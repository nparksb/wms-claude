---
title: "Report/monitor read gating — a WEB_UI_VIEW_* function on 20 POST/GET-as-query read handlers"
ticket: "SBDEV-3142"
ticket_url: "https://app.clickup.com/t/868kxzjwm"
type: "bugfix"
priority: "high"
status: "ON DEV 2026-08-31 — merged to develop: wms2-api#252 (4daad5d8) + wms2-web-ui#101 (41679877). NOT on main/prd. Open: AC-6 disclosure at closure; P8 Cypress grants (QA); F2 substitutability residual"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-08-31"
updated: "2026-08-31"
db_verified: true
db_verification_note: >
  Verified 2026-08-31 across all FIVE v2 tenant DBs: dev_wh01_om1 (WineCo dev), wh01_om1_v2 (WineCo
  UAT), wh01_hydra_v2 (Hydra PRD -- the ONLY client on v2 production), plus Hydra UAT and ShipItEZ UAT.
  All 12 WEB_UI_VIEW_* constants this plan assigns exist in mywms_function in every one, so no gate can
  fail closed for a whole tenant. Holders: WineCo dev 42-46 of 99, Hydra PRD 7 of 9 (2 newly denied per
  report -- intended, and a release-note item). AC-1 was additionally satisfied by a LIVE probe (see
  1.5): a 4-function user pulled 566,050 bytes -- the whole location table -- from
  exportStorageLocations; 29 of 33 paths confirmed leaking, 4 inconclusive on an empty dataset.
  A sixth DB (wms1-wineco) was surveyed mid-review and produced a FALSE "WineCo production breaks"
  escalation; it is WineCo's WMS v1 production, where v2 function gating does not exist. Withdrawn --
  see 1.4. WineCo has no v2 production instance.
related:
  - "SBDEV-3017"
  - "SBDEV-3158"
  - "SBDEV-3169"
  - "SBDEV-2967"
  - "SBDEV-2968"
  - "SBDEV-3063"
tags:
  - plan
  - authorization
  - reports
---

# Report/monitor read gating — a `WEB_UI_VIEW_*` function on 20 read handlers

**Ticket:** [SBDEV-3142](https://app.clickup.com/t/868kxzjwm)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix (authorization gap)
**Priority:** high
**Status:** ✅ **IMPLEMENTED — not merged.** 7 review lanes total (4 pre-impl: design · facts · security · tests; 3 post-impl: conformance · code · security), every finding applied. **AC-1 live probe DONE** (§1.5) — 29 of 33 paths measured leaking. Scope settled at **20 methods / 33 paths**; **AC-6 formal on the ticket**. **No dev-side blocker**: P7 withdrawn (§1.4), P8 is QA-owned, F2 accepted as a recorded residual, `GUARDED` enrolment deferred.
**Date:** 2026-08-31
**Tier:** T3 (authorization · 20 handlers · a 200→403 contract change · over-gating breaks live screens)

---

## 0. What changed from the ticket, up front

Six corrections to the ticket, plus one scope change Nam approved. Each is evidence-backed below; they
are collected here because each one would otherwise be discovered mid-implementation.

✅ **AC-1 is satisfied — §1.5.** A 4-function user pulled **566 KB, the entire location table**, from
`exportStorageLocations`, plus real data from 27 more paths. Measured, not inferred.

✅ **No release blocker.** All twelve constants exist in all five **v2** tenants, including the only
client on v2 production (Hydra). A mid-review escalation claiming otherwise was **false** — it rested on
WineCo's **v1** production DB, where v2 gating does not exist. Withdrawn; see §1.4 for the round trip.

⚠️ **Read §3.7 first if you read nothing else.** Four review lanes ran on this plan and the security
lane's finding is the one that changes the ticket's meaning: **this fix closes the exposure of zero
datasets on its own**, because all 19 endpoints it assessed have an SDR twin that stays open (row 20
was added after that lane ran and is not yet assessed on this axis). It is still worth
shipping; it must not be reported as protecting the report surface.

**Corrections the review lanes made to THIS plan** (all applied; full reports in
`SBDEV-3142-evidence/`):

| lane | finding | disposition |
|---|---|---|
| security | 19 of 19 endpoints keep an equivalent open route; 13 are `identical` | **§3.7 added**, AC-6 proposed |
| design · tests · security (independently) | the 19 were selected by a `$2=="POST"` awk filter, not a principle — 41 handlers on these controllers are ungated | **§1.2 corrected**; boundary restated as read-vs-mutate |
| design · facts | §3.6's `GUARDED` rejection rested on two false premises | **reversed** — enrollment now recommended |
| tests | T6 vacuous (assertion skips non-`GUARDED`); T4 named a nonexistent method; T1–T6 pinned the mechanism 19× and the function 0× | **T6 deleted, T4 fixed, T1 strengthened, T7 added** |
| tests | PIT cannot see annotation removal | **4 manual mutants substituted**, stated honestly |
| design | the Cypress suite directly calls **5** of the 20 — invisible to both caller lanes | **§6 subsection added** |
| facts | `/inactiveClubRun` returns *inactive* batches; my defect claim was wrong twice | **retracted** — name-only bug |
| facts | §3.4's cited evidence was wrong (`outboundBols/getOrderDetails` is dispatched nowhere) | **corrected**; conclusion unchanged |
| facts | 793→792 rows; max functions 80→81; two internal self-contradictions | **all fixed** |
| security | SBDEV-3158 already owns the ~90 remaining MVC reads, and widening 3142 was tried and **retracted** on 2026-08-28 | **§7.1 and §7.3 widening recommendations retracted** |

Two of my own conclusions were wrong in the same direction — proposing scope that another ticket
already owned. Both are retracted in place rather than deleted, so the error is visible.

| # | Ticket says | Reality | Where |
|---|---|---|---|
| 1 | "the only account available (`panderson`) holds all 79, so it cannot distinguish" — AC-1 is blocked | **AC-1 is not blocked.** Four DEV accounts hold usable subsets, including a *differential* pair that can prove the gate is keyed on the right function rather than merely denying everyone. Also: `panderson` holds **80**, and the DEV max is **81** | §1.3 |
| 2 | 16 handlers | **19**, by Nam's decision 2026-08-31: the 3 ungated GET `*View` reads on the same controller, dual-mapped the same way, belonging to no other ticket | §1.2 |
| 3 | "`ReportController` — 10 export handlers, dual-mapped … (20 paths)" | Correct. But the controller declares **14** handlers of which **13** are ungated (10 POST + 3 GET), across **26** paths. SBDEV-3169 §2.7's "15 handlers / 14 ungated" is wrong and is corrected in that file | §1.2 |
| 4 | AC-4: verify "by re-running the server-side inventory rather than by grep" | The inventory is the right instrument but **cannot be the sole verifier**: it keys on `getBeanType()` while the interceptor keys on `getMethod().getDeclaringClass()`, and those diverge precisely on this inheritance pair | §3.3 |
| 5 | — | Six more `/v3` endpoints of identical shape exist outside the ticket's three controllers — **already owned by SBDEV-3158**, so nothing to file. An earlier draft proposed a new ticket; retracted | §7.1 |
| 6 | — | The read surface on the ticket's own three controllers is **41** ungated handlers. **`GET /v3/transfers/skus` taken into scope (Nam, 2026-08-31) ⇒ 20 methods / 33 paths**; the other 12 GET reads stay SBDEV-3158's | §1.2, §7.3 |

---

## 1. Problem Statement

### 1.1 The defect

Twenty handlers on `ReportController`, `ClubLineController` and `TransfersController` are **reads** —
they stream a report or return DTOs and write nothing — and none carries an authorization annotation.
Ten of them export an entire dataset. A user denied the corresponding screen by the web UI's menu
guard can still obtain the full data by calling the endpoint directly.

The exposure is **authenticated, not anonymous**: these sit under `/v3/**`, which requires
authentication. The precise claim is *"any authenticated `wms_user`, regardless of screen
entitlement"*.

The web UI's own gate catalog is what makes this a defect rather than a design: `util/appMenuList.js`
is described in its own header as *"the single source of truth for 'which screen needs which
function'"*, and `middleware/require-function.js` enforces it on navigation. The menu therefore
already asserts an entitlement that the API does not check.

### 1.2 The surface — derived from the runtime, then reconciled with source

Enumerated on `origin/develop` @ `d434a3e5` by running `SurfaceInventoryContextTest`
(`mvn -o test -Dtest=SurfaceInventoryContextTest`, 1 test, BUILD SUCCESS, 19.3 s) in the per-ticket
worktree, which writes `target/surface-inventory.tsv` — **792** deployed handler rows from
`RequestMappingHandlerMapping.getHandlerMethods()` (the file is 793 lines; line 1 is the header). **Not from grep.**

**20 distinct methods, 33 distinct paths.**

| group | methods | paths | why the path count differs |
|---|---|---|---|
| `ReportController` POST exports | 10 | 20 | dual-mapped |
| `ReportController` GET `*View` reads | 3 | 6 | dual-mapped |
| `ClubLineController` POST | 3 | 3 | single-mapped |
| `TransfersController` POST | 3 | 3 | single-mapped |
| `TransfersController` GET (`/skus`, row 20) | 1 | 1 | single-mapped — **added by Nam 2026-08-31**, see §7.3 |
| **total** | **20** | **33** | |

⚠️ **The awk that produced the original 19/32 is recorded here as a WARNING, not as the derivation.**
It read `... || ($2=="POST" && $5 ~ /ClubLineController|TransfersController/)`, and that `$2=="POST"`
is what hid row 20 — a boundary set by a filter rather than a decision. Do not re-run it expecting the
current scope.

#### 🔴 …but 19 is not the whole read surface on these three controllers. **41 handlers are ungated.**

Found by the test-adequacy review lane, which noticed that `GET /v3/transfers/skus` is excluded from
the 19 **by my own `$2=="POST"` awk filter** while its POST namesake is row 14. Re-deriving without
the verb filter — all ungated handlers *declared* on the three controllers, `AdminController`-declared
aliases excluded:

| kind | methods | owner |
|---|---|---|
| POST reads | 16 | **this ticket** (rows 1–10, 14–19) |
| GET reads on `ReportController` | 3 | **this ticket** (rows 11–13) |
| **GET reads on `ClubLine`/`Transfers`** | **13** | 1 (`/transfers/skus`) is **row 20 of this ticket**; the other 12 are **SBDEV-3158's** — see §7.3 |
| GET handlers that **mutate** | 9 | **not this ticket** — the state-change axis |
| **total ungated** | **41** | |

The 9 mutating GETs are confirmed by reading their bodies, not inferred from their names:
`assignStagingLaneToOrderBatch`, `unlinkStagingLaneFromOrderBatch`, `runClubLine`,
`activateAndAssignTransferLane`, `assignTransferLaneToTransferOrder`,
`billofladingService.transferOrder(orderId)` and three siblings. These are state changes reachable by
a bare GET, which is the **state-change axis** — SBDEV-3017's territory, and its own record already
notes `runClubLine`/`runTransfer` remain open. They are deliberately out of scope here and this plan
must not quietly absorb them.

**So the read/mutate split is what makes the boundary principled; the verb is not.** A POST filter
was the wrong instrument and produced a boundary that looks deliberate and is not.

**Why the dual mapping exists** — the ticket states it but not the mechanism, and the mechanism is
what decides the fix. `DashboardController.java` declares
`public class DashboardController extends ReportController` under `@RequestMapping("/v3/dashboard")`,
so every handler `ReportController` declares is re-registered under the subclass's prefix. This is
inheritance, not a second annotation, which is why there is no `/v3/dashboard` **mapping** anywhere in
`ReportController`. (The literal string *does* occur there once, in a comment at `:310` explaining this
very point — so a reader who greps `dashboard` to check the claim gets a hit and should not read it as
a contradiction.)

The TSV confirms it row by row: `/v3/report/exportInventory` and `/v3/dashboard/exportInventory` are
two rows with **different** `beanType` (`ReportController` / `DashboardController`) and the **same**
`declaringClass` (`ReportController`).

**The three GET reads added by scope decision** (Nam, 2026-08-31) — all `ReportController`-declared,
all dual-mapped:

| path (× both prefixes) | handler method | note |
|---|---|---|
| `/flowbinMonitorView` | `floowbinMonitorView` | ⚠ the method name is misspelled in source; grep for the **path**, not the method |
| `/parcelPickingView` | `getDetailView` | ⚠ method name does not resemble the path at all |
| `/parcelMonitorView` | `parcelMonitorView` | |

Those two name mismatches are why a method-name-keyed test or verify row would silently miss two of
the three. Key on the path or on the `declaringClass#method` pair from the TSV.

### 1.3 🔴 The ticket's AC-1 blocker does not exist — and the better instrument is a *differential* account

The ticket says AC-1 cannot be satisfied because `panderson` holds everything. Measured 2026-08-31
against `dev_wh01_om1` using the **exact production query** — `UserRepository.getAllRoles`, the
five-table `mywms_user → mywms_group_mywms_user → mywms_group_mywms_role →
mywms_role_mywms_function → mywms_function` join that `AccessService.checkAnyAccess` consumes, not a
hand-rolled approximation:

| account | fns | `CLUB_LINE` | `TRANSFER_ORDER` | `INVENTORY_RECORD` | `LOCK_OVERVIEW` | `RECV_OVERVIEW` |
|---|---|---|---|---|---|---|
| `truckloading` | 4 | ✗ | ✗ | ✗ | ✗ | ✗ |
| `marthamina` | 8 | ✗ | ✗ | ✗ | ✗ | ✗ |
| `estellavasquez`, `josiemarks` | 27 | **✓** | **✓** | ✗ | ✗ | ✗ |
| `sbtest` | 35 | ✗ | ✓ | ✓ | ✓ | ✗ |
| `panderson` | 80 | ✓ | ✓ | ✓ | ✓ | ✓ |

**`estellavasquez` is the load-bearing account, and a zero-function user is not a substitute.** A
deprived-only probe cannot distinguish *"the gate works"* from *"the gate denies everyone"* — and
denying everyone is the failure mode that breaks production while looking like a successful fix. She
holds `CLUB_LINE` + `TRANSFER_ORDER` but not `INVENTORY_RECORD`, so post-fix she must be **allowed**
on `/clubLine/*` and **denied** on `/report/exportInventory`. One account, both directions.

Incidental corrections: the DEV maximum is **81** functions (`sbuser1` and `sbuser15`); `panderson` holds 80, not the 79 the ticket states. (An earlier draft wrote "the max is 80, not 79" while also naming two accounts at 81 — self-contradictory, and the 81 is correct.)
**45 of 99** accounts hold zero functions — mostly `Z-*(archived)` and service identities — so a
zero-function user proves denial but can never prove the allow half.

### 1.4 Blast radius — all five **v2** tenants have all twelve functions

| v2 tenant DB | handle | env | 12 present? | users | holders per fn |
|---|---|---|---|---|---|
| `dev_wh01_om1` | `wms2-wineco-dev` | WineCo dev | 12/12 | 99 | 42–46 |
| `wh01_om1_v2` | `wsl-wineco-uat` | WineCo UAT | 12/12 | 94 | — (presence only) |
| `wh01_hydra_v2` | `wms2-hydra` | 🔵 **Hydra PRD — the only client on v2 production** | 12/12 | 9 | 7 |
| `nywh` hydra | `nywh-hydra-uat` | Hydra UAT | 12/12 | 19 | — (presence only) |
| `c1wh` shipitez | `c1wh-shipitez-uat` | ShipItEZ UAT | 12/12 | 36 | — (presence only) |

**No gate can fail closed for a whole tenant.** On the only v2 production tenant, Hydra, all twelve
constants exist and 7 of 9 users hold each — so 2 of 9 are newly denied per report. That is the intended
effect and belongs in the release note, but it is a population change, not an outage.

⚠️ **This section went wrong and came back, and the round trip is the lesson.** The claim above was in
the first draft, correct. A review lane observed that only one of the five DBs surveyed was production,
which was a fair challenge — so I surveyed a sixth, found `WEB_UI_VIEW_PARCEL_PICKING` absent, and
escalated *"WineCo PRODUCTION breaks, 93 users denied, blocks release"* as **P7**, plus a comment on
SBDEV-3017 alleging an already-merged gate was a latent prd break.

**All of that was false.** The sixth DB was `wms1-wineco` — WineCo's **WMS v1** production. WineCo has
no v2 production instance; its v2 footprint is dev and UAT only (Nam, 2026-08-31). v1 has no
`FunctionGuardInterceptor` and no `@RequiresFunction` at all — as **this plan's own §4 says** — so no v2
gate is ever evaluated against that catalogue. Verified after the fact: `wh01_om1` has no
`flyway_schema_history`, no `outbox_message`, no `rest_idempotency`, no `putaway_config`, and 62 tables.
P7 is **withdrawn**; the SBDEV-3017 comment is **retracted**.

**The rule, since a count alone did not protect me:** the population for a v2 feature is the set of **v2
tenants**, identified by schema, not by handle name and not by environment label. "Six DBs surveyed"
and "93 users affected" are worthless if one of the DBs is the wrong product version. The one-query
v1/v2 test lives in the WineCo environment-map memory and I had it available the whole time.

### 1.5 ✅ AC-1 SATISFIED — the exposure is measured. 29 of 33 paths leak real data; 4 are unproven

Run 2026-08-31 against `https://wms-api.dev.sbo.li` (tenant `wineco` / facility `wsl`) with Nam's
credential, and re-run after row 20 entered scope. Accounts: **`truckloading`** (4 functions, holds none of the relevant twelve),
**`sbtest`** (35, the differential), **`panderson`** (80, sb_admin control). Verbatim output in
`SBDEV-3142-evidence/3142-ac1-baseline-probe.md`. **Result: 40 pass, 0 fail, 5 inconclusive.**

**The headline.** A user holding **4 functions**, entitled to none of these screens, received:

| endpoint (both prefixes) | bytes returned to `truckloading` |
|---|---|
| 🔴 `exportStorageLocations` | **566,050 B — the entire location table.** `LocationRepository.exportStorageLocations()` takes no parameters and ignores the request body, so there is no paging to walk and nothing to guess |
| `exportFlowbin` | 7,301 B |
| `exportStockUnitRecord` | 7,268 B |
| `exportSkuLocation` | 7,003 B |
| `exportOutboundParcel` | 6,920 B |
| `exportReceiving` | 6,402 B |
| `exportParcelPicking` | 6,322 B |
| `exportInventory` | 6,041 B |
| `exportContainerRecord` | 6,029 B |
| `exportLock` | 5,736 B |
| `flowbinMonitorView` (GET) | 14,990 B |
| `clubLine/unitLoads` | 11,874 B |
| `clubLine/parcels` · `clubLine/skus` · `transfers/{unitLoads,parcels,availableTransferLanes}` | 525–1,584 B |
| `transfers/skus` (GET, **row 20**) | 547 B |

**AC-4 is now measured, not just reasoned.** Every one of the 10 exports returned the same payload on
**both** `/v3/report/…` and `/v3/dashboard/…` (byte counts identical or ±1). The dual mapping is real
and both halves are live.

**Section F passed:** `dashboard/orderMonitorViewSummary` (4,186 B) and
`dashboard/replenishMonitorViewSummary` (10,325 B) both answer 200 to the deprived user — so the
mobile-shared handlers are live, and the `gated` run can prove they survive.

✅ **Row 20 is covered on the same footing as the other 19, not by analogy.**
`GET /v3/transfers/skus?orderBatchId=30704100` → **200 / 547 B** to `truckloading`. ⚠️ Its
`orderBatchId` is a REQUIRED `@RequestParam`, so omitting it yields a 400 that proves nothing — the
third instance of that trap in this one probe.

⚠️ **4 of 33 paths are INCONCLUSIVE and must not be reported as confirmed.**
`parcelPickingView` and `parcelMonitorView` (both prefixes) return `{"content":[],"totalElements":0}`
— **reachable, but no data leak demonstrated** on the DEV dataset. They need a seeded dataset before
AC-1 can be ticked for them. This is the *advertised capability is not an exploitable capability*
distinction, and it applies to rows 12 and 13 specifically.

#### ⚠️ Two bugs in my own instrument, found and fixed before the run was trusted

Both would have produced a confident wrong answer, in opposite directions. Recording them because the
probe script is now a reusable asset and these are the ways it lies:

1. **The 3 GET `*View` rows omitted `page` and `size`, which are REQUIRED** (`@RequestParam("page")`
   with no default). First run: six 400s that read exactly like "these are already protected". **What
   exposed it as my bug was the control** — `panderson` 400'd too. A 400 proves nothing about
   exposure, because the body is rejected before any gate is consulted.
2. **The empty-payload guard was a byte threshold, `-lt 32` — and `{"content":[],"totalElements":0}` is
   exactly 32 bytes.** So an empty result set was reported as a confirmed leak, off by one byte. Now
   asserts on **content** (`"totalElements":0`, `"content":[]`, `[]`), not size.

The general lesson, and the reason the control rows exist: **the deprived-user rows alone cannot tell
you whether a non-200 is a gate or your own malformed request.** Only the admin control distinguishes
them.

---

## 2. Root Cause Analysis

There is no bug in the gating mechanism. The mechanism is correct, well-documented, and these 19
handlers were simply never enrolled in it.

`FunctionGuardInterceptor.preHandle` resolves in this order:
1. `@PublicHandler` on the method → allow, short-circuit.
2. `@RequiresFunction` on the method.
3. `@RequiresFunction` on `declaring` via `AnnotationUtils.findAnnotation` (**walks the type
   hierarchy** — this is the landmine, §3.2).
4. No annotation → **allow**, unless `declaring` ∈ `GUARDED`, in which case deny fail-closed.

None of the three controllers is in `GUARDED` (the set holds 14 classes: 11 mobile controllers plus
`UserController`, `UserGroupController`, `UserRoleController`). So every unannotated handler on them
takes branch 4's allow path. The interceptor's own javadoc states the consequence for the SDR case in
terms that apply verbatim here: *"such a request falls through allowed, exactly as before."*

### Affected Locations

| file | handlers | current gate |
|---|---|---|
| `controller/ReportController.java` | 13 of 14 declared | only `reprintLabels` — `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_PARCEL_PICKING)` |
| `controller/ClubLineController.java` | 3 POST | none |
| `controller/TransfersController.java` | 3 POST | none |

`reprintLabels` is worth noting as **precedent, not just context**: it is a method-level
`WEB_UI_VIEW_*` gate on this exact controller, added by SBDEV-3017. This plan does the same thing 19
more times. There is no new mechanism.

---

## 3. Design / Proposed Fix

### 3.1 The change: 19 method-level annotations, and nothing else

One `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_…)` per handler method. No new class,
no new interceptor, no migration, and **no UI change in the API PR** — §3.4 does delete one dead web-UI
action in a second, separate PR. (§3.6 additionally recommends one `GUARDED` line as the final step.)

**The per-endpoint function table (AC-2).** Derived by a dedicated web-UI caller lane
(`SBDEV-3142-evidence/3142-web-callers.md`, `wms2-web-ui` @ `9e70a73b`) which traced every endpoint
along the same three hops — Vuex `export` action → `components/reports/popups/exportReport.vue`
`reportType` switch → owning report component → page — and then read the gate out of
`util/appMenuList.js`:

| # | handler (`ReportController`) | function | screen |
|---|---|---|---|
| 1 | `exportInventory` | `WEB_UI_VIEW_INVENTORY_RECORD` | `/reports/inventory-report` |
| 2 | `exportLock` | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | `/reports/lock-report` |
| 3 | `exportReceiving` | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | `/reports/receiving-report` |
| 4 | `exportSkuLocation` | `WEB_UI_VIEW_LOCATION_OVERVIEW` | `/reports/sku-location-report` |
| 5 | `exportFlowbin` | `WEB_UI_VIEW_FLOWBIN_MONITOR` | `/reports/flowbin-report` |
| 6 | `exportParcelPicking` | `WEB_UI_VIEW_PARCEL_PICKING` | `/reports/parcel-picking-report` |
| 7 | `exportOutboundParcel` | `WEB_UI_VIEW_PARCEL_MONITOR` | `/reports/outbound-parcel-report` |
| 8 | `exportStockUnitRecord` | `WEB_UI_VIEW_STOCK_UNIT_RECORD` | `/reports/stock-unit-record` |
| 9 | `exportContainerRecord` | `WEB_UI_VIEW_UNIT_LOAD_RECORD` | `/reports/container-record` |
| 10 | `exportStorageLocations` | `WEB_UI_VIEW_STORAGE_LOCATION` | `/masterData/locationData/storage-locations` |
| 11 | `floowbinMonitorView` → `/flowbinMonitorView` | `WEB_UI_VIEW_FLOWBIN_MONITOR` | `/reports/flowbin-report` |
| 12 | `getDetailView` → `/parcelPickingView` | `WEB_UI_VIEW_PARCEL_PICKING` | `/reports/parcel-picking-report` |
| 13 | `parcelMonitorView` → `/parcelMonitorView` | `WEB_UI_VIEW_PARCEL_MONITOR` | `/reports/outbound-parcel-report` |

| # | handler | function | screen |
|---|---|---|---|
| 14 | `ClubLineController.getSkuView` | `WEB_UI_VIEW_CLUB_LINE` ⚠ see §3.4 | `/processes/club-fulfillment`, `/outbound/club/*` |
| 15 | `ClubLineController.getClubLineUnitLoads` | `WEB_UI_VIEW_CLUB_LINE` | `/processes/club-fulfillment` |
| 16 | `ClubLineController.getParcelView` | `WEB_UI_VIEW_CLUB_LINE` | `/outbound/club`, `/processes/club-fulfillment` |
| 17 | `TransfersController.getTransferLineUnitLoads` | `WEB_UI_VIEW_TRANSFER_ORDER` | `/processes/transfer-fulfillment` |
| 18 | `TransfersController.getParcelView` | `WEB_UI_VIEW_TRANSFER_ORDER` — **no caller found**, decision in §3.5 | — |
| 19 | `TransfersController.getAvailableTransferLanes` | `WEB_UI_VIEW_TRANSFER_ORDER` | `/outbound/transfer`, `/processes/transfer-picking` |
| **20** | `TransfersController.getSkuView` — **`GET /v3/transfers/skus`** | `WEB_UI_VIEW_TRANSFER_ORDER` | `/outbound/transfer`, `/processes/transfer-picking` — **added by Nam 2026-08-31**, §7.3 |

Rows 11–13 reuse rows 5/6/7's functions **by construction**: each `*View` GET feeds the same screen
whose export it accompanies, so the two must share a gate or the screen half-works.

**A `WEB_UI_*` constant on a mobile-reachable surface is not itself disqualifying** — worth stating,
because it looks like it should be. The mobile UI already gates a screen on one of these very
constants: `wms2-mobile-ui util/menuCatalog.js:88` — `role: 'WEB_UI_VIEW_TRANSFER_ORDER'` — with a
deliberate note at `:83` that renaming it would need a coordinated data migration. So the naming
prefix is a red herring; the real constraint is §3.2's inheritance path, not the constant's name.

That same fact is a mild *supporting* argument for rows 17–19: a user denied
`WEB_UI_VIEW_TRANSFER_ORDER` already loses the mobile transfer tile, so gating the three
`/v3/transfers/*` reads on it agrees with an entitlement the estate already asserts, rather than
inventing a new one. (Mobile's own transfer calls go to `/v3/transferOrder/*` on
`controller/mobile/TransferOrderController` — a **different** controller with no dual-mapping to
`TransfersController`; they share only `AdminController`, which contributes no path. So nothing here
touches a mobile endpoint.)

### 3.2 🔴 Method-level only. A class-level annotation on `ReportController` 403s two mobile screens

This is the single most dangerous way to implement this ticket, and it is *tempting* because 13 of the
19 sit on one class and 10 of them take the same function pattern.

`preHandle` step 3 uses `AnnotationUtils.findAnnotation(declaring, RequiresFunction.class)`, which
**walks superclasses**. `DashboardController extends ReportController`. So a class-level annotation on
`ReportController` is inherited by `DashboardController`'s own five GET handlers — which include the
two the **mobile UI** calls:

- `pages/replenish.vue:133`, `:153` — `$get('/dashboard/replenishMonitorViewSummary')`
- `store/picking.js:246` — `$get('/dashboard/orderMonitorViewSummary')`

A `WEB_UI_VIEW_*` gate there 403s mobile Replenish and Picking. This is SBDEV-2968 R12 /
SBDEV-3017 §1.3 exactly, and it was reached independently by both evidence lanes.

**Method-level annotations are immune**, and the TSV proves why rather than asserting it: the five
mobile-facing GETs have `declaringClass = DashboardController`, while all 13 handlers we annotate have
`declaringClass = ReportController`. Different declaring classes, so no annotation on one reaches the
other. §6 pins this with a test **and** with probe section F.

The same rule forbids a class-level annotation on `DashboardController` — and that direction is worse,
because it is **silently inert**: the inventory would report the inherited `ReportController` methods
as gated (its `findMergedAnnotation(getBeanType(), …)` finds the subclass annotation) while the
interceptor, keying on `declaringClass = ReportController`, finds nothing and allows. A green
inventory over an open surface.

### 3.3 AC-4 is satisfied structurally, and the inventory alone cannot verify it

AC-4 asks that "both mappings of every dual-mapped export are covered, verified by re-running the
server-side inventory rather than by grep."

The **coverage** is structural: the annotation attaches to the method, the method is inherited along
with its mapping, and the interceptor resolves on `declaringClass`. One annotation, both paths. Nothing
path-keyed is needed — and the web lane's F4 shows why nothing path-keyed would work: the web UI never
calls the `/v3/dashboard/export*` twins, so **no UI-level regression test can catch a path-keyed gate
that misses them.**

But the **verification must not rest on `SurfaceInventoryContextTest`**, because it and the
interceptor disagree by design:

| | keys on | consequence |
|---|---|---|
| `FunctionGuardInterceptor` | `getMethod().getDeclaringClass()` | what actually happens at runtime |
| `SurfaceInventoryContextTest` | `hm.getBeanType()` | **over-reports** gating across an inheritance pair |

For the fix as designed (method-level) the two agree. They diverge only under the §3.2 mistakes —
exactly when you need the instrument to be honest. The inventory's gated/ungated tallies are therefore
an **upper bound on coverage**, not a verdict.

#### ✅ The correct instrument already exists — extend it, do not invent one

`src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` was built by SBDEV-3017
for precisely this problem and resolves on the interceptor's axis. Its own javadoc states the
divergence: *"`FunctionGuardInterceptor` (line ~166) keys on `getMethod().getDeclaringClass()`"* while
the inventory *"keys on `hm.getBeanType()`. Those disagree for any handler inherited from
`AdminController` into a subclass that carries a class-level `@RequiresFunction`."*

Its shape is exactly what AC-4 needs:

- a row table keyed on **`declaring class simple name + " " + path`** — `private static void row(String declaringClass, String path, String... functions)` — so each of our 33 paths gets its own row and the dual mapping is asserted per path, not inferred;
- resolution via `AnnotatedElementUtils.findMergedAnnotation(m.getDeclaringClass(), …)`, the interceptor's axis;
- `everyTrancheRouteCarriesItsIntendedFunctions()` — drift detection in both directions (a route that gained a gate, and one that lost one);
- a **separate** `@Test thePinHasNotBeenQuietlyShrunk()`, deliberately not folded into the drift test.

That last one matters here more than it did for SBDEV-3017. Its comment records the measured reason:
*"deleting the class annotation reddened only 4 of 74 rows"* — i.e. an under-specified pin let a
whole-class un-gating pass. Our change is 20 annotations that a future reader may well try to
"simplify" into one class-level annotation (§3.2), so the anti-shrink pin is the test that catches the
most likely regression.

**Decision: add our 33 rows to this class (or a sibling modelled on it), and treat the inventory as a
cross-check only.** AC-4/AC-5 are then evidenced by three independent instruments: this test (runtime
axis, per path), the inventory (upper bound), and probe section A (over the wire, both prefixes).

### 3.4 Landmine — `clubLine/skus` has a dead second caller behind a *different* gate

`store/outbound/outboundBols.js#getItemInfo` POSTs `/clubLine/skus` and has **no dispatcher** — dead
code.

⚠️ **The first draft's supporting evidence was wrong and is corrected here.** It claimed the sibling
`getOrderDetails` *in the same store* is live on the Outbound BOL screen. It is not:
`git grep "outboundBols/getOrderDetails" origin/develop` → **0 hits**. What is live is
`outbound/club/getOrderDetails`, dispatched from `components/outbound/bol/outboundBolDetailsTable.vue:201`
— a **different** store module.

The corrected picture is weaker in one way and stronger in another. Weaker: **no live path reaches
`/clubLine/skus` from a `BILL_OF_LADING` screen today**, because the neighbouring
`outbound/club/getItemInfo` (dispatched from the same component at `:202`) GETs
`/customerOrderPosition/detailsByOrderId`, not `/clubLine/skus`. Stronger: that component **already
reaches across into the club module from a BOL-gated screen**, so the cross-module coupling this
finding worries about is real and in use — it simply does not touch our endpoint yet.

**Decision: gate on `WEB_UI_VIEW_CLUB_LINE` (matching the live caller) and delete the dead action** in
the web UI, in the same PR pair. Deleting it is cheaper than an ANY-of gate that widens the endpoint
permanently to satisfy code nobody calls. If Nam prefers to keep the action, the gate becomes
`{CLUB_LINE, BILL_OF_LADING}` ANY-of and that must be recorded as a deliberate widening.

### 3.5 `TransfersController.getParcelView` — no caller found in either UI

Swept in both UIs at `origin/develop`: 0 hits in `wms2-web-ui` (agreed by two independent instruments,
`git grep` and `command grep`) and 0 in `wms2-mobile-ui` @ `c79e81c3`. Its body is **identical in
effect** to `ClubLineController.getParcelView` — both are
`return dtoViewService.getOrderDetailView(orderBatchId)` — which reads like unfinished API symmetry.

✅ **Caveat CLOSED by the code-review lane 2026-08-31.** An earlier draft said "no caller found, not
no caller" because neither caller lane had swept `omsv2-UI` or `oms-laravel-api`. Both have now been
swept with positive controls (50 and 313 files matched respectively, so the sweep demonstrably reached
the trees) and both return **zero** callers. Across all four consuming repos, nothing calls
`POST /v3/transfers/parcels`. The function assignment stays by analogy to its two siblings — there is
still no traced screen — but "uncalled" is now measured rather than assumed.

⚠️ **A sweep trap worth carrying forward: `omsv2-UI` has no `origin/develop`.** Its default branch is
`origin/main`, so a sweep written against `develop` there returns a silent zero that looks like a
clean result. Any future cross-repo enumeration must name the branch per repo.

It is nonetheless live and returns data, so *uncalled* is not *closed* — this estate's rule that an
advertised capability is not an exploitable one cuts the other way here, because the capability is
demonstrably exploitable, merely unused.

**Decision: gate it `WEB_UI_VIEW_TRANSFER_ORDER`**, matching its controller and its two siblings. This
satisfies AC-2's "recorded per-endpoint decision". Deleting it is defensible but is a separate
API-surface removal and is deliberately **not** bundled into an authorization fix.

### 3.6 What this plan explicitly does NOT do

- 🔴 **Does not touch SDR — and that matters far more than the first draft admitted.** The draft said
  the two tickets are "complementary" and called this "the MVC half". Both claims are too generous;
  **see §3.7**, which the security lane forced and which is now the single most important section for
  anyone reading this ticket's outcome.
- **Does not touch `/rest/**`.** Internal-only WMS↔OMS, JWT deferred, ruled not-a-live-exposure
  2026-08-27. The inventory surfaces four `/rest/report/*`, `/rest/stockcount/*` POST-as-query reads;
  they stay out and the probe script has no rows for them.
- 🔴 **`GUARDED` enrollment for `ReportController` — REVERSED. The first draft rejected this on two
  premises, and the design review showed both are false.**

  The draft said enrolling it "would make its one remaining unannotated handler — and every handler
  added later — deny fail-closed, and the boot assertion would refuse to start." Measured:

  1. **There is no remaining unannotated handler after the fix.** `ReportController` declares 14
     handlers; this plan annotates 13 and `reprintLabels` is already gated. That is 14 of 14.
  2. **The boot assertion keys on `declaringClass`**, not the bean type —
     `FunctionGuardStartupAssertion:148` `Class<?> declaring = handler.getMethod().getDeclaringClass();`
     then `:149` `if (!guarded.contains(declaring)) { continue; }`. So `DashboardController`'s own six
     handlers (declaringClass `DashboardController`, not in `GUARDED`) are **skipped entirely** and
     cannot become violations.

  So enrolling `ReportController` is safe *after* the annotations land, and it buys the **deletion
  tripwire**: remove any one of the 13 and the application **refuses to boot**, rather than silently
  falling through allowed. That is strictly stronger than any test — it is the property the
  `UserRoleController` / `UserGroupController` entries exist for (see the corrected comment in
  `FunctionGuardInterceptor.GUARDED`).

  **Recommendation: enroll `ReportController` in `GUARDED` in the same PR, as the final step** — after
  the 13 annotations, so the boot assertion is green at every commit.

  🔴 **ATTEMPTED 2026-08-31 AND REVERTED — this recommendation is blocked by a test-model conflict, not
  by the runtime argument above, which the conformance lane confirms still holds.**
  `UserControllerPublicHandlerUnitTest` AC-4d pins a deliberate three-way equality
  `GOLDEN_MAP == EXPECTED_GUARDED == GUARDED` across three hand-maintained lists. `ReportController`
  cannot join `GOLDEN_MAP`: that map is controller → **one class-level function**, and
  `FunctionGuardArchTest` AC-1/AC-2 require it to exist **as a class-level annotation** — precisely what
  §3.2 forbids and what the M4 mutant proves 403s two mobile screens.

  So enrolment requires relaxing a security invariant three tests exist to maintain. That is an owner
  decision, and no AC requires the enrolment, so it is **deferred, not dropped**. The security lane
  rates its absence **Medium** — the deletion tripwire is missing.

  ⚠️ That lane made the severity conditional on whether the reflection pins run in a green CI lane.
  **They do — settled with evidence:** the full `mvn -o clean test` (5815 tests / 0 failures) includes
  `Sbdev3017TrancheGateContextTest` (2 tests) and `ReportReadGateUnitTest` (9 tests). So the 13
  annotations DO have automated protection and F1 stays Medium rather than rising to High.

  ⚠️ **`ClubLineController` and `TransfersController` must NOT be enrolled.** They carry 13 ungated GET
  reads (§7.3) plus **9 GET handlers that mutate** (§1.2). Enrolling either fail-closes all of them and
  no replica starts. They become eligible only if scope widens to every read *and* the mutating GETs
  are gated — which is the state-change axis and out of scope here.

---

### 3.7 🔴 This fix closes the exposure of ZERO datasets on its own. Ship it anyway — but never claim otherwise

The security lane's finding, and the most important sentence in this plan:

> **19 of 19 gated endpoints have another route returning substantially the same rows to the same
> authenticated `wms_user` after this fix ships. 13 of 19 are `identical` — the same repository query
> method, exported over Spring Data REST at a URL derived mechanically from the method name.**

⚠️ **That lane assessed the 19; row 20 (`GET /v3/transfers/skus`) was added afterwards and has NOT been
assessed on this axis.** Its body is `transferOrderService.getSKUOverview(orderBatchId)`, so it very
likely has an SDR twin too — but that is an inference, not a measurement, and AC-6 must record it as
unassessed rather than assumed. Do not round "19 of 19" up to "20 of 20".

Method: for each handler, read the controller body → the service method → the repository method it
calls, then that repository's `@RepositoryRestResource` and method-level `@RestResource`, then
`RestConfiguration` for a verb withdrawal. `RepositoryDetectionStrategies.ANNOTATED` +
`setBasePath("/v3")` means every annotated repository is exported; SDR handlers resolve to
`RepositorySearchController` / `RepositoryEntityController`, absent from `GUARDED`, so branch 4 allows
them. **Blind spot, stated:** source-derived, not runtime-derived — no HTTP request was sent, so each
is an *exposure* claim, not a measured 200.

The sharpest examples, because they need no ids and no paging:

| gated by this ticket | still open after it | grade |
|---|---|---|
| `POST /v3/report/exportStorageLocations` | `GET /v3/location/search/exportStorageLocations` — `LocationRepository:333` `List<StorageLocationExportView> exportStorageLocations();`, **zero parameters, whole-table native query** | identical |
| `POST /v3/report/exportInventory` | `GET /v3/stockView/search/findByClientOffsetAndLimit` — the exact method `ReportService:79` calls | identical |
| `POST /v3/report/exportLock` | `GET /v3/lockOverviewAllDtoView/search/findByClientOffsetAndLimit`, **plus** the collection `GET /v3/lockOverviewAllDtoView?size=100000` — `findAll` is not un-exported | identical |
| `POST /v3/transfers/availableTransferLanes` | `GET /v3/location/search/getAvailableTransferLanes` — `LocationRepository:95`, the exact query `TransferOrderService:84` runs | identical |

So §1.1's severity sentence — *"a user denied the corresponding screen can still obtain the full
data by calling the endpoint directly"* — **remains true after this fix**, with *endpoint* rebound from
`/v3/report/exportInventory` to `/v3/stockView/search/findByClientOffsetAndLimit`.

**This is the `a-guard-fences-the-mechanism-you-aimed-at` failure, and this plan came within one review
lane of committing it** — not by gating the wrong thing, but by allowing the ticket to read as *"the
report data is now protected."*

**Why ship regardless.** The annotations are cheap and correct; the audited-route precedent already
exists on the same class (`reprintLabels`); a gate on the audited route is what gives the deny metric
and the `X-Authz-Denied` header something to say; and SBDEV-3169 explicitly stakes its Slice 3 on this
landing. Gating the front door is not worthless because a side door exists — it is worthless only if
you then announce the house is secure.

#### 🔴 A residual INSIDE this fix — the two gates are mutually substitutable (security lane F2)

Found post-implementation and **verified independently**: the fix partitions by *controller*, but the
data is partitioned by *batch id*, and nothing binds the two.

`ClubLineController.getParcelView` and `TransfersController.getParcelView` are **character-identical**:

```java
Long orderBatchId = Long.valueOf( (Integer) reqMap.get("orderBatchId") );
return dtoViewService.getOrderDetailView(orderBatchId );
```

and `ViewDtoService.getOrderDetailView` calls `customerorderRepository.getOrderViewsByBatchId(orderBatchId)`
with **no batch-type filter**. So a user holding `WEB_UI_VIEW_TRANSFER_ORDER` but not
`WEB_UI_VIEW_CLUB_LINE` can POST a **CLUB** batch id to `/v3/transfers/parcels` and receive exactly what
`/v3/clubLine/parcels` — which they were just 403'd from — would have returned. And symmetrically.

**What the fix does and does not buy, stated precisely.** It genuinely denies a user holding *neither*
function (the measured `truckloading` case, and the bulk of the exposure). It does **not** separate CLUB
from TRANSFER entitlement, which assigning two different functions implies it does.

⚠️ **SBDEV-3169 will NOT close this** — it is a cross-controller MVC substitution, not an SDR twin, so it
falls outside AC-6's residual table as written. It needs either a batch-type check in both handlers or a
deliberate decision that the two functions are equivalent for this data. **That is a functional change
this plan did not design, so it is recorded here and proposed, not improvised.**

#### ✅ MEASURED 2026-08-31 against DEV with `panderson` — no longer an inference

The code-reading argument above was confirmed end-to-end by feeding each controller the **other type's
batch id** (`panderson`, tenant wineco / facility wsl; CLUB batch `18988442` with 652 orders,
TRANSFER_OFFSITE batch `16225108` with 1):

| call | HTTP | payload |
|---|---|---|
| `POST /v3/clubLine/parcels` ← CLUB batch (native) | 200 | 652 rows, **343,396 B** |
| `POST /v3/transfers/parcels` ← **CLUB batch (foreign)** | 200 | 652 rows, **343,396 B — byte-identical** |
| `POST /v3/transfers/parcels` ← TRANSFER batch (native) | 200 | 1 row, 500 B |
| `POST /v3/clubLine/parcels` ← **TRANSFER batch (foreign)** | 200 | 1 row, **500 B — byte-identical** |

So post-fix a user holding only `WEB_UI_VIEW_TRANSFER_ORDER` reads **652 club orders (343 KB)** through
`/v3/transfers/parcels` — precisely the payload `/v3/clubLine/parcels` would have 403'd them from.

The other two pairs call *different* services (`getClubLineSKUOverview` / `getSKUOverview`,
`getClubLineUnitLoads` / `getTransferLineUnitLoads`), and the measurement refines the security lane's
"equivalent the same way" rather than simply confirming it — **same data, different projection**:

| pair, fed a CLUB batch | native | foreign | verdict |
|---|---|---|---|
| `skus` | 2,740 B | 2,660 B | same SKU ids and names (`936933364` "2023 Estate Chardonnay 750 ml" first in both); a slightly leaner projection |
| `unitLoads` | 12,899 B | 8,107 B | same unit loads (`65-B03`, id `950610547` first in both); the transfers view returns a subset of the fields |

**All three pairs substitute.** `parcels` is exact; `skus` and `unitLoads` leak the same records through
a narrower projection, which is a difference in completeness, not in entitlement.

**Marginal exposure today is zero, and that is exactly why it matters.** The SDR twin already serves
both sides, so nobody gains access they did not have. The risk is *accounting*: when SBDEV-3169 closes
the SDR route, this pair stays open while the ledger says the resource is closed. §3.5 spotted the
identical bodies and filed them as "unfinished API symmetry" — an API-hygiene reading of what is
actually an authorization fact.

**Recommended remedy** (not applied — functional change, owner's call): validate the batch type in both
handlers, or record a deliberate decision that the two functions are equivalent for this data and gate
both pairs ANY-of. Do **not** leave it assigned to SBDEV-3169; it is out of that ticket's reach.

**AC-6 — APPROVED by Nam 2026-08-31 and now a formal acceptance criterion on the ticket.** It requires
recording, per endpoint, the residual route and its owning ticket (SBDEV-3169 for the SDR twins,
SBDEV-3158 for the MVC sibling reads), and forbids closing the ticket with a claim that the report
surface is protected. The full 19-row table is in `SBDEV-3142-evidence/3142-review-security.md` §1.

The failure it exists to prevent is not a code defect — it is someone reading `on prod` as "closed"
and deprioritising SBDEV-3169 and SBDEV-3158, which is the half of the exposure that actually stays
open. That failure takes months to notice, and one checkbox prevents it.


---

## 3.8 Implementation status (2026-08-31)

**MERGED to `develop` 2026-08-31 — ClickUp `on dev`. Not on `main`/prd.**

| repo | PR | branch |
|---|---|---|
| `wms2-api` | **[#252](https://github.com/SiteBossInc/wms2-api/pull/252)** — merge `4daad5d8`, 18:19 UTC | `bugfix/SBDEV-3142-report-read-gating` |
| `wms2-web-ui` | **[#101](https://github.com/SiteBossInc/wms2-web-ui/pull/101)** — merge `41679877`, 18:20 UTC | `bugfix/SBDEV-3142-drop-dead-clubline-skus-action` |

API merged first. **Verified on `origin/develop` after merging** (not read off the merge result):
`ReportController` 14 `@RequiresFunction`, `ClubLineController` 3, `TransfersController` 4; tranche pin
at `hasSize(123)`; `outboundBols.js` no longer references `/clubLine/skus`.

⚠️ Merging to `develop` here **is a dev deploy** — this is live on dev. No Flyway migration in either PR.

**Still open at `on dev`:** AC-6 (the disclosure obligation, discharged at closure) · P8 (Cypress grants,
QA — merged before it was confirmed, on Nam's instruction) · the §3.7 substitutability residual, which
**neither SBDEV-3169 nor SBDEV-3158 closes**.

**Branches (pushed):**

| repo | branch | commits |
|---|---|---|
| `wms2-api` | `bugfix/SBDEV-3142-report-read-gating` | `5bb1c0df` the 20 annotations · `eabdf1e1` the tests · `f00ccf97` review Lows · `16c2a7af` L2 corrected (4 commits, 5 files, +663/−4) |
| `wms2-web-ui` | `bugfix/SBDEV-3142-drop-dead-clubline-skus-action` | `df7a1e4` delete the dead action |

Base: `origin/develop` @ `c8b3634f`. ⚠️ The base moved **10 commits** mid-implementation (PRs #250,
#251); two of them touched `ClubLineController` and `TransfersController` — logger re-attribution only,
no mapping change. Rebased before any edit.

**Tests:** full suite **5815 / 0 failures / 0 errors / 67 skipped**, `mvn -o clean test`.
`ReportReadGateUnitTest` 9/9 and `Sbdev3017TrancheGateContextTest` 2/2 both run **inside** that green
suite — which is what keeps the missing `GUARDED` tripwire at Medium rather than High.

**Review outcome:** conformance **PASS** (20/20 rows verified three independent ways); code review
**APPROVE with fixes** (0 High, 1 Medium, 4 Low — all Lows fixed in-pass); security **ship it**
(0 High, 2 Medium — both owner decisions, recorded above).

⚠️ **One review fix was itself wrong and is worth recording.** L2 asked for a backstop on T1b's
`isNotEqualTo(403)`. The first attempt used `verify(atLeastOnce())` — useless here, because denial
happens in `preHandle`, so a handler that 500s *after* the guard allowed it has still consulted
`AccessService` and the verify passes on exactly the case it was added to catch. Corrected to
`isEqualTo(200)` in `16c2a7af`.

**P7 withdrawn 2026-08-31** after Nam corrected the tenant map: WineCo has no v2 production instance,
and the DB the escalation rested on is its WMS v1 production. No release blocker remains. The
SBDEV-3017 comment raised on the same false premise has been retracted.

**Not done, by design:** not on production, plan not archived,
worktrees retained at `.claude/worktrees/wms2-{api,web-ui}/SBDEV-3142`. `wms2-web-ui` Jest **not run**
— the deleted action has zero dispatchers, commits a mutation its own module does not define (it would
have thrown), and no spec references it, but that is three static arguments and not a green suite.

---

## 4. V1/V2 Applicability

**v2-only. No v1 work.** v1 has no function-gating mechanism at all — no `FunctionGuardInterceptor`,
no `@RequiresFunction` — and v1 is reference-only in this estate. Nothing to port.

⚠️ **The whole authorization programme is `develop`-only and NOT on prd.** `origin/main` is at
`cf430ff3` (2026-08-20); `FunctionGuardInterceptor` does not exist there. So this fix, like SBDEV-3017
and SBDEV-3005 before it, closes nothing on production until a release ships. State that in the
ticket rather than letting `on dev` read as "fixed".

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | prerequisite | status |
|---|---|---|
| P1 | **AC-1 baseline probe run against DEV** | ✅ **DONE 2026-08-31 — the exposure is MEASURED, not inferred.** See §1.5. Output: `SBDEV-3142-evidence/3142-ac1-baseline-probe.md` |
| P2 | All 12 constants exist in every target tenant DB | ✅ done — §1.4, five DBs |
| P3 | Function table reviewed | ⚠️ 18 of 19 unambiguous; rows 14 and 18 carry recorded decisions (§3.4, §3.5) needing Nam's yes |
| P4 | Worktree off fresh `origin/develop` | ✅ `.claude/worktrees/wms2-api/SBDEV-3142` @ `d434a3e5` |
| P5 | Inventory instrument runs | ✅ verified — 1 test, BUILD SUCCESS, 792 data rows |
| P6 | Baseline suite failure count | ✅ **measured** — `mvn -o clean test` @ `d434a3e5`: **5788 tests, 0 failures, 0 errors, 67 skipped.** `clean` was used, so the total is not inflated by stale `target/test-classes`. **The baseline is zero**, so §5.2 step 8 collapses to "expect zero" and any red is a signal, not the baseline. Do not hardcode 5788 — it moves with every merge; compare *failures* |
| P8 | 🔴 **Confirm the Cypress `KC_USERNAME` account holds `WEB_UI_VIEW_CLUB_LINE` and `WEB_UI_VIEW_TRANSFER_ORDER`** (§6). Query it with §1.3's join | ⛔ **BLOCKS MERGE.** Cypress calls **5 of the 20** directly, via `cypress/support/helpers/wmsHelpers.js` among others; `cypress.env.json` is not in the repo so the grant cannot be read from source. If the account lacks either function, up to four e2e suites go red at merge **and will read as flakiness**, not as a gate working. Both the security and design review lanes asked for this row and it was missed until the conformance lane caught the omission. 🔴 **Measured 2026-08-31, and the prediction is exact.** Cypress calls **7** of the 20 (§6), needing four functions: `CLUB_LINE`, `TRANSFER_ORDER`, `PARCEL_MONITOR`, `PARCEL_PICKING`. Grants on DEV: `panderson` holds all four → suite green. **`sbtest` holds `TRANSFER_ORDER` + `PARCEL_MONITOR` + `PARCEL_PICKING` but NOT `CLUB_LINE`** → the 14 parcel-view specs and the 4 transfers specs pass, and **exactly the 2 `clubLine` specs go red** — a narrow half-red that reads as flakiness rather than as a gate working. `truckloading` and `wmstest` hold none of the four → all 7 fail. `cypress.env.json` is gitignored, so only the runner's env settles which account it is; then run §1.3's join |
| ~~P7~~ | ~~Seed `WEB_UI_VIEW_PARCEL_PICKING` into tenants lacking it~~ | ✅ **WITHDRAWN — the finding was false.** It rested on `wms1-wineco`, which is WineCo's **v1** production; WineCo has no v2 prod instance and v1 has no function gating. All five v2 tenants hold all 12 constants. See §1.4 |

### 5.2 Implementation Checklist

1. **P1 first.** Record the baseline probe output verbatim in this file's §6 and on the ticket. If any
   section-A row returns 200 with <32 bytes, re-derive that row's ids before ticking AC-1.
2. Write the failing tests (§6) and confirm each fails **for the right reason** — an assertion about a
   403, not an NPE or a missing-method error.
3. Add the 20 annotations. Method-level only (§3.2).
4. Delete `store/outbound/outboundBols.js#getItemInfo` in `wms2-web-ui` (§3.4) — a second, small PR.
5. Mutation-check every new assertion; the kill must be **attributable** (the failure message names
   the thing broken). Use PIT scoped to the changed class.
6. Re-run the inventory; assert zero ungated read handlers among the 19.
7. Run the probe in `gated` mode. Sections A–C flip to 403, D shows the differential, **E and F must
   not move**.
8. `mvn clean test`; compare failures against P6's baseline, not against zero.

---

## 6. Test Plan

The instruments, in order of what each can actually see:

| instrument | proves | blind to |
|---|---|---|
| **`Sbdev3017TrancheGateContextTest` + 33 rows** (§3.3) | each of the 33 paths resolves its intended function **on the interceptor's own axis**; drift in both directions; anti-shrink | whether the interceptor is actually *invoked* in production; real tokens/data |
| MockMvc unit test with the interceptor installed **by hand** | the gate returns 403/200 per function, per handler | the real Keycloak token, the real DB, production interceptor registration |
| `SurfaceInventoryContextTest` | cross-check only — an **upper bound** on coverage | runtime resolution (keys on `getBeanType()`, §3.3) |
| the live probe script | end-to-end, real tokens, real data, both prefixes, mobile safety | whether DEV runs the build under test |

⚠️ **`standaloneSetup` installs no interceptor unless the test adds it by hand** — but **the tooling
for that already exists and this plan's earlier draft missed it.** `BaseControllerUnitTest:95` provides
`protected void setupMockMvcWithGuard(Object controller, HandlerInterceptor interceptor)`, already used
correctly by `PutawayConfigActionGuardUnitTest`, `ShipperIdControllerActionGuardUnitTest`,
`StockUnitBulkTransferGateUnitTest` and the mobile `FunctionGuardMockMvcUnitTest`. **Use that method.**
The trap is real — a gate test built on plain `setupMockMvc` is vacuous and green — but it is solved,
not open. Every gate test here must assert a **403** in the deny case; a test asserting only 200 on the
allow path passes with no interceptor at all.

### Test scenarios — three of the first draft's six were defective

| # | scenario | expected | status |
|---|---|---|---|
| T1 | each of the 20, user holds the required function | 200 **and** `checkAnyAccess` was called with *that* function — captured via `ArgumentCaptor` | ⬆️ **strengthened**: without the captor, T1–T6 pinned the *mechanism* 19 times and the per-endpoint function **zero** times, which is AC-2's entire content |
| T2 | each of the 20, user holds **no** function | 403, body `reason`, header `X-Authz-Denied` | ok |
| T3 | each of the 13 `ReportController` handlers via the `/v3/dashboard` prefix | 403 | ok, **and its value is the mapping pin, not a second gate assertion** — dropping `extends ReportController` surfaces as 404 ≠ 403. Stays in the standalone lane: `StandaloneMockMvcBuilder` registers through the same `AbstractHandlerMethodMapping#detectHandlerMethods`, so inherited methods register under the subclass prefix with `declaringClass` unchanged. ⚠️ derived from the shared code path, **not yet measured** |
| T4 | `DashboardController.orderMonitorViewOverview` (path `/orderMonitorViewSummary`) + `replenishMonitorViewSummary`, user holds nothing | **200** | 🔴 **the first draft named `orderMonitorViewSummary` as the method. That method does not exist** — the handler is `orderMonitorViewOverview`. Exactly the name/path mismatch this plan warns about in §1.2, committed two pages later |
| T5 | ANY-of: user holds either / neither | allow / deny | ok — needed only if §3.4 resolves to the widened gate |
| ~~T6~~ | ~~`FunctionGuardStartupAssertion` still passes~~ | — | 🔴 **DELETED — vacuous, cannot fail.** The assertion does `if (!guarded.contains(declaring)) continue;` and §3.6 declines to add any of the three controllers to `GUARDED`. An annotation-only change on non-`GUARDED` classes can never make it throw |
| **T7** | the 33 `declaringClass + path` rows on `Sbdev3017TrancheGateContextTest`, plus **5 `row("DashboardController", …)` UNGATED rows** | intended function per path; `DashboardController`'s own handlers assert **no** gate | ✅ **new** — promoted out of the instruments table, which the first draft left disagreeing with this one |

**T7 needs no new pattern — the file already does exactly this for our controller.** It carries both
halves of the one dual-mapped route that is already gated:

```java
row("ReportController",       "/v3/report/reprintLabels",     "WEB_UI_VIEW_PARCEL_PICKING");
// ReportController — the dual mapping is inheritance, not a two-valued @RequestMapping. Since the
// … /v3/dashboard/reprintLabels has zero callers in either UI.)
row("ReportController",       "/v3/dashboard/reprintLabels",  "WEB_UI_VIEW_PARCEL_PICKING");
```

⚠️ **Bump the row-count pin in the same commit.** Its javadoc reads *"85 = 71 tranche rows + the
inherited `/v3/dashboard/reprintLabels` registration of one of them"*, and `thePinHasNotQuietlyShrunk()`
asserts that total — so adding 33 rows without updating it reds the build. That is the pin working as
designed, not a defect; note it so nobody "fixes" it by deleting rows.

**T4 and T7 are the regressions that matter**, and for a reason sharper than "it looks like a cleanup":

🔴 **`@RequiresFunction` is NOT `@Inherited`** (verified: zero `@Inherited` in `RequiresFunction.java`).
So if someone replaces the 13 method annotations with one class-level annotation on `ReportController`:

- `FunctionGuardArchTest`'s `Class.getAnnotation` check on `DashboardController` — which *is* in
  `SHARED_CONTROLLERS` — **stays green**, because `getAnnotation` does not walk superclasses;
- while at runtime `AnnotationUtils.findAnnotation` **does** walk, finds it, and 403s mobile Replenish
  and Picking.

The arch rail and the runtime disagree by construction, and the rail is the one that looks like it
covers this. T4 plus T7's five UNGATED `DashboardController` rows are the only detectors.

### Mutation-checking: PIT cannot see this change

The floor requires every new assertion be mutation-checked with an **attributable** kill. **PIT mutates
bytecode instructions, and adding an annotation adds no instructions** — so a PIT run here yields a
meaningless number rather than evidence. Stating that plainly is more honest than reporting coverage.

Honest substitute: **four manual revert-and-run mutants — one per mechanism, not one per endpoint** —
each tabulated with which instrument produces the attributable red:

| mutant | expected detector |
|---|---|
| M1 remove one method annotation | T2 (that endpoint) |
| M2 remove all 20 | T2 broadly |
| M3 replace the 13 with one class-level annotation on `ReportController` | **T4** + T7's UNGATED rows only |
| M4 **keep** the 20 **and add** a class-level annotation on `ReportController` | ⚠️ **T4 only** — missed by T1, T2, T3 and the arch rail, since every in-scope row still resolves its correct function. ✅ **Measured twice.** At the gate: T4 reds with `NeverWantedButInvoked: accessService.checkAnyAccess(...)`, naming the exact breach. Re-measured independently post-implementation by the conformance lane: **T4 AND T7 both kill it**, T7 naming all five mobile routes. So the "T4 only" claim was pessimistic once T7's five UNGATED `DashboardController` rows existed — two independent instruments, not one. Failures went 6 → 4 at the gate, i.e. M4 *does* satisfy two of the deny tests, which is why the status-only instruments cannot see it |

🔴 **A correction the gate forced, and the reason mutation-checking is in the floor.** T4 as first written
asserted only the status codes (`isNotEqualTo(403)`), and **it PASSED under M4** — because its lenient
allow-stub answers `allow()`, so a `DashboardController` handler that now *does* resolve an inherited
function still returns 200. A status check cannot distinguish *"no gate"* from *"a gate that happened to
allow"*. The plan asserted T4 was the sole detector; that was true only of the hardened form.

The fix is `verify(accessService, never()).checkAnyAccess(any(), any(String[].class))` — the guard must
never *consult* `AccessService` for these handlers at all. Under the real deployment the caller is a mobile
operator holding no `WEB_UI_VIEW_*`, so a consult means 403 for them even where it means 200 for a
permissive test stub.

M4 is the insidious one and it is why T4 is not optional.

### AC-4 / AC-5 — `SurfaceInventoryContextTest` is a generator, not a ratchet

Verified: it carries **exactly one assertion** — `assertThat(total)` at `:158`, a "context registered
something" sanity floor. It **cannot regress-detect anything**, and it is on the wrong axis (§3.3).
So: **AC-4 is discharged by T7's 33 pin rows**, and the inventory is retained only as the AC-5
generator that re-derives the surface. The earlier framing of it as a "cross-check" was too generous.

The `*ContextTest` lane itself is reliable: surefire excludes only `**/*IntegrationTest.java` and
`**/*E2ETest.java`, so `*ContextTest` runs on every `mvn test` (confirmed — 1 test, BUILD SUCCESS).

### Deliberately-skipped coverage

- **No verify script.** T3 permits an opt-in ≤15-row script; this plan declines. Every assertion here
  belongs in JUnit (which runs in CI and survives refactors) or in the live probe (which no script can
  replace). The probe script is a live-HTTP instrument, not a file-grading verify script, and is not
  subject to the row-hygiene rules — but its own limits are stated in its header.
- **No UI test for the `/dashboard/export*` twins.** The web UI never calls them, so there is nothing
  to regress; T3 and T7 cover the axis server-side.

### 🔴 The Cypress suite is a direct caller that neither caller lane could see

Both caller lanes traced the store → component → page chain. `wms2-web-ui`'s **Cypress e2e suite calls
**five of the 20** directly, bypassing that chain entirely, and is therefore invisible to that method:

🔴 **An earlier draft said five. It is SEVEN, and the two it missed are by far the largest** — caught by
the code-review lane, re-measured here with `command grep -rl -- "<path>" cypress/`:

| endpoint | cypress files | gate |
|---|---|---|
| 🔴 **`/report/parcelMonitorView`** | **10** | `WEB_UI_VIEW_PARCEL_MONITOR` — missing from the earlier list |
| 🔴 **`/report/parcelPickingView`** | **4** | `WEB_UI_VIEW_PARCEL_PICKING` — missing from the earlier list |
| `clubLine/skus` | 2 | `WEB_UI_VIEW_CLUB_LINE` |
| `clubLine/unitLoads` | 2 | `WEB_UI_VIEW_CLUB_LINE` |
| `transfers/availableTransferLanes` | 2 | `WEB_UI_VIEW_TRANSFER_ORDER` |
| `transfers/unitLoads` | 1 | `WEB_UI_VIEW_TRANSFER_ORDER` |
| `transfers/skus` (row 20) | 1 | `WEB_UI_VIEW_TRANSFER_ORDER` — via the named helper `cy.wms('GET', '/transfers/skus', { qs: { orderBatchId } })` |

All 10 `export*` paths and both `/parcels` paths have **zero** Cypress callers.

So the pre-merge grant check needs **four** functions, not two: `WEB_UI_VIEW_CLUB_LINE`,
`WEB_UI_VIEW_TRANSFER_ORDER`, `WEB_UI_VIEW_PARCEL_MONITOR`, `WEB_UI_VIEW_PARCEL_PICKING`.

**So gating these will fail the Cypress suite unless `KC_USERNAME` holds `WEB_UI_VIEW_CLUB_LINE` and
`WEB_UI_VIEW_TRANSFER_ORDER`.** The suite authenticates from `cypress.env.json`
(`cypress.env.example.json:22-23` → `KC_USERNAME` / `KC_PASSWORD`), which is not pinned in-repo, so
which functions that account holds cannot be determined from source. **Action: confirm that account's
grants before merge, using the §1.3 query.**

Pleasingly, this cuts the other way too. `cypress/e2e/cross-cutting/cross-cutting.cy.js:310` records a
standing *"TESTABILITY GAP: to test 403 / permission-denied paths we need two configured Keycloak test
users with different role claims"*. The probe script's account matrix (§1.3) **is** that pair —
`marthamina` / `estellavasquez` / `panderson`, with their grants measured — so this ticket can close
part of that gap as a byproduct rather than merely avoiding it.

---

## 7. Notes

### 7.1 Six more ungated `/v3` POST-as-query reads — **already owned by SBDEV-3158, do not file**

🔴 **An earlier draft proposed these as a new ticket. Retracted:** they are reads on `/v3`, so they sit
inside SBDEV-3158's ~90 by construction. Filing a ticket for them would have duplicated an existing
one. Recorded here only so the pointer survives, and cross-referenced on 3158.

Found while enumerating, from the same TSV. Same defect class, same remedy, **outside** the ticket's
three controllers:

| endpoint | declaring class | body |
|---|---|---|
| `POST /v3/advice/exportInboundNotice` | `AdviceController#exportOutboundBol` ⚠ name/path mismatch | `adviceService.exportInboundNotice(response, advice)` |
| `POST /v3/billOfLading/exportOutboundBol` | `BillOfLadingController` | `billofladingService.exportOutboundBOLs(response, bols, exportDetails)` |
| `POST /v3/cycleCount/export` | `CycleCountController` | `cyclecountService.exportCycleCounts(response, cycleCounts)` |
| `POST /v3/cycleCount/itemDataView` | `CycleCountController` | `dtoViewService.getCycleCountItemDataView(id)` |
| `POST /v3/cycleCount/locationView` | `CycleCountController` | `dtoViewService.getCycleLocationView(...)` |
| `POST /v3/cycleCount/positionView` | `CycleCountController` | `dtoViewService.getCycleCountPositionView(...)` |

This is a **T3 addition** (authorization), so per the ticket policy it is **proposed, never filed**,
capped at one proposed ticket per fix visit — Nam decides. It is not silently folded into SBDEV-3142.

**Limit of my evidence, stated precisely:** I read the six **controller** bodies and they write
nothing. I did **not** audit the three `*export*` service methods, and this estate has precedent for
export/print paths writing a flag (SBDEV-2485's `printable`). The three `*View` handlers are
unambiguous one-line delegations. So: four confirmed reads, three "read at the controller level,
service not audited". Whoever picks this up audits those three services first.

### 7.3 The 13 ungated GET reads on `ClubLine`/`Transfers` — **already owned by SBDEV-3158. Do NOT widen.**

🔴 **An earlier draft of this section recommended widening scope to all 13. That was wrong, and it was
wrong in a specific, already-documented way: it is the exact widening that was tried on 2026-08-28 and
retracted.** SBDEV-3158 says so in its own words:

> *"I widened SBDEV-3142 to 106 on 2026-08-28 and **that was wrong under the ticket policy Nam set the
> same day.** … Tier the *addition* on its own, not the combined ticket. A T3 addition is a second
> project wearing the first one's number, and it silently re-tiers the host. The widening comment on
> SBDEV-3142 has been retracted and points here."*

SBDEV-3158 owns **~90 ungated `/v3` MVC reads** — the full 106 minus this ticket's set. All 13 of the
GET reads §1.2 surfaced fall inside that ~90. So the correct action is **none**: they are enumerated,
owned, and tiered elsewhere, and 3158's own guidance is *"SBDEV-3142 … Do that one first, it is
enumerated and ready."*

I record this rather than deleting it because the *observation* in §1.2 stands and is worth keeping —
the boundary is a read/mutate line, not a verb line — while the *conclusion* I drew from it was a
repeat of a known error. Three review lanes flagged the boundary; none of them checked whether another
ticket already held it, and neither did I until the security lane named 3158.

#### The one exception: `GET /v3/transfers/skus` — recommended in-scope, and it overlaps 3158

Nominally 3158's (it is a read in the 106). But leaving it out makes **this ticket's own gate
incoherent on the controller it is editing**: rows 17–19 gate three `/v3/transfers/*` reads on
`WEB_UI_VIEW_TRANSFER_ORDER` while a fourth read of the same shape — `List<ClubLineSkuDto>` from
`transferOrderService.getSKUOverview(orderBatchId)` — answers 200 to the same denied user. The verb is
the only reason.

Its own tier is **T0/T1** (one annotation, one file, obvious, reversible) and the host ticket is
`Open`, so the ticket policy puts it on this ticket rather than a new one. And there is **no
over-gating risk** — verified, not assumed: its only two callers are `store/outbound/transfer.js:225`
and `store/processes/transferPicking.js:183`, and `util/appMenuList.js:61,70` gates both screens on
`WEB_UI_VIEW_TRANSFER_ORDER` — the function rows 17–19 already use. No new constant, no new population.

✅ **APPROVED by Nam 2026-08-31 — taken into this ticket. Scope is now 20 methods / 33 paths, and
SBDEV-3158's count drops by one** (commented there). It is row 20 of §3.1, gated
`WEB_UI_VIEW_TRANSFER_ORDER`, and **AC-1 covers it**: measured 2026-08-31,
`GET /v3/transfers/skus?orderBatchId=30704100` returned **200 / 547 B** to `truckloading` (4
functions, holds none of the twelve) — so its exposure is confirmed on the same footing as the other
19, not inherited by analogy.

The remaining GET reads on these two controllers stay SBDEV-3158's — **12 by method name, 13 by method
signature**, and the difference is not pedantry:

Re-derived post-fix from the runtime inventory: 21 ungated GET methods remain on the two controllers,
of which 9 genuinely mutate (SBDEV-3155's). 21 − 9 = 12 *names* — but `ClubLineController` declares
**two overloads both named `getActiveClubRun`** (on `/activeClubRun` and `/inactiveClubRun`), so there
are **13 handlers** to annotate.

⚠️ **Sharpest of the 13, flagged for SBDEV-3158:**
`GET /v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` — it takes the **same key a denied user
already holds** (the batch id they were just 403'd on) and returns an adjacent projection. It deserves
naming in that ticket rather than sitting as one list read among many.

⚠️ **This plan's own §7.2 warning caught this plan.** The TSV's `handler` column carries only a method
NAME, so overloads collapse into one row and any count keyed on `declaringClass + handler` undercounts.
The earlier "12" here came from exactly that. Whoever picks up SBDEV-3158 should count by
`(declaringClass, path)`, not by name — the same axis the tranche pin uses.

### 7.2 Two adjacent non-authz defects, recorded rather than fixed

Sub-T3, on controllers this ticket touches, and this ticket has not shipped — so by policy they could
land here. They are **not** authorization and bundling them would muddy the review, so they are
recorded for Nam's call:

1. **A misleading method NAME only — the endpoint is correct.** Two earlier drafts of this section
   claimed `/v3/clubLine/inactiveClubRun` returns *active* batches. **That was wrong, twice**, and the
   fact-check lane caught it. The chain:
   `getOrderBatchByStateAndType(ORDER_BATCH_ACTIVATED, [CLUB])` → `ViewDtoService:404`
   `customerorderBatchRepository.findByStateAndType(state, typeNames)` → `where cb.state < :state`
   (`CustomerorderBatchRepository:100`), and `ORDER_BATCH_ACTIVATED = 520` (`WmsConstants:78`). It
   returns batches **below** 520, i.e. not yet activated — genuinely inactive. The transfers side is
   the identical shape (`where co.state < :state`, `CUSTOMER_ORDER_ACTIVATED = 505`).

   The only real defect is that `ClubLineController` declares **two overloads both named
   `getActiveClubRun`**, and the principal-only one serves `/inactiveClubRun`. A readability bug, not a
   data bug — **materially lower priority than the first draft implied**, and no user impact.

   ⚠️ **Methodological warning, worth more than the defect.** My first reading of this was wrong in a
   way the instrument invited: `surface-inventory.tsv`'s `handler` column prints the **method name**,
   so two overloads collapse into one row and it looks like *one* handler mapped to two paths. Any
   count keyed on `declaringClass#methodName` over that TSV silently merges overloads. I re-derived
   the 19/32 figures against this — all 13 `ReportController` rows are genuine `report`/`dashboard`
   pairs (same path suffix on both prefixes) and none of the 20 has an overload (`getSkuView` occurs
   exactly once on `TransfersController`; `ClubLineController`'s namesake is a different declaring
   class, so `declaringClass#method` keying does not collide) — but the trap is live
   for the next person to use that file.
2. **`TransfersController.getTransferLineUnitLoads` can 500 on an empty batch.** It does
   `customerorderRepository.findByOrderbatchId(orderBatchId).get(0)` with no emptiness check →
   `IndexOutOfBoundsException`. Its sibling `getAvailableTransferLanes` guards the identical call with
   `if (orders.isEmpty()) return Collections.emptyList();   // batch has no order → no lanes (don't 500)`
   — so the fix is already written three methods away.

### 7.3 Corrections made to other documents

- `SBDEV-3169-sdr-read-gating.md` §2.7: `ReportController` 15 handlers / 14 ungated → **14 / 13**.
  Two instruments agree on 10 exports (runtime TSV; `grep -c '@PostMapping(path= "/export'` = 10), so
  the "11 `export*`" in `3169-evidence/3169-review-facts.md` is the source of the off-by-one. That
  file is an evidence record of a past lane, so it is annotated rather than rewritten.

### 7.4 Evidence files

| file | what |
|---|---|
| `SBDEV-3142-evidence/3142-web-callers.md` | web-UI caller → screen → function, 16 rows, `wms2-web-ui` @ `9e70a73b`. Findings F0–F6 |
| `SBDEV-3142-evidence/3142-mobile-callers.md` | mobile sweep, 10 search axes, 202 files, `wms2-mobile-ui` @ `c79e81c3` |
| `sbdocs/9-System/scripts/probe-wms2-report-read-gating-dev.sh` | the AC-1 / AC-3 live instrument, 41 rows, `baseline` + `gated` modes |
| `.claude/worktrees/wms2-api/SBDEV-3142/target/surface-inventory.tsv` | 792 deployed handler rows + a header line |

⚠️ **F0 is a methodology warning worth carrying forward:** `wms2-web-ui`'s `.gitignore` hides
`reports/`, and **9 of the 16 endpoints live entirely inside those directories**. An ignore-aware
search tool returns zero callers for them. Nine false `UNMAPPED` verdicts were avoided only by using
`git grep` against the object store. Any future audit of that repo must do the same — and a stale
`dist/` in the working tree inflates any non-git-aware count (F2).
