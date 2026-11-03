//! What the worker needs from the process that runs it.
//!
//! The worker builds every request and decides whether it may be sent ([`crate::egress`]); the
//! host carries it. That keeps TLS, proxies and the app's NSXPC connections out of the worker: in
//! the Mac app a `llama_xpc` request goes over NSXPC to LlamaXPCService, an image model is asked
//! through the image embedding service, and Ollama or LM Studio are reached with the system's
//! HTTP stack, all as the Python worker reached them.

use std::time::Duration;

use crate::provider::BackendKind;
use crate::worker::BackfillEvent;

/// One HTTP request to a model server.
#[derive(Clone, Debug, PartialEq)]
pub struct HttpRequest {
    /// Which server, so a host can route `llama_xpc` to its own connection.
    pub backend: BackendKind,
    pub method: &'static str,
    /// The absolute URL, already approved. The host sends the request there and nowhere else:
    /// no proxy, and a redirect is answered as the response it is, never followed.
    pub url: String,
    /// The path part of `url`, for a host that carries the request some other way (NSXPC).
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub timeout: Duration,
}

/// The server's reply, whatever its status.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// The process the worker runs in. Every method may be called from the worker's thread.
pub trait Host: Send + Sync {
    /// Sends a request and returns the reply, or why none came (refused, reset, timed out).
    ///
    /// # Errors
    ///
    /// A readable reason when no HTTP reply came.
    fn http(&self, request: &HttpRequest) -> Result<HttpResponse, String>;

    /// Has LlamaXPCService load `model`, which a request found not loaded; returns what was done.
    ///
    /// # Errors
    ///
    /// Why the model could not be loaded.
    fn ensure_llama_model(&self, model: &str) -> Result<String, String> {
        Err(format!("no model loader in this process to load {model}"))
    }

    /// Embeds the image files at `paths` with the image model `model` (`image_xpc`), one vector per
    /// file. The host reads the files: it is the process with access to the user's folders.
    ///
    /// # Errors
    ///
    /// Why the images could not be embedded.
    fn embed_images(&self, model: &str, paths: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let _ = (model, paths);
        Err("image models are the app's; this process has no image embedding service".into())
    }

    /// Embeds `texts` with the text tower of the image model `model` (`image_xpc`).
    ///
    /// # Errors
    ///
    /// Why the texts could not be embedded.
    fn embed_image_texts(&self, model: &str, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let _ = (model, texts);
        Err("image models are the app's; this process has no image embedding service".into())
    }

    /// One step of a backfill, as it happens.
    fn progress(&self, event: &BackfillEvent) {
        let _ = event;
    }

    /// Whether the caller has asked the backfill to stop; checked between batches.
    fn cancelled(&self) -> bool {
        false
    }
}
