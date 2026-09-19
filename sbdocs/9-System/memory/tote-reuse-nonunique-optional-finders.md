---
name: tote-reuse-nonunique-optional-finders
description: "SBDEV-3287: pickingorder_unitload has only a PK, so every Optional<> finder over unitload_id/customerordernumber crashes once a tote is reused — fixed in v1, still live at 3 v2 call sites"
metadata:
  type: project
---

**WineCo v1 prod outage, 2026-09-09.** Tote `T-0115` carried a `pickingorder_unitload` row created
**2020-05-28** that had never released its unitload. Today's pick took the same tote, two rows then
pointed at unitload 21615430, and `PickingorderUnitloadRepository.findByUnitloadLabelid` — declared
`Optional<>` over a native query with no uniqueness guarantee — threw
`IncorrectResultSizeDataAccessException: query did not return a unique result: 2` out of
`CustomerorderService.packageOrder`. The QA UI rendered that 500 as **"WmsException None: None"**.

## The invariant

`pickingorder_unitload` has **exactly one constraint, its primary key**. Neither `unitload_id` nor
`customerordernumber` is unique. Totes are a **bounded pool of physical objects reused forever**
(`los_sysprop.STRING_PATTERN_PICKING_TOTE = 'T-\d{4}'` → 10,000 labels against 272k rows on WineCo
prod), so multiple rows per label is the **steady state**, not an anomaly. Any `Optional<>` finder
over those columns is therefore wrong by construction, not merely fragile.

Only `packageOrder` ever nulls `unitload_id`, so any order that dies between pick and package
strands a holder forever. The row that fired had sat harmless for six years.

## Still open

- **v2/wms2-api has the same defect at 3 of 4 call sites.** SBDEV-2742 added the safe
  `findLatestByUnitloadLabelid` *and repointed only `ToteStateService`*. `CustomerorderService`
  (the same packageOrder path), `PickingorderUnitloadService` and `MobileInfoService` still call the
  crashing one. Hydra prd had 0 armed collisions on 2026-09-09 — no fire, real latent risk. Proposed
  on SBDEV-3287, not filed (2742 is Closed → status carve-out).
- **The write side still produces orphans.** `MobilePickingService`, freeing a tote for reuse, nulls
  `customerorder.pickingtote_id` but not the `pickingorder_unitload` row holding the tote. A partial
  unique index `(unitload_id) where unitload_id is not null` would enforce the invariant but needs a
  data cleanup first.

## Two things worth reusing

**`packageOrder` selects a row it then MUTATES** (nulls `unitload_id`, stamps FINISHED). Newest-wins
is safe for read-only lookups but not for that one — key it on `(tote id, order number)`, both of
which are already local. Measured on wineco-dev, 5 rows hold a tote their own order no longer points
at, so newest-wins there can silently release a *different* order's assignment. Generalises:
**when a lookup feeds a mutation, "probably the right row" is not good enough**
([[a-guard-fences-the-mechanism-you-aimed-at]]).

**`ReplenishorderRepository.findByUnitloadLabelid` has never worked** — its repository domain type is
`Replenishorder`, so Spring Data cannot map the native `pickingorder_unitload` result to
`Optional<PickingorderUnitload>`; every call raises `ConverterNotFoundException`. Confirmed with a
**single** matching row against unmodified `origin/develop`, so it is the mapping, not the row count.
Dead in Java, still exported at `/replenishorder/search/findByUnitloadLabelid` where it 500s. A
copy-pasted query can be broken *and* unreachable for years — see also
[[wms2-utilrestcontroller-is-service-not-restcontroller]].
