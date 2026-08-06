//! Panic-contained C ABI.

use crate::parse::{Dump, Strength};
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::ptr;
use std::slice;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_err(msg: impl Into<String>) {
    let s = msg.into();
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(s.replace('\0', "")).unwrap_or_default();
    });
}

fn clear_err() {
    set_err("");
}

macro_rules! try_or {
    ($expr:expr, $code:expr) => {
        match $expr {
            Ok(v) => v,
            Err(e) => {
                set_err(e);
                return $code;
            }
        }
    };
}

fn catch_code<F: FnOnce() -> i32>(f: F) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(code) => code,
        Err(_) => {
            set_err("Rust panic in pmat-core FFI");
            -6 // PMAT_ERR_PANIC
        }
    }
}

#[no_mangle]
pub extern "C" fn pmat_core_version() -> *const c_char {
    static V: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");
    V.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn pmat_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

#[no_mangle]
pub extern "C" fn pmat_load(path: *const c_char, out: *mut *mut Dump) -> i32 {
    catch_code(|| {
        clear_err();
        if path.is_null() || out.is_null() {
            set_err("null pointer");
            return -1;
        }
        let cstr = unsafe { CStr::from_ptr(path) };
        let path_str = try_or!(cstr.to_str().map_err(|e| e.to_string()), -2);
        let dump = try_or!(Dump::load_path(Path::new(path_str)), -3);
        unsafe {
            *out = Box::into_raw(Box::new(dump));
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_free(dump: *mut Dump) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !dump.is_null() {
            unsafe {
                drop(Box::from_raw(dump));
            }
        }
    }));
}

fn get<'a>(dump: *const Dump) -> Result<&'a Dump, i32> {
    if dump.is_null() {
        set_err("null dump");
        return Err(-1);
    }
    Ok(unsafe { &*dump })
}

#[no_mangle]
pub extern "C" fn pmat_heap_count(dump: *const Dump) -> u32 {
    // File-heap SVs only (excludes synthetic immortal placeholders).
    get(dump).map(|d| d.heap_count).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_object_count(dump: *const Dump) -> u32 {
    get(dump).map(|d| d.objects.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_format_minor(dump: *const Dump) -> u32 {
    get(dump).map(|d| d.format_minor as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_perlver(dump: *const Dump) -> u32 {
    get(dump).map(|d| d.perlver).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_ithreads(dump: *const Dump) -> i32 {
    get(dump).map(|d| if d.ithreads { 1 } else { 0 }).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_file_bytes(dump: *const Dump) -> u64 {
    get(dump).map(|d| d.file_bytes).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_type_counts(dump: *const Dump, counts: *mut u64, len: usize) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        if counts.is_null() {
            set_err("null counts");
            return -1;
        }
        let n = len.min(256);
        let slice = unsafe { slice::from_raw_parts_mut(counts, n) };
        for i in 0..n {
            slice[i] = d.type_counts[i];
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_root_count(dump: *const Dump) -> u32 {
    get(dump).map(|d| d.roots.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_root_at(
    dump: *const Dump,
    index: u32,
    name_buf: *mut c_char,
    name_buf_len: usize,
    addr_out: *mut u64,
) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        if index as usize >= d.roots.len() {
            set_err("root index out of bounds");
            return -7;
        }
        let r = &d.roots[index as usize];
        if !addr_out.is_null() {
            unsafe { *addr_out = r.addr };
        }
        if !name_buf.is_null() && name_buf_len > 0 {
            let copy = r.name.len().min(name_buf_len - 1);
            unsafe {
                ptr::copy_nonoverlapping(r.name.as_ptr(), name_buf as *mut u8, copy);
                *name_buf.add(copy) = 0;
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_id_for_addr(dump: *const Dump, addr: u64) -> u32 {
    get(dump)
        .ok()
        .and_then(|d| d.addr_to_id.get(&addr).copied())
        .unwrap_or(u32::MAX)
}

#[no_mangle]
pub extern "C" fn pmat_addr_for_id(dump: *const Dump, id: u32) -> u64 {
    get(dump)
        .ok()
        .and_then(|d| d.objects.get(id as usize).map(|o| o.addr))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_type_for_id(dump: *const Dump, id: u32) -> u8 {
    get(dump)
        .ok()
        .and_then(|d| d.objects.get(id as usize).map(|o| o.type_code))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_refcnt_for_id(dump: *const Dump, id: u32) -> u32 {
    get(dump)
        .ok()
        .and_then(|d| d.objects.get(id as usize).map(|o| o.refcnt))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_size_for_id(dump: *const Dump, id: u32) -> u64 {
    get(dump)
        .ok()
        .and_then(|d| d.objects.get(id as usize).map(|o| o.size))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_blessed_for_id(dump: *const Dump, id: u32) -> u64 {
    get(dump)
        .ok()
        .and_then(|d| d.objects.get(id as usize).map(|o| o.blessed_at))
        .unwrap_or(0)
}

fn batch_edges(
    edges: &[crate::parse::Edge],
    target_ids: *mut u32,
    strengths: *mut u8,
    max_edges: usize,
    out_n: *mut usize,
) -> i32 {
    if !out_n.is_null() {
        unsafe { *out_n = edges.len() };
    }
    let n = edges.len().min(max_edges);
    if n == 0 {
        return 0;
    }
    if target_ids.is_null() || strengths.is_null() {
        set_err("null edge buffers");
        return -1;
    }
    let t = unsafe { slice::from_raw_parts_mut(target_ids, n) };
    let s = unsafe { slice::from_raw_parts_mut(strengths, n) };
    for i in 0..n {
        t[i] = edges[i].target;
        s[i] = edges[i].strength as u8;
    }
    let _ = Strength::Strong; // keep enum linked
    0
}

#[no_mangle]
pub extern "C" fn pmat_outrefs_batch(
    dump: *const Dump,
    id: u32,
    target_ids: *mut u32,
    strengths: *mut u8,
    max_edges: usize,
    out_n: *mut usize,
) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        if id as usize >= d.objects.len() {
            set_err("object id out of bounds");
            return -7;
        }
        batch_edges(d.outrefs(id), target_ids, strengths, max_edges, out_n)
    })
}

#[no_mangle]
pub extern "C" fn pmat_inrefs_batch(
    dump: *const Dump,
    id: u32,
    source_ids: *mut u32,
    strengths: *mut u8,
    max_edges: usize,
    out_n: *mut usize,
) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        if id as usize >= d.objects.len() {
            set_err("object id out of bounds");
            return -7;
        }
        batch_edges(d.inrefs(id), source_ids, strengths, max_edges, out_n)
    })
}

#[no_mangle]
pub extern "C" fn pmat_forward_edge_count(dump: *const Dump) -> u64 {
    get(dump)
        .map(|d| d.forward_edges.len() as u64)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_reverse_edge_count(dump: *const Dump) -> u64 {
    get(dump)
        .map(|d| d.reverse_edges.len() as u64)
        .unwrap_or(0)
}
