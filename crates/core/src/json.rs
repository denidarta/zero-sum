//! JSON-string entry points shared by every binding crate (`wasm`, `ffi-uniffi`).
//!
//! Each takes and returns JSON text so the language boundary stays trivial. The
//! bindings only convert the `String` error into their platform's error type.

use crate::{
    budget::{compute, Snapshot},
    ledger::{self, Command},
    model::budget_entry_id,
    sync::{apply, EntityState, Op},
};
use serde::Serialize;
use uuid::Uuid;

#[derive(Serialize)]
struct Merged {
    state: EntityState,
    changed: bool,
}

fn err(e: impl ToString) -> String {
    e.to_string()
}

/// Merge an op into an entity. `entity_json` is `null` for a new entity.
/// Returns `{state, changed}`. Fails when the op is invalid.
pub fn merge(entity_json: &str, op_json: &str) -> Result<String, String> {
    let existing: Option<EntityState> = serde_json::from_str(entity_json).map_err(err)?;
    let op: Op = serde_json::from_str(op_json).map_err(err)?;
    let applied = apply(existing, &op)?;
    serde_json::to_string(&Merged {
        state: applied.state,
        changed: applied.changed,
    })
    .map_err(err)
}

/// Compute a budget month from a JSON array of entity states.
pub fn budget(entities_json: &str, month: &str) -> Result<String, String> {
    let entities: Vec<EntityState> = serde_json::from_str(entities_json).map_err(err)?;
    let snap = Snapshot::from_entities(&entities)?;
    serde_json::to_string(&compute(&snap, month)?).map_err(err)
}

/// Turn a ledger action (see [`Command`]) into a JSON array of patches
/// `{kind, id, fields, deleted}` over a JSON array of entity states.
/// The error text is fit to show to the user.
pub fn plan(entities_json: &str, command_json: &str) -> Result<String, String> {
    let entities: Vec<EntityState> = serde_json::from_str(entities_json).map_err(err)?;
    let command: Command = serde_json::from_str(command_json).map_err(err)?;
    serde_json::to_string(&ledger::plan(&entities, &command)?).map_err(err)
}

/// Deterministic id of the budget entry for a category and month.
pub fn entry_id(category_id: &str, month: &str) -> Result<String, String> {
    let id: Uuid = category_id.parse().map_err(err)?;
    Ok(budget_entry_id(id, month).to_string())
}

#[cfg(test)]
mod tests;
