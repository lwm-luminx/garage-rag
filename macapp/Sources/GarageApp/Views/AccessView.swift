import SwiftUI
import GarageAppExtensionKit
import GarageAppExtensions

/// The Access page (docs/plans/access-policies.md): the Rego policies every read is held to, edited as
/// text, with the built-in one beside them read-only, and a test of what any caller would see with the
/// text as it stands, saved or not. An editor a build's extension adds (`GarageAccessEditor`) gets a tab
/// of its own over the same calls.
struct AccessView: View {
    @EnvironmentObject private var appState: AppState

    /// Which tab: the Rego text editor (nil) or an extension's editor, by id.
    @State private var tab: String?
    @State private var loaded = GarageAccessPolicies()
    @State private var loadError: String?
    @State private var selection: Selection = .builtin
    @State private var draft: AccessPolicyDraft?
    /// The last Check or Save: what the server said, and whether it was a refusal.
    @State private var outcome: (message: String, isError: Bool)?
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var testCaller = "mcp:unregistered"
    @State private var testResult: GarageAccessTestResult?
    @State private var testError: String?
    @State private var showDecision = false

    enum Selection: Hashable {
        case builtin
        case policy(String)
        case new
    }

    private var editors: [any GarageAccessEditor] { GarageAppExtensions.installed.accessEditors }
    private var backend: any GarageAccessBackend { appState.grpc }
    private var notReady: Bool { appState.postgres.status != .running }
    private var names: Set<String> { Set(loaded.policies.map(\.name)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AccessPresentation.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !editors.isEmpty {
                Picker("Editor", selection: $tab) {
                    Text("Rego").tag(String?.none)
                    ForEach(editors.indices, id: \.self) { index in
                        Text(editors[index].title).tag(Optional(editors[index].id))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let id = tab, let editor = editors.first(where: { $0.id == id }) {
                editor.makeView(backend: backend)
            } else {
                regoEditor
            }
        }
        .padding(20)
        .navigationTitle("Access")
        .task { await reload() }
        .onChange(of: appState.postgres.status) { _, status in
            if status == .running { Task { await reload() } }
        }
    }

    // MARK: - The Rego editor

    private var regoEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            } else if !loaded.editable && !loaded.engine.isEmpty {
                Text("This build's access policy (\(loaded.engine)) is not edited here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                policyList
                    .frame(width: 210)
                editorPane
            }
            testPane
        }
    }

    private var policyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: Binding<Selection?>(get: { selection }, set: { open($0 ?? .builtin) })) {
                Section("Built-in") {
                    Label("rules", systemImage: "lock.doc")
                        .tag(Selection.builtin)
                        .accessibilityIdentifier("access.policy.builtin")
                }
                Section("Your Policies") {
                    if loaded.policies.isEmpty && draft?.isNew != true {
                        Text(AccessPresentation.nothingStored)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(loaded.policies) { policy in
                        HStack {
                            Text(policy.name).font(.callout.monospaced())
                            Spacer()
                            if !policy.enabled { StatusBadge("OFF", tint: .secondary) }
                        }
                        .tag(Selection.policy(policy.name))
                    }
                    if draft?.isNew == true {
                        Text(draft?.name ?? "").font(.callout.monospaced()).italic()
                            .tag(Selection.new)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 260)

            Button {
                let name = AccessPresentation.newName(existing: names)
                draft = AccessPolicyDraft(newNamed: name)
                selection = .new
                outcome = nil
            } label: {
                Label("New Policy", systemImage: "plus")
            }
            .disabled(notReady || !loaded.editable)
            .accessibilityIdentifier("access.newPolicy")
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if selection == .builtin || draft == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Built-in Policy")
                    .font(.headline)
                Text("package garage.access.rules: your rules and defaults as Rego. Read-only; a policy of your own can use its decision as data.garage.access.rules.decision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(loaded.builtinRego.isEmpty ? (notReady ? "Start the database to see the policies." : "Loading…") : loaded.builtinRego)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 260)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        } else if let binding = Binding($draft) {
            draftEditor(binding)
        }
    }

    private func draftEditor(_ draft: Binding<AccessPolicyDraft>) -> some View {
        let problem = AccessPresentation.nameProblem(draft.wrappedValue.name, existing: names, original: draft.wrappedValue.original?.name)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Name", text: draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("access.policy.name")
                Toggle("Enabled", isOn: draft.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                if let updated = draft.wrappedValue.original?.updatedAt, !updated.isEmpty {
                    Text("Saved \(updated)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            TextEditor(text: draft.rego)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityIdentifier("access.policy.rego")
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            if let outcome {
                Text(outcome.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(outcome.isError ? .red : .green)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Check") { Task { await check() } }
                    .disabled(busy || notReady || problem != nil)
                    .help("Compile with the other enabled policies; nothing is saved")
                Button("Save") { Task { await save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(busy || notReady || problem != nil || !draft.wrappedValue.isDirty)
                    .accessibilityIdentifier("access.policy.save")
                Button("Revert") { open(selection) }
                    .disabled(busy || draft.wrappedValue.isNew || !draft.wrappedValue.isDirty)
                Spacer()
                Button(draft.wrappedValue.isNew ? "Discard" : "Delete", role: .destructive) {
                    if draft.wrappedValue.isNew { open(.builtin) } else { confirmDelete = true }
                }
                .disabled(busy || notReady)
            }
        }
        .confirmationDialog(
            "Delete the policy \(draft.wrappedValue.original?.name ?? "")?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next read is decided without it.")
        }
    }

    // MARK: - Test

    private var testPane: some View {
        GroupBox("Test") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Caller", selection: $testCaller) {
                        ForEach(callers) { caller in
                            Text(caller.label).tag(caller.caller)
                        }
                    }
                    .frame(maxWidth: 360)
                    Button(draft?.isDirty == true ? "Test with This Text" : "Test") { Task { await runTest() } }
                        .disabled(busy || notReady || !loaded.editable)
                        .help("What this caller's reads would be held to, with the editor's text as it stands. Nothing is saved or read.")
                    Spacer()
                }
                if let testError {
                    Text(testError).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                } else if let result = testResult {
                    testResultView(result)
                } else {
                    Text("Pick a caller to see the targets it goes by, the policy's decision and the filter its reads would carry.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var callers: [GarageAccessCaller] {
        loaded.callers.isEmpty ? [GarageAccessCaller(caller: "mcp:unregistered", label: "An MCP client with no registration")] : loaded.callers
    }

    private func testResultView(_ result: GarageAccessTestResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(AccessPresentation.verdict(result), systemImage: result.seesEverything ? "eye" : "line.3.horizontal.decrease.circle")
                .font(.callout.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Caller").foregroundStyle(.secondary)
                    Text(AccessPresentation.callerLine(result)).font(.caption.monospaced())
                }
                GridRow {
                    Text("Targets").foregroundStyle(.secondary)
                    Text(result.targets.joined(separator: ", ")).font(.caption.monospaced())
                }
                GridRow {
                    Text("Decided by").foregroundStyle(.secondary)
                    Text(AccessPresentation.decidedBy(result)).font(.caption)
                }
                GridRow(alignment: .top) {
                    Text("Filter").foregroundStyle(.secondary)
                    Text(AccessPresentation.filterText(result)).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .font(.caption)
            DisclosureGroup("Decision", isExpanded: $showDecision) {
                Text(result.decisionJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    // MARK: - Actions

    private func open(_ target: Selection) {
        outcome = nil
        switch target {
        case .builtin:
            draft = nil
        case .policy(let name):
            guard let policy = loaded.policies.first(where: { $0.name == name }) else { return }
            draft = AccessPolicyDraft(editing: policy)
        case .new:
            if draft?.isNew != true { return }
        }
        selection = target
    }

    private func reload() async {
        guard !notReady else { return }
        do {
            loaded = try await backend.listPolicies()
            loadError = nil
            if !callers.contains(where: { $0.caller == testCaller }), let first = callers.first {
                testCaller = first.caller
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func check() async {
        guard let draft else { return }
        busy = true
        defer { busy = false }
        do {
            outcome = (try await backend.putPolicy(draft.policy, checkOnly: true), false)
        } catch {
            outcome = (error.localizedDescription, true)
        }
    }

    private func save() async {
        guard let current = draft else { return }
        busy = true
        defer { busy = false }
        do {
            let message = try await backend.putPolicy(current.policy, checkOnly: false)
            if let old = current.renamedFrom {
                _ = try await backend.removePolicy(named: old)
            }
            await reload()
            open(.policy(current.name))
            outcome = (message, false)
        } catch {
            outcome = (error.localizedDescription, true)
        }
    }

    private func delete() async {
        guard let name = draft?.original?.name else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await backend.removePolicy(named: name)
            await reload()
            open(.builtin)
        } catch {
            outcome = (error.localizedDescription, true)
        }
    }

    private func runTest() async {
        busy = true
        defer { busy = false }
        do {
            let unsaved = draft.flatMap { $0.isDirty && $0.enabled ? $0.policy : nil }
            testResult = try await backend.test(caller: testCaller, draft: unsaved)
            testError = nil
        } catch {
            testResult = nil
            testError = error.localizedDescription
        }
    }
}
