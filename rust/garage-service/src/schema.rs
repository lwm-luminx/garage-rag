//! The JSON Schema of `garage.json` (`garage_rag.config.json_schema`), which `garage config schema`
//! prints and `--publish` writes to `docs/.data/garage.schema.json`, served at [`SCHEMA_URL`].
//!
//! Every section and key comes from [`SECTIONS`], with each setting's type, default and
//! description, so a setting added there is in the schema at once; the shapes of `facts.prompts`
//! and `sources` are written out here.

use serde_json::{Map, Value, json};

use crate::config::{Kind, SCHEMA_URL, SECTIONS, Setting};

/// The schema document, in the order the file is written.
pub fn json_schema() -> Value {
    let mut properties = Map::new();
    properties.insert("$schema".to_owned(), json!({"type": "string", "description": "Path or URL to this schema."}));
    for setting in SECTIONS {
        let section = properties
            .entry(setting.section)
            .or_insert_with(|| json!({"type": "object", "additionalProperties": false, "properties": {}}));
        section["properties"][setting.key] = setting_schema(setting);
    }
    properties.insert("sources".to_owned(), sources_schema());
    json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "garage-rag configuration",
        "type": "object",
        "additionalProperties": false,
        "properties": properties,
        "$defs": prompt_defs(),
    })
}

/// The schema as `--publish` writes it: pretty-printed with a final newline.
pub fn json_schema_text() -> String {
    // The document is built from literals and strings, which always serialize.
    let mut text = serde_json::to_string_pretty(&json_schema()).unwrap_or_default();
    text.push('\n');
    text
}

/// Where `--publish` writes, the committed copy under `docs/.data`: found from `start` upwards by
/// the repository's `MODULE.bazel`.
pub fn repo_schema_path(start: &std::path::Path) -> Option<std::path::PathBuf> {
    start.ancestors().find(|dir| dir.join("MODULE.bazel").is_file()).map(|root| {
        root.join("docs").join(".data").join(std::path::Path::new(SCHEMA_URL).file_name().unwrap_or_default())
    })
}

fn setting_schema(setting: &Setting) -> Value {
    let mut schema = Map::new();
    match setting.kind {
        Kind::Str => {
            schema.insert("type".to_owned(), json!("string"));
        }
        Kind::OptStr => {
            schema.insert("type".to_owned(), json!(["string", "null"]));
        }
        Kind::Bool => {
            schema.insert("type".to_owned(), json!("boolean"));
        }
        Kind::Int => {
            schema.insert("type".to_owned(), json!("integer"));
        }
        Kind::Float => {
            schema.insert("type".to_owned(), json!("number"));
        }
        Kind::StrList => {
            schema.insert("type".to_owned(), json!("array"));
            schema.insert("items".to_owned(), json!({"type": "string"}));
        }
        Kind::Prompts => {
            schema.insert("type".to_owned(), json!("array"));
            schema.insert("items".to_owned(), prompt_schema());
        }
        Kind::Choice(choices) => {
            schema.insert("type".to_owned(), json!("string"));
            schema.insert("enum".to_owned(), json!(choices));
        }
    }
    schema.insert("description".to_owned(), json!(setting.doc));
    let default = setting.default_value();
    if !default.is_null() {
        schema.insert("default".to_owned(), default);
    }
    Value::Object(schema)
}

fn sources_schema() -> Value {
    json!({
        "type": "array",
        "description": "Sources to index. Declared sources are re-applied on every run; sources present only in the database are left untouched.",
        "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["slug", "root"],
            "properties": {
                "slug": {"type": "string", "description": "Short unique name, e.g. 'dropbox'."},
                "root": {"type": "string", "description": "Directory or file to index. '~' is expanded."},
                "kind": {"type": "string", "description": "filesystem | git | sqlite | maildir | feed | dropbox | onedrive"},
                "class": {"type": "string", "description": "Default grouping: document | code | communication"},
                "trust": {"type": "string", "description": "Default trust: authored | reference | received"},
                "include_code": {"type": "boolean", "description": "Index source files as well as documents."},
                "enabled": {"type": "boolean", "description": "Set false to skip this source."}
            }
        }
    })
}

/// One entry of `facts.prompts` (`FactPrompt` in `prompts.rs`).
fn prompt_schema() -> Value {
    json!({
        "additionalProperties": false,
        "description": "A named fact-extraction prompt, as written in ``facts.prompts``.",
        "properties": {
            "name": {
                "description": "Unique name, recorded on every fact the prompt produces. The name of a built-in prompt ('default') overrides it instead of adding a new one.",
                "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
                "title": "Name",
                "type": "string"
            },
            "description": {
                "anyOf": [{"type": "string"}, {"type": "null"}],
                "default": null,
                "description": "The instructions given to the model. Required for a new prompt; an override of a built-in may leave it out to keep the built-in's.",
                "title": "Description"
            },
            "examples": {
                "anyOf": [{"items": {"$ref": "#/$defs/FactExample"}, "type": "array"}, {"type": "null"}],
                "default": null,
                "description": "Few-shot examples (LangExtract's shape: text plus expected extractions). Required, and not empty, for a new prompt; an override of a built-in may leave it out to keep the built-in's.",
                "title": "Examples"
            },
            "corpus_classes": {
                "description": "Corpus classes the prompt runs on (document, code, communication); empty means all.",
                "items": {"enum": ["document", "code", "communication"], "type": "string"},
                "title": "Corpus Classes",
                "type": "array"
            },
            "sources": {
                "description": "Source slugs the prompt runs on; empty means every source.",
                "items": {"type": "string"},
                "title": "Sources",
                "type": "array"
            },
            "enabled": {
                "default": true,
                "description": "Set false to stop running this prompt.",
                "title": "Enabled",
                "type": "boolean"
            },
            "graph": {
                "anyOf": [{"$ref": "#/$defs/FactGraph"}, {"type": "null"}],
                "default": null,
                "description": "How this prompt's classes appear in the graph: vertices of their own label, or edges between other classes. Left out: its facts are PotentialFact and Fact vertices only."
            }
        },
        "required": ["name"],
        "title": "FactPrompt",
        "type": "object"
    })
}

const CLASS_PATTERN: &str = "^[A-Za-z0-9][A-Za-z0-9 _.-]{0,62}$";
const ATTRIBUTE_PATTERN: &str = "^[A-Za-z_][A-Za-z0-9_]{0,62}$";

/// The types `facts.prompts` refers to.
#[allow(clippy::too_many_lines)]
fn prompt_defs() -> Value {
    json!({
        "FactExample": {
            "additionalProperties": false,
            "description": "A few-shot example: a text and what should be extracted from it.",
            "properties": {
                "text": {"description": "Example input text.", "title": "Text", "type": "string"},
                "extractions": {
                    "description": "The extractions expected from the text, in the order they appear.",
                    "items": {"$ref": "#/$defs/FactExtractionExample"},
                    "title": "Extractions",
                    "type": "array"
                }
            },
            "required": ["text"],
            "title": "FactExample",
            "type": "object"
        },
        "FactExtractionExample": {
            "additionalProperties": false,
            "description": "One extraction the model should produce from an example's text.",
            "properties": {
                "class": {
                    "default": "fact",
                    "description": "Label for what kind of thing this is; stored as facts.fact_class.",
                    "title": "Class",
                    "type": "string"
                },
                "text": {
                    "description": "The extraction, quoted exactly from the example's text.",
                    "title": "Text",
                    "type": "string"
                },
                "attributes": {
                    "additionalProperties": {"anyOf": [{"type": "string"}, {"items": {"type": "string"}, "type": "array"}]},
                    "description": "Optional attributes the model should attach; stored as facts.attributes.",
                    "title": "Attributes",
                    "type": "object"
                }
            },
            "required": ["text"],
            "title": "FactExtractionExample",
            "type": "object"
        },
        "FactGraph": {
            "additionalProperties": false,
            "description": "How a prompt's classes appear in the graph.",
            "properties": {
                "vertices": {
                    "description": "Classes projected as vertices.",
                    "items": {"$ref": "#/$defs/GraphVertex"},
                    "title": "Vertices",
                    "type": "array"
                },
                "edges": {
                    "description": "Classes projected as edges.",
                    "items": {"$ref": "#/$defs/GraphEdge"},
                    "title": "Edges",
                    "type": "array"
                }
            },
            "title": "FactGraph",
            "type": "object"
        },
        "GraphEdge": {
            "additionalProperties": false,
            "description": "A class whose potential facts are edges between two other classes' distilled facts.",
            "properties": {
                "class": {
                    "description": "The extraction class (facts.fact_class) projected.",
                    "pattern": CLASS_PATTERN,
                    "title": "Class",
                    "type": "string"
                },
                "source": {
                    "description": "The attribute naming the edge's source.",
                    "pattern": ATTRIBUTE_PATTERN,
                    "title": "Source",
                    "type": "string"
                },
                "source_class": {
                    "description": "The class the source is a distilled fact of.",
                    "pattern": CLASS_PATTERN,
                    "title": "Source Class",
                    "type": "string"
                },
                "target": {
                    "description": "The attribute naming the edge's target.",
                    "pattern": ATTRIBUTE_PATTERN,
                    "title": "Target",
                    "type": "string"
                },
                "target_class": {
                    "description": "The class the target is a distilled fact of.",
                    "pattern": CLASS_PATTERN,
                    "title": "Target Class",
                    "type": "string"
                },
                "label": {
                    "default": "RELATED_TO",
                    "description": "The edge label, or the fallback when label_attribute names none of labels.",
                    "pattern": "^[A-Z][A-Z0-9_]{0,62}$",
                    "title": "Label",
                    "type": "string"
                },
                "label_attribute": {
                    "anyOf": [{"pattern": ATTRIBUTE_PATTERN, "type": "string"}, {"type": "null"}],
                    "default": null,
                    "description": "An attribute (e.g. predicate) whose value, upper-cased with spaces as _, picks the label.",
                    "title": "Label Attribute"
                },
                "labels": {
                    "description": "The labels label_attribute may pick, e.g. WORKS_AT; any other value takes label.",
                    "items": {"type": "string"},
                    "title": "Labels",
                    "type": "array"
                }
            },
            "required": ["class", "source", "source_class", "target", "target_class"],
            "title": "GraphEdge",
            "type": "object"
        },
        "GraphVertex": {
            "additionalProperties": false,
            "description": "A class whose distilled facts are vertices of their own label.",
            "properties": {
                "class": {
                    "description": "The extraction class (facts.fact_class) projected.",
                    "pattern": CLASS_PATTERN,
                    "title": "Class",
                    "type": "string"
                },
                "label": {
                    "description": "The vertex label, e.g. Person. Not one of the built-in labels.",
                    "pattern": "^[A-Z][A-Za-z0-9]{0,62}$",
                    "title": "Label",
                    "type": "string"
                },
                "title": {
                    "anyOf": [{"pattern": ATTRIBUTE_PATTERN, "type": "string"}, {"type": "null"}],
                    "default": null,
                    "description": "The attribute whose value names the vertex (its representative fact's); unset: the distilled fact's statement.",
                    "title": "Title"
                }
            },
            "required": ["class", "label"],
            "title": "GraphVertex",
            "type": "object"
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The committed copy, which the site serves, is what this module generates (`--publish`).
    #[test]
    fn the_published_schema_is_current() {
        let committed = include_str!("../../../docs/.data/garage.schema.json");
        assert!(
            json_schema_text() == committed,
            "docs/.data/garage.schema.json is stale: run `garage config schema --publish` and commit it"
        );
    }

    /// Every setting is documented: the schema is the settings' reference.
    #[test]
    fn every_setting_is_documented() {
        for setting in SECTIONS {
            assert!(!setting.doc.trim().is_empty(), "{} has no description", setting.name());
            assert!(setting.doc.ends_with('.') || setting.doc.ends_with(')'), "{} ends mid-sentence", setting.name());
        }
        let schema = json_schema();
        for setting in SECTIONS {
            let entry = &schema["properties"][setting.section]["properties"][setting.key];
            assert_eq!(entry["description"], json!(setting.doc));
            assert!(entry.get("type").is_some(), "{} has no type", setting.name());
        }
        assert_eq!(
            schema["properties"]["facts"]["properties"]["provider"]["enum"],
            json!(["llama_xpc", "ollama", "lmstudio"])
        );
        assert_eq!(
            schema["properties"]["embedding"]["properties"]["lmstudio_api_token_file"]["type"],
            json!(["string", "null"])
        );
        assert!(schema["properties"]["embedding"]["properties"]["lmstudio_api_token_file"].get("default").is_none());
    }

    #[test]
    fn the_schema_path_is_found_from_the_repository_root() {
        // Cargo runs the test where it was built; Bazel bakes in a sandbox path that is gone by the
        // time the test runs, from its runfiles root (which carries MODULE.bazel).
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let here = if manifest.is_dir() { manifest } else { std::env::current_dir().expect("a working directory") };
        let path = repo_schema_path(&here).expect("the crate is in the repository");
        assert!(path.ends_with("docs/.data/garage.schema.json"), "{}", path.display());
        assert!(repo_schema_path(std::path::Path::new("/")).is_none());
    }
}
