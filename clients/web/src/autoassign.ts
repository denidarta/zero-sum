// Auto-Assign: fill this month's assigned amounts from earlier months. Pure, so the panel
// can show each total before anything is written.
import type { BudgetMonth } from "./types";

export interface AutoAssign {
  id: string;
  label: string;
  /** Sum of the amounts the action would assign. */
  total: number;
  /** Assigned amount per category id. */
  amounts: Map<string, number>;
}

const roundUnit = (ms: number) => Math.round(ms / 1000) * 1000;

/** `prev` is the months before `current`, nearest first. */
export function autoAssigns(prev: BudgetMonth[], current: BudgetMonth): AutoAssign[] {
  const ids = current.categories.map((c) => c.category_id);
  const mean = (get: (b: BudgetMonth, id: string) => number) => (id: string) =>
    roundUnit(prev.reduce((s, b) => s + get(b, id), 0) / Math.max(prev.length, 1));
  const assigned = (b: BudgetMonth, id: string) =>
    b.categories.find((c) => c.category_id === id)?.assigned ?? 0;
  const spent = (b: BudgetMonth, id: string) =>
    Math.max(0, -(b.categories.find((c) => c.category_id === id)?.activity ?? 0));
  const make = (id: string, label: string, pick: (id: string) => number): AutoAssign => {
    const amounts = new Map(ids.map((c) => [c, pick(c)]));
    return { id, label, total: [...amounts.values()].reduce((s, v) => s + v, 0), amounts };
  };
  const last = prev[0];
  return [
    make("assigned-last", "Assigned Last Month", (id) => (last ? assigned(last, id) : 0)),
    make("spent-last", "Spent Last Month", (id) => (last ? spent(last, id) : 0)),
    make("avg-assigned", "Average Assigned", mean(assigned)),
    make("avg-spent", "Average Spent", mean(spent)),
    {
      ...make("reset", "Reset Assigned Amounts", () => 0),
      total: current.categories.reduce((s, c) => s + c.assigned, 0),
    },
  ];
}
