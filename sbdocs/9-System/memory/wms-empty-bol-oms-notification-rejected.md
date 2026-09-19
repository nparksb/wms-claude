---
name: wms-empty-bol-oms-notification-rejected
description: "WMS closes BOLs with zero positions (3.0% of shipments, ~12/yr, legit operator workflow) and notifies OMS with positions:[]; OMS has ALWAYS rejected these, so every one is a silent loss under the Status-blind dispatcher. SBDEV-2737. Measurement landmines inside."
metadata: 
  node_type: memory
  type: project
  originSessionId: b569dc6d-2bf6-4ec2-b56e-388516b2932c
  modified: 2026-07-27T19:39:41.623Z
---

`closeBOL` has **no guard** against a zero-position BOL. It closes, then enqueues an `ORDER_BATCH_SHIPPED`
notification with `{"positions":[], ...}` (`BillofladingService.java:657` builds it, `:688` enqueues). OMS rejects
every one at `LegacyWmsController.php:1759-1764` (`if (!count($params['positions']))`) — **with HTTP 200**, so
[[wms2-outbox-dispatcher-status-blind-silent-loss]] records it as a successful delivery and it is invisible.

**Exact production numbers** (measured on `wsl-wineco-uat`, the migrated copy of WineCo production, over all
2,852 `ORDER_BATCH_SHIPPED` messages 2019–2026): **86 empty / 86 rejected / 0 empty-but-accepted /
0 nonempty-but-rejected.** Perfect correlation. **3.0% overall, ~12/year**, flat across both OMS generations
(2.4% in 2020 on legacy, 3.6% in 2026 on v2).

**NOT an OMS v1→v2 port regression and NO migration cliff** — both OMS generations always rejected empty-position
sends. (An earlier analysis claimed legacy accepted ~78%; that was the substring-filter artifact below.)

**Closing an empty BOL is a LEGITIMATE workflow — do not "fix" it by blocking the close.** Real affected BOLs:
`WineCo Close 7-13-25`, `ADV Close`, `WVV Close 2-2026`, `Audeant Hold Orders`, `Bergstrom Cancelled Order`,
`Voided Orders 4.1.24`, `ARW Will Call 9.3.21`. Guard the *notification*, not the close.

**Why it matters (modestly):** an empty BOL carries no shipment content, so the missing notification conveys
nothing about goods movement. Practical harm is low; the real cost is ~12 silent failures/year that look like
successes and contaminate the SBDEV-2736 Phase-1 baseline. Tracked as **SBDEV-2737** (normal,
https://app.clickup.com/t/868kgp4cb). Fix = skip the enqueue when `palletDtos.isEmpty()`, ~3 lines.

## Measurement landmines (these produced four wrong rates before the right one)

1. **Never use `ILIKE '%"positions":[]%'`** to find empty payloads — it over-counts **~4×** (337 vs 86) because
   nested `orderDto.positions` also renders `[]` (`BillofladingService.java:513`). Use
   `json_array_length(message::json->'positions') = 0`.
2. **The payload's `bol_id` is `billoflading.name`, NOT `.number`.** Joining on `.number` returns zero matches for
   *both* accepted and rejected groups — always check the control group before reading "zero" as a finding.
3. **Dev-tenant volume is ~100% test traffic** (Cypress `cybol*`/`cybtra*`, `E2E-*`, fuzz names like
   `<script>alert(1)</script>`, `'; DROP TABLE picking_order; --`, `🍷📦🥂`). A name filter for "E2E|SMOKE" does
   **not** exclude these. For real rates use `wsl-wineco-uat` (migrated production copy), not `wms2-wineco-dev`.

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

MERGED 2026-07-28 via PR #101 (guard on palletDtos.isEmpty); exactly 86/2852 (3.0%, ~12/yr) BOL shipments have zero positions and 100% are rejected; legit operator workflow (voids/will-calls/daily close) so don't block the close, guard the notify; NOT a migration regression; SBDEV-2737 normal; LANDMINES: use json_array_length not ILIKE '%"positions":[]%' (over-counts 4×), bol_id = billoflading.name not .number, dev volume is ~100% test traffic
