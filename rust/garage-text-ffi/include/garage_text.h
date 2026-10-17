// Garage's text reader (plain text, Markdown, source code), linked in-process.
//
// Each call takes a serialized garage.plugin.v1 request message (proto/garage_plugin.proto) and
// fills `response` with the serialized response message, the same messages the reader's gRPC
// process serves. A status other than GARAGE_TEXT_OK means `response` holds a UTF-8 explanation
// instead. Free every filled buffer with garage_text_buffer_free. Every call is thread-safe.
//
// Built from rust/garage-text-ffi: libgarage_text_ffi.a (static, for the Mac app) and
// libgarage_text_ffi.{dylib,so,dll} (shared, for .NET and Python).

#ifndef GARAGE_TEXT_H
#define GARAGE_TEXT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The call succeeded; the buffer holds the response message.
#define GARAGE_TEXT_OK 0
// The request did not decode, or a pointer was null; the buffer holds a message.
#define GARAGE_TEXT_BAD_REQUEST 1
// The reader panicked; the buffer holds a message. The process is unharmed.
#define GARAGE_TEXT_PANIC 2

// Bytes owned by the library. `data` is null exactly when `len` is 0.
typedef struct GarageBuffer {
    uint8_t *data;
    size_t len;
} GarageBuffer;

// The garage.plugin.v1.ContractVersion these messages follow.
uint32_t garage_text_contract_version(void);

// DescribeRequest -> DescribeResponse.
int32_t garage_text_describe(const uint8_t *request, size_t request_len, GarageBuffer *response);

// ExtractRequest -> ExtractResponse.
int32_t garage_text_extract(const uint8_t *request, size_t request_len, GarageBuffer *response);

// Frees a buffer one of the calls above filled.
void garage_text_buffer_free(GarageBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif  // GARAGE_TEXT_H
