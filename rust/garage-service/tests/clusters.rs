//! `cluster-facts` against a real database (`enrich/clusters.py`): level 1's restatements, a full
//! run's groups, anchors and singles, then an incremental run that places new facts, asks the model
//! about a loose group and withholds a communication from a model elsewhere. Needs
//! `GARAGE_TEST_DATABASE_URL`.

#![allow(clippy::too_many_lines)]

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use garage_service::clusters::{ClusterParams, ClusterProgress, ClusterRun, Distill, cluster_facts};
use garage_service::config::Config;
use garage_service::models::{ModelSpec, register_model};
use serde_json::json;

/// A model that says every group states one claim, and refuses communications.
struct Fake {
    asked: Mutex<Vec<Vec<String>>>,
}

impl Distill for Fake {
    fn model_id(&self) -> String {
        "fake/model".to_owned()
    }

    fn may_send(&self, corpus_classes: &[&str]) -> bool {
        !corpus_classes.contains(&"communication")
    }

    fn distill(&self, statements: &[String]) -> Result<(bool, Option<String>), String> {
        self.asked.lock().unwrap().push(statements.to_vec());
        Ok((true, Some("Acme was founded in 1998 by Jane Doe.".to_owned())))
    }
}

fn unit(axis: usize, extra: &[(usize, f32)]) -> Vec<f32> {
    let mut v = vec![0.0; 8];
    v[axis] = 1.0;
    for &(i, x) in extra {
        v[i] = x;
    }
    v
}

async fn fact(client: &Client, document_id: i64, ord: i32, text: &str, class: &str, extractor: &str) -> i64 {
    let attributes = if extractor == "metadata" {
        format!(r#"{{"key": "{}:{}"}}"#, class, text.to_lowercase())
    } else {
        "{}".to_owned()
    };
    client
        .query_one(
            "INSERT INTO facts (document_id, ord, fact, fact_class, attributes, extractor, prompt_name) \
             VALUES ($1, $2, $3, $4, CAST($5::text AS jsonb), $6, $7) RETURNING id",
            &[
                &document_id,
                &ord,
                &text,
                &class,
                &attributes,
                &extractor,
                &(if extractor == "metadata" { "metadata" } else { "default" }),
            ],
        )
        .await
        .unwrap()
        .get(0)
}

async fn linked(client: &Client, fact_id: i64) -> (Option<i64>, Option<f32>, Option<i64>) {
    let row = client
        .query_one(
            "SELECT distilled_fact_id, distilled_similarity, restates_fact_id FROM facts WHERE id = $1",
            &[&fact_id],
        )
        .await
        .unwrap();
    (row.get(0), row.get(1), row.get(2))
}

#[test]
fn facts_are_restated_grouped_anchored_and_then_placed() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let model = register_model(&mut client, &ModelSpec::new("tiny", "tiny", 8), true).await.unwrap();
            let notes = source(&client, "notes", json!({})).await;
            let mail = source(&client, "mail", json!({})).await;
            let doc_a = document(&client, notes, "A", "Acme notes.", "document").await;
            let doc_b = document(&client, notes, "B", "More Acme notes.", "document").await;
            let doc_c = document(&client, mail, "Lunch", "Subject: Lunch\n\nLunch is at noon.", "communication").await;
            let f1 = fact(&client, doc_a, 0, "Acme Corp was founded in 1998 by Jane Doe.", "fact", "langextract").await;
            let f2 = fact(&client, doc_a, 1, "Acme was founded in 1998.", "fact", "langextract").await;
            let f3 = fact(&client, doc_a, 2, "The company has 42 employees.", "fact", "langextract").await;
            let f4 = fact(&client, doc_b, 0, "Acme Corporation was founded in 1998.", "fact", "langextract").await;
            let f5 = fact(&client, doc_b, 1, "The company has 45 employees.", "fact", "langextract").await;
            let f6 = fact(&client, doc_c, 0, "Lunch", "subject", "metadata").await;
            let f7 = fact(&client, doc_c, 1, "Lunch is at noon.", "fact", "langextract").await;
            let f8 = fact(&client, doc_b, 2, "Nobody embedded this one.", "fact", "langextract").await;
            for (id, vector) in [
                (f1, unit(0, &[])),
                (f2, unit(0, &[(1, 0.1)])),
                (f3, unit(2, &[])),
                (f4, unit(0, &[(1, 0.08), (3, 0.05)])),
                (f5, unit(2, &[(3, 0.1)])),
                (f6, unit(4, &[])),
                (f7, unit(5, &[])),
            ] {
                embed_fact(&client, &model.table_name, id, &vector, "vector").await;
            }

            let params = ClusterParams::from_config(&Config::defaults(), None, None).unwrap();
            let mut phases: Vec<String> = Vec::new();
            let mut report = |state: &ClusterProgress| {
                phases.push(state.phase.clone());
                true
            };
            let run = ClusterRun {
                params: params.clone(),
                full: false,
                distiller: None,
                report_to: Some(&mut report),
                ef_search: 100,
            };
            let state = cluster_facts(&mut client, &model, run).await.unwrap();
            assert!(phases.contains(&"documents".to_owned()) && phases.contains(&"neighbors".to_owned()));
            assert!(state.full, "no earlier run: the corpus is grouped from scratch");
            assert_eq!((state.facts, state.unembedded, state.restatements), (8, 1, 1));
            assert_eq!((state.nodes, state.anchors, state.anchored), (5, 1, 0));
            assert_eq!((state.clusters, state.clustered_facts, state.distilled_facts), (1, 3, 6));
            assert_eq!((state.accepted, state.distilled, state.kept), (1, 0, 0));
            assert_eq!(state.message(), "");

            // Level 1: f2 restates f1 (the longest), and backs what f1 backs.
            let (group, similarity, representative) = linked(&client, f2).await;
            assert_eq!(representative, Some(f1));
            let (group_of_f1, _, _) = linked(&client, f1).await;
            assert_eq!(group, group_of_f1);
            let within_document: Option<f32> =
                client.query_one("SELECT restates_similarity FROM facts WHERE id = $1", &[&f2]).await.unwrap().get(0);
            assert_eq!(similarity, within_document);
            // Level 2: f1 and f4 are one claim, stated by f1's text since no model was asked.
            let (group_of_f4, _, _) = linked(&client, f4).await;
            assert_eq!(group_of_f4, group_of_f1);
            let row = client
                .query_one(
                    "SELECT statement, statement_generated, model_slug, nodes, representative_fact_id, distill_model \
                     FROM distilled_facts WHERE id = $1",
                    &[&group_of_f1.unwrap()],
                )
                .await
                .unwrap();
            assert_eq!(row.get::<_, String>(0), "Acme Corp was founded in 1998 by Jane Doe.");
            assert!(!row.get::<_, bool>(1));
            assert_eq!(row.get::<_, Option<String>>(2).as_deref(), Some("tiny"));
            assert_eq!((row.get::<_, i32>(3), row.get::<_, Option<i64>>(4)), (2, Some(f1)));
            assert_eq!(row.get::<_, Option<String>>(5), None);
            // The guard keeps 42 and 45 apart; each stands alone, as does the fact with no vector.
            for (id, with_vector) in [(f3, true), (f5, true), (f7, true), (f8, false)] {
                let (did, similarity, _) = linked(&client, id).await;
                assert!(did.is_some() && similarity.is_none(), "{id}");
                let seeded: i64 = client
                    .query_one(
                        "SELECT count(*) FROM fact_emb_tiny WHERE distilled_fact_id = $1 AND seed IS NOT NULL",
                        &[&did],
                    )
                    .await
                    .unwrap()
                    .get(0);
                assert_eq!(seeded, i64::from(with_vector), "{id}");
            }
            assert_ne!(linked(&client, f3).await.0, linked(&client, f5).await.0);
            // The subject is an anchor, linked by its key at similarity 1, with a fixed centroid.
            let (anchor, similarity, _) = linked(&client, f6).await;
            assert_eq!(similarity, Some(1.0));
            let row = client
                .query_one(
                    "SELECT anchor_key, model_slug, nodes FROM distilled_facts WHERE id = $1",
                    &[&anchor.unwrap()],
                )
                .await
                .unwrap();
            assert_eq!(row.get::<_, Option<String>>(0).as_deref(), Some("subject:lunch"));
            assert_eq!(row.get::<_, Option<String>>(1).as_deref(), Some("tiny"));
            assert_eq!(row.get::<_, i32>(2), 1);
            let state_row =
                client.query_one("SELECT model_slug, params FROM fact_cluster_state WHERE id = 1", &[]).await.unwrap();
            assert_eq!(state_row.get::<_, String>(0), "tiny");
            assert_eq!(state_row.get::<_, String>(1), params.corpus_key());

            // Run again: nothing new, nothing changes.
            let run =
                ClusterRun { params: params.clone(), full: false, distiller: None, report_to: None, ef_search: 100 };
            let again = cluster_facts(&mut client, &model, run).await.unwrap();
            assert!(!again.full);
            assert_eq!((again.nodes, again.attached, again.distilled_facts), (0, 0, 6));

            // New facts: one joins the Acme group once the model confirms it; a communication near
            // "42 employees" may not go to the model, so it stays apart.
            let doc_d = document(&client, notes, "D", "Acme again.", "document").await;
            let doc_e = document(&client, mail, "Staff", "The company has 42 employees!", "communication").await;
            let f9 =
                fact(&client, doc_d, 0, "Acme Corp. was founded in 1998 by Jane Doe.", "fact", "langextract").await;
            let f10 = fact(&client, doc_e, 0, "The company has 42 employees!", "fact", "langextract").await;
            embed_fact(&client, &model.table_name, f9, &unit(0, &[(1, 0.05), (3, 0.05)]), "vector").await;
            embed_fact(&client, &model.table_name, f10, &unit(2, &[(3, 0.05)]), "vector").await;
            let fake = Arc::new(Fake { asked: Mutex::new(Vec::new()) });
            let loose = ClusterParams { tight_similarity: 1.0, ..params.clone() };
            let run = ClusterRun {
                params: loose,
                full: false,
                distiller: Some(fake.clone()),
                report_to: None,
                ef_search: 100,
            };
            let placed = cluster_facts(&mut client, &model, run).await.unwrap();
            assert!(!placed.full, "tight_similarity does not shape the groups, so no regrouping");
            assert_eq!((placed.nodes, placed.attached, placed.withheld, placed.distilled), (2, 1, 1, 2));
            assert_eq!((placed.clusters, placed.clustered_facts, placed.distilled_facts), (1, 4, 7));
            let asked = fake.asked.lock().unwrap().clone();
            assert_eq!(asked.len(), 1);
            assert_eq!(asked[0].len(), 3, "the group's members, nearest the centroid first: {asked:?}");
            assert_eq!(linked(&client, f9).await.0, group_of_f1);
            let row = client
                .query_one(
                    "SELECT statement, statement_generated, distill_model, nodes FROM distilled_facts WHERE id = $1",
                    &[&group_of_f1.unwrap()],
                )
                .await
                .unwrap();
            assert_eq!(row.get::<_, String>(0), "Acme was founded in 1998 by Jane Doe.");
            assert!(row.get::<_, bool>(1));
            assert_eq!(row.get::<_, Option<String>>(2).as_deref(), Some("fake/model"));
            assert_eq!(row.get::<_, i32>(3), 3);
            let (own, similarity, _) = linked(&client, f10).await;
            assert!(own.is_some() && similarity.is_none());
            assert_ne!(own, linked(&client, f3).await.0);

            // A binary-quantized model cannot be the clustering model.
            let huge = register_model(&mut client, &ModelSpec::new("huge", "huge", 4096), false).await.unwrap();
            let run =
                ClusterRun { params: params.clone(), full: false, distiller: None, report_to: None, ef_search: 100 };
            let error = cluster_facts(&mut client, &huge, run).await.unwrap_err();
            assert_eq!(error.message(), "huge is binary-quantized; cluster facts under a model with an HNSW index");
        })
    });
}
