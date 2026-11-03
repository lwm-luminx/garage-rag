//! What the walker skips, as data: the tables `garage_rag.config`, `garage_rag.extract.dispatch`
//! and `garage_rag.ingest.classify` hold in Python. `tests/test_ingest_rust.py` holds the defaults
//! here to Python's, so the two cannot drift apart unnoticed.

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

/// Directory names never descended into (`config.DEFAULT_EXCLUDE_DIRS`).
pub const EXCLUDE_DIRS: &[&str] = &[
    ".build",
    ".cache",
    ".git",
    ".gradle",
    ".hg",
    ".mypy_cache",
    ".next",
    ".nuxt",
    ".pytest_cache",
    ".ruff_cache",
    ".svn",
    ".terraform",
    ".tox",
    ".venv",
    "Carthage",
    "Contents",
    "DerivedData",
    "Pods",
    "__fixtures__",
    "__pycache__",
    "__snapshots__",
    "build",
    "buildtools",
    "dist",
    "external",
    "fixtures",
    "golden",
    "goldens",
    "node_modules",
    "site-packages",
    "snapshots",
    "target",
    "test_data",
    "testdata",
    "third_party",
    "thirdparty",
    "vendor",
    "venv",
];

/// Package-manager caches, matched as a fragment of the path below the root
/// (`config.DEPENDENCY_PATH_FRAGMENTS`).
pub const DEPENDENCY_PATH_FRAGMENTS: &[&str] = &[
    "go/pkg/mod",
    ".cargo/registry",
    ".rustup/toolchains",
    ".pub-cache",
    ".gem/",
    ".nuget/",
    ".m2/repository",
    ".cocoapods/",
    "Library/Caches",
];

/// Diagnostic bundles, as patterns over directory names (`config.DIAGNOSTIC_DIR_PATTERNS`).
pub const DIAGNOSTIC_DIR_PATTERNS: &[&str] = &[
    "sysdiagnose_*",
    "*.logarchive",
    "*.xcresult",
    "*.crash",
    "DiagnosticReports",
    "CrashReporter",
    "ioreg",
    "logs",
    "Logs",
    "spindump*",
    "*.dSYM",
    "CoreSimulator",
    "Diagnostics",
];

/// Machine output whatever its extension, as patterns over file names
/// (`config.DIAGNOSTIC_FILE_PATTERNS`).
pub const DIAGNOSTIC_FILE_PATTERNS: &[&str] = &[
    "*.hash.txt",
    "*.sha.txt",
    "*.sha256*",
    "*.md5",
    "apticket*",
    "*.der.txt",
    "*.plist.txt",
    "spindump*.txt",
    "pmset*.txt",
    "taskinfo*.txt",
    "launchctl*.txt",
    "*_status.txt",
    "ps.txt",
    "netstat*.txt",
    "vm_stat*.txt",
    "system_profiler*.txt",
    "*.stackshot",
    "*.ips",
    "*.diag",
    "*.panic",
];

/// Source code (`dispatch.CODE_EXTENSIONS`), skipped unless a source includes code.
pub const CODE_EXTENSIONS: &[&str] = &[
    ".asm",
    ".bash",
    ".c",
    ".cc",
    ".cfg",
    ".cjs",
    ".cmake",
    ".conf",
    ".cpp",
    ".cs",
    ".css",
    ".csv",
    ".cxx",
    ".dart",
    ".dockerfile",
    ".erl",
    ".ex",
    ".exs",
    ".fish",
    ".fs",
    ".go",
    ".gql",
    ".gradle",
    ".graphql",
    ".h",
    ".hcl",
    ".hh",
    ".hpp",
    ".hs",
    ".htm",
    ".html",
    ".ini",
    ".java",
    ".jl",
    ".js",
    ".json",
    ".jsonl",
    ".jsx",
    ".kt",
    ".kts",
    ".less",
    ".lua",
    ".m",
    ".makefile",
    ".mjs",
    ".ml",
    ".mm",
    ".ndjson",
    ".nim",
    ".php",
    ".pl",
    ".pm",
    ".properties",
    ".proto",
    ".ps1",
    ".py",
    ".pyi",
    ".r",
    ".rb",
    ".rs",
    ".s",
    ".sass",
    ".scala",
    ".scss",
    ".sh",
    ".sql",
    ".sv",
    ".svelte",
    ".svg",
    ".swift",
    ".tf",
    ".toml",
    ".ts",
    ".tsv",
    ".tsx",
    ".v",
    ".vb",
    ".vhd",
    ".vue",
    ".xml",
    ".yaml",
    ".yml",
    ".zig",
    ".zsh",
];

/// Everything a built-in reader opens (`dispatch.INDEXABLE_EXTENSIONS`).
pub const INDEXABLE_EXTENSIONS: &[&str] = &[
    ".adoc",
    ".asciidoc",
    ".asm",
    ".avif",
    ".bash",
    ".bmp",
    ".c",
    ".cc",
    ".cfg",
    ".cjs",
    ".cmake",
    ".conf",
    ".cpp",
    ".cs",
    ".css",
    ".csv",
    ".cxx",
    ".dart",
    ".dockerfile",
    ".docm",
    ".docx",
    ".eml",
    ".emlx",
    ".erl",
    ".ex",
    ".exs",
    ".fish",
    ".fs",
    ".gif",
    ".go",
    ".gql",
    ".gradle",
    ".graphql",
    ".h",
    ".hcl",
    ".heic",
    ".heif",
    ".hh",
    ".hif",
    ".hpp",
    ".hs",
    ".htm",
    ".html",
    ".ini",
    ".java",
    ".jl",
    ".jpeg",
    ".jpg",
    ".js",
    ".json",
    ".jsonl",
    ".jsx",
    ".kt",
    ".kts",
    ".less",
    ".lua",
    ".m",
    ".makefile",
    ".markdown",
    ".md",
    ".mdown",
    ".mdx",
    ".mjs",
    ".mkd",
    ".ml",
    ".mm",
    ".ndjson",
    ".nim",
    ".org",
    ".pdf",
    ".php",
    ".pl",
    ".pm",
    ".png",
    ".pptm",
    ".pptx",
    ".properties",
    ".proto",
    ".ps1",
    ".py",
    ".pyi",
    ".qmd",
    ".r",
    ".rb",
    ".rmd",
    ".rs",
    ".rst",
    ".s",
    ".sass",
    ".scala",
    ".scss",
    ".sh",
    ".sql",
    ".srt",
    ".sv",
    ".svelte",
    ".svg",
    ".swift",
    ".tex",
    ".text",
    ".tf",
    ".tif",
    ".tiff",
    ".toml",
    ".ts",
    ".tsv",
    ".tsx",
    ".txt",
    ".v",
    ".vb",
    ".vhd",
    ".vtt",
    ".vue",
    ".webp",
    ".xlsm",
    ".xlsx",
    ".xml",
    ".yaml",
    ".yml",
    ".zig",
    ".zsh",
];

/// Names with no extension that are read as code (`dispatch.NAMED_CODE_FILES`), lowercased.
pub const NAMED_CODE_FILES: &[&str] =
    &["brewfile", "dockerfile", "gemfile", "justfile", "makefile", "podfile", "rakefile", "vagrantfile"];

/// Extensions that stay documents inside a code tree (`classify._DOC_EXTENSIONS_IN_CODE_TREES`).
pub const DOC_EXTENSIONS: &[&str] = &[".adoc", ".asciidoc", ".markdown", ".md", ".mdx", ".org", ".pdf", ".rst", ".txt"];

/// Names that are documentation whatever their extension, unless it is code's
/// (`classify._DOC_STEMS`).
pub const DOC_STEMS: &[&str] = &[
    "architecture",
    "authors",
    "changelog",
    "changes",
    "codeowners",
    "contributing",
    "copying",
    "design",
    "history",
    "licence",
    "license",
    "news",
    "notice",
    "readme",
    "roadmap",
    "security",
    "todo",
];

/// The largest file read (`max_file_bytes`'s default, 64 MiB).
pub const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;

/// Dropbox's top-level folders of application bundles and binary objects
/// (`attribute.pathrules.EXCLUDED_PREFIXES`).
pub const DROPBOX_EXCLUDED_PREFIXES: &[&str] = &["Library/", "Objects/", "Software/", "Public/"];

/// The walker's rules. [`WalkPolicy::default`] is Python's; a host overrides what its settings
/// change (`max_file_bytes`, the extensions its reader plugins add).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalkPolicy {
    pub exclude_dirs: BTreeSet<String>,
    pub dependency_path_fragments: Vec<String>,
    pub diagnostic_dir_patterns: Vec<String>,
    pub diagnostic_file_patterns: Vec<String>,
    pub indexable_extensions: BTreeSet<String>,
    pub named_code_files: BTreeSet<String>,
    pub code_extensions: BTreeSet<String>,
    pub doc_extensions: BTreeSet<String>,
    pub doc_stems: BTreeSet<String>,
    pub max_file_bytes: u64,
}

fn owned<C: FromIterator<String>>(items: &[&str]) -> C {
    items.iter().map(|&item| item.to_owned()).collect()
}

impl Default for WalkPolicy {
    fn default() -> Self {
        Self {
            exclude_dirs: owned(EXCLUDE_DIRS),
            dependency_path_fragments: owned(DEPENDENCY_PATH_FRAGMENTS),
            diagnostic_dir_patterns: owned(DIAGNOSTIC_DIR_PATTERNS),
            diagnostic_file_patterns: owned(DIAGNOSTIC_FILE_PATTERNS),
            indexable_extensions: owned(INDEXABLE_EXTENSIONS),
            named_code_files: owned(NAMED_CODE_FILES),
            code_extensions: owned(CODE_EXTENSIONS),
            doc_extensions: owned(DOC_EXTENSIONS),
            doc_stems: owned(DOC_STEMS),
            max_file_bytes: MAX_FILE_BYTES,
        }
    }
}

/// Why a policy's JSON was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyError(pub String);

impl std::fmt::Display for PolicyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PolicyError {}

fn strings(key: &str, value: &Value) -> Result<Vec<String>, PolicyError> {
    let Value::Array(items) = value else {
        return Err(PolicyError(format!("policy.{key} is not a list")));
    };
    items
        .iter()
        .map(|item| {
            item.as_str().map(str::to_owned).ok_or_else(|| PolicyError(format!("policy.{key} holds a non-string")))
        })
        .collect()
}

impl WalkPolicy {
    /// The policy as JSON, each table under its field's name.
    pub fn to_json(&self) -> Value {
        json!({
            "exclude_dirs": self.exclude_dirs,
            "dependency_path_fragments": self.dependency_path_fragments,
            "diagnostic_dir_patterns": self.diagnostic_dir_patterns,
            "diagnostic_file_patterns": self.diagnostic_file_patterns,
            "indexable_extensions": self.indexable_extensions,
            "named_code_files": self.named_code_files,
            "code_extensions": self.code_extensions,
            "doc_extensions": self.doc_extensions,
            "doc_stems": self.doc_stems,
            "max_file_bytes": self.max_file_bytes,
        })
    }

    /// The default policy with the fields `overrides` names replaced.
    ///
    /// # Errors
    ///
    /// A field this policy does not have, or a value of the wrong shape.
    pub fn with_overrides(overrides: &Map<String, Value>) -> Result<Self, PolicyError> {
        let mut policy = Self::default();
        for (key, value) in overrides {
            match key.as_str() {
                "exclude_dirs" => policy.exclude_dirs = strings(key, value)?.into_iter().collect(),
                "dependency_path_fragments" => policy.dependency_path_fragments = strings(key, value)?,
                "diagnostic_dir_patterns" => policy.diagnostic_dir_patterns = strings(key, value)?,
                "diagnostic_file_patterns" => policy.diagnostic_file_patterns = strings(key, value)?,
                "indexable_extensions" => policy.indexable_extensions = strings(key, value)?.into_iter().collect(),
                "named_code_files" => policy.named_code_files = strings(key, value)?.into_iter().collect(),
                "code_extensions" => policy.code_extensions = strings(key, value)?.into_iter().collect(),
                "doc_extensions" => policy.doc_extensions = strings(key, value)?.into_iter().collect(),
                "doc_stems" => policy.doc_stems = strings(key, value)?.into_iter().collect(),
                "max_file_bytes" => {
                    policy.max_file_bytes = value
                        .as_u64()
                        .ok_or_else(|| PolicyError("policy.max_file_bytes is not a whole number".to_owned()))?;
                }
                other => return Err(PolicyError(format!("the policy has no field {other:?}"))),
            }
        }
        Ok(policy)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_json_round_trips() {
        let Value::Object(json) = WalkPolicy::default().to_json() else { panic!("not an object") };
        assert_eq!(WalkPolicy::with_overrides(&json).unwrap(), WalkPolicy::default());
    }

    #[test]
    fn an_unknown_field_is_refused() {
        let overrides = json!({"max_bytes": 1});
        assert!(WalkPolicy::with_overrides(overrides.as_object().unwrap()).is_err());
    }
}
