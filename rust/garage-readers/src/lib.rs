//! Garage's file readers in Rust, so the ingest loop reads every file itself (`extract/dispatch.py`'s
//! routing, with a Rust reader behind each route):
//!
//! - Markdown, plain text and source code through [`garage_text`], held to the Python readers, so their
//!   documents (and revisions) do not change;
//! - mail (`.eml`, `.emlx`), PDF and Office (`.docx`, `.pptx`, `.xlsx`) through the FOSS `mail-markdown`,
//!   `pdf-markdown` and `office-markdown` crates, as new readers with their own revisions, so each such
//!   file is read again once;
//! - pictures through [`garage_ocr`]'s engine (Vision on the Mac, Tesseract elsewhere), the policy of
//!   `extract/image.py` kept: an icon is no text, and a picture with too little text is indexed as a
//!   picture when `index_images` is on.
//!
//! [`revision`] names a file's reader and version (`"pdf-markdown:1"`), which GarageService remembers
//! with a no-text or failed outcome, so changing a reader retries what it gave up on. [`shared_names`]
//! reads the names iMessage contacts shared, beside a Messages database (`extract/nicknames.py`).

mod nicknames;

use std::path::Path;
use std::sync::OnceLock;

use garage_ingest::chunking::ContentKind;
use garage_ingest::pipeline::{Extracted, ReadOutcome};
use garage_ocr::{Limits, OcrEngine, Outcome};
use serde_json::{Map, Value, json};

pub use nicknames::shared_names;

/// The image reader's own version, before the engine's revision. Python's reader is at 3.
pub const IMAGE_VERSION: &str = "4";

/// `extract/dispatch.py`'s routes.
const PDF: &[&str] = &[".pdf"];
const DOCX: &[&str] = &[".docx", ".docm"];
const PPTX: &[&str] = &[".pptx", ".pptm"];
const XLSX: &[&str] = &[".xlsx", ".xlsm"];
const EMAIL: &[&str] = &[".eml", ".emlx"];
/// The extensions `extract/image.py` reads.
pub const IMAGE_EXTENSIONS: &[&str] =
    &[".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp", ".gif", ".webp", ".heic", ".heif", ".hif", ".avif"];
const LEGACY_OFFICE: &[&str] = &[".doc", ".ppt", ".xls", ".rtf", ".pages", ".key", ".numbers"];
const UNSUPPORTED_BINARY: &[&str] = &[".msg"];

/// Python's `MAX_OCR_PIXELS`, `MIN_OCR_WIDTH` and `MIN_OCR_HEIGHT`.
const MIN_OCR_WIDTH: u32 = 200;
const MIN_OCR_HEIGHT: u32 = 200;
const MAX_OCR_PIXELS: u64 = 40_000_000;

/// Which reader takes a file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reader {
    /// A garage-text reader.
    Text(garage_text::Kind),
    /// `mail-markdown`.
    Mail,
    /// `pdf-markdown`.
    Pdf,
    /// `office-markdown`, Word.
    Docx,
    /// `office-markdown`, PowerPoint.
    Pptx,
    /// `office-markdown`, Excel.
    Xlsx,
    /// [`garage_ocr`].
    Image,
}

/// The settings the readers take from `garage.json` (`extraction.*`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Settings {
    /// `extraction.max_file_bytes`: larger files fail rather than being read.
    pub max_file_bytes: u64,
    /// `extraction.ocr_min_chars`: less text than this in a picture is no text.
    pub ocr_min_chars: usize,
    /// `extraction.index_images`: a picture without text is indexed as a picture.
    pub index_images: bool,
    /// `extraction.pdf_min_chars_per_page`: below this a PDF is flagged `likely_scanned`.
    pub pdf_min_chars_per_page: usize,
}

impl Default for Settings {
    fn default() -> Self {
        Self { max_file_bytes: 64 * 1024 * 1024, ocr_min_chars: 16, index_images: true, pdf_min_chars_per_page: 32 }
    }
}

impl Settings {
    /// The settings in `object` (`max_file_bytes`, `ocr_min_chars`, `index_images`,
    /// `pdf_min_chars_per_page`); a key that is missing keeps its default.
    #[must_use]
    pub fn from_json(object: Option<&Map<String, Value>>) -> Self {
        let mut settings = Self::default();
        let Some(object) = object else { return settings };
        let count = |name: &str| object.get(name).and_then(Value::as_u64);
        if let Some(value) = count("max_file_bytes") {
            settings.max_file_bytes = value;
        }
        if let Some(value) = count("ocr_min_chars") {
            settings.ocr_min_chars = usize::try_from(value).unwrap_or(usize::MAX);
        }
        if let Some(value) = count("pdf_min_chars_per_page") {
            settings.pdf_min_chars_per_page = usize::try_from(value).unwrap_or(usize::MAX);
        }
        if let Some(value) = object.get("index_images").and_then(Value::as_bool) {
            settings.index_images = value;
        }
        settings
    }
}

/// The file's name and its suffix, lowercased, as `pathlib` splits them (`.bashrc` has no suffix).
fn name_and_suffix(path: &Path) -> (String, String) {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let suffix = garage_text::text::split_extension(&name).1.to_lowercase();
    (name, suffix)
}

/// The file's stem, as `pathlib` gives it.
fn stem(path: &Path) -> String {
    let (name, suffix) = name_and_suffix(path);
    name[..name.len() - suffix.len()].to_owned()
}

/// The reader for `path` (`extractor_for`), or why there is none (`UnsupportedFile`).
///
/// # Errors
///
/// The reason no reader takes the file.
pub fn reader_for(path: &Path) -> Result<Reader, String> {
    let (name, suffix) = name_and_suffix(path);
    let suffix = suffix.as_str();
    if garage_text::MARKDOWN_EXTENSIONS.contains(&suffix) {
        return Ok(Reader::Text(garage_text::Kind::Markdown));
    }
    for (extensions, reader) in [
        (PDF, Reader::Pdf),
        (DOCX, Reader::Docx),
        (PPTX, Reader::Pptx),
        (XLSX, Reader::Xlsx),
        (IMAGE_EXTENSIONS, Reader::Image),
    ] {
        if extensions.contains(&suffix) {
            return Ok(reader);
        }
    }
    if garage_text::CODE_EXTENSIONS.contains(&suffix) {
        return Ok(Reader::Text(garage_text::Kind::Code));
    }
    if garage_text::PLAINTEXT_EXTENSIONS.contains(&suffix) {
        return Ok(Reader::Text(garage_text::Kind::Plaintext));
    }
    if EMAIL.contains(&suffix) {
        return Ok(Reader::Mail);
    }
    if suffix.is_empty() && garage_text::NAMED_CODE_FILES.contains(&name.to_lowercase().as_str()) {
        return Ok(Reader::Text(garage_text::Kind::Code));
    }
    if LEGACY_OFFICE.contains(&suffix) {
        return Err(format!("legacy binary format {suffix} needs LibreOffice conversion: {name}"));
    }
    if UNSUPPORTED_BINARY.contains(&suffix) {
        return Err(format!("binary container {suffix} has no extractor: {name}"));
    }
    let shown = if suffix.is_empty() { name.to_lowercase() } else { suffix.to_owned() };
    Err(format!("no extractor for '{shown}'"))
}

/// The image reader's version: [`IMAGE_VERSION`] and the platform engine's revision, read once.
pub fn image_version() -> &'static str {
    static VERSION: OnceLock<String> = OnceLock::new();
    VERSION.get_or_init(|| match garage_ocr::default_engine() {
        Ok(engine) => format!("{IMAGE_VERSION}+{}", engine.revision()),
        Err(_) => format!("{IMAGE_VERSION}+unavailable"),
    })
}

/// The reader and its version for the file at `path` (`extractor_revision`): `"markdown:1"`,
/// `"pdf-markdown:1"`, `"image:4+..."`; empty when no reader takes it.
pub fn revision(path: &str) -> String {
    let Ok(reader) = reader_for(Path::new(path)) else { return String::new() };
    let (name, version) = match reader {
        Reader::Text(kind) => (kind.name(), garage_text::VERSION.to_owned()),
        Reader::Mail => ("mail-markdown", mail_markdown::VERSION.to_string()),
        Reader::Pdf => ("pdf-markdown", pdf_markdown::VERSION.to_string()),
        Reader::Docx | Reader::Pptx | Reader::Xlsx => ("office-markdown", office_markdown::VERSION.to_string()),
        Reader::Image => ("image", image_version().to_owned()),
    };
    format!("{name}:{version}")
}

/// The readers of one ingest run. A picture's engine is made when the first picture is read and kept
/// for the run: it is not shared between threads (Tesseract loads its model once per engine).
pub struct Readers {
    settings: Settings,
    engine: Option<Result<Box<dyn OcrEngine>, String>>,
}

impl Readers {
    /// Readers with `settings`, on the platform's OCR engine.
    #[must_use]
    pub fn new(settings: Settings) -> Self {
        Self { settings, engine: None }
    }

    /// Readers whose pictures go to `engine` instead of the platform's.
    #[must_use]
    pub fn with_engine(settings: Settings, engine: Box<dyn OcrEngine>) -> Self {
        Self { settings, engine: Some(Ok(engine)) }
    }

    /// The settings.
    #[must_use]
    pub fn settings(&self) -> &Settings {
        &self.settings
    }

    /// Reads the file at `path` (`dispatch.extract`, then `host_read.read_for_host`'s outcomes).
    pub fn read(&mut self, path: &Path) -> ReadOutcome {
        let metadata = match std::fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) => return ReadOutcome::Failed(format!("cannot stat {}: {error}", path.display())),
        };
        // Before the empty-file check: a cloud stub is zero bytes too, and wants downloading.
        if garage_ingest::placeholder::is_placeholder(path, &metadata) {
            return ReadOutcome::Placeholder;
        }
        let size = metadata.len();
        if size == 0 {
            return ReadOutcome::NoText(format!("empty file: {}", path.display()));
        }
        if size > self.settings.max_file_bytes {
            return ReadOutcome::Failed(format!(
                "file exceeds max_file_bytes ({size} > {}): {}",
                self.settings.max_file_bytes,
                path.display()
            ));
        }
        let reader = match reader_for(path) {
            Ok(reader) => reader,
            Err(error) => return ReadOutcome::Failed(error),
        };
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) => {
                // A dataless file the kernel would not download on this thread is still in the cloud.
                if error.raw_os_error().is_some_and(garage_ingest::materialize::refused_dataless_errno) {
                    return ReadOutcome::Placeholder;
                }
                return ReadOutcome::Failed(format!("{}: {error}", path.display()));
            }
        };
        let outcome = match reader {
            Reader::Text(kind) => Ok(text_document(kind, path, &bytes)),
            Reader::Mail => mail_document(path, &bytes),
            Reader::Pdf => pdf_document(path, &bytes, &self.settings),
            Reader::Docx => office_document(path, &bytes, office_markdown::Format::Docx),
            Reader::Pptx => office_document(path, &bytes, office_markdown::Format::Pptx),
            Reader::Xlsx => office_document(path, &bytes, office_markdown::Format::Spreadsheet),
            Reader::Image => return self.image(path, &bytes),
        };
        match outcome {
            Ok(document) if garage_text::text::py_strip(&document.text).is_empty() => {
                ReadOutcome::NoText(format!("extractor {} produced no text: {}", document.extractor, path.display()))
            }
            Ok(document) => ReadOutcome::Document(document),
            Err(error) => ReadOutcome::Failed(error),
        }
    }

    fn engine(&mut self) -> Result<&mut Box<dyn OcrEngine>, String> {
        let engine = self.engine.get_or_insert_with(|| garage_ocr::default_engine().map_err(|error| error.to_string()));
        engine.as_mut().map_err(|error| error.clone())
    }

    /// `extract_image`, on the run's engine.
    fn image(&mut self, path: &Path, bytes: &[u8]) -> ReadOutcome {
        let limits = Limits {
            min_width: MIN_OCR_WIDTH,
            min_height: MIN_OCR_HEIGHT,
            max_pixels: MAX_OCR_PIXELS,
            min_chars: self.settings.ocr_min_chars,
        };
        let index_images = self.settings.index_images;
        let engine = match self.engine() {
            Ok(engine) => engine,
            Err(error) => return ReadOutcome::Failed(format!("no OCR engine: {error}")),
        };
        let name = engine.name().to_owned();
        match garage_ocr::read_image(engine.as_mut(), bytes, &limits) {
            Outcome::Text { text, confidence, width, height } => {
                let text = garage_text::text::normalize(&text);
                if text.chars().count() < limits.min_chars {
                    return picture(
                        path,
                        index_images,
                        &format!("no usable text in image ({} chars)", text.len()),
                        width,
                        height,
                    );
                }
                let mut meta = Map::new();
                meta.insert("ocr_engine".to_owned(), json!(name));
                meta.insert("ocr_confidence".to_owned(), json!((f64::from(confidence) * 100.0).round() / 100.0));
                meta.insert("image".to_owned(), json!({ "width": width, "height": height }));
                ReadOutcome::Document(Extracted {
                    text,
                    kind: ContentKind::Prose,
                    extractor: name,
                    extractor_version: image_version().to_owned(),
                    title: Some(stem(path)),
                    lang: None,
                    meta,
                    author_hints: Vec::new(),
                })
            }
            Outcome::NoText { reason, width, height } => {
                // An icon or spacer is no text, picture or not, as Python raises before indexing it.
                if width < limits.min_width || height < limits.min_height {
                    return ReadOutcome::NoText(format!("{reason}: {}", path.display()));
                }
                picture(path, index_images, &reason, width, height)
            }
            Outcome::Failed(reason) => ReadOutcome::Failed(format!("{reason}: {}", path.display())),
        }
    }
}

/// A picture with no text worth indexing: its name as words (`picture_text`), or no text.
fn picture(path: &Path, index_images: bool, reason: &str, width: u32, height: u32) -> ReadOutcome {
    if !index_images {
        return ReadOutcome::NoText(format!("{reason}: {}", path.display()));
    }
    let stem = stem(path);
    let words: String = stem.split(['_', '-', '.']).filter(|part| !part.is_empty()).collect::<Vec<_>>().join(" ");
    let words = garage_text::text::normalize(&words);
    let mut meta = Map::new();
    meta.insert("image".to_owned(), json!({ "width": width, "height": height }));
    ReadOutcome::Document(Extracted {
        text: if words.is_empty() { stem.clone() } else { words },
        kind: ContentKind::Image,
        extractor: "image".to_owned(),
        extractor_version: image_version().to_owned(),
        title: Some(stem),
        lang: None,
        meta,
        author_hints: Vec::new(),
    })
}

fn content_kind(kind: garage_text::Kind) -> ContentKind {
    match kind {
        garage_text::Kind::Markdown => ContentKind::Markdown,
        garage_text::Kind::Plaintext => ContentKind::Prose,
        garage_text::Kind::Code => ContentKind::Code,
    }
}

fn text_document(kind: garage_text::Kind, path: &Path, bytes: &[u8]) -> Extracted {
    let (name, _) = name_and_suffix(path);
    let read = garage_text::extract(kind, &name, bytes);
    Extracted {
        text: read.text,
        kind: content_kind(read.kind),
        extractor: kind.name().to_owned(),
        extractor_version: garage_text::VERSION.to_owned(),
        title: read.title,
        lang: None,
        meta: read.meta,
        author_hints: read.author_hints,
    }
}

/// Software that writes its own name into author metadata (`base._TOOL_NAME_TOKENS`).
const TOOL_NAME_TOKENS: &[&str] = &[
    "acrobat",
    "microsoft word",
    "microsoft excel",
    "microsoft powerpoint",
    "latex",
    "pdftex",
    "pdflatex",
    "xetex",
    "ghostscript",
    "quartz",
    "openpyxl",
    "python-pptx",
    "python-docx",
    "steve canny",
    "libreoffice",
    "openoffice",
    "pages",
    "keynote",
    "numbers",
    "wkhtmltopdf",
    "reportlab",
    "tcpdf",
    "fpdf",
    "word for",
    "excel for",
    "adobe",
    "indesign",
    "illustrator",
    "photoshop",
    "canva",
    "google docs",
    "unknown",
    "user",
    "admin",
    "administrator",
    "owner",
];

/// `looks_like_tool_name`.
pub fn looks_like_tool_name(value: &str) -> bool {
    let lowered = garage_text::text::py_strip(value).to_lowercase();
    lowered.chars().count() < 3 || TOOL_NAME_TOKENS.iter().any(|token| lowered.contains(token))
}

/// `clean_author_hints`: no tool names, no duplicates (ignoring case), at most 200 characters each.
pub fn clean_author_hints<S: AsRef<str>>(values: &[S]) -> Vec<String> {
    let mut seen = Vec::<String>::new();
    let mut out = Vec::new();
    for value in values {
        let candidate = garage_text::text::py_strip(value.as_ref());
        if candidate.is_empty() || looks_like_tool_name(candidate) {
            continue;
        }
        let key = candidate.to_lowercase();
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        out.push(candidate.chars().take(200).collect());
    }
    out
}

fn truncated(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

fn mail_document(path: &Path, bytes: &[u8]) -> Result<Extracted, String> {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let mail = mail_markdown::convert(bytes).map_err(|_| format!("not an email message: {name}"))?;
    let subject = mail.subject.clone().filter(|subject| !subject.trim().is_empty());
    if mail.body.trim().is_empty() && subject.is_none() {
        return Err(format!("email has neither a subject nor a body: {name}"));
    }
    let joined = |boxes: &[mail_markdown::Mailbox]| {
        boxes.iter().map(mail_markdown::Mailbox::display).collect::<Vec<_>>().join(", ")
    };
    let mut meta = Map::new();
    meta.insert("email_from".to_owned(), json!(joined(&mail.from)));
    meta.insert("email_to".to_owned(), json!(joined(&mail.to)));
    if !mail.cc.is_empty() {
        meta.insert("email_cc".to_owned(), json!(joined(&mail.cc)));
    }
    if let Some(id) = mail.message_id.as_deref().filter(|id| !id.is_empty()) {
        meta.insert("message_id".to_owned(), json!(id));
    }
    if let Some(date) = mail.date_rfc3339.as_deref().or(mail.date.as_deref()) {
        meta.insert("email_date".to_owned(), json!(date));
    }
    if !mail.attachments.is_empty() {
        meta.insert("attachments".to_owned(), json!(mail.attachments));
    }
    if name.to_lowercase().ends_with(".partial.emlx") {
        // Mail keeps only the headers and text of a large message locally.
        meta.insert("partial".to_owned(), json!(true));
    }
    // The senders, unfiltered: tool-name tokens ("user", "admin") are common in real mailbox names.
    let mut hints: Vec<String> = Vec::new();
    for sender in &mail.from {
        if sender.address.contains('@') {
            let hint = sender.display();
            if !hints.contains(&hint) {
                hints.push(hint);
            }
        }
    }
    Ok(Extracted {
        text: garage_text::text::normalize(&mail.markdown),
        // Mail is communication wherever it is found.
        kind: ContentKind::Conversation,
        extractor: "mail-markdown".to_owned(),
        extractor_version: mail_markdown::VERSION.to_string(),
        title: Some(subject.unwrap_or_else(|| stem(path))),
        lang: None,
        meta,
        author_hints: hints,
    })
}

fn pdf_document(path: &Path, bytes: &[u8], settings: &Settings) -> Result<Extracted, String> {
    let options = pdf_markdown::Options { min_chars_per_page: settings.pdf_min_chars_per_page, ..Default::default() };
    let pdf = pdf_markdown::convert_with(bytes, &options).map_err(|error| format!("{error}: {}", path.display()))?;
    let mut meta = Map::new();
    for (key, name) in [
        ("author", "pdf_author"),
        ("title", "pdf_title"),
        ("creator", "pdf_creator"),
        ("producer", "pdf_producer"),
        ("creation_date", "pdf_creation_date"),
    ] {
        if let Some(value) = pdf.metadata.get(key).map(|value| value.trim()).filter(|value| !value.is_empty()) {
            let limit = if key == "creation_date" { 64 } else { 500 };
            meta.insert(name.to_owned(), json!(truncated(value, limit)));
        }
    }
    meta.insert("page_count".to_owned(), json!(pdf.page_count));
    if !pdf.failed_pages.is_empty() {
        meta.insert("failed_pages".to_owned(), json!(pdf.failed_pages.iter().take(50).collect::<Vec<_>>()));
    }
    if pdf.likely_scanned {
        meta.insert("likely_scanned".to_owned(), json!(true));
    }
    let hints: Vec<&String> = pdf.authors.iter().filter(|author| author.trim().chars().count() > 2).collect();
    let title = pdf.title.as_deref().map(str::trim).filter(|title| !title.is_empty()).map(str::to_owned);
    Ok(Extracted {
        text: garage_text::text::normalize(&pdf.markdown),
        kind: ContentKind::Markdown,
        extractor: "pdf-markdown".to_owned(),
        extractor_version: pdf_markdown::VERSION.to_string(),
        title: Some(title.unwrap_or_else(|| stem(path))),
        lang: None,
        meta,
        author_hints: clean_author_hints(&hints),
    })
}

fn office_document(path: &Path, bytes: &[u8], format: office_markdown::Format) -> Result<Extracted, String> {
    let document = office_markdown::convert(bytes, format).map_err(|error| format!("{error}: {}", path.display()))?;
    let mut meta = Map::new();
    let creator = document.metadata.get("creator").map(|value| value.trim()).filter(|value| !value.is_empty());
    if let Some(creator) = creator {
        meta.insert("office_author".to_owned(), json!(truncated(creator, 500)));
    }
    if let Some(last) = document.metadata.get("last_modified_by").map(|value| value.trim())
        && !last.is_empty()
        && Some(last) != creator
    {
        meta.insert("office_last_modified_by".to_owned(), json!(truncated(last, 500)));
    }
    let title = document.title.as_deref().map(str::trim).filter(|title| !title.is_empty()).map(str::to_owned);
    if let Some(title) = &title {
        meta.insert("office_title".to_owned(), json!(truncated(title, 500)));
    }
    if let Some(slides) = document.slide_count {
        meta.insert("slide_count".to_owned(), json!(slides));
    }
    if let Some(sheets) = document.sheet_count {
        meta.insert("sheet_count".to_owned(), json!(sheets));
    }
    if !document.truncated_sheets.is_empty() {
        meta.insert("truncated_sheets".to_owned(), json!(document.truncated_sheets));
    }
    let kind =
        if format == office_markdown::Format::Spreadsheet { ContentKind::Tabular } else { ContentKind::Markdown };
    Ok(Extracted {
        text: garage_text::text::normalize(&document.markdown),
        kind,
        extractor: "office-markdown".to_owned(),
        extractor_version: office_markdown::VERSION.to_string(),
        title: Some(title.unwrap_or_else(|| stem(path))),
        lang: None,
        meta,
        author_hints: clean_author_hints(&document.authors),
    })
}

#[cfg(test)]
mod tests;
