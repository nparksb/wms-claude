---
name: sbdev-3089-two-red-tests-on-develop
description: SBDEV-3089 — both wms2-api develop reds fixed; PRs #200/#201/#202 MERGED, ticket `on dev`; ArchUnit's 6 were GUARDED false positives, re-baselined; store audit must NOT deduplicate
metadata:
  type: project
---

**RESOLVED.** All three PRs merged to `develop` 2026-08-26; ticket `on dev` 2026-08-28. Not on
`release`/`main`, so QA+prod still carry the reds.

`mvn test` on wms2-api `origin/develop` used to fail **2 of 5592** (67 skipped) — the ticket's
"~4442" is stale. Re-measured 2026-08-28 @ `04ca8eb0`: **5680 / 0 failures / 67 skipped**, both
formerly-red classes green, store md5 unchanged after the run. **Only `Failures: 0` is worth
asserting — the total drifts constantly** (4442 ticket → 5592 → 5620 → 5680).

**Half 1 — `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`
— SHIPPED, PR #200 (`5c7ec9ea`), status left `Open` since the AC needs both halves.**
Test-only; the product was never wrong. SBDEV-2507's port (`1632b929`) extracted the gate
into `BillofladingPositionService.assertPalletNotAssignedToGate`; the test kept stubbing
`billofladingPositionRepository.getBySourceUnitLoadLabelId` on the PALLET label. Under
`Strictness.LENIENT` the mocked void method no-ops → falls through to an unstubbed
`findByLabelid("PARCEL001")` → `Optional.empty()` → `parcelMissingException`.
See [[wms2-mobile-palletizing-has-two-duplicate-test-classes]] for why it stayed red a month.

**Half 2 — `OptionalSafetyArchTest` — FIXED by deliberate re-baseline, PR #201 (`a52c9f63`).**
Nam said go on the recommendation 2026-08-26. Both halves verified together: **5592 tests, 0 failures,
67 skipped** — first green suite in a month — and wider-scope PIT now clears the green-suite abort
(`Created 136 mutation test units`; it still hits minion timeouts, which is SBDEV-3007's problem).
Merged (PR #201 `a52c9f63`), plus **PR #202 `613af616`** correcting the audit recipe.
Two corrections to the ticket, both measured:

1. **6 violations, not 4**, and all **6 are `isPresent()`-guarded and cannot throw**:
   `PickLineRealignmentService:80,81` · `ReplenishGeneratorService:210` ·
   `UnitloadBusinessService.recoverPalletFromNirvana:751,755` (absent from the ticket) ·
   `MobileReplenishService.fulfillMultipleUnitLoadsTx:1024` (a **rename** of the baselined
   `fulfillMultipleUnitLoads:754`, so it is pre-existing accepted debt, not new).
   The rule is bare `noClasses().should().callMethod(Optional.class, "get")` — call-site
   presence, **no dataflow** — so it cannot tell a guarded `.get()` from an unguarded one.
   SBDEV-2116's premise is unmet at every site, so the ticket's "re-freeze = accept debt vs
   fix the sites = correct" binary is a false one: there is no debt to accept.

2. **The ticket's "silently re-freezes real violations → permanent false green" hazard is
   WRONG.** The store mutation from a suite run is **prune-only (−6 / +0)** — it drops
   entries whose methods were renamed or fixed and adds **none** of the new violations.
   `FreezingArchRule` never freezes new violations without `freeze.refreeze=true`, so an
   accidentally committed store edit makes the rule **stricter**, not laxer. Still revert it
   (`git checkout -- src/test/resources/archunit_store/`) — for diff noise, not false greens.

**Re-baselining safely — two things that matter:**
- **Use `freeze.refreeze=true` temporarily** in `src/test/resources/archunit.properties`, run the test
  alone, then **revert the properties file**. Plain runs never add entries.
- **Never review the diff by eye.** A refreeze rewrote most of the store as pure line-number
  renumbering while changing only 6 sites in / 6 out. Audit **per-method site counts with line
  numbers stripped** — a method going 1→2 sites is invisible to a set comparison. Recipe is now in
  `OptionalSafetyArchTest`'s javadoc.
- **NEVER `sort -u` that audit — the store legitimately holds duplicate `File.java:NNN` lines.**
  ArchUnit stores **one entry per CALL**, and one source line can hold two: the shape here is
  `repo.findById(opt.get().getX()).orElseThrow(() -> new E(opt.get().getX()))`. Deduplicating
  undercounts the method and **hides a genuinely new second `.get()` added to an already-frozen
  line** — the exact failure the audit exists to catch. My first recipe (`a52c9f63`) said to dedup
  and was corrected by PR #202 (`613af616`).
- **Raw entry count was 150 → 154, NOT "148 → 148".** 148→148 was a *distinct-line* count. Truth:
  6 added, 6 removed, **plus 4 second-entries on already-frozen lines** the old store had recorded
  only once — `MobileInfoService.readOrder:374`, `MobileMoveUnitloadService.scanUnitLoad:188`,
  `MobilePickingService.resetPickingOrder:1333`, `MobilePutAwayService.verifyScannedLocation:484`.
  All four re-audited undeduplicated and confirmed pre-existing, so the re-baseline stands — but the
  deduped audit could not have told them from 4 new violations. Also `StockunitService.transferStock`
  is 6→5, not 5→4.
- **Prove the rule is still not permissive afterwards**: add a fresh unguarded `Optional.get()` to a
  service and confirm it fails by name. A re-baseline that disabled the rule looks identical otherwise.
- Side benefit measured: after re-baselining the store is **stable across runs** (md5 unchanged), so
  `mvn test` no longer dirties the tracked file.

**CORRECTED 2026-08-28 (PR #229, MERGED `2f82c473`): line numbers are NOT matched.** I had this wrong here and in
the file's own javadoc. `freeze.lineMatcher` is unset, so ArchUnit 1.3.0's default
`FuzzyViolationLineMatcher` ignores line numbers. Measured: **55 of the 148 live entries point at a
source line holding no `.get()`** (one is `}`, one is blank) on a **green** build. So a **line shift
never turns this red** — only a genuinely new call site or a **method rename** (the signature is
matched) does. Consequence: **never refreeze because the numbers look stale.** They are stale by 55
entries right now. Probe pair that settles it, re-run after any re-baseline: 5 blank lines shifting
`PickLineRealignmentService`'s frozen sites → GREEN; one fresh unguarded `.get()` in `BoxtypeService`
→ RED by name.

**Baseline is 148 raw / 142 distinct, not 154** (re-verified on develop 2026-08-28 after SBDEV-1615 merged; still exact, and SBDEV-1615's service edits did NOT dirty the store)**.** `ae3669f8` (an unrelated SBDEV-3017 security-test
commit) pruned the 6 `UnitloadService` recursive-delete entries SBDEV-3119 rewrote to `orElse(null)`
— prune-only, so stricter, but it rode along and left the recorded number stale. Compare against
**raw**.
