---
ticket: "SBDEV-3685"
ticket_url: "https://app.clickup.com/t/868merd11"
kind: evidence
created: 2026-10-13
status: reviewed — critic round 1 (H1 M3 L5) and round 2 (ACCEPT-WITH-RESERVATIONS; N1–N4) applied; see review-critic.md
---

# SBDEV-3685 — what reads `stockunit` / `unitload` on WineCo PRD

**This does not satisfy gate (a).** `pg_stat_statements` is still not installed on WineCo PRD (PG 14.23;
`pg_extension` count 0 on 2026-10-13). The gate also names c1wh-shipitez, which is untouched here. This is the
option-A sampling: one tenant, one day (Monday 2026-10-12, US Columbus Day). It is input to the re-plan, not a
replacement for it.

There are **two read-volume axes**, and the ticket text names only the first:

| table | seq_tup_read since 2026-09-25 | idx_tup_fetch since 2026-09-25 |
|---|---|---|
| stockunit | 19.2 B | 1.4 B |
| unitload | 8.3 B | **96.0 B** |

`pg_stat_user_tables` at 2026-10-13T19:42Z; `stats_reset` is 2026-09-25T02:24Z, the same base as the ticket's figures.
For unitload, index fetches are 11.6× its seq reads. The ticket's line "dominant read volume … is seq scans" holds for
stockunit and is **false for unitload**.

## Method

1. **Active-statement sampler.** `.omc/research/SBDEV-3685/sampler.sh` polls `pg_stat_activity` (this DB) every ~2 s, from
   2026-10-12T12:55:59Z to 20:59:58Z: 12,602 ticks and 2,668 rows, with 3 connect timeouts. All rows are role
   `wh01_om1_v2_app` from `172.18.0.1`. **This includes our own DB-MCP probes** (`/* crystaldba */`, same role and IP),
   so app traffic and investigation traffic can be told apart only by that comment. Parallel workers appear as extra rows
   with the leader's text and an empty `client_addr`. Counts below are **leaders only** unless stated.
2. **Cumulative counters.** `seq_scan` / `seq_tup_read` for both tables, every tick. The sampler did **not** log
   `idx_tup_fetch`, so the index axis is not lined up per statement. That is a gap (see Next).
3. **EXPLAIN** (estimate only, no ANALYZE) on PRD. Source code is read at **`origin/main`** for the release job, since PRD
   runs the main line, and at `origin/develop` `a4fd6490` elsewhere (flagged where it matters).

Scripts: `a1.py` (rank), `a2.py` (lift, window i-1..i+2), `a3.py` (attribution, window i-3..i+2). The reviewer's
window, permutation and recount scripts (`b1.py`, `b2.py`) are described in `review-critic.md`.

## Finding 1 — the release-job prefetch is the #1 statement by active time, and it is the whole-warehouse version on PRD

- `select … from Unitload where storagelocation_id in (…)` has **1,686 of 2,668 samples (63%)**. It was active in 13.4% of
  ticks, in 414 of ~484 minutes, with a median elapsed time of 0.29 s. That is about 6.5× the leader-only sampled active time
  of all the screens in Finding 2 combined.
- **PR-A is not on PRD.** `origin/main` carries `07afea75 Hold SBDEV-3678 out of SiteBoss OWL v2.0.151 (revert #473)`.
  On main, `service/job/ReleaseOrderJobService.java` `:266` loops `for (Object[] fixArr : itemDataFixAssignmentMap.values())`,
  which is every fix assignment in the warehouse, and `:307` calls `unitloadRepository.findByStoragelocationIdIn(allLocationIds)`.
- **The list size.** Every sample shows exactly 171 placeholders, and **all 1,686 are truncated**. That is the sampler's
  `left(…,1500)`, not the list length. The reviewer reproduced the location set on PRD: **~1,555 ids, including Nirwana
  (`location.id = 0`)**, because 3 fix assignments point at a UL now in Nirwana. Unit loads on those locations: **372,786**.
  EXPLAIN with id 0 in the list gives `Index Scan on unitload [Rows: 371331]`. 382 of the 1,686 samples (23%) are in
  wait `Client:ClientWrite`, meaning the backend was blocked pushing a large result to the JVM.
- **Plan-flip risk.** If **Shipped (51611)** enters the list, EXPLAIN flips to `Seq Scan on unitload [Rows: 865156]`. That
  happens as soon as any FLA's `assignedunitload_id` points at a shipped UL. Stale FLAs already exist (the 3 pointing at
  Nirwana).
- **Tie-in to the index axis** (inference, medium confidence). Mean duration ~0.6 s gives a catch probability of ≈0.26,
  so ≈6,500 executions in 8 h (~13/min). At ~372 k rows each, that is ≈4.8 M unit-load fetches/min. The reviewer measured
  +1.13 M `idx_tup_fetch` in 15 s (≈4.5 M/min) with `seq_tup_read` +0, and the 18-day average is ≈3.6 M/min. Same order of
  magnitude. It is not proven: the monitor's nested loops also fetch by index.
- It is **not** a seq-scan source in this window: lift ×1.0 (stockunit) and ×0.9 (unitload).

## Finding 2 — three screens account for ~75–89% of the seq scans

Increment ≈ one participant of a scan. With `max_parallel_workers_per_gather = 4`, a full parallel stockunit read shows as
+4 or +5 and ≈1.97 M tuples (e.g. 18:38:20 +4 / 1,970,209). In full-table equivalents, the window holds 622.5 M / 1.97 M ≈
**316 full stockunit reads** and 258.4 M / 0.88 M ≈ **293 full unitload reads** (~0.65/min each).

| screen (leaders only) | samples | median s (leaders) | executions | su / ul increments attributed (i-3..i+2) |
|---|---|---|---|---|
| Replenishment Monitor, `ReplenishmentMonitorViewRepository.getReplenishViewSummary` | 110 | 2.11 | **56** | 295 / 299 |
| Warehouse Location report, `view_warehouse_location_report` (`ReportService` `findByClientNameOffsetAndLimit`) | 119 | 0.83 | 86 | 162 / 162 |
| Stock-unit keyword search, `StockunitRepository` `CONCAT(LOWER(u.labelid) …) LIKE` | 8 | 0.08 | 8 | 81 / 40 |
| `stockrecord_view` keyword search | 23 | 2.94 | 8 | 5 / 13 |
| unattributed | | | | 118 / 62 |

The monitor's 295 increments over 56 runs ≈ **5.3 per run**. That matches EXPLAIN: one serial scan (the t5 fix-assignment
arm) plus one parallel scan (the t3 arm; leader + 4 workers).

**The attribution is robust** (reviewer, `review-critic.md` L1). Share of stockunit / unitload increments with a candidate:

| window | share of ticks covered | attributed |
|---|---|---|
| i-3..i+2 | 5.6% | 81.3% / 88.6% |
| i-1..i+1 | 3.5% | 79.7% / 86.5% |
| same tick only | 1.8% | **74.5% / 82.5%** |

Permutation null for stockunit, 500 draws: circular shift has max 14.6%, and a local ±20 s–5 min shift (which keeps
hour-of-day burstiness) has max 18.2%. The ×23 lift in `a2.py` is a ceiling (both screens hit 100%, so lift = 1/base), not
a magnitude.

**EXPLAIN on PRD:**
- Monitor: serial `Seq Scan on stockunit` + `Seq Scan on unitload` (t5), and a parallel second pair under `Gather Merge`
  (t3). The top-level 11.97 M-row Sort estimate comes from t5 misestimating unit loads on fix locations (466 k estimated
  vs 1,548 actual). Check it with ANALYZE off-peak before relying on it.
- Location report, for the EXPLAINed keyword shape: `Seq Scan on stockunit` (2.01 M) + `Seq Scan on unitload` (880 k).
  `location.name <> ALL('{Nirwana,Shipped}')` is applied only after both scans, and `LIKE '%…%'` over concatenated
  `lower()` cannot use an index.

**Callers** (`origin/develop`; PRD's UIs run main, which is not checked). The monitor is
`GET /dashboard/replenishMonitorViewSummary` (`DashboardController`). On web-ui it fires on every `/dashboard` mount
(`pages/dashboard/index.vue` → `replenishViewTable.vue:240` → `store/dashboard/replenishMonitor.js:33`). On mobile,
`pages/replenish.vue:233` (Critical tab) and `:253` (All tab, alongside `/replenishOrder/detailView`) call it. No
`setInterval` polls it in either UI. A recursive `setTimeout` poll was not ruled out by that grep.

**Unattributed increments (118 / 62).** They are **full-table** reads: the counters cover only these two tables, so a
"small table" explanation is impossible. They are fast (<2 s) 4-participant parallel scans repeating every ~6 s in bursts at
13:31–13:34, 17:44–17:47 and 18:38–18:39, plus singles at 13:51, 14:19, 14:54, 15:14 and 17:33. Origin is unknown. They
could be ad-hoc or MCP sessions; our own `crystaldba` probes ran at 17:34, 18:03–18:05, 18:25 and 18:31.

**No cron signature in the seq scans.** The case rests on three things together:
1. Every cron-shaped statement has a low lift (release prefetch ×1.0, replenish 6b `max(prio)` ×1.4).
2. Unattributed increments do not cluster by second-of-minute (5-second buckets 12/24/15/6/15/9/5/3/4/13/1/11 for stockunit).
3. The quietest hour (19h UTC) had only 15 increments, which rules out an unconditional per-minute scan.

Item 3 alone would not exclude a conditional one.

## Finding 3 — 99.3% of what the full scans read is dead stock

```
location in (Shipped, Nirwana)   stockunits 1,960,886   unitloads 477,799
anything else                    stockunits    14,105   unitloads  13,355
```
Unit loads by location: Shipped 495,977 · Nirwana 371,235 · PutAwayLane 2,229 · TC-OS 2,138. The monitor and the location
report each read ~2 M stock units to use ~14 k. The release prefetch (Finding 1) reads ~370 k Nirwana unit loads per call
for the same reason.

## What this means for the ticket (inference, for Nam)

Ranked by evidence × cost:

1. **Re-land SBDEV-3678 PR-A on the release line.** It is already written, reviewed and merged to develop. It narrows the
   whole-warehouse prefetch, which is the #1 statement by active time and the leading candidate for the 96 B unit-load index
   fetches. It is a release decision (devops), but **gated on the validation `07afea75` names as missing**: handheld
   multi-UL confirm and high load. PR-A does **not** remove the Nirwana path by construction. Today it avoids it only
   because the 3 stale-FLA items have 0 open orders.
2. **Query unit loads by the fix assignments' *assigned* locations only.** On main, `allLocationIds` mixes assigned
   locations with each assigned UL's *current* location, which is how Nirwana gets in. `unitloadsByLocationMap` is read
   only by `assignedLocation.getId()` (`ReleaseOrderJobService` on main, `getOrDefault(assignedLocation.getId()`), so
   `findByStoragelocationIdIn` needs just the assigned-location set. **Do not** simply drop Shipped/Nirwana from
   `allLocationIds`: `locationMap` is built from the same set, and `locationMapFinal.get(unitload.getStoragelocationId())`
   would then throw `EntityNotFoundException` for the stale-FLA items, where today they hold at 57. This is a small,
   contained change (tier per `wms-triage`, likely T1). It removes the Nirwana rows and the Shipped plan flip whether or not
   PR-A lands.
3. **Make the monitor and the location report skip Shipped/Nirwana before scanning.** Drive from `location` →
   `index_unitload_storagelocation_id` → `index_stockunit_unitload_id` (both exist on PRD), and restrict monitor t2/t3 to
   t1's SKUs. These two screens are 84–91% of the seq-scan **tuples** in the window. The four screen classes together are
   75–89% of the scan **increments**.
4. **Retire Shipped/Nirwana stock units from the hot tables.** This is the largest lever and a data-retention decision
   (T3, propose only).
5. The ticket's change-driven-cron items stand as **correctness and cost** items (R1–R5, 9b, 11). This window says nothing
   about whether they are the load case, except that the release prefetch (which PR-A, not this ticket, fixes) is.

Before/after metrics for any of these: `idx_tup_fetch` per minute on unitload (the gate's seq-scan metric cannot see item 1
or item 2), plus `seq_tup_read` per minute on both tables.

## Next

- Install `pg_stat_statements` (gate (a), both tenants). Until then:
- Re-run the sampler with `idx_tup_fetch`, `application_name`, `backend_type` and `leader_pid` logged, and `crystaldba`
  rows excluded. A 10-minute `idx_tup_fetch` delta alongside release-prefetch activity would settle Finding 1's tie-in.
- Count held orders evaluated per release tick on PRD. That is the multiplier on the ~372 k-row prefetch.

## Blind spots

1. 2 s sampling under-sees short statements; `pg_stat_statements` closes this.
2. PG 14 reports table stats at transaction end (rate-limited ~500 ms). A same-tick attribution still holds 74.5%.
3. The monitor SQL is from `origin/develop`. The sampled prefix matches the SBDEV-3120 shape, but text is truncated at 1,500 chars.
4. One holiday day. The stockunit seq rate (~1.3 increments/min) was half of 2026-10-07's.
5. "Executions" are runs of consecutive leader samples on one pid. Back-to-back calls on one pooled connection merge.
