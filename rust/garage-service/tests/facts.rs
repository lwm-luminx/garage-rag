//! The facts stage against a real database: the Facts page's listing and counts (`ops/facts.py`)
//! and the AGE projection with its reads (`db/graph.py`). The graph tests need Apache AGE on the
//! server, which the app's Postgres has and the CI image lacks; without it they pass without
//! running and say so. Needs `GARAGE_TEST_DATABASE_URL`.

#![allow(clippy::too_many_lines)]

mod common;

use common::*;
use garage_service::facts::{FactFilters, fact_stats, list_facts};
use garage_service::graph::{Center, age_available, find_vertices, graph_labels, neighborhood, rebuild_graph};
use garage_service::prompts::{GraphSchema, effective_prompts, graph_schema, parse_prompts};
use serde_json::json;

/// Two sources, two documents and four potential facts, two of them behind one distilled fact and
/// one (a mail's subject) anchored. The document ids, the fact ids in insertion order, and the
/// anchored distilled fact's id.
async fn corpus(client: &Client) -> (i64, i64, Vec<i64>, i64) {
    let notes = source(client, "notes", json!({})).await;
    let mail = source(client, "mail", json!({})).await;
    let acme = document(
        client,
        notes,
        "Acme notes",
        "Acme Corp was founded in 1998 by Jane Doe. The company has 42 employees.",
        "document",
    )
    .await;
    let lunch = document(
        client,
        mail,
        "Lunch",
        "From: Ann <ann@example.com>\nSubject: Lunch\n\nLunch is at noon.",
        "communication",
    )
    .await;
    for (document_id, ord, text) in [(acme, 0, "Acme chunk"), (lunch, 0, "Lunch chunk")] {
        let digest = sha256(client, text).await;
        client
            .execute(
                "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker) VALUES ($1, $2, $3, $4, 'test')",
                &[&document_id, &ord, &text, &digest],
            )
            .await
            .unwrap();
    }
    let author: i64 = client
        .query_one("INSERT INTO authors (display_name, is_self) VALUES ('Ann', false) RETURNING id", &[])
        .await
        .unwrap()
        .get(0);
    client
        .execute(
            "INSERT INTO document_authors (document_id, author_id, role, confidence) VALUES ($1, $2, 'sender', 1.0)",
            &[&lunch, &author],
        )
        .await
        .unwrap();
    let mut ids = Vec::new();
    for (document_id, ord, fact, class, start, end, extractor, prompt) in [
        (acme, 0, "Acme Corp was founded in 1998 by Jane Doe.", "fact", 0, 42, "langextract", "default"),
        (acme, 1, "The company has 42 employees.", "fact", 43, 72, "langextract", "default"),
        (lunch, 0, "Lunch", "subject", 37, 42, "metadata", "metadata"),
        (lunch, 1, "Lunch is at noon.", "fact", 44, 61, "langextract", "default"),
    ] {
        let id: i64 = client
            .query_one(
                "INSERT INTO facts (document_id, ord, fact, fact_class, attributes, char_start, char_end, extractor, \
                 extractor_model, prompt_name) \
                 VALUES ($1, $2, $3, $4, CAST($5::text AS jsonb), $6, $7, $8, 'tiny', $9) RETURNING id",
                &[
                    &document_id,
                    &ord,
                    &fact,
                    &class,
                    &(if class == "subject" { r#"{"key": "subject:lunch"}"# } else { "{}" }),
                    &start,
                    &end,
                    &extractor,
                    &prompt,
                ],
            )
            .await
            .unwrap()
            .get(0);
        ids.push(id);
    }
    // One moment for every fact, as one enrich run would leave; the listing then orders by document.
    client.execute("UPDATE facts SET created_at = TIMESTAMPTZ '2026-01-01 00:00:00+00'", &[]).await.unwrap();
    // Facts 1 and 4 state one claim (as far as this test cares); fact 3 is the anchored subject.
    let group: i64 = client
        .query_one(
            "INSERT INTO distilled_facts (fact_class, statement, statement_generated, representative_fact_id, \
             members_sha256, model_slug, threshold, nodes, spread) \
             VALUES ('fact', 'Acme was founded in 1998.', true, $1, '\\x00', 'tiny', 0.9, 2, 0.25) RETURNING id",
            &[&ids[0]],
        )
        .await
        .unwrap()
        .get(0);
    let anchor: i64 = client
        .query_one(
            "INSERT INTO distilled_facts (fact_class, statement, representative_fact_id, members_sha256, anchor_key, \
             nodes) VALUES ('subject', 'Lunch', $1, '\\x01', 'subject:lunch', 1) RETURNING id",
            &[&ids[2]],
        )
        .await
        .unwrap()
        .get(0);
    client
        .execute(
            "UPDATE facts SET distilled_fact_id = $1, distilled_similarity = 0.93 WHERE id = ANY($2)",
            &[&group, &vec![ids[0], ids[3]]],
        )
        .await
        .unwrap();
    client
        .execute("UPDATE facts SET distilled_fact_id = $1, distilled_similarity = 1 WHERE id = $2", &[&anchor, &ids[2]])
        .await
        .unwrap();
    (acme, lunch, ids, anchor)
}

#[test]
fn facts_are_listed_newest_first_filtered_searched_and_collapsed() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            let (acme, lunch, ids, _) = corpus(&client).await;
            let all = list_facts(&client, &FactFilters::default(), 100, 0, false, None).await.unwrap();
            assert_eq!(all.total, 4);
            // Same created_at: the newer document first, then by ord.
            assert_eq!(all.facts.iter().map(|f| f.id).collect::<Vec<_>>(), [ids[2], ids[3], ids[0], ids[1]]);
            assert_eq!(all.classes, [("fact".to_owned(), 3), ("subject".to_owned(), 1)]);
            let first = &all.facts[2];
            assert_eq!(
                (first.document_id, first.source_slug.as_str(), first.corpus_class.as_str()),
                (acme, "notes", "document")
            );
            assert_eq!(
                first.excerpt.as_deref(),
                Some("Acme Corp was founded in 1998 by Jane Doe. The company has 42 employees.")
            );
            assert_eq!(first.excerpt_start, 0);
            assert_eq!(first.distilled_size, 2);
            assert_eq!(first.distilled_statement.as_deref(), Some("Acme was founded in 1998."));
            assert!(first.distilled_generated);
            assert!((first.distilled_spread - 0.25).abs() < 1e-6);
            assert_eq!(first.extractor_model.as_deref(), Some("tiny"));
            assert!(first.created_at.is_some());
            let subject = &all.facts[0];
            assert_eq!(subject.attributes, json!({"key": "subject:lunch"}));
            assert_eq!(subject.extractor, "metadata");

            let searched = list_facts(
                &client,
                &FactFilters { query: "employees".into(), ..FactFilters::default() },
                100,
                0,
                false,
                None,
            )
            .await
            .unwrap();
            assert_eq!(searched.facts.iter().map(|f| f.id).collect::<Vec<_>>(), [ids[1]]);
            let substring = list_facts(
                &client,
                &FactFilters { query: "ploye".into(), ..FactFilters::default() },
                100,
                0,
                false,
                None,
            )
            .await
            .unwrap();
            assert_eq!(substring.total, 1);

            let mail_only = list_facts(
                &client,
                &FactFilters {
                    corpus_class: "communication".into(),
                    fact_class: "fact".into(),
                    ..FactFilters::default()
                },
                100,
                0,
                false,
                None,
            )
            .await
            .unwrap();
            assert_eq!(mail_only.facts.iter().map(|f| f.id).collect::<Vec<_>>(), [ids[3]]);
            // The classes ignore the fact_class filter, not the others.
            assert_eq!(mail_only.classes, [("fact".to_owned(), 1), ("subject".to_owned(), 1)]);
            let by_document = list_facts(
                &client,
                &FactFilters { document_id: Some(lunch), ..FactFilters::default() },
                1,
                1,
                false,
                None,
            )
            .await
            .unwrap();
            assert_eq!((by_document.total, by_document.facts.len(), by_document.facts[0].id), (2, 1, ids[3]));

            // Collapsed: the group's representative stands for it; its other member is hidden.
            let collapsed = list_facts(&client, &FactFilters::default(), 100, 0, true, None).await.unwrap();
            assert_eq!(collapsed.facts.iter().map(|f| f.id).collect::<Vec<_>>(), [ids[2], ids[0], ids[1]]);
            let behind =
                list_facts(&client, &FactFilters::default(), 100, 0, false, collapsed.facts[1].distilled_fact_id)
                    .await
                    .unwrap();
            assert_eq!(behind.facts.iter().map(|f| f.id).collect::<Vec<_>>(), [ids[3], ids[0]]);

            let bad = list_facts(
                &client,
                &FactFilters { corpus_class: "mail".into(), ..FactFilters::default() },
                1,
                0,
                false,
                None,
            )
            .await
            .unwrap_err();
            assert_eq!(bad.message(), "unknown corpus class 'mail' (expected one of document, code, communication)");

            let stats = fact_stats(&client, &FactFilters::default()).await.unwrap();
            assert_eq!((stats.facts, stats.documents), (4, 2));
            assert_eq!(stats.by_source, [("mail".to_owned(), 2), ("notes".to_owned(), 2)].into_iter().collect());
            assert_eq!(stats.by_class, [("fact".to_owned(), 3), ("subject".to_owned(), 1)].into_iter().collect());
            assert_eq!((stats.distilled, stats.clusters, stats.clustered_facts), (2, 1, 2));
            assert_eq!(stats.message(), "4 facts across 2 documents, distilled into 2");
            let notes =
                fact_stats(&client, &FactFilters { source: "notes".into(), ..FactFilters::default() }).await.unwrap();
            assert_eq!((notes.facts, notes.documents, notes.distilled, notes.clusters), (2, 1, 1, 0));
        })
    });
}

#[test]
fn the_graph_is_projected_and_read_back_where_age_exists() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            if !age_available(&client).await.unwrap() {
                eprintln!("the test server has no Apache AGE; the graph tests did not run");
                let summary = rebuild_graph(&mut client, &GraphSchema::default()).await.unwrap();
                assert!(!summary.available);
                assert!(!graph_labels(&mut client).await.unwrap().available);
                return;
            }
            let (acme, _lunch, ids, anchor) = corpus(&client).await;
            assert!(!graph_labels(&mut client).await.unwrap().available, "no graph until it is built");

            let summary = rebuild_graph(&mut client, &GraphSchema::default()).await.unwrap();
            assert!(summary.available);
            assert_eq!(
                summary.vertices,
                [("Document", 2), ("Chunk", 2), ("Author", 1), ("PotentialFact", 4), ("Fact", 2)]
                    .map(|(l, n)| (l.to_owned(), n))
            );
            assert_eq!(
                summary.edges,
                [("HAS_CHUNK", 2), ("WROTE", 1), ("RECEIVED", 0), ("STATES", 4), ("RESTATES", 0), ("SUPPORTS", 3)]
                    .map(|(l, n)| (l.to_owned(), n))
            );
            assert!(summary.message().starts_with("graph 'garage': 2 Document, 2 Chunk, 1 Author"));

            let labels = graph_labels(&mut client).await.unwrap();
            assert!(labels.available);
            assert_eq!(
                labels.vertices.iter().map(|(l, _)| l.as_str()).collect::<Vec<_>>(),
                ["Author", "Chunk", "Document", "Fact", "PotentialFact"]
            );
            assert_eq!(labels.edges.iter().filter(|(_, n)| *n > 0).count(), 4);

            let found = find_vertices(&mut client, "acme", "", 50).await.unwrap();
            let labels_found: Vec<&str> = found.iter().map(|v| v.label.as_str()).collect();
            assert_eq!(labels_found, ["Document", "Fact", "PotentialFact"]);
            assert_eq!((found[0].key, found[0].title.as_str()), (acme, "Acme notes"));
            assert_eq!(found[0].properties["corpus_class"], json!("document"));
            let by_key = find_vertices(&mut client, &ids[1].to_string(), "PotentialFact", 50).await.unwrap();
            assert_eq!(by_key.iter().map(|v| v.key).collect::<Vec<_>>(), [ids[1]]);
            assert_eq!(by_key[0].title, "The company has 42 employees.");
            let first_two = find_vertices(&mut client, "", "", 2).await.unwrap();
            assert_eq!(first_two.len(), 2);
            let unknown = find_vertices(&mut client, "x", "Person", 50).await.unwrap_err();
            assert_eq!(unknown.message(), "the graph has no 'Person' vertices");

            let around =
                neighborhood(&mut client, &Center::Key { label: "Document".into(), key: acme }, 1, None, None, 200)
                    .await
                    .unwrap();
            assert!(around.available);
            assert_eq!(around.center.as_ref().map(|c| c.key), Some(acme));
            let mut labels_around: Vec<&str> = around.vertices.iter().map(|v| v.label.as_str()).collect();
            labels_around.sort_unstable();
            assert_eq!(labels_around, ["Chunk", "Document", "PotentialFact", "PotentialFact"]);
            assert_eq!(around.edges.len(), 3);
            assert!(!around.truncated);
            // Two hops along STATES and SUPPORTS reach the distilled fact and, through it, the mail's fact.
            let deeper = neighborhood(
                &mut client,
                &Center::Id(around.center.as_ref().unwrap().id),
                3,
                None,
                Some(&["STATES".to_owned(), "SUPPORTS".to_owned()]),
                200,
            )
            .await
            .unwrap();
            let mut deeper_labels: Vec<&str> = deeper.vertices.iter().map(|v| v.label.as_str()).collect();
            deeper_labels.sort_unstable();
            assert_eq!(deeper_labels, ["Document", "Fact", "PotentialFact", "PotentialFact", "PotentialFact"]);
            assert!(deeper.edges.iter().all(|e| e.label == "STATES" || e.label == "SUPPORTS"));
            let only_facts = neighborhood(
                &mut client,
                &Center::Key { label: "Document".into(), key: acme },
                1,
                Some(&["PotentialFact".to_owned()]),
                None,
                200,
            )
            .await
            .unwrap();
            assert_eq!(only_facts.vertices.len(), 3);
            let cut = neighborhood(&mut client, &Center::Key { label: "Document".into(), key: acme }, 1, None, None, 2)
                .await
                .unwrap();
            assert_eq!((cut.vertices.len(), cut.truncated), (2, true));
            let missing =
                neighborhood(&mut client, &Center::Key { label: "Document".into(), key: 999_999 }, 1, None, None, 2)
                    .await
                    .unwrap_err();
            assert!(missing.message().starts_with("that vertex is not in the graph"));
            let unnamed = neighborhood(&mut client, &Center::Id(0), 1, None, None, 2).await.unwrap_err();
            assert_eq!(unnamed.message(), "name the vertex by graph id, or by label and relational id");

            // A configured label: the subject's distilled fact becomes a Subject vertex, not a Fact.
            let configured = parse_prompts(&json!([{
                "name": "default",
                "graph": {"vertices": [{"class": "subject", "label": "Subject"}]},
            }]))
            .unwrap();
            let schema = graph_schema(&effective_prompts(&configured).unwrap()).unwrap();
            let again = rebuild_graph(&mut client, &schema).await.unwrap();
            assert_eq!(again.vertices.last(), Some(&("Subject".to_owned(), 1)));
            assert!(again.vertices.contains(&("Fact".to_owned(), 1)));
            assert!(again.edges.contains(&("SUPPORTS".to_owned(), 3)));
            let subjects = find_vertices(&mut client, "lunch", "Subject", 50).await.unwrap();
            assert_eq!(subjects.len(), 1);
            assert_eq!((subjects[0].key, subjects[0].title.as_str()), (anchor, "Lunch"));
            assert_eq!(subjects[0].properties["anchor_key"], json!("subject:lunch"));
        })
    });
}
