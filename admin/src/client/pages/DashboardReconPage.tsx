import { Link } from "react-router";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  ArrowUpRight,
  CircleDot,
  FileText,
  Layers,
  Sparkles,
} from "lucide-react";
import type { ReconDashboardResponse } from "../lib/api";
import { fmtNumber, fmtRel } from "../lib/format";

export function DashboardReconPage({ data }: { data: ReconDashboardResponse }) {
  const k = data.kpis;
  const resolvedPct = k.parcel_refs_total
    ? (k.resolved_refs / k.parcel_refs_total) * 100
    : 0;

  return (
    <div className="flex flex-col gap-8">
      <Hero k={k} />

      <section className="grid grid-cols-4 gap-4">
        <Kpi
          accent="rye"
          label="Active leases"
          value={fmtNumber(k.active_leases)}
          sub="non-superseded · across operators"
        />
        <Kpi
          accent="cyan"
          label="Mineral owners"
          value={fmtNumber(k.tracked_owners)}
          sub={`${fmtNumber(k.active_ownership_claims)} active ownership claims`}
        />
        <Kpi
          accent="violet"
          label="Resolution coverage"
          value={`${resolvedPct.toFixed(1)}%`}
          sub={`${fmtNumber(k.resolved_refs)} of ${fmtNumber(k.parcel_refs_total)} parcel refs`}
        />
        <Kpi
          accent="rose"
          label="Unresolved refs"
          value={fmtNumber(k.unresolved_refs)}
          sub="awaiting deterministic match"
          to="/search?type=parcel_reference"
        />
      </section>

      <section className="grid grid-cols-3 gap-4">
        <div className="card col-span-2">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium">Document extraction pipeline</h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">
                Daily rollups from <code className="font-mono">extraction</code>{" "}
                events · runsheets, parcels, mineral owners produced
              </p>
            </div>
            <Link to="/events" className="btn text-xs">
              See activity <ArrowUpRight size={12} />
            </Link>
          </div>
          <div className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={data.extraction}>
                <defs>
                  <linearGradient id="ex" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#d8b948" stopOpacity={0.6} />
                    <stop offset="100%" stopColor="#d8b948" stopOpacity={0} />
                  </linearGradient>
                  <linearGradient id="ex2" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#5ee0ff" stopOpacity={0.55} />
                    <stop offset="100%" stopColor="#5ee0ff" stopOpacity={0} />
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
                />
                <Area
                  dataKey="parcels_created"
                  stroke="#d8b948"
                  fill="url(#ex)"
                  strokeWidth={1.8}
                />
                <Area
                  dataKey="rows_extracted"
                  stroke="#5ee0ff"
                  fill="url(#ex2)"
                  strokeWidth={1.4}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
          <div className="mt-2 flex items-center gap-4 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            <span className="flex items-center gap-1.5">
              <span className="size-2 rounded-full bg-[color:var(--color-rye)]" />
              parcels created
            </span>
            <span className="flex items-center gap-1.5">
              <span className="size-2 rounded-full bg-[color:var(--color-cyan)]" />
              rows extracted
            </span>
          </div>
        </div>

        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium">Counties</h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">
                Parcels by county of record
              </p>
            </div>
          </div>
          <div className="h-60">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={data.counties} layout="vertical" margin={{ left: 0 }}>
                <CartesianGrid stroke="#1c1f29" horizontal={false} />
                <XAxis
                  type="number"
                  stroke="#5d6376"
                  tickLine={false}
                  axisLine={false}
                  tick={{ fontSize: 10 }}
                />
                <YAxis
                  dataKey="county"
                  type="category"
                  stroke="#5d6376"
                  tickLine={false}
                  axisLine={false}
                  tick={{ fontSize: 10, fill: "#9aa0b3" }}
                  width={88}
                />
                <Tooltip
                  contentStyle={{
                    background: "#11131b",
                    border: "1px solid #262a36",
                    borderRadius: 8,
                    fontSize: 12,
                  }}
                />
                <Bar dataKey="parcels" radius={[0, 4, 4, 0]}>
                  {data.counties.map((_, i) => (
                    <Cell key={i} fill={`rgba(216,185,72,${0.35 + 0.06 * i})`} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>
      </section>

      <section className="grid grid-cols-2 gap-4">
        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium">Top mineral owners</h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">
                By active net mineral acres · owner strings as-extracted
              </p>
            </div>
            <span className="chip">{fmtNumber(k.net_acres_under_mgmt)} ac tracked</span>
          </div>
          <table className="w-full text-sm">
            <thead className="text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
              <tr>
                <th className="px-2 py-2 text-left">Owner</th>
                <th className="px-2 py-2 text-right">Claims</th>
                <th className="px-2 py-2 text-right">Net acres</th>
              </tr>
            </thead>
            <tbody>
              {data.topOwners.map((o, i) => (
                <tr
                  key={`${o.owner}-${i}`}
                  className="border-t border-[color:var(--color-line-soft)] align-top"
                >
                  <td className="max-w-[320px] truncate px-2 py-2.5">
                    <OwnerCell s={o.owner} />
                  </td>
                  <td className="px-2 py-2.5 text-right num">{o.claims}</td>
                  <td className="px-2 py-2.5 text-right num text-[color:var(--color-rye)]">
                    {fmtNumber(Math.round(o.net_acres))}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-medium">Top operators · leases</h3>
              <p className="text-xs text-[color:var(--color-ink-muted)]">
                Heads up: name variants signal merge candidates
              </p>
            </div>
            <span className="chip">{fmtNumber(k.active_leases)} active</span>
          </div>
          <table className="w-full text-sm">
            <thead className="text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
              <tr>
                <th className="px-2 py-2 text-left">Lessee</th>
                <th className="px-2 py-2 text-right">Leases</th>
                <th className="px-2 py-2 text-right">Avg royalty</th>
              </tr>
            </thead>
            <tbody>
              {data.topLessees.map((l) => (
                <tr
                  key={l.lessee}
                  className="border-t border-[color:var(--color-line-soft)]"
                >
                  <td className="px-2 py-2.5">{l.lessee}</td>
                  <td className="px-2 py-2.5 text-right num">{l.leases}</td>
                  <td className="px-2 py-2.5 text-right num">
                    {l.avg_royalty
                      ? (l.avg_royalty * 100).toFixed(2) + "%"
                      : "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="grid grid-cols-3 gap-4">
        <div className="card flex flex-col">
          <div className="mb-3 flex items-center gap-2 text-sm">
            <Layers size={14} /> Parcel resolution funnel
          </div>
          <Funnel
            steps={[
              { label: "Parcel refs (extracted)", value: k.parcel_refs_total },
              { label: "Refs with at least one match", value: k.resolved_refs },
              { label: "Canonical parcels", value: k.parcels_total },
            ]}
          />
          <p className="mt-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            edge: <code className="font-mono normal-case">resolves_to</code>
          </p>
        </div>

        <div className="card flex flex-col">
          <div className="mb-3 flex items-center gap-2 text-sm">
            <FileText size={14} /> Document corpus
          </div>
          <div className="grid grid-cols-3 gap-4 text-center">
            <CorpusStat label="Documents" value={k.documents_total} />
            <CorpusStat label="Pages" value={k.pages_total} />
            <CorpusStat label="Tables/Images" value={data.catalog.node_types["table"] ?? 0} />
          </div>
          <p className="mt-3 text-xs text-[color:var(--color-ink-muted)]">
            Average pages per document:{" "}
            <span className="text-[color:var(--color-ink)] num">
              {k.documents_total ? (k.pages_total / k.documents_total).toFixed(1) : "—"}
            </span>
          </p>
        </div>

        <div className="card">
          <div className="mb-3 flex items-center justify-between">
            <h3 className="text-sm font-medium">Live activity</h3>
            <span className="chip">
              <CircleDot size={10} className="text-emerald-400" /> streaming
            </span>
          </div>
          <ul className="flex flex-col">
            {data.recent.slice(0, 8).map((e) => (
              <li
                key={e.id}
                className="flex items-start gap-3 border-b border-[color:var(--color-line-soft)] py-2.5 last:border-b-0"
              >
                <span className="mt-1.5 size-1.5 shrink-0 rounded-full bg-[color:var(--color-rye)]" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-xs text-[color:var(--color-ink)]">
                    {e.summary ??
                      (e.event_type === "extraction" && e.properties?.filename
                        ? `Extracted: ${e.properties.filename}`
                        : e.event_type)}
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

    </div>
  );
}

function Hero({ k }: { k: ReconDashboardResponse["kpis"] }) {
  return (
    <div className="relative overflow-hidden rounded-2xl border border-[color:var(--color-line)] bg-gradient-to-br from-[color:var(--color-surface)] to-[#0d0f17] p-8">
      <div className="grid-tile pointer-events-none absolute inset-0 opacity-60" />
      <div className="absolute -right-20 -top-20 size-72 rounded-full bg-[color:var(--color-rye-glow)] blur-3xl" />
      <div className="relative">
        <div className="mb-6 flex items-center gap-2 text-[10px] uppercase tracking-[0.24em] text-[color:var(--color-ink-dim)]">
          <span className="size-1.5 rounded-full bg-[color:var(--color-rye)]" />
          Mineral rights · operating picture
        </div>
        <div className="grid grid-cols-4 gap-8">
          <HeroMetric label="Parcels" value={k.parcels_total} />
          <HeroMetric
            label="Net mineral acres"
            value={Math.round(k.net_acres_under_mgmt)}
          />
          <HeroMetric label="Documents" value={k.documents_total} />
          <HeroMetric label="Parcel refs" value={k.parcel_refs_total} />
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

function OwnerCell({ s }: { s: string }) {
  const parts = s.split(/[\n,]/).map((x) => x.trim()).filter(Boolean);
  if (parts.length <= 1) return <span>{s || "—"}</span>;
  return (
    <div>
      <span>{parts[0]}</span>
      <span className="ml-2 chip">+{parts.length - 1} more</span>
    </div>
  );
}

function Funnel({ steps }: { steps: { label: string; value: number }[] }) {
  const max = Math.max(...steps.map((s) => s.value), 1);
  return (
    <ol className="flex flex-col gap-2">
      {steps.map((s, i) => {
        const pct = (s.value / max) * 100;
        return (
          <li
            key={s.label}
            className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3"
          >
            <div className="mb-2 flex items-center justify-between text-xs">
              <span>{s.label}</span>
              <span className="num text-[color:var(--color-ink-muted)]">
                {fmtNumber(s.value)}
              </span>
            </div>
            <div className="h-1.5 w-full overflow-hidden rounded-full bg-[color:var(--color-surface-3)]">
              <div
                className="h-full rounded-full"
                style={{
                  width: `${pct}%`,
                  background:
                    "linear-gradient(to right, var(--color-rye), var(--color-rye-soft))",
                  opacity: 1 - i * 0.18,
                }}
              />
            </div>
          </li>
        );
      })}
    </ol>
  );
}

function CorpusStat({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3">
      <div className="num text-2xl font-semibold tracking-tight">
        {fmtNumber(value)}
      </div>
      <div className="mt-1 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
        {label}
      </div>
    </div>
  );
}

export const _SparklesUnused = Sparkles;
