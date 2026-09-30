import XCTest
import proto_garage_proto_swift
@testable import GarageApp

final class FactPromptConfigTests: XCTestCase {
    private let examples = #"[{"text": "Jane met Bob.", "extractions": [{"class": "person", "text": "Jane"}]}]"#

    private func entries(_ json: String) -> [[String: Any]] {
        FactPromptConfig.parse(json)
    }

    private func people(enabled: Bool = true) -> FactPromptItem {
        FactPromptItem(
            name: "people",
            description: "List every person named.",
            examplesJSON: examples,
            corpusClasses: ["document"],
            enabled: enabled
        )
    }

    func testSavingANewPromptAppendsItInFull() throws {
        let json = try FactPromptConfig.saving(
            people(),
            in: #"[{"name": "default", "enabled": false}]"#,
            existingNames: ["default"]
        )
        let saved = entries(json)
        XCTAssertEqual(saved.map { $0["name"] as? String }, ["default", "people"])
        XCTAssertEqual(saved[0]["enabled"] as? Bool, false)
        XCTAssertEqual(saved[1]["description"] as? String, "List every person named.")
        XCTAssertEqual(saved[1]["corpus_classes"] as? [String], ["document"])
        XCTAssertEqual(saved[1]["enabled"] as? Bool, true)
        let example = try XCTUnwrap((saved[1]["examples"] as? [[String: Any]])?.first)
        XCTAssertEqual(example["text"] as? String, "Jane met Bob.")
    }

    func testSavingARenameReplacesTheOldEntry() throws {
        let configured = try FactPromptConfig.saving(people(), in: "[]", existingNames: ["default"])
        var renamed = people()
        renamed.name = "names"
        let json = try FactPromptConfig.saving(
            renamed,
            replacing: "people",
            in: configured,
            existingNames: ["default"]
        )
        XCTAssertEqual(entries(json).map { $0["name"] as? String }, ["names"])
    }

    func testSavingKeepsTheGraphBlockTheEditorDoesNotShow() throws {
        let configured = #"[{"name": "people", "description": "Old.", "examples": [], "graph": {"vertices": [{"class": "person", "label": "Person"}]}}]"#
        let json = try FactPromptConfig.saving(people(), in: configured, existingNames: ["default"])
        let saved = try XCTUnwrap(entries(json).first)
        XCTAssertEqual(saved["description"] as? String, "List every person named.")
        let vertices = try XCTUnwrap((saved["graph"] as? [String: Any])?["vertices"] as? [[String: Any]])
        XCTAssertEqual(vertices.first?["label"] as? String, "Person")
    }

    func testSavingRefusesBadInput() {
        var badName = people()
        badName.name = "has space"
        XCTAssertThrowsError(try FactPromptConfig.saving(badName, in: "[]", existingNames: [])) { error in
            XCTAssertEqual(error as? FactPromptConfigError, .invalidName("has space"))
        }
        XCTAssertThrowsError(try FactPromptConfig.saving(people(), in: "[]", existingNames: ["people"])) { error in
            XCTAssertEqual(error as? FactPromptConfigError, .duplicateName("people"))
        }
        var noDescription = people()
        noDescription.description = "  \n"
        XCTAssertThrowsError(try FactPromptConfig.saving(noDescription, in: "[]", existingNames: [])) { error in
            XCTAssertEqual(error as? FactPromptConfigError, .emptyDescription)
        }
        for broken in ["not json", "[]", #"{"text": "x"}"#, #"[{"extractions": []}]"#, #"[{"text": "x", "extractions": 3}]"#] {
            var badExamples = people()
            badExamples.examplesJSON = broken
            XCTAssertThrowsError(try FactPromptConfig.saving(badExamples, in: "[]", existingNames: []), broken)
        }
    }

    func testTogglingABuiltInAddsAMinimalOverrideAndKeepsOtherKeys() {
        let disabled = FactPromptConfig.settingEnabled(false, for: "default", in: "[]")
        XCTAssertEqual(entries(disabled).count, 1)
        XCTAssertEqual(entries(disabled)[0]["name"] as? String, "default")
        XCTAssertEqual(entries(disabled)[0]["enabled"] as? Bool, false)

        let customized = #"[{"name": "default", "description": "Mine.", "enabled": false}]"#
        let enabled = entries(FactPromptConfig.settingEnabled(true, for: "default", in: customized))
        XCTAssertEqual(enabled[0]["description"] as? String, "Mine.")
        XCTAssertEqual(enabled[0]["enabled"] as? Bool, true)
    }

    func testRemovingDropsOnlyThatEntry() {
        let configured = #"[{"name": "default", "enabled": false}, {"name": "people", "description": "d"}]"#
        let remaining = entries(FactPromptConfig.removing("default", from: configured))
        XCTAssertEqual(remaining.map { $0["name"] as? String }, ["people"])
        XCTAssertEqual(FactPromptConfig.parse("garbage").count, 0)
    }

    func testItemFromProtoAndItsScope() {
        var proto = Garage_FactPrompt()
        proto.name = "default"
        proto.description_p = "Extract every standalone fact."
        proto.examplesJson = examples
        proto.enabled = true
        proto.builtin = true
        proto.sha256 = String(repeating: "a", count: 64)
        let item = FactPromptItem(proto)
        XCTAssertEqual(item.id, "default")
        XCTAssertTrue(item.builtin)
        XCTAssertFalse(item.customized)
        XCTAssertEqual(item.scopeSummary, "all documents")
        XCTAssertEqual(people().scopeSummary, "document")
    }

    func testBlankPromptPicksAFreeNameAndValidExamples() throws {
        let blank = FactPromptItem.blank(existingNames: ["prompt", "prompt-2"])
        XCTAssertEqual(blank.name, "prompt-3")
        XCTAssertNoThrow(try FactPromptConfig.parseExamples(blank.examplesJSON))
        XCTAssertTrue(FactPromptConfig.prettyExamples(examples).contains("\n"))
    }
}
