//! A Dropbox source read through Dropbox's HTTP API (`files/list_folder` and `files/download`),
//! not through the synced folder: the account's files are listed, the ones the walker's rules keep
//! are compared with the database by their stat, and only a new or changed file is downloaded, into
//! memory, and handed to the readers.
//!
//! Nothing here opens a connection or holds a credential. The [`RemoteHost`] carries each request
//! after [`check_destination`] has approved it (only Dropbox's two API origins, over HTTPS), and
//! hands over a short-lived access token when asked: the Mac app's store build gets it from Garage
//! Door, which keeps the refresh token, and another host may keep its own. A request carries the
//! source's paths and cursors, never a document's text: content only comes in.
//!
//! A file's URI is `dropbox:` and its path as Dropbox displays it, so a renamed file is a new
//! document and the old one goes at reconcile, as for a folder. Pictures get no image chunk, since
//! the image models read files by path and these are not on disk.

use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::pipeline::{Context, Counters, FileCandidate, FileHost, IngestSettings, ReadOutcome, ingest_one};
use crate::sha256;
use crate::source::{ScanSummary, SourceError, SourceOptions, SourceRun, SourceStorage};
use crate::walk::{
    WalkStats, is_code_path, is_dependency_path, is_diagnostic_dir, is_diagnostic_file, is_hidden, is_indexable,
};

/// The API's origin: listings, metadata, account.
pub const API_ORIGIN: &str = "https://api.dropboxapi.com";
/// The content origin: downloads.
pub const CONTENT_ORIGIN: &str = "https://content.dropboxapi.com";
/// The source kind in `sources.kind`.
pub const KIND: &str = "dropbox";
/// The URI scheme of a Dropbox file's document.
pub const URI_PREFIX: &str = "dropbox:";
/// Entries asked for per listing page (Dropbox's most is 2000).
const PAGE_LIMIT: u32 = 2000;
/// Tries of a request Dropbox asked to slow down (429, or 503 with `Retry-After`).
const RATE_LIMIT_TRIES: u32 = 4;
/// The longest wait honoured between them.
const LONGEST_WAIT: Duration = Duration::from_secs(60);
/// How long one listing call may take.
const LIST_TIMEOUT: Duration = Duration::from_secs(60);
/// How long one download may take.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(300);
/// Dropbox's content hash block size.
const HASH_BLOCK: usize = 4 * 1024 * 1024;

/// One request to Dropbox, approved by [`check_destination`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRequest {
    /// Always `POST`: every Dropbox API v2 route is one.
    pub method: &'static str,
    /// The absolute URL. The host sends the request there and nowhere else: no proxy, and a
    /// redirect is answered as the response it is, never followed.
    pub url: String,
    /// Headers, the bearer token among them. The host never logs them.
    pub headers: Vec<(String, String)>,
    /// The body.
    pub body: Vec<u8>,
    /// How long the request may take.
    pub timeout: Duration,
}

/// Dropbox's reply, whatever its status.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HttpResponse {
    /// The HTTP status.
    pub status: u16,
    /// Headers the client reads (`Retry-After`, `Dropbox-API-Result`), names in any case.
    pub headers: Vec<(String, String)>,
    /// The body.
    pub body: Vec<u8>,
}

impl HttpResponse {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
    }
}

/// What a Dropbox source needs from the process that runs it.
pub trait RemoteHost {
    /// A Dropbox access token for the source `slug`. `refresh` is true after Dropbox refused the
    /// last one, so a host that caches tokens fetches a new one.
    ///
    /// # Errors
    ///
    /// Why there is none: no account connected, Door unreachable, the grant revoked.
    fn access_token(&mut self, slug: &str, refresh: bool) -> Result<String, String>;

    /// Sends `request` and returns the reply.
    ///
    /// # Errors
    ///
    /// A readable reason when no HTTP reply came.
    fn send(&mut self, request: &HttpRequest) -> Result<HttpResponse, String>;

    /// Reads a downloaded file's bytes; `path` names it (Dropbox's display path) for the reader.
    fn read_bytes(&mut self, path: &Path, bytes: &[u8]) -> ReadOutcome;

    /// Waits before trying again a request Dropbox asked to slow down.
    fn wait(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }

    /// Asked before each file.
    fn cancelled(&mut self) -> bool {
        false
    }

    /// Progress: `phase` is scan, ingest or cancelled.
    fn progress(&mut self, _phase: &str, _current_item: Option<&str>, _counters: &Counters) {}
}

/// Approves a request's destination: Dropbox's API or content origin over HTTPS on its default
/// port, and an API v2 route. Anything else is refused, whatever asked for it.
///
/// # Errors
///
/// The rule the URL broke.
pub fn check_destination(url: &str) -> Result<(), String> {
    for origin in [API_ORIGIN, CONTENT_ORIGIN] {
        if let Some(path) = url.strip_prefix(origin)
            && path.starts_with("/2/")
            && !path.contains(['?', '#', '@', '\\'])
            && !path.contains("/../")
        {
            return Ok(());
        }
    }
    Err(format!(
        "{url:?} is not a Dropbox API route; a Dropbox source talks only to {API_ORIGIN}/2/ and {CONTENT_ORIGIN}/2/"
    ))
}

/// The root as the API names it: `""` for the whole Dropbox, else `/path` with no trailing slash.
#[must_use]
pub fn api_root(root: &str) -> String {
    let trimmed = root.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        String::new()
    } else if trimmed.starts_with('/') {
        trimmed.to_owned()
    } else {
        format!("/{trimmed}")
    }
}

/// The root a source registers with: `/` for the whole Dropbox.
#[must_use]
pub fn display_root(root: &str) -> String {
    let root = api_root(root);
    if root.is_empty() { "/".to_owned() } else { root }
}

/// One file in a listing.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// Dropbox's id (`id:...`), stable across moves.
    pub id: String,
    /// The path as displayed.
    pub path_display: String,
    /// The path in lower case.
    pub path_lower: String,
    /// Its size.
    pub size: u64,
    /// `server_modified`, in seconds since the epoch.
    pub modified: f64,
    /// Dropbox's content hash, hex.
    pub content_hash: String,
    /// The revision.
    pub rev: String,
}

impl Entry {
    fn from_json(value: &Value) -> Option<Self> {
        if value.get(".tag").and_then(Value::as_str) != Some("file") {
            return None;
        }
        if value.get("is_downloadable").and_then(Value::as_bool) == Some(false) {
            return None;
        }
        let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
        Some(Self {
            id: text("id"),
            path_display: text("path_display"),
            path_lower: text("path_lower"),
            size: value.get("size").and_then(Value::as_u64).unwrap_or(0),
            modified: value.get("server_modified").and_then(Value::as_str).and_then(parse_timestamp).unwrap_or(0.0),
            content_hash: text("content_hash"),
            rev: text("rev"),
        })
        .filter(|entry| !entry.path_display.is_empty() && !entry.id.is_empty())
    }

    /// The document's URI.
    #[must_use]
    pub fn uri(&self) -> String {
        format!("{URI_PREFIX}{}", self.path_display)
    }

    fn name(&self) -> &str {
        self.path_display.rsplit('/').next().unwrap_or_default()
    }
}

/// `YYYY-MM-DDTHH:MM:SSZ` as seconds since the epoch.
#[must_use]
pub fn parse_timestamp(text: &str) -> Option<f64> {
    let bytes = text.as_bytes();
    if bytes.len() != 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' || bytes[19] != b'Z' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| text.get(range)?.parse::<i64>().ok();
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    #[allow(clippy::cast_precision_loss)]
    let seconds = (days * 86_400 + hour * 3_600 + minute * 60 + second) as f64;
    Some(seconds)
}

/// Dropbox's content hash of `bytes` (dropbox.com/developers/reference/content-hash): SHA-256 of
/// each 4 MiB block, concatenated, then SHA-256 of that; hex.
#[must_use]
pub fn content_hash(bytes: &[u8]) -> String {
    let mut overall = sha256::Hasher::default();
    for block in bytes.chunks(HASH_BLOCK) {
        overall.update(&sha256::digest(block));
    }
    hex(&overall.finish())
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::with_capacity(bytes.len() * 2), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

/// JSON safe in an HTTP header (`Dropbox-API-Arg`): every character past ASCII escaped.
#[must_use]
pub fn header_json(value: &Value) -> String {
    use std::fmt::Write as _;
    let text = value.to_string();
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        if character.is_ascii() {
            out.push(character);
        } else {
            let mut units = [0u16; 2];
            for unit in character.encode_utf16(&mut units) {
                let _ = write!(out, "\\u{unit:04x}");
            }
        }
    }
    out
}

/// A failed API call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApiError {
    /// The path is gone or never was (`path/not_found`).
    NotFound(String),
    /// Anything else, readable.
    Other(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound(message) | Self::Other(message) => f.write_str(message),
        }
    }
}

/// The API's calls, with the token, the refresh after a 401 and the waits Dropbox asks for.
pub struct Client<'h> {
    host: &'h mut dyn RemoteHost,
    slug: String,
    token: Option<String>,
}

impl<'h> Client<'h> {
    /// A client for the source `slug`, asking `host` for its token when first needed.
    pub fn new(host: &'h mut dyn RemoteHost, slug: &str) -> Self {
        Self { host, slug: slug.to_owned(), token: None }
    }

    /// The host, between calls.
    pub fn host(&mut self) -> &mut dyn RemoteHost {
        self.host
    }

    fn call(
        &mut self,
        url: &str,
        arg_header: Option<&Value>,
        body: Option<&Value>,
        timeout: Duration,
    ) -> Result<HttpResponse, ApiError> {
        check_destination(url).map_err(ApiError::Other)?;
        let mut refreshed = false;
        let mut tries = 0;
        loop {
            let token = if let Some(token) = &self.token {
                token.clone()
            } else {
                let token = self.host.access_token(&self.slug, refreshed).map_err(ApiError::Other)?;
                self.token = Some(token.clone());
                token
            };
            let mut headers = vec![("Authorization".to_owned(), format!("Bearer {token}"))];
            if let Some(arg) = arg_header {
                headers.push(("Dropbox-API-Arg".to_owned(), header_json(arg)));
            }
            let body = match body {
                Some(body) => {
                    headers.push(("Content-Type".to_owned(), "application/json".to_owned()));
                    body.to_string().into_bytes()
                }
                None => Vec::new(),
            };
            let request = HttpRequest { method: "POST", url: url.to_owned(), headers, body, timeout };
            let response = self.host.send(&request).map_err(|error| ApiError::Other(format!("Dropbox: {error}")))?;
            match response.status {
                200 => return Ok(response),
                401 if !refreshed => {
                    // Expired or revoked: one new token, then the reply stands.
                    refreshed = true;
                    self.token = None;
                }
                429 | 503 if tries + 1 < RATE_LIMIT_TRIES => {
                    tries += 1;
                    let wait = response
                        .header("Retry-After")
                        .and_then(|value| value.trim().parse::<u64>().ok())
                        .map_or(Duration::from_secs(1 << tries), Duration::from_secs)
                        .min(LONGEST_WAIT);
                    self.host.wait(wait);
                }
                _ => return Err(api_error(&response)),
            }
        }
    }

    /// Lists every file below `root`, recursively, page by page; `visit` may stop the listing.
    ///
    /// # Errors
    ///
    /// [`ApiError::NotFound`] when the root is not in the Dropbox, else the call's failure.
    pub fn list(&mut self, root: &str, mut visit: impl FnMut(Entry) -> ControlFlow<()>) -> Result<bool, ApiError> {
        let mut reply = self.call(
            &format!("{API_ORIGIN}/2/files/list_folder"),
            None,
            Some(&json!({
                "path": api_root(root),
                "recursive": true,
                "include_deleted": false,
                "include_non_downloadable_files": false,
                "include_mounted_folders": true,
                "limit": PAGE_LIMIT,
            })),
            LIST_TIMEOUT,
        )?;
        loop {
            let page: Value = serde_json::from_slice(&reply.body)
                .map_err(|error| ApiError::Other(format!("Dropbox sent a listing that is not JSON: {error}")))?;
            for entry in page.get("entries").and_then(Value::as_array).into_iter().flatten() {
                if let Some(entry) = Entry::from_json(entry)
                    && visit(entry).is_break()
                {
                    return Ok(false);
                }
            }
            if page.get("has_more").and_then(Value::as_bool) != Some(true) {
                return Ok(true);
            }
            let cursor = page
                .get("cursor")
                .and_then(Value::as_str)
                .ok_or_else(|| ApiError::Other("Dropbox said there is more but gave no cursor".to_owned()))?
                .to_owned();
            reply = self.call(
                &format!("{API_ORIGIN}/2/files/list_folder/continue"),
                None,
                Some(&json!({ "cursor": cursor })),
                LIST_TIMEOUT,
            )?;
        }
    }

    /// Downloads one file's bytes, checked against its content hash when the listing gave one.
    ///
    /// # Errors
    ///
    /// The call's failure, or bytes that do not match the hash.
    pub fn download(&mut self, entry: &Entry) -> Result<Vec<u8>, ApiError> {
        // By id: ASCII, and still right if the file moved since the listing.
        let reply = self.call(
            &format!("{CONTENT_ORIGIN}/2/files/download"),
            Some(&json!({ "path": entry.id })),
            None,
            DOWNLOAD_TIMEOUT,
        )?;
        if !entry.content_hash.is_empty() && content_hash(&reply.body) != entry.content_hash {
            return Err(ApiError::Other(format!(
                "the download of {} does not match Dropbox's content hash",
                entry.path_display
            )));
        }
        Ok(reply.body)
    }
}

fn api_error(response: &HttpResponse) -> ApiError {
    let body: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
    let summary = body.get("error_summary").and_then(Value::as_str).map(str::to_owned);
    let summary = summary.unwrap_or_else(|| {
        let text = String::from_utf8_lossy(&response.body);
        text.chars().take(200).collect()
    });
    if response.status == 409 && summary.contains("not_found") {
        return ApiError::NotFound(format!("not in the Dropbox ({summary})"));
    }
    let what = match response.status {
        401 => "Dropbox refused the access token",
        403 => "Dropbox refused the request",
        429 => "Dropbox is rate limiting this app",
        400 => "Dropbox rejected the request",
        _ => "Dropbox answered",
    };
    ApiError::Other(format!("{what} ({}): {summary}", response.status))
}

/// Whether the walker's rules keep `entry`, counted as the walker counts. `root` is the API root.
fn keep(
    entry: &Entry,
    root: &str,
    policy: &crate::policy::WalkPolicy,
    options: &SourceOptions,
    stats: &mut WalkStats,
) -> bool {
    stats.files_seen += 1;
    let relative = entry.path_display.get(root.len()..).unwrap_or(&entry.path_display);
    let mut parts: Vec<&str> = relative.split('/').filter(|part| !part.is_empty()).collect();
    let name = parts.pop().unwrap_or_default();
    for directory in &parts {
        if policy.exclude_dirs.contains(*directory) || is_hidden(directory) || directory.eq_ignore_ascii_case(".git") {
            stats.skipped_excluded_dir += 1;
            return false;
        }
        if is_diagnostic_dir(directory, policy) {
            stats.skipped_diagnostic += 1;
            return false;
        }
    }
    if !parts.is_empty() && is_dependency_path(&format!("/{}/", parts.join("/")), policy) {
        stats.skipped_excluded_dir += 1;
        return false;
    }
    if is_hidden(name) {
        return false;
    }
    if is_diagnostic_file(name, policy) {
        stats.skipped_diagnostic += 1;
        return false;
    }
    if !is_indexable(name, policy) {
        stats.skipped_extension += 1;
        return false;
    }
    if !options.include_code && is_code_path(name, policy) {
        stats.skipped_code += 1;
        return false;
    }
    if entry.size == 0 {
        return false;
    }
    if entry.size > policy.max_file_bytes {
        stats.skipped_too_large += 1;
        return false;
    }
    stats.yielded += 1;
    true
}

/// A file's bytes, downloaded once and read by the host's readers.
struct RemoteFiles<'c, 'h> {
    client: &'c mut Client<'h>,
    entry: Entry,
    bytes: Option<Result<Vec<u8>, String>>,
}

impl RemoteFiles<'_, '_> {
    fn bytes(&mut self) -> &Result<Vec<u8>, String> {
        if self.bytes.is_none() {
            self.bytes = Some(self.client.download(&self.entry).map_err(|error| error.to_string()));
        }
        self.bytes.as_ref().unwrap_or_else(|| unreachable!())
    }
}

impl FileHost for RemoteFiles<'_, '_> {
    fn ensure_local(&mut self, _: &FileCandidate) -> bool {
        // Downloads are what this source is: never a placeholder.
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
        self.client.host().read_bytes(&candidate.path, &bytes)
    }
}

/// Lists the source, stores the scan, then decides each kept file as a walked source does.
///
/// `context.source.root` is the Dropbox path the source registered; the context's git history is
/// not consulted, since nothing is on disk. The scan stored is the listing's.
///
/// # Errors
///
/// [`SourceError::Unavailable`] when the root cannot be listed (no token, not in the Dropbox,
/// Dropbox unreachable), and [`SourceError::Storage`] when the scan or the run's end could not be
/// stored.
pub fn ingest_dropbox_source(
    host: &mut dyn RemoteHost,
    storage: &mut dyn SourceStorage,
    slug: &str,
    context: &Context<'_>,
    options: &SourceOptions,
) -> Result<SourceRun, SourceError> {
    let mut run = SourceRun::default();
    let root = api_root(&context.source.root.to_string_lossy());
    let started = std::time::Instant::now();
    let mut client = Client::new(host, slug);

    let mut entries = Vec::new();
    let mut stats = WalkStats::default();
    let listed = client.list(&root, |entry| {
        if keep(&entry, &root, context.policy, options, &mut stats) {
            entries.push(entry);
        }
        ControlFlow::Continue(())
    });
    if let Err(error) = listed {
        let problem = match error {
            ApiError::NotFound(_) => format!("{} is not in the Dropbox", display_root(&root)),
            ApiError::Other(message) => message,
        };
        run.counters.note_error(problem.clone());
        storage.finalize(false, &run.counters, 0, 0).map_err(SourceError::Storage)?;
        return Err(SourceError::Unavailable(problem));
    }
    stats.dirs = 1;
    run.walk_stats = stats;

    let mut details = Map::new();
    details.insert("remote".to_owned(), json!(KIND));
    details.insert("root".to_owned(), json!(display_root(&root)));
    details.insert("bytes".to_owned(), json!(entries.iter().map(|entry| entry.size).sum::<u64>()));
    let scan = ScanSummary {
        item_count: entries.len() as u64,
        item_type: "files".to_owned(),
        duration_seconds: started.elapsed().as_secs_f64(),
        details,
        error: None,
    };
    storage.persist_scan(&scan).map_err(SourceError::Storage)?;
    client.host().progress("scan", None, &run.counters);

    // Pictures' image chunks would name a path the image models cannot open.
    let settings = IngestSettings { index_images: false, ..context.settings.clone() };
    let context = Context { settings: &settings, ..*context };

    let mut stopped = false;
    for entry in entries {
        let candidate = FileCandidate {
            path: PathBuf::from(&entry.path_display),
            uri: entry.uri(),
            size: entry.size,
            mtime: entry.modified,
            placeholder: false,
        };
        let name = entry.name().to_owned();
        if client.host().cancelled() {
            client.host().progress("cancelled", Some(&name), &run.counters);
            stopped = true;
            break;
        }
        run.counters.seen += 1;
        let outcome = storage.check_stat(&candidate.uri).and_then(|existing| {
            let mut files = RemoteFiles { client: &mut client, entry, bytes: None };
            ingest_one(&mut files, storage, &existing, &candidate, &context, &mut run.counters)
        });
        if let Err(error) = outcome {
            run.counters.note_error(format!("{name}: {error}"));
            let _ = storage.record_seen(&candidate.uri);
        }
        client.host().progress("ingest", Some(&name), &run.counters);
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

    use super::*;
    use crate::attribution::{NoGit, SelfIdentity, TrustTier};
    use crate::chunking::ContentKind;
    use crate::pipeline::{DocumentPayload, ExistingStat, Extracted, SourceInfo, Storage};
    use crate::policy::WalkPolicy;

    #[test]
    fn only_dropbox_api_routes_are_approved() {
        assert!(check_destination("https://api.dropboxapi.com/2/files/list_folder").is_ok());
        assert!(check_destination("https://content.dropboxapi.com/2/files/download").is_ok());
        for url in [
            "http://api.dropboxapi.com/2/files/list_folder",
            "https://api.dropboxapi.com.evil.example/2/files/list_folder",
            "https://api.dropboxapi.com:8443/2/files/list_folder",
            "https://api.dropboxapi.com/oauth2/token",
            "https://api.dropboxapi.com/2/../oauth2/token",
            "https://api.dropboxapi.com/2/files?x=1",
            "https://api.dropboxapi.com@evil.example/2/",
            "https://www.dropbox.com/2/files/list_folder",
            "http://localhost:11434/2/files/download",
        ] {
            assert!(check_destination(url).is_err(), "{url}");
        }
    }

    #[test]
    fn roots_are_named_as_the_api_names_them() {
        assert_eq!(api_root("/"), "");
        assert_eq!(api_root(""), "");
        assert_eq!(api_root("Documents/"), "/Documents");
        assert_eq!(api_root("/Work/Notes"), "/Work/Notes");
        assert_eq!(display_root(""), "/");
        assert_eq!(display_root("/Work/"), "/Work");
    }

    #[test]
    #[allow(clippy::float_cmp)]
    fn timestamps_are_read_as_utc() {
        assert_eq!(parse_timestamp("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(parse_timestamp("2015-05-12T15:50:38Z"), Some(1_431_445_838.0));
        assert_eq!(parse_timestamp("2024-02-29T12:00:00Z"), Some(1_709_208_000.0));
        assert_eq!(parse_timestamp("2015-05-12 15:50:38"), None);
        assert_eq!(parse_timestamp("2015-13-12T15:50:38Z"), None);
    }

    #[test]
    fn the_content_hash_is_dropbox_s() {
        // No blocks: SHA-256 of nothing.
        assert_eq!(content_hash(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        // One block: SHA-256 of the block's SHA-256.
        assert_eq!(content_hash(b"abc"), hex(&sha256::digest(&sha256::digest(b"abc"))));
        // Two blocks: the digests concatenated.
        let bytes = vec![7u8; HASH_BLOCK + 1];
        let mut joined = sha256::digest(&bytes[..HASH_BLOCK]).to_vec();
        joined.extend_from_slice(&sha256::digest(&bytes[HASH_BLOCK..]));
        assert_eq!(content_hash(&bytes), hex(&sha256::digest(&joined)));
    }

    #[test]
    fn header_arguments_are_ascii() {
        let header = header_json(&json!({"path": "/Caf\u{e9} \u{1f600}"}));
        assert!(header.is_ascii());
        assert_eq!(header, "{\"path\":\"/Caf\\u00e9 \\ud83d\\ude00\"}");
    }

    /// A Dropbox in memory: `files` by path, listed two to a page.
    #[derive(Default)]
    #[allow(clippy::struct_excessive_bools)]
    struct FakeDropbox {
        corrupt_downloads: bool,
        files: Vec<(String, Vec<u8>)>,
        tokens_issued: u32,
        expire_first_token: bool,
        throttle_once: bool,
        missing_root: bool,
        no_token: bool,
        requests: Vec<String>,
        waits: Vec<Duration>,
        cancel_after: Option<usize>,
        asked: usize,
        phases: Vec<String>,
    }

    impl FakeDropbox {
        fn with(files: &[(&str, &str)]) -> Self {
            Self {
                files: files.iter().map(|(path, text)| ((*path).to_owned(), text.as_bytes().to_vec())).collect(),
                ..Self::default()
            }
        }

        fn entry(&self, index: usize) -> Value {
            let (path, bytes) = &self.files[index];
            json!({
                ".tag": "file", "name": path.rsplit('/').next(), "id": format!("id:{index}"),
                "path_display": path, "path_lower": path.to_lowercase(), "size": bytes.len(),
                "server_modified": "2026-11-01T10:00:00Z", "rev": "0123456789abcdef",
                "content_hash": content_hash(bytes), "is_downloadable": true,
            })
        }

        fn page(&self, from: usize) -> Vec<u8> {
            let to = (from + 2).min(self.files.len());
            let mut entries: Vec<Value> = (from..to).map(|index| self.entry(index)).collect();
            entries.push(json!({".tag": "folder", "name": "Notes", "id": "id:dir", "path_display": "/Notes"}));
            json!({ "entries": entries, "cursor": format!("c{to}"), "has_more": to < self.files.len() })
                .to_string()
                .into_bytes()
        }
    }

    fn ok(body: Vec<u8>) -> HttpResponse {
        HttpResponse { status: 200, headers: Vec::new(), body }
    }

    impl RemoteHost for FakeDropbox {
        fn access_token(&mut self, slug: &str, _refresh: bool) -> Result<String, String> {
            assert_eq!(slug, "dbx");
            if self.no_token {
                return Err("no Dropbox account is connected to Garage Door".to_owned());
            }
            self.tokens_issued += 1;
            Ok(format!("token-{}", self.tokens_issued))
        }

        fn send(&mut self, request: &HttpRequest) -> Result<HttpResponse, String> {
            let route = request.url.rsplit("/2/").next().unwrap().to_owned();
            self.requests.push(route.clone());
            let token = &request.headers[0].1;
            if self.expire_first_token && token == "Bearer token-1" {
                return Ok(HttpResponse {
                    status: 401,
                    body: br#"{"error_summary": "expired_access_token/"}"#.to_vec(),
                    ..HttpResponse::default()
                });
            }
            if self.throttle_once {
                self.throttle_once = false;
                return Ok(HttpResponse {
                    status: 429,
                    headers: vec![("retry-after".into(), "3".into())],
                    body: Vec::new(),
                });
            }
            let body: Value = serde_json::from_slice(&request.body).unwrap_or(Value::Null);
            match route.as_str() {
                "files/list_folder" => {
                    if self.missing_root {
                        return Ok(HttpResponse {
                            status: 409,
                            body: br#"{"error_summary": "path/not_found/.."}"#.to_vec(),
                            ..HttpResponse::default()
                        });
                    }
                    assert_eq!(body["recursive"], json!(true));
                    Ok(ok(self.page(0)))
                }
                "files/list_folder/continue" => {
                    let from = body["cursor"].as_str().unwrap()[1..].parse().unwrap();
                    Ok(ok(self.page(from)))
                }
                "files/download" => {
                    let arg = &request.headers.iter().find(|(name, _)| name == "Dropbox-API-Arg").unwrap().1;
                    let arg: Value = serde_json::from_str(arg).unwrap();
                    let index: usize = arg["path"].as_str().unwrap()[3..].parse().unwrap();
                    let mut bytes = self.files[index].1.clone();
                    if self.corrupt_downloads {
                        bytes.push(b'!');
                    }
                    Ok(ok(bytes))
                }
                other => panic!("unexpected route {other}"),
            }
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

        fn wait(&mut self, duration: Duration) {
            self.waits.push(duration);
        }

        fn cancelled(&mut self) -> bool {
            self.asked += 1;
            self.cancel_after.is_some_and(|after| self.asked > after)
        }

        fn progress(&mut self, phase: &str, _: Option<&str>, _: &Counters) {
            self.phases.push(phase.to_owned());
        }
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
            assert!(!document.chunks.is_empty());
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

    fn run(dropbox: &mut FakeDropbox, database: &mut Database, root: &str) -> Result<SourceRun, SourceError> {
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
        ingest_dropbox_source(dropbox, database, "dbx", &context, &SourceOptions::default())
    }

    #[test]
    fn a_listing_is_filtered_downloaded_and_indexed() {
        let mut dropbox = FakeDropbox::with(&[
            ("/Work/plan.md", PROSE),
            ("/Work/node_modules/pkg/readme.md", PROSE),
            ("/Work/.hidden/secret.md", PROSE),
            ("/Work/song.mp3", "ID3"),
            ("/Work/notes/Café.md", PROSE),
        ]);
        let mut database = Database::default();
        let outcome = run(&mut dropbox, &mut database, "/Work/").unwrap();
        assert!(outcome.completed);
        assert_eq!(database.documents, ["dropbox:/Work/plan.md", "dropbox:/Work/notes/Café.md"]);
        assert_eq!(database.finalized, Some(true));
        let scan = database.scan.unwrap();
        assert_eq!((scan.item_count, scan.details["root"].clone()), (2, json!("/Work")));
        assert_eq!(outcome.walk_stats.skipped_extension, 1);
        assert_eq!(outcome.walk_stats.skipped_excluded_dir, 2);
        assert_eq!(
            dropbox.requests,
            [
                "files/list_folder",
                "files/list_folder/continue",
                "files/list_folder/continue",
                "files/download",
                "files/download"
            ]
        );
        assert_eq!(dropbox.phases, ["scan", "ingest", "ingest"]);
    }

    #[test]
    fn an_unchanged_file_is_not_downloaded() {
        let mut dropbox = FakeDropbox::with(&[("/plan.md", PROSE)]);
        let mut database = Database::default();
        database.stats.insert(
            "dropbox:/plan.md".into(),
            ExistingStat {
                exists: true,
                byte_size: i64::try_from(PROSE.len()).unwrap(),
                mtime: parse_timestamp("2026-11-01T10:00:00Z").unwrap(),
                state: "OK".into(),
                ..ExistingStat::default()
            },
        );
        let outcome = run(&mut dropbox, &mut database, "/").unwrap();
        assert_eq!((outcome.counters.skipped, outcome.counters.indexed), (1, 0));
        assert_eq!(dropbox.requests, ["files/list_folder"]);
        assert_eq!(database.seen, ["dropbox:/plan.md"]);
    }

    #[test]
    fn an_expired_token_is_refreshed_once_and_a_throttle_waited_out() {
        let mut dropbox =
            FakeDropbox { expire_first_token: true, throttle_once: true, ..FakeDropbox::with(&[("/plan.md", PROSE)]) };
        let mut database = Database::default();
        run(&mut dropbox, &mut database, "/").unwrap();
        assert_eq!(dropbox.tokens_issued, 2);
        assert_eq!(dropbox.waits, [Duration::from_secs(3)]);
        assert_eq!(database.documents, ["dropbox:/plan.md"]);
    }

    #[test]
    fn a_missing_root_or_token_fails_the_run_before_the_scan_is_stored() {
        let mut dropbox = FakeDropbox { missing_root: true, ..FakeDropbox::with(&[("/plan.md", PROSE)]) };
        let mut database = Database::default();
        let outcome = run(&mut dropbox, &mut database, "/Gone");
        assert_eq!(outcome, Err(SourceError::Unavailable("/Gone is not in the Dropbox".into())));
        assert!(database.scan.is_none());
        assert_eq!(database.finalized, Some(false));

        let mut dropbox = FakeDropbox { no_token: true, ..FakeDropbox::with(&[("/plan.md", PROSE)]) };
        let outcome = run(&mut dropbox, &mut Database::default(), "/");
        assert_eq!(outcome, Err(SourceError::Unavailable("no Dropbox account is connected to Garage Door".into())));
        assert!(dropbox.requests.is_empty());
    }

    #[test]
    fn a_corrupt_download_fails_the_file_and_a_cancel_stops_the_run() {
        let mut dropbox = FakeDropbox {
            corrupt_downloads: true,
            cancel_after: Some(1),
            ..FakeDropbox::with(&[("/a.md", PROSE), ("/b.md", PROSE)])
        };
        let mut database = Database::default();
        let outcome = run(&mut dropbox, &mut database, "/").unwrap();
        assert_eq!(outcome.counters.failed, 1);
        assert!(outcome.counters.errors[0].contains("does not match Dropbox's content hash"));
        assert!(!outcome.completed);
        assert_eq!(database.finalized, Some(false));
        assert_eq!(dropbox.phases, ["scan", "ingest", "cancelled"]);
    }
}
