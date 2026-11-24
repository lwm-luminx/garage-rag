//! The condition a caller's reads carry (`docs/plans/access-policies.md`, "What decides"): SQL over
//! the documents (`d`) and their sources (`s`).
//!
//! The policy (`crate::policy`) answers with boundaries; for each one:
//!
//! 1. any DENY condition that matches the document, or a content rule that has not been evaluated
//!    for its current content, hides it;
//! 2. otherwise, under a DENY default, an ALLOW condition that matches admits it;
//! 3. otherwise the boundary's default decides.
//!
//! A document must pass every boundary: the built-in policy gives a door's grant one for its door
//! and one for itself.

use garage_access::{SqlFilter, SqlValue};

use crate::policy::{Condition, Decision, PolicyError};
use crate::rules::{Effect, Matcher};
use crate::store::StoredRule;

/// The filter's SQL and its parameters, numbered as they are added.
#[derive(Default)]
struct Sql {
    params: Vec<SqlValue>,
}

impl Sql {
    fn bind(&mut self, value: SqlValue) -> String {
        self.params.push(value);
        format!("${}", self.params.len())
    }

    /// A metadata matcher, inline; never NULL, so `NOT` of it is safe on a document without a
    /// source row.
    fn metadata(&mut self, matcher: &Matcher) -> String {
        let condition = match matcher {
            Matcher::Source(slugs) => {
                format!("s.slug = ANY({}::text[])", self.bind(SqlValue::TextArray(slugs.clone())))
            }
            Matcher::CorpusClass(classes) => {
                format!("d.corpus_class::text = ANY({}::text[])", self.bind(SqlValue::TextArray(classes.clone())))
            }
            Matcher::TrustTier(tiers) => {
                format!("d.trust_tier::text = ANY({}::text[])", self.bind(SqlValue::TextArray(tiers.clone())))
            }
            Matcher::Author(author) => {
                // As garage-rag's own `author` search filter reads it.
                let p = self.bind(SqlValue::Text(format!("%{}%", like_escape(author))));
                format!(
                    "EXISTS (SELECT 1 FROM document_authors da JOIN authors a ON a.id = da.author_id \
                     WHERE da.document_id = d.id AND (a.display_name ILIKE {p}::text OR EXISTS \
                     (SELECT 1 FROM author_identities ai WHERE ai.author_id = a.id AND ai.value ILIKE {p}::text)))"
                )
            }
            Matcher::Path(glob) => format!("d.uri LIKE {}::text", self.bind(SqlValue::Text(glob_to_like(glob)))),
            Matcher::Regex { .. } | Matcher::Term(_) => {
                unreachable!("content matchers are evaluated, not inlined")
            }
        };
        format!("COALESCE(({condition}), false)")
    }

    /// Every rule in `rules` has a current evaluation for the document that says it does not match.
    fn none_match(&mut self, rules: &[&StoredRule]) -> String {
        let (ids, versions) = self.rules(rules);
        format!(
            "NOT EXISTS (SELECT 1 FROM unnest({ids}::bigint[], {versions}::text[]) AS r(id, version) \
             WHERE NOT EXISTS (SELECT 1 FROM access_evaluations e WHERE e.rule_id = r.id AND e.version = r.version \
             AND e.document_id = d.id AND e.content_sha256 = d.content_sha256 AND NOT e.matched))"
        )
    }

    /// Some rule in `rules` has a current evaluation for the document that says it matches.
    fn any_match(&mut self, rules: &[&StoredRule]) -> String {
        let (ids, versions) = self.rules(rules);
        format!(
            "EXISTS (SELECT 1 FROM unnest({ids}::bigint[], {versions}::text[]) AS r(id, version) \
             JOIN access_evaluations e ON e.rule_id = r.id AND e.version = r.version \
             WHERE e.document_id = d.id AND e.content_sha256 = d.content_sha256 AND e.matched)"
        )
    }

    fn rules(&mut self, rules: &[&StoredRule]) -> (String, String) {
        let ids = self.bind(SqlValue::IntArray(rules.iter().map(|r| r.id).collect()));
        let versions = self.bind(SqlValue::TextArray(rules.iter().map(|r| r.version.clone()).collect()));
        (ids, versions)
    }
}

/// `%` and `_` (and the escape) taken literally in a LIKE pattern.
fn like_escape(text: &str) -> String {
    text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

/// A path glob as a LIKE pattern: `*` any run, `?` one character, the rest literal. A leading `~/`
/// is the home folder, as garage-rag shows locations.
pub fn glob_to_like(glob: &str) -> String {
    let expanded = match (glob.strip_prefix("~/"), std::env::var("HOME")) {
        (Some(rest), Ok(home)) if !home.is_empty() => {
            format!("{}/{rest}", home.trim_end_matches('/'))
        }
        _ => glob.to_owned(),
    };
    like_escape(&expanded).replace('*', "%").replace('?', "_")
}

/// A boundary of a [`Decision`] with its conditions resolved against the stored rules, split by
/// whether they read content.
pub struct Resolved<'a> {
    default: Effect,
    deny_content: Vec<&'a StoredRule>,
    deny_metadata: Vec<Matcher>,
    allow_content: Vec<&'a StoredRule>,
    allow_metadata: Vec<Matcher>,
}

/// The decision's boundaries over `rules`. A condition naming a disabled rule matches nothing, so it
/// is dropped, as the rule's own targets would be.
///
/// # Errors
///
/// A condition names no stored rule: the policy and the rules have parted, and the read fails rather
/// than guess.
pub fn resolve<'a>(decision: &Decision, rules: &'a [StoredRule]) -> Result<Vec<Resolved<'a>>, PolicyError> {
    let mut out = Vec::with_capacity(decision.boundaries.len());
    for boundary in &decision.boundaries {
        let mut resolved = Resolved {
            default: boundary.default,
            deny_content: vec![],
            deny_metadata: vec![],
            allow_content: vec![],
            allow_metadata: vec![],
        };
        for (conditions, deny) in [(&boundary.deny, true), (&boundary.allow, false)] {
            for condition in conditions {
                let (content, metadata) = if deny {
                    (&mut resolved.deny_content, &mut resolved.deny_metadata)
                } else {
                    (&mut resolved.allow_content, &mut resolved.allow_metadata)
                };
                match condition {
                    Condition::Inline(matcher) => metadata.push(matcher.clone()),
                    Condition::Rule(name) => {
                        let stored = rules.iter().find(|r| &r.rule.name == name).ok_or_else(|| {
                            PolicyError(format!("the policy names rule {name:?}, which does not exist"))
                        })?;
                        if !stored.rule.enabled {
                            continue;
                        }
                        if stored.rule.matcher.reads_content() {
                            if !content.iter().any(|r| r.id == stored.id) {
                                content.push(stored);
                            }
                        } else {
                            metadata.push(stored.rule.matcher.clone());
                        }
                    }
                }
            }
        }
        out.push(resolved);
    }
    Ok(out)
}

/// The content rules that decide anything for these boundaries: the ones worth evaluating before the
/// read. An ALLOW matters only under a DENY default.
pub fn content_rules<'a>(boundaries: &[Resolved<'a>]) -> Vec<&'a StoredRule> {
    let mut out: Vec<&StoredRule> = Vec::new();
    for boundary in boundaries {
        out.extend(&boundary.deny_content);
        if boundary.default == Effect::Deny {
            out.extend(&boundary.allow_content);
        }
    }
    out.sort_by_key(|r| r.id);
    out.dedup_by_key(|r| r.id);
    out
}

/// The condition for these boundaries, or `None` when none restricts anything, so the read is
/// garage-rag's own.
pub fn build(boundaries: &[Resolved<'_>]) -> Option<SqlFilter> {
    let mut sql = Sql::default();
    let mut parts: Vec<String> = Vec::new();
    for boundary in boundaries {
        if !boundary.deny_content.is_empty() {
            parts.push(sql.none_match(&boundary.deny_content));
        }
        for matcher in &boundary.deny_metadata {
            let matched = sql.metadata(matcher);
            parts.push(format!("NOT {matched}"));
        }
        if boundary.default == Effect::Deny {
            let mut admit: Vec<String> = Vec::new();
            if !boundary.allow_content.is_empty() {
                admit.push(sql.any_match(&boundary.allow_content));
            }
            for matcher in &boundary.allow_metadata {
                admit.push(sql.metadata(matcher));
            }
            parts.push(if admit.is_empty() { "FALSE".to_owned() } else { format!("({})", admit.join(" OR ")) });
        }
    }
    if parts.is_empty() {
        return None;
    }
    Some(SqlFilter::new(parts.join(" AND "), sql.params))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::policy::{Policy, data};
    use crate::rules::Rule;

    #[allow(clippy::needless_pass_by_value)] // json! literals
    fn stored(id: i64, rule: serde_json::Value) -> StoredRule {
        StoredRule { id, version: format!("v{id}"), rule: Rule::from_json(&rule).unwrap() }
    }

    fn targets(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| (*n).to_owned()).collect()
    }

    /// The built-in policy's boundaries for `targets`, resolved.
    fn r1<'a>(rules: &'a [StoredRule], defaults: &[(String, Effect)], targets: &[String]) -> Vec<Resolved<'a>> {
        let input = serde_json::json!({"caller": {"kind": "mcp"}, "targets": targets});
        let decision = Policy::builtin().decide(&input, &data(rules, defaults)).unwrap();
        resolve(&decision, rules).unwrap()
    }

    fn build_r1(rules: &[StoredRule], defaults: &[(String, Effect)], targets: &[String]) -> Option<SqlFilter> {
        build(&r1(rules, defaults, targets))
    }

    fn content_r1(rules: &[StoredRule], defaults: &[(String, Effect)], targets: &[String]) -> usize {
        content_rules(&r1(rules, defaults, targets)).len()
    }

    #[test]
    fn no_rules_and_allow_defaults_add_nothing() {
        assert_eq!(build_r1(&[], &[], &targets(&["mcp:r1"])), None);
        let rules = [stored(1, json!({"name": "a", "effect": "deny", "targets": ["door:*"], "match": {"term": "x"}}))];
        assert_eq!(build_r1(&rules, &[], &targets(&["mcp:r1"])), None);
    }

    #[test]
    fn a_deny_rule_hides_matches_and_pending_documents() {
        let rules = [
            stored(1, json!({"name": "keys", "effect": "deny", "targets": ["*"], "match": {"regex": "PRIVATE KEY"}})),
            stored(
                2,
                json!({"name": "mail", "effect": "deny", "targets": ["mcp:*"], "match": {"corpus_class": "communication"}}),
            ),
            stored(
                3,
                json!({"name": "off", "effect": "deny", "targets": ["*"], "match": {"term": "x"}, "enabled": false}),
            ),
        ];
        let filter = build_r1(&rules, &[], &targets(&["mcp:r1"])).unwrap();
        assert!(filter.sql.starts_with("NOT EXISTS (SELECT 1 FROM unnest($1::bigint[], $2::text[])"), "{}", filter.sql);
        assert!(filter.sql.contains("AND NOT COALESCE((d.corpus_class::text = ANY($3::text[])), false)"));
        assert_eq!(
            filter.params,
            [
                SqlValue::IntArray(vec![1]),
                SqlValue::TextArray(vec!["v1".into()]),
                SqlValue::TextArray(vec!["communication".into()])
            ]
        );
        assert!(filter.render(0).is_ok());
        assert_eq!(content_r1(&rules, &[], &targets(&["mcp:r1"])), 1);
    }

    #[test]
    fn under_a_deny_default_only_allowed_documents_are_seen() {
        let rules = [
            stored(1, json!({"name": "work", "effect": "allow", "targets": ["door:a"], "match": {"source": ["work"]}})),
            stored(2, json!({"name": "falcon", "effect": "allow", "targets": ["door:a"], "match": {"term": "falcon"}})),
        ];
        let defaults = vec![("door:*".to_owned(), Effect::Deny)];
        let filter = build_r1(&rules, &defaults, &targets(&["door:a"])).unwrap();
        assert!(filter.sql.starts_with("(EXISTS (SELECT 1 FROM unnest($1::bigint[], $2::text[])"), "{}", filter.sql);
        assert!(filter.sql.ends_with(" OR COALESCE((s.slug = ANY($3::text[])), false))"));
        // With no ALLOW, a DENY default sees nothing; a grant is held to its door too.
        let none = build_r1(&[], &defaults, &targets(&["door:b", "door:b/g"])).unwrap();
        assert_eq!(none.sql, "FALSE AND FALSE");
        assert_eq!(content_r1(&rules, &defaults, &targets(&["door:a"])), 1);
        assert!(content_r1(&rules, &[], &targets(&["door:a"])) == 0);
    }

    #[test]
    fn globs_and_authors_are_taken_literally_but_for_their_wildcards() {
        assert_eq!(glob_to_like("/Work/*_notes?.md"), "/Work/%\\_notes_.md");
        let rules = [stored(1, json!({"name": "a", "effect": "deny", "targets": ["*"], "match": {"author": "50%"}}))];
        let filter = build_r1(&rules, &[], &targets(&["app"])).unwrap();
        assert_eq!(filter.params, [SqlValue::Text("%50\\%%".into())]);
    }
}
