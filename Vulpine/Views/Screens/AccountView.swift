// AccountView.swift
// Port of FoxyVPN's ui/screens/AccountScreen.kt — Firefox account quota, subscription
// state, and account details fetched from Guardian.

import SwiftUI

struct AccountView: View {
    let onDismiss: () -> Void

    @State private var entitlement: Entitlement?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                Spacer()
                ProgressView("Fetching account details...")
                Spacer()
            } else if let errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundColor(.red)
                    Button("Retry") { loadAccount() }
                }
                Spacer()
            } else if let info = entitlement {
                content(info)
            }
        }
        .frame(width: 400, height: 380)
        .onAppear(perform: loadAccount)
    }

    private var header: some View {
        HStack {
            Text("Firefox Account")
                .font(.headline)
            Spacer()
            Button("Done", action: onDismiss)
        }
        .padding()
    }

    private func content(_ info: Entitlement) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(Theme.accent)

            VStack(spacing: 12) {
                row(title: "Subscription", value: info.subscribed ? "Active" : "Free Plan")
                row(title: "Account ID", value: info.uid.isEmpty ? "—" : info.uid)
                row(
                    title: "Data Remaining",
                    value: info.limitedBandwidth
                        ? (info.quotaRemaining.map { formatBytes($0) } ?? "50 GB limit")
                        : "Unlimited"
                )
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            Link("Manage subscription on Mozilla", destination: URL(string: guardianEndpointDefault)!)
                .font(.caption)

            Spacer()
        }
        .padding()
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func loadAccount() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                guard let token = await FxaAuthRepository.shared.currentAccessToken() else {
                    throw AppError.tokenInvalid
                }
                entitlement = try await GuardianClient.fetchUserInfo(endpoint: guardianEndpointDefault, accessToken: token)
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
