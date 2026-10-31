// Minimal IndexedDB key/value layer. Data is small, so the app keeps
// everything in memory and writes through.
const DB = "zero-sum";
const STORES = ["entities", "outbox", "meta"] as const;
type StoreName = (typeof STORES)[number];

let dbp: Promise<IDBDatabase> | undefined;

function open(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => STORES.forEach((s) => req.result.createObjectStore(s));
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbp;
}

async function run<T>(
  store: StoreName,
  mode: IDBTransactionMode,
  f: (s: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await open();
  return new Promise((resolve, reject) => {
    const req = f(db.transaction(store, mode).objectStore(store));
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export const idb = {
  all: <T>(store: StoreName) => run<T[]>(store, "readonly", (s) => s.getAll()),
  get: <T>(store: StoreName, key: string) =>
    run<T | undefined>(store, "readonly", (s) => s.get(key)),
  put: (store: StoreName, key: string, value: unknown) =>
    run(store, "readwrite", (s) => s.put(value, key)),
  del: (store: StoreName, key: string) => run(store, "readwrite", (s) => s.delete(key)),
};
