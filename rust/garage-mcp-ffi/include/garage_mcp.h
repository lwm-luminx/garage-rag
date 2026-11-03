// Garage's MCP server, linked in-process: the tools of garage_rag.mcp_server without Python.
//
// The server reads the corpus only through GarageService (the Corpus* calls in proto/garage.proto,
// whose replies are the Python tools' results) and reaches the local model only through the host
// below. Requests, results and host calls are UTF-8 JSON. Every result string is freed with
// garage_mcp_string_free.
//
// Built from rust/garage-mcp-ffi: libgarage_mcp_ffi.a (static, for the Mac app) and
// libgarage_mcp_ffi.{dylib,so,dll} (shared, for Python's parity tests).

#ifndef GARAGE_MCP_H
#define GARAGE_MCP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The call succeeded; the result is its JSON.
#define GARAGE_MCP_OK 0
// The request was not JSON of the expected shape, or a pointer was null: {"error"}.
#define GARAGE_MCP_BAD_REQUEST 1
// The server panicked: {"error"}. The process is unharmed.
#define GARAGE_MCP_PANIC 2
// The work failed (the listener could not bind, say): {"error"}.
#define GARAGE_MCP_FAILED 3

// A host call: `request` is JSON. Returns 0 and sets `*reply` to JSON, or nonzero and sets
// `*reply` to the reason (or leaves it NULL). The server frees `*reply` with the host's `release`.
typedef int32_t (*GarageMcpHostCall)(void *context, const char *request, char **reply);

// The process the server runs in. Its functions may be called from any thread, several at once,
// and `context` must stay valid until garage_mcp_http_stop returns (or garage_mcp_handle does).
typedef struct GarageMcpHost {
    void *context;
    // An HTTP request to the local model's server, already approved by the egress rules:
    // {"backend": "ollama" | "lmstudio" | "llama_xpc", "method", "url", "path",
    //  "headers": [[name, value], ...], "body": string, "timeout": seconds}
    // -> {"status": int, "body": string}. Send it to exactly `url`: no proxy, and a redirect is
    // the reply, never followed. A llama_xpc request may go over the host's own connection to
    // LlamaXPCService instead (`path` is the route). Nonzero only when no reply came.
    GarageMcpHostCall http;
    // {"model"}: LlamaXPCService said the model is not loaded; load it. Reply: what was done.
    // May be NULL.
    GarageMcpHostCall ensure_llama_model;
    // Frees a reply one of the calls above set.
    void (*release)(void *context, char *reply);
} GarageMcpHost;

typedef struct GarageMcpHttpServer GarageMcpHttpServer;

// Starts the streamable HTTP transport and returns once it listens:
// {"grpc": {"socket": path} | {"host", "port"}, plus "token": the per-launch GARAGE_GRPC_TOKEN},
//  "http": {"host" (default 127.0.0.1), "port" (default 8787; 0 picks one), "path" (default /mcp),
//           "allowed_origins": [...], "allowed_hosts": [...]}}
// -> {"address": "host:port", "path"}, with *server set; or {"error"} when it cannot listen.
// GarageService is reached on the first tool call, not here, so the server may start first.
int32_t garage_mcp_http_start(const char *request, const GarageMcpHost *host, GarageMcpHttpServer **server,
                              char **result);

// Whether the server is serving.
bool garage_mcp_http_is_running(const GarageMcpHttpServer *server);

// Stops and frees the server; requests in flight get up to ten seconds to finish.
void garage_mcp_http_stop(GarageMcpHttpServer *server);

// Answers one JSON-RPC message, for a stdio front end and tests:
// {"grpc": {...}, "message": {...}, "transport": "stdio" | "http", "registration_token": ...}
// -> {"reply": the reply, or null for a notification}.
int32_t garage_mcp_handle(const char *request, const GarageMcpHost *host, char **result);

// Frees a result string from this library.
void garage_mcp_string_free(char *text);

#ifdef __cplusplus
}
#endif

#endif
