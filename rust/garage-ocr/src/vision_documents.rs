//! Vision's document reader (`RecognizeDocumentsRequest`, macOS 26), reached through Swift.
//!
//! The request is Swift-only, so neither objc2-vision nor any C header reaches it. Its Swift half
//! (`swift/Sources/GarageOCRDocuments`) exports `garage_ocr_recognize_document` with `@_cdecl`, and
//! [swift-rs](https://github.com/Brendonovich/swift-rs) declares it here with `swift!`, which keeps
//! the retain counts of the `SRData` going in and the `SRString` coming back balanced. A Cargo build
//! links the Swift package through swift-rs's `SwiftLinker` (`build.rs`); a Bazel build links
//! `//rust/garage-ocr:GarageOCRDocuments`.
//!
//! Unlike [`crate::vision::Vision`], which answers lines, this answers a document's paragraphs and
//! its tables, the tables as Markdown, so a scanned form or a receipt keeps its rows.

use swift_rs::{SRData, SRString, swift};

use crate::document_reply::parse;
use crate::{OcrEngine, OcrError, Recognized};

swift!(fn garage_ocr_recognize_document(image: &SRData) -> Option<SRString>);

/// `RecognizeDocumentsRequest`: paragraphs, then each table as Markdown.
#[derive(Clone, Copy, Debug, Default)]
pub struct VisionDocuments;

impl OcrEngine for VisionDocuments {
    #[allow(clippy::unnecessary_literal_bound)] // The trait's name may be the host's, not static.
    fn name(&self) -> &str {
        "vision-documents"
    }

    /// The request has no revision of its own yet; the reply's shape is ours.
    fn revision(&self) -> String {
        "vision-documents-1".to_owned()
    }

    fn recognize(&mut self, image: &[u8]) -> Result<Recognized, OcrError> {
        let data = SRData::from(image);
        // SAFETY: the Swift function takes an SRData and returns an SRString or nil, as declared.
        let Some(reply) = (unsafe { garage_ocr_recognize_document(&data) }) else {
            return Err(OcrError::Unavailable(
                "RecognizeDocumentsRequest needs macOS 26, or it failed on this picture".to_owned(),
            ));
        };
        parse(reply.as_str())
    }
}
