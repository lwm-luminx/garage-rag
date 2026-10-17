//! Decoding, normalizing and titling text: `read_text_file`, `normalize_text` and `guess_title`
//! from `garage_rag.extract`, with Python's notions of whitespace and of a file's suffix kept, so
//! the text (and so its hash, its chunks and their vectors) does not change with the port.

use unicode_normalization::UnicodeNormalization;

/// Python's `str.isspace`: Unicode `White_Space` plus the four ASCII information separators
/// (U+001C to U+001F), which Python counts and Rust's `char::is_whitespace` does not.
pub fn is_py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// Python's `str.strip()`.
pub fn py_strip(text: &str) -> &str {
    text.trim_matches(is_py_space)
}

/// Python's `str.rstrip()`.
pub fn py_rstrip(text: &str) -> &str {
    text.trim_end_matches(is_py_space)
}

/// The encodings `decode` may report, by the names the Python reader recorded.
pub const UTF8_SIG: &str = "utf-8-sig";
pub const UTF8: &str = "utf-8";
pub const UTF16: &str = "utf-16";
pub const CP1252: &str = "cp1252";
pub const LATIN1: &str = "latin-1";

/// Decodes a text file's bytes, returning the text and the encoding used.
///
/// The order matters, and is the Python reader's. UTF-8 first, dropping a byte-order mark so it
/// does not end up in front of Markdown front matter. UTF-16 only when a byte-order mark says so:
/// almost any even-length byte string decodes as UTF-16, so trying it blind turns a legacy file
/// into CJK noise. Then Windows-1252, which most Western legacy text was written in, and finally
/// Latin-1, which accepts every byte, so decoding never fails and no document is lost to one bad
/// byte.
pub fn decode(data: &[u8]) -> (String, &'static str) {
    let (body, encoding) = match data.strip_prefix(b"\xEF\xBB\xBF") {
        Some(rest) => (rest, UTF8_SIG),
        None => (data, UTF8),
    };
    if let Ok(text) = std::str::from_utf8(body) {
        return (text.to_owned(), encoding);
    }
    if let Some(text) = decode_utf16(data) {
        return (text, UTF16);
    }
    if let Some(text) = decode_cp1252(data) {
        return (text, CP1252);
    }
    (data.iter().map(|&b| char::from(b)).collect(), LATIN1)
}

/// Python's `utf-16` codec on input that starts with a byte-order mark: the mark picks the byte
/// order and is dropped; an odd length or an unpaired surrogate fails.
fn decode_utf16(data: &[u8]) -> Option<String> {
    let little = match data.get(..2)? {
        [0xFF, 0xFE] => true,
        [0xFE, 0xFF] => false,
        _ => return None,
    };
    let body = &data[2..];
    if !body.len().is_multiple_of(2) {
        return None;
    }
    let units = body.chunks_exact(2).map(|pair| {
        let pair = [pair[0], pair[1]];
        if little { u16::from_le_bytes(pair) } else { u16::from_be_bytes(pair) }
    });
    char::decode_utf16(units).collect::<Result<String, _>>().ok()
}

/// Windows-1252's 0x80 to 0x9F. `None` marks the five bytes Python's `cp1252` codec rejects.
const CP1252_HIGH: [Option<char>; 32] = [
    Some('\u{20AC}'),
    None,
    Some('\u{201A}'),
    Some('\u{0192}'),
    Some('\u{201E}'),
    Some('\u{2026}'),
    Some('\u{2020}'),
    Some('\u{2021}'),
    Some('\u{02C6}'),
    Some('\u{2030}'),
    Some('\u{0160}'),
    Some('\u{2039}'),
    Some('\u{0152}'),
    None,
    Some('\u{017D}'),
    None,
    None,
    Some('\u{2018}'),
    Some('\u{2019}'),
    Some('\u{201C}'),
    Some('\u{201D}'),
    Some('\u{2022}'),
    Some('\u{2013}'),
    Some('\u{2014}'),
    Some('\u{02DC}'),
    Some('\u{2122}'),
    Some('\u{0161}'),
    Some('\u{203A}'),
    Some('\u{0153}'),
    None,
    Some('\u{017E}'),
    Some('\u{0178}'),
];

fn decode_cp1252(data: &[u8]) -> Option<String> {
    data.iter()
        .map(|&b| match b {
            0x80..=0x9F => CP1252_HIGH[usize::from(b - 0x80)],
            _ => Some(char::from(b)),
        })
        .collect()
}

/// `normalize_text`: NFC (macOS hands back NFD, which would make identical content hash
/// differently by where it came from), no NULs (Postgres `text` rejects them), `\n` line endings,
/// no trailing whitespace on a line, at most two blank lines in a row, and no leading or trailing
/// blank space.
pub fn normalize(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let text: String = raw.nfc().filter(|&c| c != '\0').collect();
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut out = String::with_capacity(text.len());
    let mut blanks = 0;
    let mut first = true;
    for line in text.split('\n') {
        let line = py_rstrip(line);
        if line.is_empty() {
            blanks += 1;
            if blanks > 2 {
                continue;
            }
        } else {
            blanks = 0;
        }
        if !first {
            out.push('\n');
        }
        first = false;
        out.push_str(line);
    }
    py_strip(&out).to_owned()
}

/// `extract_code`'s lighter touch: line endings and NULs only, since indentation and blank lines
/// carry meaning in source.
pub fn normalize_code(raw: &str) -> String {
    raw.replace("\r\n", "\n").replace('\r', "\n").replace('\0', "")
}

/// The first `count` pieces of Python's `text.split("\n", count)`.
fn leading_lines(text: &str, count: usize) -> impl Iterator<Item = &str> {
    text.splitn(count + 1, '\n').take(count)
}

/// `guess_title`: a Markdown H1, else the first line of 3 to 200 characters in the first ten,
/// else the file's stem.
pub fn guess_title(file_name: &str, text: &str, markdown: bool) -> Option<String> {
    if markdown {
        for line in leading_lines(text, 40) {
            if let Some(heading) = py_strip(line).strip_prefix("# ") {
                let heading = py_strip(heading);
                return (!heading.is_empty()).then(|| heading.to_owned());
            }
        }
    }
    for line in leading_lines(text, 10) {
        let stripped = py_strip(line);
        if (3..=200).contains(&stripped.chars().count()) {
            return Some(stripped.to_owned());
        }
    }
    let stem = split_extension(file_name).0;
    (!stem.is_empty()).then(|| stem.to_owned())
}

/// Python's `os.path.splitext` on a bare name, which `PurePath.stem` and `.suffix` follow: the
/// extension starts at the last dot, unless only dots precede it (".bashrc", "..").
pub fn split_extension(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(dot) if name[..dot].bytes().any(|b| b != b'.') => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_in_the_python_order() {
        assert_eq!(decode(b"plain"), ("plain".into(), UTF8));
        assert_eq!(decode(b"\xEF\xBB\xBF---\n"), ("---\n".into(), UTF8_SIG));
        assert_eq!(decode(b"\xFF\xFEh\0i\0"), ("hi".into(), UTF16));
        assert_eq!(decode(b"\xFE\xFF\0h\0i"), ("hi".into(), UTF16));
        // A UTF-16 mark on an odd length falls through to cp1252: ÿþh.
        assert_eq!(decode(b"\xFF\xFEh"), ("\u{FF}\u{FE}h".into(), CP1252));
        assert_eq!(decode(b"caf\xE9 \x93q\x94"), ("caf\u{E9} \u{201C}q\u{201D}".into(), CP1252));
        // 0x81 is undefined in cp1252, so the whole file is Latin-1.
        assert_eq!(decode(b"a\x81\x93"), ("a\u{81}\u{93}".into(), LATIN1));
    }

    #[test]
    fn normalizes_like_normalize_text() {
        assert_eq!(normalize(""), "");
        assert_eq!(normalize("e\u{301}"), "\u{E9}");
        assert_eq!(normalize("a\0b\r\nc\rd"), "ab\nc\nd");
        assert_eq!(normalize("a  \t\n\n\n\n\nb"), "a\n\n\nb");
        assert_eq!(normalize("\n\n  a\u{1c}\n  "), "a");
        assert_eq!(normalize("a\u{A0}\nb"), "a\nb");
    }

    #[test]
    fn titles() {
        assert_eq!(guess_title("x.md", "intro\n# Heading \n", true).as_deref(), Some("Heading"));
        // "#" alone is no heading, and too short to be a title line.
        assert_eq!(guess_title("x.md", "#   \nbody text", true).as_deref(), Some("body text"));
        assert_eq!(guess_title("x.txt", "ab\n  first line  \n", false).as_deref(), Some("first line"));
        assert_eq!(guess_title("notes.txt", "ab\ncd", false).as_deref(), Some("notes"));
        assert_eq!(guess_title(".bashrc", "", false).as_deref(), Some(".bashrc"));
        let eleventh = format!("{}xyz", "\n".repeat(10));
        assert_eq!(guess_title("n.txt", &eleventh, false).as_deref(), Some("n"));
    }

    #[test]
    fn splits_extensions_like_pathlib() {
        for (name, stem, suffix) in [
            ("a.md", "a", ".md"),
            (".bashrc", ".bashrc", ""),
            ("foo.", "foo", "."),
            ("x.tar.gz", "x.tar", ".gz"),
            ("..", "..", ""),
            ("...", "...", ""),
            (".a.b", ".a", ".b"),
            ("a..b", "a.", ".b"),
            ("Makefile", "Makefile", ""),
        ] {
            assert_eq!(split_extension(name), (stem, suffix), "{name}");
        }
    }
}
