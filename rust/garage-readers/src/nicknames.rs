//! Names iMessage contacts shared with the owner ("Share Name and Photo"), from Messages'
//! `NickNameCache` (`extract/nicknames.py`).
//!
//! Messages keeps the names people chose to share in `NickNameCache/` beside `chat.db`: small SQLite
//! key-value stores (`kvtable`: `key` a handle, `value` an archived nickname). The layout is Apple's
//! private format, so this reader is tolerant: any table with a text key and a blob value, the value
//! decoded as a property list (keyed archive or plain), and the first and last name, or a display
//! name, from whatever dictionary holds them. A file, row or value it cannot read is skipped; it never
//! fails an ingest. Names for handles that are not a phone number or email address are ignored.

use std::io::Cursor;
use std::path::Path;

use garage_ingest::contact_names::handle_key;
use plist::Value;
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};

/// The folder beside `chat.db`.
pub const FOLDER: &str = "NickNameCache";

const FIRST: &[&str] = &["firstname", "first", "givenname"];
const LAST: &[&str] = &["lastname", "last", "familyname"];
const DISPLAY: &[&str] = &["displayname", "fullname", "name"];

/// `(handle, name)` pairs from `messages_dir/NickNameCache`, empty when there is none. Accepted names
/// come before pending ones (a store whose name says `pending`), so a handle's accepted name wins.
pub fn shared_names(messages_dir: &Path) -> Vec<(String, String)> {
    let folder = messages_dir.join(FOLDER);
    let Ok(entries) = std::fs::read_dir(&folder) else { return Vec::new() };
    let mut files: Vec<_> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .filter(|path| {
            path.extension().is_some_and(|extension| {
                let extension = extension.to_string_lossy().to_lowercase();
                extension == "db" || extension == "sqlite"
            })
        })
        .collect();
    files.sort();
    // A stable sort: accepted stores first, each group in name order.
    files.sort_by_key(|path| {
        path.file_name().is_some_and(|name| name.to_string_lossy().to_lowercase().contains("pending"))
    });
    files.iter().flat_map(|path| read_file(path)).collect()
}

fn connect(path: &Path) -> Option<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI;
    let uri = format!("file:{}", path.canonicalize().ok()?.display());
    let readable =
        |connection: &Connection| connection.query_row("SELECT 1 FROM sqlite_master LIMIT 1", [], |_| Ok(())).is_ok();
    if let Ok(connection) = Connection::open_with_flags(format!("{uri}?mode=ro"), flags)
        && readable(&connection)
    {
        return Some(connection);
    }
    // A store Messages holds open (WAL) may only open immutable.
    Connection::open_with_flags(format!("{uri}?immutable=1"), flags).ok()
}

/// The key and value columns of `table`: `key` and `value` when it has them, else its first text and
/// first blob columns.
fn key_value_columns(connection: &Connection, table: &str) -> Option<(String, String)> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info(\"{}\")", table.replace('"', "\"\""))).ok()?;
    let columns: Vec<(String, String)> = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(1)?, row.get::<_, Option<String>>(2)?.unwrap_or_default().to_uppercase()))
        })
        .ok()?
        .filter_map(Result::ok)
        .collect();
    let named =
        |wanted: &str| columns.iter().find(|(name, _)| name.to_lowercase() == wanted).map(|(name, _)| name.clone());
    if let (Some(key), Some(value)) = (named("key"), named("value")) {
        return Some((key, value));
    }
    let text = columns.iter().find(|(_, kind)| kind.contains("TEXT")).map(|(name, _)| name.clone())?;
    let blob = columns.iter().find(|(_, kind)| kind.contains("BLOB")).map(|(name, _)| name.clone())?;
    Some((text, blob))
}

fn read_file(path: &Path) -> Vec<(String, String)> {
    let Some(connection) = connect(path) else { return Vec::new() };
    let Ok(mut statement) = connection.prepare("SELECT name FROM sqlite_master WHERE type = 'table'") else {
        return Vec::new();
    };
    let tables: Vec<String> = match statement.query_map([], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows.filter_map(Result::ok).collect(),
        Err(_) => return Vec::new(),
    };
    let mut pairs = Vec::new();
    for table in tables {
        let Some((key, value)) = key_value_columns(&connection, &table) else { continue };
        let quote = |name: &str| format!("\"{}\"", name.replace('"', "\"\""));
        let sql = format!("SELECT {}, {} FROM {}", quote(&key), quote(&value), quote(&table));
        let Ok(mut statement) = connection.prepare(&sql) else { continue };
        let Ok(mut rows) = statement.query([]) else { continue };
        while let Ok(Some(row)) = rows.next() {
            let Ok(ValueRef::Text(handle)) = row.get_ref(0) else { continue };
            let handle = String::from_utf8_lossy(handle).into_owned();
            if handle_key(&handle).is_none() {
                continue;
            }
            let Ok(ValueRef::Blob(blob)) = row.get_ref(1) else { continue };
            if let Some(name) = decode(blob) {
                pairs.push((handle, name));
            }
        }
    }
    pairs
}

fn decode(blob: &[u8]) -> Option<String> {
    if blob.is_empty() {
        return None;
    }
    let value = Value::from_reader(Cursor::new(blob)).ok()?;
    name_in(&unarchive(value), 0)
}

/// A keyed archive's root object with its references resolved; anything else as it is.
fn unarchive(value: Value) -> Value {
    let Value::Dictionary(archive) = &value else { return value };
    let (Some(Value::Array(objects)), Some(top)) = (archive.get("$objects"), archive.get("$top")) else {
        return value;
    };
    let root = match top {
        Value::Dictionary(top) => top.get("root").or_else(|| top.values().next()),
        _ => None,
    };
    root.map_or(Value::String(String::new()), |root| resolve(root, objects, 0))
}

fn resolve(item: &Value, objects: &[Value], depth: usize) -> Value {
    if depth > 32 {
        return Value::String(String::new());
    }
    match item {
        Value::Uid(uid) => usize::try_from(uid.get())
            .ok()
            .and_then(|index| objects.get(index))
            .map_or(Value::String(String::new()), |object| resolve(object, objects, depth + 1)),
        Value::Dictionary(dictionary) => {
            if let (Some(Value::Array(keys)), Some(Value::Array(values))) =
                (dictionary.get("NS.keys"), dictionary.get("NS.objects"))
            {
                let mut resolved = plist::Dictionary::new();
                for (key, value) in keys.iter().zip(values) {
                    if let Value::String(key) = resolve(key, objects, depth + 1) {
                        resolved.insert(key, resolve(value, objects, depth + 1));
                    }
                }
                return Value::Dictionary(resolved);
            }
            let mut resolved = plist::Dictionary::new();
            for (key, value) in dictionary {
                if key != "$class" {
                    resolved.insert(key.clone(), resolve(value, objects, depth + 1));
                }
            }
            Value::Dictionary(resolved)
        }
        Value::Array(values) => Value::Array(values.iter().map(|value| resolve(value, objects, depth + 1)).collect()),
        Value::String(text) if text == "$null" => Value::String(String::new()),
        other => other.clone(),
    }
}

/// The name held by the first dictionary (depth first) that has name parts.
fn name_in(value: &Value, depth: usize) -> Option<String> {
    if depth > 8 {
        return None;
    }
    let children: Vec<&Value> = match value {
        Value::Dictionary(dictionary) => {
            let field = |keys: &[&str]| {
                keys.iter().find_map(|wanted| {
                    dictionary.iter().find_map(|(key, value)| match value {
                        Value::String(text) if key.to_lowercase() == *wanted && !text.trim().is_empty() => {
                            Some(text.trim().to_owned())
                        }
                        _ => None,
                    })
                })
            };
            let parts: Vec<String> = [field(FIRST), field(LAST)].into_iter().flatten().collect();
            if !parts.is_empty() {
                return Some(parts.join(" "));
            }
            if let Some(display) = field(DISPLAY) {
                return Some(display);
            }
            dictionary.values().collect()
        }
        Value::Array(values) => values.iter().collect(),
        _ => return None,
    };
    children.into_iter().find_map(|child| name_in(child, depth + 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn archive(first: &str, last: &str) -> Vec<u8> {
        // NSKeyedArchiver's shape: $top.root -> a dictionary whose NS.keys/NS.objects point into $objects.
        let mut top = plist::Dictionary::new();
        top.insert("root".into(), Value::Uid(plist::Uid::new(1)));
        let mut root = plist::Dictionary::new();
        root.insert(
            "NS.keys".into(),
            Value::Array(vec![Value::Uid(plist::Uid::new(2)), Value::Uid(plist::Uid::new(3))]),
        );
        root.insert(
            "NS.objects".into(),
            Value::Array(vec![Value::Uid(plist::Uid::new(4)), Value::Uid(plist::Uid::new(5))]),
        );
        root.insert("$class".into(), Value::Uid(plist::Uid::new(6)));
        let objects = vec![
            Value::String("$null".into()),
            Value::Dictionary(root),
            Value::String("firstName".into()),
            Value::String("lastName".into()),
            Value::String(first.into()),
            Value::String(last.into()),
            Value::Dictionary(plist::Dictionary::new()),
        ];
        let mut archive = plist::Dictionary::new();
        archive.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
        archive.insert("$top".into(), Value::Dictionary(top));
        archive.insert("$objects".into(), Value::Array(objects));
        let mut bytes = Vec::new();
        Value::Dictionary(archive).to_writer_binary(&mut bytes).unwrap();
        bytes
    }

    fn store(path: &Path, rows: &[(&str, Vec<u8>)]) {
        let connection = Connection::open(path).unwrap();
        connection.execute("CREATE TABLE kvtable (key TEXT, value BLOB)", []).unwrap();
        for (key, value) in rows {
            connection.execute("INSERT INTO kvtable VALUES (?1, ?2)", rusqlite::params![key, value]).unwrap();
        }
    }

    #[test]
    fn reads_accepted_names_before_pending_ones() {
        let directory = std::env::temp_dir().join(format!("garage-nicknames-{}", std::process::id()));
        let folder = directory.join(FOLDER);
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&folder).unwrap();
        store(&folder.join("pendingNicknameKVStore.db"), &[("+15551234567", archive("Pending", "Name"))]);
        store(
            &folder.join("nicknameRecordsStore.db"),
            &[
                ("+15551234567", archive("Ada", "Lovelace")),
                ("ada@example.com", archive("", "Byron")),
                ("not a handle", archive("Nobody", "")),
                ("+15550000000", b"not a plist".to_vec()),
            ],
        );
        let names = shared_names(&directory);
        assert_eq!(
            names,
            vec![
                ("+15551234567".to_owned(), "Ada Lovelace".to_owned()),
                ("ada@example.com".to_owned(), "Byron".to_owned()),
                ("+15551234567".to_owned(), "Pending Name".to_owned()),
            ]
        );
        std::fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn no_folder_is_no_names() {
        assert!(shared_names(Path::new("/nonexistent/garage")).is_empty());
    }

    #[test]
    fn a_plain_dictionary_with_a_display_name() {
        let mut dictionary = plist::Dictionary::new();
        dictionary.insert("displayName".into(), Value::String(" Grace ".into()));
        let mut bytes = Vec::new();
        Value::Dictionary(dictionary).to_writer_xml(&mut bytes).unwrap();
        assert_eq!(decode(&bytes), Some("Grace".to_owned()));
    }
}
