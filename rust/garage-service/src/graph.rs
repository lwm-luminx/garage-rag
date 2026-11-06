//! The corpus as an Apache AGE graph, projected from the relational tables (`garage_rag.db.graph`).
//!
//! The tables stay the source of truth; the graph `garage` is a projection of them for openCypher
//! queries, rebuilt whole by [`rebuild_graph`] (`garage graph rebuild`, and after every
//! `cluster-facts`). It exists only where the server has AGE; elsewhere [`age_available`] is false
//! and nothing is projected.
//!
//! Vertices carry the relational id and a few display properties: `Document` (`document_id`,
//! `title`, `uri`, `corpus_class`, `trust_tier`), `Chunk` (`chunk_id`, `document_id`, `ord`; content
//! chunks, not facts'), `Author` (`author_id`, `display_name`, `is_self`), `PotentialFact` (`fact_id`,
//! `document_id`, `fact_class`, `prompt_name`, `fact`) and `Fact` (`distilled_fact_id`, `fact_class`,
//! `statement`, `statement_generated`, `nodes`, `spread`, `drift`, `anchor_key`). Edges: `HAS_CHUNK`
//! (Document -> Chunk), `WROTE` and `RECEIVED` (Author -> Document), `STATES` (Document ->
//! PotentialFact), `RESTATES` (PotentialFact -> PotentialFact) and `SUPPORTS` (PotentialFact -> Fact).
//! A prompt's `graph` block ([`GraphSchema`]) adds vertex labels per class and edges from relation
//! classes.
//!
//! The rebuild writes the label tables directly (`INSERT INTO garage."Document"`) rather than through
//! `cypher()`: one statement per label, and no value is ever interpolated into a Cypher body. The
//! reads go over AGE's label tables with bound parameters, never Cypher built from input.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use deadpool_postgres::Transaction;
use regex::Regex;
use serde_json::{Map, Value};
use tokio_postgres::types::ToSql;

use crate::db::Client;
use crate::error::{Result, ServiceError};
use crate::prompts::GraphSchema;

/// The graph's name.
pub const GRAPH: &str = "garage";

type Param = Box<dyn ToSql + Sync + Send>;

fn refs(params: &[Param]) -> Vec<&(dyn ToSql + Sync)> {
    params.iter().map(|b| b.as_ref() as &(dyn ToSql + Sync)).collect()
}

/// A SELECT with numbered parameters, built one binding at a time.
#[derive(Default)]
struct Bound {
    params: Vec<Param>,
}

impl Bound {
    fn bind(&mut self, value: Param) -> String {
        self.params.push(value);
        format!("${}", self.params.len())
    }
}

/// One label's vertices: the id property and a SELECT of (relational id, jsonb properties).
pub struct VertexSet {
    pub label: String,
    pub key: String,
    select: String,
    params: Vec<Param>,
}

/// One label's edges: the end labels and a SELECT of (from id, to id, jsonb properties).
pub struct EdgeSet {
    pub label: String,
    pub source: String,
    pub target: String,
    select: String,
    params: Vec<Param>,
}

/// label -> (id property, SELECT) (`VERTICES`).
const VERTICES: [(&str, &str, &str); 5] = [
    (
        "Document",
        "document_id",
        "SELECT d.id, jsonb_build_object('document_id', d.id, 'title', d.title, 'uri', d.uri,
                                         'corpus_class', d.corpus_class::text, 'trust_tier', d.trust_tier::text)
         FROM documents d",
    ),
    (
        "Chunk",
        "chunk_id",
        "SELECT c.id, jsonb_build_object('chunk_id', c.id, 'document_id', c.document_id, 'ord', c.ord)
         FROM chunks c WHERE c.fact_id IS NULL",
    ),
    (
        "Author",
        "author_id",
        "SELECT a.id, jsonb_build_object('author_id', a.id, 'display_name', a.display_name, 'is_self', a.is_self)
         FROM authors a",
    ),
    (
        "PotentialFact",
        "fact_id",
        "SELECT f.id, jsonb_build_object('fact_id', f.id, 'document_id', f.document_id, 'fact_class', f.fact_class,
                                         'prompt_name', f.prompt_name, 'fact', f.fact)
         FROM facts f",
    ),
    (
        "Fact",
        "distilled_fact_id",
        "SELECT df.id, jsonb_strip_nulls(jsonb_build_object(
                    'distilled_fact_id', df.id, 'fact_class', df.fact_class, 'statement', df.statement,
                    'statement_generated', df.statement_generated, 'nodes', df.nodes, 'spread', df.spread,
                    'drift', df.drift, 'anchor_key', df.anchor_key))
         FROM distilled_facts df",
    ),
];

/// label -> (from label, to label, SELECT) (`EDGES`).
const EDGES: [(&str, &str, &str, &str); 6] = [
    (
        "HAS_CHUNK",
        "Document",
        "Chunk",
        "SELECT c.document_id, c.id, jsonb_build_object('ord', c.ord) FROM chunks c WHERE c.fact_id IS NULL",
    ),
    (
        "WROTE",
        "Author",
        "Document",
        "SELECT da.author_id, da.document_id, jsonb_build_object('role', da.role::text, 'confidence', da.confidence)
         FROM document_authors da WHERE da.role IN ('author', 'committer', 'sender')",
    ),
    (
        "RECEIVED",
        "Author",
        "Document",
        "SELECT da.author_id, da.document_id, jsonb_build_object('role', da.role::text, 'confidence', da.confidence)
         FROM document_authors da WHERE da.role IN ('recipient', 'cc')",
    ),
    (
        "STATES",
        "Document",
        "PotentialFact",
        "SELECT f.document_id, f.id, jsonb_strip_nulls(jsonb_build_object('char_start', f.char_start,
                                                                          'char_end', f.char_end))
         FROM facts f",
    ),
    (
        "RESTATES",
        "PotentialFact",
        "PotentialFact",
        "SELECT f.id, f.restates_fact_id, jsonb_strip_nulls(jsonb_build_object('similarity', f.restates_similarity))
         FROM facts f WHERE f.restates_fact_id IS NOT NULL",
    ),
    (
        "SUPPORTS",
        "PotentialFact",
        "Fact",
        "SELECT f.id, f.distilled_fact_id, jsonb_strip_nulls(jsonb_build_object('similarity', f.distilled_similarity))
         FROM facts f WHERE f.distilled_fact_id IS NOT NULL AND f.restates_fact_id IS NULL",
    ),
];

/// SQL for the distilled fact of a class that a relation fact `r`'s attribute names
/// (`_resolve_end`): resolved in the fact's own document first, then by a distilled fact stating it.
fn resolve_end(attribute: &str, fact_class: &str, title: &str) -> String {
    let name = format!("r.attributes->>CAST({attribute} AS text)");
    format!(
        "coalesce(
            (SELECT m.distilled_fact_id FROM facts m
             WHERE m.document_id = r.document_id AND m.fact_class = {fact_class} AND m.distilled_fact_id IS NOT NULL
               AND (lower(m.fact) = lower({name}) OR lower(m.attributes->>CAST({title} AS text)) = lower({name}))
             ORDER BY m.id LIMIT 1),
            (SELECT d.id FROM distilled_facts d
             WHERE d.fact_class = {fact_class} AND lower(d.statement) = lower({name})
             ORDER BY d.id LIMIT 1))"
    )
}

/// The vertex and edge sets a rebuild writes: the built-in ones, then the configured ones
/// (`projection`).
#[allow(clippy::too_many_lines)]
pub fn projection(schema: &GraphSchema) -> (Vec<VertexSet>, Vec<EdgeSet>) {
    let mapped: Vec<String> = schema.vertices.keys().cloned().collect();
    let mut vertices: Vec<VertexSet> = VERTICES
        .iter()
        .map(|(label, key, select)| VertexSet {
            label: (*label).to_owned(),
            key: (*key).to_owned(),
            select: (*select).to_owned(),
            params: Vec::new(),
        })
        .collect();
    let mut edges: Vec<EdgeSet> = EDGES
        .iter()
        .map(|(label, source, target, select)| EdgeSet {
            label: (*label).to_owned(),
            source: (*source).to_owned(),
            target: (*target).to_owned(),
            select: (*select).to_owned(),
            params: Vec::new(),
        })
        .collect();
    if !mapped.is_empty() {
        // A configured class's distilled facts are vertices of its label, not Fact.
        let not_mapped = |id: &str| {
            format!("JOIN distilled_facts dm ON dm.id = {id} WHERE NOT (dm.fact_class = ANY(CAST($1 AS text[])))")
        };
        for vertex in &mut vertices {
            if vertex.label == "Fact" {
                vertex.select = format!("SELECT x.* FROM ({}) x(rid, p) {}", vertex.select, not_mapped("x.rid"));
                vertex.params = vec![Box::new(mapped.clone())];
            }
        }
        for edge in &mut edges {
            if edge.label == "SUPPORTS" {
                edge.select = format!("SELECT x.* FROM ({}) x(src, dst, p) {}", edge.select, not_mapped("x.dst"));
                edge.params = vec![Box::new(mapped.clone())];
            }
        }
    }
    for (fact_class, vertex) in &schema.vertices {
        let mut bound = Bound::default();
        let cls = bound.bind(Box::new(fact_class.clone()));
        let title = bound.bind(Box::new(vertex.title.clone()));
        vertices.push(VertexSet {
            label: vertex.label.clone(),
            key: "distilled_fact_id".to_owned(),
            select: format!(
                "SELECT df.id, jsonb_strip_nulls(jsonb_build_object(
                            'distilled_fact_id', df.id, 'fact_class', df.fact_class,
                            'title', coalesce(nullif(rep.attributes->>CAST({title} AS text), ''), df.statement),
                            'statement', df.statement, 'nodes', df.nodes, 'anchor_key', df.anchor_key))
                 FROM distilled_facts df LEFT JOIN facts rep ON rep.id = df.representative_fact_id
                 WHERE df.fact_class = {cls}"
            ),
            params: bound.params,
        });
        edges.push(EdgeSet {
            label: "SUPPORTS".to_owned(),
            source: "PotentialFact".to_owned(),
            target: vertex.label.clone(),
            select: "SELECT f.id, f.distilled_fact_id,
                            jsonb_strip_nulls(jsonb_build_object('similarity', f.distilled_similarity))
                     FROM facts f JOIN distilled_facts df ON df.id = f.distilled_fact_id
                     WHERE f.restates_fact_id IS NULL AND df.fact_class = $1"
                .to_owned(),
            params: vec![Box::new(fact_class.clone())],
        });
    }
    for edge in &schema.edges {
        let source_title = schema.vertices.get(&edge.source_class).and_then(|v| v.title.clone());
        let target_title = schema.vertices.get(&edge.target_class).and_then(|v| v.title.clone());
        let mut labels: Vec<&String> = Vec::new();
        for label in edge.labels.iter().chain(std::iter::once(&edge.label)) {
            if !labels.contains(&label) {
                labels.push(label);
            }
        }
        for label in labels {
            let mut bound = Bound::default();
            let cls = bound.bind(Box::new(edge.class.clone()));
            let source = bound.bind(Box::new(edge.source.clone()));
            let source_class = bound.bind(Box::new(edge.source_class.clone()));
            let source_title = bound.bind(Box::new(source_title.clone()));
            let target = bound.bind(Box::new(edge.target.clone()));
            let target_class = bound.bind(Box::new(edge.target_class.clone()));
            let target_title = bound.bind(Box::new(target_title.clone()));
            let label_attribute = bound.bind(Box::new(edge.label_attribute.clone()));
            let labels_p = bound.bind(Box::new(edge.labels.clone()));
            let fallback = bound.bind(Box::new(edge.label.clone()));
            let this_label = bound.bind(Box::new(label.clone()));
            let picked = if edge.label_attribute.is_some() {
                format!(
                    "upper(regexp_replace(trim(r.attributes->>CAST({label_attribute} AS text)), '[^A-Za-z0-9]+', '_', 'g'))"
                )
            } else {
                "NULL".to_owned()
            };
            edges.push(EdgeSet {
                label: label.clone(),
                source: schema.label_for(&edge.source_class),
                target: schema.label_for(&edge.target_class),
                select: format!(
                    "SELECT {},
                            {},
                            jsonb_strip_nulls(jsonb_build_object(
                                'fact_id', r.id, 'document_id', r.document_id, 'fact', r.fact,
                                'predicate', r.attributes->>CAST({label_attribute} AS text)))
                     FROM facts r
                     WHERE r.fact_class = {cls} AND r.restates_fact_id IS NULL
                       AND (CASE WHEN {picked} = ANY(CAST({labels_p} AS text[])) THEN {picked} ELSE {fallback} END)
                           = {this_label}",
                    resolve_end(&source, &source_class, &source_title),
                    resolve_end(&target, &target_class, &target_title),
                ),
                params: bound.params,
            });
        }
    }
    (vertices, edges)
}

/// What a rebuild projected; `available` is false where the server has no AGE (`GraphSummary`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GraphSummary {
    pub available: bool,
    pub vertices: Vec<(String, i64)>,
    pub edges: Vec<(String, i64)>,
}

impl GraphSummary {
    /// `GraphSummary.message`.
    pub fn message(&self) -> String {
        if !self.available {
            return "no graph: this server has no Apache AGE".to_owned();
        }
        let counts: Vec<String> = self
            .vertices
            .iter()
            .chain(self.edges.iter())
            .map(|(label, n)| format!("{} {label}", crate::service::thousands(*n)))
            .collect();
        format!("graph '{GRAPH}': {}", counts.join(", "))
    }
}

/// Whether the database has the AGE extension (`age_available`).
///
/// # Errors
///
/// The database.
pub async fn age_available(client: &Client) -> Result<bool> {
    Ok(client
        .query_one("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age')", &[])
        .await?
        .get::<_, bool>(0))
}

/// Load AGE into this connection and put `ag_catalog` on the transaction's search path (`use_age`).
///
/// # Errors
///
/// The database.
pub async fn use_age(tx: &Transaction<'_>) -> Result<()> {
    tx.batch_execute("LOAD 'age'; SET LOCAL search_path = \"$user\", public, ag_catalog").await?;
    Ok(())
}

/// Drop and re-project the `garage` graph from the tables; a no-op returning `available=false` when
/// the server has no AGE (`rebuild_graph`). Commits.
///
/// # Errors
///
/// The database.
pub async fn rebuild_graph(client: &mut Client, schema: &GraphSchema) -> Result<GraphSummary> {
    if !age_available(client).await? {
        return Ok(GraphSummary::default());
    }
    let (vertex_sets, edge_sets) = projection(schema);
    let tx = client.transaction().await?;
    use_age(&tx).await?;
    let exists: bool =
        tx.query_one("SELECT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1)", &[&GRAPH]).await?.get(0);
    if exists {
        tx.execute("SELECT ag_catalog.drop_graph($1, true)", &[&GRAPH]).await?;
    }
    tx.execute("SELECT ag_catalog.create_graph($1)", &[&GRAPH]).await?;

    let mut summary = GraphSummary { available: true, ..GraphSummary::default() };
    for set in &vertex_sets {
        tx.execute("SELECT ag_catalog.create_vlabel($1, $2)", &[&GRAPH, &set.label]).await?;
        let inserted = tx
            .execute(
                &format!(
                    "INSERT INTO {GRAPH}.\"{}\" (properties) SELECT CAST(p::text AS ag_catalog.agtype) \
                     FROM ({}) AS v(rid, p)",
                    set.label, set.select
                ),
                &refs(&set.params),
            )
            .await
            .map_err(|e| ServiceError::failed(format!("projecting {} vertices: {e}", set.label)))?;
        summary.vertices.push((set.label.clone(), i64::try_from(inserted).unwrap_or(i64::MAX)));
        // The relational id -> vertex id map the edges join through, and an index so a Cypher
        // MATCH on the id property is not a scan.
        let key = format!("ag_catalog.agtype_access_operator(properties, '\"{}\"'::ag_catalog.agtype)", set.key);
        tx.batch_execute(&format!(
            "CREATE INDEX ON {GRAPH}.\"{label}\" ({key});
             CREATE TEMP TABLE graph_ids_{lower} ON COMMIT DROP AS
                 SELECT CAST(CAST({key} AS text) AS bigint) AS rid, id AS gid FROM {GRAPH}.\"{label}\";
             CREATE UNIQUE INDEX ON graph_ids_{lower} (rid)",
            label = set.label,
            lower = set.label.to_lowercase(),
        ))
        .await?;
    }
    for set in &edge_sets {
        if !summary.edges.iter().any(|(label, _)| label == &set.label) {
            tx.execute("SELECT ag_catalog.create_elabel($1, $2)", &[&GRAPH, &set.label]).await?;
            summary.edges.push((set.label.clone(), 0));
        }
        let inserted = tx
            .execute(
                &format!(
                    "INSERT INTO {GRAPH}.\"{}\" (start_id, end_id, properties) \
                     SELECT s.gid, t.gid, CAST(e.p::text AS ag_catalog.agtype) FROM ({}) AS e(src, dst, p) \
                     JOIN graph_ids_{} s ON s.rid = e.src JOIN graph_ids_{} t ON t.rid = e.dst",
                    set.label,
                    set.select,
                    set.source.to_lowercase(),
                    set.target.to_lowercase()
                ),
                &refs(&set.params),
            )
            .await
            .map_err(|e| ServiceError::failed(format!("projecting {} edges: {e}", set.label)))?;
        if let Some(entry) = summary.edges.iter_mut().find(|(label, _)| label == &set.label) {
            entry.1 += i64::try_from(inserted).unwrap_or(i64::MAX);
        }
    }
    tx.commit().await?;
    Ok(summary)
}

// ---------------------------------------------------------------------------------------------
// Reading the graph: what the app's Graph page shows

/// The property a vertex is titled by, where one property reads as its name (`title_property`): a
/// built-in's, else a configured label's `title`. `Chunk` has none.
pub fn title_property(label: &str) -> Option<&'static str> {
    match label {
        "Author" => Some("display_name"),
        "PotentialFact" => Some("fact"),
        "Fact" => Some("statement"),
        "Chunk" => None,
        _ => Some("title"),
    }
}

/// The property holding `label`'s relational id (`key_property`); a configured label's is its
/// distilled fact's.
pub fn key_property(label: &str) -> Option<&'static str> {
    VERTICES.iter().find(|(l, _, _)| *l == label).map_or(Some("distilled_fact_id"), |(_, key, _)| Some(key))
}

static LABEL_NAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z_][A-Za-z0-9_]*$").unwrap());
static AGTYPE_SUFFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"::(numeric|vertex|edge|path)\b").unwrap());

/// One vertex: its graph id, label, relational id (`key`; 0 for a label without one) and
/// properties (`GraphVertex`).
#[derive(Clone, Debug, PartialEq)]
pub struct GraphVertex {
    pub id: i64,
    pub label: String,
    pub key: i64,
    pub title: String,
    pub properties: Map<String, Value>,
}

/// One edge between two graph ids (`GraphEdge`).
#[derive(Clone, Debug, PartialEq)]
pub struct GraphEdge {
    pub id: i64,
    pub label: String,
    pub source_id: i64,
    pub target_id: i64,
    pub properties: Map<String, Value>,
}

/// The labels the graph has, with a count of each; `available` is false without AGE or a graph
/// (`GraphLabels`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GraphLabels {
    pub available: bool,
    pub vertices: Vec<(String, i64)>,
    pub edges: Vec<(String, i64)>,
}

/// A vertex and everything within `depth` hops of it, under the label filters (`Neighborhood`).
/// `truncated` says the vertex limit cut the walk short; `vertices` includes the center.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Neighborhood {
    pub available: bool,
    pub center: Option<GraphVertex>,
    pub vertices: Vec<GraphVertex>,
    pub edges: Vec<GraphEdge>,
    pub truncated: bool,
}

/// The label of a label table from its `regclass` text (`label_from_relation`):
/// `garage."Document"` -> `Document`.
pub fn label_from_relation(relation: &str) -> String {
    let name = relation.rsplit_once('.').map_or(relation, |(_, name)| name);
    name.trim_matches('"').replace("\"\"", "\"")
}

/// An agtype map's text as a map (`parse_properties`); agtype prints maps as JSON, bar the odd
/// `::numeric` suffix.
pub fn parse_properties(raw: Option<&str>) -> Map<String, Value> {
    let Some(raw) = raw.filter(|r| !r.is_empty()) else { return Map::new() };
    let parsed = serde_json::from_str::<Value>(raw)
        .or_else(|_| serde_json::from_str::<Value>(&AGTYPE_SUFFIX.replace_all(raw, "")));
    let Ok(value) = parsed else {
        let mut map = Map::new();
        map.insert("raw".to_owned(), Value::String(raw.to_owned()));
        return map;
    };
    match value {
        Value::Object(map) => map,
        other => {
            let mut map = Map::new();
            map.insert("value".to_owned(), other);
            map
        }
    }
}

fn non_blank(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

/// What a vertex is called on screen: its title property, else something from the rest
/// (`vertex_title`).
pub fn vertex_title(label: &str, properties: &Map<String, Value>) -> String {
    if let Some(prop) = title_property(label)
        && let Some(title) = non_blank(properties.get(prop))
    {
        return title;
    }
    if label == "Document"
        && let Some(uri) = properties.get("uri").and_then(Value::as_str).filter(|u| !u.is_empty())
    {
        let trimmed = uri.trim_end_matches('/');
        let last = trimmed.rsplit('/').next().unwrap_or_default();
        return if last.is_empty() { uri.to_owned() } else { last.to_owned() };
    }
    if label == "Chunk"
        && let Some(ord) = properties.get("ord")
    {
        return format!("Chunk {}", garage_mcp::pyjson::dumps(ord, garage_mcp::pyjson::DEFAULT));
    }
    for value in properties.values() {
        if let Some(text) = non_blank(Some(value)) {
            return text;
        }
    }
    if let Some(key) = key_property(label)
        && let Some(value) = properties.get(key)
    {
        return format!("{label} {}", garage_mcp::pyjson::dumps(value, garage_mcp::pyjson::DEFAULT));
    }
    label.to_owned()
}

fn vertex(gid: &str, relation: &str, raw: Option<&str>) -> GraphVertex {
    let label = label_from_relation(relation);
    let properties = parse_properties(raw);
    let key = key_property(&label).and_then(|k| properties.get(k)).and_then(Value::as_i64).unwrap_or(0);
    GraphVertex {
        id: gid.parse().unwrap_or(0),
        label: label.clone(),
        key,
        title: vertex_title(&label, &properties),
        properties,
    }
}

const VERTEX_COLUMNS: &str =
    "CAST(v.id AS text), CAST(v.tableoid::regclass AS text), ag_catalog.agtype_out(v.properties)::text";
const EDGE_COLUMNS: &str = "CAST(e.id AS text), CAST(e.tableoid::regclass AS text), CAST(e.start_id AS text), \
                            CAST(e.end_id AS text), ag_catalog.agtype_out(e.properties)::text";

fn vertex_of(row: &tokio_postgres::Row) -> GraphVertex {
    vertex(row.get(0), row.get(1), row.get::<_, Option<String>>(2).as_deref())
}

/// Whether the server has AGE and the `garage` graph has been projected (`graph_exists`).
async fn graph_exists(tx: &Transaction<'_>) -> Result<bool> {
    Ok(tx
        .query_one("SELECT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1)", &[&GRAPH])
        .await?
        .get::<_, bool>(0))
}

/// The graph's labels of one kind (`v` or `e`), without AGE's own `_ag_label_*` parents.
async fn label_names(tx: &Transaction<'_>, kind: &str) -> Result<Vec<String>> {
    let rows = tx
        .query(
            "SELECT l.name::text FROM ag_catalog.ag_label l JOIN ag_catalog.ag_graph g ON g.graphid = l.graph \
             WHERE g.name = $1 AND l.kind = CAST(CAST($2 AS text) AS \"char\") AND l.name NOT LIKE '\\_ag\\_%' \
             ORDER BY l.name",
            &[&GRAPH, &kind],
        )
        .await?;
    Ok(rows.iter().map(|r| r.get::<_, String>(0)).filter(|name| LABEL_NAME.is_match(name)).collect())
}

/// Begins a transaction with AGE loaded, or none when the graph is not there.
async fn open_graph(client: &mut Client) -> Result<Option<Transaction<'_>>> {
    if !age_available(client).await? {
        return Ok(None);
    }
    let tx = client.transaction().await?;
    use_age(&tx).await?;
    if !graph_exists(&tx).await? {
        return Ok(None);
    }
    Ok(Some(tx))
}

/// Every label the projected graph has, with how many vertices or edges carry it (`graph_labels`).
///
/// # Errors
///
/// The database.
pub async fn graph_labels(client: &mut Client) -> Result<GraphLabels> {
    let Some(tx) = open_graph(client).await? else { return Ok(GraphLabels::default()) };
    let mut labels = GraphLabels { available: true, ..GraphLabels::default() };
    for name in label_names(&tx, "v").await? {
        let n: i64 = tx.query_one(&format!("SELECT count(*) FROM {GRAPH}.\"{name}\""), &[]).await?.get(0);
        labels.vertices.push((name, n));
    }
    for name in label_names(&tx, "e").await? {
        let n: i64 = tx.query_one(&format!("SELECT count(*) FROM {GRAPH}.\"{name}\""), &[]).await?.get(0);
        labels.edges.push((name, n));
    }
    Ok(labels)
}

/// A clause keeping the rows of the given label tables, on a query of their inherited parent
/// table (`_label_oids`); empty, binding nothing, when every label is kept.
fn label_oids(alias: &str, labels: Option<&[String]>, bound: &mut Bound) -> String {
    let Some(labels) = labels else { return String::new() };
    let graph_p = bound.bind(Box::new(GRAPH.to_owned()));
    let labels_p = bound.bind(Box::new(labels.to_vec()));
    format!(
        " AND {alias}.tableoid IN (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
         WHERE n.nspname = {graph_p} AND c.relname = ANY(CAST({labels_p} AS text[])))"
    )
}

async fn vertices_by_id(tx: &Transaction<'_>, ids: &[i64], labels: Option<&[String]>) -> Result<Vec<GraphVertex>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let mut bound = Bound::default();
    let ids_p = bound.bind(Box::new(ids.iter().map(i64::to_string).collect::<Vec<_>>()));
    let by_label = label_oids("v", labels, &mut bound);
    let sql = format!(
        "SELECT {VERTEX_COLUMNS} FROM {GRAPH}.\"_ag_label_vertex\" v \
         WHERE v.id = ANY(CAST(CAST({ids_p} AS text[]) AS ag_catalog.graphid[])){by_label} ORDER BY v.id"
    );
    Ok(tx.query(&sql, &refs(&bound.params)).await?.iter().map(vertex_of).collect())
}

/// The vertex of `label` whose relational id is `key` (`find_vertex`).
async fn find_vertex(tx: &Transaction<'_>, label: &str, key: i64) -> Result<Option<GraphVertex>> {
    if !label_names(tx, "v").await?.iter().any(|l| l == label) {
        return Err(ServiceError::not_found(format!(
            "the graph has no {} vertices",
            garage_mcp::pyrepr::str_repr(label)
        )));
    }
    let Some(prop) = key_property(label) else {
        return Err(ServiceError::invalid(format!(
            "{} vertices have no relational id; look one up by graph id",
            garage_mcp::pyrepr::str_repr(label)
        )));
    };
    let sql = format!(
        "SELECT {VERTEX_COLUMNS} FROM {GRAPH}.\"{label}\" v \
         WHERE ag_catalog.agtype_access_operator(v.properties, '\"{prop}\"'::ag_catalog.agtype) \
         = CAST(CAST($1 AS text) AS ag_catalog.agtype) LIMIT 1"
    );
    Ok(tx.query_opt(&sql, &[&key.to_string()]).await?.as_ref().map(vertex_of))
}

fn like_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

/// Vertices whose title contains `query` (case-insensitively), or whose relational id is it
/// (`find_vertices`). `label` narrows to one label; an empty `query` lists the first vertices of
/// each searchable label. Chunks have no title and are found through their documents. Empty when
/// there is no graph.
///
/// # Errors
///
/// A label the graph does not have (`NOT_FOUND`), or the database.
pub async fn find_vertices(client: &mut Client, query: &str, label: &str, limit: i64) -> Result<Vec<GraphVertex>> {
    let Some(tx) = open_graph(client).await? else { return Ok(Vec::new()) };
    let mut labels = label_names(&tx, "v").await?;
    if !label.is_empty() {
        if !labels.iter().any(|l| l == label) {
            return Err(ServiceError::not_found(format!(
                "the graph has no {} vertices",
                garage_mcp::pyrepr::str_repr(label)
            )));
        }
        labels = vec![label.to_owned()];
    }
    let query = query.trim();
    let key: Option<i64> =
        if !query.is_empty() && query.chars().all(|c| c.is_ascii_digit()) { query.parse().ok() } else { None };
    let limit = limit.max(1);
    let mut found: Vec<GraphVertex> = Vec::new();
    for name in labels {
        let mut bound = Bound::default();
        let mut clauses = Vec::new();
        if let Some(prop) = title_property(&name)
            && !query.is_empty()
        {
            let pattern = bound.bind(Box::new(format!("%{}%", like_escape(query))));
            clauses.push(format!(
                "CAST(ag_catalog.agtype_access_operator(v.properties, '\"{prop}\"'::ag_catalog.agtype) AS text) \
                 ILIKE {pattern}"
            ));
        }
        if let Some(key) = key
            && let Some(key_prop) = key_property(&name)
        {
            let key_p = bound.bind(Box::new(key.to_string()));
            clauses.push(format!(
                "ag_catalog.agtype_access_operator(v.properties, '\"{key_prop}\"'::ag_catalog.agtype) \
                 = CAST(CAST({key_p} AS text) AS ag_catalog.agtype)"
            ));
        }
        if !query.is_empty() && clauses.is_empty() {
            continue;
        }
        let where_clause = if clauses.is_empty() { String::new() } else { format!("WHERE {}", clauses.join(" OR ")) };
        let room = bound.bind(Box::new((limit - i64::try_from(found.len()).unwrap_or(i64::MAX)).max(1)));
        let sql =
            format!("SELECT {VERTEX_COLUMNS} FROM {GRAPH}.\"{name}\" v {where_clause} ORDER BY v.id LIMIT {room}");
        found.extend(tx.query(&sql, &refs(&bound.params)).await?.iter().map(vertex_of));
        if i64::try_from(found.len()).unwrap_or(i64::MAX) >= limit {
            break;
        }
    }
    found.truncate(usize::try_from(limit).unwrap_or(usize::MAX));
    Ok(found)
}

/// How a neighbourhood's center is named: by graph id, or by label and relational id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Center {
    Id(i64),
    Key { label: String, key: i64 },
}

/// Walk `depth` hops out from a vertex (`neighborhood`). `vertex_labels` and `edge_labels` keep
/// only those labels (`None` keeps all); an excluded vertex is neither shown nor walked through.
/// The walk stops at `limit` vertices, breadth first, and says so with `truncated`.
///
/// # Errors
///
/// A vertex not in the graph (`NOT_FOUND`), a center named neither way (`INVALID_ARGUMENT`), or
/// the database.
pub async fn neighborhood(
    client: &mut Client,
    center: &Center,
    depth: i64,
    vertex_labels: Option<&[String]>,
    edge_labels: Option<&[String]>,
    limit: i64,
) -> Result<Neighborhood> {
    let Some(tx) = open_graph(client).await? else { return Ok(Neighborhood::default()) };
    let center = match center {
        Center::Id(id) if *id != 0 => vertices_by_id(&tx, &[*id], None).await?.into_iter().next(),
        Center::Key { label, key } if !label.is_empty() => find_vertex(&tx, label, *key).await?,
        _ => return Err(ServiceError::invalid("name the vertex by graph id, or by label and relational id")),
    };
    let Some(center) = center else {
        return Err(ServiceError::not_found("that vertex is not in the graph; rebuild it with `garage graph rebuild`"));
    };
    let depth = depth.clamp(0, 6);
    let limit = usize::try_from(limit.max(1)).unwrap_or(usize::MAX);
    let mut vertices: Vec<GraphVertex> = vec![center.clone()];
    let mut edges: Vec<GraphEdge> = Vec::new();
    let mut frontier = vec![center.id];
    let mut truncated = false;
    for _ in 0..depth {
        if frontier.is_empty() || vertices.len() >= limit {
            break;
        }
        let mut bound = Bound::default();
        let ids_p = bound.bind(Box::new(frontier.iter().map(i64::to_string).collect::<Vec<_>>()));
        let by_label = label_oids("e", edge_labels, &mut bound);
        let sql = format!(
            "SELECT {EDGE_COLUMNS} FROM {GRAPH}.\"_ag_label_edge\" e \
             WHERE (e.start_id = ANY(CAST(CAST({ids_p} AS text[]) AS ag_catalog.graphid[])) \
             OR e.end_id = ANY(CAST(CAST({ids_p} AS text[]) AS ag_catalog.graphid[]))){by_label} ORDER BY e.id"
        );
        let hop_edges: Vec<GraphEdge> = tx
            .query(&sql, &refs(&bound.params))
            .await?
            .iter()
            .map(|row| GraphEdge {
                id: row.get::<_, String>(0).parse().unwrap_or(0),
                label: label_from_relation(row.get(1)),
                source_id: row.get::<_, String>(2).parse().unwrap_or(0),
                target_id: row.get::<_, String>(3).parse().unwrap_or(0),
                properties: parse_properties(row.get::<_, Option<String>>(4).as_deref()),
            })
            .collect();
        let known: std::collections::BTreeSet<i64> = vertices.iter().map(|v| v.id).collect();
        let new_ids: Vec<i64> = hop_edges
            .iter()
            .flat_map(|e| [e.source_id, e.target_id])
            .filter(|id| !known.contains(id))
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        let room = limit - vertices.len();
        if new_ids.len() > room {
            truncated = true;
        }
        let mut new_vertices = vertices_by_id(&tx, &new_ids, vertex_labels).await?;
        if let Some(allowed) = vertex_labels {
            new_vertices.retain(|v| allowed.contains(&v.label));
        }
        new_vertices.truncate(room);
        frontier = new_vertices.iter().map(|v| v.id).collect();
        vertices.extend(new_vertices);
        let present: std::collections::BTreeSet<i64> = vertices.iter().map(|v| v.id).collect();
        for edge in hop_edges {
            if present.contains(&edge.source_id)
                && present.contains(&edge.target_id)
                && !edges.iter().any(|e| e.id == edge.id)
            {
                edges.push(edge);
            }
        }
    }
    Ok(Neighborhood { available: true, center: Some(center), vertices, edges, truncated })
}

/// `properties` as `json.dumps(..., sort_keys=True)` writes them, for the proto.
pub fn properties_json(properties: &Map<String, Value>) -> String {
    let sorted: BTreeMap<&String, &Value> = properties.iter().collect();
    let value = Value::Object(sorted.into_iter().map(|(k, v)| (k.clone(), crate::prompts::sorted_keys(v))).collect());
    garage_mcp::pyjson::dumps(&value, garage_mcp::pyjson::DEFAULT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn props(value: &Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    #[test]
    fn labels_come_off_their_relation_names() {
        assert_eq!(label_from_relation("garage.\"Document\""), "Document");
        assert_eq!(label_from_relation("garage.\"Odd\"\"Name\""), "Odd\"Name");
        assert_eq!(label_from_relation("\"HAS_CHUNK\""), "HAS_CHUNK");
    }

    #[test]
    fn agtype_text_parses_with_and_without_its_suffixes() {
        assert_eq!(parse_properties(Some(r#"{"a": 1, "b": "x"}"#)), props(&json!({"a": 1, "b": "x"})));
        assert_eq!(parse_properties(Some(r#"{"spread": 0.5::numeric}"#)), props(&json!({"spread": 0.5})));
        assert_eq!(parse_properties(Some("[1, 2]")), props(&json!({"value": [1, 2]})));
        assert_eq!(parse_properties(Some("nonsense")), props(&json!({"raw": "nonsense"})));
        assert!(parse_properties(None).is_empty());
    }

    #[test]
    fn vertices_are_titled_by_their_title_property_or_something_readable() {
        assert_eq!(vertex_title("Document", &props(&json!({"title": " Notes ", "uri": "/a/b.md"}))), "Notes");
        assert_eq!(vertex_title("Document", &props(&json!({"title": "", "uri": "/a/b.md"}))), "b.md");
        assert_eq!(vertex_title("Document", &props(&json!({"uri": "/"}))), "/");
        assert_eq!(vertex_title("Chunk", &props(&json!({"chunk_id": 7, "ord": 3}))), "Chunk 3");
        assert_eq!(vertex_title("Author", &props(&json!({"display_name": "Ann"}))), "Ann");
        assert_eq!(vertex_title("Person", &props(&json!({"title": "Bob"}))), "Bob");
        assert_eq!(vertex_title("Fact", &props(&json!({"distilled_fact_id": 9}))), "Fact 9");
        assert_eq!(vertex_title("Fact", &props(&json!({}))), "Fact");
    }

    #[test]
    fn a_vertex_reads_its_key_from_the_label_property() {
        let v = vertex("844424930131969", "garage.\"PotentialFact\"", Some(r#"{"fact_id": 12, "fact": "x"}"#));
        assert_eq!((v.id, v.key, v.title.as_str()), (844_424_930_131_969, 12, "x"));
        assert_eq!(properties_json(&v.properties), r#"{"fact": "x", "fact_id": 12}"#);
    }

    #[test]
    fn the_projection_adds_configured_labels_after_the_builtins() {
        let (vertices, edges) = projection(&GraphSchema::default());
        assert_eq!(vertices.iter().map(|v| v.label.as_str()).collect::<Vec<_>>(), BUILTIN_V);
        assert_eq!(edges.len(), 6);
        let configured = crate::prompts::parse_prompts(&json!([{
            "name": "p", "description": "d", "examples": [{"text": "t"}],
            "graph": {
                "vertices": [{"class": "person", "label": "Person", "title": "name"}],
                "edges": [{"class": "rel", "source": "a", "source_class": "person", "target": "b",
                           "target_class": "person", "label_attribute": "predicate", "labels": ["KNOWS"]}],
            },
        }]))
        .unwrap();
        let schema = crate::prompts::graph_schema(&crate::prompts::effective_prompts(&configured).unwrap()).unwrap();
        let (vertices, edges) = projection(&schema);
        assert_eq!(vertices.last().map(|v| v.label.as_str()), Some("Person"));
        assert!(vertices.iter().find(|v| v.label == "Fact").unwrap().select.contains("NOT (dm.fact_class"));
        let labels: Vec<&str> = edges.iter().map(|e| e.label.as_str()).collect();
        assert_eq!(&labels[6..], ["SUPPORTS", "KNOWS", "RELATED_TO"]);
        assert_eq!(edges[7].source, "Person");
        assert_eq!(edges[7].params.len(), 11);
        assert_eq!(GraphSummary::default().message(), "no graph: this server has no Apache AGE");
    }

    const BUILTIN_V: [&str; 5] = ["Document", "Chunk", "Author", "PotentialFact", "Fact"];
}
