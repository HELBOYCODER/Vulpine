// ProxyStateStore.swift
// Port of FoxyVPN's data/ProxyStateStore.kt — last chosen exit server, with failure tracking.

import Foundation
import Combine

final class ProxyStateStore: ObservableObject {
    static let shared = ProxyStateStore()

    private let defaults = UserDefaults.standard
    private let failureThreshold = 3

    @Published var selectedProxy: ProxyCandidate?

    private init() {
        selectedProxy = load()
    }

    func load() -> ProxyCandidate? {
        guard let host = defaults.string(forKey: Key.host) else { return nil }
        let port = defaults.integer(forKey: Key.port)
        guard port != 0 else { return nil }
        return ProxyCandidate(
            host: host,
            port: port,
            countryCode: defaults.string(forKey: Key.countryCode) ?? "",
            countryName: defaults.string(forKey: Key.countryName) ?? "",
            cityCode: defaults.string(forKey: Key.cityCode) ?? ""
        )
    }

    func save(_ candidate: ProxyCandidate) {
        defaults.set(candidate.host, forKey: Key.host)
        defaults.set(candidate.port, forKey: Key.port)
        defaults.set(candidate.countryCode, forKey: Key.countryCode)
        defaults.set(candidate.countryName, forKey: Key.countryName)
        defaults.set(candidate.cityCode, forKey: Key.cityCode)
        defaults.set(0, forKey: Key.failures)
        selectedProxy = candidate
    }

    /// Returns (failureCount, shouldDiscardServer); mirrors ProxyStateStore.recordFailure().
    @discardableResult
    func recordFailure() -> (failures: Int, shouldDiscard: Bool) {
        let failures = defaults.integer(forKey: Key.failures) + 1
        if failures >= failureThreshold {
            clear()
            return (failures, true)
        }
        defaults.set(failures, forKey: Key.failures)
        return (failures, false)
    }

    func clear() {
        for key in [Key.host, Key.port, Key.countryCode, Key.countryName, Key.cityCode, Key.failures] {
            defaults.removeObject(forKey: key)
        }
        selectedProxy = nil
    }

    private enum Key {
        static let host = "proxy_host"
        static let port = "proxy_port"
        static let countryCode = "proxy_country_code"
        static let countryName = "proxy_country_name"
        static let cityCode = "proxy_city_code"
        static let failures = "proxy_failures"
    }
}
