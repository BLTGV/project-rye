import { Link } from "react-router";
import {
  Area,
  AreaChart,
  CartesianGrid,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  ArrowUpRight,
  ChevronRight,
  CircleDot,
  GitGraph,
  TrendingUp,
} from "lucide-react";
import {
  useCatalog,
  useDashboard,
  type DashboardResponse,
  type KnowledgeDashboardResponse,
  type ReconDashboardResponse,
} from "../lib/api";
import { colorForType, fmtMoney, fmtNumber, fmtRel } from "../lib/format";
import { DashboardReconPage } from "./DashboardReconPage";
import { DashboardKnowledgePage } from "./DashboardKnowledgePage";

export function DashboardPage() {
  const dash = useDashboard();
  const cat = useCatalog();

  if (dash.error || cat.error) {
    return (
      <div className="card text-rose-300">
        <div className="font-medium">Dashboard data is unavailable.</div>
        <p className="mt-2 text-sm leading-5 text-rose-200/80">
          The admin UI could not reach the local Rye API or the API returned an
          error while loading this instance. Check the API status in the sidebar,
          then retry this page.
        </p>
        <div className="mt-3 font-mono text-xs text-rose-200/70">
          {(dash.error || cat.error)?.message ?? "unknown error"}
        </div>
      </div>
    );
  }
  if (!dash.data || !cat.data) return <SkeletonGrid />;

  if (dash.data.kind === "recon") {
    return <DashboardReconPage data={dash.data as ReconDashboardResponse} />;
  }
  if (dash.data.kind === "knowledge") {
    return (
      <DashboardKnowledgePage
        data={dash.data as KnowledgeDashboardResponse}
        catalog={cat.data!}
      />
    );
  }
  const lect = dash.data as DashboardResponse;
  const k = lect.kpis;
  const t = lect.timeline;
  const tops = lect.topClients;
  const recent = lect.recent;
  const c = cat.data!;

  const nodeBreakdown = Object.entries(c.node_types)
    .map(([name, value]) => ({ name, value, color: colorForType(name) }))
    .sort((a, b) => b.value - a.value);

  return (
    <div className="flex flex-col gap-8">
      <Hero
        nodes={k.nodes_total}
        edges={k.edges_total}
        events={k.events_total}
        assertions={k.assertions_total}
      />

      <section className="grid grid-cols-4 gap-4">
        <Kpi
          label="Quote value · 90d"
          value={fmtMoney(k.quote_value_90d)}
          sub={`${fmtNumber(k.quote_count_90d)} quotes`}
          accent="rye"
        />
        <Kpi
          label="Clients · 90d"
          value={fmtNumber(k.unique_clients_90d)}
          sub="unique organizations"
          accent="cyan"
        />
        <Kpi
          label="Active assertions"
          value={fmtNumber(k.active_assertions)}
          sub={`${k.assertions_total - k.active_assertions} superseded`}
          accent="violet"
        />
        <Kpi
          label="Open disputes"
          value={fmtNumber(k.disputed_subjects)}
          sub="competing claims"
          accent="rose"
          to="/disputes"
        />
      </section>

      <section className="grid grid-cols-3 gap-4">
        <div className="card col-span-2">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium text-[color:var(--color-ink)]">
                Quote flow
              </h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">
                Daily new quotes · 90 day rolling window
              </p>
            </div>
            <span className="chip">
              <TrendingUp size={11} /> {fmtMoney(k.quote_value_90d)} pipeline
            </span>
          </div>
          <div className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={t}>
                <defs>
                  <linearGradient id="qf" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#d8b948" stopOpacity={0.5} />
                    <stop offset="100%" stopColor="#d8b948" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid stroke="#1c1f29" vertical={false} />
                <XAxis
                  dataKey="bucket"
                  stroke="#5d6376"
                  tickLine={false}
                  axisLine={false}
                  tick={{ fontSize: 10 }}
                  minTickGap={32}
                />
                <YAxis
                  stroke="#5d6376"
                  tickLine={false}
                  axisLine={false}
                  tick={{ fontSize: 10 }}
                  width={32}
                />
                <Tooltip
                  contentStyle={{
                    background: "#11131b",
                    border: "1px solid #262a36",
                    borderRadius: 8,
                    fontSize: 12,
                  }}
                  labelStyle={{ color: "#9aa0b3" }}
                  formatter={(value: number, name: string) => [
                    name === "value" ? fmtMoney(value) : fmtNumber(value),
                    name === "value" ? "Value" : "Quotes",
                  ]}
                />
                <Area
                  type="monotone"
                  dataKey="value"
                  stroke="#d8b948"
                  fill="url(#qf)"
                  strokeWidth={1.8}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-medium">Node composition</h3>
            <span className="chip">{fmtNumber(k.nodes_total)} nodes</span>
          </div>
          <div className="flex h-44 items-center">
            <ResponsiveContainer width="50%" height="100%">
              <PieChart>
                <Pie
                  data={nodeBreakdown}
                  dataKey="value"
                  innerRadius={42}
                  outerRadius={68}
                  paddingAngle={2}
                  stroke="#0a0b0f"
                  strokeWidth={2}
                >
                  {nodeBreakdown.map((d) => (
                    <Cell key={d.name} fill={d.color} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{
                    background: "#11131b",
                    border: "1px solid #262a36",
                    borderRadius: 8,
                    fontSize: 12,
                  }}
                />
              </PieChart>
            </ResponsiveContainer>
            <ul className="flex w-1/2 flex-col gap-1.5 text-xs">
              {nodeBreakdown.slice(0, 6).map((d) => (
                <li key={d.name} className="flex items-center justify-between gap-2">
                  <span className="flex items-center gap-2">
                    <span
                      className="size-2 rounded-full"
                      style={{ background: d.color }}
                    />
                    <span>{d.name}</span>
                  </span>
                  <span className="num text-[color:var(--color-ink-muted)]">
                    {fmtNumber(d.value)}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </section>

      <section className="grid grid-cols-3 gap-4">
        <div className="card col-span-2">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium">Top clients · by quote value</h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">
                Aggregated from <code className="font-mono">quote_created</code> events
              </p>
            </div>
            <Link to="/events" className="btn text-xs">
              All quotes <ChevronRight size={12} />
            </Link>
          </div>
          <table className="w-full text-sm">
            <thead className="text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
              <tr>
                <th className="px-2 py-2 text-left">Client</th>
                <th className="px-2 py-2 text-right">Quotes</th>
                <th className="px-2 py-2 text-right">Value</th>
                <th className="px-2 py-2 text-right">Most recent</th>
              </tr>
            </thead>
            <tbody>
              {tops.map((c) => (
                <tr
                  key={c.client}
                  className="border-t border-[color:var(--color-line-soft)]"
                >
                  <td className="px-2 py-2.5">
                    <div className="flex items-center gap-2">
                      <span className="grid size-6 place-items-center rounded bg-[color:var(--color-surface-3)] text-[10px] uppercase">
                        {c.client?.slice(0, 2)}
                      </span>
                      <span className="truncate">{c.client ?? "—"}</span>
                    </div>
                  </td>
                  <td className="px-2 py-2.5 text-right num">{c.quote_count}</td>
                  <td className="px-2 py-2.5 text-right num text-[color:var(--color-rye)]">
                    {fmtMoney(c.total_value)}
                  </td>
                  <td className="px-2 py-2.5 text-right text-[color:var(--color-ink-muted)]">
                    {fmtRel(c.last_quote_at)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-medium">Live activity</h3>
            <span className="chip">
              <CircleDot size={10} className="text-emerald-400" /> streaming
            </span>
          </div>
          <ul className="flex flex-col">
            {recent.map((e) => (
              <li
                key={e.id}
                className="flex items-start gap-3 border-b border-[color:var(--color-line-soft)] py-2.5 last:border-b-0"
              >
                <span className="mt-1.5 size-1.5 shrink-0 rounded-full bg-[color:var(--color-rye)]" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-xs text-[color:var(--color-ink)]">
                    {e.summary ?? e.event_type}
                  </div>
                  <div className="mt-0.5 flex items-center gap-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                    <span>{e.event_type}</span>
                    <span>·</span>
                    <span>{fmtRel(e.occurred_at)}</span>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </div>
      </section>

      <section className="card">
        <div className="mb-3 flex items-center justify-between">
          <div>
            <h3 className="text-sm font-medium">Knowledge graph signal</h3>
            <p className="text-xs text-[color:var(--color-ink-muted)]">
              Edges by type · what connects what in this instance
            </p>
          </div>
          <Link to="/graph" className="btn text-xs">
            <GitGraph size={12} /> Explore
          </Link>
        </div>
        <div className="grid grid-cols-3 gap-3">
          {Object.entries(c.edge_types)
            .sort((a, b) => b[1] - a[1])
            .map(([etype, count]) => {
              const max = Math.max(...Object.values(c.edge_types));
              const pct = (count / max) * 100;
              return (
                <div
                  key={etype}
                  className="rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-4"
                >
                  <div className="mb-2 flex items-center justify-between">
                    <span className="font-mono text-xs">{etype}</span>
                    <span className="num text-xs text-[color:var(--color-ink-muted)]">
                      {fmtNumber(count)}
                    </span>
                  </div>
                  <div className="h-1.5 w-full overflow-hidden rounded-full bg-[color:var(--color-surface-3)]">
                    <div
                      className="h-full rounded-full bg-gradient-to-r from-[color:var(--color-rye)] to-[color:var(--color-rye-soft)]"
                      style={{ width: `${pct}%` }}
                    />
                  </div>
                </div>
              );
            })}
        </div>
      </section>
    </div>
  );
}

function Hero({
  nodes,
  edges,
  events,
  assertions,
}: {
  nodes: number;
  edges: number;
  events: number;
  assertions: number;
}) {
  return (
    <div className="relative overflow-hidden rounded-2xl border border-[color:var(--color-line)] bg-gradient-to-br from-[color:var(--color-surface)] to-[#0d0f17] p-8">
      <div className="grid-tile pointer-events-none absolute inset-0 opacity-60" />
      <div className="absolute -right-20 -top-20 size-72 rounded-full bg-[color:var(--color-rye-glow)] blur-3xl" />
      <div className="relative">
        <div className="mb-6 flex items-center gap-2 text-[10px] uppercase tracking-[0.24em] text-[color:var(--color-ink-dim)]">
          <span className="size-1.5 rounded-full bg-[color:var(--color-rye)]" />
          Operating picture
        </div>
        <div className="grid grid-cols-4 gap-8">
          <HeroMetric label="Nodes" value={nodes} />
          <HeroMetric label="Edges" value={edges} />
          <HeroMetric label="Events" value={events} />
          <HeroMetric label="Assertions" value={assertions} />
        </div>
      </div>
    </div>
  );
}

function HeroMetric({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <div className="text-[11px] uppercase tracking-[0.2em] text-[color:var(--color-ink-muted)]">
        {label}
      </div>
      <div className="num mt-1 text-4xl font-semibold tracking-tight text-[color:var(--color-ink)]">
        {fmtNumber(value)}
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
}: {
  label: string;
  value: string;
  sub: string;
  accent: "rye" | "cyan" | "violet" | "rose";
  to?: string;
}) {
  const accentColor =
    accent === "rye"
      ? "var(--color-rye)"
      : accent === "cyan"
      ? "var(--color-cyan)"
      : accent === "violet"
      ? "var(--color-violet)"
      : "var(--color-rose)";
  const inner = (
    <div className="card relative overflow-hidden">
      <span
        className="absolute inset-x-0 top-0 h-px"
        style={{
          background:
            "linear-gradient(to right, transparent, " + accentColor + ", transparent)",
        }}
      />
      <div className="flex items-center justify-between">
        <div className="text-[11px] uppercase tracking-[0.2em] text-[color:var(--color-ink-muted)]">
          {label}
        </div>
        {to ? <ArrowUpRight size={14} className="text-[color:var(--color-ink-dim)]" /> : null}
      </div>
      <div className="num mt-3 text-3xl font-semibold tracking-tight">{value}</div>
      <div className="mt-1 text-xs text-[color:var(--color-ink-muted)]">{sub}</div>
    </div>
  );
  return to ? <Link to={to}>{inner}</Link> : inner;
}

function SkeletonGrid() {
  return (
    <div className="grid grid-cols-4 gap-4">
      {Array.from({ length: 8 }).map((_, i) => (
        <div
          key={i}
          className="h-28 animate-pulse rounded-xl border border-[color:var(--color-line)] bg-[color:var(--color-surface)]"
        />
      ))}
    </div>
  );
}
