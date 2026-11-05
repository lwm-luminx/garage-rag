# frozen_string_literal: true

# The garage_rag gem end to end through the real library, as garage-embed-uniffi's
# tests/python_roundtrip.py does for Python: a Ruby host answers the worker's HTTP requests, and the
# worker's vectors, its typed request and the errors (the host's and the worker's own) all cross the
# generated bindings. release.yaml runs it against each built gem before publishing.
#
#     gem install garage_rag-*.gem && ruby rust/garage-rag/ruby/test/roundtrip.rb
require "json"
require "garage_rag"

G = GarageRag::GarageEmbed

DEFAULTS = G::EmbedSettings.new(
  ollama_host: nil, lmstudio_host: nil, llama_host: nil, lmstudio_api_token: nil, batch_size: nil
)

class FakeOllama
  attr_reader :requests

  def initialize
    @requests = []
  end

  def http(request)
    @requests << request
    inputs = JSON.parse(request.body)["input"]
    G::HttpResponse.new(status: 200, body: JSON.generate({ "embeddings" => [[1.0, 2.0]] * inputs.length }))
  end

  def ensure_llama_model(_model) = raise(G::HostError::Failed.new(reason: "no loader"))
  def embed_images(_model, _paths) = raise(G::HostError::Failed.new(reason: "no images"))
  def embed_image_texts(_model, _texts) = raise(G::HostError::Failed.new(reason: "no images"))
  def progress(_status) = nil
  def cancelled = false
end

class Refusing < FakeOllama
  def http(_request) = raise(G::HostError::Failed.new(reason: "connection refused by the test host"))
end

def check(condition, message)
  raise message unless condition
end

host = FakeOllama.new
vectors = G.embed_texts("ollama", "nomic-embed-text", %w[a b c], DEFAULTS, host)
check(vectors == [[1.0, 2.0]] * 3, "vectors: #{vectors.inspect}")
check(host.requests[0].backend == G::Backend::OLLAMA, "backend: #{host.requests[0].backend.inspect}")
check(host.requests[0].url == "http://localhost:11434/api/embed", "url: #{host.requests[0].url}")

begin
  G.embed_texts("ollama", "m", ["a"], DEFAULTS, Refusing.new)
  raise "the host's error was swallowed"
rescue G::EmbedError::Failed => e
  check(e.message.include?("connection refused by the test host"), "error: #{e.message}")
end

begin
  G.models(G::Connection.new(endpoint: G::Endpoint::SOCKET.new(path: "/nonexistent/garage.sock"), token: nil))
  raise "reached a socket that does not exist"
rescue G::EmbedError::Failed
  nil
end

puts "UniFFI Ruby round trip: ok"
