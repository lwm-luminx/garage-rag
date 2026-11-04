//! Distilling potential facts into distinct claims (`enrich/clusters.py`, `garage cluster-facts`,
//! the `ClusterFacts` RPC).
//!
//! The rows of `facts` are *potential* facts: what one prompt extracted from one document, each a
//! verbatim, grounded quote, with a vector under every registered model in the model's
//! `potential_fact_emb_` table. This pass reads those vectors under one model and dedups in two
//! levels, as the Python module did, step for step:
//!
//! * **Level 1, per document.** A document's facts of one class are compared pair by pair; facts
//!   with the same normalized text, or whose cosine similarity clears `restate_threshold`, are
//!   grouped by average linkage behind the guard, and every member but the representative points at
//!   it (`facts.restates_fact_id`).
//! * **Level 2, per corpus.** The representatives (the *nodes*) are grouped into distilled facts: a
//!   full run grows groups from the densest seeds ([`grow_group`]); an incremental run refreshes the
//!   groups that lost nodes and attaches each new node to the nearest distilled fact that takes it
//!   ([`attach_ok`]), or makes it one of its own.
//!
//! The guard ([`claim_signature`]) keeps facts that differ in numbers, dates or negation apart; a
//! loose group is confirmed by the local chat model ([`Distill`]), and a group with a communication
//! among its members goes only to a loopback model. Metadata facts are anchors: each distinct value
//! is an anchored distilled fact with a fixed centroid, joined by key.
//!
//! Potential facts are never changed, only linked. The run is one transaction, committed at the end.

// The `real` columns take `f32`; the counts a mean divides by are small.
#![allow(clippy::cast_possible_truncation, clippy::cast_precision_loss, clippy::implicit_hasher)]

use std::cmp::Reverse;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt::Write as _;
use std::sync::{Arc, LazyLock};

use deadpool_postgres::Transaction;
use garage_ingest::sha256;
use garage_mcp::chat::{Chat, check_content};
use regex::Regex;
use serde_json::json;

use crate::config::Config;
use crate::db::{Client, assert_safe_table};
use crate::error::{Result, ServiceError};
use crate::models::{EmbeddingModel, ensure_fact_table};
use crate::registry::{distance_operator, fact_table_name, potential_fact_table_name};

/// Nodes per neighbour query.
const NEIGHBOR_BATCH: usize = 256;
/// Documents per level-1 query.
const DOCUMENT_BATCH: usize = 200;
/// `facts.extractor` of a metadata fact (`enrich/metadata.py`'s `EXTRACTOR`).
pub const METADATA_EXTRACTOR: &str = "metadata";

// ---------------------------------------------------------------------------
// The guard: what an embedding cannot tell apart

static NUMBER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\d+(?:[.,:/-]\d+)*").unwrap());
static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[a-z]+(?:'[a-z]+)?").unwrap());
static SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());

const TEMPORAL: [&str; 50] = [
    "january",
    "february",
    "march",
    "april",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
    "jan",
    "feb",
    "mar",
    "apr",
    "jun",
    "jul",
    "aug",
    "sep",
    "sept",
    "oct",
    "nov",
    "dec",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "mon",
    "tue",
    "tues",
    "wed",
    "thu",
    "thur",
    "thurs",
    "fri",
    "yesterday",
    "today",
    "tomorrow",
    "tonight",
    "morning",
    "afternoon",
    "evening",
    "night",
    "before",
    "after",
    "earlier",
    "later",
];
const NEGATION: [&str; 10] = ["not", "no", "never", "none", "neither", "nor", "without", "cannot", "nobody", "nothing"];

/// What a fact says about quantities, time and negation (`ClaimSignature`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct ClaimSignature {
    pub numbers: BTreeSet<String>,
    pub temporal: BTreeSet<String>,
    pub negated: bool,
}

/// The parts of `fact` that must agree before it can be grouped with another.
///
/// Numbers are compared as written, minus thousands separators ("1,000" and "1000" agree); month,
/// weekday and relative-time words must be the same set; and either both facts are negated or
/// neither is.
pub fn claim_signature(fact: &str) -> ClaimSignature {
    let lowered = fact.to_lowercase();
    let numbers = NUMBER.find_iter(&lowered).map(|m| m.as_str().replace(',', "")).collect();
    let words: Vec<&str> = WORD.find_iter(&lowered).map(|m| m.as_str()).collect();
    let temporal = words.iter().filter(|w| is_temporal(w)).map(|w| (*w).to_owned()).collect();
    let negated = words.iter().any(|w| NEGATION.contains(w) || w.ends_with("n't"));
    ClaimSignature { numbers, temporal, negated }
}

fn is_temporal(word: &str) -> bool {
    TEMPORAL.contains(&word)
}

// ---------------------------------------------------------------------------
// Grouping

type Pair = (i64, i64);
type Similarity = HashMap<Pair, f64>;

/// The pair's key: the lower id first.
pub fn pair(a: i64, b: i64) -> Pair {
    if a < b { (a, b) } else { (b, a) }
}

fn find(parent: &mut HashMap<i64, i64>, mut i: i64) -> i64 {
    while parent[&i] != i {
        let grandparent = parent[&parent[&i]];
        parent.insert(i, grandparent);
        i = grandparent;
    }
    i
}

/// The connected components of `edges` over `ids`, each sorted, with more than one member.
pub fn connected_groups(ids: &[i64], edges: impl IntoIterator<Item = Pair>) -> Vec<Vec<i64>> {
    let mut parent: HashMap<i64, i64> = ids.iter().map(|&i| (i, i)).collect();
    for (a, b) in edges {
        if parent.contains_key(&a) && parent.contains_key(&b) {
            let (ra, rb) = (find(&mut parent, a), find(&mut parent, b));
            if ra != rb {
                parent.insert(ra.max(rb), ra.min(rb));
            }
        }
    }
    let mut groups: HashMap<i64, Vec<i64>> = HashMap::new();
    for &i in ids {
        let root = find(&mut parent, i);
        groups.entry(root).or_default().push(i);
    }
    let mut out: Vec<Vec<i64>> = groups
        .into_values()
        .filter(|g| g.len() > 1)
        .map(|mut g| {
            g.sort_unstable();
            g
        })
        .collect();
    out.sort_by_key(|g| g[0]);
    out
}

/// Agglomerative clustering of `ids`: repeatedly merge the two clusters whose average pairwise
/// similarity is highest, while it is at least `threshold`. A missing pair counts as 0. The
/// clusters with more than one member, each sorted.
pub fn average_linkage(ids: &[i64], similarity: &Similarity, threshold: f64) -> Vec<Vec<i64>> {
    let mut sorted = ids.to_vec();
    sorted.sort_unstable();
    let mut clusters: Vec<Vec<i64>> = sorted.into_iter().map(|i| vec![i]).collect();
    let average = |a: &[i64], b: &[i64]| -> f64 {
        let total: f64 =
            a.iter().flat_map(|&x| b.iter().map(move |&y| (x, y))).map(|(x, y)| sim(similarity, x, y)).sum();
        total / (a.len() * b.len()) as f64
    };
    while clusters.len() > 1 {
        let mut best = (-1.0_f64, 0usize, 0usize);
        for i in 0..clusters.len() {
            for j in i + 1..clusters.len() {
                let score = average(&clusters[i], &clusters[j]);
                if score > best.0 {
                    best = (score, i, j);
                }
            }
        }
        let (score, i, j) = best;
        if score < threshold {
            break;
        }
        let merged = clusters.remove(j);
        clusters[i].extend(merged);
        clusters[i].sort_unstable();
    }
    let mut out: Vec<Vec<i64>> = clusters.into_iter().filter(|c| c.len() > 1).collect();
    out.sort_by_key(|c| c[0]);
    out
}

fn sim(similarity: &Similarity, a: i64, b: i64) -> f64 {
    similarity.get(&pair(a, b)).copied().unwrap_or(0.0)
}

/// Split `group` by [`claim_signature`], then cluster each part by average linkage.
pub fn guarded_clusters(
    group: &[i64],
    texts: &HashMap<i64, String>,
    similarity: &Similarity,
    threshold: f64,
) -> Vec<Vec<i64>> {
    let mut parts: Vec<(ClaimSignature, Vec<i64>)> = Vec::new();
    for &fact_id in group {
        let signature = claim_signature(texts.get(&fact_id).map_or("", String::as_str));
        match parts.iter_mut().find(|(s, _)| *s == signature) {
            Some((_, part)) => part.push(fact_id),
            None => parts.push((signature, vec![fact_id])),
        }
    }
    let mut clusters: Vec<Vec<i64>> = Vec::new();
    for (_, part) in parts {
        if part.len() > 1 {
            clusters.extend(average_linkage(&part, similarity, threshold));
        }
    }
    clusters.sort_by_key(|c| c[0]);
    clusters
}

/// The member whose text stands for the cluster: the longest, the oldest on ties.
///
/// # Panics
///
/// With no members.
pub fn representative(members: &[i64], texts: &HashMap<i64, String>) -> i64 {
    *members
        .iter()
        .min_by_key(|&&fact_id| (Reverse(texts.get(&fact_id).map_or(0, |t| t.chars().count())), fact_id))
        .expect("a cluster has members")
}

/// SHA-256 of the sorted member ids joined by commas (`members_sha256`).
pub fn members_sha256(members: &[i64]) -> Vec<u8> {
    let mut sorted = members.to_vec();
    sorted.sort_unstable();
    let joined = sorted.iter().map(ToString::to_string).collect::<Vec<_>>().join(",");
    sha256::digest(joined.as_bytes()).to_vec()
}

// ---------------------------------------------------------------------------
// Level 1: restatements within one document

/// `str.casefold()`: lowercase plus the folds that differ from it in the text facts carry.
fn casefold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.to_lowercase().chars() {
        match ch {
            'ß' => out.push_str("ss"),
            'ſ' => out.push('s'),
            'ς' => out.push('σ'),
            'ﬀ' => out.push_str("ff"),
            'ﬁ' => out.push_str("fi"),
            'ﬂ' => out.push_str("fl"),
            'ﬃ' => out.push_str("ffi"),
            'ﬄ' => out.push_str("ffl"),
            'ﬅ' | 'ﬆ' => out.push_str("st"),
            'µ' => out.push('μ'),
            other => out.push(other),
        }
    }
    out
}

/// `fact` casefolded, with runs of white space collapsed and trailing punctuation dropped.
pub fn normalize_fact(fact: &str) -> String {
    let folded = casefold(fact);
    let collapsed = SPACE.replace_all(&folded, " ");
    collapsed.trim().trim_end_matches(['.', '!', '?', ';', ':', ',']).trim().to_owned()
}

/// `{restatement: (representative, similarity)}` among one document's facts of one class.
///
/// Facts with the same [`normalize_fact`] text count as a pair at similarity 1. `similarity` should
/// hold every pair of a connected group (missing pairs count as 0, which only keeps facts apart).
pub fn document_restatements(
    ids: &[i64],
    texts: &HashMap<i64, String>,
    similarity: &Similarity,
    threshold: f64,
) -> HashMap<i64, (i64, f64)> {
    let mut sims = similarity.clone();
    let mut by_text: Vec<(String, Vec<i64>)> = Vec::new();
    for &fact_id in ids {
        let key = normalize_fact(texts.get(&fact_id).map_or("", String::as_str));
        match by_text.iter_mut().find(|(k, _)| *k == key) {
            Some((_, same)) => same.push(fact_id),
            None => by_text.push((key, vec![fact_id])),
        }
    }
    for (_, same) in &by_text {
        if same.len() < 2 {
            continue;
        }
        // Facts with the same text are one point: each takes the others' similarities, so one
        // with no vector yet does not pull its group's average down.
        let members: HashSet<i64> = same.iter().copied().collect();
        let mut best: HashMap<i64, f64> = HashMap::new();
        for (&(a, b), &s) in similarity {
            for (inside, outside) in [(a, b), (b, a)] {
                if members.contains(&inside) && !members.contains(&outside) {
                    let entry = best.entry(outside).or_insert(0.0);
                    *entry = entry.max(s);
                }
            }
        }
        for (i, &a) in same.iter().enumerate() {
            for &b in &same[i + 1..] {
                sims.insert(pair(a, b), 1.0);
            }
            for (&outside, &s) in &best {
                let entry = sims.entry(pair(a, outside)).or_insert(0.0);
                *entry = entry.max(s);
            }
        }
    }
    let edges: Vec<Pair> = sims.iter().filter(|(_, s)| **s >= threshold).map(|(p, _)| *p).collect();
    let mut restates: HashMap<i64, (i64, f64)> = HashMap::new();
    for group in connected_groups(ids, edges) {
        for members in guarded_clusters(&group, texts, &sims, threshold) {
            let rep = representative(&members, texts);
            for m in members {
                if m != rep {
                    restates.insert(m, (rep, sim(&sims, m, rep)));
                }
            }
        }
    }
    restates
}

// ---------------------------------------------------------------------------
// Level 2: growing a group around a seed

/// A vector as Python read it: 64-bit floats.
pub type Vector = Vec<f64>;

/// A pgvector text value (`[1,2,3]`) as floats.
pub fn parse_vector(literal: &str) -> Vector {
    let inner = literal.trim().trim_start_matches('[').trim_end_matches(']');
    if inner.trim().is_empty() {
        return Vec::new();
    }
    inner.split(',').filter_map(|x| x.trim().parse().ok()).collect()
}

/// Python's `%g` formatting of `value` with `precision` significant digits.
#[allow(clippy::missing_panics_doc)] // `{:e}` always writes an exponent
pub fn py_g(value: f64, precision: usize) -> String {
    if value.is_nan() {
        return "nan".to_owned();
    }
    if value.is_infinite() {
        return if value > 0.0 { "inf".to_owned() } else { "-inf".to_owned() };
    }
    let precision = precision.max(1);
    if value == 0.0 {
        return if value.is_sign_negative() { "-0".to_owned() } else { "0".to_owned() };
    }
    let scientific = format!("{:.*e}", precision - 1, value);
    let (mantissa, exponent) = scientific.split_once('e').expect("an exponent");
    let exponent: i32 = exponent.parse().expect("a numeric exponent");
    if exponent >= -4 && exponent < i32::try_from(precision).unwrap_or(i32::MAX) {
        let decimals = usize::try_from(i32::try_from(precision).unwrap_or(i32::MAX) - 1 - exponent).unwrap_or(0);
        strip_zeros(&format!("{value:.decimals$}"))
    } else {
        let sign = if exponent < 0 { '-' } else { '+' };
        format!("{}e{sign}{:02}", strip_zeros(mantissa), exponent.abs())
    }
}

fn strip_zeros(text: &str) -> String {
    if text.contains('.') { text.trim_end_matches('0').trim_end_matches('.').to_owned() } else { text.to_owned() }
}

/// `[0.1,0.2]`, each value with seven significant digits (`vector_literal`).
pub fn vector_literal(vector: &[f64]) -> String {
    let mut out = String::with_capacity(vector.len() * 10 + 2);
    out.push('[');
    for (i, value) in vector.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&py_g(*value, 7));
    }
    out.push(']');
    out
}

/// The element-wise mean of `vectors`.
pub fn mean_vector(vectors: &[&[f64]]) -> Vector {
    let n = vectors.len() as f64;
    let width = vectors.first().map_or(0, |v| v.len());
    (0..width).map(|i| vectors.iter().map(|v| v[i]).sum::<f64>() / n).collect()
}

/// Cosine similarity; 0 when either vector is zero.
pub fn cosine(a: &[f64], b: &[f64]) -> f64 {
    let dot: f64 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let norm = a.iter().map(|x| x * x).sum::<f64>().sqrt() * b.iter().map(|y| y * y).sum::<f64>().sqrt();
    if norm == 0.0 { 0.0 } else { dot / norm }
}

/// `vector` scaled to unit length (a zero vector stays as it is).
pub fn normalized(vector: &[f64]) -> Vector {
    let norm = vector.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm == 0.0 { vector.to_vec() } else { vector.iter().map(|x| x / norm).collect() }
}

/// The centroid of `count` vectors averaging `centroid`, with `vector` added.
pub fn added(centroid: &[f64], count: usize, vector: &[f64]) -> Vector {
    let count = count as f64;
    centroid.iter().zip(vector).map(|(c, v)| (c * count + v) / (count + 1.0)).collect()
}

/// How far a group's nodes stray from its centroid, and its centroid from its seed (cosine
/// distances).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Variability {
    pub spread: f64,
    pub radius: f64,
    pub drift: f64,
}

/// The group's variability from its members' vectors.
pub fn variability(vectors: &[&[f64]], centroid: &[f64], seed: &[f64]) -> Variability {
    let distances: Vec<f64> = vectors.iter().map(|v| 1.0 - cosine(v, centroid)).collect();
    let n = distances.len().max(1) as f64;
    Variability {
        spread: (distances.iter().sum::<f64>() / n).max(0.0),
        radius: distances.iter().copied().fold(0.0, f64::max),
        drift: (1.0 - cosine(centroid, seed)).max(0.0),
    }
}

/// `(similarity, new centroid)` if `vector` may join a group of `count` at `centroid`, else `None`.
///
/// It may when it is at least `threshold` similar to the centroid (or to `anchor`, the centroid a
/// batch of candidates was fetched around, so a batch is judged against one point) and to the
/// group's `seed`, and the centroid it makes stays within `max_drift` of the seed.
pub fn attach_ok(
    vector: &[f64],
    centroid: &[f64],
    seed: &[f64],
    count: usize,
    threshold: f64,
    max_drift: f64,
    anchor: Option<&[f64]>,
) -> Option<(f64, Vector)> {
    let similarity = cosine(vector, anchor.unwrap_or(centroid));
    if similarity < threshold || cosine(vector, seed) < threshold {
        return None;
    }
    let moved = added(centroid, count, vector);
    if 1.0 - cosine(&moved, seed) > max_drift {
        return None;
    }
    Some((similarity, moved))
}

/// A group grown from a seed: its members (the seed fact first), the core's mean and the settled
/// centroid.
#[derive(Clone, Debug, PartialEq)]
pub struct Grown {
    pub members: Vec<i64>,
    pub seed: Vector,
    pub centroid: Vector,
}

/// What [`grow_group`] asks of its caller: the nearest nodes to a centroid, their vectors and their
/// claim signatures.
#[allow(async_fn_in_trait)]
pub trait GrowthHost {
    /// Candidate nodes nearest `centroid`, nearest first, with their vectors loaded; `members` is
    /// how many of them will be the group's own, which the host fetches beyond.
    async fn knn(&mut self, centroid: &[f64], members: usize) -> Result<Vec<i64>>;
    /// A loaded node's vector.
    fn vector(&self, fact_id: i64) -> &[f64];
    /// A node's claim signature.
    fn signature(&mut self, fact_id: i64) -> ClaimSignature;
}

/// Grow a group from `core` (its seed first) until its centroid settles.
///
/// Candidates in `taken` (other groups) or with another claim signature are passed over. Each round
/// judges its candidates against the centroid they were fetched around, so the walk can stop at the
/// first one [`attach_ok`] refuses: every later one is further away. Members that the settled
/// centroid has left below `threshold` are let go (never the seed fact itself).
///
/// # Errors
///
/// The host's.
pub async fn grow_group<H: GrowthHost>(
    host: &mut H,
    core: &[i64],
    taken: &HashSet<i64>,
    threshold: f64,
    max_drift: f64,
    rounds: usize,
) -> Result<Grown> {
    let mut members = core.to_vec();
    let seed = mean_vector(&members.iter().map(|&m| host.vector(m)).collect::<Vec<_>>());
    let mut centroid = seed.clone();
    let wanted = host.signature(members[0]);
    for _ in 0..rounds {
        let mut changed = false;
        let anchor = centroid.clone();
        for candidate in host.knn(&anchor, members.len()).await? {
            if taken.contains(&candidate) || members.contains(&candidate) || host.signature(candidate) != wanted {
                continue;
            }
            let Some((_, moved)) =
                attach_ok(host.vector(candidate), &centroid, &seed, members.len(), threshold, max_drift, Some(&anchor))
            else {
                break;
            };
            members.push(candidate);
            centroid = moved;
            changed = true;
        }
        let kept: Vec<i64> = members
            .iter()
            .enumerate()
            .filter(|&(i, &m)| i == 0 || cosine(host.vector(m), &centroid) >= threshold)
            .map(|(_, &m)| m)
            .collect();
        if kept.len() != members.len() {
            members = kept;
            centroid = mean_vector(&members.iter().map(|&m| host.vector(m)).collect::<Vec<_>>());
            changed = true;
        }
        if !changed {
            break;
        }
    }
    Ok(Grown { members, seed, centroid })
}

/// The largest distance to the centroid a group of `nodes` may have and still count as tight.
///
/// `nodes` unit vectors that are all `t` similar in pairs sit `sqrt((1 + (nodes - 1) t) / nodes)`
/// similar to their centroid, so the cap depends on the group's size.
pub fn tight_radius(nodes: usize, tight_similarity: f64) -> f64 {
    let t = tight_similarity.clamp(-1.0, 1.0);
    let n = nodes as f64;
    1.0 - (((1.0 + (n - 1.0) * t) / n).max(0.0)).sqrt()
}

/// Whether a group is loose enough that the local model should confirm it: judged by `radius`, its
/// farthest node from the centroid, against [`tight_radius`].
pub fn needs_model(radius: f64, nodes: usize, tight_similarity: f64) -> bool {
    tight_similarity >= 1.0 || radius > tight_radius(nodes, tight_similarity)
}

// ---------------------------------------------------------------------------
// Distillation

pub const DISTILL_SYSTEM_PROMPT: &str = "You compare short statements that were extracted from one person's documents. \
                                         You answer only from the statements themselves.";

/// The question put to the model about one group.
pub fn distill_prompt(statements: &[String]) -> String {
    let listed = statements.iter().enumerate().map(|(i, s)| format!("{}. {s}", i + 1)).collect::<Vec<_>>().join("\n");
    format!(
        "Statements:\n{listed}\n\nDo all of these statements state the same claim, with no difference in who, what, \
         when, where or how much? Answer YES or NO on the first line. If YES, write on the second line one sentence \
         that states the claim, using only information present in the statements."
    )
}

/// `(same, statement)` from the model's reply. Anything but a leading YES is a no.
pub fn parse_distill_reply(reply: &str) -> (bool, Option<String>) {
    let lines: Vec<String> = reply
        .trim()
        .lines()
        .map(|line| line.trim().trim_matches(['*', '#', '>', '_', ' ']).trim().to_owned())
        .filter(|line| !line.is_empty())
        .collect();
    let Some(first) = lines.first() else { return (false, None) };
    if !first.to_uppercase().starts_with("YES") {
        return (false, None);
    }
    // "YES: <sentence>" on one line is accepted too.
    let rest = first[3..].trim_start_matches(['*', '_', ' ', ':', '.', '-', ',']).trim();
    let mut statement = if rest.is_empty() { lines.get(1).cloned().unwrap_or_default() } else { rest.to_owned() };
    if statement.to_lowercase().starts_with("statement:") {
        statement = statement["statement:".len()..].to_owned();
    }
    let statement = statement.trim().trim_matches('"').trim().to_owned();
    (true, (!statement.is_empty()).then_some(statement))
}

/// Confirms a cluster and states its claim with the local chat model (`Distiller`).
pub trait Distill: Send + Sync {
    /// `provider/model_ref`, recorded on the groups it stated.
    fn model_id(&self) -> String;
    /// Whether facts of these corpus classes may go to the model's host.
    fn may_send(&self, corpus_classes: &[&str]) -> bool;
    /// `(same, statement)` for the statements, or why the model could not be asked.
    ///
    /// # Errors
    ///
    /// The model's failure, as a message.
    fn distill(&self, statements: &[String]) -> std::result::Result<(bool, Option<String>), String>;
}

/// [`Distill`] over the configured chat model.
pub struct ChatDistiller {
    pub chat: Arc<dyn Chat>,
}

impl Distill for ChatDistiller {
    fn model_id(&self) -> String {
        format!("{}/{}", self.chat.provider(), self.chat.model_ref())
    }

    fn may_send(&self, corpus_classes: &[&str]) -> bool {
        !corpus_classes.contains(&"communication")
            || check_content(self.chat.host_url(), "cluster-facts", "communication").is_ok()
    }

    fn distill(&self, statements: &[String]) -> std::result::Result<(bool, Option<String>), String> {
        let messages = [
            json!({"role": "system", "content": DISTILL_SYSTEM_PROMPT}),
            json!({"role": "user", "content": distill_prompt(statements)}),
        ];
        let reply = self.chat.complete(&messages, Some(200), Some(0.0)).map_err(|e| e.0)?;
        Ok(parse_distill_reply(&reply.text))
    }
}

// ---------------------------------------------------------------------------
// The pass

/// The knobs of one run (`ClusterParams`; `facts.cluster_*` in the config).
#[derive(Clone, Debug, PartialEq)]
pub struct ClusterParams {
    pub threshold: f64,
    pub neighbors: i64,
    pub seed_threshold: f64,
    pub max_drift: f64,
    pub tight_similarity: f64,
    pub growth_neighbors: i64,
    pub growth_rounds: usize,
    pub attach_candidates: i64,
    pub distill_facts: usize,
    pub max_pairwise: usize,
    /// Level 1's own threshold (no model confirms a restatement); `None`: `threshold`.
    pub restate_threshold: Option<f64>,
}

impl ClusterParams {
    /// The parameters `ops.facts.cluster_facts` builds: the request's threshold and neighbours
    /// over `facts.cluster_*`, checked.
    ///
    /// # Errors
    ///
    /// `ValueError`'s messages for a threshold outside (0, 1] or fewer than one neighbour.
    pub fn from_config(config: &Config, threshold: Option<f64>, neighbors: Option<i64>) -> Result<Self> {
        let float = |field: &str| config.field(field).as_f64().unwrap_or(0.0);
        let integer = |field: &str| config.field(field).as_i64().unwrap_or(0);
        let threshold = threshold.unwrap_or_else(|| float("fact_cluster_threshold"));
        let neighbors = neighbors.filter(|&n| n != 0).unwrap_or_else(|| integer("fact_cluster_neighbors"));
        if !(threshold > 0.0 && threshold <= 1.0) {
            return Err(ServiceError::invalid(format!(
                "threshold must be above 0 and at most 1, not {}",
                garage_mcp::pyrepr::float_repr(threshold)
            )));
        }
        if neighbors < 1 {
            return Err(ServiceError::invalid(format!("neighbors must be at least 1, not {neighbors}")));
        }
        Ok(Self {
            threshold,
            neighbors,
            seed_threshold: threshold.max(float("fact_cluster_seed_threshold")),
            max_drift: float("fact_cluster_max_drift"),
            tight_similarity: float("fact_cluster_tight_similarity"),
            growth_neighbors: integer("fact_cluster_growth_neighbors"),
            growth_rounds: usize::try_from(integer("fact_cluster_growth_rounds")).unwrap_or(0),
            attach_candidates: integer("fact_cluster_attach_candidates"),
            distill_facts: usize::try_from(integer("fact_cluster_distill_facts")).unwrap_or(0),
            max_pairwise: usize::try_from(integer("fact_cluster_max_pairwise")).unwrap_or(0),
            restate_threshold: Some(float("fact_cluster_restate_threshold")),
        })
    }

    /// Level 1's threshold.
    pub fn restate(&self) -> f64 {
        self.restate_threshold.unwrap_or(self.threshold)
    }

    /// `facts.dedup_key` of a document compared under this model and threshold.
    pub fn document_key(&self, slug: &str) -> String {
        format!("{slug};t={}", py_g(self.restate(), 6))
    }

    /// What shapes the groups; a change regroups the corpus.
    pub fn corpus_key(&self) -> String {
        format!(
            "t={};s={};d={};g={};r={}",
            py_g(self.threshold, 6),
            py_g(self.seed_threshold, 6),
            py_g(self.max_drift, 6),
            self.growth_neighbors,
            self.growth_rounds
        )
    }
}

/// Where a run is (`ClusterProgress`). `phase` is `documents`, `neighbors`, `grow`, `attach`,
/// `distill` or `done`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClusterProgress {
    pub phase: String,
    pub full: bool,
    pub facts: i64,
    pub unembedded: i64,
    pub documents: i64,
    pub restatements: i64,
    pub nodes: i64,
    pub scanned: i64,
    pub candidates: i64,
    pub attached: i64,
    pub accepted: i64,
    pub anchors: i64,
    pub anchored: i64,
    pub distilled: i64,
    pub to_distill: i64,
    pub clusters: i64,
    pub clustered_facts: i64,
    pub distilled_facts: i64,
    pub kept: i64,
    pub dissolved: i64,
    pub failed: i64,
    pub withheld: i64,
    pub errors: Vec<String>,
}

impl ClusterProgress {
    /// One line on where the run is, for a progress display; empty for `done`.
    pub fn message(&self) -> String {
        let thousands = crate::service::thousands;
        match self.phase.as_str() {
            "documents" => format!("comparing each document's facts: {} documents", thousands(self.documents)),
            "neighbors" => format!("finding neighbours: {}/{} facts", thousands(self.scanned), thousands(self.nodes)),
            "grow" => format!("growing groups: {}", thousands(self.candidates)),
            "attach" => format!("placing new facts: {}/{}", thousands(self.scanned), thousands(self.nodes)),
            "distill" => format!("asking the model about group {}", thousands(self.distilled)),
            _ => String::new(),
        }
    }
}

/// The outcome of one run as the RPC and the CLI report it (`ClusterSummary`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClusterSummary {
    pub model: String,
    pub threshold: f64,
    pub distill_model: String,
    pub state: ClusterProgress,
    /// The AGE graph, re-projected after the run; empty where the server has no AGE.
    pub graph: String,
}

impl ClusterSummary {
    /// `ClusterSummary.message`.
    pub fn message(&self) -> String {
        let thousands = crate::service::thousands;
        let s = &self.state;
        let mut text = format!(
            "{} potential facts distilled into {}; {} of those group {} restatements",
            thousands(s.facts),
            thousands(s.distilled_facts),
            thousands(s.clusters),
            thousands(s.clustered_facts)
        );
        if s.restatements > 0 {
            let _ = write!(text, " ({} restate another fact of their own document)", thousands(s.restatements));
        }
        if s.full {
            text.push_str("; regrouped the corpus");
        } else if s.nodes > 0 {
            let _ =
                write!(text, "; {} of {} new facts joined a distilled fact", thousands(s.attached), thousands(s.nodes));
        }
        if s.dissolved > 0 {
            let _ = write!(text, ", {} rejected by the model", s.dissolved);
        }
        if s.failed > 0 {
            let _ = write!(text, ", {} not distilled (model error)", s.failed);
        }
        if s.withheld > 0 {
            let _ = write!(text, ", {} left ungrouped (communications stay on this machine)", s.withheld);
        }
        if s.unembedded > 0 {
            let _ = write!(text, "; {} facts have no vector yet (run the backfill)", thousands(s.unembedded));
        }
        text
    }
}

/// Receives each progress report; `false` stops the run (the client went away).
pub type Reporter<'r> = &'r mut (dyn FnMut(&ClusterProgress) -> bool + Send + Sync);

struct Statement {
    text: String,
    generated: bool,
    distill_model: Option<String>,
}

fn has_vector(table: &str, alias: &str) -> String {
    format!("EXISTS (SELECT 1 FROM {table} he WHERE he.fact_id = {alias}.id)")
}

/// Not a metadata fact: metadata facts are placed by their key, never by their vector.
fn inferred(alias: &str) -> String {
    format!("{alias}.extractor <> '{METADATA_EXTRACTOR}'")
}

struct Pass<'c, 'r> {
    tx: Transaction<'c>,
    model: EmbeddingModel,
    params: ClusterParams,
    distiller: Option<Arc<dyn Distill>>,
    report_to: Option<Reporter<'r>>,
    state: ClusterProgress,
    /// The model's potential-fact vectors, keyed on `fact_id`.
    table: String,
    fact_table: String,
    coltype: String,
    /// The model's own distance operator, so its index serves the scan; similarity is judged by
    /// cosine regardless.
    op: &'static str,
    texts: HashMap<i64, String>,
    fact_class: HashMap<i64, String>,
    corpus_class: HashMap<i64, String>,
    document: HashMap<i64, i64>,
    vectors: HashMap<i64, Vector>,
    signatures: HashMap<i64, ClaimSignature>,
    /// Classes with at least one anchor: only their facts are tried against anchors.
    anchor_classes: HashSet<String>,
}

type Row = tokio_postgres::Row;

impl Pass<'_, '_> {
    // -- plumbing -------------------------------------------------------------

    fn report(&mut self, phase: &str) -> Result<()> {
        phase.clone_into(&mut self.state.phase);
        if let Some(report) = self.report_to.as_mut()
            && !report(&self.state)
        {
            return Err(ServiceError::Failed("cluster-facts cancelled: the client went away".into()));
        }
        Ok(())
    }

    fn signature(&mut self, fact_id: i64) -> ClaimSignature {
        if let Some(signature) = self.signatures.get(&fact_id) {
            return signature.clone();
        }
        let signature = claim_signature(self.texts.get(&fact_id).map_or("", String::as_str));
        self.signatures.insert(fact_id, signature.clone());
        signature
    }

    fn cast(&self, n: usize) -> String {
        format!("CAST(CAST(${n} AS text) AS {})", self.coltype)
    }

    async fn load_vectors(&mut self, ids: &[i64]) -> Result<()> {
        let missing: Vec<i64> = ids.iter().copied().filter(|i| !self.vectors.contains_key(i)).collect();
        let sql = format!("SELECT e.fact_id, e.embedding::text FROM {} e WHERE e.fact_id = ANY($1)", self.table);
        for chunk in missing.chunks(1000) {
            for row in self.tx.query(&sql, &[&chunk]).await? {
                let fact_id: i64 = row.get(0);
                let literal: String = row.get(1);
                self.vectors.insert(fact_id, parse_vector(&literal));
            }
        }
        Ok(())
    }

    fn vectors_of(&self, members: &[i64]) -> Vec<&[f64]> {
        members.iter().map(|m| self.vectors[m].as_slice()).collect()
    }

    async fn load_facts(&mut self) -> Result<()> {
        let rows = self
            .tx
            .query(
                "SELECT f.id, f.document_id, f.fact, f.fact_class, d.corpus_class::text \
                 FROM facts f JOIN documents d ON d.id = f.document_id ORDER BY f.id",
                &[],
            )
            .await?;
        for row in rows {
            let fact_id: i64 = row.get(0);
            self.document.insert(fact_id, row.get(1));
            self.texts.insert(fact_id, row.get(2));
            self.fact_class.insert(fact_id, row.get(3));
            self.corpus_class.insert(fact_id, row.get(4));
        }
        self.state.facts = i64::try_from(self.texts.len()).unwrap_or(i64::MAX);
        self.state.unembedded = self
            .tx
            .query_one(&format!("SELECT count(*) FROM facts f WHERE NOT {}", has_vector(&self.table, "f")), &[])
            .await?
            .get(0);
        Ok(())
    }

    async fn other_fact_tables(&self) -> Result<Vec<String>> {
        let mut tables = Vec::new();
        for row in self.tx.query("SELECT table_name FROM embedding_models WHERE id <> $1", &[&self.model.id]).await? {
            let name: String = row.get(0);
            let table = fact_table_name(&name)?;
            let exists: bool =
                self.tx.query_one("SELECT to_regclass(CAST($1 AS text)) IS NOT NULL", &[&table]).await?.get(0);
            if exists {
                tables.push(table);
            }
        }
        Ok(tables)
    }

    /// Drop other models' vectors for distilled facts whose nodes changed; the backfill remakes them.
    async fn stale_elsewhere(&self, ids: &[i64]) -> Result<()> {
        if ids.is_empty() {
            return Ok(());
        }
        for table in self.other_fact_tables().await? {
            self.tx.execute(&format!("DELETE FROM {table} WHERE distilled_fact_id = ANY($1)"), &[&ids]).await?;
        }
        Ok(())
    }

    // -- level 1 --------------------------------------------------------------

    /// Link each document's restatements to their representative; see [`document_restatements`].
    #[allow(clippy::too_many_lines)]
    async fn restate_documents(&mut self, full: bool) -> Result<()> {
        let key = self.params.document_key(&self.model.slug);
        let docs: Vec<i64> = if full {
            let mut docs: Vec<i64> = self.document.values().copied().collect::<HashSet<_>>().into_iter().collect();
            docs.sort_unstable();
            docs
        } else {
            self.tx
                .query(
                    &format!(
                        "SELECT DISTINCT f.document_id FROM facts f \
                         WHERE (f.dedup_key IS NULL AND {has}) \
                            OR (f.dedup_key IS NOT NULL AND f.dedup_key <> $1) \
                            OR (f.restates_fact_id IS NULL AND f.restates_similarity IS NOT NULL) \
                         ORDER BY 1",
                        has = has_vector(&self.table, "f")
                    ),
                    &[&key],
                )
                .await?
                .iter()
                .map(|row| row.get(0))
                .collect()
        };
        let mut by_doc: HashMap<i64, Vec<i64>> = HashMap::new();
        for (&fact_id, &doc) in &self.document {
            by_doc.entry(doc).or_default().push(fact_id);
        }
        let above = format!(
            "WITH v AS (\
                SELECT e.fact_id, f.document_id, f.fact_class, e.embedding \
                FROM {table} e JOIN facts f ON f.id = e.fact_id \
                WHERE f.document_id = ANY($1) AND {inferred}) \
             SELECT a.fact_id, b.fact_id, 1 - (a.embedding <=> b.embedding) \
             FROM v a JOIN v b ON b.document_id = a.document_id AND b.fact_class = a.fact_class \
                                AND a.fact_id < b.fact_id \
             WHERE 1 - (a.embedding <=> b.embedding) >= $2",
            table = self.table,
            inferred = inferred("f")
        );
        let pairwise = pairwise_sql(&self.table);
        let reset = format!(
            "UPDATE facts f SET restates_fact_id = NULL, restates_similarity = NULL, \
                                dedup_key = CASE WHEN {} THEN $2 END \
             WHERE f.document_id = ANY($1)",
            has_vector(&self.table, "f")
        );
        let link = "UPDATE facts f SET restates_fact_id = v.rep, restates_similarity = v.similarity \
                    FROM unnest($1::bigint[], $2::bigint[], $3::real[]) AS v(id, rep, similarity) WHERE f.id = v.id";
        let restating = "SELECT id FROM facts WHERE document_id = ANY($1) AND restates_similarity IS NOT NULL";
        // A restatement that stands on its own again is placed afresh at level 2; every other fact
        // keeps its distilled fact (a representative that became a restatement leaves its group,
        // which the refresh re-centres).
        let detach = "UPDATE facts SET distilled_fact_id = NULL, distilled_similarity = NULL WHERE id = ANY($1)";
        let threshold = self.params.restate();
        for batch in docs.chunks(DOCUMENT_BATCH) {
            // Above-threshold pairs, by document and class.
            let mut found: HashMap<(i64, String), Similarity> = HashMap::new();
            for row in self.tx.query(&above, &[&batch, &threshold]).await? {
                let (a, b, s): (i64, i64, f64) = (row.get(0), row.get(1), row.get(2));
                let (Some(&doc), Some(class)) = (self.document.get(&a), self.fact_class.get(&a)) else { continue };
                found.entry((doc, class.clone())).or_default().insert(pair(a, b), s);
            }
            let mut links: (Vec<i64>, Vec<i64>, Vec<f32>) = (Vec::new(), Vec::new(), Vec::new());
            let mut linked: HashSet<i64> = HashSet::new();
            for &doc in batch {
                let mut by_class: Vec<(String, Vec<i64>)> = Vec::new();
                for &fact_id in by_doc.get(&doc).map_or(&[][..], Vec::as_slice) {
                    let class = &self.fact_class[&fact_id];
                    match by_class.iter_mut().find(|(c, _)| c == class) {
                        Some((_, ids)) => ids.push(fact_id),
                        None => by_class.push((class.clone(), vec![fact_id])),
                    }
                }
                for (fact_class, ids) in by_class {
                    if ids.len() < 2 {
                        continue;
                    }
                    let mut sims = found.remove(&(doc, fact_class)).unwrap_or_default();
                    for group in connected_groups(&ids, sims.keys().copied()) {
                        if group.len() > 2 && group.len() <= self.params.max_pairwise {
                            for row in self.tx.query(&pairwise, &[&group]).await? {
                                let (a, b, s): (i64, i64, f64) = (row.get(0), row.get(1), row.get(2));
                                sims.insert(pair(a, b), s);
                            }
                        }
                    }
                    let mut restated: Vec<(i64, (i64, f64))> =
                        document_restatements(&ids, &self.texts, &sims, threshold).into_iter().collect();
                    restated.sort_by_key(|(id, _)| *id);
                    for (fact_id, (rep, s)) in restated {
                        links.0.push(fact_id);
                        links.1.push(rep);
                        links.2.push(s as f32);
                        linked.insert(fact_id);
                    }
                }
            }
            let was: HashSet<i64> = self.tx.query(restating, &[&batch]).await?.iter().map(|row| row.get(0)).collect();
            self.tx.execute(&reset, &[&batch, &key]).await?;
            if !links.0.is_empty() {
                self.tx.execute(link, &[&links.0, &links.1, &links.2]).await?;
            }
            let mut freed: Vec<i64> = was.difference(&linked).copied().collect();
            freed.sort_unstable();
            if !freed.is_empty() && !full {
                self.tx.execute(detach, &[&freed]).await?;
            }
            self.state.documents += i64::try_from(batch.len()).unwrap_or(0);
            self.report("documents")?;
        }
        self.state.restatements =
            self.tx.query_one("SELECT count(*) FROM facts WHERE restates_fact_id IS NOT NULL", &[]).await?.get(0);
        Ok(())
    }

    // -- level 2: deciding and writing groups ----------------------------------

    /// How a group is stated, or `None` when it is not kept: the model says its members state
    /// different claims, or it needs the model and its facts may not go to it.
    async fn confirm(&mut self, members: &[i64], centroid: &[f64], var: Variability) -> Result<Option<Statement>> {
        let stated = Statement {
            text: self.texts[&representative(members, &self.texts)].clone(),
            generated: false,
            distill_model: None,
        };
        if !needs_model(var.radius, members.len(), self.params.tight_similarity) {
            self.state.accepted += 1;
            return Ok(Some(stated));
        }
        let Some(distiller) = self.distiller.clone() else { return Ok(Some(stated)) };
        let mut shown = members.to_vec();
        shown.sort_by(|&a, &b| {
            cosine(&self.vectors[&b], centroid)
                .partial_cmp(&cosine(&self.vectors[&a], centroid))
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.cmp(&b))
        });
        shown.truncate(self.params.distill_facts);
        self.state.distilled += 1;
        let classes: Vec<&str> = shown.iter().map(|m| self.corpus_class[m].as_str()).collect();
        if !distiller.may_send(&classes) {
            // A communication may not go to this model, and a loose group is not kept
            // unconfirmed: its facts stay apart.
            self.state.withheld += 1;
            return Ok(None);
        }
        let statements: Vec<String> = shown.iter().map(|m| self.texts[m].clone()).collect();
        let answer = tokio::task::spawn_blocking(move || distiller.distill(&statements))
            .await
            .unwrap_or_else(|e| Err(format!("distiller panicked: {e}")));
        self.report("distill")?;
        let (same, statement) = match answer {
            Ok(answer) => answer,
            Err(message) => {
                self.state.failed += 1;
                if self.state.errors.len() < 5 {
                    self.state.errors.push(message);
                }
                return Ok(Some(stated));
            }
        };
        if !same {
            self.state.dissolved += 1;
            return Ok(None);
        }
        let model_id = Some(self.distiller.as_ref().map(|d| d.model_id()).unwrap_or_default());
        Ok(Some(match statement {
            Some(text) => Statement { text, generated: true, distill_model: model_id },
            None => Statement { text: stated.text, generated: false, distill_model: model_id },
        }))
    }

    async fn write_group(
        &mut self,
        members: &[i64],
        centroid: &[f64],
        seed: &[f64],
        statement: &Statement,
    ) -> Result<i64> {
        let var = variability(&self.vectors_of(members), centroid, seed);
        let row = self
            .tx
            .query_one(
                "INSERT INTO distilled_facts (fact_class, statement, statement_generated, representative_fact_id, \
                                              members_sha256, model_slug, threshold, distill_model, \
                                              nodes, spread, drift, radius) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING id",
                &[
                    &self.fact_class[&members[0]],
                    &statement.text,
                    &statement.generated,
                    &representative(members, &self.texts),
                    &members_sha256(members),
                    &self.model.slug,
                    &(self.params.threshold as f32),
                    &statement.distill_model,
                    &i32::try_from(members.len()).unwrap_or(i32::MAX),
                    &(var.spread as f32),
                    &(var.drift as f32),
                    &(var.radius as f32),
                ],
            )
            .await?;
        let did: i64 = row.get(0);
        self.tx
            .execute(
                &format!(
                    "INSERT INTO {} (distilled_fact_id, embedding, seed) VALUES ($1, {}, {})",
                    self.fact_table,
                    self.cast(2),
                    self.cast(3)
                ),
                &[&did, &vector_literal(&normalized(centroid)), &vector_literal(&normalized(seed))],
            )
            .await?;
        self.link(did, members, centroid).await?;
        Ok(did)
    }

    async fn link(&self, did: i64, members: &[i64], centroid: &[f64]) -> Result<()> {
        let similarities: Vec<f32> = members.iter().map(|m| cosine(&self.vectors[m], centroid) as f32).collect();
        self.tx
            .execute(
                "UPDATE facts f SET distilled_fact_id = $1, distilled_similarity = v.similarity \
                 FROM unnest($2::bigint[], $3::real[]) AS v(id, similarity) WHERE f.id = v.id",
                &[&did, &members, &similarities],
            )
            .await?;
        Ok(())
    }

    async fn write_single(&self, fact_id: i64) -> Result<i64> {
        let row = self
            .tx
            .query_one(
                "INSERT INTO distilled_facts (fact_class, statement, representative_fact_id, members_sha256, \
                                              nodes, spread, drift, radius) \
                 VALUES ($1, $2, $3, $4, 1, 0, 0, 0) RETURNING id",
                &[&self.fact_class[&fact_id], &self.texts[&fact_id], &fact_id, &members_sha256(&[fact_id])],
            )
            .await?;
        let did: i64 = row.get(0);
        let vector = vector_literal(&self.vectors[&fact_id]);
        self.tx
            .execute(
                &format!(
                    "INSERT INTO {} (distilled_fact_id, embedding, seed) VALUES ($1, {}, {})",
                    self.fact_table,
                    self.cast(2),
                    self.cast(2)
                ),
                &[&did, &vector],
            )
            .await?;
        self.tx
            .execute(
                "UPDATE facts SET distilled_fact_id = $1, distilled_similarity = NULL WHERE id = $2",
                &[&did, &fact_id],
            )
            .await?;
        Ok(did)
    }

    async fn nodes(&self) -> Result<Vec<i64>> {
        Ok(self
            .tx
            .query(
                &format!(
                    "SELECT f.id FROM facts f WHERE f.restates_fact_id IS NULL AND {} AND {} ORDER BY f.id",
                    has_vector(&self.table, "f"),
                    inferred("f")
                ),
                &[],
            )
            .await?
            .iter()
            .map(|row| row.get(0))
            .collect())
    }

    async fn knn_nodes(&mut self, centroid: &[f64], fact_class: &str, k: i64) -> Result<Vec<i64>> {
        let rows = self
            .tx
            .query(
                &format!(
                    "SELECT e.fact_id, e.embedding::text FROM {table} e JOIN facts f ON f.id = e.fact_id \
                     WHERE f.fact_class = $1 AND f.restates_fact_id IS NULL AND {inferred} \
                     ORDER BY e.embedding {op} {v} LIMIT $3",
                    table = self.table,
                    inferred = inferred("f"),
                    op = self.op,
                    v = self.cast(2)
                ),
                &[&fact_class, &vector_literal(centroid), &k],
            )
            .await?;
        let mut found = Vec::with_capacity(rows.len());
        for row in rows {
            let fact_id: i64 = row.get(0);
            let literal: String = row.get(1);
            self.vectors.entry(fact_id).or_insert_with(|| parse_vector(&literal));
            found.push(fact_id);
        }
        Ok(found)
    }

    // -- anchors: metadata values, ground truth ------------------------------------

    /// Make each metadata value an anchored distilled fact, link its facts to it, and fix its
    /// centroid.
    #[allow(clippy::too_many_lines)]
    async fn anchor(&mut self) -> Result<()> {
        let key = "f.attributes->>'key'";
        let first = format!(
            "SELECT DISTINCT ON (f.fact_class, {key}) f.id, f.fact, f.fact_class, {key} AS key \
             FROM facts f WHERE f.extractor = '{METADATA_EXTRACTOR}' AND {key} IS NOT NULL \
             ORDER BY f.fact_class, {key}, f.id"
        );
        // An anchor whose value no document states any more goes; facts that joined it are placed afresh.
        self.tx
            .execute(
                &format!(
                    "DELETE FROM distilled_facts df WHERE df.anchor_key IS NOT NULL AND NOT EXISTS (\
                         SELECT 1 FROM facts f WHERE f.extractor = '{METADATA_EXTRACTOR}' \
                           AND f.fact_class = df.fact_class AND {key} = df.anchor_key)"
                ),
                &[],
            )
            .await?;
        // A representative deleted from under its anchor (its document read again): the value's
        // first fact takes over, and the anchor's vectors are made again from it.
        let reseated: Vec<i64> = self
            .tx
            .query(
                &format!(
                    "UPDATE distilled_facts df SET representative_fact_id = m.id, statement = m.fact \
                     FROM ({first}) m \
                     WHERE df.anchor_key IS NOT NULL AND df.representative_fact_id IS NULL \
                       AND m.fact_class = df.fact_class AND m.key = df.anchor_key \
                     RETURNING df.id"
                ),
                &[],
            )
            .await?
            .iter()
            .map(|row| row.get(0))
            .collect();
        if !reseated.is_empty() {
            let mut tables = vec![self.fact_table.clone()];
            tables.extend(self.other_fact_tables().await?);
            for table in tables {
                self.tx
                    .execute(&format!("DELETE FROM {table} WHERE distilled_fact_id = ANY($1)"), &[&reseated])
                    .await?;
            }
        }
        self.tx
            .execute(
                &format!(
                    "INSERT INTO distilled_facts (fact_class, statement, representative_fact_id, members_sha256, \
                                                  anchor_key, model_slug, nodes, spread, drift, radius) \
                     SELECT m.fact_class, m.fact, m.id, \
                            sha256(convert_to('anchor:' || m.fact_class || ':' || m.key, 'UTF8')), \
                            m.key, $1, 1, 0, 0, 0 \
                     FROM ({first}) m \
                     ON CONFLICT (fact_class, anchor_key) WHERE anchor_key IS NOT NULL DO NOTHING"
                ),
                &[&self.model.slug],
            )
            .await?;
        self.tx
            .execute("UPDATE distilled_facts SET model_slug = $1 WHERE anchor_key IS NOT NULL", &[&self.model.slug])
            .await?;
        self.tx
            .execute(
                &format!(
                    "UPDATE facts f SET distilled_fact_id = df.id, distilled_similarity = 1 \
                     FROM distilled_facts df \
                     WHERE f.extractor = '{METADATA_EXTRACTOR}' AND df.anchor_key = {key} AND df.fact_class = f.fact_class \
                       AND (f.distilled_fact_id IS DISTINCT FROM df.id OR f.distilled_similarity IS DISTINCT FROM 1)"
                ),
                &[],
            )
            .await?;
        // The fixed centroid: the representative's own vector, once it has one, never moved after.
        self.tx
            .execute(
                &format!(
                    "INSERT INTO {fact_table} (distilled_fact_id, embedding, seed) \
                     SELECT df.id, e.embedding, e.embedding \
                     FROM distilled_facts df JOIN {table} e ON e.fact_id = df.representative_fact_id \
                     WHERE df.anchor_key IS NOT NULL \
                     ON CONFLICT (distilled_fact_id) DO NOTHING",
                    fact_table = self.fact_table,
                    table = self.table
                ),
                &[],
            )
            .await?;
        self.anchor_classes = self
            .tx
            .query(
                &format!(
                    "SELECT DISTINCT df.fact_class FROM distilled_facts df JOIN {} fe \
                     ON fe.distilled_fact_id = df.id WHERE df.anchor_key IS NOT NULL",
                    self.fact_table
                ),
                &[],
            )
            .await?
            .iter()
            .map(|row| row.get(0))
            .collect();
        self.state.anchors =
            self.tx.query_one("SELECT count(*) FROM distilled_facts WHERE anchor_key IS NOT NULL", &[]).await?.get(0);
        Ok(())
    }

    /// Join each of `facts` to the nearest anchor of its class it is close enough to; those that joined.
    async fn join_anchors(&mut self, facts: &[i64]) -> Result<Vec<i64>> {
        let tried: Vec<i64> =
            facts.iter().copied().filter(|f| self.anchor_classes.contains(&self.fact_class[f])).collect();
        if tried.is_empty() {
            return Ok(Vec::new());
        }
        self.load_vectors(&tried).await?;
        let nearest = format!(
            "SELECT fe.distilled_fact_id, fe.embedding::text, df.representative_fact_id \
             FROM {fact_table} fe JOIN distilled_facts df ON df.id = fe.distilled_fact_id \
             WHERE df.fact_class = $1 AND df.anchor_key IS NOT NULL \
             ORDER BY fe.embedding {op} {v} LIMIT $3",
            fact_table = self.fact_table,
            op = self.op,
            v = self.cast(2)
        );
        let mut joined: Vec<i64> = Vec::new();
        let mut links: (Vec<i64>, Vec<i64>, Vec<f32>) = (Vec::new(), Vec::new(), Vec::new());
        for fact_id in tried {
            let Some(vector) = self.vectors.get(&fact_id).cloned() else { continue };
            let rows = self
                .tx
                .query(
                    &nearest,
                    &[&self.fact_class[&fact_id], &vector_literal(&vector), &self.params.attach_candidates],
                )
                .await?;
            for row in rows {
                let (did, centroid, rep): (i64, String, Option<i64>) = (row.get(0), row.get(1), row.get(2));
                let Some(rep) = rep else { continue };
                if self.signature(rep) != self.signature(fact_id) {
                    continue;
                }
                let similarity = cosine(&vector, &parse_vector(&centroid));
                if similarity < self.params.threshold {
                    continue;
                }
                links.0.push(did);
                links.1.push(fact_id);
                links.2.push(similarity as f32);
                joined.push(fact_id);
                break;
            }
        }
        if !links.0.is_empty() {
            self.tx
                .execute(
                    "UPDATE facts f SET distilled_fact_id = v.did, distilled_similarity = v.similarity \
                     FROM unnest($1::bigint[], $2::bigint[], $3::real[]) AS v(did, id, similarity) WHERE f.id = v.id",
                    &[&links.0, &links.1, &links.2],
                )
                .await?;
        }
        self.state.anchored += i64::try_from(joined.len()).unwrap_or(0);
        Ok(joined)
    }

    /// Record how many nodes each anchor backs and how far they sit from its fixed centroid.
    async fn anchor_stats(&self) -> Result<()> {
        self.tx
            .execute(
                &format!(
                    "UPDATE distilled_facts df SET nodes = s.n, spread = s.spread, radius = s.radius, drift = 0 \
                     FROM (\
                         SELECT d.id, count(*) AS n, \
                                coalesce(avg(e.embedding <=> fe.embedding), 0) AS spread, \
                                coalesce(max(e.embedding <=> fe.embedding), 0) AS radius \
                         FROM distilled_facts d \
                         JOIN facts f ON f.distilled_fact_id = d.id AND f.restates_fact_id IS NULL \
                         LEFT JOIN {fact_table} fe ON fe.distilled_fact_id = d.id \
                         LEFT JOIN {table} e ON e.fact_id = f.id \
                         WHERE d.anchor_key IS NOT NULL \
                         GROUP BY d.id) s \
                     WHERE df.id = s.id",
                    fact_table = self.fact_table,
                    table = self.table
                ),
                &[],
            )
            .await?;
        Ok(())
    }

    // -- level 2: a full run ----------------------------------------------------

    async fn regroup(&mut self) -> Result<()> {
        // A group found again with the same nodes keeps its row: its id, its statement and every
        // model's vector. Single facts keep theirs in finish().
        let previous: HashMap<Vec<u8>, i64> = self
            .tx
            .query("SELECT id, members_sha256 FROM distilled_facts WHERE model_slug IS NOT NULL", &[])
            .await?
            .iter()
            .map(|row| (row.get::<_, Vec<u8>>(1), row.get::<_, i64>(0)))
            .collect();
        self.tx
            .execute(
                "UPDATE facts SET distilled_fact_id = NULL, distilled_similarity = NULL WHERE distilled_fact_id IS NOT NULL",
                &[],
            )
            .await?;

        self.anchor().await?;
        let mut nodes = self.nodes().await?;
        self.state.nodes = i64::try_from(nodes.len()).unwrap_or(i64::MAX);
        // Ground truth first: a node close enough to an anchor joins it and grows no group.
        let mut taken: HashSet<i64> = self.join_anchors(&nodes).await?.into_iter().collect();
        nodes.retain(|n| !taken.contains(n));
        self.report("neighbors")?;
        let mut neighbors: HashMap<i64, Vec<(i64, f64)>> = HashMap::new();
        let neighbor_sql = neighbor_sql(&self.table, self.op);
        for batch in nodes.chunks(NEIGHBOR_BATCH) {
            for row in self.tx.query(&neighbor_sql, &[&batch, &self.params.neighbors]).await? {
                let (a, b, s): (i64, i64, Option<f64>) = (row.get(0), row.get(1), row.get(2));
                if let Some(s) = s
                    && s >= self.params.threshold
                {
                    neighbors.entry(a).or_default().push((b, s));
                    neighbors.entry(b).or_default().push((a, s));
                }
            }
            self.state.scanned += i64::try_from(batch.len()).unwrap_or(0);
            self.report("neighbors")?;
        }

        // Densest first: a seed with many close neighbours is likelier the middle of a claim than its edge.
        let mut seeds: Vec<i64> = neighbors.keys().copied().collect();
        seeds.sort_by_key(|n| (Reverse(neighbors[n].iter().map(|(b, _)| *b).collect::<HashSet<_>>().len()), *n));
        let mut grown: Vec<Grown> = Vec::new();
        for seed in seeds {
            if taken.contains(&seed) {
                continue;
            }
            let wanted = self.signature(seed);
            let mut close = neighbors[&seed].clone();
            close.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then(a.0.cmp(&b.0)));
            let mut core = vec![seed];
            for (b, s) in close {
                if s >= self.params.seed_threshold
                    && !taken.contains(&b)
                    && !core.contains(&b)
                    && self.signature(b) == wanted
                {
                    core.push(b);
                }
            }
            self.load_vectors(&core).await?;
            let fact_class = self.fact_class[&seed].clone();
            let (threshold, max_drift, rounds) =
                (self.params.threshold, self.params.max_drift, self.params.growth_rounds);
            let group = {
                let mut grower = Grower { pass: self, fact_class: &fact_class };
                grow_group(&mut grower, &core, &taken, threshold, max_drift, rounds).await?
            };
            if group.members.len() > 1 {
                taken.extend(group.members.iter().copied());
                grown.push(group);
                self.state.candidates = i64::try_from(grown.len()).unwrap_or(i64::MAX);
                self.report("grow")?;
            }
        }

        self.state.to_distill = i64::try_from(grown.len()).unwrap_or(i64::MAX);
        for group in grown {
            let mut members = group.members.clone();
            members.sort_unstable();
            let var = variability(&self.vectors_of(&members), &group.centroid, &group.seed);
            if let Some(&did) = previous.get(&members_sha256(&members)) {
                self.state.kept += 1;
                self.update_group(did, &members, &group.centroid, &group.seed, var).await?;
                continue;
            }
            if let Some(statement) = self.confirm(&members, &group.centroid, var).await? {
                self.write_group(&members, &group.centroid, &group.seed, &statement).await?;
            }
        }
        // Nodes left alone become single distilled facts in finish(), in SQL.
        self.vectors.clear();
        Ok(())
    }

    /// Re-record a group found again with the same nodes; its statement stands.
    async fn update_group(
        &self,
        did: i64,
        members: &[i64],
        centroid: &[f64],
        seed: &[f64],
        var: Variability,
    ) -> Result<()> {
        self.tx
            .execute(
                "UPDATE distilled_facts SET representative_fact_id = $2, model_slug = $3, threshold = $4, \
                                            nodes = $5, spread = $6, drift = $7, radius = $8 \
                 WHERE id = $1",
                &[
                    &did,
                    &representative(members, &self.texts),
                    &self.model.slug,
                    &(self.params.threshold as f32),
                    &i32::try_from(members.len()).unwrap_or(i32::MAX),
                    &(var.spread as f32),
                    &(var.drift as f32),
                    &(var.radius as f32),
                ],
            )
            .await?;
        self.upsert_vector(did, centroid, seed).await?;
        self.link(did, members, centroid).await
    }

    // -- level 2: an incremental run ---------------------------------------------

    /// Re-centre the distilled facts that lost nodes (a document re-extracted or re-compared).
    async fn refresh(&mut self) -> Result<()> {
        let changed: Vec<Row> = self
            .tx
            .query(
                "SELECT df.id, df.nodes, df.model_slug IS NOT NULL, \
                        coalesce(array_agg(f.id ORDER BY f.id) FILTER (WHERE f.id IS NOT NULL), '{}') \
                 FROM distilled_facts df \
                 LEFT JOIN facts f ON f.distilled_fact_id = df.id AND f.restates_fact_id IS NULL \
                 WHERE df.anchor_key IS NULL \
                 GROUP BY df.id \
                 HAVING count(f.id) IS DISTINCT FROM df.nodes",
                &[],
            )
            .await?;
        let mut stale: Vec<i64> = Vec::new();
        for row in changed {
            let did: i64 = row.get(0);
            let grouped: bool = row.get(2);
            let members: Vec<i64> = row.get(3);
            if members.is_empty() {
                self.tx.execute("DELETE FROM distilled_facts WHERE id = $1", &[&did]).await?;
                continue;
            }
            self.load_vectors(&members).await?;
            let members: Vec<i64> = members.into_iter().filter(|m| self.vectors.contains_key(m)).collect();
            if members.is_empty() {
                continue;
            }
            stale.push(did);
            let row = self
                .tx
                .query_opt(&format!("SELECT seed::text FROM {} WHERE distilled_fact_id = $1", self.fact_table), &[&did])
                .await?;
            let centroid = mean_vector(&self.vectors_of(&members));
            let mut seed = match row.and_then(|row| row.get::<_, Option<String>>(0)) {
                Some(literal) => parse_vector(&literal),
                None => centroid.clone(),
            };
            let single = members.len() == 1;
            if single {
                seed.clone_from(&centroid);
            }
            let var = variability(&self.vectors_of(&members), &centroid, &seed);
            self.tx
                .execute(
                    "UPDATE distilled_facts SET \
                         nodes = $2, spread = $3, drift = $4, radius = $5, \
                         members_sha256 = $6, representative_fact_id = $7, \
                         statement = CASE WHEN $8 THEN $9 ELSE statement END, \
                         statement_generated = statement_generated AND NOT $8, \
                         model_slug = CASE WHEN $8 THEN NULL ELSE model_slug END, \
                         threshold = CASE WHEN $8 THEN NULL ELSE threshold END, \
                         distill_model = CASE WHEN $8 THEN NULL ELSE distill_model END \
                     WHERE id = $1",
                    &[
                        &did,
                        &i32::try_from(members.len()).unwrap_or(i32::MAX),
                        &(var.spread as f32),
                        &(var.drift as f32),
                        &(var.radius as f32),
                        &members_sha256(&members),
                        &representative(&members, &self.texts),
                        &single,
                        &self.texts[&members[0]],
                    ],
                )
                .await?;
            self.upsert_vector(did, &centroid, &seed).await?;
            if !single {
                self.link(did, &members, &centroid).await?;
            } else if grouped {
                self.tx.execute("UPDATE facts SET distilled_similarity = NULL WHERE id = $1", &[&members[0]]).await?;
            }
        }
        self.stale_elsewhere(&stale).await
    }

    async fn upsert_vector(&self, did: i64, centroid: &[f64], seed: &[f64]) -> Result<()> {
        self.tx
            .execute(
                &format!(
                    "INSERT INTO {} (distilled_fact_id, embedding, seed) VALUES ($1, {}, {}) \
                     ON CONFLICT (distilled_fact_id) DO UPDATE \
                         SET embedding = EXCLUDED.embedding, seed = EXCLUDED.seed, embedded_at = now()",
                    self.fact_table,
                    self.cast(2),
                    self.cast(3)
                ),
                &[&did, &vector_literal(&normalized(centroid)), &vector_literal(&normalized(seed))],
            )
            .await?;
        Ok(())
    }

    /// Attach each new node to the nearest distilled fact that takes it, or make it one of its own.
    async fn place(&mut self) -> Result<()> {
        // A distilled fact of one member made before its fact had a vector here is made again.
        self.tx
            .execute(
                &format!(
                    "DELETE FROM distilled_facts df \
                     WHERE df.model_slug IS NULL AND df.anchor_key IS NULL \
                       AND NOT EXISTS (SELECT 1 FROM {} fe WHERE fe.distilled_fact_id = df.id AND fe.seed IS NOT NULL) \
                       AND EXISTS (SELECT 1 FROM facts f WHERE f.id = df.representative_fact_id AND {})",
                    self.fact_table,
                    has_vector(&self.table, "f")
                ),
                &[],
            )
            .await?;
        let new: Vec<i64> = self
            .tx
            .query(
                &format!(
                    "SELECT f.id FROM facts f WHERE f.distilled_fact_id IS NULL AND f.restates_fact_id IS NULL \
                     AND {} ORDER BY f.id",
                    has_vector(&self.table, "f")
                ),
                &[],
            )
            .await?
            .iter()
            .map(|row| row.get(0))
            .collect();
        self.state.nodes = i64::try_from(new.len()).unwrap_or(i64::MAX);
        self.load_vectors(&new).await?;
        let anchored: HashSet<i64> = self.join_anchors(&new).await?.into_iter().collect();
        let candidates = format!(
            "SELECT fe.distilled_fact_id, fe.seed::text, df.representative_fact_id \
             FROM {fact_table} fe JOIN distilled_facts df ON df.id = fe.distilled_fact_id \
             WHERE df.fact_class = $1 AND fe.seed IS NOT NULL AND df.anchor_key IS NULL \
             ORDER BY fe.embedding {op} {v} LIMIT $3",
            fact_table = self.fact_table,
            op = self.op,
            v = self.cast(2)
        );
        let group_nodes = "SELECT id FROM facts WHERE distilled_fact_id = $1 AND restates_fact_id IS NULL";
        for fact_id in new {
            if anchored.contains(&fact_id) {
                self.state.scanned += 1;
                continue;
            }
            let vector = self.vectors[&fact_id].clone();
            let mut placed = false;
            let rows = self
                .tx
                .query(
                    &candidates,
                    &[&self.fact_class[&fact_id], &vector_literal(&vector), &self.params.attach_candidates],
                )
                .await?;
            for row in rows {
                let (did, seed, rep): (i64, Option<String>, Option<i64>) = (row.get(0), row.get(1), row.get(2));
                let (Some(seed), Some(rep)) = (seed, rep) else { continue };
                if self.signature(rep) != self.signature(fact_id) {
                    continue;
                }
                // The stored centroid is normalized; the group's own mean is what a node moves.
                let members: Vec<i64> =
                    self.tx.query(group_nodes, &[&did]).await?.iter().map(|row| row.get(0)).collect();
                self.load_vectors(&members).await?;
                let mut members: Vec<i64> = members.into_iter().filter(|m| self.vectors.contains_key(m)).collect();
                if members.is_empty() {
                    continue;
                }
                let seed_vector = parse_vector(&seed);
                let mean = mean_vector(&self.vectors_of(&members));
                let Some((_, moved)) = attach_ok(
                    &vector,
                    &mean,
                    &seed_vector,
                    members.len(),
                    self.params.threshold,
                    self.params.max_drift,
                    None,
                ) else {
                    continue;
                };
                members.push(fact_id);
                members.sort_unstable();
                let var = variability(&self.vectors_of(&members), &moved, &seed_vector);
                let Some(statement) = self.confirm(&members, &moved, var).await? else { continue };
                self.join(did, &members, &moved, &seed_vector, var, &statement).await?;
                self.state.attached += 1;
                placed = true;
                break;
            }
            if !placed {
                self.write_single(fact_id).await?;
            }
            self.state.scanned += 1;
            if self.state.scanned % 100 == 0 {
                self.report("attach")?;
            }
        }
        Ok(())
    }

    async fn join(
        &self,
        did: i64,
        members: &[i64],
        centroid: &[f64],
        seed: &[f64],
        var: Variability,
        statement: &Statement,
    ) -> Result<()> {
        let current = self
            .tx
            .query_one(
                "SELECT statement, statement_generated, distill_model, model_slug FROM distilled_facts WHERE id = $1",
                &[&did],
            )
            .await?;
        let (current_text, current_generated, current_model, current_slug): (
            String,
            bool,
            Option<String>,
            Option<String>,
        ) = (current.get(0), current.get(1), current.get(2), current.get(3));
        // A group the model already stated keeps its sentence unless the model restated it.
        let kept;
        let statement = if current_slug.is_some() && current_generated && !statement.generated {
            kept = Statement { text: current_text, generated: true, distill_model: current_model };
            &kept
        } else {
            statement
        };
        self.tx
            .execute(
                "UPDATE distilled_facts SET \
                     statement = $2, statement_generated = $3, distill_model = $4, \
                     representative_fact_id = $5, members_sha256 = $6, model_slug = $7, \
                     threshold = $8, nodes = $9, spread = $10, drift = $11, radius = $12 \
                 WHERE id = $1",
                &[
                    &did,
                    &statement.text,
                    &statement.generated,
                    &statement.distill_model,
                    &representative(members, &self.texts),
                    &members_sha256(members),
                    &self.model.slug,
                    &(self.params.threshold as f32),
                    &i32::try_from(members.len()).unwrap_or(i32::MAX),
                    &(var.spread as f32),
                    &(var.drift as f32),
                    &(var.radius as f32),
                ],
            )
            .await?;
        self.upsert_vector(did, centroid, seed).await?;
        self.link(did, members, centroid).await?;
        self.stale_elsewhere(&[did]).await
    }

    // -- both ------------------------------------------------------------------------

    async fn finish(&mut self) -> Result<()> {
        self.anchor_stats().await?;
        // Every representative in no group stands alone: in the single distilled fact it already
        // had (a full run keeps its id), else in a new one.
        let relink = "UPDATE facts f SET distilled_fact_id = df.id, distilled_similarity = NULL \
                      FROM distilled_facts df \
                      WHERE f.distilled_fact_id IS NULL AND f.restates_fact_id IS NULL \
                        AND df.model_slug IS NULL AND df.representative_fact_id = f.id";
        self.tx.execute(relink, &[]).await?;
        self.tx
            .execute(
                "INSERT INTO distilled_facts (fact_class, statement, representative_fact_id, members_sha256, \
                                              nodes, spread, drift, radius) \
                 SELECT f.fact_class, f.fact, f.id, sha256(convert_to(f.id::text, 'UTF8')), 1, 0, 0, 0 \
                 FROM facts f WHERE f.distilled_fact_id IS NULL AND f.restates_fact_id IS NULL",
                &[],
            )
            .await?;
        self.tx.execute(relink, &[]).await?;
        // A single fact with a vector here is a centroid later facts can join.
        self.tx
            .execute(
                &format!(
                    "INSERT INTO {fact_table} AS fe (distilled_fact_id, embedding, seed) \
                     SELECT df.id, e.embedding, e.embedding \
                     FROM distilled_facts df \
                     JOIN {table} e ON e.fact_id = df.representative_fact_id \
                     WHERE df.model_slug IS NULL \
                       AND NOT EXISTS (SELECT 1 FROM {fact_table} x WHERE x.distilled_fact_id = df.id AND x.seed IS NOT NULL) \
                     ON CONFLICT (distilled_fact_id) DO UPDATE SET embedding = EXCLUDED.embedding, seed = EXCLUDED.seed \
                     WHERE fe.seed IS NULL",
                    fact_table = self.fact_table,
                    table = self.table
                ),
                &[],
            )
            .await?;
        // A restatement backs what its representative backs.
        self.tx
            .execute(
                "UPDATE facts r \
                 SET distilled_fact_id = rep.distilled_fact_id, distilled_similarity = r.restates_similarity \
                 FROM facts rep \
                 WHERE r.restates_fact_id = rep.id AND r.distilled_fact_id IS DISTINCT FROM rep.distilled_fact_id",
                &[],
            )
            .await?;
        self.tx
            .execute(
                "DELETE FROM distilled_facts df WHERE NOT EXISTS (SELECT 1 FROM facts f WHERE f.distilled_fact_id = df.id)",
                &[],
            )
            .await?;
        self.tx
            .execute(
                "INSERT INTO fact_cluster_state (id, model_slug, params) VALUES (1, $1, $2) \
                 ON CONFLICT (id) DO UPDATE SET model_slug = EXCLUDED.model_slug, params = EXCLUDED.params, \
                                                updated_at = now()",
                &[&self.model.slug, &self.params.corpus_key()],
            )
            .await?;
        Ok(())
    }

    async fn needs_full_run(&self) -> Result<bool> {
        let row = self.tx.query_opt("SELECT model_slug, params FROM fact_cluster_state WHERE id = 1", &[]).await?;
        Ok(match row {
            None => true,
            Some(row) => {
                let (slug, params): (String, String) = (row.get(0), row.get(1));
                slug != self.model.slug || params != self.params.corpus_key()
            }
        })
    }
}

/// The pass as [`grow_group`] sees it while growing groups of one class.
struct Grower<'p, 'c, 'r> {
    pass: &'p mut Pass<'c, 'r>,
    fact_class: &'p str,
}

impl GrowthHost for Grower<'_, '_, '_> {
    async fn knn(&mut self, centroid: &[f64], members: usize) -> Result<Vec<i64>> {
        let k = i64::try_from(members).unwrap_or(i64::MAX).saturating_add(self.pass.params.growth_neighbors);
        self.pass.knn_nodes(centroid, self.fact_class, k).await
    }

    fn vector(&self, fact_id: i64) -> &[f64] {
        &self.pass.vectors[&fact_id]
    }

    fn signature(&mut self, fact_id: i64) -> ClaimSignature {
        self.pass.signature(fact_id)
    }
}

fn neighbor_sql(table: &str, op: &str) -> String {
    format!(
        "SELECT src.fact_id AS a, nb.fact_id AS b, nb.similarity \
         FROM (\
             SELECT e.fact_id, f.fact_class, e.embedding \
             FROM {table} e JOIN facts f ON f.id = e.fact_id \
             WHERE e.fact_id = ANY($1)) src \
         CROSS JOIN LATERAL (\
             SELECT e2.fact_id, 1 - (e2.embedding <=> src.embedding) AS similarity \
             FROM {table} e2 JOIN facts f2 ON f2.id = e2.fact_id \
             WHERE f2.fact_class = src.fact_class AND e2.fact_id <> src.fact_id AND f2.restates_fact_id IS NULL \
               AND {inferred} \
             ORDER BY e2.embedding {op} src.embedding \
             LIMIT $2) nb",
        inferred = inferred("f2")
    )
}

fn pairwise_sql(table: &str) -> String {
    format!(
        "SELECT ea.fact_id AS a, eb.fact_id AS b, 1 - (ea.embedding <=> eb.embedding) AS similarity \
         FROM {table} ea, {table} eb \
         WHERE ea.fact_id = ANY($1) AND eb.fact_id = ANY($1) AND ea.fact_id < eb.fact_id"
    )
}

/// How a run is asked for.
pub struct ClusterRun<'r> {
    pub params: ClusterParams,
    /// Regroup the corpus rather than placing what is new (a changed model or parameter does too).
    pub full: bool,
    pub distiller: Option<Arc<dyn Distill>>,
    pub report_to: Option<Reporter<'r>>,
    /// `database.hnsw_ef_search`, set for the run.
    pub ef_search: i64,
}

/// Dedup the potential facts in two levels and link each to a distilled fact; see the module
/// documentation (`cluster_facts`).
///
/// Groups come from `model`'s vectors. The run is full when asked or when the model or a grouping
/// parameter changed since the last run, incremental otherwise. Without a distiller every group is
/// kept and stated by its representative's text. Commits once, at the end; potential facts are only
/// re-linked, never changed.
///
/// # Errors
///
/// [`ServiceError::InvalidArgument`] for a binary-quantized model, whose index does not serve the
/// neighbour queries; the database otherwise.
pub async fn cluster_facts(
    client: &mut Client,
    model: &EmbeddingModel,
    run: ClusterRun<'_>,
) -> Result<ClusterProgress> {
    if model.index_kind == "hnsw_bq" {
        return Err(ServiceError::invalid(format!(
            "{} is binary-quantized; cluster facts under a model with an HNSW index",
            model.slug
        )));
    }
    let fact_table = ensure_fact_table(client, model).await?;
    let table = potential_fact_table_name(assert_safe_table(&model.table_name)?)?;
    let coltype = model.plan().column_type();
    let op = if model.index_kind == "hnsw_bq" { "<=>" } else { distance_operator(&model.distance)? };
    let pass = Pass {
        tx: client.transaction().await?,
        model: model.clone(),
        params: run.params,
        distiller: run.distiller,
        report_to: run.report_to,
        state: ClusterProgress::default(),
        table,
        fact_table,
        coltype,
        op,
        texts: HashMap::new(),
        fact_class: HashMap::new(),
        corpus_class: HashMap::new(),
        document: HashMap::new(),
        vectors: HashMap::new(),
        signatures: HashMap::new(),
        anchor_classes: HashSet::new(),
    };
    let mut state = run_pass(pass, run.full, run.ef_search).await?;
    let totals = client
        .query_one(
            "SELECT count(*) FILTER (WHERE df.model_slug IS NOT NULL AND n > 1), \
                    CAST(coalesce(sum(n) FILTER (WHERE df.model_slug IS NOT NULL AND n > 1), 0) AS bigint), \
                    count(*) \
             FROM distilled_facts df \
             JOIN (SELECT distilled_fact_id, count(*) AS n FROM facts GROUP BY distilled_fact_id) m \
               ON m.distilled_fact_id = df.id",
            &[],
        )
        .await?;
    state.clusters = totals.get(0);
    state.clustered_facts = totals.get(1);
    state.distilled_facts = totals.get(2);
    "done".clone_into(&mut state.phase);
    Ok(state)
}

/// The pass over its transaction, committed at the end; the state as it stands then.
async fn run_pass(mut pass: Pass<'_, '_>, full: bool, ef_search: i64) -> Result<ClusterProgress> {
    pass.state.full = full || pass.needs_full_run().await?;
    pass.load_facts().await?;
    pass.tx.batch_execute(&format!("SET LOCAL hnsw.ef_search = {ef_search}")).await?;
    iterative_scan(&mut pass.tx).await?;
    let full = pass.state.full;
    pass.restate_documents(full).await?;
    if full {
        pass.regroup().await?;
    } else {
        pass.anchor().await?;
        pass.refresh().await?;
        pass.place().await?;
    }
    pass.finish().await?;
    let Pass { tx, state, .. } = pass;
    tx.commit().await?;
    Ok(state)
}

/// Let a filtered HNSW scan keep going until it finds enough fact rows (pgvector 0.8+); older
/// pgvector has no such setting, and recall is then `ef_search`'s.
async fn iterative_scan(tx: &mut Transaction<'_>) -> Result<()> {
    let savepoint = tx.savepoint("iterative_scan").await?;
    match savepoint.batch_execute("SET LOCAL hnsw.iterative_scan = relaxed_order").await {
        Ok(()) => savepoint.commit().await?,
        Err(_) => savepoint.rollback().await?,
    }
    Ok(())
}

#[cfg(test)]
#[allow(clippy::float_cmp)]
mod tests {
    use super::*;

    fn texts(pairs: &[(i64, &str)]) -> HashMap<i64, String> {
        pairs.iter().map(|(i, t)| (*i, (*t).to_owned())).collect()
    }

    #[test]
    fn the_guard_reads_numbers_time_words_and_negation() {
        let a = claim_signature("Acme has 1,000 employees as of Tuesday.");
        assert_eq!(a.numbers, ["1000".to_owned()].into_iter().collect());
        assert_eq!(a.temporal, ["tuesday".to_owned()].into_iter().collect());
        assert!(!a.negated);
        assert!(claim_signature("The meeting isn't on Tuesday").negated);
        assert!(claim_signature("No meeting today").negated);
        assert_ne!(claim_signature("42 employees"), claim_signature("45 employees"));
        assert_eq!(claim_signature("Rate 3.5/10 at 12:30").numbers, ["3.5/10", "12:30"].map(str::to_owned).into());
    }

    #[test]
    fn components_and_linkage_follow_python() {
        let groups = connected_groups(&[1, 2, 3, 4, 5], [(1, 2), (2, 3), (4, 5), (9, 1)]);
        assert_eq!(groups, vec![vec![1, 2, 3], vec![4, 5]]);
        let mut similarity = Similarity::new();
        similarity.insert((1, 2), 0.95);
        similarity.insert((2, 3), 0.9);
        similarity.insert((1, 3), 0.7);
        similarity.insert((4, 5), 0.99);
        assert_eq!(average_linkage(&[3, 2, 1], &similarity, 0.8), vec![vec![1, 2, 3]]);
        assert_eq!(average_linkage(&[1, 2, 3], &similarity, 0.85), vec![vec![1, 2]]);
        let texts = texts(&[(1, "Acme has 42 staff"), (2, "Acme employs 42 people"), (3, "Acme has 45 staff")]);
        similarity.insert((1, 3), 0.99);
        similarity.insert((2, 3), 0.99);
        assert_eq!(guarded_clusters(&[1, 2, 3], &texts, &similarity, 0.9), vec![vec![1, 2]]);
        assert_eq!(representative(&[1, 2, 3], &texts), 2);
        assert_eq!(members_sha256(&[3, 1, 2]), sha256::digest(b"1,2,3").to_vec());
    }

    #[test]
    fn restatements_merge_identical_texts_before_linking() {
        let texts = texts(&[
            (1, "Ada wrote it."),
            (2, "ada wrote it"),
            (3, "Grace wrote the compiler."),
            (4, "Grace wrote the compiler"),
        ]);
        let mut similarity = Similarity::new();
        similarity.insert((1, 3), 0.5);
        similarity.insert((3, 4), 0.99);
        let restates = document_restatements(&[1, 2, 3, 4], &texts, &similarity, 0.9);
        assert_eq!(restates.get(&2), Some(&(1, 1.0)));
        assert_eq!(restates.get(&4), Some(&(3, 1.0)));
        assert_eq!(restates.len(), 2);
        assert_eq!(normalize_fact("  Straße   IST   groß!! "), "strasse ist gross");
    }

    #[test]
    fn python_g_formatting() {
        assert_eq!(py_g(0.9, 6), "0.9");
        assert_eq!(py_g(0.92, 6), "0.92");
        assert_eq!(py_g(1.0, 6), "1");
        assert_eq!(py_g(0.05, 6), "0.05");
        assert_eq!(py_g(0.123_456_789, 7), "0.1234568");
        assert_eq!(py_g(123_456_789.0, 7), "1.234568e+08");
        assert_eq!(py_g(0.000_012_3, 7), "1.23e-05");
        assert_eq!(py_g(-0.5, 7), "-0.5");
        assert_eq!(py_g(0.0, 7), "0");
        assert_eq!(vector_literal(&[0.1, 0.25, -1.0]), "[0.1,0.25,-1]");
        assert_eq!(parse_vector("[0.1,0.25,-1]"), vec![0.1, 0.25, -1.0]);
        assert!(parse_vector("[]").is_empty());
    }

    #[test]
    fn vector_math_and_the_tight_cap() {
        assert!((cosine(&[1.0, 0.0], &[1.0, 0.0]) - 1.0).abs() < 1e-12);
        assert_eq!(cosine(&[0.0, 0.0], &[1.0, 0.0]), 0.0);
        assert_eq!(mean_vector(&[&[1.0, 2.0], &[3.0, 4.0]]), vec![2.0, 3.0]);
        assert_eq!(added(&[2.0, 3.0], 2, &[5.0, 6.0]), vec![3.0, 4.0]);
        let n = normalized(&[3.0, 4.0]);
        assert!((n[0] - 0.6).abs() < 1e-12 && (n[1] - 0.8).abs() < 1e-12);
        let r2 = tight_radius(2, 0.97);
        assert!((r2 - 0.007_5).abs() < 0.000_2, "{r2}");
        assert!(tight_radius(100, 0.97) > 0.014);
        assert!(!needs_model(0.005, 2, 0.97));
        assert!(needs_model(0.02, 2, 0.97));
        assert!(needs_model(0.0, 2, 1.0));
        let var = variability(&[&[1.0, 0.0], &[0.0, 1.0]], &[0.5, 0.5], &[0.5, 0.5]);
        assert!((var.radius - (1.0 - 0.5_f64.sqrt())).abs() < 1e-12);
        assert!(var.drift < 1e-12);
        assert!(attach_ok(&[1.0, 0.0], &[1.0, 0.0], &[1.0, 0.0], 1, 0.9, 0.05, None).is_some());
        assert!(attach_ok(&[0.0, 1.0], &[1.0, 0.0], &[1.0, 0.0], 1, 0.9, 0.05, None).is_none());
    }

    #[test]
    fn the_distill_reply_is_parsed_leniently() {
        assert_eq!(
            parse_distill_reply("YES\nAcme was founded in 1998."),
            (true, Some("Acme was founded in 1998.".into()))
        );
        assert_eq!(
            parse_distill_reply("**YES**: Acme was founded in 1998."),
            (true, Some("Acme was founded in 1998.".into()))
        );
        assert_eq!(parse_distill_reply("Yes.\nStatement: \"Ada wrote it.\""), (true, Some("Ada wrote it.".into())));
        assert_eq!(parse_distill_reply("YES"), (true, None));
        assert_eq!(parse_distill_reply("No, they differ."), (false, None));
        assert_eq!(parse_distill_reply(""), (false, None));
        assert!(distill_prompt(&["a".into(), "b".into()]).starts_with("Statements:\n1. a\n2. b\n\nDo all"));
    }

    #[test]
    fn keys_follow_python_formatting() {
        let params = ClusterParams {
            threshold: 0.9,
            neighbors: 10,
            seed_threshold: 0.95,
            max_drift: 0.05,
            tight_similarity: 0.97,
            growth_neighbors: 50,
            growth_rounds: 4,
            attach_candidates: 5,
            distill_facts: 20,
            max_pairwise: 300,
            restate_threshold: Some(0.92),
        };
        assert_eq!(params.document_key("bge"), "bge;t=0.92");
        assert_eq!(params.corpus_key(), "t=0.9;s=0.95;d=0.05;g=50;r=4");
        let config = Config::defaults();
        let defaults = ClusterParams::from_config(&config, None, None).unwrap();
        assert_eq!(defaults, params);
        let error = ClusterParams::from_config(&config, Some(1.5), None).unwrap_err();
        assert_eq!(error.message(), "threshold must be above 0 and at most 1, not 1.5");
        let error = ClusterParams::from_config(&config, None, Some(-1)).unwrap_err();
        assert_eq!(error.message(), "neighbors must be at least 1, not -1");
        assert_eq!(ClusterParams::from_config(&config, Some(0.8), Some(3)).unwrap().seed_threshold, 0.95);
    }

    struct Memory {
        vectors: HashMap<i64, Vector>,
        texts: HashMap<i64, String>,
    }

    impl GrowthHost for Memory {
        async fn knn(&mut self, centroid: &[f64], _members: usize) -> Result<Vec<i64>> {
            let mut ids: Vec<i64> = self.vectors.keys().copied().collect();
            ids.sort_by(|a, b| {
                cosine(&self.vectors[b], centroid)
                    .partial_cmp(&cosine(&self.vectors[a], centroid))
                    .unwrap()
                    .then(a.cmp(b))
            });
            Ok(ids)
        }

        fn vector(&self, fact_id: i64) -> &[f64] {
            &self.vectors[&fact_id]
        }

        fn signature(&mut self, fact_id: i64) -> ClaimSignature {
            claim_signature(&self.texts[&fact_id])
        }
    }

    #[test]
    fn groups_grow_by_nearest_neighbours_and_stop_at_the_first_refusal() {
        let mut host = Memory {
            vectors: [
                (1, vec![1.0, 0.0, 0.0]),
                (2, vec![0.99, 0.1, 0.0]),
                (3, vec![0.98, 0.15, 0.05]),
                (4, vec![0.0, 1.0, 0.0]),
                (5, vec![0.97, 0.2, 0.0]),
            ]
            .into_iter()
            .collect(),
            texts: [(1, "a"), (2, "b"), (3, "c"), (4, "d"), (5, "no e")]
                .into_iter()
                .map(|(i, t)| (i, t.to_owned()))
                .collect(),
        };
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
        let grown = runtime.block_on(grow_group(&mut host, &[1], &HashSet::new(), 0.9, 0.1, 4)).unwrap();
        // 5 is near but negated; 4 is far and stops the walk.
        assert_eq!(grown.members, vec![1, 2, 3]);
        assert_eq!(grown.seed, vec![1.0, 0.0, 0.0]);
        let taken: HashSet<i64> = [2].into_iter().collect();
        let grown = runtime.block_on(grow_group(&mut host, &[1], &taken, 0.9, 0.1, 4)).unwrap();
        assert_eq!(grown.members, vec![1, 3]);
    }

    #[test]
    fn progress_and_summary_messages() {
        let state = ClusterProgress { phase: "neighbors".into(), scanned: 1200, nodes: 3000, ..Default::default() };
        assert_eq!(state.message(), "finding neighbours: 1,200/3,000 facts");
        assert_eq!(ClusterProgress { phase: "done".into(), ..Default::default() }.message(), "");
        let summary = ClusterSummary {
            state: ClusterProgress {
                facts: 1200,
                distilled_facts: 900,
                clusters: 100,
                clustered_facts: 400,
                restatements: 30,
                nodes: 50,
                attached: 20,
                dissolved: 2,
                withheld: 1,
                unembedded: 5,
                ..Default::default()
            },
            ..Default::default()
        };
        assert_eq!(
            summary.message(),
            "1,200 potential facts distilled into 900; 100 of those group 400 restatements (30 restate another fact \
             of their own document); 20 of 50 new facts joined a distilled fact, 2 rejected by the model, 1 left \
             ungrouped (communications stay on this machine); 5 facts have no vector yet (run the backfill)"
        );
    }
}
