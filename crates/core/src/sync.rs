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
mod tests {
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
}
