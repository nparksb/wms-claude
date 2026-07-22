---
title: "Club Lane Screen Goes Blank After Split + Quantity Adjust — v2 API PORT"
ticket: "SBDEV-2486"
ticket_url: "https://app.clickup.com/t/SBDEV-2486"
pr: "https://github.com/SiteBossInc/wms2-api/pull/50"
type: bug
priority: medium
status: archived
project:
  - wms2-api
version: v2
requester: "v1→v2 sync sweep 2026-06-25 (Lane B, Feature C)"
created: 2026-06-25
updated: "2026-07-15"
db_verified: false
v1_source_plan: "[[SBDEV-2486-club-lane-blank-screen-split-adjust]] (v1/wms-api)"
v1_commits:
  - "0b1e0ec (B1-B4 club-lane query hardening — API)"
related:
  - "[[SBDEV-2486-club-lane-blank-screen-split-adjust]]"
tags:
  - plan
  - club-run
  - v2-port
---

# Club Lane Screen Blank — v2 API Port (wms2-api)

**V1 Source:** `sbdocs/1-Projects/wms1/plan/SBDEV-2486-club-lane-blank-screen-split-adjust.md` (v1 PR #179, commit `0b1e0ec`). The v1 plan covers backend **B1–B4** + frontend **F1–F4**. The frontend counterpart (`2b41185`) was ported to wms2-web-ui via **Lane A** of this sweep (v2 `aa849c3`). **This plan covers only the v2 API side.**
**V2 Target:** `v2/wms2-api` — `service/CustomerorderBatchService.java`.
**Status:** PENDING APPROVAL. **Priority:** medium.

> **Consensus note:** Scope collapsed from "port B1–B4" to **B4 (one real null-guard) + B2 null-amount guard (minor) + NEW-1 dead-code removal** — B1 and B3 are already implemented in v2 with stricter `EntityNotFoundException` semantics, and B2's reference-equality wrong-sum is neutralized by v2's id-based `AbstractBaseEntity.equals()`. Per the `wms-v2-migrate` small-port exception, ralplan consensus is skipped; the architect pre-investigation (file:line evidence below) serves as the review of record. Test-first via `wms-tdd-gate`.

---

## 2. Summary

| v1 Fix | v2 Verdict | Action |
|--------|------------|--------|
| B1 getClubLineSKUOverview NPEs | **Already-done** | v2 guards itemData/itemUnit with `EntityNotFoundException` (`:1257-1265`), pre-batched maps (no N+1). No change. Do **not** loosen to v1's `.map(...).orElse(null)` — v2's hard-fail is the better contract. |
| B2 calc() wrong-sum (reference equality) | **Not-applicable (neutralized)** | v2 already filters by `itemData.getId().equals(su.getItemdataId())` (`:1217-1220`); `Itemdata` inherits id-based `AbstractBaseEntity.equals()` (`:69-75`). No wrong-sum. |
| B2 null-amount + null-receiver guard | **Needed (minor)** | `:1218-1219` derefs `su.getAmount().intValue()` unguarded → NPE on a null amount; add `itemData != null` + `su.getAmount() == null ? 0`. |
| B3 getCustomerorderBatchDetails client NPE | **Already-done** | v2 guards with `EntityNotFoundException` (`:1308-1312`), stricter than v1's `ifPresent`. No change. |
| B4 getClubLineUnitLoads SKU filter NPE | **Needed (the real port)** | v2 has the exact unguarded `itemDataMap.get(pos.getItemdataId()).getName()` (`:956-960`). |
| NEW-1 dead `itemDataMap` in calc() | **Cleanup** | `:1212-1214` builds a `findAllById` map never read inside `calc()` — redundant DB round-trip per unitload/recursion. Remove (matches v1 fix). |

**Net: 2 small guards (B4 + B2 null-amount) + 1 dead-code removal, all in `CustomerorderBatchService.java`.**

---

## 3. V2-Specific Adaptation Notes
- Exception idiom: `EntityNotFoundException(String entityName, Long id)` for not-found; **not** `BusinessException` (v1 idiom). B4 throws nothing (filters the row out) — matches v1's fix behavior.
- `Itemdata` equality is id-based via `AbstractBaseEntity` — no `.equals()` rewrite needed (v1's B2 reference-equality concern does not apply).
- No `@Transactional` change in this port (NEW-2: these read methods lack `@Transactional(readOnly, tenantTransactionManager)` — flagged as a separate follow-up, out of scope here).

---

## 5. Changes by File — `service/CustomerorderBatchService.java`

### B4 — getClubLineUnitLoads SKU filter (`:956-960`) — **the real fix**
**Current (NPEs if a position's itemdata is not in the map):**
```java
if (skuFilter != null) {
    positions = positions.stream()
        .filter(pos -> skuFilter.equals(itemDataMap.get(pos.getItemdataId()).getName()))
        .collect(Collectors.toList());
}
```
**Fix:**
```java
if (skuFilter != null) {
    positions = positions.stream()
        .filter(pos -> {
            Itemdata id = itemDataMap.get(pos.getItemdataId());
            return id != null && skuFilter.equals(id.getName());
        })
        .collect(Collectors.toList());
}
```

### B2 — calc() stock sum (`:1217-1220`) — null-amount + receiver guard
**Current:**
```java
int stockSum = stockUnits.stream()
    .filter(su -> itemData.getId().equals(su.getItemdataId()))
    .mapToInt(su -> su.getAmount().intValue())
    .sum();
```
**Fix:**
```java
int stockSum = stockUnits.stream()
    .filter(su -> itemData != null && itemData.getId().equals(su.getItemdataId()))
    .mapToInt(su -> su.getAmount() == null ? 0 : su.getAmount().intValue())
    .sum();
```

### NEW-1 — remove dead `itemDataMap` in calc() (`:1212-1214`)
The `findAllById(itemDataIds)` map built in `calc()` is never read (the sum filters on the passed-in `itemData`). Remove it and any now-unused local `itemDataIds`/imports — behavior-preserving cleanup, one fewer DB round-trip per unitload/recursion level. Confirm no other reference before deleting.

---

## 6. NEW Issues
| NEW-# | Issue | File:Line | Severity |
|-------|-------|-----------|----------|
| NEW-1 | Dead `itemDataMap` (`findAllById`) in `calc()` never read | `:1212-1214` | Low (remove in this port) |
| NEW-2 | Read methods lack `@Transactional(readOnly, tenantTransactionManager)` (rely on OSIV) | `:939, :1233, :1292` | Low (separate follow-up; out of scope) |
| NEW-3 | B4 null-key only occurs for genuinely orphaned itemdata FKs (map keyed on same positions) — guard correct but failure is rarer than v1 framing | `:956-960` | Info |

---

## 7. Implementation Priority & Verification
- **Phase 1:** B4 guard → B2 null-amount/receiver guard → NEW-1 dead-code removal.
- **Phase 2:** unit tests (extend `CustomerorderBatchServiceUnitTest` nested classes).
- **Phase 3 (commands):** `mvn clean compile`; `mvn test -Dtest=CustomerorderBatchServiceUnitTest`. No ITs (none needed; v2 IT harness blocked by SBDEV-2217 anyway). Code review. Update §11.

### Horizontal Scalability Validation
All 10 concerns **N/A** — read-only query methods, no new state/jobs/locks/async/notifications; the changes are defensive null-guards + a dead-`findAllById` removal (strictly reduces DB round-trips). Tenant context unchanged (request-thread reads).

---

## 8. Testing Plan (test-first)

| Test class (nested) | Method | Asserts | AC |
|---------------------|--------|---------|-----|
| `CustomerorderBatchServiceUnitTest.GetClubLineUnitLoads` | `getClubLineUnitLoads_shouldFilterOutPosition_whenItemdataMissingFromMap` | A position whose `itemdataId` is absent from `itemDataMap` is filtered out (no NPE) when `skuFilter` is set | AC-1 |
| `CustomerorderBatchServiceUnitTest.GetClubLineUnitLoads` | `getClubLineUnitLoads_shouldTreatNullStockAmountAsZero` | calc() sums a stock unit with a null `amount` as 0 (no NPE) and still counts non-null siblings | AC-2 |
| `CustomerorderBatchServiceUnitTest.GetClubLineUnitLoads` (regression) | `getClubLineUnitLoads_shouldStillSumById_whenItemdataInstancesDiffer` | stock sum is by itemdata **id** (distinct `Itemdata` instances for the same row still sum) — confirms B2 stays correct after the guard | AC-3 |

**Manual:** v2 staging — split a club-lane unit load + adjust qty + apply a SKU filter referencing a freshly-orphaned itemdata; the Club Lane screen renders (no 500), stock counts correct.

### Acceptance Criteria
| AC | Statement |
|----|-----------|
| AC-1 | `getClubLineUnitLoads` with a `skuFilter` filters out (does not NPE on) a position whose itemdata is missing from the map. |
| AC-2 | `calc()` treats a null stock `amount` as 0 and guards a null `itemData` receiver. |
| AC-3 | `calc()` stock sum remains id-based (no regression from the guard). |

---

## 9. Risk Assessment
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Removing dead `itemDataMap` breaks a hidden reader | Low | Medium | Grep `calc()` for `itemDataMap`/`itemDataIds` use before deleting; unit tests cover the sum. |
| Over-loosening B1/B3 to match v1 | Low | Medium | Explicitly do NOT touch B1/B3 — v2's `EntityNotFoundException` hard-fail is the intended stricter contract. |
| B4 guard hides a real data bug (orphaned FK) | Low | Low | Guard filters silently (matches v1); NEW-3 notes it's rare; logging unchanged. |

---

## 10. ADR
- **Decision:** Port only B4 (null-guard) + B2 null-amount guard + NEW-1 cleanup; leave B1/B3 as-is (already correct, stricter in v2).
- **Drivers:** v1↔v2 parity for the club-lane blank-screen fix; v2 already ahead on most of it.
- **Alternatives:** (A) port only the genuine gaps [CHOSEN]; (B) mechanically mirror all of B1–B4 — rejected (would downgrade v2's stricter `EntityNotFoundException` semantics to v1's silent `orElse(null)`/`ifPresent`).
- **Consequences:** two defensive guards + one fewer DB round-trip; no behavior change on the happy path.
- **Follow-ups:** NEW-2 (`@Transactional(readOnly)` on club-lane read methods) — separate ticket.

---

## 11. Implementation Status

**Implemented 2026-06-25** (v1→v2 sync sweep, Lane B Feature C) on branch `fix/SBDEV-2486-club-lane-api-hardening` (off `develop`). Test-first via `wms-tdd-gate` (AC-1/AC-2 confirmed failing with the right NPEs on unchanged code, green after).

| Item | Status | Notes |
|------|--------|-------|
| B4 SKU-filter null-guard | ✅ done | `getClubLineUnitLoads` — null-guarded `itemDataMap.get(...)` before `.getName()`. |
| B2 null-amount + receiver guard | ✅ done | `calc()` — `itemData != null &&` + `su.getAmount() == null ? 0`. Wrong-sum already neutralized by id-based `equals()`. |
| NEW-1 dead-code removal | ✅ done | Removed never-read `itemDataIds`/`itemDataMap` (`findAllById`) in `calc()` — one fewer DB round-trip per unitload/recursion. No imports freed (still used elsewhere). |
| B1 / B3 | ⬜ no change | Already correct in v2 (`EntityNotFoundException` guards — stricter than v1). Deliberately untouched. |
| Unit tests | ✅ **AC-1/2/3 added; class 99/99 pass** | 3 tests in `CustomerorderBatchServiceUnitTest.GetClubLineUnitLoads`. `mvn clean compile` SUCCESS (verified on develop base). |
| PR | ✅ [#50](https://github.com/SiteBossInc/wms2-api/pull/50) → develop | branch `fix/SBDEV-2486-club-lane-api-hardening`, commit `1d871f7`. |

**Follow-up:** NEW-2 (`@Transactional(readOnly, tenantTransactionManager)` on club-lane read methods) — separate ticket. No ITs (none needed; v2 IT lane blocked by SBDEV-2217 regardless).
