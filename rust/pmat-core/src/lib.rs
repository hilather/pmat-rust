//! pmat-core: dense PMAT dump model + panic-safe C ABI.
//! Format reference: repo `doc/format.txt` (Devel-MAT 0.54, minor ≤ 6).

mod ffi;
mod parse;

pub use ffi::*;
pub use parse::{Dump, Edge, Object, Strength, TYPE_NAMES};

/// Crate version exposed to FFI.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
