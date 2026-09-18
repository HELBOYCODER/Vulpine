// ServerListClient.swift
// Port of FoxyVPN's data/ServerListClient.kt — Mozilla Remote Settings server list.

import Foundation

private let remoteSettingsURL =
    "https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records"

let recommendedCountryCode = "REC"

private let excludedCountryNames: Set<String> = ["CatchAll Anycast"]

enum ServerListClient {
    /// `ServerListClient.fetchCountries()` parity.
    static func fetchCountries() async throws -> [VpnCountry] {
        let (status, text) = try await HTTPClient.send("GET", url: remoteSettingsURL, body: nil)
        guard status == 200 else {
            throw AppError.http(status: status, body: "Remote Settings fetch failed")
        }

        let body = try text.asJSON()
        let records = body.array("data") ?? []
        var countries: [VpnCountry] = []
        for record in records {
            guard let recordObject = record as? [String: Any] else { continue }
            let countryObject = recordObject.object("country") ?? recordObject
            let country = parseCountry(countryObject)
            let isExcluded = excludedCountryNames.contains(where: {
                $0.lowercased() == country.name.lowercased()
            })
            guard !country.code.isEmpty,
                  !country.cities.isEmpty,
                  !isExcluded
            else { continue }
            countries.append(country)
        }
        await AppLog.shared.info("ServerListClient", "fetched \(countries.size) countries from Remote Settings")
        return countries
    }

    private static func parseCountry(_ json: [String: Any]) -> VpnCountry {
        VpnCountry(
            name: json.string("name"),
            code: json.string("code"),
            cities: (json.array("cities") ?? []).compactMap { $0 as? [String: Any] }.map(parseCity)
        )
    }

    private static func parseCity(_ json: [String: Any]) -> VpnCity {
        VpnCity(
            name: json.string("name"),
            code: json.string("code"),
            servers: (json.array("servers") ?? []).compactMap { $0 as? [String: Any] }.map(parseServer)
        )
    }

    private static func parseServer(_ json: [String: Any]) -> VpnServerNode {
        VpnServerNode(
            hostname: json.string("hostname"),
            port: json.int("port"),
            quarantined: json.bool("quarantined"),
            protocols: (json.array("protocols") ?? []).compactMap { $0 as? [String: Any] }.map(parseProtocol)
        )
    }

    private static func parseProtocol(_ json: [String: Any]) -> VpnProtocol {
        VpnProtocol(
            name: json.string("name"),
            host: json.string("host"),
            port: json.int("port"),
            scheme: json.string("scheme"),
            templateString: json.string("templateString")
        )
    }
}

private extension Array {
    var size: Int { count }
}
