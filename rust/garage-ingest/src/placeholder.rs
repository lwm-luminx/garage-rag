//! Cloud placeholders (`garage_rag.extract.placeholder`): files a sync client left on disk without
//! their content, which reading would download. The walker reports them rather than opening them.
//!
//! Three signals, as in Python: iCloud's `.name.icloud` sidecar name, the macOS `SF_DATALESS`
//! flag the File Provider framework sets (on files that report their real size), and, for an
//! empty file, a provider's extended attribute (the pre-File-Provider Dropbox client's
//! `com.dropbox.placeholder`).

use std::fs::Metadata;
use std::path::Path;

/// `SF_DATALESS` from `sys/stat.h`: a dataless file a File Provider extension manages.
pub const SF_DATALESS: u32 = 0x4000_0000;

const PLACEHOLDER_XATTRS: &[&str] =
    &["com.dropbox.placeholder", "com.apple.fileprovider.dataless", "com.apple.ubiquity.unsyncedItem"];
const PLACEHOLDER_XATTR_PREFIXES: &[&str] = &["com.apple.ubiquity.", "com.apple.fileprovider."];

/// Whether `path`, whose `stat` (following links) is `metadata`, is an unmaterialized stub.
pub fn is_placeholder(path: &Path, metadata: &Metadata) -> bool {
    let name = path.file_name().map(|name| name.to_string_lossy()).unwrap_or_default();
    if name.starts_with('.') && name.ends_with(".icloud") {
        return true;
    }
    if file_flags(metadata) & SF_DATALESS != 0 {
        return true;
    }
    if metadata.len() > 0 {
        return false;
    }
    // Zero bytes: the extended attribute decides stub versus genuinely empty.
    list_xattrs(path).iter().any(|attr| {
        PLACEHOLDER_XATTRS.contains(&attr.as_str())
            || PLACEHOLDER_XATTR_PREFIXES.iter().any(|prefix| attr.starts_with(prefix))
    })
}

#[cfg(target_os = "macos")]
fn file_flags(metadata: &Metadata) -> u32 {
    use std::os::macos::fs::MetadataExt;
    metadata.st_flags()
}

#[cfg(not(target_os = "macos"))]
fn file_flags(_metadata: &Metadata) -> u32 {
    0
}

/// The names of `path`'s extended attributes, not following a final symlink. Empty on any failure.
pub fn list_xattrs(path: &Path) -> Vec<String> {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;

        let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
            return Vec::new();
        };
        let size = list(&path, std::ptr::null_mut(), 0);
        let Ok(size) = usize::try_from(size) else {
            return Vec::new();
        };
        if size == 0 {
            return Vec::new();
        }
        let mut buffer = vec![0_u8; size];
        let written = list(&path, buffer.as_mut_ptr().cast(), buffer.len());
        let Ok(written) = usize::try_from(written) else {
            return Vec::new();
        };
        // A packed run of NUL-terminated names.
        buffer[..written.min(size)]
            .split(|&byte| byte == 0)
            .filter(|name| !name.is_empty())
            .map(|name| String::from_utf8_lossy(name).into_owned())
            .collect()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = path;
        Vec::new()
    }
}

#[cfg(target_os = "macos")]
fn list(path: &std::ffi::CStr, buffer: *mut libc::c_char, size: usize) -> isize {
    // SAFETY: `path` is NUL-terminated and `buffer` is null (with size 0) or holds `size` bytes.
    unsafe { libc::listxattr(path.as_ptr(), buffer, size, libc::XATTR_NOFOLLOW) }
}

#[cfg(target_os = "linux")]
fn list(path: &std::ffi::CStr, buffer: *mut libc::c_char, size: usize) -> isize {
    // SAFETY: `path` is NUL-terminated and `buffer` is null (with size 0) or holds `size` bytes.
    unsafe { libc::llistxattr(path.as_ptr(), buffer, size) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_file_without_attributes_is_not_a_placeholder() {
        let dir = std::env::temp_dir().join(format!("garage-ingest-placeholder-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let empty = dir.join("empty.txt");
        std::fs::write(&empty, b"").unwrap();
        assert!(!is_placeholder(&empty, &std::fs::metadata(&empty).unwrap()));
        let sidecar = dir.join(".notes.md.icloud");
        std::fs::write(&sidecar, b"x").unwrap();
        assert!(is_placeholder(&sidecar, &std::fs::metadata(&sidecar).unwrap()));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
