---
name: wms2-outbox-dispatcher-status-blind-silent-loss
description: "wms2 marks OMS sends SENT on HTTP 2xx alone; legacy OMS returns 200 with a non-Success verdict in the body → silent loss across /services/call/*. SBDEV-2736 Phase 1 (observability) MERGED 2026-07-30 via PR #107; Phase 2 enforcement not started. THREE envelope shapes, not two."
metadata: 
  node_type: memory
  type: project
  originSessionId: b569dc6d-2bf6-4ec2-b56e-388516b2932c
  modified: 2026-07-30T14:43:09.157Z
---

`OutboxDispatchService.dispatchOne` (`v2/wms2-api/src/main/java/net/aim_ai/wms/service/job/OutboxDispatchService.java:135-140`)
decides delivery success on the HTTP status code alone:

```java
int code = Integer.parseInt(result.get("code"));
if (code >= 200 && code < 300) { outboxService.markSent(msg.getId()); ... }
```

Every legacy OMS handler under `/services/call/*` in `v2/oms-laravel-api` returns **HTTP 200 with
`{"Status": "Error", "Result": [...]}`** for business-level failures (unknown `batch_id`, unresolvable
`positions[].unique_id`). So a failed OMS call is recorded as a successful delivery: row goes `SENT`, no retry,
no distinguishing metric, and `cleanupSent(RETENTION_DAYS)` eventually deletes it. Only trace is the service-log
row storing the error body under status `SENT` — greppable, but invisible to monitoring.

**Why:** this is the exact silent-notification-loss class SBDEV-2221/2238 were built to eliminate, reintroduced at
the response-parsing layer. It is NOT specific to one endpoint — it affects the entire outbox → legacy-OMS surface.

**LANDMINE — OMS legacy `/services/call/*` returns THREE envelope shapes.** Counts from a full census of
`wms2-wineco-dev` (1,206,656 rows, `status='SENT' AND statuscodeanswer='200'`, 2026-07-29):
- **(a) raw** — 1,193,179 — `{"Status":"Error",...}` — finishedShipping, closeAdvice, closeTransfer,
  receiveHubAndSpoke, cancelPosition, batchReversalCompleted
- **(b) wrapped** — 805 — `{"status":"success","data":{"Status":"Error",...}}` — readyToPick, picking,
  finishedPicking, palletized, loadedToTruck, held, assignedToteID. From
  `BaseLegacyController::legacySuccessResponse` (`BaseLegacyController.php:39-62`), which nests `$data` and
  hard-codes top-level `status:'success'` — **so the root lowercase `status` is never a verdict.** A
  top-level-only check misses 37.5% of rejections and reports zero for the whole picking family.
- **(c) lowercase** — 12,652 — `{"status":"success","data":{"status":"exported"|"SUCCESS",...}}`, no capital-S
  `Status` anywhere. `INVENTORY_FULL_EXPORT` + `STOCK_UPDATE`; OMS switched `"exported"`→`"SUCCESS"` on
  2026-07-13. Shape (c) is **not in plan r3** — it was found by capturing the corpus.
  **⚠️ A shape-(c) `SUCCESS` does NOT mean every record landed.** The reconcile variant reports per-record
  outcomes *inside* the success envelope: `"records_failed":1, "failed_records":[{"sku":"LKET1",
  "error":"Product with SKU 'LKET1' not found"}]`. **714 of 1,842 export responses in 2026-07 carried
  failures (1,071 records).** Classifying on the verdict word alone reads them all as accepted.
  Shapes (a)/(b) do **not** leak this way — OMS sets `Status:"Error"` whenever `processed < total` on the
  order endpoints (verified: zero counter-examples across 731 rows with a `total` field).
- plus 16 null bodies (`TEST_CRM_CONNECTIVITY`) and **4 PHP fatal-error HTML pages returned with HTTP 200**
  (`Call to undefined method OMS\Model\BOL::connection_id()`) — real crashes, and the reason the
  unrecognized-shape counter has to stay low-volume to be worth anything.

Shape (c) must match an **accept-list**, not negative space — `"exported"` would otherwise invert to a rejection.
Anchor order matters: capital-S `Status` (root, then `data`) must be consulted *before* the lowercase anchor, or a
wrapped rejection carrying both keys reads as success. OMS normalization is **SBDEV-2738**.

**Verdict census:** `Success` 1,183,372 / **`Partially Failed` 9,999** / `Error` 613. The "613 rejections" figure
in plan r1–r3 counted only `Status='Error'`.

**⚠️ Shape (a) is EXTINCT on `INVENTORY_FULL_EXPORT`** — `Partially Failed` last seen **2025-08-12**, `Error`
**2025-04-01**. All 10,306 of those rows are historical; OMS moved that process to shape (c) during 2025. **Any
query that filters export rejections on a root `Status` is reading a dead envelope and returns zero.** The live
signal is shape-(c) `records_failed`/`failed_records`, ~700/month, almost all unmapped SKUs (SBDEV-2748).

**STATUS — Phase 1 MERGED 2026-07-30**, PR [#107](https://github.com/SiteBossInc/wms2-api/pull/107) into
`develop` (merge commit `c1de721`); ClickUp SBDEV-2736 → **on dev**. Final figures are the post-r6 ones —
`mvn test` 4538 run / 2 pre-existing failures, verify script **70 pass, 0 fail, 1 skip** (the PR *description*
quotes the earlier 4520 and 57/0/1). The 70-check version discriminates: replay commit `ada7192`'s classifier
and it scores 65/5, whereas at 57 checks a build reporting zero export rejections also scored 57/0.
DEV `dev_wh01_om1` is at `2.2.05` with the sysprop seeded `false`; **UAT's four tenants were taken
`2.2.04` → `2.2.05` on 2026-07-30** (`release` @ `bab652c`, tag `v0.0.10`) — row verified `false` /
groupname `Operation Options` on all four by direct query.

**✅ DRIFT HAZARD RESOLVED 2026-07-30.** For a few hours `develop`'s working tree carried an
**amended + renamed** `V2.2.05__seed_outbox_sysprop_toggles.sql` (second seed:
`OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`, SBDEV-2381 Prereq #8) applied to `dev_wh01_om1`, while
`release` — and all four UAT tenants — held the original `V2.2.05__seed_outbox_reject_on_error_sysprop.sql`.
DEV recorded checksum `-382893208`, UAT `2141461053`. Fixed by: reverting the amendment, deleting and
re-applying DEV's `2.2.05` row so it records the original (`2141461053`), and re-landing the seed as its own
**`V2.2.06__seed_outbox_stuck_aggregate_metric_sysprop.sql`** (PR #110, **merged into `develop` 2026-07-30**, `ed4ed25`; ticket SBDEV-2785 → on dev). All five tenants are
now identical through `2.2.05`; DEV is at `2.2.06`, UAT pending with zero drift. Both sysprop rows survived
with original ids/timestamps.

**LESSON (this is the durable part):** "only one DB has it applied, so amending in place is safe" holds only
until the next environment is migrated — on a `develop → release` cadence that window can close the same day.
**Default to a new version number.** Amend only when the migration is unpublished *everywhere* and will stay
so until it lands. See [[flyway-runbook-covers-dev-and-uat-via-env-flag]].
`service/OmsResponseClassifier.java` is now the single decision point for all three egress paths
(dispatcher, `OmsNotificationService.doSend`, `StockSummaryExportJob` — the last carries ~95% of the volume).
Counters: `wms2.outbox.oms_rejected`, `wms2.outbox.response_envelope{recognized}`,
`wms2.oms.notification.rejected`, `wms2.oms.export_rejected`. Flyway `V2.2.05` seeds
`OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED=false`, **read by nothing yet**. Behaviour is unchanged — every 2xx is
still `markSent`.

**Phase 2 (enforcement) is NOT started and is gated on 7 days of observation + a retryability classification.**
`markTerminal` wedges aggregates (`OutboxMessageRepository.java:39-45` — a FAILED_TERMINAL row blocks every
higher-id sibling of the same aggregate and is never auto-deleted); `markRetry` is 5× amplification against a
deterministic failure; and ~40% of rejections are **partial outcomes for which neither is correct**.

**How to apply:** never assume `SENT` means OMS accepted it — inject `OmsResponseClassifier` instead of writing a
fourth body check. **Fail-open is load-bearing**: `classify()` catches `Exception` (not `JsonProcessingException`)
because callers run it inside their own try blocks and `dispatchOne`'s outer `catch (Exception)` calls
`markRetry`/`markTerminal` — anything escaping converts an OMS-*accepted* message into a re-POST. The same trap
bit the tenant tagging: `TenantContext.getCurrentTenant()` returns null when unset, so an unguarded
`.getTenantName()` inside that try is an NPE that silently becomes a retry.

When measuring rejection rates, **exclude `E2E-*`/`SMOKE-*` BOLs** (~35% of volume) and parse JSON rather than
substring-matching. Found while verifying the SBDEV-1921 OMS reversal endpoint; written up in
`sbdocs/4-Archieves/wms2/plan/SBDEV-1921-oms-batch-reversal-completed-endpoint.md` §3.1 item 3. Plan (r4, with
the corpus census) at `sbdocs/1-Projects/wms2/plan/SBDEV-2736-outbox-dispatcher-status-blind-rejection.md`.
Related: [[wms-empty-bol-oms-notification-rejected]] (SBDEV-2737, merged),
[[wms-stock-view-exports-every-itemdata-row]] (SBDEV-2748, the largest single rejection group).

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

marks SENT on HTTP 2xx alone, but legacy OMS returns 200 with a non-Success verdict in the body; SBDEV-2736 Phase 1 (observability, 4 counters + shared OmsResponseClassifier) MERGED 2026-07-30 via PR #107 (merge c1de721), ClickUp "on dev"; Phase 2 enforcement NOT started; V2.2.05 amendment REVERTED 2026-07-30 — second seed re-landed as V2.2.06 (PR #110), all 5 tenants identical through 2.2.05, gated on 7-day observation + retryability classification; LANDMINE: THREE envelope shapes not two (root Status / data.Status / lowercase data.status), and shape (c) needs an accept-list AND a records_failed check — a shape-(c) "SUCCESS" can carry dropped records (714/1842 in 2026-07); shape (a) is EXTINCT on INVENTORY_FULL_EXPORT since 2025-08-12 so root-Status queries there return a false zero
