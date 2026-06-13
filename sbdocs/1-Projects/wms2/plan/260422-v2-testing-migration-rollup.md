---
title: "WMS v2 Testing Migration — Coordination Rollup"
ticket: ""
ticket_url: ""
type: plan
priority: medium
status: draft
project: [wms2-api]
version: v2
requester: "nam.park@siteboss.net"
created: 2026-04-22
updated: 2026-04-22
related:
  - ./260420-v2-integration-tests-h2-migration-report.md
  - ./260420-v2-port-plpgsql-functions-to-java.md
  - ./260421-v2-replace-pg-advisory-lock.md
tags:
  - plan
  - draft
  - wms2
  - testing
  - rollup
  - coordination
---

# WMS v2 Testing Migration — Coordination Rollup

**Status: DRAFT — pending review.** This is a **coordination layer** for three separately-reviewable plans, not a re-explanation of them. Each sub-plan owns its details, sign-off, and implementation; this doc sequences them, names the critical path, and tracks overall status.

---

## 1. What this rollup covers

Three sibling plans, all targeting `v2/wms2-api`:

| # | Plan | What it does | Owning file |
|---|---|---|---|
| **P1** | H2 migration | Swap Testcontainers-PostgreSQL for H2 in-memory where portable; retain a small `postgres-integration` profile for PG-specific tests; fix landlord datasource wiring; rebuild the 17 currently-`@Disabled` tests | [260420-v2-integration-tests-h2-migration-report.md](./260420-v2-integration-tests-h2-migration-report.md) |
| **P2** | PL/pgSQL → Java | Move the 3 PL/pgSQL functions (`stock_history`, `transaction_detail`, `transaction_summary`) into Java services with staged 4-phase flag-gated rollout; new Flyway `V2.1.08` drops functions in the final phase | [260420-v2-port-plpgsql-functions-to-java.md](./260420-v2-port-plpgsql-functions-to-java.md) |
| **P3** | Advisory lock refactor | Extract `JobLockService` interface; production keeps `pg_try_advisory_lock`; test profile uses an in-memory impl; adds startup safety guard to prevent misconfigured prod | [260421-v2-replace-pg-advisory-lock.md](./260421-v2-replace-pg-advisory-lock.md) |

Together these deliver: **`mvn verify` runs on H2 without Docker for the bulk of the suite**, with a small opt-in Testcontainers-PG lane for the few tests that must stay on PostgreSQL.

---

## 2. Dependency graph

```
                    ┌─► H2 §2: migrate 7 portable repo tests
                    │    (2–3 days)               │
                    │                             ├─► H2 §3: rebuild mobile / REST tests ──┐
                    │                             │    (3–5 days)                          │
H2 §1: landlord ────┤                             │                                        │
datasource fix      │                             │                                        ├─► H2 §4: scenario scaffold (opt.)
(1–2 days, eng-     │                             │                                        │    (3–5 days)                 │
agnostic)           │                             │                                        │                               │
                    │                             │                                        │                               │
                    └─► P2 Phase A: add Java ─────┘ P2 Phase B: staging bake (~2wk cal.) ──►│ P2 Phase C: prod flip ────────┤
                        report services, flag                                               │    (1 release cycle)          │
                        off (3–4 days)                                                      │                               │
                                                                                            │                               │
P3: advisory lock ──────────────────────────────────────────────────────────────────────────┘                               │
refactor (1–2 days,                                                                                                         │
parallel with H2 §2)                                                                                                        ▼
                                                                                                                       H2 §5: CI split
                                                                                                                       (0.5 day)
                                                                                                                            │
                                                                                                                            ▼
                                                                                                         P2 Phase D: drop functions
                                                                                                         (V2.1.08, optional cleanup)
```

Key dependencies stated plainly:

- **H2 §1** gates everything. It unblocks 9 `@Disabled` tests regardless of engine. No other step is efficient without it.
- **P3** is independent — start any time. Only H2 §3 (mobile tests that trigger jobs) and H2 §4 (scenario tests) hard-require it.
- **P2 Phase A** enables reports on H2 immediately (Java path sidesteps the PL/pgSQL requirement). Phases B/C/D are calendar-bound prod rollout, not blockers for H2 work.
- **P2 Phase D** is pure cleanup. Ship-blocking for nothing. Can be 1–2 quarters out.

---

## 3. Recommended sequence

| Wk | Primary track (H2) | Parallel track 1 | Parallel track 2 (calendar) |
|---|---|---|---|
| 1 | **H2 §1 — landlord DS fix** | spike: verify Phase 1 is a 1-2 day job, not a week | — |
| 1–2 | **H2 §2 — migrate 7 portable repo tests** | **P3 — advisory lock refactor** (1–2 days) | — |
| 2–3 | **H2 §3 — rebuild mobile / REST tests** | — | **P2 Phase A — add Java report services** (3–4 days), flag default `plpgsql` |
| 3–4 | **H2 §4 — scenario scaffold (optional)** | — | **P2 Phase B — flip flag in staging**, 2-wk bake begins |
| 5 | **H2 §5 — CI split** | — | P2 Phase B bake completes |
| 6+ | — | — | **P2 Phase C — prod flip to Java default**, 1 release cycle |
| Later | — | — | **P2 Phase D — drop functions**, optional cleanup after Phase C stable |

Critical path total: **~5 weeks calendar, ~10 eng-days**, dominated by staging bake time.

---

## 4. Critical path — the narrowest viable delivery

If leadership wants the smallest slice that unlocks the stated goal ("CI runs on H2 without Docker"), ship only these:

1. **H2 §1** — landlord DS fix
2. **H2 §2** — migrate 7 portable repo tests
3. **P3** — advisory lock refactor
4. **P2 Phase A** — add Java report services (flag stays `plpgsql` in prod)
5. **H2 §5** — CI split

**~8–10 eng-days.** Skips mobile/REST rebuilds (H2 §3), scenario tests (H2 §4), and the full P2 rollout (Phase B-D). Delivers a working H2 default lane on CI without touching prod report behavior.

---

## 5. Parallelization constraints

What can run in parallel:

- **P3 ‖ H2 §2** — different engineers, different files, zero overlap.
- **P2 Phase A ‖ H2 §2/§3** — P2 touches `controller/rest/TransactionReportRestController` + three new services; H2 work touches base test classes + repo tests. Minor overlap risk in test base classes if both touch `BaseIntegrationTest`; coordinate on that file.
- **H2 §4 (scenario tests) ‖ P2 Phase B/C** — scenario tests needing reports can use either P2 Phase A's Java path (immediate) or wait for Phase C (default flipped). Either way, no blocker.

What must stay serial:

- **H2 §1 before anything** (test infra foundation).
- **H2 §2 before §3** (§3 builds on §2's `TestDataFactory` pattern).
- **P2 Phase A before B before C before D** (rollout invariant).
- **H2 §3 before §4** (§4 consumes §3's assertion helpers).

---

## 6. Flyway impact (cross-plan)

Only P2 touches migrations, and only at Phase D:

| Plan | New migration | Touches existing migrations? | Test profile impact |
|---|---|---|---|
| P1 (H2 migration) | None | No | Already has `spring.flyway.enabled=false` for H2; Hibernate `create-drop` from entities |
| P2 (PL/pgSQL → Java) | **`V2.1.08__drop_report_functions.sql`** at Phase D only | No | Testcontainers-PG boots add one create→drop cycle per fresh boot. Harmless. |
| P3 (Advisory lock) | None | No | Interface change only |

No concurrent migration-number collisions. `V2.1.08` is reserved by P2 Phase D.

---

## 7. Risks this rollup surfaces (beyond per-plan risks)

| Risk | Impact | Mitigation |
|---|---|---|
| **Landlord DS fix harder than expected** | Shifts entire critical path right by 1–2 weeks | 2-hour spike in week 0 before committing the plan. Surface result to team before scheduling the rest. |
| **P2 Phase A and H2 §3 both touch `BaseIntegrationTest`** | Merge conflicts | Assign both streams to the same engineer, or coordinate via a shared feature branch. |
| **H2 §4 depends on P3 AND P2 Phase A** | Scenario tests blocked if either slips | Scenario tests are optional — skip if blocked. Deliver §1–§3 + §5 without them. |
| **P2 Phase B staging bake reveals parity divergence** | Blocks Phase C indefinitely | Parity tests in Phase A catch this — scope is correctness, not performance. |
| **P2 Phase D dropped earlier than intended** | Report outage if Phase C rollback needed post-drop | Phase D explicitly gated on "1 release cycle after Phase C is stable in prod." Runbook entry to re-create functions via `V2.1.09` if needed. |

---

## 8. Status tracking

Update each sub-plan's frontmatter `status:` as phases complete. This rollup tracks only gate-level completion:

| Gate | Status | Date | Notes |
|---|---|---|---|
| H2 §1 landlord DS spike | ◯ pending | — | 2-hr investigation before plan kickoff |
| H2 §1 landlord DS fix | ◯ pending | — | |
| H2 §2 portable repo migration | ◯ pending | — | |
| P3 advisory lock refactor | ◯ pending | — | |
| P2 Phase A Java report services | ◯ pending | — | |
| H2 §3 mobile/REST rebuild | ◯ pending | — | |
| P2 Phase B staging bake | ◯ pending | — | calendar-bound |
| H2 §4 scenario scaffold | ◯ pending — **optional** | — | |
| P2 Phase C prod flip | ◯ pending | — | |
| H2 §5 CI split | ◯ pending | — | |
| P2 Phase D drop functions | ◯ pending — **optional cleanup** | — | gate on Phase C stability |

Legend: ◯ pending • ◐ in progress • ● done • ✗ blocked

---

## 9. Decisions needed before kickoff

Consolidating the open questions across the three plans — these are the decisions that affect more than one sub-plan:

1. **Run the landlord DS spike first?** Recommended. 2 hours, may invalidate the rest of the schedule. *(Rollup recommendation: yes.)*
2. **Commit to Phase D or accept "Phase C is our forever state"?** Phase D is cleanup; Phase C (Java default, functions still present but unused) is sufficient for the H2 goal. *(Rollup recommendation: commit to Phase C; revisit Phase D in the next quarter.)*
3. **Include scenario tests (H2 §4) in this rollup, or split into a follow-on?** Scenario tests address the real coverage gap (per smoke-test checklist) but balloon the critical path by 3–5 days. *(Rollup recommendation: split. Deliver §1-3+§5 first; scenario tests in a follow-on plan.)*
4. **Which engineer owns which track?** Specifically: does P3 run parallel (needs a second engineer) or serial (adds 1–2 days to critical path)? *(Rollup recommendation: parallel — P3 is small and isolated.)*
5. **Will one release cycle in prod be enough bake time for P2 Phase C before Phase D?** Team / business decision. Reports are client-facing; conservative answer is one full quarter.

---

## 10. How to use this rollup

- **When opening a PR for any sub-plan work:** reference the rollup's gate in the PR description (e.g. "gate: H2 §2").
- **When a sub-plan's `status:` flips:** update the table in §8.
- **When a dependency assumption breaks:** update §3 / §7 and raise in standup before continuing downstream work.
- **When archiving a sub-plan:** leave the rollup in place until all three sub-plans are done or cancelled; then archive this rollup too.
