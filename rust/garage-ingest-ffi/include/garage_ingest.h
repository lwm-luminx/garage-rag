// Garage's ingest pieces in Rust, linked in-process: the file walker, the quality gate, chunking,
// materializing placeholders, attribution, git history and the per-file decisions of the ingest loop,
// ported from garage_rag.ingest and garage_rag.extract.quality.
//
// Each call takes a NUL-terminated UTF-8 JSON request and sets `*result` to a JSON string the
// library owns; free it with garage_ingest_string_free. A status other than GARAGE_INGEST_OK means
// the result is {"error": "..."}. Every call is thread-safe and touches nothing but the files it
// is asked about.
//
// Built from rust/garage-ingest-ffi: libgarage_ingest_ffi.a (static, for the Mac app) and
// libgarage_ingest_ffi.{dylib,so,dll} (shared, for .NET and Python).

#ifndef GARAGE_INGEST_H
#define GARAGE_INGEST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The call succeeded; the result is its JSON.
#define GARAGE_INGEST_OK 0
// The request was not a JSON object of the expected shape, or a pointer was null.
#define GARAGE_INGEST_BAD_REQUEST 1
// The library panicked. The process is unharmed.
#define GARAGE_INGEST_PANIC 2

// The walker's default rules, Python's: {} -> {"exclude_dirs": [...], "dependency_path_fragments",
// "diagnostic_dir_patterns", "diagnostic_file_patterns", "indexable_extensions", "named_code_files",
// "code_extensions", "doc_extensions", "doc_stems", "max_file_bytes"}.
int32_t garage_ingest_policy(const char *request, char **result);

// Walks a source's folder, opening nothing.
//   {"root": "~/Documents", "include_code": false,
//    "exclude_prefixes": ["Library/"] | "default",   // "default": Dropbox's, for a Dropbox root
//    "policy": {"max_file_bytes": 1048576, ...}}     // fields replacing the defaults
// -> {"walked": true,                               // false: the root is inside a .git directory
//     "root": "/Users/me/Documents", "exclude_prefixes": [...],
//     "candidates": [{"path", "size", "mtime", "placeholder"}],
//     "stats": {"dirs", "files_seen", "yielded", "skipped_extension", "skipped_excluded_dir",
//               "skipped_code", "skipped_too_large", "skipped_diagnostic", "placeholders",
//               "unreadable"}}
int32_t garage_ingest_walk(const char *request, char **result);

// Why a root cannot be walked: {"root"} -> {"problem": "path does not exist: ..." | null}.
int32_t garage_ingest_root_problem(const char *request, char **result);

// Counts a source's items (garage_rag.ingest.scanner.scan_source): {"root", "kind": "filesystem" | "git" |
// "sqlite" | "maildir" | "feed", "source_slug", "include_code", "read_git": true, "policy"} ->
// {"source_slug", "kind", "root", "item_count", "item_type", "details", "duration_seconds", "error"}.
int32_t garage_ingest_scan(const char *request, char **result);

// The quality gate: {"text", "sample_chars": 65536} ->
// {"machine_generated", "reasons": [...], "reason_text", "metrics": {"lines", ...}}.
int32_t garage_ingest_assess(const char *request, char **result);

// Chunks a document's text as garage_rag.ingest.chunking does:
//   {"text", "kind": "prose" | "markdown" | "code" | "tabular" | "conversation" | "image",
//    "extension": ".py",                  // for code: picks the language's separators
//    "size": 1000, "overlap": 100}        // chunk_size/chunk_overlap, or the code_ ones for code
// -> {"chunks": [{"ord", "text", "chunker", "heading_path", "char_start", "char_end"}]}
// Offsets are in characters (Unicode code points), null when the chunk was not found in the text.
int32_t garage_ingest_chunk(const char *request, char **result);

// Attributes a file as garage_rag.attribute.resolver.resolve does:
//   {"path", "source_root", "default_trust": "authored" | "reference" | "received",
//    "author_hints": [...],                 // embedded authors, or a message's senders
//    "communication": false,               // true: hints are senders
//    "self": {"name", "identities": ["git_email:ada@example.com", ...]},
//    "repos": {"<repo root>": {"remote": "...", "by_path": {"<relative>": [[name, email, commits]]}}},
//    "read_git": false}
// -> {"trust", "authors": [{"name", "email", "role", "confidence", "evidence"}], "evidence", "meta"}
// With "read_git": true the library reads each repository's history through libgit2, once per
// process, and "repos" is ignored; otherwise a repository missing from "repos" has none.
int32_t garage_ingest_attribute(const char *request, char **result);

// Makes a cloud placeholder local within a budget, as garage_rag.ingest.materialize.ensure_local does:
//   {"path", "budget": {"enabled", "max_files", "max_bytes", "timeout_seconds",   // 0 = unlimited
//                       "files_done", "bytes_done", "deferred", "failed"}}       // the run so far
// -> {"outcome": "local" | "deferred" | "failed", "message": "..." | null,
//     "budget": {... the same fields, updated, "exhausted", "summary"}, "stalled": n}
// Pass the returned budget to the next call. The download runs on its own thread with macOS's
// dataless-file policy on; a read past its timeout is left running and counted in "stalled".
int32_t garage_ingest_ensure_local(const char *request, char **result);

// Reads a repository in-process through libgit2, as the app's _garage_git module does; no git
// command runs and nothing connects anywhere. A repository libgit2 cannot read answers
// GARAGE_INGEST_BAD_REQUEST with {"error"}.
//   garage_ingest_git_history: {"root", "max_commits"?} -> {"commits": [[name, email, [path, ...]]]},
//     as `git log --no-merges --no-renames --name-only` with .mailmap applied, newest first
//   garage_ingest_git_remote:  {"root", "name"?: "origin"} -> {"url": "..." | null}
//   garage_ingest_git_tracked: {"root"} -> {"count"}, the files `git ls-files` lists
int32_t garage_ingest_git_history(const char *request, char **result);
int32_t garage_ingest_git_remote(const char *request, char **result);
int32_t garage_ingest_git_tracked(const char *request, char **result);

// What ingest does with one file (garage_rag.ingest.pipeline.ingest_one), decided from what the
// request says about it: its stat in the database ("existing"), the walk's candidate, whether it is
// local ("local"), its bytes' hash ("source_sha256") and what its reader made of it ("read": a
// document, "no_text", "placeholder" or "failed"), with the settings, source, owner, contact names and
// git history ("repos" or "read_git") attribution reads. The reply is the facade calls Python makes, in
// order ({"calls": [{"method", ...}]}), and the counters they move. With "facade" ({"socket", or "host" and
// "port"; "token", "run_id", "source_slug"}) the stat comes from GarageService's CheckDocumentStat and each
// call is made there as PersistDocument; the reply is then the counters, with "error" when a call failed.
int32_t garage_ingest_ingest_one(const char *request, char **result);

// Runs one walked source (garage_rag.ingest.pipeline._ingest_source) through GarageService ("facade":
// {"socket", or "host" and "port"; "token", "source_slug"}): BeginIngestSession, PersistScan, each file's
// CheckDocumentStat and PersistDocument, and FinalizeIngestSession. The source is scanned as garage_ingest_scan
// does unless the request states the outcome ("scan"). What each file reads ("files", by path under the root,
// as for garage_ingest_ingest_one) comes with the request. The reply holds the run id, counters, walk stats,
// whether the walk completed and the progress reports, or "unavailable" when the root cannot be read and "error" when a run-wide call failed.
int32_t garage_ingest_ingest_source(const char *request, char **result);

// Frees a string one of the calls above returned. Null is ignored.
void garage_ingest_string_free(char *text);

#ifdef __cplusplus
}
#endif

#endif  // GARAGE_INGEST_H
