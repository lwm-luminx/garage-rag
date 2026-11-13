//! A Messages source, conversation by conversation: `ingest/conversations.py`.
//!
//! The databases are read by the FOSS `messages-markdown` crate (Python's `extract/messages.py`, held
//! to it by the crate's own fixtures); what Garage does with each thread is here. A thread is one
//! document: a header naming it and its members, then one paragraph per message, each its own chunk
//! (split further only when longer than the chunk size) carrying `chunks.direction` and
//! `chunks.sender`. The text, its hash, the chunks, the authors and the metadata match Python's, so a
//! thread stored by either side is left alone by the other.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;

use messages_markdown::{ChatMessage, Conversation, Database, Status, database_status, find_databases};
use serde_json::{Map, Value, json};

use crate::chunking::chunk_prose;
use crate::contact_names::ContactNames;
use crate::pipeline::{AuthorPayload, ChunkPayload, Context, Counters, DocumentPayload};
use crate::sha256::hex_digest;
use crate::source::{SourceHost, SourceStorage};

/// `CHUNKER`: every message chunk's chunker.
pub const CHUNKER: &str = "message";
const SELF_LABEL: &str = "Me";

/// `signature`: the document's chunker signature; a new chunk size or reader version rebuilds every thread.
#[must_use]
pub fn signature(size: usize) -> String {
    format!("conversation:{CHUNKER}:{size}:v{}", messages_markdown::VERSION)
}

/// `conversation_uri`: the database's path plus the chat's GUID.
#[must_use]
pub fn conversation_uri(db_path: &Path, conversation: &Conversation) -> String {
    format!("{}#{}", db_path.display(), conversation.guid)
}

/// A thread and the names known for its handles (`Conversation.names`).
pub struct Thread {
    /// The thread.
    pub conversation: Conversation,
    /// Names for some of its handles, in the order `attach_names` found them.
    pub names: Vec<(String, String)>,
    lookup: HashMap<String, String>,
}

impl Thread {
    /// `attach_names`: the names `contact_names` knows for the members and senders (none when it is empty).
    #[must_use]
    pub fn new(conversation: Conversation, contact_names: &ContactNames) -> Self {
        let mut names = Vec::new();
        if !contact_names.is_empty() {
            let senders = conversation.messages.iter().filter_map(|message| message.sender.as_deref());
            let mut seen = BTreeSet::new();
            for handle in conversation.participants.iter().map(String::as_str).chain(senders) {
                if !seen.insert(handle.to_owned()) {
                    continue;
                }
                if let Some(name) = contact_names.name_for(handle).filter(|name| !name.is_empty()) {
                    names.push((handle.to_owned(), name));
                }
            }
        }
        let lookup = names.iter().cloned().collect();
        Self { conversation, names, lookup }
    }

    /// `Conversation.label`: a handle's name, or the handle.
    fn label(&self, handle: &str) -> String {
        self.lookup.get(handle).filter(|name| !name.is_empty()).cloned().unwrap_or_else(|| handle.to_owned())
    }

    /// `Conversation.title`.
    #[must_use]
    pub fn title(&self) -> String {
        self.conversation.title(&self.lookup)
    }

    fn sender_label(&self, message: &ChatMessage) -> String {
        if message.is_from_me {
            return SELF_LABEL.to_owned();
        }
        message.sender.as_deref().map_or_else(|| "Unknown".to_owned(), |handle| self.label(handle))
    }

    fn member(&self, handle: &str) -> String {
        match self.lookup.get(handle).filter(|name| !name.is_empty()) {
            Some(name) => format!("{name} ({handle})"),
            None => handle.to_owned(),
        }
    }

    /// `_header`: the thread's name and members, so a rename or a new member changes the text.
    fn header(&self) -> String {
        let mut lines = vec![self.title()];
        let conversation = &self.conversation;
        if !conversation.participants.is_empty() {
            let members: Vec<String> = conversation.participants.iter().map(|handle| self.member(handle)).collect();
            lines.push(format!("Participants: {}", members.join(", ")));
        }
        if !conversation.service.is_empty() {
            lines.push(format!("Service: {}", conversation.service));
        }
        lines.join("\n")
    }
}

/// One chunk of a rendered thread, with the message it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MessageChunk {
    /// Its text.
    pub text: String,
    /// Where it sits in the document, in characters.
    pub char_start: usize,
    /// Where it ends.
    pub char_end: usize,
    /// `sent` or `received`.
    pub direction: &'static str,
    /// `me`, the sender's handle, or none.
    pub sender: Option<String>,
}

/// `_render`: the document text and its chunks, each within one message's paragraph.
///
/// # Errors
///
/// A chunk size the splitter refuses.
pub fn render(thread: &Thread, size: usize) -> Result<(String, Vec<MessageChunk>), String> {
    let header = thread.header();
    let mut offset = header.chars().count();
    let mut parts = vec![header];
    let mut chunks = Vec::new();
    for message in &thread.conversation.messages {
        let paragraph =
            format!("[{}] {}: {}", message.sent_at.minute_utc(), thread.sender_label(message), message.text);
        offset += 2; // the blank line between paragraphs
        let length = paragraph.chars().count();
        let pieces: Vec<String> = if length <= size {
            vec![paragraph.clone()]
        } else {
            chunk_prose(&paragraph, size, 0).map_err(|error| error.to_string())?.into_iter().map(|c| c.text).collect()
        };
        let (mut cursor_byte, mut cursor_char) = (0, 0);
        for piece in pieces {
            // `paragraph.find(piece, cursor)`; the splitter only drops white space, so it is found.
            let (start_byte, start_char) = match paragraph[cursor_byte..].find(&piece) {
                Some(found) => {
                    let start_byte = cursor_byte + found;
                    (start_byte, cursor_char + paragraph[cursor_byte..start_byte].chars().count())
                }
                None => (cursor_byte, cursor_char),
            };
            let piece_chars = piece.chars().count();
            cursor_byte = (start_byte + piece.len()).min(paragraph.len());
            cursor_char = start_char + piece_chars;
            chunks.push(MessageChunk {
                char_start: offset + start_char,
                char_end: offset + start_char + piece_chars,
                text: piece,
                direction: message.direction().as_str(),
                sender: message.sender_id().map(str::to_owned),
            });
        }
        parts.push(paragraph);
        offset += length;
    }
    Ok((parts.join("\n\n"), chunks))
}

/// `conversation_authors`: the handles that wrote are senders, members who only read are recipients,
/// and the owner, when named, is one or the other.
#[must_use]
pub fn conversation_authors(thread: &Thread, identity: &crate::attribution::SelfIdentity) -> Vec<AuthorPayload> {
    let conversation = &thread.conversation;
    let senders: BTreeSet<&str> =
        conversation.messages.iter().filter_map(|message| message.sender.as_deref()).collect();
    let mut handles: Vec<&str> = Vec::new();
    for handle in conversation.participants.iter().map(String::as_str).chain(senders.iter().copied()) {
        if !handles.contains(&handle) {
            handles.push(handle);
        }
    }
    let mut authors: Vec<AuthorPayload> = handles
        .into_iter()
        .filter(|handle| !identity.matches(None, Some(handle)))
        .map(|handle| AuthorPayload {
            name: thread.label(handle),
            role: if senders.contains(handle) { "sender" } else { "recipient" }.to_owned(),
            confidence: 1.0,
            evidence: "imessage-handle".to_owned(),
            identities: vec![(if handle.contains('@') { "email" } else { "phone" }.to_owned(), handle.to_owned())],
            is_self: false,
        })
        .collect();
    if !identity.name.is_empty() {
        let wrote = conversation.messages.iter().any(|message| message.is_from_me);
        authors.push(AuthorPayload {
            name: identity.name.clone(),
            role: if wrote { "sender" } else { "recipient" }.to_owned(),
            confidence: 1.0,
            evidence: if wrote { "imessage-is-from-me" } else { "imessage-owner" }.to_owned(),
            identities: Vec::new(),
            is_self: true,
        });
    }
    authors
}

/// `ingest_conversation`: stores one thread. The chunks written, or `None` when it was unchanged.
///
/// # Errors
///
/// A storage call's failure, or a chunk size the splitter refuses.
pub fn ingest_conversation(
    storage: &mut dyn SourceStorage,
    db_path: &Path,
    thread: &Thread,
    context: &Context<'_>,
) -> Result<Option<usize>, String> {
    let conversation = &thread.conversation;
    let uri = conversation_uri(db_path, conversation);
    let size = context.settings.chunk_size;
    let (text, chunks) = render(thread, size)?;
    let content_hash = hex_digest(text.as_bytes());

    let existing = storage.check_stat(&uri)?;
    if existing.exists
        && !context.force
        && existing.content_sha256 == content_hash
        && existing.chunker == signature(size)
        && existing.state.to_uppercase() == "OK"
    {
        storage.record_seen(&uri)?;
        return Ok(None);
    }

    let last = conversation.last_message_at();
    let names: Map<String, Value> =
        thread.names.iter().map(|(handle, name)| (handle.clone(), Value::String(name.clone()))).collect();
    let mut meta = Map::new();
    meta.insert("chat_guid".into(), json!(conversation.guid));
    meta.insert("chat_identifier".into(), json!(conversation.chat_identifier));
    meta.insert("service".into(), json!(conversation.service));
    meta.insert("participants".into(), json!(conversation.participants));
    meta.insert("participant_names".into(), Value::Object(names));
    meta.insert("is_group".into(), json!(conversation.is_group()));
    meta.insert("message_count".into(), json!(conversation.messages.len()));
    meta.insert("first_message_at".into(), json!(conversation.messages.first().map(|m| m.sent_at.isoformat())));
    meta.insert("last_message_at".into(), json!(last.map(|at| at.isoformat())));
    meta.insert("database".into(), json!(db_path.display().to_string()));

    #[allow(clippy::cast_precision_loss)]
    let mtime = last.map_or(0.0, |at| at.unix_micros as f64 / 1e6);
    let title = thread.title();
    let document = DocumentPayload {
        title: Some(title.clone()),
        lang: None,
        byte_size: text.len() as u64,
        mtime,
        source_sha256: None,
        content_sha256: content_hash,
        extractor: "messages".to_owned(),
        extractor_version: messages_markdown::VERSION.to_string(),
        chunker: signature(size),
        content: text,
        meta,
        corpus_class: "communication".to_owned(),
        trust_tier: context.source.default_trust.as_str().to_owned(),
        authors: conversation_authors(thread, context.identity),
        chunks: chunks
            .into_iter()
            .enumerate()
            .map(|(ord, chunk)| ChunkPayload {
                ord,
                token_count: (chunk.text.chars().count() / 4).max(1),
                char_start: Some(chunk.char_start),
                char_end: Some(chunk.char_end),
                heading_path: Some(title.clone()),
                chunk_sha256: hex_digest(chunk.text.as_bytes()),
                chunker: CHUNKER.to_owned(),
                text: chunk.text,
                direction: Some(chunk.direction.to_owned()),
                sender: chunk.sender,
                session_turn_external_id: None,
            })
            .collect(),
        session_json: None,
    };
    storage.replace_document(&uri, document).map(Some)
}

/// What stopped a run before it read every database.
enum Stop {
    Cancelled,
    Limit,
}

/// `ingest_messages_source`: every thread in every Messages database under the source's root. True
/// when every database was read to the end, which lets reconcile retire the threads that are gone; a
/// cancellation, the limit, or a database that could not be read gives false.
pub fn ingest_messages_source(
    host: &mut dyn SourceHost,
    storage: &mut dyn SourceStorage,
    context: &Context<'_>,
    limit: Option<u64>,
    counters: &mut Counters,
) -> bool {
    let root = &context.source.root;
    if !root.exists() {
        counters.note_error(format!("{}: path does not exist", root.display()));
        return false;
    }
    let contacts = context.contact_names.cloned().unwrap_or_default();
    let mut complete = true;
    let mut found = 0_usize;
    // An unlistable folder reads as empty, as os.walk's does.
    for db_path in find_databases(root).unwrap_or_default() {
        let name = db_path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        match database_status(&db_path) {
            Status::Unreadable => {
                // Most often Full Disk Access is missing. Its threads must not be retired.
                counters.note_error(format!("{name}: cannot be read (does Garage have Full Disk Access?)"));
                complete = false;
                continue;
            }
            Status::NotMessages => continue,
            Status::Messages => {}
        }
        found += 1;
        // Contacts first; a name an iMessage contact shared fills in a handle Contacts does not know.
        let directory = db_path.parent().unwrap_or(root);
        let shared = host.shared_names(directory);
        let names =
            contacts.clone().with_fallback(ContactNames::new(shared.iter().map(|(h, n)| (h.as_str(), n.as_str()))));
        match read_database(host, storage, context, &db_path, &names, limit, counters) {
            Ok(None) => {}
            Ok(Some(Stop::Cancelled | Stop::Limit)) => return false,
            Err(error) => {
                counters.note_error(format!("{name}: {error}"));
                complete = false;
            }
        }
    }
    if found == 0 && complete {
        // An unlistable folder looks empty; an empty run would retire every thread.
        counters.note_error(format!("{}: no readable Messages database found", root.display()));
        return false;
    }
    complete
}

/// One database's threads; `Err` when SQLite stopped the read part way.
fn read_database(
    host: &mut dyn SourceHost,
    storage: &mut dyn SourceStorage,
    context: &Context<'_>,
    db_path: &Path,
    names: &ContactNames,
    limit: Option<u64>,
    counters: &mut Counters,
) -> Result<Option<Stop>, String> {
    let database = Database::open(db_path).map_err(|error| error.to_string())?;
    for conversation in database.conversations().map_err(|error| error.to_string())? {
        let conversation = conversation.map_err(|error| error.to_string())?;
        if host.cancelled() {
            return Ok(Some(Stop::Cancelled));
        }
        counters.seen += 1;
        let thread = Thread::new(conversation, names);
        let title = thread.title();
        match ingest_conversation(storage, db_path, &thread, context) {
            Ok(None) => counters.skipped += 1,
            Ok(Some(written)) => {
                counters.indexed += 1;
                counters.chunks_written += written as u64;
            }
            Err(error) => {
                counters.note_error(format!("{title}: {error}"));
                // Without a seen row reconcile would treat the thread as deleted.
                let _ = storage.record_seen(&conversation_uri(db_path, &thread.conversation));
            }
        }
        host.progress("ingest", Some(&title), counters);
        if limit.is_some_and(|limit| counters.seen >= limit) {
            return Ok(Some(Stop::Limit));
        }
    }
    Ok(None)
}
