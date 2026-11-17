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
fn plan_returns_patches_or_a_user_facing_error() {
    let cmd = |from: &str| {
        json!({
            "command": "add_transfer", "ids": [CAT, CAT], "date": "2026-10-02",
            "from": from, "to": from, "amount": 5,
        })
        .to_string()
    };
    assert_eq!(
        plan("[]", &cmd(CAT)).unwrap_err(),
        "Pick two different accounts."
    );
    let v = parse(
        plan(
            "[]",
            &json!({"command": "delete_empty_category", "category_id": CAT}).to_string(),
        )
        .unwrap(),
    );
    assert_eq!(
        v[0],
        json!({"kind": "category", "id": CAT, "fields": {}, "deleted": true})
    );
    assert!(plan("[]", "{}").is_err());
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
