//! Versioned persistent `.pmat.idx` sidecar for pmat-core dumps.
//!
//! # Schema (version 1)
//!
//! Little-endian binary layout:
//! ```text
//! magic[8]        = b"PMATIDX\x01"
//! schema_version  u32   (= 1)
//! source_size     u64
//! source_digest   [u8; 16]   // 128-bit FNV-1a over full .pmat bytes
//! payload_len     u64
//! payload         [u8; payload_len]  // serialized Dump
//! payload_crc32   u32   // IEEE CRC-32 of payload only
//! ```
//!
//! Rules:
//! - Never modify the source `.pmat`.
//! - Never trust an index without matching schema + digest + CRC.
//! - On any validation failure: full re-parse (caller may rewrite index).
//!
//! Sidecar path: `<dump_path>.pmat.idx` if dump ends with other extension,
//! or `<dump>.idx` when dump is `*.pmat` → `file.pmat` + `file.pmat.idx`.

use crate::parse::{
    CodePadname, ContextRec, Dump, Edge, HashEntry, MagicRec, Object, ObjectId, Root, Strength,
};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

pub const SCHEMA_VERSION: u32 = 1;
pub const MAGIC: &[u8; 8] = b"PMATIDX\x01";

/// Result of attempting to open via index.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexOpenOutcome {
    /// Loaded dump from a validated sidecar.
    UsedIndex,
    /// Full parse used (no index, disabled, or rejected).
    FullParse,
}

thread_local! {
    static LAST_USED_INDEX: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

pub fn last_load_used_index() -> bool {
    LAST_USED_INDEX.with(|c| c.get())
}

pub fn set_last_used_index(v: bool) {
    LAST_USED_INDEX.with(|c| c.set(v));
}

/// Sidecar path next to the dump. Never overwrites the dump path itself.
/// `foo.pmat` → `foo.pmat.idx`
pub fn index_path_for(dump: &Path) -> PathBuf {
    let mut s = dump.as_os_str().to_os_string();
    s.push(".idx");
    PathBuf::from(s)
}

/// Index I/O enabled unless `PMAT_IDX=0` / `false` / `off` / `no`.
pub fn index_enabled_from_env() -> bool {
    match std::env::var("PMAT_IDX") {
        Ok(v) => {
            let v = v.trim().to_ascii_lowercase();
            !(v == "0" || v == "false" || v == "off" || v == "no" || v == "disable")
        }
        Err(_) => true,
    }
}

/// 128-bit FNV-1a over `data` (two independent 64-bit streams).
pub fn content_digest(data: &[u8]) -> [u8; 16] {
    let mut h1: u64 = 0xcbf29ce484222325;
    let mut h2: u64 = 0x100000001b3 ^ (data.len() as u64).wrapping_mul(0x9e3779b97f4a7c15);
    for (i, &b) in data.iter().enumerate() {
        h1 ^= b as u64;
        h1 = h1.wrapping_mul(0x100000001b3);
        h2 ^= (b as u64).wrapping_add((i as u64) << 1);
        h2 = h2.wrapping_mul(0x100000001b3);
    }
    let mut out = [0u8; 16];
    out[..8].copy_from_slice(&h1.to_le_bytes());
    out[8..].copy_from_slice(&h2.to_le_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    // IEEE CRC-32
    let mut crc: u32 = 0xffff_ffff;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb88320 & mask);
        }
    }
    !crc
}

// ---- binary write helpers ----

struct W {
    buf: Vec<u8>,
}

impl W {
    fn new() -> Self {
        Self { buf: Vec::new() }
    }
    fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }
    fn u16(&mut self, v: u16) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    fn bytes(&mut self, b: &[u8]) {
        self.u64(b.len() as u64);
        self.buf.extend_from_slice(b);
    }
    fn u64_slice(&mut self, s: &[u64]) {
        self.u64(s.len() as u64);
        for &x in s {
            self.u64(x);
        }
    }
    fn u32_slice(&mut self, s: &[u32]) {
        self.u64(s.len() as u64);
        for &x in s {
            self.u32(x);
        }
    }
}

struct R<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> R<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
    fn need(&self, n: usize) -> Result<(), String> {
        if self.pos + n > self.data.len() {
            Err("index payload truncated".into())
        } else {
            Ok(())
        }
    }
    fn u8(&mut self) -> Result<u8, String> {
        self.need(1)?;
        let v = self.data[self.pos];
        self.pos += 1;
        Ok(v)
    }
    fn u16(&mut self) -> Result<u16, String> {
        self.need(2)?;
        let v = u16::from_le_bytes([self.data[self.pos], self.data[self.pos + 1]]);
        self.pos += 2;
        Ok(v)
    }
    fn u32(&mut self) -> Result<u32, String> {
        self.need(4)?;
        let v = u32::from_le_bytes(
            self.data[self.pos..self.pos + 4]
                .try_into()
                .map_err(|_| "u32")?,
        );
        self.pos += 4;
        Ok(v)
    }
    fn u64(&mut self) -> Result<u64, String> {
        self.need(8)?;
        let v = u64::from_le_bytes(
            self.data[self.pos..self.pos + 8]
                .try_into()
                .map_err(|_| "u64")?,
        );
        self.pos += 8;
        Ok(v)
    }
    fn bytes(&mut self) -> Result<Vec<u8>, String> {
        let n = self.u64()? as usize;
        if n > self.data.len().saturating_sub(self.pos) {
            return Err("index blob length out of range".into());
        }
        self.need(n)?;
        let v = self.data[self.pos..self.pos + n].to_vec();
        self.pos += n;
        Ok(v)
    }
    fn u64_slice(&mut self) -> Result<Vec<u64>, String> {
        let n = self.u64()? as usize;
        let mut v = Vec::with_capacity(n.min(1_000_000));
        for _ in 0..n {
            v.push(self.u64()?);
        }
        Ok(v)
    }
    fn u32_slice(&mut self) -> Result<Vec<u32>, String> {
        let n = self.u64()? as usize;
        let mut v = Vec::with_capacity(n.min(1_000_000));
        for _ in 0..n {
            v.push(self.u32()?);
        }
        Ok(v)
    }
}

fn write_object(w: &mut W, o: &Object) {
    w.u64(o.addr);
    w.u8(o.type_code);
    w.u32(o.refcnt);
    w.u64(o.size);
    w.u64(o.blessed_at);
    w.bytes(&o.header);
    w.u64_slice(&o.ptrs);
    w.u64(o.strs.len() as u64);
    for s in &o.strs {
        w.bytes(s);
    }
    w.u8(o.array_flags);
    w.u64_slice(&o.elems);
    w.u64(o.hash_entries.len() as u64);
    for e in &o.hash_entries {
        w.bytes(&e.key);
        w.u64(e.hek);
        w.u64(e.value);
    }
    w.u64_slice(&o.code_consts);
    w.u64_slice(&o.code_constix);
    w.u64_slice(&o.code_gvs);
    w.u64_slice(&o.code_gvix);
    w.u64(o.code_padnames_at);
    w.u64(o.code_pads.len() as u64);
    for &(d, a) in &o.code_pads {
        w.u32(d);
        w.u64(a);
    }
    w.u64(o.code_padnames.len() as u64);
    for p in &o.code_padnames {
        w.u32(p.padix);
        w.bytes(&p.name);
        w.u64(p.ourstash);
        w.u16(p.flags);
        w.u64(p.fieldix);
        w.u64(p.fieldstash);
    }
    w.u64_slice(&o.object_fields);
    w.u64(o.magic.len() as u64);
    for m in &o.magic {
        w.u8(m.type_byte);
        w.u8(m.flags);
        w.u64(m.obj);
        w.u64(m.ptr);
        w.u64(m.vtbl);
    }
    w.u64(o.saved.len() as u64);
    for &(k, i, a) in &o.saved {
        w.u8(k);
        w.u64(i);
        w.u64(a);
    }
    w.u64(o.annotations.len() as u64);
    for (a, n) in &o.annotations {
        w.u64(*a);
        w.bytes(n);
    }
    w.bytes(&o.stash_name);
    w.u64_slice(&o.mro_ptrs);
    w.u64(o.io_ifileno);
    w.u64(o.io_ofileno);
    w.u64(o.class_fields.len() as u64);
    for (ix, n) in &o.class_fields {
        w.u64(*ix);
        w.bytes(n);
    }
}

fn read_object(r: &mut R<'_>) -> Result<Object, String> {
    let mut o = Object {
        addr: r.u64()?,
        type_code: r.u8()?,
        refcnt: r.u32()?,
        size: r.u64()?,
        blessed_at: r.u64()?,
        header: r.bytes()?,
        ..Default::default()
    };
    o.ptrs = r.u64_slice()?;
    let ns = r.u64()? as usize;
    o.strs = Vec::with_capacity(ns);
    for _ in 0..ns {
        o.strs.push(r.bytes()?);
    }
    o.array_flags = r.u8()?;
    o.elems = r.u64_slice()?;
    let nh = r.u64()? as usize;
    o.hash_entries = Vec::with_capacity(nh);
    for _ in 0..nh {
        o.hash_entries.push(HashEntry {
            key: r.bytes()?,
            hek: r.u64()?,
            value: r.u64()?,
        });
    }
    o.code_consts = r.u64_slice()?;
    o.code_constix = r.u64_slice()?;
    o.code_gvs = r.u64_slice()?;
    o.code_gvix = r.u64_slice()?;
    o.code_padnames_at = r.u64()?;
    let np = r.u64()? as usize;
    o.code_pads = Vec::with_capacity(np);
    for _ in 0..np {
        o.code_pads.push((r.u32()?, r.u64()?));
    }
    let npn = r.u64()? as usize;
    o.code_padnames = Vec::with_capacity(npn);
    for _ in 0..npn {
        o.code_padnames.push(CodePadname {
            padix: r.u32()?,
            name: r.bytes()?,
            ourstash: r.u64()?,
            flags: r.u16()?,
            fieldix: r.u64()?,
            fieldstash: r.u64()?,
        });
    }
    o.object_fields = r.u64_slice()?;
    let nm = r.u64()? as usize;
    o.magic = Vec::with_capacity(nm);
    for _ in 0..nm {
        o.magic.push(MagicRec {
            type_byte: r.u8()?,
            flags: r.u8()?,
            obj: r.u64()?,
            ptr: r.u64()?,
            vtbl: r.u64()?,
        });
    }
    let nsaved = r.u64()? as usize;
    o.saved = Vec::with_capacity(nsaved);
    for _ in 0..nsaved {
        o.saved.push((r.u8()?, r.u64()?, r.u64()?));
    }
    let na = r.u64()? as usize;
    o.annotations = Vec::with_capacity(na);
    for _ in 0..na {
        o.annotations.push((r.u64()?, r.bytes()?));
    }
    o.stash_name = r.bytes()?;
    o.mro_ptrs = r.u64_slice()?;
    o.io_ifileno = r.u64()?;
    o.io_ofileno = r.u64()?;
    let ncf = r.u64()? as usize;
    o.class_fields = Vec::with_capacity(ncf);
    for _ in 0..ncf {
        o.class_fields.push((r.u64()?, r.bytes()?));
    }
    Ok(o)
}

fn strength_from_u8(v: u8) -> Result<Strength, String> {
    match v {
        1 => Ok(Strength::Strong),
        2 => Ok(Strength::Weak),
        4 => Ok(Strength::Indirect),
        8 => Ok(Strength::Inferred),
        _ => Err(format!("bad strength {v}")),
    }
}

/// Serialize Dump to payload bytes (schema body only).
pub fn encode_dump(dump: &Dump) -> Vec<u8> {
    let mut w = W::new();
    w.u8(dump.format_minor);
    w.u32(dump.perlver);
    w.u8(if dump.ithreads { 1 } else { 0 });
    w.u8(if dump.big_endian { 1 } else { 0 });
    w.u32(dump.uint_len as u32);
    w.u32(dump.ptr_len as u32);
    w.u32(dump.nv_len as u32);
    w.u64(dump.file_bytes);
    w.u32(dump.heap_count);

    w.u64(dump.objects.len() as u64);
    for o in &dump.objects {
        write_object(&mut w, o);
    }

    // addr_to_id rebuilt from objects on decode

    w.u64(dump.roots.len() as u64);
    for r in &dump.roots {
        w.bytes(&r.name);
        w.u64(r.addr);
    }

    w.u32_slice(&dump.forward_off);
    w.u64(dump.forward_edges.len() as u64);
    for e in &dump.forward_edges {
        w.u32(e.target);
        w.u8(e.strength as u8);
    }
    w.u32_slice(&dump.reverse_off);
    w.u64(dump.reverse_edges.len() as u64);
    for e in &dump.reverse_edges {
        w.u32(e.target);
        w.u8(e.strength as u8);
    }

    for &c in &dump.type_counts {
        w.u64(c);
    }

    w.u64_slice(&dump.stack);
    w.u64_slice(&dump.mortals);
    w.u64(dump.mortal_floor);

    w.u64(dump.contexts.len() as u64);
    for c in &dump.contexts {
        w.u8(c.ctype);
        w.bytes(&c.common_header);
        w.u64_slice(&c.common_ptrs);
        w.u64(c.common_strs.len() as u64);
        for s in &c.common_strs {
            w.bytes(s);
        }
        w.bytes(&c.type_header);
        w.u64_slice(&c.type_ptrs);
        w.u64(c.type_strs.len() as u64);
        for s in &c.type_strs {
            w.bytes(s);
        }
    }

    w.buf
}

pub fn decode_dump(payload: &[u8]) -> Result<Dump, String> {
    let mut r = R::new(payload);
    let format_minor = r.u8()?;
    let perlver = r.u32()?;
    let ithreads = r.u8()? != 0;
    let big_endian = r.u8()? != 0;
    let uint_len = r.u32()? as usize;
    let ptr_len = r.u32()? as usize;
    let nv_len = r.u32()? as usize;
    let file_bytes = r.u64()?;
    let heap_count = r.u32()?;

    let nobj = r.u64()? as usize;
    let mut objects = Vec::with_capacity(nobj);
    for _ in 0..nobj {
        objects.push(read_object(&mut r)?);
    }
    let mut addr_to_id: HashMap<u64, ObjectId> = HashMap::with_capacity(nobj);
    for (i, o) in objects.iter().enumerate() {
        addr_to_id.insert(o.addr, i as ObjectId);
    }

    let nr = r.u64()? as usize;
    let mut roots = Vec::with_capacity(nr);
    for _ in 0..nr {
        roots.push(Root {
            name: r.bytes()?,
            addr: r.u64()?,
        });
    }

    let forward_off = r.u32_slice()?;
    let nfe = r.u64()? as usize;
    let mut forward_edges = Vec::with_capacity(nfe);
    for _ in 0..nfe {
        let target = r.u32()?;
        let strength = strength_from_u8(r.u8()?)?;
        forward_edges.push(Edge { target, strength });
    }
    let reverse_off = r.u32_slice()?;
    let nre = r.u64()? as usize;
    let mut reverse_edges = Vec::with_capacity(nre);
    for _ in 0..nre {
        let target = r.u32()?;
        let strength = strength_from_u8(r.u8()?)?;
        reverse_edges.push(Edge { target, strength });
    }

    let mut type_counts = [0u64; 256];
    for c in type_counts.iter_mut() {
        *c = r.u64()?;
    }

    let stack = r.u64_slice()?;
    let mortals = r.u64_slice()?;
    let mortal_floor = r.u64()?;

    let nctx = r.u64()? as usize;
    let mut contexts = Vec::with_capacity(nctx);
    for _ in 0..nctx {
        let ctype = r.u8()?;
        let common_header = r.bytes()?;
        let common_ptrs = r.u64_slice()?;
        let ncs = r.u64()? as usize;
        let mut common_strs = Vec::with_capacity(ncs);
        for _ in 0..ncs {
            common_strs.push(r.bytes()?);
        }
        let type_header = r.bytes()?;
        let type_ptrs = r.u64_slice()?;
        let nts = r.u64()? as usize;
        let mut type_strs = Vec::with_capacity(nts);
        for _ in 0..nts {
            type_strs.push(r.bytes()?);
        }
        contexts.push(ContextRec {
            ctype,
            common_header,
            common_ptrs,
            common_strs,
            type_header,
            type_ptrs,
            type_strs,
        });
    }

    if r.pos != r.data.len() {
        // trailing bytes are not allowed
        return Err(format!(
            "index payload has {} trailing bytes",
            r.data.len() - r.pos
        ));
    }

    Ok(Dump {
        format_minor,
        perlver,
        ithreads,
        big_endian,
        uint_len,
        ptr_len,
        nv_len,
        file_bytes,
        objects,
        heap_count,
        addr_to_id,
        roots,
        forward_off,
        forward_edges,
        reverse_off,
        reverse_edges,
        type_counts,
        stack,
        mortals,
        mortal_floor,
        contexts,
    })
}

/// Write index sidecar for `dump_path` from already-parsed `dump` and raw `file_bytes`.
pub fn write_index(dump_path: &Path, file_bytes: &[u8], dump: &Dump) -> Result<PathBuf, String> {
    let idx = index_path_for(dump_path);
    let payload = encode_dump(dump);
    let digest = content_digest(file_bytes);
    let crc = crc32(&payload);

    let mut out = Vec::with_capacity(48 + payload.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&SCHEMA_VERSION.to_le_bytes());
    out.extend_from_slice(&(file_bytes.len() as u64).to_le_bytes());
    out.extend_from_slice(&digest);
    out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
    out.extend_from_slice(&payload);
    out.extend_from_slice(&crc.to_le_bytes());

    // Atomic-ish write: temp then rename (same directory).
    let tmp = idx.with_extension("idx.tmp");
    {
        let mut f = fs::File::create(&tmp).map_err(|e| format!("index create: {e}"))?;
        f.write_all(&out).map_err(|e| format!("index write: {e}"))?;
        f.sync_all().ok();
    }
    fs::rename(&tmp, &idx).map_err(|e| format!("index rename: {e}"))?;
    Ok(idx)
}

/// Try to load Dump from sidecar. Errors mean "do not trust; full parse".
pub fn try_load_index(dump_path: &Path, file_bytes: &[u8]) -> Result<Dump, String> {
    let idx = index_path_for(dump_path);
    let mut f = fs::File::open(&idx).map_err(|e| format!("index open: {e}"))?;
    let mut data = Vec::new();
    f.read_to_end(&mut data)
        .map_err(|e| format!("index read: {e}"))?;

    if data.len() < 8 + 4 + 8 + 16 + 8 + 4 {
        return Err("index too short".into());
    }
    if &data[0..8] != MAGIC.as_slice() {
        return Err("index bad magic / schema marker".into());
    }
    let ver = u32::from_le_bytes(data[8..12].try_into().unwrap());
    if ver != SCHEMA_VERSION {
        return Err(format!("index schema version {ver} unsupported"));
    }
    let src_size = u64::from_le_bytes(data[12..20].try_into().unwrap());
    if src_size != file_bytes.len() as u64 {
        return Err("index source size mismatch".into());
    }
    let mut stored_digest = [0u8; 16];
    stored_digest.copy_from_slice(&data[20..36]);
    let expect = content_digest(file_bytes);
    if stored_digest != expect {
        return Err("index source digest mismatch".into());
    }
    let payload_len = u64::from_le_bytes(data[36..44].try_into().unwrap()) as usize;
    let payload_start: usize = 44;
    let payload_end = payload_start
        .checked_add(payload_len)
        .ok_or_else(|| "index payload_len overflow".to_string())?;
    if payload_end + 4 > data.len() {
        return Err("index truncated (payload)".into());
    }
    let payload = &data[payload_start..payload_end];
    let crc_stored = u32::from_le_bytes(data[payload_end..payload_end + 4].try_into().unwrap());
    if crc32(payload) != crc_stored {
        return Err("index payload CRC mismatch".into());
    }
    if payload_end + 4 != data.len() {
        return Err("index has trailing garbage".into());
    }
    decode_dump(payload)
}

/// Load dump: prefer validated index, else full parse; rewrite index after full parse when enabled.
pub fn load_path_with_index(path: &Path) -> Result<(Dump, IndexOpenOutcome), String> {
    let file_bytes = fs::read(path).map_err(|e| format!("io: {e}"))?;
    let enabled = index_enabled_from_env();

    if enabled {
        match try_load_index(path, &file_bytes) {
            Ok(dump) => {
                set_last_used_index(true);
                return Ok((dump, IndexOpenOutcome::UsedIndex));
            }
            Err(_e) => {
                // fall through to full parse
            }
        }
    }

    let dump = Dump::parse_bytes(&file_bytes)?;
    set_last_used_index(false);

    if enabled {
        // Best-effort rewrite; failure to write index is not a load failure.
        let _ = write_index(path, &file_bytes, &dump);
    }

    Ok((dump, IndexOpenOutcome::FullParse))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digest_stable() {
        let d = content_digest(b"hello");
        assert_eq!(d, content_digest(b"hello"));
        assert_ne!(d, content_digest(b"world"));
    }
}
