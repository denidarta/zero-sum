use anyhow::{Context, Result};
use std::env;
use tracing_subscriber::EnvFilter;
use zero_sum_server::{
    api::{router, AppState},
    store::Store,
};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| "info,tower_http=info".into()),
        )
        .init();

    let addr = env::var("ZERO_SUM_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".into());
    let db = env::var("ZERO_SUM_DB").unwrap_or_else(|_| "zero-sum.db".into());

    let store = Store::open(&db).with_context(|| format!("open {db}"))?;
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .with_context(|| format!("bind {addr}"))?;
    tracing::info!("listening on {addr}, database {db}");

    axum::serve(listener, router(AppState::new(store)))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
