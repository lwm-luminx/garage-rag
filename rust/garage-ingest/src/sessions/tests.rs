use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::json;
use zip::write::SimpleFileOptions;

use super::types::{ANTIGRAVITY_KIND, CHATGPT_KIND, CLAUDE_KIND, SessionWritePayload};
use crate::attribution::{NoGit, SelfIdentity, TrustTier};
use crate::pipeline::{
    Context, Counters, DocumentPayload, ExistingStat, FileCandidate, FileHost, IngestSettings, ReadOutcome, SourceInfo,
};
use crate::scanner::{ScanOptions, Ticker, scan_source};
use crate::source::{ScanSummary, SourceError, SourceHost, SourceOptions, SourceRun, SourceStorage, ingest_source};
use crate::policy::WalkPolicy;

static NEXT_DIR: AtomicUsize = AtomicUsize::new(1);

struct TempTree(PathBuf);

impl TempTree {
    fn new(prefix: &str) -> Self {
        let n = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("garage-sessions-{prefix}-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp dir");
        Self(dir)
    }

    fn write(&self, rel: &str, contents: &str) -> PathBuf {
        let path = self.0.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent");
        }
        fs::write(&path, contents).expect("write fixture");
        path
    }

    fn write_zip(&self, rel: &str, entries: &[(&str, &str)]) -> PathBuf {
        let path = self.0.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create zip parent");
        }
        let file = fs::File::create(&path).expect("create zip");
        let mut zip = zip::ZipWriter::new(file);
        let opts = SimpleFileOptions::default();
        for (name, body) in entries {
            zip.start_file(*name, opts).expect("start zip entry");
            zip.write_all(body.as_bytes()).expect("write zip entry");
        }
        zip.finish().expect("finish zip");
        path
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[derive(Default)]
struct NoopHost;

impl FileHost for NoopHost {
    fn ensure_local(&mut self, _: &FileCandidate) -> bool {
        true
    }
    fn source_sha256(&mut self, _: &FileCandidate) -> Option<String> {
        None
    }
    fn read(&mut self, _: &FileCandidate) -> ReadOutcome {
        ReadOutcome::NoText(String::new())
    }
}

impl SourceHost for NoopHost {
    fn cancelled(&mut self) -> bool {
        false
    }
    fn progress(&mut self, _phase: &str, _current_item: Option<&str>, _counters: &Counters) {}
}

#[derive(Default)]
struct MemorySessionStorage {
    docs: HashMap<String, DocumentPayload>,
    order: Vec<String>,
    seen: Vec<String>,
}

impl crate::pipeline::Storage for MemorySessionStorage {
    fn record_seen(&mut self, uri: &str) -> Result<(), String> {
        self.seen.push(uri.to_owned());
        Ok(())
    }
    fn record_placeholder(&mut self, _: &str, _: f64, _: &str, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn record_no_text(&mut self, _: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn record_extract_failed(&mut self, _: &str, _: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn record_rejected(&mut self, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn refresh_metadata(&mut self, _: &str, _: u64, _: f64, _: &str, _: &str, _: &str) -> Result<(), String> {
        Ok(())
    }
    fn replace_document(&mut self, uri: &str, document: DocumentPayload) -> Result<usize, String> {
        let n = document.chunks.len();
        self.order.push(uri.to_owned());
        self.docs.insert(uri.to_owned(), document);
        Ok(n)
    }
}

impl SourceStorage for MemorySessionStorage {
    fn check_stat(&mut self, uri: &str) -> Result<ExistingStat, String> {
        let Some(doc) = self.docs.get(uri) else {
            return Ok(ExistingStat::default());
        };
        Ok(ExistingStat {
            exists: true,
            mtime: doc.mtime,
            byte_size: doc.byte_size as i64,
            source_sha256: doc.source_sha256.clone().unwrap_or_default(),
            content_sha256: doc.content_sha256.clone(),
            state: "OK".to_owned(),
            chunker: doc.chunker.clone(),
            ..ExistingStat::default()
        })
    }
    fn persist_scan(&mut self, _: &ScanSummary) -> Result<(), String> {
        Ok(())
    }
    fn finalize(&mut self, _: bool, _: &Counters, _: u64, _: u64) -> Result<(), String> {
        Ok(())
    }
}

fn run_session_ingest(
    root: &Path,
    kind: &str,
    default_class: &str,
    storage: &mut MemorySessionStorage,
) -> Result<SourceRun, SourceError> {
    let source = SourceInfo {
        root: root.to_path_buf(),
        default_class: default_class.to_owned(),
        default_trust: TrustTier::Received,
    };
    let identity = SelfIdentity::new("Ada Lovelace", &[("email".to_owned(), "ada@example.com".to_owned())]);
    let settings = IngestSettings::default();
    let policy = WalkPolicy::default();
    let context = Context {
        source: &source,
        identity: &identity,
        git: &NoGit,
        contact_names: None,
        settings: &settings,
        policy: &policy,
        force: false,
    };
    let mut host = NoopHost;
    ingest_source(
        &mut host,
        storage,
        &context,
        &ScanSummary::default(),
        &SourceOptions {
            include_code: false,
            limit: None,
            messages: false,
            session_kind: Some(kind.to_owned()),
            ..SourceOptions::default()
        },
    )
}

#[test]
fn claude_jsonl_subagent_and_web_zip_scan_and_ingest() {
    let tree = TempTree::new("claude");
    let parent_lines = [
        json!({"type": "custom-title", "customTitle": "Parser Refactor"}).to_string(),
        json!({"type": "summary", "summary": "Refactored session parser"}).to_string(),
        json!({
            "type": "user",
            "uuid": "u-1",
            "sessionId": "sess-100",
            "cwd": "/workspace/garage",
            "gitBranch": "feat/sessions",
            "timestamp": "2026-04-10T12:00:00Z",
            "message": {"role": "user", "content": "Inspect src/lib.rs and run tests\u{0000}"}
        })
        .to_string(),
        json!({
            "type": "assistant",
            "uuid": "a-1",
            "parentUuid": "u-1",
            "sessionId": "sess-100",
            "timestamp": "2026-04-10T12:01:00Z",
            "message": {
                "role": "assistant",
                "model": "claude-sonnet-4-6",
                "usage": {"input_tokens": 120, "output_tokens": 45, "cache_read_input_tokens": 300},
                "content": [
                    {"type": "thinking", "thinking": "Secret internal reasoning trace"},
                    {"type": "tool_use", "id": "toolu_read", "name": "Read", "input": {"file_path": "/workspace/garage/src/lib.rs"}},
                    {"type": "tool_use", "id": "toolu_bash", "name": "Bash", "input": {"command": "cargo test"}},
                    {"type": "text", "text": "Checked src/lib.rs and ran the test suite."}
                ]
            }
        })
        .to_string(),
        json!({
            "type": "user",
            "uuid": "tr-1",
            "parentUuid": "a-1",
            "sessionId": "sess-100",
            "timestamp": "2026-04-10T12:01:05Z",
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_read", "content": "pub mod sessions;"},
                    {"type": "tool_result", "tool_use_id": "toolu_bash", "is_error": true, "content": "1 test failed"}
                ]
            }
        })
        .to_string(),
        json!({
            "type": "assistant",
            "uuid": "a-2",
            "parentUuid": "tr-1",
            "sessionId": "sess-100",
            "timestamp": "2026-04-10T12:02:00Z",
            "message": {
                "role": "assistant",
                "model": "claude-sonnet-4-6",
                "usage": {"input_tokens": 80, "output_tokens": 30},
                "content": [{"type": "text", "text": "Fixed the failing assertion."}]
            }
        })
        .to_string(),
    ]
    .join("\n");
    let parent_path = tree.write("projects/demo/sess-100.jsonl", &parent_lines);

    let subagent_lines = [
        json!({
            "type": "user",
            "uuid": "sub-u1",
            "sessionId": "sess-100",
            "agentId": "agent-helper",
            "isSidechain": true,
            "entrypoint": "claude-cowork",
            "timestamp": "2026-04-10T12:01:10Z",
            "message": {"role": "user", "content": "Audit edge cases"}
        })
        .to_string(),
        json!({
            "type": "assistant",
            "uuid": "sub-a1",
            "parentUuid": "sub-u1",
            "sessionId": "sess-100",
            "agentId": "agent-helper",
            "isSidechain": true,
            "timestamp": "2026-04-10T12:01:20Z",
            "message": {"role": "assistant", "model": "claude-haiku-4-5", "content": "All edge cases look sound."}
        })
        .to_string(),
    ]
    .join("\n");
    let sub_path = tree.write("projects/demo/sess-100/subagents/agent-helper.jsonl", &subagent_lines);

    // Ignored noise directory under ~/.claude
    tree.write("telemetry/ignored.jsonl", &parent_lines);

    let web_export = json!([{
        "uuid": "web-conv-1",
        "name": "Design Spec Draft",
        "created_at": "2026-04-11T09:00:00Z",
        "updated_at": "2026-04-11T09:05:00Z",
        "chat_messages": [
            {"uuid": "wm-1", "sender": "human", "text": "Write a short architecture note."},
            {
                "uuid": "wm-2",
                "sender": "assistant",
                "text": "Here is the spec:\n<antArtifact identifier=\"spec-v1\" type=\"text/markdown\" title=\"Session Spec\"># Session Spec\n\nRelational tables keep turns, tools, and artifacts structured.</antArtifact>"
            }
        ]
    }])
    .to_string();
    tree.write_zip("exports/claude-web.zip", &[("conversations.json", &web_export)]);

    let scan = scan_source(
        "claude",
        CLAUDE_KIND,
        &tree.0,
        &ScanOptions { include_code: false, policy: &WalkPolicy::default(), read_git: false, spotlight: None },
        &mut Ticker::new(None),
    );
    assert_eq!(scan.error, None);
    assert_eq!(scan.item_type, "sessions");
    assert_eq!(scan.item_count, 3);

    let mut storage = MemorySessionStorage::default();
    // Pass default_class = "document" to verify session transcripts still force "communication".
    let run = run_session_ingest(&tree.0, CLAUDE_KIND, "document", &mut storage).expect("ingest");
    assert!(run.completed);
    assert_eq!(run.counters.seen, 3);
    assert_eq!(run.counters.indexed, 4, "3 sessions + 1 companion antArtifact document");
    assert!(run.counters.errors.is_empty(), "{:?}", run.counters.errors);

    let parent_uri = parent_path.display().to_string();
    let sub_uri = sub_path.display().to_string();
    let parent_pos = storage.order.iter().position(|u| u == &parent_uri).expect("parent stored");
    let sub_pos = storage.order.iter().position(|u| u == &sub_uri).expect("subagent stored");
    assert!(parent_pos < sub_pos, "root session must be persisted before its subagent");

    let parent_doc = &storage.docs[&parent_uri];
    assert_eq!(parent_doc.corpus_class, "communication");
    assert!(!parent_doc.content.contains("Secret internal reasoning trace"));
    assert!(!parent_doc.content.contains('\0'));
    assert_eq!(parent_doc.chunks.len(), 3, "u-1, a-1, a-2 prose turns");
    assert_eq!(parent_doc.chunks[0].session_turn_external_id.as_deref(), Some("u-1"));
    assert_eq!(parent_doc.chunks[1].session_turn_external_id.as_deref(), Some("a-1"));
    assert_eq!(parent_doc.chunks[2].session_turn_external_id.as_deref(), Some("a-2"));

    let payload_val: serde_json::Value =
        serde_json::from_str(parent_doc.session_json.as_deref().expect("session_json")).expect("valid json");
    let SessionWritePayload::Session(rec) = SessionWritePayload::from_json(&payload_val).expect("round-trip") else {
        panic!("expected Session payload");
    };
    assert_eq!(rec.title.as_deref(), Some("Parser Refactor"));
    assert_eq!(rec.workspace_path.as_deref(), Some("/workspace/garage"));
    assert_eq!(rec.git_branch.as_deref(), Some("feat/sessions"));
    assert_eq!(rec.input_tokens, Some(200));
    assert_eq!(rec.output_tokens, Some(75));
    assert_eq!(rec.cache_read_tokens, Some(300));
    assert_eq!(rec.turns[1].thinking.as_deref(), Some("Secret internal reasoning trace"));
    assert_eq!(rec.turns[2].role, "tool");
    assert_eq!(rec.turns[2].active_ord, None);
    assert_eq!(rec.tool_calls.len(), 2);
    assert_eq!(rec.tool_calls[0].tool_kind, "read");
    assert_eq!(rec.tool_calls[0].target_path.as_deref(), Some("/workspace/garage/src/lib.rs"));
    assert_eq!(rec.tool_calls[0].result_turn_external_id.as_deref(), Some("tr-1"));
    assert_eq!(rec.tool_calls[1].tool_kind, "exec");
    assert_eq!(rec.tool_calls[1].status, "error");

    let sub_doc = &storage.docs[&sub_uri];
    let sub_val: serde_json::Value = serde_json::from_str(sub_doc.session_json.as_deref().unwrap()).unwrap();
    let SessionWritePayload::Session(sub_rec) = SessionWritePayload::from_json(&sub_val).unwrap() else {
        panic!("expected subagent Session payload");
    };
    assert_eq!(sub_rec.external_id, "sess-100:agent-helper");
    assert_eq!(sub_rec.parent_external_id.as_deref(), Some("sess-100"));
    assert_eq!(sub_rec.surface, "claude_cowork");

    // Re-running without modifications skips all 4 documents.
    let rerun = run_session_ingest(&tree.0, CLAUDE_KIND, "communication", &mut storage).expect("re-ingest");
    assert_eq!((rerun.counters.indexed, rerun.counters.skipped), (0, 4));
}

#[test]
fn chatgpt_codex_and_branched_web_mapping_preserve_inactive_branches() {
    let tree = TempTree::new("chatgpt");
    let codex_lines = [
        json!({
            "timestamp": "2026-05-01T10:00:00Z",
            "type": "session_meta",
            "payload": {
                "id": "codex-001",
                "cwd": "/Users/dev/project",
                "git": {"branch": "main", "commit_hash": "abc1234"}
            }
        })
        .to_string(),
        json!({
            "timestamp": "2026-05-01T10:00:01Z",
            "type": "turn_context",
            "payload": {"model": "gpt-5-codex", "cwd": "/Users/dev/project"}
        })
        .to_string(),
        json!({
            "timestamp": "2026-05-01T10:00:02Z",
            "type": "response_item",
            "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Patch src/main.rs"}]}
        })
        .to_string(),
        json!({
            "timestamp": "2026-05-01T10:00:03Z",
            "type": "response_item",
            "payload": {"type": "reasoning", "summary": [{"type": "summary_text", "text": "Planning minimal diff"}]}
        })
        .to_string(),
        json!({
            "timestamp": "2026-05-01T10:00:04Z",
            "type": "response_item",
            "payload": {
                "type": "custom_tool_call",
                "call_id": "call_patch_1",
                "name": "apply_patch",
                "input": "*** Begin Patch\n*** Update File: src/main.rs\n@@\n-old\n+new\n*** End Patch"
            }
        })
        .to_string(),
        json!({
            "timestamp": "2026-05-01T10:00:05Z",
            "type": "response_item",
            "payload": {"type": "custom_tool_call_output", "call_id": "call_patch_1", "output": "{\"exit_code\": 0, \"output\": \"Updated src/main.rs\"}"}
        })
        .to_string(),
        json!({
            "timestamp": "2026-05-01T10:00:06Z",
            "type": "response_item",
            "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Applied the patch to src/main.rs."}]}
        })
        .to_string(),
        json!({
            "timestamp": "2026-05-01T10:00:07Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"total_token_usage": {"input_tokens": 500, "output_tokens": 90, "cached_input_tokens": 250}}
            }
        })
        .to_string(),
    ]
    .join("\n");
    let codex_path = tree.write("sessions/2026/05/rollout-codex.jsonl", &codex_lines);
    // `~/.codex/history.jsonl` is the global prompt history index and must be skipped.
    tree.write("history.jsonl", "{\"session_id\":\"codex-001\",\"text\":\"Patch src/main.rs\"}\n");

    let web_export = json!([{
        "conversation_id": "cgpt-branch-1",
        "title": "Planetary Ocean Inquiry",
        "create_time": 1_777_000_000.0,
        "update_time": 1_777_000_120.0,
        "default_model_slug": "gpt-4o",
        "current_node": "node-a2",
        "mapping": {
            "node-root": {"id": "node-root", "message": null, "parent": null, "children": ["node-u1", "node-u2"]},
            "node-u1": {
                "id": "node-u1",
                "parent": "node-root",
                "children": ["node-a1"],
                "message": {
                    "id": "node-u1",
                    "author": {"role": "user"},
                    "create_time": 1_777_000_010.0,
                    "recipient": "all",
                    "content": {"content_type": "text", "parts": ["Abandoned question about Mars dust storms"]}
                }
            },
            "node-a1": {
                "id": "node-a1",
                "parent": "node-u1",
                "children": [],
                "message": {
                    "id": "node-a1",
                    "author": {"role": "assistant"},
                    "create_time": 1_777_000_020.0,
                    "recipient": "all",
                    "metadata": {"model_slug": "gpt-4o"},
                    "content": {"content_type": "text", "parts": ["Abandoned Mars answer"]}
                }
            },
            "node-u2": {
                "id": "node-u2",
                "parent": "node-root",
                "children": ["node-canvas"],
                "message": {
                    "id": "node-u2",
                    "author": {"role": "user"},
                    "create_time": 1_777_000_030.0,
                    "recipient": "all",
                    "content": {"content_type": "text", "parts": ["Edited question about Europa subsurface ocean"]}
                }
            },
            "node-canvas": {
                "id": "node-canvas",
                "parent": "node-u2",
                "children": ["node-a2"],
                "message": {
                    "id": "node-canvas",
                    "author": {"role": "assistant"},
                    "create_time": 1_777_000_040.0,
                    "recipient": "canmore.create_textdoc",
                    "content": {
                        "content_type": "text",
                        "parts": [json!({
                            "name": "Europa Notes",
                            "type": "document",
                            "content": "# Europa Ocean\n\nTidal flexing beneath the ice shell maintains liquid water."
                        }).to_string()]
                    }
                }
            },
            "node-a2": {
                "id": "node-a2",
                "parent": "node-canvas",
                "children": [],
                "message": {
                    "id": "node-a2",
                    "author": {"role": "assistant"},
                    "create_time": 1_777_000_060.0,
                    "recipient": "all",
                    "metadata": {"model_slug": "gpt-4o"},
                    "content": {"content_type": "text", "parts": ["Europa's ocean is warmed by tidal flexing."]}
                }
            }
        }
    }])
    .to_string();
    let zip_path = tree.write_zip("exports/chatgpt.zip", &[("conversations-000.json", &web_export)]);

    let scan = scan_source(
        "chatgpt",
        CHATGPT_KIND,
        &tree.0,
        &ScanOptions { include_code: false, policy: &WalkPolicy::default(), read_git: false, spotlight: None },
        &mut Ticker::new(None),
    );
    assert_eq!(scan.item_count, 2);

    let mut storage = MemorySessionStorage::default();
    let run = run_session_ingest(&tree.0, CHATGPT_KIND, "communication", &mut storage).expect("ingest");
    assert_eq!(run.counters.indexed, 3, "codex + chatgpt web + canvas companion");

    let codex_doc = &storage.docs[&codex_path.display().to_string()];
    let SessionWritePayload::Session(codex_rec) =
        SessionWritePayload::from_json(&serde_json::from_str(codex_doc.session_json.as_deref().unwrap()).unwrap())
            .unwrap()
    else {
        panic!("expected codex session");
    };
    assert_eq!(codex_rec.surface, "codex");
    assert_eq!(codex_rec.git_commit.as_deref(), Some("abc1234"));
    assert_eq!(codex_rec.primary_model.as_deref(), Some("gpt-5-codex"));
    assert_eq!(codex_rec.input_tokens, Some(500));
    assert_eq!(codex_rec.tool_calls.len(), 1);
    assert_eq!(codex_rec.tool_calls[0].tool_kind, "write");
    assert_eq!(codex_rec.tool_calls[0].target_path.as_deref(), Some("src/main.rs"));
    assert_eq!(codex_rec.tool_calls[0].status, "ok");

    let web_uri = format!("{}#conversations-000.json#cgpt-branch-1", zip_path.display());
    let web_doc = &storage.docs[&web_uri];
    assert!(web_doc.content.contains("Europa subsurface ocean"));
    assert!(web_doc.content.contains("warmed by tidal flexing"));
    assert!(!web_doc.content.contains("Abandoned Mars answer"), "inactive branch must not enter RAG chunks");
    assert!(!web_doc.content.contains("Mars dust storms"));

    let SessionWritePayload::Session(web_rec) =
        SessionWritePayload::from_json(&serde_json::from_str(web_doc.session_json.as_deref().unwrap()).unwrap())
            .unwrap()
    else {
        panic!("expected web session");
    };
    assert_eq!(web_rec.turns.len(), 5, "all 5 non-root mapping nodes preserved relationally");
    let inactive: Vec<&str> = web_rec
        .turns
        .iter()
        .filter(|t| t.active_ord.is_none())
        .map(|t| t.external_id.as_str())
        .collect();
    assert_eq!(inactive, vec!["node-u1", "node-a1", "node-canvas"]);
}

#[test]
fn antigravity_prefers_full_transcript_links_subagents_and_indexes_companions() {
    let tree = TempTree::new("antigravity");
    let full_steps = [
        json!({
            "step_index": 0,
            "source": "USER_EXPLICIT",
            "type": "USER_INPUT",
            "created_at": "2026-06-01T15:00:00Z",
            "content": "<user_information>\nActive Workspaces:\n- /Users/dev/garage-rag\n</user_information>\n<USER_REQUEST>\nImplement session storage\n</USER_REQUEST>"
        })
        .to_string(),
        json!({
            "step_index": 1,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "created_at": "2026-06-01T15:00:10Z",
            "thinking": "Delegating schema verification to research subagent.",
            "content": "Launching a subagent to inspect the schema.",
            "tool_calls": [{
                "id": "call_sub_1",
                "name": "invoke_subagent",
                "args": {"TypeName": "research", "Role": "Schema Reviewer", "Prompt": "Check 025_sessions.sql"}
            }]
        })
        .to_string(),
        json!({
            "step_index": 2,
            "source": "SYSTEM",
            "type": "TOOL_RESPONSE",
            "status": "DONE",
            "created_at": "2026-06-01T15:00:12Z",
            "content": "{\"conversationId\": \"child-conv-9999\"}"
        })
        .to_string(),
        json!({
            "step_index": 3,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "created_at": "2026-06-01T15:01:00Z",
            "content": "Session storage is ready and verified."
        })
        .to_string(),
    ]
    .join("\n");
    tree.write("brain/parent-conv-0001/.system_generated/logs/transcript_full.jsonl", &full_steps);
    // Compact transcript has truncated placeholder; parser must prefer transcript_full.jsonl.
    tree.write(
        "brain/parent-conv-0001/.system_generated/logs/transcript.jsonl",
        &json!({"step_index": 0, "type": "USER_INPUT", "content": "<USER_REQUEST>TRUNCATED_WRONG_FILE</USER_REQUEST>"})
            .to_string(),
    );
    tree.write(
        "brain/parent-conv-0001/implementation_plan.md",
        "# Session Ingestion Plan\n\nPersist turns, tool calls, and companion deliverables.",
    );
    tree.write(
        "brain/parent-conv-0001/implementation_plan.md.metadata.json",
        &json!({"artifactType": "ARTIFACT_TYPE_IMPLEMENTATION_PLAN", "summary": "Plan"}).to_string(),
    );
    tree.write("brain/parent-conv-0001/walkthrough.md", "# Walkthrough\n\nAll checks passed.");

    let child_steps = [
        json!({
            "step_index": 0,
            "source": "USER_EXPLICIT",
            "type": "USER_INPUT",
            "created_at": "2026-06-01T15:00:13Z",
            "content": "Check 025_sessions.sql"
        })
        .to_string(),
        json!({
            "step_index": 1,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "created_at": "2026-06-01T15:00:25Z",
            "content": "Verified foreign keys and cascade rules."
        })
        .to_string(),
    ]
    .join("\n");
    tree.write("brain/child-conv-9999/.system_generated/logs/transcript.jsonl", &child_steps);

    let scan = scan_source(
        "ag",
        ANTIGRAVITY_KIND,
        &tree.0,
        &ScanOptions { include_code: false, policy: &WalkPolicy::default(), read_git: false, spotlight: None },
        &mut Ticker::new(None),
    );
    assert_eq!(scan.item_count, 2);
    assert_eq!(scan.details.get("companion_artifacts").and_then(serde_json::Value::as_u64), Some(2));

    let mut storage = MemorySessionStorage::default();
    let run = run_session_ingest(&tree.0, ANTIGRAVITY_KIND, "communication", &mut storage).expect("ingest");
    assert_eq!(run.counters.indexed, 4, "2 conversations + 2 companion markdown deliverables");

    let parent_dir_uri = tree.0.join("brain/parent-conv-0001").display().to_string();
    let child_dir_uri = tree.0.join("brain/child-conv-9999").display().to_string();
    let parent_doc = &storage.docs[&parent_dir_uri];
    assert!(parent_doc.content.contains("Implement session storage"));
    assert!(!parent_doc.content.contains("<USER_REQUEST>"));
    assert!(!parent_doc.content.contains("TRUNCATED_WRONG_FILE"));

    let SessionWritePayload::Session(parent_rec) =
        SessionWritePayload::from_json(&serde_json::from_str(parent_doc.session_json.as_deref().unwrap()).unwrap())
            .unwrap()
    else {
        panic!("expected parent session");
    };
    assert_eq!(parent_rec.workspace_path.as_deref(), Some("/Users/dev/garage-rag"));
    assert_eq!(parent_rec.tool_calls.len(), 1);
    assert_eq!(parent_rec.tool_calls[0].tool_kind, "subagent");
    let kinds: HashMap<String, String> = parent_rec
        .artifacts
        .iter()
        .map(|a| (a.external_id.clone(), a.kind.clone()))
        .collect();
    assert_eq!(kinds.get("implementation_plan.md").map(String::as_str), Some("plan"));
    assert_eq!(kinds.get("walkthrough.md").map(String::as_str), Some("walkthrough"));

    let child_doc = &storage.docs[&child_dir_uri];
    let SessionWritePayload::Session(child_rec) =
        SessionWritePayload::from_json(&serde_json::from_str(child_doc.session_json.as_deref().unwrap()).unwrap())
            .unwrap()
    else {
        panic!("expected child session");
    };
    assert_eq!(child_rec.parent_external_id.as_deref(), Some("parent-conv-0001"));
}
