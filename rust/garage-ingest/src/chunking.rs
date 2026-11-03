//! Chunking by content kind, ported from `garage_rag.ingest.chunking`: Markdown splits at headings
//! and keeps each chunk's heading path, code splits on its language's structure, tables on sheet
//! headings and rows, and prose on paragraphs. Each chunk records its chunker id and where it sits
//! in the text, in characters, as Python records them, so a chunk made here hashes the same and
//! keeps its vectors.

use crate::splitters::{MarkdownHeaderSplitter, RecursiveSplitter, SplitterError, is_py_space, py_strip};

/// How a text is chunked (`extract.base.ContentKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContentKind {
    Prose,
    Markdown,
    Code,
    Tabular,
    Conversation,
    Image,
}

impl ContentKind {
    /// The kind Python's `ContentKind(value)` names.
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "prose" => Self::Prose,
            "markdown" => Self::Markdown,
            "code" => Self::Code,
            "tabular" => Self::Tabular,
            "conversation" => Self::Conversation,
            "image" => Self::Image,
            _ => return None,
        })
    }
}

/// One embeddable unit (`chunking.TextChunk`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextChunk {
    pub ord: usize,
    pub text: String,
    pub chunker: String,
    pub heading_path: Option<String>,
    /// Where the chunk sits in the text, `[char_start, char_end)` in characters; None when it
    /// cannot be found.
    pub char_start: Option<usize>,
    pub char_end: Option<usize>,
}

impl TextChunk {
    fn new(ord: usize, text: String, chunker: String, heading_path: Option<String>) -> Self {
        Self { ord, text, chunker, heading_path, char_start: None, char_end: None }
    }
}

/// The chunker of the one chunk that stands for a picture (`chunking.IMAGE_CHUNKER`).
pub const IMAGE_CHUNKER: &str = "image";

const MD_HEADERS: &[(&str, &str)] = &[("#", "h1"), ("##", "h2"), ("###", "h3")];
const PROSE_SEPARATORS: &[&str] = &["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " ", ""];

/// The separator table for a code file's extension (`chunking._CODE_LANGUAGES`).
pub fn code_language(extension: &str) -> Option<&'static str> {
    Some(match extension.to_lowercase().as_str() {
        ".py" | ".pyi" => "python",
        ".js" | ".jsx" | ".mjs" | ".cjs" => "js",
        ".ts" | ".tsx" => "ts",
        ".c" | ".h" => "c",
        ".cc" | ".cpp" | ".cxx" | ".hpp" | ".hh" => "cpp",
        ".go" => "go",
        ".rs" => "rust",
        ".rb" => "ruby",
        ".php" => "php",
        ".java" => "java",
        ".kt" => "kotlin",
        ".scala" => "scala",
        ".swift" => "swift",
        ".cs" => "csharp",
        ".lua" => "lua",
        ".hs" => "haskell",
        ".ex" | ".exs" => "elixir",
        ".html" | ".htm" => "html",
        ".tex" => "latex",
        ".sol" => "sol",
        ".cob" => "cobol",
        _ => return None,
    })
}

fn recursive(size: usize, overlap: usize, keep_indent: bool) -> Result<RecursiveSplitter, SplitterError> {
    RecursiveSplitter::new(size, overlap, PROSE_SEPARATORS, false, keep_indent)
}

fn heading_path(metadata: &std::collections::BTreeMap<String, String>) -> Option<String> {
    let parts: Vec<&str> = ["h1", "h2", "h3"]
        .iter()
        .filter_map(|key| metadata.get(*key))
        .filter(|part| !part.is_empty())
        .map(String::as_str)
        .collect();
    if parts.is_empty() { None } else { Some(parts.join(" > ")) }
}

/// Header split, then size split, keeping heading paths (`chunking.chunk_markdown`).
///
/// # Errors
///
/// A size the splitter refuses.
pub fn chunk_markdown(text: &str, size: usize, overlap: usize) -> Result<Vec<TextChunk>, SplitterError> {
    let size_splitter = recursive(size, overlap, true)?;
    let Ok(sections) = MarkdownHeaderSplitter::new(MD_HEADERS).split_text(text) else {
        return chunk_prose(text, size, overlap);
    };
    let mut chunks = Vec::new();
    for section in sections {
        let heading = heading_path(&section.metadata);
        let body = section.content;
        let pieces = if body.chars().count() > size { size_splitter.split_text(&body) } else { vec![body] };
        for piece in pieces {
            if !py_strip(&piece).is_empty() {
                chunks.push(TextChunk::new(
                    chunks.len(),
                    piece.trim_end_matches(is_py_space).to_owned(),
                    format!("markdown-header+recursive/v2:{size}/{overlap}"),
                    heading.clone(),
                ));
            }
        }
    }
    if chunks.is_empty() {
        return chunk_prose(text, size, overlap);
    }
    Ok(chunks)
}

/// Paragraphs, then lines, sentences and words (`chunking.chunk_prose`).
///
/// # Errors
///
/// A size the splitter refuses.
pub fn chunk_prose(text: &str, size: usize, overlap: usize) -> Result<Vec<TextChunk>, SplitterError> {
    let pieces = recursive(size, overlap, false)?.split_text(text);
    Ok(pieces
        .iter()
        .enumerate()
        .filter(|(_, piece)| !py_strip(piece).is_empty())
        .map(|(index, piece)| {
            TextChunk::new(index, py_strip(piece).to_owned(), format!("recursive:{size}/{overlap}"), None)
        })
        .collect())
}

/// On the language's structure where a table exists, as prose otherwise (`chunking.chunk_code`).
///
/// # Errors
///
/// A size the splitter refuses.
pub fn chunk_code(text: &str, extension: &str, size: usize, overlap: usize) -> Result<Vec<TextChunk>, SplitterError> {
    let (splitter, label) = match code_language(extension) {
        Some(language) => (
            RecursiveSplitter::for_language(language, size, overlap)?
                .ok_or_else(|| SplitterError(format!("no separator table for {language}")))?,
            format!("code:{language}:{size}/{overlap}"),
        ),
        None => (recursive(size, overlap, false)?, format!("recursive:{size}/{overlap}")),
    };
    Ok(splitter
        .split_text(text)
        .into_iter()
        .enumerate()
        .filter(|(_, piece)| !py_strip(piece).is_empty())
        .map(|(index, piece)| TextChunk::new(index, piece, label.clone(), None))
        .collect())
}

/// On sheet headings and rows, with no overlap (`chunking.chunk_tabular`).
///
/// # Errors
///
/// A size the splitter refuses.
pub fn chunk_tabular(text: &str, size: usize) -> Result<Vec<TextChunk>, SplitterError> {
    let splitter = RecursiveSplitter::new(size, 0, &["\n## ", "\n\n", "\n", " "], false, false)?;
    let mut chunks = Vec::new();
    for piece in splitter.split_text(text) {
        let stripped = py_strip(&piece);
        if stripped.is_empty() {
            continue;
        }
        let heading = stripped
            .strip_prefix("## ")
            .map(|rest| py_strip(rest.split('\n').next().unwrap_or_default()))
            .filter(|heading| !heading.is_empty())
            .map(str::to_owned);
        chunks.push(TextChunk::new(chunks.len(), stripped.to_owned(), format!("tabular:{size}"), heading));
    }
    Ok(chunks)
}

/// The chunk an image embedding model embeds (`chunking.image_chunk`).
pub fn image_chunk(text: &str) -> TextChunk {
    TextChunk {
        ord: 0,
        text: text.to_owned(),
        chunker: IMAGE_CHUNKER.to_owned(),
        heading_path: None,
        char_start: Some(0),
        char_end: Some(text.chars().count()),
    }
}

/// `str.splitlines()`'s line boundaries.
fn is_line_boundary(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0b}' | '\u{0c}' | '\u{1c}' | '\u{1d}' | '\u{1e}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `str.splitlines()`, without the line ends (`\r\n` is one boundary).
fn split_lines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((index, c)) = chars.next() {
        if is_line_boundary(c) {
            lines.push(&text[start..index]);
            let mut end = index + c.len_utf8();
            if c == '\r' && chars.peek().is_some_and(|&(_, next)| next == '\n') {
                chars.next();
                end += 1;
            }
            start = end;
        }
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// Where `text` sits in `source` at or after byte `cursor`, as byte offsets (`chunking._span`).
fn span(source: &str, text: &str, cursor: usize) -> Option<(usize, usize)> {
    if let Some(start) = source[cursor..].find(text) {
        let start = cursor + start;
        return Some((start, start + text.len()));
    }
    let lines: Vec<&str> = split_lines(text).into_iter().map(py_strip).filter(|line| !line.is_empty()).collect();
    let first = lines.first()?;
    let start = cursor + source[cursor..].find(first)?;
    let mut end = start + first.len();
    for line in &lines[1..] {
        end += source[end..].find(line)?;
        end += line.len();
    }
    Some((start, end))
}

/// Byte offsets to character offsets, for offsets that mostly move forward.
struct CharOffsets<'a> {
    text: &'a str,
    byte: usize,
    char: usize,
}

impl CharOffsets<'_> {
    fn at(&mut self, byte: usize) -> usize {
        if byte < self.byte {
            self.byte = 0;
            self.char = 0;
        }
        self.char += self.text[self.byte..byte].chars().count();
        self.byte = byte;
        self.char
    }
}

/// Sets each chunk's offsets to where it sits in `source` (`chunking._locate`). Each search starts
/// one character past the previous chunk's start, since chunks may overlap.
fn locate(source: &str, mut chunks: Vec<TextChunk>) -> Vec<TextChunk> {
    let mut starts = CharOffsets { text: source, byte: 0, char: 0 };
    let mut ends = CharOffsets { text: source, byte: 0, char: 0 };
    let mut cursor = 0;
    for chunk in &mut chunks {
        let Some((start, end)) = span(source, &chunk.text, cursor) else {
            continue;
        };
        chunk.char_start = Some(starts.at(start));
        chunk.char_end = Some(ends.at(end));
        // One character on, which is past the end when the chunk is empty at the end.
        cursor = source[start..].chars().next().map_or(source.len(), |c| start + c.len_utf8());
    }
    chunks
}

/// Chunks `text` by its kind (`chunking.chunk_text`). `size` and `overlap` are the settings for
/// the kind: `code_chunk_*` for code, `chunk_*` otherwise.
///
/// # Errors
///
/// A size the splitter refuses.
pub fn chunk_text(
    text: &str,
    kind: ContentKind,
    extension: &str,
    size: usize,
    overlap: usize,
) -> Result<Vec<TextChunk>, SplitterError> {
    let chunks = match kind {
        ContentKind::Image => return Ok(vec![image_chunk(text)]),
        ContentKind::Code => chunk_code(text, extension, size, overlap)?,
        ContentKind::Markdown => chunk_markdown(text, size, overlap)?,
        ContentKind::Tabular => chunk_tabular(text, size)?,
        ContentKind::Prose | ContentKind::Conversation => chunk_prose(text, size, overlap)?,
    };
    Ok(locate(text, chunks))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_chunks_carry_their_heading_path() {
        let text = "# Boot\nIntro.\n## SEP\nKeys stay away.\n";
        let chunks = chunk_text(text, ContentKind::Markdown, "", 1000, 100).unwrap();
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[1].heading_path.as_deref(), Some("Boot > SEP"));
        assert_eq!(chunks[0].chunker, "markdown-header+recursive/v2:1000/100");
        assert_eq!(chunks[0].char_start, Some(0));
    }

    #[test]
    fn offsets_are_in_characters() {
        let text = "été\n\nnext paragraph";
        let chunks = chunk_text(text, ContentKind::Prose, "", 5, 0).unwrap();
        let last = chunks.last().unwrap();
        let start = last.char_start.unwrap();
        let end = last.char_end.unwrap();
        assert_eq!(text.chars().skip(start).take(end - start).collect::<String>(), last.text);
    }

    #[test]
    fn splitlines_matches_python() {
        assert_eq!(split_lines("a\r\nb\rc\u{2028}d\n"), ["a", "b", "c", "d"]);
    }

    #[test]
    fn tables_take_their_sheet_heading() {
        let chunks = chunk_tabular("## Sheet1\na,b\n1,2", 1000).unwrap();
        assert_eq!(chunks[0].heading_path.as_deref(), Some("Sheet1"));
    }
}
