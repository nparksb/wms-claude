---
name: wms-unitload-relabel-and-return-record-shape-traps
description: "unitload.labelid is rewritten '{label}-X-{id}' on SEND_TO_NIRWANA while stockrecord/unitload_record keep the original; RETURN put-away row was CREATED (not TRANSFERRED) 2025-Q1..2026-Q1"
metadata:
  node_type: memory
  type: project
  originSessionId: 06978fd3-437b-442a-afc0-0f52f2436a5f
  modified: 2026-10-13T16:10:00.849Z
---

Two join traps on WMS v2 unit-load history, both measured on WineCo PRD 2026-10-13 (SBDEV-3736):

1. **Relabel trap.** Emptied unit loads are not deleted; SEND_TO_NIRWANA rewrites `unitload.labelid` to
   `{label}-X-{unitload.id}` (UL349197 → UL349197-X-33258969). `stockrecord.tounitload` and
   `unitload_record.label` keep the ORIGINAL label. A label join blanked 538/626 (86%) of 180-day return ULs.
   Join unit loads by id (e.g. `goodsreceiptposition.unitload_id`); compare labels only after
   `regexp_replace(labelid, '-X-[0-9]+$', '')`.
2. **Record-shape drift.** The RETURN put-away row in `unitload_record` was a second `CREATED` row
   (InboundWorkstation→PutAwayLane, with ordernumber) from ~2025-Q1 to 2026-Q1, `TRANSFERRED` before and after.
   Filtering on `recordtype='TRANSFERRED'` blanked 22.4% of all-time positions. Key on
   `ordernumber = adviceposition.number AND activitycode='RETURN'`, any recordtype.

**Why:** both traps passed a test on fixtures from the "clean" era. Both were caught only by an adversarial
reviewer picking a different era. Same lesson as [[a-test-can-pass-for-the-wrong-reason-vary-the-fixture]].

**How to apply:** when a query traces unit loads or unitload_record over history, test it on one advice per era
(2024, 2025, v1-relabelled, live v2). `unitload_record` has no index beyond the pkey (~6.8M rows). Per-row LATERAL
lookups time out at 30s; use a set-based `DISTINCT ON` subquery plus a hash join instead.
