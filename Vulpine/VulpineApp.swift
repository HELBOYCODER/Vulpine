// VulpineApp.swift
// Application entry point for Vulpine macOS.
// Integrates standard window + Menu Bar extra item for fast toggling.

import SwiftUI
import AppKit

@main
struct VulpineApp: App {
    @StateObject private var auth = FxaAuthRepository.shared
    @StateObject private var tunnel = TunnelManager.shared
    @State private var hasCheckedSession = false
    @State private var isSignedIn = false

    var body: some Scene {
        WindowGroup {
            contentView
                .onAppear(perform: checkSession)
                .onOpenURL(perform: handleURL)
        }
        .windowResizability(.contentSize)

        // Menu Bar Extra — quick status and toggle from the macOS menu bar.
        MenuBarExtra("Vulpine", systemImage: menuBarIcon) {
            Text(menuBarStatusText)
            Divider()
            Button(tunnel.state == .connected ? "Disconnect" : "Connect") {
                if tunnel.state == .connected {
                    tunnel.stop()
                } else {
                    tunnel.start()
                }
            }
            Divider()
            Button("Quit Vulpine") {
                tunnel.stop()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if !hasCheckedSession {
            splashView
        } else if isSignedIn {
            MainView()
        } else {
            LoginView(auth: auth) {
                isSignedIn = true
            }
        }
    }

    private var splashView: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundColor(Theme.accent)
            Text("Vulpine")
                .font(.title2)
                .fontWeight(.bold)
            ProgressView()
                .scaleEffect(0.8)
        }
        .frame(width: 300, height: 260)
    }

    private var menuBarIcon: String {
        switch tunnel.state {
        case .connected: return "shield.lefthalf.filled"
        case .connecting: return "shield.dashed"
        case .disconnected: return "shield"
        }
    }

    private var menuBarStatusText: String {
        switch tunnel.state {
        case .connected:
            if let country = tunnel.exitInfo?.country, !country.isEmpty {
                return "Connected — \(country)"
            }
            return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        }
    }

    private func checkSession() {
        Task {
            let status = await auth.restoreSession()
            hasCheckedSession = true
            isSignedIn = (status == .active)
        }
    }

    // MARK: - vulpine:// URL scheme (connect / disconnect / toggle)

    private func handleURL(_ url: URL) {
        let action = url.host?.lowercased()
            ?? url.absoluteString
                .replacingOccurrences(of: "vulpine:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
        switch action {
        case "connect":
            tunnel.start()
        case "disconnect":
            tunnel.stop()
        case "toggle":
            tunnel.state == .connected ? tunnel.stop() : tunnel.start()
        default:
            Task { await AppLog.shared.warn("App", "unknown vulpine:// action: \(url.absoluteString)") }
        }
    }
}
