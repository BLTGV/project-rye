import { useState, type ReactNode } from "react";
import { Link } from "react-router";
import {
  ArrowUpRight,
  CalendarCheck2,
  CalendarClock,
  ClipboardList,
  Flag,
  KanbanSquare,
  MessageSquareWarning,
  OctagonAlert,
  UserRound,
} from "lucide-react";
import {
  usePmWorkspace,
  type PmMilestone,
  type PmTask,
  type WorkspaceCandidate,
  type WorkspacePlan,
  type WorkspaceRelatedItem,
  type WorkspaceSourcePolicy,
} from "../lib/api";
import { fmtDate, fmtNumber } from "../lib/format";

type SelectedWork =
  | { kind: "task"; id: string }
  | { kind: "milestone"; id: string }
  | null;

const STATUS_ORDER = [
  "blocked",
  "backlog",
  "todo",
  "in_progress",
  "ready_for_install",
  "in_review",
  "done",
];

const STATUS_LABELS: Record<string, string> = {
  blocked: "Blocked",
  backlog: "Backlog",
  todo: "To do",
  in_progress: "In progress",
  ready_for_install: "Ready for install",
  in_review: "In review",
  done: "Done",
};

export function ProjectsWorkspacePage() {
  const pm = usePmWorkspace();
  const [selected, setSelected] = useState<SelectedWork>(null);

  if (pm.error) {
    return (
      <div className="card text-rose-300">
        <div className="font-medium">Projects workspace is unavailable.</div>
        <p className="mt-2 text-sm leading-5 text-rose-200/80">
          The local Rye API could not load project, task, and milestone knowledge for this instance.
        </p>
        <div className="mt-3 font-mono text-xs text-rose-200/70">{pm.error.message}</div>
      </div>
    );
  }

  if (!pm.data) return <ProjectsSkeleton />;

  const tasks = pm.data.tasks ?? [];
  const milestones = pm.data.milestones ?? [];
  const firstSelection: SelectedWork =
    tasks[0] ? { kind: "task", id: tasks[0].id } : milestones[0] ? { kind: "milestone", id: milestones[0].id } : null;
  const activeSelection = selected ?? firstSelection;
  const selectedTask =
    activeSelection?.kind === "task" ? tasks.find((task) => task.id === activeSelection.id) ?? null : null;
  const selectedMilestone =
    activeSelection?.kind === "milestone"
      ? milestones.find((milestone) => milestone.id === activeSelection.id) ?? null
      : null;
  const plansBySubject = groupBySubject(pm.data.plans ?? []);
  const candidatesBySubject = groupCandidatesBySubject(pm.data.candidates ?? []);
  const taskGroups = groupTasks(tasks);
  const openTasks = tasks.filter((task) => task.status !== "done").length;
  const blockedTasks = tasks.filter((task) => task.status === "blocked" || toNumber(task.blocker_count) > 0).length;
  const dueSoon = tasks.filter((task) => task.status !== "done" && isDueSoon(task.due_date)).length;
  const futurePlans = (pm.data.plans ?? []).filter((plan) => isFutureDate(planDate(plan))).length;

  return (
    <div className="flex min-h-0 flex-col gap-5">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="mb-2 flex items-center gap-2 text-[10px] uppercase tracking-[0.22em] text-[color:var(--color-ink-dim)]">
            <KanbanSquare size={13} /> Business workspace
          </div>
          <h1 className="text-2xl font-semibold tracking-tight">Projects And Delivery</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-[color:var(--color-ink-muted)]">
            Active work, milestone timing, blockers, owners, planned status changes, and suggested
            updates gathered from connected business sources.
          </p>
        </div>
        <Link to="/review" className="btn h-9 text-xs">
          <MessageSquareWarning size={14} /> Review suggested updates
        </Link>
      </header>

      <section className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <SummaryMetric icon={<ClipboardList size={15} />} label="Open tasks" value={fmtNumber(openTasks)} />
        <SummaryMetric icon={<OctagonAlert size={15} />} label="Blocked" value={fmtNumber(blockedTasks)} tone={blockedTasks > 0 ? "warn" : "ok"} />
        <SummaryMetric icon={<CalendarClock size={15} />} label="Due soon" value={fmtNumber(dueSoon)} tone={dueSoon > 0 ? "warn" : "ok"} />
        <SummaryMetric icon={<Flag size={15} />} label="Milestones" value={fmtNumber(milestones.length)} />
        <SummaryMetric icon={<CalendarCheck2 size={15} />} label="Scheduled changes" value={fmtNumber(futurePlans)} />
      </section>

      {tasks.length === 0 && milestones.length === 0 ? (
        <EmptyWorkspace
          title="No project records found"
          body="This instance does not have current project records in the PM projection yet. Suggested updates can still appear after source intake."
        />
      ) : (
        <section className="grid min-h-0 grid-cols-1 items-start gap-4 xl:grid-cols-[minmax(0,1fr)_390px]">
          <div className="flex min-w-0 flex-col gap-5">
            <MilestoneStrip
              milestones={milestones}
              selectedId={selectedMilestone?.id ?? null}
              onSelect={(id) => setSelected({ kind: "milestone", id })}
            />
            <TaskBoard
              groups={taskGroups}
              selectedId={selectedTask?.id ?? null}
              onSelect={(id) => setSelected({ kind: "task", id })}
            />
          </div>
          <ProjectDetailPanel
            task={selectedTask}
            milestone={selectedMilestone}
            plans={
              activeSelection
                ? plansBySubject.get(activeSelection.id) ?? []
                : []
            }
            candidates={
              activeSelection
                ? candidatesBySubject.get(activeSelection.id) ?? []
                : []
            }
            sourcePolicies={pm.data.source_policies ?? []}
          />
        </section>
      )}
    </div>
  );
}

function MilestoneStrip({
  milestones,
  selectedId,
  onSelect,
}: {
  milestones: PmMilestone[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  return (
    <section>
      <div className="mb-3 flex items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-medium">Milestones</h2>
          <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
            Target dates and major delivery commitments. Select one for context and source-backed updates.
          </p>
        </div>
        <span className="chip">{fmtNumber(milestones.length)}</span>
      </div>
      {milestones.length === 0 ? (
        <div className="rounded-lg border border-dashed border-[color:var(--color-line)] bg-[color:var(--color-surface)] px-4 py-8 text-center text-sm text-[color:var(--color-ink-muted)]">
          No milestones are recorded.
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2 2xl:grid-cols-4">
          {milestones.map((milestone) => (
            <button
              key={milestone.id}
              type="button"
              onClick={() => onSelect(milestone.id)}
              className={[
                "rounded-lg border bg-[color:var(--color-surface)] p-4 text-left transition",
                selectedId === milestone.id
                  ? "border-[color:var(--color-rye)]"
                  : "border-[color:var(--color-line)] hover:border-[color:var(--color-rye)]",
              ].join(" ")}
            >
              <div className="mb-2 flex items-center justify-between gap-2">
                <span className="chip">{milestoneStatusLabel(milestone.status)}</span>
                <span className="text-xs text-[color:var(--color-ink-muted)]">{fmtDate(milestone.target_date)}</span>
              </div>
              <div className="line-clamp-2 text-sm font-medium">{milestone.name ?? milestone.label}</div>
              <div className="mt-2 text-xs text-[color:var(--color-ink-muted)]">
                Owner: {milestone.owner_name ?? "Unassigned"}
              </div>
            </button>
          ))}
        </div>
      )}
    </section>
  );
}

function TaskBoard({
  groups,
  selectedId,
  onSelect,
}: {
  groups: { key: string; label: string; tasks: PmTask[] }[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  return (
    <section className="min-w-0">
      <div className="mb-3 flex items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-medium">Task Board</h2>
          <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
            Current work by status. Blocked and due-soon items stay visible at the top of the workflow.
          </p>
        </div>
      </div>
      <div className="grid auto-cols-[minmax(300px,360px)] grid-flow-col gap-3 overflow-x-auto pb-2 scrollbar">
        {groups.map((group) => (
          <div
            key={group.key}
            className="flex max-h-[calc(100vh-28rem)] min-h-[220px] flex-col rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)]"
          >
            <div className="flex items-center justify-between border-b border-[color:var(--color-line-soft)] px-4 py-3">
              <h3 className="text-sm font-medium">{group.label}</h3>
              <span className="chip">{fmtNumber(group.tasks.length)}</span>
            </div>
            <div className="flex flex-1 flex-col gap-2 overflow-y-auto p-3 scrollbar">
              {group.tasks.length === 0 ? (
                <div className="rounded-md border border-dashed border-[color:var(--color-line)] px-3 py-8 text-center text-xs text-[color:var(--color-ink-dim)]">
                  No tasks
                </div>
              ) : (
                group.tasks.map((task) => (
                  <TaskCard
                    key={task.id}
                    task={task}
                    selected={selectedId === task.id}
                    onSelect={() => onSelect(task.id)}
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

function TaskCard({ task, selected, onSelect }: { task: PmTask; selected: boolean; onSelect: () => void }) {
  const blocked = task.status === "blocked" || toNumber(task.blocker_count) > 0;
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
          <div className="line-clamp-2 text-sm font-medium text-[color:var(--color-ink)]">{task.title}</div>
          <div className="mt-1 truncate text-xs text-[color:var(--color-ink-muted)]">
            {task.project_name ?? "No project"} · {task.code ?? "No code"}
          </div>
        </div>
        {blocked ? <OctagonAlert size={16} className="shrink-0 text-amber-300" /> : null}
      </div>
      <div className="mt-3 grid grid-cols-2 gap-2 text-xs text-[color:var(--color-ink-muted)]">
        <span className="truncate">Owner: {task.owner_name ?? "Unassigned"}</span>
        <span className="truncate text-right">Due: {fmtDate(task.due_date)}</span>
      </div>
      <div className="mt-2 flex flex-wrap gap-1.5">
        {task.priority ? <span className="pill">{humanize(task.priority)}</span> : null}
        {toNumber(task.blocker_count) > 0 ? <span className="pill text-amber-300">{fmtNumber(toNumber(task.blocker_count))} blocker</span> : null}
        {toNumber(task.subtask_count) > 0 ? <span className="pill">{fmtNumber(toNumber(task.subtask_count))} subtasks</span> : null}
      </div>
    </button>
  );
}

function ProjectDetailPanel({
  task,
  milestone,
  plans,
  candidates,
  sourcePolicies,
}: {
  task: PmTask | null;
  milestone: PmMilestone | null;
  plans: WorkspacePlan[];
  candidates: WorkspaceCandidate[];
  sourcePolicies: WorkspaceSourcePolicy[];
}) {
  if (!task && !milestone) {
    return (
      <aside className="card self-start text-sm text-[color:var(--color-ink-muted)]">
        Select a task or milestone to see details.
      </aside>
    );
  }

  const id = task?.id ?? milestone!.id;
  const title = task?.title ?? milestone?.name ?? milestone?.label ?? "Selected work";
  const status = task?.status ?? milestone?.status ?? null;
  const owner = task?.owner_name ?? milestone?.owner_name ?? "Unassigned";
  const dueDate = task?.due_date ?? milestone?.target_date ?? null;
  const relatedItems = task?.related_items ?? milestone?.related_items ?? [];
  const people = relatedItems.filter((item) => item.node_type === "person");
  const otherLinks = relatedItems.filter((item) => item.node_type !== "person");

  return (
    <aside className="sticky top-20 flex max-h-[calc(100vh-6rem)] min-w-0 flex-col overflow-y-auto rounded-lg border border-[color:var(--color-line)] bg-[color:var(--color-surface)] p-5 scrollbar">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="mb-2 flex flex-wrap gap-2">
            <span className="chip">{task ? "Task" : "Milestone"}</span>
            <span className="chip">{task?.code ?? milestone?.code ?? "No code"}</span>
            <span className="chip">{statusLabel(status)}</span>
          </div>
          <h2 className="text-lg font-semibold leading-6">{title}</h2>
          <p className="mt-1 text-xs text-[color:var(--color-ink-muted)]">
            {task?.project_name ?? "Delivery work"} {task?.sprint_name ? `· ${task.sprint_name}` : ""}
          </p>
        </div>
        <Link to={`/nodes/${id}`} className="btn h-8 shrink-0 text-xs">
          <ArrowUpRight size={13} /> Record
        </Link>
      </div>

      <div className="mt-5 grid grid-cols-2 gap-3">
        <DetailStat label="Owner" value={owner} icon={<UserRound size={13} />} />
        <DetailStat label={task ? "Due date" : "Target date"} value={fmtDate(dueDate)} icon={<CalendarClock size={13} />} />
        <DetailStat label="Priority" value={task?.priority ? humanize(task.priority) : milestone?.priority ? humanize(milestone.priority) : "Not set"} />
        <DetailStat label="Reviewer" value={task?.reviewer_name ?? "Not set"} />
      </div>

      {task ? (
        <DetailBlock title="Delivery Signals">
          <div className="grid grid-cols-2 gap-3">
            <DetailStat label="Blockers" value={fmtNumber(toNumber(task.blocker_count))} />
            <DetailStat label="Subtasks" value={fmtNumber(toNumber(task.subtask_count))} />
          </div>
        </DetailBlock>
      ) : null}

      <DetailBlock title="People">
        <RelatedList items={people} empty="No people are linked yet." />
      </DetailBlock>

      <DetailBlock title="Related Work And Dependencies">
        <RelatedList items={otherLinks} empty="No related work or dependencies are linked yet." />
      </DetailBlock>

      <DetailBlock title="Scheduled Changes">
        {plans.length === 0 ? (
          <EmptyInline>No planned status changes are recorded.</EmptyInline>
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

function DetailStat({ label, value, icon }: { label: string; value: string; icon?: ReactNode }) {
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

function DetailBlock({ title, children }: { title: string; children: ReactNode }) {
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
  if (candidates.length === 0) return <EmptyInline>No source-based suggestions are waiting for this item.</EmptyInline>;
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
  if (policies.length === 0) return <EmptyInline>No explicit project source rules are recorded.</EmptyInline>;
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

function ProjectsSkeleton() {
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

function groupTasks(tasks: PmTask[]) {
  const known = new Map(STATUS_ORDER.map((status) => [status, [] as PmTask[]]));
  const other: PmTask[] = [];
  for (const task of tasks) {
    const key = task.status ?? "unknown";
    if (known.has(key)) {
      known.get(key)!.push(task);
    } else {
      other.push(task);
    }
  }
  const groups = STATUS_ORDER.map((status) => ({
    key: status,
    label: statusLabel(status),
    tasks: known.get(status) ?? [],
  }));
  if (other.length > 0) groups.push({ key: "other", label: "Other", tasks: other });
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
  for (const key of ["task_id", "taskId", "milestone_id", "milestoneId", "subject_id", "subjectNodeId"]) {
    const value = payload[key];
    if (typeof value === "string") ids.add(value);
  }
  const nested = asRecord(payload.target_payload);
  for (const key of ["task_id", "taskId", "milestone_id", "milestoneId", "subject_id", "subjectNodeId"]) {
    const value = nested[key];
    if (typeof value === "string") ids.add(value);
  }
  return [...ids];
}

function statusLabel(status: string | null | undefined) {
  if (!status) return "Unknown";
  return STATUS_LABELS[status] ?? humanize(status);
}

function milestoneStatusLabel(status: string | null | undefined) {
  if (!status) return "No status";
  return humanize(status);
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

function isFutureDate(value: string | null | undefined) {
  if (!value) return false;
  return new Date(value).getTime() > Date.now();
}

function isDueSoon(value: string | null | undefined) {
  if (!value) return false;
  const due = new Date(value).getTime();
  const now = Date.now();
  const twoWeeks = 14 * 24 * 60 * 60 * 1000;
  return due <= now + twoWeeks;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function relationshipLabel(item: WorkspaceRelatedItem) {
  return humanize(item.role ?? item.relationship ?? item.dependency_type ?? item.relation ?? item.node_type);
}

function candidateStatement(candidate: WorkspaceCandidate) {
  return candidate.properties.statement ?? candidate.label ?? "Suggested update";
}

function planSummary(plan: WorkspacePlan) {
  const claim = asRecord(plan.claim);
  const status = claim.planned_status ?? claim.status ?? claim.next_status ?? claim.stage;
  const reason = claim.reason;
  if (typeof status === "string" && typeof reason === "string") {
    return `${humanize(status)}: ${reason}`;
  }
  if (typeof status === "string") return `Move to ${humanize(status)}`;
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
