// Umbrella header that exposes the Rust ingest library's C ABI to Swift as the `GarageIngestFFI` module.
//
// garage_ingest.h and the static library behind it come from //rust/garage-ingest-ffi, so the ingest
// loop is linked into whichever process depends on :GarageIngestFFI, with nothing loaded at run time.
#ifndef GARAGE_INGEST_FFI_H
#define GARAGE_INGEST_FFI_H

#include "garage_ingest.h"

#endif /* GARAGE_INGEST_FFI_H */
