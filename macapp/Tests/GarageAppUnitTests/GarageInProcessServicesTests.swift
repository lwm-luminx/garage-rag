import XCTest
import PythonXPCService
@testable import GarageApp

@objc private protocol InProcessEchoProtocol {
    func echo(_ text: String, with reply: @escaping (String) -> Void)
}

private final class InProcessEcho: NSObject, NSXPCListenerDelegate, InProcessEchoProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: InProcessEchoProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func echo(_ text: String, with reply: @escaping (String) -> Void) {
        reply("echo: \(text)")
    }
}

final class GarageInProcessServicesTests: XCTestCase {
    private let serviceName = "me.rickmark.garage-rag.test.in-process"

    override func tearDown() {
        GarageInProcessServices.removeAll()
        super.tearDown()
    }

    func testAServiceIsOutOfProcessUntilRegistered() {
        XCTAssertFalse(GarageInProcessServices.isInProcess(serviceName))
        XCTAssertEqual(GarageInProcessServices.makeConnection(serviceName: serviceName).serviceName, serviceName)
    }

    func testARegisteredServiceIsReachedThroughItsListener() {
        let echo = InProcessEcho()
        let listener = NSXPCListener.anonymous()
        listener.delegate = echo
        listener.resume()
        defer { listener.invalidate() }
        GarageInProcessServices.register(listener.endpoint, forServiceName: serviceName)

        XCTAssertTrue(GarageInProcessServices.isInProcess(serviceName))
        let connection = GarageInProcessServices.makeConnection(serviceName: serviceName)
        XCTAssertNil(connection.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: InProcessEchoProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let replied = expectation(description: "reply")
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("in-process call failed: \(error)")
            replied.fulfill()
        } as? InProcessEchoProtocol
        proxy?.echo("hello") { answer in
            XCTAssertEqual(answer, "echo: hello")
            replied.fulfill()
        }
        wait(for: [replied], timeout: 10)
    }

    func testTheAppHostsNothingWhenNotSandboxed() {
        InProcessServiceHost.startIfSandboxed(isSandboxed: false)
        for service in InProcessServiceHost.hostedServices {
            XCTAssertFalse(GarageInProcessServices.isInProcess(service.name))
        }
    }

    @MainActor
    func testRestartNeverKillsTheAppHostingAService() async {
        let ownPid = getpid()
        let killed = KilledPids()
        let manager = XPCServiceManager(
            initialServices: [
                XPCServiceInfo(id: "ingest-xpc", name: "Ingest", bundleId: "me.rickmark.garage-rag.ingest-xpc", serviceDescription: "", state: .running(pid: ownPid, latencyMs: 1, response: "ok")),
            ],
            pingExecutor: { _ in (ownPid, 1, "ok") },
            killExecutor: { pid in
                killed.append(pid)
                return true
            },
            llamaEndpointBroker: nil
        )

        _ = await manager.restart(serviceId: "ingest-xpc")
        manager.terminateAll()

        XCTAssertEqual(killed.values, [])
    }
}

private final class KilledPids: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [pid_t] = []

    var values: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        _values.append(pid)
    }
}
