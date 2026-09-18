// LogsView.swift
// Port of FoxyVPN's ui/screens/LogsScreen.kt — ring-buffer logs with filtering, search,
// copy, clear, and export.

import SwiftUI
import AppKit

struct LogsView: View {
    @ObservedObject var log = AppLog.shared
    let onDismiss: () -> Void

    @State private var filter: LogFilter = .all
    @State private var copied = false

    enum LogFilter: String, CaseIterable {
        case all = "All"
        case problems = "Problems"
        case info = "Info"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            logList
        }
        .frame(width: 580, height: 460)
    }

    private var header: some View {
        HStack {
            Text("Diagnostics & Logs")
                .font(.headline)
            Spacer()
            Button("Done", action: onDismiss)
        }
        .padding()
    }

    private var toolbar: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(LogFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 200)

            Spacer()

            Button(copied ? "Copied!" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.exportAsText(), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }

            Button("Clear") { log.clear() }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filteredEntries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.level.label)
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(levelColor(entry.level))
                            .frame(width: 44, alignment: .leading)

                        Text("[\(entry.tag)]")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var filteredEntries: [LogEntry] {
        switch filter {
        case .all: return log.entries
        case .problems: return log.entries.filter { $0.level == .warn || $0.level == .error }
        case .info: return log.entries.filter { $0.level == .info }
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
