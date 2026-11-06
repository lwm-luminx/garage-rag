//! YAML front matter, read the way PyYAML's `yaml.safe_load` reads it.
//!
//! Front matter is YAML 1.1 in practice (Jekyll, Hugo and Obsidian all grew up on it), and the
//! Python reader this crate replaces used PyYAML, whose `SafeLoader` resolves plain scalars by
//! YAML 1.1's rules: `yes` and `off` are booleans, `1:30` is the integer 90, `0755` is octal and
//! `2024-01-01` is a date. `yaml-rust2` parses the document; the resolution below is PyYAML's,
//! so the same front matter yields the same values, and so the same titles, author hints and
//! metadata, as before.
//!
//! What a document can hold that this does not model, each of which makes [`parse`] fail so the
//! reader keeps the body and drops the front matter, as it does for malformed YAML:
//!
//! * merge keys (`<<`) and the `=` value key;
//! * tags other than the core `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq`, `!!map`
//!   (PyYAML also accepts `!!binary`, `!!set`, `!!omap`, `!!pairs` and `!!timestamp`);
//! * integers outside the 64-bit range.

use std::collections::HashMap;

use yaml_rust2::parser::{Event, EventReceiver, Parser, Tag};
use yaml_rust2::scanner::TScalarStyle;

/// A value as `yaml.safe_load` would construct it.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i128),
    Float(f64),
    Str(String),
    /// A plain scalar PyYAML reads as a `datetime.date` or `datetime`; kept as written.
    Timestamp(String),
    Seq(Vec<Value>),
    /// In document order. A repeated key keeps its first position and its last value, as a
    /// Python `dict` does.
    Map(Vec<(Value, Value)>),
}

impl Value {
    /// Python's truth value.
    pub fn is_truthy(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Bool(b) => *b,
            Value::Int(i) => *i != 0,
            Value::Float(f) => *f != 0.0,
            Value::Str(s) | Value::Timestamp(s) => !s.is_empty(),
            Value::Seq(items) => !items.is_empty(),
            Value::Map(entries) => !entries.is_empty(),
        }
    }

    /// Python's `str()` of a scalar; `None` for a container or a date-time, whose Python forms
    /// this does not reproduce.
    pub fn py_str(&self) -> Option<String> {
        match self {
            Value::Null => Some("None".to_string()),
            Value::Bool(true) => Some("True".to_string()),
            Value::Bool(false) => Some("False".to_string()),
            Value::Int(i) => Some(i.to_string()),
            Value::Float(f) => Some(py_float_repr(*f)),
            Value::Str(s) => Some(s.clone()),
            // `str(datetime.date)` is the ISO date, which is how it was written.
            Value::Timestamp(s) if is_date(s) => Some(s.clone()),
            Value::Timestamp(_) | Value::Seq(_) | Value::Map(_) => None,
        }
    }
}

/// Why the front matter was not read.
#[derive(Debug, PartialEq, Eq)]
pub struct Error(pub String);

/// Parses one YAML document. `Ok(None)` for an empty one, as `safe_load` returns `None`.
///
/// # Errors
///
/// When the text is not YAML, holds more than one document, or holds something PyYAML's safe
/// loader would refuse or this module does not model (see the module documentation).
pub fn parse(text: &str) -> Result<Option<Value>, Error> {
    // PyYAML's reader refuses a stream holding a character YAML calls non-printable; yaml-rust2
    // reads on.
    if let Some(c) = text.chars().find(|&c| !is_printable(c)) {
        return Err(Error(format!("unacceptable character {:#x}", u32::from(c))));
    }
    // yaml-rust2 ends a block scalar (`|`, `>`) that runs to the end of the input with a line
    // break even when the input has none; PyYAML does not. Front matter never ends with one, so
    // this is the common case. A first pass finds the last scalar; when it is a block scalar and
    // the input's last line is its content, the second pass drops that break.
    let mut last = LastScalar::default();
    Parser::new_from_str(text).load(&mut last, true).map_err(|error| Error(error.to_string()))?;
    let last_line = text.rsplit('\n').next().unwrap_or("");
    let ends_on_content = !text.ends_with('\n') && !last_line.trim().is_empty();

    let mut builder =
        Builder { drop_break_of: (last.was_block && ends_on_content).then_some(last.ordinal), ..Builder::default() };
    Parser::new_from_str(text).load(&mut builder, true).map_err(|error| Error(error.to_string()))?;
    if let Some(error) = builder.error {
        return Err(error);
    }
    if builder.documents > 1 {
        return Err(Error("expected a single document".to_string()));
    }
    Ok(builder.root)
}

/// Which scalar or alias event comes last, and whether it is a block scalar.
#[derive(Default)]
struct LastScalar {
    seen: usize,
    ordinal: usize,
    was_block: bool,
}

impl EventReceiver for LastScalar {
    fn on_event(&mut self, event: Event) {
        match event {
            Event::Scalar(_, style, _, _) => {
                self.ordinal = self.seen;
                self.seen += 1;
                self.was_block = matches!(style, TScalarStyle::Literal | TScalarStyle::Folded);
            }
            Event::Alias(_) => {
                self.seen += 1;
                self.was_block = false;
            }
            _ => {}
        }
    }
}

/// PyYAML's `Reader.NON_PRINTABLE`, inverted.
fn is_printable(c: char) -> bool {
    matches!(c, '\t' | '\n' | '\r' | '\x20'..='\x7e' | '\u{85}' | '\u{a0}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}')
        || c >= '\u{10000}'
}

enum Frame {
    Seq { anchor: usize, items: Vec<Value> },
    Map { anchor: usize, entries: Vec<(Value, Value)>, index: HashMap<Key, usize>, key: Option<Value> },
}

#[derive(Default)]
struct Builder {
    stack: Vec<Frame>,
    anchors: HashMap<usize, Value>,
    root: Option<Value>,
    documents: usize,
    /// Scalar and alias events seen so far.
    scalars: usize,
    /// The ordinal of a block scalar whose final line break yaml-rust2 made up.
    drop_break_of: Option<usize>,
    error: Option<Error>,
}

impl EventReceiver for Builder {
    fn on_event(&mut self, event: Event) {
        if self.error.is_some() {
            return;
        }
        if let Err(error) = self.handle(event) {
            self.error = Some(error);
        }
    }
}

impl Builder {
    fn handle(&mut self, event: Event) -> Result<(), Error> {
        match event {
            Event::DocumentStart => self.documents += 1,
            Event::Scalar(mut text, style, anchor, tag) => {
                if self.drop_break_of == Some(self.scalars) && text.ends_with('\n') {
                    text.pop();
                }
                self.scalars += 1;
                let value = resolve_scalar(text, style, tag.as_ref())?;
                self.anchor(anchor, &value);
                self.push(value)?;
            }
            Event::Alias(anchor) => {
                self.scalars += 1;
                let value = self.anchors.get(&anchor).cloned().ok_or_else(|| Error("unknown alias".to_string()))?;
                self.push(value)?;
            }
            Event::SequenceStart(anchor, tag) => {
                check_collection_tag(tag.as_ref(), "seq")?;
                self.stack.push(Frame::Seq { anchor, items: Vec::new() });
            }
            Event::MappingStart(anchor, tag) => {
                check_collection_tag(tag.as_ref(), "map")?;
                self.stack.push(Frame::Map { anchor, entries: Vec::new(), index: HashMap::new(), key: None });
            }
            Event::SequenceEnd | Event::MappingEnd => {
                let (anchor, value) = match self.stack.pop() {
                    Some(Frame::Seq { anchor, items }) => (anchor, Value::Seq(items)),
                    Some(Frame::Map { anchor, entries, .. }) => (anchor, Value::Map(entries)),
                    None => return Err(Error("unbalanced collection".to_string())),
                };
                self.anchor(anchor, &value);
                self.push(value)?;
            }
            Event::Nothing | Event::StreamStart | Event::StreamEnd | Event::DocumentEnd => {}
        }
        Ok(())
    }

    fn anchor(&mut self, anchor: usize, value: &Value) {
        // yaml-rust2 numbers anchors from 1; 0 means none.
        if anchor > 0 {
            self.anchors.insert(anchor, value.clone());
        }
    }

    fn push(&mut self, value: Value) -> Result<(), Error> {
        match self.stack.last_mut() {
            None => {
                if self.root.is_none() {
                    self.root = Some(value);
                }
            }
            Some(Frame::Seq { items, .. }) => items.push(value),
            Some(Frame::Map { entries, index, key, .. }) => match key.take() {
                None => {
                    if matches!(value, Value::Seq(_) | Value::Map(_)) {
                        return Err(Error("found unhashable key".to_string()));
                    }
                    *key = Some(value);
                }
                Some(k) => match Key::of(&k) {
                    Some(fingerprint) => {
                        if let Some(&at) = index.get(&fingerprint) {
                            entries[at].1 = value;
                        } else {
                            index.insert(fingerprint, entries.len());
                            entries.push((k, value));
                        }
                    }
                    // NaN is never equal to itself, so every NaN key is a new entry.
                    None => entries.push((k, value)),
                },
            },
        }
        Ok(())
    }
}

/// Equality of keys as Python's `dict` sees it: `1`, `1.0` and `True` are one key.
#[derive(Hash, PartialEq, Eq)]
enum Key {
    Null,
    Number(i128),
    Float(u64),
    Str(String),
    Timestamp(String),
}

impl Key {
    fn of(value: &Value) -> Option<Key> {
        Some(match value {
            Value::Null => Key::Null,
            Value::Bool(b) => Key::Number(i128::from(*b)),
            Value::Int(i) => Key::Number(*i),
            Value::Float(f) if f.is_nan() => return None,
            #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
            Value::Float(f) if f.fract() == 0.0 && f.abs() < 1e38 => Key::Number(*f as i128),
            Value::Float(f) => Key::Float((*f + 0.0).to_bits()),
            Value::Str(s) => Key::Str(s.clone()),
            Value::Timestamp(s) => Key::Timestamp(s.clone()),
            Value::Seq(_) | Value::Map(_) => return None,
        })
    }
}

const CORE: &str = "tag:yaml.org,2002:";

/// The non-specific tag, a lone `!`, which yaml-rust2 reports with an empty handle.
fn is_non_specific(tag: &Tag) -> bool {
    tag.handle.is_empty() && tag.suffix == "!"
}

fn check_collection_tag(tag: Option<&Tag>, kind: &str) -> Result<(), Error> {
    match tag {
        None => Ok(()),
        Some(tag) if is_non_specific(tag) => Ok(()),
        Some(tag) if tag.handle == CORE && tag.suffix == kind => Ok(()),
        Some(tag) => Err(Error(format!("unsupported tag {}{}", tag.handle, tag.suffix))),
    }
}

fn resolve_scalar(text: String, style: TScalarStyle, tag: Option<&Tag>) -> Result<Value, Error> {
    let kind = match tag {
        // PyYAML resolves a scalar with the non-specific tag ("!") as if it were plain, quoted or
        // not, and its patterns end in `$`, which also matches before a final newline.
        Some(tag) if is_non_specific(tag) => {
            let trimmed = text.strip_suffix('\n').unwrap_or(&text);
            match implicit_kind(trimmed) {
                "str" => "str",
                kind => {
                    return resolve_scalar(trimmed.to_owned(), TScalarStyle::Plain, None).and_then(|value| {
                        if kind == "bool" && trimmed.len() != text.len() {
                            Err(Error("not a boolean".to_string()))
                        } else {
                            Ok(value)
                        }
                    });
                }
            }
        }
        Some(tag) if tag.handle == CORE => tag.suffix.as_str(),
        Some(tag) => return Err(Error(format!("unsupported tag {}{}", tag.handle, tag.suffix))),
        None if style == TScalarStyle::Plain => implicit_kind(&text),
        None => "str",
    };
    match kind {
        "str" => Ok(Value::Str(text)),
        "null" => Ok(Value::Null),
        "bool" => match text.to_lowercase().as_str() {
            "yes" | "true" | "on" => Ok(Value::Bool(true)),
            "no" | "false" | "off" => Ok(Value::Bool(false)),
            _ => Err(Error(format!("not a boolean: {text}"))),
        },
        "int" => construct_int(&text).map(Value::Int),
        "float" => construct_float(&text).map(Value::Float),
        "timestamp" => Ok(Value::Timestamp(text)),
        other => Err(Error(format!("unsupported scalar type {other}"))),
    }
}

/// The type PyYAML's implicit resolvers give a plain scalar, tried in the order PyYAML adds them.
fn implicit_kind(text: &str) -> &'static str {
    if is_bool(text) {
        "bool"
    } else if is_float(text) {
        "float"
    } else if is_int(text) {
        "int"
    } else if text == "<<" {
        "merge"
    } else if matches!(text, "~" | "null" | "Null" | "NULL" | "") {
        "null"
    } else if is_timestamp(text) {
        "timestamp"
    } else if text == "=" {
        "value"
    } else {
        "str"
    }
}

fn is_bool(text: &str) -> bool {
    matches!(
        text,
        "yes"
            | "Yes"
            | "YES"
            | "no"
            | "No"
            | "NO"
            | "true"
            | "True"
            | "TRUE"
            | "false"
            | "False"
            | "FALSE"
            | "on"
            | "On"
            | "ON"
            | "off"
            | "Off"
            | "OFF"
    )
}

/// A tiny cursor for the resolver patterns, which are simple enough not to need a regex engine.
struct Cursor<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn new(text: &'a str) -> Self {
        Self { bytes: text.as_bytes(), at: 0 }
    }

    fn done(&self) -> bool {
        self.at == self.bytes.len()
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn eat(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.at += 1;
            true
        } else {
            false
        }
    }

    fn eat_sign(&mut self) {
        if !self.eat(b'-') {
            self.eat(b'+');
        }
    }

    /// Consumes bytes while `accept` holds; how many.
    fn many(&mut self, accept: impl Fn(u8) -> bool) -> usize {
        let start = self.at;
        while self.peek().is_some_and(&accept) {
            self.at += 1;
        }
        self.at - start
    }

    fn digit_then_digits_or_underscores(&mut self) -> bool {
        if self.peek().is_some_and(|b| b.is_ascii_digit()) {
            self.at += 1;
            self.many(|b| b.is_ascii_digit() || b == b'_');
            true
        } else {
            false
        }
    }

    /// `(?::[0-5]?[0-9])+`
    fn sexagesimal_parts(&mut self) -> bool {
        let mut parts = 0;
        loop {
            let save = self.at;
            if !self.eat(b':') {
                break;
            }
            let digits = self.many(|b| b.is_ascii_digit());
            let ok = match digits {
                1 => true,
                2 => self.bytes[self.at - 2] <= b'5',
                _ => false,
            };
            if !ok {
                self.at = save;
                break;
            }
            parts += 1;
        }
        parts > 0
    }

    /// `(?:[eE][-+][0-9]+)?`
    fn optional_exponent(&mut self) {
        let save = self.at;
        if (self.eat(b'e') || self.eat(b'E'))
            && (self.eat(b'-') || self.eat(b'+'))
            && self.many(|b| b.is_ascii_digit()) > 0
        {
            return;
        }
        self.at = save;
    }
}

fn whole(text: &str, pattern: impl Fn(&mut Cursor) -> bool) -> bool {
    let mut cursor = Cursor::new(text);
    pattern(&mut cursor) && cursor.done()
}

fn is_float(text: &str) -> bool {
    // [-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?
    whole(text, |c| {
        c.eat_sign();
        if !c.digit_then_digits_or_underscores() || !c.eat(b'.') {
            return false;
        }
        c.many(|b| b.is_ascii_digit() || b == b'_');
        c.optional_exponent();
        true
    })
    // \.[0-9][0-9_]*(?:[eE][-+][0-9]+)?
    || whole(text, |c| {
        if !c.eat(b'.') || !c.digit_then_digits_or_underscores() {
            return false;
        }
        c.optional_exponent();
        true
    })
    // [-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*
    || whole(text, |c| {
        c.eat_sign();
        if !c.digit_then_digits_or_underscores() || !c.sexagesimal_parts() || !c.eat(b'.') {
            return false;
        }
        c.many(|b| b.is_ascii_digit() || b == b'_');
        true
    })
    || matches!(text, ".inf" | ".Inf" | ".INF" | "-.inf" | "-.Inf" | "-.INF" | "+.inf" | "+.Inf" | "+.INF")
    || matches!(text, ".nan" | ".NaN" | ".NAN")
}

fn is_int(text: &str) -> bool {
    let signed_prefix = |prefix: &'static [u8], accept: fn(u8) -> bool| {
        move |c: &mut Cursor| {
            c.eat_sign();
            prefix.iter().all(|&b| c.eat(b)) && c.many(accept) > 0
        }
    };
    whole(text, signed_prefix(b"0b", |b| matches!(b, b'0' | b'1' | b'_')))
        || whole(text, signed_prefix(b"0", |b| matches!(b, b'0'..=b'7' | b'_')))
        || whole(text, |c| {
            c.eat_sign();
            c.eat(b'0')
                || (c.peek().is_some_and(|b| (b'1'..=b'9').contains(&b)) && c.digit_then_digits_or_underscores())
        })
        || whole(text, signed_prefix(b"0x", |b| b.is_ascii_hexdigit() || b == b'_'))
        || whole(text, |c| {
            c.eat_sign();
            c.peek().is_some_and(|b| (b'1'..=b'9').contains(&b))
                && c.digit_then_digits_or_underscores()
                && c.sexagesimal_parts()
        })
}

fn is_date(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
}

fn is_timestamp(text: &str) -> bool {
    if is_date(text) {
        return true;
    }
    // [0-9]{4}-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?
    //   (?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?
    whole(text, |c| {
        let digits = |c: &mut Cursor, min: usize, max: usize| {
            let n = c.many(|b| b.is_ascii_digit());
            (min..=max).contains(&n)
        };
        if !(digits(c, 4, 4) && c.eat(b'-') && digits(c, 1, 2) && c.eat(b'-') && digits(c, 1, 2)) {
            return false;
        }
        if !(c.eat(b'T') || c.eat(b't') || c.many(|b| b == b' ' || b == b'\t') > 0) {
            return false;
        }
        if !(digits(c, 1, 2) && c.eat(b':') && digits(c, 2, 2) && c.eat(b':') && digits(c, 2, 2)) {
            return false;
        }
        if c.eat(b'.') {
            c.many(|b| b.is_ascii_digit());
        }
        let save = c.at;
        c.many(|b| b == b' ' || b == b'\t');
        if c.eat(b'Z') {
            return true;
        }
        if c.eat(b'-') || c.eat(b'+') {
            if !digits(c, 1, 2) {
                return false;
            }
            if c.eat(b':') {
                return digits(c, 2, 2);
            }
            return true;
        }
        c.at = save;
        true
    })
}

fn construct_int(text: &str) -> Result<i128, Error> {
    let invalid = || Error(format!("not an integer: {text}"));
    let cleaned: String = text.chars().filter(|&c| c != '_').collect();
    let (sign, digits) = match cleaned.as_bytes().first() {
        Some(b'-') => (-1, &cleaned[1..]),
        Some(b'+') => (1, &cleaned[1..]),
        Some(_) => (1, cleaned.as_str()),
        None => return Err(invalid()),
    };
    let magnitude = if digits == "0" {
        0
    } else if let Some(bits) = digits.strip_prefix("0b") {
        i128::from_str_radix(bits, 2).map_err(|_| invalid())?
    } else if let Some(hex) = digits.strip_prefix("0x") {
        i128::from_str_radix(hex, 16).map_err(|_| invalid())?
    } else if digits.starts_with('0') {
        i128::from_str_radix(digits, 8).map_err(|_| invalid())?
    } else if digits.contains(':') {
        let mut value: i128 = 0;
        for part in digits.split(':') {
            let part: i128 = part.parse().map_err(|_| invalid())?;
            value = value.checked_mul(60).and_then(|v| v.checked_add(part)).ok_or_else(invalid)?;
        }
        value
    } else {
        digits.parse().map_err(|_| invalid())?
    };
    let value = sign * magnitude;
    if i64::try_from(value).is_err() && u64::try_from(value).is_err() {
        return Err(Error(format!("integer out of range: {text}")));
    }
    Ok(value)
}

fn construct_float(text: &str) -> Result<f64, Error> {
    let invalid = || Error(format!("not a float: {text}"));
    let cleaned: String = text.chars().filter(|&c| c != '_').collect::<String>().to_lowercase();
    let (sign, rest) = match cleaned.as_bytes().first() {
        Some(b'-') => (-1.0, &cleaned[1..]),
        Some(b'+') => (1.0, &cleaned[1..]),
        Some(_) => (1.0, cleaned.as_str()),
        None => return Err(invalid()),
    };
    if rest == ".inf" {
        return Ok(sign * f64::INFINITY);
    }
    if rest == ".nan" {
        return Ok(f64::NAN);
    }
    if rest.contains(':') {
        let mut value = 0.0;
        for part in rest.split(':') {
            value = value * 60.0 + python_float(part).ok_or_else(invalid)?;
        }
        return Ok(sign * value);
    }
    python_float(rest).map(|v| sign * v).ok_or_else(invalid)
}

/// Python's `float()` of the decimal forms the resolver admits ("1.", ".5", "1.e+5").
fn python_float(text: &str) -> Option<f64> {
    let normalized = if let Some((mantissa, exponent)) = text.split_once('e') {
        format!("{}e{exponent}", pad_mantissa(mantissa))
    } else {
        pad_mantissa(text)
    };
    normalized.parse().ok()
}

fn pad_mantissa(mantissa: &str) -> String {
    let mut out = String::with_capacity(mantissa.len() + 2);
    if mantissa.starts_with('.') {
        out.push('0');
    }
    out.push_str(mantissa);
    if mantissa.ends_with('.') {
        out.push('0');
    }
    out
}

/// Python's `repr(float)`: the shortest digits that round-trip, positional for decimal exponents
/// from -4 to 15 and scientific (`1e+16`, `1.5e-05`) outside them.
///
/// # Panics
///
/// Never: the `expect`s hold for every finite `f64`.
pub fn py_float_repr(value: f64) -> String {
    if value.is_nan() {
        return "nan".to_string();
    }
    if value.is_infinite() {
        return if value > 0.0 { "inf" } else { "-inf" }.to_string();
    }
    // Rust's `{:e}` prints the shortest round-trip digits, as Python's repr does.
    let scientific = format!("{value:e}");
    let (mantissa, exponent) = scientific.split_once('e').expect("{:e} always has an exponent");
    let exponent: i32 = exponent.parse().expect("{:e} prints an integer exponent");
    let negative = mantissa.starts_with('-');
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let sign = if negative { "-" } else { "" };
    if (-4..16).contains(&exponent) {
        let point = exponent + 1;
        let body = if point <= 0 {
            format!("0.{}{digits}", "0".repeat(usize::try_from(-point).unwrap_or(0)))
        } else {
            let point = usize::try_from(point).unwrap_or(0);
            if digits.len() <= point {
                format!("{digits}{}.0", "0".repeat(point - digits.len()))
            } else {
                format!("{}.{}", &digits[..point], &digits[point..])
            }
        };
        format!("{sign}{body}")
    } else {
        let mantissa = if digits.len() == 1 { digits } else { format!("{}.{}", &digits[..1], &digits[1..]) };
        let exponent_sign = if exponent < 0 { '-' } else { '+' };
        format!("{sign}{mantissa}e{exponent_sign}{:02}", exponent.abs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(text: &str) -> Value {
        match parse(&format!("k: {text}")).unwrap() {
            Some(Value::Map(mut entries)) => entries.remove(0).1,
            other => panic!("not a mapping: {other:?}"),
        }
    }

    #[test]
    fn resolves_plain_scalars_as_yaml_1_1() {
        assert_eq!(one("yes"), Value::Bool(true));
        assert_eq!(one("Off"), Value::Bool(false));
        assert_eq!(one("y"), Value::Str("y".into()));
        assert_eq!(one("~"), Value::Null);
        assert_eq!(one(""), Value::Null);
        assert_eq!(one("null"), Value::Null);
        assert_eq!(one("42"), Value::Int(42));
        assert_eq!(one("-1_000"), Value::Int(-1000));
        assert_eq!(one("0755"), Value::Int(0o755));
        assert_eq!(one("0x1F"), Value::Int(31));
        assert_eq!(one("0b101"), Value::Int(5));
        assert_eq!(one("1:30"), Value::Int(90));
        assert_eq!(one("09"), Value::Str("09".into()));
        assert_eq!(one("1.5"), Value::Float(1.5));
        assert_eq!(one("1."), Value::Float(1.0));
        assert_eq!(one(".5"), Value::Float(0.5));
        assert_eq!(one("1.e+5"), Value::Float(100_000.0));
        assert_eq!(one("1:30.5"), Value::Float(90.5));
        assert_eq!(one("1e3"), Value::Str("1e3".into()));
        assert_eq!(one("-.inf"), Value::Float(f64::NEG_INFINITY));
        assert!(matches!(one(".nan"), Value::Float(f) if f.is_nan()));
        assert_eq!(one("2024-01-31"), Value::Timestamp("2024-01-31".into()));
        assert_eq!(one("2024-1-31 10:00:00Z"), Value::Timestamp("2024-1-31 10:00:00Z".into()));
        assert_eq!(one("2024-1-31"), Value::Str("2024-1-31".into()));
        assert_eq!(one("hello world"), Value::Str("hello world".into()));
    }

    #[test]
    fn quoted_and_tagged_scalars_are_strings() {
        assert_eq!(one("'yes'"), Value::Str("yes".into()));
        assert_eq!(one("\"42\""), Value::Str("42".into()));
        assert_eq!(one("!!str 42"), Value::Str("42".into()));
        // The non-specific tag resolves as a plain scalar would, quoted or not.
        assert_eq!(one("! 42"), Value::Int(42));
        assert_eq!(one("! \"42\""), Value::Int(42));
        assert_eq!(one("! |\n  12\n"), Value::Int(12));
        assert_eq!(one("! words"), Value::Str("words".into()));
        assert_eq!(one("!!int '42'"), Value::Int(42));
    }

    #[test]
    fn mappings_behave_like_a_python_dict() {
        let parsed = parse("a: 1\nb: 2\na: 3\n1: x\n1.0: y\ntrue: z\n").unwrap().unwrap();
        assert_eq!(
            parsed,
            Value::Map(vec![
                (Value::Str("a".into()), Value::Int(3)),
                (Value::Str("b".into()), Value::Int(2)),
                (Value::Int(1), Value::Str("z".into())),
            ])
        );
    }

    #[test]
    fn aliases_copy_their_anchor() {
        let parsed = parse("a: &x [1, 2]\nb: *x\n").unwrap().unwrap();
        let Value::Map(entries) = parsed else { panic!() };
        assert_eq!(entries[0].1, entries[1].1);
    }

    #[test]
    fn refuses_what_it_does_not_model() {
        assert!(parse("<<: {a: 1}").is_err());
        assert!(parse("a: !!binary aGk=").is_err());
        assert!(parse("a: !local x").is_err());
        assert!(parse("[a]: 1").is_err());
        assert!(parse("a: 99999999999999999999999").is_err());
        assert!(parse("a: [1").is_err());
        assert!(parse("a: 1\n---\nb: 2\n").is_err());
        assert!(parse("a: x\0y").is_err());
        assert!(parse("a: \u{93}").is_err());
        assert!(parse("a: \u{85}\u{a0}\u{1F600}").is_ok());
    }

    #[test]
    fn a_block_scalar_at_the_end_keeps_only_the_breaks_it_has() {
        assert_eq!(one("|\n  a\n  b"), Value::Str("a\nb".into()));
        assert_eq!(one("|\n  a\n  b\n"), Value::Str("a\nb\n".into()));
        assert_eq!(one(">\n  a\n  b"), Value::Str("a b".into()));
        assert_eq!(one("|-\n  a"), Value::Str("a".into()));
        assert_eq!(one("\"a\\n\""), Value::Str("a\n".into()));
        // The last block scalar of the input, though an earlier key's.
        assert_eq!(
            parse("a: 1\nb: 2\na: |\n  x").unwrap().unwrap(),
            Value::Map(
                vec![(Value::Str("a".into()), Value::Str("x".into())), (Value::Str("b".into()), Value::Int(2)),]
            )
        );
    }

    #[test]
    fn empty_is_none() {
        assert_eq!(parse("").unwrap(), None);
        assert_eq!(parse("# only a comment\n").unwrap(), None);
    }

    #[test]
    fn float_repr_matches_python() {
        for (value, expected) in [
            (1.0, "1.0"),
            (-0.0, "-0.0"),
            (0.1, "0.1"),
            (123.456, "123.456"),
            (1e15, "1000000000000000.0"),
            (1e16, "1e+16"),
            (1.5e16, "1.5e+16"),
            (0.0001, "0.0001"),
            (0.00001, "1e-05"),
            (1.25e-7, "1.25e-07"),
            (1e100, "1e+100"),
            (f64::INFINITY, "inf"),
        ] {
            assert_eq!(py_float_repr(value), expected, "{value}");
        }
    }
}
