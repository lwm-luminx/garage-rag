import SwiftUI
import AppKit

/// Filter options for log severity levels.
public enum LogLevelFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Levels"
    case error = "Error"
    case warning = "Warning"
    case info = "Info"
    case debug = "Debug"
    case warningsAndErrors = "Warnings & Errors"

    public var id: String { rawValue }

    public func matches(_ level: LogLevel) -> Bool {
        switch self {
        case .all:
            return true
        case .error:
            return level == .error
        case .warning:
            return level == .warning
        case .info:
            return level == .info
        case .debug:
            return level == .debug
        case .warningsAndErrors:
            return level == .warning || level == .error
        }
    }
}

/// A comprehensive, sortable, and filterable table view for log entries.
public struct LogTableView: View {
    public let lines: [LogLine]
    public var sourceName: String?
    public var onClear: (() -> Void)?

    @State private var searchText = ""
    @State private var levelFilter: LogLevelFilter = .all
    @State private var selectedLineIDs = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\LogLine.date, order: .forward)]
    @State private var showDetailInspector = false
    /// `filteredLines`, recomputed only when the lines or a filter change. The table
    /// redraws at the log poll rate; filtering and sorting on every draw showed up.
    @State private var visibleLines: [LogLine] = []
    /// How many lines match the filters; `visibleLines` holds at most `maximumRowsShown` of them.
    @State private var matchCount = 0

    /// The most rows the table shows. A SwiftUI Table lays out and builds accessibility for every
    /// row it is given: a few thousand (the Unified Log after a fetch) kept the main thread busy
    /// for over 30 seconds. The filter reaches the rest.
    public static let maximumRowsShown = 500

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(
        lines: [LogLine],
        sourceName: String? = nil,
        onClear: (() -> Void)? = nil
    ) {
        self.lines = lines
        self.sourceName = sourceName
        self.onClear = onClear
    }

    private var effectiveSelectedLine: LogLine? {
        if let firstID = selectedLineIDs.first {
            return lines.first(where: { $0.id == firstID })
        }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterToolbar
            Divider()
            contentView
            if showDetailInspector, let line = effectiveSelectedLine {
                Divider()
                detailInspectorView(for: line)
            }
            Divider()
            statusBar
        }
        .onChange(of: filterKey, initial: true) {
            let matches = matchingLines
            matchCount = matches.count
            visibleLines = Self.rowsShown(from: matches, sortOrder: sortOrder, limit: Self.maximumRowsShown)
        }
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: 10) {
            // Text Search Field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Filter logs (text, source, level)…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .accessibilityIdentifier("logs.filter")

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .accessibilityLabel("Clear filter text")
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 180, maxWidth: 300)

            // Level Picker
            Picker("Level", selection: $levelFilter) {
                ForEach(LogLevelFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 140)
            .accessibilityIdentifier("logs.level")

            if hasActiveFilters {
                Button("Reset Filters") {
                    resetFilters()
                }
                .controlSize(.small)
                .accessibilityIdentifier("logs.resetFilters")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Status Bar

    /// The counts and the actions on the table, under it like Finder's status bar: what the
    /// table shows of the source, and Copy, Details and Clear beside it.
    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(countText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityIdentifier("logs.count")

            Spacer()

            Button(action: copyLogsToClipboard) {
                Label(selectedLineIDs.isEmpty ? "Copy All" : "Copy Selected", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(lines.isEmpty)
            .help("Copy log entries to clipboard")

            Toggle(isOn: $showDetailInspector) {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle log entry detail inspector")

            if let onClear = onClear {
                Button(action: onClear) {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(lines.isEmpty)
                .help("Clear logs for this source")
                .accessibilityIdentifier("logs.clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    /// "312 of 4000 entries", and when the table is capped, how many of the matches it shows.
    var countText: String {
        Self.countText(shown: visibleLines.count, matching: matchCount, total: lines.count)
    }

    static func countText(shown: Int, matching: Int, total: Int) -> String {
        let entries = matching == 1 && total == 1 ? "entry" : "entries"
        var text = "\(matching) of \(total) \(entries)"
        if shown < matching {
            text += ", showing the latest \(shown)"
        }
        return text
    }

    // MARK: - Main Content

    @ViewBuilder
    private var contentView: some View {
        if lines.isEmpty {
            emptyStateView(
                icon: "text.alignleft",
                title: "No Logs Recorded",
                subtitle: sourceName != nil ? "No log output has been produced by \(sourceName!) yet." : "No log output recorded yet."
            )
        } else if visibleLines.isEmpty {
            emptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Matches",
                subtitle: "No log entries match your active filter criteria."
            )
        } else {
            tableContent
        }
    }

    private var tableContent: some View {
        Table(visibleLines, selection: $selectedLineIDs, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.date) { line in
                Text(Self.timestampFormatter.string(from: line.date))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 85, ideal: 95, max: 115)

            TableColumn("PID") { line in
                if let pid = line.pid {
                    Text(verbatim: "\(pid)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("-")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 45, ideal: 55, max: 75)

            TableColumn("Level", value: \.level) { line in
                LogLevelBadge(level: line.level)
            }
            .width(min: 75, ideal: 85, max: 100)

            TableColumn("Stream", value: \.stream) { line in
                LogStreamBadge(stream: line.stream)
            }
            .width(min: 55, ideal: 65, max: 80)

            TableColumn("Source", value: \.source) { line in
                Text(line.source)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 90, max: 130)

            TableColumn("Message", value: \.text) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.level == .error ? .red : (line.level == .warning ? .orange : (line.level == .debug ? .secondary : .primary)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("logs.row.message")
            }
        }
        .contextMenu(forSelectionType: UUID.self) { selectedIDs in
            if !selectedIDs.isEmpty {
                Button("Copy Selected (\(selectedIDs.count))") {
                    copySelectedLines(ids: selectedIDs)
                }
                Button("Inspect Selected") {
                    if let firstID = selectedIDs.first {
                        selectedLineIDs = [firstID]
                        showDetailInspector = true
                    }
                }
            }
            Button("Copy All Filtered") {
                copyFilteredLogs()
            }
        }
        .accessibilityIdentifier("logs.table")
    }

    // MARK: - Detail Inspector View

    private func detailInspectorView(for line: LogLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    LogLevelBadge(level: line.level)
                    LogStreamBadge(stream: line.stream)
                    if let pid = line.pid {
                        Text(verbatim: "PID: \(pid)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("•")
                            .foregroundStyle(.secondary)
                    }
                    Text("Source: \(line.source)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(Self.timestampFormatter.string(from: line.date))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Text") {
                    NSPasteboard.general.copy(line.rawText ?? line.text)
                }
                .controlSize(.small)

                Button(action: { showDetailInspector = false }) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close log entry details")
                .buttonStyle(.plain)
                .font(.caption)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.level == .error ? .red : (line.level == .warning ? .orange : (line.level == .debug ? .secondary : .primary)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if let raw = line.rawText, raw != line.text {
                        Divider()
                            .padding(.vertical, 2)
                        Text("Raw: \(raw)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 140)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Helpers & State

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || levelFilter != .all
    }

    private func resetFilters() {
        searchText = ""
        levelFilter = .all
    }

    /// Everything `filteredLines` depends on. Lines are keyed by count and last id
    /// (O(1)); a trimmed ring buffer changes the last id even at a constant count.
    private struct FilterKey: Equatable {
        let lineCount: Int
        let lastLineID: UUID?
        let searchText: String
        let levelFilter: LogLevelFilter
        let sortOrder: [KeyPathComparator<LogLine>]
    }

    private var filterKey: FilterKey {
        FilterKey(
            lineCount: lines.count,
            lastLineID: lines.last?.id,
            searchText: searchText,
            levelFilter: levelFilter,
            sortOrder: sortOrder
        )
    }

    /// Every line that passes the filters, sorted by `sortOrder`.
    public var filteredLines: [LogLine] {
        matchingLines.sorted(using: sortOrder)
    }

    /// The table's rows: the newest `limit` of `matches`, sorted by `sortOrder`.
    static func rowsShown(from matches: [LogLine], sortOrder: [KeyPathComparator<LogLine>], limit: Int) -> [LogLine] {
        guard matches.count > limit else { return matches.sorted(using: sortOrder) }
        let newest = matches.sorted { $0.date > $1.date }.prefix(limit)
        return Array(newest).sorted(using: sortOrder)
    }

    /// Every line that passes the filters, in their original order.
    private var matchingLines: [LogLine] {
        var result = lines

        if levelFilter != .all {
            result = result.filter { levelFilter.matches($0.level) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.matches(searchText: query) }
        }

        return result
    }

    private func copyLogsToClipboard() {
        if !selectedLineIDs.isEmpty {
            copySelectedLines(ids: selectedLineIDs)
        } else {
            copyFilteredLogs()
        }
    }

    private func copyFilteredLogs() {
        let content = filteredLines.map { formatLogLineForExport($0) }.joined(separator: "\n")
        NSPasteboard.general.copy(content)
    }

    private func copySelectedLines(ids: Set<UUID>) {
        let matched = filteredLines.filter { ids.contains($0.id) }
        let content = matched.map { formatLogLineForExport($0) }.joined(separator: "\n")
        NSPasteboard.general.copy(content)
    }

    private func formatLogLineForExport(_ line: LogLine) -> String {
        let pidStr = line.pid.map { " [pid:\($0)]" } ?? ""
        return "[\(Self.timestampFormatter.string(from: line.date))] [\(line.level.rawValue.uppercased())] [\(line.source)/\(line.stream.rawValue)]\(pidStr) \(line.text)"
    }

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasActiveFilters {
                Button("Reset Filters") {
                    resetFilters()
                }
                .controlSize(.small)
                .accessibilityIdentifier("logs.resetFilters")
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
