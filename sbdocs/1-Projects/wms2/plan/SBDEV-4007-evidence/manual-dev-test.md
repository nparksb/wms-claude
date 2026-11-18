# SBDEV-4007: manual dev test (2026-11-06, wms-dev-probe)

**What ran:** dev `develop-57147d50` (includes #622). The web UI includes #197 (`9d9d3845`). Tenant wineco/wsl, DB `dev_wh01_om1`.

**Feasibility:**
- 9 club batches are at 520/525 with a lane and no parcels.
- **All 9 are short of stock on their lane** (`POST /v3/clubLine/skus`: every batch has at least one SKU below its required amount).
- So no run can reach DONE without moving stock. Moving stock sends STOCK_UPDATE and club notifications to OMS dev, creates parcels and leaves the batch at 530, and none of that can be undone.
- **Nam chose the failure-path tests only.** No stock was moved.

**Guard read before running:**
- The fenced `validateClubLine(batch, lease)` sets 527 and records `original_batch_state`, then `buildClubLineValidation` throws "Not enough stock" **in the same `@Transactional(rollbackFor=BusinessException)`**.
- So the batch write and the original-state write both roll back. `failJob` sees 520 (no 527) and only marks the job FAILED.

| # | Scenario | Batch | Result |
|---|---|---|---|
| M1 | Run via UI to DONE | — | ⏸ not run: no stock-ready batch on dev |
| M2 | Legacy `GET /v3/clubLine/runClubLine/41479-2`, switch `'1'` | 41479-2 (525) | ✅ failure variant. HTTP 200 in 2.6 s, `{"errors":[{"field":"Runtime Error","message":"Not enough stock on location. TESTSKU needs 7 more;"}]}` (the pre-P2 shape). Job 31611095 FAILED. Batch stayed at 525 |
| M3 | Two parallel `POST /v3/clubLine/clubRunJobs/40875-1` | 40875-1 (520) | ✅ Both returned 202 with the **same jobId 31611093**. FAILED in 0.2 s. `lastError` is the sanitized stock message. `batchState` 520. `GET /clubRunJobs/{id}` and `/byBatch/40875-1` return the same DTO |
| M4 | Kill the pod mid-run, then resume | — | ⏸ not run: needs a ≥200-order stock-ready batch and a pod kill (dev-infeasible, as the plan says) |
| M5 | Kill switch `'0'` | 41428-1 (520) | ✅ Set through `POST /v3/systemProperty/updateValue` (evicts the cache), then waited 125 s for the 2-min Caffeine TTL on any other replica. Three submits each got `{"errors":[{"message":"Async club run is disabled for this warehouse (WMS_CLUBLINE_ASYNC=0)"}]}`, the exact prefix the web UI falls back on. The legacy GET ran **inline**, returning "Not enough stock…" with **0** job rows. Batch stayed at 520 |
| M5 control | Switch restored to `'1'`, waited 125 s | 41428-1 | ✅ Three submits gave three jobs (31611096–98), each FAILED. A FAILED job is not live, so the next submit makes a new job |
| M6 | OMS side of P3 | — | — P3 dropped |

**Not covered:**
- The legacy-GET refusal "batch has a live job" while the switch is `'0'`: every job fails in under a second, so none stays live long enough.
- The P2 UI rendering. It was exercised by 2875 Jest tests, not in a browser on dev.

**Restore proof:** the 5 test job rows were deleted (`club_run_job` is empty again). `snapshot.sh diff` reports `restored` for all four snapshots:
- `t4007batch` (3 batches: id, state, version, lane)
- `t4007orders` (9 orders: id, state, parcel_id, version)
- `t4007sysprop` (id, syskey, sysvalue)
- `t4007jobs` (empty)

**Side effects left on dev:**
- The `WMS_CLUBLINE_ASYNC` row's `modified` and `version` moved; its value is back to `'1'`.
- 5 ids were burned from `seqentities`.
- **0** `outbox_message` rows and **0** `stockrecord` rows since 11:48:59Z.
- Application log lines for the 5 FAILED jobs.

## UI check in a headless browser (2026-11-09)

Run against the deployed web UI (`https://wsl-wineco.wms.dev.sbo.li`, `/processes/club-fulfillment`) and API `develop-a4bdf474`, with puppeteer-core and headless Chrome. Script: scratchpad `pup/sbdev4007-ui.js` (session-only).

**Deviation:** every dev club batch is short of lane stock, and the UI disables Run Club in that case (`disableRun` compares `amountAvailable` with `amountRequired`). The script rewrote the browser's copy of the `POST /v3/clubLine/skus` response so that `amountAvailable = amountRequired`. That made the button clickable, and the screenshots' "Total at Lane" column shows the rewritten numbers. Every other request was real, and the server still refused on the real stock.

| # | Scenario | Batch | Result |
|---|---|---|---|
| U1 | Switch `'1'`: click Run Club | 40875-1 (520) | ✅ The button went to "Club Running", then `POST /clubRunJobs/40875-1` returned 202 (job 31637726), and the page showed "Queued…". One poll GET returned FAILED 2.4 s after the click. The page then showed "Failed to run club: Not enough stock…" inline and as a toast, re-enabled Run Club, and reconciled with `GET /orderBatch` (state 520). **After a reload** it called `byBatch` and showed the same FAILED reason inline |
| U2 | Switch `'0'` (set through `updateValue`, then a 125 s wait): click Run Club | 41428-1 (520) | ✅ `POST` refused with the kill-switch text, then the **legacy `GET /runClubLine/41428-1` ran at once**. The page toasted "Failed to run club: Not enough stock…" and re-enabled Run Club. No job row was created. After a reload, `byBatch` returned "No club run job" and no message was shown, as designed: a legacy failure is reported by the toast only |

**Restore:** switch set back to `'1'` through `updateValue`, and job 31637726 deleted. `snapshot.sh diff` reports `restored` for `u4007batch`, `u4007orders`, `u4007sysprop` and `u4007jobs`. Since 15:17:18Z there are **0** `outbox_message` rows and **0** `stockrecord` rows. Side effects: the sysprop row's `modified` and `version` moved again; 1 id was burned.

**Observation, not a defect:** the stock-shortfall reason lists every short SKU (27 on 40875-1), so the toast covers the page header for its duration. It is the same server text the pre-P2 screen showed.
