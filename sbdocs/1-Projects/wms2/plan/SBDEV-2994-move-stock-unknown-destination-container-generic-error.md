---
title: "Move Stock: unknown / retired destination container returns 404 and shows the generic network toast"
ticket: "SBDEV-2994"
ticket_url: "https://app.clickup.com/t/868ktubtu"
type: "bugfix"
priority: "normal"
status: "merged — all 3 PRs in develop (web 99e2359 -> api 6135203 -> mobile 7f83d55); V2.2.17 APPLIED to wineco dev, sysprop seeded false (shadow). R3 still blocks per-tenant ENABLEMENT; §8.6 manual plan not executed; the null/dangling-storagelocation_id population remains unmeasured (§13)."
project:
  - wms2
version: "v2"
requester: "Zeshan (via Nam Park)"
created: 2026-08-18
updated: 2026-08-19
db_verified: true
related:
  - "[[wms2-move-stock-unitload-workflow]]"
  - "[[wms-exception-taxonomy]]"
  - "[[wms2-stockunit-design]]"
tags:
  - plan
  - wms2
  - move-stock
  - error-handling
---

# Move Stock: unknown / retired destination container returns 404 and shows the generic network toast

**Ticket:** [SBDEV-2994](https://app.clickup.com/t/868ktubtu)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** normal
**Status:** **Reviewed across two ralplan consensus rounds (5 independent reports). All 22 iteration-1 and 21 iteration-2 findings applied.** Gate-ready for **Fixes A, B, C and D**. ⚠ §12 Q5 was **downgraded from blocking to confirm-and-close** on 2026-08-18 after measurement showed the competing design's auto-create path has never been used on any measured tenant. R3 no longer blocks implementation — it blocks per-tenant *enablement* (§5 Fix B shadow mode). See §14.
**Date:** 2026-08-18

**Acceptance script:** `sbdocs/9-System/scripts/verify-SBDEV-2994-move-stock-unknown-destination-container-generic-error.sh`

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep, not memory. Method:

```
grep -rn "\.transferStock(" v2/wms2-api/src/main/java v2/wms2-api/src/test/java   # callers
grep -c "EntityNotFoundException" v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockunitService.java   # 34
grep -rn "stockUnit/transferStock\|bulkTransferStock" v2/wms2-web-ui v2/wms2-mobile-ui --include=*.vue --include=*.js
```

⚠ **The third grep is why the first draft missed the most important site in the estate** (§14.1 C1). Scoping
the client sweep to two *URL fragments* structurally cannot find a sibling endpoint under a different
prefix. **Corrected method — enumerate by SCREEN, not by URL:** sweep every `$axios` call in the
screen's store module, then resolve each to its controller and service.

```
grep -n "axios" v2/wms2-mobile-ui/store/moveStock.js       # 5 endpoints, not 1
grep -rn "moveStock/" v2/wms2-mobile-ui --include=*.vue    # which actions are actually dispatched
```

That sweep finds **`POST /moveStock/scanDestination`** at `store/moveStock.js:133-136` — a second live
server path for this screen, and a second unfixed instance of this defect. See rows 26-28.

All line numbers are against `origin/develop` (`d2bedc0` for wms2-api, `8e623b8` for wms2-mobile-ui) unless noted.

### 0.1 The `EntityNotFoundException` sites inside `StockunitService.transferStock`

| # | File:line | Construct | Identifier comes from | Same root-cause? | In-scope? |
|---|-----------|-----------|----------------------|------------------|-----------|
| 1 | `StockunitService.java:156` | `unitloadRepository.findByLabelid(unitLoadLabelId).orElseThrow(EntityNotFoundException)` | **Operator scan** (mobile `scannedValue`, web `container`) | **yes — the reported defect** | **yes — Fix A** |
| 2 | `StockunitService.java:178` | `locationRepository.findByName(locationName).orElseThrow(...)` | **Client-supplied** (mobile hardcodes `'Clearing'`; web sends the dropdown selection; `CancellationReversalService` sends `pickfromlocationname`) | yes — same class of miss | **yes — Fix A** |
| 3 | `StockunitService.java:157` | `unitloadTypeRepository.findByName(UNIT_LOAD_TYPE_PALLET)` | Internal constant | no — config/referential integrity | no — stays `EntityNotFoundException`; covered by Fix C |
| 4 | `StockunitService.java:161` | `unitloadRepository.findById(stockUnit.getUnitloadId())` | Internal FK | no | no — Fix C |
| 5 | `StockunitService.java:168` | `locationRepository.findById(pallet.getStoragelocationId())` | Internal FK | no | no — Fix C |
| 6 | `StockunitService.java:179` | `locationTypeRepository.findById(destinationLocation.getTypeId())` | Internal FK | no | no — Fix C |
| 7 | `StockunitService.java:188` | `locationRepository.findById(fixedAssignment...)` | Internal FK | no | no — Fix C |
| 8 | `StockunitService.java:194,202` | `unitloadRepository.findById(fla.getAssignedunitloadId())` | Internal FK | no | no — Fix C |
| 9 | `StockunitService.java:201` | `fixedLocationAssignmentOpt.orElseThrow(...)` | Internal | no | no — Fix C |
| 10 | `StockunitService.java:207,208,218` | `findById(suUnitLoad…)`, `findById(ulLocation…)` | Internal FK | no | no — Fix C |
| 11 | `StockunitService.java:225` | `unitloadTypeRepository.findByName(UNIT_LOAD_TYPE_BOX)` | Internal constant | no | no — Fix C |
| 12 | `StockunitService.java:227` | `clientRepository.findById(stockUnit.getClientId())` | Internal FK | no | no — Fix C |
| 13 | `StockunitService.java:269` | `syspropRepository.findBySyskeyAndClientId(WAREHOUSE_NAME)` | Config | no | no — Fix C. ⚠ **CORRECTED:** the first draft said "only reachable when `printLabel=true`; both UIs send `false`". The desktop popup has a **Print Label switch** (`wms2-web-ui .../popups/transferStock.vue:43`, sent at `:104`), so this block — and the **three further** `EntityNotFoundException` sites in `:269-290` — are reachable in production |
| **14** | **`StockunitService.java:169`** | **`defaultUnitLoadType.get()`** — an unguarded `Optional.get()` after an `isPresent()` fallback that can itself be empty | Internal | **no — but it is a `NoSuchElementException`, not an `EntityNotFoundException`** | ⚠ **NOT netted by Fix C.** `RestExceptionHandler:145-150` maps it to **500**. It sits in the pallet branch of the *existing-container* path — the reported path. See §5 Fix C for the decision |

**The split rule** (see §5.4 for the justification): an identifier the **operator typed or scanned** produces a `BusinessException` the operator can act on; an identifier **derived internally** from a foreign key, a constant, or a sysprop stays an `EntityNotFoundException`, because "your scan is wrong" is false and misleading for a broken FK.

### 0.2 Callers and clients of the affected endpoint / service method

| # | Site | Role | Behaves how today | In-scope? |
|---|------|------|-------------------|-----------|
| 14 | `StockUnitController.java:63-112` `transferStock` | The reported endpoint | catches `BusinessException` + `FacadeException` only → any `EntityNotFoundException` escapes to **404** | **yes — Fix C** |
| 15 | `StockUnitController.java:115-176` `bulkTransferStock` | Sibling, same service call at `:153` | **already** catches `EntityNotFoundException` at `:165-167` → 200 `{errors:[…]}` | ⚠ **CORRECTED — Fix A DOES change its behaviour.** The catch at `:163-167` is **outside** the `for` loop at `:142-162`. Today a dead label throws on iteration 1 → outer catch → **1 error, loop ABORTS**, remaining ids never attempted. After Fix A it throws `BusinessException` → the **inner** catch at `:154` → **loop continues, N errors**, and the `field` value flips from `"Entity Not Found"` to `"Runtime Error"`. The first draft asserted "unchanged" in three places (§0.2, §8.6 M6, §12). Arguably an improvement, but it must be **owned, tested and manually re-verified** — see §8.2 and M6 |
| 16 | `CancellationReversalService.java:203` | System caller (`isTransferToExistingContainer=false`) | enclosing `completeReversal` already `throws BusinessException, FacadeException` (`:172`), and already raises `BusinessException` for a not-found stock unit at `:186-187` | yes — compile + behaviour impact of Fix A must be confirmed, no new code |
| 17 | `wms2-mobile-ui components/moveStock/scanDestination.vue:174-184` | Reporter's screen | posts straight to `transferStock`; **no client-side container validation** | **yes — Fix D (parity)** |
| 18 | `wms2-mobile-ui store/moveStock.js:167-183` | Dispatch + toast | `results.errors` → real message; `catch` → generic toast | yes — no change needed once the server returns 200 (see §5, Fix D) |
| 19 | `wms2-web-ui components/handlingUnits/popups/transferStock.vue:140-146` | Desktop equivalent | **already** pre-validates via `checkContainer` → `GET /stockUnit/isUnitLoadIdValid/{labelId}` → "Container does not exist" | **yes — one-line toast reword** (§12 Q1) |
| 20 | `wms2-web-ui store/handlingUnits/stockUnits.js:160-173, 307-321` | Desktop dispatch | identical `results.errors` / generic-catch shape | no change needed once the server returns 200 |
| 21 | `StockUnitController.java:557-564` `isUnitLoadIdValid` | Existence probe used by the web UI | `findByLabelid(...).isPresent()` — **existence only, no usability check** | **yes — Fix B extends it** |
| **26** | **`MoveStockController.java:96-117` `POST /v3/moveStock/scanDestination`** | **A SECOND live server path for the reporter's screen** | catches **only** `BusinessException`/`FacadeException` at `:102-108` — byte-identical to the defect in `StockUnitController:96-102` — while `MobileMoveStockService.selectDestination` throws `EntityNotFoundException` at ~15 sites | **no — split to SBDEV-2996.** Same defect class, different endpoint; fixing it here would double this ticket |
| **27** | **`MobileMoveStockService.java:235-349` `selectDestination`** | The purpose-built, better-guarded implementation of this screen | destination-label miss → **keyed** `BusinessException("noValidString")` `:294-307`; unknown-but-well-formed label → **auto-creates** at Clearing `:309-317`; Nirvana guard `:320-324`; source-on-hold guard `:240-242` | **no — but it is the PRECEDENT this plan should have cited**, and it forces a product question (§12 Q5) |
| **28** | **`wms2-mobile-ui store/moveStock.js:133-151`** | `scanDestination` action posting to row 26 | **DEAD CODE** — nothing dispatches `moveStock/scanDestination`; `components/moveStock/scanDestination.vue:184` dispatches `moveStock/transferStock` instead | no — SBDEV-2996 |
| 22 | ~12 of 13 mobile store modules (⚠ **corrected** from "~10"; the first draft's list omitted `store/index.js`) and **30+** web store modules with the identical blanket `catch` toast (`putaway.js`, `palletizing.js`, `truckLoading.js`, `transferOrder.js`, `lookup.js`, `home.js`, `cycleCount.js`, `picking.js`, `replenish.js`, `moveUnitload.js`) | Cross-cutting | same unactionable message on any non-2xx | **no — out of scope**, see §12 Q3 |

### 0.3 Existing test surface that must not regress

| # | File | Why it matters |
|---|------|----------------|
| 23 | `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceTransferStockGuardTest.java` | SBDEV-2074/2033 invariant: `transferStock` must never call `recalculateForItem`. Exercises the `false` branch with `locationName="DEST-900"` — **Fix A changes the throw type on that path**, so this class is directly adjacent |
| 24 | `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java:1454-1968` | 9 `transferStock` invocations across both branches |
| 25 | `src/test/java/net/aim_ai/wms/unit/controller/StockUnitControllerUnitTest.java:161-342` | Controller contract, incl. the bulk loop at `:334-342`. ⚠ `bulkTransferStock_entityNotFound_…` **does not exist** — the `BulkTransferStock` nested class has exactly two tests (`:315-344`, `:346-364`), neither exercising `EntityNotFoundException`. §8.2 must **write** it, not "keep it green" |
| **29** | **`StockUnitControllerUnitTest.IsUnitLoadIdValid.returnsTrueWhenUnitloadExists` (`:1030-1044`)** | ⚠ **Fix B breaks this.** It stubs only `findByLabelid` and builds `new Unitload()` whose `getStoragelocationId()` is **`null`**. After the probe becomes `unitLoad.filter(destinationEligibilityService::canReceiveStock)` the mock returns `false` by default and `jsonPath("$", is(true))` fails. ⚠ **Remediation corrected:** this needs a **new `@Mock DestinationEligibilityService` and `@InjectMocks` rewiring**, not a "restub" of `StockunitService` as an earlier revision said — after the extraction the controller depends on a different collaborator |
| **30** | **`StockunitServiceUnitTest.transfersToExistingNonPalletContainer` (`:1454`) and `.transferStock_doesNotTriggerReplenishmentMaintenance` (`:1508`)** | ⚠ **Fix B breaks both** — neither stubs `locationRepository.findById(10L)`, and Mockito returns `Optional.empty()` for unstubbed `Optional` returns, so the new guard's lookup throws. §6 mis-attributes this to "the new throw types"; it is a **missing-stub** failure and an implementer following §6 will look in the wrong place. (`:1484` and `:1543` survive — both already stub it) |
| **31** | **`wms2-mobile-ui test/components/move-damaged-reason-payload.spec.js`** | ⚠ **Fix D breaks this.** It mounts `moveStock/scanDestination.vue` in `existing` mode, calls `wrapper.vm.submit()` **synchronously** and asserts `toHaveBeenCalledTimes(1)` (`:359-365`). Fix D inserts an `await`ed dispatch before the transfer dispatch, changing both the count and the synchronicity. §0.3 originally listed three Java files and **zero** mobile specs |
| **32** | **`wms2-mobile-ui test/pages/workflow-reset-on-entry.spec.js`** | Also drives this component; check before editing `submit()` |

Every in-scope row above is addressed in §3 or §5.

---

## 1. Problem Statement

### 1.1 Symptom

On the mobile **Move Stock → Scan Destination Container** screen, an operator who scans a destination container label that no longer resolves gets:

> **Error: Request failed due to a network or server issue. Please retry.**

The message is wrong (nothing is wrong with the network or the server) and unactionable (it names no container and suggests a retry that can never succeed). The operator's only recourse is to guess.

### 1.2 Report

Zeshan, on the **WineCo dev** server, 2026-08-18:

| Field | Value |
|---|---|
| Page | Scan Destination Container |
| Container (source) | `UL319408` |
| Location | `Clearing` |
| Scan Existing Container (destination) | `UL314581` |
| Comment / Reason (optional) | `T10 move stock testing1` |

### 1.3 DB verification (analysis protocol §8 — `db_verified: true`)

Run against the `wms2-wineco-dev` MCP on 2026-08-18.

```sql
SELECT id, labelid, entity_lock, storagelocation_id, type_id, client_id, created, modified
FROM unitload WHERE labelid IN ('UL319408','UL314581');
```

```
id=30676364  labelid='UL319408'  entity_lock=0  storagelocation_id=1  type_id=4  client_id=55750
             created=2026-08-18 19:03:50Z
-- one row only: there is NO row with labelid = 'UL314581'
```

The destination is not missing — it has been **renamed**:

```sql
SELECT id, labelid, entity_lock, storagelocation_id FROM unitload WHERE labelid LIKE 'UL31458%';
```

```
id=21552195  labelid='UL314581-X-21552195'  entity_lock=2  storagelocation_id=0
```

```sql
SELECT id, name FROM location WHERE id IN (0,1);          -- 0='Nirwana', 1='Clearing'
```

```sql
SELECT id, label, activitycode, recordtype, fromlocation, tolocation, operator, created
FROM unitload_record WHERE label LIKE 'UL314581%' ORDER BY created DESC LIMIT 1;
```

```
id=29882182  label='UL314581'  activitycode='SEND_TO_NIRWANA'  recordtype='TRANSFERRED'
             fromlocation='StagingLane07'  tolocation='Nirwana'
             operator='panderson'  created=2026-06-01 18:23:53.209679Z
```

And the source stock is healthy, so the move would have succeeded against a live destination:

```sql
SELECT id, amount, reservedamount, entity_lock FROM stockunit WHERE unitload_id = 30676364;
```

```
id=30676366  amount=4.0000  reservedamount=0.0000  entity_lock=0
```

`entity_lock=2` is `WmsConstants.BusinessObjectLockState.GOING_TO_DELETE` ("To Delete", `WmsConstants.java:1259`).

**Conclusion:** `UL314581` was retired to Nirvana 2.5 months before the scan. The physical label the operator scanned is dead. That part is data, not a bug — **the bug is that the system cannot say so.**

### 1.4 Reproduction

1. Mobile → Move Stock → scan a source container holding stock (e.g. `UL319408`).
2. Enter an amount, choose **Existing Container**.
3. On "Scan Destination Container", scan any label that has no `unitload` row — a Nirvana'd label such as `UL314581`, or simply a typo.
4. Submit. Observe the generic network toast; observe `404` in the browser Network panel.

Reproduces identically on the **desktop** Handling Units → Transfer Stock popup **only if** the client-side `checkContainer` probe is bypassed (see §0.2 row 19) — the web UI pre-validates and mobile does not.

---

## 2. Root Cause Analysis

### Bug 1 — an operator-scanned identifier is reported as a resource-lookup failure, not a domain error

`StockunitService.java:154-156`:

```java
if (isTransferToExistingContainer) {
    LOG.debug("transfer to existing container");
    unitLoad = unitloadRepository.findByLabelid(unitLoadLabelId)
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad not found by labelid: " + unitLoadLabelId));
```

`findByLabelid` is an exact-match derived query (`UnitloadRepository.java:64-65`) — a mangled `UL314581-X-21552195` cannot match `UL314581`. `EntityNotFoundException` extends `RuntimeException` (`EntityNotFoundException.java:7`), so it is **not** one of the two checked exceptions the caller catches:

`StockUnitController.java:94-102`:

```java
try {
    stockunitService.transferStock(stockUnit, amountToTransfer, isTransferExistingContainer,
                                   locationName, unitLoadLabelId, comment, printLabel);
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
} catch (FacadeException e) {
    errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage()));
}
```

It escapes to `RestExceptionHandler.java:153-159`, which maps it to **HTTP 404 + RFC 9457 `ProblemDetail`**.

`wms2-mobile-ui plugins/axios.js:167-173` rejects the promise (`axios-retry` only retries 401/403, `plugins/axios.js:35-51`), so `store/moveStock.js:179-182` runs:

```js
} catch (error) {
    console.log(error);
    this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
}
```

The `results.errors` branch at `:171-173`, which *would* have displayed a real message, is never reached because the promise rejected instead of resolving.

**No data corruption.** The throw is the first statement in the `isTransferToExistingContainer` branch, and `transferStock` is `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` (`StockunitService.java:149`). `EntityNotFoundException` is unchecked, so the default rollback rule applies and nothing was written before the throw anyway. Verified: `stockunit` `30676366` still shows `amount=4.0000, reservedamount=0.0000, entity_lock=0`.

### Bug 2 — the endpoint has no fallback for *any* unchecked lookup failure, while its sibling does

`bulkTransferStock`, 50 lines below in the same file, calls the same service method and **does** guard the case (`StockUnitController.java:163-167`):

```java
} catch (NumberFormatException e) {
    errors.add(getErrorMessage("Invalid ID Format", e.getMessage()));
} catch (EntityNotFoundException e) {
    errors.add(getErrorMessage("Entity Not Found", e.getMessage()));
}
```

So the *bulk* desktop path degrades to a displayable 200, and the *single* path — the one both UIs use most — 404s. The single-transfer endpoint is the outlier, not the bulk one. Any of the 11 internal lookups in §0.1 rows 3-13 produces the same unactionable toast today.

### Bug 3 — "exists" is not the same as "usable", and the only existing probe checks only existence

`StockUnitController.java:557-564`:

```java
@GetMapping(path = "/isUnitLoadIdValid/{labelId}", produces = "application/json")
public Boolean getStorageLocationsForStockMovement(@PathVariable("labelId") String labelId, ...) {
    Optional<Unitload> unitLoad = unitloadRepository.findByLabelid(labelId);
    if (unitLoad.isPresent())
        return true;
    else
        return false;
}
```

For *this* incident the probe would have answered correctly (`UL314581` genuinely has no row). But a unit load that **exists under an unmangled label** while sitting in Nirvana, in Shipped, or under a `GOING_TO_DELETE` / `ON_HOLD` lock passes this probe and then fails — or worse, silently succeeds — deeper in `transferStockToUnitLoad`. The Move Unit Load flow already refuses those destinations explicitly (`MobileMoveUnitloadService.java:288-296` for Nirvana/Shipped, `:261-267` for on-hold); `transferStock` has no equivalent.

Note that a Nirvana'd unit load is **recoverable** — `UnitloadBusinessService.java:532-538` and `:738-740` strip the exact trailing `-X-<id>` mangle to restore the original label. A mangled label is therefore "currently unusable", not "permanently dead", and the message must not claim otherwise.

### Bug 4 — mobile has no client-side destination validation; desktop does

`wms2-web-ui components/handlingUnits/popups/transferStock.vue:140-146`:

```js
if (this.mode === 'existing' && this.container) {
  this.$store.commit('handlingUnits/stockUnits/setValidContainer', false)
  await this.$store.dispatch('handlingUnits/stockUnits/checkContainer', {labelId: this.container})
  if (!this.validContainer) {
    this.$toast.error('Container does not exist')
    valid = false
  }
}
```

`wms2-mobile-ui components/moveStock/scanDestination.vue:145-153` has no counterpart — it validates only that the field is non-empty. This is the parity gap that makes the defect visible on handhelds first.

---

## 3. The (non-)regression chain

`git log --oneline -S"EntityNotFoundException" -- src/main/java/net/aim_ai/wms/service/StockunitService.java`

| Commit | Subject | Effect on this bug |
|---|---|---|
| `08010ba6` | `replace unsafe Optional.get() with orElseThrow(EntityNotFoundException)` | Converted `:156` from a bare `.get()` to `.orElseThrow(EntityNotFoundException)` |
| `5b1b17f7` | `fix: Phase 5 — replace unsafe Optional.get() with orElseThrow for null safety` | Same sweep, later phase |
| `bd8f07d` | `Fixed v2 Handling Units: Stock Units transfer to damaged the stock that is in 'To Delete' state shows set lock error.` | Prior fix in this exact area for `GOING_TO_DELETE` stock — precedent that To-Delete state needs explicit handling here |

**This is not a regression.** Before the null-safety sweep, `:156` threw a bare `NoSuchElementException`, which `RestExceptionHandler.java:145-150` maps to **500** — also a rejected promise, also the same generic toast. The sweep improved the server log and the status code without changing what the operator sees. State this in review so the sweep is not blamed: the UX gap predates it and was mechanically preserved.

---

## 4. Architecture Overview

```
 Mobile handheld                          wms2-api                                 Postgres (tenant)
 ───────────────                          ────────                                 ─────────────────
 moveStock/scanDestination.vue
   submit()  :174-184
      │ POST /v3/stockUnit/transferStock
      │ {id, amountToTransfer, printLabel:false,
      │  locationName:'Clearing', labelId:'UL314581',
      │  isTransferExistingContainer:true, comment}
      ▼
 store/moveStock.js
   transferStock()  :167
      │ $axios.$post
      ▼
 plugins/axios.js  :167  onError ──────►  StockUnitController.transferStock  :63
                                             │ findById(stockUnit)          :89
                                             │ try {                        :94
                                             ▼
                                          StockunitService.transferStock    :150
                                             │ @Transactional(tenantTransactionManager)
                                             │ isTransferToExistingContainer == true
                                             ▼
                                          unitloadRepository.findByLabelid  :156 ──► SELECT … WHERE labelid='UL314581'
                                             │                                        └─► 0 rows
                                             │                                            (row is 'UL314581-X-21552195')
                                             ▼
                                          EntityNotFoundException (unchecked)
                                             │ ✗ escapes catch(BusinessException|FacadeException)
                                             ▼
                                          RestExceptionHandler  :153-159  ──► 404 ProblemDetail
      ┌──────────────────────────────────────┘
      ▼
 catch(error) :179 ──► $toast.error('… network or server issue …')     ← WRONG MESSAGE
      ✗ never reaches the `results.errors` branch at :171
```

### Key files

| File | Lines | Role |
|---|---|---|
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockunitService.java` | 149-270 | `transferStock` — both branches; 13 `EntityNotFoundException` sites |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/StockUnitController.java` | 63-112 | single-transfer endpoint (no `EntityNotFoundException` catch) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/StockUnitController.java` | 115-176 | bulk endpoint (has the catch — the parity reference) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/StockUnitController.java` | 557-564 | `isUnitLoadIdValid` existence probe |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` | 145-159 | `NoSuchElementException`→500, `EntityNotFoundException`→404 |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/BusinessException.java` | 42-63, 145-147 | 1-arg ctor sets `key="placeholder"`; keyed ctor + `getKey()` |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java` | 126-130, 261-267, 288-296 | the correct-behaviour reference for label miss + unusable destination |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java` | 397, 532-538, 738-740 | `sendToNirvana` label mangle and its reversal |
| `v2/wms2-api/src/main/resources/messages.properties` | — | base bundle (locale-safe home for new keys) |
| `v2/wms2-api/src/main/resources/messages_en_US.properties` | — | en_US bundle |
| `v2/wms2-mobile-ui/components/moveStock/scanDestination.vue` | 141-185 | submit + validation (no container check) |
| `v2/wms2-mobile-ui/store/moveStock.js` | 167-183 | dispatch + toasts |
| `v2/wms2-web-ui/components/handlingUnits/popups/transferStock.vue` | 133-155 | desktop pre-validation (parity reference) |

---

## 5. Fix Design

### Fix A — operator-supplied identifiers raise `BusinessException` (server, primary)

**Problem:** §0.1 rows 1-2. The two identifiers a client actually supplies are reported as unchecked lookup failures, so the endpoint's own error contract cannot carry them.

**Solution:** keyed `BusinessException`s, which the existing `catch` at `StockUnitController.java:96` already turns into `200 {errors:[{field,message}]}` — the shape both UIs already render.

⚠ **CORRECTED — the key is `field`, not `type`.** `AdminController.getErrorMessage` (`controller/AdminController.java:264-269`) does `error.put("field", field); error.put("message", message);`. The existing suite already relies on it (`StockUnitControllerUnitTest:214, :285`) and `wms-exception-taxonomy.md:76` documents it. §8.2's original acceptance criterion named `errors[0].type`, which **does not exist** — a TDD gate would have written a test against a fabricated contract that fails even against a correct implementation.

`StockunitService.java:154-156` — before:

```java
if (isTransferToExistingContainer) {
    LOG.debug("transfer to existing container");
    unitLoad = unitloadRepository.findByLabelid(unitLoadLabelId)
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad not found by labelid: " + unitLoadLabelId));
```

after:

```java
if (isTransferToExistingContainer) {
    LOG.debug("transfer to existing container");
    // SBDEV-2994: unitLoadLabelId is scanned by the operator, so a miss is a domain error they can
    // act on (rescan / pick a live container), not a referential-integrity fault. Raising
    // EntityNotFoundException here escapes the controller's checked-exception catch and 404s, which
    // both UIs render as the blanket "network or server issue" toast. Mirrors
    // MobileMoveUnitloadService:126-130, which has always got this right on the Move Unit Load screen.
    unitLoad = unitloadRepository.findByLabelid(unitLoadLabelId)
        .orElseThrow(() -> new BusinessException(
                WmsConstants.MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND, unitLoadLabelId));
```

`StockunitService.java:178` — before:

```java
Location destinationLocation = locationRepository.findByName(locationName)
    .orElseThrow(() -> new EntityNotFoundException("Location not found by name: " + locationName));
```

after:

```java
// SBDEV-2994: locationName is client-supplied on every caller (mobile hardcodes 'Clearing', the web
// popup sends the operator's dropdown pick, CancellationReversalService:203 replays a logged
// pickfromlocationname that can be renamed or deleted between pick and reversal). Same reasoning as
// the destination label above.
Location destinationLocation = locationRepository.findByName(locationName)
    .orElseThrow(() -> new BusinessException(
            WmsConstants.MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND, locationName));
```

⚠ **CORRECTED — the original text here was false.** It claimed "`orElseThrow` cannot throw a checked exception from a lambda". `Optional.orElseThrow(Supplier<? extends X>) throws X` is generic over `X extends Throwable`; the lambda only *constructs* the exception, so `X` infers to `BusinessException` and the enclosing `transferStock` — which declares `throws BusinessException` at `:150` — compiles. There are **34** working counter-examples in this repo (`ReceivingService.java:362`, `PutawayDestinationValidator.java:120`, `CancellationReversalService.java:186`). Use the concise `.orElseThrow(() -> new BusinessException(...))` form at **both** sites; the verbose `Optional` + `isEmpty()` shape is unnecessary.

New constants on `WmsConstants` (alongside the existing message-key constants), and new rows in **both** bundles:

`src/main/resources/messages.properties` **and** `src/main/resources/messages_en_US.properties`:

```properties
transferStockDestinationUnitloadNotFound=Container %1$s was not found. It may have been emptied or removed — scan a container that is currently in use.
transferStockDestinationLocationNotFound=Location %1$s was not found.
transferStockDestinationNotUsable=Container %1$s is %2$s and cannot receive stock.
```

**Both** bundles, not just `en_US`: `BusinessException.resolveMessage` resolves against `ResourceBundle.getBundle("messages", Locale.getDefault())` at construction time (`BusinessException.java:79`), and nothing pins the JVM locale in the Dockerfile or `application.properties`. A key present only in `messages_en_US.properties` degrades to the concatenated `key, 'param'` fallback (`:109-122`) on any other default locale — documented in `wms-exception-taxonomy.md` §"Message keys".

**Use the keyed constructor, not the 1-arg one.** `BusinessException(String message)` silently sets `key = "placeholder"` (`BusinessException.java:42-47`), so every 1-arg exception in the codebase shares one key and `getKey()` cannot discriminate them. The sibling `MobileMoveUnitloadService:130` uses the 1-arg form; we deliberately diverge so §8's tests can assert `getKey()` rather than rendered copy — copy that will change the first time someone rewords it (`BusinessException.java:133-144` records exactly this trap from SBDEV-2732/2731).

**Why not the alternative** — "catch `EntityNotFoundException` at the controller and be done" (i.e. Fix C alone)? Because it flattens a scan mistake and a corrupt foreign key into one indistinguishable error string, and it leaves `CancellationReversalService` (a non-HTTP caller) with no way to tell them apart either. Fix C is still worth doing, as a net, but it is not a substitute for typing the error correctly at the throw site.

### Fix B — refuse a destination that exists but cannot receive stock (server)

⚠ **RESHAPED after review.** The first draft's shape was: refuse `GOING_TO_DELETE` / `ON_HOLD` /
Nirvana / Shipped, via a private helper on `StockunitService`. Measurement killed two of those four
branches and the layering was wrong. What follows is the corrected design.

**What the guard actually refuses — measured, not assumed** (`wms2-wineco-dev`, `count(DISTINCT u.id)`):

| Destination state | Unit loads | Reachable by label scan? | Verdict |
|---|---|---|---|
| Location `Shipped`, `entity_lock=405 (SHIPPED)` | **411,862** (395,984 carry stock) | **yes — unmangled labels** | **the entire real exposure** |
| Location `Nirwana`, `entity_lock=2` | 320,637 | **no — 320,642/320,642 are `-X-` mangled** | Fix A's label miss always fires first |
| Location `Nirwana`, `entity_lock=0` | **1** (the `Nirwana` sentinel) | **yes** | → **SBDEV-2995**, its own ticket |
| `entity_lock=104 (ON_HOLD)`, anywhere | **0** | n/a | **branch dropped** |

Three consequences the first draft got wrong:

1. **The `GOING_TO_DELETE` branch can essentially never execute.** Every To-Delete unit load on the
   tenant is label-mangled, so `findByLabelid` misses and Fix A rejects first. Keep the check for
   completeness, but say plainly that Fix A subsumes it — the draft presented it as the fix.
2. **The `ON_HOLD` branch is dropped.** Zero rows tenant-wide (P5: a check that cannot fail), and its
   claimed precedent does not exist — `MobileMoveUnitloadService:260-262` guards the **source**
   unit load's lock, not the destination's. There is no destination on-hold guard anywhere in that
   class. Re-propose it on its own merits if ops wants it.
3. **`SHIPPED` (405) was not in the draft's lock list at all**, yet it is the state 100% of the real
   population carries. The draft caught those unit loads only incidentally, via the location name.

**⚠ SYSPROP GATE — resolved 2026-08-18 (§12 Q6), and the split matters.**

R3 is uncleared, so the *behaviour-changing* half of Fix B ships gated:

| Half of Fix B | Gated? | Why |
|---|---|---|
| Refuse **Shipped** / **To-Delete** destinations | **YES — `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED`, default `false`** | 411,862 unit loads on one tenant become unusable destinations the moment this flips. R3 could not measure whether anyone relies on that today, and with no gate the only rollback is a hotfix across all tenants (R10) |
| Refuse the **Nirvana sentinel** | **NO — unconditional** | This is the **SBDEV-2995 silent-data-loss path**. It must not sit behind a flag someone has to remember to flip |

The Architect flagged the trap this closes: SBDEV-2995 was split out, yet Fix B's Nirvana branch is
still the only thing in the estate that fixes it — so gating all of Fix B would leave the
highest-severity finding of the whole review fixed *incidentally, by a change shipped disabled*.
Splitting the gate is what keeps the split honest.

Implementation: `WmsConstants.SYSTEM_PROPERTY_TRANSFER_DESTINATION_ELIGIBILITY_ENABLED_KEY =
"TRANSFER_DESTINATION_ELIGIBILITY_ENABLED"`, read via
`syspropService.getSysvalue(...)` inside `DestinationEligibilityService`, guarding **only** the
lock/Shipped clauses. Seed the row `false` for every tenant in step 4a. Absent row ⇒ treated as
`false` (fail-safe: an un-seeded tenant behaves as today).

**⚠ SHADOW MODE — designed here, because it was previously named as a mitigation and never built.**
The gate must not simply skip the check when off; it must **evaluate and log without refusing**:

⚠ **CORRECTED 2026-08-19 during implementation — `syspropService.getBoolean(...)` DOES NOT EXIST.**
`SyspropService` exposes `getSysvalue`, `getString`, `getStringDefault` and `getIntValue`; there is no
boolean accessor. The house pattern for a default-OFF gate is
`Boolean.parseBoolean(syspropService.getSysvalue(KEY))`, documented at `WmsConstants.java:930` against the
SBDEV-2658 precedent (seeded by `V2.2.11`), and it delivers the absent-row ⇒ OFF fail-safe this section
requires for free — `parseBoolean(null)` is `false`. The 1-arg `getSysvalue` is also the **only** safe
overload here: `getStringDefault(client, workstation, key, default)` calls `createSystemProperty(...)` on a
miss, i.e. an INSERT, and `canReceiveStock` runs inside `readOnly = true`. ⚠ Do **not** copy the
default-ON idiom at `WmsConstants:1115` (`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`) — that one forbids
`parseBoolean` precisely because a missing row must not disable its fix; this gate wants the opposite.

```java
boolean enforcing = Boolean.parseBoolean(
        syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_TRANSFER_DESTINATION_ELIGIBILITY_ENABLED_KEY));
if (violatesEligibility(destination)) {
    if (enforcing) {
        throw new BusinessException(WmsConstants.MSG_TRANSFER_DESTINATION_NOT_USABLE, ...);
    }
    // SBDEV-2994 shadow mode: the gate is OFF, so ALLOW the move — but record that it WOULD have
    // been refused. This log line is the only instrument that can retire R3 per tenant.
    LOG.warn("SBDEV-2994 shadow: would have refused destination unitLoad={} lock={} location={}",
             destination.getLabelid(), destination.getEntityLock(), locationName);
}
```

**Why this is load-bearing rather than a nicety.** R3 could not be cleared because the query cannot
see the population it needs to count. A gate that merely *skips* leaves that permanently true: Fix B
ships inert, the 411,862-unit-load exposure stays unmeasured forever, and **the evidence needed to
flip the gate can never be gathered by the system this plan builds.** Log-and-allow makes R3
*self-clearing per tenant* — run for one full operating cycle, count the shadow lines, and enable
where the count is zero. Roughly ten lines, and it converts the largest open risk from "someone must
find a way to measure this" into "wait and read the log".

**N7 reconciled — R3 and the gate are not alternatives.** An earlier revision left §11 saying nothing
may be implemented until a human runs a production query, while §5/§12 treated the gate as the
resolution. Both cannot be operative. The settled position: **the gate (with shadow mode) unblocks
IMPLEMENTATION; R3 blocks ENABLEMENT.** Fix B may be written, merged and deployed with the sysprop
`false` — the shadow log is what then produces R3's evidence. No tenant is switched to enforcing
until its shadow count is zero over a full cycle. §11 R3 is re-scoped accordingly.

Consequences propagated: §7.1's Feature-flags and System-properties rows flip from N/A to Yes;
§7.2 gains step 4a (constant + sysprop seed); §8.1's Shipped/To-Delete tests set the gate ON and a
new test asserts they pass through when it is OFF; **§8.6 M10 (Nirvana) stays valid unconditionally**;
verify gains `B12`.

**`%2$s` is the reason token, and every branch must supply one** (previously undefined for the
Nirvana branch — the one *ungated* branch, so the gap was on the path that always runs):

| Branch | `%2$s` |
|---|---|
| lock is not `NOT_LOCKED` | `BusinessObjectLockState.getCodeText(lock)` — e.g. `"To Delete"`, `"Shipped"` (verified to cover all 8 states) |
| destination is the **Nirvana sentinel** | the literal `"retired"` |
| destination sits at **Shipped** | the literal `"already shipped"` |

⚠ Use the **keyed** constructor with both arguments. `BusinessException(String)` is a more specific
overload than `BusinessException(String, Object...)` for a single-String call, so an implementer who
omits the second argument silently gets `key="placeholder"` and every `getKey()` assertion fails at
runtime rather than at compile time (R13 / PM-5).

**Denylist → allowlist.** `WmsConstants.BusinessObjectLockState` has **eight** members
(`WmsConstants.java:1258-1265`). A two-member denylist lets `SHIPPED`, `TRANSFER`, `NOT_FOUND` and
`PICKED_FOR_GOODSOUT` through at a non-Shipped location, and silently drifts on the next enum
addition. Invert it: a destination may receive stock only when its lock is **`NOT_LOCKED`**.

⚠ **`QUALITY_FAULT` was in the allowlist and is now removed.** It was admitted on the grounds that
"the existing damaged branch at `:230-251` already handles it deliberately" — but that branch is
entirely inside the **new-container** path, which never co-occurs with the existing-container branch
this guard runs in, and it tests the **source stockunit's** lock, not the destination unit load's.
Different entity, different branch. Measured on `wms2-wineco-dev`: **zero `unitload` rows carry any
lock outside {0, 2, 405}**, so it was a population of nothing admitted on a justification that did not
describe the cited code — the same precedent-mis-citation the reshape existed to correct.

**Extract one collaborator; do not add a fourth copy.** Counting after this fix, the estate would hold
four hand-rolled spellings of "can this destination receive stock" — `MobileMoveUnitloadService:288-296`
(guards a scanned destination **Location**), `MobileMoveUnitloadService:122` (the Nirvana unit load),
`MobileMoveStockService:320-324` (the destination **unit load** — the genuinely matching precedent, and
the one the draft never cited), and this one. Three of them disagree about which entity they apply to.

Introduce **`DestinationEligibilityService`** with two methods over the same rule:

```java
/** Throws for a destination that cannot receive stock. Used on write paths. */
public void assertCanReceiveStock(Unitload destination) throws BusinessException { ... }

/** TOTAL: never throws. Unresolvable location or null FK => false. Used by read-only probes. */
@Transactional(value = "tenantTransactionManager", readOnly = true)
public boolean canReceiveStock(Unitload destination) { ... }
```

`StockunitService.transferStock` calls `assertCanReceiveStock` immediately after the destination
resolves in the existing-container branch. `MobileMoveStockService` and `MobileMoveUnitloadService`
migrate onto it as follow-ups (not in this ticket — recorded so the next author does not add a fifth).

**`canReceiveStock` MUST be total.** This is the defect that nearly re-created the reported bug on the
desktop. The draft's helper did
`locationRepository.findById(destination.getStoragelocationId()).orElseThrow(EntityNotFoundException)`,
inside a method the controller would call from `isUnitLoadIdValid` — an endpoint with **no `try`**
whose whole declared contract is `Boolean`. `Unitload.storagelocationId` is a plain `Long` with no
FK-backed guarantee, and `findById(null)` throws `InvalidDataAccessApiUsageException`. So a dangling
or null location turns a `true`/`false` probe into a **404**, which
`wms2-web-ui store/handlingUnits/stockUnits.js:209-219` catches into
*"Error: Request failed due to a network or server issue. Please retry."* — **the exact toast this
ticket exists to delete, on the desktop, on a healthy container.** Contract, stated so a test can pin
it: **null or unresolvable `storagelocation_id` ⇒ `false`** (fail closed on a probe; the write path
still gets the typed error from `assertCanReceiveStock`).

**Visibility.** `canReceiveStock` is **public** — a method reference `stockunitService::canReceiveStock`
from a controller cannot bind a private method. §10 row 3's "private helper, not a service entry point"
was wrong and is corrected there.

**Probe fold + toast (§12 Q1).** `isUnitLoadIdValid` keeps its bare `Boolean` response shape, so
`stockUnits.js:212` is unaffected:

```java
return unitloadRepository.findByLabelid(labelId).filter(destinationEligibilityService::canReceiveStock).isPresent();
```

and `wms2-web-ui .../popups/transferStock.vue:144` changes to **"Container is not available to receive
stock"** — true for both the missing and the unusable case.

⚠ **Known, accepted regression at the shipped default (N20).** The toast reword is *ungated* while
Fix B's enforcement is gated OFF, so on delivery the desktop says "not available to receive stock"
about a container that simply **does not exist** — strictly less precise than today's wording, for no
gain until a tenant is switched to enforcing. Accepted rather than fixed: splitting the copy by cause
would need the probe to return a reason instead of a `Boolean`, which is a contract change this
ticket does not want. Revisit if enforcement stays off for more than one release.
⚠ Note also that the deploy-order argument below is about the *enabled* state; with the gate off the
probe rejects nothing extra, so API-first manufactures no untruth at the default. Web-first remains
correct for the eventual enable, and costs nothing now. ⚠ See §7.1: this pair **must deploy
web-first**, or the desktop tells 411,862 truthful containers that they "do not exist".
### Fix C — controller-level net for the remaining unchecked lookups (server)

**Problem:** Bug 2. §0.1 rows 3-13 remain 404s.

**Solution:** give `transferStock` the catch its own sibling already has. `StockUnitController.java:94-102` — add, after the existing two:

```java
} catch (EntityNotFoundException e) {
    // SBDEV-2994: these are internal referential failures, not operator mistakes. They keep their own
    // type at the throw site (§5.4) and are logged with the full exception — but the operator gets a
    // message instead of a 404 the UI renders as "network or server issue".
    //
    // The response body carries a FIXED, operator-safe string plus the stock-unit id as a support
    // reference. It must NEVER carry e.getMessage(): EntityNotFoundException's constructors
    // (EntityNotFoundException.java:9-19) build strings like "Location not found with id: 3421" and
    // "UnitLoadType not found by name: Pallet", and store/moveStock.js:173 renders errors[0].message
    // verbatim on a handheld. Routing raw entity names and primary keys to an operator would
    // contradict §0.1's own classification of these rows as "the operator can do nothing".
    LOG.error("transferStock internal lookup failed for stockUnit={}", id, e);
    errors.add(getErrorMessage("Runtime Error",
            "This move could not be completed. Please report reference " + id + " to support."));
}
```

⚠ **The first draft returned `e.getMessage()` here.** Review flagged it as the load-bearing objection (§14.1 C2): the plan classifies rows 3-13 as engineer-only and then puts their raw text on an operator's screen, contradicting P1/P4 and §5 Fix A's own argument against Fix-C-alone ("it flattens a scan mistake and a corrupt foreign key into one indistinguishable error string").

**The observability fix belongs one layer up, and is one line.** `RestExceptionHandler.java:155` currently logs `EntityNotFoundException` at **`LOG.debug`** — invisible in every environment. So Fix C's logging is a strict *improvement*, not a downgrade, and R1 overstated the risk. But Fix C's `LOG.error` covers one endpoint; changing `RestExceptionHandler:155` `debug` → `warn` covers **all 61 controllers** for a fraction of the blast radius. **Both are in scope.** With the handler fix landed, §10 row 8's decision to decline a Micrometer counter is defensible; without it, "we have monitoring" is false comfort.

**A 14th site Fix C does NOT net.** `StockunitService:169`'s `defaultUnitLoadType.get()` throws `NoSuchElementException`, which `RestExceptionHandler:145-150` maps to **500** — not caught here. It is inside the reported existing-container pallet branch. **Decision: guard it** — replace the `.get()` with an `orElseThrow(() -> new EntityNotFoundException("UnitLoadType", ...))` so Fix C's net does cover it. Recorded rather than left silent.

**Scope note:** this catch does **not** cover `stockunitRepository.findById(id)` at `StockUnitController.java:89`, which sits *before* the `try`. Leave it a 404 — and the reason is stronger than the first draft's ("a bad `id` is a client-programming error"): `id` is a **surrogate key**, so it lands squarely in the `EntityNotFoundException` branch of §5.4's discriminator. It is consistent with the rule, not an exception carved out of it. (Note `bulkTransferStock` disagrees — its equivalent lookup at `:147` is *inside* the outer `try`, so a bad id there yields a 200. A second way the two endpoints already diverge.)

### Fix D — mobile pre-validates the destination container (mobile UI, parity)

**Problem:** Bug 4 — the desktop pre-validates, mobile does not.

**Solution:** mirror `wms2-web-ui .../popups/transferStock.vue:140-146` in
`wms2-mobile-ui components/moveStock/scanDestination.vue`: after the `$refs.scan.validate()` gate at
`:148-151`, dispatch a `checkContainer` action hitting `GET /stockUnit/isUnitLoadIdValid/{labelId}` and,
on `false`, toast and return.

⚠ **The draft's stated ordering rationale was fictitious and is deleted.** It claimed validating before
the damaged-reason pause "means an operator is never asked to type a reason for a move that is about to
be rejected." That state is unreachable: `isDamagedDestination` requires `currentMode === 'new'`
(`scanDestination.vue:118-122`), and `existing` is the only mode with a destination container to
validate. Two **real** constraints replace it:

- **`submit()` at `:141` is synchronous and must become `async`.** Two existing Jest specs mount and
  drive it — `test/components/move-damaged-reason-payload.spec.js` (`:359-365` asserts
  `toHaveBeenCalledTimes(1)` on a synchronous call) and `test/pages/workflow-reset-on-entry.spec.js`.
  Both are in §0.3 rows 31-32 and both must be updated.
- **Scope the probe to `existing` mode.** In `new` mode `labelId = this.currentStock.unitLoad.labelid`
  (`:160`) — the **source** unit load. An unscoped `checkContainer(labelId)` would probe the source and
  could block a legitimate move.

**Toast copy, specified so the gate can assert it** (the draft said only "a specific message"):
**`Container ${label} is not available to receive stock`**. `checkContainer` returns a boolean; if the
probe request itself fails, **fail open** — let the submit proceed and let the server decide, rather
than copying `stockUnits.js:215-218`'s bug where a failed probe leaves `validContainer` at `false` and
the operator gets two wrong toasts.

**This is defence in depth, not the fix.** With A + C the mobile UI already shows the real message with
zero UI changes, because the server answers `200 {errors:[…]}` and `store/moveStock.js:171-173` already
renders `results.errors[0].message`.

### Fix E / Option 4 — priced, and rejected for this ticket

⚠ **The draft never priced this and review flagged the omission as a strawman** (§14.1 C9). It described
the alternative as "~18 store modules… a cross-cutting change with its own regression surface across
every workflow page" — a description of fixing *all* of them at the axios layer. Nobody proposed that.

**The actual alternative is one function, ~4 lines**, in `wms2-mobile-ui store/moveStock.js:179-182`.
The server **already sends the string**: `RestExceptionHandler.java:156` builds the 404 as
`ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.getMessage())`, so
`error.response.data.detail` is `"UnitLoad not found by labelid: UL314581"` **today, on origin/develop**.
And the helper already exists in the same repo — `store/cancellation.js:44-48`:

```js
function backendMsg(error, fallback) {
  return (error?.response?.data?.errors?.[0]) ? error.response.data.errors[0].message : fallback
}
```

| | Option 4 | This plan (A+B+C+D) |
|---|---|---|
| Files changed | 1 | ~10 across 3 repos |
| Server risk | none | type change on a shared `@Transactional` write path |
| Observable in a runnable lane | **yes** (mobile Jest) | no (D1) |
| Names the scanned container | yes | yes |
| Message voice | **internal** (`"UnitLoad not found by labelid: …"`) | operator |
| Fixes the desktop bulk path | no | yes |
| Gives `CancellationReversalService` a distinguishable error | no | yes |

**Why it is rejected as the resolution, honestly stated:** it displays internal developer text — but so
did the draft's Fix C, so that was not a fair discriminator until Fix C was reworked above. The real
reasons are the last two rows: Option 4 fixes one screen in one client, leaves the desktop and bulk
paths untouched, and leaves the non-HTTP caller unable to tell a bad label from a corrupt FK.

**It remains the right hotfix** if this ticket is ever blocking a warehouse: one file, same day, no API
deploy. Recorded so a reviewer can take it rather than rediscover it.

The genuinely cross-cutting version — teaching the axios layer to surface `ProblemDetail.detail` on any
4xx — stays out of scope. ⚠ Corrected census: **12 of 13** mobile store modules and **30+** web store
modules carry the blanket toast, so the real total is 42+, not the "~18" the draft claimed. That cuts
*in favour* of deferring it. Tracked in §12 Q3.
### 5.4 Why the split, against the documented taxonomy

`wms-exception-taxonomy.md` §"Choosing an exception" is ambiguous here — two of its branches both match:

```
Is the error a domain/business rule violation … that a human operator can understand and act on?
  └─ Yes → BusinessException(key, params...)
…
Is the error that a DB entity simply does not exist?
  └─ v2 → EntityNotFoundException(entityName, id) — results in 404 + ProblemDetail (preferred)
```

An operator-scanned label that resolves to nothing satisfies **both**. The tree is ordered, so the business-rule branch wins on a strict reading — but the wording of the later branch ("simply does not exist") reads like a catch-all and has clearly been applied that way in the Phase-5 sweep.

⚠ **The first draft's discriminator — "whose input produced the miss" — was rejected in review, on three counts (§14.1).**

1. **It is not stable.** Site `:178` has three callers that give three different answers: the web dropdown (operator-chosen), mobile's hardcoded `'Clearing'` (a *constant in the client*), and `CancellationReversalService:203` replaying a **logged** `pickfromlocationname` with no human in the loop. Taking the union reduces the rule to "if *any* caller might be interactive", which ratchets one way — every shared site eventually becomes `BusinessException` and the split dissolves.
2. **It is not enforceable.** It is a property of the *call graph*, invisible at the throw site. Nothing at `:178` tells a future author where `locationName` came from, and a new system caller silently inherits an operator-framed message and a 422.
3. **It is empirically false as stated.** The draft claimed "this is already how `MobileMoveUnitloadService` behaves." In that same class, `:126-130` throws `BusinessException` for a scanned label miss — but `:254`, **the same scanned label** in `scanDestination`, throws `EntityNotFoundException`. `MobileMoveStockService:143` does likewise. The precedent is 50/50 and the draft cited only the supporting half.

**The adopted discriminator — a property of the SIGNATURE, decidable at the throw site:**

> **A miss on a value that arrived as a parameter of the enclosing public method → `BusinessException`.
> A miss on a value derived inside the method — a field of an already-loaded entity, a `WmsConstants`
> literal, a sysprop key → `EntityNotFoundException`.**

Tested against all 14 rows of §0.1: rows 1 (`unitLoadLabelId`) and 2 (`locationName`) are method parameters → `BusinessException`. Rows 3-13 are all derived (`stockUnit.getUnitloadId()`, `pallet.getStoragelocationId()`, `UNIT_LOAD_TYPE_PALLET`, `WAREHOUSE_NAME`) → `EntityNotFoundException`. **Identical verdicts to the original rule on every row**, but now it is local, survives caller changes, is mechanically greppable (is the argument a `WmsConstants.` literal or a method parameter?), and it answers `:178` without argument — a parameter is a parameter regardless of who fills it. It also correctly labels `MobileMoveUnitloadService:254` and `MobileMoveStockService:143` as **wrong today** rather than as precedent to be explained away.

Two supporting arguments the first draft missed, both stronger than the one it made:

- **The taxonomy's v2 branch presupposes a surrogate key.** It reads `EntityNotFoundException(entityName, id)` — the `(String, Long)` overload (`EntityNotFoundException.java:13-15`). Both contested sites use `findByLabelid`/`findByName` and the **hand-written-sentence** overload (`:9-11`). The doc never covered natural-key lookups at all. That is the real ambiguity.
- **v1's branch of the same tree already resolves it this way:** `BusinessException("BusinessException.ObjectNotFound", entityName)` → 422. Fix A is **restoring** the v1 convention for these two sites, not inventing one.

**Message-key naming (P3, raised in review).** The repo already has generic `entityNotFoundForId` / `entityNotFoundForName` keys (`messages_en_US.properties:314-315`, 34 uses across `ReceivingService`, `PutawayDestinationResolver`, `PutawayDestinationValidator`, `SkuPutawayQueryService`). We deliberately do **not** reuse them: they render as `"No entity Unitload found for name='UL314581'!"` — engineer-speak, and the whole point of this ticket is operator-voice. But the divergence must be argued, not skipped. Key style follows the **bare-camelCase** SBDEV-2732 cohort (`putawayDestinationNotPermitted`, `noValidString`), which is the most recent and largest convention — so the keys are `transferStockDestinationUnitloadNotFound`, `transferStockDestinationLocationNotFound`, `transferStockDestinationNotUsable`.

Doc update is included as step 9 in §7.

---

## 6. File Change Summary

| File | Change | Description |
|---|---|---|
| `v2/wms2-api/.../service/StockunitService.java` | modify | Fix A (2 sites); Fix A4 (guard the `.get()` at `:169`); **calls** `destinationEligibilityService.assertCanReceiveStock(...)` |
| `v2/wms2-api/.../service/DestinationEligibilityService.java` | **new** | ⚠ **Was missing from this table.** The shared collaborator: throwing `assertCanReceiveStock` + TOTAL non-throwing `canReceiveStock` (§5 Fix B). Verify rows `B1`-`B9` require this exact path |
| `v2/wms2-api/.../exceptions/RestExceptionHandler.java` | modify | `:155` `LOG.debug` → `LOG.warn` — the estate-wide half of Fix C (§5 Fix C, verify `C4`) |
| `v2/wms2-api/src/test/.../unit/service/DestinationEligibilityServiceUnitTest.java` | **new** | ⚠ **Was missing.** Totality contract incl. the null / unresolvable-location cases (verify `T2`, `B8b`, `M2`) |
| `v2/wms2-api/.../service/WmsConstants.java` | modify | 3 message-key constants — `MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND`, `MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND`, **`MSG_TRANSFER_DESTINATION_NOT_USABLE`** (the third was previously named only in the verify script, N21) — plus `SYSTEM_PROPERTY_TRANSFER_DESTINATION_ELIGIBILITY_ENABLED_KEY` |
| `v2/wms2-api/src/main/resources/db/migration/V2.2.xx__seed_transfer_destination_eligibility.sql` | **new** | ⚠ **Was missing.** Seeds `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED=false` per tenant (step 3a). Pick the version by sweeping **all remote branches** — `ls db/migration/` shows a stale head because unmerged branches hold invisible versions |
| `v2/wms2-api/.../controller/StockUnitController.java` | modify | Fix C catch on `transferStock`; Fix B usability filter on `isUnitLoadIdValid` |
| `v2/wms2-api/src/main/resources/messages.properties` | modify | 3 keys (base bundle — locale safety) |
| `v2/wms2-api/src/main/resources/messages_en_US.properties` | modify | same 3 keys |
| `v2/wms2-api/src/test/.../unit/service/StockunitServiceTransferStockDestinationTest.java` | **new** | Fix A + B unit coverage |
| `v2/wms2-api/src/test/.../unit/controller/StockUnitControllerUnitTest.java` | modify | Fix C: `EntityNotFoundException` → 200 `{errors}`; pin the bulk parity |
| `v2/wms2-api/src/test/.../unit/service/StockunitServiceUnitTest.java` | modify | update the 9 existing `transferStock` invocations for the new throw types |
| `v2/wms2-api/src/test/.../unit/service/StockunitServiceTransferStockGuardTest.java` | modify (if needed) | SBDEV-2074 invariant must stay green through Fix A's `false`-branch change |
| `v2/wms2-web-ui/components/handlingUnits/popups/transferStock.vue` | modify | Fix B: reword the client-side toast (§12 Q1) |
| `v2/wms2-mobile-ui/components/moveStock/scanDestination.vue` | modify | Fix D pre-validation |
| `v2/wms2-mobile-ui/store/moveStock.js` | modify | Fix D `checkContainer` action |
| `v2/wms2-mobile-ui/test/…` | **new** | Jest coverage for Fix D |
| `sbdocs/3-Resources/architecture/wms-exception-taxonomy.md` | modify | write down the operator-input vs internal-reference discriminator |
| `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md` | modify | document the destination error contract (currently absent) |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| DB state | **N/A** | No schema or data change. The triggering row (`unitload 21552195`) is left exactly as-is — it is correct data. |
| Feature flags | ⚠ **Yes (was N/A)** | Fix B's lock/Shipped clauses are gated on `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED`, default `false` (§5 Fix B, §12 Q6). The draft's "no behavioural risk worth gating" was written when Fix B was believed to refuse almost nothing; measurement showed it refuses 411,862 unit loads on one tenant. **The Nirvana-sentinel refusal is deliberately NOT gated** — it is the SBDEV-2995 data-loss path. |
| System properties | ⚠ **Yes (was N/A)** | One new key, `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED`, seeded `false` for every tenant in step 4a. ⚠ `los_sysprop.description` is `varchar(255)` — an over-long seed raises 22001 and rolls back the whole migration file. |
| Config / env | **N/A** | — |
| Deploy order | **Yes — and the draft prescribed the WRONG one** | ⚠ **`wms2-web-ui` FIRST, then `wms2-api`, then `wms2-mobile-ui`.** The draft said "API first, mobile second… not a hard coupling" and never mentioned the web repo. But Fix B's probe fold (api) and the toast reword (web) are **one semantic change split across two independently-deployed repos**. Deploy API first and, for the whole inter-deploy window, the probe returns `false` for **411,862 existing Shipped containers** while the desktop still says *"Container does not exist"* — about containers the operator can see on a shelf. That is exactly the untruth §12 Q1 exists to eliminate, manufactured by the prescribed order. Web-first is safe both ways: "Container is not available to receive stock" is still true while the probe is existence-only. Mobile (Fix D) last — it calls an endpoint that already exists. |
| Data migration | **N/A** | — |
| External systems | **N/A** | No OMS contract touched. |
| Access / roles | **N/A** | No new endpoint, no new function gate. |
| Monitoring | **Yes** | Fix C's `LOG.error` is the new signal. Confirm it reaches the standard log sink before relying on it (§9 R2). |
| Resource bundles | **Yes** | New keys go in **both** `messages.properties` and `messages_en_US.properties`. A key in only one is the documented locale trap. |

### 7.2 Steps

Each step is independently committable.

1. **Constants + bundles.** Add the 3 keys to `WmsConstants` and to **both** properties files. Commit alone — it is inert and makes the next diffs readable.
2. **Fix A — destination label** (`StockunitService.java:154-156`). Concise
   `.orElseThrow(() -> new BusinessException(KEY, unitLoadLabelId))`. Compile. ⚠ Earlier revisions
   specified the verbose `Optional` + `isEmpty()` shape here; that was a consequence of the false
   compiler claim corrected in §5 and is **not** required.
3. **Fix A — destination location** (`StockunitService.java:178`). Same concise shape. **Confirm `CancellationReversalService.java:203` still compiles** — `completeReversal:172` already declares `throws BusinessException, FacadeException`, so it should, but this is the one cross-caller compile risk in the plan.
3a. **Sysprop + migration** — add `SYSTEM_PROPERTY_TRANSFER_DESTINATION_ELIGIBILITY_ENABLED_KEY` to `WmsConstants` and a Flyway migration seeding `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED=false` for every tenant. Ships **before** step 4 so the guard is inert on arrival. ⚠ `los_sysprop.description` is `varchar(255)` — an over-long seed raises 22001 and rolls back the whole migration file, blocking the tenant's chain. ⚠ Renumbered from "4a", which an earlier revision printed *after* step 5 while its own text said it ships before step 4.
4. **Fix B — create `DestinationEligibilityService`** with the throwing `assertCanReceiveStock(Unitload)` and the TOTAL, `@Transactional(readOnly=true)`, **public** `canReceiveStock(Unitload)`. Inject it into `StockunitService` and call the assert immediately after the destination resolves in the existing-container branch. ⚠ This step previously described a *private helper on `StockunitService`* — the pre-extraction shape — which contradicted §5, §10 row 3 and verify rows `B1`/`T2`.
5. **Fix C — controller catch** on `transferStock`, with `LOG.error`. Do **not** touch `bulkTransferStock` — it already has the catch; the point is to converge on it.
6a. **Web first (§7.1 deploy order)** — reword `wms2-web-ui .../popups/transferStock.vue:144` to "Container is not available to receive stock". **Ships and deploys before 6b.**
6b. **Then api** — fold `destinationEligibilityService::canReceiveStock` into `isUnitLoadIdValid`, keeping the bare `Boolean` response shape. ⚠ Steps 6a/6b were previously **one step spanning two repos**, which cannot be sequenced web-first and so contradicted §7.1's own ordering decision.
7. **Tests** — §8. Run `mvn test -Dtest=StockunitService*Test,StockUnitControllerUnitTest`, then `mvn clean compile`.
8. **Fix D — mobile** pre-validation + Jest coverage (§12 Q2).
9. **Docs** — the taxonomy discriminator (§5.4) and the move-stock workflow's destination error contract.

**Branch:** `feature/SBDEV-2994-move-stock-unknown-destination-container` off freshly-fetched `origin/develop`, one per repo (`v2/wms2-api`, `v2/wms2-mobile-ui`, `v2/wms2-web-ui`). The api and mobile checkouts are currently behind `origin/develop` (api by 18, mobile by 6) — **fetch and branch off `origin/develop`, not the local `develop`**, and check `wms2-web-ui` the same way before branching.

---

## 8. Testing Plan

### 8.1 Unit — `StockunitServiceTransferStockDestinationTest` (new)

Extends `BaseServiceUnitTest`, modelled on `StockunitServiceTransferStockGuardTest`. Assert on **`getKey()`**, never on rendered text (`BusinessException.java:133-144`).

| Test | Asserts |
|---|---|
| `existingContainer_unknownLabel_throwsBusinessExceptionWithKey` | `findByLabelid` empty → `BusinessException`, `getKey()` == `transferStockDestinationUnitloadNotFound`; **not** `EntityNotFoundException` |
| `existingContainer_unknownLabel_doesNotTouchStock` | `verify(stockunitBusinessService, never()).transferStockToUnitLoad(...)` — the no-corruption claim, pinned |
| `existingContainer_toDeleteDestination_throwsBusinessException` | destination present with `entityLock=GOING_TO_DELETE` → `getKey()` == `…NotUsable` |
| `existingContainer_nirvanaDestination_throwsBusinessException` | destination at `Nirwana` → `…NotUsable` |
| `existingContainer_shippedDestination_throwsBusinessException` | destination at `Shipped` → `…NotUsable` |
| `existingContainer_healthyDestination_transfersNormally` | happy path unchanged — the regression guard for Fix B |
| `newContainer_unknownLocationName_throwsBusinessExceptionWithKey` | `findByName` empty → `getKey()` == `transferStockDestinationLocationNotFound` |
| `internalLookupMiss_stillThrowsEntityNotFound` | e.g. `unitloadTypeRepository.findByName(PALLET)` empty → still `EntityNotFoundException`. **This is the test that proves the split is real** rather than a blanket conversion. ⚠ Reaching `:157` requires `findByLabelid` to **succeed** first, which under Fix B also requires the eligibility lookup to resolve — stub it or the test fails for the wrong reason |
| `canReceiveStock_nullStoragelocationId_returnsFalse` | ⚠ **New — pins the PM-1 mechanism.** `Unitload.storagelocationId` is a plain `Long`; `findById(null)` throws `InvalidDataAccessApiUsageException`. The predicate must be **total**: null ⇒ `false`, never a throw |
| `canReceiveStock_unresolvableLocation_returnsFalse` | Dangling FK ⇒ `false`. Without this the probe 404s and the desktop shows the very toast this ticket deletes |
| `canReceiveStock_shippedDestination_returnsFalse` | The branch carrying ~95% of the real population (411,862 ULs) |
| `assertCanReceiveStock_shippedDestination_throwsBusinessException` | The write-path twin of the above; `getKey()` == `transferStockDestinationNotUsable`, **gate ON** |
| `assertCanReceiveStock_shippedDestination_gateOff_allowsAndLogsShadow` | ⚠ **New — the gate-OFF pass-through §5 promised and an earlier revision never wrote.** With the sysprop `false`, a Shipped destination must **NOT** throw, and the shadow `WARN` must be emitted (`LogCaptor`/`ListAppender`). This is the only test of the mechanism that retires R3 |
| `assertCanReceiveStock_toDeleteDestination_gateOff_allowsAndLogsShadow` | Same for the To-Delete branch |
| `assertCanReceiveStock_nirvanaSentinel_gateOff_STILL_throws` | ⚠ **The most important row in this table.** The Nirvana refusal is deliberately **ungated** (§12 Q6) because it is SBDEV-2995's silent-data-loss path. With the sysprop `false` it must **still throw**. Verify row `B13` pins the code shape; this pins the behaviour |
| `assertCanReceiveStock_absentSyspropRow_behavesAsGateOff` | Fail-safe: an un-seeded tenant behaves as today |

Bundle safety, in the same class (per the `ResourceBundle` parent-chain trap — a `ResourceBundle`-based assertion catches divergence but **not** deletion from the child bundle):

| Test | Asserts |
|---|---|
| `messageKeys_presentInBaseBundle` | direct load of `messages.properties` (**not** `ResourceBundle` — the parent chain resolves a key from the base bundle even after it is deleted from the child) contains all 3 keys. ⚠ Use an **explicit UTF-8 `Reader`**: `Properties.load(InputStream)` is ISO-8859-1 while `PropertyResourceBundle` is UTF-8, so the `InputStream` overload tests a different decoding than production uses. Worked pattern: `UnitloadBusinessServiceUnitTest` T14b |
| `messageKeys_presentInEnUsBundle` | same, for `messages_en_US.properties` |
| `messageKeys_interpolateTheIdentifier` | ⚠ **New.** Each value must contain its `%1$s` (and `%2$s` for `…NotUsable`). Asserting the key *exists* is not enough — `transferStockDestinationUnitloadNotFound=Container not found.` would satisfy a key-presence check while failing the entire point of the ticket, which is to name the container |
| `messageKeys_renderViaGetLocalizedMessage` | `getLocalizedMessage(Locale.ROOT)` returns the interpolated text, not the concatenated `key, 'param'` fallback |

### 8.2 Unit — `StockUnitControllerUnitTest` (modify)

⚠ **Read this before writing any row below.** `BaseControllerUnitTest.setupMockMvc` (`:49-57`) builds
`MockMvcBuilders.standaloneSetup(controller)` with argument resolvers and a message converter but
**no `.setControllerAdvice(...)`**, so `RestExceptionHandler` is **not registered in the unit lane at
all**. Consequences: on the unfixed tree these tests fail by *throwing* (nested `ServletException`),
not by observing `status().isNotFound()` — fine as a red-first gate, but it means **no automated lane
anywhere observes the 404→200 contract change this ticket rests on.** §8.5's original framing ("no
IT") understated this: it is not that integration coverage is missing, it is that *no runnable lane*
exercises the handler. The `entityNotFoundStillMapsTo404_onTheUnnettedPath` row below is the
compensating control.

| Test | Asserts |
|---|---|
| `transferStock_entityNotFound_returns200WithErrors` | service throws `EntityNotFoundException` → **200**, body has `errors[0].field == "Runtime Error"` (the key is `field`, not `type` — see §5 Fix A). ⚠ **The label is `"Runtime Error"`, matching §5 Fix C's normative code and §0.2 row 15's bulk analysis.** An earlier revision of this row said `"Entity Not Found"`, contradicting the code block it was meant to verify; verify row `T5` greps only the literal `errors[0].field` and cannot discriminate, so the contradiction would have reached the gate. ⚠ This test can observe the POST-fix 200 but **not** the pre-fix 404: `BaseControllerUnitTest:49-57` builds MockMvc via `standaloneSetup(controller)` with **no `.setControllerAdvice(...)`**, so `RestExceptionHandler` is not registered and the unfixed tree fails by *throwing*, not by returning 404. Adequate as a red-first gate; it verifies nothing about the status contract. |
| `transferStock_businessException_returns200WithErrors` | existing behaviour pinned. ⚠ A test of this shape already exists as `returnsErrorsWhenBusinessException` (`:265-286`) — extend it, do not add a duplicate under a new name |
| `bulkTransferStock_entityNotFound_returns200WithErrors` | ⚠ **This test does NOT exist and must be written.** The draft called it a "parity reference — must stay green untouched"; the `BulkTransferStock` nested class has exactly two tests (`:315-344`, `:346-364`), neither exercising `EntityNotFoundException` |
| `bulkTransferStock_deadLabel_continuesLoopAndReportsEveryRow` | ⚠ **New — pins the behaviour change Fix A causes** (§0.2 row 15). Two ids, first with a dead destination label: today the loop **aborts** with 1 error; after Fix A it **continues** with N errors and `field` flips from `"Entity Not Found"` to `"Runtime Error"`. Nothing in the draft detected this |
| `transferStock_entityNotFound_logsAtError` | ⚠ **New — makes R1 falsifiable.** `LogCaptor` / logback `ListAppender` asserts the `ERROR` line is emitted with the stock-unit id. Without it R1's only mitigation is prose |
| `transferStock_entityNotFound_doesNotLeakInternalMessage` | ⚠ **New.** The response body must **not** contain `e.getMessage()` — no `"not found with id:"`, no entity class name. Pins §5 Fix C's operator-safe string |
| `entityNotFoundStillMapsTo404_onTheUnnettedPath` | ⚠ **New, ~10 lines.** A second MockMvc built as `standaloneSetup(controller).setControllerAdvice(new RestExceptionHandler())`, asserting `StockUnitController:89`'s deliberately-untouched path **still 404s**. This is the **only** automated proof anywhere that the advice mapping is real |

### 8.3 Regression

- `StockunitServiceTransferStockGuardTest` — SBDEV-2074/2033 invariant. It drives the `false` branch with `locationName="DEST-900"`, which Fix A changes; it must stay green.
- `StockunitServiceUnitTest:1454-1968` — 9 `transferStock` invocations. ⚠ **The draft's diagnosis was wrong.** It said "update … for the new throw types". Two of them — `transfersToExistingNonPalletContainer` (`:1454`) and `transferStock_doesNotTriggerReplenishmentMaintenance` (`:1508`) — break for a **different reason**: neither stubs `locationRepository.findById(10L)`, and Mockito returns `Optional.empty()` for unstubbed `Optional` returns, so Fix B's new eligibility lookup throws. An implementer following the draft would look in the wrong place. (`:1484` and `:1543` already stub it and survive.)
- `StockUnitControllerUnitTest.IsUnitLoadIdValid.returnsTrueWhenUnitloadExists` (`:1030-1044`) — ⚠ **breaks under Fix B.** It builds `new Unitload()` with a **null** `storagelocationId` and asserts `jsonPath("$", is(true))`; after the probe fold the mocked service returns `false` by default. Restub it.

### 8.4 Mobile Jest (Fix D)

`wms2-mobile-ui` **does** have a working Jest suite despite `CLAUDE.md` saying otherwise. There is no `yarn` on PATH — run `node_modules/.bin/jest` under an nvm node.

| Test | Asserts |
|---|---|
| `scanDestination submit() blocks when checkContainer returns false` | no `transferStock` dispatch; toast is exactly `Container ${label} is not available to receive stock` |
| `scanDestination submit() proceeds when the probe itself errors` | ⚠ **New — fail OPEN.** A failed probe must not block the move; the server decides. Prevents copying `stockUnits.js:215-218`'s bug where a failed probe leaves `validContainer=false` and the operator gets two wrong toasts |
| `scanDestination does not probe in 'new' mode` | ⚠ **New.** In `new` mode `labelId` is the **source** UL (`:160`); an unscoped probe would test the wrong container |
| `checkContainer returns true when the probe request itself throws` | ⚠ **Pins fail-OPEN explicitly.** A shadow shipping fail-CLOSED (`return false` in the catch — the exact `stockUnits.js:215-218` bug this plan cites) previously scored identical to a correct implementation, because no verify row and no test covered it. Verify rows `D5`/`D6` now back these two |
| `scanDestination submit() proceeds when checkContainer returns true` | dispatch fires with the expected payload |
| existing specs still pass after `submit()` becomes `async` | ⚠ **`test/components/move-damaged-reason-payload.spec.js:359-365` calls `wrapper.vm.submit()` synchronously and asserts `toHaveBeenCalledTimes(1)`.** Fix D inserts an awaited dispatch before the transfer dispatch, changing both count and synchronicity. `test/pages/workflow-reset-on-entry.spec.js` also drives this component. Both must be updated — neither was listed in the draft |

### 8.5 Integration

**Deferred.** The v2 Testcontainers lane cannot boot (SBDEV-2217) — the whole IT surface is `@Disabled` on `develop`. Do not add an IT that cannot run; gate on unit tests + `mvn clean compile` + the manual plan below. Revisit when the harness is repaired.

### 8.6 Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | The reported case, verbatim | WineCo dev, mobile | Move Stock → source `UL319408` → amount 1 → Existing Container → scan `UL314581` → Submit | Toast names `UL314581` and says it was not found / may have been emptied. **Not** the network toast. No stock moved. | |
| M2 | Typo'd label | WineCo dev, mobile | scan `UL999999` | Same message shape, names `UL999999` | |
| M3 | Live destination (happy path) | WineCo dev, mobile | scan a container currently in use for the same client | Stock moves; "Stock moved" toast; source amount decreases | |
| M4 | To-Delete destination | WineCo dev, mobile | scan a UL with `entity_lock=2` under an unmangled label (seed one if none exists) | "…is To Delete and cannot receive stock" | |
| M5 | Desktop single transfer | WineCo dev, web | Handling Units → Transfer Stock → Existing Container → a dead label | Client-side "Container does not exist" (unchanged); if the probe is bypassed, the server message from M1 | |
| M6 | Desktop bulk transfer | WineCo dev, web | select **3** rows → Transfer Stock → Existing Container → a dead label | ⚠ **REWRITTEN — the draft said "unchanged from today", which is false.** *Today:* the loop **aborts** on row 1 with **one** error (`field="Entity Not Found"`) and rows 2-3 are never attempted. *After Fix A:* the loop **continues**, producing **three** errors with `field="Runtime Error"`. Confirm the new behaviour explicitly; a tester following the draft would have "confirmed" the wrong thing. The web UI renders only `errors[0].message`, so the operator-visible change is wording | |
| M9 | Desktop probe against a dangling location | WineCo dev, web | pick a container whose `storagelocation_id` points at no `location` row (seed one), open Transfer Stock, scan it | ⚠ **New — pins PM-1.** Must show "Container is not available to receive stock", **never** the generic network toast. If the network toast appears, `canReceiveStock` is not total and Fix B has re-created this ticket's bug on the desktop | |
| M10 | Nirvana sentinel | WineCo dev, mobile | type `Nirwana` as the destination container | Rejected. ⚠ Tracked as **SBDEV-2995**; included here because Fix B closes it incidentally and a regression would be silent data loss | |
| M7 | Cancellation reversal regression | WineCo dev | complete a reversal whose `pickfromlocationname` still exists | Succeeds as before (Fix A changed its throw type on the failure path only) | |
| M8 | SQL sanity after M1 | WineCo dev | `SELECT amount, reservedamount FROM stockunit WHERE unitload_id=30676364;` | `4.0000 / 0.0000` — unchanged, proving no partial commit | |

---

## 8.7 Acceptance

**Script:** `sbdocs/9-System/scripts/verify-SBDEV-2994-move-stock-unknown-destination-container-generic-error.sh`

```
PROJECT_ROOT=<worktree>/v2/wms2-api \
MOBILE_ROOT=<worktree>/v2/wms2-mobile-ui \
WEB_ROOT=<worktree>/v2/wms2-web-ui \
  bash sbdocs/9-System/scripts/verify-SBDEV-2994-move-stock-unknown-destination-container-generic-error.sh
```

Point all three roots at the implementation worktree (or a symlink shadow root). Left at their
defaults the script grades the main checkouts, not the work.

**Script revision 2** — rewritten after the consensus review, which built a wrong-implementation
tree and demonstrated that **five** of revision 1's rows (`A3`, `B3`, `C1`, `T2`, `T3`) passed
against implementations wrong in exactly the way those rows existed to catch.

**Baseline, measured 2026-08-18 against `origin/develop` (api `d2bedc0`, mobile `8e623b8`):**

```
Result: 4 pass, 41 fail, 1 skip
```

The 4 passes are the parity pins — `A3` (internal lookups already use `EntityNotFoundException`;
threshold 32 = 34 today minus exactly the 2 sites Fix A converts, so converting even one extra trips
it), `P1`, `P2`, `P3`. Green **before and after**. Every Fix row is red.

**Validation, and an important correction to how it was first reported.**

| Direction | Result |
|---|---|
| unfixed `origin/develop` | 4 pass (pins only), 41 fail — every Fix row red |
| correct shadow | all Fix rows **green**, no false-REDs |
| six near-miss WRONG shadows | ⚠ **all six returned `42 pass, 0 fail`** before the iteration-2 repairs |

⚠ **The first write-up of this section claimed the script was "validated in BOTH directions". That
claim was true but materially overstated, and the overstatement mattered.** One wrong implementation
was tested — a leaking Fix C body — and the result was generalised to the whole script. Iteration 2
rebuilt the correct implementation *plus six near-misses*, each being precisely the defect a row
exists to catch, and **every one of them passed**:

| Mutation | Row that should have caught it | Why it walked through |
|---|---|---|
| `canReceiveStock` uses `.get()` with no null guard — **PM-1 exactly** | `B8` | the row forbade the literal `orElseThrow` and nothing else; `.get()` and `findById(null)` were invisible to it |
| the `RestExceptionHandler` log line **deleted** rather than raised to `warn` | `C4` | a bare negation — "no `LOG.debug` survives" is satisfied by deleting the logging |
| the mobile probe moved **out** of the `existing` block | `D3` | the anchor backtracked onto the third `currentMode === 'existing'` occurrence, after which any `checkContainer` satisfied it |
| one **extra** internal lookup blanket-converted | `A3` | threshold off by one — `A4` adds an `EntityNotFoundException` back, so correct is 33, not 32 |
| en_US value reduced to `Container not found.` (no `%1$s`) | `K3` | the row audited `messages.properties` only; `messages_en_US.properties` is the bundle that actually renders |
| `transferStock`'s catch does not log; `bulkTransferStock`'s does | `C2` | anchored file-wide while its sibling `C3` was hardened with `method_slice` |

All six rows are repaired above and the baseline is re-measured at **4 pass / 41 fail / 1 skip** (rows B8b, B12, B13 added since).

**The lesson, corrected.** "Run against a correct shadow as well as the unfixed tree" is the *lesser*
half. A correct shadow proves there are no false-REDs. **Only a family of near-miss wrong shadows
proves there are no false-GREENs** — and a false-green is the failure that actually ships a defect.
Red-only baselining could not see any of these six; single-wrong-shadow testing caught one of seven.

**Final acceptance:** `Result: N pass, 0 fail` pasted verbatim in the end-of-task report, plus
`RUN_MVN=1` for the three targeted maven rows.

### Script defects found by testing the script — seven now, across two revisions

Recorded because every one produces a confident, meaningless green (or an equally meaningless red).
The recurring cause is always the same: **a file-scoped grep cannot express "in this method".**

*Revision 1, found by baselining:*
1. **`A3` false-FAILed on a case typo** — the literal is `"UnitLoadType"`, capital **L**.
2. **`P3` was permanently red and unfalsifiable** — a file-scoped `file_not_contains
   'recalculateForItem'`, but that call is legitimate at `:127` in a different method.

*Revision 1, found by the review building a wrong-implementation tree:*
3. **`A3`, `B3`, `C1`, `T2`, `T3` passed on wrong implementations.** `B3` is the sharpest:
   `GOING_TO_DELETE` already appears at `:368/:421/:465/:514`, so a guard omitting To-Delete
   entirely went green. `T2`/`T3` passed on files containing only *comments*.

*Revision 2, found by re-baselining and positive-testing:*
4. **`C3` and `B8` passed VACUOUSLY** — both were bare negations over a construct that does not
   exist on the unfixed tree, and a negation over an absent construct is trivially true. Both now
   require the construct to exist first.
5. **`C4` passed vacuously on a wrong literal** — it grepped `LOG.debug("EntityNotFound`, but the
   real line is `LOG.debug(ex.getMessage());`. The regex matched nothing while the defect was fully
   present.
6. 🔴 **`file_contains_within` was broken for every pattern containing `@`.** The helper spliced
   patterns into the perl *source*, so `@PostMapping` / `@ExceptionHandler` were parsed as **array
   variables** and interpolated to nothing — collapsing the tempered lookahead to `(?!)`, which
   always fails, so the gap could never be traversed. Effect: `C4` green when it should be red, and
   `C1`/`C2`/`C3` **would have stayed red even after a correct implementation**. Patterns now pass
   through the environment, where perl does no `@`/`$` interpolation. This one defect silently
   poisoned four rows.
7. **`C3` false-RED against a CORRECT implementation** — found only by positive-testing. It matched
   `bulkTransferStock`'s catch, which legitimately *does* use `e.getMessage()`. Some assertions are
   genuinely per-method and no single regex expresses them; `C3` now slices `transferStock`'s body
   first (`method_slice`) and asserts on the slice.

**The lesson worth carrying:** defects 4-7 were invisible to red-only baselining. Three of them
(`C1`, `C2`, `C3`) would have read as "not implemented yet" forever, and defect 6 would have been
diagnosed as a bad implementation rather than a bad script. **Every future verify script in this
vault should be run against a correct shadow as well as the unfixed tree.**

---

## 9. Horizontal Scalability Validation

`v2/wms2-api` runs multiple replicas behind a load balancer.

| # | Concern | Verdict | Note |
|---|---|---|---|
| 1 | In-JVM state | **N/A** | No new caches, statics, or thread-locals. The helper is stateless. |
| 2 | Connection pool math | **N/A** | Fix B's `locationRepository.findById` runs inside the existing `transferStock` transaction — no new connection. Fix D's probe is a pre-existing endpoint; it adds one short read per scan on the mobile path, bounded by operator scan rate. |
| 3 | Scheduled jobs | **N/A** | None touched. |
| 4 | Long transactions | **No** | The new guard runs at the head of an existing transaction and shortens it on the failure path (throws earlier). |
| 5 | Request affinity | **N/A** | Stateless request. |
| 6 | Retry / idempotency | **N/A** | Failure paths write nothing, so replay is trivially safe. Happy path unchanged. |
| 7 | Tenant context | **N/A** | No async, no `CompletableFuture`, no scheduled hop. |
| 8 | Distributed lock correctness | **No** | No new locks. `transferStock` keeps `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` — **and `BusinessException` is already in `rollbackFor`**, so the new throws roll back correctly (`wms-exception-taxonomy.md` §Rollback: checked exceptions need explicit `rollbackFor`). Verify this annotation is untouched. |
| 9 | Cache invalidation | **N/A** | No writes to cached entities on any new path. |
| 10 | External notifications | **N/A** | No OMS/message send added. Fix A/B throw *before* the `sendStockChangeMessage` at `:251`. |

---

## 10. v2 constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | ⚠ **Yes (was N/A).** True only on the *service* path. On the **probe** path the controller calls `canReceiveStock` with no surrounding transaction and OSIV off, so `findByLabelid` opens/closes one transaction and the eligibility lookup opens another — two acquisitions and a read-consistency gap between them. Hence the `readOnly` annotation in row 3. |
| 2 | Transaction manager | **Yes** — `StockunitService.java:149` already declares `tenantTransactionManager` + `rollbackFor` incl. `BusinessException`; must remain byte-for-byte |
| 3 | `readOnly=true` | ⚠ **Yes (was "N/A — a private helper, not a service entry point"). Wrong on both counts.** `canReceiveStock` is reached as `destinationEligibilityService::canReceiveStock` from `StockUnitController.isUnitLoadIdValid`; a method reference cannot bind a private method, so it **is** public and **is** a service entry point, called from a `GET` handler. It carries `@Transactional(value="tenantTransactionManager", readOnly=true)`. |
| 4 | Caffeine invalidation | **N/A** — no cached entity written |
| 5 | Jakarta namespace | **N/A** — no imports copied from v1 |
| 6 | H2-compatible test SQL | **N/A** — pure Mockito unit tests, no SQL |
| 7 | `BaseControllerTest` for controller changes | **Yes** — Fix C changes `StockUnitController`; extend the existing `StockUnitControllerUnitTest` (the class is `BaseControllerUnitTest`, not `BaseControllerTest`). ⚠ Its `setupMockMvc` (`:49-57`) is `standaloneSetup(controller)` with **no `.setControllerAdvice(...)`**, so `RestExceptionHandler` is **not registered** — see §8.2. |
| 8 | Micrometer metrics | **No** — but only because the estate-wide fix lands: `RestExceptionHandler:155` `debug`→`warn` gives one greppable signal for all 61 controllers. Fix C's `LOG.error` alone would leave 60 controllers silent and "we have monitoring" would be false comfort. §8.2 adds a log-emission assertion so R1 is falsifiable without a counter. |

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **R1** Fix C converts a 404 into a 200, hiding genuine data corruption | Medium — **the draft had this backwards** | `RestExceptionHandler:155` already logs these at **`LOG.debug`** — invisible in every environment — so Fix C's logging is a strict *improvement*, not a downgrade. Two-part mitigation: the `LOG.error` in the catch, **plus** `RestExceptionHandler:155` `debug`→`warn` for all 61 controllers. §8.2 adds a **log-emission assertion** so R1 is falsifiable in the unit lane instead of resting on prose. Owner: implementer. |
| **R2** The `LOG.error` never reaches the log sink, voiding R1 | Medium | ⚠ The draft's mitigation was unfalsifiable — "force one internal-lookup failure on dev" named no mechanism (all 11 sites are FKs unbreakable from the UI) and no owner. **Concrete:** on dev, temporarily rename the `Pallet` row in `unitload_type`, run one existing-container transfer to a pallet, confirm the `ERROR` line, rename back. ~2 minutes, reversible. **Owner: implementer, during the §8.6 manual pass.** |
| **R3** Fix B rejects a destination operators legitimately use today | **High — NOT cleared. The draft's clearing was invalid** | ⚠ All three reviewers rejected it, for three independent reasons: **(a)** the query joined `sr.tounitload = unitload.labelid`, but `sendToNirvana` **renames** retired rows to `<label>-X-<id>` — the very mechanism this ticket is about — so the join drops the population being counted (66% of `MANUAL_*` records match no current label); **(b)** `entity_lock=104` has **zero rows tenant-wide**, so the ON_HOLD half **could not fail** whatever the truth (P5); **(c)** all-time hits are **958**, most recent **2025-04-23** — the 365-day window opens just after the last occurrence. Production was never measured. ⚠ **RE-SCOPED (N7): R3 no longer blocks implementation — it blocks ENABLEMENT.** With shadow mode designed (§5 Fix B), Fix B may be written, merged and deployed with the sysprop `false`; the shadow `WARN` line then *produces* the evidence R3 needs, per tenant, without anyone having to invent a query that can see the mangled population. **A tenant is switched to enforcing only after its shadow count is zero over a full operating cycle.** The corrected one-off query (all time, joining on `split_part(tounitload,'-X-',1)`, on a production tenant) remains useful as a cross-check but is no longer a hard gate. ON_HOLD is dropped from Fix B entirely. **Owner: whoever enables the first tenant.** |
| **R4** `CancellationReversalService:203` now receives `BusinessException` where it expected `EntityNotFoundException` | Low | It already `throws BusinessException` at `:172` and already raises one for an analogous not-found at `:186-187`. Step 3 makes the compile check explicit; M7 covers it at runtime |
| **R5** New message keys land in `messages_en_US.properties` only | Low | §8.1 asserts both bundles via direct `Properties.load` (not `ResourceBundle` — the parent chain masks a missing child key) |
| **R6** Tests assert rendered copy and break on the first rewording | Low | Assert `getKey()`. Explicitly called out in §5 Fix A and §8.1 |
| **R7** Local checkouts are behind `origin/develop` (api 18, mobile 6) and the branch is cut from a stale base | Medium | Step 7.2 branch note: fetch first, branch off `origin/develop` |
| **R8** `mvn test` mutates the tracked `archunit_store` | Low | Revert it before committing. Two pre-existing failures on clean `develop` are expected — compare against that baseline, not against zero |
| **R9** Fix D's extra round-trip slows the scan loop | Low | One small GET on an endpoint the desktop already calls per submit. If material, drop Fix D — A+C already deliver the fix. Owner: implementer. |
| **R10** Fix B refuses a legitimate consolidation in production and there is no way to turn it off | **High (new, from the pre-mortem)** | §7.1 declined a sysprop gate and there is no dark-launch, so the only rollback is a hotfix across all tenants. Combined with R3 being uncleared this is the largest risk in the plan. **Mitigation: gate Fix B behind a sysprop defaulting OFF**, enable per tenant after observing its log line in shadow mode. This reverses the draft's "no behavioural risk worth gating". |
| **R11** Fix C's `LOG.error` becomes routine noise and gets filtered, making the 404→200 a pure loss of signal | **Medium (new, from the pre-mortem)** | R2 covered "the line never arrives"; nothing covered "it arrives 400×/day and someone mutes it". The `RestExceptionHandler:155` `warn` gives an estate-wide baseline, so an endpoint-specific spike is distinguishable from background rate. |
| **R12** Fix A + Fix D interact — the probe rejects client-side, so the operator never sees the server keys Fix A exists to write | **Medium (new, from the pre-mortem)** | Fix D's toast carries the same meaning as the server key (§5 Fix D), and Fix D fails **open** on a probe error so the server message stays reachable. §8.4 asserts both. |
| **R13** A rushed merge resolves a conflict using the 1-arg `BusinessException(String)` ctor | **Low (new, from the pre-mortem)** | `BusinessException:42-47` sets `key="placeholder"` silently and every `getKey()` call still compiles. §8.1 asserts `getKey()` **equals** the specific key, so this fails loudly rather than passing. |

---

## 11.5 Pre-mortem

⚠ **Added after review.** Deliberate mode requires a pre-mortem, and §11's risk register does not
substitute: a register asks "what could go wrong with each change", one row at a time. A pre-mortem
asks the opposite question — *it is six months from now and this change caused an incident; what
happened?* — which surfaces the failure modes a per-row register structurally cannot: **interactions
between fixes, adoption failures, and the ways the mitigations themselves fail.** Each scenario below
produced a risk row that did not previously exist.

### PM-1 — "Container is not available to receive stock" becomes the new unactionable toast, on the desktop

`canReceiveStock` resolves the destination's location. `Unitload.storagelocationId` is a plain `Long`
with no FK-backed guarantee, and `findById(null)` throws `InvalidDataAccessApiUsageException`. On any
tenant carrying a unit load whose `storagelocation_id` is null or points at a deleted row, the probe —
a method with **no `try`** whose declared contract is `Boolean` — throws, 404s, and
`wms2-web-ui store/handlingUnits/stockUnits.js:209-219` catches it into *"Error: Request failed due to
a network or server issue. Please retry."* **The exact toast this ticket exists to eliminate, now on
the desktop, on a perfectly healthy container.** Six months on it reopens as "the SBDEV-2994 fix broke
desktop transfers."

*Provable today:* `StockUnitControllerUnitTest.returnsTrueWhenUnitloadExists` (`:1030-1044`) builds a
`Unitload` with only `labelid` set, so `getStoragelocationId()` is null. That test goes red the moment
Fix B lands. → **§5 Fix B's totality contract; §8.1 two new tests; §8.6 M9.**

### PM-2 — Fix B refuses a live workflow on a tenant nobody measured

R3 was "cleared" on two dev/UAT tenants by a query that (a) joins on a label the retirement path
**renames**, (b) tests a lock state with zero rows so it cannot fail, and (c) uses a 365-day window
opening just after the last real occurrence. A production tenant runs a "park it on hold → consolidate
into it → release the lot" pattern; Fix B refuses the consolidation. Because it returns a clean
`BusinessException` → HTTP 200, **it never trips a 5xx alert**. Operators blame the scanners. There is
no sysprop gate (§7.1 declined one) and no dark launch, so the only rollback is a hotfix across all
tenants. → **R3 reopened; ON_HOLD branch dropped; new R10 requiring a sysprop gate defaulting OFF.**

### PM-3 — the 404→200 conversion becomes a pure loss of signal

Fix C's mitigation is a log line. A botched tenant migration leaves `unitload_type` rows missing;
`StockunitService:157`'s `findByName(PALLET)` misses on **every** pallet transfer; every operator gets
a polite HTTP 200; nothing pages; the only trace is one `ERROR` among thousands — or, worse, the line
is loud enough that someone mutes it in month two. Under the pre-Fix-C behaviour this was a 404 flood,
visible on any status-code dashboard. → **new R11; the `RestExceptionHandler:155` `debug`→`warn` change
so there is an estate-wide baseline to compare a spike against; §8.2's log-emission assertion.**

### PM-4 — the fixes cancel each other on the path that motivated them

Fix D's client-side probe rejects the container before the request is made, so the operator never sees
the server message. If Fix D's copy is generic, Fix A's carefully-keyed, bundle-localised messages
become **dead code on the mobile Move Stock screen — the exact screen in the ticket title.** → **new
R12; Fix D's copy specified to carry the same meaning; Fix D fails OPEN so the server message stays
reachable; §8.4 asserts both.**

### PM-5 — the split lands in the bundle but not in the code

A rushed merge-conflict resolution uses the 1-arg `BusinessException(String)` constructor.
`BusinessException:42-47` silently sets `key="placeholder"`, every `getKey()` call still compiles, and
a test asserting merely that `getKey()` is non-null stays green while all three keys are unreachable.
→ **new R13; §8.1 asserts `getKey()` **equals** the specific key, not that it exists.**

---

## 12. Open Questions / Resolved Decisions

### Open

- **Q5 — PRODUCT DECISION, raised by review: what does an unknown-but-well-formed destination label MEAN?** The two live implementations of this screen answer irreconcilably:
  - `MobileMoveStockService:294-318` — **not an error.** Validate against the `STRING_PATTERN_SEPARATE_STOCK` sysprop; on a match, **auto-create** the container at `Clearing` and proceed. Only a *malformed* label errors, via keyed `noValidString` naming the expected format.
  - `StockunitService.transferStock` + Fix A — **hard rejection**, with a message telling the operator to scan a container already in use.

  These are not two error messages, they are two product decisions about what "Existing Container" means, and no engineering makes both true at once. **This plan picks hard rejection** — it matches the desktop's existing pre-validation, is smaller, and carries no sysprop coupling. But the draft picked it *by accident*, never having seen the alternative. Consequence if it stands: the two mobile Move Stock paths teach operators contradictory rules for the same scan gesture, and Fix A's "scan a container that is currently in use" is false guidance on the sibling screen. Tracked against **SBDEV-2996**.
  ⚠ **MEASURED 2026-08-18 — the tension is real in the CODE but appears dead in PRACTICE. Q5 is downgraded from blocking to confirm-and-close.**

  The auto-create branch is not a general rule: `MobileMoveStockService:294-318` creates only when the
  scanned label matches the `STRING_PATTERN_SEPARATE_STOCK` sysprop.

  | Tenant | `STRING_PATTERN_SEPARATE_STOCK` | `unitload` rows `^SU-` | `unitload_record` rows `^SU-` | total `unitload_record` |
  |---|---|---|---|---|
  | WineCo dev | `SU-\d{6}` | 0 | **0** | 4,027,022 |
  | Hydra UAT | `SU-\d{6}` | 0 | **0** | 83,704 |
  | Hydra dev2 | `SU-\d{6}` | 0 | — | — |

  `stockrecord.tounitload` matching `^SU-` on WineCo dev: **0**.

  Two consequences. **(a) The reported incident does not discriminate between the two designs** —
  `UL314581` does not match `SU-\d{6}`, so the auto-create implementation would have rejected it too,
  just with a better message (`noValidString`, naming the expected format). **(b) Across ~4.1M
  historical unit-load records on three tenants, no `SU-######` container has ever existed.**
  `unitload_record.label` is an unmangled historical snapshot, so retired containers are counted —
  zero means never created, not merely none surviving.

  **So hard rejection stands and Fix D ships as designed**, with no probe exemption, because there is
  no evidence of a label family that is legitimately scanned before it exists.

  ⚠ **Caveat, stated because the same gap invalidated R3:** these are dev/UAT tenants; **production was
  not measured.** The evidence is much stronger than R3's — that query was structurally blind (it
  joined on a label the retirement path renames), whereas this reads an unmangled historical column
  over a large sample — but it is the same class of gap. **One production query closes it:**
  `SELECT count(*) FROM unitload_record WHERE label ~ '^SU-';`

  **Zeshan's input is now a yes/no, not a design decision:** *does anyone ever scan a brand-new
  `SU-######` label to split stock into a fresh container?* SBDEV-2996 still owns retiring the
  divergence between the two screens.
- **Q3 — Fix E (the cross-cutting toast) as a follow-up ticket?** ⚠ **Corrected count: 12 of 13 mobile store modules and 30+ web store modules — 42+ in total, not the "~18" an earlier revision claimed here** (§5 Fix E was corrected; this line was not, so the document contradicted itself). **Recommendation: file a separate ticket**, do not widen this one. Does **not** block the TDD gate — it changes nothing in this plan's scope either way.

### Split to their own tickets — both filed 2026-08-18 (N19)

- **[SBDEV-2995](https://app.clickup.com/t/868ktvc2h)** — *high* — `transferStock` accepts the `Nirwana` sentinel as a destination container; stock silently disappears. Confirmed on WineCo dev (unit load 66252) and Hydra UAT (51151), both `entity_lock=0`. **This ticket's Fix B closes it via the ungated Nirvana branch**, which is why that branch is deliberately outside the sysprop gate.
- **[SBDEV-2996](https://app.clickup.com/t/868ktvc9j)** — `POST /v3/moveStock/scanDestination` carries the same defect across ~15 sites behind a dead mobile action, and owns the create-vs-reject product question (§12 Q5).

Neither has a plan file yet; both are ClickUp-only until picked up.

### Resolved 2026-08-18 (iteration-2 decisions)

- **Q6 — Fix B ships behind a sysprop, defaulting OFF; the Nirvana-sentinel refusal does NOT.** See §5 Fix B. This resolves R10's contradiction with §7.1 and closes the ordering trap the Architect identified: SBDEV-2995's data-loss path must not be fixed only as a side effect of a change shipped disabled.
- **Q7 — `QUALITY_FAULT` removed from the allowlist** (§5 Fix B): zero `unitload` rows carry it, and its cited precedent describes a different branch and a different entity.

### Reopened by review 2026-08-18

- **Q4 is REOPENED.** Its clearing of R3 was invalid on three counts (see §11 R3) and one of its two statistics was wrong by five orders of magnitude (see below). The pre-flight query must be re-run over all time, joining on `split_part(tounitload,'-X-',1)`, on at least one **production** tenant, before Fix B is implemented.

### Resolved 2026-08-18 (user decision + measurement)

- **Q1 — extend `isUnitLoadIdValid`, and reword the desktop toast.** Option (a). `canReceiveStock` folds into the probe while the bare `Boolean` response shape is kept, so `wms2-web-ui store/handlingUnits/stockUnits.js:212` is unaffected; the toast at `.../popups/transferStock.vue:144` becomes **"Container is not available to receive stock"**, which is true for both the missing and the unusable case. Adds `wms2-web-ui` to the repo list for a one-line change.
- **Q2 — Fix D (mobile pre-validation) is in this ticket.** The desktop/mobile parity gap is the reason this defect surfaced on handhelds and not on the desktop; leaving it open invites the same report again.
- **Q4 — R3's pre-flight query: run, and it clears the risk.** On WineCo dev and Hydra UAT: `stockrecord` has **zero** rows with `tostoragelocation IN ('Nirwana','Shipped')` in the last 365 days, and **zero** `MANUAL_SPLIT`/`MANUAL_TRANSFER` rows whose destination unit load carries `entity_lock IN (2,104)`. No observed workflow moves stock into a destination Fix B would now refuse, so the guard keeps its full breadth rather than being narrowed to To-Delete + Nirvana. ⚠ **CORRECTED 2026-08-18 — this row's evidence was wrong and R3 is NOT cleared.** The original parenthetical claimed "210,167 at Nirwana with `entity_lock=0` that do carry stock". **The true figure is 1.** The query used `count(*)` over a `LEFT JOIN stockunit`, which counts (unit-load, stock-unit) *pairs*, not unit loads. Re-measured with `count(DISTINCT u.id)` on `wms2-wineco-dev`: Nirwana/`entity_lock=2` = 320,637 ULs (0 stock); Nirwana/`entity_lock=0` = **1** UL carrying 210,167 stock-unit rows; Shipped/`entity_lock=405` = **411,862** ULs (not the 1,408,552 the same bad query reported). All three reviewers flagged this independently. See §14 for why R3's clearing must be redone rather than reworded.

### Resolved during analysis

- **Operator-input vs internal-reference is the split rule**, not "all `EntityNotFoundException` in this method". §5.4. Prevents the blanket conversion that would make an FK corruption read as a scan mistake.
- **Keyed `BusinessException`, not the 1-arg form**, despite `MobileMoveUnitloadService` using the 1-arg form — so tests can assert `getKey()` (`BusinessException.java:42-47, 133-144`).
- **New keys go in both bundles**, base included, because nothing pins the JVM default locale.
- **`bulkTransferStock` is the correct one; `transferStock` is the outlier.** Fix C converges on the sibling rather than inventing a third convention.
- **This is not a regression from the Phase-5 null-safety sweep.** Pre-sweep it was `NoSuchElementException` → 500 → the same toast. §3.
- **No data was corrupted by the reported incident.** Verified by SQL (§1.3) and pinned by a test (§8.1).
- **No integration test.** The v2 Testcontainers lane cannot boot (SBDEV-2217). §8.5.

---

## 13. Implementation Status

### Merged and migrated — 2026-08-19

All three PRs merged into `develop` in the required order: **wms2-web-ui #67 `99e2359` → wms2-api #167 `6135203` → wms2-mobile-ui #36 `7f83d55`**. Web-first was honoured for the reason §8 gives — API-first would have left the desktop telling operators that 411,862 truthful Shipped containers "do not exist" for the whole inter-deploy window.

`V2.2.17` was re-swept against **every remote branch** immediately before the merge (not `ls db/migration/`): claimed only by this PR's branch, `develop` was at `V2.2.16`. No collision.

**Flyway `V2.2.17` is applied to WineCo dev (`dev_wh01_om1`)** — `flyway_schema_history` shows `2.2.17` `success=true` at 2026-08-19 21:46:59; exactly **one** `los_sysprop` row for `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` (the `WHERE NOT EXISTS` idempotency held); `sysvalue = 'false'`; `description` 227 chars, under the `varchar(255)` ceiling that aborts with `22001`.

Static exposure on that tenant, re-measured post-merge, matches this plan exactly: **411,862** unit loads at Shipped, 320,638 at Nirwana, 320,642 locked.

⚠ **R3 is unchanged and still blocks enablement.** Shadow mode is now live on WineCo dev. To clear R3 for a tenant: run one operating cycle, then grep for `SBDEV-2994 shadow: would have refused destination … reason=Shipped` — matching `reason=Shipped`, **not** `reason=already shipped` (the lock branch fires first and words it differently). Zero lines over a full cycle is the clearing condition. The Nirvana-sentinel refusal is ungated by design and is live on deploy.

**Not verified as deployed.** The migration being applied does not by itself establish that the application image carrying these commits is running on dev. Other tenants stay unpatched until the app boots against them (`StartupFlywayMigrator` runs Flyway per **active** tenant every boot). `wms2-hydra-dev2` is an **inactive** tenant with no `flyway_schema_history` at all — expected for an inactive DB, not a stalled chain, and not a gap to chase.

**Implemented 2026-08-19.** Three repos, one commit each, all off `origin/develop` in per-ticket worktrees.

| Repo | Branch | Commit | Base | PR |
|---|---|---|---|---|
| `v2/wms2-web-ui` | `feature/SBDEV-2994-move-stock-unknown-destination-container` | `860de0e` | `d4f71c1` | [#67](https://github.com/SiteBossInc/wms2-web-ui/pull/67) — **merge 1st** |
| `v2/wms2-api` | same | `3abb1f22` | `d2bedc02` | [#167](https://github.com/SiteBossInc/wms2-api/pull/167) — merge 2nd |
| `v2/wms2-mobile-ui` | same | `6b4531b` | `8e623b8` | [#36](https://github.com/SiteBossInc/wms2-mobile-ui/pull/36) — merge 3rd |

⚠ **Merge/deploy order is web → api → mobile** (§7.1). PRs must not be merged in any other order.

### Results

| Gate | Result |
|---|---|
| `mvn -o clean compile` | BUILD SUCCESS (full clean, not incremental — catches DI/signature drift) |
| Targeted API tests (5 classes) | **153 pass, 0 fail** |
| Full API suite | **5172 run, 2 failures, 0 errors, 67 skipped** — `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` (6 violations, **none in SBDEV-2994 files**; Fix A4 *reduced* the count by one) and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`. Both confirmed pre-existing by an independent verifier lane that ran them on a throwaway detached worktree at `origin/develop` `d2bedc02` |
| Mobile Jest | **156 pass, 0 fail** (10 suites) |
| Verify script | **`Result: 55 pass, 0 fail, 0 skip`** (`RUN_MVN=1`, all three roots at the worktrees) |

### Test classes

- **`unit/service/StockunitServiceTransferStockDestinationTest`** (new, 11) — Fix A both sites; the
  internal-lookup split pin; `EligibilityIsConsulted` (refusal propagates, no stock moved, and an
  `InOrder` proof the gate runs *before* the pallet-type lookup and before `transferStockToUnitLoad`);
  `MessageBundles` (both bundles, UTF-8 `Reader`, `%1$s`/`%2$s` interpolation, non-fallback rendering).
- **`unit/service/DestinationEligibilityServiceUnitTest`** (new, 18) — the rule against the real
  implementation: gate ON refusals, both shadow-mode pass-throughs **with the WARN asserted**, the
  absent-sysprop fail-safe, `nirvanaSentinel_gateOff_STILL_throws`,
  `nirvanaSentinel_doesNotConsultTheGate` (asserts the *absence* of the sysprop read), and the PM-1
  totality set incl. `canReceiveStock_nullEntityLock_returnsFalseWithoutThrowing`.
- **`unit/controller/StockUnitControllerUnitTest`** (+6) — Fix C 200/`field=="Runtime Error"`, no-leak,
  ERROR-log emission, bulk parity, bulk loop-continuation, and `entityNotFoundStillMapsTo404_onTheUnnettedPath`
  (a second MockMvc *with* `RestExceptionHandler` — the only automated proof the advice mapping is real).
- **`test/components/move-stock-destination-probe.spec.js`** (new, 8) — Fix D blocking, fail-OPEN at both
  layers, `new`-mode non-probe, plus the re-entry and mid-probe-state-clear cases.

### Ablations run

| Ablation | Result |
|---|---|
| Shadow `LOG.warn` deleted | ✅ 3 eligibility tests fail; verify `B14` fails |
| Mobile re-entry guard removed | ✅ the double-dispatch test fails |
| Mobile state snapshot removed | ✅ the mid-probe-clear test fails |

⚠ **One of my own tests was vacuous and was fixed.** The mid-probe-clear case originally committed
`moveStock/initialize`, which the spec's mount factory stubs as a **no-op**, so it passed with and without
the snapshot. It now clears the state directly.

### Deviations from this plan, all deliberate

1. **§5 Fix B's `getBoolean`** does not exist — see the correction in §5 above.
2. **§8.1's `canReceiveStock_*`/`assertCanReceiveStock_*` rows moved** to their own class so the rule is
   asserted against the real implementation rather than a mocked collaborator (which would have been
   `doThrow` → `assertThrows`, a tautology). Both review lanes judged the move a strengthening. All 16
   §8.1 behaviours survive; the shadow-WARN assertion was the one initially lost and is now restored plus
   pinned by new verify rows `B14`/`T9`.
3. **§8.3's predicted breakage was misdiagnosed.** `StockunitServiceUnitTest` broke because the class had
   no `@Mock` for the new collaborator (all **4** tests in `TransferStockToExistingContainer`), not from an
   unstubbed `locationRepository.findById(10L)` — that lookup now lives behind the extracted service, so
   the predicted mechanism cannot occur.
4. **§8.4's claim that `test/pages/workflow-reset-on-entry.spec.js` drives `submit()` is false.** It
   imports the component but never calls `submit()`; it needed no change and stays green.
5. **Fix C's catch is placed after the existing two**, as §5 Fix C prescribes. Placing it first made
   verify `C3` fail, because its from-here-to-end slice then swallowed the pre-existing legitimate
   `e.getMessage()` in the `BusinessException` catch.
6. **One commit per repo** rather than per-fix. Fixes A/B/C interlock across the same files; each repo's
   commit is atomic and revertable as a unit.

### Verify-script changes made during implementation

`B14` (shadow WARN present in `assertCanReceiveStock`'s non-enforcing branch) and `T9` (a test observes
it) were **added** — both review lanes independently found that deleting the WARN scored 153/153 and
53/53. Baseline moved 53 → 55 rows. ⚠ `B14` was a **false RED on its first run**: it anchored on the
sysprop constant, which appears only inside the private `enforcing()` helper defined *after* both entry
points, so the slice captured the wrong method. Re-anchored on the method signature and re-tested in three
directions (correct → PASS, pre-fix replay → FAIL, ablated → FAIL).

⚠ **`B13` is weaker than it reads.** It slices `assertCanReceiveStock` → the sysprop constant and requires
Nirvana to appear first; because the gate is read via `enforcing()` rather than inline, that slice now spans
past `canReceiveStock` too. The *behaviour* is pinned properly by `nirvanaSentinel_doesNotConsultTheGate`.

### Landmines found that this plan did not predict

- **`OptionalSafetyArchTest` (SBDEV-2116) forbids `Optional.get()` anywhere under
  `net.aim_ai.wms.service`, which collides with verify row `B8`.** `B8` explicitly blesses the idiomatic
  `isPresent()` + `get()` form for the total predicate; using it added a 7th arch violation. Resolved with
  `orElse(null)`, which satisfies both. Anyone writing a total predicate in a service package hits this.
- **`SyspropMigrationDescriptionWidthTest`** already enforces the `varchar(255)` limit the plan warns
  about in prose — the guard exists, no new one needed.
- The Flyway sweep across all 130 remote branches confirmed `V2.2.16` as the high-water mark (a plain
  `ls db/migration/` happened to agree this time), so this ships `V2.2.17`.

### Still open

- **§8.6 manual test plan (M1-M10)** — not executed; requires a WineCo dev session. M9 (dangling-location
  probe) and M10 (Nirvana sentinel) are the two that pin behaviour nothing else covers at runtime.
- **The null/dangling-`storagelocation_id` population is unmeasured.** `canReceiveStock` fails **closed**
  there per §5's explicit contract, and that branch is **outside** the sysprop gate — so at the shipped
  default the desktop will refuse those containers while the server would accept the move. §5's fail-safe
  claim ("an un-seeded tenant behaves exactly as today") does not hold for this class of row. The Shipped
  population was measured to the unit; this one was not. Query to run before enabling — or before merge if
  the count is feared non-trivial:
  `SELECT count(*) FROM unitload u LEFT JOIN location l ON l.id = u.storagelocation_id WHERE u.storagelocation_id IS NULL OR l.id IS NULL;`
  Changing the fail-closed contract would contradict §5 and break pinned rows `B8`/`B8b`, so it is left as
  an owner decision rather than silently redesigned.
- **R3 enablement** — unchanged: ship with the sysprop `false`, read the shadow WARN count per tenant over
  one operating cycle, enable where it is zero.

---

## 14. ralplan consensus review — 2026-08-18

Three independent lanes (Planner / Architect / Critic, opus, deliberate mode) reviewed this draft.
Architect and Critic each saw the same fixed snapshot; neither received the other's output. Full
reports are preserved verbatim at `reviews/SBDEV-2994-review-{planner,architect,critic}.md`.

**Critic verdict: ITERATE.** 22 must-fix items. The plan is **not TDD-gate-ready.**

### 14.1 Findings two or three lanes reached independently

Convergence across lanes that could not see each other is the strongest signal here.

| # | Finding | Lanes | Sev |
|---|---|---|---|
| C1 | **`MobileMoveStockService.selectDestination` (`:235`, via `MoveStockController:96` `POST /v3/moveStock/scanDestination`) is a second, complete, correctly-guarded implementation of this exact screen — and is missing from §0.** Its controller catches only `BusinessException`/`FacadeException`, so it is also a *second unfixed instance of this very defect*, with ~15 `EntityNotFoundException` sites. It is a **third** convention (unknown-but-well-formed label → auto-create at Clearing). §0's grep was scoped to two URL fragments and structurally could not find it. | Architect, Critic | **High** |
| C2 | **Fix C routes raw engineer-only text to the operator.** `errors.add(getErrorMessage("Entity Not Found", e.getMessage()))` puts `"Location not found with id: 3421"` on a handheld — for the 11 sites §0.1 itself classifies as "the operator can do nothing." Contradicts P1/P4 and §5 Fix A's own argument against C-alone. | Architect (V3), Critic (M3) | **High** |
| C3 | **R3 is not cleared.** Three separate defects: `entity_lock=104` has **zero rows tenant-wide**, so the ON_HOLD half *cannot fail*; the join `sr.tounitload = unitload.labelid` drops the `-X-` mangled population the plan is about (66% of `MANUAL_*` records match no current label); and all-time hits are **958**, most recent **2025-04-23** — the 365-day window starts just after the last occurrence. Production was never measured. | Planner, Architect, Critic | **High** |
| C4 | **§12 Q4's "210,167 at Nirwana with `entity_lock=0`" is wrong; the true value is 1.** `count(*)` over a `LEFT JOIN` counted pairs, not unit loads. Corrected in §12. | Architect, Critic | **High** |
| C5 | **Fix A silently changes `bulkTransferStock`.** Its `catch` at `:163-167` is *outside* the `for` loop: today a dead label aborts the batch with 1 error; after Fix A the inner catch takes it and the loop continues with N errors. §0.2 row 15, M6 and §12 each assert the opposite. | Planner (G6), Architect (0.4) | **Medium** |
| C6 | **§8.2's controller test cannot observe the status contract.** `BaseControllerUnitTest:49-57` uses `standaloneSetup` with no `.setControllerAdvice(...)`, so `RestExceptionHandler` is absent from the unit lane too — D1 is worse than §8.5 states. | Planner, Architect (V7), Critic | **Medium** |
| C7 | **Fix B breaks currently-green tests the plan never lists**, incl. `StockUnitControllerUnitTest.returnsTrueWhenUnitloadExists` (`:1030-1044`) and two `StockunitServiceUnitTest` cases missing a `locationRepository.findById` stub. §6 mis-attributes the breakage to "the new throw types". | Planner (G1), Critic (M9) | **Medium** |
| C8 | **"`orElseThrow` cannot throw a checked exception from a lambda" is false** — 34 counter-examples in-repo. Corrected in §5. | Planner (G2), Critic (M12) | **Medium** |
| C9 | **Option 4 (a ~4-line `backendMsg` extraction in `store/moveStock.js`) was never priced** — it was conflated with Fix E's "~18 modules". The server already sends the string in `ProblemDetail.detail`. `store/cancellation.js:44-48` already implements the helper. | Planner, Architect, Critic | **High** |
| C10 | **Verify rows pass on wrong implementations.** The Critic built a wrong-implementation tree and demonstrated **A3, B3, C1, T2, T3 all PASS**. Notably B3: `GOING_TO_DELETE` already appears at `:368/:421/:465/:514`, so a guard omitting To-Delete entirely goes green. | all three | **High** |

### 14.2 Single-lane findings that change the design

- **Architect — live data-loss path, unreported and outside this ticket's scope.** Unit load `labelid='Nirwana'` exists with `entity_lock=0` at the Nirwana location on **both** tenants measured (WineCo dev id 66252 holding 210,167 stock-unit rows; Hydra UAT id 51151). `findByLabelid('Nirwana')` resolves it and no lock check fires, so `transferStock` will move stock onto it and the stock is effectively gone. `MobileMoveStockService:320-324` and `MobileMoveUnitloadService:122` both guard this; `transferStock` does not. **File separately.**
- **Architect — the prescribed deploy order manufactures the untruth §12 Q1 exists to prevent.** API-first makes the probe reject 411,862 existing Shipped containers while the desktop still says "Container does not exist." Correct order is **web-ui first**, then api, then mobile.
- **Architect — the observability fix belongs one layer up.** `RestExceptionHandler:155` logs `EntityNotFoundException` at **`LOG.debug`**, i.e. invisible everywhere. A one-line `debug`→`warn` buys for all 61 controllers what Fix C's `LOG.error` buys for one.
- **Critic — §8.2 named a JSON field that does not exist** (`errors[0].type`; the key is `field`). Corrected in §5/§8.2.
- **Critic — a 14th unchecked site Fix C does not net:** `StockunitService:169` `defaultUnitLoadType.get()` → `NoSuchElementException` → **500**, inside the reported existing-container pallet branch.
- **Critic — `mvn_test_passes` can only ever be red**: `-q` suppresses the INFO lines it greps for, and a missing `mvn` records as a plain FAIL.
- **Critic — §0.1 row 13 is wrong**: the web popup has a Print Label switch (`transferStock.vue:43`), so the `printLabel` block and its three further sites *are* reachable in production.
- **Critic — P3 unargued:** `entityNotFoundForId` / `entityNotFoundForName` already exist (`messages_en_US.properties:314-315`, 34 uses). Diverging is defensible; not mentioning them is not.

### 14.3 Status

Items C1-C4, C9, C10 plus the Critic's M2/M5/M7 are prerequisites for the TDD gate. The gate is
**held**. The review also establishes that this ticket, as scoped, is really three or four pieces of
work; §14.2's data-loss path and the second unfixed endpoint (C1) each want their own ticket.

---

## 14.4 Consensus iteration 2 — 2026-08-18

Architect and Critic re-reviewed the revision independently (neither saw the other's output).
Reports: `reviews/SBDEV-2994-review-{architect,critic}-i2.md`.

**Architect: PARTIALLY DISCHARGED** — "one focused revision away, not another round."
**Critic: ITERATE** — 19 of 22 iteration-1 items discharged; 21 new findings, most in the script.

### 14.4.1 The finding that matters most

⚠ **The verify script was still certifying wrong implementations, and my report of its validation
was overstated.** §8.7 originally said it was "validated in BOTH directions". That was true and
insufficient: **one** wrong implementation had been tested and the result generalised. Both reviewers
independently built families of near-miss wrong shadows:

- Architect: 6 mutations, **all 6 scored `42 pass, 0 fail`** — identical to correct.
- Critic: 7 mutations, **4 scored identically to correct**, including an **empty stub** of
  `DestinationEligibilityService` whose branch names existed only inside `// TODO:` comments.

Root causes, all now fixed: rows grepping *prose* rather than code; bare negations over constructs
that do not exist yet; a line-count that included the plan's own prescribed comment; a leak check
defeated by assigning to an intermediate variable.

### 14.4.2 My own defects found in this iteration

| # | Defect | How it was caught |
|---|---|---|
| 1 | 🔴 **`B12`/`B13` were wired into the runner but NEVER DEFINED** — bash 127, recorded as an ordinary FAIL, so `0 fail` was unreachable and the sysprop gate + ungated-Nirvana invariant had **zero** verification. A shadow that gated the Nirvana refusal — leaving SBDEV-2995's data loss open — scored identical to correct. Cause: an edit aborted on an assertion **before** the write, so only the `run` lines landed | Critic |
| 2 | `B8` was unsatisfiable — `method_slice` compiled `/s` without `/m`, so a `^`-anchored end never matched and the slice was always empty | Critic |
| 3 | `B8` also **banned idiomatic correct code** (`isPresent()` + `.get()`), rejecting valid implementations | Critic |
| 4 | `A3` counted **comment lines**, and §5 Fix A prescribes a comment containing the literal token — one free wrong conversion | Critic |
| 5 | `C3` was defeated by `String detail = e.getMessage();` — the High-rated leak still shippable under a green script | Critic |
| 6 | `A4` was VACUOUS at baseline — the construct it asserted already exists at `:225` | my own positive test |
| 7 | `B8`'s end-anchor alternation bound at **top level**, splitting the whole regex so `$1` came back empty — red against a correct implementation | my own positive test |

Defects 6 and 7 were invisible to both reviewers and to red-only baselining; only running the script
against a **correct** shadow exposed them.

### 14.4.3 Method, corrected for the third time

Red-only baselining catches nothing here. One correct shadow catches false-REDs. **Only a family of
near-miss WRONG shadows catches false-GREENs — and a false-green is the one that ships the defect.**
Both are now mandatory for any verify script in this vault.

Current baseline: **4 pass / 41 fail / 1 skip**, four parity pins green, `B8` and `B13` confirmed to
discriminate in both directions.

### 14.4.4 Open — carried into iteration 3

**Needs a human, not another review round:**
- **R3** — the corrected pre-flight query (all time, `split_part(tounitload,'-X-',1)`, on a
  **production** tenant). Owner unassigned. Blocks Fix B.
- **§12 Q5** — the product decision on SBDEV-2996: does an unknown well-formed label mean *create* or
  *reject*? Gates Fix D.

**Plan-document consistency (Critic N6-N21), none design-level:** the gate's promised §8.1 tests and
shadow-mode logging were claimed but never written (N6, N8); R3-vs-gate status unreconciled (N7);
Fix A's code shape specified three ways (N9); `%2$s` undefined for the ungated Nirvana branch (N11);
§6 omits the Flyway seed migration (N12); §7.2 prints step 4a after step 5 (N13); §14 has no
discharge column (N14); §12 Q3 still says "~18" (N18); the third message-key constant is named only
in the script (N21).

---

## 14.5 Iteration-2 discharge — 2026-08-18

All of the Critic's N6-N21 applied. Status per item:

| # | Finding | Status |
|---|---|---|
| N1 | `B12`/`B13` invoked but never defined | **FIXED** — defined; both verified to discriminate |
| N2 | `B8` unsatisfiable (`/s` without `/m`) and banned idiomatic correct code | **FIXED** — plus a top-level alternation bug found by positive testing |
| N3 | Whole Fix B surface passed on an empty stub with `// TODO` comments | **FIXED** — new `code_only` helper; all B-rows read code, not prose |
| N4 | `A3` counted comment lines, incl. the plan's own prescribed comment | **FIXED** — counts code only |
| N5 | `C3` defeated by `String detail = e.getMessage();` | **FIXED** — forbids any reference to the exception's message in the catch; re-verified |
| N6 | Gate tests promised in §5, never written in §8.1 | **FIXED** — 5 new rows, incl. `..._nirvanaSentinel_gateOff_STILL_throws` |
| N7 | R3 vs the gate unreconciled | **FIXED** — R3 re-scoped: the gate unblocks *implementation*, R3 blocks *enablement* |
| N8 | "Shadow mode" named as the mitigation, never designed | **FIXED** — designed as log-and-allow, which makes R3 **self-clearing per tenant** |
| N9 | Fix A's code shape specified three ways | **FIXED** — concise `orElseThrow` everywhere |
| N10 | Fix D's two acceptance criteria had no verify row | **FIXED** — `D5`/`D6`/`D7`; both directions tested |
| N11 | `%2$s` undefined for the ungated Nirvana branch | **FIXED** — reason token defined per branch |
| N12 | §6 omitted the Flyway seed migration | **FIXED** |
| N13 | §7.2 printed step 4a after step 5 | **FIXED** — renumbered 3a |
| N14 | §14 had no discharge column | **FIXED** — this table |
| N15 | `A4` a bare negation defeated by a rename | **FIXED** — twice; the first repair was vacuous at baseline |
| N16 | `mvn_test_passes` greened on a class with zero tests | **FIXED** — requires `Tests run: [1-9]` |
| N17 | Script header baseline stale | **FIXED** |
| N18 | §12 Q3 still said "~18 modules" | **FIXED** — 42+ |
| N19 | Split tickets unverified | **FIXED** — SBDEV-2995 / SBDEV-2996 linked with ids |
| N20 | Default-OFF gate makes the toast reword a small regression | **ACCEPTED** — documented, with the reason not to fix it |
| N21 | Third constant named only in the script | **FIXED** — named in §6 |

### One more defect of my own, found by positive testing

⚠ **`method_slice` was silently broken for four rows.** A comment placed between the env assignments
and `perl` sat on a backslash-continuation line:

```bash
VW_START="$start" VW_END="$end" \
  # comment
  perl -0777 ...
```

The continuation swallowed the comment, so the assignments became their own command and `perl` ran
with `VW_START`/`VW_END` **unset** — the regex degenerated to `/(.*?)/`, matched empty at offset 0,
and **C2, C3, C4 and D3 all went red against a correct implementation.** Red-only baselining could
not see it; the rows were *supposed* to be red. Only running a correct shadow exposed it. Now fixed,
with a warning comment placed where the next author will trip over it.

### Verification state

| Direction | Result |
|---|---|
| unfixed `origin/develop` | **4 pass / 44 fail / 1 skip** — only the four parity pins |
| correct shadows | `B1`-`B9`, `B13`, `C1`-`C4`, `D1`-`D7` green |
| near-miss wrong shadows | empty-stub → B4/B5/B6/B9/B12/B13 red; throwing predicate → B8 red; non-logging catch → C2 red; intermediate-variable leak → C3 red; fail-closed probe + generic toast → D5/D6 red |

### Remaining

- **§12 Q5** — ⚠ **downgraded 2026-08-18 from blocking to confirm-and-close.** Measured across three tenants and ~4.1M unit-load records: the `SU-######` create-on-scan path has **never been used**, and the reported incident would have been rejected by both designs anyway. Hard rejection stands; **Fix D ships as designed and is no longer held.** Residual: one production query (`SELECT count(*) FROM unitload_record WHERE label ~ '^SU-'`) and a yes/no from Zeshan.
- **R3 enablement** — after Fix B deploys with the sysprop `false`, read the shadow `WARN` count per tenant over one operating cycle before enforcing.
