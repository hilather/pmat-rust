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
        // Prefer validated .pmat.idx sidecar (PAR-110); never modifies the .pmat.
        let dump = try_or!(Dump::load_path(Path::new(path_str)), -3);
        unsafe {
            *out = Box::into_raw(Box::new(dump));
        }
        0
    })
}

/// 1 if the most recent successful pmat_load used a validated index; else 0.
#[no_mangle]
pub extern "C" fn pmat_last_load_used_index() -> i32 {
    if crate::index::last_load_used_index() {
        1
    } else {
        0
    }
}

/// Write path of the index sidecar for `dump_path` into `buf` (NUL-terminated).
/// Returns 0 on success, negative on error.
#[no_mangle]
pub extern "C" fn pmat_index_path(
    dump_path: *const c_char,
    buf: *mut c_char,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        clear_err();
        if dump_path.is_null() || buf.is_null() || buflen == 0 {
            set_err("null pointer");
            return -1;
        }
        let cstr = unsafe { CStr::from_ptr(dump_path) };
        let path_str = try_or!(cstr.to_str().map_err(|e| e.to_string()), -2);
        let idx = crate::index::index_path_for(Path::new(path_str));
        let s = idx.to_string_lossy();
        let bytes = s.as_bytes();
        if bytes.len() + 1 > buflen {
            set_err("buffer too small for index path");
            return -7;
        }
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, bytes.len());
            *buf.add(bytes.len()) = 0;
        }
        0
    })
}

/// Force full parse and rewrite index (when index enabled). Returns same as pmat_load.
#[no_mangle]
pub extern "C" fn pmat_load_full_parse(path: *const c_char, out: *mut *mut Dump) -> i32 {
    catch_code(|| {
        clear_err();
        if path.is_null() || out.is_null() {
            set_err("null pointer");
            return -1;
        }
        let cstr = unsafe { CStr::from_ptr(path) };
        let path_str = try_or!(cstr.to_str().map_err(|e| e.to_string()), -2);
        let p = Path::new(path_str);
        let file_bytes = try_or!(
            std::fs::read(p).map_err(|e| format!("io: {e}")),
            -2
        );
        let dump = try_or!(Dump::parse_bytes(&file_bytes), -3);
        crate::index::set_last_used_index(false);
        if crate::index::should_use_index(file_bytes.len() as u64) {
            let _ = crate::index::write_index(p, &file_bytes, &dump);
        }
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

// ---- Payload accessors for full SV materialization ----

#[no_mangle]
pub extern "C" fn pmat_stack_count(dump: *const Dump) -> u32 {
    get(dump).map(|d| d.stack.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_stack_at(dump: *const Dump, index: u32, addr_out: *mut u64) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        if index as usize >= d.stack.len() {
            set_err("stack index out of bounds");
            return -7;
        }
        if addr_out.is_null() {
            set_err("null");
            return -1;
        }
        unsafe { *addr_out = d.stack[index as usize] };
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_mortal_count(dump: *const Dump) -> u32 {
    get(dump).map(|d| d.mortals.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_mortal_at(dump: *const Dump, index: u32, addr_out: *mut u64) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        if index as usize >= d.mortals.len() {
            set_err("mortal index out of bounds");
            return -7;
        }
        if addr_out.is_null() {
            return -1;
        }
        unsafe { *addr_out = d.mortals[index as usize] };
        0
    })
}

fn obj_ref(dump: *const Dump, id: u32) -> Result<&'static crate::parse::Object, i32> {
    let d = get(dump)?;
    d.objects
        .get(id as usize)
        .ok_or_else(|| {
            set_err("object id out of bounds");
            -7
        })
        .map(|o| unsafe { &*(o as *const _) })
}

#[no_mangle]
pub extern "C" fn pmat_obj_header_len(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.header.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_header_copy(
    dump: *const Dump,
    id: u32,
    buf: *mut u8,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let n = o.header.len().min(buflen);
        if n > 0 {
            if buf.is_null() {
                return -1;
            }
            unsafe {
                ptr::copy_nonoverlapping(o.header.as_ptr(), buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_ptrs(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.ptrs.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_ptr_at(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.ptrs.get(index as usize).copied())
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_strs(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.strs.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_str_len(dump: *const Dump, id: u32, index: u32) -> u32 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.strs.get(index as usize).map(|s| s.len() as u32))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_str_copy(
    dump: *const Dump,
    id: u32,
    index: u32,
    buf: *mut u8,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let s = match o.strs.get(index as usize) {
            Some(s) => s,
            None => {
                set_err("str index");
                return -7;
            }
        };
        let n = s.len().min(buflen);
        if n > 0 && !buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(s.as_ptr(), buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_array_flags(dump: *const Dump, id: u32) -> u8 {
    obj_ref(dump, id).map(|o| o.array_flags).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_elems(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.elems.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_elem_at(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.elems.get(index as usize).copied())
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_hash(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.hash_entries.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_hash_key_len(dump: *const Dump, id: u32, index: u32) -> u32 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.hash_entries.get(index as usize).map(|e| e.key.len() as u32))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_hash_key_copy(
    dump: *const Dump,
    id: u32,
    index: u32,
    buf: *mut u8,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let e = match o.hash_entries.get(index as usize) {
            Some(e) => e,
            None => return -7,
        };
        let n = e.key.len().min(buflen);
        if n > 0 && !buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(e.key.as_ptr(), buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_hash_hek(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.hash_entries.get(index as usize).map(|e| e.hek))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_hash_val(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.hash_entries.get(index as usize).map(|e| e.value))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_code_padnames_at(dump: *const Dump, id: u32) -> u64 {
    obj_ref(dump, id).map(|o| o.code_padnames_at).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_code_consts(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.code_consts.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_code_const_at(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.code_consts.get(index as usize).copied())
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_code_gvs(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.code_gvs.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_code_gv_at(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.code_gvs.get(index as usize).copied())
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_code_pads(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.code_pads.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_code_pad_at(
    dump: *const Dump,
    id: u32,
    index: u32,
    depth_out: *mut u32,
    addr_out: *mut u64,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let (depth, addr) = match o.code_pads.get(index as usize) {
            Some(x) => *x,
            None => return -7,
        };
        if !depth_out.is_null() {
            unsafe { *depth_out = depth };
        }
        if !addr_out.is_null() {
            unsafe { *addr_out = addr };
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_code_padnames(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.code_padnames.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_code_padname_at(
    dump: *const Dump,
    id: u32,
    index: u32,
    padix_out: *mut u32,
    flags_out: *mut u16,
    ourstash_out: *mut u64,
    fieldix_out: *mut u64,
    fieldstash_out: *mut u64,
    name_buf: *mut u8,
    name_buflen: usize,
    name_len_out: *mut u32,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let pn = match o.code_padnames.get(index as usize) {
            Some(p) => p,
            None => return -7,
        };
        if !padix_out.is_null() {
            unsafe { *padix_out = pn.padix };
        }
        if !flags_out.is_null() {
            unsafe { *flags_out = pn.flags };
        }
        if !ourstash_out.is_null() {
            unsafe { *ourstash_out = pn.ourstash };
        }
        if !fieldix_out.is_null() {
            unsafe { *fieldix_out = pn.fieldix };
        }
        if !fieldstash_out.is_null() {
            unsafe { *fieldstash_out = pn.fieldstash };
        }
        if !name_len_out.is_null() {
            unsafe { *name_len_out = pn.name.len() as u32 };
        }
        let n = pn.name.len().min(name_buflen);
        if n > 0 && !name_buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(pn.name.as_ptr(), name_buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_magic(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.magic.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_magic_at(
    dump: *const Dump,
    id: u32,
    index: u32,
    type_out: *mut u8,
    flags_out: *mut u8,
    obj_out: *mut u64,
    ptr_out: *mut u64,
    vtbl_out: *mut u64,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let m = match o.magic.get(index as usize) {
            Some(m) => m,
            None => return -7,
        };
        unsafe {
            if !type_out.is_null() {
                *type_out = m.type_byte;
            }
            if !flags_out.is_null() {
                *flags_out = m.flags;
            }
            if !obj_out.is_null() {
                *obj_out = m.obj;
            }
            if !ptr_out.is_null() {
                *ptr_out = m.ptr;
            }
            if !vtbl_out.is_null() {
                *vtbl_out = m.vtbl;
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_stash_name_len(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.stash_name.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_stash_name_copy(
    dump: *const Dump,
    id: u32,
    buf: *mut u8,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let n = o.stash_name.len().min(buflen);
        if n > 0 && !buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(o.stash_name.as_ptr(), buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_mro(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.mro_ptrs.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_mro_at(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id)
        .ok()
        .and_then(|o| o.mro_ptrs.get(index as usize).copied())
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_annotations(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.annotations.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_annotation_at(
    dump: *const Dump,
    id: u32,
    index: u32,
    addr_out: *mut u64,
    name_buf: *mut u8,
    name_buflen: usize,
    name_len_out: *mut u32,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let (addr, name) = match o.annotations.get(index as usize) {
            Some(a) => a,
            None => return -7,
        };
        if !addr_out.is_null() {
            unsafe { *addr_out = *addr };
        }
        if !name_len_out.is_null() {
            unsafe { *name_len_out = name.len() as u32 };
        }
        let n = name.len().min(name_buflen);
        if n > 0 && !name_buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(name.as_ptr(), name_buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_saved(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.saved.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_saved_at(
    dump: *const Dump,
    id: u32,
    index: u32,
    kind_out: *mut u8,
    idx_out: *mut u64,
    addr_out: *mut u64,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let (kind, idx, addr) = match o.saved.get(index as usize) {
            Some(s) => *s,
            None => return -7,
        };
        unsafe {
            if !kind_out.is_null() {
                *kind_out = kind;
            }
            if !idx_out.is_null() {
                *idx_out = idx;
            }
            if !addr_out.is_null() {
                *addr_out = addr;
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_code_constix(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.code_constix.len() as u32).unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn pmat_obj_code_constix_at(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id).ok().and_then(|o| o.code_constix.get(index as usize).copied()).unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn pmat_obj_n_code_gvix(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id).map(|o| o.code_gvix.len() as u32).unwrap_or(0)
}
#[no_mangle]
pub extern "C" fn pmat_obj_code_gvix_at(dump: *const Dump, id: u32, index: u32) -> u64 {
    obj_ref(dump, id).ok().and_then(|o| o.code_gvix.get(index as usize).copied()).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_count(dump: *const Dump) -> u32 {
    get(dump).map(|d| d.contexts.len() as u32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_type(dump: *const Dump, index: u32) -> u8 {
    get(dump)
        .ok()
        .and_then(|d| d.contexts.get(index as usize).map(|c| c.ctype))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_common_header_len(dump: *const Dump, index: u32) -> u32 {
    get(dump)
        .ok()
        .and_then(|d| d.contexts.get(index as usize).map(|c| c.common_header.len() as u32))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_common_header_copy(
    dump: *const Dump,
    index: u32,
    buf: *mut u8,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        let c = match d.contexts.get(index as usize) {
            Some(c) => c,
            None => return -7,
        };
        let n = c.common_header.len().min(buflen);
        if n > 0 && !buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(c.common_header.as_ptr(), buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_context_n_common_strs(dump: *const Dump, index: u32) -> u32 {
    get(dump)
        .ok()
        .and_then(|d| d.contexts.get(index as usize).map(|c| c.common_strs.len() as u32))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_common_str_len(dump: *const Dump, index: u32, sidx: u32) -> u32 {
    get(dump)
        .ok()
        .and_then(|d| {
            d.contexts
                .get(index as usize)
                .and_then(|c| c.common_strs.get(sidx as usize).map(|s| s.len() as u32))
        })
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_common_str_copy(
    dump: *const Dump,
    index: u32,
    sidx: u32,
    buf: *mut u8,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        let s = match d
            .contexts
            .get(index as usize)
            .and_then(|c| c.common_strs.get(sidx as usize))
        {
            Some(s) => s,
            None => return -7,
        };
        let n = s.len().min(buflen);
        if n > 0 && !buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(s.as_ptr(), buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_context_n_type_ptrs(dump: *const Dump, index: u32) -> u32 {
    get(dump)
        .ok()
        .and_then(|d| d.contexts.get(index as usize).map(|c| c.type_ptrs.len() as u32))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_type_ptr_at(dump: *const Dump, index: u32, pidx: u32) -> u64 {
    get(dump)
        .ok()
        .and_then(|d| {
            d.contexts
                .get(index as usize)
                .and_then(|c| c.type_ptrs.get(pidx as usize).copied())
        })
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_type_header_len(dump: *const Dump, index: u32) -> u32 {
    get(dump)
        .ok()
        .and_then(|d| d.contexts.get(index as usize).map(|c| c.type_header.len() as u32))
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_context_type_header_copy(
    dump: *const Dump,
    index: u32,
    buf: *mut u8,
    buflen: usize,
) -> i32 {
    catch_code(|| {
        let d = match get(dump) {
            Ok(d) => d,
            Err(c) => return c,
        };
        let c = match d.contexts.get(index as usize) {
            Some(c) => c,
            None => return -7,
        };
        let n = c.type_header.len().min(buflen);
        if n > 0 && !buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(c.type_header.as_ptr(), buf, n);
            }
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn pmat_obj_n_class_fields(dump: *const Dump, id: u32) -> u32 {
    obj_ref(dump, id)
        .map(|o| o.class_fields.len() as u32)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn pmat_obj_class_field_at(
    dump: *const Dump,
    id: u32,
    index: u32,
    fieldix_out: *mut u64,
    name_buf: *mut u8,
    name_buflen: usize,
    name_len_out: *mut u32,
) -> i32 {
    catch_code(|| {
        let o = match obj_ref(dump, id) {
            Ok(o) => o,
            Err(c) => return c,
        };
        let (fieldix, name) = match o.class_fields.get(index as usize) {
            Some(f) => f,
            None => return -7,
        };
        if !fieldix_out.is_null() {
            unsafe { *fieldix_out = *fieldix };
        }
        if !name_len_out.is_null() {
            unsafe { *name_len_out = name.len() as u32 };
        }
        let n = name.len().min(name_buflen);
        if n > 0 && !name_buf.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(name.as_ptr(), name_buf, n);
            }
        }
        0
    })
}
