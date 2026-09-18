// HTTPClient.swift
// URLSession-fronted HTTP used by the control plane (FxA, Guardian, Remote Settings).
// Port of FoxyVPN's ControlPlaneHttp.kt — minus Android's VpnService.protect(), which macOS
// handles by marking the socket as "outside the tunnel" via NEProvider's bypass logic.

import Foundation

let mozillaVpnUserAgent = "MozillaVPN/2.35.0 (sys:macos; iap:true)"

/// Errors surfaced to the UI.
enum AppError: LocalizedError {
    case quotaExceeded
    case tokenInvalid
    case http(status: Int, body: String)
    case transport(String)
    case challenge(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .quotaExceeded:
            return "Account proxy quota exceeded — Mozilla resets it monthly."
        case .tokenInvalid:
            return "Firefox rejected the saved session. Please sign in again."
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .transport(let message):
            return message
        case .challenge(let message):
            return "Fastly challenge failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// Full HTTP response, headers included. Guardian reports the free-plan quota in
/// `X-Quota-Limit` / `X-Quota-Remaining` / `X-Quota-Reset`, so the raw headers are needed
/// to show real numbers instead of a hard-coded guess.
struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: String

    /// Case-insensitive header lookup (URLSession already lowercases, this keeps callers safe).
    func header(_ name: String) -> String? { headers[name.lowercased()] }

    func headerInt64(_ name: String) -> Int64? { header(name).flatMap { Int64($0) } }
}

/// Custom-session URLSession delegate so every request can bypass the active tunnel.
final class DirectNetworkDelegate: NSObject, URLSessionDelegate {
    static let shared = DirectNetworkDelegate()

    /// URLSession has no public "exclude from VPN" API, so this delegate runs on a dedicated
    /// session whose configuration is created before the tunnel starts and which we keep for the
    /// app lifetime. NEPacketTunnelProvider routing rules exclude this process's traffic.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}

enum HTTPClient {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": mozillaVpnUserAgent,
            "Accept": "application/json",
        ]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: DirectNetworkDelegate.shared, delegateQueue: nil)
    }()

    /// Sends a request and returns (statusCode, body). Throws `AppError.transport` on network failure.
    static func send(
        _ method: String,
        url: String,
        body: Data? = nil,
        contentType: String = "application/json",
        authorization: String? = nil,
        customUserAgent: String? = nil,
        additionalHeaders: [String: String] = [:],
        session: URLSession = HTTPClient.shared
    ) async throws -> (statusCode: Int, body: String) {
        let response = try await sendDetailed(
            method,
            url: url,
            body: body,
            contentType: contentType,
            authorization: authorization,
            customUserAgent: customUserAgent,
            additionalHeaders: additionalHeaders,
            session: session
        )
        return (response.statusCode, response.body)
    }

    /// Same as `send(...)` but keeps the response headers, which Guardian uses for quota reporting.
    static func sendDetailed(
        _ method: String,
        url: String,
        body: Data? = nil,
        contentType: String = "application/json",
        authorization: String? = nil,
        customUserAgent: String? = nil,
        additionalHeaders: [String: String] = [:],
        session: URLSession = HTTPClient.shared
    ) async throws -> HTTPResponse {
        guard let request = makeRequest(
            method: method,
            url: url,
            body: body,
            contentType: contentType,
            authorization: authorization,
            customUserAgent: customUserAgent,
            additionalHeaders: additionalHeaders
        ) else {
            throw AppError.transport("Invalid URL: \(url)")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.transport("Non-HTTP response from \(url)")
            }
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key.lowercased()] = String(describing: value)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: text)
        } catch let error as AppError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw AppError.cancelled
        } catch {
            throw AppError.transport(error.localizedDescription)
        }
    }

    static func makeRequest(
        method: String,
        url: String,
        body: Data?,
        contentType: String,
        authorization: String?,
        customUserAgent: String?,
        additionalHeaders: [String: String]
    ) -> URLRequest? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let userAgent = customUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = body
        } else if method != "GET" && method != "HEAD" {
            request.httpBody = Data()
        }
        return request
    }
}
