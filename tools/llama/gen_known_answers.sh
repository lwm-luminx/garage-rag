#!/bin/sh
# Regenerate ext/nomic_embed/known_answers.json, the reference vectors LlamaXPCService's
# "Embedding Known Answers" self-test and //macapp/Tests/LlamaEngineTests compare against.
#
# Builds llama.cpp's llama-embedding for the CPU from the source //ext/llama_cpp pins, fetches
# the GGUF //ext/nomic_embed pins (both sha256-checked), and embeds each input on its own. Run it
# on an Apple silicon Mac after bumping either pin (the reference belongs to the CPU it was made
# on; see the docstring); tools/llama/known_answers.py has the details and the inputs.
#
#   tools/llama/gen_known_answers.sh                               # -> ext/nomic_embed/known_answers.json
#   tools/llama/gen_known_answers.sh --metal --out /tmp/metal.json \
#       --compare ext/nomic_embed/known_answers.json               # Metal against the CPU reference
#
# Needs python3 (standard library only), cmake and a C++ compiler. The known-answers workflow
# (.github/workflows/known-answers.yaml) runs it on macOS (the reference, and Metal against it)
# and, with the cross-architecture tolerance, on Linux.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
exec python3 "$here/known_answers.py" "$@"
