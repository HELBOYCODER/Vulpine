// Base64URL.swift
// RFC 4648 base64url helpers (replaces android.util.Base64 URL_SAFE/NO_WRAP).

import Foundation

extension String {
    /// Standard base64url alphabet without padding (Kotlin `Base64.URL_SAFE or Base64.NO_WRAP` parity).
    var base64URLEncoded: String {
        Data(utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    /// Decodes base64url **and** standard base64, tolerant of missing padding
    /// (mirrors Kotlin's Base64.decode(..., URL_SAFE | NO_WRAP) plus real-world leniency).
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// JWT payload decoder — equivalent of FoxyVPN's `jwtExpiryEpochSeconds()`.
enum JWT {
    /// Returns the `exp` claim as an epoch-seconds timestamp, or nil if absent/unparseable.
    static func expiryEpochSeconds(_ token: String) -> Int64? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        guard let exp = object["exp"] as? NSNumber else { return nil }
        let value = exp.int64Value
        return value > 0 ? value : nil
    }
}
