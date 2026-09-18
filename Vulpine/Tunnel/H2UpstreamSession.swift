// H2UpstreamSession.swift
// Port of FoxyVPN's vpn/upstream/H2UpstreamSession.kt — carries the device's tunneled
// TCP streams across a single multiplexed HTTP/2 connection to Fastly's edge via CONNECT.
//
// Network.framework (NWConnection) powers the TLS transport with ALPN ["h2"]. Streams
// are multiplexed as RFC 9113 HTTP/2 streams using HTTP2Frame and HPACK.

import Foundation
import Network
import Security

enum UpstreamError: LocalizedError {
    case rejected(statusCode: Int, authority: String)
    case timeout(authority: String)
    case unauthenticated
    case streamClosed
    case sessionDead

    var errorDescription: String? {
        switch self {
        case .rejected(let status, let auth): return "Upstream edge rejected CONNECT \(auth) (HTTP \(status))"
        case .timeout(let auth): return "Timeout connecting to \(auth) via upstream edge"
        case .unauthenticated: return "Upstream session unauthenticated"
        case .streamClosed: return "Stream closed"
        case .sessionDead: return "Upstream session is closed or dead"
        }
    }
}

/// One multiplexed TCP stream carried inside the HTTP/2 tunnel.
final class H2Stream {
    let streamId: Int32
    let targetAuthority: String
    private(set) var remoteWindow: Int32 = 65_535

    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var onConnected: ((Int) -> Void)?

    private let lock = NSLock()

    init(streamId: Int32, targetAuthority: String) {
        self.streamId = streamId
        self.targetAuthority = targetAuthority
    }

    func adjustRemoteWindow(by delta: Int32) {
        lock.lock()
        defer { lock.unlock() }
        remoteWindow += delta
    }
}

final class H2UpstreamSession {
    let edgeHost: String
    let edgePort: Int
    private var bearerToken: String
    private let customDnsServer: String?

    private var connection: NWConnection?
    private let decoder = HTTP2FrameDecoder()
    private let hpackDecoder = HPACKDecoder()
    private let queue = DispatchQueue(label: "app.vulpine.h2", qos: .userInitiated)

    private var nextStreamId: Int32 = 1
    private var streams: [Int32: H2Stream] = [:]
    private var connectionRemoteWindow: Int32 = 65_535

    @Published private(set) var isConnected = false
    private var isClosing = false
    private let lock = NSLock()

    var onSessionDead: (() -> Void)?

    init(edgeHost: String, edgePort: Int, bearerToken: String, customDnsServer: String? = nil) {
        self.edgeHost = edgeHost
        self.edgePort = edgePort
        self.bearerToken = bearerToken
        self.customDnsServer = customDnsServer
    }

    func updateBearerToken(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        self.bearerToken = token
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.startConnection(continuation)
            }
        }
    }

    private func startConnection(_ continuation: CheckedContinuation<Void, Error>) {
        let tlsParams = NWParameters.tls
        let tlsOptions = tlsParams.defaultProtocolStack.applicationProtocols[0] as! NWProtocolTLS.Options
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "h2")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(edgeHost),
            port: NWEndpoint.Port(integerLiteral: UInt16(edgePort))
        )
        let conn = NWConnection(to: endpoint, using: tlsParams)
        self.connection = conn

        var resumed = false
        let resumeOnce: (Result<Void, Error>) -> Void = { res in
            guard !resumed else { return }
            resumed = true
            switch res {
            case .success: continuation.resume()
            case .failure(let err): continuation.resume(throwing: err)
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendConnectionPreface()
                self.isConnected = true
                resumeOnce(.success(()))
                self.startReading()
            case .failed(let err):
                self.isConnected = false
                resumeOnce(.failure(err))
                self.handleDeath()
            case .cancelled:
                self.isConnected = false
                self.handleDeath()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendConnectionPreface() {
        var preface = Data(HTTP2Preface.clientMagic.utf8)
        let settings = HTTP2FrameEncoder.settings([
            (HTTP2Settings.enablePush, 0),
            (HTTP2Settings.initialWindowSize, 65_535),
            (HTTP2Settings.maxFrameSize, 16_384),
        ])
        preface.append(settings)
        // Up-size the connection-level window so we are never bottlenecked on Fastly's side.
        preface.append(HTTP2FrameEncoder.windowUpdate(streamId: 0, increment: 1_048_576))
        connection?.send(content: preface, completion: .idempotent)
    }

    private func startReading() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.decoder.append(content)
                self.processFrames()
            }
            if isComplete || error != nil {
                self.handleDeath()
                return
            }
            self.startReading()
        }
    }

    private func processFrames() {
        while let frame = (try? decoder.nextFrame()).flatMap({ $0 }) {
            switch frame.type {
            case .settings:
                if !frame.flags.contains(.ack) {
                    connection?.send(content: HTTP2FrameEncoder.settings([], ack: true), completion: .idempotent)
                }
            case .ping:
                if !frame.flags.contains(.ack) {
                    connection?.send(content: HTTP2FrameEncoder.ping(payload: frame.payload, ack: true), completion: .idempotent)
                }
            case .windowUpdate:
                if frame.payload.count >= 4 {
                    let increment = Int32(frame.payload.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian } & 0x7FFF_FFFF)
                    if frame.streamId == 0 {
                        connectionRemoteWindow += increment
                    } else if let stream = streams[frame.streamId] {
                        stream.adjustRemoteWindow(by: increment)
                    }
                }
            case .headers:
                handleHeadersFrame(frame)
            case .data:
                handleDataFrame(frame)
            case .rstStream:
                streams.removeValue(forKey: frame.streamId)?.onClose?()
            case .goaway:
                handleDeath()
            default:
                break
            }
        }
    }

    private func handleHeadersFrame(_ frame: HTTP2Frame) {
        guard let stream = streams[frame.streamId] else { return }
        guard let headers = try? hpackDecoder.decode(frame.payload) else { return }
        for header in headers {
            if header.name == ":status", let status = Int(header.value) {
                stream.onConnected?(status)
            }
        }
    }

    private func handleDataFrame(_ frame: HTTP2Frame) {
        guard let stream = streams[frame.streamId] else { return }
        // Flow control: acknowledge data frames with connection + stream window updates.
        let windowAck = HTTP2FrameEncoder.windowUpdate(streamId: 0, increment: UInt32(frame.payload.count))
            + HTTP2FrameEncoder.windowUpdate(streamId: frame.streamId, increment: UInt32(frame.payload.count))
        connection?.send(content: windowAck, completion: .idempotent)

        stream.onData?(frame.payload)
        if frame.flags.contains(.endStream) {
            stream.onClose?()
            streams.removeValue(forKey: frame.streamId)
        }
    }

    /// Opens an HTTP/2 CONNECT tunnel to `targetHost:targetPort` carrying arbitrary TCP traffic.
    /// Equivalent of FoxyVPN's `UpstreamSession.openStream(targetHost, targetPort)`.
    func openStream(targetHost: String, targetPort: Int) async throws -> H2Stream {
        guard isConnected else { throw UpstreamError.sessionDead }
        let authority = "\(targetHost):\(targetPort)"

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<H2Stream, Error>) in
            queue.async {
                let streamId = self.nextStreamId
                self.nextStreamId += 2

                let stream = H2Stream(streamId: streamId, targetAuthority: authority)
                self.streams[streamId] = stream

                var resumed = false
                stream.onConnected = { status in
                    guard !resumed else { return }
                    resumed = true
                    if status >= 200 && status < 300 {
                        continuation.resume(returning: stream)
                    } else if status == 401 || status == 403 || status == 407 {
                        continuation.resume(throwing: UpstreamError.unauthenticated)
                    } else {
                        continuation.resume(throwing: UpstreamError.rejected(statusCode: status, authority: authority))
                    }
                }

                let connectHeaders: [(String, String)] = [
                    (":method", "CONNECT"),
                    (":authority", authority),
                    ("proxy-authorization", "Bearer \(self.bearerToken)"),
                    ("user-agent", mozillaVpnUserAgent),
                ]
                let block = HPACKEncoder.encode(connectHeaders)
                let frameData = HTTP2FrameEncoder.headers(streamId: streamId, block: block, endStream: false)
                self.connection?.send(content: frameData, completion: .idempotent)
            }
        }
    }

    /// Sends raw bytes into an open stream.
    func sendData(streamId: Int32, data: Data, endStream: Bool = false) {
        queue.async {
            var offset = 0
            let maxChunk = 16_384
            while offset < data.count || (data.isEmpty && endStream) {
                let end = min(offset + maxChunk, data.count)
                let chunk = data.subdata(in: offset..<end)
                let isLast = endStream && end == data.count
                let frameData = HTTP2FrameEncoder.data(streamId: streamId, payload: chunk, endStream: isLast)
                self.connection?.send(content: frameData, completion: .idempotent)
                offset = end
                if data.isEmpty { break }
            }
        }
    }

    /// Closes a stream with RST_STREAM (cancel).
    func closeStream(streamId: Int32) {
        queue.async {
            guard let stream = self.streams.removeValue(forKey: streamId) else { return }
            let rst = HTTP2FrameEncoder.rstStream(streamId: streamId, errorCode: HTTP2ErrorCode.cancel.rawValue)
            self.connection?.send(content: rst, completion: .idempotent)
            stream.onClose?()
        }
    }

    func close() {
        queue.async {
            guard !self.isClosing else { return }
            self.isClosing = true
            let goaway = HTTP2FrameEncoder.goaway(lastStreamId: self.nextStreamId, errorCode: 0)
            self.connection?.send(content: goaway, completion: .idempotent)
            self.connection?.cancel()
            self.handleDeath()
        }
    }

    private func handleDeath() {
        isConnected = false
        for stream in streams.values { stream.onClose?() }
        streams.removeAll()
        onSessionDead?()
    }
}
