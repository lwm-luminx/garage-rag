import Foundation
import GaragePluginProto
import GaragePlugins
import XCTest

final class NativeTextReaderTests: XCTestCase {
    private let reader = NativeTextReader()

    func testDescribesTheTextExtractors() throws {
        XCTAssertEqual(NativeTextReader.contract, .contractVersion1)
        let described = try reader.describe()
        XCTAssertEqual(described.name, "garage-text")
        XCTAssertEqual(described.contract, .contractVersion1)
        XCTAssertEqual(described.extractors.map(\.name), ["markdown", "plaintext", "code"])
        let markdown = try XCTUnwrap(described.extractors.first { $0.name == "markdown" })
        XCTAssertTrue(markdown.extensions.contains(".md"))
        XCTAssertEqual(markdown.kind, .markdown)
    }

    func testReadsMarkdownWithFrontMatter() throws {
        let text = "---\ntitle: Garden plan\nauthor: Ada Lovelace\n---\n# Heading\n\nTomatoes go in May.\n"
        let response = try reader.extract(fileName: "plan.md", content: Data(text.utf8))
        guard case let .document(document)? = response.outcome else {
            return XCTFail("expected a document, got \(response)")
        }
        XCTAssertEqual(document.extractor, "markdown")
        XCTAssertEqual(document.kind, .markdown)
        XCTAssertEqual(document.title, "Garden plan")
        XCTAssertEqual(document.authorHints, ["Ada Lovelace"])
        XCTAssertTrue(document.text.contains("Tomatoes go in May."))
        let meta = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(document.metaJson.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(meta["frontmatter"])
    }

    func testAnEmptyFileHasNoText() throws {
        let response = try reader.extract(fileName: "empty.txt", content: Data())
        guard case .noText? = response.outcome else {
            return XCTFail("expected no text, got \(response)")
        }
    }

    func testAnUnknownExtensionIsUnsupported() throws {
        let response = try reader.extract(fileName: "photo.jpeg", content: Data([0xFF, 0xD8]))
        guard case let .failure(failure)? = response.outcome else {
            return XCTFail("expected a failure, got \(response)")
        }
        XCTAssertEqual(failure.code, .unsupported)
    }

    func testANamedExtractorOverridesTheExtension() throws {
        let response = try reader.extract(fileName: "a.md", content: Data("# T\nbody".utf8), extractor: "plaintext")
        guard case let .document(document)? = response.outcome else {
            return XCTFail("expected a document, got \(response)")
        }
        XCTAssertEqual(document.extractor, "plaintext")

        let unknown = try reader.extract(fileName: "a.txt", content: Data("x".utf8), extractor: "pdf")
        guard case let .failure(failure)? = unknown.outcome else {
            return XCTFail("expected a failure, got \(unknown)")
        }
        XCTAssertEqual(failure.code, .unsupported)
    }
}
