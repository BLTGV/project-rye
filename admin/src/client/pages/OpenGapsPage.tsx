import { Link } from "react-router";
import { CheckCircle2, HelpCircle, RefreshCcw } from "lucide-react";
import { useOpenGaps, useStaleDigests, type OpenGapRow, type StaleDigestRow } from "../lib/api";
import { BasisBadge, ConfidenceChip } from "../components/AssertionBadges";
import { colorForType, fmtDate, fmtNumber } from "../lib/format";

export function OpenGapsPage() {
  const gaps = useOpenGaps(200);
  const stale = useStaleDigests(200);

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="mb-2 flex items-center gap-2 text-[10px] uppercase tracking-[0.22em] text-[color:var(--color-ink-dim)]">
            <HelpCircle size={13} /> Knowledge gaps
          </div>
          <h1 className="text-2xl font-semibold tracking-tight">Open Questions</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-[color:var(--color-ink-muted)]">
            Questions Rye knows it cannot answer yet, plus digests whose sources
            have moved on. Answering a gap or re-running a distillation clears
            the entry.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Metric label="Open gaps" value={gaps.data?.length ?? 0} />
          <Metric label="Stale digests" value={stale.data?.length ?? 0} />
        </div>
      </header>

      {gaps.error ? <ErrorLine error={gaps.error} /> : null}
      {stale.error ? <ErrorLine error={stale.error} /> : null}

      <section className="card">
        <div className="mb-3 flex items-center justify-between gap-3">
          <div>
            <h2 className="flex items-center gap-2 text-sm font-medium">
              <HelpCircle size={14} /> Open gaps
            </h2>
            <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
              Accepted knowledge_gap assertions that nothing has resolved.
            </p>
          </div>
          <span className="chip">{fmtNumber(gaps.data?.length ?? 0)}</span>
        </div>
        {gaps.isLoading ? (
          <LoadingLine />
        ) : (gaps.data?.length ?? 0) === 0 ? (
          <EmptyLine>
            <CheckCircle2 size={14} className="mr-2 inline text-emerald-300" />
            No open gaps recorded.
          </EmptyLine>
        ) : (
          <ul className="flex flex-col gap-2">
            {(gaps.data ?? []).map((gap) => (
              <GapRow key={gap.id} gap={gap} />
            ))}
          </ul>
        )}
      </section>

      <section className="card">
        <div className="mb-3 flex items-center justify-between gap-3">
          <div>
            <h2 className="flex items-center gap-2 text-sm font-medium">
              <RefreshCcw size={14} /> Stale digests
            </h2>
            <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
              Derived summaries whose subject gained newer facts, or whose source
              assertions were overturned, after the digest watermark.
            </p>
          </div>
          <span className="chip">{fmtNumber(stale.data?.length ?? 0)}</span>
        </div>
        {stale.isLoading ? (
          <LoadingLine />
        ) : (stale.data?.length ?? 0) === 0 ? (
          <EmptyLine>
            <CheckCircle2 size={14} className="mr-2 inline text-emerald-300" />
            Every digest is current with its sources.
          </EmptyLine>
        ) : (
          <ul className="flex flex-col gap-2">
            {(stale.data ?? []).map((digest) => (
              <StaleDigestLine key={digest.id} digest={digest} />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

function GapRow({ gap }: { gap: OpenGapRow }) {
  return (
    <li className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <SubjectLink
          nodeId={gap.subject_node_id}
          label={gap.subject_label ?? gap.subject_ref}
          nodeType={gap.subject_node_type}
        />
        <span className="chip font-mono">{gap.assertion_key}</span>
        <BasisBadge basis={gap.basis} />
        <ConfidenceChip effective={gap.effective_confidence} stored={gap.confidence} />
        <span className="chip">{fmtDate(gap.asserted_at)}</span>
      </div>
      <p className="text-sm leading-5 text-[color:var(--color-ink)]">{gapQuestion(gap)}</p>
      {gap.evidence.length > 0 ? (
        <div className="mt-2 flex flex-wrap gap-2 text-[11px] text-[color:var(--color-ink-muted)]">
          {gap.evidence.map((row) => (
            <span key={row.evidence_id} className="pill">
              {humanizeKey(row.kind)}
              {row.witness_label ? ` · ${row.witness_label}` : ""}
            </span>
          ))}
        </div>
      ) : null}
    </li>
  );
}

function StaleDigestLine({ digest }: { digest: StaleDigestRow }) {
  return (
    <li className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <SubjectLink
          nodeId={digest.subject_node_id}
          label={digest.subject_label ?? digest.subject_ref}
          nodeType={digest.subject_node_type}
        />
        <span className="chip font-mono">{digest.assertion_key}</span>
        <span className="rounded-md border border-amber-400/30 bg-amber-400/10 px-2 py-1 text-[10px] uppercase tracking-wider text-amber-200">
          stale
        </span>
        {digest.newer_subject_assertion ? (
          <span className="pill">newer facts on subject</span>
        ) : null}
        {digest.overturned_source ? <span className="pill">source overturned</span> : null}
        <span className="chip">as of {fmtDate(digest.watermark)}</span>
      </div>
      <pre className="max-h-40 overflow-auto whitespace-pre-wrap rounded-md bg-[color:var(--color-canvas)] p-2 font-mono text-[11px] leading-5 text-[color:var(--color-ink-muted)] scrollbar">
        {JSON.stringify(digest.claim ?? {}, null, 2)}
      </pre>
    </li>
  );
}

function SubjectLink({
  nodeId,
  label,
  nodeType,
}: {
  nodeId: string | null;
  label: string;
  nodeType: string | null;
}) {
  if (!nodeId) {
    return <span className="text-sm font-medium">{label}</span>;
  }
  return (
    <Link
      to={`/nodes/${nodeId}`}
      className="flex items-center gap-2 text-sm hover:text-[color:var(--color-rye)]"
    >
      <span className="size-2 rounded-full" style={{ background: colorForType(nodeType ?? "") }} />
      <span className="font-medium">{label}</span>
    </Link>
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

function humanizeKey(key: string): string {
  return key
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/[_:.-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function gapQuestion(gap: OpenGapRow): string {
  for (const key of ["question", "text", "summary", "description", "gap"]) {
    const value = gap.claim?.[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return JSON.stringify(gap.claim ?? {});
}

function LoadingLine() {
  return <div className="animate-pulse text-sm text-[color:var(--color-ink-muted)]">Loading…</div>;
}

function EmptyLine({ children }: { children: React.ReactNode }) {
  return (
    <div className="rounded-md border border-dashed border-[color:var(--color-line)] p-4 text-sm text-[color:var(--color-ink-muted)]">
      {children}
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
