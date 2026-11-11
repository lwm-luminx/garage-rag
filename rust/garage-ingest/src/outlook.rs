//! An Outlook source read through Microsoft Graph (`/me/mailFolders`, `/me/messages`): the mail of the
//! signed-in Microsoft account (Outlook.com or Microsoft 365), folder by folder. Each message is
//! listed, compared with the database by its stat, and only a new or changed one is downloaded, as its
//! RFC 822 MIME (`/$value`), into memory and handed to the mail reader, which files it as a
//! `communication`: the egress rule then keeps it off any model server that is not loopback, exactly
//! as for an `.eml` on disk.
//!
//! Nothing here opens a connection or holds a credential: [`crate::onedrive`]'s Graph client carries
//! each request through the [`RemoteHost`] after [`check_destination`] approved it, and asks the host
//! for the token with `"service": "outlook"` (the store build's node links its Microsoft account
//! through Garage Door and keeps the token itself). A request carries folder and message ids, never a
//! message's text: content only comes in.
//!
//! The root is a folder path by display name (`Inbox/Projects`), a well-known folder name (`inbox`,
//! `sentitems`, `archive`) or a folder id, and every folder below it is read; `/` reads the whole
//! mailbox but Deleted Items, Junk Email, Drafts and the Outbox. Ids are Graph's immutable ids
//! (`Prefer: IdType="ImmutableId"`), so a message's URI, `outlook:` and its id, survives a move to
//! another folder.

use std::collections::VecDeque;
use std::ops::ControlFlow;
use std::path::PathBuf;

use serde_json::{Map, Value, json};

use crate::dropbox::{RemoteHost, keep};
use crate::onedrive::{ApiError, Client, DOWNLOAD_TIMEOUT, GRAPH, encode_path, parse_graph_time};
use crate::pipeline::{Context, FileCandidate, FileHost, IngestSettings, ReadOutcome, ingest_one};
use crate::sha256;
use crate::source::{ScanSummary, SourceError, SourceOptions, SourceRun, SourceStorage};
use crate::walk::WalkStats;

/// The source kind in `sources.kind`.
pub const KIND: &str = "outlook";
/// The URI scheme of a message's document.
pub const URI_PREFIX: &str = "outlook:";
/// The well-known folders the whole mailbox (`/`) leaves out.
pub const SKIPPED_FOLDERS: &[&str] = &["deleteditems", "junkemail", "drafts", "outbox"];
/// Items asked for per page.
const PAGE_LIMIT: u32 = 100;
/// MAPI's `PR_MESSAGE_SIZE`, the only size Graph v1.0 gives for a message.
const SIZE_PROPERTY: &str = "Integer 0x0E08";
/// Graph's immutable ids, which survive a move between folders.
const IMMUTABLE_IDS: (&str, &str) = ("Prefer", "IdType=\"ImmutableId\"");

/// Approves a request's destination: Graph's mail routes (`/v1.0/me/mailFolders`, `/v1.0/me/messages/`),
/// over HTTPS on the default port. Anything else is refused, whatever asked for it.
///
/// # Errors
///
/// The rule the URL broke.
pub fn check_destination(url: &str) -> Result<(), String> {
    let refuse = || format!("{url:?} is not an Outlook route; an Outlook source talks only to {GRAPH}/me/mailFolders");
    if url.contains(['#', '\\', ' ']) || url.contains("/../") || url.contains("/./") {
        return Err(refuse());
    }
    let path = url.strip_prefix(GRAPH).ok_or_else(refuse)?;
    let folders =
        path.strip_prefix("/me/mailFolders").is_some_and(|rest| rest.is_empty() || rest.starts_with(['/', '?']));
    if folders || path.starts_with("/me/messages/") { Ok(()) } else { Err(refuse()) }
}

/// One message in a listing.
#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    /// Graph's immutable id.
    pub id: String,
    /// The folder's path by display name, `/`-separated, then the id as an `.eml` file: what the
    /// walker's rules and the mail reader see.
    pub path: String,
    /// `PR_MESSAGE_SIZE`, or 1 when Graph gave none.
    pub size: u64,
    /// `lastModifiedDateTime`, in seconds since the epoch.
    pub modified: f64,
}

impl Message {
    /// The document's URI.
    #[must_use]
    pub fn uri(&self) -> String {
        format!("{URI_PREFIX}{}", self.id)
    }

    fn folder(&self) -> &str {
        self.path.rsplit_once('/').map_or("", |(folder, _)| folder)
    }
}

fn message(value: &Value, folder: &str) -> Option<Message> {
    let id = value.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())?;
    if value.get("isDraft").and_then(Value::as_bool) == Some(true) || id.contains(['/', '\\']) {
        return None;
    }
    let size = value
        .get("singleValueExtendedProperties")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|property| {
            property.get("id").and_then(Value::as_str).is_some_and(|id| id.eq_ignore_ascii_case(SIZE_PROPERTY))
        })
        .and_then(|property| property.get("value").and_then(Value::as_str))
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|size| *size > 0)
        .unwrap_or(1);
    Some(Message {
        id: id.to_owned(),
        path: format!("{folder}/{id}.eml"),
        size,
        modified: value.get("lastModifiedDateTime").and_then(Value::as_str).and_then(parse_graph_time).unwrap_or(0.0),
    })
}

/// A folder to read: its id and its path by display name.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Folder {
    id: String,
    path: String,
}

fn folder_url(id: &str) -> String {
    format!("{GRAPH}/me/mailFolders/{}", encode_path(id))
}

fn folders_query() -> String {
    format!("?$top={PAGE_LIMIT}&$select=id,displayName")
}

fn messages_query() -> String {
    format!(
        "?$top={PAGE_LIMIT}&$select=id,isDraft,lastModifiedDateTime\
         &$expand=singleValueExtendedProperties($filter=id%20eq%20'{}')",
        SIZE_PROPERTY.replace(' ', "%20")
    )
}

/// The mailbox, over Graph.
struct Mailbox<'h> {
    client: Client<'h>,
}

impl<'h> Mailbox<'h> {
    fn new(host: &'h mut dyn RemoteHost, slug: &str) -> Self {
        let headers = vec![(IMMUTABLE_IDS.0.to_owned(), IMMUTABLE_IDS.1.to_owned())];
        Self { client: Client::for_service(host, slug, KIND, "Outlook", check_destination, headers) }
    }

    /// Every item of a paged listing, until `each` stops it; false when it did.
    fn pages(&mut self, first: String, mut each: impl FnMut(&Value) -> ControlFlow<()>) -> Result<bool, ApiError> {
        let mut url = first;
        loop {
            let page = self.client.json(&url)?;
            for value in page.get("value").and_then(Value::as_array).into_iter().flatten() {
                if each(value).is_break() {
                    return Ok(false);
                }
            }
            match page.get("@odata.nextLink").and_then(Value::as_str) {
                Some(next) => next.clone_into(&mut url),
                None => return Ok(true),
            }
        }
    }

    /// The folders below `parent` (the mailbox's top level when `None`), with their paths below `path`.
    fn children(&mut self, parent: Option<&str>, path: &str) -> Result<Vec<Folder>, ApiError> {
        let url = match parent {
            None => format!("{GRAPH}/me/mailFolders{}", folders_query()),
            Some(id) => format!("{}/childFolders{}", folder_url(id), folders_query()),
        };
        let mut folders = Vec::new();
        self.pages(url, |value| {
            let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default();
            let (id, name) = (text("id"), text("displayName"));
            if !id.is_empty() && !name.is_empty() && !name.contains('/') {
                folders.push(Folder { id: id.to_owned(), path: format!("{path}/{name}") });
            }
            ControlFlow::Continue(())
        })?;
        Ok(folders)
    }

    /// One folder by a well-known name or an id, or `None` when the mailbox has no such folder.
    fn folder(&mut self, name: &str) -> Result<Option<Folder>, ApiError> {
        match self.client.json(&format!("{}?$select=id,displayName", folder_url(name))) {
            Ok(value) => {
                let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
                let (id, display) = (text("id"), text("displayName"));
                Ok((!id.is_empty())
                    .then(|| Folder { id, path: format!("/{}", if display.is_empty() { name } else { &display }) }))
            }
            Err(ApiError::NotFound(_)) => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// The ids of the folders the whole mailbox leaves out, those the mailbox has.
    fn skipped(&mut self) -> Result<Vec<String>, ApiError> {
        let mut ids = Vec::new();
        for name in SKIPPED_FOLDERS {
            if let Some(folder) = self.folder(name)? {
                ids.push(folder.id);
            }
        }
        Ok(ids)
    }

    /// The folders a root names: every top-level folder for `""`, else the folder at the display-name
    /// path, whose first part may also be a well-known name or an id.
    fn resolve(&mut self, root: &str) -> Result<Vec<Folder>, ApiError> {
        if root.is_empty() {
            return self.children(None, "");
        }
        let mut current: Option<Folder> = None;
        for part in root.split('/').filter(|part| !part.is_empty()) {
            let parent = current.as_ref().map(|folder| folder.id.clone());
            let path = current.as_ref().map_or(String::new(), |folder| folder.path.clone());
            let found = self
                .children(parent.as_deref(), &path)?
                .into_iter()
                .find(|folder| folder.path.rsplit('/').next().is_some_and(|name| name.eq_ignore_ascii_case(part)));
            current = match found {
                Some(folder) => Some(folder),
                None if current.is_none() => self.folder(part)?,
                None => None,
            };
            if current.is_none() {
                return Err(ApiError::NotFound(format!("no folder {part}")));
            }
        }
        Ok(current.into_iter().collect())
    }

    /// Lists every message in `start` and the folders below them, but `skipped`; `visit` may stop it.
    fn list(
        &mut self,
        start: Vec<Folder>,
        skipped: &[String],
        mut visit: impl FnMut(Message) -> ControlFlow<()>,
    ) -> Result<(bool, u64), ApiError> {
        let mut folders: VecDeque<Folder> = start.into_iter().filter(|folder| !skipped.contains(&folder.id)).collect();
        let mut listed = 0;
        while let Some(folder) = folders.pop_front() {
            listed += 1;
            let url = format!("{}/messages{}", folder_url(&folder.id), messages_query());
            let mut stopped = false;
            self.pages(url, |value| {
                let Some(message) = message(value, &folder.path) else { return ControlFlow::Continue(()) };
                let flow = visit(message);
                stopped = flow.is_break();
                flow
            })?;
            if stopped {
                return Ok((false, listed));
            }
            for child in self.children(Some(&folder.id), &folder.path)? {
                if !skipped.contains(&child.id) {
                    folders.push_back(child);
                }
            }
        }
        Ok((true, listed))
    }

    /// One message's MIME.
    fn download(&mut self, message: &Message) -> Result<Vec<u8>, ApiError> {
        let url = format!("{GRAPH}/me/messages/{}/$value", encode_path(&message.id));
        let reply = self.client.get(&url, true, DOWNLOAD_TIMEOUT)?;
        if reply.status != 200 {
            return Err(ApiError::Other(format!("Outlook answered the download of a message with {}", reply.status)));
        }
        Ok(reply.body)
    }
}

/// A message's MIME, downloaded once and read by the host's readers.
struct MailFiles<'m, 'h> {
    mailbox: &'m mut Mailbox<'h>,
    message: Message,
    bytes: Option<Result<Vec<u8>, String>>,
}

impl MailFiles<'_, '_> {
    fn bytes(&mut self) -> &Result<Vec<u8>, String> {
        if self.bytes.is_none() {
            self.bytes = Some(self.mailbox.download(&self.message).map_err(|error| error.to_string()));
        }
        self.bytes.as_ref().unwrap_or_else(|| unreachable!())
    }
}

impl FileHost for MailFiles<'_, '_> {
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
        self.mailbox.client.host().read_bytes(&candidate.path, &bytes)
    }
}

/// The root as registered, without its slashes: `""` for the whole mailbox.
fn mail_root(root: &str) -> String {
    root.trim().trim_matches('/').to_owned()
}

/// The root as a source shows it: `/` for the whole mailbox.
#[must_use]
pub fn display_root(root: &str) -> String {
    format!("/{}", mail_root(root))
}

/// Lists the source's folders, stores the scan, then decides each message as a walked source decides a
/// file: an unchanged one is skipped before it is downloaded.
///
/// # Errors
///
/// [`SourceError::Unavailable`] when the root cannot be listed (no token, no such folder, Graph
/// unreachable), and [`SourceError::Storage`] when the scan or the run's end could not be stored.
pub fn ingest_outlook_source(
    host: &mut dyn RemoteHost,
    storage: &mut dyn SourceStorage,
    slug: &str,
    context: &Context<'_>,
    options: &SourceOptions,
) -> Result<SourceRun, SourceError> {
    let mut run = SourceRun::default();
    let root = mail_root(&context.source.root.to_string_lossy());
    let started = std::time::Instant::now();
    let mut mailbox = Mailbox::new(host, slug);

    let mut messages = Vec::new();
    let mut stats = WalkStats::default();
    let listed = mailbox.skipped().and_then(|skipped| {
        let start = mailbox.resolve(&root)?;
        mailbox.list(start, &skipped, |message| {
            if keep(&message.path, message.size, "", context.policy, options, &mut stats) {
                messages.push(message);
            }
            ControlFlow::Continue(())
        })
    });
    match listed {
        Ok((_, folders)) => stats.dirs = folders,
        Err(error) => {
            let problem = match error {
                ApiError::NotFound(_) => format!("{} is not a folder in the mailbox", display_root(&root)),
                ApiError::Other(message) => message,
            };
            run.counters.note_error(problem.clone());
            storage.finalize(false, &run.counters, 0, 0).map_err(SourceError::Storage)?;
            return Err(SourceError::Unavailable(problem));
        }
    }
    run.walk_stats = stats;

    let mut details = Map::new();
    details.insert("remote".to_owned(), json!(KIND));
    details.insert("root".to_owned(), json!(display_root(&root)));
    let scan = ScanSummary {
        item_count: messages.len() as u64,
        item_type: "messages".to_owned(),
        duration_seconds: started.elapsed().as_secs_f64(),
        details,
        error: None,
    };
    storage.persist_scan(&scan).map_err(SourceError::Storage)?;
    mailbox.client.host().progress("scan", None, &run.counters);

    let settings = IngestSettings { index_images: false, ..context.settings.clone() };
    let context = Context { settings: &settings, ..*context };

    let mut stopped = false;
    for message in messages {
        let candidate = FileCandidate {
            path: PathBuf::from(&message.path),
            uri: message.uri(),
            size: message.size,
            mtime: message.modified,
            placeholder: false,
        };
        let name = message.folder().trim_start_matches('/').to_owned();
        if mailbox.client.host().cancelled() {
            mailbox.client.host().progress("cancelled", Some(&name), &run.counters);
            stopped = true;
            break;
        }
        run.counters.seen += 1;
        let outcome = storage.check_stat(&candidate.uri).and_then(|existing| {
            let mut files = MailFiles { mailbox: &mut mailbox, message, bytes: None };
            ingest_one(&mut files, storage, &existing, &candidate, &context, &mut run.counters)
        });
        if let Err(error) = outcome {
            run.counters.note_error(format!("a message in {name}: {error}"));
            let _ = storage.record_seen(&candidate.uri);
        }
        mailbox.client.host().progress("ingest", Some(&name), &run.counters);
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
    fn only_graph_mail_routes_are_approved() {
        for url in [
            "https://graph.microsoft.com/v1.0/me/mailFolders?$top=100",
            "https://graph.microsoft.com/v1.0/me/mailFolders/inbox?$select=id",
            "https://graph.microsoft.com/v1.0/me/mailFolders/AAMk%3D/messages?$skip=100",
            "https://graph.microsoft.com/v1.0/me/messages/AAMk%3D/$value",
        ] {
            assert!(check_destination(url).is_ok(), "{url}");
        }
        for url in [
            "http://graph.microsoft.com/v1.0/me/mailFolders",
            "https://graph.microsoft.com/v1.0/me/mailFoldersX",
            "https://graph.microsoft.com/v1.0/me/messages",
            "https://graph.microsoft.com/v1.0/me/sendMail",
            "https://graph.microsoft.com/v1.0/me/drive/root/children",
            "https://graph.microsoft.com/v1.0/me/mailFolders/../drive",
            "https://graph.microsoft.com/beta/me/mailFolders",
            "https://graph.microsoft.com.evil.example/v1.0/me/mailFolders",
            "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$filter=a eq b",
        ] {
            assert!(check_destination(url).is_err(), "{url}");
        }
    }

    #[test]
    fn a_message_is_read_from_graph_s_listing() {
        let value = json!({
            "id": "AAMk=", "isDraft": false, "lastModifiedDateTime": "2026-11-01T10:00:00Z",
            "singleValueExtendedProperties": [{"id": "Integer 0xe08", "value": "1234"}],
        });
        // Another property is not the size: the message still counts, as one byte.
        let mut message = message(&value, "/Inbox").unwrap();
        assert_eq!(message.size, 1);
        let value = json!({
            "id": "AAMk=", "lastModifiedDateTime": "2026-11-01T10:00:00Z",
            "singleValueExtendedProperties": [{"id": "Integer 0x0e08", "value": "1234"}],
        });
        message = super::message(&value, "/Inbox").unwrap();
        assert_eq!(
            (message.size, message.path.as_str(), message.uri()),
            (1234, "/Inbox/AAMk=.eml", "outlook:AAMk=".into())
        );
        assert!(super::message(&json!({"id": "A", "isDraft": true}), "").is_none());
        assert!(super::message(&json!({"id": "a/b"}), "").is_none());
        assert_eq!((display_root(""), display_root("/Inbox/Projects/")), ("/".into(), "/Inbox/Projects".into()));
    }

    /// A mailbox in memory: folders by path, each with its messages, listed two to a page.
    #[derive(Default)]
    struct FakeMailbox {
        /// (folder path, display name's id, messages as (id, MIME)).
        folders: Vec<(String, Vec<(String, String)>)>,
        requests: Vec<String>,
        immutable: bool,
        tokens: u32,
    }

    impl FakeMailbox {
        fn id(path: &str) -> String {
            format!("F{}", path.replace('/', "~"))
        }

        fn path(id: &str) -> String {
            id[1..].replace('~', "/")
        }

        fn children(&self, parent: &str) -> Vec<Value> {
            let mut out = Vec::new();
            for (path, _) in &self.folders {
                if let Some((dir, name)) = path.rsplit_once('/')
                    && dir == parent
                {
                    out.push(json!({"id": Self::id(path), "displayName": name}));
                }
            }
            out
        }

        fn paged(values: &[Value], url: &str, skip: usize) -> Vec<u8> {
            let to = (skip + 2).min(values.len());
            let mut page = json!({"value": values[skip..to]});
            if to < values.len() {
                let base = url.split('?').next().unwrap();
                page["@odata.nextLink"] = json!(format!("{base}?$skip={to}"));
            }
            page.to_string().into_bytes()
        }
    }

    fn reply(status: u16, body: impl Into<Vec<u8>>) -> HttpResponse {
        HttpResponse { status, headers: Vec::new(), body: body.into() }
    }

    impl RemoteHost for FakeMailbox {
        fn access_token(&mut self, service: &str, slug: &str, _: bool) -> Result<String, String> {
            assert_eq!((service, slug), (KIND, "mail"));
            self.tokens += 1;
            Ok("token".into())
        }

        fn send(&mut self, request: &HttpRequest) -> Result<HttpResponse, String> {
            check_destination(&request.url)?;
            self.immutable |=
                request.headers.iter().any(|(name, value)| name == "Prefer" && value.contains("ImmutableId"));
            let url = request.url.clone();
            let path =
                url.split('?').next().unwrap().strip_prefix(GRAPH).unwrap().replace("%3D", "=").replace("%20", " ");
            let skip: usize = url.split("$skip=").nth(1).map_or(0, |n| n.parse().unwrap());
            if let Some(id) = path.strip_prefix("/me/messages/").and_then(|rest| rest.strip_suffix("/$value")) {
                self.requests.push(format!("download {id}"));
                let mime = self.folders.iter().flat_map(|(_, messages)| messages).find(|(m, _)| m == id).unwrap();
                return Ok(reply(200, mime.1.clone()));
            }
            if path == "/me/mailFolders" {
                return Ok(reply(200, Self::paged(&self.children(""), &url, skip)));
            }
            let rest = path.strip_prefix("/me/mailFolders/").unwrap();
            let (id, tail) = rest.split_once('/').unwrap_or((rest, ""));
            let known = match id {
                "inbox" => Some("/Inbox"),
                "deleteditems" => Some("/Deleted Items"),
                "junkemail" | "drafts" | "outbox" => None,
                _ => Some(""),
            };
            let folder = match known {
                None => return Ok(reply(404, r#"{"error": {"code": "ErrorItemNotFound", "message": "none"}}"#)),
                Some("") => Self::path(id),
                Some(path) => path.to_owned(),
            };
            if !self.folders.iter().any(|(path, _)| *path == folder) {
                return Ok(reply(404, r#"{"error": {"code": "ErrorItemNotFound", "message": "none"}}"#));
            }
            match tail {
                "" => Ok(reply(
                    200,
                    json!({"id": Self::id(&folder), "displayName": folder.rsplit('/').next()}).to_string(),
                )),
                "childFolders" => Ok(reply(200, Self::paged(&self.children(&folder), &url, skip))),
                "messages" => {
                    self.requests.push(format!("list {folder}"));
                    let messages: Vec<Value> = self
                        .folders
                        .iter()
                        .find(|(path, _)| *path == folder)
                        .unwrap()
                        .1
                        .iter()
                        .map(|(id, mime)| json!({
                            "id": id, "lastModifiedDateTime": "2026-11-01T10:00:00Z",
                            "singleValueExtendedProperties": [{"id": SIZE_PROPERTY, "value": mime.len().to_string()}],
                        }))
                        .collect();
                    Ok(reply(200, Self::paged(&messages, &url, skip)))
                }
                other => panic!("unexpected {other}"),
            }
        }

        fn read_bytes(&mut self, path: &Path, bytes: &[u8]) -> ReadOutcome {
            assert_eq!(path.extension().unwrap(), "eml");
            ReadOutcome::Document(Extracted {
                text: String::from_utf8_lossy(bytes).into_owned(),
                kind: ContentKind::Conversation,
                extractor: "mail".into(),
                extractor_version: "1".into(),
                title: None,
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
        documents: Vec<(String, String)>,
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
            self.documents.push((uri.to_owned(), document.corpus_class.clone()));
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

    const MAIL: &str = "From: Ann <ann@example.com>\r\nSubject: The plan\r\n\r\nGarage keeps its index on the \
                        Mac. This note talks about the plan for the week, the people who will review it, and what \
                        is still open before we ship it.";

    fn mailbox() -> FakeMailbox {
        let mail = |id: &str| (id.to_owned(), MAIL.to_owned());
        FakeMailbox {
            folders: vec![
                ("/Inbox".into(), vec![mail("m1="), mail("m2"), mail("m3")]),
                ("/Inbox/Projects".into(), vec![mail("p1")]),
                ("/Deleted Items".into(), vec![mail("d1")]),
                ("/Sent Items".into(), vec![mail("s1")]),
            ],
            ..FakeMailbox::default()
        }
    }

    fn run(mail: &mut FakeMailbox, database: &mut Database, root: &str) -> Result<SourceRun, SourceError> {
        let source = SourceInfo {
            root: PathBuf::from(root),
            default_class: "communication".into(),
            default_trust: TrustTier::Received,
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
        ingest_outlook_source(mail, database, "mail", &context, &SourceOptions::default())
    }

    #[test]
    fn the_whole_mailbox_is_read_but_deleted_items() {
        let mut mail = mailbox();
        let mut database = Database::default();
        let outcome = run(&mut mail, &mut database, "/").unwrap();
        assert!(outcome.completed);
        let uris: Vec<&str> = database.documents.iter().map(|(uri, _)| uri.as_str()).collect();
        assert_eq!(uris, ["outlook:m1=", "outlook:m2", "outlook:m3", "outlook:s1", "outlook:p1"]);
        assert!(database.documents.iter().all(|(_, class)| class == "communication"));
        assert!(mail.immutable, "every signed request asks for immutable ids");
        assert!(!mail.requests.contains(&"list /Deleted Items".to_owned()));
        let scan = database.scan.unwrap();
        assert_eq!(
            (scan.item_count, scan.item_type.as_str(), scan.details["root"].clone()),
            (5, "messages", json!("/"))
        );
        assert_eq!(database.finalized, Some(true));
    }

    #[test]
    fn a_folder_path_reads_that_folder_and_below() {
        let mut mail = mailbox();
        let mut database = Database::default();
        run(&mut mail, &mut database, "inbox/projects").unwrap();
        assert_eq!(database.documents.iter().map(|(uri, _)| uri.as_str()).collect::<Vec<_>>(), ["outlook:p1"]);
        let mut database = Database::default();
        run(&mut mailbox(), &mut database, "Inbox").unwrap();
        assert_eq!(database.documents.len(), 4);
    }

    #[test]
    fn an_unchanged_message_is_not_downloaded() {
        let mut mail = mailbox();
        let mut database = Database::default();
        database.stats.insert(
            "outlook:p1".into(),
            ExistingStat {
                exists: true,
                byte_size: i64::try_from(MAIL.len()).unwrap(),
                mtime: parse_graph_time("2026-11-01T10:00:00Z").unwrap(),
                state: "OK".into(),
                // What the mail reader's chunks are: an `.eml` read by an older reader is read again.
                chunker: "conversation:1".into(),
                ..ExistingStat::default()
            },
        );
        let outcome = run(&mut mail, &mut database, "/Inbox/Projects").unwrap();
        assert_eq!((outcome.counters.skipped, outcome.counters.indexed), (1, 0));
        assert!(!mail.requests.iter().any(|request| request.starts_with("download")));
    }

    #[test]
    fn a_missing_folder_fails_the_run_before_the_scan_is_stored() {
        let mut mail = mailbox();
        let mut database = Database::default();
        let outcome = run(&mut mail, &mut database, "/Nowhere");
        assert_eq!(outcome, Err(SourceError::Unavailable("/Nowhere is not a folder in the mailbox".into())));
        assert!(database.scan.is_none());
        assert_eq!(database.finalized, Some(false));
    }
}
