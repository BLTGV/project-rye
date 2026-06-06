import { useEffect, useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router";
import {
  Activity,
  AlertTriangle,
  CircuitBoard,
  LayoutDashboard,
  Network,
  Search,
} from "lucide-react";
import { useInstance } from "../lib/instance";
import { CommandPalette } from "./CommandPalette";

const NAV: { to: string; label: string; Icon: typeof LayoutDashboard }[] = [
  { to: "/", label: "Overview", Icon: LayoutDashboard },
  { to: "/search", label: "Records", Icon: Search },
  { to: "/graph", label: "Graph", Icon: Network },
  { to: "/events", label: "Activity", Icon: Activity },
  { to: "/disputes", label: "Disputes", Icon: AlertTriangle },
];

export function AppLayout() {
  const [paletteOpen, setPaletteOpen] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((v) => !v);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="grid min-h-screen grid-cols-[224px_minmax(0,1fr)] text-[color:var(--color-ink)]">
      {/* Sidebar */}
      <aside className="sticky top-0 flex h-screen min-h-0 flex-col overflow-hidden border-r border-[color:var(--color-line)] bg-[color:var(--color-surface)]/70 backdrop-blur">
        <div className="shrink-0 border-b border-[color:var(--color-line-soft)] px-5 py-5">
          <div className="flex items-center gap-2">
            <RyeMark />
            <div className="flex flex-col leading-tight">
              <span className="text-sm font-semibold tracking-tight">Rye</span>
              <span className="text-[10px] uppercase tracking-[0.18em] text-[color:var(--color-ink-dim)]">
                admin console
              </span>
            </div>
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-3 py-3 scrollbar">
          <nav className="flex flex-col gap-0.5">
            {NAV.map(({ to, label, Icon }) => (
              <NavLink
                key={to}
                to={to}
                end={to === "/"}
                className={({ isActive }) =>
                  [
                    "group flex items-center gap-3 rounded-md px-3 py-2 text-sm transition",
                    isActive
                      ? "bg-[color:var(--color-surface-2)] text-white"
                      : "text-[color:var(--color-ink-muted)] hover:bg-[color:var(--color-surface-2)] hover:text-white",
                  ].join(" ")
                }
              >
                <Icon size={15} className="shrink-0 opacity-80" />
                <span>{label}</span>
              </NavLink>
            ))}
          </nav>
        </div>

        <div className="shrink-0 border-t border-[color:var(--color-line-soft)] bg-[color:var(--color-surface)]/80 px-4 py-4">
          <div className="flex flex-col gap-3">
          <InstancePicker />
          <button
            onClick={() => setPaletteOpen(true)}
            className="flex items-center justify-between rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] px-3 py-2 text-xs text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)] hover:text-white"
          >
            <span className="flex items-center gap-2">
              <Search size={13} /> Quick find
            </span>
            <kbd className="font-mono text-[10px] text-[color:var(--color-ink-dim)]">
              ⌘K
            </kbd>
          </button>
          <a
            href="https://projectrye.dev"
            target="_blank"
            rel="noreferrer"
            className="text-[10px] uppercase tracking-[0.18em] text-[color:var(--color-ink-dim)] hover:text-[color:var(--color-rye)]"
          >
            projectrye.dev ↗
          </a>
          </div>
        </div>
      </aside>

      {/* Main */}
      <main className="flex min-h-screen min-w-0 flex-col">
        <TopBar onOpenPalette={() => setPaletteOpen(true)} />
        <div className="min-w-0 flex-1 overflow-x-hidden px-4 py-6 scrollbar md:px-8">
          <Outlet />
        </div>
      </main>

      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        onNavigate={(path) => {
          setPaletteOpen(false);
          navigate(path);
        }}
      />
    </div>
  );
}

function TopBar({ onOpenPalette }: { onOpenPalette: () => void }) {
  const { current, error, loading } = useInstance();
  const statusLabel = error ? "offline" : loading ? "checking" : "live";
  return (
    <div className="sticky top-0 z-10 flex min-w-0 items-center justify-between gap-4 border-b border-[color:var(--color-line)] bg-[color:var(--color-canvas)]/80 px-4 py-3 backdrop-blur md:px-8">
      <div className="flex items-center gap-3">
        <span className="text-[10px] uppercase tracking-[0.22em] text-[color:var(--color-ink-dim)]">
          Instance
        </span>
        <span className="font-mono text-xs text-[color:var(--color-ink)]">
          {current || "—"}
        </span>
        <span
          className="chip"
          title={error ? `Rye API unavailable: ${error}` : undefined}
        >
          {error ? (
            <span className="size-2 rounded-full bg-[color:var(--color-rose)]" />
          ) : loading ? (
            <span className="size-2 rounded-full bg-[color:var(--color-ink-dim)]" />
          ) : (
            <span className="live-dot" />
          )}
          {statusLabel}
        </span>
      </div>
      <button
        onClick={onOpenPalette}
        className="hidden w-72 max-w-[45vw] items-center justify-between gap-2 rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface)] px-3 py-1.5 text-left text-xs text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)] sm:flex"
      >
        <span className="flex min-w-0 items-center gap-2">
          <Search size={13} />
          <span className="truncate">Search records, standards, clients…</span>
        </span>
        <kbd className="font-mono text-[10px] text-[color:var(--color-ink-dim)]">
          ⌘K
        </kbd>
      </button>
    </div>
  );
}

function InstancePicker() {
  const { instances, current, setCurrent, loading, error } = useInstance();
  if (loading) {
    return <div className="card-flat px-3 py-2 text-xs text-[color:var(--color-ink-dim)]">Loading…</div>;
  }
  if (error) {
    return (
      <div className="rounded-md border border-rose-500/40 bg-rose-500/10 px-3 py-2 text-[11px] leading-4 text-rose-200">
        Local Rye API unavailable.
        <div className="mt-1 font-mono text-[10px] text-rose-200/80">{error}</div>
      </div>
    );
  }
  if (instances.length === 0) {
    return (
      <div className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-[11px] text-amber-300">
        No Rye instances configured in the local API environment.
      </div>
    );
  }
  return (
    <label className="flex flex-col gap-1">
      <span className="text-[10px] uppercase tracking-[0.18em] text-[color:var(--color-ink-dim)]">
        Instance
      </span>
      <select
        className="input text-xs"
        value={current}
        onChange={(e) => setCurrent(e.target.value)}
      >
        {instances.map((i) => (
          <option key={i.id} value={i.id}>
            {i.label}
          </option>
        ))}
      </select>
    </label>
  );
}

function RyeMark() {
  return (
    <svg width="22" height="22" viewBox="0 0 32 32" fill="none">
      <defs>
        <linearGradient id="g" x1="0" x2="1" y1="0" y2="1">
          <stop offset="0" stopColor="#ecd97a" />
          <stop offset="1" stopColor="#b8901f" />
        </linearGradient>
      </defs>
      <circle cx="16" cy="16" r="14" fill="url(#g)" />
      <path
        d="M16 6 v20 M10 11 c4 0 6 2 6 5 M22 11 c-4 0 -6 2 -6 5 M9 17 c5 0 7 2 7 5 M23 17 c-5 0 -7 2 -7 5"
        stroke="#0a0b0f"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  );
}

export { CircuitBoard };
