# UI test corpus

`corpus/` is a small, made-up corpus for the UI tests (`macapp/Tests/GarageAppUITests` and
`macapp/Tests/GarageAppModelUITests`). Nothing
in it is true: the places, people, dates and words were invented so that a test can ask for them
and know the answer. Each file carries one invented word, its **token**, that appears in no other
file, so a search hit can be traced to its file.

The UI test bundle carries the folder as `Resources/corpus` (`:corpus_resources` in this
package's `BUILD.bazel`). `GarageUITestCase.copyFixtureCorpus()` copies it into the test's
throwaway data folder, and the tests add that copy as a source. The committed folder is never a
source itself.

This README sits beside the folder rather than in it, so ingesting the folder does not index it.

## Files

| File | Extractor | Title | Class | Trust | Chunks | Token | Known fact |
|---|---|---|---|---|---|---|---|
| `quillon-bridge.md` | markdown | The Quillon Bridge | document | authored | 2 | zorvexine | The Quillon Bridge opened in 1893. Its engineer was Adela Morcombe. |
| `marrowgate-lighthouse.txt` | plaintext | Marrowgate Lighthouse | document | authored | 1 | plimbrate | Idra Voss kept the Marrowgate lighthouse for forty-one years (1902 to 1943). |
| `tide_tables.rs` | code | tide_tables.rs | code | authored | 1 | tessaroon | High water at Port Ellery comes 52 minutes later each day. |
| `lantern-festival.eml` | email | The Brindlecombe lantern festival | communication | received | 1 | wendleflock | The Brindlecombe lantern festival is held on the third Saturday of October. |
| `ashvale-orchard.pdf` | pypdf | The Ashvale Orchard Survey | document | reference | 1 | orbanquet | The Ashvale orchard grows 212 varieties of pear. |
| `tavish-glassworks.docx` | python-docx | A History of Tavish Glassworks | document | reference | 1 | glimmerhaft | Tavish Glassworks was founded by Mirela Tavish in 1911. |

What the tests can count on:

- **Documents.** A source added through the Sources page has code off, so it indexes **five**
  documents: every file but `tide_tables.rs`. With code on, six.
- **Chunks.** Six with code off (the Markdown note splits at its `## Repairs` heading), seven
  with code on.
- **Titles and filters.** The Documents page filters by title or URI, so `quillon` finds only
  the Markdown note and `lantern` only the mail.
- **Trust.** The PDF and the Word file name an author (Nell Oduya, Mirela Tavish) in their
  metadata, who is not the data folder's owner, so they are `reference`. The mail is from Oren
  Pask, so it is `received`. The rest are `authored`, the source's default.
- **Tokens.** Each token appears in its own file only, so a search or fact that carries it came
  from that file.
- **Facts.** The model UI tests distil the corpus with `DeterministicLlamaEngine`
  (`macapp/Tests/LlamaTestSupport`), which makes one fact of every sentence of five words or more:
  kind `event` (with a `year` attribute) when it holds a four-digit year, `fact` otherwise. From the
  five documents that is 20 facts, 11 of them events and 3 from the mail; the one carrying a
  token is the Markdown note's "Townspeople call the middle arch the zorvexine arch, ...".

`garage_python/tests/test_fixture_corpus.py` ingests the folder through the real pipeline (with a
recording gateway in place of the database) and checks every row of the table above, so a change
to an extractor that would break a UI test fails on Linux CI first.

## Rebuilding

`make_corpus.py` writes every file, the PDF by hand and the Word file with python-docx, with fixed
timestamps, so a rerun gives the same bytes on the same machine:

```bash
garage_python/.venv/bin/python macapp/Tests/Fixtures/make_corpus.py
```

To add a file, add it to `FILES` in the script, then to the table here and to `EXPECTED` in
`test_fixture_corpus.py`.
