//! UniFFI bindings of `zero-sum-core` for the iOS client.
//!
//! Thin wrappers over `zero_sum_core::json`, the same functions the web client
//! gets through `crates/wasm`. Swift is generated from this crate's compiled
//! metadata, see `scripts/build-ios-core.sh`.

use zero_sum_core::json;

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

fn err(message: String) -> CoreError {
    CoreError::Invalid { message }
}

/// Merge an op into an entity. `entity_json` is `null` for a new entity.
/// Returns `{state, changed}`. Fails when the op is invalid.
#[uniffi::export]
pub fn merge_op(entity_json: String, op_json: String) -> Result<String, CoreError> {
    json::merge(&entity_json, &op_json).map_err(err)
}

/// Compute a budget month from a JSON array of entity states.
#[uniffi::export]
pub fn compute_budget(entities_json: String, month: String) -> Result<String, CoreError> {
    json::budget(&entities_json, &month).map_err(err)
}

/// Deterministic id of the budget entry for a category and month.
#[uniffi::export]
pub fn budget_entry_id(category_id: String, month: String) -> Result<String, CoreError> {
    json::entry_id(&category_id, &month).map_err(err)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_map_to_core_error() {
        let e = compute_budget("[]".into(), "2026-13".into()).unwrap_err();
        assert!(e.to_string().contains("bad month"));
        assert!(budget_entry_id("nope".into(), "2026-10".into()).is_err());
        assert!(merge_op("null".into(), "{}".into()).is_err());
    }
}
