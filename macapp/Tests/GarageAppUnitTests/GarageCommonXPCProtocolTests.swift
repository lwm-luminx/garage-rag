import XCTest
import IngestClient
import GarageXPCKit
@testable import GarageApp

final class MockCommonXPCService: NSObject, GarageCommonXPCServiceProtocol {
    var pingResponse = "pong from MockCommonXPCService"
    var logsStdout = "sample stdout line 1\nsample stdout line 2\n"
    var logsStderr = "sample stderr error 1\n"
    var didClearLogs = false

    func ping(with reply: @escaping (String) -> Void) {
        reply(pingResponse)
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        reply("MockCommonXPCService", 12345, 99.5, "ready")
    }

    func updateConfiguration(_ options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        reply(true, nil)
    }

    func runDiagnostic(with reply: @escaping (Bool, String?, String?) -> Void) {
        reply(true, "Mock diagnostic passed", "All systems operational in mock service")
    }

    func getServiceStatus(with reply: @escaping (String) -> Void) {
        reply("{}")
    }

    func runSelfTests(with reply: @escaping (Bool, String) -> Void) {
        reply(true, "{}")
    }

    func restartServices(graceful: Bool, with reply: @escaping (Bool, String?) -> Void) {
        reply(true, nil)
    }

    func fetchLogs(with reply: @escaping (String?, String?) -> Void) {
        reply(logsStdout, logsStderr)
    }

    func fetchBufferedOutput(clearBuffer: Bool, with reply: @escaping (String?, String?, Error?) -> Void) {
        let out = logsStdout
        let err = logsStderr
        if clearBuffer {
            logsStdout = ""
            logsStderr = ""
            didClearLogs = true
        }
        reply(out, err, nil)
    }

    func clearLogs(with reply: @escaping (Bool) -> Void) {
        logsStdout = ""
        logsStderr = ""
        didClearLogs = true
        reply(true)
    }

    func subscribeToLogStream(with reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}

final class GarageCommonXPCProtocolTests: XCTestCase {

    func testOutputCaptureBufferingAndClearing() {
        let capture = GarageXPCOutputCapture(maxBufferSize: 4096)

        capture.appendCustomLog(stream: "stdout", message: "Hello standard output")
        capture.appendCustomLog(stream: "stderr", message: "Warning alert")

        let (out1, err1) = capture.fetchLogs(clearBuffer: false)
        XCTAssertTrue(out1.contains("Hello standard output"))
        XCTAssertTrue(err1.contains("Warning alert"))

        // Clear buffer
        let (out2, err2) = capture.fetchLogs(clearBuffer: true)
        XCTAssertTrue(out2.contains("Hello standard output"))
        XCTAssertTrue(err2.contains("Warning alert"))

        let (out3, err3) = capture.fetchLogs(clearBuffer: false)
        XCTAssertEqual(out3, "")
        XCTAssertEqual(err3, "")
    }

    func testMockCommonXPCServiceProtocolConformance() async throws {
        let mockService = MockCommonXPCService()

        let pingExpectation = expectation(description: "ping")
        mockService.ping { response in
            XCTAssertEqual(response, "pong from MockCommonXPCService")
            pingExpectation.fulfill()
        }

        let infoExpectation = expectation(description: "serviceInfo")
        mockService.getServiceInfo { name, pid, uptime, status in
            XCTAssertEqual(name, "MockCommonXPCService")
            XCTAssertEqual(pid, 12345)
            XCTAssertEqual(uptime, 99.5)
            XCTAssertEqual(status, "ready")
            infoExpectation.fulfill()
        }

        let logsExpectation = expectation(description: "fetchLogs")
        mockService.fetchBufferedOutput(clearBuffer: true) { out, err, error in
            XCTAssertNil(error)
            XCTAssertTrue(out!.contains("sample stdout"))
            XCTAssertTrue(err!.contains("sample stderr"))
            logsExpectation.fulfill()
        }

        await fulfillment(of: [pingExpectation, infoExpectation, logsExpectation], timeout: 2.0)
        XCTAssertTrue(mockService.didClearLogs)
    }

    func testPortNumberFormattingWithoutCommas() {
        let ports = [80, 443, 5432, 8080, 50051, 65535]
        for port in ports {
            let formattedString = "\(port)"
            XCTAssertFalse(formattedString.contains(","), "Port \(port) string representation should not have commas: \(formattedString)")

            // Test integer format style grouping never
            let numberFormatted = port.formatted(.number.grouping(.never))
            XCTAssertFalse(numberFormatted.contains(","), "Port \(port) number formatted grouping never should not have commas: \(numberFormatted)")
            XCTAssertEqual(numberFormatted, "\(port)")
        }
    }

    func testMockCommonXPCServiceRunDiagnostic() async throws {
        let mockService = MockCommonXPCService()
        let expectation = expectation(description: "runDiagnostic")
        mockService.runDiagnostic { success, summary, details in
            XCTAssertTrue(success)
            XCTAssertEqual(summary, "Mock diagnostic passed")
            XCTAssertEqual(details, "All systems operational in mock service")
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testGarageFileLoggerOperations() {
        let testLogName = "test-logger-\(UUID().uuidString).log"
        defer { GarageFileLogger.shared.clear(fileName: testLogName) }

        GarageFileLogger.shared.append(
            fileName: testLogName,
            text: "Initial message test line 1",
            stream: "stdout",
            level: "INFO",
            source: "TestFileLogger"
        )
        GarageFileLogger.shared.append(
            fileName: testLogName,
            text: "Error message test line 2",
            stream: "stderr",
            level: "ERROR",
            source: "TestFileLogger"
        )

        let contents = GarageFileLogger.shared.readLogs(fileName: testLogName)
        XCTAssertTrue(contents.contains("[INFO] [TestFileLogger] Initial message test line 1"))
        XCTAssertTrue(contents.contains("[ERROR] [TestFileLogger] Error message test line 2"))

        // Test clear
        GarageFileLogger.shared.clear(fileName: testLogName)
        let cleared = GarageFileLogger.shared.readLogs(fileName: testLogName)
        XCTAssertEqual(cleared, "")
    }

    @MainActor
    func testOSLogStreamServiceXPCAndFileIngestion() {
        let osLogService = OSLogStreamService()
        osLogService.clearLogs()

        // 1. Direct XPC stdout ingestion
        osLogService.receiveXPCStdout("Ingestion process started\nIngestion chunk 1", source: .ingest, pid: 9999)
        let ingestLogs = osLogService.logs(for: .ingest)
        XCTAssertTrue(ingestLogs.contains(where: { $0.text == "Ingestion process started" }))
        XCTAssertTrue(ingestLogs.contains(where: { $0.text == "Ingestion chunk 1" }))

        // 2. Direct XPC stderr ingestion
        osLogService.receiveXPCStderr("Failed to parse document index 42", source: .embed, pid: 8888)
        let embedLogs = osLogService.logs(for: .embed)
        XCTAssertTrue(embedLogs.contains(where: { $0.text == "Failed to parse document index 42" && $0.level == .error }))

        // 3. Direct XPC structured log ingestion
        osLogService.receiveXPCLog(source: .mcp, level: .warning, message: "MCP server received unsupported tool request", pid: 7777)
        let mcpLogs = osLogService.logs(for: .mcp)
        XCTAssertTrue(mcpLogs.contains(where: { $0.text == "MCP server received unsupported tool request" && $0.level == .warning }))

        // 4. File log ingestion
        let testLogFileName = "test-embed-file-\(UUID().uuidString).log"
        defer { GarageFileLogger.shared.clear(fileName: testLogFileName) }

        GarageFileLogger.shared.append(
            fileName: testLogFileName,
            text: "Batch embedding 128 vectors finished",
            stream: "stdout",
            level: "INFO",
            source: "EmbedService"
        )
        osLogService.loadLogsFromFile(fileName: testLogFileName, for: .embed)
        let reloadedEmbedLogs = osLogService.logs(for: .embed)
        XCTAssertTrue(reloadedEmbedLogs.contains(where: { $0.text.contains("Batch embedding 128 vectors finished") }))
    }
}
