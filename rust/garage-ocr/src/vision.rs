//! Apple Vision's `VNRecognizeTextRequest`, in-process.
//!
//! Vision is a system framework, linked at build time like Foundation: nothing is bundled and nothing
//! is loaded by name at run time. It decodes the picture itself (through ImageIO, so HEIC needs no
//! decoder of ours), runs on the Neural Engine, and reads Latin, Cyrillic, CJK, Arabic and Thai
//! scripts. Results come back a line at a time, each with a confidence from 0 to 1.
//!
//! The engine holds only its settings: the Objective-C objects live for one call, inside an
//! autorelease pool, so the engine is `Send` and memory does not build up over a long run.

use objc2::AllocAnyThread;
use objc2::rc::autoreleasepool;
use objc2_foundation::{NSArray, NSData, NSDictionary, NSString};
use objc2_vision::{VNImageRequestHandler, VNRecognizeTextRequest, VNRequest, VNRequestTextRecognitionLevel};

use crate::{OcrEngine, OcrError, Recognized, Span};

/// How hard Vision looks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    /// The neural recognizer, with language correction: slower, and what the ingester uses.
    Accurate,
    /// The character-by-character recognizer: for a quick look, not for the index.
    Fast,
}

/// Vision text recognition.
#[derive(Clone, Debug)]
pub struct Vision {
    level: Level,
    languages: Vec<String>,
    language_correction: bool,
}

impl Default for Vision {
    /// Accurate, with language correction, detecting the language itself.
    fn default() -> Self {
        Self { level: Level::Accurate, languages: Vec::new(), language_correction: true }
    }
}

impl Vision {
    /// The fast recognizer, without language correction.
    pub fn fast() -> Self {
        Self { level: Level::Fast, languages: Vec::new(), language_correction: false }
    }

    /// Prefer these languages (BCP 47, such as `en-US`, `fr-FR`, `zh-Hans`), in order, instead of
    /// detecting the language.
    #[must_use]
    pub fn with_languages(mut self, languages: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.languages = languages.into_iter().map(Into::into).collect();
        self
    }

    fn request(&self) -> objc2::rc::Retained<VNRecognizeTextRequest> {
        let request = VNRecognizeTextRequest::new();
        request.setRecognitionLevel(match self.level {
            Level::Accurate => VNRequestTextRecognitionLevel::Accurate,
            Level::Fast => VNRequestTextRecognitionLevel::Fast,
        });
        request.setUsesLanguageCorrection(self.language_correction);
        if self.languages.is_empty() {
            request.setAutomaticallyDetectsLanguage(true);
        } else {
            let languages: Vec<_> = self.languages.iter().map(|language| NSString::from_str(language)).collect();
            request.setRecognitionLanguages(&NSArray::from_retained_slice(&languages));
        }
        request
    }
}

impl OcrEngine for Vision {
    #[allow(clippy::unnecessary_literal_bound)] // The trait's name may be the host's, not static.
    fn name(&self) -> &str {
        "vision"
    }

    /// The request's revision, which Apple bumps when the model changes in a way it documents. A
    /// macOS update can still change the output within a revision; that does not re-read the corpus.
    fn revision(&self) -> String {
        let revision = autoreleasepool(|_| {
            // SAFETY: a property read on a fresh request.
            unsafe { self.request().revision() }
        });
        let level = match self.level {
            Level::Accurate => "accurate",
            Level::Fast => "fast",
        };
        format!("vision-r{revision}-{level}")
    }

    fn recognize(&mut self, image: &[u8]) -> Result<Recognized, OcrError> {
        autoreleasepool(|_| {
            let data = NSData::with_bytes(image);
            let handler = VNImageRequestHandler::initWithData_options(
                VNImageRequestHandler::alloc(),
                &data,
                &NSDictionary::new(),
            );
            let request = self.request();
            let as_request: &VNRequest = &request;
            handler.performRequests_error(&NSArray::from_slice(&[as_request])).map_err(|error| {
                // Vision reports a picture it cannot decode and a failed request alike; ImageIO's
                // decoding failures carry no code of their own here.
                OcrError::Failed(error.localizedDescription().to_string())
            })?;
            let mut spans = Vec::new();
            for observation in request.results().iter().flat_map(|results| results.iter()) {
                let candidates = observation.topCandidates(1);
                if let Some(best) = candidates.firstObject() {
                    spans.push(Span { text: best.string().to_string(), confidence: best.confidence() * 100.0 });
                }
            }
            Ok(Recognized { spans, separator: "\n" })
        })
    }
}
