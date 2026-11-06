import Foundation
import GarageEmbedWorker
import ImageEmbedBridge
import ImageEmbedClient
import XCTest

/// The Rust embed worker linked into a Swift process, with the host's model servers faked: each
/// request the worker sends reaches the right member of `GarageEmbedWorkerHost`, and each reply
/// comes back as vectors.
final class GarageEmbedWorkerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        func append(_ item: String) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private static func noImages() -> ImageEmbedAccess.Service? { nil }

    func testOllamaGoesOverHTTPToTheApprovedURL() throws {
        let asked = Recorder()
        let host = GarageEmbedWorkerHost(
            images: Self.noImages(),
            send: { request in
                asked.append("\(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
                let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let inputs = body?["input"] as? [String] ?? []
                let reply = ["embeddings": inputs.map { [Float($0.count), 0] }]
                return .success((200, try! JSONSerialization.data(withJSONObject: reply)))
            }
        )
        let vectors = try GarageEmbedWorker.embedTexts(provider: "ollama", modelRef: "nomic", texts: ["abc", "de"], host: host).get()
        XCTAssertEqual(vectors, [[3, 0], [2, 0]])
        XCTAssertEqual(asked.values, ["POST http://localhost:11434/api/embed"])
    }

    func testAnOffBoxHostIsRefusedBeforeTheHostIsAsked() {
        let asked = Recorder()
        let host = GarageEmbedWorkerHost(
            images: Self.noImages(),
            send: { request in
                asked.append(request.url?.absoluteString ?? "?")
                return .failure(URLError(.cannotConnectToHost))
            }
        )
        // llama_host must be loopback: the worker's egress rules refuse anything else.
        let result = GarageEmbedWorker.embedTexts(
            provider: "llama_xpc",
            modelRef: "mxbai-embed-xsmall",
            texts: ["abc"],
            settings: ["llama_host": "http://example.com:8790"],
            host: host
        )
        guard case .failure(let failure) = result else {
            return XCTFail("an off-box llama_host was accepted")
        }
        XCTAssertEqual(failure.kind, .failed)
        XCTAssertEqual(asked.values, [])
    }

    func testLlamaXPCGoesOverNSXPCAndLoadsAModelOnDemand() throws {
        let asked = Recorder()
        let loaded = Recorder()
        let host = GarageEmbedWorkerHost(
            llamaRequest: { method, path, body, _ in
                asked.append("\(method) \(path)")
                if loaded.values.isEmpty {
                    return .success((503, #"{"error": {"message": "no model loaded"}}"#))
                }
                let inputs = (try? JSONSerialization.jsonObject(with: Data((body ?? "").utf8)) as? [String: Any])?["input"] as? [String] ?? []
                let data = inputs.enumerated().map { ["index": $0.offset, "embedding": [Float($0.element.count)]] as [String: Any] }
                let reply = String(decoding: try! JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self)
                return .success((200, reply))
            },
            ensureLlamaModel: { alias in
                loaded.append(alias)
                return .success("loaded \(alias)")
            },
            images: Self.noImages(),
            send: { _ in
                XCTFail("llama_xpc went over HTTP")
                return .failure(URLError(.unsupportedURL))
            }
        )
        let vectors = try GarageEmbedWorker.embedTexts(provider: "llama_xpc", modelRef: "mxbai-embed-xsmall", texts: ["abcd"], host: host).get()
        XCTAssertEqual(vectors, [[4]])
        XCTAssertEqual(loaded.values, ["mxbai-embed-xsmall"])
        XCTAssertEqual(asked.values, ["POST /v1/embeddings", "POST /v1/embeddings"])
    }

    func testImageModelsGoToTheImageService() throws {
        let images = ImageEmbedAccess.Service(
            loadModel: { slug in ImageEmbedModelInfo(slug: slug, dims: 2, imageSize: 256, textLength: 64) },
            embedImages: { blobs, _ in blobs.map { [Float($0.count), 1] } },
            embedTexts: { texts, _ in texts.map { [Float($0.count), 2] } }
        )
        let host = GarageEmbedWorkerHost(images: images)
        let vectors = try GarageEmbedWorker.embedTexts(provider: "image_xpc", modelRef: "siglip2-base-256", texts: ["a cat"], host: host).get()
        XCTAssertEqual(vectors, [[5, 2]])
    }

    func testAnUnknownProviderIsRefused() {
        let result = GarageEmbedWorker.embedTexts(provider: "none", modelRef: "none", texts: ["x"], host: GarageEmbedWorkerHost(images: Self.noImages()))
        guard case .failure(let failure) = result else {
            return XCTFail("an unknown provider embedded")
        }
        XCTAssertEqual(failure.kind, .failed)
    }

    func testABackfillWithNoServerFailsWithTheReason() {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("garage-embed-\(UUID().uuidString).sock").path
        let events = Recorder()
        let host = GarageEmbedWorkerHost(images: Self.noImages(), progress: { events.append($0.phase) })
        let result = GarageEmbedWorker.backfill(.init(grpc: .socket(socket), token: "t"), host: host)
        guard case .failure(let failure) = result else {
            return XCTFail("a backfill with no GarageService succeeded")
        }
        XCTAssertEqual(failure.kind, .failed)
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(events.values, [])
    }
}
