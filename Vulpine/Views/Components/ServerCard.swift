// ServerCard.swift
// Compact card displaying the selected exit country and city — opens the server picker.

import SwiftUI

struct ServerCard: View {
    let candidate: ProxyCandidate?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(countryTitle)
                        .font(.headline)
                    Text(citySubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var countryTitle: String {
        guard let candidate else { return "Select location" }
        return candidate.countryName.isEmpty ? candidate.countryCode : candidate.countryName
    }

    private var citySubtitle: String {
        guard let candidate else { return "Choose an exit edge" }
        return candidate.cityCode.isEmpty ? candidate.authority : "\(candidate.cityCode) • \(candidate.authority)"
    }
}
