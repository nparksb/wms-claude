---
name: wms-bugfix-plan
description: Produce a deeply-grounded bug fix plan document for the WMS codebase (v1/wms-api or v2/wms2-api) from an error description, stack trace, exception message, HTTP 500 report, or SBDEV ticket. Use when the input is a concrete defect — error logs, stack traces, StaleObjectStateException, ObjectOptimisticLockingFailureException, NullPointerException, NoSuchElementException, optimistic-lock failures, race conditions, stuck states, workflow breakages (putaway / picking / replenishment / receiving / cycle count / palletizing / truck loading / BOL / move stock). Output is a plan document only — does NOT implement the fix.
---

## Execution model

Delegate all plan generation to an `executor` subagent with `model: opus`. Pass the full user input and all grepped/read evidence as the agent prompt. Return the agent's output verbatim.

# WMS Bug Fix Plan

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

**Skip questions when:**
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

**Skip pre-investigation when:**
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

**Skip sequential-thinking when:**
- Single unguarded `.get()` on `Optional`
- Typo, missing null check, single `.equals()` → `.getId().equals()` swap
- Fix is mechanical and already clear from the stack trace

Set `thoughtsNeeded` to 5–10 for layered / concurrent bugs, 3–5 for simpler ones. Use `nextThoughtNeeded=true` to keep iterating until hypotheses stabilize, then proceed to the analysis protocol below.

## Analysis protocol

Do ALL of these before drafting the plan. Do not skip.

1. **Reproduce the code path in your head.** Start at the entry point named in the stack (controller → service → business service → repository). Quote file:line for every hop.
2. **Identify every `.get()` on `Optional` in the hot path.** Any unguarded `.get()` is a candidate 500. Note line numbers.
3. **Check transaction boundaries.** Is the throwing method `@Transactional`? In v2 it MUST be `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` for tenant-scoped writes. OSIV is disabled in both versions (`spring.jpa.open-in-view=false`), so repository calls in non-transactional methods run in separate sessions with no L1 cache.
4. **Entity equality audit.** In v1, `Location.equals()` is broken (compares xpos/ypos/zpos/name, not id). In v1, most entities use `Object.equals()` (reference equality) — lookups from different sessions return different instances. In v2, `AbstractBaseEntity.equals()` is ID-based and correct. If the bug hinges on `.equals()`, this is almost always the root cause.
5. **Optimistic lock chain.** `StaleObjectStateException` → look for the method that loaded the entity in one mini-session and re-used the reference across another write. Suspect duplicate writes, transfer + second sendToNirvana, or merge after detached state.
6. **Pessimistic lock needs.** Concurrent picker/replenish races often need `findByIdForUpdate` — check the repository for an existing locked variant before suggesting a new one.
7. **Regression archaeology.** Run `git log --oneline <file>` for suspect files. If a fix was re-enabled, disabled, or reworked recently, call it out as "The Regression Chain" with commit SHAs and dates.
8. **DB verification gate (mandatory before writing Root Cause Analysis).** Confirm the symptom at the DB level using `mcp__wms1-wineco-dev__execute_sql`, `explain_query`, or `get_object_details` before drafting any RCA prose. A plan built on code reading alone can plausibly misidentify the root cause — a live query is the only way to prove the data state that triggers the bug. Run at minimum one query that either reproduces the triggering data condition OR confirms the absence of the expected state. Record the query + result inline in §1 (Symptom). Set `db_verified: true` in the plan frontmatter. **If the MCP connection is unavailable, set `db_verified: false` and flag it explicitly at the top of §1 — do not silently omit. A plan flagged `db_verified: false` requires a note on what manual DB check the implementer must run before starting.**

## Pre-draft enumeration (Layer 1 — MANDATORY before drafting §1-§9)

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

## Output document

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

## Verification script (MANDATORY companion to every plan this skill emits)

**Why this exists.** Prose claims like "S3 done" can be over-claimed without anyone noticing. A 30-second grep-based script encodes each fix as a machine-checkable assertion so an implementing agent's "DONE" claim is provable. Real incident: an executor claimed 14 OMS-decoupling sites complete but had only done 3 — the verify script (added retroactively) exposed the gap immediately. Every plan ships with one.

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

**A bug-fix plan delivered without a corresponding verify script is not review-ready.**

## Non-negotiable WMS context

Bake these into the plan whenever relevant — they're the most common sources of actual bugs in this repo.

**v1/wms-api:**
- `Location.equals()` compares by coord+name (broken); `hashCode()` mixes in id → equals/hashCode contract violated. ALWAYS use `.getId().equals()` for Location comparison.
- Most other entities use `Object.equals()` — reference equality. With OSIV disabled, two `findById`/`findByName` calls return different instances. Do NOT use `.equals()` on them; compare IDs.
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
- OSIV is disabled. Every unannotated method that chains multiple repository calls is suspect.
- Never commit `.env`, `auth.json`, `config.php`, `local.php`, `*_dev.properties`, or Jasypt `ENC(...)` values.

## Plan naming convention

**The `YYMMDD-` prefix is REQUIRED for every plan that does not have an SBDEV ticket.** It makes the latest plans sort to the top of the directory listing, which is how reviewers identify which plans are current vs. stale. Use today's date in YYMMDD format (e.g., `260424-` for 2026-04-24).

- Ticketed: `SBDEV-####-kebab-description.md` — no YYMMDD prefix; the ticket number is the sortable identifier.
- Untracked (the common case): `YYMMDD-kebab-description.md` (e.g., `260424-runclubline-transaction-boundary-hardening.md`).
- Investigation/debug plans may keep the `-debug-plan` suffix when it adds clarity: `YYMMDD-kebab-description-debug-plan.md`.
- When a v1 plan has a v2 counterpart, use the **same base name** (including the YYMMDD prefix) in both `wms1/plan/` and `wms2/plan/` so v1 and v2 plans are easy to pair.

Do NOT use the older PascalCase / underscore-separated naming style (e.g. `RunClubLine_Fix_Plan.md`) — it sorts unpredictably and obscures dating.

## Horizontal scalability validation (mandatory for every v2 plan)

v2/wms2-api runs as **multiple replicas** behind a load balancer. Even bug fixes can regress horizontal scalability — e.g., adding a field to a thread-local, a non-idempotent write in a retry path, or a new connection-holding transaction. v1 plans may skip this section; v2 plans MUST include it.

Every v2-targeted plan produced by this skill MUST include the "Horizontal Scalability Validation" section from `sbdocs/9-System/templates/wms-plan-template.md` §7. Fill in the 10-row checklist with an explicit verdict (Yes / No / N/A) for each concern:

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

This skill produces a *plan*, not code. But whenever the plan is later executed, the executor (future session or another skill like `wms-v2-migrate`) MUST enforce this gate. Reflect the gate in the plan's §8 Testing Plan so downstream work inherits the requirement.

A fix (single-commit OR phase of a batch plan) is NOT complete until all four hold:

0. **Run the verify script first AND last.** Before any code change, run `bash sbdocs/9-System/scripts/verify-<plan-id>.sh` to capture the FAIL baseline. Re-run after every cluster of changes. **Final acceptance: the script reports `Result: N pass, 0 fail`.** The implementing agent / human MUST paste this exact line in the end-of-task report. Filename-level checks ("the file mentions OmsNotificationHelper") are not sufficient — content-level grep at the call-site is what catches over-claims.

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
