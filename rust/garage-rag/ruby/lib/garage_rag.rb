# frozen_string_literal: true

# Garage's UniFFI bindings for Ruby. Each namespace of the garage-rag library is its own generated
# module, loaded here and reachable under GarageRag:
#
#   require "garage_rag"
#   GarageRag::GarageEmbed.embed_texts(...)   # the same module as ::GarageEmbed
require_relative "garage_rag/garage_embed"

module GarageRag
  GarageEmbed = ::GarageEmbed
end
