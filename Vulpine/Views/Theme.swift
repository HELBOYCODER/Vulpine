// Theme.swift
// Color palette and typography matching FoxyVPN's Material 3 theme, mapped to native
// macOS SwiftUI semantic styles.

import SwiftUI

enum Theme {
    /// Fox accent orange — equivalent of FoxyVPN's FoxSeed (0xFFFF7139).
    static let accent = Color(red: 1.0, green: 0.443, blue: 0.224)
    static let accentDark = Color(red: 0.627, green: 0.227, blue: 0.0)

    /// Status indicator colors.
    static let connectedGreen = Color(red: 0.106, green: 0.431, blue: 0.184)
    static let connectedGreenDark = Color(red: 0.482, green: 0.875, blue: 0.573)

    static let connectingAmber = Color(red: 0.541, green: 0.353, blue: 0.0)
    static let connectingAmberDark = Color(red: 1.0, green: 0.769, blue: 0.420)

    static func statusColor(for state: ConnectionState, isDark: Bool) -> Color {
        switch state {
        case .connected: return isDark ? connectedGreenDark : connectedGreen
        case .connecting: return isDark ? connectingAmberDark : connectingAmber
        case .disconnected: return Color.secondary
        }
    }
}
