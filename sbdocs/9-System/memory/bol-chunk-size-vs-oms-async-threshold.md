---
name: bol-chunk-size-vs-oms-async-threshold
description: "WMS BOL-shipped chunk size (40) sits under the OMS finishedShipping async threshold (50), so chunks run synchronously at ~0.19 s/parcel; SBDEV-4073 fix = sysprop 60"
metadata:
  node_type: memory
  type: project
  originSessionId: 3a2d7026-06f3-4515-a6d8-16bea93efd77
  modified: 2026-11-08T12:24:17.049Z
---

WMS `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` (SBDEV-3672, default 40, ceiling 60) and OMS `wms.finished_shipping.async_threshold` (SBDEV-3757, 50; config/wms.php in oms-laravel-api) were built the same day (2026-10-16) for the same 1,528-parcel BOL without knowing about each other. A finishedShipping call over 50 parcels is stored as a receipt and answered at once ("Received N parcels; processing"). At 50 or under it ships synchronously at ~0.19 s/parcel. So 40-parcel chunks each take ~8 s and hold the CLUB lane (c1wh BOL 12245859300: 30 chunks, 239 s).

**Why:** if either side's number changes, re-check the other. Chunks ≤ threshold = slow; > threshold = async, so the WMS marks the BOL delivered before the OMS ships it (failures surface via the OMS watchdog, not the WMS per-BOL status).

**How to apply:** Nam chose sysprop 60 on PRD, config only, no code (SBDEV-4073, 2026-11-08). The PRD OMS env override of the threshold is unverified; the OMS log line `finishedShipping: BOL answered` carries `mode`/`duration_ms`. Related: [[club-oms-chunking-rollout-dropped]] (a different chunk size, club line, stays 1).
