---
name: wms1-aftercommit-message-rows-silently-lost
description: v1 createServiceLog lacks REQUIRES_NEW, so every Message row written from an afterCommit callback is silently discarded
metadata:
  type: project
---

**v1/wms-api `MessageService.createServiceLog` carries NO `@Transactional`.** Called from a
`TransactionSynchronization.afterCommit()` callback, `messageRepository.save()` joins the
already-committed outer transaction as a non-new participant, so the INSERT is never flushed and
is discarded when the persistence context closes — no exception, no log line.
(v2/wms2-api's copy IS `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW)`.)

Live on v1 prod (both `wms1-shipitez1` and `wms1-wineco`), found 2026-09-08. **Three commits, three
release tags, three different cliff dates — each matches its own deploy, which is what proves the
mechanism.** A process type survives only while it still has a producer that is NOT an afterCommit
callback:

| commit | deferred | first tag | tag date | observed last row |
|---|---|---|---|---|
| `9c78f1c` | TOTE_ASSIGNED (`MobilePickingService.processPick`) + PICKING_STARTED (`confirmPick`) | v1.26.15 | 2026-03-04 | wineco TOTE_ASSIGNED 2026-03-04 14:30 |
| `0f8deca` | PICKING_FINISHED (`finishPickingOrder`) | v1.26.17 | 2026-03-05 | shipitez PICK_PACK FINISHED 2026-03-06 08:21 |
| `f46cf06` | the CLUB path, all three (`runClubLine`) | v1.26.38 | 2026-06-15 | wineco CLUB 2026-06-30 |

TOTE_ASSIGNED died first and alone because `processPick` was its only live producer. STARTED and
FINISHED limped on for three more months **on club volume only** — `runClubLine` still called them
directly until v1.26.38. Confirm the split by payload shape: club sends a UUID `tote_label`,
PICK_PACK sends `C1-…`. On wineco 100% of FINISHED rows are UUID-shaped from April on.

Do not read the aggregate monthly counts as one cliff; they are three.

⚠ **The HTTP POST still fires** — proved by 30 217 burned message numbers
([[burned-sequence-numbers-prove-a-code-path-ran]]), since `createMessage` runs only after
`httpRestService.post` returns. So this is an **audit-trail** outage, not (necessarily) a delivery
outage. Do not read "0 message rows" as "OMS was never told".

Two things compound it: `catch (IOException e)` is dead code (RESTEasy throws unchecked
`ProcessingException`), so a real failure leaves no FAILED row either; and
`PickingorderBusinessService` sets `pickingconfirmationsent = true` *inside* the tx before the
deferred call, so that column is `true` for every affected order and is useless as a backfill
predicate. Nothing anywhere reads it for retry.

**Why:** afterCommit is documented by Spring as "no commit following anymore — use REQUIRES_NEW";
this codebase already had `createMessageInNewTransaction` (used only by `BolClosedEventListener`)
and never applied it here.

**How to apply:** any DB write inside an afterCommit callback in v1 must go through a
`REQUIRES_NEW` service method. See [[wms1-oms-notification-plan-claims-a-fix-that-never-existed]].
