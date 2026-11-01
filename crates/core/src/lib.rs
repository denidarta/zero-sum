//! Shared logic for the zero-sum budget: entity model, sync merge, budget math.
//!
//! No I/O and no clock. The server uses it directly. Clients are meant to reuse
//! it (UniFFI for iOS and Android, WASM for web) so merge and budget rules
//! exist exactly once. See `docs/architecture.md`.

pub mod budget;
pub mod json;
pub mod ledger;
pub mod model;
pub mod sync;
