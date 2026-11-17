use super::*;
use serde_json::json;

fn op(n: u128, ts: i64, fields: Value, deleted: Option<bool>) -> Op {
    Op {
        op_id: Uuid::from_u128(n),
        ts,
        kind: Kind::Payee,
        entity_id: Uuid::from_u128(1000),
        fields: fields.as_object().cloned().unwrap_or_default(),
        deleted,
    }
}

#[test]
fn newer_field_write_wins_regardless_of_arrival_order() {
    let create = op(1, 10, json!({"name": "Shop"}), None);
    let early = op(2, 20, json!({"name": "Early"}), None);
    let late = op(3, 30, json!({"name": "Late"}), None);

    let a = apply(None, &create).unwrap().state;
    let a = apply(Some(a), &late).unwrap().state;
    let a = apply(Some(a), &early).unwrap().state;

    let b = apply(None, &create).unwrap().state;
    let b = apply(Some(b), &early).unwrap().state;
    let b = apply(Some(b), &late).unwrap().state;

    assert_eq!(a, b);
    assert_eq!(a.data["name"], "Late");
}

#[test]
fn stale_op_reports_unchanged() {
    let s = apply(None, &op(1, 50, json!({"name": "New"}), None))
        .unwrap()
        .state;
    let r = apply(Some(s), &op(2, 40, json!({"name": "Old"}), None)).unwrap();
    assert!(!r.changed);
    assert_eq!(r.state.data["name"], "New");
}

#[test]
fn replay_is_idempotent() {
    let o = op(1, 10, json!({"name": "Shop"}), None);
    let s = apply(None, &o).unwrap().state;
    let again = apply(Some(s.clone()), &o).unwrap();
    assert!(!again.changed);
    assert_eq!(again.state, s);
}

#[test]
fn different_fields_merge() {
    let mut o1 = op(1, 10, json!({"name": "Cash"}), None);
    o1.kind = Kind::Account;
    o1.fields.insert("kind".into(), json!("cash"));
    let mut o2 = op(2, 5, json!({"note": "wallet"}), None);
    o2.kind = Kind::Account;
    let s = apply(None, &o1).unwrap().state;
    let s = apply(Some(s), &o2).unwrap().state;
    assert_eq!(s.data["name"], "Cash");
    assert_eq!(s.data["note"], "wallet");
}

#[test]
fn delete_and_restore_follow_stamps() {
    let s = apply(None, &op(1, 10, json!({"name": "A"}), None))
        .unwrap()
        .state;
    let s = apply(Some(s), &op(2, 30, json!({}), Some(true)))
        .unwrap()
        .state;
    assert!(s.deleted);
    // Older restore loses.
    let s = apply(Some(s), &op(3, 20, json!({}), Some(false)))
        .unwrap()
        .state;
    assert!(s.deleted);
    let s = apply(Some(s), &op(4, 40, json!({}), Some(false)))
        .unwrap()
        .state;
    assert!(!s.deleted);
}

#[test]
fn rejects_unknown_field_and_incomplete_create() {
    assert!(apply(None, &op(1, 10, json!({"nmae": "x"}), None)).is_err());
    assert!(apply(None, &op(1, 10, json!({}), Some(true))).is_err());
    assert!(apply(None, &op(1, 10, json!({}), None)).is_err());
}
