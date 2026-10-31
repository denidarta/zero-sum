//! C ABI of `zero-sum-core` for the Flutter client.
//!
//! Thin wrapper over `zero_sum_core::json`. Every function returns
//! `{"ok": <json>}` or `{"err": "..."}`. The caller owns the returned string and
//! must release it with [`zs_free`].

use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use zero_sum_core::json;

/// Read a NUL-terminated UTF-8 argument. A null or non-UTF-8 pointer is an error value, not UB.
unsafe fn arg<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() {
        return Err("null argument".into());
    }
    CStr::from_ptr(p).to_str().map_err(|e| e.to_string())
}

/// `merge` and `budget` return JSON text; embed it as a value, not a string.
fn parsed(r: Result<String, String>) -> Result<Value, String> {
    r.and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
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
    reply(parsed((|| json::merge(arg(entity_json)?, arg(op_json)?))()))
}

/// Compute a budget month from a JSON array of entity states.
/// # Safety
/// Both pointers must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn zs_budget(
    entities_json: *const c_char,
    month: *const c_char,
) -> *mut c_char {
    reply(parsed((|| json::budget(arg(entities_json)?, arg(month)?))()))
}

/// Deterministic id of the budget entry for a category and month.
/// # Safety
/// Both pointers must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn zs_entry_id(
    category_id: *const c_char,
    month: *const c_char,
) -> *mut c_char {
    reply((|| {
        json::entry_id(arg(category_id)?, arg(month)?).map(Value::String)
    })())
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
    fn abi_roundtrip() {
        let c = "00000000-0000-4000-8000-0000000000aa";
        assert!(call(zs_entry_id, c, "2026-10")["ok"].is_string());
        assert_eq!(call(zs_budget, "[]", "2026-10")["ok"]["ready_to_assign"], 0);
        assert_eq!(call(zs_merge, "null", "{}").get("ok"), None);
        assert!(call(zs_merge, "null", "{}")["err"].is_string());
    }
}
