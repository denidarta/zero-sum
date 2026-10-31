//! JSON-string bindings of `zero-sum-core` for the web client.
//!
//! The web client runs the exact same merge and budget code as the server, so
//! the numbers on screen match the numbers the server computes. Each function
//! takes and returns JSON text to keep the boundary trivial.

use serde::Serialize;
use uuid::Uuid;
use wasm_bindgen::prelude::*;
use zero_sum_core::{
    budget::{compute, Snapshot},
    model::budget_entry_id,
    sync::{apply, EntityState, Op},
};

fn err(e: impl ToString) -> JsError {
    JsError::new(&e.to_string())
}

#[derive(Serialize)]
struct Merged {
    state: EntityState,
    changed: bool,
}

/// Merge an op into an entity. `entity_json` is `null` for a new entity.
/// Returns `{state, changed}`. Throws when the op is invalid.
#[wasm_bindgen]
pub fn merge(entity_json: &str, op_json: &str) -> Result<String, JsError> {
    let existing: Option<EntityState> = serde_json::from_str(entity_json).map_err(err)?;
    let op: Op = serde_json::from_str(op_json).map_err(err)?;
    let applied = apply(existing, &op).map_err(err)?;
    serde_json::to_string(&Merged {
        state: applied.state,
        changed: applied.changed,
    })
    .map_err(err)
}

/// Compute a budget month from a JSON array of entity states.
#[wasm_bindgen]
pub fn budget(entities_json: &str, month: &str) -> Result<String, JsError> {
    let entities: Vec<EntityState> = serde_json::from_str(entities_json).map_err(err)?;
    let snap = Snapshot::from_entities(&entities).map_err(err)?;
    let month = compute(&snap, month).map_err(err)?;
    serde_json::to_string(&month).map_err(err)
}

/// Deterministic id of the budget entry for a category and month.
#[wasm_bindgen]
pub fn entry_id(category_id: &str, month: &str) -> Result<String, JsError> {
    let id: Uuid = category_id.parse().map_err(err)?;
    Ok(budget_entry_id(id, month).to_string())
}
