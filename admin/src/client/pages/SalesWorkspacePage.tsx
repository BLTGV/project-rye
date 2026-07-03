import { useState, type ReactNode } from "react";
import { Link } from "react-router";
import {
  ArrowUpRight,
  BriefcaseBusiness,
  CalendarClock,
  CircleDollarSign,
  Contact,
  Handshake,
  MessageSquareWarning,
  UserRound,
} from "lucide-react";
import {
  useCrmWorkspace,
  type CrmOpportunity,
  type WorkspaceCandidate,
  type WorkspacePlan,
  type WorkspaceRelatedItem,
  type WorkspaceSourcePolicy,
} from "../lib/api";
import { fmtDate, fmtMoney, fmtNumber } from "../lib/format";

const SALES_STAGES = [
  "prospecting",
  "qualification",
  "site_survey_completed",
  "proposal_sent",
  "contract_review",
  "negotiation",
];

const STAGE_LABELS: Record<string, string> = {
  prospecting: "Prospecting",
  qualification: "Qualifying",
  site_survey_completed: "Site survey done",
  proposal_sent: "Proposal sent",
  contract_review: "Contract review",
  negotiation: "Negotiating",
};

export function SalesWorkspacePage() {
  const crm = useCrmWorkspace();
  const [selectedId, setSelectedId] = useState<string | null>(null);

  if (crm.error) {
    return (
      <div className="card text-rose-300">
        <div className="font-medium">Sales workspace is unavailable.</div>
        <p className="mt-2 text-sm leading-5 text-rose-200/80">
          The local Rye API could not load deal and account knowledge for this instance.
        </p>
        <div className="mt-3 font-mono text-xs text-rose-200/70">{crm.error.message}</div>
      </div>
    );
  }

  if (!crm.data) return <SalesSkeleton />;

  const opportunities = crm.data.opportunities ?? [];
  const selected =
    opportunities.find((opportunity) => opportunity.id === selectedId) ??
    opportunities[0] ??
    null;
  const stageGroups = groupOpportunities(opportunities);
  const plansBySubject = groupBySubject(crm.data.plans ?? []);
  const candidatesBySubject = groupCandidatesBySubject(crm.data.candidates ?? []);
  const totalValue = opportunities.reduce((sum, opportunity) => sum + toNumber(opportunity.current_value), 0);
  const weightedValue = opportunities.reduce((sum, opportunity) => {
    const probability = normalizeProbability(opportunity.win_probability);
    return sum + toNumber(opportunity.current_value) * probability;
  }, 0);
  const needsNextStep = opportunities.filter((opportunity) => !opportunity.next_action).length;
  const futurePlans = (crm.data.plans ?? []).filter((plan) => isFutureDate(planDate(plan))).length;

  return (
    <div className="flex min-h-0 flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="mb-2 flex items-center gap-2 text-[10px] uppercase tracking-[0.22em] text-[color:var(--color-ink-dim)]">
            <Handshake size={13} /> Business workspace
          </div>
          <h1 className="text-2xl font-semibold tracking-tight">Sales Pipeline</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-[color:var(--color-ink-muted)]">
            Deals, account relationships, next steps, planned stage changes, and suggested updates
            gathered from connected business sources.
          </p>
        </div>
        <Link to="/review" className="btn h-9 text-xs">
          <MessageSquareWarning size={14} /> Review suggested updates
        </Link>
      </header>

      <section className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <SummaryMetric icon={<BriefcaseBusiness size={15} />} label="Open deals" value={fmtNumber(opportunities.length)} />
        <SummaryMetric icon={<CircleDollarSign size={15} />} label="Pipeline value" value={fmtMoney(totalValue)} />
        <SummaryMetric icon={<CircleDollarSign size={15} />} label="Weighted value" value={fmtMoney(weightedValue)} />
        <SummaryMetric icon={<MessageSquareWarning size={15} />} label="Need next step" value={fmtNumber(needsNextStep)} tone={needsNextStep > 0 ? "warn" : "ok"} />
        <SummaryMetric icon={<CalendarClock size={15} />} label="Scheduled changes" value={fmtNumber(futurePlans)} />
      </section>

      {opportunities.length === 0 ? (
        <EmptyWorkspace
          title="No sales records found"
          body="This instance does not have current deal records in the CRM projection yet. Suggested updates can still appear after source intake."
        />
      ) : (
        <section className="grid min-h-0 grid-cols-1 items-start gap-4 xl:grid-cols-[minmax(0,1fr)_390px]">
          <PipelineBoard
            groups={stageGroups}
            selectedId={selected?.id ?? null}
            onSelect={setSelectedId}
          />
          <SalesDetailPanel
            opportunity={selected}
            plans={selected ? plansBySubject.get(selected.id) ?? [] : []}
            candidates={selected ? candidatesBySubject.get(selected.id) ?? [] : []}
            sourcePolicies={crm.data.source_policies ?? []}
          />
        </section>
      )}
    </div>
  );
}

function PipelineBoard({
  groups,
  selectedId,
  onSelect,
}: {
  groups: { key: string; label: string; opportunities: CrmOpportunity[] }[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  return (
    <section className="min-w-0">
      <div className="mb-3 flex items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-medium">Pipeline Board</h2>
          <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
            Current deal stage by opportunity. Select any card to inspect the business context.
          </p>
        </div>
      </div>
      <div className="grid auto-cols-[minmax(300px,360px)] grid-flow-col gap-3 overflow-x-auto pb-2 scrollbar">
        {groups.map((group) => (
          <div
            key={group.key}
            className="flex max-h-[calc(100vh-24rem)] min-h-[220px] flex-col rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)]"
          >
            <div className="flex items-center justify-between border-b border-[color:var(--color-line-soft)] px-4 py-3">
              <h3 className="text-sm font-medium">{group.label}</h3>
              <span className="chip">{fmtNumber(group.opportunities.length)}</span>
            </div>
            <div className="flex flex-1 flex-col gap-2 overflow-y-auto p-3 scrollbar">
              {group.opportunities.length === 0 ? (
                <div className="rounded-md border border-dashed border-[color:var(--color-line)] px-3 py-8 text-center text-xs text-[color:var(--color-ink-dim)]">
                  No deals
                </div>
              ) : (
                group.opportunities.map((opportunity) => (
                  <OpportunityCard
                    key={opportunity.id}
                    opportunity={opportunity}
                    selected={selectedId === opportunity.id}
                    onSelect={() => onSelect(opportunity.id)}
                  />
                ))
              )}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function OpportunityCard({
  opportunity,
  selected,
  onSelect,
}: {
  opportunity: CrmOpportunity;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      className={[
        "w-full rounded-md border p-3 text-left transition",
        selected
          ? "border-[color:var(--color-rye)] bg-[color:var(--color-surface-3)]"
          : "border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)]/70 hover:border-[color:var(--color-rye)]",
      ].join(" ")}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate text-sm font-medium text-[color:var(--color-ink)]">
            {opportunity.name ?? opportunity.label}
          </div>
          <div className="mt-1 truncate text-xs text-[color:var(--color-ink-muted)]">
            {opportunity.pipeline ? humanize(opportunity.pipeline) : "Pipeline"} · {opportunity.code ?? "No code"}
          </div>
        </div>
        <span className="num shrink-0 text-sm font-semibold text-[color:var(--color-rye)]">
          {fmtMoney(toNumber(opportunity.current_value))}
        </span>
      </div>
      <div className="mt-3 grid grid-cols-2 gap-2 text-xs text-[color:var(--color-ink-muted)]">
        <span className="truncate">Owner: {opportunity.assigned_to_name ?? "Unassigned"}</span>
        <span className="truncate text-right">{formatProbability(opportunity.win_probability)}</span>
      </div>
      <div className="mt-2 line-clamp-2 text-xs leading-5 text-[color:var(--color-ink)]">
        {opportunity.next_action ?? "No next step recorded"}
      </div>
    </button>
  );
}

function SalesDetailPanel({
  opportunity,
  plans,
  candidates,
  sourcePolicies,
}: {
  opportunity: CrmOpportunity | null;
  plans: WorkspacePlan[];
  candidates: WorkspaceCandidate[];
  sourcePolicies: WorkspaceSourcePolicy[];
}) {
  if (!opportunity) {
    return (
      <aside className="card self-start text-sm text-[color:var(--color-ink-muted)]">
        Select a deal to see details.
      </aside>
    );
  }

  const people = opportunity.related_items.filter((item) => item.node_type === "person");
  const organizations = opportunity.related_items.filter((item) => item.node_type === "org");
  const otherLinks = opportunity.related_items.filter(
    (item) => item.node_type !== "person" && item.node_type !== "org"
  );

  return (
    <aside className="sticky top-20 flex max-h-[calc(100vh-6rem)] min-w-0 flex-col overflow-y-auto rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-5 scrollbar">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="mb-2 flex flex-wrap gap-2">
            <span className="chip">{stageLabel(opportunity.stage)}</span>
            <span className="chip">{opportunity.code ?? "No code"}</span>
          </div>
          <h2 className="text-lg font-semibold leading-6">{opportunity.name ?? opportunity.label}</h2>
          <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
            {opportunity.pipeline ? humanize(opportunity.pipeline) : "Sales pipeline"}
          </p>
        </div>
        <Link to={`/nodes/${opportunity.id}`} className="btn h-8 shrink-0 text-xs">
          <ArrowUpRight size={13} /> Record
        </Link>
      </div>

      <div className="mt-5 grid grid-cols-2 gap-3">
        <DetailStat label="Value" value={fmtMoney(toNumber(opportunity.current_value))} />
        <DetailStat label="Win chance" value={formatProbability(opportunity.win_probability)} />
        <DetailStat label="Owner" value={opportunity.assigned_to_name ?? "Unassigned"} icon={<UserRound size={13} />} />
        <DetailStat label="Contact" value={opportunity.primary_contact_name ?? "Unknown"} icon={<Contact size={13} />} />
      </div>

      <DetailBlock title="Next Step">
        <p className="text-sm leading-6 text-[color:var(--color-ink)]">
          {opportunity.next_action ?? "No confirmed next step has been recorded."}
        </p>
      </DetailBlock>

      <DetailBlock title="People And Accounts">
        <RelatedList items={[...people, ...organizations]} empty="No people or accounts are linked yet." />
      </DetailBlock>

      <DetailBlock title="Related Work">
        <RelatedList items={otherLinks} empty="No related projects, tasks, or dependencies are linked yet." />
      </DetailBlock>

      <DetailBlock title="Scheduled Changes">
        {plans.length === 0 ? (
          <EmptyInline>No planned stage changes are recorded.</EmptyInline>
        ) : (
          <div className="flex flex-col gap-2">
            {plans.map((plan) => (
              <div key={plan.id} className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
                <div className="text-sm font-medium">{planSummary(plan)}</div>
                <div className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
                  Effective {fmtDate(planDate(plan))} · recorded {fmtDate(plan.created_at)}
                </div>
              </div>
            ))}
          </div>
        )}
      </DetailBlock>

      <DetailBlock title="Suggested Updates">
        <SuggestionList candidates={candidates} />
      </DetailBlock>

      <DetailBlock title="Where The Page Gets Truth">
        <SourcePolicyList policies={sourcePolicies} />
      </DetailBlock>
    </aside>
  );
}

function SummaryMetric({
  icon,
  label,
  value,
  tone = "default",
}: {
  icon: ReactNode;
  label: string;
  value: string;
  tone?: "default" | "warn" | "ok";
}) {
  const toneClass =
    tone === "warn" ? "text-amber-300" : tone === "ok" ? "text-emerald-300" : "text-[color:var(--color-ink)]";
  return (
    <div className="rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-4">
      <div className="flex items-center gap-2 text-xs text-[color:var(--color-ink-muted)]">
        <span className={toneClass}>{icon}</span>
        {label}
      </div>
      <div className={`num mt-2 text-xl font-semibold ${toneClass}`}>{value}</div>
    </div>
  );
}

function DetailStat({
  label,
  value,
  icon,
}: {
  label: string;
  value: string;
  icon?: ReactNode;
}) {
  return (
    <div className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
      <div className="flex items-center gap-1.5 text-[11px] text-[color:var(--color-ink-muted)]">
        {icon}
        {label}
      </div>
      <div className="mt-1 truncate text-sm font-medium">{value}</div>
    </div>
  );
}

function DetailBlock({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="mt-5 border-t border-[color:var(--color-line-soft)] pt-4">
      <h3 className="mb-2 text-sm font-medium">{title}</h3>
      {children}
    </section>
  );
}

function RelatedList({ items, empty }: { items: WorkspaceRelatedItem[]; empty: string }) {
  if (items.length === 0) return <EmptyInline>{empty}</EmptyInline>;
  return (
    <div className="flex flex-col gap-2">
      {items.slice(0, 10).map((item) => (
        <Link
          key={`${item.relation}:${item.id}`}
          to={`/nodes/${item.id}`}
          className="flex items-center justify-between gap-3 rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] px-3 py-2 text-sm hover:border-[color:var(--color-rye)]"
        >
          <span className="min-w-0 truncate">{item.label ?? item.id}</span>
          <span className="shrink-0 text-[11px] text-[color:var(--color-ink-muted)]">
            {relationshipLabel(item)}
          </span>
        </Link>
      ))}
    </div>
  );
}

function SuggestionList({ candidates }: { candidates: WorkspaceCandidate[] }) {
  if (candidates.length === 0) return <EmptyInline>No source-based suggestions are waiting for this deal.</EmptyInline>;
  return (
    <div className="flex flex-col gap-2">
      {candidates.slice(0, 5).map((candidate) => (
        <Link
          key={candidate.id}
          to="/review"
          className="rounded-md border border-amber-400/30 bg-amber-400/10 p-3 text-sm hover:border-amber-300"
        >
          <div className="line-clamp-3 leading-5">{candidateStatement(candidate)}</div>
          <div className="mt-2 text-xs text-amber-200/80">
            {candidate.sources.length} supporting source{candidate.sources.length === 1 ? "" : "s"} · {fmtDate(candidate.created_at)}
          </div>
        </Link>
      ))}
    </div>
  );
}

function SourcePolicyList({ policies }: { policies: WorkspaceSourcePolicy[] }) {
  if (policies.length === 0) return <EmptyInline>No explicit sales source rules are recorded.</EmptyInline>;
  return (
    <div className="flex flex-col gap-2 text-xs text-[color:var(--color-ink-muted)]">
      {policies.slice(0, 4).map((policy) => (
        <div key={policy.id} className="rounded-md border border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] p-3">
          <div className="font-medium text-[color:var(--color-ink)]">{policy.scope_label}</div>
          <div className="mt-1">{policySummary(policy)}</div>
        </div>
      ))}
    </div>
  );
}

function EmptyWorkspace({ title, body }: { title: string; body: string }) {
  return (
    <section className="rounded-lg border border-dashed border-[color:var(--color-line)] bg-[color:var(--color-surface)] px-5 py-12 text-center">
      <h2 className="text-base font-medium">{title}</h2>
      <p className="mx-auto mt-2 max-w-xl text-sm leading-6 text-[color:var(--color-ink-muted)]">{body}</p>
    </section>
  );
}

function EmptyInline({ children }: { children: ReactNode }) {
  return <div className="text-sm leading-6 text-[color:var(--color-ink-muted)]">{children}</div>;
}

function SalesSkeleton() {
  return (
    <div className="flex flex-col gap-4">
      <div className="h-24 animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
      <div className="grid grid-cols-5 gap-3">
        {Array.from({ length: 5 }).map((_, index) => (
          <div key={index} className="h-24 animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
        ))}
      </div>
      <div className="h-[520px] animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
    </div>
  );
}

function groupOpportunities(opportunities: CrmOpportunity[]) {
  const known = new Map(SALES_STAGES.map((stage) => [stage, [] as CrmOpportunity[]]));
  const other: CrmOpportunity[] = [];
  for (const opportunity of opportunities) {
    const key = opportunity.stage ?? "unknown";
    if (known.has(key)) {
      known.get(key)!.push(opportunity);
    } else {
      other.push(opportunity);
    }
  }
  const groups = SALES_STAGES.map((stage) => ({
    key: stage,
    label: stageLabel(stage),
    opportunities: known.get(stage) ?? [],
  }));
  if (other.length > 0) groups.push({ key: "other", label: "Other", opportunities: other });
  return groups;
}

function groupBySubject(plans: WorkspacePlan[]) {
  const grouped = new Map<string, WorkspacePlan[]>();
  for (const plan of plans) {
    if (!grouped.has(plan.subject_id)) grouped.set(plan.subject_id, []);
    grouped.get(plan.subject_id)!.push(plan);
  }
  return grouped;
}

function groupCandidatesBySubject(candidates: WorkspaceCandidate[]) {
  const grouped = new Map<string, WorkspaceCandidate[]>();
  for (const candidate of candidates) {
    const subjectIds = candidateSubjectIds(candidate);
    for (const id of subjectIds) {
      if (!grouped.has(id)) grouped.set(id, []);
      grouped.get(id)!.push(candidate);
    }
  }
  return grouped;
}

function candidateSubjectIds(candidate: WorkspaceCandidate) {
  const ids = new Set<string>();
  const payload = asRecord(candidate.properties.target_payload);
  for (const key of ["opportunity_id", "opportunityId", "subject_id", "subjectNodeId"]) {
    const value = payload[key];
    if (typeof value === "string") ids.add(value);
  }
  const nested = asRecord(payload.target_payload);
  for (const key of ["opportunity_id", "opportunityId", "subject_id", "subjectNodeId"]) {
    const value = nested[key];
    if (typeof value === "string") ids.add(value);
  }
  return [...ids];
}

function stageLabel(stage: string | null | undefined) {
  if (!stage) return "Unknown stage";
  return STAGE_LABELS[stage] ?? humanize(stage);
}

function humanize(value: string) {
  return value
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function toNumber(value: unknown) {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) ? number : 0;
}

function normalizeProbability(value: unknown) {
  const number = toNumber(value);
  if (number <= 0) return 0;
  return number > 1 ? number / 100 : number;
}

function formatProbability(value: unknown) {
  const probability = normalizeProbability(value);
  if (!probability) return "No probability";
  return `${Math.round(probability * 100)}% likely`;
}

function isFutureDate(value: string | null | undefined) {
  if (!value) return false;
  return new Date(value).getTime() > Date.now();
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function relationshipLabel(item: WorkspaceRelatedItem) {
  return humanize(item.role ?? item.relationship ?? item.relation ?? item.node_type);
}

function candidateStatement(candidate: WorkspaceCandidate) {
  return candidate.properties.statement ?? candidate.label ?? "Suggested update";
}

function planSummary(plan: WorkspacePlan) {
  const claim = asRecord(plan.claim);
  const stage = claim.planned_stage ?? claim.stage ?? claim.next_stage ?? claim.status;
  const reason = claim.reason;
  if (typeof stage === "string" && typeof reason === "string") {
    return `${humanize(stage)}: ${reason}`;
  }
  if (typeof stage === "string") return `Move to ${humanize(stage)}`;
  if (typeof reason === "string") return reason;
  return humanize(plan.assertion_key);
}

function planDate(plan: WorkspacePlan) {
  const claim = asRecord(plan.claim);
  const value = claim.effective_at;
  return typeof value === "string" ? value : plan.effective_at;
}

function policySummary(policy: WorkspaceSourcePolicy) {
  const claim = asRecord(policy.claim);
  const source = claim.authoritative_source ?? claim.source ?? claim.system;
  const domain = claim.status_domain ?? policy.assertion_key;
  if (typeof source === "string") return `${humanize(source)} is trusted for ${humanize(String(domain))}.`;
  return `Trusted rule for ${humanize(String(domain))}.`;
}
