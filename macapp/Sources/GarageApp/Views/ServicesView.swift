import SwiftUI
import AppKit
import Combine
import GarageXPCKit

// The Services page, under Advanced: the Index Manager (the gRPC backend), one row per helper
// process with Test, Restart and its status report, and the helpers' output folded away at the
// bottom. These were the lower half of the Status page, which now shows a helper only when
// something is wrong with it (`StatusHealth`). The rows are in ServicesView+Rows.swift and
// their wording in StatusPagePresentation.swift (`ServiceRowPresentation`).

@MainActor
struct ServicesView: View {
    @EnvironmentObject var appState: AppState

    @State var refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State var expandedServiceIds: Set<String> = []
    @State var grpcTestResult: (isSuccess: Bool, summary: String, details: String, durationMs: Double)? = nil
    @State var isTestingGrpc: Bool = false
    @State var copiedServiceId: String? = nil
    @AppStorage("garage.status.showServiceOutput") private var showServiceOutput = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                indexManagerSection
                servicesSection
                serviceOutputSection
            }
            .padding(20)
        }
        .navigationTitle("Services")
        .onAppear {
            Task {
                await appState.xpcServices.refreshAll()
                await appState.grpc.refreshStatus()
                if appState.xpcServices.statusReports.isEmpty {
                    await appState.xpcServices.refreshAllStatusReports()
                }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task { await appState.xpcServices.refreshAll() }
        }
    }

    // MARK: - Service output

    /// The XPC manager's log, folded away: it is for looking into a helper that stopped answering,
    /// not for glancing at.
    @ViewBuilder
    private var serviceOutputSection: some View {
        let lines = appState.xpcServices.logs
        if !lines.isEmpty {
            GroupBox {
                if showServiceOutput {
                    LogTableView(lines: lines, sourceName: "XPC Services") {
                        appState.clearLogs(for: "XPC Services")
                    }
                    .frame(minHeight: 200, maxHeight: 350)
                }
            } label: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showServiceOutput.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: showServiceOutput)
                        Text("Service Output")
                        Text("\(lines.count.formatted()) \(IndexingPresentation.plural("line", lines.count))")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("status.serviceOutput.toggle")
            }
        }
    }
}
