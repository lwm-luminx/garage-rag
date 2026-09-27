import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PythonXPCService

/// Full-window setup assistant shown on a fresh install (and on demand from
/// the "Setup Assistant…" menu item). Four pages: wait for services, pick
/// data sources, pick models, connect an agent.
@MainActor
struct FirstRunView: View {
    @EnvironmentObject var appState: AppState

    private var coordinator: FirstRunCoordinator { appState.firstRun }

    var body: some View {
        HStack(spacing: 0) {
            stepRail
                .frame(width: 220)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                pageHeader
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 16)

                Divider()

                ScrollView {
                    Group {
                        switch coordinator.step {
                        case .settingUp: FirstRunSettingUpPage()
                        case .selectData: FirstRunSelectDataPage()
                        case .selectModels: FirstRunSelectModelsPage()
                        case .setupAgent: FirstRunSetupAgentPage()
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                footer
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        // A container, so the identifier names this group instead of replacing the
        // identifiers of every control inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRun.root")
    }

    // MARK: - Step rail

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Garage")
                        .font(.headline)
                    Text("Setup Assistant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)

            ForEach(FirstRunStep.allCases) { step in
                stepRow(step)
            }

            Spacer()

            Text("Garage keeps its index on this Mac and never sends it to the cloud. Assistants you connect receive only the excerpts their searches return, and may send those to their own cloud model.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
        }
    }

    private func stepRow(_ step: FirstRunStep) -> some View {
        let current = coordinator.step
        let isCurrent = step == current
        let isDone = step < current

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : (isDone ? Color.green : Color.primary.opacity(0.08)))
                    .frame(width: 24, height: 24)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isCurrent ? .white : .secondary)
                }
            }
            Text(step.title)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
        .accessibilityIdentifier("firstRun.step.\(step.rawValue)")
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: coordinator.step.symbol)
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.step.title)
                    .font(.system(size: 22, weight: .bold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var headerSubtitle: String {
        switch coordinator.step {
        case .settingUp:
            coordinator.isAfterDatabaseReset
                ? "The database was reset. Garage is creating a new, empty one and will register the sources in garage.json again."
                : "Garage is starting its private database and background services. This only takes a moment the first time."
        case .selectData:
            "Choose what Garage should index. You can add, remove or fine-tune sources any time from the Sources page."
        case .selectModels:
            "Optionally pick a distillation model that extracts facts from your documents, then the text embedding model that powers search."
        case .setupAgent:
            "Connect your AI assistants to Garage's MCP server so they can search your corpus."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // Available on every page, including while services are still
            // starting, so a hung startup never traps the user here.
            Button("Skip setup") {
                coordinator.skip()
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(coordinator.isWorking)
            .accessibilityIdentifier("firstRun.skipSetup")

            Spacer()

            if let progress = coordinator.progressMessage, coordinator.isWorking {
                ProgressView().controlSize(.small)
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            switch coordinator.step {
            case .settingUp:
                if coordinator.servicesFailed || coordinator.errorMessage != nil {
                    Button("Retry") {
                        coordinator.retryServices()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("firstRun.retry")
                }

            case .selectData:
                Button("I'll decide later") {
                    coordinator.selectedSourceIDs = []
                    Task { await coordinator.commitSources() }
                }
                .disabled(coordinator.isWorking)
                .accessibilityIdentifier("firstRun.decideLater")
                Button(nextTitleForData) {
                    Task { await coordinator.commitSources() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isWorking || coordinator.selectedSourceIDs.isEmpty)
                .accessibilityIdentifier("firstRun.next")

            case .selectModels:
                Button("Back") {
                    coordinator.goBack()
                }
                .disabled(coordinator.isWorking)
                Button("I'll decide later") {
                    coordinator.selectedEmbeddingSlugs = []
                    coordinator.selectedDistillationSlug = nil
                    Task { await coordinator.commitModels() }
                }
                .disabled(coordinator.isWorking)
                .accessibilityIdentifier("firstRun.decideLater")
                Button("Next") {
                    Task { await coordinator.commitModels() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isWorking || (coordinator.selectedEmbeddingSlugs.isEmpty && coordinator.selectedDistillationSlug == nil))
                .accessibilityIdentifier("firstRun.next")

            case .setupAgent:
                Button("Back") {
                    coordinator.goBack()
                }
                .disabled(coordinator.isWorking)
                Button("Finish") {
                    coordinator.finish()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isWorking)
                .accessibilityIdentifier("firstRun.finish")
            }
        }
    }

    private var nextTitleForData: String {
        let count = coordinator.selectedSourceIDs.count
        return count == 0 ? "Next" : "Add \(count) source\(count == 1 ? "" : "s") & Next"
    }
}

// MARK: - Shared pieces

enum FirstRunStyle {
    static let cardCorner: CGFloat = 10

    static func cardBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: cardCorner)
            .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: cardCorner)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
    }
}

private struct FirstRunBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // A badge is one token: never wrap it ("ADD ED") when its row runs short.
            .lineLimit(1)
    }
}

private struct FirstRunErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FirstRunSectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Page 1: Setting things up

@MainActor
struct FirstRunSettingUpPage: View {
    @EnvironmentObject var appState: AppState

    private var coordinator: FirstRunCoordinator { appState.firstRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                ForEach(coordinator.serviceChecks) { check in
                    checkRow(check)
                }
            }

            if let error = coordinator.errorMessage {
                FirstRunErrorBanner(message: error)
            } else if coordinator.servicesFailed {
                FirstRunErrorBanner(message: "A service failed to start. Retry, or skip setup and inspect the Logs page.")
            }

            Text("Garage keeps its database in ~/Library/Application Support/GarageApp. Nothing is indexed until you choose sources on the next page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkRow(_ check: FirstRunServiceCheck) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                switch check.state {
                case .pending:
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.secondary)
                case .inProgress:
                    ProgressView().controlSize(.small)
                case .ready:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.subheadline.weight(.semibold))
                Text(detailText(for: check))
                    .font(.caption)
                    .foregroundStyle(check.state.isFailed ? .red : .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(FirstRunStyle.cardBackground(selected: false))
        .accessibilityIdentifier("firstRun.check.\(check.id)")
    }

    private func detailText(for check: FirstRunServiceCheck) -> String {
        switch check.state {
        case .failed(let message): message
        case .ready where check.id == "postgres": "Running on port \(appState.postgres.port)"
        case .ready where check.id == "mcp": "Listening at \(appState.mcp.endpoint.absoluteString)"
        case .ready: "Ready"
        default: check.detail
        }
    }
}

// MARK: - Page 2: Select your data

@MainActor
struct FirstRunSelectDataPage: View {
    @EnvironmentObject var appState: AppState

    private var coordinator: FirstRunCoordinator { appState.firstRun }

    // Three columns at the assistant's width (MainWindowSizing.assistantSize), also when a mouse makes
    // the scroll bar take its ~15 pt: 920 less the sidebar and padding leaves about 620 pt.
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 320), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if coordinator.isSandboxed {
                if !appState.volumeAccess.status.isGranted || !coordinator.hasFullDiskAccess {
                    storeAccessCard
                }
            } else if !appState.volumeAccess.status.isGranted {
                diskAccessCard
            }

            if let error = coordinator.errorMessage {
                FirstRunErrorBanner(message: error)
            }

            FirstRunSectionTitle(
                title: "Common locations",
                subtitle: "Select one or more. Locations that don't exist on this Mac, or that need Full Disk Access, are greyed out."
            )

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(coordinator.sourceTemplates.filter { !$0.isCustom }) { template in
                    templateCard(template)
                }
            }

            FirstRunSectionTitle(
                title: "Custom folders",
                subtitle: "Add any other folder. Choosing it here also grants Garage permission to read it."
            )

            let custom = coordinator.sourceTemplates.filter(\.isCustom)
            if !custom.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(custom) { template in
                        templateCard(template)
                    }
                }
            }

            Button {
                chooseCustomFolder()
            } label: {
                Label("Add custom folder…", systemImage: "folder.badge.plus")
            }
            .disabled(coordinator.isWorking)
            .accessibilityIdentifier("firstRun.addCustomFolder")

            if !coordinator.isSandboxed, coordinator.sourceTemplates.contains(where: \.needsFullDiskAccess) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mail and Messages need Full Disk Access. Turn it on for Garage in System Settings → Privacy & Security, then quit and reopen Garage to pick them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Privacy Settings…") {
                            appState.openPrivacySettings(for: .fullDiskAccess)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("firstRun.fullDiskAccess")
                    }
                }
            }

            if coordinator.selectedSources.contains(where: \.isCommunication) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.blue)
                    Text("Messages and Mail are stored as communications: they never leave this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Full Disk Access is turned on in System Settings, and the folder grant in a panel, so check
        // both again every few seconds while this page shows.
        .task {
            while !Task.isCancelled {
                coordinator.refreshAccess()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The App Store build's access, in the order it works: the home folder first (the sandbox reads
    /// nothing outside its container without it), then Full Disk Access, which Mail and Messages
    /// also need. Full Disk Access can be skipped; the warning says what is lost.
    private var storeAccessCard: some View {
        let granted = appState.volumeAccess.status.isGranted
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : "folder.badge.person.crop")
                    .font(.title2)
                    .foregroundStyle(granted ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(granted ? "Folder access granted" : "1. Give Garage your home folder")
                        .font(.subheadline.weight(.semibold))
                    if !granted {
                        Text("Garage runs in the macOS sandbox. Select your home folder once and it can read Documents, Desktop, Downloads, iCloud Drive and the rest, without asking for each folder. Select your startup disk instead to index other disks too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Select Home Folder…") {
                                appState.promptAndSelectHomeFolder()
                                _ = appState.testVolumeAccess()
                                coordinator.refreshAccess()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("firstRun.selectHome")
                            Button("Select Startup Disk…") {
                                appState.promptAndSelectRootVolume()
                                _ = appState.testVolumeAccess()
                                coordinator.refreshAccess()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Spacer()
            }

            if !coordinator.hasFullDiskAccess {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("2. Turn on Full Disk Access, or Mail and Messages won't work")
                            .font(.subheadline.weight(.semibold))
                        Text("macOS keeps Mail, Messages and some other folders behind Full Disk Access. Without it Garage can't index them, even with your home folder granted, and their locations stay greyed out below. Turn on Garage in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Garage; setup picks up here. You can skip this and turn it on later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !granted {
                            Text("Garage can check Full Disk Access once your home folder is granted.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button("Open Privacy Settings…") {
                            appState.openPrivacySettings(for: .fullDiskAccess)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("firstRun.fullDiskAccess")
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRun.storeAccess")
    }

    private var diskAccessCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant disk access")
                    .font(.subheadline.weight(.semibold))
                Text("Garage runs in the macOS sandbox. Select your startup disk once so it can read the folders you choose below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Select Startup Disk…") {
                        appState.promptAndSelectRootVolume()
                        _ = appState.testVolumeAccess()
                    }
                    .controlSize(.small)
                    Button("Open Privacy Settings…") {
                        appState.openPrivacySettings(for: .fullDiskAccess)
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRun.diskAccess")
    }

    /// The selectable card, with a custom folder's remove control laid over it as a
    /// sibling rather than nested inside the selection button, so each is its own
    /// hit target and accessibility element.
    private func templateCard(_ template: FirstRunSourceTemplate) -> some View {
        ZStack(alignment: .topTrailing) {
            templateSelectionButton(template)

            if template.isCustom {
                Button {
                    coordinator.removeCustomFolder(template)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(10)
                .disabled(coordinator.isWorking)
                .help("Remove this folder from the list")
                .accessibilityLabel("Remove \(template.title)")
                .accessibilityIdentifier("firstRun.source.remove.\(template.id)")
            }
        }
    }

    private func templateSelectionButton(_ template: FirstRunSourceTemplate) -> some View {
        let selected = coordinator.selectedSourceIDs.contains(template.id)
        let alreadyRegistered = appState.registeredSources.contains { $0.slug == template.slug }

        return Button {
            coordinator.toggleSource(template)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: template.symbol)
                            .foregroundStyle(.secondary)
                        Text(template.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    // Badges get their own row: beside the title they squeezed it into
                    // hyphenating ("Mes-sages") at three columns.
                    let isCode = !template.isCommunication && template.corpusClass == "code"
                    if template.isCommunication || isCode || alreadyRegistered {
                        HStack(spacing: 4) {
                            if template.isCommunication {
                                FirstRunBadge(text: "PRIVATE", tint: .purple)
                            } else if isCode {
                                FirstRunBadge(text: "CODE", tint: .indigo)
                            }
                            if alreadyRegistered {
                                FirstRunBadge(text: "ADDED", tint: .green)
                            }
                        }
                        .fixedSize()
                    }
                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(template.root)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if template.needsFullDiskAccess {
                            FirstRunBadge(text: "NEEDS FULL DISK ACCESS", tint: .orange)
                        } else if !template.isAvailable {
                            FirstRunBadge(text: "NOT FOUND", tint: .secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .padding(.trailing, template.isCustom ? 20 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FirstRunStyle.cardBackground(selected: selected))
            .opacity(template.isAvailable ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: FirstRunStyle.cardCorner))
        }
        .buttonStyle(.plain)
        .disabled(!template.isAvailable || coordinator.isWorking)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("firstRun.source.\(template.id)")
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for Garage to index"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            coordinator.addCustomFolder(url)
        }
    }
}

// MARK: - Page 3: Select your models

@MainActor
struct FirstRunSelectModelsPage: View {
    @EnvironmentObject var appState: AppState

    private var coordinator: FirstRunCoordinator { appState.firstRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = coordinator.errorMessage {
                FirstRunErrorBanner(message: error)
            }

            FirstRunSectionTitle(
                title: "Distillation model",
                subtitle: "Optional. A small instruction-tuned model that gleans atomic facts from your documents and answers rag_ask over MCP. One model is active at a time (facts.model in garage.json)."
            )

            if coordinator.distillationPresets.isEmpty {
                Text("No distillation presets were found in models.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(coordinator.distillationPresets) { preset in
                        modelRow(
                            preset,
                            selected: coordinator.selectedDistillationSlug == preset.slug,
                            registered: false,
                            activeForFacts: appState.factsModel == preset.slug
                        ) {
                            coordinator.toggleDistillation(preset)
                        }
                    }
                }
            }

            FirstRunSectionTitle(
                title: "Text embedding models",
                subtitle: "Turn document chunks into vectors for semantic search. Pick at least one; the first becomes the default. Each model keeps its own vector table, so you can add more later and embed with them."
            )

            if coordinator.embeddingPresets.isEmpty {
                Text("No text embedding presets were found in models.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(coordinator.embeddingPresets) { preset in
                        modelRow(
                            preset,
                            selected: coordinator.selectedEmbeddingSlugs.contains(preset.slug),
                            registered: appState.registeredModels.contains { $0.slug == preset.slug }
                        ) {
                            coordinator.toggleEmbedding(preset)
                        }
                    }
                }
            }

            Toggle("Download model files now", isOn: Binding(
                get: { coordinator.downloadSelectedModels },
                set: { coordinator.downloadSelectedModels = $0 }
            ))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("firstRun.downloadModels")

            Text("Downloads run in the background through the model download service and are verified against their published SHA-256. Watch progress on the Models page. Garage embeds after each ingest; if a download finishes later, use Embed All on the Models page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelRow(_ preset: ModelPresetEntry, selected: Bool, registered: Bool, activeForFacts: Bool = false, toggle: @escaping () -> Void) -> some View {
        let downloaded = preset.effectiveFilename.map { appState.modelDownload.isModelDownloaded(filename: $0) } ?? false

        return Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(preset.name)
                            .font(.subheadline.weight(.semibold))
                        if preset.featured {
                            FirstRunBadge(text: "RECOMMENDED", tint: .green)
                        }
                        if preset.effectiveDims > 0 {
                            FirstRunBadge(text: "\(preset.effectiveDims) DIMS", tint: .blue)
                        }
                        if let ctx = preset.contextSize, ctx > 0 {
                            FirstRunBadge(text: "\(ctx) CTX", tint: .secondary)
                        }
                        if preset.toolCalling {
                            FirstRunBadge(text: "TOOLS", tint: .purple)
                                .help("Trained to call tools, so it can use Garage's MCP tools")
                        }
                        if let region = preset.originRegion {
                            FirstRunBadge(text: region, tint: .secondary)
                                .help("Made by \(preset.originSummary)")
                                .accessibilityLabel("Origin \(preset.originSummary)")
                        }
                        if registered {
                            FirstRunBadge(text: "REGISTERED", tint: .teal)
                        }
                        if activeForFacts {
                            FirstRunBadge(text: "ACTIVE FACTS MODEL", tint: .green)
                        }
                        if downloaded {
                            FirstRunBadge(text: "ON DISK", tint: .teal)
                        }
                    }

                    if let description = preset.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let useCases = preset.useCases, !useCases.isEmpty {
                        Text(useCases.joined(separator: " • "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FirstRunStyle.cardBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: FirstRunStyle.cardCorner))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isWorking)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("firstRun.model.\(preset.slug)")
    }
}

// MARK: - Page 4: Set up your agent

@MainActor
struct FirstRunSetupAgentPage: View {
    @EnvironmentObject var appState: AppState

    private var coordinator: FirstRunCoordinator { appState.firstRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = coordinator.errorMessage {
                FirstRunErrorBanner(message: error)
            }

            // With HTTP off (the default) there is no server to run: assistants start `garage-mcp`.
            if appState.mcp.httpEnabled {
                serverCard
            }

            FirstRunSectionTitle(
                title: "Installed assistants",
                subtitle: "Garage looked for the configuration files of common assistants. Select the ones to connect; each gets a \"garage-rag\" server entry pointing at the endpoint above."
            )

            VStack(spacing: 8) {
                ForEach(coordinator.detectedClients) { client in
                    clientRow(client)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await coordinator.registerSelectedClients() }
                } label: {
                    Label("Connect selected assistants", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isWorking || coordinator.selectedClientIDs.isEmpty)
                .accessibilityIdentifier("firstRun.registerClients")

                Button("Add custom config file…") {
                    chooseCustomConfigFile()
                }
                .disabled(coordinator.isWorking)

                Button("Rescan") {
                    appState.mcp.refreshDetectedClients()
                }
                .disabled(coordinator.isWorking)
            }

            if let summary = coordinator.registrationSummary {
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("A connected assistant receives the excerpts its searches return — only those, not your whole index — and may send them to its own cloud model, including excerpts from Messages and Mail if you index them. What happens to them then is up to that assistant's privacy terms, not Garage's.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("firstRun.agentPrivacy")

            Text("You can always revisit this from the MCP Server page, where you can also test tool calls against the running server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var serverCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("MCP server: \(statusTitle)")
                        .font(.subheadline.weight(.semibold))
                    if appState.mcp.status == .starting || appState.mcp.status == .stopping {
                        ProgressView().controlSize(.small)
                    }
                }

                Text(appState.mcp.endpoint.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Text("Port")
                        .font(.caption)
                    TextField(
                        "Port",
                        value: Binding(
                            get: { appState.mcp.port },
                            set: { newPort in
                                if (1...65535).contains(newPort) {
                                    appState.mcp.port = newPort
                                }
                            }
                        ),
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(appState.mcp.status == .running || appState.mcp.status == .starting || coordinator.isWorking)

                    if appState.mcp.status == .running {
                        Button("Restart") {
                            Task {
                                await appState.mcp.stop()
                                await coordinator.startMCPServer()
                            }
                        }
                        .controlSize(.small)
                        .disabled(coordinator.isWorking)
                    } else {
                        Button("Start server") {
                            Task { await coordinator.startMCPServer() }
                        }
                        .controlSize(.small)
                        .disabled(appState.mcp.status == .starting || coordinator.isWorking)
                        .accessibilityIdentifier("firstRun.startMCP")
                    }
                }

                if case .failed(let message) = appState.mcp.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(FirstRunStyle.cardBackground(selected: false))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRun.mcpServer")
    }

    private func clientRow(_ client: MCPClientConfig) -> some View {
        let selected = coordinator.selectedClientIDs.contains(client.id)
        let home = GarageAppGroup.realHomeDirectory

        return Button {
            coordinator.toggleClient(client)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(client.label)
                            .font(.subheadline.weight(.semibold))
                        if client.isRegistered {
                            FirstRunBadge(text: "CONNECTED", tint: .green)
                        } else if client.existsOnDisk {
                            FirstRunBadge(text: "INSTALLED", tint: .blue)
                        } else {
                            FirstRunBadge(text: "NOT FOUND", tint: .secondary)
                        }
                        if client.isProjectScoped {
                            FirstRunBadge(text: "PROJECT", tint: .orange)
                        }
                    }
                    Text(client.path.path.replacingOccurrences(of: home, with: "~"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !client.note.isEmpty {
                        Text(client.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FirstRunStyle.cardBackground(selected: selected))
            .opacity(client.existsOnDisk ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: FirstRunStyle.cardCorner))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isWorking)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("firstRun.client.\(client.id)")
    }

    private var statusTitle: String {
        switch appState.mcp.status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .failed: "Failed"
        }
    }

    private var statusColor: Color {
        switch appState.mcp.status {
        case .running: .green
        case .starting, .stopping: .blue
        case .stopped: .secondary
        case .failed: .red
        }
    }

    private func chooseCustomConfigFile() {
        let panel = NSOpenPanel()
        panel.title = "Select MCP Client Configuration File"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await coordinator.registerCustomConfigFile(url) }
    }
}
