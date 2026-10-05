---
name: wms2-stockrecord-id-not-monotonic-use-created
description: "On a live wms2 DB, new stockrecord rows get ids BELOW max(id) — an id watermark returns 0 rows (false zero); watermark by `created` instead"
metadata:
  node_type: memory
  type: reference
  originSessionId: 2c37db9b-77a2-4f7b-83c6-52cb25e24686
  modified: 2026-09-30T22:57:23.498Z
---

On DEV wineco (`dev_wh01_om1`), 2026-10-01, SBDEV-3605 live test: `max(stockrecord.id)` was 988307865
before a real multi-UL pick. The pick's 8 new rows got ids **31269232–31269240**, far below it. So
`WHERE id > <watermark>` returned **0 rows** while the pick had in fact written everything. It looked
like "nothing was booked", which is exactly the false zero that confirms a hoped-for no-op.

Cause: ids come from a sequence/table allocator that does not track `max(id)`. Historic
migrated/imported rows sit above the live allocator's range.

**How to apply:**
- Watermark live DB changes by `created > now() - interval '…'` (or a captured timestamp), never by id.
- A zero from any "rows after X" probe needs a positive control ([[a-zero-scan-needs-a-positive-control]]).
  Here the control was the stock unit's amount changing 6 → 1 while the id scan said 0.
- IT fixtures on a fresh container may still see monotonic ids. This is a live-DB trap
  ([[wms2-concurrency-it-fixture-traps]] covers the IT-side watermark issues).

DEV test credentials: realm `wineco` on kc2.dev.sbo.li, client `om1`, headers `X-Tenant-ID: wineco`,
`facility_code: wsl`. The account and password come from the user; never store the password.
