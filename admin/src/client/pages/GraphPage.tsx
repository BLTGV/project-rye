import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { ExternalLink, GitBranch, Network, Search } from "lucide-react";
import { GraphCanvas } from "../components/GraphCanvas";
import { useInstance } from "../lib/instance";
import { useNeighborhood, useNodeSearch } from "../lib/api";
import { colorForType, shortId } from "../lib/format";

export function GraphPage() {
  const { id: idFromUrl } = useParams();
  const navigate = useNavigate();
  const { current } = useInstance();
  const [seed, setSeed] = useState<string | undefined>(idFromUrl);
  const [selectedId, setSelectedId] = useState<string | null>(idFromUrl ?? null);
  const [hops, setHops] = useState(2);
  const [q, setQ] = useState("");
  const candidates = useNodeSearch(q, null, 8);
  const graph = useNeighborhood(seed, hops);

  useEffect(() => {
    if (!seed && current) {
      // bootstrap with a sensible seed: first popular node label
      fetch(`/api/nodes?instance=${current}&limit=1&q=AS22759`)
        .then((r) => r.json() as Promise<{ rows: { id: string }[] }>)
        .then((d) => {
          if (d.rows?.[0]?.id) {
            setSeed(d.rows[0].id);
            setSelectedId(d.rows[0].id);
          }
        });
    }
  }, [current, seed]);

  useEffect(() => {
    if (idFromUrl) {
      setSeed(idFromUrl);
      setSelectedId(idFromUrl);
    }
  }, [idFromUrl]);

  const selectedNode =
    graph.data?.nodes.find((node) => node.id === selectedId) ??
    graph.data?.nodes.find((node) => node.id === seed) ??
    null;

  return (
    <div className="flex flex-col gap-4">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold tracking-tight">Graph explorer</h1>
          <p className="text-sm text-[color:var(--color-ink-muted)]">
            Pick any record; walk outward up to three hops and inspect neighbors in place.
          </p>
        </div>
        <div className="flex items-center gap-3">
          {[1, 2, 3].map((h) => (
            <button
              key={h}
              onClick={() => setHops(h)}
              className={
                "rounded px-3 py-1 text-xs " +
                (hops === h
                  ? "bg-[color:var(--color-rye)] text-black"
                  : "border border-[color:var(--color-line)] text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)]")
              }
            >
              {h} hop{h > 1 ? "s" : ""}
            </button>
          ))}
        </div>
      </header>

      <div className="grid grid-cols-[280px_1fr] gap-4">
        <div className="card">
          <div className="mb-2 flex items-center gap-2 text-sm">
            <Search size={14} /> Anchor
          </div>
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Pick a starting record"
            className="input mb-3"
          />
          <ul className="flex flex-col gap-1">
            {(candidates.data?.rows ?? []).map((r) => (
              <li key={r.id}>
                <button
                  onClick={() => {
                    setSeed(r.id);
                    setSelectedId(r.id);
                    navigate(`/graph/${r.id}`);
                  }}
                  className={
                    "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs " +
                    (seed === r.id
                      ? "bg-[color:var(--color-surface-2)] text-white"
                      : "text-[color:var(--color-ink-muted)] hover:bg-[color:var(--color-surface-2)] hover:text-white")
                  }
                >
                  <span
                    className="size-2 rounded-full"
                    style={{ background: colorForType(r.node_type) }}
                  />
                  <span className="truncate">{r.label}</span>
                </button>
              </li>
            ))}
          </ul>
          {seed ? (
            <div className="mt-4 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
              Anchored on{" "}
              <span className="font-mono normal-case text-[color:var(--color-ink-muted)]">
                {shortId(seed)}
              </span>
            </div>
          ) : null}
        </div>

        <div className="card p-3">
          <div className="mb-2 flex items-center justify-between px-2">
            <span className="flex items-center gap-2 text-sm">
              <Network size={14} /> Subgraph
            </span>
            <span className="text-xs text-[color:var(--color-ink-muted)]">
              {graph.data?.nodes.length ?? 0} nodes ·{" "}
              {graph.data?.edges.length ?? 0} edges
            </span>
          </div>
          {selectedNode ? (
            <div className="mb-2 flex flex-col gap-2 rounded-lg border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2 sm:flex-row sm:items-center sm:justify-between">
              <div className="min-w-0">
                <div className="truncate text-sm font-medium text-[color:var(--color-ink)]">
                  {selectedNode.label}
                </div>
                <div className="mt-1 flex flex-wrap gap-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                  <span>{selectedNode.node_type}</span>
                  {selectedNode.id === seed ? <span>graph focus</span> : null}
                </div>
              </div>
              <div className="flex shrink-0 flex-wrap gap-2">
                {selectedNode.id !== seed ? (
                  <button
                    type="button"
                    onClick={() => {
                      setSeed(selectedNode.id);
                      setSelectedId(selectedNode.id);
                      navigate(`/graph/${selectedNode.id}`);
                    }}
                    className="btn h-8 text-xs"
                  >
                    <GitBranch size={13} /> Focus here
                  </button>
                ) : null}
                <button
                  type="button"
                  onClick={() => navigate(`/nodes/${selectedNode.id}`)}
                  className="btn h-8 text-xs"
                >
                  <ExternalLink size={13} /> Open record
                </button>
              </div>
            </div>
          ) : null}
          <GraphCanvas
            data={graph.data}
            focusId={seed}
            selectedId={selectedNode?.id ?? selectedId}
            onSelect={setSelectedId}
            height={620}
          />
        </div>
      </div>
    </div>
  );
}
