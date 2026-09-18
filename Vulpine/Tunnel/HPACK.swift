// HPACK.swift
// RFC 7541 HPACK decoder — enough of the spec to read CONNECT responses and headers
// from the Fastly edge: static table, dynamic table (with size limit), Huffman literals,
// and integer decoding. Ports the subset FoxyVPN's H2 layer relies on via Netty.

import Foundation

enum HPACKError: Error {
    case truncated
    case invalidInteger
    case invalidIndex
    case invalidHuffman
    case invalidString
    case unsupportedPseudoHeader
}

struct HPACKHeader: Equatable {
    let name: String
    let value: String
}

final class HPACKDecoder {
    /// RFC 7541 Appendix A: the 61-entry static table.
    static let staticTable: [(String, String)] = [
        (":authority", ""),
        (":method", "GET"),
        (":method", "POST"),
        (":path", "/"),
        (":path", "/index.html"),
        (":scheme", "http"),
        (":scheme", "https"),
        (":status", "200"),
        (":status", "204"),
        (":status", "206"),
        (":status", "304"),
        (":status", "400"),
        (":status", "404"),
        (":status", "500"),
        ("accept-charset", ""),
        ("accept-encoding", "gzip, deflate"),
        ("accept-language", ""),
        ("accept-ranges", ""),
        ("accept", ""),
        ("access-control-allow-origin", ""),
        ("age", ""),
        ("allow", ""),
        ("authorization", ""),
        ("cache-control", ""),
        ("content-disposition", ""),
        ("content-encoding", ""),
        ("content-language", ""),
        ("content-length", ""),
        ("content-location", ""),
        ("content-range", ""),
        ("content-type", ""),
        ("cookie", ""),
        ("date", ""),
        ("etag", ""),
        ("expect", ""),
        ("expires", ""),
        ("from", ""),
        ("host", ""),
        ("if-match", ""),
        ("if-modified-since", ""),
        ("if-none-match", ""),
        ("if-range", ""),
        ("if-unmodified-since", ""),
        ("last-modified", ""),
        ("link", ""),
        ("location", ""),
        ("max-forwards", ""),
        ("proxy-authenticate", ""),
        ("proxy-authorization", ""),
        ("range", ""),
        ("referer", ""),
        ("refresh", ""),
        ("retry-after", ""),
        ("server", ""),
        ("set-cookie", ""),
        ("strict-transport-security", ""),
        ("transfer-encoding", ""),
        ("user-agent", ""),
        ("vary", ""),
        ("via", ""),
        ("www-authenticate", ""),
    ]

    /// Maximum number of bytes the dynamic table may hold (HPACK SETTINGS_HEADER_TABLE_SIZE).
    var maxDynamicTableSize: Int {
        get { dynamicTable.maxSize }
        set { dynamicTable.maxSize = newValue }
    }

    private let dynamicTable = DynamicTable()

    func decode(_ data: Data) throws -> [HPACKHeader] {
        var headers: [HPACKHeader] = []
        var index = 0

        while index < data.count {
            let byte = data[index]
            index += 1

            // Literal header field never indexed / without indexing share the "new name" shape.
            if byte & 0xF0 == 0x00 || byte & 0xF0 == 0x10 || byte & 0xE0 == 0x20 {
                let incremental = (byte & 0xC0) == 0x40
                var nameIndex = Int(byte & 0x0F)
                if nameIndex == 0 {
                    let (name, consumed) = try readString(data, at: index)
                    name = try lowercaseHeaderName(name)
                    index = consumed
                } else {
                    nameIndex += index - 1 > 0 ? 0 : 0
                }
                let name: String
                if byte & 0x0F == 0 {
                    let (raw, consumed) = try readString(data, at: index)
                    name = raw.lowercased()
                    index = consumed
                } else {
                    name = try lookup(index: Int(byte & 0x0F)).name
                }
                let (value, consumed) = try readString(data, at: index)
                index = consumed
                let header = HPACKHeader(name: name, value: value)
                headers.append(header)
                if incremental { dynamicTable.insert(header) }
                _ = nameIndex
                continue
            }

            // Indexed header field: 1xxxxxxx.
            if byte & 0x80 != 0 {
                let (rawIndex, consumed) = try readInteger(data, at: index, prefixBits: 7, firstByte: byte)
                index = consumed
                let header = try lookup(index: rawIndex)
                headers.append(header)
                if (byte & 0x40) != 0 { dynamicTable.insert(header) }
                continue
            }

            // Dynamic table size update: 001xxxxx.
            if byte & 0xE0 == 0x20 {
                let (size, consumed) = try readInteger(data, at: index, prefixBits: 5, firstByte: byte)
                index = consumed
                dynamicTable.maxSize = size
                continue
            }

            throw HPACKError.truncated
        }

        return headers
    }

    private func lookup(index: Int) throws -> HPACKHeader {
        if index <= 0 { throw HPACKError.invalidIndex }
        if index <= Self.staticTable.count {
            let entry = Self.staticTable[index - 1]
            return HPACKHeader(name: entry.0, value: entry.1)
        }
        guard let entry = dynamicTable.entry(at: index - Self.staticTable.count) else {
            throw HPACKError.invalidIndex
        }
        return entry
    }

    /// Reads a length-prefixed string literal (RFC 7541 §5.2).
    private func readString(_ data: Data, at start: Int) throws -> (String, Int) {
        let (length, consumed) = try readInteger(data, at: start, prefixBits: 7, firstByte: nil)
        var index = consumed
        guard index + length <= data.count else { throw HPACKError.truncated }
        let chunk = data.subdata(in: index..<(index + length))
        index += length
        let isHuffman = (data[start] & 0x80) != 0
        if isHuffman {
            guard let decoded = HPACKHuffman.decode(chunk) else { throw HPACKError.invalidHuffman }
            return (decoded, index)
        }
        guard let text = String(data: chunk, encoding: .utf8) else { throw HPACKError.invalidString }
        return (text, index)
    }

    /// RFC 7541 §5.1 variable-length integer.
    private func readInteger(
        _ data: Data,
        at start: Int,
        prefixBits: Int,
        firstByte: Byte?
    ) throws -> (value: Int, nextIndex: Int) {
        let maxPrefix = (1 << prefixBits) - 1
        var value: Int
        var index = start

        if let first = firstByte {
            value = Int(first) & maxPrefix
            if value < maxPrefix { return (value, index) }
        } else {
            guard index < data.count else { throw HPACKError.truncated }
            value = Int(data[index]) & maxPrefix
            index += 1
            if value < maxPrefix { return (value, index) }
        }

        var shift = 0
        while index < data.count {
            let byte = data[index]
            index += 1
            value += Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
            if shift > 28 { throw HPACKError.invalidInteger }
        }
        throw HPACKError.truncated
    }

    private func lowercaseHeaderName(_ name: String) throws -> String { name.lowercased() }
}

/// RFC 7541 §4.3 dynamic table with FIFO eviction and a byte-size ceiling.
private final class DynamicTable {
    private var entries: [HPACKHeader] = []
    private(set) var size = 0
    var maxSize = 4_096

    func insert(_ header: HPACKHeader) {
        let cost = header.name.utf8.count + header.value.utf8.count + 32
        entries.insert(header, at: 0)
        size += cost
        evict()
    }

    func entry(at index: Int) -> HPACKHeader? {
        guard index > 0, index <= entries.count else { return nil }
        return entries[index - 1]
    }

    private func evict() {
        while size > maxSize, !entries.isEmpty {
            let removed = entries.removeLast()
            size -= removed.name.utf8.count + removed.value.utf8.count + 32
        }
    }
}
