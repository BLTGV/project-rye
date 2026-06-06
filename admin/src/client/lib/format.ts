export function fmtNumber(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return "—";
  if (Math.abs(n) >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (Math.abs(n) >= 10_000) return (n / 1_000).toFixed(0) + "k";
  if (Math.abs(n) >= 1_000) return (n / 1_000).toFixed(1) + "k";
  return n.toLocaleString();
}

export function fmtMoney(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return "—";
  if (Math.abs(n) >= 1_000_000) return "$" + (n / 1_000_000).toFixed(2) + "M";
  if (Math.abs(n) >= 1_000) return "$" + (n / 1_000).toFixed(1) + "k";
  return "$" + n.toLocaleString();
}

export function fmtRel(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  const diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 60) return Math.floor(diff) + "s ago";
  if (diff < 3600) return Math.floor(diff / 60) + "m ago";
  if (diff < 86400) return Math.floor(diff / 3600) + "h ago";
  if (diff < 86400 * 7) return Math.floor(diff / 86400) + "d ago";
  return d.toLocaleDateString();
}

export function fmtDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

const TYPE_COLOR: Record<string, string> = {
  test: "#5ee0ff",
  test_method: "#a78bfa",
  test_standard: "#d8b948",
  wire_spec: "#4ade80",
  equipment: "#ff6f91",
  external_lab: "#fb923c",
  person: "#5ee0ff",
  org: "#a78bfa",
  opportunity: "#d8b948",
  task: "#4ade80",
  project: "#fb923c",
};

export function colorForType(t: string): string {
  return TYPE_COLOR[t] ?? "#9aa0b3";
}

export function shortId(id: string): string {
  if (!id) return "";
  return id.slice(0, 6) + "…" + id.slice(-4);
}
