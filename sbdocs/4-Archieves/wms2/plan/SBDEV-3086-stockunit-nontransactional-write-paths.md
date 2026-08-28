---
title: "WMSv2 StockunitService non-transactional write paths"
ticket: "SBDEV-3086"
ticket_url: "https://app.clickup.com/t/868kwj9dt"
type: bug
priority: normal
status: archived
project: [wms2]
version: v2
requester: audit-driven
created: 2026-08-25
updated: 2026-08-26
db_verified: true
related:
  - ../../../3-Resources/design/wms2-stockunit-design.md
  - ../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
  - ../../../3-Resources/architecture/wms2-oms-integration-map.md
  - ../../../9-System/mutation-testing-recipe.md
  - ../../../1-Projects/wms2/plan/SBDEV-2994-move-stock-unknown-destination-container-generic-error.md
tags:
  - plan
  - bug
  - transactions
  - inventory
  - oms-notification
---

> **Archived 2026-08-26.** Merged (`206ad9ed` wms2-api #198, `d3fb6ac` wms2-web-ui #79,
> `98060c99` wms2-api #203), deployed to dev, and live-verified — see §10.
> No acceptance script existed for this plan, by design (§9.3), so none was retired.
> Implementation worktrees removed 2026-08-26: `wms2-api/SBDEV-3086`,
> `wms2-api/SBDEV-3086-field-fix`, `wms2-web-ui/SBDEV-3086` — all gates passed.
> Findings disposition recorded in §10; landmines #1/#2 went to **SBDEV-3091**.

# WMSv2: non-transactional write paths in `StockunitService`

**Ticket:** [SBDEV-3086](https://app.clickup.com/t/868kwj9dt)
**Project:** wms2 | **Version:** v2 | **Type:** bug
**Priority:** normal — see §1.3, exposure is measured at essentially zero
**Status:** pending approval
**Date:** 2026-08-25

**Base:** `v2/wms2-api` `origin/develop` @ `353a3484`; `v2/wms2-web-ui` @ `99e2359`; `v2/wms2-mobile-ui` @ `98eae72`. Every `file:line` below was read with `git show origin/develop:<path>` at that commit, or from the web-UI working tree at that commit.

> **Tier: T3.** Deciding factor is *data integrity on a stock-lock write path*, not urgency — the ClickUp priority is `normal` and the measured exposure (§1.3) is nil. The router routes on execution risk.

> **Framing.** This is **hygiene-class correctness**, in the same class as SBDEV-3085. The mechanisms are real and reachable in code; the residue has **never been observed** in any tenant DB (§1.3). Nothing is on fire. The value is closing four windows before a tenant starts using the feature at volume, and making the bulk endpoints tell the operator the truth.

**Where the skill-mandated sections live.** This plan keeps its own §0-§9 numbering; the sections `wms-bugfix-plan/SKILL.md:269-301` requires map as follows. *Problem Statement* → §1. *Root Cause Analysis* → §2. **Architecture Overview → §1.4.** *Fix Design* → §3. **File Change Summary → §3.7.** *Implementation Steps + Prerequisites* → §5. *Testing Plan + Manual test plan* → §6 / §6.4. **Risks & Mitigations → §8.1.** **Completeness checklist → §9.5.**

---

## Corrections carried in

Everything in this table contradicts either the ticket text, the triage note, or one of the three analysis lanes. **C1, C2, C7, C9 and C13 will each cause a wrong implementation if lost** — C13 demonstrably did, post-merge, and C7 is the row it corrects: read the two together.

| # | Claim as written | Verified reality @ `353a3484` |
|---|---|---|
| **C1** | "Neither `Stockunit` nor `Unitload` declares `@Version`, so there is no optimistic locking" | **Wrong — it is inherited.** `@Version private Integer version` is on the `@MappedSuperclass` at `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java:34-35` (`@MappedSuperclass` at `:15`); `model/Stockunit.java:9` and `model/Unitload.java:8` both `extends AbstractBaseEntity`. Optimistic locking **is** active. With OSIV off (`application.properties:55`) the `save` at `StockunitService:454` runs on a **detached** entity → Hibernate `merge` → `OptimisticLockException` is possible there. Any concurrency assertion must tolerate `ObjectOptimisticLockingFailureException`. Note the file lives under `model/`, not `entity/` |
| **C2** | Endpoint `bulkSetLockDamaged` | **Does not exist.** The real endpoint is `POST /v3/stockUnit/bulkTransferToDamaged` (`StockUnitController:539`), which calls the *service* method `setLockDamaged` (`:564`) and is gated by `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` (`:538`). The synthesized name came from mixing the service call with the gate name |
| **C3** | "Both UIs need changes" | **`wms2-mobile-ui` has zero consumers** — 0 hits for every spelling of the three endpoints; its only `bulk` hits are palletizing scans. `omsv2-UI` also 0. **`wms2-web-ui` only.** Do not open a mobile worktree |
| **C4** | Deferral is `MessageService:109 → OmsNotificationService` | Three hops, all verified: `MessageService.sendStockChangeMessage:109` → `StockChangeNotificationService.sendAfterCommit:34` → `OmsNotificationService.sendAfterCommit:52`; the "is a tx actually open" guard is `:68-69`, the **synchronous** fallback branch is `:88` |
| **C5** | The ticket's line numbers | All stale by ~23-29 lines — SBDEV-3085 (PR #196) merged mid-triage. Current: `setLockDamaged:413`, `adjustAmount:471`, `removeLock:548`; the already-transactional siblings are `transferStock:156-157`, `setLockOnHold:347-348`, `adjustReservedAmount:516-517` |
| **C6** | Baseline reds are `OptimisticLockSafetyArchTest` | **No such class exists.** The two develop baseline reds are `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate` (clearing them is SBDEV-3089). Neither is in this plan's PIT scope, so PIT runs today without waiting on 3089 |
| **C7** | `getErrorMessage` emits `{name, message}` | **Wrong — it emits `{field, message}`** (`AdminController.java:286-291`, inherited; `StockUnitController extends AdminController` at `:30`). Two consequences: `util/commonUtility.js:11`'s `${errors[i].field}` template is **already correct** and needs no fix, and `StockUnitControllerUnitTest:515` asserting `$.errors[0].field` is consistent with the real shape. The per-item change is to **add an `id` key**, not to rename anything |
| **C8** | All three store actions dispatch `searchStockUnit` only in the `else` | True for `bulkLock` (`stockUnits.js:242`) and `bulkUnlock` (`:259`). **False for `bulkTransferToDamaged`** — its dispatch at `:336` is already outside the `if/else`. The re-dispatch fix applies to **two** actions, not three |
| **C9** | `StockUnitControllerUnitTest:720` breaks under F5 | **It does not**, because it exercises `POST /v3/stockUnit/bulkAdjustAmount` (`:732`) and D4 keeps that endpoint out of scope. Verified: the three in-scope error tests all submit a **single** id — `:966`, `:1106`, `:1199` all `ids = "100"` — so moving the try inside the loop changes nothing for them. **Under D4 scope, F5 breaks zero existing controller tests.** The `EntityNotFoundException` catch is still required, for correctness rather than as a test mitigation (§2.5) |
| **C10** | "Prove F1 by PIT mutation on the annotation" | PIT's operators mutate **method bodies / bytecode instructions**. They do not add or remove annotations and do not change method visibility, so the F1 annotation/visibility mutants cannot be produced by the PIT engine. Proof by mutation is preserved — but mutants 1, 2 and 3 must be **hand-applied source edits, recompiled**, per `sbdocs/9-System/mutation-testing-recipe.md`. PIT itself is still run, scoped, over the new helper's body. See §9.2 |
| **C11** | "No integration test runs at all, so F1 cannot be proven by rollback test" | **Half right, and the wrong half was load-bearing.** The 28 `*IT.java` classes *are* dead — failsafe's `<includes>` at `pom.xml:611-614` overrides its `**/*IT.java` default, and surefire's patterns do not match them either. But **40 files match that same `<includes>`** — 39 `*IntegrationTest.java` + 1 `*E2ETest.java` — of which **30 are not `@Disabled`** and therefore run: failsafe is bound to `integration-test` + `verify` at `pom.xml:624-631`. Surefire *excludes* them at `pom.xml:494-497`, so they run under **`mvn verify` only, not `mvn test`**. And `src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java` exists, is not `@Disabled`, and its javadoc states it *"Intentionally omits @Transactional so that service @Transactional boundaries are real: each test method can observe whether a rollback actually occurred"* (`:15-19`). Three live precedents: `integration/service/AdviceServiceRollbackIntegrationTest`, `integration/CancelOrderRollbackIntegrationTest`, `integration/SkuRestControllerAtomicityIntegrationTest`. → **D6** adds a rollback IT for F1 |

| **C12** | Web-UI citations against `99e2359` | **Stale — `wms2-web-ui` `origin/develop` moved to `c82661b` during review** (SBDEV-3085's UI PR #77 landed; `store/handlingUnits/stockUnits.js` grew 166 lines). Every finding still holds, re-verified on `c82661b`, but the lines moved: `bulkLock` **:349** (POST `:351`, guard `:353`, dispatch `:358` **inside** the `else`), `bulkUnlock` **:374** (`:376`/`:378`/`:383`, also inside), `bulkTransferToDamaged` **:474** (`:476`/`:478`, dispatch **:484 outside** the `if/else` — C8 confirmed on the new base). New since the analysis: SBDEV-2967-C added an `if (isAuthzDenial(error)) return` early-exit to all three `catch` blocks, so the Jest specs must not treat the catch as one generic path. ⚠ `if (results.errors)` now appears **14×** in this file — only our three return the new shape, but the idiom is shared, so anyone applying `{requested, succeeded, errors}` elsewhere hits the same `[]`-is-truthy trap D7 exists to avoid |

| **C13** *(added 2026-08-26, post-merge)* | C7's "the per-item change is to **add an `id` key**, not to rename anything", plus §3.5's snippet showing the plain two-arg `getErrorMessage(field, message)` | **Incomplete — §3.6 D8 superseded both, and what shipped folds the id into `field` too.** `StockUnitController:716` is `getErrorMessage(field + " (id " + id + ")", message)`, so a failure renders `Invalid ID Format (id abc)` and the id appears in **two** places. Both are load-bearing for **different** consumers: `errors[].id` is read programmatically by `failedIdsFrom()` (`wms2-web-ui store/handlingUnits/stockUnits.js:126`) to narrow the grid to failed rows — load-bearing because `setLockDamaged` is not idempotent (§7 row 6) — while `errors[].field` is what the **operator** reads, since `util/commonUtility.js:11` renders `` `${field}: ${message}` `` and knows nothing about `id`. **Do not "clean up" the interpolation.** Deleting it leaves the entire Java suite green while degrading every failure toast to an unattributable message. Measured: reading C7 + §3.5 alone I concluded the fold was an accidental deviation and had a one-line deletion PR ready before checking the web-ui side. Regression pin now exists — `StockUnitControllerUnitTest.bulkSetLockOnHold_failingId_isFoldedIntoField` (PR #203), mutation-checked so exactly that deletion fails exactly that test and no other |

Two further mechanical facts, in no lane report: **`StockunitService` does not inject `BasicService`** (field list `:23-76`), so D3's pre-minted label cannot call `basicService.generateNumber` directly without a new DI edge — §3.1 uses a one-line accessor on `UnitloadService` instead, keeping D1's zero-new-injections property. And **`StockunitBusinessService:417-428` is not the source-lock guard**; that guard is `:294-298`, while `:417-428` sits inside `sendToNirvana`/`changeAmount`. D2's substance holds; the citation is corrected in §2.1.

---

## §0 — Affected sites, and what is deliberately left alone

Four anti-patterns were enumerated exhaustively across `src/main`. This plan takes 5 sites and names every sibling it does not take.

| Pattern | In scope | Out of scope (same shape, named so nobody re-derives it) |
|---|---|---|
| **Notify before the persisting write** | **F3** — `removeLock`: `sendStockChangeMessage` at `:567`/`:571`, `stockunitRepository.save` at `:583` | Nothing. There are **15** `sendStockChangeMessage` call sites in `src/main` (a `git grep` returns 16 lines — the 16th is the declaration at `MessageService:109`), and **two** of them are notify-before-save: `:567` and `:571`, both inside `removeLock`. The other 13 read as save-then-send; that was spot-checked on `setLockOnHold:394→:399` and `MobileMoveUnitloadService:572→:575`, not exhaustively verified across all 13 |
| **Print inside / around a transaction** | **F2** — `setLockDamaged`: `printLabel(:463)` runs before `triggerReplenishmentMaintenance(:465)` | `transferStock:343` — `printService.cupsPrint` is the last statement **inside** a `@Transactional` method (`:156`), i.e. network I/O holding a tenant connection. Adjacent, not this ticket's shape (nothing follows it), **out of scope**. ⚠ `HttpInTransactionArchTest`'s rule (method `:55-68`, condition from `:70`) filters on `HttpRestService` at `:75` only, so `cupsPrint` is invisible to it — if anyone later puts `@Transactional` on `setLockDamaged`, `printLabel` becomes a new unguarded violation with no test to catch it |
| **Commit, then validate** | **F4** — `adjustAmount`: `changeAmount(:487)` commits, `default: throw` at `:501-502` | `MobileCycleCountService:377-378` and `:474-475` — identical shape, out of scope |
| **Bulk `try` outside the per-id loop** | **F5** — the lock trio per D4: `bulkSetLockOnHold` (`:467`/`:478`), `bulkTransferToDamaged` (`:539`/`:558`), `bulkRemoveLock` (`:608`/`:618`) | `bulkAdjustAmount:336`, `bulkAdjustReservedAmount:415`, `UnitLoadController:139` — follow-up. **`bulkTransferStock:241` must stay out**: it already has an inner try at `:251`, and `StockUnitControllerUnitTest:498` pins its abort-on-`EntityNotFoundException` per SBDEV-2994 with a comment saying the row fails if someone nets it in |
| **Missing transaction boundary** | **F1** — `setLockDamaged:447-454` | — |

**Response-shape exemplar to copy:** `AdminActionController:275-314` `recoverStuckPallets` — per-item try inside the loop (`for` at `:275`, closing `}` at `:314`), per-item catches, and a response carrying `recoveredIds` / `skipped[{id, reason}]`. F5 diverges from its *shape* deliberately; see §3.5.
**Deferred-print exemplar to copy:** `ReceivingService:598-613` — `TransactionSynchronizationManager.registerSynchronization(afterCommit → cupsPrint)`, with the rationale stated in the comment at `:598-599`.
**Save-then-send exemplars:** `setLockOnHold:394→:399` (same class) and `MobileMoveUnitloadService.removeStockDamaged:572→:575` (the mobile twin of `removeLock`, which gets the ordering right).

---

## §1 — Problem Statement

### 1.1 The four windows

`StockunitService` has six mutating public methods. Three carry `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException, FacadeException})` — `transferStock:156`, `setLockOnHold:347`, `adjustReservedAmount:516`. Three do not: `setLockDamaged:413`, `adjustAmount:471`, `removeLock:548`. Each unannotated method performs multiple writes through repositories that each commit on their own.

1. **Mark-damaged is not atomic** (`setLockDamaged`). Create a UL in `Damaged` → save → transfer stock onto it → mark that stock `QUALITY_FAULT`: four independently committing steps. Failing after the container commits strands an **empty unit load in `Damaged`**; failing after the transfer but before the lock write leaves **damaged stock at `entityLock = NOT_LOCKED`** — allocatable and replenishment-visible. The second window is the worse one.
2. **Release-lock notifies OMS before it writes** (`removeLock`). `sendStockChangeMessage` fires at `:567`/`:571`, the `save` at `:583`. Not being transactional, `OmsNotificationService:68-69` sees no active transaction and takes the **synchronous** branch at `:88`, so the POST goes out immediately. If the save then fails, OMS has been told stock was released that WMS never released.
3. **Amount-edit commits, then reports failure** (`adjustAmount`). `changeAmount(:487)` is itself `@Transactional` (`StockunitBusinessService:428`) and **commits**; the `default:` arm at `:501-502` then throws `"unexpected lock=… found. value not changed"`, which is false. Reachable for `PICKED_FOR_GOODSOUT`(100), `NOT_FOUND`(403) and `TRANSFER`(404) (`WmsConstants:1306-1313`) — only `SHIPPED`(405) and `GOING_TO_DELETE`(2) are pre-rejected at `:476-480`.
4. **A bulk lock write abandons the rest of the batch** (all three trio endpoints). The `try` sits outside the `for`, so the first failing id ends the loop with earlier ids committed and later ids never attempted — and the 200 carries one generic `"Runtime Error"` with **no id**.

### 1.2 What the operator sees

For (4), today's UI shows a single toast built from `errors[0].message` and — for `bulkLock`/`bulkUnlock` — skips the table refresh entirely (`stockUnits.js:242`, `:259` sit inside the `else`), so rows that *did* change keep rendering their pre-write state. The obvious next action is to re-select and re-submit, re-applying the ids that already succeeded. On `bulkTransferToDamaged` that is a **second damaged-stock adjustment**.

### 1.3 Measured exposure — essentially zero

| Probe | `wms2-wineco-dev` | `wms2-hydra` (prd) |
|---|---|---|
| Unit loads in `Damaged` (location id 51627) | 293, **0 empty** — residue *a* absent | **0** |
| Stockunits in `Damaged` with `entity_lock <> 103` | 5 of 293 — all with `modified` 29 s to 925 d after `created` and operator comments → legitimate later unlocks, **not** residue *b* | n/a |
| `stockrecord` | 5,577 `DAMAGED`, 3,146 `MANAGE_INVENTORY` | **0** `DAMAGED` ever, 23 `MANAGE_INVENTORY` |
| `message` `STOCK_UPDATE` | 64,329 `SENT`, 1 `CREATED` (2023), **0 `FAILED`** | n/a |
| Default `INBOUND` printer configured | **Yes** → `printLabel`'s missing-printer `orElseThrow` cannot fire there; CUPS unreachability is the realistic F2 trigger | n/a |

**Verdict: mechanism real, residue never observed, and mark-damaged is unused on the production tenant checked.** This must temper how the ticket is read.

### 1.4 Architecture Overview

```
 wms2-web-ui: stockUnitsTable.vue → popups/lockConfirmation.vue | transferToDamaged
              → store/handlingUnits/stockUnits.js  bulkLock:237 / bulkUnlock:254 / bulkTransferToDamaged:330
              │ POST /v3/stockUnit/bulk{SetLockOnHold,TransferToDamaged,RemoveLock}
 ─────────────▼──────────────────────────────────────────────────────────────────────────
 wms2-api: StockUnitController (extends AdminController:30)
     bulkSetLockOnHold:467 / bulkTransferToDamaged:539 / bulkRemoveLock:608
       └─ F5: the try sits OUTSIDE the for-loop (:477 / :557 / :617)
              → first failure abandons the batch; the 200 body carries no id
     │
     ▼ StockunitService — 6 mutating methods, 3 annotated, 3 not
     ├─ setLockDamaged:413   NOT @Transactional ................... F1 / F2
     │    :443/:446 findByName(Damaged, BOX type)   [stay put]
     │    :447 createUnitload ─┐
     │    :450 save(unitload) ─┤ FOUR independent commits  → F1
     │    :451 transferStockToUnitLoad (own tx) ─┤
     │    :452-454 QUALITY_FAULT + save ────────┘
     │    :461 send   :463 printLabel   :465 triggerReplenishmentMaintenance  → F2 (print first)
     ├─ adjustAmount:471    NOT @Transactional ..................... F4
     │    :487 changeAmount (own tx, COMMITS) → :501 default: throw "value not changed"
     ├─ removeLock:548      NOT @Transactional ..................... F3
     │    :567/:571 send → :583 save    send chain: MessageService:109 →
     │      StockChangeNotificationService:34 → OmsNotificationService:52
     │      (no tx ⇒ SYNCHRONOUS POST at :88)
     └─ transferStock:156 / setLockOnHold:347 / adjustReservedAmount:516 — already annotated

 After F1: setLockDamaged → mintUnitloadLabel()  [outside] → moveStockToNewDamagedContainer(...)
             ╔═ @Transactional(value="tenantTransactionManager", rollbackFor={Business,Facade}) ═╗
             ║ D3 pre-lock location[Damaged] FOR UPDATE → createUnitload(label,…) → save →      ║
             ║ transferStockToUnitLoad → setEntityLock(QUALITY_FAULT) → save                    ║
             ╚═════════════════════════════════════════════════════════════════════════════════╝
```

**Key Files** (paths under `src/main/java/net/aim_ai/wms/` unless noted)

| File | Lines | Role |
|---|---|---|
| `service/StockunitService.java` | `413`, `447-454`, `461-465`, `471`, `486-503`, `548`, `567-583` | The four windows. F1-F4 all land here |
| `service/UnitloadService.java` | `21` (class), `128`, `132`, `136-139`; collaborators `24/26/28/30/40/52/58/62` | Gains the F1 boundary and `mintUnitloadLabel`. Zero `@Transactional` today |
| `service/StockunitBusinessService.java` | `144-146`, `179`, `187-188`, `209`, `240-243`, `245`, `250`, `257`, `290`, `294-298`, `345-347`, `428` | The transfer the boundary wraps; owns the documented resource-**type** lock order D3 now overlays. **Not modified** |
| `controller/StockUnitController.java` | `30`, `466-492`, `538-573`, `607-630` | The lock trio. F5 lands here plus a private `getErrorMessage` overload |
| `controller/AdminController.java` · `repo/jpa/LocationRepository.java` | `286-291` · `51-54`, `56-58` | `getErrorMessage` → `{field, message}` (C7); `findByIdForUpdate`, no lock timeout — the D3 pre-lock. **Neither modified** |
| web-UI `store/handlingUnits/stockUnits.js` | `237-248`, `254-265`, `330-341` | The three consuming actions |
| web-UI `util/commonUtility.js` | `4-16` | `checkResponseError` — the D8 toast surface. Already length-guards (`:6-7`) and already reads `errors[i].field` (`:11`). **Not modified** |

---

## §2 — Root Cause Analysis

### 2.1 F1 — `setLockDamaged` has no transaction boundary

```
:447  Unitload unitLoad = unitloadService.createUnitload(location_damaged, unitLoadType.getId(), stockUnit.getClientId(), CODE_DAMAGED);
:448  Itemdata itemDataForBoxtype = itemdataService.getById(stockUnit.getItemdataId());
:449  unitLoad.setBoxtypeId(itemDataForBoxtype.getDefaultboxtypeId());
:450  unitloadRepository.save(unitLoad);
:451  Stockunit damagedStock = stockunitBusinessService.transferStockToUnitLoad(stockUnit, unitLoad, amount, CODE_DAMAGED, null, comment, false, true);
:452  damagedStock.setEntityLock(QUALITY_FAULT);
:453  damagedStock.setAdditionalcontent(comment);
:454  stockunitRepository.save(damagedStock);
```

`setLockDamaged` is not annotated, so `:447`, `:450` and `:454` each commit alone, and `:451` opens and commits its own transaction (`StockunitBusinessService:187-188`, REQUIRED with no outer tx to join).

**Why the boundary must include `:452-454` (D2).** After `:451` commits, the damaged container holds a stockunit with `entityLock = NOT_LOCKED` on **both** branches: the split/merge branch creates the destination SU through `createStockUnit` → `createStockUnitCore`, which sets the lock to 0 (`StockunitBusinessService:144-146`); the full-move branch (`:345-347`) moves the *source* SU, whose lock the guard at `:294-298` **required** to be `NOT_LOCKED`. Unlocked stock is allocatable and replenishment-visible, so a crash between `:451` and `:454` leaves **pickable damaged stock**. Including `:452-454` also keeps the entity **managed**, turning the `:454` `save` into a flush and closing the detached-`merge` `OptimisticLockException` window C1 exposes.

**Why the precedent settles the design.** `transferStock:156-157` already runs exactly this sequence — `createUnitload(:261)` → `transferStockToUnitLoad(:276)` → `setEntityLock(QUALITY_FAULT)(:277)` → `save(:297)` — inside one `tenantTransactionManager` transaction with the same `rollbackFor`, in production. F1 is precedent-conformant, not novel.

**Why the helper cannot live on `StockunitBusinessService`.** It needs `createUnitload`, which only `UnitloadService` has, and `UnitloadService` already constructor-injects `StockunitBusinessService` (`:52`) — the reverse edge closes a two-node cycle, `spring.main.allow-circular-references` is set nowhere in `src/main`, and Spring Boot 3 defaults it to `false` → hard startup failure. Hence **D1** in the ADR: the helper goes on `UnitloadService`, which already holds every collaborator (`:24`, `:26`, `:28`, `:30`, `:40`, `:52`, `:58`, `:62`), and `StockunitService` already injects it (`:51`) so the call is **cross-bean and the proxy always fires**.

**Lock-order hazard the boundary creates (D3).** `unitload.storagelocation_id` has an FK to `location(id)`, so inserting a unit load takes a **`FOR KEY SHARE`** tuple lock on `location[Damaged]` for the rest of the transaction. `transferStockToUnitLoad` then takes `SELECT … FOR UPDATE` on that **same row** (`locationRepository.findByIdForUpdate` at `StockunitBusinessService:290`). `FOR UPDATE` conflicts with `FOR KEY SHARE`, so two concurrent mark-damaged operations deadlock (`40P01`). Today this cannot happen from `setLockDamaged` because `createUnitload`'s writes commit and release before the transfer's transaction starts — **the boundary introduces it on this path.** PostgreSQL detects it and rolls one side back completely, so the failure mode is an occasional 500 with no residue; but `bulkTransferToDamaged` gives N collision windows per request. Hence **D3: pre-lock `location[Damaged]` as the helper's first statement**, so two concurrent mark-damaged transactions take the strongest lock on the shared row first and serialize.

**The residual inversion D3 does *not* close — name it, do not triage it as a regression.** D3 removes only the mark-damaged ↔ mark-damaged self-collision (the `KEY SHARE`→`FOR UPDATE` upgrade), which is the high-frequency bulk case and is why it earns its keep. A cross-path **ABBA** cycle remains, created by the *boundary* rather than by the pre-lock: **the helper** takes `location[Damaged]` first, then `location[src]` at `StockunitBusinessService:250`, while **`transferStock`'s damaged-destination branch** (`:274-297`) — a gated, UI-reachable operation on the same page — takes `location[src]` at `:250`, then `location[Damaged]` at `:290`. So a **`40P01` is an expected low-frequency outcome**, not evidence the pre-lock failed: PostgreSQL detects it, rolls one side back completely and leaves no residue. Monitor as information (prereq 8).

Note also that `StockunitBusinessService:240-243` documents a stable resource-**type** order (`src-stockunit → src-unitload → src-location → dst-unitload → dst-stockunit → dst-location`, implemented at `:209`/`:245`/`:250`/`:257`/`:290`) while D3 imposes a resource-**instance** order. The two now coexist; **any third path locking both `location` rows must pick one.** The eventual full fix — hoist the source-location lock into the helper, both locations in ascending `location.id` — is **explicitly not in this plan**: it takes locations before `:209`'s src-stockunit lock, inverting against every path that locks a stockunit first, i.e. trading a known cycle for an unaudited one.

**Sequence-number hazard the pre-lock creates.** `createUnitload(Location, …)` mints the label via `basicService.generateNumber` (`UnitloadService:128` → `BasicService:47`) → `SequenceTransactionService.getNextSequenceNumber` which is `@Transactional(tenantTransactionManager, REQUIRES_NEW)` (`:23-24`). Today that runs as the helper's first statement while no locks are held. Behind a pre-lock it becomes a `REQUIRES_NEW` **inside a lock-holding transaction** on a second tenant connection (tenant pool default 5, `TenantDynamicRoutingDataSource:86`). Hence **D3's second half: hoist the mint out of the boundary** and use the `createUnitload(String name, …)` overload at `UnitloadService:132`, which does not call `generateNumber`. Cost is a harmless `UL######` gap on rollback.

`triggerReplenishmentMaintenance` stays **outside** the boundary. `ReplenishmentOrderMaintenanceService:128-135` documents that routing the recalc through a proxy inside a shared transaction marks it rollback-only and poisons sibling orders; with the boundary closed at `:454` the recalc opens its own short transaction and no shared transaction exists to poison.

### 2.2 F2 — a print failure also skips the replenishment recalc

`printLabel(:463)` precedes `triggerReplenishmentMaintenance(:465)`. `printLabel` (`:595-604`) does a sysprop read, a label render and `printService.cupsPrint(:603)`, and it declares `throws BusinessException, FacadeException`. A CUPS timeout therefore aborts `setLockDamaged` **after** the stock is durably damaged and **before** the replenishment recalculation — so an operator-visible failure leaves replenishment stale for that item. The `INBOUND` default printer is configured on the tenant checked, so the realistic trigger is CUPS unreachability rather than the missing-printer `orElseThrow`.

### 2.3 F3 — `removeLock` notifies before it writes

`sendStockChangeMessage` at `:567` (QUALITY_FAULT arm) and `:571` (ON_HOLD arm) precede `stockunitRepository.save(:583)`. `removeLock` is not transactional, so `OmsNotificationService:68-69` finds no active transaction and the `:88` branch POSTs **synchronously**. The payload is provably identical on either side of the save: `SharedService.getStockChangeDTO:129-143` reads **nothing off the mutable `Stockunit`** — only `itemData`, the passed ints, the comment, a sysprop (`:130`) and `clientRepository.findById` (`:131`). So moving the send below the save is behaviour-preserving for the payload and strictly safer for ordering.

### 2.4 F4 — `adjustAmount` commits, then throws "value not changed"

`changeAmount(:487)` is `@Transactional` at `StockunitBusinessService:428` and commits. The switch at `:491-503` reads `stockUnit.getEntityLock()` and covers `ON_HOLD`, `QUALITY_FAULT`, `NOT_LOCKED`; everything else hits `default: throw` at `:501-502`. All three inputs the switch needs — `oldAmount(:486)`, `diff(:488)`, `itemData(:490)` — are computable before `:487`, so the switch can be hoisted above the mutating call with no other change. Per the settled answer: **reject those locks, do not add new cases.**

### 2.5 F5 — the bulk `try` sits outside the loop

All three in-scope endpoints have the identical shape: `try { for (String id : ids) { … } } catch (BusinessException) {…} catch (FacadeException) {…}` — `bulkSetLockOnHold:477-489`, `bulkTransferToDamaged:557-570`, `bulkRemoveLock:617-627`. Two consequences:

- The first failure abandons the remainder while earlier ids stay committed.
- **None of the three catches `EntityNotFoundException`**, which `stockunitRepository.findById(...).orElseThrow` raises for a dead id (`:482`, `:563`) — so a dead id escapes as an unchecked exception. `bulkRemoveLock` is additionally asymmetric: it catches only `BusinessException` (`:625`), no `FacadeException`.

Both success and error responses are also unusable for per-id attribution: success returns `ResponseEntity.ok(<the last successful Stockunit>)` (`:492`, `:573`, `:630`) and errors return `{errors: [{field, message}]}` (C7) with **no id**.

### 2.6 Web-UI — why the `errors` key is omitted when empty (D7)

The obvious response shape, `{requested, succeeded, errors: []}`, would break today's UI. **`[]` is truthy in JS.** `if (results.errors)` at `store/handlingUnits/stockUnits.js:353` (`bulkLock`), `:378` (`bulkUnlock`) and `:478` (`bulkTransferToDamaged`) — lines per C12 would take the **error** branch on every response including total success; the next line, `results.errors[0].message`, throws `TypeError`, is swallowed by the outer `catch`, and the operator is shown *"Error: Request failed due to a network or server issue. Please retry."* **after the write succeeded** — and retries a completed damaged-stock adjustment.

**D7 removes that entirely: the `errors` key is present only when the list is non-empty.** On total success the response is `{requested, succeeded}`. Today's UI then sees `results.errors === undefined` → falsy → success branch → `searchStockUnit` dispatched, exactly as now; on partial failure it sees a populated array and behaves exactly as it does today (one toast, per-id detail lost until the UI ships). The new shape is therefore backward-compatible with the deployed UI in **both** outcomes, and the cross-repo merge-order dependency this plan used to carry dissolves (§5.3).

---

## §3 — Design / Proposed Fix

All snippets are minimal diffs, not whole methods.

### 3.1 F1 — atomic mark-damaged helper on `UnitloadService`

`UnitloadService` has **zero** `@Transactional` today; this is its first, and `TransactionManagerArchTest:47-57` reds the build for a bare one.

**Use the literal `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, not the `@TenantTransactional` meta-annotation.** The meta form has **zero `src/main` usages** (the only hit is a javadoc self-reference at `TenantTransactional.java:21`), while the literal form is proven at `StockunitService:156`/`:347`/`:516` and `StockunitBusinessService:178`/`:187`, including on the precedent path §2.1 argues from. Three reasons it is *required*, not merely preferred: `TransactionManagerArchTest:47-57` uses `areAnnotatedWith`, **not** `areMetaAnnotatedWith`, so the meta form would ship with no ArchUnit backstop; mutant 2 ("drop `rollbackFor`") is inapplicable to it, since the attributes are baked into `TenantTransactional.java:26`; and a naive `method.getAnnotation(Transactional.class)` returns **null** on a meta-annotated method, so the §6.2 reflection assertion would be red against correct code or rewritten vacuously. ⚠ Note for the reviewer: `TransactionManagerArchTest:53-55`'s own `.because(...)` message recommends *"Use `@TenantTransactional` or `@Transactional(value = …)`"* — i.e. the repo's stated guidance offers the meta form. The three reasons above still hold; this plan deliberately takes the other branch of that guidance.

**New on `UnitloadService`** — a label accessor and the helper. The accessor exists because `StockunitService` does **not** inject `BasicService`; routing the mint through the bean that already owns unit-load labelling keeps D1's zero-new-injections property.

```java
/** Mints a unit-load label WITHOUT opening a transaction. Callers that need the label
 *  before a transactional block use this so the REQUIRES_NEW sequence write
 *  (SequenceTransactionService:23) never runs inside a lock-holding tx. */
public String mintUnitloadLabel() throws BusinessException {
    return basicService.generateNumber(WmsConstants.EntityPrefixes.UNITLOAD, "UNIT_LOAD");
}

public record DamagedTransfer(Unitload container, Stockunit damagedStock) {}

@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public DamagedTransfer moveStockToNewDamagedContainer(String containerLabel, Stockunit stockUnit,
        Location damagedLocation, Long unitLoadTypeId, BigDecimal amount, String comment)
        throws BusinessException, FacadeException {
    // D3: strongest lock on the shared Damaged row FIRST, so the FK KEY SHARE taken by the
    // unit-load insert below can never invert against transferStockToUnitLoad's FOR UPDATE.
    locationRepository.findByIdForUpdate(damagedLocation.getId())
        .orElseThrow(() -> new EntityNotFoundException("Location", damagedLocation.getId()));

    // this.createUnitload is a self-invocation and that is CORRECT: createUnitload carries no
    // @Transactional of its own, so there is no advice to bypass. Do not "fix" it with a self proxy.
    Unitload container = createUnitload(containerLabel, damagedLocation, unitLoadTypeId,
                                       stockUnit.getClientId(), WmsConstants.CODE_DAMAGED);
    container.setBoxtypeId(itemdataService.getById(stockUnit.getItemdataId()).getDefaultboxtypeId());
    unitloadRepository.save(container);

    Stockunit damagedStock = stockunitBusinessService.transferStockToUnitLoad(
        stockUnit, container, amount, WmsConstants.CODE_DAMAGED, null, comment, false, true);
    damagedStock.setEntityLock(WmsConstants.BusinessObjectLockState.QUALITY_FAULT);
    damagedStock.setAdditionalcontent(comment);
    stockunitRepository.save(damagedStock);

    return new DamagedTransfer(container, damagedStock);
}
```

**`StockunitService.setLockDamaged` before (`:447-454`):** the eight lines quoted in §2.1.

**After:**

```java
String containerLabel = unitloadService.mintUnitloadLabel();   // outside the boundary (D3)
UnitloadService.DamagedTransfer transfer = unitloadService.moveStockToNewDamagedContainer(
        containerLabel, stockUnit, location_damaged, unitLoadType.getId(), amount, comment);
Unitload unitLoad = transfer.container();
Stockunit damagedStock = transfer.damagedStock();
```

`:443` (`findByName(STORAGE_LOCATION_DAMAGED)`) and `:446` (`findByName(UNIT_LOAD_TYPE_BOX)`) stay in `setLockDamaged`, unchanged. `:456-465` stay outside the boundary.

Three properties that **fail silently if lost** — each is one of §9.2's mutants: the helper is **`public`** (proxy-mode advice is public-only); it is reached **cross-bean** through `unitloadService`, never via `this.`; and it carries **both** `value` and `rollbackFor`, because `BusinessException` and `FacadeException` are *checked* and Spring's default unchecked-only rule would **commit** the half-done work — worse than the bug. Also note `createUnitload(String name, …)` at `UnitloadService:136-139` returns an **existing** unit load when `findByLabelid(name)` hits; unreachable with a freshly minted label, recorded so nobody adds a delete-on-rollback compensation later.

### 3.2 F2 — print last

**Before:** `printLabel(:463)` then `triggerReplenishmentMaintenance(:465)`.
**After:** `triggerReplenishmentMaintenance(...)` then `printLabel(...)`, i.e. swap the two statements so the print is the last thing before the `return`.

Chosen over the `ReceivingService:598-613` after-commit registration because `setLockDamaged` itself remains non-transactional, so there is no commit to hang the callback on. A statement swap is the whole fix.

### 3.3 F3 — save, then notify

**Before:** `sendStockChangeMessage` inside the switch at `:567` / `:571`; `save` at `:583`.
**After:** the switch builds `list` only; the single `messageService.sendStockChangeMessage(list)` moves to immediately **after** `:583`. This converges `removeLock` on `setLockOnHold:394→:399` and on its own mobile twin `MobileMoveUnitloadService:572→:575`.

### 3.4 F4 — validate, then commit

**Before:** `changeAmount(:487)` → `diff(:488)` → `itemData(:490)` → switch `(:491-503)`.
**After:** `oldAmount` → `diff` → `itemData` → switch → **then** `changeAmount`. The `default:` arm now throws before anything mutates, so `"value not changed"` becomes true.

### 3.5 F5 — per-item outcome on the lock trio

The same reshaping in `bulkSetLockOnHold`, `bulkTransferToDamaged`, `bulkRemoveLock`: move the `try` inside the `for`, catch per item, and record the id on both sides. Below is `bulkTransferToDamaged`; the other two differ only in the service call and in the lookup — see the two notes after the snippet.

```java
List<String> succeeded = new ArrayList<>();
List<Map<String, String>> errors = new ArrayList<>();
for (String id : ids) {
    try {
        Long parsedId = Long.parseLong(id);
        Stockunit stockUnit = stockunitRepository.findById(parsedId)
            .orElseThrow(() -> new EntityNotFoundException("StockUnit", parsedId));
        stockunitService.setLockDamaged(stockUnit, adjustAmount, comment, printLabel, principal);
        succeeded.add(id);
    } catch (NumberFormatException e) {
        errors.add(getErrorMessage("Invalid ID Format", e.getMessage(), id));
    } catch (EntityNotFoundException e) {
        errors.add(getErrorMessage("Entity Not Found", e.getMessage(), id));
    } catch (BusinessException e) {
        errors.add(getErrorMessage("Runtime Error", e.getMessage(), id));
    } catch (FacadeException e) {
        errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage(), id));
    } catch (org.springframework.dao.DataAccessException e) {
        // F1's boundary makes lock/version failures reachable per item; Spring Data translates
        // Deadlock/CannotAcquireLock/PessimisticLockingFailure/ObjectOptimisticLockingFailure
        // into this one hierarchy. Without this clause they escape the loop and re-open the
        // exact "abandons the rest of the batch" defect F5 exists to close.
        errors.add(getErrorMessage("Runtime Error", "Concurrent update conflict — retry this row", id));
    }
}
Map<String, Object> result = new LinkedHashMap<>();
result.put("requested", ids.length);
result.put("succeeded", succeeded);
if (!errors.isEmpty()) {          // D7: omit the key entirely when empty — see §2.6
    result.put("errors", errors);
}
return ResponseEntity.ok(result);
```

**Two per-endpoint differences that the word "identical" would hide:**

- **`bulkRemoveLock` keeps its no-lookup shape.** Unlike `:482` and `:563`, `bulkRemoveLock:623` passes `parsedId` straight to `stockunitService.removeLock` and the `EntityNotFoundException` originates inside the service at `StockunitService:552`. **Do not add a `findById` to it** — that would be a gratuitous extra query and a behaviour change. Its per-item catches are otherwise the same, and note it catches only `BusinessException` today (`:625`), so `FacadeException` is a genuine addition there.
- **No `id.trim()`.** The snippet deliberately parses `id` as-is, matching today's `Long.parseLong(id)`. Trimming would be a small improvement but is an unannounced id-parsing behaviour change on three endpoints; keep it out of this ticket.

The per-item `id` comes from a private overload on `StockUnitController` — **not** on the shared `AdminController`, which many controllers extend:

```java
private Map<String, String> getErrorMessage(String field, String message, String id) {
    // ⚠️ SUPERSEDED BY D8 — see the correction note below. As SHIPPED, the id is also
    // folded into `field`:  getErrorMessage(field + " (id " + id + ")", message)
    Map<String, String> error = getErrorMessage(field, message);   // AdminController:286, {field, message}
    error.put("id", id);
    return error;
}
```

> **⚠️ Correction (2026-08-26) — this snippet predates §3.6 D8 and is not what shipped.**
> The implementation at `StockUnitController:716` folds the failing id into `field` as well:
> `getErrorMessage(field + " (id " + id + ")", message)`, so a failure renders as
> `Invalid ID Format (id abc)`. **That is deliberate and load-bearing — do not "clean it up".**
> The two copies of the id serve different consumers:
> - `errors[].id` is read *programmatically* by `failedIdsFrom()`
>   (`wms2-web-ui store/handlingUnits/stockUnits.js:126`) to narrow the grid selection to the failed
>   rows — itself load-bearing, because `setLockDamaged` is not idempotent (§7 row 6).
> - `errors[].field` is what the *operator* reads. `util/commonUtility.js:11` renders
>   `` `${field}: ${message}` `` and knows nothing about `id`, so per that file's own comment the
>   fold is "the only place the operator can read it".
>
> Deleting the interpolation leaves the whole Java suite green while degrading every failure toast to
> an unattributable message. Reading this snippet alone, I concluded the fold was an accidental
> deviation and had a one-line "cleanup" PR ready before checking the web-ui side. A regression pin
> now exists — `StockUnitControllerUnitTest.bulkSetLockOnHold_failingId_isFoldedIntoField` (PR #203),
> mutation-checked so that exactly that deletion fails exactly that test.

**The shape is a deliberate third variant.** `{requested, succeeded, errors[{id, field, message}]}` differs from `AdminActionController`'s `recoveredIds` + `skipped[{id, reason}]` and from `labelPrinting`'s `printedCount`/`requested` + `skipped[{labelId, reason}]`, because it reuses `AdminController.getErrorMessage`'s already-deployed `{field, message}` pair (C7) — which is what `util/commonUtility.js:11` already renders — instead of introducing a fourth `reason` spelling. This is the shape the §8 follow-up endpoints should adopt. `requested` is kept so a surface can say "2 of 3". Dropping the bare-`Stockunit` success payload breaks nothing: the UI reads no field off it and refreshes by re-dispatching `searchStockUnit`.

### 3.6 Web-UI (`wms2-web-ui` only — C3)

| # | Change | Site |
|---|---|---|
| 1 | Length-guard the error branch in all three actions, reading defensively so it works against **both** the old and the new API shape: `const errs = Array.isArray(results && results.errors) ? results.errors : []`. Define partial-ness explicitly: `const partial = errs.length > 0 && (Array.isArray(results && results.succeeded) ? results.succeeded.length : 0) > 0` — against a response with no `succeeded` key (the old API), `partial` is false and the behaviour falls back to today's single toast | `store/handlingUnits/stockUnits.js:237`, `:254`, `:330` |
| 2 | Re-dispatch `searchStockUnit` on any response with ≥1 success, not only in the `else` — **`bulkLock` and `bulkUnlock` only** (C8: `bulkTransferToDamaged:484` is already unconditional — re-verified on `c82661b`). In-file precedent: `transferStock:169`, `transferToDamaged:188` | `:358`, `:383` |
| 3 | `return result` from all three actions — they return `undefined` today, so no component can react. Precedent: `store/admin/labelPrinting.js:264` | `:248`, `:265`, `:341` |
| 4 | **The partial-failure surface is a toast fan-out (D8).** Call the existing `util/commonUtility.js:4-16` `checkResponseError`, which needs **no change**: it already length-guards at `:6-7` and already renders `` `${errors[i].field}: ${errors[i].message}` `` at `:11`, which is exactly the shape `AdminController.getErrorMessage:286-291` emits (C7). ⚠ **`checkResponseError` renders `field` and `message` only — it never reads an `id` key** (`commonUtility.js:11`). So the API's 3-arg `getErrorMessage` overload must fold the id **into `field`** (e.g. `"Runtime Error (id 12345)"`) while still emitting the separate `id` key that item 5's selection rule needs. Without that fold, three failing rows produce three identical toasts and F5's per-id truth never reaches the operator. ~5 lines against an already-verified helper | `commonUtility.js` (read-only), the three actions |
| 5 | Keep **only the failed rows** selected after a partial run. This is load-bearing, not cosmetic — it is the mitigation for §7 row 6's non-idempotent retry. `lockConfirmation.vue:88` → `close()` emits `clearItem` only (`:56`), so `selectedItems` survives whole and the obvious retry re-submits ids that already succeeded. Exact hazard guarded at `unitLoadLabels.vue:176-181`. Also reconcile the two dialogs: `transferToDamaged` emits `clearItems` (`stockUnitsTable.vue:120`), `lockConfirmation` does not (`:118`). **When `errors[].id` is absent (old API), keep the whole selection** — there is nothing to narrow to | `components/handlingUnits/popups/lockConfirmation.vue:88`, `components/handlingUnits/stockUnitsTable.vue:118` |
| 6 | **Opt-in follow-up, not in this ticket:** a per-id result dialog on the SBDEV-2861 tier-C convention — store state + mutation (`store/admin/labelPrinting.js:51`, `:73-75`), branch on partial rather than toasting (`:257-263`), a dialog mirroring `components/admin/labelPrinting/printResultDialog.vue` with the CSV download at `:92-100`, mounted beside the existing dialogs at `stockUnitsTable.vue:118-121`. Worth doing if operators ask for the CSV; a new component plus new spec files is not justified by a `normal`-priority fix with nil measured residue | deferred |

### 3.7 File Change Summary

**Two repos. 6 files of production code (3 API + 3 web-UI), 6 files of test code (4 API + 2 web-UI).** No mobile repo, no schema, no migration.

| File | Change Type | Description |
|---|---|---|
| **`v2/wms2-api`** | | |
| `src/main/java/.../service/UnitloadService.java` | Add | `mintUnitloadLabel()`, the `DamagedTransfer` record, and the `@Transactional(tenantTransactionManager, rollbackFor)` `moveStockToNewDamagedContainer` helper (F1). First transaction boundary in the class |
| `src/main/java/.../service/StockunitService.java` | Modify | `setLockDamaged:447-454` → the two-call form (F1); swap `:463`/`:465` (F2); one `sendStockChangeMessage` below `:583` in `removeLock` (F3); hoist the lock switch above `changeAmount:487` (F4) |
| `src/main/java/.../controller/StockUnitController.java` | Modify | Per-item try + `{requested, succeeded[, errors]}` on `bulkSetLockOnHold`, `bulkTransferToDamaged`, `bulkRemoveLock` (F5); add the private 3-arg `getErrorMessage` overload |
| `src/test/java/.../unit/service/UnitloadServiceUnitTest.java` | Modify | New nested class for the helper: annotation reflection, pre-lock order, `QUALITY_FAULT` inside, two `never()` side-effect rows (`messageService`, `printService`; the recalc is pinned in `StockunitServiceUnitTest` instead — see §6.2) |
| `src/test/java/.../unit/service/StockunitServiceUnitTest.java` | Modify | Rewrite `:1092`/`:1125`/`:1163` to the new seam; add F2/F3/F4 ordering and `never()` tests |
| `src/test/java/.../unit/controller/StockUnitControllerUnitTest.java` | Modify | Per-item partial / dead-id / `DataAccessException` / total-success rows × 3 endpoints |
| `src/test/java/.../integration/service/StockunitDamagedRollbackIntegrationTest.java` | Add | D6 — `extends BaseRollbackIntegrationTest`; asserts the F1 boundary actually rolls back |
| **`v2/wms2-web-ui`** | | |
| `store/handlingUnits/stockUnits.js` | Modify | Length-guard + partial predicate, re-dispatch on any success (`bulkLock`/`bulkUnlock`), `return result`, toast fan-out via `checkResponseError` |
| `components/handlingUnits/popups/lockConfirmation.vue` + `components/handlingUnits/stockUnitsTable.vue` | Modify | Keep only failed rows selected after a partial run |
| `test/store/handlingUnits/stockUnits.spec.js` | Add | ⚠ **C13:** the earlier claim that *no* spec covers this module was wrong — it searched for a `handlingUnits/` **directory**. `test/store/handlingUnitsActionAuthz.spec.js` (10 `it`s) and `test/store/handlingUnitsDeniedToast.spec.js` (7) already exercise this store. Neither covers the bulk response shape, so the new spec is still needed — but **do not break `handlingUnitsDeniedToast.spec.js:63`**, which enumerates actions by parsing the module source ("DERIVED, not hand-listed") and so picks up our three automatically. Model on `test/store/admin/labelPrinting.spec.js` (esp. `:63`, the full-success negative) |
| `test/components/handlingUnits/lockConfirmation.spec.js` | Add | Pins the keep-only-failed-rows selection rule (§6.3). Model on `test/components/admin/labelPrinting/unitLoadLabels.spec.js` |
| **Not touched** | | `AdminController`, `LocationRepository`, `StockunitBusinessService`, `util/commonUtility.js`, `db/migration/**`, `wms2-mobile-ui`, `omsv2-UI`, `v1/**` |

---

## §4 — V1/V2 Applicability

**Nothing to port. v2 only.**

`v1/wms-api` carries the same missing annotations on the mark-damaged / unlock / adjust paths and the same bulk `try`-outside-the-loop shape. **v1 is reference-only** per the standing instruction: state the finding if asked, file no v1 ticket, plan or code. And per C3, `v2/wms2-mobile-ui` and `v2/omsv2-UI` have **zero** consumers of all three endpoints, so no mobile change in either version.

---

## §5 — Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. Flyway version unchanged, **no new migration** | — | Verify with `git diff --stat -- src/main/resources/db/migration` = empty before the PR. This plan must not consume a Flyway version number |
| 2 | **Feature flags / system properties** | None added. `SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY` and the `INBOUND` default printer must stay as-is for the F2 manual test | — | Default `INBOUND` printer confirmed present on `wms2-wineco-dev` (§1.3) |
| 3 | **Config / env changes** | None. `spring.jpa.open-in-view=false` (`application.properties:55`) and the tenant pool default of 5 (`TenantDynamicRoutingDataSource:86`) are assumed, not changed | — | ⚠ `application_dev.properties` is gitignored, so a per-env `maxPoolSize` override cannot be seen from the repo; the 5 is the code default |
| 4 | **Deploy-order dependencies** | **None.** D7 (omit `errors` when empty) makes the new API shape backward-compatible with the deployed UI, so either merge order is safe. See §5.3 | — | This was a hard constraint in the pre-D7 draft; it is gone, not relaxed |
| 5 | **Data migration** | None. No backfill: §1.3 measured **0** orphan containers and **0** `entity_lock`-drifted damaged stockunits across the tenants checked | — | Re-run the two `Damaged`-location queries on any tenant not covered in §1.3 before that tenant is upgraded |
| 6 | **External systems** | OMS `STOCK_UPDATE` endpoint reachable for the F3 manual test; a reachable CUPS printer for the F2 happy path and an unreachable one for the F2 negative | — | F2's negative test is the only one needing a deliberately broken printer |
| 7 | **Access / permissions** | Test operator holds `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` (`StockUnitController:538`), `WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD` (`:466`) and `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` (`:607`). No new gate | — | Existing gates only; nothing added or widened |
| 8 | **Monitoring / alerts** | None required. Watch for `40P01` (deadlock) and `ObjectOptimisticLockingFailureException` on `/v3/stockUnit/bulkTransferToDamaged` for the first week — **as information, not as a fix-failure signal** | — | D3 removes the mark-damaged ↔ mark-damaged self-collision. A residual `location[Damaged]` ↔ `location[src]` inversion against `transferStock:274-297` remains, created by the boundary rather than by the pre-lock (§2.1), so `40P01` is an **expected low-frequency outcome** that PostgreSQL resolves with a complete rollback and no residue. After F5 it surfaces as one `errors` entry naming the id, not a 500 |
| 9 | **Baseline capture** | Record the develop baseline **before** any edit, for **both** lanes. `mvn test`: the two known reds are `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate` (C6). `mvn verify`: capture separately — D6 lands in that lane and it is **already red**, because `ReplenishmentOrderMaintenanceServiceIntegrationTest`'s single test ends in an unconditional `fail("AC-4 data setup not yet implemented")` | — | Compare **test** counts, not suite counts. Same rule on `wms2-web-ui`, which has 2 always-red suites with 0 failing tests |
| 10 | **`archunit_store` hygiene** | `git status src/test/resources/archunit_store/` clean before starting, and checked after every `mvn test` | — | `OptionalSafetyArchTest` uses `FreezingArchRule.freeze`; F1 moves code between service classes, which can register as a *new* `Optional.get()` violation and go red for an unrelated-looking reason. `mvn test` **mutates** the store |

### 5.2 Implementation checklist

**API (`v2/wms2-api`), worktree `.claude/worktrees/wms2-api/SBDEV-3086` off freshly-fetched `origin/develop`:**

The per-file view is §3.7; this is the order to do it in.

- [ ] Capture the test baseline (prereq 9) and confirm `archunit_store` is clean (prereq 10).
- [ ] Write the failing tests first, per §6 — the F1 boundary assertions, the D6 rollback test, and the F2/F3/F4/F5 pins — and mutation-check each new assertion before implementing.
- [ ] **F1** in three commits: (a) `mintUnitloadLabel()` + the `DamagedTransfer` record; (b) `moveStockToNewDamagedContainer(...)` with the literal annotation, the D3 pre-lock first and `:452-454` inside; (c) rewrite `setLockDamaged:447-454` to the two-call form (§3.1).
- [ ] **F2** swap `:463`/`:465`. **F3** collapse the two sends into one below `:583`. **F4** hoist the switch above `changeAmount(:487)`. Each is a one-statement move.
- [ ] **F5** per-item try (including `DataAccessException`) on the three endpoints + the private 3-arg `getErrorMessage`. `bulkRemoveLock` keeps its no-lookup shape; no `id.trim()` anywhere.
- [ ] Rewrite `StockunitServiceUnitTest:1092`, `:1125`, `:1163` to the new seam (§6.2).
- [ ] Confirm D6 is red before F1c and green after, under **`mvn verify`** (surefire excludes `*IntegrationTest` at `pom.xml:494-497`).
- [ ] Run the three F1 mutants (§9.2); each red for the right reason, recompilation forced.
- [ ] `mvn clean compile` green, and confirm the Spring context still starts — unit tests do not see DI wiring, and `UnitloadService` becomes proxied for the first time.
- [ ] Full suite vs. the prereq-9 baseline; `archunit_store` re-checked. Independent code review, every High/Medium fixed, never self-approve.

**Web-UI (`v2/wms2-web-ui`), worktree `.claude/worktrees/wms2-web-ui/SBDEV-3086`:** items 1-5 in §3.6 (item 6 is deferred); a new `test/store/handlingUnits/stockUnits.spec.js` (no spec exists for these call sites today) and a component spec for the keep-only-failed-rows rule; Jest suite vs. baseline, comparing **test** counts, not suite counts.

### 5.3 Merge order — no longer a constraint

Merging to `wms2` `develop` is itself a dev deploy (branch-push-driven, no CI on PRs), so merge order *is* deploy order — which is why the pre-D7 draft carried a hard "web-UI first" rule. **D7 dissolves it.** With the `errors` key omitted when empty, the new API response is backward-compatible with the deployed UI in both outcomes: on total success today's `if (results.errors)` sees `undefined` → success branch → `searchStockUnit` dispatched, and on partial failure it sees a populated array and behaves exactly as it does today (§2.6). The new UI is likewise forward- and backward-compatible, because §3.6 item 1 reads `errors` defensively and derives `partial` from `succeeded`, which the old API never sends.

**Either order is safe, and the two PRs are independent.** The API PR is the one that carries the correctness fixes; ship it whenever it is ready. §6.2 keeps one row pinning the old-UI-shape compatibility so a future change to the response cannot quietly re-create the coupling.

---

## §6 — Test Plan

### 6.1 Coverage the change starts from

`StockunitServiceUnitTest` has **75** `@Test`; `StockUnitControllerUnitTest` has **50**. Existing coverage of the five targets:

| Fix | Existing coverage |
|---|---|
| F1 | Three tests exercise the trio as *direct collaborators of `StockunitService`* (`:1092`, `:1125`, `:1163`). None asserts a boundary |
| F2 | **Zero.** All three `setLockDamaged` happy-path tests pass `printLabel = false`. `:1158` verifies the recalc happened, never relative to the print |
| F3 | **Zero.** No ordering assertion on `sendStockChangeMessage` vs `save` anywhere |
| F4 | Near-zero. `:519` asserts the throw but **not** that `changeAmount` was skipped |
| F5 | The three trio error tests submit a single id (`:966`, `:1106`, `:1199`), so none exercises partial failure |

**The test lanes — see C11 for the full derivation.** `*IT.java` is dead (28 classes, matching neither plugin's patterns); `*IntegrationTest.java` is **alive** and runs under **`mvn verify` only**, because surefire excludes it (`pom.xml:494-497`) while failsafe includes it (`:611-614`) and is bound to `verify` (`:624-631`). `BaseRollbackIntegrationTest` exists precisely to observe real rollbacks, with three live subclasses.

**So F1 gets a real rollback test (D6), and the proof becomes observational rather than inferential.** `StockunitDamagedRollbackIntegrationTest extends BaseRollbackIntegrationTest` throws from `transferStockToUnitLoad` mid-helper and asserts **zero `unitload` rows in `Damaged`** — the one thing no mutant can show, since a mutant proves a property of the annotation and this proves the committed state. The mutants stay: they cover `value`, `rollbackFor` and visibility, which the integration test cannot see (a boundary bound to the wrong TM can still look correct on a single H2 datasource).

Two limits, stated: H2 **does not reproduce** `SELECT … FOR UPDATE` **lock semantics** (`StockunitBusinessServiceConcurrencyIT:20` — it accepts and executes the statement, which is why D6 can run at all), so the D3 pre-lock and the deadlock class stay out of the integration lane; and this plan did not execute the lane, so its pass state is inferred, not measured.

### 6.2 Test scenarios

| Scenario | Steps | Expected |
|---|---|---|
| F1 boundary is on the helper | Look the method up by name and signature on `UnitloadService`, **assert it was found**, then assert the modifier and the annotation | Method present; `Modifier.isPublic` true; `getAnnotation(Transactional.class)` non-null with `value() == "tenantTransactionManager"` and `rollbackFor()` containing both `BusinessException` and `FacadeException`. **Never a `getDeclaredMethods()` for-each without the found assertion** — that shape goes vacuously green if the method is renamed or absent (it has happened here: a for-each test stayed 13/13 green against a gutted interface) |
| **F1 really rolls back (D6)** | `StockunitDamagedRollbackIntegrationTest extends BaseRollbackIntegrationTest`: `@MockitoBean StockunitBusinessService` stubbed so `transferStockToUnitLoad` throws `BusinessException` after the `unitload` insert; call `setLockDamaged`; read the DB. ⚠ Use `@MockitoBean`, **not** `@MockitoSpyBean` — `AdviceServiceRollbackIntegrationTest:52-56` documents that spying a `@Transactional`-proxied bean makes `doThrow().when()` invoke the real method and corrupt the mock state, and `transferStockToUnitLoad` is `@Transactional` (`:187-188`). Seed `location[Damaged]`, `location[SPAWN]` (`UnitloadService:150` `orElseThrow`), `unitloadType[BOX]`, client, itemdata, boxtype, source unitload + stockunit, **and pre-seed `los_sequencenumber`** (D3 makes `mintUnitloadLabel` the first call; `AdviceServiceRollbackIntegrationTest:99-106` shows why) | **Zero `unitload` rows in the `Damaged` location** — the load-bearing assertion, because that insert is real and precedes the throw — **plus `assertThatThrownBy(…).isInstanceOf(BusinessException.class)`**, without which mutant 1 escapes (§9.2: the pre-lock throws `TransactionRequiredException` before the insert, so zero rows is trivially true). Red before F1c (pre-fix, the `save` at `UnitloadService:148` commits in its own repository transaction), green after. Runs under `mvn verify`. Do **not** also assert "zero new `stockunit` rows": with the transfer stubbed out no stockunit is ever created, so that clause holds under any implementation — including one with no transaction at all. **What D6 does not observe:** the `QUALITY_FAULT` write and the D3 pre-lock never execute on this path, and the D6 schema has no FKs (`flyway.enabled=false` + `ddl-auto=create-drop` + zero JPA associations), so D6 says nothing about D3 |
| F1 call is cross-bean | `setLockDamaged` with the trio stubbed on the `unitloadService` mock | `verify(unitloadService).moveStockToNewDamagedContainer(...)`; `stockunitBusinessService.transferStockToUnitLoad` is **never** called directly by `StockunitService` |
| F1 pre-lock precedes every other repository interaction | Helper under `InOrder(locationRepository, unitloadRepository, stockunitBusinessService)` | `findByIdForUpdate` precedes `save(Unitload)` precedes `transferStockToUnitLoad`. (This is what a test can decide; an unmocked statement inserted before the pre-lock would be invisible to it) |
| F1 side effects stay outside the boundary | Helper happy path in `UnitloadServiceUnitTest`, all collaborators mocked | `verify(messageService, never()).sendStockChangeMessage(any())` and `verify(printService, never()).cupsPrint(any(), any())`. Both are real fields on `UnitloadService` (`messageService:50`, `printService:36`) and other methods on the class do call them, so a careless helper genuinely trips these |
| The recalc runs **after** the boundary closes | `StockunitServiceUnitTest` on `setLockDamaged` | `InOrder(unitloadService, replenishmentOrderMaintenanceService)`: `moveStockToNewDamagedContainer` precedes `recalculateForItem`. ⚠ Do **not** write this as `verify(replenishmentOrderMaintenanceService, never())` on the helper — `UnitloadService` has no such collaborator (field list `:24-70`), so that assertion cannot fail under any implementation and would need an otherwise-unused `@Mock` even to compile |
| F1 label is minted outside | `setLockDamaged` happy path | `unitloadService.mintUnitloadLabel()` called once, **before** `moveStockToNewDamagedContainer`; the minted label is the first argument |
| F1 QUALITY_FAULT is inside | Helper happy path | The returned `damagedStock` has `entityLock == QUALITY_FAULT` and `stockunitRepository.save` was called by the **helper** |
| F2 print is last | `setLockDamaged(printLabel = true)` under `InOrder(replenishmentOrderMaintenanceService, printService)` | `recalculateForItem` precedes `cupsPrint` |
| F2 print failure spares the recalc | `printService.cupsPrint` throws `FacadeException` | The exception propagates **and** `recalculateForItem` was already called |
| F3 save precedes notify | `removeLock` under `InOrder(stockunitRepository, messageService)`, once for `QUALITY_FAULT` and once for `ON_HOLD` | `save` precedes `sendStockChangeMessage`; exactly one send per call |
| F4 no commit on an unexpected lock | `adjustAmount` with `entityLock` = 100 `PICKED_FOR_GOODSOUT`, 403 `NOT_FOUND`, 404 `TRANSFER` | throws `BusinessException`; `verify(stockunitBusinessService, never()).changeAmount(...)` |
| F4 happy paths unchanged | `NOT_LOCKED`, `ON_HOLD`, `QUALITY_FAULT` | `changeAmount` called once; the message still sent |
| F5 partial failure per endpoint | 3 ids, middle one throws `BusinessException` | 200; `succeeded` = the other two ids; `errors` has exactly 1 entry carrying the failing **id**; the service was called **3** times |
| F5 dead id does not abort | 2 ids, the second unstubbed → `Optional.empty()` | 200; `errors[0].field == "Entity Not Found"`, `errors[0].id` = the dead id; the first id in `succeeded` |
| **F5 lock failure does not abort** | 3 ids, the middle one's service call throws `DeadlockLoserDataAccessException` | 200; the other two ids in `succeeded`; exactly one `errors` entry carrying the failing **id**; the service was called **3** times. Red today (it escapes as a test error — the standalone MockMvc installs no `RestExceptionHandler`, `BaseControllerUnitTest:50-52`) |
| F5 total success shape | 2 ids, both succeed | 200; `requested == 2`; `succeeded` has 2 **id strings**; **`$.errors` does not exist** (`jsonPath("$.errors").doesNotExist()`) — the D7 pin the deployed UI depends on |
| F5 sibling untouched | `bulkTransferStock` with a dead id | `StockUnitControllerUnitTest:498` still green (SBDEV-2994's pin) |
| UI: the four shapes | `bulkUnlock` mocked to resolve, in turn: `{requested:2, succeeded:['1','2']}` · `{requested:2, succeeded:['1'], errors:[{id:'2',…}]}` · a bare `Stockunit` (old success) · `{errors:[{field,message}]}` (old error) | (1) success path, `searchStockUnit` dispatched, no error toast, no `TypeError`; (2) result returned, `searchStockUnit` still dispatched, one toast per failing id via `checkResponseError`; (3) success branch; (4) single toast, `partial` false, whole selection retained. (3) and (4) pin the §5.3 claim that neither merge order can break the deployed UI |
| UI: retry hygiene | after a partial run | only the failed ids remain selected; with `errors[].id` absent, the whole selection is kept |

### 6.3 New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `UnitloadServiceUnitTest` | `moveStockToNewDamagedContainer_*` (new nested class) | boundary annotation attributes, `public`, pre-lock order, QUALITY_FAULT inside, two `never()` side-effect rows (`messageService`, `printService`) |
| `integration/service/StockunitDamagedRollbackIntegrationTest` *(new)* | `setLockDamaged_midHelperThrow_leavesNoDamagedContainer` | **D6** — the real rollback. `extends BaseRollbackIntegrationTest`; runs under `mvn verify`. Model on `AdviceServiceRollbackIntegrationTest` |
| `StockunitServiceUnitTest` | `:1092`, `:1125`, `:1163` **rewritten** | the trio is now stubbed on the `unitloadService` seam; `verify(unitloadService).createUnitload(...)` at `:1192-1193` and `verify(stockunitBusinessService).transferStockToUnitLoad(...)` at `:1154-1156` / `:1194` must move to the new seam or the stubs go unused |
| `StockunitServiceUnitTest` | `setLockDamaged_printsAfterRecalc`, `setLockDamaged_printFailureLeavesRecalcDone` | F2 |
| `StockunitServiceUnitTest` | `removeLock_savesBeforeNotifying_qualityFault` / `_onHold` | F3 |
| `StockunitServiceUnitTest` | `adjustAmount_unexpectedLock_doesNotCommit` (×3 locks) | F4, with `verify(never())` |
| `StockUnitControllerUnitTest` | per-item partial / dead-id / total-success rows × 3 endpoints | F5 |
| `test/store/handlingUnits/stockUnits.spec.js` *(new)* | **Gate rows (red today):** the actions return their result; `bulkLock`/`bulkUnlock` re-dispatch `searchStockUnit` on a *partial* response; one toast **per** failing id. **Compat pins (green by design, not gate rows):** D7 total success with `errors` absent; the two deployed shapes. ⚠ `bulkTransferToDamaged`'s dispatch is already unconditional (`:484`), so the re-dispatch row is **not** a gate row for it | §3.6 items 1-4. See C13 on the two existing specs. Model on `test/store/admin/labelPrinting.spec.js` (`:42`, `:63`) |
| `test/components/handlingUnits/…` *(new)* | keep-only-failed-rows | Model on `unitLoadLabels.spec.js:9` |

### 6.4 Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Mark-damaged happy path | staging (`wms2-wineco-dev`) | Stock Units → select 1 row → Transfer to Damaged, amount < total, `printLabel` off → confirm | One new UL in `Damaged` holding the damaged stock at `entity_lock = 103`; source amount reduced | |
| Mark-damaged with label | staging | as above with `printLabel` on, printer reachable | Label prints; stock damaged; replenishment recalculated | |
| F2 — print failure | staging | Point the default `INBOUND` printer at an unreachable host, repeat | Operator sees the print error, **but** the stock is damaged and the replenishment recalc already ran (check `replenishorder` for the item) | |
| F3 — release lock | staging | Select a `QUALITY_FAULT` row → Release lock | `entity_lock` back to 0, and exactly one `message` row of type `STOCK_UPDATE` in `SENT`, created **after** the stockunit's `modified` | |
| F4 — unexpected lock | staging DB + UI | Set one stockunit to `entity_lock = 100` by hand, then Adjust Amount from the UI | Error toast; `amount` and `stockrecord` **unchanged** | |
| F5 — bulk partial failure | staging | Select 3 rows, one of them already locked → bulk Transfer to Damaged | One error toast naming the failing id and its reason; the 2 successes are refreshed in the table; **only the failed row stays selected** | |
| F5 — bulk total success | staging | Select 3 valid rows → bulk Set Lock On Hold | Success path, no error toast, table refreshed | |
| D7 — new API against the **old** UI build | staging | Deploy the API alone and repeat the two rows above from an un-updated web-UI | Both behave as they do today — no "Request failed… Please retry" on a successful write. This is the §2.6 / §5.3 check | |
| SQL sanity | staging DB | `SELECT count(*) FROM unitload u WHERE u.storagelocation_id = <Damaged> AND NOT EXISTS (SELECT 1 FROM stockunit s WHERE s.unitload_id = u.id);` | 0, before and after the exercises | |

### 6.5 Deliberately-skipped coverage

| What | Why |
|---|---|
| Concurrent-deadlock reproduction for D3 | Requires two real PostgreSQL sessions; H2 does not reproduce `SELECT … FOR UPDATE` **lock** semantics (`StockunitBusinessServiceConcurrencyIT:20`), so it is out of reach of the live `*IntegrationTest` lane too. Covered by the pre-lock-ordering unit assertion plus the prereq-8 watch — and the residual inversion in §2.1 means a `40P01` is expected anyway, so there is no invariant here to pin |
| Reviving the `*IT` lane | 28 classes run in neither lane (§6.1). Fixing that is a repo-wide test-infrastructure change, unrelated to these four windows. F1's rollback proof does not need it — D6 uses the live `*IntegrationTest` lane. Follow-up, listed in §8 |
| Cypress bulk coverage | `wmsHelpers.js:687`/`:694` only wrap the **singular** endpoints, and `inventory-management.cy.js:261,307,440,455,522` assert today's `errors[]`-at-200 contract on those. Those stay green because the singular endpoints' response shapes are untouched. New bulk helpers are out of scope |

---

## §7 — Horizontal Scalability Validation

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1, 3, 5, 7 | **In-JVM state · Scheduled jobs · Request affinity · Tenant context** | **No / N/A** | No cache, map, static or `ThreadLocal` added — the `DamagedTransfer` record is a per-call return value. No `@Scheduled` added or modified. Every changed path is a single stateless request; the web-UI change is toasts and selection state in one browser. No `@Async`, no `CompletableFuture`, no job thread — `TenantContext` is set by `TenantFilter` on the request thread and the whole boundary runs on it |
| 2 | **Connection pool math** | **Yes** | F1 holds one tenant connection across `createUnitload` + `transferStockToUnitLoad` + the lock save. D3 hoists the `REQUIRES_NEW` sequence mint (`SequenceTransactionService:23-24`) **out** of the boundary, so peak stays at **1** connection per in-flight operation instead of 2. (No comparison to `transferStock` is drawn: `transferStock:157-261` issues only `findById` reads and holds **no** row locks — its first pessimistic lock is `StockunitBusinessService:209`, reached at `:270`/`:276` — so its `:261` mint runs inside an open transaction but not under a held lock.) Tenant pool default is 5 (`TenantDynamicRoutingDataSource:86`); landlord is 2 (`application.properties:46`) and is untouched because the explicit `value = "tenantTransactionManager"` pins the tenant TM |
| 4 | **Long transactions** | **Yes** | The boundary spans several repository calls, and this is the point of the change. Bounded and deliberately short: the added work over today's `transferStockToUnitLoad` transaction is one `unitload` INSERT, one `unitloadrecord` INSERT and one `unitload` UPDATE, all on rows this transaction just created, so they contend with nothing. The three items that would put I/O inside it — `sendStockChangeMessage(:461)`, `printLabel(:463)`, `triggerReplenishmentMaintenance(:465)` — are all **outside** by design and must stay there |
| 6 | **Retry / idempotency** | **Yes** | `setLockDamaged` is **not** idempotent — re-running it damages more stock. F5 plus §3.6 item 5 (keep only failed rows selected) exist precisely so an operator retry cannot double-apply; item 5 is load-bearing for exactly this reason. No server-side idempotency key is added; the guard is that the UI never re-submits a succeeded id |
| 8 | **Distributed lock correctness** | **Yes** | The D3 pre-lock is `locationRepository.findByIdForUpdate(damagedLocationId)` **inside** the tenant-bound boundary — the required condition. ⚠ Three facts to carry: `LocationRepository:51-54` has **no** lock timeout (unlike `StockunitRepository:33-36`'s 5000 ms), so the pre-lock waits unbounded under contention; `@Version` is live (C1), so `ObjectOptimisticLockingFailureException` is a legitimate outcome; and a **residual `location[Damaged]` ↔ `location[src]` inversion remains** against `transferStock:274-297` (§2.1), so `40P01` is expected at low frequency and is not a fix failure. F5's `DataAccessException` clause turns all three into a per-item `errors` entry rather than an aborted batch. Adding a timeout hint would mean changing the shared `LocationRepository.findByIdForUpdate` — **three** `src/main` call sites (`StockunitBusinessService:250`, `:290`, `UnitloadBusinessService:163`) — or adding a dedicated query — **out of scope, recorded as a follow-up** |
| 9 | **Cache invalidation** | **N/A** | Read-only against the one cached entity on these paths: `Itemdata` is `@Cacheable` (`ItemdataService:52`, `:57`) and is read at `StockunitService:448`, `:458`, `:490`, `:561` and inside the helper. No cached entity is written and no eviction is added, so there is nothing to invalidate |
| 10 | **External notifications** | **Yes** | F3 moves the OMS `STOCK_UPDATE` POST below the `save`. `removeLock` stays non-transactional, so `OmsNotificationService` still takes the synchronous `:88` branch — the send is now after a durable write rather than before it. F1 keeps `sendStockChangeMessage(:461)` outside the boundary, so no notification is emitted from inside a transaction and no replica retry can duplicate one |

Every `file:line` backing the rows above is cited in the row itself; the retry-hazard guard for row 6 is `components/handlingUnits/popups/lockConfirmation.vue:88`/`:56`, precedent `unitLoadLabels.vue:176-181`.

### v2-only constraint checklist

| # | Constraint | Verdict | Note |
|---|---|---|---|
| 1 | OSIV disabled | **Yes — relied on** | `application.properties:55`. It is why `save(:454)` is a detached `merge` today, and why pulling `:452-454` inside the boundary (keeping the entity managed) removes an `OptimisticLockException` window |
| 2 | `tenantTransactionManager` | **Yes — mandatory** | Via the **literal** annotation (§3.1), not `@TenantTransactional`. `TransactionManagerArchTest:47-57` uses `areAnnotatedWith(Transactional.class)`, so it reds a bare `@Transactional` in `net.aim_ai.wms.service` but is blind to the meta form — one of the three reasons §3.1 rejects it |
| 3 | `BaseControllerUnitTest` | **Yes** | F5's rows extend `StockUnitControllerUnitTest`, which uses `standaloneSetup`. ⚠ That MockMvc has **no** `RestExceptionHandler` — `BaseControllerUnitTest:50-52` forwards an **empty** advice array to `setControllerAdvice` — so any exception the per-item catch misses escapes as a test *error*, not a 200. That is why `EntityNotFoundException`, `NumberFormatException` and `DataAccessException` must all be caught per item, and what makes the three new F5 rows red today |
| 4 | Jakarta namespace | **Yes** | `jakarta.persistence` throughout; the new record and helper add no imports outside it |
| 5-8 | `readOnly = true` · Caffeine invalidation · H2-compatible test SQL · Micrometer metrics | **N/A** | Every new boundary is a write path; no cached entity is written (§7 row 9); no SQL in tests — the §1.3 queries live in this document, not the repo; no new metric, and prereq 8 asks for log watching rather than instrumentation |

---

## §8 — Risks & Notes

### 8.1 Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Unbounded pre-lock wait.** `findByIdForUpdate` carries **no** lock timeout (`LocationRepository:51-54`; contrast `StockunitRepository:33-36`'s 5000 ms) and the lock is held for the whole helper | A concurrent mark-damaged on the same warehouse blocks with no ceiling; under a bulk request, N sequential waits | Accepted. The boundary is short (three INSERT/UPDATEs plus `transferStockToUnitLoad`, all on rows it just created) and §1.3 measures **zero** mark-damaged usage on prd. A dedicated timeout-carrying query is follow-up 2 — not the shared `LocationRepository.findByIdForUpdate`, whose three `src/main` call sites (`StockunitBusinessService:250`, `:290`, `UnitloadBusinessService:163`) would all silently inherit the change |
| **Residual `40P01`, and `ObjectOptimisticLockingFailureException`.** D3 closes only the self-collision, not the `location[Damaged]` ↔ `location[src]` inversion against `transferStock:274-297` (§2.1); `@Version` is inherited and live (C1) | An occasional 500 — or, after F5, one `errors` entry — on concurrent damage + move-to-damaged | PostgreSQL detects the deadlock and rolls one side back completely: **no residue**. F5's `DataAccessException` clause turns both into a per-item outcome naming the id. Prereq 8 watches them as information, explicitly **not** as evidence the pre-lock failed. The optimistic-lock window is also *reduced* by D2 — the `:454` `save` becomes a flush rather than a detached `merge` |
| **The batch is not atomic.** F5 makes each item atomic; the batch is not | A partial run leaves some ids changed and some not, and `setLockDamaged` is not idempotent — a naive retry double-damages stock | Per-item `succeeded`/`errors` so the operator can see which is which, plus §3.6 item 5 (keep **only** the failed rows selected) so the obvious retry cannot re-submit a succeeded id. Stated as a non-goal in §8.2 so nobody reads "atomic" as all-or-nothing |
| **`archunit_store` mutation.** `OptionalSafetyArchTest` uses `FreezingArchRule.freeze`, and F1 moves code between service classes | A *new* frozen violation is recorded, the build reds for an unrelated-looking reason, and the store is silently committed | Prereq 10: `git status src/test/resources/archunit_store/` clean before starting and re-checked after **every** `mvn test`/PIT run |
| **Cross-repo response contract.** Three endpoints change from a bare `Stockunit` to a result map | A consumer reading the old body breaks | Measured: `wms2-mobile-ui` and `omsv2-UI` have **zero** consumers (C3); no API test asserts the success body; the web-UI reads no field off it. D7 keeps the new shape backward-compatible with the deployed UI in both outcomes (§2.6), and §6.2 pins that with a Jest row |
| **A vacuous F1 fix.** Three source shapes compile, pass every unit test and produce no boundary (wrong TM, missing `rollbackFor`, non-public method) | The plan ships, the window stays open, and nothing is red | §3.1's literal annotation (keeps `TransactionManagerArchTest:47-57` in scope), the found-then-assert reflection row in §6.2, the three hand-applied mutants in §9.2, and **D6's rollback integration test**, which observes the committed state rather than inferring it |
| **A vacuous *test*.** A `getDeclaredMethods()` for-each assertion goes green when the method is renamed or absent | The proof surface silently evaporates on the next refactor | §6.2 mandates asserting the method **was found** before asserting anything about it. This repo has been bitten: a for-each test stayed 13/13 green against a gutted interface |

### 8.2 Non-goals — read these before widening the scope.

1. **The bulk batch is not atomic.** F5 makes each *item* atomic; the *batch* is not, and is not intended to be. Nobody should read "atomic" as all-or-nothing across a bulk request.
2. **`transferStock:343`** — `cupsPrint` as the last statement inside a `@Transactional` method. Adjacent, real, **out of scope**.
3. **`MobileCycleCountService:377-378` / `:474-475`** — the same commit-then-validate shape. **Out of scope.**
4. **`bulkAdjustAmount:336`, `bulkAdjustReservedAmount:415`, `UnitLoadController:139`** — the same bulk anti-pattern. **Follow-up, not this ticket.** `bulkTransferStock:241` is out permanently: it is already fixed and `StockUnitControllerUnitTest:498` pins its behaviour per SBDEV-2994.
5. **v1** — the same missing annotations exist there. v1 is reference-only; **no v1 ticket, no v1 plan, no v1 code.**
6. **Full lock-graph normalisation.** Two disciplines now coexist: `StockunitBusinessService:240-243`'s resource-**type** order and D3's resource-**instance** order. Any third path that locks both `location[Damaged]` and `location[src]` must pick one. The eventual fix — hoist the source-location lock into the helper and take both in ascending `location.id` — is **not in this plan**: it takes locations before `:209`'s src-stockunit lock and so inverts against every path that locks a stockunit first, trading a known cycle for an unaudited one.
7. **A first proxied `UnitloadService`.** F1 gives the class its first `@Transactional`, so it becomes a CGLIB-proxied bean for the first time, affecting every site that injects it. Benign — the class is not `final` (`UnitloadService:21`) — and already covered by §5.2's "confirm the Spring context still starts".

**Doc drift to fix alongside** (found during analysis, not part of the code change):

- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` has **no** `StockunitService` boundary coverage at all and is `last_verified: 2026-06-01`, past the 60-day rule in `v2/wms2-api/CLAUDE.md`. That is the document this subsystem points at for exactly this question, and F1 changes its subject matter.
- `ReplenishmentOrderMaintenanceService:133` (a source comment) says the hazard is "most acute when `recalculateForItem` is called from `StockunitService.transferStock`" — `transferStock` no longer calls it.
- `sbdocs/3-Resources/design/wms2-stockunit-design.md` was already corrected on 2026-08-25 (`:140`, `:175`, `:369`, `:599`, `:618`).

**Follow-ups worth a ticket later, deliberately not filed here** (one ticket per fix visit): a lock timeout on the location pessimistic query (§7 row 8); `HttpInTransactionArchTest` not seeing `PrintService.cupsPrint` (§0); the 28 `*IT.java` classes that run in neither lane (§6.1); and the per-id result dialog with CSV export (§3.6 item 6).

---

## §9 — Acceptance & Implementation

### 9.1 Acceptance criteria

Each row is decided by a named §6.2 scenario unless marked otherwise.

- [ ] **F1** — `UnitloadService.moveStockToNewDamagedContainer` is `public`, carries the **literal** `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, and contains `:447-454`'s work including the `QUALITY_FAULT` write.
- [ ] The D3 pre-lock on `location[Damaged]` **precedes every other mocked repository interaction** in the helper.
- [ ] The label is minted **before** the helper is entered, via the `createUnitload(String name, …)` overload (`UnitloadService:132`) — so no `REQUIRES_NEW` sequence write happens inside the boundary.
- [ ] `StockunitService` reaches the helper **cross-bean** via `unitloadService`, never `this.`.
- [ ] Inside the helper, `sendStockChangeMessage` and `cupsPrint` are each `verify(…, never())`; the recalc is pinned separately as an `InOrder` in `StockunitServiceUnitTest`, because `UnitloadService` has no `ReplenishmentOrderMaintenanceService` collaborator and a `never()` there could not fail.
- [ ] **D6: a throw mid-helper leaves zero `unitload` rows in `Damaged`.** Red before F1c, green after, under `mvn verify`.
- [ ] **F2/F3/F4** — `printLabel` is the last statement before `return`; `removeLock` sends exactly once, below the `save`; `adjustAmount`'s lock switch throws before `changeAmount` is called.
- [ ] **F5** — per-item try on all three endpoints catching `NumberFormatException`, `EntityNotFoundException`, `BusinessException`, `FacadeException` **and `org.springframework.dao.DataAccessException`**; every error entry carries the id.
- [ ] Response is `{requested, succeeded}` on total success — **the `errors` key is absent, not empty** (D7) — and `{requested, succeeded, errors[{id, field, message}]}` otherwise. **`succeeded` is a list of id strings, not entities.**
- [ ] `bulkRemoveLock` still passes `parsedId` straight to the service with **no** `findById` lookup, and no endpoint gains an `id.trim()`.
- [ ] `bulkTransferStock`, `bulkAdjustAmount`, `bulkAdjustReservedAmount` and `UnitLoadController:139` are **untouched**, and `StockUnitControllerUnitTest:498` is still green.
- [ ] **Web-UI** — all three actions read `errors` defensively, derive `partial` from `succeeded`, return their result, and fan out one toast per failing id through the **unmodified** `checkResponseError` — with the id folded into `field` API-side, since that helper never reads an `id` key (`commonUtility.js:11`); only failed rows stay selected; `bulkLock`/`bulkUnlock` re-dispatch `searchStockUnit` on any success; Jest pins both deployed-UI shapes.
- [ ] **Process** — no new Flyway migration or schema change; full suite vs. the prereq-9 baseline; `archunit_store` unchanged in git; every new assertion mutation-checked; one independent review pass, no self-approval.

### 9.2 The three F1 mutants

Per **C10**, PIT's operators mutate method bodies and cannot produce any of these; all three are **hand-applied source edits, recompiled**, per `sbdocs/9-System/mutation-testing-recipe.md`. PIT is run in addition, scoped, over the helper's body. Each mutant must turn a test red **for the right reason** — verify the mutant actually landed before trusting the red, and force recompilation (a same-mtime copy is silently skipped).

**D6 is a second, independent killer for mutants 2 and 3 — but NOT for mutant 1 unless D6 also pins the exception type.** Mutant 2 lets a *checked* `BusinessException` commit the half-done work, leaving the `unitload` row → red. Mutant 3 removes the advice entirely, leaving the row → red. **Mutant 1 escapes the zero-rows assertion:** binding the landlord TM leaves the tenant `EntityManager` with no transaction, so D3's pre-lock — the helper's *first* statement — throws `TransactionRequiredException` (`LocationRepository:56-58`, OSIV off at `application.properties:55`) **before** the insert at `UnitloadService:148`. Zero rows in `Damaged`, assertion green, mutant alive. That is why D6 must **also** assert the propagated exception type (`assertThatThrownBy(…).isInstanceOf(BusinessException.class)`) — with that clause mutant 1 is red for the right reason. Mutant 1 keeps its reflection killer regardless, so the contract is not unprotected either way.

| # | Mutant | What it proves | Why a naive test passes it |
|---|---|---|---|
| 1 | Drop `value = "tenantTransactionManager"`, leaving a bare `@Transactional` | The boundary binds the **tenant** TM | It binds the landlord TM instead, so every `net.aim_ai.wms.repo.jpa` call opens its own tenant transaction and the writes commit independently — **the fix is vacuous while the source reads almost correctly** — and it holds a landlord connection from a pool of **2** (`application.properties:46`), which can stall tenant-config lookups app-wide. It also removes the tenant transaction the pre-lock needs: that is *silent to mock-based unit tests* (the point here) but loud in production, where a `PESSIMISTIC_WRITE` with OSIV off and no tenant tx throws `TransactionRequiredException` (`LocationRepository:56-58`). Killers: `TransactionManagerArchTest:47-57` + the annotation-attribute assertion |
| 2 | Drop `rollbackFor` (keep `value`) | Checked exceptions roll the boundary back | The two exceptions are **checked**; Spring's default unchecked-only rule **commits** the half-done work — worse than the bug. Every happy-path test still passes because nothing throws. Killers: the annotation-attribute assertion, and D6 if the injected throw is a checked one |
| 3 | Make the helper package-private | Proxy advice reaches the method | Proxy-mode advice is **public-only**, so the annotation is silently ignored and there is no transaction at all. Compiles; every mock-based unit test stays green. Killers: the reflection assertion on the modifier — which **must** assert the method was found first — and D6 |

**Dropped: the former mutant 4** ("call the helper via `this.`"). It only compiles if the helper is first relocated onto `StockunitService`, so its red is a *compile* error and proves nothing beyond "the test compiles against the chosen design". The cross-bean property stays pinned by `verify(unitloadService).moveStockToNewDamagedContainer(...)` in §6.2. A genuine version exists if wanted — relocate the helper **and** keep a thin `unitloadService` method delegating `this.`-style, which compiles, keeps the verify green and does evaporate the boundary — but it is optional; the three above plus D6 are the contract.

**Scoped PIT commands** (one class at a time — a wide `net.aim_ai.wms.service.*` run was measured aborting or timing out; do not widen):

```bash
export JAVA_HOME=~/.sdkman/candidates/java/21.0.11-ms
export PATH="$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH"
mvn -o test-compile -q     # mandatory, or PIT reports "0 mutation test units"

mvn org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.service.UnitloadService \
  -DtargetTests=net.aim_ai.wms.unit.service.UnitloadServiceUnitTest

mvn org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses=net.aim_ai.wms.service.StockunitService \
  -DtargetTests='net.aim_ai.wms.unit.service.StockunitServiceUnitTest,net.aim_ai.wms.unit.service.StockunitServiceLockOnHoldTxTest,net.aim_ai.wms.unit.service.StockunitServiceAuditCommentClampUnitTest,net.aim_ai.wms.unit.service.StockunitServiceTransferStockDestinationTest,net.aim_ai.wms.unit.service.StockunitServiceTransferStockGuardTest'
```

Neither baseline red (C6) is in scope, so PIT runs today without waiting on SBDEV-3089. Check `git status src/test/resources/archunit_store/` after every run.

### 9.3 No verify script

T3 permits an opt-in ≤15-row acceptance script. **This plan ships none.** Every assertion above is expressible in JUnit or Jest, which run in CI, survive refactors and can be mutation-checked; and the load-bearing properties here — "the annotation carries `value`", "the method is public", "the call crosses a bean boundary" — are exactly the ones a grep-based row reports as green while being wrong. §9.1, §9.2 and D6 are the contract.

### 9.4 Recommended OMC composition

**T3** — data integrity on a stock-lock write path across two repos; the tier is execution risk, not urgency (exposure is nil). Pre-draft was analyst + three parallel lanes (arch / api-enum / ui-consumers) plus a DB probe; plan review was `critic` + `architect` over one ralplan round — both done. Implement with `ralph` as two **independent** clusters (D7 removed the sequencing dependency). Verification is the floor, always: DB query · failing test first · **mutation-check every new assertion** · one independent review · full suite vs baseline — plus D6 under `mvn verify` and a `verifier` lane. `code-reviewer` for review, never self-approve; `git-master` for the commits, since the API side has five logically separable fixes.

### 9.5 Completeness checklist

Per `wms-bugfix-plan/SKILL.md:282-301`. Every row answered; none empty.

| # | Concern | Answer |
|---|---|---|
| 0 | **DB verified** | ✓ §1.3 — live probes on `wms2-wineco-dev` and `wms2-hydra` (prd); frontmatter `db_verified: true`. Independently re-run during review, every number matched |
| 1 | **All callsites enumerated** | ✓ §0 enumerates all five patterns across `src/main`; every in-scope site is addressed in §3.1-§3.6 and every sibling is named with a rationale in the out-of-scope column. One qualifier, matching §0's own wording: the notify-before-save classification of the other 13 `sendStockChangeMessage` sites was **spot-checked, not exhaustively verified** |
| 2 | **Adjacent bugs** | ✓ §0's out-of-scope column + §8.2 non-goals 2-4: `transferStock:343`, `MobileCycleCountService:377-378`/`:474-475`, `bulkAdjustAmount:336`, `bulkAdjustReservedAmount:415`, `UnitLoadController:139` — all found by pattern-grep, all deliberately deferred |
| 3 | **Backward compatibility** | ✓ §2.6 + §5.3 + §3.5. The response shape changes; D7 (omit `errors` when empty) keeps it compatible with the deployed UI in both outcomes, pinned by a §6.2 Jest row and a `jsonPath("$.errors").doesNotExist()` controller row. No DB schema, no persisted state, no mobile/`omsv2-UI` consumer (C3) |
| 4 | **Concurrency** | ✓ §2.1 (the FK `KEY SHARE`→`FOR UPDATE` inversion, D3's pre-lock, and the **named residual ABBA** against `transferStock:274-297`), §7 rows 6 and 8, §8.1 rows 1-2. Optimistic locking is live (C1) and tolerated, not assumed away. Idempotency: `setLockDamaged` is not idempotent; §3.6 item 5 is the guard |
| 5 | **Multi-tenant** | ✓ §7 rows 2 and 7 + the v2-constraint table rows 1-2. The literal `value = "tenantTransactionManager"` pins the tenant TM (mutant 1 proves it); the landlord pool of 2 is untouched; `TenantContext` stays on the request thread — no `@Async`, no job thread |
| 6 | **Error handling** | ✓ Answered in full below the table |
| 7 | **Observability** | ✓ Prereq 8 — watch `40P01` and `ObjectOptimisticLockingFailureException` on `bulkTransferToDamaged` for one week, explicitly as information. No new metric (v2-constraint row 8); F5's per-item catches log nothing new beyond the existing controller logging, and the operator-facing signal is the `errors` entry itself |
| 8 | **Rollback / migration** | ✓ Prereqs 1 and 5 — no Flyway version consumed, no schema change, no backfill (§1.3 measured zero residue on both tenants). No feature flag, no sysprop row (prereq 2). Deploy order: none required (prereq 4, §5.3) |
| 9 | **Test coverage** | ✓ §6.1-§6.5 — named classes and methods in §6.3 (unit, the D6 integration test, Jest), the manual click-path table in §6.4, and §6.5 naming what is deliberately left uncovered |
| 10 | **Cross-version (v1↔v2)** | ✓ §4 — the same defects exist in v1 and v1 is reference-only per the standing instruction: **no v1 ticket, no v1 plan, no v1 code.** No paired plan |

**Row 6 in full — every new throw path has a handler or a documented contract change.** Four kinds of change:

1. **F5's per-item catches replace an aborting outer `try`.** Each catch *is* the handler: `NumberFormatException`, `EntityNotFoundException`, `BusinessException`, `FacadeException` and `DataAccessException` each become one `errors` entry naming the id, and the loop continues. Strictly more is caught than today. The classes F1 makes newly reachable per item (deadlock, lock-acquisition, optimistic-lock) are exactly why the `DataAccessException` clause is mandatory rather than defensive.
2. **Anything still uncaught is a 500 with no per-id detail** — unchanged from today, and accepted (§8.2 non-goal 1). In the *tests* it is worse than a 500: `BaseControllerUnitTest:50-52` installs no `RestExceptionHandler`, so an uncaught exception is a test *error*. That is what makes the new F5 rows red today, and why the catch list must be complete rather than lean on a handler absent from the test context.
3. **F1 changes *when* an existing throw takes effect, not what throws.** `transferStockToUnitLoad` already declared both checked exceptions; the change is that a throw now rolls the container insert back. `rollbackFor` makes that true, mutant 2 proves it, D6 observes it.
4. **F4 changes an error's timing — the one documented contract change on the error side.** `adjustAmount`'s `default: throw` currently fires *after* `changeAmount` commits, so `"value not changed"` is false; after F4 it fires before, so the message becomes true. Same exception type, same message, same inputs — only the side effect disappears.

**Response-shape contract change, for the record:** the lock trio's 200 body goes from a bare `Stockunit` to `{requested, succeeded[, errors]}` — specified in §3.5, compatibility argued in §2.6 / §5.3, pinned by §6.2 rows on both sides.

---

## ADR — SBDEV-3086

**Decision.** Close four non-transactional write windows in `StockunitService` with the smallest boundary that fixes each, and make the three bulk lock endpoints report per-item outcomes. Specifically: (F1) extract `setLockDamaged:447-454` into one tenant-bound `@Transactional` helper on `UnitloadService`, pre-locking `location[Damaged]` and taking a pre-minted label; (F2) make `printLabel` the last statement; (F3) move the OMS send below the `save` in `removeLock`; (F4) hoist `adjustAmount`'s lock switch above `changeAmount`; (F5) per-item try and `{requested, succeeded[, errors[{id, …}]]}` on the lock trio. The two repos are independent and can ship in either order.

**Decisions taken (Nam, 2026-08-25) — settled, recorded, not re-opened.**

| # | Decision | Rationale |
|---|---|---|
| **D1** | The F1 helper lives on **`UnitloadService`** | It already holds every collaborator (`:24`, `:26`, `:28`, `:30`, `:52`, `:58`, `:62`) — zero new injections, zero cycle. `StockunitService` already injects it (`:51`), so the call is cross-bean and the proxy always fires. Placing it on `StockunitBusinessService` would need `UnitloadService`, closing a constructor cycle against `UnitloadService:52` → hard startup failure |
| **D2** | The boundary **includes** the `QUALITY_FAULT` write (`:452-454`) | Stopping at `:451` leaves a *committed* state with damaged stock at `entityLock = NOT_LOCKED` — allocatable and replenishment-visible, i.e. **pickable damaged stock**, worse than the orphan container the ticket names. Both `transferStockToUnitLoad` branches produce it (`StockunitBusinessService:144-146` and `:345-347`, guard at `:294-298`). The sibling `transferStock` already does it inside its tx (`:277` + `:297`). Bonus: the entity stays managed, so `save` becomes a flush and the C1 `OptimisticLockException` window closes |
| **D3** | **Pre-lock `location[Damaged]`, and hoist the label mint** | The boundary otherwise creates an FK `KEY SHARE` → `FOR UPDATE` self-collision on the shared `Damaged` row (`40P01` under concurrent or bulk damage). Pre-locking serializes instead. That in turn would put the `REQUIRES_NEW` sequence write (`SequenceTransactionService:23-24`) inside a lock-holding tx on a second tenant connection, so the mint moves out and the `createUnitload(String name, …)` overload (`UnitloadService:132`) is used. Cost: a harmless `UL######` gap on rollback. **Scope of the claim:** it closes the self-collision only; the cross-path `location[Damaged]` ↔ `location[src]` inversion against `transferStock:274-297` remains and is expected (§2.1, §8.1) |
| **D4** | F5 scope is the **lock trio only** | `bulkTransferToDamaged`, `bulkRemoveLock`, `bulkSetLockOnHold`. `bulkTransferStock` is already fixed and `StockUnitControllerUnitTest:498` pins its abort behaviour per SBDEV-2994 — netting it in fails that pin and would silently supersede a prior decision |
| **D5** | Prove F1 by **mutation** as well as by test | Three hand-applied source mutants (the PIT engine cannot produce annotation or visibility mutants — C10). They cover what no test of behaviour can see: which TM the boundary binds, whether `rollbackFor` names the two checked exceptions, and whether the method is public enough for proxy advice |
| **D6** | **Add a rollback integration test for F1** | The earlier "no integration lane runs at all" premise was wrong (C11): `*IntegrationTest.java` runs under `mvn verify`, and `BaseRollbackIntegrationTest` exists specifically to observe real rollbacks, with three live precedents. `StockunitDamagedRollbackIntegrationTest` throws mid-helper and asserts zero `unitload` rows in `Damaged`. **This makes the F1 proof observational rather than inferential** — a mutant proves a property of the annotation, this proves the committed state. The mutants stay; the two cover disjoint failure modes |
| **D7** | **Omit the `errors` key when the list is empty** | `{requested, succeeded}` on total success; `errors` only when non-empty. `[]` is truthy in JS, so an always-present `errors` would push today's UI into its error branch on success, `results.errors[0].message` would throw a swallowed `TypeError`, and the operator would be told to retry a completed damaged-stock adjustment (§2.6). Omitting the key makes the new response backward-compatible with the deployed UI in both outcomes, which **dissolves the cross-repo merge-order dependency** the earlier draft carried as its one hard constraint |
| **D8** | **Toast fan-out is the default UI surface** | `util/commonUtility.js:4-16` `checkResponseError` already length-guards (`:6-7`) and already renders `errors[i].field` (`:11`) — exactly the shape `AdminController.getErrorMessage:286-291` emits (C7) — so it needs **no change**. ~5 lines against a verified helper satisfies the operator-truthfulness driver. A per-id result dialog with CSV export is a new component plus new spec files and is **demoted to an opt-in follow-up** (§3.6 item 6); for a `normal`-priority fix with nil measured residue that default was backwards. The keep-only-failed-rows rule **stays** — it is the mitigation for §7 row 6's non-idempotent retry |

**Drivers, in priority order.**

1. **Correctness of the committed state.** D2 is the decision that matters most: the window this plan is really closing is *pickable damaged stock*, not the empty container the ticket describes.
2. **No silently-vacuous fix.** Three distinct ways to write F1 that compile, pass every unit test, and do nothing (§9.2) — wrong TM, missing `rollbackFor`, non-public method. The proof surface must target the boundary, not the happy path; D6 adds the one observation that does not depend on reading the annotation at all.
3. **Do not make the operator's error worse.** A bulk endpoint that reports a generic failure with no id invites a retry that double-damages stock. F5 gives the operator per-id truth; D7 makes the new shape safe against the UI that is already deployed; §3.6 item 5 keeps the retry from re-submitting a succeeded id.

**Alternatives considered.**

| Alternative | Verdict |
|---|---|
| Helper on **`StockunitBusinessService`** (the literal reading of the ticket) | **Invalidated.** Needs `createUnitload`; injecting `UnitloadService` closes a constructor cycle with `UnitloadService:52`, and `spring.main.allow-circular-references` is set nowhere → hard startup failure, not a warning |
| Helper on **`StockunitService`** via an `@Lazy` self-proxy | Viable, repo-precedented (`ReplenishmentOrderMaintenanceService:80-82`). Rejected: a self-proxy hop is load-bearing and invisible, and a later refactor to `this.` re-breaks the fix with a green suite. D1's cross-bean call has no such failure mode and is pinned by a `verify` |
| Use **`@TenantTransactional`** rather than the literal annotation | Rejected. Zero `src/main` usages (only a javadoc self-reference at `TenantTransactional.java:21`); `TransactionManagerArchTest:47-57` uses `areAnnotatedWith`, not `areMetaAnnotatedWith`, so it would ship with no ArchUnit backstop; mutant 2 is inapplicable to it; and a naive `getAnnotation(Transactional.class)` returns null on it, making the §6.2 assertion either red on correct code or vacuous. See §3.1 |
| Response with **`errors: []`** always present | Rejected — this is what D7 replaces. `[]` is truthy, so `if (results.errors)` at `stockUnits.js:237`/`:254`/`:330` takes the error branch on total success, `results.errors[0].message` throws a `TypeError`, the outer `catch` swallows it, and the operator is shown *"Request failed… Please retry"* **after a successful write** — a second damaged-stock adjustment on `bulkTransferToDamaged`. It is a cleaner contract in the abstract, but it buys that cleanliness with a cross-repo deploy-order dependency on a `normal`-priority fix |
| Ship **F3 + F4 + F5 only**, defer F1/D2/D3 | Considered. F1 is the only part that introduces new lock contention and protects a path with zero measured incidents (§1.3), so a split is arguable. Rejected: F1 is the correctness core — *pickable damaged stock* is driver 1 — and D6 removes the only real reason to defer it (that it could not be proven). The contention cost is bounded and the path is unused where it would bite |
| **Prove F1 by mutation only**, no integration test | Rejected — superseded by D6. It rested on "no integration lane runs at all", which is false (C11), and no mutant can show that the committed state after a mid-helper throw is clean: a perfect annotation can still coexist with a half-written state via propagation or a detached `merge` |
| A **new leaf bean** (`DamagedStockAtomicService`) | Viable and the cleanest boundary — nothing injects it, so no cycle. Rejected on cost: it duplicates six collaborators `UnitloadService` already has, plus a class and a test class for one method |
| `@Lazy UnitloadService` into `StockunitBusinessService` | Rejected. Works, but re-forms the cycle behind a proxy on a bean ~20 services depend on, and contradicts the in-repo warning at `PickLineRealignmentService:29-38` |
| Wrap **all** of `setLockDamaged` in `@Transactional` | Rejected. Pulls `triggerReplenishmentMaintenance(:465)` into the shared tx and lights up the `ReplenishmentOrderMaintenanceService:128-135` rollback-only landmine; pulls `printLabel(:463)` — a sysprop read, a render and a CUPS call — inside the `Damaged`-location lock; and defers the `:461` send. Strictly worse than the scoped helper |
| **Compensating delete** in a `catch` | Rejected. The compensation is itself a non-transactional write that can fail, cannot run if the JVM dies, and cannot tell the container it just created from one `findByLabelid` returned because it already existed (`UnitloadService:136-139`) — deleting that one destroys live data |
| **Reuse an existing damaged unit load** | Rejected. Dissolves the problem, but `:445-447` deliberately always creates a fresh Box-type UL per SBDEV-1953 and SBDEV-1746. Out of scope |
| **Accept the `40P01`** instead of D3's pre-lock | Defensible — PostgreSQL detects it, the rollback is complete, and the sibling `transferStock` path already carries the same shape in production. Rejected because `bulkTransferToDamaged` multiplies the *self*-collision windows per request. Note the plan accepts the residual cross-path inversion on exactly this reasoning (§2.1); D3 buys the high-frequency half, not the whole class |
| **Extend the instance order** — hoist the source-location lock into the helper, both locations in ascending `location.id` | Would close the residual inversion completely. Rejected for now: it takes locations before `StockunitBusinessService:209`'s src-stockunit lock, inverting against every path that locks a stockunit first, i.e. it trades a known, PostgreSQL-resolved cycle for an unaudited one. Needs a full lock-graph pass — §8.2 non-goal 6 |
| A **bounded per-item retry** for the deadlock loser | Rejected for this ticket. It would hide the residual `40P01` rather than surface it, and a retry of a non-idempotent operation needs a correctness argument this plan has not made. F5's `DataAccessException` clause gives the operator the id instead, which is the safe half |
| A **verify script** as the acceptance gate | Rejected. Every property here is expressible in JUnit/Jest, and the load-bearing ones (annotation attributes, method visibility, cross-bean dispatch) are exactly what a grep row reports green while being wrong |

**Consequences.**

- `UnitloadService` gains its first transaction boundary, and with it becomes a CGLIB-proxied bean for the first time — benign (`UnitloadService:21` is not `final`), covered by §5.2's context-startup check. Anyone adding a second `@Transactional` there must carry `value = "tenantTransactionManager"` or `TransactionManagerArchTest` reds the build.
- All mark-damaged operations warehouse-wide now serialize on one `location` row for the length of the helper. They already serialized on it inside `transferStockToUnitLoad`; the added contention is a handful of INSERTs. `LocationRepository:51-54` has no lock timeout, so that wait is unbounded under contention — accepted, recorded as a follow-up.
- Two lock-ordering disciplines now coexist in the same call chain: `StockunitBusinessService:240-243`'s resource-**type** order and D3's resource-**instance** order. A residual `40P01` is an expected outcome, not a defect (§2.1, §8.1). Any third path locking both `location` rows must pick one.
- The three trio endpoints' response shape changes from a bare `Stockunit` to a result map. No API test asserts the success body and the web-UI reads no field off it; D7 keeps it compatible with the deployed UI, but the shape is now a contract two repos share.
- F1's correctness rests on the annotation mutants **plus** an observed rollback (D6), which is the strongest proof available without a PostgreSQL integration lane. What remains unprovable in-repo is the concurrency half — H2 does not reproduce `SELECT … FOR UPDATE` **lock semantics** (`StockunitBusinessServiceConcurrencyIT:20`).

**Follow-ups.**

1. `bulkAdjustAmount`, `bulkAdjustReservedAmount`, `UnitLoadController:139` — same bulk anti-pattern; adopt this plan's response shape.
2. A lock timeout for the location pessimistic read (new dedicated query, not the shared `LocationRepository.findByIdForUpdate`, whose three `src/main` call sites are `StockunitBusinessService:250`, `:290`, `UnitloadBusinessService:163`).
3. `transferStock:343` — `cupsPrint` inside a transaction; and `HttpInTransactionArchTest`'s blind spot for `PrintService`.
4. `MobileCycleCountService:377-378` / `:474-475` — commit-then-validate.
5. The 28 `*IT.java` classes that run in neither lane (§6.1) — rename to `*IntegrationTest` or widen failsafe's `<includes>`.
6. `wms2-transaction-osiv-boundary-map.md` — add `StockunitService` coverage and re-verify; fix the stale comment at `ReplenishmentOrderMaintenanceService:133`.
7. The per-id result dialog with CSV export (§3.6 item 6), if operators ask for it.


---

## §10 — Implementation Status (2026-08-26)

**MERGED, deployed to dev, and live-verified. Archived 2026-08-26.**
*(This block previously read "Both PRs open. Not merged, not deployed" — that was true when written earlier the same day and was corrected at archival.)*

| | |
|---|---|
| API PR | [#198](https://github.com/SiteBossInc/wms2-api/pull/198) → `develop` — **MERGED** `206ad9ed`, 2026-08-26 13:30Z |
| Web-UI PR | [#79](https://github.com/SiteBossInc/wms2-web-ui/pull/79) → `develop` — **MERGED** `d3fb6ac`, 2026-08-26 13:31Z |
| Follow-up PR | [#203](https://github.com/SiteBossInc/wms2-api/pull/203) → `develop` — **MERGED** `98060c99`, 2026-08-26 14:09Z — D8 regression pin, see §3.5's correction note and C13 |
| Branch (both) | `bugfix/SBDEV-3086-stockunit-nontransactional-write-paths` — deleted at archival |
| Worktrees | removed 2026-08-26: `.claude/worktrees/{wms2-api,wms2-web-ui}/SBDEV-3086` and `wms2-api/SBDEV-3086-field-fix`. All gates passed (PR merged, tree clean, nothing unpushed) |

### Live verification on dev (2026-08-26)

Tenant `wineco` / facility `wsl` → DB `dev_wh01_om1`, via real Keycloak tokens.

- **F5 partial success, with a real write.** `bulkSetLockOnHold` with `988306832,abc,999999999` → HTTP 200,
  `{requested:3, succeeded:["988306832"], errors:[Invalid ID Format/abc, Entity Not Found/999999999]}`.
  DB confirmed the surviving write committed: `stockunit 988306832` `entity_lock` 0→104, `version` 0→1.
  Restored via `bulkRemoveLock`; `entity_lock` back to 0, `amount`/`reservedamount` untouched, exactly one
  row modified in the window. (`version` is now 2 — inherent to optimistic locking, not restorable.)
- **The pre-fix behaviour was also measured**, before the deploy landed: the same request returned
  **HTTP 500**. Note what that meant operationally — with the real id first, the lock **committed** and the
  operator still saw a 500. F5 closed a silent-write defect, not just poor ergonomics.
- **D7 confirmed live**: the total-success restore returned no `errors` key at all, not an empty array.
- **Gates enforced** on all three endpoints: `panderson` (80 fns) 200 · `sbtest` (35 fns) 200 ·
  `truckloading` (4 `MOBILE_UI_*` fns) **403**.
  ⚠️ **`sbtest` is NOT a negative case here** — the group→role→function chain shows it holds all three of
  `WEB_UI_ACTION_ADJUST_LOCK_{ON_HOLD,DAMAGED,RELEASE_LOCK}`. Written as "sbtest → expect 403", the 200
  would have read as a gate bypass. The genuine negative is `truckloading`, which also happens to share the
  dev password; `josiemarks`/`estellavasquez` lack the functions but do not share it.

### Findings disposition at archival (2026-08-26)

Per `archive-plan` step 3b — nothing below is left as "recorded in the plan":

| Finding | Disposition |
|---|---|
| Landmines #1 (failsafe `Tests run: 0` false green) and #2 (`AdviceServiceRollbackIntegrationTest`'s inert `los_sequencenumber` pre-seed) | **On a ticket** — widened **SBDEV-3091**, which already owns the "IT runs in neither Maven lane" code path. Not filed as a sibling |
| The **6 Low** code-reviewer findings, "deferred" | **Dropped**, with reason: judged not worth a return visit; they are recoverable from PR [#198](https://github.com/SiteBossInc/wms2-api/pull/198)'s inline comment thread if that judgement is revisited |
| §3.5's snippet vs. what shipped (id folded into `field`) | **Fixed** — regression pin in PR #203, plus §3.5's correction note and **C13**. Mutation-checked: deleting the interpolation fails exactly that one test |
| `bulkTransferToDamaged` returns **500** when `amount` is omitted — `Integer.parseInt(null)` throws, then the catch calls `Double.parseDouble(null)` which NPEs uncaught at `StockUnitController:572-573`, before the F5 loop | **Dropped**, with reason: pre-existing, outside D4's scope, and unchanged by this plan. Same unguarded-input→opaque-500 class F5 fixed for ids, one field over. Found in today's live test; no ticket, per the one-ticket-per-fix-visit cap |
| The 2 verifier **PARTIAL** items | **Dropped** — neither is a defect (already recorded in §Review below) |
| The 23 unchecked `- [ ]` boxes in §5.2 and §9.1 | **Stale bookkeeping, not open work.** They were never ticked; the authoritative evidence is this §10's *Tests*/*Review* subsections plus the live verification above. Left unticked deliberately rather than back-ticked by someone who did not witness each run |

### Commits

| SHA | Repo | Subject |
|---|---|---|
| `024159b9` | wms2-api | `test(SBDEV-3086)` — the 25 failing gate tests, no `src/main` change |
| `6c4f1f0d` | wms2-api | `fix(inventory)` — F1–F5 + the D6 rollback IT |
| `39feffae` | wms2-api | `fix(review)` — M1/M2/M3 |
| `9fa83b3` | wms2-web-ui | `fix(handling-units)` — §3.6 items 1–5 + both new specs |

### Tests

- API targeted: **222 pass, 0 red** (incl. `TransactionManagerArchTest`).
- `StockunitDamagedRollbackIntegrationTest`: **1 pass**, ~22 s, real Spring/H2 boot.
- API full suite: **5619 run, 2 failures** — the two known baseline reds (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`, SBDEV-3089). Identical to the pre-change baseline.
- Web-UI: **647 pass, 0 fail** (was 634). Failed *suites* 3 → 2, the known always-red pair with 0 failing tests.
- **6 mutation checks, all red for the right reason** — the three §9.2 F1 mutants plus three on the new behavioural assertions (`setAdditionalcontent`, `QUALITY_FAULT`, pre-lock order).
- No verify script, per §9.3.

### Review

verifier **PASS** (11/13 VERIFIED, 0 MISSING, 2 PARTIAL — neither a defect). code-reviewer: **3 Medium fixed, 6 Low deferred** (posted as inline PR comments).

- **M1** (design, decided by Nam): a print failure was marking a *committed* damage transfer as failed, and keep-only-failed-rows then selected that row for retry against a non-idempotent operation. Now swallowed and warned. The gate test that pinned propagation was updated to the new contract.
- **M2**: `TransactionException` is a **sibling** of `DataAccessException`, not a subclass — pool exhaustion still aborted the batch. Added `catch (RuntimeException)`.
- **M3**: the `DataAccessException` clause discarded the exception; no trace for the `40P01` §7 row 8 asks operators to watch. Now logged.

### Landmines found during implementation, not predicted by the plan

1. **`mvn failsafe:integration-test -Dit.test=<Class>` reports `Tests run: 0` and BUILD SUCCESS** — a false green. `mvn test -Dtest=<Class>` overrides surefire's `*IntegrationTest` exclude and actually runs it.
2. **`landlord.datasource.auto-commit=false` (`application.properties:51`) makes the `AdviceServiceRollbackIntegrationTest:99-106` `los_sequencenumber` pre-seed recipe a silent no-op** — a plain `JdbcTemplate.execute("INSERT …")` raises no error but Hikari rolls it back on connection return. Needs an explicit `conn.commit()`. **The existing pre-seed in `AdviceServiceRollbackIntegrationTest` is therefore also inert** — not failing today, but its comment overstates what it does. Worth a follow-up.
3. `Location`, `Itemdata`, `UnitloadType` and `Boxtype` each carry many `@NotNull` fields whose violations surface at **commit**, not at `save()`, as `TransactionSystemException` several statements later — budget for it when seeding this lane.
4. `wms2-web-ui` `develop` moved twice during this ticket (C12), and `test/store/` already held two specs for this module (C13). Both corrections are in the Corrections table.

### Deliberately not done

D6 does not observe D3 (its H2 schema has no FKs, so the `KEY SHARE` story is untestable there); no concurrent-deadlock reproduction; the six deferred Lows; and the three sibling bulk endpoints (`bulkAdjustAmount`, `bulkAdjustReservedAmount`, `UnitLoadController:139`) remain on the old abort-the-batch shape by design (D4).
