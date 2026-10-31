use axum::{
    body::Body,
    http::{Request, StatusCode},
    Router,
};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;
use uuid::Uuid;
use zero_sum_core::model::budget_entry_id;
use zero_sum_server::{
    api::{router, AppState},
    store::Store,
};

fn app() -> Router {
    router(AppState::new(Store::in_memory().unwrap()))
}

async fn call(app: &Router, req: Request<Body>) -> (StatusCode, Value) {
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn push(app: &Router, ops: Vec<Value>) -> Value {
    let req = Request::post("/sync/push")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({"device_id": "test", "ops": ops}).to_string(),
        ))
        .unwrap();
    let (status, body) = call(app, req).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

async fn get(app: &Router, uri: &str) -> (StatusCode, Value) {
    call(app, Request::get(uri).body(Body::empty()).unwrap()).await
}

fn op(kind: &str, entity: Uuid, ts: i64, fields: Value) -> Value {
    json!({"op_id": Uuid::new_v4(), "ts": ts, "kind": kind, "entity_id": entity, "fields": fields})
}

#[tokio::test]
async fn push_is_idempotent_and_pull_returns_state() {
    let app = app();
    let acct = Uuid::new_v4();
    let create = op(
        "account",
        acct,
        10,
        json!({"name": "Checking", "kind": "checking"}),
    );

    let out = push(&app, vec![create.clone()]).await;
    assert_eq!(out["results"][0]["status"], "applied");
    assert_eq!(out["cursor"], 1);

    let again = push(&app, vec![create]).await;
    assert_eq!(again["results"][0]["status"], "duplicate");
    assert_eq!(again["cursor"], 1);

    let (_, page) = get(&app, "/sync/pull?since=0").await;
    assert_eq!(page["changes"].as_array().unwrap().len(), 1);
    assert_eq!(page["changes"][0]["data"]["name"], "Checking");
    assert_eq!(page["cursor"], 1);
    assert_eq!(page["has_more"], false);

    let (_, empty) = get(&app, "/sync/pull?since=1").await;
    assert!(empty["changes"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn offline_edits_merge_per_field_and_stale_loses() {
    let app = app();
    let acct = Uuid::new_v4();
    push(
        &app,
        vec![op(
            "account",
            acct,
            10,
            json!({"name": "A", "kind": "cash"}),
        )],
    )
    .await;
    // Device 1 renames at t=100, device 2 edits the note at t=50, device 3 renames stale at t=20.
    let out = push(
        &app,
        vec![
            op("account", acct, 100, json!({"name": "Wallet"})),
            op("account", acct, 50, json!({"note": "daily"})),
            op("account", acct, 20, json!({"name": "Old"})),
        ],
    )
    .await;
    let statuses: Vec<_> = out["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["status"].clone())
        .collect();
    assert_eq!(statuses, ["applied", "applied", "stale"]);

    let (_, page) = get(&app, "/sync/pull?since=0").await;
    let data = &page["changes"][0]["data"];
    assert_eq!(data["name"], "Wallet");
    assert_eq!(data["note"], "daily");
}

#[tokio::test]
async fn bad_op_is_rejected_without_failing_batch() {
    let app = app();
    let good = Uuid::new_v4();
    let out = push(
        &app,
        vec![
            op("account", Uuid::new_v4(), 1, json!({"nmae": "typo"})),
            op(
                "transaction",
                Uuid::new_v4(),
                1,
                json!({"account_id": good, "date": "31/10/2026", "amount": 1}),
            ),
            op("payee", good, 1, json!({"name": "Shop"})),
        ],
    )
    .await;
    let r = out["results"].as_array().unwrap();
    assert_eq!(r[0]["status"], "rejected");
    assert_eq!(r[1]["status"], "rejected");
    assert_eq!(r[2]["status"], "applied");
}

#[tokio::test]
async fn pull_paginates() {
    let app = app();
    let ops = (0..5)
        .map(|i| op("payee", Uuid::new_v4(), i, json!({"name": format!("p{i}")})))
        .collect();
    push(&app, ops).await;
    let (_, p1) = get(&app, "/sync/pull?since=0&limit=2").await;
    assert_eq!(p1["changes"].as_array().unwrap().len(), 2);
    assert_eq!(p1["has_more"], true);
    let (_, p2) = get(&app, &format!("/sync/pull?since={}&limit=10", p1["cursor"])).await;
    assert_eq!(p2["changes"].as_array().unwrap().len(), 3);
    assert_eq!(p2["has_more"], false);
}

#[tokio::test]
async fn budget_month_from_synced_entities() {
    let app = app();
    let (acct, group, rent, food) = (
        Uuid::new_v4(),
        Uuid::new_v4(),
        Uuid::new_v4(),
        Uuid::new_v4(),
    );
    push(
        &app,
        vec![
            op("account", acct, 1, json!({"name": "Checking", "kind": "checking"})),
            op("category_group", group, 1, json!({"name": "Bills"})),
            op("category", rent, 1, json!({"group_id": group, "name": "Rent"})),
            op("category", food, 1, json!({"group_id": group, "name": "Food"})),
            op("transaction", Uuid::new_v4(), 1, json!({"account_id": acct, "date": "2026-10-01", "amount": 3_000_000})),
            op("transaction", Uuid::new_v4(), 1, json!({"account_id": acct, "date": "2026-10-04", "amount": -250_000, "category_id": food})),
            op("budget_entry", budget_entry_id(rent, "2026-10"), 1, json!({"category_id": rent, "month": "2026-10", "assigned": 1_200_000})),
            op("budget_entry", budget_entry_id(food, "2026-10"), 1, json!({"category_id": food, "month": "2026-10", "assigned": 400_000})),
        ],
    )
    .await;

    let (status, b) = get(&app, "/budget/2026-10").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(b["ready_to_assign"], 1_400_000);
    let food_row = b["categories"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["category_id"] == json!(food))
        .unwrap();
    assert_eq!(food_row["activity"], -250_000);
    assert_eq!(food_row["available"], 150_000);

    // Deleting the spend frees the envelope again.
    let (_, page) = get(&app, "/sync/pull?since=0").await;
    let spend = page["changes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["data"]["amount"] == -250_000)
        .unwrap();
    push(&app, vec![json!({"op_id": Uuid::new_v4(), "ts": 99, "kind": "transaction", "entity_id": spend["id"], "deleted": true})]).await;
    let (_, b) = get(&app, "/budget/2026-10").await;
    let food_row = b["categories"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["category_id"] == json!(food))
        .unwrap();
    assert_eq!(food_row["available"], 400_000);

    let (status, _) = get(&app, "/budget/not-a-month").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn budget_entry_requires_derived_id() {
    let app = app();
    let cat = Uuid::new_v4();
    let out = push(
        &app,
        vec![op(
            "budget_entry",
            Uuid::new_v4(),
            1,
            json!({"category_id": cat, "month": "2026-10", "assigned": 1}),
        )],
    )
    .await;
    assert_eq!(out["results"][0]["status"], "rejected");
}
