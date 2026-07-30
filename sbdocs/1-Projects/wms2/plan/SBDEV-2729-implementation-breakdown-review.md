---
title: "SBDEV-2729 — Review of Zeshan's implementation breakdown"
ticket: SBDEV-2729
type: plan-review
reviewer: Nam Park
date: 2026-07-29
reviews: "[[SBDEV-2729-system-sku-receiving-null-label-token]]"
status: changes-requested
---

# SBDEV-2729 — Review of the implementation breakdown

**What this reviews:** Zeshan's proposed PR1/PR2 execution breakdown for SBDEV-2729
(System SKU / ICE PACK cannot be received — null ZPL label token aborts `receiveGoods`).

**Reviewed against:** the approved plan
`SBDEV-2729-system-sku-receiving-null-label-token.md` (Architect **APPROVE** r7/r8,
Critic **APPROVE** r6).

**Bottom line:** The breakdown restates the plan's intent faithfully and gets the
hard technical content right. **But the PR1/PR2 partition was altered from the
approved plan in a way that breaks PR1's build.** Three corrections are required
before execution; the new Phase-0 additions are good and should be kept.

---

## Verdict at a glance

| Area | Status |
|---|---|
| Phase 0 prerequisites (incl. new additions) | ✅ Keep — improves on the plan |
| Fix A (SharedService null-safety + boxtype guard + requireConfig + hoist) | ✅ Correct |
| Message bundle (base `messages.properties` + `en_US`) | ✅ Correct |
| Fix F (getSysvalue `unless = "#result == null"`) | ✅ Correct, correctly in PR1 |
| **Fix E placement (PR1 → moved to PR2)** | 🔴 **Critical — PR1 won't compile** |
| **Fix D scope ("all 6 endpoints" in PR1)** | 🟠 **Contradicts plan + own acceptance line** |
| **PR1 test scope** | 🟡 **Thinned — missing `shouldGuardNullBoxtypeId` + others** |
| Fix B / Fix C (PR2) | ✅ Correct |
| Verify target `62 pass / 0 fail / 3 skip` | ✅ Correct end-state |

---

## 🔴 Critical — moving Fix E to PR2 makes PR1 fail to compile

The breakdown lists **Fix E under PR2** ("reprintLabel propagates BusinessException;
UnitLoadController gains the catch"). The approved plan places Fix E in **PR1**,
step 7, gated on `mvn clean compile`, and lists `E1 E2` in the PR1 acceptance subset
(plan §7.2).

This is not a preference — it is mandatory. Verified against the code
(`v2/wms2-api`):

- `BusinessException extends Exception` → **checked** exception
  (`exceptions/BusinessException.java:14`)
- `UnitloadService.reprintLabel` (`:216`, declared `throws FacadeException` only)
  calls `sharedService.createCaseLabel(...)` at **`:250` and `:254`**
- `UnitLoadController.reprintLabel` (`:66`) catches **only `FacadeException`** (`:67`)

The moment Fix A (PR1) adds `throws BusinessException` to
`SharedService.createCaseLabel`, lines 250/254 become *unhandled checked-exception*
compile errors. Therefore **Fix E rows 5 (`reprintLabel` adds `throws`) and 6
(`UnitLoadController` adds the `catch`) are compile-mandatory in PR1** — Fix A cannot
ship without them. As written, Zeshan's PR1 fails `mvn clean compile`.

**Action:** Move Fix E back into PR1, immediately after Fix A and before the PR1
tests — exactly as the plan sequences it (plan §7.2 PR1 step 7).

---

## 🟠 Major — Fix D scope contradicts the plan *and* the breakdown's own acceptance line

The breakdown puts **"all 6 ReceivingController endpoints"** in PR1. The plan scopes
PR1 to **Fix D for `/receive` only**, deferring the five sibling endpoints to PR2
(plan §7.2 PR1 step 8, PR2 step 15).

Two problems with the change as written:

1. **Internal contradiction.** The breakdown's PR1 acceptance says "PR1's named
   check subset of the verify script." That subset *explicitly excludes*
   `D1/D4/D5/D6` and `S1/S2`, because those checks scan all six catch blocks
   (plan §7.2). Converting all six endpoints pulls those checks into PR1's scope —
   so the stated gate no longer matches the work.
2. **PR2 orphan.** The breakdown's PR2 lists only Fix B, C, E. The five sibling
   Fix D endpoints appear *nowhere* in PR2 — so they are only accounted for if all
   six really are in PR1.

Net effect: the breakdown appears to have **swapped** Fix-D-remainder (PR2 → PR1)
and Fix E (PR1 → PR2). The Fix E swap is the build-breaker above; the Fix D swap is
"merely" inconsistent.

**Action (recommended):** Revert to the plan's split — `/receive` in PR1, the five
siblings in PR2. If doing all six in PR1 is genuinely preferred, then the PR1 gate
**must** be updated to include `D1/D4/D5/D6` (note `S1/S2` still cannot pass until
Fix B lands in PR2). Either way, reconcile scope with the gate — right now they
disagree.

---

## 🟡 Moderate — PR1 test scope is thinned

The breakdown reduces PR1 tests to "7 migrations + `shouldBuildLabelForSystemOwnedSku`."
The plan's §8.1/§8.3 require materially more for PR1:

- ~8 *new* `SharedServiceUnitTest` cases: winetype-null, boxtype-name-null,
  advice-externalid-null, all-optional-null, ZPL-missing → `BusinessException`,
  warehouse-name-missing, warehouse-name-blank, and the happy-path regression guard.
- **`shouldGuardNullBoxtypeId` — notably missing.** The breakdown includes the
  boxtype `findById(null)` crash as a *fix* but drops its *test* (which asserts
  `boxtypeRepository.findById` is **never** called for a null `boxtype_id`). Fixing
  the second live crash without its regression test is precisely the gap to avoid.
- §8.3's `shouldStillEchoBusinessExceptionMessage` and
  `shouldStillEchoEntityNotFoundMessage` — the latter guards the HIGH-2 regression
  (`EntityNotFoundException extends RuntimeException`, so Fix D must catch it
  *before* `RuntimeException` or six endpoints lose actionable text).

**Action:** Restore the full §8.1/§8.3 PR1 test list, especially
`shouldGuardNullBoxtypeId`.

---

## Minor omissions (present in the plan, absent from the breakdown)

Not wrong — just missing from the execution notes:

- **Orphan `goodsreceipt` header** pre/post-deploy check (plan §7.1). The plan flags
  this because clean rollback is asserted but unproven, and the operator retried an
  unknown number of times.
- **Manual smoke §8.4, especially row 9** — reprint a `boxtype_id IS NULL` UL using
  the *specific* selection SQL. An arbitrary UL won't hit Path 2, so the test can
  false-pass.
- `git checkout archunit_store` after `mvn test`, and the "flaky `T*` while the
  SBDEV-2736 tree is moving — re-run standalone" caveat.
- Doc-drift sentence in `sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md` §4.4.
- `nullToEmpty` static helper isn't named explicitly (implied by "null-guard every token").

---

## Credit — good additions *beyond* the plan (keep these)

- **Phase 0 #3 — seed a dev ICE PACK system SKU (System client, `winetype` NULL).**
  Genuinely fills a gap: plan §1.4 records that reachable dev copies have *no*
  `client_id = 0` itemdata and no ICE PACK row, so the system-owned path cannot be
  reproduced on dev without a deliberate seed. The "SKU-sync writes `''`, not NULL"
  note is correct and explains why a plain sync won't reproduce it.
- **Phase 0 #4 — fill prod HMG ICE PACK's Product Type as an immediate ops
  workaround.** Sensible for unblocking urgent shipments, and correctly labeled
  workaround-not-fix (the code fix still lands).
- **New evidence:** the dev-WSL behavioral contrast (receives fine with
  `winetype = 'Fit in Packing'`) and "devops confirmed ICE PACK / winetype = NULL /
  System on prod" largely discharge the §1.4 DB prerequisite. Correctly, the
  breakdown still keeps **step 0 (verbatim error string) blocking** — the plan ranks
  that above the DB row, and it's the cheapest decisive confirmation of the
  `replacement` (i.e. `String.replace`) hypothesis.

---

## Required changes before execution

1. **Move Fix E into PR1** (non-negotiable — PR1 will not compile otherwise).
2. **Reconcile Fix D scope with the acceptance gate** — recommend reverting to
   `/receive`-only in PR1, with the five siblings in PR2.
3. **Restore the full PR1 test list**, especially `shouldGuardNullBoxtypeId`.

With those three corrections, the breakdown matches the approved plan. The Phase-0
additions (#3, #4, and the new evidence) are improvements and should be retained.

---

*Evidence for the critical finding was verified directly against `v2/wms2-api`
source on 2026-07-29: `BusinessException.java:14`, `UnitloadService.java:216/250/254`,
`UnitLoadController.java:66-67`.*
