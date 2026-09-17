---
title: Freeing the 63 stranded units on T-0002 and T-0007 (Hydra PRD)
ticket: "SBDEV-3316 / SBDEV-3326"
status: Phase A PASSED 2026-09-11 21:08Z — BLOCKER CLEARED 2026-09-15, Phases B-D are RUNNABLE NOW
last_verified: 2026-09-16
applies_to: Hydra PRD (wh01_hydra_v2) · rehearsal on WineCo DEV (dev_wh01_om1)
---

# Freeing the 63 units on `T-0002` and `T-0007`

## ✅ UNBLOCKED — re-verified 2026-09-16

**The release landed on 2026-09-15. Phases B–D can be run now.** The section below is kept as the
historical record of why this sat for weeks; every claim in it was true on 2026-09-11 and is false today.

Re-measured 2026-09-16:

| | 2026-09-11 | **2026-09-16** |
| --- | --- | --- |
| Hydra PRD running build | `0.0.25` | **`0.0.26`**, `drift=false` |
| SBDEV-3316's commits on `origin/main` | No | **Yes** — `577eb830`, `d2ed6a48`, `1be9db0e` all ancestors of `origin/main` |
| SBDEV-3264 / SBDEV-3316 ClickUp status | Open / on qa | **both `on prod`** |
| Hydra PRD Flyway head | `V2.2.25` | **`V2.2.30`**, installed 2026-09-15 18:49 |
| `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` | pointed at `api-oms-uat` | **`https://api-oms.sbo.li/...`** — correct |

### Pre-flight re-run 2026-09-16 — ALL SEVEN ROWS STILL RESOLVE, GO

Every abort condition checked again today; nothing has drifted since 2026-09-11.

| log | tote | dest bin | qty | candidates | resolves to | lock |
|---|---|---|---|---|---|---|
| 1 | `T-0002` | `1V8L1C2` | 24 | 1 | 60941 | 100 |
| 2 | `T-0002` | `1V8L1C4` | 12 | 1 | 60947 | 100 |
| 3 | `T-0002` | `1FBZL4C1` | 12 | 1 | 60952 | 100 |
| 4 | `T-0002` | `1FBZL3C6` | 12 | 1 | 60957 | 100 |
| 8 | `T-0007` | `1V4L1C1` | 1 | 1 | 159982 | 100 |
| 9 | `T-0007` | `1V4L1C3` | 1 | 1 | 160025 | 100 |
| 10 | `T-0007` | `1V4L1C7` | 1 | 1 | 160050 | 100 |

`candidates = 1` on every row (0 would mean the stock is gone; >1 means the choice is undetermined —
either aborts). Stock amounts match `amount_picked` exactly on all seven. Same stock-unit ids as the
2026-09-11 measurement, so nothing has been consumed in the interim.

Environment checks, same run:

| check | value |
|---|---|
| running PRD build | **0.0.26**, `drift=false` (was 0.0.25) |
| Flyway head | **V2.2.30** — matches `origin/main` |
| FK on `picktounitload_id` | **present** — `fk_cancel_log_picktounitload` |
| all 7 destination bins exist | **yes**, 1 row each |
| `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` | **`https://api-oms.sbo.li/...`** — prod OMS, not UAT |

⚠️ **This is an operator workflow, not a script.** There is no SQL to run. The fix works by
`completeReversal` re-resolving `picktostockunit_id` at completion time and then moving the stock;
doing it by hand in SQL would stamp the rows without moving anything, which is the exact defect
SBDEV-3316 fixed.

**So the 63 units are now blocked on ATTENTION, not on a release.** Nobody has run a reversal since
the deploy: `customerorder_cancellation_log` on Hydra PRD still reads 16 rows / 7 `reversal_required`
/ **0 ever initiated / 0 ever completed**, oldest 1128.7 h = **47.0 days**.

⚠️ **`picktostockunit_id` is still NULL on all 16 rows, and that is EXPECTED — do not read it as the
fix having failed.** Per SBDEV-3316's H-2 review fix, `completeReversal` re-resolves the stock unit at
completion time and persists what it finds, so the rows heal on first use. The backfill in
`sbdev-3316-rts-backfill-and-sysprop.md` Step 1 remains optional. Run its Step 0 pre-flight first
(measured 2026-09-11: 7 rows, `candidates = 1` on every one).

<details>
<summary>Historical — why this was blocked, as written 2026-09-11 (every claim below is now false)</summary>

**The fixes are on `develop`. Hydra PRD runs `main`.** Measured 2026-09-11:

| | |
| --- | --- |
| Hydra PRD running build | **`0.0.25`** (`GET https://wms-api.sbo.li/api/public/version`) |
| `wms2-api` `main` | `1d5c8bef` — **`develop` is 50 commits ahead** |
| `wms2-mobile-ui` `main` | `abffcee` — **`develop` is 11 commits ahead** |
| SBDEV-3316 / 3319 / 3326 / 3264 on `main`? | **No. None of them.** |

So on production today: the reversal still resolves nothing, still cannot move locked stock, and the
mobile action bar is still off-viewport. **Attempting the operator steps on PRD right now will fail**,
and per SBDEV-3316 it will fail *loudly* rather than silently — which is the improvement, but it does
not move stock.

Releases to `main` are DevOps' to cut. This runbook cannot skip that.

</details>

## The target state

Seven rows, two totes, two orders. Re-verified 2026-09-11 — nothing has changed since 31 July:

| log | tote | order | CO position | destination bin | qty | stock unit | lock | currently at |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | T-0002 | 60861 | 60864 | `1V8L1C2` | 24 | 60941 | 100 | FinishedPicking |
| 2 | T-0002 | 60861 | 60863 | `1V8L1C4` | 12 | 60947 | 100 | FinishedPicking |
| 3 | T-0002 | 60861 | 60865 | `1FBZL4C1` | 12 | 60952 | 100 | FinishedPicking |
| 4 | T-0002 | 60861 | 60862 | `1FBZL3C6` | 12 | 60957 | 100 | FinishedPicking |
| 8 | T-0007 | 159907 | 159909 | `1V4L1C1` | 1 | 159982 | 100 | FinishedPicking |
| 9 | T-0007 | 159907 | 159910 | `1V4L1C3` | 1 | 160025 | 100 | FinishedPicking |
| 10 | T-0007 | 159907 | 159908 | `1V4L1C7` | 1 | 160050 | 100 | FinishedPicking |

`picktostockunit_id` is NULL on all seven; `reversal_initiated_at` and `reversal_completed_at` are
NULL on all seven. **60 + 3 = 63 units.**

⚠️ **No backfill is required.** SBDEV-3316 re-resolves `picktostockunit_id` at completion time, so
the application repairs these rows itself on first use. The backfill SQL in
`sbdev-3316-rts-backfill-and-sysprop.md` is a fallback, not a prerequisite.

---

# Phase A — prove it on DEV ✅ PASSED 2026-09-11 21:08 UTC

> **Result.** Run by `panderson` against build `develop-1d87198d`, on log id 5 / tote `T-2176`.
> `picktostockunit_id` NULL → **29855325**; the 3 units moved from `FinishedPicking` to
> **`TCOMPANY-01`** (stock unit 66350, `entity_lock = 0`, `modified` 21:08:09.563 — the same instant
> as the completion); tote `T-2176` now holds **0 stock units and sits in `EmptyTotes`**;
> `ORDER_BATCH_REVERSAL_COMPLETED` **SENT**. Control: 586 other stock units on the tenant remain at
> lock 100, so only what moved was cleared.
>
> ⚠️ **Two traps this run exposed, both of which would mislead the next person.**
>
> 1. `HTTP 200` and `reversal_completed_at` came back looking identical to the broken May behaviour.
>    They are not evidence. **Assert the location.**
> 2. After a successful reversal, joining the log's `picktostockunit_id` shows `amount = 0`,
>    `entity_lock = 2` (`GOING_TO_DELETE`), location `Nirwana`. That is the **emptied source husk**
>    being retired — `transferStock` merges the units into the existing bin stock unit rather than
>    relocating the source row. Verifying by that join alone reads as a failure. **Query the
>    destination bin**, as Phase D does.

# Phase A — the procedure (kept for re-running)

Dev already runs the fixed build, and it has a **row of exactly the same shape**.

## A1. Confirm the dev build

```bash
curl -s https://wms-api.dev.sbo.li/api/public/version
# expect version: develop-1d87198d… or later
```

## A2. The rehearsal subject — WineCo DEV, `dev_wh01_om1`

Cancellation log **id 5**, tote **`T-2176`**, customer order **29855310**, destination
**`TCOMPANY-01`**, 3 units, stock unit **29855325** at `entity_lock = 100`,
`picktostockunit_id` NULL, `reversal_completed_at` NULL.

Same shape as the seven PRD rows: unresolved column, locked stock, never initiated.

⚠️ Rows 1–4 on that tenant are the **historical no-ops** — completed 2026-05-28/29, the day
SBDEV-1921 merged, stamped successful while moving nothing. Leave them alone; they are the evidence
of the original defect. Note rows 2, 3 and 4 still have stock sitting on their totes at lock 100 —
that is what a "successful" reversal used to look like.

## A3. Before

```sql
SELECT l.id, l.tote_label_id, l.pickfromlocationname, l.picktostockunit_id,
       l.reversal_initiated_at, l.reversal_completed_at,
       s.id AS stockunit, s.entity_lock, s.amount, loc.name AS stock_is_at
FROM customerorder_cancellation_log l
JOIN pickingorder_unitload pu ON pu.id = l.picktounitload_id
JOIN stockunit s ON s.unitload_id = pu.unitload_id
JOIN unitload u ON u.id = s.unitload_id
LEFT JOIN location loc ON loc.id = u.storagelocation_id
WHERE l.id = 5;
```

Record `stock_is_at` and `entity_lock`. **These two are the test.**

## A4. Run it on the dev mobile UI

`https://wsl-wineco.wms.dev.sbo.li/mobile` → **Cancellation**:

1. **Scan Tote** `T-2176`, or **View List** and pick order 29855310.
2. Detail screen → **Start Reversal**. (Pre-fix this button was off-viewport; if you cannot see it,
   the UI build is older than the fix — check before blaming anything else.)
3. Action screen → tick **every** position. The Complete button gates on all of them: a partial
   reversal is structurally unreachable (SBDEV-3323).
4. **Complete Reversal.**

## A5. After — the assertion that matters

```sql
-- rerun A3's query.
```

**Pass:** `stock_is_at` = `TCOMPANY-01`, `entity_lock` = 0, `picktostockunit_id` populated,
`reversal_completed_at` set.

⚠️ **`reversal_completed_at` alone is NOT a pass.** That column was stamped four times on this very
tenant in May while nothing moved. **Read the location.** If the stamp is set and the stock is still
on the tote, stop and report — that is the original defect resurfacing.

**If it refuses:** read the message. `"Source stockUnit=… is locked=…"` naming a state other than
`Picked` means a different lock is in play and the refusal is correct. A refusal naming
`picktounitload_id` means the hop could not resolve — capture it, that is new.

---

# Phase B — promote to production

DevOps' call and DevOps' action. What has to reach `main`:

| repo | commits needed | why it is needed |
| --- | --- | --- |
| `wms2-api` | SBDEV-3316 (`577eb830`, `d2ed6a48`), SBDEV-3326, SBDEV-3319 | resolve the stock unit · clear the lock · stop picking cancelled work |
| `wms2-mobile-ui` | SBDEV-3264 (`776edff`), SBDEV-3316 H-1 (`08f2370`), SBDEV-3319 | make the action bar reachable · surface the refusal message |

⚠️ **`develop` is 50 commits ahead on the API and 11 ahead on mobile.** A release carries *all* of
it, not just these. Sizing that is a DevOps + Nam decision, not this runbook's.

⚠️ **A Flyway migration ships with it** — `V2.2.28`, the FK on
`customerorder_cancellation_log.picktounitload_id`. Precondition verified on six tenant databases
(0 rows would violate, each zero with a positive control). It runs on first boot of the new build.
If a tenant stalls, the query to run is in that migration's header.

## B1. After the production deploy, before touching the totes

```bash
curl -s https://wms-api.sbo.li/api/public/version    # must no longer be 0.0.25
```

```sql
-- Flyway reached V2.2.28 on this tenant
SELECT version, script, success, installed_on
FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 3;

-- and the constraint actually exists (the migration is guarded, so "success" can mean "skipped")
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'public.customerorder_cancellation_log'::regclass;
```

---

# Phase C — free the units on PRD

Mobile UI: `https://nywh-hydra.wms.sbo.li/mobile` → **Cancellation**.

**Do `T-0007` first.** 3 units against 60, three positions against four, and it is the tote from the
customer escalation (ST#1181, SBDEV-3264). Smallest blast radius, highest visibility.

## C1. `T-0007` — order 159907, 3 positions, 3 units

1. Scan Tote `T-0007` (or View List → order 159907).
2. **Start Reversal.**
3. Tick all three positions — `1V4L1C1`, `1V4L1C3`, `1V4L1C7`.
4. **Complete Reversal.**
5. **Verify before continuing** (Phase D query). Do not proceed to `T-0002` until `T-0007` is proven.

## C2. `T-0002` — order 60861, 4 positions, 60 units

Same sequence. Destinations `1V8L1C2` (24), `1V8L1C4` (12), `1FBZL4C1` (12), `1FBZL3C6` (12).

⚠️ This tote has been stranded since **2026-07-31**. Confirm physically that the goods are still on
it before completing — the system's belief is 41 days old.

---

# Phase D — verify the units actually moved

```sql
SELECT l.id, l.tote_label_id, l.pickfromlocationname AS expected_bin,
       l.amount_picked, l.reversal_completed_at,
       s.id AS stockunit, s.entity_lock, s.amount,
       loc.name AS stock_is_now_at,
       (loc.name = l.pickfromlocationname) AS at_the_right_bin
FROM customerorder_cancellation_log l
JOIN stockunit s ON s.id = l.picktostockunit_id
JOIN unitload u ON u.id = s.unitload_id
LEFT JOIN location loc ON loc.id = u.storagelocation_id
WHERE l.id IN (1,2,3,4,8,9,10)
ORDER BY l.id;
```

**Done means:** `at_the_right_bin` true on all seven · `entity_lock` 0 on all seven · 63 units
accounted for.

```sql
-- the totes are free
SELECT u.labelid, count(s.id) AS stock_units_still_on_it
FROM unitload u LEFT JOIN stockunit s ON s.unitload_id = u.id
WHERE u.id IN (17662, 37736) GROUP BY u.labelid;
```

Expect **0** on both. That is `T-0002` and `T-0007` back in a fleet of 8.

## D1. Then check OMS actually heard

```sql
SELECT process, destination, status, statuscodeanswer, created
FROM message WHERE process = 'ORDER_BATCH_REVERSAL_COMPLETED' ORDER BY created DESC;
```

The sysprop now points at `api-oms.sbo.li` (fixed and verified 2026-09-11 — four
`ORDER_BATCH_PALLETIZED` calls got HTTP 200 that afternoon, the first ever). So expect a **2xx**.

⚠️ **Never read `status = SENT` as delivery.** 189 rows on this tenant are `SENT` beside a `404`.
Join `destination` and `statuscodeanswer`, always.

---

# If it goes wrong

| symptom | meaning | action |
| --- | --- | --- |
| `"Source stockUnit=… is locked=Picked"` | the lock clear did not reach the DB | build is older than SBDEV-3326 — check `/api/public/version` |
| `"…is locked=<other state>"` | a different lock — `Quality Fault`, `On Hold`, … | correct refusal. Resolve that state first; do not force it |
| `"no source stock unit could be resolved"` | the hop failed — the tote was unlinked before the log was written | **not recoverable from the screen.** Capture `picktounitload_id` and raise it |
| Stamp set, stock still on the tote | the original defect | **stop immediately.** Do not run the second tote |
| Complete button absent | UI older than SBDEV-3264 | check the deployed mobile build |
| Tote ends up standing in a pick bin | SBDEV-3340 — whole-unit-load route | not reachable on Hydra (all 7 destinations are flow bins). If it happens, that assumption was wrong |

**Nothing here needs a database write.** If you find yourself reaching for `UPDATE`, stop — the
application repairs these rows itself, and a manual write will mask whatever actually failed.
