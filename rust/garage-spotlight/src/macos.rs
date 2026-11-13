//! The importer host: CoreFoundation's CFPlugIn, CoreServices' type identifiers and libobjc's
//! autorelease pools, bound by hand and linked at build time (system frameworks, nothing bundled).
//!
//! An importer is loaded the way `mdimport` loads one: `CFPlugInCreate` on its bundle, the factory for
//! `kMDImporterTypeID`, then `QueryInterface` for the URL interface (`ImporterImportURLData`) or, from
//! older importers, the path one (`ImporterImportData`). Calls are serialized: an importer is not
//! promised to be reentrant, and `mdworker` calls each from one thread at a time.

#![allow(non_upper_case_globals, non_snake_case, unsafe_code)]

use std::ffi::c_void;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;
use std::sync::Mutex;

use crate::{EXCLUDED_TYPES, Imported, Importer, Outcome, SYSTEM_IMPORTERS};

type Boolean = u8;
type CFIndex = isize;
type CFTypeID = usize;
type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFArrayRef = *const c_void;
type CFURLRef = *const c_void;
type CFUUIDRef = *const c_void;
type CFPlugInRef = *const c_void;
type CFMutableDictionaryRef = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct CFRange {
    location: CFIndex,
    length: CFIndex,
}

/// `CFUUIDBytes`, which is also COM's `REFIID` under CFPlugIn.
#[repr(C)]
#[derive(Clone, Copy)]
struct CFUUIDBytes([u8; 16]);

const kCFStringEncodingUTF8: u32 = 0x0800_0100;

/// `kMDImporterTypeID`: 8B08C4BF-415B-11D8-B3F9-0003936726FC.
const IMPORTER_TYPE: CFUUIDBytes =
    CFUUIDBytes([0x8B, 0x08, 0xC4, 0xBF, 0x41, 0x5B, 0x11, 0xD8, 0xB3, 0xF9, 0x00, 0x03, 0x93, 0x67, 0x26, 0xFC]);
/// `kMDImporterInterfaceID`: 6EBC27C4-899C-11D8-84AE-0003936726FC (`ImporterImportData`, a path).
const PATH_INTERFACE: CFUUIDBytes =
    CFUUIDBytes([0x6E, 0xBC, 0x27, 0xC4, 0x89, 0x9C, 0x11, 0xD8, 0x84, 0xAE, 0x00, 0x03, 0x93, 0x67, 0x26, 0xFC]);
/// `kMDImporterURLInterfaceID`: 13F60F02-3622-4F35-9891-EC10E6CD08F8 (`ImporterImportURLData`).
const URL_INTERFACE: CFUUIDBytes =
    CFUUIDBytes([0x13, 0xF6, 0x0F, 0x02, 0x36, 0x22, 0x4F, 0x35, 0x98, 0x91, 0xEC, 0x10, 0xE6, 0xCD, 0x08, 0xF8]);

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeDictionaryKeyCallBacks: u8;
    static kCFTypeDictionaryValueCallBacks: u8;

    fn CFRelease(cf: CFTypeRef);
    fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;
    fn CFStringGetTypeID() -> CFTypeID;
    fn CFArrayGetTypeID() -> CFTypeID;
    fn CFStringCreateWithBytes(
        alloc: CFTypeRef,
        bytes: *const u8,
        length: CFIndex,
        encoding: u32,
        external: Boolean,
    ) -> CFStringRef;
    fn CFStringGetLength(string: CFStringRef) -> CFIndex;
    fn CFStringGetCharacters(string: CFStringRef, range: CFRange, buffer: *mut u16);
    fn CFArrayGetCount(array: CFArrayRef) -> CFIndex;
    fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) -> *const c_void;
    fn CFDictionaryCreateMutable(
        alloc: CFTypeRef,
        capacity: CFIndex,
        key_callbacks: *const c_void,
        value_callbacks: *const c_void,
    ) -> CFMutableDictionaryRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> *const c_void;
    fn CFURLCreateFromFileSystemRepresentation(
        alloc: CFTypeRef,
        buffer: *const u8,
        length: CFIndex,
        directory: Boolean,
    ) -> CFURLRef;
    fn CFUUIDCreateFromUUIDBytes(alloc: CFTypeRef, bytes: CFUUIDBytes) -> CFUUIDRef;
    fn CFPlugInCreate(alloc: CFTypeRef, url: CFURLRef) -> CFPlugInRef;
    fn CFPlugInFindFactoriesForPlugInTypeInPlugIn(type_id: CFUUIDRef, plugin: CFPlugInRef) -> CFArrayRef;
    fn CFPlugInInstanceCreate(alloc: CFTypeRef, factory_id: CFUUIDRef, type_id: CFUUIDRef) -> *mut c_void;
}

#[link(name = "CoreServices", kind = "framework")]
unsafe extern "C" {
    static kUTTagClassFilenameExtension: CFStringRef;

    fn UTTypeCreatePreferredIdentifierForTag(
        tag_class: CFStringRef,
        tag: CFStringRef,
        conforming_to: CFStringRef,
    ) -> CFStringRef;
    fn UTTypeCopyAllTagsWithClass(uti: CFStringRef, tag_class: CFStringRef) -> CFArrayRef;
    fn UTTypeConformsTo(uti: CFStringRef, conforms_to: CFStringRef) -> Boolean;
}

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
}

/// COM's `IUnknown`, as `CFPlugInCOM.h` lays it out.
#[repr(C)]
struct IUnknownVtbl {
    _reserved: *mut c_void,
    query_interface: Option<unsafe extern "C" fn(*mut c_void, CFUUIDBytes, *mut *mut c_void) -> i32>,
    add_ref: Option<unsafe extern "C" fn(*mut c_void) -> u32>,
    release: Option<unsafe extern "C" fn(*mut c_void) -> u32>,
}

/// `MDImporterInterfaceStruct`.
#[repr(C)]
struct PathVtbl {
    unknown: IUnknownVtbl,
    import: Option<unsafe extern "C" fn(*mut c_void, CFMutableDictionaryRef, CFStringRef, CFStringRef) -> Boolean>,
}

/// `MDImporterURLInterfaceStruct`.
#[repr(C)]
struct UrlVtbl {
    unknown: IUnknownVtbl,
    import: Option<unsafe extern "C" fn(*mut c_void, CFMutableDictionaryRef, CFStringRef, CFURLRef) -> Boolean>,
}

/// A CoreFoundation object this code owns, released when dropped.
pub(crate) struct Owned(pub(crate) CFTypeRef);

impl Owned {
    pub(crate) fn new(object: CFTypeRef) -> Option<Self> {
        // `then`, not `then_some`: `Self(null)` built eagerly would be dropped, and CFRelease(NULL) traps.
        (!object.is_null()).then(|| Self(object))
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: a non-null object of the Create or Copy rule, released once.
        unsafe { CFRelease(self.0) }
    }
}

/// An autorelease pool for one importer call: importers built on Cocoa autorelease, and this thread
/// has no run loop to drain a pool for them.
pub(crate) struct Pool(*mut c_void);

impl Pool {
    pub(crate) fn push() -> Self {
        // SAFETY: no preconditions.
        Self(unsafe { objc_autoreleasePoolPush() })
    }
}

impl Drop for Pool {
    fn drop(&mut self) {
        // SAFETY: the pool this thread pushed, popped once, in order.
        unsafe { objc_autoreleasePoolPop(self.0) }
    }
}

pub(crate) fn cf_string(text: &str) -> Option<Owned> {
    let length = CFIndex::try_from(text.len()).ok()?;
    // SAFETY: `text` is valid UTF-8 of that length.
    Owned::new(unsafe { CFStringCreateWithBytes(ptr::null(), text.as_ptr(), length, kCFStringEncodingUTF8, 0) })
}

/// The Rust string of a CoreFoundation value, when it is a string.
pub(crate) fn rust_string(value: CFTypeRef) -> Option<String> {
    // SAFETY: `value` is null or a live CoreFoundation object.
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFStringGetTypeID() {
            return None;
        }
        let length = CFStringGetLength(value);
        let mut buffer = vec![0u16; usize::try_from(length).ok()?];
        CFStringGetCharacters(value, CFRange { location: 0, length }, buffer.as_mut_ptr());
        Some(String::from_utf16_lossy(&buffer))
    }
}

/// The strings of a CoreFoundation value, when it is an array (others are skipped).
pub(crate) fn rust_strings(value: CFTypeRef) -> Vec<String> {
    // SAFETY: `value` is null or a live CoreFoundation object.
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFArrayGetTypeID() {
            return Vec::new();
        }
        (0..CFArrayGetCount(value)).filter_map(|index| rust_string(CFArrayGetValueAtIndex(value, index))).collect()
    }
}

fn conforms(uti: &str, to: &str) -> bool {
    if uti.eq_ignore_ascii_case(to) {
        return true;
    }
    let (Some(uti), Some(to)) = (cf_string(uti), cf_string(to)) else { return false };
    // SAFETY: two live strings.
    unsafe { UTTypeConformsTo(uti.0, to.0) != 0 }
}

fn excluded(uti: &str) -> bool {
    EXCLUDED_TYPES.iter().any(|excluded| conforms(uti, excluded))
}

/// The preferred type of a file with `extension` (no dot).
fn type_for_extension(extension: &str) -> Option<String> {
    let tag = cf_string(extension)?;
    // SAFETY: a live string, and the system's constant.
    let uti =
        Owned::new(unsafe { UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, tag.0, ptr::null()) })?;
    rust_string(uti.0)
}

fn extensions_of(uti: &str) -> Vec<String> {
    let Some(uti) = cf_string(uti) else { return Vec::new() };
    // SAFETY: a live string, and the system's constant.
    let Some(tags) = Owned::new(unsafe { UTTypeCopyAllTagsWithClass(uti.0, kUTTagClassFilenameExtension) }) else {
        return Vec::new();
    };
    rust_strings(tags.0)
}

/// The document types of the system's importers, through [`EXCLUDED_TYPES`].
fn document_importers() -> Vec<Importer> {
    crate::importers_in(Path::new(SYSTEM_IMPORTERS))
        .into_iter()
        .filter(|importer| !crate::excluded_importer(&importer.path))
        .filter_map(|mut importer| {
            importer.content_types.retain(|uti| !excluded(uti));
            (!importer.content_types.is_empty()).then_some(importer)
        })
        .collect()
}

pub(crate) fn extensions() -> Vec<String> {
    let mut extensions: Vec<String> = document_importers()
        .iter()
        .flat_map(|importer| importer.content_types.iter().flat_map(|uti| extensions_of(uti)))
        .map(|extension| format!(".{}", extension.to_lowercase()))
        .collect();
    extensions.sort();
    extensions.dedup();
    extensions
}

/// A loaded importer's interface.
#[derive(Clone, Copy)]
enum Interface {
    Url(*mut *mut UrlVtbl),
    Path(*mut *mut PathVtbl),
}

struct Entry {
    importer: Importer,
    /// Loaded on first use; the error is kept, so a broken importer is tried once.
    loaded: Option<Result<Interface, String>>,
}

struct Registry {
    entries: Vec<Entry>,
}

// SAFETY: the interfaces are only called with the registry's lock held, one call at a time.
unsafe impl Send for Registry {}

static REGISTRY: Mutex<Option<Registry>> = Mutex::new(None);

/// Loads the importer bundle at `path`. The plug-in and its instance are kept for the process's life:
/// an importer is never unloaded.
fn load(path: &Path) -> Result<Interface, String> {
    let shown = path.display();
    let bytes = path.as_os_str().as_bytes();
    let length = CFIndex::try_from(bytes.len()).map_err(|_| format!("path too long: {shown}"))?;
    // SAFETY: each call gets live objects; the instance's vtable is the COM layout CFPlugIn promises.
    unsafe {
        let url = Owned::new(CFURLCreateFromFileSystemRepresentation(ptr::null(), bytes.as_ptr(), length, 1))
            .ok_or_else(|| format!("no URL for {shown}"))?;
        let plugin = CFPlugInCreate(ptr::null(), url.0);
        if plugin.is_null() {
            return Err(format!("CFPlugInCreate refused {shown}"));
        }
        let type_id = CFUUIDCreateFromUUIDBytes(ptr::null(), IMPORTER_TYPE);
        let factories = Owned::new(CFPlugInFindFactoriesForPlugInTypeInPlugIn(type_id, plugin))
            .ok_or_else(|| format!("no importer factory in {shown}"))?;
        if CFArrayGetCount(factories.0) == 0 {
            return Err(format!("no importer factory in {shown}"));
        }
        let factory = CFArrayGetValueAtIndex(factories.0, 0);
        let unknown = CFPlugInInstanceCreate(ptr::null(), factory, type_id).cast::<*mut IUnknownVtbl>();
        if unknown.is_null() || (*unknown).is_null() {
            return Err(format!("the importer in {shown} made no instance"));
        }
        let vtable = &**unknown;
        let query = vtable.query_interface.ok_or_else(|| format!("the importer in {shown} has no QueryInterface"))?;
        let mut interface: *mut c_void = ptr::null_mut();
        let found = if query(unknown.cast(), URL_INTERFACE, &raw mut interface) == 0 && !interface.is_null() {
            Ok(Interface::Url(interface.cast()))
        } else if query(unknown.cast(), PATH_INTERFACE, &raw mut interface) == 0 && !interface.is_null() {
            Ok(Interface::Path(interface.cast()))
        } else {
            Err(format!("the importer in {shown} has no MDImporter interface"))
        };
        if let Some(release) = vtable.release {
            release(unknown.cast());
        }
        found
    }
}

/// Calls the importer and reads what it filled in.
fn call(interface: Interface, path: &Path, uti: &str, importer: &Importer) -> Outcome {
    let shown = path.display();
    let Some(uti_string) = cf_string(uti) else { return Outcome::Failed(format!("bad type {uti}: {shown}")) };
    let bytes = path.as_os_str().as_bytes();
    let Ok(length) = CFIndex::try_from(bytes.len()) else { return Outcome::Failed(format!("path too long: {shown}")) };
    let _pool = Pool::push();
    // SAFETY: the interface came from `load`; every object handed over is live for the call.
    unsafe {
        let Some(attributes) = Owned::new(CFDictionaryCreateMutable(
            ptr::null(),
            0,
            (&raw const kCFTypeDictionaryKeyCallBacks).cast(),
            (&raw const kCFTypeDictionaryValueCallBacks).cast(),
        )) else {
            return Outcome::Failed(format!("no dictionary for {shown}"));
        };
        let dictionary = attributes.0.cast_mut();
        let succeeded = match interface {
            Interface::Url(interface) => {
                let is_dir = u8::from(path.is_dir());
                let Some(url) =
                    Owned::new(CFURLCreateFromFileSystemRepresentation(ptr::null(), bytes.as_ptr(), length, is_dir))
                else {
                    return Outcome::Failed(format!("no URL for {shown}"));
                };
                match (**interface).import {
                    Some(import) => import(interface.cast(), dictionary, uti_string.0, url.0),
                    None => return Outcome::Failed(format!("{} has no import function", importer.identifier)),
                }
            }
            Interface::Path(interface) => {
                let Some(path_string) = cf_string(&path.to_string_lossy()) else {
                    return Outcome::Failed(format!("bad path: {shown}"));
                };
                match (**interface).import {
                    Some(import) => import(interface.cast(), dictionary, uti_string.0, path_string.0),
                    None => return Outcome::Failed(format!("{} has no import function", importer.identifier)),
                }
            }
        };
        if succeeded == 0 {
            return Outcome::Failed(format!("Spotlight importer {} could not read {shown}", importer.identifier));
        }
        let value = |key: &str| cf_string(key).map_or(ptr::null(), |key| CFDictionaryGetValue(attributes.0, key.0));
        let text = rust_string(value("kMDItemTextContent")).unwrap_or_default();
        if text.trim().is_empty() {
            return Outcome::NoText(format!("Spotlight importer {} found no text: {shown}", importer.identifier));
        }
        Outcome::Imported(Imported {
            text,
            title: rust_string(value("kMDItemTitle")).filter(|title| !title.trim().is_empty()),
            authors: rust_strings(value("kMDItemAuthors")),
            content_type: uti.to_owned(),
            importer: importer.identifier.clone(),
            importer_version: importer.version.clone(),
        })
    }
}

pub(crate) fn import(path: &Path) -> Outcome {
    let shown = path.display();
    let extension = path.extension().map(|extension| extension.to_string_lossy().to_lowercase()).unwrap_or_default();
    if extension.is_empty() {
        return Outcome::NoImporter(format!("no extension, so no type: {shown}"));
    }
    let Some(uti) = type_for_extension(&extension) else {
        return Outcome::NoImporter(format!("no type for .{extension}: {shown}"));
    };
    if excluded(&uti) {
        return Outcome::NoImporter(format!("{uti} is not read through Spotlight: {shown}"));
    }
    let mut registry = REGISTRY.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let registry = registry.get_or_insert_with(|| Registry {
        entries: document_importers().into_iter().map(|importer| Entry { importer, loaded: None }).collect(),
    });
    // The importer that names the type itself, else the first whose types it conforms to.
    let position = registry
        .entries
        .iter()
        .position(|entry| entry.importer.content_types.iter().any(|known| known.eq_ignore_ascii_case(&uti)))
        .or_else(|| {
            registry
                .entries
                .iter()
                .position(|entry| entry.importer.content_types.iter().any(|known| conforms(&uti, known)))
        });
    let Some(position) = position else {
        return Outcome::NoImporter(format!("no system Spotlight importer takes {uti}: {shown}"));
    };
    let entry = &mut registry.entries[position];
    let interface = match entry.loaded.get_or_insert_with(|| load(&entry.importer.path)) {
        Ok(interface) => *interface,
        Err(error) => return Outcome::Failed(error.clone()),
    };
    call(interface, path, &uti, &entry.importer)
}
