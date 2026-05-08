---
title: "WMS API v1 → v2 Applicability — commits after 2026-03-20"
type: investigation
status: concluded
version: both
scope: wms-api
owner: Nam Park
created: 2026-04-18
updated: 2026-04-18
last_verified: 2026-04-18
verified_by: v1 git log + v2 git log cross-reference + v2 plan archive scan + v2 code verification on develop-arden branch
related:
  - ../../2-Areas/wms-v1-v2-sync/README.md
  - ../../2-Areas/wms-v1-v2-sync/sync-log.md
  - ../../4-Archieves/wms2/plan/260424-V1_Develop_Arden_Commits_March2026_Port.md
tags:
  - investigation
  - report
  - migration
  - wms-api
---

# WMS API v1 → v2 Applicability — commits after 2026-03-20

## 1. Context & Trigger

Pre-work for the first API-focused Lane B sync session. The 2026-03-20 baseline (v1 `7f06c6f`) corresponds to the prior bulk sync into v2; this report enumerates and classifies every non-merge commit on v1/wms-api `develop-arden` since then, cross-referencing against v2 code on `wms2-api` `develop-arden`.

## 2. Questions

1. Which v1/wms-api commits since 2026-03-20 are already represented in v2 (by equivalent fix or architectural alternative)?
2. Which genuinely need porting?
3. Which are explicitly not applicable (docs, v1-local tooling / re-port, revert pairs)?
4. Which need a product/architectural judgment call before porting?

## 3. Method

- `git -C v1/wms-api log --since="2026-03-21" --no-merges develop-arden` — 49 non-merge commits enumerated.
- `git -C v1/wms-api log --since="2026-03-21" --merges develop-arden` — 21 merge commits (SBDEV-1604, SBDEV-1943, SBDEV-2020, SBDEV-2037, SBDEV-2072, SBDEV-2079, release-260326, etc.).
- `git -C v2/wms2-api log --oneline develop-arden` — v2 comparison.
- Cross-referenced `sbdocs/{1-Projects,4-Archieves}/wms2/plan/` for documented port plans.
- Direct code inspection on v2/wms2-api `develop-arden` for Bucket B verification.
- Grepped sbdocs for SBDEV tickets (1604, 1943, 2020, 2037, 2072, 2079, 2099, 2102, 2116).

## 4. Summary

| Bucket | Count | Action |
|---|---|---|
| **A — Already in v2** | 28 | Skip |
| **B — Verify / judgment call** | 3 | Deep-dive before porting |
| **C — Not applicable** (docs / v1-local / post-migration fix) | 6 | Skip permanently |
| **D — Revert pair + final fix** | 3 (nets 1 port candidate) | Skip 2, port 1 (`d52046e` if missing in v2) |
| **E — Needs porting** | 9 SHAs (7 unique subjects — 2 duplicates) | Port via `wms-v2-migrate` |
| **Merge commits** | 21 | Not units of work; covered by non-merge commits |
| **Total non-merge** | 49 | |

**Realistic port workload:** ~7 unique subjects to port, 1 architectural judgment call (`f0bef13`), and merge-branch enumeration for SBDEV-2072 + SBDEV-2079. Fits a single focused session (2–4 hours).

## 5. Bucket A — Already in v2 (28 commits)

### 5.1 From the 2026-03-27 → 2026-04-18 window (17 commits)

Evidence-based: direct SHA or commit-message match in v2's `develop-arden` history.

| v1 SHA | Date | Subject | v2 evidence |
|--------|------|---------|-------------|
| `227eede` | 2026-04-10 | fix(putaway): prevent stuck unit loads (SBDEV-2102) | v2 `1092e90` |
| `f19bfea` | 2026-04-12 | fix(putaway): UnitloadType ID comparison (SBDEV-2102) | v2 `1092e90` (consolidated port) |
| `77c7518` | 2026-04-13 | fix(putaway): remove duplicate sendToNirvana (SBDEV-2102) | v2 `ef6187a` |
| `b5ac3fa` | 2026-04-13 | fix(pickingtote): null pickingtoteId guard (SBDEV-2102) | v2 `99340b0` |
| `7d63473` | 2026-04-10 | SBDEV-2099 backend fixes (Outbound Parcel Report) | v2 `3b1e0c7`, `cf313d7` |
| `5c4fc5d` | 2026-04-14 | SBDEV-2116 guard unguarded Optional.get (phase 1) | v2 Phase 5 (`5b1b17f`, `a66805c`) + Phase 1 (`25001a9`) |
| `cca3cc9` | 2026-04-15 | SBDEV-2116 guard remaining Optional.get | v2 Phase 5 (same) |
| `c53f33b` | 2026-04-15 | SBDEV-2116 test fix (getParcelMonitorViewByKeyword) | v2 Phase 5 (same) |
| `7e4d7ad` | 2026-04-15 | SBDEV-2116 propagate checked exception | v2 Phase 5 (same) |
| `271958e` | 2026-04-15 | SBDEV-2116 propagate to test callers | v2 Phase 5 (same) |
| `96b3795` | 2026-04-03 | fix(unitload): propagate boxtype for derivative unitloads | v2 `5d192f5`, `fd581b6` |
| `204d266` | 2026-03-31 | fix: stale entity optimistic lock in recalculateOpenOrders | v2 `b68cbbf` (plan `260331-recalculate-orders-stale-entity`) |
| `64968a2` | 2026-04-01 | fix: pessimistic lock Customerorder in releaseOrder | v2 `892169b` (plan `260401-order-release-optimistic-lock`) |
| `d72fef2` | 2026-04-01 | fix: null-safe section lookup in cancellation | v2 `3e7e1a4` (plan `Cancel_Order_Null_SectionId_And_Early_Return`) |
| `e516e38` | 2026-04-01 | fix: refresh stale entity in changeReservedAmount | v2 `930be52` (plan `260401-replenish-stockunit-optimistic-lock`) |
| `2fa92e9` | 2026-04-02 | fix: getIdsToCancelReplenishOrders use fixed-assignment upper bound | v2 `fd88804` |
| `8f71354` | 2026-03-31 | only display size of the maps in the log | v2 `92d0251` |

### 5.2 From the 2026-03-21 → 2026-03-26 window — ADDED in this revision (6 commits)

| v1 SHA | Date | Subject | v2 evidence / reasoning |
|--------|------|---------|--------------------------|
| `83dddd8` | 2026-03-26 | fixed palletize filter on the outbound parcel report | SBDEV-2099 family; v2 `3b1e0c7` + `cf313d7` |
| `66c79af` | 2026-03-25 | feat: port Phase 3 feature migrations + Location/LocationType CRUD | Backport v2 → v1; v2 is the origin, so v2 already has it |
| `1334bf1` | 2026-03-24 | feat: port develop-arden migration gaps — cancel-PACKED, race locks, SQL filters | Same direction: backport from v2 into v1 |
| `a3a2df2` | 2026-03-24 | re-implemented missing fixes for cancelled order filtering | v1 re-implementation of v2-originated fix |
| `b7707bf` | 2026-03-23 | fix: remove replenishment trigger from adjustReservedAmount | Reservation-leak family already in v2 (per `260424-V1_Develop_Arden_Commits_March2026_Port.md`) |
| `4d73546` | 2026-03-23 | fix: lock parent rows in confirmPick() | Covered by `260424-V2_Consolidated_Picking_Fixes_Port.md` (RC family) |

### 5.3 Previously Bucket B — promoted after v2 code verification (5 commits)

| v1 SHA | Date | Subject | v2 evidence |
|--------|------|---------|-------------|
| `cccf7a4` | 2026-03-27 | immutable list + club order cancellation hardening | URL constant fixed at `CustomerorderService.java:718`; singletonList wrapped at 5 v2 call sites |
| `b04066c` | 2026-04-02 | remove nullable amount from getIdsToCancelReplenishOrders | Identical signature + JPQL at `ReplenishorderRepository.java:128-134` |
| `0ecc20e` | 2026-04-03 | use managed entity in mergePickingOrders | v2 uses `currentOrderMap` + `findAllByIdForUpdate` at `PickingOrderMergeService.java:57-64` (architectural equivalent) |
| `cc7bdfd` | 2026-03-27 | cron hot fix — wrap singletonList | Same wrap at `ReleaseOrderJobService.java:652` |
| `e26e095` / `46b573d` | 2026-04-01 | inventory transfer data inconsistency | v2 has `TransferOrderService.getTransferLineUnitLoads()` at line 238 (different implementation path, same method surface) |

## 6. Bucket B — Verify / judgment call (3 commits)

| v1 SHA | Date | Subject | State in v2 | Decision needed |
|--------|------|---------|-------------|-----------------|
| `f0bef13` | 2026-03-31 | cron job auto-flush optimistic lock failures | Partial: retry expansion ✅ (v2 `25001a9`). Missing: `BasicService.showLog()` 30s cache; `@Transactional` on `recalculateOpenOrders()` | Does v2's architecture (Redis cache + Phase 1 transaction safety) reproduce the auto-flush symptom v1 saw? If yes, port the missing pieces; if no, skip with rationale. |
| `50edfe7` | 2026-03-25 | Allow OMS cancellation for pre-QA club orders | v2 `14a4a81` "Phase 7 Part A — fix 4 cancel flow bugs" is the likely home | Confirm Phase 7 Part A covers the pre-QA-club OMS cancellation path; probably already in v2. |
| `46130c3` | 2026-03-24 | Fixed parcel cancelled message | No direct v2 match identified | Inspect v2 parcel message flow to determine if the same issue exists. |

## 7. Bucket C — Not applicable (6 commits)

Do not port. These are v1-local maintenance / docs / back-port artifacts.

| v1 SHA | Date | Subject | Reason not applicable |
|--------|------|---------|-----------------------|
| `60df565` | 2026-04-15 | removed implementation plan documents | v1-local doc cleanup |
| `cc798c1` | 2026-04-15 | put the claude git worktree in the gitignore file | v1-local tooling |
| `4dc5aab` | 2026-03-27 | claude.md update and plan file re-arrangement | v1-local docs |
| `1e114a8` | 2026-03-26 | added plan used to fix club order cancellation bug; updated claude files | v1-local docs |
| `1150417` | 2026-03-25 | adding the plan used to fix club order cancellation bug | v1-local docs |
| `6c65461` | 2026-03-23 | fixed broken order transfer after migrating develop-arden branch commits until March 20, 2026 | v1-local post-migration repair; does not correspond to a v2 issue |

## 8. Bucket D — Revert pair + final fix (3 commits)

Pallet-name duplicate validation — classic apply / revert / re-apply pattern.

| v1 SHA | Date | Subject | Verdict |
|--------|------|---------|---------|
| `0fbf74e` | 2026-04-06 | Fixed Pallet name creation doesn't have duplicate name validation | **Skip** — reverted by `d364033` |
| `d364033` | 2026-04-06 | Revert `0fbf74e` | **Skip** — counterpart to above |
| `d52046e` | 2026-04-06 | Fixed pallet name creation doesn't have duplicate name validation | **Port if not in v2** |

## 9. Bucket E — Needs porting (9 SHAs → 7 unique subjects)

Queue for a Lane B API sync session via `wms-v2-migrate`.

| v1 SHA | Date | Author | Subject | Notes |
|--------|------|--------|---------|-------|
| `4c8d500` | 2026-03-23 | Arden | Fixed Import SKU Data with non-existing Shipper Code causes server error | Duplicate of `4d84547` |
| `4d84547` | 2026-03-23 | Arden | (duplicate — same subject as `4c8d500`) | Port once |
| `98fce54` | 2026-03-26 | Arden | Fixed Newly created BOL already has shipped date | Duplicate of `e476daf` |
| `e476daf` | 2026-03-26 | Arden | (duplicate — same subject as `98fce54`) | Port once |
| `8957b9a` | 2026-04-02 | Arden | Fixed exporting new empty open BOL shows SKU data in the excel file | Low priority — report/export edge case |
| `d52046e` | 2026-04-06 | Arden | Pallet name duplicate validation (see Bucket D) | Verify not in v2; port if missing |
| `4a0a26e` | 2026-04-15 | Leonardo | feat(transaction): create transaction_detail function for detailed transaction reporting | **Verify scope** — new feature; v2 translation may need a different approach (PostgreSQL function vs Spring Data vs Caffeine-cached read) |
| SBDEV-2072 merge (`cd758bc`) | 2026-04-02 | Arden | Merged feature branch (empty merge subject) | Expand via `git log --first-parent cd758bc^2` before porting |
| SBDEV-2079 merge (`81f404c`) | 2026-04-06 | Arden | Merged feature branch (empty merge subject) | Expand via `git log --first-parent 81f404c^2` before porting |

## 10. Merge commits in scope (21 total)

Merges themselves are not units of work — their non-merge contents are captured in Buckets A–E. Listed here for completeness:

- **2026-03-21 → 03-26 window (6):** release-260326, SBDEV-1943, SBDEV-2020 (×2), SBDEV-1604, SBDEV-2037.
- **2026-03-27 → 04-18 window (15):** SBDEV-2072, SBDEV-2079, and assorted task-branch merges.

SBDEV-2072 (`cd758bc`) and SBDEV-2079 (`81f404c`) are flagged for expansion because their non-merge contents may not be fully captured in the Bucket E list above.

## 11. Verdict & Recommendation

**Verdict.** Of 49 non-merge v1 commits since 2026-03-20:

- **28 are already in v2** (Bucket A — strong evidence).
- **3 need a verify / judgment call** (Bucket B — `f0bef13`, `50edfe7`, `46130c3`).
- **6 are docs / v1-local** (Bucket C — never port).
- **3 form a revert trio** (Bucket D — net 1 port candidate: `d52046e`).
- **9 SHAs (7 unique subjects) genuinely need porting** (Bucket E + the two merge-branch expansions).

**Confidence:** High for A / C / D. Medium for B (explicit verification steps per commit). Medium for E (7 unique subjects well-defined, 2 merge expansions required).

**Recommendation — single API sync session plan:**

1. **Verify Bucket B (15–30 min).** Inspect `f0bef13`'s partial coverage, `50edfe7` vs Phase 7 Part A, `46130c3` vs v2 parcel code. Expect 2 of 3 to resolve to Bucket A.
2. **Expand merge commits** (`cd758bc`, `81f404c`) via `git log --first-parent <sha>^2`. Likely 2–5 additional commits to classify.
3. **Port Bucket E** (≤7 unique subjects) using `wms-v2-migrate` with sequential-thinking where appropriate. Leonardo's transaction_detail function (`4a0a26e`) warrants closer analysis.
4. **Port `d52046e`** from Bucket D if not in v2.
5. **Update `sync-log.md`** `wms-api` column with the new anchor once the session completes.

## 12. Open Questions

- **`f0bef13` judgment call.** Does v2 reproduce the v1 auto-flush symptom under Phase 1 + Phase 3 architecture? If yes, port the missing `showLog()` cache + `@Transactional` on `recalculateOpenOrders()`. If no, skip with rationale.
- **`4a0a26e` scope.** Is "transaction_detail function" a PostgreSQL function, a Java service, or both? v2 translation may need a different approach.
- **SBDEV-2072 and SBDEV-2079 contents.** Both are merge commits with empty subjects — underlying branch work must be enumerated before port planning.

## 13. References

- v1 git log scope: `git -C v1/wms-api log --since="2026-03-21" develop-arden`
- v2 git log scope: `git -C v2/wms2-api log --oneline develop-arden`
- v2 port-plan archive: `sbdocs/4-Archieves/wms2/plan/`
- Prior batch port: `sbdocs/4-Archieves/wms2/plan/260424-V1_Develop_Arden_Commits_March2026_Port.md` (dated 2026-03-21)

## 14. Verification Log

| Date | Scope | Result | Checked by |
|------|-------|--------|------------|
| 2026-04-18 | Initial analysis (originally filtered to 2026-03-27+); broadened to 2026-03-21+ and Bucket B verified against v2/wms2-api `develop-arden` code | Concluded — single port session scoped; 1 judgment call (`f0bef13`) carried forward | Nam Park + Claude |
