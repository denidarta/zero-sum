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
  let last;
  for (;;) {
    try {
      last = await f();
      if (last) return last;
    } catch (e) {
      last = e.message.split("\n")[0];
    }
    if (Date.now() > end) throw new Error(`timeout: ${what} (last: ${last})`);
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
  await A.getByRole("button", { name: "Plan" }).click();
  await A.locator('[data-cat="Rent"] input.num').fill("1200");
  await A.locator('[data-cat="Rent"] input.num').press("Enter");
  await until(async () => (await rta(A)) === "Rp1.800", "A ready to assign 1,800.00");

  // Device B is new. It must converge to the same numbers.
  const b = await open();
  const B = b.page;
  await until(async () => (await rta(B)) === "Rp1.800", "B pulled A's budget");

  // B goes offline and re-assigns rent. Nothing may be lost or block the UI.
  await b.ctx.setOffline(true);
  await B.locator('[data-cat="Rent"] input.num').fill("1500");
  await B.locator('[data-cat="Rent"] input.num').press("Enter");
  await until(async () => (await rta(B)) === "Rp1.500", "B local edit while offline");
  assert.equal(await rta(A), "Rp1.800", "A must not see offline edit yet");

  // Meanwhile A records spending in the same category.
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByPlaceholder("Amount").fill("100");
  await A.getByLabel("Inflow").uncheck();
  await A.locator("select").nth(1).selectOption({ label: "Rent" });
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByRole("button", { name: "Plan" }).click();

  // B reconnects. Both devices converge on assigned 1500 and 100 spent.
  await b.ctx.setOffline(false);
  await B.evaluate(() => window.zs.sync());
  await until(async () => (await B.locator('[data-cat="Rent"] td.avail').innerText()) === "Rp1.400", "B available");
  await until(async () => (await A.locator('[data-cat="Rent"] td.avail').innerText()) === "Rp1.400", "A available");
  assert.equal(await rta(A), "Rp1.500");
  assert.equal(await rta(B), "Rp1.500");

  // Pending queue drained on both.
  assert.equal(await A.evaluate(() => window.zs.outbox.length), 0);
  assert.equal(await B.evaluate(() => window.zs.outbox.length), 0);

  // ---- Ledger rules: docs/ledger-edits-spec.md ----
  const dialogs = [];
  A.on("dialog", (d) => { dialogs.push(d.message()); d.accept(); });
  const cell = (page, cat) => page.locator(`[data-cat="${cat}"] td.avail`).innerText();
  const addCategory = async (n, name) => {
    await A.getByPlaceholder("Add category").nth(n).fill(name);
    await A.getByPlaceholder("Add category").nth(n).press("Enter");
  };
  await A.getByRole("button", { name: "Plan" }).click();

  // D1: a group with categories cannot be deleted.
  await A.getByLabel("Delete group Bills").click();
  assert.match(dialogs.at(-1), /Move or delete the categories in Bills first/);
  assert.equal(await A.locator("tr.group", { hasText: "Bills" }).count(), 1);
  assert.equal(await rta(A), "Rp1.500");

  // D2: B adds a category to a group that A deletes meanwhile. It must stay visible.
  await A.getByPlaceholder("New category group").fill("Temp");
  await A.getByRole("button", { name: "Add group" }).click();
  await until(async () => (await B.locator("tr.group", { hasText: "Temp" }).count()) === 1, "B sees Temp");
  await b.ctx.setOffline(true);
  await B.getByPlaceholder("Add category").nth(1).fill("Gym");
  await B.getByPlaceholder("Add category").nth(1).press("Enter");
  await B.locator('[data-cat="Gym"] input.num').fill("200");
  await B.locator('[data-cat="Gym"] input.num').press("Enter");
  await until(async () => (await rta(B)) === "Rp1.300", "B assigned to Gym offline");
  await A.getByLabel("Delete group Temp").click();
  assert.match(dialogs.at(-1), /Delete group Temp/);
  await b.ctx.setOffline(false);
  await B.evaluate(() => window.zs.sync());
  for (const [name, P] of [["A", A], ["B", B]]) {
    await until(async () => (await P.getByTestId("orphaned").locator('[data-cat="Gym"]').count()) === 1, `${name} shows Gym as orphaned`);
    await until(async () => (await rta(P)) === "Rp1.300", `${name} keeps Gym's 200 assigned`);
  }
  // The user can move it to a real group.
  await A.getByLabel("Move Gym to a group").selectOption({ label: "Bills" });
  await until(async () => (await A.getByTestId("orphaned").count()) === 0, "orphan section gone");
  // D3: deleting a category without transactions returns its money to Ready to Assign.
  await A.getByLabel("Delete category Gym").click();
  assert.match(dialogs.at(-1), /returns to Ready to Assign/);
  await until(async () => (await rta(A)) === "Rp1.500", "Gym's 200 back in Ready to Assign");

  // D3: deleting a category with transactions moves them.
  await addCategory(0, "Food");
  await addCategory(0, "Fun");
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByPlaceholder("Amount").fill("50");
  await A.getByLabel("Inflow").uncheck();
  await A.locator("select").nth(1).selectOption({ label: "Food" });
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByRole("button", { name: "Plan" }).click();
  assert.equal(await cell(A, "Food"), "-Rp50");
  await A.getByLabel("Delete category Food").click();
  await A.locator(".modal select").selectOption({ label: "Rent" });
  await A.getByRole("button", { name: "Move and delete category" }).click();
  await until(async () => (await cell(A, "Rent")) === "Rp1.350", "Rent absorbed Food's 50");
  assert.equal(await A.locator('[data-cat="Food"]').count(), 0);
  assert.equal(await rta(A), "Rp1.500");

  // D4/D8: transfers are two linked transactions and edits mirror.
  await A.getByPlaceholder("New account").fill("Savings");
  await A.getByRole("button", { name: "Add account" }).click();
  await A.getByPlaceholder("New account").fill("Brokerage");
  await A.getByLabel("On budget").uncheck();
  await A.getByRole("button", { name: "Add account" }).click();
  const balance = (name) => A.locator(".accounts li", { hasText: name }).locator(".num").innerText();
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByRole("button", { name: "Transfer", exact: true }).click();
  await A.locator("select").nth(0).selectOption({ label: "Checking" });
  await A.locator("select").nth(1).selectOption({ label: "Savings" });
  await A.getByPlaceholder("Amount").fill("100");
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await until(async () => (await balance("Savings")) === "Rp100", "Savings got the transfer");
  assert.equal(await A.getByText("Transfer to Savings").count(), 1);
  assert.equal(await A.getByText("Transfer from Checking").count(), 1);
  await A.locator("tr[data-tx]", { hasText: "Transfer from Checking" }).getByLabel("Edit transaction").click();
  const edit = A.locator("tr[data-tx] form");
  await edit.getByPlaceholder("Amount").fill("150");
  await edit.getByPlaceholder("Memo").fill("rainy day");
  await edit.getByRole("button", { name: "Save" }).click();
  await until(async () => (await balance("Savings")) === "Rp150", "edit mirrored to the Checking leg");
  assert.equal(await A.locator("tr[data-tx]", { hasText: "Transfer to Savings" }).locator(".memo").innerText(), "rainy day");
  await A.locator("tr[data-tx]", { hasText: "Transfer to Savings" }).getByLabel("Delete transaction").click();
  assert.match(dialogs.at(-1), /both legs/);
  await until(async () => (await balance("Savings")) === "Rp0", "deleting one leg deletes both");
  assert.equal(await A.getByText(/Transfer (to|from)/).count(), 0);

  // D5: money leaving the budget for a tracking account needs a category.
  await A.locator("select").nth(0).selectOption({ label: "Checking" });
  await A.locator("select").nth(1).selectOption({ label: "Brokerage" });
  await A.getByPlaceholder("Amount").fill("100");
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByText("Pick the category this money comes from.").waitFor();
  await A.locator("select").nth(2).selectOption({ label: "Rent" });
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByRole("button", { name: "Plan" }).click();
  await until(async () => (await cell(A, "Rent")) === "Rp1.250", "Rent paid for the Brokerage transfer");
  assert.equal(await rta(A), "Rp1.500");
  // Money coming back from a tracking account is income.
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByRole("button", { name: "Transfer", exact: true }).click();
  await A.locator("select").nth(0).selectOption({ label: "Brokerage" });
  await A.locator("select").nth(1).selectOption({ label: "Checking" });
  await A.getByPlaceholder("Amount").fill("100");
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByRole("button", { name: "Plan" }).click();
  await until(async () => (await rta(A)) === "Rp1.600", "transfer in from tracking is income");

  // D6/D7: splits sum to the amount.
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByRole("button", { name: "Transaction", exact: true }).click();
  await A.getByPlaceholder("Amount").fill("90");
  await A.getByLabel("Inflow").uncheck();
  await A.getByPlaceholder("Memo").fill("split");
  await A.getByRole("button", { name: "Split", exact: true }).click();
  await A.locator('[data-split-line="0"] select').selectOption({ label: "Rent" });
  await A.locator('[data-split-line="0"] input').fill("60");
  await A.getByRole("button", { name: "Add split line" }).click();
  await A.locator('[data-split-line="1"] select').selectOption({ label: "Fun" });
  await A.locator('[data-split-line="1"] input').fill("20");
  assert.match(await A.getByTestId("split-left").innerText(), /10\.00/);
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByText("Split lines add up to 80.00, but the amount is 90.00.").waitFor();
  await A.locator('[data-split-line="1"] input').fill("30");
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.getByText("Split (2)").waitFor();
  await A.getByRole("button", { name: "Plan" }).click();
  await until(async () => (await cell(A, "Rent")) === "Rp1.190", "split line hit Rent");
  assert.equal(await cell(A, "Fun"), "-Rp30");

  // Editing an existing transaction.
  await A.getByRole("button", { name: "All transactions" }).click();
  await A.getByPlaceholder("Amount").fill("5");
  await A.getByPlaceholder("Memo").fill("coffee");
  await A.locator("select").nth(1).selectOption({ label: "Fun" });
  await A.getByRole("button", { name: "Add", exact: true }).click();
  await A.locator("tr[data-tx]", { hasText: "coffee" }).getByLabel("Edit transaction").click();
  await A.locator("tr[data-tx] form").getByPlaceholder("Amount").fill("8");
  await A.locator("tr[data-tx] form").getByRole("button", { name: "Save" }).click();
  await A.getByRole("button", { name: "Plan" }).click();
  await until(async () => (await cell(A, "Fun")) === "-Rp38", "edit changed the amount");

  // Everything converges on the other device.
  await B.evaluate(() => window.zs.sync());
  await until(async () => (await cell(B, "Fun")) === "-Rp38", "B sees the edit");
  assert.equal(await cell(B, "Rent"), "Rp1.190");
  assert.equal(await rta(B), "Rp1.600");
  assert.equal(await rta(A), "Rp1.600");

  // Reload B with no network: the shell comes from the service worker, data from IndexedDB.
  await B.evaluate(() => navigator.serviceWorker.ready);
  await b.ctx.setOffline(true);
  await B.reload();
  await until(async () => (await rta(B)) === "Rp1.600", "B reload offline");
  console.log("OK");
} finally {
  await browser?.close();
  server.kill();
  rmSync(dir, { recursive: true, force: true });
}
