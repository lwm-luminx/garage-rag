//! Python's `email.utils.parseaddr` (strict, as of 3.13), which attribution uses to read a message's
//! senders: `email._parseaddr.AddrlistClass` ported line for line, with the strict mode's checks
//! around it, so a sender splits into the same name and address it does in Python.

const SPECIALS: &str = "()<>@,:;.\"[]";
const LWS: &str = " \t";
const CR: &str = "\r\n";

struct Parser {
    field: Vec<char>,
    pos: usize,
    comments: Vec<String>,
}

fn is_atom_end(ch: char) -> bool {
    SPECIALS.contains(ch) || LWS.contains(ch) || CR.contains(ch)
}

fn is_phrase_end(ch: char) -> bool {
    ch != '.' && is_atom_end(ch)
}

fn quote(text: &str) -> String {
    text.replace('\\', "\\\\").replace('"', "\\\"")
}

impl Parser {
    fn new(field: &str) -> Self {
        Self { field: field.chars().collect(), pos: 0, comments: Vec::new() }
    }

    fn at(&self) -> Option<char> {
        self.field.get(self.pos).copied()
    }

    fn more(&self) -> bool {
        self.pos < self.field.len()
    }

    /// `gotonext`: skips white space and collects comments; returns the spaces and tabs skipped.
    fn goto_next(&mut self) -> String {
        let mut skipped = String::new();
        while let Some(ch) = self.at() {
            if LWS.contains(ch) || ch == '\n' || ch == '\r' {
                if ch != '\n' && ch != '\r' {
                    skipped.push(ch);
                }
                self.pos += 1;
            } else if ch == '(' {
                let comment = self.comment();
                self.comments.push(comment);
            } else {
                break;
            }
        }
        skipped
    }

    fn address_list(&mut self) -> Vec<(String, String)> {
        let mut result = Vec::new();
        while self.more() {
            let address = self.address();
            if address.is_empty() {
                result.push((String::new(), String::new()));
            } else {
                result.extend(address);
            }
        }
        result
    }

    fn address(&mut self) -> Vec<(String, String)> {
        self.comments.clear();
        self.goto_next();
        let old_pos = self.pos;
        let phrases = self.phrase_list();
        self.goto_next();
        let mut result = Vec::new();
        match self.at() {
            None => {
                if let Some(first) = phrases.first() {
                    result.push((self.comments.join(" "), first.clone()));
                }
            }
            Some('.' | '@') => {
                // Python restores its comment list here, but the saved name is the same list object,
                // so the comments read so far stay and the addr-spec's pass reads them again.
                self.pos = old_pos;
                let spec = self.addr_spec();
                result.push((self.comments.join(" "), spec));
            }
            Some(':') => {
                self.pos += 1;
                while self.more() {
                    self.goto_next();
                    if self.at() == Some(';') {
                        self.pos += 1;
                        break;
                    }
                    let inner = self.address();
                    result.extend(inner);
                }
            }
            Some('<') => {
                let route = self.route_addr();
                if self.comments.is_empty() {
                    result.push((phrases.join(" "), route));
                } else {
                    result.push((format!("{} ({})", phrases.join(" "), self.comments.join(" ")), route));
                }
            }
            Some(ch) => {
                if let Some(first) = phrases.first() {
                    result.push((self.comments.join(" "), first.clone()));
                } else if SPECIALS.contains(ch) {
                    self.pos += 1;
                }
            }
        }
        self.goto_next();
        if self.at() == Some(',') {
            self.pos += 1;
        }
        result
    }

    fn route_addr(&mut self) -> String {
        let mut expect_route = false;
        self.pos += 1;
        self.goto_next();
        let mut spec = String::new();
        while let Some(ch) = self.at() {
            if expect_route {
                self.domain();
                expect_route = false;
            } else if ch == '>' {
                self.pos += 1;
                break;
            } else if ch == '@' {
                self.pos += 1;
                expect_route = true;
            } else if ch == ':' {
                self.pos += 1;
            } else {
                spec = self.addr_spec();
                self.pos += 1;
                break;
            }
            self.goto_next();
        }
        spec
    }

    fn addr_spec(&mut self) -> String {
        let mut parts: Vec<String> = Vec::new();
        self.goto_next();
        while let Some(ch) = self.at() {
            let mut preserve_ws = true;
            if ch == '.' {
                if parts.last().is_some_and(|last| last.trim().is_empty()) {
                    parts.pop();
                }
                parts.push(".".to_owned());
                self.pos += 1;
                preserve_ws = false;
            } else if ch == '"' {
                let quoted = self.quoted();
                parts.push(format!("\"{}\"", quote(&quoted)));
            } else if is_atom_end(ch) {
                if parts.last().is_some_and(|last| last.trim().is_empty()) {
                    parts.pop();
                }
                break;
            } else {
                parts.push(self.atom(is_atom_end));
            }
            let ws = self.goto_next();
            if preserve_ws && !ws.is_empty() {
                parts.push(ws);
            }
        }
        if self.at() != Some('@') {
            return parts.concat();
        }
        parts.push("@".to_owned());
        self.pos += 1;
        self.goto_next();
        let domain = self.domain();
        if domain.is_empty() {
            return String::new();
        }
        parts.concat() + &domain
    }

    fn domain(&mut self) -> String {
        let mut parts = String::new();
        while let Some(ch) = self.at() {
            if LWS.contains(ch) {
                self.pos += 1;
            } else if ch == '(' {
                let comment = self.comment();
                self.comments.push(comment);
            } else if ch == '[' {
                let literal = self.delimited('[', "]\r", false);
                parts.push('[');
                parts.push_str(&literal);
                parts.push(']');
            } else if ch == '.' {
                self.pos += 1;
                parts.push('.');
            } else if ch == '@' {
                return String::new();
            } else if is_atom_end(ch) {
                break;
            } else {
                parts.push_str(&self.atom(is_atom_end));
            }
        }
        parts
    }

    fn delimited(&mut self, begin: char, ends: &str, allow_comments: bool) -> String {
        if self.at() != Some(begin) {
            return String::new();
        }
        let mut out = String::new();
        let mut quoted = false;
        self.pos += 1;
        while let Some(ch) = self.at() {
            if quoted {
                out.push(ch);
                quoted = false;
            } else if ends.contains(ch) {
                self.pos += 1;
                break;
            } else if allow_comments && ch == '(' {
                out.push_str(&self.comment());
                continue;
            } else if ch == '\\' {
                quoted = true;
            } else {
                out.push(ch);
            }
            self.pos += 1;
        }
        out
    }

    fn quoted(&mut self) -> String {
        self.delimited('"', "\"\r", false)
    }

    fn comment(&mut self) -> String {
        self.delimited('(', ")\r", true)
    }

    fn atom(&mut self, ends: fn(char) -> bool) -> String {
        let mut out = String::new();
        while let Some(ch) = self.at() {
            if ends(ch) {
                break;
            }
            out.push(ch);
            self.pos += 1;
        }
        out
    }

    fn phrase_list(&mut self) -> Vec<String> {
        let mut phrases = Vec::new();
        while let Some(ch) = self.at() {
            if LWS.contains(ch) || CR.contains(ch) {
                self.pos += 1;
            } else if ch == '"' {
                phrases.push(self.quoted());
            } else if ch == '(' {
                let comment = self.comment();
                self.comments.push(comment);
            } else if is_phrase_end(ch) {
                break;
            } else {
                phrases.push(self.atom(is_phrase_end));
            }
        }
        phrases
    }
}

/// `_iter_escaped_chars`: each character, a backslash pair as one item.
fn escaped_chars(text: &[char]) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let mut escape = false;
    let mut last = 0;
    for (pos, &ch) in text.iter().enumerate() {
        last = pos;
        if escape {
            out.push((pos, format!("\\{ch}")));
            escape = false;
        } else if ch == '\\' {
            escape = true;
        } else {
            out.push((pos, ch.to_string()));
        }
    }
    if escape {
        out.push((last, "\\".to_owned()));
    }
    out
}

/// `_strip_quoted_realnames`.
fn strip_quoted_realnames(addr: &str) -> String {
    if !addr.contains('"') {
        return addr.to_owned();
    }
    let chars: Vec<char> = addr.chars().collect();
    let mut start = 0;
    let mut open: Option<usize> = None;
    let mut result = String::new();
    for (pos, ch) in escaped_chars(&chars) {
        if ch == "\"" {
            match open {
                None => open = Some(pos),
                Some(open_pos) => {
                    if start != open_pos {
                        result.extend(&chars[start..open_pos]);
                    }
                    start = pos + 1;
                    open = None;
                }
            }
        }
    }
    if start < chars.len() {
        result.extend(&chars[start..]);
    }
    result
}

/// `_check_parenthesis`.
fn balanced_parentheses(addr: &str) -> bool {
    let stripped: Vec<char> = strip_quoted_realnames(addr).chars().collect();
    let mut opens = 0i64;
    for (_, ch) in escaped_chars(&stripped) {
        if ch == "(" {
            opens += 1;
        } else if ch == ")" {
            opens -= 1;
            if opens < 0 {
                return false;
            }
        }
    }
    opens == 0
}

/// `email.utils.parseaddr(addr)`: `(name, address)`, or two empty strings when the parse fails.
#[must_use]
pub fn parseaddr(addr: &str) -> (String, String) {
    let field = if balanced_parentheses(addr) { addr } else { "('', '')" };
    let mut addresses = if field.is_empty() { Vec::new() } else { Parser::new(field).address_list() };
    for address in &mut addresses {
        if address.1.contains('[') {
            *address = (String::new(), String::new());
        }
    }
    if addresses.len() == 1 { addresses.remove(0) } else { (String::new(), String::new()) }
}

#[cfg(test)]
mod tests {
    use super::parseaddr;

    fn pair(name: &str, address: &str) -> (String, String) {
        (name.to_owned(), address.to_owned())
    }

    #[test]
    fn senders_split_as_python_splits_them() {
        for (input, name, address) in [
            ("Ada Lovelace <ada@example.com>", "Ada Lovelace", "ada@example.com"),
            ("ada@example.com", "", "ada@example.com"),
            ("\"Lovelace, Ada\" <ada@example.com>", "Lovelace, Ada", "ada@example.com"),
            ("ada@example.com (Ada Lovelace)", "Ada Lovelace", "ada@example.com"),
            ("Ada", "", "Ada"),
            ("", "", ""),
            ("Ada <ada@example.com>, Bob <b@x>", "", ""),
            ("Ada Lovelace", "", "Ada"),
            ("  Ada  <  ada@x  >  ", "Ada", "ada@x"),
            ("a@b@c", "", ""),
            ("Ada <ada@x", "Ada", "ada@x"),
            ("\"unterminated <a@x>", "", "unterminated <a@x>"),
            ("Ada (comment) <a@x>", "Ada (comment)", "a@x"),
            ("Mr. Ada <a@x>", "Mr. Ada", "a@x"),
            ("ada at x", "", "ada"),
            ("Ada <>", "Ada", ""),
            ("Zoë <zoe@x.org>", "Zoë", "zoe@x.org"),
        ] {
            assert_eq!(parseaddr(input), pair(name, address), "{input:?}");
        }
    }
}
