import XCTest
@testable import GarageApp

/// Serves one canned reply to every request made through its session.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var reply: (status: Int, body: Data)?
    nonisolated(unsafe) static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let reply = Self.reply ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ModelCatalogTests: XCTestCase {
    private var directory: URL!
    private var destination: URL!
    private var session: URLSession!

    private let catalog = Data("""
        {"text_embedding": [{"slug": "bge-m3", "name": "BGE-M3", "dims": 1024}], "fact_distil": []}
        """.utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        destination = directory.appendingPathComponent("models.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.reply = nil
        StubURLProtocol.error = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func refresh() async -> Bool {
        await ModelCatalog.refresh(from: ModelCatalog.remoteURL, to: destination, session: session)
    }

    func testTheSiteServesTheCatalog() {
        XCTAssertEqual(ModelCatalog.remoteURL.absoluteString, "https://garagerag.app/.data/models.json")
    }

    func testAUsableCatalogIsSaved() async throws {
        StubURLProtocol.reply = (200, catalog)
        let changed = await refresh()
        XCTAssertTrue(changed)
        XCTAssertEqual(try Data(contentsOf: destination), catalog)
    }

    func testTheSameCatalogIsNotRewritten() async {
        StubURLProtocol.reply = (200, catalog)
        _ = await refresh()
        let changed = await refresh()
        XCTAssertFalse(changed)
    }

    func testAnErrorReplyKeepsTheSavedCatalog() async throws {
        StubURLProtocol.reply = (200, catalog)
        _ = await refresh()
        StubURLProtocol.reply = (404, Data("<html>not found</html>".utf8))
        let changed = await refresh()
        XCTAssertFalse(changed)
        XCTAssertEqual(try Data(contentsOf: destination), catalog)
    }

    func testAFileThatIsNotACatalogIsRejected() async {
        StubURLProtocol.reply = (200, Data(#"{"text_embedding": []}"#.utf8))
        let changed = await refresh()
        XCTAssertFalse(changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testBeingOfflineSavesNothing() async {
        StubURLProtocol.error = URLError(.notConnectedToInternet)
        let changed = await refresh()
        XCTAssertFalse(changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTheCommittedCatalogIsUsable() throws {
        // The file the site serves and the app bundles, from the repository.
        let candidates = [
            Bundle(for: Self.self).url(forResource: "models", withExtension: "json"),
            ProcessInfo.processInfo.environment["TEST_SRCDIR"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("_main/data/models/models.json")
            },
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("data/models/models.json is not in this test's runfiles")
        }
        XCTAssertTrue(GarageConfigLoader.isUsableModelCatalog(try Data(contentsOf: url)))
    }

    func testAFetchedCatalogMissingAGroupDoesNotCoverTheBundledOne() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundled = directory.appendingPathComponent("bundled.json")
        let fetched = directory.appendingPathComponent("fetched.json")
        try Data("""
            {"text_embedding": [{"slug": "a"}], "image_embedding": [{"slug": "b"}], "inference_models": []}
            """.utf8).write(to: bundled)
        try Data(#"{"text_embedding": [{"slug": "a"}]}"#.utf8).write(to: fetched)
        XCTAssertFalse(ModelCatalog.covers(fetched, groupsOf: bundled))

        try Data(#"{"text_embedding": [{"slug": "a"}], "image_embedding": [{"slug": "c"}]}"#.utf8).write(to: fetched)
        XCTAssertTrue(ModelCatalog.covers(fetched, groupsOf: bundled), "an empty bundled group asks nothing of the fetched copy")
        XCTAssertTrue(ModelCatalog.covers(fetched, groupsOf: directory.appendingPathComponent("missing.json")))
    }
}
