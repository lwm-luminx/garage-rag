"""Search over the corpus.

Only the lightweight shared types live here; :mod:`garage_rag.search.hybrid`
imports every embedding backend and is loaded on demand.
"""

from typing import Literal

SearchMode = Literal["hybrid", "vector", "fts"]
# chunks.direction of a message chunk (014_chunk_direction.sql).
Direction = Literal["sent", "received"]

__all__ = ["Direction", "SearchMode"]
