//! The part of Garage's configuration the worker reads (`embedding.*` in `garage.json`).

use std::path::PathBuf;

use serde_json::Value;

/// Where the model servers are, as `garage_rag.config.Settings` names them. The host fills it from
/// the configuration; [`Settings::default`] is Python's defaults.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    /// `embedding.ollama_host`.
    pub ollama_host: String,
    /// `embedding.lmstudio_host` (with `/v1`, which the client strips).
    pub lmstudio_host: String,
    /// `embedding.llama_host`, LlamaXPCService's API (loopback only).
    pub llama_host: String,
    /// LM Studio's bearer token, when the configuration names one
    /// (`GARAGE_LMSTUDIO_API_TOKEN` or `embedding.lmstudio_api_token_file`, read by the host).
    pub lmstudio_api_token: Option<String>,
    /// `embedding.batch_size`: chunks per embedding request.
    pub batch_size: usize,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            ollama_host: "http://localhost:11434".into(),
            lmstudio_host: "http://localhost:1234/v1".into(),
            llama_host: "http://127.0.0.1:8790".into(),
            lmstudio_api_token: None,
            batch_size: 64,
        }
    }
}

/// `embedding.*` keys [`Settings::from_service`] asks for, by their name in `garage.json`.
pub const SERVICE_KEYS: [&str; 5] = [
    "embedding.ollama_host",
    "embedding.lmstudio_host",
    "embedding.llama_host",
    "embedding.lmstudio_api_token_file",
    "embedding.batch_size",
];

impl Settings {
    /// The settings the backend runs with, read one key at a time through `get` (GarageService's
    /// `GetSetting`, which answers with the effective value as JSON), so the worker and the Python
    /// backend never disagree about where the model servers are. A key `get` cannot answer keeps
    /// its default. The LM Studio token is read as Python reads it: `GARAGE_LMSTUDIO_API_TOKEN`,
    /// else the file `embedding.lmstudio_api_token_file` names; one that cannot be read is left
    /// out, and LM Studio's refusal then says how to set it.
    pub fn from_service<E>(get: impl Fn(&str) -> Result<Value, E>) -> Self {
        let mut settings = Self::default();
        let text = |key: &str| match get(key) {
            Ok(Value::String(value)) if !value.trim().is_empty() => Some(value),
            _ => None,
        };
        if let Some(host) = text("embedding.ollama_host") {
            settings.ollama_host = host;
        }
        if let Some(host) = text("embedding.lmstudio_host") {
            settings.lmstudio_host = host;
        }
        if let Some(host) = text("embedding.llama_host") {
            settings.llama_host = host;
        }
        if let Ok(Value::Number(size)) = get("embedding.batch_size")
            && let Some(size) = size.as_u64().filter(|size| *size > 0)
        {
            settings.batch_size = usize::try_from(size).unwrap_or(settings.batch_size);
        }
        settings.lmstudio_api_token = match std::env::var("GARAGE_LMSTUDIO_API_TOKEN") {
            Ok(token) => Some(token.trim().to_string()).filter(|token| !token.is_empty()),
            Err(_) => text("embedding.lmstudio_api_token_file").and_then(|path| read_token(&path)),
        };
        settings
    }
}

/// The token in the file at `path` (`~` is the home folder), trimmed; `None` when it is unreadable
/// or empty.
fn read_token(path: &str) -> Option<String> {
    let path = match path.strip_prefix("~/") {
        Some(rest) => PathBuf::from(std::env::var_os("HOME")?).join(rest),
        None => PathBuf::from(path),
    };
    let token = std::fs::read_to_string(path).ok()?;
    Some(token.trim().to_string()).filter(|token| !token.is_empty())
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use serde_json::json;

    use super::*;

    fn from(values: &HashMap<&str, Value>) -> Settings {
        Settings::from_service(|key| values.get(key).cloned().ok_or(()))
    }

    #[test]
    fn the_service_values_replace_the_defaults() {
        let values = HashMap::from([
            ("embedding.ollama_host", json!("http://gpu-box:11434")),
            ("embedding.lmstudio_host", json!("http://127.0.0.1:1235/v1")),
            ("embedding.llama_host", json!("http://127.0.0.1:9000")),
            ("embedding.batch_size", json!(16)),
            ("embedding.lmstudio_api_token_file", Value::Null),
        ]);
        let settings = from(&values);
        assert_eq!(settings.ollama_host, "http://gpu-box:11434");
        assert_eq!(settings.lmstudio_host, "http://127.0.0.1:1235/v1");
        assert_eq!(settings.llama_host, "http://127.0.0.1:9000");
        assert_eq!(settings.batch_size, 16);
    }

    #[test]
    fn unanswered_or_odd_keys_keep_the_defaults() {
        let values = HashMap::from([("embedding.batch_size", json!(0)), ("embedding.ollama_host", json!(""))]);
        let settings = from(&values);
        assert_eq!(Settings { lmstudio_api_token: None, ..settings }, Settings::default());
    }

    #[test]
    fn the_token_file_is_read_and_trimmed() {
        let path = std::env::temp_dir().join(format!("garage-embed-token-{}", std::process::id()));
        std::fs::write(&path, "  sekrit\n").unwrap();
        assert_eq!(read_token(path.to_str().unwrap()).as_deref(), Some("sekrit"));
        std::fs::write(&path, "\n").unwrap();
        assert_eq!(read_token(path.to_str().unwrap()), None);
        std::fs::remove_file(&path).unwrap();
        assert_eq!(read_token(path.to_str().unwrap()), None);
    }
}
