"""When a corpus element happened, so listings can put the most recent first.

An element's own time, not when Garage ingested it: a Messages thread's last
message (``meta.last_message_at``), a mail's ``Date`` header
(``meta.email_date``), else the file's modification time, and only for an
element with none of those its ``ingested_at``. A meta value that is not an
ISO timestamp (a mail whose ``Date`` header did not parse is kept verbatim) is
skipped rather than cast, so one odd header cannot fail a listing.
"""

from __future__ import annotations

_ISO = "'^[0-9]{4}-[0-9]{2}-[0-9]{2}T'"


def _meta_time(alias: str, key: str) -> str:
    value = f"{alias}.meta->>'{key}'"
    return f"CASE WHEN {value} ~ {_ISO} THEN CAST({value} AS timestamptz) END"


def document_time_sql(alias: str = "d") -> str:
    """A ``timestamptz`` expression for when the ``documents`` row ``alias`` happened."""
    return (
        f"coalesce({_meta_time(alias, 'last_message_at')}, {_meta_time(alias, 'email_date')}, "
        f"{alias}.mtime, {alias}.ingested_at)"
    )


def iso_utc_sql(expression: str) -> str:
    """``expression`` (a ``timestamptz``) as ISO 8601 text in UTC, which sorts as text in time order."""
    return f"""to_char({expression} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""
