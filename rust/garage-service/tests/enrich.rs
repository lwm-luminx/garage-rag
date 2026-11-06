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
        _corpus_class: &str,
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

/// A model server on loopback that answers every chat as the UI tests' `DeterministicLlamaEngine`
/// does: LangExtract's fenced JSON with one `fact` per sentence (of five words or more) of the
/// prompt's final `Q: ` text. Returns its URL and the prompts it was sent.
fn sentence_server() -> (String, Arc<Mutex<Vec<String>>>) {
    use std::io::{BufRead, BufReader, Read, Write};

    fn answer(prompt: &str) -> String {
        let question = prompt
            .trim_end()
            .strip_suffix("\nA:")
            .and_then(|body| body.rfind("\nQ: ").map(|i| body[i + 4..].to_owned()))
            .unwrap_or_default();
        let extractions: Vec<serde_json::Value> = question
            .lines()
            .flat_map(|line| line.split_inclusive(['.', '!', '?']))
            .map(str::trim)
            .filter(|s| s.ends_with(['.', '!', '?']) && s.split(' ').count() >= 5)
            .map(|s| json!({"fact": s}))
            .collect();
        format!("```json\n{}\n```", serde_json::to_string_pretty(&json!({"extractions": extractions})).unwrap())
    }

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let prompts: Arc<Mutex<Vec<String>>> = Arc::default();
    let seen = prompts.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let (mut line, mut length) = (String::new(), 0usize);
            reader.read_line(&mut line).unwrap();
            assert!(line.starts_with("POST /v1/chat/completions "), "{line}");
            loop {
                line.clear();
                reader.read_line(&mut line).unwrap();
                if line.trim().is_empty() {
                    break;
                }
                if let Some((name, value)) = line.split_once(':')
                    && name.eq_ignore_ascii_case("content-length")
                {
                    length = value.trim().parse().unwrap();
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let request: serde_json::Value = serde_json::from_slice(&body).unwrap();
            let prompt =
                request["messages"].as_array().unwrap().last().unwrap()["content"].as_str().unwrap().to_owned();
            let reply =
                json!({"choices": [{"message": {"role": "assistant", "content": answer(&prompt)}}]}).to_string();
            seen.lock().unwrap().push(prompt);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                reply.len()
            )
            .unwrap();
        }
    });
    (url, prompts)
}

#[test]
fn langextract_distils_grounded_facts_through_a_local_model_server() {
    use garage_service::host::PlainHost;
    use garage_service::langextract::LangExtractor;

    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let notes = source(&client, "notes", json!({})).await;
            let text = "# Acme\n\nAcme was founded in 1998 by Zoë Smith. It makes anvils for the whole valley.\n\
                        Short one. The roof was replaced after the storm last spring!";
            let note = document(&client, notes, "acme.md", text, "document").await;
            let thread = document(
                &client,
                notes,
                "thread",
                "Ada: the plumber is coming on Tuesday at nine.\nBob: ok",
                "communication",
            )
            .await;

            let (url, prompts) = sentence_server();
            let servers = Settings { llama_host: url.clone(), ..Settings::default() };
            let host = Arc::new(PlainHost::with_sockets(tokio::runtime::Handle::current(), None, None));
            let extractor = Arc::new(LangExtractor::new(host));
            let mut on_event = |_: &EnrichEvent| true;
            let documents = documents_to_enrich(&client, "notes", None).await.unwrap();
            let summary = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected: effective_prompts(&[]).unwrap(),
                    model: model("llama_xpc", "gemma2-2b", &servers),
                    servers: servers.clone(),
                    stale_only: false,
                    extractor: Some(extractor),
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap();
            assert_eq!((summary.total, summary.enriched, summary.failed, summary.facts), (2, 2, 0, 4), "{summary:?}");
            assert_eq!(prompts.lock().unwrap().len(), 2, "one prompt per document, each to the loopback server");

            let rows = |document_id: i64| {
                let client = &client;
                async move {
                    client
                        .query(
                            "SELECT fact, fact_class, extractor, extractor_model, char_start, char_end, \
                                    (SELECT content FROM documents WHERE id = document_id) \
                             FROM facts WHERE document_id = $1 ORDER BY ord",
                            &[&document_id],
                        )
                        .await
                        .unwrap()
                }
            };
            let facts = rows(note).await;
            assert_eq!(
                facts.iter().map(|r| r.get::<_, String>(0)).collect::<Vec<_>>(),
                [
                    "Acme was founded in 1998 by Zoë Smith.",
                    "It makes anvils for the whole valley.",
                    "The roof was replaced after the storm last spring!"
                ]
            );
            for row in facts.iter().chain(rows(thread).await.iter()) {
                let (fact, start, end, content): (String, i32, i32, String) =
                    (row.get(0), row.get(4), row.get(5), row.get(6));
                let (start, end) = (usize::try_from(start).unwrap(), usize::try_from(end).unwrap());
                assert_eq!(content.chars().skip(start).take(end - start).collect::<String>(), fact, "grounded");
                assert_eq!(
                    (row.get::<_, String>(1), row.get::<_, String>(2), row.get::<_, String>(3)),
                    ("fact".to_owned(), "langextract".to_owned(), "gemma2-2b".to_owned())
                );
            }
            let chunks: i64 = scalar(
                &client,
                "SELECT count(*) FROM chunks WHERE fact_id IS NOT NULL AND chunker = 'facts:langextract:gemma2-2b'",
                &[],
            )
            .await;
            assert_eq!(chunks, 4);
            let run: i32 = scalar(
                &client,
                "SELECT facts FROM fact_runs WHERE document_id = $1 AND prompt_name = 'default'",
                &[&note],
            )
            .await;
            assert_eq!(run, 3);

            // An off-box Ollama: the communication is refused before anything is sent.
            let before = prompts.lock().unwrap().len();
            let documents = documents_to_enrich(&client, "*", Some(thread)).await.unwrap();
            let elsewhere = Settings { ollama_host: "http://models.example.net:11434".into(), ..Settings::default() };
            let host = Arc::new(PlainHost::with_sockets(tokio::runtime::Handle::current(), None, None));
            let summary = enrich_facts(
                &mut client,
                EnrichRun {
                    documents,
                    selected: effective_prompts(&[]).unwrap(),
                    model: model("ollama", "gemma2:2b", &elsewhere),
                    servers: elsewhere,
                    stale_only: false,
                    extractor: Some(Arc::new(LangExtractor::new(host))),
                    on_event: &mut on_event,
                },
            )
            .await
            .unwrap();
            assert_eq!(summary.failed, 1);
            assert_eq!(prompts.lock().unwrap().len(), before, "nothing was sent");
        })
    });
}
