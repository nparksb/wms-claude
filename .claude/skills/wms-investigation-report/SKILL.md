---
name: wms-investigation-report
description: Produce an evidence-based investigation report for a WMS concern without committing to a fix. Use when the goal is to understand / diagnose / audit rather than implement — metric anomaly, suspected race condition, pre-feature feasibility study, tech-debt audit, connection pool saturation, reservation leak, OSIV impact audit, cross-system reconciliation question, or "should we even fix this?" decision. Output is a report with hypotheses, evidence, verdict + confidence, and a recommendation (fix now / fix later / do not fix / monitor / investigate further). Does NOT produce a fix plan or implement changes.
---

# WMS Investigation Report

Produces an evidence-driven investigation report at `sbdocs/3-Resources/reports/`. The output ends in a verdict + recommendation, NOT an implementation plan.

## Triage first — run `wms-triage`

**Invoke `Skill("wms-triage", "<the concern>")` before investigating.** Two of its four probe questions kill investigations outright: *is it already fixed on `origin/develop`?* and *does it reproduce?* An unreproducible concern needs a reporter conversation, not a report.

`wms-triage` also owns the rules this skill obeys and does not restate:

- **The floor** — the DB query and the one independent review pass apply to a report exactly as they do to a fix. A hypothesis with no query behind it is not evidence.
- **The ticket policy** — where a finding goes (fix-in-PR · widen an existing ticket · file one, capped at one per visit and confirmed by Nam · fix tooling defects directly). A report's recommendation section must route each finding through it, not invent its own destinations.

## Trigger

Use this skill when the user asks you to:
- "Investigate why …", "audit …", "look into …", "figure out if …"
- Diagnose a metric spike, slow query, connection pool saturation, memory pressure
- Evaluate a suspected bug that may not be worth fixing
- Do a feasibility / groundwork study before drafting a feature plan
- Compare v1 vs v2 behavior to decide where a fix belongs
- Reconcile data between OMS (MySQL) and WMS (PostgreSQL)

Do NOT use this skill when the user wants:
- An actionable fix plan → use `wms-bugfix-plan`
- A feature design → use `wms-feature-plan`
- A v1 → v2 port → use `wms-v2-migrate`
- An immediate recovery playbook → write a runbook instead

If in doubt: if the user is OK leaving a "do not fix, here's why" conclusion on the table, this is the right skill.

## Investigation protocol

Do these in order. Do not skip to a verdict.

1. **Pin the question.** Re-state the investigation in 1–5 explicit questions. If the list grows past 5, push back — propose splitting into multiple reports. Vague questions produce vague reports.
2. **State initial hypotheses with confidence.** Low / medium / high. Include at least one "nothing is actually wrong" hypothesis — absence of a bug is a valid finding.
3. **Choose method.** Code read? Log/metric inspection? DB query? Repro? Interview? Name the sources you will consult.
4. **Gather evidence.** For each piece: quote source (`file:line`, log line, query output), observation, which hypothesis it supports or contradicts. Prefer primary evidence (actual code, actual logs) over secondary (someone's memory, earlier docs).
5. **Re-rank hypotheses.** Make the update explicit. If confidence went down, say so — that's often the most useful finding.
6. **Write the verdict before the recommendation.** The verdict is what is (probably) true; the recommendation is what to do about it. Conflating them hides uncertainty.
7. **Call out what you could NOT answer.** Open questions go in a dedicated section, so follow-up work has a scoped starting point.

## Pre-investigation phase (specialist agents — run AFTER pinning the question, BEFORE gathering evidence)

After the investigation question is pinned (step 1 above), route to one or more specialist agents to accelerate hypothesis generation and evidence gathering. Their findings become raw evidence in §5 — they do NOT replace the protocol above.

**Routing table — invoke when ANY trigger matches:**

| Agent | Invoke when | What to ask for |
|---|---|---|
| `tracer` | Root cause is unclear, ≥2 competing hypotheses exist, bug involves concurrency / lock contention / race condition / `StaleObjectStateException`, or symptom is intermittent | Ranked competing hypotheses with evidence-for / evidence-against each, uncertainty level, recommended next probe — feed directly into §3 Initial Hypotheses |
| `analyst` | Investigation question is vague or has scope creep risk, user could reasonably disagree about what "wrong" means, or the question implies an undefined acceptance criterion | Clarified question framing, scope boundary, what a "nothing is wrong" conclusion would look like — feed into §2 Questions |
| `architect` | Investigation spans ≥3 services, requires understanding transaction / tenant routing / caching architecture, or needs file:line evidence for how a subsystem currently works | Current-state architecture evidence (file:line), which constraints are load-bearing, what the code says vs what the doc says — feed into §4 Method and §5 Evidence |

**Skip pre-investigation when:**
- The question is already precise and the investigation is a single focused code read or DB query
- The user has explicitly said "just investigate" / "I know the scope"

**Fold findings into the report:**
- `tracer` findings → §3 Initial Hypotheses (tracer's ranked list becomes the starting hypothesis table); update confidence after your own evidence pass
- `analyst` findings → §2 Questions (refined question list); flag any scope risks in §9 Open Questions
- `architect` findings → §4 Method (add the specific files/queries to consult), §5 Evidence (architecture findings are primary evidence)

## Pre-draft enumeration (Layer 1 — code-grounding before evidence)

Before drafting §5 Evidence, produce a single Sources-In-Scope table by **enumeration, not memory**:

1. **Symbol grep — every entity/method/constant the question references:**
   ```
   grep -rln "<symbol>" src/main/java sbdocs/3-Resources/ sbdocs/4-Archieves/
   ```
2. **Pattern grep — every place that exhibits the suspected pattern**, not just the named one. Reservation leak? Grep every `reservedamount` write. Connection-pool saturation? Grep every Hikari property.
3. **Cross-reference prior reports** — any related investigation in `sbdocs/3-Resources/reports/` or archives. List them; coordinate or supersede.
4. **List metric / log sources by name** if the question implies them — Grafana panel name, log query, DB query — so §4 Method is grounded.

Place this enumeration as §3.5 (between Method and Evidence) so the evidence section can map findings to specific sources, not vague memory.

## Completeness checklist (Layer 2 — gate before declaring the report ready)

Walk every row. Mark `✓ <reference>` or `no — <rationale>`. Empty rows block sign-off.

| # | Concern | Considered? |
|---|---|---|
| 1 | All in-scope code files / log sources / queries enumerated in §3.5 |  |
| 2 | At least one "nothing is actually wrong" hypothesis in §3 |  |
| 3 | Each hypothesis has primary evidence (file:line, log line, query output), not paraphrase |  |
| 4 | Confidence assigned per hypothesis; uncertainty stated explicitly when present |  |
| 5 | What you LOOKED FOR but didn't find — null results documented as findings |  |
| 6 | v1/v2 deltas if both versions are in scope |  |
| 7 | Cross-references to related reports / plans cited |  |
| 8 | §9 Open Questions populated with any sub-questions you couldn't answer |  |
| 9 | §8 Recommendation explicitly picks one of: Fix now / Fix later / Do NOT fix / Monitor / Investigate further |  |
| 10 | If recommendation = Fix now/later — note that the downstream plan must ship a verify script |  |
| 11 | **Ticket** — inbound ticket (if any) recorded in frontmatter + §10; if recommendation = Fix now/later, either an `SBDEV-####` was created per §Ticket resolution or §8 says explicitly that none is filed yet. `Do NOT fix` / `Monitor` / `Investigate further` → `no — no ticket warranted` |  |

## Output document

Save to `sbdocs/3-Resources/reports/`. **Filename MUST follow the naming convention in the section below** — `YYMMDD-kebab-description.md`, where YYMMDD is today's date in YYMMDD format. Use the template at `sbdocs/9-System/templates/wms-investigation-report-template.md`. Canonical references for shape and depth (filenames as currently on disk):
- `sbdocs/1-Projects/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md`
- `sbdocs/4-Archieves/wms1/plan/WMS_OSIV_Disabled_Audit.md` (legacy filename — preserved as archive)
- `sbdocs/4-Archieves/wms2/plan/Reservation_Leak_Analysis.md` (legacy filename — preserved as archive)
- `sbdocs/4-Archieves/wms1/plan/WineCo_Staging_Lane_Investigation.md` (legacy filename — preserved as archive)
- `sbdocs/3-Resources/reports/260424-wms-oms-notification-delivery-guarantees.md` (more recent shape — section numbering, hypothesis ranking, recommendation table)

## Filename naming convention

**The `YYMMDD-` prefix is REQUIRED for every new investigation report.** It makes the latest reports sort to the top of the directory listing, which is how reviewers identify which reports are current vs. stale. Use today's date in YYMMDD format (e.g., `260424-` for 2026-04-24).

- New report: `YYMMDD-kebab-description.md` (e.g., `260424-wms-oms-notification-delivery-guarantees.md`).
- Existing reports without the prefix in `4-Archieves/` are legacy and remain as-is.
- **Reports never take an `SBDEV-####` filename prefix**, even when a ticket exists or gets created at handoff — that prefix belongs to plans. The ticket lives in the frontmatter (`ticket:` / `ticket_url:`), not the filename. See §Ticket resolution.

Required sections (in template order):
1. Context & Trigger
2. Questions (1–5, explicit)
3. Initial Hypotheses (table with confidence)
4. Method
5. Evidence (one sub-section per finding, tied back to a hypothesis)
6. Updated Hypothesis Ranking
7. Verdict (with overall confidence)
8. Recommendation — pick exactly one: Fix now / Fix later / Do NOT fix / Monitor / Investigate further
9. Open Questions
10. References

## Non-negotiable WMS context

Same gotchas as the other skills — bring them in when relevant:
- v1 `Location.equals()` is broken; most v1 entities use `Object.equals()` (reference equality) which fails under OSIV=false.
- v2 tenant writes need `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
- OSIV disabled in both versions — non-transactional methods split into mini-sessions with no L1 cache.
- Multi-tenant: N replicas × T tenants × maxPoolSize can exceed PostgreSQL `max_connections` — always do the math.
- Mockito 3.3.3 in v1 — no static mocking.
- ERP boundaries: OMS is MySQL (v1 Zend Framework 2 / v2 Laravel 12); WMS is PostgreSQL; cross-DB joins are conceptual, not enforced. For reconciliation investigations, list the conceptual joins explicitly.

## Evidence discipline

- **Quote, don't paraphrase.** A hypothesis "confirmed by logs" without the log line is not evidence.
- **Prefer null results.** If you looked for something and it wasn't there, say so — it kills the hypothesis cleanly.
- **Assign confidence, don't dodge it.** "Likely" is fine; "100%" needs a deterministic argument (stack trace + code + commit); "uncertain" with reasons is better than silent uncertainty.
- **Separate facts from inferences.** Findings (what the code says) vs inferences (what you conclude). Mark inferences as such.

## When uncertain

- Not enough evidence for a verdict → recommendation = **Investigate further** with specific signals/queries listed. This is a valid, common outcome and preferable to guessing.
- Verdict conflicts with user's expectation → call it out plainly in §7. Don't soften.
- Question turns out ill-posed → stop and offer to re-frame rather than answering a question that can't be answered.

## Ticket resolution (outcome-gated — NOT up front)

Unlike `wms-bugfix-plan` / `wms-feature-plan`, this skill does **not** open a ticket before the work starts. An investigation can legitimately conclude "nothing is wrong" or "do not fix", and filing a ticket for a defect that turns out not to exist pollutes the backlog. Report filenames stay `YYMMDD-kebab-description.md` either way — a report is never renamed to `SBDEV-####`.

**Inbound — a ticket already exists (check at protocol step 1):**
- If the prompt names an `SBDEV-####`, a ClickUp URL, or a bare task id, fetch it with `mcp__clickup__clickup_get_task` and use the reporter's own wording in §1 Context & Trigger.
- Record it in the report frontmatter as `ticket: "SBDEV-####"` and `ticket_url: "https://app.clickup.com/t/<id>"` (add both keys — the report template doesn't ship them), and link it from §10 References.
- When the report concludes, post the §7 Verdict + §8 Recommendation back to that ticket via `mcp__clickup__clickup_create_comment` so the investigation isn't stranded in the vault. Confirm with the user before commenting — it notifies watchers.

**Outbound — create a ticket ONLY when the report hands off to a plan:**

Trigger: §8 Recommendation is **Fix now** or **Fix later**, no ticket already covers the finding, and the user wants the plan drafted. `Do NOT fix`, `Monitor`, and `Investigate further` get **no ticket** — the report itself is the deliverable.

1. **Search first** — `mcp__clickup__clickup_search` on the 2–3 most distinctive keywords from the verdict (service/class name, exception type, config key). Reuse an existing open ticket rather than duplicating; tell the user which one matched.
2. **Create it** with `mcp__clickup__clickup_create_task`:
   - `list_id: "901103718309"` — Fulfillment Development Backlog, the default for all WMS work. Don't ask which list.
   - `name` — `[WMS v{1|2}] <one-line symptom or capability>`, drawn from §7 Verdict rather than the investigation question (the question is what you didn't know; the verdict is what you found).
   - `markdown_description` — the verdict in 2–4 sentences, the primary evidence (file:line, query output, log line) that carries it, affected version + tenant(s), and `Investigation: sbdocs/3-Resources/reports/YYMMDD-kebab-description.md`. The report is the evidence of record — link it, don't restate it.
   - `priority` — `"high"` for confirmed data corruption / stuck workflow / production impact; `"normal"` otherwise. `"urgent"` only when the user says production is down.
   - `task_type` — `"Bug"` when handing to `wms-bugfix-plan`, `"Feature"` when handing to `wms-feature-plan`; retry without it if the type doesn't exist in the workspace.
   - **Show the user the proposed `name` + `priority` and get a go-ahead before the call** — this writes to a shared tracker.
3. **Record it in the report before handing off** — write the `SBDEV-####` and URL into §8 Recommendation and §10 References, plus the `ticket:` / `ticket_url:` frontmatter keys. This is what stops a duplicate: the downstream skill's own Ticket-resolution phase sees the ticket named in the prompt and reuses it instead of creating a second one.

**If the handoff happens in a later session** and you did not create the ticket here, say so explicitly in §8 ("no ticket filed yet — `wms-bugfix-plan` will open one"). Leave `ticket: ""`, so nobody assumes the work is tracked when it isn't.

## Handoff to other skills

The report ends an investigation; it does not start a fix. When the recommendation is "Fix now" or "Fix later":
- Note the target skill in §8: "draft via `wms-bugfix-plan` for v1" or "via `wms-feature-plan` for v2".
- Run the outbound ticket flow in §Ticket resolution above, and pass the resulting `SBDEV-####` into the plan skill so it reuses the ticket rather than opening a duplicate.
- Cross-link the plan from §10 References after it's created.
- If v1 fix is applicable, expect a `wms-v2-migrate` follow-up plan; flag that too.

## Verification script — not produced here, required downstream

This skill produces a *descriptive* report, not an actionable plan, so no acceptance script ships with the report itself. **However:** if the recommendation in §8 is "Fix now" or "Fix later", the downstream plan generated via `wms-bugfix-plan` / `wms-feature-plan` MUST ship with a `sbdocs/9-System/scripts/verify-<plan-id>.sh` per those skills' Verification-script section. When you write the recommendation, mention this expectation explicitly so the next session can't forget it.
