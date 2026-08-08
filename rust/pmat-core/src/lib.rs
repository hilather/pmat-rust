//! pmat-core: dense PMAT dump model + panic-safe C ABI.
//! Format reference: repo `doc/format.txt` (Devel-MAT 0.54, minor ≤ 6).

mod ffi;
mod index;
mod parse;

pub use ffi::*;
pub use index::{
    content_digest, index_enabled_from_env, index_path_for, last_load_used_index,
    load_path_with_index, should_use_index, try_load_index, write_index, IndexOpenOutcome,
    DEFAULT_IDX_MIN_BYTES, SCHEMA_VERSION,
};
pub use parse::{Dump, Edge, Object, Strength, TYPE_NAMES};

/// Crate version exposed to FFI.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
