---
name: wms-investigation-report
description: Produce an evidence-based investigation report for a WMS concern without committing to a fix. Use when the goal is to understand / diagnose / audit rather than implement — metric anomaly, suspected race condition, pre-feature feasibility study, tech-debt audit, connection pool saturation, reservation leak, OSIV impact audit, cross-system reconciliation question, or "should we even fix this?" decision. Output is a report with hypotheses, evidence, verdict + confidence, and a recommendation (fix now / fix later / do not fix / monitor / investigate further). Does NOT produce a fix plan or implement changes.
---

# WMS Investigation Report

Produces an evidence-driven investigation report at `sbdocs/3-Resources/reports/`. The output ends in a verdict + recommendation, NOT an implementation plan.

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

## Handoff to other skills

The report ends an investigation; it does not start a fix. When the recommendation is "Fix now" or "Fix later":
- Note the target skill in §8: "draft via `wms-bugfix-plan` for v1" or "via `wms-feature-plan` for v2".
- Cross-link the plan from §10 References after it's created.
- If v1 fix is applicable, expect a `wms-v2-migrate` follow-up plan; flag that too.

## Verification script — not produced here, required downstream

This skill produces a *descriptive* report, not an actionable plan, so no acceptance script ships with the report itself. **However:** if the recommendation in §8 is "Fix now" or "Fix later", the downstream plan generated via `wms-bugfix-plan` / `wms-feature-plan` MUST ship with a `sbdocs/9-System/scripts/verify-<plan-id>.sh` per those skills' Verification-script section. When you write the recommendation, mention this expectation explicitly so the next session can't forget it.
