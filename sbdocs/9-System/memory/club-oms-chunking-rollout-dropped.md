---
name: club-oms-chunking-rollout-dropped
description: "SBDEV-3310 WMS_CLUBLINE_OMS_CHUNK_SIZE stays 1 on every PRD tenant; rollout dropped 2026-11-05 — don't re-propose without the 3 prerequisites"
metadata:
  node_type: memory
  type: project
  originSessionId: 6e6ca462-0151-46bb-8bff-76d02a0cf5f6
  modified: 2026-11-05T13:03:47.527Z
---

WineCo PRD rollout of `WMS_CLUBLINE_OMS_CHUNK_SIZE` 1→100 was **dropped** 2026-11-05 (Nam). All PRD tenants stay at 1. wineco DEV restored to 1 on 2026-11-05 (snapshot `chunk3310` diff = restored).

**Why:** Joe reproduced two chunk failures (a terminal 400 holds the whole chunk's later rows, 100 orders at a time; a partial OMS 200 with `failed_records` is marked SENT). The reason for chunking is gone: the CLUB lane (every 3 s, batch 25, since v0.0.26) drained a 357-row WineCo PRD club in 48.5 s (~441 messages/min), so a 328-order club takes ~2¼ min unchunked.

**How to apply:** before anyone sets the value above 1 on any tenant, require (1) per-record `failed_records` handling (SBDEV-2736 Phase 2), (2) requeue or split recovery for `CLUB_BATCH_CHUNK` terminal rows (the SBDEV-3672 requeue is BOL-only), and (3) OMS treating an update to a status a parcel already has as success. Related: [[sbdev3310-club-run]], [[use-wineco-prd-for-data-validation]].

**Stale carriers (corrected 2026-11-07):** SBDEV-4007 was scoped on 2026-11-04, the day *before* the drop. Its ticket §2 ("do this first, set ~100") and §6, and its plan §5.1 row 2 ("→ 100 per tenant"), kept telling readers that chunk size was an open prerequisite. On 2026-11-07 a status check repeated that, and Nam corrected it. All three are now struck through and marked superseded. #623's V2.2.48 also rewrote the config-UI description to "Keep at 1 … larger chunks are not safe yet". Re-read 2026-11-07: `1` on dev, c1wh, nywh-shipitez and nywh-hydra PRD. **If any doc or ticket says to raise this value, the drop overrides it.** Check the SBDEV-3310 rollout comment thread (the ⏸ hold → ❌ drop replies), not the scoping text.

