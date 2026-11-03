//! The text splitters, ported from `garage_rag.ingest.splitters` (itself a port of the parts of
//! langchain-text-splitters Garage used; MIT License, Copyright (c) LangChain, Inc.): the recursive
//! character splitter with its per-language separator tables, and the Markdown header splitter.
//!
//! Every quirk is kept, because a chunk that differs changes its hash and so its vectors. The
//! language tables are regular expressions, applied as Python's `re` applies them: `"$$"` in the
//! LaTeX table is an end-of-text anchor (it matches the empty string before a final newline and at
//! the end), and `"\n| "` in the Haskell table is an alternation. Lengths are in characters, as
//! Python's `len` counts them, and whitespace is `str.isspace`'s.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use regex::Regex;

/// `str.isspace`: White_Space plus the information separators U+001C to U+001F.
pub(crate) fn is_py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// `str.strip()`.
pub(crate) fn py_strip(text: &str) -> &str {
    text.trim_matches(is_py_space)
}

fn char_len(text: &str) -> usize {
    text.chars().count()
}

const C_FAMILY: &[&str] = &[
    "\nclass ",
    "\nvoid ",
    "\nint ",
    "\nfloat ",
    "\ndouble ",
    "\nif ",
    "\nfor ",
    "\nwhile ",
    "\nswitch ",
    "\ncase ",
    "\n\n",
    "\n",
    " ",
    "",
];

/// The separator tables, by the language name recorded in a chunker id (`code:<language>:...`).
/// Each entry is a regular expression in Python's syntax.
#[allow(clippy::too_many_lines)]
pub fn language_separators(language: &str) -> Option<&'static [&'static str]> {
    Some(match language {
        "python" => &["\nclass ", "\ndef ", "\n\tdef ", "\n\n", "\n", " ", ""],
        "js" => &[
            "\nfunction ",
            "\nconst ",
            "\nlet ",
            "\nvar ",
            "\nclass ",
            "\nif ",
            "\nfor ",
            "\nwhile ",
            "\nswitch ",
            "\ncase ",
            "\ndefault ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "ts" => &[
            "\nenum ",
            "\ninterface ",
            "\nnamespace ",
            "\ntype ",
            "\nclass ",
            "\nfunction ",
            "\nconst ",
            "\nlet ",
            "\nvar ",
            "\nif ",
            "\nfor ",
            "\nwhile ",
            "\nswitch ",
            "\ncase ",
            "\ndefault ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "c" | "cpp" => C_FAMILY,
        "go" => &[
            "\nfunc ",
            "\nvar ",
            "\nconst ",
            "\ntype ",
            "\nif ",
            "\nfor ",
            "\nswitch ",
            "\ncase ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "rust" => &[
            "\nfn ", "\nconst ", "\nlet ", "\nif ", "\nwhile ", "\nfor ", "\nloop ", "\nmatch ", "\nconst ", "\n\n",
            "\n", " ", "",
        ],
        "ruby" => &[
            "\ndef ",
            "\nclass ",
            "\nif ",
            "\nunless ",
            "\nwhile ",
            "\nfor ",
            "\ndo ",
            "\nbegin ",
            "\nrescue ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "php" => &[
            "\nfunction ",
            "\nclass ",
            "\nif ",
            "\nforeach ",
            "\nwhile ",
            "\ndo ",
            "\nswitch ",
            "\ncase ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "java" => &[
            "\nclass ",
            "\npublic ",
            "\nprotected ",
            "\nprivate ",
            "\nstatic ",
            "\nif ",
            "\nfor ",
            "\nwhile ",
            "\nswitch ",
            "\ncase ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "kotlin" => &[
            "\nclass ",
            "\npublic ",
            "\nprotected ",
            "\nprivate ",
            "\ninternal ",
            "\ncompanion ",
            "\nfun ",
            "\nval ",
            "\nvar ",
            "\nif ",
            "\nfor ",
            "\nwhile ",
            "\nwhen ",
            "\ncase ",
            "\nelse ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "scala" => &[
            "\nclass ",
            "\nobject ",
            "\ndef ",
            "\nval ",
            "\nvar ",
            "\nif ",
            "\nfor ",
            "\nwhile ",
            "\nmatch ",
            "\ncase ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "swift" => &[
            "\nfunc ",
            "\nclass ",
            "\nstruct ",
            "\nenum ",
            "\nif ",
            "\nfor ",
            "\nwhile ",
            "\ndo ",
            "\nswitch ",
            "\ncase ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "csharp" => &[
            "\ninterface ",
            "\nenum ",
            "\nimplements ",
            "\ndelegate ",
            "\nevent ",
            "\nclass ",
            "\nabstract ",
            "\npublic ",
            "\nprotected ",
            "\nprivate ",
            "\nstatic ",
            "\nreturn ",
            "\nif ",
            "\ncontinue ",
            "\nfor ",
            "\nforeach ",
            "\nwhile ",
            "\nswitch ",
            "\nbreak ",
            "\ncase ",
            "\nelse ",
            "\ntry ",
            "\nthrow ",
            "\nfinally ",
            "\ncatch ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "lua" => &["\nlocal ", "\nfunction ", "\nif ", "\nfor ", "\nwhile ", "\nrepeat ", "\n\n", "\n", " ", ""],
        "haskell" => &[
            "\nmain :: ",
            "\nmain = ",
            "\nlet ",
            "\nin ",
            "\ndo ",
            "\nwhere ",
            "\n:: ",
            "\n= ",
            "\ndata ",
            "\nnewtype ",
            "\ntype ",
            "\n:: ",
            "\nmodule ",
            "\nimport ",
            "\nqualified ",
            "\nimport qualified ",
            "\nclass ",
            "\ninstance ",
            "\ncase ",
            "\n| ",
            "\ndata ",
            "\n= {",
            "\n, ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "elixir" => &[
            "\ndef ",
            "\ndefp ",
            "\ndefmodule ",
            "\ndefprotocol ",
            "\ndefmacro ",
            "\ndefmacrop ",
            "\nif ",
            "\nunless ",
            "\nwhile ",
            "\ncase ",
            "\ncond ",
            "\nwith ",
            "\nfor ",
            "\ndo ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "html" => &[
            "<body", "<div", "<p", "<br", "<li", "<h1", "<h2", "<h3", "<h4", "<h5", "<h6", "<span", "<table", "<tr",
            "<td", "<th", "<ul", "<ol", "<header", "<footer", "<nav", "<head", "<style", "<script", "<meta", "<title",
            "",
        ],
        "latex" => &[
            "\n\\\\chapter{",
            "\n\\\\section{",
            "\n\\\\subsection{",
            "\n\\\\subsubsection{",
            "\n\\\\begin{enumerate}",
            "\n\\\\begin{itemize}",
            "\n\\\\begin{description}",
            "\n\\\\begin{list}",
            "\n\\\\begin{quote}",
            "\n\\\\begin{quotation}",
            "\n\\\\begin{verse}",
            "\n\\\\begin{verbatim}",
            "\n\\\\begin{align}",
            "$$",
            "$",
            " ",
            "",
        ],
        "sol" => &[
            "\npragma ",
            "\nusing ",
            "\ncontract ",
            "\ninterface ",
            "\nlibrary ",
            "\nconstructor ",
            "\ntype ",
            "\nfunction ",
            "\nevent ",
            "\nmodifier ",
            "\nerror ",
            "\nstruct ",
            "\nenum ",
            "\nif ",
            "\nfor ",
            "\nwhile ",
            "\ndo while ",
            "\nassembly ",
            "\n\n",
            "\n",
            " ",
            "",
        ],
        "cobol" => &[
            "\nIDENTIFICATION DIVISION.",
            "\nENVIRONMENT DIVISION.",
            "\nDATA DIVISION.",
            "\nPROCEDURE DIVISION.",
            "\nWORKING-STORAGE SECTION.",
            "\nLINKAGE SECTION.",
            "\nFILE SECTION.",
            "\nINPUT-OUTPUT SECTION.",
            "\nOPEN ",
            "\nCLOSE ",
            "\nREAD ",
            "\nWRITE ",
            "\nIF ",
            "\nELSE ",
            "\nMOVE ",
            "\nPERFORM ",
            "\nUNTIL ",
            "\nVARYING ",
            "\nACCEPT ",
            "\nDISPLAY ",
            "\nSTOP RUN.",
            "\n",
            " ",
            "",
        ],
        _ => return None,
    })
}

/// Every language with a separator table.
pub const LANGUAGES: &[&str] = &[
    "python", "js", "ts", "c", "cpp", "go", "rust", "ruby", "php", "java", "kotlin", "scala", "swift", "csharp", "lua",
    "haskell", "elixir", "html", "latex", "sol", "cobol",
];

/// One separator, compiled.
#[derive(Debug, Clone)]
enum Separator {
    /// The empty separator: split into characters.
    Characters,
    /// A pattern made only of `$`: Python's end anchor, which matches the empty string before a
    /// final newline and at the end of the text.
    End,
    Pattern(Regex),
}

impl Separator {
    fn new(separator: &str, is_regex: bool) -> Result<Self, String> {
        if separator.is_empty() {
            return Ok(Self::Characters);
        }
        if !is_regex {
            return Regex::new(&regex::escape(separator)).map(Self::Pattern).map_err(|error| error.to_string());
        }
        if separator.chars().all(|c| c == '$') {
            return Ok(Self::End);
        }
        // Python reads a brace that starts no repetition as a literal; Rust's regex refuses it, and
        // no table holds a repetition.
        let pattern = separator.replace('{', "\\{").replace('}', "\\}");
        Regex::new(&pattern).map(Self::Pattern).map_err(|error| error.to_string())
    }

    /// The (start, end) byte ranges of each match, as `re.finditer` finds them.
    fn matches(&self, text: &str) -> Vec<(usize, usize)> {
        match self {
            Self::Characters => Vec::new(),
            Self::End => {
                let mut found = Vec::new();
                if text.ends_with('\n') {
                    found.push((text.len() - 1, text.len() - 1));
                }
                found.push((text.len(), text.len()));
                found
            }
            Self::Pattern(regex) => regex.find_iter(text).map(|found| (found.start(), found.end())).collect(),
        }
    }

    fn found_in(&self, text: &str) -> bool {
        match self {
            Self::Characters | Self::End => true,
            Self::Pattern(regex) => regex.is_match(text),
        }
    }

    /// Splits on the separator, each separator kept at the start of the piece after it; empty
    /// pieces are dropped (`splitters._split_keeping_separator`).
    fn split<'a>(&self, text: &'a str) -> Vec<&'a str> {
        if matches!(self, Self::Characters) {
            return text.char_indices().map(|(index, c)| &text[index..index + c.len_utf8()]).collect();
        }
        let mut pieces = Vec::new();
        let mut found = self.matches(text).into_iter().peekable();
        // `re.split` with a group gives text, separator, text, ..., text; each separator joins the
        // text after it, which runs to the next separator's start.
        let first_end = found.peek().map_or(text.len(), |&(start, _)| start);
        pieces.push(&text[..first_end]);
        while let Some((start, _)) = found.next() {
            let next = found.peek().map_or(text.len(), |&(next_start, _)| next_start);
            pieces.push(&text[start..next.max(start)]);
        }
        pieces.into_iter().filter(|piece| !piece.is_empty()).collect()
    }
}

static BLANK_LINES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\A(?:[ \t]*\r?\n)+").expect("compiles"));

/// `text` stripped, except that a first line after a line break keeps its indentation
/// (`splitters.strip_keeping_indent`).
pub fn strip_keeping_indent(text: &str) -> &str {
    match BLANK_LINES.find(text) {
        Some(blank) => text[blank.end()..].trim_end_matches(is_py_space),
        None => py_strip(text),
    }
}

/// Why a splitter could not be made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitterError(pub String);

impl std::fmt::Display for SplitterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SplitterError {}

/// Splits on the first separator present, recursing into pieces still too long, then packs the
/// pieces back up to `chunk_size` characters with up to `chunk_overlap` carried into the next.
#[derive(Debug, Clone)]
pub struct RecursiveSplitter {
    chunk_size: usize,
    chunk_overlap: usize,
    separators: Vec<Separator>,
    keep_indent: bool,
}

impl RecursiveSplitter {
    /// # Errors
    ///
    /// A size of 0, an overlap larger than the size, or a separator that does not compile.
    pub fn new(
        chunk_size: usize,
        chunk_overlap: usize,
        separators: &[&str],
        is_separator_regex: bool,
        keep_indent: bool,
    ) -> Result<Self, SplitterError> {
        if chunk_size == 0 {
            return Err(SplitterError(format!("chunk_size must be > 0, got {chunk_size}")));
        }
        if chunk_overlap > chunk_size {
            return Err(SplitterError(format!(
                "chunk_overlap ({chunk_overlap}) is larger than chunk_size ({chunk_size})"
            )));
        }
        let separators = separators
            .iter()
            .map(|separator| Separator::new(separator, is_separator_regex).map_err(SplitterError))
            .collect::<Result<_, _>>()?;
        Ok(Self { chunk_size, chunk_overlap, separators, keep_indent })
    }

    /// The splitter for a language's table, or None for a language without one.
    ///
    /// # Errors
    ///
    /// As [`RecursiveSplitter::new`].
    pub fn for_language(
        language: &str,
        chunk_size: usize,
        chunk_overlap: usize,
    ) -> Result<Option<Self>, SplitterError> {
        language_separators(language)
            .map(|separators| Self::new(chunk_size, chunk_overlap, separators, true, false))
            .transpose()
    }

    pub fn split_text(&self, text: &str) -> Vec<String> {
        self.split(text, &self.separators)
    }

    fn split(&self, text: &str, separators: &[Separator]) -> Vec<String> {
        let mut separator = &separators[separators.len() - 1];
        let mut remaining: &[Separator] = &[];
        for (index, candidate) in separators.iter().enumerate() {
            if matches!(candidate, Separator::Characters) {
                separator = candidate;
                break;
            }
            if candidate.found_in(text) {
                separator = candidate;
                remaining = &separators[index + 1..];
                break;
            }
        }

        let mut chunks = Vec::new();
        let mut short: Vec<&str> = Vec::new();
        for piece in separator.split(text) {
            if char_len(piece) < self.chunk_size {
                short.push(piece);
                continue;
            }
            if !short.is_empty() {
                chunks.extend(self.merge(&short));
                short.clear();
            }
            if remaining.is_empty() {
                chunks.push(piece.to_owned());
            } else {
                chunks.extend(self.split(piece, remaining));
            }
        }
        if !short.is_empty() {
            chunks.extend(self.merge(&short));
        }
        chunks
    }

    fn strip<'a>(&self, text: &'a str) -> &'a str {
        if self.keep_indent { strip_keeping_indent(text) } else { py_strip(text) }
    }

    fn merge(&self, splits: &[&str]) -> Vec<String> {
        let mut docs = Vec::new();
        let mut current: std::collections::VecDeque<(&str, usize)> = std::collections::VecDeque::new();
        let mut total = 0;
        for &piece in splits {
            let length = char_len(piece);
            if total + length > self.chunk_size && !current.is_empty() {
                let joined: String = current.iter().map(|&(text, _)| text).collect();
                let doc = self.strip(&joined);
                if !doc.is_empty() {
                    docs.push(doc.to_owned());
                }
                while total > self.chunk_overlap || (total + length > self.chunk_size && total > 0) {
                    let (_, first) = current.pop_front().expect("total > 0 means a piece is held");
                    total -= first;
                }
            }
            current.push_back((piece, length));
            total += length;
        }
        let joined: String = current.iter().map(|&(text, _)| text).collect();
        let doc = self.strip(&joined);
        if !doc.is_empty() {
            docs.push(doc.to_owned());
        }
        docs
    }
}

/// A run of Markdown under one heading path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownSection {
    pub content: String,
    /// The heading text above it, under the names the splitter was given (`h1`, `h2`, ...).
    pub metadata: BTreeMap<String, String>,
}

// What `str.isprintable` refuses: categories Cc, Cf, Cs, Co, Cn, Zl, Zp and Zs, but the space.
static NONPRINTABLE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[\p{Cc}\p{Cf}\p{Co}\p{Cn}\p{Zl}\p{Zp}\p{Zs}--\x20]").expect("compiles"));

fn is_printable(c: char) -> bool {
    let mut buffer = [0_u8; 4];
    !NONPRINTABLE.is_match(c.encode_utf8(&mut buffer))
}

fn printable(text: &str) -> String {
    if NONPRINTABLE.is_match(text) { text.chars().filter(|&c| is_printable(c)).collect() } else { text.to_owned() }
}

/// Splits Markdown into sections at ATX headings, keeping the heading lines and never splitting
/// inside a fenced code block (`splitters.MarkdownHeaderSplitter`).
#[derive(Debug, Clone)]
pub struct MarkdownHeaderSplitter {
    headers: Vec<(String, String)>,
}

/// A Markdown split that went wrong where Python raises (an `IndexError` in the aggregation); the
/// chunker falls back to prose then, as Python's does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownSplitFailed;

impl MarkdownHeaderSplitter {
    pub fn new(headers: &[(&str, &str)]) -> Self {
        let mut headers: Vec<(String, String)> =
            headers.iter().map(|&(marker, name)| (marker.to_owned(), name.to_owned())).collect();
        // Longest marker first (stable), so "##" is not mistaken for "#".
        headers.sort_by_key(|(marker, _)| std::cmp::Reverse(marker.len()));
        Self { headers }
    }

    /// # Errors
    ///
    /// [`MarkdownSplitFailed`] where Python's splitter raises.
    pub fn split_text(&self, text: &str) -> Result<Vec<MarkdownSection>, MarkdownSplitFailed> {
        let mut lines: Vec<MarkdownSection> = Vec::new();
        let mut content: Vec<String> = Vec::new();
        let mut metadata: BTreeMap<String, String> = BTreeMap::new();
        let mut stack: Vec<(usize, String)> = Vec::new();
        let mut active: BTreeMap<String, String> = BTreeMap::new();
        let mut in_code = false;
        let mut fence = "";

        for raw in text.split('\n') {
            let line = printable(py_strip(raw));
            if !in_code {
                if line.starts_with("```") && line.matches("```").count() == 1 {
                    in_code = true;
                    fence = "```";
                } else if line.starts_with("~~~") {
                    in_code = true;
                    fence = "~~~";
                }
            } else if line.starts_with(fence) {
                in_code = false;
                fence = "";
            }

            if in_code {
                content.push(
                    raw.trim_end_matches(is_py_space).chars().filter(|&c| c == '\t' || is_printable(c)).collect(),
                );
                continue;
            }

            let mut is_header = false;
            for (marker, name) in &self.headers {
                let rest = line.strip_prefix(marker.as_str());
                if let Some(rest) = rest.filter(|rest| rest.is_empty() || rest.starts_with(' ')) {
                    let level = marker.matches('#').count();
                    while let Some((top, popped)) = stack.pop() {
                        if top < level {
                            stack.push((top, popped));
                            break;
                        }
                        active.remove(&popped);
                    }
                    stack.push((level, name.clone()));
                    active.insert(name.clone(), py_strip(rest).to_owned());
                    if !content.is_empty() {
                        lines.push(MarkdownSection { content: content.join("\n"), metadata: metadata.clone() });
                        content.clear();
                    }
                    content.push(line.clone());
                    is_header = true;
                    break;
                }
            }
            if !is_header {
                if !line.is_empty() {
                    content.push(line);
                } else if !content.is_empty() {
                    lines.push(MarkdownSection { content: content.join("\n"), metadata: metadata.clone() });
                    content.clear();
                }
            }
            metadata = active.clone();
        }

        if !content.is_empty() {
            lines.push(MarkdownSection { content: content.join("\n"), metadata });
        }
        Self::aggregate(lines)
    }

    fn aggregate(lines: Vec<MarkdownSection>) -> Result<Vec<MarkdownSection>, MarkdownSplitFailed> {
        let mut sections: Vec<MarkdownSection> = Vec::new();
        for line in lines {
            if let Some(last) = sections.last_mut() {
                if last.metadata == line.metadata {
                    last.content.push_str("  \n");
                    last.content.push_str(&line.content);
                    continue;
                }
                if last.metadata.len() < line.metadata.len() {
                    // Python indexes the last line's first character, which raises on an empty line.
                    let last_line = last.content.rsplit('\n').next().unwrap_or_default();
                    let Some(first) = last_line.chars().next() else {
                        return Err(MarkdownSplitFailed);
                    };
                    if first == '#' {
                        last.content.push_str("  \n");
                        last.content.push_str(&line.content);
                        last.metadata = line.metadata;
                        continue;
                    }
                }
            }
            sections.push(line);
        }
        Ok(sections)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_table_compiles() {
        for language in LANGUAGES {
            assert!(RecursiveSplitter::for_language(language, 100, 10).unwrap().is_some(), "{language}");
        }
        assert!(RecursiveSplitter::for_language("perl", 100, 10).unwrap().is_none());
    }

    #[test]
    fn the_end_anchor_splits_as_python_does() {
        // re.split("($$)", "ab\n") == ["ab", "", "\n", "", ""]
        assert_eq!(Separator::End.split("ab\n"), ["ab", "\n"]);
        assert_eq!(Separator::End.split("ab"), ["ab"]);
    }

    #[test]
    fn separators_are_kept_with_the_piece_after_them() {
        let separator = Separator::new("\n\n", false).unwrap();
        assert_eq!(separator.split("a\n\nb\n\nc"), ["a", "\n\nb", "\n\nc"]);
        assert_eq!(separator.split("\n\na"), ["\n\na"]);
    }

    #[test]
    fn prose_splits_with_overlap() {
        let splitter = RecursiveSplitter::new(10, 4, &["\n\n", "\n", " ", ""], false, false).unwrap();
        assert_eq!(splitter.split_text("one two three four five"), ["one two", "two three", "four five"]);
    }

    #[test]
    fn a_bad_size_is_refused() {
        assert!(RecursiveSplitter::new(0, 0, &[""], false, false).is_err());
        assert!(RecursiveSplitter::new(5, 6, &[""], false, false).is_err());
    }

    #[test]
    fn markdown_keeps_headings_and_fences() {
        let splitter = MarkdownHeaderSplitter::new(&[("#", "h1"), ("##", "h2")]);
        let sections = splitter.split_text("# A\ntext\n```\n# not\n```\n## B\nmore").unwrap();
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].content, "# A\ntext\n```\n# not\n```");
        assert_eq!(sections[1].metadata.get("h2").map(String::as_str), Some("B"));
    }
}
