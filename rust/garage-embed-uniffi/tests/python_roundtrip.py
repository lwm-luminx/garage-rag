"""UniFFI's Python bindings of the embed worker, end to end through the real library.

    python3 python_roundtrip.py DIR    # DIR holds garage_embed.py and the built shared library

A Python host answers the worker's HTTP requests; the worker's vectors, its typed request and
the errors (the host's and the worker's own) all cross the generated bindings. CI runs it after
generating the bindings (.github/workflows/ci.yaml, the rust job).
"""

import json
import sys

sys.path.insert(0, sys.argv[1])
import garage_embed as g  # noqa: E402

DEFAULTS = g.EmbedSettings(
    ollama_host=None, lmstudio_host=None, llama_host=None, lmstudio_api_token=None, batch_size=None
)


class FakeOllama(g.EmbedHost):
    def __init__(self):
        self.requests = []

    def http(self, request):
        self.requests.append(request)
        inputs = json.loads(bytes(request.body))["input"]
        return g.HttpResponse(status=200, body=json.dumps({"embeddings": [[1.0, 2.0]] * len(inputs)}).encode())

    def ensure_llama_model(self, model):
        raise g.HostError.Failed(reason="no loader")

    def embed_images(self, model, paths):
        raise g.HostError.Failed(reason="no images")

    def embed_image_texts(self, model, texts):
        raise g.HostError.Failed(reason="no images")

    def progress(self, status):
        pass

    def cancelled(self):
        return False


class Refusing(FakeOllama):
    def http(self, request):
        raise g.HostError.Failed(reason="connection refused by the test host")


host = FakeOllama()
vectors = g.embed_texts("ollama", "nomic-embed-text", ["a", "b", "c"], DEFAULTS, host)
assert vectors == [[1.0, 2.0]] * 3, vectors
assert host.requests[0].backend == g.Backend.OLLAMA, host.requests[0].backend
assert host.requests[0].url == "http://localhost:11434/api/embed", host.requests[0].url

try:
    g.embed_texts("ollama", "m", ["a"], DEFAULTS, Refusing())
    raise AssertionError("the host's error was swallowed")
except g.EmbedError.Failed as error:
    assert "connection refused by the test host" in str(error), error

try:
    g.models(g.Connection(endpoint=g.Endpoint.SOCKET(path="/nonexistent/garage.sock"), token=None))
    raise AssertionError("reached a socket that does not exist")
except g.EmbedError.Failed:
    pass

print("UniFFI Python round trip: ok")
