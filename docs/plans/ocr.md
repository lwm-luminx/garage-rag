---
layout: default
title: OCR for the Rust Ingester
description: Which engine reads text from pictures once the image reader leaves Python. Apple Vision in-process on the Mac, Tesseract linked statically for the Windows CLI, and a vision model over XPC as an opt-in later, all behind one engine trait in rust/garage-ocr.
date: 2026-11-03
status: Proposed (prototype in rust/garage-ocr)
status_kind: proposed
---

# OCR for the Rust ingester

The image reader (`garage_rag/extract/image.py`) is one of the last readers still in Python. It
reads text with Tesseract 5 and the `tessdata_fast` English model, in-process through
`_garage_tesseract` (`//ext/tesseract` and `//ext/leptonica`, linked statically into the app's
Python). Porting it to Rust is the chance to ask whether Tesseract should stay the engine.

This plan compares the candidates, recommends one per platform, and describes the prototype in
`rust/garage-ocr`, whose engine trait keeps the choice swappable.

## What the reader needs

- **Local only.** No picture or its text leaves the machine (`docs/privacy.md`). Every option below
  runs on the device.
- **In-process, linked at build time.** We prefer static linking to `dlopen`, and in-process libraries to
  spawning a tool.
- **Screenshots first.** Most pictures worth indexing are screenshots (light and dark, dense UI),
  phone photos of documents, and scans. Clean scans are the easy case.
- **Platforms.** Apple silicon Macs are the product. The Windows CLI (#227) needs an engine too, and
  CI runs on Linux.
- **Deterministic enough.** The text decides `content_sha256`, so an engine whose output changes from
  run to run re-chunks documents for nothing. A change of engine or model must bump the reader's
  `extractor_version`, which re-reads every picture once.

## The candidates

| | Tesseract 5 (ours, static) | Apple Vision | ocrs / RTen | PaddleOCR (PP-OCRv5) via ONNX | Vision-language model over XPC |
| --- | --- | --- | --- | --- | --- |
| Screenshots, photos | Weak: low contrast, dark mode and dense UI lose words | Strong | Good on screenshots | Strong | Strongest, including tables and handwriting |
| Clean scans | Good | Strong | Fair | Strong | Strong |
| Languages | 100+, one data file each (we ship `eng`) | About 30 across Latin, Cyrillic, CJK, Thai, Vietnamese and Arabic, all built in | Latin script only ("early preview") | 80+, through several recognizer models | Depends on the model |
| Speed on Apple silicon | CPU only | Neural Engine | CPU (SIMD) | CPU, or CoreML after conversion | Seconds per picture on the GPU |
| Linking | Static, already built by `//ext` | System framework (like Foundation): nothing bundled, nothing loaded by name | Pure Rust, static | Needs ONNX Runtime, a large C++ library that `ort` normally downloads prebuilt | Already in LlamaXPCService (llama.cpp, static) |
| Bundle cost | ~6 MB of libraries plus 4 MB per language | None | ~12 MB of models | ~10–20 MB of models plus the runtime | Hundreds of MB to a few GB per model |
| Windows | Yes (CMake and MSVC, like `windows.yaml`'s other builds) | No | Yes | Yes | Not as built |
| License | Apache-2.0 | System | MIT or Apache-2.0 | Apache-2.0 (models and runtime) | Varies by model |
| Rust binding | Our own, 15 functions over `capi.h` | `objc2-vision` | `ocrs` crate | `ort` (`oar-ocr`, `paddle-ocr-rs` build on it) | The host's NSXPC bridge |

### Tesseract bindings

The published crates do not fit the build:

- `tesseract`, `tesseract-sys` and `leptess` link the system library through pkg-config or vcpkg,
  which means a dynamic `libtesseract` on the Mac and on Windows.
- `tesseract-rs` and `kreuzberg-tesseract` build Tesseract from source in `build.rs` and download
  it there, which Bazel's hermetic builds and the Mac build host do not allow.

We already build Tesseract and Leptonica statically, without codecs, for `_garage_tesseract`. A
hand-written binding over the fifteen `capi.h` functions that reader uses, linked against those
`//ext` targets, is smaller than any of the crates and adds no build-time downloads. The prototype
does this. Pixels are decoded by the `image` crate, since our Leptonica has no codecs.

### Apple Vision

`VNRecognizeTextRequest` at the accurate level is a neural recognizer with language correction. It
reads exactly the pictures Tesseract struggles with, it runs on the Neural Engine, and it decodes the
file itself through ImageIO, so HEIC needs no decoder of ours (today `extract/imageio.py` does this
for Python).

It is a system framework, linked at build time like Foundation. It works in a sandboxed XPC
service with no extra entitlement, and it makes no network requests.

There are two trade-offs:

- Its output can change with a macOS update within the same request revision. The reader's
  `extractor_version` records the revision, not the OS build, so an OS update does not re-read the
  corpus. Pictures read after an update may differ slightly from those read before it.
- macOS 26 adds `RecognizeDocumentsRequest`, which also returns paragraphs, lists and tables. It is
  Swift-only, so Rust cannot call it directly. It could reach the reader later as a host engine (see
  below), through the Swift host.

### ocrs

`ocrs` is pure Rust and statically linked, with models trained for RTen. It is the most attractive
build story here. Its README still calls it an early preview and it reads only Latin script. Revisit
it when it supports more languages.

### PaddleOCR through ONNX

PP-OCRv5 is the strongest open model family and the most multilingual. The cost is the runtime:
ONNX Runtime is a large C++ library, and `ort` expects to download a prebuilt dynamic build. A
static, Bazel-built ONNX Runtime is a project of its own.

Two cheaper routes are worth trying if Vision falls short on some script:

- converting the models to CoreML and running them in GarageImageEmbedXPCService beside the CLIP
  models;
- running them under RTen or tract, which we have not verified.

### A vision-language model over XPC

LlamaXPCService already hosts llama.cpp, statically linked. llama.cpp's multimodal support reads
several small OCR-tuned vision-language models. These give the best results on tables, forms and
handwriting, and can answer in Markdown.

The drawbacks:

- They take seconds per picture.
- They hold a large model in memory beside the embedding model.
- They can write text that is not in the picture. In an index that is worse than missing a word.

That makes such a model a second pass, not the default. It would run on the pictures the fast engine
reads poorly, when the user turns it on. The engine trait's `HostEngine` is the seam for it: the
host's closure sends the bytes over NSXPC and returns the spans.

## Recommendation

1. **On the Mac, use Apple Vision (accurate, language detection on) as the image reader's engine** in
   the Rust ingester. Once the Python reader retires, Tesseract, Leptonica and `tessdata` leave the
   app. This is a change to the product's output, so it is Rick's call, and it re-reads and re-embeds
   every picture once (a new `extractor` and `extractor_version`).
2. **On Windows and Linux, use Tesseract, linked statically through `garage-ocr`'s own binding.** The
   Windows build adds Tesseract and Leptonica to `tools/windows/fetch_ext.py`'s MSVC builds. Windows'
   built-in `Windows.Media.Ocr` (WinRT, in-process, using the installed language packs) is the
   Windows counterpart of Vision. It is worth a measurement once the Windows CLI ingests pictures.
3. **Add a vision-language model only as an opt-in second pass**, through a host engine over XPC,
   after measuring it on real pictures.
4. **Leave ocrs and PaddleOCR for later.** Revisit ocrs when it reads more than Latin script, and
   PaddleOCR through CoreML if Vision misses a script users need.

## The prototype: `rust/garage-ocr`

- `OcrEngine` is the trait: `name`, `revision` (for `extractor_version`) and `recognize(bytes)`,
  returning `Recognized` spans with confidences from 0 to 100. Engines take the file's bytes, as
  reader plugins do (`docs/plans/rust-plugins.md`), never a path.
- `read_image` is `extract_image`'s policy around any engine:
  - an icon (under 200×200, measured from the header by `imagesize`) never reaches the engine;
  - more than 40 megapixels fails;
  - fewer than `ocr_min_chars` characters is "no text", which the caller turns into a picture document
    when `ingest.index_images` is on.
- `tesseract::Tesseract` is the binding above. Cargo builds link `GARAGE_TESSERACT_DIR`'s static
  libraries or pkg-config's, as `garage-git` does for libgit2. Bazel links `//ext/tesseract` and
  `//ext/leptonica`.
- `vision::Vision` is `VNRecognizeTextRequest` through `objc2-vision`. Each call runs inside an
  autorelease pool, and the engine holds only its settings, so it is `Send`.
- `HostEngine` wraps a closure, for an engine in another process.
- `default_engine()` returns Vision on macOS and Tesseract elsewhere.
- `examples/ocr-compare.rs` runs every engine built in over a folder of pictures. It prints, per
  picture and engine, the outcome, time, confidence and text, and can write each engine's text out
  for diffing. It is the bake-off tool for the decision above, run on a Mac against a real corpus:

  ```sh
  cd rust && cargo run --release -p garage-ocr --example ocr-compare -- --out /tmp/ocr ~/Pictures/Screenshots
  ```

Tests: the policy tests run everywhere, and the Tesseract tests run where `eng` data is installed (CI's
Linux job has it) and skip otherwise. Vision is type-checked for `aarch64-apple-darwin` on Linux; its
first run is on a Mac.

### What remains for the port

- The image reader itself in the Rust ingester: the extension dispatch, `normalize_text` from
  `garage-text`, the picture document for "no text", and `meta.ocr_engine` / `meta.ocr_confidence`.
  This belongs to the ingester's reader dispatch, wherever the Swift host's `read` hands pictures to
  Rust.
- A setting for the engine (`ingest.ocr_engine`: `vision` | `tesseract`) if both stay on the Mac.
- Bazel: the `garage-ocr` targets need their first build on a Mac.
