//! The few SQLite calls the scanner makes, bound by hand to the system's libsqlite3 (macOS ships
//! it; Linux needs `libsqlite3-dev`), as `rust/garage-git` binds libgit2: no crate, so Bazel's
//! lockfile is untouched. Connections open as Python's `sqlite3.connect(uri, uri=True)` opens them.

use std::ffi::{CStr, CString, c_char, c_int};
use std::ptr;

#[repr(C)]
struct Sqlite3 {
    _private: [u8; 0],
}

#[repr(C)]
struct Statement {
    _private: [u8; 0],
}

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READWRITE: c_int = 0x0000_0002;
const SQLITE_OPEN_CREATE: c_int = 0x0000_0004;
const SQLITE_OPEN_URI: c_int = 0x0000_0040;

#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(filename: *const c_char, db: *mut *mut Sqlite3, flags: c_int, vfs: *const c_char) -> c_int;
    fn sqlite3_close(db: *mut Sqlite3) -> c_int;
    fn sqlite3_busy_timeout(db: *mut Sqlite3, ms: c_int) -> c_int;
    fn sqlite3_errmsg(db: *mut Sqlite3) -> *const c_char;
    fn sqlite3_prepare_v2(
        db: *mut Sqlite3,
        sql: *const c_char,
        bytes: c_int,
        statement: *mut *mut Statement,
        tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_step(statement: *mut Statement) -> c_int;
    fn sqlite3_finalize(statement: *mut Statement) -> c_int;
    fn sqlite3_column_count(statement: *mut Statement) -> c_int;
    fn sqlite3_column_text(statement: *mut Statement, column: c_int) -> *const u8;
    fn sqlite3_column_bytes(statement: *mut Statement, column: c_int) -> c_int;
    fn sqlite3_column_int64(statement: *mut Statement, column: c_int) -> i64;
    fn sqlite3_column_type(statement: *mut Statement, column: c_int) -> c_int;
}

const SQLITE_NULL: c_int = 5;

/// A value of a result column: text as UTF-8 (lossily, as Python's `str` would fail rather than
/// guess, which only a corrupt catalog could reach), integers as `i64`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cell {
    Null,
    Integer(i64),
    Text(String),
}

/// One open database. Closed on drop.
pub struct Connection {
    db: *mut Sqlite3,
}

/// A failure, with SQLite's message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl Connection {
    /// Opens `uri` as `sqlite3.connect(uri, uri=True, timeout=...)` does: read-write and create
    /// unless the URI's `mode` says otherwise, with a busy timeout.
    ///
    /// # Errors
    ///
    /// SQLite's reason the database could not be opened.
    pub fn open_uri(uri: &str, timeout_ms: i32) -> Result<Self, Error> {
        let uri = CString::new(uri).map_err(|_| Error("embedded null character".to_owned()))?;
        let mut db = ptr::null_mut();
        // SAFETY: `uri` is NUL-terminated and `db` receives the handle, which is closed on every path.
        let code = unsafe {
            sqlite3_open_v2(
                uri.as_ptr(),
                &raw mut db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
                ptr::null(),
            )
        };
        let connection = Self { db };
        if code != SQLITE_OK {
            return Err(connection.error());
        }
        // SAFETY: `db` is open.
        unsafe { sqlite3_busy_timeout(connection.db, timeout_ms) };
        Ok(connection)
    }

    fn error(&self) -> Error {
        if self.db.is_null() {
            return Error("out of memory".to_owned());
        }
        // SAFETY: `db` is a live handle; the message stays valid until the next call on it.
        let message = unsafe { CStr::from_ptr(sqlite3_errmsg(self.db)) };
        Error(message.to_string_lossy().into_owned())
    }

    /// Every row `sql` returns.
    ///
    /// # Errors
    ///
    /// SQLite's reason the statement failed.
    pub fn rows(&self, sql: &str) -> Result<Vec<Vec<Cell>>, Error> {
        let sql = CString::new(sql).map_err(|_| Error("embedded null character".to_owned()))?;
        let mut statement = ptr::null_mut();
        // SAFETY: `sql` is NUL-terminated; the statement is finalized below on every path.
        let code = unsafe { sqlite3_prepare_v2(self.db, sql.as_ptr(), -1, &raw mut statement, ptr::null_mut()) };
        if code != SQLITE_OK {
            return Err(self.error());
        }
        let statement = Finalize(statement);
        let mut rows = Vec::new();
        loop {
            // SAFETY: the statement is prepared.
            match unsafe { sqlite3_step(statement.0) } {
                SQLITE_ROW => rows.push(row(statement.0)),
                SQLITE_DONE => return Ok(rows),
                _ => return Err(self.error()),
            }
        }
    }
}

fn row(statement: *mut Statement) -> Vec<Cell> {
    // SAFETY: `statement` is on a row; column pointers stay valid until the next step.
    unsafe {
        (0..sqlite3_column_count(statement))
            .map(|column| match sqlite3_column_type(statement, column) {
                SQLITE_NULL => Cell::Null,
                1 => Cell::Integer(sqlite3_column_int64(statement, column)),
                _ => {
                    let text = sqlite3_column_text(statement, column);
                    let length = usize::try_from(sqlite3_column_bytes(statement, column)).unwrap_or(0);
                    if text.is_null() {
                        Cell::Null
                    } else {
                        Cell::Text(String::from_utf8_lossy(std::slice::from_raw_parts(text, length)).into_owned())
                    }
                }
            })
            .collect()
    }
}

struct Finalize(*mut Statement);

impl Drop for Finalize {
    fn drop(&mut self) {
        // SAFETY: the statement was prepared and is finalized once.
        unsafe { sqlite3_finalize(self.0) };
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // SAFETY: `db` is the handle `sqlite3_open_v2` gave (null is a no-op).
        unsafe { sqlite3_close(self.db) };
    }
}
