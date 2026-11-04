//! What the commands print: rich's markup (`[green]…[/green]`) rendered as colour on a terminal
//! and dropped elsewhere, its box tables, thousands separators, and the yes/no prompts.

use std::io::{IsTerminal, Write};
use std::sync::OnceLock;

/// Whether stdout is a terminal that gets colour (`NO_COLOR` turns it off, as rich honours it).
pub fn colour() -> bool {
    static COLOUR: OnceLock<bool> = OnceLock::new();
    *COLOUR.get_or_init(|| std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none())
}

/// Whether stdout is a terminal (`console.is_terminal`).
pub fn is_terminal() -> bool {
    std::io::stdout().is_terminal()
}

fn code(style: &str) -> Option<&'static str> {
    Some(match style {
        "red" => "31",
        "green" => "32",
        "yellow" => "33",
        "blue" => "34",
        "magenta" => "35",
        "cyan" => "36",
        "dim" => "2",
        "bold" => "1",
        _ => return None,
    })
}

/// `text` with its markup rendered (ANSI on a terminal, nothing elsewhere). A tag whose words are
/// not styles is left as it is, as rich leaves `[1]`.
pub fn render(text: &str) -> String {
    render_with(text, colour())
}

fn render_with(text: &str, colour: bool) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    let mut open = 0usize;
    while let Some(start) = rest.find('[') {
        let Some(end) = rest[start..].find(']') else { break };
        let tag = &rest[start + 1..start + end];
        let (closing, words) = match tag.strip_prefix('/') {
            Some(words) => (true, words),
            None => (false, tag),
        };
        let styles: Vec<&str> = words.split_whitespace().collect();
        let known =
            !styles.is_empty() && styles.iter().all(|style| code(style).is_some()) || (closing && words.is_empty());
        out.push_str(&rest[..start]);
        if known {
            if colour {
                if closing {
                    out.push_str("\x1b[0m");
                    open = open.saturating_sub(1);
                } else {
                    for style in styles {
                        out.push_str("\x1b[");
                        out.push_str(code(style).unwrap_or("0"));
                        out.push('m');
                    }
                    open += 1;
                }
            }
        } else {
            out.push_str(&rest[start..=start + end]);
        }
        rest = &rest[start + end + 1..];
    }
    out.push_str(rest);
    if colour && open > 0 {
        out.push_str("\x1b[0m");
    }
    out
}

/// Prints `text` with its markup rendered, and a newline.
pub fn print(text: &str) {
    println!("{}", render(text));
}

/// Prints `text` as it is, markup included (`typer.echo`, `markup=False`).
pub fn echo(text: &str) {
    println!("{text}");
}

/// Prints `text` to stderr, markup rendered.
pub fn eprint(text: &str) {
    eprintln!("{}", render_with(text, std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none()));
}

/// `12,345`.
pub fn commas(n: impl Into<i128>) -> String {
    let n: i128 = n.into();
    let digits = n.unsigned_abs().to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3 + 1);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

/// `$HOME` shortened to `~` at the front of a path, as the Python CLI shows locations.
pub fn tilde(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && path.starts_with(&home) => format!("~{}", &path[home.len()..]),
        _ => path.to_owned(),
    }
}

/// How a column lines up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Justify {
    Left,
    Right,
}

/// rich's default table: a heavy head, a title above, each cell's markup rendered.
pub struct Table {
    title: Option<String>,
    columns: Vec<(String, Justify)>,
    rows: Vec<Vec<String>>,
}

fn width(text: &str) -> usize {
    text.lines().map(|line| render_with(line, false).chars().count()).max().unwrap_or(0)
}

impl Table {
    pub fn new(title: Option<&str>) -> Self {
        Self { title: title.map(str::to_owned), columns: Vec::new(), rows: Vec::new() }
    }

    pub fn column(&mut self, name: &str, justify: Justify) -> &mut Self {
        self.columns.push((name.to_owned(), justify));
        self
    }

    pub fn columns(&mut self, names: &[&str]) -> &mut Self {
        for name in names {
            self.column(name, Justify::Left);
        }
        self
    }

    pub fn row<S: AsRef<str>>(&mut self, cells: &[S]) -> &mut Self {
        let mut row: Vec<String> = cells.iter().map(|cell| cell.as_ref().to_owned()).collect();
        row.resize(self.columns.len(), String::new());
        self.rows.push(row);
        self
    }

    /// The table, rendered.
    pub fn render(&self) -> String {
        let widths: Vec<usize> = self
            .columns
            .iter()
            .enumerate()
            .map(|(i, (name, _))| {
                self.rows.iter().map(|row| width(&row[i])).chain(std::iter::once(width(name))).max().unwrap_or(0)
            })
            .collect();
        let total: usize = widths.iter().map(|w| w + 2).sum::<usize>() + self.columns.len() + 1;
        let mut out = String::new();
        if let Some(title) = &self.title {
            let title_width = width(title);
            let pad = total.saturating_sub(title_width) / 2;
            out.push_str(&" ".repeat(pad));
            out.push_str(&render(title));
            out.push('\n');
        }
        let line = |left: &str, fill: &str, mid: &str, right: &str| -> String {
            let mut s = String::from(left);
            for (i, w) in widths.iter().enumerate() {
                if i > 0 {
                    s.push_str(mid);
                }
                s.push_str(&fill.repeat(w + 2));
            }
            s.push_str(right);
            s.push('\n');
            s
        };
        let cells = |row: &[String], bar: &str| -> String {
            let heights = row.iter().map(|cell| cell.lines().count().max(1)).max().unwrap_or(1);
            let mut s = String::new();
            for line_index in 0..heights {
                s.push_str(bar);
                for (i, cell) in row.iter().enumerate() {
                    let text = cell.lines().nth(line_index).unwrap_or("");
                    let plain = width(text);
                    let pad = widths[i].saturating_sub(plain);
                    s.push(' ');
                    match self.columns[i].1 {
                        Justify::Left => {
                            s.push_str(&render(text));
                            s.push_str(&" ".repeat(pad));
                        }
                        Justify::Right => {
                            s.push_str(&" ".repeat(pad));
                            s.push_str(&render(text));
                        }
                    }
                    s.push(' ');
                    s.push_str(bar);
                }
                s.push('\n');
            }
            s
        };
        out.push_str(&line("┏", "━", "┳", "┓"));
        let header: Vec<String> = self.columns.iter().map(|(name, _)| format!("[bold]{name}[/bold]")).collect();
        out.push_str(&cells(&header, "┃"));
        out.push_str(&line("┡", "━", "╇", "┩"));
        for row in &self.rows {
            out.push_str(&cells(row, "│"));
        }
        out.push_str(&line("└", "─", "┴", "┘"));
        out
    }

    pub fn print(&self) {
        print!("{}", self.render());
    }
}

/// `typer.confirm`: asks on stdout, reads one line; `None` when stdin is closed.
pub fn confirm(question: &str) -> bool {
    print!("{question} [y/N]: ");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line).is_err() {
        return false;
    }
    matches!(line.trim().to_ascii_lowercase().as_str(), "y" | "yes")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markup_is_rendered_or_dropped() {
        assert_eq!(render_with("[green]ok[/green] [1] x", false), "ok [1] x");
        assert_eq!(render_with("[bold cyan]1.[/bold cyan]", true), "\x1b[1m\x1b[36m1.\x1b[0m");
        assert_eq!(render_with("[red]open", true), "\x1b[31mopen\x1b[0m");
        assert_eq!(commas(1_234_567), "1,234,567");
        assert_eq!(commas(12), "12");
        assert_eq!(commas(-1000), "-1,000");
    }

    #[test]
    fn tables_line_up() {
        let mut table = Table::new(Some("corpus"));
        table.column("table", Justify::Left).column("rows", Justify::Right);
        table.row(&["documents", "1,200"]).row(&["chunks", "7"]);
        let text = table.render();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[1], "┏━━━━━━━━━━━┳━━━━━━━┓");
        assert_eq!(render_with(lines[2], false), "┃ table     ┃  rows ┃");
        assert_eq!(lines[4], "│ documents │ 1,200 │");
        assert_eq!(lines[5], "│ chunks    │     7 │");
    }
}
