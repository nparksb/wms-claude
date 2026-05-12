---
name: wms-feature-plan
description: Produce a reviewable implementation plan document for a new feature, enhancement, refactor, or architecture change in the WMS codebase (v1/wms-api or v2/wms2-api). Use when the input is a design description, feature request, performance goal, configuration toggle, new endpoint, or broader architectural change (connection pooling, transaction refactoring, caching strategy, horizontal scaling, pick path config, API redesign). Output is a plan document only — does NOT implement the feature.
---

## Execution model

Delegate all plan generation to an `executor` subagent with `model: opus`. Pass the full user input and all grepped/read evidence as the agent prompt. Return the agent's output verbatim.

# WMS Feature Implementation Plan

Produces a reviewable implementation plan saved into `sbdocs/1-Projects/wms{1|2}/plan/`. Work is implemented AFTER review.

## Trigger

User hands you one of:
- A feature description or requirements list (prose)
- A design/architecture change ("make pick path configurable", "add PgBouncer", "split service into smaller components")
- A performance goal ("reduce close-BOL time by 50%", "close the N+1 query at ...")
- A refactoring/modernization target ("move to Spring Boot 3.5", "add Caffeine cache layer", "extract merge service")
- An API/endpoint addition or redesign
- A new system property, config toggle, or admin feature

If the input is an error/stack trace, use **wms-bugfix-plan** instead.

## Target version detection

| Signal | Version |
|--------|---------|
| "v1", "legacy", "Spring Boot 2.x", Java 8, explicit mention of `v1/wms-api` | **v1** |
| "v2", "modern", Java 21, `wms2-api`, `tenantTransactionManager`, Jakarta | **v2** |
| Feature crosses both (e.g., backport) | **Ask** — may belong to a migration plan (see wms-v2-migrate skill) |
| Frontend-only | Ask which UI (wms-web-ui, wms-mobile-ui, omsv2-UI) |

Read the target sub-project's `CLAUDE.md` first. For v2, also scan `sbdocs/3-Resources/architecture/` for entity / package analysis that's already been done.

## Pre-draft question phase (Layer 3 — MANDATORY when triggered)

**Triggers — ask 3-5 clarifying questions BEFORE drafting if ANY of:**
- Scope is ambiguous (v1 vs v2, single PR vs phased rollout)
- A behavior change is user-visible (UX shift, error-mode shift, response-time shift)
- Concurrency semantics are not obvious from the prompt
- A performance claim has no measurable target
- A non-additive contract change is implied (API, DB schema, persisted state, frontend payload shape)
- The feature touches a flow where the user could legitimately disagree about correctness

Default question set (adapt — pick the 3-5 most relevant):
1. **Scope** — v1, v2, or both? Single PR or phased rollout?
2. **Behavior change** — what does the user see today vs after? Is the UX shift intentional?
3. **Concurrency** — what should happen when two operators race? Block, fail fast, or queue?
4. **Measurable target** — for performance work, what number defines "done well"?
5. **Backward compatibility** — is breaking any contract OK, or must everything stay additive?
6. **Coordination** — does any in-flight plan or sibling ticket cover the same code paths?

**Skip questions when:**
- The feature is mechanical (config toggle added to an existing pattern, single endpoint addition)
- The user has already answered every question category in the prompt
- The user has explicitly asked you to "just draft" / "use reasonable defaults"

Document the answers (or the explicit "use defaults" decision) in the plan's §10 Open Questions / Resolved Decisions — never silently choose for the user on these categories.

## Pre-investigation phase (specialist agents — run BEFORE drafting)

Before writing the plan body, route the input to one or more specialist agents to surface evidence the plan author cannot derive from reading the prompt alone. Each agent returns findings; fold those findings into the plan's §2 (Current Architecture), §3 (Design), and §5 (Phased Implementation Plan).

**Routing table — invoke when ANY trigger matches:**

| Agent | Invoke when | What to ask for |
|---|---|---|
| `analyst` | Scope is ambiguous, acceptance criteria are undefined, the feature description is prose without concrete constraints, behavior change where the user could reasonably disagree about correctness, or no measurable "done" criterion exists | Requirements gaps, undefined acceptance criteria, scope risks, questions to resolve before the plan is authoritative |
| `architect` | Feature spans ≥3 services/modules, touches transaction managers / tenant routing / caching architecture, introduces a new concurrency primitive, or needs second-opinion validation of a proposed design against actual code structure | File:line evidence for how the current system works, which architectural constraints apply, which design alternatives are ruled out and why |
| `tracer` | Feature work that involves a concurrency primitive (new lock, cache invalidation race, idempotency under retry), or where the motivation is a recurring incident/failure mode that needs root-cause confirmation before designing the fix | Competing hypotheses for why the current approach fails, evidence-for / evidence-against, uncertainty level, what to confirm before designing the new behavior |

**Skip pre-investigation when:**
- Feature is mechanical: new `SYSTEM_PROPERTY_*_KEY` following an existing pattern, single endpoint addition, config toggle
- The user has explicitly said "just draft" / "use reasonable defaults"

**Recommended sequences:**
- New feature with vague scope → `analyst` first; if analyst reveals architectural complexity, follow with `architect`
- Performance or reliability feature → `analyst` (acceptance criteria) + `architect` (current code path) in parallel
- Concurrency or idempotency feature → `tracer` (confirm failure mode) → `architect` (design constraints)
- Large refactor crossing ≥3 services → `architect` alone is often sufficient

**Fold findings into the plan:**
- `analyst` findings → §10 Open Questions / Resolved Decisions (pre-resolved) and §9 Alternatives Considered; acceptance criteria feed §7 Testing Strategy
- `architect` findings → §2 Current Architecture (file:line tables), §3 Design (rationale for approach), §9 Alternatives Considered (ruled-out options)
- `tracer` findings → §1 Problem Statement (confirmed failure mode), §3 Design (constraints the new design must satisfy)

## Deep analysis mode (sequential-thinking)

For non-trivial features, invoke `mcp__sequential-thinking__sequentialthinking` BEFORE drafting the plan. Use the thinking session to enumerate alternatives, identify every callsite, and validate backward compatibility — these sections get weak treatment without it.

**Trigger sequential-thinking when ANY of:**
- Cross-component change (API + service + repository + UI)
- New concurrency primitive (lock, transaction boundary, cache layer)
- Schema change or data migration
- Performance claim with a measurable target ("reduce X by Y%")
- Utility used in ≥5 callsites needs enumeration
- Phased rollout required (Phase 0 safety net, backport, etc.)

**Skip sequential-thinking when:**
- Config toggle added to an existing pattern (e.g., new `SYSTEM_PROPERTY_*_KEY` with obvious shape)
- Single-file endpoint addition
- Documentation / comment-only change

Set `thoughtsNeeded` to 6–12 for cross-component or schema changes, 3–5 for focused enhancements. Branch explicit "Alternative A vs B" thoughts — those feed directly into the plan's "Alternatives Considered" section.

## Analysis protocol

Do ALL of these before drafting. A feature plan that skips these becomes "design fiction" and wastes review cycles.

1. **Map the current architecture first.** Before proposing anything new, document what exists. Read the touched services, repositories, controllers. Cite file:line for every component named.
2. **Enumerate ALL callsites.** For anything that looks like a hot-path (sort comparator, entity lookup, transaction boundary), grep for every caller. If you change behavior of a utility, you need to know who depends on the old behavior. See `SBDEV-2096-configurable-pick-path-direction.md` — the v1 plan was revised after finding the initial version only wired 2 of 7 callsites.
3. **Inventory existing patterns first — do NOT invent new ones.**
   - Config toggles: `WmsConstants.SYSTEM_PROPERTY_*_KEY / *_DEFAULT_VALUE` + `LosSyspropService.getStringDefault` (v1) or `SystemPropertyService` (v2).
   - Multi-tenant data access: `tenant_name` / `facility_code` HTTP headers + `TenantDynamicRoutingDataSource`.
   - Transaction boundaries: always on the service method that writes, always explicit `rollbackFor`.
   - Entity lookup: `Optional.orElseThrow(() -> new BusinessException("X not found: " + id))`.
   - Pessimistic locking: `findByIdForUpdate` (repository already has it for many entities).
4. **Backward compatibility audit.** Ask for EACH change: does this break existing callers, stored data, API contracts, frontend expectations? Call out any non-additive change explicitly.
5. **Alternatives considered.** List at least 2 realistic alternatives and document WHY they were rejected (see the "Alternatives Considered (and Rejected)" pattern in `SBDEV-2102` Bug 6 and `V2_Consolidated_Picking_Fixes_Port.md`).
6. **Phasing.** If the change spans >1 PR, split into phases with explicit prereq ordering. Phase 0 should almost always be a safety net / back-compat shim (see `SBDEV-2116` Phase 0 global handler).
7. **DB verification (required when the feature touches queries, schema, or state machines).** If the feature changes SQL, adds columns/indexes, modifies entity states, or depends on existing data shape — run `mcp__wms1-wineco-dev__execute_sql` or `explain_query` to confirm the current data shape before designing the change. Record the query + result inline in §2 (Current State). Set `db_verified: true / N/A` in the plan frontmatter (`N/A` only for pure code-logic features with no DB read/write path).

## Pre-draft enumeration (Layer 1 — MANDATORY before drafting §1-§10)

Before writing a single section of the plan body, produce a single Affected-Sites table by **enumeration, not memory**. The plan body MUST visit every row — either covering it or explicitly excluding it with rationale. This catches the most common feature-plan failure mode: a config toggle / refactor / API change that lands at 2 of 7 callsites because nobody enumerated.

### Method

1. **Symbol grep — every method, class, constant, or pattern named in the prompt:**
   ```
   grep -rln "<symbol>" src/main/java
   grep -rln "<symbol>" src/test/java
   ```

2. **Callsite grep — for any utility/helper change, find every caller:**
   For changes to a sort comparator, entity lookup, transaction boundary, or system property:
   ```
   grep -rn "<methodName>(" src/main/java
   ```
   See `SBDEV-2096-configurable-pick-path-direction.md` — the v1 plan was revised after finding the initial version only wired 2 of 7 callsites.

3. **Pattern grep — every place that exhibits the same shape needing the new behavior:**
   - "Bulk UPDATE without chunking" → `grep -rn "@Modifying" src/main/java/.../repo/`
   - "Service that should defer external HTTP" → `grep -rn "httpRestService\." src/main/java/.../service/`
   - "Cache without @CacheEvict on writes" → `grep -rn "@Cacheable\|@CachePut" src/main/java/`

4. **Cross-reference grep — related plans:**
   ```
   grep -rln "<symbol>" sbdocs/1-Projects/ sbdocs/4-Archieves/
   ```

### Required output — place at the top of the plan body as §0

```markdown
## 0. Affected sites (enumeration before drafting)

| # | File:line | Construct | In-scope this plan? | Phase |
|---|-----------|-----------|---------------------|-------|
| 1 | service/Foo.java:123 | calls oldMethod()        | yes | Phase 1 |
| 2 | service/Bar.java:45  | calls oldMethod()        | yes | Phase 1 |
| 3 | service/Baz.java:78  | calls oldMethod() in admin tooling | yes — but flagged for caller-audit | Phase 2 |
| 4 | service/Qux.java:90  | calls oldMethod() — frontend-only contract | no — covered by separate UI plan | — |
```

If any in-scope row is missing from §3 Design (or §5 Phased Implementation Plan), the plan is incomplete. The §0 table also feeds §9 Acceptance — every in-scope row should map to one POSITIVE check in `verify-<plan-id>.sh`.

## Output document

Save to `sbdocs/1-Projects/wms{1|2}/plan/`. **Filename MUST follow the naming convention in the section below** — `YYMMDD-kebab-description.md` for untracked plans, `SBDEV-####-kebab-description.md` for ticketed plans. Use the template at `sbdocs/9-System/templates/wms-plan-template.md` for frontmatter. Canonical references:
- Config-toggle feature: `SBDEV-2096-configurable-pick-path-direction.md`
- Performance feature: `260405-PgBouncer_Connection_Pool_Strategy_2026-04-05.md`
- Large refactor with phases: `SBDEV-2116-unguarded-optional-get-fix-plan.md`

Required sections (numbered, in order):

1. **Problem Statement** — what's missing / inefficient / broken about the current state. Quantify where possible ("300 connections exceeds max_connections=100").
2. **Current Architecture** — the "is" diagram. Sub-sections for each component. ASCII box diagrams for topology. Tables for config defaults.
3. **Design** — the "will be" diagram. Numbered sub-sections (3.1, 3.2, …). For each: rationale, code signature, config keys, data model deltas. Prefer additive changes; if a non-additive change is unavoidable, explain migration.
4. **File Change Summary** — table (File | Change Type (Add/Modify/Delete) | Description).
5. **Phased Implementation Plan** — if the change is non-trivial. One subsection per phase: Goal, Changes, Testing, Risk level, Branch name, Estimated effort. **Every plan MUST include a Prerequisites sub-section (§5.1 of the template — DB state, feature flags, system properties, config / env changes, deploy-order dependencies, data migration, external systems, access, monitoring). Mark rows `N/A` with a one-sentence rationale only when truly nothing applies.**
6. **Backward Compatibility** — table (Aspect | Before | After | Impact). Explicit "What Does NOT Change" list.
7. **Testing Strategy** — Unit (new tests named), Integration (`mvn verify` / Testcontainers), **Manual Test Plan (mandatory; table: Scenario | Environment | Steps | Expected Result | Pass/Fail — covers UI click-path smoke, cross-system interactions like OMS/printer/Keycloak, SQL-level sanity against a real tenant DB if SQL changed; mark `N/A` with a one-sentence rationale only for changes with no user-visible path).**
8. **Rollout Plan** — branch → merge target → release tag per phase if applicable.
9. **Alternatives Considered** — table or subsections: Option | Description | Why rejected.
10. **Open Questions / Resolved Decisions** — keep unresolved questions explicit so review can close them.

## Completeness checklist (Layer 2 — gate before declaring the draft ready)

Before declaring the plan draft ready for review, walk every row. For each: mark `✓ <reference>` (with §-section / file:line) OR `no — <one-line rationale>`. **Empty rows block the plan.**

| # | Concern | Considered? |
|---|---|---|
| 1 | **All callsites enumerated** — every row in §0 covered by §3 Design or excluded with rationale |  |
| 2 | **Adjacent shapes** — other classes / methods that share the same pattern needing the new behavior |  |
| 3 | **Backward compatibility** — API contract, DB schema, persisted state, frontend payload shape, error-response shape; explicit "What Does NOT Change" list in §6 |  |
| 4 | **Concurrency** — race conditions, lock ordering, optimistic-lock retry, deadlock potential, idempotency under retry |  |
| 5 | **Multi-tenant** — cross-tenant queries, tenant context propagation, per-tenant cache / pool scoping; v2 horizontal scalability checklist filled |  |
| 6 | **Error handling** — every new throw path has a handler or an explicit contract change documented |  |
| 7 | **DB verified** — if the feature touches queries, schema, or state machines: `execute_sql` / `explain_query` run and result recorded in §2 (Current State); frontmatter has `db_verified: true` or `db_verified: N/A` with rationale |  |
| 7 | **Observability** — logs (level + message), metrics (Prometheus / Micrometer), Grafana panels, alert thresholds |  |
| 8 | **Rollout / migration** — Flyway version, data backfill, deploy-order dependencies, feature-flag toggles, sysprop rows, rollback path |  |
| 9 | **Test coverage** — unit + integration + manual smoke; named test classes and method signatures; performance measurement test if a target was claimed |  |
| 10 | **Cross-version (v1↔v2)** — applicable, deferred to a paired plan, or N/A with explicit rationale |  |
| 11 | **Alternatives considered** — at least 2 in §9, each with an explicit rejection rationale |  |

A `no — rationale` answer is acceptable when defensible. An empty row means the category was not considered, and the plan is not ready for review.

## Verification script (MANDATORY companion to every plan this skill emits)

**Why this exists.** Prose claims like "F3 done" can be over-claimed without anyone noticing. A 30-second grep-based script encodes each fix as a machine-checkable assertion so an implementing agent's "DONE" claim is provable. Real incident: an executor claimed 14 OMS-decoupling sites complete but had only done 3 — the verify script (added retroactively) exposed the gap immediately. Every plan ships with one.

**What to do, automatically as part of authoring this plan:**

1. Determine `<plan-id>` — the plan filename without `.md` (e.g. `SBDEV-2095-large-bol-close-decoupling-and-perf` for `SBDEV-2095-large-bol-close-decoupling-and-perf.md`).

2. Copy the skeleton:
   ```
   cp sbdocs/9-System/templates/verify-plan-template.sh \
      sbdocs/9-System/scripts/verify-<plan-id>.sh
   chmod +x sbdocs/9-System/scripts/verify-<plan-id>.sh
   ```

3. For EACH fix / phase / sub-feature in the plan body (3.1, 3.2, F3, S1b, etc.) add at least:
   - **One POSITIVE check** — "the new construct exists at the right call-site" (a specific regex of class+method+arg).
   - **One NEGATIVE check** when the change replaces existing code — "the old construct is gone."
   - **For phased plans:** group the checks by phase and label them so the script's output matches the rollout order.

4. Optionally append `mvn_test_passes <ClassName>` rows for each touched test class.

5. Wire each check via the `run` runner so the script outputs PASS/FAIL per item. Exit code is 0 only when every check passes.

6. Reference the script's path in the plan markdown's §9 Acceptance section.

**Reference scripts (study before authoring):**
- `sbdocs/9-System/scripts/verify-260424-oms-notification.sh` — cross-service program with 14 sites; demonstrates `file_count_at_least`, multi-line regex via `file_contains_ml`, and `mvn_test_passes` integration.
- `sbdocs/9-System/scripts/verify-SBDEV-2095.sh` — focused 4-fix plan with positive + negative assertions per fix and per-repo signature checks.

**A feature plan delivered without a corresponding verify script is not review-ready.**

## Non-negotiable WMS context

Bake these in when they apply. Reviewers will push back if you miss them.

**Configuration & feature toggles:**
- System properties live in `los_sysprop` (v1) or equivalent v2 table.
- 4-tier cascade lookup: client+workstation → client+default → system+workstation → system+default. Never reinvent.
- New keys go in `WmsConstants` as `SYSTEM_PROPERTY_*_KEY` / `*_DEFAULT_VALUE` pairs.
- Admin endpoints `/v3/systemProperty/create` and `/v3/systemProperty/updateValue` already exist — use them.

**Multi-tenancy:**
- Database-per-tenant. Any new query must route through the tenant datasource.
- Any new cache must be tenant-scoped (v2 uses Caffeine — don't build a parallel cache).
- HTTP headers `tenant_name` + `facility_code` drive the 4-char routing key in v2.

**Concurrency & transactions (v2):**
- All tenant writes: `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
- Pessimistic lock for merge/cancel/state-transition paths: `findByIdForUpdate`.
- OSIV is disabled — do not design around the assumption that an entity stays managed across method calls.
- Lock timeout property: `spring.jpa.properties.jakarta.persistence.lock.timeout=5000`.

**Error handling:**
- Services throw `BusinessException` (caught by controller or `RestExceptionHandler`).
- For user-facing errors include the identifier in the message ("Unit load not found: IN-000364"). Warehouse is a private API — info disclosure is not a concern.
- Never return raw `NoSuchElementException` or `NullPointerException` from a controller.

**Connection pools / infra:**
- Per-tenant HikariCP pools multiplied by replicas × tenants — always do the math and compare to `max_connections`.
- Tenant pool evictor runs every 5 min, evicts idle >15 min. Don't break the eviction contract.

**Performance:**
- Caffeine cache (v2) with explicit TTL; Micrometer metrics; Zipkin tracing spans. Reuse these — don't add parallel stacks.
- Batch fetch preferred over N+1 — see `phase2-n-plus-1-batch-fetch-implementation-plan.md`.

**Frontend (if touched):**
- Vue/Nuxt UIs use `vue-keycloak-js` for auth, Vuex for state, axios with retry.
- Error response shape: `{ "errors": [{"type": "...", "message": "..."}] }`. Changing this breaks both UIs.

## Plan naming convention

Same rules as `wms-bugfix-plan` §Plan naming convention. Ticketed: `SBDEV-####-kebab.md`. Untracked: `YYMMDD-kebab.md` (e.g., `260405-pgbouncer-connection-pool-strategy.md`). v1/v2 pairs share the same base name. No PascalCase or SCREAMING_SNAKE_CASE.

## Horizontal scalability validation (mandatory for every v2 plan)

v2/wms2-api runs as **multiple replicas** behind a load balancer. New features are the most common place horizontal scalability gets broken — in-memory caches, scheduled jobs, external notifications in transactions, ThreadLocal propagation on async paths. A feature plan that omits this check is not review-ready.

Every v2-targeted feature plan produced by this skill MUST include the "Horizontal Scalability Validation" section from `sbdocs/9-System/templates/wms-plan-template.md` §7. Fill in the 10-row checklist with an explicit verdict (Yes / No / N/A) for each concern:

Same 10 concerns as `wms-bugfix-plan` §Horizontal Scalability Validation — In-JVM state, connection pool math, scheduled jobs, long transactions, request affinity, retry/idempotency, tenant context, distributed lock correctness, cache invalidation, external notifications.

For any **Yes** row: provide file:line or test evidence in the "Evidence" sub-table. A new feature that adds caching, a scheduled job, an async pipeline, a WebSocket, or an external integration almost always has two or more Yes rows — treat the default as "this probably affects scalability, prove otherwise."

A missing or empty row blocks plan sign-off.

## v2-only constraint checklist (skip entirely for v1 plans)

Before drafting any v2 plan section, verify each constraint. These don't overlap with the horizontal scalability checklist — they're code-level architectural invariants that differ from v1.

| # | Constraint | What to check | Verdict |
|---|---|---|---|
| 1 | **OSIV disabled** | `spring.jpa.open-in-view=false` in v2. Any repository call outside a `@Transactional` boundary opens a new session with no L1 cache. Lazy-loaded associations outside a transaction throw `LazyInitializationException`. All new service methods that load associations must be transactional or use DTO projections. | Yes / No / N/A |
| 2 | **Transaction manager** | Tenant-scoped writes must use `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. Using the default `transactionManager` silently routes to the wrong datasource. | Yes / No / N/A |
| 3 | **`@Transactional(readOnly=true)`** | All read-only service methods must declare `readOnly=true`. This enables Hibernate read optimization and prevents accidental writes in read paths. | Yes / No / N/A |
| 4 | **Caffeine cache invalidation** | Any write to an entity whose type is cached (`@Cacheable`) must pair a `@CacheEvict` or `@CachePut`. Check `wms2-caching-strategy.md` for the full list of cached types. New cached types require explicit TTL and tenant-scoped cache key. | Yes / No / N/A |
| 5 | **Micrometer metrics** | New flows on high-frequency paths (picking, receiving, replenishment, club runs) must emit a counter or timer via `MeterRegistry`. Reuse existing metric names before inventing new ones; check `wms2-scheduled-jobs-catalog.md` for existing instrumentation patterns. | Yes / No / N/A |
| 6 | **Jakarta namespace** | v2 uses `jakarta.*` (Spring Boot 3.x / Jakarta EE 10). Any code copied or ported from v1 that imports `javax.persistence`, `javax.validation`, or `javax.transaction` will fail at compile or runtime. Find-replace before implementation. | Yes / No / N/A |
| 7 | **H2-compatible test SQL** | v2 unit tests (non-Testcontainers) run against H2. Native PostgreSQL syntax (`::text`, `ILIKE`, `ON CONFLICT`, `gen_random_uuid()`, array operators) must be replaced or the test promoted to a Testcontainers integration test. | Yes / No / N/A |
| 8 | **`BaseControllerTest` for new endpoints** | Every new or modified controller endpoint requires a test extending `BaseControllerTest`. Verify it wires the correct `MockMvc` setup, tenant context, and Keycloak role fixtures. | Yes / No / N/A |

For any **Yes** row: cite the specific file:line or document in the plan body where the constraint is addressed. A v2 plan with unchecked rows is not review-ready.

## Post-implementation gate (mandatory when executing the plan)

Same 4-point gate as `wms-bugfix-plan` §Post-implementation gate. In summary: run the verify script first (capture FAIL baseline) and last (must show `Result: N pass, 0 fail`); tests exist for every change (unit + Testcontainers for repo/JPQL + `BaseControllerTest` for controllers); all pass via `mvn verify`; plan doc updated with commit SHAs, test results, and verify-script output before sign-off. Never announce a phase complete with any of these unchecked.

## Escalate, don't guess

- Cross-version design → defer to wms-v2-migrate or ask which version is authoritative.
- Breaking API change → ask before drafting; the answer shapes the plan.
- Performance claim ("will reduce X by Y%") → must have a measurement method in the plan, or drop the number.
