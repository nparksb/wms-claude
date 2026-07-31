---
title: "SBDEV-2736 — Outbox dispatcher is Status-blind: OMS rejections recorded as successful deliveries"
ticket: "SBDEV-2736"
ticket_url: "https://app.clickup.com/t/868kgmr5a"
type: "bugfix"
severity: "high"
priority: "high"
status: "implemented"
project: ["wms2-api"]
version: "v2"
requester: "nam.park@siteboss.net"
assignee: "Nam Park"
created: "2026-07-27"
updated: "2026-07-30"
revision: 6
db_verified: true
db_verified_note: >
  Verified 2026-07-27 against wms2-wineco-dev and wms2-hydra-dev2 via MCP, then
  RE-verified after ralplan review corrected two errors in revision 1. The defect
  is materialised in the `message` service-log table: 613 rows on wineco-dev
  (20 on hydra-dev2) carry status='SENT' + statuscodeanswer='200' while the stored
  body reports a non-Success verdict. 192 of the wineco-dev rows are from 2026.
  Critically, ORDER_BATCH_SHIPPED rejects at ~48-68% of REAL (non-E2E) sends across
  May-Jul 2026 — revision 1 wrongly reported "~10/month" by averaging over 12 months.
  Queries + results inline in §1.2.
blocks:
  - "SBDEV-2736 Phase 2 is gated on SBDEV-2737"
related:
  - "[[SBDEV-1921-oms-batch-reversal-completed-endpoint]]"
  - "[[SBDEV-2221-transactional-outbox-pilot]]"
  - "[[SBDEV-2238-4.1-bol-closeBOL-outbox-migration]]"
  - "[[wms2-oms-integration-map]]"
  - "SBDEV-2737 — WMS sends BOL-shipped with empty positions[] (https://app.clickup.com/t/868kgp4cb)"
  - "SBDEV-2738 — OMS legacy envelope normalization (https://app.clickup.com/t/868kgp4h6)"
  - "SBDEV-2748 — inventory export failing 19mo on unmapped SKU PNWV20 (https://app.clickup.com/t/868khcak2)"
tags:
  - plan
  - wms2
  - oms
  - outbox
  - notification-loss
  - observability
  - bugfix
---

# SBDEV-2736 — Outbox dispatcher is Status-blind

**Ticket:** [SBDEV-2736](https://app.clickup.com/t/868kgmr5a)
**Project:** wms2-api | **Version:** v2 | **Type:** bugfix (silent notification loss)
**Priority:** High | **Severity:** HIGH
**Status:** draft — **revision 2**, post-ralplan-review (2026-07-27)

> **Revision history.**
> **r1** — initial draft. **r2** — rewritten after a ralplan Architect+Critic pass found two errors that
> invalidated r1's core claims. Both were independently re-verified against code and live DB before acceptance:
>
> 1. **The detector was wrong.** r1 asserted OMS returns one uniform `{"Status":...}` envelope. It returns **two**.
>    r1's detector would have caught 120 of 192 (62.5%) of 2026 rejections and reported **zero** for five of the
>    six affected process types. r1 additionally shipped a unit test and a verify check that *pinned this bug as
>    intended behavior*. Fixed in Fix A; see §1.3.
> 2. **The rate was wrong by ~4.5×.** r1 said "~10/month", derived by averaging 122 rejections over 12 months.
>    The trailing-three-month rate on `ORDER_BATCH_SHIPPED` is **~70% of all sends**. This is not a rare edge
>    case being instrumented — on the primary evidence tenant the BOL-shipped notification currently fails more
>    often than it succeeds. See §1.2 and **§12 Q6, which asks whether this invalidates the agreed phasing.**
>
> Also corrected in r2: the fail-open guarantee did not hold (Fix A), the inertness gate could not fail (Fix E),
> the counter was not tenant-tagged (Fix B), the Phase-2 wedging hazard was unrecorded (§11), and the plan's own
> sample code failed its own verify script (resolved by deferring Fix C).
>
> **Then a third rate correction, from chasing the root cause.** ~35% of recent rejection volume turned out to be
> **E2E smoke-test traffic**. The de-contaminated real-BOL rate is **~48-68%**, not ~70%. The dominant message
> (`"There are no pallets to process"`, 114 of 192) was traced to WMS sending `positions:[]` and filed as
> **[SBDEV-2737](https://app.clickup.com/t/868kgp4cb)**. The two-envelope problem was filed against OMS as
> **[SBDEV-2738](https://app.clickup.com/t/868kgp4h6)**.
>
> **D1's phasing was then amended by the user** — SBDEV-2737 becomes the priority, Phase 1 ships alongside, and
> Phase 2 is gated on the rate dropping. See §12 Q6.
>
> *Three successive corrections to the same number is itself the lesson: this plan's value proposition is
> "measure first", and the measurement was wrong three times before it was right. §11 risk 5 and the
> `response_envelope` counter exist so the next wrong measurement announces itself.*
>
> **Process note.** Authored inline (no `executor` subagent) per a standing session instruction; the ralplan
> Architect and Critic passes were run explicitly and their findings are incorporated above and throughout.

> **Framing.** SBDEV-2221 + the SBDEV-2238 family made WMS→OMS notification *delivery* durable. This plan closes
> the last hole: **WMS never checks whether OMS accepted the message.** A rejection is indistinguishable from a
> success, so the retry machinery never engages and the row is deleted after retention.
>
> **Decisions taken before drafting** (§12): D1 phase the fix (observe, then enforce); D2 outbox dispatcher only;
> D3 sysprop-gated default OFF; D4 no backfill. **D1's premise is now in question — see §12 Q6.**

---

## 0. Affected sites (enumeration before drafting)

```bash
grep -rn "outboxService.enqueue" --include=*.java src/main/java          # 16 hits / 7 services
grep -rn "sendAfterCommit"      --include=*.java src/main/java           # 16 legacy hits / 6 services
grep -rn "markSent\|isTerminal\|TAG_OUTCOME" --include=*.java src/main/java
```

### 0.1 In-scope

> **⚠️ Scope widened 2026-07-28 — decision D2 amended.** Revision 1–2 limited this plan to the outbox dispatcher.
> Production measurement then showed that **95% of the real rejection volume is on paths that exclusion covered**
> (§0.3). The classifier is now a **shared component** applied at all three WMS→OMS egress points.

| # | File:line | Construct | In-scope? |
|---|---|---|---|
| 1 | `service/OmsResponseClassifier.java` | **NEW** — shared `@Component`: `OmsVerdict` enum + `classify(String body)` | **YES (Fix A)** |
| 2 | `service/job/OutboxDispatchService.java:131-151` | `dispatchOne` 2xx branch — `markSent` on status code alone | **YES (Fix B1)** |
| 3 | `service/OmsNotificationService.java` (`doSend`) | Legacy `sendAfterCommit` path — meters non-2xx but never reads the body | **YES (Fix B2) — NEW in r3** |
| 4 | `schedulejob/StockSummaryExportJob.java:299-310` | Direct `httpRestService.post`, hard-codes `MessageStatus.SENT` | **YES (Fix B3) — NEW in r3** |
| 5 | `src/main/resources/db/migration/V2.2.05__*.sql` | NEW — seed the Phase-2 sysprop row default `false` | **YES (Fix D)** |
| 6 | `test/java/.../unit/service/job/OutboxDispatchServiceUnitTest.java` | Extend (10 existing) | **YES (Fix E)** |
| 7 | `test/java/.../unit/service/OmsResponseClassifierUnitTest.java` | **NEW** — classifier table-driven tests | **YES (Fix E)** |
| 8 | `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | §2 + `last_verified` (2026-06-01) | **YES (Fix F)** |

> **Deferred to Phase 2 (was Fix C in r1):** the `WmsConstants` sysprop *constant*. A `public static final String`
> with no reader cannot be type-checked against the migration literal, so the coupling it appears to buy is
> illusory — and its presence made the plan's own Fix B sample code fail the plan's own `C-inert` verify check.
> The Flyway seed (Fix D) still ships in Phase 1; that is where the real value is (§12 Q1).

### 0.2 Enqueue call sites covered with no per-site edits

All 16 benefit automatically — the fix is inside the shared dispatcher.

| Service | Sites | Types |
|---|---|---|
| `PickingorderBusinessService` | 4 (`:275, :392, :458, :629`) | picking started / finished / tote-assigned |
| `CustomerorderBatchService` | 4 (`:306, :744, :754, :769`) | release / started / finished |
| `AdviceService` | 3 (`:269, :369, :440`) | advice close / transfer |
| `BillofladingService` | 1 (`:692`) | `ORDER_BATCH_SHIPPED` |
| `CustomerorderService` | 1 (`:801`) | order cancelled |
| `CancellationReversalService` | 1 (`:244`) | `ORDER_BATCH_REVERSAL_COMPLETED` |
| `ReleaseOrderJobService` | 1 (`:741`) | order release (cron) |

### 0.3 Why D2 was amended — the measurement that forced it

Production rejection volume by egress path (`wsl-wineco-uat`, all process types, since 2025-01-01):

| Path | Process types | Rejections | Covered by r2 scope? |
|---|---|---|---|
| **Direct POST** (`StockSummaryExportJob`) | `INVENTORY_FULL_EXPORT` | **701 (95.5%)** | ❌ no |
| **Outbox** (`OutboxDispatchService`) | `ORDER_BATCH_SHIPPED` | 24 | ✅ yes — but all empty-BOL, removed by SBDEV-2737 |
| **Outbox** | picking family (tote-assigned / released / finished / started) | 9 | ✅ yes |
| **Legacy** `sendAfterCommit` | various | 0 observed | ❌ no |

**The r2 scope would have detected 9 events in 19 months on WineCo — and ~0 after SBDEV-2737.** The instrument
was aimed at 4.5% of the problem. Of the 701, **575 are a single unmapped SKU failing daily for 19 months**
([SBDEV-2748](https://app.clickup.com/t/868khcak2)) — found only because this analysis looked outside the
original scope.

D2 is therefore amended: **classify the response at every WMS→OMS egress point**, not just the outbox. The
classifier is a pure function of a response body, so covering the other two paths is a small addition to the same
PR, not a new design.

### 0.4 Still excluded

| # | File | Sites | Why |
|---|---|---|---|
| 9 | `MessageService.java` | 1 | Manual operator resend surface — the operator sees the response directly. |

The 13 `sendAfterCommit` call sites in `ManageOrderService` (9), `StockChangeNotificationService` (3),
`CustomerorderBatchService` (1) and `ReleaseOrderJobService` (1) are now covered **centrally** by Fix B2 — the
classification happens once inside `OmsNotificationService.doSend`, so no per-caller edits are needed.

### 0.4 Cross-reference

- [[SBDEV-1921-oms-batch-reversal-completed-endpoint]] §3.1 item 3 — where the defect was discovered (archived).
- [[SBDEV-2221-transactional-outbox-pilot]] — introduced `dispatchOne`; the 2xx-only predicate dates from here.
- [[SBDEV-2238-4.1-bol-closeBOL-outbox-migration]] — migrated `BillofladingService`, the caller rejecting at ~70%.

**Docs consulted:** `wms2-oms-integration-map.md` §2, `wms2-scheduled-jobs-catalog.md` §3,
`wms2-transaction-osiv-boundary-map.md` (confirming `dispatchOne` holds no transaction).

---

## 1. Problem Statement

### 1.1 Symptom

WMS advances state, enqueues an outbox row, and the dispatcher POSTs it. OMS returns **HTTP 200** with a body
saying it rejected the message. WMS reads only the status code and: marks the row `SENT`; increments the
*success* counter; writes a `SENT` service-log row; never retries (retry/terminal branches are unreachable for
2xx); and deletes the row once `cleanupSent(RETENTION_DAYS)` runs. **No metric, log level, or alert distinguishes
this from a real success.**

### 1.2 DB verification — PASSED (corrected in r2)

Run 2026-07-27 against `wms2-wineco-dev` and `wms2-hydra-dev2`.

**Population.** `SENT` + HTTP 200 rows whose body reports a non-Success verdict:

| Tenant | `SENT` + 200 | non-Success body |
|---|---|---|
| wms2-wineco-dev | 1,206,518 | **613** |
| wms2-hydra-dev2 | 51,624 | **20** |

**⚠️ Rate — the number that matters, corrected twice.** Revision 1 reported "~10/month" (averaging 122 over 12
months). The ralplan review corrected that to "~70%". Chasing the root cause then revealed a **third** correction:
~35% of the recent rejection volume is **E2E smoke-test traffic** (`E2E-CLB-SMOKE-BOL-*`, `E2E-BOL-SMOKE-*`,
60 rows since 2026-05-29), which inflates the headline. Both the raw and the de-contaminated figures are below —
**use the real-BOL column.**

Raw (all traffic) on `ORDER_BATCH_SHIPPED`, wineco-dev:

```sql
SELECT to_char(created,'YYYY-MM') AS mon, COUNT(*) AS total_sends,
       COUNT(*) FILTER (WHERE answer ILIKE '%"Status":"Error"%') AS rejections
FROM message
WHERE process='ORDER_BATCH_SHIPPED' AND status='SENT' AND statuscodeanswer='200'
  AND created >= '2026-01-01' GROUP BY 1 ORDER BY 1;
```

| Month | Sends | Rejected | **% rejected** |
|---|---|---|---|
| 2026-02 | 28 | 8 | 28.6% |
| 2026-03 | 5 | 0 | 0% |
| 2026-04 | 4 | 0 | 0% |
| 2026-05 | 33 | 23 | **69.7%** |
| 2026-06 | 63 | 46 | **73.0%** |
| 2026-07 | 65 | 45 | **69.2%** |

> ### ⚠️ SETTLED POSITION on the rate (2026-07-27, after SBDEV-2737 diagnosis) — READ THIS INSTEAD OF THE TABLES BELOW
>
> The rate figures in this section were corrected four times. Rather than layer another retraction, here is the
> final, evidence-backed position. **The tables below are retained only as a correction trail — do not cite them.**
>
> **On wms2-wineco-dev (v2 dev):** all 114 rejections are automated test traffic from one `operator_id` (52610) —
> 71 obviously synthetic, 13 Cypress, 30 that an "exclude E2E/SMOKE" name filter wrongly passed as real
> (`🍷📦🥂`, `<script>alert(1)</script>`, `'; DROP TABLE picking_order; --`, `ibre`). **Dev volume proves nothing
> about production.**
>
> **On production — measured exactly against `wsl-wineco-uat` (the migrated copy of WineCo production), using
> JSON parsing over all 2,852 `ORDER_BATCH_SHIPPED` messages 2019–2026:**
>
> | Measure | n |
> |---|---|
> | Truly empty top-level `positions` | **86** |
> | Rejected by OMS | **86** |
> | Empty **and** rejected | **86 (100%)** |
> | Empty but accepted | **0** |
> | Non-empty but rejected | **0** |
>
> **Perfect correlation** — emptiness is an exact predictor of rejection, no exceptions in seven years.
> Rate: **86/2,852 = 3.0%**, ~12/year, flat across both OMS generations (2.4% in 2020 on legacy, 3.6% in 2026
> on v2). Affected BOLs are real operator work: `WineCo Close 7-13-25` (rejected 2026-07-14), `ADV Close`,
> `WVV Close 2-2026`, `Audeant Hold Orders`, `Bergstrom Cancelled Order`, `Voided Orders 4.1.24`.
>
> **❌ NOT a migration regression.** An earlier reading of this evidence claimed legacy OMS accepted ~78% and
> OMS v2 newly rejects — implying an OMS-v2 cutover cliff. That was an artifact of a bad filter (below). Both
> OMS generations always rejected empty-position sends. **No migration exposure.**
>
> **Practical harm is low:** an empty BOL contains no shipment content, so the missing notification conveys
> nothing about goods movement. The real cost is ~12 silent failures/year that are indistinguishable from
> success — i.e. contamination of the very baseline Phase 1 exists to measure. Tracked at **normal** priority in
> [SBDEV-2737](https://app.clickup.com/t/868kgp4cb).
>
> ### Two measurement landmines worth keeping
>
> 1. **Do not use `ILIKE '%"positions":[]%'`** to find empty payloads — it over-counts **~4×** (337 vs 86)
>    because nested `orderDto.positions` also renders `[]` (`BillofladingService.java:513`). Use
>    `json_array_length(message::json->'positions') = 0`. Every wrong rate in this plan's history traces to this.
> 2. **The payload's `bol_id` is `billoflading.name`, not `.number`.** Joining on `.number` returns zero matches
>    for *both* accepted and rejected groups — checking the control group is what exposed the broken join rather
>    than reading "zero" as a finding.

**⚠️ SUPERSEDED — the two tables below are the correction trail, not the answer. See the settled position above.**

| Month | Real BOL sends | Rejected | **% rejected** |
|---|---|---|---|
| 2026-05 | 31 | 21 | **67.7%** |
| 2026-06 | 31 | 15 | **48.4%** |
| 2026-07 | 38 | 18 | **47.4%** |

**Roughly half of all real BOL-shipped notifications are rejected**, sustained over three months. By contrast
**hydra-dev2 is ~3%** (2/66) — the split is itself a diagnostic lead pointing at tenant data/config rather than
code. The E2E traffic inflates but does not cause the defect: all-time, `"There are no pallets to process"` has
**127 real-BOL occurrences going back to 2020-02**, versus 60 E2E since 2026-05-29.

**Message distribution (2026, all shapes)** — the input Phase 2 needs, and the basis for §11 risk 3:

| Message | n | Retryability |
|---|---|---|
| `There are no pallets to process` | 114 | **Permanently unretryable** — WMS sent `positions:[]`. Root cause → **SBDEV-2737** |
| `At least one parcel was not updated` | 64 | **Partial outcome** — neither retry nor terminal is correct |
| `At least one parcel did not have its tote id assigned` | 6 | Partial outcome |
| `Some positions were not processed` | 6 | Partial outcome |
| `At least one parcel was not shipped` | 2 | Partial outcome |

**~40% of rejections are partial outcomes** for which the Phase-2 binary (retry vs terminal) has no correct
answer. This is why Step 12's deliverable is a classification, not a rate.

**Root cause of the dominant message — found, and filed.** OMS rejects when `positions` is empty
(`LegacyWmsController.php:1759-1764`), and the stored WMS payload confirms it sends nothing:

```json
{"positions":[],"bol_id":"...","shared_unique_bol_id":"ec93b37e-...",
 "transfer_id":"ede68006-...","outbound_bol_type":"REGULAR","source_warehouse":"WSL"}
```

Tracked as **[SBDEV-2737](https://app.clickup.com/t/868kgp4cb)** — see §12 Q6 for how it re-orders this plan.

**⚠️ Two envelope shapes, not one** — the finding that invalidated r1's detector:

```sql
SELECT process,
  CASE WHEN answer ~ '^\s*\{\s*"Status"'          THEN 'a: root Status'
       WHEN answer ILIKE '%"data":{"Status"%'     THEN 'b: wrapped data.Status' END AS shape,
  COUNT(*) FROM message
WHERE status='SENT' AND statuscodeanswer='200' AND answer ILIKE '%"Status":"Error"%'
GROUP BY 1,2;
```

| Process type | 2026 total | shape (a) root | shape (b) wrapped |
|---|---|---|---|
| `ORDER_BATCH_SHIPPED` | 122 | 120 | 2 |
| `ORDER_BATCH_PICKING_FINISHED` | 26 | 0 | **26** |
| `ORDER_BATCH_PICKING_STARTED` | 21 | 0 | **21** |
| `ORDER_BATCH_PICKING_RELEASED` | 16 | 0 | **16** |
| `ORDER_BATCH_PICKING_TOTE_ASSIGNED` | 6 | 0 | **6** |
| `ORDER_BATCH_ON_HOLD` | 1 | 0 | **1** |
| **Total** | **192** | **120 (62.5%)** | **72 (37.5%)** |

A root-only detector reports **zero** for five of six process types. Note the §1.2 population query uses a
**substring** match, which catches both shapes — so r1's evidence and r1's detector disagreed by 37.5%. Fix A's
two-level predicate makes them agree; §7 scenario 5 cross-validates that they do.

**A third population the detector must NOT be pointed at yet.** `INVENTORY_FULL_EXPORT` carries **9,999** rows
whose body is `{"Status":"Partially Failed",...}` (plus 307 `Status:Error`), last seen **today**. A negative-space
predicate matches `Partially Failed` as a rejection, but these are *partial successes* and the process is emitted
by `StockSummaryExportJob` (§0.3 row 10) via a direct `httpRestService.post` — **not** the outbox, so the detector
never sees them in Phase 1. It would light up at 9,999-scale the moment that job migrates. Recorded as §11 risk 6.

**Caveat.** The `message` table is written by the outbox, the legacy path, and `StockSummaryExportJob`, spanning
2019–2026. The 2026 `ORDER_BATCH_SHIPPED` rows are attributable to the outbox via SBDEV-2238-4.1. Counts are an
upper bound on outbox-path damage, a lower bound on total.

### 1.3 OMS returns two response shapes (corrected in r2)

Revision 1 claimed uniformity. It is wrong. `BaseLegacyController::legacySuccessResponse`
(`BaseLegacyController.php:56-62` → `legacyResponse` `:39-45`) **wraps** whatever it is handed:

```php
protected function legacyResponse($data, string $status = 'success', string $message = null): array
{
    return ['status' => $status, 'message' => $message, 'data' => $data];
}
```

Handlers that build a `Status` envelope and then pass it *through* that wrapper produce shape (b). `readyToPick`
(`LegacyWmsController.php:1129-1145`) is representative — it computes `$status = empty($errors) ? 'Success' : 'Error'`,
puts it in `$data`, then calls `legacySuccessResponse($data, $message)`, yielding:

```json
{"status":"success","message":"At least one parcel was not updated",
 "data":{"Status":"Error","Message":"At least one parcel was not updated",
         "Result":["readyToPick Failed for unique_id=...: Parcel not found"],"processed":0,"total":1}}
```

Top-level `status` is **`success`**; the real verdict is one level down.

| Shape | Wire form | Handlers |
|---|---|---|
| **(a) raw** | `{"Status":"Error",...}` | `finishedShipping` `:1739-1745`, `closeAdvice` `:2705`, `closeTransfer` `:2804`, `receiveHubAndSpoke` `:2928`, `cancelPosition` `:3076`, `batchReversalCompleted` `:3218` |
| **(b) wrapped** | `{"status":"success","data":{"Status":"Error",...}}` | `readyToPick` `:1137`, `picking` `:1349`, `finishedPicking` `:1595`, `palletized` `:2133`, `loadedToTruck` `:2350`, `held` `:2582`, `assignedToteID` `:865-881` |

**Why not fix OMS instead?** It is the more durable fix and the same team owns both repos — but it does not
replace the WMS detector: OMS deploys independently, so a shape regression must be detectable from the WMS side,
and there is no OMS-side equivalent of the 613 rows to measure against. The two are complementary. Filing the OMS
normalization is §12 Q7.

---

## 2. Root Cause Analysis

### Bug 1 — `dispatchOne` treats "HTTP transport succeeded" as "OMS accepted"

**File:** `service/job/OutboxDispatchService.java:131-151`

```java
Map<String, String> result = httpRestService.postWithIdempotencyKey(...);
int code = Integer.parseInt(result.get("code"));

if (code >= 200 && code < 300) {
    outboxService.markSent(msg.getId());                                    // <-- body never inspected
    meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "sent").increment();
    writeServiceLog(msg, WmsConstants.MessageStatus.SENT, String.valueOf(code), result.get("answer"));
}
```

`result.get("answer")` is the full body (confirmed: `HttpRestService.java:53-69` — `exchange` returns the raw
body and does not throw on non-2xx) and is passed to the service log without ever being examined.

**Why it fails:** the predicate encodes "the HTTP round-trip completed" but is *used* as "the peer accepted the
event." For a status-code-driven API those coincide; for this OMS surface they do not.

**Why it was not caught:** `OutboxDispatchServiceUnitTest:101` asserts exactly the buggy behavior. All 2xx stubs
in the class are `Map.of("code","200","answer","OK")` (`:104, :174, :278, :284, :313`), so no test has ever
exercised a real response body.

**Confidence: certain** — one readable branch, corroborated by 633 rows across two tenants.

### Bug 2 (latent, out of scope) — the same blindness on two other paths

The legacy `sendAfterCommit` path and `StockSummaryExportJob` share the trait. 17 sites, §0.3. Excluded by D2.

### Non-bug ruled out — SBDEV-2381 stale rejections are safe

OMS's defensive out-of-order rejection does **not** produce `Status: Error`. `readyToPick` derives its verdict as
`empty($errors) ? 'Success' : 'Error'` (`:1129`), and a stale drop increments `$processedPositions` and
`continue`s **without appending to `$errors`** (`:1095-1099`), so it yields `Success`. Verified at `:1095, :1303,
:1547, :2084`. Inline comment: *"Treated as processed so WMS retries don't loop."* No false positives.

---

## 3. Architecture Overview

### Current (broken)

```
  dispatchOne: POST ──► OMS ──► HTTP 200 {"Status":"Error"}  (or wrapped {"status":"success","data":{...}})
       │
       └─ code in 2xx? ── YES ─► markSent / outcome="sent" / serviceLog(SENT) / row later deleted
                                  *** rejection invisible ***
```

### Target — Phase 1: observe, do not change semantics

```
       └─ code in 2xx? ── YES ─► classify(body)
                                   ├─ REJECTED   → LOG.warn + oms_rejected{tenant,facility,processType}++
                                   ├─ ACCEPTED   → (nothing)
                                   └─ UNRECOGNIZED → response_envelope{recognized="no",processType}++
                                  then markSent / outcome="sent" / serviceLog(SENT)   [ALL UNCHANGED]
```

### Target — Phase 2 (separate plan, sysprop-gated)

```
                                   REJECTED + sysprop ON → markRetry (default)
                                                            markTerminal ONLY for classified-unretryable
```

**Key invariants (Phase 1):** zero change to outbox state transitions, zero change to existing metric series,
zero change to the Service Log.

### Key files

| File | Lines | Role |
|---|---|---|
| `service/job/OutboxDispatchService.java` | 131-151 | **Primary.** 2xx branch. |
| `service/job/OutboxDispatchService.java` | 152-166 | Outer `catch (Exception)` — drives Fix A's catch width. |
| `service/job/OutboxDispatchService.java` | 201-204 | `isTerminal` — untouched; Phase 2 extension point. |
| `repo/jpa/OutboxMessageRepository.java` | 39-45, 73 | `FAILED_TERMINAL` sibling-blocking gate — §11 risk 3. |
| `schedulejob/OutboxDispatcherJob.java` | 87, 92-94 | `TenantContext` in scope; tenant+facility tagging precedent. |
| `db/migration/V2.2.05__*.sql` | NEW | Sysprop seed. Head is V2.2.04. |
| `unit/service/job/OutboxDispatchServiceUnitTest.java` | +8 tests | |
| `wms2-oms-integration-map.md` | §2 | `last_verified` currently 2026-06-01. |

---

## 4. Fix Design

### Fix A — three-way response classifier (shared component)

**File:** `service/OmsResponseClassifier.java` — **NEW `@Component`.**

> **r3 change:** was a private method on `OutboxDispatchService`. It is now a standalone injectable component
> because three separate egress paths need it (§0.3). Constructor-inject its own `ObjectMapper` per the v2
> convention; it holds no state, so it is trivially thread-safe and unit-testable in isolation.

```java
/** Outcome of inspecting a 2xx OMS response body (SBDEV-2736). */
public enum OmsVerdict { ACCEPTED, REJECTED, UNRECOGNIZED }

private static final String OMS_STATUS_FIELD    = "Status";
private static final String OMS_WRAPPER_DATA    = "data";
private static final String OMS_STATUS_SUCCESS  = "Success";

/**
 * Classifies a 2xx OMS response body.
 *
 * <p>OMS's legacy /services/call/* surface returns HTTP 200 for business-level failures and carries the
 * verdict in the body, so the status code alone cannot distinguish acceptance from rejection (SBDEV-2736).
 * Two shapes exist and BOTH must be handled — a root-only check misses 37.5% of real rejections and reports
 * zero for the entire picking family:</p>
 * <pre>
 *   (a) raw:     {"Status":"Error", ...}
 *   (b) wrapped: {"status":"success","message":...,"data":{"Status":"Error", ...}}
 * </pre>
 * Shape (b) comes from BaseLegacyController::legacySuccessResponse, which nests the real envelope under
 * "data" and stamps a top-level lowercase status of "success".
 *
 * <p>Structural lookup only — exactly these two anchors, no recursive/wildcard search — so the predicate
 * stays closed and Phase 2 can safely drive delivery decisions from it. Anything else is UNRECOGNIZED
 * (never REJECTED), which is metered so an unknown OMS shape announces itself instead of failing silent.</p>
 */
public OmsVerdict classify(String body) {
    if (body == null || body.isBlank()) {
        return OmsVerdict.UNRECOGNIZED;
    }
    try {
        JsonNode root = objectMapper.readTree(body);
        if (!(root instanceof ObjectNode)) {
            return OmsVerdict.UNRECOGNIZED;
        }
        JsonNode verdict = root.get(OMS_STATUS_FIELD);                       // shape (a)
        if (verdict == null || !verdict.isTextual()) {
            JsonNode data = root.get(OMS_WRAPPER_DATA);                      // shape (b)
            if (data instanceof ObjectNode) {
                verdict = data.get(OMS_STATUS_FIELD);
            }
        }
        if (verdict == null || !verdict.isTextual()) {
            return OmsVerdict.UNRECOGNIZED;
        }
        return OMS_STATUS_SUCCESS.equalsIgnoreCase(verdict.asText())
            ? OmsVerdict.ACCEPTED : OmsVerdict.REJECTED;
    } catch (Exception e) {
        // MUST be Exception, not JsonProcessingException. dispatchOne's outer handler (line ~152) is
        // catch(Exception) and calls markRetry/markTerminal — so any throwable escaping here would convert
        // an OMS-ACCEPTED message into a delivery failure, violating the Phase-1 inertness guarantee.
        LOG.debug("outboxDispatcher: could not classify OMS response body", e);
        return OmsVerdict.UNRECOGNIZED;
    }
}
```

**Why each choice:**

- **Two structural anchors, not a depth search.** Gets full coverage of both real shapes while keeping the
  predicate closed — important because Phase 2 drives `markRetry`/`markTerminal` from it, where a stray nested
  `Status` in an arbitrary `Result` payload would cause a false re-delivery.
- **Three-way, not boolean.** `UNRECOGNIZED` is distinct from `ACCEPTED`. This is what makes the Phase-1→Phase-2
  gate real: if an OMS shape drifts, the recognition counter goes non-zero and the rejection baseline for that
  process type is known-untrustworthy, rather than silently reading zero. r1's boolean collapsed these.
- **`catch (Exception)`, not `catch (JsonProcessingException)`.** See the inline comment — this is the one path
  by which Phase 1 could change behavior, and it is a two-word fix.
- **Case-insensitive against `Success`**, matching the negative space, because OMS also emits `Failure` and
  `Partially Failed`.
- **Shared component, not duplicated logic.** One classifier, one test class, three consumers. If SBDEV-2738
  normalizes the OMS envelope, the two-level lookup collapses to one level in exactly one place.

> **⚠️ `Partially Failed` and `INVENTORY_FULL_EXPORT`.** The negative-space match treats
> `{"Status":"Partially Failed"}` as `REJECTED`. On the direct-POST path that is a **large** population — see
> §11 risk 6. Decide before implementing whether a partial success should count as a rejection for that process
> type, or whether the counter should simply distinguish it via a `verdict` tag. **The safe Phase-1 answer is to
> count it and tag it**, since Phase 1 changes no behavior; Phase 2 must not act on it without a decision.

### Fix B1 — outbox dispatcher: wire into the 2xx branch (observability only)

**Before:**

```java
if (code >= 200 && code < 300) {
    outboxService.markSent(msg.getId());
    meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "sent").increment();
    writeServiceLog(msg, WmsConstants.MessageStatus.SENT, String.valueOf(code), result.get("answer"));
}
```

**After:**

```java
if (code >= 200 && code < 300) {
    String answer = result.get("answer");
    OmsVerdict verdict = omsResponseClassifier.classify(answer);
    Tags omsTags = Tags.of("tenant",      TenantContext.getCurrentTenant().getTenantName(),
                           "facility",    TenantContext.getCurrentTenant().getFacilityCode(),
                           TAG_PROCESS_TYPE, msg.getProcessType());
    if (verdict == OmsVerdict.REJECTED) {
        // SBDEV-2736 Phase 1: surface only. Delivery semantics deliberately unchanged until the
        // rejection baseline is classified; Phase 2 acts on this behind the seeded sysprop gate.
        LOG.warn("outboxDispatcher: OMS rejected a 2xx-delivered message (recorded as SENT anyway). "
                + "outboxId={} processType={} aggregate={}/{} body={}",
            msg.getId(), msg.getProcessType(), msg.getAggregateType(), msg.getAggregateId(), answer);
        meters.counter("wms2.outbox.oms_rejected", omsTags).increment();
    }
    meters.counter("wms2.outbox.response_envelope",
        omsTags.and("recognized", verdict == OmsVerdict.UNRECOGNIZED ? "no" : "yes")).increment();

    outboxService.markSent(msg.getId());
    meters.counter("wms2.outbox.dispatched", TAG_OUTCOME, "sent").increment();
    writeServiceLog(msg, WmsConstants.MessageStatus.SENT, String.valueOf(code), answer);
}
```

**Why each choice:**

- **New counters, not a new `outcome` tag value.** `dispatched{outcome}` is a partition over *terminal delivery
  outcomes*; a Phase-1 rejection is not a distinct outcome (the row still goes `SENT`). Adding a value would make
  the partition non-exhaustive and inconsistent with row state. (r1 justified this as "would break existing
  dashboards" — no in-repo consumer of `wms2.outbox.dispatched` exists, so state that as unverified; the
  modelling argument is the one that holds.)
- **Tenant + facility tags.** `OutboxDispatcherJob:87` sets `TenantContext` for the whole `dispatchBatch` call,
  and the sibling `wms2.outbox.stuck_aggregate` gauge is already `Tags.of("tenant", …, "facility", …)` at
  `:92-94`. Given wineco ~70% vs hydra ~3%, **tenant is the signal** — an untagged alert cannot name the affected
  warehouse.
- **`LOG.warn`, not `LOG.error`.** Phase 1 deliberately does not act. An ERROR the system declines to act on
  trains operators to filter that logger, and at ~45/month and rising the desensitization budget is real. The
  counter is the alerting surface (Step 8 alerts on the counter, not the log). ERROR earns its level in Phase 2.
- **No sysprop name in the comment** — r1's comment contained the literal key, which made the plan's own
  `C-inert` verify check fail on correct implementation.
- **`response_envelope` on every 2xx**, not only on rejection — the denominator is what makes `recognized="no"`
  interpretable.

### Fix B2 — legacy path: `OmsNotificationService.doSend` — **NEW in r3**

**File:** `service/OmsNotificationService.java`, in `doSend` where the response is handled.

Same three lines as B1: classify the body, and on `REJECTED` emit a WARN plus
`wms2.oms.notification.rejected{tenant, processType}`. **(Corrected in r5 — this line originally said
`{tenant, facility, processType}`, which contradicted the "reuse the tag convention" sentence directly
after it and was never what shipped. `notification.failed` is tenant-only, and the pair is only readable
if both carry the same tags. `export_rejected` DOES take `facility`, because that job iterates per
tenant+warehouse — see r5.)** Reuse the existing
`wms2.oms.notification.failed` counter's tag convention so the two read as a pair.

**Why centrally here and not at the 13 call sites:** every legacy caller funnels through `doSend`, so one edit
covers `ManageOrderService` (9), `StockChangeNotificationService` (3), `CustomerorderBatchService` (1) and
`ReleaseOrderJobService` (1) with no per-caller churn — and automatically covers any caller not yet migrated to
the outbox.

**Behavioural inertness still holds:** this path is already fire-and-forget with no retry, so adding a counter
and a log changes nothing about delivery.

### Fix B3 — direct POST: `StockSummaryExportJob` — **NEW in r3, highest-value site**

**File:** `schedulejob/StockSummaryExportJob.java:299-310`.

**Before** — status hard-coded regardless of the response body:

```java
Map<String,String> respMap = httpRestService.post(urlPath, payload);
messageService.createMessage(..., WmsConstants.MessageStatus.SENT, respMap.get("code"), respMap.get("answer"));
```

**After** — classify, count, and log; **still write `SENT`** (Phase 1 changes no behavior):

```java
Map<String,String> respMap = httpRestService.post(urlPath, payload);
OmsVerdict verdict = omsResponseClassifier.classify(respMap.get("answer"));
if (verdict == OmsVerdict.REJECTED) {
    LOG.warn("stockSummaryExport: OMS rejected the inventory export (recorded as SENT anyway). body={}",
        respMap.get("answer"));
    meters.counter("wms2.oms.export_rejected", "tenant", ..., "facility", ...).increment();
}
messageService.createMessage(..., WmsConstants.MessageStatus.SENT, respMap.get("code"), respMap.get("answer"));
```

**This is the site that matters.** It carries 701 of the 734 production rejections (§0.3) — including the 575
that turned out to be [SBDEV-2748](https://app.clickup.com/t/868khcak2). Had this counter existed in January
2025, that SKU issue would have been visible the first week instead of the nineteenth month.

The job already has a `MeterRegistry`? **Verify during implementation** — if not, constructor-inject one
(`schedulejob/JobMetrics.java` is the established pattern for cron jobs and may be the better home).

### Fix D — Flyway `V2.2.05` sysprop seed

**File:** `src/main/resources/db/migration/V2.2.05__seed_outbox_sysprop_toggles.sql` — NEW.

Seeds `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED = 'false'`, idempotent via `WHERE NOT EXISTS`. Ships in Phase 1
so every tenant has the row after the Phase-1 `flyway migrate` and Phase 2 is a config flip with no second
operator DB step (the SBDEV-1666/1762 lesson).

> **Implementation note.** `V2.2.04__seed_lane_behavior_sysprop_toggles.sql` is the template — **diff the column
> list against it, do not hand-write**. Its actual order is
> `(id, version, entity_lock, hidden, syskey, sysvalue, workstation, client_id, groupname, description, created, modified)`;
> r1's draft SQL had a different order and omitted `workstation`.

Phase 2's first test must assert `syspropService.getSysvalue(KEY)` is non-null against a seeded DB — that is what
guards the key literal against drift now that the Java constant is deferred.

### Fix E — tests

**File:** `unit/service/job/OutboxDispatchServiceUnitTest.java`

> **On the inertness gate.** r1 claimed "the 10 existing tests passing unmodified proves Phase 1 is inert." That
> is **false and has been removed**: only 4 of the 10 use a 2xx stub, and every 2xx stub is `answer="OK"`, which
> fails `readTree` and short-circuits the classifier before it evaluates anything. Those tests cannot distinguish
> a correct implementation from one that marks rejections terminal. They are retained as a smoke gate against
> exceptions and reordering — nothing more. **The real gate is E1 below.**

| # | Test | Asserts |
|---|---|---|
| **E1** | `dispatchOne_capturedBodies_neverAlterDeliveryOutcome` | **The inertness gate.** Table-driven over verbatim `message.answer` strings captured from the live table — shape (a), shape (b), `Partially Failed`, `"OK"`, empty, malformed. For every one: `markSent(id)` called, `never()` on `markTerminal` and `markRetry`, `dispatched{outcome="sent"}` == 1, and the `createMessage(...)` argument tuple byte-identical to the existing `200`/`"OK"` case at `:111-119`. |
| **E2** | `dispatchOne_2xxRawStatusError_incrementsRejectedCounter` | Shape (a) → `oms_rejected{tenant,facility,processType}` == 1. |
| **E3** | `dispatchOne_2xxWrappedDataStatusError_incrementsRejectedCounter` | **Shape (b)**, verbatim wrapped body from §1.3 → counter == 1. The test r1 got backwards. |
| **E4** | `dispatchOne_2xxStatusSuccess_bothShapes_doesNotIncrementRejectedCounter` | `{"Status":"Success"}` and `{"status":"success","data":{"Status":"Success"}}` → 0. |
| **E5** | `dispatchOne_2xxPartiallyFailed_incrementsRejectedCounter` | Negative-space match, not `Error`-equality. |
| **E6** | `dispatchOne_2xxUnrecognizedBody_incrementsRecognizedNoAndNotRejected` | `""`, `"OK"`, `"[1,2]"`, `{"foo":1}`, `{"status":"success","data":{"x":1}}` → `response_envelope{recognized="no"}` incremented, `oms_rejected` == 0. |
| **E7** | `dispatchOne_classifierThrowsRuntimeException_stillMarksSentAndNeverRetries` | `ObjectMapper` stubbed to throw `RuntimeException` → `markSent` called, `never()` on `markRetry`/`markTerminal`. **The only test that actually proves the fail-open invariant** (Fix A's `catch (Exception)`). |
| **E8** | `dispatchOne_rejectedCounter_isTaggedWithTenantAndFacility` | Tag assertion via `SimpleMeterRegistry`. |

`SimpleMeterRegistry` for counter assertions (existing pattern). Unit scope only — no Testcontainers (SBDEV-2217).

**Log assertions:** AC-1's log clause needs a `ListAppender` on the `OutboxDispatchService` logger. There is
exactly one precedent repo-wide (`FileImportControllerUnitTest`). Either follow it in E2, or drop the log clause
from §10 AC-1 — do not leave it as an untestable criterion (§12 Q8).

### Fix F — documentation

`wms2-oms-integration-map.md` §2: document **both** response shapes with the §1.3 handler table, the Phase-1
counters, and the Phase-2 plan. Bump `last_verified` from `2026-06-01` to the merge date.

---

## 5. File change summary

| File | Change | LoC |
|---|---|---|
| `service/OmsResponseClassifier.java` | **NEW** — Fix A: enum + `classify()` | +55 |
| `service/job/OutboxDispatchService.java` | Fix B1 — inject classifier, wire 2xx branch | +22 / -4 |
| `service/OmsNotificationService.java` | **Fix B2 (r3)** — classify in `doSend`, counter + WARN | +14 |
| `schedulejob/StockSummaryExportJob.java` | **Fix B3 (r3)** — classify response, counter + WARN | +14 |
| `db/migration/V2.2.05__seed_outbox_sysprop_toggles.sql` | NEW — Fix D | +14 |
| `unit/service/OmsResponseClassifierUnitTest.java` | **NEW** — table-driven over all six captured shapes | +130 |
| `unit/service/job/OutboxDispatchServiceUnitTest.java` | 8 tests incl. the corpus inertness gate | +260 |
| `wms2-oms-integration-map.md` | Fix F — both shapes, all three egress paths | +36 / -2 |

**~545 added, 6 removed.** Still no production behavior change — every site keeps its existing status write.

> Extracting the classifier means `OutboxDispatchServiceUnitTest` no longer needs to test parsing logic; it tests
> *wiring* (counter fires, `markSent` still called), while `OmsResponseClassifierUnitTest` owns the shape matrix.
> That is a better split than r2's single fat test class.

---

## 6. Implementation steps

### 6.1 Prerequisites

| Category | Applies? | Detail |
|---|---|---|
| DB state | **YES** | Flyway `V2.2.05`. Confirm head is still `V2.2.04`; renumber if another plan lands first. |
| Sysprops | **YES** | `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` seeded `false`, **inert in Phase 1**. |
| Config / env | No | No `application.properties` change; cron and lock `100008L` unchanged. |
| Deploy order | No | Self-contained; no OMS-side change. |
| Data migration | No | D4 — no backfill. |
| External systems | No | WMS reads the envelope OMS already sends. |
| Access | **YES** | Tenant DB for `flyway migrate`; Prometheus/Grafana for Step 8. |
| Monitoring | **YES** | Two new counters need panels + an alert before Phase 2. |

### 6.2 Checklist

- [ ] **Step 1 — Capture the body corpus.** Before writing code, extract the distinct `answer` shapes from the
      live table into test fixtures:
      `SELECT DISTINCT left(answer,300) FROM message WHERE status='SENT' AND statuscodeanswer='200' AND created >= '2026-01-01';`
      These become E1's inputs. **Do this first** — r1's central error was writing the detector without ever
      looking at a real body.
- [ ] **Step 2 — TDD gate.** Author E1–E8 against unmodified production code. E2/E3/E5/E6/E8 must FAIL; E1 and E7
      must PASS (they assert current behavior, which Phase 1 preserves). Use `wms-tdd-gate`.
- [x] **Step 3 — Baseline the verify script.** Re-captured 2026-07-28 on unmodified `develop` after the r3 scope
      widening: **`Result: 14 pass, 43 fail, 1 skip`** (was 12/34/1 at r2 scope). The 14 baseline passes are
      Phase-1 inertness guards (`P1-*`, `B3-sent`) plus negative guards vacuously true before implementation
      (`A-notnarrow`, `A-notdup`, `B-not*`, `E-buggone`, `E-orig`, `E-never`). All 43 implementation checks fail
      as they should.
- [ ] **Step 4 — Fix A.** Classifier + enum. `mvn clean compile`.
- [ ] **Step 5 — Fix B.** Wire the 2xx branch. **STOP condition: E1 must still pass.** If E1 fails, Phase 1 has
      changed delivery behavior and the implementation is wrong. (This replaces r1's "10 tests unmodified" gate,
      which could not fail.)
- [ ] **Step 6 — Fix D.** `V2.2.05`; diff the column list against `V2.2.04`.
- [ ] **Step 7 — Tests green.** `mvn test -Dtest=OutboxDispatchServiceUnitTest,OutboxDispatcherJobUnitTest`.
- [ ] **Step 8 — Alert rule (named owner + date required).** Panels for both counters; alert on
      `rate(wms2_outbox_oms_rejected[1h]) > 0` **by tenant**, and on `response_envelope{recognized="no"} > 0`.
      r1 left this optional and ownerless, which is why §11 risk 4 rates the mitigation weak.
- [ ] **Step 9 — Fix F.** Doc + `last_verified`.
- [ ] **Step 10 — Acceptance.** Verify script `Result: N pass, 0 fail`; paste the line.
- [ ] **Step 11 — Full regression.** `mvn test`. Expect the 4 known `develop` failures, no new ones.
- [ ] **Step 12 — Observe 7 days; produce a RETRYABILITY CLASSIFICATION and confirm the rate moved.** Two
      deliverables, not a rate:
      1. Bucket every distinct `Message` into retryable-transient / permanently-unretryable / partial-outcome
         with counts. §1.2's table is the starting point — **~40% are partial outcomes** for which neither
         `markRetry` nor `markTerminal` is correct, and Phase 2 needs a third answer for them.
      2. Confirm [SBDEV-2737](https://app.clickup.com/t/868kgp4cb) actually moved the rate. **Phase 2 does not
         start until it has** (§12 Q6). Exclude `E2E-*`/`SMOKE-*` BOLs from the comparison — they are ~35% of
         volume and will otherwise mask the improvement.
- [ ] **Step 13 — Update §14 Implementation Status** before sign-off.

---

## 7. Testing plan

### Unit
`OutboxDispatchServiceUnitTest` — E1–E8 per Fix E. The 10 existing remain as a smoke gate (not an inertness proof).

### Integration
**None.** Pure in-process predicate over a string already in hand: no new SQL, HTTP call, or transaction. The v2
Testcontainers lane cannot boot ([[wms2-it-harness-broken-sbdev-2217]]). Flyway is exercised by provisioning.

### Manual test plan

| # | Scenario | Env | Steps | Expected |
|---|---|---|---|---|
| 1 | Shape (a) counted, delivery unchanged | dev (wineco) | Trigger a BOL close OMS rejects (occurs naturally at ~70%) | `oms_rejected{tenant="wineco",processType="ORDER_BATCH_SHIPPED"}` ≥1; WARN log; **outbox row still `SENT`** |
| 2 | Shape (b) counted | dev | Trigger a picking notification with an unmatched parcel | `oms_rejected{processType="ORDER_BATCH_PICKING_FINISHED"}` ≥1 — **the case r1 would have missed** |
| 3 | Happy path unaffected | dev | Trigger an accepted notification | `oms_rejected` unchanged; `dispatched{outcome="sent"}` +1; `response_envelope{recognized="yes"}` +1 |
| 4 | Unknown shape self-alarms | dev | Point one row at an endpoint returning `{"ok":true}` | `response_envelope{recognized="no"}` +1; `oms_rejected` unchanged |
| 5 | Metric ↔ table cross-validation | dev | Compare 7-day counter total against the §1.2 substring query for the same window | **Must agree.** Divergence means the classifier and the evidence query disagree — the exact r1 failure |
| 6 | Sysprop seeded and inert | dev | `SELECT sysvalue FROM los_sysprop WHERE syskey='OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED'` | One row `false`; behavior identical either way |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Integration / Testcontainers | No new SQL or HTTP surface; harness broken (SBDEV-2217). |
| OMS-side test | No OMS change in this plan. |
| Load test | One `readTree` per dispatched message, batch-bounded, off the request path. Bodies verified small: max 453 B, p99 315 B across all 613 rejection bodies. |

---

## 8. Horizontal scalability validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | No | `classifyOmsResponse` is a pure function. No field/cache/ThreadLocal added. |
| 2 | Connection pool | No | No DB call added; runs in dispatcher Phase 2, which holds no transaction (class javadoc `:31-42`). |
| 3 | Scheduled jobs | No | No new `@Scheduled`; lock `100008L` unchanged — one replica dispatches, so counters are not multiplied. |
| 4 | Long transactions | No | In-memory parse, microseconds, outside any tx. |
| 5 | Request affinity | N/A | Cron path. |
| 6 | Retry / idempotency | No change | No state transition altered. Counter may double-count if a replica crashes between POST and `markSent` — same pre-existing window as `outcome="sent"`. |
| 7 | Tenant context | **Yes — now used** | Reads `TenantContext` for tags, inside the existing per-tenant loop (`OutboxDispatcherJob:87`). No `@Async`. |
| 8 | Distributed lock | No | None acquired. |
| 9 | Cache invalidation | No | No cached entity written. |
| 10 | External notifications | No | Adds no send. |

**Cardinality check for row 7:** `oms_rejected` = tenants × facilities × 9 process types; `response_envelope`
doubles that. Bounded by active tenant count — the same bound `wms2.outbox.stuck_aggregate` already accepts.

## 9. v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | N/A | Operates on a `String`; no entity or lazy association. |
| 2 | Transaction manager | N/A | `dispatchOne` deliberately non-transactional; `markSent` is `REQUIRES_NEW` in `OutboxService`, unchanged. |
| 3 | `readOnly=true` | N/A | No new service read method. |
| 4 | Caffeine invalidation | N/A | No cached type written. |
| 5 | Jakarta namespace | N/A | No new imports beyond `Tags`; `JsonNode`/`ObjectNode` already imported. |
| 6 | H2-compatible test SQL | Yes — satisfied | Tests are pure unit with mocks; the migration's `nextval('seqentities')` runs only in provisioning. |
| 7 | `BaseControllerTest` | N/A | No controller change. |
| 8 | Micrometer | Yes | Two new counters; existing names checked first; tagging matches `stuck_aggregate` precedent. |

## 10. Acceptance

Verify script: `sbdocs/9-System/scripts/verify-SBDEV-2736-outbox-dispatcher-status-blind-rejection.sh`
**Required: `Result: N pass, 0 fail`.**

Criteria for `wms-tdd-gate`:

1. A 2xx whose body is **shape (a)** `{"Status":"Error",...}` increments `wms2.outbox.oms_rejected` tagged with tenant, facility, and process type. *(Log-content assertion deliberately excluded — §12 Q8. The WARN log ships; it is not an acceptance criterion.)*
2. A 2xx whose body is **shape (b)** `{"status":"success","data":{"Status":"Error",...}}` increments the same counter identically. *(This is the criterion r1 had inverted.)*
3. A 2xx whose verdict resolves to `Success` in either shape increments neither the rejected counter nor a WARN log.
4. A body carrying a non-`Success`, non-`Error` verdict (e.g. `Partially Failed`) counts as rejected.
5. A 2xx that is empty, non-JSON, a JSON array, or an object with no resolvable `Status` in either position increments `wms2.outbox.response_envelope{recognized="no"}`, does **not** increment `oms_rejected`, and never throws.
6. **Inertness:** for every body in the captured corpus — including all of the above — `markSent` is called, `markTerminal`/`markRetry` are never called, `dispatched{outcome="sent"}` increments exactly once, and the `createMessage` argument tuple is byte-identical to the pre-change `200`/`"OK"` case.
7. A `RuntimeException` thrown from inside the classifier still results in `markSent` and never `markRetry`/`markTerminal`.
8. `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` exists in `los_sysprop` with value `false` after `flyway migrate`. *(Manual — §7 scenario 6, not unit-testable.)*
9. **A shape-(c) body whose verdict is on the accept-list but which reports per-record failures (`records_failed > 0` or a non-empty `failed_records`) classifies as `REJECTED`, not `ACCEPTED`.** *(Added r5. AC-1..AC-8 contained no criterion covering shape (c) at all, so the declared merge gate scored an identical `57 pass, 0 fail` on the implementation that reported zero export rejections per month — the gate could not distinguish it from a correct one. The check now discriminates: the r4 classifier scores 65/5, the r5 classifier 70/0.)*
10. The same downgrade applies to a shape-(a)/(b) `Success` verdict carrying those fields. *(No production body does today — 0 of 1,183,372 — so this is a no-op guard against an envelope convergence ahead of SBDEV-2738.)*
11. The evidence fields are matched leniently: `records_failed` via `asLong(0)` (OMS is PHP and may emit `"1"`) and `failed_records` via `isContainerNode()` (`json_encode` emits an object for a re-keyed PHP array).

## 11. Risks & mitigations

| # | Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|---|
| 1 | **Log volume at the true rate.** ~18 real-BOL rejections/month on wineco-dev `ORDER_BATCH_SHIPPED` (~38/month including E2E), plus the picking family. r1 understated this. | Log noise | Medium | `LOG.warn` not ERROR (Fix B); counter is the alerting surface. Volume should fall sharply once SBDEV-2737 lands — re-evaluate at Step 12. |
| 2 | Classifier false-positive on a non-legacy destination | Spurious WARN + counter | Low | All 16 enqueue sites target legacy OMS (§0.2). Two closed structural anchors; anything else is `UNRECOGNIZED`, not `REJECTED`. E6 pins this. |
| 3 | **Phase 2 `markTerminal` permanently wedges aggregates.** `OutboxMessageRepository.java:39-45` excludes any aggregate with an earlier sibling in `FAILED_TERMINAL`; `:73` — such rows are never auto-deleted and need operator action. At the current rate that is ~18 wedged aggregates/month/tenant. | Pipeline jam | **High if Phase 2 ran today** | Three layers: (a) **Phase 2 is now gated on SBDEV-2737** (§12 Q6), so it is designed against a post-fix rate; (b) **Phase 2 defaults to `markRetry`**, reserving `markTerminal` for classified-unretryable messages; (c) Step 12's classification is the required input. |
| 4 | **Phase 2 never happens; well-instrumented bug.** | Divergence stays unfixed but visible | **Lower after Q6** | The amended phasing changes this materially: the *actual* defect is now its own prioritized ticket (SBDEV-2737) rather than something Phase 2 was implicitly carrying, so the worst case is "the dispatcher stays Status-blind while the dominant rejection is fixed anyway" — much better than r1's worst case. Remaining mitigations: Step 8 alert with named owner; Step 12 produces a decision input; the seeded sysprop makes Phase 2 a config flip. **Honest caveat: only the sysprop is a mechanism; the rest is process.** |
| 5 | Detector and evidence query measure different sets | Untrustworthy baseline — **this is what happened in r1** | Low after fix | §7 scenario 5 cross-validates counter vs table over the same window. `recognized="no"` catches shape drift. |
| 6 | **`INVENTORY_FULL_EXPORT` will light the counter up immediately.** 701 rejections since 2025-01, ~1/day ongoing. Fix B3 makes them visible on day one — which is the point, but it means the counter is non-zero from the first deploy and the alert must not be read as "the fix broke something". Additionally its `Partially Failed` bodies are partial successes counted as rejections by negative-space matching. | Alert noise / misread on rollout | **High — expected, not a defect** | Land [SBDEV-2748](https://app.clickup.com/t/868khcak2) first if possible; it removes 575 of the 701. Tag the counter by `processType` so `INVENTORY_FULL_EXPORT` can be alerted separately. Decide the `Partially Failed` treatment before Phase 2 (Fix A note). |
| 7 | Only `MessageService` manual-resend stays unclassified (§0.4) | Negligible | Accepted | Operator sees the response directly on that surface. |

## 12. Open questions / resolved decisions

### Resolved before drafting

| # | Decision | Chosen | Rationale |
|---|---|---|---|
| D1 | Failure mode | Observe first, then enforce | 16 call sites, no baseline. **Premise now challenged — see Q6.** |
| D2 | Scope | ~~Outbox dispatcher only~~ → **AMENDED 2026-07-28: all three WMS→OMS egress paths** | Original rationale (legacy path has no persisted delivery state; being migrated away) was sound in the abstract but **empirically wrong about where the failures are**. Production shows 95.5% of rejections on the direct-POST path the exclusion covered, including 575 occurrences of a single unmapped SKU failing daily for 19 months ([SBDEV-2748](https://app.clickup.com/t/868khcak2)). Outbox-only would have detected 9 events in 19 months, ~0 after SBDEV-2737. See §0.3. Cost of widening is small — the classifier is a pure function, so it is 2 extra call sites in the same PR. |
| D3 | Rollout | Sysprop-gated default OFF | Repo precedent (SBDEV-1666/1762). Seeded in Phase 1, consumed in Phase 2. |
| D4 | Backfill | None | Forward-only; service-log rows retain bodies. |

### Resolved during ralplan review

| # | Question | Resolution |
|---|---|---|
| Q1 | Inert sysprop + seed in Phase 1, or defer? | **Split.** Ship Fix D (seed) — it delivers the config-flip property. Defer the Java constant to Phase 2 — an unread constant cannot be type-checked against the migration literal, so it buys nothing, and it broke the plan's own verify check. Phase 2's first test asserts the key resolves. |
| Q2 | `LOG.error` or `WARN` in Phase 1? | **WARN.** An ERROR the system declines to act on trains operators to filter it. ERROR in Phase 2 where the outcome changes. |
| Q3 | Does the 7-day window gate merge? | **No — post-merge** (you must deploy to observe). But r1 had no merge gate that could fail; E1's corpus test is now the pre-merge gate. The window gates **Phase 2 planning**. |

### Resolved after review (user decisions, 2026-07-27)

| # | Question | Resolution |
|---|---|---|
| **Q6** | **Does the real rate invalidate D1's phasing?** | **The amendment stands, but for a much weaker reason than any earlier version of this answer claimed.** Exact production measurement (§1.2) puts the empty-BOL rate at **3.0%, ~12/year, with no migration cliff and low practical harm** — not the ~50%, then ~1-in-6, that successively justified making SBDEV-2737 *the* priority. It is now **normal** priority. The residual case for still doing it first is narrow but sound: those ~12/year are the single dominant rejection message, so removing them makes Phase 1's baseline measure something other than a known defect. If SBDEV-2737 slips, **ship Phase 1 anyway** — it no longer depends on it. |
| **Q7** | File the OMS envelope normalization? | **Yes — filed as [SBDEV-2738](https://app.clickup.com/t/868kgp4h6).** Not a blocker for Phase 1 and does **not** replace the WMS classifier (OMS deploys independently). Once it lands, Fix A's two-level lookup can collapse to one level and `response_envelope` becomes the proof the contract stayed normalized. |
| **Q8** | AC-1 log assertion — `ListAppender` or drop? | **Dropped.** The counter assertions carry the acceptance weight and are well-precedented via `SimpleMeterRegistry`. The WARN log still ships (Fix B); it is simply not an acceptance criterion. Avoids introducing a harness with one precedent repo-wide for a non-behavioral assertion. |

### Execution order — CONFIRMED

```
NOW      SBDEV-2737  guard the empty-BOL OMS notification   <-- normal; 3.0% / ~12yr, trivial fix,
                                                                removes the dominant contaminant
                                                                from Phase 1's baseline
         SBDEV-2736  Phase 1 counters (this plan)              ships alongside, inert
         SBDEV-2738  OMS envelope normalization                independent, no coordination

THEN     empty-BOL calls stop  ->  Phase 1 measures what actually remains
LATER    SBDEV-2736  Phase 2 — enforcement behind the seeded sysprop,
                     designed from Step 12's retryability classification
```

Removing the un-satisfiable calls **before** Phase 1's baseline makes the baseline measure something other than a
known defect. But this is now a nice-to-have ordering, not a dependency: **if SBDEV-2737 slips, ship Phase 1
anyway.** Phase 1's content is unaffected — Fixes A/B/D/E/F stand as written.

> **Do not adopt SBDEV-2737 fix option 3** ("refuse to close an empty BOL"). Production BOL names —
> `Bergstrom Cancelled Order`, `Voided Orders 4.1.24`, the `WineCo Close <date>` dailies — indicate closing an
> empty BOL is a **legitimate operator workflow**. Guard the notification, not the close.

## 13. Completeness checklist

| # | Concern | Status |
|---|---|---|
| 0 | **DB verified** | ✓ §1.2 — two tenants, 613+20 rows, shape split, monthly rate; `db_verified: true`. Re-verified in r2 after review corrected the rate and shape claims |
| 1 | All callsites enumerated | ✓ §0.1 (4 in-scope), §0.2 (16 beneficiaries), §0.3 (17 excluded, incl. `StockSummaryExportJob` found in review) |
| 2 | Adjacent bugs | ✓ §0.3 + §2 Bug 2 — three variants of the pattern; two consciously deferred |
| 3 | Backward compatibility | ✓ §3 invariants — no API/schema/state/payload change; existing metric series untouched. Bodies logged: legacy envelopes carry identifiers already in the same table's payload column — no new PII exposure |
| 4 | Concurrency | ✓ §8 rows 6, 8 — no state transition changed; lock `100008L` means one dispatcher replica |
| 5 | Multi-tenant | ✓ §8 row 7 — counters now tenant+facility tagged with cardinality bound stated; sysprop seeded per tenant DB |
| 6 | Error handling | ✓ Fix A `catch (Exception)` with the reason inline; E7 proves it; no new throw path escapes `dispatchOne` |
| 7 | Observability | ✓ Fix B two counters; Step 8 alert with named owner; §11 risks 1 and 5 |
| 8 | Rollback / migration | ✓ Fix D forward-only, idempotent. Code rollback safe (removing additive counters breaks nothing) |
| 9 | Test coverage | ✓ Fix E E1–E8; E1 is the real inertness gate; §7 six manual scenarios; skips justified |
| 10 | Cross-version (v1↔v2) | ✓ **N/A — v2-only.** v1/wms-api has no transactional outbox; its notification path is fire-and-forget with no persisted delivery state, matching the §0.3 exclusion rationale |

## 14. Implementation status

> **MERGED 2026-07-30.** wms2-api PR **[#107](https://github.com/SiteBossInc/wms2-api/pull/107)** merged
> into `develop` (merge commit **`c1de721`**; branch `feature/SBDEV-2736-oms-response-classifier`).
> ClickUp SBDEV-2736 → **on dev**.
>
> **Amended after merge, 2026-07-30.** `V2.2.05` was renamed to `…seed_outbox_sysprop_toggles.sql` and a
> second seed added — `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED` (SBDEV-2381), which was read at
> `OutboxDispatchService:317` but had no Flyway seed and no `*_DEFAULT_VALUE`. Default unchanged (`false`);
> the row exists so the toggle is visible on the Admin screen. Re-applied on `dev_wh01_om1` by deleting the
> `2.2.05` history row and re-migrating — **not** `flyway repair`, which stamps without re-running. Anyone
> holding the pre-amendment `2.2.05` will hit a validation failure and needs the same fix.
>
> **Phase 1 only — the ticket is not resolved.** Delivery semantics are unchanged; every 2xx is still
> marked `SENT`. Phase 2 (enforcement) has not started and does not start until Step 12 below is done.
>
> DB state: DEV `dev_wh01_om1` migrated to `2.2.05` on 2026-07-29, sysprop row confirmed present and
> `false`. UAT's four tenants are still at `2.2.04` and need `V2.2.05` when this reaches `release` —
> see [`wms2-apply-pending-tenant-flyway.md`](../../../2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md).

**Phase 1 implemented 2026-07-29.** Branch `feature/SBDEV-2736-oms-response-classifier` off `origin/develop`.
Three commits — **read all three**, because the first carries a defect the other two remove:

| Commit | What |
|---|---|
| `ada7192` | Fixes A/B1/B2/B3/D/E/F as designed. **Contains the r5 HIGH — do not cherry-pick alone.** |
| `0d04098` | Review pass 1: the shape-(c) per-record-failure downgrade, plus 3 MEDIUM / 6 LOW. |
| *(see git log)* | Review pass 2: lenient evidence typing, uniform downgrade, verify-script discrimination, 3 MEDIUM / 7 LOW. |

| Fix | File | Status |
|---|---|---|
| A | `service/OmsResponseClassifier.java` (NEW) | ✅ **three** anchors, not two — see r4 note below |
| B1 | `service/job/OutboxDispatchService.recordOmsVerdict` | ✅ |
| B2 | `service/OmsNotificationService.recordOmsVerdict` | ✅ |
| B3 | `schedulejob/StockSummaryExportJob.recordOmsVerdict` | ✅ |
| D | `db/migration/V2.2.05__seed_outbox_sysprop_toggles.sql` (NEW) | ✅ head was V2.2.04, no renumber needed |
| E | `unit/service/OmsResponseClassifierUnitTest` (NEW, **48** exec) + `OutboxDispatchServiceUnitTest` (37) + `OmsNotificationServiceUnitTest$FailureCounter` (5) + `StockSummaryExportJobUnitTest$OmsVerdictOnExport` (NEW, 4) | ✅ E1–E8 + **E9**, plus B2/B3 coverage added in review |
| F | `wms2-oms-integration-map.md` §2.5.2 (NEW), `last_verified` → 2026-07-29 | ✅ |

**Results (final, after both review passes).** `mvn test` → **4538 run, 2 failures, 0 errors, 67 skipped**;
both failures are the known `develop` baseline (`OptionalSafetyArchTest` ArchUnit drift,
`MobilePalletizingServiceTest`) — no new ones. `mvn clean compile` clean;
`OmsNotificationConfigContextLoadTest` passes, so the constructor changes wire correctly under Spring.

Verify script: **`Result: 70 pass, 0 fail, 1 skip`** (baseline on clean `develop` was 14/43/1; it was
57/0/1 before the r5 checks were added). **The gate now discriminates** — replay `ada7192`'s classifier
under the current script and it scores **65 pass, 5 fail**. That was the point of the r5 additions: at
57 checks the script scored an identical `57 pass, 0 fail` on the implementation that reported zero
export rejections per month, so the declared merge gate could not tell a correct build from a broken one.

> ⚠️ Running the suite mutates `src/test/resources/archunit_store/5fb3fee0-…`. It was reverted with
> `git checkout --` and is **not** in `ada7192`.

### r4 — what Step 1's corpus changed (2026-07-29)

Capturing the bodies before writing the detector was the plan's own first checklist item, and it contradicted
the plan three times. All three were verified against `wms2-wineco-dev` (1,206,656 rows,
`status='SENT' AND statuscodeanswer='200'`).

1. **There is a third envelope shape.** 12,652 rows carry a lowercase `data.status` and no capital-S `Status`
   anywhere: `{"status":"success","data":{"status":"exported",…}}` (11,636, to 2026-07-13) and
   `{"…,"data":{"status":"SUCCESS",…}}` (1,016, from 2026-07-13 — OMS changed the value mid-July). **Both are
   successes**, and both flow through Fix B3. Under §10 AC-5 as written they were `UNRECOGNIZED`, so
   `response_envelope{recognized="no"}` would have fired 12,652 times for healthy traffic on the
   highest-volume path from the first deploy — burying the 4 rows that are a genuine OMS crash
   (`<b>Fatal error</b>: Call to undefined method OMS\Model\BOL::connection_id()`, HTTP 200) which are the
   only thing that counter exists to surface.
   **Resolved: added a third anchor with an accept-list** (user decision, option B). It cannot be negative
   space — `"exported"` would invert — so this one anchor matches `{success, exported}` and yields
   `UNRECOGNIZED` for anything else, never `REJECTED`.
   **⚠️ See r5 — the accept-list alone was not sufficient and shipped as a defect in the first draft.**
2. **`Partially Failed` is 9,999 rows, not part of the 613.** §1.2 counted only `Status="Error"` (307 + 195 +
   65 + 21 + 18 + 6 + 1 = 613 ✓). Negative-space matching also catches `Partially Failed`, all on
   `INVENTORY_FULL_EXPORT`, so **`oms_rejected` will be ~94% one process type on day one**. §11 risk 6 is real
   but was understated by 16×. The verdicts are genuine loss — the top message is
   `"Unable to locate SKU PNWV20 for client Pike Road Wines"` (1,086 rows,
   [SBDEV-2748](https://app.clickup.com/t/868khcak2)).
3. **Fix B1's sample code broke the fail-open invariant it was written to protect.** It called
   `TenantContext.getCurrentTenant().getTenantName()` inside `dispatchOne`'s try. That returns null when
   unset, and the NPE would be caught by the outer `catch (Exception)` → `markRetry` on a message OMS had
   accepted. Same failure mode as E7, different trigger. Guarded, and pinned by new test **E9**
   `dispatchOne_nullTenantContext_stillMarksSentAndNeverRetries`.

Two verify-script checks were also corrected — they were measuring the wrong thing, not detecting a gap:
`E-count` counted only `@Test` and so under-reported by 3 once the corpus cases became table-driven;
`E-cshapes` used an escaped-JSON pattern that required an unescaped closing quote and could never match a
real Java string literal.

### r5 — code review (2026-07-29): the shape-(c) accept-list was itself a defect

A `code-reviewer` pass on `ada7192` found **1 HIGH, 3 MEDIUM, 6 LOW**. All are fixed; the HIGH matters
because it would have defeated the ticket.

**HIGH — the accept-list reported live partial failures as ACCEPTED.** r4 concluded "both shape-(c) values
are successes" from `data.status` alone, without looking inside the envelope. The reconcile variant carries
per-record outcomes *under* a `SUCCESS` verdict:

```json
{"status":"success","data":{"status":"SUCCESS","records_processed":149,"records_failed":1,
  "failed_records":[{"record":147,"sku":"LKET1","error":"Product with SKU 'LKET1' not found"}]}}
```

**714 of 1,842 export responses in July 2026 look like this — 1,071 dropped records.** Meanwhile shape (a) is
**extinct** on `INVENTORY_FULL_EXPORT` (`Partially Failed` last seen 2025-08-12, `Error` 2025-04-01), so the
9,999 + 307 rows that justified Fix B3 as "the site that matters" are *all historical*. Net effect of the
first draft: `wms2.oms.export_rejected` would have read **zero per month** on the highest-volume path while
~1,071 records/month were being dropped — and Step 12 would have handed Phase 2 a false all-clear.

Fixed by `hasPerRecordFailures`: a shape-(c) accept-list hit is downgraded to `REJECTED` when
`records_failed > 0` or `failed_records` is non-empty. This restores parity with shape (a), which expressed
the same condition as `Status:"Partially Failed"` and was already `REJECTED` by negative space.
**My own fixture `C_RECONCILED` contained `records_failed:1` and asserted ACCEPTED — the test pinned the bug.**

Checked whether shapes (a)/(b) leak the same way: **they do not.** OMS sets `Status:"Error"` whenever
`processed < total` on the order endpoints — zero counter-examples across 731 rows carrying a `total` field.

**MEDIUM — the drift guarantee was overstated.** The plan claims `recognized="no"` makes an unknown OMS shape
announce itself. Both drifts that actually happened (a→c during 2025; `exported`→`SUCCESS` on 2026-07-13)
were *semantic*, not structural, and each was absorbed by widening the accept-list rather than reported. The
counter detects envelopes WMS cannot **parse**, not changes in what they **mean**. Javadoc and §2.5.2 now say
so, and the accept-list is documented as requiring re-validation against a fresh corpus.

**MEDIUM — asymmetric null guard.** `TenantProfile` was null-checked but its *fields* were not;
`TenantDbConfiguration.warehouse` has no `nullable=false`, and Micrometer NPEs on a null tag value — which
would have lost both counters *and* the WARN. Each field is now coalesced, and the WARN moved ahead of tag
construction so the diagnostic survives a tagging failure.

**MEDIUM — `export_rejected` lost the `facility` tag** the plan specified. The job iterates one
`TenantProfile` per tenant+warehouse, so a multi-warehouse tenant (ShipItEZ NY `wh02` + LA `wh01`) collapsed
into one series. Added. `notification.rejected` stays tenant-only **by choice**, to match the
`notification.failed` counter it pairs with.

**MEDIUM — no tests on Fix B2 or B3.** Fix E only ever specified outbox tests. Worse: `OmsNotificationServiceUnitTest`
uses `@InjectMocks`, so the new classifier was injected as **null** and every `recordOmsVerdict` NPE'd into
its own catch — green tests over an unexercised feature, and the reason the HIGH went unnoticed. Both sites
now have rejection, acceptance, and fail-open coverage (7 new tests).

LOWs fixed: stale "not yet consulted" field comment; `"unknown"` literal unified as
`OmsResponseClassifier.UNKNOWN_TENANT`; `.trim()` before the verdict comparison (an untrimmed `" Success "`
falls to `REJECTED`, the dangerous direction); `verifyNoMoreInteractions` on the E1 inertness gate so an
*added* spurious interaction cannot slip through. Two LOWs accepted as-is and recorded rather than changed:
`StockSummaryExportJob` holding a bare `MeterRegistry` alongside `JobMetrics` (the metric belongs to the
`wms2.oms.*` family, not `wms2.cron.<job>.*`), and `recordOmsVerdict` running before `markSent` (matches the
Fix B1 spec; means `response_envelope` can exceed `dispatched{sent}` if `markSent` throws).

The reviewer also **cleared three things I had flagged as risks**: `TenantContext` *is* propagated to the
export consumer thread by `TenantAwareTaskDecorator`, the closed-predicate claim holds, and `V2.2.05` is a
faithful copy of the `V2.2.04` template.

### r6 — second code review (2026-07-29): 0 HIGH, 3 MEDIUM, 7 LOW

A second `code-reviewer` pass confirmed every r5 fix landed correctly and found no new HIGH. The three
MEDIUMs were all about the fix being *under-defended* rather than wrong:

1. **The acceptance gate could not see the defect it exists to catch.** §10 AC-1..AC-8 contained no
   criterion mentioning shape (c), and the verify script scored an identical `57 pass, 0 fail` on both the
   buggy and the fixed classifier — so a future refactor that dropped `hasPerRecordFailures` would stay
   green. Added AC-9/10/11 and 13 script checks; replaying `ada7192`'s classifier now scores **65/5**.
   *This is the finding worth remembering: a 100%-passing gate proved nothing, twice in a row, because
   nobody asked what it would take to make it fail.*
2. **`hasPerRecordFailures` was one PHP serializer change from re-opening the hole.** `records_failed`
   required `isNumber()`, but PHP emits `"1"` for a value that has been through PDO or a string cast;
   `failed_records` required `isArray()`, but `json_encode` emits an *object* for a re-keyed PHP array —
   and the observed entries already carry a `"record":147` index, so that refactor is one step away.
   Now `asLong(0)` and `isContainerNode()`, with tests for both, plus tests proving a garbled value does
   **not** manufacture a rejection (which Phase 2 would re-POST on).
3. **§4 Fix B2 still specified `{tenant, facility, processType}`** while the code emits tenant-only —
   contradicting its own next sentence. Corrected in place rather than only in r5.

Also from r6: the downgrade now applies to **every** shape's success verdict, not just (c). No
shape-(a)/(b) body carries these fields today (**0 of 1,183,372** — verified), so it is a no-op guard, but
it closes the reviewer's open question about an envelope convergence ahead of SBDEV-2738.

LOWs fixed: §14 was stale at `ada7192`; the `notification.rejected` test asserted counter *registration*
but never `.increment()` (deleting the increment would have left it green); a duplicated `verify` line in
the E1 gate; the root-lowercase-`status` blind spot is now documented as deliberate; both WARN sites
truncate the echoed body at 2,000 chars (a rejection body embeds one object per failed record);
`UNKNOWN_TENANT` moved to `WmsConstants.UNKNOWN_TAG_VALUE` (a *classifier* should not own a metrics-tag
literal, and it substitutes for facility and processType too).

**The classifier now owns a private `ObjectMapper`** instead of taking the Spring bean. It only calls
`readTree`, so it needs nothing from the shared configuration — and this removes a real drift risk the
reviewer spotted: the unit tests pinned behaviour under a default mapper while production used the
autoconfigured one, so a future tightening there (`FAIL_ON_TRAILING_TOKENS`, `StreamReadConstraints`)
would have changed verdicts with no test signal.

Two r6 open questions recorded and deliberately not acted on: `hasPerRecordFailures` reads only
`root` and `root.data` (a `data.data` nesting or a differently-named evidence field would be missed), and
no speculative field names were added, because inventing anchors without corpus evidence is exactly the
closed-predicate violation the design forbids. The arch doc's re-validation instruction now covers **the
accept-list and the failure-evidence fields**.

### Deliberately not done in Phase 1

- **Fix C** (Java sysprop constant) — deferred to Phase 2 per Q1. An unread constant cannot be type-checked
  against the migration literal.
- **Behaviour change.** Every 2xx is still `markSent`. E1's 12-case corpus test is the gate that proves it and
  must stay green.
- **Step 8 (alert rules)** and **Step 12 (7-day observation + retryability classification)** are post-merge
  and still open. Phase 2 does not start until Step 12 is done.
- **Backfill** — none, per D4.
