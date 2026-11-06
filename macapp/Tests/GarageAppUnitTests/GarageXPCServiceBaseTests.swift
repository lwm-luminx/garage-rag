import XCTest
import GarageXPCKit

/// `GarageXPCServiceBase` as every helper runs it: no runtime to start, the suite is the logging
/// test plus the service's own.
final class GarageXPCServiceBaseTests: XCTestCase {
    private final class PlainService: GarageXPCServiceBase {
        override func additionalSelfTests() -> [GarageXPCSelfTest] {
            [
                GarageXPCSelfTest(name: "Plain", description: "Needs nothing.") { "ok" },
                GarageXPCSelfTest(name: "Failing", description: "Throws.") { throw GarageXPCSelfTestFailure("broken") },
            ]
        }
    }

    func testTheSuiteIsTheLoggingTestPlusTheServicesOwn() {
        let service = PlainService(serviceName: "PlainService")
        let results = service.performSelfTests()
        XCTAssertEqual(results.map(\.name), ["Logging", "Plain", "Failing"])
        XCTAssertEqual(results[1].status, .passed)
        XCTAssertEqual(results[2].status, .failed)
        XCTAssertEqual(results[2].summary, "broken")
        XCTAssertEqual(service.lifecycle, .degraded, "a failed self test degrades the service")
    }

    func testPingCarriesTheLifecycle() {
        let service = PlainService(serviceName: "PlainService")
        let replied = expectation(description: "ping")
        service.ping { reply in
            XCTAssertEqual(reply, "pong from PlainService [bootstrapping]")
            replied.fulfill()
        }
        wait(for: [replied], timeout: 5)
    }
}
