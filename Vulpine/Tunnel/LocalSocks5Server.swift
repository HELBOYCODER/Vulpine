// LocalSocks5Server.swift
// Port of FoxyVPN's vpn/socks/LocalSocks5Server.kt — an RFC 1928 SOCKS5 server listening
// on 127.0.0.1. Bridges incoming client TCP connections into the HTTP/2 upstream session
// via CONNECT streams.
//
// Powered by Network.framework's NWListener (macOS native socket listener).

import Foundation
import Network

final class LocalSocks5Server {
    let port: Int
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.vulpine.socks5", qos: .userInitiated)

    var sessionProvider: (() -> H2UpstreamSession?)?
    var onTrafficSample: ((Int64, Int64) -> Void)?

    private var txBytes: Int64 = 0
    private var rxBytes: Int64 = 0
    private let lock = NSLock()

    init(port: Int = 10808) {
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleClientConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Task { await AppLog.shared.info("SOCKS5", "listening on 127.0.0.1:\(self.port)") }
            case .failed(let err):
                Task { await AppLog.shared.error("SOCKS5", "listener failed", error: err) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleClientConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Step 1: SOCKS5 greeting (0x05, NMETHODS, METHODS...).
        connection.receive(minimumIncompleteLength: 2, maximumLength: 257) { [weak self] content, _, isComplete, _ in
            guard let self, let content, content.count >= 2, content[0] == 0x05 else {
                connection.cancel()
                return
            }
            // Method selection: 0x00 (NO AUTHENTICATION REQUIRED).
            let reply = Data([0x05, 0x00])
            connection.send(content: reply, completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                self?.readRequest(connection)
            })
        }
    }

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] content, _, _, _ in
            guard let self, let content, content.count >= 4 else {
                connection.cancel()
                return
            }
            guard content[0] == 0x05, content[1] == 0x01 else {
                // Command not supported (we only bridge CONNECT 0x01).
                self.sendSocksReply(connection, replyCode: 0x07)
                return
            }

            guard let (host, port) = self.parseTarget(content) else {
                self.sendSocksReply(connection, replyCode: 0x08)
                return
            }

            guard let session = self.sessionProvider?(), session.isConnected else {
                self.sendSocksReply(connection, replyCode: 0x05)
                return
            }

            Task {
                do {
                    let stream = try await session.openStream(targetHost: host, targetPort: port)
                    self.sendSocksReply(connection, replyCode: 0x00)
                    self.bridge(client: connection, stream: stream, session: session)
                } catch UpstreamError.unauthenticated {
                    self.sendSocksReply(connection, replyCode: 0x01)
                } catch UpstreamError.rejected {
                    self.sendSocksReply(connection, replyCode: 0x05)
                } catch {
                    self.sendSocksReply(connection, replyCode: 0x04)
                }
            }
        }
    }

    private func parseTarget(_ data: Data) -> (String, Int)? {
        guard data.count >= 7 else { return nil }
        let addrType = data[3]
        var offset = 4
        let host: String

        switch addrType {
        case 0x01: // IPv4
            guard data.count >= 10 else { return nil }
            host = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
            offset = 8
        case 0x03: // Domain name
            let len = Int(data[4])
            guard data.count >= 5 + len + 2 else { return nil }
            guard let domain = String(data: data.subdata(in: 5..<(5 + len)), encoding: .ascii) else { return nil }
            host = domain
            offset = 5 + len
        case 0x04: // IPv6
            guard data.count >= 22 else { return nil }
            var parts = [String]()
            for i in stride(from: 4, to: 20, by: 2) {
                let part = (UInt16(data[i]) << 8) | UInt16(data[i + 1])
                parts.append(String(part, radix: 16))
            }
            host = parts.joined(separator: ":")
            offset = 20
        default:
            return nil
        }

        let port = (Int(data[offset]) << 8) | Int(data[offset + 1])
        return (host, port)
    }

    private func sendSocksReply(_ connection: NWConnection, replyCode: UInt8) {
        let reply = Data([0x05, replyCode, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        connection.send(content: reply, completion: .contentProcessed { _ in
            if replyCode != 0x00 { connection.cancel() }
        })
    }

    /// Bi-directional pump between the local NWConnection and the H2 stream.
    private func bridge(client: NWConnection, stream: H2Stream, session: H2UpstreamSession) {
        var closed = false
        let closeBoth = {
            guard !closed else { return }
            closed = true
            client.cancel()
            session.closeStream(streamId: stream.streamId)
        }

        stream.onData = { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            self.rxBytes += Int64(data.count)
            self.lock.unlock()
            client.send(content: data, completion: .contentProcessed { error in
                if error != nil { closeBoth() }
            })
        }

        stream.onClose = { closeBoth() }

        func pumpClientToUpstream() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] content, _, isComplete, error in
                guard let self, !closed else { return }
                if let content, !content.isEmpty {
                    self.lock.lock()
                    self.txBytes += Int64(content.count)
                    self.lock.unlock()
                    session.sendData(streamId: stream.streamId, data: content, endStream: isComplete)
                }
                if isComplete || error != nil {
                    closeBoth()
                    return
                }
                pumpClientToUpstream()
            }
        }
        pumpClientToUpstream()
    }

    /// Cumulative (tx, rx) bytes transferred through this server.
    func readStats() -> (tx: Int64, rx: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (txBytes, rxBytes)
    }
}
