import XCTest
import GarageXPCKit

/// `GarageXPCServiceBase` without Python, as ModelDownloadXPCService runs it.
final class GarageXPCServiceBaseTests: XCTestCase {
    private final class PlainService: GarageXPCServiceBase {
        override func additionalSelfTests() -> [GarageXPCSelfTest] {
            [
                GarageXPCSelfTest(name: "Plain", description: "Needs nothing.", requiresPython: false) { "ok" },
                GarageXPCSelfTest(name: "Needs Python", description: "Asks for an interpreter.") { "unreachable" },
            ]
        }
    }

    func testAServiceWithoutPythonReportsItAsNotUsed() {
        let service = PlainService(serviceName: "PlainService")
        XCTAssertTrue(service.isRuntimeReady)
        XCTAssertEqual(service.statusReport().python.state, "notUsed")
        XCTAssertNil(service.statusReport().python.error)
    }

    func testATestThatNeedsPythonFailsInAServiceWithoutIt() {
        let service = PlainService(serviceName: "PlainService")
        let results = service.performSelfTests()
        XCTAssertEqual(results.map(\.name), ["Logging", "Plain", "Needs Python"])
        XCTAssertEqual(results[1].status, .passed)
        XCTAssertEqual(results[2].status, .failed)
        XCTAssertEqual(results[2].summary, "This service embeds no Python runtime")
    }

    func testPingCarriesNoPythonDetail() {
        let service = PlainService(serviceName: "PlainService")
        let replied = expectation(description: "ping")
        service.ping { reply in
            XCTAssertEqual(reply, "pong from PlainService [bootstrapping]")
            replied.fulfill()
        }
        wait(for: [replied], timeout: 5)
    }
}
