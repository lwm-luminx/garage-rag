#!/usr/bin/env bash
# Compiles ext/python/garage_tesseract/garage_tesseract.c as an ordinary extension module, for
# testing it outside the app. The app's Python has it built in, with //ext/tesseract and
# //ext/leptonica linked statically (see //ext/python); a venv has neither, so CI builds it with this
# against the system libtesseract and puts OUT_DIR on PYTHONPATH, and tests/test_tesseract.py reads
# through it.
#
#   tools/garage_tesseract/build_extension.sh PYTHON OUT_DIR
#
# Needs a C compiler and Tesseract's headers and pkg-config file (libtesseract-dev, or Homebrew's
# tesseract).
set -euo pipefail

python=${1:?usage: build_extension.sh PYTHON OUT_DIR}
out=${2:?usage: build_extension.sh PYTHON OUT_DIR}
source="$(cd "$(dirname "$0")/../.." && pwd)/ext/python/garage_tesseract/garage_tesseract.c"

suffix=$("$python" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
include=$("$python" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
case "$(uname -s)" in
    Darwin) link=(-bundle -undefined dynamic_lookup) ;;
    *) link=(-shared) ;;
esac

mkdir -p "$out"
# shellcheck disable=SC2046 # pkg-config's flags are meant to split
cc "${link[@]}" -fPIC -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-missing-field-initializers \
    -I"$include" $(pkg-config --cflags tesseract) \
    "$source" $(pkg-config --libs tesseract) -o "$out/_garage_tesseract$suffix"
echo "$out/_garage_tesseract$suffix"
