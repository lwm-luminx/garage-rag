import Foundation
import GarageAppExtensionKit

// The Access page's wording and decisions as plain values (docs/plans/access-policies.md), kept out
// of the view so they can be tested without a window.

enum AccessPresentation {
    /// What the page says above the editor.
    static let explanation = "Every read asks a Rego policy which documents its caller may see: the app, garage on a terminal, and each connected assistant by its registration. The built-in policy applies your rules and defaults; a policy of your own can build on it or replace it. A change applies to the next read."

    /// What the list says with nothing stored.
    static let nothingStored = "No policies of your own. The built-in policy decides from the rules and defaults; with none of those, every caller sees every document."

    /// What a new policy starts as: the built-in decision, plus one boundary, so it compiles and shows the shape.
    static let template = """
    package garage.access

    # Every read asks for data.garage.access.decision: a list of boundaries a document must pass.
    # This keeps the built-in decision (your rules and defaults) and adds one boundary:
    # assistants over MCP never see communications.
    decision := {"boundaries": array.concat(data.garage.access.rules.decision.boundaries, extra)}

    extra := [{"default": "allow", "deny": [{"corpus_class": "communication"}]}] if {
    \tinput.caller.kind == "mcp"
    } else := []

    """

    /// A name not yet taken: `policy`, `policy-2`, ...
    static func newName(existing: Set<String>) -> String {
        if !existing.contains("policy") { return "policy" }
        var n = 2
        while existing.contains("policy-\(n)") { n += 1 }
        return "policy-\(n)"
    }

    /// Why `name` cannot be saved, or nil. `original` is the name the policy was opened under.
    static func nameProblem(_ name: String, existing: Set<String>, original: String?) -> String? {
        if name.isEmpty { return "Give the policy a name." }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) { return "A name has no leading or trailing spaces." }
        if name.contains("/") || name.contains("\\") { return "A name has no slash." }
        if name != original && existing.contains(name) { return "There is already a policy named \(name)." }
        return nil
    }

    /// The one-line verdict of a test.
    static func verdict(_ result: GarageAccessTestResult) -> String {
        if result.seesEverything { return "Sees every document" }
        let pending = result.contentRules.reduce(Int64(0)) { $0 + $1.pending }
        let boundaries = "Held to the filter below"
        return pending > 0 ? "\(boundaries); \(pending) documents not yet checked by content rules stay hidden" : boundaries
    }

    /// Who decided, for the test's result.
    static func decidedBy(_ result: GarageAccessTestResult) -> String {
        result.policies.isEmpty ? "The built-in policy (your rules and defaults)" : result.policies.joined(separator: ", ")
    }

    /// The caller line: `mcp over stdio (Claude)`.
    static func callerLine(_ result: GarageAccessTestResult) -> String {
        let registration = result.registrationName.isEmpty ? "" : " (\(result.registrationName))"
        return "\(result.callerKind) over \(result.transport)\(registration)"
    }

    /// The filter with its parameters, as the read would bind them.
    static func filterText(_ result: GarageAccessTestResult) -> String {
        guard !result.seesEverything else { return "none" }
        let params = result.filterParams.enumerated().map { "$\($0.offset + 1) = \($0.element)" }
        return ([result.filterSQL] + params).joined(separator: "\n")
    }
}

/// The text editor's state: the policy as opened, and as edited.
struct AccessPolicyDraft: Equatable {
    /// nil: a new policy, not yet saved.
    var original: GarageAccessPolicy?
    var name: String
    var rego: String
    var enabled: Bool

    init(editing policy: GarageAccessPolicy) {
        original = policy
        name = policy.name
        rego = policy.rego
        enabled = policy.enabled
    }

    init(newNamed name: String) {
        original = nil
        self.name = name
        rego = AccessPresentation.template
        enabled = true
    }

    var isNew: Bool { original == nil }

    var isDirty: Bool {
        guard let original else { return true }
        return original.name != name || original.rego != rego || original.enabled != enabled
    }

    /// What Save and Check send, and Test decides with.
    var policy: GarageAccessPolicy {
        GarageAccessPolicy(name: name, rego: rego, enabled: enabled)
    }

    /// A rename saves the new name, then removes the old one.
    var renamedFrom: String? {
        guard let original, original.name != name else { return nil }
        return original.name
    }
}
