//! JSON values as Python's `repr` writes them, for argument errors worded as pydantic words them
//! (`input_value='abc', input_type=str`).

use serde_json::Value;
use std::fmt::Write as _;

/// `repr(value)` of the Python object `json.loads` would make.
pub fn repr(value: &Value) -> String {
    match value {
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(number) => match (number.as_i64(), number.as_u64(), number.as_f64()) {
            (Some(int), _, _) => int.to_string(),
            (None, Some(int), _) => int.to_string(),
            (_, _, Some(float)) => float_repr(float),
            _ => number.to_string(),
        },
        Value::String(text) => str_repr(text),
        Value::Array(items) => format!("[{}]", items.iter().map(repr).collect::<Vec<_>>().join(", ")),
        Value::Object(map) => format!(
            "{{{}}}",
            map.iter().map(|(key, value)| format!("{}: {}", str_repr(key), repr(value))).collect::<Vec<_>>().join(", ")
        ),
    }
}

/// `type(value).__name__`.
pub fn type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "NoneType",
        Value::Bool(_) => "bool",
        Value::Number(number) if number.is_f64() => "float",
        Value::Number(_) => "int",
        Value::String(_) => "str",
        Value::Array(_) => "list",
        Value::Object(_) => "dict",
    }
}

/// pydantic's `input_value`: the repr, cut to its first 25 and last 24 characters when longer than 50.
pub fn truncated(value: &Value) -> String {
    let text = repr(value);
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= 50 {
        return text;
    }
    let head: String = chars[..25].iter().collect();
    let tail: String = chars[chars.len() - 24..].iter().collect();
    format!("{head}...{tail}")
}

/// `repr(float)`: the shortest digits that round-trip, in exponent form below 1e-4 and from 1e16.
pub fn float_repr(value: f64) -> String {
    if value.is_nan() {
        return "nan".into();
    }
    if value.is_infinite() {
        return if value > 0.0 { "inf".into() } else { "-inf".into() };
    }
    // `{:e}` gives the shortest round-trip digits: "1.2345e-7", "-5e0".
    let formatted = format!("{value:e}");
    let (mantissa, exponent) = formatted.split_once('e').unwrap_or((&formatted, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let negative = mantissa.starts_with('-');
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let sign = if negative { "-" } else { "" };
    if !(-4..16).contains(&exponent) {
        let rest = if digits.len() > 1 { format!(".{}", &digits[1..]) } else { String::new() };
        let exp_sign = if exponent < 0 { '-' } else { '+' };
        return format!("{sign}{}{rest}e{exp_sign}{:02}", &digits[..1], exponent.abs());
    }
    let point = exponent + 1; // digits before the decimal point
    if point <= 0 {
        let zeros = "0".repeat(usize::try_from(-point).unwrap_or(0));
        return format!("{sign}0.{zeros}{digits}");
    }
    let point = usize::try_from(point).unwrap_or(0);
    if digits.len() <= point {
        return format!("{sign}{digits}{}.0", "0".repeat(point - digits.len()));
    }
    format!("{sign}{}.{}", &digits[..point], &digits[point..])
}

/// `repr(str)`: single quotes unless the text holds one and no double quote.
pub fn str_repr(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') { '"' } else { '\'' };
    let mut out = String::with_capacity(text.len() + 2);
    out.push(quote);
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c if is_printable(c) => out.push(c),
            c => {
                let code = u32::from(c);
                if code <= 0xff {
                    let _ = write!(out, "\\x{code:02x}");
                } else if code <= 0xffff {
                    let _ = write!(out, "\\u{code:04x}");
                } else {
                    let _ = write!(out, "\\U{code:08x}");
                }
            }
        }
    }
    out.push(quote);
    out
}

/// Close to `str.isprintable` for one character: not a control, separator other than space, or
/// unassigned format character.
fn is_printable(c: char) -> bool {
    if c == ' ' {
        return true;
    }
    if c.is_control() || c.is_whitespace() {
        return false;
    }
    // Format and private characters Python escapes; the common ones.
    !matches!(u32::from(c), 0xad | 0x200b..=0x200f | 0x2028..=0x202e | 0x2060..=0x206f | 0xfeff | 0xfff9..=0xfffb)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn values_print_as_python_prints_them() {
        assert_eq!(repr(&json!(null)), "None");
        assert_eq!(repr(&json!(true)), "True");
        assert_eq!(repr(&json!("it's")), "\"it's\"");
        assert_eq!(repr(&json!("a\"b'c")), "'a\"b\\'c'");
        assert_eq!(repr(&json!("tab\theré\u{1}")), "'tab\\theré\\x01'");
        assert_eq!(repr(&json!({"a": [1, 2.5, null, true]})), "{'a': [1, 2.5, None, True]}");
        assert_eq!(repr(&json!([])), "[]");
    }

    #[test]
    fn floats_print_as_python_prints_them() {
        for (value, text) in [
            (1e-7, "1e-07"),
            (1e20, "1e+20"),
            (123_456_789.123, "123456789.123"),
            (1000.0, "1000.0"),
            (0.0001, "0.0001"),
            (2.5, "2.5"),
            (-0.5, "-0.5"),
            (0.0, "0.0"),
            (1e16, "1e+16"),
            (1.5e-5, "1.5e-05"),
            (9_999_999_999_999_998.0, "9999999999999998.0"),
        ] {
            assert_eq!(float_repr(value), text, "{value}");
        }
    }

    #[test]
    fn long_values_are_cut_as_pydantic_cuts_them() {
        let long = json!("x".repeat(100));
        assert_eq!(truncated(&long), format!("'{}...{}'", "x".repeat(24), "x".repeat(23)));
        let list = json!((0..40).collect::<Vec<_>>());
        assert_eq!(truncated(&list), "[0, 1, 2, 3, 4, 5, 6, 7, ... 34, 35, 36, 37, 38, 39]");
    }
}
