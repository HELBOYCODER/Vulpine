// TunnelVerifier.swift
// v1.1.0 — end-to-end traffic check. After the tunnel comes up, performs a real
// SOCKS5 CONNECT through 127.0.0.1:<socksPort> and fetches Cloudflare's trace
// endpoint over the tunnel. This is what catches the "shows connected but no
// traffic flows" class of failure instead of silently faking success.

import Foundation
import Network

struct TunnelExitInfo: Equatable, Sendable {
    let ip: String
    let country: String
}

enum TunnelVerifier {
    struct VerifyError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let traceHost = "www.cloudflare.com"
    private static let tracePath = "/cdn-cgi/trace"

    /// Runs a full SOCKS5 handshake against the local bridge and fetches an HTTP page
    /// through the tunnel. Throws if any step fails or times out.
    static func verify(socksPort: Int, timeout: TimeInterval = 15) async throws -> TunnelExitInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TunnelExitInfo, Error>) in
            let state = VerificationState(continuation: continuation)
            let queue = DispatchQueue(label: "app.vulpine.verify", qos: .userInitiated)
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(integerLiteral: UInt16(clamping: socksPort)),
                using: .tcp
            )
            state.connection = connection

            queue.asyncAfter(deadline: .now() + timeout) {
                state.finish(.failure(VerifyError(message: "exit check timed out after \(Int(timeout))s")))
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    state.sendGreeting()
                case .failed(let error):
                    state.finish(.failure(VerifyError(message: "could not reach the local SOCKS bridge: \(error)")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func socksConnectRequest(host: String, port: UInt16) -> Data {
        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(host.utf8.count)])
        request.append(Data(host.utf8))
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        return request
    }

    /// Mutable handshake state, confined to the connection's dispatch queue.
    private final class VerificationState {
        private enum Phase { case greeting, connectReply, response }

        private var phase: Phase = .greeting
        private var buffer = Data()
        private var finished = false
        private let continuation: CheckedContinuation<TunnelExitInfo, Error>
        private var connectionRef: NWConnection?

        init(continuation: CheckedContinuation<TunnelExitInfo, Error>) {
            self.continuation = continuation
        }

        var connection: NWConnection? {
            get { connectionRef }
            set { connectionRef = newValue }
        }

        func finish(_ result: Result<TunnelExitInfo, Error>) {
            guard !finished else { return }
            finished = true
            connectionRef?.cancel()
            continuation.resume(with: result)
        }

        func sendGreeting() {
            send(Data([0x05, 0x01, 0x00]))
            phase = .greeting
            receiveMore()
        }

        private func sendConnect() {
            send(socksConnectRequest(host: traceHost, port: 80))
            phase = .connectReply
            receiveMore()
        }

        private func sendTraceRequest() {
            let httpRequest =
                "GET \(tracePath) HTTP/1.1\r\n"
                + "Host: \(traceHost)\r\n"
                + "User-Agent: Vulpine/1.1\r\n"
                + "Accept: */*\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            send(Data(httpRequest.utf8))
            phase = .response
            receiveMore()
        }

        private func receiveMore() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] content, _, isComplete, error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(VerifyError(message: "exit check connection failed: \(error)")))
                    return
                }
                if let content { self.buffer.append(content) }
                if self.process(isComplete: isComplete) { return }
                if isComplete {
                    self.finish(.failure(VerifyError(message: "tunnel closed before any traffic could flow")))
                    return
                }
                self.receiveMore()
            }
        }

        /// Returns true when the verification has finished (success or terminal failure).
        private func process(isComplete: Bool) -> Bool {
            switch phase {
            case .greeting:
                guard buffer.count >= 2 else { return false }
                guard buffer[0] == 0x05, buffer[1] == 0x00 else {
                    finish(.failure(VerifyError(message: "local SOCKS bridge refused the exit check")))
                    return true
                }
                buffer.removeSubrange(0..<2)
                sendConnect()
                return false
            case .connectReply:
                guard buffer.count >= 2 else { return false }
                guard buffer[0] == 0x05, buffer[1] == 0x00 else {
                    finish(.failure(VerifyError(message: "tunnel CONNECT was rejected by the upstream edge")))
                    return true
                }
                buffer.removeAll(keepingCapacity: true)
                sendTraceRequest()
                return false
            case .response:
                guard let text = String(data: buffer, encoding: .utf8), text.contains("loc=") else {
                    return false
                }
                var ip = ""
                var country = ""
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
                    if line.hasPrefix("loc=") { country = String(line.dropFirst(4)) }
                }
                finish(.success(TunnelExitInfo(ip: ip, country: country)))
                return true
            }
        }

        private func send(_ data: Data) {
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.finish(.failure(VerifyError(message: "exit check send failed: \(error)")))
            })
        }
    }
}
