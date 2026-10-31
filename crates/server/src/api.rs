//! HTTP + WebSocket API.
//!
//! - `GET  /health`
//! - `POST /sync/push`      body `{device_id, ops}`
//! - `GET  /sync/pull`      query `since`, `limit`
//! - `GET  /sync/ws`        pushes `{"type":"changed","cursor":N}` when data changes
//! - `GET  /budget/{month}` derived budget for `YYYY-MM`
//!
//! There is no authentication. Network reachability is the access control, see
//! `docs/architecture.md`.

use crate::store::{PullPage, PushOutcome, Store};
use anyhow::anyhow;
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use std::sync::Arc;
use tokio::sync::broadcast;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use zero_sum_core::{
    budget::{compute, BudgetMonth},
    sync::Op,
};

const DEFAULT_PULL_LIMIT: usize = 500;
const MAX_PULL_LIMIT: usize = 5000;

#[derive(Clone)]
pub struct AppState {
    store: Arc<Store>,
    changed: broadcast::Sender<i64>,
}

impl AppState {
    pub fn new(store: Store) -> Self {
        let (changed, _) = broadcast::channel(16);
        AppState {
            store: Arc::new(store),
            changed,
        }
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/sync/push", post(push))
        .route("/sync/pull", get(pull))
        .route("/sync/ws", get(ws))
        .route("/budget/{month}", get(budget))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

enum ApiError {
    BadRequest(String),
    Internal(anyhow::Error),
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        ApiError::Internal(e)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        match self {
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, m).into_response(),
            ApiError::Internal(e) => {
                tracing::error!("{e:#}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error").into_response()
            }
        }
    }
}

/// Run blocking SQLite work off the async runtime.
async fn blocking<T: Send + 'static>(
    store: &Arc<Store>,
    f: impl FnOnce(&Store) -> anyhow::Result<T> + Send + 'static,
) -> Result<T, ApiError> {
    let store = store.clone();
    tokio::task::spawn_blocking(move || f(&store))
        .await
        .map_err(|e| ApiError::Internal(anyhow!(e)))?
        .map_err(ApiError::from)
}

#[derive(Deserialize)]
struct PushBody {
    device_id: String,
    ops: Vec<Op>,
}

async fn push(
    State(s): State<AppState>,
    Json(body): Json<PushBody>,
) -> Result<Json<PushOutcome>, ApiError> {
    let device = body.device_id;
    let out = blocking(&s.store, move |st| st.push(&device, body.ops)).await?;
    // No receivers is fine: nobody is listening.
    let _ = s.changed.send(out.cursor);
    Ok(Json(out))
}

#[derive(Deserialize)]
struct PullQuery {
    #[serde(default)]
    since: i64,
    limit: Option<usize>,
}

async fn pull(
    State(s): State<AppState>,
    Query(q): Query<PullQuery>,
) -> Result<Json<PullPage>, ApiError> {
    let limit = q
        .limit
        .unwrap_or(DEFAULT_PULL_LIMIT)
        .clamp(1, MAX_PULL_LIMIT);
    let page = blocking(&s.store, move |st| st.pull(q.since, limit)).await?;
    Ok(Json(page))
}

async fn budget(
    State(s): State<AppState>,
    Path(month): Path<String>,
) -> Result<Json<BudgetMonth>, ApiError> {
    let snap = blocking(&s.store, |st| st.snapshot()).await?;
    compute(&snap, &month)
        .map(Json)
        .map_err(ApiError::BadRequest)
}

async fn ws(upgrade: WebSocketUpgrade, State(s): State<AppState>) -> Response {
    upgrade.on_upgrade(move |socket| watch(socket, s))
}

async fn watch(mut socket: WebSocket, s: AppState) {
    let mut rx = s.changed.subscribe();
    if let Ok(head) = blocking(&s.store, |st| st.head()).await {
        if notify(&mut socket, head).await.is_err() {
            return;
        }
    }
    loop {
        tokio::select! {
            msg = rx.recv() => match msg {
                Ok(cursor) => if notify(&mut socket, cursor).await.is_err() { return },
                // Missed some updates: tell the client the latest head.
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    let Ok(head) = blocking(&s.store, |st| st.head()).await else { return };
                    if notify(&mut socket, head).await.is_err() { return }
                }
                Err(broadcast::error::RecvError::Closed) => return,
            },
            incoming = socket.recv() => match incoming {
                None | Some(Err(_)) | Some(Ok(Message::Close(_))) => return,
                Some(Ok(_)) => {}
            },
        }
    }
}

async fn notify(socket: &mut WebSocket, cursor: i64) -> Result<(), axum::Error> {
    let text = format!(r#"{{"type":"changed","cursor":{cursor}}}"#);
    socket.send(Message::Text(text.into())).await
}
