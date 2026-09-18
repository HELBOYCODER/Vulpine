// DohResolver.swift
// RFC 8484 DNS-over-HTTPS resolver used to find Mozilla edge addresses when the system
// resolver is poisoned, filtered or simply unavailable — the normal situation on filtered
// networks, and the reason the edge hostnames (xxxxx.m1.fastly-masque.net) can look
// "unresolvable" to Network.framework even though they exist.
//
// Port of FoxyVPN's vpn/upstream/EdgeAddressResolver.kt, reduced to A/AAAA lookups over the
// wire-format DoH protocol that Cloudflare/Google/Quad9 all serve.

import Foundation

/// Resolves hostnames through DoH endpoints, with a small positive-answer cache.
final class DohResolver {
    static let shared = DohResolver()

    private struct Entry {
        let addresses: [String]
        let storedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()
    private let cacheTTL: TimeInterval = 300

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // DoH must not be re-routed through the system proxy or it inherits the very
        // problem it is meant to solve.
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    /// Resolves `host` through the first DoH endpoint that answers. Returns an empty array
    /// when nothing resolves (callers then fall back to the system resolver).
    func resolve(host: String, endpoints: [String]) async -> [String] {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, !endpoints.isEmpty, !Self.isAddressLiteral(name) else { return [] }
        guard name.unicodeScalars.allSatisfy({ $0.isASCII }) else { return [] }

        if let cached = cachedAddresses(for: name) { return cached }

        for endpoint in endpoints {
            if Task.isCancelled { return [] }
            var addresses = await query(name: name, type: 1, endpoint: endpoint)   // A
            addresses += await query(name: name, type: 28, endpoint: endpoint)     // AAAA
            if !addresses.isEmpty {
                store(addresses, for: name)
                await AppLog.shared.info(
                    "DoH",
                    "resolved \(name) -> \(addresses.joined(separator: ", ")) via \(endpoint)"
                )
                return addresses
            }
        }
        await AppLog.shared.warn("DoH", "no DoH endpoint could resolve \(name)")
        return []
    }

    func cachedAddresses(for host: String) -> [String]? {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[name] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < cacheTTL else {
            cache.removeValue(forKey: name)
            return nil
        }
        return entry.addresses
    }

    /// Prefers IPv4: A is requested first and its answers are kept in front of the AAAA ones.
    func preferredAddress(host: String, endpoints: [String]) async -> String? {
        let addresses = await resolve(host: host, endpoints: endpoints)
        return addresses.first { !$0.contains(":") } ?? addresses.first
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func store(_ addresses: [String], for host: String) {
        lock.lock()
        cache[host] = Entry(addresses: addresses, storedAt: Date())
        lock.unlock()
    }

    /// True for IPv4/IPv6 literals, which must never be sent to a resolver.
    static func isAddressLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isNumber }
                && (Int(part) ?? 256) <= 255
        }
    }

    // MARK: - Wire format

    private func query(name: String, type: UInt16, endpoint: String) async -> [String] {
        guard let url = Self.dnsQueryURL(for: endpoint) else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Self.buildQuery(name: name, type: type)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return Self.parseAnswers(data, wantType: type)
        } catch {
            return []
        }
    }

    static func dnsQueryURL(for endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var base = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
        base = base.hasSuffix("/") ? String(base.dropLast()) : base
        if !base.lowercased().hasSuffix("/dns-query") { base += "/dns-query" }
        return URL(string: base)
    }

    /// Builds a single-question recursive query (RFC 1035 §4).
    static func buildQuery(name: String, type: UInt16) -> Data {
        var out = Data()
        out.append(contentsOf: [0x00, 0x00])            // transaction id (DoH recommends 0)
        out.append(contentsOf: [0x01, 0x00])            // flags: recursion desired
        out.append(contentsOf: [0x00, 0x01])            // qdcount
        out.append(contentsOf: [0x00, 0x00])            // ancount
        out.append(contentsOf: [0x00, 0x00])            // nscount
        out.append(contentsOf: [0x00, 0x00])            // arcount

        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0x00)                                 // end of name
        out.append(UInt8(type >> 8)); out.append(UInt8(type & 0xFF))
        out.append(contentsOf: [0x00, 0x01])             // class IN
        return out
    }

    /// Parses the answer section and returns the textual addresses of `wantType` records.
    static func parseAnswers(_ data: Data, wantType: UInt16) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return [] }
        guard bytes[3] & 0x0F == 0 else { return [] }     // RCODE must be NOERROR
        let questionCount = Int(bytes[4]) << 8 | Int(bytes[5])
        let answerCount = Int(bytes[6]) << 8 | Int(bytes[7])

        var offset = 12
        for _ in 0..<questionCount {
            guard let next = skipName(bytes, offset) else { return [] }
            offset = next + 4
            guard offset <= bytes.count else { return [] }
        }

        var addresses: [String] = []
        for _ in 0..<answerCount {
            guard let next = skipName(bytes, offset) else { break }
            guard next + 10 <= bytes.count else { break }
            let type = UInt16(bytes[next]) << 8 | UInt16(bytes[next + 1])
            let rdLength = Int(bytes[next + 8]) << 8 | Int(bytes[next + 9])
            let rdStart = next + 10
            guard rdStart + rdLength <= bytes.count else { break }
            if type == wantType {
                if type == 1, rdLength == 4 {
                    addresses.append(
                        "\(bytes[rdStart]).\(bytes[rdStart + 1]).\(bytes[rdStart + 2]).\(bytes[rdStart + 3])"
                    )
                } else if type == 28, rdLength == 16 {
                    if let text = formatIPv6(Array(bytes[rdStart..<(rdStart + 16)])) {
                        addresses.append(text)
                    }
                }
            }
            offset = rdStart + rdLength
        }
        return addresses
    }

    /// Advances past a (possibly compressed) domain name, returning the offset after it.
    private static func skipName(_ bytes: [UInt8], _ start: Int) -> Int? {
        var offset = start
        var consumed = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 {
                return offset + 2 <= bytes.count ? offset + 2 : nil
            }
            guard length <= 63 else { return nil }
            offset += 1 + length
            consumed += 1 + length
            guard consumed <= 255 else { return nil }
        }
        return nil
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        var groups: [String] = []
        for index in stride(from: 0, to: 16, by: 2) {
            let value = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            groups.append(String(value, radix: 16))
        }
        return groups.joined(separator: ":")
    }
}