//! JSON-string entry points shared by every binding crate (`wasm`, `ffi-uniffi`).
//!
//! Each takes and returns JSON text so the language boundary stays trivial. The
//! bindings only convert the `String` error into their platform's error type.

use crate::{
    budget::{compute, Snapshot},
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

/// Deterministic id of the budget entry for a category and month.
pub fn entry_id(category_id: &str, month: &str) -> Result<String, String> {
    let id: Uuid = category_id.parse().map_err(err)?;
    Ok(budget_entry_id(id, month).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    const CAT: &str = "00000000-0000-4000-8000-000000000010";

    fn op(n: u8, ts: i64, name: &str) -> String {
        json!({
            "op_id": format!("00000000-0000-4000-8000-0000000000{n:02}"),
            "ts": ts, "kind": "payee",
            "entity_id": "00000000-0000-4000-8000-000000000099",
            "fields": {"name": name},
        })
        .to_string()
    }

    fn parse(s: String) -> Value {
        serde_json::from_str(&s).unwrap()
    }

    #[test]
    fn merge_creates_then_updates() {
        let a = parse(merge("null", &op(1, 10, "Shop")).unwrap());
        assert_eq!(a["changed"], true);
        let b = parse(merge(&a["state"].to_string(), &op(2, 20, "Cafe")).unwrap());
        assert_eq!(b["state"]["data"]["name"], "Cafe");
        // Older write loses and reports unchanged.
        let c = parse(merge(&b["state"].to_string(), &op(3, 5, "Old")).unwrap());
        assert_eq!(c["changed"], false);
        assert_eq!(c["state"]["data"]["name"], "Cafe");
    }

    #[test]
    fn invalid_op_is_an_error() {
        let bad = json!({
            "op_id": "00000000-0000-4000-8000-000000000001", "ts": 1, "kind": "payee",
            "entity_id": "00000000-0000-4000-8000-000000000099", "fields": {"nmae": "x"},
        });
        assert!(merge("null", &bad.to_string()).is_err());
    }

    #[test]
    fn budget_and_entry_id() {
        let id = entry_id(CAT, "2026-10").unwrap();
        assert_eq!(
            id,
            budget_entry_id(CAT.parse().unwrap(), "2026-10").to_string()
        );
        assert!(entry_id("nope", "2026-10").is_err());
        let v = parse(budget("[]", "2026-10").unwrap());
        assert_eq!(v["ready_to_assign"], 0);
        assert!(budget("[]", "2026-13").is_err());
    }
}
