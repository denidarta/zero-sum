// Local database + sync engine.
//
// Edits apply to the local copy at once and queue in an outbox. Push sends the
// outbox, pull fetches entity state changed on the server. After a pull, still
// unsent ops are merged over the server state again, so local edits made
// offline are never lost. Merge is idempotent, which makes that safe.
import { mergeOp } from "./core";
import { idb } from "./idb";
import type { Change, Entity, Kind, Op } from "./types";

const key = (kind: Kind, id: string) => `${kind}:${id}`;
const PUSH_BATCH = 500;

export type SyncState = "idle" | "syncing" | "offline";

export class Db {
  entities = new Map<string, Entity>();
  outbox: Op[] = [];
  cursor = 0;
  deviceId = "";
  state: SyncState = "idle";
  /** Bumped on every change so the UI knows to re-render. */
  version = 0;

  private listeners = new Set<() => void>();
  private lastTs = 0;
  private syncing: Promise<void> | undefined;
  private again = false;
  private ws: WebSocket | undefined;
  private wsDelay = 1000;

  /** Server base URL. Empty means same origin. */
  serverUrl = localStorage.getItem("zs.server") ?? "";

  async load() {
    const [ents, ops, cursor, device] = await Promise.all([
      idb.all<Entity>("entities"),
      idb.all<Op>("outbox"),
      idb.get<number>("meta", "cursor"),
      idb.get<string>("meta", "deviceId"),
    ]);
    ents.forEach((e) => this.entities.set(key(e.kind, e.id), e));
    this.outbox = ops.sort((a, b) => a.ts - b.ts);
    this.cursor = cursor ?? 0;
    this.deviceId = device ?? uuid();
    if (!device) await idb.put("meta", "deviceId", this.deviceId);
    this.lastTs = Math.max(0, ...this.outbox.map((o) => o.ts));
    this.bump();
  }

  subscribe(f: () => void) {
    this.listeners.add(f);
    return () => this.listeners.delete(f);
  }

  private bump() {
    this.version++;
    this.listeners.forEach((f) => f());
  }

  list(kind: Kind): Entity[] {
    return [...this.entities.values()].filter((e) => e.kind === kind && !e.deleted);
  }

  get(kind: Kind, id: string): Entity | undefined {
    return this.entities.get(key(kind, id));
  }

  /** Apply an edit locally and queue it for the server. */
  edit(kind: Kind, id: string, fields: Record<string, unknown>, deleted?: boolean): void {
    // Strictly increasing so a later local edit always beats an earlier one.
    this.lastTs = Math.max(Date.now(), this.lastTs + 1);
    const op: Op = { op_id: uuid(), ts: this.lastTs, kind, entity_id: id, fields };
    if (deleted !== undefined) op.deleted = deleted;
    const existing = this.entities.get(key(kind, id)) ?? null;
    const { state } = mergeOp(existing, op); // throws on invalid input; nothing is queued
    this.entities.set(key(kind, id), state);
    this.outbox.push(op);
    void idb.put("entities", key(kind, id), state);
    void idb.put("outbox", op.op_id, op);
    this.bump();
    void this.sync();
  }

  remove(kind: Kind, id: string) {
    this.edit(kind, id, {}, true);
  }

  // ---- sync ----

  private url(path: string) {
    return this.serverUrl.replace(/\/$/, "") + path;
  }

  /** Push then pull. Calls made while a sync runs are folded into one rerun. */
  sync(): Promise<void> {
    if (this.syncing) {
      this.again = true;
      return this.syncing;
    }
    this.syncing = (async () => {
      try {
        do {
          this.again = false;
          this.setState("syncing");
          await this.push();
          await this.pull();
          this.setState("idle");
        } while (this.again);
      } catch (e) {
        console.warn("sync failed", e);
        this.setState("offline");
      } finally {
        this.syncing = undefined;
      }
    })();
    return this.syncing;
  }

  private setState(s: SyncState) {
    if (this.state !== s) {
      this.state = s;
      this.bump();
    }
  }

  private async push() {
    while (this.outbox.length) {
      const batch = this.outbox.slice(0, PUSH_BATCH);
      const res = await fetch(this.url("/sync/push"), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ device_id: this.deviceId, ops: batch }),
      });
      if (!res.ok) throw new Error(`push ${res.status}`);
      const out: { results: { op_id: string; status: string; reason?: string }[] } =
        await res.json();
      for (const r of out.results) {
        if (r.status === "rejected") console.warn("op rejected", r.reason);
      }
      // Every status is final, including rejected: resending cannot help.
      const done = new Set(out.results.map((r) => r.op_id));
      this.outbox = this.outbox.filter((o) => !done.has(o.op_id));
      await Promise.all([...done].map((id) => idb.del("outbox", id)));
      this.bump();
    }
  }

  private async pull() {
    for (;;) {
      const res = await fetch(this.url(`/sync/pull?since=${this.cursor}&limit=500`));
      if (!res.ok) throw new Error(`pull ${res.status}`);
      const page: { changes: Change[]; cursor: number; has_more: boolean } = await res.json();
      for (const { seq: _seq, ...server } of page.changes) {
        let state: Entity = server;
        for (const op of this.outbox) {
          if (op.kind === state.kind && op.entity_id === state.id) {
            try {
              state = mergeOp(state, op).state;
            } catch {
              /* invalid against server state; the push will reject it */
            }
          }
        }
        this.entities.set(key(state.kind, state.id), state);
        await idb.put("entities", key(state.kind, state.id), state);
      }
      this.cursor = page.cursor;
      await idb.put("meta", "cursor", this.cursor);
      this.bump();
      if (!page.has_more) break;
    }
  }

  // ---- realtime nudge ----

  /** Open the WebSocket. A message only means "pull now". */
  connect() {
    this.ws?.close();
    const base = this.serverUrl || location.origin;
    const url = base.replace(/^http/, "ws").replace(/\/$/, "") + "/sync/ws";
    const ws = new WebSocket(url);
    this.ws = ws;
    ws.onopen = () => (this.wsDelay = 1000);
    ws.onmessage = () => void this.sync();
    ws.onclose = () => {
      if (this.ws !== ws) return;
      setTimeout(() => this.connect(), this.wsDelay);
      this.wsDelay = Math.min(this.wsDelay * 2, 30000);
    };
  }

  setServer(url: string) {
    this.serverUrl = url;
    localStorage.setItem("zs.server", url);
    this.connect();
    void this.sync();
  }
}

export function uuid(): string {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6]! & 0x0f) | 0x40;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
