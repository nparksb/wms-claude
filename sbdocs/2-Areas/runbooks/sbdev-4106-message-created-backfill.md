---
title: SBDEV-4106 — backfill NULL message.created on legacy v1 resend rows
type: runbook
scope: wms2-api v2 / PRD
severity: SEV3
alert: "SBDEV-4095 job log: expired rows remain (pinned by NULL-created resends)"
status: proposed
created: 2026-11-11
last_verified: 2026-11-11
verified_by: "DEV dry run (dev_wh01_om1)"
ticket: SBDEV-4106
owner: Nam Park
risk: low (58 rows, guarded, reversible until the next nightly cleanup run)
related:
  - sbdev-3332-markedforcancellation-residue-backfill.md
---

# SBDEV-4106 — backfill NULL `message.created` on legacy v1 resend rows

## Why a runbook and not code

The defect was in v1's write path: `MessageService.resendMessage` saved the resend row twice, and the second save left `created` NULL. v2 fixed that write path in SBDEV-3325 (`d324fc47`). What is left is **58 rows of legacy data on two PRD tenants**. Nam decided on 2026-11-11 to repair them with an operator one-off and **not** a Flyway migration, so that a v1 data repair does not enter the v2 schema history.

Value written: the row's own `modified`, which is when v1 actually wrote the resend (Nam, 2026-11-11). It is **not** the original's `created`. On DEV the two differ by 22–65 min, and `modified` is the later of the two, so it is the conservative choice: the row ages out slightly later.

## Prerequisite — do not run on PRD before this

**SBDEV-4095 and SBDEV-4094 must both be on prod.**

- **4095 (the move logic).** Check the code itself, not ancestry, because release cuts revert held tickets:
  `git -C v2/wms2-api show origin/main:src/main/java/net/aim_ai/wms/repo/jpa/MessageRepository.java | grep -c 'NOT EXISTS'`
  The result must be ≥ 1, and `moveExpiredToArchive` must be present. On 2026-11-11 it was `origin/develop` = 4 and `origin/main` = 0, so this is not met yet. Without 4095, the old job hits 23503 on the pinned originals.
- **4094 (the `redeliver_id` index).** `MessageRepository` says to deploy 4095 only with or after this index. Without it, each `NOT EXISTS` probe scans the whole table, and the first run over WineCo's ~214k-row backlog could take hours. On each PRD tenant, check: `SELECT indexname FROM pg_indexes WHERE tablename='message' AND indexdef ILIKE '%(redeliver_id)%';`. It must return a row.
- On each tenant, also re-check the retention setting (`CLEAN_UP_OLD_MESSAGES_PERIOD`, 365 at filing) and that there are still no user triggers on `message` (`SELECT count(*) FROM pg_trigger WHERE tgrelid='message'::regclass AND NOT tgisinternal;` must be 0).

## The population

| Tenant DB | MCP | Rows | Measured |
|---|---|---|---|
| WineCo `wh01_om1_v2` | `wsl-wineco-prd` | 51 | 2026-11-11 (filing). Not re-checked: MCP timed out |
| ShipItEz `wh01_shipitez_v2` | `c1wh-shipitez-prd` | 7 | 2026-11-11 (filing). Not re-checked: MCP timed out |
| ShipItEz `wh02_shipitez_v2` | `nywh-shipitez-prd` | 0 | re-checked 2026-11-11: 0 resends, 0 NULL `created` |
| Hydra `wh01_hydra_v2` | `nywh-hydra-prd` | 0 | 2026-11-11 (filing): its 2 resends are v2-written and have `created` |
| DEV `dev_wh01_om1` | `wms2-wineco-dev` | 3 → **0** | **done 2026-11-11** (see *DEV dry run*) |

At filing, the NULL-`created` rows on both affected tenants were *exactly* the resend rows, and every one of them had a non-NULL `modified`. The guard below re-asserts both of those facts at run time instead of trusting this table.

## Procedure — per tenant DB

Run it with **`psql -X`** against the tenant DB, as a role that has `UPDATE` on `message`. The MCPs on PRD are read-only. `-X` skips `~/.psqlrc`: an `ON_ERROR_ROLLBACK` setting there would let a refused run print `COMMIT`. Set `expected` from the table above: 51 for WineCo, 7 for ShipItEz wh01.

```sql
\set ON_ERROR_STOP on
\set expected 51
-- REPEATABLE READ: the ids file and the UPDATE see the same snapshot
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- 1. Rollback record: save the ids BEFORE writing anything, and keep the file with the ticket.
\copy (SELECT id, redeliver_id, modified FROM message WHERE created IS NULL ORDER BY id) TO 'sbdev4106-<tenant>-ids.csv' CSV HEADER

-- 2. Guarded backfill. Any mismatch raises, and ON_ERROR_STOP leaves the transaction aborted.
SELECT set_config('sbdev4106.expected', :'expected', true);
DO $$
DECLARE expected int := current_setting('sbdev4106.expected')::int; n int; u int;
BEGIN
  SELECT count(*) INTO n FROM message WHERE created IS NULL;
  IF n <> expected THEN RAISE EXCEPTION 'abort: % NULL-created rows, expected %', n, expected; END IF;
  SELECT count(*) INTO n FROM message WHERE created IS NULL AND (redeliver_id IS NULL OR modified IS NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'abort: % NULL-created rows are not resends with a modified', n; END IF;
  UPDATE message SET created = modified
   WHERE created IS NULL AND redeliver_id IS NOT NULL AND modified IS NOT NULL;
  GET DIAGNOSTICS u = ROW_COUNT;
  IF u <> expected THEN RAISE EXCEPTION 'abort: updated %, expected %', u, expected; END IF;
END $$;

-- 3. AC-3: this must return 0.
SELECT count(*) AS null_created_after FROM message WHERE created IS NULL;
COMMIT;
```

If the run **commits**, the ids file holds `expected` data lines plus 1 header line. Attach it to SBDEV-4106. If the run **aborts**, delete the file. It describes a write that never happened, and a stale copy left on disk could be mistaken for a rollback record later.

## Rollback

```sql
\set ON_ERROR_STOP on
\set expected 51
BEGIN;
SELECT set_config('sbdev4106.expected', :'expected', true);
DO $$
DECLARE expected int := current_setting('sbdev4106.expected')::int; u int;
BEGIN
  -- <ids> = the id column of sbdev4106-<tenant>-ids.csv (data lines only, not the header)
  UPDATE message SET created = NULL WHERE id IN (<ids>) AND created = modified;
  GET DIAGNOSTICS u = ROW_COUNT;
  IF u <> expected THEN RAISE EXCEPTION 'abort: reverted %, expected % (rows already moved to message_archived?)', u, expected; END IF;
END $$;
COMMIT;
```

Nothing in v2 rewrites `created` or `modified` on these rows: the only `save` creates new rows, the SDR `/message` writes are disabled, and there are no triggers. So `created = modified` still identifies the backfilled rows at rollback time.

⚠ **Rollback works only until the next `CleanUpOldMessagesJob` run, whether scheduled (nightly) or manual (`triggerArchiveMessages`).** That run **moves** every backfilled row that is older than the retention period into `message_archived`. **Rollback after the move is not supported by this runbook.** `message_archived` has no primary key and already holds duplicate ids (P87), so a copy-back would need its own reviewed procedure: `DISTINCT ON (id)`, originals before resends because of the self-FK, and `created` reset to NULL. Run the backfill early in the day, and don't trigger the job manually until you have inspected the result.

## DEV dry run — 2026-11-11

- Before: `dev_wh01_om1` had 13 resend rows and 3 NULL-`created` rows (20028205, 20045654, 22130189). All 3 were resends with a non-NULL `modified`. There are no user triggers on `message`.
- Ran the step-2 `DO` block with `expected = 3`. After: 0 NULL `created`, and `created = modified` on all 3 rows.
- Guard check: re-running the block with `expected = 3` failed with `abort: 0 NULL-created rows, expected 3`. So a wrong count, or a second run, refuses instead of writing.
- Rollback cycle: the rollback block with `expected = 3` reverted all 3 rows (NULL `created` back to 3). The prediction query then returned `resends_moving 3 · resends_staying 0 · originals_freed 2`. That is correct: 20028205 and 20045654 redeliver the same original, which is why the WineCo "51 + 47" can't be added up blindly. Then the backfill was re-applied, leaving 0 NULL `created`. `idx_message_redeliver_id` is present on DEV.
- AC-4 can't be observed on DEV, because the job is off there (`CLEAN_UP_OLD_MESSAGES_ACTIVATED=false`).

## Expected effect, and what to announce

- **Predict before you announce.** Not every row moves on the first run. A resend whose `modified` is inside the retention period stays, and its original stays with it. Run this read-only on each tenant before the backfill, and announce the two numbers it returns. It is approximate: it ignores multi-link chains.

  ```sql
  WITH c AS (SELECT now() - interval '365 days' AS cutoff)   -- use the tenant's CLEAN_UP_OLD_MESSAGES_PERIOD
  SELECT
    (SELECT count(*) FROM message, c WHERE created IS NULL AND redeliver_id IS NOT NULL AND modified < c.cutoff) AS resends_moving,
    (SELECT count(*) FROM message, c WHERE created IS NULL AND redeliver_id IS NOT NULL AND modified >= c.cutoff) AS resends_staying,
    (SELECT count(DISTINCT o.id) FROM message o, c
      WHERE o.created < c.cutoff
        AND EXISTS (SELECT 1 FROM message r WHERE r.redeliver_id = o.id AND r.created IS NULL)
        AND NOT EXISTS (SELECT 1 FROM message r WHERE r.redeliver_id = o.id AND COALESCE(r.created, r.modified) >= c.cutoff)) AS originals_freed;
  ```
- **WineCo:** the first run after the backfill moves `resends_moving + originals_freed` rows from `message` to `message_archived`. This is at most 98, but less if any resend is still inside the retention period, and an original referenced by two resends counts once. Moved rows disappear from the Service Log, like any other expired message. **AC-4:** the job log's "expired rows remain" count drops by `originals_freed`. It reaches 0 only if `resends_staying` is 0. Otherwise the remaining rows age out on later nights, as their resends' `modified` crosses the cutoff.
- **ShipItEz wh01:** nothing moves yet. The originals date from 2026-02-11, so the 7 pairs age out from 2027-02-11.

## Order of operations

1. SBDEV-4095 and SBDEV-4094 reach prod (see *Prerequisite*), and the index, retention and trigger checks pass on each tenant.
2. Re-run AC-1 read-only on both tenants. If the counts are not 51 / 7, stop and re-measure. Run the prediction query, and announce its numbers.
3. Run the procedure on WineCo, then on ShipItEz wh01, early in the day. Attach both id files.
4. The next morning, check AC-4 in the WineCo job log against the predicted `originals_freed`.
