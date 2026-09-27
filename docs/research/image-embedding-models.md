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

## How it fits Garage

- `embedding_models.modality` (`014_model_modality.sql`) separates text and image models; a picture
  gets one `image` chunk whose text is its title or caption and whose vector comes from the file.
- The `image_xpc` provider is local by construction: no HTTP, an NSXPC bridge from the Python in
  each helper to `GarageImageEmbedXPCService` through the endpoint the app hands over, the same way
  `llama_xpc` models are loaded on demand.
- Search embeds the query through the text tower under an image model, so hybrid search over an
  image model returns pictures; a text model never sees image chunks.
