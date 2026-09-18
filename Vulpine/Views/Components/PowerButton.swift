// PowerButton.swift
// The prominent circular power button — port of FoxyVPN's HomeScreen power button.

import SwiftUI

struct PowerButton: View {
    let state: ConnectionState
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(buttonFill)
                    .frame(width: 140, height: 140)
                    .shadow(color: shadowColor, radius: state == .connected ? 12 : 6, y: 4)

                if state == .connecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundColor(iconTint)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var buttonFill: Color {
        switch state {
        case .connected:
            return colorScheme == .dark ? Theme.connectedGreenDark : Theme.connectedGreen
        case .connecting:
            return colorScheme == .dark ? Theme.connectingAmberDark : Theme.connectingAmber
        case .disconnected:
            return Theme.accent
        }
    }

    private var iconTint: Color {
        switch state {
        case .connected:
            return colorScheme == .dark ? .black : .white
        default:
            return .white
        }
    }

    private var shadowColor: Color {
        buttonFill.opacity(colorScheme == .dark ? 0.4 : 0.25)
    }
}
