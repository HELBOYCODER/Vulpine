// TunnelManager.swift
// Orchestrates the VPN session on macOS — fetches the proxy pass from Guardian, establishes
// the HTTP/2 upstream connection to Fastly's edge, starts the local SOCKS5 server, and
// configures system proxy routing when proxy-only mode is selected.
//
// Direct macOS port of FoxyVPN's FoxyVpnService.kt.

import Foundation
import Combine
import SystemConfiguration

@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var currentCandidate: ProxyCandidate?
    @Published private(set) var rxRatePerSecond: Int64 = 0
    @Published private(set) var txRatePerSecond: Int64 = 0

    private var activeSession: H2UpstreamSession?
    private var socksServer: LocalSocks5Server?
    private var statsTimer: Timer?
    private var lastStats: (tx: Int64, rx: Int64) = (0, 0)

    private let tokenStore = TokenStore.shared
    private let proxyStore = ProxyStateStore.shared
    private let settings = SettingsStore.shared

    func start() {
        guard state == .disconnected else { return }
        state = .connecting
        lastError = nil

        Task {
            do {
                try await performConnect()
                state = .connected
                startStatsTimer()
                await AppLog.shared.info("Tunnel", "connected to \(currentCandidate?.authority ?? "upstream")")
            } catch {
                await AppLog.shared.error("Tunnel", "connect failed", error: error)
                lastError = error.localizedDescription
                stop()
            }
        }
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        socksServer?.stop()
        socksServer = nil
        activeSession?.close()
        activeSession = nil
        disableSystemProxy()
        state = .disconnected
        rxRatePerSecond = 0
        txRatePerSecond = 0
    }

    private func performConnect() async throws {
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

        // Step 2: Fetch a proxy pass from Guardian.
        await AppLog.shared.info("Tunnel", "fetching proxy pass from Guardian...")
        let pass = try await GuardianClient.fetchProxyPass(endpoint: guardianEndpointDefault, accessToken: accessToken)

        // Step 3: Pick a candidate server node.
        let candidate = try await resolveCandidate()
        self.currentCandidate = candidate

        // Step 4: Start the HTTP/2 session to the Fastly edge node.
        await AppLog.shared.info("Tunnel", "connecting to edge \(candidate.authority)...")
        let session = H2UpstreamSession(
            edgeHost: candidate.host,
            edgePort: candidate.port,
            bearerToken: pass.token,
            customDnsServer: settings.customDnsServer
        )
        session.onSessionDead = { [weak self] in
            Task { @MainActor in
                self?.handleSessionDeath()
            }
        }
        try await session.connect()
        self.activeSession = session

        // Step 5: Start the local SOCKS5 server listening on 127.0.0.1:port.
        let socks = LocalSocks5Server(port: settings.socksPort)
        socks.sessionProvider = { [weak self] in self?.activeSession }
        try socks.start()
        self.socksServer = socks

        // Step 6: If proxy-only mode is active, set the macOS system SOCKS proxy to route through us.
        if settings.proxyOnlyMode {
            enableSystemProxy(port: settings.socksPort)
        }
    }

    private func resolveCandidate() async throws -> ProxyCandidate {
        if let explicit = proxyStore.selectedProxy { return explicit }
        let countries = try await ServerListClient.fetchCountries()
        guard let first = countries.first(where: { !$0.cities.isEmpty }),
              let candidate = ServerListSupport.candidatesForCountry(countries, countryCode: first.code).first
        else {
            throw AppError.transport("No servers available from Mozilla Remote Settings")
        }
        proxyStore.save(candidate)
        return candidate
    }

    private func handleSessionDeath() {
        guard state == .connected else { return }
        stop()
        lastError = "Connection to edge dropped"
    }

    private func startStatsTimer() {
        lastStats = socksServer?.readStats() ?? (0, 0)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let socks = self.socksServer else { return }
            let current = socks.readStats()
            self.txRatePerSecond = max(0, current.tx - self.lastStats.tx)
            self.rxRatePerSecond = max(0, current.rx - self.lastStats.rx)
            self.lastStats = current
        }
    }

    // MARK: - macOS System SOCKS Proxy Configuration

    private func enableSystemProxy(port: Int) {
        runNetworksetup(["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", String(port)])
        runNetworksetup(["-setsocksfirewallproxystate", "Wi-Fi", "on"])
    }

    private func disableSystemProxy() {
        guard settings.proxyOnlyMode else { return }
        runNetworksetup(["-setsocksfirewallproxystate", "Wi-Fi", "off"])
    }

    private func runNetworksetup(_ arguments: [String]) {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments = arguments
        try? task.run()
    }
}
