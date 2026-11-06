//! Names for message handles (`extract/contact_names.py`): turning `+15551234567` into the person it
//! belongs to. An email matches case-insensitively; a phone number matches on its digits, or on its
//! last ten digits when exactly one name claims them.

use std::collections::{BTreeSet, HashMap};

use crate::splitters::is_py_space;

/// A national number without its country code, and the length below which a suffix stops being
/// specific to one number.
const NATIONAL_DIGITS: usize = 10;
const MIN_PHONE_DIGITS: usize = 7;

/// `handle_key`: an email lowercased, a phone number's digits, or `None`.
#[must_use]
pub fn handle_key(handle: &str) -> Option<String> {
    let handle = handle.trim_matches(is_py_space);
    if handle.is_empty() {
        return None;
    }
    if handle.contains('@') {
        return Some(handle.to_lowercase());
    }
    // Python's str.isdigit also takes other scripts' digits; a handle Messages stores is ASCII.
    let digits: String = handle.chars().filter(char::is_ascii_digit).collect();
    (digits.chars().count() >= MIN_PHONE_DIGITS).then_some(digits)
}

/// `ContactNames`: a handle-to-name lookup, with an optional fallback tier consulted only for
/// handles this one does not resolve.
#[derive(Clone, Debug, Default)]
pub struct ContactNames {
    exact: HashMap<String, String>,
    national: HashMap<String, BTreeSet<String>>,
    fallback: Option<Box<ContactNames>>,
}

impl ContactNames {
    /// Names from `(handle, name)` pairs; the first name given for a handle wins.
    pub fn new<'a>(entries: impl IntoIterator<Item = (&'a str, &'a str)>) -> Self {
        let mut names = Self::default();
        for (handle, name) in entries {
            names.add(handle, name);
        }
        names
    }

    /// `add`: records a name, its white space collapsed.
    pub fn add(&mut self, handle: &str, name: &str) {
        let name = name.split(is_py_space).filter(|word| !word.is_empty()).collect::<Vec<_>>().join(" ");
        let Some(key) = handle_key(handle) else { return };
        if name.is_empty() {
            return;
        }
        if !key.contains('@') && key.chars().count() >= NATIONAL_DIGITS {
            let national: String = key.chars().skip(key.chars().count() - NATIONAL_DIGITS).collect();
            self.national.entry(national).or_default().insert(name.clone());
        }
        self.exact.entry(key).or_insert(name);
    }

    /// `with_fallback`: these names, then `fallback` for the handles they do not resolve.
    #[must_use]
    pub fn with_fallback(mut self, fallback: ContactNames) -> Self {
        self.fallback = Some(Box::new(match self.fallback.take() {
            Some(existing) => existing.with_fallback(fallback),
            None => fallback,
        }));
        self
    }

    /// Whether any name is known (`__bool__`).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.exact.is_empty() && self.fallback.as_ref().is_none_or(|fallback| fallback.is_empty())
    }

    /// `name_for`: the name for `handle`, or `None` when no contact, or more than one, claims it.
    #[must_use]
    pub fn name_for(&self, handle: &str) -> Option<String> {
        self.own_name_for(handle).or_else(|| self.fallback.as_ref().and_then(|fallback| fallback.name_for(handle)))
    }

    fn own_name_for(&self, handle: &str) -> Option<String> {
        let key = handle_key(handle)?;
        if let Some(name) = self.exact.get(&key) {
            return Some(name.clone());
        }
        let length = key.chars().count();
        if key.contains('@') || length < NATIONAL_DIGITS {
            return None;
        }
        let national: String = key.chars().skip(length - NATIONAL_DIGITS).collect();
        let names = self.national.get(&national)?;
        if names.len() == 1 { names.iter().next().cloned() } else { None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_match_on_digits_or_one_national_suffix() {
        let names = ContactNames::new([("(555) 123-4567", "Ada  Lovelace"), ("ADA@Example.com", "Ada")]);
        assert_eq!(names.name_for("+15551234567").as_deref(), Some("Ada Lovelace"));
        assert_eq!(names.name_for("ada@example.COM").as_deref(), Some("Ada"));
        assert_eq!(names.name_for("12345"), None);
        let shared = ContactNames::new([("+1 555 123 4567", "A"), ("+44 555 123 4567", "B")]);
        assert_eq!(shared.name_for("5551234567"), None, "two names claim the suffix");
        let tiered = ContactNames::new([("a@x", "Mine")]).with_fallback(ContactNames::new([("b@x", "Shared")]));
        assert_eq!(tiered.name_for("b@x").as_deref(), Some("Shared"));
        assert!(!tiered.is_empty());
    }
}
