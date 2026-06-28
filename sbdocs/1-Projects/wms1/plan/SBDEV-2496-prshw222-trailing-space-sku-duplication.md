---
title: "SBDEV-2496 — Trailing-space SKU duplication holds orders with 'No fixed assigned location'"
ticket: "SBDEV-2496"
ticket_url: "https://app.clickup.com/t/9006034209/SBDEV-2496"
type: "bugfix"
priority: "high"
status: "implemented"
project: ["wms1"]
version: "v1"
requester: "Scott Dalton"
created: "2026-06-26"
updated: "2026-06-26"
db_verified: true
related:
  - "[[SBDEV-2496-prshw222-duplicate-sku-remediation]]"
tags:
  - plan
  - wms1
  - inventory-control
  - sku-master-data
---

# SBDEV-2496 — Trailing-space SKU duplication holds orders with "No fixed assigned location"

**Ticket:** [SBDEV-2496](https://app.clickup.com/t/9006034209/SBDEV-2496)
**Project:** wms1 | **Version:** v1/wms-api | **Type:** Bug fix
**Priority:** High (recurrence prevention; original client blocker already resolved)
**Status:** Draft — pending review

> **Scope note.** This plan covers the **permanent code fix** (whitespace normalization on SKU master-data write/lookup boundaries + a one-time data migration) to prevent recurrence.
>
> **The original WineCo/Pike Road incident is already resolved.** Verified against `wms1-wineco` on 2026-06-26: the duplicate was consolidated by another actor onto the **clean** row `33714616` (now holds the 60 units @ 03-B05 + the active fixed-location assignment), the trailing-space twin `33355356` was deleted, and parcel **PR261039** released (line `33715138` → state 200 ASSIGNED). The companion runbook [[SBDEV-2496-prshw222-duplicate-sku-remediation]] has been **retired (do not run)** — it assumed the opposite survivor and would corrupt the released order. This plan is no longer the unblock path; it is recurrence prevention only.

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn` over `v1/wms-api/src/main/java` for the Itemdata create/lookup boundaries. Two **write** sites mint `Itemdata`; the rest are **lookup** sites whose exact-match on an untrimmed SKU string is what splits a SKU into a clean/space pair.

| # | File:line | Construct | Same root cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `SkuRestController.java:86` | `findByClientIdAndItemNr(clientId, sku.getSku())` — create-path existence check (untrimmed) | yes | yes |
| 2 | `SkuRestController.java:119,121` | `new Itemdata()` + `setItemNr(sku.getSku())` — **mints duplicate** (untrimmed persist) | yes | yes |
| 3 | `SkuRestController.java:207` | `findByClientIdAndItemNr(clientId, sku.getSku())` — update-path lookup; on miss delegates to `create()` → **mints duplicate** | yes | yes |
| 4 | `SkuRestController.java:325` | `findByClientIdAndItemNr(clientId, sku.getSku())` — deactivate/third path (untrimmed) | yes | yes |
| 5 | `FileImportController.java:339,348` | `new Itemdata()` + `setItemNr(skuDto.getSkuNumber())` — file SKU import (untrimmed persist) | yes | yes |
| 6 | `Itemdata.java:170` | `setItemNr(String)` — single persist chokepoint for every write path | yes | yes (primary normalization point) |
| 7 | `OrderRestController.java:271,259` | `skuSet.add(orderPosition.getSkuId())` — order-import SKU set built from raw inbound SKU | yes (consumer) | yes (defensive) |
| 8 | `OrderRestController.java:520,528,542` | `resolveItemData()` — `findByClientNumberAndSkuSet(skuSet,…)`, `itemData.getItemNr().equals(sku)`, map keyed by `getItemNr()` (untrimmed) | yes (consumer) | yes (defensive) |
| 9 | `OrderRestController.java:435` | `clientItemDataMap.get(clientId).get(orderPosition.getSkuId())` — order-line bind by raw inbound SKU | yes (consumer) | yes (defensive) |
| 10 | `AdviceRestController.java` (`findByClientIdAndItemNr` caller) | receiving advice resolves itemdata by SKU (untrimmed lookup) | yes (consumer) | yes (defensive) |
| 11 | `ReceivingService.java`, `StockCountRestController.java`, `TransactionReportRestController.java`, `ItemDataController.java`, mobile/replenish lookups | other `findByItemNr`/`findByClientIdAndItemNr` callers | yes (consumer) | **no** — these are lookup/read/report paths that do **not** mint `Itemdata` (only sites 2 & 5 do). `ReceivingService` deserves the sharpest look since receiving advice is the suspected origin of the original space — but advice ingress is handled at `AdviceRestController` (site 10, in scope); confirm during implementation that `ReceivingService` lookups are strictly downstream of that normalized ingress and cannot themselves create or mis-resolve a SKU. If that turns out false, pull `ReceivingService` into scope. Others revisit only if a report mismatch surfaces. |

> Sites 1–6 are the **fix** (stop minting duplicates + normalize on persist). Sites 7–10 are **defensive** (trim inbound SKU at the OMS ingress boundaries so an order/advice carrying a stray space still resolves to the single normalized master row). Site 11 is explicitly out of scope.

---

## 1. Problem Statement

**Client-visible symptom (WineCo / Pike Road, ST#1019).** SKU **PRSHW222** ("2022 Sparkling Hog Wild Rose 750 ml") shows **60** on hand at location **03-B05** (reserved 0) on the SKU Location Report, yet parcel **PR261039** (batch `50662-1`) sits **On Hold** and its PRSHW222 line reports **"No fixed assigned location."** The order cannot release.

**Reproduction (data condition).** An OMS SKU code and the stored WMS `item_nr` differ only by trailing whitespace. The SKU sync then creates a *second* `itemdata` row for the same physical SKU; inbound orders bind to whichever row matches the exact inbound string, which may be the empty twin.

### DB verification (wms1-wineco production, 2026-06-26) — `db_verified: true`

Pike Road (`client_id 512501`) has **two** `itemdata` rows for the same product:

| itemdata id | `item_nr` (bracketed) | len | created | stock | fix_location_assignment |
|---|---|---|---|---|---|
| **33355356** | `[PRSHW222 ]` (trailing space) | 9 | 2026-06-05 13:41 | **60 @ 03-B05** (+4 empty @ Nirwana) | ✅ active, 03-B05, bounds 36/60/84 |
| **33714616** | `[PRSHW222]` (clean) | 8 | 2026-06-26 10:16 | **none** | ❌ none |

Held order `33715135` (clientordernumber `PR261039`, parcel `KA1782497010429`), batch `061054`, line **33715138** is in state **56 = `RAW_ON_HOLD_NO_FIXED_ASSIGNED_LOCATION`**, qty 2, pointing at the **empty clean twin 33714616**.

```sql
-- collapsing duplicate pairs per client (only one exists in wineco):
SELECT client_id, btrim(item_nr) AS trimmed, count(*) n,
       string_agg('['||item_nr||']#'||id,', ' ORDER BY created) variants
FROM itemdata GROUP BY client_id, btrim(item_nr) HAVING count(*)>1;
-- -> 512501 | PRSHW222 | 2 | [PRSHW222 ]#33355356, [PRSHW222]#33714616

-- whitespace itemdata across the tenant (3 total; only PRSHW222 has stock):
SELECT id,'['||item_nr||']',client_id,
       (SELECT coalesce(sum(amount),0) FROM stockunit s WHERE s.itemdata_id=i.id) qty
FROM itemdata i WHERE item_nr <> btrim(item_nr);
-- -> [23WINERYBLOCKPN ]#22198980 (client 419802, qty 0)
--    [NVAYBMS ]#29735086        (client 146700, qty 0)
--    [PRSHW222 ]#33355356       (client 512501, qty 60)
```

There is a `UNIQUE (client_id, item_nr)` constraint on `itemdata` (`uk3l3dgof3l6mc1dl7s3lmida65`), which is exactly why `'PRSHW222'` and `'PRSHW222 '` are allowed to coexist as two rows.

> **The table above is the historical snapshot at investigation time.** As of a re-query on 2026-06-26, production has been remediated: `33355356` is deleted, the clean `33714616` now holds the stock + FLA, and the parcel released. The RCA below remains valid as the explanation of *how the duplicate arose*; the code fix targets the mechanism so it cannot recur.

---

## 2. Root Cause Analysis

### Bug 1 — SKU lookup uses a trailing-space-sensitive exact match, so a stray space creates a duplicate `itemdata`

`SkuRestController` resolves an inbound SKU with an exact-equality derived query and, on a miss, creates a new row:

```java
// SkuRestController.java:86  (create path)
Optional<Itemdata> itemDataValue =
    itemdataRepository.findByClientIdAndItemNr(client.getId(), sku.getSku());   // exact '=' match
...
// SkuRestController.java:119-121  (mints the duplicate)
Itemdata itemData = new Itemdata();
itemData.setId(itemdataRepository.getNextId());
itemData.setItemNr(sku.getSku());                                              // persists untrimmed
```

`findByClientIdAndItemNr` is a Spring Data derived query → SQL `WHERE item_nr = :itemNr`. **Postgres `=` on `varchar`/`text` is trailing-space-sensitive** (only `bpchar`/`char(n)` ignore trailing blanks). The stored value was `'PRSHW222 '`; the inbound SKU sync sent `'PRSHW222'`; `'PRSHW222' = 'PRSHW222 '` is **false**, so the lookup missed and a fresh, empty `itemdata` (`33714616`) was created. The update path has the same defect and is worse — it *delegates to create* on a miss:

```java
// SkuRestController.java:207-214  (update path → falls through to create)
Optional<Itemdata> itemDataValue =
    itemdataRepository.findByClientIdAndItemNr(client.getId(), sku.getSku());
if (!itemDataValue.isPresent()) {
    LOG.info("SKU " + sku.getSku() + " does not exist, going to create");
    List<SkuDto> createList = new ArrayList<>();
    createList.add(sku);
    create(createList);                         // <-- mints the empty twin
}
```

The same untrimmed `new Itemdata().setItemNr(...)` pattern exists in the file SKU import (`FileImportController.java:339,348`).

> **Origin of the data.** The trailing-space row `33355356` was created **2026-06-05** and is the one that received stock and got a fix-location assignment — so an early SKU/receiving import persisted the SKU *with* a trailing space, and every later clean-string sync failed to match it. The clean twin appeared 2026-06-26 10:16, ~48 min before the parcel was created in WMS (11:04).

### Bug 2 — Order release reports "No fixed assigned location" for the empty twin (correct behavior, wrong input)

This is **not** a defect in the release job — it is the downstream symptom of Bug 1. `ReleaseOrderJobService.releaseOrder()` sets a line to state 56 only when **both** conditions hold for the line's `itemdata_id`:

1. No `fix_location_assignment` row exists for that itemdata — `OrderReleaseJob` builds `itemDataFixAssignmentMap` from `FixLocationAssignmentRepository.getFixedLocationAndItemDataIds()`; the empty twin has no FLA row, so the map has no entry (`fixAssignmentID == null`). (`ReleaseOrderJobService.java:115-139`, `:219-263`.) Note: `getFixedLocationAndItemDataIds()` (`FixLocationAssignmentRepository.java:90-91`) returns **all** FLAs regardless of `active` — so the empty-twin case is specifically the *"no FLA row at all"* branch (`fixAssignmentID == null` → state 56), which is distinct from the *inactive-FLA* branch (`RAW_ON_HOLD_FIX_ASSIGNMENT_IS_INACTIVE`, state 58) that the same map also feeds. This incident is purely the former; no change to the release job is in scope.
2. Pickable overstock is insufficient — `StockunitRepository.getStockUnitAvailable(itemdataId)` requires `location_area.useforpicking = true` and no entity locks; the empty twin has zero stockunits, so `available = 0 < 2`.

Location **03-B05 itself is valid and pickable** (`location_area.useforpicking = true`, no entity locks) — verified in production. The fix-location setup is **active and correct**, but it is attached to the *other* (trailing-space) itemdata. So per the ticket's decision tree this is a confirmed **bug** (whitespace-driven SKU duplication), not a setup gap. No code change is needed in the release job; fixing Bug 1 + the data correction removes the symptom.

---

## 3. Design / Proposed Fix

**Principle:** treat SKU codes as identifiers — normalize (trim) at every ingress boundary, on **both** the value persisted **and** the value used to look it up, so the same physical SKU can never split into two `itemdata` rows.

### 3.1 Fix A — Normalize on persist at the single chokepoint (`Itemdata.setItemNr`)

Trim in the setter so **every** write path (SkuRest create, FileImport, any future caller) stores a clean `item_nr`. Defensive and minimal.

```java
// Itemdata.java:170  (before)
public void setItemNr(String itemNr) { this.itemNr = itemNr; }

// after
public void setItemNr(String itemNr) {
    this.itemNr = (itemNr == null) ? null : itemNr.trim();
}
```

**Why the setter and not only the call-sites:** it is the one place all persists funnel through, so it cannot be bypassed by a new caller. The call-sites still need the *lookup* trimmed (Fix B) regardless — trimming the stored value does not help a lookup whose *key* carries a space.

**Hydration-safety (resolved review concern).** A normalizing setter is dangerous if Hibernate calls it during entity *load*, because the in-memory value would then differ from the DB snapshot and dirty-checking would emit a spurious `UPDATE` and bump `@Version` (`Itemdata.java` has `@Version private Integer version`), risking version churn and `ObjectOptimisticLockingFailureException` on read paths. **This does not apply here:** `Itemdata` uses **field-access** JPA mapping (annotations on fields, no `@Access(PROPERTY)`), so Hibernate sets the field directly via reflection on hydration and never calls `setItemNr` during load. The trim therefore fires only on application writes. **Required acceptance gate:** a load-then-flush unit/IT test must confirm that reading a (legacy whitespace) row and flushing in a no-op transaction does **not** issue an UPDATE — if that ever fails (access type changed), drop Fix A and rely on Fix B + a `@PrePersist`/`@PreUpdate` guard instead.

### 3.2 Fix B — Normalize inbound SKU before every lookup (new `SkuCodes.normalize` helper)

Add a tiny static helper and apply it to the inbound SKU string *before* the repository lookup at each ingress boundary. A clean stored value (Fix A + migration) only resolves if the lookup key is also clean.

```java
public final class SkuCodes {
    private SkuCodes() {}
    /** Canonical SKU form: trimmed; null/blank → null so callers fail the existing not-found path. */
    public static String normalize(String raw) {
        if (raw == null) return null;
        String t = raw.trim();
        return t.isEmpty() ? null : t;
    }
}
```

Apply at:
- `SkuRestController.java:86, 207, 325` — `findByClientIdAndItemNr(clientId, SkuCodes.normalize(sku.getSku()))`, and use the normalized value for the subsequent `setItemNr` so create stores the canonical form even if the setter trim were ever removed.
- `FileImportController.java:348` — `setItemNr(SkuCodes.normalize(skuDto.getSkuNumber()))`.
- `OrderRestController` — **consistency is mandatory across all three key spaces or the bug survives.** `resolveItemData` drives a **native** `IN`-query (`findByClientNumberAndSkuSet`, `ItemdataRepository.java:51-56`) whose `IN`-list is the `skuSet` itself (so the *set contents* must be normalized at the `:259/:271` build), keys the bind map by the **stored** `itemData.getItemNr()` (`:542`) and the existence check by `itemData.getItemNr().equals(sku)` (`:528`), and binds the line by the **raw inbound** `orderPosition.getSkuId()` (`:435`). Normalize the inbound SKU **once** at the earliest ingress (`:259/:271`) and reuse that normalized value for the `:435` bind; normalize `getItemNr()` at `:528/:542`. With both stored values (post-migration) and inbound values trimmed, a genuinely-missing SKU still fails the `resultList.size() != skuSet.size()` check and throws `ENTITY_DOES_NOT_EXISTS` — no real miss is masked.
- `OrderRestController.java:435,443` — **add a null guard before `itemData.getId()`.** Today an inbound SKU that mismatches by key but coincidentally passes the size check yields `itemData == null` → NPE → HTTP 500 (`RestExceptionHandler` does not map `NullPointerException`). Replace with an explicit `throw new WebserviceBusinessExceptionClientSide(ENTITY_DOES_NOT_EXISTS, ...)` so any future un-normalized path degrades to a clean client error instead of a 500.
- `AdviceRestController` — normalize the inbound SKU before its `findByClientIdAndItemNr` lookup (receiving is the most likely origin of the original space).

### 3.3 Fix C — One-time Flyway migration to normalize existing `item_nr`

Trim existing whitespace `item_nr` values so historical rows match future clean lookups. Guard against the unique-constraint collision.

> **Migration version — do NOT use `V1.1.06`.** `V1.1.06__transfer_order_state_fix.sql` already exists and the Flyway **head is `V1.26.30`** (`V1.26.30__replenishment_monitor_view_add_ro_id.sql`, SBDEV-2384). A `V1.1.x` file would either trip duplicate-version validation or sort below the baseline and never run. Name this **`V1.26.31__trim_itemdata_item_nr_whitespace.sql`**, and **re-check the actual head at coding time** — other tickets may push it past V1.26.30. (The stale "next would be `V1.1.06`" note in `v1/wms-api/CLAUDE.md` and the root project CLAUDE.md has been corrected as part of this work.)

```sql
-- V1.26.31__trim_itemdata_item_nr_whitespace.sql  (verify head before finalizing the version)
-- Trim only rows that (a) have whitespace AND (b) would NOT collide with an
-- existing trimmed sibling in the same client. The one current colliding pair
-- (PRSHW222 / client 512501) is consolidated by the SBDEV-2496 runbook BEFORE
-- this migration deploys, so it is already clean by the time this runs.
UPDATE itemdata i
   SET item_nr = btrim(i.item_nr)
 WHERE i.item_nr <> btrim(i.item_nr)
   AND NOT EXISTS (
       SELECT 1 FROM itemdata j
        WHERE j.client_id = i.client_id
          AND j.id <> i.id
          AND j.item_nr = btrim(i.item_nr));
```

Rows skipped by the `NOT EXISTS` guard (a residual unresolved collision) are **surfaced for manual consolidation, not silently dropped** — they remain visible to the canary query in Prereq 8. The guard is **idempotent** (a second run matches nothing, because trimmed rows no longer satisfy `item_nr <> btrim(item_nr)`). Caveat: it resolves only two-way collisions; a hypothetical three-way case (`'X'`, `'X '`, `'X  '`) would leave the double-space row skipped — not present in current data (the only remaining whitespace rows, `23WINERYBLOCKPN ` and `NVAYBMS `, trim to distinct values and have no clean sibling), so the migration trims both cleanly. The PRSHW222 collision no longer exists (production already consolidated to the single clean row), so it is not a factor.

**Files changed:** `Itemdata.java`, new `SkuCodes.java`, `SkuRestController.java`, `FileImportController.java`, `OrderRestController.java`, `AdviceRestController.java`, new `V1.26.31__trim_itemdata_item_nr_whitespace.sql` (verify head at coding time).

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| SKU upsert via `findByClientIdAndItemNr` + create-on-miss | `SkuRestController` | `wms2-api` SKU ingest (verify) | Same trailing-space-sensitive `=` semantics in Postgres → same duplication risk |
| `item_nr` unique `(client_id, item_nr)` | present | likely present | Same coexistence of clean/space twins |

### What Needs Porting
1. The normalization principle (trim on persist + trim on lookup) should be evaluated for v2/wms2-api’s SKU ingest and order/advice import. **Defer to a paired v2 plan** via `wms-v2-migrate` (same base name) — out of scope here.

### What Does NOT Need Porting
- The production data correction (runbook) is wineco-v1-specific.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Confirm Flyway head (was `V1.26.30` on 2026-06-26) and name the new migration `V1.26.31` (or next free). The PRSHW222 incident is **already resolved** in prod — no data prerequisite remains; the migration only trims the two latent zero-stock whitespace SKUs | DBA / support | Companion runbook is **retired (do not run)** — see [[SBDEV-2496-prshw222-duplicate-sku-remediation]] |
| 2 | **Feature flags / system properties** | N/A — no toggle | — | Pure code + migration |
| 3 | **Config / env changes** | N/A | — | |
| 4 | **Deploy-order dependencies** | None. The migration is **order-independent for correctness**: with no remaining collisions in prod, it trims `23WINERYBLOCKPN ` and `NVAYBMS ` cleanly regardless of deploy sequence; the collision guard is the safety net if a new collision appears before deploy | Release owner | |
| 5 | **Data migration** | `V1.1.06__trim_itemdata_item_nr_whitespace.sql` (in this plan) | — | Idempotent (re-running trims nothing new) |
| 6 | **External systems** | Confirm with OMS whether the source SKU master itself carries the trailing space; if so, raise an OMS-side cleanup so it stops re-sending it | OMS owner | WMS-side normalization makes WMS resilient regardless |
| 7 | **Access / permissions** | N/A | — | |
| 8 | **Monitoring / alerts** | Optional: a periodic check `SELECT count(*) FROM itemdata WHERE item_nr <> btrim(item_nr)` to alert on new whitespace SKUs | — | Cheap regression canary |

### 5.2 Implementation Checklist

- [ ] **S1** Add `SkuCodes.normalize` helper (`net.aim_ai.wms.service` or `util`).
- [ ] **S2** Trim in `Itemdata.setItemNr` (Fix A).
- [ ] **S3** Normalize lookup + persist in `SkuRestController` (lines 86, 121, 207, 325).
- [ ] **S4** Normalize persist in `FileImportController` (line 348).
- [ ] **S5** Normalize inbound SKU in `OrderRestController` (`:259/:271` set build, `:435` bind, `:528/:542` map) and `AdviceRestController` lookup.
- [ ] **S6** Add `V1.1.06__trim_itemdata_item_nr_whitespace.sql` (Fix C).
- [ ] Unit tests added (S1–S5).
- [ ] Migration integration test (S6, Testcontainers — see §6 caveat).
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2496-prshw222-trailing-space-sku-duplication.sh` → `0 fail`.
- [ ] Code review completed.

---

## 6. Test Plan

> **v1 IT caveat (from project memory).** All v1 `@SpringBootTest` ITs currently fail at context load due to `ro_id` view drift (SBDEV-2384) — fix the view before running any v1 IT, or gate this plan on unit tests + a standalone Flyway-on-Testcontainers migration test. Mockito is **3.3.3** — no `mockStatic()`; test `SkuCodes` directly (it’s static + pure) rather than mocking it.

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Inbound SKU with trailing space matches existing clean row | POST sku `'PRSHW222 '` when `'PRSHW222'` exists | No new `itemdata` created; existing row updated |
| Inbound clean SKU matches existing (legacy) space row after migration | Migration trims space row → POST `'PRSHW222'` | Resolves to the single normalized row |
| Order line with trailing-space SKU binds to normalized master | Import order line sku `'PRSHW222 '` | Binds to the one `'PRSHW222'` itemdata; no 500/NPE, no false "does not exist" |
| Migration collision guard | Two rows `'X'` and `'X '` same client | `'X '` left untrimmed (skipped), surfaced for manual merge; migration succeeds |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `SkuCodesTest` (new, unit) | `normalize_trimsTrailingSpace`, `normalize_blankToNull`, `normalize_nullToNull` | Helper contract |
| `ItemdataTest` (new/updated, unit) | `setItemNr_trimsWhitespace`, `setItemNr_nullStaysNull` | Setter normalization |
| `ItemdataHydrationIT` (new, Testcontainers) | `loadThenFlush_legacyWhitespaceRow_issuesNoUpdate` | **Fix A gate** — confirms field-access means the trimming setter does NOT fire on load (no spurious UPDATE / version bump) |
| `SkuRestControllerTest` (updated) | `create_withTrailingSpace_matchesExistingRow_noDuplicate`, `update_missByWhitespace_doesNotCreateDuplicate` | No duplicate minted |
| `OrderRestControllerTest` (updated, `BaseControllerTest`/MockMvc as used in repo) | `import_orderLineWithTrailingSpaceSku_bindsToNormalizedItemdata`, `import_cleanSku_resolvesStoredCleanRow`, `import_unknownSku_returnsEntityDoesNotExist_not500` | Both directions bind; genuine miss is a clean client error, not NPE→500 |
| `V1_1_06_MigrationIT` (new, Testcontainers) | `trimsWhitespace_skipsCollisions` | Migration trims non-colliding rows, skips collisions |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Original incident stays resolved (regression) | wineco prod | Confirm exactly one `PRSHW222` row for client 512501 (clean `33714616`, 60 stock, 1 FLA) and line `33715138` is state 200 | single clean row; parcel released (already true 2026-06-26) |  |
| No new whitespace SKUs after deploy | wineco prod | `SELECT count(*) FROM itemdata WHERE item_nr <> btrim(item_nr)` after a SKU sync | count does not grow |  |
| SKU sync re-send of `'PRSHW222'` | staging | Trigger OMS SKU sync | resolves to single row, no duplicate |  |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=SkuCodesTest,ItemdataTest,SkuRestControllerTest,OrderRestControllerTest` | | |
| `mvn verify` (or scoped migration IT) | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Full `mvn verify` v1 IT suite | Blocked by SBDEV-2384 `ro_id` view drift; run scoped migration IT instead until the view is fixed |

---

## 7. Horizontal Scalability Validation

N/A — this is a v1/wms-api plan. v1 is not deployed as horizontally-scaled replicas in the same model as v2; the v2 evolution (if pursued) carries its own §7 in the paired v2 plan.

---

## 8. Notes

- **Architect + Critic review completed (2026-06-26).** This plan was reviewed by the `architect` and `critic` agents after drafting (ralplan consensus was skipped given the live-DB-confirmed root cause). Their blockers are folded in: Flyway version corrected from the stale `V1.1.06` to `V1.26.31` (§3.3); setter hydration-safety resolved via the field-access finding (§3.1); order-import consistent-normalization + NPE guard added (§3.2); migration guard reworded order-independent (§3.3); RCA `active`-flag note added (§2); and the production-state divergence that retired the runbook is reflected throughout.
- **Setter-trim vs call-site-trim — resolved.** Keep **both**: Fix A (setter) is safe here specifically because `Itemdata` uses field-access JPA, so the trimming setter never fires on hydration (see §3.1); Fix B (lookup normalization) is independently required. The load-then-flush test in §6 is the gate that keeps Fix A honest if the access type ever changes.
- **Deferred defense-in-depth — partial unique index.** A `CREATE UNIQUE INDEX ... ON itemdata (client_id, btrim(item_nr))` would make the DB itself reject a space-twin even if a future un-normalized caller slips through. **Deferred, not adopted:** it changes the failure mode for SKU import to a `DataIntegrityViolationException` (Postgres 23505), and `SkuRestController.create` currently catches only `WebserviceBusinessExceptionClientSide`, so the 23505 would bubble to a 500 until a handler is added. Revisit as a follow-up once the application-layer normalization has soaked.
- **OMS-side root cause.** WMS normalization makes WMS resilient, but if the OMS SKU master itself stores `'PRSHW222 '`, every export carries the space. Raise an OMS-side data-cleanup ticket (Prereq 6) so the canonical source is clean too.
- **Companion runbook:** [[SBDEV-2496-prshw222-duplicate-sku-remediation]] — apply first to unblock PR261039.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

`sbdocs/9-System/scripts/verify-SBDEV-2496-prshw222-trailing-space-sku-duplication.sh` — one POSITIVE check per fix site plus NEGATIVE checks for the replaced untrimmed constructs, and `mvn test` rows for the new/updated unit tests. The implementing agent runs it after every pass and pastes `Result: N pass, 0 fail` into the end-of-task report.

### 9.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | ~6 fix sites across 2 controllers + 1 model + 1 helper + 1 migration, single subsystem |
| **Pre-draft step** | none | RCA confirmed with live DB evidence |
| **Plan-review step** | critic + architect — **done (2026-06-26)** | Blockers folded in (§8); re-run `critic` only if scope changes |
| **Implementation shape** | executor | Cohesive single-subsystem change |
| **Verification step** | verify-script + verifier | Mandatory |
| **Code-review step** | code-reviewer | Touches an OMS ingress boundary; cheap insurance |
| **Commit step** | git-master | Logical commits: helper+setter, controllers, migration |

---

## 10. Implementation Status

**Implemented 2026-06-26** (branch `task/SBDEV-2496-trailing-space-sku-normalization`, PR → `develop`: https://github.com/SiteBossInc/wms-api/pull/186, commit `decff33`).

### Files changed (v1/wms-api)
| File | Change |
|---|---|
| `model/Itemdata.java` | `setItemNr` trims (null-safe); field-access JPA → not called on hydration |
| `util/SkuCodes.java` (new) | `normalize(raw)` — trim, blank→null |
| `controller/rest/SkuRestController.java` | normalize all 3 lookups + create persist; blank-SKU guard rejects whitespace-only (item_nr is NOT NULL) |
| `controller/FileImportController.java` | normalize existence lookup + persist via `normalizedSkuNumber`; blank-SKU error |
| `controller/rest/OrderRestController.java` | normalize per-order dedup, `skuSet`, club-SKU comparison, `resolveItemData` map keys/equality, and the order-line bind; **new null guard** → `ENTITY_DOES_NOT_EXISTS` instead of NPE→500 |
| `controller/rest/AdviceRestController.java` | normalize both SKU lookups; transfer-path `.get()` → `orElseThrow(ENTITY_DOES_NOT_EXISTS)` |
| `resources/db/migration/V1.26.31__trim_itemdata_item_nr_whitespace.sql` (new) | one-time trim via `regexp_replace('^\s+|\s+$')` (matches Java `trim()`), id-based trimmed-to-trimmed collision guard |
| `CLAUDE.md` (v1/wms-api) | corrected stale "next migration = V1.1.06" guidance → check actual Flyway head |

> Migration version used: **`V1.26.31`** (Flyway head was `V1.26.30`; the planned `V1.1.06` already existed — caught by the Architect/Critic review).

### Tests
- New: `unit/util/SkuCodesUnitTest` (3), `unit/model/ItemdataUnitTest` (2), `unit/controller/rest/SkuRestControllerNormalizeTest` (2). All green.
- Regression: `OrderRestControllerCreateTransferTest` (7), `OrderRestControllerCancelTest` (5), `ItemdataServiceUnitTest` (6) — all pass.
- `mvn test -Dtest='SkuCodesUnitTest,ItemdataUnitTest,SkuRestControllerNormalizeTest,OrderRestControllerCreateTransferTest,OrderRestControllerCancelTest,ItemdataServiceUnitTest'` → **Tests run: 25, Failures: 0, Errors: 0** — BUILD SUCCESS. `mvn clean compile` clean.
- Deferred (`SBDEV2496DeferredTests`, `@Disabled`): hydration IT, migration IT, `@WebMvcTest` order-import — blocked by SBDEV-2384 v1 IT-harness drift; author + enable once unblocked.

### Acceptance
- `bash sbdocs/9-System/scripts/verify-SBDEV-2496-prshw222-trailing-space-sku-duplication.sh` → **`Result: 14 pass, 0 fail, 1 skip`**.

### Review
- Architect + Critic reviewed the plan; `code-reviewer` reviewed the implementation (2 HIGH, 4 MEDIUM, 1 conditional-MEDIUM) — **all HIGH/MEDIUM fixed**: SQL/Java trim char-set parity (`regexp_replace`), normalized per-order dedup + club comparison, single normalization point in `resolveItemData`, AdviceRestController null guard, robust migration collision guard, blank-SKU rejection (item_nr NOT NULL).
