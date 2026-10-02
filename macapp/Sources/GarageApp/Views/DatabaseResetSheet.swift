import SwiftUI

/// Confirms "Reset Database". It spells out that everything Garage built from the user's files goes
/// (the index, facts, conversation memory) and that the files themselves stay, then hands off to
/// `AppState.resetDatabaseAndRelaunch(keepingSettings:)`, which stops the services, deletes the
/// cluster and relaunches the app to create a new one. Keep Settings (the default) fills it from
/// garage.json with no setup assistant; Start Over sets garage.json aside and runs the assistant.
/// Back Up First… writes the same
/// dump as the Database page's Back Up… without leaving the sheet, so the old database can be
/// restored after the reset.
@MainActor
struct DatabaseResetSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var backup: BackupState = .none
    @State private var keepSettings = true

    private enum BackupState: Equatable {
        case none
        case running
        case saved(URL)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Reset the Garage database?")
                    .font(.title2.bold())
            }
            Text("Garage deletes its database and starts over with an empty one. Your original files are not touched.")
                .fixedSize(horizontal: false, vertical: true)

            Picker("Settings", selection: $keepSettings) {
                Text("Keep settings").tag(true)
                Text("Start over").tag(false)
            }
            .pickerStyle(.segmented)
            .help("Keep settings fills the new database from garage.json. Start over sets garage.json aside and runs the setup assistant.")
            .accessibilityIdentifier("reset.keepSettings")

            ResetSection(title: "Deleted", systemImage: "trash", tint: .red, items: deletedItems)
            ResetSection(title: "Kept", systemImage: "checkmark.circle", tint: .green, items: keptItems)

            Text(DatabaseResetPresentation.explanation(
                keepingSettings: keepSettings, pgData: Paths.displayPath(of: Paths.pgDataDir)))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            HStack {
                Button("Back Up First…", systemImage: "externaldrive") { backUp() }
                    .disabled(appState.postgres.status != .running || backup == .running)
                    .help("Save a dump of the database. Restore… on the Database page brings it back after the reset.")
                    .accessibilityIdentifier("reset.backup")
                backupStatus
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("reset.cancel")
                Button("Reset and Relaunch", role: .destructive) {
                    dismiss()
                    let keepingSettings = keepSettings
                    Task { await appState.resetDatabaseAndRelaunch(keepingSettings: keepingSettings) }
                }
                // A plain destructive button renders gray on macOS; prominent + tint makes it red.
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(backup == .running)
                .accessibilityIdentifier("reset.confirm")
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled(backup == .running)
    }

    @ViewBuilder
    private var backupStatus: some View {
        switch backup {
        case .none:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .saved(let url):
            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
        case .failed(let message):
            Label("Backup failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .help(message)
        }
    }

    private func backUp() {
        guard let destination = DatabaseBackupPanel.chooseDestination() else { return }
        backup = .running
        Task {
            do {
                try await appState.postgres.backupDatabase(to: destination)
                DatabaseBackupRecord.record(destination)
                backup = .saved(destination)
            } catch {
                backup = .failed(error.localizedDescription)
            }
        }
    }

    private var deletedItems: [ResetItem] {
        let stats = appState.corpusStats
        let indexDetail = stats.documentsCount > 0
            ? "\(stats.documentsCount) indexed documents, their \(stats.totalChunks) chunks, and their embeddings under every model."
            : "Every indexed document, its chunks, and their embeddings under every model."
        var items = [
            ResetItem(title: "The search index", detail: indexDetail),
            ResetItem(title: "Facts", detail: "Every fact distilled from your documents."),
            ResetItem(
                title: "Conversation memory",
                detail: "The copies of message and mail threads Garage imported. The originals in Messages and Mail stay."
            ),
            ResetItem(
                title: "Registrations and history",
                detail: "Registered sources and text embedding models, authorship, and ingest history."
            ),
        ]
        if !keepSettings {
            items.append(ResetItem(
                title: "Settings",
                detail: "garage.json is renamed to garage.json.before-reset-<date> beside it, not deleted, so you can bring it back."
            ))
        }
        return items
    }

    private var keptItems: [ResetItem] {
        [
            ResetItem(
                title: "Your original files",
                detail: "Nothing in your sources' folders, repositories, mail or message archives is moved or deleted."
            ),
            keepSettings
                ? ResetItem(
                    title: "Models, logs and settings",
                    detail: "Downloaded model files, logs, and garage.json. Its sources and default embedding model are "
                        + "registered in the new database; nothing is written back to the file."
                )
                : ResetItem(title: "Models and logs", detail: "Downloaded model files and logs."),
            ResetItem(title: "The database password", detail: "It stays in your Keychain; the new database uses it."),
        ]
    }
}

/// The reset sheet's wording for each choice, kept apart for the unit tests.
enum DatabaseResetPresentation {
    static func explanation(keepingSettings: Bool, pgData: String) -> String {
        if keepingSettings {
            return "Garage stops its services, deletes \(pgData), and relaunches. It creates a new database and "
                + "registers the sources and default embedding model garage.json names, with no setup assistant. "
                + "Run ingest to rebuild the index, or bring a backup back with Restore… on the Database page."
        }
        return "Garage stops its services, deletes \(pgData), sets garage.json aside and relaunches into the setup "
            + "assistant, which creates a new database and walks you through choosing sources and models. "
            + "Or bring a backup back with Restore… on the Database page."
    }
}

private struct ResetItem: Identifiable {
    let title: String
    let detail: String
    var id: String { title }
}

private struct ResetSection: View {
    let title: String
    let systemImage: String
    let tint: Color
    let items: [ResetItem]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}
