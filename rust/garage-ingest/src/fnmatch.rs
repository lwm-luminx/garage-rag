//! Python's `fnmatch.fnmatchcase` on POSIX: `*` matches any run of characters (`/` included), `?`
//! any one character, and `[...]` a set (`[!...]` its complement, `a-z` a range). The walker
//! lowercases both sides first, as `walker._matches_any` does.

/// Whether `name` matches the shell pattern `pattern`, case-sensitively.
pub fn fnmatch(name: &str, pattern: &str) -> bool {
    let name: Vec<char> = name.chars().collect();
    let pattern: Vec<char> = pattern.chars().collect();
    matches(&name, &pattern)
}

fn matches(name: &[char], pattern: &[char]) -> bool {
    // Iterative glob matching with one backtrack point per `*`, which is enough because a later
    // `*` subsumes every alternative an earlier one could take.
    let (mut n, mut p) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while n < name.len() {
        if p < pattern.len() {
            match pattern[p] {
                '*' => {
                    star = Some((p, n));
                    p += 1;
                    continue;
                }
                '?' => {
                    n += 1;
                    p += 1;
                    continue;
                }
                '[' => {
                    if let Some((matched, end)) = set(name[n], &pattern[p..]) {
                        if matched {
                            n += 1;
                            p += end;
                            continue;
                        }
                    } else if name[n] == '[' {
                        // An unterminated `[` is a literal, as in Python.
                        n += 1;
                        p += 1;
                        continue;
                    }
                }
                literal => {
                    if literal == name[n] {
                        n += 1;
                        p += 1;
                        continue;
                    }
                }
            }
        }
        match star {
            Some((star_p, star_n)) => {
                p = star_p + 1;
                n = star_n + 1;
                star = Some((star_p, star_n + 1));
            }
            None => return false,
        }
    }
    pattern[p..].iter().all(|&c| c == '*')
}

/// Matches `c` against the set at the start of `pattern` (which begins with `[`): whether it
/// matched, and the set's length in pattern characters. None when the set is unterminated.
fn set(c: char, pattern: &[char]) -> Option<(bool, usize)> {
    let mut i = 1;
    let negate = matches!(pattern.get(i), Some('!'));
    if negate {
        i += 1;
    }
    // A `]` right after the opening (or after `!`) is a member, not the end.
    let start = i;
    let mut found = false;
    while i < pattern.len() {
        let member = pattern[i];
        if member == ']' && i > start {
            return Some((found != negate, i + 1));
        }
        if pattern.get(i + 1) == Some(&'-') && pattern.get(i + 2).is_some_and(|&hi| hi != ']') {
            let high = pattern[i + 2];
            if member <= c && c <= high {
                found = true;
            }
            i += 3;
        } else {
            if member == c {
                found = true;
            }
            i += 1;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::fnmatch;

    #[test]
    fn stars_match_any_run_including_none() {
        assert!(fnmatch("sysdiagnose_2026", "sysdiagnose_*"));
        assert!(fnmatch("sysdiagnose_", "sysdiagnose_*"));
        assert!(fnmatch("a.hash.txt", "*.hash.txt"));
        assert!(fnmatch("x.sha256sum", "*.sha256*"));
        assert!(!fnmatch("hash.txt", "*.hash.txt"));
        assert!(fnmatch("a/b", "*"));
        assert!(fnmatch("spindump.txt", "spindump*.txt"));
        assert!(!fnmatch("spindump.txt.gz", "spindump*.txt"));
    }

    #[test]
    fn literals_question_marks_and_sets() {
        assert!(fnmatch("logs", "logs"));
        assert!(!fnmatch("logs2", "logs"));
        assert!(fnmatch("a1", "a?"));
        assert!(fnmatch("b", "[abc]"));
        assert!(!fnmatch("d", "[abc]"));
        assert!(fnmatch("d", "[!abc]"));
        assert!(fnmatch("m", "[a-z]"));
        assert!(fnmatch("]", "[]]"));
        assert!(fnmatch("[x", "[x"));
    }
}
