//! Lossless-enough PMAT parser into a dense ObjectId model.
//!
//! Builds contiguous forward and reverse edge tables from structural pointers
//! (blessed, type-specific PTR fields, ARRAY elems, HASH values, REF rv, etc.).
//! Edge *names* (Perl description strings) are not required for graph topology
//! parity checks; strengths use strong for normal PTR slots and weak for blessed.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

pub type ObjectId = u32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Strength {
    Strong = 1,
    Weak = 2,
    Indirect = 4,
    Inferred = 8,
}

#[derive(Clone, Debug)]
pub struct Edge {
    pub target: ObjectId,
    pub strength: Strength,
}

#[derive(Clone, Debug, Default)]
pub struct HashEntry {
    pub key: Vec<u8>,
    pub hek: u64,
    pub value: u64,
}

#[derive(Clone, Debug, Default)]
pub struct MagicRec {
    pub type_byte: u8,
    pub flags: u8,
    pub obj: u64,
    pub ptr: u64,
    pub vtbl: u64,
}

#[derive(Clone, Debug, Default)]
pub struct CodePadname {
    pub padix: u32,
    pub name: Vec<u8>,
    pub ourstash: u64,
    pub flags: u16,
    pub fieldix: u64,
    pub fieldstash: u64,
}

#[derive(Clone, Debug, Default)]
pub struct Object {
    pub addr: u64,
    pub type_code: u8,
    pub refcnt: u32,
    pub size: u64,
    pub blessed_at: u64,
    /// Type-specific header bytes (after common header).
    pub header: Vec<u8>,
    pub ptrs: Vec<u64>,
    pub strs: Vec<Vec<u8>>,
    pub array_flags: u8,
    pub elems: Vec<u64>,
    pub hash_entries: Vec<HashEntry>,
    pub code_consts: Vec<u64>,
    pub code_constix: Vec<u64>,
    pub code_gvs: Vec<u64>,
    pub code_gvix: Vec<u64>,
    pub code_padnames_at: u64,
    pub code_pads: Vec<(u32, u64)>,
    pub code_padnames: Vec<CodePadname>,
    pub object_fields: Vec<u64>,
    pub magic: Vec<MagicRec>,
    /// SVx saved slots: (kind, index_or_0, addr) kind: 1=SCALAR,2=ARRAY,3=HASH,4=elem idx,5=hash key
    pub saved: Vec<(u8, u64, u64)>,
    pub annotations: Vec<(u64, Vec<u8>)>,
    /// STASH/CLASS name (from type strs beyond HASH).
    pub stash_name: Vec<u8>,
    pub mro_ptrs: Vec<u64>,
    /// IO fields
    pub io_ifileno: u64,
    pub io_ofileno: u64,
    pub class_fields: Vec<(u64, Vec<u8>)>,
}

#[derive(Clone, Debug)]
pub struct Root {
    pub name: Vec<u8>,
    pub addr: u64,
}

#[derive(Clone, Debug, Default)]
pub struct ContextRec {
    pub ctype: u8,
    pub common_header: Vec<u8>,
    pub common_ptrs: Vec<u64>,
    pub common_strs: Vec<Vec<u8>>,
    pub type_header: Vec<u8>,
    pub type_ptrs: Vec<u64>,
    pub type_strs: Vec<Vec<u8>>,
}

#[derive(Debug)]
pub struct Dump {
    pub format_minor: u8,
    pub perlver: u32,
    pub ithreads: bool,
    pub big_endian: bool,
    pub uint_len: usize,
    pub ptr_len: usize,
    pub nv_len: usize,
    pub file_bytes: u64,
    pub objects: Vec<Object>,
    /// Number of objects that appeared on the file heap (excludes synthetic
    /// immortal placeholders registered only for edge resolution).
    pub heap_count: u32,
    pub addr_to_id: HashMap<u64, ObjectId>,
    pub roots: Vec<Root>,
    /// CSR forward: for id, edges in forward_edges[forward_off[id]..forward_off[id+1]]
    pub forward_off: Vec<u32>,
    pub forward_edges: Vec<Edge>,
    pub reverse_off: Vec<u32>,
    pub reverse_edges: Vec<Edge>,
    pub type_counts: [u64; 256],
    pub stack: Vec<u64>,
    pub mortals: Vec<u64>,
    pub mortal_floor: u64,
    pub contexts: Vec<ContextRec>,
}

pub static TYPE_NAMES: [&str; 18] = [
    "COMMON", "GLOB", "SCALAR", "REF", "ARRAY", "HASH", "STASH", "CODE", "IO",
    "LVALUE", "REGEXP", "FORMAT", "INVLIST", "UNDEF", "YES", "NO", "OBJECT", "CLASS",
];

struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
    big_endian: bool,
    uint_len: usize,
    ptr_len: usize,
    nv_len: usize,
}

impl<'a> Cursor<'a> {
    fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    fn need(&self, n: usize) -> Result<(), String> {
        if self.remaining() < n {
            Err(format!("unexpected EOF at {} need {}", self.pos, n))
        } else {
            Ok(())
        }
    }

    fn read_exact(&mut self, n: usize) -> Result<&'a [u8], String> {
        self.need(n)?;
        let s = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.read_exact(1)?[0])
    }

    fn u32(&mut self) -> Result<u32, String> {
        let b = self.read_exact(4)?;
        Ok(if self.big_endian {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        })
    }

    fn u64(&mut self) -> Result<u64, String> {
        let b = self.read_exact(8)?;
        Ok(if self.big_endian {
            u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
        } else {
            u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
        })
    }

    fn uint(&mut self) -> Result<u64, String> {
        if self.uint_len == 8 {
            self.u64()
        } else {
            Ok(self.u32()? as u64)
        }
    }

    fn ptr(&mut self) -> Result<u64, String> {
        if self.ptr_len == 8 {
            self.u64()
        } else {
            Ok(self.u32()? as u64)
        }
    }

    fn str_bytes(&mut self) -> Result<Vec<u8>, String> {
        let len_u = self.uint()?;
        // Devel::MAT::Dumper writes uint(-1) for NULL strings (see write_str).
        // Match Dumpfile::_read_str: return empty/None without a body.
        let minus_1 = if self.uint_len == 8 {
            u64::MAX
        } else {
            u32::MAX as u64
        };
        if len_u == minus_1 {
            return Ok(Vec::new());
        }
        if len_u > self.remaining() as u64 {
            return Err(format!(
                "string length {len_u} at pos {} exceeds remaining {}",
                self.pos - self.uint_len,
                self.remaining()
            ));
        }
        let len = len_u as usize;
        Ok(self.read_exact(len)?.to_vec())
    }

    fn skip(&mut self, n: usize) -> Result<(), String> {
        self.need(n)?;
        self.pos += n;
        Ok(())
    }
}

/// Temporary edge with address target before ID resolution.
struct PendingEdge {
    from: ObjectId,
    to_addr: u64,
    strength: Strength,
}

impl Dump {
    /// Load dump from path. Prefer a validated `.pmat.idx` sidecar when enabled
    /// (`PMAT_IDX` not disabled); otherwise full parse and rewrite the index.
    pub fn load_path(path: &Path) -> Result<Self, String> {
        crate::index::load_path_with_index(path).map(|(d, _)| d)
    }

    /// Full parse only (no index). Used when rebuilding or when index is disabled.
    pub fn load_path_full_parse(path: &Path) -> Result<Self, String> {
        let data = fs::read(path).map_err(|e| format!("io: {e}"))?;
        Self::parse_bytes(&data)
    }

    pub fn parse_bytes(data: &[u8]) -> Result<Self, String> {
        let file_bytes = data.len() as u64;
        let mut c = Cursor {
            data,
            pos: 0,
            big_endian: false,
            uint_len: 4,
            ptr_len: 4,
            nv_len: 8,
        };

        if c.read_exact(4)? != b"PMAT" {
            return Err("File magic signature not found".into());
        }

        let flags = c.u8()?;
        c.big_endian = flags & 0x01 != 0;
        c.uint_len = if flags & 0x02 != 0 { 8 } else { 4 };
        c.ptr_len = if flags & 0x04 != 0 { 8 } else { 4 };
        c.nv_len = if flags & 0x08 != 0 { 10 } else { 8 };
        let ithreads = flags & 0x10 != 0;
        if flags & !0x1f != 0 {
            return Err(format!("unrecognised flags {flags:#x}"));
        }

        if c.u8()? != 0 {
            return Err("zero header field is not zero".into());
        }
        if c.u8()? != 0 {
            return Err("format version major unrecognised".into());
        }
        let format_minor = c.u8()?;
        if format_minor > 6 {
            return Err(format!("format version minor unrecognised ({format_minor})"));
        }
        let perlver = c.u32()?;

        let n_types = c.u8()? as usize;
        let mut sv_sizes: Vec<(u8, u8, u8)> = Vec::with_capacity(n_types);
        for _ in 0..n_types {
            let h = c.u8()?;
            let np = c.u8()?;
            let ns = c.u8()?;
            sv_sizes.push((h, np, ns));
        }

        let mut svx_sizes: Vec<(u8, u8, u8)> = Vec::new();
        if format_minor >= 4 {
            let n_ext = c.u8()? as usize;
            for _ in 0..n_ext {
                svx_sizes.push((c.u8()?, c.u8()?, c.u8()?));
            }
        } else {
            svx_sizes.push((2, 2, 0));
        }

        let mut ctx_sizes: Vec<(u8, u8, u8)> = Vec::new();
        if format_minor >= 2 {
            let n_ctx = c.u8()? as usize;
            for _ in 0..n_ctx {
                ctx_sizes.push((c.u8()?, c.u8()?, c.u8()?));
            }
        }

        // Immortal root addresses — not always present on the heap stream, but
        // many edges point at them. Registered after heap parse for edge
        // resolution without inflating heap_count / type_counts.
        let undef_at = c.ptr()?;
        let yes_at = c.ptr()?;
        let no_at = c.ptr()?;

        let mut roots = Vec::new();
        roots.push(Root {
            name: b"sv_undef".to_vec(),
            addr: undef_at,
        });
        roots.push(Root {
            name: b"sv_yes".to_vec(),
            addr: yes_at,
        });
        roots.push(Root {
            name: b"sv_no".to_vec(),
            addr: no_at,
        });

        let n_roots = c.u32()?;
        for _ in 0..n_roots {
            let name = c.str_bytes()?;
            let addr = c.ptr()?;
            roots.push(Root { name, addr });
        }

        let stacksize = c.uint()? as usize;
        let mut stack: Vec<u64> = Vec::with_capacity(stacksize);
        for _ in 0..stacksize {
            stack.push(c.ptr()?);
        }

        // Heap
        let mut objects: Vec<Object> = Vec::new();
        let mut addr_to_id: HashMap<u64, ObjectId> = HashMap::new();
        let mut pending: Vec<PendingEdge> = Vec::new();
        let mut type_counts = [0u64; 256];

        // common sizes
        let (common_h, common_np, common_ns) = sv_sizes
            .first()
            .copied()
            .ok_or_else(|| "missing common type size".to_string())?;

        loop {
            let type_code = c.u8()?;
            if type_code == 0 {
                break;
            }

            if type_code >= 0xF1 {
                return Err(format!("Unrecognised META tag {type_code:02X}"));
            }
            if type_code == 0xF0 {
                // META_STRUCT: uint id, uint nfields, str name, then fields
                let _id = c.uint()?;
                let nfields = c.uint()? as usize;
                let _name = c.str_bytes()?;
                for _ in 0..nfields {
                    let _fn = c.str_bytes()?;
                    let _ft = c.u8()?;
                }
                continue;
            }
            if type_code >= 0x80 {
                // extension on existing SV
                let idx = (type_code - 0x80) as usize;
                let (hb, np, ns) = if idx < svx_sizes.len() {
                    svx_sizes[idx]
                } else {
                    return Err(format!("Unrecognised SV extension type {type_code:02x}"));
                };
                let sv_addr = c.ptr()?;
                // read extension payload; collect ptrs as weak/strong edges if SV known
                let _bytes = c.read_exact(hb as usize)?.to_vec();
                let mut ext_ptrs = Vec::new();
                for _ in 0..np {
                    ext_ptrs.push(c.ptr()?);
                }
                let mut ext_strs: Vec<Vec<u8>> = Vec::new();
                for _ in 0..ns {
                    ext_strs.push(c.str_bytes()?);
                }
                if let Some(&from) = addr_to_id.get(&sv_addr) {
                    if type_code == 0x80 {
                        let type_byte = _bytes.first().copied().unwrap_or(0);
                        let flags = _bytes.get(1).copied().unwrap_or(0);
                        let obj = ext_ptrs.first().copied().unwrap_or(0);
                        let mptr = ext_ptrs.get(1).copied().unwrap_or(0);
                        let vtbl = ext_ptrs.get(2).copied().unwrap_or(0);
                        objects[from as usize].magic.push(MagicRec {
                            type_byte,
                            flags,
                            obj,
                            ptr: mptr,
                            vtbl,
                        });
                        if obj != 0 {
                            let strength = if flags & 0x01 != 0 {
                                Strength::Strong
                            } else {
                                Strength::Weak
                            };
                            pending.push(PendingEdge {
                                from,
                                to_addr: obj,
                                strength,
                            });
                        }
                        if mptr != 0 {
                            pending.push(PendingEdge {
                                from,
                                to_addr: mptr,
                                strength: Strength::Strong,
                            });
                        }
                    } else if type_code == 0x81 {
                        let p = ext_ptrs.first().copied().unwrap_or(0);
                        objects[from as usize].saved.push((1, 0, p));
                    } else if type_code == 0x82 {
                        let p = ext_ptrs.first().copied().unwrap_or(0);
                        objects[from as usize].saved.push((2, 0, p));
                    } else if type_code == 0x83 {
                        let p = ext_ptrs.first().copied().unwrap_or(0);
                        objects[from as usize].saved.push((3, 0, p));
                    } else if type_code == 0x84 {
                        // ARRAY elem saved: header uint index, ptr value
                        let idx = if !_bytes.is_empty() {
                            unpack_uint(&_bytes, c.big_endian, c.uint_len).unwrap_or(0)
                        } else {
                            0
                        };
                        let p = ext_ptrs.first().copied().unwrap_or(0);
                        objects[from as usize].saved.push((4, idx, p));
                    } else if type_code == 0x85 {
                        // HASH elem saved: ptrs key_addr, val_addr
                        let k = ext_ptrs.first().copied().unwrap_or(0);
                        let v = ext_ptrs.get(1).copied().unwrap_or(0);
                        objects[from as usize].saved.push((5, k, v));
                    } else if type_code == 0x86 {
                        let p = ext_ptrs.first().copied().unwrap_or(0);
                        objects[from as usize].saved.push((6, 0, p)); // CODE slot
                    } else if type_code == 0x87 {
                        let p = ext_ptrs.first().copied().unwrap_or(0);
                        let name = ext_strs.first().cloned().unwrap_or_default();
                        objects[from as usize].annotations.push((p, name));
                        if p != 0 {
                            pending.push(PendingEdge {
                                from,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    } else {
                        for &p in &ext_ptrs {
                            if p != 0 {
                                pending.push(PendingEdge {
                                    from,
                                    to_addr: p,
                                    strength: Strength::Strong,
                                });
                            }
                        }
                    }
                }
                continue;
            }

            // Common header
            let common = c.read_exact(common_h as usize)?;
            let (addr, refcnt, size) = unpack_common(common, c.big_endian, c.ptr_len, c.uint_len)?;
            let mut common_ptrs = Vec::new();
            for _ in 0..common_np {
                common_ptrs.push(c.ptr()?);
            }
            for _ in 0..common_ns {
                let _ = c.str_bytes()?;
            }
            let blessed_at = common_ptrs.first().copied().unwrap_or(0);

            let type_idx = type_code as usize;
            let (th, tnp, tns) = if type_idx < sv_sizes.len() {
                sv_sizes[type_idx]
            } else {
                return Err(format!("type {type_code} out of size table"));
            };

            let type_header = c.read_exact(th as usize)?.to_vec();
            let mut type_ptrs = Vec::new();
            for _ in 0..tnp {
                type_ptrs.push(c.ptr()?);
            }
            let mut type_strs = Vec::new();
            for _ in 0..tns {
                type_strs.push(c.str_bytes()?);
            }

            let id = objects.len() as ObjectId;
            let body_pos = c.pos;

            let mut obj = Object {
                addr,
                type_code,
                refcnt,
                size,
                blessed_at,
                header: type_header.clone(),
                ptrs: type_ptrs.clone(),
                strs: type_strs.clone(),
                ..Default::default()
            };
            objects.push(obj);
            addr_to_id.insert(addr, id);
            type_counts[type_code as usize] += 1;

            if blessed_at != 0 {
                pending.push(PendingEdge {
                    from: id,
                    to_addr: blessed_at,
                    strength: Strength::Weak,
                });
            }

            // Type-specific bodies + structural edges
            match type_code {
                1 => {
                    // GLOB ptrs: stash, scalar, array, hash, code, egv, io, form
                    // Match Devel::MAT::SV::GLOB::_outrefs (0.54):
                    //   strong: scalar, array, hash, code, io, form
                    //   egv: weak if self, else strong
                    //   stash: not emitted as a direct outref
                    let slots_strong = [1usize, 2, 3, 4, 6, 7]; // scalar..code, io, form
                    for &idx in &slots_strong {
                        if let Some(&p) = type_ptrs.get(idx) {
                            if p != 0 {
                                pending.push(PendingEdge {
                                    from: id,
                                    to_addr: p,
                                    strength: Strength::Strong,
                                });
                            }
                        }
                    }
                    if let Some(&egv) = type_ptrs.get(5) {
                        if egv != 0 {
                            let strength = if egv == addr {
                                Strength::Weak
                            } else {
                                Strength::Strong
                            };
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: egv,
                                strength,
                            });
                        }
                    }
                }
                2 => {
                    // SCALAR: ourstash
                    for &p in &type_ptrs {
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
                    let _ = type_header;
                    let _ = type_strs;
                }
                3 => {
                    // REF: flags in header; ptrs rv, ourstash
                    let flags = type_header.first().copied().unwrap_or(0);
                    let weak = flags & 0x01 != 0;
                    if let Some(&rv) = type_ptrs.first() {
                        if rv != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: rv,
                                strength: if weak {
                                    Strength::Weak
                                } else {
                                    Strength::Strong
                                },
                            });
                        }
                    }
                    if let Some(&stash) = type_ptrs.get(1) {
                        if stash != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: stash,
                                strength: Strength::Strong,
                            });
                        }
                    }
                }
                4 => {
                    // ARRAY body: COUNT ptrs; flags may follow count in header
                    let n = unpack_uint(&type_header, c.big_endian, c.uint_len)? as usize;
                    let flags = if type_header.len() > c.uint_len {
                        type_header[c.uint_len]
                    } else {
                        0
                    };
                    if n > c.remaining() / c.ptr_len.max(1) + 1 {
                        return Err(format!(
                            "ARRAY count {n} looks corrupt (type={type_code} id={id} pos={body_pos})"
                        ));
                    }
                    objects[id as usize].array_flags = flags;
                    // Match Devel::MAT::SV::ARRAY::_outrefs (0.54):
                    // AvREAL unset (flags 0x01 = not REAL / is_unreal) → weak elems;
                    // AvREAL set → strong elems (contribute to SvREFCNT).
                    let elem_strength = if (flags & 0x01) != 0 {
                        Strength::Weak
                    } else {
                        Strength::Strong
                    };
                    let mut elems = Vec::with_capacity(n);
                    for _ in 0..n {
                        let elem = c.ptr()?;
                        elems.push(elem);
                        if elem != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: elem,
                                strength: elem_strength,
                            });
                        }
                    }
                    objects[id as usize].elems = elems;
                }
                5 | 6 | 17 => {
                    // HASH / STASH / CLASS: body keys
                    let n = unpack_uint(&type_header, c.big_endian, c.uint_len)? as usize;
                    let has_hek = format_minor >= 6;
                    for &p in &type_ptrs {
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
                    // STASH/CLASS: ptrs after HASH backrefs are MRO; strs include name
                    if type_code == 6 || type_code == 17 {
                        // HASH uses 1 ptr (backrefs); remaining ptrs are MRO
                        if type_ptrs.len() > 1 {
                            objects[id as usize].mro_ptrs = type_ptrs[1..].to_vec();
                        }
                        if let Some(name) = type_strs.first() {
                            objects[id as usize].stash_name = name.clone();
                        }
                    }
                    let mut entries = Vec::with_capacity(n);
                    for i in 0..n {
                        let key = c.str_bytes().map_err(|e| {
                            format!(
                                "hash key {i}/{n}: {e} (type={type_code} id={id} addr={addr:#x} body_pos={body_pos} now={})",
                                c.pos
                            )
                        })?;
                        let hek = if has_hek { c.ptr()? } else { 0 };
                        let val = c.ptr()?;
                        if val != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: val,
                                strength: Strength::Strong,
                            });
                        }
                        entries.push(HashEntry { key, hek, value: val });
                    }
                    objects[id as usize].hash_entries = entries;
                    // CLASS has trailing CLASSx tags until 0 (see SV::CLASS::load)
                    if type_code == 17 {
                        loop {
                            let bt = c.u8()?;
                            if bt == 0 {
                                break;
                            }
                            if bt == 1 {
                                let fieldix = c.uint()?;
                                let name = c.str_bytes()?;
                                objects[id as usize].class_fields.push((fieldix, name));
                            } else {
                                return Err(format!(
                                    "unknown CLASSx tag {bt} (id={id} addr={addr:#x})"
                                ));
                            }
                        }
                    }
                }
                7 => {
                    // CODE: ptrs + body of CONSTSV etc until type 0
                    // Header: UINT LINE, U8 FLAGS, PTR OPROOT, U32 DEPTH, PTR NAME_HEK
                    // FLAGS: 0x08 WEAKOUTSIDE, 0x10 CVGV_RC (see format.txt / SV::CODE)
                    let code_flags = {
                        let th = &type_header;
                        let mut off = c.uint_len; // skip LINE
                        if th.len() > off {
                            th[off]
                        } else {
                            0
                        }
                    };
                    let weak_outside = (code_flags & 0x08) != 0;
                    let strong_gv = (code_flags & 0x10) != 0;
                    // PTRs: STASH, GLOB, OUTSIDE, PADLIST, CONSTVAL — 0.54 strengths
                    let ptr_strengths = [
                        Strength::Weak,                                   // STASH
                        if strong_gv { Strength::Strong } else { Strength::Weak }, // GLOB
                        if weak_outside { Strength::Weak } else { Strength::Strong }, // OUTSIDE
                        Strength::Strong,                                  // PADLIST
                        Strength::Strong,                                  // CONSTVAL
                    ];
                    for (i, &p) in type_ptrs.iter().enumerate() {
                        if p != 0 {
                            let strength = ptr_strengths.get(i).copied().unwrap_or(Strength::Strong);
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength,
                            });
                        }
                    }
                    // ithreads: constants/gvs are indirect; else strong (0.54 _outrefs)
                    let const_gv_strength = if ithreads {
                        Strength::Indirect
                    } else {
                        Strength::Strong
                    };
                    // Padnames/pads: indirect if PADLIST present, else strong
                    let have_padlist = type_ptrs.get(3).copied().unwrap_or(0) != 0;
                    let pad_strength = if have_padlist {
                        Strength::Indirect
                    } else {
                        Strength::Strong
                    };
                    loop {
                        let bt = c.u8()?;
                        if bt == 0 {
                            break;
                        }
                        match bt {
                            1 => {
                                let p = c.ptr()?;
                                objects[id as usize].code_consts.push(p);
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: const_gv_strength,
                                    });
                                }
                            }
                            2 => {
                                objects[id as usize].code_constix.push(c.uint()?);
                            }
                            3 => {
                                let p = c.ptr()?;
                                objects[id as usize].code_gvs.push(p);
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: const_gv_strength,
                                    });
                                }
                            }
                            4 => {
                                objects[id as usize].code_gvix.push(c.uint()?);
                            }
                            5 => {
                                let padix = c.uint()? as u32;
                                let name = c.str_bytes()?;
                                let p = c.ptr()?;
                                objects[id as usize].code_padnames.push(CodePadname {
                                    padix,
                                    name,
                                    ourstash: p,
                                    flags: 0,
                                    fieldix: 0,
                                    fieldstash: 0,
                                });
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            6 => {
                                let _ = c.uint()?;
                                let _ = c.uint()?;
                                let p = c.ptr()?;
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            7 => {
                                let p = c.ptr()?;
                                objects[id as usize].code_padnames_at = p;
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: pad_strength,
                                    });
                                }
                            }
                            8 => {
                                let depth = c.uint()? as u32;
                                let p = c.ptr()?;
                                objects[id as usize].code_pads.push((depth, p));
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: pad_strength,
                                    });
                                }
                            }
                            9 => {
                                let padix = c.uint()? as u32;
                                let flags = c.u8()?;
                                if let Some(pn) = objects[id as usize]
                                    .code_padnames
                                    .iter_mut()
                                    .find(|p| p.padix == padix)
                                {
                                    pn.flags = flags as u16;
                                } else {
                                    objects[id as usize].code_padnames.push(CodePadname {
                                        padix,
                                        name: Vec::new(),
                                        ourstash: 0,
                                        flags: flags as u16,
                                        fieldix: 0,
                                        fieldstash: 0,
                                    });
                                }
                            }
                            10 => {
                                let padix = c.uint()? as u32;
                                let fieldix = c.uint()?;
                                let p = c.ptr()?;
                                if let Some(pn) = objects[id as usize]
                                    .code_padnames
                                    .iter_mut()
                                    .find(|x| x.padix == padix)
                                {
                                    pn.flags |= 0x100;
                                    pn.fieldix = fieldix;
                                    pn.fieldstash = p;
                                }
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            _ => {
                                return Err(format!("unknown CODE body tag {bt}"));
                            }
                        }
                    }
                }
                8 => {
                    // IO
                    if type_header.len() >= c.uint_len * 2 {
                        objects[id as usize].io_ifileno =
                            unpack_uint(&type_header[0..c.uint_len], c.big_endian, c.uint_len)?;
                        objects[id as usize].io_ofileno = unpack_uint(
                            &type_header[c.uint_len..c.uint_len * 2],
                            c.big_endian,
                            c.uint_len,
                        )?;
                    }
                    for &p in &type_ptrs {
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
                }
                9 => {
                    // LVALUE
                    for &p in &type_ptrs {
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
                }
                16 => {
                    // OBJECT: UINT COUNT in header + COUNT field ptrs
                    let n = unpack_uint(&type_header, c.big_endian, c.uint_len)? as usize;
                    let mut fields = Vec::with_capacity(n);
                    for _ in 0..n {
                        let p = c.ptr()?;
                        fields.push(p);
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
                    objects[id as usize].object_fields = fields.clone();
                    objects[id as usize].elems = fields;
                }
                0x7F => {
                    // STRUCT: fields by meta — ptr fields only known via meta types;
                    // type header already consumed; field values follow based on meta.
                    // Without resolving meta here, skip is unsafe. 0.54 dumps may include
                    // few structs; try reading remaining as raw if nfields known from header.
                    // Header for STRUCT is empty in sizes; structid in core fields?
                    // See format: STRUCT has structid in load via sv->structid.
                    // For safety, leave payload empty (no extra body if nfields handled elsewhere).
                }
                _ => {
                    // REGEXP, FORMAT, INVLIST, UNDEF, YES, NO: no extra body
                    for &p in &type_ptrs {
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
                }
            }
        }

        // Contexts
        let mut contexts: Vec<ContextRec> = Vec::new();
        if format_minor >= 2 && !ctx_sizes.is_empty() {
            let (ch, cnp, cns) = ctx_sizes[0];
            loop {
                let ctype = c.u8()?;
                if ctype == 0 {
                    break;
                }
                let common_header = c.read_exact(ch as usize)?.to_vec();
                let mut common_ptrs = Vec::new();
                for _ in 0..cnp {
                    common_ptrs.push(c.ptr()?);
                }
                let mut common_strs = Vec::new();
                for _ in 0..cns {
                    common_strs.push(c.str_bytes()?);
                }
                let mut type_header = Vec::new();
                let mut type_ptrs = Vec::new();
                let mut type_strs = Vec::new();
                if (ctype as usize) < ctx_sizes.len() {
                    let (th, tnp, tns) = ctx_sizes[ctype as usize];
                    type_header = c.read_exact(th as usize)?.to_vec();
                    for _ in 0..tnp {
                        type_ptrs.push(c.ptr()?);
                    }
                    for _ in 0..tns {
                        type_strs.push(c.str_bytes()?);
                    }
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
        }

        // Mortals (optional trailing)
        let mut mortals: Vec<u64> = Vec::new();
        let mut mortal_floor: u64 = 0;
        if c.remaining() >= c.uint_len {
            let mortalcount = c.uint()? as usize;
            if mortalcount > 0 {
                for _ in 0..mortalcount {
                    mortals.push(c.ptr()?);
                }
                if c.remaining() >= c.uint_len {
                    mortal_floor = c.uint()?;
                }
            }
        }

        // File-heap object count (before synthetic immortals).
        let heap_count = objects.len() as u32;

        // Register immortal undef/yes/no for edge resolution if not already on heap.
        // 0.54 keeps these outside the heap hash but resolves them via sv_at.
        for (addr, type_code) in [
            (undef_at, 13u8),
            (yes_at, 14u8),
            (no_at, 15u8),
        ] {
            if addr != 0 && !addr_to_id.contains_key(&addr) {
                let id = objects.len() as ObjectId;
                objects.push(Object {
                    addr,
                    type_code,
                    refcnt: 1,
                    size: 0,
                    blessed_at: 0,
                    ..Default::default()
                });
                addr_to_id.insert(addr, id);
                // Do not increment type_counts — these are synthetic placeholders.
            }
        }

        // Resolve edges + build CSR (includes edges into immortals).
        let n = objects.len();
        let mut fwd_lists: Vec<Vec<Edge>> = vec![Vec::new(); n];
        for pe in pending {
            if let Some(&tid) = addr_to_id.get(&pe.to_addr) {
                if (pe.from as usize) < n {
                    fwd_lists[pe.from as usize].push(Edge {
                        target: tid,
                        strength: pe.strength,
                    });
                }
            }
        }

        let mut forward_off = Vec::with_capacity(n + 1);
        let mut forward_edges = Vec::new();
        forward_off.push(0);
        for list in &fwd_lists {
            forward_edges.extend(list.iter().cloned());
            forward_off.push(forward_edges.len() as u32);
        }

        let mut rev_lists: Vec<Vec<Edge>> = vec![Vec::new(); n];
        for (from, list) in fwd_lists.iter().enumerate() {
            for e in list {
                rev_lists[e.target as usize].push(Edge {
                    target: from as ObjectId,
                    strength: e.strength,
                });
            }
        }
        let mut reverse_off = Vec::with_capacity(n + 1);
        let mut reverse_edges = Vec::new();
        reverse_off.push(0);
        for list in &rev_lists {
            reverse_edges.extend(list.iter().cloned());
            reverse_off.push(reverse_edges.len() as u32);
        }

        Ok(Dump {
            format_minor,
            perlver,
            ithreads,
            big_endian: c.big_endian,
            uint_len: c.uint_len,
            ptr_len: c.ptr_len,
            nv_len: c.nv_len,
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

    pub fn outrefs(&self, id: ObjectId) -> &[Edge] {
        let i = id as usize;
        if i + 1 >= self.forward_off.len() {
            return &[];
        }
        let a = self.forward_off[i] as usize;
        let b = self.forward_off[i + 1] as usize;
        &self.forward_edges[a..b]
    }

    pub fn inrefs(&self, id: ObjectId) -> &[Edge] {
        let i = id as usize;
        if i + 1 >= self.reverse_off.len() {
            return &[];
        }
        let a = self.reverse_off[i] as usize;
        let b = self.reverse_off[i + 1] as usize;
        &self.reverse_edges[a..b]
    }

    /// Strong exclusive children (CSR): non-immortal refcnt==1 strong outrefs.
    /// Same filter as classic `_owned_children` / historic owned_set walk.
    pub fn exclusive_kids(&self) -> Vec<Vec<u32>> {
        let n = self.heap_count as usize;
        let mut kids: Vec<Vec<u32>> = vec![Vec::new(); n];
        for id in 0..n {
            for e in self.outrefs(id as ObjectId) {
                if e.strength != Strength::Strong {
                    continue;
                }
                let t = e.target as usize;
                if t >= n {
                    continue;
                }
                let obj = &self.objects[t];
                if obj.refcnt != 1 {
                    continue;
                }
                // UNDEF/YES/NO type codes (immortal placeholders)
                if matches!(obj.type_code, 13 | 14 | 15) {
                    continue;
                }
                kids[id].push(e.target);
            }
        }
        kids
    }

    /// Worker count for parallel owned scoring.
    /// `PMAT_OWNED_THREADS=N` forces N (min 1); unset → available_parallelism.
    pub fn owned_thread_count() -> usize {
        if let Ok(v) = std::env::var("PMAT_OWNED_THREADS") {
            if let Ok(n) = v.parse::<usize>() {
                return n.max(1);
            }
        }
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
            .max(1)
    }

    /// Classic %seen owned_size for every heap ObjectId (not child-sum DP).
    /// Exclusive children: strong CSR outrefs to non-immortal refcnt==1 targets.
    /// Only `heap_count` real heap objects are included (not synthetic immortals).
    /// Independent root walks are parallelized across CPU cores (per-worker seen).
    pub fn owned_sizes(&self) -> Vec<u64> {
        let kids = self.exclusive_kids();
        self.owned_sizes_with_kids(&kids)
    }

    pub fn owned_sizes_with_kids(&self, kids: &[Vec<u32>]) -> Vec<u64> {
        let n = self.heap_count as usize;
        if n == 0 {
            return Vec::new();
        }
        let threads = Self::owned_thread_count().min(n);
        if threads <= 1 {
            return self.owned_sizes_range(kids, 0, n);
        }

        let mut owned = vec![0u64; n];
        let chunk = (n + threads - 1) / threads;
        // Split into non-overlapping mutable subslices (no aliasing UB).
        let objects = &self.objects;
        std::thread::scope(|scope| {
            let mut rest: &mut [u64] = &mut owned[..];
            let mut base = 0usize;
            for t in 0..threads {
                let start = t * chunk;
                let end = ((t + 1) * chunk).min(n);
                if start >= end {
                    continue;
                }
                debug_assert_eq!(base, start);
                let take = end - start;
                let (mine, tail) = rest.split_at_mut(take);
                rest = tail;
                base = end;
                let kids = kids;
                scope.spawn(move || {
                    let mut seen = vec![0u32; n];
                    let mut gen: u32 = 0;
                    for (local_i, out_slot) in mine.iter_mut().enumerate() {
                        let s = start + local_i;
                        gen = gen.wrapping_add(1);
                        if gen == 0 {
                            seen.fill(0);
                            gen = 1;
                        }
                        let mut total = 0u64;
                        let mut stack = vec![s as u32];
                        while let Some(id) = stack.pop() {
                            let i = id as usize;
                            if seen[i] == gen {
                                continue;
                            }
                            seen[i] = gen;
                            total = total.saturating_add(objects[i].size);
                            stack.extend_from_slice(&kids[i]);
                        }
                        *out_slot = total;
                    }
                });
            }
        });
        owned
    }

    fn owned_sizes_range(&self, kids: &[Vec<u32>], start: usize, end: usize) -> Vec<u64> {
        let n = self.heap_count as usize;
        let mut owned = vec![0u64; n];
        let mut seen = vec![0u32; n];
        let mut gen: u32 = 0;
        for s in start..end {
            gen = gen.wrapping_add(1);
            if gen == 0 {
                seen.fill(0);
                gen = 1;
            }
            let mut total = 0u64;
            let mut stack = vec![s as u32];
            while let Some(id) = stack.pop() {
                let i = id as usize;
                if seen[i] == gen {
                    continue;
                }
                seen[i] = gen;
                total = total.saturating_add(self.objects[i].size);
                stack.extend_from_slice(&kids[i]);
            }
            owned[s] = total;
        }
        owned
    }

    /// Top-K roots by owned size (score desc, addr asc). Returns (id, addr, score).
    pub fn owned_topk(&self, k: usize) -> Vec<(u32, u64, u64)> {
        if k == 0 {
            return Vec::new();
        }
        let kids = self.exclusive_kids();
        let owned = self.owned_sizes_with_kids(&kids);
        self.topk_from_owned(&owned, k)
    }

    fn topk_from_owned(&self, owned: &[u64], k: usize) -> Vec<(u32, u64, u64)> {
        let n = owned.len().min(self.heap_count as usize);
        if k == 0 || n == 0 {
            return Vec::new();
        }
        // Min-heap of size k via sorted Vec (k is tiny, e.g. 5).
        let mut best: Vec<(u64, u64, u32)> = Vec::with_capacity(k); // (score, addr, id)
        for id in 0..n {
            let score = owned[id];
            let addr = self.objects[id].addr;
            if best.len() < k {
                best.push((score, addr, id as u32));
                best.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
            } else if score > best[k - 1].0
                || (score == best[k - 1].0 && addr < best[k - 1].1)
            {
                best.pop();
                best.push((score, addr, id as u32));
                best.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
            }
        }
        best.into_iter()
            .map(|(score, addr, id)| (id, addr, score))
            .collect()
    }

    /// Among exclusive descendants of `root` (not including root), top-K by owned score.
    pub fn owned_descendants_topk(
        &self,
        root: ObjectId,
        k: usize,
        owned: &[u64],
        kids: &[Vec<u32>],
    ) -> Vec<(u32, u64, u64)> {
        let n = self.heap_count as usize;
        let r = root as usize;
        if k == 0 || r >= n {
            return Vec::new();
        }
        // Collect exclusive set (incl. root), then rank descendants only.
        let mut seen = vec![false; n];
        let mut stack = vec![root];
        let mut members: Vec<u32> = Vec::new();
        while let Some(id) = stack.pop() {
            let i = id as usize;
            if i >= n || seen[i] {
                continue;
            }
            seen[i] = true;
            members.push(id);
            stack.extend_from_slice(&kids[i]);
        }
        let mut best: Vec<(u64, u64, u32)> = Vec::with_capacity(k);
        for &id in &members {
            if id == root {
                continue;
            }
            let i = id as usize;
            let score = owned.get(i).copied().unwrap_or(0);
            let addr = self.objects[i].addr;
            if best.len() < k {
                best.push((score, addr, id));
                best.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
            } else if score > best[k - 1].0
                || (score == best[k - 1].0 && addr < best[k - 1].1)
            {
                best.pop();
                best.push((score, addr, id));
                best.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
            }
        }
        best.into_iter()
            .map(|(score, addr, id)| (id, addr, score))
            .collect()
    }

    /// Multi-level largest-owned display tree without materializing the heap.
    /// `counts` is e.g. [5, 3, 2] for roots then nested "of which" levels.
    /// Each node: (id, addr, score, depth, parent_index_in_out_or_-1).
    pub fn owned_largest_tree(&self, counts: &[usize]) -> Vec<(u32, u64, u64, u32, i32)> {
        if counts.is_empty() || counts[0] == 0 {
            return Vec::new();
        }
        let kids = self.exclusive_kids();
        let owned = self.owned_sizes_with_kids(&kids);
        let mut out: Vec<(u32, u64, u64, u32, i32)> = Vec::new();

        // Level 0: global top-K
        let roots = self.topk_from_owned(&owned, counts[0]);
        for (id, addr, score) in roots {
            out.push((id, addr, score, 0, -1));
        }

        // Deeper levels: for each node at depth d-1, expand exclusive descendants
        for depth in 1..counts.len() {
            let k = counts[depth];
            if k == 0 {
                break;
            }
            let parent_depth = (depth - 1) as u32;
            // Snapshot parent indices at this depth (out grows as we append).
            let parents: Vec<usize> = out
                .iter()
                .enumerate()
                .filter(|(_, n)| n.3 == parent_depth)
                .map(|(i, _)| i)
                .collect();
            for pi in parents {
                let root_id = out[pi].0;
                let kids_top = self.owned_descendants_topk(root_id, k, &owned, &kids);
                for (id, addr, score) in kids_top {
                    out.push((id, addr, score, depth as u32, pi as i32));
                }
            }
        }
        out
    }
}

fn unpack_common(
    bytes: &[u8],
    big_endian: bool,
    ptr_len: usize,
    uint_len: usize,
) -> Result<(u64, u32, u64), String> {
    // PTR addr, U32 refcnt, UINT size
    let mut off = 0;
    let addr = read_int(bytes, off, ptr_len, big_endian)?;
    off += ptr_len;
    let refcnt = read_int(bytes, off, 4, big_endian)? as u32;
    off += 4;
    let size = read_int(bytes, off, uint_len, big_endian)?;
    let _ = off;
    Ok((addr, refcnt, size))
}

fn unpack_uint(bytes: &[u8], big_endian: bool, uint_len: usize) -> Result<u64, String> {
    read_int(bytes, 0, uint_len, big_endian)
}

fn read_int(bytes: &[u8], off: usize, len: usize, big_endian: bool) -> Result<u64, String> {
    if bytes.len() < off + len {
        return Err("header truncated".into());
    }
    let sl = &bytes[off..off + len];
    Ok(match len {
        4 => {
            let v = if big_endian {
                u32::from_be_bytes([sl[0], sl[1], sl[2], sl[3]])
            } else {
                u32::from_le_bytes([sl[0], sl[1], sl[2], sl[3]])
            };
            v as u64
        }
        8 => {
            if big_endian {
                u64::from_be_bytes([
                    sl[0], sl[1], sl[2], sl[3], sl[4], sl[5], sl[6], sl[7],
                ])
            } else {
                u64::from_le_bytes([
                    sl[0], sl[1], sl[2], sl[3], sl[4], sl[5], sl[6], sl[7],
                ])
            }
        }
        _ => return Err(format!("bad int len {len}")),
    })
}

