//! A Gmail source read through the Gmail API (`/gmail/v1/users/me`): the messages under one label (or
//! the whole mailbox but spam, trash, drafts and chats), each fetched once as its RFC 822 MIME
//! (`format=raw`) into memory and handed to the mail reader, which files it as a `communication`: the
//! egress rule then keeps it off any model server that is not loopback, exactly as for an `.eml` on
//! disk.
//!
//! A Gmail message never changes after it arrives (only its labels do), so a message the database
//! already holds is skipped by its id alone, without a request: each one's stat is the same fixed
//! size and time, which an indexed row matches.
//!
//! Nothing here opens a connection or holds a credential: [`crate::onedrive`]'s client carries each
//! request through the [`RemoteHost`] after [`check_destination`] approved it, and asks the host for
//! the token with `"service": "gmail"` (the store build's node links its Google account through Garage
//! Door, which redeems Google's code, seals the tokens to the node and keeps none). A request carries
//! label and message ids, never a message's text: content only comes in.

use std::ops::ControlFlow;
use std::path::PathBuf;

use serde_json::{Map, Value, json};

use crate::dropbox::{RemoteHost, keep};
use crate::onedrive::{ApiError, Client, DOWNLOAD_TIMEOUT, encode_path};
use crate::pipeline::{Context, FileCandidate, FileHost, IngestSettings, ReadOutcome, ingest_one};
use crate::sha256;
use crate::source::{ScanSummary, SourceError, SourceOptions, SourceRun, SourceStorage};
use crate::walk::WalkStats;

/// The Gmail API's routes for the signed-in account.
pub const API: &str = "https://gmail.googleapis.com/gmail/v1/users/me";
/// The source kind in `sources.kind`.
pub const KIND: &str = "gmail";
/// The URI scheme of a message's document.
pub const URI_PREFIX: &str = "gmail:";
/// What the whole mailbox (`/`) leaves out, as a Gmail search (spam and trash are left out anyway).
const ALL_MAIL: &str = "-in:drafts -in:chats";
/// Messages asked for per page (Gmail's most is 500).
const PAGE_SIZE: u32 = 500;
/// The stat every message has: it never changes, so an indexed one is never fetched again.
const FIXED_SIZE: u64 = 1;
const FIXED_TIME: f64 = 1.0;

/// Approves a request's destination: the Gmail API's `messages` and `labels` routes for the
/// signed-in account, over HTTPS on the default port. Anything else is refused, whatever asked for it.
///
/// # Errors
///
/// The rule the URL broke.
pub fn check_destination(url: &str) -> Result<(), String> {
    let refuse = || format!("{url:?} is not a Gmail route; a Gmail source talks only to {API}/messages and /labels");
    if url.contains(['#', '\\', ' ']) || url.contains("/../") || url.contains("/./") {
        return Err(refuse());
    }
    let path = url.strip_prefix(API).ok_or_else(refuse)?;
    let allowed = ["/messages", "/labels"]
        .iter()
        .any(|route| path.strip_prefix(route).is_some_and(|rest| rest.is_empty() || rest.starts_with(['/', '?'])));
    if allowed { Ok(()) } else { Err(refuse()) }
}

/// One message to read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    /// Gmail's id.
    pub id: String,
    /// The label's name, then the id as an `.eml` file: what the walker's rules and the mail reader see.
    pub path: String,
}

impl Message {
    /// The document's URI.
    #[must_use]
    pub fn uri(&self) -> String {
        format!("{URI_PREFIX}{}", self.id)
    }
}

/// RFC 4648's base64url, with or without padding (Gmail's `raw`); `None` when it is not.
#[must_use]
pub fn decode_base64url(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut bits = 0u32;
    let mut count = 0;
    for byte in text.bytes().filter(|byte| *byte != b'=' && !byte.is_ascii_whitespace()) {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            _ => return None,
        };
        bits = bits << 6 | u32::from(value);
        count += 6;
        if count >= 8 {
            count -= 8;
            out.push(u8::try_from(bits >> count & 0xff).ok()?);
        }
    }
    Some(out)
}

/// The mailbox, over the API.
struct Mailbox<'h> {
    client: Client<'h>,
}

impl<'h> Mailbox<'h> {
    fn new(host: &'h mut dyn RemoteHost, slug: &str) -> Self {
        Self { client: Client::for_service(host, slug, KIND, "Gmail", check_destination, Vec::new()) }
    }

    /// The label a root names, by its id (`INBOX`, `SENT`, `Label_12`) or its name, without case:
    /// `(id, name)`, or [`ApiError::NotFound`].
    fn label(&mut self, root: &str) -> Result<(String, String), ApiError> {
        let labels = self.client.json(&format!("{API}/labels"))?;
        labels
            .get("labels")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|label| {
                let text = |key: &str| label.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
                (text("id"), text("name"))
            })
            .find(|(id, name)| !id.is_empty() && (id == root || name.eq_ignore_ascii_case(root)))
            .ok_or_else(|| ApiError::NotFound(format!("no label {root}")))
    }

    /// Every message id under `label` (or the whole mailbox but drafts and chats), page by page.
    fn list(
        &mut self,
        label: Option<&str>,
        mut visit: impl FnMut(String) -> ControlFlow<()>,
    ) -> Result<bool, ApiError> {
        let filter = match label {
            Some(id) => format!("labelIds={}", encode_path(id)),
            None => format!("q={}", encode_path(ALL_MAIL)),
        };
        let base = format!("{API}/messages?{filter}&maxResults={PAGE_SIZE}");
        let mut url = base.clone();
        loop {
            let page = self.client.json(&url)?;
            for value in page.get("messages").and_then(Value::as_array).into_iter().flatten() {
                let Some(id) = value.get("id").and_then(Value::as_str).filter(|id| !id.is_empty() && !id.contains('/'))
                else {
                    continue;
                };
                if visit(id.to_owned()).is_break() {
                    return Ok(false);
                }
            }
            match page.get("nextPageToken").and_then(Value::as_str) {
                Some(token) if !token.is_empty() => url = format!("{base}&pageToken={}", encode_path(token)),
                _ => return Ok(true),
            }
        }
    }

    /// One message's MIME.
    fn download(&mut self, message: &Message) -> Result<Vec<u8>, ApiError> {
        let url = format!("{API}/messages/{}?format=raw", encode_path(&message.id));
        let reply = self.client.get(&url, true, DOWNLOAD_TIMEOUT)?;
        if reply.status != 200 {
            return Err(ApiError::Other(format!("Gmail answered the download of a message with {}", reply.status)));
        }
        let value: Value = serde_json::from_slice(&reply.body)
            .map_err(|error| ApiError::Other(format!("Gmail sent a message that is not JSON: {error}")))?;
        value
            .get("raw")
            .and_then(Value::as_str)
            .and_then(decode_base64url)
            .ok_or_else(|| ApiError::Other("Gmail sent a message with no MIME".to_owned()))
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

/// Lists the source's messages, stores the scan, then reads each one the database does not hold yet.
///
/// # Errors
///
/// [`SourceError::Unavailable`] when the mailbox cannot be listed (no token, no such label, Google
/// unreachable), and [`SourceError::Storage`] when the scan or the run's end could not be stored.
pub fn ingest_gmail_source(
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
    let mut stats = WalkStats { dirs: 1, ..WalkStats::default() };
    let listed = (|| {
        let label = if root.is_empty() { None } else { Some(mailbox.label(&root)?) };
        let folder = label.as_ref().map_or_else(|| "All Mail".to_owned(), |(_, name)| name.replace('/', "-"));
        mailbox.list(label.as_ref().map(|(id, _)| id.as_str()), |id| {
            let message = Message { path: format!("/{folder}/{id}.eml"), id };
            if keep(&message.path, FIXED_SIZE, "", context.policy, options, &mut stats) {
                messages.push(message);
            }
            ControlFlow::Continue(())
        })
    })();
    if let Err(error) = listed {
        let problem = match error {
            ApiError::NotFound(_) => format!("{} is not a label in the Gmail account", display_root(&root)),
            ApiError::Other(message) => message,
        };
        run.counters.note_error(problem.clone());
        storage.finalize(false, &run.counters, 0, 0).map_err(SourceError::Storage)?;
        return Err(SourceError::Unavailable(problem));
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
            size: FIXED_SIZE,
            mtime: FIXED_TIME,
            placeholder: false,
        };
        if mailbox.client.host().cancelled() {
            mailbox.client.host().progress("cancelled", Some("Gmail"), &run.counters);
            stopped = true;
            break;
        }
        run.counters.seen += 1;
        let outcome = storage.check_stat(&candidate.uri).and_then(|existing| {
            let mut files = MailFiles { mailbox: &mut mailbox, message, bytes: None };
            ingest_one(&mut files, storage, &existing, &candidate, &context, &mut run.counters)
        });
        if let Err(error) = outcome {
            run.counters.note_error(format!("a message: {error}"));
            let _ = storage.record_seen(&candidate.uri);
        }
        mailbox.client.host().progress("ingest", Some("Gmail"), &run.counters);
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
    fn only_gmail_s_message_and_label_routes_are_approved() {
        for url in [
            "https://gmail.googleapis.com/gmail/v1/users/me/labels",
            "https://gmail.googleapis.com/gmail/v1/users/me/messages?labelIds=INBOX&maxResults=500",
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/18c2a?format=raw",
        ] {
            assert!(check_destination(url).is_ok(), "{url}");
        }
        for url in [
            "http://gmail.googleapis.com/gmail/v1/users/me/messages",
            "https://gmail.googleapis.com/gmail/v1/users/me/messagesX",
            "https://gmail.googleapis.com/gmail/v1/users/me/drafts",
            "https://gmail.googleapis.com/gmail/v1/users/me/settings/filters",
            "https://gmail.googleapis.com/gmail/v1/users/other@example.com/messages",
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/../drafts",
            "https://www.googleapis.com/drive/v3/files",
            "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=in:inbox is:unread",
        ] {
            assert!(check_destination(url).is_err(), "{url}");
        }
    }

    #[test]
    fn gmail_s_raw_is_base64url() {
        assert_eq!(decode_base64url("SGVsbG8_IFdvcmxkIQ").unwrap(), b"Hello? World!");
        assert_eq!(decode_base64url("SGk=").unwrap(), b"Hi");
        assert_eq!(decode_base64url("-_8").unwrap(), [0xfb, 0xff]);
        assert!(decode_base64url("not base64!").is_none());
    }

    fn base64url(bytes: &[u8]) -> String {
        const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut out = String::new();
        for group in bytes.chunks(3) {
            let value = group
                .iter()
                .enumerate()
                .fold(0u32, |value, (index, byte)| value | u32::from(*byte) << (16 - 8 * index));
            for index in 0..=group.len() {
                out.push(char::from(ALPHABET[(value >> (18 - 6 * index)) as usize & 63]));
            }
        }
        out
    }

    /// A mailbox in memory: labels with their messages, listed two to a page.
    #[derive(Default)]
    struct FakeGmail {
        labels: Vec<(String, String, Vec<String>)>,
        requests: Vec<String>,
    }

    fn reply(status: u16, body: impl Into<Vec<u8>>) -> HttpResponse {
        HttpResponse { status, headers: Vec::new(), body: body.into() }
    }

    impl RemoteHost for FakeGmail {
        fn access_token(&mut self, service: &str, slug: &str, _: bool) -> Result<String, String> {
            assert_eq!((service, slug), (KIND, "gm"));
            Ok("token".into())
        }

        fn send(&mut self, request: &HttpRequest) -> Result<HttpResponse, String> {
            check_destination(&request.url)?;
            let rest = request.url.strip_prefix(API).unwrap();
            if rest == "/labels" {
                let labels: Vec<Value> =
                    self.labels.iter().map(|(id, name, _)| json!({"id": id, "name": name})).collect();
                return Ok(reply(200, json!({"labels": labels}).to_string()));
            }
            if let Some(id) = rest.strip_prefix("/messages/").and_then(|rest| rest.strip_suffix("?format=raw")) {
                self.requests.push(format!("get {id}"));
                return Ok(reply(200, json!({"id": id, "raw": base64url(MAIL.as_bytes())}).to_string()));
            }
            let query = rest.strip_prefix("/messages?").unwrap();
            let ids: Vec<String> = if let Some(label) = query.strip_prefix("labelIds=") {
                let label = label.split('&').next().unwrap();
                self.labels.iter().find(|(id, _, _)| id == label).unwrap().2.clone()
            } else {
                assert!(query.starts_with("q=-in%3Adrafts%20-in%3Achats"), "{query}");
                self.labels.iter().filter(|(id, _, _)| id != "DRAFT").flat_map(|(_, _, ids)| ids.clone()).collect()
            };
            self.requests.push("list".into());
            let from: usize = query.split("pageToken=").nth(1).map_or(0, |token| token.parse().unwrap());
            let to = (from + 2).min(ids.len());
            let mut page = json!({"messages": ids[from..to].iter().map(|id| json!({"id": id})).collect::<Vec<_>>()});
            if to < ids.len() {
                page["nextPageToken"] = json!(to.to_string());
            }
            Ok(reply(200, page.to_string()))
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

    fn gmail() -> FakeGmail {
        let ids = |ids: &[&str]| ids.iter().map(|id| (*id).to_owned()).collect::<Vec<_>>();
        FakeGmail {
            labels: vec![
                ("INBOX".into(), "INBOX".into(), ids(&["a1", "a2", "a3"])),
                ("Label_7".into(), "Projects/Garage".into(), ids(&["p1"])),
                ("DRAFT".into(), "DRAFT".into(), ids(&["d1"])),
            ],
            ..FakeGmail::default()
        }
    }

    fn run(gmail: &mut FakeGmail, database: &mut Database, root: &str) -> Result<SourceRun, SourceError> {
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
        ingest_gmail_source(gmail, database, "gm", &context, &SourceOptions::default())
    }

    #[test]
    fn the_whole_mailbox_is_read_but_drafts() {
        let mut gmail = gmail();
        let mut database = Database::default();
        let outcome = run(&mut gmail, &mut database, "/").unwrap();
        assert!(outcome.completed);
        let uris: Vec<&str> = database.documents.iter().map(|(uri, _)| uri.as_str()).collect();
        assert_eq!(uris, ["gmail:a1", "gmail:a2", "gmail:a3", "gmail:p1"]);
        assert!(database.documents.iter().all(|(_, class)| class == "communication"));
        let scan = database.scan.unwrap();
        assert_eq!((scan.item_count, scan.item_type.as_str()), (4, "messages"));
    }

    #[test]
    fn a_label_by_name_reads_its_messages_and_a_held_message_is_never_fetched() {
        let mut gmail = gmail();
        let mut database = Database::default();
        run(&mut gmail, &mut database, "projects/garage").unwrap();
        assert_eq!(database.documents.iter().map(|(uri, _)| uri.as_str()).collect::<Vec<_>>(), ["gmail:p1"]);

        let mut gmail = self::gmail();
        let mut database = Database::default();
        database.stats.insert(
            "gmail:a2".into(),
            ExistingStat {
                exists: true,
                byte_size: 1,
                mtime: FIXED_TIME,
                state: "OK".into(),
                chunker: "conversation:1".into(),
                ..ExistingStat::default()
            },
        );
        let outcome = run(&mut gmail, &mut database, "INBOX").unwrap();
        assert_eq!((outcome.counters.skipped, outcome.counters.indexed), (1, 2));
        assert_eq!(gmail.requests.iter().filter(|request| request.starts_with("get")).count(), 2);
        assert!(!gmail.requests.contains(&"get a2".to_owned()));
    }

    #[test]
    fn a_missing_label_fails_the_run_before_the_scan_is_stored() {
        let mut gmail = gmail();
        let mut database = Database::default();
        let outcome = run(&mut gmail, &mut database, "/Nowhere");
        assert_eq!(outcome, Err(SourceError::Unavailable("/Nowhere is not a label in the Gmail account".into())));
        assert!(database.scan.is_none());
        assert_eq!(database.finalized, Some(false));
    }
}
