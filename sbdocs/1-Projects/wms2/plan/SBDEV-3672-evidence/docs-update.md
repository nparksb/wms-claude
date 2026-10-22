---
kind: docs-update
ticket: SBDEV-3672
head: 057d0e3b
ui_head: 63b0a89
date: 2026-10-16
author: SBDEV-3672 docs lane
---

# SBDEV-3672: sbdocs update change log

Source of truth: wms2-api worktree `.claude/worktrees/wms2-api/SBDEV-3672` at `1866ab66`, and wms2-web-ui worktree `.claude/worktrees/wms2-web-ui/SBDEV-3672` at `63b0a89`. All cites were read from those commits with `git show <sha>:<path>`. Every added sentence about behaviour not yet on `develop` carries `⏳ pending-merge(SBDEV-3672)`.

**`last_verified` was not bumped on any doc.** Each touched doc covers far more than this change. The house convention (sysprop catalog, workflow doc) records a scoped check in `verified_by` and leaves `last_verified` alone. I followed that convention: a scoped `verified_by` note where the doc has the field, plus a verification-log row.

## 1. `sbdocs/3-Resources/workflows/wms2-bol-truck-loading-workflow.md`

| Section | Change |
|---|---|
| frontmatter | `updated: 2026-10-16`; scoped `verified_by` note prepended (sections listed, rest NOT re-verified) |
| §1 Overview, the shipped bullet (was `:44`) | "post-commit callback" → outbox enqueue inside the close tx, dispatched after commit; chunking sentence marked |
| §3 Lifecycle diagram (was `:114`) | enqueue shown as a step inside the close tx (1 row or N chunk rows, marked), POST after commit |
| §6.5 (was `:310-319`) | **Rewritten.** Retitled "OMS shipped notification (outbox)". The old `sendAfterCommit` snippet had been stale since SBDEV-2221, and the rewrite corrects it. New subsections: 6.5.1 chunking (a table covering K, who is chunked, the chunk row's aggregate type/id/key/lane CLUB, payload, the 29-attempt retry budget); 6.5.2 the "OMS notification" row (endpoint, the five states and their precedence, the `confirmed` math, the three `NO_RECORD` reasons with their UI text, `lastError` URL redaction, the Service Log link condition, `last_message_id`); 6.5.3 Requeue (who may use it, what it does, the `NONE` reasons, the 409 case, the audit row, the after-commit log and counter); 6.5.4 both R-9 gaps plus the manual-DELETE note; 6.5.5 the legacy oversized row, linking to the plan's §7 recipe |
| §7 OMS Callbacks (was `:329`) | SHIPPED row: the stale `closeBOL (line 653)` → `runShippingPhase`, outbox enqueue `:786`; footnote that SHIPPED is the outbox exception to "post-commit only" |
| §9 REST Endpoints | two rows: `GET omsNotificationStatus/{id}` (617) and `POST requeueOmsNotification/{id}` (629) |
| §12 How to debug | one row: "BOL detail says OMS notification failed" |
| §13 Verification Log | one row for this change |

## 2. `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md`

| Section | Change |
|---|---|
| §2.2 `ORDER_BATCH_SHIPPED` row (`:112`) | Payload cell: one BOL becomes 1..N POSTs. The rule covers K, the default 40, the clamp 60, REGULAR/HUB_AND_SPOKE only, `BILL_OF_LADING_CHUNK` on lane CLUB, `chunk_index`/`chunk_count`, and the fact that transfers and BOLs with ≤ K parcels keep one row and an unchanged payload |
| §2.2, new note under the table | the status and requeue endpoints, and the audit row never sent to OMS; points to workflow §6.5 |
| §2.8 outbox retry paragraph (the retry row) | per-process-type budget: 29 attempts for `ORDER_BATCH_SHIPPED` (≈24 h, 1 h cap, 30 POSTs), 5 for everything else, 400/404/422 terminal at once |

`last_verified` was not bumped. The doc has no verification log, so none was added.

## 3. `sbdocs/3-Resources/data-dictionary/wms2-sysprop-catalog.md`

| Section | Change |
|---|---|
| §4.7 OutboxDispatcherJob properties | new row `app.outbox.dispatcher.bol-shipped-max-attempts` = `29` |
| §10 Shipping | new row `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE`, covering: seed (`40`, V2.2.40), the `los_sysprop` group `Operation Options` / `workstation='DEFAULT'` / `client_id=0` and its idempotent guard, where it is read (once per close, `BillofladingService.java:844` → `resolveChunkSize` `:58`), the fallbacks (blank → 40 silently; non-numeric or < 1 → 40 with a WARN; > 60 → 60 with a WARN; never throws) and the seed-consistency test |
| §11.1 seeds table | row `V2.2.40 — NOT merged`, excluded from the counts like V2.2.27 |
| §11.2 | row: a numeric chunk size, not a gate; absent and seeded behave the same |
| frontmatter `verified_by` | scoped note prepended; `last_verified` unchanged |
| §14 Verification Log | one row |

## 4. `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md`

| Section | Change |
|---|---|
| §4.8 `OutboxDispatcherJob`, Retry policy row | budget per process type (29 for `ORDER_BATCH_SHIPPED`, 5 otherwise) |
| §4.8, new Lanes row | DEFAULT and CLUB lanes on separate locks; CLUB now also carries every BOL chunk row, while an unchunked BOL row stays on DEFAULT; one sentence on the R-3 cross-tenant cost (tenants run sequentially per tick) |
| frontmatter | `updated: 2026-10-16`; scoped `verified_by` note; `last_verified` unchanged |
| §10 Verification Log | one row |

## 5. `sbdocs/3-Resources/architecture/wms2-entity-enumeration-report.md`

| Section | Change |
|---|---|
| `OutboxMessage` row | `outbox_message.last_message_id`: nullable bigint, no default, no FK, written only for `ORDER_BATCH_SHIPPED`. It is native-only and deliberately not mapped, because a tenant whose V2.2.40 migration failed must keep claiming and dispatching (`RETURNING *` maps entity columns only) |
| Verification Log | one row |

`last_verified` was not bumped.

## 6. SBDEV-3325 egress watchdog README: NOT edited (it lives outside sbdocs)

The README is `scripts/oms-egress-watchdog/README.md` **in the wms2-api repo**. SBDEV-3672 does not touch it at `1866ab66`. Per the brief, I did not edit it. Proposed text for the API lane to add under **"Day to day"**, after the `WATCHDOG_ACK` bullet:

> - **A poisoned BOL-shipped row (SBDEV-3672).** An `ORDER_BATCH_SHIPPED` outbox row now retries for
>   ~24 h (29 attempts) before it goes `FAILED_TERMINAL`, so on a low-traffic tenant one bad row can
>   keep `failing` red for a day. Once the row is owned, set `WATCHDOG_ACK` to the finding's whole key,
>   copied from the summary line (e.g. `<tenant>/<warehouse> failing message:ORDER_BATCH_SHIPPED`), and
>   remove the ack after the row is requeued or closed.
> - **Requeue audit rows are excluded by design.** The BOL screen's Requeue writes a Service Log row
>   with process `ORDER_BATCH_SHIPPED_REQUEUE`, destination `'N/A'` and code `REQUEUE`. `'N/A'` is this
>   watchdog's own inbound exclusion (`egress-failures.sql:91`), so those rows are never graded. Any
>   change to that exclusion must keep `OmsEgressWatchdogQueryIT#requeueAuditRows_yieldZeroFindings`
>   green.

Its "What it does NOT cover → Partial failure" bullet (which cites SBDEV-3672) may also want a line saying that the outbox retries are now ~24 h for BOL-shipped rows. That is optional.

## 7. Code ≠ plan, as documented

- **Legacy threshold.** The plan says "parcels > K". The code uses the fixed ceiling, **60** (`BolOmsNotificationService.legacyParcels`, `:290`, `CHUNK_SIZE_CEILING`), so lowering K never turns a sendable row "legacy". Workflow §6.5.5 says "more than 60 parcels".
- The other brief-listed differences (V2.2.40; both native queries fenced on `process_type`; `lastError` URL redaction; after-commit counter and log; the `process_type` tag on `service_log_link.failed`) are written as the code has them.

## 8. Found but not fixed (pre-existing, out of scope)

- `wms2-sysprop-catalog.md` §4.7 still says `app.cron.outbox-dispatcher` = `*/15` and `batch-size` = `10`. `application.properties:213,243` at `1866ab66` has `*/3` and `25`.
- `wms2-oms-integration-map.md` §2.2's SBDEV-2221 note says the dispatcher runs "every 15 s". It runs every 3 s, as above.
- `wms2-oms-integration-map.md` §2 intro (`:82`) still says failed calls "do not retry automatically". That is true only for `sendAfterCommit` sites; §2.8 qualifies it.
- `wms2-sysprop-catalog.md` has no row for `WMS_CLUBLINE_OMS_CHUNK_SIZE` (`WmsConstants.java:1400`), the sibling key K's resolver copies.

## 9. Not verified

- No Maven or yarn run (a suite was running in the API worktree; docs only).
- Markdown rendering was not previewed in Obsidian. The edited tables keep their column counts.
- This lane does not review its own work. An independent reviewer still needs to check these edits.

## 10. Review fixes (2026-10-16)

These fix the "Docs lane review" findings in `conformance-verifier.md`. All of them are in `wms2-bol-truck-loading-workflow.md` §6.5. I re-checked every cite at `1866ab66` / `63b0a89`. **Convention adopted for L1:** one marker per claim sentence, not one per paragraph.

| Finding | Fix |
|---|---|
| M1 (§6.5.2 opening paragraph, sentences 2–3) | Each sentence now carries a marker |
| M2 (§6.5.2 UI paragraph, last sentence, `last_message_id`) | Marker added |
| M3 (§6.5 intro, `enqueueBolShippedNotification`) | That sentence now says the helper exists only on the branch, that the paragraph's line numbers are at `1866ab66`, and that develop has the skip and enqueue at about `:779-806`. It carries a marker. The SBDEV-2221 and SBDEV-2737 sentences stay unmarked (they are merged) |
| L1 (§6.5.2 UI paragraph, §6.5.3 What it does / 409 / Audit row, §6.5.4 intro, both list items and closing, §6.5.5) | The single trailing marker is split, so each claim sentence carries its own |
| L2 (`.vue:226`) | Now `:102` (`v-if="canViewMessages && chunk.messagePresent"`), with `canViewMessages` at `:226` |
| L3 (`.vue:118`) | Button `:118`, its `v-if="omsStatus.failed > 0"` at `:109` |
| L4 (`BolOmsNotificationService.java:115`) | Now `:126`, the `findBolNotificationRows` call. The fence itself stays cited at `OutboxMessageRepository.java:109-120` |

**Marker count in the workflow doc:** 26 → 49, all spelled exactly `⏳ pending-merge(SBDEV-3672)`. The other four docs are unchanged.

## 11. Re-cite at 057d0e3b (2026-10-16)

`git diff --stat 1866ab66 057d0e3b -- src/main scripts` shows three changed files:
- `BolOmsNotificationService.java`: host-aware `lastError` redaction; +9 lines above most cites.
- `OutboxDispatchService.java`: comment reworded in place; no lines moved.
- the watchdog README.

Every other cited file is byte-identical, so no other cite in the 5 docs changed. Only the workflow doc cites `BolOmsNotificationService` or describes the redaction. All changes below are in `wms2-bol-truck-loading-workflow.md`:

| Where | Was (1866ab66) | Now (057d0e3b) |
|---|---|---|
| §6.5.2, status query call | `BolOmsNotificationService.java:126` | `:131` |
| §6.5.2, confirmed math | `:152-153` | `:161-162` |
| §6.5.2, `noRecordReason` | `:237-246` | `:246-255` |
| §6.5.2, `redactedLastError` | `:276` | `:289` |
| §6.5.3, requeue tx | `:167-228` | `:176-237` |
| §6.5.3, audit write | `:62-69,210` | `:62-69,219` |
| §6.5.3, after-commit log and counter | `:222-225` | `:231-234` |
| §6.5.5, legacy label | `:290` | `:319` |
| §6.5 italic note and M3 sentence | "at `1866ab66`" | "at `057d0e3b`" (`BillofladingService` lines unchanged) |

Content changes in the same doc:
- **Redaction (§6.5.2).** Every URL becomes `<oms-url>`. Then every remaining occurrence of the OMS host, matched case-insensitively, becomes `<oms-host>`. The host is taken from the **current** `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop, so a bare host from an earlier endpoint is not caught. The result is then cut to 300 characters. Each sentence carries a marker (50 markers total in the doc).
- **Legacy label (§6.5.5).** Now reads "more than 60 parcels (`CHUNK_SIZE_CEILING`, not today's K)", matching amended plan A-L6.
- **Records.** `verified_by` and the §13 log row note the re-cite.

**Watchdog README.** The API lane has now edited it (`scripts/oms-egress-watchdog/README.md`, +14 lines in `0f54c0bf`), so the proposal in §6 is superseded by the repo text. I did not review that text here.
