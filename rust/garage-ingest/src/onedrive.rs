//! A OneDrive source read through Microsoft Graph (`/me/drive`), not through a synced folder: the
//! folder's tree is listed child by child, the files the walker's rules keep are compared with the
//! database by their stat, and only a new or changed file is downloaded, into memory, and handed to
//! the readers. The same drive serves OneDrive for Business, which lives in SharePoint.
//!
//! Nothing here opens a connection or holds a credential: the [`RemoteHost`] it shares with
//! [`crate::dropbox`] carries each request after [`check_destination`] approved it, and hands over
//! the access token (the store build's node links its Microsoft account through Garage Door, which
//! only relays Microsoft's answer, sealed to the node, and keeps and refreshes the token itself).
//! Graph answers a download with a redirect to a pre-authenticated URL on Microsoft's content hosts;
//! the host never follows it, so the client checks that URL here and asks for it without the token.
//! A request carries the source's paths and item ids, never a document's text: content only comes in.
//!
//! A file's URI is `onedrive:` and its path in the drive, so a renamed file is a new document and the
//! old one goes at reconcile, as for a folder. Pictures get no image chunk, since the image models
//! read files by path and these are not on disk.

use std::collections::VecDeque;
use std::ops::ControlFlow;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::dropbox::{HttpRequest, HttpResponse, RemoteHost, api_root, display_root, keep, parse_timestamp};
use crate::pipeline::{Context, FileCandidate, FileHost, IngestSettings, ReadOutcome, ingest_one};
use crate::sha256;
use crate::source::{ScanSummary, SourceError, SourceOptions, SourceRun, SourceStorage};
use crate::walk::{WalkStats, is_dependency_path, is_diagnostic_dir, is_hidden};

/// Microsoft Graph's origin and version.
pub const GRAPH: &str = "https://graph.microsoft.com/v1.0";
/// The source kind in `sources.kind`.
pub const KIND: &str = "onedrive";
/// The URI scheme of a OneDrive file's document.
pub const URI_PREFIX: &str = "onedrive:";
/// The hosts Graph redirects a download to (the suffix after a dot, or the whole host).
pub const CONTENT_HOSTS: &[&str] = &["sharepoint.com", "1drv.com", "livefilestore.com", "microsoftpersonalcontent.com"];
/// Children asked for per page (Graph's most is 999).
const PAGE_LIMIT: u32 = 999;
/// The fields a listing asks for.
const SELECT: &str = "id,name,size,file,folder,package,remoteItem,deleted,lastModifiedDateTime";
/// Tries of a request Graph asked to slow down (429, or 503 with `Retry-After`).
const RATE_LIMIT_TRIES: u32 = 4;
/// The longest wait honoured between them.
const LONGEST_WAIT: Duration = Duration::from_secs(60);
/// How long one listing call may take.
pub(crate) const LIST_TIMEOUT: Duration = Duration::from_secs(60);
/// How long one download may take.
pub(crate) const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(300);

/// Approves a request's destination: Graph's drive routes (`/v1.0/me/drive/`, `/v1.0/drives/`) and
/// the content hosts a download redirects to, over HTTPS on the default port. Anything else is
/// refused, whatever asked for it.
///
/// # Errors
///
/// The rule the URL broke.
pub fn check_destination(url: &str) -> Result<(), String> {
    let refuse = || {
        format!(
            "{url:?} is not a OneDrive route; a OneDrive source talks only to {GRAPH}/me/drive/ and Microsoft's \
             content hosts"
        )
    };
    if url.contains(['#', '\\', ' ']) || url.contains("/../") || url.contains("/./") {
        return Err(refuse());
    }
    if let Some(path) = url.strip_prefix(GRAPH)
        && (path.starts_with("/me/drive/") || path.starts_with("/drives/"))
    {
        return Ok(());
    }
    let rest = url.strip_prefix("https://").ok_or_else(refuse)?;
    let host = rest.split(['/', '?']).next().unwrap_or_default();
    let host_ok = !host.is_empty()
        && host.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'.')
        && CONTENT_HOSTS.iter().any(|suffix| {
            host.eq_ignore_ascii_case(suffix)
                || host.len() > suffix.len() + 1
                    && host[host.len() - suffix.len()..].eq_ignore_ascii_case(suffix)
                    && host.as_bytes()[host.len() - suffix.len() - 1] == b'.'
        });
    if host_ok && rest[host.len()..].starts_with('/') { Ok(()) } else { Err(refuse()) }
}

/// One file in a listing.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// The drive item's id.
    pub id: String,
    /// The path in the drive, `/`-separated from its root.
    pub path_display: String,
    /// Its size.
    pub size: u64,
    /// `lastModifiedDateTime`, in seconds since the epoch.
    pub modified: f64,
    /// Graph's QuickXorHash, base64, when it gave one.
    pub quick_xor_hash: String,
}

impl Entry {
    /// The document's URI.
    #[must_use]
    pub fn uri(&self) -> String {
        format!("{URI_PREFIX}{}", self.path_display)
    }

    fn name(&self) -> &str {
        self.path_display.rsplit('/').next().unwrap_or_default()
    }
}

/// One child of a folder: a file, a folder to descend, or something else (a OneNote notebook, a
/// shortcut to another drive, a deleted item), which is passed over.
enum Child {
    File(Entry),
    Folder { id: String, path: String },
    Other,
}

fn child(value: &Value, parent: &str) -> Child {
    let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    let (id, name) = (text("id"), text("name"));
    if id.is_empty()
        || name.is_empty()
        || ["package", "remoteItem", "deleted"].iter().any(|key| value.get(key).is_some())
    {
        return Child::Other;
    }
    let path = format!("{parent}/{name}");
    if value.get("folder").is_some() {
        return Child::Folder { id, path };
    }
    let Some(file) = value.get("file") else { return Child::Other };
    Child::File(Entry {
        id,
        path_display: path,
        size: value.get("size").and_then(Value::as_u64).unwrap_or(0),
        modified: value.get("lastModifiedDateTime").and_then(Value::as_str).and_then(parse_graph_time).unwrap_or(0.0),
        quick_xor_hash: file.pointer("/hashes/quickXorHash").and_then(Value::as_str).unwrap_or_default().to_owned(),
    })
}

/// Graph's `YYYY-MM-DDTHH:MM:SS[.fff]Z` as seconds since the epoch; the fraction is dropped, as a
/// file system's whole-second stat would.
#[must_use]
pub fn parse_graph_time(text: &str) -> Option<f64> {
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

/// Microsoft's QuickXorHash of `bytes` (learn.microsoft.com/onedrive/developer/code-snippets/quickxorhash),
/// base64: each byte XORed into a 160-bit register at a position that moves 11 bits per byte, then
/// the length XORed into its last 64 bits.
#[must_use]
pub fn quick_xor_hash(bytes: &[u8]) -> String {
    const WIDTH_BITS: usize = 160;
    const SHIFT: usize = 11;
    // A byte's bits start at `(index * 11) % 160`, so bytes 160 apart land on the same place: fold first.
    let mut folded = [0u8; WIDTH_BITS];
    for (index, byte) in bytes.iter().enumerate() {
        folded[index % WIDTH_BITS] ^= byte;
    }
    let mut register = [0u8; WIDTH_BITS / 8];
    for (index, byte) in folded.iter().enumerate() {
        let bit = (index * SHIFT) % WIDTH_BITS;
        let (at, offset) = (bit / 8, bit % 8);
        let wide = u16::from(*byte) << offset;
        register[at] ^= wide.to_le_bytes()[0];
        register[(at + 1) % register.len()] ^= wide.to_le_bytes()[1];
    }
    let length = (bytes.len() as u64).to_le_bytes();
    let start = register.len() - length.len();
    for (index, byte) in length.iter().enumerate() {
        register[start + index] ^= byte;
    }
    base64(&register)
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for group in bytes.chunks(3) {
        let value =
            group.iter().enumerate().fold(0u32, |value, (index, byte)| value | u32::from(*byte) << (16 - 8 * index));
        for index in 0..4 {
            if index <= group.len() {
                out.push(char::from(ALPHABET[(value >> (18 - 6 * index)) as usize & 63]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// `path` with every byte that is not unreserved percent-encoded, `/` kept: a drive path in a URL.
#[must_use]
pub fn encode_path(path: &str) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(path.len());
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~/".contains(&byte) {
            out.push(char::from(byte));
        } else {
            let _ = write!(out, "%{byte:02X}");
        }
    }
    out
}

/// A failed Graph call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApiError {
    /// The item is gone or never was (404, `itemNotFound`).
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

/// Graph's calls, with the token, the refresh after a 401 and the waits Graph asks for. A OneDrive
/// source's by default; [`crate::outlook`] makes one for its own routes with [`Client::for_service`].
pub struct Client<'h> {
    host: &'h mut dyn RemoteHost,
    slug: String,
    token: Option<String>,
    service: &'static str,
    label: &'static str,
    check: fn(&str) -> Result<(), String>,
    headers: Vec<(String, String)>,
}

impl<'h> Client<'h> {
    /// A client for the OneDrive source `slug`, asking `host` for its token when first needed.
    pub fn new(host: &'h mut dyn RemoteHost, slug: &str) -> Self {
        Self::for_service(host, slug, KIND, "OneDrive", check_destination, Vec::new())
    }

    /// A Graph client for another source kind: its token is asked for as `service`, every URL must pass
    /// `check`, its errors name `label`, and `headers` go on every signed request.
    pub(crate) fn for_service(
        host: &'h mut dyn RemoteHost,
        slug: &str,
        service: &'static str,
        label: &'static str,
        check: fn(&str) -> Result<(), String>,
        headers: Vec<(String, String)>,
    ) -> Self {
        Self { host, slug: slug.to_owned(), token: None, service, label, check, headers }
    }

    /// The host, between calls.
    pub fn host(&mut self) -> &mut dyn RemoteHost {
        self.host
    }

    /// A `GET` of `url`, with the bearer token when `signed` (Graph) and without it (a content host's
    /// pre-authenticated URL). Returns a 2xx or 3xx reply; anything else is the error.
    pub(crate) fn get(&mut self, url: &str, signed: bool, timeout: Duration) -> Result<HttpResponse, ApiError> {
        (self.check)(url).map_err(ApiError::Other)?;
        let mut refreshed = false;
        let mut tries = 0;
        loop {
            let mut headers = Vec::new();
            if signed {
                let token = if let Some(token) = &self.token {
                    token.clone()
                } else {
                    let token = self.host.access_token(self.service, &self.slug, refreshed).map_err(ApiError::Other)?;
                    self.token = Some(token.clone());
                    token
                };
                headers.push(("Authorization".to_owned(), format!("Bearer {token}")));
                headers.extend(self.headers.iter().cloned());
            }
            let request = HttpRequest { method: "GET", url: url.to_owned(), headers, body: Vec::new(), timeout };
            let label = self.label;
            let response = self.host.send(&request).map_err(|error| ApiError::Other(format!("{label}: {error}")))?;
            match response.status {
                200..=399 => return Ok(response),
                401 if signed && !refreshed => {
                    // Expired or revoked: one new token, then the reply stands.
                    refreshed = true;
                    self.token = None;
                }
                429 | 503 if tries + 1 < RATE_LIMIT_TRIES => {
                    tries += 1;
                    let wait = header(&response, "Retry-After")
                        .and_then(|value| value.trim().parse::<u64>().ok())
                        .map_or(Duration::from_secs(1 << tries), Duration::from_secs)
                        .min(LONGEST_WAIT);
                    self.host.wait(wait);
                }
                _ => return Err(api_error(&response, self.label)),
            }
        }
    }

    pub(crate) fn json(&mut self, url: &str) -> Result<Value, ApiError> {
        let reply = self.get(url, true, LIST_TIMEOUT)?;
        let label = self.label;
        if reply.status != 200 {
            return Err(ApiError::Other(format!("{label} answered a listing with {}", reply.status)));
        }
        serde_json::from_slice(&reply.body)
            .map_err(|error| ApiError::Other(format!("{label} sent a listing that is not JSON: {error}")))
    }

    /// Lists every file below `root` (an API root, `""` for the whole drive), folder by folder;
    /// `descend` decides, by its path and name, whether a folder is listed, and `visit` may stop the
    /// listing.
    ///
    /// # Errors
    ///
    /// [`ApiError::NotFound`] when the root is not in the drive, else the call's failure.
    pub fn list(
        &mut self,
        root: &str,
        mut descend: impl FnMut(&str) -> bool,
        mut visit: impl FnMut(Entry) -> ControlFlow<()>,
    ) -> Result<bool, ApiError> {
        let query = format!("?$top={PAGE_LIMIT}&$select={SELECT}");
        let first = if root.is_empty() {
            format!("{GRAPH}/me/drive/root/children{query}")
        } else {
            format!("{GRAPH}/me/drive/root:{}:/children{query}", encode_path(root))
        };
        let mut folders = VecDeque::from([(first, root.to_owned())]);
        while let Some((mut url, parent)) = folders.pop_front() {
            loop {
                let page = self.json(&url)?;
                for value in page.get("value").and_then(Value::as_array).into_iter().flatten() {
                    match child(value, &parent) {
                        Child::File(entry) => {
                            if visit(entry).is_break() {
                                return Ok(false);
                            }
                        }
                        Child::Folder { id, path } if descend(&path) => {
                            folders.push_back((
                                format!("{GRAPH}/me/drive/items/{}/children{query}", encode_path(&id)),
                                path,
                            ));
                        }
                        Child::Folder { .. } | Child::Other => {}
                    }
                }
                match page.get("@odata.nextLink").and_then(Value::as_str) {
                    Some(next) => next.clone_into(&mut url),
                    None => break,
                }
            }
        }
        Ok(true)
    }

    /// Downloads one file's bytes, checked against its QuickXorHash when the listing gave one: Graph's
    /// `content` route answers with a redirect to a pre-authenticated URL, fetched without the token.
    ///
    /// # Errors
    ///
    /// The call's failure, a redirect elsewhere, or bytes that do not match the hash.
    pub fn download(&mut self, entry: &Entry) -> Result<Vec<u8>, ApiError> {
        let content = format!("{GRAPH}/me/drive/items/{}/content", encode_path(&entry.id));
        let mut reply = self.get(&content, true, DOWNLOAD_TIMEOUT)?;
        if (300..400).contains(&reply.status) {
            let location = header(&reply, "Location")
                .ok_or_else(|| ApiError::Other(format!("OneDrive redirected {} to nowhere", entry.path_display)))?
                .to_owned();
            reply = self.get(&location, false, DOWNLOAD_TIMEOUT)?;
        }
        if reply.status != 200 {
            return Err(ApiError::Other(format!(
                "OneDrive answered the download of {} with {}",
                entry.path_display, reply.status
            )));
        }
        if !entry.quick_xor_hash.is_empty() && quick_xor_hash(&reply.body) != entry.quick_xor_hash {
            return Err(ApiError::Other(format!(
                "the download of {} does not match OneDrive's QuickXorHash",
                entry.path_display
            )));
        }
        Ok(reply.body)
    }
}

pub(crate) fn header<'r>(response: &'r HttpResponse, name: &str) -> Option<&'r str> {
    response.headers.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
}

fn api_error(response: &HttpResponse, label: &str) -> ApiError {
    let body: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
    let code = body.pointer("/error/code").and_then(Value::as_str).unwrap_or_default();
    let message = body
        .pointer("/error/message")
        .and_then(Value::as_str)
        .map_or_else(|| String::from_utf8_lossy(&response.body).chars().take(200).collect(), str::to_owned);
    if response.status == 404 || code == "itemNotFound" {
        return ApiError::NotFound(format!("{label} has no such item ({message})"));
    }
    let what = match response.status {
        401 => "refused the access token",
        403 => "refused the request",
        429 => "is rate limiting this app",
        400 => "rejected the request",
        _ => "answered",
    };
    let detail = if code.is_empty() { message } else { format!("{code}: {message}") };
    ApiError::Other(format!("{label} {what} ({}): {detail}", response.status))
}

/// Whether the walker's rules descend into the folder at `path` (below `root`); a folder they skip
/// is counted once, and none of it is listed.
fn descend(path: &str, root: &str, policy: &crate::policy::WalkPolicy, stats: &mut WalkStats) -> bool {
    let relative = path.get(root.len()..).unwrap_or(path);
    let name = relative.rsplit('/').next().unwrap_or_default();
    if policy.exclude_dirs.contains(name) || is_hidden(name) || name.eq_ignore_ascii_case(".git") {
        stats.skipped_excluded_dir += 1;
        return false;
    }
    if is_diagnostic_dir(name, policy) {
        stats.skipped_diagnostic += 1;
        return false;
    }
    if is_dependency_path(&format!("{relative}/"), policy) {
        stats.skipped_excluded_dir += 1;
        return false;
    }
    stats.dirs += 1;
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
/// `context.source.root` is the folder in the drive the source registered; the context's git
/// history is not consulted, since nothing is on disk. The scan stored is the listing's.
///
/// # Errors
///
/// [`SourceError::Unavailable`] when the root cannot be listed (no token, not in the drive, Graph
/// unreachable), and [`SourceError::Storage`] when the scan or the run's end could not be stored.
pub fn ingest_onedrive_source(
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
    let mut stats = WalkStats { dirs: 1, ..WalkStats::default() };
    let mut folder_stats = WalkStats::default();
    let listed = client.list(
        &root,
        |path| descend(path, &root, context.policy, &mut folder_stats),
        |entry| {
            if keep(&entry.path_display, entry.size, &root, context.policy, options, &mut stats) {
                entries.push(entry);
            }
            ControlFlow::Continue(())
        },
    );
    if let Err(error) = listed {
        let problem = match error {
            ApiError::NotFound(_) => format!("{} is not in the OneDrive", display_root(&root)),
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
    use std::path::Path;

    use super::*;
    use crate::attribution::{NoGit, SelfIdentity, TrustTier};
    use crate::chunking::ContentKind;
    use crate::pipeline::{Counters, DocumentPayload, ExistingStat, Extracted, SourceInfo, Storage};
    use crate::policy::WalkPolicy;

    #[test]
    fn only_graph_drive_routes_and_content_hosts_are_approved() {
        for url in [
            "https://graph.microsoft.com/v1.0/me/drive/root/children?$top=999",
            "https://graph.microsoft.com/v1.0/me/drive/root:/Work%20Notes:/children",
            "https://graph.microsoft.com/v1.0/drives/b!abc/items/01X/children?$skiptoken=x",
            "https://contoso-my.sharepoint.com/personal/a/_layouts/15/download.aspx?UniqueId=1&tempauth=t",
            "https://public.am.files.1drv.com/y4m/file.md?download",
            "https://my.microsoftpersonalcontent.com/personal/abc/_layouts/15/download.aspx?x=1",
        ] {
            assert!(check_destination(url).is_ok(), "{url}");
        }
        for url in [
            "http://graph.microsoft.com/v1.0/me/drive/root/children",
            "https://graph.microsoft.com/v1.0/me/messages",
            "https://graph.microsoft.com/beta/me/drive/root/children",
            "https://graph.microsoft.com/v1.0/me/drive/../messages",
            "https://graph.microsoft.com.evil.example/v1.0/me/drive/",
            "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            "https://evilsharepoint.com/download",
            "https://sharepoint.com.evil.example/download",
            "https://contoso.sharepoint.com:8443/download",
            "https://user@contoso.sharepoint.com/download",
            "https://contoso.sharepoint.com",
            "http://localhost:11434/v1.0/me/drive/",
        ] {
            assert!(check_destination(url).is_err(), "{url}");
        }
    }

    #[test]
    fn the_quick_xor_hash_is_microsoft_s() {
        // rclone's vectors (backend/onedrive/quickxorhash), input and hash both base64.
        let decode = |text: &str| -> Vec<u8> {
            let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            let mut bits = 0u32;
            let mut count = 0;
            let mut out = Vec::new();
            for byte in text.bytes().filter(|byte| *byte != b'=') {
                bits = bits << 6 | u32::try_from(alphabet.iter().position(|a| *a == byte).unwrap()).unwrap();
                count += 6;
                if count >= 8 {
                    count -= 8;
                    out.push(u8::try_from(bits >> count & 0xff).unwrap());
                }
            }
            out
        };
        for (input, hash) in [
            ("", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="),
            ("Sg==", "SgAAAAAAAAAAAAAAAQAAAAAAAAA="),
            ("tbQ=", "taAFAAAAAAAAAAAAAgAAAAAAAAA="),
            ("h490d57Pqz5q2rtT", "h3gEHe7giWeswgdq3MYupgAAAAA="),
            ("2fuxhBJXtpWFe8dOfdGeHw==", "O9tHLAghgSvYohKFyMMxnNCHaHg="),
            (
                "C16uQlxsHxMWnV2gJhFPuJ2/guZ4N1YgmNvAwL1yrouGQtwieGx8WvZsmYRnX72JnbVtTw==",
                "QtlSNqXhVij64MMhKJ3EsDFB/z8=",
            ),
        ] {
            assert_eq!(quick_xor_hash(&decode(input)), hash, "{input}");
        }
        // Longer than the register, so bytes fold onto each other.
        let long: Vec<u8> = (0..1000u32).map(|index| u8::try_from(index % 251).unwrap()).collect();
        let mut naive = [0u8; 20];
        for (index, byte) in long.iter().enumerate() {
            let bit = (index * 11) % 160;
            for offset in 0..8 {
                if byte >> offset & 1 == 1 {
                    let at = (bit + offset) % 160;
                    naive[at / 8] ^= 1 << (at % 8);
                }
            }
        }
        for (index, byte) in 1000u64.to_le_bytes().iter().enumerate() {
            naive[12 + index] ^= byte;
        }
        assert_eq!(quick_xor_hash(&long), base64(&naive));
    }

    #[test]
    #[allow(clippy::float_cmp)]
    fn graph_times_and_paths_are_read_as_graph_writes_them() {
        assert_eq!(parse_graph_time("2015-05-12T15:50:38Z"), Some(1_431_445_838.0));
        assert_eq!(parse_graph_time("2015-05-12T15:50:38.123Z"), Some(1_431_445_838.0));
        assert_eq!(parse_graph_time("2015-05-12T15:50:38.1x3Z"), None);
        assert_eq!(encode_path("/Work Notes/Café"), "/Work%20Notes/Caf%C3%A9");
        assert_eq!(encode_path("/a#b?c"), "/a%23b%3Fc");
    }

    /// A drive in memory: `files` by path, children listed two to a page.
    #[derive(Default)]
    #[allow(clippy::struct_excessive_bools)]
    struct FakeGraph {
        files: Vec<(String, Vec<u8>)>,
        corrupt_downloads: bool,
        expire_first_token: bool,
        throttle_once: bool,
        missing_root: bool,
        tokens_issued: u32,
        requests: Vec<String>,
        waits: Vec<Duration>,
        cancel_after: Option<usize>,
        asked: usize,
        phases: Vec<String>,
    }

    impl FakeGraph {
        fn with(files: &[(&str, &str)]) -> Self {
            Self {
                files: files.iter().map(|(path, text)| ((*path).to_owned(), text.as_bytes().to_vec())).collect(),
                ..Self::default()
            }
        }

        /// The children of the folder `path`: its files, then its folders (ids are their paths).
        fn children(&self, path: &str) -> Vec<Value> {
            let prefix = format!("{path}/");
            let mut folders = Vec::new();
            let mut values = Vec::new();
            for (index, (file, bytes)) in self.files.iter().enumerate() {
                let Some(rest) = file.strip_prefix(&prefix) else { continue };
                match rest.split_once('/') {
                    None => values.push(json!({
                        "id": format!("F{index}"), "name": rest, "size": bytes.len(),
                        "lastModifiedDateTime": "2026-11-01T10:00:00.5Z",
                        "file": {"mimeType": "text/plain", "hashes": {"quickXorHash": quick_xor_hash(bytes)}},
                    })),
                    Some((folder, _)) if !folders.contains(&folder.to_owned()) => folders.push(folder.to_owned()),
                    Some(_) => {}
                }
            }
            for folder in folders {
                values.push(json!({"id": format!("D{prefix}{folder}"), "name": folder, "folder": {"childCount": 1}}));
            }
            values.push(json!({"id": "N1", "name": "Notebook", "package": {"type": "oneNote"}}));
            values
        }

        fn page(&self, folder: &str, from: usize) -> Vec<u8> {
            let children = self.children(folder);
            let to = (from + 2).min(children.len());
            let mut page = json!({ "value": children[from..to] });
            if to < children.len() {
                page["@odata.nextLink"] = json!(format!(
                    "{GRAPH}/drives/b!x/items/{}/children?$skiptoken={to}",
                    encode_path(&format!("D{folder}"))
                ));
            }
            page.to_string().into_bytes()
        }
    }

    fn reply(status: u16, body: impl Into<Vec<u8>>) -> HttpResponse {
        HttpResponse { status, headers: Vec::new(), body: body.into() }
    }

    fn decode_path(text: &str) -> String {
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

    impl RemoteHost for FakeGraph {
        fn access_token(&mut self, service: &str, slug: &str, _refresh: bool) -> Result<String, String> {
            assert_eq!((service, slug), (KIND, "od"));
            self.tokens_issued += 1;
            Ok(format!("token-{}", self.tokens_issued))
        }

        fn send(&mut self, request: &HttpRequest) -> Result<HttpResponse, String> {
            assert_eq!(request.method, "GET");
            check_destination(&request.url)?;
            let url = request.url.clone();
            let signed = request.headers.iter().any(|(name, _)| name == "Authorization");
            if let Some(index) = url.strip_prefix("https://contoso-my.sharepoint.com/download/") {
                assert!(!signed, "the token never goes to a content host");
                self.requests.push("content".into());
                let mut bytes = self.files[index.parse::<usize>().unwrap()].1.clone();
                if self.corrupt_downloads {
                    bytes.push(b'!');
                }
                return Ok(reply(200, bytes));
            }
            assert!(signed);
            if self.expire_first_token && request.headers[0].1 == "Bearer token-1" {
                return Ok(reply(401, r#"{"error": {"code": "InvalidAuthenticationToken", "message": "expired"}}"#));
            }
            if self.throttle_once {
                self.throttle_once = false;
                return Ok(HttpResponse {
                    status: 429,
                    headers: vec![("retry-after".into(), "3".into())],
                    body: Vec::new(),
                });
            }
            let path = url.split('?').next().unwrap().strip_prefix(GRAPH).unwrap().to_owned();
            let skip: usize = url.split("$skiptoken=").nth(1).map_or(0, |token| token.parse().unwrap());
            if let Some(id) = path.strip_prefix("/me/drive/items/").and_then(|rest| rest.strip_suffix("/content")) {
                self.requests.push("download".into());
                let index = &id[1..];
                return Ok(HttpResponse {
                    status: 302,
                    headers: vec![("Location".into(), format!("https://contoso-my.sharepoint.com/download/{index}"))],
                    body: Vec::new(),
                });
            }
            self.requests.push("children".into());
            let folder = if path == "/me/drive/root/children" {
                String::new()
            } else if let Some(root) =
                path.strip_prefix("/me/drive/root:").and_then(|rest| rest.strip_suffix(":/children"))
            {
                let root = decode_path(root);
                if self.missing_root {
                    return Ok(reply(404, r#"{"error": {"code": "itemNotFound", "message": "gone"}}"#));
                }
                root
            } else {
                let id = path
                    .strip_prefix("/me/drive/items/")
                    .or_else(|| path.strip_prefix("/drives/b!x/items/"))
                    .and_then(|rest| rest.strip_suffix("/children"))
                    .unwrap();
                decode_path(id)[1..].to_owned()
            };
            Ok(reply(200, self.page(&folder, skip)))
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

    fn run(graph: &mut FakeGraph, database: &mut Database, root: &str) -> Result<SourceRun, SourceError> {
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
        ingest_onedrive_source(graph, database, "od", &context, &SourceOptions::default())
    }

    #[test]
    fn a_tree_is_listed_pruned_downloaded_and_indexed() {
        let mut graph = FakeGraph::with(&[
            ("/Work/plan.md", PROSE),
            ("/Work/song.mp3", "ID3"),
            ("/Work/node_modules/pkg/readme.md", PROSE),
            ("/Work/.hidden/secret.md", PROSE),
            ("/Work/notes/Café.md", PROSE),
            ("/Elsewhere/other.md", PROSE),
        ]);
        let mut database = Database::default();
        let outcome = run(&mut graph, &mut database, "/Work/").unwrap();
        assert!(outcome.completed);
        assert_eq!(database.documents, ["onedrive:/Work/plan.md", "onedrive:/Work/notes/Café.md"]);
        assert_eq!(database.finalized, Some(true));
        let scan = database.scan.unwrap();
        assert_eq!((scan.item_count, scan.details["root"].clone()), (2, json!("/Work")));
        assert_eq!(outcome.walk_stats.skipped_extension, 1);
        // node_modules and .hidden are never listed.
        assert_eq!(outcome.walk_stats.skipped_excluded_dir, 2);
        assert_eq!(graph.requests.iter().filter(|request| *request == "children").count(), 4);
        assert_eq!(graph.requests.iter().filter(|request| *request == "content").count(), 2);
        assert_eq!(graph.phases, ["scan", "ingest", "ingest"]);
    }

    #[test]
    fn an_unchanged_file_is_not_downloaded() {
        let mut graph = FakeGraph::with(&[("/plan.md", PROSE)]);
        let mut database = Database::default();
        database.stats.insert(
            "onedrive:/plan.md".into(),
            ExistingStat {
                exists: true,
                byte_size: i64::try_from(PROSE.len()).unwrap(),
                mtime: parse_timestamp("2026-11-01T10:00:00Z").unwrap(),
                state: "OK".into(),
                ..ExistingStat::default()
            },
        );
        let outcome = run(&mut graph, &mut database, "/").unwrap();
        assert_eq!((outcome.counters.skipped, outcome.counters.indexed), (1, 0));
        assert_eq!(graph.requests, ["children"]);
        assert_eq!(database.seen, ["onedrive:/plan.md"]);
    }

    #[test]
    fn an_expired_token_is_refreshed_once_and_a_throttle_waited_out() {
        let mut graph =
            FakeGraph { expire_first_token: true, throttle_once: true, ..FakeGraph::with(&[("/plan.md", PROSE)]) };
        let mut database = Database::default();
        run(&mut graph, &mut database, "/").unwrap();
        assert_eq!(graph.tokens_issued, 2);
        assert_eq!(graph.waits, [Duration::from_secs(3)]);
        assert_eq!(database.documents, ["onedrive:/plan.md"]);
    }

    #[test]
    fn a_missing_root_fails_the_run_before_the_scan_is_stored() {
        let mut graph = FakeGraph { missing_root: true, ..FakeGraph::with(&[("/plan.md", PROSE)]) };
        let mut database = Database::default();
        let outcome = run(&mut graph, &mut database, "/Gone");
        assert_eq!(outcome, Err(SourceError::Unavailable("/Gone is not in the OneDrive".into())));
        assert!(database.scan.is_none());
        assert_eq!(database.finalized, Some(false));
    }

    #[test]
    fn a_corrupt_download_fails_the_file_and_a_cancel_stops_the_run() {
        let mut graph = FakeGraph {
            corrupt_downloads: true,
            cancel_after: Some(1),
            ..FakeGraph::with(&[("/a.md", PROSE), ("/b.md", PROSE)])
        };
        let mut database = Database::default();
        let outcome = run(&mut graph, &mut database, "/").unwrap();
        assert_eq!(outcome.counters.failed, 1);
        assert!(outcome.counters.errors[0].contains("does not match OneDrive's QuickXorHash"));
        assert!(!outcome.completed);
        assert_eq!(graph.phases, ["scan", "ingest", "cancelled"]);
    }
}
