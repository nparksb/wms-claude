---
name: wms-bugfix-plan
description: Produce a deeply-grounded bug fix plan document for the WMS codebase (v1/wms-api or v2/wms2-api) from an error description, stack trace, exception message, HTTP 500 report, or SBDEV ticket. Use when the input is a concrete defect — error logs, stack traces, StaleObjectStateException, ObjectOptimisticLockingFailureException, NullPointerException, NoSuchElementException, optimistic-lock failures, race conditions, stuck states, workflow breakages (putaway / picking / replenishment / receiving / cycle count / palletizing / truck loading / BOL / move stock). Output is a plan document plus the failing tests written by the chained TDD gate — it does NOT implement the fix. BEFORE this skill: run `wms-triage` for the tier verdict — it decides how much of this skill runs, and often ends the task instead.
---

## Execution model

**Run the `wms-triage` skill FIRST — its tier verdict decides which of these phases run at all.** At T0/T1 there is no analysis-delegation phase and no ralplan phase; you do the work inline and the whole thing is minutes. The sequence below is the **T3** shape.

Three phases:
0. **Ticket resolution** — Stay in the main session for this (the confirmation gate needs the user). Resolve or create the ClickUp ticket and move it to `in development` (see "Ticket resolution" below), then pass the resulting `SBDEV-####` and plan filename into the phases below. Complete this phase before delegating analysis — it is two fast MCP calls, and the ticket id feeds the filename, the verify-script name, and the board state.
1. **Analysis phase** — Delegate to an `executor` subagent with `model: opus`. The executor runs pre-investigation agents, analysis protocol, and pre-draft enumeration, producing all file:line evidence, root-cause hypotheses, and affected-sites data.
2. **Plan drafting phase** — Pass the analysis output to `ralplan` (see "Plan generation" below). Do not write the plan document directly from the analysis output.
3. **TDD gate phase** — After the plan is saved (and its verify script, **if the tier calls for one — T2 and below do not**), chain straight into `wms-tdd-gate` in the same session (see "Chain to the TDD gate" below). Do not end the session at the approved plan.

# WMS Bug Fix Plan

## Triage and tier — run `wms-triage` FIRST

**Do not start here.** Invoke `Skill("wms-triage", "<ticket or symptom>")` before anything below. It owns:

- the four-question **triage probe** (already fixed? reproduces? is the reported cause the real cause? one line?),
- the **tier router** (T0-T3) and the mid-flight escalation triggers,
- **the floor** — the five things that never scale at any tier,
- the **ticket policy**, and **row hygiene** for verify scripts.

Those rules live in exactly one file. Do not restate them here; if one is wrong, fix `wms-triage/SKILL.md`.

**This skill is the T3 shape.** The triage probe frequently ends the task before this skill is needed — that is the intended outcome, not a failure to engage. Come back here only when the probe says `needs a plan: yes` at **T2** (reduced: no ralplan, no verify script) or **T3** (everything below).

Produces a reviewable fix plan saved into the Obsidian vault at `sbdocs/1-Projects/wms{1|2}/plan/`. Implementation happens AFTER review in a separate session.

## Trigger

User hands you one of:
- A stack trace (Java exception + class:line)
- An HTTP 500 response or error log line
- A bug description referencing a WMS workflow (putaway, picking, replenish, receiving, cycle count, palletize, move stock, truck loading, cancel order, etc.)
- A SBDEV ticket number (`SBDEV-####`) or ticket URL
- A reproducible symptom ("unit load gets stuck", "pallet cannot be scanned", "duplicate send to nirvana", "optimistic lock", "stale entity")

## Target version detection

Decide v1 vs v2 BEFORE analyzing. Ask the user if ambiguous.

| Signal | Version |
|--------|---------|
| Stack trace references `net.aim_ai.wms.*` + `javax.persistence` | **v1** (Java 8, Spring Boot 2.3.7) |
| Stack trace references `jakarta.persistence`, `@Transactional("tenantTransactionManager")` | **v2** (Java 21, Spring Boot 3.5.9) |
| Error from mobile UI port :3001 | Could be either — ask |
| Ticket mentioned without version | **Ask the user** |

Read the sub-project `CLAUDE.md` for the detected version FIRST — it contains critical rules like "only `Location` has `equals/hashCode` (and it's broken)" for v1.

## Ticket resolution (MANDATORY — run after version detection, before drafting)

Every plan this skill emits is ticket-backed. **If the prompt does not name a ticket, create one in ClickUp** — do not fall straight through to `YYMMDD-` naming.

1. **Look for a ticket in the prompt** — `SBDEV-####`, a ClickUp task URL (`https://app.clickup.com/t/<id>`), or a bare task id. If found, fetch it with `mcp__clickup__clickup_get_task` to pull the reporter's own wording into §1 Problem Statement, then skip to step 4.

2. **Search before creating** — run `mcp__clickup__clickup_search` with the 2–3 most distinctive keywords (service/class name, exception type, workflow name). If an open ticket already covers this defect, reuse it instead of opening a duplicate, and tell the user which one you matched.

3. **Create the ticket** with `mcp__clickup__clickup_create_task`:
   - `list_id: "901103718309"` — Fulfillment Development Backlog, the default for all WMS work. Don't ask which list.
   - `name` — `[WMS v{1|2}] <one-line symptom>` (e.g. `[WMS v2] Stock history report mis-aggregates shared SKUs across clients`). Describe the symptom the operator sees, not the code fix.
   - `markdown_description` — symptom, affected version + tenant(s), reproduction steps or the triggering data condition, and the stack trace / error message verbatim when one was supplied. Append `Plan: sbdocs/1-Projects/wms{1|2}/plan/<filename>.md` once the filename is settled.
   - `priority` — `"high"` for data corruption, stuck workflows, or a production outage; `"normal"` otherwise. `"urgent"` only when the user says production is down. State the reasoning in one line.
   - `task_type: "Bug"` — if the call errors because the type doesn't exist in the workspace, retry without it.
   - **Show the user the proposed `name` + `priority` and get a go-ahead before the call** — this writes to a shared tracker. Skip the confirm only when the user already said "file the ticket" / "just draft it", or has authorized ticket creation earlier in the session.

4. **Record the ticket** — take `custom_id` (the `SBDEV-####` form; fall back to `id` if the workspace returns no custom id) and the task `url` from the create/get response, then use them for:
   - the plan filename — `SBDEV-####-kebab-description.md`
   - frontmatter `ticket: "SBDEV-####"` and `ticket_url: "https://app.clickup.com/t/<id>"`
   - the verify script — `sbdocs/9-System/scripts/verify-SBDEV-####-kebab-description.sh`

5. **Move the ticket to `in development`** — the last thing before analysis begins. `mcp__clickup__clickup_update_task` with `status: "in development"`. This applies to **both** paths: a ticket the user supplied and one you just created. The board should show the work as picked up before you spend a single agent on it, not after the plan lands.
   - The exact string on Fulfillment Development Backlog is lowercase **`in development`**. Do not invent `In Progress` / `In Development` — the API rejects a status the list doesn't define. The ladder has no separate planning state, so `in development` covers planning through implementation.
   - **Never move a ticket backwards.** If it is already at `in development` or beyond (`comitted local`, `pr submitted`, `on dev`, …), leave it and say what you found — a ticket already at `pr submitted` probably means this plan duplicates work in flight.
   - No confirmation needed for this one. The user asking for a plan is the authorization; it's a status flip, not a new artifact on a shared board.
   - No ticket (the fallback below) → nothing to update. Say so.

**Fall back to `YYMMDD-kebab-description.md`** only when the ClickUp MCP is unavailable or the user explicitly declines a ticket. In that case leave `ticket: ""`, skip step 5, and note at the top of §1 that the ticket still needs filing.

## Pre-draft question phase (Layer 3 — MANDATORY when triggered)

**Triggers — ask 3-5 clarifying questions BEFORE drafting if ANY of:**
- Scope is ambiguous (v1 vs v2, single PR vs phased rollout)
- A behavior change is user-visible (UX shift, error-mode shift, response-time shift)
- Concurrency semantics are not obvious from the prompt
- A performance claim has no measurable target
- A non-additive contract change is implied (API, DB schema, persisted state, frontend payload shape)
- The fix touches a flow where the user could legitimately disagree about correctness

Default question set (adapt — pick the 3-5 most relevant):
1. **Scope** — v1, v2, or both? Single PR or phased rollout?
2. **Behavior change** — what does the user see today vs after the fix? Is the UX shift intentional?
3. **Concurrency** — what should happen when two operators race? Block, fail fast, or queue?
4. **Measurable target** — for performance work, what number defines "done well"?
5. **Backward compatibility** — is breaking any contract OK, or must everything stay additive?
6. **Coordination** — does any in-flight plan or sibling ticket cover the same code paths?

**Skip questions when (tier-gated — see `wms-triage`):**
- **T0 always; T1 unless a user-visible contract changes.** The router already answered this; do not re-derive it
- The fix is mechanical (typo, missing null-check, single `.equals()` → `.getId().equals()`)
- The user has already answered every question category in the prompt
- The user has explicitly asked you to "just draft" / "use reasonable defaults"

Document the answers (or the explicit "use defaults" decision) in the plan's §10 Open Questions / Resolved Decisions — never silently choose for the user on these categories.

## Pre-investigation phase (specialist agents — run BEFORE drafting)

Before writing the plan body, route the input to one or more specialist agents to surface evidence that the plan author cannot derive from code reading alone. Each agent returns findings; fold those findings into the plan's §1 (Root Cause), §3 (Fix Design), and §5 (Implementation Steps).

**Routing table — invoke when ANY trigger matches:**

| Agent | Invoke when | What to ask for |
|---|---|---|
| `tracer` | Concurrent bug, race condition, `StaleObjectStateException`, `ObjectOptimisticLockingFailureException`, optimistic/pessimistic lock failure, layered bug with ≥2 plausible hypotheses, root cause unclear from the symptom alone | Competing hypotheses ranked by evidence, evidence-for / evidence-against each, uncertainty level, recommended next probe |
| `analyst` | Feature work or behavior change with ambiguous scope, input has no concrete stack trace / error message, acceptance criteria are undefined, behavior change where the user could reasonably disagree about correctness | Requirements gaps, undefined acceptance criteria, scope risks, questions to resolve before the plan is authoritative |
| `architect` | Code path crosses ≥3 services/modules, fix touches transaction managers / tenant routing / caching architecture, or a second-opinion is needed after `tracer` to verify hypotheses against actual code structure | File:line evidence for the suspected root cause, which architectural constraints apply, which alternative fixes were ruled out and why |

**Skip pre-investigation when (tier-gated):**
- **T0/T1: skip entirely.** **T2: one `architect` consult — a single specific question about the riskiest design choice, not a loop.** Only T3 runs `tracer` / `architect` as full passes
- Fix is mechanical: single null-check, `.get()` → `.orElseThrow()`, typo, constant swap
- The user has explicitly said "just draft" / "use reasonable defaults"

**Multi-agent pattern (parallel when independent):**
- Bug with unclear root cause + complex code path → run `tracer` + `architect` in parallel; both feed §1 (Root Cause Analysis)
- Feature with vague scope → run `analyst` first; if result reveals architectural complexity, follow with `architect`
- Do NOT run `analyst` on a concrete bug with a stack trace — it will ask questions instead of finding answers

**Fold findings into the plan:**
- `tracer` findings → §1 Root Cause sub-sections, especially the "winning" hypothesis and the evidence that ruled out alternatives
- `analyst` findings → §10 Open Questions / Resolved Decisions (as pre-resolved items) and §8 Acceptance criteria
- `architect` findings → §3 Fix Design ("why this fix and not alternatives"), §4 Architecture Overview (key file:line table)

## Deep analysis mode (sequential-thinking)

For non-trivial bug fixes, invoke `mcp__sequential-thinking__sequentialthinking` BEFORE drafting the plan. Use it to work through the analysis protocol step-by-step with explicit hypothesis branching.

**Trigger sequential-thinking when ANY of:**
- Stack trace points to ≥2 distinct problems (layered bugs, unmasked defects)
- Code path crosses ≥3 services/modules
- Bug involves concurrency (optimistic locks, pessimistic locks, race conditions, `StaleObjectStateException`)
- Regression archaeology is needed (commits re-enabling / disabling fixes)
- Fix requires changes in both API and UI

**Skip sequential-thinking when (tier-gated):**
- **T0/T1/T2: skip.** It is a T3 tool — reserve it for a genuinely unknown root cause
- Single unguarded `.get()` on `Optional`
- Typo, missing null check, single `.equals()` → `.getId().equals()` swap
- Fix is mechanical and already clear from the stack trace

Set `thoughtsNeeded` to 5–10 for layered / concurrent bugs, 3–5 for simpler ones. Use `nextThoughtNeeded=true` to keep iterating until hypotheses stabilize, then proceed to the analysis protocol below.

## Analysis protocol

Do ALL of these before drafting the plan. Do not skip.

1. **Reproduce the code path in your head.** Start at the entry point named in the stack (controller → service → business service → repository). Quote file:line for every hop.
2. **Identify every `.get()` on `Optional` in the hot path.** Any unguarded `.get()` is a candidate 500. Note line numbers.
3. **Check transaction boundaries.** Is the throwing method `@Transactional`? In v2 it MUST be `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` for tenant-scoped writes. **OSIV is NOT symmetric across versions — do not assume it (corrected 2026-08-20, SBDEV-3003).** v2 pins it: `v2/wms2-api/src/main/resources/application.properties:55` has `spring.jpa.open-in-view=false`. **v1 pins it nowhere** — no `spring.jpa.open-in-view` in any tracked file. **UAT and Production run v1 with it off** (set externally); **DEV may not**, and neither does a bare local/CI JVM — both get Spring Boot 2.x's default, which is **on**. So for any v1 concurrency or stale-entity bug: check the setting on the box you reproduced on before concluding whether a caller's entity arrives **detached** (re-fetch = real DB read, fresh version) or **managed** (re-fetch may be an L1 hit returning the same object, unrefreshed). The two cases have different failure modes for the same defect — silent lost update versus `OptimisticLockException`-then-retry. Details and the correction trail: `sbdocs/3-Resources/architecture/wms1-transaction-boundary-map.md` §3, which itself asserted the opposite in ~8 places until 2026-08-20.
4. **Entity equality audit.** In v1, `Location.equals()` is broken (compares xpos/ypos/zpos/name, not id). In v1, most entities use `Object.equals()` (reference equality) — lookups from different sessions return different instances. In v2, `AbstractBaseEntity.equals()` is ID-based and correct. If the bug hinges on `.equals()`, this is almost always the root cause.
5. **Optimistic lock chain.** `StaleObjectStateException` → look for the method that loaded the entity in one mini-session and re-used the reference across another write. Suspect duplicate writes, transfer + second sendToNirvana, or merge after detached state.
6. **Pessimistic lock needs.** Concurrent picker/replenish races often need `findByIdForUpdate` — check the repository for an existing locked variant before suggesting a new one.
7. **Regression archaeology.** Run `git log --oneline <file>` for suspect files. If a fix was re-enabled, disabled, or reworked recently, call it out as "The Regression Chain" with commit SHAs and dates.
8. **DB verification gate (mandatory before writing Root Cause Analysis).** Confirm the symptom at the DB level using `mcp__wms1-wineco-dev__execute_sql`, `explain_query`, or `get_object_details` before drafting any RCA prose. A plan built on code reading alone can plausibly misidentify the root cause — a live query is the only way to prove the data state that triggers the bug. Run at minimum one query that either reproduces the triggering data condition OR confirms the absence of the expected state. Record the query + result inline in §1 (Symptom). Set `db_verified: true` in the plan frontmatter. **If the MCP connection is unavailable, set `db_verified: false` and flag it explicitly at the top of §1 — do not silently omit. A plan flagged `db_verified: false` requires a note on what manual DB check the implementer must run before starting.**

## Pre-draft enumeration (Layer 1 — MANDATORY before drafting §1-§9)

**Tier gate: the enumeration itself happens at EVERY tier — it is grep and one SQL query, and it is where the parallel Spring Data REST delete route and the three-FK fact came from on SBDEV-3011. What scales is whether it becomes a §0 *table in a document* (T2/T3) or three lines on the ticket (T0/T1).**

Before writing a single section of the plan body, produce a single Affected-Sites table by **enumeration, not memory**. The plan body MUST visit every row — either fixing it or explicitly excluding it with rationale. This is the highest-ROI completeness step; ~60-70% of "the plan missed sites" gaps come from skipping it.

### Method

1. **Symbol grep — every method, class, or constant named in the prompt:**
   ```
   grep -rln "<symbol>" src/main/java
   grep -rln "<symbol>" src/test/java
   ```

2. **Pattern grep — every place that exhibits the same suspected root-cause:**
   - "OMS POST inside @Transactional" → `grep -rn "httpRestService\.post" src/main/java/.../service/`
   - "Unguarded `Optional.get()`" → `grep -rn "\.get()" src/main/java | grep -B1 "findBy"`
   - "Inverted re-entrancy guard" → `grep -rn "List<Long>\|Set<Long>" src/main/java/.../service/` and check for `.contains` + `.remove`
   - "void-returning bulk repo method (no chunking)" → `grep -rn "@Modifying" src/main/java/.../repo/` and check for `void` return
   Find adjacent instances of the same bug, not just the named one.

3. **Architecture/design doc lookup — existing analysis of the affected subsystem:**
   Check `sbdocs/3-Resources/architecture/` and `sbdocs/3-Resources/design/` for docs that cover the affected service, package, or pattern. Read any relevant doc before proposing a fix — do not re-derive what is already documented.
   Key docs to check by area (use v1 or v2 doc depending on which codebase you're fixing):
   - Transaction issues → v1: `wms1-transaction-boundary-map.md` | v2: `wms2-transaction-osiv-boundary-map.md`
   - Tenant routing / datasource → v1: `wms1-tenant-routing-datasource-topology.md` | v2: `wms2-tenant-routing-datasource-topology.md`
   - State machine / stuck states → v1: `wms1-state-machine-catalog.md` | v2: `wms2-state-machine-catalog.md`
   - Entity / package structure → v1: `wms1-entity-enumeration-report.md`, `wms1-java-package-analysis.md` | v2: `wms2-entity-enumeration-report.md`, `wms2-java-package-analysis.md`
   - Scheduled jobs → v1: `wms1-scheduled-jobs-catalog.md` | v2: `wms2-scheduled-jobs-catalog.md`
   - Stock unit / inventory → v1: `wms1-stockunit-design.md` | v2: `wms2-stockunit-design.md`
   - Replenishment design → v1: `wms1-replenish-workflow.md`, `wms1-replenish-order-creation.md`, `wms1-multi-unitload-replenish.md` | v2: `wms2-replenishment-design.md`, `wms2-replenish-workflow.md`, `wms2-multi-unitload-replenish.md`
   - Caching / stale data → v2: `wms2-caching-strategy.md`
   - OMS integration failures → v1: `wms1-oms-integration-map.md` | v2: `wms2-oms-integration-map.md`
   - HTTP request / auth / 403/422/500 → v1: `wms1-end-to-end-request-journey.md` | v2: `wms2-end-to-end-request-journey.md`
   - Permission denied / access errors → v1: `wms1-function-permission-map.md` | v2: `wms2-keycloak-role-matrix.md`
   - Exception hierarchy / choosing exception type / rollback → `wms-exception-taxonomy.md` (covers both v1 and v2)
   - Sysprop / config key unknown → v1: `wms1-sysprop-catalog.md` | v2: `wms2-sysprop-catalog.md`
   - Cancel order failures / stuck-cancelled state → v1: `wms1-cancel-cascade-workflow.md` | v2: `wms2-cancel-cascade-workflow.md`
   - Move stock / move unitload bugs → v1: `wms1-move-stock-unitload-workflow.md` | v2: `wms2-move-stock-unitload-workflow.md`
   - Picking bugs → v1: `wms1-picking-workflow.md` | v2: `wms2-picking-workflow.md`
   - BOL / truck loading bugs → v1: `wms1-bol-truck-loading-workflow.md` | v2: `wms2-bol-truck-loading-workflow.md`
   - Cycle count bugs → v1: `wms1-cycle-count-workflow.md` | v2: `wms2-cycle-count-workflow.md`
   - Receiving / putaway bugs → v1: `wms1-receiving-putaway-workflow.md` | v2: `wms2-receiving-putaway-workflow.md`
   - Transfer order bugs → v1: `wms1-transfer-order-workflow.md` | v2: `wms2-transfer-order-workflow.md`
   - Domain term / glossary lookup → `wms-domain-glossary.md` (unified v1+v2) or `wms2-domain-glossary.md` (v2-focused)
   - Architecture decisions (no-JPA, OSIV, TX strategy, native SQL) → `sbdocs/3-Resources/decisions/` ADR-001 through ADR-005
   - Database migration safety → `wms-database-migration-guide.md`
   - v1 vs v2 differences → `wms1-vs-wms2-delta.md`

4. **Cross-reference grep — related plans and prior incidents:**
   ```
   grep -rln "<symbol>" sbdocs/1-Projects/ sbdocs/4-Archieves/
   ```
   List any plan that previously touched the symbol — coordinate or supersede it.

### Required output — place at the top of the plan body as §0

```markdown
## 0. Affected sites (enumeration before drafting)

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | service/Foo.java:123 | foo() inside @Transactional      | yes | yes |
| 2 | service/Bar.java:45  | bar() inside @Transactional      | yes | yes |
| 3 | service/Baz.java:78  | baz() ambient tx, no POST inside | no  | no — different pattern |
```

If any in-scope row is missing from §3 Fix Design (or §5 Implementation Steps), the plan is incomplete and not review-ready.

The §0 table also feeds §9 Acceptance — every in-scope row should map to one POSITIVE check in `verify-<plan-id>.sh`.

## Plan generation — ralplan at T3 ONLY (tier per `wms-triage`)

**T3 only.** A T3 plan goes through the `/oh-my-claudecode:ralplan` consensus loop (Planner → Architect → Critic) for **one** round; run a second round only if the Critic returns a **High**. At **T2**, replace the loop with a single `architect` consult — one specific question about the riskiest design choice — and write the plan yourself. At **T0/T1** there is no plan document to review.

Measured on SBDEV-3011: two consensus rounds over six agent passes produced exactly **one** genuinely valuable design change. One round plus the mid-flight escalation triggers would have caught it.

**Why:** The analysis phase identifies what is broken; ralplan ensures the fix design, acceptance criteria, and implementation steps survive a structured review before being committed to disk. Plans that skip consensus routinely have weak §3 Fix Design or acceptance criteria too vague for the TDD gate.

**Workflow:**
1. Complete the Analysis Protocol and Pre-draft Enumeration above. The executor produces a structured analysis bundle.
2. **Invoke `Skill("oh-my-claudecode:ralplan", "--interactive <analysis context>")` with the full analysis.** Pass:
   - §0 Affected Sites table (all confirmed in-scope rows)
   - Root cause per bug (file:line, broken code block, why it fails)
   - Proposed fix design (Before/After code blocks) for each site
   - Acceptance criteria candidates for `wms-tdd-gate`
   - Target plan filename (`SBDEV-####-kebab.md` or `YYMMDD-kebab.md`)
3. ralplan `--interactive` pauses at two points:
   - **After Planner draft** — review and redirect before Architect/Critic run
   - **After Critic approves** — approve, request changes, or reject before the plan is saved
4. The consensus-approved plan is saved to `sbdocs/1-Projects/wms{1|2}/plan/<filename>.md`.

**Exception:** Mechanical one-liner fixes (single null-check, missing `.orElseThrow()`, typo, constant swap) may skip ralplan and be written directly — state the reason explicitly in the plan header.

## Output document

**LENGTH — T2 does not get a document by default** (bullets on the ticket; a document needs Nam's explicit yes — see `wms-triage`). **T3: no hard cap, but every section must earn its place.** The old flat ≤200-line T2 cap is retired: 85% of archived v2 plans blew it, which made it a number people overrode rather than a limit.** A plan's job is to make the fix decidable and reviewable. Past roughly 200 lines it starts competing with the code for maintenance, and over-specified detail becomes its own defect source: SBDEV-3011's 1142-line plan required several correction rounds for precedent counts, annotation counts and citations that were only wrong because they were stated at all. Prefer a shorter plan and a sharper verify script.

Save to `sbdocs/1-Projects/wms{1|2}/plan/`. **Filename MUST follow the naming convention in the section below** — `YYMMDD-kebab-description.md` for untracked plans, `SBDEV-####-kebab-description.md` for ticketed plans. Use the template at `sbdocs/9-System/templates/wms-plan-template.md` for frontmatter. Structure the body like existing plans in the same folder — see `SBDEV-2102-putaway-unit-load-not-found-stuck.md` and `SBDEV-2116-unguarded-optional-get-fix-plan.md` as the canonical references.

Required sections (numbered, in order):

1. **Problem Statement** — user-visible symptoms, exact error messages, reproduction steps.
2. **Root Cause Analysis** — one sub-section per distinct bug (`### Bug 1: ...`, `### Bug 2: ...`). Each sub-section cites `File.java:LINE`, shows the broken code block, explains *why* it fails, and references CLAUDE.md rules when relevant.
3. **(Optional) The Regression Chain** — commit table if the bug was introduced or unmasked by prior commits.
4. **Architecture Overview** — ASCII flow diagram of the code path + "Key Files" table (File | Lines | Role).
5. **Fix Design** — one sub-section per fix (`### Fix A: ...`, `### Fix B: ...`). Each shows Before/After code, file:line, why this fix and not alternatives. Prefer the minimal diff.
6. **File Change Summary** — table (File | Change Type | Description).
7. **Implementation Steps** — ordered, each step small enough to commit atomically. **Every plan MUST include a Prerequisites sub-section (§5.1 of the template — DB state, feature flags, system properties, config / env changes, deploy-order dependencies, data migration, external systems, access, monitoring). Mark rows `N/A` with a one-sentence rationale only when truly nothing applies (pure code-logic refactor).**
8. **Testing Plan** — Unit / Integration / Regression subsections, bulleted. Include specific test method names. For v1 mention Mockito 3.3.3 limitations (no `mockStatic`). For v2 mention Testcontainers PostgreSQL. **MUST include a "Manual test plan" sub-section (table: Scenario | Environment | Steps | Expected Result | Pass/Fail) — click-path smoke, cross-system interactions, SQL-level sanity against a real tenant DB if SQL changed. Mark `N/A` with a one-sentence rationale only for changes with no user-visible path.**
9. **Risks & Mitigations** — table (Risk | Impact | Mitigation).
10. **Implementation Status** — add when implemented in a later session; version it (`## 11. Bug N (v2 — YYYY-MM-DD)`) when new layers are discovered.

## Completeness checklist (Layer 2 — gate before declaring the draft ready)

**Tier gate: T2/T3 only.** At T0/T1 there is no plan document, and the floor (DB query · failing test · mutation-check · one review · suite-vs-baseline) is the whole gate.

Before declaring the plan draft ready for review, walk every row. For each: mark `✓ <reference>` (with §-section / file:line / sub-section reference) OR `no — <one-line rationale>`. **Empty rows block the plan.**

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** — Analysis protocol §8 complete: `execute_sql` / `explain_query` run, result recorded in §1 (Symptom); frontmatter has `db_verified: true` or `db_verified: false` with explicit rationale. **This row must be filled before any other row is marked.** |  |
| 1 | **All callsites enumerated** — every row in §0 visited by §3 Fix Design or excluded with rationale |  |
| 2 | **Adjacent bugs** — other classes / methods with the same root-cause pattern, found via pattern-grep |  |
| 3 | **Backward compatibility** — API contract, DB schema, persisted state, frontend payload shape, error-response shape |  |
| 4 | **Concurrency** — race conditions, lock ordering, optimistic-lock retry, deadlock potential, idempotency under retry |  |
| 5 | **Multi-tenant** — cross-tenant queries, tenant context propagation, per-tenant cache / pool scoping |  |
| 6 | **Error handling** — every new throw path has a handler or an explicit contract change documented |  |
| 7 | **Observability** — logs (level + message), metrics, alert thresholds; especially for new failure modes |  |
| 8 | **Rollback / migration** — Flyway version, data backfill, deploy-order dependencies, feature-flag toggles, sysprop rows |  |
| 9 | **Test coverage** — unit + integration + manual smoke; named test classes and method signatures |  |
| 10 | **Cross-version (v1↔v2)** — applicable, deferred to a paired plan, or N/A with explicit rationale |  |

A `no — rationale` answer is acceptable when defensible (e.g. "no — this is a v1-only plan; v2 has its own evolution"). An empty row means the category was not considered, and the plan is not ready for review.

## Verification script — T3 OPT-IN ONLY, ≤ 15 rows

**Read *Row hygiene* in `wms-triage` before writing a single row.** T2 and below produce **no** script — their assertions live in JUnit/Jest, which run in CI, survive refactors and can be mutation-checked. Even at T3 a script is opt-in and capped at 15 rows: write a row only for an invariant a test genuinely cannot see (a cross-file or cross-repo one, e.g. *"no call site anywhere passes an entity"*).

**Why the mechanism exists at all.** Prose claims like "S3 done" can be over-claimed without anyone noticing; a grep row encodes a fix as a machine-checkable assertion. Real incident: an executor claimed 14 OMS-decoupling sites complete but had only done 3, and a retroactive script exposed it. That is the one job rows are still good at — counting sites across files. They have been a net negative at everything else; see the measured evidence in `wms-triage`.

**What to do, automatically as part of authoring this plan:**

1. Determine `<plan-id>` — the plan filename without `.md` (e.g. `SBDEV-2102-putaway-unit-load-not-found-stuck` for `SBDEV-2102-putaway-unit-load-not-found-stuck.md`).

2. Copy the skeleton:
   ```
   cp sbdocs/9-System/templates/verify-plan-template.sh \
      sbdocs/9-System/scripts/verify-<plan-id>.sh
   chmod +x sbdocs/9-System/scripts/verify-<plan-id>.sh
   ```

3. For EACH fix in the plan body (Fix A, Fix B, Bug 1, F3, etc.) add at least:
   - **One POSITIVE check** — "the new construct exists at the right call-site" (a specific regex of class+method+arg).
   - **One NEGATIVE check** when the fix replaces existing code — "the old construct is gone." (Use `file_not_contains` or invert with `!`.)

4. Optionally append `mvn_test_passes <ClassName>` rows for each touched test class.

5. Wire each check via the `run` runner so the script outputs PASS/FAIL per item. Exit code is 0 only when every check passes.

6. Reference the script's path in the plan markdown's §9 Acceptance section.

**Reference scripts (study before authoring):**
- `sbdocs/9-System/scripts/verify-260424-oms-notification.sh` — cross-service program with 14 sites; demonstrates `file_count_at_least`, multi-line regex via `file_contains_ml`, and `mvn_test_passes` integration.
- `sbdocs/9-System/scripts/verify-SBDEV-2095.sh` — focused 4-fix plan with positive + negative assertions per fix and per-repo signature checks.

**Tier gate:** a verify script is **T3 opt-in only**, capped at 15 rows. At **T2 and below there is no script** — the failing test IS the acceptance check, and cross-file invariants that a test cannot see are the only reason to add a row at all. This supersedes any earlier text in this skill requiring a script at T2.

**Build it from `sbdocs/9-System/templates/verify-plan-template.sh`** — the two defects that used to make it unusable were fixed 2026-08-21: `file_not_contains` now guards `[ -f "$2" ] || return 1` (it used to PASS for a file that does not exist, a fault 51 scripts inherited) and `mvn_test_passes` now checks the exit code plus a real `Tests run:` summary line (it used to grep strings `mvn -q` suppresses, so it was permanently red in 38 scripts). A mutation-checked guard test pins both at `sbdocs/9-System/templates/test-verify-plan-template-helpers.sh` — run it if you touch the template. Do NOT fork a one-off script from a sibling `verify-*.sh`: that re-detaches from the guard test, which is how the original two defects survived for months.

**And run it, do not merely read it.** Three separate bugs in SBDEV-3011's script were found only by executing it: a permanently-red row (`NoDeletePagingAndSortingRepository` *contains* the substring `PagingAndSortingRepository`), a negative satisfied by its own explanatory comment, and a `PLAN` path unresolvable from a worktree. Then re-check each fix against the unfixed tree, so a repair cannot have quietly become a false green.

**A plan is not review-ready without acceptance criteria a test can encode.** A verify script is not part of that bar — at T3 it is optional, below T3 it should not exist.

## Chain to the TDD gate (automatic — do NOT stop at the approved plan)

**Tier gate: T2/T3 run the gate skill. At T0/T1 write the failing test inline yourself** — creating a worktree and a gate session for a one-file fix costs more than the fix. The floor still applies: the test must exist, fail for the right reason, and be mutation-checked.

At T2/T3, once the plan is saved AND `verify-<plan-id>.sh` exists, invoke `Skill("wms-tdd-gate", "<path-to-plan-file>")` in the same session. **Do not ask the user whether to run it.** Plan approval already happened at the ralplan Critic step; the human checkpoint for the tests themselves is the gate's own Step 5. A "shall I run the gate?" prompt approves a decision that was already made and forces the gate to re-read the plan cold in a fresh session.

**Why chain rather than defer.** The verify script and the failing tests are both *baselines*, and a baseline is only trustworthy when captured against the unfixed build. A grep-based verify script cannot prove its own assertions have teeth — it can report `Result: N pass, 0 fail` on a build that still contains the defect the plan was written to kill. The gate's Step 4 "unexpectedly passes" row is the negative test that catches exactly that. Capture both baselines in one session, before any production code changes.

**Branch precondition — MANDATORY before the gate writes any file.** The plan lives in `sbdocs/` (not git), but the gate writes Java into `v{1|2}/wms-api`, a real repository. Before invoking:

1. Take the branch name from the plan (§5 Implementation Steps / §8 Rollout — e.g. `feature/SBDEV-####-kebab`). If the plan names none, derive `feature/<plan-id>`.
2. `cd` into the target repo, confirm the working tree is clean, and create/checkout that branch off the correct base (`develop` unless the plan says otherwise).
3. **Never let the gate write tests onto `develop` or `main`.** If the tree is dirty or the base is wrong, stop and ask — do not guess.

**Skip the chain only for these rows.** Name the row that applies and tell the user the gate still owes them a run:

| Condition | Why | Instead |
|---|---|---|
| Plan is a v1+v2 pair | Tests land in two repos; one gate run can't own both | Chain for the version being implemented first; flag the sibling as pending |
| `db_verified: false` | Acceptance criteria may rest on an unproven data condition — the tests would encode a guess | Resolve the DB check first, then gate |
| §10 Open Questions has an unresolved item | The contract is still moving; tests written now get rewritten | Close the question, then gate |
| No Java test surface | Sysprop row seed, doc-only, config-only change | Rely on the verify script + §8 Manual test plan. **Flyway view / function / DDL changes do NOT qualify** — those have a Testcontainers integration-test surface; don't use this row to dodge them |
| Multi-phase plan | Later phases' criteria aren't stable yet | Gate **Phase 1 criteria only**, then re-run the gate per phase |

## Non-negotiable WMS context

Bake these into the plan whenever relevant — they're the most common sources of actual bugs in this repo.

**v1/wms-api:**
- `Location.equals()` compares by coord+name (broken); `hashCode()` mixes in id → equals/hashCode contract violated. ALWAYS use `.getId().equals()` for Location comparison.
- Most other entities use `Object.equals()` — reference equality. Outside a session (and OSIV is **not** reliably on or off in v1 — it is pinned nowhere in-repo, off on UAT/prod, unknown on DEV), two `findById`/`findByName` calls return different instances. Do NOT use `.equals()` on them; compare IDs.
- Mockito 3.3.3 — no `mockStatic()`. If a test needs static mocking, refactor instead.
- No JPA association annotations — manual FK relationships only.
- `RestExceptionHandler` only handles `ApiInvalidParameterException` / `ApiConstraintViolationException` / `MethodArgumentNotValidException` / `ApiMissingUserException` / SSO. `NoSuchElementException` and `NullPointerException` become HTTP 500.

**v2/wms2-api:**
- All tenant-scoped `@Transactional` MUST specify `value = "tenantTransactionManager"`.
- Lock timeout property is `jakarta.persistence.lock.timeout` (not `javax.*`).
- Constructor injection only — add new deps as constructor parameters, not `@Autowired` fields.
- SLF4J parameterized logging: `LOG.debug("msg={}", var)`, not string concatenation.
- Prefer `.orElseThrow(() -> new EntityNotFoundException(...))` over `.get()`.
- `AbstractBaseEntity.equals()` is ID-based — so entity `.equals()` works correctly across sessions. v1 bugs from broken equals generally do NOT reproduce in v2, but **missing `@Transactional`** is almost always a real v2 bug on top of any v1 logic.
- Caffeine caching + Micrometer + Zipkin are wired — don't add alternative metrics stacks.

**Both versions:**
- Multi-tenant. Every tenant has its own database; never assume cross-tenant data in a single query.
- OSIV is **not pinned anywhere in v1's repo** — measured off on UAT and prod, unverified on DEV, so a DEV repro may not match what you ship. Every unannotated method that chains multiple repository calls is suspect either way.
- Never commit `.env`, `auth.json`, `config.php`, `local.php`, `*_dev.properties`, or Jasypt `ENC(...)` values.

## Plan naming convention

**Ticketed is the default** — see §Ticket resolution above; a plan without a ticket in the prompt gets a ClickUp ticket created for it. **The `YYMMDD-` prefix is REQUIRED for the residual case of a plan with no SBDEV ticket** (ClickUp unavailable, or the user declined). It makes the latest plans sort to the top of the directory listing, which is how reviewers identify which plans are current vs. stale. Use today's date in YYMMDD format (e.g., `260424-` for 2026-04-24).

- Ticketed (the normal case): `SBDEV-####-kebab-description.md` — no YYMMDD prefix; the ticket number is the sortable identifier.
- Untracked (fallback only): `YYMMDD-kebab-description.md` (e.g., `260424-runclubline-transaction-boundary-hardening.md`).
- Investigation/debug plans may keep the `-debug-plan` suffix when it adds clarity: `YYMMDD-kebab-description-debug-plan.md`.
- When a v1 plan has a v2 counterpart, use the **same base name** (including the YYMMDD prefix) in both `wms1/plan/` and `wms2/plan/` so v1 and v2 plans are easy to pair.

Do NOT use the older PascalCase / underscore-separated naming style (e.g. `RunClubLine_Fix_Plan.md`) — it sorts unpredictably and obscures dating.

## Horizontal scalability validation (mandatory for every v2 plan)

v2/wms2-api runs as **multiple replicas** behind a load balancer. Even bug fixes can regress horizontal scalability — e.g., adding a field to a thread-local, a non-idempotent write in a retry path, or a new connection-holding transaction. v1 plans may skip this section; v2 plans MUST include it.

**Tier gate: T2/T3.** At T0/T1, state in one line whether the change adds in-JVM state, a scheduled job, a long transaction, or an external call — if all four are no, that is the whole section.

Every T2/T3 v2-targeted plan produced by this skill MUST include the "Horizontal Scalability Validation" section from `sbdocs/9-System/templates/wms-plan-template.md` §7. Fill in the 10-row checklist with an explicit verdict (Yes / No / N/A) for each concern:

1. **In-JVM state** — new Caffeine / ConcurrentHashMap / static / ThreadLocal state visible only to one replica
2. **Connection pool math** — changes to per-request DB connections; recompute `replicas × tenants × maxPoolSize` vs Postgres `max_connections`
3. **Scheduled jobs** — `@Scheduled` / cron additions need ShedLock or single-instance deployment
4. **Long transactions** — holding a DB connection across external I/O or many repository calls
5. **Request affinity** — assuming the follow-up request lands on the same JVM (in-memory session, WebSocket, SSE)
6. **Retry / idempotency** — tolerating replay from another replica after a crash mid-op
7. **Tenant context** — propagating `TenantContext` / `@RequestScope` across `@Async`, `CompletableFuture`, or scheduled jobs
8. **Distributed lock correctness** — pessimistic / optimistic locks held inside `@Transactional(tenantTransactionManager)`, with lock timeout configured
9. **Cache invalidation** — writes to cached entities must `@CacheEvict` / `@CachePut`; shared (Redis) cache eviction propagates across replicas
10. **External notifications** — defer HTTP / message sends to `TransactionSynchronization.afterCommit` so they don't fire twice on retry

For any **Yes** row: provide file:line or test evidence in the "Evidence" sub-table. A bug fix that touches cron jobs, notification pipelines, caches, or lock paths almost always has at least one Yes row — don't default to all-N/A without thinking.

A missing or empty row blocks plan sign-off.

## v2-only constraint checklist (skip entirely for v1 plans)

**Tier gate: T2/T3 as a written table. At T0/T1 the relevant rows are still TRUE — `tenantTransactionManager`, jakarta namespace, constructor injection, OSIV-disabled — you simply do not write a table about them.**

Before drafting any v2 plan section, verify each constraint. These don't overlap with the horizontal scalability checklist — they're code-level architectural invariants that differ from v1.

| # | Constraint | What to check | Verdict |
|---|---|---|---|
| 1 | **OSIV disabled** | `spring.jpa.open-in-view=false` in v2. Any repository call outside a `@Transactional` boundary opens a new session with no L1 cache. Lazy-loaded associations accessed outside a transaction throw `LazyInitializationException`. Plan must ensure all lazy-load paths are inside a transaction or switched to eager/DTO projection. | Yes / No / N/A |
| 2 | **Transaction manager** | Tenant-scoped writes must use `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. Using the default `transactionManager` silently routes to the wrong datasource. | Yes / No / N/A |
| 3 | **`@Transactional(readOnly=true)`** | All read-only service methods must declare `readOnly=true`. This enables Hibernate read optimization and prevents accidental writes in read paths. | Yes / No / N/A |
| 4 | **Caffeine cache invalidation** | Any write to an entity whose type is cached (`@Cacheable`) must pair a `@CacheEvict` or `@CachePut`. Check `wms2-caching-strategy.md` for the full list of cached types. Missing eviction = stale data served to all replicas. | Yes / No / N/A |
| 5 | **Jakarta namespace** | v2 uses `jakarta.*` (Spring Boot 3.x / Jakarta EE 10). Any code copied or ported from v1 that imports `javax.persistence`, `javax.validation`, or `javax.transaction` will fail at compile or runtime. Find-replace before the fix is implemented. | Yes / No / N/A |
| 6 | **H2-compatible test SQL** | v2 unit tests (non-Testcontainers) run against H2. Native PostgreSQL syntax (`::text`, `ILIKE`, `ON CONFLICT`, `gen_random_uuid()`, array operators) must be replaced or the test promoted to a Testcontainers integration test. | Yes / No / N/A |
| 7 | **`BaseControllerTest` for controller changes** | Any new or modified controller endpoint requires a test extending `BaseControllerTest`. Verify it wires the correct `MockMvc` setup and tenant context. | Yes / No / N/A |
| 8 | **Micrometer metrics** | If the fix touches a high-frequency path (picking, receiving, replenishment, club runs), check whether an existing metric covers the regression. If not, add a counter or timer via `MeterRegistry` — reuse existing metric names before inventing new ones. | Yes / No / N/A |

For any **Yes** row: cite the specific file:line or document in the plan body where the constraint is addressed. A v2 plan with unchecked rows is not review-ready.

## Post-implementation gate (mandatory when executing the plan)

This skill produces a *plan* plus the chained TDD gate's failing tests — never production code. Whenever the plan is later executed, the executor (future session or another skill like `wms-v2-migrate`) MUST enforce this gate. Reflect the gate in the plan's §8 Testing Plan so downstream work inherits the requirement. When the TDD gate ran, its tests ARE the primary completion criterion — point 1 below is already partly satisfied, and the executor's job is to make those tests pass without weakening them.

A fix (single-commit OR phase of a batch plan) is NOT complete until all four hold:

0. **If the plan has a verify script** (T3 opt-in only — most plans have none; skip this item and say so), run it first AND last. Before any code change, run `bash sbdocs/9-System/scripts/verify-<plan-id>.sh` to capture the FAIL baseline. Re-run after every cluster of changes. **Final acceptance: the script reports `Result: N pass, 0 fail`.** The implementing agent / human MUST paste this exact line in the end-of-task report. Filename-level checks ("the file mentions OmsNotificationHelper") are not sufficient — content-level grep at the call-site is what catches over-claims.

1. **Tests exist for every code change.** At minimum one unit test asserting the new behavior. Repository native-SQL or JPQL changes require a Testcontainers integration test. Controller endpoint changes require a controller test (extending `BaseControllerTest` in v2). If the originating report added no tests, the fix still adds them — don't inherit the gap. If coverage is truly impossible (auto-generated code, config-only change), record the reason in the plan's §8 Testing Plan.

2. **Run the tests; all must pass.** Target the touched class with `mvn test -Dtest=<ClassName>` first for fast feedback. Run `mvn verify` (full suite incl. Testcontainers) before the fix leaves the branch. On any failure: fix the port, fix the test, or roll back — do NOT mark the phase complete.

3. **Update the plan document before sign-off.** Fill in the Implementation Status section with:
   - v2 commit SHA(s) for each fix in the phase
   - Test class + method names added or updated
   - `mvn test` / `mvn verify` result summary (count passed / failed / skipped)
   - Final verify-script line: `Result: N pass, 0 fail, M skip`
   - Any deliberately-skipped coverage with a one-sentence rationale

Never announce a phase or fix complete with any of these four unchecked.

## When uncertain

Stop and ask the user rather than invent. Especially:
- Unclear target version → ask.
- Symptoms not reproducible from the code path → propose hypotheses with confidence scores (see SBDEV-2102 Bug 6 section for the pattern), don't pick one silently.
- Fix requires database migration or config change → flag it explicitly in section 6.
