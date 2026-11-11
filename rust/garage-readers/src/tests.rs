use std::path::{Path, PathBuf};

use garage_ocr::{HostEngine, OcrError, Recognized, Span};

use super::*;

/// The tests' fixtures: the PDF and Office files are the `pdf-markdown` and `office-markdown` crates'
/// own, the picture `garage-ocr`'s (900x240). They are compiled in, as `garage-ocr`'s are: Bazel's test
/// runs where `CARGO_MANIFEST_DIR` (the compile sandbox) no longer exists.
fn fixture(name: &str) -> Vec<u8> {
    let bytes: &[u8] = match name {
        "blank.pdf" => include_bytes!("../testdata/blank.pdf"),
        "counts.xlsx" => include_bytes!("../testdata/counts.xlsx"),
        "minutes.docx" => include_bytes!("../testdata/minutes.docx"),
        "report.pdf" => include_bytes!("../testdata/report.pdf"),
        "review.pptx" => include_bytes!("../testdata/review.pptx"),
        "two-lines.png" => include_bytes!("../testdata/two-lines.png"),
        other => panic!("no fixture {other}"),
    };
    bytes.to_vec()
}

/// A fresh folder for one test.
fn folder(name: &str) -> PathBuf {
    let folder = std::env::temp_dir().join(format!("garage-readers-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    folder
}

fn write(folder: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let path = folder.join(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

fn document(outcome: ReadOutcome) -> Extracted {
    match outcome {
        ReadOutcome::Document(document) => document,
        other => panic!("not a document: {other:?}"),
    }
}

/// An engine that reads `text` in every picture.
fn engine(text: &'static str) -> Box<dyn OcrEngine> {
    Box::new(HostEngine::new("stub", "1", move |_: &[u8]| {
        Ok::<_, OcrError>(Recognized {
            spans: vec![Span { text: text.to_owned(), confidence: 87.456 }],
            separator: " ",
        })
    }))
}

#[test]
fn routes_follow_dispatch() {
    let route = |name: &str| reader_for(Path::new(name));
    assert_eq!(route("notes.md"), Ok(Reader::Text(garage_text::Kind::Markdown)));
    assert_eq!(route("main.RS"), Ok(Reader::Text(garage_text::Kind::Code)));
    assert_eq!(route("Makefile"), Ok(Reader::Text(garage_text::Kind::Code)));
    assert_eq!(route("readme.txt"), Ok(Reader::Text(garage_text::Kind::Plaintext)));
    assert_eq!(route("a.eml"), Ok(Reader::Mail));
    assert_eq!(route("1234.partial.emlx"), Ok(Reader::Mail));
    assert_eq!(route("a.PDF"), Ok(Reader::Pdf));
    assert_eq!(route("a.docm"), Ok(Reader::Docx));
    assert_eq!(route("a.pptx"), Ok(Reader::Pptx));
    assert_eq!(route("a.xlsm"), Ok(Reader::Xlsx));
    assert_eq!(route("a.HEIC"), Ok(Reader::Image));
    // A legacy format goes to the Mac's Spotlight importer when one takes it.
    if spotlight_extensions().iter().any(|extension| extension == ".doc") {
        assert_eq!(route("a.doc"), Ok(Reader::Spotlight));
    } else {
        assert_eq!(route("a.doc"), Err("legacy binary format .doc needs LibreOffice conversion: a.doc".to_owned()));
    }
    assert_eq!(route("a.msg"), Err("binary container .msg has no extractor: a.msg".to_owned()));
    assert_eq!(route("a.bin"), Err("no extractor for '.bin'".to_owned()));
    assert_eq!(route("LICENSE"), Err("no extractor for 'license'".to_owned()));
}

#[test]
fn revisions_name_reader_and_version() {
    assert_eq!(revision("/x/notes.md"), "markdown:1");
    assert_eq!(revision("/x/main.py"), "code:1");
    assert_eq!(revision("/x/a.txt"), "plaintext:1");
    assert_eq!(revision("/x/a.eml"), format!("mail-markdown:{}", mail_markdown::VERSION));
    assert_eq!(revision("/x/a.pdf"), format!("pdf-markdown:{}", pdf_markdown::VERSION));
    assert_eq!(revision("/x/a.xlsx"), format!("office-markdown:{}", office_markdown::VERSION));
    assert!(revision("/x/a.png").starts_with("image:4+"));
    if spotlight_extensions().iter().any(|extension| extension == ".doc") {
        assert_eq!(revision("/x/a.doc"), format!("spotlight:{}", garage_spotlight::revision()));
    } else {
        assert_eq!(revision("/x/a.doc"), "");
    }
}

#[test]
fn spotlight_takes_only_what_no_built_in_reader_does() {
    for extension in spotlight_extensions() {
        assert_eq!(reader_for(Path::new(&format!("file{extension}"))), Ok(Reader::Spotlight), "{extension}");
        for built_in in [".md", ".txt", ".rs", ".pdf", ".docx", ".pptx", ".xlsx", ".eml", ".png", ".html"] {
            assert_ne!(extension, built_in);
        }
    }
    #[cfg(not(target_os = "macos"))]
    assert!(spotlight_extensions().is_empty());
}

#[test]
fn settings_from_json_keep_defaults() {
    let object = json!({ "ocr_min_chars": 4, "index_images": false });
    let settings = Settings::from_json(object.as_object());
    assert_eq!(settings, Settings { ocr_min_chars: 4, index_images: false, ..Settings::default() });
    assert_eq!(Settings::from_json(None), Settings::default());
    assert!(Settings::default().spotlight);
    let off = json!({ "spotlight": false });
    assert!(!Settings::from_json(off.as_object()).spotlight);
}

#[test]
fn empty_large_and_unsupported_files() {
    let folder = folder("limits");
    let mut readers = Readers::new(Settings { max_file_bytes: 8, ..Settings::default() });
    assert!(
        matches!(readers.read(&write(&folder, "empty.md", b"")), ReadOutcome::NoText(reason) if reason.starts_with("empty file"))
    );
    assert!(
        matches!(readers.read(&write(&folder, "big.md", b"# more than eight")), ReadOutcome::Failed(reason) if reason.contains("max_file_bytes"))
    );
    // With Spotlight's importers off (or off the Mac), a legacy format needs LibreOffice.
    let mut legacy = Readers::new(Settings { spotlight: false, ..Settings::default() });
    if spotlight_extensions().is_empty() {
        assert!(
            matches!(legacy.read(&write(&folder, "old.doc", b"x")), ReadOutcome::Failed(reason) if reason.contains("LibreOffice"))
        );
    } else {
        assert!(
            matches!(legacy.read(&write(&folder, "old.doc", b"x")), ReadOutcome::Failed(reason) if reason.contains("extraction.spotlight"))
        );
    }
    assert!(
        matches!(readers.read(&write(&folder, "blank.md", b"  \n")), ReadOutcome::NoText(reason) if reason.contains("produced no text"))
    );
    assert!(
        matches!(readers.read(&folder.join("missing.md")), ReadOutcome::Failed(reason) if reason.starts_with("cannot stat"))
    );
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn text_is_garage_text() {
    let folder = folder("text");
    let mut readers = Readers::new(Settings::default());
    let read = document(readers.read(&write(&folder, "notes.md", b"# Orchard\n\nPears and apples.\n")));
    let expected = garage_text::extract(garage_text::Kind::Markdown, "notes.md", b"# Orchard\n\nPears and apples.\n");
    assert_eq!(read.text, expected.text);
    assert_eq!(read.title, expected.title);
    assert_eq!(
        (read.kind, read.extractor.as_str(), read.extractor_version.as_str()),
        (ContentKind::Markdown, "markdown", "1")
    );
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn mail_is_a_conversation() {
    let folder = folder("mail");
    let message = b"From: Nell Oduya <nell@example.com>\r\nTo: Tomas Brandt <tomas@example.com>, ana@example.com\r\n\
Cc: admin@example.com\r\nSubject: Pear harvest\r\nMessage-ID: <1@example.com>\r\n\
Date: Tue, 3 Nov 2026 10:00:00 +0000\r\nContent-Type: text/plain\r\n\r\nThe north slope is ready.\r\n";
    let mut readers = Readers::new(Settings::default());
    let read = document(readers.read(&write(&folder, "harvest.eml", message)));
    assert_eq!(read.kind, ContentKind::Conversation);
    assert_eq!(read.extractor, "mail-markdown");
    assert_eq!(read.title.as_deref(), Some("Pear harvest"));
    assert!(read.text.contains("The north slope is ready."), "{}", read.text);
    assert_eq!(read.meta["email_from"], json!("Nell Oduya <nell@example.com>"));
    assert!(read.meta["email_to"].as_str().unwrap().contains("ana@example.com"));
    assert!(read.meta.contains_key("email_cc"));
    assert!(read.meta.contains_key("message_id"));
    assert!(read.meta.contains_key("email_date"));
    assert!(!read.meta.contains_key("partial"));
    assert_eq!(read.author_hints, ["Nell Oduya <nell@example.com>"]);

    let partial = document(readers.read(&write(&folder, "7.partial.emlx", &[b"200\n".as_slice(), message].concat())));
    assert_eq!(partial.meta["partial"], json!(true));
    assert!(matches!(readers.read(&write(&folder, "nothing.eml", b"X-Header: 1\r\n\r\n")), ReadOutcome::Failed(_)));
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn pdf_is_markdown_with_its_metadata() {
    let folder = folder("pdf");
    let mut readers = Readers::new(Settings::default());
    let read = document(readers.read(&write(&folder, "report.pdf", &fixture("report.pdf"))));
    assert_eq!(read.kind, ContentKind::Markdown);
    assert_eq!(read.extractor, "pdf-markdown");
    assert_eq!(read.title.as_deref(), Some("The Ashvale Orchard Survey"));
    assert!(read.text.starts_with("# The Ashvale Orchard Survey"), "{}", read.text);
    assert_eq!(read.meta["page_count"], json!(3));
    assert!(read.meta["pdf_producer"].as_str().unwrap().contains("ReportLab"));
    assert_eq!(read.author_hints, ["Nell Oduya", "Tomas Brandt"]);
    assert!(!matches!(readers.read(&write(&folder, "blank.pdf", &fixture("blank.pdf"))), ReadOutcome::Document(_)));
    assert!(matches!(readers.read(&write(&folder, "broken.pdf", b"not a pdf")), ReadOutcome::Failed(_)));
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn office_documents() {
    let folder = folder("office");
    let mut readers = Readers::new(Settings::default());
    let minutes = document(readers.read(&write(&folder, "minutes.docx", &fixture("minutes.docx"))));
    assert_eq!((minutes.kind, minutes.extractor.as_str()), (ContentKind::Markdown, "office-markdown"));
    assert_eq!(minutes.title.as_deref(), Some("Orchard Minutes"));
    assert_eq!(minutes.meta["office_title"], json!("Orchard Minutes"));
    assert_eq!(minutes.author_hints, ["Nell Oduya", "Tomas Brandt"]);

    let review = document(readers.read(&write(&folder, "review.pptx", &fixture("review.pptx"))));
    assert_eq!(review.meta["slide_count"], json!(4));

    let counts = document(readers.read(&write(&folder, "counts.xlsx", &fixture("counts.xlsx"))));
    assert_eq!(counts.kind, ContentKind::Tabular);
    assert_eq!(counts.meta["sheet_count"], json!(2));
    assert!(counts.text.contains("| 0 | tree 0 |"), "{}", counts.text);

    assert!(matches!(readers.read(&write(&folder, "broken.docx", b"not a zip")), ReadOutcome::Failed(_)));
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn pictures_with_text_and_without() {
    let folder = folder("image");
    let picture = fixture("two-lines.png");
    let path = write(&folder, "orchard_map-2026.png", &picture);

    let mut readers = Readers::with_engine(Settings::default(), engine("The north slope holds the pears."));
    let read = document(readers.read(&path));
    assert_eq!((read.kind, read.extractor.as_str()), (ContentKind::Prose, "stub"));
    assert_eq!(read.text, "The north slope holds the pears.");
    assert_eq!(read.title.as_deref(), Some("orchard_map-2026"));
    assert_eq!(read.meta["ocr_engine"], json!("stub"));
    assert_eq!(read.meta["ocr_confidence"], json!(87.46));
    assert_eq!(read.meta["image"], json!({ "width": 900, "height": 240 }));
    assert_eq!(read.extractor_version, image_version());

    // Too little text: a picture, named by its file.
    let mut readers = Readers::with_engine(Settings::default(), engine("OK"));
    let read = document(readers.read(&path));
    assert_eq!((read.kind, read.extractor.as_str()), (ContentKind::Image, "image"));
    assert_eq!(read.text, "orchard map 2026");

    // With index_images off, no text.
    let mut readers = Readers::with_engine(Settings { index_images: false, ..Settings::default() }, engine("OK"));
    assert!(matches!(readers.read(&path), ReadOutcome::NoText(_)));

    // An unreadable picture fails.
    let mut readers = Readers::with_engine(Settings::default(), engine("ignored"));
    assert!(matches!(readers.read(&write(&folder, "broken.png", b"not a picture")), ReadOutcome::Failed(_)));
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn author_hints_drop_tool_names_and_duplicates() {
    assert!(looks_like_tool_name("Microsoft Word"));
    assert!(looks_like_tool_name("ab"));
    assert!(!looks_like_tool_name("Nell Oduya"));
    assert_eq!(
        clean_author_hints(&["Nell Oduya", " nell oduya ", "python-docx", "", "Tomas Brandt"]),
        ["Nell Oduya", "Tomas Brandt"]
    );
}
