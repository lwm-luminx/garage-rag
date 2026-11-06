//! MCP registrations and their tokens (`019_mcp_registrations.sql`, `docs/plans/access-hooks.md`,
//! "Registrations carry a token").
//!
//! A token proves which registration a caller holds, not which program is running: anything that
//! can read an assistant's config can present that assistant's token. It never makes a caller the
//! app, and it is never logged or stored, only its SHA-256 (taken by the server, `sha256()`).

use garage_access::Registration;

use crate::db::Client;
use crate::error::{Result, ServiceError};

/// What every token starts with, so one found in a file or a log is recognisable.
pub const TOKEN_PREFIX: &str = "gmr_";
/// The environment variable a stdio entry carries it in; `garage-mcp` reads it.
pub const TOKEN_ENV: &str = "GARAGE_MCP_TOKEN";

/// A new token: [`TOKEN_PREFIX`] and 32 random bytes, base64url without padding.
///
/// # Errors
///
/// The system's random source failed.
pub fn mint_token() -> Result<String> {
    Ok(format!("{TOKEN_PREFIX}{}", base64url(&random::<32>()?)))
}

/// A new registration id: 16 random bytes, base64url.
///
/// # Errors
///
/// The system's random source failed.
pub fn mint_id() -> Result<String> {
    Ok(base64url(&random::<16>()?))
}

fn random<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|e| ServiceError::failed(format!("the system's random source: {e}")))?;
    Ok(bytes)
}

fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for group in bytes.chunks(3) {
        let n = group.iter().enumerate().fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..=group.len() {
            out.push(char::from(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize]));
        }
    }
    out
}

/// One registration as `McpInstall` records it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewRegistration<'a> {
    pub token: &'a str,
    pub name: &'a str,
    pub client: &'a str,
    pub transport: &'a str,
    pub config_path: &'a str,
}

/// Records `registration`, or updates the row its token already has (a forced re-install keeps
/// the token, and so the id). The registration's id.
///
/// # Errors
///
/// The server.
pub async fn record(client: &Client, registration: &NewRegistration<'_>) -> Result<String> {
    let id = mint_id()?;
    let row = client
        .query_one(
            "INSERT INTO mcp_registrations (id, name, client, transport, config_path, token_sha256) \
             VALUES ($1, $2, $3, $4, $5, sha256(convert_to($6::text, 'UTF8'))) \
             ON CONFLICT (token_sha256) DO UPDATE SET name = EXCLUDED.name, client = EXCLUDED.client, \
                 transport = EXCLUDED.transport, config_path = EXCLUDED.config_path \
             RETURNING id",
            &[
                &id,
                &registration.name,
                &registration.client,
                &registration.transport,
                &registration.config_path,
                &registration.token,
            ],
        )
        .await?;
    Ok(row.get(0))
}

/// Deletes the registration `token` proves, so a copy of it stops working at once: its id, or
/// `None` when the token matched nothing.
///
/// # Errors
///
/// The server.
pub async fn remove(client: &Client, token: &str) -> Result<Option<String>> {
    let row = client
        .query_opt(
            "DELETE FROM mcp_registrations WHERE token_sha256 = sha256(convert_to($1::text, 'UTF8')) RETURNING id",
            &[&token],
        )
        .await?;
    Ok(row.map(|r| r.get(0)))
}

/// The registration `token` proves, stamping when it was last seen (at most once a minute, so a
/// busy assistant does not write on every read). `None` for an empty, unknown or revoked token.
///
/// # Errors
///
/// The server.
pub async fn resolve(client: &Client, token: &str) -> Result<Option<Registration>> {
    if token.is_empty() {
        return Ok(None);
    }
    let row = client
        .query_opt(
            "SELECT id, name, client, last_seen_at IS NULL OR last_seen_at < now() - interval '1 minute' \
             FROM mcp_registrations WHERE token_sha256 = sha256(convert_to($1::text, 'UTF8'))",
            &[&token],
        )
        .await?;
    let Some(row) = row else { return Ok(None) };
    let id: String = row.get(0);
    if row.get::<_, bool>(3) {
        client.execute("UPDATE mcp_registrations SET last_seen_at = now() WHERE id = $1", &[&id]).await?;
    }
    Ok(Some(Registration { id, name: row.get(1), client: row.get(2) }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64url_matches_the_rfc_vectors() {
        // RFC 4648 section 10, without padding, in the URL alphabet.
        for (input, expected) in [
            ("", ""),
            ("f", "Zg"),
            ("fo", "Zm8"),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg"),
            ("fooba", "Zm9vYmE"),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64url(input.as_bytes()), expected);
        }
        assert_eq!(base64url(&[0xfb, 0xff]), "-_8");
    }

    #[test]
    fn tokens_are_long_random_and_recognisable() {
        let (a, b) = (mint_token().unwrap(), mint_token().unwrap());
        assert!(a.starts_with(TOKEN_PREFIX));
        assert_eq!(a.len(), TOKEN_PREFIX.len() + 43);
        assert_ne!(a, b);
        assert_eq!(mint_id().unwrap().len(), 22);
    }
}
