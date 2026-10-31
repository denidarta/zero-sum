import { render } from "preact";
import { App } from "./app";
import { loadCore } from "./core";
import { Db } from "./db";
import "./style.css";

async function start() {
  const root = document.getElementById("app")!;
  try {
    await loadCore();
    const db = new Db();
    await db.load();
    render(<App db={db} />, root);
    db.connect();
    void db.sync();
    window.addEventListener("online", () => void db.sync());
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") void db.sync();
    });
    // Test hook, handy in the console and in e2e tests.
    (window as any).zs = db;
    if ("serviceWorker" in navigator && import.meta.env.PROD) {
      void navigator.serviceWorker.register("/sw.js");
    }
  } catch (e) {
    root.textContent = `Failed to start: ${e}`;
    throw e;
  }
}

void start();
