//! JSON-text entry points to merge and budget math.
//!
//! Every binding (WASM, C ABI, UniFFI) takes and returns JSON text. The glue
//! lives here once so the bindings stay thin and cannot drift apart.

use crate::{
    budget::{compute, Snapshot},
    model::budget_entry_id,
    sync::{apply, EntityState, Op},
};
use serde::Serialize;
use uuid::Uuid;

fn de<T: serde::de::DeserializeOwned>(s: &str) -> Result<T, String> {
    serde_json::from_str(s).map_err(|e| e.to_string())
}

fn ser(v: &impl Serialize) -> Result<String, String> {
    serde_json::to_string(v).map_err(|e| e.to_string())
}

#[derive(Serialize)]
struct Merged {
    state: EntityState,
    changed: bool,
}

/// Merge an op into an entity. `entity_json` is `null` for a new entity.
/// Returns `{"state": EntityState, "changed": bool}`.
pub fn merge(entity_json: &str, op_json: &str) -> Result<String, String> {
    let a = apply(de::<Option<EntityState>>(entity_json)?, &de::<Op>(op_json)?)?;
    ser(&Merged {
        state: a.state,
        changed: a.changed,
    })
}

/// Compute a budget month from a JSON array of entity states.
pub fn budget(entities_json: &str, month: &str) -> Result<String, String> {
    let entities: Vec<EntityState> = de(entities_json)?;
    ser(&compute(&Snapshot::from_entities(&entities)?, month)?)
}

/// Deterministic id of the budget entry for a category and month.
pub fn entry_id(category_id: &str, month: &str) -> Result<String, String> {
    let id: Uuid = category_id
        .parse()
        .map_err(|e: uuid::Error| e.to_string())?;
    Ok(budget_entry_id(id, month).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn merge_budget_roundtrip() {
        let op = r#"{"op_id":"00000000-0000-4000-8000-000000000001","ts":1,"kind":"payee",
                     "entity_id":"00000000-0000-4000-8000-000000000002","fields":{"name":"Shop"}}"#;
        let r: Value = serde_json::from_str(&merge("null", op).unwrap()).unwrap();
        assert_eq!(r["changed"], true);
        assert_eq!(r["state"]["data"]["name"], "Shop");

        let b: Value = serde_json::from_str(&budget("[]", "2026-10").unwrap()).unwrap();
        assert_eq!(b["ready_to_assign"], 0);
    }

    #[test]
    fn errors_are_strings() {
        assert!(merge("null", "{}").is_err());
        assert!(budget("[]", "2026-13").is_err());
        assert!(entry_id("nope", "2026-10").is_err());
    }

    #[test]
    fn entry_id_matches_model() {
        let c = "00000000-0000-4000-8000-0000000000aa";
        let want = budget_entry_id(c.parse().unwrap(), "2026-10").to_string();
        assert_eq!(entry_id(c, "2026-10").unwrap(), want);
    }
}
