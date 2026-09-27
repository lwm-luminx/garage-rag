import XCTest
import LlamaClient
@testable import LlamaModelLoader
import LlamaServiceHost
import LlamaTestSupport
import PythonXPCService

// MARK: - Resolver

final class LlamaModelResolverTests: XCTestCase {
    private var root: URL!
    private var modelsDir: URL!
    private var catalog: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LlamaModelResolverTests-\(UUID().uuidString)")
        modelsDir = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        catalog = root.appendingPathComponent("models.json")
        let json: [String: Any] = [
            "text_embedding": [
                ["slug": "bge-m3", "name": "BGE-M3", "model_id": "BAAI/bge-m3", "model_ref": "bge-m3", "download_file": "bge-m3-Q8_0.gguf", "context_size": 8192, "native_dims": 1024],
                ["slug": "mxbai-embed-xsmall", "name": "mxbai xsmall", "download_file": "gguf/mxbai-embed-xsmall-v1-q8_0.gguf", "context_size": 512],
                ["slug": "renamed", "name": "Renamed", "model_ref": "renamed-ref", "download_file": "renamed.gguf"],
            ],
            "fact_distil": [
                ["slug": "gemma2-2b", "name": "Gemma 2 2B", "download_file": "gemma-2-2b-it-Q4_K_M.gguf", "context_size": 8192],
            ],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: catalog)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relative: String) throws -> String {
        let url = modelsDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: url)
        return url.path
    }

    private var resolver: LlamaModelResolver {
        LlamaModelResolver(catalogURLs: [root.appendingPathComponent("missing.json"), catalog], modelsDirectory: modelsDir)
    }

    func testResolvesADownloadedCatalogModelWithTheModelsPageSettings() throws {
        let path = try touch("bge-m3-Q8_0.gguf")
        let plan = try resolver.resolve(alias: "bge-m3")
        XCTAssertEqual(plan.alias, "bge-m3")
        XCTAssertEqual(plan.displayName, "BGE-M3")
        XCTAssertEqual(plan.path, path)
        XCTAssertEqual(plan.contextSize, 8192)
        XCTAssertEqual(plan.config["n_ctx"] as? Int, 8192)
        XCTAssertEqual(plan.config["n_gpu_layers"] as? Int, LlamaModelLoadDefaults.gpuLayers)
        XCTAssertEqual(plan.config["threads"] as? Int, LlamaModelLoadDefaults.threads)
    }

    func testFindsADownloadFileKeptInASubfolder() throws {
        let path = try touch("gguf/mxbai-embed-xsmall-v1-q8_0.gguf")
        let plan = try resolver.resolve(alias: "mxbai-embed-xsmall")
        XCTAssertEqual(plan.path, path)
        XCTAssertEqual(plan.contextSize, 512)
    }

    func testFindsTheFileByNameWhenItSitsElsewhereInTheModelsFolder() throws {
        let path = try touch("imported/GEMMA-2-2B-IT-Q4_K_M.gguf")
        XCTAssertEqual(try resolver.resolve(alias: "gemma2-2b").path, path)
    }

    func testAnEntryIsFoundByModelRef() throws {
        _ = try touch("renamed.gguf")
        XCTAssertEqual(try resolver.resolve(alias: "renamed-ref").alias, "renamed-ref")
    }

    func testAnEntryIsFoundByModelID() throws {
        // A llama_xpc registration whose model_ref is the provider-side id, as the add-model form suggests.
        _ = try touch("bge-m3-Q8_0.gguf")
        let plan = try resolver.resolve(alias: "BAAI/bge-m3")
        XCTAssertEqual(plan.displayName, "BGE-M3")
        XCTAssertTrue(plan.path.hasSuffix("bge-m3-Q8_0.gguf"), plan.path)
    }

    func testAMissingDownloadSaysWhatToDownload() {
        XCTAssertThrowsError(try resolver.resolve(alias: "bge-m3")) { error in
            XCTAssertEqual(error as? LlamaModelLoaderError, .notDownloaded(alias: "bge-m3", name: "BGE-M3", file: "bge-m3-Q8_0.gguf"))
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Download BGE-M3 on the Models page"), text)
        }
    }

    func testAModelOutsideTheCatalogResolvesToAFileNamedAfterIt() throws {
        let path = try touch("my-custom-embedder.gguf")
        XCTAssertEqual(try resolver.resolve(alias: "my-custom-embedder").path, path)
    }

    func testAnUnknownModelIsAnError() {
        XCTAssertThrowsError(try resolver.resolve(alias: "nothing-like-it")) { error in
            XCTAssertEqual(error as? LlamaModelLoaderError, .unknownModel(alias: "nothing-like-it"))
        }
    }

    func testContainingAppBundleIsTheOutermostApp() {
        let service = URL(fileURLWithPath: "/Applications/Garage.app/Contents/Helpers/garage-mcp.app/Contents/MacOS/garage-mcp")
        XCTAssertEqual(LlamaModelResolver.containingAppBundle(of: service)?.path, "/Applications/Garage.app")
        XCTAssertNil(LlamaModelResolver.containingAppBundle(of: URL(fileURLWithPath: "/usr/bin/true")))
    }
}

// MARK: - Loader

private final class FakeService: @unchecked Sendable {
    private let lock = NSLock()
    private var resident: Set<String>
    private(set) var ensured: [LlamaModelLoadPlan] = []
    var ensureDelay: UInt64 = 0
    var ensureError: Error?

    init(resident: Set<String> = []) {
        self.resident = resident
    }

    var ensureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ensured.count
    }

    var service: LlamaModelLoader.Service {
        LlamaModelLoader.Service(
            residentAliases: { [self] in
                lock.lock()
                defer { lock.unlock() }
                return Array(resident)
            },
            ensure: { [self] plan in
                if ensureDelay > 0 {
                    try await Task.sleep(nanoseconds: ensureDelay)
                }
                if let ensureError {
                    throw ensureError
                }
                lock.lock()
                ensured.append(plan)
                resident.insert(plan.alias)
                lock.unlock()
                return "Model loaded successfully from \(plan.path)"
            }
        )
    }
}

final class LlamaModelLoaderTests: XCTestCase {
    private static func plan(_ alias: String) -> LlamaModelLoadPlan {
        LlamaModelLoadPlan(alias: alias, displayName: alias, path: "/models/\(alias).gguf")
    }

    func testAResidentModelIsNeitherResolvedNorLoaded() async throws {
        let fake = FakeService(resident: ["bge-m3"])
        let loader = LlamaModelLoader(service: fake.service, resolve: { _ in
            XCTFail("a resident model must not be resolved")
            throw LlamaModelLoaderError.unknownModel(alias: "bge-m3")
        })
        let outcome = try await loader.ensureLoaded(alias: "bge-m3")
        XCTAssertEqual(outcome, .alreadyLoaded)
        XCTAssertEqual(fake.ensureCount, 0)
    }

    func testAMissingModelIsLoadedWithItsPlan() async throws {
        let fake = FakeService(resident: ["bge-m3"])
        let loader = LlamaModelLoader(service: fake.service, resolve: { Self.plan($0) })
        let outcome = try await loader.ensureLoaded(alias: "gemma2-2b")
        XCTAssertEqual(outcome, .loaded(message: "Model loaded successfully from /models/gemma2-2b.gguf"))
        XCTAssertEqual(fake.ensured.map(\.alias), ["gemma2-2b"])
    }

    func testConcurrentCallersShareOneLoad() async throws {
        let fake = FakeService()
        fake.ensureDelay = 200_000_000
        let loader = LlamaModelLoader(service: fake.service, resolve: { Self.plan($0) })
        try await withThrowingTaskGroup(of: LlamaModelLoader.Outcome.self) { group in
            for _ in 0..<8 {
                group.addTask { try await loader.ensureLoaded(alias: "bge-m3") }
            }
            for try await _ in group {}
        }
        XCTAssertEqual(fake.ensureCount, 1)
    }

    func testDifferentModelsLoadIndependently() async throws {
        let fake = FakeService()
        let loader = LlamaModelLoader(service: fake.service, resolve: { Self.plan($0) })
        _ = try await loader.ensureLoaded(alias: "bge-m3")
        _ = try await loader.ensureLoaded(alias: "gemma2-2b")
        _ = try await loader.ensureLoaded(alias: "bge-m3")
        XCTAssertEqual(fake.ensured.map(\.alias), ["bge-m3", "gemma2-2b"])
    }

    func testAResolveErrorReachesTheCallerUnchanged() async {
        let fake = FakeService()
        let loader = LlamaModelLoader(service: fake.service, resolve: { alias in
            throw LlamaModelLoaderError.notDownloaded(alias: alias, name: "BGE-M3", file: "bge-m3-Q8_0.gguf")
        })
        do {
            _ = try await loader.ensureLoaded(alias: "bge-m3")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LlamaModelLoaderError, .notDownloaded(alias: "bge-m3", name: "BGE-M3", file: "bge-m3-Q8_0.gguf"))
        }
        XCTAssertEqual(fake.ensureCount, 0)
    }

    func testAServiceFailureIsALoadFailure() async {
        let fake = FakeService()
        fake.ensureError = LlamaClientError.serverError(statusCode: 500, message: "llama.cpp could not load it")
        let loader = LlamaModelLoader(service: fake.service, resolve: { Self.plan($0) })
        do {
            _ = try await loader.ensureLoaded(alias: "bge-m3")
            XCTFail("expected an error")
        } catch let error as LlamaModelLoaderError {
            guard case .loadFailed(let alias, let message) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(alias, "bge-m3")
            XCTAssertTrue(message.contains("llama.cpp could not load it"), message)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testBlockingCallWaitsForTheLoad() {
        let fake = FakeService()
        fake.ensureDelay = 50_000_000
        let loader = LlamaModelLoader(service: fake.service, resolve: { Self.plan($0) })
        let result = loader.ensureLoadedBlocking(alias: "bge-m3", timeout: 10)
        guard case .success(.loaded) = result else {
            return XCTFail("unexpected \(result)")
        }
        XCTAssertEqual(fake.ensureCount, 1)
    }

    func testBlockingCallTimesOut() {
        let fake = FakeService()
        fake.ensureDelay = 5_000_000_000
        let loader = LlamaModelLoader(service: fake.service, resolve: { Self.plan($0) })
        let result = loader.ensureLoadedBlocking(alias: "bge-m3", timeout: 0.2)
        guard case .failure(let error) = result else {
            return XCTFail("unexpected \(result)")
        }
        XCTAssertEqual(error as? LlamaModelLoaderError, .timedOut(alias: "bge-m3", seconds: 0))
    }

    // MARK: Against the mock engine, through LlamaClient

    func testLoadsThroughLlamaClientEnsureModel() async throws {
        let engine = MockLlamaServerEngine(modelPath: "/tmp/mock-model.gguf", modelAlias: "test-model")
        let service = LlamaModelLoader.Service.xpc(makeClient: { LlamaClient(inProcessEngine: engine) })
        let loader = LlamaModelLoader(service: service, resolve: { Self.plan($0) })

        let resident = try await loader.ensureLoaded(alias: "test-model")
        XCTAssertEqual(resident, .alreadyLoaded)
        XCTAssertEqual(engine.currentModelPath, "/tmp/mock-model.gguf")

        _ = try await loader.ensureLoaded(alias: "bge-m3")
        XCTAssertEqual(engine.currentModelPath, "/models/bge-m3.gguf")
    }

    func testEngineEnsureModelKeepsAResidentAlias() {
        let engine = MockLlamaServerEngine(modelPath: "/tmp/mock-model.gguf", modelAlias: "test-model")
        let resident = engine.ensureModel(path: "/tmp/other.gguf", alias: "test-model", configJson: nil)
        XCTAssertTrue(resident.success)
        XCTAssertEqual(engine.currentModelPath, "/tmp/mock-model.gguf")

        let loaded = engine.ensureModel(path: "/tmp/other.gguf", alias: "other", configJson: nil)
        XCTAssertTrue(loaded.success)
        XCTAssertEqual(engine.currentModelPath, "/tmp/other.gguf")
    }
}

// MARK: - Through a handed-over endpoint

/// What garage-xpc, embed-xpc and mcp-server-xpc do: reach LlamaXPCService through the endpoint of
/// its anonymous listener, handed over by the app, since they cannot look it up by name. Here the
/// service front end (`LlamaXPCServiceDelegate`) runs in the test process on the mock engine, and
/// the calls go over real NSXPC connections to its anonymous listener.
final class LlamaModelLoaderEndpointTests: XCTestCase {
    private static func plan(_ alias: String) -> LlamaModelLoadPlan {
        LlamaModelLoadPlan(alias: alias, displayName: alias, path: "/models/\(alias).gguf")
    }

    private static func service(_ engine: MockLlamaServerEngine) -> LlamaXPCServiceDelegate {
        LlamaXPCServiceDelegate(engine: engine, httpPort: 0, socketPath: nil)
    }

    func testWithoutAnEndpointTheLoaderSaysSo() async {
        let store = GarageLlamaEndpointStore()
        let loader = LlamaModelLoader(service: .handedOverEndpoint(store: store), resolve: { Self.plan($0) })
        do {
            _ = try await loader.ensureLoaded(alias: "bge-m3")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LlamaModelLoaderError, .endpointNotHandedOver)
            XCTAssertTrue(error.localizedDescription.contains("LlamaXPCService endpoint not handed over yet"), error.localizedDescription)
        }
    }

    func testLoadsThroughTheHandedOverEndpoint() async throws {
        let engine = MockLlamaServerEngine(modelPath: "/tmp/mock-model.gguf", modelAlias: "test-model")
        let llama = Self.service(engine)
        let store = GarageLlamaEndpointStore()
        store.set(llama.anonymousListenerEndpoint())
        let loader = LlamaModelLoader(service: .handedOverEndpoint(store: store), resolve: { Self.plan($0) })

        let resident = try await loader.ensureLoaded(alias: "test-model")
        XCTAssertEqual(resident, .alreadyLoaded)

        let outcome = try await loader.ensureLoaded(alias: "bge-m3")
        guard case .loaded = outcome else {
            return XCTFail("unexpected \(outcome)")
        }
        XCTAssertEqual(engine.currentModelPath, "/models/bge-m3.gguf")
        // The anonymous listener lives as long as the service object.
        withExtendedLifetime(llama) {}
    }

    func testANewEndpointReplacesTheConnection() async throws {
        let first = MockLlamaServerEngine(modelPath: "/tmp/first.gguf", modelAlias: "first")
        let second = MockLlamaServerEngine(modelPath: "/tmp/second.gguf", modelAlias: "second")
        let firstService = Self.service(first)
        let secondService = Self.service(second)
        let store = GarageLlamaEndpointStore()
        let loader = LlamaModelLoader(service: .handedOverEndpoint(store: store), resolve: { Self.plan($0) })

        store.set(firstService.anonymousListenerEndpoint())
        _ = try await loader.ensureLoaded(alias: "bge-m3")
        XCTAssertEqual(first.currentModelPath, "/models/bge-m3.gguf")

        // As after LlamaXPCService was relaunched and the app handed its new endpoint over.
        store.set(secondService.anonymousListenerEndpoint())
        _ = try await loader.ensureLoaded(alias: "bge-m3")
        XCTAssertEqual(second.currentModelPath, "/models/bge-m3.gguf")
        withExtendedLifetime((firstService, secondService)) {}
    }

    func testStoreCountsHandOvers() {
        let store = GarageLlamaEndpointStore()
        XCTAssertNil(store.endpoint)
        XCTAssertEqual(store.generation, 0)
        let listener = NSXPCListener.anonymous()
        store.set(listener.endpoint)
        XCTAssertNotNil(store.endpoint)
        XCTAssertEqual(store.generation, 1)
        store.set(nil)
        XCTAssertNil(store.endpoint)
        XCTAssertEqual(store.generation, 2)
    }
}

// MARK: - C bridge

final class LlamaModelLoaderBridgeTests: XCTestCase {
    override func tearDown() {
        LlamaModelLoaderBridge.setLoader(nil)
        super.tearDown()
    }

    private func call(_ alias: String?, capacity: Int = 256) -> (Int32, String) {
        var buffer = [CChar](repeating: 0, count: capacity)
        let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
            if let alias {
                return alias.withCString { LlamaModelLoaderBridge.entry($0, out.baseAddress, capacity) }
            }
            return LlamaModelLoaderBridge.entry(nil, out.baseAddress, capacity)
        }
        return (status, String(cString: buffer))
    }

    func testEntryLoadsThroughTheInstalledLoader() {
        let fake = FakeService()
        LlamaModelLoaderBridge.setLoader(LlamaModelLoader(service: fake.service, resolve: {
            LlamaModelLoadPlan(alias: $0, displayName: $0, path: "/models/\($0).gguf")
        }))
        let (status, message) = call("bge-m3")
        XCTAssertEqual(status, 0)
        XCTAssertTrue(message.contains("/models/bge-m3.gguf"), message)
        XCTAssertEqual(fake.ensureCount, 1)

        let (again, already) = call("bge-m3")
        XCTAssertEqual(again, 0)
        XCTAssertEqual(already, "bge-m3 is already loaded")
    }

    func testEntryReportsWhatToDo() {
        LlamaModelLoaderBridge.setLoader(LlamaModelLoader(service: FakeService().service, resolve: { alias in
            throw LlamaModelLoaderError.notDownloaded(alias: alias, name: "BGE-M3", file: "bge-m3-Q8_0.gguf")
        }))
        let (status, message) = call("bge-m3")
        XCTAssertEqual(status, 1)
        XCTAssertTrue(message.contains("Download BGE-M3 on the Models page"), message)
    }

    func testEntryWithoutALoaderOrAlias() {
        XCTAssertEqual(call("bge-m3").0, 3)
        XCTAssertEqual(call(nil).0, 2)
    }

    func testSelfTestIsSkippedUntilAnEndpointArrives() {
        let test = LlamaModelLoaderBridge.selfTest(store: GarageLlamaEndpointStore())
        XCTAssertEqual(test.name, GarageLlamaEndpointStore.dependentSelfTestName)
        XCTAssertThrowsError(try test.body()) { error in
            XCTAssertTrue(error is GarageXPCSelfTestSkipped, "unexpected \(error)")
            XCTAssertTrue(error.localizedDescription.contains("not handed over yet"), error.localizedDescription)
        }
        let results = GarageXPCSelfTestRunner.run([test])
        XCTAssertEqual(results.first?.status, .skipped)
    }

    func testSelfTestPassesThroughAHandedOverEndpoint() throws {
        let engine = MockLlamaServerEngine(modelPath: "/tmp/mock-model.gguf", modelAlias: "test-model")
        let llama = LlamaXPCServiceDelegate(engine: engine, httpPort: 0, socketPath: nil)
        let store = GarageLlamaEndpointStore()
        store.set(llama.anonymousListenerEndpoint())
        let text = try LlamaModelLoaderBridge.selfTest(store: store).body()
        XCTAssertTrue(text.contains("pong from LlamaXPCService"), text)
        XCTAssertTrue(text.contains("test-model"), text)
        withExtendedLifetime(llama) {}
    }

    func testMessagesAreTruncatedOnScalarBoundaries() {
        var buffer = [CChar](repeating: 0x7f, count: 6)
        buffer.withUnsafeMutableBufferPointer { out in
            LlamaModelLoaderBridge.write("ab\u{00e9}\u{00e9}", to: out.baseAddress, capacity: 6)
        }
        // "ab" (2) + "é" (2) fits in 5 bytes; the second "é" would not.
        XCTAssertEqual(String(cString: buffer), "ab\u{00e9}")
    }
}
