use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use garage_spotlight::index::{IndexedItem, Value as IndexValue};
use serde_json::{Map, Value, json};

use super::*;
use crate::attribution::{NoGit, SelfIdentity, TrustTier};
use crate::chunking::ContentKind;
use crate::pipeline::{
    AuthorPayload, Context, DocumentPayload, ExistingStat, Extracted, FileCandidate, FileHost, IngestSettings,
    ReadOutcome, SourceInfo, Storage,
};
use crate::policy::WalkPolicy;
use crate::source::{SourceHost, SourceRun, SourceStorage};

struct TempTree(PathBuf);

impl TempTree {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!("garage-ingest-spotlight-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn write(&self, rel: &str, content: &[u8]) -> PathBuf {
        let p = self.0.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, content).unwrap();
        p
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn private_path_blocks_personal_folders_and_library_when_outside() {
    let home = Path::new("/Users/alice");
    let docs_root = Path::new("/Users/alice/Documents");
    assert!(private_path(&home.join("Library/Mail/V10/1.emlx"), docs_root, Some(home)));
    assert!(private_path(&home.join("Library/Messages/chat.db"), docs_root, Some(home)));
    assert!(private_path(&home.join("Library/Preferences/foo.plist"), docs_root, Some(home)));
    assert!(private_path(
        &home.join("Pictures/Photos Library.photoslibrary/database/Photos.sqlite"),
        docs_root,
        Some(home),
    ));
    assert!(!private_path(&home.join("Documents/notes.md"), docs_root, Some(home)));

    // Explicitly pointing a root inside ~/Library/CloudStorage permits CloudStorage, yet Mail/Messages remain blocked.
    let icloud_root = home.join("Library/Mobile Documents");
    assert!(!private_path(&icloud_root.join("com~apple~CloudDocs/plan.pdf"), &icloud_root, Some(home)));
    assert!(private_path(&home.join("Library/Mail/V10/1.emlx"), &icloud_root, Some(home)));
}

#[test]
fn download_origins_strip_credentials_queries_and_non_urls() {
    assert_eq!(
        origin("https://user:secret@example.com/path/doc.pdf?token=abc#top").as_deref(),
        Some("https://example.com/path/doc.pdf")
    );
    assert_eq!(origin("https://example.com?x=1").as_deref(), Some("https://example.com"));
    assert_eq!(origin("ftp://files.example.org/pub/a.rtf").as_deref(), Some("ftp://files.example.org/pub/a.rtf"));
    assert_eq!(origin("Alice <alice@example.com>"), None);
    assert_eq!(origin("file:///tmp/local.pdf"), None);
}

#[test]
fn describe_enriches_metadata_and_falls_back_title_and_authors() {
    let mut doc = Extracted {
        text: "body".into(),
        kind: ContentKind::Prose,
        extractor: "spotlight".into(),
        extractor_version: "1".into(),
        title: None,
        lang: None,
        meta: Map::new(),
        author_hints: Vec::new(),
    };
    let attrs = vec![
        ("kMDItemDisplayName".into(), IndexValue::Text("Budget.rtf".into())),
        ("kMDItemTitle".into(), IndexValue::Text("Q4 Budget".into())),
        ("kMDItemAuthors".into(), IndexValue::List(vec!["Alice".into(), "Bob".into()])),
        ("kMDItemKeywords".into(), IndexValue::List(vec!["finance".into()])),
        (
            "kMDItemWhereFroms".into(),
            IndexValue::List(vec!["https://u:p@drive.example.com/budget?dl=1".into(), "Re: Budget".into()]),
        ),
        ("kMDItemUseCount".into(), IndexValue::Number(5.0)),
    ];
    describe(&mut doc, &attrs);
    assert_eq!(doc.title.as_deref(), Some("Q4 Budget"));
    assert_eq!(doc.author_hints, vec!["Alice", "Bob"]);
    assert_eq!(doc.meta["spotlight"]["display_name"], json!("Budget.rtf"));
    assert_eq!(doc.meta["spotlight"]["where_froms"], json!(["https://drive.example.com/budget"]));
    assert_eq!(doc.meta["spotlight"]["use_count"], json!(5));

    // Existing title and authors from primary reader are preserved.
    let mut doc_with_own =
        Extracted { title: Some("Own Title".into()), author_hints: vec!["Carol".into()], ..doc.clone() };
    describe(&mut doc_with_own, &attrs);
    assert_eq!(doc_with_own.title.as_deref(), Some("Own Title"));
    assert_eq!(doc_with_own.author_hints, vec!["Carol"]);
}

#[derive(Default)]
struct MockHost {
    reads: RefCell<Vec<String>>,
}

impl FileHost for MockHost {
    fn ensure_local(&mut self, _: &FileCandidate) -> bool {
        true
    }

    fn source_sha256(&mut self, candidate: &FileCandidate) -> Option<String> {
        Some(crate::pipeline::sha256_hex(candidate.uri.as_bytes()))
    }

    fn read(&mut self, candidate: &FileCandidate) -> ReadOutcome {
        self.reads.borrow_mut().push(candidate.name());
        ReadOutcome::Document(Extracted {
            text: format!("Extracted text of {}", candidate.name()),
            kind: ContentKind::Prose,
            extractor: "mock".into(),
            extractor_version: "1".into(),
            title: None,
            lang: None,
            meta: Map::new(),
            author_hints: Vec::new(),
        })
    }
}

impl SourceHost for MockHost {}

type LinkedPayload = (String, Option<String>, Map<String, Value>, Vec<AuthorPayload>);

#[derive(Default)]
struct MockStorage {
    stats: HashMap<String, ExistingStat>,
    actions: Vec<String>,
    linked_payloads: Vec<LinkedPayload>,
    replaced_payloads: Vec<(String, DocumentPayload)>,
}

impl Storage for MockStorage {
    fn record_seen(&mut self, uri: &str) -> Result<(), String> {
        self.actions.push(format!("seen:{uri}"));
        Ok(())
    }

    fn record_placeholder(&mut self, uri: &str, _: f64, _: &str, _: &str) -> Result<(), String> {
        self.actions.push(format!("placeholder:{uri}"));
        Ok(())
    }

    fn record_no_text(&mut self, uri: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
        self.actions.push(format!("no_text:{uri}"));
        Ok(())
    }

    fn record_extract_failed(&mut self, uri: &str, _: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
        self.actions.push(format!("extract_failed:{uri}"));
        Ok(())
    }

    fn record_rejected(&mut self, uri: &str) -> Result<(), String> {
        self.actions.push(format!("rejected:{uri}"));
        Ok(())
    }

    fn refresh_metadata(&mut self, uri: &str, _: u64, _: f64, _: &str, _: &str, _: &str) -> Result<(), String> {
        self.actions.push(format!("refresh_metadata:{uri}"));
        Ok(())
    }

    fn replace_document(&mut self, uri: &str, document: DocumentPayload) -> Result<usize, String> {
        let count = document.chunks.len();
        self.actions.push(format!("replace:{uri}"));
        self.replaced_payloads.push((uri.to_owned(), document));
        Ok(count)
    }

    fn link_additional(
        &mut self,
        uri: &str,
        _: f64,
        title: Option<&str>,
        meta: &Map<String, Value>,
        authors: &[AuthorPayload],
    ) -> Result<(), String> {
        self.actions.push(format!("link:{uri}"));
        self.linked_payloads.push((uri.to_owned(), title.map(str::to_owned), meta.clone(), authors.to_vec()));
        Ok(())
    }
}

impl SourceStorage for MockStorage {
    fn check_stat(&mut self, uri: &str) -> Result<ExistingStat, String> {
        Ok(self.stats.get(uri).cloned().unwrap_or_default())
    }

    fn persist_scan(&mut self, _: &crate::source::ScanSummary) -> Result<(), String> {
        Ok(())
    }

    fn finalize(&mut self, _: bool, _: &crate::pipeline::Counters, _: u64, _: u64) -> Result<(), String> {
        Ok(())
    }
}

#[test]
fn spotlight_links_existing_documents_skips_unchanged_links_and_indexes_uncovered_ones() {
    let tree = TempTree::new("link-and-index");
    let uncovered = tree.write("uncovered.md", b"# Uncovered note");
    let already_owned = tree.write("already.md", b"# Owned by filesystem");
    let unchanged_linked = tree.write("linked.md", b"# Already linked");

    let real_root = fs::canonicalize(&tree.0).unwrap();
    let items: Vec<IndexedItem> = [&uncovered, &already_owned, &unchanged_linked]
        .iter()
        .map(|p| IndexedItem {
            path: fs::canonicalize(p).unwrap(),
            content_types: vec!["net.daringfireball.markdown".into(), "public.content".into()],
        })
        .collect();

    let policy = WalkPolicy::default();
    let mut stats = WalkStats::default();
    let mut listed = Listed::default();
    let found = filter_items(&tree.0, &real_root, None, &items, &policy, false, &[], &mut stats, &mut listed);
    assert_eq!(found.len(), 3);

    let unchanged_mtime = microsecond_mtime(found.iter().find(|c| c.path == unchanged_linked).unwrap().mtime);

    let mut storage = MockStorage::default();
    storage.stats.insert(
        already_owned.to_string_lossy().into_owned(),
        ExistingStat {
            exists: false,
            existing_document_id: Some(42),
            already_linked: false,
            ..ExistingStat::default()
        },
    );
    storage.stats.insert(
        unchanged_linked.to_string_lossy().into_owned(),
        ExistingStat {
            exists: false,
            mtime: unchanged_mtime,
            existing_document_id: Some(99),
            already_linked: true,
            ..ExistingStat::default()
        },
    );

    let source =
        SourceInfo { root: tree.0.clone(), default_class: "document".into(), default_trust: TrustTier::Authored };
    let identity = SelfIdentity::new("Alice", &[]);
    let settings = IngestSettings::default();
    let context = Context {
        source: &source,
        identity: &identity,
        git: &NoGit,
        contact_names: None,
        settings: &settings,
        policy: &policy,
        force: false,
    };

    let mut host = MockHost::default();
    let mut run = SourceRun::default();
    let completed = ingest_candidates(
        &mut host,
        &mut storage,
        &context,
        &found,
        None,
        &|path| {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            vec![
                ("kMDItemTitle".into(), IndexValue::Text(format!("Title of {name}"))),
                ("kMDItemAuthors".into(), IndexValue::List(vec!["Alice".into()])),
                ("kMDItemUseCount".into(), IndexValue::Number(3.0)),
            ]
        },
        &mut run,
    );

    assert!(completed);
    // Only the uncovered file was actually read from disk!
    assert_eq!(*host.reads.borrow(), vec!["uncovered.md"]);
    assert_eq!(run.counters.seen, 3);
    assert_eq!(run.counters.indexed, 2);
    assert_eq!(run.counters.skipped, 1);

    // Uncovered was replaced under spotlight; already_owned was linked without reading; unchanged_linked was fast-skipped.
    assert_eq!(storage.replaced_payloads.len(), 1);
    assert_eq!(storage.replaced_payloads[0].0, uncovered.to_string_lossy());
    assert_eq!(storage.replaced_payloads[0].1.title.as_deref(), Some("Title of uncovered.md"));
    assert_eq!(storage.replaced_payloads[0].1.meta["spotlight"]["use_count"], json!(3));

    assert_eq!(storage.linked_payloads.len(), 1);
    assert_eq!(storage.linked_payloads[0].0, already_owned.to_string_lossy());
    assert_eq!(storage.linked_payloads[0].1.as_deref(), Some("Title of already.md"));
    assert_eq!(storage.linked_payloads[0].2["spotlight"]["use_count"], json!(3));
    assert_eq!(storage.linked_payloads[0].3[0].name, "Alice");
    assert!(storage.linked_payloads[0].3[0].is_self);

    assert!(storage.actions.contains(&format!("seen:{}", unchanged_linked.display())));
}
