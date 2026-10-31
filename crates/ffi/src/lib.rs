//! C ABI of `zero-sum-core` for the Flutter client.
//!
//! Same surface as the WASM crate: JSON text in, JSON text out, so merge and
//! budget rules exist once. Every function returns `{"ok": ...}` or
//! `{"err": "..."}`. The caller owns the returned string and must release it
//! with [`zs_free`]. No hand-written bindings generator: three functions do not
//! justify one.

use serde::Serialize;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use uuid::Uuid;
use zero_sum_core::{
    budget::{compute, Snapshot},
    model::budget_entry_id,
    sync::{apply, EntityState, Op},
};

#[derive(Serialize)]
struct Merged {
    state: EntityState,
    changed: bool,
}

fn merge_json(entity: &str, op: &str) -> Result<Value, String> {
    let existing: Option<EntityState> = serde_json::from_str(entity).map_err(|e| e.to_string())?;
    let op: Op = serde_json::from_str(op).map_err(|e| e.to_string())?;
    let a = apply(existing, &op)?;
    serde_json::to_value(Merged {
        state: a.state,
        changed: a.changed,
    })
    .map_err(|e| e.to_string())
}

fn budget_json(entities: &str, month: &str) -> Result<Value, String> {
    let entities: Vec<EntityState> = serde_json::from_str(entities).map_err(|e| e.to_string())?;
    let snap = Snapshot::from_entities(&entities)?;
    serde_json::to_value(compute(&snap, month)?).map_err(|e| e.to_string())
}

fn entry_id_json(category_id: &str, month: &str) -> Result<Value, String> {
    let id: Uuid = category_id
        .parse()
        .map_err(|e: uuid::Error| e.to_string())?;
    Ok(Value::String(budget_entry_id(id, month).to_string()))
}

/// Read a NUL-terminated UTF-8 argument. A null or non-UTF-8 pointer is an error value, not UB.
unsafe fn arg<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() {
        return Err("null argument".into());
    }
    CStr::from_ptr(p).to_str().map_err(|e| e.to_string())
}

fn reply(r: Result<Value, String>) -> *mut c_char {
    let v = match r {
        Ok(v) => json!({ "ok": v }),
        Err(e) => json!({ "err": e }),
    };
    // JSON text never contains NUL.
    CString::new(v.to_string()).unwrap().into_raw()
}

/// Merge an op into an entity. `entity_json` is `null` for a new entity.
/// # Safety
/// Both pointers must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn zs_merge(
    entity_json: *const c_char,
    op_json: *const c_char,
) -> *mut c_char {
    reply((|| merge_json(arg(entity_json)?, arg(op_json)?))())
}

/// Compute a budget month from a JSON array of entity states.
/// # Safety
/// Both pointers must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn zs_budget(
    entities_json: *const c_char,
    month: *const c_char,
) -> *mut c_char {
    reply((|| budget_json(arg(entities_json)?, arg(month)?))())
}

/// Deterministic id of the budget entry for a category and month.
/// # Safety
/// Both pointers must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn zs_entry_id(
    category_id: *const c_char,
    month: *const c_char,
) -> *mut c_char {
    reply((|| entry_id_json(arg(category_id)?, arg(month)?))())
}

/// Release a string returned by any `zs_*` function.
/// # Safety
/// `p` must come from this library and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn zs_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(
        f: unsafe extern "C" fn(*const c_char, *const c_char) -> *mut c_char,
        a: &str,
        b: &str,
    ) -> Value {
        let (a, b) = (CString::new(a).unwrap(), CString::new(b).unwrap());
        unsafe {
            let p = f(a.as_ptr(), b.as_ptr());
            let v = serde_json::from_str(CStr::from_ptr(p).to_str().unwrap()).unwrap();
            zs_free(p);
            v
        }
    }

    #[test]
    fn merge_budget_roundtrip() {
        let op = r#"{"op_id":"00000000-0000-4000-8000-000000000001","ts":1,"kind":"payee",
                     "entity_id":"00000000-0000-4000-8000-000000000002","fields":{"name":"Shop"}}"#;
        let r = call(zs_merge, "null", op);
        assert_eq!(r["ok"]["changed"], true);
        assert_eq!(r["ok"]["state"]["data"]["name"], "Shop");

        let b = call(zs_budget, "[]", "2026-10");
        assert_eq!(b["ok"]["ready_to_assign"], 0);
    }

    #[test]
    fn errors_are_values() {
        assert!(call(zs_merge, "null", "{}")["err"].is_string());
        assert!(call(zs_budget, "[]", "2026-13")["err"].is_string());
        assert!(call(zs_entry_id, "nope", "2026-10")["err"].is_string());
    }

    #[test]
    fn entry_id_matches_core() {
        let c = "00000000-0000-4000-8000-0000000000aa";
        let want = budget_entry_id(c.parse().unwrap(), "2026-10").to_string();
        assert_eq!(call(zs_entry_id, c, "2026-10")["ok"], want);
    }
}
