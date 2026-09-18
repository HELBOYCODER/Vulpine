// TunnelManager.swift
// Orchestrates the VPN session on macOS — fetches the proxy pass from Guardian, establishes
// the HTTP/2 upstream connection to Fastly's edge, starts the local SOCKS5 server, verifies
// that traffic actually flows end-to-end, and configures the macOS system SOCKS proxy.
//
// Direct macOS port of FoxyVPN's FoxyVpnService.kt.
//
// v1.1.0: the system proxy is now configured automatically on every network service that
// is actually up (not just one hard-coded "Wi-Fi"), networksetup failures are surfaced
// (with a one-time administrator-privilege fallback), the previous proxy state is restored
// on disconnect, failing edge candidates are skipped automatically, and a post-connect
// exit check turns "connected but silent" into a visible error instead of a lie.

import Foundation
import Combine
import SystemConfiguration

struct ProxyApplyResult: Sendable {
    /// service name -> previously captured proxy state (for restore on disconnect)
    let appliedServices: [String: String]
    let needsAdmin: Bool
}

@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var currentCandidate: ProxyCandidate?
    @Published private(set) var exitInfo: TunnelExitInfo?
    @Published private(set) var rxRatePerSecond: Int64 = 0
    @Published private(set) var txRatePerSecond: Int64 = 0
    /// Per-server dial failures from the most recent attempt — lets the UI explain *why* a
    /// connection failed instead of showing one opaque error string.
    @Published private(set) var dialDiagnostics: [EdgeDialFailure] = []

    /// How many edge servers to try before giving up on a connect attempt.
    private static let maxCandidateAttempts = 5

    private var activeSession: H2UpstreamSession?
    private var socksServer: LocalSocks5Server?
    private var statsTimer: Timer?
    private var lastStats: (tx: Int64, rx: Int64) = (0, 0)
    /// Guards against a stale connect task resurrecting the tunnel after stop().
    private var generation = 0
    /// Network services whose SOCKS proxy we changed while connected.
    private var modifiedProxyServices: [String: String] = [:]
    private var systemProxyApplied = false

    private let tokenStore = TokenStore.shared
    private let proxyStore = ProxyStateStore.shared
    private let settings = SettingsStore.shared

    func start() {
        guard state == .disconnected else { return }
        state = .connecting
        lastError = nil
        exitInfo = nil
        generation += 1
        let gen = generation

        Task {
            do {
                try await performConnect(generation: gen)
                guard gen == self.generation else { return }
                self.state = .connected
                self.startStatsTimer()
                await AppLog.shared.info("Tunnel", "connected to \(self.currentCandidate?.authority ?? "upstream")")
            } catch {
                guard gen == self.generation else { return }
                await AppLog.shared.error("Tunnel", "connect failed", error: error)
                self.lastError = error.localizedDescription
                self.stop()
            }
        }
    }

    func stop() {
        generation += 1
        state = .disconnected
        teardown()
        rxRatePerSecond = 0
        txRatePerSecond = 0
        exitInfo = nil
    }

    /// Tears the tunnel down but keeps the current state/lastError values.
    private func teardown() {
        statsTimer?.invalidate()
        statsTimer = nil
        socksServer?.stop()
        socksServer = nil
        activeSession?.close()
        activeSession = nil
        if systemProxyApplied {
            systemProxyApplied = false
            let services = modifiedProxyServices
            modifiedProxyServices = [:]
            Task.detached(priority: .userInitiated) {
                await SystemProxyConfigurator.restore(services)
            }
        }
    }

    // MARK: - Connect sequence

    private func performConnect(generation gen: Int) async throws {
        // Step 1: Ensure we have a valid access token.
        let accessToken: String
        if let token = await FxaAuthRepository.shared.currentAccessToken() {
            accessToken = token
        } else {
            let status = try await FxaAuthRepository.shared.restoreSession()
            guard status == .active, let token = await FxaAuthRepository.shared.currentAccessToken() else {
                throw AppError.tokenInvalid
            }
            accessToken = token
        }

        // Step 2: Fetch a proxy pass from Guardian — activating the (free) entitlement first
        // when the account has never been enrolled, otherwise fresh accounts always get 401.
        await AppLog.shared.info("Tunnel", "fetching proxy pass from Guardian...")
        let pass = try await GuardianClient.mintProxyPass(endpoint: guardianEndpointDefault, accessToken: accessToken)

        // Step 3: Collect candidate edge nodes — the saved selection first, then the rest.
        let candidates = try await resolveCandidates()
        guard !candidates.isEmpty else {
            throw AppError.transport("No servers available from Mozilla Remote Settings")
        }

        // Step 4: Try candidates until one passes the end-to-end exit check.
        var lastError: Error = AppError.transport("No working edge server found")
        let savedAuthority = proxyStore.selectedProxy?.authority
        for candidate in candidates.prefix(6) {
            guard gen == self.generation else { return }
            do {
                try await connectToEdge(candidate, passToken: pass.token)
                guard gen == self.generation else { return }
                currentCandidate = candidate
                proxyStore.save(candidate)
                return
            } catch {
                guard gen == self.generation else { return }
                await AppLog.shared.warn("Tunnel", "candidate \(candidate.authority) failed", error: error)
                lastError = error
                teardownSession()
                // Retiring a dead saved location matters: it is always tried first, so without
                // this the app would keep paying for a server that no longer works.
                if candidate.authority == savedAuthority {
                    let result = proxyStore.recordFailure()
                    if result.shouldDiscard {
                        await AppLog.shared.warn("Tunnel", "saved location \(candidate.authority) discarded after \(result.failures) failures")
                    }
                }
            }
        }
        throw AppError.transport(
            "\(lastError.localizedDescription). Firefox VPN edges listen on TCP 2499 "
                + "(443 is tried as a fallback). If your network blocks both, no location can connect — "
                + "try another location or a different network."
        )
    }

    private func connectToEdge(_ candidate: ProxyCandidate, passToken: String) async throws {
        // Protocol port first (2499), then 443. Some networks only pass 443 and some Fastly
        // POPs answer the proxy on both; a failed port costs at most one quick round trip.
        var ports = [candidate.port]
        if candidate.port != 443 { ports.append(443) }

        var lastError: Error = AppError.transport("no usable port on \(candidate.host)")
        for port in ports {
            do {
                try await connectToEdgePort(candidate, port: port, passToken: passToken)
                return
            } catch {
                await AppLog.shared.warn("Tunnel", "\(candidate.host):\(port) failed", error: error)
                lastError = error
                teardownSession()
            }
        }
        throw lastError
    }

    private func connectToEdgePort(_ candidate: ProxyCandidate, port: Int, passToken: String) async throws {
        // Start the HTTP/2 session to the Fastly edge node.
        await AppLog.shared.info("Tunnel", "connecting to edge \(candidate.host):\(port)...")
        let session = H2UpstreamSession(
            edgeHost: candidate.host,
            edgePort: port,
            bearerToken: passToken,
            dohEndpoints: settings.dohEndpoints,
            edgeAddressOverride: settings.effectiveCustomEdgeAddress,
            upstreamProxy: settings.upstreamProxySetting
        )
        session.onSessionDead = { [weak self] in
            Task { @MainActor in
                self?.handleSessionDeath()
            }
        }
        try await session.connect()
        activeSession = session

        // Start the local SOCKS5 server listening on 127.0.0.1:port.
        let socks = LocalSocks5Server(port: settings.socksPort)
        socks.sessionProvider = { [weak self] in self?.activeSession }
        try socks.start()
        socksServer = socks

        // Step 5: prove that traffic really flows through the tunnel.
        if settings.exitCheckEnabled {
            let exit = try await TunnelVerifier.verify(socksPort: settings.socksPort)
            exitInfo = exit
            await AppLog.shared.info("Tunnel", "exit check passed: \(exit.ip) (\(exit.country))")
        }

        // Step 6: route the system's traffic through the local bridge.
        if settings.proxyOnlyMode {
            let applied = await SystemProxyConfigurator.apply(port: settings.socksPort)
            if !applied.appliedServices.isEmpty {
                modifiedProxyServices.merge(applied.appliedServices) { _, new in new }
                systemProxyApplied = true
            }
            if applied.needsAdmin {
                await AppLog.shared.warn("Tunnel", "system proxy needs administrator approval; some services may be unconfigured")
            }
        }
    }

    private func teardownSession() {
        socksServer?.stop()
        socksServer = nil
        activeSession?.close()
        activeSession = nil
    }

    /// The saved selection (if any) followed by candidates from every available country.
    private func resolveCandidates() async throws -> [ProxyCandidate] {
        var out: [ProxyCandidate] = []
        var seen = Set<String>()
        if let selected = proxyStore.selectedProxy {
            out.append(selected)
            seen.insert(selected.authority)
        }
        let countries = try await ServerListClient.fetchCountries()
        for country in countries {
            for candidate in ServerListSupport.candidatesForCountry(countries, countryCode: country.code) where !seen.contains(candidate.authority) {
                seen.insert(candidate.authority)
                out.append(candidate)
                if out.count >= 12 { return out }
            }
        }
        return out
    }

    private func handleSessionDeath() {
        guard state == .connected else { return }
        stop()
        lastError = "Connection to edge dropped"
    }

    private func startStatsTimer() {
        lastStats = socksServer?.readStats() ?? (0, 0)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let socks = self.socksServer else { return }
                let current = socks.readStats()
                self.txRatePerSecond = max(0, current.tx - self.lastStats.tx)
                self.rxRatePerSecond = max(0, current.rx - self.lastStats.rx)
                self.lastStats = current
            }
        }
    }
}

// MARK: - System SOCKS proxy configuration (v1.1.0)

/// Configures the macOS system SOCKS proxy across every active network service, using
/// `networksetup`. Runs all blocking process calls off the main actor.
enum SystemProxyConfigurator {

    /// Reads the current SOCKS proxy settings of a service via `networksetup -getsocksfirewallproxy`.
    static func currentState(of service: String) -> String {
        let output = runCapture("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service]) ?? ""
        var enabled = false
        var host = ""
        var port = ""
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Enabled:") {
                enabled = line.contains("Yes")
            } else if line.hasPrefix("Server:") {
                host = String(line.dropFirst("Server:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Port:") {
                port = String(line.dropFirst("Port:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return "\(enabled ? 1 : 0)|\(host)|\(port)"
    }

    /// Applies the system SOCKS proxy to every active network service.
    /// Tries `networksetup` directly first; only if that fails (non-admin user) does it
    /// fall back to an administrator-privilege prompt.
    static func apply(port: Int) async -> ProxyApplyResult {
        let services = activeNetworkServices()
        var applied: [String: String] = [:]
        var needsAdmin = false

        for service in services {
            let previous = currentState(of: service)
            let parts = previous.split(separator: "|").map(String.init)
            let wasEnabled = parts.first == "1"
            let wasOurs = parts.count >= 3 && parts[1] == "127.0.0.1" && parts[2] == String(port)
            if wasEnabled && wasOurs { continue } // already pointed at us

            var ok = run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, "127.0.0.1", String(port)])
            if !ok {
                // Fall back to an explicit admin prompt — networksetup requires admin group rights.
                ok = await runElevated("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, "127.0.0.1", String(port)])
                if ok { needsAdmin = true }
            }
            if ok {
                applied[service] = previous
                // Verify it actually took effect.
                let now = currentState(of: service)
                let nowParts = now.split(separator: "|").map(String.init)
                if !(nowParts.first == "1" && nowParts.count >= 3 && nowParts[1] == "127.0.0.1" && nowParts[2] == String(port)) {
                    applied.removeValue(forKey: service)
                    await AppLog.shared.warn("Tunnel", "system proxy on '\(service)' did not stick")
                }
            } else {
                await AppLog.shared.error("Tunnel", "could not set the system SOCKS proxy on '\(service)' (administrator approval declined?)")
                needsAdmin = true
            }
        }
        return ProxyApplyResult(appliedServices: applied, needsAdmin: needsAdmin)
    }

    /// Restores the proxy state captured in `services` (empty string disables).
    static func restore(_ services: [String: String]) async {
        for (service, previous) in services {
            let parts = previous.split(separator: "|").map(String.init)
            if parts.first == "1", parts.count >= 3 {
                _ = run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, parts[1], parts[2]])
            } else {
                _ = run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
            }
        }
    }

    /// Network services that currently have an IPv4 address (i.e. are actually in use).
    static func activeNetworkServices() -> [String] {
        guard let listing = runCapture("/usr/sbin/networksetup", ["-listallnetworkservices"]) else { return [] }
        var services: [String] = []
        for rawLine in listing.split(separator: "\n").dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains("denotes"), !line.contains("asterisk") else { continue }
            let service = line.hasPrefix("*") ? String(line.dropFirst()) : line
            guard !service.isEmpty else { continue }
            let info = runCapture("/usr/sbin/networksetup", ["-getinfo", service]) ?? ""
            if let ipLine = info.split(separator: "\n").first(where: { $0.hasPrefix("IP address") }),
               !ipLine.contains("none"), ipLine.contains(":") {
                let ip = ipLine.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !ip.isEmpty { services.append(service) }
            }
        }
        return services
    }

    // MARK: - Process helpers (blocking — always call off the main thread)

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func runCapture(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func runElevated(_ path: String, _ arguments: [String]) async -> Bool {
        let escaped = arguments
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            .map { "\"\($0)\"" }
            .joined(separator: " ")
        let script = "do shell script \"\(path) \(escaped)\" with administrator privileges"
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }
}
