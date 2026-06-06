import { useMemo, useState } from "react";
import { Link } from "react-router";
import { Filter, Search } from "lucide-react";
import { useCatalog, useNodeSearch } from "../lib/api";
import type { NodeRow } from "../lib/api";
import { colorForType, fmtNumber, fmtRel, shortId } from "../lib/format";

export function SearchPage() {
  const [q, setQ] = useState("");
  const [type, setType] = useState<string | null>(null);
  const catalog = useCatalog();
  const search = useNodeSearch(q, type, 80);

  const types = useMemo(
    () =>
      Object.entries(catalog.data?.node_types ?? {}).sort((a, b) => b[1] - a[1]),
    [catalog.data]
  );
  const rows = search.data?.rows ?? [];

  return (
    <div className="flex min-w-0 flex-col gap-5">
      <header className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div className="min-w-0">
          <h1 className="text-xl font-semibold tracking-tight">Records</h1>
          <p className="max-w-3xl text-sm text-[color:var(--color-ink-muted)]">
            Search source evidence, classification context, and accepted knowledge.
            Source items are intake records until validated into facts, tasks, or graph connections.
          </p>
        </div>
        <div className="shrink-0 text-xs text-[color:var(--color-ink-dim)]">
          {search.data ? `${fmtNumber(search.data.total)} matches` : ""}
        </div>
      </header>

      <div className="card flex min-w-0 items-center gap-3 py-3">
        <Search size={16} className="shrink-0 text-[color:var(--color-ink-muted)]" />
        <input
          autoFocus
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="e.g. MIL-DTL-83513, AS22759, Lockheed…"
          className="min-w-0 flex-1 bg-transparent text-sm placeholder:text-[color:var(--color-ink-dim)] focus:outline-none"
        />
        <span className="chip shrink-0">
          <Filter size={11} /> {type ?? "all types"}
        </span>
      </div>

      <div className="flex gap-2 overflow-x-auto pb-2 scrollbar">
        <Pill active={type === null} onClick={() => setType(null)}>
          All
        </Pill>
        {types.map(([name, count]) => (
          <Pill
            key={name}
            active={type === name}
            onClick={() => setType(name)}
            color={colorForType(name)}
          >
            {name} · {fmtNumber(count)}
          </Pill>
        ))}
      </div>

      <div className="card hidden overflow-hidden p-0 lg:block">
        <div className="overflow-x-auto scrollbar">
          <table className="w-full table-fixed text-sm">
            <colgroup>
              <col />
              <col className="w-36" />
              <col className="w-36" />
              <col className="w-24" />
              <col className="w-24" />
            </colgroup>
            <thead className="text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
              <tr className="bg-[color:var(--color-surface-2)]/60">
                <th className="px-4 py-2.5 text-left">Label</th>
                <th className="px-4 py-2.5 text-left">Type</th>
                <th className="px-4 py-2.5 text-left">Source</th>
                <th className="px-4 py-2.5 text-right">Created</th>
                <th className="px-4 py-2.5 text-right">ID</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr
                  key={r.id}
                  className="border-t border-[color:var(--color-line-soft)] hover:bg-[color:var(--color-surface-2)]"
                >
                  <td className="min-w-0 px-4 py-2.5">
                    <Link
                      to={`/nodes/${r.id}`}
                      className="flex min-w-0 items-center gap-2 text-[color:var(--color-ink)] hover:text-[color:var(--color-rye)]"
                      title={displaySearchLabel(r) || "(unlabeled)"}
                    >
                      <span
                        className="size-2 shrink-0 rounded-full"
                        style={{ background: colorForType(r.node_type) }}
                      />
                      <span className="truncate">
                        {displaySearchLabel(r) || <span className="italic text-[color:var(--color-ink-dim)]">(unlabeled)</span>}
                      </span>
                    </Link>
                  </td>
                  <td className="truncate px-4 py-2.5 text-[color:var(--color-ink-muted)]" title={r.node_type}>
                    {r.node_type}
                  </td>
                  <td className="truncate px-4 py-2.5 text-[color:var(--color-ink-muted)]" title={r.external_source ?? undefined}>
                    {r.external_source ?? "—"}
                  </td>
                  <td className="px-4 py-2.5 text-right text-[color:var(--color-ink-muted)]">
                    {fmtRel(r.created_at)}
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-[10px] text-[color:var(--color-ink-dim)]">
                    {shortId(r.id)}
                  </td>
                </tr>
              ))}
              {search.isLoading
                ? Array.from({ length: 8 }).map((_, i) => (
                    <tr key={`s-${i}`} className="border-t border-[color:var(--color-line-soft)]">
                      <td colSpan={5} className="px-4 py-3">
                        <div className="h-4 w-full animate-pulse rounded bg-[color:var(--color-surface-2)]" />
                      </td>
                    </tr>
                  ))
                : null}
              {!search.isLoading && rows.length === 0 ? (
                <tr>
                  <td
                    colSpan={5}
                    className="px-4 py-10 text-center text-xs text-[color:var(--color-ink-dim)]"
                  >
                    No records match
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </div>

      <div className="grid gap-3 lg:hidden">
        {rows.map((r) => (
          <Link
            key={r.id}
            to={`/nodes/${r.id}`}
            className="card block p-4 transition hover:border-[color:var(--color-rye)]"
          >
            <div className="flex min-w-0 items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="flex min-w-0 items-center gap-2 text-sm font-medium text-[color:var(--color-ink)]">
                  <span
                    className="size-2 shrink-0 rounded-full"
                    style={{ background: colorForType(r.node_type) }}
                  />
                  <span className="truncate">
                    {displaySearchLabel(r) || <span className="italic text-[color:var(--color-ink-dim)]">(unlabeled)</span>}
                  </span>
                </div>
                <div className="mt-2 flex flex-wrap gap-1">
                  <span className="pill">{r.node_type}</span>
                  <span className="pill">{r.external_source ?? "no source"}</span>
                </div>
              </div>
              <span className="shrink-0 text-xs text-[color:var(--color-ink-muted)]">
                {fmtRel(r.created_at)}
              </span>
            </div>
            <div className="mt-3 font-mono text-[10px] text-[color:var(--color-ink-dim)]">
              {shortId(r.id)}
            </div>
          </Link>
        ))}
        {search.isLoading
          ? Array.from({ length: 6 }).map((_, i) => (
              <div key={`m-${i}`} className="card p-4">
                <div className="h-4 w-3/4 animate-pulse rounded bg-[color:var(--color-surface-2)]" />
                <div className="mt-3 h-4 w-1/2 animate-pulse rounded bg-[color:var(--color-surface-2)]" />
              </div>
            ))
          : null}
        {!search.isLoading && rows.length === 0 ? (
          <div className="card py-10 text-center text-xs text-[color:var(--color-ink-dim)]">
            No records match
          </div>
        ) : null}
      </div>
    </div>
  );
}

function Pill({
  children,
  active,
  onClick,
  color,
}: {
  children: React.ReactNode;
  active: boolean;
  onClick: () => void;
  color?: string;
}) {
  return (
    <button
      onClick={onClick}
      className={
        "flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs whitespace-nowrap transition " +
        (active
          ? "border-[color:var(--color-rye)] bg-[color:var(--color-rye)]/10 text-white"
          : "border-[color:var(--color-line)] bg-[color:var(--color-surface)] text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)]")
      }
    >
      {color ? <span className="size-2 rounded-full" style={{ background: color }} /> : null}
      {children}
    </button>
  );
}

function displaySearchLabel(node: NodeRow): string {
  if (node.node_type !== "source_item") return node.label;
  const props = asRecord(node.properties);
  const metadata = asRecord(props.metadata);
  if (firstString(metadata.provider, props.provider) !== "slack") return node.label;

  const channel = firstString(metadata.channel_name);
  const author = firstString(metadata.author_label);
  const authorId = firstString(metadata.author_id);
  let label = node.label;
  if (author && authorId) {
    label = label.replace(new RegExp(`<@${escapeRegExp(authorId)}>`, "g"), author);
  }
  if (channel && new RegExp(`^Slack #${escapeRegExp(channel)}: F[A-Z0-9]+$`).test(label)) {
    return `Slack file attachment in #${channel}`;
  }
  if (channel) {
    const body = label
      .replace(new RegExp(`^Slack #${escapeRegExp(channel)}:\\s*`), "")
      .replace(/^<@[A-Z0-9]+>\s*/, "")
      .replace(/<@[A-Z0-9]+>/g, "@mentioned user");
    if (body && body !== label) return `${author ?? "Slack message"} in #${channel}: ${body}`;
  }
  return label;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
    if (typeof value === "number" || typeof value === "boolean") return String(value);
  }
  return null;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
