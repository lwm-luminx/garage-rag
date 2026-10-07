# Garage Models page: design

## What the page is for

Someone opens Models to answer, in this order:

1. Is search working: is there an embedding model, is the corpus embedded with it, and is the
   model on disk?
2. Is fact distillation set up: which model gleans facts, is it on disk, is it loaded?
3. Can I add another model, or switch the one in use?

And rarely, when something is off: which file is this, does its hash match, what table does it
write to, does Llama XPC answer, can I embed a sentence and look at the numbers.

## Critique of the page on `main`

It is a debugging panel with nine stacked group boxes, most of them for the rare case:

- **Every registered model carries up to eight uppercase badges** (LLAMA XPC, DEFAULT, REGISTERED,
  ACTIVE IN LLAMA XPC, DOWNLOADED (GGUF), SHA-256 VERIFIED, 100% EMBEDDED…) plus the slug, dims,
  ctx, ref, local file, expected hash and computed hash, all at once. "REGISTERED" on every row of
  the *Registered Models* list says nothing. The answer to "is search working" is buried in there.
- **Adding a model happens in two places.** An "Available Models" box with a Register button per
  preset, and below it a "Model Configuration & Registration" form with a Preset/Custom segmented
  picker, an Advanced Settings toggle, and List / Set Default / Drop buttons that duplicate the
  row menu. The form's "Model Name" field was never sent anywhere.
- **Embed appears twice per row** (a button and a menu item), and "Download to Llama XPC" and
  "Load Model" are blue and purple prominent buttons on every row.
- **The full-vector inspector is always open**, with a 60-point text editor, a picker and up to
  four badges, before the distillation model is even reached.
- **Llama XPC gets its own box** with Ping and Refresh and a "Health Status: ok" table, and a
  separate "Llama Output" box prints "Success: …" lines after each load.
- **The LM Studio token** is a third box, with its own explanation.

## The design as built

Rick's follow-up (2026-09-25 15:00 UTC): the page should be tabs. So the page is a segmented
control at the top (Overall · Embedding · Distillation) with the refresh button beside it, and
three pages under it:

- **Overall** answers the questions at a glance. An Embedding card leads with one headline in
  the Status page's style (Search ready / 880 embeddings to go with a bar / Embedding… / Waiting
  for ingest / Model file missing / No embedding model), the Embed All and Manage… buttons, and
  one line per model under it. A Fact Distillation card does the same for the model in use
  (its name, "Loaded in Llama XPC" or "On disk", Glean Facts, Manage…) with the other presets
  listed under it. Then the Providers box and the run output.
- **Embedding** is the model rows with their actions and details, Add a model, and the folded
  Test an Embedding panel.
- **Distillation** is the preset rows and the Fact Prompts section.

Manage… on a card switches to that tab; "Test an Embedding…" on a row's menu switches to the
Embedding tab with the panel open. The Embedding and Distillation pages are the boxes described
below.

```
┌ Text Embedding Models ─────────────────────────────────────────────────┐
│ 2 models · 9,120 of 20,000 embeddings done      [Embed All] (↻)        │
│ ╭────────────────────────────────────────────────────────────────────╮ │
│ │ (✓) BGE-M3  DEFAULT LOADED            [Unload] [Embed] (…) ›       │ │
│ │     Embedded · 10,000 chunks                                       │ │
│ ╰────────────────────────────────────────────────────────────────────╯ │
│ ╭────────────────────────────────────────────────────────────────────╮ │
│ │ (⬇) Nomic Embed v1.5                  [Download] [Embed] (…) ›     │ │
│ │     Not downloaded                                                 │ │
│ ╰────────────────────────────────────────────────────────────────────╯ │
│ ──────────────────────────────────────────────────────────────────── │
│ Add a model                                                            │
│   Qwen3 Embedding 0.6B  RECOMMENDED  1024 DIMS               [Add]     │
│   description · use cases                                              │
│ › Custom model…                                                        │
└────────────────────────────────────────────────────────────────────────┘
┌ Fact Distillation Model ───────────────────────────────────────────────┐
│ One model is in use at a time.                        [Glean Facts]    │
│ ╭────────────────────────────────────────────────────────────────────╮ │
│ │ (⚡) Qwen3 1.7B  IN USE           [Unload] [Use for Facts] (…) ›   │ │
│ │     Loaded in Llama XPC                                            │ │
│ ╰────────────────────────────────────────────────────────────────────╯ │
└────────────────────────────────────────────────────────────────────────┘
┌ Fact Prompts ──────────────────────────────────────────────────────────┐  (unchanged)
┌ Providers ─────────────────────────────────────────────────────────────┐
│ (●) Llama XPC   Running · loaded: bge-m3, qwen3 · 3 slots idle         │
│                                              [Unload All] [Refresh]    │
│ (🔑) LM Studio  API token stored in the Keychain   [••••] [Replace]    │  (only when used)
└────────────────────────────────────────────────────────────────────────┘
› Test an Embedding   Embed a sentence and inspect the full vector         (collapsed)
  Embedding Output / Fact Distillation Output                              (only while logs exist)
```

### One row per model, one line of state

A row is a tinted symbol circle (the menu bar popover's Control Center idiom), the model's
name, at most three tags, and **one line that says where the model stands**, in this order of
precedence:

| circle | line | when |
|---|---|---|
| blue, filled, ⬇ | Downloading · 1.2 GB of 2.3 GB · 40 MB/s · 27s left, with a bar and Cancel | a download is in flight |
| orange, faint, ⬇ | Not downloaded | a Llama XPC model whose file is missing |
| grey, faint | No chunks to embed yet | the corpus is empty |
| green, filled, ✓ | Embedded · 10,000 chunks | every chunk has a vector |
| blue, filled | Embedding · 9,120 of 10,000 chunks, with a bar | a backfill is running |
| orange, faint | 880 chunks to embed · 9,120 of 10,000 done, with a bar | otherwise |

Distillation rows say Loaded in Llama XPC / On disk · loads when facts are gleaned / Served by
Ollama. The file comes first because without it nothing else can happen.

Tags: DEFAULT or IN USE (green), the provider only when it is not Llama XPC, and LOADED
(purple) when Llama XPC holds an embedding model. Nothing else.

Actions follow from the state: Download while the file is missing, Load or Unload once it is
there, Embed (embedding rows) or Use for Facts (distillation rows), and a (…) menu with Set as
Default, Test an Embedding…, Copy Expected SHA-256, Verify File, Reveal in Finder, Delete Model
File and Remove from Database. No prominent buttons on rows.

### Details behind a chevron

The chevron on the right opens a label/value grid: slug, model ref, provider, dimensions with
how they are stored (`1024 · halfvec HNSW`), context, table, file and size, and the SHA-256 with
a Verify or Compute button. A verified hash replaces the expected one instead of repeating it; a
mismatch shows both.

### Adding a model

Presets from models.json that are not registered yet are rows with one **Add** button
(RECOMMENDED and dims tags, description, use cases). "Custom model…" unfolds a small form for a
model models.json does not list: slug, provider, dimensions, model ref, a default checkbox and
one Register button. The old segmented Preset/Custom picker, Advanced Settings toggle, and the
List / Set Default / Drop buttons are gone; the row menu has the last two.

### Providers

One row for Llama XPC: status color, the service's own status line, how many models are
loaded, slots, Unload All and Refresh, and the last error in red under it when there is one.
Under it, one sub-row per model the service holds in memory (Rick's ask, 2026-09-25 15:17):
its name and alias, what it is for (default embedding model, facts model, answers requests that
name no model) and its own Unload button. Ping and
the health table are gone; Refresh does the same call. LM Studio gets a row only when a model
on the page uses it or a token is stored, with the token field inline.

### Testing an embedding

Folded under "Test an Embedding". Same function as before (model, optional dimensions, the
sentence, Embed, stats and the full untruncated vector), with the badges and the "(Full,
Non-Truncated)" labels dropped. "Test an Embedding…" on a row's menu opens it with that model
selected.

## What stayed the same

- The accessibility identifiers the UI test uses (`models.refresh`, `models.embedAll`) and the
  rule that Embed All is disabled with no registered models.
- Every operation goes through the same AppState calls (registerModel, setDefaultModel,
  dropModel, runBackfill, runEnrichFacts, setFactsModel, the download and Llama services).
- The Fact Prompts section and the two log tables.
- The Unload confirmation alert.

## Not done here

- The page is a plain stack; a sidebar-and-detail split (rows on the left, details on the
  right) would suit a corpus with many models, but nobody has more than three today.
- The Status page's Models card still reads "Models & Llama Ready"; its copy was left alone.
