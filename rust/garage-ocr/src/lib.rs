//! Text from pictures, behind one trait, so the ingester does not care which engine reads them.
//!
//! [`OcrEngine`] takes a picture's encoded bytes (a file's bytes, as the reader plugins are handed
//! them, never a path) and answers [`Recognized`] text with a confidence per span. The engines:
//!
//! - [`vision::Vision`] (macOS, the `vision` feature): Apple Vision's `VNRecognizeTextRequest`,
//!   in-process, on the Neural Engine. The system framework decodes the picture itself, HEIC included.
//! - [`tesseract::Tesseract`] (the `tesseract` feature): Tesseract's C API, linked at build time
//!   (`//ext/tesseract` statically under Bazel), for the Windows CLI and Linux.
//! - `vision_documents::VisionDocuments` (macOS 26, the `vision-documents` feature): Vision's
//!   Swift-only `RecognizeDocumentsRequest`, called through swift-rs, answering paragraphs and tables.
//! - [`HostEngine`]: recognition the host supplies, such as a vision-language model served by an XPC
//!   service, behind the same trait.
//!
//! [`read_image`] is the reader's policy around any engine, as `garage_rag.extract.image` applies it
//! around Tesseract: pictures too small to hold text and decompression bombs are turned away before
//! the engine runs, and text below a minimum length is "no text", which the caller may index as a
//! picture instead.

#![cfg_attr(not(test), deny(clippy::unwrap_used))]

use std::fmt;

#[cfg(any(test, all(feature = "vision-documents", target_os = "macos")))]
mod document_reply;
#[cfg(feature = "tesseract")]
pub mod tesseract;
#[cfg(all(feature = "vision", target_os = "macos"))]
pub mod vision;
#[cfg(all(feature = "vision-documents", target_os = "macos"))]
pub mod vision_documents;

/// A run of recognized text: a word (Tesseract) or a line (Vision).
#[derive(Clone, Debug, PartialEq)]
pub struct Span {
    /// The text.
    pub text: String,
    /// From 0 to 100. Negative marks a region found but not read (Tesseract's -1).
    pub confidence: f32,
}

/// What an engine read in a picture.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Recognized {
    /// The spans in reading order, as the engine gave them.
    pub spans: Vec<Span>,
    /// How the spans join: `" "` for words, `"\n"` for lines.
    pub separator: &'static str,
}

impl Recognized {
    /// The readable spans: not empty after trimming, and not marked unreadable.
    pub fn readable(&self) -> impl Iterator<Item = &Span> {
        self.spans.iter().filter(|span| span.confidence >= 0.0 && !span.text.trim().is_empty())
    }

    /// The readable spans' text, trimmed and joined by the engine's separator.
    pub fn text(&self) -> String {
        self.readable().map(|span| span.text.trim()).collect::<Vec<_>>().join(self.separator)
    }

    /// The mean confidence of the readable spans, 0 when there are none.
    pub fn mean_confidence(&self) -> f32 {
        let (sum, count) =
            self.readable().fold((0.0_f32, 0_u32), |(sum, count), span| (sum + span.confidence, count + 1));
        if count == 0 {
            0.0
        } else {
            #[allow(clippy::cast_precision_loss)]
            let count = count as f32;
            sum / count
        }
    }
}

/// Why an engine could not read a picture.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OcrError {
    /// The engine cannot run here: its library or model data is missing.
    Unavailable(String),
    /// The bytes are not a picture the engine can decode.
    Unreadable(String),
    /// The engine failed on a picture it could decode.
    Failed(String),
}

impl fmt::Display for OcrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable(message) => write!(f, "OCR unavailable: {message}"),
            Self::Unreadable(message) => write!(f, "unreadable image: {message}"),
            Self::Failed(message) => write!(f, "OCR failed: {message}"),
        }
    }
}

impl std::error::Error for OcrError {}

/// An OCR engine. Not shared between threads: a pool keeps one per worker, as the Python reader
/// keeps one `TessBaseAPI` per thread, so a model loads once per worker.
pub trait OcrEngine: Send {
    /// The engine's name, recorded as the document's `meta.ocr_engine` (`tesseract`, `vision`, ...).
    fn name(&self) -> &str;

    /// What decides the engine's output: its version and model. It belongs in the reader's
    /// `extractor_version`, so a change re-reads every picture (and only then).
    fn revision(&self) -> String;

    /// Read the text in a picture's encoded bytes.
    ///
    /// # Errors
    ///
    /// [`OcrError`] when the engine is unavailable, cannot decode the bytes, or fails.
    fn recognize(&mut self, image: &[u8]) -> Result<Recognized, OcrError>;
}

impl<E: OcrEngine + ?Sized> OcrEngine for Box<E> {
    fn name(&self) -> &str {
        (**self).name()
    }

    fn revision(&self) -> String {
        (**self).revision()
    }

    fn recognize(&mut self, image: &[u8]) -> Result<Recognized, OcrError> {
        (**self).recognize(image)
    }
}

/// Recognition the host supplies: a closure from a picture's bytes to its text. This is the seam for
/// an engine in another process, such as a vision-language model in an XPC service, reached over the
/// host's own transport (the ingest FFI's host callbacks, NSXPC).
pub struct HostEngine<F> {
    name: String,
    revision: String,
    recognize: F,
}

impl<F> HostEngine<F>
where
    F: FnMut(&[u8]) -> Result<Recognized, OcrError> + Send,
{
    /// An engine named `name` whose output `revision` decides, reading through `recognize`.
    pub fn new(name: impl Into<String>, revision: impl Into<String>, recognize: F) -> Self {
        Self { name: name.into(), revision: revision.into(), recognize }
    }
}

impl<F> OcrEngine for HostEngine<F>
where
    F: FnMut(&[u8]) -> Result<Recognized, OcrError> + Send,
{
    fn name(&self) -> &str {
        &self.name
    }

    fn revision(&self) -> String {
        self.revision.clone()
    }

    fn recognize(&mut self, image: &[u8]) -> Result<Recognized, OcrError> {
        (self.recognize)(image)
    }
}

/// The platform's default engine: Vision on macOS, Tesseract elsewhere.
///
/// # Errors
///
/// [`OcrError::Unavailable`] when no engine is built in, or Tesseract cannot load its data.
pub fn default_engine() -> Result<Box<dyn OcrEngine>, OcrError> {
    #[cfg(all(feature = "vision", target_os = "macos"))]
    {
        return Ok(Box::new(vision::Vision::default()));
    }
    #[allow(unreachable_code)]
    {
        #[cfg(feature = "tesseract")]
        {
            return Ok(Box::new(tesseract::Tesseract::new(None, tesseract::DEFAULT_LANGUAGE)?));
        }
        #[allow(unreachable_code)]
        Err(OcrError::Unavailable("garage-ocr was built with no engine".to_owned()))
    }
}

/// The reader's limits (`garage_rag.extract.image`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Narrower than this, a picture is an icon or a spacer, not a document.
    pub min_width: u32,
    /// Shorter than this, likewise.
    pub min_height: u32,
    /// More pixels than this is a decompression bomb or a scan too large to read.
    pub max_pixels: u64,
    /// Less text than this is no text (`ingest.ocr_min_chars`).
    pub min_chars: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self { min_width: 200, min_height: 200, max_pixels: 40_000_000, min_chars: 16 }
    }
}

/// How reading a picture went.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    /// Text worth indexing.
    Text {
        /// The text, not yet normalized (the caller applies `normalize_text`).
        text: String,
        /// The mean confidence, 0 to 100.
        confidence: f32,
        /// The picture's width.
        width: u32,
        /// Its height.
        height: u32,
    },
    /// No usable text: the caller indexes it as a picture (`ingest.index_images`) or rejects it.
    /// `width` and `height` are 0 when the picture was turned away before it was measured.
    NoText {
        /// Why, for the log.
        reason: String,
        /// The picture's width.
        width: u32,
        /// Its height.
        height: u32,
    },
    /// The picture could not be read.
    Failed(String),
}

/// Read a picture with `engine` under `limits`, as `extract_image` does with Tesseract.
pub fn read_image(engine: &mut dyn OcrEngine, image: &[u8], limits: &Limits) -> Outcome {
    let (width, height) = match imagesize::blob_size(image) {
        Ok(size) => (u32::try_from(size.width).unwrap_or(u32::MAX), u32::try_from(size.height).unwrap_or(u32::MAX)),
        Err(error) => return Outcome::Failed(format!("unreadable image: {error}")),
    };
    if u64::from(width) * u64::from(height) > limits.max_pixels {
        return Outcome::Failed(format!("image too large to OCR ({width}x{height})"));
    }
    if width < limits.min_width || height < limits.min_height {
        return Outcome::NoText { reason: format!("image too small to hold text ({width}x{height})"), width, height };
    }
    let recognized = match engine.recognize(image) {
        Ok(recognized) => recognized,
        Err(error) => return Outcome::Failed(format!("{} failed: {error}", engine.name())),
    };
    let text = recognized.text();
    let confidence = recognized.mean_confidence();
    if text.chars().count() < limits.min_chars {
        return Outcome::NoText {
            reason: format!("no usable text in image (confidence {confidence:.0}, {} chars)", text.chars().count()),
            width,
            height,
        };
    }
    Outcome::Text { text, confidence, width, height }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(spans: Vec<Span>) -> impl OcrEngine {
        HostEngine::new("stub", "1", move |_: &[u8]| Ok(Recognized { spans: spans.clone(), separator: " " }))
    }

    fn span(text: &str, confidence: f32) -> Span {
        Span { text: text.to_owned(), confidence }
    }

    const PICTURE: &[u8] = include_bytes!("../testdata/two-lines.png");

    #[test]
    fn unreadable_and_empty_spans_are_dropped() {
        let recognized = Recognized {
            spans: vec![span(" Garage ", 90.0), span("", 80.0), span("~", -1.0), span("reads", 70.0)],
            separator: " ",
        };
        assert_eq!(recognized.text(), "Garage reads");
        assert!((recognized.mean_confidence() - 80.0).abs() < f32::EPSILON);
    }

    #[test]
    fn text_long_enough_is_text() {
        let mut engine = engine(vec![span("Garage reads this sentence.", 91.0)]);
        let outcome = read_image(&mut engine, PICTURE, &Limits::default());
        assert_eq!(
            outcome,
            Outcome::Text { text: "Garage reads this sentence.".to_owned(), confidence: 91.0, width: 900, height: 240 }
        );
    }

    #[test]
    fn short_text_is_no_text() {
        let mut engine = engine(vec![span("OK", 99.0)]);
        assert!(matches!(read_image(&mut engine, PICTURE, &Limits::default()), Outcome::NoText { width: 900, .. }));
    }

    #[test]
    fn icons_never_reach_the_engine() {
        let mut engine = HostEngine::new("stub", "1", |_: &[u8]| -> Result<Recognized, OcrError> {
            panic!("an icon reached the engine")
        });
        let icon = include_bytes!("../testdata/icon.png");
        assert!(matches!(read_image(&mut engine, icon, &Limits::default()), Outcome::NoText { width: 32, .. }));
    }

    #[test]
    fn too_many_pixels_fails() {
        let mut engine = engine(vec![]);
        let limits = Limits { max_pixels: 1000, ..Limits::default() };
        assert!(matches!(read_image(&mut engine, PICTURE, &limits), Outcome::Failed(_)));
    }

    #[test]
    fn garbage_fails() {
        let mut engine = engine(vec![]);
        assert!(matches!(read_image(&mut engine, b"not a picture", &Limits::default()), Outcome::Failed(_)));
    }
}
