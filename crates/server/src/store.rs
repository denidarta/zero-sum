//! SQLite storage: an append-only op log plus merged entity state.

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{path::Path, str::FromStr, sync::Mutex, time::SystemTime};
use uuid::Uuid;
use zero_sum_core::{
    budget::Snapshot,
    model::{parse_data, Kind},
    sync::{apply, Change, EntityState, Op, OpResult, OpStatus},
};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS ops (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    op_id       TEXT NOT NULL UNIQUE,
    device_id   TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    body        TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS entities (
    kind    TEXT NOT NULL,
    id      TEXT NOT NULL,
    data    TEXT NOT NULL,
    stamps  TEXT NOT NULL,
    deleted INTEGER NOT NULL,
    seq     INTEGER NOT NULL,
    PRIMARY KEY (kind, id)
);
CREATE INDEX IF NOT EXISTS entities_seq ON entities (seq);
";

pub struct Store {
    conn: Mutex<Connection>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PushOutcome {
    pub results: Vec<OpResult>,
    /// Server head after the push.
    pub cursor: i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PullPage {
    pub changes: Vec<Change>,
    /// Pass as `since` on the next pull.
    pub cursor: i64,
    pub has_more: bool,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path).context("open database")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Self::init(conn)
    }

    pub fn in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(SCHEMA)?;
        Ok(Store {
            conn: Mutex::new(conn),
        })
    }

    pub fn head(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        head(&conn)
    }

    /// Merge a batch of ops in one transaction. A bad op never fails the batch.
    pub fn push(&self, device_id: &str, ops: Vec<Op>) -> Result<PushOutcome> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let mut results = Vec::with_capacity(ops.len());

        for op in ops {
            let seen: bool = tx
                .query_row(
                    "SELECT 1 FROM ops WHERE op_id = ?1",
                    [op.op_id.to_string()],
                    |_| Ok(true),
                )
                .optional()?
                .unwrap_or(false);
            if seen {
                results.push(result(&op, OpStatus::Duplicate, None));
                continue;
            }
            let existing = load_entity(&tx, op.kind, op.entity_id)?;
            let applied = match apply(existing, &op) {
                Ok(a) => a,
                Err(reason) => {
                    results.push(result(&op, OpStatus::Rejected, Some(reason)));
                    continue;
                }
            };
            tx.execute(
                "INSERT INTO ops (op_id, device_id, received_at, body) VALUES (?1, ?2, ?3, ?4)",
                params![
                    op.op_id.to_string(),
                    device_id,
                    now,
                    serde_json::to_string(&op)?
                ],
            )?;
            let status = if applied.changed {
                let seq = tx.last_insert_rowid();
                save_entity(&tx, &applied.state, seq)?;
                OpStatus::Applied
            } else {
                OpStatus::Stale
            };
            results.push(result(&op, status, None));
        }

        let cursor = head(&tx)?;
        tx.commit()?;
        Ok(PushOutcome { results, cursor })
    }

    /// Entities changed after `since`, oldest first.
    pub fn pull(&self, since: i64, limit: usize) -> Result<PullPage> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT kind, id, data, stamps, deleted, seq FROM entities
             WHERE seq > ?1 ORDER BY seq LIMIT ?2",
        )?;
        let mut changes = stmt
            .query_map(params![since, limit as i64 + 1], row_to_change)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let has_more = changes.len() > limit;
        changes.truncate(limit);
        let cursor = match changes.last() {
            Some(c) => c.seq,
            None => since,
        };
        Ok(PullPage {
            changes,
            cursor,
            has_more,
        })
    }

    /// All live entities, typed, for budget math.
    pub fn snapshot(&self) -> Result<Snapshot> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT kind, id, data, stamps, deleted, seq FROM entities WHERE deleted = 0 ORDER BY id",
        )?;
        let changes = stmt
            .query_map([], row_to_change)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut snap = Snapshot::default();
        for c in changes {
            let e = c.entity;
            // Stored data was validated on write, so a parse failure means a bug or corruption.
            match e.kind {
                Kind::Account => snap
                    .accounts
                    .push((e.id, parse_data(&e.data).map_err(anyhow::Error::msg)?)),
                Kind::Category => snap
                    .categories
                    .push((e.id, parse_data(&e.data).map_err(anyhow::Error::msg)?)),
                Kind::Transaction => snap
                    .transactions
                    .push(parse_data(&e.data).map_err(anyhow::Error::msg)?),
                Kind::BudgetEntry => snap
                    .entries
                    .push(parse_data(&e.data).map_err(anyhow::Error::msg)?),
                Kind::CategoryGroup | Kind::Payee => {}
            }
        }
        Ok(snap)
    }
}

fn result(op: &Op, status: OpStatus, reason: Option<String>) -> OpResult {
    OpResult {
        op_id: op.op_id,
        status,
        reason,
    }
}

fn head(conn: &Connection) -> Result<i64> {
    Ok(conn.query_row("SELECT COALESCE(MAX(seq), 0) FROM ops", [], |r| r.get(0))?)
}

fn load_entity(conn: &Connection, kind: Kind, id: Uuid) -> Result<Option<EntityState>> {
    let row = conn
        .query_row(
            "SELECT kind, id, data, stamps, deleted, seq FROM entities WHERE kind = ?1 AND id = ?2",
            params![kind.as_str(), id.to_string()],
            row_to_change,
        )
        .optional()?;
    Ok(row.map(|c| c.entity))
}

fn save_entity(conn: &Connection, e: &EntityState, seq: i64) -> Result<()> {
    conn.execute(
        "INSERT INTO entities (kind, id, data, stamps, deleted, seq) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT (kind, id) DO UPDATE SET
            data = excluded.data, stamps = excluded.stamps,
            deleted = excluded.deleted, seq = excluded.seq",
        params![
            e.kind.as_str(),
            e.id.to_string(),
            serde_json::to_string(&e.data)?,
            serde_json::to_string(&e.stamps)?,
            e.deleted,
            seq
        ],
    )?;
    Ok(())
}

fn row_to_change(r: &rusqlite::Row<'_>) -> rusqlite::Result<Change> {
    let conv = |i: usize, e: String| {
        rusqlite::Error::FromSqlConversionFailure(i, rusqlite::types::Type::Text, e.into())
    };
    let kind: String = r.get(0)?;
    let id: String = r.get(1)?;
    let data: String = r.get(2)?;
    let stamps: String = r.get(3)?;
    Ok(Change {
        seq: r.get(5)?,
        entity: EntityState {
            kind: Kind::from_str(&kind).map_err(|e| conv(0, e))?,
            id: Uuid::parse_str(&id).map_err(|e| conv(1, e.to_string()))?,
            data: serde_json::from_str(&data).map_err(|e| conv(2, e.to_string()))?,
            stamps: serde_json::from_str(&stamps).map_err(|e| conv(3, e.to_string()))?,
            deleted: r.get(4)?,
        },
    })
}
