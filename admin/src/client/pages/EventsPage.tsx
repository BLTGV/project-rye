import { Fragment, useMemo, useState } from "react";
import { Link } from "react-router";
import { ChevronDown, ChevronRight, ExternalLink } from "lucide-react";
import { type EventRow, useEvents } from "../lib/api";
import { colorForType, fmtRel, shortId } from "../lib/format";

export function EventsPage() {
  const events = useEvents(300);
  const [q, setQ] = useState("");
  const [openId, setOpenId] = useState<string | null>(null);

  const filtered = useMemo(() => {
    const term = q.trim().toLowerCase();
    if (!term) return events.data ?? [];
    return (events.data ?? []).filter((e) =>
      [
        e.summary,
        e.event_type,
        e.actor_system,
        JSON.stringify(e.properties),
        JSON.stringify(e.participants),
      ]
        .filter(Boolean)
        .some((x) => String(x).toLowerCase().includes(term))
    );
  }, [events.data, q]);

  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-xl font-semibold tracking-tight">Activity</h1>
        <p className="text-sm text-[color:var(--color-ink-muted)]">
          Immutable event log · {filtered.length} of {events.data?.length ?? 0}{" "}
          recent events
        </p>
      </header>

      <div className="card flex items-center gap-3 py-3">
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Filter by type, summary, actor, property…"
          className="flex-1 bg-transparent text-sm placeholder:text-[color:var(--color-ink-dim)] focus:outline-none"
        />
      </div>

      <div className="card overflow-hidden p-0">
        <table className="w-full text-sm">
          <thead className="text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            <tr className="bg-[color:var(--color-surface-2)]/60">
              <th className="px-4 py-2.5 text-left">When</th>
              <th className="px-4 py-2.5 text-left">Type</th>
              <th className="px-4 py-2.5 text-left">Summary</th>
              <th className="px-4 py-2.5 text-left">Actor</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((e) => {
              const isOpen = openId === e.id;
              return (
                <Fragment key={e.id}>
                  <tr
                    tabIndex={0}
                    aria-expanded={isOpen}
                    onClick={() => setOpenId(isOpen ? null : e.id)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter" || event.key === " ") {
                        event.preventDefault();
                        setOpenId(isOpen ? null : e.id);
                      }
                    }}
                    className={
                      "cursor-pointer border-t border-[color:var(--color-line-soft)] align-top outline-none hover:bg-[color:var(--color-surface-2)]/45 focus:bg-[color:var(--color-surface-2)]/60 " +
                      (isOpen ? "bg-[color:var(--color-surface-2)]/35" : "")
                    }
                  >
                    <td className="px-4 py-2.5 text-xs text-[color:var(--color-ink-muted)]">
                      <span className="flex items-center gap-2">
                        {isOpen ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
                        {fmtRel(e.occurred_at)}
                      </span>
                    </td>
                    <td className="px-4 py-2.5">
                      <span className="pill">{e.event_type}</span>
                    </td>
                    <td className="px-4 py-2.5">
                      {e.summary}
                      <PropertyChips p={e.properties} />
                    </td>
                    <td className="px-4 py-2.5 font-mono text-xs text-[color:var(--color-ink-muted)]">
                      {e.actor_system ?? "—"}
                    </td>
                  </tr>
                  {isOpen ? (
                    <tr className="border-t border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)]/25">
                      <td colSpan={4} className="px-4 py-3">
                        <EventDetails event={e} />
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function PropertyChips({ p }: { p: Record<string, unknown> }) {
  if (!p) return null;
  const wanted = [
    "target_type",
    "status",
    "assertion_type",
    "assertion_key",
    "candidate_id",
    "task_node_id",
    "subject_node_id",
    "source_channel",
  ];
  const present = wanted
    .map((k) =>
      p[k] !== undefined && p[k] !== null && typeof p[k] !== "object"
        ? [k, compactValue(String(p[k]))]
        : null
    )
    .filter(Boolean) as [string, string][];
  if (present.length === 0) return null;
  return (
    <div className="mt-1 flex flex-wrap gap-1">
      {present.map(([k, v]) => (
        <span key={k} className="chip">
          <span className="text-[color:var(--color-ink-dim)]">{k}</span>
          <span className="text-[color:var(--color-ink-muted)]">{v}</span>
        </span>
      ))}
    </div>
  );
}

function EventDetails({ event }: { event: EventRow }) {
  const links = recordLinks(event);
  return (
    <div className="grid gap-3 text-xs lg:grid-cols-[minmax(0,1fr)_minmax(260px,380px)]">
      <div className="min-w-0 rounded-lg border border-[color:var(--color-line-soft)] bg-[color:var(--color-bg)]/25 p-3">
        <div className="mb-2 flex flex-wrap gap-x-4 gap-y-1 text-[color:var(--color-ink-muted)]">
          <span>
            <span className="text-[color:var(--color-ink-dim)]">Event</span>{" "}
            <span className="font-mono">{shortId(event.id)}</span>
          </span>
          <span>
            <span className="text-[color:var(--color-ink-dim)]">Occurred</span>{" "}
            {new Date(event.occurred_at).toLocaleString()}
          </span>
          <span>
            <span className="text-[color:var(--color-ink-dim)]">Actor system</span>{" "}
            <span className="font-mono">{event.actor_system ?? "—"}</span>
          </span>
        </div>
        <pre className="max-h-56 overflow-auto rounded-md border border-[color:var(--color-line-soft)] bg-black/20 p-3 font-mono text-[11px] leading-relaxed text-[color:var(--color-ink-muted)]">
          {JSON.stringify(event.properties ?? {}, null, 2)}
        </pre>
      </div>

      <div className="min-w-0 rounded-lg border border-[color:var(--color-line-soft)] bg-[color:var(--color-bg)]/25 p-3">
        <div className="mb-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
          Linked records
        </div>
        {links.length ? (
          <div className="flex flex-col gap-2">
            {links.map((link) => (
              <div
                key={link.id}
                className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)]/45 p-2"
              >
                <div className="flex min-w-0 items-center gap-2">
                  <span
                    className="size-2 shrink-0 rounded-full"
                    style={{ background: colorForType(link.node_type ?? "node") }}
                  />
                  <span className="min-w-0 flex-1 truncate text-[color:var(--color-ink)]">
                    {link.label}
                  </span>
                  {link.role ? <span className="chip shrink-0">{link.role}</span> : null}
                </div>
                <div className="mt-2 flex gap-2">
                  <Link
                    to={`/nodes/${link.id}`}
                    onClick={(event) => event.stopPropagation()}
                    className="btn h-7 text-[11px]"
                  >
                    <ExternalLink size={12} /> Record
                  </Link>
                  <Link
                    to={`/graph/${link.id}`}
                    onClick={(event) => event.stopPropagation()}
                    className="btn h-7 text-[11px]"
                  >
                    Graph
                  </Link>
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="text-[color:var(--color-ink-dim)]">No linked node records.</div>
        )}
      </div>
    </div>
  );
}

interface RecordLink {
  id: string;
  label: string;
  node_type?: string;
  role?: string;
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const NODE_REF_KEYS = new Set([
  "candidate_id",
  "node_id",
  "source_id",
  "target_id",
  "source_node_id",
  "target_node_id",
  "subject_node_id",
  "task_node_id",
]);

function recordLinks(event: EventRow): RecordLink[] {
  const byId = new Map<string, RecordLink>();
  for (const participant of event.participants ?? []) {
    byId.set(participant.node_id, {
      id: participant.node_id,
      label: participant.label ?? shortId(participant.node_id),
      node_type: participant.node_type,
      role: participant.role,
    });
  }
  collectPropertyNodeRefs(event.properties, byId);
  return Array.from(byId.values());
}

function collectPropertyNodeRefs(
  value: unknown,
  links: Map<string, RecordLink>,
  key?: string
) {
  if (typeof value === "string") {
    if (isNodeRefKey(key) && UUID_PATTERN.test(value) && !links.has(value)) {
      links.set(value, {
        id: value,
        label: `${humanizeKey(key ?? "record")} ${shortId(value)}`,
      });
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectPropertyNodeRefs(item, links, key);
    return;
  }
  if (value && typeof value === "object") {
    for (const [childKey, childValue] of Object.entries(value as Record<string, unknown>)) {
      collectPropertyNodeRefs(childValue, links, childKey);
    }
  }
}

function isNodeRefKey(key: string | undefined): boolean {
  return !!key && (NODE_REF_KEYS.has(key) || key.endsWith("_node_id"));
}

function compactValue(value: string): string {
  if (UUID_PATTERN.test(value)) return shortId(value);
  if (value.length > 44) return `${value.slice(0, 40)}…`;
  return value;
}

function humanizeKey(key: string): string {
  return key.replace(/_/g, " ");
}
