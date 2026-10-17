//! The text reader's C ABI, declared in `include/garage_text.h`.
//!
//! Requests and responses are `garage.plugin.v1` messages, serialized, exactly as they cross the
//! gRPC transport, so a host speaks one contract whichever way a plugin is loaded. The mechanics
//! (buffers, status codes, panics) are `garage_plugin::ffi`'s.

use garage_plugin::ffi::{self, GarageBuffer};
use garage_text::TextPlugin;

/// `garage.plugin.v1.ContractVersion` of the messages this library speaks.
#[unsafe(no_mangle)]
pub extern "C" fn garage_text_contract_version() -> u32 {
    garage_plugin::CONTRACT as u32
}

/// Answers a serialized `DescribeRequest` with a serialized `DescribeResponse`.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes (or is null with `request_len` 0);
/// `response` points to a writable `GarageBuffer`, which the caller frees with
/// [`garage_text_buffer_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_text_describe(
    request: *const u8,
    request_len: usize,
    response: *mut GarageBuffer,
) -> i32 {
    // SAFETY: the caller's contract is the function's.
    unsafe { ffi::describe(&TextPlugin, request, request_len, response) }
}

/// Answers a serialized `ExtractRequest` with a serialized `ExtractResponse`.
///
/// # Safety
///
/// As for [`garage_text_describe`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_text_extract(
    request: *const u8,
    request_len: usize,
    response: *mut GarageBuffer,
) -> i32 {
    // SAFETY: the caller's contract is the function's.
    unsafe { ffi::extract(&TextPlugin, request, request_len, response) }
}

/// Frees a buffer a call above filled in.
///
/// # Safety
///
/// `buffer` came from this library and was not freed before.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_text_buffer_free(buffer: GarageBuffer) {
    // SAFETY: the caller's contract is the function's.
    unsafe { ffi::buffer_free(buffer) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use garage_plugin::proto::{ExtractRequest, ExtractResponse, extract_response::Outcome};
    use prost::Message;

    #[test]
    fn extracts_through_the_c_abi() {
        let request = ExtractRequest {
            extractor: String::new(),
            file_name: "hello.md".into(),
            content: b"---\ntitle: Hi\n---\nWorld\n".to_vec(),
        }
        .encode_to_vec();
        let mut out = GarageBuffer::EMPTY;
        let status = unsafe { garage_text_extract(request.as_ptr(), request.len(), &raw mut out) };
        assert_eq!(status, ffi::STATUS_OK);
        let bytes = unsafe { std::slice::from_raw_parts(out.data, out.len) }.to_vec();
        unsafe { garage_text_buffer_free(out) };
        let Some(Outcome::Document(doc)) = ExtractResponse::decode(bytes.as_slice()).unwrap().outcome else {
            panic!("no document");
        };
        assert_eq!((doc.title.as_deref(), doc.text.as_str()), (Some("Hi"), "World"));
        assert_eq!(garage_text_contract_version(), 1);
    }
}
