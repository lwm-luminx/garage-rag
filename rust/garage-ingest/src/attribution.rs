//! Attribution, ported from `attribute/resolver.py`, `attribute/pathrules.py` and the path helpers of
//! `attribute/git.py`: who wrote a file and how much it is trusted, from (strongest first) git
//! history, a message's senders, embedded metadata, the path, and the source's default. Every
//! decision records the evidence that produced it, worded as Python words it.
//!
//! Reading a repository's history is the host's: [`GitHistory`] hands over what one pass over a
//! repository learned (Python's `RepoAttribution`), and the rest is decided here.

use std::collections::{BTreeMap, HashSet};
use std::path::{Component, Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::fnmatch::fnmatch;
use crate::parseaddr::parseaddr;

/// How much a document is trusted (`db.models.TrustTier`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrustTier {
    /// The owner wrote it.
    Authored,
    /// The owner collected it.
    Reference,
    /// Somebody sent it to the owner.
    Received,
}

impl TrustTier {
    /// The value Python and the database use.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Authored => "authored",
            Self::Reference => "reference",
            Self::Received => "received",
        }
    }

    /// The tier a value names.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "authored" => Some(Self::Authored),
            "reference" => Some(Self::Reference),
            "received" => Some(Self::Received),
            _ => None,
        }
    }
}

/// An author's part in a document (`db.models.AuthorRole`), the two attribution assigns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthorRole {
    /// The main author.
    Author,
    /// Another contributor.
    Committer,
}

impl AuthorRole {
    /// The value Python and the database use.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Author => "author",
            Self::Committer => "committer",
        }
    }
}

/// A glob over a source-relative path, the trust it implies, and the label recorded with it.
pub struct PathRule {
    /// `fnmatch` pattern; `*` crosses `/`.
    pub pattern: &'static str,
    /// What a match implies.
    pub trust: TrustTier,
    /// The evidence recorded for a match.
    pub label: &'static str,
}

/// Vendored dependency directories: third-party code wherever found (`VENDOR_MARKERS`).
pub const VENDOR_MARKERS: &[&str] = &[
    "node_modules",
    "vendor",
    "third_party",
    "3rd_party",
    "thirdparty",
    "external",
    "externals",
    "deps",
    "dependencies",
    "Pods",
    "Carthage",
    "site-packages",
    "bower_components",
    "submodules",
    "subprojects",
];

const fn rule(pattern: &'static str, trust: TrustTier, label: &'static str) -> PathRule {
    PathRule { pattern, trust, label }
}

/// `DEFAULT_RULES`, in order: the first match wins.
pub const DEFAULT_RULES: &[PathRule] = &[
    rule("Reference/*", TrustTier::Reference, "path:Reference"),
    rule("Documents/Paper/Reference/*", TrustTier::Reference, "path:Paper/Reference"),
    rule("Documents/Reference/*", TrustTier::Reference, "path:Documents/Reference"),
    rule("**/Army Field Manuals/*", TrustTier::Reference, "path:field-manuals"),
    rule("**/Documentation/*", TrustTier::Reference, "path:Documentation"),
    rule("**/Datasheets/*", TrustTier::Reference, "path:Datasheets"),
    rule("**/Manuals/*", TrustTier::Reference, "path:Manuals"),
    rule("**/Books/*", TrustTier::Reference, "path:Books"),
    rule("**/Papers/*", TrustTier::Reference, "path:Papers"),
    rule("**/Specs/*", TrustTier::Reference, "path:Specs"),
    rule("**/RFCs/*", TrustTier::Reference, "path:RFCs"),
    rule("Personal/*", TrustTier::Authored, "path:Personal"),
    rule("Projects/*", TrustTier::Authored, "path:Projects"),
    rule("Documents/Research/*", TrustTier::Authored, "path:Documents/Research"),
    rule("Documents/Paper/*", TrustTier::Authored, "path:Documents/Paper"),
    rule("Notes/*", TrustTier::Authored, "path:Notes"),
];

const REFERENCE_COMPONENTS: &[&str] = &["reference", "references", "papers", "manuals", "datasheets", "books"];

/// `Path.parts` as strings: the root (`/`) first, then each name.
fn parts(path: &Path) -> Vec<String> {
    path.components()
        .filter_map(|component| match component {
            Component::RootDir => Some("/".to_owned()),
            Component::Prefix(prefix) => Some(prefix.as_os_str().to_string_lossy().into_owned()),
            Component::Normal(name) => Some(name.to_string_lossy().into_owned()),
            Component::ParentDir => Some("..".to_owned()),
            Component::CurDir => None,
        })
        .collect()
}

/// `Path.resolve()` (not strict): the longest existing prefix with its links followed, then the rest
/// normalized lexically. Relative paths are taken from the working directory.
#[must_use]
pub fn resolve_path(path: &Path) -> PathBuf {
    let absolute =
        if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir().unwrap_or_default().join(path) };
    let mut resolved = PathBuf::new();
    let mut remaining = absolute.components();
    while let Some(component) = remaining.next() {
        match component {
            Component::Prefix(_) | Component::RootDir => resolved.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                resolved.pop();
            }
            Component::Normal(name) => {
                let candidate = resolved.join(name);
                if let Ok(real) = std::fs::canonicalize(&candidate) {
                    resolved = real;
                } else {
                    resolved = candidate;
                    for rest in remaining.by_ref() {
                        match rest {
                            Component::ParentDir => {
                                resolved.pop();
                            }
                            Component::Normal(name) => resolved.push(name),
                            _ => {}
                        }
                    }
                    break;
                }
            }
        }
    }
    resolved
}

fn posix(path: &Path) -> String {
    let joined = parts(path).join("/");
    if joined.is_empty() { ".".to_owned() } else { joined }
}

/// `relative_posix`: `path` relative to `root`, both resolved, in the form git reports; `None` when
/// it is outside.
#[must_use]
pub fn relative_posix(root: &Path, path: &Path) -> Option<String> {
    resolve_path(path).strip_prefix(resolve_path(root)).ok().map(posix)
}

/// `relative_to_root`: the source-relative POSIX path, or the bare name when outside the root.
#[must_use]
pub fn relative_to_root(root: &Path, path: &Path) -> String {
    relative_posix(root, path)
        .unwrap_or_else(|| path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default())
}

/// `is_vendored`: whether any part of the path names a vendored dependency tree.
#[must_use]
pub fn is_vendored(path: &Path) -> bool {
    parts(path).iter().any(|part| VENDOR_MARKERS.contains(&part.as_str()))
}

/// `classify_path`: the trust the path implies, with the label of the rule that decided it.
#[must_use]
pub fn classify_path(path: &Path, root: &Path, default: TrustTier) -> (TrustTier, String) {
    if is_vendored(path) {
        return (TrustTier::Reference, "path:vendored".to_owned());
    }
    let relative = relative_to_root(root, path);
    if let Some(rule) = DEFAULT_RULES.iter().find(|rule| fnmatch(&relative, rule.pattern)) {
        return (rule.trust, rule.label.to_owned());
    }
    let lowered: HashSet<String> = parts(path).iter().map(|part| part.to_lowercase()).collect();
    if let Some(marker) = REFERENCE_COMPONENTS.iter().find(|marker| lowered.contains(**marker)) {
        return (TrustTier::Reference, format!("path:component:{marker}"));
    }
    (default, "path:default".to_owned())
}

/// `find_repo_root`: the nearest enclosing directory holding `.git`, starting at `path` itself when
/// it is a directory.
#[must_use]
pub fn find_repo_root(path: &Path) -> Option<PathBuf> {
    let start = if path.is_dir() { path } else { path.parent()? };
    start.ancestors().find(|candidate| candidate.join(".git").exists()).map(Path::to_path_buf)
}

/// `urlsplit(url).path`.
fn url_path(url: &str) -> &str {
    let Some(colon) = url.find(':') else { return url };
    let scheme = &url[..colon];
    let valid_scheme = scheme.chars().next().is_some_and(|ch| ch.is_ascii_alphabetic())
        && scheme.chars().all(|ch| ch.is_ascii_alphanumeric() || "+-.".contains(ch));
    let mut rest = if valid_scheme { &url[colon + 1..] } else { url };
    if let Some(after) = rest.strip_prefix("//") {
        let end = after.find(['/', '?', '#']).unwrap_or(after.len());
        rest = &after[end..];
    }
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    &rest[..end]
}

/// `remote_owner`: the owner segment of a git remote URL, for third-party detection.
#[must_use]
pub fn remote_owner(remote: Option<&str>) -> Option<String> {
    let remote = remote.filter(|remote| !remote.is_empty())?;
    let cleaned = remote.strip_suffix(".git").unwrap_or(remote);
    let tail = if cleaned.contains("://") {
        url_path(cleaned)
    } else if cleaned.split_once('@').is_some_and(|(_, host)| host.contains(':')) {
        cleaned.split_once(':').map_or("", |(_, tail)| tail)
    } else {
        cleaned.split_once('/').map_or(cleaned, |(_, tail)| tail)
    };
    tail.split('/').find(|segment| !segment.is_empty()).map(str::to_owned)
}

/// How much one identity contributed to one file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthorTally {
    /// The commit author's name.
    pub name: String,
    /// The commit author's address.
    pub email: String,
    /// Commits touching the file.
    pub commits: u64,
}

/// What one pass over a repository's history learned (`RepoAttribution`).
#[derive(Clone, Debug, Default)]
pub struct RepoAttribution {
    /// The `origin` remote's URL.
    pub remote: Option<String>,
    /// Repository-relative POSIX path -> its contributors, in any order.
    pub by_path: BTreeMap<String, Vec<AuthorTally>>,
}

impl RepoAttribution {
    /// `authors_for`: a file's contributors, most commits first, then by name.
    #[must_use]
    pub fn authors_for(&self, relative: &str) -> Vec<AuthorTally> {
        let mut tallies = self.by_path.get(relative).cloned().unwrap_or_default();
        tallies.sort_by(|a, b| b.commits.cmp(&a.commits).then_with(|| a.name.cmp(&b.name)));
        tallies
    }
}

/// Reads a repository's history, as `cached_repo_attribution` does; the host's to provide.
pub trait GitHistory {
    /// The history of the repository at `root`, or `None` when it cannot be read.
    fn repository(&self, root: &Path) -> Option<RepoAttribution>;
}

/// No history: git attribution is skipped, as Python does with neither `_garage_git` nor pygit2.
pub struct NoGit;

impl GitHistory for NoGit {
    fn repository(&self, _root: &Path) -> Option<RepoAttribution> {
        None
    }
}

/// The corpus owner's identities (`SelfIdentity`).
#[derive(Clone, Debug, Default)]
pub struct SelfIdentity {
    /// `self.name`.
    pub name: String,
    emails: Vec<String>,
    names: HashSet<String>,
}

impl SelfIdentity {
    /// From the owner's name and `(kind, value)` pairs (`git_email:...`, `email:...`, `git_name:...`).
    #[must_use]
    pub fn new(name: &str, pairs: &[(String, String)]) -> Self {
        let mut emails: Vec<String> = Vec::new();
        for (kind, value) in pairs {
            let value = value.to_lowercase();
            if kind.contains("email") && !emails.contains(&value) {
                emails.push(value);
            }
        }
        let mut names: HashSet<String> =
            pairs.iter().filter(|(kind, _)| kind == "git_name").map(|(_, value)| value.to_lowercase()).collect();
        if !name.is_empty() {
            names.insert(name.to_lowercase());
        }
        Self { name: name.to_owned(), emails, names }
    }

    /// Whether a name or address is the owner's.
    #[must_use]
    pub fn matches(&self, name: Option<&str>, email: Option<&str>) -> bool {
        email.is_some_and(|email| !email.is_empty() && self.emails.contains(&email.to_lowercase()))
            || name.is_some_and(|name| !name.is_empty() && self.names.contains(&name.to_lowercase()))
    }

    /// The owner's addresses, in the order configured.
    #[must_use]
    pub fn emails(&self) -> &[String] {
        &self.emails
    }
}

/// One resolved author with its role and provenance.
#[derive(Clone, Debug, PartialEq)]
pub struct AttributedAuthor {
    /// The name.
    pub name: String,
    /// The address, when known.
    pub email: Option<String>,
    /// Author or committer.
    pub role: AuthorRole,
    /// From 0 to 1, rounded to three places.
    pub confidence: f64,
    /// Where it came from.
    pub evidence: String,
}

/// The attribution decision for one document.
#[derive(Clone, Debug, PartialEq)]
pub struct Attribution {
    /// How much it is trusted.
    pub trust: TrustTier,
    /// Who wrote it.
    pub authors: Vec<AttributedAuthor>,
    /// The rule that decided.
    pub evidence: String,
    /// Git details, when git decided.
    pub meta: Map<String, Value>,
}

/// Python's `round(x, 3)`: the decimal nearest the exact binary value, ties to even.
fn round3(value: f64) -> f64 {
    format!("{value:.3}").parse().unwrap_or(value)
}

#[allow(clippy::cast_precision_loss)]
fn ratio(part: u64, whole: u64) -> f64 {
    round3(part as f64 / whole as f64)
}

fn git_attribution(path: &Path, identity: &SelfIdentity, git: &dyn GitHistory) -> Option<Attribution> {
    let repo_root = find_repo_root(path)?;
    let repo = git.repository(&repo_root).unwrap_or_default();
    let relative = relative_posix(&repo_root, path)?;
    let tallies = repo.authors_for(&relative);
    let top = tallies.first()?;
    let owner = remote_owner(repo.remote.as_deref());
    let self_commits: u64 = tallies
        .iter()
        .filter(|tally| identity.matches(Some(&tally.name), Some(&tally.email)))
        .map(|tally| tally.commits)
        .sum();
    let total: u64 = tallies.iter().map(|tally| tally.commits).sum::<u64>().max(1);
    let email = |tally: &AuthorTally| Some(tally.email.clone()).filter(|email| !email.is_empty());
    let mut authors = vec![AttributedAuthor {
        name: top.name.clone(),
        email: email(top),
        role: AuthorRole::Author,
        confidence: ratio(top.commits, total),
        evidence: format!("git-log:top-committer:{}/{total}", top.commits),
    }];
    authors.extend(tallies.iter().skip(1).take(5).map(|tally| AttributedAuthor {
        name: tally.name.clone(),
        email: email(tally),
        role: AuthorRole::Committer,
        confidence: ratio(tally.commits, total),
        evidence: format!("git-log:committer:{}/{total}", tally.commits),
    }));
    let (trust, evidence) = if self_commits > 0 {
        (TrustTier::Authored, format!("git-log:self-commits:{self_commits}/{total}"))
    } else {
        (TrustTier::Reference, format!("git-log:no-self-commits:owner={}", owner.as_deref().unwrap_or("None")))
    };
    let repo_name = repo_root.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let Value::Object(meta) = json!({
        "git_repo": repo_name,
        "git_remote": repo.remote,
        "git_remote_owner": owner,
        "git_commits_total": total,
        "git_commits_self": self_commits,
    }) else {
        unreachable!("json! of an object literal is an object")
    };
    Some(Attribution { trust, authors, evidence, meta })
}

fn metadata_attribution(hints: &[String], identity: &SelfIdentity) -> Option<Attribution> {
    if hints.is_empty() {
        return None;
    }
    let authors = hints
        .iter()
        .take(5)
        .enumerate()
        .map(|(index, hint)| AttributedAuthor {
            name: hint.clone(),
            email: None,
            role: if index == 0 { AuthorRole::Author } else { AuthorRole::Committer },
            confidence: if index == 0 { 0.8 } else { 0.5 },
            evidence: "document-metadata".to_owned(),
        })
        .collect();
    let (trust, evidence) = if hints.iter().any(|hint| identity.matches(Some(hint), None)) {
        (TrustTier::Authored, "document-metadata:self")
    } else {
        (TrustTier::Reference, "document-metadata:third-party")
    };
    Some(Attribution { trust, authors, evidence: evidence.to_owned(), meta: Map::new() })
}

fn sender_attribution(senders: &[String], identity: &SelfIdentity) -> Option<Attribution> {
    let parsed: Vec<(String, String)> = senders
        .iter()
        .take(5)
        .map(|sender| parseaddr(sender))
        .filter(|(name, address)| !name.is_empty() || !address.is_empty())
        .collect();
    if parsed.is_empty() {
        return None;
    }
    let authors = parsed
        .iter()
        .map(|(name, address)| AttributedAuthor {
            name: if name.is_empty() { address.clone() } else { name.clone() },
            email: Some(address.clone()).filter(|address| !address.is_empty()),
            role: AuthorRole::Author,
            confidence: 0.9,
            evidence: "message-sender".to_owned(),
        })
        .collect();
    let mine = parsed.iter().any(|(name, address)| identity.matches(Some(name), Some(address)));
    let (trust, evidence) = if mine {
        (TrustTier::Authored, "message-sender:self")
    } else {
        (TrustTier::Received, "message-sender:third-party")
    };
    Some(Attribution { trust, authors, evidence: evidence.to_owned(), meta: Map::new() })
}

/// What [`resolve`] decides from, besides the file's path.
pub struct Signals<'a> {
    /// The source's root.
    pub source_root: &'a Path,
    /// The source's default trust.
    pub default_trust: TrustTier,
    /// Embedded authors, or a message's senders when `communication`.
    pub author_hints: &'a [String],
    /// The owner.
    pub identity: &'a SelfIdentity,
    /// Whether the document is a message.
    pub communication: bool,
}

/// `resolve`: trust and authorship for one file. Unlike Python, which picks any one of the owner's
/// addresses for a path-only attribution, the first one configured is used.
#[must_use]
pub fn resolve(path: &Path, signals: &Signals<'_>, git: &dyn GitHistory) -> Attribution {
    let identity = signals.identity;
    if let Some(from_git) = git_attribution(path, identity, git) {
        return from_git;
    }
    if signals.communication
        && let Some(from_sender) = sender_attribution(signals.author_hints, identity)
    {
        return from_sender;
    }
    let from_meta = metadata_attribution(signals.author_hints, identity);
    let (path_trust, path_label) = classify_path(path, signals.source_root, signals.default_trust);
    if let Some(from_meta) = from_meta {
        let trust = if path_trust == TrustTier::Reference { TrustTier::Reference } else { from_meta.trust };
        return Attribution {
            trust,
            authors: from_meta.authors,
            evidence: format!("{}+{path_label}", from_meta.evidence),
            meta: Map::new(),
        };
    }
    let mut authors = Vec::new();
    if path_trust == TrustTier::Authored && !identity.name.is_empty() {
        authors.push(AttributedAuthor {
            name: identity.name.clone(),
            email: identity.emails().first().cloned(),
            role: AuthorRole::Author,
            confidence: 0.6,
            evidence: path_label.clone(),
        });
    }
    Attribution { trust: path_trust, authors, evidence: path_label, meta: Map::new() }
}

#[cfg(test)]
#[allow(clippy::float_cmp)]
mod tests {
    use super::*;

    struct OneRepo(RepoAttribution);

    impl GitHistory for OneRepo {
        fn repository(&self, _root: &Path) -> Option<RepoAttribution> {
            Some(self.0.clone())
        }
    }

    fn identity() -> SelfIdentity {
        SelfIdentity::new("Ada Lovelace", &[("git_email".to_owned(), "Ada@Example.com".to_owned())])
    }

    fn signals<'a>(root: &'a Path, hints: &'a [String], identity: &'a SelfIdentity) -> Signals<'a> {
        Signals {
            source_root: root,
            default_trust: TrustTier::Authored,
            author_hints: hints,
            identity,
            communication: false,
        }
    }

    #[test]
    fn paths_classify_by_the_first_rule() {
        let root = Path::new("/garage/root");
        let case = |relative: &str| classify_path(&root.join(relative), root, TrustTier::Authored);
        assert_eq!(case("Reference/a.pdf"), (TrustTier::Reference, "path:Reference".to_owned()));
        assert_eq!(case("x/y/Manuals/m.pdf"), (TrustTier::Reference, "path:Manuals".to_owned()));
        assert_eq!(case("Projects/x/node_modules/a.js"), (TrustTier::Reference, "path:vendored".to_owned()));
        assert_eq!(case("Notes/today.md"), (TrustTier::Authored, "path:Notes".to_owned()));
        assert_eq!(case("misc/references/r.md"), (TrustTier::Reference, "path:component:references".to_owned()));
        assert_eq!(case("misc/r.md"), (TrustTier::Authored, "path:default".to_owned()));
    }

    #[test]
    fn remote_owners() {
        for (remote, owner) in [
            ("https://github.com/ada/engine.git", Some("ada")),
            ("ssh://git@github.com:22/ada/engine", Some("ada")),
            ("git@github.com:ada/engine.git", Some("ada")),
            ("github.com/ada/engine", Some("ada")),
            ("engine", Some("engine")),
            ("", None),
        ] {
            assert_eq!(remote_owner(Some(remote)).as_deref(), owner, "{remote}");
        }
        assert_eq!(remote_owner(None), None);
    }

    #[test]
    fn git_history_decides_first() {
        let dir = std::env::temp_dir().join(format!("garage-attr-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let file = dir.join("lib.rs");
        std::fs::write(&file, "x").unwrap();
        let tally = |name: &str, email: &str, commits| AuthorTally { name: name.into(), email: email.into(), commits };
        let mut by_path = BTreeMap::new();
        by_path.insert("lib.rs".to_owned(), vec![tally("Bob", "bob@x", 3), tally("Ada", "ada@example.com", 13)]);
        let git = OneRepo(RepoAttribution { remote: Some("git@github.com:bob/lib.git".into()), by_path });
        let identity = identity();
        let attribution = resolve(&file, &signals(&dir, &[], &identity), &git);
        assert_eq!(attribution.trust, TrustTier::Authored);
        assert_eq!(attribution.evidence, "git-log:self-commits:13/16");
        assert_eq!(attribution.authors[0].confidence, 0.812);
        assert_eq!(attribution.authors[1].confidence, 0.188);
        assert_eq!(attribution.meta["git_remote_owner"], "bob");
        // An untracked file in the repository falls through to the path.
        let other = dir.join("notes.md");
        assert_eq!(resolve(&other, &signals(&dir, &[], &identity), &git).evidence, "path:default");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn metadata_and_senders() {
        let identity = identity();
        let root = Path::new("/no/such/garage");
        let hints = vec!["Grace Hopper".to_owned()];
        let paper = resolve(&root.join("Reference/p.pdf"), &signals(root, &hints, &identity), &NoGit);
        assert_eq!(
            (paper.trust, paper.evidence.as_str()),
            (TrustTier::Reference, "document-metadata:third-party+path:Reference")
        );
        let senders = vec!["Grace <grace@navy.mil>".to_owned()];
        let mail = Signals { communication: true, ..signals(root, &senders, &identity) };
        let received = resolve(&root.join("mail/1.eml"), &mail, &NoGit);
        assert_eq!((received.trust, received.evidence.as_str()), (TrustTier::Received, "message-sender:third-party"));
        let mine = vec!["ada@example.com".to_owned()];
        let sent = resolve(
            &root.join("mail/2.eml"),
            &Signals { communication: true, ..signals(root, &mine, &identity) },
            &NoGit,
        );
        assert_eq!(sent.trust, TrustTier::Authored);
        assert_eq!(sent.authors[0].name, "ada@example.com");
    }

    #[test]
    fn a_path_alone_names_the_owner() {
        let identity = identity();
        let root = Path::new("/no/such/garage");
        let attribution = resolve(&root.join("Notes/a.md"), &signals(root, &[], &identity), &NoGit);
        assert_eq!(attribution.authors[0].email.as_deref(), Some("ada@example.com"));
        assert_eq!(attribution.authors[0].confidence, 0.6);
    }

    #[test]
    fn rounding_matches_python() {
        assert_eq!(round3(0.0625), 0.062);
        assert_eq!(round3(2.0 / 3.0), 0.667);
    }
}
