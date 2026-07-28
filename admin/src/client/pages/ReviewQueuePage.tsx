import { useState } from "react";
import { Link } from "react-router";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  ArrowRight,
  CheckCircle2,
  ClipboardCheck,
  FileText,
  Gavel,
  Inbox,
  Link2,
  Search,
  ShieldCheck,
  Users,
  XCircle,
} from "lucide-react";
import {
  acceptAssertion,
  rejectCandidateAssertion,
  useAssertionReviewQueue,
  type AssertionEvidenceRow,
  type ReviewCandidateRow,
  type ReviewIncumbentRow,
  type ReviewQueueGroup,
} from "../lib/api";
import { BasisBadge, ConfidenceChip } from "../components/AssertionBadges";
import { StructuralCandidateReview } from "../components/StructuralCandidateReview";
import { colorForType, fmtDate, fmtNumber, shortId } from "../lib/format";
import { useInstance } from "../lib/instance";

type ReviewTab = "assertions" | "structural";

const TABS: { id: ReviewTab; label: string }[] = [
  { id: "assertions", label: "Candidate assertions" },
  { id: "structural", label: "Structural candidates" },
];

export function ReviewQueuePage() {
  const { current } = useInstance();
  const queryClient = useQueryClient();
  const [tab, setTab] = useState<ReviewTab>("assertions");
  const [assertionType, setAssertionType] = useState("all");
  const [search, setSearch] = useState("");
  const [competingOnly, setCompetingOnly] = useState(false);
  const [resolved, setResolved] = useState<Record<string, string>>({});
  const queue = useAssertionReviewQueue({
    assertionType,
    q: search,
    competingOnly,
    limit: 80,
  });
  const groups = queue.data?.groups ?? [];

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["assertion-review", current] });
    queryClient.invalidateQueries({ queryKey: ["dashboard", current] });
  };

  const acceptMutation = useMutation({
    mutationFn: (input: { id: string; groupKey: string; reason: string }) =>
      acceptAssertion(current, input.id, {
        reason: input.reason || null,
        actor: "review-queue-ui",
      }),
    onSuccess: (_result, input) => {
      // A competing group is settled the moment one candidate wins; mark it so
      // the losers read as resolved before the refetch lands.
      setResolved((prev) => ({ ...prev, [input.groupKey]: input.id }));
      invalidate();
    },
  });

  const rejectMutation = useMutation({
    mutationFn: (input: { id: string; reason: string }) =>
      rejectCandidateAssertion(current, input.id, {
        reason: input.reason,
        actor: "review-queue-ui",
      }),
    onSuccess: invalidate,
  });

  return (
    <div className="flex min-h-0 flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="mb-2 flex items-center gap-2 text-[10px] uppercase tracking-[0.22em] text-[color:var(--color-ink-dim)]">
            <ClipboardCheck size={13} /> Review queue
          </div>
          <h1 className="text-2xl font-semibold tracking-tight">Review</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-[color:var(--color-ink-muted)]">
            Every proposed claim waiting on a decision. Candidates are grouped by
            the record and question they answer; when more than one candidate
            claims the same question they compete, and accepting one settles the
            group.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Metric label="Questions" value={queue.data?.stats.tuples ?? 0} />
          <Metric label="Competing" value={queue.data?.stats.competing_tuples ?? 0} />
          <Metric label="Candidates" value={queue.data?.stats.candidates ?? 0} />
        </div>
      </header>

      <div className="flex w-fit rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-1">
        {TABS.map((entry) => (
          <button
            key={entry.id}
            type="button"
            className={[
              "rounded px-3 py-1.5 text-xs",
              tab === entry.id
                ? "bg-[color:var(--color-rye)] text-black"
                : "text-[color:var(--color-ink-muted)] hover:text-white",
            ].join(" ")}
            onClick={() => setTab(entry.id)}
          >
            {entry.label}
          </button>
        ))}
      </div>

      {tab === "structural" ? (
        <StructuralCandidateReview />
      ) : (
        <>
          <section className="rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-4">
            <div className="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(240px,1fr)_220px_auto]">
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
                    placeholder="Record, question, or claim text"
                  />
                </span>
              </label>
              <label className="flex min-w-0 flex-col gap-1">
                <span className="field-label">Question type</span>
                <select
                  className="input text-sm"
                  value={assertionType}
                  onChange={(event) => setAssertionType(event.target.value)}
                >
                  <option value="all">All types</option>
                  {(queue.data?.types ?? []).map((row) => (
                    <option key={row.assertion_type} value={row.assertion_type}>
                      {humanizeKey(row.assertion_type)} ({row.count})
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex items-end gap-2 text-xs text-[color:var(--color-ink-muted)]">
                <input
                  type="checkbox"
                  checked={competingOnly}
                  onChange={(event) => setCompetingOnly(event.target.checked)}
                />
                Competing only
              </label>
            </div>
          </section>

          {queue.error ? <ErrorLine error={queue.error} /> : null}
          {acceptMutation.error ? <ErrorLine error={acceptMutation.error} /> : null}
          {rejectMutation.error ? <ErrorLine error={rejectMutation.error} /> : null}

          {queue.isLoading && groups.length === 0 ? <LoadingLine /> : null}
          {!queue.isLoading && groups.length === 0 ? (
            <div className="card flex items-center gap-3 text-sm text-emerald-300">
              <CheckCircle2 size={16} /> Nothing waiting on review. Every question
              has a single accepted answer.
            </div>
          ) : null}

          <div className="flex flex-col gap-4">
            {groups.map((group) => (
              <ReviewGroupCard
                key={groupKey(group)}
                group={group}
                acceptedId={resolved[groupKey(group)] ?? null}
                accepting={acceptMutation.isPending}
                rejecting={rejectMutation.isPending}
                onAccept={(candidateId, reason) =>
                  acceptMutation.mutate({
                    id: candidateId,
                    groupKey: groupKey(group),
                    reason,
                  })
                }
                onReject={(candidateId, reason) =>
                  rejectMutation.mutate({ id: candidateId, reason })
                }
              />
            ))}
          </div>
        </>
      )}
    </div>
  );
}

function ReviewGroupCard({
  group,
  acceptedId,
  accepting,
  rejecting,
  onAccept,
  onReject,
}: {
  group: ReviewQueueGroup;
  acceptedId: string | null;
  accepting: boolean;
  rejecting: boolean;
  onAccept: (candidateId: string, reason: string) => void;
  onReject: (candidateId: string, reason: string) => void;
}) {
  const competing = group.candidate_count > 1;
  return (
    <section
      className={[
        "card",
        acceptedId
          ? "border-emerald-400/40"
          : competing
            ? "border-[color:var(--color-rose)]/40"
            : "",
      ].join(" ")}
    >
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <SubjectLink group={group} />
            <span className="pill text-[color:var(--color-cyan)]">
              {humanizeKey(group.assertion_type)}
            </span>
            {group.assertion_key !== "default" ? (
              <span className="chip font-mono">{group.assertion_key}</span>
            ) : null}
          </div>
          <p className="mt-2 text-xs leading-5 text-[color:var(--color-ink-muted)]">
            {competing
              ? `${group.candidate_count} candidates answer this question. Accepting one supersedes the accepted answer and leaves the others for rejection.`
              : "One candidate is waiting to become the accepted answer for this question."}
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap items-center gap-2">
          {competing ? (
            <span className="rounded-md border border-[color:var(--color-rose)]/40 bg-[color:var(--color-rose)]/10 px-2 py-1 text-[10px] uppercase tracking-wider text-[color:var(--color-rose)]">
              <Gavel size={11} className="mr-1 inline" />
              competing
            </span>
          ) : null}
          <span className="chip">{group.candidate_count} candidate{group.candidate_count === 1 ? "" : "s"}</span>
        </div>
      </div>

      {acceptedId ? (
        <div className="mb-3 flex items-center gap-2 rounded-md border border-emerald-400/30 bg-emerald-400/10 px-3 py-2 text-xs text-emerald-300">
          <CheckCircle2 size={14} /> Resolved — candidate {shortId(acceptedId)} is now
          the accepted answer.
        </div>
      ) : null}

      <IncumbentPanel incumbent={group.incumbent} />

      <div className="mt-3 grid grid-cols-1 gap-3 xl:grid-cols-2">
        {group.candidates.map((candidate) => (
          <CandidateCard
            key={candidate.id}
            candidate={candidate}
            incumbent={group.incumbent}
            resolved={Boolean(acceptedId)}
            won={acceptedId === candidate.id}
            accepting={accepting}
            rejecting={rejecting}
            onAccept={(reason) => onAccept(candidate.id, reason)}
            onReject={(reason) => onReject(candidate.id, reason)}
          />
        ))}
      </div>
    </section>
  );
}

function SubjectLink({ group }: { group: ReviewQueueGroup }) {
  const label = group.subject_label ?? group.subject_ref;
  if (!group.subject_node_id) {
    return (
      <span className="flex items-center gap-2 text-sm font-medium">
        <Link2 size={13} className="text-[color:var(--color-ink-dim)]" />
        {label}
      </span>
    );
  }
  return (
    <Link
      to={`/nodes/${group.subject_node_id}`}
      className="flex items-center gap-2 text-sm hover:text-[color:var(--color-rye)]"
    >
      <span
        className="size-2 rounded-full"
        style={{ background: colorForType(group.subject_node_type ?? "") }}
      />
      <span className="font-medium">{label}</span>
      {group.subject_node_type ? (
        <span className="text-xs text-[color:var(--color-ink-dim)]">
          {humanizeKey(group.subject_node_type)}
        </span>
      ) : null}
    </Link>
  );
}

function IncumbentPanel({ incumbent }: { incumbent: ReviewIncumbentRow | null }) {
  if (!incumbent) {
    return (
      <div className="rounded-md border border-dashed border-[color:var(--color-line)] bg-[color:var(--color-surface-2)]/60 p-3 text-xs text-[color:var(--color-ink-dim)]">
        No accepted answer yet — accepting a candidate establishes the first one.
      </div>
    );
  }
  return (
    <div className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <span className="field-label">Accepted incumbent</span>
        <BasisBadge basis={incumbent.basis} />
        <ConfidenceChip
          effective={incumbent.effective_confidence}
          stored={incumbent.confidence}
        />
        <span className="chip">{fmtDate(incumbent.asserted_at)}</span>
      </div>
      <ClaimBlock claim={incumbent.claim} />
    </div>
  );
}

function CandidateCard({
  candidate,
  incumbent,
  resolved,
  won,
  accepting,
  rejecting,
  onAccept,
  onReject,
}: {
  candidate: ReviewCandidateRow;
  incumbent: ReviewIncumbentRow | null;
  resolved: boolean;
  won: boolean;
  accepting: boolean;
  rejecting: boolean;
  onAccept: (reason: string) => void;
  onReject: (reason: string) => void;
}) {
  const [reason, setReason] = useState("");
  const diff = claimDiff(incumbent?.claim, candidate.claim);
  const blockedByBasis =
    candidate.basis === "inferred" &&
    Boolean(incumbent) &&
    incumbent?.basis !== "inferred";

  return (
    <div
      className={[
        "flex min-w-0 flex-col rounded-md border p-3",
        won
          ? "border-emerald-400/40 bg-emerald-400/5"
          : resolved
            ? "border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)]/40 opacity-60"
            : "border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)]",
      ].join(" ")}
    >
      <div className="mb-2 flex flex-wrap items-center gap-1.5">
        <BasisBadge basis={candidate.basis} />
        <ConfidenceChip
          effective={candidate.effective_confidence}
          stored={candidate.confidence}
          prior={candidate.basis_prior}
        />
        {candidate.classification ? (
          <span className="pill text-[color:var(--color-violet)]">
            {humanizeKey(candidate.classification)}
          </span>
        ) : null}
        <span className="chip font-mono">{shortId(candidate.id)}</span>
      </div>

      <ClaimBlock claim={candidate.claim} />

      <ClaimDiff diff={diff} hasIncumbent={Boolean(incumbent)} />

      <EvidenceSummary evidence={candidate.evidence} witnessCount={candidate.witness_count} />

      <div className="mt-3 flex flex-col gap-2 border-t border-[color:var(--color-line-soft)] pt-3">
        {blockedByBasis ? (
          <p className="text-[11px] leading-4 text-amber-300">
            Inferred candidates cannot displace a {humanizeKey(incumbent?.basis ?? "")}{" "}
            incumbent — accepting this will be refused.
          </p>
        ) : null}
        <input
          className="input text-xs"
          value={reason}
          onChange={(event) => setReason(event.target.value)}
          placeholder="Reason (optional to accept, required to reject)"
        />
        <div className="flex flex-wrap items-center justify-between gap-2">
          <span className="text-[11px] text-[color:var(--color-ink-dim)]">
            asserted {fmtDate(candidate.asserted_at)}
          </span>
          <div className="flex gap-2">
            <button
              type="button"
              className="btn h-8 text-xs"
              disabled={resolved || rejecting || !reason.trim()}
              title={reason.trim() ? undefined : "A rejection reason is required"}
              onClick={() => onReject(reason.trim())}
            >
              <XCircle size={13} /> Reject
            </button>
            <button
              type="button"
              className="btn-primary h-8 text-xs"
              disabled={resolved || accepting}
              onClick={() => onAccept(reason.trim())}
            >
              <ShieldCheck size={13} /> Accept
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function EvidenceSummary({
  evidence,
  witnessCount,
}: {
  evidence: AssertionEvidenceRow[];
  witnessCount: number;
}) {
  if (evidence.length === 0) {
    return (
      <div className="mt-2 text-[11px] text-[color:var(--color-ink-dim)]">
        No evidence rows recorded.
      </div>
    );
  }
  return (
    <details className="mt-2 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-canvas)] p-2">
      <summary className="flex cursor-pointer flex-wrap items-center gap-2 text-[11px] text-[color:var(--color-ink-muted)]">
        <span className="chip">
          <FileText size={10} /> {evidence.length} evidence
        </span>
        <span className="chip">
          <Users size={10} /> {witnessCount} witness{witnessCount === 1 ? "" : "es"}
        </span>
        {evidence.some((row) => !row.independent) ? (
          <span className="chip text-amber-300">shared witness</span>
        ) : null}
      </summary>
      <ul className="mt-2 flex flex-col gap-1.5">
        {evidence.map((row) => (
          <EvidenceLine key={row.evidence_id} row={row} />
        ))}
      </ul>
    </details>
  );
}

function EvidenceLine({ row }: { row: AssertionEvidenceRow }) {
  return (
    <li className="flex flex-wrap items-center gap-2 text-[11px] text-[color:var(--color-ink-muted)]">
      <span className="pill">{humanizeKey(row.kind)}</span>
      {row.witness_label ? (
        row.witness_node_id ? (
          <Link
            to={`/nodes/${row.witness_node_id}`}
            className="hover:text-[color:var(--color-rye)]"
          >
            {row.witness_label}
          </Link>
        ) : (
          <span>{row.witness_label}</span>
        )
      ) : (
        <span className="text-[color:var(--color-ink-dim)]">no witness</span>
      )}
      {row.event_id ? (
        <Link to={`/events?event=${row.event_id}`} className="hover:text-[color:var(--color-rye)]">
          {row.event_summary ?? humanizeKey(row.event_type ?? "event")}
        </Link>
      ) : null}
      {row.source_assertion_id ? (
        <span className="font-mono text-[color:var(--color-ink-dim)]">
          {row.source_assertion_type ?? "assertion"}:{row.source_assertion_key ?? "default"}
        </span>
      ) : null}
      {row.independent ? null : <span className="text-amber-300">not independent</span>}
    </li>
  );
}

type ClaimDiffEntry = {
  key: string;
  change: "added" | "removed" | "changed";
  before: unknown;
  after: unknown;
};

function ClaimDiff({ diff, hasIncumbent }: { diff: ClaimDiffEntry[]; hasIncumbent: boolean }) {
  if (!hasIncumbent) return null;
  if (diff.length === 0) {
    return (
      <div className="mt-2 text-[11px] text-[color:var(--color-ink-dim)]">
        Identical to the accepted claim.
      </div>
    );
  }
  return (
    <div className="mt-2 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-canvas)] p-2">
      <div className="field-label mb-1.5">Change vs accepted</div>
      <ul className="flex flex-col gap-1">
        {diff.map((entry) => (
          <li key={entry.key} className="flex flex-wrap items-center gap-2 text-[11px]">
            <span className="font-mono text-[color:var(--color-ink-muted)]">{entry.key}</span>
            {entry.change === "added" ? (
              <span className="text-emerald-300">+ {formatValue(entry.after)}</span>
            ) : entry.change === "removed" ? (
              <span className="text-rose-300 line-through">{formatValue(entry.before)}</span>
            ) : (
              <>
                <span className="text-[color:var(--color-ink-dim)] line-through">
                  {formatValue(entry.before)}
                </span>
                <ArrowRight size={11} className="text-[color:var(--color-ink-dim)]" />
                <span className="text-[color:var(--color-ink)]">{formatValue(entry.after)}</span>
              </>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}

function ClaimBlock({ claim }: { claim: unknown }) {
  const text = claimSummary(claim);
  if (text) {
    return (
      <p className="rounded-md bg-[color:var(--color-canvas)] p-2 text-sm leading-5 text-[color:var(--color-ink)]">
        {text}
      </p>
    );
  }
  return (
    <pre className="max-h-40 overflow-auto whitespace-pre-wrap rounded-md bg-[color:var(--color-canvas)] p-2 font-mono text-[11px] leading-5 text-[color:var(--color-ink-muted)] scrollbar">
      {JSON.stringify(claim ?? {}, null, 2)}
    </pre>
  );
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <div className="card-flat min-w-28 px-3 py-2">
      <div className="field-label">{label}</div>
      <div className="num mt-1 text-xl font-semibold">{fmtNumber(value)}</div>
    </div>
  );
}

function LoadingLine() {
  return (
    <div className="card flex items-center gap-2 text-sm text-[color:var(--color-ink-muted)]">
      <Inbox size={14} /> Loading review queue…
    </div>
  );
}

function ErrorLine({ error }: { error: unknown }) {
  return (
    <div className="rounded-md border border-rose-400/30 bg-rose-400/10 px-3 py-2 text-sm text-rose-200">
      {String(error instanceof Error ? error.message : error)}
    </div>
  );
}

function groupKey(group: ReviewQueueGroup): string {
  return `${group.subject_ref}:${group.assertion_type}:${group.assertion_key}`;
}

function claimDiff(before: unknown, after: unknown): ClaimDiffEntry[] {
  const oldClaim = asRecord(before);
  const newClaim = asRecord(after);
  const keys = Array.from(new Set([...Object.keys(oldClaim), ...Object.keys(newClaim)]));
  const entries: ClaimDiffEntry[] = [];
  for (const key of keys) {
    const oldValue = oldClaim[key];
    const newValue = newClaim[key];
    if (JSON.stringify(oldValue) === JSON.stringify(newValue)) continue;
    entries.push({
      key,
      change:
        oldValue === undefined ? "added" : newValue === undefined ? "removed" : "changed",
      before: oldValue,
      after: newValue,
    });
  }
  return entries;
}

function claimSummary(claim: unknown): string | null {
  const record = asRecord(claim);
  const entries = Object.entries(record).filter(([, value]) => value !== null && value !== undefined);
  if (entries.length === 0 || entries.length > 4) return null;
  if (entries.some(([, value]) => value && typeof value === "object")) return null;
  return entries.map(([key, value]) => `${humanizeKey(key)}: ${String(value)}`).join(" · ");
}

function formatValue(value: unknown): string {
  if (value === undefined) return "—";
  if (value === null) return "null";
  if (typeof value === "object") {
    const text = JSON.stringify(value);
    return text.length > 80 ? `${text.slice(0, 77)}…` : text;
  }
  return String(value);
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

export function humanizeKey(key: string): string {
  return key
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[_:.-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}
