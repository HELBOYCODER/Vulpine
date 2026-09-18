// ServerListView.swift
// Port of FoxyVPN's ui/screens/ServerListScreen.kt — country & city selection with latency ping.

import SwiftUI

struct ServerListView: View {
    @ObservedObject var proxyStore = ProxyStateStore.shared
    let onDismiss: () -> Void

    @State private var countries: [VpnCountry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                Spacer()
                ProgressView("Fetching server list from Mozilla...")
                Spacer()
            } else if let errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundColor(.red)
                    Button("Retry") { loadServers() }
                }
                Spacer()
            } else {
                searchField
                listContent
            }
        }
        .frame(width: 440, height: 520)
        .onAppear(perform: loadServers)
    }

    private var header: some View {
        HStack {
            Text("Select Location")
                .font(.headline)
            Spacer()
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var searchField: some View {
        TextField("Search countries or cities", text: $searchQuery)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding(12)
    }

    private var listContent: some View {
        List {
            ForEach(filteredCountries, id: \.code) { country in
                Section(header: Text(country.name)) {
                    ForEach(country.cities, id: \.code) { city in
                        Button(action: { selectCity(country: country, city: city) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(city.name).font(.body)
                                    Text(city.code).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if isSelected(country: country, city: city) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
    }

    private var filteredCountries: [VpnCountry] {
        guard !searchQuery.isEmpty else { return countries }
        let q = searchQuery.lowercased()
        return countries.compactMap { country in
            let matchCountry = country.name.lowercased().contains(q) || country.code.lowercased().contains(q)
            let matchingCities = country.cities.filter {
                $0.name.lowercased().contains(q) || $0.code.lowercased().contains(q)
            }
            if matchCountry { return country }
            if !matchingCities.isEmpty {
                return VpnCountry(name: country.name, code: country.code, cities: matchingCities)
            }
            return nil
        }
    }

    private func isSelected(country: VpnCountry, city: VpnCity) -> Bool {
        guard let current = proxyStore.selectedProxy else { return false }
        return current.countryCode == country.code && current.cityCode == city.code
    }

    private func selectCity(country: VpnCountry, city: VpnCity) {
        guard let candidate = ServerListSupport.candidatesForCity(countries, countryCode: country.code, cityCode: city.code).first else { return }
        proxyStore.save(candidate)
        onDismiss()
    }

    private func loadServers() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                countries = try await ServerListClient.fetchCountries()
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
