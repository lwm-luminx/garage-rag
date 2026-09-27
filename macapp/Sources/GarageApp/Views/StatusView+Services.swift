import SwiftUI
import AppKit
import PythonXPCService

/// The Index Manager box (the gRPC backend) and the Helper Services box (one row per XPC helper),
/// each row with Test, Restart and a chevron to its status report, self tests and the last test's
/// output. Rows carry a small dot rather than a filled circle: seven green circles in a column read
/// as noise, and the dot is the Models page's idiom for a list of like things.
extension StatusView {
    var indexManagerSection: some View {
        GroupBox("Index Manager") {
            grpcRow
                .padding(10)
        }
    }

    /// Titled with `GroupBox("Helper Services")`, with the box's buttons on its first row rather
    /// than in a custom label: on macOS a GroupBox's custom label is not in the accessibility tree,
    /// so neither the title nor Test All, Restart All and Refresh could be reached there.
    var servicesSection: some View {
        GroupBox("Helper Services") {
            VStack(spacing: 0) {
                servicesToolbar
                    .padding(.bottom, 8)
                ForEach(Array(appState.xpcServices.services.enumerated()), id: \.element.id) { index, service in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 8)
                    }
                    xpcRow(for: service)
                }
            }
            .padding(10)
        }
    }

    private var servicesToolbar: some View {
        HStack(spacing: 8) {
            if let lastRefreshed = appState.xpcServices.lastRefreshedAt {
                Text("Checked \(lastRefreshed, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appState.xpcServices.isRefreshingAll || appState.xpcServices.isTestingAll || isTestingGrpc {
                ProgressView().controlSize(.mini)
            }
            Button("Test All") {
                runAllTests()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.xpcServices.isTestingAll || isTestingGrpc)
            .help("Run every helper's tests, and query the Index Manager")
            .accessibilityIdentifier("status.services.testAll")
            Button("Restart All") {
                Task { await appState.xpcServices.restartAll() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.xpcServices.isRefreshingAll || appState.xpcServices.isRestartingAll)
            .help("Stop every helper process; each starts again on its next request")
            .accessibilityIdentifier("status.services.restartAll")
            Button {
                Task {
                    await appState.xpcServices.refreshAll()
                    await appState.grpc.refreshStatus()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(appState.xpcServices.isRefreshingAll || appState.xpcServices.isRestartingAll)
            .help("Check every helper again")
            .accessibilityLabel("Refresh Services")
            .accessibilityIdentifier("status.services.refresh")
        }
    }

    func runAllTests() {
        Task {
            isTestingGrpc = true
            grpcTestResult = await appState.grpc.testServiceQuery()
            isTestingGrpc = false
            await appState.xpcServices.runAllDiagnosticTests()
        }
    }

    // MARK: - Rows

    /// The row's first line: dot, title, state, then the actions and the chevron. `title` is the
    /// service's name in a list of them, or its state in a box that already names it.
    private func serviceRow<Actions: View>(
        _ row: ServiceRowPresentation,
        title: String? = nil,
        isExpanded: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if row.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(row.isActive ? row.tint : Color.clear)
                        .overlay(Circle().strokeBorder(row.tint, lineWidth: row.isActive ? 0 : 1.5))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? row.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(row.detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            actions()
            Button(action: toggle) {
                DisclosureChevron(isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide \(row.name) details" : "Show \(row.name) details")
            .accessibilityIdentifier("status.service.\(row.id).details")
        }
    }

    private var grpcRow: some View {
        let row = ServiceRowPresentation.grpc(
            status: appState.grpc.status,
            address: appState.grpc.shortAddress,
            lastTest: grpcTestResult.map { (isSuccess: $0.isSuccess, summary: $0.summary) }
        )
        let isExpanded = expandedServiceIds.contains(row.id)
        return VStack(alignment: .leading, spacing: 8) {
            serviceRow(row, title: row.stateTitle, isExpanded: isExpanded, toggle: { toggleExpanded(row.id) }) {
                Button {
                    Task {
                        isTestingGrpc = true
                        grpcTestResult = await appState.grpc.testServiceQuery()
                        isTestingGrpc = false
                        _ = withAnimation { expandedServiceIds.insert("grpc") }
                    }
                } label: {
                    if isTestingGrpc {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTestingGrpc || appState.grpc.status != .running)
                .help("Call GetStatus, GetVersion, ListModels, ListSources and GetStats")
                .accessibilityIdentifier("status.service.grpc.test")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    detailLine("Address", appState.grpc.address, monospaced: true)
                    detailLine("Process", "The Python GarageService over gRPC: search, documents, sources, models, stats, and every operation the app runs.")
                    if let result = grpcTestResult {
                        testOutput(id: "grpc", isSuccess: result.isSuccess, summary: result.summary, durationMs: result.durationMs, details: result.details)
                    } else {
                        Text("Test queries the backend and shows its answers here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 26)
            }
        }
    }

    private func xpcRow(for service: XPCServiceInfo) -> some View {
        let report = appState.xpcServices.statusReports[service.id]
        let test = appState.xpcServices.diagnosticResults[service.id]
        let row = ServiceRowPresentation.xpc(service, report: report, test: test)
        let isExpanded = expandedServiceIds.contains(service.id)
        let isTesting = appState.xpcServices.testingServiceIds.contains(service.id)
        let isRestarting = appState.xpcServices.restartingServiceIds.contains(service.id)

        return VStack(alignment: .leading, spacing: 8) {
            serviceRow(row, isExpanded: isExpanded, toggle: { toggleExpanded(service.id) }) {
                Button {
                    Task {
                        _ = await appState.xpcServices.runDiagnosticTest(for: service.id)
                        _ = withAnimation { expandedServiceIds.insert(service.id) }
                    }
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting || service.isChecking)
                .help(ServiceDiagnosticTest.primary(for: service.id).description)
                .accessibilityIdentifier("status.service.\(service.id).test")

                Button("Restart") {
                    Task { await appState.xpcServices.restart(serviceId: service.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.isChecking || isRestarting || appState.xpcServices.isRestartingAll)
                .help("Stop the helper process; it starts again on its next request")
                .accessibilityIdentifier("status.service.\(service.id).restart")
            }

            if isExpanded {
                xpcDetails(for: service, report: report, test: test, isBusy: isTesting || isRestarting || service.isChecking)
                    .padding(.leading, 26)
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedServiceIds.contains(id) {
                expandedServiceIds.remove(id)
            } else {
                expandedServiceIds.insert(id)
            }
        }
    }

    // MARK: - Details

    /// What the helper reports about itself, its self tests, and the last functional test's output.
    private func xpcDetails(for service: XPCServiceInfo, report: GarageXPCStatusReport?, test: ServiceDiagnosticTestResult?, isBusy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    detailLine("Process", processLine(service, report: report), monospaced: true)
                    if let report {
                        detailLine("Python", pythonLine(report.python), monospaced: report.python.error == nil, isError: report.python.error != nil)
                    }
                    if let path = report?.logFilePath, !path.isEmpty {
                        detailLine("Log file", MenuBarStatus.abbreviatedPath(path), monospaced: true)
                    }
                }
                Spacer()
                if report != nil {
                    Menu {
                        Button("Restart Managed Services") {
                            Task { _ = await appState.xpcServices.restartManagedServices(serviceId: service.id, graceful: true) }
                        }
                        .help("Ask the helper to restart the servers it manages, waiting for each to finish")
                        Button("Force Restart Managed Services") {
                            Task { _ = await appState.xpcServices.restartManagedServices(serviceId: service.id, graceful: false) }
                        }
                        .help("Kill and restart the servers the helper manages")
                        Button("Run Self Tests") {
                            Task { _ = await appState.xpcServices.runServiceSelfTests(serviceId: service.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(isBusy)
                    .accessibilityLabel("More \(ServiceRowPresentation.name(forServiceId: service.id)) Actions")
                }
            }

            if let report {
                if !report.services.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Managed services")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(report.services, id: \.name) { managed in
                            managedServiceLine(managed)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Self tests")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let lastRun = report.lastTestRun {
                            Text("ran \(Date(timeIntervalSince1970: lastRun), style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if report.tests.isEmpty {
                        Text("None reported yet. Test runs them.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(report.tests.enumerated()), id: \.offset) { _, result in
                            selfTestLine(result)
                        }
                    }
                }

                if !report.recentErrorLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent errors")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        MonospaceOutputBox(report.recentErrorLines.joined(separator: "\n"), maxHeight: 160)
                    }
                }

                if let crash = report.lastCrashReport, !crash.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Crash report")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        MonospaceOutputBox(crash, maxHeight: 160)
                    }
                }
            } else {
                Text("No status report from this helper yet. Test asks for one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let test {
                testOutput(id: service.id, isSuccess: test.isSuccess, summary: test.summary, durationMs: test.durationMs, details: test.details, name: test.testName)
            }
        }
    }

    private func processLine(_ service: XPCServiceInfo, report: GarageXPCStatusReport?) -> String {
        var parts = [service.bundleId]
        if let pid = service.pid { parts.append("pid \(pid)") }
        if let report {
            parts.append(report.lifecycle)
            parts.append("up \(formatUptime(report.uptimeSeconds))")
        }
        return parts.joined(separator: " · ")
    }

    private func pythonLine(_ python: GarageXPCPythonStatus) -> String {
        if let error = python.error, !error.isEmpty {
            return "\(python.state): \(error)"
        }
        let version = python.version?.split(separator: " ").first.map(String.init) ?? python.state
        var line = version
        if let home = python.home, !home.isEmpty { line += " · \(MenuBarStatus.abbreviatedPath(home))" }
        if let initMs = python.initializationMs { line += String(format: " · started in %.0f ms", initMs) }
        return line
    }

    private func managedServiceLine(_ managed: GarageXPCManagedServiceStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(managedServiceColor(managed.state))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(managed.name)
                .font(.caption.weight(.medium))
            Text(managed.state)
                .font(.caption)
                .foregroundStyle(.secondary)
            if managed.restartCount > 0 {
                Text("restarted \(managed.restartCount)×")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let detail = managed.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func selfTestLine(_ test: GarageXPCTestResult) -> some View {
        let (icon, color): (String, Color) = switch test.status {
        case .passed: ("checkmark.circle.fill", .green)
        case .failed: ("xmark.circle.fill", .red)
        case .skipped: ("minus.circle", .gray)
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(test.name)
                    .font(.caption.weight(.medium))
                Text(String(format: "%.0f ms", test.durationMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(test.summary)
                    .font(.caption)
                    .foregroundStyle(test.status == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(2)
                Spacer()
            }
            if test.status == .failed {
                if let error = test.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.leading, 18)
                }
                if !test.details.isEmpty {
                    MonospaceOutputBox(test.details, maxHeight: 140)
                        .padding(.leading, 18)
                }
            } else if !test.details.isEmpty {
                DisclosureGroup {
                    MonospaceOutputBox(test.details, maxHeight: 120)
                } label: {
                    Text("Output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .padding(.leading, 18)
            }
        }
    }

    /// The last functional test's verdict and output, with Copy.
    private func testOutput(id: String, isSuccess: Bool, summary: String, durationMs: Double, details: String, name: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isSuccess ? Color.green : Color.red)
                Text(name ?? "Test")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(isSuccess ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.red))
                    .lineLimit(2)
                Text(String(format: "%.0f ms", durationMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(copiedServiceId == id ? "Copied" : "Copy") {
                    NSPasteboard.general.copy(details)
                    copiedServiceId = id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedServiceId == id { copiedServiceId = nil }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if !details.isEmpty {
                MonospaceOutputBox(details, maxHeight: 140)
            }
        }
    }

    private func detailLine(_ label: String, _ value: String, monospaced: Bool = false, isError: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func managedServiceColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "running": .green
        case "starting", "restarting", "stopping": .blue
        case "failed": .red
        case "stopped": .orange
        default: .secondary
        }
    }

    func formatUptime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        if total < 86400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86400)d \((total % 86400) / 3600)h"
    }
}
