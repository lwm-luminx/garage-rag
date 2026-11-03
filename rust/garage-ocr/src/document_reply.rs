//! The reply of Vision's document reader ([`crate::vision_documents`]) as text: its paragraphs, then
//! each table as Markdown. Apart from the Swift call so it is tested on every platform.

use serde_json::Value;

use crate::{OcrError, Recognized, Span};

/// The Swift half's JSON: {"confidence": 0...1, "paragraphs": [String], "tables": [[[String]]]}.
pub(crate) fn parse(json: &str) -> Result<Recognized, OcrError> {
    let reply: Value = serde_json::from_str(json).map_err(|error| OcrError::Failed(format!("bad reply: {error}")))?;
    #[allow(clippy::cast_possible_truncation)]
    let confidence = reply.get("confidence").and_then(Value::as_f64).unwrap_or(0.0) as f32 * 100.0;
    let mut spans: Vec<Span> = reply
        .get("paragraphs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|text| Span { text: text.to_owned(), confidence })
        .collect();
    for table in reply.get("tables").and_then(Value::as_array).into_iter().flatten() {
        let rows: Vec<Vec<&str>> = table
            .as_array()
            .into_iter()
            .flatten()
            .map(|row| row.as_array().into_iter().flatten().filter_map(Value::as_str).collect())
            .collect();
        if let Some(markdown) = markdown_table(&rows) {
            spans.push(Span { text: markdown, confidence });
        }
    }
    Ok(Recognized { spans, separator: "\n\n" })
}

/// A table as GitHub Markdown, its first row as the header. None when it has no cells.
fn markdown_table(rows: &[Vec<&str>]) -> Option<String> {
    let width = rows.iter().map(Vec::len).max().filter(|width| *width > 0)?;
    let line = |row: &[&str]| {
        let cells: Vec<String> = (0..width)
            .map(|column| row.get(column).copied().unwrap_or("").replace('|', "\\|").replace('\n', " "))
            .collect();
        format!("| {} |", cells.join(" | "))
    };
    let mut lines = vec![line(&rows[0]), format!("|{}", " --- |".repeat(width))];
    lines.extend(rows[1..].iter().map(|row| line(row)));
    Some(lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paragraphs_then_tables() {
        let recognized = parse(
            r#"{"confidence": 0.9, "paragraphs": ["Invoice 4471", "Due November 30"],
                "tables": [[["Item", "Price"], ["Lamp", "40 | 45"], ["Desk"]]]}"#,
        )
        .expect("parse");
        assert_eq!(
            recognized.text(),
            "Invoice 4471\n\nDue November 30\n\n| Item | Price |\n| --- | --- |\n| Lamp | 40 \\| 45 |\n| Desk |  |"
        );
        assert!((recognized.mean_confidence() - 90.0).abs() < 0.01);
    }

    #[test]
    fn an_empty_document_has_no_spans() {
        let recognized = parse(r#"{"confidence": 0, "paragraphs": [], "tables": [[]]}"#).expect("parse");
        assert!(recognized.spans.is_empty());
    }
}
