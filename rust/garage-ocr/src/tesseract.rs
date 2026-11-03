//! Tesseract through its C API (`capi.h`), linked at build time.
//!
//! The same calls `garage_rag.extract.tesseract` makes through `_garage_tesseract`: one
//! `TessBaseAPI` per engine, initialized once with the English LSTM model, page segmentation as the
//! CLI's default (`PSM_AUTO`), and the words read back with their confidences. Under Bazel the
//! library is `//ext/tesseract` over `//ext/leptonica`, both static, so nothing is loaded at run
//! time; a Cargo build links what `build.rs` finds.

use std::ffi::{CStr, CString, c_char, c_float, c_int, c_void};
use std::path::Path;
use std::ptr::NonNull;

use image::DynamicImage;

use crate::{OcrEngine, OcrError, Recognized, Span};

/// The language the app bundles (`tessdata_fast`'s `eng`).
pub const DEFAULT_LANGUAGE: &str = "eng";

// TessPageIteratorLevel and TessPageSegMode values from publictypes.h.
const RIL_WORD: c_int = 3;
// The CLI's default. TessBaseAPI's own, PSM_SINGLE_BLOCK, reads a multi-column screenshot as one run.
const PSM_AUTO: c_int = 3;

#[repr(C)]
struct TessBaseApi {
    _private: [u8; 0],
}

#[repr(C)]
struct TessResultIterator {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn TessVersion() -> *const c_char;
    fn TessBaseAPICreate() -> *mut TessBaseApi;
    fn TessBaseAPIDelete(handle: *mut TessBaseApi);
    fn TessBaseAPIInit3(handle: *mut TessBaseApi, datapath: *const c_char, language: *const c_char) -> c_int;
    fn TessBaseAPISetVariable(handle: *mut TessBaseApi, name: *const c_char, value: *const c_char) -> c_int;
    fn TessBaseAPISetPageSegMode(handle: *mut TessBaseApi, mode: c_int);
    fn TessBaseAPISetImage(
        handle: *mut TessBaseApi,
        imagedata: *const u8,
        width: c_int,
        height: c_int,
        bytes_per_pixel: c_int,
        bytes_per_line: c_int,
    );
    fn TessBaseAPIRecognize(handle: *mut TessBaseApi, monitor: *mut c_void) -> c_int;
    fn TessBaseAPIGetIterator(handle: *mut TessBaseApi) -> *mut TessResultIterator;
    fn TessBaseAPIClear(handle: *mut TessBaseApi);
    fn TessResultIteratorDelete(handle: *mut TessResultIterator);
    fn TessResultIteratorNext(handle: *mut TessResultIterator, level: c_int) -> c_int;
    fn TessResultIteratorConfidence(handle: *const TessResultIterator, level: c_int) -> c_float;
    fn TessResultIteratorGetUTF8Text(handle: *const TessResultIterator, level: c_int) -> *mut c_char;
    fn TessDeleteText(text: *const c_char);
}

/// The linked library's version, such as `5.5.1`.
pub fn version() -> String {
    // SAFETY: TessVersion returns a static, NUL-terminated string.
    unsafe { CStr::from_ptr(TessVersion()) }.to_string_lossy().into_owned()
}

/// One initialized `TessBaseAPI`.
pub struct Tesseract {
    api: NonNull<TessBaseApi>,
    language: String,
}

// SAFETY: a TessBaseAPI may move between threads; it is only not safe to share, and `recognize`
// takes `&mut self`.
unsafe impl Send for Tesseract {}

impl Tesseract {
    /// An engine reading `language` with the model data in `datapath` (a `tessdata` folder), or
    /// Tesseract's own default (`TESSDATA_PREFIX`) when `None`.
    ///
    /// # Errors
    ///
    /// [`OcrError::Unavailable`] when the language's data cannot be loaded.
    pub fn new(datapath: Option<&Path>, language: &str) -> Result<Self, OcrError> {
        let to_c =
            |value: &str| CString::new(value).map_err(|_| OcrError::Unavailable(format!("bad argument {value:?}")));
        let datapath_c = datapath.map(|path| to_c(&path.to_string_lossy())).transpose()?;
        let language_c = to_c(language)?;
        // SAFETY: plain constructor.
        let api = NonNull::new(unsafe { TessBaseAPICreate() })
            .ok_or_else(|| OcrError::Unavailable("TessBaseAPICreate failed".to_owned()))?;
        let engine = Self { api, language: language.to_owned() };
        // SAFETY: `api` is live; the strings outlive the call, and Init3 copies them.
        let rc = unsafe {
            TessBaseAPIInit3(
                engine.api.as_ptr(),
                datapath_c.as_ref().map_or(std::ptr::null(), |path| path.as_ptr()),
                language_c.as_ptr(),
            )
        };
        if rc != 0 {
            let place =
                datapath.map_or_else(|| "Tesseract's default tessdata".to_owned(), |path| path.display().to_string());
            return Err(OcrError::Unavailable(format!(
                "tesseract could not load '{language}' language data from {place}"
            )));
        }
        let null_device = if cfg!(windows) { c"NUL" } else { c"/dev/null" };
        // SAFETY: `api` is live and initialized.
        unsafe {
            TessBaseAPISetPageSegMode(engine.api.as_ptr(), PSM_AUTO);
            // tprintf goes to stderr otherwise ("Estimating resolution as ..." per image).
            TessBaseAPISetVariable(engine.api.as_ptr(), c"debug_file".as_ptr(), null_device.as_ptr());
        }
        Ok(engine)
    }

    fn words(&mut self, pixels: &[u8], width: u32, height: u32, channels: u32) -> Result<Vec<Span>, OcrError> {
        let too_large = || OcrError::Failed(format!("image too large ({width}x{height})"));
        let c_width = c_int::try_from(width).map_err(|_| too_large())?;
        let c_height = c_int::try_from(height).map_err(|_| too_large())?;
        let c_channels = c_int::try_from(channels).map_err(|_| too_large())?;
        let stride = c_width.checked_mul(c_channels).ok_or_else(too_large)?;
        let api = self.api.as_ptr();
        // SAFETY: `pixels` holds `height` rows of `stride` bytes and outlives Recognize, which
        // reads it; Clear drops Tesseract's reference before this returns.
        unsafe {
            TessBaseAPISetImage(api, pixels.as_ptr(), c_width, c_height, c_channels, stride);
            if TessBaseAPIRecognize(api, std::ptr::null_mut()) != 0 {
                TessBaseAPIClear(api);
                return Err(OcrError::Failed("tesseract recognition failed".to_owned()));
            }
            let iterator = TessBaseAPIGetIterator(api);
            let mut words = Vec::new();
            if !iterator.is_null() {
                loop {
                    let raw = TessResultIteratorGetUTF8Text(iterator, RIL_WORD);
                    if !raw.is_null() {
                        let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
                        TessDeleteText(raw);
                        words.push(Span { text, confidence: TessResultIteratorConfidence(iterator, RIL_WORD) });
                    }
                    if TessResultIteratorNext(iterator, RIL_WORD) == 0 {
                        break;
                    }
                }
                TessResultIteratorDelete(iterator);
            }
            TessBaseAPIClear(api);
            Ok(words)
        }
    }
}

impl Drop for Tesseract {
    fn drop(&mut self) {
        // SAFETY: created by TessBaseAPICreate and dropped once.
        unsafe { TessBaseAPIDelete(self.api.as_ptr()) }
    }
}

impl OcrEngine for Tesseract {
    #[allow(clippy::unnecessary_literal_bound)] // The trait's name may be the host's, not static.
    fn name(&self) -> &str {
        "tesseract"
    }

    fn revision(&self) -> String {
        format!("tesseract-{}-{}", version(), self.language)
    }

    fn recognize(&mut self, image: &[u8]) -> Result<Recognized, OcrError> {
        let decoded = image::load_from_memory(image).map_err(|error| OcrError::Unreadable(error.to_string()))?;
        // Pillow hands Tesseract L, RGB or RGBA as decoded; match that rather than always widening.
        let (pixels, channels) = match decoded {
            DynamicImage::ImageLuma8(gray) => (gray.into_raw(), 1),
            other if other.color().has_alpha() => (other.into_rgba8().into_raw(), 4),
            other if other.color().has_color() => (other.into_rgb8().into_raw(), 3),
            other => (other.into_luma8().into_raw(), 1),
        };
        let size = imagesize::blob_size(image).map_err(|error| OcrError::Unreadable(error.to_string()))?;
        let width = u32::try_from(size.width).map_err(|_| OcrError::Unreadable("width out of range".to_owned()))?;
        let height = u32::try_from(size.height).map_err(|_| OcrError::Unreadable("height out of range".to_owned()))?;
        let words = self.words(&pixels, width, height, channels)?;
        Ok(Recognized { spans: words, separator: " " })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Limits, Outcome, read_image};

    fn engine() -> Option<Tesseract> {
        match Tesseract::new(None, DEFAULT_LANGUAGE) {
            Ok(engine) => Some(engine),
            Err(error) => {
                eprintln!("skipped: {error}");
                None
            }
        }
    }

    #[test]
    fn reads_a_sentence() {
        let Some(mut engine) = engine() else { return };
        let outcome = read_image(&mut engine, include_bytes!("../testdata/two-lines.png"), &Limits::default());
        let Outcome::Text { text, confidence, .. } = outcome else { panic!("no text: {outcome:?}") };
        assert!(text.contains("Garage reads this sentence."), "{text}");
        assert!(text.contains("4471"), "{text}");
        assert!(confidence > 70.0, "{confidence}");
    }

    #[test]
    fn a_blank_picture_has_no_text() {
        let Some(mut engine) = engine() else { return };
        let outcome = read_image(&mut engine, include_bytes!("../testdata/blank.png"), &Limits::default());
        assert!(matches!(outcome, Outcome::NoText { width: 400, height: 300, .. }), "{outcome:?}");
    }

    #[test]
    fn one_engine_reads_many_pictures() {
        let Some(mut engine) = engine() else { return };
        for _ in 0..3 {
            let recognized = engine.recognize(include_bytes!("../testdata/two-lines.png")).expect("recognize");
            assert!(recognized.text().contains("Garage"));
        }
        assert!(engine.revision().starts_with("tesseract-5."));
    }

    #[test]
    fn garbage_is_unreadable() {
        let Some(mut engine) = engine() else { return };
        assert!(matches!(engine.recognize(b"\x89PNG not really"), Err(OcrError::Unreadable(_))));
    }
}
