// SHA256.swift
// CommonCrypto-backed SHA-256 (parity with Kotlin's MessageDigest.getInstance("SHA-256")).

import Foundation
import CommonCrypto

func sha256(_ data: Data) -> Data {
    var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), digest.mutableBytes)
    }
    return digest
}

func sha256(_ string: String) -> Data {
    sha256(Data(string.utf8))
}

extension Data {
    /// HKDF-Extract as used by Mozilla's FxA / Guardian protocol family (RFC 5869, section 2.2).
    func hmacSha256(key: Data) -> Data {
        var out = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { (info: UnsafeRawBufferPointer) in
            key.withUnsafeBytes { (keyPtr: UnsafeRawBufferPointer) in
                _ = CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyPtr.baseAddress, key.count,
                    info.baseAddress, self.count,
                    out.mutableBytes
                )
            }
        }
        return out
    }

    /// Constant-time equality check for token / MAC comparisons.
    func timingSafeCompare(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<count { diff |= self[i] ^ other[i] }
        return diff == 0
    }
}
