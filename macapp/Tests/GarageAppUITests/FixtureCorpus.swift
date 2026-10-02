import XCTest

/// What the made-up corpus in `macapp/Tests/Fixtures/corpus` holds, as its README lists it.
/// `garage_python/tests/test_fixture_corpus.py` checks the same facts against the real extractors.
enum FixtureCorpus {
    struct Document {
        let file: String
        let title: String
        /// An invented word that only this file contains.
        let token: String
        /// `corpus_class` and `trust_tier`, as the Documents page's badges show them.
        let corpusClass: String
        let trustTier: String
        /// How many chunks the file makes.
        var chunks = 1
    }

    static let quillonBridge = Document(file: "quillon-bridge.md", title: "The Quillon Bridge", token: "zorvexine",
                                        corpusClass: "Document", trustTier: "Authored", chunks: 2)
    static let lighthouse = Document(file: "marrowgate-lighthouse.txt", title: "Marrowgate Lighthouse", token: "plimbrate",
                                     corpusClass: "Document", trustTier: "Authored")
    static let tideTables = Document(file: "tide_tables.rs", title: "tide_tables.rs", token: "tessaroon",
                                     corpusClass: "Code", trustTier: "Authored")
    static let lanternFestival = Document(file: "lantern-festival.eml", title: "The Brindlecombe lantern festival", token: "wendleflock",
                                          corpusClass: "Communication", trustTier: "Received")
    static let orchard = Document(file: "ashvale-orchard.pdf", title: "The Ashvale Orchard Survey", token: "orbanquet",
                                  corpusClass: "Document", trustTier: "Reference")
    static let glassworks = Document(file: "tavish-glassworks.docx", title: "A History of Tavish Glassworks", token: "glimmerhaft",
                                     corpusClass: "Document", trustTier: "Reference")

    /// What a source added through the Sources page indexes: code is off there, so not the Rust file.
    static let indexedWithoutCode = [quillonBridge, lighthouse, lanternFestival, orchard, glassworks]
    /// Every file: what the source menu's Ingest Including Code indexes.
    static let indexedWithCode = indexedWithoutCode + [tideTables]
    /// Chunks of `indexedWithoutCode`: the Markdown note splits at its second heading.
    static let chunksWithoutCode = 6
    static let chunksWithCode = 7
    static let quillonBridgeChunks = 2

    /// What the model UI tests' deterministic engine (`DeterministicLlamaEngine` in LlamaTestSupport)
    /// distills from `indexedWithoutCode`: one fact per sentence of five words or more, of kind
    /// `event` when it holds a four-digit year and `fact` otherwise. `test_fixture_corpus.py` checks
    /// these counts against the vendored LangExtract.
    static let distilledFacts = 20
    static let distilledEvents = 11
    static let distilledFromMail = 3
    static let quillonBridgeFacts = 5
    /// What Glean Facts reads from the mail's headers with no model (`garage_rag/enrich/metadata.py`):
    /// its sender, its one recipient and its subject, of kinds `sender`, `recipient` and `subject`.
    static let metadataFactsFromMail = 3
    /// Every potential fact a Glean Facts run stores: the engine's and the mail's metadata facts.
    static let gleanedFacts = distilledFacts + metadataFactsFromMail
    static let gleanedFromMail = distilledFromMail + metadataFactsFromMail
    /// The one sentence that carries the Markdown note's token, and so the one fact that does.
    static let zorvexineFact = "Townspeople call the middle arch the zorvexine arch, after the swallows that nest under it."
}

extension GarageUITestCase {
    /// A copy of the fixture corpus in this test's data folder, to add as a source. The bundle's own
    /// copy is never a source: an ingest would record paths inside the test bundle.
    func copyFixtureCorpus(named name: String = "corpus", file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let bundled = try XCTUnwrap(
            Bundle(for: GarageUITestCase.self).resourceURL?.appendingPathComponent("corpus", isDirectory: true),
            "the UI test bundle has no resources folder",
            file: file,
            line: line
        )
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            XCTFail("the UI test bundle has no corpus at \(bundled.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        let copy = dataDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: bundled, to: copy)
        return copy
    }

    /// Copies the corpus into this test's data folder (or takes the copy at `root`), adds it as the
    /// source `slug`, runs its Scan & Ingest and waits until the Status page counts every document.
    /// Leaves the Status page open.
    @discardableResult
    func ingestFixtureCorpus(
        slug: String = "fixture",
        root: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let corpus = try root ?? copyFixtureCorpus(file: file, line: line)
        addCustomSource(slug: slug, root: corpus, file: file, line: line)

        let scanIngest = element(identifier: "sources.row.\(slug).scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled", file: file, line: line)
        click(scanIngest)

        open(section: "status", file: file, line: line)
        let documents = element(identifier: "status.figure.documents")
        let expected = String(FixtureCorpus.indexedWithoutCode.count)
        XCTAssertTrue(
            waitUntil(timeout: 240) { documents.exists && self.shownText(of: documents) == expected },
            "the Status page never counted the corpus's \(expected) documents (\(documents.exists ? shownText(of: documents) : "missing"))",
            file: file,
            line: line
        )
        return corpus
    }
}
