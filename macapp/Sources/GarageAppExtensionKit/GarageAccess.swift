import Foundation
import SwiftUI

// The Access page's contract (docs/plans/access-policies.md): the calls an editor makes and what they
// return, as plain values, so an editor an extension adds (a build's visual rule editor) works through
// the same GarageService calls as the page's own Rego text editor, and needs nothing of the app.

/// A stored Rego module.
public struct GarageAccessPolicy: Sendable, Equatable, Identifiable {
    public var name: String
    public var rego: String
    public var enabled: Bool
    /// RFC 3339; empty for one not yet saved.
    public var updatedAt: String

    public var id: String { name }

    public init(name: String, rego: String, enabled: Bool = true, updatedAt: String = "") {
        self.name = name
        self.rego = rego
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

/// A caller `test` can be asked about: `caller` is what it takes (`app`, `mcp:<registration id>`, ...).
public struct GarageAccessCaller: Sendable, Equatable, Identifiable, Hashable {
    public var caller: String
    public var label: String

    public var id: String { caller }

    public init(caller: String, label: String) {
        self.caller = caller
        self.label = label
    }
}

/// The policies as they stand, the built-in module, and who can be tested.
public struct GarageAccessPolicies: Sendable, Equatable {
    public var policies: [GarageAccessPolicy]
    /// The built-in module (package garage.access.rules), read-only.
    public var builtinRego: String
    /// The build's access policy, and whether these calls edit it.
    public var engine: String
    public var editable: Bool
    public var callers: [GarageAccessCaller]

    public init(
        policies: [GarageAccessPolicy] = [],
        builtinRego: String = "",
        engine: String = "",
        editable: Bool = false,
        callers: [GarageAccessCaller] = []
    ) {
        self.policies = policies
        self.builtinRego = builtinRego
        self.engine = engine
        self.editable = editable
        self.callers = callers
    }
}

/// A stored rule: `{name, effect, targets, match, enabled}` as JSON.
public struct GarageAccessRule: Sendable, Equatable, Identifiable {
    public var name: String
    public var ruleJSON: String
    public var enabled: Bool
    /// Content rules: documents not yet evaluated against this version of the rule.
    public var pending: Int64

    public var id: String { name }

    public init(name: String, ruleJSON: String, enabled: Bool, pending: Int64 = 0) {
        self.name = name
        self.ruleJSON = ruleJSON
        self.enabled = enabled
        self.pending = pending
    }
}

/// A target's default: `allow` or `deny`.
public struct GarageAccessDefault: Sendable, Equatable, Identifiable {
    public var target: String
    public var effect: String

    public var id: String { target }

    public init(target: String, effect: String) {
        self.target = target
        self.effect = effect
    }
}

/// What a caller's reads would be held to.
public struct GarageAccessTestResult: Sendable, Equatable {
    public var callerKind: String
    public var transport: String
    public var registrationName: String
    /// The target names the caller goes by, outermost first.
    public var targets: [String]
    /// The stored modules that decided; empty: the built-in one alone.
    public var policies: [String]
    /// `data.garage.access.decision`, as pretty JSON.
    public var decisionJSON: String
    /// Content rules the decision depends on, with how many documents each has yet to look at.
    public var contentRules: [(name: String, pending: Int64)]
    public var seesEverything: Bool
    public var filterSQL: String
    /// Each bind parameter of `filterSQL`, `$1` first, as JSON.
    public var filterParams: [String]
    /// The MCP tools an assistant may list and call (`data.garage.tools.decision`), and the ones the
    /// policy withholds; both empty for the app and `garage`.
    public var tools: [String]
    public var withheldTools: [String]

    public init(
        callerKind: String = "",
        transport: String = "",
        registrationName: String = "",
        targets: [String] = [],
        policies: [String] = [],
        decisionJSON: String = "",
        contentRules: [(name: String, pending: Int64)] = [],
        seesEverything: Bool = true,
        filterSQL: String = "",
        filterParams: [String] = [],
        tools: [String] = [],
        withheldTools: [String] = []
    ) {
        self.callerKind = callerKind
        self.transport = transport
        self.registrationName = registrationName
        self.targets = targets
        self.policies = policies
        self.decisionJSON = decisionJSON
        self.contentRules = contentRules
        self.seesEverything = seesEverything
        self.filterSQL = filterSQL
        self.filterParams = filterParams
        self.tools = tools
        self.withheldTools = withheldTools
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.callerKind == rhs.callerKind && lhs.transport == rhs.transport
            && lhs.registrationName == rhs.registrationName && lhs.targets == rhs.targets
            && lhs.policies == rhs.policies && lhs.decisionJSON == rhs.decisionJSON
            && lhs.contentRules.map(\.name) == rhs.contentRules.map(\.name)
            && lhs.contentRules.map(\.pending) == rhs.contentRules.map(\.pending)
            && lhs.seesEverything == rhs.seesEverything && lhs.filterSQL == rhs.filterSQL
            && lhs.filterParams == rhs.filterParams && lhs.tools == rhs.tools
            && lhs.withheldTools == rhs.withheldTools
    }
}

/// GarageService's access calls. Each throws with the server's message (a policy that does not
/// compile, a rule that is not one); each change applies to the next read.
@MainActor
public protocol GarageAccessBackend: AnyObject {
    func listPolicies() async throws -> GarageAccessPolicies
    /// Saves `policy` once it compiles with the other enabled ones; `checkOnly` compiles and saves nothing.
    func putPolicy(_ policy: GarageAccessPolicy, checkOnly: Bool) async throws -> String
    func removePolicy(named name: String) async throws -> String
    func listRules() async throws -> [GarageAccessRule]
    func putRule(json: String) async throws -> String
    func removeRule(named name: String) async throws -> String
    func listDefaults() async throws -> [GarageAccessDefault]
    /// `effect` `allow` or `deny`; empty clears the target's default.
    func setDefault(target: String, effect: String) async throws -> String
    /// What `caller`'s reads would be held to, with `draft` in place of the stored module of its name.
    func test(caller: String, draft: GarageAccessPolicy?) async throws -> GarageAccessTestResult
}

/// An editor an extension adds to the Access page, as a tab beside the Rego text editor.
@MainActor
public protocol GarageAccessEditor {
    /// Stable and unique among the editors a build links in.
    var id: String { get }
    /// The tab's title ("Rules").
    var title: String { get }

    func makeView(backend: any GarageAccessBackend) -> AnyView
}
