# Badge

An uppercase pill (`badge` style, `radius-pill`) that shows a state or a corpus class. It always carries its word: colour is never the only signal.

- Plan status: `accent` = proposed / active, `success` = landed, `warning` = deferred, `neutral` = reference.
- Ingest state: `success` = OK, `danger` = failed.
- Corpus class (adds a dot): `corpus-document` (blue), `corpus-code` (brand violet), `corpus-communication` (green; communications never leave the machine). These match the app's `tint(forCorpusClass:)`.
- One or two words. Do not use it as a button.
