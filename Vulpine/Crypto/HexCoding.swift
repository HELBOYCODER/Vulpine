// HexCoding.swift
// Zero-dependency hex encode/decode (replaces Kotlin's toHex()/hexToBytes()).

import Foundation

extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Big-endian byte array from a hex string (Kotlin `String.hexToBytes()` parity).
    init?(hex: String) {
        let cleaned = hex.lowercased()
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension String {
    var hexToData: Data? { Data(hex: self) }
}
