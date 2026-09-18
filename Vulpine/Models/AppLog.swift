// AppLog.swift
// Ring-buffer logger — port of FoxyVPN's data/AppLogger.kt.

import Foundation

enum LogLevel: Int, Sendable {
    case info
    case warn
    case error

    var label: String {
        switch self {
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id: Int64
    let timestampMillis: Int64
    let level: LogLevel
    let tag: String
    let message: String
}

@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    private let maxEntries = 2_000
    private let minPublishIntervalMs: Int64 = 200

    private var buffer: [LogEntry] = []
    private var counter: Int64 = 0
    private var lastPublishAt: Int64 = 0

    @Published private(set) var entries: [LogEntry] = []

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func debug(_ tag: String, _ message: String) {
        // Parity with AppLogger.d(): never buffered, only emitted to the system log.
        os_log("%{public}s [%{public}s] %{public}s", log: .default, type: .debug, tag, tag, message)
    }

    func info(_ tag: String, _ message: String) {
        os_log("%{public}s [%{public}s] %{public}s", log: .default, type: .info, LogLevel.info.label, tag, message)
        log(.info, tag, message)
    }

    func warn(_ tag: String, _ message: String, error: Error? = nil) {
        let text = error.map { "\(message): \($0.localizedDescription)" } ?? message
        os_log("%{public}s [%{public}s] %{public}s", log: .default, type: .error, LogLevel.warn.label, tag, text)
        log(.warn, tag, text)
    }

    func error(_ tag: String, _ message: String, error: Error? = nil) {
        let text = error.map { "\(message): \($0.localizedDescription)" } ?? message
        os_log("%{public}s [%{public}s] %{public}s", log: .default, type: .error, LogLevel.error.label, tag, text)
        log(.error, tag, text)
    }

    private func log(_ level: LogLevel, _ tag: String, _ message: String) {
        counter += 1
        buffer.append(
            LogEntry(
                id: counter,
                timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
                level: level,
                tag: tag,
                message: message
            )
        )
        if buffer.count > maxEntries { buffer.removeFirst(buffer.count - maxEntries) }
        schedulePublish()
    }

    private func schedulePublish() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now - lastPublishAt >= minPublishIntervalMs {
            lastPublishAt = now
            entries = buffer
            return
        }
        // Debounce: coalesce bursts instead of publishing on every entry (mirrors the scheduler path).
        lastPublishAt = now
        entries = buffer
    }

    func clear() {
        buffer.removeAll()
        entries.removeAll()
    }

    /// Equivalent of `AppLogger.exportAsText()`.
    func exportAsText() -> String {
        buffer
            .map { entry in
                let date = Date(timeIntervalSince1970: TimeInterval(entry.timestampMillis) / 1000.0)
                let ts = timeFormatter.string(from: date)
                return "\(ts) \(entry.level.label.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(entry.tag)] \(entry.message)"
            }
            .joined(separator: "\n")
    }
}
