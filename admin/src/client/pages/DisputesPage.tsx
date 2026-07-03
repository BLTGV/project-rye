import { Link } from "react-router";
import { AlertTriangle } from "lucide-react";
import { useDisputes } from "../lib/api";
import { colorForType } from "../lib/format";

export function DisputesPage() {
  const disputes = useDisputes();
  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-xl font-semibold tracking-tight">Conflicting Information</h1>
        <p className="text-sm text-[color:var(--color-ink-muted)]">
          Records where the system has more than one current answer for the same
          business question. Open the record to inspect sources and choose the
          version that should remain current.
        </p>
      </header>

      {disputes.isLoading ? (
        <div className="card">Loading…</div>
      ) : (disputes.data?.length ?? 0) === 0 ? (
        <div className="card flex items-center gap-3 text-sm text-emerald-300">
          <AlertTriangle size={16} /> No competing claims. Clean knowledge state.
        </div>
      ) : (
        <ul className="flex flex-col gap-3">
          {(disputes.data ?? []).map((d) => (
            <li key={`${d.subject_node_id}-${d.assertion_type}`} className="card">
              <div className="flex items-center justify-between">
                <Link
                  to={`/nodes/${d.subject_node_id}`}
                  className="flex items-center gap-2 text-sm hover:text-[color:var(--color-rye)]"
                >
                  <span
                    className="size-2 rounded-full"
                    style={{ background: colorForType(d.node_type) }}
                  />
                  <span className="font-medium">{d.label}</span>
                  <span className="text-xs text-[color:var(--color-ink-dim)]">
                    {humanize(d.node_type)}
                  </span>
                </Link>
                <div className="flex items-center gap-2">
                  <span className="pill text-[color:var(--color-cyan)]">
                    {humanize(d.assertion_type)}
                  </span>
                  <span className="chip">
                    {d.competing_claims} claims
                  </span>
                </div>
              </div>
              <div className="mt-3 grid grid-cols-2 gap-2">
                {d.claims.map((c, i) => (
                  <div
                    key={c.id}
                    className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-2"
                  >
                    <div className="mb-1 flex items-center justify-between text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                      <span>Version {i + 1}</span>
                      <span>{confidenceLabel(c.confidence)}</span>
                    </div>
                    <div className="text-sm leading-6 text-[color:var(--color-ink)]">
                      {formatClaim(c.claim)}
                    </div>
                    <div className="mt-2 flex items-center justify-between text-[10px] text-[color:var(--color-ink-muted)]">
                      <span>{c.source_event_id ? "Source linked" : "No source linked"}</span>
                      <Link to={`/nodes/${d.subject_node_id}`} className="hover:text-[color:var(--color-rye)]">
                        Open record
                      </Link>
                    </div>
                  </div>
                ))}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function formatClaim(value: unknown): string {
  if (!value || typeof value !== "object" || Array.isArray(value)) return String(value ?? "No value");
  const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== null && v !== undefined);
  if (entries.length === 0) return "No value";
  return entries
    .slice(0, 4)
    .map(([key, v]) => `${humanize(key)}: ${String(v)}`)
    .join(" · ");
}

function confidenceLabel(value: unknown): string {
  const number = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(number)) return "Confidence not set";
  if (number >= 0.8) return "High confidence";
  if (number >= 0.5) return "Medium confidence";
  return "Low confidence";
}

function humanize(value: string): string {
  return value
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}
