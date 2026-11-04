import XCTest
import GarageXPCKit

final class UTF8StreamDecoderTests: XCTestCase {
    /// Every split point of text with 2-, 3- and 4-byte characters decodes to the original text.
    func testAnySplitPointRoundTrips() {
        let text = "a é … 🦆 z"
        let bytes = Data(text.utf8)
        for cut in 0...bytes.count {
            var decoder = UTF8StreamDecoder()
            let joined = decoder.decode(bytes.prefix(cut)) + decoder.decode(bytes.dropFirst(cut)) + decoder.flush()
            XCTAssertEqual(joined, text, "split at byte \(cut)")
        }
    }

    func testAnIncompleteTailIsHeldBack() {
        var decoder = UTF8StreamDecoder()
        let ellipsis = Data("…".utf8)  // E2 80 A6

        XCTAssertEqual(decoder.decode(Data("x".utf8) + ellipsis.prefix(2)), "x")
        XCTAssertEqual(decoder.decode(ellipsis.suffix(1)), "…")
    }

    func testByteAtATime() {
        let text = "naïve 日本 🦆"
        var decoder = UTF8StreamDecoder()
        var out = ""
        for byte in Data(text.utf8) {
            out += decoder.decode(Data([byte]))
        }
        XCTAssertEqual(out + decoder.flush(), text)
    }

    func testMalformedBytesStillDecode() {
        var decoder = UTF8StreamDecoder()
        // Stray continuation bytes are not an incomplete character; they must not be held forever.
        XCTAssertEqual(decoder.decode(Data([0x61, 0x80, 0x80])), "a\u{FFFD}\u{FFFD}")
        XCTAssertEqual(decoder.flush(), "")
    }
}
