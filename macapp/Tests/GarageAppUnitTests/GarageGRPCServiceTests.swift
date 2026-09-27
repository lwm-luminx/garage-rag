import XCTest
import SwiftUI
import IngestClient
import PythonXPCService
import proto_garage_proto_swift
@testable import GarageApp

final class GarageGRPCServiceTests: XCTestCase {

    @MainActor
    func testInitialStateAndDefaults() {
        let postgres = PostgresService()
        let grpcService = GarageGRPCService(postgres: postgres, port: 50051)

        XCTAssertEqual(grpcService.status, .stopped)
        XCTAssertEqual(grpcService.host, "127.0.0.1")
        XCTAssertEqual(grpcService.port, 50051)
        XCTAssertTrue(grpcService.logs.isEmpty)
    }

    @MainActor
    func testAddressNamesTheSocketWhenThereIsOne() {
        let grpcService = GarageGRPCService(postgres: PostgresService(), port: 50051)
        if let socketPath = grpcService.socketPath {
            XCTAssertTrue(socketPath.hasSuffix("/s/grpc"), socketPath)
            XCTAssertEqual(grpcService.address, "unix:\(socketPath)")
            XCTAssertEqual(grpcService.shortAddress, "a private socket")
        } else {
            XCTAssertEqual(grpcService.address, "127.0.0.1:50051")
            XCTAssertEqual(grpcService.shortAddress, "127.0.0.1:50051")
        }
    }

    func testGarageGRPCStatusEquality() {
        XCTAssertEqual(GarageGRPCStatus.stopped, GarageGRPCStatus.stopped)
        XCTAssertEqual(GarageGRPCStatus.starting, GarageGRPCStatus.starting)
        XCTAssertEqual(GarageGRPCStatus.running, GarageGRPCStatus.running)
        XCTAssertEqual(GarageGRPCStatus.stopping, GarageGRPCStatus.stopping)
        XCTAssertEqual(GarageGRPCStatus.failed("error"), GarageGRPCStatus.failed("error"))
        XCTAssertNotEqual(GarageGRPCStatus.failed("a"), GarageGRPCStatus.failed("b"))
        XCTAssertNotEqual(GarageGRPCStatus.stopped, GarageGRPCStatus.running)
    }

    func testGarageGRPCErrorDescriptions() {
        let dbError = GarageGRPCError.databaseNotOnline
        XCTAssertTrue(dbError.localizedDescription.contains("Database is not online"))

        let cliError = GarageGRPCError.cliNotFound
        XCTAssertTrue(cliError.localizedDescription.contains("garage CLI not found"))

        let timeoutError = GarageGRPCError.startupTimeout
        XCTAssertTrue(timeoutError.localizedDescription.contains("Timed out"))

        let launchError = GarageGRPCError.launchFailed("exec format error")
        XCTAssertTrue(launchError.localizedDescription.contains("exec format error"))

        let serverNotRunning = GarageGRPCError.serverNotRunning
        XCTAssertTrue(serverNotRunning.localizedDescription.contains("gRPC server is not running"))

        let searchFailed = GarageGRPCError.searchFailed("connection refused")
        XCTAssertTrue(searchFailed.localizedDescription.contains("connection refused"))
    }

    @MainActor
    func testStartRefusedWhenDatabaseOffline() async {
        let postgres = PostgresService()
        XCTAssertEqual(postgres.status, .stopped)
        let grpcService = GarageGRPCService(postgres: postgres)

        do {
            try await grpcService.start()
            XCTFail("Expected start to throw databaseNotOnline")
        } catch let error as GarageGRPCError {
            switch error {
            case .databaseNotOnline:
                break // Success
            default:
                XCTFail("Unexpected GarageGRPCError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        if case .failed(let message) = grpcService.status {
            XCTAssertTrue(message.contains("Database is not online"))
        } else {
            XCTFail("Expected status to be .failed, but got \(grpcService.status)")
        }
    }

    @MainActor
    func testSearchResultItemModel() {
        var protoHit = Garage_SearchHit()
        protoHit.rank = 1
        protoHit.title = "Architecture Overview"
        protoHit.uri = "file:///docs/architecture.md"
        protoHit.corpusClass = "document"
        protoHit.trustTier = "authored"
        protoHit.matchedBy = "hybrid"
        protoHit.score = 0.952
        protoHit.headingPath = "System Design > Services"
        protoHit.authors = ["Alice", "Bob"]
        protoHit.text = "This document describes the overall system design."
        protoHit.snippet = "This document describes the overall system design..."

        let item = SearchResultItem(hit: protoHit)

        XCTAssertEqual(item.rank, 1)
        XCTAssertEqual(item.title, "Architecture Overview")
        XCTAssertEqual(item.displayTitle, "Architecture Overview")
        XCTAssertEqual(item.uri, "file:///docs/architecture.md")
        XCTAssertEqual(item.corpusClass, "document")
        XCTAssertEqual(item.trustTier, "authored")
        XCTAssertEqual(item.matchedBy, "hybrid")
        XCTAssertEqual(item.score, 0.952, accuracy: 0.001)
        XCTAssertEqual(item.headingPath, "System Design > Services")
        XCTAssertEqual(item.authors, ["Alice", "Bob"])
        XCTAssertEqual(item.authorsList, "Alice, Bob")
        XCTAssertEqual(item.text, "This document describes the overall system design.")
        XCTAssertEqual(item.snippet, "This document describes the overall system design...")
    }

    @MainActor
    func testSearchResultItemDisplayTitleFallbacks() {
        var hit1 = Garage_SearchHit()
        hit1.rank = 1
        hit1.title = ""
        hit1.headingPath = "Section 2.1"
        hit1.uri = "file:///notes/meeting.txt"
        let item1 = SearchResultItem(hit: hit1)
        XCTAssertEqual(item1.displayTitle, "Section 2.1")

        var hit2 = Garage_SearchHit()
        hit2.rank = 2
        hit2.title = ""
        hit2.headingPath = ""
        hit2.uri = "file:///notes/meeting.txt"
        let item2 = SearchResultItem(hit: hit2)
        XCTAssertEqual(item2.displayTitle, "meeting.txt")

        var hit3 = Garage_SearchHit()
        hit3.rank = 3
        hit3.title = ""
        hit3.headingPath = ""
        hit3.uri = ""
        let item3 = SearchResultItem(hit: hit3)
        XCTAssertEqual(item3.displayTitle, "(untitled)")
    }

    @MainActor
    func testCorpusClassAndTrustTierBadges() {
        let classBadge = CorpusClassBadge(corpusClass: "code")
        let classController = NSHostingController(rootView: classBadge)
        XCTAssertNotNil(classController.view)

        let trustBadge = TrustTierBadge(tier: "reference")
        let trustController = NSHostingController(rootView: trustBadge)
        XCTAssertNotNil(trustController.view)
    }

    @MainActor
    func testSearchViewCreation() {
        let state = AppState()
        let view = SearchView().environmentObject(state)
        let controller = NSHostingController(rootView: view)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testGarageXPCClientAndServiceWiring() {
        let xpcClient = GarageXPCClient()
        XCTAssertEqual(GarageXPCClient.serviceName, "me.rickmark.garage-rag.xpc")
        XCTAssertEqual(GarageXPCConstants.serviceName, "me.rickmark.garage-rag.xpc")

        let postgres = PostgresService()
        let grpcService = GarageGRPCService(postgres: postgres, port: 50051, client: xpcClient)
        XCTAssertEqual(grpcService.port, 50051)
        XCTAssertEqual(grpcService.status, .stopped)

        grpcService.clearLogs()
        XCTAssertTrue(grpcService.logs.isEmpty)

        grpcService.terminateImmediately()
        XCTAssertEqual(grpcService.status, .stopping)
    }
}
