// FxaAuthRepository.swift
// Port of FoxyVPN's data/FxaAuthRepository.kt — Firefox account sign-in with Mozilla's
// onepw protocol (PBKDF2 + HKDF authPW derivation), Hawk-authenticated session calls,
// email 2FA, and OAuth token exchange.

import Foundation
import CommonCrypto
import Combine

private let fxaAuthServer = "https://api.accounts.firefox.com/v1"
private let firefoxCclientId = "5882386c6d801776"
private let oauthScope = "profile https://identity.mozilla.com/apps/vpn"
private let protocolVersion = "identity.mozilla.com/picl/v1/"
private let pbkdf2Rounds = 1000
private let stretchedPwLen = 32
private let hkdfLen = 32
private let verificationMethodEmail2fa = "email-2fa"
private let fxaErrnoInvalidParameter = 107
private let fxaMaxChallengeAttempts = 5
private let defaultAccessTokenTtlSeconds: Int64 = 24 * 60 * 60

enum LoginStep { case credentials, twoFactor }

struct FxaApiError: Error, LocalizedError {
    let message: String
    let errno: Int?
    let statusCode: Int?

    var errorDescription: String? { message }

    /// FoxyVPN's `isPermanentRefreshRejection()` — a 400/401/403 means the session is gone.
    var isPermanentRefreshRejection: Bool {
        statusCode == 400 || statusCode == 401 || statusCode == 403
    }
}

struct FxaRefreshFailure: Error {
    let message: String
    let permanent: Bool
}

final class FxaAuthRepository: ObservableObject {
    static let shared = FxaAuthRepository()

    private let tokenStore: TokenStore
    private let challengeSolver: FastlyChallengeSolver

    /// Mirrors `pendingSessionToken` — held while an email-2FA code is outstanding.
    private var pendingSessionToken: String?

    init(
        tokenStore: TokenStore = .shared,
        challengeSolver: FastlyChallengeSolver = .shared
    ) {
        self.tokenStore = tokenStore
        self.challengeSolver = challengeSolver
    }

    // MARK: - Public API

    /// `startLogin(email, password)` parity. Returns true when email 2FA is required.
    @discardableResult
    func startLogin(email: String, password: String) async throws -> Bool {
        let data = try await loginAttempt(email: email, password: password)
        let sessionToken = data.string("sessionToken")
        pendingSessionToken = sessionToken
        let verified = data.bool("verified")
        if !verified { return true }
        try completeLogin(sessionToken: sessionToken)
        return false
    }

    /// `submitTwoFactorCode(code)` parity.
    @discardableResult
    func submitTwoFactorCode(_ code: String) async throws -> Bool {
        guard let sessionToken = pendingSessionToken else {
            throw GuardianError(message: "No pending FxA session. Start sign-in again.")
        }
        let body = ["code": code]
        _ = try await fxaDo("POST", path: "/session/verify_code", sessionToken: sessionToken, jsonBody: body)
        try completeLogin(sessionToken: sessionToken)
        return false
    }

    /// `restoreSession()` parity.
    func restoreSession() async -> SessionStatus {
        guard let stored = tokenStore.loadAuth() else { return .needsLogin }

        if stored.refreshToken == nil && !tokenStore.hasValidAccessToken() {
            tokenStore.clear()
            return .needsLogin
        }
        if tokenStore.hasValidAccessToken() { return .active }

        do {
            _ = try await ensureFreshAccessToken()
            return .active
        } catch let failure as FxaRefreshFailure {
            if failure.permanent {
                await AppLog.shared.warn("FxaAuthRepository", "FxA rejected the stored session; signing out")
                tokenStore.clear()
                return .needsLogin
            }
            await AppLog.shared.warn(
                "FxaAuthRepository",
                "could not renew the session right now; staying signed in"
            )
            return .unreachable
        } catch {
            await AppLog.shared.warn("FxaAuthRepository", "unexpected error while restoring the session")
            return .unreachable
        }
    }

    /// `ensureFreshAccessToken(force:)` parity.
    func ensureFreshAccessToken(force: Bool = false) async throws -> RuntimeAuth {
        guard let current = tokenStore.loadAuth() else {
            throw FxaRefreshFailure(message: "Not signed in", permanent: true)
        }
        if !force, tokenStore.hasValidAccessToken() { return current }

        guard let refreshToken = current.refreshToken else {
            throw FxaRefreshFailure(
                message: "The stored session has no refresh token; sign in again.",
                permanent: true
            )
        }

        let body: [String: Any] = [
            "client_id": firefoxCclientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": oauthScope,
        ]

        let tokenData: [String: Any]
        do {
            tokenData = try await fxaDo("POST", path: "/oauth/token", jsonBody: body)
        } catch let rejected as FxaApiError {
            throw FxaRefreshFailure(
                message: rejected.message,
                permanent: rejected.isPermanentRefreshRejection
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw FxaRefreshFailure(
                message: error.localizedDescription.isEmpty
                    ? "Could not reach the Firefox Accounts server"
                    : error.localizedDescription,
                permanent: false
            )
        }

        let accessToken = tokenData.string("access_token")
        guard !accessToken.isEmpty else {
            throw FxaRefreshFailure(message: "FxA returned no access token for the refresh grant", permanent: false)
        }

        let renewed = RuntimeAuth(
            accessToken: accessToken,
            refreshToken: tokenData.string("refresh_token").isEmpty ? refreshToken : tokenData.string("refresh_token"),
            expiresAtEpochSeconds: expiry(from: tokenData)
        )
        do {
            try tokenStore.saveAuth(renewed)
        } catch {
            await AppLog.shared.warn("FxaAuthRepository", "could not persist the renewed token", error: error)
        }
        return renewed
    }

    /// `currentAccessToken()` parity.
    func currentAccessToken() async -> String? {
        do {
            return try await ensureFreshAccessToken().accessToken
        } catch let failure as FxaRefreshFailure {
            return failure.permanent ? nil : tokenStore.loadAuth()?.accessToken
        } catch {
            return tokenStore.loadAuth()?.accessToken
        }
    }

    /// `refreshAccessToken()` parity.
    func refreshAccessToken() async -> RuntimeAuth? {
        do {
            return try await ensureFreshAccessToken(force: true)
        } catch {
            await AppLog.shared.warn("FxaAuthRepository", "access token renewal failed", error: error)
            return nil
        }
    }

    func signOut() {
        pendingSessionToken = nil
        tokenStore.clear()
    }

    // MARK: - Internals

    private func completeLogin(sessionToken: String) throws {
        let tokenData = try await fxaDo(
            "POST",
            path: "/oauth/token",
            sessionToken: sessionToken,
            jsonBody: [
                "client_id": firefoxCclientId,
                "grant_type": "fxa-credentials",
                "scope": oauthScope,
                "access_type": "offline",
            ]
        )
        try tokenStore.saveAuth(
            RuntimeAuth(
                accessToken: tokenData.string("access_token"),
                refreshToken: tokenData.string("refresh_token").isEmpty ? nil : tokenData.string("refresh_token"),
                expiresAtEpochSeconds: expiry(from: tokenData)
            )
        )
        pendingSessionToken = nil
    }

    private func loginAttempt(email: String, password: String, withVerificationMethod: Bool = true)
        async throws -> [String: Any]
    {
        var body: [String: Any] = [
            "email": email,
            "authPW": deriveAuthPw(email: email, password: password),
        ]
        if withVerificationMethod { body["verificationMethod"] = verificationMethodEmail2fa }

        do {
            return try await fxaDo("POST", path: "/account/login", jsonBody: body)
        } catch let error as FxaApiError {
            // Older FxA servers reject the unknown field with errno 107 — retry without it.
            if error.errno == fxaErrnoInvalidParameter, withVerificationMethod {
                return try await loginAttempt(email: email, password: password, withVerificationMethod: false)
            }
            throw error
        }
    }

    /// `fxaDo(...)` parity — one request, with a Fastly challenge retry and Hawk auth.
    private func fxaDo(
        _ method: String,
        path: String,
        sessionToken: String? = nil,
        jsonBody: [String: Any]
    ) async throws -> [String: Any] {
        let url = fxaAuthServer + path
        guard let urlObject = URL(string: url),
              let components = URLComponents(url: urlObject, resolvingAgainstBaseURL: false)
        else { throw AppError.transport("Invalid FxA URL: \(url)") }

        let bodyBytes = (try? JSONSerialization.data(withJSONObject: jsonBody)) ?? Data()
        var tokenId: String?
        var hmacKey: Data?
        if let sessionToken {
            let credentials = deriveHawkCredentials(sessionTokenHex: sessionToken)
            tokenId = credentials.id
            hmacKey = credentials.key
        }

        func buildRequest() -> URLRequest {
            var request = URLRequest(url: urlObject)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(mozillaVpnUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let _, let tokenId, let hmacKey {
                request.setValue(
                    hawkHeader(
                        method: method,
                        components: components,
                        tokenId: tokenId,
                        hmacKey: hmacKey,
                        body: bodyBytes
                    ),
                    forHTTPHeaderField: "Authorization"
                )
            }
            request.httpBody = bodyBytes
            return request
        }

        var attempt = 0
        var lastError: Error?
        while attempt < fxaMaxChallengeAttempts {
            attempt += 1
            do {
                let (data, response) = try await HTTPClient.shared.data(for: buildRequest())
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AppError.transport("Non-HTTP response from FxA")
                }
                if httpResponse.statusCode == 406 && attempt < fxaMaxChallengeAttempts {
                    try await challengeSolver.solveAndInstall()
                    continue
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                if httpResponse.statusCode >= 400 {
                    let parsed = try? text.asJSON()
                    let errno = parsed?["errno"] as? Int
                    let message = parsed?.string("message").isEmpty == false
                        ? parsed!.string("message")
                        : (text.isEmpty ? "HTTP \(httpResponse.statusCode)" : text)
                    throw FxaApiError(message: message, errno: errno, statusCode: httpResponse.statusCode)
                }
                if text.isEmpty { return [:] }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AppError.transport("Could not parse FxA JSON response")
                }
                return object
            } catch let error as FxaApiError {
                throw error
            } catch let error as CancellationError {
                throw error
            } catch {
                if attempt < fxaMaxChallengeAttempts {
                    lastError = error
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError.map { AppError.transport($0.localizedDescription) }
            ?? AppError.transport("FxA request failed")
    }

    private func expiry(from tokenData: [String: Any]) -> Int64 {
        let expiresIn = tokenData.int("expires_in")
        return Int64(Date().timeIntervalSince1970) + (expiresIn > 0 ? Int64(expiresIn) : defaultAccessTokenTtlSeconds)
    }

    // MARK: - Mozilla onepw protocol

    /// `deriveQuickStretch(...)` + `deriveAuthPw(...)` parity.
    private func deriveAuthPw(email: String, password: String) -> String {
        let salt = "\(protocolVersion)quickStretch:\(email)"
        let quickStretched = pbkdf2HmacSha256(
            password: Data(password.utf8),
            salt: Data(salt.utf8),
            iterations: pbkdf2Rounds,
            keyLengthBytes: stretchedPwLen
        )
        return hkdf(quickStretched, info: "\(protocolVersion)authPW", length: hkdfLen).hexEncoded
    }

    /// `deriveHawkCredentials(...)` parity — 64 bytes of HKDF output split into id + key.
    private func deriveHawkCredentials(sessionTokenHex: String) -> (id: String, key: Data) {
        let sessionToken = Data(hex: sessionTokenHex) ?? Data()
        let expanded = hkdf(sessionToken, info: "\(protocolVersion)sessionToken", length: 64)
        let id = expanded.prefix(32).hexEncoded
        let key = expanded.suffix(32)
        return (id, Data(key))
    }

    /// `hawkHeader(...)` parity — Hawk 1 header over method, path, host, port and payload hash.
    private func hawkHeader(
        method: String,
        components: URLComponents,
        tokenId: String,
        hmacKey: Data,
        body: Data
    ) -> String {
        let ts = String(Int64(Date().timeIntervalSince1970))
        var nonceBytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, 6, &nonceBytes)
        let nonce = Data(nonceBytes).base64URLEncoded

        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }

        var payloadHash = ""
        if !body.isEmpty {
            let prefix = "hawk.1.payload\napplication/json\n"
            var payload = Data(prefix.utf8)
            payload.append(body)
            payload.append("\n".data(using: .utf8)!)
            payloadHash = sha256(payload).base64EncodedString()
        }

        let host = components.host ?? ""
        let port = components.port ?? 443
        let normalized =
            "hawk.1.header\n\(ts)\n\(nonce)\n\(method.uppercased())\n\(path)\n\(host)\n\(port)\n\(payloadHash)\n\n"
        let mac = Data(hmacSha256(key: hmacKey, data: Data(normalized.utf8))).base64EncodedString()

        var header = "Hawk id=\"\(tokenId)\", ts=\"\(ts)\", nonce=\"\(nonce)\", mac=\"\(mac)\""
        if !payloadHash.isEmpty { header += ", hash=\"\(payloadHash)\"" }
        return header
    }
}

// MARK: - Crypto primitives (hmacSha256 / hkdf / pbkdf2 parity)

func hmacSha256(key: Data, data: Data) -> Data {
    var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { dataPtr in
        key.withUnsafeBytes { keyPtr in
            CCHmac(
                CCHmacAlgorithm(kCCHmacAlgSHA256),
                keyPtr.baseAddress, key.count,
                dataPtr.baseAddress, data.count,
                &out
            )
        }
    }
    return Data(out)
}

func hkdf(_ ikm: Data, info: String, length: Int, salt: Data = Data(count: 32)) -> Data {
    let prk = hmacSha256(key: salt, data: ikm)
    let infoBytes = Data(info.utf8)
    var result = Data(count: length)
    var previousBlock = Data()
    var generated = 0
    var counter: UInt8 = 1
    while generated < length {
        var blockInput = Data()
        blockInput.append(previousBlock)
        blockInput.append(infoBytes)
        blockInput.append(counter)
        let block = hmacSha256(key: prk, data: blockInput)
        let toCopy = min(block.count, length - generated)
        result.replaceSubrange(generated..<(generated + toCopy), with: block.prefix(toCopy))
        generated += toCopy
        previousBlock = block
        counter += 1
    }
    return result
}

func pbkdf2HmacSha256(password: Data, salt: Data, iterations: Int, keyLengthBytes: Int) -> Data {
    var derivedKey = [UInt8](repeating: 0, count: keyLengthBytes)
    password.withUnsafeBytes { pwPtr in
        salt.withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derivedKey, keyLengthBytes
            )
        }
    }
    return Data(derivedKey)
}
