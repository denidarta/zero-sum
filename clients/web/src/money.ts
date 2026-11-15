/** Milliunits to a display string, e.g. 1234500 -> "1,234.50". */
export function fmt(ms: number): string {
  const sign = ms < 0 ? "-" : "";
  const cents = Math.round(Math.abs(ms) / 10);
  const whole = Math.floor(cents / 100).toLocaleString("en-US");
  return `${sign}${whole}.${String(cents % 100).padStart(2, "0")}`;
}

/** Display form in rupiah, e.g. 1234500 -> "Rp1.234.500". Cents show only when present. */
export function fmtMoney(ms: number): string {
  const sign = ms < 0 ? "-" : "";
  const cents = Math.round(Math.abs(ms) / 10);
  const whole = Math.floor(cents / 100).toLocaleString("id-ID");
  const c = cents % 100;
  return `${sign}Rp${whole}${c ? `,${String(c).padStart(2, "0")}` : ""}`;
}

/** Editable form of an amount: "1200" or "1200.5", no separators, so `parse` reads it back. */
export const plain = (ms: number): string =>
  ms % 1000 === 0 ? String(ms / 1000) : String(ms / 1000).replace(/(\.\d*?)0+$/, "$1");

/** Parse "12", "12.5", "1,234.56" into milliunits. Returns null when invalid. */
export function parse(s: string): number | null {
  const m = /^(-?)(\d[\d,]*)?(?:\.(\d{0,3}))?$/.exec(s.trim());
  if (!m || (!m[2] && !m[3])) return null;
  const whole = Number((m[2] ?? "0").replace(/,/g, ""));
  const frac = Number((m[3] ?? "").padEnd(3, "0"));
  const v = whole * 1000 + frac;
  if (!Number.isSafeInteger(v)) return null;
  return m[1] ? -v : v;
}

export const today = () => new Date().toLocaleDateString("sv-SE"); // YYYY-MM-DD
export const thisMonth = () => today().slice(0, 7);

export function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split("-").map(Number) as [number, number];
  const d = new Date(y, m - 1 + delta, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}
