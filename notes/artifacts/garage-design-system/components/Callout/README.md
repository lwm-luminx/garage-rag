# Callout

A tinted note set into prose: `info` (brand violet), `success`, `warning`, `danger`. It keeps the site's 4px leading edge, with a hairline around the other three sides.

- The title defaults to a word for the tone ("Note", "Done", "Heads up", "Careful"); pass `title` to say what happened ("Alpha build").
- Body is one or two sentences in `ink`. State the consequence, then the reassurance: "Deletes the index. Your source files are not touched."
- `danger` gets `role="alert"`; the others are `role="note"`.
- Never stack more than two in a row.
