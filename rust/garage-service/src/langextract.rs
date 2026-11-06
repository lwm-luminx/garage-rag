//! The LangExtract adapter behind `EnrichFacts` (`enrich/facts.py`'s `extract_facts`,
//! `enrich/local_provider.py`'s `LocalLanguageModel`): the [`FactExtractor`] the service runs with.
//!
//! LangExtract's prompting, parsing and grounding are the `langextract-rs` crate's, which makes no
//! request and opens no file of its own: the model it is given is its only way out. That model is
//! always Garage's own chat client ([`ChatModel`]) on the local server `facts.provider` names, so
//! every prompt goes through the process's [`Host`] (`Host::http`; `llama_xpc` over NSXPC in the
//! app) and only after the egress rules approved it: the document's class through
//! `check_destination` first ([`FactModel::check_egress`], so a communication never reaches a host
//! that is not loopback), then the chat client's own destination check. Upstream LangExtract's
//! routing of model ids to Gemini or OpenAI is not in the crate, and a cloud model id is refused
//! before anything is sent.
//!
//! The request knobs are the ones Python's `facts_language_model` chose per server: Ollama gets
//! temperature 0.1 and JSON mode (a GPT-OSS model a JSON-only system prompt instead, since its
//! response format conflicts with JSON mode); LlamaXPCService and LM Studio (which refuses
//! `json_object`) get the prompt alone.

use std::sync::Arc;

use ::langextract::{ExampleData, ExtractConfig, Extraction};
use garage_embed::{Host, Settings};
use garage_mcp::chat::{ChatModel, ChatSettings};
use serde_json::{Value, json};

use crate::enrich::{Extracted, FactExtractor, FactModel, refuse_cloud_model_id};
use crate::prompts::EffectivePrompt;

/// What LangExtract's own Ollama provider sent, kept when Ollama moved onto `/v1`.
const OLLAMA_TEMPERATURE: f64 = 0.1;

/// GPT-OSS's response format conflicts with JSON mode; it gets this instead.
pub const GPT_OSS_SYSTEM_PROMPT: &str = "Output a single JSON object matching the requested extraction format. \
                                         Do not include code fences, prose, or reasoning.";

/// `_is_gpt_oss_model`.
fn is_gpt_oss_model(model_id: &str) -> bool {
    let normalized = model_id.to_lowercase();
    normalized == "gpt-oss" || normalized.strip_prefix("gpt-oss:").is_some_and(|tag| !tag.is_empty())
}

/// How one server is asked: the system prompt, temperature and response format.
#[derive(Clone, Debug, Default, PartialEq)]
struct RequestKnobs {
    system_prompt: Option<&'static str>,
    temperature: Option<f64>,
    response_format: Option<Value>,
}

/// `facts_language_model`'s choices per provider.
fn knobs(model: &FactModel) -> RequestKnobs {
    match model.provider.as_str() {
        "ollama" if is_gpt_oss_model(&model.model_id) => RequestKnobs {
            system_prompt: Some(GPT_OSS_SYSTEM_PROMPT),
            temperature: Some(OLLAMA_TEMPERATURE),
            response_format: None,
        },
        "ollama" => RequestKnobs {
            system_prompt: None,
            temperature: Some(OLLAMA_TEMPERATURE),
            response_format: Some(json!({"type": "json_object"})),
        },
        _ => RequestKnobs::default(),
    }
}

/// `langextract_examples`: a prompt's few-shot examples in LangExtract's types; an extraction
/// with no attributes carries none, as Python passed `None`.
fn examples(prompt: &EffectivePrompt) -> Vec<ExampleData> {
    prompt
        .examples
        .iter()
        .map(|example| ExampleData {
            text: example.text.clone(),
            extractions: example
                .extractions
                .iter()
                .map(|e| {
                    let extraction = Extraction::new(e.class.clone(), e.text.clone());
                    if e.attributes.is_empty() { extraction } else { extraction.with_attributes(e.attributes.clone()) }
                })
                .collect(),
        })
        .collect()
}

/// The grounded extractions as `facts` rows; an ungrounded one (the model quoting its own few-shot
/// example) cannot be traced to the text and is dropped.
fn grounded(extractions: Vec<Extraction>) -> Vec<Extracted> {
    let span = |position: usize| i32::try_from(position).unwrap_or(i32::MAX);
    extractions
        .into_iter()
        .filter_map(|e| {
            let interval = e.char_interval?;
            Some(Extracted {
                fact_class: e.extraction_class,
                text: e.extraction_text,
                attributes: e.attributes.unwrap_or_default(),
                char_start: span(interval.start_pos),
                char_end: span(interval.end_pos),
            })
        })
        .collect()
}

/// A chat client's failure, as LangExtract's model error.
#[derive(Debug)]
struct ModelFailure(String);

impl std::fmt::Display for ModelFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ModelFailure {}

/// LangExtract over the process's host: the [`FactExtractor`] `garage-service serve`, the app's
/// GarageXPCService (`garage-service-ffi`) and the CLI's in-process service run with.
pub struct LangExtractor {
    host: Arc<dyn Host>,
}

impl LangExtractor {
    /// The extractor whose every model request goes through `host`.
    pub fn new(host: Arc<dyn Host>) -> Self {
        Self { host }
    }

    /// The chat client for `model`, built through the egress rules: the document's class first,
    /// then the destination allowlist. Makes no request.
    fn chat_model(&self, model: &FactModel, servers: &Settings, corpus_class: &str) -> Result<ChatModel, String> {
        refuse_cloud_model_id(&model.model_id).map_err(|e| e.message().to_owned())?;
        model.check_egress(corpus_class, servers).map_err(|e| e.0)?;
        let settings = ChatSettings {
            fact_provider: model.provider.clone(),
            fact_model: model.model_id.clone(),
            inference_provider: String::new(),
            inference_model: String::new(),
            servers: servers.clone(),
            ..ChatSettings::default()
        };
        ChatModel::new(&settings, self.host.clone()).map_err(|e| e.0)
    }
}

impl FactExtractor for LangExtractor {
    fn extract(
        &self,
        model: &FactModel,
        servers: &Settings,
        corpus_class: &str,
        prompt: &EffectivePrompt,
        text: &str,
    ) -> Result<Vec<Extracted>, String> {
        let chat = self.chat_model(model, servers, corpus_class)?;
        let knobs = knobs(model);
        let ask = |prompt: &str| -> ::langextract::Result<String> {
            let mut messages = Vec::with_capacity(2);
            if let Some(system) = knobs.system_prompt {
                messages.push(json!({"role": "system", "content": system}));
            }
            messages.push(json!({"role": "user", "content": prompt}));
            chat.complete_with(&messages, None, knobs.temperature, knobs.response_format.clone())
                .map(|reply| reply.text)
                .map_err(|e| ::langextract::Error::Model(Box::new(ModelFailure(e.0))))
        };
        let config = ExtractConfig::new(prompt.description.clone(), examples(prompt));
        let document = ::langextract::extract(text, &config, &ask).map_err(|e| match e {
            ::langextract::Error::Model(failure) => failure.to_string(),
            other => format!("LangExtract: {other}"),
        })?;
        Ok(grounded(document.extractions))
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use garage_embed::host::{HttpRequest, HttpResponse};
    use serde_json::Map;

    use super::*;
    use crate::prompts::effective_prompts;

    /// A model server that answers every chat as the UI tests' `DeterministicLlamaEngine` does:
    /// LangExtract's fenced JSON with one `fact` per sentence of the prompt's final question.
    #[derive(Default)]
    struct SentenceServer {
        requests: Mutex<Vec<HttpRequest>>,
    }

    fn question(prompt: &str) -> Option<&str> {
        let body = prompt.trim_end().strip_suffix("\nA:")?;
        body.rfind("\nQ: ").map(|i| &body[i + 4..]).or_else(|| body.strip_prefix("Q: "))
    }

    fn sentence_answer(text: &str) -> String {
        let extractions: Vec<Value> = text
            .lines()
            .flat_map(|line| line.split_inclusive(['.', '!', '?']))
            .map(str::trim)
            .filter(|s| s.ends_with(['.', '!', '?']) && s.split(' ').count() >= 5)
            .map(|s| json!({"fact": s}))
            .collect();
        format!("```json\n{}\n```", serde_json::to_string_pretty(&json!({"extractions": extractions})).unwrap())
    }

    impl Host for SentenceServer {
        fn http(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
            self.requests.lock().unwrap().push(request.clone());
            let body: Value = serde_json::from_slice(&request.body).unwrap();
            let prompt = body["messages"].as_array().unwrap().last().unwrap()["content"].as_str().unwrap();
            let content = question(prompt).map_or_else(|| "no question".to_owned(), sentence_answer);
            let reply = json!({"choices": [{"message": {"role": "assistant", "content": content}}]});
            Ok(HttpResponse { status: 200, body: reply.to_string().into_bytes() })
        }
    }

    fn default_prompt() -> EffectivePrompt {
        effective_prompts(&[]).unwrap().remove(0)
    }

    fn slice(text: &str, fact: &Extracted) -> String {
        let (start, end) = (usize::try_from(fact.char_start).unwrap(), usize::try_from(fact.char_end).unwrap());
        text.chars().skip(start).take(end - start).collect()
    }

    const TEXT: &str = "# Notes\n\nAcme was founded in 1998 by Zoë Smith. It makes anvils for the whole valley.\n\
                        Short one. The roof was replaced after the storm last spring!";

    #[test]
    fn every_fact_is_grounded_in_the_text_through_the_hosts_llama_xpc_route() {
        let server = Arc::new(SentenceServer::default());
        let servers = Settings::default();
        let model = FactModel::new("llama_xpc", "gemma2-2b", &servers).unwrap();
        let facts = LangExtractor::new(server.clone())
            .extract(&model, &servers, "communication", &default_prompt(), TEXT)
            .unwrap();
        assert_eq!(
            facts.iter().map(|f| f.text.as_str()).collect::<Vec<_>>(),
            [
                "Acme was founded in 1998 by Zoë Smith.",
                "It makes anvils for the whole valley.",
                "The roof was replaced after the storm last spring!"
            ]
        );
        for fact in &facts {
            assert_eq!(fact.fact_class, "fact");
            assert_eq!(slice(TEXT, fact), fact.text, "a span in code points");
            assert_eq!(fact.attributes, Map::new());
        }
        let requests = server.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        let request = &requests[0];
        assert_eq!((request.method, request.path.as_str()), ("POST", "/v1/chat/completions"));
        assert_eq!(request.url, format!("{}/v1/chat/completions", servers.llama_host.trim_end_matches('/')));
        let body: Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body["model"], "gemma2-2b");
        assert_eq!(body.get("temperature"), None);
        assert_eq!(body.get("response_format"), None);
        let prompt = body["messages"][0]["content"].as_str().unwrap();
        assert!(prompt.starts_with(&default_prompt().description), "{prompt}");
        assert_eq!(question(prompt), Some(TEXT), "the prompt ends with the text as LangExtract's question");
    }

    #[test]
    fn ollama_gets_json_mode_and_gpt_oss_a_system_prompt() {
        let servers = Settings::default();
        let ask = |model_id: &str| {
            let server = Arc::new(SentenceServer::default());
            let model = FactModel::new("ollama", model_id, &servers).unwrap();
            LangExtractor::new(server.clone()).extract(&model, &servers, "document", &default_prompt(), TEXT).unwrap();
            let body: Value = serde_json::from_slice(&server.requests.lock().unwrap()[0].body).unwrap();
            body
        };
        let plain = ask("gemma2:2b");
        assert_eq!(plain["temperature"], 0.1);
        assert_eq!(plain["response_format"], json!({"type": "json_object"}));
        assert_eq!(plain["messages"].as_array().unwrap().len(), 1);
        let oss = ask("gpt-oss:20b");
        assert_eq!(oss.get("response_format"), None);
        assert_eq!(oss["messages"][0], json!({"role": "system", "content": GPT_OSS_SYSTEM_PROMPT}));
        assert!(is_gpt_oss_model("GPT-OSS") && !is_gpt_oss_model("gpt-oss:") && !is_gpt_oss_model("gpt-ossify"));
    }

    #[test]
    fn a_communication_never_reaches_a_host_that_is_not_loopback() {
        let server = Arc::new(SentenceServer::default());
        let servers = Settings { ollama_host: "http://gpu.local:11434".into(), ..Settings::default() };
        let model = FactModel::new("ollama", "gemma2:2b", &servers).unwrap();
        let extractor = LangExtractor::new(server.clone());
        let error = extractor.extract(&model, &servers, "communication", &default_prompt(), TEXT).unwrap_err();
        assert!(error.starts_with("facts:ollama: communications never leave this machine"), "{error}");
        assert!(server.requests.lock().unwrap().is_empty(), "nothing was sent");
        // A document may go to the configured off-box server.
        let facts = extractor.extract(&model, &servers, "document", &default_prompt(), TEXT).unwrap();
        assert_eq!(facts.len(), 3);
        assert_eq!(server.requests.lock().unwrap()[0].url, "http://gpu.local:11434/v1/chat/completions");
    }

    #[test]
    fn unapproved_servers_and_cloud_models_are_refused_before_anything_is_sent() {
        let server = Arc::new(SentenceServer::default());
        let extractor = LangExtractor::new(server.clone());
        let servers = Settings::default();
        let cloud = FactModel::new("ollama", "gpt-4o", &servers).unwrap();
        let error = extractor.extract(&cloud, &servers, "document", &default_prompt(), TEXT).unwrap_err();
        assert!(error.contains("names a cloud-hosted model"), "{error}");
        // A FactModel pointing somewhere the configuration does not name.
        let stray = FactModel { host_url: "http://elsewhere.example:11434".into(), ..cloud.clone() };
        let stray = FactModel { model_id: "gemma2:2b".into(), ..stray };
        assert!(extractor.extract(&stray, &servers, "document", &default_prompt(), TEXT).is_err());
        assert!(server.requests.lock().unwrap().is_empty());
    }

    #[test]
    fn ungrounded_extractions_are_dropped_and_examples_keep_their_attributes() {
        let mut quoted = Extraction::new("fact", "from the example");
        quoted.char_interval = None;
        let mut found = Extraction::new("event", "in 1998");
        found.char_interval = Some(::langextract::CharInterval { start_pos: 2, end_pos: 9 });
        let mut year = Map::new();
        year.insert("year".into(), json!("1998"));
        found.attributes = Some(year.clone());
        let facts = grounded(vec![quoted, found]);
        assert_eq!(
            facts,
            [Extracted {
                fact_class: "event".into(),
                text: "in 1998".into(),
                attributes: year,
                char_start: 2,
                char_end: 9
            }]
        );
        let converted = examples(&default_prompt());
        assert!(!converted.is_empty() && converted.iter().all(|e| !e.extractions.is_empty()));
    }

    #[test]
    fn a_model_failure_names_the_server() {
        struct Down;
        impl Host for Down {
            fn http(&self, _: &HttpRequest) -> Result<HttpResponse, String> {
                Err("connection refused".into())
            }
        }
        let servers = Settings::default();
        let model = FactModel::new("ollama", "gemma2:2b", &servers).unwrap();
        let error = LangExtractor::new(Arc::new(Down))
            .extract(&model, &servers, "document", &default_prompt(), TEXT)
            .unwrap_err();
        assert!(error.starts_with("local model 'gemma2:2b' is not available from the local Ollama server"), "{error}");
    }
}
