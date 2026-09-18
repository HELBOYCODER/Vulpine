// HPACKEncoder.swift
// Minimal RFC 7541 HPACK encoder — enough to build HTTP/2 CONNECT request headers.
// Only emits literal header fields without indexing (0x00 pattern), with optional Huffman,
// which is RFC-compliant, avoids dynamic-table state in the encoder, and is identical in
// effect to Netty's simplest encoding path.

import Foundation

enum HPACKEncoder {
    /// Encodes a list of headers as an HPACK header block using literal representation without indexing.
    static func encode(_ headers: [(name: String, value: String)]) -> Data {
        var out = Data()
        for (name, value) in headers {
            out.append(encodeHeader(name: name, value: value))
        }
        return out
    }

    private static func encodeHeader(name: String, value: String) -> Data {
        var out = Data()
        // 0000 0000 = literal header field without indexing, new name (RFC 7541 §6.2.2).
        out.append(0x00)
        out.append(encodeString(name))
        out.append(encodeString(value))
        return out
    }

    /// Length-prefixed string literal with H=0 (no Huffman) for simplicity and speed.
    private static func encodeString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var out = Data()
        out.append(contentsOf: encodeInteger(bytes.count, prefixBits: 7, mask: 0x00))
        out.append(bytes)
        return out
    }

    /// Variable-length integer encoding (RFC 7541 §5.1).
    static func encodeInteger(_ value: Int, prefixBits: Int, mask: UInt8 = 0) -> [UInt8] {
        let maxPrefix = (1 << prefixBits) - 1
        if value < maxPrefix {
            return [mask | UInt8(value)]
        }
        var out = [mask | UInt8(maxPrefix)]
        var remaining = value - maxPrefix
        while remaining >= 128 {
            out.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        out.append(UInt8(remaining))
        return out
    }
}
