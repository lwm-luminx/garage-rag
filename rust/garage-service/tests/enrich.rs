//! `enrich-facts` against a real database (`enrich/facts.py`, `enrich/metadata.py`): a mail's and a
//! thread's metadata facts with no model, a prompt's facts through an extractor, each with its chunk
//! and its `fact_runs` row, `stale_only`, the egress rule on a communication, a build with no
//! extractor, and a client that went away. Needs `GARAGE_TEST_DATABASE_URL`.

#![allow(clippy::too_many_lines)]

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use garage_embed::Settings;
use garage_service::enrich::{
    EnrichEvent, EnrichRun, Extracted, FactExtractor, FactModel, documents_to_enrich, enrich_facts,
};
use garage_service::prompts::{EffectivePrompt, effective_prompts};
use serde_json::{Map, json};

/// An extractor that finds the first line of whatever it is given, and remembers the asks.
struct Fake {
    asked: Mutex<Vec<(String, String, String)>>,
}

impl FactExtractor for Fake {
    fn extract(
        &self,
        model: &FactModel,
        _servers: &Settings,
        prompt: &EffectivePrompt,
        text: &str,
    ) -> Result<Vec<Extracted>, String> {
        self.asked.lock().unwrap().push((model.model_id.clone(), prompt.name.clone(), text.to_owned()));
        let end = text.find('\n').map_or(text.chars().count(), |i| text[..i].chars().count());
        Ok(vec![Extracted {
            fact_class: "fact".into(),
            text: text.chars().take(end).collect(),
            attributes: Map::new(),
            char_start: 0,
            char_end: i32::try_from(end).unwrap(),
        }])
    }
}

const MAIL: &str = "Subject: Re: Roof quote\n\
                    From: Ada Lovelace <ada@example.com>\n\
                    To: bob@example.com\n\
                    \n\
                    Bob, the quote is attached.";

async fn set_meta(client: &Client, document_id: i64, meta: serde_json::Value) {
    client
        .execute(
            "UPDATE documents SET meta = CAST($2::text AS jsonb) WHERE id = $1",
            &[&document_id, &meta.to_string()],
        )
        .await
        .unwrap();
}

async fn facts_of(client: &Client, document_id: i64) -> Vec<(String, String, String, String)> {
    client
        .query(
            "SELECT fact_class, fact, extractor, prompt_name FROM facts WHERE document_id = $1 ORDER BY prompt_name, ord",
            &[&document_id],
        )
        .await
        .unwrap()
        .iter()
        .map(|r| (r.get(0), r.get(1), r.get(2), r.get(3)))
        .collect()
}

fn model(provider: &str, model_id: &str, servers: &Settings) -> FactModel {
    FactModel::new(provider, model_id, servers).unwrap()
}

#[test]
fn documents_are_enriched_with_metadata_and_prompt_facts() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let mail = source(&client, "mail", json!({})).await;
            let notes = source(&client, "notes", json!({})).await;
            let ada: i64 = client
                .query_one("INSERT INTO authors (display_name) VALUES ('Ada Lovelace') RETURNING id", &[])
                .await
                .unwrap()
                .get(0);
            client
                .execute(
                    "INSERT INTO author_identities (author_id, kind, value) VALUES ($1, 'email', 'ada@example.com')",
                    &[&ada],
                )
                .await
                .unwrap();
            let letter = document(&client, mail, "letter.eml", MAIL, "communication").await;
            set_meta(
                &client,
                letter,
                json!({"email_from": "Ada Lovelace <ada@example.com>", "email_to": "bob@example.com"}),
            )
            .await;
            let thread = document(&client, mail, "thread", "Ada Lovelace: hi\nBob: hello", "communication").await;
            set_meta(&client, thread, json!({"chat_guid": "iMessage;-;+15551234567"})).await;
            client
                .execute(
                    "INSERT INTO document_authors (document_id, author_id, role) VALUES ($1, $2, 'sender')",
                    &[&thread, &ada],
                )
                .await
                .unwrap();
            let note =
                document(&client, notes, "note.md", "Acme was founded in 1998. It makes anvils.", "document").await;
            let empty = document(&client, notes, "empty.md", "", "document").await;

            let servers = Settings::default();
            let selected = effective_prompts(&[]).unwrap();
            let fake = Arc::new(Fake { asked: Mutex::new(Vec::new()) });
            let events: Arc<Mutex<Vec<EnrichEvent>>> = Arc::default();
            let seen = events.clone();
            let mut on_event = move |event: &EnrichEvent| {
                seen.lock().unwrap().push(event.clone());
                true
            };
            let documents = documents_to_enrich(&client, "*", None).await.unwrap();
            assert_eq!(documents.iter().map(|d| d.id).collect::<Vec<_>>(), [letter, thread, note, empty]);
            assert_eq!(documents[0].source_slug, "mail");
            let summary = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected: selected.clone(),
                    model: model("llama_xpc", "gemma2-2b", &servers),
                    servers: servers.clone(),
                    stale_only: false,
                    extractor: Some(fake.clone()),
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap();
            assert_eq!((summary.total, summary.enriched, summary.failed, summary.skipped), (4, 4, 0, 0));
            // The letter: sender, recipient, subject, plus its first line; the thread: Ada, plus a
            // line; the note: a line; the empty document: nothing, but it still ran.
            assert_eq!(summary.facts, 3 + 1 + 1 + 1 + 1);
            assert_eq!(summary.message(), "4/4 documents enriched, 7 facts extracted");
            assert_eq!(summary.prompts, ["default"]);
            assert_eq!(
                facts_of(&client, letter).await,
                [
                    (
                        "fact".to_owned(),
                        "Subject: Re: Roof quote".to_owned(),
                        "langextract".to_owned(),
                        "default".to_owned()
                    ),
                    (
                        "sender".to_owned(),
                        "Ada Lovelace <ada@example.com>".to_owned(),
                        "metadata".to_owned(),
                        "metadata".to_owned()
                    ),
                    (
                        "recipient".to_owned(),
                        "bob@example.com".to_owned(),
                        "metadata".to_owned(),
                        "metadata".to_owned()
                    ),
                    ("subject".to_owned(), "Re: Roof quote".to_owned(), "metadata".to_owned(), "metadata".to_owned()),
                ]
            );
            assert_eq!(
                facts_of(&client, thread).await.iter().map(|f| (f.0.as_str(), f.1.as_str())).collect::<Vec<_>>(),
                [("fact", "Ada Lovelace: hi"), ("sender", "Ada Lovelace")]
            );
            let events = events.lock().unwrap().clone();
            assert_eq!(events.len(), 4);
            assert_eq!(events[0].prompts, ["metadata", "default"]);
            assert_eq!(events[0].message(), "1/4: test://letter.eml: 4 facts");
            assert_eq!(events[2].prompts, ["default"]);
            assert_eq!(events[3].message(), "4/4: test://empty.md: 0 facts");
            assert!(!events[3].skipped, "a prompt ran, with nothing to read");
            // Every fact has a chunk for the backfill, after the document's own, and a run is recorded.
            let chunks: i64 = scalar(
                &client,
                "SELECT count(*) FROM chunks WHERE document_id = $1 AND fact_id IS NOT NULL AND chunker LIKE 'facts:%'",
                &[&letter],
            )
            .await;
            assert_eq!(chunks, 4);
            let chunkers: Vec<String> = client
                .query("SELECT DISTINCT chunker FROM chunks WHERE document_id = $1 ORDER BY 1", &[&letter])
                .await
                .unwrap()
                .iter()
                .map(|r| r.get(0))
                .collect();
            assert_eq!(chunkers, ["facts:langextract:gemma2-2b", "facts:metadata:1"]);
            let runs: Vec<(String, String, i32)> = client
                .query(
                    "SELECT prompt_name, extractor_model, facts FROM fact_runs WHERE document_id = $1 ORDER BY 1",
                    &[&letter],
                )
                .await
                .unwrap()
                .iter()
                .map(|r| (r.get(0), r.get(1), r.get(2)))
                .collect();
            assert_eq!(
                runs,
                [("default".to_owned(), "gemma2-2b".to_owned(), 1), ("metadata".to_owned(), "metadata".to_owned(), 3)]
            );
            assert_eq!(fake.asked.lock().unwrap().len(), 3, "the empty document is not sent");

            // Nothing changed: stale_only skips every document.
            let mut on_event = |_: &EnrichEvent| true;
            let documents = documents_to_enrich(&client, "*", None).await.unwrap();
            let summary = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected: selected.clone(),
                    model: model("llama_xpc", "gemma2-2b", &servers),
                    servers: servers.clone(),
                    stale_only: true,
                    extractor: Some(fake.clone()),
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap();
            assert_eq!((summary.enriched, summary.skipped, summary.facts), (0, 4, 0));
            assert_eq!(summary.message(), "0/4 documents enriched, 0 facts extracted, 4 skipped");
            // A different model makes the prompt stale again, but not the metadata.
            let documents = documents_to_enrich(&client, "notes", None).await.unwrap();
            assert_eq!(documents.len(), 2);
            let summary = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected: selected.clone(),
                    model: model("ollama", "gpt-oss:20b", &servers),
                    servers: servers.clone(),
                    stale_only: true,
                    extractor: Some(fake.clone()),
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap();
            assert_eq!((summary.enriched, summary.skipped, summary.facts), (2, 0, 1));
            assert_eq!(fake.asked.lock().unwrap().last().map(|a| a.0.as_str()), Some("gpt-oss:20b"));
            let runs: i64 =
                scalar(&client, "SELECT count(*) FROM fact_runs WHERE extractor_model = 'gpt-oss:20b'", &[]).await;
            assert_eq!(runs, 2);

            // A communication never goes to a model elsewhere; the metadata facts are still written.
            let elsewhere = Settings { ollama_host: "http://models.example.net:11434".into(), ..Settings::default() };
            let documents = documents_to_enrich(&client, "mail", None).await.unwrap();
            let summary = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected: selected.clone(),
                    model: model("ollama", "gpt-oss:20b", &elsewhere),
                    servers: elsewhere.clone(),
                    stale_only: false,
                    extractor: Some(fake.clone()),
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap();
            assert_eq!((summary.enriched, summary.failed, summary.facts), (0, 2, 4));
            assert_eq!(summary.message(), "0/2 documents enriched, 4 facts extracted, 2 failed");
            let facts = facts_of(&client, letter).await;
            assert_eq!(facts.len(), 4, "the earlier prompt facts are kept when the prompt could not run");

            // A build with no extractor writes metadata facts and fails each prompt.
            let documents = documents_to_enrich(&client, "*", Some(note)).await.unwrap();
            let events: Arc<Mutex<Vec<EnrichEvent>>> = Arc::default();
            let seen = events.clone();
            let mut on_event = move |event: &EnrichEvent| {
                seen.lock().unwrap().push(event.clone());
                true
            };
            let summary = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected: selected.clone(),
                    model: model("llama_xpc", "gemma2-2b", &servers),
                    servers: servers.clone(),
                    stale_only: false,
                    extractor: None,
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap();
            assert_eq!((summary.total, summary.failed), (1, 1));
            let events = events.lock().unwrap().clone();
            assert_eq!(
                events[0].error.as_deref(),
                Some("fact extraction with a model is not available in this build; metadata facts were written")
            );
            assert_eq!(
                events[0].message(),
                "1/1: test://note.md: fact extraction with a model is not available in this build; metadata facts were written"
            );

            // The client went away.
            let mut on_event = |_: &EnrichEvent| false;
            let documents = documents_to_enrich(&client, "*", None).await.unwrap();
            let error = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected,
                    model: model("llama_xpc", "gemma2-2b", &servers),
                    servers: servers.clone(),
                    stale_only: false,
                    extractor: Some(fake),
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap_err();
            assert!(error.message().starts_with("enrich-facts cancelled"), "{error:?}");

            let missing = documents_to_enrich(&client, "*", Some(999_999)).await.unwrap_err();
            assert_eq!(missing.message(), "document 999999 not found");
            assert!(documents_to_enrich(&client, "nothing", None).await.unwrap().is_empty());
        })
    });
}
