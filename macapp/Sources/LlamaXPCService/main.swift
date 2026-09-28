import LlamaEngine
import LlamaServiceHost

// MARK: - Process Entry Point

// llama.cpp behind the shared XPC/HTTP front end (//macapp/Sources/LlamaServiceHost).
let engine = LlamaCppEngine()
let delegate = LlamaXPCServiceDelegate(
    engine: engine,
    engineSelfTests: [embeddingKnownAnswersSelfTest(engine: engine)]
)
engine.httpURL = delegate.httpURL
delegate.bootstrap()
delegate.run()
