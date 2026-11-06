"""The embed worker (rust/garage-embed-uniffi): ``backfill``, ``models``, ``embed_texts`` and the
``EmbedHost`` protocol a host implements. The generated bindings live in ``garage_rag._native``;
this module keeps their 0.1 import path, with the same objects."""

from ._native.garage_embed import *  # noqa: F403
from ._native.garage_embed import __all__  # noqa: F401
