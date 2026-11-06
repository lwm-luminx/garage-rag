# frozen_string_literal: true

# The garage_rag gem: Garage's UniFFI bindings for Ruby, one platform gem per OS and CPU with the
# garage-rag shared library inside. ruby/build.sh lays out lib/ and builds it; the version is the
# library's (rust/garage-rag/Cargo.toml, the app's release version), passed as GARAGE_RAG_VERSION,
# and the platform GARAGE_RAG_GEM_PLATFORM.
version = ENV.fetch("GARAGE_RAG_VERSION") { raise "set GARAGE_RAG_VERSION (ruby/build.sh does)" }

Gem::Specification.new do |spec|
  spec.name = "garage_rag"
  spec.version = version
  spec.platform = ENV.fetch("GARAGE_RAG_GEM_PLATFORM", Gem::Platform.local.to_s)
  spec.summary = "Garage's Rust components for Ruby: the garage command line and the embed worker, with typed records, errors and a host protocol."
  spec.description = "UniFFI bindings of Garage (https://garagerag.app), a local-first personal RAG pipeline: " \
                     "the garage command line, run in-process, and the embed worker, which hands each " \
                     "model-server request to a host you implement."
  spec.authors = ["Rick Mark-Penwell"]
  spec.homepage = "https://garagerag.app"
  spec.license = "MIT"
  spec.metadata = {
    "source_code_uri" => "https://github.com/lwm-luminx/garage-rag",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*"]
  spec.require_paths = ["lib"]
  spec.add_dependency "ffi", "~> 1.17"
end
