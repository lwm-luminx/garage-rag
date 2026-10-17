//! Garage's reader for plain text, Markdown and source code: `garage_rag.extract.text`, ported.
//!
//! The Python module is the specification, and `garage_python/tests/test_text_plugin.py` holds
//! this crate to it file by file. [`TextPlugin`] serves the reader through the plugin contract
//! (`proto/garage_plugin.proto`), in-process through `garage-text-ffi` or as the
//! `garage-text-plugin` process.

pub mod text;
pub mod yaml;

use garage_plugin::proto::{
    ContentKind, DescribeRequest, DescribeResponse, Document, ExtractRequest, ExtractResponse, Extractor, failure::Code,
};
use garage_plugin::{CONTRACT, Plugin};
use serde_json::{Map, Value as Json};

use crate::yaml::Value;

/// The plugin's name in `Describe`.
pub const PLUGIN_NAME: &str = "garage-text";

/// The extractors' version, recorded on every document they read. It is the Python module's
/// `VERSION`, because the output is the same: files the Python reader gave up on are not retried
/// just because this reader replaced it. Bump both together when the output changes.
pub const VERSION: &str = "1";

/// `MARKDOWN_EXTENSIONS` in `garage_rag.extract.dispatch`.
pub const MARKDOWN_EXTENSIONS: &[&str] = &[".md", ".markdown", ".mdown", ".mkd", ".mdx", ".qmd", ".rmd"];

/// `PLAINTEXT_EXTENSIONS` in `garage_rag.extract.dispatch`.
pub const PLAINTEXT_EXTENSIONS: &[&str] =
    &[".txt", ".text", ".rst", ".org", ".adoc", ".asciidoc", ".tex", ".srt", ".vtt"];

/// `CODE_EXTENSIONS` in `garage_rag.extract.dispatch`: source, and the structured configuration
/// and data that is grouped with it.
pub const CODE_EXTENSIONS: &[&str] = &[
    ".py",
    ".pyi",
    ".js",
    ".jsx",
    ".mjs",
    ".cjs",
    ".ts",
    ".tsx",
    ".c",
    ".h",
    ".cc",
    ".cpp",
    ".cxx",
    ".hpp",
    ".hh",
    ".m",
    ".mm",
    ".swift",
    ".java",
    ".kt",
    ".kts",
    ".scala",
    ".go",
    ".rs",
    ".rb",
    ".php",
    ".pl",
    ".pm",
    ".lua",
    ".sh",
    ".bash",
    ".zsh",
    ".fish",
    ".ps1",
    ".sql",
    ".r",
    ".jl",
    ".hs",
    ".ml",
    ".ex",
    ".exs",
    ".erl",
    ".cs",
    ".fs",
    ".vb",
    ".dart",
    ".zig",
    ".nim",
    ".html",
    ".htm",
    ".xml",
    ".svg",
    ".css",
    ".scss",
    ".sass",
    ".less",
    ".vue",
    ".svelte",
    ".proto",
    ".graphql",
    ".gql",
    ".tf",
    ".hcl",
    ".dockerfile",
    ".makefile",
    ".cmake",
    ".gradle",
    ".s",
    ".asm",
    ".v",
    ".sv",
    ".vhd",
    ".json",
    ".jsonl",
    ".ndjson",
    ".yaml",
    ".yml",
    ".toml",
    ".ini",
    ".cfg",
    ".conf",
    ".properties",
    ".csv",
    ".tsv",
];

/// `NAMED_CODE_FILES` in `garage_rag.extract.dispatch`: names with no extension worth reading.
pub const NAMED_CODE_FILES: &[&str] =
    &["makefile", "dockerfile", "rakefile", "gemfile", "podfile", "brewfile", "justfile", "vagrantfile"];

/// One of the three readers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Markdown,
    Plaintext,
    Code,
}

impl Kind {
    pub const ALL: [Kind; 3] = [Kind::Markdown, Kind::Plaintext, Kind::Code];

    /// The name recorded on documents, as the Python extractors record it.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Markdown => "markdown",
            Kind::Plaintext => "plaintext",
            Kind::Code => "code",
        }
    }

    pub fn from_name(name: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|kind| kind.name() == name)
    }

    /// The reader for a file name, as `extractor_for` routes it; `None` when none of the three
    /// reads it.
    pub fn for_file_name(file_name: &str) -> Option<Kind> {
        let suffix = text::split_extension(file_name).1.to_lowercase();
        if MARKDOWN_EXTENSIONS.contains(&suffix.as_str()) {
            Some(Kind::Markdown)
        } else if CODE_EXTENSIONS.contains(&suffix.as_str()) {
            Some(Kind::Code)
        } else if PLAINTEXT_EXTENSIONS.contains(&suffix.as_str()) {
            Some(Kind::Plaintext)
        } else if suffix.is_empty() && NAMED_CODE_FILES.contains(&file_name.to_lowercase().as_str()) {
            Some(Kind::Code)
        } else {
            None
        }
    }

    fn content_kind(self) -> ContentKind {
        match self {
            Kind::Markdown => ContentKind::Markdown,
            Kind::Plaintext => ContentKind::Prose,
            Kind::Code => ContentKind::Code,
        }
    }

    fn describe(self) -> Extractor {
        let (extensions, file_names): (&[&str], &[&str]) = match self {
            Kind::Markdown => (MARKDOWN_EXTENSIONS, &[]),
            Kind::Plaintext => (PLAINTEXT_EXTENSIONS, &[]),
            Kind::Code => (CODE_EXTENSIONS, NAMED_CODE_FILES),
        };
        Extractor {
            name: self.name().to_owned(),
            version: VERSION.to_owned(),
            extensions: extensions.iter().map(|&e| e.to_owned()).collect(),
            file_names: file_names.iter().map(|&n| n.to_owned()).collect(),
            kind: self.content_kind().into(),
        }
    }
}

/// What a reader made of a file, before it becomes a `Document`.
#[derive(Debug, Clone, PartialEq)]
pub struct Extracted {
    pub text: String,
    pub kind: Kind,
    pub title: Option<String>,
    /// A JSON object.
    pub meta: Map<String, Json>,
    pub author_hints: Vec<String>,
}

impl Extracted {
    /// Whether the text is empty or all whitespace, which the ingester records as no text.
    pub fn is_empty(&self) -> bool {
        text::py_strip(&self.text).is_empty()
    }
}

/// Reads a file with the given reader.
pub fn extract(kind: Kind, file_name: &str, content: &[u8]) -> Extracted {
    match kind {
        Kind::Markdown => extract_markdown(file_name, content),
        Kind::Plaintext => extract_plaintext(file_name, content),
        Kind::Code => extract_code(file_name, content),
    }
}

/// `extract_markdown`: front matter split off and mined for a title, author hints and metadata.
pub fn extract_markdown(file_name: &str, content: &[u8]) -> Extracted {
    let (raw, encoding) = text::decode(content);
    let (front, body) = split_front_matter(&raw);
    let text = text::normalize(body);

    let title = match lookup(&front, "title") {
        Some(Value::Str(title)) => Some(text::py_strip(title).to_owned()),
        _ => None,
    }
    .filter(|title| !title.is_empty())
    .or_else(|| text::guess_title(file_name, &text, true));

    let mut meta = Map::new();
    meta.insert("encoding".into(), encoding.into());
    if !front.is_empty() {
        // Only the JSON-safe scalars; front matter can hold any YAML.
        let scalars: Map<String, Json> =
            front.iter().filter_map(|(key, value)| Some((json_key(key)?, json_scalar(value)?))).collect();
        meta.insert("frontmatter".into(), Json::Object(scalars));
    }

    Extracted { text, kind: Kind::Markdown, title, meta, author_hints: author_hints(&front) }
}

/// `extract_plaintext`.
pub fn extract_plaintext(file_name: &str, content: &[u8]) -> Extracted {
    let (raw, encoding) = text::decode(content);
    let text = text::normalize(&raw);
    let title = text::guess_title(file_name, &text, false);
    let mut meta = Map::new();
    meta.insert("encoding".into(), encoding.into());
    Extracted { text, kind: Kind::Plaintext, title, meta, author_hints: Vec::new() }
}

/// `extract_code`: verbatim, since indentation and blank lines are structure.
pub fn extract_code(file_name: &str, content: &[u8]) -> Extracted {
    let (raw, encoding) = text::decode(content);
    let text = text::normalize_code(&raw);
    let mut meta = Map::new();
    meta.insert("encoding".into(), encoding.into());
    meta.insert("extension".into(), text::split_extension(file_name).1.to_lowercase().into());
    Extracted { text, kind: Kind::Code, title: Some(file_name.to_owned()), meta, author_hints: Vec::new() }
}

type FrontMatter = Vec<(Value, Value)>;

/// `split_frontmatter`: leading YAML between `---` lines, and the body after it. Empty front
/// matter and the whole text when there is none, when it does not parse, or when it is not a
/// mapping, so a malformed block never costs the body.
pub fn split_front_matter(text: &str) -> (FrontMatter, &str) {
    if !text.starts_with("---") {
        return (Vec::new(), text);
    }
    let mut lines = text.split('\n');
    if lines.next().map(text::py_strip) != Some("---") {
        return (Vec::new(), text);
    }
    // Where each line starts, to slice the block and the body out of `text` without copying.
    let mut start = text.find('\n').map_or(text.len(), |n| n + 1);
    let block_start = start;
    for (index, line) in lines.enumerate() {
        // The Python reader looks for the closing line among lines 1 to 199.
        if index + 1 >= 200 {
            break;
        }
        let end = start + line.len();
        if matches!(text::py_strip(line), "---" | "...") {
            // The block is the lines between, joined by "\n": no trailing newline.
            let block = &text[block_start..start.saturating_sub(1).max(block_start)];
            let body = text.get(end + 1..).unwrap_or("");
            return match yaml::parse(block) {
                Ok(Some(Value::Map(entries))) => (entries, body),
                _ => (Vec::new(), text),
            };
        }
        start = end + 1;
    }
    (Vec::new(), text)
}

fn lookup<'a>(front: &'a FrontMatter, key: &str) -> Option<&'a Value> {
    front.iter().find(|(k, _)| matches!(k, Value::Str(s) if s == key)).map(|(_, v)| v)
}

/// `_author_hints_from_frontmatter`.
fn author_hints(front: &FrontMatter) -> Vec<String> {
    let mut hints = Vec::new();
    for key in ["author", "authors", "by", "creator"] {
        match lookup(front, key) {
            Some(Value::Str(value)) => hints.push(value.clone()),
            Some(Value::Seq(items)) => {
                hints.extend(items.iter().filter(|item| item.is_truthy()).filter_map(Value::py_str));
            }
            _ => {}
        }
    }
    hints.iter().map(|hint| text::py_strip(hint)).filter(|hint| !hint.is_empty()).map(str::to_owned).collect()
}

/// A front-matter key as `json.dumps` writes a `dict` key.
fn json_key(key: &Value) -> Option<String> {
    match key {
        Value::Str(s) => Some(s.clone()),
        Value::Int(i) => Some(i.to_string()),
        Value::Float(f) => Some(yaml::py_float_repr(*f)),
        Value::Bool(b) => Some(b.to_string()),
        Value::Null => Some("null".to_owned()),
        Value::Timestamp(_) | Value::Seq(_) | Value::Map(_) => None,
    }
}

/// The values the Python reader keeps: `str`, `int`, `float` and `bool`. A non-finite float has no
/// JSON form and is dropped.
fn json_scalar(value: &Value) -> Option<Json> {
    match value {
        Value::Str(s) => Some(Json::from(s.as_str())),
        Value::Bool(b) => Some(Json::from(*b)),
        Value::Int(i) => i64::try_from(*i).map(Json::from).ok().or_else(|| u64::try_from(*i).map(Json::from).ok()),
        Value::Float(f) => serde_json::Number::from_f64(*f).map(Json::Number),
        Value::Null | Value::Timestamp(_) | Value::Seq(_) | Value::Map(_) => None,
    }
}

/// The text reader as a plugin.
#[derive(Debug, Default, Clone, Copy)]
pub struct TextPlugin;

impl Plugin for TextPlugin {
    fn describe(&self, _: &DescribeRequest) -> DescribeResponse {
        DescribeResponse {
            name: PLUGIN_NAME.to_owned(),
            version: env!("CARGO_PKG_VERSION").to_owned(),
            contract: CONTRACT.into(),
            extractors: Kind::ALL.into_iter().map(Kind::describe).collect(),
        }
    }

    fn extract(&self, request: ExtractRequest) -> ExtractResponse {
        let kind = if request.extractor.is_empty() {
            Kind::for_file_name(&request.file_name)
        } else {
            Kind::from_name(&request.extractor)
        };
        let Some(kind) = kind else {
            let what = if request.extractor.is_empty() { &request.file_name } else { &request.extractor };
            return ExtractResponse::failure(Code::Unsupported, format!("{PLUGIN_NAME} has no extractor for {what:?}"));
        };
        if request.content.is_empty() {
            return ExtractResponse::no_text(format!("empty file: {}", request.file_name));
        }
        let extracted = extract(kind, &request.file_name, &request.content);
        if extracted.is_empty() {
            return ExtractResponse::no_text(format!(
                "extractor {} produced no text: {}",
                kind.name(),
                request.file_name
            ));
        }
        ExtractResponse::document(Document {
            text: extracted.text,
            kind: kind.content_kind().into(),
            extractor: kind.name().to_owned(),
            extractor_version: VERSION.to_owned(),
            title: extracted.title,
            lang: None,
            meta_json: Json::Object(extracted.meta).to_string(),
            author_hints: extracted.author_hints,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use garage_plugin::proto::extract_response::Outcome;

    fn markdown(source: &str) -> Extracted {
        extract_markdown("note.md", source.as_bytes())
    }

    #[test]
    fn reads_front_matter() {
        let doc = markdown(
            "---\ntitle: '  My Note '\nauthor: Ada\nauthors: [Grace, '', 0, 7, yes]\ntags: [a]\ncount: 3\ndraft: no\nwhen: 2024-01-02\n---\n# Heading\nBody.\n",
        );
        assert_eq!(doc.title.as_deref(), Some("My Note"));
        assert_eq!(doc.text, "# Heading\nBody.");
        assert_eq!(doc.author_hints, ["Ada", "Grace", "7", "True"]);
        assert_eq!(
            Json::Object(doc.meta).to_string(),
            r#"{"encoding":"utf-8","frontmatter":{"title":"  My Note ","author":"Ada","count":3,"draft":false}}"#
        );
    }

    #[test]
    fn keeps_the_body_when_front_matter_is_bad() {
        let source = "---\ntitle: [unclosed\n---\nBody\n";
        let doc = markdown(source);
        assert_eq!(doc.text, "---\ntitle: [unclosed\n---\nBody");
        assert_eq!(doc.title.as_deref(), Some("---"));
        assert_eq!(doc.meta.len(), 1);
    }

    #[test]
    fn empty_or_scalar_front_matter_is_not_front_matter() {
        assert_eq!(markdown("---\n---\nBody\n").text, "---\n---\nBody");
        assert_eq!(markdown("---\njust text\n---\nBody\n").text, "---\njust text\n---\nBody");
    }

    #[test]
    fn front_matter_ends_with_dots_and_handles_crlf() {
        let doc = markdown("---\r\ntitle: T\r\n...\r\nBody\r\n");
        assert_eq!(doc.title.as_deref(), Some("T"));
        assert_eq!(doc.text, "Body");
    }

    #[test]
    fn falls_back_to_a_heading_then_a_line() {
        assert_eq!(markdown("intro\n# Real Title\n").title.as_deref(), Some("Real Title"));
        assert_eq!(markdown("---\ntitle: '  '\n---\nFirst line\n").title.as_deref(), Some("First line"));
    }

    #[test]
    fn utf8_bom_does_not_hide_front_matter() {
        let doc = extract_markdown("n.md", b"\xEF\xBB\xBF---\ntitle: X\n---\nbody");
        assert_eq!(doc.title.as_deref(), Some("X"));
        assert_eq!(doc.meta["encoding"], "utf-8-sig");
    }

    #[test]
    fn code_is_verbatim() {
        let doc = extract_code("Main.PY", b"def f():\r\n\r\n\r\n\r\n    return 1\0\n");
        assert_eq!(doc.text, "def f():\n\n\n\n    return 1\n");
        assert_eq!(doc.title.as_deref(), Some("Main.PY"));
        assert_eq!(doc.meta["extension"], ".py");
    }

    #[test]
    fn routes_like_dispatch() {
        assert_eq!(Kind::for_file_name("a.MD"), Some(Kind::Markdown));
        assert_eq!(Kind::for_file_name("a.txt"), Some(Kind::Plaintext));
        assert_eq!(Kind::for_file_name("a.rs"), Some(Kind::Code));
        assert_eq!(Kind::for_file_name("Makefile"), Some(Kind::Code));
        assert_eq!(Kind::for_file_name("makefile.bak"), None);
        assert_eq!(Kind::for_file_name("a.pdf"), None);
    }

    #[test]
    fn plugin_outcomes() {
        let extract = |extractor: &str, file_name: &str, content: &[u8]| {
            TextPlugin
                .extract(ExtractRequest {
                    extractor: extractor.into(),
                    file_name: file_name.into(),
                    content: content.to_vec(),
                })
                .outcome
                .unwrap()
        };
        let Outcome::Document(doc) = extract("", "a.md", b"# T\nbody") else { panic!() };
        assert_eq!((doc.extractor.as_str(), doc.kind), ("markdown", ContentKind::Markdown.into()));
        let Outcome::Document(doc) = extract("plaintext", "a.md", b"# T\nbody") else { panic!() };
        assert_eq!(doc.extractor, "plaintext");
        assert!(matches!(extract("", "a.txt", b"  \n\t"), Outcome::NoText(_)));
        assert!(matches!(extract("", "a.txt", b""), Outcome::NoText(_)));
        assert!(matches!(extract("", "a.pdf", b"%PDF"), Outcome::Failure(f) if f.code == Code::Unsupported as i32));
        assert!(matches!(extract("pdf", "a.txt", b"x"), Outcome::Failure(f) if f.code == Code::Unsupported as i32));
    }

    #[test]
    fn describes_its_extractors() {
        let described = TextPlugin.describe(&DescribeRequest::default());
        assert_eq!(described.name, "garage-text");
        let names: Vec<_> = described.extractors.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["markdown", "plaintext", "code"]);
        assert!(described.extractors[2].file_names.contains(&"makefile".to_owned()));
    }
}
