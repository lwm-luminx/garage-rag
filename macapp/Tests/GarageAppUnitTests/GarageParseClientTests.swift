import XCTest
import GarageXPCKit
@testable import GarageIngestXPCServiceCore

/// A reader process in this test: answers, never answers, or drops the connection mid-file as a
/// crashed process would.
private final class FakeParser: NSObject, GarageParseXPCProtocol, NSXPCListenerDelegate {
    enum Behavior { case answer, hang, crash }
    var behavior: Behavior = .answer
    private var connections: [NSXPCConnection] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: GarageParseXPCProtocol.self)
        connection.exportedObject = self
        connections.append(connection)
        connection.resume()
        return true
    }

    func parse(_ request: String, bytes: Data, withReply reply: @escaping (String?, String?) -> Void) {
        switch behavior {
        case .answer:
            reply("{\"no_text\": \"\(bytes.count) bytes for \(request.count)\"}", nil)
        case .hang:
            break
        case .crash:
            connections.forEach { $0.invalidate() }
        }
    }
}

final class GarageParseClientTests: XCTestCase {
    private var listener: NSXPCListener!
    private var parser: FakeParser!
    private var client: GarageParseClient!

    override func setUp() {
        parser = FakeParser()
        listener = NSXPCListener.anonymous()
        listener.delegate = parser
        listener.resume()
        let endpoint = listener.endpoint
        client = GarageParseClient(deadline: .init(base: 1, perMegabyte: 0)) {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: GarageParseXPCProtocol.self)
            return connection
        }
    }

    override func tearDown() {
        listener.invalidate()
    }

    func testAnAnswerComesBack() {
        XCTAssertEqual(client.parse(request: "{}", bytes: Data([1, 2, 3])), .reply("{\"no_text\": \"3 bytes for 2\"}"))
    }

    func testAReaderThatHangsCostsTheFileAndTheNextFileGetsANewProcess() {
        parser.behavior = .hang
        guard case .failed(let reason) = client.parse(request: "{}", bytes: Data()) else {
            return XCTFail("a hang must fail the file")
        }
        XCTAssertTrue(reason.contains("took longer than 1 seconds"), reason)
        parser.behavior = .answer
        XCTAssertEqual(client.parse(request: "{}", bytes: Data([1])), .reply("{\"no_text\": \"1 bytes for 2\"}"))
    }

    func testAReaderThatDiesCostsTheFileAndTheNextFileGetsANewProcess() {
        parser.behavior = .crash
        guard case .failed(let reason) = client.parse(request: "{}", bytes: Data()) else {
            return XCTFail("a crash must fail the file")
        }
        XCTAssertTrue(reason.hasPrefix("the reader crashed on this file"), reason)
        parser.behavior = .answer
        XCTAssertEqual(client.parse(request: "{}", bytes: Data([1, 2])), .reply("{\"no_text\": \"2 bytes for 2\"}"))
    }

    func testTheDeadlineGrowsWithTheFile() {
        let deadline = GarageParseClient.Deadline(base: 120, perMegabyte: 2)
        XCTAssertEqual(deadline.seconds(forBytes: 0), 120)
        XCTAssertEqual(deadline.seconds(forBytes: 10 * 1_048_576), 140)
    }
}
