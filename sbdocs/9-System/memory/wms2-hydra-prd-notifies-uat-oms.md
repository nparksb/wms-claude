---
name: wms2-hydra-prd-notifies-uat-oms
description: Hydra PRD has 3 WEBSERVICE_* sysprops pointing at the UAT OMS host; 188 notifications got 404 and were all recorded SENT
metadata:
  type: project
---

Measured 2026-09-10 on `wms2-hydra` (PRD), found while investigating SBDEV-3311. **Three of 23
`WEBSERVICE_*` sysprops on production point at `api-oms-uat.siteboss.net`**; the other 20 point at
`api-oms.sbo.li`:

- `WEBSERVICE_ORDER_BATCH_PALLETIZED` — **152** message rows, 2026-07-16 → 2026-09-10
- `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` — **36** rows, 2026-07-15 → 2026-09-10
- `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` — 0 rows

**Every one of the 188 got HTTP `404` and every one is recorded `status = SENT`.** So prd OMS has
never received a palletized or loaded-to-truck notification for those events (two months of silent
divergence), the payloads did leave prd for a UAT endpoint, and the `message` table hides both.
These two process types go through the legacy `sendAfterCommit` path, not the outbox, which records
`SENT` without consulting the status code — related to [[wms2-outbox-dispatcher-status-blind-silent-loss]]
and [[wms2-sendaftercommit-guard-is-inverted]] but a distinct defect: the *status recording*, not the guard.

**A 404 recorded as SENT means "process type absent from `message`" and "process type failing" look
alike.** Never read a `SENT` row as delivery — join `destination` and `statuscodeanswer`.

Proposed to Nam 2026-09-10, not filed (T3, prd data integrity). Unrelated to SBDEV-3311.
