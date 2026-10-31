// Thin typed wrapper over the Rust core compiled to WASM. Merge and budget
// rules live in Rust only, so this client cannot disagree with the server.
import init, { budget, entry_id, merge } from "./wasm-pkg/zero_sum_wasm.js";
import type { BudgetMonth, Entity, Op } from "./types";

export const loadCore = () => init();

export function mergeOp(entity: Entity | null, op: Op): { state: Entity; changed: boolean } {
  return JSON.parse(merge(JSON.stringify(entity), JSON.stringify(op)));
}

export function computeBudget(entities: Entity[], month: string): BudgetMonth {
  return JSON.parse(budget(JSON.stringify(entities), month));
}

export const budgetEntryId = (categoryId: string, month: string): string =>
  entry_id(categoryId, month);
