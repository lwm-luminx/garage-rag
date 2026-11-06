// Umbrella header that exposes the Rust text reader's C ABI to Swift as the `GarageTextFFI` module.
//
// garage_text.h and the static library behind it come from //rust/garage-text-ffi, so the reader
// is linked into whichever process depends on :GaragePlugins, with nothing loaded at run time.
#ifndef GARAGE_TEXT_FFI_H
#define GARAGE_TEXT_FFI_H

#include "garage_text.h"

#endif /* GARAGE_TEXT_FFI_H */
