// H2UpstreamSession.swift
// Port of FoxyVPN's vpn/upstream/H2UpstreamSession.kt — carries the device's tunneled
// TCP streams across a single multiplexed HTTP/2 connection to Fastly's edge via CONNECT.
//
// Network.framework (NWConnection) powers the TLS transport with ALPN ["h2"]. Streams
// are multiplexed as RFC 9113 HTTP/2 streams using HTTP2Frame and HPACK.
//
// v1.1.0: enforces HTTP/2 send-side flow control (per-stream + connection windows with
// buffering until WINDOW_UPDATE), fails openStream() after a timeout instead of hanging
// forever, accumulates CONTINUATION frames, and logs HPACK decode failures.

import Foundation
import Network
import Security

enum UpstreamError: LocalizedError {
    case rejected(statusCode: Int, authority: String)
    case timeout(authority: String)
    case unauthenticated
    case streamClosed
    case sessionDead
    /// The TLS/TCP transport to the edge never came up (port blocked, DNS, reset...).
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let status, let auth):
            let hint: String
            switch status {
            case 405: hint = " — the edge is reachable but refuses CONNECT on this port"
            case 401, 403: hint = " — the proxy pass was rejected; sign in again"
            case 407: hint = " — the edge requires proxy authentication"
            default: hint = ""
            }
            return "Upstream edge rejected CONNECT \(auth) (HTTP \(status))\(hint)"
        case .timeout(let auth): return "Timeout connecting to \(auth) via upstream edge"
        case .unauthenticated: return "Upstream session unauthenticated"
        case .streamClosed: return "Stream closed"
        case .sessionDead: return "Upstream session is closed or dead"
        case .unreachable(let message): return "Cannot reach \(message)"
        }
    }
}

/// One multiplexed TCP stream carried inside the HTTP/2 tunnel.
final class H2Stream {
    let streamId: Int32
    let targetAuthority: String

    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var onConnected: ((Int) -> Void)?

    /// Send-side state — only touched on the session queue.
    /// Bytes the server allows us to send on this stream (RFC 9113 §5.2.1).
    fileprivate var sendWindow: Int32 = 65_535
    fileprivate var pendingChunks: [Data] = []
    fileprivate var pendingEnd = false
    fileprivate var ended = false

    init(streamId: Int32, targetAuthority: String) {
        self.streamId = streamId
        self.targetAuthority = targetAuthority
    }
}

final class H2UpstreamSession {
    let edgeHost: String
    let edgePort: Int
    private var bearerToken: String
    /// DNS-over-HTTPS endpoints used to resolve `edgeHost` when the system resolver is poisoned
    /// or blocked. Empty means "use the system resolver".
    private let dohEndpoints: [String]
    /// Explicit address (hostname or IP) to dial instead of resolving `edgeHost`. macOS port of
    /// FoxyVPN's `edgeAddress`: the TLS handshake and certificate check still target `edgeHost`.
    private let edgeAddressOverride: String?
    /// Optional upstream proxy that both the TCP connect and the TLS handshake are chained
    /// through (macOS 14+). Mirrors FoxyVPN's `upstreamProxy`.
    private let upstreamProxy: UpstreamProxySetting?

    /// Address actually handed to Network.framework — surfaced for logs/diagnostics.
    private(set) var dialTargetDescription = ""

    private var connection: NWConnection?
    private let decoder = HTTP2FrameDecoder()
    private let hpackDecoder = HPACKDecoder()
    private let queue = DispatchQueue(label: "app.vulpine.h2", qos: .userInitiated)

    /// Seconds Network.framework is allowed to spend on the TCP connect before giving up, so a
    /// filtered/blackholed edge fails fast and the next candidate can be tried.
    private static let tcpConnectTimeoutSeconds = 8

    private var nextStreamId: Int32 = 1
    private var streams: [Int32: H2Stream] = [:]
    /// Bytes the server allows us to send on the connection as a whole.
    private var connectionSendWindow: Int32 = 65_535
    /// The server's advertised SETTINGS_INITIAL_WINDOW_SIZE for new streams.
    private var serverInitialWindowSize: Int32 = 65_535
    /// HEADERS frame seen without END_HEADERS — waiting for CONTINUATION frames.
    private var pendingHeaders: (streamId: Int32, block: Data)?

    private(set) var isConnected = false
    private var isClosing = false
    private var deathReported = false

    var onSessionDead: (() -> Void)?

    init(
        edgeHost: String,
        edgePort: Int,
        bearerToken: String,
        dohEndpoints: [String] = [],
        edgeAddressOverride: String? = nil,
        upstreamProxy: UpstreamProxySetting? = nil
    ) {
        self.edgeHost = edgeHost
        self.edgePort = edgePort
        self.bearerToken = bearerToken
        self.dohEndpoints = dohEndpoints
        self.edgeAddressOverride = edgeAddressOverride
        self.upstreamProxy = upstreamProxy
    }

    func updateBearerToken(_ token: String) {
        bearerToken = token
    }

    func connect() async throws {
        // Resolve the dial address *before* entering the session queue: the DoH round trip is
        // async and must not block the serialised frame-processing queue.
        let target = await resolveDialTarget()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.startConnection(continuation, dialTarget: target)
            }
        }
    }

    /// Decides where the TCP connection is opened.
    ///
    /// 1. An explicit edge address (Settings → "custom edge address") wins, so a user can pin a
    ///    known-good Fastly IP when the hostname is blocked or resolves badly.
    /// 2. Otherwise the edge hostname is resolved over DNS-over-HTTPS (RFC 8484), which keeps
    ///    working when the local resolver is poisoned or filtered.
    /// 3. Otherwise Network.framework resolves the hostname with the system resolver.
    private func resolveDialTarget() async -> (host: String, pinServerName: Bool, detail: String) {
        let override = edgeAddressOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            let isLiteral = DohResolver.isAddressLiteral(override)
            return (override, isLiteral, "custom edge address \(override) (TLS name \(edgeHost))")
        }

        if !dohEndpoints.isEmpty,
           let address = await DohResolver.shared.preferredAddress(host: edgeHost, endpoints: dohEndpoints) {
            return (address, true, "DoH \(edgeHost) -> \(address)")
        }

        return (edgeHost, false, "system resolver \(edgeHost)")
    }

    private func startConnection(
        _ continuation: CheckedContinuation<Void, Error>,
        dialTarget: (host: String, pinServerName: Bool, detail: String)
    ) {
        dialTargetDescription = dialTarget.detail

        let tlsParams = NWParameters.tls
        let tlsOptions = tlsParams.defaultProtocolStack.applicationProtocols[0] as! NWProtocolTLS.Options
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "h2")

        // Always verify the certificate against the real Mozilla edge name, even when we dial a
        // raw IP for it (exactly what FoxyVPN does with its custom `edgeAddress`).
        if dialTarget.pinServerName && dialTarget.host != edgeHost {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, edgeHost)
        }

        // Fail fast on a filtered/blackholed address, and keep the tunnel alive across NAT timeouts.
        if let tcp = tlsParams.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = Self.tcpConnectTimeoutSeconds
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15
        }

        applyUpstreamProxy(to: tlsParams)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(dialTarget.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: edgePort))
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
                let reason: String
                switch err {
                case .dns(let code): reason = "DNS error \(code)"
                case .posix(let code): reason = "network error \(code.rawValue) (\(code))"
                @unknown default: reason = "\(err)"
                }
                resumeOnce(.failure(
                    UpstreamError.unreachable("edge \(self.edgeHost):\(self.edgePort) — \(reason)")
                ))
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

    /// Chains the dial through the user's own proxy (Settings → "Connect through another
    /// proxy"). Network.framework performs the TCP connect *and* the TLS handshake through the
    /// proxy, so the HTTP/2 tunnel itself is tunnelled instead of leaking around it — the same
    /// effect as Netty's proxy handler on Android.
    private func applyUpstreamProxy(to tlsParams: NWParameters) {
        guard let proxy = upstreamProxy, proxy.isUsable else { return }

        guard #available(macOS 14.0, *) else {
            Task {
                await AppLog.shared.warn(
                    "H2",
                    "upstream proxy chaining needs macOS 14 or newer; dialling the edge directly instead"
                )
            }
            return
        }

        let hop = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxy.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: proxy.port))
        )
        var configuration: ProxyConfiguration
        switch proxy.type {
        case .socks5: configuration = ProxyConfiguration(socksv5Proxy: hop)
        case .http: configuration = ProxyConfiguration(httpCONNECTProxy: hop)
        }
        if !proxy.username.isEmpty {
            configuration.applyCredential(username: proxy.username, password: proxy.password)
        }
        // Never let the OS quietly fall back to a direct connection: on a filtered network the
        // direct path is precisely the one that does not work.
        configuration.allowFailover = false

        let context = NWParameters.PrivacyContext(description: "vulpine-upstream-proxy")
        context.proxyConfigurations = [configuration]
        tlsParams.setPrivacyContext(context)

        Task {
            await AppLog.shared.info(
                "H2",
                "dialling the edge through \(proxy.type.rawValue.uppercased()) proxy \(proxy.host):\(proxy.port)"
            )
        }
    }

    private func sendConnectionPreface() {
        var preface = Data(HTTP2Preface.clientMagic.utf8)
        let settings = HTTP2FrameEncoder.settings([
            (HTTP2Settings.enablePush, 0),
            (HTTP2Settings.initialWindowSize, 65_535),
            (HTTP2Settings.maxFrameSize, 16_384),
        ])
        preface.append(settings)
        // Up-size the connection-level receive window so we are never bottlenecked on Fastly's side.
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
                    applyServerSettings(frame.payload)
                }
            case .ping:
                if !frame.flags.contains(.ack) {
                    connection?.send(content: HTTP2FrameEncoder.ping(payload: frame.payload, ack: true), completion: .idempotent)
                }
            case .windowUpdate:
                handleWindowUpdate(frame)
            case .headers:
                if frame.flags.contains(.endHeaders) {
                    handleHeaders(streamId: frame.streamId, block: frame.payload)
                } else {
                    pendingHeaders = (streamId: frame.streamId, block: frame.payload)
                }
            case .continuation:
                guard var pending = pendingHeaders, pending.streamId == frame.streamId else { break }
                pending.block.append(frame.payload)
                if frame.flags.contains(.endHeaders) {
                    pendingHeaders = nil
                    handleHeaders(streamId: pending.streamId, block: pending.block)
                } else {
                    pendingHeaders = pending
                }
            case .data:
                handleDataFrame(frame)
            case .rstStream:
                pendingHeaders = nil
                if let stream = streams.removeValue(forKey: frame.streamId) {
                    stream.onClose?()
                }
            case .goaway:
                handleDeath()
            default:
                break
            }
        }
    }

    /// Applies the server's SETTINGS_INITIAL_WINDOW_SIZE delta to every open stream (RFC 9113 §6.5.2).
    private func applyServerSettings(_ payload: Data) {
        var offset = 0
        while offset + 6 <= payload.count {
            let id = (UInt16(payload[offset]) << 8) | UInt16(payload[offset + 1])
            let value = payload.subdata(in: (offset + 2)..<(offset + 6))
                .withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            if id == HTTP2Settings.initialWindowSize {
                let newValue = Int32(bitPattern: value & 0x7FFF_FFFF)
                let delta = newValue - serverInitialWindowSize
                serverInitialWindowSize = newValue
                if delta != 0 {
                    for (streamId, stream) in streams {
                        stream.sendWindow += delta
                        flushStream(streamId)
                    }
                }
            }
            offset += 6
        }
    }

    private func handleWindowUpdate(_ frame: HTTP2Frame) {
        guard frame.payload.count >= 4 else { return }
        let raw = frame.payload.subdata(in: 0..<4)
            .withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) } & 0x7FFF_FFFF
        let increment = Int32(bitPattern: raw)
        if frame.streamId == 0 {
            connectionSendWindow += increment
            for streamId in streams.keys { flushStream(streamId) }
        } else if let stream = streams[frame.streamId] {
            stream.sendWindow += increment
            flushStream(frame.streamId)
        }
    }

    private func handleHeaders(streamId: Int32, block: Data) {
        guard let stream = streams[streamId] else { return }
        let headers: [HPACKHeader]
        do {
            headers = try hpackDecoder.decode(block)
        } catch {
            Task { await AppLog.shared.error("H2", "HPACK decode failed for stream \(streamId): \(error)") }
            streams.removeValue(forKey: streamId)
            stream.onConnected?(0)
            return
        }
        for header in headers {
            if header.name == ":status", let status = Int(header.value) {
                if !(200..<300).contains(status) {
                    // Keep the edge's answer visible in the log — this is what tells a blocked
                    // port apart from a rejected proxy pass or a port without proxy support.
                    let extra = headers
                        .filter { !$0.name.hasPrefix(":") && $0.name != "date" }
                        .prefix(4)
                        .map { "\($0.name): \($0.value)" }
                        .joined(separator: "; ")
                    Task { await AppLog.shared.warn("H2", "edge answered HTTP \(status) for \(stream.targetAuthority)\(extra.isEmpty ? "" : " — \(extra)")") }
                }
                stream.onConnected?(status)
                return
            }
        }
    }

    private func handleDataFrame(_ frame: HTTP2Frame) {
        guard let stream = streams[frame.streamId] else { return }
        // Flow control: acknowledge data frames with connection + stream window updates.
        let windowAck = HTTP2FrameEncoder.windowUpdate(streamId: 0, increment: UInt32(frame.payload.count))
            + HTTP2FrameEncoder.windowUpdate(streamId: frame.streamId, increment: UInt32(frame.payload.count))
        connection?.send(content: windowAck, completion: .idempotent)

        if !frame.payload.isEmpty {
            stream.onData?(frame.payload)
        }
        if frame.flags.contains(.endStream) {
            streams.removeValue(forKey: frame.streamId)
            stream.onClose?()
        }
    }

    /// Opens an HTTP/2 CONNECT tunnel to `targetHost:targetPort` carrying arbitrary TCP traffic.
    /// Equivalent of FoxyVPN's `UpstreamSession.openStream(targetHost, targetPort)`.
    /// Fails with `UpstreamError.timeout` if the edge does not answer within 10 seconds.
    func openStream(targetHost: String, targetPort: Int) async throws -> H2Stream {
        guard isConnected else { throw UpstreamError.sessionDead }
        let authority = "\(targetHost):\(targetPort)"

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<H2Stream, Error>) in
            queue.async {
                let streamId = self.nextStreamId
                self.nextStreamId += 2

                let stream = H2Stream(streamId: streamId, targetAuthority: authority)
                stream.sendWindow = self.serverInitialWindowSize
                self.streams[streamId] = stream

                var resumed = false
                let resume: (Result<H2Stream, Error>) -> Void = { res in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(with: res)
                }
                stream.onConnected = { status in
                    if status >= 200 && status < 300 {
                        resume(.success(stream))
                    } else if status == 401 || status == 403 || status == 407 {
                        self.streams.removeValue(forKey: streamId)
                        resume(.failure(UpstreamError.unauthenticated))
                    } else {
                        self.streams.removeValue(forKey: streamId)
                        resume(.failure(UpstreamError.rejected(statusCode: status, authority: authority)))
                    }
                }

                // Never hang forever if the edge goes silent.
                self.queue.asyncAfter(deadline: .now() + 10) {
                    guard !resumed else { return }
                    self.streams.removeValue(forKey: streamId)
                    resume(.failure(UpstreamError.timeout(authority: authority)))
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

    /// Sends raw bytes into an open stream. Buffers behind the HTTP/2 flow-control
    /// windows and flushes as WINDOW_UPDATE frames arrive from the server.
    func sendData(streamId: Int32, data: Data, endStream: Bool = false) {
        queue.async {
            guard let stream = self.streams[streamId], !stream.ended else { return }
            if !data.isEmpty { stream.pendingChunks.append(data) }
            if endStream { stream.pendingEnd = true }
            self.flushStream(streamId)
        }
    }

    /// Sends whatever the stream's buffer allows given the stream + connection windows.
    /// Must be called on the session queue.
    private func flushStream(_ streamId: Int32) {
        guard let stream = streams[streamId], !stream.ended else { return }
        while !stream.pendingChunks.isEmpty {
            guard connectionSendWindow > 0, stream.sendWindow > 0 else { return }
            let head = stream.pendingChunks[0]
            let allowed = min(min(16_384, Int(connectionSendWindow), Int(stream.sendWindow)), head.count)
            let chunk = head.subdata(in: 0..<allowed)
            connection?.send(
                content: HTTP2FrameEncoder.data(streamId: streamId, payload: chunk, endStream: false),
                completion: .idempotent
            )
            connectionSendWindow -= Int32(allowed)
            stream.sendWindow -= Int32(allowed)
            if allowed == head.count {
                stream.pendingChunks.removeFirst()
            } else {
                stream.pendingChunks[0] = head.subdata(in: allowed..<head.count)
            }
        }
        // A zero-length DATA frame with END_STREAM consumes no flow-control credit.
        if stream.pendingEnd {
            connection?.send(
                content: HTTP2FrameEncoder.data(streamId: streamId, payload: Data(), endStream: true),
                completion: .idempotent
            )
            stream.ended = true
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
        guard !deathReported else { return }
        deathReported = true
        isConnected = false
        let openStreams = streams
        streams.removeAll()
        pendingHeaders = nil
        for stream in openStreams.values { stream.onClose?() }
        onSessionDead?()
    }
}
