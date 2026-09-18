// LoginView.swift
// Port of FoxyVPN's ui/screens/LoginScreen.kt — Firefox account sign-in
// (credentials + 2FA confirmation code).

import SwiftUI

struct LoginView: View {
    @ObservedObject var auth: FxaAuthRepository
    let onSignedIn: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var awaitingTwoFactor = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 56))
                .foregroundColor(Theme.accent)

            VStack(spacing: 6) {
                Text("Sign in with Firefox")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Vulpine uses the free 50 GB monthly VPN traffic included with your Firefox account. No subscription required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if !awaitingTwoFactor {
                credentialsForm
            } else {
                twoFactorForm
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
        }
        .padding(32)
        .frame(width: 420, height: 460)
    }

    private var credentialsForm: some View {
        VStack(spacing: 12) {
            TextField("Firefox account email", text: $email)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Button(action: submitLogin) {
                HStack {
                    if isLoading { ProgressView().scaleEffect(0.8) }
                    Text("Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(isLoading || email.isEmpty || password.isEmpty)
        }
    }

    private var twoFactorForm: some View {
        VStack(spacing: 12) {
            Text("Enter the confirmation code sent to your email")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Confirmation code", text: $code)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Button(action: submitTwoFactor) {
                HStack {
                    if isLoading { ProgressView().scaleEffect(0.8) }
                    Text("Verify")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(isLoading || code.isEmpty)
        }
    }

    private func submitLogin() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                let needsVerification = try await auth.startLogin(email: email, password: password)
                isLoading = false
                if needsVerification {
                    awaitingTwoFactor = true
                } else {
                    onSignedIn()
                }
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func submitTwoFactor() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await auth.submitTwoFactorCode(code)
                isLoading = false
                onSignedIn()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
