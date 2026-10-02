# Image embedding models for Garage

*September 2026. The survey behind the `image_embedding` section of `docs/.data/models.json` and
`GarageImageEmbedXPCService`.*

## What Garage needs

A model that maps a picture and a short text query into one vector space, so a search phrase ranks
photos, screenshots and diagrams beside text chunks in the same Reciprocal Rank Fusion. It has to
run on this machine (the privacy guarantee), on Apple Silicon, inside a sandboxed XPC service with
no network, and ship under a licence that allows redistribution in an app. That rules out anything
served only by a cloud API and anything non-commercial.

The runtime question decides more than the leaderboard: llama.cpp has no image *retrieval*
embedding path (its CLIP/SigLIP encoders exist only as the vision front end of chat models;
[ggml-org/llama.cpp#17635](https://github.com/ggml-org/llama.cpp/issues/17635) tracks standalone
image embeddings and is open), so the built-in engine cannot serve one. Core ML can, on the Neural
Engine, and a CLIP-style model is two straightforward towers, which is why the helper is Core ML.

## Candidates

| Model | Params | ImageNet zero-shot | Retrieval (Flickr30k / COCO) | Dims | Licence | Apple Silicon path |
|---|---|---|---|---|---|---|
| **SigLIP 2 Base patch16 256** (Google, Feb 2025) | 375 M | 78.2 % (76.8 % measured on the Core ML fp16 build) | strong; SigLIP 2 base is above CLIP ViT-L/14 on both | 768 | Apache 2.0 | Core ML fp16 conversion published (`FluidInference/siglip2-base-patch16-256-coreml`); 5 ms per image on an M5 Pro ANE |
| SigLIP 2 So400m patch14 384 | 1.1 B | 83.1 % | best of the family | 1152 | Apache 2.0 | needs a conversion; ~2 GB fp16 |
| MobileCLIP2 S2 / B / L-14 (Apple, Aug 2025) | 100 M–500 M | 77.2 % (S2), 81.9 % (L/14) | 74.8 (S2) | 512 | Apple ML Research Model License, non-commercial research only | Core ML by design |
| MobileCLIP (v1) S2 (Apple, 2024) | 100 M | 74.4 % | 72 | 512 | Apple sample-code licence (`apple-ascl`), redistribution allowed | Core ML packages published (`apple/coreml-mobileclip`) |
| nomic-embed-vision v1.5 (Nomic, 2024) | 93 M | 71.0 % | shares the space of `nomic-embed-text-v1.5`, already in the catalog | 768 | Apache 2.0 | ONNX only; conversion needed |
| jina-clip-v2 / jina-embeddings-v4 | 865 M / 3.8 B | 78 % (v2) | best multilingual retrieval | 1024 / 2048 | CC BY-NC 4.0 | ONNX only, and non-commercial |
| Qwen3-VL-Embedding 2B / 8B (Alibaba, 2026) | 2 B / 8 B | n/a | state of the art on MMEB (multimodal), documents as images | 2048 / 4096 | Apache 2.0 | llama.cpp support experimental and unmerged; too heavy for Core ML today |
| Perception Encoder (Meta, 2025) | 300 M–2 B | 83–86 % | very strong | 1024+ | Apache 2.0 | needs a conversion |
| OpenAI CLIP ViT-L/14 | 428 M | 75.5 % | baseline | 768 | MIT | Core ML conversions exist; superseded |

Figures are the models' own reports and the Core ML repository's measurements; the retrieval
column is text-to-image recall@1 where published.

## Choice: SigLIP 2 Base patch16 256

It is the best model that meets every constraint at once:

- **Licence**: Apache 2.0, so the app may download and run it, and the catalog may point at it.
- **Runtime**: a Core ML fp16 conversion already exists, with both towers as separate packages
  (image 176 MB, text 539 MB on disk) and the tokenizer beside them, so no conversion pipeline is
  needed for the first release. The image tower runs on the Neural Engine in about 5 ms.
- **Quality**: within a few points of models three times its size, and a clear step over
  MobileCLIP v1 and nomic-embed-vision. Its text tower is multilingual (trained on WebLI in many
  languages), which matters for a personal corpus.
- **Contract**: inputs `pixel_values` float32 `[1, 3, 256, 256]` (bilinear resize to 256×256 with
  no crop, `(x − 0.5) / 0.5` per channel) and `input_ids` int32 `[1, 64]` (lowercased text through
  the Gemma SentencePiece-BPE tokenizer in `tokenizer.json`, `<eos>` appended, padded with `<pad>`
  = 0); outputs `image_embeds` / `text_embeds`, 768 wide, L2-normalized. `logit_scale` 112.9 and
  `logit_bias` −16.77 are for classification and unused in retrieval.

Every file is pinned by SHA-256 in the catalog (`download_files`) except the two `Manifest.json`
files, which are small and whose formatting the conversion does not fix.

## Runner-up and later candidates

- **MobileCLIP2** would be the pick on speed and size, and it is Apple's own Core ML format, but
  the licence forbids anything beyond research. If Apple relicenses it (as it did MobileCLIP v1),
  it drops in: same two-tower shape, 512 dims, its own CLIP BPE tokenizer with 77 tokens.
- **MobileCLIP v1 S2** is the fallback if the SigLIP 2 conversion ever disappears from Hugging
  Face: published by Apple as Core ML, permissive licence, lower quality.
- **SigLIP 2 So400m** and **Perception Encoder** are the upgrade path once a conversion is
  produced (a `coremltools` script over the Hugging Face checkpoints; a few hours of work, then
  a ~2 GB download). The catalog fields (`image_size`, `text_length`, `image_mean`, `image_std`,
  `text_lowercase`) are enough to describe either.
- **Qwen3-VL-Embedding** is the state of the art for documents-as-images (a screenshot of a page
  embedded whole, no OCR), which is the natural next step for PDFs and slides. It needs llama.cpp
  support to land, or a Core ML conversion of a 2 B decoder, neither of which is ready.

## Survey of published Core ML conversions (late September 2026)

A second pass looked for more catalog entries. It covered every Hugging Face repository with a Core ML
build of an image-text model (`siglip`, `siglip2`, `clip`, `mobileclip`, `uform`, Perception Encoder,
nomic-embed-vision, and the `coreml` library filter under the zero-shot and feature-extraction pipeline tags).

The bar is the engine as it stands (`macapp/Sources/ImageEmbedEngine`). A conversion passes only if it
meets all of these:

- Both towers are published as `.mlpackage` folders, since the downloader fetches files one by one and
  does not unzip.
- Each tower declares exactly one input and one output. The engine takes `.first` of Core ML's
  unordered name-to-description dictionaries, so a second input or output is nondeterministic, not
  merely unsupported.
- The image input is a `[1, 3, N, N]` array or an image feature.
- The text input is a fixed `[1, L]` array of token ids.
- The same repository ships a `tokenizer.json` that `BPETokenizer` encodes correctly. That tokenizer
  is SentencePiece-style BPE (the Gemma vocabulary): no pre-tokenizer it needs to honour, spaces
  replaced by `▁`, byte fallback, and `<eos>` appended with no BOS.
- The licence is Apache 2.0, MIT or `apple-ascl`.

Where a package was published unzipped, its I/O contract below was read from its own `model.mlmodel`
spec with `coremltools` 9.0. Otherwise it comes from the repository's `metadata.json`, file listing or
card, and the table says when something was not inspected.

### Added: SigLIP 2 Base patch16 224, CamStack build (`siglip2-base-224`)

`camstack/camstack-models`, folder `clip/siglip2/`, is a conversion of `google/siglip2-base-patch16-224`
at revision `75de2d55` (the upstream `main` today), made by the CamStack project with
`scripts/build-siglip2-model.py`.

- **Licence.** The folder's card is Apache 2.0 and lists the modifications, as Apache §4(b) requires.
  The repository as a whole is a mirror that also holds AGPL (Ultralytics) and non-commercial
  (InsightFace, MobileCLIP) folders under their own licences. The catalog references only the
  `clip/siglip2/` files, and the SHA-256 pins bind it to exactly those.
- **Contract.**
  - Vision (`camstack-siglip2-b16-224-vision.mlpackage`, 185 MB fp16) takes an image feature
    `image`, 224×224 RGB. The graph scales it by 1/255 and applies `2x − 1` (= `(x − 0.5) / 0.5`)
    itself, so the engine passes the `CGImage` through Core ML's scale-fill and its own
    mean/std are unused. It outputs `embedding` fp16 `[1, 768]`, not normalized; the engine
    normalizes it.
  - Text (`camstack-siglip2-b16-224-text.mlpackage`, 565 MB fp16) takes `input_ids` int32
    `[1, 64]` and outputs `embedding` fp16 `[1, 768]`.
- **Tokenizer.** `clip/siglip2/onnx/camstack-siglip2-b16-224-tokenizer.json` has the same vocabulary
  and merges as the upstream Gemma tokenizer (and the one the 256 px entry downloads), with a
  `Lowercase` normalizer prepended. Its `Split(" ")` pre-tokenizer runs after spaces have become `▁`,
  so it never fires, and the engine's lack of pre-tokenizer support does not change the ids.
- **Why add it.** It is a second, independent conversion with a smaller input (224 px: 196 patches
  against 256 at 256 px), from a project that verifies cross-format cosine and tokenizer
  ids against the reference. If the FluidInference repository ever disappears, this one keeps
  SigLIP 2 available. It is not a quality upgrade: the 224 px checkpoint is the same model trained at a lower
  resolution and, like every SigLIP resolution sweep, scores a little below it. The two checkpoints differ, so their vectors do not share a space. Each has its own model table.
- **Verified on this Mac (Apple silicon, coremltools 9.0).**
  - Every downloaded file's SHA-256 matches the pinned `lfs.oid`.
  - The Core ML compute plan puts 302 of 304 vision ops and 278 of 281 text ops on the Neural
    Engine. The image tower takes 4.2 ms per image on `cpuAndNeuralEngine` and 8.3 ms on
    `cpuAndGPU`, and the two agree to cosine 0.9999.
  - Retrieval test: six system pictures (zebra, parrot, penguin, owl, cactus, Earth) against six
    captions, tokenized the engine's way (lowercased, `<eos>`, `<pad>` = 0 to 64). Every caption
    ranked its own picture first.
- **Confidence: high** for the model and its contract. The residual risk is the repository: a
  mirror that moves (its last push was 2026-09-27), so a re-push breaks the pinned download
  rather than silently changing the model.

### Rejected, and the engine change each would need

| Repository | Model | Licence | Why it does not run today | Engine change that would unlock it |
|---|---|---|---|---|
| `palmier-io/siglip2-base-coreml` (byte-identical copies at `asamkhya`, `kanevry`, `kuluruvineeth`, `karthikramesh`, `pilotcut`, `artin666`; a rebuild at `karaiman`) | SigLIP 2 Base 256; the archives (image 92 MB, text 259 MB) are about half the fp16 size, so the build is likely quantized (not inspected) | Apache 2.0 | Towers and tokenizer ship only as `.zip` archives | Download-then-extract: a `download_files` entry flagged as an archive, verified by SHA-256 before it is unpacked into `models/<slug>/`. This is the most attractive unlock: about 350 MB instead of 750 MB. A quantized build gives its own vectors, so it would be a separate catalog entry. |
| `nodevorg/siglip2-base-patch16-256-coreml` | SigLIP 2 Base 256, fp16, plus an int8-embedding text tower | Apache 2.0 | Zipped packages | Same archive support |
| `zidage/siglip2-base-coreml-macos` | the same (likely quantized) build, compiled | no licence tag | Zipped `.mlmodelc`, and no licence stated | Archive support; still blocked on licence |
| `nufrnd/lvc-siglip2-base-coreml` | SigLIP 2 Base 256 (the same weights as FluidInference, byte for byte) | Apache 2.0 | Tokenizer is a custom `tokenizer-vocab.json` + `tokenizer-merges.bin`, not a `tokenizer.json` | A tokenizer file fetched from a second repository (`download_files` entries naming their own repo), or a loader for that format. Low value, since it duplicates the existing entry. |
| `FinDIT-Studio/siglip2-naflex-coreml` | SigLIP 2 Base NaFlex (512 patches) | Apache 2.0 | The vision tower takes three inputs (`pixel_values` as `[1, 512, 768]` patches, host-computed `position_embeddings`, `attention_mask`); published as `.mlmodelc` | NaFlex preprocessing on the host: aspect-preserving resize to a patch budget, patchify, bilinear resize of the 16×16 position table, the mask. Also named-input binding (below). It would suit documents and screenshots, whose aspect ratio a square resize distorts. |
| `batmac/ViT-B-16-SigLIP2-Image-CoreML`, `antonlnz/siglip2-so400m-image-coreml`, `metaclass/siglip-so400m-patch14-384-coreml` | SigLIP 2 B/16 224, SigLIP 2 So400m 384, SigLIP So400m 384 | Apache 2.0 | Image tower only (metaclass also zipped); no text tower, so no text-to-image search | None in the engine: someone has to convert the text tower. An image-only mode (`image_to_image` alone) is possible but gives up the main use. |
| `SashimiSaketoro/PE-Core-ANE` | Meta Perception Encoder Core T/S/B/L/G, ANE-tuned | MIT (repo); upstream PE is Apache 2.0 | Image towers only | A text tower conversion, then a CLIP BPE tokenizer (PE's text side uses OpenCLIP's) |
| `apple/coreml-mobileclip` | MobileCLIP v1 S0/S1/S2/B/B-LT | `apple-ascl` (weights under `LICENSE_weights_data`) | Text tower takes 77 CLIP BPE tokens; the repository has no tokenizer file | A CLIP byte-level BPE tokenizer: GPT-2 byte-to-unicode mapping, the CLIP regex pre-tokenizer, `</w>` word ends, `<|startoftext|>` before and `<|endoftext|>` after, zero padding to 77. Also a tokenizer from another repository (`openai/clip-vit-base-patch32`'s `tokenizer.json`, MIT). With both, this is the smallest and fastest permissive option (S0 image tower 23 MB). |
| `damian0815/CLIP-ViT-H-14-laion2B-s32B-b79K_CoreML`, `InspiratioNULL/CLIP-VIT-B-32-DataComp.XL-CoreML`, `yurijmikhalevich/rclip-models` | OpenCLIP ViT-H/14, ViT-B/32 | MIT | CLIP BPE; rclip ships its text tower as ONNX only | CLIP BPE tokenizer (as above) |
| `unum-cloud/uform3-image-text-english-*`, `…-multilingual-base` | UForm 3 | Apache 2.0 | Text tower takes `input_ids` and `attention_mask`; both towers output `features` and `embeddings`; `input_ids` is float32 in the non-`_neural` build; tokenizers are BERT WordPiece (English) and XLM-R Unigram (multilingual) | Named-input and named-output selection from the catalog (`image_input`, `text_input`, `text_mask_input`, `image_output`, `text_output`), an attention mask, float token ids, and WordPiece and Unigram tokenizers. The multilingual build has 256-dim embeddings and is the only small multilingual alternative. |
| `JacobNewmes/coreml-medsiglip-448` | MedSigLIP 448 | tagged Apache 2.0, but upstream `google/medsiglip-448` is gated under the Health AI Developer Foundations terms | Licence; text tower also takes `attention_mask` | Not a licence we can accept |
| `mlboydaisuke/SigLIP-base-patch16-224-CoreML`, `h9899/siglip-base-patch16-224-coreml`, `ronaldeddings/runback-siglip-coreml` | SigLIP (v1) B/16 224, So400m 384 | Apache 2.0 | SigLIP v1's tokenizer is SentencePiece **Unigram** (T5 style, with punctuation-stripping normalizers); mlboydaisuke ships only a vocabulary and its text input is flexible (`1…64`, default 4); h9899's text tower is loose `.mlmodelc` parts | A Unigram tokenizer (Viterbi over piece scores) and its `Precompiled` normalizer, plus reading the upper bound of a flexible text shape, since the engine reads the default shape today. SigLIP 2 supersedes all of these. |
| MobileCLIP2 (`apple/MobileCLIP2-*`), jina-clip-v2, jina-embeddings-v4 | — | Apple ML Research licence, CC BY-NC 4.0 | Non-commercial | None; licence |
| nomic-embed-vision v1.5, Qwen3-VL-Embedding | — | Apache 2.0 | No Core ML conversion published | A conversion; Qwen3-VL-Embedding is a 2 B decoder, not two towers |

### Engine work, in order of what it unlocks

1. **Archive downloads** (zip, verified before extraction). This unlocks the likely-quantized SigLIP 2
   Base 256 build, about half the download of the featured model, from several independent re-uploads of
   one conversion.
2. **Named I/O and an attention mask.** Optional catalog fields naming each tower's input and
   output features, and an optional mask input filled with 1s for tokens and 0s for padding. This
   makes multi-output packages deterministic and opens UForm 3 and MedSigLIP-shaped conversions.
3. **CLIP byte-level BPE, and a tokenizer from another repository.** This unlocks MobileCLIP v1
   (`apple-ascl`) and every OpenCLIP conversion, and MobileCLIP2 if Apple ever relicenses it.
4. **Unigram and WordPiece tokenizers.** This unlocks SigLIP v1 and UForm.
5. **NaFlex preprocessing.** This is the document-page path: aspect-preserving SigLIP 2, with no
   square squash.

## How it fits Garage

- `embedding_models.modality` (`014_model_modality.sql`) separates text and image models; a picture
  gets one `image` chunk whose text is its title or caption and whose vector comes from the file.
- The `image_xpc` provider is local by construction: no HTTP, an NSXPC bridge from the Python in
  each helper to `GarageImageEmbedXPCService` through the endpoint the app hands over, the same way
  `llama_xpc` models are loaded on demand.
- Search embeds the query through the text tower under an image model, so hybrid search over an
  image model returns pictures; a text model never sees image chunks.
