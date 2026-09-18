// FastlyChallengeSolver.swift
// Port of FoxyVPN's data/FastlyChallengeSolver.kt — Fastly's bot challenge (proof-of-work +
// private-access-token rounds), solved locally without a browser.

import Foundation
import CommonCrypto

enum FastlyChallengeError: Error, LocalizedError {
    case generic(String)

    var errorDescription: String? {
        if case .generic(let message) = self { return "Fastly challenge failed: \(message)" }
        return nil
    }
}

final class FastlyChallengeSolver {
    static let shared = FastlyChallengeSolver()

    private let solveTimeoutSeconds: TimeInterval = 60
    private let maxPostBackRounds = 3
    private let solverUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    private let powAlphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    private let htmlAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    private let challengePrefixRegex = try? NSRegularExpression(pattern: "/_fs-ch-[A-Za-z0-9]+")
    private let initCallRegex = try? NSRegularExpression(
        pattern: "init\\((\\[[^\\]]*\\]),\\s*\"([^\"]+)\",\\s*\"([^\"]+)\""
    )

    private let queue = DispatchQueue(label: "app.vulpine.fastly-solver")

    private final class NoChallengePage: Error {}

    /// Public entry point — mirrors `solveAndInstall()`.
    func solveAndInstall() async throws {
        var lastError: FastlyChallengeError?
        for base in ["https://api.accounts.firefox.com", "https://accounts.firefox.com"] {
            do {
                try await solveOnHost(base)
                return
            } catch is NoChallengePage {
                continue
            } catch let error as FastlyChallengeError {
                lastError = error
            }
        }
        throw lastError ?? FastlyChallengeError.generic("host did not serve a Fastly challenge page")
    }

    private func baseOrigin(_ prefixUrl: String) -> String {
        let idx = prefixUrl.range(of: "/_fs-ch-")
        return idx.map { String(prefixUrl[..<prefixUrl.distance(from: prefixUrl.startIndex, to: $0.lowerBound)]) }
            ?? prefixUrl
    }

    /// Proof-of-work: find a two-character suffix so that SHA-256(base + suffix) matches the target.
    private func solvePow(base: String, targetHex: String) -> String? {
        guard let target = Data(hex: targetHex), target.count == 32 else { return nil }
        var context = CC_SHA256_CTX()
        for a in powAlphabet {
            for b in powAlphabet {
                let suffix = String(a) + String(b)
                var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
                CC_SHA256_Init(&context)
                CC_SHA256_Update(&context, base, CC_LONG(base.utf8.count))
                CC_SHA256_Update(&context, suffix, CC_LONG(suffix.utf8.count))
                digest.withUnsafeMutableBytes { ptr in
                    _ = CC_SHA256_Final(ptr.bindMemory(to: UInt8.self).baseAddress, &context)
                }
                if digest == target { return suffix }
            }
        }
        return nil
}

    private func fetchText(
        _ url: String,
        accept: String,
        userAgent: String,
        session: HTTPClient.Session
    ) async throws -> String {
        let request = HTTPClient.makeRequest(
            method: "GET",
            url: url,
            body: nil,
            contentType: "text/plain",
            authorization: nil,
            customUserAgent: userAgent,
            additionalHeaders: ["Accept": accept]
        )
        do {
            let (data, _) = try await session.data(for: request!)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw FastlyChallengeError.generic("GET \(url) failed: \(error.localizedDescription)")
        }
    }

    private func fetchChallengePage(_ url: String, session: HTTPClient.Session) async throws -> (String, Bool) {
        let body = try await fetchText(url, accept: htmlAccept, userAgent: solverUserAgent, session: session)
        let isChallenge = body.contains("/_fs-ch-") && body.contains("Client Challenge")
        return (body, isChallenge)
    }

    private func parseChallengeInit(_ script: String) throws -> ([Any], String) {
        guard let regex = initCallRegex else { throw FastlyChallengeError.generic("regex unavailable") }
        let nsScript = script as NSString
        let matches = regex.matches(in: script, range: NSRange(location: 0, length: nsScript.length))
        guard let last = matches.last,
              last.numberOfRanges >= 3
        else { throw FastlyChallengeError.generic("challenge init() call not found in script") }

        let challengesJSON = nsScript.substring(with: last.range(at: 1))
        guard let challenges = try? JSONSerialization.jsonObject(with: Data(challengesJSON.utf8)) as? [Any],
              !challenges.isEmpty
        else { throw FastlyChallengeError.generic("could not parse challenge list") }
        let token = nsScript.substring(with: last.range(at: 2))
        return (challenges, token)
    }

    private func fetchPat(_ prefixUrl: String, token: String, session: HTTPClient.Session) async throws -> String {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let url = "\(prefixUrl)/pat?token=\(encoded)"
        let request = HTTPClient.makeRequest(
            method: "POST",
            url: url,
            body: Data(),
            contentType: "application/json",
            authorization: nil,
            customUserAgent: solverUserAgent,
            additionalHeaders: [
                "Accept": "text/plain",
                "Origin": baseOrigin(prefixUrl),
            ]
        )
        guard let request else { throw FastlyChallengeError.generic("invalid PAT URL") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FastlyChallengeError.generic("non-HTTP PAT response")
            }
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 { return "" }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw FastlyChallengeError.generic("PAT request returned HTTP \(httpResponse.statusCode)")
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let auth = object["auth"] as? String, !auth.isEmpty
            else { throw FastlyChallengeError.generic("could not parse PAT response") }
            return auth
        } catch let error as FastlyChallengeError {
            throw error
        } catch {
            throw FastlyChallengeError.generic("PAT request failed: \(error.localizedDescription)")
        }
    }

    private func clientMetricsAnswer() -> [String: Any] {
        [
            "ty": "clientmetrics",
            "webdriver": false,
            "bot_detection_result": [
                "bot_detected": false,
                "bot_kind": NSNull(),
            ] as [String: Any],
            "browser_metrics": [
                "client_data": "{}",
                "error_trace": NSNull(),
            ] as [String: Any],
            "detector_results": [String: Any](),
            "v": 2,
        ]
    }

    private func answerChallenge(
        _ challenge: [String: Any],
        prefixUrl: String,
        token: String,
        session: HTTPClient.Session
    ) async throws -> [String: Any] {
        let data = challenge["data"] as? [String: Any] ?? [:]
        switch challenge["ty"] as? String {
        case "pow":
            let base = data.string("base")
            guard let answer = solvePow(base: base, targetHex: data.string("hash")) else {
                throw FastlyChallengeError.generic("no proof-of-work solution found for base \(base)")
            }
            return [
                "ty": "pow",
                "base": base,
                "answer": answer,
                "hmac": data.string("hmac"),
                "expires": data.string("expires"),
            ]
        case "pat":
            let auth = try await fetchPat(prefixUrl, token: token, session: session)
            return ["ty": "pat", "auth": auth]
        case "clientmetrics":
            return clientMetricsAnswer()
        case let type:
            throw FastlyChallengeError.generic(
                "unsupported Fastly challenge type '\(type ?? "nil")' (captcha cannot be solved automatically)"
            )
        }
    }

    private func solveOnHost(_ base: String) async throws {
        let config = HTTPClient.ephemeralConfig
        let session = HTTPClient.Session(
            configuration: config,
            delegate: nil,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let pageUrl = "\(base)/"
        let (page, isChallenge) = try await fetchChallengePage(pageUrl, session: session)
        guard isChallenge else { throw NoChallengePage() }

        guard let prefixMatch = challengePrefixRegex?.firstMatch(
            in: page,
            range: NSRange(location: 0, length: (page as NSString).length)
        ) else {
            throw FastlyChallengeError.generic("challenge asset prefix not found on \(base)")
        }
        let prefix = (page as NSString).substring(with: prefixMatch.range)
        let prefixUrl = base + prefix

        let script = try await fetchText(
            "\(prefixUrl)/script.js?reload=true",
            accept: htmlAccept,
            userAgent: solverUserAgent,
            session: session
        )
        var (challenges, token) = try parseChallengeInit(script)

        for _ in 0..<maxPostBackRounds {
            var answers: [Any] = []
            for challenge in challenges {
                guard let object = challenge as? [String: Any] else { continue }
                answers.append(try await answerChallenge(object, prefixUrl: prefixUrl, token: token, session: session))
            }
            let postBody = try JSONSerialization.data(
                withJSONObject: ["token": token, "data": answers],
                options: []
            )
            let request = HTTPClient.makeRequest(
                method: "POST",
                url: "\(prefixUrl)/fst-post-back",
                body: postBody,
                contentType: "application/json",
                authorization: nil,
                customUserAgent: solverUserAgent,
                additionalHeaders: [
                    "Accept": "application/json",
                    "Origin": baseOrigin(prefixUrl),
                ]
            )
            guard let request else { throw FastlyChallengeError.generic("invalid post-back URL") }
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode)
                else {
                    throw FastlyChallengeError.generic("challenge post-back returned an error status")
                }
                let body = try data.asJSON()
                if body.string("status") == "success" {
                    let (_, stillChallenged) = try await fetchChallengePage(pageUrl, session: session)
                    if stillChallenged {
                        throw FastlyChallengeError.generic("challenge cookie not accepted on this exit IP")
                    }
                    HTTPCookieStorage.shared.setChallengeCookies(body: body)
                    return
                }
                guard let nextChallenges = body["ch"] as? [Any], !nextChallenges.isEmpty,
                      let nextToken = body["tok"] as? String, !nextToken.isEmpty
                else {
                    throw FastlyChallengeError.generic("unexpected post-back response")
                }
                challenges = nextChallenges
                token = nextToken
            } catch let error as FastlyChallengeError {
                throw error
            } catch {
                throw FastlyChallengeError.generic("post-back failed: \(error.localizedDescription)")
            }
        }
        throw FastlyChallengeError.generic("Fastly challenge did not complete within \(maxPostBackRounds) rounds")
    }
}

extension HTTPClient {
    /// Solver session: a plain ephemeral URLSession (cookies stored in the shared cookie storage).
    typealias Session = URLSession

    static var ephemeralConfig: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }
}

extension HTTPCookieStorage {
    /// Writes the challenge cookie into the shared cookie storage for `firefox.com`, matching
    /// FoxyVPN's `installChallengeCookies()` which pins it to that domain.
    fileprivate func setChallengeCookies(body: [String: Any]) {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            if cookie.domain.contains("firefox.com") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        // The challenge response sets the cookie via Set-Cookie on the actual response; when the
        // URLSession cookie store already captured it there is nothing left to do here.
        guard let token = body["token"] as? String, !token.isEmpty else { return }
        if let cookie = HTTPCookie(
            properties: [
                .domain: ".firefox.com",
                .path: "/",
                .name: "fastly-challenge",
                .value: token,
                .secure: "TRUE",
            ]
        ) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}
