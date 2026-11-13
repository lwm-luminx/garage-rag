//! Fact extraction over a set of documents (`enrich/facts.py`, `enrich/metadata.py`, `ops/facts.py`'s
//! `enrich_facts`; `garage enrich-facts`, the `EnrichFacts` RPC).
//!
//! Each document gets, once per prompt, the atomic facts a local model extracts from it, every one
//! a verbatim, grounded quote, stored in `facts` and replaced prompt by prompt on the next run.
//! `fact_runs` remembers what each prompt last ran with, so a changed prompt, document or model is
//! detectable (`stale_only`). Each stored fact also gets a `chunks` row of its own, which the
//! ordinary backfill embeds under every registered model.
//!
//! A mail's sender, recipients and subject, and a Messages thread's participants, are ground truth
//! read straight from the document's metadata with no model (`extractor = 'metadata'`, prompt
//! `metadata`), each with its value's exact key in `attributes.key`; `garage cluster-facts` anchors
//! distilled facts on those keys.
//!
//! The model's part is behind [`FactExtractor`]: what to extract (the prompt's description and
//! examples), from which text, with which model; the LangExtract loop that drives the model lives
//! in that implementation ([`crate::langextract::LangExtractor`], over the process's host). Before anything is deleted, the document's class goes through the
//! egress rules: a server that is not approved, or a communication for a server that is not
//! loopback, refuses the run for that document.

#![allow(clippy::implicit_hasher)]

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::sync::{Arc, LazyLock};

use deadpool_postgres::Transaction;
use garage_embed::Settings;
use garage_embed::egress::{EgressBlocked, allows_communications, check_destination};
use garage_ingest::parseaddr::{formataddr, getaddresses};
use garage_ingest::sha256;
use regex::Regex;
use serde_json::{Map, Value};

use crate::db::Client;
use crate::error::{Result, ServiceError};
use crate::prompts::EffectivePrompt;

// ---------------------------------------------------------------------------
// Metadata facts

/// `facts.prompt_name` of a metadata fact.
pub const METADATA_PROMPT: &str = "metadata";
/// `facts.extractor` of a metadata fact.
pub const METADATA_EXTRACTOR: &str = "metadata";
/// Bumped when what is read, or how it is keyed, changes: every document is read again.
pub const METADATA_VERSION: &str = "1";
/// The `chunker` of a metadata fact's chunk.
pub const METADATA_CHUNKER: &str = "facts:metadata:1";
pub const FACT_CLASSES: [&str; 3] = ["sender", "recipient", "subject"];

/// `fact_runs.prompt_sha256` of the metadata pass: SHA-256 of `metadata:<version>`.
pub fn metadata_prompt_sha256() -> Vec<u8> {
    sha256::digest(format!("metadata:{METADATA_VERSION}").as_bytes()).to_vec()
}

// "Re:", "Fwd:", "AW:", "[External]" and the like, repeated, at the start of a subject.
static SUBJECT_PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\s*(?:(?:re|fw|fwd|aw|sv|vs|wg|antw)\s*(?:\[\d+\])?\s*:|\[[^\]]*\])\s*").unwrap()
});
static SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());

/// One fact read from a document's metadata (`MetadataFact`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MetadataFact {
    pub fact_class: String,
    pub text: String,
    pub key: String,
    /// Where the text appears in the document, in code points, when it does.
    pub char_start: Option<i32>,
    pub char_end: Option<i32>,
    pub attributes: Map<String, Value>,
}

/// A subject's exact key: reply and forward prefixes stripped, casefolded, spaces collapsed.
pub fn normalize_subject(subject: &str) -> String {
    let mut value = subject.to_owned();
    loop {
        let stripped = SUBJECT_PREFIX.replacen(&value, 1, "").into_owned();
        if stripped == value {
            break;
        }
        value = stripped;
    }
    SPACE.replace_all(&value, " ").trim().to_lowercase()
}

/// `content.find(value, start, end)` in code points: where `value` appears in `content[start..end]`.
fn span(content: &str, value: &str, start: usize, end: usize) -> (Option<i32>, Option<i32>) {
    if value.is_empty() || start >= end {
        return (None, None);
    }
    let (start_byte, end_byte) = (char_to_byte(content, start), char_to_byte(content, end));
    let Some(at) = content[start_byte..end_byte].find(value) else { return (None, None) };
    let at_chars = content[..start_byte + at].chars().count();
    let width = value.chars().count();
    (Some(to_i32(at_chars)), Some(to_i32(at_chars + width)))
}

fn char_to_byte(content: &str, chars: usize) -> usize {
    content.char_indices().nth(chars).map_or(content.len(), |(byte, _)| byte)
}

fn to_i32(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

/// The bounds, in code points, of the value of a mail's `label:` header line, or an empty range.
fn header_line(content: &str, label: &str) -> (usize, usize) {
    let header_end = content.find("\n\n").unwrap_or(content.len());
    let prefix = format!("{label}: ");
    let at = if content.starts_with(&prefix) {
        0
    } else {
        match content[..header_end].find(&format!("\n{prefix}")) {
            Some(at) => at + 1,
            None => return (0, 0),
        }
    };
    let value_start = at + prefix.len();
    let line_end = content[..header_end].get(at..).and_then(|rest| rest.find('\n')).map_or(header_end, |n| at + n);
    (content[..value_start].chars().count(), content[..line_end].chars().count())
}

fn string_attr(key: &str, value: &str) -> (String, Value) {
    (key.to_owned(), Value::String(value.to_owned()))
}

/// A mail's sender, recipients and subject. `author_of` maps a lowercased address to its author.
pub fn mail_facts(content: &str, meta: &Map<String, Value>, author_of: &HashMap<String, i64>) -> Vec<MetadataFact> {
    let header = |key: &str| meta.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let mut facts = Vec::new();
    let mut seen: HashSet<(String, String)> = HashSet::new();
    for (fact_class, label, value) in [
        ("sender", "From", header("email_from")),
        ("recipient", "To", header("email_to")),
        ("recipient", "Cc", header("email_cc")),
    ] {
        let (start, end) = header_line(content, label);
        let fields: Vec<&str> = value.into_iter().collect();
        for (name, address) in getaddresses(&fields) {
            let address = address.trim();
            if !address.contains('@') {
                continue;
            }
            let lowered = address.to_lowercase();
            let key = match author_of.get(&lowered) {
                Some(author) => format!("author:{author}"),
                None => format!("email:{lowered}"),
            };
            if !seen.insert((fact_class.to_owned(), key.clone())) {
                continue;
            }
            let mut quoted = if name.is_empty() { address.to_owned() } else { formataddr(&name, address) };
            let mut found = span(content, &quoted, start, end);
            if found.0.is_none() {
                address.clone_into(&mut quoted);
                found = span(content, address, start, end);
            }
            let mut attributes = Map::new();
            attributes.extend([
                string_attr("key", &key),
                string_attr("address", &lowered),
                string_attr("header", &label.to_lowercase()),
            ]);
            if !name.is_empty() {
                attributes.extend([string_attr("name", &name)]);
            }
            facts.push(MetadataFact {
                fact_class: fact_class.to_owned(),
                text: quoted,
                key,
                char_start: found.0,
                char_end: found.1,
                attributes,
            });
        }
    }
    // Only a stated subject: without one, the title is the file's name.
    let (start, end) = header_line(content, "Subject");
    let subject = content[char_to_byte(content, start)..char_to_byte(content, end)].trim();
    let key = normalize_subject(subject);
    if !key.is_empty() {
        let found = span(content, subject, start, end);
        let key = format!("subject:{key}");
        let mut attributes = Map::new();
        attributes.extend([string_attr("key", &key)]);
        facts.push(MetadataFact {
            fact_class: "subject".to_owned(),
            text: subject.to_owned(),
            key,
            char_start: found.0,
            char_end: found.1,
            attributes,
        });
    }
    facts
}

/// A thread's participants, each `(author_id, display_name, role)` with role `sender` or `recipient`.
pub fn conversation_facts(content: &str, participants: &[(i64, String, String)]) -> Vec<MetadataFact> {
    let mut facts = Vec::new();
    for (author_id, name, role) in participants {
        if (role != "sender" && role != "recipient") || name.is_empty() {
            continue;
        }
        let key = format!("author:{author_id}");
        let found = span(content, name, 0, content.chars().count());
        let mut attributes = Map::new();
        attributes.extend([string_attr("key", &key)]);
        facts.push(MetadataFact {
            fact_class: role.clone(),
            text: name.clone(),
            key,
            char_start: found.0,
            char_end: found.1,
            attributes,
        });
    }
    facts
}

/// Whether a document is a mail or a Messages thread, the documents with metadata facts.
pub fn has_metadata(meta: &Value) -> bool {
    meta.get("email_from").is_some() || meta.get("chat_guid").is_some()
}

// ---------------------------------------------------------------------------
// Documents, runs and what is stale

/// What the loop needs of a `documents` row.
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentRow {
    pub id: i64,
    pub source_id: i64,
    pub source_slug: String,
    pub uri: String,
    pub corpus_class: String,
    pub content: Option<String>,
    pub content_sha256: Vec<u8>,
    pub meta: Value,
}

impl DocumentRow {
    fn meta_object(&self) -> Map<String, Value> {
        self.meta.as_object().cloned().unwrap_or_default()
    }
}

const DOCUMENT_COLUMNS: &str =
    "d.id, d.source_id, s.slug, d.uri, d.corpus_class::text, d.content, d.content_sha256, d.meta";

fn document_row(row: &tokio_postgres::Row) -> DocumentRow {
    DocumentRow {
        id: row.get(0),
        source_id: row.get(1),
        source_slug: row.get(2),
        uri: row.get(3),
        corpus_class: row.get(4),
        content: row.get(5),
        content_sha256: row.get(6),
        meta: row.get(7),
    }
}

/// The documents a run covers: one by id (`NOT_FOUND` when there is none), a source's, or every
/// one; in id order. Empty when there is nothing to enrich.
///
/// # Errors
///
/// `document {id} not found`; the database.
pub async fn documents_to_enrich(client: &Client, source: &str, document_id: Option<i64>) -> Result<Vec<DocumentRow>> {
    let joins = "FROM documents d JOIN sources s ON s.id = d.source_id";
    if let Some(id) = document_id {
        let row = client.query_opt(&format!("SELECT {DOCUMENT_COLUMNS} {joins} WHERE d.id = $1"), &[&id]).await?;
        return match row {
            Some(row) => Ok(vec![document_row(&row)]),
            None => Err(ServiceError::not_found(format!("document {id} not found"))),
        };
    }
    let rows = if source.is_empty() || source == "*" {
        client.query(&format!("SELECT {DOCUMENT_COLUMNS} {joins} ORDER BY d.id"), &[]).await?
    } else {
        client
            .query(
                &format!(
                    "SELECT {DOCUMENT_COLUMNS} {joins} \
                     WHERE (s.slug = $1 OR EXISTS (SELECT 1 FROM document_sources ds \
                     JOIN sources s2 ON s2.id = ds.source_id WHERE ds.document_id = d.id AND s2.slug = $1)) \
                     ORDER BY d.id"
                ),
                &[&source],
            )
            .await?
    };
    Ok(rows.iter().map(document_row).collect())
}

/// One `fact_runs` row: what a prompt last ran with on a document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FactRun {
    pub prompt_sha256: Vec<u8>,
    pub content_sha256: Vec<u8>,
    pub extractor_model: String,
}

/// A document's runs by prompt name.
///
/// # Errors
///
/// The database.
pub async fn fact_runs(client: &Client, document_id: i64) -> Result<HashMap<String, FactRun>> {
    let rows = client
        .query(
            "SELECT prompt_name, prompt_sha256, content_sha256, extractor_model FROM fact_runs WHERE document_id = $1",
            &[&document_id],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|row| {
            (
                row.get::<_, String>(0),
                FactRun { prompt_sha256: row.get(1), content_sha256: row.get(2), extractor_model: row.get(3) },
            )
        })
        .collect())
}

/// Whether `prompt`'s facts for the document need extracting (again): it never ran, or what it ran
/// with (the prompt's text, the document's content, the model) changed since (`facts.is_stale`).
pub fn prompt_is_stale(
    run: Option<&FactRun>,
    document: &DocumentRow,
    prompt: &EffectivePrompt,
    model_id: &str,
) -> bool {
    run.is_none_or(|run| {
        run.prompt_sha256 != prompt.sha256()
            || run.content_sha256 != document.content_sha256
            || run.extractor_model != model_id
    })
}

/// Whether the document's metadata facts need writing (again) (`metadata.is_stale`).
pub fn metadata_is_stale(run: Option<&FactRun>, document: &DocumentRow) -> bool {
    has_metadata(&document.meta)
        && run.is_none_or(|run| {
            run.prompt_sha256 != metadata_prompt_sha256() || run.content_sha256 != document.content_sha256
        })
}

// ---------------------------------------------------------------------------
// The model's side

/// Fact-distillation backends: the local inference servers (`FACT_DISTIL_PROVIDERS`).
pub const FACT_DISTIL_PROVIDERS: [&str; 3] = ["ollama", "llama_xpc", "lmstudio"];

// Model ids upstream LangExtract routed to a cloud API (its Gemini and OpenAI provider patterns),
// plus Anthropic's. `gpt-oss` is an open-weights model served by Ollama and does not match.
static CLOUD_MODEL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^(?:gemini|gpt-3\.5|gpt-4|gpt4\.|gpt-5|gpt5\.|o[1-9]|claude)").unwrap());

/// `ValueError` when `model_id` names a cloud-hosted model: fact distillation only runs on local
/// models, so such an id is a configuration mistake (`refuse_cloud_model_id`).
///
/// # Errors
///
/// [`ServiceError::InvalidArgument`] with Python's message.
pub fn refuse_cloud_model_id(model_id: &str) -> Result<()> {
    if CLOUD_MODEL.is_match(model_id) {
        return Err(ServiceError::invalid(format!(
            "{} names a cloud-hosted model; fact distillation runs only on local models (facts.provider {})",
            garage_mcp::pyrepr::str_repr(model_id),
            FACT_DISTIL_PROVIDERS.join(", ")
        )));
    }
    Ok(())
}

/// The model a run extracts with and where it is (`fact_backend`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FactModel {
    pub provider: String,
    pub model_id: String,
    /// The server's URL as configured.
    pub host_url: String,
    /// `llama_xpc`: the app's own service, loopback only.
    pub loopback_only: bool,
}

impl FactModel {
    /// The model for `provider` on the configured servers.
    ///
    /// # Errors
    ///
    /// An unknown provider, with Python's message.
    pub fn new(provider: &str, model_id: &str, servers: &Settings) -> Result<Self> {
        let host_url = match provider {
            "llama_xpc" => servers.llama_host.clone(),
            "ollama" => servers.ollama_host.clone(),
            "lmstudio" => servers.lmstudio_host.clone(),
            other => {
                return Err(ServiceError::invalid(format!(
                    "unknown fact-distil provider {}; expected one of ('ollama', 'llama_xpc', 'lmstudio')",
                    garage_mcp::pyrepr::str_repr(other)
                )));
            }
        };
        Ok(Self {
            provider: provider.to_owned(),
            model_id: model_id.to_owned(),
            host_url,
            loopback_only: provider == "llama_xpc",
        })
    }

    /// `egress.check_destination` for a document of `corpus_class`: the content rule first, then
    /// the destination allowlist.
    ///
    /// # Errors
    ///
    /// [`EgressBlocked`] with the rule's message.
    pub fn check_egress(&self, corpus_class: &str, servers: &Settings) -> std::result::Result<(), EgressBlocked> {
        let purpose = format!("facts:{}", self.provider);
        if corpus_class == "communication" && !allows_communications(&self.host_url) {
            return Err(EgressBlocked(format!(
                "{purpose}: communications never leave this machine; {:?} is not a loopback host",
                self.host_url
            )));
        }
        check_destination(&self.host_url, &purpose, self.loopback_only, servers)
    }
}

/// One grounded extraction, as stored in `facts`.
#[derive(Clone, Debug, PartialEq)]
pub struct Extracted {
    pub fact_class: String,
    pub text: String,
    pub attributes: Map<String, Value>,
    /// The span in the document's text, in code points.
    pub char_start: i32,
    pub char_end: i32,
}

/// What distils a document's text into facts with a prompt: the LangExtract loop over the model's
/// host (`extract_facts`). Only grounded extractions come back: an ungrounded one is the model
/// quoting its own few-shot example, which cannot be traced to the source text.
pub trait FactExtractor: Send + Sync {
    /// The facts `prompt` finds in `text` with `model`, on the configured `servers`. `text` is of
    /// `corpus_class`, which an implementation that sends it anywhere runs through the egress
    /// rules ([`FactModel::check_egress`]) before it does.
    ///
    /// # Errors
    ///
    /// Why the model could not be asked, or its answer could not be used, as a message.
    fn extract(
        &self,
        model: &FactModel,
        servers: &Settings,
        corpus_class: &str,
        prompt: &EffectivePrompt,
        text: &str,
    ) -> std::result::Result<Vec<Extracted>, String>;
}

// ---------------------------------------------------------------------------
// Storing facts

async fn next_chunk_ord(tx: &Transaction<'_>, document_id: i64) -> Result<i32> {
    let ord: i32 = tx
        .query_one("SELECT coalesce(max(ord), -1) + 1 FROM chunks WHERE document_id = $1", &[&document_id])
        .await?
        .get(0);
    Ok(ord)
}

/// Gives each new fact a chunk of its own after the document's existing chunks, for the backfill
/// to embed: nothing but its text, no heading path and no span into the document.
async fn queue_for_embedding(
    tx: &Transaction<'_>,
    document_id: i64,
    facts: &[(i64, String)],
    chunker: &str,
) -> Result<()> {
    if facts.is_empty() {
        return Ok(());
    }
    let base = next_chunk_ord(tx, document_id).await?;
    for (i, (fact_id, text)) in facts.iter().enumerate() {
        tx.execute(
            "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker, fact_id) VALUES ($1, $2, $3, $4, $5, $6)",
            &[&document_id, &(base + to_i32(i)), text, &sha256::digest(text.as_bytes()).to_vec(), &chunker, fact_id],
        )
        .await?;
    }
    Ok(())
}

async fn record_run(
    tx: &Transaction<'_>,
    document: &DocumentRow,
    prompt_name: &str,
    prompt_sha256: &[u8],
    extractor_model: &str,
    facts: usize,
) -> Result<()> {
    tx.execute(
        "INSERT INTO fact_runs (document_id, prompt_name, prompt_sha256, content_sha256, extractor_model, facts, \
                                extracted_at) \
         VALUES ($1, $2, $3, $4, $5, $6, now()) \
         ON CONFLICT (document_id, prompt_name) DO UPDATE SET prompt_sha256 = EXCLUDED.prompt_sha256, \
             content_sha256 = EXCLUDED.content_sha256, extractor_model = EXCLUDED.extractor_model, \
             facts = EXCLUDED.facts, extracted_at = now()",
        &[
            &document.id,
            &prompt_name,
            &prompt_sha256.to_vec(),
            &document.content_sha256,
            &extractor_model,
            &to_i32(facts),
        ],
    )
    .await?;
    Ok(())
}

/// The metadata facts of a document: a mail's or a Messages thread's; none for anything else
/// (`document_facts`).
///
/// # Errors
///
/// The database.
pub async fn document_metadata_facts(tx: &Transaction<'_>, document: &DocumentRow) -> Result<Vec<MetadataFact>> {
    let meta = document.meta_object();
    let content = document.content.as_deref().unwrap_or("");
    if meta.contains_key("email_from") {
        let fields: Vec<&str> = ["email_from", "email_to", "email_cc"]
            .iter()
            .map(|k| meta.get(*k).and_then(Value::as_str).unwrap_or(""))
            .collect();
        let addresses: Vec<String> = getaddresses(&fields)
            .into_iter()
            .filter(|(_, address)| address.contains('@'))
            .map(|(_, address)| address.to_lowercase())
            .collect();
        let rows = tx
            .query(
                "SELECT lower(value), author_id FROM author_identities WHERE kind = 'email' AND lower(value) = ANY($1)",
                &[&addresses],
            )
            .await?;
        let author_of: HashMap<String, i64> = rows.iter().map(|row| (row.get(0), row.get(1))).collect();
        return Ok(mail_facts(content, &meta, &author_of));
    }
    if meta.contains_key("chat_guid") {
        let rows = tx
            .query(
                "SELECT a.id, a.display_name, da.role::text FROM document_authors da JOIN authors a ON a.id = da.author_id \
                 WHERE da.document_id = $1 AND da.role IN ('sender', 'recipient') ORDER BY da.role, a.id",
                &[&document.id],
            )
            .await?;
        let participants: Vec<(i64, String, String)> = rows
            .iter()
            .map(|row| (row.get(0), row.get::<_, Option<String>>(1).unwrap_or_default(), row.get(2)))
            .collect();
        return Ok(conversation_facts(content, &participants));
    }
    Ok(Vec::new())
}

/// Replaces the document's metadata facts, each with a chunk for the backfill to embed, and records
/// the run under the `metadata` prompt name; the ids written (`store_metadata_facts`).
///
/// # Errors
///
/// The database.
pub async fn store_metadata_facts(tx: &Transaction<'_>, document: &DocumentRow) -> Result<Vec<i64>> {
    tx.execute("DELETE FROM facts WHERE document_id = $1 AND prompt_name = $2", &[&document.id, &METADATA_PROMPT])
        .await?;
    if !has_metadata(&document.meta) {
        return Ok(Vec::new());
    }
    let found = document_metadata_facts(tx, document).await?;
    let digest = metadata_prompt_sha256();
    let mut written: Vec<(i64, String)> = Vec::new();
    for (ord, fact) in found.iter().enumerate() {
        let id: i64 = tx
            .query_one(
                "INSERT INTO facts (document_id, ord, fact, fact_class, attributes, char_start, char_end, extractor, \
                                    extractor_model, prompt_name, prompt_sha256) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULL, $9, $10) RETURNING id",
                &[
                    &document.id,
                    &to_i32(ord),
                    &fact.text,
                    &fact.fact_class,
                    &Value::Object(fact.attributes.clone()),
                    &fact.char_start,
                    &fact.char_end,
                    &METADATA_EXTRACTOR,
                    &METADATA_PROMPT,
                    &digest,
                ],
            )
            .await?
            .get(0);
        written.push((id, fact.text.clone()));
    }
    record_run(tx, document, METADATA_PROMPT, &digest, METADATA_EXTRACTOR, written.len()).await?;
    queue_for_embedding(tx, document.id, &written, METADATA_CHUNKER).await?;
    Ok(written.into_iter().map(|(id, _)| id).collect())
}

/// Replaces `prompt`'s earlier facts for the document with `extracted`, in appearance order, each
/// with a chunk for the backfill, and records the run; the ids written (`extract_and_store_facts`'s
/// storage, after the model answered).
///
/// # Errors
///
/// The database.
pub async fn store_prompt_facts(
    tx: &Transaction<'_>,
    document: &DocumentRow,
    prompt: &EffectivePrompt,
    model_id: &str,
    extracted: &[Extracted],
) -> Result<Vec<i64>> {
    tx.execute("DELETE FROM facts WHERE document_id = $1 AND prompt_name = $2", &[&document.id, &prompt.name]).await?;
    let digest = prompt.sha256();
    let mut written: Vec<(i64, String)> = Vec::new();
    for (ord, fact) in extracted.iter().enumerate() {
        let id: i64 = tx
            .query_one(
                "INSERT INTO facts (document_id, ord, fact, fact_class, attributes, char_start, char_end, extractor, \
                                    extractor_model, prompt_name, prompt_sha256) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, 'langextract', $8, $9, $10) RETURNING id",
                &[
                    &document.id,
                    &to_i32(ord),
                    &fact.text,
                    &fact.fact_class,
                    &Value::Object(fact.attributes.clone()),
                    &fact.char_start,
                    &fact.char_end,
                    &model_id,
                    &prompt.name,
                    &digest,
                ],
            )
            .await?
            .get(0);
        written.push((id, fact.text.clone()));
    }
    record_run(tx, document, &prompt.name, &digest, model_id, written.len()).await?;
    queue_for_embedding(tx, document.id, &written, &format!("facts:langextract:{model_id}")).await?;
    Ok(written.into_iter().map(|(id, _)| id).collect())
}

// ---------------------------------------------------------------------------
// The loop

/// One document processed: `index` of `total`, with its fact count or error (`EnrichEvent`).
/// `prompts` are the prompts that ran on it; `skipped` when none did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EnrichEvent {
    pub index: i64,
    pub total: i64,
    pub document_id: i64,
    pub uri: String,
    pub facts: i64,
    pub error: Option<String>,
    pub prompts: Vec<String>,
    pub skipped: bool,
}

impl EnrichEvent {
    /// The RPC's line for the document.
    pub fn message(&self) -> String {
        let subject = if self.uri.is_empty() { self.document_id.to_string() } else { self.uri.clone() };
        let outcome = match &self.error {
            Some(error) => error.clone(),
            None if self.skipped => "skipped".to_owned(),
            None => format!("{} facts", self.facts),
        };
        format!("{}/{}: {subject}: {outcome}", self.index, self.total)
    }
}

/// A run's totals (`EnrichSummary`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EnrichSummary {
    pub model_id: String,
    pub provider: String,
    pub total: i64,
    pub enriched: i64,
    pub facts: i64,
    pub failed: i64,
    pub skipped: i64,
    pub prompts: Vec<String>,
}

impl EnrichSummary {
    /// `EnrichSummary.message`.
    pub fn message(&self) -> String {
        let mut text = format!(
            "{}/{} documents enriched, {} facts extracted",
            self.enriched,
            self.total,
            crate::service::thousands(self.facts)
        );
        if self.skipped > 0 {
            let _ = write!(text, ", {} skipped", self.skipped);
        }
        if self.failed > 0 {
            let _ = write!(text, ", {} failed", self.failed);
        }
        text
    }
}

/// How a run is asked for.
pub struct EnrichRun<'a> {
    pub documents: Vec<DocumentRow>,
    /// The prompts selected, enabled ones or the ones named; each applies by its scope.
    pub selected: Vec<EffectivePrompt>,
    pub model: FactModel,
    pub servers: Settings,
    pub stale_only: bool,
    /// The model's side; `None` when this process has none, which fails each prompt's run.
    pub extractor: Option<Arc<dyn FactExtractor>>,
    /// Receives each document's event; `false` stops the run (the client went away).
    pub on_event: &'a mut (dyn FnMut(&EnrichEvent) -> bool + Send + Sync),
}

/// Runs `prompt` on the document in its own transaction: the egress check, the model, then the
/// facts stored; how many.
async fn run_prompt(
    client: &mut Client,
    document: &DocumentRow,
    prompt: &EffectivePrompt,
    run: &EnrichRun<'_>,
) -> Result<usize> {
    run.model.check_egress(&document.corpus_class, &run.servers).map_err(|e| ServiceError::PermissionDenied(e.0))?;
    let extracted = match document.content.as_deref().filter(|c| !c.is_empty()) {
        None => Vec::new(),
        Some(text) => {
            let Some(extractor) = run.extractor.clone() else {
                return Err(ServiceError::Unavailable(
                    "fact extraction with a model is not available in this build; metadata facts were written".into(),
                ));
            };
            let (model, servers, corpus_class, prompt_copy, text) = (
                run.model.clone(),
                run.servers.clone(),
                document.corpus_class.clone(),
                prompt.clone(),
                text.to_owned(),
            );
            tokio::task::spawn_blocking(move || extractor.extract(&model, &servers, &corpus_class, &prompt_copy, &text))
                .await
                .unwrap_or_else(|e| Err(format!("extractor panicked: {e}")))
                .map_err(ServiceError::Unavailable)?
        }
    };
    let tx = client.transaction().await?;
    let written = store_prompt_facts(&tx, document, prompt, &run.model.model_id, &extracted).await?;
    tx.commit().await?;
    Ok(written.len())
}

/// Distils the documents into atomic facts, once per prompt, reporting each document
/// (`enrich_facts`). One failing document is recorded and the run continues.
///
/// # Errors
///
/// The database, or a client that went away.
pub async fn enrich_facts(client: &mut Client, mut run: EnrichRun<'_>) -> Result<EnrichSummary> {
    let total = i64::try_from(run.documents.len()).unwrap_or(i64::MAX);
    let (mut failed, mut skipped, mut total_facts) = (0i64, 0i64, 0i64);
    let documents = std::mem::take(&mut run.documents);
    for (i, document) in documents.iter().enumerate() {
        let mut event = EnrichEvent {
            index: i64::try_from(i + 1).unwrap_or(i64::MAX),
            total,
            document_id: document.id,
            uri: document.uri.clone(),
            ..EnrichEvent::default()
        };
        let mut applicable: Vec<&EffectivePrompt> = run
            .selected
            .iter()
            .filter(|p| p.applies_to(Some(&document.corpus_class), Some(&document.source_slug)))
            .collect();
        let runs = if run.stale_only { fact_runs(client, document.id).await? } else { HashMap::new() };
        if run.stale_only && !applicable.is_empty() {
            applicable.retain(|p| prompt_is_stale(runs.get(&p.name), document, p, &run.model.model_id));
        }
        let mut errors: Vec<String> = Vec::new();
        // A mail's sender, recipients and subject, a thread's participants: no model, nothing sent.
        if !run.stale_only || metadata_is_stale(runs.get(METADATA_PROMPT), document) {
            match store_metadata(client, document).await {
                Ok(written) if written > 0 => {
                    event.facts += i64::try_from(written).unwrap_or(i64::MAX);
                    event.prompts.push(METADATA_PROMPT.to_owned());
                }
                Ok(_) => {}
                Err(error) => errors.push(format!("{METADATA_PROMPT}: {}", error.message())),
            }
        }
        for prompt in &applicable {
            match run_prompt(client, document, prompt, &run).await {
                Ok(written) => {
                    event.facts += i64::try_from(written).unwrap_or(i64::MAX);
                    event.prompts.push(prompt.name.clone());
                }
                Err(error) => errors.push(if applicable.len() > 1 {
                    format!("{}: {}", prompt.name, error.message())
                } else {
                    error.message().to_owned()
                }),
            }
        }
        total_facts += event.facts;
        if !errors.is_empty() {
            failed += 1;
            event.error = Some(errors.join("; "));
        } else if applicable.is_empty() && event.prompts.is_empty() {
            skipped += 1;
            event.skipped = true;
        }
        if !(run.on_event)(&event) {
            return Err(ServiceError::Failed("enrich-facts cancelled: the client went away".into()));
        }
    }
    Ok(EnrichSummary {
        model_id: run.model.model_id.clone(),
        provider: run.model.provider.clone(),
        total,
        enriched: total - failed - skipped,
        facts: total_facts,
        failed,
        skipped,
        prompts: run.selected.iter().map(|p| p.name.clone()).collect(),
    })
}

async fn store_metadata(client: &mut Client, document: &DocumentRow) -> Result<usize> {
    let tx = client.transaction().await?;
    let written = store_metadata_facts(&tx, document).await?;
    tx.commit().await?;
    Ok(written.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTENT: &str = "Subject: Re: FW: Roof  quote\n\
                           From: Ada Lovelace <ada@example.com>\n\
                           To: bob@example.com, Carol <carol@example.com>\n\
                           Cc: Ada Lovelace <ada@example.com>\n\
                           Date: Tue, 29 Sep 2026 10:00:00 +0000\n\
                           \n\
                           Bob, the quote from bob@example.com's roofer is attached.";

    fn meta() -> Map<String, Value> {
        let mut meta = Map::new();
        meta.insert("email_from".into(), "Ada Lovelace <ada@example.com>".into());
        meta.insert("email_to".into(), "bob@example.com, Carol <carol@example.com>".into());
        meta.insert("email_cc".into(), "Ada Lovelace <ada@example.com>".into());
        meta
    }

    fn slice(content: &str, start: Option<i32>, end: Option<i32>) -> String {
        let (start, end) = (usize::try_from(start.unwrap()).unwrap(), usize::try_from(end.unwrap()).unwrap());
        content.chars().skip(start).take(end - start).collect()
    }

    #[test]
    fn subjects_normalize_as_python() {
        for (subject, key) in [
            ("Roof quote", "roof quote"),
            ("Re: Roof quote", "roof quote"),
            ("RE: Fwd: re:  Roof   Quote ", "roof quote"),
            ("[External] AW: Roof quote", "roof quote"),
            ("Re[2]: Roof quote", "roof quote"),
            ("Regarding the roof", "regarding the roof"),
            ("Re:", ""),
        ] {
            assert_eq!(normalize_subject(subject), key, "{subject:?}");
        }
    }

    #[test]
    fn a_mails_sender_recipients_and_subject_are_grounded_in_its_header() {
        let author_of: HashMap<String, i64> = [("ada@example.com".to_owned(), 7)].into_iter().collect();
        let facts = mail_facts(CONTENT, &meta(), &author_of);
        assert_eq!(
            facts.iter().map(|f| (f.fact_class.as_str(), f.text.as_str(), f.key.as_str())).collect::<Vec<_>>(),
            [
                ("sender", "Ada Lovelace <ada@example.com>", "author:7"),
                ("recipient", "bob@example.com", "email:bob@example.com"),
                ("recipient", "Carol <carol@example.com>", "email:carol@example.com"),
                // Ada is also on Cc: one recipient fact for her, beside the sender fact.
                ("recipient", "Ada Lovelace <ada@example.com>", "author:7"),
                ("subject", "Re: FW: Roof  quote", "subject:roof quote"),
            ]
        );
        for fact in &facts {
            assert_eq!(slice(CONTENT, fact.char_start, fact.char_end), fact.text);
            assert_eq!(fact.attributes["key"], fact.key);
            assert!(FACT_CLASSES.contains(&fact.fact_class.as_str()));
        }
        // Grounded in the header, not in the body where the address appears again.
        let header_end = to_i32(CONTENT.find("\n\n").unwrap());
        assert!(facts[1].char_start.unwrap() < header_end);
        assert!(facts[3].char_start.unwrap() > to_i32(CONTENT.find("Cc: ").unwrap()));
        assert_eq!(facts[0].attributes["name"], "Ada Lovelace");
        assert_eq!(facts[0].attributes["header"], "from");
        assert_eq!(facts[1].attributes.get("name"), None);
    }

    #[test]
    fn a_mail_without_a_subject_line_has_no_subject_fact() {
        let mut meta = Map::new();
        meta.insert("email_from".into(), "ada@example.com".into());
        let facts = mail_facts("From: ada@example.com\n\nNo subject here.", &meta, &HashMap::new());
        assert_eq!(facts.len(), 1);
        assert_eq!((facts[0].fact_class.as_str(), facts[0].key.as_str()), ("sender", "email:ada@example.com"));
    }

    #[test]
    fn an_address_the_header_block_does_not_carry_is_kept_ungrounded() {
        let mut meta = Map::new();
        meta.insert("email_from".into(), "Ada <ada@example.com>".into());
        let facts = mail_facts("Subject: Hi\n\nbody", &meta, &HashMap::new());
        let sender = &facts[0];
        assert_eq!((sender.text.as_str(), sender.char_start, sender.char_end), ("ada@example.com", None, None));
    }

    #[test]
    fn spans_count_code_points() {
        let mut meta = Map::new();
        meta.insert("email_from".into(), "Zoë <zoe@x.org>".into());
        let content = "From: Zoë <zoe@x.org>\nSubject: Café ☕ plans\n\nbody";
        let facts = mail_facts(content, &meta, &HashMap::new());
        // The encoded word is not in the header, so the address alone is quoted, grounded.
        assert_eq!(facts[0].text, "zoe@x.org");
        assert_eq!(slice(content, facts[0].char_start, facts[0].char_end), "zoe@x.org");
        assert_eq!(facts[1].text, "Café ☕ plans");
        assert_eq!(facts[1].key, "subject:café ☕ plans");
        assert_eq!(slice(content, facts[1].char_start, facts[1].char_end), "Café ☕ plans");
    }

    #[test]
    fn a_threads_participants_are_keyed_on_their_authors() {
        let content = "[2026-09-24 12:00 UTC] Ada: on my way\n[2026-09-24 12:01 UTC] Me: see you";
        let participants = vec![
            (3, "Ada".to_owned(), "sender".to_owned()),
            (4, "Bob".to_owned(), "recipient".to_owned()),
            (5, "Eve".to_owned(), "cc".to_owned()),
        ];
        let facts = conversation_facts(content, &participants);
        assert_eq!(
            facts
                .iter()
                .map(|f| (f.fact_class.as_str(), f.text.as_str(), f.key.as_str(), f.char_start))
                .collect::<Vec<_>>(),
            [
                ("sender", "Ada", "author:3", Some(to_i32(content.find("Ada").unwrap()))),
                ("recipient", "Bob", "author:4", None),
            ]
        );
    }

    #[test]
    fn only_mail_and_threads_have_metadata_facts() {
        let document = |meta: Value| DocumentRow {
            id: 1,
            source_id: 1,
            source_slug: "s".into(),
            uri: String::new(),
            corpus_class: "document".into(),
            content: None,
            content_sha256: b"x".to_vec(),
            meta,
        };
        let mail = document(serde_json::json!({"email_from": "a@b.c"}));
        let thread = document(serde_json::json!({"chat_guid": "g"}));
        let note = document(serde_json::json!({}));
        assert!(has_metadata(&mail.meta) && has_metadata(&thread.meta) && !has_metadata(&note.meta));
        assert!(metadata_is_stale(None, &mail));
        assert!(!metadata_is_stale(None, &note));
        let run = FactRun {
            prompt_sha256: metadata_prompt_sha256(),
            content_sha256: b"x".to_vec(),
            extractor_model: "metadata".into(),
        };
        assert!(!metadata_is_stale(Some(&run), &mail));
        let run = FactRun { content_sha256: b"y".to_vec(), ..run };
        assert!(metadata_is_stale(Some(&run), &mail));
        assert_eq!(
            crate::db::hex_string(&metadata_prompt_sha256()),
            crate::db::hex_string(&sha256::digest(b"metadata:1"))
        );
    }

    #[test]
    fn cloud_models_and_unknown_providers_are_refused() {
        assert!(refuse_cloud_model_id("gemma2:2b").is_ok());
        assert!(refuse_cloud_model_id("gpt-oss:20b").is_ok());
        let error = refuse_cloud_model_id("gpt-4o").unwrap_err();
        assert_eq!(
            error.message(),
            "'gpt-4o' names a cloud-hosted model; fact distillation runs only on local models (facts.provider ollama, \
             llama_xpc, lmstudio)"
        );
        assert!(refuse_cloud_model_id("Claude-3").is_err() && refuse_cloud_model_id("o3-mini").is_err());
        let servers = Settings::default();
        let error = FactModel::new("cloud", "m", &servers).unwrap_err();
        assert_eq!(
            error.message(),
            "unknown fact-distil provider 'cloud'; expected one of ('ollama', 'llama_xpc', 'lmstudio')"
        );
        let model = FactModel::new("llama_xpc", "gemma2-2b", &servers).unwrap();
        assert!(model.loopback_only && model.host_url == servers.llama_host);
        assert!(model.check_egress("communication", &servers).is_ok());
        let elsewhere = Settings { ollama_host: "http://gpu.local:11434".into(), ..Settings::default() };
        let remote = FactModel::new("ollama", "m", &elsewhere).unwrap();
        assert!(remote.check_egress("document", &elsewhere).is_ok());
        let blocked = remote.check_egress("communication", &elsewhere).unwrap_err();
        assert!(blocked.0.starts_with("facts:ollama: communications never leave this machine"), "{}", blocked.0);
    }

    #[test]
    fn messages_follow_python() {
        let event = EnrichEvent {
            index: 2,
            total: 5,
            document_id: 9,
            uri: "file:///a.md".into(),
            facts: 3,
            ..Default::default()
        };
        assert_eq!(event.message(), "2/5: file:///a.md: 3 facts");
        let event = EnrichEvent { uri: String::new(), skipped: true, ..event };
        assert_eq!(event.message(), "2/5: 9: skipped");
        let event = EnrichEvent { error: Some("boom".into()), ..event };
        assert_eq!(event.message(), "2/5: 9: boom");
        let summary = EnrichSummary { total: 5, enriched: 3, facts: 1200, failed: 1, skipped: 1, ..Default::default() };
        assert_eq!(summary.message(), "3/5 documents enriched, 1,200 facts extracted, 1 skipped, 1 failed");
    }
}
