//! Text from files Garage has no reader for, through macOS's own Spotlight importers.
//!
//! Spotlight's importers are CFPlugIn bundles (`.mdimporter`) that implement the `MDImporter`
//! interface of `<CoreServices/Metadata/MDImporter.h>`: given a file, they fill a dictionary of
//! metadata attributes, the text among them (`kMDItemTextContent`). The index keeps that text to
//! itself (`MDItemCopyAttribute` never returns it), so this crate is a small importer host, as
//! `mdimport` is: it loads the importer for a file's type in-process and reads the dictionary it fills.
//!
//! What it loads is deliberately narrow:
//!
//! - only the system's importers, in `/System/Library/Spotlight`: Apple-signed, so library validation
//!   lets a hardened or sandboxed process load them, and well exercised by `mdworker`. A third party's
//!   importer could crash or hang the ingest, and is not loaded;
//! - only for document types ([`EXCLUDED_TYPES`] leaves out pictures, media, archives, applications,
//!   contacts, calendars, messages, plain text and code, which Garage reads itself or not at all, and
//!   HTML and web archives, whose importer needs the main thread's WebKit);
//! - never the importers of personal records ([`EXCLUDED_IMPORTERS`]: Mail, contacts, calendars, photos);
//! - each importer once, the first time a file needs it, and never unloaded.
//!
//! Garage's own readers decide which files come here ([`extensions`] lists what the system can
//! import; `garage-readers` subtracts what it reads itself). On every other platform [`extensions`]
//! is empty and [`import`] imports nothing.
//!
//! [`index`] reads the index itself (`MDQuery`), for the `spotlight` source kind: which files a
//! folder holds and what Spotlight knows about each, never their text.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub mod index;
#[cfg(target_os = "macos")]
mod index_macos;
#[cfg(target_os = "macos")]
mod macos;

/// This crate's own version: change it when what it makes of an importer's attributes changes.
pub const VERSION: &str = "1";

/// Where the system's importers live.
pub const SYSTEM_IMPORTERS: &str = "/System/Library/Spotlight";

/// `kMDImporterTypeID`, the CFPlugIn type an importer's factories make.
pub const MD_IMPORTER_TYPE_ID: &str = "8B08C4BF-415B-11D8-B3F9-0003936726FC";

/// Types whose files never go to an importer, and every type that conforms to one of them.
pub const EXCLUDED_TYPES: &[&str] = &[
    // Read by garage-ocr, or not text.
    "public.image",
    "public.audiovisual-content",
    "public.archive",
    "public.font",
    "public.executable",
    "com.apple.application",
    "com.apple.bundle",
    "com.apple.package",
    "public.folder",
    // Communications and personal records: never through a generic reader.
    "public.contact",
    "public.calendar-event",
    "public.email-message",
    "com.apple.mail.emlx",
    "com.apple.ichat.transcript",
    "com.apple.ichat.ichat",
    // Garage's text readers own text and code, with their own list of extensions.
    "public.plain-text",
    "public.source-code",
    "public.script",
    "public.xml",
    "public.json",
    // The rich-text importer reads these through WebKit, which wants the main thread.
    "public.html",
    "com.apple.webarchive",
];

/// Importers never loaded, by bundle name, whatever types they declare: they read personal records
/// (mail parts, contacts and groups, calendars, photo libraries), which never go through a generic reader.
pub const EXCLUDED_IMPORTERS: &[&str] = &["Mail", "vCard", "iCal", "iPhoto", "iPhoto8"];

/// Whether the importer bundle at `bundle` is one of [`EXCLUDED_IMPORTERS`].
#[must_use]
pub fn excluded_importer(bundle: &Path) -> bool {
    bundle.file_stem().is_some_and(|name| EXCLUDED_IMPORTERS.iter().any(|excluded| name.eq_ignore_ascii_case(excluded)))
}

/// One of the system's importers, as its `Info.plist` describes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Importer {
    /// The `.mdimporter` bundle.
    pub path: PathBuf,
    /// `CFBundleIdentifier` (the bundle's name when it has none).
    pub identifier: String,
    /// `CFBundleVersion`, else `CFBundleShortVersionString`, else empty.
    pub version: String,
    /// The types it imports (`CFBundleDocumentTypes[].LSItemContentTypes`), in its own order.
    pub content_types: Vec<String>,
}

impl Importer {
    /// The importer `bundle`'s `Info.plist` (XML or binary) describes, or none when it is not an
    /// `MDImporter` CFPlugIn (a Spotlight extension, say) or declares no types.
    #[must_use]
    pub fn from_info_plist(bundle: &Path, info: &[u8]) -> Option<Self> {
        let plist = plist::Value::from_reader(std::io::Cursor::new(info)).ok()?;
        let info = plist.as_dictionary()?;
        let is_importer = info
            .get("CFPlugInTypes")
            .and_then(plist::Value::as_dictionary)
            .is_some_and(|types| types.keys().any(|key| key.eq_ignore_ascii_case(MD_IMPORTER_TYPE_ID)));
        if !is_importer {
            return None;
        }
        let text = |key: &str| info.get(key).and_then(plist::Value::as_string).map(str::to_owned);
        let mut content_types = Vec::new();
        for document_type in info.get("CFBundleDocumentTypes").and_then(plist::Value::as_array).into_iter().flatten() {
            let types = document_type
                .as_dictionary()
                .and_then(|document_type| document_type.get("LSItemContentTypes"))
                .and_then(plist::Value::as_array);
            for content_type in types.into_iter().flatten().filter_map(plist::Value::as_string) {
                if !content_types.iter().any(|known: &String| known.eq_ignore_ascii_case(content_type)) {
                    content_types.push(content_type.to_owned());
                }
            }
        }
        if content_types.is_empty() {
            return None;
        }
        let name = bundle.file_stem().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        Some(Self {
            path: bundle.to_owned(),
            identifier: text("CFBundleIdentifier").unwrap_or(name),
            version: text("CFBundleVersion").or_else(|| text("CFBundleShortVersionString")).unwrap_or_default(),
            content_types,
        })
    }
}

/// The importers in `directory` (`*.mdimporter`), by bundle name.
#[must_use]
pub fn importers_in(directory: &Path) -> Vec<Importer> {
    let Ok(entries) = std::fs::read_dir(directory) else { return Vec::new() };
    let mut bundles: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("mdimporter")))
        .collect();
    bundles.sort();
    bundles
        .into_iter()
        .filter_map(|bundle| {
            let info = std::fs::read(bundle.join("Contents/Info.plist")).ok()?;
            Importer::from_info_plist(&bundle, &info)
        })
        .collect()
}

/// What an importer made of a file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    /// `kMDItemTextContent`.
    pub text: String,
    /// `kMDItemTitle`, when it has one.
    pub title: Option<String>,
    /// `kMDItemAuthors`.
    pub authors: Vec<String>,
    /// The file's type (its extension's preferred UTI).
    pub content_type: String,
    /// The importer's `CFBundleIdentifier`.
    pub importer: String,
    /// The importer's version.
    pub importer_version: String,
}

/// The outcome of [`import`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The importer's text.
    Imported(Imported),
    /// The importer read the file and found no text.
    NoText(String),
    /// No system importer takes the file's type (or this is not a Mac).
    NoImporter(String),
    /// The importer could not be loaded, or refused the file.
    Failed(String),
}

/// Whether the system has importers this crate can load: false off the Mac.
pub fn available() -> bool {
    !extensions().is_empty()
}

/// The extensions (lowercased, with the dot: `".rtf"`) of the document types the system's importers
/// take, read once. Empty off the Mac.
pub fn extensions() -> &'static [String] {
    static EXTENSIONS: OnceLock<Vec<String>> = OnceLock::new();
    EXTENSIONS.get_or_init(|| {
        #[cfg(target_os = "macos")]
        {
            macos::extensions()
        }
        #[cfg(not(target_os = "macos"))]
        {
            Vec::new()
        }
    })
}

/// Reads `path` with the system importer for its type.
pub fn import(path: &Path) -> Outcome {
    #[cfg(target_os = "macos")]
    {
        macos::import(path)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Outcome::NoImporter(format!("Spotlight importers are a macOS feature: {}", path.display()))
    }
}

/// [`VERSION`] and the system's build (`"1+25B78"`), which names the importers' versions too: an
/// update of macOS can bring new importers, and a file one gave up on is then tried again.
pub fn revision() -> &'static str {
    static REVISION: OnceLock<String> = OnceLock::new();
    REVISION.get_or_init(|| {
        let build = std::fs::read("/System/Library/CoreServices/SystemVersion.plist")
            .ok()
            .and_then(|bytes| plist::Value::from_reader(std::io::Cursor::new(bytes)).ok())
            .and_then(|plist| plist.as_dictionary()?.get("ProductBuildVersion")?.as_string().map(str::to_owned));
        format!("{VERSION}+{}", build.unwrap_or_else(|| "unavailable".to_owned()))
    })
}

#[cfg(test)]
mod tests;
