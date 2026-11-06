//! Rejecting machine-generated text, ported from `garage_rag.extract.quality`.
//!
//! Logs, dumps and manifests slip past the walker's name rules; this content-based backstop finds
//! them from cheap structural signals: repeated line shapes, timestamp prefixes, hex and base64
//! density, structured-dump shapes and a low share of letters. One signal alone rejects only when
//! it is extreme; otherwise two must agree, so prose about hex is kept.
//!
//! Character classes follow Python's `str` methods, not Rust's `char` ones, so the metrics are
//! Python's to the last digit: a letter is Unicode category L (`str.isalpha`), which leaves out the
//! combining marks Rust's `is_alphabetic` counts, and whitespace adds U+001C to U+001F
//! (`str.isspace`).

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;

/// How much of a document is inspected, in characters (Python's `SAMPLE_BYTES`, which slices a
/// `str`).
pub const SAMPLE_CHARS: usize = 64 * 1024;
/// Fewer non-blank lines than this, and only the hash test applies.
pub const MIN_LINES_TO_JUDGE: usize = 40;

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a quality pattern compiles")
}

static TIMESTAMP_PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    regex(concat!(
        r"^\s*(?:",
        r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}",     // 2026-07-27 11:30
        r"|\d{2}:\d{2}:\d{2}[.,]\d+",            // 11:30:31.163
        r"|\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}", // Dec 24 04:09:06
        r"|\[\d+\.\d+\]",                        // [12345.678] kernel style
        r"|\d{10,13}\b",                         // epoch millis
        r")",
    ))
});
// A long unbroken run of hex or base64: hashes, manifests, memory dumps.
static HEX_RUN: LazyLock<Regex> = LazyLock::new(|| regex(r"\b[0-9a-fA-F]{16,}\b"));
static BASE64_RUN: LazyLock<Regex> = LazyLock::new(|| regex(r"\b[A-Za-z0-9+/]{40,}={0,2}\b"));
// The same, at the start of a line (Python's `re.match`).
static HEX_LEAD: LazyLock<Regex> = LazyLock::new(|| regex(r"^\b[0-9a-fA-F]{16,}\b"));
static BASE64_LEAD: LazyLock<Regex> = LazyLock::new(|| regex(r"^\b[A-Za-z0-9+/]{40,}={0,2}\b"));
// Structured-dump shapes: "+-o Root <class IORegistryEntry, id 0x...>", key = {
static DUMP_SHAPE: LazyLock<Regex> = LazyLock::new(|| regex(r"^\s*(?:[+|`\-]{1,4}[o\-]|\{|\}|<\w+ |0x[0-9a-f]{6,})"));
static DIGITS: LazyLock<Regex> = LazyLock::new(|| regex(r"\d+"));
// What `str.isalpha() or str.isspace()` accepts.
static LETTER_OR_SPACE: LazyLock<Regex> = LazyLock::new(|| regex(r"[\p{L}\s\x{1c}-\x{1f}]+"));

/// Why a document was accepted or rejected (`quality.QualityVerdict`).
#[derive(Debug, Clone, PartialEq)]
pub struct Verdict {
    pub machine_generated: bool,
    pub reasons: Vec<String>,
    /// The signals measured, in Python's order, each rounded to three places as Python rounds.
    pub metrics: Vec<(&'static str, f64)>,
}

impl Verdict {
    /// The reasons joined, or "looks human-authored".
    pub fn reason_text(&self) -> String {
        if self.reasons.is_empty() { "looks human-authored".to_owned() } else { self.reasons.join(", ") }
    }
}

/// `str.isspace`: White_Space plus the information separators U+001C to U+001F.
fn is_py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// The first `count` characters of `text`.
fn prefix(text: &str, count: usize) -> &str {
    text.char_indices().nth(count).map_or(text, |(index, _)| &text[..index])
}

/// Non-blank lines (`line.strip()` is not empty).
fn lines(sample: &str) -> Vec<&str> {
    sample.split('\n').filter(|line| !line.trim_matches(is_py_space).is_empty()).collect()
}

/// `round(value, 3)`: the nearest of the shortest decimals, ties to even, as Python's correctly
/// rounded `round` and Rust's formatter both round.
fn round3(value: f64) -> f64 {
    format!("{value:.3}").parse().unwrap_or(value)
}

/// `f"{value:.0%}"`.
fn percent(value: f64) -> String {
    format!("{:.0}%", value * 100.0)
}

#[allow(clippy::cast_precision_loss)]
fn ratio(part: usize, whole: usize) -> f64 {
    part as f64 / whole as f64
}

fn alpha_ratio(text: &str) -> f64 {
    let total = text.chars().count();
    if total == 0 {
        return 0.0;
    }
    let letters: usize = LETTER_OR_SPACE.find_iter(text).map(|found| found.as_str().chars().count()).sum();
    ratio(letters, total)
}

/// Judges whether `text` looks machine-generated, from its first `sample_chars` characters, or
/// more when that sample holds too few lines (a dump's lines can be longer than the sample).
pub fn assess(text: &str, sample_chars: usize) -> Verdict {
    let total_chars = text.chars().count();
    let mut sample = prefix(text, sample_chars);
    let mut found = lines(sample);
    let mut limit = sample_chars;
    while found.len() < MIN_LINES_TO_JUDGE && limit < total_chars {
        limit = limit.saturating_mul(8);
        sample = prefix(text, limit);
        found = lines(sample);
    }

    #[allow(clippy::cast_precision_loss)]
    let line_count = found.len() as f64;
    if found.len() < MIN_LINES_TO_JUDGE {
        // Too few lines for the structural signals, but a short file can still be plainly machine
        // output: a checksum manifest is a dozen lines of hex, each "<hash>  <path>".
        if !found.is_empty() {
            let dense = ratio(
                found
                    .iter()
                    .filter(|line| {
                        let line = line.trim_matches(is_py_space);
                        HEX_LEAD.is_match(line) || BASE64_LEAD.is_match(line)
                    })
                    .count(),
                found.len(),
            );
            if dense > 0.8 {
                return Verdict {
                    machine_generated: true,
                    reasons: vec![format!("every line is a hash or blob ({})", percent(dense))],
                    metrics: vec![("lines", line_count), ("hash_lines", round3(dense))],
                };
            }
        }
        return Verdict { machine_generated: false, reasons: Vec::new(), metrics: vec![("lines", line_count)] };
    }

    let total = found.len();
    let shapes: HashSet<String> =
        found.iter().map(|line| DIGITS.replace_all(prefix(line, 120), "#").into_owned()).collect();
    let repetition = 1.0 - ratio(shapes.len(), total);
    let timestamped = ratio(found.iter().filter(|line| TIMESTAMP_PREFIX.is_match(line)).count(), total);
    let dumpish = ratio(found.iter().filter(|line| DUMP_SHAPE.is_match(line)).count(), total);
    let hexish = ratio(HEX_RUN.find_iter(sample).count(), total);
    let b64ish = ratio(BASE64_RUN.find_iter(sample).count(), total);
    let alpha = alpha_ratio(sample);

    let metrics = vec![
        ("lines", line_count),
        ("repetition", round3(repetition)),
        ("timestamped", round3(timestamped)),
        ("dumpish", round3(dumpish)),
        ("hex_per_line", round3(hexish)),
        ("base64_per_line", round3(b64ish)),
        ("alpha_ratio", round3(alpha)),
    ];

    let mut reasons = Vec::new();
    if timestamped > 0.45 {
        reasons.push(format!("timestamp-prefixed lines {}", percent(timestamped)));
    }
    if repetition > 0.65 {
        reasons.push(format!("repetitive line shapes {}", percent(repetition)));
    }
    if dumpish > 0.4 {
        reasons.push(format!("structured-dump lines {}", percent(dumpish)));
    }
    if hexish > 0.6 {
        reasons.push(format!("hex runs {hexish:.2}/line"));
    }
    if b64ish > 0.4 {
        reasons.push(format!("base64 runs {b64ish:.2}/line"));
    }
    if alpha < 0.55 {
        reasons.push(format!("low alphabetic ratio {}", percent(alpha)));
    }

    // Decisive alone; human prose never restates one line shape four times in five.
    let decisive = timestamped > 0.6 || hexish > 1.0 || dumpish > 0.7 || repetition > 0.82;
    let machine_generated = decisive || reasons.len() >= 2;
    Verdict { machine_generated, reasons, metrics }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prose_is_kept() {
        let text = (0..60)
            .map(|i| format!("Paragraph {i} wanders through the garden and talks about tomatoes, weather and friends."))
            .collect::<Vec<_>>()
            .join("\n");
        let verdict = assess(&text, SAMPLE_CHARS);
        assert!(!verdict.reasons.iter().any(|reason| reason.contains("timestamp")), "{verdict:?}");
        assert_eq!(verdict.metrics[0], ("lines", 60.0));
    }

    #[test]
    fn a_log_is_rejected() {
        let text = (0..60)
            .map(|i| format!("2026-07-27 11:{:02}:00 kernel: event {i} happened", i % 60))
            .collect::<Vec<_>>()
            .join("\n");
        let verdict = assess(&text, SAMPLE_CHARS);
        assert!(verdict.machine_generated);
        assert_eq!(verdict.reasons[0], "timestamp-prefixed lines 100%");
    }

    #[test]
    fn a_short_manifest_is_rejected() {
        let text = (0..10).map(|i| format!("{:064x}  file{i}.bin", i * 7_919)).collect::<Vec<_>>().join("\n");
        let verdict = assess(&text, SAMPLE_CHARS);
        assert!(verdict.machine_generated);
        assert_eq!(verdict.reasons, ["every line is a hash or blob (100%)"]);
    }

    #[test]
    fn rounding_and_percentages_tie_to_even_as_python_does() {
        assert!((round3(0.0625) - 0.062).abs() < f64::EPSILON);
        assert_eq!(percent(0.125), "12%");
        assert_eq!(percent(0.5), "50%");
        assert_eq!(format!("{:.0}", 2.5), "2");
    }

    #[test]
    fn letters_are_category_l() {
        // A Devanagari vowel sign is Alphabetic to Rust but not a letter to Python.
        assert!((alpha_ratio("\u{915}\u{93e}") - 0.5).abs() < f64::EPSILON);
        assert!((alpha_ratio("a\u{1c}") - 1.0).abs() < f64::EPSILON);
    }
}
