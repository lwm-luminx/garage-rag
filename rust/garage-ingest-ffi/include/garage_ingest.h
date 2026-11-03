// Garage's ingest pieces in Rust, linked in-process: the file walker and the quality gate, ported
// from garage_rag.ingest.walker and garage_rag.extract.quality.
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

// The quality gate: {"text", "sample_chars": 65536} ->
// {"machine_generated", "reasons": [...], "reason_text", "metrics": {"lines", ...}}.
int32_t garage_ingest_assess(const char *request, char **result);

// Frees a string one of the calls above returned. Null is ignored.
void garage_ingest_string_free(char *text);

#ifdef __cplusplus
}
#endif

#endif  // GARAGE_INGEST_H
