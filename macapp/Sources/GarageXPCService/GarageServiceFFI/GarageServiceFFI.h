// Umbrella header that exposes the Rust GarageService's C ABI to Swift as the `GarageServiceFFI` module.
//
// garage_service.h and the static library behind it come from //rust/garage-service-ffi, so the
// backend is linked into GarageXPCService (and the sandboxed app, which hosts it in-process), with
// nothing loaded at run time.
#ifndef GARAGE_SERVICE_FFI_H
#define GARAGE_SERVICE_FFI_H

#include "garage_service.h"

#endif /* GARAGE_SERVICE_FFI_H */
