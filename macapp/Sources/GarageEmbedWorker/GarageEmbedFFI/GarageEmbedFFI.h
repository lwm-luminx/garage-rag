// Umbrella header that exposes the Rust embed worker's C ABI to Swift as the `GarageEmbedFFI` module.
//
// garage_embed.h and the static library behind it come from //rust/garage-embed-ffi, so the worker
// is linked into whichever process depends on :GarageEmbedWorker, with nothing loaded at run time.
#ifndef GARAGE_EMBED_FFI_H
#define GARAGE_EMBED_FFI_H

#include "garage_embed.h"

#endif /* GARAGE_EMBED_FFI_H */
