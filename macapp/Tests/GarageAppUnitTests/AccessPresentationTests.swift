import XCTest
import GarageAppExtensionKit
@testable import GarageApp

final class AccessPresentationTests: XCTestCase {

    func testANewPolicyTakesTheFirstFreeName() {
        XCTAssertEqual(AccessPresentation.newName(existing: []), "policy")
        XCTAssertEqual(AccessPresentation.newName(existing: ["policy"]), "policy-2")
        XCTAssertEqual(AccessPresentation.newName(existing: ["policy", "policy-2"]), "policy-3")
    }

    func testTheTemplateBuildsOnTheBuiltInDecision() {
        XCTAssertTrue(AccessPresentation.template.hasPrefix("package garage.access\n"))
        XCTAssertTrue(AccessPresentation.template.contains("data.garage.access.rules.decision.boundaries"))
    }

    func testNamesAreWordsWithNoSlashAndNotTaken() {
        XCTAssertNil(AccessPresentation.nameProblem("no-mail", existing: [], original: nil))
        XCTAssertNotNil(AccessPresentation.nameProblem("", existing: [], original: nil))
        XCTAssertNotNil(AccessPresentation.nameProblem(" padded", existing: [], original: nil))
        XCTAssertNotNil(AccessPresentation.nameProblem("a/b", existing: [], original: nil))
        XCTAssertNotNil(AccessPresentation.nameProblem("taken", existing: ["taken"], original: nil))
        // Its own name is not taken by itself.
        XCTAssertNil(AccessPresentation.nameProblem("taken", existing: ["taken"], original: "taken"))
    }

    func testADraftKnowsWhenItChangedAndWhatItWasCalled() {
        let stored = GarageAccessPolicy(name: "no-mail", rego: "package x\n", enabled: true, updatedAt: "2026-11-24T18:00:00Z")
        var draft = AccessPolicyDraft(editing: stored)
        XCTAssertFalse(draft.isNew)
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.renamedFrom)
        draft.rego += "y := 1\n"
        XCTAssertTrue(draft.isDirty)
        draft.name = "no-mail-2"
        XCTAssertEqual(draft.renamedFrom, "no-mail")
        XCTAssertEqual(draft.policy, GarageAccessPolicy(name: "no-mail-2", rego: "package x\ny := 1\n", enabled: true))

        let fresh = AccessPolicyDraft(newNamed: "policy")
        XCTAssertTrue(fresh.isNew)
        XCTAssertTrue(fresh.isDirty)
        XCTAssertEqual(fresh.rego, AccessPresentation.template)
    }

    func testATestResultReadsAsAVerdictAndAFilter() {
        let open = GarageAccessTestResult(callerKind: "app", transport: "grpc", targets: ["app"], seesEverything: true)
        XCTAssertEqual(AccessPresentation.verdict(open), "Sees every document")
        XCTAssertEqual(AccessPresentation.filterText(open), "none")
        XCTAssertEqual(AccessPresentation.decidedBy(open), "The built-in policy (your rules and defaults)")
        XCTAssertEqual(AccessPresentation.callerLine(open), "app over grpc")

        let held = GarageAccessTestResult(
            callerKind: "mcp",
            transport: "stdio",
            registrationName: "Claude",
            targets: ["mcp:r1"],
            policies: ["no-mail"],
            contentRules: [(name: "keys", pending: 3)],
            seesEverything: false,
            filterSQL: "NOT (d.corpus_class::text = ANY($1::text[]))",
            filterParams: [#"["communication"]"#]
        )
        XCTAssertEqual(AccessPresentation.callerLine(held), "mcp over stdio (Claude)")
        XCTAssertEqual(AccessPresentation.decidedBy(held), "no-mail")
        XCTAssertTrue(AccessPresentation.verdict(held).contains("3 documents not yet checked"))
        XCTAssertEqual(
            AccessPresentation.filterText(held),
            "NOT (d.corpus_class::text = ANY($1::text[]))\n$1 = [\"communication\"]"
        )
    }
}
