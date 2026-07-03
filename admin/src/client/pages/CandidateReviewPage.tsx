import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  CheckCircle2,
  ClipboardCheck,
  Clock3,
  Copy,
  Inbox,
  Search,
  ShieldCheck,
  XCircle,
} from "lucide-react";
import {
  acceptCrmStagePlanCandidate,
  acceptPmMilestonePlanCandidate,
  acceptPmTaskPlanCandidate,
  acceptSourcePolicyCandidate,
  promoteKnowledgeCandidate,
  setKnowledgeCandidateStatus,
  useCandidateReviewQueue,
  useNodeSearch,
  type AcceptCrmStagePlanCandidateInput,
  type AcceptPmMilestonePlanCandidateInput,
  type AcceptPmTaskPlanCandidateInput,
  type AcceptSourcePolicyCandidateInput,
  type CandidateReviewRow,
  type KnowledgeCandidateKind,
  type KnowledgeCandidateStatus,
  type PromoteKnowledgeCandidateInput,
} from "../lib/api";
import { shortId, fmtDate, fmtNumber } from "../lib/format";
import { useInstance } from "../lib/instance";

const STATUS_OPTIONS = ["all", "proposed", "needs_review", "accepted", "rejected", "duplicate", "superseded"];
const KIND_OPTIONS = ["all", "fact", "task", "edge", "decision", "procedure", "preference", "risk"];

type TargetType = PromoteKnowledgeCandidateInput["target_type"];

type GuidedAcceptPayload =
  | { mode: "source_policy"; payload: AcceptSourcePolicyCandidateInput }
  | { mode: "crm_stage_plan"; payload: AcceptCrmStagePlanCandidateInput }
  | { mode: "pm_task_plan"; payload: AcceptPmTaskPlanCandidateInput }
  | { mode: "pm_milestone_plan"; payload: AcceptPmMilestonePlanCandidateInput };

type GuidedAcceptResult = {
  target_type: string;
  id?: string;
  ids?: string[];
  subject_node_id: string;
};

export function CandidateReviewPage() {
  const { current } = useInstance();
  const queryClient = useQueryClient();
  const [status, setStatus] = useState("all");
  const [kind, setKind] = useState("all");
  const [search, setSearch] = useState("");
  const [includeClosed, setIncludeClosed] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const queue = useCandidateReviewQueue({ status, kind, q: search, includeClosed, limit: 120 });
  const candidates = queue.data?.candidates ?? [];
  const selected = candidates.find((candidate) => candidate.id === selectedId) ?? candidates[0] ?? null;

  useEffect(() => {
    if (!selectedId && candidates[0]) setSelectedId(candidates[0].id);
    if (selectedId && candidates.length > 0 && !candidates.some((candidate) => candidate.id === selectedId)) {
      setSelectedId(candidates[0].id);
    }
  }, [candidates, selectedId]);

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: ["candidate-review", current] });

  const statusMutation = useMutation({
    mutationFn: (input: { id: string; status: KnowledgeCandidateStatus; reason: string }) =>
      setKnowledgeCandidateStatus(current, input.id, {
        status: input.status,
        reason: input.reason,
        actor: "candidate-review-ui",
      }),
    onSuccess: invalidate,
  });

  const promoteMutation = useMutation({
    mutationFn: (input: { id: string; payload: PromoteKnowledgeCandidateInput }) =>
      promoteKnowledgeCandidate(current, input.id, input.payload),
    onSuccess: invalidate,
  });

  const guidedAcceptMutation = useMutation<
    GuidedAcceptResult,
    Error,
    { id: string; payload: GuidedAcceptPayload }
  >({
    mutationFn: async (input): Promise<GuidedAcceptResult> => {
      const { payload } = input;
      if (payload.mode === "source_policy") {
        return acceptSourcePolicyCandidate(current, input.id, payload.payload);
      }
      if (payload.mode === "crm_stage_plan") {
        return acceptCrmStagePlanCandidate(current, input.id, payload.payload);
      }
      if (payload.mode === "pm_task_plan") {
        return acceptPmTaskPlanCandidate(current, input.id, payload.payload);
      }
      return acceptPmMilestonePlanCandidate(current, input.id, payload.payload);
    },
    onSuccess: invalidate,
  });

  return (
    <div className="flex min-h-0 flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="mb-2 flex items-center gap-2 text-[10px] uppercase tracking-[0.22em] text-[color:var(--color-ink-dim)]">
            <ClipboardCheck size={13} /> Decision queue
          </div>
          <h1 className="text-2xl font-semibold tracking-tight">Suggested Updates</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-[color:var(--color-ink-muted)]">
            Confirm, edit, reject, or ask for better proof before a source-based
            suggestion becomes accepted business knowledge.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Metric label="Open" value={queue.data?.stats.open ?? 0} />
          <Metric label="Accepted" value={queue.data?.stats.accepted ?? 0} />
          <Metric label="Rejected" value={queue.data?.stats.rejected ?? 0} />
          <Metric label="Total" value={queue.data?.stats.total ?? 0} />
        </div>
      </header>

      <section className="rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-4">
        <div className="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(240px,1fr)_180px_180px_auto]">
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Search</span>
            <span className="relative">
              <Search
                size={14}
                className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[color:var(--color-ink-dim)]"
              />
              <input
                className="input w-full pl-9 text-sm"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Statement, source id, target payload"
              />
            </span>
          </label>
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Status</span>
            <select className="input text-sm" value={status} onChange={(event) => setStatus(event.target.value)}>
              {STATUS_OPTIONS.map((value) => (
                <option key={value} value={value}>
                  {value === "all" ? "Open statuses" : humanizeKey(value)}
                </option>
              ))}
            </select>
          </label>
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Kind</span>
            <select className="input text-sm" value={kind} onChange={(event) => setKind(event.target.value)}>
              {KIND_OPTIONS.map((value) => (
                <option key={value} value={value}>
                  {value === "all" ? "All kinds" : humanizeKey(value)}
                </option>
              ))}
            </select>
          </label>
          <label className="flex items-end gap-2 text-xs text-[color:var(--color-ink-muted)]">
            <input
              type="checkbox"
              checked={includeClosed}
              onChange={(event) => setIncludeClosed(event.target.checked)}
            />
            Include closed
          </label>
        </div>
      </section>

      {queue.error ? <ErrorLine error={queue.error} /> : null}
      {statusMutation.error ? <ErrorLine error={statusMutation.error} /> : null}
      {promoteMutation.error ? <ErrorLine error={promoteMutation.error} /> : null}
      {guidedAcceptMutation.error ? <ErrorLine error={guidedAcceptMutation.error} /> : null}

      <section className="grid grid-cols-1 items-start gap-4 xl:grid-cols-[420px_minmax(0,1fr)]">
        <CandidateQueue
          loading={queue.isLoading}
          rows={candidates}
          selectedId={selected?.id ?? null}
          onSelect={setSelectedId}
        />
        <ReviewWorkspace
          candidate={selected}
          promoting={promoteMutation.isPending}
          guidedAccepting={guidedAcceptMutation.isPending}
          settingStatus={statusMutation.isPending}
          onPromote={(candidateId, payload) => promoteMutation.mutate({ id: candidateId, payload })}
          onGuidedAccept={(candidateId, payload) =>
            guidedAcceptMutation.mutate({ id: candidateId, payload })
          }
          onSetStatus={(candidateId, nextStatus, reason) =>
            statusMutation.mutate({ id: candidateId, status: nextStatus, reason })
          }
        />
      </section>
    </div>
  );
}

function CandidateQueue({
  rows,
  selectedId,
  loading,
  onSelect,
}: {
  rows: CandidateReviewRow[];
  selectedId: string | null;
  loading: boolean;
  onSelect: (id: string) => void;
}) {
  return (
    <section className="card min-h-0 self-start">
      <div className="mb-3 flex items-center justify-between gap-3">
        <div>
          <h2 className="flex items-center gap-2 text-sm font-medium">
            <Inbox size={14} /> Suggestions
          </h2>
          <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
            Pick a suggested update to review. Closed items stay hidden unless included.
          </p>
        </div>
        <span className="chip">{fmtNumber(rows.length)}</span>
      </div>
      {loading && rows.length === 0 ? <LoadingLine /> : null}
      {!loading && rows.length === 0 ? <EmptyLine>No candidates match these filters.</EmptyLine> : null}
      <ul className="flex max-h-[520px] flex-col gap-2 overflow-y-auto pr-1 scrollbar">
        {rows.map((candidate) => (
          <li key={candidate.id}>
            <button
              type="button"
              onClick={() => onSelect(candidate.id)}
              className={[
                "w-full rounded-md border p-3 text-left transition",
                selectedId === candidate.id
                  ? "border-[color:var(--color-rye)] bg-[color:var(--color-surface-2)]"
                  : "border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)]/60 hover:border-[color:var(--color-rye)]",
              ].join(" ")}
            >
              <div className="mb-2 flex flex-wrap items-center gap-1.5">
                <span className="pill">{humanizeKey(candidateKind(candidate))}</span>
                <CandidateStatusPill status={candidate.status} />
                {typeof candidate.properties.confidence === "number" ? (
                  <span className="chip">{candidate.properties.confidence}</span>
                ) : null}
              </div>
              <p className="line-clamp-3 text-sm leading-5 text-[color:var(--color-ink)]">
                {candidateStatement(candidate)}
              </p>
              <div className="mt-2 flex items-center justify-between gap-2 text-[11px] text-[color:var(--color-ink-dim)]">
                <span>{fmtDate(candidate.created_at)}</span>
                <span>{candidate.supporting_sources.length} sources</span>
              </div>
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function ReviewWorkspace({
  candidate,
  promoting,
  guidedAccepting,
  settingStatus,
  onPromote,
  onGuidedAccept,
  onSetStatus,
}: {
  candidate: CandidateReviewRow | null;
  promoting: boolean;
  guidedAccepting: boolean;
  settingStatus: boolean;
  onPromote: (candidateId: string, payload: PromoteKnowledgeCandidateInput) => void;
  onGuidedAccept: (candidateId: string, payload: GuidedAcceptPayload) => void;
  onSetStatus: (candidateId: string, status: KnowledgeCandidateStatus, reason: string) => void;
}) {
  const [reason, setReason] = useState("");
  if (!candidate) {
    return (
      <section className="card flex items-center justify-center text-sm text-[color:var(--color-ink-muted)]">
        Select a suggested update to review.
      </section>
    );
  }

  return (
    <section className="grid min-h-0 grid-cols-1 items-start gap-4 xl:grid-cols-[minmax(0,0.9fr)_minmax(420px,1.1fr)]">
      <div className="flex min-w-0 flex-col gap-4">
        <CandidateEvidencePanel candidate={candidate} />
        <section className="card">
          <h2 className="mb-2 flex items-center gap-2 text-sm font-medium">
            <XCircle size={14} /> Do Not Accept Yet
          </h2>
          <p className="mb-3 text-xs leading-5 text-[color:var(--color-ink-muted)]">
            Use these when the suggestion is wrong, already covered, or needs stronger proof.
          </p>
          <textarea
            className="input min-h-20 w-full text-sm"
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder="Reviewer reason"
          />
          <div className="mt-3 flex flex-wrap gap-2">
            <button
              type="button"
              className="btn h-9 text-xs"
              disabled={settingStatus}
              onClick={() =>
                onSetStatus(candidate.id, "needs_review", reason || "Needs more evidence from candidate review UI")
              }
            >
              <Clock3 size={13} /> Needs proof
            </button>
            <button
              type="button"
              className="btn h-9 text-xs"
              disabled={settingStatus}
              onClick={() => onSetStatus(candidate.id, "duplicate", reason || "Marked duplicate in candidate review UI")}
            >
              <Copy size={13} /> Duplicate
            </button>
            <button
              type="button"
              className="btn h-9 text-xs"
              disabled={settingStatus}
              onClick={() => onSetStatus(candidate.id, "rejected", reason || "Rejected in candidate review UI")}
            >
              <XCircle size={13} /> Reject
            </button>
          </div>
        </section>
      </div>
      <PromotionEditor
        key={candidate.id}
        candidate={candidate}
        promoting={promoting}
        guidedAccepting={guidedAccepting}
        onPromote={onPromote}
        onGuidedAccept={onGuidedAccept}
      />
    </section>
  );
}

function CandidateEvidencePanel({ candidate }: { candidate: CandidateReviewRow }) {
  const targetPayload = asRecord(candidate.properties.target_payload);
  return (
    <section className="card max-h-[520px] min-w-0 overflow-y-auto scrollbar">
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <span className="chip">{humanizeKey(candidateKind(candidate))}</span>
        <CandidateStatusPill status={candidate.status} />
        <span className="chip">suggestion {shortId(candidate.id)}</span>
      </div>
      <h2 className="text-sm font-medium">Suggested Change</h2>
      <p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-[color:var(--color-ink)]">
        {candidateStatement(candidate)}
      </p>

      <div className="mt-4 grid grid-cols-1 gap-3 lg:grid-cols-2">
        <InfoGroup title="Review Contexts">
          {candidate.review_contexts.length === 0 ? (
            <EmptyInline>No review scope attached.</EmptyInline>
          ) : (
            candidate.review_contexts.map((ctx) => (
              <Link key={ctx.id} to={`/nodes/${ctx.id}`} className="pill hover:text-[color:var(--color-rye)]">
                {ctx.label ?? shortId(ctx.id)}
              </Link>
            ))
          )}
        </InfoGroup>
        <InfoGroup title="Evidence Sources">
          {candidate.supporting_sources.length === 0 ? (
            <EmptyInline>No source links attached.</EmptyInline>
          ) : (
            candidate.supporting_sources.map((source) => (
              <Link key={`${source.edge_type}:${source.id}`} to={`/nodes/${source.id}`} className="pill hover:text-[color:var(--color-rye)]">
                {source.label ?? shortId(source.id)}
              </Link>
            ))
          )}
        </InfoGroup>
      </div>

      <details className="mt-4 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
        <summary className="cursor-pointer text-xs font-medium text-[color:var(--color-ink-muted)]">
          Technical details
        </summary>
        <pre className="mt-3 max-h-60 overflow-auto whitespace-pre-wrap rounded-md bg-[color:var(--color-canvas)] p-3 text-[11px] leading-5 text-[color:var(--color-ink-muted)] scrollbar">
          {formatJson(targetPayload)}
        </pre>
      </details>

      {candidate.promoted_targets.length > 0 ? (
        <div className="mt-4">
          <div className="field-label mb-2">Promoted Targets</div>
          <div className="flex flex-wrap gap-2">
            {candidate.promoted_targets.map((target) => (
              <Link key={target.id} to={`/nodes/${target.id}`} className="pill border-emerald-400/30 text-emerald-300 hover:text-emerald-100">
                {target.label ?? shortId(target.id)}
              </Link>
            ))}
          </div>
        </div>
      ) : null}
    </section>
  );
}

function PromotionEditor({
  candidate,
  promoting,
  guidedAccepting,
  onPromote,
  onGuidedAccept,
}: {
  candidate: CandidateReviewRow;
  promoting: boolean;
  guidedAccepting: boolean;
  onPromote: (candidateId: string, payload: PromoteKnowledgeCandidateInput) => void;
  onGuidedAccept: (candidateId: string, payload: GuidedAcceptPayload) => void;
}) {
  const initial = useMemo(() => initialPromotionDraft(candidate), [candidate]);
  const [targetType, setTargetType] = useState<TargetType>(initial.targetType);
  const [subjectNodeId, setSubjectNodeId] = useState(initial.subjectNodeId);
  const [subjectSearch, setSubjectSearch] = useState("");
  const [assertionType, setAssertionType] = useState(initial.assertionType);
  const [assertionKey, setAssertionKey] = useState(initial.assertionKey);
  const [claimText, setClaimText] = useState(initial.claimText);
  const [effectiveAt, setEffectiveAt] = useState(initial.effectiveAt);
  const [effectiveTo, setEffectiveTo] = useState(initial.effectiveTo);
  const [confidence, setConfidence] = useState(initial.confidence);
  const [taskLabel, setTaskLabel] = useState(initial.taskLabel);
  const [taskPropertiesText, setTaskPropertiesText] = useState(initial.taskPropertiesText);
  const [edgeSourceId, setEdgeSourceId] = useState(initial.edgeSourceId);
  const [edgeTargetId, setEdgeTargetId] = useState(initial.edgeTargetId);
  const [edgeType, setEdgeType] = useState(initial.edgeType);
  const [edgePropertiesText, setEdgePropertiesText] = useState(initial.edgePropertiesText);
  const subjectResults = useNodeSearch(subjectSearch, null, 8);
  const claimError = jsonError(claimText);
  const taskPropsError = jsonError(taskPropertiesText);
  const edgePropsError = jsonError(edgePropertiesText);

  const acceptDisabled =
    promoting ||
    (targetType === "assertion" && (!subjectNodeId || !assertionType || Boolean(claimError))) ||
    (targetType === "task" && (!taskLabel || Boolean(taskPropsError))) ||
    (targetType === "edge" && (!edgeSourceId || !edgeTargetId || !edgeType || Boolean(edgePropsError)));

  function submit() {
    if (targetType === "assertion") {
      const parsedClaim = parseJsonRecord(claimText);
      if (!parsedClaim) return;
      const parsedConfidence = confidence.trim() ? Number(confidence) : null;
      onPromote(candidate.id, {
        target_type: "assertion",
        subject_node_id: subjectNodeId,
        assertion_type: assertionType,
        assertion_key: assertionKey || "default",
        claim: parsedClaim,
        effective_at: effectiveAt || null,
        effective_to: effectiveTo || null,
        confidence: Number.isFinite(parsedConfidence) ? parsedConfidence : null,
        actor: "candidate-review-ui",
      });
      return;
    }

    if (targetType === "task") {
      onPromote(candidate.id, {
        target_type: "task",
        label: taskLabel,
        properties: parseJsonRecord(taskPropertiesText) ?? {},
        actor: "candidate-review-ui",
      });
      return;
    }

    onPromote(candidate.id, {
      target_type: "edge",
      source_id: edgeSourceId,
      target_id: edgeTargetId,
      edge_type: edgeType,
      properties: parseJsonRecord(edgePropertiesText) ?? {},
      effective_from: effectiveAt || null,
      effective_to: effectiveTo || null,
      actor: "candidate-review-ui",
    });
  }

  return (
    <section className="card max-h-[720px] min-w-0 overflow-y-auto scrollbar">
      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="flex items-center gap-2 text-sm font-medium">
            <ShieldCheck size={14} /> Accept As Business Truth
          </h2>
          <p className="mt-1 max-w-2xl text-xs leading-5 text-[color:var(--color-ink-muted)]">
            Review the accepted target before saving it. The system will keep the
            source links and reviewer history with the accepted knowledge.
          </p>
        </div>
      </div>

      <GuidedAcceptPanel
        candidate={candidate}
        accepting={guidedAccepting}
        onAccept={(payload) => onGuidedAccept(candidate.id, payload)}
      />

      <details className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
        <summary className="cursor-pointer text-xs font-medium text-[color:var(--color-ink-muted)]">
          Advanced technical acceptance editor
        </summary>
        <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
          <p className="max-w-xl text-xs leading-5 text-[color:var(--color-ink-muted)]">
            Use this only when no guided business form fits the suggested update.
          </p>
          <div className="flex rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-1">
            {(["assertion", "task", "edge"] as TargetType[]).map((type) => (
              <button
                key={type}
                type="button"
                className={[
                  "rounded px-3 py-1.5 text-xs",
                  targetType === type
                    ? "bg-[color:var(--color-rye)] text-black"
                    : "text-[color:var(--color-ink-muted)] hover:text-white",
                ].join(" ")}
                onClick={() => setTargetType(type)}
              >
                {humanizeKey(type)}
              </button>
            ))}
          </div>
        </div>

      {targetType === "assertion" ? (
        <div className="mt-4 flex flex-col gap-3">
          <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Subject node id</span>
              <input className="input text-sm" value={subjectNodeId} onChange={(event) => setSubjectNodeId(event.target.value)} />
            </label>
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Find subject</span>
              <input className="input text-sm" value={subjectSearch} onChange={(event) => setSubjectSearch(event.target.value)} placeholder="Search nodes" />
            </label>
          </div>
          {subjectSearch ? (
            <div className="flex max-h-32 flex-wrap gap-2 overflow-y-auto rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-2 scrollbar">
              {(subjectResults.data?.rows ?? []).map((node) => (
                <button
                  type="button"
                  key={node.id}
                  className="pill hover:text-[color:var(--color-rye)]"
                  onClick={() => setSubjectNodeId(node.id)}
                >
                  {node.label} <span className="text-[color:var(--color-ink-dim)]">{node.node_type}</span>
                </button>
              ))}
            </div>
          ) : null}
          <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Assertion type</span>
              <input className="input text-sm" value={assertionType} onChange={(event) => setAssertionType(event.target.value)} />
            </label>
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Assertion key</span>
              <input className="input text-sm" value={assertionKey} onChange={(event) => setAssertionKey(event.target.value)} />
            </label>
          </div>
          <div className="grid grid-cols-1 gap-3 xl:grid-cols-3">
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Effective at</span>
              <input className="input text-sm" value={effectiveAt} onChange={(event) => setEffectiveAt(event.target.value)} placeholder="YYYY-MM-DD or timestamp" />
            </label>
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Effective to</span>
              <input className="input text-sm" value={effectiveTo} onChange={(event) => setEffectiveTo(event.target.value)} placeholder="optional" />
            </label>
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Confidence</span>
              <input className="input text-sm" value={confidence} onChange={(event) => setConfidence(event.target.value)} placeholder="0-1" />
            </label>
          </div>
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Claim JSON</span>
            <textarea
              className="input min-h-64 w-full font-mono text-xs leading-5"
              value={claimText}
              onChange={(event) => setClaimText(event.target.value)}
            />
          </label>
          {claimError ? <ErrorLine error={claimError} /> : null}
        </div>
      ) : null}

      {targetType === "task" ? (
        <div className="mt-4 flex flex-col gap-3">
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Task label</span>
            <input className="input text-sm" value={taskLabel} onChange={(event) => setTaskLabel(event.target.value)} />
          </label>
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Task properties JSON</span>
            <textarea className="input min-h-56 w-full font-mono text-xs leading-5" value={taskPropertiesText} onChange={(event) => setTaskPropertiesText(event.target.value)} />
          </label>
          {taskPropsError ? <ErrorLine error={taskPropsError} /> : null}
        </div>
      ) : null}

      {targetType === "edge" ? (
        <div className="mt-4 flex flex-col gap-3">
          <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Source node id</span>
              <input className="input text-sm" value={edgeSourceId} onChange={(event) => setEdgeSourceId(event.target.value)} />
            </label>
            <label className="flex min-w-0 flex-col gap-1">
              <span className="field-label">Target node id</span>
              <input className="input text-sm" value={edgeTargetId} onChange={(event) => setEdgeTargetId(event.target.value)} />
            </label>
          </div>
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Edge type</span>
            <input className="input text-sm" value={edgeType} onChange={(event) => setEdgeType(event.target.value)} />
          </label>
          <label className="flex min-w-0 flex-col gap-1">
            <span className="field-label">Edge properties JSON</span>
            <textarea className="input min-h-48 w-full font-mono text-xs leading-5" value={edgePropertiesText} onChange={(event) => setEdgePropertiesText(event.target.value)} />
          </label>
          {edgePropsError ? <ErrorLine error={edgePropsError} /> : null}
        </div>
      ) : null}

      <div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-[color:var(--color-line-soft)] pt-4">
        <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
          Promotion writes an event, accepted target, evidence link, and accepted candidate status.
        </p>
        <button type="button" className="btn-primary h-10" disabled={acceptDisabled} onClick={submit}>
          <CheckCircle2 size={14} /> Accept authoritative
        </button>
      </div>
      </details>
    </section>
  );
}

type GuidedDraft =
  | {
      kind: "source_policy";
      scopeId: string;
      scopeLabel: string;
      statusDomains: string[];
      authoritativeSource: string;
      effectiveAt: string;
      reviewGate: string;
      evidenceAllowed: string[];
      supersedes: string;
      notes: string;
    }
  | {
      kind: "crm_stage_plan" | "pm_task_plan" | "pm_milestone_plan";
      nodeType: "opportunity" | "task" | "milestone";
      recordCode: string;
      valueLabel: "Stage" | "Status";
      value: string;
      effectiveAt: string;
      reason: string;
      statement: string;
    };

function GuidedAcceptPanel({
  candidate,
  accepting,
  onAccept,
}: {
  candidate: CandidateReviewRow;
  accepting: boolean;
  onAccept: (payload: GuidedAcceptPayload) => void;
}) {
  const draft = useMemo(() => detectGuidedDraft(candidate), [candidate]);

  if (!draft) {
    return (
      <div className="mb-4 rounded-md border border-dashed border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3 text-xs leading-5 text-[color:var(--color-ink-muted)]">
        No guided business form matched this suggestion. Use the advanced editor
        only if the accepted target is clear.
      </div>
    );
  }

  return draft.kind === "source_policy" ? (
    <SourcePolicyGuidedForm draft={draft} accepting={accepting} onAccept={onAccept} />
  ) : (
    <PlanGuidedForm draft={draft} accepting={accepting} onAccept={onAccept} />
  );
}

function SourcePolicyGuidedForm({
  draft,
  accepting,
  onAccept,
}: {
  draft: Extract<GuidedDraft, { kind: "source_policy" }>;
  accepting: boolean;
  onAccept: (payload: GuidedAcceptPayload) => void;
}) {
  const [scopeId, setScopeId] = useState(draft.scopeId);
  const [scopeSearch, setScopeSearch] = useState(draft.scopeLabel);
  const [statusDomainsText, setStatusDomainsText] = useState(draft.statusDomains.join(", "));
  const [authoritativeSource, setAuthoritativeSource] = useState(draft.authoritativeSource);
  const [effectiveAt, setEffectiveAt] = useState(draft.effectiveAt);
  const [reviewGate, setReviewGate] = useState(draft.reviewGate);
  const [evidenceAllowedText, setEvidenceAllowedText] = useState(draft.evidenceAllowed.join(", "));
  const [supersedes, setSupersedes] = useState(draft.supersedes);
  const [notes, setNotes] = useState(draft.notes);
  const scopeResults = useNodeSearch(scopeSearch, "onboarding_scope", 8);
  const domains = splitList(statusDomainsText);
  const disabled = accepting || !scopeId || domains.length === 0 || !authoritativeSource.trim();

  return (
    <section className="mb-4 rounded-md border border-[color:var(--color-rye)]/40 bg-[color:var(--color-surface-2)] p-3">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="flex items-center gap-2 text-sm font-medium">
            <ShieldCheck size={14} /> Guided Source Policy
          </h3>
          <p className="mt-1 text-xs leading-5 text-[color:var(--color-ink-muted)]">
            Use this when the suggestion says which source should be authoritative
            for one or more business status domains.
          </p>
        </div>
        <span className="chip">rye-source-context</span>
      </div>

      <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Scope node id</span>
          <input className="input text-sm" value={scopeId} onChange={(event) => setScopeId(event.target.value)} />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Find scope</span>
          <input className="input text-sm" value={scopeSearch} onChange={(event) => setScopeSearch(event.target.value)} placeholder="Search onboarding scopes" />
        </label>
      </div>
      {scopeSearch ? (
        <NodePickList
          rows={scopeResults.data?.rows ?? []}
          onPick={(nodeId) => setScopeId(nodeId)}
        />
      ) : null}

      <div className="mt-3 grid grid-cols-1 gap-3 xl:grid-cols-2">
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Status domains</span>
          <input className="input text-sm" value={statusDomainsText} onChange={(event) => setStatusDomainsText(event.target.value)} placeholder="deal_stage, task_status" />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Authoritative source</span>
          <input className="input text-sm" value={authoritativeSource} onChange={(event) => setAuthoritativeSource(event.target.value)} />
        </label>
      </div>

      <div className="mt-3 grid grid-cols-1 gap-3 xl:grid-cols-2">
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Policy effective date</span>
          <input className="input text-sm" value={effectiveAt} onChange={(event) => setEffectiveAt(event.target.value)} placeholder="YYYY-MM-DD or timestamp" />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Supersedes</span>
          <input className="input text-sm" value={supersedes} onChange={(event) => setSupersedes(event.target.value)} placeholder="Prior source or policy" />
        </label>
      </div>

      <div className="mt-3 grid grid-cols-1 gap-3 xl:grid-cols-2">
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Review gate</span>
          <input className="input text-sm" value={reviewGate} onChange={(event) => setReviewGate(event.target.value)} />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Evidence allowed</span>
          <input className="input text-sm" value={evidenceAllowedText} onChange={(event) => setEvidenceAllowedText(event.target.value)} placeholder="owner confirmation, reviewed source row" />
        </label>
      </div>

      <label className="mt-3 flex min-w-0 flex-col gap-1">
        <span className="field-label">Notes</span>
        <textarea className="input min-h-20 text-sm" value={notes} onChange={(event) => setNotes(event.target.value)} />
      </label>

      <div className="mt-3 flex flex-wrap items-center justify-between gap-3 border-t border-[color:var(--color-line-soft)] pt-3">
        <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
          Writes source-of-truth policy assertions through the source-context helper.
        </p>
        <button
          type="button"
          className="btn-primary h-9 text-xs"
          disabled={disabled}
          onClick={() =>
            onAccept({
              mode: "source_policy",
              payload: {
                scope_id: scopeId,
                status_domains: domains,
                authoritative_source: authoritativeSource.trim(),
                effective_at: effectiveAt.trim() || null,
                review_gate: reviewGate.trim() || null,
                evidence_allowed: splitList(evidenceAllowedText),
                supersedes: supersedes.trim() || null,
                notes: notes.trim() || null,
                actor: "candidate-review-ui-guided",
              },
            })
          }
        >
          <CheckCircle2 size={14} /> Accept source policy
        </button>
      </div>
    </section>
  );
}

function PlanGuidedForm({
  draft,
  accepting,
  onAccept,
}: {
  draft: Exclude<GuidedDraft, { kind: "source_policy" }>;
  accepting: boolean;
  onAccept: (payload: GuidedAcceptPayload) => void;
}) {
  const [targetNodeId, setTargetNodeId] = useState("");
  const [targetSearch, setTargetSearch] = useState(draft.recordCode);
  const [value, setValue] = useState(draft.value);
  const [effectiveAt, setEffectiveAt] = useState(draft.effectiveAt);
  const [reason, setReason] = useState(draft.reason);
  const [propertiesText, setPropertiesText] = useState(
    formatJson({
      candidate_statement: draft.statement,
      detected_record_code: draft.recordCode,
      accepted_from: "candidate_review_ui",
    })
  );
  const targetResults = useNodeSearch(targetSearch, draft.nodeType, 8);
  const propertiesError = jsonError(propertiesText);

  useEffect(() => {
    if (targetNodeId || !draft.recordCode || !targetResults.data?.rows.length) return;
    const exact = targetResults.data.rows.find((node) => {
      const code = firstString(node.external_id, node.properties.code);
      return code?.toLowerCase() === draft.recordCode.toLowerCase();
    });
    if (exact) setTargetNodeId(exact.id);
  }, [draft.recordCode, targetNodeId, targetResults.data?.rows]);

  const disabled =
    accepting ||
    !targetNodeId ||
    !value.trim() ||
    !effectiveAt.trim() ||
    Boolean(propertiesError);

  function submit() {
    const plan_properties = parseJsonRecord(propertiesText) ?? {};
    const common = {
      effective_at: effectiveAt.trim(),
      reason: reason.trim() || null,
      actor: "candidate-review-ui-guided",
      plan_properties,
    };

    if (draft.kind === "crm_stage_plan") {
      onAccept({
        mode: "crm_stage_plan",
        payload: {
          opportunity_id: targetNodeId,
          stage: value.trim(),
          ...common,
        },
      });
      return;
    }

    if (draft.kind === "pm_task_plan") {
      onAccept({
        mode: "pm_task_plan",
        payload: {
          task_id: targetNodeId,
          status: value.trim(),
          ...common,
        },
      });
      return;
    }

    onAccept({
      mode: "pm_milestone_plan",
      payload: {
        milestone_id: targetNodeId,
        status: value.trim(),
        ...common,
      },
    });
  }

  return (
    <section className="mb-4 rounded-md border border-[color:var(--color-rye)]/40 bg-[color:var(--color-surface-2)] p-3">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="flex items-center gap-2 text-sm font-medium">
            <Clock3 size={14} /> Guided Future Plan
          </h3>
          <p className="mt-1 text-xs leading-5 text-[color:var(--color-ink-muted)]">
            Use this when the suggestion describes a planned future CRM or PM state
            change. It remains future knowledge until its effective date.
          </p>
        </div>
        <span className="chip">
          {draft.kind === "crm_stage_plan" ? "rye-crm" : "rye-project-management"}
        </span>
      </div>

      <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Target node id</span>
          <input className="input text-sm" value={targetNodeId} onChange={(event) => setTargetNodeId(event.target.value)} />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Find {draft.nodeType}</span>
          <input className="input text-sm" value={targetSearch} onChange={(event) => setTargetSearch(event.target.value)} placeholder="Code, label, or external id" />
        </label>
      </div>
      {targetSearch ? (
        <NodePickList
          rows={targetResults.data?.rows ?? []}
          onPick={(nodeId) => setTargetNodeId(nodeId)}
        />
      ) : null}

      <div className="mt-3 grid grid-cols-1 gap-3 xl:grid-cols-2">
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">{draft.valueLabel}</span>
          <input className="input text-sm" value={value} onChange={(event) => setValue(event.target.value)} />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="field-label">Effective at</span>
          <input className="input text-sm" value={effectiveAt} onChange={(event) => setEffectiveAt(event.target.value)} placeholder="YYYY-MM-DD or timestamp" />
        </label>
      </div>

      <label className="mt-3 flex min-w-0 flex-col gap-1">
        <span className="field-label">Reason</span>
        <input className="input text-sm" value={reason} onChange={(event) => setReason(event.target.value)} />
      </label>

      <details className="mt-3 rounded-md border border-[color:var(--color-line-soft)] p-3">
        <summary className="cursor-pointer text-xs font-medium text-[color:var(--color-ink-muted)]">
          Plan properties
        </summary>
        <textarea
          className="input mt-3 min-h-36 w-full font-mono text-xs leading-5"
          value={propertiesText}
          onChange={(event) => setPropertiesText(event.target.value)}
        />
      </details>
      {propertiesError ? <ErrorLine error={propertiesError} /> : null}

      <div className="mt-3 flex flex-wrap items-center justify-between gap-3 border-t border-[color:var(--color-line-soft)] pt-3">
        <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
          Calls the plugin schedule helper and links this candidate to the target.
        </p>
        <button type="button" className="btn-primary h-9 text-xs" disabled={disabled} onClick={submit}>
          <CheckCircle2 size={14} /> Accept scheduled plan
        </button>
      </div>
    </section>
  );
}

function NodePickList({
  rows,
  onPick,
}: {
  rows: { id: string; label: string; node_type: string; external_id: string | null; properties: Record<string, unknown> }[];
  onPick: (nodeId: string) => void;
}) {
  if (rows.length === 0) {
    return (
      <div className="mt-2 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-canvas)] p-2 text-xs text-[color:var(--color-ink-dim)]">
        No matching nodes found.
      </div>
    );
  }

  return (
    <div className="mt-2 flex max-h-32 flex-wrap gap-2 overflow-y-auto rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-canvas)] p-2 scrollbar">
      {rows.map((node) => (
        <button
          type="button"
          key={node.id}
          className="pill hover:text-[color:var(--color-rye)]"
          onClick={() => onPick(node.id)}
        >
          {node.label}
          <span className="text-[color:var(--color-ink-dim)]">
            {node.external_id ? ` ${node.external_id}` : ` ${node.node_type}`}
          </span>
        </button>
      ))}
    </div>
  );
}

function initialPromotionDraft(candidate: CandidateReviewRow) {
  const kind = candidateKind(candidate);
  const target = asRecord(candidate.properties.target_payload);
  const claim = asRecord(target.claim);
  const fallbackClaim = {
    text: candidateStatement(candidate),
    candidate_kind: kind,
    target_payload: target,
  };
  const contextSubject = candidate.review_contexts[0]?.id ?? "";
  const supportingSubject = candidate.supporting_sources[0]?.id ?? "";
  const subjectNodeId = firstString(target.subject_node_id, contextSubject, supportingSubject) ?? "";

  return {
    targetType: (kind === "task" ? "task" : kind === "edge" ? "edge" : "assertion") as TargetType,
    subjectNodeId,
    assertionType:
      firstString(target.assertion_type) ??
      (kind === "fact" ? "observation" : kind === "decision" ? "decision" : kind === "risk" ? "risk" : kind),
    assertionKey:
      firstString(target.assertion_key, candidate.properties.normalized_key) ??
      `candidate_${shortId(candidate.id)}`,
    claimText: formatJson(Object.keys(claim).length > 0 ? claim : fallbackClaim),
    effectiveAt: firstString(target.effective_at) ?? "",
    effectiveTo: firstString(target.effective_to) ?? "",
    confidence:
      typeof candidate.properties.confidence === "number" ? String(candidate.properties.confidence) : "",
    taskLabel: candidateStatement(candidate),
    taskPropertiesText: formatJson({
      status: "open",
      candidate_id: candidate.id,
      candidate_kind: kind,
    }),
    edgeSourceId: firstString(target.source_id) ?? "",
    edgeTargetId: firstString(target.target_id) ?? "",
    edgeType: firstString(target.edge_type) ?? "",
    edgePropertiesText: formatJson(asRecord(target.properties)),
  };
}

function detectGuidedDraft(candidate: CandidateReviewRow): GuidedDraft | null {
  const statement = candidateStatement(candidate);
  const lower = statement.toLowerCase();
  const identifiers = extractIdentifiers(candidate);
  const sourceDomains = extractSourceDomains(statement, identifiers);

  if (
    lower.includes("source-of-truth") ||
    lower.includes("source of truth") ||
    (/\breplace\b/i.test(statement) && sourceDomains.length > 0)
  ) {
    const context = candidate.review_contexts.find((ctx) => ctx.node_type === "onboarding_scope")
      ?? candidate.review_contexts[0];
    const date = extractIsoDate(statement, identifiers);
    const nonDomainIdentifiers = identifiers.filter(
      (id) => !isDomainIdentifier(id) && !isIsoDate(id) && !/^BW-[A-Z]+-/i.test(id)
    );
    const leadingSourceFromStatement = statement.match(/^([A-Z][A-Za-z0-9 .&-]{1,80}?)(?:\s+is\b|\s+was\b|\s+will\b|\s+has\b|\s+became\b|\s+becomes\b)/)?.[1]?.trim();
    const sourceFromStatement = statement.match(/\b([A-Z][A-Za-z0-9 .&-]{1,80}?)\s+(?:will\s+)?replace\b/)?.[1]?.trim();
    const supersedesFromStatement = statement.match(/\breplace\s+(.+?)\s+as\s+(?:the\s+)?source\b/i)?.[1]?.trim();
    return {
      kind: "source_policy",
      scopeId: context?.id ?? "",
      scopeLabel: context?.label ?? "",
      statusDomains: sourceDomains.length > 0 ? sourceDomains : ["status_domain"],
      authoritativeSource: nonDomainIdentifiers[0] ?? leadingSourceFromStatement ?? sourceFromStatement ?? "",
      effectiveAt: date ?? "",
      reviewGate: "review required before authority",
      evidenceAllowed: ["reviewed source observation", "owner confirmation"],
      supersedes: supersedesFromStatement ?? nonDomainIdentifiers[1] ?? "",
      notes: statement,
    };
  }

  const date = extractIsoDate(statement, identifiers) ?? "";
  const value = extractPlannedValue(statement, identifiers);
  const defaultReason = `Accepted from candidate ${shortId(candidate.id)}.`;

  const opportunityCode = identifiers.find((id) => /^BW-OPP-/i.test(id))
    ?? statement.match(/\b([A-Z]{2,}-OPP-\d+)\b/i)?.[1]
    ?? "";
  if (opportunityCode || (lower.includes("opportunity") && lower.includes("stage"))) {
    return {
      kind: "crm_stage_plan",
      nodeType: "opportunity",
      recordCode: opportunityCode,
      valueLabel: "Stage",
      value,
      effectiveAt: date,
      reason: defaultReason,
      statement,
    };
  }

  const taskCode = identifiers.find((id) => /^BW-TSK-/i.test(id))
    ?? statement.match(/\b([A-Z]{2,}-TSK-\d+)\b/i)?.[1]
    ?? "";
  if (taskCode || (lower.includes("task") && lower.includes("planned"))) {
    return {
      kind: "pm_task_plan",
      nodeType: "task",
      recordCode: taskCode,
      valueLabel: "Status",
      value,
      effectiveAt: date,
      reason: defaultReason,
      statement,
    };
  }

  const milestoneCode = identifiers.find((id) => /^BW-MIL-/i.test(id))
    ?? statement.match(/\b([A-Z]{2,}-MIL-\d+)\b/i)?.[1]
    ?? "";
  if (milestoneCode || (lower.includes("milestone") && lower.includes("planned"))) {
    return {
      kind: "pm_milestone_plan",
      nodeType: "milestone",
      recordCode: milestoneCode,
      valueLabel: "Status",
      value,
      effectiveAt: date,
      reason: defaultReason,
      statement,
    };
  }

  return null;
}

function extractIdentifiers(candidate: CandidateReviewRow): string[] {
  const target = asRecord(candidate.properties.target_payload);
  return asStringArray(target.identifiers);
}

function extractIsoDate(statement: string, identifiers: string[]) {
  const fromStatement = statement.match(/\b20\d{2}-\d{2}-\d{2}(?:[T ][0-9:.+-Z]*)?\b/)?.[0];
  if (fromStatement) return fromStatement;
  return identifiers.find(isIsoDate) ?? null;
}

function extractSourceDomains(statement: string, identifiers: string[]) {
  const fromIdentifiers = identifiers.filter(isDomainIdentifier);
  if (fromIdentifiers.length > 0) return fromIdentifiers;

  const sourceFor = statement.match(/\bsource\s+for\s+(.+?)(?:\s+effective\b|\s+starting\b|\s+as\s+of\b|[.;]|$)/i)?.[1];
  if (!sourceFor) return [];
  return splitList(sourceFor.replace(/\band\b/gi, ",")).filter(isDomainIdentifier);
}

function extractPlannedValue(statement: string, identifiers: string[]) {
  const match = statement.match(/\b(?:to|become)\s+([a-z][a-z0-9_ -]*?)(?:\s+(?:effective|on|by|after|because|for)\b|[.;,]|$)/i);
  if (match?.[1]) return match[1].trim().replace(/\s+/g, "_");
  return (
    identifiers.find((id) => /^[a-z][a-z0-9_]+$/.test(id) && !isDomainIdentifier(id)) ??
    identifiers.find((id) => /^[a-z][a-z0-9_]+$/.test(id)) ??
    ""
  );
}

function isIsoDate(value: string) {
  return /^20\d{2}-\d{2}-\d{2}/.test(value.trim());
}

function isDomainIdentifier(value: string) {
  return /^[a-z][a-z0-9_]*_[a-z0-9_]+$/.test(value.trim()) && !isIsoDate(value);
}

function splitList(value: string) {
  return value
    .split(/,|\n|;/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <div className="card-flat min-w-28 px-3 py-2">
      <div className="field-label">{label}</div>
      <div className="num mt-1 text-xl font-semibold">{fmtNumber(value)}</div>
    </div>
  );
}

function InfoGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="field-label mb-2">{title}</div>
      <div className="flex flex-wrap gap-2">{children}</div>
    </div>
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

function candidateKind(candidate: CandidateReviewRow): KnowledgeCandidateKind {
  const kind = candidate.properties.candidate_kind;
  return kind && KIND_OPTIONS.includes(kind)
    ? (kind as KnowledgeCandidateKind)
    : "fact";
}

function candidateStatement(candidate: CandidateReviewRow): string {
  return firstString(candidate.properties.statement, candidate.label, shortId(candidate.id)) ?? shortId(candidate.id);
}

type JsonObject = Record<string, unknown>;

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

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map(asString).filter((item): item is string => Boolean(item));
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    const text = asString(value);
    if (text) return text;
  }
  return null;
}

function formatJson(value: unknown) {
  return JSON.stringify(value ?? {}, null, 2);
}

function parseJsonRecord(value: string): JsonObject | null {
  try {
    const parsed = JSON.parse(value);
    return asRecord(parsed);
  } catch {
    return null;
  }
}

function jsonError(value: string) {
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? null
      : "JSON must be an object.";
  } catch (error) {
    return error instanceof Error ? error.message : "Invalid JSON.";
  }
}

function humanizeKey(key: string) {
  return key
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[_:.-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function LoadingLine() {
  return <div className="animate-pulse text-sm text-[color:var(--color-ink-muted)]">Loading...</div>;
}

function EmptyLine({ children }: { children: React.ReactNode }) {
  return <div className="rounded-md border border-dashed border-[color:var(--color-line)] p-4 text-sm text-[color:var(--color-ink-muted)]">{children}</div>;
}

function EmptyInline({ children }: { children: React.ReactNode }) {
  return <span className="text-xs text-[color:var(--color-ink-dim)]">{children}</span>;
}

function ErrorLine({ error }: { error: unknown }) {
  return (
    <div className="rounded-md border border-rose-400/30 bg-rose-400/10 px-3 py-2 text-sm text-rose-200">
      {String(error instanceof Error ? error.message : error)}
    </div>
  );
}
