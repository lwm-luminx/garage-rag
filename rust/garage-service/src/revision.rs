//! The Python readers' `extractor_revision` (`extract/dispatch.py`), for a caller that names none.
//!
//! A remembered no-text or failed outcome counts only while the reader that produced it is
//! unchanged. The Rust ingest loop names its own reader for each file; a caller that does not (the
//! Python loop, or the Rust loop reading through a Python host) gets the Python readers' routing
//! and versions, as the Python server answered, so the two servers remember and forget the same
//! outcomes while both exist.

use std::path::Path;

const EMAIL: &[&str] = &[".eml", ".emlx"];
const PDF: &[&str] = &[".pdf"];
const DOCX: &[&str] = &[".docx", ".docm"];
const PPTX: &[&str] = &[".pptx", ".pptm"];
const XLSX: &[&str] = &[".xlsx", ".xlsm"];
const IMAGE: &[&str] =
    &[".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp", ".gif", ".webp", ".heic", ".heif", ".hif", ".avif"];

/// Each Python reader module's `VERSION`.
const TEXT_VERSION: &str = "1";
const MAIL_VERSION: &str = "1";
const PDF_VERSION: &str = "1";
const OFFICE_VERSION: &str = "1";
const IMAGE_VERSION: &str = "3";

/// `"pdf:1"`, `"markdown:1"`, ...; empty when no Python reader takes the file.
pub fn python_extractor_revision(uri: &str) -> String {
    let path = Path::new(uri);
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_lowercase();
    let suffix =
        path.extension().and_then(|e| e.to_str()).map(|e| format!(".{}", e.to_lowercase())).unwrap_or_default();
    let has = |set: &[&str]| set.contains(&suffix.as_str());
    let (reader, version) = if has(garage_text::MARKDOWN_EXTENSIONS) {
        ("markdown", TEXT_VERSION)
    } else if has(PDF) {
        ("pdf", PDF_VERSION)
    } else if has(DOCX) {
        ("docx", OFFICE_VERSION)
    } else if has(PPTX) {
        ("pptx", OFFICE_VERSION)
    } else if has(XLSX) {
        ("xlsx", OFFICE_VERSION)
    } else if has(IMAGE) {
        ("image", IMAGE_VERSION)
    } else if has(garage_text::CODE_EXTENSIONS) {
        ("code", TEXT_VERSION)
    } else if has(garage_text::PLAINTEXT_EXTENSIONS) {
        ("plaintext", TEXT_VERSION)
    } else if has(EMAIL) {
        ("email", MAIL_VERSION)
    } else if suffix.is_empty() && garage_text::NAMED_CODE_FILES.contains(&name.as_str()) {
        ("code", TEXT_VERSION)
    } else {
        return String::new();
    };
    format!("{reader}:{version}")
}

#[cfg(test)]
mod tests {
    use super::python_extractor_revision as revision;

    #[test]
    fn files_route_as_the_python_readers_did() {
        assert_eq!(revision("/docs/broken.pdf"), "pdf:1");
        assert_eq!(revision("/notes/a.md"), "markdown:1");
        assert_eq!(revision("/pics/photo.PNG"), "image:3");
        assert_eq!(revision("/src/main.rs"), "code:1");
        assert_eq!(revision("/src/Makefile"), "code:1");
        assert_eq!(revision("/mail/1.emlx"), "email:1");
        assert_eq!(revision("/x/deck.pptm"), "pptx:1");
        assert_eq!(revision("/x/old.doc"), "");
        assert_eq!(revision("/x/noext"), "");
    }
}
