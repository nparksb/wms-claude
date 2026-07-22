---
title: "SBDEV-2496 — Trailing-space SKU duplication (v2): order-import + advice normalization gaps"
ticket: "SBDEV-2496"
ticket_url: "https://app.clickup.com/t/9006034209/SBDEV-2496"
type: "bugfix"
priority: "high"
status: archived
project: ["wms2-api"]
version: "v2"
requester: "Scott Dalton"
created: "2026-07-10"
updated: "2026-07-15"
db_verified: false
related:
  - "[[SBDEV-2496-prshw222-trailing-space-sku-duplication]]"
  - "[[260610-wms2-sku-trim-normalization]]"
  - "[[wms2-sku-trim-data-cleanup]]"
tags:
  - plan
  - wms2
  - inventory-control
  - sku-master-data
  - sku-sync
---

# SBDEV-2496 — Trailing-space SKU duplication (v2 port): close order-import + advice normalization gaps

**Ticket:** [SBDEV-2496](https://app.clickup.com/t/9006034209/SBDEV-2496)
**Project:** wms2-api | **Version:** v2/wms2-api | **Type:** Bug fix (v1→v2 port of `decff33`)
**Priority:** High (recurrence prevention; closes 260610's documented order-import carve-out 6b)
**Status:** archived 2026-07-15 — **implemented & merged to `develop`** via wms2-api [PR #66](https://github.com/SiteBossInc/wms2-api/pull/66) (commit `997b07e` "port v1 decff33 — SBDEV-2496 trailing-space SKU normalization", merged 2026-07-12; verified on `origin/develop`). (Superseded the earlier "reviewed / pending implementation approval" note — implementation landed after ralplan consensus.)
**Sweep:** part of [[2026-07-10-wms-v1-sync]] (Lane B unit 1 of 6).

> **Scope note.** This is the **v2 port** of v1/wms-api commit `decff33` (SBDEV-2496). The SKU-master write/lookup and file-import boundaries were **already normalized in v2** by [[260610-wms2-sku-trim-normalization]] (commit `d1a224d`, PR #44). This plan ports **only what v2 still lacks**: the fully-unnormalized order-import path in `OrderRestController` (260610's explicit carve-out 6b), the extracted `OrderBatchCreationService` bind (the actual NPE producer), one unguarded `Optional.get()` on the advice transfer path, the advice file-import crash (NEW-1), and the `Itemdata.setItemNr` model-level trim. **No Flyway migration** (deliberate v2 divergence — see §0). Recurrence prevention only; no production blocker.

---

## §0. Affected sites

### Already normalized in v2 (by 260610 / `d1a224d`) — NOT in scope

| # | File:line | Construct | Status |
|---|-----------|-----------|--------|
| A1 | `SkuRestController` :95, :209, :309 (helper :352-359) | `normalize(SkuDto)` mutates sku/skuName at entry of create/update/delete; whitespace-only → `FIELD_NOT_SET` | ✅ done |
| A2 | `FileImportController.importSkus` :320-327 | DTO trim at entry | ✅ done |
| A3 | `ItemdataService.findByClientIdAndItemNr` :53-57 (`@Cacheable`) | trims `itemNr` arg inline — covers all ~18 caller sites incl. `AdviceRestController:234/:377`, `FileImportController:352/:427` lookups | ✅ done |
| A4 | `ItemdataService.loadItemDataSet` :80-95 | trims `skuSet` elements inline (Phase 1b, sequencing-gated) | ✅ done |

### Confirmed still needed — in scope

| # | Fix | File:line | Construct | Root cause |
|---|-----|-----------|-----------|------------|
| 1 | **O** (CRITICAL) | `OrderRestController.java` :265, :283-286, :298, :309, :326, :389, :397, :411 | Order-import path fully unnormalized: blank check `isEmpty()` (whitespace-only passes the guard, later fails at `:403` with `ENTITY_DOES_NOT_EXISTS`); dedup + `skuSet` + club comparisons on **raw** `getSkuId()`; `resolveItemData:389` calls `itemdataRepository.findByClientNumberAndSkuSet` **directly** (bypasses the trimmed `loadItemDataSet`); `:397` equality + `:411` map keys use **raw** `getItemNr()` | 260610 carve-out 6b |
| 2 | **O-bind** (LOAD-BEARING) | `OrderBatchCreationService.java` :188, :195 | `clientItemDataMap.get(clientId).get(orderPosition.getSkuId())` — **raw** bind key against the (post-Fix-O normalized) map keys; `itemData.getId()` with **no null guard**. **This bind is the actual NPE producer for a padded inbound SKU**: once `resolveItemData` is normalized, its size check (`:391`) compares normalized-set vs normalized-result and *passes*, so it does NOT fail first — the raw `.get()` at `:188` misses the normalized key → null → NPE→500 (Architect iteration-2 finding; AC-8b is the dedicated gate) | v2-only (extracted bind) |
| 3 | **ADV** | `AdviceRestController.java` :377-379 | `Itemdata itemdata = itemDataOptional.get();` — unguarded `Optional.get()` on the advice-**transfer** path → `NoSuchElementException`→500 on genuinely-unknown SKU. (The sibling `:234-237` path is **already safe** — explicit `itemData == null` → `ENTITY_DOES_NOT_EXISTS`, code-verified) | port of v1 |
| 4 | **A** | `Itemdata.java` :97-99 | `setItemNr(String)` does not trim | port of v1 (model persist chokepoint) |
| 5 | **NEW-1** (MEDIUM) | `FileImportController.java` :427-438 | Advice import: a missed SKU lookup appends an error row (:428-430) then **unconditionally** dereferences `itemData.get().getDefultypeId()` (:432) and `itemData.get().getDefaultboxtypeId()` (:436) → `NoSuchElementException`→500 instead of the aggregated error-list response | v2-only |

### Deliberate v2 divergence — do NOT port

- **v1 Fix C (Flyway `V1.26.31` data-trim).** 260610 explicitly chose a **per-tenant cleanup runbook** ([[wms2-sku-trim-data-cleanup]]) over a Flyway migration. **Do NOT create `V2.1.17`.** Data cleanliness is enforced by the blocking gate in §5.1 Prereq 1.

---

## §1. Problem Statement

An OMS SKU and the stored WMS `item_nr` differing only by leading/trailing whitespace splits one physical SKU across lookup boundaries. 260610 normalized the SKU-master write paths and the `ItemdataService` lookup choke points, but the **order-batch import** funnels a SKU through five key spaces that all still operate on the **raw** inbound string, and the extracted bind in `OrderBatchCreationService` dereferences without a null guard. A padded order line today either misses resolution (`ENTITY_DOES_NOT_EXISTS`), dedups/compares wrongly against its clean twin, or NPEs→500 at bind. This plan closes that carve-out, matching v1 `decff33`.

---

## §2. Root Cause Analysis

The order-import request funnels a SKU through **five distinct key spaces**, all currently raw. The fix must normalize all five with a single canonical normalizer or the bug survives in whichever space is missed.

| # | File | Line | Key space | Current (raw) behavior |
|---|------|------|-----------|------------------------|
| 1 | `OrderRestController.java` | 265 | blank guard | `getSkuId() == null \|\| getSkuId().isEmpty()` — whitespace-only passes the guard (then fails at `:403` with `ENTITY_DOES_NOT_EXISTS`; the fix changes the error **code** to `FIELD_NOT_SET`, both 4xx `WebserviceBusinessExceptionClientSide`) |
| 2 | `OrderRestController.java` | 283–286 | per-order dedup set | padded twin dedups as distinct |
| 3 | `OrderRestController.java` | 298 | resolve `skuSet` | feeds the native `IN`-query raw (`ItemdataRepository:41`, exact match, no DB-side trim) |
| 4 | `OrderRestController.java` | 309, 326 | club-line comparison | raw `.equals` both directions |
| 5 | `OrderRestController.java` | 389, 397, 411 | resolve lookup / equality / map key | direct repo call bypassing `loadItemDataSet`; raw stored-vs-inbound match; raw map key |
| 6 | `OrderBatchCreationService.java` | 188, 195 | line bind (**load-bearing**) | raw bind key + no null guard → NPE→500 |
| 7 | `AdviceRestController.java` | 377–379 | advice-transfer lookup | unguarded `Optional.get()` |
| 8 | `FileImportController.java` | 427–438 | advice file-import | unconditional `itemData.get()` after missed-SKU error row |
| 9 | `Itemdata.java` | 97–99 | model persist chokepoint | `setItemNr` does not trim |

`RestExceptionHandler` maps neither `NullPointerException` (site 6) nor `NoSuchElementException` (sites 7, 8) — all surface as raw HTTP 500.

**Field-access JPA (site 9).** `Itemdata` maps via field access (`@Column` on `private String itemNr`, `Itemdata.java:22-23`; no `@Access(PROPERTY)` anywhere in the file), so Hibernate sets fields directly on hydration and never calls `setItemNr` during load. **Fix A's hydration safety therefore rests on this static verification, not on a runtime test** — the load-then-flush IT is authored but `@Disabled` (SBDEV-2217).

---

## §3. Design / Proposed Fix

**Principle (consensus-final wording):** a **single canonical normalizer — `SkuCodes.normalize` — applied at every read boundary of the order-import surfaces added by this plan; the DTO is never mutated** (raw `skuId` is preserved in the `ORDER_BATCH_IMPORT` audit payload serialized at `OrderBatchCreationService:219/:223`).

**Idiom decision (Critic iteration-2 resolution).** v2's merged 260610 normalization uses **inline `.trim()`** at the `ItemdataService` choke points (`:56`, `:86`). This plan introduces `net.aim_ai.wms.util.SkuCodes` (v1-parity) and uses it **only on the new surfaces** (`OrderRestController`, `OrderBatchCreationService`). The two `ItemdataService` inline trims are **deliberately NOT refactored** onto `SkuCodes.normalize`: the semantics differ for blank input (`.trim()` → `""`; `normalize` → `null`), and while both resolve to no-match, swapping would change the issued SQL for a case that cannot occur on the new surfaces (blank is rejected at `:265` before any set/bind is built). Equivalence documented here; harmonization deferred as optional tech-debt.

### 3.1 Fix O — `OrderRestController` order-import normalization (CRITICAL)

New helper (`net.aim_ai.wms.util.SkuCodes`, mirrors v1 exactly):

```java
public final class SkuCodes {
    private SkuCodes() {}
    /** Canonical SKU form: trimmed; null/blank → null so callers hit the existing not-found path. */
    public static String normalize(String raw) {
        if (raw == null) return null;
        String t = raw.trim();
        return t.isEmpty() ? null : t;
    }
}
```

Per Architect synthesis, normalization inside `OrderRestController` is **centralized behind a private helper** (e.g. `private static String normalizedSku(OrderPositionDto pos) { return SkuCodes.normalize(pos.getSkuId()); }`) so there is one normalization point per class, not five scattered calls.

**Position loop (`:258-299`)** — normalize once per position into a local, reuse everywhere:

```java
String sku = normalizedSku(orderPosition);
if (sku == null) {                                  // was: getSkuId()==null || getSkuId().isEmpty()
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.FIELD_NOT_SET, null, "sku_id", orderPosition);
}
...
if (localItemDataIdentifierMap.contains(sku)) { ... }   // :283-286 dedup on normalized
localItemDataIdentifierMap.add(sku);
...
skuSet.add(sku);                                        // :298 — set reaching :389 is now normalized
```

**Club-line comparisons (`:309`, `:326`)**: `Objects.equals(normalizedSku(pos), normalizedSku(candidate))`.

**`resolveItemData` (`:389-414`)**: `:397` → `Objects.equals(SkuCodes.normalize(itemData.getItemNr()), SkuCodes.normalize(sku))`; `:411` → `map.put(SkuCodes.normalize(itemData.getItemNr()), itemData)`. `:389` keeps the direct repo call (its input set is already normalized upstream). A genuinely-missing SKU still fails the size check → `ENTITY_DOES_NOT_EXISTS` (no real miss masked).

**Do NOT mutate `OrderPositionDto.skuId`** — it is re-serialized into the `ORDER_BATCH_IMPORT` service-log payload (`OrderBatchCreationService:219`); the raw value is the audit evidence that diagnosed #959/SBDEV-2496. Normalize at each read instead. The verify script (§9.2) carries a grep guard that fails on any new raw `getSkuId()` read in the persistence path of these two classes.

### 3.2 Fix O-bind — `OrderBatchCreationService.createAll` normalized bind key + null guard (LOAD-BEARING)

```java
// :188  was: Itemdata itemData = clientItemDataMap.get(orderPosition.getClientId()).get(orderPosition.getSkuId());
Itemdata itemData = clientItemDataMap
        .get(orderPosition.getClientId())
        .get(SkuCodes.normalize(orderPosition.getSkuId()));      // LOAD-BEARING: must match §3.1's normalized map keys
if (itemData == null) {                                          // defensive backstop (key desync)
    throw new WebserviceBusinessExceptionClientSide(
        WmsConstants.ENTITY_DOES_NOT_EXISTS, null, "sku", orderPosition.getSkuId(), orderPosition);
}
```

- The **normalized bind key is load-bearing** (see §0 row 2): without it, a padded inbound SKU with a valid trimmed row sails through `resolveItemData` and NPEs here. AC-8b asserts the end-to-end padded import succeeds **via the bind**, not via the guard.
- The **null guard is the defensive backstop** for future key desync; it cannot be provoked through the real controller flow, so `OrderBatchCreationServiceUnitTest` exercises `createAll` in isolation with a deliberately-mismatched map (AC-9).
- Invariant (open question resolved): the outer `clientItemDataMap.get(clientId)` cannot be null — every batch `clientId` is inserted at `OrderRestController:297` from the same positions that reach `createAll`.
- Contract-safe: `createAll` is `@Transactional(value="tenantTransactionManager", rollbackFor={WebserviceBusinessExceptionClientSide.class, BusinessException.class})` (`:68`) and declares `throws WebserviceBusinessExceptionClientSide` (`:74`); the guard throws inside the existing tenant tx before further persists.

### 3.3 Fix ADV — `AdviceRestController` advice-transfer `orElseThrow`

```java
// :378-379  was: Itemdata itemdata = itemDataOptional.get();
Itemdata itemdata = itemDataOptional.orElseThrow(() ->
    new WebserviceBusinessExceptionClientSide(
        WmsConstants.ENTITY_DOES_NOT_EXISTS, null, "sku", orderPositionDto.getSkuId(), orderPositionDto));
```

The lookup already trims via `ItemdataService` (A3); this only replaces the unguarded `.get()`. The `:234-237` sibling path **already** null-checks and throws `ENTITY_DOES_NOT_EXISTS` — code-verified, no change. Implementation must confirm the enclosing method's transactional posture (if `@Transactional`, `WebserviceBusinessExceptionClientSide` must be in its `rollbackFor`).

### 3.4 Fix A — `Itemdata.setItemNr` null-safe trim (model chokepoint)

```java
public void setItemNr(String itemNr) { this.itemNr = (itemNr == null) ? null : itemNr.trim(); }
```

**Trade-off named explicitly (Critic finding):** both current writers already receive trimmed input via 260610 (`SkuBatchCreateUpdateService:49` consumes the normalized DTO; `FileImportController:369` after the `:322` entry trim), so Fix A adds **zero coverage today** — it is pure defense-in-depth for future writers, retained for v1-parity. Its hydration safety rests on **static field-access verification** (§2), confirmed independently by Architect and Critic; the load-then-flush IT stays `@Disabled TODO(SBDEV-2217)` as standing debt.

### 3.5 Fix NEW-1 — `FileImportController` advice-import guard (MEDIUM)

Guard the dependent dereferences at `:432`/`:436` on `itemData.isPresent()`, preserving the method's error-accumulation style (append to `errors`, skip the dependent checks for that row, keep processing siblings). Confirm the exact skip construct (`continue` vs guarded block) against the enclosing loop at implementation so the aggregated `errors` response shape is unchanged.

### 3.6 Runbook update (consensus-mandated, ships with this plan)

Update [[wms2-sku-trim-data-cleanup]]:
1. **§3 gated surfaces:** add `OrderRestController.resolveItemData` (`:389/:397/:411`) **and** `OrderBatchCreationService` bind (`:188`) as the third/fourth normalized surfaces, landing with this plan (the runbook currently lists only `findByClientIdAndItemNr` + `loadItemDataSet`).
2. **Correct the false unique-constraint premise** (runbook `:41-42`): `uk3l3dgof3l6mc1dl7s3lmida65 UNIQUE (client_id, item_nr)` **exists** in v2 (`V1.0.01__wms_tables.sql:363`; `item_nr NOT NULL` `:347`). An unresolved-collision trim UPDATE raises `23505` and rolls back — **safer than documented**; the operator's mental model must reflect DB-enforced collision-resolution-before-trim.

**Files changed:** new `util/SkuCodes.java`; `controller/rest/OrderRestController.java`; `service/OrderBatchCreationService.java`; `controller/rest/AdviceRestController.java`; `model/Itemdata.java`; `controller/FileImportController.java`; runbook doc. **No** migration, **no** sysprop, **no** schema change.

---

## §4. V1/V2 Applicability

| V1 Fix (`decff33`) | Description | V2 Verdict | Rationale |
|--------|----------------|----------------|--------|
| Fix B @ `SkuRestController` (3 endpoints) | normalize lookups + persist, blank rejection | **Not needed (V2 already correct)** | 260610 DTO normalize :95/:209/:309 |
| Fix B @ `FileImportController` SKU import | normalize lookup + persist | **Not needed (V2 already correct)** | 260610 entry trim :320-327 |
| Fix B @ `AdviceRestController` lookups | normalize both SKU lookups | **Not needed (V2 already correct)** | choke-point trim (A3) |
| Fix B @ `AdviceRestController` `.get()` → `orElseThrow` | clean error on transfer path | **Needed** | §3.3 (`:378-379`) |
| Fix B @ `OrderRestController` order import | normalize all key spaces + bind null guard | **Needed (CRITICAL)** | §3.1 + §3.2; v2 bind is in extracted `OrderBatchCreationService` (architecturally different locus) |
| Fix A `Itemdata.setItemNr` trim | persist chokepoint | **Needed** (defense-in-depth) | §3.4 |
| Fix C Flyway `V1.26.31` data-trim | one-time data migration | **Not applicable** | deliberate v2 divergence — runbook (§0) |
| — | advice file-import crash | **NEW-1 (v2-only)** | §3.5 |

---

## §5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state — BLOCKING PER-TENANT DEPLOY GATE** | The [[wms2-sku-trim-data-cleanup]] runbook has **NOT been executed on any tenant** (execution log: dev censuses only; hydra `BONMFPN23` collision pair unresolved). Before Fix O deploys to a tenant: run the census (0 untrimmed `item_nr`) and resolve collision pairs per the runbook. **Do not deploy to an uncleaned tenant.** | DBA / support | Failure mode on an uncleaned tenant: a padded stored row with no trimmed twin becomes unreachable (`ENTITY_DOES_NOT_EXISTS`); a duplicate pair where the **padded** row holds live stock rebinds orders to the empty clean twin → "No fixed assigned location" hold — the original SBDEV-2496 symptom, self-inflicted at deploy. Fail-visible (hold, not silent loss); recoverable via the runbook. |
| 2 | Feature flags / sysprops | N/A — unconditional normalization | — | Pure code |
| 3 | Config / env | N/A | — | |
| 4 | Deploy-order dependencies | 260610 (`d1a224d`) already on `develop` — this plan depends on its choke-point trims | Release owner | merged; verify at branch time |
| 5 | Data migration | N/A — **no Flyway migration** (v2 divergence) | — | Do NOT create `V2.1.17` |
| 6 | External systems | Optional: OMS-side SKU-master trim ticket | OMS owner | defense in depth |
| 7 | Access / permissions | N/A | — | |
| 8 | Monitoring / alerts | Optional canary: `SELECT count(*) FROM itemdata WHERE item_nr <> trim(item_nr)` per tenant post-deploy | — | reuse 260610 discovery query |

### 5.2 Implementation Checklist

- [ ] **S1** Add `net.aim_ai.wms.util.SkuCodes.normalize` (trim, blank→null).
- [ ] **S2** `Itemdata.setItemNr` null-safe trim (Fix A).
- [ ] **S3** `OrderRestController`: private `normalizedSku(pos)` helper; blank guard (`:265` → `FIELD_NOT_SET`), dedup (`:283-286`), `skuSet` (`:298`), club comparisons (`:309`,`:326`), `resolveItemData` equality (`:397`) + map key (`:411`) — all via the helper / `SkuCodes.normalize` (Fix O).
- [ ] **S4** `OrderBatchCreationService.createAll`: **normalized bind key** (`:188`, load-bearing) + null guard → `ENTITY_DOES_NOT_EXISTS` (Fix O-bind).
- [ ] **S5** `AdviceRestController` `:378-379` `orElseThrow(ENTITY_DOES_NOT_EXISTS)` (Fix ADV).
- [ ] **S6** `FileImportController` advice import: guard `:432`/`:436` dereferences on `isPresent()` (Fix NEW-1).
- [ ] **S7** Runbook update per §3.6 (gated surfaces + unique-constraint correction).
- [ ] Unit tests for S1–S6; ITs authored `@Disabled TODO(SBDEV-2217)`.
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2496-trailing-space-sku-duplication-v2.sh` → `0 fail`.
- [ ] `mvn clean compile` + targeted `mvn test` green.
- [ ] Code review completed.

### Phase 0 — Transaction & concurrency posture

**No new `@Transactional` is introduced or modified, and none is needed.** All changes are read-side (lookup keys, equality, map keys), DTO-level (in-memory string normalization), or model-level (setter trim). `createAll` already runs in the correct tenant tx (`:68`) with the thrown exception in `rollbackFor`; the guard throws before further persists. `Itemdata.setItemNr` fires only on application writes (field-access JPA) — no dirty-check UPDATE on read paths, no `@Version` churn, no OSIV/lazy-load change, no cross-manager write.

---

## §6. Test Plan

> **v2 IT harness caveat (SBDEV-2217).** Testcontainers lane cannot boot. Gate on **unit tests + `mvn clean compile`**; ITs authored but `@Disabled` with `TODO(SBDEV-2217)`.

### New / updated tests → acceptance criteria

| AC | Statement | Test |
|----|-----------|------|
| **AC-1** | `SkuCodes.normalize` trims; blank→null; null→null | `unit/util/SkuCodesUnitTest` (new) |
| **AC-2** | `Itemdata.setItemNr` trims non-null; null stays null | `unit/model/ItemdataUnitTest` |
| **AC-3** | Whitespace-only order `skuId` → `FIELD_NOT_SET` (error-code change from `ENTITY_DOES_NOT_EXISTS`; both 4xx) | `OrderRestControllerUnitTest#import_whitespaceOnlySku_fieldNotSet` |
| **AC-4** | Padded order line resolves against the normalized master row in `resolveItemData` | `OrderRestControllerUnitTest#import_paddedLine_resolvesNormalizedItemdata` |
| **AC-5** | Padded twins in one order dedup as the same SKU (`NOT_UNIQUE_VALUE`) | `OrderRestControllerUnitTest#import_paddedTwins_dedupCollapses` |
| **AC-6** | Club-line SKU comparison is whitespace-tolerant | `OrderRestControllerUnitTest#import_clubPaddedSku_sameLine` |
| **AC-7** | Unknown order SKU → `ENTITY_DOES_NOT_EXISTS` (clean 4xx, not 500) | `OrderRestControllerUnitTest#import_unknownSku_entityDoesNotExist_not500` |
| **AC-8** | `createAll` binds a padded inbound SKU via the **normalized key** | `OrderBatchCreationServiceUnitTest#createAll_normalizedBindKey_resolvesPaddedInbound` |
| **AC-8b** | End-to-end: a trailing-space inbound SKU whose only matching row is a trimmed `itemdata` imports successfully — asserting the `:188` bind **hits** (guard NOT triggered) | `OrderBatchCreationServiceUnitTest#createAll_paddedSku_bindsWithoutGuard` (map keyed normalized, position padded) |
| **AC-9** | `createAll` with a deliberately-mismatched map → `ENTITY_DOES_NOT_EXISTS`, not NPE (defensive guard; not provokable via controller flow) | `OrderBatchCreationServiceUnitTest#createAll_missingItemData_throwsEntityDoesNotExist_notNpe` |
| **AC-10** | Advice transfer unknown SKU → `ENTITY_DOES_NOT_EXISTS`, not `NoSuchElementException`→500 | `AdviceRestControllerUnitTest#transfer_unknownSku_throwsEntityDoesNotExist` |
| **AC-11** | Advice file-import unknown SKU → error row in aggregated response; siblings processed; no 500 | `FileImportControllerUnitTest#importAdvice_unknownSku_appendsErrorRow` |
| **AC-12** (deferred) | Load-then-flush of a legacy whitespace row issues no UPDATE | `ItemdataHydrationIT` (`@Disabled TODO(SBDEV-2217)`) |

> Test-class names: match the existing test-class naming for these production classes at implementation time (check `src/test/java/net/aim_ai/wms/unit/**` before creating new classes; extend existing ones where present).

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Padded order import binds clean row | dev tenant (post-cleanup census) | `POST /rest/order/...` with line `skuId = "<existing> "` | 2xx; single `customerorder_position` bound to the clean `itemdata`; no 500 |  |
| Unknown SKU order import | dev tenant | import a line with a nonexistent SKU | clean 4xx `ENTITY_DOES_NOT_EXISTS`, not 500 |  |
| Advice file-import partial errors | dev tenant | upload advice file with one absent SKU among valid rows | aggregated error response; valid rows unaffected; no 500 |  |
| No new whitespace SKUs post-deploy | dev tenant DB | canary query after an order sync | count does not grow |  |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|------------------------------|
| `mvn clean compile` | | |
| `mvn test -Dtest='<the classes above>'` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| `ItemdataHydrationIT`, `OrderImportNormalizationIT` | SBDEV-2217 harness; authored `@Disabled`, enable when unblocked |
| Full `mvn verify` | same |

---

## §7. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | Pure string normalization + null guards; no static/ThreadLocal/cache added |
| 2 | Connection pool math | **No** | No new query |
| 3 | Scheduled jobs | **No** | None touched |
| 4 | Long transactions | **No** | Existing `createAll` boundary; guard throws before extra persist |
| 5 | Request affinity | **No** | Stateless |
| 6 | Retry / idempotency | **N/A — note** | REST idempotency (SBDEV-2222) hashes the **raw** body: `"SKU"` and `"SKU "` stay distinct requests (distinct dedup rows) but converge on the same `itemdata` row at bind — intended fix, not a regression |
| 7 | Tenant context | **No** | Synchronous request thread only |
| 8 | Distributed locks | **No** | No lock changes |
| 9 | Cache invalidation | **Yes — benign, pre-existing** | `ItemdataService.findByClientIdAndItemNr` `@Cacheable` key uses the **raw** `#itemNr` arg while the body queries trimmed (260610) → padded+trimmed inputs = two cache entries for the **same** row (lower hit rate, never stale/wrong). This plan does not touch that method (order import uses `findByClientNumberAndSkuSet`, uncached). Documented, not mitigated |
| 10 | External notifications | **No** | `ORDER_BATCH_IMPORT` service-log write pre-existing and unchanged (raw DTO deliberately preserved) |

### Evidence

| Concern | Verified | File:line |
|---------|-----------|-----------|
| 9 | raw `#itemNr` cache key vs trimmed body | `service/ItemdataService.java:52-57` |
| 6 | raw-body idempotency hash | `IdempotencyFilter` (SBDEV-2222), wms2-api CLAUDE.md |

---

## §8. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Wrong-row bind on an uncleaned tenant** (padded stored row + trimmed lookups) | Low (dev data shows padded rows at zero stock) | High (order hold / pick-from-wrong-row; fail-visible) | §5.1 Prereq 1 **blocking per-tenant census gate**; runbook remediation |
| **Pre-existing live exposure (independent of this plan):** 260610's merged choke-point trims (`ItemdataService:56/:86`, ~18 caller sites) already carry the same hazard on uncleaned tenants | Unknown (depends where PR #44 is deployed) | High | Census framed as **overdue**, not merely a SBDEV-2496 prereq; open question: which qa/prod tenants run PR #44 and have they been censused? |
| Normalization-invariant rot (a future raw `getSkuId()` read in the persistence path) | Medium over time | Medium | Private-helper centralization + verify-script grep guard (§9.2) |
| Error-code change for whitespace-only SKU (`ENTITY_DOES_NOT_EXISTS` → `FIELD_NOT_SET`) | Certain | Low (both 4xx client-side) | Documented for OMS reviewers (AC-3) |
| Club-comparison behavior change (padded twins now match) | Certain | Low (intended) | AC-6 |
| Two normalization idioms in codebase (`SkuCodes` new surfaces vs inline `.trim()` choke points) | Certain | Low | §3 idiom decision documents equivalence; harmonization deferred |

---

## §9. Acceptance & Implementation

### 9.1 ADR (consensus record)

- **Decision:** Option A — per-site normalization via new `SkuCodes.normalize`, centralized behind a private helper in `OrderRestController`; normalized load-bearing bind + defensive guard in `OrderBatchCreationService`; DTO never mutated. No Flyway migration.
- **Drivers:** five-key-space completeness; error-contract stability on a live OMS ingress; consistency with 260610.
- **Alternatives:** Option B (route `:389` through `loadItemDataSet`) — rejected: covers 1 of 5 key spaces, changes error contract to `BusinessException`. DTO-mutate-once + `rawSkuId` audit field (Architect antithesis) — rejected: destroys raw audit value at `OrderBatchCreationService:219`; synthesis (helper + grep guard) adopted instead.
- **Consequences:** normalization is an every-read-boundary discipline backstopped mechanically; census gate becomes a hard deploy dependency; `SkuCodes` and inline-`.trim()` idioms coexist (documented).
- **Follow-ups:** SBDEV-2217 unblocks AC-12; optional idiom harmonization; OMS-side trim ticket; unique index on `(client_id, trim(item_nr))` remains deferred (260610 §9).
- **Consensus:** Architect APPROVE (iter 1 with amendments; iter 2 APPROVE, `:188` load-bearing correction folded). Critic ITERATE ×2 → all findings discharged in this document (persisted artifact, idiom decision, `:188` citation, `:379` scope ruling, runbook task, live-exposure risk row, verify-script authored).

### 9.2 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2496-trailing-space-sku-duplication-v2.sh` — authored with this plan (baseline all-FAIL pre-implementation). Positive checks S1–S6 + runbook S7; **negative checks**: raw `skuSet.add(getSkuId())` gone, raw resolve map key gone, raw bind key gone, **no new trim Flyway migration** (v2 uses the runbook — deliberately inverted from the v1 script's S6), and a **persistence-path guard**: no `getSkuId()` read inside `OrderRestController`'s position-validation/resolve region or `OrderBatchCreationService`'s bind region without an enclosing `SkuCodes.normalize(`/`normalizedSku(` (raw reads remain legal only in error-message args and the audit serialization).

### 9.3 Recommended OMC composition

| Aspect | Value |
|---|---|
| Size class | Standard (6 fix sites, 2 controllers + 1 service + 1 model + 1 util + 1 doc) |
| Plan-review | ralplan consensus — **done 2026-07-10** |
| Implementation | executor |
| Verification | verify-script + verifier |
| Code-review | code-reviewer (OMS ingress boundary) |
| Commits | (1) `SkuCodes` + `Itemdata`; (2) `OrderRestController` + `OrderBatchCreationService`; (3) `AdviceRestController` + `FileImportController`; (4) runbook doc |

---

## §10. Open Questions

- [ ] **Census status per tenant** — which qa/prod tenants run 260610 (PR #44) today, and have their censuses been run? Gates Prereq 1 AND quantifies the pre-existing exposure (§8 row 2).
- [ ] **FileImport advice-loop skip construct** — `continue` vs guarded block; confirm at implementation against the enclosing loop.
- [ ] **`AdviceRestController` transfer method transactional posture** — if `@Transactional`, confirm `WebserviceBusinessExceptionClientSide` in `rollbackFor` before adding the `orElseThrow`.

## §11. Implementation Status

**Implemented 2026-07-10** (branch `port/SBDEV-2496-sku-normalization`, [PR #66](https://github.com/SiteBossInc/wms2-api/pull/66) → `develop`).

### Commits (v2/wms2-api)
| SHA | Scope |
|---|---|
| `9aa6b91` | S1 `SkuCodes` util + S2 `Itemdata.setItemNr` trim (+ `SkuCodesUnitTest`, `ItemdataUnitTest`) |
| `2edbf0f` | S3 `OrderRestController` five key spaces + S4 `OrderBatchCreationService` load-bearing bind + guard (+ tests) |
| `b4cd676` | S5 `AdviceRestController` orElseThrow + S6 `FileImportController` advice-import guard (+ tests; 4 pre-existing tests that pinned the crash updated to assert the real rejection contract) |

S7 runbook update applied directly to [[wms2-sku-trim-data-cleanup]] (sbdocs, not in git): 4-surface gated table + unique-constraint correction (`uk3l3dgof3l6mc1dl7s3lmida65` exists; collision trim → 23505 rollback).

### Tests / gates
- TDD gate (pre-implementation): 15 tests, 11 failed-for-right-reason baseline; 4 benign passes analyzed (AC-4 size-check shortcut, AC-7 resolve-layer already clean, 2 null-input cases).
- `mvn test` (6 affected suites): **193 run / 0 failures / 0 errors**; post-review comment-hygiene delta re-run exit 0.
- `mvn clean compile`: BUILD SUCCESS (497 sources).
- Verify script: **`Result: 16 pass, 0 fail, 1 skip`** (skip = commented mvn rows placeholder).
- AC-12 hydration IT deferred `@Disabled TODO(SBDEV-2217)`.

### Review
- Code review (code-reviewer): **APPROVE — 0 HIGH / 0 MEDIUM / 3 LOW.** 2 LOW comment-hygiene items fixed; 1 LOW pre-existing recorded as follow-up (below). Both executor judgment calls verified legitimate (S6 test rewrite un-pinned the crash; STRICT_STUBS prunes proven safe).
- Deslop pass: no-op (diff already minimal/plan-shaped).

### Follow-ups
- **Pre-existing (out of scope):** `AdviceRestController.createTransfer` has no `@Transactional` — `adviceRepository.save` commits before the position loop, so a failed position bind leaves an orphan Advice header. This port improves the failure (500→clean 400) but the orphan remains; candidate ticket: wrap in tenant `@Transactional(rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`.
- §10 open question outstanding: per-tenant census status for the deploy gate (Prereq 1) — operational, owned by DBA/support.
- `wms2-rest-api-reference.md` errata on next verification: whitespace-only order `sku_id` now `FIELD_NOT_SET`; advice-transfer unknown SKU now 4xx.
