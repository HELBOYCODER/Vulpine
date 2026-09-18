// MainView.swift
// Port of FoxyVPN's ui/screens/HomeScreen.kt — primary macOS dashboard with power button,
// connection status, location card, traffic throughput, and modal sheet routing.

import SwiftUI

struct MainView: View {
    @ObservedObject var tunnel = TunnelManager.shared
    @ObservedObject var proxyStore = ProxyStateStore.shared
    @ObservedObject var auth = FxaAuthRepository.shared

    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: String, Identifiable {
        case serverList
        case settings
        case account
        case logs
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 24) {
            topBar

            Spacer()

            statusLabel

            PowerButton(state: tunnel.state) {
                toggleConnection()
            }

            if tunnel.state == .connected {
                TrafficStatsView(
                    rxRatePerSecond: tunnel.rxRatePerSecond,
                    txRatePerSecond: tunnel.txRatePerSecond
                )

                if let exit = tunnel.exitInfo {
                    Label {
                        Text(exitTitle(exit))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                            .foregroundColor(Theme.accent)
                    }
                }
            }

            Spacer()

            ServerCard(candidate: proxyStore.selectedProxy) {
                activeSheet = .serverList
            }
        }
        .padding(24)
        .frame(width: 360, height: 500)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .serverList:
                ServerListView { activeSheet = nil }
            case .settings:
                SettingsView(
                    onSignOut: {
                        tunnel.stop()
                        auth.signOut()
                        activeSheet = nil
                    },
                    onOpenLogs: { activeSheet = .logs },
                    onDismiss: { activeSheet = nil }
                )
            case .account:
                AccountView { activeSheet = nil }
            case .logs:
                LogsView { activeSheet = nil }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundColor(Theme.accent)
                .font(.title3)

            Text("Vulpine")
                .font(.headline)
                .fontWeight(.bold)

            Spacer()

            Button(action: { activeSheet = .account }) {
                Image(systemName: "person.crop.circle")
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: { activeSheet = .settings }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var statusLabel: some View {
        VStack(spacing: 4) {
            Text(statusTitle)
                .font(.title3)
                .fontWeight(.semibold)

            if let error = tunnel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var statusTitle: String {
        switch tunnel.state {
        case .connected: return "Protected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Not connected"
        }
    }

    private func exitTitle(_ exit: TunnelExitInfo) -> String {
        let country = exit.country.isEmpty ? "unknown" : exit.country
        return exit.ip.isEmpty ? "Exit: \(country)" : "Exit: \(country) • \(exit.ip)"
    }

    private func toggleConnection() {
        switch tunnel.state {
        case .connected, .connecting:
            tunnel.stop()
        case .disconnected:
            tunnel.start()
        }
    }
}
