---
layout: default
title: Attribution & Identity
description: How Garage works out who wrote each document it indexes, from git history, document metadata, path conventions and mail senders, and how trust tiers shape search.
---

# Attribution

How the pipeline decides who wrote something and how much to trust it. Every
decision records its `evidence`, so a wrong answer is traceable to the rule
responsible.

## Precedence

Signals are tried in order; the first that produces an answer wins.

### 1. Git history — authoritative

For a tracked file, `attribute/git.py` supplies the contributors and their commit
counts. The decision that matters:

- **The owner has commits on this file** → `authored`
- **No commits by the owner** → `reference`

That single test separates your own repository from a clone of someone else's,
which no other signal can do. It works per *file*, so a fork where you changed
three files attributes those three to you and the rest to upstream.

Real output from this corpus:

```
reference  agave         owner=anza-xyz     top=Brooks           git-log:no-self-commits
reference  chainlink     owner=smartcontr…  top=Jordan Krage     git-log:no-self-commits
reference  bitchat       owner=rickmark     top=Vignesh Skanda   git-log:no-self-commits
authored   demuxusb      README.md                               git-log:self-commits:4/4
authored   integrity-coin README.md                              git-log:self-commits:4/4
```

Note `bitchat`: the remote is under your account, but you never touched that
README, so it is `reference`. Ownership of the *repository* is not authorship of
the *file*.

> **Performance.** `git log --follow` per file across ~18k tracked documents would
> mean 18k git invocations. Instead one `git log --name-only --no-renames` pass
> per repository builds a path→authors map in memory. Measured: 60 repositories,
> 277,796 tracked paths, **29 seconds** total.
>
> The tradeoff is `--no-renames`. Following renames requires per-file history; a
> renamed file is attributed from commits touching its current path, which in
> practice still identifies the right person.

> **No git needed.** History is read in-process through libgit2; Garage never runs `git`,
> so this signal works on a Mac without the Xcode Command Line Tools. The app's Python has a
> built-in `_garage_git` module with libgit2 linked in statically (`//ext/python`,
> `//ext/libgit2`). A venv or PyPI install reads through pygit2 instead
> (`pip install 'garage-rag[git]'`); with neither, git history is skipped and files are
> attributed from the signals below.

### 2. Embedded document metadata

PDF `/Author`, Office core properties, Markdown frontmatter `author:`.

Reliable when present, absent most of the time — no Markdown file in this corpus
carries an `author:` key, so frontmatter is a bonus path, not a dependency.

Metadata is filtered through `looks_like_tool_name()`, because software writes
its own name into these fields. Without the filter, `python-pptx`'s default
template attributes every deck to the library's author ("Steve Canny") and
`openpyxl` names itself on every spreadsheet. Tool names are kept in `meta` for
provenance but never become authors.

A third party's name in the metadata implies `reference`; the owner's implies
`authored`. A reference-shaped *path* still overrides an authored guess — "in
`Reference/` but carries my name" is usually a paper you collected.

### 3. Path convention

`attribute/pathrules.py`, first match wins. Data, not logic — adapting to a
different layout means editing the table.

| Pattern | Trust |
|---|---|
| `Reference/*` | `reference` |
| `Documents/Paper/Reference/*` | `reference` |
| `**/{Documentation,Datasheets,Manuals,Books,Papers,Specs,RFCs}/*` | `reference` |
| `Personal/*`, `Projects/*`, `Notes/*` | `authored` |
| `Documents/{Research,Paper}/*` | `authored` |
| any component named `reference`/`papers`/`manuals`/… | `reference` |
| anything else | source default |

Vendored trees (`node_modules`, `vendor`, `third_party`, `Pods`,
`site-packages`, …) are `reference` **wherever they appear**, checked before the
path table.

### 4. Source default

Whatever `garage add-source --trust` recorded.

## Identity resolution

An author owns many identities. Resolution is lookup-by-identity, create-on-miss,
so one person arriving first as a git email and later as a PDF byline collapses
onto a single row rather than duplicating.

Configure your own identities so the authored/reference split works:

```json
"identity": {
  "name": "Your Name",
  "identities": [
    "git_email:you@example.com",
    "email:you@example.com",
    "git_name:Your Name"
  ]
}
```

Add every address you have committed under. An identity you omit reads as
somebody else, and your own work is filed as `reference`.

## Communications

The schema has three roles for messages and mail alongside `author` and
`committer` (`AuthorRole` in `db/models.py`): `sender`, `recipient`, `cc`.

**Mail** (`.eml`, `.emlx`) replaces the metadata signal with the sender. For an
extracted message the resolver reads the `From:` addresses
(`_sender_attribution` in `attribute/resolver.py`): your name or address makes
the message `authored` (`message-sender:self`), anyone else's makes it
`received` (`message-sender:third-party`). A byline on a paper means you
collected it; a name on a message means it was sent to you, so the
document-metadata rule, which would call it `reference`, does not apply. The
senders are recorded with role `author`. Git history still comes first, so a
message file tracked in a repository is attributed from its commits.

**Messages** threads (`ingest/conversations.py`) record every handle in the
thread: those who wrote in it as `sender`, those who only read it as
`recipient` (evidence `imessage-handle`), and you as `sender` when you wrote and
`identity.name` is set (`imessage-is-from-me`), or as `recipient` in a thread
you only read (`imessage-owner`): a thread is always you plus one or more
others. The thread's trust is the source's default (`received` for the app's
Messages preset). Since a thread holds both sides, each message's chunk says who
wrote it: `chunks.direction` is `sent` for your own messages and `received` for
everyone else's, and `chunks.sender` is the handle, or `me`.

A handle's author is named after the handle (`+15551234567`) until the ingest is
given a contact name for it (`extract/contact_names.py`): from Contacts, which the app
reads and passes to each ingest, or, for a Messages handle Contacts does not know,
the name that contact shared over iMessage (`extract/nicknames.py`). When the name arrives,
that author row takes it; when another author already has the name (the same
person's other number or email), the row is merged into that one, identities
and document links included. An author that already has a real name keeps it.
The author filter in search matches identities as well as names, so filtering
by a phone number still finds a named author's threads.

`cc` is not assigned yet.

## Corpus class

Independent of trust, decided by content shape with the source default as
fallback (`ingest/classify.py`):

- Code extensions → `code`
- Documentation names (`README`, `LICENSE`, `SECURITY`, `CHANGELOG`…) → `document`,
  **but only when the extension is not itself a code extension**. Otherwise
  `security.rb` and `license.py` would be misfiled as prose — a bug this code had
  and now has a regression test for.
- Conversations, or a source that pins the class → `communication`

Structured config (`.json`, `.yaml`, `.toml`, `.ini`, `.csv`) counts as **code**.
As documents it was 63% of this corpus — 461k of 726k chunks of CI workflows and
dependency manifests — and pure retrieval noise. It is still indexable with
`--include-code`, filed as `code`.

## Inspecting decisions

```bash
garage extract <file>          # shows author hints and extracted metadata
garage search "..." --author "Name"
garage search "..." --trust authored     # only your own writing
garage search "..." --trust reference    # only QA'ed external material
garage search "..." --direction sent     # only messages you sent
```

The `evidence` column on `document_authors` records exactly which rule fired:

```sql
SELECT a.display_name, da.role, da.confidence, da.evidence
FROM document_authors da JOIN authors a ON a.id = da.author_id
WHERE da.document_id = 123;
```
