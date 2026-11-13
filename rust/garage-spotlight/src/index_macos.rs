//! The index's side of [`crate::index`] on the Mac: `MDQuery` and `MDItem` from CoreServices'
//! Metadata framework, bound by hand like the importer host and linked at build time.
//!
//! A search is one synchronous `MDQueryExecute` scoped to the folder, asking the query to keep
//! each result's path and type tree (`valueListAttrs`), so reading them back is a lookup in the
//! query's own results rather than a round trip to the metadata server per item.

#![allow(non_upper_case_globals, non_snake_case, unsafe_code)]

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::ptr;

use crate::index::{ATTRIBUTES, IndexedItem, Value, private_content_type};
use crate::macos::{Owned, Pool, cf_string, rust_string, rust_strings};

type Boolean = u8;
type CFIndex = isize;
type CFTypeID = usize;
type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFArrayRef = *const c_void;
type MDQueryRef = *const c_void;
type MDItemRef = *const c_void;

/// `kMDQuerySynchronous`: `MDQueryExecute` returns once the query has gathered every result.
const kMDQuerySynchronous: usize = 1;
/// `kCFNumberFloat64Type`.
const kCFNumberFloat64Type: CFIndex = 6;
/// Seconds from the Unix epoch to CoreFoundation's (2001-01-01T00:00:00Z).
const CF_ABSOLUTE_TIME_TO_UNIX: f64 = 978_307_200.0;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeArrayCallBacks: u8;

    fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;
    fn CFArrayCreate(
        alloc: CFTypeRef,
        values: *const CFTypeRef,
        count: CFIndex,
        callbacks: *const c_void,
    ) -> CFArrayRef;
    fn CFNumberGetTypeID() -> CFTypeID;
    fn CFNumberGetValue(number: CFTypeRef, kind: CFIndex, value: *mut c_void) -> Boolean;
    fn CFDateGetTypeID() -> CFTypeID;
    fn CFDateGetAbsoluteTime(date: CFTypeRef) -> f64;
    fn CFBooleanGetTypeID() -> CFTypeID;
    fn CFBooleanGetValue(boolean: CFTypeRef) -> Boolean;
    fn CFStringGetTypeID() -> CFTypeID;
    fn CFArrayGetTypeID() -> CFTypeID;
}

#[link(name = "CoreServices", kind = "framework")]
unsafe extern "C" {
    fn MDQueryCreate(
        alloc: CFTypeRef,
        query: CFStringRef,
        value_list_attrs: CFArrayRef,
        sorting_attrs: CFArrayRef,
    ) -> MDQueryRef;
    fn MDQuerySetSearchScope(query: MDQueryRef, scope_directories: CFArrayRef, scope_options: u32);
    fn MDQueryExecute(query: MDQueryRef, option_flags: usize) -> Boolean;
    fn MDQueryGetResultCount(query: MDQueryRef) -> CFIndex;
    fn MDQueryGetAttributeValueOfResultAtIndex(query: MDQueryRef, name: CFStringRef, index: CFIndex) -> CFTypeRef;
    fn MDItemCreate(alloc: CFTypeRef, path: CFStringRef) -> MDItemRef;
    fn MDItemCopyAttribute(item: MDItemRef, name: CFStringRef) -> CFTypeRef;
}

/// A CFArray of strings, owned.
fn cf_string_array(strings: &[&str]) -> Option<(Owned, Vec<Owned>)> {
    let owned: Vec<Owned> = strings.iter().map(|text| cf_string(text)).collect::<Option<_>>()?;
    let values: Vec<CFTypeRef> = owned.iter().map(|string| string.0).collect();
    let count = CFIndex::try_from(values.len()).ok()?;
    // SAFETY: `values` holds `count` live strings; the array retains them (kCFTypeArrayCallBacks).
    let array = Owned::new(unsafe {
        CFArrayCreate(ptr::null(), values.as_ptr(), count, (&raw const kCFTypeArrayCallBacks).cast())
    })?;
    Some((array, owned))
}

/// The Rust value of an attribute's CoreFoundation value.
fn value_of(value: CFTypeRef) -> Option<Value> {
    if value.is_null() {
        return None;
    }
    // SAFETY: `value` is a live CoreFoundation object.
    let type_id = unsafe { CFGetTypeID(value) };
    // SAFETY: each getter is called on an object of its own type.
    unsafe {
        if type_id == CFStringGetTypeID() {
            rust_string(value).filter(|text| !text.trim().is_empty()).map(Value::Text)
        } else if type_id == CFArrayGetTypeID() {
            let strings = rust_strings(value);
            (!strings.is_empty()).then_some(Value::List(strings))
        } else if type_id == CFDateGetTypeID() {
            Some(Value::Date(CFDateGetAbsoluteTime(value) + CF_ABSOLUTE_TIME_TO_UNIX))
        } else if type_id == CFNumberGetTypeID() {
            let mut number = 0.0_f64;
            (CFNumberGetValue(value, kCFNumberFloat64Type, (&raw mut number).cast()) != 0)
                .then_some(Value::Number(number))
        } else if type_id == CFBooleanGetTypeID() {
            Some(Value::Bool(CFBooleanGetValue(value) != 0))
        } else {
            None
        }
    }
}

pub(crate) fn search(scope: &Path, query: &str) -> Result<Vec<IndexedItem>, String> {
    let shown = scope.display();
    let _pool = Pool::push();
    let text = cf_string(query).ok_or_else(|| format!("the Spotlight query is not a string: {query}"))?;
    let (wanted, _names) =
        cf_string_array(&["kMDItemPath", "kMDItemContentTypeTree"]).ok_or("no attribute list for the query")?;
    let path_key = cf_string("kMDItemPath").ok_or("no attribute name")?;
    let tree_key = cf_string("kMDItemContentTypeTree").ok_or("no attribute name")?;
    let scope_text = scope.to_string_lossy();
    let (scopes, _scope_names) =
        cf_string_array(&[scope_text.as_ref()]).ok_or_else(|| format!("no search scope for {shown}"))?;
    // SAFETY: every object handed over is live for the call; the query is released when dropped.
    unsafe {
        let query_ref = Owned::new(MDQueryCreate(ptr::null(), text.0, wanted.0, ptr::null()))
            .ok_or_else(|| format!("Spotlight could not parse the query {query:?}"))?;
        MDQuerySetSearchScope(query_ref.0, scopes.0, 0);
        if MDQueryExecute(query_ref.0, kMDQuerySynchronous) == 0 {
            return Err(format!("Spotlight refused to search {shown}"));
        }
        let count = MDQueryGetResultCount(query_ref.0);
        let mut items = Vec::with_capacity(usize::try_from(count).unwrap_or(0));
        for index in 0..count {
            let Some(path) = rust_string(MDQueryGetAttributeValueOfResultAtIndex(query_ref.0, path_key.0, index))
            else {
                continue;
            };
            let content_types = rust_strings(MDQueryGetAttributeValueOfResultAtIndex(query_ref.0, tree_key.0, index));
            items.push(IndexedItem { path: PathBuf::from(path), content_types });
        }
        Ok(items)
    }
}

pub(crate) fn attributes(path: &Path) -> Vec<(String, Value)> {
    let _pool = Pool::push();
    let Some(path_text) = cf_string(&path.to_string_lossy()) else { return Vec::new() };
    // SAFETY: a live string; the item is released when dropped.
    let Some(item) = Owned::new(unsafe { MDItemCreate(ptr::null(), path_text.0) }) else { return Vec::new() };
    let copy = |name: &str| -> Option<Owned> {
        let key = cf_string(name)?;
        // SAFETY: a live item and name; the value follows the Copy rule.
        Owned::new(unsafe { MDItemCopyAttribute(item.0, key.0) })
    };
    let tree = copy("kMDItemContentTypeTree").map(|tree| rust_strings(tree.0)).unwrap_or_default();
    if private_content_type(&tree) {
        return Vec::new();
    }
    ATTRIBUTES
        .iter()
        .filter_map(|&name| copy(name).and_then(|value| value_of(value.0)).map(|value| (name.to_owned(), value)))
        .collect()
}
