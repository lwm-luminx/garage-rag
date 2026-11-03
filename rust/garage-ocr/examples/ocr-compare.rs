//! Runs every OCR engine built in over the same pictures and prints one row per picture and engine,
//! for a bake-off on a real corpus:
//!
//! ```sh
//! cargo run --release -p garage-ocr --example ocr-compare -- ~/Pictures/Screenshots ~/Documents/scans
//! cargo run --release -p garage-ocr --example ocr-compare -- --out /tmp/ocr ~/Pictures/Screenshots
//! ```
//!
//! Columns: file, engine, outcome, milliseconds, mean confidence, characters, and the text's start.
//! With `--out DIR` each engine's full text is also written to `DIR/<engine>/<file>.txt`, so two
//! engines can be diffed. Nothing leaves the machine.

use std::path::{Path, PathBuf};
use std::time::Instant;

use garage_ocr::{Limits, OcrEngine, Outcome, read_image};

const EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"];

fn engines() -> Vec<Box<dyn OcrEngine>> {
    let mut engines: Vec<Box<dyn OcrEngine>> = Vec::new();
    #[cfg(target_os = "macos")]
    {
        engines.push(Box::new(garage_ocr::vision::Vision::default()));
        engines.push(Box::new(garage_ocr::vision::Vision::fast()));
    }
    match garage_ocr::tesseract::Tesseract::new(
        std::env::var_os("TESSDATA").map(PathBuf::from).as_deref(),
        garage_ocr::tesseract::DEFAULT_LANGUAGE,
    ) {
        Ok(engine) => engines.push(Box::new(engine)),
        Err(error) => eprintln!("tesseract skipped: {error}"),
    }
    engines
}

fn pictures(path: &Path, into: &mut Vec<PathBuf>) {
    if path.is_dir() {
        let Ok(entries) = std::fs::read_dir(path) else { return };
        let mut children: Vec<PathBuf> = entries.filter_map(|entry| entry.ok().map(|entry| entry.path())).collect();
        children.sort();
        for child in children {
            pictures(&child, into);
        }
    } else if path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str()))
    {
        into.push(path.to_owned());
    }
}

fn main() {
    let mut args = std::env::args().skip(1).peekable();
    let mut out: Option<PathBuf> = None;
    let mut files = Vec::new();
    while let Some(arg) = args.next() {
        if arg == "--out" {
            out = args.next().map(PathBuf::from);
        } else {
            pictures(Path::new(&arg), &mut files);
        }
    }
    if files.is_empty() {
        eprintln!("usage: ocr-compare [--out DIR] PICTURE_OR_FOLDER...");
        std::process::exit(2);
    }
    let mut engines = engines();
    let limits = Limits::default();
    println!("file\tengine\toutcome\tms\tconfidence\tchars\tstart");
    for file in &files {
        let Ok(bytes) = std::fs::read(file) else {
            eprintln!("unreadable: {}", file.display());
            continue;
        };
        for engine in &mut engines {
            let label = format!("{}:{}", engine.name(), engine.revision());
            let started = Instant::now();
            let outcome = read_image(engine.as_mut(), &bytes, &limits);
            let ms = started.elapsed().as_millis();
            let (kind, confidence, text) = match &outcome {
                Outcome::Text { text, confidence, .. } => ("text", *confidence, text.clone()),
                Outcome::NoText { reason, .. } => ("no_text", 0.0, reason.clone()),
                Outcome::Failed(error) => ("failed", 0.0, error.clone()),
            };
            let start: String = text.chars().take(60).map(|c| if c.is_whitespace() { ' ' } else { c }).collect();
            println!("{}\t{label}\t{kind}\t{ms}\t{confidence:.1}\t{}\t{start}", file.display(), text.chars().count());
            if let (Some(out), Outcome::Text { text, .. }) = (&out, &outcome) {
                let dir = out.join(label.replace([':', '/'], "_"));
                let name = file.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
                if std::fs::create_dir_all(&dir).is_ok() {
                    let _ = std::fs::write(dir.join(format!("{name}.txt")), text);
                }
            }
        }
    }
}
