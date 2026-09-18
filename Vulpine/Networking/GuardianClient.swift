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
        let response = try await sendAuthorized("GET", url: url, accessToken: accessToken, body: nil)
        switch response.statusCode {
        case 401, 403:
            throw AppError.tokenInvalid
        case 429:
            throw AppError.quotaExceeded
        default:
            break
        }
        guard response.statusCode == 200 else {
            throw AppError.http(status: response.statusCode, body: String(response.body.prefix(2048)))
        }
        let body = try response.body.asJSON()
        let token = body.string("token")
        guard !token.isEmpty else {
            throw GuardianError(message: "proxy pass response did not contain a token")
        }
        let explicitExpiry = body.optionalInt64("expires_at")
        return ProxyPass(
            token: token,
            expiresAtEpochSeconds: explicitExpiry ?? JWT.expiryEpochSeconds(token),
            quotaMax: response.headerInt64("X-Quota-Limit"),
            quotaRemaining: response.headerInt64("X-Quota-Remaining"),
            quotaReset: response.headerInt64("X-Quota-Reset")
        )
    }

    /// The whole "get me a proxy pass" sequence, including the enrolment step that the
    /// Android client performs in `FoxyVpnService.mintProxyPass()`:
    ///
    ///   fetchProxyPass -> (401/403) -> activateGuardian -> fetchProxyPass
    ///
    /// `activateGuardian` is what enrols a Firefox account in the free (limited-bandwidth)
    /// Guardian plan. Without it a fresh/free account is rejected with 401 and the tunnel can
    /// never come up — v1.1.0 shipped `activateGuardian` but never called it, so every free
    /// account failed at the very first step with "Firefox rejected the saved session".
    static func mintProxyPass(endpoint: String, accessToken: String) async throws -> ProxyPass {
        do {
            return try await fetchProxyPass(endpoint: endpoint, accessToken: accessToken)
        } catch AppError.tokenInvalid {
            await AppLog.shared.warn(
                "Guardian",
                "proxy pass was rejected; activating the Guardian entitlement for this account and retrying"
            )
            let entitlement = try await activateGuardian(endpoint: endpoint, accessToken: accessToken)
            await AppLog.shared.info(
                "Guardian",
                "entitlement activated: subscribed=\(entitlement.subscribed) "
                    + "limitedBandwidth=\(entitlement.limitedBandwidth) "
                    + "maxBytes=\(entitlement.maxBytes.map(String.init) ?? "unlimited")"
            )
            return try await fetchProxyPass(endpoint: endpoint, accessToken: accessToken)
        }
    }


    /// `GuardianClient.fetchUserInfo(...)` parity.
    static func fetchUserInfo(endpoint: String, accessToken: String) async throws -> Entitlement {
        let url = "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/v1/fpn/status"
        let response = try await sendAuthorized("GET", url: url, accessToken: accessToken, body: nil)
        guard response.statusCode == 200 else {
            throw AppError.http(status: response.statusCode, body: String(response.body.prefix(2048)))
        }
        let entitlement = try parseEntitlement(response.body.asJSON())
        guard entitlement.limitedBandwidth else { return entitlement }
        let pass = try? await fetchProxyPass(endpoint: endpoint, accessToken: accessToken)
        return entitlement.copyingQuotaRemaining(pass?.quotaRemaining)
    }

    /// `GuardianClient.activateGuardian(...)` parity.
    static func activateGuardian(endpoint: String, accessToken: String) async throws -> Entitlement {
        let url = "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/v1/fpn/activate"
        let response = try await sendAuthorized("POST", url: url, accessToken: accessToken, body: Data())
        guard response.statusCode == 200 else {
            throw AppError.http(status: response.statusCode, body: String(response.body.prefix(2048)))
        }
        return try parseEntitlement(response.body.asJSON())
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
    ) async throws -> HTTPResponse {
        func attempt() async throws -> HTTPResponse {
            try await HTTPClient.sendDetailed(
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
