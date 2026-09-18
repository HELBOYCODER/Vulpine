// HTTP2Frame.swift
// RFC 9113 frame codec — the wire layer of the tunnel's upstream session.
// Ports the subset of Netty's Http2FrameCodec that FoxyVPN uses: DATA, HEADERS,
// SETTINGS, WINDOW_UPDATE, RST_STREAM, PING, GOAWAY.

import Foundation

public enum HTTP2Error: Error {
    case incomplete
    case malformed(String)
    case streamClosed
    case connectionError(String)
}

/// Frame type identifiers (RFC 9113 §6).
public enum HTTP2FrameType: UInt8 {
    case data = 0x0
    case headers = 0x1
    case priority = 0x2
    case rstStream = 0x3
    case settings = 0x4
    case pushPromise = 0x5
    case ping = 0x6
    case goaway = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9
}

/// Frame flags.
public struct HTTP2Flags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let endStream = HTTP2Flags(rawValue: 0x01)
    public static let endHeaders = HTTP2Flags(rawValue: 0x04)
    public static let padded = HTTP2Flags(rawValue: 0x08)
    public static let priority = HTTP2Flags(rawValue: 0x20)
    public static let ack = HTTP2Flags(rawValue: 0x01)
}

public struct HTTP2Frame {
    public let streamId: Int32
    public let type: HTTP2FrameType
    public let flags: HTTP2Flags
    public let payload: Data

    public init(streamId: Int32, type: HTTP2FrameType, flags: HTTP2Flags, payload: Data) {
        self.streamId = streamId
        self.type = type
        self.flags = flags
        self.payload = payload
    }
}

public enum HTTP2Preface {
    /// The client connection preface (RFC 9113 §3.4).
    static let clientMagic = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
}

/// Reads a 9-byte frame header plus its payload from a byte stream.
public final class HTTP2FrameDecoder {
    private var buffer = Data()
    private static let headerLength = 9

    /// Appends newly-arrived bytes.
    public func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame, or nil if more bytes are needed.
    public func nextFrame() throws -> HTTP2Frame? {
        guard buffer.count >= Self.headerLength else { return nil }
        let header = buffer.prefix(Self.headerLength)
        let length = (Int(header[0]) << 16) | (Int(header[1]) << 8) | Int(header[2])
        let typeByte = header[3]
        let flagsByte = header[4]
        let streamId = Int32(
            (UInt32(header[5]) << 24) | (UInt32(header[6]) << 16) | (UInt32(header[7]) << 8) | UInt32(header[8])
        ) & 0x7FFF_FFFF

        let totalNeeded = Self.headerLength + length
        guard buffer.count >= totalNeeded else { return nil }

        guard let type = HTTP2FrameType(rawValue: typeByte) else {
            // Unknown/extension frames are skipped per RFC 9113 §5.5.
            buffer.removeSubrange(0..<totalNeeded)
            return try nextFrame()
        }

        let payload = buffer.subdata(in: Self.headerLength..<totalNeeded)
        buffer.removeSubrange(0..<totalNeeded)

        return HTTP2Frame(
            streamId: streamId,
            type: type,
            flags: HTTP2Flags(rawValue: flagsByte),
            payload: payload
        )
    }

    public var pendingBytes: Int { buffer.count }

    public func reset() { buffer.removeAll() }
}

/// Writes frames in the 9-byte header + payload format.
public enum HTTP2FrameEncoder {
    public static func encode(_ frame: HTTP2Frame) -> Data {
        var out = Data()
        let length = frame.payload.count
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(frame.type.rawValue)
        out.append(frame.flags.rawValue)
        var stream = UInt32(frame.streamId & 0x7FFF_FFFF).bigEndian
        withUnsafeBytes(of: &stream) { out.append(contentsOf: $0) }
        out.append(frame.payload)
        return out
    }

    public static func data(streamId: Int32, payload: Data, endStream: Bool) -> Data {
        encode(
            HTTP2Frame(
                streamId: streamId,
                type: .data,
                flags: endStream ? [.endStream] : [],
                payload: payload
            )
        )
    }

    public static func headers(streamId: Int32, block: Data, endStream: Bool, endHeaders: Bool = true) -> Data {
        var flags: HTTP2Flags = []
        if endStream { flags.insert(.endStream) }
        if endHeaders { flags.insert(.endHeaders) }
        return encode(HTTP2Frame(streamId: streamId, type: .headers, flags: flags, payload: block))
    }

    public static func settings(_ parameters: [(UInt16, UInt32)], ack: Bool = false) -> Data {
        var payload = Data()
        if !ack {
            for (id, value) in parameters {
                var idBE = id.bigEndian
                withUnsafeBytes(of: &idBE) { payload.append(contentsOf: $0) }
                var valueBE = value.bigEndian
                withUnsafeBytes(of: &valueBE) { payload.append(contentsOf: $0) }
            }
        }
        return encode(HTTP2Frame(streamId: 0, type: .settings, flags: ack ? [.ack] : [], payload: payload))
    }

    public static func windowUpdate(streamId: Int32, increment: UInt32) -> Data {
        var payload = Data()
        var be = (increment & 0x7FFF_FFFF).bigEndian
        withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
        return encode(HTTP2Frame(streamId: streamId, type: .windowUpdate, flags: [], payload: payload))
    }

    public static func rstStream(streamId: Int32, errorCode: UInt32) -> Data {
        var payload = Data()
        var be = errorCode.bigEndian
        withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
        return encode(HTTP2Frame(streamId: streamId, type: .rstStream, flags: [], payload: payload))
    }

    public static func ping(payload: Data, ack: Bool = false) -> Data {
        encode(HTTP2Frame(streamId: 0, type: .ping, flags: ack ? [.ack] : [], payload: payload))
    }

    public static func goaway(lastStreamId: Int32, errorCode: UInt32, debugData: Data = Data()) -> Data {
        var payload = Data()
        var id = UInt32(lastStreamId & 0x7FFF_FFFF).bigEndian
        withUnsafeBytes(of: &id) { payload.append(contentsOf: $0) }
        var code = errorCode.bigEndian
        withUnsafeBytes(of: &code) { payload.append(contentsOf: $0) }
        payload.append(debugData)
        return encode(HTTP2Frame(streamId: 0, type: .goaway, flags: [], payload: payload))
    }
}

/// Settings identifiers (RFC 9113 §6.5.2).
public enum HTTP2Settings {
    public static let headerTableSize: UInt16 = 0x1
    public static let enablePush: UInt16 = 0x2
    public static let maxConcurrentStreams: UInt16 = 0x3
    public static let initialWindowSize: UInt16 = 0x4
    public static let maxFrameSize: UInt16 = 0x5
    public static let maxHeaderListSize: UInt16 = 0x6
}

/// RFC 9113 §6.4 error codes.
public enum HTTP2ErrorCode: UInt32 {
    case noError = 0x0
    case protocolError = 0x1
    case internalError = 0x2
    case flowControlError = 0x3
    case settingsTimeout = 0x4
    case streamClosed = 0x5
    case frameSizeError = 0x6
    case refusedStream = 0x7
    case cancel = 0x8
    case compressionError = 0x9
    case connectError = 0xa
    case enhanceYourCalm = 0xb
    case inadequateSecurity = 0xc
    case http11Required = 0xd
}
