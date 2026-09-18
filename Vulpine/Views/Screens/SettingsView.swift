// SettingsView.swift
// Port of FoxyVPN's ui/screens/SettingsScreen.kt — v1.1.0 redesign: a proper macOS
// settings pane with toolbar tabs (General / Connection / Network / Advanced), exposing
// every setting the store supports instead of a cramped single Form.

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    let onSignOut: () -> Void
    let onOpenLogs: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                connectionTab
                    .tabItem { Label("Connection", systemImage: "bolt.horizontal") }
                networkTab
                    .tabItem { Label("Network", systemImage: "network") }
                advancedTab
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }
            .padding(.top, 8)

            Divider()

            HStack {
                Button("View Logs…", action: onOpenLogs)
                Spacer()
                Button("Sign Out", role: .destructive, action: onSignOut)
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
            .padding(.top, 10)
        }
        .frame(width: 580, height: 520)
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.themeMode) {
                    Text("Automatic").tag(Settings.ThemeMode.system)
                    Text("Light").tag(Settings.ThemeMode.light)
                    Text("Dark").tag(Settings.ThemeMode.dark)
                }
            }

            Section("System") {
                Toggle("Launch Vulpine at login", isOn: launchAtLoginBinding)

                LabeledContent("SOCKS5 port") {
                    TextField("Port", value: $settings.socksPort, formatter: NumberFormatter())
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }
                Text("The local bridge always listens on 127.0.0.1. Other apps can use it directly as a SOCKS5 proxy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var connectionTab: some View {
        Form {
            Section("Routing") {
                Toggle("Configure macOS system proxy", isOn: $settings.proxyOnlyMode)
                Text("When connected, Vulpine points the macOS SOCKS proxy at its local bridge so all apps use the tunnel automatically. Turn this off if you only want to use the SOCKS5 port manually.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Verification") {
                Toggle("Exit-node check", isOn: $settings.exitCheckEnabled)
                Text("After connecting, Vulpine sends a small request through the tunnel (Cloudflare trace) to confirm traffic is really flowing, and reports the exit country. If traffic does not flow, it tries another server instead of showing a fake \"Protected\".")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var networkTab: some View {
        Form {
            Section("DNS") {
                Picker("DNS-over-HTTPS", selection: $settings.dohProvider) {
                    ForEach(DohProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

                Toggle("Use a custom DNS server", isOn: $settings.customDnsEnabled)

                if settings.customDnsEnabled {
                    LabeledContent("DNS server") {
                        TextField("e.g. 1.1.1.1", text: $settings.customDnsServer)
                            .frame(width: 160)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Presets", selection: dnsPresetBinding) {
                        Text("Custom…").tag("")
                        ForEach(Settings.customDnsPresets.sorted(by: { $0.key < $1.key }), id: \.key) { key, label in
                            Text(label).tag(key)
                        }
                    }
                }
            }

            Section("Upstream proxy (chaining)") {
                Toggle("Connect through another proxy", isOn: $settings.upstreamProxyEnabled)

                if settings.upstreamProxyEnabled {
                    Picker("Type", selection: $settings.upstreamProxyType) {
                        Text("SOCKS5").tag(UpstreamProxyType.socks5)
                        Text("HTTP").tag(UpstreamProxyType.http)
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Host") {
                        TextField("proxy.example.com", text: $settings.upstreamProxyHost)
                            .frame(width: 220)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Port") {
                        TextField("Port", value: $settings.upstreamProxyPort, formatter: NumberFormatter())
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Username") {
                        TextField("optional", text: $settings.upstreamProxyUsername)
                            .frame(width: 220)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Password") {
                        SecureField("optional", text: $settings.upstreamProxyPassword)
                            .frame(width: 220)
                    }

                    Button("Clear saved credentials", action: settings.resetUpstreamProxyCredentials)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var advancedTab: some View {
        Form {
            Section("Edge server") {
                LabeledContent("Custom edge address") {
                    TextField("leave empty for automatic", text: $settings.customEdgeAddress)
                        .frame(width: 220)
                        .multilineTextAlignment(.trailing)
                }
                Text("Overrides the Fastly edge host chosen from Mozilla's server list. Only change this if you know what you are doing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Split routing") {
                Toggle("Bypass the tunnel for LAN addresses", isOn: $settings.bypassLan)

                LabeledContent("Excluded domains") {
                    TextField("example.com, app.internal", text: $settings.excludedDomainsRaw)
                        .frame(width: 260)
                }
                Text("Comma- or space-separated domains that should not go through the tunnel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Bindings

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { enabled in
                settings.launchAtLogin = enabled
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    Task { await AppLog.shared.warn("Settings", "launch-at-login could not be updated", error: error) }
                }
            }
        )
    }

    private var dnsPresetBinding: Binding<String> {
        Binding(
            get: { Settings.customDnsPresets[settings.customDnsServer] != nil ? settings.customDnsServer : "" },
            set: { newValue in
                if !newValue.isEmpty { settings.customDnsServer = newValue }
            }
        )
    }
}
