import { Link } from "react-router";
import { AlertTriangle } from "lucide-react";
import { useDisputes } from "../lib/api";
import { colorForType, shortId } from "../lib/format";

export function DisputesPage() {
  const disputes = useDisputes();
  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-xl font-semibold tracking-tight">Active disputes</h1>
        <p className="text-sm text-[color:var(--color-ink-muted)]">
          Subjects where multiple non-superseded assertions of the same type
          coexist. Use <code className="font-mono">resolve_dispute()</code> to
          pick a winner.
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
                    {d.node_type}
                  </span>
                </Link>
                <div className="flex items-center gap-2">
                  <span className="pill text-[color:var(--color-cyan)]">
                    {d.assertion_type}
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
                      <span>Claim {i + 1}</span>
                      <span className="font-mono">{shortId(c.id)}</span>
                    </div>
                    <pre className="overflow-x-auto font-mono text-[11px]">
                      {JSON.stringify(c.claim, null, 2)}
                    </pre>
                    <div className="mt-1 flex items-center justify-between text-[10px] text-[color:var(--color-ink-muted)]">
                      <span className="font-mono">{c.source_event_id ? shortId(c.source_event_id) : "no source"}</span>
                      <span>{c.confidence ?? "—"} confidence</span>
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
