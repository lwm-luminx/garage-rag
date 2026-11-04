//! The database: the URL as the app and `garage.json` write it, a pool of connections, and the
//! few value conversions the SQL needs (vectors as text, timestamps as Python wrote them).

use std::fmt::Write as _;
use std::str::FromStr;
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use tokio_postgres::NoTls;

use crate::error::{Result, ServiceError};

/// One connection from the pool.
pub type Client = deadpool_postgres::Object;

/// A parsed database URL: `postgresql[+driver]://user:password@host:port/dbname?host=...&port=...`
/// (`sqlalchemy.engine.make_url`, then libpq's reading of the query).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DatabaseUrl {
    pub user: Option<String>,
    pub password: Option<String>,
    /// Hosts, in order: the authority's, then every `host=` of the query. A path is a socket folder.
    pub hosts: Vec<String>,
    pub port: Option<u16>,
    pub dbname: Option<String>,
}

fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(byte as char);
        } else {
            let _ = std::fmt::Write::write_fmt(&mut out, format_args!("%{byte:02X}"));
        }
    }
    out
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(value) = u8::from_str_radix(&text[i + 1..i + 3], 16)
        {
            out.push(value);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl DatabaseUrl {
    /// Parses `url`. The driver suffix (`+psycopg`) is dropped, as `to_psycopg_conninfo` did.
    ///
    /// # Errors
    ///
    /// [`ServiceError::InvalidArgument`] when the URL is not a `postgresql://` URL.
    pub fn parse(url: &str) -> Result<Self> {
        let (scheme, rest) = url
            .split_once("://")
            .ok_or_else(|| ServiceError::invalid(format!("not a database URL: {}", redact_url(url))))?;
        let base = scheme.split('+').next().unwrap_or_default();
        if base != "postgresql" && base != "postgres" {
            return Err(ServiceError::invalid(format!("database URL must be postgresql://, not {base}://")));
        }
        let (rest, query) = rest.split_once('?').map_or((rest, ""), |(r, q)| (r, q));
        let (authority, path) = rest.split_once('/').map_or((rest, ""), |(a, p)| (a, p));
        let mut parsed = Self::default();
        let (userinfo, hostport) = authority.rsplit_once('@').map_or(("", authority), |(u, h)| (u, h));
        if !userinfo.is_empty() {
            let (user, password) = userinfo.split_once(':').map_or((userinfo, None), |(u, p)| (u, Some(p)));
            parsed.user = Some(percent_decode(user));
            parsed.password = password.map(percent_decode);
        }
        if !hostport.is_empty() {
            let (host, port) = if let Some(end) = hostport.strip_prefix('[').and_then(|h| h.split_once(']')) {
                (end.0.to_owned(), end.1.strip_prefix(':'))
            } else if let Some((h, p)) = hostport.rsplit_once(':') {
                (h.to_owned(), Some(p))
            } else {
                (hostport.to_owned(), None)
            };
            if !host.is_empty() {
                parsed.hosts.push(percent_decode(&host));
            }
            if let Some(port) = port.filter(|p| !p.is_empty()) {
                parsed.port = Some(port.parse().map_err(|_| ServiceError::invalid(format!("bad port {port:?}")))?);
            }
        }
        if !path.is_empty() {
            parsed.dbname = Some(percent_decode(path));
        }
        for pair in query.split('&').filter(|p| !p.is_empty()) {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            // SQLAlchemy renders a space as `+`; libpq reads `+` literally, and the app's socket
            // folder (`Group Containers/...`) has one, so both spellings mean a space here.
            let value = percent_decode(&value.replace('+', " "));
            match key {
                "host" => parsed.hosts.push(value),
                "port" => {
                    parsed.port =
                        Some(value.parse().map_err(|_| ServiceError::invalid(format!("bad port {value:?}")))?);
                }
                "dbname" => parsed.dbname = Some(value),
                "user" => parsed.user = Some(value),
                "password" => parsed.password = Some(value),
                _ => {}
            }
        }
        Ok(parsed)
    }

    /// The tokio-postgres configuration: libpq's defaults where the URL says nothing (the login
    /// user, a database named after it, the usual socket folders then loopback, port 5432).
    pub fn to_config(&self) -> tokio_postgres::Config {
        let mut config = tokio_postgres::Config::new();
        let user = self.user.clone().or_else(|| std::env::var("USER").ok()).unwrap_or_else(|| "postgres".into());
        config.user(&user);
        if let Some(password) = &self.password {
            config.password(password);
        }
        config.dbname(self.dbname.as_deref().unwrap_or(&user));
        if self.hosts.is_empty() {
            for host in ["/var/run/postgresql", "/tmp", "localhost"] {
                config.host(host);
            }
        } else {
            for host in &self.hosts {
                config.host(host);
            }
        }
        config.port(self.port.unwrap_or(5432));
        config.connect_timeout(Duration::from_secs(10));
        config.application_name("garage-service");
        config
    }

    /// The same URL for another database on the server (`url.set(database=...)`).
    #[must_use]
    pub fn with_database(&self, dbname: &str) -> Self {
        Self { dbname: Some(dbname.to_owned()), ..self.clone() }
    }

    /// The URL again, every host in the query so a socket folder survives
    /// (`render_as_string(hide_password=False)`).
    pub fn to_url(&self) -> String {
        let mut url = String::from("postgresql://");
        if let Some(user) = &self.user {
            url.push_str(&percent_encode(user));
            if let Some(password) = &self.password {
                url.push(':');
                url.push_str(&percent_encode(password));
            }
            url.push('@');
        }
        url.push('/');
        if let Some(dbname) = &self.dbname {
            url.push_str(&percent_encode(dbname));
        }
        let mut query: Vec<String> = self.hosts.iter().map(|h| format!("host={}", percent_encode(h))).collect();
        if let Some(port) = self.port {
            query.push(format!("port={port}"));
        }
        if !query.is_empty() {
            url.push('?');
            url.push_str(&query.join("&"));
        }
        url
    }
}

/// `url` with its password hidden, for logs (`migrate.redact_url`).
pub fn redact_url(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else { return "<database url>".into() };
    let Some((userinfo, tail)) = rest.split_once('@') else { return url.to_owned() };
    match userinfo.split_once(':') {
        Some((user, _)) => format!("{scheme}://{user}:***@{tail}"),
        None => url.to_owned(),
    }
}

/// A pool of connections to the database `url` names.
///
/// # Errors
///
/// A URL that does not parse. Connecting happens on first use.
pub fn pool_for(url: &str) -> Result<Pool> {
    let config = DatabaseUrl::parse(url)?.to_config();
    let manager = Manager::from_config(config, NoTls, ManagerConfig { recycling_method: RecyclingMethod::Fast });
    Pool::builder(manager).max_size(8).build().map_err(|e| ServiceError::failed(format!("database pool: {e}")))
}

/// `[1,2,3]`: a vector as pgvector reads it from text (`CAST($1 AS vector)`).
pub fn vector_text(values: &[f32]) -> String {
    let mut out = String::with_capacity(values.len() * 8 + 2);
    out.push('[');
    for (i, value) in values.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let _ = write!(out, "{value}");
    }
    out.push(']');
    out
}

/// A vector as pgvector prints it (`embedding::text`).
pub fn parse_vector(text: &str) -> Vec<f32> {
    text.trim().trim_start_matches('[').trim_end_matches(']').split(',').filter_map(|v| v.trim().parse().ok()).collect()
}

/// A timestamp as Python's `datetime.isoformat()` wrote it, in UTC: microseconds only when they
/// are not zero, and `+00:00`.
pub fn isoformat(at: DateTime<Utc>) -> String {
    let format = if at.timestamp_subsec_micros() == 0 { SecondsFormat::Secs } else { SecondsFormat::Micros };
    at.to_rfc3339_opts(format, false)
}

/// `at` as `isoformat`, or empty for none.
pub fn isoformat_opt(at: Option<DateTime<Utc>>) -> String {
    at.map(isoformat).unwrap_or_default()
}

/// A hex digest as the bytes the `bytea` columns hold; empty for an empty or malformed string.
pub fn hex_bytes(hex: &str) -> Vec<u8> {
    if !hex.len().is_multiple_of(2) {
        return Vec::new();
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16))
        .collect::<std::result::Result<_, _>>()
        .unwrap_or_default()
}

/// Bytes as the lowercase hex Python's `bytes.hex()` gives.
pub fn hex_string(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// A table name the registry shaped, so it can be interpolated into SQL (`assert_safe_table`).
///
/// # Errors
///
/// [`ServiceError::InvalidArgument`] for any other name.
pub fn assert_safe_table(name: &str) -> Result<&str> {
    let safe = name.strip_prefix("emb_").is_some_and(|rest| {
        !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    });
    if safe { Ok(name) } else { Err(ServiceError::invalid(format!("unsafe embedding table name: {name:?}"))) }
}

impl FromStr for DatabaseUrl {
    type Err = ServiceError;

    fn from_str(url: &str) -> Result<Self> {
        Self::parse(url)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_apps_socket_url_parses() {
        let url = DatabaseUrl::parse(
            "postgresql+psycopg://garage:s%3Acret@/garage-rag?host=/Users/me/Library/Group+Containers/x/s&port=14824",
        )
        .unwrap();
        assert_eq!(url.user.as_deref(), Some("garage"));
        assert_eq!(url.password.as_deref(), Some("s:cret"));
        assert_eq!(url.hosts, vec!["/Users/me/Library/Group Containers/x/s".to_owned()]);
        assert_eq!(url.port, Some(14824));
        assert_eq!(url.dbname.as_deref(), Some("garage-rag"));
        let again = url.with_database("garage_test_1").to_url();
        assert_eq!(
            again,
            "postgresql://garage:s%3Acret@/garage_test_1?host=%2FUsers%2Fme%2FLibrary%2FGroup%20Containers%2Fx%2Fs&port=14824"
        );
        assert_eq!(DatabaseUrl::parse(&again).unwrap(), url.with_database("garage_test_1"));
    }

    #[test]
    fn a_loopback_url_and_the_default_parse() {
        let url = DatabaseUrl::parse("postgresql://garage_dev:garage_dev@localhost:5432/postgres").unwrap();
        assert_eq!((url.hosts.as_slice(), url.port), (["localhost".to_owned()].as_slice(), Some(5432)));
        let bare = DatabaseUrl::parse("postgresql+psycopg:///rag").unwrap();
        assert_eq!((bare.hosts.len(), bare.dbname.as_deref()), (0, Some("rag")));
        assert!(DatabaseUrl::parse("mysql://x").is_err());
        assert_eq!(bare.with_database("other").dbname.as_deref(), Some("other"));
    }

    #[test]
    fn urls_are_redacted_for_logs() {
        assert_eq!(redact_url("postgresql://u:pw@h/db"), "postgresql://u:***@h/db");
        assert_eq!(redact_url("postgresql:///db"), "postgresql:///db");
    }

    #[test]
    fn vectors_hex_and_times_round_trip() {
        assert_eq!(vector_text(&[1.0, -0.5]), "[1,-0.5]");
        assert_eq!(parse_vector("[1,-0.5]"), vec![1.0, -0.5]);
        assert_eq!(hex_string(&hex_bytes("ab".repeat(32).as_str())), "ab".repeat(32));
        assert_eq!(hex_bytes("abc"), Vec::<u8>::new());
        let at = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        assert_eq!(isoformat(at), "2023-11-14T22:13:20+00:00");
        let at = DateTime::from_timestamp(1_700_000_000, 26_490_000).unwrap();
        assert_eq!(isoformat(at), "2023-11-14T22:13:20.026490+00:00");
        assert!(assert_safe_table("emb_bge_m3").is_ok());
        assert!(assert_safe_table("emb_bge; drop").is_err());
    }
}
