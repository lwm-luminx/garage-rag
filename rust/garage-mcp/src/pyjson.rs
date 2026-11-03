//! `json.dumps` as Python writes it, for text that goes into a model's prompt: the agent's tool
//! calls (default separators, ASCII only) and tool results (compact, Unicode kept). Floats are
//! Python's `repr`, so `1e-07`, not `1e-7`.

use serde_json::Value;
use std::fmt::Write as _;

use crate::pyrepr::float_repr;

/// How `json.dumps` was called.
#[derive(Clone, Copy, Debug)]
pub struct Style {
    /// `separators=(",", ":")` instead of the default `(", ", ": ")`.
    pub compact: bool,
    /// `ensure_ascii`, Python's default.
    pub ensure_ascii: bool,
}

/// `json.dumps(obj)`.
pub const DEFAULT: Style = Style { compact: false, ensure_ascii: true };
/// `json.dumps(obj, ensure_ascii=False, separators=(",", ":"))`.
pub const COMPACT_UNICODE: Style = Style { compact: true, ensure_ascii: false };

pub fn dumps(value: &Value, style: Style) -> String {
    let mut out = String::new();
    write(&mut out, value, style);
    out
}

fn write(out: &mut String, value: &Value, style: Style) {
    let (item, key) = if style.compact { (",", ":") } else { (", ", ": ") };
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => {
            if number.is_f64() {
                let x = number.as_f64().unwrap_or(0.0);
                if x.is_nan() {
                    out.push_str("NaN");
                } else if x.is_infinite() {
                    out.push_str(if x > 0.0 { "Infinity" } else { "-Infinity" });
                } else {
                    out.push_str(&float_repr(x));
                }
            } else {
                out.push_str(&number.to_string());
            }
        }
        Value::String(text) => write_str(out, text, style.ensure_ascii),
        Value::Array(items) => {
            out.push('[');
            for (i, element) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(item);
                }
                write(out, element, style);
            }
            out.push(']');
        }
        Value::Object(map) => {
            out.push('{');
            for (i, (name, element)) in map.iter().enumerate() {
                if i > 0 {
                    out.push_str(item);
                }
                write_str(out, name, style.ensure_ascii);
                out.push_str(key);
                write(out, element, style);
            }
            out.push('}');
        }
    }
}

fn write_str(out: &mut String, text: &str, ensure_ascii: bool) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if u32::from(c) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", u32::from(c));
            }
            c if ensure_ascii && !c.is_ascii() => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    let _ = write!(out, "\\u{unit:04x}");
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn writes_as_python_writes() {
        let value = json!({"tool": "rag_search", "arguments": {"query": "café 😀", "limit": 6, "x": 1e-7, "y": 2.0}});
        assert_eq!(
            dumps(&value, DEFAULT),
            "{\"tool\": \"rag_search\", \"arguments\": {\"query\": \"caf\\u00e9 \\ud83d\\ude00\", \"limit\": 6, \"x\": 1e-07, \"y\": 2.0}}"
        );
        assert_eq!(
            dumps(&value, COMPACT_UNICODE),
            r#"{"tool":"rag_search","arguments":{"query":"café 😀","limit":6,"x":1e-07,"y":2.0}}"#
        );
    }
}
