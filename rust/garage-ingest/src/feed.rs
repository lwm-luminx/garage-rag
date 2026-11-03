//! Counting the entries of a feed file: `scanner._count_feed_items`.
//!
//! Python tries three readings in turn: a JSON Feed's `items`, then the elements of an XML
//! document (`xml.etree.ElementTree.fromstring`, which is expat with namespaces) whose tag ends in
//! `item` or `entry`, and last a regular expression over the raw text. Which one answers depends on
//! whether expat accepts the document, so [`xml_entries`] checks what expat checks: well-formedness,
//! entity references, and namespace prefixes bound to a declaration. A document it would reject
//! falls through to the expression, as in Python.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

static FALLBACK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)<(?:[a-zA-Z0-9_]+:)?(?:item|entry)\b").expect("the fallback pattern compiles"));

/// Python's `str.isspace`, which also counts the information separators U+001C to U+001F.
fn python_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// The entries in a feed file's bytes, read as UTF-8 with replacement as Python reads them.
pub fn count_feed_items(bytes: &[u8]) -> u64 {
    let content = String::from_utf8_lossy(bytes);
    // Python reads the file in text mode, which turns \r\n and \r into \n.
    let content = content.replace("\r\n", "\n").replace('\r', "\n");
    let stripped = content.trim_matches(python_space);
    if stripped.starts_with('{')
        && stripped.ends_with('}')
        && let Ok(Value::Object(data)) = serde_json::from_str::<Value>(stripped)
        && let Some(Value::Array(items)) = data.get("items")
    {
        return items.len() as u64;
    }
    if let Some(count) = xml_entries(&content)
        && count > 0
    {
        return count;
    }
    FALLBACK.find_iter(&content).count() as u64
}

/// The elements of `text` whose local name, lowercased, ends in `item` or `entry`, or None when
/// expat would not parse it.
pub fn xml_entries(text: &str) -> Option<u64> {
    let mut parser = Parser { chars: text.chars().collect(), at: 0, entities: HashSet::new(), count: 0 };
    parser.document().ok()?;
    Some(parser.count)
}

struct Parser {
    chars: Vec<char>,
    at: usize,
    /// General entities the internal DTD subset declares with a literal value.
    entities: HashSet<String>,
    count: u64,
}

type Parsed<T = ()> = Result<T, ()>;

fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r')
}

fn is_xml_char(c: char) -> bool {
    matches!(c, '\t' | '\n' | '\r' | '\u{20}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}' | '\u{10000}'..='\u{10ffff}')
}

fn is_name_start(c: char) -> bool {
    matches!(c,
        ':' | 'A'..='Z' | '_' | 'a'..='z' | '\u{c0}'..='\u{d6}' | '\u{d8}'..='\u{f6}' | '\u{f8}'..='\u{2ff}'
        | '\u{370}'..='\u{37d}' | '\u{37f}'..='\u{1fff}' | '\u{200c}'..='\u{200d}' | '\u{2070}'..='\u{218f}'
        | '\u{2c00}'..='\u{2fef}' | '\u{3001}'..='\u{d7ff}' | '\u{f900}'..='\u{fdcf}' | '\u{fdf0}'..='\u{fffd}'
        | '\u{10000}'..='\u{effff}')
}

fn is_name_char(c: char) -> bool {
    is_name_start(c) || matches!(c, '-' | '.' | '0'..='9' | '\u{b7}' | '\u{300}'..='\u{36f}' | '\u{203f}'..='\u{2040}')
}

/// Namespace bindings in scope: prefix (empty for the default) to URI.
type Scope = HashMap<String, String>;

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    fn starts_with(&self, text: &str) -> bool {
        let mut at = self.at;
        for c in text.chars() {
            if self.chars.get(at) != Some(&c) {
                return false;
            }
            at += 1;
        }
        true
    }

    fn eat(&mut self, text: &str) -> bool {
        if self.starts_with(text) {
            self.at += text.chars().count();
            true
        } else {
            false
        }
    }

    fn expect(&mut self, text: &str) -> Parsed {
        if self.eat(text) { Ok(()) } else { Err(()) }
    }

    /// Skips whitespace, returning whether there was any.
    fn space(&mut self) -> bool {
        let start = self.at;
        while self.peek().is_some_and(is_space) {
            self.at += 1;
        }
        self.at > start
    }

    fn name(&mut self) -> Parsed<String> {
        let start = self.at;
        if !self.peek().is_some_and(is_name_start) {
            return Err(());
        }
        while self.peek().is_some_and(is_name_char) {
            self.at += 1;
        }
        Ok(self.chars[start..self.at].iter().collect())
    }

    /// Text up to `end` (consumed), every character a legal XML character.
    fn until(&mut self, end: &str) -> Parsed<String> {
        let start = self.at;
        while !self.starts_with(end) {
            let c = self.peek().ok_or(())?;
            if !is_xml_char(c) {
                return Err(());
            }
            self.at += 1;
        }
        let text = self.chars[start..self.at].iter().collect();
        self.at += end.chars().count();
        Ok(text)
    }

    fn quoted(&mut self) -> Parsed<String> {
        let quote = self.peek().filter(|&c| c == '"' || c == '\'').ok_or(())?;
        self.at += 1;
        self.until(&quote.to_string())
    }

    fn document(&mut self) -> Parsed {
        self.eat("\u{feff}");
        if self.starts_with("<?xml") && self.chars.get(self.at + 5).is_some_and(|&c| is_space(c) || c == '?') {
            self.xml_declaration()?;
        }
        self.misc()?;
        if self.starts_with("<!DOCTYPE") {
            self.doctype()?;
            self.misc()?;
        }
        if self.peek() != Some('<') {
            return Err(());
        }
        let scope = Scope::from([("xml".to_owned(), "http://www.w3.org/XML/1998/namespace".to_owned())]);
        self.element(&scope)?;
        self.misc()?;
        if self.at == self.chars.len() { Ok(()) } else { Err(()) }
    }

    fn xml_declaration(&mut self) -> Parsed {
        self.expect("<?xml")?;
        let mut seen = Vec::new();
        loop {
            let spaced = self.space();
            if self.eat("?>") {
                break;
            }
            if !spaced {
                return Err(());
            }
            let name = self.name()?;
            self.space();
            self.expect("=")?;
            self.space();
            let value = self.quoted()?;
            let valid = match name.as_str() {
                "version" => {
                    seen.is_empty()
                        && !value.is_empty()
                        && value.chars().all(|c| c.is_ascii_alphanumeric() || "_.:-".contains(c))
                }
                "encoding" => {
                    seen == ["version"]
                        && value.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
                        && value.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
                }
                "standalone" => {
                    seen.first().is_some_and(|first| first == "version")
                        && !seen.contains(&"standalone".to_owned())
                        && (value == "yes" || value == "no")
                }
                _ => false,
            };
            if !valid {
                return Err(());
            }
            seen.push(name);
        }
        if seen.first().is_some_and(|first| first == "version") { Ok(()) } else { Err(()) }
    }

    /// Comments, processing instructions and whitespace, outside the root element.
    fn misc(&mut self) -> Parsed {
        loop {
            self.space();
            if self.starts_with("<!--") {
                self.comment()?;
            } else if self.starts_with("<?") {
                self.processing_instruction()?;
            } else {
                return Ok(());
            }
        }
    }

    fn comment(&mut self) -> Parsed {
        self.expect("<!--")?;
        let body = self.until("-->")?;
        if body.contains("--") || body.ends_with('-') { Err(()) } else { Ok(()) }
    }

    fn processing_instruction(&mut self) -> Parsed {
        self.expect("<?")?;
        let target = self.name()?;
        if target.eq_ignore_ascii_case("xml") {
            return Err(());
        }
        if self.eat("?>") {
            return Ok(());
        }
        if !self.space() {
            return Err(());
        }
        self.until("?>").map(drop)
    }

    fn doctype(&mut self) -> Parsed {
        self.expect("<!DOCTYPE")?;
        if !self.space() {
            return Err(());
        }
        self.name()?;
        let spaced = self.space();
        if spaced && (self.starts_with("SYSTEM") || self.starts_with("PUBLIC")) {
            self.external_id()?;
            self.space();
        }
        if self.eat("[") {
            self.internal_subset()?;
            self.space();
        }
        self.expect(">")
    }

    fn external_id(&mut self) -> Parsed {
        if self.eat("SYSTEM") {
            if !self.space() {
                return Err(());
            }
            self.quoted()?;
        } else {
            self.expect("PUBLIC")?;
            if !self.space() {
                return Err(());
            }
            self.quoted()?;
            if !self.space() {
                return Err(());
            }
            self.quoted()?;
        }
        Ok(())
    }

    fn internal_subset(&mut self) -> Parsed {
        loop {
            self.space();
            if self.eat("]") {
                return Ok(());
            }
            if self.starts_with("<!--") {
                self.comment()?;
            } else if self.starts_with("<?") {
                self.processing_instruction()?;
            } else if self.eat("<!ENTITY") {
                self.entity_declaration()?;
            } else if self.eat("<!") {
                // ELEMENT, ATTLIST, NOTATION: not read further, only skipped.
                self.name()?;
                loop {
                    match self.peek().ok_or(())? {
                        '>' => {
                            self.at += 1;
                            break;
                        }
                        '"' | '\'' => {
                            self.quoted()?;
                        }
                        _ => self.at += 1,
                    }
                }
            } else if self.eat("%") {
                self.name()?;
                self.expect(";")?;
            } else {
                return Err(());
            }
        }
    }

    fn entity_declaration(&mut self) -> Parsed {
        if !self.space() {
            return Err(());
        }
        let parameter = self.eat("%");
        if parameter && !self.space() {
            return Err(());
        }
        let name = self.name()?;
        if !self.space() {
            return Err(());
        }
        if self.starts_with("SYSTEM") || self.starts_with("PUBLIC") {
            // An external entity is not loaded, so a reference to it fails like an undefined one.
            self.external_id()?;
            self.space();
            if self.eat("NDATA") {
                self.space();
                self.name()?;
            }
        } else {
            self.quoted()?;
            if !parameter {
                self.entities.insert(name);
            }
        }
        self.space();
        self.expect(">")
    }

    /// A reference after its `&`: a character reference or a declared or predefined entity.
    fn reference(&mut self) -> Parsed {
        if self.eat("#") {
            let hex = self.eat("x");
            let start = self.at;
            while self.peek().is_some_and(|c| if hex { c.is_ascii_hexdigit() } else { c.is_ascii_digit() }) {
                self.at += 1;
            }
            let digits: String = self.chars[start..self.at].iter().collect();
            self.expect(";")?;
            let code = u32::from_str_radix(&digits, if hex { 16 } else { 10 }).map_err(drop)?;
            return if char::from_u32(code).is_some_and(is_xml_char) { Ok(()) } else { Err(()) };
        }
        let name = self.name()?;
        self.expect(";")?;
        if matches!(name.as_str(), "amp" | "lt" | "gt" | "apos" | "quot") || self.entities.contains(&name) {
            Ok(())
        } else {
            Err(())
        }
    }

    fn attribute_value(&mut self) -> Parsed {
        let quote = self.peek().filter(|&c| c == '"' || c == '\'').ok_or(())?;
        self.at += 1;
        loop {
            match self.peek().ok_or(())? {
                c if c == quote => {
                    self.at += 1;
                    return Ok(());
                }
                '<' => return Err(()),
                '&' => {
                    self.at += 1;
                    self.reference()?;
                }
                c if is_xml_char(c) => self.at += 1,
                _ => return Err(()),
            }
        }
    }

    fn element(&mut self, outer: &Scope) -> Parsed {
        self.expect("<")?;
        let tag = self.name()?;
        let mut attributes: Vec<(String, usize)> = Vec::new();
        let mut scope = outer.clone();
        let mut declarations = Vec::new();
        loop {
            let spaced = self.space();
            if self.starts_with("/>") || self.starts_with(">") {
                break;
            }
            if !spaced {
                return Err(());
            }
            let name = self.name()?;
            self.space();
            self.expect("=")?;
            self.space();
            let start = self.at;
            self.attribute_value()?;
            if attributes.iter().any(|(seen, _)| *seen == name) {
                return Err(());
            }
            if name == "xmlns" || name.starts_with("xmlns:") {
                let value: String = self.chars[start + 1..self.at - 1].iter().collect();
                declarations.push((name.clone(), value));
            }
            attributes.push((name, start));
        }
        for (name, value) in declarations {
            match name.strip_prefix("xmlns:") {
                None => {
                    scope.insert(String::new(), value);
                }
                Some(prefix) => {
                    if value.is_empty() || prefix == "xmlns" || prefix.contains(':') {
                        return Err(());
                    }
                    scope.insert(prefix.to_owned(), value);
                }
            }
        }
        let local = qualified(&tag, &scope)?;
        let mut expanded = HashSet::new();
        for (name, _) in &attributes {
            if name == "xmlns" || name.starts_with("xmlns:") {
                continue;
            }
            if !expanded.insert(qualified_attribute(name, &scope)?) {
                return Err(());
            }
        }
        let lowered = local.to_lowercase();
        if lowered.ends_with("item") || lowered.ends_with("entry") {
            self.count += 1;
        }
        if self.eat("/>") {
            return Ok(());
        }
        self.expect(">")?;
        self.content(&scope)?;
        self.expect("</")?;
        if self.name()? != tag {
            return Err(());
        }
        self.space();
        self.expect(">")
    }

    fn content(&mut self, scope: &Scope) -> Parsed {
        loop {
            if self.starts_with("</") {
                return Ok(());
            }
            if self.starts_with("<!--") {
                self.comment()?;
            } else if self.eat("<![CDATA[") {
                self.until("]]>")?;
            } else if self.starts_with("<?") {
                self.processing_instruction()?;
            } else if self.starts_with("<") {
                self.element(scope)?;
            } else if self.eat("&") {
                self.reference()?;
            } else if self.starts_with("]]>") {
                return Err(());
            } else {
                let c = self.peek().ok_or(())?;
                if !is_xml_char(c) {
                    return Err(());
                }
                self.at += 1;
            }
        }
    }
}

/// An element's local name once its prefix is resolved, or Err for a name expat refuses: more
/// than one colon, an empty part, or a prefix with no binding.
fn qualified(name: &str, scope: &Scope) -> Parsed<String> {
    match name.split_once(':') {
        None => Ok(name.to_owned()),
        Some((prefix, local)) => {
            if prefix.is_empty() || local.is_empty() || local.contains(':') || !scope.contains_key(prefix) {
                Err(())
            } else {
                Ok(local.to_owned())
            }
        }
    }
}

/// An attribute's expanded name: unprefixed attributes are in no namespace.
fn qualified_attribute(name: &str, scope: &Scope) -> Parsed<(String, String)> {
    match name.split_once(':') {
        None => Ok((String::new(), name.to_owned())),
        Some((prefix, _)) => {
            let local = qualified(name, scope)?;
            Ok((scope[prefix].clone(), local))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_feeds_count_their_items() {
        assert_eq!(count_feed_items(br#" {"version": "x", "items": [{}, {}, {}]} "#), 3);
        assert_eq!(count_feed_items(br#"{"items": 3}"#), 0);
    }

    #[test]
    fn xml_feeds_count_item_and_entry_elements() {
        let rss = br#"<?xml version="1.0" encoding="UTF-8"?><rss><channel><item/><item><title>a &amp; b</title></item></channel></rss>"#;
        assert_eq!(count_feed_items(rss), 2);
        let atom = br#"<feed xmlns="http://www.w3.org/2005/Atom"><entry/><a:LineItem xmlns:a="u"/></feed>"#;
        assert_eq!(count_feed_items(atom), 2);
    }

    #[test]
    fn malformed_xml_falls_back_to_the_expression() {
        // &nbsp; is undefined, so expat fails and every <item and <entry counts, nested or not.
        assert_eq!(xml_entries("<rss><item>&nbsp;</item></rss>"), None);
        assert_eq!(count_feed_items(b"<rss><item>&nbsp;</item><dc:entry></rss>"), 2);
        // An unbound prefix is an error too.
        assert_eq!(xml_entries("<rss><x:item/></rss>"), None);
        assert_eq!(xml_entries("<a></b>"), None);
        assert_eq!(xml_entries("<a/><b/>"), None);
        assert_eq!(xml_entries("<a><!-- x -- y --></a>"), None);
    }

    #[test]
    fn a_parsed_document_with_no_entries_still_tries_the_expression() {
        assert_eq!(xml_entries("<a><![CDATA[<item>]]></a>"), Some(0));
        assert_eq!(count_feed_items(b"<a><![CDATA[<item>]]></a>"), 1);
    }

    #[test]
    fn declared_entities_are_defined() {
        let text = r#"<!DOCTYPE rss [<!ENTITY nbsp "&#160;">]><rss><item>&nbsp;</item></rss>"#;
        assert_eq!(xml_entries(text), Some(1));
    }
}
