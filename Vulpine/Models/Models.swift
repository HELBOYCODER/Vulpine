// Models.swift
// Shared domain types — direct ports of FoxyVPN's data/model/Models.kt

import Foundation

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

enum LoginStepState: Equatable, Sendable {
    case credentials
    case twoFactor
}

struct VpnProtocol: Hashable, Sendable {
    let name: String
    let host: String
    let port: Int
    let scheme: String
    let templateString: String

    init(name: String, host: String = "", port: Int = 0, scheme: String = "", templateString: String = "") {
        self.name = name
        self.host = host
        self.port = port
        self.scheme = scheme
        self.templateString = templateString
    }
}

struct VpnServerNode: Hashable, Sendable {
    let hostname: String
    let port: Int
    let quarantined: Bool
    let protocols: [VpnProtocol]
}

struct VpnCity: Hashable, Sendable {
    let name: String
    let code: String
    let servers: [VpnServerNode]
}

struct VpnCountry: Hashable, Sendable {
    let name: String
    let code: String
    let cities: [VpnCity]
}

struct ProxyCandidate: Hashable, Sendable {
    let host: String
    let port: Int
    let countryCode: String
    let countryName: String
    let cityCode: String

    var authority: String { "\(host):\(port)" }
}

struct Entitlement: Equatable, Sendable {
    let subscribed: Bool
    let uid: String
    let maxBytes: Int64?
    let limitedBandwidth: Bool
    let quotaRemaining: Int64?
}

struct RuntimeAuth: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAtEpochSeconds: Int64
}

enum SessionStatus: Sendable {
    case active
    case needsLogin
    case unreachable
}

struct ProxyPass: Equatable, Sendable {
    let token: String
    let expiresAtEpochSeconds: Int64?
    let quotaMax: Int64?
    let quotaRemaining: Int64?
    let quotaReset: Int64?
}

enum UpstreamProxyType: String, CaseIterable, Sendable {
    case socks5
    case http
}

enum DohProvider: String, CaseIterable, Sendable {
    case automatic
    case cloudflare
    case google
    case quad9
    case off

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .off: return "Off (use the system resolver)"
        }
    }

    var addresses: [String] {
        switch self {
        case .automatic: return ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
        case .cloudflare: return ["1.1.1.1", "1.0.0.1"]
        case .google: return ["8.8.8.8", "8.8.4.4"]
        case .quad9: return ["9.9.9.9", "149.112.112.112"]
        case .off: return []
        }
    }

    /// DNS-over-HTTPS endpoints (RFC 8484). IP-literal URLs are used on purpose: the whole
    /// point is to resolve Mozilla's edge hostnames when the system resolver is broken or
    /// filtered, so the DoH endpoint itself must not depend on that resolver.
    var dohEndpoints: [String] {
        switch self {
        case .automatic:
            return ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "https://9.9.9.9/dns-query"]
        case .cloudflare:
            return ["https://1.1.1.1/dns-query", "https://1.0.0.1/dns-query"]
        case .google:
            return ["https://8.8.8.8/dns-query", "https://8.8.4.4/dns-query"]
        case .quad9:
            return ["https://9.9.9.9/dns-query"]
        case .off:
            return []
        }
    }
}

/// An upstream proxy the tunnel should be dialled through. Mirrors FoxyVPN's
/// `UpstreamProxyConfig`. Applied with `NWParameters.PrivacyContext.proxyConfigurations`
/// (macOS 14+), which chains the TCP *and* the TLS handshake through the proxy exactly like
/// Netty's proxy handler does on Android.
struct UpstreamProxySetting: Sendable, Equatable {
    let type: UpstreamProxyType
    let host: String
    let port: Int
    let username: String
    let password: String

    var isUsable: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65_535).contains(port) }
}

/// Why a single candidate edge could not be dialled — surfaced in the log so a "cannot
/// connect" failure names the actual cause instead of just the last error string.
struct EdgeDialFailure: Sendable {
    let authority: String
    let reason: String
}

/// Server-list helpers mirroring ServerListClient.kt's companion object.
enum ServerListSupport {
    /// Equivalent of `ServerListClient.defaultConnectTarget(server)`.
    static func defaultConnectTarget(_ server: VpnServerNode) -> (host: String, port: Int)? {
        for proto in server.protocols where proto.name == "connect" {
            let host = proto.host.isEmpty ? server.hostname : proto.host
            let port = proto.port != 0 ? proto.port : server.port
            return (host, port)
        }
        if server.protocols.isEmpty { return (server.hostname, server.port) }
        return nil
    }

    /// Equivalent of `ServerListClient.candidatesForCountry(...)`.
    static func candidatesForCountry(_ countries: [VpnCountry], countryCode: String) -> [ProxyCandidate] {
        var out: [ProxyCandidate] = []
        for country in countries where country.code.lowercased() == countryCode.lowercased() {
            for city in country.cities {
                for server in city.servers where !server.quarantined {
                    guard let target = defaultConnectTarget(server) else { continue }
                    out.append(
                        ProxyCandidate(
                            host: target.host,
                            port: target.port,
                            countryCode: country.code,
                            countryName: country.name,
                            cityCode: city.code
                        )
                    )
                }
            }
        }
        return out
    }

    /// Equivalent of `ServerListClient.candidatesForCity(...)`.
    static func candidatesForCity(
        _ countries: [VpnCountry],
        countryCode: String,
        cityCode: String
    ) -> [ProxyCandidate] {
        candidatesForCountry(countries, countryCode: countryCode)
            .filter { $0.cityCode.lowercased() == cityCode.lowercased() }
    }
}
