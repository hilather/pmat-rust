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

#[derive(Clone, Debug)]
pub struct Object {
    pub addr: u64,
    pub type_code: u8,
    pub refcnt: u32,
    pub size: u64,
    pub blessed_at: u64,
}

#[derive(Clone, Debug)]
pub struct Root {
    pub name: Vec<u8>,
    pub addr: u64,
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
    pub fn load_path(path: &Path) -> Result<Self, String> {
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
                for _ in 0..ns {
                    let _ = c.str_bytes()?;
                }
                // Note: from may not be in addr_to_id yet if extension appears before
                // the SV in rare order — queue stores from_addr and resolve later.
                // Here SV is typically already present (extensions follow their SV).
                if let Some(&from) = addr_to_id.get(&sv_addr) {
                    if type_code == 0x80 {
                        // MAGIC: bytes = [type_char, flags], ptrs = [obj, ptr, vtbl]
                        // 0.54: obj is strong iff flags&0x01 (MGf_REFCOUNTED), else weak;
                        //       ptr is strong when present.
                        let flags = _bytes.get(1).copied().unwrap_or(0);
                        if let Some(&obj) = ext_ptrs.first() {
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
                        }
                        if let Some(&mptr) = ext_ptrs.get(1) {
                            if mptr != 0 {
                                pending.push(PendingEdge {
                                    from,
                                    to_addr: mptr,
                                    strength: Strength::Strong,
                                });
                            }
                        }
                        // vtbl is not an SV edge
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

            objects.push(Object {
                addr,
                type_code,
                refcnt,
                size,
                blessed_at,
            });
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
                    // ARRAY body: COUNT ptrs
                    let n = unpack_uint(&type_header, c.big_endian, c.uint_len)? as usize;
                    if n > c.remaining() / c.ptr_len.max(1) + 1 {
                        return Err(format!(
                            "ARRAY count {n} looks corrupt (type={type_code} id={id} pos={body_pos})"
                        ));
                    }
                    for _ in 0..n {
                        let elem = c.ptr()?;
                        if elem != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: elem,
                                strength: Strength::Strong,
                            });
                        }
                    }
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
                    for i in 0..n {
                        let _key = c.str_bytes().map_err(|e| {
                            format!(
                                "hash key {i}/{n}: {e} (type={type_code} id={id} addr={addr:#x} body_pos={body_pos} now={})",
                                c.pos
                            )
                        })?;
                        if has_hek {
                            let _hek = c.ptr()?;
                        }
                        let val = c.ptr()?;
                        if val != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: val,
                                strength: Strength::Strong,
                            });
                        }
                    }
                    // CLASS has trailing CLASSx tags until 0 (see SV::CLASS::load)
                    if type_code == 17 {
                        loop {
                            let bt = c.u8()?;
                            if bt == 0 {
                                break;
                            }
                            if bt == 1 {
                                // FIELD: fieldix + name
                                let _fieldix = c.uint()?;
                                let _name = c.str_bytes()?;
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
                    for &p in &type_ptrs {
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
                    // CODEx body tags mirror Devel::MAT::SV::CODE::load (0.54)
                    loop {
                        let bt = c.u8()?;
                        if bt == 0 {
                            break;
                        }
                        match bt {
                            1 => {
                                // CONSTSV
                                let p = c.ptr()?;
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            2 => {
                                // CONSTIX
                                let _ = c.uint()?;
                            }
                            3 => {
                                // GVSV
                                let p = c.ptr()?;
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            4 => {
                                // GVIX
                                let _ = c.uint()?;
                            }
                            5 => {
                                // PADNAME at padix: str name + ptr ourstash
                                let _padix = c.uint()?;
                                let _name = c.str_bytes()?;
                                let p = c.ptr()?;
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            6 => {
                                // legacy padsvs: uint, uint, ptr
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
                                // PADNAMES ptr
                                let p = c.ptr()?;
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            8 => {
                                // PAD at depth
                                let _depth = c.uint()?;
                                let p = c.ptr()?;
                                if p != 0 {
                                    pending.push(PendingEdge {
                                        from: id,
                                        to_addr: p,
                                        strength: Strength::Strong,
                                    });
                                }
                            }
                            9 => {
                                // PADNAME_FLAGS
                                let _padix = c.uint()?;
                                let _flags = c.u8()?;
                            }
                            10 => {
                                // PADNAME_FIELD
                                let _padix = c.uint()?;
                                let _fieldix = c.uint()?;
                                let p = c.ptr()?;
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
                8 | 9 => {
                    // IO / LVALUE
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
                    for _ in 0..n {
                        let p = c.ptr()?;
                        if p != 0 {
                            pending.push(PendingEdge {
                                from: id,
                                to_addr: p,
                                strength: Strength::Strong,
                            });
                        }
                    }
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
        if format_minor >= 2 && !ctx_sizes.is_empty() {
            let (ch, cnp, cns) = ctx_sizes[0];
            loop {
                let ctype = c.u8()?;
                if ctype == 0 {
                    break;
                }
                let _ = c.read_exact(ch as usize)?;
                for _ in 0..cnp {
                    let _ = c.ptr()?;
                }
                for _ in 0..cns {
                    let _ = c.str_bytes()?;
                }
                if (ctype as usize) < ctx_sizes.len() {
                    let (th, tnp, tns) = ctx_sizes[ctype as usize];
                    let _ = c.read_exact(th as usize)?;
                    for _ in 0..tnp {
                        let _ = c.ptr()?;
                    }
                    for _ in 0..tns {
                        let _ = c.str_bytes()?;
                    }
                }
            }
        }

        // Mortals (optional trailing)
        if c.remaining() >= c.uint_len {
            let mortalcount = c.uint()? as usize;
            if mortalcount > 0 {
                for _ in 0..mortalcount {
                    let _ = c.ptr()?;
                }
                if c.remaining() >= c.uint_len {
                    let _floor = c.uint()?;
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

