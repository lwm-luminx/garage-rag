//! A Google Drive source read through the Drive API (`/drive/v3/files`), not through a synced folder:
//! the folder's tree is listed folder by folder, the files the walker's rules keep are compared with
//! the database by their stat, and only a new or changed file is downloaded, into memory, and handed
//! to the readers. Google's own documents have no bytes of their own, so they are exported: a Doc as
//! `.docx`, a Sheet as `.xlsx` and a Slides deck as `.pptx`, which the Office reader reads; other
//! Google types (Forms, Drawings, shortcuts, sites) are passed over.
//!
//! Nothing here opens a connection or holds a credential: [`crate::onedrive`]'s client carries each
//! request through the [`RemoteHost`] after [`check_destination`] approved it, and asks the host for
//! the token with `"service": "google_drive"` (the store build's node links its Google account through
//! Garage Door, which redeems Google's code, seals the tokens to the node and keeps none). A request
//! carries folder and file ids, never a document's text: content only comes in.
//!
//! A file's URI is `google_drive:` and its id, since Drive allows two files of one name in a folder
//! and a file in more than one folder: a renamed or moved file keeps its document.

use std::collections::VecDeque;
use std::ops::ControlFlow;
use std::path::PathBuf;

use serde_json::{Map, Value, json};

use crate::dropbox::{RemoteHost, display_root, keep, parse_timestamp};
use crate::onedrive::{ApiError, Client, DOWNLOAD_TIMEOUT, descend, encode_path};
use crate::pipeline::{Context, FileCandidate, FileHost, IngestSettings, ReadOutcome, ingest_one};
use crate::sha256;
use crate::source::{ScanSummary, SourceError, SourceOptions, SourceRun, SourceStorage};
use crate::walk::WalkStats;

/// The Drive API's files collection.
pub const FILES: &str = "https://www.googleapis.com/drive/v3/files";
/// The source kind in `sources.kind`.
pub const KIND: &str = "google_drive";
/// The URI scheme of a Drive file's document.
pub const URI_PREFIX: &str = "google_drive:";
/// A folder's MIME type.
const FOLDER: &str = "application/vnd.google-apps.folder";
/// Google's own types and what each is exported as: (type, export MIME type, extension).
const EXPORTS: &[(&str, &str, &str)] = &[
    (
        "application/vnd.google-apps.document",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".docx",
    ),
    (
        "application/vnd.google-apps.spreadsheet",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".xlsx",
    ),
    (
        "application/vnd.google-apps.presentation",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ".pptx",
    ),
];
/// Files asked for per page (Drive's most is 1000).
const PAGE_SIZE: u32 = 1000;
/// The fields a listing asks for.
const FIELDS: &str = "nextPageToken,files(id,name,mimeType,size,modifiedTime)";

/// Approves a request's destination: the Drive API's files collection, over HTTPS on the default
/// port. Anything else is refused, whatever asked for it.
///
/// # Errors
///
/// The rule the URL broke.
pub fn check_destination(url: &str) -> Result<(), String> {
    let refuse = || format!("{url:?} is not a Google Drive route; a Google Drive source talks only to {FILES}");
    if url.contains(['#', '\\', ' ']) || url.contains("/../") || url.contains("/./") {
        return Err(refuse());
    }
    match url.strip_prefix(FILES) {
        Some(rest) if rest.is_empty() || rest.starts_with(['/', '?']) => Ok(()),
        _ => Err(refuse()),
    }
}

/// One file in a listing.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// Drive's id.
    pub id: String,
    /// The path below the source's root by name, an exported file with its export's extension.
    pub path: String,
    /// Its size, or 1 for one of Google's own documents, which has none.
    pub size: u64,
    /// `modifiedTime`, in seconds since the epoch.
    pub modified: f64,
    /// The MIME type to export it as, for one of Google's own documents.
    pub export: Option<&'static str>,
}

impl Entry {
    /// The document's URI.
    #[must_use]
    pub fn uri(&self) -> String {
        format!("{URI_PREFIX}{}", self.id)
    }

    fn name(&self) -> &str {
        self.path.rsplit('/').next().unwrap_or_default()
    }
}

/// One child of a folder.
enum Child {
    File(Entry),
    Folder { id: String, path: String },
    Other,
}

fn child(value: &Value, parent: &str) -> Child {
    let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default();
    let (id, name, mime) = (text("id"), text("name"), text("mimeType"));
    if id.is_empty() || name.is_empty() || name.contains('/') {
        return Child::Other;
    }
    if mime == FOLDER {
        return Child::Folder { id: id.to_owned(), path: format!("{parent}/{name}") };
    }
    let modified = parse_drive_time(text("modifiedTime")).unwrap_or(0.0);
    if let Some((_, export, extension)) = EXPORTS.iter().find(|(kind, _, _)| *kind == mime) {
        let file =
            if name.to_ascii_lowercase().ends_with(extension) { name.to_owned() } else { format!("{name}{extension}") };
        return Child::File(Entry {
            id: id.to_owned(),
            path: format!("{parent}/{file}"),
            size: 1,
            modified,
            export: Some(export),
        });
    }
    if mime.starts_with("application/vnd.google-apps.") {
        return Child::Other;
    }
    let size = text("size").parse::<u64>().unwrap_or(0);
    Child::File(Entry { id: id.to_owned(), path: format!("{parent}/{name}"), size, modified, export: None })
}

/// Drive's RFC 3339 `YYYY-MM-DDTHH:MM:SS[.fff]Z` as seconds since the epoch, the fraction dropped.
#[must_use]
pub fn parse_drive_time(text: &str) -> Option<f64> {
    match text.split_once('.') {
        Some((whole, fraction))
            if fraction.ends_with('Z') && fraction[..fraction.len() - 1].bytes().all(|b| b.is_ascii_digit()) =>
        {
            parse_timestamp(&format!("{whole}Z"))
        }
        Some(_) => None,
        None => parse_timestamp(text),
    }
}

/// The Drive, over the API.
struct Drive<'h> {
    client: Client<'h>,
}

impl<'h> Drive<'h> {
    fn new(host: &'h mut dyn RemoteHost, slug: &str) -> Self {
        Self { client: Client::for_service(host, slug, KIND, "Google Drive", check_destination, Vec::new()) }
    }

    /// Every child of the folder `id` (not in the trash), page by page, until `each` stops it.
    fn children(&mut self, id: &str, mut each: impl FnMut(&Value) -> ControlFlow<()>) -> Result<bool, ApiError> {
        let query = format!("'{}' in parents and trashed = false", id.replace(['\\', '\''], ""));
        let base = format!("{FILES}?q={}&fields={}&pageSize={PAGE_SIZE}", encode_path(&query), encode_path(FIELDS));
        let mut url = base.clone();
        loop {
            let page = self.client.json(&url)?;
            for value in page.get("files").and_then(Value::as_array).into_iter().flatten() {
                if each(value).is_break() {
                    return Ok(false);
                }
            }
            match page.get("nextPageToken").and_then(Value::as_str) {
                Some(token) if !token.is_empty() => url = format!("{base}&pageToken={}", encode_path(token)),
                _ => return Ok(true),
            }
        }
    }

    /// The id of the folder at `root`, a path by name from My Drive (`""` for My Drive itself);
    /// [`ApiError::NotFound`] when a part of it is not a folder there.
    fn resolve(&mut self, root: &str) -> Result<String, ApiError> {
        let mut current = "root".to_owned();
        for part in root.split('/').filter(|part| !part.is_empty()) {
            let mut exact = None;
            let mut loose = None;
            self.children(&current, |value| {
                if value.get("mimeType").and_then(Value::as_str) == Some(FOLDER) {
                    let name = value.get("name").and_then(Value::as_str).unwrap_or_default();
                    let id = value.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
                    if name == part {
                        exact = Some(id);
                        return ControlFlow::Break(());
                    }
                    if loose.is_none() && name.eq_ignore_ascii_case(part) {
                        loose = Some(id);
                    }
                }
                ControlFlow::Continue(())
            })?;
            current = exact.or(loose).ok_or_else(|| ApiError::NotFound(format!("no folder {part}")))?;
        }
        Ok(current)
    }

    /// Lists every file below the folder `root_id` (at `root`), folder by folder; `descend` decides by
    /// its path whether a folder is listed, and `visit` may stop the listing.
    fn list(
        &mut self,
        root_id: String,
        root: &str,
        mut descend: impl FnMut(&str) -> bool,
        mut visit: impl FnMut(Entry) -> ControlFlow<()>,
    ) -> Result<bool, ApiError> {
        let mut folders = VecDeque::from([(root_id, root.to_owned())]);
        let mut seen = Vec::new();
        while let Some((id, path)) = folders.pop_front() {
            // A folder can sit in more than one parent: list it once.
            if seen.contains(&id) {
                continue;
            }
            seen.push(id.clone());
            let mut stopped = false;
            let mut below = Vec::new();
            self.children(&id, |value| match child(value, &path) {
                Child::File(entry) => {
                    let flow = visit(entry);
                    stopped = flow.is_break();
                    flow
                }
                Child::Folder { id, path } => {
                    below.push((id, path));
                    ControlFlow::Continue(())
                }
                Child::Other => ControlFlow::Continue(()),
            })?;
            if stopped {
                return Ok(false);
            }
            folders.extend(below.into_iter().filter(|(_, path)| descend(path)));
        }
        Ok(true)
    }

    /// One file's bytes: its content, or its export for one of Google's own documents.
    fn download(&mut self, entry: &Entry) -> Result<Vec<u8>, ApiError> {
        let id = encode_path(&entry.id);
        let url = match entry.export {
            Some(mime) => format!("{FILES}/{id}/export?mimeType={}", encode_path(mime)),
            None => format!("{FILES}/{id}?alt=media"),
        };
        let reply = self.client.get(&url, true, DOWNLOAD_TIMEOUT)?;
        if reply.status != 200 {
            return Err(ApiError::Other(format!(
                "Google Drive answered the download of {} with {}",
                entry.path, reply.status
            )));
        }
        Ok(reply.body)
    }
}

/// A file's bytes, downloaded once and read by the host's readers.
struct DriveFiles<'d, 'h> {
    drive: &'d mut Drive<'h>,
    entry: Entry,
    bytes: Option<Result<Vec<u8>, String>>,
}

impl DriveFiles<'_, '_> {
    fn bytes(&mut self) -> &Result<Vec<u8>, String> {
        if self.bytes.is_none() {
            self.bytes = Some(self.drive.download(&self.entry).map_err(|error| error.to_string()));
        }
        self.bytes.as_ref().unwrap_or_else(|| unreachable!())
    }
}

impl FileHost for DriveFiles<'_, '_> {
    fn ensure_local(&mut self, _: &FileCandidate) -> bool {
        true
    }

    fn source_sha256(&mut self, _: &FileCandidate) -> Option<String> {
        self.bytes().as_ref().ok().map(|bytes| sha256::hex_digest(bytes))
    }

    fn read(&mut self, candidate: &FileCandidate) -> ReadOutcome {
        let bytes = match self.bytes() {
            Ok(bytes) => bytes.clone(),
            Err(error) => return ReadOutcome::Failed(error.clone()),
        };
        self.drive.client.host().read_bytes(&candidate.path, &bytes)
    }
}

/// Lists the source, stores the scan, then decides each kept file as a walked source does.
///
/// `context.source.root` is the folder in My Drive the source registered, by its path of names.
///
/// # Errors
///
/// [`SourceError::Unavailable`] when the root cannot be listed (no token, no such folder, Google
/// unreachable), and [`SourceError::Storage`] when the scan or the run's end could not be stored.
pub fn ingest_google_drive_source(
    host: &mut dyn RemoteHost,
    storage: &mut dyn SourceStorage,
    slug: &str,
    context: &Context<'_>,
    options: &SourceOptions,
) -> Result<SourceRun, SourceError> {
    let mut run = SourceRun::default();
    let root = crate::dropbox::api_root(&context.source.root.to_string_lossy());
    let started = std::time::Instant::now();
    let mut drive = Drive::new(host, slug);

    let mut entries = Vec::new();
    let mut stats = WalkStats { dirs: 1, ..WalkStats::default() };
    let mut folder_stats = WalkStats::default();
    let listed = drive.resolve(&root).and_then(|root_id| {
        drive.list(
            root_id,
            &root,
            |path| descend(path, &root, context.policy, &mut folder_stats),
            |entry| {
                if keep(&entry.path, entry.size, &root, context.policy, options, &mut stats) {
                    entries.push(entry);
                }
                ControlFlow::Continue(())
            },
        )
    });
    if let Err(error) = listed {
        let problem = match error {
            ApiError::NotFound(_) => format!("{} is not a folder in the Google Drive", display_root(&root)),
            ApiError::Other(message) => message,
        };
        run.counters.note_error(problem.clone());
        storage.finalize(false, &run.counters, 0, 0).map_err(SourceError::Storage)?;
        return Err(SourceError::Unavailable(problem));
    }
    stats.dirs += folder_stats.dirs;
    stats.skipped_excluded_dir += folder_stats.skipped_excluded_dir;
    stats.skipped_diagnostic += folder_stats.skipped_diagnostic;
    run.walk_stats = stats;

    let mut details = Map::new();
    details.insert("remote".to_owned(), json!(KIND));
    details.insert("root".to_owned(), json!(display_root(&root)));
    let scan = ScanSummary {
        item_count: entries.len() as u64,
        item_type: "files".to_owned(),
        duration_seconds: started.elapsed().as_secs_f64(),
        details,
        error: None,
    };
    storage.persist_scan(&scan).map_err(SourceError::Storage)?;
    drive.client.host().progress("scan", None, &run.counters);

    // Pictures' image chunks would name a path the image models cannot open.
    let settings = IngestSettings { index_images: false, ..context.settings.clone() };
    let context = Context { settings: &settings, ..*context };

    let mut stopped = false;
    for entry in entries {
        let candidate = FileCandidate {
            path: PathBuf::from(&entry.path),
            uri: entry.uri(),
            size: entry.size,
            mtime: entry.modified,
            placeholder: false,
        };
        let name = entry.name().to_owned();
        if drive.client.host().cancelled() {
            drive.client.host().progress("cancelled", Some(&name), &run.counters);
            stopped = true;
            break;
        }
        run.counters.seen += 1;
        let outcome = storage.check_stat(&candidate.uri).and_then(|existing| {
            let mut files = DriveFiles { drive: &mut drive, entry, bytes: None };
            ingest_one(&mut files, storage, &existing, &candidate, &context, &mut run.counters)
        });
        if let Err(error) = outcome {
            run.counters.note_error(format!("{name}: {error}"));
            let _ = storage.record_seen(&candidate.uri);
        }
        drive.client.host().progress("ingest", Some(&name), &run.counters);
        if options.limit.is_some_and(|limit| run.counters.seen >= limit) {
            stopped = true;
            break;
        }
    }
    run.completed = !stopped;
    storage.finalize(run.completed, &run.counters, 0, 0).map_err(SourceError::Storage)?;
    Ok(run)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::path::Path;
    use std::time::Duration;

    use super::*;
    use crate::attribution::{NoGit, SelfIdentity, TrustTier};
    use crate::chunking::ContentKind;
    use crate::dropbox::{HttpRequest, HttpResponse};
    use crate::pipeline::{Counters, DocumentPayload, ExistingStat, Extracted, SourceInfo, Storage};
    use crate::policy::WalkPolicy;

    #[test]
    fn only_the_drive_files_collection_is_approved() {
        for url in [
            "https://www.googleapis.com/drive/v3/files?q=x&pageSize=1000",
            "https://www.googleapis.com/drive/v3/files/abc?alt=media",
            "https://www.googleapis.com/drive/v3/files/abc/export?mimeType=text%2Fplain",
        ] {
            assert!(check_destination(url).is_ok(), "{url}");
        }
        for url in [
            "http://www.googleapis.com/drive/v3/files",
            "https://www.googleapis.com/drive/v3/filesX",
            "https://www.googleapis.com/drive/v3/about",
            "https://www.googleapis.com/drive/v3/files/../permissions",
            "https://www.googleapis.com/gmail/v1/users/me/messages",
            "https://www.googleapis.com.evil.example/drive/v3/files",
            "https://www.googleapis.com/drive/v3/files?q=a b",
            "https://oauth2.googleapis.com/token",
        ] {
            assert!(check_destination(url).is_err(), "{url}");
        }
    }

    #[test]
    fn google_s_own_documents_are_exported_as_office_files() {
        let doc = json!({"id": "d1", "name": "Plan", "mimeType": "application/vnd.google-apps.document",
                         "modifiedTime": "2026-11-01T10:00:00.123Z"});
        let Child::File(entry) = child(&doc, "/Work") else { panic!() };
        assert_eq!(
            (entry.path.as_str(), entry.size, entry.uri()),
            ("/Work/Plan.docx", 1, "google_drive:d1".to_owned())
        );
        assert!(entry.export.unwrap().contains("wordprocessingml"));
        let form = json!({"id": "f1", "name": "Survey", "mimeType": "application/vnd.google-apps.form"});
        assert!(matches!(child(&form, ""), Child::Other));
        let pdf = json!({"id": "p1", "name": "a.pdf", "mimeType": "application/pdf", "size": "1234"});
        let Child::File(entry) = child(&pdf, "") else { panic!() };
        assert_eq!((entry.size, entry.export), (1234, None));
        assert!(matches!(child(&json!({"id": "x", "name": "a/b", "mimeType": "text/plain"}), ""), Child::Other));
    }

    /// A drive in memory: folders and files by path (a path ending in `/` is a folder), ids their
    /// index, children listed two to a page.
    #[derive(Default)]
    struct FakeDrive {
        items: Vec<(String, String, String)>,
        requests: Vec<String>,
    }

    impl FakeDrive {
        fn with(items: &[(&str, &str, &str)]) -> Self {
            Self {
                items: items
                    .iter()
                    .map(|(path, mime, body)| ((*path).to_owned(), (*mime).to_owned(), (*body).to_owned()))
                    .collect(),
                ..Self::default()
            }
        }

        fn parent_of(&self, id: &str) -> String {
            if id == "root" { String::new() } else { self.items[id[1..].parse::<usize>().unwrap()].0.clone() }
        }

        fn children(&self, parent: &str) -> Vec<Value> {
            self.items
                .iter()
                .enumerate()
                .filter(|(_, (path, _, _))| path.rsplit_once('/').is_some_and(|(dir, _)| dir == parent))
                .map(|(index, (path, mime, body))| {
                    json!({"id": format!("i{index}"), "name": path.rsplit('/').next(), "mimeType": mime,
                           "size": body.len().to_string(), "modifiedTime": "2026-11-01T10:00:00.000Z"})
                })
                .collect()
        }
    }

    fn reply(status: u16, body: impl Into<Vec<u8>>) -> HttpResponse {
        HttpResponse { status, headers: Vec::new(), body: body.into() }
    }

    fn decode(text: &str) -> String {
        let bytes = text.as_bytes();
        let mut out = Vec::new();
        let mut index = 0;
        while index < bytes.len() {
            if bytes[index] == b'%' {
                out.push(u8::from_str_radix(&text[index + 1..index + 3], 16).unwrap());
                index += 3;
            } else {
                out.push(bytes[index]);
                index += 1;
            }
        }
        String::from_utf8(out).unwrap()
    }

    impl RemoteHost for FakeDrive {
        fn access_token(&mut self, service: &str, slug: &str, _: bool) -> Result<String, String> {
            assert_eq!((service, slug), (KIND, "gd"));
            Ok("token".into())
        }

        fn send(&mut self, request: &HttpRequest) -> Result<HttpResponse, String> {
            check_destination(&request.url)?;
            let url = &request.url;
            if let Some(rest) = url.strip_prefix(&format!("{FILES}/")) {
                let (id, how) = rest.split_once(['?', '/']).unwrap();
                self.requests.push(format!("download {id} {}", how.split('?').next().unwrap()));
                let (_, _, body) = &self.items[id[1..].parse::<usize>().unwrap()];
                return Ok(reply(200, body.clone()));
            }
            let query = decode(url.split("q=").nth(1).unwrap().split('&').next().unwrap());
            let id = query.split('\'').nth(1).unwrap().to_owned();
            let parent = self.parent_of(&id);
            self.requests.push(format!("list {parent}"));
            let children = self.children(&parent);
            let from: usize = url.split("pageToken=").nth(1).map_or(0, |token| token.parse().unwrap());
            let to = (from + 2).min(children.len());
            let mut page = json!({"files": children[from..to]});
            if to < children.len() {
                page["nextPageToken"] = json!(to.to_string());
            }
            Ok(reply(200, page.to_string()))
        }

        fn read_bytes(&mut self, path: &Path, bytes: &[u8]) -> ReadOutcome {
            ReadOutcome::Document(Extracted {
                text: String::from_utf8_lossy(bytes).into_owned(),
                kind: ContentKind::Prose,
                extractor: "markdown".into(),
                extractor_version: "1".into(),
                title: path.file_stem().map(|stem| stem.to_string_lossy().into_owned()),
                lang: None,
                meta: Map::new(),
                author_hints: Vec::new(),
            })
        }

        fn wait(&mut self, _: Duration) {}
    }

    #[derive(Default)]
    struct Database {
        stats: HashMap<String, ExistingStat>,
        documents: Vec<String>,
        seen: Vec<String>,
        scan: Option<ScanSummary>,
        finalized: Option<bool>,
    }

    impl Storage for Database {
        fn record_seen(&mut self, uri: &str) -> Result<(), String> {
            self.seen.push(uri.to_owned());
            Ok(())
        }
        fn record_placeholder(&mut self, _: &str, _: f64, _: &str, _: &str) -> Result<(), String> {
            unreachable!()
        }
        fn record_no_text(&mut self, _: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
            unreachable!()
        }
        fn record_extract_failed(&mut self, uri: &str, _: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
            self.seen.push(format!("failed {uri}"));
            Ok(())
        }
        fn record_rejected(&mut self, uri: &str) -> Result<(), String> {
            self.seen.push(format!("rejected {uri}"));
            Ok(())
        }
        fn refresh_metadata(&mut self, uri: &str, _: u64, _: f64, _: &str, _: &str, _: &str) -> Result<(), String> {
            self.seen.push(format!("refreshed {uri}"));
            Ok(())
        }
        fn replace_document(&mut self, uri: &str, document: DocumentPayload) -> Result<usize, String> {
            self.documents.push(uri.to_owned());
            Ok(document.chunks.len())
        }
    }

    impl SourceStorage for Database {
        fn check_stat(&mut self, uri: &str) -> Result<ExistingStat, String> {
            Ok(self.stats.get(uri).cloned().unwrap_or_default())
        }
        fn persist_scan(&mut self, scan: &ScanSummary) -> Result<(), String> {
            self.scan = Some(scan.clone());
            Ok(())
        }
        fn finalize(&mut self, completed: bool, _: &Counters, _: u64, _: u64) -> Result<(), String> {
            self.finalized = Some(completed);
            Ok(())
        }
    }

    const PROSE: &str = "Garage keeps its index on the Mac. This note talks about the plan for the week, \
                         the people who will review it, and what is still open before we ship it.";

    fn drive() -> FakeDrive {
        FakeDrive::with(&[
            ("/Work", FOLDER, ""),
            ("/Work/plan.md", "text/markdown", PROSE),
            ("/Work/Budget", "application/vnd.google-apps.spreadsheet", PROSE),
            ("/Work/song.mp3", "audio/mpeg", "ID3"),
            ("/Work/node_modules", FOLDER, ""),
            ("/Work/node_modules/readme.md", "text/markdown", PROSE),
            ("/Work/Notes", FOLDER, ""),
            ("/Work/Notes/Café.md", "text/markdown", PROSE),
            ("/Work/Survey", "application/vnd.google-apps.form", ""),
            ("/Elsewhere.md", "text/markdown", PROSE),
        ])
    }

    fn run(drive: &mut FakeDrive, database: &mut Database, root: &str) -> Result<SourceRun, SourceError> {
        let source = SourceInfo {
            root: PathBuf::from(root),
            default_class: "document".into(),
            default_trust: TrustTier::Authored,
        };
        let identity = SelfIdentity::new("", &[]);
        let settings = IngestSettings::default();
        let policy = WalkPolicy::default();
        let context = Context {
            source: &source,
            identity: &identity,
            git: &NoGit,
            contact_names: None,
            settings: &settings,
            policy: &policy,
            force: false,
        };
        ingest_google_drive_source(drive, database, "gd", &context, &SourceOptions::default())
    }

    #[test]
    fn a_folder_is_resolved_listed_pruned_exported_and_indexed() {
        let mut drive = drive();
        let mut database = Database::default();
        let outcome = run(&mut drive, &mut database, "/work").unwrap();
        assert!(outcome.completed);
        assert_eq!(database.documents, ["google_drive:i1", "google_drive:i2", "google_drive:i7"]);
        assert_eq!(outcome.walk_stats.skipped_extension, 1);
        assert_eq!(outcome.walk_stats.skipped_excluded_dir, 1);
        assert!(drive.requests.contains(&"download i2 export".to_owned()));
        assert!(drive.requests.contains(&"download i1 alt=media".to_owned()));
        assert!(!drive.requests.contains(&"list /Work/node_modules".to_owned()));
        let scan = database.scan.unwrap();
        assert_eq!((scan.item_count, scan.details["root"].clone()), (3, json!("/work")));
    }

    #[test]
    fn an_unchanged_file_is_not_downloaded() {
        let mut drive = drive();
        let mut database = Database::default();
        database.stats.insert(
            "google_drive:i7".into(),
            ExistingStat {
                exists: true,
                byte_size: i64::try_from(PROSE.len()).unwrap(),
                mtime: parse_drive_time("2026-11-01T10:00:00Z").unwrap(),
                state: "OK".into(),
                ..ExistingStat::default()
            },
        );
        let outcome = run(&mut drive, &mut database, "/Work/Notes").unwrap();
        assert_eq!((outcome.counters.skipped, outcome.counters.indexed), (1, 0));
        assert!(!drive.requests.iter().any(|request| request.starts_with("download")));
    }

    #[test]
    fn a_missing_folder_fails_the_run_before_the_scan_is_stored() {
        let mut drive = drive();
        let mut database = Database::default();
        let outcome = run(&mut drive, &mut database, "/Gone");
        assert_eq!(outcome, Err(SourceError::Unavailable("/Gone is not a folder in the Google Drive".into())));
        assert!(database.scan.is_none());
        assert_eq!(database.finalized, Some(false));
    }
}
