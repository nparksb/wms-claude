---
title: "WineCo Replenishment Job — Open-State Partial Index + Cron Recalc Cadence"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: draft
project: [wms1]
version: v1
requester: "Nam Park"
created: 2026-07-01
updated: 2026-07-01
status_detail: "Architect + Critic APPROVED 2026-07-01 (consensus, zero blocking) — ready for human sign-off / implementation"
db_verified: true
related:
  - "[[260701-wineco-replenishment-job-slow-runtime-index-eval]]"
  - "[[wms1-scheduled-jobs-catalog]]"
tags:
  - plan
  - replenishment
  - performance
  - indexing
  - scheduled-jobs
---

# WineCo Replenishment Job — Open-State Partial Index + Cron Recalc Cadence

**Project:** wms1 | **Version:** v1/wms-api | **Type:** bugfix (performance)
**Priority:** High
**Status:** approved (Architect + Critic consensus, 2026-07-01) — awaiting human sign-off before implementation
**Date:** 2026-07-01

> Authored from the DB-verified investigation report `260701-wineco-replenishment-job-slow-runtime-index-eval.md` (recommendation = Fix now), then reviewed by the Architect and Critic lanes (2026-07-01). Both returned **APPROVE-WITH-CHANGES / zero BLOCKING** — the shipped artifacts (the `WHERE state < 700` partial index and the one-token `force` change) were confirmed correct against the code; this revision folds in their findings (corrected migration-execution rationale, completed §0 enumeration, tightened test spec, index-eligibility wording, observability). Submitted for human sign-off before implementation.

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn` over `src/main/java`, `src/main/resources/db/migration`, `src/test/java`.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `repo/jpa/ReplenishorderRepository.java:104-105` `findByStateLessThanEqualAndDestinationIdIsNull(300)` | `state <= 300 AND destination_id IS NULL` seq scan | yes (state scan) | **served by index (Fix A)** — no code change |
| 2 | `repo/jpa/ReplenishorderRepository.java` `getIdsForUnreachableReplenishOrders` | `state <= 300` seq scan + joins | yes | served by index (Fix A) |
| 3 | `repo/jpa/ReplenishorderRepository.java` `getIdsToCancelReplenishOrders` | `state <= 300` seq scan | yes | served by index (Fix A) |
| 4 | `repo/jpa/ReplenishorderRepository.java` `getIdsToUpdateReplenishmentOrderPriority(/2)` | `state < 500` seq scan | yes | served by index (Fix A) |
| 5 | `ReplenishmentOrderMaintenanceService.java:74` `findByState(300)` (via `recalculateOpenOrders`) | `state = 300` seq scan | yes | served by index (Fix A) |
| 6 | `schedulejob/ReplenishOrderJob.java:93` `recalculateOpenOrders(true)` | cron passes `force=true`, bypasses cadence throttle | yes (frequency) | **Fix B — change to `false`** |
| 7 | `service/mobile/MobileReplenishService.java:789` `recalculateOpenOrders(true)` | user-triggered multi-fulfill recalc | no — must stay immediate | **excluded** (keep `force=true`) |
| 8 | `repo/jpa/ReplenishorderRepository.java:165` `getIdsToDeleteEmptyFixAssignmentWithoutStockToReplenish` (via `deleteEmptyFixAssignmentWithoutStockToReplenish`, `ReplenishOrderJob.java:77`) | NOT EXISTS `replenishorder.state < 700` | yes | served by index (Fix A) |
| 9 | `repo/jpa/ReplenishorderRepository.java:194` `getIdsForItemDataWithFixedAssignmentWithOrders` (via `ReplenishOrderJob.java:85`) | NOT EXISTS `replenishorder.state < 700` | yes | served by index (Fix A) |
| 10 | `repo/jpa/ItemdataRepository.java:66-104` `getIdsForItemDataWithoutFixedAssignment` | NOT EXISTS on `replenishorder` by `itemdata_id` | no — already index-served (`index_replenishorder_itemdata_id`) | excluded (report §5.7 null result) |
| 11 | `repo/jpa/ReplenishorderRepository.java:83,318` `findByStateGreaterThanPage`, `getClosedViewByKeyword` (`state > :state` / `state >= :state`) | ad-hoc UI/REST queries — `state >` predicates, NOT served by a `WHERE state < 700` index | no — not the hot path | excluded (ad-hoc UI, not the 60×/hr job) |
| 12 | `src/main/resources/db/migration/` (latest `V1.26.30`) | schema migrations | n/a | **Fix A — add `V1.26.31`** |

Rows 1–5, 8, 9 are all served by the single index in Fix A (no per-query code change) — every one has a state predicate that implies `state < 700` (`= 300`, `<= 300`, `< 500`, `< 700`). Row 6 is the only Java change. Rows 7, 10, 11 are explicitly excluded with rationale.

> **Enumeration note (from review):** rows 8–9 were added after the Architect/Critic pass — the cron issues **at least 7** `replenishorder.state` touches, not the "~6" an earlier draft stated. Row 8's phase (`deleteEmptyFixAssignmentWithoutStockToReplenish`) is also likely **dormant in prod** due to a pre-existing bug at `ReplenishOrderJob.java:200` (`Boolean.parseBoolean(WmsConstants.SYSTEM_PROPERTY_..._KEY)` parses the *constant's key-name string*, not the sysprop value → always false). That defect is **out of scope** here (do not fix); noted so a reviewer knows the phase may not run. Row 11 (`state >`/`state >=` REST queries) is deliberately not served — the partial index targets the job's `state < X` hot path, not ad-hoc UI reads.

---

## 1. Problem Statement

WineCo runs a dedicated `wms-api` production container with `app.cron=true`, so it executes the scheduled jobs. The replenishment job `ReplenishOrderJob.doCalculation` (`schedulejob/ReplenishOrderJob.java:60-95`) is the **slowest scheduled job across all client production instances**, and its cron default fires **every minute** (`wms1-scheduled-jobs-catalog.md:86,172-173`).

**Symptom (DB-verified, live read-only against `wms1-wineco` MCP, 2026-07-01):**
- `replenishorder` = **61,071 rows**; only **624 open** (`state <= 300`, all exactly `state = 300`); ~60,447 (99%) terminal (`state >= 700`).
- **No index on `state`** (indexes: `itemdata_id, client_id, destination_id, operator_id, pkey, requestedlocation_id, requestedrack_id, stockunit_id, number`).
- **At least 7** job phases filter `replenishorder` by `state` (see §0 rows 1–5, 8, 9) and each does a **full 61K-row seq scan** to return ≤624 rows, every minute. Sample `EXPLAIN` estimates: `findByState(300)` seq scan cost ~1990; `getIdsForUnreachableReplenishOrders` seq scan 1676 (total 3956); `getIdsToUpdateReplenishmentOrderPriority` seq scan 1990 (total 3967). Note these cost estimates predate the 2026-07-01 13:39 UTC manual `VACUUM (ANALYZE)` that refreshed planner stats — see §8 M1 for the corrected baseline-capture procedure.

WineCo is slowest because it has the deepest history — the code is O(total history) where it should be O(open orders). Full evidence in the source report.

> **Out of scope (cross-referenced, not fixed here):** the same tenant had badly **stale planner statistics** since the 2026-06-06 cutover (ANALYZE never refreshed row estimates — planner saw customerorder ~1,700 rows vs actual ~479K, stockunit ~8K vs ~1.9M). This was NOT physical bloat (an earlier read misclassified it — see report §5.5 correction). A manual `VACUUM (ANALYZE)` at 2026-07-01 13:39 UTC fixed the stats; autovacuum is enabled but has never *completed* on these tables — verification/monitoring is a DBA/ops action (report §8 item 2), not a code/schema change, and does not belong in this plan.

---

## 2. Root Cause Analysis

### Bug 1 — No index supports the `state`-predicate scans

`replenishorder` has no index whose leading column is `state`. Every phase that selects the open working set (`state = 300`, `state <= 300`, `state < 500`) therefore full-scans all 61K rows. On small/new tenants this is cheap; on WineCo's 61K-row table it is the dominant recurring cost, paid 60×/hour.

The originally-proposed index —
```sql
CREATE INDEX CONCURRENTLY idx_replenishorder_open_null_destination
ON replenishorder (state, itemdata_id) WHERE destination_id IS NULL AND state <= 300;
```
— is **correct but too narrow**: its partial predicate is only *implied by* `findByStateLessThanEqualAndDestinationIdIsNull(300)` (site #1). Sites #2–#5 have no `destination_id IS NULL` predicate (and #4 uses `state < 500`, not `<= 300`), so Postgres cannot use it for them. It fixes 1 of 6 scan phases.

### Bug 2 — Cron path bypasses the recalculation cadence throttle (frequency amplifier)

`ReplenishmentOrderMaintenanceService.recalculateOpenOrders(boolean force)` has a cadence guard (`shouldSkipForCadence()`, `ReplenishmentOrderMaintenanceService.java:148-165`) gated by the sysprop `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS`. The cron path calls it with **`force = true`** (`ReplenishOrderJob.java:93`), which skips the guard, so the full open-order recalculation (site #5's seq scan + per-order re-fetch/save loop) runs on **every** one-minute tick.

**Load-bearing nuance (verified):**
- `lastRun` initializes to `Instant.EPOCH` (`ReplenishmentOrderMaintenanceService.java:44`) → the first post-startup call never skips, and there is no NPE risk.
- The cadence sysprop **default is `"0"`** (`WmsConstants.java:998-999`), and `shouldSkipForCadence()` returns `false` when the cadence is zero/negative. **Therefore changing `force=true` → `force=false` alone has NO runtime effect** until an operator sets `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` to a positive value. The code change *enables* the throttle; the sysprop *activates* it. With the default sysprop the behavior is unchanged (no regression, no improvement).

---

## 3. (Regression Chain)

Not a regression. `ReplenishmentOrderMaintenanceService` (cadence guard) and the recent `V1.26.29/30` replenishment-monitor-view migrations are new, but the missing `state` index and the `force=true` cron call are original design, not a recently-introduced defect.

---

## 4. Architecture Overview

```
SchedulingConfiguration.replenish()  (cron: every minute by default)
  └─ ReplenishOrderJob.doCalculation(isCronJob=true)      ReplenishOrderJob.java:60
       ├─ mergePickingOrders()
       ├─ cancelUnreachableReplenishment()   → getIdsForUnreachableReplenishOrders (state<=300)   ── seq scan ─┐
       ├─ cancelReplenishmentIfFlowbinIsFull → getIdsToCancelReplenishOrders (state<=300)          ── seq scan ─┤
       ├─ deleteEmptyFixAssignment…(L77)     → getIdsToDeleteEmptyFix… (NOT EXISTS state<700)†     ── seq scan ─┤
       ├─ generateReplen…noFixedAssign (itemdata) → itemdata_id-keyed (already indexed)                        │  all
       ├─ generateReplen…FixedAssign(L85)    → getIdsForItemDataWithFixedAssignmentWithOrders (state<700) ─────┤  served
       ├─ updateReplenishmentOrderPriority   → getIdsToUpdateReplenishmentOrderPriority (state<500) ── seq scan ┤  by
       ├─ recalculateReplenishmentOrderWithoutFixedLocationAssignment                                          │  Fix A
       │      → findByStateLessThanEqualAndDestinationIdIsNull(300)                                 ── scan ────┤
       └─ recalculateOpenOrders(true)  ── Fix B: → false ──→ findByState(300)                       ── seq scan ┘
              (force=true bypasses shouldSkipForCadence)

† deleteEmptyFixAssignment… is likely DORMANT in prod — pre-existing Boolean.parseBoolean(KEY_NAME) bug at
  ReplenishOrderJob.java:200 gates it off. Out of scope (do not fix); index still serves it if ever enabled.
```

**Key Files**

| File | Lines | Role |
|------|-------|------|
| `schedulejob/ReplenishOrderJob.java` | 60-95, **93** | Cron driver; L93 recalc call (Fix B) |
| `service/ReplenishmentOrderMaintenanceService.java` | 44, 65-86, 148-165 | `recalculateOpenOrders` + cadence guard; `lastRun=EPOCH` |
| `repo/jpa/ReplenishorderRepository.java` | 104-105, 130-158, 203-238 | The `state`-predicate queries (Fix A serves all) |
| `service/mobile/MobileReplenishService.java` | 789 | User-triggered recalc — **unchanged** |
| `src/main/resources/db/migration/` | latest `V1.26.30` | Flyway; add `V1.26.31` (Fix A) |
| `service/WmsConstants.java` | 998-999 | Cadence sysprop key + default `"0"` |

---

## 5. Fix Design

### Fix A — Partial index on `replenishorder.state` (Flyway `V1.26.31`)

New migration `src/main/resources/db/migration/V1.26.31__replenishorder_open_state_index.sql`:

```sql
-- Partial index on the "open" replenish-order working set (state < 700 = not FINISHED/CANCELED).
-- Serves every state-predicate phase of ReplenishOrderJob.doCalculation:
--   state = 300, state <= 300, state < 500  all imply  state < 700.
-- Subsumes the originally-proposed narrow index (WHERE destination_id IS NULL AND state <= 300).
--
-- Plain (non-CONCURRENT) CREATE is used here on purpose. NOTE: migrations do NOT run at app
-- startup on this project — flyway-core is <scope>test</scope> (pom.xml:375-376), the Dockerfile
-- ENTRYPOINT is just `java -jar` (no flyway:migrate), and ddl-auto=none. Production index creation
-- is 100% an out-of-band DBA action (mvn flyway:migrate uses flyway-maven-plugin 9.12.0, or direct
-- SQL). The plain-CREATE constraint exists because the TEST harness (AppPostgresDBSetupExtension,
-- Flyway 6.4.4, applies migrations inside a transaction) would fail on a CONCURRENTLY statement.
-- For LARGE existing production tenants (e.g. WineCo, ~61k rows) a DBA MUST create this index
-- CONCURRENTLY out-of-band with the EXACT name+predicate below (see §7 Prerequisites); IF NOT EXISTS
-- (matched by index NAME) then makes this file a no-op there.
CREATE INDEX IF NOT EXISTS idx_replenishorder_open_state
    ON replenishorder (state)
    WHERE state < 700;
```

**Why this and not alternatives:**
- **vs. the proposed narrow index:** `WHERE state < 700` (624 rows) is implied by every state predicate the cron issues (`state=300`, `state<=300`, `state<500`, and the two `state<700` NOT-EXISTS phases — §0 rows 1–5, 8, 9), so it is **eligible for all of them**, not just site #1. Index *use* is guaranteed on the two single-table scans (`findByState(300)`, `findByStateLessThanEqualAndDestinationIdIsNull`); on the multi-join phases the planner may still scan `replenishorder` as a hash/merge inner side — so those are confirmed by the M1 `EXPLAIN (ANALYZE, BUFFERS)` (§8), not asserted here. The narrow index's target (site #1) becomes a 624-entry index scan then a trivial filter to the 90 null-destination rows.
- **vs. `CREATE INDEX CONCURRENTLY` inside the migration file:** the migration is applied by two different Flyway versions — **prod** via the maven plugin **9.12.0** (which *does* support `-- executeInTransaction=false`, so CONCURRENTLY would work there) but the **test IT lane** via **Flyway 6.4.4** inside a transaction (`AppPostgresDBSetupExtension`), which has no per-script transaction control and would **fail to boot** on a CONCURRENTLY statement. So a CONCURRENTLY migration file would break the test harness even though prod could run it. Keeping the file plain + doing CONCURRENTLY out-of-band on big tenants satisfies both lanes. (Do NOT set `spring.flyway.mixed=true` — irrelevant here since Spring Boot doesn't run migrations at all.)
- **vs. full (non-partial) index on `state`:** a partial index excludes the ~60K terminal rows, so it stays tiny and cheap to maintain on every insert/update of a finished order. Trade-off: the partial index will NOT serve the `state >`/`state >=` REST queries (§0 row 11) — accepted, since those are ad-hoc UI reads, not the 60×/hr job.

### Fix B — Cron recalc honors cadence (`ReplenishOrderJob.java:93`)

```java
// Before
replenishmentOrderMaintenanceService.recalculateOpenOrders(true);
// After
replenishmentOrderMaintenanceService.recalculateOpenOrders(false);
```

**Why:** lets the scheduled path respect `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` so the full recalc no longer runs on every one-minute tick. **This is inert until the operator sets that sysprop > 0** (default `"0"` → never skips → no behavior change). `MobileReplenishService.java:789` stays `true` — a user just performed a multi-fulfill and expects an immediate recalc. No other production caller exists (site enumeration §0).

**Fix B2 (observability, same commit) — log the skip so ops can verify the throttle.** `shouldSkipForCadence()` currently returns silently, so when the sysprop is set an operator can only infer the throttle works from the *absence* of downstream logs. Add one debug line at the skip point in `recalculateOpenOrders(boolean)` (`ReplenishmentOrderMaintenanceService.java:70`):

```java
// After
if (!force && shouldSkipForCadence()) {
    LOG.debug("recalculateOpenOrders skipped: within cadence window (lastRun={})", lastRun);
    return;
}
```
SLF4J parameterized (no string concat). This makes M4 verifiable by log presence, not just absence.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `src/main/resources/db/migration/V1.26.31__replenishorder_open_state_index.sql` | **new** | Partial index `idx_replenishorder_open_state (state) WHERE state < 700` |
| `schedulejob/ReplenishOrderJob.java` | edit (1 token) | L93 `recalculateOpenOrders(true)` → `(false)` |
| `service/ReplenishmentOrderMaintenanceService.java` | edit (1 line) | Fix B2: `LOG.debug` on cadence skip at L70 |
| `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | edit (add tests) | Assert `force=false` within cadence skips the query (see §8). **NOT** the IT-style `src/test/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceServiceTest.java` |
| `sbdocs/9-System/scripts/verify-260701-wineco-replenishment-job-index-and-cadence.sh` | new | Acceptance script |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| **How the index actually gets created (critical)** | **YES** | Deploying the JAR does **NOT** create the index — `flyway-core` is `test`-scope and nothing runs migrations at startup (Dockerfile is `java -jar`, `ddl-auto=none`). Index creation is an explicit ops step on **every** tenant: either a DBA runs the SQL directly, or someone runs `mvn flyway:migrate` (flyway-maven-plugin 9.12.0) against each tenant DB. Do not assume the deploy handles it. |
| **DB state / pre-deploy DBA action** | **YES** | On large tenants (WineCo first), a DBA runs off-peak, using the **exact** index name and predicate: `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_replenishorder_open_state ON replenishorder (state) WHERE state < 700;`. The name+predicate MUST match the migration exactly — `IF NOT EXISTS` matches by **name only**, so a divergent predicate would silently leave the wrong index in place with no error. `CONCURRENTLY` cannot run in a txn and briefly waits on in-flight writes. Small tenants can just run the plain `V1.26.31` migration (instant). |
| **Flyway history idempotency** | Note | If a DBA creates the index CONCURRENTLY out-of-band, later running `mvn flyway:migrate` applies `V1.26.31` as a no-op (IF NOT EXISTS) and records it in `schema_version` — fine. If flyway is never run on that tenant, `schema_version` simply won't list `V1.26.31` until the next migrate (also fine, still a no-op). Either order is idempotent. |
| **System property** | **YES (for Fix B to take effect)** | To actually reduce recalc frequency, set sysprop `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` to a positive value (e.g. `300`) per tenant in `LosSysprop`. Leaving the default `"0"` keeps current behavior (safe). |
| **Feature flags** | No | — |
| **Deploy-order dependency** | **YES** | DBA `CONCURRENTLY` index creation should precede (or accompany) rolling `V1.26.31` to that tenant. Order relative to Fix B (code) does not matter. |
| **Config / env** | No | Do NOT set `spring.flyway.mixed=true` (irrelevant — Spring Boot doesn't run migrations here anyway). |
| **Data migration / backfill** | No | Index only. |
| **External systems** | No | — |
| **Monitoring** | Recommended | Capture `EXPLAIN (ANALYZE, BUFFERS)` of the §1 queries before/after (see §8 M1); watch job-duration log line `end. took <ms>ms` (`ReplenishOrderJob.java:94`); Fix B2 debug log confirms cadence skips. |

### 7.2 Steps (each independently committable)

1. Add migration `V1.26.31__replenishorder_open_state_index.sql` (Fix A). Commit.
2. Change `ReplenishOrderJob.java:93` to `recalculateOpenOrders(false)` (Fix B). Commit.
3. Add the unit test in §8. Commit.
4. Run acceptance: `bash sbdocs/9-System/scripts/verify-260701-wineco-replenishment-job-index-and-cadence.sh` → must report `Result: N pass, 0 fail`.

---

## 8. Testing Plan

### Unit
Add to the **Mockito** test `src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` (uses `@ExtendWith(MockitoExtension.class)` → **strict stubbing**; `losSyspropRepository` is an injected `@Mock`). **Not** the Spring/IT-style `.../service/ReplenishmentOrderMaintenanceServiceTest.java` (blocked IT lane — the test would not run and the acceptance gate would falsely fail).

Both new tests MUST **explicitly stub the cadence sysprop** — with strict stubbing an unstubbed `findSysvalueBySyskey(...)` returns `null`, which happens to fall through to cadence `0` via the `parseLong` catch, so an un-stubbed test would *accidentally* exercise the wrong path and never assert what it claims:

- `recalculateOpenOrders_forceFalse_withinCadence_skipsQuery()` —
  `when(losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_CADENCE_SECONDS_KEY)).thenReturn("3600");`
  then `recalculateOpenOrders(true)` once (sets `lastRun`), then `recalculateOpenOrders(false)`, and `verify(replenishorderRepository, times(1)).findByState(WmsConstants.State.PROCESSABLE)` — the second (force=false) call is skipped by the cadence window. (Both calls share the instance `lastRun` because the method is `synchronized`.)
- `recalculateOpenOrders_forceFalse_cadenceZero_runsEveryTime()` —
  `when(...CADENCE...KEY)).thenReturn("0");` then two `recalculateOpenOrders(false)` calls, and `verify(replenishorderRepository, times(2)).findByState(...)` — guards the default-behavior-unchanged claim (cadence 0 → never skips).
- Mockito 3.3.3 — no `mockStatic` needed; `losSyspropRepository` is an injected mock.
- No unit test is added for the migration SQL (DDL); its correctness is asserted by the manual EXPLAIN below and the verify script's file/content checks.

### Integration
- **Skipped.** Per project memory, the v1 `@SpringBootTest`/Testcontainers IT lane is currently blocked (ro_id view drift SBDEV-2384 and Testcontainers issues). Acceptance rests on `mvn clean compile` + the targeted unit test + the manual EXPLAIN. Re-enable an IT that boots Flyway `V1.26.31` once the IT harness is unblocked.

### Regression
- `mvn clean compile` (catches the one-token edit / any drift).
- `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest` — all existing cases (which call `recalculateOpenOrders(true)`) must still pass.

### Manual test plan

| # | Scenario | Environment | Steps | Expected |
|---|---|---|---|---|
| M1 | Index used by all state phases | wms1-wineco (DBA, off-peak) | **Capture baseline FIRST** (post-13:39 VACUUM, pre-index) with `EXPLAIN (ANALYZE, BUFFERS)` on `WHERE state=300`, `state<=300 AND destination_id IS NULL`, `state<500`, **and the two join phases** (`getIdsForUnreachableReplenishOrders`, `getIdsToUpdateReplenishmentOrderPriority`). Then create the index CONCURRENTLY and re-run the same EXPLAINs. | Single-table scans switch Seq Scan → Index/Bitmap on `idx_replenishorder_open_state`. **Confirm** the two join phases also use the index (they may not — planner-dependent); if a join phase still seq-scans, note it — the fix is still net-positive but that phase is unimproved. Baseline captured post-vacuum so the delta reflects the index alone, not the vacuum. |
| M2 | Index definition matches + no-op where pre-exists | any tenant | After DBA create, run `SELECT indexdef FROM pg_indexes WHERE indexname='idx_replenishorder_open_state';` — confirm it is exactly `... (state) WHERE (state < 700)`. Then run `V1.26.31` (mvn flyway:migrate) | `indexdef` predicate is `state < 700` (NOT a divergent predicate); migration applies as a no-op via `IF NOT EXISTS`, no error, no duplicate/INVALID index |
| M3 | Migration creates index on a tenant without it | fresh/small tenant | Run `mvn flyway:migrate` (or DBA SQL) — NOTE: deploying the JAR alone does NOT create it | Index created (instant on small tables); `\d+ replenishorder` shows it |
| M4 | Cron cadence honored | staging with `app.cron=true` | Set `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS=300`; watch `ReplenishOrderJob` logs over several minutes | Recalc-open-orders phase runs at most once per 5 min; other phases still run each tick |
| M5 | Default sysprop = no behavior change | staging | Leave sysprop `"0"`; deploy Fix B | Recalc runs every tick as before (no regression) |
| M6 | Mobile multi-fulfill still recalcs immediately | staging mobile | Perform multi-unitload replenish fulfill | Open orders recalculated immediately (site #789 unchanged) |

### Post-implementation gate
Run `verify-260701-wineco-replenishment-job-index-and-cadence.sh` first (FAIL baseline) and last (`Result: N pass, 0 fail`); paste the final line in the completion report. Update §11 with commit SHAs, test method names, and `mvn` results.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `CREATE INDEX CONCURRENTLY` fails mid-way on a big tenant, leaving an INVALID index | Index unused; disk used | DBA runs off-peak, `IF NOT EXISTS`; if INVALID, `DROP INDEX` and retry. Migration's plain `CREATE` is not used on big tenants (no-op via IF NOT EXISTS). |
| DBA creates the out-of-band index with a **divergent name or predicate** (e.g. `state <= 600`, or forgets `WHERE`) | Migration silently no-ops (matches by name) → wrong index permanently in place, no error; or a name mismatch triggers a full-lock plain `CREATE` on a large table | §7.1 mandates the **exact** name `idx_replenishorder_open_state` + predicate `WHERE state < 700`; M2 verifies `pg_indexes.indexdef` post-create. (Verify script only checks the migration *file*, not the deployed DB — M2 is the DB-level gate.) |
| A future engineer "fixes" the migration to use `CONCURRENTLY` | Test IT lane (`AppPostgresDBSetupExtension`, Flyway 6.4.4, transactional) fails to boot | Migration comment + §5 explain *why* it must stay plain; verify script asserts `CONCURRENTLY` is NOT in the migration file (fails fast). |
| Plain `CREATE INDEX` (non-concurrent) run via `mvn flyway:migrate` against a **mid-size** tenant that skipped the DBA CONCURRENTLY step | Brief write-blocking `SHARE` lock on `replenishorder` while the index builds — can stall the every-minute cron's own writes | Do the DBA CONCURRENTLY pre-step on any non-trivial tenant; §10 flags the per-tenant row-count check to decide which tenants need it. Do NOT rely on `spring.flyway.mixed=true` (Spring Boot doesn't run migrations here). |
| Fix B assumed to reduce load but sysprop left at `"0"` | No improvement (but no regression) | §5/§7 state the sysprop is required to activate; M4/M5 verify both paths. |
| Cadence set too high → replenishment recalc lags real demand | Slightly stale open-order priorities | Cadence is operator-tunable per tenant; start at 300s, adjust. Other job phases (generate/cancel/priority) still run every tick — only the `recalculateOpenOrders` recompute is throttled. |
| Index maintenance overhead on write | Negligible | Partial index (624 rows) only indexes non-terminal rows; terminal-state transitions drop the row out of the index. |
| Concurrency: v1 jobs have no in-JVM RUNNING guard (`wms1-scheduled-jobs-catalog.md:114`) | Pre-existing; unchanged | Out of scope; WineCo runs a single cron container. Not affected by this change. |

**Horizontal scalability (v2):** N/A — v1-only plan; v1/wms-api is not the horizontally-scaled service. A v2 counterpart is not applicable (v2 has its own `ReplenishOrderJob` with a RUNNING guard and different query layer; evaluate separately if v2 shows the same slow-job symptom).

---

## 10. Open Questions / Resolved Decisions

- **Resolved (defaults used, per "proceed"):** Scope = v1 only, single PR (migration + code + test). Behavior change: none by default (Fix B inert until sysprop set) — intentional, zero-regression rollout. Performance target: eliminate full-table seq scans on the state-predicate phases (verified via M1 EXPLAIN).
- **Open:** Which tenants besides WineCo have a large enough `replenishorder` to need the DBA `CONCURRENTLY` pre-step vs. letting the plain migration create it? (Small tenants: plain create is instant.) Requires per-tenant row-count check before deploy.
- **Open (out of scope, tracked in report):** autovacuum/stats remediation for `customerorder*` / `stockunit` — likely the bigger win; DBA action, not this plan.

---

## 11. Implementation Status

_Not yet implemented. Fill in on execution: commit SHA(s) for the migration and `ReplenishOrderJob.java` edit, added test method names, `mvn clean compile` + `mvn test -Dtest=ReplenishmentOrderMaintenanceServiceUnitTest` results, and the final `verify-...sh` line `Result: N pass, 0 fail, M skip`._

---

## Acceptance

Machine-checkable script: `sbdocs/9-System/scripts/verify-260701-wineco-replenishment-job-index-and-cadence.sh`
Run: `bash sbdocs/9-System/scripts/verify-260701-wineco-replenishment-job-index-and-cadence.sh` — acceptance = `Result: N pass, 0 fail`.
