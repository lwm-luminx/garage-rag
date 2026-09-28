import XCTest
@testable import GarageApp

final class LlamaDiagnosticTests: XCTestCase {
    /// The Built-in Engine row tokenizes only when the engine's health says a model is loaded, and
    /// skips the tokenizer when it says none is.
    func testHealthReportsLoadedModelFromKnownStatuses() throws {
        XCTAssertTrue(try XPCServiceManager.llamaHealthReportsLoadedModel(#"{"status": "ok"}"#))
        XCTAssertFalse(try XPCServiceManager.llamaHealthReportsLoadedModel(#"{"status": "no_model_loaded"}"#))
        XCTAssertFalse(try XPCServiceManager.llamaHealthReportsLoadedModel(#"{"status": "loading model"}"#))
    }

    /// A broken health route fails the test instead of reading as an engine with no model.
    func testMalformedHealthThrows() {
        XCTAssertThrowsError(try XPCServiceManager.llamaHealthReportsLoadedModel(nil))
        XCTAssertThrowsError(try XPCServiceManager.llamaHealthReportsLoadedModel("not json"))
        XCTAssertThrowsError(try XPCServiceManager.llamaHealthReportsLoadedModel("{}"))
        XCTAssertThrowsError(try XPCServiceManager.llamaHealthReportsLoadedModel(#"{"status": "error"}"#))
    }
}
