// TokenStore.swift
// Port of FoxyVPN's data/TokenStore.kt — Keychain-backed FxA session storage.

import Foundation

final class TokenStore {
    static let shared = TokenStore()

    private enum Key {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let expiresAt = "expires_at"
    }

    private static let clockSkewToleranceSeconds: Int64 = 60

    func saveAuth(_ auth: RuntimeAuth) {
        try? Keychain.set(auth.accessToken, key: Key.accessToken)
        if let refresh = auth.refreshToken {
            try? Keychain.set(refresh, key: Key.refreshToken)
        } else {
            Keychain.remove(Key.refreshToken)
        }
        try? Keychain.set(String(auth.expiresAtEpochSeconds), key: Key.expiresAt)
    }

    func loadAuth() -> RuntimeAuth? {
        guard let access = Keychain.get(Key.accessToken), !access.isEmpty else { return nil }
        let refresh = Keychain.get(Key.refreshToken).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = Int64(Keychain.get(Key.expiresAt) ?? "") ?? 0
        return RuntimeAuth(accessToken: access, refreshToken: refresh, expiresAtEpochSeconds: expiresAt)
    }

    func hasValidAccessToken() -> Bool {
        guard let auth = loadAuth() else { return false }
        guard auth.expiresAtEpochSeconds > 0 else { return false }
        let now = Int64(Date().timeIntervalSince1970)
        return auth.expiresAtEpochSeconds - now > Self.clockSkewToleranceSeconds
    }

    func hasStoredSession() -> Bool { loadAuth() != nil }

    func hasRefreshToken() -> Bool { loadAuth()?.refreshToken != nil }

    func clear() { Keychain.clearAll() }
}
