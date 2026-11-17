export type Kind = "account" | "category_group" | "category" | "payee" | "transaction" | "budget_entry";

export interface Stamp {
  ts: number;
  op: string;
}

export interface Entity {
  kind: Kind;
  id: string;
  data: Record<string, any>;
  stamps: Record<string, Stamp>;
  deleted: boolean;
}

export interface Op {
  op_id: string;
  ts: number;
  kind: Kind;
  entity_id: string;
  fields: Record<string, unknown>;
  deleted?: boolean;
}

export interface Change extends Entity {
  seq: number;
}

export interface CategoryMonth {
  category_id: string;
  assigned: number;
  activity: number;
  available: number;
}

/** Payment category of one credit card. `category_id` takes budget entries like a category. */
export interface CardPaymentMonth {
  account_id: string;
  category_id: string;
  assigned: number;
  activity: number;
  available: number;
}

export interface BudgetMonth {
  month: string;
  ready_to_assign: number;
  categories: CategoryMonth[];
  /** Absent in data computed by an older core. */
  card_payments?: CardPaymentMonth[];
  /** Live categories whose group is missing or deleted. */
  orphaned_category_ids: string[];
}

/** One category line of a split transaction. */
export interface Split {
  category_id: string;
  amount: number;
  memo?: string | null;
}
