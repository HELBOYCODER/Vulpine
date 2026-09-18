// VulpineApp.swift
// Application entry point for Vulpine macOS.
// Integrates standard window + Menu Bar extra item for fast toggling.

import SwiftUI

@main
struct VulpineApp: App {
    @StateObject private var auth = FxaAuthRepository.shared
    @StateObject private var tunnel = TunnelManager.shared
    @State private var hasCheckedSession = false
    @State private var isSignedIn = false

    var body: some Scene {
        WindowGroup {
            Group {
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
            .onAppear(perform: checkSession)
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
        case .connected: return "Protected — Connected"
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
}
