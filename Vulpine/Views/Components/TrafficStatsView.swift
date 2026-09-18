// TrafficStatsView.swift
// Live throughput indicators (↓ rx / ↑ tx) matching FoxyVPN's notification/home stats.

import SwiftUI

struct TrafficStatsView: View {
    let rxRatePerSecond: Int64
    let txRatePerSecond: Int64

    var body: some View {
        HStack(spacing: 24) {
            Label {
                Text(formatBytesPerSecond(rxRatePerSecond))
                    .font(.system(.body, design: .monospaced))
            } icon: {
                Image(systemName: "arrow.down")
                    .foregroundColor(.blue)
            }

            Label {
                Text(formatBytesPerSecond(txRatePerSecond))
                    .font(.system(.body, design: .monospaced))
            } icon: {
                Image(systemName: "arrow.up")
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }
}
