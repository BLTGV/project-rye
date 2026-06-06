import { useEffect, useState } from "react";
import { Command } from "cmdk";
import { useInstance } from "../lib/instance";
import { colorForType, shortId } from "../lib/format";

interface Props {
  open: boolean;
  onClose: () => void;
  onNavigate: (path: string) => void;
}

interface Hit {
  id: string;
  node_type: string;
  label: string;
}

export function CommandPalette({ open, onClose, onNavigate }: Props) {
  const { current } = useInstance();
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<Hit[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!open) {
      setQ("");
      setHits([]);
    }
  }, [open]);

  useEffect(() => {
    if (!open || !current) return;
    const term = q.trim();
    if (term.length < 2) {
      setHits([]);
      return;
    }
    let cancelled = false;
    setLoading(true);
    const url = new URL("/api/nodes", window.location.origin);
    url.searchParams.set("q", term);
    url.searchParams.set("instance", current);
    url.searchParams.set("limit", "12");
    fetch(url)
      .then((r) => r.json() as Promise<{ rows: Hit[] }>)
      .then((data) => {
        if (!cancelled)
          setHits(
            (data.rows ?? []).map((r) => ({
              id: r.id,
              node_type: r.node_type,
              label: r.label,
            }))
          );
      })
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [q, open, current]);

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center bg-black/60 pt-24" onClick={onClose}>
      <div
        className="w-[640px] overflow-hidden rounded-xl border border-[color:var(--color-line)] bg-[color:var(--color-surface)] shadow-[0_24px_80px_-20px_rgba(0,0,0,0.8)]"
        onClick={(e) => e.stopPropagation()}
      >
        <Command shouldFilter={false} loop label="Quick find">
          <div className="flex items-center gap-3 border-b border-[color:var(--color-line)] px-4 py-3">
            <span className="text-[color:var(--color-rye)]">⌘</span>
            <Command.Input
              autoFocus
              value={q}
              onValueChange={setQ}
              placeholder="Search records, standards, clients…"
              className="w-full bg-transparent text-sm placeholder:text-[color:var(--color-ink-dim)] focus:outline-none"
            />
            {loading ? <span className="text-xs text-[color:var(--color-ink-dim)]">searching…</span> : null}
          </div>
          <Command.List className="max-h-[420px] overflow-y-auto p-2 scrollbar">
            {q.length < 2 ? (
              <div className="px-3 py-8 text-center text-xs text-[color:var(--color-ink-dim)]">
                Type to search nodes by label, standard, or property…
              </div>
            ) : hits.length === 0 && !loading ? (
              <div className="px-3 py-8 text-center text-xs text-[color:var(--color-ink-dim)]">
                No matches
              </div>
            ) : null}
            {hits.map((h) => (
              <Command.Item
                key={h.id}
                value={h.id}
                onSelect={() => onNavigate(`/nodes/${h.id}`)}
                className="group flex cursor-pointer items-center justify-between rounded-md px-3 py-2 text-sm aria-selected:bg-[color:var(--color-surface-2)]"
              >
                <div className="flex min-w-0 items-center gap-3">
                  <span
                    className="size-2 shrink-0 rounded-full"
                    style={{ background: colorForType(h.node_type) }}
                  />
                  <span className="truncate">{h.label}</span>
                </div>
                <div className="flex items-center gap-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                  <span>{h.node_type}</span>
                  <span className="font-mono">{shortId(h.id)}</span>
                </div>
              </Command.Item>
            ))}
          </Command.List>
          <div className="flex items-center justify-between border-t border-[color:var(--color-line)] px-4 py-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            <span>↵ open • esc close</span>
            <span>fuzzy via pg_trgm</span>
          </div>
        </Command>
      </div>
    </div>
  );
}
