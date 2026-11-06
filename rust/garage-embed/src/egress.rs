//! Where the worker may send content: `garage_rag.net.egress`'s destination rules.
//!
//! * Loopback is always approved; otherwise only the origins configured as
//!   `embedding.ollama_host` / `embedding.lmstudio_host` are.
//! * The app's own services (`llama_xpc`) are loopback only.
//! * Communications go only to loopback ([`allows_communications`]). The facade already leaves
//!   communication chunks out of an off-box model's batches; this is the second check.
//!
//! A host that carries a request ([`crate::Host::http`]) must send it to exactly the URL it was
//! given, with no proxy and no redirect, so the check here is the check of what is sent.

use std::fmt;
use std::net::IpAddr;

use crate::Settings;

/// A request the rules refuse. Nothing was sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EgressBlocked(pub String);

impl fmt::Display for EgressBlocked {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for EgressBlocked {}

/// `(scheme, host, port)` of a URL, as `egress._origin` reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Origin {
    pub scheme: String,
    pub host: String,
    pub port: u16,
}

/// The URL's scheme and authority's host and port, without parsing anything else. A bare
/// `host:port` counts as http.
fn split(url: &str) -> (String, &str) {
    let (scheme, rest) = match url.find("://") {
        Some(at) => (url[..at].to_ascii_lowercase(), &url[at + 3..]),
        None => ("http".to_string(), url),
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..end];
    // Any user information comes before the last '@'.
    let authority = authority.rfind('@').map_or(authority, |at| &authority[at + 1..]);
    (scheme, authority)
}

/// The authority's host (lowercase, without a trailing dot or IPv6 brackets) and its port text.
fn host_and_port(authority: &str) -> Option<(String, Option<&str>)> {
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let close = rest.find(']')?;
        let after = &rest[close + 1..];
        let port = match after.strip_prefix(':') {
            Some(port) => Some(port),
            None if after.is_empty() => None,
            None => return None,
        };
        (&rest[..close], port)
    } else {
        match authority.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        }
    };
    let host = host.to_ascii_lowercase();
    let host = host.trim_end_matches('.').to_string();
    Some((host, port.filter(|port| !port.is_empty())))
}

/// The URL's origin, or `None` when it has no host, a bad port or a scheme other than http(s).
pub fn origin(url: &str) -> Option<Origin> {
    let (scheme, authority) = split(url.trim());
    let (host, port) = host_and_port(authority)?;
    if host.is_empty() || (scheme != "http" && scheme != "https") {
        return None;
    }
    let port = match port {
        Some(port) => port.parse::<u16>().ok()?,
        None if scheme == "https" => 443,
        None => 80,
    };
    Some(Origin { scheme, host, port })
}

/// Whether the URL points at this machine: `localhost` or a literal loopback address. Any other
/// name is refused even if it resolves to loopback today, as `garage_rag.config.is_loopback_url`
/// does.
pub fn is_loopback_url(url: &str) -> bool {
    let (_, authority) = split(url.trim());
    let Some((host, _)) = host_and_port(authority) else {
        return false;
    };
    if host == "localhost" {
        return true;
    }
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(address)) => address.is_loopback(),
        Ok(IpAddr::V6(address)) => address.is_loopback() || address.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback()),
        Err(_) => false,
    }
}

/// Whether communication content may be sent to the URL: only when it is loopback.
pub fn allows_communications(url: &str) -> bool {
    is_loopback_url(url)
}

/// `Ok(())` when content for `purpose` may go to `url`, as `egress.check_destination`.
///
/// `loopback_only` is for the app's own services, which are never anywhere else.
///
/// # Errors
///
/// [`EgressBlocked`] naming the rule, when the destination is not approved.
pub fn check_destination(
    url: &str,
    purpose: &str,
    loopback_only: bool,
    settings: &Settings,
) -> Result<(), EgressBlocked> {
    if loopback_only {
        if is_loopback_url(url) {
            return Ok(());
        }
        return Err(EgressBlocked(format!("{purpose}: {url:?} must be a loopback URL (localhost, 127.0.0.1 or ::1)")));
    }
    if is_loopback_url(url) {
        return Ok(());
    }
    let approved = [&settings.ollama_host, &settings.lmstudio_host];
    if let Some(wanted) = origin(url)
        && approved.iter().any(|approved| origin(approved).as_ref() == Some(&wanted))
    {
        return Ok(());
    }
    Err(EgressBlocked(format!(
        "{purpose}: {url:?} is not an approved destination; content goes only to loopback or to the \
         model servers configured as embedding.ollama_host / embedding.lmstudio_host"
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn origin_of(url: &str) -> Option<(String, String, u16)> {
        origin(url).map(|o| (o.scheme, o.host, o.port))
    }

    #[test]
    fn reads_origins_as_python_does() {
        assert_eq!(origin_of("http://localhost:11434"), Some(("http".into(), "localhost".into(), 11434)));
        assert_eq!(
            origin_of("HTTPS://Models.Example.COM./v1"),
            Some(("https".into(), "models.example.com".into(), 443))
        );
        assert_eq!(origin_of("gpu.lan:1234"), Some(("http".into(), "gpu.lan".into(), 1234)));
        assert_eq!(origin_of("http://user:pw@[::1]:8790/x"), Some(("http".into(), "::1".into(), 8790)));
        assert_eq!(origin_of("ftp://example.com"), None);
        assert_eq!(origin_of("http://example.com:99999"), None);
        assert_eq!(origin_of("http://:80"), None);
    }

    #[test]
    fn loopback_is_an_address_or_localhost_never_a_name() {
        for url in ["http://localhost:1", "127.0.0.1:8790", "http://127.9.9.9", "http://[::1]:80", "http://LOCALHOST./"]
        {
            assert!(is_loopback_url(url), "{url}");
        }
        for url in ["http://127.example.com", "http://10.0.0.1", "http://[::2]", "http://example.com", ""] {
            assert!(!is_loopback_url(url), "{url}");
        }
    }

    #[test]
    fn approves_loopback_and_exactly_the_configured_origins() {
        let settings = Settings { ollama_host: "http://gpu.lan:11434".into(), ..Settings::default() };
        assert!(check_destination("http://gpu.lan:11434", "t", false, &settings).is_ok());
        assert!(check_destination("http://GPU.lan:11434/api/embed", "t", false, &settings).is_ok());
        assert!(check_destination("http://localhost:9", "t", false, &settings).is_ok());
        // Another port, scheme or host of the same machine name is another origin.
        assert!(check_destination("http://gpu.lan:11435", "t", false, &settings).is_err());
        assert!(check_destination("https://gpu.lan:11434", "t", false, &settings).is_err());
        assert!(check_destination("http://elsewhere.example.com", "t", false, &settings).is_err());
    }

    #[test]
    fn the_apps_own_services_are_loopback_only() {
        let settings = Settings { ollama_host: "http://gpu.lan:11434".into(), ..Settings::default() };
        assert!(check_destination("http://127.0.0.1:8790", "t", true, &settings).is_ok());
        let refused = check_destination("http://gpu.lan:11434", "t", true, &settings).unwrap_err();
        assert!(refused.0.contains("must be a loopback URL"), "{refused}");
    }

    #[test]
    fn communications_stay_on_this_machine() {
        assert!(allows_communications("http://localhost:11434"));
        assert!(!allows_communications("http://gpu.lan:11434"));
    }
}
