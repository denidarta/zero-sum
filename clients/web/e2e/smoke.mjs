// End-to-end check: two browsers, one real server, offline edit, convergence.
//
//   npm run build && cargo build -p zero-sum-server
//   node e2e/smoke.mjs
//
// Needs `playwright` resolvable (preinstalled in the cloud sandbox).
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";

const { chromium } = createRequire(import.meta.url)("playwright");
const root = resolve(import.meta.dirname, "../../..");
const dir = mkdtempSync(join(tmpdir(), "zs-e2e-"));
const port = 18900 + Math.floor(Math.random() * 500);
const base = `http://127.0.0.1:${port}`;

const server = spawn(join(root, "target/debug/zero-sum-server"), [], {
  env: {
    ...process.env,
    ZERO_SUM_ADDR: `127.0.0.1:${port}`,
    ZERO_SUM_DB: join(dir, "e2e.db"),
    ZERO_SUM_WEB_DIR: join(root, "clients/web/dist"),
  },
  stdio: "inherit",
});

const until = async (f, what, ms = 8000) => {
  const end = Date.now() + ms;
  for (;;) {
    try {
      const v = await f();
      if (v) return v;
    } catch {}
    if (Date.now() > end) throw new Error(`timeout: ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};
const rta = (page) => page.getByTestId("rta").innerText();

let browser;
try {
  await until(() => fetch(`${base}/health`).then((r) => r.ok), "server up");
  browser = await chromium.launch();

  const open = async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    page.on("pageerror", (e) => { throw e; });
    await page.goto(base);
    await page.getByTestId("rta").waitFor();
    return { ctx, page };
  };

  // Device A builds a budget.
  const a = await open();
  const A = a.page;
  await A.getByPlaceholder("New account").fill("Checking");
  await A.getByRole("button", { name: "Add account" }).click();
  await A.getByPlaceholder("New category group").fill("Bills");
  await A.getByRole("button", { name: "Add group" }).click();
  await A.getByPlaceholder("Add category").fill("Rent");
  await A.getByPlaceholder("Add category").press("Enter");
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByPlaceholder("Amount").fill("3000");
  await A.getByLabel("Inflow").check();
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByRole("button", { name: "Budget" }).click();
  await A.locator('[data-cat="Rent"] input.num').fill("1200");
  await A.locator('[data-cat="Rent"] input.num').press("Enter");
  await until(async () => (await rta(A)) === "1,800.00", "A ready to assign 1,800.00");

  // Device B is new. It must converge to the same numbers.
  const b = await open();
  const B = b.page;
  await until(async () => (await rta(B)) === "1,800.00", "B pulled A's budget");

  // B goes offline and re-assigns rent. Nothing may be lost or block the UI.
  await b.ctx.setOffline(true);
  await B.locator('[data-cat="Rent"] input.num').fill("1500");
  await B.locator('[data-cat="Rent"] input.num').press("Enter");
  await until(async () => (await rta(B)) === "1,500.00", "B local edit while offline");
  assert.equal(await rta(A), "1,800.00", "A must not see offline edit yet");

  // Meanwhile A records spending in the same category.
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByPlaceholder("Amount").fill("100");
  await A.getByLabel("Inflow").uncheck();
  await A.locator("select").nth(1).selectOption({ label: "Rent" });
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByRole("button", { name: "Budget" }).click();

  // B reconnects. Both devices converge on assigned 1500 and 100 spent.
  await b.ctx.setOffline(false);
  await B.evaluate(() => window.zs.sync());
  await until(async () => (await B.locator('[data-cat="Rent"] td.avail').innerText()) === "1,400.00", "B available");
  await until(async () => (await A.locator('[data-cat="Rent"] td.avail').innerText()) === "1,400.00", "A available");
  assert.equal(await rta(A), "1,500.00");
  assert.equal(await rta(B), "1,500.00");

  // Pending queue drained on both.
  assert.equal(await A.evaluate(() => window.zs.outbox.length), 0);
  assert.equal(await B.evaluate(() => window.zs.outbox.length), 0);

  // Reload B with no network: the shell comes from the service worker, data from IndexedDB.
  await B.evaluate(() => navigator.serviceWorker.ready);
  await b.ctx.setOffline(true);
  await B.reload();
  await until(async () => (await rta(B)) === "1,500.00", "B reload offline");
  console.log("OK");
} finally {
  await browser?.close();
  server.kill();
  rmSync(dir, { recursive: true, force: true });
}
