---
layout: default
title: Middle-Layer SFT — LoRA Adapters Trained with MLX, Served by llama.cpp
description: Design for fine-tuning the middle layers of an open-weight model on the Garage corpus with MLX on the Mac, exported as a LoRA adapter GGUF that the app's llama.cpp engine loads beside the quantized base model.
---

# Middle-layer SFT: teaching the local model the corpus

> **Status.** Design only. Nothing in this document exists in the code yet: there is no training
> package, no adapter loading in `LlamaCppEngine`, no `train` section in the config. The pinned
> llama.cpp (`v0.4.0`, `ext/llama_cpp/llama_cpp.MODULE.bazel`) already carries everything the
> runtime side needs; the rest is laid out as milestones in §9.

Garage retrieves. Every answer the MCP tools give is grounded in chunks and facts pulled from
Postgres at question time, and the model behind `rag_ask` is whatever instruct model the user
picked, untouched. This document designs the one place where Garage would change the model
itself: a **supervised fine-tune (SFT) of the middle layers** of an open-weight model on the
owner's own corpus, so that the model

1. **knows the corpus's facts without retrieval** (closed-book recall of what the `facts` table
   holds), and
2. **writes in the owner's voice** (trained on `authored` documents and the owner's side of
   Messages threads).

Three choices frame everything below, and they were made deliberately:

- **The trainer is MLX** (`mlx-lm`) on the Mac. It is the fastest practical path on Apple
  silicon, it trains quantized bases (QLoRA), and it needs no PyTorch or CUDA.
- **The artifact is a LoRA adapter GGUF**, loaded next to the quantized base model with
  llama.cpp's adapter API, not a merged model. Adapters are small, swappable, several can coexist
  (one per corpus, one per month), and the base stays the catalog's quantization.
- **Retrieval stays primary.** The adapter complements RAG with recall and tone; it does not
  replace citations, and `rag_ask` keeps grounding its answers.

## 1. Goals and non-goals

**Goals**

- A dataset builder that turns the Garage corpus into SFT data: facts into question–answer and
  statement pairs with paraphrase augmentation, authored text and sent messages into voice data,
  plus the abstention and replay examples that keep the model honest and intact.
- A training recipe for MLX that trains **only a chosen window of transformer blocks** (and only
  chosen projections inside them), with the window a parameter, not a constant.
- An export step that produces an adapter GGUF the pinned llama.cpp loads, with a check that the
  adapter behaves the same under MLX and under llama.cpp.
- Runtime support in the app: `LlamaXPCService` loads adapters beside a model; the `rag_ask` and
  `rag_generate` MCP tools answer with the adapter on.
- An evaluation protocol, including the experiment that decides which layers to train.

**Non-goals**

- Cloud training of any kind. Training happens on the Mac that holds the corpus; the privacy
  guarantee (`docs/privacy.md`) is unchanged because nothing leaves.
- Full fine-tunes, merged models, or requantization. A merged model is a multi-gigabyte artifact
  per run and requantization adds noise; the adapter is the product.
- Mixture-of-experts bases (`gpt-oss-20b`, `qwen3-30b-a3b`). LoRA over expert tensors is possible
  in both toolchains but is the least exercised path in each; dense models first.
- llama.cpp's own trainer. The pin has `llama_opt_init`/`llama_opt_epoch` and
  `examples/training/finetune.cpp` (full-parameter training with a `param_filter` hook, CPU and
  Metal). It would remove the Python ML stack entirely and is worth revisiting once it supports
  LoRA targets; today it is a full fine-tune, so it is noted here and set aside.

## 2. Why the middle layers, and what "middle" means here

The literature (§11) gives three reasons to aim a knowledge fine-tune at the middle of the stack
rather than the top:

- **That is where factual recall lives.** Causal tracing in ROME and MEMIT locates the
  associations behind factual statements in the MLPs of the middle layers, and edits those MLPs
  to change what the model "knows". A fine-tune meant to add facts should put its capacity where
  the mechanism it is adding to sits.
- **The top layers are the most dispensable.** Gromov et al. remove up to half of the deepest
  layers of Llama-2 70B with little loss on question answering after a light LoRA heal, which says
  the late layers hold little that recall depends on; LISA's layer-importance sampling draws the
  same picture from gradients.
- **Restricting the parameters restricts the forgetting.** LoRA already forgets less than full
  fine-tuning for the same target loss (Biderman et al.); confining it to a window of blocks and
  leaving embeddings, the output head and the late layers untouched narrows what can drift.

Two more results shape the dataset rather than the layer choice. Knowledge only becomes
**extractable** when it is seen in many formulations: Allen-Zhu & Li show that a fact presented in
one form is memorised but cannot be answered to, while the same fact in paraphrases, permutations
and rewrites can; Ovadia et al. see the same effect from the retrieval side, where fine-tuning
without paraphrase augmentation lost to RAG. Jiang et al. find that showing question–answer
examples **before** the raw documents teaches the model how knowledge is later queried. And
Gekhman et al. show that fine-tuning on facts the model does not already know raises its
hallucination rate unless it also learns when to say it does not know; Berglund et al.'s reversal
curse means "A is B" must be trained in both directions.

**Operational definition.** For a model with `L` blocks the default window is the central half,
`[L/4, 3L/4)`: layers 8–23 of a 32-layer model, 9–26 of a 36-layer one. Within the window:

| Goal | Projections trained | Rationale |
|---|---|---|
| Knowledge | MLP `gate_proj`, `up_proj`, `down_proj` | the MLPs are the key–value memories ROME edits |
| Voice | attention `q_proj`, `k_proj`, `v_proj`, `o_proj` in the later half of the window | style is a matter of what the model attends to and reproduces, not of stored facts |
| Both | the union | one adapter, two example mixes |

The window and the projection set are **sweep parameters** (§8). The central half is the
hypothesis; the experiment picks the window the measurements favour.

## 3. Model selection

A base model has to pass through three toolchains unchanged: `mlx-lm` trains it,
`convert_lora_to_gguf.py` (llama.cpp's converter, which reuses `convert_hf_to_gguf`'s model
classes) maps the adapter onto GGUF tensor names, and the pinned llama.cpp runs it. The criteria:

1. **Dense decoder.** No MoE (see non-goals).
2. **Supported by all three tools** for the exact architecture, including its norm layout and
   any fused projections.
3. **bf16 safetensors on Hugging Face** under the catalog entry's `model_id`, and a GGUF quant of
   the same weights already in the catalog (`download_model_id`/`download_file`), so the adapter
   is trained against the weights it will be applied to.
4. **A licence that permits derived adapters** for personal use.
5. **Fits a Mac for training.** Rule of thumb, from parameter count `P` (billions): a 4-bit QLoRA
   base takes about `0.6·P` GB, bf16 about `2·P` GB, plus activations (a few GB at sequence 2048
   with gradient checkpointing, batch 1–2) and the optimizer state for the adapter, which is small.

| Model | Catalog slug | Blocks | Licence | QLoRA / bf16 fit | Verdict |
|---|---|---|---|---|---|
| Llama 3.1 8B Instruct | `llama-3.1-8b-instruct` | 32 | Llama 3.1 Community | 16 GB / 32 GB+ | **Reference model.** The most exercised LoRA path in all three tools; the only family `mlx_lm.fuse --export-gguf` also handles, which gives a second route for cross-checks. |
| Qwen3-4B-Instruct-2507 | `qwen3-4b-instruct-2507` | 36 | Apache-2.0 | 16 GB / 24 GB | **Development model.** Fast enough for layer sweeps; bf16 LoRA on a 24 GB Mac. |
| Qwen3-8B | (add if adopted) | 36 | Apache-2.0 | 16 GB / 32 GB+ | **Permissive 8B.** Hybrid thinking template: the dataset must carry the non-thinking form of the chat template so training and inference agree. |
| Llama 3.2 3B Instruct | `llama-3.2-3b-instruct` | 28 | Llama 3.2 Community | 8 GB / 16 GB | Fine for voice; capacity-limited for knowledge. |
| Gemma 3 4B / 12B | `gemma3-4b`, `gemma3-12b` | 34 / 48 | Gemma Terms | 16 / 24 GB and up | Multimodal checkpoints (text tower is what trains); large vocabulary; verify the converter's Gemma 3 adapter mapping before use. |
| Phi-4-mini | `phi-4-mini-instruct` | 32 | MIT | 8 GB / 16 GB | Fused `qkv_proj` and `gate_up_proj`: the converter splits them, and the layer-key generator must target the fused names. Verify. |
| Granite 4.1 3B / 8B | `granite-4.1-3b`, `granite-4.1-8b` | — | Apache-2.0 | — | Check `mlx-lm` architecture support first. |
| gpt-oss-20b, Qwen3-30B-A3B | `gpt-oss-20b`, `qwen3-30b-a3b-instruct-2507` | MoE | — | — | Avoid (non-goal). |
| DeepSeek-R1-Distill-Qwen-7B | `deepseek-r1-distill-qwen-7b` | 28 | MIT | — | Avoid: trained to emit reasoning traces, which the fact data does not contain. |
| Mistral Small 3.2 24B | `mistral-small-3.2-24b-instruct` | 40 | Apache-2.0 | 24 GB+ / 48 GB+ | Too large to iterate on; a possible final target later. |

Two notes. The model being trained is independent of `facts.model`: the dataset builder uses
whatever `LocalChatModel` (`enrich/generation.py`) is configured to write paraphrases, and that
can be a different, larger model than the one being tuned. And the catalog already stores both
identities each entry needs: `model_id` is the Hugging Face repository the bf16 weights come
from, `download_file` the GGUF the app runs; the bartowski and Unsloth quants in the catalog are
made from the same released weights, which is what lets an adapter trained on one apply to the
other.

## 4. Dataset construction

This is the Garage-specific part, and the part that decides whether the fine-tune works. A
future `garage_rag/train/dataset.py` (CLI `garage train export`, later also a gRPC op) reads the
corpus from Postgres and writes `mlx-lm`'s JSONL files (`train.jsonl`, `valid.jsonl`,
`test.jsonl`) into a run folder under the data directory, beside a `manifest.json` recording the
filters, the row counts, a hash over the source rows, and the model that generated paraphrases.
Everything it generates is produced by the local model through `LocalChatModel`; the builder
makes no network request of its own.

### 4.1 Knowledge set

Source: `facts` (`data/sql/006_facts.sql`, `013_fact_prompts.sql`), optionally filtered by
`prompt_name`, source and trust tier. Each fact is atomic and grounded in a span of
`documents.content` (`char_start`, `char_end`), which is exactly the unit the literature says to
augment. Per fact:

- **Questions.** `N` paraphrased questions (default 5) whose answer is the fact, written by the
  local model from the fact and a short window of its grounding span.
- **Restatements.** The fact rewritten in several forms (passive, with the entities reordered, as
  a one-line summary), each as the answer to a short "state what you know about <subject>" turn.
- **Reversals.** For a fact of the shape "A is/has/wrote B", the inverted question ("What is B
  of?" → A), so both directions are trained (Berglund et al.).
- **Grounded continuation.** The grounding span, so the raw wording is seen too: the user turn
  gives the document's title, date and the first sentence of the span and asks for the
  continuation, the assistant turn is the rest of the span.

**One format for every row.** Every example in every file is `chat`
(`{"messages": [system, user, assistant]}`), including the continuation and voice examples that
would more naturally be `completions` or `text`. `mlx-lm` picks one parser per file by inspecting
its first row (`create_dataset` in `mlx_lm/tuner/datasets.py`), so a mixed file would parse every
later row as the first row's format and fail, and `mask_prompt` is rejected for `text` datasets.
Chat rows carry the prompt-masking we want for all of them.

The manifest keeps the fact id, the document URI and the span for every generated example, so a
training example can always be traced to the text it came from.

### 4.2 Abstention set

Questions the corpus cannot answer, answered with a fixed refusal ("I don't have that in my
notes."). They are generated by asking the local model for plausible questions about entities the
corpus does not know, and they are what stops the tuned model from inventing facts in the corpus's
style (Gekhman et al.). Absence from `facts` is not enough evidence: fact extraction is optional
and never exhaustive, and an entity can be all over `documents` and `chunks` without a single fact
row, so a candidate screened against the table alone would teach the adapter to refuse things the
owner has written about. Each candidate is therefore checked with the same hybrid search
(`search/hybrid.py`) the MCP tools use, over chunks and facts together, with the entity's aliases
(the question's noun phrases and the model's own alternative spellings) as extra queries; a
candidate whose best hit scores above a threshold is dropped, and the manifest records the top
hits for the ones kept. Target share: about 10 % of the knowledge set.

### 4.3 Voice set

Two sources, both selected through the attribution tables rather than by path:

- **Authored documents.** `documents.trust_tier = 'authored'` joined to `document_authors` with
  `authors.is_self`, as `chat` rows whose user turn is the document title plus its first paragraph
  with a request to continue, and whose assistant turn is the continuation, trained with
  `--mask-prompt` so only the owner's text contributes to the loss.
- **Sent messages.** Messages threads (`ingest/conversations.py`) give one chunk per message with
  `chunks.direction` and `chunks.sender` (`014_chunk_direction.sql`). The preceding `received`
  turns become the user side and the owner's `sent` reply the assistant side of a `chat` example,
  under a fixed persona system prompt ("You are writing as <owner>…").

Communications are `corpus_class = 'communication'`, and the content rule in `docs/privacy.md`
says they never leave the machine. Training does not move them: MLX runs on the Mac that holds
the database. The builder still requires an explicit `--include-communications` flag, because the
resulting adapter is a derived artifact of them and has to be treated as such (§7).

### 4.4 Replay set

A fine-tune on a narrow corpus drifts on everything else. The usual remedy, mixing in a public
instruction dataset, would mean downloading one; Garage does not need to. The builder instead
**self-distils**: it asks the base model a few hundred generic prompts (coding, summarising,
everyday questions, with no corpus content) and records its own answers as `chat` examples. Training
on the base model's own outputs anchors it to its current behaviour at near-zero cost. Target
share: 20–30 % of the final mix.

### 4.5 Splits and phases

- **Split by document, before generating anything.** The builder first partitions documents into
  a training set and a small held-out set (seeded, by document id, so a re-run reproduces it), and
  only then generates examples. A held-out document contributes to **no** training subset: not its
  facts' questions or restatements, not its grounded continuations, not a voice example from its
  text, and a Messages thread is held out whole. Without that, a "held-out" fact would still be
  seen through its document's continuation or voice rows and the generalisation number would mean
  nothing.
- `valid.jsonl`: **held-out paraphrases of trained facts** (the extractability measure: the fact
  was trained, this wording was not), the **held-out documents' facts** as questions (a sanity
  check that should stay near the base model's score), and samples of the abstention and replay
  sets.
- **Curriculum as phases, not file order.** `mlx-lm` does not train in file order: `iterate_batches`
  (`mlx_lm/tuner/trainer.py`) sorts examples by length, cuts them into batches and permutes the
  batches every epoch, so nothing about a JSONL's ordering survives. The Jiang et al. ordering is
  implemented as **two sequential runs** instead: phase 1 trains on the question–answer,
  restatement and reversal rows (with the replay and abstention shares mixed in); phase 2 starts
  from phase 1's adapter (`resume_adapter_file`) and trains on the grounded continuations and
  voice rows, again with replay mixed in. The builder writes one `data/` folder per phase.

## 5. Training run (MLX)

### 5.1 Where it lives

`mlx-lm`, `transformers` and `huggingface_hub` all open their own network connections, and
`garage_rag/net/egress.py` is the one module allowed to do that (`tests/test_egress_block.py`
scans every import under `garage_rag/`). The trainer therefore lives **outside the package**, in
its own `uv` project at `tools/finetune/` with its own `pyproject.toml` and lockfile, and
`garage_rag` never imports it. The split is clean: the dataset builder (needs the database and the
local model, no new dependencies) is in `garage_rag/train/`; the trainer, the exporter and the
evaluation harness (need MLX and the Hugging Face stack) are in `tools/finetune/`.

Living outside the scan is not the same as being allowed to talk to the network. A process that
holds corpus-derived training data and imports a Hugging Face client has to be held to the same
rule as `garage_rag`, so `tools/finetune/` enforces it in two ways:

- **Weights are fetched in their own phase.** `finetune fetch-base <model_id>` is the only command
  that may reach the network, and it never opens the data folder: it downloads the bf16 weights
  (and runs `mlx_lm.convert -q` when a quantized copy is wanted) into
  `<data>/train/bases/<model_id>/`, records their revision and checksums, and exits.
- **Every other phase runs offline, and proves it.** `train`, `export` and `eval` take the base
  as a **local path** (never a repository id), set `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`
  before any import, and import `tools/finetune/netguard.py` first of all. The guard replaces
  `socket.socket`'s connect so that any destination that is not loopback raises, mirroring
  `egress.check_destination`'s loopback rule with no allowlist at all (the trainer has no reason to
  reach even the configured Ollama host), and it logs the attempt. A test starts each phase against
  a tiny model with a fake Hugging Face id and asserts the guard, not a download, is what fires.
  On a Mac the launcher additionally wraps the phase in `sandbox-exec` with a network-deny profile
  where available, as a second layer rather than the mechanism.

### 5.2 Selecting the layers with stock mlx-lm

`mlx-lm`'s `linear_to_lora_layers(model, num_layers, config)` wraps the **last** `num_layers`
blocks, which is the wrong end of the model for this work. But after that loop it also wraps
every module whose **full path** is listed in `lora_parameters.keys`, matched against
`model.named_modules()`. So a YAML with `num_layers: 0` and explicit full-path keys trains exactly
the chosen layers with the unmodified `mlx_lm.lora` command, and `load_adapters` reconstructs the
same layout from the saved `adapter_config.json`. No fork is needed.

`tools/finetune/make_config.py` writes that YAML. It loads the model with `mlx_lm.load`, walks
`named_modules()` to find the block list and the projection names for the architecture (never a
string template: Phi's `qkv_proj` and Qwen's `q_norm` differ from Llama), applies the window and
projection choice from §2, and emits:

```yaml
model: /…/GarageApp/train/bases/meta-llama--Llama-3.1-8B-Instruct   # a local path, never a repo id (§5.1)
train: true
fine_tune_type: lora
data: /…/GarageApp/train/runs/2026-10-04T12-00/phase1      # phase2 reuses this file with data: …/phase2
# resume_adapter_file: …/runs/2026-10-04T12-00/adapters/adapters.safetensors   # set for phase 2 (§4.5)
num_layers: 0                                  # nothing from the top of the stack
lora_parameters:
  rank: 16
  scale: 20.0                                  # see §6: alpha = scale * rank for llama.cpp
  dropout: 0.0
  keys:
    - model.layers.8.mlp.gate_proj
    - model.layers.8.mlp.up_proj
    - model.layers.8.mlp.down_proj
    # … through model.layers.23.mlp.down_proj
mask_prompt: true
grad_checkpoint: true
batch_size: 2
grad_accumulation_steps: 4
max_seq_length: 2048
learning_rate: 2.0e-5
lr_schedule: {name: cosine_decay, warmup: 50, arguments: [2.0e-5, 1500, 1.0e-6]}
iters: 1500
steps_per_eval: 100
save_every: 250
adapter_path: /…/GarageApp/train/runs/2026-10-04T12-00/adapters
seed: 0
```

### 5.3 Starting points

| Setting | Knowledge | Voice |
|---|---|---|
| Rank | 16–32 (facts need capacity) | 8 |
| Scale | 20 (mlx-lm default; rsLoRA-like at these ranks) | 20 |
| Learning rate | 1e-5 to 5e-5, cosine | 1e-5 |
| Epochs | 2–4 over the augmented set | 1–2 |
| Batch | 1–2 × 4 accumulation | same |
| Sequence | 2048 (1024 on a 16 GB Mac) | 2048 |
| Loss | completion only (`mask_prompt`) | completion only |

### 5.4 Base weights

`mlx-lm` loads the Hugging Face bf16 safetensors named by the catalog's `model_id` directly, or a
4-bit MLX quantization of them made with `mlx_lm.convert -q` when bf16 does not fit (QLoRA). An
adapter trained against the 4-bit MLX quant and applied to the catalog's Q4_K_M GGUF sees
slightly different base activations; this is ordinary QLoRA practice and §8 measures it rather
than assuming it away. Downloading the weights is the only network step in the whole pipeline,
and it is a download of public weights, not an upload of anything.

## 6. Adapter export to llama.cpp

### 6.1 What llama.cpp expects

The pinned llama.cpp loads an adapter with `llama_adapter_lora_init(model, path)` and applies a
set of them to a context with `llama_set_adapters_lora(ctx, adapters, n, scales)`. In the graph
each adapted weight becomes `y += s · B(A x)` with

```
s = adapter_scale · alpha / rank        (alpha from the GGUF key adapter.lora.alpha)
s = adapter_scale                        when alpha is 0
```

The loader pairs `<tensor>.lora_a` with `<tensor>.lora_b` and checks, against the base tensor,
that `a` has the base's input width, `b` the base's output width, and that `a`'s other dimension
equals `b`'s (the rank). In row-major terms that is the PEFT layout: `lora_A` of shape
`(rank, in)`, `lora_B` of shape `(out, rank)`.

### 6.2 What mlx-lm produces

`mlx-lm`'s `LoRALinear` computes `y + scale · ((x @ lora_a) @ lora_b)` with `lora_a` of shape
`(in, rank)` and `lora_b` of shape `(rank, out)`, saved to `adapters.safetensors` under keys like
`model.layers.12.mlp.down_proj.lora_a`, with `adapter_config.json` carrying the `lora_parameters`
above. `mlx_lm.fuse --export-gguf` is not the route: it merges the adapter and writes a full f16
model, and only for the Llama and Mistral families.

### 6.3 The conversion

`tools/finetune/export_adapter.py` turns the MLX adapter into a PEFT adapter and hands it to
llama.cpp's converter:

1. For each `<path>.lora_a` / `<path>.lora_b` pair: `lora_A.weight = lora_a.T`,
   `lora_B.weight = lora_b.T`, saved as `base_model.model.<path>.lora_A.weight` and
   `…lora_B.weight` in `adapter_model.safetensors`.
2. `adapter_config.json`: `r = rank`, **`lora_alpha = scale · rank`** (so llama.cpp's `alpha/rank`
   reproduces mlx-lm's `scale`), `target_modules` listing the projection names,
   `base_model_name_or_path` = the catalog `model_id`, `peft_type = "LORA"`.
3. `python convert_lora_to_gguf.py --base <dir with the base's config.json> --outtype f16
   <adapter dir>` from the pinned llama.cpp source tarball, fetched and verified with
   `tools/windows/fetch_ext.py`'s `pins()`/`download()` exactly as `tools/llama/known_answers.py`
   does, so the converter is the same release the app links.
4. Add Garage's own metadata keys to the GGUF: `garage.base_gguf_sha256` (the catalog entry's
   `sha256`), `garage.layers` (the window), `garage.targets`, `garage.dataset_sha256` (the
   manifest hash), `garage.trained_at`. The runtime loader checks the first (§7).

### 6.4 Equivalence check

Modelled on the known-answers harness (`tools/llama/known_answers.py`, `MIN_COSINE`): a fixed set
of prompts is decoded greedily twice, once under MLX with `load_adapters`, once under llama.cpp
with the adapter GGUF (through `LlamaXPCService`'s HTTP socket, or a `llama-cli` built from the
same tarball), and the harness compares the token sequences and the cosine of the first-token
logit vectors. Divergence beyond tolerance means a layout or scale mistake in the export, caught
before the adapter is ever offered to the app.

## 7. Runtime integration in Garage

Described here, built in M3–M4 (§9).

**Swift.** `LlamaCppEngine` (`macapp/Sources/LlamaEngine`) keeps, per resident model, a table of
loaded adapters keyed by name (`llama_adapter_lora_init` once per adapter, freed with the model).
Adapter **selection is part of the request, not of the model's state**: a completion, chat or
embedding request names its adapters (`lora: [{name, scale}]`, llama-server's request field), and
the engine calls `llama_set_adapters_lora` with exactly that set, inside the same `lock` that
serialises the decode that follows. llama.cpp only touches the context when the set differs from
the current one, so the call is free when consecutive requests agree, and two callers that
disagree (a `rag_ask` with the knowledge adapter and an `enrich-facts` run without it, on the same
base) can never run a decode under the other's adapters, because selection and decode are one
critical section. A request that names an adapter that is not loaded for that model gets a 400,
never a silent run on the base.

Two routes manage the table: `GET /lora-adapters` lists each model's loaded adapters, and
`POST /lora-adapters {model, adapters}` **reconciles** a resident model's table with the named set,
loading what is missing and dropping what is no longer wanted. That reconciliation is a separate,
explicit call on purpose: `LlamaCppEngine.ensureModel` and `LlamaModelLoader.ensureLoaded` both
return at once for an alias that is already resident, so adapters passed only as load options
would be ignored whenever the base was loaded first without them or the setting changed later.
`ensureModel` still accepts an initial adapter list for the cold-load case, and the loader
follows every `ensureModel` with a reconcile for the resident case.

`LlamaModelResolver` resolves adapter names from `<data>/adapters/<name>/adapter.gguf` beside
`models/` (`GarageAppGroup`), never from the model catalog: an adapter encodes the corpus and is
personal data, so it lives with `pgdata`, not with the shareable downloads. Before loading one,
the engine reads `garage.base_gguf_sha256` and refuses an adapter whose base differs from the
loaded model's file.

**Python.** Two settings, `inference.adapters` and `facts.adapters` (lists of adapter names,
declared in `SECTIONS` in `config/__init__.py`, documented, schema regenerated with
`garage config schema --publish`). `LlamaXPCClient._with_model_loaded` does two things with them:
after `ensureModel` it posts the reconcile (`/lora-adapters`) so the resident model has them
loaded, and it puts the same names in each request's `lora` field so the selection travels with
the inference. `rag_ask` and `rag_generate` thereby answer with the adapter on, `enrich-facts` can
run with one or without, and the two never interfere. The egress rules do not change: adapters
only ever go to the loopback `llama_xpc` provider, and the Ollama and LM Studio providers cannot
load them; the document says so rather than pretending they can.

**Ops and app.** `garage train export` lands first as an `ops/` function (the CLI command and a
future `TrainExport` RPC are both thin presenters over it, with `_stream_events`-style progress).
`garage train import-adapter <gguf>` copies a trained adapter into the adapters folder and reads
its metadata. The Models page gains an Adapters section listing them with base model, layers and
training date, and the app marks an adapter **stale** when the current `facts` state no longer
matches its `garage.dataset_sha256`. Reset Database deletes `pgdata` and leaves adapters alone,
but they will show as stale afterwards until the corpus is re-ingested and a new one trained.

## 8. Evaluation and the layer-window experiment

Every run folder gets a `results.json`; the harness in `tools/finetune/eval.py` computes:

| Metric | Measures | Data |
|---|---|---|
| Closed-book accuracy on held-out paraphrases | extractability of trained facts | `valid.jsonl` knowledge rows, exact and contains matching against the fact |
| Accuracy on held-out documents' facts | generalisation (expected near base) | facts of the documents held out in §4.5, which no training row saw |
| Abstention rate | honesty on unanswerable questions | abstention rows, and a mirror set of answerable ones to catch over-refusal |
| Voice perplexity | fit to the owner's style | held-out `authored` text; plus a small blind sample rated by the owner |
| Forgetting | drift on general ability | log-likelihood of the replay set's base-model answers, tuned vs base |
| MLX vs llama.cpp agreement | export correctness | §6.4 |

**The layer experiment.** On the reference model, with the knowledge dataset fixed, train one
adapter per configuration and compare on the table above:

- Windows: `[0, L/4)`, `[L/4, L/2)`, `[L/2, 3L/4)`, `[3L/4, L)`, the central half
  `[L/4, 3L/4)`, and mlx-lm's default last-16 as the control.
- Projections: MLP only, attention only, both.
- Rank: 8, 16, 32.

The hypotheses to test: the central half beats the last-16 control on closed-book accuracy at
equal forgetting; MLP-only is enough for knowledge; attention in the later half of the window is
what moves voice perplexity. The document records the protocol, not results; the results go in
the run folders and a short note here once they exist.

## 9. Milestones

| | Milestone | Deliverable | Tests |
|---|---|---|---|
| M0 | This document | `docs/plans/sft-middle-layers.md` | — |
| M1 | Dataset exporter | `garage_rag/train/dataset.py`, `garage train export`: document-level split, chat-only rows, abstention candidates screened by hybrid search, one `data/` folder per phase, manifest, generation through `LocalChatModel` | unit tests on mocks for every example type; a test that no held-out document reaches any training row; every row parses as `chat`; `test_egress_block.py` unchanged and green |
| M2 | Trainer, export, equivalence | `tools/finetune/` (`fetch-base`, `netguard.py`, `make_config.py`, two-phase `train`, `export_adapter.py`, `eval.py`), run by hand on the development model | the guard test (offline phases never open a non-loopback socket); layout and `alpha = scale·rank` round-trip test on a tiny synthetic adapter; equivalence check |
| M3 | Runtime adapters | `LlamaCppEngine` per-model adapter table, per-request selection under the engine lock, `/lora-adapters` list and reconcile routes, adapter folder, base-hash check | Swift unit tests for request parsing, `LlamaModelResolver` and the reconcile; a `MockLlamaServerEngine` test that interleaved requests with different adapter sets each decode under their own |
| M4 | App and ops surface | settings, `import-adapter`, Adapters section, staleness | config schema test, gRPC serialization tests |
| M5 | Layer-window study | results on the reference model, note added to §8 | — |

## 10. Risks and open questions

- **Quantization mismatch.** An adapter trained on a 4-bit MLX base and applied to a Q4_K_M GGUF
  may lose some accuracy; §8 measures it, and training in bf16 on a larger Mac is the remedy.
- **Converter coverage.** `convert_lora_to_gguf.py` splits fused projections (Phi) and follows
  `convert_hf_to_gguf`'s tensor mapping, but each architecture's adapter path should be exercised
  once on a tiny run before it is relied on; Qwen3's attention norms and Gemma 3's tied embeddings
  are the first things to check.
- **Key paths differ by architecture.** `make_config.py` must derive module paths from the loaded
  model, never from a template.
- **Memory on 16 GB Macs.** QLoRA, gradient checkpointing, sequence 1024 and batch 1 should fit
  the 4B development model; the 8B reference model wants 24 GB or more.
- **Staleness.** The corpus grows daily; the adapter does not. Retraining cadence (monthly? on
  demand?) and the cost of each run decide how much of the knowledge goal is realistic against RAG,
  which is always current.
- **Licences.** A derived adapter of a Llama model carries the Llama licence's attribution terms;
  Gemma's terms apply to Gemma derivatives. Apache-2.0 bases (Qwen3) avoid the question.
- **Received content.** Whether anything from `trust_tier = 'received'` should ever enter the
  dataset. The default answer is no: it is other people's words and, in communications, the
  prompt-injection surface the trust tiers exist to mark. The flag in §4.3 admits sent messages,
  not received ones, as training targets; received turns appear only as context.

## 11. References

Papers, cited by author and year above; arXiv identifiers as listed, to be confirmed against the
PDFs when they are filed.

| Paper | arXiv |
|---|---|
| Hu et al. 2021 — LoRA: Low-Rank Adaptation of Large Language Models | 2106.09685 |
| Dettmers et al. 2023 — QLoRA: Efficient Finetuning of Quantized LLMs | 2305.14314 |
| Meng et al. 2022 — Locating and Editing Factual Associations in GPT (ROME) | 2202.05262 |
| Meng et al. 2022 — Mass-Editing Memory in a Transformer (MEMIT) | 2210.07229 |
| Allen-Zhu & Li 2023 — Physics of Language Models, Part 3.1: Knowledge Storage and Extraction | 2309.14316 |
| Ovadia et al. 2023 — Fine-Tuning or Retrieval? Comparing Knowledge Injection in LLMs | 2312.05934 |
| Jiang et al. 2024 — Instruction-tuned Language Models are Better Knowledge Learners | 2402.12847 |
| Gekhman et al. 2024 — Does Fine-Tuning LLMs on New Knowledge Encourage Hallucinations? | 2405.05904 |
| Biderman et al. 2024 — LoRA Learns Less and Forgets Less | 2405.09673 |
| Gromov et al. 2024 — The Unreasonable Ineffectiveness of the Deeper Layers | 2403.17887 |
| Berglund et al. 2023 — The Reversal Curse: LLMs trained on "A is B" fail to learn "B is A" | 2309.12288 |
| Kalajdzievski 2023 — A Rank Stabilization Scaling Factor for Fine-Tuning with LoRA (rsLoRA) | 2312.03732 |
| Pan et al. 2024 — LISA: Layerwise Importance Sampling for Memory-Efficient LLM Fine-Tuning | 2403.17919 |

Tooling consulted at the versions named: llama.cpp `v0.4.0` (`include/llama.h` adapter and
training APIs, `src/llama-adapter.{h,cpp}` for the scale rule and shape checks,
`convert_lora_to_gguf.py`, `examples/training/finetune.cpp`); `mlx-lm` `main` as of October 2026
(`mlx_lm/tuner/lora.py`, `mlx_lm/tuner/utils.py`, `mlx_lm/lora.py`, `LORA.md`).
