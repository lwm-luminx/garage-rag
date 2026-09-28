import SwiftUI
import OSLog

public struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var source: LogSource = .postgres
    @State private var selectedTimeWindow: OSLogTimeWindow = .recent5m

    public enum LogSource: String, CaseIterable, Identifiable, Sendable, Hashable {
        case unifiedLog = "Unified Log"
        case postgres = "Postgres"
        case garage = "App"
        case ingest = "Ingest"
        case embed = "Embed"
        case mcp = "MCP Server"
        case grpc = "Index Manager"
        case llama = "Built-in Engine"
        case modelDownload = "Downloader"

        public var id: String { rawValue }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            sourcePickerToolbar
            Divider()

            osLogStreamingControlsBar
            Divider()

            LogTableView(
                lines: lines,
                sourceName: source.rawValue,
                onClear: {
                    appState.clearLogs(for: source.rawValue)
                }
            )
            .id(source)
        }
        .navigationTitle("Logs")
        .onAppear {
            configureStreamingForCurrentSource()
        }
        .onChange(of: source) {
            configureStreamingForCurrentSource()
        }
    }

    // MARK: - Source Picker Toolbar

    private var sourcePickerToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Picker("Log Source", selection: $source) {
                ForEach(LogSource.allCases) { src in
                    Text(src.rawValue).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("logs.source")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - OSLog Streaming Controls Bar

    private var osLogStreamingControlsBar: some View {
        HStack(spacing: 12) {
            // Live Status Indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(streamingStatusColor)
                    .frame(width: 8, height: 8)

                Text(streamingStatusText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(appState.osLogStreamService.isStreaming && !appState.osLogStreamService.isPaused ? .primary : .secondary)

                if let lastPolled = appState.osLogStreamService.lastPolledDate {
                    Text("(\(Self.timeFormatter.string(from: lastPolled)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            Divider()
                .frame(height: 14)

            // Pause / Resume Toggle
            Button(action: {
                appState.osLogStreamService.togglePause()
            }) {
                Label(
                    appState.osLogStreamService.isPaused ? "Resume Stream" : "Pause Stream",
                    systemImage: appState.osLogStreamService.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.plain)
            .font(.caption)
            .controlSize(.small)
            .accessibilityIdentifier("logs.pause")

            Spacer()

            // Time Window Fetch Menu
            Menu {
                ForEach(OSLogTimeWindow.allCases) { window in
                    Button("Fetch Past \(window.rawValue)") {
                        fetchHistoricalOSLogs(window: window)
                    }
                }
            } label: {
                Label("Fetch OSLog", systemImage: "arrow.clockwise.circle")
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .controlSize(.small)
            .help("Fetch historical entries from OSLogStore")
            .accessibilityIdentifier("logs.fetch")

            Divider()
                .frame(height: 14)

            // The Logs view is where a user first sees something go wrong, so
            // the reporter opens here pre-loaded with the stream they are on.
            Button {
                NotificationCenter.default.post(
                    name: .garageShowBugReport,
                    object: BugReportContext(logSource: source, attachLogs: true)
                )
            } label: {
                Label("Report a Bug", systemImage: "ladybug")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .controlSize(.small)
            .help("Open a bug report with these log lines attached")
            .accessibilityIdentifier("logs.reportBug")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Streaming Actions

    /// One stream serves every source: entries are routed by category, so switching
    /// sources only changes which routed lines are shown.
    private func configureStreamingForCurrentSource() {
        if !appState.osLogStreamService.isStreaming {
            appState.osLogStreamService.startStreaming(since: Date().addingTimeInterval(-300), paused: true)
        }
    }

    private func fetchHistoricalOSLogs(window: OSLogTimeWindow) {
        appState.osLogStreamService.fetchRecentLogs(timeWindow: window.interval)
    }

    // MARK: - Status Helpers

    private var streamingStatusColor: Color {
        if !appState.osLogStreamService.isStreaming {
            return .secondary
        }
        if appState.osLogStreamService.isPaused {
            return .orange
        }
        return .green
    }

    private var streamingStatusText: String {
        if !appState.osLogStreamService.isStreaming {
            return "OSLog Inactive"
        }
        if appState.osLogStreamService.isPaused {
            return "OSLog Paused (\(source.rawValue))"
        }
        return "Live OSLog (\(source.rawValue))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - Log Lines Source

    private var lines: [LogLine] {
        appState.osLogStreamService.logs(for: source)
    }
}
