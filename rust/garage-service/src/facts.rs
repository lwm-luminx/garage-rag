//! The listing and counts the app's Facts page and `garage facts list|stats` browse potential facts
//! through (`garage_rag.ops.facts`: `list_facts`, `fact_stats`), with the same SQL.

use std::collections::BTreeMap;
use std::fmt::Write;

use chrono::{DateTime, Utc};
use serde_json::Value;
use tokio_postgres::types::ToSql;

use crate::db::Client;
use crate::error::{Result, ServiceError};
use crate::prompts::CORPUS_CLASS_NAMES;

/// Characters of `documents.content` shown either side of a fact's grounded span.
pub const EXCERPT_CONTEXT: i32 = 200;

/// The filters `list_facts` and `fact_stats` share (`_fact_filters`); empty means everything.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FactFilters {
    /// Full-text (stemmed) or substring match on the fact.
    pub query: String,
    pub source: String,
    pub fact_class: String,
    pub corpus_class: String,
    pub document_id: Option<i64>,
}

/// One fact with the document it was distilled from (`FactRow`).
#[derive(Clone, Debug, PartialEq)]
pub struct FactRow {
    pub id: i64,
    pub document_id: i64,
    pub ord: i32,
    pub fact: String,
    pub fact_class: String,
    pub attributes: Value,
    pub char_start: Option<i32>,
    pub char_end: Option<i32>,
    pub extractor: String,
    pub extractor_model: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub document_title: Option<String>,
    pub document_uri: String,
    pub source_slug: String,
    pub corpus_class: String,
    /// The grounded span with [`EXCERPT_CONTEXT`] characters either side, and where it starts in
    /// `documents.content`; none when the fact has no span or the document keeps no content.
    pub excerpt: Option<String>,
    pub excerpt_start: i32,
    /// The distilled fact this potential fact backs, how many potential facts back it, its
    /// statement and whether the local model wrote that statement.
    pub distilled_fact_id: Option<i64>,
    pub distilled_size: i64,
    pub distilled_statement: Option<String>,
    pub distilled_generated: bool,
    /// How varied that distilled fact's group is, and the fact of the same document this one restates.
    pub distilled_spread: f64,
    pub restates_fact_id: Option<i64>,
}

/// A page of facts with the total under the filters and the classes the other filters would find
/// (`FactPage`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FactPage {
    pub facts: Vec<FactRow>,
    pub total: i64,
    pub classes: Vec<(String, i64)>,
}

/// Fact counts under the filters (`FactStats`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FactStats {
    pub facts: i64,
    pub documents: i64,
    pub by_source: BTreeMap<String, i64>,
    pub by_class: BTreeMap<String, i64>,
    /// Distilled facts backed by these potential facts; how many are backed by more than one, and
    /// how many potential facts those groups hold.
    pub distilled: i64,
    pub clusters: i64,
    pub clustered_facts: i64,
}

impl FactStats {
    /// `FactStats.message`.
    pub fn message(&self) -> String {
        let thousands = crate::service::thousands;
        let mut text = format!("{} facts across {} documents", thousands(self.facts), thousands(self.documents));
        if self.distilled > 0 {
            let _ = write!(text, ", distilled into {}", thousands(self.distilled));
        }
        text
    }
}

/// `_like_pattern`: the query as a substring pattern with LIKE's own characters escaped.
pub fn like_pattern(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_");
    format!("%{escaped}%")
}

type Param = Box<dyn ToSql + Sync + Send>;

/// The WHERE clauses of the filters but `fact_class`, their parameters numbered from 1, and the
/// `fact_class` filter, bound last ([`Filters::filtered`]) so the queries over `base` can take a
/// prefix of the parameters.
struct Filters {
    base: Vec<String>,
    params: Vec<Param>,
    fact_class: Option<String>,
}

impl Filters {
    fn bind(&mut self, value: Param) -> String {
        self.params.push(value);
        format!("${}", self.params.len())
    }

    /// `base` with the `fact_class` clause, binding its parameter after every other.
    fn filtered(&mut self) -> Vec<String> {
        let mut filtered = self.base.clone();
        if let Some(fact_class) = self.fact_class.take() {
            let p = self.bind(Box::new(fact_class));
            filtered.push(format!("f.fact_class = {p}"));
        }
        filtered
    }
}

fn fact_filters(filters: &FactFilters) -> Result<Filters> {
    let mut built = Filters { base: Vec::new(), params: Vec::new(), fact_class: None };
    let query = filters.query.trim();
    if !query.is_empty() {
        let q = built.bind(Box::new(query.to_owned()));
        let like = built.bind(Box::new(like_pattern(query)));
        built.base.push(format!("(f.tsv @@ websearch_to_tsquery('english', {q}) OR f.fact ILIKE {like})"));
    }
    if !filters.source.is_empty() {
        let p = built.bind(Box::new(filters.source.clone()));
        built.base.push(format!(
            "(s.slug = {p} OR EXISTS (SELECT 1 FROM document_sources ds \
             JOIN sources s2 ON s2.id = ds.source_id WHERE ds.document_id = d.id AND s2.slug = {p}))"
        ));
    }
    if !filters.corpus_class.is_empty() {
        if !CORPUS_CLASS_NAMES.contains(&filters.corpus_class.as_str()) {
            return Err(ServiceError::invalid(format!(
                "unknown corpus class {} (expected one of {})",
                garage_mcp::pyrepr::str_repr(&filters.corpus_class),
                CORPUS_CLASS_NAMES.join(", ")
            )));
        }
        let p = built.bind(Box::new(filters.corpus_class.clone()));
        built.base.push(format!("d.corpus_class = CAST(CAST({p} AS text) AS corpus_class)"));
    }
    if let Some(document_id) = filters.document_id.filter(|id| *id != 0) {
        let p = built.bind(Box::new(document_id));
        built.base.push(format!("f.document_id = {p}"));
    }
    if !filters.fact_class.is_empty() {
        built.fact_class = Some(filters.fact_class.clone());
    }
    Ok(built)
}

fn where_clause(clauses: &[String]) -> String {
    if clauses.is_empty() { String::new() } else { format!("WHERE {}", clauses.join(" AND ")) }
}

const FACT_JOINS: &str = "FROM facts f JOIN documents d ON d.id = f.document_id JOIN sources s ON s.id = d.source_id";
const DISTILLED_JOIN: &str = " LEFT JOIN distilled_facts df ON df.id = f.distilled_fact_id";
/// With collapse, a potential fact is listed only when it stands for its distilled fact: it is the
/// representative (or, when that is gone, the lowest id), or it has none yet.
const COLLAPSED: &str = "(f.distilled_fact_id IS NULL OR f.id = COALESCE(df.representative_fact_id,
    (SELECT min(f2.id) FROM facts f2 WHERE f2.distilled_fact_id = f.distilled_fact_id)))";

fn refs(params: &[Param]) -> Vec<&(dyn ToSql + Sync)> {
    params.iter().map(|b| b.as_ref() as &(dyn ToSql + Sync)).collect()
}

/// Facts matching the filters, newest first, or best match first given a query (`list_facts`).
/// `collapse` lists the potential facts behind one distilled fact once, as its representative;
/// `distilled_fact_id` lists one distilled fact's potential facts.
///
/// # Errors
///
/// A corpus class that does not exist, or the database.
pub async fn list_facts(
    client: &Client,
    filters: &FactFilters,
    limit: i64,
    offset: i64,
    collapse: bool,
    distilled_fact_id: Option<i64>,
) -> Result<FactPage> {
    let mut built = fact_filters(filters)?;
    if collapse {
        built.base.push(COLLAPSED.to_owned());
    }
    if let Some(id) = distilled_fact_id.filter(|id| *id != 0) {
        let p = built.bind(Box::new(id));
        built.base.push(format!("f.distilled_fact_id = {p}"));
    }
    let base_params = built.params.len();
    let filtered = built.filtered();
    let filter_params = built.params.len();
    let joins = format!("{FACT_JOINS}{DISTILLED_JOIN}");
    let ctx = built.bind(Box::new(EXCERPT_CONTEXT));
    let order = if filters.query.trim().is_empty() {
        "f.created_at DESC, f.document_id DESC, f.ord ASC".to_owned()
    } else {
        // The query is the first parameter when there is one.
        "ts_rank(f.tsv, websearch_to_tsquery('english', $1)) DESC, f.id DESC".to_owned()
    };
    let limit_p = built.bind(Box::new(limit.max(1)));
    let offset_p = built.bind(Box::new(offset.max(0)));
    let filtered = where_clause(&filtered);
    let sql = format!(
        "SELECT f.id, f.document_id, f.ord, f.fact, f.fact_class, f.attributes,
                f.char_start, f.char_end, f.extractor, f.extractor_model, f.created_at,
                d.title AS document_title, d.uri AS document_uri, s.slug AS source_slug,
                d.corpus_class::text AS corpus_class,
                CASE WHEN f.char_start IS NOT NULL AND f.char_end IS NOT NULL AND d.content IS NOT NULL
                     THEN substr(d.content, GREATEST(f.char_start - {ctx}, 0) + 1,
                                 f.char_end - GREATEST(f.char_start - {ctx}, 0) + {ctx})
                END AS excerpt,
                GREATEST(COALESCE(f.char_start, 0) - {ctx}, 0) AS excerpt_start,
                f.distilled_fact_id,
                CASE WHEN f.distilled_fact_id IS NULL THEN 0 ELSE
                     (SELECT count(*) FROM facts f3 WHERE f3.distilled_fact_id = f.distilled_fact_id)
                END AS distilled_size,
                df.statement AS distilled_statement,
                COALESCE(df.statement_generated, false) AS distilled_generated,
                COALESCE(df.spread, 0) AS distilled_spread,
                f.restates_fact_id
         {joins} {filtered} ORDER BY {order} LIMIT {limit_p} OFFSET {offset_p}"
    );
    let rows = client.query(&sql, &refs(&built.params)).await?;
    let facts = rows
        .iter()
        .map(|row| FactRow {
            id: row.get(0),
            document_id: row.get(1),
            ord: row.get(2),
            fact: row.get(3),
            fact_class: row.get(4),
            attributes: row.get::<_, Option<Value>>(5).unwrap_or(Value::Object(serde_json::Map::new())),
            char_start: row.get(6),
            char_end: row.get(7),
            extractor: row.get::<_, Option<String>>(8).unwrap_or_default(),
            extractor_model: row.get(9),
            created_at: row.get(10),
            document_title: row.get(11),
            document_uri: row.get::<_, Option<String>>(12).unwrap_or_default(),
            source_slug: row.get(13),
            corpus_class: row.get(14),
            excerpt: row.get(15),
            excerpt_start: row.get(16),
            distilled_fact_id: row.get(17),
            distilled_size: row.get(18),
            distilled_statement: row.get(19),
            distilled_generated: row.get(20),
            distilled_spread: f64::from(row.get::<_, f32>(21)),
            restates_fact_id: row.get(22),
        })
        .collect();
    // The counts take the filters' parameters only: a prefix of what the page query bound.
    let total: i64 = client
        .query_one(&format!("SELECT count(*) {joins} {filtered}"), &refs(&built.params[..filter_params]))
        .await?
        .get(0);
    let classes = client
        .query(
            &format!(
                "SELECT f.fact_class, count(*) {joins} {} GROUP BY f.fact_class ORDER BY 2 DESC, 1",
                where_clause(&built.base)
            ),
            &refs(&built.params[..base_params]),
        )
        .await?
        .iter()
        .map(|row| (row.get(0), row.get(1)))
        .collect();
    Ok(FactPage { facts, total, classes })
}

/// How many facts match the filters, over how many documents, per source and per class
/// (`fact_stats`).
///
/// # Errors
///
/// A corpus class that does not exist, or the database.
pub async fn fact_stats(client: &Client, filters: &FactFilters) -> Result<FactStats> {
    let mut built = fact_filters(filters)?;
    let filtered = built.filtered();
    let params = refs(&built.params);
    let scope = format!("{FACT_JOINS} {}", where_clause(&filtered));
    let row = client.query_one(&format!("SELECT count(*), count(DISTINCT f.document_id) {scope}"), &params).await?;
    let mut stats = FactStats { facts: row.get(0), documents: row.get(1), ..FactStats::default() };
    for row in
        client.query(&format!("SELECT s.slug, count(*) {scope} GROUP BY s.slug ORDER BY 2 DESC, 1"), &params).await?
    {
        stats.by_source.insert(row.get(0), row.get(1));
    }
    for row in client
        .query(&format!("SELECT f.fact_class, count(*) {scope} GROUP BY f.fact_class ORDER BY 2 DESC, 1"), &params)
        .await?
    {
        stats.by_class.insert(row.get(0), row.get(1));
    }
    let mut linked = filtered;
    linked.push("f.distilled_fact_id IS NOT NULL".to_owned());
    let row = client
        .query_one(
            &format!(
                "SELECT count(*), count(*) FILTER (WHERE n > 1),
                        CAST(coalesce(sum(n) FILTER (WHERE n > 1), 0) AS bigint)
                 FROM (SELECT f.distilled_fact_id, count(*) AS n {FACT_JOINS} {} GROUP BY f.distilled_fact_id) g",
                where_clause(&linked)
            ),
            &params,
        )
        .await?;
    stats.distilled = row.get(0);
    stats.clusters = row.get(1);
    stats.clustered_facts = row.get(2);
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn like_patterns_escape_the_wildcards() {
        assert_eq!(like_pattern("a_b%c\\d"), "%a\\_b\\%c\\\\d%");
    }

    #[test]
    fn an_unknown_corpus_class_is_refused_before_the_database_sees_it() {
        let Err(error) = fact_filters(&FactFilters { corpus_class: "mail".into(), ..FactFilters::default() }) else {
            panic!("accepted")
        };
        assert_eq!(error.message(), "unknown corpus class 'mail' (expected one of document, code, communication)");
    }

    #[test]
    fn the_stats_message_counts_with_separators() {
        let stats = FactStats { facts: 1234, documents: 5, distilled: 1000, ..FactStats::default() };
        assert_eq!(stats.message(), "1,234 facts across 5 documents, distilled into 1,000");
    }
}
