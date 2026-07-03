---
title: "WineCo Replenishment Job Slow Runtime — Root Cause & Index Evaluation"
type: investigation
status: concluded
version: v1
scope: "v1/wms-api — ReplenishOrderJob.doCalculation + replenishorder indexing + tenant autovacuum"
owner: "Nam Park"
created: 2026-07-01
updated: 2026-07-01
last_verified: 2026-07-01
verified_by: "Nam Park (live wms1-wineco MCP)"
related:
  - "[[260601-wineco-replenishment-pickpack-source-and-order-count]]"
  - "[[wms1-scheduled-jobs-catalog]]"
tags:
  - investigation
  - report
  - replenishment
  - performance
  - indexing
  - autovacuum
---

# WineCo Replenishment Job Slow Runtime — Root Cause & Index Evaluation

**Topic:** `ReplenishOrderJob.doCalculation` runtime on WineCo prod (`app.cron=true`) + proposed `replenishorder` index | **Version:** v1/wms-api
**Started:** 2026-07-01 | **Investigator:** Nam Park
**Status:** concluded

---

## 1. Context & Trigger

The `wms-api` `release` branch was deployed to production. WineCo runs a **separate** `wms-api` container with `app.cron=true`, so it executes the scheduled jobs. WineCo's scheduled jobs run **longest of all client production instances**. A candidate index was proposed to speed up the replenishment job:

```sql
CREATE INDEX CONCURRENTLY idx_replenishorder_open_null_destination
ON replenishorder (state, itemdata_id)
WHERE destination_id IS NULL AND state <= 300;
```

This report determines the root cause of the slow runtime and evaluates whether that index helps (or whether a better one exists).

**Amplifying factor:** the replenishment cron default is **every minute** (`wms1-scheduled-jobs-catalog.md:86,172-173` — `REPLENISHMENT_TIMER_MINUTE`/`HOUR` default to `"*"` → `"0 * * * * *"`). Whatever this job costs per run, WineCo pays it 60×/hour.

---

## 2. Questions

1. Why does WineCo's replenishment scheduled job run longer than other clients' for identical code?
2. Which queries inside `ReplenishOrderJob.doCalculation` dominate the runtime?
3. Does the proposed partial index (`…WHERE destination_id IS NULL AND state <= 300`) meaningfully reduce runtime?
4. Is there a better single index?
5. Are there non-index levers (DB maintenance, scheduling) with larger or broader payoff?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | `replenishorder` has grown large on WineCo and `state`-filter phases seq-scan the whole table | high | Job filters by `state` in ~6 phases; no obvious `state` index |
| H2 | The proposed index fixes the bottleneck | medium | It targets a real query, but partial predicate looks narrow |
| H3 | The multi-join phases (against `customerorder*`, `stockunit`) dominate, not `replenishorder` scans | medium | Those queries have deeper join trees |
| H4 | DB maintenance (autovacuum/stats) is degraded on this tenant, inflating all scans | low | Not yet inspected |
| H5 | Nothing is actually wrong — WineCo is just the largest tenant and the job is O(history) by design | low | Must rule out; "largest tenant" alone could explain it |

---

## 4. Method

- Read the job driver `schedulejob/ReplenishOrderJob.java` and backing `service/job/ReplenishOrderJobService.java`, `service/ReplenishmentOrderMaintenanceService.java`, `service/ReplenishorderService.java`.
- Enumerated every `replenishorder` query in `repo/jpa/ReplenishorderRepository.java` and `repo/jpa/ItemdataRepository.java` (§3.5).
- Live, **read-only** inspection of the `wms1-wineco` production database via MCP: row counts, state/destination distribution, `pg_indexes`, `pg_stat_user_tables`, and `EXPLAIN` plans (estimates; `EXPLAIN ANALYZE` is blocked by the MCP tool). **No index was created** — MCP is read-only and this is production.
- Cross-referenced `wms1-scheduled-jobs-catalog.md` for cron cadence and prior WineCo replenishment report.

State constants (`service/WmsConstants.State`): `0=RAW, 200=ASSIGNED, 300=PROCESSABLE, 500=STARTED, 600=PICKED, 700=FINISHED, 800=CANCELED`.

---

## 3.5 Sources In Scope

| Source | Role |
|---|---|
| `schedulejob/ReplenishOrderJob.java:60-95` | `doCalculation()` — 11 phases in sequence |
| `schedulejob/ReplenishOrderJob.java:93` | `recalculateOpenOrders(true)` — **force=true**, bypasses cadence throttle |
| `service/ReplenishmentOrderMaintenanceService.java:65-86,148-165` | `recalculateOpenOrders` + `shouldSkipForCadence` (cadence gate) |
| `service/ReplenishorderService.java:250-271` | `recalculateReplenishmentOrderWithoutFixedLocationAssignment` → target of proposed index |
| `repo/jpa/ReplenishorderRepository.java:104-105` | `findByStateLessThanEqualAndDestinationIdIsNull(state)` — proposed-index target |
| `repo/jpa/ReplenishorderRepository.java:130-158` | `getIdsForUnreachableReplenishOrders`, `getIdsToCancelReplenishOrders` (`state <= 300`) |
| `repo/jpa/ReplenishorderRepository.java:203-238` | `getIdsToUpdateReplenishmentOrderPriority(/2)` (`state < 500`) |
| `repo/jpa/ItemdataRepository.java:66-104` | `getIdsForItemDataWithoutFixedAssignment` — NOT EXISTS on `replenishorder` by `itemdata_id` |
| `wms1-scheduled-jobs-catalog.md:86,165-181` | cron cadence = every minute; job phase list |
| `260601-wineco-replenishment-pickpack-source-and-order-count.md` | prior WineCo replenishment investigation |

Prior reports touching this area do **not** cover job runtime/indexing; this report is net-new and supersedes none.

---

## 5. Evidence

### 5.1 `replenishorder` is 99% dead-weight history, with no `state` index

**Source:** live `wms1-wineco`, `pg_indexes` + counts
**Observation:**
- 61,071 total rows; **only 624 open** (`state <= 300`, all exactly `state = 300`); ~60,447 (99%) are FINISHED/CANCELED (`state >= 700`).
- Indexes present: `itemdata_id`, `client_id`, `destination_id`, `operator_id`, `pkey`, `requestedlocation_id`, `requestedrack_id`, `stockunit_id`, `number` (unique). **No index on `state`.**
- `destination_id IS NULL` = 8,921 rows total, but only **90** of those are open (`state <= 300`); the other 8,831 are finished.

**Supports:** H1. **Contradicts:** partially H5 — size matters, but the fix is cheap (index), so it's not "by design / unavoidable".

### 5.2 Every `state`-filter phase full-scans the 61K-row table

**Source:** `EXPLAIN` (estimates) on live DB
**Observation:**

| Phase / method | Predicate | Plan | Est. cost |
|---|---|---|---|
| `recalculateOpenOrders` → `findByState(300)` | `state = 300` | **Seq Scan** | ~1990 |
| `cancelUnreachableReplenishment` → `getIdsForUnreachableReplenishOrders` | `state <= 300` + 4 joins | **Seq Scan** on replenishorder 1676 | 3956 total |
| `updateReplenishmentOrderPriority` → `getIdsToUpdateReplenishmentOrderPriority(/2)` | `state < 500` | **Seq Scan** 1990 + hash join | 3967 total |
| `recalculateReplenishmentOrderWithoutFixedLocationAssignment` → `findByStateLessThanEqualAndDestinationIdIsNull(300)` | `state <= 300 AND destination_id IS NULL` | Bitmap Index Scan on `replenishorder_destination_id` (~9,065 est) → filter `state` → 90 | ~1424 |

Every phase reads the full table (or the full 8.9K null-destination set) to return ≤624 rows. This runs **every minute**.
**Supports:** H1. **Contradicts:** H3 — the `replenishorder` seq scans are first-class cost centers, not just the joins.

### 5.3 The proposed index is correct but serves only 1 of ~6 phases

**Source:** predicate-implication analysis + §5.1/§5.2
**Observation:** The proposed partial index has predicate `destination_id IS NULL AND state <= 300` (only **90 rows**). For Postgres to use a partial index, the *query* predicate must **imply** the index predicate:
- `findByStateLessThanEqualAndDestinationIdIsNull(300)` → `state <= 300 AND destination_id IS NULL` → **implies it. ✓ (served)**
- `findByState(300)` → `state = 300`, no `destination_id` filter → does **not** imply `destination_id IS NULL`. ✗
- `getIdsToUpdateReplenishmentOrderPriority` → `state < 500` → does **not** imply `state <= 300`. ✗
- `getIdsForUnreachableReplenishOrders` / `getIdsToCancelReplenishOrders` → `state <= 300`, no `destination_id` filter → ✗

So the proposed index leaves the other five seq scans untouched. Its second column `itemdata_id` is only a covering column (the target query fetches all rows and loops; it never filters by `itemdata_id`), so it adds little.
**Supports:** rejects H2 as a *complete* fix; confirms it as a *partial* one.

### 5.4 A single broader partial index serves all phases

**Source:** predicate-implication analysis
**Observation:** A partial index keyed on `state` with predicate `state < 700` (FINISHED) contains only the **624 open rows** and excludes the 60K terminal rows. Every hot predicate implies `state < 700`: `state = 300` ✓, `state <= 300` ✓, `state < 500` ✓, and the NOT-EXISTS `state < 700` lookups ✓. It therefore serves **all** phases in §5.2, including the proposed index's own target (which becomes a 624-entry index scan, then a trivial filter to the 90 null-destination rows). It subsumes the proposed index.
**Supports:** H1 remediation; answers Q4.

### 5.5 Stale planner statistics since the 2026-06-06 cutover — NOT physical bloat (corrected)

> **Correction (2026-07-01, later same day):** an earlier draft of this section read the `pg_stat_user_tables` counters shortly after the DB stat counters had been reset and reported "68–87% dead / heavy bloat." That was an artifact — the dead-tuple ratios were computed against badly-understated live counts. A manual `VACUUM (ANALYZE)` on these five tables ran at **2026-07-01 13:39 UTC** (visible as `last_vacuum`), and the refreshed stats show the real picture below. The prior bloat figures are withdrawn.

**Source:** live `pg_stat_user_tables` + `pg_stat_database` (post-13:39 ANALYZE)
**Observation:** the stat counters were reset on **2026-06-06 04:00 UTC** (`pg_stat_database.stats_reset` — the WineCo cutover date), and `ANALYZE` had not refreshed live-row estimates until today's manual run. Before/after:

| table | live (stale, pre-ANALYZE) | live (true, post-ANALYZE) | dead now | true dead % |
|---|---|---|---|---|
| stockunit | 7,970 | **1,926,177** | 26 | ~0% |
| customerorder_position | 6,195 | **1,726,426** | 0 | ~0% |
| customerorder | 1,708 | **479,024** | 2 | ~0% |
| replenishorder | 413 | **61,071** | 3 | ~0% |

So these tables were **not** heavily bloated — dead tuples were always a small fraction of the true size. The real defect was **stale statistics**: the planner believed `customerorder` had ~1,700 rows (actual ~479K) and `stockunit` ~8K (actual ~1.9M). That magnitude of misestimate risks catastrophic plan choices at real scale, and it went unfixed for 25 days.

Separately, `last_autovacuum` is **NULL** on all five tables across those 25 days — autovacuum (which is `on`, `track_counts=on`, no per-table disable, stock thresholds) has **never completed** on them on its own. Today's manual vacuum fixed the stats; whether autovacuum keeps them fresh is unproven (see §9).
**Supports:** H4, but **reframed** — from "heavy bloat inflating scans" to "stale planner stats + autovacuum-never-completed." Also reveals the joined tables are far larger than §5.1's snapshot implied, which *strengthens* H1 (the job's joins are expensive at real scale).

### 5.6 The cron path bypasses the recalculation cadence throttle

**Source:** `ReplenishOrderJob.java:93`, `ReplenishmentOrderMaintenanceService.java:69-73,148-165`
**Observation:** `recalculateOpenOrders(boolean force)` has a cadence guard (`shouldSkipForCadence()` gated by `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS`). The scheduled path calls it with **`force = true`**, which skips the guard. So the full open-order recalculation runs on **every** one-minute tick regardless of the configured cadence — the throttle exists but is inert from the cron.
**Supports:** a cheap, correctness-neutral runtime reduction (Q5).

### 5.7 Null result — the `itemdata`-scan phase is already well-indexed

**Source:** `EXPLAIN` of `getIdsForItemDataWithoutFixedAssignment`
**Observation:** Plan is nested-loop / index-scan driven (itemdata has only 74 live rows; the correlated `NOT EXISTS` on `replenishorder` uses `index_replenishorder_itemdata_id`, cost ~0.66). This phase is **not** a bottleneck; no new index warranted here. Documents that the problem is specifically the `state`-only-predicate phases, not the `itemdata_id`-keyed ones.
**Supports:** narrows H1/H3 — confirms the fix target is `state` predicates.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H1 | Full seq scans of a large `replenishorder` (no `state` index) drive the runtime | **high** | §5.1, §5.2 |
| H4 | Stale planner stats (since 06-06 cutover) + autovacuum-never-completed — NOT physical bloat | **high (reframed)** | §5.5 |
| H2 | Proposed index fixes it | **low (as complete fix)** / medium (partial) | §5.3 |
| H3 | Multi-join phases dominate over `replenishorder` scans | **low** | §5.2 (scans are first-class), §5.7 |
| H5 | Nothing wrong / unavoidable | **rejected** | §5.1 — cheap index + maintenance available |

---

## 7. Verdict

WineCo's replenishment job is slow for two compounding, well-evidenced reasons. **First (H1):** `replenishorder` holds 61K rows of which 99% are terminal history, there is **no index on `state`**, and ~6 phases of `doCalculation` filter by `state` — so each runs a full 61K-row seq scan to return ≤624 open rows, **every minute**. WineCo is slowest simply because it has the deepest history; the code is O(total history) where it should be O(open orders). **Second (H4, corrected):** the planner statistics on the tables the job joins were badly stale since the 2026-06-06 cutover — `ANALYZE` never refreshed them, so the planner saw `customerorder` as ~1,700 rows (actual ~479K) and `stockunit` as ~8K (actual ~1.9M) — and autovacuum has never completed on them on its own (`last_autovacuum` NULL for 25 days). This is a *stale-stats* problem, not the physical bloat an earlier draft claimed; a manual `VACUUM (ANALYZE)` at 13:39 UTC today fixed the stats. It is broader than replenishment (all WineCo query planning was affected) but is an ops issue, not a code change.

The proposed index is **correct but too narrow (§5.3):** its `destination_id IS NULL AND state <= 300` predicate is only implied by one query, so it accelerates 1 of ~6 scan phases and leaves the two most expensive ones (`getIdsToUpdateReplenishmentOrderPriority`, `getIdsForUnreachableReplenishOrders`) and the every-tick `findByState(300)` recalculation still seq-scanning. A single broader partial index — `(state) WHERE state < 700` — subsumes it and serves all phases (§5.4).

**Confidence:** high for H1 — the index reasoning is deterministic from predicate implication, and `replenishorder`'s 61,071 / 624-open figures are `count(*)`-derived, so they are unaffected by the stats-staleness issue. H4 remains high but its *nature* is corrected (stale stats, not bloat). Exact millisecond wins are estimated, not measured, because the MCP blocks `EXPLAIN ANALYZE`.

---

## 8. Recommendation

- [x] **Fix now** — draft via `wms-bugfix-plan` (v1/wms-api). Ship a Flyway migration `V1.1.0x__` and a `sbdocs/9-System/scripts/verify-<plan-id>.sh` per that skill's Verification-script section.

Ordered actions:

1. **Replace the proposed index with the broader partial index (highest code-side leverage):**
   ```sql
   CREATE INDEX CONCURRENTLY idx_replenishorder_open_state
   ON replenishorder (state)
   WHERE state < 700;
   ```
   624-row index; serves every `state`-predicate phase, subsumes the proposed index. (`CREATE INDEX CONCURRENTLY` cannot run in a txn and briefly waits on in-flight writes — run off-peak; note Flyway needs this migration marked to run outside a transaction.)

2. **Refresh statistics + ensure autovacuum keeps up (broad win — corrected; DBA/ops, not code):** the one-time `VACUUM (ANALYZE) …` on the five tables **already ran at 2026-07-01 13:39 UTC** and fixed the stale stats (live-row estimates now correct). Remaining work is *verification*, not a re-run:
   - Autovacuum is already `on` (`track_counts=on`, no per-table disable, stock thresholds) — do **not** "restart" it; a manual VACUUM does not start/enable the daemon.
   - `last_autovacuum` was NULL on all five tables for the 25 days since the 2026-06-06 stat reset, so autovacuum has never *completed* on them. Set `log_autovacuum_min_duration = 0` + `SELECT pg_reload_conf();`, then monitor `last_autovacuum` / `n_dead_tup` as churn resumes. If it stays NULL while dead tuples climb, chase worker cancellation (the every-minute cron holds locks on these tables) or launcher/resource starvation across tenant DBs.
   - Optionally lower per-table `autovacuum_analyze_scale_factor` on the large churny tables so ANALYZE fires sooner.

3. **Honor the recalculation cadence from the cron path (cheap, correctness-neutral):** change `ReplenishOrderJob.java:93` `recalculateOpenOrders(true)` → `recalculateOpenOrders(false)` (or otherwise let `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` gate the scheduled invocation) so the full recalc doesn't run on every one-minute tick.

4. **Fix later / track:** archive or purge terminal (`state >= 700`) `replenishorder` rows (99% of the 61K table). Note `customerorder` (~479K), `customerorder_position` (~1.7M), and `stockunit` (~1.9M) are large but *not* bloated (dead tuples ~0 post-vacuum), so they need retention/archival planning, not vacuuming. The partial index makes the `replenishorder` cleanup non-urgent.

---

## 9. Open Questions

- **Cross-tenant comparison:** only `wms1-wineco` was inspected. The "WineCo is slowest" claim rests on it having the deepest history (inference); confirm by comparing `replenishorder` row counts and job timings across other tenants' DBs.
- **Actual timings:** MCP blocks `EXPLAIN ANALYZE`, so wins are estimated. A DBA should capture `EXPLAIN (ANALYZE, BUFFERS)` before/after the index and `VACUUM ANALYZE` to quantify.
- **Autovacuum root cause:** it is *enabled* (not disabled, not per-table-off, defaults not starved on paper), yet `last_autovacuum` stayed NULL for 25 days post-cutover. Why has it never completed on these tables? Prime suspect: workers repeatedly canceled by lock conflicts from the every-minute cron. Needs `log_autovacuum_min_duration=0` logging to confirm.
- **`app.cron=true` singleton:** is WineCo's cron container the only one running these jobs, or could two instances double-run (no JVM RUNNING guard in v1 per `wms1-scheduled-jobs-catalog.md:114`)? Out of scope here but worth confirming.

---

## 10. References

- **Related reports:** `[[260601-wineco-replenishment-pickpack-source-and-order-count]]`
- **Architecture:** `[[wms1-scheduled-jobs-catalog]]` (§3.2 `ReplenishOrderJob`, cadence)
- **Code:** `schedulejob/ReplenishOrderJob.java` (`doCalculation`, L93), `service/ReplenishmentOrderMaintenanceService.java` (cadence), `service/ReplenishorderService.java:250-271`, `repo/jpa/ReplenishorderRepository.java`, `repo/jpa/ItemdataRepository.java:66-104`
- **Downstream plan:** `[[260701-wineco-replenishment-job-index-and-cadence]]` (v1 bugfix plan, ships `verify-260701-wineco-replenishment-job-index-and-cadence.sh`).
- **Queries preserved:** all counts/plans in §5 from live `wms1-wineco` MCP, read-only, 2026-07-01.

---

## 11. Verification Log

| Date | Who | Check | Result |
|---|---|---|---|
| 2026-07-01 | Nam Park | Live read-only inspection of `wms1-wineco` (counts, indexes, `pg_stat_user_tables`, `EXPLAIN`) | Evidence in §5 confirmed; no index created |
