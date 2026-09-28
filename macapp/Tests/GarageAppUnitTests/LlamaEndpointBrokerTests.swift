import XCTest
import PythonXPCService
@testable import GarageApp

/// A connection the fake connector made; `lose()` plays the service being relaunched.
private class FakeLink: LlamaEndpointLink {
    let lock = NSLock()
    private let onLost: () -> Void
    private var _invalidated = false

    init(onLost: @escaping () -> Void) {
        self.onLost = onLost
    }

    var invalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _invalidated
    }

    func invalidate() {
        lock.lock()
        let first = !_invalidated
        _invalidated = true
        lock.unlock()
        // As NSXPC does: invalidating calls the invalidation handler.
        if first {
            onLost()
        }
    }

    func lose() {
        onLost()
    }
}

private final class FakeSource: FakeLink, LlamaEndpointSource {
    private let answer: () -> NSXPCListenerEndpoint?
    private var _fetches = 0

    init(answer: @escaping () -> NSXPCListenerEndpoint?, onLost: @escaping () -> Void) {
        self.answer = answer
        super.init(onLost: onLost)
    }

    var fetches: Int {
        lock.lock()
        defer { lock.unlock() }
        return _fetches
    }

    func fetchEndpoint(_ reply: @escaping (NSXPCListenerEndpoint?, String?) -> Void) {
        lock.lock()
        _fetches += 1
        lock.unlock()
        let endpoint = answer()
        DispatchQueue.global().async {
            reply(endpoint, endpoint == nil ? "not yet" : nil)
        }
    }
}

private final class FakeReceiver: FakeLink, LlamaEndpointReceiver {
    let id: String
    private let accepts: () -> Bool
    private var _delivered: [NSXPCListenerEndpoint] = []

    init(id: String, accepts: @escaping () -> Bool, onLost: @escaping () -> Void) {
        self.id = id
        self.accepts = accepts
        super.init(onLost: onLost)
    }

    var delivered: [NSXPCListenerEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return _delivered
    }

    func deliver(_ endpoint: NSXPCListenerEndpoint, _ reply: @escaping (Bool, String?) -> Void) {
        let accepted = accepts()
        lock.lock()
        if accepted {
            _delivered.append(endpoint)
        }
        lock.unlock()
        DispatchQueue.global().async {
            reply(accepted, accepted ? "ok" : "refused")
        }
    }
}

private final class FakeConnector: @unchecked Sendable {
    private let lock = NSLock()
    private var _sources: [FakeSource] = []
    private var _receivers: [String: [FakeReceiver]] = [:]
    private var _endpointAvailable = true
    private var _refusals: [String: Int] = [:]
    /// Each fetch answers the endpoint of a new anonymous listener, as a relaunched service would.
    private var listeners: [NSXPCListener] = []

    var endpointAvailable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _endpointAvailable }
        set { lock.lock(); _endpointAvailable = newValue; lock.unlock() }
    }

    func refuse(_ id: String, times: Int) {
        lock.lock()
        _refusals[id] = times
        lock.unlock()
    }

    var sources: [FakeSource] {
        lock.lock()
        defer { lock.unlock() }
        return _sources
    }

    func receivers(_ id: String) -> [FakeReceiver] {
        lock.lock()
        defer { lock.unlock() }
        return _receivers[id] ?? []
    }

    private func makeEndpoint() -> NSXPCListenerEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard _endpointAvailable else { return nil }
        let listener = NSXPCListener.anonymous()
        listeners.append(listener)
        return listener.endpoint
    }

    private func shouldAccept(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let left = _refusals[id], left > 0 {
            _refusals[id] = left - 1
            return false
        }
        return true
    }

    var connector: LlamaEndpointConnector {
        LlamaEndpointConnector(
            connectSource: { [self] onLost in
                let source = FakeSource(answer: { [self] in makeEndpoint() }, onLost: onLost)
                lock.lock()
                _sources.append(source)
                lock.unlock()
                return source
            },
            connectReceiver: { [self] id, onLost in
                let receiver = FakeReceiver(id: id, accepts: { [self] in shouldAccept(id) }, onLost: onLost)
                lock.lock()
                _receivers[id, default: []].append(receiver)
                lock.unlock()
                return receiver
            }
        )
    }
}

final class LlamaEndpointBrokerTests: XCTestCase {
    private let ids = LlamaEndpointBroker.receiverServiceIds
    private var brokers: [LlamaEndpointBroker] = []

    override func tearDown() {
        brokers.forEach { $0.stop() }
        brokers = []
        super.tearDown()
    }

    private func makeBroker(_ fake: FakeConnector) -> LlamaEndpointBroker {
        let broker = LlamaEndpointBroker(connector: fake.connector, retryDelays: [0.02], lostDelay: 0.01, roundTimeout: 5)
        brokers.append(broker)
        return broker
    }

    private func waitUntil(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func testTheReceiversAreTheServicesThatLoadModelsOnDemand() {
        XCTAssertEqual(Set(ids), ["garage-xpc", "embed-xpc", "mcp-server-xpc"])
        let known = Set(XPCServiceManager.defaultServices.map(\.id))
        XCTAssertTrue(Set(ids).isSubset(of: known))
    }

    func testStartHandsOneEndpointToEveryReceiver() {
        let fake = FakeConnector()
        let broker = makeBroker(fake)
        broker.start()
        waitUntil { broker.successfulRounds == 1 }

        XCTAssertEqual(fake.sources.count, 1)
        XCTAssertEqual(fake.sources.first?.fetches, 1)
        let delivered = ids.compactMap { fake.receivers($0).first?.delivered.first }
        XCTAssertEqual(delivered.count, ids.count)
        XCTAssertTrue(delivered.allSatisfy { $0 === delivered[0] })

        broker.start()  // idempotent
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(broker.successfulRounds, 1)
    }

    func testARelaunchedReceiverGetsTheSameEndpointAgain() {
        let fake = FakeConnector()
        let broker = makeBroker(fake)
        broker.start()
        waitUntil { broker.successfulRounds == 1 }
        let first = fake.receivers("embed-xpc")[0]

        first.lose()
        waitUntil { broker.successfulRounds == 2 }

        // A new connection to the relaunched service, and no new fetch from LlamaXPCService.
        XCTAssertEqual(fake.receivers("embed-xpc").count, 2)
        XCTAssertTrue(first.invalidated)
        XCTAssertEqual(fake.sources.count, 1)
        XCTAssertEqual(fake.sources[0].fetches, 1)
        XCTAssertTrue(fake.receivers("embed-xpc")[1].delivered.first === first.delivered.first)
    }

    func testARelaunchedLlamaServiceHandsEveryoneANewEndpoint() {
        let fake = FakeConnector()
        let broker = makeBroker(fake)
        broker.start()
        waitUntil { broker.successfulRounds == 1 }
        let oldEndpoint = fake.receivers("garage-xpc")[0].delivered[0]

        fake.sources[0].lose()
        waitUntil { broker.successfulRounds == 2 }

        XCTAssertEqual(fake.sources.count, 2)
        XCTAssertTrue(fake.sources[0].invalidated)
        for id in ids {
            let delivered = fake.receivers(id).flatMap(\.delivered)
            XCTAssertEqual(delivered.count, 2, id)
            XCTAssertFalse(delivered[1] === oldEndpoint, id)
        }
    }

    func testHandOverAgainWithRefetchAsksForANewEndpoint() {
        let fake = FakeConnector()
        let broker = makeBroker(fake)
        broker.start()
        waitUntil { broker.successfulRounds == 1 }

        broker.handOverAgain(refetch: true)
        waitUntil { broker.successfulRounds == 2 }
        XCTAssertEqual(fake.sources.count, 2)

        broker.handOverAgain()
        waitUntil { broker.successfulRounds == 3 }
        XCTAssertEqual(fake.sources.count, 2)
    }

    func testARefusedHandOverIsRetried() {
        let fake = FakeConnector()
        fake.refuse("mcp-server-xpc", times: 2)
        let broker = makeBroker(fake)
        broker.start()
        waitUntil { broker.successfulRounds == 1 }
        XCTAssertEqual(fake.receivers("mcp-server-xpc").flatMap(\.delivered).count, 1)
        // Each refusal dropped the connection, so the retry used a fresh one.
        XCTAssertEqual(fake.receivers("mcp-server-xpc").count, 3)
    }

    func testNoEndpointYetIsRetriedUntilOneComes() {
        let fake = FakeConnector()
        fake.endpointAvailable = false
        let broker = makeBroker(fake)
        broker.start()
        waitUntil { fake.sources.count >= 2 }
        XCTAssertEqual(broker.successfulRounds, 0)
        XCTAssertTrue(ids.allSatisfy { fake.receivers($0).isEmpty })

        fake.endpointAvailable = true
        waitUntil { broker.successfulRounds == 1 }
        XCTAssertTrue(ids.allSatisfy { fake.receivers($0).first?.delivered.count == 1 })
    }

    func testStopClosesEveryConnectionAndIgnoresLostOnes() {
        let fake = FakeConnector()
        let broker = makeBroker(fake)
        broker.start()
        waitUntil { broker.successfulRounds == 1 }

        broker.stop()
        XCTAssertFalse(broker.isRunning)
        XCTAssertTrue(fake.sources.allSatisfy(\.invalidated))
        XCTAssertTrue(ids.allSatisfy { fake.receivers($0).allSatisfy(\.invalidated) })

        // A helper killed after stop() must not be relaunched by a new hand-over.
        fake.sources[0].lose()
        fake.receivers("garage-xpc")[0].lose()
        broker.handOverAgain(refetch: true)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(broker.successfulRounds, 1)
        XCTAssertEqual(fake.sources.count, 1)
        XCTAssertEqual(fake.receivers("garage-xpc").count, 1)

        // start() after stop() (a failed database reset) hands it over again.
        broker.start()
        waitUntil { broker.successfulRounds == 2 }
        XCTAssertEqual(fake.sources.count, 2)
    }

    @MainActor
    func testTheManagerStartsTheBrokerWithStreamingAndStopsItFirstOnTerminate() {
        let fake = FakeConnector()
        let broker = makeBroker(fake)
        let manager = XPCServiceManager(initialServices: [], pingExecutor: nil, killExecutor: { _ in true }, llamaEndpointBroker: broker)

        manager.startStreamingAllServices()
        waitUntil { broker.successfulRounds == 1 }

        manager.terminateAll()
        XCTAssertFalse(broker.isRunning)
        XCTAssertTrue(fake.sources.allSatisfy(\.invalidated))
    }

    @MainActor
    func testUnitTestManagersHaveNoBroker() {
        XCTAssertNil(XPCServiceManager().llamaEndpointBroker)
    }
}
