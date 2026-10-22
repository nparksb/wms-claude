---
name: sbdev-3142
description: "SBDEV-3142 report/monitor read gating — AC-1 measured (566KB location table to a 4-fn user); WineCo PRD lacks WEB_UI_VIEW_PARCEL_PICKING so reprintLabels is a latent prd break; closes ZERO datasets alone (SDR twins); SBDEV-3158 owns the rest"
metadata: 
  node_type: memory
  type: project
  originSessionId: c527756c-ad1f-4b3c-b51c-2aed67debc7c
  modified: 2026-08-31T16:16:24.442Z
---

**SHIPPED `on dev` 2026-08-31** — wms2-api PR #252 (merge `4daad5d8`, 20 method-level
`@RequiresFunction`) + wms2-web-ui PR #101 (`41679877`, deletes the dead `outboundBols/getItemInfo`).
NOT on `main`/prd. Suite 5815/0. Plan: `sbdocs/1-Projects/wms2/plan/SBDEV-3142-report-read-gating.md`. **T3.**

🔴 **Two live residuals that outlast the merge.** (1) **The CLUB_LINE and TRANSFER_ORDER gates are
mutually substitutable** — `clubLine/parcels` and `transfers/parcels` are character-identical with no
batch-type check; measured on DEV, `TRANSFER_ORDER` alone reads **652 club orders / 343,396 B** through
the transfers path, byte-identical to what the club path now 403s. `skus`/`unitLoads` substitute through
a narrower projection. **SBDEV-3169 CANNOT close this** (cross-controller MVC, not an SDR twin) — do not
book it there. (2) `ReportController` is **not** in `GUARDED`, so no deletion tripwire: blocked by
`UserControllerPublicHandlerUnitTest` AC-4d pinning `GOLDEN_MAP == EXPECTED_GUARDED == GUARDED`, and this
controller cannot join `GOLDEN_MAP` (one *class-level* function; it needs 12, method-level).

⚠️ **Cypress calls 7 of the 20** (`parcelMonitorView` 10 spec files, `parcelPickingView` 4, +5). Needs
4 functions. `sbtest` holds 3 but NOT `CLUB_LINE` → exactly the 2 clubLine specs red. **That pattern is
the gate working, not flakiness.** Merged before QA confirmed, on Nam's instruction. The MVC
read axis of the defect class [[sbdev-3017-tranche1-mvc-gating]] ruled out of its state-change tranche;
the SDR axis is SBDEV-3169. Neither closes the founding complaint alone.

**Scope is 20 methods / 33 paths, not the ticket's 16.** Nam widened twice on 2026-08-31: first the 3
ungated GET `*View` reads on `ReportController`, then `GET /v3/transfers/skus` (row 20). Derived from
`RequestMappingHandlerMapping` (`target/surface-inventory.tsv`, 792 data rows), not grep: 10 POST exports +
3 GET views (all `ReportController`-declared, **dual-mapped ⇒ 26 paths**) + 3 `ClubLineController` +
3 `TransfersController` POSTs + `TransfersController.getSkuView` GET (single-mapped).

⚠️ **The original 19/32 boundary was set by a `$2=="POST"` awk filter, not a decision** — that is what
hid row 20, whose POST namesake on `ClubLineController` was already in scope. Three review lanes
flagged the boundary independently. The principled line is **read vs mutate, not GET vs POST**: 41
handlers on these three controllers are ungated = 20 (this ticket) + 12 reads (SBDEV-3158's) + 9 GETs
that genuinely MUTATE (`runClubLine`, `activateAndAssignTransferLane`, `billofladingService.transferOrder`
… — SBDEV-3155's, confirmed by reading bodies).

⚠️ **`ReportController` declares 14 handlers, 13 ungated — NOT the 15/14 that SBDEV-3169 §2.7 and
`3169-review-facts.md` both assert.** Corrected in the plan file 2026-08-31. Two instruments agree on
10 `export*` (runtime TSV; `grep -c '@PostMapping(path= "/export'`); 3169's "11 export*" is the
off-by-one source.

**Two method names do not match their paths** — `/flowbinMonitorView` → `floowbinMonitorView` [sic],
`/parcelPickingView` → `getDetailView`. A method-name-keyed test or row silently misses both. Key on
the path or on `declaringClass#method`.

**AC-1 was never blocked.** The ticket says only `panderson` was available and holds everything. DEV
has usable subsets, and the load-bearing one is **`estellavasquez` (27 fns: holds `CLUB_LINE` +
`TRANSFER_ORDER`, lacks `INVENTORY_RECORD`)** — a *differential* account. A zero-function user cannot
distinguish "gate works" from "gate denies everyone", which is the failure mode that breaks prod while
looking like a fix. Also: `panderson` holds **80**, the DEV max is **81** (`sbuser1`,`sbuser15`) vs the ticket's 79, and **45 of 99** users hold zero.
**✅ AC-1 DONE 2026-08-31** via `sbdocs/9-System/scripts/probe-wms2-report-read-gating-dev.sh baseline`
(44 rows): **40 pass, 0 fail, 5 inconclusive.** A then-4-function user (`truckloading`) pulled **566,050 B —
the whole location table — from `exportStorageLocations`**, plus real data on 28 more paths (incl. row 20 at 547 B); every
export returned identical bytes on BOTH prefixes, so AC-4's dual mapping is measured too.
⚠️ `parcelPickingView`/`parcelMonitorView` (4 paths) returned `{"content":[],"totalElements":0}` —
reachable, leak NOT demonstrated; they need seeded data.

**Usable DEV accounts, all on the one dev password: `panderson` (80), `sbtest` (35 — the two-directional
differential: lacks CLUB_LINE + RECEIVED_STOCK_OVERVIEW, holds INVENTORY_RECORD + LOCK + TRANSFER),
`wmstest` (0, holds nothing — THE deprived seat).**
🔴 **`truckloading` is NO LONGER a deprived account: re-measured 2026-09-01 at 35 functions**, holding 9 of
the 12 this probe assumes it lacks. Its script has been corrected to use `wmstest`. DEV grants drift
between sessions — re-derive them before every run, never trust a recorded count. See
[[sbdev-3155-mutating-get-gating]]. `marthamina`, `estellavasquez`, `josiemarks`,
`sbuser2` do NOT share it — don't build a probe on them.

**THREE ways that probe lied before I trusted it:** (1) the 3 GET `*View` handlers REQUIRE `page`+`size`
(`@RequestParam` with no default) — omitting them gave six 400s that read as "already protected", and
only the admin CONTROL row exposed it as my bug; a 400 proves nothing because the body is rejected
before the gate. (2) The empty-payload guard was `-lt 32` bytes and `{"content":[],"totalElements":0}`
is EXACTLY 32 — an empty page reported as a confirmed leak. Assert on CONTENT, not size. (3) Row 20's
`orderBatchId` is likewise a REQUIRED `@RequestParam`. **The admin CONTROL row is the thing that
distinguishes "a gate" from "my malformed request" — never run a deprived-only probe.**

🔴 **`WEB_UI_VIEW_PARCEL_PICKING` DOES NOT EXIST in WineCo PRODUCTION** (`wh01_om1`, 93 users, 79
functions; no name variant). Gating on it denies all 93 — and **`reprintLabels` already carries that
gate on develop**, so tote-label reprint is a latent break for that tenant the moment the authz
programme reaches prd. Commented on SBDEV-3017. Fix = seed the function + grant to the roles holding
`WEB_UI_VIEW_PARCEL_MONITOR` (43 of 93); `mywms_function` is tenant-local, NOT a Flyway one-liner.

I first surveyed 5 DBs, found 12/12, and wrote "no gate can fail closed for a whole tenant." **FALSE —
four of the five were non-production.** The other 11 constants are present in all six. Holders: DEV
42–46 of 99, WineCo prd 35–43 of 93, hydra prd 7 of 9. **Count production tenants, not DBs**, and
never make a closed-set claim off a five-member sample.

**Verify with `Sbdev3017TrancheGateContextTest`, NOT `SurfaceInventoryContextTest`** — the latter keys
on `getBeanType()` and over-reports; see trap 2 in [[sbdev-3017-tranche1-mvc-gating]]. The former is
keyed `declaringClass + " " + path` on the interceptor's own axis and carries a separate
`thePinHasNotBeenQuietlyShrunk()` test — which matters here because "simplify 19 method annotations
into one class annotation" is the likely future regression, and it would **403 mobile Replenish +
Picking** (`AnnotationUtils.findAnnotation` walks `DashboardController` → `ReportController`).

**No mobile caller of any of the 19** — two independent instruments: 10-axis `git grep` over 202 files
at `c79e81c3`, plus the mobile UI having **no download capability at all**.

6 more ungated `/v3` POST-as-query reads exist outside the three controllers —
`/v3/advice/exportInboundNotice`, `/v3/billOfLading/exportOutboundBol`, `/v3/cycleCount/{export,
itemDataView,locationView,positionView}`. **Already SBDEV-3158's — do NOT file** (see below). Controller
bodies are reads; the 3 `*export*` **service** methods were NOT audited (SBDEV-2485 is precedent for
export paths writing a flag).

Also recorded, not fixed: `TransfersController.getTransferLineUnitLoads` does `.get(0)` with no
emptiness guard → 500, while its sibling `getAvailableTransferLanes` guards the identical call with
`if (orders.isEmpty()) return Collections.emptyList();`.

**REVIEWED 2026-08-31, 4 lanes. The verdict that matters: this fix closes the exposure of ZERO
datasets on its own.** All 19 endpoints keep an equivalent open route; **13 of 19 are `identical` —
the same repository query method exported over SDR** (e.g. `POST /v3/report/exportStorageLocations`
vs `GET /v3/location/search/exportStorageLocations`, zero params, whole-table native query). Residual
is SBDEV-3169's (SDR) + SBDEV-3158's (MVC siblings). **Ship it anyway, but never report it as "the
report surface is protected"** — now enforced as **AC-6 on the ticket** (Nam approved 2026-08-31):
record the residual route + owning ticket per endpoint, and never close this as "protected". Residual
owners: SBDEV-3169 (SDR twins), SBDEV-3158 (MVC siblings). ⚠️ Row 20 was added after that lane ran and
is UNASSESSED on this axis — do not round "19 of 19" to "20 of 20".
See [[a-guard-fences-the-mechanism-you-aimed-at]].

⚠️ **SBDEV-3158 owns the ~90 remaining ungated `/v3` MVC reads, and widening 3142 was already tried
and RETRACTED on 2026-08-28.** I re-proposed that widening twice (the 6 advice/BOL/cycleCount reads as
a new ticket; 13 more GET reads into scope) before the security lane surfaced 3158. Both retracted.
**Check whether a sibling ticket already owns a surface before proposing scope** — three review lanes
flagged my boundary and none of them checked either.

**Corrections to my own claims, recorded because the pattern repeated:**
- `/v3/clubLine/inactiveClubRun` does **NOT** return active batches — `findByStateAndType` is
  `where cb.state < :state`, `ORDER_BATCH_ACTIVATED = 520`, so it correctly returns not-yet-activated.
  Only the method NAME is wrong (two overloads both `getActiveClubRun`). No user impact.
- **`surface-inventory.tsv`'s `handler` column is a method NAME, so overloads collapse to one row** —
  looks like one handler on two paths. Any count keyed `declaringClass#handler` merges them. A third
  "106 is a lower bound" mechanism beyond the known `getBeanType` over-report.
- DEV max is **81** functions (`sbuser1`,`sbuser15`); `panderson` holds 80. TSV is 792 data rows + header.

**`GUARDED` enrollment for `ReportController` is SAFE after the fix and RECOMMENDED** — my first draft
rejected it on two false premises. Post-fix all 14 declared handlers are annotated, and
`FunctionGuardStartupAssertion:148-149` keys on `declaringClass`, so `DashboardController`'s own 6
handlers are skipped. Buys a **deletion tripwire**: remove an annotation ⇒ app refuses to boot. Do NOT
enroll `ClubLine`/`Transfers` (13 ungated reads + 9 mutating GETs each).

**Test traps, measured:** `FunctionGuardStartupAssertion` skips non-`GUARDED` classes, so a
"boot still passes" test here is **vacuous**. **PIT cannot see annotation removal** (it mutates
instructions; an annotation adds none) — use manual revert-and-run mutants. The insidious mutant is
*keep the 19 AND add a class-level annotation*: missed by 3 of 4 instruments **and** by
`FunctionGuardArchTest`, because **`@RequiresFunction` is not `@Inherited`** — `Class.getAnnotation`
on `DashboardController` stays green while `AnnotationUtils.findAnnotation` walks at runtime.
`BaseControllerUnitTest:95 setupMockMvcWithGuard(controller, interceptor)` is the non-vacuous setup.

**The Cypress suite in `wms2-web-ui` directly calls 5 of the 20** (incl. row 20 via the named helper
`cypress/support/helpers/wmsHelpers.js:1080`) — invisible to a store→component→page
caller trace. Gating reds it unless `KC_USERNAME` holds `CLUB_LINE`+`TRANSFER_ORDER`.

**Baseline @ `d434a3e5`: 5788 tests / 0 failures / 67 skipped** (`mvn -o clean test`).

**Over-gating UX defect, in scope:** every denied read fires TWO contradictory toasts — `plugins/axios.js`
correctly reads `X-Authz-Denied` and says "no permission" (header, not body — load-bearing, the exports
are `responseType: 'blob'`), then the store's `catch` says "Please retry." **37 store files** in
wms2-web-ui (a review lane said 17; measured 37).

Related: [[wms2-web-ui-gitignore-reports-hides-34-files-from-grep]] (9 of 16 endpoints live inside the
ignored `reports/` dirs — an ignore-aware search returns 9 false UNMAPPED),
[[wms2-gating-programme-is-live-on-prd]],
[[wms2-rest-surface-internal-only-jwt-deferred]] (the 4 `/rest/**` POST-as-query reads stay out),
[[a-guard-fences-the-mechanism-you-aimed-at]], [[consolidate-tickets-dont-file-one-per-finding]].
