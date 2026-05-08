---
name: wms-v2-migrate
description: Port or adapt an existing v1/wms-api plan (bug fix or feature) into a corresponding v2/wms2-api plan by deeply analyzing the v2 codebase, determining which v1 fixes still apply, and discovering new v2-only issues along the way. Use when input is a pointer to a v1 plan file (usually under sbdocs/1-Projects/wms1/plan/ or sbdocs/4-Archieves/wms1/plan/), a list of v1 fixes to port, or phrases like "port to v2", "v1 to v2 applicability", "migrate to v2", "backport", "v2 equivalent". Output is a v2-specific plan document — does NOT implement changes.
---

# WMS v1 → v2 Migration Plan

Produces a v2-specific plan document, tailored from an existing v1 plan by verifying each v1 fix against the v2 codebase. Saved to `sbdocs/1-Projects/wms2/plan/`. Work is implemented AFTER review.

## Trigger

User hands you:
- A path to a v1 plan file (e.g., `sbdocs/1-Projects/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md` or an archived one in `4-Archieves/wms1/plan/`).
- A list of v1 fixes / commits to port.
- A phrase like "port SBDEV-#### to v2", "v2 equivalent of X", "migrate the Y fix".
- An already-implemented v1 fix they want replicated in v2.

If the v1 plan doesn't exist yet, stop and invoke **wms-bugfix-plan** or **wms-feature-plan** first.

## Plan generation — MANDATORY: use ralplan

Every migration plan produced by this skill **MUST** go through the `/oh-my-claudecode:ralplan` consensus loop (Planner → Architect → Critic). Do not write the plan document directly.

**Why:** Migration plans feed directly into `wms-tdd-gate`. A plan that skips consensus produces incomplete acceptance criteria, missed v2-only issues, and inadequate TDD gate checklists — all of which cause the implementation phase to fail or regress.

**Workflow:**
1. Complete the Analysis Protocol (steps 1–6 below) to gather all facts, file:line evidence, and v2-only issue candidates.
2. **Invoke `Skill("oh-my-claudecode:ralplan", "--interactive <analysis context>")` with the full analysis.** Pass:
   - All confirmed-missing fixes with before/after v2 code blocks
   - All NEW-N v2-only issues with severity
   - The target plan filename
   - Acceptance criteria requirements for wms-tdd-gate
3. ralplan `--interactive` pauses at two points via `AskUserQuestion`:
   - **After Planner draft** — review the plan and redirect before Architect/Critic run
   - **After Critic approves** — approve, request changes, or reject before the plan is saved
4. The consensus-approved plan is saved to `sbdocs/1-Projects/wms2/plan/<filename>.md`.

**Exception:** Single one-liner ports (config value, pure rename) may skip ralplan and be written directly — state the reason explicitly.

## Deep analysis mode (sequential-thinking)

Migration plans are almost always complex enough to warrant `mcp__sequential-thinking__sequentialthinking`. The v1↔v2 applicability pass benefits greatly from explicit hypothesis branching per fix, and sequential-thinking is the natural tool for that shape of reasoning.

**Trigger sequential-thinking when ANY of:**
- ≥5 v1 fixes to port
- v2 has significant architectural divergence (extracted services, new transaction manager, Jakarta namespace, constructor injection overhaul)
- v1 fix involves `.equals()` / reference equality (v2 may or may not need it depending on `AbstractBaseEntity`)
- Concurrency fix (lock + transaction coupling) — verify BOTH the lock and the `@Transactional(value="tenantTransactionManager", ...)` annotation on the v2 side
- v1 plan mentions "unmasked", "layered", or a "regression chain"

**Skip sequential-thinking when:**
- Porting a single config / property value (one-liner)
- v1 plan is a pure rename / typo fix

Recommended thought structure: one thought per v1 fix — "does this apply to v2? evidence (v2 file:line)?" — then branch into NEW-N discoveries as they surface. Expect 10–20 thoughts for a consolidated port (≥10 fixes). This mirrors the shape of `V2_Consolidated_Picking_Fixes_Port.md`.

## Analysis protocol

This is the hardest of the three skills — don't shortcut. A bad migration plan claims fixes are "already done in v2" when they're not, or misses v2-only bugs that layered on top of the v1 issue.

1. **Read the v1 plan cover to cover.** Extract every fix with its file:line, the code Before/After, the rationale, and the regression chain. Catalog them (e.g., Fix A, B, …, RC-1..RC-13, TD-1..TD-4). This catalog is your checklist.
2. **Read the v2 sub-project CLAUDE.md.** Internalize the v2 adaptation rules (see non-negotiable context below).
3. **Locate each fix's v2 counterpart.** For EVERY fix in the catalog:
   - Find the v2 equivalent file (class and service names often match; paths differ).
   - Find the v2 line range. Use Grep / Read — never guess.
   - Determine status: **Already done** / **Confirmed missing** / **Architecturally different (explain)** / **Not applicable (explain)**.
   - For "Confirmed missing" cases, show the exact v2 code today and the v2-adapted Before/After. Do not copy the v1 patch verbatim — translate it.
4. **Hunt for NEW v2-only issues.** As you read v2 code around each fix, look for problems v2 has that v1 never had:
   - Missing `@Transactional(value = "tenantTransactionManager", ...)` on tenant writes (CRITICAL — makes any pessimistic lock useless).
   - Plain `findById` where `findByIdForUpdate` is needed for concurrency.
   - v2 constructor injection oversights (new service needs a dep that isn't injected).
   - Unsafe `.get()` or `.orElseThrow` with the wrong exception type.
   - Potential NPEs introduced by v2-specific null paths.
   - Label these `NEW-1`, `NEW-2`, … and rank severity.
5. **Verify "Already done" claims.** It is tempting to mark many fixes as already done. For each such claim, quote the v2 line range showing the fix is in place. If you can't quote it, it's not actually already done.
6. **Check for v2 architectural refactors.** v2 often extracts responsibilities (e.g., `PickingOrderMergeService` extracted from `ReplenishOrderJob`). The v1 fix may need to land in a different class, or needs to be split across multiple classes. Spell this out.
7. **Only then invoke ralplan.** Pass the full analysis as context (see "Plan generation — MANDATORY: use ralplan" above). Do NOT write the plan file directly.

## Output document

Save to `sbdocs/1-Projects/wms2/plan/<same-base-name-as-v1-plan>.md` — **preserve the v1 plan's full filename** including any `YYMMDD-` prefix or `SBDEV-####-` ticket prefix. The base-name match makes v1 and v2 plans easy to pair (e.g., v1 `260424-runclubline-transaction-boundary-hardening.md` → v2 `260424-runclubline-transaction-boundary-hardening.md`). Do NOT add a fresh date prefix when porting; the v1 plan's date remains the authoritative timestamp for this work stream.

If the v1 plan you're porting is a legacy file lacking the `YYMMDD-` prefix (e.g., archived plans like `Cancel_Order_Null_SectionId_Fix.md`), still preserve the base name for pairing. Future plans should follow the YYMMDD convention from the start.

Use the template at `sbdocs/9-System/templates/wms-plan-template.md` for frontmatter. Canonical references:
- `sbdocs/1-Projects/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md` (per-fix applicability table + v2-only issues)
- `sbdocs/4-Archieves/wms2/plan/V2_Consolidated_Picking_Fixes_Port.md` (multi-plan consolidation)
- `sbdocs/4-Archieves/wms2/plan/V1_Develop_Commits_March2026_Port.md` (commit-by-commit port)

Required sections (in order):

1. **Header** — Date, Status, Priority, V1 Source Plan(s) (as links), V2 Target (`wms2-api`).
2. **Summary** — counts: X v1 fixes total, Y already exist in v2, Z confirmed still needed, W NEW v2-only issues discovered. Brief note on any significant architectural differences that affect the port (extracted services, Jakarta namespace, etc.).
3. **V1 → V2 Applicability Analysis** — table: `V1 Fix | Description | V2 Verdict | Rationale`. Every v1 fix gets a row. Verdicts: **Needed**, **Needed (CRITICAL)**, **Not needed (V2 already correct)**, **Not needed (but optimize)**, **Architecturally different**.
4. **V2-Specific Adaptation Notes** — short section listing the adaptation rules that apply to every ported change (see below). Copy / tailor for the specific port.
5. **Changes by File** — one subsection per v2 file touched. Each has:
   - Header table: `V1 Fix # | V2 Line | Status | Action | Priority`
   - For every "Confirmed missing" or "Architecturally different" row: expand with **Current code**, **Fix (v2-specific)**, **Why** — with v2 file:line.
6. **NEW Issues Summary** — table of v2-only issues discovered: `NEW-# | Issue | File:Line | Severity | Description`. These often become the most impactful entries in the port.
7. **Implementation Priority** — phased. **Phase 0 MUST list any missing `@Transactional` fixes** because locking fixes are ineffective without them. **Every plan MUST include a Prerequisites sub-section (§5.1 of the template — v2-side DB state, system properties, config / env changes, deploy-order dependencies against oms-laravel-api or omsv2-UI, external systems). Note any v1 prereqs that do NOT apply to v2 due to architectural divergence. Mark rows `N/A` with a one-sentence rationale only when truly nothing applies.**
8. **Testing Plan** — per-fix test port/adapt. V2 tests often need different mocks (see `V2_Consolidated_Picking_Fixes_Port.md` §Testing Plan). Note Testcontainers + PostgreSQL expectation. **MUST include a "Manual test plan" sub-section (table: Scenario | Environment | Steps | Expected Result | Pass/Fail) — at minimum verify the v2 deployment reproduces the v1 happy-path behavior and that the originally-reported v1 symptom cannot be triggered in v2. Cover cross-system interactions (OMS, Keycloak, Micrometer/Zipkin) whenever the port touches them.**
9. **Risk Assessment** — same table shape as feature/bugfix plans, but include risks specific to porting: wrong transaction manager, Jakarta property name, circular DI from new constructor dep, v2 cache invalidation after lock.

## V2-specific adaptation rules (apply to every ported change)

These must appear in **section 4 "V2-Specific Adaptation Notes"** of the plan. Tailor as needed.

1. **Transaction manager:** Every tenant service `@Transactional` MUST specify `value = "tenantTransactionManager"` and `rollbackFor = {BusinessException.class, FacadeException.class}`. Bare `@Transactional` is wrong in v2.
2. **Jakarta vs javax:** Lock timeout property is `jakarta.persistence.lock.timeout`, not `javax.persistence.lock.timeout`. Imports are `jakarta.*` (persistence, servlet, validation).
3. **`Optional` handling:** Use `.orElseThrow(() -> new EntityNotFoundException(...))` or `BusinessException` — never `.get()`.
4. **SLF4J parameterized logging:** `LOG.debug("message={}", var)`. No string concatenation.
5. **Constructor injection:** Add new deps as constructor parameters, not `@Autowired` fields. Verify the constructor updates.
6. **Entity equality:** v2 `AbstractBaseEntity.equals()` is ID-based and correct. v1 `.equals()` fixes for `Location` / `UnitloadType` are typically **not needed** in v2 — but confirm in code, don't assume.
7. **Extracted services:** Logic v1 kept in one class may be split in v2 (example: `PickingOrderMergeService` extracted from `ReplenishOrderJob`). Land the fix in the correct v2 class.
8. **Pessimistic locks:** Reuse existing `findByIdForUpdate` methods where they exist (check the repository first). When one is missing, add it in the same PR as the fix that needs it.
9. **Caching & metrics:** Caffeine + Micrometer + Zipkin are wired. Don't introduce parallel caching or metrics stacks.
10. **Mockito / tests:** v2 uses modern Mockito (can mock statics, constructor-injected mocks). Tests from v1 often need rewriting, not just copying.

## Common traps (check before submitting the plan)

- Claimed "already done in v2" without quoting the v2 line range → verify or downgrade the verdict.
- Forgot to translate `javax` → `jakarta` imports / properties.
- Put `@Transactional` on a tenant write without the `tenantTransactionManager` value.
- Added a pessimistic lock but didn't verify the method is `@Transactional` (lock is released immediately on auto-commit otherwise — see `V2_Consolidated_Picking_Fixes_Port.md` NEW-5).
- Copied v1 code that used `.get()` on Optional — v2 must use `.orElseThrow`.
- Copied v1 Location `.equals()` comparisons — v2 doesn't need the ID-comparison rewrite.
- Proposed a fix in a v2 class that's been deprecated or refactored away — always confirm the class still exists and owns the behavior.

## Plan naming convention

- Preserve the v1 base name so pairs are obvious. Examples:
  - v1: `sbdocs/1-Projects/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md`
  - v2: `sbdocs/1-Projects/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md`
- Multi-plan consolidation: `V2_Consolidated_<topic>_Port.md`.
- Date-pinned commit ports: `V1_Develop_<tag>_<YYYYMM>_Port.md`.

## Horizontal scalability validation (mandatory for every v2 plan)

v2/wms2-api runs as **multiple replicas** behind a load balancer. A port that ignores this can introduce connection-pool exhaustion, duplicated scheduled jobs, stale local caches, or broken tenant context on async paths.

Every plan produced by this skill MUST include the "Horizontal Scalability Validation" section from `sbdocs/9-System/templates/wms-plan-template.md` §7. Fill in the 10-row checklist with an explicit verdict (Yes / No / N/A) for each concern:

Same 10 concerns as `wms-bugfix-plan` §Horizontal Scalability Validation — In-JVM state, connection pool math, scheduled jobs, long transactions, request affinity, retry/idempotency, tenant context, distributed lock correctness, cache invalidation, external notifications.

For any **Yes** row: provide file:line or test evidence in the "Evidence" sub-table. Ports that touch v1 idioms which v2 already solved architecturally (e.g., v1 local cache replaced by v2 Redis cache in `syspropService`) must explicitly note the equivalence and mark the concern N/A with rationale.

A missing or empty row blocks plan sign-off.

## Post-port gate (mandatory for every phase and every single-commit port)

A port (single commit OR phase of a batch plan) is NOT complete until all three of these hold:

1. **Tests exist for every code change.** At minimum one unit test asserting the new behavior. Repository native-SQL / JPQL changes require a Testcontainers integration test. Controller endpoint changes require a controller test (extending `BaseControllerTest` in v2). If the v1 commit added no tests, the port still adds them — don't inherit the gap. If coverage is truly impossible (config-only change, auto-generated migration), record the reason in the plan's Test Plan section.

2. **Run the tests; all must pass.** Target the touched class with `mvn test -Dtest=<ClassName>` first (fast feedback). Run `mvn verify` (full suite incl. Testcontainers) before the phase leaves the branch. On any failure: fix the port, fix the test, or roll back — do NOT mark the phase complete.

3. **Update the plan document before sign-off.** Fill in the Implementation Status section with:
   - v2 commit SHA(s) for each ported v1 SHA
   - Test class + method names added or updated
   - `mvn test` / `mvn verify` result summary (count passed / failed / skipped)
   - Any deliberately-skipped coverage with a one-sentence rationale

Never announce a phase complete, merge its branch, or move to the next phase with any of these three unchecked.

## When uncertain

- Can't locate v2 equivalent → grep the v2 repo for the method/class name, then ask the user.
- v1 fix relies on a v2-refactored-away module → flag it and ask whether the v2 equivalent still has the problem.
- Ambiguous severity of a NEW issue → include it with a conservative severity and a one-line justification rather than dropping it.
