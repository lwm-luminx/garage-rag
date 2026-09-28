import XCTest
import ImageEmbedClient
@testable import ImageEmbedEngine

final class ImageModelCatalogTests: XCTestCase {
    private static let catalog = """
    {
      "text_embedding": [{"slug": "bge-m3", "name": "BGE-M3", "native_dims": 1024}],
      "image_embedding": [
        {
          "slug": "siglip2-base-256",
          "name": "SigLIP 2 Base (256 px)",
          "provider": "image_xpc",
          "modality": "image",
          "native_dims": 768,
          "image_size": 256,
          "text_length": 64,
          "image_mean": [0.5, 0.5, 0.5],
          "image_std": [0.5, 0.5, 0.5],
          "text_lowercase": true,
          "image_model": "siglip2-base-patch16-256-image-fp16.mlpackage",
          "text_model": "siglip2-base-patch16-256-text-fp16.mlpackage",
          "tokenizer": "tokenizer.json"
        },
        {"slug": "broken", "name": "No packages"}
      ]
    }
    """

    func testParsesImageEntriesAndSkipsOnesWithoutPackages() throws {
        let specs = try XCTUnwrap(ImageModelResolver.parseCatalog(Data(Self.catalog.utf8)))
        XCTAssertEqual(specs.map(\.slug), ["siglip2-base-256"])
        let spec = specs[0]
        XCTAssertEqual(spec.name, "SigLIP 2 Base (256 px)")
        XCTAssertEqual(spec.imagePackage, "siglip2-base-patch16-256-image-fp16.mlpackage")
        XCTAssertEqual(spec.textPackage, "siglip2-base-patch16-256-text-fp16.mlpackage")
        XCTAssertEqual(spec.tokenizerFile, "tokenizer.json")
        XCTAssertEqual(spec.dims, 768)
        XCTAssertEqual(spec.imageSize, 256)
        XCTAssertEqual(spec.textLength, 64)
        XCTAssertEqual(spec.imageMean, [0.5, 0.5, 0.5])
        XCTAssertTrue(spec.textLowercase)
    }

    func testNotACatalogIsNil() {
        XCTAssertNil(ImageModelResolver.parseCatalog(Data("[1, 2]".utf8)))
    }

    func testTheCommittedCatalogDescribesSigLIP2() throws {
        // The app bundles data/models/models.json as the fallback catalog; the test's own bundle
        // does not, so this reads the repository copy: from the runfiles under Bazel, else through
        // the source tree when it is there.
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            ProcessInfo.processInfo.environment["TEST_SRCDIR"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("_main/data/models/models.json")
            },
            repo.appendingPathComponent("data/models/models.json"),
        ].compactMap { $0 }
        guard let catalog = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let data = try? Data(contentsOf: catalog)
        else {
            throw XCTSkip("data/models/models.json is not in this test's runfiles or beside the test sources")
        }
        let specs = try XCTUnwrap(ImageModelResolver.parseCatalog(data))
        XCTAssertTrue(specs.contains { $0.slug == "siglip2-base-256" && $0.dims == 768 })
    }

    func testFolderPerSlugAndMissingFilesAreNamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ImageModelResolver(catalogURLs: [], modelsDirectory: root)
        XCTAssertEqual(resolver.folder(for: "siglip2-base-256").lastPathComponent, "siglip2-base-256")

        let spec = ImageModelSpec(slug: "siglip2-base-256", imagePackage: "image.mlpackage", textPackage: "text.mlpackage")
        XCTAssertThrowsError(try resolver.locate(spec)) { error in
            guard case ImageModelResolverError.notDownloaded(_, let missing, _) = error else {
                return XCTFail("expected notDownloaded, got \(error)")
            }
            XCTAssertEqual(Set(missing), ["image.mlpackage", "text.mlpackage", "tokenizer.json"])
        }
    }

    func testFolderWithoutCatalogEntryIsResolvedFromItsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("custom", isDirectory: true)
        for name in ["custom-image.mlpackage", "custom-text.mlpackage"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))

        let resolver = ImageModelResolver(catalogURLs: [], modelsDirectory: root)
        let spec = try resolver.spec(for: "custom")
        XCTAssertEqual(spec.imagePackage, "custom-image.mlpackage")
        XCTAssertEqual(spec.textPackage, "custom-text.mlpackage")
        XCTAssertNil(spec.dims)
        let files = try resolver.locate(spec)
        XCTAssertEqual(files.tokenizer.lastPathComponent, "tokenizer.json")
        XCTAssertThrowsError(try resolver.spec(for: "absent"))
    }

    func testVectorsRoundTripThroughTheWireForm() throws {
        let vectors: [[Float]] = [[0.25, -1, 3.5], [1, 2, 3]]
        let data = ImageEmbedVectors.encode(vectors)
        XCTAssertEqual(data.count, 6 * 4)
        XCTAssertEqual(ImageEmbedVectors.decode(data, count: 2), vectors)
        XCTAssertNil(ImageEmbedVectors.decode(data, count: 4))
        XCTAssertEqual(ImageEmbedVectors.decode(Data(), count: 0), [])
    }
}
