//! JSON-string bindings of `zero-sum-core` for the iOS client, via UniFFI.
//!
//! Same three functions and same JSON shapes as `crates/wasm`, so the iOS app
//! runs the exact merge and budget code the server runs. Swift is generated
//! from this crate's compiled metadata, see `scripts/build-ios-core.sh`.

use serde::Serialize;
use uuid::Uuid;
use zero_sum_core::{
    budget::{compute, Snapshot},
    model::budget_entry_id as core_entry_id,
    sync::{apply, EntityState, Op},
};

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    Invalid { message: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let CoreError::Invalid { message } = self;
        f.write_str(message)
    }
}

impl std::error::Error for CoreError {}

fn err(e: impl ToString) -> CoreError {
    CoreError::Invalid {
        message: e.to_string(),
    }
}

#[derive(Serialize)]
struct Merged {
    state: EntityState,
    changed: bool,
}

/// Merge an op into an entity. `entity_json` is `null` for a new entity.
/// Returns `{state, changed}`. Fails when the op is invalid.
#[uniffi::export]
pub fn merge_op(entity_json: String, op_json: String) -> Result<String, CoreError> {
    let existing: Option<EntityState> = serde_json::from_str(&entity_json).map_err(err)?;
    let op: Op = serde_json::from_str(&op_json).map_err(err)?;
    let applied = apply(existing, &op).map_err(err)?;
    serde_json::to_string(&Merged {
        state: applied.state,
        changed: applied.changed,
    })
    .map_err(err)
}

/// Compute a budget month from a JSON array of entity states.
#[uniffi::export]
pub fn compute_budget(entities_json: String, month: String) -> Result<String, CoreError> {
    let entities: Vec<EntityState> = serde_json::from_str(&entities_json).map_err(err)?;
    let snap = Snapshot::from_entities(&entities).map_err(err)?;
    let month = compute(&snap, &month).map_err(err)?;
    serde_json::to_string(&month).map_err(err)
}

/// Deterministic id of the budget entry for a category and month.
#[uniffi::export]
pub fn budget_entry_id(category_id: String, month: String) -> Result<String, CoreError> {
    let id: Uuid = category_id.parse().map_err(err)?;
    Ok(core_entry_id(id, &month).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    const CAT: &str = "00000000-0000-4000-8000-000000000010";

    #[test]
    fn merge_creates_then_updates() {
        let op = |n: u8, ts: i64, name: &str| {
            json!({
                "op_id": format!("00000000-0000-4000-8000-0000000000{n:02}"),
                "ts": ts, "kind": "payee",
                "entity_id": "00000000-0000-4000-8000-000000000099",
                "fields": {"name": name},
            })
            .to_string()
        };
        let a: Value =
            serde_json::from_str(&merge_op("null".into(), op(1, 10, "Shop")).unwrap()).unwrap();
        assert_eq!(a["changed"], true);
        let b: Value =
            serde_json::from_str(&merge_op(a["state"].to_string(), op(2, 20, "Cafe")).unwrap())
                .unwrap();
        assert_eq!(b["state"]["data"]["name"], "Cafe");
        // Older write loses and reports unchanged.
        let c: Value =
            serde_json::from_str(&merge_op(b["state"].to_string(), op(3, 5, "Old")).unwrap())
                .unwrap();
        assert_eq!(c["changed"], false);
        assert_eq!(c["state"]["data"]["name"], "Cafe");
    }

    #[test]
    fn invalid_op_is_an_error() {
        let op = json!({
            "op_id": "00000000-0000-4000-8000-000000000001", "ts": 1, "kind": "payee",
            "entity_id": "00000000-0000-4000-8000-000000000099", "fields": {"nmae": "x"},
        });
        assert!(merge_op("null".into(), op.to_string()).is_err());
    }

    #[test]
    fn budget_and_entry_id_match_core() {
        let id = budget_entry_id(CAT.into(), "2026-10".into()).unwrap();
        assert_eq!(
            id,
            core_entry_id(CAT.parse().unwrap(), "2026-10").to_string()
        );
        let out = compute_budget("[]".into(), "2026-10".into()).unwrap();
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ready_to_assign"], 0);
        assert!(compute_budget("[]".into(), "2026-13".into()).is_err());
    }
}
