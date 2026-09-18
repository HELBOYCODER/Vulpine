// Settings.swift
// Persistent user preferences — port of FoxyVPN's data/SettingsStore.kt.
// UserDefaults replaces SharedPreferences; Keychain replaces EncryptedSharedPreferences.

import Foundation
import Combine

// Alias for compatibility with FoxyVPN naming
typealias SettingsStore = Settings

final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: Theme

    enum ThemeMode: String, CaseIterable {
        case system
        case light
        case dark
    }

    @Published var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Key.themeMode) }
    }

    // MARK: Connection options

    @Published var exitCheckEnabled: Bool {
        didSet { defaults.set(exitCheckEnabled, forKey: Key.exitCheck) }
    }

    /// SOCKS5 listen port. On macOS this is exposed to other local apps, exactly like FoxyVPN's
    /// configurable bind address, but always binds to loopback for safety.
    @Published var socksPort: Int {
        didSet { defaults.set(socksPort.clamped(to: 1...65_535), forKey: Key.socksPort) }
    }

    /// Address the local SOCKS5 bridge binds to. Loopback by default (v1.1.0 unintentionally
    /// listened on 0.0.0.0, exposing the tunnel to the whole LAN). See `socksBindPresets`.
    @Published var socksBindAddress: String {
        didSet {
            let trimmed = socksBindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            defaults.set(trimmed, forKey: Key.socksBindAddress)
        }
    }

    /// DoH endpoints (RFC 8484) used to resolve Mozilla's edge hostnames. An explicit custom DNS
    /// server wins over the provider preset, matching the Android client's behaviour.
    var dohEndpoints: [String] {
        if customDnsEnabled, Self.isValidDnsServer(customDnsServer) {
            return ["https://\(customDnsServer)/dns-query"]
        }
        return dohProvider.dohEndpoints
    }

    /// The upstream proxy to chain the tunnel through, or nil when disabled or incomplete.
    var upstreamProxySetting: UpstreamProxySetting? {
        guard upstreamProxyEnabled else { return nil }
        let setting = UpstreamProxySetting(
            type: upstreamProxyType,
            host: upstreamProxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: upstreamProxyPort,
            username: upstreamProxyUsername,
            password: upstreamProxyPassword
        )
        return setting.isUsable ? setting : nil
    }

    @Published var dohProvider: DohProvider {
        didSet { defaults.set(dohProvider.rawValue, forKey: Key.dohProvider) }
    }

    @Published var customDnsEnabled: Bool {
        didSet { defaults.set(customDnsEnabled, forKey: Key.customDnsEnabled) }
    }

    @Published var customDnsServer: String {
        didSet {
            let trimmed = customDnsServer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidDnsServer(trimmed) else { return }
            defaults.set(trimmed, forKey: Key.customDnsServer)
        }
    }

    var effectiveCustomDnsServer: String? {
        guard customDnsEnabled else { return nil }
        let value = customDnsServer
        return Self.isValidDnsServer(value) ? value : nil
    }

    /// Equivalent of `proxyOnlyMode`: routes the system's traffic through the local SOCKS5
    /// bridge by configuring the macOS system proxy. Defaults to ON — without it the tunnel
    /// would come up but no app traffic would actually use it.
    @Published var proxyOnlyMode: Bool {
        didSet { defaults.set(proxyOnlyMode, forKey: Key.proxyOnlyMode) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    @Published var customEdgeAddress: String {
        didSet {
            let normalized = customEdgeAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard Self.isValidEdgeHost(normalized) || normalized.isEmpty else { return }
            defaults.set(normalized, forKey: Key.customEdgeAddress)
        }
    }

    var effectiveCustomEdgeAddress: String? {
        let value = customEdgeAddress
        guard !value.isEmpty, Self.isValidEdgeHost(value) else { return nil }
        return value
    }

    // MARK: Upstream proxy chaining

    @Published var upstreamProxyEnabled: Bool {
        didSet { defaults.set(upstreamProxyEnabled, forKey: Key.upstreamProxyEnabled) }
    }

    @Published var upstreamProxyType: UpstreamProxyType {
        didSet { defaults.set(upstreamProxyType.rawValue, forKey: Key.upstreamProxyType) }
    }

    @Published var upstreamProxyHost: String {
        didSet {
            defaults.set(
                upstreamProxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: Key.upstreamProxyHost
            )
        }
    }

    @Published var upstreamProxyPort: Int {
        didSet { defaults.set(upstreamProxyPort.clamped(to: 1...65_535), forKey: Key.upstreamProxyPort) }
    }

    @Published var upstreamProxyUsername: String {
        didSet { try? Keychain.set(upstreamProxyUsername, key: Key.upstreamProxyUsername) }
    }

    @Published var upstreamProxyPassword: String {
        didSet { try? Keychain.set(upstreamProxyPassword, key: Key.upstreamProxyPassword) }
    }

    // MARK: Split routing (macOS analogue of FoxyVPN's split tunneling)

    /// Bypass the tunnel for LAN destinations (10/8, 172.16/12, 192.168/16, link-local).
    @Published var bypassLan: Bool {
        didSet { defaults.set(bypassLan, forKey: Key.bypassLan) }
    }

    /// Space-separated list of domains that should resolve through the system resolver, not the tunnel.
    @Published var excludedDomainsRaw: String {
        didSet { defaults.set(excludedDomainsRaw, forKey: Key.excludedDomains) }
    }

    var excludedDomains: Set<String> {
        Set(
            excludedDomainsRaw
                .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// Bundle identifiers (or absolute paths) whose traffic should leave outside the tunnel.
    @Published var excludedAppsRaw: String {
        didSet { defaults.set(excludedAppsRaw, forKey: Key.excludedApps) }
    }

    var excludedApps: Set<String> {
        Set(
            excludedAppsRaw
                .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .map { String($0) }
                .filter { !$0.isEmpty }
        )
    }

    // MARK: Boot

    private init() {
        themeMode = Settings.ThemeMode(rawValue: defaults.string(forKey: Key.themeMode) ?? "") ?? .system
        exitCheckEnabled = defaults.object(forKey: Key.exitCheck) as? Bool ?? true
        socksPort = defaults.object(forKey: Key.socksPort) as? Int ?? Settings.defaultSocksPort
        socksBindAddress = defaults.string(forKey: Key.socksBindAddress) ?? Settings.defaultSocksBindAddress
        dohProvider = DohProvider(rawValue: defaults.string(forKey: Key.dohProvider) ?? "") ?? .automatic
        customDnsEnabled = defaults.object(forKey: Key.customDnsEnabled) as? Bool ?? false
        customDnsServer = defaults.string(forKey: Key.customDnsServer) ?? Settings.defaultCustomDnsServer
        proxyOnlyMode = defaults.object(forKey: Key.proxyOnlyMode) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        customEdgeAddress = defaults.string(forKey: Key.customEdgeAddress) ?? ""
        upstreamProxyEnabled = defaults.object(forKey: Key.upstreamProxyEnabled) as? Bool ?? false
        upstreamProxyType = UpstreamProxyType(rawValue: defaults.string(forKey: Key.upstreamProxyType) ?? "") ?? .socks5
        upstreamProxyHost = defaults.string(forKey: Key.upstreamProxyHost) ?? ""
        upstreamProxyPort = defaults.object(forKey: Key.upstreamProxyPort) as? Int ?? Settings.defaultUpstreamProxyPort
        upstreamProxyUsername = Keychain.get(Key.upstreamProxyUsername) ?? ""
        upstreamProxyPassword = Keychain.get(Key.upstreamProxyPassword) ?? ""
        bypassLan = defaults.object(forKey: Key.bypassLan) as? Bool ?? true
        excludedDomainsRaw = defaults.string(forKey: Key.excludedDomains) ?? ""
        excludedAppsRaw = defaults.string(forKey: Key.excludedApps) ?? ""
    }

    func resetUpstreamProxyCredentials() {
        Keychain.remove(Key.upstreamProxyUsername)
        Keychain.remove(Key.upstreamProxyPassword)
        upstreamProxyUsername = ""
        upstreamProxyPassword = ""
    }

    // MARK: Validation — identical rules to SettingsStore.kt

    static func isValidIpAddress(_ value: String) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(value, nil, &hints, &result)
        defer { if let result = result { freeaddrinfo(result) } }
        return rc == 0
    }

    static func isValidDnsServer(_ value: String) -> Bool { isValidIpAddress(value) }

    static func isValidHostname(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "", options: .literal, range: nil)
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.contains(":") { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  !label.hasPrefix("-"),
                  !label.hasSuffix("-")
            else { return false }
            return label.allSatisfy { char in
                char == "-" || (char.isASCII && (char.isLetter || char.isNumber))
            }
        }
    }

    static func isValidEdgeHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
        return isValidHostname(host) || isValidIpAddress(host)
    }

    // MARK: Constants (parity with SettingsStore.kt companion object)

    static let defaultSocksPort = 1080
    static let defaultSocksBindAddress = "127.0.0.1"
    static let defaultUpstreamProxyPort = 1080
    static let defaultCustomDnsServer = "1.1.1.1"

    static let socksPortPresets = [
        1080, 1081, 1086, 7890,
    ]

    static let customDnsPresets = [
        "1.1.1.1": "Cloudflare (1.1.1.1)",
        "8.8.8.8": "Google (8.8.8.8)",
        "9.9.9.9": "Quad9 (9.9.9.9)",
    ]

    static let socksBindPresets = [
        "127.0.0.1": "Loopback only (127.0.0.1)",
        "0.0.0.0": "All interfaces (0.0.0.0)",
    ]

    private enum Key {
        static let themeMode = "theme_mode"
        static let exitCheck = "exit_check_enabled"
        static let socksPort = "socks_port"
        static let socksBindAddress = "socks_bind_address"
        static let dohProvider = "doh_provider"
        static let customDnsEnabled = "custom_dns_enabled"
        static let customDnsServer = "custom_dns_server"
        static let proxyOnlyMode = "proxy_only_mode"
        static let launchAtLogin = "launch_at_login"
        static let customEdgeAddress = "custom_edge_address"
        static let upstreamProxyEnabled = "upstream_proxy_enabled"
        static let upstreamProxyType = "upstream_proxy_type"
        static let upstreamProxyHost = "upstream_proxy_host"
        static let upstreamProxyPort = "upstream_proxy_port"
        static let upstreamProxyUsername = "upstream_proxy_username"
        static let upstreamProxyPassword = "upstream_proxy_password"
        static let bypassLan = "bypass_lan"
        static let excludedDomains = "excluded_domains"
        static let excludedApps = "excluded_apps"
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

private extension String {
    /// A literal-suffix remover that only strips a single trailing dot, matching Kotlin's `removeSuffix(".")`.
    func trimmingTrailingDot() -> String {
        hasSuffix(".") ? String(dropLast()) : self
    }
}
