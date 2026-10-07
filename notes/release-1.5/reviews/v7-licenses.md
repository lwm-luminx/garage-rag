# Garage 1.5 license review (v7), tree at 0a35384 (#102 head)

**Verdict: no blockers. Nothing GPL or AGPL ships. The notices file is current and covers the default build. Fix two LGPL gaps before the App Store submission: the GPL-3.0 and LGPL-2.1 texts are missing, and GNU libiconv is statically linked inside lxml.**

## How this was checked
- Ran `python3 tools/third_party_notices.py --notices <tmp>/NOTICES.txt`, with network access, in the review tree. `diff` against `data/notices/THIRD_PARTY_NOTICES.txt` found 0 differences (15,791 lines). `--check` passes.
- Compared every pin under `ext/*/*.MODULE.bazel` and the Swift deps of rules_swift 3.6.1 (`swift/repositories.bzl`, fetched) against `NATIVE_COMPONENTS`.
- Listed the `License:` line of every uv.lock runtime package from the generated file, then read the bundled license texts.

## Findings

**Should fix: the notices omit GPL-3.0, which LGPL-3.0 requires.** psycopg 3.3.4 and psycopg-pool 3.3.1 are LGPL-3.0-only. Their sections carry only the LGPL text, at lines 4425 and 4600 of the notices file. LGPLv3 §4(b) requires the combined work to be accompanied by the GNU GPL as well. No `GNU GENERAL PUBLIC LICENSE Version 3` text appears anywhere in the file. Fix: add the GPL-3.0 text, for example as an extra section in `generate()`. Compliance is otherwise reasonable. Both are pure-Python `py3-none-any` wheels. `bazel/python_site_packages.bzl` copies the install trees whole, so the `.py` source ships and can be replaced. They load libpq through ctypes, and libpq is under the PostgreSQL license.

**Should fix: GNU libiconv (LGPL-2.1) is statically linked into lxml, with no LGPL-2.1 text and no source offer.** lxml 6.1.2 reaches the app through python-docx and python-pptx. Its universal2 wheel's `LICENSES.txt` says it bundles "iconv: LGPL 2.1", and gives only a URL for the license.
- Verified: `lxml/etree.cpython-313-darwin.so` exports `_libiconv_open_into`, `_libiconvctl`, `_libiconvlist` and `__libiconv_version`, and its only dylib load is `/usr/lib/libSystem.B.dylib`. So the copy is static, not the system libiconv.
- LGPL-2.1 §6 requires three things: the license text, the means to relink (source or object files, or a shared-library mechanism), and source for the exact version or a written offer.
- The header of the notices file says "Source code for the GPL- and LGPL-licensed components is available from the upstream projects linked below". libiconv is not listed below, and pointing at upstream is not the §6 offer.
- Fix, preferred: build lxml from sdist against the macOS SDK's libxml2, libxslt and libiconv. The LGPL code then stays in the OS, and there are fewer duplicate copies.
- Fix, alternative: ship the LGPL-2.1 text, name libiconv and its version, and host the exact source plus lxml's build recipe.

**Should fix: the app's own license is clear, but the bundle's About panel says only "MIT".**
- `garage_python/LICENSE` is MIT, "Copyright (c) 2026 Rick Mark". The app ships it in `Contents/Resources` (`macapp/Sources/GarageApp/BUILD.bazel:70`). The FAQ (`docs/support/faq.md:28`, "permissive MIT License"), the notices header and `README.md:188` all agree.
- There is no root `LICENSE`, so GitHub will not detect the license (README links `garage_python/LICENSE`).
- `NSHumanReadableCopyright` is the bare string `MIT` in the GarageApp, GarageCLI and GarageMCPCLI Info.plists. It should read something like `Copyright © 2026 Rick Mark. MIT License.`
- The App Store listing is not in the repo, so I could not verify it. Check that its copyright field matches, bearing in mind the signing identity is "Richard Penwell (DWVXMLB45Y)".

**Should fix: the Models catalog offers weights with restrictive licenses and shows no license. This is inferred: huggingface.co is blocked here, so the licenses below come from memory.**
- The app does not redistribute any weights. `ModelDownloadClient` fetches them from Hugging Face at the user's request, so no text is needed in THIRD_PARTY_NOTICES.
- Several entries in `docs/.data/models.json` carry use restrictions:
  - Gemma 2 2B Instruct is the featured `fact_distil` default, pre-selected in first run (`FirstRunCoordinator.swift:347`). It and EmbeddingGemma are under the Gemma Terms of Use and its Prohibited Use Policy.
  - NVIDIA Llama-Embed-Nemotron-8B is, I believe, under a non-commercial NVIDIA license, and is built on Llama 3.1, which has its own Community License.
- The rest (BGE-M3, Nomic, mxbai, Snowflake Arctic, Qwen, Mistral, DeepSeek-R1-Distill) are MIT or Apache-2.0 (inferred).
- Recommend a `license` and `license_url` field per catalog entry, shown on the Models page and in first run. Consider dropping the non-commercial Nemotron entry or labelling it.

**Note: NATIVE_COMPONENTS is complete for the default (PostgreSQL 18) build.**
- Every pin in ext/ matches an entry with the same version: CPython 3.13.15, PostgreSQL 18.6 (libpq included), pgvector 0.8.6, AGE 1.8.0 (commit `e43dc1a`, LICENSE and NOTICE), ICU 76.1, OpenSSL 3.4.7, zlib 1.3.2, llama.cpp 0.4.0, Tesseract 5.5.3, tessdata_fast 4.1.0, Leptonica 1.87.0, Sparkle 2.10.0 and PythonKit 0.5.1.
- The Swift runtime matches rules_swift 3.6.1 exactly: SwiftProtobuf 1.20.2, grpc-swift 1.16.0, NIO 2.42.0, NIO HTTP/2 1.26.0, NIO Transport Services 1.15.0, NIO Extras 1.4.0, NIO SSL 2.23.0 with BoringSSL, swift-log 1.4.4, Collections 1.0.4 and Atomics 1.1.0.
- The vendored LangExtract and the reimplemented langchain splitters are listed too.

**Note: two gaps the index test cannot catch.**
- `--config=pg19` swaps in PostgreSQL 19 beta (`REL_19_BETA4`) and AGE commit `d03d1cb`, but the notices still say PostgreSQL 18.6 and AGE `e43dc1a`. The licenses are identical, but versions and URLs would be wrong if a release were ever cut with pg19. Nothing in `.bazelrc` or CI does that today.
- `ext/nomic_embed` (nomic-embed-text-v1.5 Q2_K GGUF, Apache-2.0) says LlamaXPCService "ships it". No macapp BUILD file references `//ext/nomic_embed:selftest_model`, so it does not ship today and needs no entry. When it is wired in, add a NATIVE_COMPONENTS entry, because it would then be redistributed. The comment in the BUILD file is stale.
- Suggest a test that compares `ext/*/*.MODULE.bazel` pins (version or strip_prefix) against NATIVE_COMPONENTS, so a bump cannot drift silently.

**Note: tessdata is covered.** `PythonXPCService.framework/tessdata/eng.traineddata` comes from tessdata_fast 4.1.0, which is Apache-2.0. Its LICENSE is in the notices as its own section. No other traineddata ships (osd is absent).

**Note: no GPL or AGPL is linked (verified in the build files).**
- CPython uses `--with-readline=editline` and Postgres uses `--with-libedit-preferred` (libedit from the SDK, BSD).
- llama.cpp builds only libllama and ggml (`LLAMA_BUILD_COMMON/SERVER/TOOLS=OFF`), so none of its `vendor/` code ships.
- Tesseract is built with `DISABLE_ARCHIVE/CURL/TIFF` and no training tools. Leptonica is built with no codecs.
- PyMuPDF is absent. pypdfium2 bundles its PDFium dependency licenses (abseil, freetype, ICU, lcms, libjpeg-turbo, openjpeg, libpng, libtiff, zlib), and all of them are in the notices.
- Pillow's bundled libs are permissive. Its liblzma is 0BSD or public domain. FriBiDi is not bundled.
- Other licenses: certifi is MPL-2.0 (a data file shipped unmodified, which is fine). regex is Apache-2.0 plus CNRI-Python. Everything else is MIT, BSD, Apache, ISC or PSF.
- Inferred risk: nothing in the build stops CPython's configure from picking up Homebrew `gdbm` (GPL-3) or `xz` on a builder where they are installed. There is no otool gate for non-SDK absolute load paths in `Python.framework/.../lib-dynload`. Worth a one-line check in the release checklist: `otool -L` on lib-dynload, with no `/opt/homebrew` entries.

**Note: LGPL in the Mac App Store (inferred risk assessment).**
- Apple's standard EULA allows reverse engineering "to the extent permitted by ... licensing terms governing use of any open-sourced components".
- Mac App Store binaries are not FairPlay-encrypted.
- Users can replace the psycopg `.py` files, but that breaks the code signature. An ad-hoc re-signed build falls back to the login keychain, so it still runs.
- This is the common position for LGPL in App Store apps. Once the two text and offer items above are fixed, I see no blocker.

**Note: minor over- and under-inclusion.**
- The one notices file lists Sparkle in App Store builds, where Sparkle does not ship. This is harmless.
- cryptography 43.0.3 statically bundles its own OpenSSL 3.x, and its license is covered by the Apache-2.0 OpenSSL entry.
- The Rust crates compiled into cryptography, pydantic-core and rpds-py have no licenses in the wheels' dist-info, so they are absent from the notices (inferred: they are MIT or Apache, which is common practice, but strictly they are incomplete).
- pytest, pluggy and iniconfig ship in the app, deliberately, as a runtime dependency. This is not a license problem.
