import { useState } from "react";
import { Link } from "react-router";
import {
  AlertTriangle,
  CalendarClock,
  CheckCircle2,
  CircuitBoard,
  ClipboardList,
  Clock3,
  Filter,
  History,
  Layers3,
  Map as MapIcon,
  Plug,
  RotateCcw,
  Search,
  Workflow,
} from "lucide-react";
import {
  useKnowledgeMap,
  type KnowledgeMapCandidateSample,
  type KnowledgeMapOperationalPlan,
  type KnowledgeMapPolicyRow,
  type KnowledgeMapScope,
  type KnowledgeMapWarning,
} from "../lib/api";
import { fmtDate, fmtNumber, shortId } from "../lib/format";

export function KnowledgeMapPage() {
  const map = useKnowledgeMap();
  const [filters, setFilters] = useState<PolicyFilters>({
    search: "",
    type: "all",
    domain: "all",
  });
  const [activeSection, setActiveSection] = useState<KnowledgeSection>("overview");

  if (map.error) {
    return (
      <div className="card text-rose-300">
        <div className="font-medium">Process knowledge is unavailable.</div>
        <p className="mt-2 text-sm leading-5 text-rose-200/80">
          The admin API could not load the process knowledge map for this
          instance.
        </p>
        <div className="mt-3 font-mono text-xs text-rose-200/70">
          {map.error.message}
        </div>
      </div>
    );
  }

  if (!map.data) return <KnowledgeMapSkeleton />;

  const data = map.data;
  const currentRows = data.current_process;
  const futureRows = data.future_process ?? [];
  const historicalRows = data.historical_process;
  const operationalPlans = data.operational_plans ?? [];
  const allPolicyRows = [...currentRows, ...futureRows, ...historicalRows];
  const typeOptions = optionList(allPolicyRows.map((row) => row.assertion_type));
  const domainOptions = optionList(allPolicyRows.map((row) => row.domain ?? row.assertion_key));
  const filteredCurrentRows = filterPolicyRows(currentRows, filters);
  const filteredFutureRows = filterPolicyRows(futureRows, filters);
  const filteredHistoricalRows = filterPolicyRows(historicalRows, filters);
  const sourceTruthRows = currentRows.filter(
    (row) => row.assertion_type === "source_of_truth_policy"
  );
  const futureTruthRows = futureRows.filter(
    (row) => row.assertion_type === "source_of_truth_policy"
  );
  const constraintRows = currentRows.filter(
    (row) => row.assertion_type === "process_constraint"
  );
  const sectionItems: SectionItem[] = [
    {
      id: "overview",
      label: "Overview",
      icon: <MapIcon size={14} />,
      count: data.stats.scope_count,
      purpose: "Start here to see scope, plugin coverage, candidates, and warnings.",
    },
    {
      id: "current",
      label: "Current",
      icon: <CheckCircle2 size={14} />,
      count: data.stats.current_process_count,
      purpose: "Use this for how the business works today.",
    },
    {
      id: "future",
      label: "Plans",
      icon: <CalendarClock size={14} />,
      count: (data.stats.future_process_count ?? futureRows.length) + (data.stats.operational_plan_count ?? operationalPlans.length),
      purpose: "Review future-effective policies and current-visible CRM/PM plans.",
    },
    {
      id: "candidates",
      label: "Candidates",
      icon: <ClipboardList size={14} />,
      count: data.stats.candidate_count,
      purpose: "Inspect proposed knowledge before it becomes accepted truth.",
    },
    {
      id: "history",
      label: "History",
      icon: <History size={14} />,
      count: data.stats.historical_process_count,
      purpose: "Answer what used to be true without mixing it into current answers.",
    },
    {
      id: "warnings",
      label: "Warnings",
      icon: <AlertTriangle size={14} />,
      count: data.stats.warning_count,
      purpose: "Find duplicate, missing, or suspicious knowledge map conditions.",
    },
  ];

  return (
    <div className="flex flex-col gap-6">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="mb-2 flex items-center gap-2 text-[10px] uppercase tracking-[0.22em] text-[color:var(--color-ink-dim)]">
            <CircuitBoard size={13} /> Knowledge map
          </div>
          <h1 className="text-2xl font-semibold tracking-tight">
            Process Knowledge
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-[color:var(--color-ink-muted)]">
            Current operating rules, prior windows, candidate state, and plugin
            coverage from the selected Rye instance.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <MetricChip label="Scopes" value={data.stats.scope_count} />
          <MetricChip label="Current rules" value={data.stats.current_process_count} />
          <MetricChip label="Future" value={data.stats.future_process_count ?? futureRows.length} />
          <MetricChip label="Plans" value={data.stats.operational_plan_count ?? operationalPlans.length} />
          <MetricChip label="History" value={data.stats.historical_process_count} />
          <MetricChip label="Warnings" value={data.stats.warning_count} tone={data.stats.warning_count > 0 ? "warn" : "ok"} />
        </div>
      </header>

      <SectionSwitcher
        items={sectionItems}
        active={activeSection}
        onSelect={setActiveSection}
      />

      {activeSection === "overview" ? (
        <section className="flex flex-col gap-4">
          <SectionIntro
            title="Map Overview"
            purpose="This section answers whether the selected Rye instance has a usable business-knowledge scope, the expected plugins, pending candidates, and warnings that need human attention."
            components="Scope cards show what area of the business is being mapped. Plugin cards show which domain skills are attached. Candidate gates show how much proposed knowledge still needs review."
          />
          {data.warnings.length > 0 ? <WarningPanel warnings={data.warnings.slice(0, 4)} compact /> : <WarningPanel warnings={[]} compact />}
          <section className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-4">
            <SummaryTile
              icon={<CheckCircle2 size={14} />}
              label="Source of truth"
              value={sourceTruthRows.length}
              sub="current authority policies"
            />
            <SummaryTile
              icon={<CalendarClock size={14} />}
              label="Future authority"
              value={futureTruthRows.length}
              sub="scheduled source policies"
            />
            <SummaryTile
              icon={<Workflow size={14} />}
              label="Constraints"
              value={constraintRows.length}
              sub="current bottleneck claims"
            />
            <SummaryTile
              icon={<Clock3 size={14} />}
              label="Generated"
              value={fmtDate(data.generated_at)}
              sub="local admin read"
            />
          </section>
          <section className="grid grid-cols-1 gap-4 xl:grid-cols-3">
            <ScopePanel scopes={data.scopes} />
            <PluginPanel bindings={data.plugin_bindings} />
            <CandidatePanel
              statuses={data.candidate_statuses}
              total={data.stats.candidate_count}
            />
          </section>
        </section>
      ) : null}

      {activeSection === "current" ? (
        <section className="flex flex-col gap-4">
          <SectionIntro
            title="Current Knowledge"
            purpose="This section answers how the business works now. Future-effective rows are intentionally excluded so current answers do not drift into planned-state answers."
            components="Lenses narrow the map by knowledge type or domain. The table shows the current accepted rule, its scope, effective window, and the claim used by agents."
          />
          <PolicyLensPanel
            rows={currentRows}
            filters={filters}
            onChange={setFilters}
          />
          <section className="card">
            <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
              <div>
                <h2 className="text-sm font-medium">How The Process Works Now</h2>
                <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
                  Current-valid process assertions grouped by scope and domain.
                </p>
              </div>
              <span className="chip">
                {fmtNumber(filteredCurrentRows.length)} / {fmtNumber(currentRows.length)} rows
              </span>
            </div>
            <PolicyFilterControls
              filters={filters}
              typeOptions={typeOptions}
              domainOptions={domainOptions}
              onChange={setFilters}
            />
            <PolicyTable rows={filteredCurrentRows} mode="current" />
          </section>
        </section>
      ) : null}

      {activeSection === "future" ? (
        <section className="flex flex-col gap-4">
          <SectionIntro
            title="Plans And Future"
            purpose="This section answers what is planned or future-effective. Rows here can support planning and milestone tracking, but they should not answer current-state questions until their effective date."
            components="Future policies describe scheduled source-of-truth changes. Operational plans show CRM/PM plan assertions that are visible today while the future truth row waits for its effective date."
          />
          <OperationalPlans rows={operationalPlans} />
          <section className="card">
            <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
              <div>
                <h2 className="text-sm font-medium">Future-Effective Policies</h2>
                <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
                  Accepted policies whose effective date is later than now.
                </p>
              </div>
              <span className="chip">
                {fmtNumber(filteredFutureRows.length)} / {fmtNumber(futureRows.length)} rows
              </span>
            </div>
            <PolicyFilterControls
              filters={filters}
              typeOptions={typeOptions}
              domainOptions={domainOptions}
              onChange={setFilters}
            />
            <PolicyTable rows={filteredFutureRows} mode="current" />
          </section>
        </section>
      ) : null}

      {activeSection === "candidates" ? (
        <section className="flex flex-col gap-4">
          <SectionIntro
            title="Candidate Review"
            purpose="This section answers what the agents observed but humans have not fully accepted. It is where contradiction is cheaper than writing documentation from scratch."
            components="Gate bars show candidate status volume. Recent cards show the proposed statement, source links, and enough context to decide whether to promote, reject, or ask for more evidence."
          />
          <section className="grid grid-cols-1 gap-4 2xl:grid-cols-5">
            <div className="2xl:col-span-2">
              <CandidatePanel
                statuses={data.candidate_statuses}
                total={data.stats.candidate_count}
              />
            </div>
            <div className="card 2xl:col-span-3">
              <div className="mb-4 flex items-center justify-between">
                <div>
                  <h2 className="text-sm font-medium">Recent Candidates</h2>
                  <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
                    Proposed knowledge waiting for acceptance, rejection, or promotion.
                  </p>
                </div>
                <span className="chip">{fmtNumber(data.candidate_samples.length)}</span>
              </div>
              <CandidateSamples rows={data.candidate_samples} />
            </div>
          </section>
        </section>
      ) : null}

      {activeSection === "history" ? (
        <section className="flex flex-col gap-4">
          <SectionIntro
            title="History"
            purpose="This section answers what used to be true. It helps agents answer historical questions without reviving old process nodes or source policies as current truth."
            components="The table shows closed or superseded windows, including the effective dates and supersession dates that bound historical answers."
          />
          <section className="card">
            <div className="mb-4 flex items-center justify-between">
              <div>
                <h2 className="text-sm font-medium">Historical Windows</h2>
                <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
                  Superseded or closed process knowledge that should only answer historical questions.
                </p>
              </div>
              <span className="chip">
                <History size={11} /> {fmtNumber(filteredHistoricalRows.length)} / {fmtNumber(historicalRows.length)}
              </span>
            </div>
            <PolicyFilterControls
              filters={filters}
              typeOptions={typeOptions}
              domainOptions={domainOptions}
              onChange={setFilters}
            />
            <PolicyTable rows={filteredHistoricalRows} mode="history" />
          </section>
        </section>
      ) : null}

      {activeSection === "warnings" ? (
        <section className="flex flex-col gap-4">
          <SectionIntro
            title="Warnings"
            purpose="This section answers what might confuse an agent or a human reviewer: duplicate authorities, missing plugin coverage, suspicious future rows, or policy/candidate mismatches."
            components="Each warning includes severity, scope, domain, and the assertion or node that should be inspected."
          />
          <WarningPanel warnings={data.warnings} />
        </section>
      ) : null}
    </div>
  );
}

interface PolicyFilters {
  search: string;
  type: string;
  domain: string;
}

type KnowledgeSection = "overview" | "current" | "future" | "candidates" | "history" | "warnings";

interface SectionItem {
  id: KnowledgeSection;
  label: string;
  icon: React.ReactNode;
  count: number;
  purpose: string;
}

function SectionSwitcher({
  items,
  active,
  onSelect,
}: {
  items: SectionItem[];
  active: KnowledgeSection;
  onSelect: (section: KnowledgeSection) => void;
}) {
  return (
    <nav className="grid grid-cols-1 gap-2 md:grid-cols-2 xl:grid-cols-6">
      {items.map((item) => (
        <button
          key={item.id}
          type="button"
          onClick={() => onSelect(item.id)}
          className={[
            "rounded-lg border p-3 text-left transition",
            active === item.id
              ? "border-[color:var(--color-rye)] bg-[color:var(--color-surface)] text-white"
              : "border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)] text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)] hover:text-white",
          ].join(" ")}
          title={item.purpose}
        >
          <span className="flex items-center justify-between gap-2">
            <span className="flex min-w-0 items-center gap-2 text-sm font-medium">
              {item.icon}
              <span className="truncate">{item.label}</span>
            </span>
            <span className="num text-xs text-[color:var(--color-ink-dim)]">
              {fmtNumber(item.count)}
            </span>
          </span>
          <span className="mt-2 block line-clamp-2 text-[11px] leading-4 text-[color:var(--color-ink-dim)]">
            {item.purpose}
          </span>
        </button>
      ))}
    </nav>
  );
}

function SectionIntro({
  title,
  purpose,
  components,
}: {
  title: string;
  purpose: string;
  components: string;
}) {
  return (
    <section className="rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-4">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <h2 className="text-sm font-medium">{title}</h2>
          <p className="mt-1 max-w-4xl text-xs leading-5 text-[color:var(--color-ink-muted)]">
            {purpose}
          </p>
        </div>
        <p className="max-w-2xl text-xs leading-5 text-[color:var(--color-ink-dim)]">
          {components}
        </p>
      </div>
    </section>
  );
}

function PolicyLensPanel({
  rows,
  filters,
  onChange,
}: {
  rows: KnowledgeMapPolicyRow[];
  filters: PolicyFilters;
  onChange: (next: PolicyFilters) => void;
}) {
  const typeCounts = countRows(rows, (row) => row.assertion_type);
  const domainCounts = countRows(rows, (row) => row.domain ?? row.assertion_key);
  const activeFilters = [
    filters.type !== "all" ? filters.type : null,
    filters.domain !== "all" ? filters.domain : null,
    filters.search ? `"${filters.search}"` : null,
  ].filter(Boolean);

  return (
    <section className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,1.4fr)]">
      <div className="card">
        <div className="mb-4 flex items-center justify-between gap-3">
          <div>
            <h2 className="flex items-center gap-2 text-sm font-medium">
              <Layers3 size={14} /> Current Knowledge Lenses
            </h2>
            <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
              Slice the current map by assertion type or operating domain.
            </p>
          </div>
          {activeFilters.length > 0 ? (
            <button
              className="chip hover:border-[color:var(--color-rye)] hover:text-white"
              onClick={() => onChange({ search: "", type: "all", domain: "all" })}
              title="Reset filters"
            >
              <RotateCcw size={12} /> reset
            </button>
          ) : null}
        </div>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <LensGroup
            title="Types"
            rows={typeCounts}
            selected={filters.type}
            onSelect={(type) => onChange({ ...filters, type })}
          />
          <LensGroup
            title="Domains"
            rows={domainCounts}
            selected={filters.domain}
            onSelect={(domain) => onChange({ ...filters, domain })}
          />
        </div>
      </div>

      <div className="card">
        <div className="mb-4 flex items-center justify-between gap-3">
          <div>
            <h2 className="flex items-center gap-2 text-sm font-medium">
              <Filter size={14} /> Review Focus
            </h2>
            <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
              Use one filter set for current and historical rows, then open any
              scope or source from the row.
            </p>
          </div>
          <span className="chip">{activeFilters.length || 0} filters</span>
        </div>
        <PolicyFilterControls
          filters={filters}
          typeOptions={optionList(typeCounts.map((row) => row.key))}
          domainOptions={optionList(domainCounts.map((row) => row.key))}
          onChange={onChange}
          compact
        />
      </div>
    </section>
  );
}

function LensGroup({
  title,
  rows,
  selected,
  onSelect,
}: {
  title: string;
  rows: { key: string; count: number }[];
  selected: string;
  onSelect: (value: string) => void;
}) {
  const max = Math.max(1, ...rows.map((row) => row.count));
  return (
    <div>
      <div className="mb-2 flex items-center justify-between">
        <span className="field-label">{title}</span>
        <button
          className={selected === "all" ? "pill" : "chip hover:text-white"}
          onClick={() => onSelect("all")}
        >
          all
        </button>
      </div>
      <div className="flex max-h-60 flex-col gap-1.5 overflow-y-auto pr-1 scrollbar">
        {rows.map((row) => (
          <button
            key={row.key}
            className={[
              "group grid grid-cols-[minmax(0,1fr)_48px] items-center gap-2 rounded-md border px-2 py-1.5 text-left text-xs",
              selected === row.key
                ? "border-[color:var(--color-rye)] bg-[color:var(--color-surface-2)] text-white"
                : "border-[color:var(--color-line-soft)] bg-[color:var(--color-surface-2)]/60 text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)] hover:text-white",
            ].join(" ")}
            onClick={() => onSelect(row.key)}
            title={row.key}
          >
            <span className="truncate">{formatLensKey(row.key)}</span>
            <span className="num text-right text-[color:var(--color-ink-dim)]">
              {fmtNumber(row.count)}
            </span>
            <span className="col-span-2 h-1 overflow-hidden rounded-full bg-[color:var(--color-surface-3)]">
              <span
                className="block h-full rounded-full bg-[color:var(--color-rye)]"
                style={{ width: `${Math.max(8, (row.count / max) * 100)}%` }}
              />
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}

function PolicyFilterControls({
  filters,
  typeOptions,
  domainOptions,
  onChange,
  compact = false,
}: {
  filters: PolicyFilters;
  typeOptions: string[];
  domainOptions: string[];
  onChange: (next: PolicyFilters) => void;
  compact?: boolean;
}) {
  return (
    <div className={`mb-4 grid grid-cols-1 gap-3 ${compact ? "lg:grid-cols-1" : "lg:grid-cols-[1.2fr_0.9fr_0.9fr_auto]"}`}>
      <label className="flex min-w-0 flex-col gap-1">
        <span className="field-label">Search</span>
        <span className="relative">
          <Search
            size={14}
            className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[color:var(--color-ink-dim)]"
          />
          <input
            className="input w-full pl-9 text-sm"
            value={filters.search}
            onChange={(e) => onChange({ ...filters, search: e.target.value })}
            placeholder="Find systems, domains, policies, dates"
          />
        </span>
      </label>
      <label className="flex min-w-0 flex-col gap-1">
        <span className="field-label">Type</span>
        <select
          className="input text-sm"
          value={filters.type}
          onChange={(e) => onChange({ ...filters, type: e.target.value })}
        >
          {typeOptions.map((value) => (
            <option key={value} value={value}>
              {value === "all" ? "All types" : policyLabel(value)}
            </option>
          ))}
        </select>
      </label>
      <label className="flex min-w-0 flex-col gap-1">
        <span className="field-label">Domain</span>
        <select
          className="input text-sm"
          value={filters.domain}
          onChange={(e) => onChange({ ...filters, domain: e.target.value })}
        >
          {domainOptions.map((value) => (
            <option key={value} value={value}>
              {value === "all" ? "All domains" : formatLensKey(value)}
            </option>
          ))}
        </select>
      </label>
      {!compact ? (
        <div className="flex items-end">
          <button
            className="flex w-full items-center justify-center gap-2 rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] px-3 py-2 text-sm text-[color:var(--color-ink-muted)] hover:border-[color:var(--color-rye)] hover:text-white"
            onClick={() => onChange({ search: "", type: "all", domain: "all" })}
            title="Reset filters"
          >
            <RotateCcw size={14} /> Reset
          </button>
        </div>
      ) : null}
    </div>
  );
}

function WarningPanel({
  warnings,
  compact = false,
}: {
  warnings: KnowledgeMapWarning[];
  compact?: boolean;
}) {
  if (warnings.length === 0) {
    return (
      <section className="rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-4 py-3 text-sm text-emerald-200">
        <div className="flex items-center gap-2">
          <CheckCircle2 size={15} /> No process knowledge warnings in this
          instance.
        </div>
      </section>
    );
  }

  return (
    <section className="rounded-lg border border-amber-500/30 bg-amber-500/10 p-4">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="flex items-center gap-2 text-sm font-medium text-amber-200">
          <AlertTriangle size={15} /> Review warnings
        </h2>
        <span className="chip text-amber-200">{warnings.length}</span>
      </div>
      <ul className={`grid max-h-[520px] grid-cols-1 gap-3 overflow-y-auto pr-1 scrollbar ${compact ? "" : "xl:grid-cols-2"}`}>
        {warnings.map((warning, index) => (
          <li
            key={`${warning.kind}-${warning.assertion_id ?? warning.subject_node_id ?? index}`}
            className="rounded-md border border-amber-500/20 bg-[color:var(--color-surface)]/70 p-3"
          >
            <div className="mb-1 flex items-center justify-between gap-2">
              <span className="font-mono text-[10px] uppercase tracking-wider text-amber-200">
                {warning.kind}
              </span>
              <span className={warning.severity === "high" ? "chip text-rose-300" : "chip text-amber-200"}>
                {warning.severity}
              </span>
            </div>
            <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
              {warning.summary}
            </p>
            <div className="mt-2 flex flex-wrap items-center gap-2 text-[11px] text-[color:var(--color-ink-dim)]">
              {warning.subject_node_id ? (
                <Link
                  className="hover:text-[color:var(--color-rye)]"
                  to={`/nodes/${warning.subject_node_id}`}
                >
                  {warning.scope_label ?? shortId(warning.subject_node_id)}
                </Link>
              ) : null}
              {warning.domain ? <span>{warning.domain}</span> : null}
              {warning.claimed_authority_at ? (
                <span>claim: {warning.claimed_authority_at}</span>
              ) : null}
              {warning.effective_at ? (
                <span>assertion: {fmtDate(warning.effective_at)}</span>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

function ScopePanel({ scopes }: { scopes: KnowledgeMapScope[] }) {
  return (
    <section className="card">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-sm font-medium">Scopes</h2>
        <span className="chip">{fmtNumber(scopes.length)}</span>
      </div>
      <ul className="flex max-h-[520px] flex-col gap-2 overflow-y-auto pr-1 scrollbar">
        {scopes.map((scope) => (
          <li
            key={scope.id}
            className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3"
          >
            <div className="flex items-center justify-between gap-3">
              <Link
                to={`/nodes/${scope.id}`}
                className="min-w-0 truncate text-sm font-medium hover:text-[color:var(--color-rye)]"
                title={scope.label}
              >
                {scope.label}
              </Link>
              <span className="pill shrink-0">{scope.node_type}</span>
            </div>
            <div className="mt-2 flex flex-wrap gap-2 text-[11px] text-[color:var(--color-ink-muted)]">
              <span>{scope.active_policy_count} active</span>
              <span>{scope.superseded_policy_count} superseded</span>
              <span>{scope.candidate_count} candidates</span>
              {scope.owner ? <span>{scope.owner}</span> : null}
            </div>
            {scope.purpose ? (
              <p className="mt-2 line-clamp-2 text-xs leading-5 text-[color:var(--color-ink-dim)]">
                {scope.purpose}
              </p>
            ) : null}
          </li>
        ))}
      </ul>
    </section>
  );
}

function PluginPanel({
  bindings,
}: {
  bindings: {
    assertion_id: string;
    scope_id: string;
    scope_label: string;
    plugin_id: string;
    plugin_label: string | null;
    description: string;
    is_expected_plugin: boolean;
  }[];
}) {
  return (
    <section className="card">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="flex items-center gap-2 text-sm font-medium">
          <Plug size={14} /> Plugins
        </h2>
        <span className="chip">{fmtNumber(bindings.length)}</span>
      </div>
      {bindings.length === 0 ? (
        <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
          No current plugin policy bindings.
        </p>
      ) : (
        <ul className="flex max-h-[520px] flex-col gap-2 overflow-y-auto pr-1 scrollbar">
          {bindings.map((binding) => (
            <li
              key={binding.assertion_id}
              className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3"
            >
              <div className="flex items-center justify-between gap-2">
                <span className="truncate text-sm font-medium">
                  {binding.plugin_label ?? binding.plugin_id}
                </span>
                <span
                  className={
                    binding.is_expected_plugin
                      ? "pill shrink-0"
                      : "chip shrink-0 text-amber-200"
                  }
                >
                  {binding.is_expected_plugin ? binding.plugin_id : "unrecognized"}
                </span>
              </div>
              {!binding.is_expected_plugin ? (
                <div className="mt-1 font-mono text-[11px] text-amber-200">
                  {binding.plugin_id}
                </div>
              ) : null}
              <Link
                to={`/nodes/${binding.scope_id}`}
                className="mt-1 block truncate text-xs text-[color:var(--color-ink-muted)] hover:text-[color:var(--color-rye)]"
              >
                {binding.scope_label}
              </Link>
              {binding.description ? (
                <p className="mt-2 line-clamp-2 text-xs leading-5 text-[color:var(--color-ink-dim)]">
                  {binding.description}
                </p>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function CandidatePanel({
  statuses,
  total,
}: {
  statuses: { status: string; count: number }[];
  total: number;
}) {
  const max = Math.max(1, ...statuses.map((row) => row.count));
  return (
    <section className="card">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-sm font-medium">Candidate Gates</h2>
        <span className="chip">{fmtNumber(total)}</span>
      </div>
      {statuses.length === 0 ? (
        <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
          No candidates in this instance.
        </p>
      ) : (
        <div className="space-y-3">
          {statuses.map((row) => (
            <div key={row.status}>
              <div className="mb-1 flex items-center justify-between text-xs">
                <span className="font-mono">{row.status}</span>
                <span className="num text-[color:var(--color-ink-muted)]">
                  {fmtNumber(row.count)}
                </span>
              </div>
              <div className="h-2 overflow-hidden rounded-full bg-[color:var(--color-surface-3)]">
                <div
                  className="h-full rounded-full bg-[color:var(--color-rye)]"
                  style={{ width: `${(row.count / max) * 100}%` }}
                />
              </div>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

function OperationalPlans({ rows }: { rows: KnowledgeMapOperationalPlan[] }) {
  if (rows.length === 0) {
    return (
      <section className="card">
        <div className="mb-2 flex items-center gap-2">
          <CalendarClock size={14} />
          <h2 className="text-sm font-medium">Operational Plans</h2>
        </div>
        <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
          No current-visible CRM or PM plans are stored for this instance.
        </p>
      </section>
    );
  }

  return (
    <section className="card">
      <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
        <div>
          <h2 className="flex items-center gap-2 text-sm font-medium">
            <CalendarClock size={14} /> Operational Plans
          </h2>
          <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
            Current-visible plan assertions written by CRM and PM scheduling helpers.
          </p>
        </div>
        <span className="chip">{fmtNumber(rows.length)}</span>
      </div>
      <ul className="grid grid-cols-1 gap-3 xl:grid-cols-3">
        {rows.map((row) => (
          <li
            key={row.id}
            className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3"
          >
            <div className="mb-2 flex items-start justify-between gap-3">
              <div className="min-w-0">
                <Link
                  to={`/nodes/${row.subject_node_id}`}
                  className="block truncate text-sm font-medium hover:text-[color:var(--color-rye)]"
                  title={row.subject_label}
                >
                  {row.subject_label}
                </Link>
                <div className="mt-1 font-mono text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                  {planLabel(row.assertion_type)}
                </div>
              </div>
              <span className="pill shrink-0">{fmtDate(row.planned_for)}</span>
            </div>
            <p className="text-xs leading-5 text-[color:var(--color-ink)]">
              {planSummary(row)}
            </p>
            <p className="mt-2 line-clamp-2 text-xs leading-5 text-[color:var(--color-ink-muted)]">
              {planDetail(row)}
            </p>
          </li>
        ))}
      </ul>
    </section>
  );
}

function SummaryTile({
  icon,
  label,
  value,
  sub,
}: {
  icon: React.ReactNode;
  label: string;
  value: number | string;
  sub: string;
}) {
  return (
    <div className="card-flat">
      <div className="mb-3 flex items-center justify-between text-[color:var(--color-ink-dim)]">
        {icon}
        <span className="field-label">{label}</span>
      </div>
      <div className="num text-2xl font-semibold tracking-tight">
        {typeof value === "number" ? fmtNumber(value) : value}
      </div>
      <div className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
        {sub}
      </div>
    </div>
  );
}

function PolicyTable({
  rows,
  mode,
}: {
  rows: KnowledgeMapPolicyRow[];
  mode: "current" | "history";
}) {
  if (rows.length === 0) {
    return (
      <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
        No rows to display.
      </p>
    );
  }

  return (
    <div className="max-h-[720px] overflow-auto scrollbar">
      <table className="min-w-[980px] text-left text-xs">
        <thead className="sticky top-0 z-10 border-b border-[color:var(--color-line-soft)] bg-[color:var(--color-surface)] text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
          <tr>
            <th className="py-2 pr-3 font-medium">Scope</th>
            <th className="py-2 pr-3 font-medium">Knowledge</th>
            <th className="py-2 pr-3 font-medium">Current Meaning</th>
            <th className="py-2 pr-3 font-medium">Window</th>
            <th className="py-2 pr-3 font-medium">Claim Date</th>
            {mode === "history" ? (
              <th className="py-2 pr-3 font-medium">Superseded</th>
            ) : null}
          </tr>
        </thead>
        <tbody className="divide-y divide-[color:var(--color-line-soft)]">
          {rows.map((row) => (
            <tr key={row.id} className="align-top">
              <td className="w-56 py-3 pr-3">
                <Link
                  to={`/nodes/${row.subject_node_id}`}
                  className="block truncate font-medium hover:text-[color:var(--color-rye)]"
                  title={row.scope_label}
                >
                  {row.scope_label}
                </Link>
                <div className="mt-1 font-mono text-[10px] uppercase tracking-wider text-[color:var(--color-ink-dim)]">
                  {row.scope_type}
                </div>
              </td>
              <td className="w-64 py-3 pr-3">
                <div className="font-mono text-[11px] text-[color:var(--color-cyan)]">
                  {policyLabel(row.assertion_type)}
                </div>
                <div className="mt-1 text-[color:var(--color-ink-muted)]">
                  {row.domain ?? row.assertion_key}
                </div>
              </td>
              <td className="py-3 pr-3">
                <div className="font-medium text-[color:var(--color-ink)]">
                  {policySummary(row)}
                </div>
                <div className="mt-1 line-clamp-2 max-w-xl text-[color:var(--color-ink-muted)]">
                  {policyDetail(row)}
                </div>
              </td>
              <td className="w-40 py-3 pr-3 text-[color:var(--color-ink-muted)]">
                <div>{fmtDate(row.effective_at)}</div>
                <div className="mt-1 text-[color:var(--color-ink-dim)]">
                  to {row.effective_to ? fmtDate(row.effective_to) : "current"}
                </div>
              </td>
              <td className="w-44 py-3 pr-3 text-[color:var(--color-ink-muted)]">
                {row.claimed_authority_at ?? "same as assertion"}
              </td>
              {mode === "history" ? (
                <td className="w-36 py-3 pr-3 text-[color:var(--color-ink-muted)]">
                  {fmtDate(row.superseded_at)}
                </td>
              ) : null}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function CandidateSamples({ rows }: { rows: KnowledgeMapCandidateSample[] }) {
  if (rows.length === 0) {
    return (
      <p className="text-xs leading-5 text-[color:var(--color-ink-muted)]">
        No recent candidates.
      </p>
    );
  }

  return (
    <ul className="flex max-h-[680px] flex-col gap-2 overflow-y-auto pr-1 scrollbar">
      {rows.map((row) => (
        <li
          key={row.id}
          className="rounded-md border border-[color:var(--color-line)] bg-[color:var(--color-surface-2)] p-3"
        >
          <div className="mb-2 flex items-center justify-between gap-2">
            <span className="pill">{row.status}</span>
            <span className="font-mono text-[10px] text-[color:var(--color-ink-dim)]">
              {fmtDate(row.created_at)}
            </span>
          </div>
          <div className="line-clamp-3 text-xs leading-5">
            {row.statement ?? row.label ?? shortId(row.id)}
          </div>
          {row.supporting_sources.length > 0 ? (
            <div className="mt-2 flex flex-wrap gap-1.5">
              {row.supporting_sources.slice(0, 3).map((source) => (
                <Link
                  key={`${row.id}-${source.id}`}
                  to={`/nodes/${source.id}`}
                  className="pill max-w-full truncate hover:text-[color:var(--color-rye)]"
                  title={source.label ?? source.id}
                >
                  {source.label ?? shortId(source.id)}
                </Link>
              ))}
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

function MetricChip({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone?: "ok" | "warn";
}) {
  const toneClass =
    tone === "ok"
      ? "text-emerald-300"
      : tone === "warn"
        ? "text-amber-200"
        : "";
  return (
    <span className={`chip ${toneClass}`}>
      {label}: <span className="num">{fmtNumber(value)}</span>
    </span>
  );
}

function KnowledgeMapSkeleton() {
  return (
    <div className="flex flex-col gap-4">
      <div className="h-24 animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
      <div className="grid grid-cols-3 gap-4">
        <div className="h-56 animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
        <div className="h-56 animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
        <div className="h-56 animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
      </div>
      <div className="h-96 animate-pulse rounded-lg bg-[color:var(--color-surface)]" />
    </div>
  );
}

function optionList(values: Array<string | null | undefined>) {
  const unique = Array.from(
    new Set(values.filter((value): value is string => !!value && value.trim().length > 0))
  ).sort((a, b) => formatLensKey(a).localeCompare(formatLensKey(b)));
  return ["all", ...unique];
}

function countRows(
  rows: KnowledgeMapPolicyRow[],
  getKey: (row: KnowledgeMapPolicyRow) => string | null | undefined
) {
  const counts = new Map<string, number>();
  for (const row of rows) {
    const key = getKey(row) ?? "unclassified";
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return Array.from(counts.entries())
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || formatLensKey(a.key).localeCompare(formatLensKey(b.key)));
}

function filterPolicyRows(rows: KnowledgeMapPolicyRow[], filters: PolicyFilters) {
  const search = filters.search.trim().toLowerCase();
  return rows.filter((row) => {
    if (filters.type !== "all" && row.assertion_type !== filters.type) {
      return false;
    }
    const domain = row.domain ?? row.assertion_key;
    if (filters.domain !== "all" && domain !== filters.domain) {
      return false;
    }
    if (!search) return true;
    return policySearchText(row).includes(search);
  });
}

function policySearchText(row: KnowledgeMapPolicyRow) {
  return [
    row.scope_label,
    row.scope_type,
    row.assertion_type,
    row.assertion_key,
    row.domain,
    row.summary_value,
    row.claimed_authority_at,
    policySummary(row),
    policyDetail(row),
    JSON.stringify(row.claim),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
}

function formatLensKey(value: string) {
  return value
    .replace(/^status_domain:/, "")
    .replace(/^process:/, "")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function policyLabel(type: string) {
  switch (type) {
    case "process_document":
      return "process document";
    case "business_policy":
      return "business policy";
    case "source_of_truth_policy":
      return "source of truth";
    case "process_constraint":
      return "constraint";
    case "improvement_cycle":
    case "process_improvement_cycle":
      return "improvement cycle";
    default:
      return type;
  }
}

function policySummary(row: KnowledgeMapPolicyRow) {
  if (row.assertion_type === "process_document") {
    return (
      claimText(row.claim, ["title", "summary"]) ??
      row.summary_value ??
      row.assertion_key
    );
  }
  if (row.assertion_type === "business_policy") {
    return (
      claimText(row.claim, ["policy_key", "policy", "domain"]) ??
      row.summary_value ??
      row.assertion_key
    );
  }
  if (row.assertion_type === "source_of_truth_policy") {
    return (
      claimText(row.claim, ["authoritative_source"]) ??
      row.summary_value ??
      row.assertion_key
    );
  }
  if (row.assertion_type === "process_constraint") {
    return (
      claimText(row.claim, ["constraint", "Identify", "identify", "current_constraint"]) ??
      row.summary_value ??
      row.assertion_key
    );
  }
  if (row.assertion_type.includes("improvement_cycle")) {
    return (
      claimText(row.claim, ["cycle_name", "goal", "identify", "Identify"]) ??
      row.summary_value ??
      row.assertion_key
    );
  }
  return row.summary_value ?? row.assertion_key;
}

function policyDetail(row: KnowledgeMapPolicyRow) {
  if (row.assertion_type === "process_document") {
    return (
      claimText(row.claim, [
        "accepted_steps",
        "branching_or_exceptions",
        "corrected_inferences",
        "summary",
      ]) ?? "No process steps recorded."
    );
  }
  if (row.assertion_type === "business_policy") {
    return (
      claimText(row.claim, ["policy", "affected_domains", "domain"]) ??
      "No business policy detail recorded."
    );
  }
  if (row.assertion_type === "source_of_truth_policy") {
    return (
      claimText(row.claim, ["review_gate", "authoritative_surface", "notes", "supersedes"]) ??
      "No review detail recorded."
    );
  }
  if (row.assertion_type === "process_constraint") {
    return (
      claimText(row.claim, [
        "impact",
        "constraint_location",
        "prior_constraint",
        "evidence",
        "bottleneck_effect",
        "next_constraint",
      ]) ??
      "No constraint detail recorded."
    );
  }
  if (row.assertion_type.includes("improvement_cycle")) {
    return (
      claimText(row.claim, ["exploit", "Exploit", "subordinate", "Subordinate", "repeat", "Repeat"]) ??
      "No cycle steps recorded."
    );
  }
  return claimText(row.claim, ["text", "purpose", "notes"]) ?? "";
}

function planLabel(type: string) {
  switch (type) {
    case "deal_stage_plan":
      return "CRM stage plan";
    case "task_status_plan":
      return "PM task plan";
    case "milestone_status_plan":
      return "PM milestone plan";
    default:
      return type.replace(/_/g, " ");
  }
}

function planSummary(row: KnowledgeMapOperationalPlan) {
  if (row.assertion_type === "deal_stage_plan") {
    return `Planned stage: ${claimText(row.claim, ["planned_stage"]) ?? "unknown"}`;
  }
  if (row.assertion_type === "task_status_plan" || row.assertion_type === "milestone_status_plan") {
    return `Planned status: ${claimText(row.claim, ["planned_status"]) ?? "unknown"}`;
  }
  return claimText(row.claim, ["summary", "status"]) ?? row.assertion_type;
}

function planDetail(row: KnowledgeMapOperationalPlan) {
  const current =
    claimText(row.claim, ["current_stage_at_schedule", "current_status_at_schedule"]) ??
    "unknown current state";
  const reason = claimText(row.claim, ["reason"]) ?? "no reason recorded";
  return `Recorded from ${current}; ${reason}.`;
}

function claimText(claim: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const value = claim[key];
    if (value !== null && value !== undefined && value !== "") {
      return formatClaimValue(value);
    }
  }
  return null;
}

function formatClaimValue(value: unknown): string {
  if (Array.isArray(value)) {
    return value.map((item) => formatClaimValue(item)).join("; ");
  }
  if (value && typeof value === "object") {
    return JSON.stringify(value);
  }
  return String(value);
}
