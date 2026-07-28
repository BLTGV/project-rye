// Shared v2 assertion chrome: where a claim came from (basis) and how strongly
// Rye believes it (effective vs stored confidence). Used by the review queue,
// the gaps surface, and node detail so the three read the same way.

export function BasisBadge({ basis }: { basis: string }) {
  const cls =
    basis === "observed"
      ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-300"
      : basis === "reported"
        ? "border-[color:var(--color-cyan)]/30 bg-[color:var(--color-cyan)]/10 text-[color:var(--color-cyan)]"
        : basis === "inferred"
          ? "border-[color:var(--color-violet)]/30 bg-[color:var(--color-violet)]/10 text-[color:var(--color-violet)]"
          : basis === "assumed"
            ? "border-amber-400/30 bg-amber-400/10 text-amber-200"
            : "border-[color:var(--color-line)] text-[color:var(--color-ink-muted)]";
  return (
    <span
      className={`rounded-md border px-2 py-1 text-[10px] uppercase tracking-wider ${cls}`}
      title={basisDescription(basis)}
    >
      {humanizeBasis(basis)}
    </span>
  );
}

export function ConfidenceChip({
  effective,
  stored,
  prior,
}: {
  effective: number | null | undefined;
  stored: number | null | undefined;
  prior?: number | null;
}) {
  const effectiveValue = numeric(effective);
  const storedValue = numeric(stored);
  const priorValue = numeric(prior);

  if (effectiveValue !== null) {
    return (
      <span
        className="chip"
        title={
          storedValue !== null
            ? `Effective belief ${pct(effectiveValue)} · stored prior ${pct(storedValue)}`
            : `Effective belief ${pct(effectiveValue)} · no stored prior`
        }
      >
        {pct(effectiveValue)} effective
        {storedValue !== null && storedValue !== effectiveValue ? (
          <span className="text-[color:var(--color-ink-dim)]">/ {pct(storedValue)} stored</span>
        ) : null}
      </span>
    );
  }

  // effective_confidence() is defined only over current_valid_assertions, so a
  // live candidate has none yet. Show what the computation would start from.
  const fallback = storedValue ?? priorValue;
  if (fallback === null) return <span className="chip">confidence not set</span>;
  return (
    <span
      className="chip"
      title={
        storedValue !== null
          ? "Stored prior. Effective belief is computed once this row is accepted and current."
          : "Registry prior for this basis. Effective belief is computed once this row is accepted and current."
      }
    >
      {pct(fallback)} {storedValue !== null ? "stored" : "basis prior"}
    </span>
  );
}

export function basisDescription(basis: string): string {
  switch (basis) {
    case "observed":
      return "Rye saw this directly in a source system or document.";
    case "reported":
      return "Someone told Rye this; it was not observed directly.";
    case "inferred":
      return "Derived from other assertions rather than observed.";
    case "assumed":
      return "A working assumption with no supporting evidence.";
    default:
      return "The basis for this claim was not recorded.";
  }
}

function humanizeBasis(basis: string): string {
  return basis.replace(/[_-]+/g, " ");
}

function numeric(value: number | string | null | undefined): number | null {
  if (value === null || value === undefined) return null;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function pct(value: number): string {
  return `${Math.round(value * 100)}%`;
}
