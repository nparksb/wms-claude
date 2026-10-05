---
name: wms2-id-watermark-false-zero-on-live-db
description: "\"id > max(id)\" is not a valid \"rows written since\" instrument on a live wms2 DB; new rows get ids far BELOW the max. Verify by a natural key + timestamp"
metadata:
  node_type: memory
  type: feedback
  originSessionId: ffd93f1b-3f2e-47c8-9ee4-eb0786bdfb64
  modified: 2026-09-26T21:41:44.376Z
---

Measured 2026-09-26 while live-testing SBDEV-3546 on WineCo dev. I took `max(id)` of `unitload_record`
(988 308 546), closed a BOL, and queried `id > max` for new rows. It returned **zero**, a clean false
zero. The row existed with id **31 233 713**. Ids are not monotonic across writers (pooled allocation,
plus historical rows imported with high ids), so a watermark can sit above every id the app will issue
for a long time.

**Why:** the false zero read as "the fix wrote nothing", which would have been reported as a production
defect. It is the same instrument failure [[wms2-concurrency-it-fixture-traps]] records for ITs, here on
a live DB.

**How to apply:** to find rows a live action just wrote, filter on a natural key (label, order number,
BOL number) plus a `created > <timestamp taken before the action>` bound. Never use an id watermark.
Treat a zero with a positive control ([[a-zero-scan-needs-a-positive-control]]).
