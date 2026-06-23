const workspaceConfig = readWorkspaceConfig();

const state = {
  instance: workspaceConfig.defaultInstance,
  instances: [],
  crm: null,
  pm: null,
  reviews: [],
  activeReviewId: null,
  activeSalesId: null,
  activeProjectId: null,
  reviewFilter: "all",
};

const els = {
  instanceSelect: document.querySelector("#instanceSelect"),
  refreshButton: document.querySelector("#refreshButton"),
  summaryGrid: document.querySelector("#summaryGrid"),
  reviewCount: document.querySelector("#reviewCount"),
  reviewQueue: document.querySelector("#reviewQueue"),
  decisionPanel: document.querySelector("#decisionPanel"),
  crmPipeline: document.querySelector("#crmPipeline"),
  crmProposals: document.querySelector("#crmProposals"),
  crmDetail: document.querySelector("#crmDetail"),
  crmUpdated: document.querySelector("#crmUpdated"),
  pmBoard: document.querySelector("#pmBoard"),
  pmProposals: document.querySelector("#pmProposals"),
  pmDetail: document.querySelector("#pmDetail"),
  pmUpdated: document.querySelector("#pmUpdated"),
  milestones: document.querySelector("#milestones"),
  timelineList: document.querySelector("#timelineList"),
  sourceList: document.querySelector("#sourceList"),
  toast: document.querySelector("#toast"),
};

document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => switchView(tab.dataset.view));
});

document.addEventListener("click", async (event) => {
  const button = event.target.closest("button");
  if (!button) return;

  if (button.dataset.filter) {
    state.reviewFilter = button.dataset.filter;
    renderReviewInbox();
    return;
  }

  if (button.dataset.selectReview) {
    state.activeReviewId = button.dataset.selectReview;
    switchView("review");
    renderReviewInbox();
    return;
  }

  if (button.dataset.selectSales) {
    state.activeSalesId = button.dataset.selectSales;
    renderCrm();
    return;
  }

  if (button.dataset.selectProject) {
    state.activeProjectId = button.dataset.selectProject;
    renderPm();
    return;
  }

  if (button.dataset.action) {
    await saveDecision(button);
  }
});

els.refreshButton.addEventListener("click", () => loadWorkspace());
els.instanceSelect.addEventListener("change", () => {
  state.instance = els.instanceSelect.value;
  state.activeReviewId = null;
  state.activeSalesId = null;
  state.activeProjectId = null;
  const url = new URL(window.location.href);
  url.searchParams.set("instance", state.instance);
  window.history.replaceState({}, "", url);
  loadWorkspace();
});

await init();

async function init() {
  const instances = await apiGet("/instances", false);
  state.instances = instances.instances ?? [];
  const requestedInstance = new URLSearchParams(window.location.search).get("instance");
  state.instance = [requestedInstance, workspaceConfig.defaultInstance, instances.default, state.instances[0]?.id]
    .find((id) => id && state.instances.some((item) => item.id === id))
    ?? "";
  els.instanceSelect.innerHTML = state.instances
    .map((item) => `<option value="${escapeHtml(item.id)}">${escapeHtml(businessInstanceLabel(item))}</option>`)
    .join("");
  els.instanceSelect.disabled = state.instances.length === 0;
  els.instanceSelect.value = state.instance;
  if (!state.instance) {
    renderUnavailable("No Rye instances are configured for this workspace.");
    return;
  }
  await loadWorkspace();
  switchView(initialView());
}

function readWorkspaceConfig() {
  const params = new URLSearchParams(window.location.search);
  const config = window.RYE_WORKSPACE_CONFIG ?? {};
  const metaApiBase = document.querySelector('meta[name="rye-api-base"]')?.content ?? "";
  const metaDefaultInstance = document.querySelector('meta[name="rye-default-instance"]')?.content ?? "";

  return {
    apiBase: normalizeApiBase(
      params.get("api") || config.apiBase || metaApiBase || "/api"
    ),
    defaultInstance:
      params.get("default_instance") ||
      params.get("defaultInstance") ||
      config.defaultInstance ||
      metaDefaultInstance ||
      "",
  };
}

function normalizeApiBase(value) {
  return String(value || "/api").trim().replace(/\/+$/, "") || "/api";
}

function apiUrl(path) {
  return new URL(`${workspaceConfig.apiBase}${path}`, window.location.origin);
}

function renderUnavailable(message) {
  els.summaryGrid.innerHTML = metric("Instances", 0);
  els.reviewQueue.innerHTML = emptyBlock(message);
  els.decisionPanel.innerHTML = emptyDecision();
  els.crmPipeline.innerHTML = emptyBlock(message);
  els.crmDetail.innerHTML = emptyBlock(message);
  els.pmBoard.innerHTML = emptyBlock(message);
  els.pmDetail.innerHTML = emptyBlock(message);
  els.timelineList.innerHTML = emptyBlock(message);
  els.sourceList.innerHTML = emptyBlock(message);
  toast(message);
}

async function loadWorkspace() {
  try {
    const [crm, pm] = await Promise.all([
      apiGet("/workspace/crm"),
      apiGet("/workspace/pm"),
    ]);
    state.crm = crm;
    state.pm = pm;
    state.reviews = buildReviewItems();
    if (!state.reviews.some((item) => item.id === state.activeReviewId)) {
      state.activeReviewId = state.reviews[0]?.id ?? null;
    }
    if (!state.activeSalesId || !(state.crm?.opportunities ?? []).some((item) => item.id === state.activeSalesId)) {
      state.activeSalesId = state.crm?.opportunities?.[0]?.id ?? null;
    }
    const projectItems = [...(state.pm?.tasks ?? []), ...(state.pm?.milestones ?? [])];
    if (!state.activeProjectId || !projectItems.some((item) => item.id === state.activeProjectId)) {
      state.activeProjectId = projectItems[0]?.id ?? null;
    }
    render();
    toast("Workspace refreshed");
  } catch (error) {
    toast(error.message || String(error));
  }
}

function render() {
  renderSummary();
  renderReviewInbox();
  renderCrm();
  renderPm();
  renderTimeline();
  renderSources();
}

function renderSummary() {
  const ready = state.reviews.filter((item) => item.action).length;
  const needsRouting = state.reviews.filter((item) => !item.action).length;
  const futurePlans = (state.crm?.plans?.length ?? 0) + (state.pm?.plans?.length ?? 0);
  const futureCandidates = state.reviews.filter((item) => item.effectiveAt).length;
  els.summaryGrid.innerHTML = [
    metric("Items to review", state.reviews.length),
    metric("Can approve now", ready),
    metric("Scheduled changes", futurePlans + futureCandidates),
    metric("Need clarification", needsRouting),
  ].join("");
}

function renderReviewInbox() {
  document.querySelectorAll(".queue-filter").forEach((button) => {
    button.classList.toggle("active", button.dataset.filter === state.reviewFilter);
  });

  const visible = filteredReviews();
  els.reviewCount.textContent = `${visible.length} shown`;
  els.reviewQueue.innerHTML = visible.length
    ? visible.map((item) => reviewQueueItem(item)).join("")
    : emptyBlock("No items match this filter.");

  const active = state.reviews.find((item) => item.id === state.activeReviewId) ?? visible[0] ?? state.reviews[0];
  if (active && state.activeReviewId !== active.id) state.activeReviewId = active.id;
  els.decisionPanel.innerHTML = active ? decisionDetail(active) : emptyDecision();
}

function renderCrm() {
  const opportunities = state.crm?.opportunities ?? [];
  const plansBySubject = groupBy(state.crm?.plans ?? [], "subject_id");
  const businessPlansBySubject = Object.fromEntries(
    Object.entries(plansBySubject).map(([key, rows]) => [key, rows.filter((plan) => !isSmokePlan(plan))])
  );
  els.crmUpdated.textContent = state.crm?.generated_at ? `updated ${formatDate(state.crm.generated_at)}` : "";
  els.crmPipeline.innerHTML = opportunities.length
    ? `<div class="business-list cols-3">
        ${businessListHeader(["Opportunity", "Today", "Next planned change"])}
        ${opportunities.map((opp) => opportunityListItem(opp, businessPlansBySubject[opp.id] ?? [])).join("")}
      </div>`
    : emptyBlock("No sales opportunities found.");

  const selected = opportunities.find((opp) => opp.id === state.activeSalesId) ?? opportunities[0] ?? null;
  if (selected && state.activeSalesId !== selected.id) state.activeSalesId = selected.id;
  els.crmDetail.innerHTML = selected
    ? salesDetail(selected, businessPlansBySubject[selected.id] ?? [])
    : emptyBlock("No sales opportunities found.");
}

function renderPm() {
  const tasks = state.pm?.tasks ?? [];
  const milestones = (state.pm?.milestones ?? [])
    .filter((milestone) => !String(milestone.code || milestone.name || "").startsWith("GUIDED-SMOKE"));
  const plansBySubject = groupBy(state.pm?.plans ?? [], "subject_id");
  const businessPlansBySubject = Object.fromEntries(
    Object.entries(plansBySubject).map(([key, rows]) => [key, rows.filter((plan) => !isSmokePlan(plan))])
  );
  els.pmUpdated.textContent = state.pm?.generated_at ? `updated ${formatDate(state.pm.generated_at)}` : "";
  const rows = [
    ...tasks.map((task) => taskListItem(task, businessPlansBySubject[task.id] ?? [])),
    ...milestones.map((milestone) => milestoneListItem(milestone, businessPlansBySubject[milestone.id] ?? [])),
  ];
  els.pmBoard.innerHTML = rows.length
    ? `<div class="business-list cols-3">
        ${businessListHeader(["Work item", "Today", "Next planned change"])}
        ${rows.join("")}
      </div>`
    : emptyBlock("No project work found.");
  els.milestones.innerHTML = "";

  const projectItems = [...tasks, ...milestones];
  const selected = projectItems.find((item) => item.id === state.activeProjectId) ?? projectItems[0] ?? null;
  if (selected && state.activeProjectId !== selected.id) state.activeProjectId = selected.id;
  els.pmDetail.innerHTML = selected
    ? projectDetail(selected, businessPlansBySubject[selected.id] ?? [])
    : emptyBlock("No project work found.");
}

function renderTimeline() {
  const items = buildTimelineItems();
  els.timelineList.innerHTML = items.length
    ? items.map(timelineItem).join("")
    : emptyBlock("No upcoming changes found.");
}

function renderSources() {
  const policies = [
    ...(state.crm?.source_policies ?? []).map((item) => ({ ...item, area: "CRM" })),
    ...(state.pm?.source_policies ?? []).map((item) => ({ ...item, area: "PM" })),
  ];
  const grouped = groupBy(policies, (policy) => policy.claim?.status_domain || policy.assertion_key || "unknown");
  els.sourceList.innerHTML = Object.entries(grouped).length
    ? Object.entries(grouped).map(([domain, rows]) => sourceDomainCard(domain, rows)).join("")
    : emptyBlock("No system rules found.");
}

function buildReviewItems() {
  const byId = new Map();
  const crmCandidates = state.crm?.candidates ?? [];
  const pmCandidates = state.pm?.candidates ?? [];
  const opportunities = state.crm?.opportunities ?? [];
  const tasks = state.pm?.tasks ?? [];
  const milestones = state.pm?.milestones ?? [];

  crmCandidates.forEach((candidate) => {
    const draft = detectCrmCandidate(candidate, opportunities, state.crm?.source_policies ?? []);
    mergeReview(byId, candidate, "CRM", draft);
  });

  pmCandidates.forEach((candidate) => {
    const draft = detectPmCandidate(candidate, tasks, milestones, state.pm?.source_policies ?? []);
    mergeReview(byId, candidate, "PM", draft);
  });

  return [...byId.values()].sort(compareReviews);
}

function mergeReview(map, candidate, domain, draft) {
  const existing = map.get(candidate.id);
  if (existing) {
    if (!existing.domains.includes(domain)) existing.domains.push(domain);
    if (!existing.action && draft?.action) applyDraft(existing, draft);
    if (draft?.effectiveAt && !existing.effectiveAt) existing.effectiveAt = draft.effectiveAt;
    existing.sortScore = reviewSortScore(existing);
    return;
  }

  const item = {
    id: candidate.id,
    candidate,
    domains: [domain],
    status: candidate.status || "proposed",
    statement: candidateStatement(candidate),
    confidence: candidate.properties?.confidence,
    createdBy: candidate.properties?.created_by || "unknown agent",
    createdAt: candidate.created_at,
    sourceDoc: sourceDocKey(candidate),
    kind: draft?.kind || readableCandidateKind(candidate),
    title: draft?.summary || plainStatementTitle(candidateStatement(candidate)),
    record: draft?.record || "General business process",
    currentValue: draft?.currentValue || "Not clear yet",
    proposedValue: draft?.proposedValue || "Needs a person to interpret it",
    effectiveAt: draft?.effectiveAt || null,
    condition: draft?.condition || conditionFrom(candidateStatement(candidate)),
    impact: draft?.impact || "This note may be useful, but it is not specific enough to approve as an official sales or project change yet.",
    evidence: reviewEvidence(candidate, draft),
    questions: reviewQuestions(candidate),
    action: null,
    actionLabel: null,
    payload: null,
    formType: null,
  };
  if (draft) applyDraft(item, draft);
  item.sortScore = reviewSortScore(item);
  map.set(candidate.id, item);
}

function applyDraft(item, draft) {
  item.kind = draft.kind || item.kind;
  item.title = draft.summary || item.title;
  item.record = draft.record || item.record;
  item.currentValue = draft.currentValue || item.currentValue;
  item.proposedValue = draft.proposedValue || item.proposedValue;
  item.effectiveAt = draft.effectiveAt || item.effectiveAt;
  item.condition = draft.condition || item.condition;
  item.impact = draft.impact || item.impact;
  item.action = draft.action || item.action;
  item.actionLabel = draft.label || item.actionLabel;
  item.payload = draft.payload || item.payload;
  item.formType = draft.formType || item.formType;
  item.evidence = uniqueText([...(item.evidence ?? []), ...(draft.evidence ?? [])]);
}

function detectCrmCandidate(candidate, opportunities, policies) {
  const statement = candidateStatement(candidate);
  const identifiers = identifiersFor(candidate);
  const payload = targetPayload(candidate);
  const payloadOpp = findOpportunityForCandidate(candidate, opportunities);
  const payloadStage = payload.planned_stage || payload.stage || payload.plannedStage;
  const payloadEffectiveAt = payload.effective_at || payload.effectiveAt;
  if (payloadOpp && isPendingDecision(statement)) {
    const subject = opportunityName(payloadOpp);
    return {
      kind: "Sales decision",
      summary: pendingDecisionTitle(statement),
      record: subject,
      currentValue: "Waiting on a customer or team answer",
      proposedValue: "Do not treat this as final until the answer is confirmed",
      condition: conditionFrom(statement),
      impact: `This keeps ${subject} visible in the sales dashboard while marking the unresolved answer as follow-up, not official status.`,
      evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
    };
  }
  if (payloadOpp && payloadStage && payloadEffectiveAt) {
    const condition = conditionFrom(statement);
    const subject = opportunityName(payloadOpp);
    return {
      kind: "Sales opportunity update",
      summary: `${subject} should move to ${plainValue(payloadStage)} on ${businessDate(payloadEffectiveAt)}.`,
      record: subject,
      currentValue: plainValue(payloadOpp.stage || "unknown"),
      proposedValue: plainValue(payloadStage),
      effectiveAt: payloadEffectiveAt,
      condition,
      impact: `Approving this keeps the sales opportunity at ${plainValue(payloadOpp.stage || "unknown")} today. Starting ${businessDate(payloadEffectiveAt)}, reports and assistants should treat it as ${plainValue(payloadStage)} if the condition is satisfied.`,
      evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
      action: "accept_crm_stage_plan",
      label: "Approve change",
      formType: "crm_stage_plan",
      payload: {
        opportunity_id: payloadOpp.id,
        stage: payloadStage,
        effective_at: payloadEffectiveAt,
        reason: condition || `Accepted from CRM workspace candidate ${shortId(candidate.id)}.`,
        actor: "crm-pm-workspace",
        plan_properties: { candidate_statement: statement },
      },
    };
  }

  const oppCode = identifiers.find((id) => /^BW-OPP-/i.test(id)) ?? statement.match(/\b[A-Z]+-OPP-\d+\b/i)?.[0];
  if (oppCode) {
    const opp = opportunities.find((item) => item.code?.toLowerCase() === oppCode.toLowerCase());
    const stage = plannedValue(statement, identifiers);
    const effectiveAt = isoDate(statement, identifiers);
    if (opp && stage && effectiveAt) {
      const condition = conditionFrom(statement);
      const subject = businessSubject(statement, "sales_opportunity");
      return {
        kind: "Sales opportunity update",
        summary: `${subject} should move to ${plainValue(stage)} on ${businessDate(effectiveAt)}.`,
        record: subject,
        currentValue: plainValue(opp.stage || "unknown"),
        proposedValue: plainValue(stage),
        effectiveAt,
        condition,
        impact: `Approving this keeps the sales opportunity at ${plainValue(opp.stage || "unknown")} today. Starting ${businessDate(effectiveAt)}, reports and assistants should treat it as ${plainValue(stage)} if the condition is satisfied.`,
        evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
        action: "accept_crm_stage_plan",
        label: "Approve change",
        formType: "crm_stage_plan",
        payload: {
          opportunity_id: opp.id,
          stage,
          effective_at: effectiveAt,
          reason: condition || `Accepted from CRM workspace candidate ${shortId(candidate.id)}.`,
          actor: "crm-pm-workspace",
          plan_properties: { candidate_statement: statement },
        },
      };
    }
  }

  const domains = identifiers.filter(isDomainIdentifier).filter((id) =>
    ["deal_stage", "sales_next_action"].includes(id)
  );
  if (domains.length) {
    const context = candidate.review_contexts?.[0];
    const source = identifiers.find((id) => !isDomainIdentifier(id) && !isIsoDate(id)) ?? leadingName(statement);
    const supersedes = statement.match(/\breplace\s+(.+?)\s+as\s+(?:the\s+)?source\b/i)?.[1]?.trim() ?? currentSourceFor(policies, domains);
    const effectiveAt = isoDate(statement, identifiers);
    if (context?.id && source) {
      const domainText = businessDomainList(domains);
      const currentSource = currentSourceFor(policies, domains) || supersedes || "the current system";
      return {
        kind: "Sales system change",
        summary: `${source} should become the place to check ${domainText}${effectiveAt ? ` on ${businessDate(effectiveAt)}` : ""}.`,
        record: "Sales system rules",
        currentValue: currentSource,
        proposedValue: `${source} for ${domainText}`,
        effectiveAt,
        condition: "after the system change is reviewed and confirmed",
        impact: `Approving this means people and assistants should use ${source} for ${domainText} starting ${businessDate(effectiveAt)}. Before then, they should keep using ${currentSource}.`,
        evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
        action: "accept_source_policy",
        label: "Approve system change",
        formType: "source_policy",
        payload: {
          scope_id: context.id,
          status_domains: domains,
          authoritative_source: source,
          effective_at: effectiveAt,
          review_gate: "review required before authority",
          evidence_allowed: ["reviewed source observation", "owner confirmation"],
          supersedes,
          notes: statement,
          actor: "crm-pm-workspace",
        },
      };
    }
  }

  return null;
}

function detectPmCandidate(candidate, tasks, milestones, policies) {
  const statement = candidateStatement(candidate);
  const identifiers = identifiersFor(candidate);
  const payload = targetPayload(candidate);
  const payloadTask = findTaskForCandidate(candidate, tasks);
  const payloadMilestone = findMilestoneForCandidate(candidate, milestones);
  const payloadStatus = payload.planned_status || payload.status || payload.plannedStatus;
  const payloadEffectiveAt = payload.effective_at || payload.effectiveAt;
  if ((payloadTask || payloadMilestone) && isPendingDecision(statement)) {
    const subject = payloadTask ? taskName(payloadTask) : milestoneName(payloadMilestone);
    return {
      kind: payloadTask ? "Project task decision" : "Project milestone decision",
      summary: pendingDecisionTitle(statement),
      record: subject,
      currentValue: "Waiting on a customer, vendor, or site answer",
      proposedValue: "Do not treat this as complete until the answer is confirmed",
      condition: conditionFrom(statement),
      impact: `This keeps ${subject} visible in the project dashboard while marking the unresolved answer as follow-up, not official status.`,
      evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
    };
  }
  if (payloadTask && payloadStatus && payloadEffectiveAt) {
    const condition = conditionFrom(statement);
    const subject = taskName(payloadTask);
    return {
      kind: "Project task update",
      summary: `${subject} should move to ${plainValue(payloadStatus)} on ${businessDate(payloadEffectiveAt)}.`,
      record: subject,
      currentValue: plainValue(payloadTask.status || "unknown"),
      proposedValue: plainValue(payloadStatus),
      effectiveAt: payloadEffectiveAt,
      condition,
      impact: `Approving this keeps the task at ${plainValue(payloadTask.status || "unknown")} today. Starting ${businessDate(payloadEffectiveAt)}, project updates should treat it as ${plainValue(payloadStatus)} if the condition is satisfied.`,
      evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
      action: "accept_pm_task_plan",
      label: "Approve change",
      formType: "pm_status_plan",
      payload: {
        task_id: payloadTask.id,
        status: payloadStatus,
        effective_at: payloadEffectiveAt,
        reason: condition || `Accepted from PM workspace candidate ${shortId(candidate.id)}.`,
        actor: "crm-pm-workspace",
        plan_properties: { candidate_statement: statement },
      },
    };
  }

  if (payloadMilestone && payloadStatus && payloadEffectiveAt) {
    const condition = conditionFrom(statement);
    const subject = milestoneName(payloadMilestone);
    return {
      kind: "Project milestone update",
      summary: `${subject} should move to ${plainValue(payloadStatus)} on ${businessDate(payloadEffectiveAt)}.`,
      record: subject,
      currentValue: plainValue(payloadMilestone.status || "unknown"),
      proposedValue: plainValue(payloadStatus),
      effectiveAt: payloadEffectiveAt,
      condition,
      impact: `Approving this keeps the milestone at ${plainValue(payloadMilestone.status || "unknown")} today. Starting ${businessDate(payloadEffectiveAt)}, project updates should treat it as ${plainValue(payloadStatus)} if the condition is satisfied.`,
      evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
      action: "accept_pm_milestone_plan",
      label: "Approve change",
      formType: "pm_status_plan",
      payload: {
        milestone_id: payloadMilestone.id,
        status: payloadStatus,
        effective_at: payloadEffectiveAt,
        reason: condition || `Accepted from PM workspace candidate ${shortId(candidate.id)}.`,
        actor: "crm-pm-workspace",
        plan_properties: { candidate_statement: statement },
      },
    };
  }

  const taskCode = identifiers.find((id) => /^BW-TSK-/i.test(id)) ?? statement.match(/\b[A-Z]+-TSK-\d+\b/i)?.[0];
  if (taskCode) {
    const task = tasks.find((item) => item.code?.toLowerCase() === taskCode.toLowerCase());
    const status = plannedValue(statement, identifiers);
    const effectiveAt = isoDate(statement, identifiers);
    if (task && status && effectiveAt) {
      const condition = conditionFrom(statement);
      const subject = businessSubject(statement, "project_task");
      return {
        kind: "Project task update",
        summary: `${subject} should move to ${plainValue(status)} on ${businessDate(effectiveAt)}.`,
        record: subject,
        currentValue: plainValue(task.status || "unknown"),
        proposedValue: plainValue(status),
        effectiveAt,
        condition,
        impact: `Approving this keeps the task at ${plainValue(task.status || "unknown")} today. Starting ${businessDate(effectiveAt)}, project updates should treat it as ${plainValue(status)} if the condition is satisfied.`,
        evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
        action: "accept_pm_task_plan",
        label: "Approve change",
        formType: "pm_status_plan",
        payload: {
          task_id: task.id,
          status,
          effective_at: effectiveAt,
          reason: condition || `Accepted from PM workspace candidate ${shortId(candidate.id)}.`,
          actor: "crm-pm-workspace",
          plan_properties: { candidate_statement: statement },
        },
      };
    }
  }

  const milestoneCode = identifiers.find((id) => /^BW-MIL-/i.test(id)) ?? statement.match(/\b[A-Z]+-MIL-\d+\b/i)?.[0];
  if (milestoneCode) {
    const milestone = milestones.find((item) => item.code?.toLowerCase() === milestoneCode.toLowerCase());
    const status = plannedValue(statement, identifiers);
    const effectiveAt = isoDate(statement, identifiers);
    if (milestone && status && effectiveAt) {
      const condition = conditionFrom(statement);
      const subject = businessSubject(statement, "project_milestone");
      return {
        kind: "Project milestone update",
        summary: `${subject} should move to ${plainValue(status)} on ${businessDate(effectiveAt)}.`,
        record: subject,
        currentValue: plainValue(milestone.status || "unknown"),
        proposedValue: plainValue(status),
        effectiveAt,
        condition,
        impact: `Approving this keeps the milestone at ${plainValue(milestone.status || "unknown")} today. Starting ${businessDate(effectiveAt)}, project updates should treat it as ${plainValue(status)} if the condition is satisfied.`,
        evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
        action: "accept_pm_milestone_plan",
        label: "Approve change",
        formType: "pm_status_plan",
        payload: {
          milestone_id: milestone.id,
          status,
          effective_at: effectiveAt,
          reason: condition || `Accepted from PM workspace candidate ${shortId(candidate.id)}.`,
          actor: "crm-pm-workspace",
          plan_properties: { candidate_statement: statement },
        },
      };
    }
  }

  const domains = identifiers.filter(isDomainIdentifier).filter((id) =>
    ["project_task_status", "project_milestone_status"].includes(id)
  );
  if (domains.length) {
    const context = candidate.review_contexts?.[0];
    const source = identifiers.find((id) => !isDomainIdentifier(id) && !isIsoDate(id)) ?? leadingName(statement);
    const supersedes = statement.match(/\breplace\s+(.+?)\s+for\b/i)?.[1]?.trim() ?? currentSourceFor(policies, domains);
    const effectiveAt = isoDate(statement, identifiers);
    if (context?.id && source) {
      const domainText = businessDomainList(domains);
      const currentSource = currentSourceFor(policies, domains) || supersedes || "the current system";
      return {
        kind: "Project system change",
        summary: `${source} should become the place to check ${domainText}${effectiveAt ? ` on ${businessDate(effectiveAt)}` : ""}.`,
        record: "Project system rules",
        currentValue: currentSource,
        proposedValue: `${source} for ${domainText}`,
        effectiveAt,
        condition: "after the system change is reviewed and confirmed",
        impact: `Approving this means people and assistants should use ${source} for ${domainText} starting ${businessDate(effectiveAt)}. Before then, they should keep using ${currentSource}.`,
        evidence: [evidenceSourceLine(candidate), quoteObservation(statement)],
        action: "accept_source_policy",
        label: "Approve system change",
        formType: "source_policy",
        payload: {
          scope_id: context.id,
          status_domains: domains,
          authoritative_source: source,
          effective_at: effectiveAt,
          review_gate: "review required before authority",
          evidence_allowed: ["reviewed source observation", "owner confirmation"],
          supersedes,
          notes: statement,
          actor: "crm-pm-workspace",
        },
      };
    }
  }

  return null;
}

function filteredReviews() {
  return state.reviews.filter((item) => {
    if (state.reviewFilter === "ready") return Boolean(item.action);
    if (state.reviewFilter === "future") return Boolean(item.effectiveAt);
    if (state.reviewFilter === "needs-routing") return !item.action;
    return true;
  });
}

function reviewQueueItem(item) {
  const active = item.id === state.activeReviewId;
  return `
    <button class="review-row ${active ? "active" : ""}" type="button" data-select-review="${escapeHtml(item.id)}">
      <span class="review-row-top">
        <span>${escapeHtml(item.domains.map(businessAreaName).join(" + "))}</span>
        <span>${escapeHtml(item.action ? "Ready to decide" : "Needs clarification")}</span>
      </span>
      <strong>${escapeHtml(item.title)}</strong>
      <span class="review-row-meta">
        ${escapeHtml(item.kind)}
        ${item.effectiveAt ? ` · ${escapeHtml(businessDate(item.effectiveAt))}` : ""}
      </span>
    </button>
  `;
}

function decisionDetail(item) {
  const canAccept = Boolean(item.action);
  return `
    <article class="decision-detail">
      <div class="decision-head">
        <div>
          <div class="proposal-meta">
            ${chip(item.domains.map(businessAreaName).join(" + "))}
            ${chip(item.kind, canAccept ? "good" : "")}
            ${item.effectiveAt ? chip("Scheduled", "future") : ""}
          </div>
          <h3>${escapeHtml(item.title)}</h3>
          <div class="decision-actions">
            ${canAccept ? `<button class="primary" type="button" data-action="${escapeHtml(item.action)}" data-candidate="${escapeHtml(item.id)}">${escapeHtml(item.actionLabel || "Approve")}</button>` : ""}
            <button type="button" data-action="needs_review" data-candidate="${escapeHtml(item.id)}">Ask owner to verify</button>
            <button type="button" data-action="reject" data-candidate="${escapeHtml(item.id)}">Mark not useful</button>
            <p class="action-help">Approve makes this part of the working dashboard. Ask owner to verify keeps it visible without treating it as final. Mark not useful closes old, duplicate, or incorrect information.</p>
          </div>
          <p><strong>Your decision:</strong> Should this become official business information?</p>
          <p>${escapeHtml(item.impact)}</p>
        </div>
      </div>

      <div class="decision-grid">
        ${detailCell("What this is about", item.record)}
        ${detailCell("What is true now", item.currentValue)}
        ${detailCell("What would become official", item.proposedValue)}
        ${detailCell("When it applies", item.effectiveAt ? businessDate(item.effectiveAt) : "Now or not specified")}
      </div>

      ${item.condition ? `
        <div class="impact-note">
          <strong>Condition</strong>
          <span>${escapeHtml(item.condition)}</span>
        </div>
      ` : ""}

      ${renderDecisionForm(item)}

      <section class="detail-section">
        <h4>Why this appeared</h4>
        <ul class="evidence-list">
          ${item.evidence.map((line) => `<li>${escapeHtml(line)}</li>`).join("")}
        </ul>
      </section>

      ${item.questions.length ? `
        <section class="detail-section">
          <h4>Questions a reviewer may need to answer</h4>
          <ul class="evidence-list">
            ${item.questions.slice(0, 5).map((line) => `<li>${escapeHtml(line)}</li>`).join("")}
          </ul>
        </section>
      ` : ""}

      <section class="detail-section subdued">
        <h4>Original observation</h4>
        <p>${escapeHtml(quoteObservation(item.statement))}</p>
        <div class="record-meta">
          ${chip(itemSourceChip(item))}
          ${chip(item.confidence != null ? `System confidence: ${Math.round(Number(item.confidence) * 100)}%` : "Confidence unknown")}
        </div>
      </section>
    </article>
  `;
}

function renderDecisionForm(item) {
  if (!item.action || !item.payload || !item.formType) {
    return `
      <section class="detail-section route-note">
        <h4>Why this needs clarification</h4>
        <p>This note may be useful, but it does not yet say exactly what business record or process should change. Use “Ask owner to verify” when someone should confirm the source, clarify the condition, or explain what decision is needed.</p>
      </section>
    `;
  }

  const payload = item.payload;
  if (item.formType === "source_policy") {
    return `
      <form class="decision-form" data-form-type="source_policy" data-payload="${escapeAttr(JSON.stringify(payload))}">
        <div class="form-head">
          <h4>Edit before approving</h4>
          <span>No technical fields</span>
        </div>
        <div class="field-grid">
          ${textField("authoritative_source", "System to use", payload.authoritative_source)}
          ${dateField("effective_at", "Start date", payload.effective_at)}
          ${textField("supersedes", "Replaces", payload.supersedes)}
          ${textField("review_gate", "What must be checked first", payload.review_gate)}
        </div>
        ${textArea("notes", "Approval note", payload.notes)}
      </form>
    `;
  }

  if (item.formType === "crm_stage_plan") {
    return `
      <form class="decision-form" data-form-type="crm_stage_plan" data-payload="${escapeAttr(JSON.stringify(payload))}">
        <div class="form-head">
          <h4>Edit before approving</h4>
          <span>No technical fields</span>
        </div>
        <div class="field-grid">
          ${selectField("stage", "Sales status", payload.stage, ["site_survey_completed", "needs_financing", "proposal_sent", "contract_review", "negotiation", "closed_won", "closed_lost"])}
          ${dateField("effective_at", "Start date", payload.effective_at)}
          ${textField("reason", "Reason or condition", payload.reason)}
        </div>
      </form>
    `;
  }

  return `
    <form class="decision-form" data-form-type="pm_status_plan" data-payload="${escapeAttr(JSON.stringify(payload))}">
      <div class="form-head">
        <h4>Edit before approving</h4>
        <span>No technical fields</span>
      </div>
      <div class="field-grid">
        ${selectField("status", "Project status", payload.status, ["backlog", "todo", "in_progress", "ready_for_install", "in_review", "approved", "done", "blocked"])}
        ${dateField("effective_at", "Start date", payload.effective_at)}
        ${textField("reason", "Reason or condition", payload.reason)}
      </div>
    </form>
  `;
}

function contextReviewCard(item) {
  return `
    <article class="context-review">
      <div class="proposal-meta">
        ${chip(item.kind, item.action ? "good" : "")}
        ${item.effectiveAt ? chip(businessDate(item.effectiveAt), "future") : ""}
      </div>
      <strong>${escapeHtml(item.title)}</strong>
      <p>${escapeHtml(item.proposedValue)}</p>
      <button type="button" data-select-review="${escapeHtml(item.id)}">Open decision</button>
    </article>
  `;
}

function opportunityListItem(opp, plans) {
  const name = opportunityName(opp);
  const reviews = relatedReviews(name, "CRM", opp.id);
  const decisionText = reviews.length ? ` · ${reviewCountLabel(reviews.length)}` : "";
  return `
    <button class="business-row ${state.activeSalesId === opp.id ? "active" : ""}" type="button" data-select-sales="${escapeHtml(opp.id)}">
      <span class="row-main">
        <strong>${escapeHtml(name)}</strong>
        <span>${escapeHtml(`${opp.assigned_to_name || "No owner"} · ${opp.primary_contact_name || "No contact"}${decisionText}`)}</span>
      </span>
      <span class="row-status">${escapeHtml(plainValue(opp.stage || "unknown"))}</span>
      <span class="row-next">${escapeHtml(nextSalesChange(plans))}</span>
    </button>
  `;
}

function taskListItem(task, plans) {
  const name = taskName(task);
  const reviews = relatedReviews(name, "PM", task.id);
  const decisionText = reviews.length ? ` · ${reviewCountLabel(reviews.length)}` : "";
  return `
    <button class="business-row ${state.activeProjectId === task.id ? "active" : ""}" type="button" data-select-project="${escapeHtml(task.id)}">
      <span class="row-main">
        <strong>${escapeHtml(name)}</strong>
        <span>${escapeHtml(`${task.owner_name || "No owner"} · ${projectName(task.project_name || task.project_code)}${decisionText}`)}</span>
      </span>
      <span class="row-status">${escapeHtml(plainValue(task.status || "unknown"))}</span>
      <span class="row-next">${escapeHtml(nextProjectChange(plans))}</span>
    </button>
  `;
}

function milestoneListItem(milestone, plans) {
  const name = milestoneName(milestone);
  const reviews = relatedReviews(name, "PM", milestone.id);
  const decisionText = reviews.length ? ` · ${reviewCountLabel(reviews.length)}` : "";
  return `
    <button class="business-row ${state.activeProjectId === milestone.id ? "active" : ""}" type="button" data-select-project="${escapeHtml(milestone.id)}">
      <span class="row-main">
        <strong>${escapeHtml(name)}</strong>
        <span>${escapeHtml(`${milestone.target_date ? `Target ${businessDate(milestone.target_date)}` : "No target date"}${decisionText}`)}</span>
      </span>
      <span class="row-status">${escapeHtml(plainValue(milestone.status || "unknown"))}</span>
      <span class="row-next">${escapeHtml(nextProjectChange(plans))}</span>
    </button>
  `;
}

function salesDetail(opp, plans) {
  const name = opportunityName(opp);
  const reviews = relatedReviews(name, "CRM", opp.id);
  const nextChange = nextSalesChange(plans);
  const relationshipSections = salesRelationshipSections(opp.related_items ?? []);
  const missing = [
    !opp.current_value ? "Expected deal value is not known." : "",
    !opp.win_probability ? "Win probability is not known." : "",
    !opp.primary_contact_name ? "Primary contact is not known." : "",
    reviews.length ? `${reviewCountLabel(reviews.length)} ${needsVerb(reviews.length)} follow-up before this record is complete.` : "",
  ].filter(Boolean);
  return `
    <article class="record-detail">
      <div class="record-detail-head">
        <div>
          <h3>${escapeHtml(name)}</h3>
          <p>${escapeHtml(salesSummary(opp, nextChange))}</p>
        </div>
      </div>

      ${calloutSection("What to do next", salesNextActionLines(opp, reviews, plans))}

      ${detailSection("At a glance", [
        `Owner: ${opp.assigned_to_name || "No owner assigned."}`,
        `Customer contact: ${opp.primary_contact_name || "No contact recorded."}`,
        `Sales status: ${plainValue(opp.stage || "unknown")}`,
        `Expected value: ${opp.current_value ? `$${Number(opp.current_value).toLocaleString()}` : "Not recorded."}`,
        `Win probability: ${opp.win_probability ? `${Math.round(Number(opp.win_probability) * 100)}%` : "Not recorded."}`,
      ])}

      ${relationshipSections.people.length ? detailSection("People and organizations", relationshipSections.people) : ""}
      ${relationshipSections.work.length ? detailSection("Connected work", relationshipSections.work) : ""}

      ${plans.length ? detailSection("Upcoming official changes", plans.map((plan) =>
        `${plainValue(plan.claim?.planned_stage || "new status")} on ${businessDate(planDate(plan))}${plan.claim?.reason || plan.claim?.condition ? `: ${cleanBusinessText(plan.claim.reason || plan.claim.condition)}` : ""}`
      )) : detailSection("Upcoming official changes", ["No approved future changes for this opportunity."])}

      ${missing.length ? detailSection("Needs follow-up", missing) : detailSection("Needs follow-up", ["No obvious gaps in the available sales detail."])}

      ${reviews.length ? relatedDecisionSection(reviews) : detailSection("Related decisions", ["No open decisions are tied directly to this opportunity."])}
    </article>
  `;
}

function nextSalesChange(plans) {
  const plan = plans[0];
  if (!plan) return "No scheduled change";
  return `${plainValue(plan.claim?.planned_stage || "new status")} ${businessDate(planDate(plan))}`.trim();
}

function nextProjectChange(plans) {
  const plan = plans[0];
  if (!plan) return "No scheduled change";
  return `${plainValue(plan.claim?.planned_status || "new status")} ${businessDate(planDate(plan))}`.trim();
}

function planDate(plan) {
  return plan?.claim?.effective_at || plan?.claim?.planned_date || plan?.effective_at || "";
}

function reviewCountLabel(count) {
  if (!count) return "No open decisions";
  if (count === 1) return "1 open decision";
  return `${count} open decisions`;
}

function needsVerb(count) {
  return count === 1 ? "needs" : "need";
}

function projectDetail(item, plans) {
  const milestone = isMilestoneItem(item);
  const name = milestone ? milestoneName(item) : taskName(item);
  const reviews = relatedReviews(name, "PM", item.id);
  const nextChange = nextProjectChange(plans);
  const relationshipSections = projectRelationshipSections(item.related_items ?? [], milestone);
  const missing = milestone
    ? [
        !item.target_date ? "Target date is not known." : "",
        !item.status ? "Current milestone status is not known." : "",
        reviews.length ? `${reviewCountLabel(reviews.length)} ${needsVerb(reviews.length)} follow-up before this milestone is complete.` : "",
      ].filter(Boolean)
    : [
        !item.due_date ? "Due date is not known." : "",
        !item.priority ? "Priority is not known." : "",
        !item.reviewer_name ? "Reviewer is not assigned." : "",
        reviews.length ? `${reviewCountLabel(reviews.length)} ${needsVerb(reviews.length)} follow-up before this work item is complete.` : "",
      ].filter(Boolean);
  return `
    <article class="record-detail">
      <div class="record-detail-head">
        <div>
          <h3>${escapeHtml(name)}</h3>
          <p>${escapeHtml(projectSummary(item, milestone, nextChange))}</p>
        </div>
      </div>

      ${calloutSection("What to do next", projectNextActionLines(item, milestone, reviews, plans, relationshipSections))}

      ${!milestone ? detailSection("Project context", [
        `Project: ${projectName(item.project_name || item.project_code)}`,
        `Owner: ${item.owner_name || "No owner assigned."}`,
        `Project status: ${plainValue(item.status || "unknown")}`,
        item.reviewer_name ? `Reviewer: ${item.reviewer_name}` : "No reviewer is assigned.",
        item.due_date ? `Due date: ${businessDate(item.due_date)}` : "No due date is recorded.",
        item.priority ? `Priority: ${plainValue(item.priority)}` : "No priority is recorded.",
        Number(item.blocker_count || 0) ? `${item.blocker_count} blockers recorded.` : "No blockers are recorded.",
      ]) : detailSection("Milestone context", [
        `Owner: ${item.owner_name || "No owner assigned."}`,
        `Milestone status: ${plainValue(item.status || "unknown")}`,
        item.target_date ? `Target date: ${businessDate(item.target_date)}` : "No target date is recorded.",
        item.priority ? `Priority: ${plainValue(item.priority)}` : "No priority is recorded.",
      ])}

      ${relationshipSections.blockers.length ? detailSection("Blockers and dependencies", relationshipSections.blockers) : ""}
      ${relationshipSections.work.length ? detailSection("Connected sales or project work", relationshipSections.work) : ""}
      ${relationshipSections.people.length ? detailSection("People involved", relationshipSections.people) : ""}

      ${plans.length ? detailSection("Upcoming official changes", plans.map((plan) =>
        `${plainValue(plan.claim?.planned_status || "new status")} on ${businessDate(planDate(plan))}${plan.claim?.reason || plan.claim?.condition ? `: ${cleanBusinessText(plan.claim.reason || plan.claim.condition)}` : ""}`
      )) : detailSection("Upcoming official changes", ["No approved future changes for this work item."])}

      ${missing.length ? detailSection("Needs follow-up", missing) : detailSection("Needs follow-up", ["No obvious gaps in the available project detail."])}

      ${reviews.length ? relatedDecisionSection(reviews) : detailSection("Related decisions", ["No open decisions are tied directly to this work item."])}
    </article>
  `;
}

function salesSummary(opp, nextChange) {
  const owner = opp.assigned_to_name || "No owner";
  const contact = opp.primary_contact_name || "no named contact";
  return `${owner} owns follow-up with ${contact}. Current sales status is ${plainValue(opp.stage || "unknown")}; next scheduled change is ${nextChange}.`;
}

function projectSummary(item, milestone, nextChange) {
  if (milestone) {
    return `This milestone controls whether delivery can move forward. Current status is ${plainValue(item.status || "unknown")}; next scheduled change is ${nextChange}.`;
  }
  return `${item.owner_name || "No owner"} owns this work for ${projectName(item.project_name || item.project_code)}. Current status is ${plainValue(item.status || "unknown")}; next scheduled change is ${nextChange}.`;
}

function businessListHeader(labels) {
  return `
    <div class="business-list-header" aria-hidden="true">
      ${labels.map((label) => `<span>${escapeHtml(label)}</span>`).join("")}
    </div>
  `;
}

function stateStrip(items) {
  return `
    <div class="state-strip">
      ${items.map(([label, value]) => `
        <div class="state-item">
          <span>${escapeHtml(label)}</span>
          <strong>${escapeHtml(value || "Not specified")}</strong>
        </div>
      `).join("")}
    </div>
  `;
}

function relatedDecisionSection(reviews) {
  const shown = reviews.slice(0, 2);
  const remaining = reviews.length - shown.length;
  return `
    <section class="detail-section">
      <h4>Related decisions</h4>
      <p class="section-note">${escapeHtml(`${reviews.length} decision${reviews.length === 1 ? "" : "s"} connected to this item.`)}</p>
      <div class="linked-decisions">
        ${shown.map((item) => `
          <article class="linked-decision">
            <strong>${escapeHtml(item.title)}</strong>
            <p>${escapeHtml(item.action ? "Ready to decide" : "Needs clarification")}</p>
            <button type="button" data-select-review="${escapeHtml(item.id)}">Open decision</button>
          </article>
        `).join("")}
      </div>
      ${remaining > 0 ? `<p class="section-note">${escapeHtml(`${remaining} more are in the Decisions tab.`)}</p>` : ""}
    </section>
  `;
}

function calloutSection(title, rows) {
  return `
    <section class="detail-section action-callout">
      <h4>${escapeHtml(title)}</h4>
      <ul class="evidence-list">
        ${rows.map((row) => `<li>${escapeHtml(row)}</li>`).join("")}
      </ul>
    </section>
  `;
}

function detailSection(title, rows) {
  return `
    <section class="detail-section">
      <h4>${escapeHtml(title)}</h4>
      <ul class="evidence-list">
        ${rows.map((row) => `<li>${escapeHtml(row)}</li>`).join("")}
      </ul>
    </section>
  `;
}

function salesNextActionLines(opp, reviews, plans) {
  const lines = [];
  if (opp.next_action) lines.push(opp.next_action);
  if (reviews.length) lines.push(`${reviewCountLabel(reviews.length)} should be resolved before this opportunity is treated as complete.`);
  if (plans.length) lines.push(`Watch the scheduled status change: ${nextSalesChange(plans)}.`);
  if (!lines.length) lines.push("No next action is recorded; assign a follow-up or close the gap in the Decisions tab.");
  return lines.map(readableBusinessLine);
}

function projectNextActionLines(item, milestone, reviews, plans, sections) {
  const lines = [];
  if (!milestone && item.status === "blocked" && sections.blockers.length) {
    lines.push(sections.blockers[0]);
  }
  if (!milestone && item.due_date) lines.push(`Finish or update this by ${businessDate(item.due_date)}.`);
  if (milestone && item.target_date) lines.push(`Confirm milestone outcome by ${businessDate(item.target_date)}.`);
  if (reviews.length) lines.push(`${reviewCountLabel(reviews.length)} should be resolved before this item is treated as complete.`);
  if (plans.length) lines.push(`Watch the scheduled status change: ${nextProjectChange(plans)}.`);
  if (!lines.length) lines.push("No immediate action is recorded; review the connected work and assign a next step.");
  return lines.map(readableBusinessLine);
}

function salesRelationshipSections(items) {
  const people = [];
  const work = [];
  items.forEach((item) => {
    const line = relationshipLine(item);
    if (!line) return;
    if (["person", "org"].includes(item.node_type)) people.push(line);
    else work.push(line);
  });
  return { people: uniqueText(people), work: uniqueText(work) };
}

function projectRelationshipSections(items, milestone) {
  const people = [];
  const work = [];
  const blockers = [];
  items.forEach((item) => {
    const line = relationshipLine(item, milestone ? "milestone" : "task");
    if (!line) return;
    if (item.relation === "blocks" || item.relation === "depends_on" || item.node_type === "dependency") blockers.push(line);
    else if (["person", "org"].includes(item.node_type)) people.push(line);
    else work.push(line);
  });
  return { people: uniqueText(people), work: uniqueText(work), blockers: uniqueText(blockers) };
}

function relationshipLine(item, subjectType = "record") {
  const label = cleanBusinessText(item.label || "Related item");
  const reason = item.reason ? `: ${cleanBusinessText(item.reason)}` : "";
  const context = item.context ? ` (${plainValue(item.context)})` : "";
  const role = item.role ? ` (${plainValue(item.role)})` : "";
  const relationship = item.relationship ? ` (${plainValue(item.relationship)})` : "";
  switch (item.relation) {
    case "primary_contact":
      return `Customer contact: ${label}${role}`;
    case "customer_account":
      return `Customer organization: ${label}${relationship}`;
    case "venue_under_review":
      return `Venue under review: ${label}${reason}`;
    case "agency_review":
      return `External approval needed from ${label}${reason}`;
    case "assigned_to":
      return `Assigned to: ${label}${role}`;
    case "collaborates_on":
      return `Collaborator: ${label}${role}`;
    case "vendor_for":
      return `Vendor involved: ${label}${role}`;
    case "reviewed_by":
      return `External reviewer: ${label}${role}`;
    case "regarding":
      if (item.node_type === "task") return `Related task: ${label}${context}`;
      if (item.node_type === "milestone") return `Related milestone: ${label}${context}`;
      return item.node_type === "opportunity"
        ? `Related sales opportunity: ${label}${context}`
        : `Related to ${label}${context}`;
    case "contains":
      return item.direction === "in"
        ? `Part of project: ${label}`
        : `Contains: ${label}`;
    case "depends_on":
      return item.direction === "out"
        ? `Depends on ${label}${reason}`
        : `${label} depends on this ${subjectType}${reason}`;
    case "blocks":
      return item.direction === "in"
        ? `Blocked by ${label}${reason}`
        : `Blocks ${label}${reason}`;
    default:
      return `${plainValue(item.relation)}: ${label}${reason}`;
  }
}

function relatedReviews(name, domain, recordId = null) {
  return state.reviews
    .map((item) => {
      if (!item.domains.includes(domain)) return null;
      const payloadIds = reviewTargetIds(item);
      if (recordId && payloadIds.length) {
        return payloadIds.includes(recordId) ? { item, score: 0 } : null;
      }
      const haystack = `${item.title} ${item.record} ${item.proposedValue} ${item.statement}`;
      const exact = haystack.includes(name);
      const topic = relatedTopicScore(name, haystack);
      if (!exact && !topic) return null;
      return { item, score: exact ? 0 : 1 };
    })
    .filter(Boolean)
    .sort((a, b) => a.score - b.score || compareReviews(a.item, b.item))
    .map((entry) => entry.item);
}

function reviewTargetIds(item) {
  const payload = item.payload || targetPayload(item.candidate) || {};
  return uniqueText([
    payload.opportunity_id,
    payload.opportunityId,
    payload.task_id,
    payload.taskId,
    payload.milestone_id,
    payload.milestoneId,
  ]);
}

function relatedTopicScore(name, haystack) {
  const lowerName = name.toLowerCase();
  const lowerHaystack = haystack.toLowerCase();
  const tokens = lowerName
    .replace(/[^a-z0-9]+/g, " ")
    .split(/\s+/)
    .filter((token) => token.length >= 4 && !["summer", "late", "night", "catering", "school"].includes(token));
  const matches = tokens.filter((token) => lowerHaystack.includes(token)).length;
  if (matches >= Math.min(2, tokens.length)) return true;
  if (lowerName.includes("load calculation")) return lowerHaystack.includes("load calculation");
  if (lowerName.includes("equipment ordering")) return lowerHaystack.includes("equipment") || lowerHaystack.includes("ready for install") || lowerHaystack.includes("supplier");
  if (lowerName.includes("permit")) return lowerHaystack.includes("permit") || lowerHaystack.includes("city approval");
  return false;
}

function opportunityCard(opp, plans) {
  return `
    <button class="record-card record-button ${state.activeSalesId === opp.id ? "active" : ""}" type="button" data-select-sales="${escapeHtml(opp.id)}">
      <div class="record-title">
        <span>${escapeHtml(opportunityName(opp))}</span>
        <span class="chip">${escapeHtml(plainValue(opp.stage || "unknown"))}</span>
      </div>
      <div class="record-meta">
        ${chip(opp.assigned_to_name || "No owner")}
        ${chip(opp.primary_contact_name || "No contact")}
        ${chip(opp.current_value ? `$${Number(opp.current_value).toLocaleString()}` : "No value")}
        ${plans.map((plan) => chip(`Scheduled: ${plainValue(plan.claim?.planned_stage || "")} ${businessDate(plan.claim?.effective_at || plan.effective_at)}`, "future")).join("")}
      </div>
    </button>
  `;
}

function taskCard(task, plans) {
  return `
    <button class="record-card record-button ${state.activeProjectId === task.id ? "active" : ""}" type="button" data-select-project="${escapeHtml(task.id)}">
      <div class="record-title">
        <span>${escapeHtml(taskName(task))}</span>
        <span class="chip">${escapeHtml(plainValue(task.status || "unknown"))}</span>
      </div>
      <div class="record-meta">
        ${chip(task.owner_name || "No owner")}
        ${chip(projectName(task.project_name || task.project_code))}
        ${task.due_date ? chip(`Due ${businessDate(task.due_date)}`) : chip("No due date")}
        ${task.blocker_count ? chip(`${task.blocker_count} blockers`, "bad") : ""}
        ${plans.map((plan) => chip(`Scheduled: ${plainValue(plan.claim?.planned_status || "")} ${businessDate(plan.claim?.effective_at || plan.effective_at)}`, "future")).join("")}
      </div>
    </button>
  `;
}

function milestoneCard(milestone, plans) {
  return `
    <button class="milestone-card record-button ${state.activeProjectId === milestone.id ? "active" : ""}" type="button" data-select-project="${escapeHtml(milestone.id)}">
      <div class="record-title">
        <span>${escapeHtml(milestoneName(milestone))}</span>
        <span class="chip">${escapeHtml(plainValue(milestone.status || "unknown"))}</span>
      </div>
      <div class="record-meta">
        ${chip(milestone.target_date ? `Target ${businessDate(milestone.target_date)}` : "No target date")}
        ${plans.map((plan) => chip(`Scheduled: ${plainValue(plan.claim?.planned_status || "")} ${businessDate(plan.claim?.effective_at || plan.effective_at)}`, "future")).join("")}
      </div>
    </button>
  `;
}

function buildTimelineItems() {
  const acceptedPlans = [
    ...(state.crm?.plans ?? []).filter((plan) => !isSmokePlan(plan)).map((plan) => ({
      date: planDate(plan),
      title: `Sales opportunity scheduled for ${plainValue(plan.claim?.planned_stage || "new status")}`,
      kind: "Approved sales change",
      status: plan.claim?.status || "scheduled",
      detail: plan.claim?.reason || plan.claim?.condition || "A sales status change is scheduled.",
    })),
    ...(state.pm?.plans ?? []).filter((plan) => !isSmokePlan(plan)).map((plan) => ({
      date: planDate(plan),
      title: `${plan.subject_type === "milestone" ? "Project milestone" : "Project task"} scheduled for ${plainValue(plan.claim?.planned_status || "new status")}`,
      kind: plan.assertion_type === "milestone_status_plan" ? "Approved milestone change" : "Approved task change",
      status: plan.claim?.status || "scheduled",
      detail: plan.claim?.reason || plan.claim?.condition || "A project status change is scheduled.",
    })),
  ];

  const futurePolicies = [
    ...(state.crm?.source_policies ?? []),
    ...(state.pm?.source_policies ?? []),
  ]
    .filter((policy) => isFuture(policy.effective_at))
    .map((policy) => ({
      date: policy.effective_at,
      title: `${policy.claim?.authoritative_source || "System"} becomes the place to check ${businessDomainName(policy.claim?.status_domain || policy.assertion_key)}`,
      kind: "Approved system change",
      status: "scheduled",
      detail: plainReviewGate(policy.claim?.review_gate) || "A future system change has been approved.",
    }));

  const pendingFuture = state.reviews
    .filter((item) => item.effectiveAt)
    .map((item) => ({
      date: item.effectiveAt,
      title: item.title,
      kind: `Waiting for ${item.domains.map(businessAreaName).join(" + ")} decision`,
      status: item.action ? "ready to decide" : "needs clarification",
      detail: item.impact,
      reviewId: item.id,
    }));

  return [...acceptedPlans, ...futurePolicies, ...pendingFuture]
    .filter((item) => item.date)
    .sort((a, b) => String(a.date).localeCompare(String(b.date)));
}

function timelineItem(item) {
  return `
    <article class="timeline-item">
      <div class="timeline-date">${escapeHtml(businessDate(item.date))}</div>
      <div class="timeline-body">
        <div class="proposal-meta">
          ${chip(item.kind, item.reviewId ? "" : "good")}
          ${chip(humanize(item.status), "future")}
        </div>
        <strong>${escapeHtml(item.title)}</strong>
        <p>${escapeHtml(item.detail)}</p>
        ${item.reviewId ? `<button type="button" data-select-review="${escapeHtml(item.reviewId)}">Open decision</button>` : ""}
      </div>
    </article>
  `;
}

function sourceDomainCard(domain, policies) {
  const sorted = [...policies].sort((a, b) => String(a.effective_at || "").localeCompare(String(b.effective_at || "")));
  return `
    <article class="source-domain">
      <div>
        <h3>${escapeHtml(businessDomainName(domain))}</h3>
        <p>${escapeHtml(sourceStatusText(sorted))}</p>
      </div>
      <div class="source-policy-list">
        ${sorted.map(sourcePolicyPill).join("")}
      </div>
    </article>
  `;
}

function sourcePolicyPill(policy) {
  const future = isFuture(policy.effective_at);
  return `
    <div class="source-policy ${future ? "future-policy" : ""}">
      <strong>${escapeHtml(policy.claim?.authoritative_source || "Unknown source")}</strong>
      <span>${escapeHtml(future ? `Starts ${businessDate(policy.effective_at)}` : `Current since ${businessDate(policy.effective_at)}`)}</span>
      <p>${escapeHtml(plainReviewGate(policy.claim?.review_gate))}</p>
    </div>
  `;
}

async function saveDecision(button) {
  const action = button.dataset.action;
  const candidateId = button.dataset.candidate;
  try {
    button.disabled = true;
    if (action === "needs_review") {
      await apiPost(`/candidates/${candidateId}/status`, {
        status: "needs_review",
        reason: "Reviewer asked for proof from the business review workspace",
        actor: "crm-pm-workspace",
      });
    } else if (action === "reject") {
      await apiPost(`/candidates/${candidateId}/status`, {
        status: "rejected",
        reason: "Dismissed from the business review workspace",
        actor: "crm-pm-workspace",
      });
    } else {
      const payload = collectDecisionPayload(button);
      const endpoint = {
        accept_crm_stage_plan: "accept-crm-stage-plan",
        accept_pm_task_plan: "accept-pm-task-plan",
        accept_pm_milestone_plan: "accept-pm-milestone-plan",
        accept_source_policy: "accept-source-policy",
      }[action];
      if (!endpoint) throw new Error(`Unknown decision action: ${action}`);
      await apiPost(`/candidates/${candidateId}/${endpoint}`, payload);
    }
    toast("Decision saved");
    await loadWorkspace();
  } catch (error) {
    button.disabled = false;
    toast(error.message || String(error));
  }
}

function collectDecisionPayload(button) {
  const form = button.closest(".decision-detail")?.querySelector(".decision-form");
  if (!form) return {};
  const payload = JSON.parse(form.dataset.payload || "{}");
  const data = new FormData(form);
  for (const [key, value] of data.entries()) {
    payload[key] = String(value).trim();
  }
  if (payload.plan_properties && payload.reason) {
    payload.plan_properties.acceptance_reason = payload.reason;
  }
  return payload;
}

async function apiGet(path, includeInstance = true) {
  const url = apiUrl(path);
  if (includeInstance) url.searchParams.set("instance", state.instance);
  const response = await fetch(url, { headers: { "x-rye-instance": state.instance } });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  return response.json();
}

async function apiPost(path, body) {
  const url = apiUrl(path);
  url.searchParams.set("instance", state.instance);
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-rye-instance": state.instance },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  return response.json();
}

function switchView(view) {
  const normalized = normalizeView(view);
  els.summaryGrid.hidden = normalized !== "review";
  document.querySelectorAll(".workspace").forEach((item) => item.classList.remove("active"));
  document.querySelectorAll(".tab").forEach((item) => item.classList.toggle("active", item.dataset.view === normalized));
  document.querySelector(`#${normalized}View`)?.classList.add("active");
}

function initialView() {
  const params = new URLSearchParams(window.location.search);
  return params.get("view") || window.location.hash.replace(/^#/, "") || "review";
}

function normalizeView(view) {
  const aliases = { sales: "crm", projects: "pm", decisions: "review", upcoming: "timeline", systems: "sources" };
  const normalized = aliases[view] || view || "review";
  return ["review", "crm", "pm", "timeline", "sources"].includes(normalized) ? normalized : "review";
}

function column(title, body) {
  return `
    <section class="column">
      <div class="column-title">
        <span>${escapeHtml(plainValue(title))}</span>
        <span>${(body.match(/record-card/g) ?? []).length}</span>
      </div>
      ${body || emptyBlock("No items here.")}
    </section>
  `;
}

function metric(label, value) {
  return `
    <div class="metric">
      <div class="label">${escapeHtml(label)}</div>
      <div class="value">${escapeHtml(String(value))}</div>
    </div>
  `;
}

function chip(text, cls = "") {
  return `<span class="chip ${cls}">${escapeHtml(text)}</span>`;
}

function detailCell(label, value) {
  return `
    <div class="detail-cell">
      <span>${escapeHtml(label)}</span>
      <strong>${escapeHtml(value || "Not specified")}</strong>
    </div>
  `;
}

function textField(name, label, value) {
  return `
    <label class="field">
      <span>${escapeHtml(label)}</span>
      <input name="${escapeHtml(name)}" value="${escapeAttr(value || "")}" />
    </label>
  `;
}

function dateField(name, label, value) {
  return `
    <label class="field">
      <span>${escapeHtml(label)}</span>
      <input type="date" name="${escapeHtml(name)}" value="${escapeAttr(dateOnly(value || ""))}" />
    </label>
  `;
}

function selectField(name, label, value, options) {
  const selected = String(value || "");
  return `
    <label class="field">
      <span>${escapeHtml(label)}</span>
      <select name="${escapeHtml(name)}">
        ${unique([selected, ...options].filter(Boolean)).map((option) => `
          <option value="${escapeAttr(option)}" ${option === selected ? "selected" : ""}>${escapeHtml(plainValue(option))}</option>
        `).join("")}
      </select>
    </label>
  `;
}

function textArea(name, label, value) {
  return `
    <label class="field wide">
      <span>${escapeHtml(label)}</span>
      <textarea name="${escapeHtml(name)}" rows="3">${escapeHtml(value || "")}</textarea>
    </label>
  `;
}

function emptyBlock(text) {
  return `<p class="empty">${escapeHtml(text)}</p>`;
}

function emptyDecision() {
  return `
    <div class="decision-detail">
      <div class="decision-head">
        <div>
          <h3>No decisions waiting</h3>
          <p>There are no open sales or project items for this instance.</p>
        </div>
      </div>
    </div>
  `;
}

function groupBy(rows, keyOrFn) {
  return rows.reduce((acc, row) => {
    const value = typeof keyOrFn === "function" ? keyOrFn(row) : row[keyOrFn];
    const key = value ?? "";
    acc[key] ??= [];
    acc[key].push(row);
    return acc;
  }, {});
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function uniqueText(values) {
  return unique(values.map((value) => String(value || "").trim()).filter(Boolean));
}

function candidateStatement(candidate) {
  return candidate.properties?.statement || candidate.label || candidate.id;
}

function identifiersFor(candidate) {
  const payload = targetPayload(candidate);
  return Array.isArray(payload?.identifiers)
    ? payload.identifiers.map(String).filter(Boolean)
    : [];
}

function targetPayload(candidate) {
  return typeof candidate.properties?.target_payload === "string"
    ? tryJson(candidate.properties.target_payload)
    : candidate.properties?.target_payload ?? {};
}

function findOpportunityForCandidate(candidate, opportunities) {
  const payload = targetPayload(candidate);
  const id = payload.opportunity_id || payload.opportunityId;
  if (id) {
    const exact = opportunities.find((item) => item.id === id);
    if (exact) return exact;
  }
  return findBusinessRecord(candidate, opportunities, (item) => [
    item.code,
    item.name,
    item.label,
    opportunityName(item),
    payload.opportunity_name,
    payload.opportunity,
    payload.subject,
  ]);
}

function findTaskForCandidate(candidate, tasks) {
  const payload = targetPayload(candidate);
  const id = payload.task_id || payload.taskId;
  if (id) {
    const exact = tasks.find((item) => item.id === id);
    if (exact) return exact;
  }
  if (payload.target_type === "milestone" || payload.milestone_id || payload.milestone_name) return null;
  return findBusinessRecord(candidate, tasks, (item) => [
    item.code,
    item.title,
    item.label,
    taskName(item),
    payload.task_name,
    payload.task,
    payload.subject,
  ]);
}

function findMilestoneForCandidate(candidate, milestones) {
  const payload = targetPayload(candidate);
  const id = payload.milestone_id || payload.milestoneId;
  if (id) {
    const exact = milestones.find((item) => item.id === id);
    if (exact) return exact;
  }
  if (payload.target_type === "task" || payload.task_id || payload.task_name) return null;
  return findBusinessRecord(candidate, milestones, (item) => [
    item.code,
    item.name,
    item.label,
    milestoneName(item),
    payload.milestone_name,
    payload.milestone,
    payload.subject,
  ]);
}

function findBusinessRecord(candidate, records, valuesFor) {
  const haystack = normalizeText(`${candidateStatement(candidate)} ${JSON.stringify(targetPayload(candidate))}`);
  return records.find((item) =>
    uniqueText(valuesFor(item))
      .map(normalizeText)
      .filter((value) => value.length >= 4)
      .some((value) => haystack.includes(value))
  ) ?? null;
}

function normalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function sourceDocKey(candidate) {
  const payload = targetPayload(candidate);
  return payload.source_doc_key
    || payload.source_doc_keys?.[0]
    || payload.candidate_process_document?.source_doc_keys?.[0]
    || candidate.properties?.source_doc_key
    || "";
}

function readableCandidateKind(candidate) {
  const kind = candidate.properties?.candidate_kind || targetPayload(candidate).document_type || "business note";
  if (kind === "fact") return "Business note";
  if (kind === "procedure") return "Process note";
  return plainValue(kind);
}

function reviewEvidence(candidate, draft) {
  const payload = targetPayload(candidate);
  const evidence = [
    ...(draft?.evidence ?? []),
    sourceDocKey(candidate) ? evidenceSourceLine(candidate) : "",
    ...(candidate.sources ?? []).map((source) => `Supported by ${friendlySourceLabel(source)}`),
  ];

  const processDoc = payload.candidate_process_document;
  if (Array.isArray(processDoc?.domain_summaries)) {
    processDoc.domain_summaries.slice(0, 2).forEach((summary) => {
      if (summary.likely_process) evidence.push(cleanBusinessText(summary.likely_process));
    });
  }

  return uniqueText(evidence);
}

function evidenceSourceLine(candidate) {
  const key = sourceDocKey(candidate);
  if (key) return `Found in ${friendlySourceName(key)}`;
  const source = candidate.sources?.[0];
  return source ? `Supported by ${friendlySourceLabel(source)}` : "Source needs to be attached or confirmed";
}

function itemSourceChip(item) {
  if (item.sourceDoc) return `Found in ${friendlySourceName(item.sourceDoc)}`;
  const source = item.candidate?.sources?.[0];
  return source ? `Supported by ${friendlySourceLabel(source)}` : "Source needs confirmation";
}

function reviewQuestions(candidate) {
  const payload = targetPayload(candidate);
  const processDoc = payload.candidate_process_document;
  return uniqueText([
    ...(payload.suggested_review_questions ?? []),
    ...(processDoc?.open_questions_for_human_review ?? []),
  ].map(cleanBusinessText));
}

function plainStatementTitle(statement) {
  return summarizeUnmappedStatement(statement);
}

function isPendingDecision(statement) {
  return /\b(decision|pending|still needs|needs to answer|waiting on|remains pending)\b/i.test(statement);
}

function pendingDecisionTitle(statement) {
  const afterColon = statement.match(/\b(?:opportunity|project task|milestone|sales)\s+decision:\s*(.+)$/i)?.[1];
  return sentenceCase(cleanBusinessText(firstSentence(afterColon || statement))
    .replace(/\bstill\s+/gi, "")
    .replace(/\bremains pending\b/gi, "is pending")
    .replace(/\bis still pending\b/gi, "is pending"));
}

function quoteObservation(statement) {
  return cleanBusinessText(statement).replace(/\b20\d{2}-\d{2}-\d{2}\b/g, (date) => businessDate(date));
}

function summarizeUnmappedStatement(statement) {
  if (/shadow PipelinePro|future-state evidence/i.test(statement)) {
    return "Future system records should not be used as today’s official information.";
  }
  if (/future cutover digest|planned replacements/i.test(statement)) {
    return "Future system changes need review before they affect sales and projects.";
  }
  if (isPendingDecision(statement)) return pendingDecisionTitle(statement);
  if (/opportunity|sales stage|deal stage|next sales action/i.test(statement)) return "Sales details need confirmation.";
  if (/task|work item|due date|owner|assignee/i.test(statement)) return "Project work details need confirmation.";
  if (/milestone|permit|approval/i.test(statement)) return "Milestone details need confirmation.";
  return cleanBusinessText(firstSentence(statement));
}

function businessSubject(statement, type) {
  const customer = businessCustomer(statement);
  if (type === "sales_opportunity") return `${customer} sales opportunity`;
  if (type === "project_task") {
    if (/load calculation/i.test(statement)) return `${customer} load calculation task`;
    if (/supplier|ready_for_install|ready for install|outdoor unit|equipment/i.test(statement)) return `${customer} equipment ordering task`;
    return `${customer} project task`;
  }
  if (type === "project_milestone") {
    if (/permit|city approval/i.test(statement)) return `${customer} permit milestone`;
    return `${customer} project milestone`;
  }
  return `${customer} business record`;
}

function businessCustomer(statement) {
  if (/lumen house/i.test(statement)) return "Lumen House";
  if (/northstar/i.test(statement)) return "Northstar Cafe";
  const name = leadingName(statement);
  return name && name.length > 3 ? name : "the customer";
}

function businessAreaName(area) {
  if (area === "CRM") return "Sales";
  if (area === "PM") return "Projects";
  return plainValue(area);
}

function businessDomainName(domain) {
  const key = String(domain || "");
  const labels = {
    deal_stage: "sales stage",
    sales_next_action: "next sales action",
    project_task_status: "project task status",
    project_milestone_status: "project milestone status",
    technician_dispatch_status: "technician dispatch status",
    crew_assignment_status: "crew assignment status",
    equipment_eta_status: "equipment ETA",
    equipment_reserve_status: "equipment reservation",
  };
  return labels[key] || plainValue(key);
}

function businessDomainList(domains) {
  const labels = domains.map(businessDomainName);
  if (labels.length <= 1) return labels[0] || "business information";
  return `${labels.slice(0, -1).join(", ")} and ${labels[labels.length - 1]}`;
}

function opportunityName(opp) {
  return cleanBusinessText(opp.name || opp.label || opp.code || "Sales opportunity");
}

function taskName(task) {
  return cleanBusinessText(task.title || task.label || task.code || "Project task");
}

function milestoneName(milestone) {
  return cleanBusinessText(milestone.name || milestone.label || milestone.code || "Project milestone");
}

function isMilestoneItem(item) {
  return Boolean(item.status_claim) || String(item.code || "").includes("MIL") || Object.hasOwn(item, "target_date");
}

function projectName(value) {
  return value ? cleanBusinessText(value) : "No project recorded";
}

function businessInstanceLabel(item) {
  if (item.id?.startsWith("eval-")) return cleanBusinessText(item.label || item.id).replace(/^Eval ·\s*/i, "Demo: ");
  if (item.id === "local") return "Local data";
  return cleanBusinessText(item.label || item.id);
}

function isSmokePlan(plan) {
  const text = `${plan.subject_label || ""} ${plan.claim?.reason || ""} ${JSON.stringify(plan.claim?.properties || "")}`.toLowerCase();
  return text.includes("guided-smoke") || text.includes("route smoke") || text.includes("regression");
}

function reviewStatusLabel(status) {
  const labels = {
    proposed: "Waiting for decision",
    needs_review: "Proof requested",
    accepted: "Approved",
    rejected: "Dismissed",
  };
  return labels[status] || plainValue(status || "waiting");
}

function friendlySourceName(key) {
  if (!key) return "the source note";
  if (key.includes("patchwork-slack")) return "Slack #event-desk";
  if (key.includes("patchwork-email-atlas")) return "Atlas Labs email thread";
  if (key.includes("patchwork-email-willow")) return "Willow Creek email thread";
  if (key.includes("patchwork-email-baxter")) return "Baxter-Diaz email";
  if (key.includes("patchwork-lead-tracker")) return "Lead Tracker spreadsheet";
  if (key.includes("patchwork-event-workboard")) return "Event Workboard spreadsheet";
  if (key.includes("patchwork-rye-pilot")) return "Rye pilot process note";
  if (key.includes("millbrook-slack")) return "Slack #jobs";
  if (key.includes("millbrook-email-harper")) return "Harper Lane email thread";
  if (key.includes("millbrook-email-vale")) return "Vale ADU email thread";
  if (key.includes("millbrook-email-olson")) return "Olson bathroom leak email thread";
  if (key.includes("millbrook-leads-job-board")) return "Leads and Job Board spreadsheet";
  if (key.includes("millbrook-deposit-tracker")) return "Deposit Tracker spreadsheet";
  if (key.includes("millbrook-role-roster")) return "Millbrook role roster";
  if (key.includes("2026-06-18")) return "the June 18 future systems update";
  if (key.includes("2026-06-12")) return "the June 12 current process review";
  if (key.includes("2026-06-20")) return "the June 20 follow-up review";
  return "the source note";
}

function friendlySourceLabel(source) {
  const label = cleanBusinessText(source?.label || "");
  if (!label) return friendlySourceName(source?.id || "");
  const type = source?.source_type ? plainValue(source.source_type) : "";
  return type ? `${label} (${type})` : label;
}

function plainReviewGate(value) {
  if (!value) return "No approval check is recorded.";
  const text = String(value || "")
    .replace(/\bimported candidates\b/gi, "imported records")
    .replace(/\s{2,}/g, " ")
    .trim();
  if (/\bRye\b/.test(text)) return text;
  return cleanBusinessText(text)
    .replace(/Raw exports/gi, "Unreviewed system exports")
    .replace(/reconciled to/gi, "checked against")
    .replace(/for the relevant start date/gi, "for the date being reviewed")
    .replace(/for the relevant effective date/gi, "for the date being reviewed");
}

function cleanBusinessText(value) {
  return String(value || "")
    .replace(/\bBW-(?:OPP|TSK|MIL|PRJ)-\d+\b/g, "")
    .replace(/\bdeal_stage\b/g, "sales stage")
    .replace(/\bsales_next_action\b/g, "next sales action")
    .replace(/\bproject_task_status\b/g, "project task status")
    .replace(/\bproject_milestone_status\b/g, "project milestone status")
    .replace(/\bready_for_install\b/g, "ready for install")
    .replace(/\bin_progress\b/g, "in progress")
    .replace(/\bproposal_sent\b/g, "proposal sent")
    .replace(/\bcontract_review\b/g, "contract review")
    .replace(/\bsite_survey_completed\b/g, "site survey completed")
    .replace(/\bneeds_financing\b/g, "needs financing")
    .replace(/\bwaiting_city\b/g, "waiting for city approval")
    .replace(/\bfuture-state evidence\b/gi, "future system notes")
    .replace(/\beffective dates\b/gi, "start dates")
    .replace(/\beffective date\b/gi, "start date")
    .replace(/\beffective\b/gi, "starting")
    .replace(/\bcurrent truth\b/gi, "today’s official information")
    .replace(/\bcurrent-state questions\b/gi, "questions about today")
    .replace(/\bCRM\b/g, "sales")
    .replace(/\bPM\b/g, "project")
    .replace(/\bExisting Rye context\b/g, "Existing approved records")
    .replace(/\bRye business policy\b/g, "existing business rule")
    .replace(/\bRye context\b/g, "approved records")
    .replace(/\bRye\b/g, "approved records")
    .replace(/\bcandidate\b/gi, "unconfirmed")
    .replace(/\bfuture-effective\b/g, "scheduled")
    .replace(/\bsource-authority\b/g, "system ownership")
    .replace(/\bplugin-shaped\b/g, "application-ready")
    .replace(/\s{2,}/g, " ")
    .replace(/\s+([,.;:])/g, "$1")
    .trim();
}

function readableBusinessLine(value) {
  return cleanBusinessText(value).replace(/\b20\d{2}-\d{2}-\d{2}\b/g, (date) => businessDate(date));
}

function plannedValue(statement, identifiers) {
  const patterns = [
    /\bplanned\s+to\s+become\s+([a-z][a-z0-9_ -]*?)(?:\s+(?:effective|on|by|after|because|for|if|when)\b|[.;,]|$)/i,
    /\bplanned\s+(?:CRM\s+stage\s+change\s+)?to\s+([a-z][a-z0-9_ -]*?)(?:\s+(?:effective|on|by|after|because|for|if|when)\b|[.;,]|$)/i,
    /\bmove\s+to\s+([a-z][a-z0-9_ -]*?)(?:\s+(?:effective|on|by|after|because|for|if|when)\b|[.;,]|$)/i,
    /\bbecome\s+([a-z][a-z0-9_ -]*?)(?:\s+(?:effective|on|by|after|because|for|if|when)\b|[.;,]|$)/i,
  ];
  for (const pattern of patterns) {
    const match = statement.match(pattern);
    if (match?.[1]) return match[1].trim().replace(/\s+/g, "_");
  }
  return identifiers.find((id) => /^[a-z][a-z0-9_]+$/.test(id) && !isDomainIdentifier(id)) ?? "";
}

function isoDate(statement, identifiers) {
  return statement.match(/\b20\d{2}-\d{2}-\d{2}(?:T[0-9:.+-Z]+)?\b/)?.[0]
    ?? identifiers.find(isIsoDate)
    ?? null;
}

function conditionFrom(statement) {
  return statement.match(/\b(?:after|if|when)\s+(.+?)(?:[.;]|$)/i)?.[0]?.trim() ?? "";
}

function currentSourceFor(policies, domains) {
  const summaries = domains.map((domain) => {
    const matching = policies
      .filter((policy) => policy.claim?.status_domain === domain && !isFuture(policy.effective_at))
      .sort((a, b) => String(b.effective_at || "").localeCompare(String(a.effective_at || "")));
    const source = matching[0]?.claim?.authoritative_source;
    return source ? `${businessDomainName(domain)}: ${source}` : "";
  }).filter(Boolean);
  return summaries.join("; ");
}

function sourceStatusText(policies) {
  const current = policies
    .filter((policy) => !isFuture(policy.effective_at))
    .sort((a, b) => String(b.effective_at || "").localeCompare(String(a.effective_at || "")))[0];
  const future = policies
    .filter((policy) => isFuture(policy.effective_at))
    .sort((a, b) => String(a.effective_at || "").localeCompare(String(b.effective_at || "")))[0];
  if (current && future) {
    const currentSource = current.claim?.authoritative_source || "Unknown";
    const futureSource = future.claim?.authoritative_source || "Unknown";
    if (currentSource === futureSource) {
      return `${currentSource} is used today. Starting ${businessDate(future.effective_at)}, new updates should be checked there first.`;
    }
    return `${currentSource} is used today. ${futureSource} is scheduled to take over on ${businessDate(future.effective_at)}.`;
  }
  if (current) return `${current.claim?.authoritative_source || "Unknown"} is used today.`;
  if (future) return `${future.claim?.authoritative_source || "Unknown"} is scheduled to take over on ${businessDate(future.effective_at)}.`;
  return "No system rule details available.";
}

function leadingName(statement) {
  return statement.match(/^([A-Z][A-Za-z0-9 .&-]{1,60}?)(?:\s+is\b|\s+will\b|\s+has\b)/)?.[1]?.trim() ?? "";
}

function firstSentence(value) {
  return String(value || "").split(/(?<=[.!?])\s+/)[0].slice(0, 180);
}

function compareReviews(a, b) {
  return a.sortScore - b.sortScore
    || String(a.effectiveAt || "9999").localeCompare(String(b.effectiveAt || "9999"))
    || String(a.createdAt || "").localeCompare(String(b.createdAt || ""));
}

function reviewSortScore(item) {
  if (item.action && item.effectiveAt) return 0;
  if (item.action) return 1;
  if (item.effectiveAt) return 2;
  return 3;
}

function isFuture(value) {
  if (!value) return false;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return false;
  return date.getTime() > Date.now();
}

function isIsoDate(value) {
  return /^20\d{2}-\d{2}-\d{2}/.test(String(value).trim());
}

function isDomainIdentifier(value) {
  return /^[a-z][a-z0-9_]*_[a-z0-9_]+$/.test(String(value).trim()) && !isIsoDate(value);
}

function humanize(value) {
  return String(value || "")
    .replace(/[_:.-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function plainValue(value) {
  const key = String(value || "").trim();
  const labels = {
    backlog: "backlog",
    todo: "to do",
    in_progress: "in progress",
    ready_for_install: "ready for install",
    in_review: "in review",
    approved: "approved",
    done: "done",
    blocked: "blocked",
    conditional_todo: "conditional to do",
    waiting_external: "waiting on external answer",
    waiting_customer_deposit: "waiting on customer deposit",
    paused_nurture: "paused/nurture",
    tentative: "tentative",
    proposal_ready: "proposal ready",
    waiting_city: "waiting for city approval",
    site_survey_completed: "site survey completed",
    needs_financing: "needs financing",
    proposal_sent: "proposal sent",
    contract_review: "contract review",
    negotiation: "negotiation",
    closed_won: "closed won",
    closed_lost: "closed lost",
  };
  if (labels[key]) return sentenceCase(labels[key]);
  return sentenceCase(cleanBusinessText(key).replace(/[_:.-]+/g, " "));
}

function sentenceCase(value) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : "";
}

function businessDate(value) {
  if (!value) return "";
  const match = String(value).match(/^(\d{4})-(\d{2})-(\d{2})/);
  const date = match
    ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
    : new Date(value);
  if (Number.isNaN(date.getTime())) return dateOnly(value);
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function dateOnly(value) {
  if (!value) return "";
  return String(value).slice(0, 10);
}

function formatDate(value) {
  return new Date(value).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

function shortId(id) {
  return String(id || "").slice(0, 8);
}

function tryJson(value) {
  try {
    return JSON.parse(value);
  } catch {
    return {};
  }
}

function toast(message) {
  els.toast.textContent = message;
  els.toast.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => els.toast.classList.remove("show"), 2800);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/`/g, "&#96;");
}
