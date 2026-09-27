import XCTest
@testable import ImageEmbedEngine

/// The Gemma-style tokenizer the SigLIP 2 text tower takes, on a tiny synthetic tokenizer.json
/// in the same shape as the real one: SentencePiece-BPE vocab, `▁` for spaces, merges, byte fallback.
final class BPETokenizerTests: XCTestCase {
    private static let tokenizerJSON = """
    {
      "version": "1.0",
      "added_tokens": [
        {"id": 0, "content": "<pad>", "special": true},
        {"id": 1, "content": "<eos>", "special": true},
        {"id": 2, "content": "<bos>", "special": true},
        {"id": 3, "content": "<unk>", "special": true}
      ],
      "normalizer": {
        "type": "Sequence",
        "normalizers": [
          {"type": "Replace", "pattern": {"String": " "}, "content": "▁"}
        ]
      },
      "model": {
        "type": "BPE",
        "unk_token": "<unk>",
        "byte_fallback": true,
        "vocab": {
          "<pad>": 0, "<eos>": 1, "<bos>": 2, "<unk>": 3,
          "▁": 4, "a": 5, "c": 6, "t": 7, "▁a": 8, "▁c": 9, "at": 10, "▁cat": 11, "▁ca": 12,
          "<0x21>": 13
        },
        "merges": [
          ["▁", "a"],
          ["▁", "c"],
          ["a", "t"],
          ["▁c", "at"]
        ]
      }
    }
    """

    private func tokenizer() throws -> BPETokenizer {
        try BPETokenizer(data: Data(Self.tokenizerJSON.utf8))
    }

    func testSpecialTokenIdsComeFromTheVocab() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.padId, 0)
        XCTAssertEqual(tokenizer.eosId, 1)
        XCTAssertEqual(tokenizer.bosId, 2)
        XCTAssertEqual(tokenizer.vocabularySize, 14)
    }

    func testMergesApplyInRankOrder() throws {
        let tokenizer = try tokenizer()
        // "▁cat": "▁c" (rank 1) + "at" (rank 2) → "▁cat" (rank 3).
        XCTAssertEqual(tokenizer.tokenize(" cat", lowercase: true), [11])
        XCTAssertEqual(tokenizer.tokenize("a cat", lowercase: true), [5, 11])
    }

    func testLowercasingIsTheCallersChoice() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize(" CAT", lowercase: true), [11])
        // Without lowercasing the uppercase letters fall back to bytes, none of which are in the vocab.
        XCTAssertNotEqual(tokenizer.tokenize(" CAT", lowercase: false), [11])
    }

    func testUnknownBytesFallBackToByteTokens() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize("!", lowercase: true), [13])
    }

    func testEncodeAppendsEosAndPads() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.encode(" cat", length: 4, lowercase: true), [11, 1, 0, 0])
    }

    func testEncodeCutsLongTextKeepingEos() throws {
        let tokenizer = try tokenizer()
        let ids = tokenizer.encode("a cat a cat a cat", length: 3, lowercase: true)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids, [5, 11, 1])
    }

    func testStringMergesAreAccepted() throws {
        var json = Self.tokenizerJSON
        json = json.replacingOccurrences(of: "[\"▁\", \"a\"]", with: "\"▁ a\"")
        let tokenizer = try BPETokenizer(data: Data(json.utf8))
        XCTAssertEqual(tokenizer.tokenize(" a", lowercase: true), [8])
    }

    func testOnlyBPEIsSupported() {
        let json = """
        {"model": {"type": "WordPiece", "vocab": {"<eos>": 1}}}
        """
        XCTAssertThrowsError(try BPETokenizer(data: Data(json.utf8)))
    }
}
