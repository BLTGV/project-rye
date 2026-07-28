import { Link } from "react-router";
import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  AlertTriangle,
  ArrowRight,
  ArrowUpRight,
  CircleDot,
  GitGraph,
  History,
  Users,
} from "lucide-react";
import type { KnowledgeDashboardResponse, CatalogResponse } from "../lib/api";
import { colorForType, fmtNumber, fmtRel } from "../lib/format";

export function DashboardKnowledgePage({
  data,
  catalog,
}: {
  data: KnowledgeDashboardResponse;
  catalog: CatalogResponse;
}) {
  const k = data.kpis;
  const factComposition = data.composition
    .map((row) => ({
      ...row,
      total: row.active + row.superseded,
    }))
    .sort((a, b) => b.total - a.total)
    .slice(0, 8);
  const maxFactTypeTotal = Math.max(
    1,
    ...factComposition.map((row) => row.total)
  );
  const supersessionCounts = data.supersessions.reduce(
    (counts, row) => {
      const category = supersessionCategory(row);
      counts[category] = (counts[category] ?? 0) + 1;
      return counts;
    },
    {} as Record<SupersessionCategory, number>
  );
  const policySupersessions =
    (supersessionCounts.scope ?? 0) +
    (supersessionCounts.routing ?? 0) +
    (supersessionCounts.source ?? 0) +
    (supersessionCounts.candidate ?? 0);
  const domainSupersessions = supersessionCounts.domain ?? 0;

  return (
    <div className="flex flex-col gap-8">
      <Hero
        items={[
          { label: "Nodes", value: k.nodes_total },
          { label: "People", value: k.people_total },
          { label: "Events", value: k.events_total },
          { label: "Assertions", value: k.assertions_total },
        ]}
      />

      <section className="grid grid-cols-3 gap-4">
        <Kpi label="Active assertions" value={fmtNumber(k.active_assertions)} sub="current claims" accent="rye" />
        <Kpi
          label="Superseded"
          value={fmtNumber(k.superseded_assertions)}
          sub="replaced claims"
          accent="violet"
          href="#superseded-assertions"
          action="View list"
        />
        <Kpi
          label="Awaiting review"
          value={fmtNumber(k.review_tuples)}
          sub={`${fmtNumber(k.disputed_subjects)} competing`}
          accent="rose"
          to="/review"
          action="Review"
        />
        <Kpi
          label="Open gaps"
          value={fmtNumber(k.open_gaps)}
          sub="questions Rye can't answer yet"
          accent="cyan"
          to="/gaps"
          action="Open"
        />
        <Kpi
          label="Stale digests"
          value={fmtNumber(k.stale_digests)}
          sub="summaries behind their sources"
          accent="violet"
          to="/gaps"
          action="Open"
        />
        <Kpi label="Artifacts" value={fmtNumber(k.artifacts_total)} sub="summaries & documents" accent="cyan" />
      </section>

      {/* activity over time + assertion composition */}
      <section className="grid grid-cols-3 gap-4">
        <div className="card col-span-2">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium">Activity over time</h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">
                Events per month · how knowledge accumulates
              </p>
            </div>
            <span className="chip">{fmtNumber(k.events_total)} events</span>
          </div>
          <div className="h-56">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={data.timeline}>
                <defs>
                  <linearGradient id="act" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#d8b948" stopOpacity={0.5} />
                    <stop offset="100%" stopColor="#d8b948" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid stroke="#1c1f29" vertical={false} />
                <XAxis dataKey="bucket" stroke="#5d6376" tickLine={false} axisLine={false} tick={{ fontSize: 10 }} minTickGap={24} />
                <YAxis stroke="#5d6376" tickLine={false} axisLine={false} tick={{ fontSize: 10 }} width={28} allowDecimals={false} />
                <Tooltip
                  contentStyle={{ background: "#11131b", border: "1px solid #262a36", borderRadius: 8, fontSize: 12 }}
                  labelStyle={{ color: "#9aa0b3" }}
                  formatter={(v: number) => [fmtNumber(v), "Events"]}
                />
                <Area type="monotone" dataKey="count" stroke="#d8b948" fill="url(#act)" strokeWidth={1.8} />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-medium">Assertions by type</h3>
            <span className="chip">{fmtNumber(k.active_assertions)} active</span>
          </div>
          <div className="space-y-2">
            {factComposition.map((row) => {
              const activeWidth = (row.active / maxFactTypeTotal) * 100;
              const supersededWidth = (row.superseded / maxFactTypeTotal) * 100;
              return (
                <div key={row.assertion_type} className="space-y-1">
                  <div className="flex items-center justify-between gap-3 text-xs">
                    <span className="min-w-0 truncate text-[color:var(--color-ink)]" title={row.assertion_type}>
                      {row.assertion_type}
                    </span>
                    <span className="num shrink-0 text-[color:var(--color-ink-muted)]">
                      {fmtNumber(row.total)}
                    </span>
                  </div>
                  <div className="h-2 overflow-hidden rounded-full bg-[color:var(--color-surface-3)]">
                    <div className="flex h-full min-w-1">
                      <div
                        className="bg-[#7c9c5a]"
                        style={{ width: `${activeWidth}%` }}
                        aria-label={`${row.active} active ${row.assertion_type} assertions`}
                      />
                      <div
                        className="bg-[#3a3f4d]"
                        style={{ width: `${supersededWidth}%` }}
                        aria-label={`${row.superseded} superseded ${row.assertion_type} assertions`}
                      />
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
          <div className="mt-4 flex items-center gap-4 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            <span className="flex items-center gap-1.5"><span className="size-2 rounded-sm" style={{ background: "#7c9c5a" }} /> active</span>
            <span className="flex items-center gap-1.5"><span className="size-2 rounded-sm" style={{ background: "#3a3f4d" }} /> superseded</span>
          </div>
        </div>
      </section>

      {/* people↔events + knowledge by subject + disputes */}
      <section className="grid grid-cols-3 gap-4">
        <RankList
          title="People & entities by activity"
          subtitle="Who is connected to the most events"
          icon={<Users size={12} />}
          rows={data.topParticipants.map((p) => ({
            id: p.id,
            label: p.label,
            node_type: p.node_type,
            value: p.events,
            valueLabel: `${p.events}`,
          }))}
        />
        <RankList
          title="Assertions by subject"
          subtitle="Assertions accumulated per node"
          icon={<History size={12} />}
          rows={data.topSubjects.map((s) => ({
            id: s.id,
            label: s.label,
            node_type: s.node_type,
            value: s.facts,
            valueLabel: `${s.facts}`,
            sub: `${s.active} active`,
          }))}
        />

        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-medium">Competing claims</h3>
            <Link to="/review" className="btn text-xs">
              <AlertTriangle size={12} /> Review
            </Link>
          </div>
          {data.disputes.length === 0 ? (
            <p className="text-xs text-emerald-300">No competing claims. Clean knowledge state.</p>
          ) : (
            <ul className="flex flex-col gap-2">
              {data.disputes.map((d) => (
                <li key={`${d.subject_node_id}-${d.assertion_type}`}>
                  <Link to={`/nodes/${d.subject_node_id}`} className="block rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3 hover:border-[color:var(--color-rose)]">
                    <div className="flex items-center justify-between">
                      <span className="flex items-center gap-2 text-sm">
                        <span className="size-2 rounded-full" style={{ background: colorForType(d.node_type) }} />
                        <span className="font-medium">{d.label}</span>
                      </span>
                      <span className="chip text-[color:var(--color-rose)]">{d.competing_claims} claims</span>
                    </div>
                    <div className="mt-1 font-mono text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                      {d.assertion_type}
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>

      {/* superseded assertions */}
      <section id="superseded-assertions" className="card scroll-mt-6">
        <div className="mb-4 flex items-center justify-between">
          <div>
            <h3 className="text-sm font-medium">Superseded assertions</h3>
            <p className="text-xs text-[color:var(--color-ink-muted)]">
              Older claims replaced by newer claims
            </p>
          </div>
          <div className="flex items-center gap-2">
            <span className="chip">{fmtNumber(domainSupersessions)} domain</span>
            <span className="chip">{fmtNumber(policySupersessions)} policy/routing</span>
            <span className="chip"><History size={11} /> {fmtNumber(k.superseded_assertions)} total</span>
          </div>
        </div>
        {data.supersessions.length === 0 ? (
          <p className="text-xs text-[color:var(--color-ink-muted)]">No superseded assertions yet.</p>
        ) : (
          <ul className="flex flex-col gap-2.5">
            {data.supersessions.map((s, i) => (
              <li key={i} className="rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3">
                <div className="mb-2 flex flex-wrap items-center gap-2">
                  <Link to={`/nodes/${s.subject_node_id}`} className="flex items-center gap-2 text-sm hover:text-[color:var(--color-rye)]">
                    <span className="size-2 rounded-full" style={{ background: colorForType(s.node_type) }} />
                    <span className="font-medium">{displaySupersessionSubject(s)}</span>
                  </Link>
                  <span className="pill text-[color:var(--color-cyan)]">{s.assertion_type}</span>
                  <span className="pill">{supersessionCategoryLabel(s)}</span>
                  <span className="pill">
                    changed {changedClaimKeys(s.old_claim, s.new_claim).join(", ")}
                  </span>
                </div>
                {supersessionSubjectNote(s) ? (
                  <p className="mb-2 text-xs text-[color:var(--color-ink-muted)]">
                    {supersessionSubjectNote(s)}
                  </p>
                ) : null}
                <div className="grid grid-cols-[1fr_auto_1fr] items-stretch gap-3">
                  <FactCell claim={s.old_claim} at={s.old_at} tone="old" />
                  <div className="flex items-center text-[color:var(--color-ink-dim)]"><ArrowRight size={16} /></div>
                  <FactCell claim={s.new_claim} at={s.new_at} tone="new" />
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* live activity + edge signal */}
      <section className="grid grid-cols-3 gap-4">
        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-medium">Recent activity</h3>
            <span className="chip"><CircleDot size={10} className="text-emerald-400" /> live</span>
          </div>
          <ul className="flex flex-col">
            {data.recent.map((e) => (
              <li key={e.id} className="flex items-start gap-3 border-b border-[color:var(--color-line-soft)] py-2.5 last:border-b-0">
                <span className="mt-1.5 size-1.5 shrink-0 rounded-full bg-[color:var(--color-rye)]" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-xs">{e.summary ?? e.event_type}</div>
                  <div className="mt-0.5 flex items-center gap-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                    <span>{e.event_type}</span><span>·</span><span>{fmtRel(e.occurred_at)}</span>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </div>

        <div className="card col-span-2">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium">Knowledge graph signal</h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">Edges by type · what connects what</p>
            </div>
            <Link to="/graph" className="btn text-xs"><GitGraph size={12} /> Explore</Link>
          </div>
          <div className="grid grid-cols-3 gap-3">
            {Object.entries(catalog.edge_types).sort((a, b) => b[1] - a[1]).map(([etype, count]) => {
              const max = Math.max(...Object.values(catalog.edge_types));
              return (
                <div key={etype} className="rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-4">
                  <div className="mb-2 flex items-center justify-between">
                    <span className="font-mono text-xs">{etype}</span>
                    <span className="num text-xs text-[color:var(--color-ink-muted)]">{fmtNumber(count)}</span>
                  </div>
                  <div className="h-1.5 w-full overflow-hidden rounded-full bg-[color:var(--color-surface-3)]">
                    <div className="h-full rounded-full bg-gradient-to-r from-[color:var(--color-rye)] to-[color:var(--color-rye-soft)]" style={{ width: `${(count / max) * 100}%` }} />
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </section>
    </div>
  );
}

function FactCell({ claim, at, tone }: { claim: Record<string, unknown>; at: string | null; tone: "old" | "new" }) {
  const text = formatClaimSummary(claim);
  return (
    <div
      className={
        "rounded-md border p-2 " +
        (tone === "new"
          ? "border-[color:var(--color-rye)]/40 bg-[color:var(--color-rye-glow)]/10"
          : "border-[color:var(--color-line)] bg-[color:var(--color-surface-3)] opacity-70")
      }
    >
      <div className="mb-1 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
        {tone === "new" ? "now" : "was"} · {at ? fmtRel(at) : "—"}
      </div>
      <div className={"text-xs " + (tone === "old" ? "line-through decoration-[color:var(--color-ink-dim)]/50" : "text-[color:var(--color-ink)]")}>
        {text}
      </div>
    </div>
  );
}

function displaySupersessionSubject(
  row: KnowledgeDashboardResponse["supersessions"][number]
): string {
  if (row.node_type === "review_context" && row.label === "Needs Context") {
    return "Needs Context routing bucket";
  }
  return row.label;
}

function supersessionSubjectNote(
  row: KnowledgeDashboardResponse["supersessions"][number]
): string | null {
  if (row.node_type === "review_context" && row.label === "Needs Context") {
    return "System policy for source items that could not be safely routed to a project or workflow yet. These are not accepted business facts.";
  }
  if (row.node_type === "onboarding_scope") {
    return "Scope policy/history, not application data.";
  }
  return null;
}

type SupersessionCategory =
  | "domain"
  | "scope"
  | "routing"
  | "source"
  | "candidate";

function supersessionCategory(
  row: KnowledgeDashboardResponse["supersessions"][number]
): SupersessionCategory {
  if (row.node_type === "onboarding_scope" || row.assertion_type.startsWith("scope_")) {
    return "scope";
  }
  if (
    row.node_type === "review_context" ||
    row.assertion_type === "holding_context" ||
    row.assertion_type === "relevance_rule" ||
    row.assertion_type === "edge_policy" ||
    row.assertion_type === "task_policy"
  ) {
    return "routing";
  }
  if (
    row.assertion_type === "source_context_confirmation" ||
    row.assertion_type === "source_purpose" ||
    row.assertion_type === "classification_rationale" ||
    row.assertion_type === "holding_review_context"
  ) {
    return "source";
  }
  if (row.assertion_type === "candidate_status") {
    return "candidate";
  }
  return "domain";
}

function supersessionCategoryLabel(
  row: KnowledgeDashboardResponse["supersessions"][number]
): string {
  switch (supersessionCategory(row)) {
    case "scope":
      return "scope policy";
    case "routing":
      return "routing policy";
    case "source":
      return "source context";
    case "candidate":
      return "candidate lifecycle";
    case "domain":
      return "domain assertion";
  }
}

function changedClaimKeys(
  oldClaim: Record<string, unknown>,
  newClaim: Record<string, unknown>
) {
  const oldKeys = Object.keys(oldClaim ?? {});
  const newKeys = Object.keys(newClaim ?? {});
  const keys = Array.from(new Set([...oldKeys, ...newKeys])).filter((key) => {
    return JSON.stringify(oldClaim?.[key]) !== JSON.stringify(newClaim?.[key]);
  });
  return keys.length > 0 ? keys : ["claim"];
}

function formatClaimSummary(claim: Record<string, unknown>): string {
  if (!claim || typeof claim !== "object") return String(claim ?? "");

  for (const key of ["status", "purpose", "text", "action", "context_id"]) {
    if (claim[key] != null) return `${key}: ${formatClaimValue(claim[key])}`;
  }

  const entries = Object.entries(claim).slice(0, 3);
  const text = entries
    .map(([key, value]) => `${key}: ${formatClaimValue(value)}`)
    .join("; ");
  const remaining = Object.keys(claim).length - entries.length;
  return remaining > 0 ? `${text}; +${remaining} more` : text;
}

function formatClaimValue(value: unknown): string {
  if (Array.isArray(value)) {
    const text: string = value.map((item) => formatClaimValue(item)).join(", ");
    return text.length > 180 ? `${text.slice(0, 177)}...` : text;
  }
  if (value && typeof value === "object") {
    const text = JSON.stringify(value);
    return text.length > 180 ? `${text.slice(0, 177)}...` : text;
  }
  return String(value ?? "");
}

function RankList({
  title,
  subtitle,
  icon,
  rows,
}: {
  title: string;
  subtitle: string;
  icon: React.ReactNode;
  rows: { id: string; label: string; node_type: string; value: number; valueLabel: string; sub?: string }[];
}) {
  const max = Math.max(1, ...rows.map((r) => r.value));
  return (
    <div className="card">
      <div className="mb-3">
        <h3 className="flex items-center gap-2 text-sm font-medium">{icon} {title}</h3>
        <p className="text-xs text-[color:var(--color-ink-muted)]">{subtitle}</p>
      </div>
      <ul className="flex flex-col gap-2">
        {rows.map((r) => (
          <li key={r.id}>
            <Link to={`/nodes/${r.id}`} className="group block">
              <div className="mb-1 flex items-center justify-between gap-2 text-xs">
                <span className="flex min-w-0 items-center gap-2">
                  <span className="size-2 shrink-0 rounded-full" style={{ background: colorForType(r.node_type) }} />
                  <span className="truncate group-hover:text-[color:var(--color-rye)]">{r.label}</span>
                </span>
                <span className="num shrink-0 text-[color:var(--color-ink-muted)]">
                  {r.valueLabel}
                  {r.sub ? <span className="ml-1 text-[10px] text-[color:var(--color-ink-dim)]">· {r.sub}</span> : null}
                </span>
              </div>
              <div className="h-1.5 w-full overflow-hidden rounded-full bg-[color:var(--color-surface-3)]">
                <div className="h-full rounded-full" style={{ width: `${(r.value / max) * 100}%`, background: colorForType(r.node_type) }} />
              </div>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

function Hero({ items }: { items: { label: string; value: number }[] }) {
  return (
    <div className="relative overflow-hidden rounded-2xl border border-[color:var(--color-line)] bg-gradient-to-br from-[color:var(--color-surface)] to-[#0d0f17] p-8">
      <div className="grid-tile pointer-events-none absolute inset-0 opacity-60" />
      <div className="absolute -right-20 -top-20 size-72 rounded-full bg-[color:var(--color-rye-glow)] blur-3xl" />
      <div className="relative">
        <div className="mb-6 flex items-center gap-2 text-[10px] uppercase tracking-[0.24em] text-[color:var(--color-ink-dim)]">
          <span className="size-1.5 rounded-full bg-[color:var(--color-rye)]" /> Operating picture
        </div>
        <div className="grid grid-cols-4 gap-8">
          {items.map((m) => (
            <div key={m.label}>
              <div className="text-[11px] uppercase tracking-[0.2em] text-[color:var(--color-ink-muted)]">{m.label}</div>
              <div className="num mt-1 text-4xl font-semibold tracking-tight text-[color:var(--color-ink)]">{fmtNumber(m.value)}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function Kpi({
  label,
  value,
  sub,
  accent,
  to,
  href,
  action,
}: {
  label: string;
  value: string;
  sub: string;
  accent: "rye" | "cyan" | "violet" | "rose";
  to?: string;
  href?: string;
  action?: string;
}) {
  const accentColor =
    accent === "rye" ? "var(--color-rye)" : accent === "cyan" ? "var(--color-cyan)" : accent === "violet" ? "var(--color-violet)" : "var(--color-rose)";
  const isLinked = Boolean(to || href);
  const inner = (
    <div className={"card relative overflow-hidden " + (isLinked ? "transition hover:border-[color:var(--color-rye)]" : "")}>
      <span className="absolute inset-x-0 top-0 h-px" style={{ background: "linear-gradient(to right, transparent, " + accentColor + ", transparent)" }} />
      <div className="flex items-center justify-between">
        <div className="text-[11px] uppercase tracking-[0.2em] text-[color:var(--color-ink-muted)]">{label}</div>
        {isLinked ? <ArrowUpRight size={14} className="text-[color:var(--color-ink-dim)]" /> : null}
      </div>
      <div className="num mt-3 text-3xl font-semibold tracking-tight">{value}</div>
      <div className="mt-1 flex items-center justify-between gap-2 text-xs text-[color:var(--color-ink-muted)]">
        <span>{sub}</span>
        {action ? (
          <span className="shrink-0 text-[11px] text-[color:var(--color-rye)]">
            {action}
          </span>
        ) : null}
      </div>
    </div>
  );
  if (to) return <Link to={to}>{inner}</Link>;
  if (href) return <a href={href}>{inner}</a>;
  return inner;
}
