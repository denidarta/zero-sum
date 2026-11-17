//! Sync wire types and the merge rule.
//!
//! Model: clients send operations (field patches). The server merges them into
//! entity state with per-field last-writer-wins and returns entity state to
//! clients. Merge is commutative and idempotent, so ops can arrive late, twice
//! or out of order and every replica converges.

use crate::model::{validate, Kind};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use uuid::Uuid;

/// Pseudo field that tracks the tombstone flag in [`EntityState::stamps`].
pub const DELETED: &str = "_deleted";

/// Orders writes to one field: client wall clock first, op id as tie-break.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Stamp {
    pub ts: i64,
    pub op: Uuid,
}

/// A patch to one entity. Creating an entity is a patch that sets all required fields.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Op {
    /// Client-generated, makes pushes idempotent.
    pub op_id: Uuid,
    /// Client wall clock, milliseconds since the Unix epoch.
    pub ts: i64,
    pub kind: Kind,
    pub entity_id: Uuid,
    #[serde(default)]
    pub fields: Map<String, Value>,
    /// `Some(true)` deletes (tombstone), `Some(false)` restores.
    #[serde(default)]
    pub deleted: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EntityState {
    pub kind: Kind,
    pub id: Uuid,
    pub data: Map<String, Value>,
    /// Winning stamp per field. Clients need it to merge pending local ops over pulled state.
    pub stamps: BTreeMap<String, Stamp>,
    pub deleted: bool,
}

/// An entity state tagged with the server sequence number of its last change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Change {
    pub seq: i64,
    #[serde(flatten)]
    pub entity: EntityState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpStatus {
    /// Changed at least one field.
    Applied,
    /// Valid, but every field lost to a newer write.
    Stale,
    /// Seen before. Nothing done.
    Duplicate,
    /// Invalid. See `reason`. The client should drop the op.
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpResult {
    pub op_id: Uuid,
    pub status: OpStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub struct Applied {
    pub state: EntityState,
    pub changed: bool,
}

/// Merge `op` into `existing`. Returns the new state, or why the op is invalid.
pub fn apply(existing: Option<EntityState>, op: &Op) -> Result<Applied, String> {
    if op.fields.is_empty() && op.deleted.is_none() {
        return Err("op changes nothing".into());
    }
    let mut state = existing.unwrap_or_else(|| EntityState {
        kind: op.kind,
        id: op.entity_id,
        data: Map::new(),
        stamps: BTreeMap::new(),
        deleted: false,
    });
    let stamp = Stamp {
        ts: op.ts,
        op: op.op_id,
    };
    let mut changed = false;

    for (field, value) in &op.fields {
        if state.stamps.get(field).is_some_and(|s| *s >= stamp) {
            continue;
        }
        state.stamps.insert(field.clone(), stamp.clone());
        if state.data.get(field) != Some(value) {
            state.data.insert(field.clone(), value.clone());
            changed = true;
        }
    }
    if let Some(del) = op.deleted {
        if !state.stamps.get(DELETED).is_some_and(|s| *s >= stamp) {
            state.stamps.insert(DELETED.into(), stamp);
            if state.deleted != del {
                state.deleted = del;
                changed = true;
            }
        }
    }

    validate(state.kind, state.id, &state.data)?;
    Ok(Applied { state, changed })
}

#[cfg(test)]
mod tests;
