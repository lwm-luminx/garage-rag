//! The command line, read as Typer read it: `--name value`, `--name=value`, `-n value`, repeated
//! options collected, `--` ending the options. Each command names the options it takes; an
//! unknown one is an error with Typer's wording, and exit code 2.

use std::collections::BTreeMap;

/// One option a command takes.
#[derive(Clone, Copy, Debug)]
pub struct Opt {
    /// The long name, without the dashes.
    pub long: &'static str,
    /// The one-letter short name, when there is one.
    pub short: Option<char>,
    /// Whether a value follows (`--limit 5`), or the option is a switch (`--force`).
    pub value: bool,
}

impl Opt {
    pub const fn flag(long: &'static str) -> Self {
        Self { long, short: None, value: false }
    }

    pub const fn short_flag(long: &'static str, short: char) -> Self {
        Self { long, short: Some(short), value: false }
    }

    pub const fn value(long: &'static str) -> Self {
        Self { long, short: None, value: true }
    }

    pub const fn short_value(long: &'static str, short: char) -> Self {
        Self { long, short: Some(short), value: true }
    }
}

/// A command's arguments once read.
#[derive(Clone, Debug, Default)]
pub struct Parsed {
    /// The positional arguments, in order.
    pub positional: Vec<String>,
    /// Each option's values (a switch records an empty string per occurrence).
    options: BTreeMap<&'static str, Vec<String>>,
}

impl Parsed {
    /// Whether `long` was given at all.
    pub fn has(&self, long: &str) -> bool {
        self.options.contains_key(long)
    }

    /// The last value of `long`, when given.
    pub fn get(&self, long: &str) -> Option<&str> {
        self.options.get(long).and_then(|values| values.last()).map(String::as_str)
    }

    /// Every value of `long`, for a repeatable option.
    pub fn all(&self, long: &str) -> Vec<String> {
        self.options.get(long).cloned().unwrap_or_default()
    }

    /// `--long` as a whole number.
    ///
    /// # Errors
    ///
    /// Typer's "Invalid value" message.
    pub fn int<T: std::str::FromStr>(&self, long: &str) -> Result<Option<T>, String> {
        match self.get(long) {
            None => Ok(None),
            Some(text) => text
                .parse()
                .map(Some)
                .map_err(|_| format!("Invalid value for '--{long}': '{text}' is not a valid integer.")),
        }
    }

    /// `--long` as a number with a fraction.
    ///
    /// # Errors
    ///
    /// Typer's "Invalid value" message.
    pub fn float(&self, long: &str) -> Result<Option<f64>, String> {
        match self.get(long) {
            None => Ok(None),
            Some(text) => text
                .parse()
                .map(Some)
                .map_err(|_| format!("Invalid value for '--{long}': '{text}' is not a valid float.")),
        }
    }

    /// The positional argument at `index`, or Typer's "Missing argument".
    ///
    /// # Errors
    ///
    /// When there is none.
    pub fn arg(&self, index: usize, name: &str) -> Result<&str, String> {
        self.positional.get(index).map(String::as_str).ok_or_else(|| format!("Missing argument '{name}'."))
    }
}

/// Reads `args` against `opts`.
///
/// # Errors
///
/// An unknown option, a value-less option at the end, or a switch given a value.
pub fn parse(args: &[String], opts: &[Opt]) -> Result<Parsed, String> {
    let mut parsed = Parsed::default();
    let mut rest = args.iter();
    let mut only_positional = false;
    while let Some(arg) = rest.next() {
        if only_positional || arg == "-" || !arg.starts_with('-') {
            parsed.positional.push(arg.clone());
            continue;
        }
        if arg == "--" {
            only_positional = true;
            continue;
        }
        let (name, inline) = match arg.strip_prefix("--") {
            Some(long) => match long.split_once('=') {
                Some((name, value)) => (find(opts, |o| o.long == name, arg)?, Some(value.to_owned())),
                None => (find(opts, |o| o.long == long, arg)?, None),
            },
            None => {
                let mut chars = arg[1..].chars();
                let letter = chars.next().ok_or_else(|| format!("No such option: {arg}"))?;
                let opt = find(opts, |o| o.short == Some(letter), arg)?;
                let trailing: String = chars.collect();
                (opt, (!trailing.is_empty()).then_some(trailing))
            }
        };
        let value = if name.value {
            match inline {
                Some(value) => value,
                None => {
                    rest.next().cloned().ok_or_else(|| format!("Option '--{}' requires an argument.", name.long))?
                }
            }
        } else {
            if inline.is_some() {
                return Err(format!("Option '--{}' does not take a value.", name.long));
            }
            String::new()
        };
        parsed.options.entry(name.long).or_default().push(value);
    }
    Ok(parsed)
}

fn find(opts: &[Opt], matches: impl Fn(&Opt) -> bool, arg: &str) -> Result<Opt, String> {
    opts.iter().copied().find(matches).ok_or_else(|| format!("No such option: {arg}"))
}

/// `true`/`false` as Typer's boolean options read them (`--apply/--dry-run` pairs are two switches).
pub fn parse_bool(text: &str) -> Option<bool> {
    match text.trim().to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" | "t" | "y" => Some(true),
        "false" | "no" | "off" | "0" | "f" | "n" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|&a| a.to_owned()).collect()
    }

    #[test]
    fn options_are_read_in_every_spelling() {
        let opts = [Opt::short_value("limit", 'n'), Opt::flag("full"), Opt::short_value("source", 's')];
        let parsed =
            parse(&strings(&["query", "--limit=3", "-s", "a", "--source", "b", "--full", "-n5"]), &opts).unwrap();
        assert_eq!(parsed.positional, vec!["query"]);
        assert_eq!(parsed.get("limit"), Some("5"));
        assert_eq!(parsed.all("source"), vec!["a", "b"]);
        assert!(parsed.has("full"));
        assert_eq!(parsed.int::<i64>("limit").unwrap(), Some(5));
        assert_eq!(parse(&strings(&["--nope"]), &opts).unwrap_err(), "No such option: --nope");
        assert_eq!(parse(&strings(&["--limit"]), &opts).unwrap_err(), "Option '--limit' requires an argument.");
        assert_eq!(parse(&strings(&["--", "--limit"]), &opts).unwrap().positional, vec!["--limit"]);
        assert_eq!(parse(&strings(&["--full=1"]), &opts).unwrap_err(), "Option '--full' does not take a value.");
    }
}
