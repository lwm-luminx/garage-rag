import LlamaServiceHost
import LlamaTestSupport

// MARK: - Process Entry Point

// LlamaXPCService's own front end (//macapp/Sources/LlamaServiceHost) on the deterministic test
// engine instead of llama.cpp: the UI tests' host app (GarageApp_uitest) embeds this under the
// real service's bundle identifier, so the app, the Python llama_xpc provider and the MCP server
// reach it exactly as they reach the real one.
let delegate = LlamaXPCServiceDelegate(engine: DeterministicLlamaEngine())
delegate.bootstrap()
delegate.run()
