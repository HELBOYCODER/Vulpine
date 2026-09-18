// GuardianClient.swift
// Port of FoxyVPN's data/GuardianClient.kt — Mozilla Guardian control plane
// (proxy pass + entitlement status).

import Foundation

let guardianEndpointDefault = "https://vpn.mozilla.org"

struct GuardianError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum GuardianClient {
    /// `GuardianClient.fetchProxyPass(...)` parity.
    static func fetchProxyPass(endpoint: String, accessToken: String) async throws -> ProxyPass {
        let url = "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/v1/fpn/token"
        let (status, text) = try await sendAuthorized("GET", url: url, accessToken: accessToken, body: nil)
        switch status {
        case 401, 403:
            throw AppError.tokenInvalid
        case 429:
            throw AppError.quotaExceeded
        default:
            break
        }
        guard status == 200 else {
            throw AppError.http(status: status, body: String(text.prefix(2048)))
        }
        let body = try text.asJSON()
        let token = body.string("token")
        guard !token.isEmpty else {
            throw GuardianError(message: "proxy pass response did not contain a token")
        }
        let explicitExpiry = body.optionalInt64("expires_at")
        return ProxyPass(
            token: token,
            expiresAtEpochSeconds: explicitExpiry ?? JWT.expiryEpochSeconds(token),
            quotaMax: nil,
            quotaRemaining: nil,
            quotaReset: nil
        )
    }

    /// `GuardianClient.fetchUserInfo(...)` parity.
    static func fetchUserInfo(endpoint: String, accessToken: String) async throws -> Entitlement {
        let url = "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/v1/fpn/status"
        let (status, text) = try await sendAuthorized("GET", url: url, accessToken: accessToken, body: nil)
        guard status == 200 else {
            throw AppError.http(status: status, body: String(text.prefix(2048)))
        }
        let entitlement = try parseEntitlement(text.asJSON())
        guard entitlement.limitedBandwidth else { return entitlement }
        let pass = try? await fetchProxyPass(endpoint: endpoint, accessToken: accessToken)
        return entitlement.copyingQuotaRemaining(pass?.quotaRemaining)
    }

    /// `GuardianClient.activateGuardian(...)` parity.
    static func activateGuardian(endpoint: String, accessToken: String) async throws -> Entitlement {
        let url = "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/v1/fpn/activate"
        let (status, text) = try await sendAuthorized("POST", url: url, accessToken: accessToken, body: Data())
        guard status == 200 else {
            throw AppError.http(status: status, body: String(text.prefix(2048)))
        }
        return try parseEntitlement(text.asJSON())
    }

    private static func parseEntitlement(_ body: [String: Any]) throws -> Entitlement {
        Entitlement(
            subscribed: body.bool("subscribed"),
            uid: body.string("uid"),
            maxBytes: body.optionalInt64("maxBytes"),
            limitedBandwidth: body.bool("limited_bandwidth"),
            quotaRemaining: nil
        )
    }

    /// Retries once with a solved Fastly challenge when the server answers HTTP 406, exactly like
    /// the Android client's `authorizedRequest()`.
    private static func sendAuthorized(
        _ method: String,
        url: String,
        accessToken: String,
        body: Data?
    ) async throws -> (statusCode: Int, body: String) {
        func attempt() async throws -> (statusCode: Int, body: String) {
            try await HTTPClient.send(
                method,
                url: url,
                body: body,
                contentType: "application/json",
                authorization: "Bearer \(accessToken)"
            )
        }

        var response = try await attempt()
        if response.statusCode == 406 {
            try await FastlyChallengeSolver.shared.solveAndInstall()
            response = try await attempt()
        }
        return response
    }
}

private extension Entitlement {
    func copyingQuotaRemaining(_ value: Int64?) -> Entitlement {
        Entitlement(
            subscribed: subscribed,
            uid: uid,
            maxBytes: maxBytes,
            limitedBandwidth: limitedBandwidth,
            quotaRemaining: value ?? quotaRemaining
        )
    }
}
