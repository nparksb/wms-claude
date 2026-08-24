---
title: "WMSv2: the 8 WEB_UI_ACTION_* constants gate nothing — 15 destructive write endpoints are open to every wms_user"
ticket: "SBDEV-2967"
ticket_url: "https://app.clickup.com/t/868krr3rq"
type: "bugfix"
priority: "high"
status: "✅ MERGED + DEPLOYED to WineCo dev 2026-08-22. api [#185](https://github.com/SiteBossInc/wms2-api/pull/185) merged `9fa2f1d` FIRST, then web-ui [#73](https://github.com/SiteBossInc/wms2-web-ui/pull/73) merged `b499fb9`; both dev deploys succeeded. **V2.2.21 applied `success=true` at 14:48:21** on `dev_wh01_om1` — RENUMBERED from V2.2.20 because SBDEV-3010 (PR #184) merged first holding that version; see §0.J. Grants verified against the §2.6 table exactly: the 5 adjust/lock functions reached `inventory-manager`, and `DELETE_UNIT_LOAD`/`_RECURSIVE` leaked to NO non-super-admin role. Live dev bundle carries `canPerformAction` and both `WEB_UI_ACTION_*` constants. Results at merge: api 5458 run / 2 failures at the known develop baseline; web-ui 595 passed / 0 failing; verify script 44 pass, 0 fail, 1 skip. Reviewed by 3 lanes over 2 passes each (§0.I) — 9 defects found in the implementation, all fixed and individually mutation-checked. ✅ **API-half manual QA COMPLETE live on dev 2026-08-22 (§0.K), BOTH directions: as a caller holding nothing, all 13 return 403 with the correct per-endpoint constant, and bulk returns 403 not 200-with-errors (C-3 proven live); after granting the same principal `inventory-manager`, C.1-C.10 return 404 (gate PASSED) while C.11-C.13 still 403 — so the §2.6 grant table is enforced end to end and V2.2.21 is functional. transferStock still denies on 2968's VIEW function (C-10). Zero data mutated.** 🔴 STILL OPEN: the UI half of manual QA (§4.4) — including one screenshot of the row-action dropdown, since the tooltip wrapper and its `flex-grow-1` were never seen rendered.** Only WineCo dev has V2.2.21: UAT tenants are at 2.2.17 and PRD at 2.2.16, so a prd promotion applies 2.2.17→2.2.21 in sequence. Pre-existing findings tracked elsewhere: S-1 + S-2 on [SBDEV-3017](https://app.clickup.com/t/868kufdy1) (raised to high), the Cypress principal on [SBDEV-3062](https://app.clickup.com/t/868kv11ed). This slice closes the AUDITED ROUTE, not the capability. NOT archived — archive only after manual QA."




project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-16
updated: 2026-08-22
db_verified: true
related:
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2967-A-axios-403-denial-not-logout.md
  - SBDEV-2967-B-web-view-gating.md
  - SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
tags:
  - plan
  - security
  - authorization
---

# SBDEV-2967-C — Server-side gates for the 8 `WEB_UI_ACTION_*` constants

**Ticket:** [SBDEV-2967](https://app.clickup.com/t/868krr3rq) · **slice C of 3** (see the [index](SBDEV-2967-web-ui-function-gating-enforcement.md))
**Repos:** `v2/wms2-api` (primary) · `v2/wms2-web-ui` (control disabling)
**Tier:** T3 · **Blocked on:** slice A, P2-ACTION · **Independent of:** slice B

> **Why this is separate from slice B.** Opposite failure modes and a deploy-order constraint between them.
> A hidden menu item is loud, immediate and revertible by a UI image rollback. A 403 on a button the operator
> can still see is **silent until someone needs it** — and until [slice A](SBDEV-2967-A-axios-403-denial-not-logout.md)
> lands, that 403 logs them out instead of telling them anything. The two also need different Brent
> decisions: slice B asks *who owns master data*, this asks *who may destroy stock*.

---

## 0. The surface

### 0.A The 8 `WEB_UI_ACTION_*` constants — 1 enforced, 3 misused

| Constant | Backend reference | Actually enforced? |
|---|---|---|
| `ADJUST_LOCK_DAMAGED` | `StockunitService:232`, `service/mobile/MobileMoveStockService:252,257`, `service/mobile/MobileMoveUnitloadService:303,308` | ⚠ **partially — see §0.E** |
| `DELETE_UNIT_LOAD` | `UnitLoadController:100, :134` | ❌ **no — passed as the `comment` argument** (§0.D) |
| `DELETE_UNIT_LOAD_RECURSIVE` | `UnitLoadController:163` | ❌ **no — same** |
| `ADJUST_AMOUNT`, `ADJUST_RESERVED_AMOUNT`, `ADJUST_LOCK_RELEASE_LOCK`, `ADJUST_LOCK_ON_HOLD`, `PRINT_TOTE_LABELS` | seed only | ❌ none |

**The 8 constants resolve to 15 write endpoints across 5 controllers, not 8.**

### 0.B `StockUnitController` — **0 of 16 guarded**; Fix E's target is the 10 rows marked ⬛

Enumerated 2026-08-17 on the SBDEV-2870 branch; **re-confirmed on `origin/develop` `5506117` 2026-08-21** —
the only `@RequiresFunction` annotations on this class are `transferStock` (`:93`) and
`storageLocationsForStockMovement` (`:595`), both `MOBILE_UI_VIEW_STOCK_TRANSFER` ANY-of from SBDEV-2968.
**None of the action endpoints below is gated.**

| # | Endpoint | Method | Guard today | Fix E target |
|---|---|---|---|---|
| C.1 ⬛ | `POST /v3/stockUnit/transferToDamaged` | `transferToDamaged` (`:444`) | ❌ **none** | `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` — **received from SBDEV-2870, design proven (§3)** |
| C.2 ⬛ | `POST /v3/stockUnit/bulkTransferToDamaged` | `bulkTransferToDamaged` (`:485`) | ❌ **none** | same — **received from SBDEV-2870** |
| C.3 ⬛ | `POST /v3/stockUnit/adjustAmount` | `adjustAmount` | ❌ **none** | `WEB_UI_ACTION_ADJUST_AMOUNT` |
| C.4 ⬛ | `POST /v3/stockUnit/bulkAdjustAmount` | `bulkAdjustAmount` | ❌ **none** | same |
| C.5 ⬛ | `POST /v3/stockUnit/adjustReservedAmount` | `adjustReservedAmount` | ❌ **none** | `WEB_UI_ACTION_ADJUST_RESERVED_AMOUNT` |
| C.6 ⬛ | `POST /v3/stockUnit/bulkAdjustReservedAmount` | `bulkAdjustReservedAmount` | ❌ **none** | same |
| C.7 ⬛ | `POST /v3/stockUnit/setLockOnHold` | `setLockOnHold` | ❌ **none** | `WEB_UI_ACTION_ADJUST_LOCK_ON_HOLD` |
| C.8 ⬛ | `POST /v3/stockUnit/bulkSetLockOnHold` | `bulkSetLockOnHold` | ❌ **none** | same |
| C.9 ⬛ | `POST /v3/stockUnit/removeLock` | `removeLock` | ❌ **none** | `WEB_UI_ACTION_ADJUST_LOCK_RELEASE_LOCK` |
| C.10 ⬛ | `POST /v3/stockUnit/bulkRemoveLock` | `bulkRemoveLock` | ❌ **none** | same |
| — | `transferStock` (`:93`), `getStorageLocationsForStockMovement` (`:595`) | | ✅ 2968 ANY-of `{MOBILE_UI_VIEW_STOCK_TRANSFER, WEB_UI_VIEW_STOCK_UNIT}` | **leave alone** — a WEB_UI-only gate here 403s mobile Move Stock. ⚠ The **method** is `getStorageLocationsForStockMovement`; `storageLocationsForStockMovement` is the **URL path**. Keying a test or a verify row on the path name is a permanent red that reads as work-not-done. |

### 0.C `UnitLoadController` — **0 of 9 guarded**

Enumerated 2026-08-17, per-method (a first pass with a 50-line window mis-attributed a delete constant to
`/reprintLabel`; corrected below).

| # | Endpoint | Method | Constant in body | Service called | Fix E target |
|---|---|---|---|---|---|
| C.11 ⬛ | `POST /v3/unitLoad/deleteContainer` | `deleteContainer` | `DELETE_UNIT_LOAD` — **as the `comment` arg** | `deleteUnitLoad` | `WEB_UI_ACTION_DELETE_UNIT_LOAD` |
| C.12 ⬛ | `POST /v3/unitLoad/bulkDeleteContainer` | `bulkDeleteContainer` | `DELETE_UNIT_LOAD` — same | `deleteUnitLoad` (loop) | same |
| C.13 ⬛ | 🔴 `GET /v3/unitLoad/deleteContainerRecursive/{id}` | `deleteContainerRecursive` | `DELETE_UNIT_LOAD_RECURSIVE` — same | `deleteUnitLoadRecursive` | `WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE` |
| — | `POST /v3/unitLoad/reprintLabel` | `reprintLabel` | — (clean) | `reprintLabel` | none — not a listed constant |
| — | 5 × `GET` detail/search endpoints | | — | | `WEB_UI_VIEW_CONTAINER` — **view follow-on, SBDEV-3017** |

Three things:

1. 🔴 **`deleteContainerRecursive` is a `GET` that recursively deletes a container and its children**
   (`:154`). Independent of authorization that is wrong: GETs are prefetchable, link-previewable, and land in
   access logs and browser history. **Not this slice's job to change the verb** — but a gate on a GET is
   weaker than a gate on a POST, and it should be recorded.
2. **All three delete endpoints pass the constant as the `comment` argument** —
   [SBDEV-2979](https://app.clickup.com/t/868kt336b). §2.4's warning applies verbatim: **do not repurpose
   that argument as the gate.**
3. `:156` logs `"start reprintLabel unitload={}"` inside `deleteContainerRecursive` — cosmetic copy-paste,
   but it is the lineage that produced the constant-as-comment defect.

### 0.D ⚠ The delete constants are being written into the audit trail

`UnitloadService.deleteUnitLoad(Unitload unitLoad, **String comment**, boolean notifyCRM, Principal principal)`
— the second parameter is the operator's **comment**, not a function name. `UnitLoadController:100/:134/:163`
pass a `FunctionEnum` constant into it, so every web-initiated container deletion records the literal string
as its audit reason, and ships it to OMS via `sendStockChangeMessage`.

**Confirmed on WineCo dev: 478 `stockrecord` rows** with
`additionalcontent = 'WEB_UI_ACTION_DELETE_UNIT_LOAD'`, `activitycode = 'MANUAL_REMOVAL'`, across 5 operators
(`mcervone` 210, `adampetersen` 148, `adriantorres` 78, `bcampbell` 23, `nathanquintanilla` 19),
2025-02-04 → 2025-04-22.

**Out of scope here** — a data-quality bug, not an authorization one — but recorded because it is the trap
that makes those two constants *look* enforced at the call site.

### 0.E 🔴 The one guard everyone believes exists is narrower than claimed

`StockunitService:262` — **was `:232` before 2968; every `StockunitService` line number quoted in this plan is from the pre-2968 tree** — is inside **`transferStock`**, in a conditional branch (destination `DAMAGED`
**and** lock `QUALITY_FAULT`). **`setLockDamaged` (`:360`) has no guard at all** — verified: no
`doesUserHaveAccess` anywhere in that method — and it is reached by `POST /transferToDamaged`
(`StockUnitController:416`) and `/bulkTransferToDamaged` (`:457`).

So the dedicated endpoints for the *one action everyone believes is enforced* are **open today**. Two
consequences:

- 🔴 **`setLockDamaged` must NOT be treated as an "existing guard, regression pin only."** Following that
  instruction pins a guard that does not exist and ships `/transferToDamaged` open. **The pre-split verify
  script does exactly this** — row `E8` reads *"ADJUST_LOCK_DAMAGED enforcement is UNCHANGED (regression
  pin)"*. That row is deleted, not carried over.
- The figure "1 of 80 functions is enforced" needs this footnote: it is one function checked in **one
  conditional branch of one unrelated method**, while that same action's own endpoints are ungated.

### 0.F `PRINT_TOTE_LABELS` — the constant has no consumer at all

It appears in exactly two places: its declaration (`WmsConstants:417`) and the `super-admin` seed
(`UtilRestController:413`). **No controller and no service references it.** Meanwhile tote/label printing is
spread across **three controllers**:

| # | Endpoint | Controller |
|---|---|---|
| C.14 ⬛ | `POST /v3/dashboard/printToteLabels` | `DashboardController:71` |
| C.15 ⬛ | `POST /v3/report/reprintLabels` | `ReportController:306` |
| C.16 ⬛ | `POST /v3/labelPrinting/totes/generate` | `LabelPrintingController:171` |
| C.17 ⬛ | `POST /v3/labelPrinting/totes/reprint` | `LabelPrintingController:180` |
| — | 3 × `GET` (`totes`, `preview/tote`, `types`) | `LabelPrintingController:86, :143, :212` — reads |

⚠ **So "gate `PRINT_TOTE_LABELS`" is not one annotation — it is a scoping decision across 4 write endpoints
in 3 controllers.** Two sub-questions the implementer cannot answer alone:

- Is `DashboardController:71` (the Pick&Pack monitor's print button) the same *capability* as
  `LabelPrintingController`'s generate/reprint pair, or a separate feature deserving its own constant?
- `ReportController:306 /reprintLabels` is reached from the Parcel Picking report, whose own menu function is
  **undecided** (slice B §7.2). Gating it here couples two open decisions.

**Decision: `PRINT_TOTE_LABELS` is deferred to a tranche C2.** The other seven constants have a clean
single/bulk shape on two controllers; this one does not, and bundling it holds up the rest. **Tranche C1 is
the 13 endpoints C.1–C.13.**

---

---

### 0.G 🔴 Re-validation against `develop` `d70204c` — 2026-08-22

This plan was verified against `develop` `5506117`. Develop has since taken SBDEV-2984, 3011, 3012, 3013 and
2967-B. Everything in §0.A–§0.F **still holds** — re-measured below — but five things changed, one of which
makes an acceptance criterion unachievable as written.

**Confirmed unchanged on `d70204c`:**

| Claim | Result |
|---|---|
| §0.B StockUnitController has exactly 2 `@RequiresFunction`, both mobile ANY-of | ✅ lines 93 and 595, unchanged |
| §0.C UnitLoadController has **zero** | ✅ zero |
| All 10 StockUnitController targets exist, all `POST`, all ungated | ✅ `adjustAmount` :226, `bulkAdjustAmount` :263, `adjustReservedAmount` :306, `bulkAdjustReservedAmount` :341, `setLockOnHold` :381, `bulkSetLockOnHold` :409, `transferToDamaged` :442, `bulkTransferToDamaged` :479, `removeLock` :521, `bulkRemoveLock` :546 |
| §0.C 3 delete endpoints, `deleteContainerRecursive` still a **GET** | ✅ :89, :119, :154 — all three still pass the constant as the `comment` arg |
| §2.2 **fact 1** — a bulk path returns `ResponseEntity.ok(errorMap)` on `BusinessException` | ✅ re-read at `bulkAdjustAmount` :291-300. *A service-layer guard really would return HTTP 200.* |
| §0.E `setLockDamaged` has **no** guard | ✅ the only `doesUserHaveAccess` in `StockunitService` is :262, inside `transferStock` (156→327). `setLockDamaged` is :390. **C-R5 is live; the old E8 pin must not be carried.** |
| §2.7 **G-1** no `controller/rest/*` carries `@RequiresFunction` | ✅ holds today |
| Guard infra (`RequiresFunction`, `FunctionGuardInterceptor`, `FunctionGuardStartupAssertion`) | ✅ all present |

**🔴 F1 (High) — AC C-6 is not achievable, and "add to the golden map" is dangerously ambiguous.**
`FunctionGuardStartupAssertion.findUnannotatedGuardedHandlers(handlers, guarded)` only inspects handlers
**whose declaring class is in `GUARDED`**. `GUARDED` today is 13 classes (11 mobile + `UserRoleController`,
`UserGroupController`); **neither** `StockUnitController` nor `UnitLoadController` is in it. And they must not
be added — `StockUnitController:69-73` records the SBDEV-2968 decision verbatim:

> *"Gated even though StockUnitController is NOT in FunctionGuardInterceptor.GUARDED: the interceptor
> resolves a METHOD-level @RequiresFunction before it consults that set… adding it to GUARDED would fail
> closed on all ~40 of its endpoints, several of which serve the web UI."*

Confirmed against the interceptor: `FunctionGuardInterceptor:124-133` denies fail-closed when the annotation
is absent **and** the class is in `GUARDED`. Adding either controller would 403 its unannotated read handlers
(`getDetailView`, `stockunitDetailsById`, `isUnitLoadIdValid`, and UnitLoadController's 6 GETs) — breaking the
Stock Units and Containers pages for everyone.

**Consequences:**
- **C-6 ("removing any one annotation fails bean initialisation") is struck.** No bean-init protection is
  available for these two controllers without the GUARDED membership that is forbidden.
- **C-5's "golden map" means the `FunctionGuardArchTest` map, NOT `GUARDED`.** State it explicitly. The
  replacement anti-drift rule is an ArchUnit test that **enumerates the 13 endpoints by name + parameter
  arity** and asserts each resolves a `@RequiresFunction`. That is the only mechanism left, so it carries the
  whole anti-drift burden and must itself be mutation-checked.

**🔴 F2 (High) — the deny/allow pair is vacuous unless it uses the right helper.** §4.2's stated landmine —
the class-wide `lenient()` stub in `StockUnitControllerUnitTest.setUp` — **does not exist on `develop`**; it
lived on the unmerged SBDEV-2870 branch. `StockUnitControllerUnitTest` contains no `lenient` at all, so
**C-R6 as written is not live.** The real landmine is the inverse and worse:
`BaseControllerUnitTest.setupMockMvc` installs **no interceptor**, so `@RequiresFunction` is **completely
inert** under it. Only `setupMockMvcWithGuard(controller, interceptor)` (:95) exercises a gate — it is
documented as *"the one MockMvc mode in which authorization can actually be exercised in this repository"*
and is **strictly additive**, so the 6 pre-existing StockUnitController tests will NOT break.
**A deny/allow pair written with plain `setupMockMvc` passes on an ungated controller.** Reference impl:
`unit/controller/mobile/FunctionGuardMockMvcUnitTest`.

**F3 (Medium) — P6 is stale: the Flyway head is now `V2.2.19`, not `V2.2.18`.** 2967-B's
`V2.2.19__seed_web_view_function_grants.sql` merged as `d70204c` on 2026-08-22 and is applied on WineCo dev.
**The ACTION grant migration is `V2.2.20`.** Re-swept across all 40+ remote branches 2026-08-22: V2.2.19 is
the unique maximum, so V2.2.20 is free at the moment of writing. Re-sweep again at PR time.

**F4 (Low, but it silently false-greens a verify row) — §2.3 property 4's file paths are wrong.**
`Authority.java` is at `net/aim_ai/wms/Authority.java` (**not** `security/`) with the constant at **:99**;
`SecurityConfiguration.java` is at `net/aim_ai/wms/SecurityConfiguration.java` (**not** `config/`) with the
exposure at **:193-194**; the interceptor emits at **:191**, not :184. A verify row naming the plan's paths
hits a missing file — and the template's perl helpers **exit 0 on a file they cannot open**, so C-7 would
report PASS while asserting nothing. Use the real paths.

**F5 (Medium, new) — `getStorageLocationsForStockMovement` is an OVERLOADED name.** It is declared twice on
`StockUnitController`: :598 (no-arg, `GET /storageLocationsForStockMovement`) and :608
(`@PathVariable labelId`, `GET /isUnitLoadIdValid/{labelId}`) — the second is a copy-paste name. §0.B already
warns that the *path* differs from the *method*; the overload is a second, sharper trap. **C-10's regression
pin and F1's ArchUnit rule must key on name + parameter arity**, or they will match the wrong overload and
pass while the intended method is unguarded.

**✅ P4 DISCHARGED for WineCo dev — 2026-08-22.** 180-day `stockrecord` audit over
`MANUAL_ADJUSTMENT`/`MANAGE_INVENTORY`/`DAMAGED`/`MANUAL_REMOVAL`, joined to held functions through **both**
grant paths (direct `mywms_user_mywms_role` ∪ group→role):

| Operator | Rows | Last used | `WEB_UI_ACTION_*` held | Verdict |
|---|---|---|---|---|
| `panderson` | 187 | 2026-08-21 | **8 of 8** (80 functions — super-admin) | ✅ unaffected |
| `midnight.p` | 2 | 2026-06-03 | **8 of 8** | ✅ unaffected |
| `anonymous` | 15 | 2026-05-21 | **0** | ✅ **not reachable through the gated endpoints — see below** |

**Hydra UAT (`nywh`) — zero actors in 180 days.** Not a vacuous empty set: the table holds 93,539 rows with
the newest at 2026-08-12 (the DB is live), but the newest row carrying *any* of the four gated activity codes
is **2026-01-23**, seven months back and outside the window. ⚠️ **This corrects §2.6**, which reported 3 Hydra
operators — those were **lifetime** totals (the plan already flags `pesposito` as dormant since 2025-06). On a
recency-bounded view Hydra UAT has **no affected operator at all**.

**Production — one actor, unaffected.** `wms2_landlord` on prd has exactly **one** active v2 tenant
(hydra/nywh → `wh01_hydra_v2`; the other six prd warehouses are still v1), so that single DB is the whole
production surface. 180-day audit there: `thomasjr`, 22 rows of `MANAGE_INVENTORY`, last used 2026-08-18,
holding **8 of 8** `WEB_UI_ACTION_*` functions (77 total). ✅ unaffected.

✅ **P4 is therefore fully discharged across every environment — dev, UAT and prd. No user in any tenant
loses a destructive action they actually use, and no remediation is required before the image lands.** The
§2.6 grant table remains worth shipping for *future* delegation, but it is not load-bearing for regression
safety: every current actor is already a super-admin holding all 8 constants.

**✅ The §2.6 `anonymous` caveat is discharged.** Those rows do **not** come from the 13 gated endpoints.
Each gated service method has exactly **one** caller in `src/main` — the controller this slice gates — but
the *activity codes are not exclusive to it*: `MANUAL_ADJUSTMENT` is also written by
`ReplenishmentReservationReconciliationService:74` (the SBDEV-2610 data fix, reached via
`ReplenishmentReconciliationController`, a controller this slice does not touch), and `DAMAGED` by
`service/mobile/*` and `controller/rest/UtilRestController`. `SecurityContextUtils.getUserName()` returns the
sentinel **only** when `Authentication` is null — a JWT always yields `preferred_username` or the subject — so
these were principal-less invocations of a *different* path. **Nothing automated depends on the endpoints
being gated here.**

---

### 0.H TDD gate baseline — 2026-08-22

**Worktree:** `.claude/worktrees/wms2-api/SBDEV-2967-C` on `bugfix/SBDEV-2967-C-web-action-gating`,
off freshly-fetched `origin/develop` `d70204c`. Three test files added; **zero** production files touched.

| Test class | Tests | Fail | Pass |
|---|---|---|---|
| `unit/controller/StockUnitControllerActionGuardUnitTest` | 6 | 4 | 2 |
| `unit/controller/UnitLoadControllerActionGuardUnitTest` | 5 | 4 | 1 |
| `unit/security/ActionGuardAnnotationContractUnitTest` | 6 | 1 | 5 |
| **total** | **17** | **9** | **8** |

**All 9 failures are assertion failures, 0 errors.** The headline evidence is a clean status signal, exactly
what §2.3 property 3 asked for — every action endpoint answers **200** to a caller holding nothing:

```
C.2  /v3/stockUnit/bulkTransferToDamaged     -> 200
C.3  /v3/stockUnit/adjustAmount              -> 200
C.4  /v3/stockUnit/bulkAdjustAmount          -> 200
...
C.12 POST /v3/unitLoad/bulkDeleteContainer   -> 200
C.13 GET  /v3/unitLoad/deleteContainerRecursive/100 -> 500   (see below)
```

**The 8 tests that pass today are pins, not filler** — they assert properties that hold now and must keep
holding: the 13 handlers exist at the expected **arity**, the `getStorageLocationsForStockMovement` overload
is still a pair, `GUARDED` still excludes both controllers (F1), no `controller/rest` class is annotated or
guarded (G-1/G-2), and 2968's `transferStock` ANY-of still admits a mobile-only caller.

**Mutation results — the floor, applied to those 8 pins.** Baseline green, control green afterwards, tree
clean, every patch `touch`ed to force recompilation:

| Mutant | Verdict |
|---|---|
| M1 · add `StockUnitController` to `GUARDED` | **KILLED** |
| M2 · add a **fully-qualified** `@RequiresFunction` to a `controller/rest` class | 🔴 **SURVIVED**, then KILLED — see below |
| M2b · add a short-form `@RequiresFunction` to a `controller/rest` class | **KILLED** |
| M3 · delete `transferStock`'s annotation | **KILLED** (verified by diff, not by a count) |
| M4 · rename a gated target method | **KILLED** |

🔴 **M2 found a real defect in the gate's own tests.** The first version of the G-1 check scanned source text
for the literal `@RequiresFunction`, and a fully-qualified `@net.aim_ai.wms.security.RequiresFunction`
**survived it** — a presence-grep standing in for a property, the failure mode
[[verify-rows-cannot-assert-policy-only-jest-can]] names. Rewritten to resolve the annotation by
**reflection** (which is spelling- and line-wrap-blind) plus a non-empty-scan assertion; both spellings are
killed now. C-13's implementation must be reflection-based for the same reason.

🔴 **A second pin was vacuous and was strengthened.** The `transferStock` regression pin originally asserted
only *"a mobile-only caller is not 403"*. Deleting the annotation outright also satisfies that, so the pin
could not see its most likely regression. It now also asserts that a caller holding **neither** function is
**refused**, which is what M3 kills.

⚠️ **New observation, not in scope: `GET /v3/unitLoad/deleteContainerRecursive/{id}` returns 500 on the
SUCCESS path.** `UnitLoadController:171-172` returns `ResponseEntity.ok(new Object())`, and a bare `Object`
has no serializable properties; no `FAIL_ON_EMPTY_BEANS` override exists in `application.properties`. In the
gate that shows as `-> 500` where every sibling shows `-> 200`. The gate signal is unaffected (500 ≠ 403
either way, and post-fix a denial is a clean 403), but if it reproduces against a real deployment the
recursive-delete button reports failure while the container *is* deleted — which would be consistent with
§0.D's finding that its last real use on WineCo dev was 2025-04-22. **Needs a curl to confirm before it is
claimed as a defect.** Not fixed here — the gate touches no production code.

**Verify script baseline:** `verify-SBDEV-2967-C-web-action-gating.sh`, mono-rooted, run through a symlink
shadow root at the worktree: **`Result: 18 pass, 23 fail, 4 skip`**. It can fail, so it is not the
assert-nothing trap. Confirmed it carries **no `E1–E9` rows** — only `C*` and `V*` — so the superseded
service-layer assertions did not survive the split. Its `GR1`/`GR2` rows agree with the reflection tests.

**Completion contract for the executor:**

```
cd .claude/worktrees/wms2-api/SBDEV-2967-C
mvn test -Dtest=StockUnitControllerActionGuardUnitTest
mvn test -Dtest=UnitLoadControllerActionGuardUnitTest
mvn test -Dtest=ActionGuardAnnotationContractUnitTest
```

Done when all pass and the verify script reports `0 fail`. Neither contract may be weakened.

⚠️ **CORRECTED post-review:** that command now yields **15**, not 17 — the two `/rest` guard-rail tests (G-1,
G-2) were **relocated** into `FunctionGuardArchTest`, where §2.7 places them. The full contract is therefore
**15 + 2**, and `FunctionGuardArchTest` must be run too:

```
mvn test -Dtest=FunctionGuardArchTest,UtilRestControllerSeedUnitTest
```

The web-ui half had no worktree at gate time; it does now —
`.claude/worktrees/wms2-web-ui/SBDEV-2967-C`, run with `node_modules/.bin/jest`.
---

### 0.I Independent review — 3 lanes, 2026-08-22

Three lanes on opus, each required to write a file artifact (an idle lane with no report is not a passing
review). All three delivered. Reports:
`scratchpad/review-{conformance,code,security}.md`.

**Verdicts:** conformance **INCOMPLETE** (1 MISSING) · code review **1 High, 4 Medium, 6 Low** · security
**1 High, 2 Medium, 1 Low**. Every in-diff finding below is **FIXED**; two pre-existing findings need a
scope decision and are called out at the end.

#### Fixed — and each fix mutation-checked

| # | Lane | Finding | Fix |
|---|---|---|---|
| **H-1 / LOW-1** | code + security + conformance (all three) | 🔴 **AC C-11 was half done.** `container.js`'s `canPerformAction` had **zero consumers** — `containerTable.vue` was never touched, so both Delete controls stayed enabled for every non-`super-admin` while the server now 403s them. Since §2.6 keeps the delete constants super-admin-only this is the *widest* blast radius in the slice, and it is risk **C-R1** verbatim. Verify row `U2` and the container Jest block were **false-greens over it** | Wired both controls in `containerTable.vue` |
| **M-4** | code | 🔴 **Nothing tested the component wiring.** Measured: stripping **all 8** `:disabled` bindings from `stockUnitsTable.vue` left the suite at `548 passed` — identical. The entire client-side deliverable was deletable with a green suite | New `test/components/handlingUnits/actionControlsDisabled.spec.js`, asserting **exact binding counts per key** (not presence — `transferToDamaged` is bound twice, so a `toContain` version could not see one being deleted, which I measured) |
| **M-1** | code | 🔴 **The anti-drift rule was arity-blind for the exact overload it exists to protect — mutation SURVIVED.** Annotating the **arity-2** `getStorageLocationsForStockMovement` (`/isUnitLoadIdValid/{labelId}`) passed everything: `FunctionGuardArchTest`'s AC-4 filter keys on the method NAME, so the arity-free allow-list entry covers both overloads, and the contract test resolved both but asserted only the arity-1 one | Added the missing half: the arity-2 overload's annotation must be `isNull()`. Mutant now KILLED |
| **MEDIUM-1** | security | 🔴 **SET 5 pinned a string no request ever presents.** Nothing calls `.anonymous(disable)`, so `permitAll` on `/rest/**` is satisfied by an `AnonymousAuthenticationToken` whose principal is **`anonymousUser`**. `Authentication.getName()` — what the interceptor actually reads — returns `anonymousUser`; `SecurityContextUtils`' `ANONYMOUS` sentinel is returned only when `getAuthentication()` is literally null, which never happens in the filter chain. My audit row keyed on `'anonymous'` and so **could not catch its own case** | `IN ('anonymous', 'anonymousUser')` on both halves, and the §2.7 reasoning corrected in-file: what keeps the OMS path safe is `getAllRoles` returning empty **plus** G-1/G-2, not the sentinel |
| **M-2** | code | **The tooltip was inert.** Vuetify 2 sets `pointer-events:none` on `.v-btn--disabled`, so a `title` on a disabled button is never hit-tested. §2.5 chose "disable-**with-tooltip** (preferred, for discoverability)" and this silently degraded to the bare greying-out §2.5 rejected | Hint moved onto a wrapping `<span>` on all 10 controls |
| **M-3** | code | **A denied action raised a second, contradictory toast** — "network or server issue. Please retry." Slice A suppresses the retry but the promise still rejects, so each store action's generic `catch` fired too, telling the operator to retry something they will never be permitted to do | 403 early-return in all 7 affected actions, plus `handlingUnitsDeniedToast.spec.js`. Mutation-checked **both ways**: removing the guard reds it, and a blanket `return` (which would silence real 500s) reds it too |
| **L-5** | code | Nothing cross-checked `V2.2.20`'s five function names against `initDB`'s five `grantFunction` calls — two seeding surfaces, silent drift, only the Java one tested | `C-8d` parity test parsing the migration; also asserts the three deliberately-excluded constants are absent |
| **L-1, L-3, L-6** | code | Javadoc said "no-arg/one-arg" where the real arities are **1 and 2** (the worst place in the repo for an off-by-one); 4 unused imports left from the G-1 relocation; `C-4`'s display name overstated what it pins | All corrected |
| **§3.3** | conformance | 🔴 **My own fix to the verify script's `gated()` helper introduced 2 false-greens.** The gap `(?:[^{}]|"[^"]*")*?` leaves a bare `"` matchable by the plain branch, so the engine could enter a string, swallow braces across a whole method body and close at a later quote. Rows **C6** and **C8** passed with the annotation DELETED | One character — `[^{}\"]` in the plain branch. Re-measured: 13/13 pass on the correct tree (C13 still fixed) and both mutants KILLED |

**Corrections to this document itself**, both from the conformance lane:

- **§0.H's completion contract said "all 17 pass" for a command that now yields 15.** The two `/rest` guard-rail
  tests were **relocated** into `FunctionGuardArchTest` (where §2.7 places them), so it is 15 + 2. A future
  reader running the documented command saw 15 and could not tell relocation from two missing tests. Corrected
  in §0.H.
- **AC C-6's replacement has two residuals** that the word "replacement" hid, and neither is recoverable:
  1. It is a **surefire test, not a deploy gate**. C-6 would have failed *bean initialisation*; this runs in the
     test phase, and the repo's own documented build is `mvn clean package -DskipTests` — so a build that skips
     tests carries **zero** anti-drift protection.
  2. It is an **allow-list of 13 known handlers**. A *newly added* destructive endpoint on either controller is
     caught by nothing — not this test, not the startup assertion (class not in `GUARDED`), not AC-4 (which
     constrains gates that exist rather than requiring one). C-6-as-written would not have caught it either, so
     this is a pre-existing hole, not a regression — but it should be stated, not implied.

**Also confirmed by the lanes, worth keeping:** the conformance lane **executed** the G-3 query on all three
environments (dev, Hydra UAT, prd) — `anonymous` exists as a row on all three and holds **0** functions, so the
empty result is a real all-clear rather than a missing-row artifact. The security lane cleared the whole
fail-open surface (`checkAnyAccess` cannot flip a denial to an allow on any branch), confirmed no alternate MVC
route to the six gated service methods, confirmed `AdminController`'s inherited handlers are all
`@PreAuthorize(IS_SB_ADMIN)` and so not a path in, and — with a bearer-token argument rather than a hand-wave —
concluded the **GET verb on `deleteContainerRecursive` is as strong as a POST would be** for authz, because a
cross-site request, prefetch or link preview arrives with no `Authorization` header and 401s before the
interceptor runs. It explicitly disagreed that the verb needs changing for security reasons.

#### Second review pass — 3 lanes again, and two items no code change closes

All three lanes re-ran scoped to the fixes. **Conformance: PASS** (both first-pass blockers independently
re-verified — AC C-11 both halves, and its own 13/13 `gated()` mutant sweep). Code review and security each
returned further findings, **all of them defects in my fixes**, all now closed and mutation-checked: the 403
guard covered only the five SINGLE actions and missed all five BULK ones (risk C-R4's shape, and the spec's
hand-written case list held the same seven so it could not see the gap — the list is now DERIVED from the
module source); the tooltip wrapper shrink-wrapped inside the flex `.v-list-item` and collapsed five
full-width click targets; the binding spec could not tell a binding on the button from one on the wrapper
(relocating all eight onto the spans left the suite green, and `disabled` on a span is inert); the C-8d parity
check was satisfied by a quoted mention in a **comment** and would have passed syntactically invalid SQL;
the arity fix closed the instance but not the class (a NEW annotated `removeLock` overload survived); and the
header lookup was case-sensitive, re-planting a fragility `plugins/axios.js` already documents.

🔴 **Two things need a named owner before the image ships. Neither is a code change here.**

**E-1 — the Cypress e2e suite calls five gated endpoints directly and asserts 200.**
`cypress/support/helpers/wmsHelpers.js` and
`cypress/e2e/wms/inventory-management/inventory-management.cy.js` POST to `/stockUnit/adjustAmount`,
`/adjustReservedAmount`, `/setLockOnHold`, `/removeLock` and `/transferToDamaged` with
hard status assertions — `expect(resp.status).to.equal(200)` at `:129`, `:158`, `:193` and others. A 403
fails those specs outright.

⚠️ **CORRECTED 2026-08-22, and the correction lowers the priority.** I first wrote this up as *"the suite
goes red the moment this lands"*. **That is wrong.** Verified: **no CI workflow runs Cypress** — the four
`wms2-web-ui` workflows all build/deploy images and none references `cypress` or `e2e` — and `package.json`
exposes **`cy:open` only**, with no `cy:run`. So nothing invokes it headlessly; it breaks when a human next
runs the suite against a gated environment. Confusing rather than blocking.

The principal is runtime-supplied and deliberately absent from the repo: `cy.wms` → `cy.kcToken` → the
`kcToken` task (`cypress.config.js:42`) → `issueToken(config.env)`
(`cypress/support/plugins/auth-task.js:43-53`), a Keycloak password grant on `env.KC_USERNAME` /
`env.KC_PASSWORD`. **If the suite runs as a super-admin it is already fine** — super-admin holds all 8
constants on every tenant. Only the credential owner can settle it.

✅ **Filed 2026-08-22 as a widening of [SBDEV-3062](https://app.clickup.com/t/868kv11ed)**, not a new ticket —
that ticket already owns account-grant hygiene for this gating rollout, including "2 Cypress leftovers", so
it is the same fix visit and the same owner. Three options recorded there, cheapest first: confirm the
principal is a super-admin (a five-minute check that probably ends it) · grant the five functions to the
e2e user's role · change the specs to accept 403, which is only right if the suite is meant to run as an
unprivileged persona.

**E-2 — `transferStock` / `bulkTransferStock` will still double-toast on a 403.** They are 2968's surface,
not this slice's (they keep the cross-UI ANY-of view gate), so the `isAuthzDenial` guard was deliberately not
extended to them. Documented at the call site rather than fixed, so that the next reader does not think it
was an oversight.

**Process finding, recorded because it nearly produced a false review result.** Three lanes and the
implementer were patch-and-restoring in the SAME two worktrees concurrently. The conformance lane caught one
of its own mutant runs reporting a changed result whose patch had provably not applied — the tree had moved
underneath it — and it verified via three md5-identical snapshots that nothing was lost before switching to
additive probes only. Separately, the implementer destroyed six store actions with a greedy multiline regex
and recovered them from HEAD. **Give each lane its own worktree, or serialise them.** Two mutation harnesses
in one tree will eventually lose each other's work, and the failure looks like a finding rather than an
accident. Both lanes also independently demonstrated that **a mutation harness needs to prove its mutant hit
the intended symbol** — the conformance lane's first sweep reported six false-greens caused by an anchor that
matched a single/bulk pair partner, producing a clean, plausible, entirely wrong table.

#### 🔴 Two PRE-EXISTING findings that need Nam's decision — NOT fixed here

Neither is caused by this diff. Both are recorded because **the plan never mentions them**, and that gap is
itself the finding: the next reader will believe the capability is gated.

✅ **FILED 2026-08-22 — as a widening of [SBDEV-3017](https://app.clickup.com/t/868kufdy1), not a new ticket.**
Search-then-widen found the code-path sibling: 3017 is *"Authorization coverage beyond the mobile controllers
— SDR endpoints are ungatable"*, and its Class A already owns the mechanism (it even cites
`PATCH /v3/stockunit/{id}` from SBDEV-2870 §10.2 as the second occurrence of the shape — which is S-2).
Four things were new to it and are now on the ticket: **(1)** Class A is not only read-exposure — the write
side makes every function gate **self-grantable in one request**, with the measured post-3013 exposure table;
**(2)** two of the surfaces have LIVE clients (`store/admin/group.js:65` and `role.js:85` are SDR item PUTs
and neither controller has a `@PutMapping`), so "just un-export it" is unavailable there, and the item-PUT
association-URI leg needs a different mechanism entirely; **(3)** the 2870 §10.2 **500 is not evidence of
refusal** — SDR commits in `save()` and serializes after, and `reservedamount` is nullable behind an
unconditional `@Transient` getter, so judge any probe by re-reading the row; **(4)** 3017's own landmine
*"only 1 of ~80 functions is enforced"* is stale. Priority raised `normal` → `high`; urgent left to Nam.
Recommended split recorded there: the ~20-line escalation fix is safe and independent of the read-exposure
inventory.

**S-1 (High) — the 13 gates are self-grantable in as little as ONE request.** Every access decision derives
from `UserRepository.getAllRoles`, which traverses `user → group → role → function`. SBDEV-3013 door ① withdrew
the SDR write verbs from the **last** hop only (`mywms_role_mywms_function`). Measured against the production
`RepositoryRestConfigurer` this session: `mywms_group_mywms_user`, `mywms_group_mywms_role`,
`mywms_user_mywms_role`, `User`, `UserGroup`, `UserRole` and the `User.groups` / `UserGroup.roles` associations
**all still expose POST/PUT/PATCH/DELETE**. So
`PATCH /v3/userGroup/{aGroupIAlreadyBelongTo}/roles` with a privileged role's URI, then
`POST /v3/stockUnit/adjustAmount` → 200. `FunctionGuardInterceptor` structurally cannot see it —
`RepositoryRestHandlerMapping` does not consult `WebMvcConfigurer#addInterceptors`, which the interceptor's own
javadoc states. Proposed fix is ~20 lines in the mechanism this repo already built (five more `forDomainType`
blocks in `RestConfiguration.configureRoleFunctionWriteExposure` plus rows in the already-parameterised
`SdrWriteExposureUnitTest`), gated on first confirming those writes have no UI client.

**S-2 (Medium, could be High) — the gated *capability* has a second, ungated, unaudited path.**
`/v3/stockunit` and `/v3/unitload` retain all four SDR write verbs (measured), and the protected fields
(`amount`, `reservedamount`, `entityLock`) have public setters with no `@JsonIgnore`/`@ReadOnlyProperty`. So
`PATCH /v3/stockunit/{id} {"amount":0}` and `DELETE /v3/unitload/{id}` reach the same data as the gated
endpoints with no guard, no `stockrecord` row and no `BusinessException` validation. **Counter-evidence stated
honestly by the lane:** `AdminController:230-232` records a prior measurement that `PATCH /v3/stockunit`
returns **500**, and SBDEV-2870 §10.2 marks the whole area "not runtime-verified". But
`PATCH`/`DELETE /v3/unitload/{id}` — the second path around the two constants this slice restricts *hardest* —
has **never been measured in either direction**. **Two curls with a plain `wms_user` token settle it.** Until
then this plan should not claim the capability is gated, only the route: "route gated, capability open" is a
shape SBDEV-2870 §11.2 and SBDEV-2968 §14.12.a already flagged twice.

---

### 0.J The Flyway collision caught at merge — 2026-08-22

**SBDEV-3010's PR #184 and this slice's #185 both claimed `V2.2.20`.** #184 merged first (it was submitted
first), so this slice's migration was renumbered to **`V2.2.21__seed_web_action_function_grants.sql`**.

Had the second merge gone in unchanged, Flyway would have found two files at one version and failed **on
every tenant** — and per this repo's own standing warning, a tenant migration failure never aborts boot, so
nothing would have reported it.

**🔴 The process lesson, which is the part worth keeping.** P5/P6 required a re-sweep of `V2.2.*` across all
remote branches at PR time. That sweep was run **three times** — twice by me and once by the conformance
review lane — and **all three reported `V2.2.19` as the maximum and all three were right at the moment they
ran.** #184's branch was pushed between sweeps. **A point-in-time sweep structurally cannot catch a
collision with a branch that does not exist yet**, so "I swept at PR time" is not a defence; the window is
open until the merge.

What does catch it is the checker #184 itself added — `db/check-migration-version-collision.sh` — which
compares the local migration directory against every remote branch *and* names the highest version claimed
anywhere, including on branches whose files never reached `develop`. It reported `RESULT: clear` after the
renumber, and it correctly flagged the stale `V2.2.20` still sitting on this branch's abandoned pushed
state. **Run it immediately before every merge that carries a migration, not at PR time.**

**A second, smaller defect surfaced in the same merge.** `db/audit-access-invariants.sql` conflicted because
both branches appended a new SET at end-of-file — no semantic conflict, but git cannot tell. Both are kept
(3010's SET 10 for join-table KEY integrity, this slice's G-3 invariant). Resolving it exposed that **this
slice had labelled its set "SET 5" when the file already carried SETs 1–9** — a duplicate label that no test
or verify row checks, and that nothing but the merge would have revealed. Renumbered to **SET 11**, and
retitled from "the `anonymous` SENTINEL must hold zero functions" to "no unauthenticated identity may hold a
function", since the security lane established `anonymousUser` is the real principal on the `/rest` path and
not a sentinel at all.

---

### 0.K Manual QA — API half executed live on WineCo dev, 2026-08-22

Run as `sbtest`, which is exactly the M7 persona: holds `WEB_UI_LOG_IN`, **zero** `WEB_UI_ACTION_*`.

**Method — zero data mutated.** Every probe used a non-existent id (`999999999`). The gate runs before the
handler, so a denial is a clean 403 and an allow would have fallen through to `EntityNotFound` — the verdict
is readable either way without touching stock. Confirmed after: **0 `stockrecord` rows created, 0 rows at all
in the preceding 30 minutes.** Control first: `GET /v3/user/getAllRoles/sbtest` → **200**, so the token is
valid and the interceptor is not blanket-denying.

**All 13 endpoints returned 403, each naming its OWN constant** (C.1/C.2 `ADJUST_LOCK_DAMAGED`, C.3/C.4
`ADJUST_AMOUNT`, C.5/C.6 `ADJUST_RESERVED_AMOUNT`, C.7/C.8 `ADJUST_LOCK_ON_HOLD`, C.9/C.10
`ADJUST_LOCK_RELEASE_LOCK`, C.11/C.12 `DELETE_UNIT_LOAD`, C.13 `DELETE_UNIT_LOAD_RECURSIVE`).

| AC | Verified live |
|---|---|
| **C-1** | ✅ all 13, single **and** bulk |
| **selectivity** | ✅ each endpoint on its own constant; pair members correctly share one |
| **C-3** | ✅ **the headline claim** — every bulk endpoint returns **403**, never `200 {errors:[…]}`. This is the §2.2 fact-1 property that justified controller-level placement, now measured in the deployed system rather than argued from the code |
| **C-7** | ✅ `X-Authz-Denied` present on every denial, naming the right function |
| **C-10** | ✅ `transferStock` denies with **`MOBILE_UI_VIEW_STOCK_TRANSFER`** — a 2968 VIEW function, not an ACTION constant. Proof the slice did not narrow the cross-UI ANY-of gate |
| CORS | ⚠️ **declared, not proven.** `access-control-expose-headers: …, X-Authz-Denied` is present with the right allow-origin — but curl cannot prove browser *exposure*; only JS `headers.get()` can |

**V2.2.21's delegation reached real accounts.** Five dev users now hold exactly the five delegated functions
via the `inventory-manager` role — `danielvalentim`, `daniilandriyenko`, `jovanyaguilera`, `markchilcote`,
`ursulajimenez` — and all five held **zero** `WEB_UI_ACTION_*` before it. That is the migration working on
users, not just a row count.

#### ✅ M11, the allow path — verified 2026-08-22 by granting `sbtest` the `inventory-manager` group

Re-probed all 13 with the same non-existent id. **The same principal, in the same minute, is allowed on ten
and denied on three** — exactly the §2.6 table:

| Rows | Result |
|---|---|
| C.1–C.10 (adjust / lock) | **404** — gate PASSED, handler entered, `EntityNotFound` on the fake id |
| C.11–C.13 (deletes) | **403** — `WEB_UI_ACTION_DELETE_UNIT_LOAD` / `_RECURSIVE`, still super-admin-only |

0 `stockrecord` rows in 20 minutes; grant count unchanged; neither probe target exists.

**This is the strongest evidence in the slice and no unit test can produce it.** The earlier run proved each
endpoint names its own constant; this proves **the grant table itself is enforced end to end**. One principal,
one group membership as the only variable: `403 × 13` → `404 × 10 + 403 × 3`. It also confirms **V2.2.21 is
functional** — the grants that migration inserted are exactly what unlocked C.1–C.10 — and that §2.6's
`DELETE_UNIT_LOAD*` restriction holds against a real `inventory-manager` rather than being inferred from the
migration text.

⚠️ **Diagnostic worth keeping:** the first attempt showed no change, and the cause was neither the app nor
the migration. Two separate group systems exist — Keycloak groups (in the token's `groups` claim) and the WMS
`mywms_group_mywms_user` table — and **only the latter feeds `UserRepository.getAllRoles`, which is what every
gate reads.** A Keycloak-side group assignment would have had no effect at all. I also ruled out a regression
I suspected from the same day's merge: SBDEV-3010 added PRIMARY KEYs to that very table hours earlier, and a
delete-all-then-reinsert save would now raise 23505 where it previously created a silent duplicate — but
`UserService.replaceUserGroups` uses a proper **set difference** (remove only what is unwanted, add only what
is missing), so the new keys are safe there.

#### 🔴 Still unverified — all of it browser-only

`sbtest` now holds both view functions, so **it is the ideal UI QA persona**: Adjust/Lock controls should be
**enabled** and both Containers Delete controls **disabled with a tooltip**, exercising both states in one
login.
- **The tooltip actually being visible** — Vuetify sets `.v-btn--disabled{pointer-events:none}`, which is why
  the hint moved onto a wrapper `<span>` with `flex-grow-1`. **Still the only change in this slice with no
  runtime evidence**; one screenshot of the row-action dropdown closes it.
- **The operator staying logged in** on a denial (slice A's behaviour, client-side).
- **`X-Authz-Denied` readable from JS** — the server *declares* it in `access-control-expose-headers`, but
  curl ignores CORS filtering, so only a browser can prove exposure.
- **M12** (mobile Move Stock unaffected) — needs the mobile app.
- **The `flex-grow-1` wrapper and the tooltip** — still the only claim in the slice with no runtime evidence;
  one screenshot of the row-action dropdown closes it.

## 1. Why the gates are needed — the reachability evidence

**Verified 2026-08-16 — corrected twice, so the evidence is stated in full.**

The mobile UI makes exactly **five** calls into shared controllers, and **none is an action endpoint**:

```
store/moveStock.js:157  → /stockUnit/storageLocationsForStockMovement   (read)
store/moveStock.js:169  → /stockUnit/transferStock                      (move, not an ACTION constant)
store/picking.js:244    → /dashboard/orderMonitorViewSummary            (read)
pages/replenish.vue:133 → /dashboard/replenishMonitorViewSummary        (read)
pages/replenish.vue:153 → /dashboard/replenishMonitorViewSummary        (read)
```

A repo-wide grep of `wms2-mobile-ui` for
`adjustAmount|adjustReserved|setLock|removeLock|deleteUnitLoad|printToteLabels` returns **nothing**.

| Action | Cross-UI? | Entry points |
|---|---|---|
| `ADJUST_LOCK_DAMAGED` | ✅ **the only one** | `StockunitService:232` + `service/mobile/MobileMoveStockService:252,257` + `service/mobile/MobileMoveUnitloadService:303,308` — mobile reaches it *service-internally* when a move involves damaged stock, never as an endpoint |
| `ADJUST_AMOUNT` | ❌ web-only | `StockUnitController:179` single + ~`:222` bulk |
| `ADJUST_RESERVED_AMOUNT` | ❌ web-only | `:259` / `:300` |
| `ADJUST_LOCK_ON_HOLD` | ❌ web-only | `:334` / `:362` |
| `ADJUST_LOCK_RELEASE_LOCK` | ❌ web-only | `:474` / `:499` |
| `PRINT_TOTE_LABELS` | ❌ web-only | `DashboardController:71` (+ §0.F) |
| `DELETE_UNIT_LOAD` | ❌ web-only | `UnitLoadController:100`, `:134` |
| `DELETE_UNIT_LOAD_RECURSIVE` | ❌ web-only | `:163` |

> **Correction, recorded rather than quietly fixed.** Two earlier drafts claimed these actions were cross-UI
> — first all 8, then 6 of 8. **Both were wrong.** The second came from observing that five mobile services
> mutate `entityLock`/amount, which is true but irrelevant: mutating a lock *during picking or cycle count*
> is not the same as invoking the *adjust-lock action*. Only `ADJUST_LOCK_DAMAGED` is genuinely shared.

---

## 2. Fix design

### 2.1 🔴 The contradiction this slice resolves

**The pre-split plan gave two opposite instructions in one section, and both had verify rows and tests
behind them.** §3.5 carried a heading *"REVERSED at architect review — the gates go on the CONTROLLER, not
the service"* with three pieces of verified evidence, and then, four paragraphs later, ended with:

> *"Implementation: `accessService.doesUserHaveAnyAccess(...)` at the entry of the service method backing
> each action… **Not** `@RequiresFunction`, and **not** the interceptor."*

§6.2's test table named service classes, risk R6 warned against controller placement, and the verify
script's rows `E1–E6` assert the constants appear in `StockunitService.java` / `UnitloadService.java` while
row `E9` asserts **no** `WEB_UI_ACTION_*` appears inside a `@RequiresFunction`. **Row E9 would fail a correct
implementation.** An implementer following the trailing paragraph would have shipped guards that return
HTTP 200.

**Resolution: the REVERSED decision stands. §2.2 is the single instruction. The trailing paragraph, R6,
§6.2's service-class table and verify rows E1–E6/E8/E9 are superseded and are not carried into this slice.**

### 2.2 The decision, and the three facts behind it

**Method-level `@RequiresFunction` on the controller endpoints for the 7 web-only actions — both the single
and the bulk method of each pair. `ADJUST_LOCK_DAMAGED` additionally keeps its existing service-layer check
in `transferStock`, because that branch is genuinely cross-UI; its own two endpoints (C.1, C.2) get
controller gates like everything else.**

The convergence argument for the service layer is **true but not decisive** — single and bulk really do
converge on one service method (verified: `adjustAmount` `StockUnitController:200`/`:241`,
`adjustReservedAmount` `:278`/`:317`, `setLockOnHold` `:346`/`:378`, `removeLock` `:485`/`:514`,
`setLockDamaged` `:416`/`:457`, `UnitLoadController:100`/`:134`). Three verified facts defeat it:

**1. A service-layer denial does not produce 403. On the bulk paths it produces HTTP 200.**
`StockUnitController:224-254` wraps the whole loop in
`try { … } catch (BusinessException e) { errors.add(getErrorMessage(...)) }` and returns
**`ResponseEntity.ok(errorMap)`**. The existing guard shape throws `BusinessException`
(`StockunitService:232`), so a service-layer gate on any bulk action returns **200 with an errors array** —
indistinguishable to the client from a partial success. **Re-confirmed on `develop` 2026-08-21** at
`adjustAmount`. *A guard that returns 200 is not a guard.*

**2. The denial message is a key, not a sentence.** `getErrorMessage("Runtime Error", e.getMessage())` — with
`BusinessException`'s 1-arg constructor the key is `"placeholder"` and `getMessage()` returns the key only
while it is absent from the bundle. Opaque denial is the exact failure mode this slice exists to prevent.

**3. N authorization reads per bulk request.** `AccessService.doesUserHaveAccess` runs an uncached 5-table
`getAllRoles` per call. Inside the converged service method that is **once per id**; at the controller it is
once per request.

The anti-drift concern is solved elsewhere: 2968's `FunctionGuardArchTest` golden map plus the
`SmartInitializingSingleton` startup assertion (`FunctionGuardStartupAssertion`, both verified on `develop`)
make a *missing* annotation fail bean initialisation. **Add all gated controllers to the golden map.**

Method-level annotation also **avoids the mobile-coupling problem entirely** — mobile touches only
`transferStock` and `storageLocationsForStockMovement`, which stay as 2968 left them.

### 2.3 The damaged-lock pair (C.1, C.2) — received from SBDEV-2870 with a **proven** implementation

Written, tested and ablation-proven on `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin`, then
reverted from that branch and re-homed here on a consistency argument:

> "Transfer To Damaged" is **one of six sibling row actions** on the Stock Units page — Lock, Unlock, Adjust
> Amount, Adjust Reserved, Transfer Stock, Transfer To Damaged. All six dispatch from the same table
> (`store/handlingUnits/stockUnits.js`), each has a single and a bulk variant, and all twelve endpoints sit
> on `StockUnitController`. Gating **one** would have removed Transfer To Damaged from ~13 live WineCo users
> while leaving the other five open to every `wms_user` — an unexplainable state. One tranche, one grant
> decision.

**Unlike the rest of this slice, this part is not a proposal. Reuse it.** Five properties established
empirically, not to be re-litigated:

1. **Controller-level, not service-level.** This pair is the proof case for §2.2.
2. **Before the bulk loop.** One authorization read per request, not per id. Ablation-proven: moving the
   check inside the loop fails `bulkTransferToDamaged_shouldCheckAuthorizationOncePerRequest`.
3. **Deny tests must stub the happy path.** Otherwise removing the gate fails on an incidental
   `EntityNotFoundException` rather than on the status — the ablation signal is then accidental. Fixed
   version yields a clean `expected:<403> but was:<200>`.
4. **`X-Authz-Denied` requires CORS exposure or it is invisible.** ✅ **Landed by SBDEV-2968 and verified on
   `develop` 2026-08-21**: `Authority.java:99`, emitted at `FunctionGuardInterceptor.java:184`, exposed at
   `SecurityConfiguration.java:193-194`, pinned by `SecurityConfigurationTest:91`.

    **Reference it by symbol, never by literal.** Write `Authority.AUTHZ_DENIED_HEADER`, not
    `"X-Authz-Denied"`. If 2968 were reverted this slice **fails to compile** instead of silently logging
    operators out on every denial — the loudest available signal, at no cost. Mirror 2968's verify row `A27`
    (`file_not_contains '"X-Authz-Denied"'`) plus an `[inherited]` row asserting the symbol resolves on the
    branch under test.
5. **`SecurityConfigurationTest` asserts the exposed-header list.** 2968 already made this edit and the
   assertion is `containsExactlyInAnyOrder`, not `containsExactly` — order-sensitivity would depend on the
   order of two `addExposedHeader` calls that no requirement constrains. **Do not "restore"
   `containsExactly`.** Verify, do not re-do.

Two caveats carried over unresolved, both flagged by review and deliberately not self-applied:

- **Null-as-success** — the proven helper returns `null` for "allowed", so a third call site could discard
  the return and silently bypass the gate. Preferred shape: `requireDamagedLockAccess()` throwing a
  dedicated exception mapped in `RestExceptionHandler`, which would also converge the mobile paths
  (`service/mobile/MobileMoveStockService:252,257`, `service/mobile/MobileMoveUnitloadService:303,308`) onto one denial contract instead
  of today's two. **With `@RequiresFunction` chosen for C.1–C.13 this largely dissolves** — the annotation
  has no return value to discard. Keep the note for the service-layer `transferStock` branch.
- 🔴 **A class-wide `lenient()` permissive stub** was needed in `StockUnitControllerUnitTest.setUp` so six
  pre-existing tests kept exercising the handler. It is permanent and class-wide, so **any** gate on this
  controller's 16 endpoints becomes silently permissive in every existing test. With this slice gating 10 of
  them, **use per-nested-class stubs so unstubbed means *deny*** — failing closed like production. This is
  the single most likely way this slice ships a vacuous test suite.

### 2.4 ⚠ Do not reuse the `UnitLoadController` constant arguments as the hook

Those constants are currently the `comment` argument (§0.D). Adding enforcement there would either break the
audit comment or silently pass the wrong string. The gate goes **above the method** as an annotation; the
argument gets a real comment, under SBDEV-2979.

### 2.5 UI — disable the controls

Hide or **disable-with-tooltip** (preferred, for discoverability) each gated control in the components that
dispatch C.1–C.13, principally `store/handlingUnits/stockUnits.js` and `container.js`. This is what prevents
most users ever triggering a 403 at all.

### 2.6 🔴 ACTION grants — without which this slice is a silent capability removal

**No non-`super-admin` role holds a single `WEB_UI_ACTION_*` function that reaches a live user.** ✅ Re-measured on `dev_wh01_om1` 2026-08-21: all 8 constants are additionally held by test-created single-function roles (`ROLE000043–50`, `ROLE000092–99`), but **all 16 have ZERO users**, so the claim stands (§1.2 of slice B — every role shows
0). Slice B's VIEW grants do not change that. So the moment these gates land, **every `inventory-manager`,
`outbound-manager`, `receiving` and `CS-REP` user loses stock adjustment, lock on-hold/release and container
delete** — capabilities they exercise today, removed with no menu change to signal it.

That is a **larger and less visible blast radius than the menu work.**

> ✅ **APPROVED 2026-08-21 (Nam) — ship the table below as drafted**, on the stated understanding that
> grants are adjustable afterwards via Admin → User Management with no deploy (that path works: SBDEV-3005
> is deployed and made the replace atomic).
>
> **Grounded in real usage, not proposal.** 180-day `stockrecord` audit:
>
> | Tenant | Non-super-admin operators using these actions |
> |---|---|
> | WineCo dev | **0** — only `panderson` (375 rows) and `midnight.p` (11), both super-admin |
> | **Hydra UAT** | **3** — `pesposito` **1,153 rows**, `omallozzi2` 16, `j.arcate` 1 |
>
> 🔴 **All three Hydra operators hold NO ROLES** (`j.arcate` has no `mywms_user` row at all), so no grant
> can reach them until the §4-P3a provisioning gap is closed. ~~That is a precondition of this slice~~ ✅ **DISCHARGED 2026-08-21** — production has no provisioning gap (all 7 prod humans hold roles); the role-less users are dormant dev/UAT accounts. [SBDEV-3062](https://app.clickup.com/t/868kv11ed) reduces to hygiene and no longer blocks. See slice B §1.2.4. ⚠️ **`pesposito`'s 1,153 rows were a LIFETIME total for a user dormant since 2025-06** — bound operator analysis by recency.
>
> ⚠️ **`anonymous` performed 48 gated-action rows on WineCo dev** (`MANUAL_ADJUSTMENT`, `MANAGE_INVENTORY`,
> `DAMAGED`) with no roles. A gate denies it. Confirm nothing automated depends on that path before shipping.
>
> **`DELETE_UNIT_LOAD*` stays `super-admin`-only** — last real use on WineCo dev was **2025-04-22**, 16
> months ago, so restricting it costs almost nothing against an irreversible, stock-history-writing action.

Proposed ACTION grants — ⚠ **P2-ACTION sign-off, and arguably more sensitive than the VIEW table, since
these are the destructive operations:**

| Action | Proposed personas | Rationale |
|---|---|---|
| `ADJUST_AMOUNT`, `ADJUST_RESERVED_AMOUNT` | `inventory-manager` | stock correction is inventory ops |
| `ADJUST_LOCK_ON_HOLD`, `ADJUST_LOCK_RELEASE_LOCK`, `ADJUST_LOCK_DAMAGED` | `inventory-manager` | lock management is inventory ops |
| `DELETE_UNIT_LOAD`, `DELETE_UNIT_LOAD_RECURSIVE` | **`super-admin` only** | irreversible and it writes stock history — recommend NOT delegating |
| `PRINT_TOTE_LABELS` | `outbound-manager` | deferred to tranche C2 with the constant itself |

**If Brent declines to delegate any of these, that is a valid answer** — but it must be a decision, because
the default (grant nothing) silently removes them from everyone but the 39 super-admins.

Migration mechanics are identical to slice B §2.5-F2: `INSERT … WHERE NOT EXISTS`, keyed by role **name**,
**never `ON CONFLICT`** (the constraint-name drift + 42P10 reasoning applies unchanged). **Re-sweep
`V2.2.*` across all remote branches at PR time** — head is V2.2.18 as of 2026-08-21.

---

### 2.7 🔴 Guard rails — pin the ABSENCE that makes the OMS path safe

Added 2026-08-21 after the SBDEV-3062 reachability analysis. **These protect a property that currently
holds by accident, and whose violation fails silently.**

**The situation.** `/rest/**` is `permitAll()` (`SecurityConfiguration:123-127`), so OMS calls arrive with
no `Authentication`; `SecurityContextUtils.getUserName()` therefore returns the sentinel `"anonymous"`.
Those are real HTTP requests and `FunctionGuardInterceptor` **is** registered on `/**`
(`WebConfig:35`) — so the interceptor does run on them.

**Why they are safe today, and only today.** No `controller/rest/*` class carries `@RequiresFunction` or
appears in `GUARDED`, so every one falls through the `annotation == null && !GUARDED.contains(declaring)`
branch. This slice gates `/v3/stockUnit` and `/v3/unitLoad`, a different path. Nothing enforces that state
— **one annotation added later breaks OMS integration silently**, and no test would notice, because the
integration path is not exercised by any suite.

| # | Guard rail | Shape |
|---|---|---|
| **G-1** | No class in `net.aim_ai.wms.controller.rest` may carry `@RequiresFunction` | ArchUnit in `FunctionGuardArchTest` + verify row |
| **G-2** | No `controller/rest/*` class may appear in `FunctionGuardInterceptor.GUARDED` | ArchUnit (read `GUARDED` by reflection, as `FunctionGuardWiringUnitTest` does) + verify row |
| **G-3** | `anonymous` must hold **zero** functions on every tenant | audit row in the SBDEV-2968 `db/audit-access-invariants.sql` surface |

**G-3 is the data half and it is not redundant.** `anonymous` is a real `mywms_user` row on at least
Hydra UAT (`SecurityContextUtils` javadoc notes this explicitly, id 1). Granting it a function would make an
**unauthenticated** principal privileged — so a later-gated `/rest` endpoint would **silently pass** rather
than fail loudly. That is the inverse of what a sentinel should do, and it is exactly the mistake an
operator would make while "fixing" a 403 seen in the logs.

**Do NOT grant `anonymous` or `oms_integration` a role or group.** Analysed and rejected under SBDEV-3062:
`anonymous` is a sentinel meaning *nobody is authenticated*; `oms_integration` is unused (1 `stockrecord`
row across all tenants). Neither is denied by anything this plan ships.

⚠️ **Out of scope, recorded because it is the root of the above:** `/rest/**` being `permitAll()` means the
OMS-facing write API is unauthenticated. Pre-existing; not this plan's to fix.

---

## 3. Prerequisites

| # | Prerequisite | Blocking? |
|---|---|---|
| **P1** | ~~SBDEV-2968 merged.~~ ✅ **DONE 2026-08-21** — `@RequiresFunction`, `FunctionGuardInterceptor`, `FunctionGuardStartupAssertion`, `FunctionGuardArchTest`, `Authority.AUTHZ_DENIED_HEADER` + CORS all verified on `develop` `5506117`. | Done |
| **P2** | ✅ **DONE 2026-08-21 — [slice A](SBDEV-2967-A-axios-403-denial-not-logout.md) MERGED ([#70](https://github.com/SiteBossInc/wms2-web-ui/pull/70), merge `46dd072`), DEPLOYED to WineCo dev and e2e-verified in a real browser.** Without it every gate in this slice would log the operator out instead of denying them — that was the hard ordering constraint of the whole family, and it is now satisfied. | Done |
| **P3** | ✅ **DISCHARGED 2026-08-21 (Nam) — see the approval box in §2.6.** Ship the ACTION grant table as drafted, `DELETE_UNIT_LOAD*` staying `super-admin`-only; grants are adjustable afterwards via Admin → User Management with no deploy. Original framing kept for history: *Brent signs off the §2.6 ACTION grant table — covers all six Stock Units row actions in one decision; gating a subset is what §2.3's relocation exists to avoid.* | Done |
| **P4** | Run the audit + a regression predictor **for actions, not just menu items** (slice B §2.6). ✅ **FULLY DISCHARGED 2026-08-22 — see §0.G.** Audited all three environments. WineCo dev: 3 actors, the 2 real ones hold all 8 constants, `anonymous` is not reachable through the gated endpoints. Hydra UAT: **0** actors in 180 days (newest gated row 2026-01-23; §2.6's 3 operators were lifetime totals). Prd: 1 actor (`thomasjr`), holds 8 of 8 — and prd has only **one** active v2 tenant, so that is the entire production surface. **No remediation needed anywhere.** | Done |
| **P5** | ACTION grant migration applied to every tenant **before or with** the api change. | **YES** |
| **P6** | Re-sweep `V2.2.*` across all remote branches at PR time. 🔴 **Head is now `V2.2.19`, not V2.2.18** — 2967-B merged 2026-08-22. **The ACTION grant migration is `V2.2.20`** (swept across all remote branches 2026-08-22: V2.2.19 is the unique max). Re-sweep again at PR time. | **YES** |
| **P7** | **Deploy order: ① ACTION grant migration → ② `wms2-web-ui` disabled controls → ③ `wms2-api` gates.** The UI must precede the server gates or a user sees an enabled button that 403s. **If ② and ③ ride the same release, say so and accept the window explicitly.** | **YES** |
| **P8** | Decide tranche C2 (`PRINT_TOTE_LABELS`, §0.F) — in this ticket or its own. | No — deferrable |

---

## 4. Test plan

### 4.1 `wms2-api` (JUnit) — **one deny/allow pair per ENDPOINT, not per constant**

§0.B shows 8 endpoints for 4 constants on `StockUnitController` alone. A test covering only the single
member leaves the bulk one open — and the bulk members are exactly where a mis-placed guard returns HTTP
200.

| Endpoint(s) | Constant | Test class |
|---|---|---|
| C.1, C.2 | `ADJUST_LOCK_DAMAGED` | `StockUnitControllerActionGuardUnitTest` — 🔴 **UNGUARDED TODAY (§0.E), must be implemented; not a regression pin** |
| C.3, C.4 | `ADJUST_AMOUNT` | ” |
| C.5, C.6 | `ADJUST_RESERVED_AMOUNT` | ” |
| C.7, C.8 | `ADJUST_LOCK_ON_HOLD` | ” |
| C.9, C.10 | `ADJUST_LOCK_RELEASE_LOCK` | ” |
| C.11, C.12 | `DELETE_UNIT_LOAD` | `UnitLoadControllerActionGuardUnitTest` |
| C.13 | `DELETE_UNIT_LOAD_RECURSIVE` | ” |

Plus: `bulkX_shouldCheckAuthorizationOncePerRequest` per bulk endpoint (§2.3 property 2), and a golden-map
ArchUnit entry per gated controller.

`unit/controller/rest/UtilRestControllerSeedUnitTest#seedsActionFunctionsPerTheApprovedTable`.

### 4.2 Test landmines specific to this slice

- 🔴 **The class-wide `lenient()` stub in `StockUnitControllerUnitTest.setUp` makes every new gate silently
  permissive.** Use per-nested-class stubs. Verify by deleting one annotation and confirming *that*
  endpoint's pair goes red.
- **Mutation-check every new assertion** (the floor). ⚠ **A pin can be vacuous even AFTER the fix** — a
  sibling fix's early return can absorb the mutant. Mutation-check post-implementation, not only at the gate.
- **`standaloneSetup` cannot see the class-level `/v3` prefix** — a green test proves nothing about routing.
- **Assert `BusinessException.getKey()`, never `getMessage()`.**
- **No `@SpringBootTest`** (SBDEV-2217). Known baseline: 2 pre-existing failures on `develop`. `mvn test`
  mutates the tracked `archunit_store` — revert it. `-Dtest='Outer#method'` silently no-ops for `@Nested`.
- **Transactional tests are blind to propagation and `readOnly`** — irrelevant to a gate, but do not assume
  a green transactional test says anything about the guard's placement.

### 4.3 `wms2-web-ui` (Jest)

Disabled-control specs per §2.5. Baseline: 2 always-red *suites*, 0 failing tests — compare the tests count.

### 4.4 Manual

| # | Persona | Action | Expected |
|---|---|---|---|
| M7 | non-`super-admin` with `WEB_UI_VIEW_STOCK_UNIT` but no `ACTION_ADJUST_AMOUNT` | Handling Units → adjust | control disabled; direct API call **403**, operator **stays logged in** (needs slice A) |
| M7b | same | **bulk** adjust of 3 ids | **403**, not `200 {errors:[…]}` — this is the §2.2 fact-1 regression |
| M11 | `inventory-manager` after the ACTION migration | adjust amount | works |
| M12 | mobile operator | Move Stock involving damaged stock | **unaffected** — the `transferStock` service branch is unchanged |

---

## 5. Risks

| # | Risk | Sev | Mitigation | Residual |
|---|---|---|---|---|
| **C-R1** | 🔴 **Silently removes all destructive actions from every non-`super-admin` user.** Less visible than the menu work — a hidden item is obvious; an enabled-looking button that 403s is not. | **High** | §2.6 ACTION grants (P3); P4's predictor must cover actions; P7 sequences the disabled controls ahead of the server gate; M7 | Accepted only once P3 answers. **If the grants are declined, this stops being a risk and becomes the intended behaviour — but it must be stated, not defaulted into.** |
| **C-R2** | 🔴 **An action-gate 403 logs the operator out.** | **High** | **Slice A, as blocking prerequisite P2.** Do not ship this slice first. | None once slice A lands. |
| **C-R3** | **A guard placed at the service layer returns HTTP 200 on every bulk path.** The pre-split plan instructed exactly this in one paragraph. | **High** | §2.1 records the contradiction and its resolution; §2.2 is the single instruction; M7b and the per-endpoint pairs catch it | Low if §2.2 is followed. |
| **C-R4** | **A gate on one member of a single/bulk pair leaves the other open.** | **High** | ArchUnit asserts **pairs**; §0.B is the row-by-row checklist; AC restated per endpoint | Low if worked row by row. |
| **C-R5** | 🔴 **`setLockDamaged` treated as an existing guard and pinned "unchanged"**, shipping `/transferToDamaged` open. | **High** | §0.E; the pre-split verify row `E8` is deleted, not carried | Low. |
| **C-R6** | ~~The class-wide `lenient()` stub makes the whole new suite vacuous.~~ 🔴 **RESTATED 2026-08-22 — the stub does not exist on `develop`** (it was on the unmerged 2870 branch). The live risk is the inverse: `BaseControllerUnitTest.setupMockMvc` installs **no interceptor**, so `@RequiresFunction` is **inert** under it and a deny/allow pair written with it passes on an ungated controller. | **High** | Use `setupMockMvcWithGuard(controller, interceptor)` (:95) — the only mode that exercises a gate here; it is strictly additive so existing tests are unaffected. Reference: `FunctionGuardMockMvcUnitTest`. Mutation-check each gate individually. | Low if the right helper is used. |
| **C-R7** | An implementer hooks the gate onto `UnitLoadController`'s existing constant argument, which is really the `comment`. | Medium | §2.4; §0.D documents the 478-row evidence | Low. |
| **C-R8** | Gating a shared endpoint 403s the mobile UI. | Medium | `transferStock` / `storageLocationsForStockMovement` are explicitly excluded (§0.B last row) | Low. |
| **C-R9** | Flyway version collides with V2.2.18 or an unmerged branch. | Medium | P6 re-sweep immediately before the PR | Low at the moment of the sweep. |
| **C-R10** | `PRINT_TOTE_LABELS` bundled in and holds up the other seven. | Medium | §0.F defers it to tranche C2 | Low. |

---

## 6. Acceptance criteria

| # | Criterion | Test |
|---|---|---|
| C-1 | Each of C.1–C.13 denies with **403** without its function — **single AND bulk** | one pair per endpoint, §4.1 |
| C-2 | Each allows with the function | same pairs |
| C-3 | **A denied bulk request returns 403, not `200 {errors:[…]}`** | `bulkAdjustAmount_deniedReturns403NotOk` — the §2.2 fact-1 pin |
| C-4 | Authorization is read **once per request**, not once per id | `bulkX_shouldCheckAuthorizationOncePerRequest` |
| C-5 | Every gated controller is in the `FunctionGuardArchTest` golden map — **the ArchTest map, NOT `FunctionGuardInterceptor.GUARDED`; adding these classes to `GUARDED` fail-closes their ungated read handlers (§0.G F1)** | ArchUnit |
| C-6 | ~~Removing any one annotation fails bean initialisation~~ 🔴 **STRUCK — unachievable, see §0.G F1.** `FunctionGuardStartupAssertion` only inspects classes in `GUARDED`, and these two must not join it. **Replacement:** an ArchUnit rule enumerating all 13 endpoints by **name + parameter arity** (§0.G F5) and asserting each resolves a `@RequiresFunction` | ArchUnit — carries the whole anti-drift burden, so mutation-check it individually |
| C-7 | The header is referenced by symbol, never by literal | verify row `file_not_contains '"X-Authz-Denied"'` + an `[inherited]` row that `Authority.AUTHZ_DENIED_HEADER` resolves. ⚠ **Real paths: `net/aim_ai/wms/Authority.java:99` and `net/aim_ai/wms/SecurityConfiguration.java:193-194`** — not `security/`/`config/` as §2.3 says; a row naming the wrong file PASSES while asserting nothing (§0.G F4) |
| C-8 | The grant migration includes **ACTION** grants | `UtilRestControllerSeedUnitTest#seedsActionFunctionsPerTheApprovedTable` — guards §2.6, the silent capability removal |
| C-9 | Grant migration is idempotent, `NOT EXISTS`, no `ON CONFLICT` | verify rows |
| C-10 | `transferStock` and `getStorageLocationsForStockMovement` keep exactly 2968's annotations | regression pin — ⚠ **key on name + parameter arity: the name is OVERLOADED** (:598 no-arg, :608 `@PathVariable labelId`), see §0.G F5 |
| C-11 | UI controls are disabled without the function | Jest, §4.3 |
| C-13 | **No `controller/rest/*` class carries `@RequiresFunction`** (G-1) | ArchUnit — protects the unauthenticated OMS path |
| C-14 | **No `controller/rest/*` class is in `GUARDED`** (G-2) | ArchUnit, reading `GUARDED` by reflection |
| C-15 | **`anonymous` holds zero functions** on every tenant (G-3) | audit row — a granted sentinel makes an unauthenticated caller privileged |
| C-12 | Mobile Move Stock with damaged stock is unaffected — ⚠ the mobile services live in **`service/mobile/`**, not `service/` | M12 + the unchanged `transferStock` service branch |

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2967-C-web-action-gating.sh`. ⚠ **Do not carry over
rows `E1–E9` from the pre-split script** — E1–E6 target the superseded service-layer placement, E8 pins a
guard that does not exist, and **E9 asserts no `WEB_UI_ACTION_*` appears inside a `@RequiresFunction`, which
would fail a correct implementation.** All are replaced.

---

## 7. Scalability

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | no server cache added |
| 2 | Connection pool | No | **One uncached `getAllRoles` per request.** ⚠ Only true because of controller placement (§2.2 fact 3); service placement would make it once per id on bulk paths. |
| 3 | Long transactions | No | Guards sit at method entry, before business work |
| 4 | Retry / idempotency | No | A denied action never executes |
| 5 | Tenant context | **Yes — load-bearing** | `getAllRoles` reads the tenant DB; guards run inside request scope, after `TenantFilter` |
| 6 | Observability | — | Reuses 2968's `wms2.authz.*` counters |

**v2 constraints:** OSIV disabled — guards return `List<String>`, no lazy proxy escapes · no new
`@Transactional` (a bare one would bind to the **landlord** TM) · Jakarta namespace N/A · Mockito-only tests.

---

## 8. Provenance

Carved out of `SBDEV-2967-web-ui-function-gating-enforcement.md` on 2026-08-21 and re-verified against
`origin/develop` `5506117`. C.1/C.2 arrived from SBDEV-2870 on 2026-08-17 with a proven implementation
(§2.3). The controller-vs-service contradiction (§2.1) was found during the carve, not present in any prior
review — the pre-split document had shipped both instructions simultaneously, with verify rows enforcing the
superseded one.
