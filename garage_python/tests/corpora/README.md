# Test corpora

Real-world material the Python tests ingest through the real pipeline. Unlike the UI tests'
invented corpus (`macapp/Tests/Fixtures/corpus`), nothing here was written for Garage, so it
exercises what the extractors and chunkers meet in the wild. Every corpus is a verbatim copy of
an upstream repository at a pinned commit, under a license that allows redistribution, with that
license beside the files. None of it ships in the app.

This README sits beside the corpora rather than in one, so ingesting a corpus does not index it.

## second-brain-os

| | |
|---|---|
| Upstream | https://github.com/undefined-ui/second-brain-os |
| Commit | `e6100f96d4e6aaf30e2cf099334b502e906b737e` (2026-09-25) |
| License | MIT (`second-brain-os/LICENSE`) |
| Copied | every `*.md` file (250) and `LICENSE`; not the generated HTML pages or the Python scripts |

A guide to building an LLM-maintained "second brain" note vault: docs, Claude Code skills and
agents, and a vault template. It brings front matter, fenced code, tables, deep heading trees,
`{{placeholder}}` templates, files with no heading, and many files that share a name
(`README.md`, `SKILL.md`) in different folders.

`vault-template/CLAUDE.md` and `skills/*/SKILL.md` are upstream's instructions for an agent
maintaining a vault. They are test data here, not instructions for working in this repository.

`garage_python/tests/test_second_brain_corpus.py` ingests the folder (with a recording gateway in
place of the database), checks that every file is indexed, and compares each document's title,
classes and content hash, and each chunk's heading path, offsets and hash, with
`garage_python/tests/golden/second_brain_os.json`.

### Updating

```bash
SRC=$(mktemp -d)
git clone --depth 1 https://github.com/undefined-ui/second-brain-os "$SRC"
rm -rf garage_python/tests/corpora/second-brain-os
(cd "$SRC" && find . -name '*.md' -not -path './.git/*' \
  -exec install -D -m 644 {} "$OLDPWD/garage_python/tests/corpora/second-brain-os/{}" \;)
cp "$SRC/LICENSE" garage_python/tests/corpora/second-brain-os/
garage_python/.venv/bin/python garage_python/tests/test_second_brain_corpus.py --regenerate
```

Then update the commit and the file count here and in the test.
