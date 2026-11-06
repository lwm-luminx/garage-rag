//! The in-process transport: a C ABI over the contract's serialized messages.
//!
//! A plugin linked into the ingester exports four functions, named with its own prefix so that
//! several can be linked into one image (the text plugin's are in `garage-text-ffi`):
//!
//! ```c
//! uint32_t <prefix>_contract_version(void);
//! int32_t  <prefix>_describe(const uint8_t *request, size_t request_len, GarageBuffer *response);
//! int32_t  <prefix>_extract(const uint8_t *request, size_t request_len, GarageBuffer *response);
//! void     <prefix>_buffer_free(GarageBuffer buffer);
//! ```
//!
//! `request` is a serialized `DescribeRequest` or `ExtractRequest`. On [`STATUS_OK`] `*response`
//! holds a serialized `DescribeResponse` or `ExtractResponse`; on any other status it holds a UTF-8
//! message saying what went wrong. Either way the caller frees it with `<prefix>_buffer_free`.
//! Every call is independent and thread-safe.
//!
//! The functions here do the work; a plugin's own crate only declares the `extern "C"` symbols
//! and forwards to them, because a symbol's name cannot come from a generic.

use std::panic::{AssertUnwindSafe, catch_unwind};

use prost::Message;

use crate::Plugin;
use crate::proto::{DescribeRequest, ExtractRequest};

/// The call succeeded; the buffer holds the response message.
pub const STATUS_OK: i32 = 0;
/// The request did not decode, or a pointer was null; the buffer holds a message.
pub const STATUS_BAD_REQUEST: i32 = 1;
/// The plugin panicked; the buffer holds a message. The process is unharmed.
pub const STATUS_PANIC: i32 = 2;

/// Bytes owned by the plugin, handed to the caller. `data` is null exactly when `len` is 0.
#[repr(C)]
#[derive(Debug)]
pub struct GarageBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl GarageBuffer {
    /// An empty buffer, for the caller to pass in before a call.
    pub const EMPTY: Self = Self { data: std::ptr::null_mut(), len: 0 };

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::EMPTY;
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { data: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

/// Frees a buffer this module handed out.
///
/// # Safety
///
/// `buffer` must have come from [`describe`] or [`extract`] and not been freed before.
// By value, as the C function takes it: the buffer is consumed.
#[allow(clippy::needless_pass_by_value)]
pub unsafe fn buffer_free(buffer: GarageBuffer) {
    if buffer.data.is_null() {
        return;
    }
    let slice = std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.len);
    // SAFETY: the pointer and length came from `Box::into_raw` of a boxed slice of this length.
    drop(unsafe { Box::from_raw(slice) });
}

/// `<prefix>_describe`.
///
/// # Safety
///
/// `request` must point to `request_len` readable bytes (or be null with `request_len` 0), and
/// `response` must point to a writable [`GarageBuffer`].
pub unsafe fn describe<P: Plugin>(
    plugin: &P,
    request: *const u8,
    request_len: usize,
    response: *mut GarageBuffer,
) -> i32 {
    // SAFETY: forwarded from the caller's contract.
    unsafe {
        call(request, request_len, response, |bytes| {
            let request = DescribeRequest::decode(bytes)?;
            Ok(plugin.describe(&request).encode_to_vec())
        })
    }
}

/// `<prefix>_extract`.
///
/// # Safety
///
/// As for [`describe`].
pub unsafe fn extract<P: Plugin>(
    plugin: &P,
    request: *const u8,
    request_len: usize,
    response: *mut GarageBuffer,
) -> i32 {
    // SAFETY: forwarded from the caller's contract.
    unsafe {
        call(request, request_len, response, |bytes| {
            let request = ExtractRequest::decode(bytes)?;
            Ok(plugin.extract(request).encode_to_vec())
        })
    }
}

unsafe fn call(
    request: *const u8,
    request_len: usize,
    response: *mut GarageBuffer,
    handler: impl FnOnce(&[u8]) -> Result<Vec<u8>, prost::DecodeError>,
) -> i32 {
    if response.is_null() {
        return STATUS_BAD_REQUEST;
    }
    let bytes: &[u8] = if request_len == 0 {
        &[]
    } else if request.is_null() {
        // SAFETY: the caller promised `response` is writable.
        unsafe { response.write(GarageBuffer::from_vec(b"request is null".to_vec())) };
        return STATUS_BAD_REQUEST;
    } else {
        // SAFETY: the caller promised `request_len` readable bytes at `request`.
        unsafe { std::slice::from_raw_parts(request, request_len) }
    };
    let (status, out) = match catch_unwind(AssertUnwindSafe(|| handler(bytes))) {
        Ok(Ok(encoded)) => (STATUS_OK, encoded),
        Ok(Err(error)) => (STATUS_BAD_REQUEST, format!("request does not decode: {error}").into_bytes()),
        Err(panic) => (STATUS_PANIC, format!("plugin panicked: {}", panic_message(&*panic)).into_bytes()),
    };
    // SAFETY: as above.
    unsafe { response.write(GarageBuffer::from_vec(out)) };
    status
}

pub(crate) fn panic_message(panic: &(dyn std::any::Any + Send)) -> String {
    if let Some(text) = panic.downcast_ref::<&str>() {
        (*text).to_string()
    } else if let Some(text) = panic.downcast_ref::<String>() {
        text.clone()
    } else {
        "unknown panic".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::{DescribeResponse, ExtractResponse, extract_response::Outcome};

    struct Echo;

    impl Plugin for Echo {
        fn describe(&self, _: &DescribeRequest) -> DescribeResponse {
            DescribeResponse { name: "echo".into(), ..Default::default() }
        }

        fn extract(&self, request: ExtractRequest) -> ExtractResponse {
            assert!(request.file_name != "panic.txt", "asked to panic");
            ExtractResponse::no_text(request.file_name)
        }
    }

    fn take(buffer: GarageBuffer) -> Vec<u8> {
        let bytes = if buffer.data.is_null() {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec()
        };
        unsafe { buffer_free(buffer) };
        bytes
    }

    #[test]
    fn round_trips_a_request() {
        let request = ExtractRequest { file_name: "a.txt".into(), ..Default::default() }.encode_to_vec();
        let mut out = GarageBuffer::EMPTY;
        let status = unsafe { extract(&Echo, request.as_ptr(), request.len(), &raw mut out) };
        assert_eq!(status, STATUS_OK);
        let response = ExtractResponse::decode(take(out).as_slice()).unwrap();
        assert!(matches!(response.outcome, Some(Outcome::NoText(ref n)) if n.reason == "a.txt"));
    }

    #[test]
    fn an_empty_request_is_the_default_message() {
        let mut out = GarageBuffer::EMPTY;
        let status = unsafe { describe(&Echo, std::ptr::null(), 0, &raw mut out) };
        assert_eq!(status, STATUS_OK);
        assert_eq!(DescribeResponse::decode(take(out).as_slice()).unwrap().name, "echo");
    }

    #[test]
    fn garbage_is_a_bad_request() {
        let garbage = [0xff_u8, 0xff, 0xff];
        let mut out = GarageBuffer::EMPTY;
        let status = unsafe { extract(&Echo, garbage.as_ptr(), garbage.len(), &raw mut out) };
        assert_eq!(status, STATUS_BAD_REQUEST);
        assert!(String::from_utf8(take(out)).unwrap().starts_with("request does not decode"));
    }

    #[test]
    fn a_panic_is_contained() {
        let request = ExtractRequest { file_name: "panic.txt".into(), ..Default::default() }.encode_to_vec();
        let mut out = GarageBuffer::EMPTY;
        let status = unsafe { extract(&Echo, request.as_ptr(), request.len(), &raw mut out) };
        assert_eq!(status, STATUS_PANIC);
        assert!(String::from_utf8(take(out)).unwrap().contains("asked to panic"));
    }

    #[test]
    fn a_null_response_pointer_is_refused() {
        let status = unsafe { describe(&Echo, std::ptr::null(), 0, std::ptr::null_mut()) };
        assert_eq!(status, STATUS_BAD_REQUEST);
    }
}
