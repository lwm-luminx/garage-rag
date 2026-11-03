// Vision's document reader (RecognizeDocumentsRequest, macOS 26), for Rust.
//
// The request is Swift-only: it has no Objective-C counterpart, so objc2-vision cannot reach it.
// This file exports one C entry point through swift-rs, which garage-ocr's `vision_documents`
// module declares with `swift!`. Paragraphs and tables come back as JSON; the Rust side turns them
// into text.

import Foundation
import SwiftRs
import Vision

/// The reply, as JSON: {"confidence": 0...1, "paragraphs": [String], "tables": [[[String]]]}.
private struct DocumentReply: Encodable {
    var confidence: Float
    var paragraphs: [String]
    var tables: [[[String]]]
}

/// Carries a result out of the task the request runs in.
private final class ReplyBox: @unchecked Sendable {
    var json: String?
}

/// Reads the document in an encoded picture (any format ImageIO decodes). Returns nil when the
/// request is unavailable (before macOS 26) or fails, and "{}"-shaped JSON with no paragraphs when
/// the picture holds no document.
@_cdecl("garage_ocr_recognize_document")
public func garageOCRRecognizeDocument(image: SRData) -> SRString? {
    #if compiler(>=6.2)  // The macOS 26 SDK (Xcode 26); an older SDK has no RecognizeDocumentsRequest.
    guard #available(macOS 26.0, *) else { return nil }
    let bytes = Data(image.toArray())
    let box = ReplyBox()
    let done = DispatchSemaphore(value: 0)
    // The request is async; the C ABI is not. The calling thread is a worker of the ingester's
    // own pool, never the main thread, so waiting here blocks nothing Swift needs.
    Task.detached {
        defer { done.signal() }
        box.json = try? await recognize(bytes)
    }
    done.wait()
    return box.json.map { SRString($0) }
    #else
    return nil
    #endif
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private func recognize(_ bytes: Data) async throws -> String {
    let request = RecognizeDocumentsRequest()
    let observations = try await request.perform(on: bytes)
    var reply = DocumentReply(confidence: 0, paragraphs: [], tables: [])
    if let observation = observations.first {
        let document = observation.document
        reply.confidence = observation.confidence
        reply.paragraphs = document.paragraphs.map { $0.transcript }
        reply.tables = document.tables.map { table in
            table.rows.map { row in row.map { $0.content.text.transcript } }
        }
    }
    let data = try JSONEncoder().encode(reply)
    return String(decoding: data, as: UTF8.self)
}
#endif
