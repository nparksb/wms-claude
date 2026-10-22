---
name: sbdev-2485-club-printable-flag-receiving-only
description: "Club staging-lane reprint button hidden for split ULs — printable flag = goodsreceiptposition membership, not reprint eligibility (v1+v2 identical)"
metadata: 
  node_type: memory
  type: project
  originSessionId: d4f8e0f8-e118-4670-b0f4-e84089fba214
  modified: 2026-07-25T15:01:30.628Z
---

SBDEV-2485 (club process): the staging-lane print/reprint label button (`inventoryOnLaneTable.vue:63` `v-if="item.printable"`) is hidden for **split-created** unit loads. Root cause: `CustomerorderBatchService.buildDtoList` sets `printable` from `GoodsreceiptpositionRepository.findPrintableUnitLoadIds` = "does the UL have a `goodsreceiptposition` row" (receiving-only). Split ULs (`createUnitload` w/ `CODE_MANUAL_SPLIT`) never get one → `printable=false`. But `UnitloadService.reprintLabel` already has a **Path-2** branch that prints split/move/transfer ULs — only the visibility gate was wrong.

**DB-proven blast radius** (2026-07-21, wsl-wineco-uat v2 twin): of unit loads that hold stock, **97.9% (470,764) have printable=false** — the receiving-only rule is inverted from where inventory lives. wms2-hydra-uat same pattern.

**Key insight for the fix:** `buildDtoList` already skips `amount==0` before creating a DTO (`entry.getValue()` = remaining stock of the club item via `calc()`), so every built DTO already has stock. Fix: `dto.setPrintable(entry.getValue() > 0 && lock != null && lock == NOT_LOCKED)` + delete the dead `findPrintableUnitLoadIds` query/param. API-only, no UI change.

**Architect/critic review refinements (2026-07-21):** (1) MUST also gate on `entityLock == NOT_LOCKED` — `UnitloadService.reprintLabel` hard-throws on a locked UL, and the staging-lane query doesn't filter entity_lock, so stock-only flag would show a button that 500s on click. (2) `entityLock` is a **nullable Integer**, `NOT_LOCKED` is primitive int → `==` NPEs on null; guard with `lock != null` (null→hidden). Test fixtures (`buildUnitload`) leave entityLock null, so existing `printable=true` assertions need `setEntityLock(0)`. (3) v2 test is `@MockitoSettings(LENIENT)` (stub removal = hygiene), v1 is STRICT (removal required). (4) v2 `getClubLineUnitLoads` has NO `@Transactional`. (5) 97.9% figure is whole-table, not lane-scoped.

Lines: v1 `CustomerorderBatchService.java:902/1034`, v2 `:1028/1161`; repo v1 `:50-57` / v2 `:50-54`. v1 and v2 byte-identical. Repo `findPrintableUnitLoadIds` is `@RestResource`-exposed → kept (open Q1), only the internal caller removed.

**STATUS (2026-07-25):** v2 **MERGED → develop as wms2-api PR #86**; v2 plan ARCHIVED → `sbdocs/4-Archieves/wms2/plan/SBDEV-2485-club-split-unitload-reprint-label.md`. **v1 plan STILL ACTIVE (draft)** at `sbdocs/1-Projects/wms1/plan/SBDEV-2485-club-split-unitload-reprint-label.md` — v1 fix not yet shipped. Both verify scripts (`-v1.sh`/`-v2.sh`) remain in `9-System/scripts/` (archive-plan guardrail: shared base has an active v1 sibling → scripts stay until v1 is also archived).

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

staging-lane `printable` flag = goodsreceiptposition membership (receiving-only) not reprint eligibility; split ULs never get a GRP row → button hidden though reprintLabel Path-2 already prints them; DB-proven 97.9% of stock-bearing ULs wrongly printable=false; fix = `setPrintable(entry.getValue()>0)` + drop dead query, API-only; v1/v2 identical; draft plans + verify scripts written
