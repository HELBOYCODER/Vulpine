// ByteFormat.swift
// Port of FoxyVPN's data/ByteFormat.kt

import Foundation

private let unit: Double = 1024.0
private let units = ["KB", "MB", "GB", "TB", "PB"]

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 0 { return "—" }
    if bytes < 1024 { return "\(bytes) B" }
    var value = Double(bytes) / unit
    var index = 0
    while value >= unit && index < units.count - 1 {
        value /= unit
        index += 1
    }
    let pattern = value >= 100 ? "%.0f %s" : "%.1f %s"
    return String(format: pattern, value, units[index])
}

func formatBytesPerSecond(_ bytesPerSecond: Int64) -> String {
    "\(formatBytes(max(0, bytesPerSecond)))/s"
}
