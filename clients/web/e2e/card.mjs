// End-to-end check of credit card payment rows. Seeds a card through the sync API
// (the account form only creates checking and tracking accounts), then checks the
// "Credit Card Payments" section and assigning to it.
//
//   npm run build && cargo build -p zero-sum-server
//   node e2e/card.mjs
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const { chromium } = createRequire(import.meta.url)("playwright");
const root = resolve(import.meta.dirname, "../../..");
const dir = mkdtempSync(join(tmpdir(), "zs-card-"));
const port = 19500 + Math.floor(Math.random() * 400);
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
      if (await f()) return;
    } catch {}
    if (Date.now() > end) throw new Error(`timeout: ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
};

let browser;
try {
  await until(() => fetch(`${base}/health`).then((r) => r.ok), "server up");
  const now = new Date();
  const month = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
  const [checking, card, group, rent] = [randomUUID(), randomUUID(), randomUUID(), randomUUID()];
  const op = (kind, entity_id, fields) => ({ op_id: randomUUID(), ts: Date.now(), kind, entity_id, fields });
  const ops = [
    op("account", checking, { name: "Checking", kind: "checking" }),
    op("account", card, { name: "Visa", kind: "credit_card" }),
    op("category_group", group, { name: "Bills" }),
    op("category", rent, { group_id: group, name: "Rent" }),
    op("transaction", randomUUID(), { account_id: checking, date: `${month}-01`, amount: 3_000_000 }),
    op("transaction", randomUUID(), { account_id: card, date: `${month}-02`, amount: -200_000, category_id: rent }),
  ];
  const res = await fetch(`${base}/sync/push`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ device_id: "e2e", ops }),
  });
  assert.ok(res.ok, await res.text());

  browser = await chromium.launch();
  const page = await (await browser.newContext()).newPage();
  page.on("pageerror", (e) => {
    throw e;
  });
  await page.goto(base);
  await page.getByTestId("rta").waitFor();

  // Rent has nothing assigned, so the 200 spent on the card is overspending covered by credit:
  // Ready to Assign is untouched and the Visa row stays at zero.
  const row = page.locator('[data-cat="card:Visa"]');
  await row.waitFor();
  assert.equal(await page.getByTestId("rta").innerText(), "Rp3.000");
  assert.equal(await row.locator("td.avail").innerText(), "Rp0");

  // Assign 500 to Rent, then the 200 card spend is covered and moves to the Visa row.
  await page.locator('[data-cat="Rent"] input.num').fill("500");
  await page.locator('[data-cat="Rent"] input.num').press("Enter");
  await until(async () => (await row.locator("td.avail").innerText()) === "Rp200", "Visa row shows moved money");
  assert.equal(await page.getByTestId("rta").innerText(), "Rp2.500");

  // Assign 50 straight to the payment category.
  await row.locator("input.num").fill("50");
  await row.locator("input.num").press("Enter");
  await until(async () => (await row.locator("td.avail").innerText()) === "Rp250", "assigned to Visa row");
  assert.equal(await page.getByTestId("rta").innerText(), "Rp2.450");
  console.log("card e2e ok");
} finally {
  await browser?.close();
  server.kill();
  rmSync(dir, { recursive: true, force: true });
}
