//! The ingest pieces' C ABI, declared in `include/garage_ingest.h`: each call takes a JSON request
//! and fills `result` with JSON, which Swift, .NET and Python's ctypes read without generated code.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};

use garage_ingest::{WalkOptions, WalkPolicy, WalkStats, Walked};
use serde_json::{Map, Value, json};

/// The call succeeded; the result is its JSON.
pub const GARAGE_INGEST_OK: i32 = 0;
/// The request was not valid JSON of the expected shape, or a pointer was null.
pub const GARAGE_INGEST_BAD_REQUEST: i32 = 1;
/// The library panicked. The process is unharmed.
pub const GARAGE_INGEST_PANIC: i32 = 2;

type Outcome = Result<Value, String>;

/// Parses `request`, runs `work` on it and writes its JSON (or `{"error": ...}`) to `*result`.
fn call(request: *const c_char, result: *mut *mut c_char, work: impl FnOnce(&Map<String, Value>) -> Outcome) -> i32 {
    let (status, value) = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() {
            return (GARAGE_INGEST_BAD_REQUEST, json!({ "error": "the request pointer was null" }));
        }
        // SAFETY: the caller passes a NUL-terminated string.
        let request = unsafe { CStr::from_ptr(request) };
        let request = match serde_json::from_slice::<Value>(request.to_bytes()) {
            Ok(Value::Object(request)) => request,
            Ok(_) => return (GARAGE_INGEST_BAD_REQUEST, json!({ "error": "the request is not a JSON object" })),
            Err(error) => {
                return (GARAGE_INGEST_BAD_REQUEST, json!({ "error": format!("the request is not JSON: {error}") }));
            }
        };
        match work(&request) {
            Ok(value) => (GARAGE_INGEST_OK, value),
            Err(error) => (GARAGE_INGEST_BAD_REQUEST, json!({ "error": error })),
        }
    }))
    .unwrap_or_else(|panic| {
        let message = panic
            .downcast_ref::<&str>()
            .map(|text| (*text).to_owned())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "the ingest library panicked".to_owned());
        (GARAGE_INGEST_PANIC, json!({ "error": message }))
    });
    if !result.is_null() {
        let text = CString::new(value.to_string()).unwrap_or_default();
        // SAFETY: the caller passes a writable pointer.
        unsafe { *result = text.into_raw() };
    }
    status
}

fn root(request: &Map<String, Value>) -> Result<PathBuf, String> {
    request
        .get("root")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| "the request has no \"root\" string".to_owned())
}

fn walk(request: &Map<String, Value>) -> Outcome {
    let root = root(request)?;
    let policy = match request.get("policy") {
        None | Some(Value::Null) => WalkPolicy::default(),
        Some(Value::Object(overrides)) => WalkPolicy::with_overrides(overrides).map_err(|error| error.to_string())?,
        Some(_) => return Err("\"policy\" is not an object".to_owned()),
    };
    let include_code = request.get("include_code").and_then(Value::as_bool).unwrap_or(false);
    let expanded = garage_ingest::walk::expand_home(&root);
    let exclude_prefixes = match request.get("exclude_prefixes") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::String(word)) if word == "default" => garage_ingest::default_exclude_prefixes(&expanded),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str().map(str::to_owned).ok_or_else(|| "\"exclude_prefixes\" holds a non-string".to_owned())
            })
            .collect::<Result<_, _>>()?,
        Some(_) => return Err("\"exclude_prefixes\" is not a list or \"default\"".to_owned()),
    };
    let options = WalkOptions { include_code, exclude_prefixes };
    let mut stats = WalkStats::default();
    let mut candidates = Vec::new();
    let walked = garage_ingest::walk(&root, &policy, &options, &mut stats, |candidate| {
        candidates.push(json!({
            "path": candidate.path.to_string_lossy(),
            "size": candidate.size,
            "mtime": candidate.mtime,
            "placeholder": candidate.placeholder,
        }));
    });
    let stats: Map<String, Value> =
        stats.fields().iter().map(|&(name, count)| (name.to_owned(), json!(count))).collect();
    Ok(json!({
        "walked": walked == Walked::Walked,
        "root": expanded.to_string_lossy(),
        "exclude_prefixes": options.exclude_prefixes,
        "candidates": candidates,
        "stats": stats,
    }))
}

fn assess(request: &Map<String, Value>) -> Outcome {
    let text = request.get("text").and_then(Value::as_str).ok_or("the request has no \"text\" string")?;
    let sample_chars = match request.get("sample_chars") {
        None | Some(Value::Null) => garage_ingest::quality::SAMPLE_CHARS,
        Some(value) => value
            .as_u64()
            .and_then(|count| usize::try_from(count).ok())
            .ok_or("\"sample_chars\" is not a whole number")?,
    };
    let verdict = garage_ingest::assess(text, sample_chars);
    let metrics: Map<String, Value> =
        verdict.metrics.iter().map(|&(name, value)| (name.to_owned(), json!(value))).collect();
    Ok(json!({
        "machine_generated": verdict.machine_generated,
        "reasons": verdict.reasons,
        "reason_text": verdict.reason_text(),
        "metrics": metrics,
    }))
}

/// The default walk policy: `{}` -> `{"exclude_dirs": [...], ..., "max_file_bytes": n}`.
///
/// # Safety
///
/// `request` is a NUL-terminated string and `result` a writable pointer; free `*result` with
/// [`garage_ingest_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_policy(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, |_| Ok(WalkPolicy::default().to_json()))
}

/// Walks a source: `{"root", "include_code"?, "exclude_prefixes"?: [..] | "default", "policy"?}`
/// -> `{"walked", "root", "exclude_prefixes", "candidates": [{"path", "size", "mtime",
/// "placeholder"}], "stats": {...}}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_walk(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, walk)
}

/// Why a source's root cannot be walked: `{"root"}` -> `{"problem": string | null}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_root_problem(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, |request| Ok(json!({ "problem": garage_ingest::root_problem(Path::new(&root(request)?)) })))
}

/// The quality gate: `{"text", "sample_chars"?}` -> `{"machine_generated", "reasons",
/// "reason_text", "metrics": {...}}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_assess(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, assess)
}

/// Frees a string this library returned. Null is ignored.
///
/// # Safety
///
/// `text` is null or a string one of this library's calls returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the caller's contract: a string this library made with CString::into_raw.
        drop(unsafe { CString::from_raw(text) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(entry: unsafe extern "C" fn(*const c_char, *mut *mut c_char) -> i32, request: &str) -> (i32, Value) {
        let request = CString::new(request).unwrap();
        let mut result: *mut c_char = std::ptr::null_mut();
        // SAFETY: a valid request and out-pointer.
        let status = unsafe { entry(request.as_ptr(), &raw mut result) };
        // SAFETY: the library returned it.
        let text = unsafe { CStr::from_ptr(result) }.to_str().unwrap().to_owned();
        // SAFETY: as above, freed once.
        unsafe { garage_ingest_string_free(result) };
        (status, serde_json::from_str(&text).unwrap())
    }

    #[test]
    fn assess_answers_with_a_verdict() {
        let (status, verdict) = run(garage_ingest_assess, r#"{"text": "one line"}"#);
        assert_eq!(status, GARAGE_INGEST_OK);
        assert_eq!(verdict["machine_generated"], false);
        assert_eq!(verdict["reason_text"], "looks human-authored");
        assert_eq!(verdict["metrics"]["lines"], 1.0);
    }

    #[test]
    fn a_bad_request_says_why() {
        let (status, reply) = run(garage_ingest_walk, "[]");
        assert_eq!(status, GARAGE_INGEST_BAD_REQUEST);
        assert_eq!(reply["error"], "the request is not a JSON object");
        let (status, reply) = run(garage_ingest_walk, r#"{"root": "/", "policy": {"nope": 1}}"#);
        assert_eq!(status, GARAGE_INGEST_BAD_REQUEST);
        assert!(reply["error"].as_str().unwrap().contains("nope"));
    }

    #[test]
    fn a_missing_root_is_a_problem() {
        let (status, reply) = run(garage_ingest_root_problem, r#"{"root": "/no/such/garage/root"}"#);
        assert_eq!(status, GARAGE_INGEST_OK);
        assert_eq!(reply["problem"], "path does not exist: /no/such/garage/root");
    }
}
