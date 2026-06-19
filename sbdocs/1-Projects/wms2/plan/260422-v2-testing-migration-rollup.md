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
updated: 2026-06-17
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

> **Re-grounding note (2026-06-17):** Re-verified against HEAD. The April draft's critical path was anchored on a "landlord datasource fix" gate that **has already shipped** — the H2 test infrastructure (`application-integration.properties`, `BaseIntegrationTest`/`BasePostgresIntegrationTest`, `TestDataFactory`, `TestDatabaseConfig`) all exist and the H2 lane runs today. The Flyway numbers the draft reserved (`V2.1.08`/`V2.1.09`) are **already taken**; head is `V2.1.14`. The advisory-lock surface grew from 5 jobs to **8**, and at least the outbox path now runs `@Scheduled` on all replicas (lock is load-bearing there, not merely defensive). The three sub-plans were re-grounded on this date; this rollup is regenerated to match them. Every gate, estimate, and dependency below reflects the live tree.

---

## 1. What this rollup covers

Three sibling plans, all targeting `v2/wms2-api`:

| # | Plan | What it does | Owning file |
|---|---|---|---|
| **P1** | H2 migration | The H2 default lane already exists; this plan **audits the current 18 `@Disabled` markers**, rebuilds the ~8 "legacy multi-tenant infra" tests onto the existing `BaseIntegrationTest` + `TestDataFactory`, keeps the enumerated PG-only-native-SQL tests on `BasePostgresIntegrationTest`, and makes the PG opt-in lane real (with a named owner) | [260420-v2-integration-tests-h2-migration-report.md](./260420-v2-integration-tests-h2-migration-report.md) |
| **P2** | PL/pgSQL → Java | Move the 3 report functions (`stock_history`, `transaction_detail`, `transaction_summary`) into Java services on the **`tenantDynamicRoutingDataSource`** bean, with a staged 4-phase flag-gated rollout; new Flyway `V2.1.17` (re-derive at execution) drops the functions in the final phase. **Baselines on the post-UTC `timestamptz` bodies** (`V1.2.05`, via PR #47) — see P2's cross-branch note | [260420-v2-port-plpgsql-functions-to-java.md](./260420-v2-port-plpgsql-functions-to-java.md) |
| **P3** | Advisory lock refactor | Extract `JobLockService` interface from the current raw-JDBC `AdvisoryLockService` (8 jobs / 8 lock IDs); production keeps `pg_try_advisory_lock` with ThreadLocal connection-pinning; test profile uses an in-memory impl; adds an allowlist startup guard to prevent misconfigured prod | [260421-v2-replace-pg-advisory-lock.md](./260421-v2-replace-pg-advisory-lock.md) |

Together these deliver: **`mvn verify` runs on H2 without Docker for the bulk of the suite** (target ≥90% of integration classes), with a small opt-in Testcontainers-PG lane for the few tests that must stay on PostgreSQL.

---

## 2. Dependency graph

```
P1 §1: audit the 18 @Disabled markers + run the no-Docker
acceptance test (0.5–1 day)  ──►  P1 §2: rebuild ~8 Category-A
   │   (infra already exists)       legacy-multi-tenant tests on the
   │                                existing H2 base (3–5 days) ──┐
   │                                                              │
   │                                                              ├─► P1 §4: make the PG
   │                                P1 §3: Category-C fixtures     │   opt-in lane real
   │                                + cleanup (1–2 days) ──────────┤   (1–2 days, gated on
   │                                                              │   named PG-lane owner)
   │                                                              │            │
P3: advisory-lock refactor ───────────────────────────────────────┤            ├─► P1 §5: scenario
(1–2 days, parallel — but the rename touches 8 job files          │            │   scaffold (opt.,
+ the contract test; see §5)                                      │            │   3–5 days; needs
                                                                  │            │   P3 + P2 Phase A)
P2 Phase A: add Java report services on tenantDynamic-            │            │
RoutingDataSource, flag off (3–4 days) ──────────────────────────┘            │
   │   (this is the real H2 gate for report tests, incl.                       │
   │    ClientRepositoryIntegrationTest:285)                                   │
   │                                                                           ▼
   └─► P2 Phase B: staging bake (~2wk cal.) ─► P2 Phase C: prod flip ─► P2 Phase D: drop
       (flag=java in staging)                  (1 release cycle)        functions (V2.1.17,
                                                                        re-derive; optional cleanup)
```

Key dependencies stated plainly:

- **The H2 test infrastructure already exists** — there is no "landlord DS fix gates everything" step anymore. P1 §1 is a short audit, not a build. The April draft's week-0 spike is obsolete.
- **P2 Phase A is the real H2 gate for report tests.** The one remaining report-dependent disabled test (`ClientRepositoryIntegrationTest:285`, the `transaction_detail` smoke test) is blocked by the PL/pgSQL function, not by infra. Once P2 Phase A lands the Java report path, that test (and any future report test) can run on H2.
- **P3 is independent** — start any time. Only P1 §5 (scenario tests that drive scheduled jobs) hard-requires it. **Caveat:** P3's rename of `AdvisoryLockService` touches **8** job files plus a reflection-based contract test — see §5.
- **P2 Phases B/C/D** are calendar-bound prod rollout, not blockers for H2 work. **Phase D is pure cleanup** and ship-blocking for nothing; it can be 1–2 quarters out.

---

## 3. Recommended sequence

| Wk | Primary track (P1) | Parallel track 1 | Parallel track 2 (calendar) |
|---|---|---|---|
| 1 | **P1 §1 — audit the 18 `@Disabled` markers; run the no-Docker acceptance test** | **P3 — advisory-lock refactor** (1–2 days; coordinate the rename — §5) | — |
| 1–2 | **P1 §2 — rebuild ~8 Category-A legacy tests on the existing H2 base** | — | **P2 Phase A — add Java report services** on `tenantDynamicRoutingDataSource` (3–4 days), flag default `plpgsql` |
| 2–3 | **P1 §3 — Category-C fixtures + cleanup** | — | **P2 Phase B — flip flag in staging**, 2-wk bake begins |
| 3 | **P1 §4 — make the PG opt-in lane real** (gated on named owner) | — | P2 Phase B bake continues |
| 4 | **P1 §5 — scenario scaffold (optional)** | — | P2 Phase B bake completes |
| 5+ | — | — | **P2 Phase C — prod flip to Java default**, 1 release cycle |
| Later | — | — | **P2 Phase D — drop functions** (`V2.1.17`, re-derive), optional cleanup after Phase C stable |

Critical path total: **~6 weeks calendar** (dominated by the P2 staging bake), **~6–11 eng-days** for P1 Phases 1–4 + ~1–2 for P3, with P2 Phase A's ~3–4 eng-days running on the calendar track.

---

## 4. Critical path — the narrowest viable delivery

If leadership wants the smallest slice that unlocks the stated goal ("CI runs on H2 without Docker for the bulk of the suite"), ship only these:

1. **P1 §1** — audit the disabled set + run the no-Docker acceptance test (`mvn verify` with the Docker daemon stopped → green). This *proves* the existing infra delivers the goal for the already-running subset.
2. **P1 §2** — rebuild the ~8 Category-A legacy-multi-tenant tests on the existing H2 base.
3. **P3** — advisory-lock refactor (unblocks any test that reaches a scheduled-job entry point on H2).
4. **P2 Phase A** — add Java report services (flag stays `plpgsql` in prod), which unblocks the report-dependent test on H2.
5. **P1 §4** — make the PG opt-in lane real, with a named owner, so the enumerated PG-only tests have a home.

**~7–10 eng-days.** Skips the optional scenario layer (P1 §5) and the full P2 prod rollout (Phases B–D). Delivers a working H2 default lane on CI without touching prod report behavior. The numeric success bar: **≥90% of the ~42 integration classes run on the H2 default lane**; only the enumerated PG-only set (P1 §4.3) requires the PG lane.

---

## 5. Parallelization constraints

What can run in parallel:

- **P3 ‖ P1 §2** — different engineers, mostly different files. **Coordination risk (not zero):** P3 renames `AdvisoryLockService` → `PostgresAdvisoryJobLockService` and moves `JobLockId` into the new `JobLockService` interface. That touches **8 scheduled-job classes (16 call sites)** *and* the reflection-based `AdvisoryLockServiceJobLockIdContractTest`. If P1 §2 rebuilds any test that references the lock, sequence the P3 rename first or rebase. (April draft said "5 files × 10 sites" — it is 8 × 16.)
- **P2 Phase A ‖ P1 §2/§3** — P2 touches `controller/rest/TransactionReportRestController` + three new `service/report/*` services; P1 work touches base test classes + repo/service tests. Minor overlap risk only if both touch `BaseIntegrationTest` (now a stable shared base used by several landed SBDEV tickets) — coordinate on that file.
- **P1 §5 (scenario tests) ‖ P2 Phase B/C** — scenario tests needing reports can use either P2 Phase A's Java path (immediate) or wait for Phase C (default flipped). Either way, no blocker.

What must stay serial:

- **P1 §2 before §5** (§5 builds on §2's rebuilt fixtures + assertion helpers).
- **PR #47 (`feature/utc-timezone`) merged to `develop` → P2 Phase A** (P2 baselines on `V1.2.05`'s `timestamptz` report functions, which land with #47; re-run P2 §2.2.1 byte-diff against the merged `V1.2.05` at Phase A kickoff).
- **P2 Phase A before B before C before D** (rollout invariant).
- **P3 rename before any test that references the renamed type** (compile-break otherwise).

---

## 6. Flyway impact (cross-plan)

Only P2 touches migrations, and only at Phase D:

| Plan | New migration | Touches existing migrations? | Test profile impact |
|---|---|---|---|
| P1 (H2 migration) | None | No | Has `spring.flyway.enabled=false` for H2; Hibernate `create-drop` from entities |
| P2 (PL/pgSQL → Java) | **`V2.1.17__drop_report_functions.sql`** at Phase D only, rollback **`V2.1.18__restore_report_functions.sql`** | No | Testcontainers-PG boots add one create→drop cycle per fresh boot. Harmless. |
| P3 (Advisory lock) | None | No | Interface change only |

**Migration numbering (verified 2026-06-17):** on `develop` the head is `V2.1.14`. The `feature/utc-timezone` branch (PR [#47](https://github.com/SiteBossInc/wms2-api/pull/47)) adds `V2.1.15__add_api_timestamp_format_sysprop.sql` and `V2.1.16__replenishment_monitor_view_flag_based_classification.sql`, so **once it merges the head is `V2.1.16` and the next free is `V2.1.17`** — hence P2's drop = `V2.1.17`, restore = `V2.1.18`. The April draft's `V2.1.08`/`V2.1.09` and the UTC branch's `V2.1.15`/`V2.1.16` are all taken. **Re-derive the next-free number at Phase D execution time** — Phase D is several release cycles out, so more migrations will land first. Do not hardcode `V2.1.17`. (Note: PR #47's `V1.2.05` also recreates the three report functions as `timestamptz`, so P2 baselines on those bodies — see P2's cross-branch note.)

---

## 7. Risks this rollup surfaces (beyond per-plan risks)

| Risk | Impact | Mitigation |
|---|---|---|
| **H2 lane verifies wiring, not SQL-engine fidelity** | PG-specific regressions in H2-covered code are structurally invisible to the default lane — this is the core risk of the whole initiative | The PG (Testcontainers) lane is **load-bearing** for SQL fidelity and MUST have a named owner + a **blocking** CI cadence (not "nightly if someone remembers"). P2's parity gate (below) is necessary but not sufficient. |
| **"Parity tests catch divergence" is false comfort** | P2's Java-vs-DB parity test only proves equality *for what it seeds*; H2-vs-PG divergence (BigDecimal scale, `date_trunc` rounding, timezone) shows up on un-seeded shapes | P2 §6 must seed timezone-boundary and rounding-boundary cases deliberately, use scale-insensitive `BigDecimal.compareTo`, and require a deterministic total `ORDER BY`. The PG lane remains the backstop. |
| **P3 rename collides with 8 job files + the contract test** | Compile break / broken contract test if P1 §2 rebuilds in parallel | Sequence the P3 rename first, or rebase. P3 includes the checklist item to retarget `AdvisoryLockServiceJobLockIdContractTest`. |
| **Outbox advisory lock is load-bearing, not defensive** | If the outbox/idempotency `@Scheduled` jobs run on all replicas (they appear to — `@EnableScheduling` is unconditional and `OutboxDispatcherJob` has no `app.cron` gate), the in-memory test lock carries a higher correctness bar | P3 Open Question Q1: confirm replica/outbox topology with the deploy owner. The in-memory impl needs a per-test `reset()` hook (P3 §3.1.3) and must never reach a multi-replica path (allowlist guard, P3 §3.2). |
| **P2 Phase A wires the wrong datasource** | If the new report services autowire the `@Primary`/landlord DS instead of `tenantDynamicRoutingDataSource`, reports query the wrong DB | P2 §3.0 fixes the bean explicitly (`tenantDynamicRoutingDataSource`, `TenantDatabaseConfig.java:54-72`); `TestDatabaseConfig` forwards it to H2 in tests. Verify in Phase A. |
| **P2 Phase D dropped before Phase C is stable** | Report outage if Phase C rollback needed post-drop | Phase D explicitly gated on "1 release cycle after Phase C is stable in prod." Restore via a new forward migration (re-derive number) if needed — reports are client-facing. |

---

## 8. Status tracking

Update each sub-plan's frontmatter `status:` as phases complete. This rollup tracks only gate-level completion:

| Gate | Status | Date | Notes |
|---|---|---|---|
| P1 §1 audit 18 `@Disabled` + no-Docker acceptance test | ◯ pending | — | acceptance: `mvn verify` green with Docker daemon stopped |
| P1 §2 rebuild ~8 Category-A legacy tests | ◯ pending | — | onto existing `BaseIntegrationTest` + `TestDataFactory` |
| P3 advisory-lock refactor | ◯ pending | — | 8 job files / 16 sites + contract test |
| P2 Phase A Java report services | ◯ pending | — | on `tenantDynamicRoutingDataSource`; real H2 gate for report tests |
| P1 §3 Category-C fixtures + cleanup | ◯ pending | — | |
| P1 §4 make PG opt-in lane real | ◯ pending | — | **gated on named PG-lane owner** |
| P2 Phase B staging bake | ◯ pending | — | calendar-bound |
| P1 §5 scenario scaffold | ◯ pending — **optional** | — | needs P3 + P2 Phase A |
| P2 Phase C prod flip | ◯ pending | — | |
| P2 Phase D drop functions | ◯ pending — **optional cleanup** | — | `V2.1.17` (re-derive); drops `timestamptz` sigs; gate on Phase C stability |

Legend: ◯ pending • ◐ in progress • ● done • ✗ blocked

---

## 9. Decisions needed before kickoff

Consolidating the open questions across the three plans — these are the decisions that affect more than one sub-plan:

1. **Who owns the PG opt-in lane, and what is its CI cadence?** This is now a **precondition**, not a nice-to-have: the H2 lane cannot catch PG-specific regressions, so the PG lane must have an owner and a blocking cadence. *(Rollup recommendation: name an owner before P1 §4; run the PG lane pre-merge-to-main, not nightly-best-effort.)*
2. **Confirm the outbox/idempotency replica topology (P3 Q1).** If those `@Scheduled` jobs run on all replicas, the advisory lock is load-bearing and the in-memory test substitute needs the reset-hook discipline P3 specifies. *(Rollup recommendation: confirm with deploy owner; treat the lock as load-bearing until proven otherwise.)*
3. **PR #47 (`feature/utc-timezone`) must be merged to `develop` before P2 Phase A begins (hard precondition).** P2 baselines its report-function port on `V1.2.05`'s `timestamptz` bodies, which only exist on `develop` after #47 lands; the report-port drop/restore migrations (`V2.1.17`/`V2.1.18`) also assume #47's `V2.1.15`/`V2.1.16` are present. *(Rollup recommendation: do not start P2 Phase A until #47 is merged; at kickoff, re-run P2 §2.2.1's byte-diff against the merged `V1.2.05` and re-derive line/migration numbers. If #47 is dropped, P2's fallback baseline applies — see P2 re-grounding note.)*
4. **Commit to P2 Phase D, or accept "Phase C is our forever state"?** Phase D is cleanup; Phase C (Java default, functions present but unused) is sufficient for the H2 goal. *(Rollup recommendation: commit to Phase C; revisit Phase D next quarter and re-derive the migration number then.)*
5. **Include scenario tests (P1 §5) in this rollup, or split into a follow-on?** Scenario tests address the real coverage gap but balloon the critical path by 3–5 days and need both P3 and P2 Phase A. *(Rollup recommendation: split. Deliver P1 §1–4 + P3 + P2 Phase A first; scenario tests in a follow-on plan.)*
6. **Does P3 run parallel (needs a second engineer + the rename coordination in §5) or serial (adds 1–2 days)?** *(Rollup recommendation: parallel — P3 is small and isolated, but land the rename before any parallel test rebuild touches the lock.)*

---

## 10. How to use this rollup

- **When opening a PR for any sub-plan work:** reference the rollup's gate in the PR description (e.g. "gate: P1 §2").
- **When a sub-plan's `status:` flips:** update the table in §8.
- **When a dependency assumption breaks:** update §3 / §7 and raise in standup before continuing downstream work.
- **Before starting any phase:** re-confirm the file references in the relevant sub-plan still match HEAD (these docs drift — the April→June gap is what forced this regeneration).
- **When archiving a sub-plan:** leave the rollup in place until all three sub-plans are done or cancelled; then archive this rollup too.
