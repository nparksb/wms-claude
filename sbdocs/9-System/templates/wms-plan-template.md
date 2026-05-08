---
title: "{{title}}"
ticket: ""
ticket_url: ""
type: ""
priority: ""
status: ""
project: []
version: ""
requester: ""
created: ""
updated: ""
related: []
tags:
  - plan
---

# {{title}}

**Ticket:** [{{ticket}}]({{ticket_url}})
**Project:** {{project}} | **Version:** {{version}} | **Type:** {{type}}
**Priority:** {{priority}}
**Status:** {{status}}
**Date:** {{created}}

---

## 1. Problem Statement

<!-- What is broken or missing? Include user-visible symptoms, error messages, and reproduction steps if applicable. -->

---

## 2. Root Cause Analysis

<!-- Why does the problem occur? Trace from symptom to code. Include file paths, line numbers, and code snippets. For features, replace this section with "Current Architecture" describing the existing state. -->

### Affected Locations

<!-- Table of files/lines that need changes -->

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | | | |

---

## 3. Design / Proposed Fix

<!-- What will change and why. For bug fixes: describe each fix. For features: describe the design. For performance: describe optimizations with estimated impact. -->

### 3.1 {{Fix or Feature Name}}

**Problem:**
<!-- What specifically is wrong at this location -->

**Solution:**
<!-- What the change looks like -->

**Files changed:** <!-- list of files -->

---

## 4. V1/V2 Applicability

<!-- Remove this section if the plan targets only one version. Use when porting fixes between v1 and v2. -->

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| | | | |

### What Needs Porting

1. <!-- item -->

### What Does NOT Need Porting

- <!-- item and reason -->

---

## 5. Prerequisites & Implementation Plan

<!--
  Section 5 has two sub-sections:
    5.1 Prerequisites — what must be TRUE or IN PLACE before Step 1 can run.
                        Reviewers should be able to read this and know exactly
                        what to prepare on staging / prod.
    5.2 Implementation Checklist — ordered, atomic, reviewable steps.
-->

### 5.1 Prerequisites

List everything that must be prepared before implementation starts. Every row is required — mark `N/A` with a one-sentence rationale if truly none apply (e.g., pure code-logic refactor with no runtime dependencies).

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** (schema version, required rows, Flyway baseline) | e.g. Flyway at V1.1.05; seed row `los_sysprop.syskey='X'` exists | | |
| 2 | **Feature flags / system properties** (toggles that must be set before rollout) | e.g. `SYSTEM_PROPERTY_FOO_KEY=true` in `los_sysprop` | | |
| 3 | **Config / env changes** (application.properties, jasypt, keycloak client, env var) | e.g. set `jasypt.encryptor.password`; add `JAVA_OPTS="-Xmx3072m"` | | |
| 4 | **Deploy-order dependencies** (other services / apps that must ship first or together) | e.g. oms-laravel-api must deploy v2.5.x before this wms-api change | | |
| 5 | **Data migration** (backfill script, one-off SQL, manual DBA task) | e.g. run `tools/backfill_qtyrequired.sql` once per tenant | | |
| 6 | **External systems** (OMS webhook URL, printer config, Keycloak realm) | e.g. WMS_WEBSERVICE_ORDER_BATCH_PICKED_URL reachable | | |
| 7 | **Access / permissions** (new role, new endpoint authority, Keycloak client scope) | e.g. add `WMS_ADMIN_CLUB_RUN` to app admin group | | |
| 8 | **Monitoring / alerts** (Grafana panel, alert rule, log-based metric) | e.g. add panel for `stockunit_optimistic_lock_failure_total` | | |

### 5.2 Implementation Checklist

- [ ] <!-- task 1 -->
- [ ] <!-- task 2 -->
- [ ] Unit tests added/updated
- [ ] Integration tests (if applicable)
- [ ] Code review completed

---

## 6. Test Plan

<!--
  MANDATORY before phase sign-off. Every code change in this plan must have:
    - At least one unit test asserting the new behavior
    - Testcontainers integration test for any native-SQL / JPQL change
    - Controller test (BaseControllerTest) for any endpoint change
  Run `mvn test -Dtest=<ClassName>` per touched class; `mvn verify` before merge.
  On any failure the phase is NOT complete.
  If coverage is truly impossible (config-only / auto-generated), record the reason here.
-->

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| | | |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| | | |

### Manual test plan

<!--
  Required even when unit + integration coverage looks complete. Click-path or SQL-path
  smoke checks catch UI regressions, frontend state bugs, OMS integration drift, and
  cross-tenant environment issues that no isolated test exercises. Mark "N/A" with a
  one-sentence rationale only for changes with no user-visible path (pure internal
  helper refactor, log-only change).
-->

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| <!-- UI smoke: happy path through the changed flow --> | staging | 1. … 2. … | | |
| <!-- UI smoke: error / edge case --> | staging | | | |
| <!-- Cross-system: OMS / printer / keycloak interaction, if touched --> | staging | | | |
| <!-- SQL-level sanity against a real tenant DB, if SQL / migration changed --> | staging DB | psql: `SELECT …` | non-empty, no grammar error | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=...` | | |
| `mvn verify` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| | |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

<!--
  v2/wms2-api is deployed as MULTIPLE REPLICAS behind a load balancer. Every plan
  touching v2 must explicitly answer these questions. An item marked "N/A" MUST have
  a one-sentence rationale. A scalability risk surfaced here blocks sign-off until
  addressed (either implementation or accepted-with-mitigation).
-->

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica (Caffeine cache, `ConcurrentHashMap`, static field, `ThreadLocal`)? | Yes / No / N/A | If yes: move to Redis / DB, or justify why per-replica is OK |
| 2 | **Connection pool math** | Change per-request DB connection usage (holding connection longer, new pools, new tenants)? | Yes / No / N/A | Recompute `replicas × tenants × maxPoolSize` vs Postgres `max_connections`; consult PgBouncer plan if impacted |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | Yes / No / N/A | If yes: use ShedLock / distributed lock, OR document single-instance-only requirement and configure the deployment accordingly |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | Yes / No / N/A | Measure expected duration; compare to HikariCP `connectionTimeout`; split or defer external I/O until after commit |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica (in-memory session, WebSocket, SSE)? | Yes / No / N/A | Make stateless, DB-backed session, or require sticky sessions in ingress config |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op and another replica retries? | Yes / No / N/A | Confirm idempotent write (upsert on natural key, versioned entity, conditional update); add retry-safe guard |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` / `@RequestScope` across async boundaries (`@Async`, `CompletableFuture`, job threads)? | Yes / No / N/A | Explicitly re-set and clear tenant context in the async lane; scheduled jobs MUST set tenant context manually |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | Yes / No / N/A | Verify `findByIdForUpdate` is inside `@Transactional(tenantTransactionManager)`; optimistic lock path has retry expansion; lock timeout configured |
| 9 | **Cache invalidation** | Write to an entity that is cached (Caffeine local or Redis shared)? | Yes / No / N/A | Verify `@CacheEvict` / `@CachePut` covers all write paths; if shared cache, confirm eviction propagates across replicas |
| 10 | **External notifications (OMS, printer, etc.)** | Send an HTTP / message to an external system inside a transaction? | Yes / No / N/A | Defer to after-commit (`TransactionSynchronization.afterCommit`); otherwise another replica's retry produces duplicate notifications |

### Evidence (fill in for any "Yes" row)

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| | | |

---

## 8. Notes

<!-- Anything else: related plans, deployment considerations, follow-up work, version history of this document. -->

---

## 9. Acceptance & Implementation

This section closes two gaps that bit historical plans:
- **9.1 Acceptance script** — a machine-checkable contract so an agent's "DONE" claim cannot be accepted on prose alone.
- **9.2 Recommended OMC composition** — an explicit orchestration recipe so the implementer (human or autopilot) doesn't single-shot a multi-cluster plan with one `executor` and over-claim. Match the orchestration shape to the plan's complexity.

### 9.1 Acceptance script (machine-checkable)

Every plan ships an executable acceptance script at `sbdocs/9-System/scripts/verify-<plan-id>.sh`. The script encodes each rollout item as a grep / test assertion so the implementer's "DONE" claim is provable, not prose.

**Authoring rules:**
- Copy `sbdocs/9-System/templates/verify-plan-template.sh` as a starting point.
- Add one `check_<rollout-id>_<aspect>` function per rollout item — at least a POSITIVE check ("new construct present at right call-site"), and a NEGATIVE check where applicable ("old construct is gone").
- Wire each check into the runner via `run <id> "<description>" <fn>`.
- Optional but encouraged: invoke a targeted `mvn test -Dtest=<TestClass>` for any item whose correctness depends on behavior, not just code shape.

**Workflow contract:**
1. The plan author writes the verify script alongside the plan, before implementation starts.
2. The implementing agent (human or executor) runs it after every change pass and pastes the output into its end-of-task report.
3. The orchestrator re-runs it. **A "DONE" claim with FAIL lines is not accepted.**
4. CI (or a pre-commit hook, if wired) runs it on every push.

**Path:** `sbdocs/9-System/scripts/verify-<plan-id>.sh` (relative to vault root).

### 9.2 Recommended OMC composition (for implementation)

OMC's value compounds when you match the orchestration shape to the plan's complexity. A single `executor` for a 14-site plan is the failure mode that bit `260424-oms-notification-rollback-risk-remediation.md` on first attempt — over-claim across too many sites with no built-in gate. Conversely, spinning up `team` + `critic` + `verifier` for a typo fix is wasted compute.

This sub-section tells the implementer (human or autopilot) **which OMC composition to use**. Pick from the decision tree, then fill in the per-plan table.

#### Decision tree

```
Plan size / complexity?
│
├─ Trivial: 1-3 fixes, mechanical, single file area, no contract change
│   • /oh-my-claudecode:executor   (one agent)
│   • bash sbdocs/9-System/scripts/verify-<plan-id>.sh
│   • /oh-my-claudecode:verifier   (final pass)
│
├─ Standard: 4-10 fixes, single subsystem
│   • /oh-my-claudecode:critic     (review the plan BEFORE coding starts)
│   • /oh-my-claudecode:executor
│   • bash sbdocs/9-System/scripts/verify-<plan-id>.sh
│   • /oh-my-claudecode:verifier
│
├─ Large: 10+ fixes, OR cross-subsystem, OR high-blast-radius
│   • /oh-my-claudecode:analyst → /oh-my-claudecode:planner   (pre-draft if not already done)
│   • /oh-my-claudecode:critic   (find gaps in the plan before coding)
│   • /oh-my-claudecode:ralph    (loops: implement cluster → run verify → fix FAIL → repeat
│                                 until exit condition `0 fail` from verify-<plan-id>.sh)
│       OR /oh-my-claudecode:team   (parallel by cluster, for time-pressured rollouts)
│   • /oh-my-claudecode:code-reviewer   (final pass before commit)
│   • /oh-my-claudecode:git-master       (atomic commits with trailers)
│
└─ Pattern decision: introducing a NEW pattern that may conflict with existing ones
    • /oh-my-claudecode:ccg   (Claude + Codex + Gemini consensus) BEFORE drafting
    • then route to the matching row above based on size
```

#### Required — fill in for THIS plan

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Trivial / Standard / Large / Pattern-decision | e.g. "8 fixes across one service — Standard" |
| **Pre-draft step** | none / deep-interview / analyst+planner / ccg | when applicable |
| **Plan-review step** | none / critic | should be `critic` for Standard+ |
| **Implementation shape** | executor / ralph / team / autopilot | pick one; `ralph` is the default for Large |
| **Verification step** | verify-script + verifier (mandatory for ALL) | always |
| **Code-review step** | none / code-reviewer | should be `code-reviewer` for Large |
| **Commit step** | git directly / git-master | use `git-master` for plans with multiple logical commits |

The implementer MAY override this recommendation (e.g., scale down `ralph` to `executor` if the verify script is comprehensive enough) but the override and rationale go into the implementation report.

#### Why this matters (the two failure modes)

- **Over-claim** ("agent said DONE, code says NOT DONE") is **structurally prevented** by `ralph` + verify-script-as-exit. The loop can't terminate while any check fails. The agent's prose is irrelevant; the script's exit code is the contract. Plan-A's 14-site over-claim incident from 2026-04-25 is the canonical example.
- **Under-coverage** ("plan missed S2/S4/S11") is **structurally prevented** by `critic` on the plan before coding starts. Catches gaps that the §0 enumeration and the Layer-2 completeness checklist missed.

#### Persistence — record lessons AFTER rollout

After this plan ships, if a reusable lesson surfaced:
- `project_memory_add_directive` — encode the lesson as a permanent directive (e.g. *"Every BOL-close-related plan must check the bolToClose guard"*). Future sessions inherit it.
- `notepad_write_priority` — short-term context for areas with active churn (e.g. *"Plan A renamed S3 helper site name from `closeBol` to `closeBOL`"*).
- `state_write` — for multi-week ports / migrations, track per-site progress across sessions.

#### Cross-plan references (study these for shape)

- Standard-shape example: `SBDEV-2095-large-bol-close-decoupling-and-perf.md` — 4 fixes (F3-F6), single subsystem, single `executor`, `verify-SBDEV-2095.sh` as exit gate.
- Large-shape example: `260424-oms-notification-rollback-risk-remediation.md` — 14 sites, cross-service, would have benefited from `ralph` + `critic` instead of single `executor`. §11 documents the over-claim recovery.
