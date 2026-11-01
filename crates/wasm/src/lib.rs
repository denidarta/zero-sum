//! JSON-string bindings of `zero-sum-core` for the web client.
//!
//! Thin wrappers over `zero_sum_core::json`. The web client runs the exact same
//! merge and budget code as the server, so the numbers on screen match the
//! numbers the server computes.

use wasm_bindgen::prelude::*;
use zero_sum_core::json;

fn err(e: String) -> JsError {
    JsError::new(&e)
}

/// Merge an op into an entity. `entity_json` is `null` for a new entity.
/// Returns `{state, changed}`. Throws when the op is invalid.
#[wasm_bindgen]
pub fn merge(entity_json: &str, op_json: &str) -> Result<String, JsError> {
    json::merge(entity_json, op_json).map_err(err)
}

/// Compute a budget month from a JSON array of entity states.
#[wasm_bindgen]
pub fn budget(entities_json: &str, month: &str) -> Result<String, JsError> {
    json::budget(entities_json, month).map_err(err)
}

/// Deterministic id of the budget entry for a category and month.
#[wasm_bindgen]
pub fn entry_id(category_id: &str, month: &str) -> Result<String, JsError> {
    json::entry_id(category_id, month).map_err(err)
}

/// Turn a ledger action into entity patches. Throws a user-facing message when it is not allowed.
#[wasm_bindgen]
pub fn plan(entities_json: &str, command_json: &str) -> Result<String, JsError> {
    json::plan(entities_json, command_json).map_err(err)
}
