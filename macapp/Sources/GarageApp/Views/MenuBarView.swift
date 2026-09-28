import AppKit
import SwiftUI

/// The menu bar item's popover. Top to bottom: a header with the two commands every menu bar app
/// owes its user (open the window, quit), a quick search of the corpus, one row for the services,
/// and what the pipeline is doing with a way to start or stop it.
///
/// Everything else the app can do lives in the window, one click away on any row.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 540

    var body: some View {
        let status = MenuBarStatus(appState: appState)
        VStack(alignment: .leading, spacing: 10) {
            header

            MenuBarQuickSearch(isEnabled: status.canSearch, canAsk: status.canAsk)

            servicesModule(status)

            if status.database == .running {
                activityModule(status)
            }
        }
        .padding(12)
        .frame(width: Self.width)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Garage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            MenuBarHeaderButton(symbol: "macwindow", help: "Open Garage (⌘O)", key: "o") {
                MenuBarNavigation.openMainWindow(openWindow: openWindow)
            }
            .accessibilityIdentifier("menubar.openGarage")

            MenuBarHeaderButton(symbol: "power", help: "Quit Garage (⌘Q)", key: "q") {
                AppDelegate.quit()
            }
            .accessibilityIdentifier("menubar.quit")
        }
        .padding(.leading, 2)
    }

    // MARK: - Services

    /// One row for the services. "All systems go" when everything is fine; otherwise a short summary
    /// of the worst problem. Either way the row opens the Status page, where the fixes live: the
    /// popover is too small to be a control panel.
    private func servicesModule(_ status: MenuBarStatus) -> some View {
        let summary = status.summary
        return MenuBarModule {
            MenuBarRow(
                symbol: summary.symbol,
                tint: summary.tint,
                title: summary.title,
                detail: summary.detail,
                action: { show(.status) }
            )
            .accessibilityIdentifier(status.allSystemsGo ? "menubar.allSystemsGo" : "menubar.problem")
        }
        .accessibilityIdentifier("menubar.services")
    }

    // MARK: - Activity

    /// What the pipeline is doing, and the one action that fits: "Ingest Now" while idle, "Stop"
    /// while it runs. The module's title line doubles as the popover's status line.
    private func activityModule(_ status: MenuBarStatus) -> some View {
        MenuBarModule {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        show(.status)
                    } label: {
                        HStack(spacing: 6) {
                            if status.showsActivityDot {
                                Circle()
                                    .fill(status.tint)
                                    .frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                            }
                            Text(status.showsActivityDot ? status.headline : status.corpusLine)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if let fraction = status.ingestFraction {
                                Text(MenuBarStatus.percent(fraction))
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuBarRowButtonStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("menubar.status")

                    Spacer(minLength: 4)

                    activityAction(status)
                }

                if status.isBusy {
                    if let fraction = status.ingestFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                    if let detail = status.activityDetail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    if let item = status.currentItem {
                        Text(MenuBarStatus.abbreviatedPath(item))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    MenuBarStageTrail(stages: status.stageTrail, current: status.stage)
                        .padding(.top, 2)
                }

                ForEach(Array(status.attentions.enumerated()), id: \.offset) { _, attention in
                    attentionRow(attention)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .accessibilityIdentifier("menubar.activity")
    }

    @ViewBuilder
    private func activityAction(_ status: MenuBarStatus) -> some View {
        switch status.activity {
        case .idle:
            if status.database == .running {
                MenuBarActionButton(title: "Ingest Now", isDisabled: !status.canIngest) {
                    Task { await appState.ingestAllSources() }
                }
                .help(status.sourceCount == 0 ? "Add a source in Garage first." : "Scan and ingest every source.")
                .accessibilityIdentifier("menubar.ingest")
            }
        case .ingesting:
            MenuBarActionButton(
                title: status.isCancellingIngest ? "Stopping…" : "Stop",
                isDestructive: true,
                isDisabled: status.isCancellingIngest
            ) {
                appState.cancelAll()
            }
            .accessibilityIdentifier("menubar.cancel")
        case .scanning:
            MenuBarActionButton(title: "Stop", isDestructive: true) {
                appState.cancelAll()
            }
            .accessibilityIdentifier("menubar.cancel")
        case .embedding:
            MenuBarActionButton(title: "Stop", isDestructive: true) {
                // cancelAll stops a backfill only when maintenance started it; this one may not have.
                appState.cancelAll()
                appState.backfill.cancel()
            }
            .accessibilityIdentifier("menubar.cancel")
        case .distilling:
            MenuBarActionButton(title: "Stop", isDestructive: true) {
                appState.enrichFacts.cancel()
            }
            .accessibilityIdentifier("menubar.cancel")
        }
    }

    /// One line per problem, with the page that explains it a click away. Database and MCP failures
    /// already colour their service row, so here they only get their "why"; a failed ingest has no
    /// row of its own and is the one people otherwise never learn about.
    @ViewBuilder
    private func attentionRow(_ attention: MenuBarStatus.Attention) -> some View {
        switch attention {
        case .ingestFailed(let message):
            attentionLine("Last ingest failed: \(message)", section: .status)
        case .databaseFailed, .databaseNeedsMigration, .mcpFailed:
            EmptyView()
        }
    }

    private func attentionLine(_ text: String, section: AppSection) -> some View {
        Button {
            show(section)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .padding(.top, 2)
        .accessibilityIdentifier("menubar.attention")
    }

    // MARK: - Navigation

    private func show(_ section: AppSection) {
        MenuBarNavigation.show(section, openWindow: openWindow)
    }
}
