// SettingsView.swift
// Port of FoxyVPN's ui/screens/SettingsScreen.kt — port, DNS, proxy chaining, exit verification,
// proxy-only mode, and sign out.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    let onSignOut: () -> Void
    let onOpenLogs: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                Section("Mode") {
                    Toggle("Proxy-only mode", isOn: $settings.proxyOnlyMode)
                    Text("Configures macOS system SOCKS proxy instead of a system-wide network extension.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Local SOCKS5 port")
                        Spacer()
                        TextField("Port", value: $settings.socksPort, formatter: NumberFormatter())
                            .frame(width: 80)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }

                Section("DNS") {
                    Picker("DNS-over-HTTPS", selection: $settings.dohProvider) {
                        ForEach(DohProvider.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                }

                Section("Verification") {
                    Toggle("Exit verification", isOn: $settings.exitVerificationEnabled)
                    Text("Checks IP exit country against Cloudflare trace after connecting.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Diagnostics") {
                    Button("View logs", action: onOpenLogs)
                }

                Section {
                    Button("Sign Out", role: .destructive, action: onSignOut)
                }
            }
            .padding()
        }
        .frame(width: 460, height: 500)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.headline)
            Spacer()
            Button("Done", action: onDismiss)
        }
        .padding()
    }
}
