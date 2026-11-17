use super::*;
use serde_json::json;

fn check(extra: Value) -> Result<(), String> {
    let mut data = json!({
        "account_id": "00000000-0000-4000-8000-000000000001",
        "date": "2026-10-05",
        "amount": -300,
    });
    data.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    validate(Kind::Transaction, Uuid::nil(), data.as_object().unwrap())
}

fn line(n: u8, amount: i64) -> Value {
    json!({"category_id": format!("00000000-0000-4000-8000-0000000000{n:02}"), "amount": amount})
}

#[test]
fn split_lines_must_sum_to_amount() {
    assert!(check(json!({"splits": [line(10, -100), line(11, -200)]})).is_ok());
    assert!(check(json!({"splits": [line(10, -100), line(11, -100)]})).is_err());
}

#[test]
fn split_excludes_category_and_transfer() {
    let s = json!([line(10, -300)]);
    assert!(
        check(json!({"splits": s, "category_id": "00000000-0000-4000-8000-000000000010"})).is_err()
    );
    assert!(check(
        json!({"splits": s, "transfer_account_id": "00000000-0000-4000-8000-000000000002"})
    )
    .is_err());
}

#[test]
fn transfer_partner_needs_transfer_account() {
    let partner = "00000000-0000-4000-8000-000000000077";
    assert!(check(json!({"transfer_transaction_id": partner})).is_err());
    assert!(check(json!({
        "transfer_transaction_id": partner,
        "transfer_account_id": "00000000-0000-4000-8000-000000000002",
    }))
    .is_ok());
}
