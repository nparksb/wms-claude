---
title: SBDEV-3316 — RTS backfill (OPTIONAL) and reversal-sysprop correction (REQUIRED)
ticket: "SBDEV-3316"
status: step 3 required — NOT YET RUN; steps 0-2 are now optional
last_verified: 2026-09-11
applies_to: Hydra PRD (wh01_hydra_v2), WineCo DEV (dev_wh01_om1)
---

# SBDEV-3316 — backfill (optional) + sysprop correction (required)

> ⚠️ **Read this first — the backfill is no longer required.** The review pass (H-2) showed that a
> code-only fix would leave the 8 rows that exist today permanently un-completable, because
> `cancellationAction.vue` sends **every** position on the order and gates Complete on all of them, so
> one unresolvable row condemns the whole order. The fix now **re-resolves `picktostockunit_id` at
> completion time** from the same implementation the record path uses, and persists what it finds.
> Every pending row on PRD resolves today, so the application heals its own data on the first
> completion and **no production write is needed to unblock the two stuck orders.**
>
> Steps 0–2 below are kept as a **pre-flight and a fallback**: run Step 0 to confirm the rows are
> still resolvable before an operator tries, and Step 1 only if you want the rows repaired ahead of
> time rather than on first use. **Step 3 (the sysprop) is still required** — the code cannot fix it.

**Nothing in this file has been executed.** Everything is a write against a live database bar the
read-only probes; run it deliberately, in order, with the pre-flight and post-check queries.

Related: SBDEV-3264 owns the CSS defect that currently makes the completion screen unreachable. That
defect is the only reason this has never fired on production — **do not ship 3264 before this.**

---

## Step 0 — pre-flight (read-only, must all hold) — RUN THIS EVEN IF YOU SKIP STEP 1

```sql
-- 0a. The rows to repair. Expect 7 on Hydra PRD, each with candidates = 1.
WITH target AS (
  SELECT l.id AS log_id, l.customerorder_position_id, l.picktounitload_id, pu.unitload_id,
         (SELECT pp.itemdata_id FROM pickingorder_position pp
           WHERE pp.customerorderposition_id = l.customerorder_position_id
           ORDER BY pp.id LIMIT 1) AS itemdata_id
  FROM customerorder_cancellation_log l
  JOIN pickingorder_unitload pu ON pu.id = l.picktounitload_id
  WHERE l.picktostockunit_id IS NULL
    AND l.picktounitload_id IS NOT NULL
    AND l.reversal_required
)
SELECT t.log_id, t.picktounitload_id, t.unitload_id, t.itemdata_id,
       (SELECT count(*) FROM stockunit s
         WHERE s.unitload_id = t.unitload_id AND s.itemdata_id = t.itemdata_id) AS candidates,
       (SELECT s.id FROM stockunit s
         WHERE s.unitload_id = t.unitload_id AND s.itemdata_id = t.itemdata_id
         ORDER BY s.id LIMIT 1) AS would_set
FROM target t ORDER BY t.log_id;
```

**Abort if any row reports `candidates = 0` or `candidates > 1`.** Zero means the stock unit has since
been consumed and the goods are no longer where the log says; more than one means the tote held two
stock units of the same SKU and the choice is not determined — resolve it with the warehouse, do not
pick one. Measured 2026-09-11 on Hydra PRD: 7 rows, `candidates = 1` on every one, targets
`60941, 60947, 60952, 60957, 159982, 160025, 160050`.

```sql
-- 0b. Destination bins must be able to accept the stock. transferStock() throws — surfaced as
--     HTTP 409 "Source location unavailable" — when the bin is full or holds a different SKU.
WITH target AS (
  SELECT l.id AS log_id, l.tote_label_id, l.pickfromlocationname, l.amount_picked,
         (SELECT pp.itemdata_id FROM pickingorder_position pp
           WHERE pp.customerorderposition_id = l.customerorder_position_id
           ORDER BY pp.id LIMIT 1) AS itemdata_id
  FROM customerorder_cancellation_log l
  WHERE l.picktostockunit_id IS NULL AND l.picktounitload_id IS NOT NULL AND l.reversal_required
)
SELECT t.log_id, t.tote_label_id, t.pickfromlocationname, t.amount_picked, loc.id AS location_id,
       (SELECT count(*) FROM stockunit s JOIN unitload u ON u.id = s.unitload_id
         WHERE u.storagelocation_id = loc.id AND s.itemdata_id <> t.itemdata_id) AS foreign_sku_units,
       (SELECT count(*) FROM stockunit s JOIN unitload u ON u.id = s.unitload_id
         WHERE u.storagelocation_id = loc.id AND s.itemdata_id = t.itemdata_id) AS same_sku_units
FROM target t LEFT JOIN location loc ON loc.name = t.pickfromlocationname
ORDER BY t.log_id;
```

Measured 2026-09-11 on Hydra PRD — all seven bins exist, each holds exactly one unit load, and
**`foreign_sku_units = 0` with `same_sku_units = 1` on every row**, so each unit merges back into its
own container. No 409, and no need for the D5 rule-3 putaway fallback:

| log | tote | bin | qty | SKU |
| --- | --- | --- | --- | --- |
| 1 | T-0002 | 1V8L1C2 | 24 | 2329531 |
| 2 | T-0002 | 1V8L1C4 | 12 | 2368010 |
| 3 | T-0002 | 1FBZL4C1 | 12 | 77005441 |
| 4 | T-0002 | 1FBZL3C6 | 12 | 2368008 |
| 8 | T-0007 | 1V4L1C1 | 1 | 2858804 |
| 9 | T-0007 | 1V4L1C3 | 1 | 57399 |
| 10 | T-0007 | 1V4L1C7 | 1 | 59694 |

`location_id` values were 1009 / 1011 / 1162 / 1160 / 1126 / 1128 / 1132. Re-run 0b rather than
trusting these — bins change.

---

## Step 1 — backfill `picktostockunit_id` (OPTIONAL — the app now does this itself)

Mirrors the corrected Java exactly: hop `picktounitload_id → pickingorder_unitload.unitload_id`, then
filter `stockunit` by the **picking** position's `itemdata_id`. Wrap it in a transaction and check the
row count before committing.

```sql
BEGIN;

UPDATE customerorder_cancellation_log l
   SET picktostockunit_id = s.id
  FROM pickingorder_unitload pu,
       LATERAL (SELECT pp.itemdata_id FROM pickingorder_position pp
                 WHERE pp.customerorderposition_id = l.customerorder_position_id
                 ORDER BY pp.id LIMIT 1) AS pos,
       LATERAL (SELECT s2.id FROM stockunit s2
                 WHERE s2.unitload_id = pu.unitload_id
                   AND s2.itemdata_id = pos.itemdata_id
                 ORDER BY s2.id LIMIT 1) AS s
 WHERE pu.id = l.picktounitload_id
   AND l.picktostockunit_id IS NULL
   AND l.picktounitload_id IS NOT NULL
   AND l.reversal_required;

-- Expect exactly the count from 0a (7 on Hydra PRD). Anything else: ROLLBACK and re-run 0a.
-- Then confirm before committing:
SELECT id, picktounitload_id, picktostockunit_id
  FROM customerorder_cancellation_log
 WHERE reversal_required AND reversal_completed_at IS NULL
 ORDER BY id;

COMMIT;   -- or ROLLBACK
```

⚠️ `LIMIT 1` is safe **only because 0a proved `candidates = 1` for every row.** If you skipped 0a this
statement silently picks the lowest stock-unit id, which is a guess. Do not run Step 1 without 0a.

⚠️ It deliberately does **not** touch `version`. Nothing holds these entities in a session, and bumping
it would serve no purpose; note it so a later optimistic-lock question has an answer.

---

## Step 2 — post-check and hand-off to the warehouse

```sql
-- Should be 0 after Step 1. If you SKIPPED Step 1 this is expected to be non-zero — those rows are
-- resolved by completeReversal on first use instead. Either way, a row that cannot be resolved now
-- FAILS LOUDLY at completion rather than stamping a false success, which is the point of the change.
SELECT count(*) FROM customerorder_cancellation_log
 WHERE reversal_required AND reversal_completed_at IS NULL AND picktostockunit_id IS NULL;
```

The 7 rows are then completable from the mobile RTS screen — **once SBDEV-3264 has unblocked the
action bar.** Completing them returns 63 units (60 on `T-0002`, 3 on `T-0007`) and puts 2 of Hydra's
8 tote labels back into rotation. Verify after the operator runs it:

```sql
SELECT l.id, l.tote_label_id, l.reversal_completed_at, l.pickfromlocationname,
       u.labelid AS stockunit_now_on, loc.name AS stockunit_now_at
  FROM customerorder_cancellation_log l
  JOIN stockunit s ON s.id = l.picktostockunit_id
  JOIN unitload u ON u.id = s.unitload_id
  LEFT JOIN location loc ON loc.id = u.storagelocation_id
 WHERE l.id IN (1,2,3,4,8,9,10) ORDER BY l.id;
```

`stockunit_now_at` must equal `pickfromlocationname`. **Do not read `reversal_completed_at` as proof
the stock moved** — that column being set while nothing moved is the entire defect.

---

## Step 3 — the reversal sysprop points at the wrong OMS (REQUIRED)

`WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` on Hydra **PRD** resolves to the **UAT** OMS
(`api-oms-uat`). Latent only because no reversal has ever completed; the first success after this
backfill would notify the wrong environment. This was the last unchecked item on the SBDEV-1921
closure list, and it is the same class of defect as SBDEV-3314 (three prd sysprops pointing at UAT).

```sql
SELECT name, value FROM los_sysprop
 WHERE name LIKE 'WEBSERVICE_ORDER_BATCH_REVERSAL%' ORDER BY name;
```

Correct it to the PRD OMS host before Step 1's rows are completed. Coordinate with **SBDEV-3314** —
same root cause, and fixing them separately risks one being reverted by the other's runbook.

⚠️ Never read an outbox row's `SENT` status as delivery. Measured on Hydra PRD: 188 events received
HTTP 404 from the UAT OMS and **all** recorded `SENT`, because any 2xx-or-not response that returns
without throwing marks the row sent.
