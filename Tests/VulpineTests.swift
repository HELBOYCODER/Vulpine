// Tests/VulpineTests.swift
// Self-contained, framework-free validation checks for HPACK, HTTP/2 framing,
// and URL/Base64 helpers (ponytail requirement: one runnable check).

import Foundation

@main
enum VulpineTests {
    static func main() {
        print("Running Vulpine test suite...")
        testBase64URL()
        testHPACKIntegerEncoding()
        testHTTP2FrameCodec()
        testJWTExpiry()
        print("All checks passed.")
    }

    private static func testBase64URL() {
        let original = "Hello, Vulpine on macOS! Testing base64url encoding without padding."
        let encoded = original.base64URLEncoded
        assert(!encoded.contains("+"))
        assert(!encoded.contains("/"))
        assert(!encoded.contains("="))
        let decodedData = Data(base64URLEncoded: encoded)
        assert(decodedData != nil)
        let restored = String(data: decodedData!, encoding: .utf8)
        assert(restored == original)
        print("  ✓ Base64URL round-trip")
    }

    private static func testHPACKIntegerEncoding() {
        // 10 with 5-bit prefix -> fits inline: [10]
        let small = HPACKEncoder.encodeInteger(10, prefixBits: 5)
        assert(small == [10])

        // 1337 with 5-bit prefix (max prefix = 31)
        // 1337 - 31 = 1306; 1306 % 128 = 26 (+ 128 = 154); 1306 >> 7 = 10 -> [31, 154, 10]
        let encoded = HPACKEncoder.encodeInteger(1337, prefixBits: 5)
        assert(encoded == [31, 154, 10])
        print("  ✓ HPACK integer encoding (RFC 7541 §5.1)")
    }

    private static func testHTTP2FrameCodec() {
        let payload = Data("PING1234".utf8)
        let frame = HTTP2Frame(streamId: 0, type: .ping, flags: [.ack], payload: payload)
        let encoded = HTTP2FrameEncoder.encode(frame)

        // 9 byte header + 8 byte payload = 17 bytes
        assert(encoded.count == 17)
        assert(encoded[0] == 0x00 && encoded[1] == 0x00 && encoded[2] == 0x08) // length = 8
        assert(encoded[3] == HTTP2FrameType.ping.rawValue)
        assert(encoded[4] == HTTP2Flags.ack.rawValue)

        let decoder = HTTP2FrameDecoder()
        decoder.append(encoded)
        let decoded = try! decoder.nextFrame()
        assert(decoded != nil)
        assert(decoded!.streamId == 0)
        assert(decoded!.type == .ping)
        assert(decoded!.flags.contains(.ack))
        assert(decoded!.payload == payload)
        print("  ✓ HTTP/2 frame codec (encode + decode round-trip)")
    }

    private static func testJWTExpiry() {
        // Mock JWT with {"exp": 1700000000} in payload
        let payloadJson = "{\"exp\":1700000000}"
        let fakeJwt = "header.\(Data(payloadJson.utf8).base64URLEncoded).signature"
        let exp = JWT.expiryEpochSeconds(fakeJwt)
        assert(exp == 1700000000)
        print("  ✓ JWT expiry parser")
    }
}
