---
name: sbdev-1762-transfer-lane-club-like-depletion
description: "SBDEV-1762 v2 transfer lanes deplete like club lanes — implemented (PR #91), sysprop-gated; stock-move deadlock landmine + deferred hardening"
metadata: 
  node_type: memory
  type: project
  originSessionId: 155a251e-557a-4c75-98d9-7138d272900f
  modified: 2026-07-25T01:56:20.493Z
---

SBDEV-1762 (WMS v2, wms2-api): transfer "run transfer" now optionally depletes only the order's required SKUs/qty (reserved-adjusted `amount-reservedamount`) and leaves foreign/excess/reserved stock on the lane — club-like. Per-tenant, **default OFF** behind sysprop `TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED`; OFF path byte-identical. MERGED 2026-07-24 → wms2-api **PR #91** into develop (merge commit `7e0e926`; branch `feature/SBDEV-1762-transfer-lane-club-like-depletion`); ClickUp "on dev". Sysprop row seeded default OFF by Flyway **V2.2.04** (PR #93) — covers both fresh DBs and existing tenants (operator runs `flyway migrate` / `psql`-applies V2.2.04 against the tenant DB). Per-tenant opt-in via `configure-client-sysprops.sh` / `SyspropService.setSysvalue`. (The standalone operator seed script `seed-los_sysprop-SBDEV-1762-SBDEV-1666.sql` was DELETED 2026-07-24 as redundant with V2.2.04.) NOTE: PR #91 + #92 both added a constant to the same `WmsConstants.java` block → trivial conflict when #92 merged second, resolved by keeping both. Touches `TransferOrderService.isEnoughStockOnTransferLane(co, boolean)` overload + `BillofladingService.transferOrder`/`combineStock` needed-budget. 14 unit tests + verify script green. Missing/under-qty still BLOCKS (no short/overship — future). Plan: `sbdocs/4-Archieves/wms2/plan/SBDEV-1762-transfer-lane-club-like-depletion.md`.

**Concurrency LANDMINE (reusable across the stock-move subsystem):** `StockunitBusinessService.transferStockToUnitLoad` holds the shared source **Location** lock (`:249-250`) across its per-SU moves, acquired AFTER the per-SU lock, in the canonical **SU→UL→Location** order (SBDEV-2481, `:240-243`). wms2-api has **NO deadlock/serialization-retry infra**. Consequences: (1) an **up-front lane-`Location` lock is an ANTI-PATTERN** — it inverts the canonical SU-first order and creates a NEW transfer-vs-(putaway/replenish/move/pick/club) 40P01 deadlock class (this exact fix was proposed then rejected in review). (2) Any multi-SU-on-one-lane op has an inherent rare same-lane concurrent-transfer 40P01 — accepted as an atomic-rollback fail-fast (single tenant tx, `rollbackFor=BusinessException`), not corruption. Keep new lane-mutating code on the canonical SU-first order.

**DEFERRED follow-up (file as a ticket):** "stock-move deadlock-retry hardening" — global 40P01 retry OR reorder `transferStockToUnitLoad` to Location-first across all ~18 callers (with Testcontainers IT, gated on [[wms2-it-harness-broken-sbdev-2217]]). Would let concurrent same-lane transfers be fully clean.

**Also:** carrier-staged transfer lanes are effectively leaf-only in practice (OFF would also throw "is carrier!"); ON only relocates a carrier to Nirvana when genuinely empty. **DB verification was BLOCKED** at authoring (tenant MCPs `wsl-wineco-uat` + `wms2-hydra-uat` down) — the §2.7 lane-reality query is unrun; run it per opting-in tenant before enabling. Related: [[sbdev-1714-replenishment-finish-audit-snapshot-v2]], [[sbdev-2074-nonreplenishable-move-reservation-gap]] (SBDEV-1666 replenish-from-lane is a SEPARATE excluded ticket).

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

MERGED 2026-07-24 → PR #91 into develop (merge 7e0e926), ClickUp "on dev", sysprop-gated default OFF (`TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED`), reserved-adjusted partial depletion; row seeded default OFF by Flyway V2.2.04 (PR #93) covering fresh DBs + existing tenants (operator runs flyway migrate); standalone seed script deleted 2026-07-24 as redundant; LANDMINE: transferStockToUnitLoad holds shared Location lock across per-SU moves in canonical SU→UL→Location order + NO retry infra → up-front lane-Location lock is an anti-pattern (cross-caller 40P01); rare same-lane concurrent-transfer 40P01 accepted as atomic-rollback fail-fast; DEFERRED "stock-move deadlock-retry hardening" ticket; DB verification was blocked (MCPs down)
