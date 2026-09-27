"""Generate ext/nomic_embed/known_answers.json: llama.cpp's embeddings of fixed inputs.

LlamaXPCService's "Embedding Known Answers" self-test and //macapp/Tests/LlamaEngineTests embed
the inputs below with the bundled nomic-embed-text Q2_K GGUF and compare against these vectors.
The reference comes from llama.cpp's own `llama-embedding`, built for the CPU from the exact
source //ext/llama_cpp pins, run on the exact GGUF //ext/nomic_embed pins, one input per run,
on Apple silicon: the only CPU the app ships on, and the one the self-test runs on. That matches
how LlamaCppEngine embeds:

- tokenization with special tokens added and parsed (`common_tokenize(..., true, true)`, the
  engine's `tokenize(addSpecial: true, parseSpecial: true)`), so BERT's [CLS]/[SEP] frame the text;
- the pooling the GGUF declares (nomic-bert: mean), since neither side overrides it;
- L2 normalization (`--embd-normalize 2`, llama-embedding's default; the engine's `normalized`);
- one sequence per context, as the engine embeds one input at a time.

    tools/llama/gen_known_answers.sh                      # CPU reference -> ext/nomic_embed/known_answers.json
    tools/llama/gen_known_answers.sh --metal --out x.json # the same on Metal, to compare

`--compare FILE` prints the cosine of each vector against FILE's and fails below the tolerance
stored there (MIN_COSINE), which is how CI checks a regenerated reference and measures Metal
and Linux x86-64 against it. Q2_K vectors are not bit-exact across backends: Metal keeps the
activations in float where the CPU quantizes them to Q8_K, and the AVX2 and NEON kernels
accumulate in different orders. Measured against the Apple silicon CPU reference, Metal on the
same machine reaches 0.988 at worst and Linux x86-64 about 0.99, so the tolerance is 0.98:
close enough that a broken tokenizer, pooling or normalization, which fall far below it, still
fail. Standard library only; needs cmake and a C++ compiler.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools" / "windows"))
from fetch_ext import download, extract, pins

OUTPUT = REPO / "ext" / "nomic_embed" / "known_answers.json"
MODEL_REPO = "nomic-ai/nomic-embed-text-v1.5-GGUF"
N_CTX = 2048  # the engine's n_ctx for this model: min(4096 default, 2048 trained)

# nomic-embed-text wants a task prefix on every input; using them documents the correct usage.
INPUTS: list[tuple[str, str]] = [
    ("cat_a", "search_document: The cat slept all afternoon on the warm windowsill."),
    (
        "cat_b",
        "search_document: All afternoon, the cat napped on the sunny window ledge.",
    ),
    (
        "unrelated",
        "search_document: Quarterly estimated tax payments are due in April, June, September and January.",
    ),
    ("query", "search_query: How do I bake sourdough bread at home?"),
    (
        "document",
        (
            "search_document: Mix starter, flour, water and salt, let the dough rise overnight, "
            "then bake it in a hot Dutch oven."
        ),
    ),
]

# cosine(higher) must exceed cosine(lower): paraphrases sit closer than unrelated text, and a
# query sits closer to its answer than to anything else here.
ORDERINGS = [
    {"higher": ["cat_a", "cat_b"], "lower": ["cat_a", "unrelated"]},
    {"higher": ["query", "document"], "lower": ["query", "unrelated"]},
    {"higher": ["query", "document"], "lower": ["query", "cat_a"]},
]

# The cosine every backend and CPU architecture must reach against the reference. The Apple
# silicon CPU is the reference; the same machine's Metal measured 0.988 at worst (Metal keeps
# activations in float where the CPU quantizes them to Q8_K for Q2_K dot products) and Linux
# x86-64 about 0.99 (AVX2 and NEON accumulate differently). A pipeline error gives far less.
MIN_COSINE = 0.98
MAX_NORM_ERROR = 1e-3


def _cmake_flags(metal: bool) -> list[str]:
    return [
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLLAMA_BUILD_COMMON=ON",
        "-DLLAMA_BUILD_EXAMPLES=ON",
        "-DLLAMA_BUILD_TOOLS=OFF",
        "-DLLAMA_BUILD_TESTS=OFF",
        "-DLLAMA_BUILD_SERVER=OFF",
        "-DLLAMA_BUILD_APP=OFF",
        "-DLLAMA_OPENSSL=OFF",
        # Portable kernels, so the reference does not depend on the build host's CPU extensions.
        "-DGGML_NATIVE=OFF",
        "-DGGML_BLAS=OFF",
        f"-DGGML_METAL={'ON' if metal else 'OFF'}",
    ]


def _fetch(name: str) -> dict[str, object]:
    pin = pins(name)
    data = download(pin["urls"])
    digest = hashlib.sha256(data).hexdigest()
    if digest != pin["sha256"]:
        raise SystemExit(f"{name}: sha256 {digest} does not match the pinned {pin['sha256']}")
    pin["data"] = data
    return pin


def build_llama(work: Path, metal: bool) -> tuple[Path, dict[str, object]]:
    pin = _fetch("llama_cpp")
    source = work / "llama_cpp"
    extract(pin.pop("data"), source, pin["strip_prefix"])
    build = work / ("build-metal" if metal else "build-cpu")
    flags = _cmake_flags(metal)
    subprocess.run(["cmake", "-S", str(source), "-B", str(build), *flags], check=True)
    jobs = str(os.cpu_count() or 2)
    subprocess.run(
        ["cmake", "--build", str(build), "--target", "llama-embedding", "-j", jobs],
        check=True,
    )
    binary = build / "bin" / "llama-embedding"
    if not binary.exists():
        raise SystemExit(f"no llama-embedding at {binary}")
    pin["cmake_flags"] = flags
    return binary, pin


def fetch_model(work: Path) -> tuple[Path, dict[str, object]]:
    pin = _fetch("nomic_embed")
    path = work / "nomic-embed-text-v1.5.Q2_K.gguf"
    path.write_bytes(pin.pop("data"))
    return path, pin


def embed(binary: Path, model: Path, text: str, metal: bool) -> list[float]:
    command = [
        str(binary), "-m", str(model), "-p", text, "-c", str(N_CTX),
        "-ngl", "99" if metal else "0", "--embd-normalize", "2", "--embd-output-format", "json",
    ]  # fmt: skip
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    # The JSON goes to stdout; llama.cpp's logging goes to stderr.
    start = result.stdout.index("{")
    payload, _ = json.JSONDecoder().raw_decode(result.stdout[start:])
    data = payload["data"]
    if len(data) != 1:
        raise SystemExit(f"expected one embedding for {text!r}, got {len(data)}")
    return [float(x) for x in data[0]["embedding"]]


def _norm(v: list[float]) -> float:
    return math.sqrt(sum(x * x for x in v))


def cosine(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b, strict=True)) / (_norm(a) * _norm(b))


def generate(work: Path, metal: bool) -> dict[str, object]:
    work.mkdir(parents=True, exist_ok=True)
    binary, llama = build_llama(work, metal)
    model, model_pin = fetch_model(work)
    llama_version = str(llama["strip_prefix"]).removeprefix("llama.cpp-")
    vectors = {name: embed(binary, model, text, metal) for name, text in INPUTS}
    command = (
        f"llama-embedding -m nomic-embed-text-v1.5.Q2_K.gguf -p <text> -c {N_CTX} "
        f"-ngl {99 if metal else 0} --embd-normalize 2 --embd-output-format json"
    )
    return {
        "about": (
            "Known answers for LlamaXPCService's 'Embedding Known Answers' self-test and "
            "LlamaEngineTests. Generated by tools/llama/gen_known_answers.sh; do not edit by hand. "
            "Each vector is llama.cpp's llama-embedding output for one input, run alone."
        ),
        "model": {
            "repo": MODEL_REPO,
            "file": model.name,
            "url": model_pin["urls"][0],
            "sha256": model_pin["sha256"],
            "license": "Apache-2.0",
        },
        "llama_cpp": {
            "version": llama_version,
            "url": llama["urls"][0],
            "sha256": llama["sha256"],
        },
        "generation": {
            "backend": "metal" if metal else "cpu",
            "platform": f"{platform.system()} {platform.machine()}",
            "cmake_flags": llama["cmake_flags"],
            "command": command,
            "generated": datetime.datetime.now(tz=datetime.UTC).date().isoformat(),
        },
        "pooling": "mean (declared by the GGUF; nomic-bert)",
        "normalize": "L2",
        "dimensions": len(next(iter(vectors.values()))),
        "tolerance": {
            "min_cosine": MIN_COSINE,
            "max_norm_error": MAX_NORM_ERROR,
            "why": (
                "Not bit-exact: Metal keeps activations in float where the CPU quantizes them to "
                "Q8_K for Q2_K dot products, and the backends and CPU architectures sum in "
                "different orders. Against the Apple silicon CPU reference, Metal measured 0.988 "
                "at worst and Linux x86-64 about 0.99. A broken tokenizer, pooling or "
                "normalization drops the cosine far below that."
            ),
        },
        "orderings": ORDERINGS,
        "inputs": [
            {
                "id": name,
                "text": text,
                "norm": round(_norm(vectors[name]), 7),
                "first8": vectors[name][:8],
                "embedding": vectors[name],
            }
            for name, text in INPUTS
        ],
    }


def render(known: dict[str, object]) -> str:
    """JSON with each vector on one line, so the file stays short and diffs stay readable."""
    known = json.loads(json.dumps(known))  # a copy: the tokens below must not reach the caller's
    vectors: dict[str, str] = {}
    for entry in known["inputs"]:
        for key in ("first8", "embedding"):
            token = f"@@{entry['id']}.{key}@@"
            vectors[f'"{token}"'] = json.dumps(entry[key])
            entry[key] = token
    text = json.dumps(known, indent=1) + "\n"
    for token, value in vectors.items():
        text = text.replace(token, value)
    return text


def compare(produced: dict[str, object], reference_path: Path) -> int:
    """Cosine of each produced vector against the reference's; 0 when all reach the file's tolerance."""
    reference = json.loads(reference_path.read_text())
    expected = {entry["id"]: entry["embedding"] for entry in reference["inputs"]}
    minimum = reference["tolerance"]["min_cosine"]
    made = reference.get("generation", {})
    print(f"reference: {made.get('backend', '?')} on {made.get('platform', '?')}")
    worst = 1.0
    for entry in produced["inputs"]:
        c = cosine(entry["embedding"], expected[entry["id"]])
        worst = min(worst, c)
        print(f"{entry['id']:>10}: cosine {c:.7f}")
    print(f"worst cosine {worst:.7f} (tolerance {minimum})")
    return 0 if worst >= minimum else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--work",
        type=Path,
        default=Path(tempfile.gettempdir()) / "garage-known-answers",
    )
    parser.add_argument("--out", type=Path, default=OUTPUT)
    parser.add_argument("--metal", action="store_true", help="run llama.cpp on Metal instead of the CPU")
    parser.add_argument("--compare", type=Path, help="compare against this known-answers file")
    args = parser.parse_args()
    produced = generate(args.work, args.metal)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render(produced))
    print(f"wrote {args.out}")
    if args.compare:
        return compare(produced, args.compare)
    return 0


if __name__ == "__main__":
    sys.exit(main())
