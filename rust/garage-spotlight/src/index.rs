//! Spotlight's index itself, read through the `MDQuery` and `MDItem` calls of CoreServices'
//! Metadata framework, for the `spotlight` source kind.
//!
//! Where the rest of this crate hosts importers to get a file's *text*, this module asks the index
//! which files exist under a folder ([`search`]) and what Spotlight knows *about* each one
//! ([`attributes`]): its display name, type, authors, where it was downloaded from, when it was
//! last opened and how often. The text always comes from the file on disk, through Garage's own
//! readers; the index only names the files and describes them.
//!
//! Personal records never come out of here: an item whose type is a contact, calendar event, mail
//! message, Messages transcript or photo library ([`private_content_type`], which mirrors
//! [`crate::EXCLUDED_IMPORTERS`] and the communications in [`crate::EXCLUDED_TYPES`]) is dropped
//! before the caller sees it, whatever query it ran. Off the Mac, [`search`] fails and
//! [`attributes`] is empty.

use std::path::{Path, PathBuf};

/// The query a Spotlight source runs: every file Spotlight classes as content (documents,
/// pictures, media, ...), never folders, applications or system files. Garage's walk rules then
/// keep what its readers take.
pub const DEFAULT_QUERY: &str = r#"kMDItemContentTypeTree == "public.content""#;

/// Types (and every type below them, as `kMDItemContentTypeTree` lists its ancestors) that are
/// never taken from the index: personal records and communications, which Garage reads only
/// through their own source kinds (Messages, mail) or not at all.
pub const PRIVATE_TYPES: &[&str] = &[
    "public.contact",
    "public.vcard",
    "public.calendar-event",
    "public.to-do-item",
    "public.email-message",
    "com.apple.mail.emlx",
    "com.apple.mail.email",
    "com.apple.ichat.transcript",
    "com.apple.ichat.ichat",
    "com.apple.ical.ics",
    "com.apple.ical.vcs",
    "com.apple.photos.library",
    "com.apple.iphoto.library",
];

/// Type prefixes of the apps whose records are private: Mail, Calendar, Contacts, Photos and iPhoto,
/// Messages, Notes, Reminders (the importers [`crate::EXCLUDED_IMPORTERS`] never loads, and their
/// newer siblings).
pub const PRIVATE_TYPE_PREFIXES: &[&str] = &[
    "com.apple.mail.",
    "com.apple.ical.",
    "com.apple.addressbook.",
    "com.apple.contacts.",
    "com.apple.iphoto.",
    "com.apple.photos.",
    "com.apple.ichat.",
    "com.apple.messages.",
    "com.apple.mobilesms.",
    "com.apple.notes.",
    "com.apple.reminders.",
];

/// The attributes [`attributes`] reads for one file.
pub const ATTRIBUTES: &[&str] = &[
    "kMDItemDisplayName",
    "kMDItemContentType",
    "kMDItemKind",
    "kMDItemTitle",
    "kMDItemAuthors",
    "kMDItemCreator",
    "kMDItemKeywords",
    "kMDItemWhereFroms",
    "kMDItemLastUsedDate",
    "kMDItemUseCount",
    "kMDItemContentCreationDate",
    "kMDItemContentModificationDate",
];

/// One attribute's value, as the index holds it.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    /// A string.
    Text(String),
    /// A list of strings (authors, keywords, where-froms).
    List(Vec<String>),
    /// A number.
    Number(f64),
    /// A date, in seconds since the Unix epoch.
    Date(f64),
    /// A flag.
    Bool(bool),
}

/// One file the index holds under the searched folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexedItem {
    /// `kMDItemPath`.
    pub path: PathBuf,
    /// `kMDItemContentTypeTree`: the file's type and every type it conforms to.
    pub content_types: Vec<String>,
}

/// Whether a file whose type tree is `tree` is a personal record ([`PRIVATE_TYPES`],
/// [`PRIVATE_TYPE_PREFIXES`]), never taken from the index.
#[must_use]
pub fn private_content_type(tree: &[String]) -> bool {
    tree.iter().any(|uti| {
        let uti = uti.to_ascii_lowercase();
        PRIVATE_TYPES.iter().any(|private| uti == *private)
            || PRIVATE_TYPE_PREFIXES.iter().any(|prefix| uti.starts_with(prefix))
    })
}

/// The query string a source runs: [`DEFAULT_QUERY`], narrowed by the source's own predicate
/// when it has one (`kMDItemLastUsedDate >= $time.today(-30)`, say). A narrower query cannot widen
/// what is taken: it is joined to the default with `&&`, and [`search`] drops private types after.
#[must_use]
pub fn query_string(narrowed_by: Option<&str>) -> String {
    match narrowed_by.map(str::trim).filter(|query| !query.is_empty()) {
        Some(query) => format!("({DEFAULT_QUERY}) && ({query})"),
        None => DEFAULT_QUERY.to_owned(),
    }
}

/// The files the index holds below `scope` (a folder) that match `query` (Spotlight's query
/// language, as `mdfind` takes it), by path, with personal records ([`private_content_type`]) and
/// items with no path left out. The query runs synchronously.
///
/// # Errors
///
/// Why the query could not run: not a Mac, a query Spotlight cannot parse, or a refusal from the
/// metadata server.
pub fn search(scope: &Path, query: &str) -> Result<Vec<IndexedItem>, String> {
    #[cfg(target_os = "macos")]
    {
        let mut items = crate::index_macos::search(scope, query)?;
        items.retain(|item| !private_content_type(&item.content_types));
        items.sort_by(|a, b| a.path.cmp(&b.path));
        items.dedup_by(|a, b| a.path == b.path);
        Ok(items)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = query;
        Err(format!("Spotlight is a macOS feature: {} cannot be searched here", scope.display()))
    }
}

/// What the index knows about the file at `path`, for each of [`ATTRIBUTES`] it has a value for.
/// Empty off the Mac, for a file the index does not hold, or for a personal record.
#[must_use]
pub fn attributes(path: &Path) -> Vec<(String, Value)> {
    #[cfg(target_os = "macos")]
    {
        crate::index_macos::attributes(path)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
        Vec::new()
    }
}
