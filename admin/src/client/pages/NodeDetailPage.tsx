import { type FormEvent, type ReactNode, useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, ArrowLeft, Calendar, Check, CheckCircle, Clock, Copy, Database, ExternalLink, FileText, GitBranch, History, Info, Link2, Plus, RefreshCcw, ScrollText, Tags, ThumbsDown, ThumbsUp, Users, X } from "lucide-react";
import { createKnowledgeCandidate, promoteKnowledgeCandidate, setKnowledgeCandidateStatus, useNeighborhood, useNodeDetail, useNodeKnowledge } from "../lib/api";
import type { AcceptedKnowledgeRow, ArtifactRow, AssertionRow, CreateKnowledgeCandidateInput, EdgeNeighbor, EventRow, GraphPayload, KnowledgeCandidateKind, KnowledgeCandidateRow, KnowledgeCandidateStatus, NodeDetail, NodeKnowledge, NodeProvenanceSummary, NodeRow, PromoteKnowledgeCandidateInput, ReviewContextScope, SourceSummary } from "../lib/api";
import { GraphCanvas } from "../components/GraphCanvas";
import { colorForType, fmtDate, fmtRel, shortId } from "../lib/format";
import { useInstance } from "../lib/instance";

type DetailTab = "overview" | "graph" | "assertions" | "connections" | "activity";

const DETAIL_TABS: Array<{ id: DetailTab; label: string }> = [
  { id: "overview", label: "Overview" },
  { id: "graph", label: "Graph" },
  { id: "assertions", label: "Assertions" },
  { id: "connections", label: "Connections" },
  { id: "activity", label: "Activity" },
];

export function NodeDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { current } = useInstance();
  const queryClient = useQueryClient();
  const detail = useNodeDetail(id);
  const [hops, setHops] = useState(1);
  const [graphFocusId, setGraphFocusId] = useState<string | undefined>(id);
  const [selectedGraphNodeId, setSelectedGraphNodeId] = useState<string | null>(id ?? null);
  const [activeTab, setActiveTab] = useState<DetailTab>(() => parseDetailTab());
  const [copiedRecordId, setCopiedRecordId] = useState(false);
  const [knowledgeAsOf, setKnowledgeAsOf] = useState("");
  const [includeStale, setIncludeStale] = useState(false);
  const [includeSuperseded, setIncludeSuperseded] = useState(false);
  const [includeRejected, setIncludeRejected] = useState(false);
  const [includeRawEvidence, setIncludeRawEvidence] = useState(false);
  const [showTypeLegend, setShowTypeLegend] = useState(() =>
    typeof window !== "undefined" && new URLSearchParams(window.location.search).has("legend")
  );
  useEffect(() => {
    setGraphFocusId(id);
    setSelectedGraphNodeId(id ?? null);
    setHops(1);
  }, [id]);

  const graph = useNeighborhood(graphFocusId ?? id, hops);
  const knowledgeOptions = useMemo(
    () => ({
      asOf: knowledgeAsOf || null,
      includeStale,
      includeSuperseded,
      includeRejected,
      includeRawEvidence,
    }),
    [includeRawEvidence, includeRejected, includeStale, includeSuperseded, knowledgeAsOf]
  );
  const knowledge = useNodeKnowledge(id, knowledgeOptions);
  const refreshKnowledge = () => {
    void queryClient.invalidateQueries({ queryKey: ["node-knowledge", current, id] });
    void queryClient.invalidateQueries({ queryKey: ["node-detail", current, id] });
    void queryClient.invalidateQueries({ queryKey: ["dashboard", current] });
  };
  const createCandidate = useMutation({
    mutationFn: (input: CreateKnowledgeCandidateInput) =>
      createKnowledgeCandidate(current, input),
    onSuccess: refreshKnowledge,
  });
  const setCandidateStatus = useMutation({
    mutationFn: (input: { id: string; status: KnowledgeCandidateStatus; reason?: string }) =>
      setKnowledgeCandidateStatus(current, input.id, {
        status: input.status,
        reason: input.reason ?? null,
        actor: "admin-ui",
      }),
    onSuccess: refreshKnowledge,
  });
  const promoteCandidate = useMutation({
    mutationFn: (input: { id: string; payload: PromoteKnowledgeCandidateInput }) =>
      promoteKnowledgeCandidate(current, input.id, input.payload),
    onSuccess: refreshKnowledge,
  });

  if (detail.isLoading) return <div className="card animate-pulse">Loading…</div>;
  if (detail.error || !detail.data?.node) {
    return (
      <div className="card text-rose-300">
        Could not load node: {String(detail.error)}
      </div>
    );
  }

  const n = detail.data.node;
  const props = (n.properties ?? {}) as Record<string, unknown>;
  const isSourceHub = n.node_type === "source_account" || n.node_type === "source_container";
  const isReviewContext = n.node_type === "review_context";
  const usesKnowledgeTabs = usesKnowledgeWorkflowTabs(n);
  const knowledgeData = knowledge.data ?? null;
  const edgesOut = detail.data.edges_out;
  const edgesIn = detail.data.edges_in;
  const connectionCount = edgesOut.length + edgesIn.length;
  const tabLabels = detailTabsForNode(n);
  const edgeSummary = summarizeEdgeCategories([...edgesOut, ...edgesIn]);
  const graphSummary = summarizeGraphEdges(graph.data?.edges ?? []);
  const selectedGraphId =
    graph.data?.nodes.some((node) => node.id === selectedGraphNodeId)
      ? selectedGraphNodeId
      : graphFocusId ?? n.id;
  const tabCounts: Partial<Record<DetailTab, number>> = usesKnowledgeTabs
    ? {
        overview:
          (knowledgeData?.evidence.source_items_count ?? 0) +
          (knowledgeData?.evidence.artifacts_count ?? 0),
        graph: knowledgeData?.candidates.length,
        assertions: knowledgeData?.accepted_knowledge.length,
        connections: knowledgeData?.actions.length,
        activity: knowledgeData?.history.events_count,
      }
    : {
        overview: detail.data.source_summary?.item_count,
        graph: graph.data?.edges.length,
        assertions: detail.data.assertions.length,
        connections: connectionCount,
        activity: detail.data.events.length,
      };
  const selectTab = (tab: DetailTab) => {
    setActiveTab(tab);
    if (typeof window === "undefined") return;
    const next = new URL(window.location.href);
    if (tab === "overview") {
      next.searchParams.delete("tab");
    } else {
      next.searchParams.set("tab", tab);
    }
    window.history.replaceState(null, "", `${next.pathname}${next.search}${next.hash}`);
  };
  const copyRecordId = async () => {
    let copied = false;
    try {
      if (typeof navigator !== "undefined" && navigator.clipboard) {
        await navigator.clipboard.writeText(n.id);
        copied = true;
      }
    } catch {
      copied = false;
    }
    if (!copied && typeof document !== "undefined") {
      const el = document.createElement("textarea");
      el.value = n.id;
      el.setAttribute("readonly", "true");
      el.style.position = "fixed";
      el.style.left = "-9999px";
      document.body.appendChild(el);
      el.select();
      copied = document.execCommand("copy");
      document.body.removeChild(el);
    }
    if (copied) {
      setCopiedRecordId(true);
      window.setTimeout(() => setCopiedRecordId(false), 1200);
    } else {
      setCopiedRecordId(false);
    }
  };

  return (
    <div className="flex flex-col gap-6">
      <header className="card-flat flex items-start justify-between gap-6">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-3">
            <button
              onClick={() => navigate(-1)}
              className="btn h-8 text-xs"
            >
              <ArrowLeft size={12} /> Back
            </button>
            <div className="flex items-center gap-2 text-[10px] uppercase tracking-[0.18em] text-[color:var(--color-ink-dim)]">
              <span
                className="size-2 rounded-full"
                style={{ background: colorForType(n.node_type) }}
              />
              {n.node_type}
              {n.external_source ? (
                <>
                  <span>·</span> <span>{n.external_source}</span>
                </>
              ) : null}
              <button
                type="button"
                onClick={() => setShowTypeLegend(true)}
                className="ml-1 inline-flex size-5 items-center justify-center rounded-full border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] text-[color:var(--color-ink-muted)] transition hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-ink)]"
                aria-label="Explain Rye labels"
                title="Explain Rye labels"
              >
                <Info size={12} />
              </button>
            </div>
          </div>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight">{displayNodeTitle(n)}</h1>
          <div className="mt-2 text-xs text-[color:var(--color-ink-muted)]">
            Created {fmtDate(n.created_at)}
            {n.archived_at ? ` · Archived ${fmtDate(n.archived_at)}` : ""}
          </div>
          {isReviewContext ? (
            <ReviewContextScopeSummary scope={detail.data.context_scope ?? null} />
          ) : null}
        </div>
        <div className="flex flex-col items-end gap-2 text-right text-xs text-[color:var(--color-ink-muted)]">
          <button
            type="button"
            onClick={copyRecordId}
            title={`Rye record ID: ${n.id}\nClick to copy`}
            aria-label={`Copy Rye record ID ${n.id}`}
            className="inline-flex max-w-[220px] items-center gap-2 rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] px-2.5 py-1.5 text-left transition hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-ink)]"
          >
            {copiedRecordId ? <Check size={12} /> : <Copy size={12} />}
            <span className="min-w-0">
              <span className="block font-sans text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                Record ID
              </span>
              <span className="block truncate font-mono text-xs text-[color:var(--color-ink-muted)]">
                {copiedRecordId ? "Copied" : shortId(n.id)}
              </span>
            </span>
          </button>
          <div>{detail.data.assertions.length} claims/rules</div>
          <div>{detail.data.events.length} activity events</div>
          <div title="Edges are grouped below as provenance, proposed routes, or accepted knowledge.">
            {connectionCount} stored edges
          </div>
        </div>
      </header>

      {(isSourceHub || n.node_type === "source_item") ? (
        <SourceAttentionBanner
          node={n}
          summary={detail.data.source_summary ?? null}
          edgeSummary={edgeSummary}
        />
      ) : null}

      {showTypeLegend ? (
        <TypeLegendOverlay node={n} onClose={() => setShowTypeLegend(false)} />
      ) : null}

      <NodeDetailTabs
        active={activeTab}
        counts={tabCounts}
        labels={tabLabels}
        onChange={selectTab}
      />

      {usesKnowledgeTabs ? (
        <KnowledgeActivenessControls
          asOf={knowledgeAsOf}
          includeStale={includeStale}
          includeSuperseded={includeSuperseded}
          includeRejected={includeRejected}
          includeRawEvidence={includeRawEvidence}
          onAsOfChange={setKnowledgeAsOf}
          onIncludeStaleChange={setIncludeStale}
          onIncludeSupersededChange={setIncludeSuperseded}
          onIncludeRejectedChange={setIncludeRejected}
          onIncludeRawEvidenceChange={setIncludeRawEvidence}
        />
      ) : null}

      {activeTab === "overview" ? (
        usesKnowledgeTabs ? (
          <section className="grid grid-cols-1 gap-4 lg:grid-cols-3">
            <div className="min-w-0 space-y-4 lg:col-span-2">
              <KnowledgeEvidencePanel knowledge={knowledgeData} loading={knowledge.isLoading} />
              <WhatWasLearnedPanel knowledge={knowledgeData} loading={knowledge.isLoading} />
              {detail.data.source_summary ? <SourceSummaryCard summary={detail.data.source_summary} /> : null}
            </div>

            <div className="card max-h-[calc(100vh-260px)] min-h-[320px] min-w-0 overflow-y-auto scrollbar">
              <NodeOverviewDetails
                node={n}
                props={props}
                detail={detail.data}
                isReviewContext={isReviewContext}
                isSourceHub={isSourceHub}
              />
            </div>
          </section>
        ) : (
          <section className="grid grid-cols-1 gap-4 lg:grid-cols-3">
            {detail.data.source_summary ? (
              <div className="min-w-0 lg:col-span-2">
                <SourceSummaryCard summary={detail.data.source_summary} />
              </div>
            ) : null}

            <div
              className={
                (detail.data.source_summary ? "lg:col-span-1" : "lg:col-span-3") +
                " card max-h-[calc(100vh-260px)] min-h-[320px] min-w-0 overflow-y-auto scrollbar"
              }
            >
              <NodeOverviewDetails
                node={n}
                props={props}
                detail={detail.data}
                isReviewContext={isReviewContext}
                isSourceHub={isSourceHub}
              />
            </div>
          </section>
        )
      ) : null}

      {activeTab === "graph" ? (
        usesKnowledgeTabs ? (
          <CandidateKnowledgePanel
            node={n}
            knowledge={knowledgeData}
            loading={knowledge.isLoading}
            error={knowledge.error}
            creating={createCandidate.isPending}
            reviewing={setCandidateStatus.isPending || promoteCandidate.isPending}
            mutationError={createCandidate.error ?? setCandidateStatus.error ?? promoteCandidate.error}
            onCreate={(input) => createCandidate.mutate(input)}
            onSetStatus={(candidateId, status, reason) =>
              setCandidateStatus.mutate({ id: candidateId, status, reason })
            }
            onPromote={(candidateId, payload) =>
              promoteCandidate.mutate({ id: candidateId, payload })
            }
          />
        ) : (
          <section className="card min-w-0">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <div className="flex items-center gap-2 text-sm">
                <GitBranch size={14} /> {tabLabels.graph}
              </div>
              <p className="mt-1 text-xs leading-5 text-[color:var(--color-ink-muted)]">
                {graphIntroForNode(n)}
              </p>
            </div>
            <div className="flex gap-1">
              {[1, 2, 3].map((h) => (
                <button
                  key={h}
                  onClick={() => setHops(h)}
                  className={
                    "rounded px-2 py-1 text-xs " +
                    (hops === h
                      ? "bg-[color:var(--color-rye)] text-black"
                      : "border border-[color:var(--color-line)] text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)]")
                  }
                >
                  {h} hop{h > 1 ? "s" : ""}
                </button>
              ))}
            </div>
          </div>
          {(graph.data?.edges.length ?? 0) === 0 ? (
            <UnconnectedGraphExplanation
              node={n}
              provenance={detail.data.provenance_summary ?? null}
            />
          ) : null}
          <div className="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(0,1fr)_260px] 2xl:grid-cols-[minmax(0,1fr)_300px]">
            <GraphCanvas
              data={graph.data}
              focusId={graphFocusId ?? n.id}
              selectedId={selectedGraphId}
              onSelect={setSelectedGraphNodeId}
              height={560}
            />
            <GraphInspectorPanel
              graph={graph.data}
              pageNodeId={n.id}
              focusId={graphFocusId ?? n.id}
              selectedId={selectedGraphId}
              onSelect={setSelectedGraphNodeId}
              onOpen={(targetId) => navigate(`/nodes/${targetId}`)}
              onSetFocus={(targetId) => {
                setGraphFocusId(targetId);
                setSelectedGraphNodeId(targetId);
              }}
            />
          </div>
          <div className="mt-3 flex flex-col gap-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)] sm:flex-row sm:items-center sm:justify-between">
            <span>
              {graph.data?.nodes.length ?? 0} nodes ·{" "}
              {graph.data?.edges.length ?? 0} edges
            </span>
            <EdgeCategoryChips summary={graphSummary} />
            <span>inspector selection stays on this page</span>
          </div>
          </section>
        )
      ) : null}

      {activeTab === "assertions" ? (
        usesKnowledgeTabs ? (
          <AcceptedKnowledgePanel items={knowledgeData?.accepted_knowledge ?? []} loading={knowledge.isLoading} />
        ) : (
          <AssertionList items={detail.data.assertions} />
        )
      ) : null}

      {activeTab === "connections" ? (
        usesKnowledgeTabs ? (
          <KnowledgeActionsPanel items={knowledgeData?.actions ?? []} loading={knowledge.isLoading} />
        ) : (
          <ConnectionGroups edgesOut={edgesOut} edgesIn={edgesIn} />
        )
      ) : null}

      {activeTab === "activity" ? (
        usesKnowledgeTabs ? (
          <KnowledgeHistoryPanel knowledge={knowledgeData} loading={knowledge.isLoading} />
        ) : (
          <EventList items={detail.data.events} />
        )
      ) : null}
    </div>
  );
}

function GraphInspectorPanel({
  graph,
  pageNodeId,
  focusId,
  selectedId,
  onSelect,
  onOpen,
  onSetFocus,
}: {
  graph: GraphPayload | undefined;
  pageNodeId: string;
  focusId: string;
  selectedId?: string | null;
  onSelect: (id: string) => void;
  onOpen: (id: string) => void;
  onSetFocus: (id: string) => void;
}) {
  const rows = useMemo(() => {
    if (!graph) return [];
    const degree = new Map<string, { count: number; summary: EdgeCategorySummary }>();
    for (const node of graph.nodes) {
      degree.set(node.id, {
        count: 0,
        summary: { provenance: 0, classification: 0, knowledge: 0 },
      });
    }
    for (const edge of graph.edges) {
      const category = edgeCategory(edge);
      for (const nodeId of [edge.source, edge.target]) {
        const entry =
          degree.get(nodeId) ??
          { count: 0, summary: { provenance: 0, classification: 0, knowledge: 0 } };
        entry.count += 1;
        entry.summary[category] += 1;
        degree.set(nodeId, entry);
      }
    }
    return graph.nodes
      .map((node) => ({
        node,
        degree: degree.get(node.id) ?? {
          count: 0,
          summary: { provenance: 0, classification: 0, knowledge: 0 },
        },
      }))
      .sort((a, b) => {
        if (a.node.id === selectedId) return -1;
        if (b.node.id === selectedId) return 1;
        if (a.node.id === focusId) return -1;
        if (b.node.id === focusId) return 1;
        return b.degree.count - a.degree.count || a.node.label.localeCompare(b.node.label);
      });
  }, [focusId, graph, selectedId]);
  const selectedRow =
    rows.find((row) => row.node.id === selectedId) ??
    rows.find((row) => row.node.id === focusId) ??
    rows[0] ??
    null;
  const selectedEdges = useMemo(() => {
    if (!graph || !selectedRow) return [];
    const labels = new Map(graph.nodes.map((node) => [node.id, node]));
    return graph.edges
      .filter((edge) => edge.source === selectedRow.node.id || edge.target === selectedRow.node.id)
      .map((edge) => {
        const otherId = edge.source === selectedRow.node.id ? edge.target : edge.source;
        return {
          edge,
          category: edgeCategory(edge),
          other: labels.get(otherId) ?? null,
        };
      });
  }, [graph, selectedRow]);

  return (
    <aside className="min-h-[260px] max-h-[560px] overflow-y-auto rounded-xl border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-3 scrollbar">
      <div className="mb-3 flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 text-sm">
          <GitBranch size={14} /> Graph inspector
        </div>
        <span className="chip">{rows.length}</span>
      </div>
      {!graph ? (
        <LoadingLine />
      ) : rows.length === 0 ? (
        <EmptyLine>No graph nodes are visible.</EmptyLine>
      ) : (
        <div className="space-y-3">
          {selectedRow ? (
            <div className="rounded-lg border border-[color:var(--color-cyan)]/50 bg-[color:var(--color-cyan)]/5 p-3">
              <div className="flex items-start gap-2">
                <span
                  className="mt-1 size-2.5 shrink-0 rounded-full"
                  style={{ background: colorForType(selectedRow.node.node_type) }}
                />
                <div className="min-w-0 flex-1">
                  <div className="break-words text-sm font-semibold leading-5 text-[color:var(--color-ink)]">
                    {selectedRow.node.label}
                  </div>
                  <div className="mt-1 flex flex-wrap gap-1 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                    <span>{selectedRow.node.node_type}</span>
                    <span>{selectedRow.degree.count} edges</span>
                    {selectedRow.node.id === pageNodeId ? <span>page record</span> : null}
                    {selectedRow.node.id === focusId ? <span>graph focus</span> : null}
                  </div>
                </div>
              </div>
              <div className="mt-3 flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => onOpen(selectedRow.node.id)}
                  className="btn h-8 text-xs"
                >
                  <ExternalLink size={13} /> Open record
                </button>
                {selectedRow.node.id !== focusId ? (
                  <button
                    type="button"
                    onClick={() => onSetFocus(selectedRow.node.id)}
                    className="btn h-8 text-xs"
                  >
                    <GitBranch size={13} /> Focus graph
                  </button>
                ) : null}
                {focusId !== pageNodeId ? (
                  <button
                    type="button"
                    onClick={() => onSetFocus(pageNodeId)}
                    className="btn h-8 text-xs"
                  >
                    <RefreshCcw size={13} /> Page graph
                  </button>
                ) : null}
              </div>
              {selectedEdges.length > 0 ? (
                <ul className="mt-3 space-y-1">
                  {selectedEdges.slice(0, 6).map(({ edge, other, category }) => (
                    <li
                      key={edge.id}
                      className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-2 py-1.5"
                    >
                      <div className="flex min-w-0 items-center justify-between gap-2">
                        <span className="truncate text-xs text-[color:var(--color-ink)]">
                          {other?.label ?? shortId(edge.source === selectedRow.node.id ? edge.target : edge.source)}
                        </span>
                        <span className="pill shrink-0">{edgeCategoryLabel(category)}</span>
                      </div>
                      <div className="mt-1 truncate text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                        {humanizeKey(edge.edge_type)}
                      </div>
                    </li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}
          <div className="border-t border-[color:var(--color-line-soft)] pt-3">
            <div className="mb-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
              Nodes in view
            </div>
            <ul className="space-y-1">
              {rows.map(({ node, degree }) => (
                <li key={node.id}>
                  <button
                    type="button"
                    onClick={() => onSelect(node.id)}
                    className={
                      "group flex w-full items-start gap-2 rounded-md border px-2 py-2 text-left transition " +
                      (node.id === selectedRow?.node.id
                        ? "border-[color:var(--color-cyan)] bg-[color:var(--color-cyan)]/10 text-[color:var(--color-ink)]"
                        : node.id === focusId
                          ? "border-[color:var(--color-rye)]/50 bg-[color:var(--color-rye)]/5 text-[color:var(--color-ink)]"
                          : "border-transparent text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-line)] hover:bg-[color:var(--color-surface-2)] hover:text-[color:var(--color-ink)]")
                    }
                  >
                    <span
                      className="mt-1 size-2.5 shrink-0 rounded-full"
                      style={{ background: colorForType(node.node_type) }}
                    />
                    <span className="min-w-0 flex-1">
                      <span className="block break-words text-xs font-medium leading-4">
                        {node.label}
                      </span>
                      <span className="mt-1 flex flex-wrap gap-1 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                        <span>{node.node_type}</span>
                        <span>{degree.count} edges</span>
                      </span>
                      <span className="mt-1 flex flex-wrap gap-1">
                        {degree.summary.knowledge > 0 ? (
                          <span className="pill">{degree.summary.knowledge} accepted</span>
                        ) : null}
                        {degree.summary.provenance > 0 ? (
                          <span className="pill">{degree.summary.provenance} provenance</span>
                        ) : null}
                        {degree.summary.classification > 0 ? (
                          <span className="pill">{degree.summary.classification} proposed</span>
                        ) : null}
                      </span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          </div>
        </div>
      )}
    </aside>
  );
}

function NodeOverviewDetails({
  node,
  props,
  detail,
  isReviewContext,
  isSourceHub,
}: {
  node: NodeRow;
  props: JsonObject;
  detail: NodeDetail;
  isReviewContext: boolean;
  isSourceHub: boolean;
}) {
  if (node.node_type === "source_item") {
    return (
      <SourceItemDetails
        node={node}
        props={props}
        artifacts={detail.artifacts ?? []}
        assertions={detail.assertions}
        edgesOut={detail.edges_out}
      />
    );
  }
  if (isReviewContext) {
    return (
      <ReviewContextDetails
        node={node}
        props={props}
        assertions={detail.assertions}
        edgesIn={detail.edges_in}
        contextScope={detail.context_scope ?? null}
      />
    );
  }
  if (isSourceHub) {
    return (
      <SourceHubDetails
        node={node}
        props={props}
        assertions={detail.assertions}
        summary={detail.source_summary ?? null}
      />
    );
  }
  return (
    <>
      <div className="mb-2 flex items-center gap-2 text-sm">
        <ScrollText size={14} /> Properties
      </div>
      <PropertyList props={props} />
    </>
  );
}

function KnowledgeActivenessControls({
  asOf,
  includeStale,
  includeSuperseded,
  includeRejected,
  includeRawEvidence,
  onAsOfChange,
  onIncludeStaleChange,
  onIncludeSupersededChange,
  onIncludeRejectedChange,
  onIncludeRawEvidenceChange,
}: {
  asOf: string;
  includeStale: boolean;
  includeSuperseded: boolean;
  includeRejected: boolean;
  includeRawEvidence: boolean;
  onAsOfChange: (value: string) => void;
  onIncludeStaleChange: (value: boolean) => void;
  onIncludeSupersededChange: (value: boolean) => void;
  onIncludeRejectedChange: (value: boolean) => void;
  onIncludeRawEvidenceChange: (value: boolean) => void;
}) {
  return (
    <section className="card-flat flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" className="btn h-9 text-xs" onClick={() => onAsOfChange("")}>
          <RefreshCcw size={13} /> Current
        </button>
        <label className="flex items-center gap-2 text-xs text-[color:var(--color-ink-muted)]">
          <Clock size={13} />
          <input
            type="datetime-local"
            value={asOf}
            onChange={(event) => onAsOfChange(event.target.value)}
            className="input h-9 min-w-[210px]"
          />
        </label>
      </div>
      <div className="flex flex-wrap gap-3 text-xs text-[color:var(--color-ink-muted)]">
        <CheckboxControl label="Include stale" checked={includeStale} onChange={onIncludeStaleChange} />
        <CheckboxControl label="Include superseded" checked={includeSuperseded} onChange={onIncludeSupersededChange} />
        <CheckboxControl label="Include rejected" checked={includeRejected} onChange={onIncludeRejectedChange} />
        <CheckboxControl label="Raw evidence" checked={includeRawEvidence} onChange={onIncludeRawEvidenceChange} />
      </div>
    </section>
  );
}

function CheckboxControl({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="inline-flex items-center gap-2">
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        className="size-4 rounded border-[color:var(--color-line)] bg-[color:var(--color-surface-2)]"
      />
      {label}
    </label>
  );
}

function KnowledgeEvidencePanel({
  knowledge,
  loading,
}: {
  knowledge: NodeKnowledge | null;
  loading: boolean;
}) {
  if (loading && !knowledge) return <LoadingCard label="Loading evidence" />;
  const evidence = knowledge?.evidence;
  return (
    <section className="card">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2 text-sm">
          <Database size={14} /> Evidence
        </div>
        <div className="flex flex-wrap gap-2">
          <span className="chip">{evidence?.source_items_count ?? 0} source items</span>
          <span className="chip">{evidence?.artifacts_count ?? 0} artifacts</span>
          <span className="chip">{evidence?.source_events_count ?? 0} events</span>
        </div>
      </div>
      {(evidence?.recent_evidence.length ?? 0) === 0 ? (
        <EmptyLine>No evidence has been associated with this record yet.</EmptyLine>
      ) : (
        <ul className="grid grid-cols-1 gap-2 md:grid-cols-2">
          {evidence?.recent_evidence.slice(0, 8).map((item) => (
            <li key={`${item.kind}:${item.id}`} className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2 text-sm">
              <div className="flex min-w-0 items-center justify-between gap-2">
                <span className="chip shrink-0">{humanizeKey(item.kind)}</span>
                <span className="truncate text-xs text-[color:var(--color-ink-muted)]">
                  {item.occurred_at ? fmtDate(item.occurred_at) : shortId(item.id)}
                </span>
              </div>
              <div className="mt-2 truncate text-[color:var(--color-ink)]" title={item.title ?? item.id}>
                {item.title ?? shortId(item.id)}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function WhatWasLearnedPanel({
  knowledge,
  loading,
}: {
  knowledge: NodeKnowledge | null;
  loading: boolean;
}) {
  if (loading && !knowledge) return <LoadingCard label="Loading learned content" />;
  const learned = knowledge?.what_was_learned;
  return (
    <section className="card">
      <div className="mb-3 flex items-center gap-2 text-sm">
        <CheckCircle size={14} /> What Was Learned
      </div>
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-5">
        <KnowledgePreview label="Topics" items={learned?.topics ?? []} />
        <KnowledgePreview label="Entities" items={learned?.entities ?? []} />
        <KnowledgePreview label="Actions" items={learned?.actions ?? []} />
        <KnowledgePreview label="Decisions" items={learned?.decisions ?? []} />
        <KnowledgePreview label="Open questions" items={learned?.open_questions ?? []} />
      </div>
    </section>
  );
}

function KnowledgePreview({ label, items }: { label: string; items: string[] }) {
  return (
    <div className="min-w-0 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
      <div className="field-label">{label}</div>
      {items.length === 0 ? (
        <div className="mt-2 text-xs text-[color:var(--color-ink-dim)]">None</div>
      ) : (
        <ul className="mt-2 space-y-1 text-sm text-[color:var(--color-ink)]">
          {items.slice(0, 5).map((item) => (
            <li key={item} className="truncate" title={item}>
              {humanizeKey(item)}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

const CANDIDATE_KINDS: KnowledgeCandidateKind[] = [
  "fact",
  "task",
  "edge",
  "decision",
  "procedure",
  "preference",
  "risk",
];

function CandidateKnowledgePanel({
  node,
  knowledge,
  loading,
  error,
  creating,
  reviewing,
  mutationError,
  onCreate,
  onSetStatus,
  onPromote,
}: {
  node: NodeRow;
  knowledge: NodeKnowledge | null;
  loading: boolean;
  error: unknown;
  creating: boolean;
  reviewing: boolean;
  mutationError: unknown;
  onCreate: (input: CreateKnowledgeCandidateInput) => void;
  onSetStatus: (candidateId: string, status: KnowledgeCandidateStatus, reason: string) => void;
  onPromote: (candidateId: string, payload: PromoteKnowledgeCandidateInput) => void;
}) {
  const [kind, setKind] = useState<KnowledgeCandidateKind>("fact");
  const [statement, setStatement] = useState("");
  const [confidence, setConfidence] = useState("");
  const candidates = knowledge?.candidates ?? [];
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const trimmed = statement.trim();
    if (!trimmed) return;
    onCreate({
      candidate_kind: kind,
      statement: trimmed,
      source_node_ids: [node.id],
      target_payload: { subject_node_id: node.id },
      confidence: confidence ? Number(confidence) : null,
      created_by: "admin-ui",
    });
    setStatement("");
    setConfidence("");
  };

  return (
    <section className="grid grid-cols-1 gap-4 xl:grid-cols-[360px_1fr]">
      <form onSubmit={submit} className="card flex flex-col gap-3">
        <div className="flex items-center gap-2 text-sm">
          <Plus size={14} /> Candidate Knowledge
        </div>
        <select
          value={kind}
          onChange={(event) => setKind(event.target.value as KnowledgeCandidateKind)}
          className="input h-10"
        >
          {CANDIDATE_KINDS.map((item) => (
            <option key={item} value={item}>
              {humanizeKey(item)}
            </option>
          ))}
        </select>
        <textarea
          value={statement}
          onChange={(event) => setStatement(event.target.value)}
          className="input min-h-28 resize-y py-2"
          placeholder="Collected statement, action, risk, decision, or procedure"
        />
        <input
          type="number"
          min="0"
          max="1"
          step="0.01"
          value={confidence}
          onChange={(event) => setConfidence(event.target.value)}
          className="input h-10"
          placeholder="Confidence 0-1"
        />
        <button type="submit" disabled={creating || !statement.trim()} className="btn-primary h-10 disabled:opacity-50">
          <Plus size={14} /> Create candidate
        </button>
        {mutationError ? <ErrorLine error={mutationError} /> : null}
      </form>

      <div className="card min-w-0">
        <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2 text-sm">
            <ScrollText size={14} /> Review Queue
          </div>
          <span className="chip">{candidates.length}</span>
        </div>
        {error ? <ErrorLine error={error} /> : null}
        {loading && candidates.length === 0 ? (
          <LoadingLine />
        ) : candidates.length === 0 ? (
          <EmptyLine>No candidate knowledge has been collected for this record.</EmptyLine>
        ) : (
          <ul className="flex flex-col divide-y divide-[color:var(--color-line-soft)]">
            {candidates.map((candidate) => (
              <CandidateReviewCard
                key={candidate.id}
                node={node}
                candidate={candidate}
                reviewing={reviewing}
                onSetStatus={onSetStatus}
                onPromote={onPromote}
              />
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}

function CandidateReviewCard({
  node,
  candidate,
  reviewing,
  onSetStatus,
  onPromote,
}: {
  node: NodeRow;
  candidate: KnowledgeCandidateRow;
  reviewing: boolean;
  onSetStatus: (candidateId: string, status: KnowledgeCandidateStatus, reason: string) => void;
  onPromote: (candidateId: string, payload: PromoteKnowledgeCandidateInput) => void;
}) {
  const kind = candidateKind(candidate);
  const statement = candidateStatement(candidate);
  const promotion = promotionPayloadForCandidate(node, candidate);
  const promotedTargets = candidate.promoted_targets ?? [];

  return (
    <li className="py-4">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="chip">{humanizeKey(kind)}</span>
            <CandidateStatusPill status={candidate.status} />
            {typeof candidate.properties.confidence === "number" ? (
              <span className="pill">confidence {candidate.properties.confidence}</span>
            ) : null}
          </div>
          <p className="mt-2 whitespace-pre-wrap text-sm leading-5 text-[color:var(--color-ink)]">
            {statement}
          </p>
          <div className="mt-3 flex flex-wrap gap-1 text-xs">
            {candidate.supporting_sources.slice(0, 4).map((source) => (
              <Link
                key={`${source.edge_type}:${source.id}`}
                to={`/nodes/${source.id}`}
                className="pill hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-rye)]"
              >
                {source.label ?? shortId(source.id)}
              </Link>
            ))}
            {promotedTargets.map((target) => (
              <Link
                key={target.id}
                to={`/nodes/${target.id}`}
                className="pill border-emerald-400/30 text-emerald-300 hover:text-emerald-100"
              >
                Promoted: {target.label ?? shortId(target.id)}
              </Link>
            ))}
          </div>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2">
          {promotion ? (
            <button
              type="button"
              className="btn-primary h-9 text-xs"
              disabled={reviewing}
              onClick={() => onPromote(candidate.id, promotion)}
              title={promotionTitle(promotion)}
            >
              <ThumbsUp size={13} /> Promote {promotion.target_type}
            </button>
          ) : (
            <button type="button" className="btn h-9 text-xs opacity-60" disabled>
              <ThumbsUp size={13} /> Promote edge
            </button>
          )}
          <button
            type="button"
            className="btn h-9 text-xs"
            disabled={reviewing}
            onClick={() => onSetStatus(candidate.id, "needs_review", "Marked needs review in admin UI")}
          >
            <Clock size={13} /> Needs review
          </button>
          <button
            type="button"
            className="btn h-9 text-xs"
            disabled={reviewing}
            onClick={() => onSetStatus(candidate.id, "duplicate", "Marked duplicate in admin UI")}
          >
            <Copy size={13} /> Duplicate
          </button>
          <button
            type="button"
            className="btn h-9 text-xs"
            disabled={reviewing}
            onClick={() => onSetStatus(candidate.id, "rejected", "Rejected in admin UI")}
          >
            <ThumbsDown size={13} /> Reject
          </button>
        </div>
      </div>
    </li>
  );
}

function CandidateStatusPill({ status }: { status: KnowledgeCandidateStatus }) {
  const cls =
    status === "accepted"
      ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-300"
      : status === "rejected" || status === "duplicate"
        ? "border-rose-400/30 bg-rose-400/10 text-rose-300"
        : status === "needs_review"
          ? "border-amber-400/30 bg-amber-400/10 text-amber-200"
          : "border-[color:var(--color-line)] text-[color:var(--color-ink-muted)]";
  return (
    <span className={`rounded-md border px-2 py-1 text-[10px] uppercase tracking-wider ${cls}`}>
      {humanizeKey(status)}
    </span>
  );
}

function candidateKind(candidate: KnowledgeCandidateRow): KnowledgeCandidateKind {
  const kind = candidate.properties.candidate_kind;
  return CANDIDATE_KINDS.includes(kind as KnowledgeCandidateKind)
    ? (kind as KnowledgeCandidateKind)
    : "fact";
}

function candidateStatement(candidate: KnowledgeCandidateRow): string {
  return firstString(candidate.properties.statement, candidate.label, shortId(candidate.id)) ?? shortId(candidate.id);
}

function promotionPayloadForCandidate(
  node: NodeRow,
  candidate: KnowledgeCandidateRow
): PromoteKnowledgeCandidateInput | null {
  const kind = candidateKind(candidate);
  const statement = candidateStatement(candidate);
  const target = asRecord(candidate.properties.target_payload);
  const confidence =
    typeof candidate.properties.confidence === "number" ? candidate.properties.confidence : null;

  if (kind === "task") {
    return {
      target_type: "task",
      label: statement,
      properties: {
        status: "open",
        source_node_id: node.id,
        candidate_kind: kind,
      },
      actor: "admin-ui",
    };
  }

  if (kind === "edge") {
    const sourceId = firstString(target.source_id);
    const targetId = firstString(target.target_id);
    const edgeType = firstString(target.edge_type);
    if (!sourceId || !targetId || !edgeType) return null;
    return {
      target_type: "edge",
      source_id: sourceId,
      target_id: targetId,
      edge_type: edgeType,
      properties: asRecord(target.properties),
      effective_from: firstString(target.effective_from),
      effective_to: firstString(target.effective_to),
      actor: "admin-ui",
    };
  }

  const payloadClaim = asRecord(target.claim);
  const assertionType =
    firstString(target.assertion_type) ??
    (kind === "fact"
      ? "observation"
      : kind === "decision"
        ? "decision"
        : kind === "risk"
          ? "risk"
          : kind);
  return {
    target_type: "assertion",
    subject_node_id: firstString(target.subject_node_id) ?? node.id,
    assertion_type: assertionType,
    assertion_key:
      firstString(target.assertion_key, candidate.properties.normalized_key) ??
      `candidate_${shortId(candidate.id)}`,
    claim:
      Object.keys(payloadClaim).length > 0
        ? payloadClaim
        : {
            text: statement,
            candidate_kind: kind,
            target_payload: target,
          },
    effective_at: firstString(target.effective_at),
    effective_to: firstString(target.effective_to),
    confidence,
    actor: "admin-ui",
  };
}

function promotionTitle(payload: PromoteKnowledgeCandidateInput): string {
  if (payload.target_type === "assertion") {
    return `${payload.assertion_type}:${payload.assertion_key ?? "default"}`;
  }
  if (payload.target_type === "task") return payload.label;
  return `${payload.edge_type} ${shortId(payload.source_id)} -> ${shortId(payload.target_id)}`;
}

function AcceptedKnowledgePanel({
  items,
  loading,
}: {
  items: AcceptedKnowledgeRow[];
  loading: boolean;
}) {
  if (loading && items.length === 0) return <LoadingCard label="Loading accepted knowledge" />;
  return (
    <section className="card">
      <div className="mb-3 flex items-center gap-2 text-sm">
        <CheckCircle size={14} /> Accepted Knowledge
        <span className="chip">{items.length}</span>
      </div>
      {items.length === 0 ? (
        <EmptyLine>No accepted knowledge is visible under the current activeness filters.</EmptyLine>
      ) : (
        <ul className="flex flex-col divide-y divide-[color:var(--color-line-soft)]">
          {items.map((item) => (
            <li key={item.id} className="py-4">
              <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-sm font-medium text-[color:var(--color-ink)]">
                      {humanizeKey(item.assertion_type)}
                    </span>
                    <span className="pill">{item.assertion_key}</span>
                    {item.superseded_at ? <span className="pill">superseded</span> : null}
                  </div>
                  <TemporalLine item={item} />
                </div>
                {typeof item.confidence === "number" ? <span className="chip">{item.confidence}</span> : null}
              </div>
              <ClaimBlock claim={item.claim} />
              <ProvenanceTrail item={item} />
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function TemporalLine({ item }: { item: AssertionRow }) {
  const parts = [
    item.effective_at ? `effective ${fmtDate(item.effective_at)}` : "effective immediately",
    item.effective_to ? `until ${fmtDate(item.effective_to)}` : "no end date",
    item.superseded_at ? `superseded ${fmtDate(item.superseded_at)}` : null,
  ].filter(Boolean);
  return <div className="mt-1 text-xs text-[color:var(--color-ink-muted)]">{parts.join(" · ")}</div>;
}

function ClaimBlock({ claim }: { claim: unknown }) {
  return isSimpleTextClaim(claim) ? (
    <p className="mt-3 rounded-md bg-[color:var(--color-surface-2)] p-3 text-sm leading-5 text-[color:var(--color-ink)]">
      {claimText(claim)}
    </p>
  ) : (
    <pre className="mt-3 overflow-x-auto rounded-md bg-[color:var(--color-surface-2)] p-3 font-mono text-[11px]">
      {JSON.stringify(claim, null, 2)}
    </pre>
  );
}

function ProvenanceTrail({ item }: { item: AcceptedKnowledgeRow }) {
  const sourceRefs = Array.isArray(item.attrs?.source_refs) ? item.attrs.source_refs : [];
  if (!item.candidate_id && !item.source_event_id && sourceRefs.length === 0) return null;
  return (
    <div className="mt-3 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2 text-xs text-[color:var(--color-ink-muted)]">
      <div className="field-label">Provenance trail</div>
      <div className="mt-2 flex flex-wrap gap-2">
        {item.candidate_id ? (
          <Link to={`/nodes/${item.candidate_id}`} className="pill hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-rye)]">
            candidate {item.candidate_label ?? shortId(item.candidate_id)}
          </Link>
        ) : null}
        {item.source_event_id ? (
          <span className="pill">
            event {item.source_event_type ? humanizeKey(item.source_event_type) : shortId(item.source_event_id)}
          </span>
        ) : null}
        {sourceRefs.slice(0, 5).map((ref, index) => {
          const record = asRecord(ref);
          const nodeId = firstString(record.node_id);
          return nodeId ? (
            <Link key={`${nodeId}:${index}`} to={`/nodes/${nodeId}`} className="pill hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-rye)]">
              source {shortId(nodeId)}
            </Link>
          ) : null;
        })}
      </div>
    </div>
  );
}

function KnowledgeActionsPanel({
  items,
  loading,
}: {
  items: NodeKnowledge["actions"];
  loading: boolean;
}) {
  if (loading && items.length === 0) return <LoadingCard label="Loading actions" />;
  return (
    <section className="card">
      <div className="mb-3 flex items-center gap-2 text-sm">
        <Check size={14} /> Actions
        <span className="chip">{items.length}</span>
      </div>
      {items.length === 0 ? (
        <EmptyLine>No promoted or connected action items are visible for this node.</EmptyLine>
      ) : (
        <ul className="grid grid-cols-1 gap-3 md:grid-cols-2">
          {items.map((item) => (
            <li key={item.id} className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
              <div className="flex items-start justify-between gap-2">
                <Link to={`/nodes/${item.id}`} className="text-sm font-medium text-[color:var(--color-ink)] hover:text-[color:var(--color-rye)]">
                  {item.label ?? shortId(item.id)}
                </Link>
                <span className="chip">{humanizeKey(item.status ?? firstString(item.properties.status) ?? "open")}</span>
              </div>
              <div className="mt-2 text-xs text-[color:var(--color-ink-muted)]">
                Created {fmtDate(item.created_at)}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function KnowledgeHistoryPanel({
  knowledge,
  loading,
}: {
  knowledge: NodeKnowledge | null;
  loading: boolean;
}) {
  if (loading && !knowledge) return <LoadingCard label="Loading history" />;
  const history = knowledge?.history;
  return (
    <section className="grid grid-cols-1 gap-4">
      <div className="card">
        <div className="mb-3 flex items-center gap-2 text-sm">
          <History size={14} /> History
        </div>
        <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
          <MetricTile label="events" count={history?.events_count ?? 0} />
          <MetricTile label="assertions" count={history?.assertions_count ?? 0} />
          <MetricTile label="superseded" count={history?.superseded_assertions_count ?? 0} />
          <MetricTile label="candidates" count={history?.candidates_count ?? 0} />
        </div>
      </div>
      <EventList items={history?.recent_events ?? []} />
    </section>
  );
}

function LoadingCard({ label }: { label: string }) {
  return <div className="card animate-pulse text-sm text-[color:var(--color-ink-muted)]">{label}…</div>;
}

function LoadingLine() {
  return <div className="animate-pulse text-sm text-[color:var(--color-ink-muted)]">Loading…</div>;
}

function ErrorLine({ error }: { error: unknown }) {
  return (
    <div className="rounded-md border border-rose-400/30 bg-rose-400/10 px-3 py-2 text-sm text-rose-200">
      {String(error instanceof Error ? error.message : error)}
    </div>
  );
}

function UnconnectedGraphExplanation({
  node,
  provenance,
}: {
  node: NodeRow;
  provenance: NodeProvenanceSummary | null;
}) {
  const events = provenance?.source_events ?? [];
  const hasEvidence = provenance?.status === "derived_from_assertion_sources" && events.length > 0;

  return (
    <section className="mb-4 rounded-lg border border-amber-400/30 bg-amber-400/10 p-3">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div className="max-w-3xl">
          <div className="flex items-center gap-2 text-sm font-medium text-amber-100">
            <Info size={14} /> No accepted knowledge-graph connections yet
          </div>
          <p className="mt-1 text-sm leading-5 text-amber-100/80">
            This {humanizeKey(node.node_type).toLowerCase()} exists because Rye
            has stored claims about it, but no accepted edge in rye.edges currently
            connects it to another node. The links below are citation sources for
            those claims, not confirmed graph connections.
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2 text-xs">
          <span className="chip">0 accepted edges</span>
          <span className="chip">{provenance?.source_events_count ?? 0} source events</span>
        </div>
      </div>

      {hasEvidence ? (
        <div className="mt-3 space-y-2">
          <div className="field-label">Source evidence for the stored claims</div>
          {events.slice(0, 3).map((event) => (
            <ProvenanceEventCard key={event.id} event={event} />
          ))}
          {events.length > 3 ? (
            <div className="text-xs text-amber-100/70">
              +{events.length - 3} more source {pluralize("event", events.length - 3)}
            </div>
          ) : null}
        </div>
      ) : (
        <div className="mt-3 rounded-md border border-amber-400/20 bg-black/20 px-3 py-2 text-sm text-amber-100/80">
          No source event was recorded on this node's assertions. The record may
          have been created directly or by an intake path that did not preserve
          provenance.
        </div>
      )}
    </section>
  );
}

function ProvenanceEventCard({
  event,
}: {
  event: NodeProvenanceSummary["source_events"][number];
}) {
  const sourceKey = firstString(
    asRecord(event.properties).source_item_key,
    asRecord(event.properties).recording_id
  );
  const people = event.participants.filter((participant) => participant.node_type !== "task");

  return (
    <div className="rounded-md border border-amber-400/20 bg-black/20 px-3 py-2">
      <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-sm text-[color:var(--color-ink)]">
        <span className="chip">{humanizeKey(event.event_type)}</span>
        <span className="font-medium">{event.summary ?? sourceKey ?? shortId(event.id)}</span>
        <span className="text-xs text-[color:var(--color-ink-muted)]">{fmtDate(event.occurred_at)}</span>
        {sourceKey ? (
          <span className="pill max-w-full break-words whitespace-normal font-mono">{sourceKey}</span>
        ) : null}
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-1 text-xs">
        <span className="field-label mr-1">Citation trail, not graph edges</span>
        <ProvenanceLinks items={event.source_items} emptyLabel="No source item" />
        <ProvenanceLinks items={event.review_contexts} emptyLabel="No review context" />
        {people.slice(0, 4).map((participant) => (
            <Link
              key={`${participant.role}:${participant.id}`}
              to={`/nodes/${participant.id}`}
              className="pill max-w-full hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-rye)]"
              title={`${humanizeKey(participant.role)} · ${humanizeKey(participant.node_type)}`}
            >
              {participant.label}
            </Link>
        ))}
      </div>
    </div>
  );
}

function ProvenanceLinks({
  items,
  emptyLabel,
}: {
  items: NodeProvenanceSummary["source_events"][number]["source_items"];
  emptyLabel: string;
}) {
  if (items.length === 0) {
    return <span className="text-xs text-[color:var(--color-ink-dim)]">{emptyLabel}</span>;
  }
  return (
    <>
      {items.slice(0, 4).map((item) => (
        <Link
          key={item.id}
          to={`/nodes/${item.id}`}
          className="pill max-w-full hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-rye)]"
          title={`${humanizeKey(item.role)} · ${humanizeKey(item.node_type)}`}
        >
          {item.label}
        </Link>
      ))}
    </>
  );
}

function parseDetailTab(): DetailTab {
  if (typeof window === "undefined") return "overview";
  const tab = new URLSearchParams(window.location.search).get("tab");
  return DETAIL_TABS.some((item) => item.id === tab) ? (tab as DetailTab) : "overview";
}

function usesKnowledgeWorkflowTabs(node: NodeRow): boolean {
  return [
    "source_account",
    "source_container",
    "source_item",
    "review_context",
    "knowledge_candidate",
  ].includes(node.node_type);
}

function detailTabsForNode(node: NodeRow): Record<DetailTab, string> {
  if (usesKnowledgeWorkflowTabs(node)) {
    return {
      overview: "Evidence",
      graph: "Candidate Knowledge",
      assertions: "Accepted Knowledge",
      connections: "Actions",
      activity: "History",
    };
  }
  return Object.fromEntries(DETAIL_TABS.map((tab) => [tab.id, tab.label])) as Record<DetailTab, string>;
}

function NodeDetailTabs({
  active,
  counts,
  labels,
  onChange,
}: {
  active: DetailTab;
  counts: Partial<Record<DetailTab, number>>;
  labels: Record<DetailTab, string>;
  onChange: (tab: DetailTab) => void;
}) {
  return (
    <nav
      className="sticky top-[57px] z-20 rounded-xl border border-[color:var(--color-line)] bg-[color:var(--color-surface)]/95 p-1 shadow-lg backdrop-blur"
      aria-label="Node detail sections"
    >
      <div className="grid grid-cols-2 gap-1 md:grid-cols-5" role="tablist">
        {DETAIL_TABS.map((tab) => {
          const selected = active === tab.id;
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={selected}
              onClick={() => onChange(tab.id)}
              className={
                "flex min-h-10 items-center justify-center gap-2 rounded-lg px-3 text-sm transition " +
                (selected
                  ? "bg-[color:var(--color-rye)] text-black"
                  : "text-[color:var(--color-ink-muted)] hover:bg-[color:var(--color-surface-2)] hover:text-[color:var(--color-ink)]")
              }
            >
              <span className="truncate">{labels[tab.id]}</span>
              {typeof counts[tab.id] === "number" ? (
                <span
                  className={
                    "rounded-md px-1.5 py-0.5 font-mono text-[10px] " +
                    (selected
                      ? "bg-black/15 text-black"
                      : "bg-[color:var(--color-surface-2)] text-[color:var(--color-ink-muted)]")
                  }
                >
                  {counts[tab.id]}
                </span>
              ) : null}
            </button>
          );
        })}
      </div>
    </nav>
  );
}

function ReviewContextScopeSummary({ scope }: { scope: ReviewContextScope | null }) {
  const scopeLabel = reviewContextScopeLabel(scope);
  return (
    <div className="mt-3 max-w-3xl rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2 text-xs leading-5 text-[color:var(--color-ink-muted)]">
      <span className="font-medium text-[color:var(--color-ink)]">Applies within: </span>
      {scopeLabel}
    </div>
  );
}

function SourceAttentionBanner({
  node,
  summary,
  edgeSummary,
}: {
  node: NodeRow;
  summary: SourceSummary | null;
  edgeSummary: EdgeCategorySummary;
}) {
  const props = asRecord(node.properties);
  const classification = asRecord(props.classification);
  const confirmationStatus = firstString(
    props.confirmation_status,
    asRecord(props.context_confirmation).status,
    classification.confirmation_status
  );
  const needsConfirmation = confirmationStatus === "needs_confirmation";
  const routeCount = edgeSummary.classification;
  const sourceItems = summary?.item_count ?? 0;

  const title = needsConfirmation
    ? "Source context needs confirmation"
    : node.node_type === "source_item"
      ? "Source evidence with proposed routing"
      : "Source context recorded";
  const description = needsConfirmation
    ? "Rye collected this source but should not use its provider name or membership metadata as business truth until someone confirms the purpose and allowed contexts."
    : node.node_type === "source_item"
      ? "This record is source evidence. Routes shown here are classifier proposals unless they are later promoted into accepted facts, tasks, or knowledge connections."
      : "This source is being tracked separately from accepted knowledge so provenance stays visible and review context can be changed over time.";

  return (
    <section className="rounded-xl border border-amber-400/30 bg-amber-400/10 p-4">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div className="max-w-4xl">
          <div className="flex items-center gap-2 text-sm font-medium text-amber-100">
            <AlertTriangle size={15} /> {title}
          </div>
          <p className="mt-1 text-sm leading-5 text-amber-100/80">{description}</p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2 text-xs">
          {confirmationStatus ? <span className="chip">{humanizeKey(confirmationStatus)}</span> : null}
          {sourceItems > 0 ? <span className="chip">{sourceItems} source items</span> : null}
          {routeCount > 0 ? <span className="chip">{routeCount} proposed routes</span> : null}
        </div>
      </div>
      {needsConfirmation ? (
        <div className="mt-3 grid grid-cols-1 gap-2 text-sm leading-5 text-amber-100/80 md:grid-cols-2">
          {confirmationQuestions(node).map((question) => (
            <div key={question} className="rounded-md border border-amber-400/20 bg-black/20 px-3 py-2">
              {question}
            </div>
          ))}
        </div>
      ) : null}
    </section>
  );
}

function confirmationQuestions(node: NodeRow): string[] {
  if (node.node_type === "source_account") {
    return [
      "Which connected account, workspace, mailbox, or tenant boundary does this represent?",
      "Which review contexts are allowed to use this account's data?",
      "What should Rye never infer from account membership or provider metadata?",
      "Should items from this account be reviewed per item, per container, or by default rules?",
    ];
  }
  return [
    "What is this provider container normally used for?",
    "Which review contexts are allowed here, and is any one of them the default?",
    "What should Rye never infer from the container name, membership, or provider metadata?",
    "Should high-confidence items create candidate facts/tasks, or only remain source evidence?",
  ];
}

function SourceSummaryCard({ summary }: { summary: SourceSummary }) {
  return (
    <section className="card">
      <div className="mb-4 flex flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2 text-sm">
            <Database size={14} /> Source rollup
          </div>
          <div className="flex flex-wrap justify-end gap-2 text-xs">
            <span className="chip" title="Provider-native subdivisions included in this roll-up.">
              {summary.container_count} containers
            </span>
            <span className="chip" title="Individual imported records counted under this source scope.">
              {summary.item_count} source items
            </span>
            <span className="chip" title="Review purposes currently used to classify these source items.">
              {summary.contexts.length} review contexts
            </span>
          </div>
        </div>
        <p className="text-sm leading-5 text-[color:var(--color-ink-muted)]">
          A roll-up is an aggregate of collected source scope and proposed
          classification routes. Use it to verify coverage, find unclassified
          or misrouted inputs, and decide whether source material is ready to
          become candidate facts, tasks, or accepted knowledge connections.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-5 md:grid-cols-3">
        <div>
          <div className="mb-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            Proposed routes by context
          </div>
          {summary.contexts.length === 0 ? (
            <div className="text-xs text-[color:var(--color-ink-dim)]">None.</div>
          ) : (
            <ul className="flex flex-col divide-y divide-[color:var(--color-line-soft)]">
              {summary.contexts.map((context) => (
                <li key={context.id} className="flex items-center justify-between gap-3 py-2 text-sm">
                  <Link
                    to={`/nodes/${context.id}`}
                    className="truncate hover:text-[color:var(--color-rye)]"
                  >
                    {context.label}
                  </Link>
                  <span className="pill shrink-0">{context.item_count}</span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="md:col-span-2">
          <div className="mb-2 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            Recent source items
          </div>
          {summary.recent_items.length === 0 ? (
            <div className="text-xs text-[color:var(--color-ink-dim)]">None.</div>
          ) : (
            <ul className="grid grid-cols-1 gap-x-4 divide-y divide-[color:var(--color-line-soft)] md:grid-cols-2">
              {summary.recent_items.slice(0, 6).map((item) => (
                <li key={item.id} className="py-2 text-sm">
                  <Link
                    to={`/nodes/${item.id}`}
                    className="block truncate hover:text-[color:var(--color-rye)]"
                  >
                    {item.label}
                  </Link>
                  <div className="mt-1 flex flex-wrap items-center gap-1 text-[10px] text-[color:var(--color-ink-muted)]">
                    {item.source_key ? <span className="pill">{item.source_key}</span> : null}
                    {item.contexts.slice(0, 2).map((context) => (
                      <span key={context} className="pill">
                        {context}
                      </span>
                    ))}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </section>
  );
}

function TypeLegendOverlay({ node, onClose }: { node: NodeRow; onClose: () => void }) {
  const nodeType = describeNodeType(node.node_type);
  const sourceType = describeExternalSource(node.external_source);
  const shouldShowNodeTypeTitle = nodeType.title.toLowerCase() !== humanizeKey(node.node_type).toLowerCase();
  const namespaceLabel = node.external_source ?? "not recorded";
  const shouldShowNamespaceTitle = sourceType.title.toLowerCase() !== humanizeKey(namespaceLabel).toLowerCase();
  const semanticExamples = [
    "person",
    "org",
    "project",
    "workstream",
    "task",
  ];

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/70 px-4 py-10 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="type-legend-title"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div className="max-h-[calc(100vh-80px)] w-full max-w-3xl overflow-y-auto rounded-xl border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-5 shadow-2xl scrollbar">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div>
            <h2 id="type-legend-title" className="text-lg font-semibold tracking-tight">
              Rye Label Legend
            </h2>
            <p className="mt-1 text-sm leading-5 text-[color:var(--color-ink-muted)]">
              The header labels describe the role of this record in Rye. They are
              not business conclusions by themselves.
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="inline-flex size-8 shrink-0 items-center justify-center rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] text-[color:var(--color-ink-muted)] transition hover:border-[color:var(--color-rye)] hover:text-[color:var(--color-ink)]"
            aria-label="Close legend"
          >
            <X size={16} />
          </button>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <section className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-4">
            <div className="field-label">Current node type</div>
            <div className="mt-2 flex items-center gap-2">
              <span
                className="size-2 rounded-full"
                style={{ background: colorForType(node.node_type) }}
              />
              <span className="font-mono text-xs uppercase tracking-wider text-[color:var(--color-cyan)]">
                {node.node_type}
              </span>
            </div>
            {shouldShowNodeTypeTitle ? (
              <h3 className="mt-3 text-sm font-medium text-[color:var(--color-ink)]">
                {nodeType.title}
              </h3>
            ) : null}
            <p className={(shouldShowNodeTypeTitle ? "mt-1" : "mt-3") + " text-sm leading-5 text-[color:var(--color-ink-muted)]"}>
              {nodeType.description}
            </p>
          </section>

          <section className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-4">
            <div className="field-label">Current namespace</div>
            <div className="mt-2 font-mono text-xs uppercase tracking-wider text-[color:var(--color-violet)]">
              {namespaceLabel}
            </div>
            {shouldShowNamespaceTitle ? (
              <h3 className="mt-3 text-sm font-medium text-[color:var(--color-ink)]">
                {sourceType.title}
              </h3>
            ) : null}
            <p className={(shouldShowNamespaceTitle ? "mt-1" : "mt-3") + " text-sm leading-5 text-[color:var(--color-ink-muted)]"}>
              {sourceType.description}
            </p>
          </section>
        </div>

        <section className="mt-4 rounded-md border border-[color:var(--color-line-soft)] p-4">
          <h3 className="text-sm font-medium text-[color:var(--color-ink)]">
            Why these distinctions exist
          </h3>
          <ul className="mt-3 grid grid-cols-2 gap-2 text-sm leading-5 text-[color:var(--color-ink-muted)]">
            <li className="rounded bg-[color:var(--color-surface-2)] p-3">
              Rye separates where information came from from what it means.
            </li>
            <li className="rounded bg-[color:var(--color-surface-2)] p-3">
              Agents can cite provenance before creating facts, tasks, or relationships.
            </li>
            <li className="rounded bg-[color:var(--color-surface-2)] p-3">
              Source metadata can be confirmed, rejected, or superseded over time.
            </li>
            <li className="rounded bg-[color:var(--color-surface-2)] p-3">
              Review contexts tell the classifier why something matters and what links are allowed.
            </li>
          </ul>
        </section>

        <section className="mt-4">
          <div className="mb-2 field-label">Common node types</div>
          <div className="grid grid-cols-2 gap-2 text-sm">
            {["source_account", "source_container", "source_item", "review_context"].map((type) => {
              const def = describeNodeType(type);
              return (
                <div key={type} className="rounded-md border border-[color:var(--color-line-soft)] p-3">
                  <div className="font-mono text-[11px] uppercase tracking-wider text-[color:var(--color-cyan)]">
                    {type}
                  </div>
                  <div className="mt-1 text-[color:var(--color-ink-muted)]">
                    {def.short}
                  </div>
                </div>
              );
            })}
            <div className="rounded-md border border-[color:var(--color-line-soft)] p-3">
              <div className="font-mono text-[11px] uppercase tracking-wider text-[color:var(--color-cyan)]">
                semantic nodes
              </div>
              <div className="mt-1 text-[color:var(--color-ink-muted)]">
                {semanticExamples.join(", ")}: extracted or curated meaning from source material.
              </div>
            </div>
          </div>
        </section>

        <div className="mt-4 rounded-md bg-[color:var(--color-surface-2)] p-3 text-sm leading-5 text-[color:var(--color-ink-muted)]">
          On this page, <span className="font-mono text-[color:var(--color-ink)]">{node.node_type}</span>{" "}
          means the record shape, while{" "}
          <span className="font-mono text-[color:var(--color-ink)]">
            {node.external_source ?? "not recorded"}
          </span>{" "}
          identifies the process or provider namespace that created it.
        </div>
      </div>
    </div>
  );
}

type JsonObject = Record<string, unknown>;
type DisplayFact = { label: string; value: string };
type PersonFact = { label: string; value: string; detail?: string };
type LinkFact = { label: string; url: string };
type EdgeCategory = "provenance" | "classification" | "knowledge";
type EdgeCategorySummary = Record<EdgeCategory, number>;

function SourceItemDetails({
  node,
  props,
  artifacts,
  assertions,
  edgesOut,
}: {
  node: NodeRow;
  props: JsonObject;
  artifacts: ArtifactRow[];
  assertions: AssertionRow[];
  edgesOut: EdgeNeighbor[];
}) {
  const metadata = asRecord(props.metadata);
  const classification = asRecord(props.classification);
  const attrs = asRecord(node.attrs);
  const contextLabels = edgesOut
    .filter((edge) => edge.edge_type === "reviewed_under")
    .map((edge) => edge.label);
  const fallbackContextIds = asStringArray(classification.context_ids);
  const routeLabels = contextLabels.length > 0 ? contextLabels : fallbackContextIds;
  const classificationRationale = firstString(classification.rationale);
  const classificationEvidence = asStringArray(classification.evidence);
  const classificationConfidence = firstString(classification.confidence);

  const primaryFacts = useMemo(
    () =>
      [
        fact(
          "Item type",
          firstString(
            props.item_type,
            props.source_type,
            metadata.item_type,
            metadata.type,
            metadata.provider_item_type,
            node.external_source
          )
        ),
        fact(
          "Provider",
          firstString(props.provider, metadata.provider, props.source_type, node.external_source)
        ),
        fact("Channel", firstString(metadata.channel_name) ? `Slack #${metadata.channel_name}` : null),
        fact("Author", firstString(metadata.author_label, metadata.author_id)),
        fact(
          "External id",
          firstString(
            node.external_id,
            props.external_id,
            props.recording_id,
            metadata.external_id,
            metadata.id,
            metadata.recording_id
          )
        ),
        fact("Source value", firstString(props.source_value, metadata.source_value)),
        fact("Visibility", firstString(props.visibility, metadata.visibility)),
        fact("Persistence reason", firstString(props.persistence_reason, metadata.persistence_reason)),
        fact(
          "Occurred",
          firstTimestamp(
            props.occurred_at,
            metadata.occurred_at,
            metadata.start,
            metadata.started_at,
            metadata.created_at
          )
        ),
        fact("Source key", firstString(attrs.source_item_key, props.source_item_key, props.id)),
      ].filter((item): item is DisplayFact => Boolean(item)),
    [attrs, metadata, node.external_id, node.external_source, props]
  );

  const timeFields = useMemo(() => collectTimeFields(props), [props]);
  const links = useMemo(() => collectLinks(props, artifacts), [artifacts, props]);
  const primaryExternalLink = useMemo(() => selectPrimaryExternalLink(links), [links]);
  const people = useMemo(() => collectPeople(props), [props]);
  const narratives = useMemo(() => extractNarratives(assertions), [assertions]);
  const excerpt = useMemo(() => selectArtifactExcerpt(artifacts), [artifacts]);
  const evidence = asStringArray(props.evidence);
  const contract = asString(props.contract);
  const confirmationStatus = firstString(props.confirmation_status, classification.confirmation_status);

  return (
    <div className="min-w-0">
      <div className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-2 text-sm">
          <FileText size={14} /> Source item
        </div>
        {primaryExternalLink ? (
          <a
            href={primaryExternalLink.url}
            target="_blank"
            rel="noreferrer"
            className="inline-flex w-fit items-center gap-2 rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] px-3 py-1.5 text-sm text-[color:var(--color-ink)] hover:border-[color:var(--color-cyan)] hover:text-white"
            title={primaryExternalLink.url}
          >
            <ExternalLink size={14} />
            Open external item
          </a>
        ) : null}
      </div>

      <div className="space-y-4">
        <SourceItemStatusPanel
          routes={routeLabels}
          confidence={classificationConfidence}
          rationale={classificationRationale}
          evidence={classificationEvidence}
        />

        {primaryFacts.length > 0 ? (
          <dl className="grid grid-cols-1 gap-2 text-sm">
            {primaryFacts.map((item) => (
              <div key={item.label} className="min-w-0">
                <dt className="field-label">{item.label}</dt>
                <dd className="mt-1 break-words text-[color:var(--color-ink)]">
                  {item.value}
                </dd>
              </div>
            ))}
          </dl>
        ) : (
          <div className="text-xs text-[color:var(--color-ink-dim)]">
            No source identity fields were recorded.
          </div>
        )}

        <SourceDetailSection icon={<Tags size={14} />} title="Proposed review routes">
          {routeLabels.length > 0 ? (
            <PillList items={routeLabels} />
          ) : (
            <EmptyLine>No review context has been recorded.</EmptyLine>
          )}
        </SourceDetailSection>

        {narratives.length > 0 ? (
          <SourceDetailSection title="Purpose and rationale">
            <div className="space-y-3">
              {narratives.map((item) => (
                <div key={item.label}>
                  <div className="field-label">{item.label}</div>
                  <p className="mt-1 whitespace-pre-wrap text-sm leading-5 text-[color:var(--color-ink)]">
                    {item.value}
                  </p>
                </div>
              ))}
            </div>
          </SourceDetailSection>
        ) : null}

        {timeFields.length > 0 ? (
          <SourceDetailSection icon={<Calendar size={14} />} title="Time fields">
            <dl className="space-y-2 text-sm">
              {timeFields.map((item) => (
                <div key={`${item.label}:${item.value}`}>
                  <dt className="field-label">{item.label}</dt>
                  <dd className="mt-1 text-[color:var(--color-ink)]">{item.value}</dd>
                </div>
              ))}
            </dl>
          </SourceDetailSection>
        ) : null}

        {people.length > 0 ? (
          <SourceDetailSection icon={<Users size={14} />} title="People listed in metadata">
            <ul className="space-y-2">
              {people.slice(0, 8).map((person) => (
                <li key={person.value} className="min-w-0 text-sm">
                  <div className="truncate text-[color:var(--color-ink)]">{person.label}</div>
                  {person.detail ? (
                    <div className="truncate text-xs text-[color:var(--color-ink-muted)]">
                      {person.detail}
                    </div>
                  ) : null}
                </li>
              ))}
              {people.length > 8 ? (
                <li className="text-xs text-[color:var(--color-ink-dim)]">
                  +{people.length - 8} more
                </li>
              ) : null}
            </ul>
          </SourceDetailSection>
        ) : null}

        {links.length > 0 ? (
          <SourceDetailSection icon={<Link2 size={14} />} title="Source links">
            <ul className="space-y-2">
              {links.slice(0, 6).map((link) => (
                <li key={link.url} className="min-w-0 text-sm">
                  <a
                    href={link.url}
                    target="_blank"
                    rel="noreferrer"
                    className="block truncate text-[color:var(--color-cyan)] hover:text-white"
                    title={link.url}
                  >
                    {link.label}
                  </a>
                </li>
              ))}
            </ul>
          </SourceDetailSection>
        ) : null}

        {excerpt ? (
          <SourceDetailSection title="Content excerpt">
            <div className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
              <div className="field-label">{excerpt.artifactType}</div>
              <p className="mt-2 whitespace-pre-wrap text-sm leading-5 text-[color:var(--color-ink)]">
                {excerpt.text}
              </p>
            </div>
          </SourceDetailSection>
        ) : null}

        {(contract || evidence.length > 0 || confirmationStatus) ? (
          <SourceDetailSection title="Validation and provenance">
            <dl className="space-y-3 text-sm">
              {confirmationStatus ? (
                <div>
                  <dt className="field-label">Confirmation status</dt>
                  <dd className="mt-1 text-[color:var(--color-ink)]">{confirmationStatus}</dd>
                </div>
              ) : null}
              {contract ? (
                <div>
                  <dt className="field-label">Contract</dt>
                  <dd className="mt-1 break-all font-mono text-xs text-[color:var(--color-ink-muted)]">
                    {contract}
                  </dd>
                </div>
              ) : null}
              {evidence.length > 0 ? (
                <div>
                  <dt className="field-label">Evidence notes</dt>
                  <dd className="mt-2 flex flex-wrap gap-1">
                    {evidence.map((item) => (
                      <span key={item} className="pill max-w-full break-words whitespace-normal">
                        {item}
                      </span>
                    ))}
                  </dd>
                </div>
              ) : null}
            </dl>
          </SourceDetailSection>
        ) : null}

        <details className="border-t border-[color:var(--color-line-soft)] pt-3">
          <summary className="cursor-pointer text-xs uppercase tracking-wider text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-ink)]">
            Raw properties
          </summary>
          <div className="mt-3 max-h-[360px] overflow-auto pr-1 scrollbar">
            <PropertyList props={props} />
          </div>
        </details>
      </div>
    </div>
  );
}

function ReviewContextDetails({
  node,
  props,
  assertions,
  edgesIn,
  contextScope,
}: {
  node: NodeRow;
  props: JsonObject;
  assertions: AssertionRow[];
  edgesIn: EdgeNeighbor[];
  contextScope: ReviewContextScope | null;
}) {
  const metadata = asRecord(props.metadata);
  const purpose = firstString(
    props.purpose,
    claimText(assertions.find((assertion) => assertion.assertion_type === "purpose")?.claim)
  );
  const relevanceRules = dedupe([
    ...asStringArray(props.relevance_rules),
    ...assertionTexts(assertions, "relevance_rule"),
  ]);
  const edgePolicies = dedupe([
    ...asStringArray(props.edge_policies),
    ...assertionTexts(assertions, "edge_policy"),
  ]);
  const taskPolicy = firstString(
    props.task_policy,
    claimText(assertions.find((assertion) => assertion.assertion_type === "task_policy")?.claim)
  );
  const routingHints = dedupe([
    ...asStringArray(props.routing_hints),
    ...asStringArray(metadata.routing_hints),
    ...asStringArray(metadata.keywords),
  ]);
  const usage = summarizeEdges(edgesIn);
  const contract = asString(props.contract);
  const contextId = firstString(props.context_id, props.source_context_id, node.external_id);
  const version = firstString(props.version, metadata.profiles_version, metadata.version);

  return (
    <div className="min-w-0">
      <div className="mb-4 flex items-center gap-2 text-sm">
        <Tags size={14} /> Review context
      </div>

      <div className="space-y-4">
        <dl className="grid grid-cols-1 gap-2 text-sm">
          {[
            fact("Context id", contextId),
            fact("Profile source", firstString(node.external_source, props.source_context_record_kind)),
            fact("Profile version", version),
          ]
            .filter((item): item is DisplayFact => Boolean(item))
            .map((item) => (
              <div key={item.label} className="min-w-0">
                <dt className="field-label">{item.label}</dt>
                <dd className="mt-1 break-words text-[color:var(--color-ink)]">
                  {item.value}
                </dd>
              </div>
            ))}
        </dl>

        <SourceDetailSection title="Containing scope">
          <div className="space-y-3">
            <p className="text-sm leading-5 text-[color:var(--color-ink-muted)]">
              Review context labels are not global identity. Use this node only
              for material that belongs to the same confirmed scope; the same
              label for another customer, matter, source, or time period should
              be represented by a separate scoped review context unless explicitly linked.
            </p>
            <ReviewContextScopeDetails scope={contextScope} />
          </div>
        </SourceDetailSection>

        {purpose ? (
          <SourceDetailSection title="Purpose">
            <p className="whitespace-pre-wrap text-sm leading-5 text-[color:var(--color-ink)]">
              {purpose}
            </p>
          </SourceDetailSection>
        ) : null}

        {routingHints.length > 0 ? (
          <SourceDetailSection title="Routing hints">
            <PillList items={routingHints} />
          </SourceDetailSection>
        ) : null}

        {usage.length > 0 ? (
          <SourceDetailSection title="Currently connected">
            <div className="grid grid-cols-2 gap-2">
              {usage.map((item) => (
                <div
                  key={item.label}
                  className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2"
                >
                  <div className="text-lg font-semibold text-[color:var(--color-ink)]">
                    {item.count}
                  </div>
                  <div className="mt-0.5 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-muted)]">
                    {item.label}
                  </div>
                </div>
              ))}
            </div>
          </SourceDetailSection>
        ) : null}

        {relevanceRules.length > 0 ? (
          <SourceDetailSection title="What to keep">
            <PlainList items={relevanceRules} />
          </SourceDetailSection>
        ) : null}

        {edgePolicies.length > 0 ? (
          <SourceDetailSection title="When to connect">
            <PlainList items={edgePolicies} />
          </SourceDetailSection>
        ) : null}

        {taskPolicy ? (
          <SourceDetailSection title="Task policy">
            <p className="whitespace-pre-wrap text-sm leading-5 text-[color:var(--color-ink)]">
              {taskPolicy}
            </p>
          </SourceDetailSection>
        ) : null}

        {contract ? (
          <SourceDetailSection title="Validation">
            <dl className="space-y-2 text-sm">
              <div>
                <dt className="field-label">Contract</dt>
                <dd className="mt-1 break-all font-mono text-xs text-[color:var(--color-ink-muted)]">
                  {contract}
                </dd>
              </div>
            </dl>
          </SourceDetailSection>
        ) : null}

        <details className="border-t border-[color:var(--color-line-soft)] pt-3">
          <summary className="cursor-pointer text-xs uppercase tracking-wider text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-ink)]">
            Raw properties
          </summary>
          <div className="mt-3 max-h-[360px] overflow-auto pr-1 scrollbar">
            <PropertyList props={props} />
          </div>
        </details>
      </div>
    </div>
  );
}

function ReviewContextScopeDetails({ scope }: { scope: ReviewContextScope | null }) {
  if (!scope || scope.source_items_count === 0) {
    return (
      <div className="rounded-md border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-sm leading-5 text-amber-200">
        No containing source scope is recorded for this review context yet.
        Treat the label as ambiguous until a source account, customer, matter,
        workspace, or other boundary is confirmed.
      </div>
    );
  }

  return (
    <div className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
      <div className="field-label">Current scope evidence</div>
      <p className="mt-2 text-sm leading-5 text-[color:var(--color-ink)]">
        Derived from {scope.source_items_count} routed {pluralize("source item", scope.source_items_count)}.
        This is a working scope inferred from current routing, not proof that
        every future item named this way belongs here.
      </p>

      <dl className="mt-3 grid grid-cols-1 gap-3 text-sm md:grid-cols-2">
        <div>
          <dt className="field-label">Source accounts</dt>
          <dd className="mt-1 text-[color:var(--color-ink)]">
            {scope.source_accounts.length > 0
              ? scope.source_accounts.map((item) => `${item.label} (${item.item_count})`).join(", ")
              : "Not linked"}
          </dd>
        </div>
        <div>
          <dt className="field-label">Source containers</dt>
          <dd className="mt-1 text-[color:var(--color-ink)]">
            {scope.source_containers.length > 0
              ? scope.source_containers.map((item) => `${item.label} (${item.item_count})`).join(", ")
              : "Not linked"}
          </dd>
        </div>
      </dl>
    </div>
  );
}

function reviewContextScopeLabel(scope: ReviewContextScope | null): string {
  if (!scope || scope.source_items_count === 0) {
    return "scope not recorded; do not treat this label as global.";
  }
  const accounts = scope.source_accounts.map((item) => item.label);
  const containers = scope.source_containers.map((item) => item.label);
  const target = [...accounts, ...containers].slice(0, 3).join(" / ");
  const suffix =
    accounts.length + containers.length > 3
      ? ` +${accounts.length + containers.length - 3} more`
      : "";
  return `${target || "routed source items"}${suffix} (${scope.source_items_count} ${pluralize("source item", scope.source_items_count)}, derived)`;
}

function pluralize(label: string, count: number): string {
  return count === 1 ? label : `${label}s`;
}

function SourceHubDetails({
  node,
  props,
  assertions,
  summary,
}: {
  node: NodeRow;
  props: JsonObject;
  assertions: AssertionRow[];
  summary: SourceSummary | null;
}) {
  const metadata = asRecord(props.metadata);
  const confirmationStatus = firstString(props.confirmation_status, asRecord(props.context_confirmation).status);
  const sourcePurpose = firstString(
    claimText(assertions.find((assertion) => assertion.assertion_type === "source_purpose")?.claim),
    props.purpose
  );
  const neverInfer = asStringArray(props.never_infer);
  const allowedContexts = asStringArray(props.allowed_context_ids);
  const defaultContexts = asStringArray(props.default_context_ids);
  const holdingContext = firstString(props.holding_context_id);
  const evidence = dedupe([
    ...asStringArray(props.evidence),
    ...asStringArray(asRecord(props.context_confirmation).evidence),
  ]);
  const sourceFacts = [
    fact("Provider", firstString(props.provider, metadata.source_type, node.external_source)),
    fact("Container type", firstString(props.container_type, metadata.container_type)),
    fact("Native label", firstString(metadata.native_label, props.native_label)),
    fact("Provider scope", firstString(metadata.provider_scope, props.provider_scope)),
    fact("External id", firstString(node.external_id, props.source_context_id)),
    fact("Confirmation", confirmationStatus),
    fact("Holding context", firstString(props.holding_context_id)),
  ].filter((item): item is DisplayFact => Boolean(item));

  return (
    <div className="min-w-0">
      <div className="mb-4 flex items-center gap-2 text-sm">
        <Database size={14} />
        {node.node_type === "source_account" ? "Source account" : "Source container"}
      </div>

      <div className="space-y-4">
        <SourceConfirmationPanel
          node={node}
          status={confirmationStatus}
          allowedContexts={allowedContexts}
          defaultContexts={defaultContexts}
          holdingContext={holdingContext}
        />

        {sourceFacts.length > 0 ? (
          <dl className="grid grid-cols-1 gap-2 text-sm">
            {sourceFacts.map((item) => (
              <div key={item.label} className="min-w-0">
                <dt className="field-label">{item.label}</dt>
                <dd className="mt-1 break-words text-[color:var(--color-ink)]">
                  {item.value}
                </dd>
              </div>
            ))}
          </dl>
        ) : null}

        {summary ? (
          <SourceDetailSection title="Roll-up inventory">
            <p className="mb-3 text-sm leading-5 text-[color:var(--color-ink-muted)]">
              Counts aggregated from this source scope. Use them to compare what
              was collected against how much has been classified for review.
            </p>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
              <MetricTile label="containers" count={summary.container_count} />
              <MetricTile label="source items" count={summary.item_count} />
              <MetricTile label="review contexts" count={summary.contexts.length} />
            </div>
          </SourceDetailSection>
        ) : null}

        {sourcePurpose ? (
          <SourceDetailSection title="Collection purpose">
            <p className="whitespace-pre-wrap text-sm leading-5 text-[color:var(--color-ink)]">
              {sourcePurpose}
            </p>
          </SourceDetailSection>
        ) : null}

        {neverInfer.length > 0 ? (
          <SourceDetailSection title="Never infer">
            <PlainList items={neverInfer} />
          </SourceDetailSection>
        ) : null}

        {evidence.length > 0 ? (
          <SourceDetailSection title="Evidence">
            <PlainList items={evidence} />
          </SourceDetailSection>
        ) : null}

        <details className="border-t border-[color:var(--color-line-soft)] pt-3">
          <summary className="cursor-pointer text-xs uppercase tracking-wider text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-ink)]">
            Raw properties
          </summary>
          <div className="mt-3 max-h-[360px] overflow-auto pr-1 scrollbar">
            <PropertyList props={props} />
          </div>
        </details>
      </div>
    </div>
  );
}

function SourceConfirmationPanel({
  node,
  status,
  allowedContexts,
  defaultContexts,
  holdingContext,
}: {
  node: NodeRow;
  status: string | null;
  allowedContexts: string[];
  defaultContexts: string[];
  holdingContext: string | null;
}) {
  const needsConfirmation = status === "needs_confirmation" || !status;
  return (
    <section
      className={
        "rounded-md border p-3 " +
        (needsConfirmation
          ? "border-amber-400/30 bg-amber-400/10"
          : "border-emerald-400/30 bg-emerald-400/10")
      }
    >
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="text-sm font-medium text-[color:var(--color-ink)]">
            {needsConfirmation ? "Awaiting source-context confirmation" : "Source context confirmed"}
          </div>
          <p className="mt-1 text-sm leading-5 text-[color:var(--color-ink-muted)]">
            Provider metadata can organize evidence, but it should not create
            business relationships until the purpose and allowed review contexts
            are explicit.
          </p>
        </div>
        <span className="chip shrink-0">{status ? humanizeKey(status) : "Unconfirmed"}</span>
      </div>

      <dl className="mt-3 grid grid-cols-1 gap-3 text-sm md:grid-cols-2">
        <div>
          <dt className="field-label">Allowed contexts</dt>
          <dd className="mt-1">
            {allowedContexts.length > 0 ? (
              <PillList items={allowedContexts.map(humanizeKey)} />
            ) : (
              <EmptyLine>Not confirmed.</EmptyLine>
            )}
          </dd>
        </div>
        <div>
          <dt className="field-label">Default context</dt>
          <dd className="mt-1">
            {defaultContexts.length > 0 ? (
              <PillList items={defaultContexts.map(humanizeKey)} />
            ) : (
              <EmptyLine>No default; classify per item.</EmptyLine>
            )}
          </dd>
        </div>
        {holdingContext ? (
          <div>
            <dt className="field-label">Holding context</dt>
            <dd className="mt-1">
              <span className="pill">{humanizeKey(holdingContext)}</span>
            </dd>
          </div>
        ) : null}
      </dl>

      {needsConfirmation ? (
        <details className="mt-3">
          <summary className="cursor-pointer text-xs uppercase tracking-wider text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-ink)]">
            Confirmation questions for the agent
          </summary>
          <div className="mt-2">
            <PlainList items={confirmationQuestions(node)} />
          </div>
        </details>
      ) : null}
    </section>
  );
}

function SourceItemStatusPanel({
  routes,
  confidence,
  rationale,
  evidence,
}: {
  routes: string[];
  confidence: string | null;
  rationale: string | null;
  evidence: string[];
}) {
  return (
    <section className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="text-sm font-medium text-[color:var(--color-ink)]">
            Classification proposal
          </div>
          <p className="mt-1 text-sm leading-5 text-[color:var(--color-ink-muted)]">
            Rye has source evidence and proposed review routes. This is not an
            accepted fact, task, responsibility, or semantic relationship until
            a validation step promotes it.
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-1">
          {confidence ? <span className="chip">confidence {confidence}</span> : null}
          <span className="chip">{routes.length} routes</span>
        </div>
      </div>
      {routes.length > 0 ? (
        <div className="mt-3">
          <div className="field-label">Proposed routes</div>
          <div className="mt-2">
            <PillList items={routes} />
          </div>
        </div>
      ) : null}
      {rationale ? (
        <p className="mt-3 rounded-md border border-[color:var(--color-line-soft)] bg-black/20 px-3 py-2 text-sm leading-5 text-[color:var(--color-ink)]">
          {rationale}
        </p>
      ) : null}
      {evidence.length > 0 ? (
        <details className="mt-3">
          <summary className="cursor-pointer text-xs uppercase tracking-wider text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-ink)]">
            Routing evidence
          </summary>
          <div className="mt-2">
            <PlainList items={evidence} />
          </div>
        </details>
      ) : null}
    </section>
  );
}

function SourceDetailSection({
  icon,
  title,
  children,
}: {
  icon?: ReactNode;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="border-t border-[color:var(--color-line-soft)] pt-3">
      <div className="mb-2 flex items-center gap-2 text-xs font-medium uppercase tracking-wider text-[color:var(--color-ink-muted)]">
        {icon}
        {title}
      </div>
      {children}
    </section>
  );
}

function MetricTile({ label, count }: { label: string; count: number }) {
  return (
    <div className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2">
      <div className="text-lg font-semibold text-[color:var(--color-ink)]">{count}</div>
      <div className="mt-0.5 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-muted)]">
        {label}
      </div>
    </div>
  );
}

function PlainList({ items }: { items: string[] }) {
  return (
    <ul className="space-y-2 text-sm leading-5 text-[color:var(--color-ink)]">
      {items.map((item) => (
        <li key={item} className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2">
          {item}
        </li>
      ))}
    </ul>
  );
}

function PillList({ items }: { items: string[] }) {
  return (
    <div className="flex flex-wrap gap-1">
      {dedupe(items).map((item) => (
        <span key={item} className="pill max-w-full break-words whitespace-normal">
          {item}
        </span>
      ))}
    </div>
  );
}

function EmptyLine({ children }: { children: ReactNode }) {
  return <div className="text-xs text-[color:var(--color-ink-dim)]">{children}</div>;
}

function describeNodeType(type: string): {
  title: string;
  short: string;
  description: string;
} {
  const defs: Record<string, { title: string; short: string; description: string }> = {
    source_account: {
      title: "Connected source account",
      short: "A connected provider account, workspace, mailbox, or integration.",
      description:
        "A top-level external source, such as a Fathom account, Slack workspace, email account, or document system. It exists so Rye can track collection scope, credentials, confirmation state, and provenance.",
    },
    source_container: {
      title: "Provider-native source container",
      short: "A provider subdivision such as a team, channel, folder, inbox, or drive.",
      description:
        "A subdivision inside a source account. It groups source items by where the provider placed them, without assuming business meaning. For example, a Fathom team named Uncategorized is a Fathom container, not a global Rye category.",
    },
    source_item: {
      title: "Individual source record",
      short: "A single imported message, meeting, email, file, transcript, or row.",
      description:
        "The durable provenance record for a specific thing Rye collected. Facts, events, tasks, and classifications can cite it so later agents know exactly what evidence they came from.",
    },
    review_context: {
      title: "Classification and review purpose",
      short: "A purpose profile that tells agents what matters and when to connect records.",
      description:
        "A review context defines why information is being reviewed, which facts should be kept, and which relationships are valid. It guides classification; it is not the same as the source location.",
    },
    person: {
      title: "Person",
      short: "A human mentioned or involved in the accumulated knowledge.",
      description:
        "A semantic entity representing a person. It should be connected only when source content or confirmed context supports the relationship.",
    },
    org: {
      title: "Organization",
      short: "A company, agency, client, vendor, or other organization.",
      description:
        "A semantic entity representing an organization. Rye keeps it separate from source accounts so provider metadata does not become business truth automatically.",
    },
    project: {
      title: "Project or matter",
      short: "A scoped initiative, client project, matter, or delivery effort.",
      description:
        "A semantic work boundary used to accumulate source evidence, facts, tasks, and decisions that belong together. It should be scoped by source context, customer, matter, or time period when the label could otherwise be ambiguous.",
    },
    task: {
      title: "Task",
      short: "An action item extracted from source content or created by a user/agent.",
      description:
        "A trackable action item. It can link to source evidence and review context so agents know why it exists.",
    },
    workstream: {
      title: "Workstream",
      short: "A recurring line of work, topic, matter, or initiative.",
      description:
        "A semantic grouping for work that accumulates over time across many source items, events, and tasks.",
    },
  };
  return (
    defs[type] ?? {
      title: humanizeKey(type),
      short: "A Rye node type used by this instance.",
      description:
        "A Rye node type identifies what role this record plays in the graph. The detail panels and assertions provide the meaning and evidence.",
    }
  );
}

function describeExternalSource(source: string | null): { title: string; description: string } {
  if (!source) {
    return {
      title: "No source namespace recorded",
      description:
        "This record does not currently expose a provider or intake namespace in the header.",
    };
  }
  const defs: Record<string, { title: string; description: string }> = {
    source_context: {
      title: "Source-context intake",
      description:
        "This record was created by the source-context intake process. That process records connected sources, provider-native containers, confirmation state, and source items before semantic meaning is inferred.",
    },
    context_profile: {
      title: "Review-context profile",
      description:
        "This record was created from a review-context profile: a purpose, relevance rules, and connection policies that guide classification.",
    },
    fathom: {
      title: "Fathom provider data",
      description:
        "This record originated from Fathom data. Provider fields are provenance unless a user or trusted process confirms their business meaning.",
    },
    slack: {
      title: "Slack provider data",
      description:
        "This record originated from Slack data. Workspace, channel, and member metadata should be treated as source context until confirmed.",
    },
    outlook: {
      title: "Outlook provider data",
      description:
        "This record originated from Outlook data. Mailbox and folder metadata describe where content came from, not necessarily what it means.",
    },
  };
  return (
    defs[source] ?? {
      title: humanizeKey(source),
      description:
        "This label identifies the provider, schema, or process namespace that created the record. It is separate from the Rye node type.",
    }
  );
}

function assertionTexts(assertions: AssertionRow[], assertionType: string): string[] {
  return assertions
    .filter((assertion) => !assertion.superseded_at && assertion.assertion_type === assertionType)
    .map((assertion) => claimText(assertion.claim))
    .filter((item): item is string => Boolean(item));
}

function summarizeEdges(edges: EdgeNeighbor[]): { label: string; count: number }[] {
  const counts = new Map<string, number>();
  for (const edge of edges) {
    const label =
      edge.node_type === "source_item"
        ? "source items"
        : edge.node_type === "task"
          ? "tasks"
          : humanizeKey(edge.node_type);
    counts.set(label, (counts.get(label) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([label, count]) => ({ label, count }))
    .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
}

function edgeCategory(edge: { edge_type: string; properties?: Record<string, unknown> }): EdgeCategory {
  const reason = firstString(asRecord(edge.properties).reason_type);
  if (reason === "provenance" || edge.edge_type === "contains_item") return "provenance";
  if (reason === "classification_proposal" || edge.edge_type === "reviewed_under") {
    return "classification";
  }
  return "knowledge";
}

function edgeCategoryLabel(category: EdgeCategory): string {
  if (category === "knowledge") return "accepted";
  if (category === "classification") return "proposed";
  return "provenance";
}

function summarizeEdgeCategories(edges: Array<{ edge_type: string; properties?: Record<string, unknown> }>): EdgeCategorySummary {
  const summary: EdgeCategorySummary = { provenance: 0, classification: 0, knowledge: 0 };
  for (const edge of edges) {
    summary[edgeCategory(edge)] += 1;
  }
  return summary;
}

function summarizeGraphEdges(edges: Array<{ edge_type: string; properties?: Record<string, unknown> }>): EdgeCategorySummary {
  return summarizeEdgeCategories(edges);
}

function graphIntroForNode(node: NodeRow): string {
  if (node.node_type === "source_account" || node.node_type === "source_container") {
    return "This view shows source scope and routing. Source containment and classifier proposals are not accepted business relationships.";
  }
  if (node.node_type === "source_item") {
    return "This view shows how the source item is routed for review. Route edges are classifier proposals until validated.";
  }
  if (node.node_type === "review_context") {
    return "This view shows inputs routed to this review purpose and any accepted semantic links around it.";
  }
  return "This view shows accepted graph neighbors plus any provenance or route edges connected to this node.";
}

function fact(label: string, value: unknown): DisplayFact | null {
  const text = asString(value);
  return text ? { label, value: text } : null;
}

function asRecord(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonObject)
    : {};
}

function asString(value: unknown): string | null {
  if (typeof value === "string" && value.trim()) return value.trim();
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return null;
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    const text = asString(value);
    if (text) return text;
  }
  return null;
}

function firstTimestamp(...values: unknown[]): string | null {
  for (const value of values) {
    const text = asString(value);
    if (text && looksLikeTimestamp(text)) return fmtDate(text);
  }
  return null;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((item) => asString(item)).filter((item): item is string => Boolean(item));
}

function dedupe(items: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of items) {
    const key = item.trim().toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(item.trim());
  }
  return out;
}

function displayNodeTitle(node: NodeRow): string {
  if (node.node_type !== "source_item") return node.label;
  return displaySourceItemLabel(node.label, asRecord(node.properties));
}

function displaySourceItemLabel(label: string, props: JsonObject): string {
  const metadata = asRecord(props.metadata);
  const provider = firstString(metadata.provider, props.provider);
  if (provider !== "slack") return label;

  const channel = firstString(metadata.channel_name);
  const author = firstString(metadata.author_label);
  let next = label;
  const authorId = firstString(metadata.author_id);
  if (author && authorId) {
    next = next.replace(new RegExp(`<@${escapeRegExp(authorId)}>`, "g"), author);
  }

  const fileOnly = channel && new RegExp(`^Slack #${escapeRegExp(channel)}: F[A-Z0-9]+$`).test(next);
  if (fileOnly) return `Slack file attachment in #${channel}`;
  if (channel) {
    const body = next
      .replace(new RegExp(`^Slack #${escapeRegExp(channel)}:\\s*`), "")
      .replace(/^<@[A-Z0-9]+>\s*/, "")
      .replace(/<@[A-Z0-9]+>/g, "@mentioned user");
    if (body && body !== next) {
      return `${author ?? "Slack message"} in #${channel}: ${body}`;
    }
  }
  return next;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function humanizeKey(key: string): string {
  return key
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[_:.-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function collectTimeFields(props: JsonObject): DisplayFact[] {
  const candidates: [string, unknown][] = [];
  const metadata = asRecord(props.metadata);
  const keys = [
    "occurred_at",
    "start",
    "end",
    "started_at",
    "ended_at",
    "created_at",
    "updated_at",
    "sent_at",
    "received_at",
    "recorded_at",
  ];
  for (const key of keys) {
    candidates.push([key, props[key]], [`metadata.${key}`, metadata[key]]);
  }

  const seen = new Set<string>();
  return candidates.flatMap(([key, value]) => {
    const text = asString(value);
    if (!text || seen.has(`${key}:${text}`) || !looksLikeTimestamp(text)) return [];
    seen.add(`${key}:${text}`);
    return [{ label: humanizeKey(key.replace(/^metadata\./, "")), value: fmtDate(text) }];
  });
}

function looksLikeTimestamp(value: string): boolean {
  if (!/\d{4}-\d{2}-\d{2}/.test(value)) return false;
  return !Number.isNaN(Date.parse(value));
}

function collectLinks(props: JsonObject, artifacts: ArtifactRow[]): LinkFact[] {
  const links: LinkFact[] = [];
  const visit = (value: unknown, path: string, depth: number) => {
    if (links.length >= 12 || depth > 4) return;
    const text = asString(value);
    if (text) {
      const urls = extractHttpUrls(text);
      if (urls.length > 0) {
        for (const url of urls) {
          links.push({ label: linkLabelForPath(path), url });
        }
        return;
      }
    }
    if (Array.isArray(value)) {
      value.slice(0, 20).forEach((item, index) => visit(item, `${path}.${index}`, depth + 1));
      return;
    }
    if (value && typeof value === "object") {
      Object.entries(value as JsonObject).forEach(([key, child]) => {
        if (key.toLowerCase().includes("email")) return;
        visit(child, path ? `${path}.${key}` : key, depth + 1);
      });
    }
  };

  visit(props, "properties", 0);
  for (const artifact of artifacts) {
    visit(artifact.location, `artifact.${artifact.artifact_type}.location`, 0);
    visit(artifact.content, `artifact.${artifact.artifact_type}.content`, 0);
  }

  const seen = new Set<string>();
  return links.filter((link) => {
    if (seen.has(link.url)) return false;
    seen.add(link.url);
    return true;
  });
}

function selectPrimaryExternalLink(links: LinkFact[]): LinkFact | null {
  return (
    links.find((link) => /external|permalink|source|message|recording|meeting/i.test(link.label)) ??
    links[0] ??
    null
  );
}

function linkLabelForPath(path: string): string {
  const last = path.split(".").pop() ?? "link";
  const key = last.toLowerCase();
  if (key === "external_url" || key === "permalink" || key === "web_url") return "External item";
  if (key === "title_link" || key === "original_url") return "Linked attachment";
  if (key === "url") return "Link";
  return humanizeKey(last);
}

function extractHttpUrls(value: string): string[] {
  const urls = new Set<string>();
  const slackLinkPattern = /<((?:https?:\/\/)[^>|]+)(?:\|[^>]+)?>/g;
  let match: RegExpExecArray | null;
  while ((match = slackLinkPattern.exec(value))) {
    const url = cleanUrl(match[1]);
    if (isHttpUrl(url)) urls.add(url);
  }

  const plainPattern = /\bhttps?:\/\/[^\s<>"']+/g;
  while ((match = plainPattern.exec(value))) {
    const url = cleanUrl(match[0]);
    if (isHttpUrl(url)) urls.add(url);
  }
  return [...urls];
}

function cleanUrl(value: string): string {
  return value.replace(/[)\].,;:!?]+$/g, "");
}

function isHttpUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

function collectPeople(props: JsonObject): PersonFact[] {
  const metadata = asRecord(props.metadata);
  const candidateArrays = [
    props.people,
    props.participants,
    props.attendees,
    props.invitees,
    metadata.people,
    metadata.participants,
    metadata.attendees,
    metadata.invitees,
  ];
  const people: PersonFact[] = [];

  for (const candidate of candidateArrays) {
    if (!Array.isArray(candidate)) continue;
    for (const item of candidate) {
      const person = personFromValue(item);
      if (person) people.push(person);
    }
  }

  const recordedBy = personFromValue(props.recorded_by) ?? personFromValue(metadata.recorded_by);
  if (recordedBy) people.unshift(recordedBy);

  const seen = new Set<string>();
  return people.filter((person) => {
    const key = person.value.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function personFromValue(value: unknown): PersonFact | null {
  const text = asString(value);
  if (text) return { label: text, value: text };
  const record = asRecord(value);
  const label = firstString(record.name, record.display_name, record.real_name, record.email, record.id);
  if (!label) return null;
  const detail = firstString(record.email, record.domain, record.id);
  return { label, value: detail ? `${label}:${detail}` : label, detail: detail ?? undefined };
}

function extractNarratives(assertions: AssertionRow[]): DisplayFact[] {
  const allowed = ["purpose", "rationale", "classification", "recording"];
  return assertions
    .filter((assertion) => !assertion.superseded_at)
    .filter((assertion) => allowed.some((token) => assertion.assertion_type.includes(token)))
    .map((assertion) => fact(humanizeKey(assertion.assertion_type), claimText(assertion.claim)))
    .filter((item): item is DisplayFact => Boolean(item));
}

function claimText(claim: unknown): string | null {
  const text = asString(claim);
  if (text) return text;
  const record = asRecord(claim);
  return firstString(
    record.text,
    record.summary,
    record.purpose,
    record.rationale,
    record.reason,
    record.note,
    record.description
  );
}

function isSimpleTextClaim(claim: unknown): boolean {
  if (asString(claim)) return true;
  const record = asRecord(claim);
  const keys = Object.keys(record);
  return keys.length === 1 && keys[0] === "text" && Boolean(asString(record.text));
}

function selectArtifactExcerpt(
  artifacts: ArtifactRow[]
): { artifactType: string; text: string } | null {
  const ranked = [...artifacts].sort((a, b) => artifactRank(a) - artifactRank(b));
  for (const artifact of ranked) {
    const text = artifactText(artifact);
    if (text) return { artifactType: humanizeKey(artifact.artifact_type), text };
  }
  return null;
}

function artifactRank(artifact: ArtifactRow): number {
  if (artifact.artifact_type.includes("summary")) return 0;
  if (artifact.artifact_type.includes("content")) return 1;
  return 2;
}

function artifactText(artifact: ArtifactRow): string | null {
  const content = asRecord(artifact.content);
  const nested = asRecord(content.content);
  const messages = nested.messages;
  if (Array.isArray(messages)) {
    const lines = messages
      .slice(0, 8)
      .map((message) => {
        const record = asRecord(message);
        const author = firstString(record.author_label, record.author_id, "Message");
        const text = firstString(record.text, record.summary, record.title);
        return text ? `${author}: ${text}` : null;
      })
      .filter((line): line is string => Boolean(line));
    if (lines.length > 0) return compactText(lines.join("\n"), 720);
  }
  const text = firstString(
    content.summary,
    content.markdown,
    content.text,
    content.body,
    nested.summary,
    nested.markdown,
    nested.text,
    nested.body
  );
  if (!text) return null;
  return compactText(stripMarkdown(text), 420);
}

function stripMarkdown(value: string): string {
  return value
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[*_`#>]+/g, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function compactText(value: string, maxLength: number): string {
  const text = value.replace(/[ \t]+/g, " ").trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength).trim()}...`;
}

function PropertyList({ props }: { props: Record<string, unknown> }) {
  const entries = useMemo(() => Object.entries(props), [props]);
  if (entries.length === 0)
    return (
      <div className="text-xs text-[color:var(--color-ink-dim)]">No properties.</div>
    );
  return (
    <dl className="flex flex-col divide-y divide-[color:var(--color-line-soft)] text-sm">
      {entries.map(([k, v]) => (
        <div key={k} className="grid grid-cols-[120px_1fr] gap-2 py-2">
          <dt className="font-mono text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
            {k}
          </dt>
          <dd className="break-words text-[color:var(--color-ink)]">
            <PropertyValue v={v} />
          </dd>
        </div>
      ))}
    </dl>
  );
}

function PropertyValue({ v }: { v: unknown }) {
  if (v === null || v === undefined)
    return <span className="text-[color:var(--color-ink-dim)]">—</span>;
  if (Array.isArray(v))
    return (
      <div className="flex flex-wrap gap-1">
        {v.map((it, i) => (
          <span key={i} className="pill">
            {String(it)}
          </span>
        ))}
      </div>
    );
  if (typeof v === "object")
    return (
      <pre className="overflow-x-auto rounded bg-[color:var(--color-surface-2)] p-2 font-mono text-[11px]">
        {JSON.stringify(v, null, 2)}
      </pre>
    );
  const s = String(v);
  if (s.startsWith("<") && s.endsWith(">"))
    return (
      <span className="text-[color:var(--color-ink-muted)]">
        {s.slice(0, 160)}…
      </span>
    );
  return <span>{s}</span>;
}

function AssertionList({ items }: { items: AssertionRow[] }) {
  if (items.length === 0)
    return (
      <div className="card text-xs text-[color:var(--color-ink-dim)]">
        No assertions on this node.
      </div>
    );
  return (
    <div className="card">
      <div className="mb-2 flex items-center gap-2 text-sm">
        <ScrollText size={14} /> Assertions
        <span className="chip">{items.length}</span>
      </div>
      <p className="mb-4 text-sm leading-5 text-[color:var(--color-ink-muted)]">
        Assertions are Rye's stored claims and rules for this node. For a review
        context, they explain why the context exists, what information belongs
        here, when connections should be created, and when tasks should be made.
        <span className="text-[color:var(--color-ink)]"> Current</span> means
        the assertion has not been replaced by a newer one; replaced assertions
        stay visible for audit history.
      </p>
      <ul className="flex flex-col divide-y divide-[color:var(--color-line-soft)]">
        {items.map((assertion) => {
          const definition = describeAssertion(assertion.assertion_type);
          const status = assertionStatus(assertion);
          return (
            <li key={assertion.id} className="py-4">
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-sm font-medium text-[color:var(--color-ink)]">
                      {definition.title}
                    </span>
                    <span className="chip">{definition.category}</span>
                  </div>
                  <p className="mt-1 text-sm leading-5 text-[color:var(--color-ink-muted)]">
                    {definition.description}
                  </p>
                </div>
                <span
                  className={
                    "shrink-0 rounded-md px-2 py-1 text-[10px] uppercase tracking-wider " +
                    (assertion.superseded_at
                      ? "border border-[color:var(--color-line)] text-[color:var(--color-ink-dim)]"
                      : "border border-emerald-400/30 bg-emerald-400/10 text-emerald-300")
                  }
                  title={status.description}
                >
                  {status.label}
                </span>
              </div>

              <div className="mt-3">
                <div className="field-label">Stored claim or rule</div>
                {isSimpleTextClaim(assertion.claim) ? (
                  <p className="mt-1 rounded-md bg-[color:var(--color-surface-2)] p-3 text-sm leading-5 text-[color:var(--color-ink)]">
                    {claimText(assertion.claim)}
                  </p>
                ) : (
                  <pre className="mt-1.5 overflow-x-auto rounded-md bg-[color:var(--color-surface-2)] p-3 font-mono text-[11px]">
                    {JSON.stringify(assertion.claim, null, 2)}
                  </pre>
                )}
              </div>

              <details className="mt-3">
                <summary className="cursor-pointer text-xs uppercase tracking-wider text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-ink)]">
                  Technical assertion data
                </summary>
                <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3 text-sm">
                  {assertionTechnicalFacts(assertion).map((item) => (
                    <div key={item.label} className="min-w-0">
                      <dt className="field-label">{item.label}</dt>
                      <dd className="mt-1 break-words text-[color:var(--color-ink)]">
                        {item.value}
                      </dd>
                    </div>
                  ))}
                </dl>
              </details>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function describeAssertion(type: string): {
  title: string;
  category: string;
  description: string;
} {
  const defs: Record<string, { title: string; category: string; description: string }> = {
    purpose: {
      title: "Purpose",
      category: "Scope rule",
      description:
        "Explains why this node exists and what kind of information should be accumulated here.",
    },
    relevance_rule: {
      title: "Relevance rule",
      category: "Classification rule",
      description:
        "Guides whether incoming source material belongs in this context and what facts should be kept.",
    },
    edge_policy: {
      title: "Connection rule",
      category: "Graph rule",
      description:
        "Defines when Rye should create relationships between this context and people, organizations, tasks, workstreams, or other records.",
    },
    task_policy: {
      title: "Task policy",
      category: "Task rule",
      description:
        "Defines when source material should produce task records or follow-up work.",
    },
    source_purpose: {
      title: "Source purpose",
      category: "Source rule",
      description:
        "Explains why a source account or container is being collected and what it should be used for.",
    },
    routing_hint: {
      title: "Routing hint",
      category: "Classifier hint",
      description:
        "A keyword or signal that helps route source material into the right review context.",
    },
    default_review_context: {
      title: "Default review context",
      category: "Source routing",
      description:
        "A confirmed default context for source material from a source account or container.",
    },
    source_context_confirmation: {
      title: "Source context confirmation",
      category: "Validation",
      description:
        "Records whether a source account or container's business context has been confirmed.",
    },
    observation: {
      title: "Observation",
      category: "Fact",
      description:
        "A recorded fact-like claim from source material. It may support later decisions or connections.",
    },
    status: {
      title: "Status",
      category: "Current state",
      description:
        "A single-valued current-state claim. Later status assertions may replace earlier ones.",
    },
    decision: {
      title: "Decision",
      category: "Decision",
      description:
        "A decision recorded from source material or user input.",
    },
    obligation: {
      title: "Obligation",
      category: "Duty",
      description:
        "A required action, deadline, or responsibility recorded from source material.",
    },
    risk: {
      title: "Risk",
      category: "Risk",
      description:
        "A potential issue, conflict, exposure, or uncertainty that should remain visible.",
    },
    task_status: {
      title: "Task status",
      category: "Task state",
      description:
        "The current state of a task, such as open, blocked, assigned, or complete.",
    },
  };
  return (
    defs[type] ?? {
      title: titleCase(humanizeKey(type)),
      category: "Assertion",
      description:
        "A stored claim or rule about this node. Technical details show the raw assertion type.",
    }
  );
}

function assertionStatus(assertion: AssertionRow): { label: string; description: string } {
  if (assertion.superseded_at) {
    return {
      label: "Replaced",
      description:
        "A newer assertion superseded this one. It remains visible so the change history can be audited.",
    };
  }
  return {
    label: "Current",
    description:
      "This assertion has not been superseded. Rye treats it as the current stored claim or rule for this node.",
  };
}

function assertionTechnicalFacts(assertion: AssertionRow): DisplayFact[] {
  return [
    fact("Assertion type", assertion.assertion_type),
    fact("Assertion key", assertion.assertion_key),
    fact("Status", assertion.superseded_at ? "Replaced" : "Current"),
    fact("Created", fmtDate(assertion.created_at)),
    fact("Effective at", assertion.effective_at ? fmtDate(assertion.effective_at) : null),
    fact("Effective to", assertion.effective_to ? fmtDate(assertion.effective_to) : null),
    fact("Confidence", assertion.confidence === null ? null : String(assertion.confidence)),
    fact("Source event", assertion.source_event_id),
    fact("Superseded at", assertion.superseded_at ? fmtDate(assertion.superseded_at) : null),
  ].filter((item): item is DisplayFact => Boolean(item));
}

function ConnectionGroups({
  edgesOut,
  edgesIn,
}: {
  edgesOut: EdgeNeighbor[];
  edgesIn: EdgeNeighbor[];
}) {
  const all = [
    ...edgesOut.map((edge) => ({ ...edge, direction: "outgoing" as const })),
    ...edgesIn.map((edge) => ({ ...edge, direction: "incoming" as const })),
  ];
  const groups: Array<{
    category: EdgeCategory;
    title: string;
    description: string;
    edges: Array<EdgeNeighbor & { direction: "incoming" | "outgoing" }>;
  }> = [
    {
      category: "provenance",
      title: "Source and provenance",
      description:
        "Where collected material came from. These edges cite containment or evidence flow; they are not business relationships.",
      edges: all.filter((edge) => edgeCategory(edge) === "provenance"),
    },
    {
      category: "classification",
      title: "Classification proposals",
      description:
        "Classifier routes such as source item reviewed under a context. These guide review, but are not accepted facts or responsibilities.",
      edges: all.filter((edge) => edgeCategory(edge) === "classification"),
    },
    {
      category: "knowledge",
      title: "Accepted knowledge connections",
      description:
        "Durable graph relationships between semantic nodes. These are the links agents should treat as accepted interconnected knowledge.",
      edges: all.filter((edge) => edgeCategory(edge) === "knowledge"),
    },
  ];

  return (
    <section className="grid grid-cols-1 gap-4">
      <div className="card">
        <div className="mb-2 flex flex-wrap items-center gap-2 text-sm">
          <GitBranch size={14} /> Edge types
          <EdgeCategoryChips summary={summarizeEdgeCategories(all)} />
        </div>
        <p className="text-sm leading-5 text-[color:var(--color-ink-muted)]">
          Rye stores several kinds of edges. Source/provenance and proposed
          classification routes are useful for review, but they should not be
          confused with accepted knowledge-graph relationships.
        </p>
      </div>
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-3">
        {groups.map((group) => (
          <EdgeGroupCard key={group.category} {...group} />
        ))}
      </div>
    </section>
  );
}

function EdgeGroupCard({
  title,
  description,
  edges,
}: {
  category: EdgeCategory;
  title: string;
  description: string;
  edges: Array<EdgeNeighbor & { direction: "incoming" | "outgoing" }>;
}) {
  return (
    <div className="card min-w-0">
      <div className="mb-2 flex items-center justify-between gap-2">
        <div className="text-sm font-medium text-[color:var(--color-ink)]">{title}</div>
        <span className="chip">{edges.length}</span>
      </div>
      <p className="mb-3 text-xs leading-5 text-[color:var(--color-ink-muted)]">{description}</p>
      {edges.length === 0 ? (
        <div className="text-xs text-[color:var(--color-ink-dim)]">None.</div>
      ) : (
        <ul className="flex max-h-[520px] flex-col divide-y divide-[color:var(--color-line-soft)] overflow-y-auto pr-1 scrollbar">
          {edges.slice(0, 40).map((edge) => (
            <li key={`${edge.direction}:${edge.id}`} className="py-2 text-sm">
              <div className="flex min-w-0 items-center gap-2">
                <span
                  className="size-2 shrink-0 rounded-full"
                  style={{ background: colorForType(edge.node_type) }}
                />
                <span className="pill shrink-0 font-mono">{humanizeKey(edge.edge_type)}</span>
              </div>
              <Link
                to={`/nodes/${edge.direction === "outgoing" ? edge.target_id : edge.source_id}`}
                className="mt-1 block truncate hover:text-[color:var(--color-rye)]"
                title={edge.label}
              >
                {edge.label}
              </Link>
              <div className="mt-1 text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                {edge.direction}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function EdgeCategoryChips({ summary }: { summary: EdgeCategorySummary }) {
  return (
    <span className="inline-flex flex-wrap gap-1">
      <span className="chip">{summary.provenance} provenance</span>
      <span className="chip">{summary.classification} proposals</span>
      <span className="chip">{summary.knowledge} accepted</span>
    </span>
  );
}

function EventList({ items }: { items: EventRow[] }) {
  return (
    <div className="card">
      <div className="mb-2 flex items-center gap-2 text-sm">
        <History size={14} /> Activity
        <span className="chip">{items.length}</span>
      </div>
      <p className="mb-4 text-sm leading-5 text-[color:var(--color-ink-muted)]">
        Activity is Rye's immutable audit trail for this record. These entries
        show what was observed or changed, who or what process did it, and why
        the record exists; they are not always business facts.
      </p>
      {items.length === 0 ? (
        <div className="text-xs text-[color:var(--color-ink-dim)]">No events.</div>
      ) : (
        <ul className="flex flex-col divide-y divide-[color:var(--color-line-soft)]">
          {items.slice(0, 20).map((event) => {
            const display = describeEvent(event);
            const subject = eventSubject(event);
            const facts = eventTechnicalFacts(event);
            return (
              <li key={event.id} className="py-4">
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="text-sm font-medium text-[color:var(--color-ink)]">
                        {display.title}
                      </span>
                      <span className="chip">{display.category}</span>
                      {event.role ? (
                        <span className="pill">{humanizeKey(event.role)}</span>
                      ) : null}
                    </div>
                    <p className="mt-1 text-sm leading-5 text-[color:var(--color-ink-muted)]">
                      {display.description}
                    </p>
                  </div>
                  <span className="shrink-0 text-xs text-[color:var(--color-ink-muted)]">
                    {fmtRel(event.occurred_at)}
                  </span>
                </div>

                {subject ? (
                  <div className="mt-3 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2 text-sm text-[color:var(--color-ink)]">
                    {subject}
                  </div>
                ) : null}

                <details className="mt-3">
                  <summary className="cursor-pointer text-xs uppercase tracking-wider text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-ink)]">
                    Technical event data
                  </summary>
                  <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3 text-sm">
                    {facts.map((factItem) => (
                      <div key={factItem.label} className="min-w-0">
                        <dt className="field-label">{factItem.label}</dt>
                        <dd className="mt-1 break-words text-[color:var(--color-ink)]">
                          {factItem.value}
                        </dd>
                      </div>
                    ))}
                  </dl>
                </details>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

function describeEvent(event: EventRow): {
  title: string;
  category: string;
  description: string;
} {
  const props = asRecord(event.properties);
  if (event.event_type === "source_context_record_observed") {
    const recordKind = firstString(props.record_kind, event.role, "source record") ?? "source record";
    return {
      title: `${titleCase(humanizeKey(recordKind))} observed`,
      category: "Provenance",
      description:
        "Rye recorded this item during source-context intake. Use it to trace where collected data came from and whether the source context still needs confirmation; it is not a business fact by itself.",
    };
  }
  if (event.event_type === "extraction") {
    return {
      title: "Extraction run",
      category: "Processing",
      description:
        "A processing step extracted or updated Rye records from source material.",
    };
  }
  if (event.event_type === "quote_created") {
    return {
      title: "Quote created",
      category: "Business event",
      description:
        "A domain event was recorded in Rye and can be used as evidence for related facts or workflow state.",
    };
  }
  return {
    title: titleCase(humanizeKey(event.event_type)),
    category: "Activity",
    description:
      "Rye logged this event in its append-only activity history. The technical event type is retained for filtering and audit.",
  };
}

function eventSubject(event: EventRow): string | null {
  if (!event.summary) return null;
  if (event.event_type === "source_context_record_observed") {
    const parts = event.summary.split(":");
    const subject = parts.length > 1 ? parts.slice(1).join(":").trim() : event.summary;
    return subject ? `Observed record: ${subject}` : event.summary;
  }
  return event.summary;
}

function eventTechnicalFacts(event: EventRow): DisplayFact[] {
  const props = asRecord(event.properties);
  return [
    fact("Event type", event.event_type),
    fact("Actor", event.actor_system),
    fact("Role", event.role ? humanizeKey(event.role) : null),
    fact("Occurred", fmtDate(event.occurred_at)),
    fact("Contract", firstString(props.contract)),
    fact("Record kind", firstString(props.record_kind) ? humanizeKey(String(props.record_kind)) : null),
    fact("Source context id", firstString(props.source_context_id)),
  ].filter((item): item is DisplayFact => Boolean(item));
}

function titleCase(value: string): string {
  return value
    .split(" ")
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}
