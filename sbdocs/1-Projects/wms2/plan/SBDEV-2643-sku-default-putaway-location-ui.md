---
title: "WMSv2: SKU-level Default Putaway Location — configuration UI and the per-SKU effective-destination read"
ticket: "SBDEV-2643"
ticket_url: "https://app.clickup.com/t/868keru0b"
type: "feature"
priority: "urgent"
status: "ALL SIX PHASES MERGED 2026-08-12 — every line of code for this ticket is on develop.
  ⚠⚠ BLOCKING DEFECT FOUND IN MANUAL TESTING 2026-08-13, FIXED, MERGED — and it was NOT 2643's.
    PutawayConfigController was mapped at "/putawayConfig", outside /v3, while the web UI's axios baseURL
    ends in /v3 — so ALL FIVE of its endpoints 404'd from the browser: eligibleLocations, preview, and the
    sku/merchant/warehouse writes. SBDEV-2732's SHIPPED tier-2 and tier-3 pickers never worked either;
    2643's dialog inherited the same 404. Symptom: "No mapping for GET /v3/putawayConfig/eligibleLocations"
    in the API log, surfacing as the picker's "list of locations could not be loaded completely" banner.
    THREE FIXES, ALL MERGED 2026-08-13 — none of them 2643's, all found by clicking the pencil:
      #152 wms2-api  (fdd5c7c) THE BLOCKER — @RequestMapping("/v3/putawayConfig"); all 5 endpoints 404'd
      #153 wms2-api  (0517286) the eligible read used exceptions as verdicts, and BusinessException logs
                               at INFO in its CONSTRUCTOR → ~1,500 INFO lines + 1,500 exceptions PER
                               dialog open (2,738 candidates, 1,532 ineligible on wineco). Extracted
                               verdictFor(); validate() is now a thin throwing wrapper, ONE authority kept.
      #56  wms2-web-ui (10bec3a) the caption said "1206 of 2738 locations can be used" directly above an
                               EMPTY dropdown — the picker offers only the goods-in tier until "Show
                               storage locations" is enabled. Now states the split and how to reach the
                               rest. Rejected auto-enabling the toggle: it silently flips a safety default.
    ⚠ MEASURED, correcting the plan a THIRD time: 1,206 eligible at SKU scope on wineco-dev, not the
      "2,554" §3.8.2a asserts. With 2,564-candidates→2,738 and 13-round-trips→14, every figure in that
      section that anyone has actually checked has been wrong. Treat the rest as unverified.
    ORIGINAL: wms2-api PR #152, merged fdd5c7c (commit 808f17a) — one line, @RequestMapping("/v3/putawayConfig"),
    no UI change needed. Plus ControllerRequestMappingConventionUnitTest, which fails on this defect and on
    any future controller mapped outside /v3 | /rest | /api | /detrack.
    ⚠ WHY THE WHOLE GATE MISSED IT — the lesson worth keeping: every check in BOTH tickets asserts the
    METHOD annotation (@GetMapping("/eligibleLocations")), and controller unit tests use standaloneSetup,
    which never applies a class-level prefix. So the full path an HTTP client calls was asserted NOWHERE.
    It survived 2 tickets, 7 PRs, 289 UI tests, ~4,950 API tests and 94 verify rows. Only M9/M14 — a curl —
    could have caught it, and they had not been run. THE MANUAL ROWS ARE NOT A FORMALITY.
  ClickUp: `on dev` set 2026-08-12, with a handover comment listing the six PRs, the AC position, and the
    three outstanding items (comment 90110260191653).
  ⚠ MANUAL RUN STARTED 2026-08-13 — 9 rows PASS, and the feature works: ICE PACK (874400) was configured to
    ICEPACK (225817) through the UI, verified in the DB, then cleared, both with correct audit rows.
    PASS: M1, M4, M5, M6, M10(a), M10(d), M11, M13, plus an off-plan check that a rejected write neither
    writes nor audits. M6 also clears the response.reset()/CORS landmine — the server's own 422 text
    reached the toast, which is unreadable to JS without ACAO. Full log in §7.5a.
    STILL OPEN: M7 (needs a non-sb_admin login), M12, M3, M8, M9. M2 is moot — B1-pre shipped ahead of A1.
  ⚠ ONE PRODUCT QUESTION SPUN OUT, NOT BLOCKING: SBDEV-2947 (868kr048e) — the picker offers only the
    goods-in tier by default, and on wineco-dev ZERO goods-in locations are usable by any SKU (all 8,804 are
    Case; the one goods-in area's 12 locations take Pallet or nothing; HubAndSpoke-01..10 have no
    location_constraint rows at all). So this ticket's headline workflow sits behind "Show storage
    locations". It is 2732's shared control, so the fix moves tiers 2 and 3 too — hence a separate ticket
    rather than holding a merged one. Recommendation there: default the toggle on at SKU scope only. See §7.5a.
  ⚠ NOT DONE, and none of it is code: (1) the remaining manual rows above — they are the AC evidence, not
    the suite; (2) M14's HTTP half (its SQL half is closed); (3) the A4 SEARCH-BOX FOLLOW-UP
    PR, which owns the last 2 verify rows; (4) archive.
    ⚠ Do NOT archive while the search-box PR is open — `archive-plan` retires the verify script, which
    would take those two rows' only home with it.
  ⚠ B2 PREREQUISITES ARE NOW ALL SATISFIED: 2732 both phases merged, A4's `name` parameter on develop,
    B1's surface on develop, and V2.2.13 APPLIED to wms2-wineco-dev (2026-08-12) so AC4 (clear) and AC9
    (audit) are finally reachable. B2 branches off develop AFTER B1 — both touch skuData.vue.
    PR 1/6  B1-pre  wms2-web-ui #52   MERGED  9bfa8ac (commit 8c82308) — DEV image built before #149
    PR 2/6  A1      wms2-api    #149  MERGED  dc98461 (commit dcfd8e3)
    PR 3/6  A2      wms2-api    #150  MERGED  6161976 (commits 25e65ed + 1c1cc21 + 5977b44)
    PR 6/6  B2      wms2-web-ui #55   MERGED  af10b92 (commit 8cb7aa7)
                                      RE-VERIFIED ON MERGED DEVELOP from a clean detached checkout:
                                      289 tests / 29 suites, 0 failures; verify 94 pass / 2 fail, both
                                      being the deferred search rows.
                                      THREE lanes: conformance PASS; code review 1 HIGH + 4 Med + 8 Low
                                      (the ONLY High in six phases); then a scoped re-review of the 13
                                      fixes that found 4 more — TWO of them inside the test block written
                                      to protect that High. All applied. See §7.8d.
                                      ⚠ LANDS AT 94 pass / 2 fail BY DESIGN — the A4 search box was split
                                      into a follow-up PR (see §5.7a). `0 fail` moves there.
    PR 5/6  B1      wms2-web-ui #54   MERGED  3a61723 (commit 3022c3b)
                                      THREE lanes, 0 High throughout: conformance PASS, code review
                                      7 Medium / 11 Low -> "merge after M1-M5", then a scoped re-review of
                                      the 14 fixes (12 sound, 1 wrong, 1 incomplete — both corrected).
                                      RE-VERIFIED ON MERGED DEVELOP from a clean detached checkout:
                                      69 pass / 27 fail, zero B1/A1/A2/A4/X failures; all 27 remaining
                                      reds are B2's.
    ⚠ NEW WEB BASELINE — THE JEST SUITE IS NOW FULLY GREEN. SBDEV-2931 (web #53) landed immediately before
      #54 and DELETED the dead test/NuxtLogo.spec.js. Measured on merged origin/develop: 27/27 suites,
      260 tests, 0 failures. Every earlier row in this plan quoting "27 of 28 suites, NuxtLogo fails to
      run, pre-existing" was true when written and is now STALE. B2 must expect 28/28 (its 2 new specs
      replace the one removed suite) and treat ANY suite failure as its own.
    PR 4/6  A4      wms2-api    #151  MERGED  b40a990 (commits 79e8a76 + 2c5cbc2)
                                      RE-VERIFIED ON MERGED DEVELOP from a clean detached checkout of
                                      origin/develop (not the feature branch): 54 pass / 42 fail / 0 skip,
                                      identical to pre-merge; zero A1/A2/A4/X failures. The only two
                                      A4-prefixed reds are the dialog rows that live in the B2 block.
                                      BOTH lanes PASSED: conformance PASS, code review 0 High / 3 Medium /
                                      5 Low -> "merge after two one-line fixes". All 6 actionable findings
                                      fixed in 2c5cbc2 (§7.8b). ⚠ 3b took THREE attempts — the first went
                                      idle with no report and two died on a session limit; do not read an
                                      idle review lane as a clean one.
  VERIFIED ON MERGED DEVELOP (api 6161976 / web 9bfa8ac): verify 47 pass / 47 fail / 0 skip; all eight
  A1-*, all seventeen A2-* and all five X-* rows GREEN, zero A1/A2/X failures. 22 + 7 + 36 tests, 0
  failures; mvn clean compile clean; archunit_store unmutated. `0 fail` is NOT reachable until PR 6 by
  design — §8.0a's three-part per-PR criterion.
  ⚠ THE §5.1-row-4 DEPLOY GATE WAS HONOURED FOR PRs 1-2, not merely stated: #52 merged, its DEV build
  watched to success, and only then #149. A2 had no cross-repo gate.
  ⚠ A2 CARRIED A REAL DESIGN DEFECT, found by review, decided by Nam as OPTION (a). Reporting the
  CONFIGURED tier's P1 verdict made `compatible` disagree with both the writer (which exempts flowbins
  from P1) and receiving (which reports the PLACEMENT's verdict after divertPickFaceToLane). Confirmed on
  wms2-wineco-dev: ICEPACK type 51502 permits only unitloadtype 1; ICE PACK defultype_id is 4. describeForSku
  now returns PutawayDisplay(configured, placement), diverts unconditionally, and the envelope sources
  compatible/warning from the PLACEMENT plus divertedTo/divertedReason — §3.4's decision box.
  ⚠ KNOCK-ON FOR B2, DO NOT MISS IT: §3.8.2a's STATIC banner is no longer the only diversion signal. B2
  can render a per-SKU divertedReason resolved from messages.properties, matching the receive-time wording
  by construction. Strictly better than the hardcoded banner and unavailable when §3.8.2a was written.
  REVIEW ACROSS ALL PHASES: 0 Critical / 0 High at every round; 3 High + 7 Medium fixed in total. Rounds
  caught a test that COULD NOT FAIL, a verify clause satisfiable by JAVADOC (the same vacuity class the
  preceding commit had just fixed twice), and an UNPINNED divertedReason argument order — a hole
  ReceivingControllerUnitTest documents an earlier review lane having actually exploited with the whole
  suite green. All negative-tested.
  SETTLED WITH DATA: the divert adds a findByName(PutAwayLane) throw path; all four reachable tenants have
  exactly one such row, so risk is nil (§3.4).
  A4 AS BUILT: the plan's sketch would have parameterised the SHARED candidate query. Implementation
  instead left it BYTE-IDENTICAL and added a sibling findPutawayCandidatesByName, service branching on a
  trimmed-blank term — R11 becomes a structural guarantee, not an argument (§3.5a's r7 box). TWO VERIFY
  ROWS WERE GREEN ON CODE THEY EXISTED TO REJECT: A4-split (the R11 row itself) passed while the shared
  query was parameterised, and A4-inquery passed while the FILTERED query's value clause was broken behind
  a correct countQuery — the latter found by the conformance lane, not by me. Both rewritten with
  tempered-greedy gaps and re-negative-tested against 5 mutants. Also fixed: a javadoc claiming the 3-arg
  overload is where 2732's pickers arrive (FALSE — it has zero production callers).
  ⚠ R11 IS MITIGATED IN CODE BUT NOT CLOSED — manual row M14 (compare totalElements at WAREHOUSE and
  MERCHANT scope against the pre-A4 value on DEV) is the closure evidence and has NOT been run.
  ORIGINAL NOTE: A4 branches off develop @ 6161976. ⚠ THE RISKY PHASE (R11): it edits two SBDEV-2732-owned files
  serving the LIVE WAREHOUSE and MERCHANT pickers and its failure mode is SILENT — legal destinations
  quietly missing from someone else screen, no toast, no 4xx. Its empty-search identity test must be green
  before it merges, and §8.4 row 3a wants evidence those two pickers still return their full sets (~516 at
  merchant/warehouse scope on wineco-dev), which 2643 own tests cannot show.
  GATE TESTS for A4/B1/B2 are parked on tdd-gate/SBDEV-2643 in BOTH repos. DO NOT DELETE THOSE BRANCHES.
  NOT DONE: ClickUp `on dev` (belongs to whoever validates the deploy), archive, deploy verification.
  Zero migrations throughout, so no tenant DB is pending anything."

project: [wms2]
version: "v2"
db_verified: true
requester: "Scott Dalton"
assignee: "Nam Park / David Oppenheim"
created: "2026-08-07"
updated: "2026-08-12"
revision: 7
depends_on:
  - {ticket: SBDEV-2732, status: "✅ FULLY MERGED 2026-08-11 — BOTH PHASES. Phase 1-API merge 889298d;
       Phase 2 steps 18a/A/B/C/D + 19/19a/20/21/22 all merged across wms2-api (#139, #141-#148) and
       wms2-web-ui (#42-#49). 2732's own verify script reads PHASE=all 285 pass / 0 fail. It is READY TO
       ARCHIVE pending only an optional product read of the step-19a diversion wording.
       ⛔ NOTHING IN 2643 IS BLOCKED ON 2732 ANY MORE. Re-verified by symbol grep on origin/develop
       2026-08-12 at api bcfdc47 / web e702a42. (Was 'Phase 2 NOT started'; refreshed 2026-08-12.)",
     note: "SPLIT BY PHASE — check which half you need before assuming a blocker.
       ---- MERGED on develop (merge 889298d + review commit 0837289; PR #139 head was aff434e):
       PutawayDestinationResolver, PutawayConfigService.setSkuDestination,
       PUT /putawayConfig/sku/{itemdataId} (PutawayConfigController:154),
       PutawayDestinationQueryService, PutawayDestinationValidator, putaway_config_audit,
       GET /v3/receiving/getPutawayDestination/{advicePositionId}, stop-seeding, and
       V2.2.13 (3x DROP NOT NULL). Re-verified by symbol grep on origin/develop 2026-08-11.
       ---- ⚠ THE 'STILL ABSENT' LIST IS EMPTY AS OF r7. Every construct 2643 waited on is on develop:
       components/common/LocationPicker.vue (+ its spec) with EXACTLY the props/events contract this
       plan wrote at §3.8.2b — value / items / disabled / item-text / item-value, @input + @select
       emitting the full row — plus the server-supplied tier field;
       GET /putawayConfig/eligibleLocations (PutawayConfigController:92) returning the record
       {locationId, locationName, areaName, locationType, tier, eligible, blockingReason}, which
       matches §3.5's specified row shape field-for-field, tier added;
       BlockingReason as its own service-layer enum with ALL SEVEN values — LOCKED, FIX_ASSIGNED, LANE,
       BOUND_TO_ANOTHER_SKU, AREA_NOT_USABLE, FLOWBIN_SCOPE, TYPE_INCOMPATIBLE — so Q2's residual gap
       (MUST-4's this-SKU-vs-another distinction was unnameable) is CLOSED;
       util/keycloakRoles.js, the working sb_admin gate;
       store/admin/configuration.js with getEligiblePutawayLocations / previewPutawayConfig /
       setWarehouse- and setMerchantPutawayDestination;
       and components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue — the wrapper
       that B2 now EXTENDS instead of cloning (see 3.8). Its scope prop is documented
       \"'MERCHANT' / 'SKU' when steps 21 and SBDEV-2643 reuse this\".
       ---- CONSEQUENCE for this plan: the 10 ACs blocked on Phase 1-API are UNBLOCKED NOW, and A2 is
       implementable off 889298d. AC4 and AC9 are reachable on wms2-wineco-dev (V2.2.13 applied
       2026-08-11 13:50:50) but NOT on wh01_hydra_v2, which has no flyway_schema_history at all, so the
       boot migrator skips it: client.defaultputawaylocation_id is absent, itemdata.putawaylocation_id is
       still NOT NULL, putaway_config_audit does not exist, and that tenant throws 42703 on every client
       read. Manual rows touching AC4/AC9 must run on wineco-dev (Q10).
       ---- PHASE A3 IS DELETED (r6): 2732 owns eligibleLocations. Do not build it here.
       ---- MIGRATION VERSION MOVED: V2.2.11 -> V2.2.13 on 2026-08-10 (V2.2.11 was claimed by PR #138,
       V2.2.12 also taken). Cite V2.2.13; V2.2.11 in older notes means this same file.
       ---- 2732 does NOT close when #139 merges: its own Phase 2-UI closes it, and that phase owns the
       WAREHOUSE and MERCHANT tier UI. This plan owns the SKU tier only. (Phase 2-UI has since merged;
       2732 is complete. The tier split stands: 2643 still owns the SKU tier and only that.)
       ---- ⚠ r7 BOUNDARY CHANGE: B2 now writes into TWO 2732-owned files, by design and with the cost
       stated. See 14 principle 1 and 3.8. Verify row A2-neg-2732f still holds for the API side —
       describeForSku does NOT go into 2732's facade."}
  - {ticket: SBDEV-2863, sha: 675b4a1, status: "MERGED 2026-08-07 — PR #134 (merge 7d9d38e)",
     note: "RETIRES THIS PLAN'S PHASE A0 ENTIRELY. 2863 shipped BOTH halves in one commit:
       Authority.java:44 is now IS_SB_ADMIN = \"hasAuthority('\" + SB_ADMIN_ROLE + \"')\", and the same
       commit added the @Nested AuthorityExpressionsResolve class to
       CustomMethodSecurityExpressionRootUnitTest — a strict superset of A0's planned detector
       (resolves-without-exception; TRUE for sb_admin; FALSE for a non-admin; agrees with
       isAimAdmin(); prefix-independent; plus a harness self-test). Consequences: F1 is FIXED, not
       merely owned elsewhere; §5.1 row 0e is DISCHARGED; AC12's backend half is unblocked; and
       2732 §3.12's six @PreAuthorize(Authority.IS_SB_ADMIN) sites are CORRECT as written."}
  - {ticket: SBDEV-2731, sha: 6bc709a, status: "MERGED",
     note: "wms2-api #133 @ 6bc709a + wms2-web-ui #39 @ 4ce39a1, both on develop. Supplies the
       configured-vs-default display precedent and the wording constants this plan reuses verbatim
       (receivingForm.vue:296-297), plus the neutral unitloadTypeNotPermittedOnLocation message the
       receive-time backstop already renders."}
related:
  - "[[SBDEV-1938]]"
  - "[[SBDEV-2642]]"
  - "[[SBDEV-2731-alternate-putaway-location-not-honored-receiving]]"
  - "[[SBDEV-2732-configurable-default-putaway-location-hierarchy]]"
  - "[[SBDEV-2796]]"
  - "[[SBDEV-2821]]"
  - "[[SBDEV-2863]]"
  - "[[wms2-it-harness-broken-sbdev-2217]]"
db_verified_note: >
  Verified 2026-08-07 against hydra/nywh DEV (`wms2-hydra-dev2` = `wh01_hydra_v2`, tunnel :25060).
  ALL READS SELECT-ONLY — no DDL, no DML, no session settings changed. "HMG" is the former name of
  the Hydra `nywh` warehouse, so the ticket's "Example Warehouse: HMG" resolves to this tenant.

  MEASURED (each number reproduced independently of the analysis lane):
  `itemdata` = 2,720 rows; `count(DISTINCT putawaylocation_id)` = **1**; rows with
  `putawaylocation_id IS NULL` = **0**; `information_schema.columns.is_nullable` for
  `itemdata.putawaylocation_id` = **NO**; `location` = **666**; columns named `location.active` = **0**;
  tables named `putaway_config_audit` = **0**.

  SKU-SCOPE ELIGIBILITY under SBDEV-2732's predicate set (P2.2 `entity_lock = 0` AND P2.3 no lane flag
  AND P2.4 `useforgoodsin OR useforstorage` AND P2.5 no `fix_location_assignment.assignedlocation_id`
  AND P2.7(c) not in a `useforpicking` area): total 666 → unlocked 666 → no-lane 644 →
  goodsin-or-storage 603 → **92 eligible (13.8%)**. Rejected by P2.7(c): **511 in a `useforpicking`
  area**. Rejected by P2.5: **154 fix-assigned**.

  THE FINDING THAT DRIVES D1: by `location_type.sltname` (the column is `sltname`, NOT `name`), the
  tenant has **496 flowbins, and all 496 are in a `useforpicking` area**; 154 of them are fix-assigned.
  So P2.7(c) rejects **every flowbin in the warehouse**. SBDEV-2731's own PRD evidence records the
  reported ICE PACK location as id 52075 with `type_id = 2` (`flowbin`) — i.e. the one location this
  ticket exists to configure is rejected by 2732's SKU-scope predicates.

  ⚠ **r3 (2026-08-08) IS THE CURRENT CONCLUSION — the r2 text below is SUPERSEDED.** The measurement is
  unchanged and still correct; what keeps changing is what 2643 does about it.

  **r3: 2643 OFFERS the 511 pick-face locations, `ICE PACK` among them.** 2732 answered Q12 as option
  (iv-b) on 2026-08-08: configuration is widened at every scope, `skuWriteRejectsPickFaceDestination`
  is DELETED, and a SKU-scope pick-face write is LEGAL. What is refused is the *placement*, at run time.
  Tier 1 is exempt from 2732's P2.7 rule (e), so flowbins are offerable at this plan's scope.
  **One exclusion survives:** a flowbin fix-assigned to a *different* SKU (2732's rule (f), added
  2026-08-09) — 1,344 of 2,555 candidate rows on `wms2-wineco-dev`, 154 of 603 on `wms2-hydra-dev2`.
  See §10.1 D1 and §15.

  ~~r2 (2026-08-07): a SKU-scope pick-face WRITE is an unconditional 422 that 2732 ships a unit test to
  enforce (`skuWriteRejectsPickFaceDestination`, 2732 `:2211`), so offering those 511 rows would offer
  rows that cannot be saved; 2643 therefore offers only the 92 eligible locations.~~ **That test no
  longer exists and the cited line no longer resolves.**

  ⚠ **DEPENDENCY NOW SATISFIED:** SBDEV-2821 **merged to `develop` 2026-08-09** (`wms2-api` PR #135,
  merge `fd90487`), so putaway can surface a configured destination. The r2 text's hand-off of tier-1
  pick-face relaxation to 2821 is complete.
tags:
  - plan
---

# WMSv2: SKU-level Default Putaway Location — configuration UI and the per-SKU effective-destination read

**Ticket:** [SBDEV-2643](https://app.clickup.com/t/868keru0b)
**Project:** wms2 (`wms2-api` + `wms2-web-ui`) | **Version:** v2 | **Type:** feature
**Priority:** urgent
**Status:** draft
**Date:** 2026-08-07

> **This plan is a THIN CONSUMER STACKED ON SBDEV-2732.** 2732 owns the resolver, the validated
> writer, the write endpoint, the read facade, the audit table, `V2.2.13`, stop-seeding, and
> `LocationPicker.vue`. **SBDEV-2643 ships ZERO migrations.** Its own deliverables are six small,
> well-bounded items (D-A … D-F, §3) plus the SKU edit surface. Everything else it needs belongs to
> 2732, and **as of 2026-08-07 none of 2732 exists in merged code** — its plan is `status: draft`.
>
> Read §5.1, §8 and **§3's blocking banner** before writing a line of code. Two items are
> implementable **today** — `B1-pre` then A1 (in that order, §5.1 row 4) — plus most of
> B1; everything else waits on 2732's Phase-1 merge landing on `develop`.
> *(Was "three items … A0's detector, `B1-pre`, and A1". **A0 is retired** — see revision 5 below.)*
>
> **⚠ REVISION 5 (2026-08-09) — PHASE A0 IS RETIRED. SBDEV-2863 SHIPPED IT.**
>
> [SBDEV-2863](https://app.clickup.com/t/868knmx18) **merged 2026-08-07** — `wms2-api` PR #134, commits
> `675b4a1` (fix + tests) and `d8e0137` (docs), merge `7d9d38e`, ClickUp `on dev`. It shipped **both**
> halves of F1 in one commit, which is more than this plan assumed anyone would do:
>
> 1. **The constant is repaired.** `Authority.java:44` now reads
>    `IS_SB_ADMIN = "hasAuthority('" + SB_ADMIN_ROLE + "')"` — fix option (1), the one §3.1 recommended.
>    The 9 endpoints that returned 500 to every caller now authorize correctly.
> 2. **The detector exists, and it is a superset of A0's.** The same commit added a `@Nested`
>    `AuthorityExpressionsResolve` class to `CustomMethodSecurityExpressionRootUnitTest` (+210 lines)
>    that parses and evaluates the constant against a root built through the **real**
>    `CustomMethodSecurityExpressionHandler` — asserting it resolves without `SpelEvaluationException`,
>    evaluates TRUE for an `sb_admin`, FALSE for a non-admin, agrees with `isAimAdmin()`, and is
>    `ROLE_`-prefix-independent, plus a self-test proving the harness would catch a broken expression.
>    A0's two planned tests are both subsumed.
>
> **Consequences for this plan, all reductions:**
> - **Phase A0 is deleted**, not deferred. Its branch, its file change, its 5 verify rows and its
>   `A0-test` row are gone. §5.2's phase count drops from six to five.
> - **§5.1 row 0e is DISCHARGED.** "2732 must not merge carrying `Authority.IS_SB_ADMIN`" is void —
>   that annotation is now the *correct* one, and 2732 §3.12 needs no change.
> - **AC12's backend half is unblocked.** F2 still stands (`standaloneSetup` evaluates no
>   `@PreAuthorize`, and the IT lane is down per SBDEV-2217), so **M8 stays the AC12 evidence** — but
>   it should now return **403**, and a 500 means 2863 regressed, not that 2732 mis-merged.
> - **Two verify rows were already reporting falsely** and have been fixed: `A0-ctx1` asserted the
>   *broken* spelling survives (permanently red since 2026-08-07), and **`X-2732-authz` would have gone
>   red against a correct SBDEV-2732** — it asserted the absence of the very annotation 2732 is right
>   to write. Both are replaced by `X-authz-constant`, a regression guard on the repair itself, which
>   runs today and was negative-tested against the pre-fix `Authority.java` (`6bc709a`).
>
> **⚠ REVISION 2 (2026-08-07) REVERSED D1 — AND REVISION 3 (2026-08-08) REVERSES IT BACK.**
>
> **r1** offered pick faces behind an advisory warning. **r2** enforced 2732's P2.7(c) and offered only the
> 92 genuinely-eligible locations, on the sound reasoning that a SKU-scope pick-face write was an
> unconditional 422 which 2732 shipped a test to enforce — so r1 would have offered ~511 unsavable rows.
>
> **r3: that premise no longer holds.** SBDEV-2732 answered **Q12 as option (iv-b)** on 2026-08-08.
> Configuration is now **widened at every scope**: `skuWriteRejectsPickFaceDestination` is **deleted**, and
> a SKU-scope pick-face write is **legal**. What is refused is the *placement* — receiving diverts a
> pick-face destination to the standard lane and putaway routes it (2732 §5.2 step 15). Three consequences
> for this plan:
>
> 1. **D1 returns to r1's shape** — offer pick faces, with an advisory rather than an exclusion. r2's
>    exclusion would now hide **511 savable locations**, including `ICE PACK` itself, which is the
>    configuration the parent bug is about.
> 2. **Tier 1 is exempt from 2732's P2.7 rule (e).** Rule (e) bars `flowbin`-type destinations at
>    **merchant and warehouse** scope only (putaway auto-creates a `FixLocationAssignment` binding the
>    location to the first SKU, which breaks multi-SKU scopes). **This plan is SKU scope, so flowbins are
>    offerable here.**
> 3. **P1 must be skipped for `flowbin` destinations at write time** (2732 §3.4c). Without that, `ICE PACK`
>    is still unsavable — flowbin permits only `PickLocation` and the SKU's default type is `Case`. **This
>    plan depends on that exemption shipping; if 2732 implements P1 unguarded, the picker will offer rows
>    the backend still rejects and r2's objection becomes correct again.**
>    ⚠ **NARROWED 2026-08-09 by review of 2732:** the skip predicate is **`sltname == 'flowbin'` ONLY**, not
>    the `useforpicking OR flowbin` form r3 was drafted against. That does not change this plan's dependency
>    — `ICE PACK` is a flowbin either way — but 2643 must not restate the wider predicate anywhere.
>
> **⚠ 4. ADDED 2026-08-09, POSTDATES r3 — 2732 gained P2.7 rule (f), and it changes what the picker must
> exclude.** Tier 1 is exempt from rule (e), but **not** from rule (f): a flowbin whose
> `FixLocationAssignment` belongs to a **different** SKU must **not** be offered, because such a row saves
> cleanly and then fails at *every* putaway (`scannedLocationHasDifferentFixedAssignment`) with nothing
> naming the configuration that caused it. **This is the majority of flowbins, not an edge case** — 1,344 of
> 2,555 candidate rows on `wms2-wineco-dev` (53%), 154 of 603 on `wms2-hydra-dev2` (26%).
> **Consequences for this plan:** the exclusion set is **never empty**, so r3's claim that *"on HMG
> production the exclusion set is empty — every candidate qualifies"* no longer holds; and `blockingReason`
> needs a value distinguishing own-from-foreign, which is **2732's enum to extend, not this plan's**
> (MUST-4).
>
> **The advisory text matters.** A pick-face destination does not receive stock directly — it is routed via
> putaway, so the operator performs one putaway scan. Say that, rather than implying immediate placement.
>
> **✅ RE-MEASURED 2026-08-09 (SELECT-only).** r2's arithmetic (603 goods-in-or-storage → **92 eligible**,
> **511 excluded by P2.7(c)**) was computed with P2.7(c) as an absolute reject. Those two numbers sum
> exactly to the population — **P2.7(c) was doing ALL of the exclusion.** Under (iv-b) it is dropped, so at
> SKU scope the picker's exclusion set collapses to the remaining predicates (locked, lane flags, area):
>
> | Tenant | goods-in-or-storage | of which in a picking area | **eligible at SKU scope under (iv-b)** |
> |---|---|---|---|
> | `wms2-wineco-dev` (tester's env) | — | — | **2,555** of 2,739 total locations |
> | `wsl-wineco-uat` | 2,704 | **2,219** | **2,694** |
> | `wms2-hydra` (HMG PRD) | 229 | **191** | **229** |
>
> **On HMG production the exclusion set is now empty** — all 229 qualify. On wineco UAT r2's rule would
> have hidden **2,219 of 2,704** locations, about 82% of the picker.
>
> **r2's own population (603) matches none of these three tenants**, so its figures were measured somewhere
> else again — treat them as unusable rather than merely stale, and re-derive on whichever tenant this ships
> against. The `db_verified` note needs the same treatment.
>
> **Tier 1 is exempt from rule (e)**, so flowbins are offerable here; rule (e) bars them at merchant and
> warehouse scope only.
>
> **Read §15 (revision log) before §10.1, and §14 for the principles this is graded against.**

> **Repos verified at:** `v2/wms2-api` `6bc709a` (branch `develop`), `v2/wms2-web-ui` `4ce39a1`
> (branch `develop`) — both are the SBDEV-2731 merge. Every `file:line` in this document was read at
> those SHAs. Claims that could not be confirmed are marked **UNVERIFIED** inline.

---

## 0. Affected Sites

Enumerated 2026-08-07 by grep against disk, not from memory: `putawaylocation|putawayLocation|PutAwayLocation`
(case-insensitive) across `v2/wms2-api/src` and `v2/wms2-web-ui` (excluding `node_modules`, `.nuxt`,
`cypress`), plus the SKU-screen store and every component that renders SKU details.

Every **out-of-scope** row keeps its ownership marker. `no — owned by SBDEV-2732 <section>` means the
construct is real and needs changing, but **2732's PR changes it** — do not touch it here, and do not
re-discover it during implementation.

### 0.1 API — `v2/wms2-api/src/main/java/net/aim_ai/wms/`

| # | File:line | Construct | In scope this plan? | Phase |
|---|---|---|---|---|
| 1 | `service/ItemdataService.java:119-174` | `getItemdataDetails` — the SKU details map | **YES — primary API change** | A1 |
| 2 | `service/ItemdataService.java:166-171` | `putawayLocation` = location **name only**; key omitted when id null **or** FK dangling | **YES — add `putawayLocationId`; the dangling-FK ambiguity is AC8's blocker (§3.3, Q6→D-C)** | A1 |
| 3 | `controller/ItemDataController.java:173-176` | `GET /v3/itemData/itemdataDetailsById/{id}` → row 1 | **YES — payload grows** | A1 |
| 4 | `controller/ItemDataController.java:186-191` | `GET .../itemdataDetailsByNumberAndClientNumber/{n}/{cn}` → row 1 | **YES — payload grows; 12 UI consumers (§6.2)** | A1 |
| 5 | `controller/ItemDataController.java:179-183` | `GET .../itemdataDetailsByNumber/{n}` → row 1; `:182` `.get(0)` throws `IndexOutOfBoundsException` on a miss | **YES for the payload; NO for the `.get(0)` bug** — pre-existing, zero UI consumers, out of scope (F6) | A1 |
| 6 | **NEW** `GET /v3/itemData/{id}/effectivePutawayDestination` | the per-SKU 4-tier effective read | **YES — D-B** | A2 |
| 7 | **NEW** `service/SkuPutawayQueryService.describeForSku(Long)` | `readOnly=true` tenant-transaction boundary for the `MANDATORY` resolver. ⚠ **r2: 2643's OWN new file**, not a method added to 2732's `PutawayDestinationQueryService` (§3.2) | **YES — D-A** | A2 |
| 8 | `controller/ItemDataController.java:80` | `@CacheEvict(value="itemdata", allEntries=true)` — flushes every tenant | no — owned by SBDEV-2732 §3.5 (its §0.1 row 14) |
| 9 | `controller/ItemDataController.java:81` | state-mutating `@GetMapping` with `consumes="application/json"` | no — owned by SBDEV-2732 §3.5 / §10.4 Q5 (**deliberately left as-is**: the web UI calls it and changing the verb is a breaking API change) |
| 10 | `controller/ItemDataController.java:83-85, 89-91` | zero-validation write path; `itemdataService.getById` (`@Cacheable`) then raw `save()` | no — owned by SBDEV-2732 §3.5 |
| 11 | `controller/ItemDataController.java:93` | `LOG.debug(... oldLocation={} ...)` interpolates `itemData.getPutawaylocationId()` **after** `:90` mutated it — both args render the NEW id | **YES — 2643 flags it.** 2732 §3.5 rewrites the method but never names this line. If 2732 ships without fixing it, 2643 fixes it (one line). See **D11** (§10.1) |
| 12 | `service/ItemdataService.java:47-50` | `getById` is `@Cacheable`; writers must not use it | no — owned by SBDEV-2732 §0.1 row 13a |
| 13 | `service/ItemdataService.java:62-76` | dead `setPutAwayLocation` (0 production callers) carrying the **correct** 2-key `@CacheEvict` at `:62-67` | no — owned by SBDEV-2732 §3.5 (promoted to the validated writer) |
| 14 | `model/Itemdata.java:49-51` | `@NotNull` on `putawaylocationId` | no — owned by SBDEV-2732 §3.2 (removed with `V2.2.13`) |
| 15 | `controller/LocationController.java:47-49` | `GET /v3/location/detailView` → `getLocationView()` | **YES — read-only context for D-D; NOT widened (D3)** | A3 |
| 16 | `service/ViewDtoService.java:806-832` | `getLocationView()` — exactly 8 fields (`id` `:815`, `locationName` `:816`, `clientNumber` `:817`, `clientName` `:818`, `areaName` `:819`, `locationType` = `sltname` `:820`, `created` `:821`, `modified` `:822`). **No lane flags, no `type_id`, no `usefor*`, no `entity_lock`** | **YES as evidence, NO as a change target** — D3 rejects widening it (4 other screens consume it). D-D ships a dedicated endpoint instead | A3 |
| 17 | `repo/jpa/LocationRepository.java:104-111` | `getStorageLocationsForPutAwayItemData` — `a.useforstorage = 'true'` **and stockunit-driven** (returns only locations where the SKU already has stock) | **NO — must NOT back the picker**, on two independent grounds. 2732 §0.1 row 34 / §3.4c |
| 18 | `repo/jpa/LocationRepository.java:21-22` | `findByName` → tier-4 resolution, no `client_id` filter, `location.name` not unique | no — owned by SBDEV-2732 §3.4b / §5.1 |
| 19 | `SecurityConfiguration.java:143` | `/v3/**` → `hasAnyAuthority("wms_user")` only. **Path note:** the file is `net/aim_ai/wms/SecurityConfiguration.java`, **not** `config/SecurityConfiguration.java` (C1) | **YES — context: any warehouse user can repoint any SKU today. 2643 must not widen it** | A2 |
| 20 | `Authority.java:44` *(was `:14`)* | ~~`IS_SB_ADMIN = "isSbAdmin()"` — names a SpEL method that does not exist (F1)~~ **FIXED by SBDEV-2863 `675b4a1` (2026-08-07): now `"hasAuthority('" + SB_ADMIN_ROLE + "')"`** | **NO — F1 is closed. Guarded against regression by verify row `X-authz-constant`** | ~~A0~~ |
| 21 | `CustomMethodSecurityExpressionRoot.java:77` | `isAimAdmin()` — the **only** admin predicate the custom root defines; 2863 deliberately did **not** add an `isSbAdmin()` alias | **NO — historical evidence for F1** | ~~A0~~ |
| 22 | `Authority.java:17, 52` *(was `:19, 24`)* | `SB_ADMIN_ROLE = "sb_admin"`; `getExpForRole(String)` → `hasAuthority('<role>')` — the shape 2863 adopted | **NO — 2863's fix target, already applied** | ~~A0~~ |
| 23 | `CustomMethodSecurityExpressionHandler.java:19` | `root.setDefaultRolePrefix(null)` — why a bare authority name is correct and no `ROLE_` prefix is needed | **NO — read-only context; 2863 pins it with `hasAuthorityIsPrefixIndependent`** | ~~A0~~ |
| 24 | `MethodSecurityConfig.java:9-18` | `@EnableMethodSecurity(prePostEnabled=true, …)` + handler wiring | **NO — read-only context** | ~~A0~~ |
| 25 | `controller/AdminController.java:80, 108, 121, 134, 143, 155, 176, 194` | 8 live `@PreAuthorize(Authority.IS_SB_ADMIN)` sites — ~~all return 500 for everyone today~~ **all authorize correctly since `675b4a1`** | **NO — repaired by SBDEV-2863** | ~~A0~~ |
| 26 | `controller/ReplenishmentReconciliationController.java:37` | the 9th `@PreAuthorize(Authority.IS_SB_ADMIN)` site — **also repaired** | **NO — same** | ~~A0~~ |
| 27 | `controller/AdminController.java:31` | `@RequestMapping("/v3")`, **no class-level `@PreAuthorize`** — so `ItemDataController extends AdminController` (`:34`) inherits no authorization | **YES — read-only context** | A2 |
| 28 | `service/ViewDtoService.java:895-931` | `getItemDataViewPage` — SKU table projection at `:915-924`, **no putaway field** | **no — Q4 answered NO COLUMN** (§10). Overlay + dialog satisfy AC1; a column would need a second API change and hits the persistedState hazard (F3) | — |
| 29 | `controller/rest/SkuRestController.java:85-88, 144-146, 198-201, 257-259` | create/update seed `putawaylocation_id` = lane id | no — owned by SBDEV-2732 §0.1 rows 8, 9 (stop-seeding, same commit as `V2.2.13`) |
| 30 | `controller/FileImportController.java:355-359, 383` | CSV import seeds the lane id | no — owned by SBDEV-2732 §0.1 row 11 |
| 31 | `service/SkuBatchCreateUpdateService.java:36, 53` | `setPutawaylocationId(defaultPutawayLocationId)` | no — owned by SBDEV-2732 §0.1 row 10 (parameter removed) |
| 32 | `service/WmsConstants.java:771` | `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"` | no — owned by SBDEV-2732 §0.1 row 32. **2643 reads it** for display wording and for Q3's picker exclusion |
| 33 | `service/ReceivingService.java:454-457, 491-495` | the consumption side of the SKU value | no — owned by SBDEV-2732 §3.7, **and** explicitly out per the ticket's own "Receiving Behavior Boundary" |
| 34 | `service/BoxtypeService.java:87` | `details.put("putawayLocation", …)` for **box types** | **out** — unrelated entity, same key name. Do not sweep it |
| 35 | `model/ReceivingDtoView.java:47, 173` | `defaultputawaylocationname` | no — owned by SBDEV-2732 §3.8 (the view needs **no** change) |
| 36 | `service/ReportService.java:182` | `getDefaultputawaylocationname()` | out — read-only report column (2732 §0.1 row 36) |
| 37 | `service/mobile/MobileMoveUnitloadService.java:362-366`, `service/ReturnAdviceAutoReceiveService.java:344-348` | lane-by-name / null-guard readers | no — owned by SBDEV-2732 §3.7.4 |
| 38 | `src/main/resources/db/migration/` head = **`V2.2.10`** (swept across **all** remote branches, not `ls`) | Flyway state | **out — 2643 ships NO migration.** `V2.2.13` is 2732's |
| 39 | `landlord/config/IdempotencyFilter.java:262` | Javadoc naming `ItemdataService.setPutAwayLocation` | out — comment only; **goes stale when 2732 rewrites that method** — flag to 2732 |
| 40 | `landlord/config/IdempotencyFilter.java:271` | `uri.startsWith("/rest/sku/")` — the filter guards `/rest/**` only, so `PUT /putawayConfig/**` is outside it | **YES — read-only context for §7's scalability row 6** | A2 |
| 41 | `controller/ItemDataController.java:97-98` | `sendStockUpdate` — notifies OMS via `httpRestService` | **out, and load-bearing that it stays out**: a putaway-config change must **not** trigger an inventory export. Verify row `A2-neg-oms` asserts it | A2 |

### 0.2 API tests — `v2/wms2-api/src/test/`

| # | File:line | Construct | In scope this plan? | Phase |
|---|---|---|---|---|
| 42 | `unit/controller/ItemDataControllerUnitTest.java:91-102` | the **11-arg** `new ItemDataController(...)` construction (verified 2026-08-07: `keycloakService, 100, itemdataRepository, clientRepository, warehouseStockReportService, dtoViewService, itemdataService, syspropRepository, messageService, httpRestService, syspropService`) | **YES — adding a constructor parameter for D-B breaks this test.** Expect to touch it | A2 |
| 43 | `unit/controller/ItemDataControllerUnitTest.java:111` | `testItemdata.setPutawaylocationId(5L)` fixture | **YES — reused by the new nested class** | A1 |
| 44 | `unit/controller/ItemDataControllerUnitTest.java:119-158` | `@Nested @DisplayName("setPutAwayLocation")` — `:125-146` happy path, `:148-157` not-found | **⚠ COLLISION — do NOT edit.** 2732 Phase-1 Step 9 rewires `ItemDataController:80-95` and must edit these same two tests. 2643 appends a **NEW** nested class at the end of the file (`:374` is EOF) | A2 |
| 45 | `unit/service/ItemdataServiceUnitTest.java:415-428` | `shouldIncludePutawayLocationWhenPresent` — asserts `get("putawayLocation") == "LOC-001"` | **YES — gains a `putawayLocationId` assertion** | A1 |
| 46 | `unit/service/ItemdataServiceUnitTest.java:448-472` | `shouldHandleItemWithAllOptionalFields` — `containsKeys(...)` list at `:468-471` | **YES — the added key must be added here** | A1 |
| 47 | `unit/service/ItemdataServiceUnitTest.java:475-498` | `shouldHandleMissingOptionalReferences` — dangling FK ⇒ `doesNotContainKey("putawayLocation")` at `:498` | **YES — this test ENCODES the AC8 ambiguity.** Adding `putawayLocationId` unconditionally requires rewriting it, deliberately (§3.3) | A1 |
| 48 | `unit/service/ItemdataServiceUnitTest.java:585-604` | null id ⇒ `doesNotContainKey("putawayLocation")` at `:604` | **YES — this is the correct "not configured" case and MUST stay green.** It also must NOT gain `putawayLocationId` | A1 |
| 49 | `unit/config/OptionalSafetyArchTest.java:37` + tracked `src/test/resources/archunit_store/{stored.rules, 5fb3fee0-6caf-4f48-a5cd-5271da610572}`, config `src/test/resources/archunit.properties` | `FreezingArchRule.freeze(...)` over a **git-tracked** violation store (F4) | **YES — build-hygiene constraint.** A new unguarded `Optional.get()` either fails the build or **silently freezes**; `mvn test` mutates the tracked store | all |
| 50 | `unit/CustomMethodSecurityExpressionRootUnitTest.java` | `:170-206` tested `isAimAdmin()` **directly**, never evaluating the SpEL string — the reason F1 was invisible for 9 endpoints. **SBDEV-2863 `675b4a1` appended `@Nested AuthorityExpressionsResolve` (+210 lines) which evaluates the constant through the real handler** | **NO — the test A0 would have written already exists, and is broader** | ~~A0~~ |
| 51 | `common/base/BaseControllerUnitTest.java:34, 52-58` | `setupMockMvc` → `MockMvcBuilders.standaloneSetup(...)` — **no security filter chain, no method-security advisor** (F2). ⚠ The class is `BaseControllerUnitTest`, **not** `BaseControllerTest` (C6) | **YES — this is what makes AC12 non-automatable in the Java unit lane** | A2 |
| 52 | `common/fixtures/TestDataFactory.java:632, 677-678, 694` | `ItemdataBuilder.withPutawaylocationId` | no — 2732 updates ≈10 fixtures for the nullable column |
| 53 | `unit/service/BoxtypeServiceUnitTest.java:188, 222` | box-type `putawayLocation` assertions | out — row 34's entity. Do not touch |
| 54 | ~10 `src/test/resources/scripts/*.sql` + 4 IT files seeding `putawaylocation_id` | NOT NULL fixtures | no — owned by SBDEV-2732 Step 3 |

### 0.3 Web UI — `v2/wms2-web-ui/`

| # | File:line | Construct | In scope this plan? | Phase |
|---|---|---|---|---|
| 55 | `components/masterData/material/skuData/skuData.vue:95-99` | **ACTIVE** `item.actions` template, one eye button at `:97` (`@click="showDetails(item)"`) | **YES — add the Edit affordance beside it.** ⚠ An actions column already exists and already ships one button (C2) — 2643 adds a second, it does not create the column | B1 |
| 56 | `…/skuData.vue:100-123` | commented-out pencil / trash / `v-menu`("Something 1/2/3") block | **YES — delete the corpse.** It is the reference shape only; do **not** resurrect trash or the menu. ⚠ 2732 §0.2 row 45 cites this as `:107-131` — **wrong** (C4) | B1 |
| 57 | `…/skuData.vue:126-152` | `<full-details title="SKU Details" …>` overlay | **YES — host the Edit entry point via its `#actions` slot** | B1 |
| 58 | `…/skuData.vue:130` | `:exclude-fields="['id', 'itemNr', 'version']"` | **YES — MUST add `'putawayLocationId'`, or a raw-integer row renders (§6.1)** | B1 |
| 59 | `…/skuData.vue:142` | `'putawayLocation': 'Putaway Location'` in the `field-names` map | **YES — relabel to `'Default Putaway Location'`** per the ticket's exact wording | B1 |
| 60 | `…/skuData.vue:184-193` | `headers` array — no putaway column | **no — Q4 answered NO COLUMN** (§10) | — |
| 61 | `…/skuData.vue:303-307` | `showDetails` → `getSkuDetail` — **always refetches**, no caching | **YES — the fresh-read path; the dialog reuses it** | B1 |
| 62 | **NEW** `components/masterData/material/skuData/editSkuPutawayDialog.vue` | the SKU edit surface | **YES — 2643's primary UI deliverable** | B2 |
| 63 | **NEW** `components/masterData/material/skuData/putawayWording.js` | shared `DEFAULT_PUTAWAY_LANE_NAME` / `_LABEL` extracted from 2731 | **YES — §3.6; prevents a third copy** | B1 |
| 64 | `store/masterData/skuData.js:88-94` | `getSkuDetail` → `GET /itemData/itemdataDetailsById/{id}` | **YES — consumes the widened payload; re-dispatched after a write** | B1 |
| 65 | `store/masterData/skuData.js:46-95` | actions block — `getSkuData` (`:46`), `searchSkuData` (`:63`), `getSkuDetail` (`:88`). **Zero write actions exist in this store** | ⚠ **SUPERSEDED — the write did NOT land here.** r7 §3.8 deliverable 3 puts it in `store/admin/configuration.js` as **`setSkuPutawayDestination`**, beside its tier-2/tier-3 siblings, because "tier 1 living in a different module is how the three drift". This row was never reconciled to r7; it is stale, not a miss. **This store still has zero write actions** | B2 |
| 66 | **NEW** store action reading `effectivePutawayDestination` | the "effective default when no override" AC | ⚠ **VERIFIED IN SUBSTANCE, name/location stale for the same r7 reason.** Shipped as **`getSkuEffectivePutawayDestination`** in `store/admin/configuration.js` | B2 |
| 67 | `components/common/fullDetails.vue:10-11` | `v-for="(value, name) in details"` + `v-if="excludeFields.indexOf(name) == -1"` | **YES — the BC mechanism; renders every unexcluded key.** Label falls through to `:14`'s `name.charAt(0).toUpperCase() + name.slice(1)` | B1 |
| 68 | `components/common/fullDetails.vue:26` | `<slot name="actions">` inside `v-card-actions` | **YES — the clean Edit-button host. Zero changes to `fullDetails.vue` required** | B1 |
| 69 | `components/common/skuInfo.vue:102-105` | explicit `reportDetail.putawayLocation` row | **YES — audit only, expected no-change.** BC-safe: field-explicit, no key iteration (§6.2) | B1 |
| 70 | `store/masterData/storageLocation.js:50-58` | `getStorageLocations` → `$get('/location/detailView')`, **no params** | **YES as evidence, NO as a change target** — D3 keeps this endpoint untouched | A3 |
| 71 | `components/common/LocationPicker.vue` | the tiered picker | no — owned by SBDEV-2732 §3.11.2 Step 19. **2643 consumes it** (Q7 → strict reuse) |
| 72 | `components/masterData/location/fixedLocations/moveFixedLocation.vue:13` | bare `<v-autocomplete :items="items">` — the naive precedent | **YES as reference only** — insufficient for AC3 "searchable + meaningful info" | B2 |
| 73 | `components/receiving/open/receive/receivingForm.vue:14-24, 215-222, 296-314` | 2731's configured-vs-default wording: comment `:215-220`, `DEFAULT_PUTAWAY_LANE_NAME='PutAwayLane'` `:221`, `DEFAULT_PUTAWAY_LANE_LABEL='Put Away Lane'` `:222`, `isPutawayDestinationApplied` `:296-300`, `isPutawayOverride` `:301-305`, `putawayDisplay` `:309-314` | **YES — 2643 MUST reuse these, not invent new wording** (§3.6) | B1 |
| 74 | `store/index.js:5-6, 24-28` | `affiliatedGroups: []` / `affiliatedGroupsStr: ''` + their two mutations — **set, never read for gating** | **YES — the only material for the UI permission gate** | B1 |
| 75 | `store/index.js:3, 19-21, 92-101, 103-117` | `isWmsUser`; `getUserRoles`; `getAffiliatedGroupsByUsername` — roles are **already fetched** | **YES — the data is there; only the gate is missing** | B1 |
| 76 | `nuxt.config.js:167` | `appAdminGroup: process.env.APP_ADMIN_GROUP \|\| '/wms/wh/wms_admin'` — **read nowhere, and DEAD: WMS V2 does not use it any more (r6)** | **NO.** 2643 must not consume it. ⚠ **r7 CORRECTS r6's replacement too:** the gate is **`resolveSbAdmin` from `util/keycloakRoles.js`** (2732-shipped), not `$kc.hasResourceRole(...)`. ~~"The load-bearing row is now `nuxt.config.js:162` (`keycloak.clientId` ← `KEYCLOAK_CLIENT`)"~~ — **`nuxt.config.js` is NOT load-bearing for this gate at all**: `sb_admin` rides the `groups` claim, so no client id is consulted (§3.11) | B1 |
| 77 | `layouts/default.vue:467` | `console.log("affiliatedGroupsStr ", …)` — the **only** read of the gating material in the entire app, and it is a log statement | **YES — proof there is no gating framework (§3.7)** | B1 |
| 78 | `plugins/persistedState.client.js:26-29` | reducer `({ warehouseTimezone, selectedWarehouse, warehouses, ...persisted }) => persisted` ⇒ `masterData.skuData` **IS** persisted to `localStorage['vuex-web']` (F3) | **YES — AC5 hazard.** Mitigated by Q4's no-column decision + the overlay's unconditional refetch at `skuData.vue:304` | B1 |
| 79 | `components/masterData/material/packaging/editPackagingDialog.vue` (196 L) + `packaging.vue:91-94, 122-127, 161, 170, 294` | the **only** masterData create/edit dialog in the repo, and a sibling of the SKU screen | **YES — the idiom to copy** (§3.5) | B2 |
| 80 | `store/masterData/packaging.js:99-113` (`createPackaging`) / `:114-128` (`editPackaging`) | the write-action idiom: `try` → `results.errors` → `$toast` → `catch` → `context.dispatch(...)` | **YES — the store idiom to copy, with 3 deliberate deviations** (§3.4) | B2 |
| 81 | 12 components calling `itemdataDetailsByNumberAndClientNumber`, all feeding `components/common/skuInfo.vue` | BC blast radius — enumerated in §6.2 | **YES — audit, expected no-change** | B1 |
| 82 | `components/internalOps/cycleCount/planned/create/createCycleCountSkuTable.vue:166`, `components/receiving/open/create/createPurchaseOrderSkuTable.vue:290` | the other two `itemdataDetailsById` consumers | **YES — audit** | B1 |
| 83 | `test/` — 16 Jest specs, **no `skuData` spec** | test surface | **YES — 3 new specs (§7.2)** | B1/B2 |
| 84 | `pages/masterData/strategies/sku-data-nam.vue`, `static/fakeSKUData.json` | stray scratch page + fixture with putaway refs | **out** — dead scratch artifacts, not menu-reachable. **Do not edit** | — |
| 85 | `components/putaway/storePallet.vue` (mobile UI) | mobile putaway | **out** — `wms2-mobile-ui` is out of scope (2732 §0.2 row 46, §8.4) | — |
| 86 | `controller/PutawayConfigController.java:92-97` (`eligibleLocations`) | takes only `scope`, `subjectId`, `Pageable` — **no name/search parameter**, though 2732's Q2 close assigned one to 2643 | **YES — A4 adds `@RequestParam(required = false) String name`** (§3.5a). ⚠ **2732-owned file** | A4 |
| 87 | `service/PutawayDestinationQueryService.java:214` (`eligibleLocations`) | the paginated candidate read behind that endpoint | **YES — A4 adds a 4-arg overload taking `name` and BRANCHES to the filtered query on a non-blank term**; the 3-arg form is kept as a delegate, so 2732's 8 merged behavioural tests keep driving the signature they were written against. ⚠ **2732-owned file; serves WAREHOUSE + MERCHANT too** | A4 |
| 88 | `store/admin/configuration.js` (`getEligiblePutawayLocations`) | loops pages at `size=200` until exhausted — **2,564 candidates on wineco-dev = 13 sequential round-trips** | **YES — passes the debounced term and stops accumulating when a search is active.** ⚠ **MOVED A4 → B2 (2026-08-12):** A4's PR is API-only. This is a `wms2-web-ui` file whose only consumer is B2's search box, and shipping a reader for a UI that does not exist yet is untestable dead code | **B2** |
| **89** | **`repo/jpa/LocationRepository.java:277-283`** (`findPutawayCandidates`) — ⚠ **ADDED 2026-08-12; A4's third API file, absent from §0 as planned** | the candidate query the picker pages through. **2732-owned** | **YES, but by ADDITION ONLY — this method is left byte-identical.** A4 appends a sibling `findPutawayCandidatesByName(excludedLaneName, nameFilter, Pageable)` carrying the `LOWER(…) LIKE LOWER(CONCAT('%', :nameFilter, '%'))` predicate, and the service branches between them. That the *existing* query is untouched is the whole R11 guarantee (§3.5a's implementation box); verify row `A4-split` asserts it | A4 |

---

## 1. Problem Statement

### 1.1 The requester's framing

Scott Dalton, via SBDEV-2643 (child of SBDEV-1938): warehouse operators need to designate a
**Default Putaway Location** per SKU, so that SKUs which always live in one known place — the worked
example is a **System-Client Ice Pack SKU in the HMG warehouse** — are received directly there instead
of routing through the generic Put Away Lane. The ticket asks for this to be settable *"in the
appropriate SKU edit or warehouse-configuration interface"*, with a searchable location selector,
a way to clear back to standard behaviour, and an audit trail. It carries **12 acceptance criteria**
(mapped 1:1 in §13) and an explicit **"Receiving Behavior Boundary"** section deferring what receiving
*does* with the value to a separate ticket.

### 1.2 The verified current state — two facts that reframe the ticket

**(a) The value is DB-only configurable today.** There is no UI to set it. `skuData.vue` displays
`putawayLocation` read-only (`:142`) and its create/edit block has been **commented out** since before
this ticket (`:100-123`). Consequence, measured on hydra/nywh DEV 2026-08-07: **2,720 of 2,720 SKUs
point at exactly one destination** — `count(DISTINCT putawaylocation_id) = 1`, the `PutAwayLane`
(id 50155). The feature is not merely unconfigurable; it has never been configured. On PRD, SBDEV-2731
records exactly **one** SKU warehouse-wide with a non-`PutAwayLane` destination (the ICE PACK SKU) —
and that one value is invalid, which is what filed 2731.

**(b) The one live write path is an unvalidated, unauthorized `@GetMapping`.** Verified at
`ItemDataController.java:79-95`:

```java
// Request Json: { itemDataId, locationId }
@CacheEvict(value = "itemdata", allEntries = true)                      // :80  flushes EVERY tenant
@GetMapping(path = "/setPutAwayLocation/{itemdataid}/{locationid}",     // :81  GET that mutates state,
            consumes = "application/json", produces = "application/json")  //     with a nonsensical `consumes`
public ResponseEntity<Object> setPutAwayLocation(@PathVariable("itemdataid") Long itemDataId,
                                                 @PathVariable("locationid") Long locationId,
                                                 @AuthenticationPrincipal Principal principal) … {
    LOG.debug("start with itemData={} location={}", itemDataId, locationId);
    Itemdata itemData = itemdataService.getById(itemDataId);            // :89  @Cacheable — mutated in place
    itemData.setPutawaylocationId(locationId);                          // :90  zero validation
    Itemdata newItemData = itemdataRepository.save(itemData);           // :91  raw save
    LOG.debug("end.  changed putaway location in itemData={} from oldLocation={} to newLocation={}",
              itemData, itemData.getPutawaylocationId(), locationId);   // :93  logs the NEW value as `oldLocation`
    return ResponseEntity.ok(newItemData);
}
```

Every clause is a defect:

| Line | Defect | Consequence |
|---|---|---|
| `:80` | `allEntries = true` on the `itemdata` cache | one SKU write flushes every tenant's `itemdata` cache |
| `:81` | `@GetMapping` mutates state; `consumes = "application/json"` on a body-less GET | not idempotent-by-verb; CSRF-reachable; the `consumes` clause is meaningless |
| `:83-85` | no `@PreAuthorize`. `ItemDataController extends AdminController` (`:34`) but `AdminController:31` carries only `@RequestMapping("/v3")` — **no class-level authorization** | `SecurityConfiguration.java:143` gates `/v3/**` on `hasAnyAuthority("wms_user")`, so **any warehouse user can repoint any SKU to any location id** |
| `:89` | `itemdataService.getById` is `@Cacheable` (`ItemdataService.java:47`) | the cached instance is mutated in place before eviction fires |
| `:90` | no existence check, no compatibility check, no lane check, no lock check | a nonexistent or hostile location id is accepted verbatim. **This is where SBDEV-2731's invalid ICE PACK configuration came from** (2732 §10.5) |
| `:91` | raw repository `save()`, no `@Transactional` anywhere under `controller/` | no audit row, no metric, no rollback semantics |
| `:93` | `itemData.getPutawaylocationId()` is read *after* `:90` mutated it | the debug line renders the **new** id twice — actively misleads anyone debugging a putaway config |

And the one service method that *would* have validated, `ItemdataService.setPutAwayLocation`
(`:68-76`), has **zero production callers** — the only other `src/main` reference is a Javadoc mention
at `IdempotencyFilter.java:262`. It is also broken for the case that matters: `:71` does
`locationRepository.findById(itemData.getPutawaylocationId()).orElseThrow(...)`, and `findById(null)`
raises `InvalidDataAccessApiUsageException`, so it blows up on a first-time set.

### 1.3 What this plan is, and is not

SBDEV-2732 already owns the repair of every row in that table. **This plan does not re-fix them.** It
builds the operator-facing surface on top, plus the five API pieces 2732's design does not define
(§3, D-A…D-F). Its central risk is therefore not technical difficulty — it is that **every contract it
consumes is on unwritten code** (§11.0, R5).

### 1.4 The scope limitation, stated up front

2732 §3.4c/§3.5a make a pick-face destination a **422 at all three scopes** (P2.7(c)) — `:722`
*"absolute at all three scopes — tier 1 included"*, `:792-795` *"Tier 1 (SKU) is exempt from (a), (b)
and (d) — **but NOT from (c)**, deliberately"*, and 2732 ships the unit test that enforces it
(`skuWriteRejectsPickFaceDestination`, `:2211`). Measured 2026-08-07 on hydra/nywh DEV: **all 496
flowbins in the warehouse are in a `useforpicking` area**, and SBDEV-2731's PRD evidence records the
reported ICE PACK location (id 52075) as `type_id = 2` = `flowbin`.

**Consequence, and it is the most important sentence in this plan: 2643 ships a picker offering 92
locations, and the ICE PACK location the ticket names as its worked example is not one of them.**
That is not a defect in 2643 and not a divergence from 2732 — it is **correct sequencing**. 2732
`:722` already assigns tier-1 pick-face relaxation to **[SBDEV-2821](https://app.clickup.com/t/868km8j9z)**,
alongside P2.5. Until 2821 lands, a SKU-scope pick-face configuration **cannot be written by any
client**, 2643 included; a picker that offered them would offer rows whose selection 422s.

> [!warning] **⚠ r7 — THE PARAGRAPH ABOVE AND THE ONE BELOW ARE r2-ERA AND NO LONGER TRUE.**
> "Until 2821 lands, a SKU-scope pick-face configuration cannot be written by any client" — **SBDEV-2821
> LANDED on 2026-08-09** (PR #135, merge `fd90487`), and **D1 was re-reversed in r3** so the picker
> *does* offer pick faces. Read §10.1's **D1** row and §3.8.2a for the live position; this passage
> survives only because §1.4 records the scope reasoning as it stood at r2.

**What 2643 owes the operator is legibility** — and r7 restates what that means now that pick faces
*are* selectable. The banner no longer explains an absence; it explains a **deferral in placement**: a
pick-face destination is **routed via putaway** rather than placed at receipt, so the stock is not on the
face when the receipt closes. §10.1 **D1** records the decision; §9.1 records the option that was
rejected and why. A reviewer who reads nothing else should read D1.

---

## 2. Current Architecture

The "is" state, with DB evidence inline. All reads SELECT-only against `wms2-hydra-dev2`
(= `wh01_hydra_v2` = HMG/nywh DEV) on 2026-08-07.

### 2.1 The data model

| Aspect | Evidence | Value |
|---|---|---|
| the column | `V2.2.00__base_v2_schema.sql:951`; FK `:5686-5690`; index `:4468-4471` | `itemdata.putawaylocation_id bigint NOT NULL` |
| nullability, live | `information_schema.columns` | `is_nullable = NO` — **AC4 is hard-blocked until 2732's `V2.2.13 DROP NOT NULL`** |
| the entity | `Itemdata.java:49-51` | `@NotNull` / `@Column(name="putawaylocation_id")` / `Long putawaylocationId`. **Verified in code, not inferred from 2732's plan** |
| configured values | `SELECT count(*), count(DISTINCT putawaylocation_id) FROM itemdata` | **2,720 SKUs → 1 distinct destination**, id 50155 `PutAwayLane`. `count(*) WHERE putawaylocation_id IS NULL` = **0** |
| tier-4 resolution | `LocationRepository.java:21-22` `findByName` | no `client_id` filter, and `location.name` has no unique constraint |
| the constant | `WmsConstants.java:771` | `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"` |
| **there is no `location.active`** | `information_schema.columns` count = **0**; `Location.java:32-41` has only the 5 lane booleans (`staginglane` `:33`, `transferlane` `:35`, `automationlane` `:37`, `crossdockinglane` `:39`, `gate` `:41`) | **AC6's "active" and "shipping lane" name columns that do not exist.** §3.9 records the reinterpretation |
| **there is no location "code"** | `Location.java:10-41` has `name` only; `getLocationView()` exposes `locationName` + `areaName` + `locationType` | **AC3's `CODE — Human Name` rendering is unimplementable as specified.** §3.9 records the substitute |
| location-type column | `information_schema` | the column is **`location_type.sltname`**, not `name` |
| audit | `information_schema.tables` count for `putaway_config_audit` = **0** | **AC9 is hard-blocked** on 2732 |
| facility scope | one DB per facility (2732 §2.4) | **AC7 is structurally satisfied** — assert as an invariant, do not build for it |

### 2.2 The location inventory — and why the picker's eligible set is the crux

666 locations. Under 2732's SKU-scope predicate set:

| Filter | Count | Predicate |
|---|---|---|
| all locations | 666 | — |
| `entity_lock = 0` | 666 | P2.2 |
| no lane flag TRUE | 644 | P2.3 (rejects 22) |
| `useforgoodsin OR useforstorage` (area flags) | 603 | P2.4 — **OR, not AND** |
| in a `useforpicking` area | **511** | P2.7(c) **rejects all 511** |
| fix-assigned (`fix_location_assignment.assignedlocation_id`) | **154** | P2.5 **rejects all 154** |
| **SKU-scope eligible under 2732 verbatim** | **92 (13.8%)** | all predicates |

By `location_type.sltname`:

| `sltname` | count | in a `useforpicking` area | fix-assigned |
|---|---|---|---|
| **flowbin** | **496** | **496 (100%)** | 154 |
| overstock pallet | 104 | 3 | 0 |
| NoRestriction | 36 | 0 | 0 |
| overstock box | 14 | 12 | 0 |
| cases and pallets | 13 | 0 | 0 |
| totes | 2 | 0 | 0 |
| packages | 1 | 0 | 0 |

Two conclusions:

1. **`useforpicking` is the single most aggressive filter** — 511 of 666 — and it eliminates **every
   flowbin**, i.e. every pick face, i.e. the class of location the ticket's own worked example names.
2. **A preloaded, client-side-filtered picker scales fine at 666 rows.** 2732's Q2 ("does a preloaded
   picker scale?") is answered NO-PROBLEM for this tenant. AC3's "searchable" therefore needs a search
   *box*, not a server-search endpoint — but D3 still puts **predicate evaluation** server-side, for a
   different reason (single source of truth), not for scale.

Also measured: `PutAwayLane` itself (id 50155) is `entity_lock=0`, `type_id=50057`
(`sltname='cases and pallets'`), area `Inbound`, `useforgoodsin=TRUE`, `useforstorage=FALSE`,
`useforpicking=FALSE`, all 5 lane flags FALSE, 0 FLA rows — so **the tier-4 fallback passes every
SKU-scope predicate and is legally selectable.** After `V2.2.13`, "pin this SKU to `PutAwayLane`" and
"clear the override" produce identical receiving behaviour but different configurations. §3.5 / Q3
resolve the ambiguity by excluding it from the picker.

### 2.3 The read path

`ItemdataService.getItemdataDetails(Long)` (`:119-174`) — verified 2026-08-07:

```java
public Map<String, Object> getItemdataDetails(Long id) {                 // :119  NO @Transactional
    Itemdata i = itemdataRepository.findById(id).orElseThrow(...);       // :120  repo, NOT the @Cacheable getById
    Map<String, Object> details = new HashMap<>();
    …
    if (i.getPutawaylocationId() != null) {                             // :166
        Optional<Location> location = locationRepository.findById(...);  // :167
        if (location.isPresent()) {                                     // :168
            details.put("putawayLocation", location.get().getName());    // :169  NAME ONLY — no id
        }
    }
    return details;
}
```

Three properties matter downstream:

- **No id in the payload.** No picker can pre-select the current value. This is D-C, the single
  smallest change that unblocks the whole UI.
- **Double-guarded omission.** The key is absent when the id is NULL (`:166`) *and* when the FK dangles
  (`:168`). Today those are indistinguishable to a client — and `ItemdataServiceUnitTest.java:498`
  **enforces** the ambiguity. After `V2.2.13` makes NULL the normal state, "inherit" and "broken"
  must be distinguishable, or **AC8 is unimplementable**. §3.3.
- **`findById`, not `getById`.** The details read bypasses the Caffeine `itemdata` cache entirely, so
  2643's own display is always fresh even under Caffeine — a real advantage over 2732 §7.6 row 9's
  accepted staleness. §7.4 row 5/9 assert it so a future "optimisation" to `getById` cannot break it.
  It also means `getItemdataDetails` must **not** host the resolver call: it has no transaction
  (`ItemdataService.java:15` is a bare `@Service`) and 2732's resolver is `Propagation.MANDATORY` (F5).

### 2.4 The location list the picker would naturally use — and why it cannot work

`ViewDtoService.getLocationView()` (`:806-832`), served by `LocationController.java:47-49` at
`GET /v3/location/detailView`, read by `store/masterData/storageLocation.js:51` with no params.
It returns exactly 8 fields:

`id` `:815` · `locationName` `:816` · `clientNumber` `:817` · `clientName` `:818` · `areaName` `:819` ·
`locationType` (= `getSltname()`) `:820` · `created` `:821` · `modified` `:822`

**No lane flags. No `type_id`. No `usefor*`. No `entity_lock`. No FLA marker.** So 2732 §3.11.2's
mandated *client-side P2.4 filter over `/location/detailView`* **cannot be implemented against the
endpoint it names** — and 2732's own Step 19 is blocked identically. D3 resolves this with a dedicated
server-side endpoint rather than widening a payload four other screens consume.

### 2.5 The write surface, the auth surface, and the test surface

- **Write:** §1.2. One unvalidated `@GetMapping`, plus five other seeders
  (`SkuRestController` ×4, `FileImportController`, `SkuBatchCreateUpdateService`) that all 2732 owns.
- **Auth:** `SecurityConfiguration.java:143` — `/v3/**` requires only `hasAnyAuthority("wms_user")`.
  Method-level authorization is wired (`MethodSecurityConfig.java:9-18`,
  `CustomMethodSecurityExpressionHandler.java:15-23`) and the custom root defines exactly one admin
  predicate, `isAimAdmin()` at `CustomMethodSecurityExpressionRoot.java:77`. But
  `Authority.java:14` **used to read** `IS_SB_ADMIN = "isSbAdmin()";  // legacy` — a method that existed
  nowhere in `src/main` or `src/test` (F1). **FIXED by SBDEV-2863 `675b4a1` on 2026-08-07:
  `Authority.java:44` now renders `hasAuthority('sb_admin')`, and the same commit added the
  SpEL-evaluation test.** §3.1 is retained as history only — see revision 5 at the top.
- **UI auth:** none. An exhaustive grep for
  `APP_ADMIN_GROUP|affiliatedGroups|isAdmin|isSbAdmin|adminGroup|wms_admin|hasRole|realmAccess|resourceAccess`
  over `*.vue` + `*.js` returns **6 lines total** (rows 74–77 in §0.3), of which the only *read* is a
  `console.log`. There is no `isAdmin` computed, no mixin, no route middleware, no role `v-if`
  anywhere. **2643 builds the first gate in the app.** §3.7.
  ⚠ **r7 SUPERSEDES r6 HERE — and "2643 builds the first gate in the app" is now FALSE.**
  **SBDEV-2732 built it first**: `util/keycloakRoles.js` (+ `test/util/keycloakRoles.spec.js`) and its
  consumer `defaultPutawayLocationField.vue` are on develop, so the app already has exactly one role
  gate and 2643 **extends** it to a second screen rather than inventing one. The token list should
  therefore include **`resolveSbAdmin` / `extractWmsRoles` / `hasWmsRole`** — the forms that now exist —
  and `hasResourceRole` stays only to catch a **reintroduction** of the disproven form, not as the
  expected gate. ~~r6: "after B1 the gate is a `hasResourceRole` call"~~ — **it is not; see §3.11.**
  `APP_ADMIN_GROUP` likewise stays only to catch a reintroduction.
- **Tests:** `BaseControllerUnitTest.java:52-58` uses `MockMvcBuilders.standaloneSetup(...)` — no
  security filter chain, no method-security advisor — so **`@PreAuthorize` is never evaluated in any
  controller unit test** (F2). The `@SpringBootTest` lane is down (SBDEV-2217). AC12's "permission
  enforcement" is therefore **not automatable as a controller test**; it is proven by **SBDEV-2863's**
  SpEL-evaluation unit test (`@Nested AuthorityExpressionsResolve`, merged `675b4a1`) plus manual **M8**.
  *(Was "A0's" — A0 is retired, revision 5. F2 itself is unchanged and still stands.)* §7.

### 2.6 Flyway state

Head, swept across **all** remote branches (not `ls db/migration/`, per the recorded landmine):
**`V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop`** (SBDEV-2854, merged `68274b0`).
`V2.2.13` is 2732's. **2643 ships zero migrations**, so the whole Flyway-ordering hazard class
(out-of-order skip → `validateOnMigrate` boot failure → swallowed by `StartupFlywayMigrator`) does not
apply to this plan. Stale duplicate versions on abandoned branches (`V2.2.01`, `V2.2.02`, `V2.2.03`)
are pre-rebase artifacts — ignore them.

---

## 3. Design

> # ⛔ BLOCKING BANNER — READ BEFORE WRITING A TEST AGAINST ANYTHING IN §3
>
> **Every contract in §3.2, §3.4 and §3.5 is a NEGOTIATING POSITION, not a specification.** Each is
> marked `CONTRACT-PROVISIONAL` in its own heading. **Re-derive each one from SBDEV-2732's *merged PR*
> before writing a single test** (R5, §11.0).
>
> Why this is a banner and not a checklist bullet: 2732 is `status: draft`, and its own **D18**
> (`:103-106`) records that *"the 2026-08-04 revisions changed validator predicate semantics (P2.5,
> P2.7(c)) and have had no independent pass; the previous Critic pass returned 12 findings including a
> **CRITICAL** one."* 2732's §12 changelog shows P2.5 flipped and reverted the same day, and P2.7(c)
> becoming implementable only on 2026-08-06. §10.3 records **ten** defects found in 2732 while verifying
> these contracts, one of which (C4) is in the row that scopes this entire ticket, and two of which
> (C10) are 2732 contradicting itself on the exact rule §3.5 depends on.
>
> An implementer with no memory of this session must not read §3.4's code block as settled API.

Six API/UI deliverables (**D-A … D-F**) plus the SKU edit surface. Each subsection states the contract,
the phase, and the 2732 dependency. **Nothing here changes `ReceivingService`, and nothing here ships
SQL.** The five principles §3 is designed against are stated in **§14**.

### 3.1 D-E — repair `Authority.IS_SB_ADMIN` — ~~Phase A0~~ **RETIRED, DELIVERED BY SBDEV-2863**

> [!done] **This entire subsection is HISTORICAL as of 2026-08-09. Do not implement any of it.**
>
> [SBDEV-2863](https://app.clickup.com/t/868knmx18) merged 2026-08-07 (PR #134, `675b4a1` + `d8e0137`,
> merge `7d9d38e`) and shipped **both** the repair and the detector — see revision 5 at the top of this
> plan. On `origin/develop` today:
>
> - `Authority.java:44` = `IS_SB_ADMIN = "hasAuthority('" + SB_ADMIN_ROLE + "')"`, with a doc comment
>   recording that `ded4d644` (2025-10-29) renamed `IS_AIM_ADMIN`/`isAimAdmin()` to
>   `IS_SB_ADMIN`/`isSbAdmin()` but left the root's method named `isAimAdmin()` — i.e. the expression
>   **worked before that rename**, which this plan did not know.
> - `CustomMethodSecurityExpressionRootUnitTest` carries `@Nested AuthorityExpressionsResolve`, which
>   evaluates the constant through the real handler. **A0's detector would now be a duplicate.**
>
> The text below is kept because it is the analysis that produced the ticket, and because the rejected
> alternatives explain why 2863's chosen fix is the right one — 2863 took option (1). **Nothing here is
> a deliverable of this plan.**

**Problem (as it stood 2026-08-07, now fixed).** `Authority.java:14` then read:

```java
public static final String IS_SB_ADMIN = "isSbAdmin()";  // legacy
```

SpEL resolves `isSbAdmin()` reflectively against the method-security expression root. The root is
`CustomMethodSecurityExpressionRoot` (`:11`), wired via `CustomMethodSecurityExpressionHandler:15-23`
and `MethodSecurityConfig:13-18`. Its **only** admin predicate is `isAimAdmin()` at `:77`. An
exhaustive grep for `isSbAdmin` across `src/main` and `src/test` returns exactly one hit —
`Authority.java:14` itself. So evaluation raises
`SpelEvaluationException: EL1004E: Method call: Method isSbAdmin() cannot be found on type
CustomMethodSecurityExpressionRoot` → **HTTP 500, not 403**, for **every caller including a genuine
`sb_admin`**.

**Live blast radius today:** `AdminController.java:80, 108, 121, 134, 143, 155, 176, 194` (8 user/group
admin endpoints) and `ReplenishmentReconciliationController.java:37`. Nine endpoints are dead.
Separately ticketed as **[SBDEV-2863](https://app.clickup.com/t/868knmx18)**.

**Why it is 2643's problem.** 2732 §3.12 mandates `@PreAuthorize(Authority.IS_SB_ADMIN)` on
`PutawayConfigController`'s three writes **and** on `PutawayConfigService`'s writers plus
`validateOnly`, calling it *"the pattern used throughout `AdminController`"*. If 2643 adopts the
constant as-is, **every SKU putaway write returns 500** — and AC12's permission test would be
asserting against a broken expression.

**Fix (D2, option (c)) — the correct expression is:**

```java
@PreAuthorize(Authority.getExpForRole(Authority.SB_ADMIN_ROLE))   // → "hasAuthority('sb_admin')"
```

`Authority.java:19` defines `SB_ADMIN_ROLE = "sb_admin"` and `:24` `getExpForRole(String)` renders
`hasAuthority('<role>')`. This is safe with **no** `ROLE_` prefix because
`CustomMethodSecurityExpressionHandler.java:19` calls `root.setDefaultRolePrefix(null)`. It touches no
shared security wiring and needs no custom root at all.

> **⚖ r2 SCOPE CHANGE — 2643 does NOT apply that swap. It ships the DETECTOR and the FINDING.**
>
> r1 had A0 (later A2) edit `@PreAuthorize(Authority.IS_SB_ADMIN)` → `getExpForRole(...)` inside
> **`PutawayConfigService.java` and `PutawayConfigController.java`** — 2732's own files, on lines 2732
> deliberately writes (2732 §3.5 `:905, 917, 925`, §3.9 `:1491`, §3.5a `:972, 978, 985`, all citing its
> §3.12 as *"the authorization boundary"*).
>
> **A 2643 PR reverting a security annotation that a 2732 PR deliberately added, days later, in 2732's
> own file, is the wrong home for the change** — whatever its merits. It is not a stacked consumer edit;
> it is a cross-plan security reversal, and it would land after 2732's review approved the annotation.
>
> **Correct homes, in order of preference:** (1) a one-token review comment on 2732's PR *before it
> merges*; (2) **[SBDEV-2863](https://app.clickup.com/t/868knmx18)**, which already owns the constant.
> 2643 carries a **blocking prerequisite row** (§5.1 row 0e: *"2732 must not merge with
> `Authority.IS_SB_ADMIN`"*) and a **prerequisite probe** in the verify script (`X-2732-authz`) that
> FAILS if 2732's file lands still carrying the broken constant. The probe is labelled a prerequisite,
> never a 2643 deliverable.
>
> **⚠ r5 (2026-08-09): the probe was DELETED, and it was not merely stale.** With the constant repaired
> by SBDEV-2863, `PutawayConfigService` carrying `@PreAuthorize(Authority.IS_SB_ADMIN)` is **correct** —
> so `X-2732-authz`, which asserted that line's *absence*, would have failed a correct SBDEV-2732 and
> been read as "2732 must not merge". It is replaced by `X-authz-constant`, a regression guard on
> `Authority.java` itself. **Row 0e is discharged; this box's ownership argument stands but is now moot.**
>
> **What 2643 keeps is the higher-value half.** The detector below is the artefact that protects a third
> party — without it, 2732 §3.12 builds a new security boundary on a constant that 500s for everyone,
> and no existing test can see it.

**Two alternatives were considered and rejected for A0's scope:** (a) add an `isSbAdmin()` alias to
`CustomMethodSecurityExpressionRoot` — changes shared security wiring on a plan that has no business
doing so; (b) repoint `Authority.IS_SB_ADMIN` at `"isAimAdmin()"` — silently changes the semantics of
9 unrelated endpoints from "sb admin" to "aim admin". ~~**A0 ships the detector only; the expression fix
belongs to 2732's review or SBDEV-2863, and the repair of the 9 broken endpoints is SBDEV-2863's.**~~
**SUPERSEDED — SBDEV-2863 shipped the detector *and* the fix, taking option (1) as recommended, and
explicitly rejecting the alias (option (a)/(3)) for the reason given here. 2643 ships neither.**

**~~The detector is the deliverable, not the annotation.~~** *(Historical.)*
`CustomMethodSecurityExpressionRootUnitTest.java:170-206` tested `isAimAdmin()` **directly** and
therefore could not see this class of defect. A0 would have added a test that **evaluates the SpEL
string** — sketched below. **SBDEV-2863 added exactly this test, and more, in `675b4a1`; the sketch is
retained only to show the two are equivalent:**

```java
// unit/CustomMethodSecurityExpressionRootUnitTest.java — NEW @Nested class
@Test
@DisplayName("every Authority SpEL constant resolves against the expression root")
void authoritySpelConstantsResolve() {
    var root = new CustomMethodSecurityExpressionRoot(authentication);   // real root, not a mock
    var parser = new SpelExpressionParser();
    // A constant naming a method the root does not declare throws SpelEvaluationException here,
    // exactly as it does inside Spring Security's method-security advisor. A direct isAimAdmin()
    // call cannot catch this — the string is never parsed.
    assertThatCode(() -> parser.parseExpression(Authority.getExpForRole(Authority.SB_ADMIN_ROLE))
            .getValue(new StandardEvaluationContext(root), Boolean.class))
        .doesNotThrowAnyException();
}
```

~~Assert the **same** for whichever constant 2643's handlers actually carry. Do **not** assert
`Authority.IS_SB_ADMIN` resolves — it does not, and A0 is not fixing it.~~

**⚠ That last instruction is now exactly backwards, which is why this subsection is fenced off rather
than merely marked stale.** `Authority.IS_SB_ADMIN` **does** resolve on `origin/develop`, and 2863's
`AuthorityExpressionsResolve` asserts precisely that. Anyone implementing the paragraph above verbatim
today would write a test asserting the repaired constant is broken.

### 3.2 D-A — `SkuPutawayQueryService.describeForSku` (Phase A2, blocked on 2732 Phase 1-API)

> **`CONTRACT-PROVISIONAL` — re-derive from 2732's merged PR before writing tests.** The types
> (`Resolution`, `PutawayDestinationResolver`) and the `MANDATORY` propagation rule are 2732's and are
> `draft`. See §3's blocking banner.

2732 §3.1.5 defines exactly two facade methods — `describeForAdvicePosition(Long)` and
`describeForClient(Long)`. **There is no `describeForSku`.** That is 2643's genuine API gap: without
it, no SKU-scope caller can obtain a `Resolution`.

**r2 change — 2643 owns the file, not the method-on-someone-else's-class.** r1 added `describeForSku`
*into* `service/PutawayDestinationQueryService.java`, a file 2732 creates days earlier. The
`Propagation.MANDATORY` constraint (constraint 3 below) requires **a** `@Transactional` bean between the
controller and the resolver; **it does not require that bean to be 2732's file.** 2732 §3.1.5 (`:508-519`)
describes the facade as a holder of two sibling methods, not a registry. So D-A ships as **2643's own
class**:

```java
// service/SkuPutawayQueryService.java  — NEW, 2643-OWNED FILE
@Service
public class SkuPutawayQueryService {

    private final PutawayDestinationResolver putawayDestinationResolver;   // 2732's bean, injected
    private final ItemdataRepository itemdataRepository;

    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public Resolution describeForSku(Long itemdataId) throws BusinessException { … }
}
```

**Why this is strictly better, and it is not a style preference:**

| | r1 (method on 2732's class) | r2 (2643's own class) |
|---|---|---|
| merge surface | a three-way merge inside 2732's newest file | a compile-time dependency on two 2732 **types** |
| failure mode if 2732 reworks the facade on merge | textual conflict, or PM1's silent orphan | a compile error the build catches immediately |
| blast radius on 2732's review cycle | 2643's method must survive 2732's rewrites | none — 2732 never sees this file |
| cost | — | one class + one line of DI |

The counter-argument is cohesion: three `describeForX` methods in one place is more discoverable. Real,
but weaker than the conflict cost — §5.4 rated A2 **HIGH** risk principally *because* of that coupling
(R1, R2, §11.0), and this removes the reason.

**The negative check does not move.** `A2-neg-res` still asserts `putawayDestinationResolver`
appears nowhere in `ItemDataController.java` — the resolver moves into a *service*, never the
controller. That the check is shape-independent is evidence it was written against the right invariant.
A **new** negative row (`A2-neg-2732f`) asserts `describeForSku` does **not** appear in
`PutawayDestinationQueryService.java`, so the boundary is enforced rather than merely intended.

Three constraints, each load-bearing:

1. **`value = "tenantTransactionManager"` verbatim.** A bare `@Transactional` silently binds the
   `@Primary` **landlord** transaction manager. `unit/config/TransactionManagerArchTest.java` enforces
   this repo-wide; the verify script asserts the literal string as well.
2. **`readOnly = true`.** Required for symmetry with 2732's two sibling facade methods, and safe **only
   because** 2732 §3.4a reads tier 3 through `SyspropRepository` and never
   `SyspropService.getStringDefault` (which INSERTs at `SyspropService.java:234`). 2643 must not
   weaken that.
3. **It must supply the transaction the resolver demands.** `PutawayDestinationResolver.resolve(...)`
   is `Propagation.MANDATORY` (2732 §3.1.5) and there is **zero `@Transactional` anywhere under
   `controller/`** — the only three matches in the tree are comments. A `MANDATORY` call from a
   controller raises `IllegalTransactionStateException`, a bare `RuntimeException`, on **every** call →
   mapped to **500**. OSIV would not help and is off anyway
   (`application.properties:55` `spring.jpa.open-in-view=false`): it opens an `EntityManager`, never a
   transaction. **`describeForSku` must NOT be added to `ItemdataService`** either —
   `ItemdataService.java:15` is a bare `@Service` with no transaction annotation anywhere (F5).
   `SkuPutawayQueryService` exists **only** to be that transactional boundary; a `@Service` without the
   annotation would reproduce the F5 bug in a new file.

**No mocked unit test can prove this wiring** (a Mockito mock has no propagation semantics), so it is
enforced by the negative code-shape check **D-F** (§3.6) plus manual row **M8**.

### 3.3 D-C — `getItemdataDetails` gains `putawayLocationId` (Phase A1, **no 2732 dependency**)

> [!warning] **⚠ §3.3's TEST-CONSEQUENCES TABLE IS SUPERSEDED BY §8.0a. Recorded 2026-08-12 by the
> Phase-3a conformance lane, which traced a red verify row back to it.**
>
> This section prescribes edits to **four existing `ItemdataServiceUnitTest` methods** (`:415-428` gains
> a `containsEntry`; `:468-471` gains a key; `:498` "rewritten"; `:585-604` gains a `doesNotContainKey`).
> **That is not what shipped, and not what should ship.** §8.0a's PR-2 row endorses a new
> `@Nested PutawayLocationIdInDetails` class instead, which is what the TDD gate wrote and what PR 2
> carries — appending leaves the four existing tests untouched and independently meaningful, rather than
> editing four assertions to prove one new key.
>
> **It cost something to leave stale.** Verify row `A1-t2` was written against this section's
> `containsKey` phrasing for the "rewritten `:498`". The shipped test asserts the strictly stronger
> `containsEntry("putawayLocationId", 999L)`, so the row was **red against a better implementation** —
> and the tempting fix (swap `containsEntry` for `containsKey`) would have traded value coverage for a
> green light. The row was widened instead; see its comment in the verify script.
>
> ✅ **Safety of not editing the four:** `shouldHandleItemWithAllOptionalFields` (`:468`) uses
> AssertJ's `containsKeys`, a **subset** matcher, so a widened payload cannot break it — confirmed by
> the conformance lane, and by the 36-run/0-fail result on PR 2's branch.
>
> **Action for the next revision:** rewrite the table below as "append a `@Nested` class", or delete it
> and point at §8.0a. Do not re-prescribe the four edits.

The smallest change in the plan and the one that unblocks the whole UI.

```java
// service/ItemdataService.java — inside getItemdataDetails, replacing :166-171
if (i.getPutawaylocationId() != null) {
    // SBDEV-2643: emit the id UNCONDITIONALLY when non-null, even if the FK dangles.
    // The id present WITHOUT a name is the "configured but invalid" signal (AC8); the key
    // absent entirely is the "not configured / inherits" signal. Before this, both cases
    // omitted every key and were indistinguishable. (⚠ An earlier draft cited
    // ItemdataServiceUnitTest:498 as "pinning" that ambiguity — it does not; it asserts only
    // name-absence and stays green unchanged. See the §3.3 supersession box above.)
    details.put("putawayLocationId", i.getPutawaylocationId());
    // ⚠ AMENDED 2026-08-12 — was `.ifPresent(loc -> ...)`. AS SHIPPED this keeps the file's existing
    // `Optional<Location> location = ...; if(location.isPresent())` shape, and the code is right:
    // the three adjacent branches (:154, :159, :166) all use that form, so the ifPresent version
    // introduced local inconsistency and a gratuitously larger diff into a file watched by an
    // ArchUnit OptionalSafetyArchTest. Behaviourally identical; verify row A1-name pins the guard.
    Optional<Location> location = locationRepository.findById(i.getPutawaylocationId());
    if (location.isPresent()) {
        details.put("putawayLocation", location.get().getName());
    }
}
```

> [!note] **The comment inside this snippet is longer than what shipped, deliberately — do not paste it
> verbatim.** Code review cut the production comment to four lines: the asymmetry contract only. The
> AC1/AC8 narrative, the per-tenant SKU count, and the B1-pre deploy-ordering note were all removed —
> the first two belong in the plan and the PR body, and the third is a property of a *merge window*, not
> of a source file, so it becomes actively misleading once both PRs are on develop. It is recorded in
> §5.1 row 4, §6.1 and §8.0a, which are durable.

| SKU state | `putawayLocationId` | `putawayLocation` | UI reads it as |
|---|---|---|---|
| no override (post-`V2.2.13` normal) | absent | absent | *inherits the effective default* |
| override, FK resolves | present | present | *configured: `<name>`* |
| override, FK dangles | **present** | **absent** | **configured but INVALID — AC8** |

**Zero extra queries.** `putawaylocationId` is already on the entity loaded at `:120`; only a
`details.put` is added. **No behaviour change to the name key** — every existing consumer of
`putawayLocation` is untouched.

**Test consequences, all deliberate:**

| Test | Line | Action |
|---|---|---|
| `shouldIncludePutawayLocationWhenPresent` | `:415-428` | add `assertThat(details).containsEntry("putawayLocationId", <id>)` |
| `shouldHandleItemWithAllOptionalFields` | key list `:468-471` | add `"putawayLocationId"` |
| `shouldHandleMissingOptionalReferences` | assertion `:498` | **rewrite deliberately** — dangling FK now yields `containsKey("putawayLocationId")` **and** `doesNotContainKey("putawayLocation")`. This test encodes the AC8 ambiguity; changing it is the point |
| null-id case | assertion `:604` | **must stay green, and must also assert `doesNotContainKey("putawayLocationId")`** |

**The richer AC8 signal (`compatible` / `warning`) does NOT come from here.** It comes from D-B, so
precedence and compatibility logic stay in exactly one place. The details map stays dumb.

### 3.4 D-B — `GET /v3/itemData/{id}/effectivePutawayDestination` (Phase A2, blocked on 2732 Phase 1-API)

> **`CONTRACT-PROVISIONAL` — re-derive from 2732's merged PR before writing tests.** The `Resolution`
> shape, the `Source` enum names and the `compatible`/`warning` semantics are 2732's §3.8 and are
> `draft`. See §3's blocking banner.

2732's read inventory covers advice positions (N8) and clients (N9). No SKU-scope read exists.

```java
// controller/ItemDataController.java — delegates only; opens no transaction of its own
@GetMapping(path = "/{id}/effectivePutawayDestination", produces = "application/json")
public Map<String, Object> effectivePutawayDestination(@PathVariable("id") Long id,
                                                      @AuthenticationPrincipal Principal principal)
        throws BusinessException {
    // §3.2's SkuPutawayQueryService supplies the tenant transaction the MANDATORY resolver requires.
    return toEnvelope(skuPutawayQueryService.describeForSku(id));
}
```

**Envelope — 2732 §3.8's `Resolution` shape, 7 fields, unchanged:**

```
{ locationId, locationName, source, sourceLabel, configuredFor, compatible, warning }
```

| Field | Contract |
|---|---|
| `source` | **enum name**: `SKU_OVERRIDE` \| `MERCHANT_OVERRIDE` \| `WAREHOUSE_DEFAULT` \| `STANDARD_PUTAWAY_LANE` |
| `sourceLabel` | display string: `"SKU override"` \| `"Merchant default"` \| `"Warehouse default"` \| `"Standard putaway lane"` |
| `compatible` | **P1 reported without throwing** — this is what lets the UI warn *before* commit (AC8) |
| `warning` | the rendered `putawayDestinationNotPermitted` text when `compatible == false` |

2732 §3.8 is explicit: *"`source` is the enum name so Vue never re-derives the precedence."*
**2643 must not re-derive tiers in JavaScript.** The controller owns only the `Resolution` →
JSON mapping.

**Do not conflate this with 2732's `PutawayConfigPreview` envelope** (2732 §3.5a):
`{ locationId, locationName, compatible, incompatibleSkuCount, totalSkuCount, exampleIncompatibleSku, blockingReason }`.
Different shape, different purpose. At SKU scope the three count fields are degenerate (the subject
*is* one SKU). What the dialog wants from `preview` is `compatible` + `blockingReason` as the pre-Save
gate — **and 2732 does not state what `preview` returns for `scope=SKU`.** That is **Q2, still OPEN**
(§10). Until answered, B2 gates Save on the 422 response from the write itself, which always works.

**Security.** The endpoint lands under the existing `/v3/**` → `hasAnyAuthority("wms_user")` rule
(`SecurityConfiguration.java:143`). It is a **read**, so it is deliberately **not** admin-gated —
consistent with 2732's reasoning that `preview` reveals no more than the picker already shows, and
required by the ticket's *"read-only users may view the configured value"*. **2643 must not widen
`SecurityConfiguration`.**

**Constructor impact.** `ItemDataController`'s constructor is currently 11-arg
(`ItemDataControllerUnitTest.java:91-102`); adding `SkuPutawayQueryService` makes it 12 and
**breaks that test's construction**. Expect to touch `:91-102` — and see R2 (§11.0) on the collision with
2732 Step 9.

> [!danger] **⚠⚠ THE ENVELOPE ABOVE IS SUPERSEDED — §3.4 PREDATED (iv-b) AND SBDEV-2821. DECIDED
> 2026-08-12 (option (a)); see the box below for what shipped.**
>
> **The defect.** A bare `Resolution` made `compatible` disagree with **both** the writer and receiving.
> Confirmed on `wms2-wineco-dev`, not theorised: `ICEPACK` (225817) is a `flowbin` of type **51502**,
> whose `location_constraint` permits **only** unit-load type 1 (`PickLocation`), while `ICE PACK`
> (874400) has `defultype_id = 4` (Case). Three answers for one configuration:
>
> | Path | P1 treatment | Verdict |
> |---|---|---|
> | **Writer** `PutawayDestinationValidator:140` | `flowbin \|\| type==null \|\| isUnitloadTypePermitted(...)` — **flowbin exempt** | accepts |
> | **Receiving read** `ReceivingController:120` | verdict from the **placement**, after `divertPickFaceToLane` | `compatible: true` |
> | **A2's first cut** | `classify()` — P1 unguarded, no diversion | **`false` + a warning** |
>
> So the config screen would have warned "incompatible" about a configuration the writer accepts, the
> picker offers, and receiving handles correctly — **the SBDEV-2731 defect class in a new costume**, in
> the very method whose javadoc claimed immunity from it.
>
> **Decision: option (a) — mirror `describeForAdvicePosition`.** `describeForSku` now returns
> `PutawayDisplay(configured, placement)` and applies `divertPickFaceToLane` **unconditionally** (it
> no-ops on a non-pick-face, so a conditional call would be a second copy of the predicate). The
> envelope gains `divertedTo` / `divertedReason`, and **`compatible` + `warning` come from the
> PLACEMENT**. `locationName` stays the **configured** destination so the admin's setting remains
> visible — returning only the placement would make the screen look like it discarded the setting.
>
> **Consequence for B2:** §3.8.2a's always-visible static banner is no longer the only diversion signal.
> B2 can render a **per-SKU** sentence from `divertedReason` (resolved from `messages.properties`, so it
> matches the receive-time wording by construction) and show the banner only as general context. That is
> strictly better than a hardcoded banner and was not available when §3.8.2a was written.
>
> Regression-pinned at both layers, mutation-verified: `appliesTheSameDiversionReceivingDoes` (facade)
> and `divertedDestinationReportsPlacementCompatibilityAndNamesBoth` (envelope).
>
> ✅ **One consequence checked and cleared.** Applying the divert means `describeForSku` can now reach
> `locationRepository.findByName('PutAwayLane')`, so on a tenant lacking that row it would throw
> `entityNotFoundForName` — a new throw path on a read endpoint. **Verified 2026-08-12, SELECT-only: all
> four reachable tenants have exactly one `PutAwayLane` row** (`wms2-wineco-dev`, `wms2-hydra-dev2`,
> `wsl-wineco-uat`, `nywh-hydra-uat`). Receiving would already be broken on a tenant without it, so the
> risk is nil. No code change; recorded so the next reader does not re-derive it.
>
> ⚠ **A SECOND cross-controller literal duplicate came with this change** — the `PutAwayLane` →
> `"Put Away Lane"` mapping, inlined rather than reusing `ReceivingController.laneLabel` (a private
> static in a 2732-owned file, so reuse needs the boundary breach declined for `sourceLabel`). Unlike
> `sourceLabel` it has **no compile-time backstop** — a ternary on a string constant, not an exhaustive
> switch — so a one-sided rename would make the two screens narrate the same diversion differently,
> silently. Verify row **`A2-labels`** now pins `"Put Away Lane"` in both controllers and is
> negative-tested.

> [!warning] **⚠ TWO FURTHER CORRECTIONS FROM A2's IMPLEMENTATION (2026-08-12). The field NAMES above
> are right; presence was wrong.**
>
> **1. `warning` is OMITTED when compatible — it is NOT always present.** The first implementation
> documented "all seven keys always present" as a deliberate divergence from `ReceivingController`. That
> invariant is **unachievable in this application**: `Include.NON_NULL` is set app-wide
> (`WebConfigurer.java:79` and `:122`, plus `application.properties:14`), so a `LinkedHashMap` entry with
> a null value is dropped on the wire no matter what the mapper method puts in it. The endpoint returned
> **six** keys, behaving exactly like the envelope it claimed to differ from.
> The omission is now explicit in Java rather than left to Jackson, which makes the wire shape
> **independent of the serialization mapper** — load-bearing, because the test harness builds a bare
> `new ObjectMapper()` (`BaseControllerUnitTest:39`) that **keeps** nulls. Production and test therefore
> disagreed about the payload, and `jsonPath("$.warning").doesNotExist()` passed under **both**, so no
> jsonPath assertion in this harness could ever have caught it. The guard is now a raw-body assertion.
> ⚠ **And note the limit of `A2-env`:** it greps Java source, so it certifies the seven keys are
> **mapped**, never that they are **serialized**. That gap is precisely what hid this — the same
> "verify row, not a comment" failure §3.4 was written to close, reappearing one level down.
>
> **2. `sourceLabel` is a KNOWN DUPLICATE of an identical private static in 2732's
> `ReceivingController`.** Recorded here, not only in the code comment, so it survives that comment being
> deleted. The single-source-of-truth home is a `label()` method on `PutawayDestinationResolver.Source`,
> but that enum is 2732's and §14 principle 1 (r7) licenses editing 2732-owned files **only** where 2732
> assigned the work — it did for Phase A4, and did not for this. Duplicated and flagged rather than
> breached. Bounded risk: the switch is exhaustive over a 4-value enum with no `default`, so adding a
> fifth `Source` breaks **both** copies at compile time. The residual risk is a *relabel* diverging
> silently. **Consolidation candidate for whoever next owns `PutawayDestinationResolver`.**

**Envelope completeness is a verify row, not a comment.** `A2-env` asserts **all seven** keys —
`locationId`, `locationName`, `source`, `sourceLabel`, `configuredFor`, `compatible`, `warning`. r1's
row was named "7-field" and asserted four; a four-field envelope would have passed it while the UI
silently lost `source` (the field 2732 §3.8 exists to stop Vue re-deriving precedence) and `locationId`
(the field the picker pre-selects with).

**Negative constraints on the handler:** no `putawayDestinationResolver` (D-F), and no
`httpRestService` — a putaway-config read must never touch the OMS notification path
(`ItemDataController.java:97-98`). Both are verify rows.

### 3.5 D-D — `GET /v3/putawayConfig/eligibleLocations?scope=SKU` (specified here, **handed to 2732**; A3 is the fallback)

> **`CONTRACT-PROVISIONAL` — re-derive from 2732's merged PR before writing tests.** `PutawayScope`,
> `blockingReason` and `PutawayDestinationValidator` are 2732's and are `draft`. **And as of r2 this
> subsection is a specification handed to 2732, not a 2643 deliverable** — see the ownership box below.
> See §3's blocking banner.

**Decision D3: server-side predicate evaluation. Do NOT widen `getLocationView()`, and do NOT
re-implement predicates in Vue.**

> **⚖ OWNERSHIP (r2, resolves Q5 — D12).** **2732 owns D-D.** This subsection is a complete
> specification handed to 2732's author; **A3 is 2643's named fallback, not its plan of record.**
> Three grounds, and the first is decisive:
> 1. **2732's own picker cannot ship without it.** 2732 `:1605` mandates a client-side P2.4 filter over
>    `/location/detailView`, and `ViewDtoService.java:815-822` exposes **none** of the flags (§2.4).
>    2732's Step 19 (`:2036`) is blocked **identically**. The endpoint is on 2732's critical path whether
>    or not 2643 exists.
> 2. **Building it in 2643 inverts the dependency direction of the whole feature family** — 2732's
>    merchant and warehouse pickers would consume a 2643-owned endpoint.
> 3. **Robustness is *higher* if 2732 owns it.** If 2643 shipped D-D and 2732 later reshaped
>    `blockingReason` or `PutawayScope`, 2643 would own a broken endpoint inside someone else's
>    controller.
>
> **Decision deadline: before A3's TDD gate opens.** If 2732 declines, 2643 ships A3 as specified here
> (1.5 d). Recorded as **D12**; the acceptance item is §5.1 row 0d.
>
> **Consequence for the verify script:** 2643 cannot assert the shape of constructs it did not write. The
> `A3-*` rows are therefore split — **consumer** rows (the dialog sources its items from
> `eligibleLocations`; it does **not** call `/location/detailView` and does **not** re-implement
> predicates in JS) are asserted unconditionally against 2643's own files, and the **contract** rows run
> only once the endpoint exists at all, *whoever* shipped it.

```java
// controller/PutawayConfigController.java  (2732's class — ONE read, specified by 2643)
@GetMapping("/eligibleLocations")
@Transactional(value = "tenantTransactionManager", readOnly = true)
public List<Map<String, Object>> eligibleLocations(@RequestParam PutawayScope scope,
                                                   @RequestParam(required = false) Long subjectId)
        throws BusinessException;
// row: { locationId, locationName, areaName, locationType, eligible, blockingReason }
```

| Field | Contract |
|---|---|
| `locationName` / `areaName` / `locationType` | display material; `locationType` is `location_type.sltname` |
| `eligible` | `true` when the location passes **every** SKU-scope predicate, P2.7(c) included |
| `blockingReason` | 2732's enum **as 2732 defines it** — ⚠ **UPDATED 2026-08-11: that enum is now 7 values, not 3.** 2732's step 18a shipped `BOUND_TO_ANOTHER_SKU`, `AREA_NOT_USABLE`, `FLOWBIN_SCOPE` and `TYPE_INCOMPATIBLE` alongside the original `LOCKED \| FIX_ASSIGNED \| LANE \| null`, closing MUST-4. **Build the picker against `BOUND_TO_ANOTHER_SKU`, not `FIX_ASSIGNED`, for a flowbin bound elsewhere** — both rule-(f) keys were re-mapped, so `FIX_ASSIGNED` is no longer emitted for that case (it is retained but currently unreachable). Superseded text follows. **r2 removes r1's `PICK_FACE` extension**: with D1 reversed there is no 2643-specific class to name, and extending a 2732 enum from a 2643 PR was an undeclared cross-plan mutation (§15, MUST-4) |

**r2 also deletes r1's `advisory` field.** It existed only to carry the old D1's "offered with a
warning" class. With D1 reversed, a row is `eligible` or it is not offered; no third state exists, and
no 2643-specific field is added to a 2732-owned type. This restores §14's principle 2 without
qualification.

The predicate authority is **2732's `PutawayDestinationValidator`**, called from the server. The
endpoint reports its verdict; it does not re-derive it. A `PutawayScope` parameter is carried so the
same endpoint serves 2732's merchant/warehouse pickers — at SKU scope the response is:

| Class | Predicates | Offered? | Measured on hydra DEV |
|---|---|---|---|
| **eligible** | passes all — P2.2, P2.3, P2.4, P2.5 **and P2.7(c)** | **yes** | **92** |
| **not offered** | fails any predicate: P2.7(c) pick face (511), P2.5 fix-assigned (154), P2.3 lane (22), P2.4 area flags (63) | **no** — and the picker says *why*, see §3.8.2 | 574 distinct rows |

**Both P2.5 and P2.7(c) are absolute.** 2732 §3.4c calls P2.5 *"load-bearing for D15"* and `:722` says
the same of P2.7(c) — *"absolute at all three scopes, tier 1 included."* Relaxing either from a 2643 PR
would (a) fail 2732's `skuWriteRejectsFixAssignedLocation` / `skuWriteRejectsPickFaceDestination` tests
(`:2210-2211`) and (b) arm the over-bound-bin path SBDEV-2796/2821 own. **SBDEV-2821 relaxes them, for
tier 1, when it ships tier-1 placement** (2732 `:722`, `:711`).

**Tiering and the lock warning are inherited, not reinvented.** 2732 §3.11.2 requires the SKU picker to
carry the same two-tier shape (default = `useforgoodsin`; advanced = `useforstorage` behind a
**"Show storage locations"** toggle that reveals a lock-contention warning) — 2732 `:1607` says so
explicitly, and `:1605-1607` gives the reason. **This warning survives r2 unchanged**: unlike the
pick-face banner it is about a hazard that is genuinely reachable — a *storage* destination is savable
today, and a receipt into one holds `FOR UPDATE` on that Location row for a whole multi-case receipt.
§7.4 row 8 explains why it is a scalability requirement and not a nicety.

**Excluded from the list:** the tier-4 lane itself (`location.name == 'PutAwayLane'`,
`WmsConstants.java:771`). Per Q3/F8 it passes every predicate, so without the exclusion an operator can
*pin* tier 1 to the fallback and then wonder why a later warehouse default does nothing. **"Clear /
Use default" is the only route back.** The exclusion test compares against the machine **name**
constant, never the display label (§3.6).

**H2 note:** if D-D lands as a repository query, keep it **JPQL with plain joins and booleans** — no
`nullif(...)::bigint` or other Postgres-only construct (2732 §7.7 row 6 flags exactly that in
`readCommittedDestination`), because the test SQL lane must stay H2-compatible.

### 3.5a D-G — `name` search parameter on `GET /putawayConfig/eligibleLocations` (**NEW SCOPE, r7, Phase A4**)

> [!important] **✅ Q4 ANSWERED 2026-08-12 — option (ii): 2643 ships the server-side search parameter.
> This is NEW scope the plan did not carry, and it was assigned to 2643 by SBDEV-2732 in writing.**
>
> 2732's Q2 close states that SKU scope *"crosses the ~2,000 threshold"* while merchant/warehouse do not,
> and hands the remedy to **"SBDEV-2643 Phase B2 as a parameter on `eligibleLocations`, never on
> `/location/detailView`"**. **That parameter was never built.** `PutawayConfigController:92-97` takes
> only `scope`, `subjectId` and `Pageable`.

> [!danger] **⚠ "`wms2-wineco-dev`" IS THE DATABASE `dev_wh01_om1`. THREE PLAUSIBLE-LOOKING WRONG COPIES SIT
> BESIDE IT ON THE SAME TUNNEL (localhost:25060), AND TWO OF THEM ANSWER EVERY QUERY YOU ASK.**
>
> | database | what it is | V2.2.13? | candidates |
> |---|---|---|---|
> | **`dev_wh01_om1`** | ✅ **the live DEV tenant DB — use this one** | applied 08-11 13:50 | 2,738 |
> | `wh01_om1_v2` | migration-era copy; it is what `migration.env.wineco` points at | **no `flyway_schema_history` at all** | 2,889 |
> | `wh01_om1` | the v1 database | n/a | 2,765 |
>
> `om1` is WineCo's tenant code — the same `om1` as the API's Keycloak client `om1-api`. The `dev_` prefix is
> the tell, and it is the **exact analogue of the recorded `dev_landlord` vs `landlord` trap**: the DEV object
> carries the prefix and a stale same-named sibling sits next to it returning plausible answers.
>
> ⚠ **`migration.env.wineco` points at the WRONG database for this purpose.** It is the v1→v2 onboarding
> toolkit's config, so `TENANT_DB_NAME=wh01_om1_v2` — the migration target, not the running DEV tenant.
> Querying it 2026-08-12 reported `putaway_config_audit` MISSING and `putawaylocation_id` NOT NULL, which
> would have read as "V2.2.13 was never applied" when it had been applied the day before. **Confirm the DB by
> its `flyway_schema_history` head, never by an env file.**

**The measured problem.** `store/admin/configuration.js`'s `getEligiblePutawayLocations` loops pages at
`size = 200` until the server reports the last page, accumulating every row client-side (with a
`MAX_PAGES = 100` runaway backstop). Measured candidate sets, 2026-08-12, SELECT-only:

> [!warning] **⚠ THE `2,564` FIGURE BELOW IS WRONG. MEASURED AGAINST THE LIVE DEV DB 2026-08-12 (M14):
> the shipped query returns 2,738 candidates, i.e. 14 pages, not 13.**
>
> `SELECT count(*) FROM location WHERE name <> 'PutAwayLane'` on **`dev_wh01_om1`** — which IS
> `wms2-wineco-dev`, see the DB-identity warning below — gives **2,738** against 2,739 total locations. The
> single excluded row is the one `PutAwayLane`. `ceil(2738/200) = 14`.
>
> Provenance of 2,564 could not be reconstructed: it is not the count on any of the three wineco copies on
> the dev host (`dev_wh01_om1` 2,738 / `wh01_om1_v2` 2,889 / v1 `wh01_om1` 2,765), nor does it fall out of
> excluding staging/transfer/gate lanes (2,705), requiring an area (2,738), or restricting to flowbins
> (2,068). Treat the UAT row's 2,703 as equally unverified.
>
> **The error is in the plan's favour** — A4's justification is *stronger* at 2,738 rows over 14 sequential
> requests than at the 2,564/13 it argued from. But an unverifiable measurement quoted five times across a
> plan is how a later phase "confirms" a number nobody ever took.

| tenant | candidate locations | pages at size 200 | total locations |
|---|---|---|---|
| `wms2-wineco-dev` (`dev_wh01_om1`) | **2,738** ✅ measured 2026-08-12 | **14 sequential round-trips** | 2,739 |
| ~~`wms2-wineco-dev`~~ | ~~2,564~~ **WRONG, see above** | ~~13~~ | 2,739 |
| `wsl-wineco-uat` | 2,703 | 14 | 2,890 |
| `wms2-hydra-dev2` / `nywh-hydra-uat` | 602 | 4 | 666 / 665 |

So on a WineCo-shaped tenant, **opening the SKU dialog costs 13 serial HTTP requests before the operator
can type**, and drops ~2,500 rows into a `v-autocomplete`. Tiers 2 and 3 never see this (516 rows), which
is why 2732 could leave it: **the volume is scope-dependent, and SKU scope is 2643's.**

**The change.**

```java
// PutawayConfigController — ADD the parameter; the existing three are unchanged.
@GetMapping("/eligibleLocations")
public Page<EligibleLocation> eligibleLocations(
        @RequestParam PutawayScope scope,
        @RequestParam(required = false) Long subjectId,
        @RequestParam(required = false) String name,     // <-- D-G
        Pageable pageable) throws BusinessException {
    return putawayDestinationQueryService.eligibleLocations(scope, subjectId, name, pageable);
}
```

| Rule | Requirement |
|---|---|
| **Filter semantics** | case-insensitive **contains** on `location.name`, applied **in the query**, never after eligibility evaluation |
| **Optionality** | `null` / blank ⇒ **identical behaviour to today**, byte-for-byte. Tiers 2 and 3 pass nothing and must be unaffected — this is the compatibility contract, and it is what makes the change safe to make in a 2732-owned file |
| **⚠ It filters CANDIDATES, not RESULTS** | The predicate goes in the same SQL that selects candidates, so the page is *N matching* rows. Filtering after the fact would page over 2,564 rows to return 3 — the round-trips this exists to remove |
| **⚠ `eligible` semantics must not shift** | The 7 `BlockingReason` values and the `tier` field are computed exactly as before **for the rows that match**. A search must never turn an ineligible row eligible, and **must not narrow the eligible set for an empty search** |
| **⚠ `totalCount` becomes search-relative — and the banner MUST NOT use it** | With a search applied, `totalElements` counts *matches*, so §3.8.2a's *"{eligibleCount} of this warehouse's {totalCount}"* would silently become "of this search", which is **confidently wrong** (§14 principle 4). **The banner's counts come from the UNFILTERED first read**, taken once when the dialog opens, and are not recomputed per keystroke. Verify row `A4-neg-banner` |
| **H2 compatibility** | JPQL, not native SQL — the same constraint 2732 pinned with `P2A-h2` |
| **Debounce** | the caller debounces (≥250 ms) and drops out-of-order responses; a search box that fires per keystroke re-introduces the round-trip cost it removes |

**Ownership.** This lands in `PutawayConfigController` and `PutawayDestinationQueryService` — both
2732-owned. It is covered by the same r7 boundary amendment as B2 (§3.8, §14 principle 1) and for a
stronger reason: **2732 explicitly assigned this deliverable to 2643.** Verify rows `A4-*`.

**Phase.** New **Phase A4** (`wms2-api`), between A2 and B2 — B2's picker consumes it. **+0.5 d**, which
is why §5.7's total moved from ~1.0 d to ~1.5 d.

> [!success] **✅ A4 IMPLEMENTED 2026-08-12 — and the "byte-for-byte" rule above became a SPLIT QUERY,
> not a parameterised one. This is the one design detail of A4 worth carrying forward.**
>
> The table above required a blank term to behave *"identical to today, byte-for-byte"* and §5.5a said
> **branch around the predicate**. Implementation took that literally, which the sketch at `:1195` did not
> anticipate: `LocationRepository.findPutawayCandidates` is **left completely untouched**, and A4 adds a
> **sibling** `findPutawayCandidatesByName(excludedLaneName, nameFilter, Pageable)`. The service branches
> on a trimmed-blank term and calls one or the other.
>
> **Why not one query with `(:name IS NULL OR LOWER(l.name) LIKE …)`** — the obvious shape, and the one
> `CLAUDE.md`'s optional-JPQL-filter rule would otherwise push you toward:
> - that leaves **every unfiltered read executing a different SQL string than it does today**, on two
>   screens already in production, whose failure mode is a silently missing row. "Very probably fine" is
>   not provable without a plan on each tenant; the split makes it a **structural guarantee** instead of an
>   argument, and costs one duplicated predicate pair.
> - the `CLAUDE.md` rule then does not apply at all, because the filtered query never receives a null or
>   empty term. The service normalises `null`, `""` and `"   "` to "no search" **before** the branch.
>
> **The duplication is the price, and two guards keep the copies honest:** verify row `A4-split` asserts
> the untouched query still carries **no** name predicate (`countQuery` included), and
> `theFilteredQueryLowercasesBothSidesAndKeepsItsSiblingsPredicates` asserts both queries keep the same
> excluded-lane clause and the same two-tier `ORDER BY`.
>
> **Wildcard escaping was deliberately NOT added** — ⚠ **but the first version of this paragraph justified
> that with a false absolute, and a review lane MEASURED it wrong (2026-08-12).** It claimed a metacharacter
> "can only *widen* a match — it cannot narrow one". True of `%` and `_`. **False of backslash**, which is the
> default `LIKE` escape character in both H2 and Postgres. On H2 2.3.232 with the shipped pattern: `A%B` → 3
> rows, `A\%B` → **1** row, and a term ending in `\` → **zero rows** (it consumes the closing `%`). A silent
> empty result is the *absence* failure class R11 is about, so the claim mattered.
>
> **Still not escaped, as a scoped decision:** the only caller is B2's search box, where a typed backslash
> gives zero rows that a backspace restores — self-correcting and visible to the person who caused it, unlike
> R11's loss on a screen where the operator cannot tell anything is missing. Adding an `ESCAPE` clause would
> also make `%` literal, which is a behaviour change rather than a fix. Revisit if a location-naming scheme
> ever uses backslashes.
>
> **⚠ `@RestResource(exported = false)` on the new query is load-bearing, and its absence was a real finding
> (M1).** `RestConfiguration:47` uses `RepositoryDetectionStrategies.ANNOTATED` and `LocationRepository`
> carries `@RepositoryRestResource`, so query methods export **by default**: without the annotation the method
> is published at `GET /v3/location/search/findPutawayCandidatesByName`, reachable by any `wms_user` — and an
> HTTP caller passing `nameFilter=` runs exactly the match-everything wildcard this section forbids,
> **falsifying the "blank never reaches the filtered query" invariant.** Every other query method in that file
> is explicit; the one that is not is 2732's `findPutawayCandidates`, whose posture is 2732's to revisit.
> Same class as the **SBDEV-1666** landmine: a service-layer guard cannot constrain a `@RestResource`-exported
> query.
>
> **The 3-argument `eligibleLocations` was kept as a delegate**, not deleted — ⚠ **and the first version of
> this box justified that with a false claim, caught by the conformance lane 2026-08-12.** It said the 3-arg
> form "is the signature 2732's two production pickers arrive through". **It is not.** Those pickers arrive at
> `PutawayConfigController.eligibleLocations`, which since A4 calls the **4-arg** form with `name = null`;
> grep `src/main` and the 3-arg overload has **zero production callers**. The honest justification is the
> second half only: **its 8 merged behavioural tests in `EligibleLocationsRead` drive that signature**, and
> deleting the overload would make A4 rewrite 8 call sites in another ticket's test file to add a parameter
> none of them care about. It is a two-line delegate, not a second implementation, and
> `theLegacyThreeArgFormIsTheSameCodePath` pins the delegation so the two cannot diverge. **Judged worth
> keeping on that basis alone** — but it IS production code with no production caller, so if a reviewer would
> rather see it deleted and the 8 tests updated, that is a reasonable call and the fix is mechanical.
> `takesScopeAndOptionalSubjectId`
> was **widened** to `(PutawayScope, Long, String, Pageable)` — deliberately not deleted, since that row
> going red is the intended signal that a shared signature moved.

### 3.6 D-F — the negative code-shape checks (all phases)

2732 mandates `check_N2_controller_delegates_not_resolves` for `ReceivingController` only. **2643 must
carry the identical check for `ItemDataController.java`.** Rationale, and it is not theoretical: an
implementer can satisfy every positive check by adding the facade method *and still* calling
`putawayDestinationResolver` directly from the controller — which reintroduces the
`Propagation.MANDATORY` → `IllegalTransactionStateException` → 500 on every call, while the script
stays green.

Four negative checks, in the verify script:

| id | Assertion | Failure it catches |
|---|---|---|
| `A2-neg-res` | `putawayDestinationResolver` appears **nowhere** in `ItemDataController.java` | 500 on every call to the new endpoint |
| `A2-neg-oms` | `httpRestService` appears nowhere in the new handler | a config read triggering an OMS inventory export |
| `B2-neg-leg` | the store action does **not** target `/itemData/setPutAwayLocation` | the tenant-wide `allEntries=true` cache flush, no validation, no audit |
| `B1-neg-corpse` | the commented `:100-123` block is gone from `skuData.vue` | dead code the ticket's missing edit form is attributed to |

**Negative-test the script itself.** Per the recorded landmine, a "N pass, 0 fail" means nothing until
you replay the pre-fix tree and watch it FAIL. §7.5.

### 3.7 The wording contract — inherit from 2731, invent nothing

`receivingForm.vue` already canonicalised this, with a comment at `:215-220` explaining why:

```js
// SBDEV-2731 Fix A. Mirrors WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE
// (WmsConstants.java:771) — this is the LOCATION NAME, not a display label. […]
// Comparing against the spaced display label below would make isPutawayOverride
// true for every SKU.
const DEFAULT_PUTAWAY_LANE_NAME  = 'PutAwayLane'          // :216  location.name — for COMPARISON
const DEFAULT_PUTAWAY_LANE_LABEL = 'Put Away Lane'        // :217  operator-facing text ONLY
```

with `isPutawayDestinationApplied` (tri-state, `:296-300`), `isPutawayOverride` (`:301-305`, compares
against the **NAME**) and `putawayDisplay` (`:309-314`, maps the machine name to the **LABEL**).

**2643 reuses both constants and the same comparison discipline.** 2731 has them in one place; a second
copy is the divergence risk, so **B1 extracts them to
`components/masterData/material/skuData/putawayWording.js`** and re-imports them into
`receivingForm.vue`, rather than making a third copy. Never render `PutAwayLane` to an operator; never
compare against `'Put Away Lane'`.

**The ticket's own wording, reconciled:** it writes `Default Putaway Location: PutawayLane` (no capital
A) in one place. The real name is `PutAwayLane`. **Use the code constant for comparison and the label
for display** — do not encode the ticket's typo.

### 3.8 The SKU edit surface (Phase B1 + B2)

> [!important] **RESHAPED r7 (2026-08-12) — SBDEV-2732 ALREADY BUILT THE HARD HALF OF B2. READ THIS
> BEFORE IMPLEMENTING §3.8.2.**
>
> When this section was written, 2732 Phase 2 did not exist and 2643 expected to build its own dialog
> around 2732's raw `LocationPicker`. 2732 then shipped **`defaultPutawayLocationField.vue`**
> (step 20, merge `ec01dd7`) — a *wrapper* that already owns everything B2's hard parts were:
>
> | B2 was going to build | Where it now lives |
> |---|---|
> | preview / Save-gating on `compatible` | `defaultPutawayLocationField.refreshPreview()` + `saveDisabled` |
> | the `blockingReason` → human-message map | same file, all **7** enum values |
> | D11 count-and-confirm, with a 409-honest recount | `save()` / `confirmSave()` |
> | paginated `eligibleLocations` accumulate + `totalCount` | `admin/configuration/getEligiblePutawayLocations` |
> | "Clear omits `locationId` entirely" | already the wrapper's write shape |
> | 422 / 409 body surfacing | same (and one of the six defects 2732's review round fixed) |
> | the `sb_admin` gate | `canEdit` ← `resolveSbAdmin` (§3.11) |
> | double-submit re-entry guard | `confirmSave()`'s `if (this.saving) return` |
>
> And it was **built for this**: its `scope` prop is documented *"'WAREHOUSE' today; 'MERCHANT' / 'SKU'
> when steps 21 and SBDEV-2643 reuse this"*, `subjectId` as *"Required at SKU scope"*, and its
> `write()` has a SKU branch that deliberately refuses with the comment *"SKU scope belongs to
> SBDEV-2732's sibling ticket (SBDEV-2643 B2) and has its own endpoint"*.
>
> **So B2 EXTENDS that component. It does not clone it.** §3.8.2's structure below is superseded in its
> internals and retained for the entry points, the wording and the banner. What B2 actually adds:
>
> 1. `SKU: 'admin/configuration/setSkuPutawayDestination'` in the wrapper's `writeActionForScope` map;
> 2. that store action → `PUT /putawayConfig/sku/{itemdataId}`, in `store/admin/configuration.js`
>    beside its tier-2 and tier-3 siblings (tier 1 living in a different module is how the three drift);
> 3. a `subjectId == null` guard at SKU scope, mirroring the existing MERCHANT one;
> 4. **the SKU path skips D11's confirm** — see the box below;
> 5. a thin `editSkuPutawayDialog.vue` that supplies dialog chrome, the effective-value line and the
>    scope banner, and mounts the wrapper at `scope="SKU"`.
>
> ⚠ **This crosses §14 principle 1 on purpose, and r7 amends the principle rather than breaching it
> quietly.** D13's "2643 writes into ZERO 2732-owned files" was a **temporal** guard against two
> in-flight PRs colliding — §11.0 said so at the time (*"the residue is temporal, not architectural"*).
> 2732 is merged and ready to archive, so the collision risk is gone and the cost has inverted: holding
> the boundary now means shipping a **second confirmation gate**, which 2732 §3.11.2 names as exactly
> how one of them ends up without it.

> [!warning] **The SKU write takes NO `confirmIncompatibleSkus`, so the shared D11 confirm must be
> skipped at SKU scope.** `PutawayConfigController.setSku` is
> `(@PathVariable Long itemdataId, @RequestParam(required = false) Long locationId)` and its javadoc is
> explicit: *"SKU scope writes straight through: the blast radius is one SKU, so D11's
> count-and-confirm does not apply and there is no `confirmIncompatibleSkus` parameter to honour."*
>
> At SKU scope `preview`'s counts are **degenerate** — the subject *is* one SKU, so
> `incompatibleSkuCount / totalSkuCount` is 0-or-1 of 1 (§3.5, and Q2 predicted this before the code
> existed). Inheriting the shared `incompatibleSkuCount > 0` test would therefore raise a confirmation
> dialog in front of a write **that cannot honour the answer** — the operator confirms, and the
> confirmation goes nowhere. Verify rows `B2-skip-d11` and `B2-neg-conf`.

The remaining structure below still applies to the **thin** dialog. Copy
`components/masterData/material/packaging/editPackagingDialog.vue` (196 L) for its **chrome and entry
points only** — the **only** masterData create/edit dialog in the repo, and a sibling of the SKU screen
(`material/packaging/` next to `material/skuData/`). Not the `components/admin/` ones. ⚠ **Do not also
copy its `validated()` + `$toast` validation idiom** — the wrapper owns Save-gating now, and a
hand-rolled validator whose only job is to duplicate `saveDisabled` is the duplication `B2-neg-dup`
exists to catch. Verify row `B2-valid` is retired for the same reason.

**3.8.1 Entry points — two, per `packaging.vue`'s precedent**

1. A pencil button in the **existing active** actions column at `skuData.vue:95-99`, beside the eye at
   `:97` — mirroring `packaging.vue:91-94`. Reachable without opening details first.
2. A button in `<full-details>`'s **`#actions` slot** (`fullDetails.vue:26`, already present) so the
   edit is reachable from the overlay. **Zero changes to `fullDetails.vue`.**

`fullDetails.vue` **cannot** host an editable field, and should not be made to: it is a generic
read-only renderer (`:10` `v-for`, `:11` exclude check, `:13-17` label/value spans, `:18` `getValue()`),
used by many screens. Making one field editable means either a cross-cutting per-field slot API (out of
2643's scope) or a `name`-specific special case — exactly the anti-pattern `:19`'s hardcoded
`name === 'priority'` already is.

Delete the commented `:100-123` block in the same commit. Do **not** resurrect the trash button or the
"Something 1/2/3" menu.

**3.8.2 `editSkuPutawayDialog.vue` — structure, matching the precedent exactly**

```
<v-dialog v-model="show" class="rounded-0" persistent max-width="400px">
  props: ['show', 'item']                        // no `mode` — edit-only, there is no create
  ── Current value              (read-only)  "Default Putaway Location: <configured name>"
                                            or  "Inherits: <sourceLabel> — <locationName>"
                                            from GET /v3/itemData/{id}/effectivePutawayDestination
  ── <location-picker>                       2732's components/common/LocationPicker.vue
                                             :items from GET /v3/putawayConfig/eligibleLocations?scope=SKU
                                             two tiers (goodsin default / storage behind the toggle)
                                             renders "<locationName> — <areaName>"   (§3.9 AC3)
  ── SCOPE banner               ALWAYS VISIBLE, above the picker  ← D1 (r3), REWRITTEN r7
                                "A pick face selected here is routed via putaway, not placed
                                 directly at receipt. The stock is not on the pick face when the
                                 receipt closes; it arrives when someone puts it away.
                                 {eligibleCount} of this warehouse's {totalCount} locations
                                 are currently eligible."
                                ⚠ {eligibleCount}/{totalCount} are COMPUTED AT RUNTIME from the
                                  eligibleLocations response — NEVER literals. See §3.8.2a(3).
                                ⚠ r7: the old "not yet selectable / tracked by SBDEV-2821" text is
                                  DELETED. See §3.8.2a.
  ── storage-tier lock warning  v-if the "Show storage locations" toggle is on   (2732 :1607)
  ── compatibility warning      v-if effective.compatible === false  → render `warning` verbatim
  ── actions:  [Clear / Use default]   [Cancel]   [Submit]
```

**3.8.2a The scope banner is a deliverable, not decoration (D1, §14 principle 4).**

> [!danger] **REWRITTEN r7 (2026-08-12) — THIS SECTION'S PREMISE EXPIRED TWICE AND CONTRADICTED THE D1
> ROW IN §10.1 FOR THREE REVISIONS.**
>
> The r2 text below required the banner to say pick faces are *"not yet selectable"* and to name
> **SBDEV-2821** as the ticket that will fix that. **Both halves are now false, on two independent
> counts:**
>
> 1. **D1 was RE-REVERSED in r3.** The SKU picker **does** offer pick faces, flowbins included — tier 1
>    is exempt from 2732's P2.7 rule (e). §10.1's D1 row has said so since r3. This section was never
>    reconciled to it, so the plan simultaneously specified "pick faces are offered" (D1) and "the
>    banner tells the operator they are not" (§3.8.2a). **r4's log claims the body was reconciled to r3;
>    it missed this**, and the two verify rows kept the stale version enforceable.
>    *Measured confirmation:* 2732 reports **2,554** eligible rows at SKU scope on `wms2-wineco-dev`
>    against **516** at merchant/warehouse scope. That gap **is** the pick faces.
> 2. **SBDEV-2821 MERGED on 2026-08-09** — PR #135, merge `fd90487`, ClickUp `on dev`. Even under r2's
>    reading, the banner would now be pointing operators at work that has already shipped.
>
> A banner that tells an operator to wait for a shipped ticket, about a restriction that does not exist,
> is **confidently wrong** — the precise §14-principle-4 inversion this section was written to prevent,
> reproduced by the section itself.

> [!done] **✅ Q3 ANSWERED 2026-08-12 — MIRROR SBDEV-2732's ALREADY-APPROVED WORDING. Do not write new
> copy.** 2732 step 19a's diversion sentence was chosen as *variant A* and moved into
> `messages.properties` (PR #147, merge `509be61`) precisely so a product revision is a properties edit:
>
> ```properties
> putawayDestinationDivertedToLane=Received to %1$s. Putaway will move it to %2$s \
>   — the stock is not on %2$s until then.
> ```
>
> That is the **receive-time** sentence. 2643's banner is the **configure-time** sentence for the same
> mechanism, so it must read as the same voice — an operator who configures a pick face and then receives
> into it should not meet two different explanations of one behaviour. The config-time form:
>
> > **Putaway will move stock here — it is not on {locationName} until then.**
> > Receiving sends it to {laneName} first.
> > *{eligibleCount} of this warehouse's {totalCount} locations are currently eligible.*
>
> **Why this is a mirror and not a copy-paste:** the API key is parameterised on *(lane, configured)* and
> is emitted **only when a receipt was actually diverted** (`ReceivingController:130-136` sets
> `divertedTo` / `divertedReason` as *absent, not null*, when the gate did not fire). The banner is shown
> **before** any receipt exists, so it cannot consume that key — it states the same fact in the future
> tense. ⚠ **Do NOT try to render `putawayDestinationDivertedToLane` from the config screen**: there is no
> receipt, so there are no arguments to bind, and `wms2-web-ui` has **no `vue-i18n`** — UI copy is
> hardcoded in components (which is why 2732 put the *receive-time* string on the API side, where the
> arguments live).
>
> **Consequence for §5.7's risk row:** the "get the wording reviewed by Scott Dalton / David Oppenheim
> before merge" item is **downgraded from a blocker to a courtesy** — the wording is derived from copy
> the requester's side already accepted. It still moves if 2732's own pending product read changes
> variant A, so **keep the two in step**: if that properties value changes, this banner changes with it.

The banner is **always-visible**, not per-row, and it must:

1. state the **mechanism** — putaway moves the stock here; it is not placed directly at receipt
   (mirroring the approved wording above);
2. state the **operational consequence** — *it is not on that location until then.* This is not optional
   colour: a screen that shows `ICE PACK` while stock lands on `PutAwayLane` **is the SBDEV-2731 defect
   class**, and 2732 built step 19a specifically to stop it recurring on the receiving side;
3. state the eligible count, so "the list looks short" is confirmed rather than suspected.

Verify rows `B2-banner` (mechanism), `B2-banner2` (consequence), **`B2-neg-bann`** (the expired
`SBDEV-2821` / "not yet selectable" framing is gone), `B2-banner3` (counts computed).

~~Superseded r7 — r2's rationale, retained only so a reader who remembers it knows it was deliberate:~~
~~r1 shipped a per-row advisory on pick-face rows; r2 removed those rows entirely, which creates a worse
failure if nothing replaces the banner — an operator types "ICE", finds nothing, and concludes the
search is broken. That reasoning was sound **for r2's eligible set**; it stopped applying the moment r3
put the pick faces back in the list.~~

> **⚠ The counts MUST be computed at runtime, never written as literals.** `92` and `666` appear
> throughout this plan as **measurements of `wh01_hydra_v2` on 2026-08-07** (frontmatter, §2.2). They are
> wrong for wineco, for ShipItEZ, for hydra PRD, and wrong for hydra DEV itself the moment a location is
> added. A banner asserting "92 of this warehouse's 666 locations" to an operator whose warehouse has
> neither number is **confidently wrong** — a worse failure than the silent one this banner exists to
> prevent, and a direct inversion of §14 principle 4.
>
> Both numbers are already in the response: §3.5's row shape is
> `{ locationId, locationName, areaName, locationType, eligible, blockingReason }` and the endpoint
> returns **both** classes (Jest `pickerNeverResurrectsIneligibleRows` depends on it — ⚠ renamed r7 from
> `pickerNeverOffersPickFaces`, which asserted the opposite of D1/r3). So the dialog computes
> `eligibleCount = items.filter(r => r.eligible).length` and `totalCount = items.length`. That is
> **reading a server verdict**, not re-deriving a predicate — §14 principle 2 is untouched.
>
> ⚠ **r7, and this is a NEW way to get it wrong:** once A4's `name` search exists (§3.5a), `items` is the **search-narrowed** set and `totalElements` counts matches. Computing the banner from it turns *"of this warehouse's 2,564"* into *"of this search's 3"* — silently, per keystroke. **Capture both counts ONCE from the unfiltered read taken when the dialog opens, and never recompute them while searching.** Verify row `A4-neg-banner`.

The same three facts belong in the picker's **empty-state** text (a client filter can produce zero rows
even when many are eligible) — including the computed counts, on the same rule.

⚠ **r7 — the verify-row list that stood here named the retired rows** (`B2-banner` "names SBDEV-2821",
`B2-banner2` "names 2732 Q9"). The live list is the one above. The Jest name
`scopeBannerNamesBlockingTicket` goes with it — there is no blocking ticket to name; rename to
**`scopeBannerStatesRoutedViaPutaway`**, and add **`scopeBannerStatesConsequence`**.
**`scopeBannerCountIsComputedNotLiteral`** is unchanged and still required.

**3.8.2b `LocationPicker.vue`'s props/events contract — SPECIFIED HERE, handed to 2732 (Q6).**

r1 filed this as an interim guess in §10.2. r2 promotes it to a **written spec** and makes 2732's
acceptance of it a §5.1 item (row 0b). Grounds: waiting costs the entire user-visible half of the ticket
while its `urgent` priority runs; specifying costs at worst one dialog's binding rewrite, and
`B2-field` detects the divergence. *(⚠ r7: this said `B2-picker`, a row renamed when B2 moved to
reusing 2732's wrapper — see §3.8. The row id in the script is `B2-field`.)*

The shape is **the repo's own idiom**, taken from the *real* precedent — `createBol.vue:68-76`, the
file's only `v-autocomplete` (§10.3 **C7**; 2732's cited `:109-121` + `:125` "Lookup" button do **not**
exist):

```
props:   :items       Array of eligible rows, exactly as GET /putawayConfig/eligibleLocations returns them
         :value       the currently selected locationId  (v-model)
         :disabled    Boolean — the permission gate (§3.11), applied as :disabled never v-if
         item-text    String, default 'locationName'   (createBol.vue:74 uses item-text="label")
         item-value   String, default 'locationId'     (createBol.vue:75 uses item-value="value")
events:  @input       the selected locationId — the v-model contract (createBol.vue:69 v-model)
         @select      the FULL row object, so the caller reads blockingReason / areaName / locationType
                      without a second lookup or a client-side re-derivation (§14 principle 2)
```

`@select` emitting the whole row is the load-bearing clause: without it the dialog must either refetch
or re-derive, and re-deriving is exactly what D3 forbids.

Idiom rules, all from the precedent:

- Field labels are `<v-card-text class="pa-0 font-weight-bold">Label</v-card-text>` **above** the
  control — **not** Vuetify `label=` props.
- **Validation is a hand-rolled `validated()` returning a boolean and firing `this.$toast.error(...)`
  per failure.** No `v-form`, no `rules`, no Vuelidate.
- `save()` wraps in `CommUtil.showPageSpinner(this)` / `hidePageSpinner(this)`, dispatches, then
  `this.close()`. `close()` calls `resetFields()` then `this.$emit('close')`.
- Buttons: `<v-btn class="justify-start bigButton" tile depressed dark @click="close">Cancel</v-btn>`
  and `<v-btn class="justify-start bigButton ml-0" tile depressed color="primary" dark @click="save">Submit</v-btn>`.

**3.8.3 The store write action — `store/masterData/skuData.js`**

The store currently has `getSkuData` (`:46`), `searchSkuData` (`:63`), `getSkuDetail` (`:88`) and
**zero write actions of any kind**. 2643 adds the first, copying `store/masterData/packaging.js:114-128`:

```js
// data: { id, locationId }   — locationId == null  ⇒  CLEAR (omit the query param entirely)
async setSkuPutawayLocation(context, data) {
  try {
    const qs = data.locationId == null ? '' : `?locationId=${data.locationId}`
    const results = await this.$axios.$put(`/putawayConfig/sku/${data.id}${qs}`)
    if (results && results.errors) {
      this.$toast.error(results.errors[0].message)
    } else {
      this.$toast.success('Default putaway location updated')
    }
    // Re-read THIS SKU only. NOT searchSkuData — that re-pages the table and loses the user's place.
    await context.dispatch('getSkuDetail', { id: data.id })
  } catch (e) {
    // 2732's writes return REAL HTTP errors (422 validation, 409 stale confirmation), so they land
    // HERE, not in results.errors. Surface the body or every validation message is swallowed.
    const msg = e?.response?.data?.errors?.[0]?.message
             ?? e?.response?.data?.message
             ?? 'Error: Request failed due to a network or server issue. Please retry.'
    this.$toast.error(msg)
  }
},

getSkuEffectivePutaway(context, data) {
  return this.$axios.$get(`/itemData/${data.id}/effectivePutawayDestination`)
},
```

Three deliberate deviations from the packaging precedent:

1. **`PUT /putawayConfig/sku/{id}`** (2732 §3.5a) — **not** `PUT /itemdata/{id}` (the HAL path) and
   **not** `GET /itemData/setPutAwayLocation/{i}/{l}` (unvalidated, unaudited, wrong verb, tenant-wide
   cache flush). Verify row `B2-neg-leg`.
2. **Re-dispatch `getSkuDetail` for the edited SKU**, where `editPackaging:122` re-dispatches
   `getPackaging` (the whole list). `searchSkuData` re-pages the table.
3. **Surface `e.response.data`.** The bare "network or server issue" toast would hide every validation
   message the ticket asks to be actionable.

⚠ **Related landmine — CORS.** `response.reset()` strips the CORS headers Spring Security's
`CorsFilter` already wrote, after which the browser blocks the 422 and the UI shows its generic network
toast regardless of the code above. **If 2732's exception handler uses `reset()` instead of
`resetBuffer()`, the 422 body never reaches the operator.** MockMvc installs no `CorsFilter`, so no
unit test catches it. **Manual row M6 is the ONLY detector.** ⚠ *r2 correction: r1 promised a verify row
`B2-cors` here. No such row exists, and none can — the `reset()` vs `resetBuffer()` call lives in
**2732's** exception handler, and a grep asserting its content would be both a cross-plan assertion
(§14 principle 1) and unable to see the browser-side effect that actually matters. Citing a check that
does not exist is exactly the over-claim this plan's §14 principle 5 forbids.*

**3.8.4 `locationId` omitted ⇒ CLEAR.** 2732 §3.5a: `@RequestParam(required = false) Long locationId`,
*"omitted ⇒ clear"*. The Clear button must omit the parameter, **not** send `?locationId=` or
`?locationId=null`. Jest asserts the exact URL.

**3.8.5 AC5 / persistedState.** `masterData.skuData` **is** persisted to `localStorage['vuex-web']`
(`plugins/persistedState.client.js:26-29` — an allow-nothing-out reducer excluding only
`warehouseTimezone`, `selectedWarehouse`, `warehouses`), so the SKU list rehydrates from localStorage
on refresh. **The overlay is safe** because `skuData.vue:304` always refetches via `getSkuDetail`, which
has no caching. This is the second reason Q4 answers **no table column**: a column would render a
stale rehydrated value after a write. No exclusion is added to `persistedState.client.js`.

### 3.9 Three ticket requirements that name things the schema does not have

Documented reinterpretations, **never silent**. Each is a scope clarification for the reviewer, not a
blocker.

| AC | Ticket wording | Reality | This plan's reading |
|---|---|---|---|
| AC6 | *"only valid, **active**, stock-compatible locations"* | `Location` has **no `active` column** — `Location.java:32-41` is the 5 lane booleans; `information_schema` count of `location.active` = **0** | **`entityLock == NOT_LOCKED`** (`WmsConstants.java:1188-1195`) is the active proxy — 2732's P2.2. Measured: 666 of 666 unlocked, so this predicate rejects nothing on this tenant today |
| AC6 | *"shipping lane"* | no `shippinglane` flag exists | nearest is **`gate`** (`Location.java:41`, 7 rows). Rejected by P2.3 like every other lane flag |
| AC3 | *"displays meaningful location information"*, ticket renders `ICE-PACK-01 — Ice Pack Pick Location` (a **code — name** pair) | `Location` has **`name` only**; `getLocationView()` exposes `locationName`, `areaName`, `locationType` (= `sltname`). **There is no location code column** | render **`locationName — areaName`** (falling back to `locationType` when the area is null). The two-part shape the ticket asks for is preserved; the *fields* are the ones that exist |

### 3.10 What this plan explicitly does NOT build

- **Any migration.** 2643 ships zero SQL. `V2.2.13` is 2732's.
- **Any change to `ReceivingService`** — the ticket's own "Receiving Behavior Boundary" defers routing
  behaviour, and 2732 §3.7 owns it regardless.
- **`LocationPicker.vue` itself** (2732 §3.11.2 Step 19) — 2643 *consumes* it. Q7 → strict reuse; a
  second picker would mean two implementations of a safety-critical filter.
- **The merchant and warehouse tiers.**
- **A general web-UI role-gating framework** — cross-cutting across every screen, already a named
  follow-up in 2732 §8.4. §3.11 builds one bounded gate, not a framework.
- **The `eligibleLocations` endpoint itself, as plan of record.** D-D is **specified** in §3.5 and
  **handed to 2732** (D12). A3 remains as a named fallback with a decision deadline.
- **The `@PreAuthorize` constant swap in 2732's files.** §3.1's r2 scope box. 2643 ships the detector and
  a prerequisite row; the edit belongs to 2732's review or SBDEV-2863.
- **Any relaxation of P2.5 or P2.7(c).** Both stay absolute. SBDEV-2821 relaxes them for tier 1
  (2732 `:722`). 2643 does not extend `blockingReason` and adds no `advisory` field (r2, §3.5).
- **A count-and-confirm preview flow.** Answered by 2732's own signature (Q8/D-x): `setSku` carries
  **no** `confirmIncompatibleSkus`; only `setMerchant` and `setWarehouse` do. Count-and-confirm is a
  bulk-blast-radius device and one SKU has no blast radius. 2643 needs only the **blocking** signal.
- **A table column on the SKU grid** (Q4).
- **Repairing the 9 endpoints F1 breaks** — SBDEV-2863's.

### 3.11 The UI permission gate — `disabled`, not `v-if`

There is no role gating anywhere in `wms2-web-ui` (§2.5). 2643 builds the first one, bounded:

> [!danger] **REWRITTEN AGAIN r7 (2026-08-12). BOTH earlier forms are WRONG. Do not implement either.**
>
> This section has now specified a gate that could never work **twice**, for two different reasons, and
> the second time it was written *as the correction of the first*. The history matters because the
> failure mode is identical: both forms were derived from reading the backend and reasoning about where
> the role "should" live, instead of checking how the token actually carries it.
>
> **r5 and earlier — `appAdminGroup`:** dead config. `APP_ADMIN_GROUP` survives only at
> `nuxt.config.js:167` and `CLAUDE.md:70`; **no code reads it**, and 2732 §3.12 says the same
> independently. A gate keyed on it is `false` for everyone.
>
> **r6 — `$kc.hasResourceRole('sb_admin', $config.keycloak.clientId)`:** ⚠ **would have returned
> `false` for 100% of real `sb_admin` users, on every tenant, permanently.** SBDEV-2732's review round
> proved it on two independent grounds:
> 1. **`sb_admin` is carried in the JWT via the Keycloak GROUP — the `groups` claim** (confirmed with
>    the ticket owner 2026-08-11). ~~**Group membership does not appear under `resource_access` at all**,
>    so a `resource_access` lookup cannot see it, regardless of which client is named.~~
>    🔴 **THIS SENTENCE IS FALSE — measured 2026-08-26; see the correction box below ground 2.**
>    `sb_admin` DOES appear under `resource_access[om1-api].roles`, bare. The client named is exactly
>    what matters. The API knows
>    this: `JwtAccessTokenCustomizer.extractRoles` harvests `GROUP_ELEMENT_IN_JWT = "groups"` at `:98`
>    *in addition to* iterating every client under `resource_access` (`.elements()`, not one client).
> 2. Even setting that aside, `$config.keycloak.clientId` is the build-wide `KEYCLOAK_CLIENT`, while
>    the token is issued by the **per-tenant** client from tenant discovery
>    (`plugins/keycloak.client.js` ← `tenant_discovery.client_id`). Two independent sources on one
>    deployment serving every tenant hostname — **wrong by construction**, not merely fragile.
>
> 🔴 **CORRECTED 2026-08-26 by a live token probe — ground 1 above is FALSE, and it matters because
> it points at the wrong repair.** Measured on `kc2.dev.sbo.li` / realm `wineco` / client `om1`
> (password grant, JWT decoded) for `panderson`, a real `sb_admin`:
>
> ```
> groups:                         ['/sb_admin', '/wms_admin', '/wms_user', '/warehouse/wsl']
> resource_access[om1-api].roles: ['wms_admin', 'sb_admin', 'wms_user']    <-- sb_admin IS here, BARE
> ```
>
> Group membership **does** appear under `resource_access` — Keycloak emits each group as a bare
> client role on `om1-api`, and that bare copy is the one `hasAuthority('sb_admin')` matches (the
> `groups` entry keeps its full path `/sb_admin` and matches nothing). Nam, 2026-08-26: *"Keycloak
> group `/sb_admin` IS the `sb_admin` role within the WMS app; the WMS token decoder does that role
> mapping from the token."*
>
> **The CONCLUSION stands — the original gate did return `false` for every real `sb_admin` — but the
> CAUSE is ground 2 alone:** `$config.keycloak.clientId` is `om1` (the auth client) while the roles
> live under **`om1-api`**. So `hasResourceRole` is not blind to `sb_admin` in principle, and anyone
> repairing a gate like this must fix the **clientId**, not the claim it reads. Full probe: role
> matrix §2.1's precondition box.
>
> ⚠ Ground 2 is therefore the *whole* reason, not a belt-and-braces second argument. The phrase
> "regardless of which client is named" in ground 1 is the specific sentence to disbelieve.
>
> r6's own warning ("ops must confirm `KEYCLOAK_CLIENT` equals `om1-api` per environment") framed this
> as a configuration risk. It was not: no configuration value would have made it work.

**The gate is 2732's shared helper. 2643 does not write a third role reader.**

`util/keycloakRoles.js` (merged with 2732 step 20) exists precisely because this went wrong once in
shipped code — a genuine `sb_admin` reloading onto the Operation Options tab got a permanently disabled
control. It **mirrors `JwtAccessTokenCustomizer.extractRoles`** deliberately, and its header names that
Java method as the source of truth to keep in step.

```js
// skuData.vue — and nowhere else in 2643; the dialog gets the gate from the shared field component.
import { resolveSbAdmin } from '@/util/keycloakRoles'

data() {
  return { isSbAdmin: false }   // ⚠ reactive DATA, never a computed — see below
},

async mounted() {
  this.isSbAdmin = await resolveSbAdmin(this.$kc)
},
```

> [!warning] **A `computed` here is broken, and this is the second half of 2732's fix — not a style
> preference.** `$kc` is a plain injected object (`inject('kc', …)`) whose getters read a closure
> variable that is `null` until the **fire-and-forget** `initKeycloak()` resolves. So a computed over
> `$kc` has **zero reactive dependencies**: Vue 2 evaluates it once, caches `false`, and never
> re-evaluates. `resolveSbAdmin` awaits `$kc.ready`, which settles on **any** terminal state —
> authenticated, redirected-to-login, or errored (SBDEV-2554) — so it cannot hang.
>
> Verify row **`B1-perm`** now asserts reactive data + the awaited resolver. It previously asserted an
> `isPutawayConfigAdmin` **computed**, i.e. **it would have enforced the defect.**

Applied as **`:disabled` plus a tooltip**, on the pencil button and the dialog's Submit —
**never `v-if`**. The ticket says read-only users **may view** the configured value; hiding the field
would fail AC1 for them, and hiding the button hides the fact that the capability exists.

**This gate is defence-in-depth only.** The real boundary is `PutawayConfigService`'s `@PreAuthorize`
(2732 N5 / §3.12: *"the security boundary is the backend, and it is enforced in `PutawayConfigService`,
not on the event-handler methods"*) — and that boundary is ~~**inoperative until A0 lands** (F1)~~
**operative as of SBDEV-2863 `675b4a1` (2026-08-07)**, which repaired the constant those annotations
carry. Saying so explicitly is what keeps AC12 *explicitly* met by backend enforcement rather than
*implicitly* unmet.

---

## 4. File Change Summary

**`v2/wms2-api`**

**Files 2643 writes into that SBDEV-2732 owns — in `wms2-api`: ZERO. In `wms2-web-ui` (r7): TWO, on
purpose.**

- **`wms2-api` — TWO as of r7 (was zero), both in the new Phase A4.** `PutawayConfigController` and `PutawayDestinationQueryService` gain the `name` search parameter (§3.5a). ⚠ **This one was assigned to 2643 by 2732 in writing** — its Q2 close hands the remedy to "SBDEV-2643 Phase B2 as a parameter on `eligibleLocations`" — so it is delegated scope, not a boundary breach. `describeForSku` still goes in **2643's own** `SkuPutawayQueryService`, never into 2732's facade (verify `A2-neg-2732f`, still live). The r1 breaches remain forbidden: r1 had four (a
  security-annotation swap in two of them, a method added to a third, `blockingReason`/`advisory`
  mutations in a fourth) — r2 removed all four and r7 does **not** reinstate any of them (§15).
- **`wms2-web-ui` — r7 adds two**, both in Phase B2:
  `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue` (the `SKU:` writer
  entry + the confirm-skip branch) and `store/admin/configuration.js` (`setSkuPutawayDestination`, and
  the SKU-scope effective read). **Rationale, cost and the amendment to §14 principle 1 are in §3.8's
  opening box** — in short: 2732 is merged so there is no PR to collide with, the component was written
  to be reused at SKU scope, and refusing to touch it means shipping a second confirmation gate.
- ~~"Only the A3 **fallback** rows touch a 2732 file"~~ — **A3 is deleted** (r6), so that sentence no
  longer describes anything.

| File | Change | Phase | Description |
|---|---|---|---|
| ~~`src/test/java/net/aim_ai/wms/unit/CustomMethodSecurityExpressionRootUnitTest.java`~~ | ~~Modify~~ **REMOVED r5** | ~~A0~~ | **SBDEV-2863 `675b4a1` already added the `@Nested` SpEL-evaluation class. 2643 touches this file not at all.** |
| `src/main/java/net/aim_ai/wms/service/ItemdataService.java` | **Modify** | A1 | `getItemdataDetails` `:166-171` → emit `putawayLocationId` unconditionally when non-null (§3.3) |
| `src/test/java/net/aim_ai/wms/unit/service/ItemdataServiceUnitTest.java` | **Modify** | A1 | 4 cases: `:415-428`, `:468-471`, `:475-498` (rewritten), `:585-604` |
| `src/main/java/net/aim_ai/wms/service/SkuPutawayQueryService.java` | **Add** — **2643-owned** | A2 | `describeForSku(Long)`, `@Transactional(value="tenantTransactionManager", readOnly=true)`, injecting 2732's `PutawayDestinationResolver` (§3.2). ⚠ **r2: replaces r1's "add a method to `PutawayDestinationQueryService.java`"** |
| `src/main/java/net/aim_ai/wms/controller/ItemDataController.java` | **Modify** | A2 | new `GET /{id}/effectivePutawayDestination` + `toEnvelope`; constructor gains `SkuPutawayQueryService` (11→12 args) |
| `src/main/java/net/aim_ai/wms/controller/PutawayConfigController.java` | **Modify** — ⚠ **2732-owned (r7)** | A4 | `eligibleLocations` gains `@RequestParam(required = false) String name` (§3.5a). **Assigned to 2643 by 2732's own Q2 close** |
| `src/main/java/net/aim_ai/wms/service/PutawayDestinationQueryService.java` | **Modify** — ⚠ **2732-owned (r7)** | A4 | ⚠ **AS BUILT: a 4-arg overload that BRANCHES between two repository queries** — the contains-filter itself lives in `LocationRepository` (row below), not here. The earlier wording "the filter applied inside the candidate query" named the wrong layer once the split-query design landed. Empty/null/whitespace `name` is normalised here and routed to the untouched query; tiers 2/3 depend on that |
| `src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java` | **Modify — ADD ONLY** ⚠ **2732-owned** | A4 | ⚠ **ADDED to this table 2026-08-12 — A4's third API file was missing from it.** New sibling `findPutawayCandidatesByName` carries `LOWER(l.name) LIKE LOWER(CONCAT('%', :nameFilter, '%'))` in **both** the `value` and the `countQuery`, JPQL not native (H2 lane). The existing `findPutawayCandidates` is **left byte-identical** — that is the R11 guarantee (§0 row 89) |
| `src/test/java/net/aim_ai/wms/unit/controller/ItemDataControllerUnitTest.java` | **Modify** | A2 | fix the constructor call at `:91-102`; append a **NEW** `@Nested EffectivePutawayDestination` class at EOF (`:374`). **Do NOT touch `:119-158`** — 2732 Step 9 owns it |
| `src/test/java/net/aim_ai/wms/unit/service/SkuPutawayQueryServiceUnitTest.java` | **Add** | A2 | `describeForSku` delegation + the two transaction-annotation assertions |
| `src/main/java/net/aim_ai/wms/service/PutawayDestinationQueryService.java` | **unchanged** | — | 2732's file. `describeForSku` deliberately does **not** land here (§3.2); `A2-neg-2732f` asserts it |
| `src/main/java/net/aim_ai/wms/controller/PutawayConfigController.java` | **unchanged in the plan of record** | *A3 fallback only* | `GET /eligibleLocations` (§3.5) — **2732's to write** (D12). Touched by 2643 only if 2732 declines |
| `src/main/java/net/aim_ai/wms/service/PutawayConfigService.java` | **unchanged in the plan of record** | *A3 fallback only* | eligibility evaluation delegating to `PutawayDestinationValidator`; JPQL only, H2-safe. Same condition |
| `src/test/java/net/aim_ai/wms/unit/controller/PutawayConfigControllerUnitTest.java` | **unchanged in the plan of record** | *A3 fallback only* | `?scope=SKU` returns eligible / not-offered; the tier-4 lane is excluded; a fix-assigned destination stays blocked — ⚠ **but as `BOUND_TO_ANOTHER_SKU` since 2026-08-11, not `FIX_ASSIGNED`** (2732 step 18a re-mapped both rule-(f) keys; see §3.5) |
| — | **no `blockingReason` enum change** | — | **r2: `PICK_FACE` is NOT added.** D1 reversed ⇒ no 2643-specific reason code exists (MUST-4) |
| — | **no migration** | — | **2643 ships zero SQL** |

**`v2/wms2-web-ui`**

| File | Change | Phase | Description |
|---|---|---|---|
| `components/masterData/material/skuData/putawayWording.js` | **Add** | B1 | `DEFAULT_PUTAWAY_LANE_NAME` / `_LABEL` extracted from `receivingForm.vue:296-297` ⚠ **(was `:221-222` until 2026-08-12 — SBDEV-2732 PRs #50/#51 added ~100 lines to that file; names and values unchanged, so the extraction is unaffected. Re-grep the symbols, do not trust the line numbers)** (§3.7) |
| `components/receiving/open/receive/receivingForm.vue` | **Modify** | B1 | import the two constants from the shared module instead of declaring them at `:221-222`. **No behaviour change** — 2731's tri-state and comparisons are untouched |
| `components/masterData/material/skuData/skuData.vue` | **Modify** | `B1-pre` + B1 | **`B1-pre` (ships FIRST, alone):** `:130` `exclude-fields` += `'putawayLocationId'`. **B1:** `:142` relabel → `'Default Putaway Location'`; pencil button at `:95-99`; `#actions` slot button in `<full-details>`; **delete** `:100-123`; ⚠ **r7: `isSbAdmin` reactive data + `await resolveSbAdmin(this.$kc)` in `mounted()` — NOT an `isPutawayConfigAdmin` computed** (§3.11); mount the dialog |
| `components/masterData/material/skuData/editSkuPutawayDialog.vue` | **Add** — **THIN (r7)** | B2 | dialog chrome, the effective-value line, the r7 **scope banner** (routed-via-putaway + consequence, §3.8.2a), and `<default-putaway-location-field scope="SKU">`. ⚠ **Does NOT contain:** the picker, the preview gate, the `blockingReason` map, a `validated()` idiom, or a write |
| `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue` | **Modify** — ⚠ **2732-owned (r7)** | B2 | `SKU: 'admin/configuration/setSkuPutawayDestination'` in `writeActionForScope`; the `scope === 'SKU'` branch in `save()` that **skips D11's confirm**; a `subjectId == null` guard mirroring MERCHANT's. §3.8 / §14 principle 1 |
| `store/admin/configuration.js` | **Modify** — ⚠ **2732-owned (r7)** | B2 | `setSkuPutawayDestination` → `PUT /putawayConfig/sku/{itemdataId}` (clear **omits** `locationId`; surfaces `response.data`; sends **no** `confirmIncompatibleSkus`), and the SKU-scope effective read on the **`/itemData/{id}/`** path. Placed beside its tier-2/tier-3 siblings |
| ~~`store/masterData/skuData.js`~~ | **unchanged (r7)** | — | ~~`setSkuPutawayLocation` + `getSkuEffectivePutaway`~~ — **moved to `store/admin/configuration.js`.** ⚠ Must NOT gain an `eligibleLocations` reader: 2732's is the only one (verify `B2-one-elig`). May keep `getSkuDetail` for the read-after-write refetch |
| `test/components/masterData/material/skuData/skuData.spec.js` | **Add** | B1 | Edit affordance, exclude-fields, relabel, permission gate — incl. **the enabled-after-hard-reload case** (the non-reactive-computed defect) |
| `test/components/masterData/material/skuData/editSkuPutawayDialog.spec.js` | **Add** | B2 | `scopeBannerStatesRoutedViaPutaway`, `scopeBannerStatesConsequence`, `scopeBannerCountIsComputedNotLiteral`; the wrapper is mounted at `scope="SKU"`; **no** raw `LocationPicker` |
| `test/store/admin/configuration.spec.js` | **Modify** | B2 | the SKU write hits `PUT /putawayConfig/sku/{id}`, never the legacy GET; Clear omits the param; no `confirmIncompatibleSkus` |
| `test/components/admin/parametersAndConfiguration/**` | **Regression** | B2 | ⚠ **r7 obligation:** the wrapper serves three scopes — prove WAREHOUSE and MERCHANT still write correctly after the SKU change (§5.7 testing row) |
| `components/common/fullDetails.vue` | **unchanged** | — | the `#actions` slot at `:26` already exists |
| `plugins/persistedState.client.js` | **unchanged** | — | §3.8.5 — the overlay always refetches, and there is no table column |

---

## 5. Phased Implementation Plan

**Five** phases across two repos — **A0 retired r5** (SBDEV-2863), **A3 deleted r6** (2732 owns D-D), and
**A4 ADDED r7** (Q4 → (ii): the `name` search parameter 2732 assigned to 2643, §3.5a).
Remaining: **`B1-pre` → A1 → A2 → A4 → B1 → B2.**

> [!done] **r7: ALL FOUR ARE IMPLEMENTABLE TODAY.** Every external prerequisite is merged, so the only
> ordering constraints left are 2643's **own**: `B1-pre` before A1 (§5.1 row 4 — a hard gate, because DEV
> auto-deploys on push and A1-without-`B1-pre` renders a stray raw-integer row on every SKU details
> overlay), and A2 before B2 (B2 reads the effective destination A2 exposes).
> ~~"A2, A3, B1 and B2 are not [implementable]"~~ — that was true at r6 and is false now.

### 5.1 Prerequisites — MANDATORY

Every row is required. `N/A` carries a one-sentence rationale.

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| **0** | **External dependency — SBDEV-2732 Phase 1-API merged to `develop`** | The resolver, `Resolution` + `Source`, `PutawayDestinationQueryService`, `PutawayDestinationValidator` (P1 + P2), `PutawayConfigService.setSkuDestination`, `PutawayConfigController`, `putaway_config_audit`, `V2.2.13`, stop-seeding, `@NotNull` removed from `Itemdata.java:49`. ✅ **SATISFIED 2026-08-11 — merge `889298d`** (+ review commit `0837289`). Every construct re-verified by symbol grep on `origin/develop`; `Itemdata.putawaylocationId` no longer carries `@NotNull`; `V2.2.13` is on develop | 2732 ✅ | ~~HARD BLOCKER on A2, A3, B2~~ — **NOTHING IS BLOCKED (r7).** A2 unblocked at r6; **B2 unblocked 2026-08-11** when 2732 Phase 2 merged in full. **A3 is deleted** (row 0d). Branch from `origin/develop` at or after `e702a42` (web) / `bcfdc47` (api), never from a 2732 feature branch (§8.1) — several are still lying around locally |
| **0b** | **External dependency — SBDEV-2732 Phase 2-UI merged** (`components/common/LocationPicker.vue`), **and 2732's acceptance of §3.8.2b's props/events spec** | Q7 → strict reuse, so B2 waits for the component. ⚠ **2732 specifies its behaviour but NOT its props/events API** — no prop list, no event list, no `v-model` contract in 2732 §3.11.2, §3.11.3 or Step 19. **r2 writes that spec (§3.8.2b) and hands it over.** ACCEPTANCE ITEM: 2732's author confirms `:items` / `:value` / `:disabled` / `item-text` / `item-value` + `@input` / `@select`-emits-the-full-row, or returns a counter-spec | 2732 ✅ | ✅ **FULLY SATISFIED — r7.** Q6 closed 2026-08-11 (contract adopted **verbatim**: `value` / `items` / `disabled` / `item-text` / `item-value`, `@input` + `@select`-emits-the-full-row, plus a server-supplied `tier`), and **the component now EXISTS on develop** (`components/common/LocationPicker.vue` + `test/components/common/locationPicker.spec.js`, 2732 step 19, merge `9edb743`). Verified against the shipped file, not just the plan text. **B2 is unblocked.** ⚠ **And the reuse target went further than this row anticipated:** 2732 also shipped `defaultPutawayLocationField.vue`, so B2 consumes the **wrapper**, not the raw picker — §3.8. The R5 risk this row managed is closed twice over |
| **0c** | ~~External dependency — SBDEV-2863~~ **✅ SATISFIED 2026-08-07** | SBDEV-2863 **merged** — PR #134, `675b4a1` + `d8e0137`, merge `7d9d38e`, ClickUp `on dev`. It repaired the constant **and** shipped the SpEL-evaluation detector, so **2643's Phase A0 is retired entirely** (r5) | 2863 ✅ | **Nothing to pull forward and nothing to wait for.** F1 is closed for 2732 as much as for 2643. The only surviving obligation is the regression guard `X-authz-constant` in the verify script |
| ~~**0d**~~ | ~~Ownership decision — who ships D-D (`GET /putawayConfig/eligibleLocations`)?~~ **✅ RESOLVED 2026-08-11 — 2732 ACCEPTED IT** | **2732 owns it**, as its r-next **§3.11.0 / step 18a**. §3.5's specification was adopted, and 2732 extended it with a server-computed `tier` field and a bulk-evaluation design (**5 queries, not 2,739 × `validate()`** — `isUnitloadTypePermitted` is keyed on `location.type_id`, 8 distinct values, so the fan-out is tiny) | 2732 ✅ | **D12 confirmed in writing. §5.1's decision deadline is met and Phase A3 is DELETED** (§5.5). 2732 also confirmed the diagnosis: its own Step 19 was **unimplementable** as written, because `getLocationView()` (`ViewDtoService.java:806-832`) exposes none of the predicate columns. 2643 is now a pure **consumer** of that endpoint |
| ~~**0e**~~ | ~~SBDEV-2732 must NOT merge carrying `@PreAuthorize(Authority.IS_SB_ADMIN)`~~ **✅ DISCHARGED 2026-08-09 — and it was resolved by *repair*, not by avoidance** | SBDEV-2863 repaired the constant on 2026-08-07 (`Authority.java:44` → `hasAuthority('sb_admin')`), so **2732's annotation is now the correct one.** 2732 §3.12 keeps `Authority.IS_SB_ADMIN` at all six sites (`:905, 917, 925`, `:1491`, `:972, 978, 985`) **unchanged** — no swap to `getExpForRole(...)` is needed or wanted | ✅ closed | ⚠ **The old detector was worse than stale.** `X-2732-authz` asserted the *absence* of `@PreAuthorize(Authority.IS_SB_ADMIN)` from `PutawayConfigService` — it would have gone **red against a correct SBDEV-2732** and read as "2732 must not merge". **Replaced by `X-authz-constant`**, which guards the repair itself, runs today, and was negative-tested against pre-fix `6bc709a`. **M8 now expects 403; a 500 means SBDEV-2863 regressed, not that 2732 mis-merged** |
| 1 | **Database state** | **No change required and none made. 2643 ships ZERO migrations.** **Flyway head on `origin/develop` is now `V2.2.13`** (was `V2.2.10`; `V2.2.12` also landed via PR #137) | — | ⚠ **r6 — the A1 caveat is GONE and the AC4 gate is HALF-MET.** `V2.2.13` merged **and** applied to `wms2-wineco-dev` on 2026-08-11 13:50:50, so `putawaylocation_id` is now `NULL`-able there and `Itemdata.java` no longer carries `@NotNull`. **AC4 + AC9 are reachable on wineco-dev.** They are **NOT** reachable on `wh01_hydra_v2` — it has no `flyway_schema_history`, so the boot migrator skips it entirely and `V2.2.13` will never self-apply; that tenant currently throws `42703` on every `client` read. Operator fix: `db/backfill-flyway-history.sh` ⚠ **CORRECTED 2026-08-11 on the ticket owner's information: `wh01_hydra_v2` is INACTIVE on DEV.** The only active DEV tenant is WineCo's `dev_wh01_om1`. `StartupFlywayMigrator` iterates ACTIVE tenants only, so an inactive DB is never migrated and never served — there is no `42703`, and no operator repair is owed. Everything below about backfilling its Flyway history is MOOT for DEV. It would matter only if that tenant were reactivated., then migrate |
| 2 | **Feature flags / system properties** | **N/A** — 2643 introduces no toggle and reads none. It inherits 2732's `DEFAULT_PUTAWAY_LOCATION` sysprop transitively through the resolver and never touches it directly | — | Rationale recorded so the empty row reads as a decision |
| 3 | **Config / env changes** | **NONE — and r7 removes the last ops item this row carried.** ⚠ **`APP_ADMIN_GROUP` IS NOT USED BY WMS V2 ANY MORE** (vestige at `nuxt.config.js:167` and `CLAUDE.md:70`; nothing reads it or `appGroup`; 2732 §3.12 concurs). ⚠ **AND r6's replacement was ALSO wrong** — see §3.11 | ✅ closed | **The gate is 2732's shipped helper: `resolveSbAdmin` from `util/keycloakRoles.js`, assigned to reactive data in `mounted()`.** r6 specified `$kc.hasResourceRole('sb_admin', $config.keycloak.clientId)` on the theory that `sb_admin` is a resource role on `om1-api`; **it is delivered via the Keycloak GROUP, i.e. the `groups` claim, which never appears under `resource_access`** — so that form was false for **every** real `sb_admin`, permanently, on every tenant. **r6's ops action item ("confirm `KEYCLOAK_CLIENT` equals `om1-api` per environment") is WITHDRAWN: no value of `KEYCLOAK_CLIENT` would have made it work,** and `$config.keycloak.clientId` is a build-wide env var while the token comes from per-tenant discovery. **Nothing is owed to ops.** Manual row **M7** rewritten again |
| 4 | **Deploy-order dependencies — `B1-pre` is a HARD PREREQUISITE OF A1** | **`B1-pre` (one line: `'putawayLocationId'` added to `skuData.vue:130`'s `exclude-fields`) MUST be merged and deployed BEFORE A1 merges.** Not "prefer that ordering" — **required.** Then **A2 → B2** (and A3 → B2 only under the fallback). No OMS dependency, no `oms-laravel-api` dependency | author | ⚠ **r2 upgrades this from permission to gate.** The line is a **provable no-op today** — `exclude-fields` naming a key the payload does not yet carry changes nothing — so there is no cost to landing it first and no reason to accept the alternative. The alternative is not hypothetical: **DEV auto-deploys on push**, and §6.1 predicts that A1-without-B1-pre renders a stray `PutawayLocationId` raw-integer row on **every** SKU details overlay within minutes. Deploying a known user-visible cosmetic defect because the fix was optional is not a tradeoff, it is an avoidable one. **M2 is a pre-B1-pre *observation* of the hazard (run it on a local build or a branch preview), not a licence to ship A1 alone to DEV.** §8 rollout step 2 |
| 5 | **Data migration** | **N/A** — no backfill, no one-off SQL, no DBA task. 2732's `V2.2.13` carries the only backfill in this feature family, and it is scoped inside that migration | — | |
| 6 | **External systems** | **N/A** — no OMS notification, no outbox row, no printer, no Keycloak realm or client change. Explicitly: a putaway-config change must **not** trigger an inventory export (verify row `A2-neg-oms`) | — | |
| 7 | **Access / permissions** | `@PreAuthorize(Authority.IS_SB_ADMIN)` — which **now renders `hasAuthority('sb_admin')`** since SBDEV-2863 `675b4a1`, so the constant and the `getExpForRole(...)` form are the same string and either spelling is correct. **No new Keycloak role and no new group** — `sb_admin` already exists (`Authority.java:17`). `GET /{id}/effectivePutawayDestination` is deliberately **not** admin-gated: it is a read, and the ticket requires read-only users to see the value | author | The `/v3/**` → `hasAnyAuthority("wms_user")` rule (`SecurityConfiguration.java:143`) must **not** be widened. ~~A0 must land before any write path claims to be gated~~ — **A0 is retired; the gate is already operative on `develop`** |
| 8 | **Monitoring / alerts** | **2643 adds no metric.** It inherits 2732's `PutawayResolutionMetrics`. Ops must add a panel for **`wms2.putaway.resolution{source="SKU_OVERRIDE"}`** — the only correct adoption detector for *this* ticket | author + ops | ⚠ **2732 §8.1 (`:2293`) makes non-zero tier-2/3 usage a condition for closing 2643.** That is the wrong signal for a SKU-tier ticket: `MERCHANT_OVERRIDE`/`WAREHOUSE_DEFAULT` counters can stay at zero forever while 2643 works perfectly. **Raise at review; 2643's closure gate should be `resolution{source="SKU_OVERRIDE"} > 0`** |
| 9 | **Deadlock-retry hardening — is the deferred *"stock-move deadlock-retry hardening"* ticket a prerequisite of 2643?** | **NO — and this row exists so that nobody re-adds it.** 2732 `:2308`(i) makes that ticket *"an **absolute** prerequisite before **Q9 widens P2.4 to admit pick locations**"*, and 2732 **Q9** (`:2561`) answers **No** to that widening. **r1's D1 did precisely what Q9 declines, for the same physical reason**, so r1 inherited the price — and answered it with a UI banner, which is not retry infrastructure. **r2's D1 widens nothing:** the eligible set is 2732's own 92, P2.7(c) is enforced, and 2643 arms no path 2732 has not already accepted | — | ⚠ **What DOES remain is 2732's *own* accepted risk, unchanged by 2643.** `:2308`(i)'s **first** clause makes the deadlock ticket a prerequisite *"before any tenant points tier 2 or tier 3 at a live storage location"*, and the `useforstorage` advanced tier lets an operator point a **SKU** at one. **2643 inherits that as 2732's condition, not as a new one**, and mitigates it exactly as 2732 requires: the picker defaults to `useforgoodsin`, storage sits behind the toggle + lock warning (2732 `:1607`, §3.5), and the log-based `40P01` detector (§7.7) stays. See §7.4 row 8 |

### ~~5.2 Phase A0 — the SpEL detector (`wms2-api`)~~ — **RETIRED r5 (2026-08-09). DO NOT IMPLEMENT.**

> [!done] **Delivered in full by [SBDEV-2863](https://app.clickup.com/t/868knmx18), merged 2026-08-07.**
>
> PR #134 (`675b4a1` fix + tests, `d8e0137` docs, merge `7d9d38e`) added `@Nested
> AuthorityExpressionsResolve` to `CustomMethodSecurityExpressionRootUnitTest` — the detector this
> phase specified — **and** repaired `Authority.java:44` in the same commit. Every goal below is met on
> `origin/develop`. Building it now would duplicate a passing test.
>
> **Note what 2863's version does that this phase's spec did not:** it evaluates through the real
> `CustomMethodSecurityExpressionHandler` rather than a hand-built root, which wires `trustResolver`
> and `permissionEvaluator`. A hand-built root NPEs on `isAuthenticated()` / `hasPermission(...)`, so
> the spec below would have produced a test that goes red on correct code the first time anyone wrote
> `@PreAuthorize("isAuthenticated()")` — and would then have been weakened or deleted. 2863 guards
> against that explicitly with a `harnessSupportsBuiltInExpressions` self-test.
>
> Original specification, retained for provenance only:

| Aspect | Detail *(historical — not a deliverable)* |
|---|---|
| **Goal** | the F1 defect class becomes **detectable**, before 2732 builds a security boundary on it |
| **Changes** | §3.1's detector **only**: a new `@Nested` class in `CustomMethodSecurityExpressionRootUnitTest` that **evaluates** the SpEL string against a real `CustomMethodSecurityExpressionRoot` |
| **Testing** | `mvn test -Dtest=CustomMethodSecurityExpressionRootUnitTest`. ⚠ **This row's negative test is now inverted and must not be run as written** — it says to assert `Authority.IS_SB_ADMIN` resolves and confirm a **FAIL** with `EL1004E`. It resolves fine today; that assertion would pass, and reverting it would delete a correct test |
| **Risk** | **NONE — test-only, zero production bytes, zero blast radius** (§8.2 row 1) |
| **Branch** | ~~`fix/SBDEV-2643-A0-sb-admin-spel`~~ — never cut |
| **Effort** | ~~0.5 d~~ — **0 d, reclaimed** |

### 5.3 Phase A1 — `putawayLocationId` in the details payload (`wms2-api`)

| Aspect | Detail |
|---|---|
| **Goal** | the UI can pre-select the configured value, and "invalid" becomes distinguishable from "inherits" |
| **Changes** | §3.3. `ItemdataService.getItemdataDetails` `:166-171`; four `ItemdataServiceUnitTest` cases |
| **Testing** | `mvn test -Dtest=ItemdataServiceUnitTest` + `mvn clean compile`. **Mutate-then-check** each new assertion: flip the production line, confirm the test fails, restore |
| **Risk** | **LOW code, MEDIUM deploy.** 15 call sites consume the widened payload (§6.2); 12 of them are provably safe, 3 need the `exclude-fields` companion. R4 (§11.0). ⚠ **HARD-GATED on `B1-pre` being deployed first** — §5.1 row 4 |
| **Branch** | `feature/SBDEV-2643-A1-itemdata-details-putaway-id` |
| **Effort** | 0.5 d |

### 5.4 Phase A2 — the effective-destination read (`wms2-api`)

| Aspect | Detail |
|---|---|
| **Goal** | one server-side answer to "where does this SKU actually go, and is it compatible?" |
| **Changes** | §3.2 (D-A) + §3.4 (D-B). **NEW 2643-owned `service/SkuPutawayQueryService.java`** — r2 no longer edits 2732's facade. New `@Nested EffectivePutawayDestination` appended to `ItemDataControllerUnitTest`; new `SkuPutawayQueryServiceUnitTest`. ⚠ **No constant swap** — row 0e is discharged (SBDEV-2863 repaired it); A2 simply must not admin-gate the read (verify `A2-neg-badconst`, §3.4) |
| **Testing** | `mvn test -Dtest=ItemDataControllerUnitTest` and `-Dtest=SkuPutawayQueryServiceUnitTest`. ⚠ `-Dtest='Outer#method'` **silently no-ops for `@Nested`** — name the nested class. Plus `mvn clean compile` for the 12-arg constructor |
| **Risk** | **MEDIUM (was HIGH in r1).** r2 removes the two coupling sources that made it HIGH: the method-into-2732's-file and the security-annotation swap. What remains is a **type-level** dependency on `Resolution` / `PutawayDestinationResolver` — a compile error if 2732 reshapes them, not a three-way merge (R1 ↓, R2 unchanged: the test file collision at `ItemDataControllerUnitTest` is real and mitigated by the new nested class). **Re-verify every §3 contract against 2732's merged PR before writing a single test** (R5, §3's banner) |
| **Branch** | `feature/SBDEV-2643-A2-sku-effective-putaway` — **branched from 2732's Phase-1 MERGE COMMIT on `develop`, never from 2732's branch** (§8) |
| **Effort** | 1.5 d — **UNBLOCKED as of 2026-08-11**, 2732 Phase 1-API is on `develop` at `889298d` |

### ~~5.5 Phase A3 — the eligible-locations read (`wms2-api`)~~ — **DELETED r6 (2026-08-11). DO NOT IMPLEMENT.**

> [!done] **2732 accepted D-D on 2026-08-11.** Its r-next **§3.11.0** adopted §3.5's specification and made
> it 2732 **step 18a**, extending it with a server-computed `tier` field and a bulk-evaluation design
> (5 queries, not 2,739 × `validate()`). The decision deadline in §5.1 row 0d is met, the fallback did not
> fire, and **1.5 d is reclaimed.** 2643 is a pure consumer: its `A3-*` consumer rows still grade against
> its own files, and the contract rows grade whoever shipped the endpoint (§13). Original specification
> retained below for provenance only.

| Aspect | Detail |
|---|---|
| **Status** | ⚠ **CONDITIONAL.** D-D is **specified in §3.5 and handed to 2732** (D12, §5.1 row 0d). A3 exists only for the case where 2732 declines. **Decision deadline: before A3's TDD gate opens.** Expected outcome: **A3 is a 0-day phase** |
| **Goal** | the picker offers exactly the right locations, evaluated once, server-side |
| **Changes** | §3.5 (D-D). `GET /v3/putawayConfig/eligibleLocations`, the two-class response (eligible / not-offered), the tier-4-lane exclusion. ⚠ **r2: no `advisory` field, no `PICK_FACE` reason** — both were D1's apparatus |
| **Testing** | `mvn test -Dtest=PutawayConfigControllerUnitTest` + a service-level case per predicate. **JPQL only** — H2-safe (§7.3 row 7) |
| **Risk** | **MEDIUM.** Under the fallback, 2643 writes an endpoint into 2732's controller and a query into 2732's service — the largest cross-plan write surface remaining anywhere in the plan, which is itself an argument for the hand-over. **The verify script does not assert 2643's authorship of these constructs** (§13's A3 note): the contract rows run whoever ships them, and the consumer rows are what 2643 is accountable for |
| **Branch** | `feature/SBDEV-2643-A3-eligible-locations` (only if the fallback fires) |
| **Effort** | 1.5 d — **0 d if 2732 absorbs it, which is the expectation** |

### 5.5a Phase A4 — the `name` search parameter (`wms2-api`) — **NEW r7**

| Aspect | Detail |
|---|---|
| **Goal** | the SKU picker searches server-side, so opening the dialog is **one** request instead of 13 |
| **Changes** | §3.5a. `PutawayConfigController.eligibleLocations` gains `@RequestParam(required = false) String name`; `PutawayDestinationQueryService.eligibleLocations` gains the parameter and **branches** to a new sibling repository query `LocationRepository.findPutawayCandidatesByName` that applies a case-insensitive **contains** on `location.name` **inside the query** — the existing `findPutawayCandidates` is left untouched (see §3.5a's implementation box for why a split beats a parameterised query here). ⚠ **`store/admin/configuration.js` is NOT in this PR** — A4 is API-only; the reader change rides with **B2**, its only consumer |
| **Testing** | `mvn test -Dtest=PutawayConfigControllerUnitTest,PutawayDestinationQueryServiceUnitTest` (⚠ **comma, not `+`** — the `+` form matched nothing and reported `Tests run: 0` under `-DfailIfNoTests=false`, a false green this plan hit for real) + `mvn clean test`. ⚠ **The load-bearing case is the EMPTY search**, and the honest form of that assertion is *"the filtered query is never reached"*, not *"the rows come back the same"* — see the note below |
| **⚠ What a mocked test can and cannot prove here** | Once the predicate is in the DATABASE, **no mocked-repository test can witness narrowing or case-insensitivity** — a correct service returns exactly what the stub hands back. The gate's original `nameFilterNarrowsThePage` / `nameFilterIsCaseInsensitive` were therefore unsatisfiable by a correct implementation and satisfiable only by the service-side `stream().filter()` this phase exists to remove. They were **reshaped, not weakened**, into: blank ⇒ filtered query never called; non-blank ⇒ filtered query called with the trimmed verbatim term **and the unfiltered one never called**; and the case-insensitive contains asserted **against the `@Query` text itself**, which is a property of the shipped artifact rather than of a stub. 6 tests, all green; the three mutations they were negative-tested against are listed in §7.5 |
| **Risk** | ⚠ **MEDIUM, and it is a shared-endpoint risk, not a tier-1 one.** `eligibleLocations` already serves 2732's WAREHOUSE and MERCHANT pickers. A predicate bug that narrows the **unfiltered** set silently shrinks those two pickers — an operator would see fewer legal destinations with no error. That is why the empty-search identity assertion is the first test, not the last. JPQL only (H2 lane, 2732's `P2A-h2`) |
| **Branch** | `feature/SBDEV-2643-A4-eligible-locations-name-search` |
| **Effort** | 0.5 d |

### 5.6 Phase B1 — the SKU screen surface (`wms2-web-ui`)

| Aspect | Detail |
|---|---|
| **Goal** | the edit affordance exists, the payload renders cleanly, wording is shared not copied |
| **Changes** | §3.7 + §3.8.1 + §3.11. `exclude-fields` += `'putawayLocationId'` (**ships separately as `B1-pre`, before A1** — §5.1 row 4); relabel `:142`; pencil at `:95-99`; `#actions` slot button; **delete `:100-123`**; ⚠ **r7: `isSbAdmin` reactive data + `await resolveSbAdmin(this.$kc)` in `mounted()`** — ~~`isPutawayConfigAdmin`~~ was a **computed**, which caches `false` forever because `$kc` has no reactive dependencies (§3.11); extract `putawayWording.js` and re-import into `receivingForm.vue` |
| **Testing** | `export PATH="$HOME/.nvm/versions/node/v24.15.0/bin:$PATH"` then `node_modules/.bin/jest test/components/masterData/material/skuData/skuData.spec.js --coverage=false`. **Re-run `receivingForm.spec.js`** — B1 edits that file's constant declarations |
| **Risk** | **LOW–MEDIUM.** Touching `receivingForm.vue` risks regressing 2731's just-merged display; its spec is the guard. The Edit button must be **disabled with a "coming soon" tooltip** if B1 ships before B2 |
| **Branch** | `feature/SBDEV-2643-B1-sku-putaway-surface` |
| **Effort** | 1 d |

### 5.7 Phase B2 — the edit dialog and the write (`wms2-web-ui`)

| Aspect | Detail |
|---|---|
| **Goal** | an authorized operator can set, change and clear a SKU's default putaway location |
| **Changes** | ⚠ **RESHAPED r7 — see §3.8's opening box. B2 EXTENDS 2732's `defaultPutawayLocationField.vue`; it does not build a parallel dialog.** Five deliverables: (1) `SKU:` added to that component's `writeActionForScope` map; (2) the SKU branch that **skips D11's confirm** (the endpoint takes no `confirmIncompatibleSkus`); (3) `setSkuPutawayDestination` in `store/admin/configuration.js` → `PUT /putawayConfig/sku/{itemdataId}`, beside its tier-2/tier-3 siblings; (4) a `subjectId == null` guard at SKU scope mirroring the MERCHANT one; (5) a **thin** `editSkuPutawayDialog.vue` — chrome, the effective-value line, the r7 scope banner, and the wrapper at `scope="SKU"`. Plus the itemData-path effective read, **the debounced server-side search box wired to A4's `name` parameter (§3.5a) — ⚠ the banner's counts must still come from the UNFILTERED first read, never from a search-narrowed `totalElements`**, and 2 Jest specs. **NOT built here:** the picker, the preview gate, the `blockingReason` map, the paginated accumulate, the clear-omits rule, 422 surfacing, the permission gate |
| **Testing** | the 2 new specs, `--coverage=false`. Copy the idiom from `test/components/receiving/open/receive/receivingForm.spec.js`: `shallowMount`, `@/` alias, a `mount*` helper hand-building `$axios` as `{ $get: jest.fn(url => …), $put: jest.fn() }` branching on `url.includes(...)`, and `$store` as a **plain object literal** with a nested `state` tree — no Vuex, no localVue. `jest.config.js` has **no `roots` key**. ⚠ **r7 adds a regression obligation:** the wrapper now serves three scopes, so the SKU change must not disturb WAREHOUSE or MERCHANT — run `test/components/admin/parametersAndConfiguration/` **and** `test/util/keycloakRoles.spec.js`, not just the two new files |
| **Risk** | ⚠ **DOWNGRADED HIGH → MEDIUM in r7, and the reason is not optimism.** Every external blocker is merged (2732 both phases, `LocationPicker.vue`, `eligibleLocations`, all 7 `BlockingReason` values, SBDEV-2863, SBDEV-2821), Q6's contract question is closed because the component exists and matches, and the surface area collapsed to five small deliverables. **The residual risk moved to a different place: B2 now edits a file three other screens render** (the Operation Options control, the edit/add param dialogs, the shipper screen). A mistake in `writeActionForScope` or the confirm-skip is a **tier-2/tier-3 regression**, not a tier-1 bug. That is why the testing row above adds the wrapper's own specs. ⚠ The scope banner's wording still wants a product read (Scott Dalton / David Oppenheim) — **and r7 changed what it says**, so the r2/r3 sign-off, if any was given, does not carry over |
| **Branch** | `feature/SBDEV-2643-B2-sku-putaway-dialog` |
| **Effort** | ⚠ **2.5 d → ~1.0 d for B2 itself** (four of the six things that made it 2.5 d are now merged code 2643 consumes) — **but the ticket total moved to ~1.5 d** because r7 added **Phase A4** (§5.5a, +0.5 d) when Q4 was answered as (ii). B2 now **depends on A4**: the picker's search box is server-backed |

### 5.8 Fallback if 2732 slips

`B1-pre` + A1 + B1 deliver AC1's configured-value display, the relabel, the shared
wording module, the permission computed, and the whole surface. **Do not ship a visible-but-dead Edit
button.** Either hold B1 with A1 and ship the UI as one coherent change once B2 is unblocked, or ship B1
with the button `disabled` and a tooltip naming the blocking ticket.

⚠ **`B1-pre` is not part of this fallback discussion — it is a prerequisite of A1 in every scenario**
(§5.1 row 4). r1 phrased this as *"shipping A1 alone is safe only if B1's `exclude-fields` line has
already deployed"*, which reads as a conditional permission. It is a gate: **A1 does not merge until
`B1-pre` is deployed.**

**The honest read of this section:** if 2732 slips indefinitely, 2643 ships ~6 lines of production code
(one `details.put`, one `exclude-fields` entry, one label, plus the B1 surface) and one test-only
detector. That is a real but small deliverable, and it is the *whole* of what 2643 can be held to before
2732 merges. Everything else in this document is either a consumer plan or a specification handed to
2732 — §14's principle 1, made explicit.

### 5.9 Implementation Checklist

- [ ] Re-fetch **both** repos and diff `develop..origin/develop` **per repo** before enumerating anything — the recorded process landmine from SBDEV-2781 (a local `develop` 11 commits stale made a plan's primary fix already-merged)
- [ ] **Re-derive §3.2, §3.4 and §3.5 from 2732's merged PR** — all three are `CONTRACT-PROVISIONAL`; see §3's blocking banner (R5). 2732's §12 changelog shows P2.5 flipped and reverted the same day, P2.7(c) becoming implementable only on 2026-08-06, and 2732's own D18 (`:103-106`) records no independent review pass
- [x] ~~A0 detector test; negative-test it against `Authority.IS_SB_ADMIN`~~ — **done by SBDEV-2863 `675b4a1`, 2026-08-07.** Do not re-write it, and do **not** run the negative test as written: the constant resolves now, so that assertion is inverted
- [x] ~~**Send §5.1 row 0e to 2732's reviewer**~~ — **discharged.** SBDEV-2863 repaired the constant, so 2732 **should** merge carrying `@PreAuthorize(Authority.IS_SB_ADMIN)`. Nothing to send
- [ ] **`B1-pre` merged AND deployed** — the hard prerequisite of A1 (§5.1 row 4)
- [ ] A1 + the 4 test-case edits; mutate-then-check each
- [x] ~~**Send §3.5 to 2732's author and get D-D ownership in writing** (Q5 → D12, §5.1 row 0d)~~ — **DONE 2026-08-11: 2732 ADOPTED it as its r-next §3.11.0 / step 18a. Phase A3 is deleted; do not build the endpoint here**
- [x] ~~**Send §3.8.2b's picker props/events spec to 2732's author and get acceptance or a counter-spec** (Q6, §5.1 row 0b)~~ — **DONE 2026-08-11: accepted VERBATIM into 2732 §3.11.5, plus a server-supplied `tier` field. B2 now waits only on the component existing (2732 step 19)**
- [x] ~~Get the **scope banner's wording** (§3.8.2a) reviewed by David Oppenheim / Scott Dalton before B2 merges~~ — **ANSWERED r7 (Decision 3 Q3): MIRROR 2732's already-approved `putawayDestinationDivertedToLane` copy.** Downgraded from blocker to courtesy, since the wording now derives from copy the requester's side accepted. ⚠ **Keep the two strings in step** — if 2732's pending product read revises variant A, this banner moves with it
- [ ] A2 — branched from `889298d` or later, ancestry asserted (§8). ~~A3~~ **deleted (r6)**
- [ ] **A4 — the `name` search parameter** (§3.5a / §5.5a, **NEW r7** from Q4 → (ii)). ⚠ **Write the EMPTY-SEARCH IDENTITY test FIRST** — `name = null` and `name = ""` must be byte-identical to today, because tiers 2 and 3 call the same endpoint and a predicate bug silently shrinks *their* pickers with no error shown
- [ ] **A4 — confirm the banner's counts come from the UNFILTERED first read**, not from a search-narrowed `totalElements` (verify `A4-neg-banner`)
- [x] ~~**Re-specify the B1 permission gate**~~ — ⚠ **DONE TWICE. The 2026-08-11 entry below was itself wrong; the live specification is r7's.** **r7 (2026-08-12):** §3.11 specifies `resolveSbAdmin` from 2732's `util/keycloakRoles.js`, assigned to **reactive data** in `mounted()`; `B1-perm` / `B1-cfg` / `B1-neg-cfg` rewritten and mutation-tested; **M7** rewritten with the hard-reload half added. ~~**2026-08-11:** §3.11 specifies `$kc.hasResourceRole('sb_admin', $config.keycloak.clientId)`; verify rows `B1-cfg` + new `B1-neg-cfg` rewritten and negative-tested four ways.~~ ⚠ **That form was false for 100% of real `sb_admins` — the role rides the `groups` claim.** Note that it was "negative-tested four ways" and still shipped wrong: **the negative tests proved the rows detect the specified form, not that the specified form was correct.** A verify row cannot catch a mis-specification; only reading the token can
- [x] ~~**Confirm `KEYCLOAK_CLIENT` == the API's hardcoded `om1-api`** per environment (ops)~~ — ⚠ **WITHDRAWN r7: never relevant.** `sb_admin` rides the Keycloak `groups` claim, so no client id is consulted by the gate (§3.11, §5.1 row 3). Nothing is owed to ops
- [ ] B1, B2
- [ ] `git checkout src/test/resources/archunit_store/` before **every** commit — `mvn test` mutates those tracked files
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh` — 0 FAIL, and the SKIP count matches the phases not yet reached
- [ ] Manual test plan **M1–M13** executed and recorded (§7.5) against **`wms2-wineco-dev`** using the subjects fixed by Q10 — SKU `ICE PACK` **874400**, location `ICEPACK` **225817**. ⚠ Not hydra (no `ICE PACK` SKU on dev2), not UAT (`V2.2.10`, so AC4/AC9 unreachable)
- [ ] Code review; every High/Medium finding fixed

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| `getItemdataDetails` payload | `putawayLocation` (name) present only when the id is non-null **and** the FK resolves | `putawayLocationId` added whenever the id is non-null; `putawayLocation` unchanged | **🟡 additive.** One consumer of 15 renders unknown keys generically — mitigated by one array entry (§6.1) |
| "configured but invalid" | indistinguishable from "not configured" — both omit every key | id present, name absent | **🟢 strictly more information.** Enables AC8 |
| `GET /v3/itemData/itemdataDetailsById/{id}` | 3 consumers | same 3 | 1 needs the `exclude-fields` companion; 2 are field-explicit |
| `GET .../itemdataDetailsByNumberAndClientNumber/{n}/{cn}` | 12 consumers, all → `skuInfo.vue` | same 12 | **🟢 all safe** — `skuInfo.vue` renders explicit named fields |
| `GET .../itemdataDetailsByNumber/{n}` | 0 UI consumers | same | **🟢 no impact** |
| `SecurityConfiguration.java:143` | `/v3/**` → `hasAnyAuthority("wms_user")` | **unchanged** | the new read lands under the existing rule; the write is 2732's endpoint |
| `@PreAuthorize(Authority.IS_SB_ADMIN)` at 9 existing sites | 500 for everyone | **unchanged by 2643** | SBDEV-2863 owns them. A0 changes only 2643's/2732's own sites |
| `receivingForm.vue` display | constants declared inline at `:221-222` | imported from `putawayWording.js` | **🟢 no behaviour change.** Same values, same comparisons, same tri-state. `receivingForm.spec.js` is the guard |
| `skuData.vue` details label | `"Putaway Location"` | `"Default Putaway Location"` | **🟢 cosmetic**, and it is the ticket's own wording |
| `skuData.vue` actions column | one eye button | eye + pencil | **🟢 additive.** The column already exists |
| SKU CSV export | `downloadSkuData` (`skuData.vue:320`) destructures an explicit field list | **unchanged** | **🟢** the new id never reaches a CSV |
| `itemdata` Caffeine cache | 2-key eviction on the dead writer; `allEntries=true` on the live one | **unchanged by 2643** | 2643 adds no cache and no write path of its own — §7.3 row 4 |
| Flyway | head `V2.2.10` | **head `V2.2.10`** | **🟢 2643 ships zero migrations** |

### 6.1 The one real hazard — `fullDetails.vue`'s stray row

`fullDetails.vue:10-11` iterates **every** key in `details` and renders any key not in `excludeFields`;
`:13-14` falls back to `name.charAt(0).toUpperCase() + name.slice(1)` when `fieldNames` has no entry.
`skuData.vue:130` excludes only `['id', 'itemNr', 'version']`.

**So A1 alone makes every SKU details overlay render a new row labelled `PutawayLocationId` showing a
raw integer.** Not a functional break — user-visible on DEV within minutes, because DEV auto-deploys on
push.

**Mandatory mitigation, and it is a GATE not a preference:** `'putawayLocationId'` goes into
`skuData.vue:130`'s `exclude-fields` — shipped **first**, as the standalone one-line `B1-pre` PR.
**Adding the exclusion before A1 merges is a provable no-op** (you are excluding a key the payload does
not yet carry), so it costs nothing and closes the window entirely. **A1 does not merge until `B1-pre`
is deployed** (§5.1 row 4, §8 rollout step 2). Verify row `B1-exclude`; risk R4 (§11.0).

### 6.2 Complete consumer inventory of the widened payload

**`GET /v3/itemData/itemdataDetailsById/{id}` — 3 consumers:**

| Consumer | Renders via | Verdict |
|---|---|---|
| `store/masterData/skuData.js:90` → `skuData.vue:304` → `<full-details>` `:126-152` | generic key iteration | **🟡 stray id row unless excluded at `:130`** |
| `components/internalOps/cycleCount/planned/create/createCycleCountSkuTable.vue:166` | ⚠ **CORRECTED 2026-08-12 — it does NOT feed `SkuInfo`; that file imports `SkuInfo` nowhere (zero grep hits).** It destructures two explicit fields into an object literal — `skuDetails.clientName` (`:171`) and `skuDetails.handlingUnitName` (`:173`) | **🟢 safe, for a STRONGER reason than was claimed** — explicit field destructuring is immune even to a renderer change. ~~confirm the sink during B1's audit~~ — done |
| `components/receiving/open/create/createPurchaseOrderSkuTable.vue:290` | ⚠ **CORRECTED 2026-08-12 — `SkuInfo` IS imported at `:173`, but the `itemdataDetailsById` response never reaches it.** It feeds an explicit object literal at `:293-302` using only `skuDetails.handlingUnitName`; the `SkuInfo` at `:164` is bound to a different data path | **🟢 safe** — same stronger reason as the row above |
| `cypress/support/helpers/wmsHelpers.js:415` (`itemdataDetailsById`) and `:421` (`itemdataDetailsByNumberAndClientNumber`) | ⚠ **ADDED 2026-08-12 — two consumers this "complete inventory" had missed** | **🟢 safe** — no spec under `cypress/` asserts either response shape, so an added key cannot break one |

> [!note] **Why the two corrections above matter even though both verdicts were right.** "Safe because the sink is `SkuInfo`, and `SkuInfo` is field-explicit" is a **load-bearing claim** in this table. If someone later makes `SkuInfo` generic, they will consult this row and reach the wrong conclusion about two consumers that were never `SkuInfo` consumers at all. The real reason both are safe — explicit destructuring at the call site — survives that change; the stated reason did not. ⚠ Also confirmed 2026-08-12: `fullDetails.vue` is the **only** generic key-iterating renderer on this payload. Four other key-iterating components exist (`Strategies/customerOrder.vue:83`, `admin/serviceLog/serviceLog.vue:67`, `receiving/closed/closedNoticeTable.vue:51`, `material/skuUnits/skuUnit.vue:97`) and all four render different payloads; `wms2-mobile-ui` has zero `itemdataDetails` consumers and zero generic renderers, so §6.3's "out of scope" is also factually "not a consumer".

**`GET /v3/itemData/itemdataDetailsByNumberAndClientNumber/{n}/{cn}` — 12 consumers, all feeding
`components/common/skuInfo.vue`, all 🟢 SAFE:**

`components/receiving/open/openNoticeTable.vue:271, :279` (imports SkuInfo `:158`) ·
`components/outbound/transfer/transferDetailsTable.vue:132` (`:43`) ·
`components/processes/clubRuns/tabTables/availableInventory.vue:174` (`:68`) ·
`components/processes/transferPicking/tabTables/availableInventory.vue:175` (`:68`) ·
`components/processes/transferPicking/tabTables/inventoryOnLane.vue:188` (`:75`) ·
`components/outbound/club/batchContentTable.vue:151` (`:59`) ·
`components/outbound/pickPack/parcelDetailsTable.vue:130` (`:43`) ·
`components/processes/clubRuns/tabTables/inventoryOnLaneTable.vue:185` (`:75`) ·
`components/processes/clubRuns/itemsTable.vue:191` (`:43`) ·
`components/outbound/club/orderDetails/orderDetailsTable.vue:127` (`:48`)

**Why all 12 are safe:** `skuInfo.vue:102-105` renders **explicit** named fields —
`<v-list-item-content>Putaway Location</…><v-list-item-content>{{ reportDetail.putawayLocation }}</…>`.
No key iteration, no `excludeFields`. An added key is simply ignored.
(`pages/receiving/openNotice/receive.vue:27` imports a **different** component,
`receiving/open/receive/skuInfo.vue` — also field-explicit.)

**`GET /v3/itemData/itemdataDetailsByNumber/{n}` — zero UI consumers.**

**Java-side consumers of the map:** `ItemDataController.java:176, 183, 191` only. Tests asserting on its
keys: `ItemdataServiceUnitTest.java:415-428, 448-472, 475-498, 585-604`.
`BoxtypeServiceUnitTest.java:188, 222` asserts a **different** map (`BoxtypeService.java:87`) — do not
touch it.

### 6.2a A4 widens a SHARED endpoint — the compatibility contract (NEW r7)

`GET /putawayConfig/eligibleLocations` gains `name`. **Adding an optional request parameter is wire-compatible** — Spring binds a missing `@RequestParam(required = false) String name` to `null`, so every existing caller is unaffected at the HTTP layer. That is the easy half.

**The hard half is behavioural, and it is the actual compatibility surface:**

| Existing caller | Passes `name`? | Required behaviour after A4 |
|---|---|---|
| 2732 WAREHOUSE picker (`defaultPutawayLocationField.vue`, `scope=WAREHOUSE`) | no | **byte-identical** result to pre-A4 |
| 2732 MERCHANT picker (same component, `scope=MERCHANT`, step 21) | no | **byte-identical** |
| 2643 SKU picker (B2) | yes, debounced | narrowed page; `eligible` / `blockingReason` / `tier` unchanged for matching rows |

So the contract is: **`name` null or blank ⇒ the query is exactly the query that runs today.** Not "equivalent", not "logically the same" — the same predicate set. A `LIKE '%%'` shortcut that *looks* harmless still changes the plan the database picks and can reorder an unsorted page, which would reshuffle two shipped pickers for no reason. **Branch around the predicate when the term is absent; do not parameterise it to a wildcard.** Verify `A4-t-empty`; risk **R11**.

⚠ **`totalElements` semantics change for searching callers only.** With a term applied it counts *matches*, not the facility's candidates — which is why §3.8.2a requires the banner's counts to come from the unfiltered first read (`A4-neg-banner`). Non-searching callers see no change, so 2732's screens are unaffected.

### 6.3 What Does NOT Change

- **`ReceivingService` — nothing.** No routing behaviour changes. The ticket's own "Receiving Behavior
  Boundary" defers it and 2732 §3.7 owns it. A SKU configured through 2643 behaves at receive time
  exactly as one configured by a DBA today.
- **`itemdata.putawaylocation_id`'s nullability, the `@NotNull` at `Itemdata.java:49`, and the DB
  schema.** 2643 ships no DDL. `ddl-auto=none` per-request `42703` risk is **nil** — a genuine
  advantage over 2732's row 8.
- **The legacy `GET /v3/itemData/setPutAwayLocation/{i}/{l}`** — left in place, verb unchanged (2732
  §10.4 Q5: the web UI calls it and changing the verb is breaking). 2643 simply **never calls it**.
- **`ViewDtoService.getLocationView()` and `GET /v3/location/detailView`** — not widened (D3). Four
  other screens keep their payload byte-for-byte.
- **`fullDetails.vue`** — the `#actions` slot already exists at `:26`.
- **`plugins/persistedState.client.js`** — no exclusion added (§3.8.5).
- **`SecurityConfiguration.java`** — not widened, not narrowed.
- **`CacheConfig`, `MethodSecurityConfig`, `CustomMethodSecurityExpressionRoot`, `Authority.java`** —
  untouched by 2643. SBDEV-2863 already repaired `Authority.java`; 2643 adds nothing here.
- **The 9 endpoints F1 broke** — **repaired by SBDEV-2863 `675b4a1` (2026-08-07)**, before 2643 ships
  anything. *(Was: "SBDEV-2863's, still broken after 2643 ships.")*
- **`store/masterData/storageLocation.js`** — untouched; the picker reads the new endpoint.
- **The SKU data table** — no new column, no `headers` change, no `getItemDataViewPage` change (Q4).
- **`wms2-mobile-ui`** — entirely out of scope.

---

## 7. Testing Strategy

### 7.1 Unit lane — Java (`v2/wms2-api`)

**Harness constraints, non-negotiable:**

- **The base class is `BaseControllerUnitTest`** (`common/base/BaseControllerUnitTest.java:34`), **not**
  `BaseControllerTest` — which does not exist (C6; 2732 §7.7 row 7 carries the same wrong name).
  `setupMockMvc(controller)` at `:52-58` builds `MockMvcBuilders.standaloneSetup(...)` with a
  `PageableHandlerMethodArgumentResolver`, a `MockPrincipalArgumentResolver`, a
  `MappingJackson2HttpMessageConverter` over a `JavaTimeModule`-registered `ObjectMapper` with
  `FAIL_ON_UNKNOWN_PROPERTIES=false`, and `.alwaysDo(print())`.
- **⚠ `standaloneSetup` installs no security filter chain and no method-security advisor, so
  `@PreAuthorize` is NEVER evaluated in this lane** (F2). This lane proves shape and delegation, never
  authorization.
- **The `@SpringBootTest` / Testcontainers lane is DOWN** (SBDEV-2217). Gate on `mvn test` +
  `mvn clean compile`. Any new IT is `@Disabled` with `TODO(SBDEV-2217)`.
- `mvn test` **MUTATES** tracked `src/test/resources/archunit_store/{stored.rules,
  5fb3fee0-6caf-4f48-a5cd-5271da610572}` (F4) — `git checkout` them before every commit.
- `mvn` / `java` need the SDKMAN PATH export.
- **`-Dtest='Outer#method'` silently no-ops for `@Nested` tests** (false green) — always name the nested
  class.
- **Baseline the 2 pre-existing failures on clean `develop`** as of 2026-07-28
  (`OptionalSafetyArchTest` ArchUnit drift, `MobilePalletizingServiceTest`). Do not chase them; record
  the baseline count before the first change.

| Test class | Method | Asserts | Phase |
|---|---|---|---|
| ~~`CustomMethodSecurityExpressionRootUnitTest` (new `@Nested SpelResolution`)~~ | ~~`authoritySpelConstantsResolve`~~ | **ALREADY EXISTS** as `@Nested AuthorityExpressionsResolve` (SBDEV-2863 `675b4a1`), evaluating through the **real** `CustomMethodSecurityExpressionHandler` | ~~A0~~ — **retired r5** |
| ~~`CustomMethodSecurityExpressionRootUnitTest`~~ | ~~`sbAdminExpressionUsesBareAuthorityName`~~ | **ALREADY EXISTS** as `getExpForRole_expressionResolves`, which additionally asserts `Authority.IS_SB_ADMIN` **equals** `getExpForRole(SB_ADMIN_ROLE)` so the constant cannot drift from the helper | ~~A0~~ — **retired r5** |
| `ItemdataServiceUnitTest` | `shouldIncludePutawayLocationWhenPresent` (mod `:415-428`) | `containsEntry("putawayLocationId", 7L)` **and** `containsEntry("putawayLocation", "LOC-001")` | A1 |
| `ItemdataServiceUnitTest` | `shouldHandleItemWithAllOptionalFields` (mod `:468-471`) | key list gains `"putawayLocationId"` | A1 |
| `ItemdataServiceUnitTest` | `shouldHandleMissingOptionalReferences` (**rewritten**, `:498`) | dangling FK ⇒ `containsKey("putawayLocationId")` **and** `doesNotContainKey("putawayLocation")` — the AC8 signal | A1 |
| `ItemdataServiceUnitTest` | null-id case (mod `:585-604`) | `doesNotContainKey("putawayLocation")` **and** `doesNotContainKey("putawayLocationId")` | A1 |
| `ItemdataServiceUnitTest` | `getItemdataDetailsAddsNoQueries` | `verify(locationRepository, times(1)).findById(any())` and **zero** additional repository interactions vs. the pre-change baseline | A1 |
| `SkuPutawayQueryServiceUnitTest` (**new file, 2643-owned**) | `describeForSkuDelegatesToResolver` | the resolver is called once with the SKU's id; the returned `Resolution` is passed through unmodified | A2 |
| `SkuPutawayQueryServiceUnitTest` | `describeForSkuIsReadOnlyTenantTransaction` | reflective assertion that the method's `@Transactional` carries `value="tenantTransactionManager"` **and** `readOnly=true` | A2 |
| `ItemDataControllerUnitTest` (**new `@Nested EffectivePutawayDestination`**, appended at EOF) | `returnsSevenFieldEnvelope` | all 7 keys present: `locationId, locationName, source, sourceLabel, configuredFor, compatible, warning` | A2 |
| ″ | `sourceIsEnumNameNotLabel` | `source` == `"SKU_OVERRIDE"`, `sourceLabel` == `"SKU override"` — **the UI must never re-derive tiers** | A2 |
| ″ | `incompatibleConfigCarriesWarning` | `compatible=false` ⇒ `warning` is non-blank (AC8) | A2 |
| ″ | `delegatesToFacadeNotResolver` | the facade mock is invoked; **no resolver collaborator is even constructed** | A2 |
| `SkuPutawayQueryServiceUnitTest` | `describeForSkuOpensNoNewTransaction` | no `Propagation.REQUIRES_NEW` and no second `@Transactional` layer — the resolver must **join**, per 2732 §3.1.5's `MANDATORY` | A2 |
| `ItemDataControllerUnitTest` ″ | `neverCarriesBrokenAuthorityConstant` | the new handler and `SkuPutawayQueryService` carry no `Authority.IS_SB_ADMIN` (§5.1 row 0e; the read is deliberately not admin-gated at all) | A2 |
| ~~`PutawayConfigControllerUnitTest` (A3 fallback only)~~ | ~~`eligibleLocationsSkuScopeTwoClasses`~~ | **DELETED r7 — A3 is gone and 2732 never used that method name, so the verify row citing it could only ever be red** |
| ⚠ **AS BUILT:** `PutawayDestinationQueryServiceUnitTest.NameSearchParameter` — **not** the controller test | **`blankNameIsIdenticalToNoNameFilter`** | ⚠ **THE LOAD-BEARING TEST OF PHASE A4; written FIRST, as required.** ⚠ **Two corrections against the row as planned, both recorded rather than silently applied.** (1) **It lives in the SERVICE test**, because the contract is behavioural — *which query runs* — and the controller test is a reflection/shape class that cannot see a query. (2) **"identical to the no-argument call" is not the assertion that guards R11** — a blank term routed through a match-everything wildcard would satisfy it. The test asserts `verify(locationRepository, never()).findPutawayCandidatesByName(…)`: the filtered query is not merely harmless when the term is blank, it is **never reached**. It also compares the 3-arg legacy path (`theLegacyThreeArgFormIsTheSameCodePath`), which is the signature 2732's two pickers actually call. Verify row `A4-t-empty` was repointed to this file and now requires the `never()` clause |
| ⚠ **RESHAPED — see §5.5a's "what a mocked test can and cannot prove" row** | ~~`eligibleLocationsNameFilterNarrowsThePage`~~ → **`nameFilterRoutesToTheFilteredQueryVerbatim`** | The planned assertion — "a term matching 1 of N candidates returns that one row" — is **unsatisfiable by a correct implementation and satisfiable only by an incorrect one.** A4 puts the predicate in the DATABASE, so against a mocked repository the service returns whatever the stub hands back; the only way to make the original pass is a service-side `stream().filter()` over all 2,564 rows, which is the exact cost this phase removes. Replaced by the strictly stronger routing assertion: the term reaches the filtered query **trimmed and un-wildcarded** (captor-checked), and the **unfiltered query is never called** — which is precisely how the forbidden post-filter would have to be built |
| ″ | ~~`eligibleLocationsNameFilterIsCaseInsensitive`~~ → **`theFilteredQueryLowercasesBothSidesAndKeepsItsSiblingsPredicates`** | Same problem: case-folding is a property of the SQL, so a mock cannot witness it. Asserted **against the `@Query` text itself** — `LOWER(l.name) LIKE LOWER(CONCAT('%', :nameFilter, '%'))`, `nativeQuery = false`, plus the two clauses the split query must keep identical to its sibling (excluded-lane, two-tier `ORDER BY`) **and** that the sibling still carries no name predicate. This is a real property of the shipped artifact, and it caught two of the three A4 mutants |
| `PutawayDestinationQueryServiceUnitTest.NameSearchParameter` | `nameFilterDoesNotAlterEligibility` | an **ineligible** row that matches the term is still returned with `eligible = false` and its original `blockingReason` — a search must never launder a blocked destination into an offerable one. ⚠ Needed a **`doAnswer` that genuinely blocks one row**: with the default no-op validator mock every row is eligible and the test compared `true == true`, passing whatever the search did. An asserted fixture premise now guards that |
| ⚠ `PutawayConfigControllerUnitTest.EligibleLocationsEndpoint` → **`takesScopeAndOptionalSubjectId`** | **A4 BREAKS THIS EXISTING 2732 TEST — update it, do not delete it** | It asserts `containsExactly(PutawayScope.class, Long.class, Pageable.class)` on the endpoint's parameter types (`PutawayConfigControllerUnitTest:602-605`). Adding `String name` makes it red. **Widen it to `containsExactly(PutawayScope, Long, String, Pageable)`** and keep the `containsExactly` form — the comment there explains why it is deliberately exact rather than a loose `contains`. ⚠ **Discovered by the TDD gate, 2026-08-12.** It is the concrete instance of risk **R11**: A4's first casualty is a test 2732 owns |
| `PutawayDestinationQueryServiceUnitTest.NameSearchParameter` | ~~`nameFilterAppliedInsideCandidateQuery`~~ → **`nameFilterReachesTheRepositoryNotAServiceSideStream`** | the predicate is in the query, not a post-filter — otherwise the page is computed over all 2,564 rows to return 3 (verify `A4-inquery`). Shipped as the gate wrote it: reflection over `LocationRepository` for a `findPutawayCandidates*` method taking **two** `String` parameters |
| ″ | `eligibleLocationsExcludesTierFourLane` | no row whose `locationName` equals `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE` (Q3) | A3 |
| ″ | ~~`eligibleLocationsNeverRelaxesFixAssigned`~~ → **`eligibleLocationsExcludesFlowbinAssignedToAnotherSku`** | ⚠ **REWRITTEN 2026-08-09 — the old form asserts the superseded r2 design and would fail a correct implementation.** P2.5's absolute reject is **dropped** (2732 Q12 → iv-b), so "a fix-assigned location is never offered" is false: a SKU pointed at **its own** pick face is the intent. What must be excluded is a flowbin fix-assigned to a **different** SKU — 2732's new **P2.7 rule (f)**. **Two tests needed**, or an implementation that excludes all fix-assigned locations passes: pair this with `eligibleLocationsOffersTheSkusOwnFixAssignedPickFace` | A3 |
| ″ | ~~`eligibleLocationsNeverOffersPickFace`~~ → **`eligibleLocationsOffersPickFaces`** | ⚠ **INVERTED 2026-08-09 — this is the single most dangerous stale row in the plan.** As written it asserts *"a `useforpicking`-area location is **not offered**, ever"*, which is **exactly what r3 reversed**. It cites P2.7(c) as *"absolute"* — P2.7(c) is **DROPPED at all three scopes** — and mirrors 2732's `skuWriteRejectsPickFaceDestination`, a test 2732 **deleted** on 2026-08-08 (the cited line `:2211` no longer resolves). **A TDD gate run against the old row would permanently enforce the design r3 abandoned.** The correct assertion: a `useforpicking` location **IS** offered at SKU scope, including flowbins (tier 1 is exempt from rule (e)) | A3 |

**Mutate-then-check every new assertion.** Per the recorded landmine, a new assertion is worthless until
you have seen it fail: flip the production line, watch red, restore. SBDEV-2736 scored 57 pass / 0 fail
on the very build carrying the defect its ticket was written to catch.

### 7.2 Unit lane — Jest (`v2/wms2-web-ui`)

**How to run** (no `yarn` on PATH; `jest.config.js` has **no `roots` key**):

```bash
export PATH="$HOME/.nvm/versions/node/v24.15.0/bin:$PATH"
cd /home/nampark/dev/wms-claude/v2/wms2-web-ui
node_modules/.bin/jest test/components/masterData/material/skuData/skuData.spec.js --coverage=false
```

**Copy the idiom from `test/components/receiving/open/receive/receivingForm.spec.js`** — same feature
area, written by 2731's TDD gate: `shallowMount`, import the SUT by `@/` alias, a `mount*` helper
hand-building `$axios` as `{ $get: jest.fn(url => …), $put: jest.fn() }` branching on
`url.includes(...)`, and `$store` as a **plain object literal** with a nested `state` tree — no Vuex, no
localVue. Match its header comment too: it explains *why* each test cannot pass against the pre-fix
component, driving the whole chain (axios payload → watcher → computed → rendered text) rather than
poking a computed directly.

| Spec | Test | Asserts | Phase |
|---|---|---|---|
| `test/components/masterData/material/skuData/skuData.spec.js` | `excludesRawPutawayLocationId` | with `putawayLocationId` in the details payload, **no** row labelled `PutawayLocationId` renders | B1 |
| ″ | `detailsLabelIsDefaultPutawayLocation` | the overlay renders `"Default Putaway Location"`, not `"Putaway Location"` | B1 |
| ″ | `editAffordanceEnabledForAdmin` | ⚠ **REWRITTEN AGAIN r7 — r6's form below was also wrong; do NOT generate either.** Stub the token so `resolveSbAdmin` resolves `true` — i.e. `$kc.tokenParsed.groups` **contains `'sb_admin'`**, and `$kc.ready` is a resolved promise ⇒ pencil **enabled**. ⚠ **`await flushPromises()` (or `await nextTick()` twice) before asserting**: the gate is set in an `async mounted()`, so a synchronous assertion reads the initial `false` and the test fails against correct code. ~~r6: stub `$kc.hasResourceRole` to return `true` for `('sb_admin', <clientId>)`~~ — that tests a call the implementation must not make. ~~r5: `affiliatedGroups` containing `$config.appAdminGroup`~~ — dead config. **Both superseded forms would pass against a gate that can never grant anyone access** (§3.11) | B1 |
| ″ | `editAffordanceDisabledNotHiddenForReadOnly` | non-admin ⇒ pencil **present and `disabled`**. ⚠ **REQUIRED ASSERTION FORM** (r2, so the verify row can see it and so the test is not satisfied by the word "disabled" appearing anywhere in a Vuetify spec): the spec must (a) name **`isSbAdmin`** (⚠ **r7: was `isPutawayConfigAdmin`**, the computed §3.11 replaced), (b) prove presence with **`.exists()`**, and (c) read the attribute with **`.attributes('disabled')`** or **`.props('disabled')`** — never a snapshot or a text match. **r7 adds a third case, `editAffordanceEnabledForAdminAfterReload`**, which is the one that catches the non-reactive-gate defect: mount with auth settling *after* first paint, then assert the pencil becomes enabled. Verify row `B1-jest2` | B1 |
| ″ | `commentedActionsBlockIsGone` | the rendered tree has no trash icon and no `mdi-dots-vertical` menu | B1 |
| `test/components/…/editSkuPutawayDialog.spec.js` | `clearOmitsLocationIdEntirely` | Clear dispatches with `locationId: null`, and the resulting URL has **no** `?locationId=` at all | B2 |
| ″ | `scopeBannerStatesRoutedViaPutaway` + `scopeBannerStatesConsequence` | ⚠ **RENAMED AND REWRITTEN r7 — was `scopeBannerNamesBlockingTicket`, which asserted the banner names `SBDEV-2821` and `2732 Q9`.** There is no blocking ticket to name: **2821 merged 2026-08-09**, and **D1 was re-reversed in r3** so pick faces ARE offered. The banner must render **unconditionally** (not behind a selection) and state (a) that a pick-face destination is **routed via putaway, not placed directly**, and (b) the **consequence** — the stock is not on the pick face when the receipt closes. A third negative, **`scopeBannerOmitsExpiredFraming`**, asserts `SBDEV-2821` and "not yet selectable" are **absent**. §3.8.2a; verify rows `B2-banner`, `B2-banner2`, `B2-neg-bann` | B2 |
| ″ | `pickerNeverResurrectsIneligibleRows` | ⚠ **RENAMED r7 — `pickerNeverOffersPickFaces` asserted the OPPOSITE of D1/r3.** Pick faces are eligible at SKU scope and must be offered; what must never be offered is a row the server marked **`eligible: false`**. Given an `eligibleLocations` payload mixing eligible and ineligible rows, the wrapper passes only the eligible ones — the client does not resurrect what the server rejected, and does not filter on a predicate of its own (§14 principle 2) | B2 |
| ″ | `emptyStateExplainsWhy` | a client filter yielding zero rows renders the same three facts as the banner, not a bare "No data available" | B2 |
| ″ | `incompatibleEffectiveRendersWarning` | `compatible: false` ⇒ the envelope's `warning` text renders verbatim | B2 |
| ″ | `defaultRenderedWithLabelNotMachineName` | an inherited `STANDARD_PUTAWAY_LANE` renders `"Put Away Lane"`, never `"PutAwayLane"` | B2 |
| ″ | `validationToastOnEmptySelection` | Submit with nothing selected fires `$toast.error` and dispatches nothing | B2 |
| ″ | `submitDisabledForReadOnly` | non-admin ⇒ Submit `disabled` | B2 |
| `test/store/masterData/skuData.spec.js` | `writeTargetsPutawayConfigEndpoint` | `$put` called with `/putawayConfig/sku/{id}`; **`$get`/`$put` never see `/itemData/setPutAwayLocation`**. ⚠ **REQUIRED ASSERTION FORM** (r2): the negative half must be written **`.not.` FIRST** — e.g. `expect($put).not.toHaveBeenCalledWith(expect.stringContaining('setPutAwayLocation'))` or `expect(urls.join(' ')).not.toContain('setPutAwayLocation')`. r1's verify row was a bare substring grep for `setPutAwayLocation` and would have **passed on a spec asserting the opposite**, or on the string in a comment. Verify row `B2-jest4` | B2 |
| ″ | `surfacesValidationBodyOn422` | a rejected `$put` with `response.data.errors[0].message` ⇒ that message reaches `$toast.error`, not the generic network string | B2 |
| ″ | `refetchesDetailNotTable` | after a successful write, `getSkuDetail` is dispatched and **`searchSkuData` is not** | B2 |

**Re-run `receivingForm.spec.js` in B1** — B1 moves the constants that spec's assertions depend on.

### 7.3 v2-only constraint checklist (8 rows)

Verdicts are about code not yet written; **the verify script and the post-implementation gate hold the
real PASS/FAIL**, matching 2732 §7.7's verdict semantics.

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | **OSIV disabled** ⇒ load entities inside the transaction, or return ids/DTOs | **BY DESIGN — re-verify post-implementation** | `application.properties:55` `spring.jpa.open-in-view=false`. 2643's only new read is `describeForSku`, which runs entirely inside the `readOnly=true` facade and returns a fully-loaded `Resolution`. `getItemdataDetails` already dereferences via explicit `findById` (`ItemdataService.java:167`); every FK on `Itemdata` (`:39-51`) is a manual `Long` with no lazy association. **No new risk** |
| 2 | **`tenantTransactionManager` named explicitly** — a bare `@Transactional` silently binds the `@Primary` landlord TM | **BY DESIGN — re-verify post-implementation** | `describeForSku` carries `@Transactional(value="tenantTransactionManager", readOnly = true)` verbatim from 2732 §3.1.5's two siblings. `unit/config/TransactionManagerArchTest.java` enforces it repo-wide; verify row `A2-tx` asserts the literal string. **⚠ `ItemdataService` is a bare `@Service` (`:15`) with NO `@Transactional` anywhere (F5) — do not add the resolver call there** |
| 3 | **`readOnly = true`** on the read facade; the resolver must not be `readOnly` and must not open `REQUIRES_NEW` | **BY DESIGN — re-verify post-implementation** | `describeForSku` is a pure read. Safe **only** because 2732 §3.4a reads tier 3 via `SyspropRepository` and never `SyspropService.getStringDefault` (which INSERTs at `SyspropService.java:234`). 2643 adds no `REQUIRES_NEW` and no resolver of its own. If 2732's `neverCallsGetStringDefault` guard is ever deleted this becomes a write-in-readOnly bug |
| 4 | **Caffeine/Redis eviction covers every write path, in both profiles** | **BY DESIGN — re-verify post-implementation** | 2643 introduces **no cache and no write path of its own** — it delegates to `PutawayConfigService.setSkuDestination`, which carries 2732's 2-key `itemdata` eviction copied verbatim from `ItemdataService.java:62-67`. `CacheConfig` untouched ⇒ the two-profile-sync trap is avoided entirely. ⚠ **2643 must NOT call `GET /v3/itemData/setPutAwayLocation/...`**, whose `@CacheEvict(allEntries=true)` at `ItemDataController.java:80` flushes every tenant — verify row `B2-neg-leg`. `describeForSku` is uncached |
| 5 | **Micrometer** | **BY DESIGN — re-verify post-implementation** | 2643 adds no metric; it inherits 2732's `PutawayResolutionMetrics` via the shared writer and resolver. ⚠ 2732 §8.1 (`:2293`) makes non-zero **tier-2/3** counters a condition for closing 2643 — wrong signal for a SKU-tier ticket. `resolution{source="SKU_OVERRIDE"} > 0` is 2643's own correct detector (§5.1 row 8; raise at review) |
| 6 | **Jakarta namespace only (`jakarta.*`)** | **BY DESIGN — re-verify post-implementation** | Nothing is ported from v1 — SBDEV-2642 shipped zero commits (2732 §10.5). Existing files comply: `Location.java:3` `import jakarta.persistence.*`, `:5` `jakarta.validation.constraints.NotNull`; `ItemDataControllerUnitTest.java:28` `jakarta.servlet.ServletException`. 2643 adds no entity, so no new persistence imports |
| 7 | **H2-compatible test SQL** | **BY DESIGN — re-verify post-implementation** | 2643 adds **no migration**. Its only candidate query is D-D's eligibility read: **JPQL with plain joins and booleans**, no `nullif(...)::bigint` (the Postgres-only construct 2732 §7.7 row 6 flags in `readCommittedDestination`). Prefer JPQL over native to sidestep the class entirely |
| 8 | **New/changed endpoints need a `BaseControllerUnitTest` subclass** (⚠ **not** `BaseControllerTest` — C6) | **BY DESIGN — re-verify post-implementation** | `GET /v3/itemData/{id}/effectivePutawayDestination` gets a NEW `@Nested` class in `ItemDataControllerUnitTest`, which already extends `BaseControllerUnitTest`. ⚠ **F2: `standaloneSetup` (`:52-58`) evaluates no `@PreAuthorize`** — this lane proves shape and delegation, not authorization. **Entity/DDL drift: 2643 ships no DDL and no entity change**, so the `ddl-auto=none` per-request `42703` risk is nil |

### 7.4 Horizontal-scalability checklist (10 rows)

| # | Concern | Does 2643 change... | Verdict | Evidence / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | introduce state that exists in only one replica? | **No — BY DESIGN, re-verify post-implementation** | No new cache, no `ConcurrentHashMap`, no static, no `ThreadLocal`. `describeForSku` is a pure function of DB state. Vuex state is per-browser, not per-replica. 2643 adds no equivalent of 2732 §7.6 row 1's request-scoped previous-value carrier |
| 2 | **Connection-pool math** | change per-request DB connection usage? | **No — BY DESIGN, re-verify post-implementation** | `effectivePutawayDestination` is one new request holding one connection for ≤4 index-backed resolver queries. `getItemdataDetails` gains **zero** queries — `putawaylocationId` is already on the entity loaded at `:120`; only a `details.put` is added (asserted by `getItemdataDetailsAddsNoQueries`). Call frequency is admin-screen scale — one per dialog open, not per receipt |
| 3 | **Scheduled jobs** | add or modify a `@Scheduled` job? | **N/A** | 2643 adds no job and touches none |
| 4 | **Long transactions** | hold a transaction across more repository calls or external I/O? | **No — BY DESIGN, re-verify post-implementation** | `describeForSku`'s `readOnly=true` transaction spans ≤4 lookups and closes. No HTTP, no printer, no broker, no loop. Config writes are 2732's single-entity transactions. **2643 adds nothing to the receiving path** |
| 5 | **Request affinity** | assume a follow-up request lands on the same replica? | **No — BY DESIGN, re-verify post-implementation** | Every read re-resolves from the DB; every write is a separate stateless `PUT`. The read-after-write (Save → re-dispatch `getSkuDetail`) may land on a **different** replica — safe because the write commits before the response and `describeForSku` is uncached. ⚠ **Caveat:** `ItemdataService.getById` is `@Cacheable` (`:47`) under Caffeine, so a different replica could serve a stale `itemdata` for its TTL — but the read-after-write goes through `getItemdataDetails`, which uses `itemdataRepository.findById` (`:120`), **not** the cached `getById`. **🟢 by accident — verify row `A1-repo` pins it** so a future "optimisation" cannot silently break it |
| 6 | **Retry / idempotency** | rely on single-execution semantics? | **No — BY DESIGN, re-verify post-implementation** | The write is idempotent last-writer-wins on one column, protected by `Itemdata`'s `@Version`. A double-submit yields a duplicate `putaway_config_audit` row — harmless, and the correct record of two requests (2732 §7.6 row 6). `PUT /putawayConfig/**` is **outside** `IdempotencyFilter`, which guards `/rest/**` only (`IdempotencyFilter.java:271`) — unchanged, not made worse |
| 7 | **Tenant context** | use `TenantContext` across an async boundary? | **No — BY DESIGN, re-verify post-implementation** | Everything on the request thread. No `@Async`, no `CompletableFuture`. The `@Cacheable`/`@CacheEvict` SpEL reads `TenantContext.getCurrentTenant()?.getFacilityCode()` synchronously (`ItemdataService.java:47, 63-66`) |
| 8 | **Distributed-lock correctness** | add or rely on cross-replica locking? | **No lock added — but 2643 IS the surface that arms 2732's accepted risk** | `describeForSku` is `readOnly`; the config write is a single-row `UPDATE itemdata`. 2732 §7.6 row 8's accepted risk is a **lock-order inversion at receive time** (`transferUnitLoadToLocation` takes `findByIdForUpdate` on the destination Location at `:150`, before UL/SU at `:293-294`, inverting SBDEV-2232's canonical SU→UL→Location order, with no deadlock-retry infra). Receiving is out of 2643's scope — **but 2643 is how an operator arms it:** a SKU pointed at a live storage location makes receipts hold `FOR UPDATE` on that row for a whole multi-case receipt. **Therefore 2643 MUST carry 2732 §3.11.2's advanced-tier toggle + lock-contention warning verbatim** (2732 `:1607` requires exactly this for the SKU picker) and must **not** default the picker to storage locations. Measured: 92 SKU-eligible locations on hydra DEV, of which the `useforstorage` subset is the armed set. ⚠ **r2: the armed set is exactly 2732's own, not one byte wider.** r1's D1 widened it to include pick faces and answered 2732 `:2308`(i)'s *hard* prerequisite with a UI banner — a UI banner is not deadlock-retry infrastructure, and 2732 **Q9** (`:2561`) answers *"No"* to precisely that widening, naming the same physical reason (*"picking locks the same rows in the opposite order far more often than replenishment does"*). **r2 enforces P2.7(c), so no new prerequisite is inherited** (§5.1 row 9). The storage-tier toggle + lock warning remain **mandatory** — that hazard is 2732's, is real, and is reachable today |
| 9 | **Cache invalidation** | write to a cached entity? | **Yes, indirectly — BY DESIGN, re-verify post-implementation** | The write targets `Itemdata`, cached under `itemdata` (2 keys, `ItemdataService.java:47, 62-67`). Eviction is 2732's, copied verbatim. Under **Redis** it propagates cross-replica; under **Caffeine** it does not, so another replica can show a stale value for up to the TTL. **Accepted** on 2732's reasoning: the receiving path reads tiers uncached (no receipt is misrouted) and the exposure is admin display only. **2643-specific improvement:** `getItemdataDetails` reads via `findById` (`:120`), bypassing the cache, so **2643's own display is always fresh even under Caffeine.** Asserted — see row 5 |
| 10 | **External notifications** | send HTTP/message to an external system inside a transaction? | **No — BY DESIGN, re-verify post-implementation** | No OMS notification, no outbox row, no printer, no Keycloak call on any 2643 path. ⚠ `ItemDataController` **does** hold `HttpRestService` and a `sendStockUpdate` endpoint (`:97-98`) that notifies OMS — **2643 must not touch it**, and a putaway-config change must **not** trigger an inventory export. Verify row `A2-neg-oms` asserts `httpRestService` appears nowhere in the new handler |

### 7.5 Manual Test Plan (MANDATORY)

> [!done] **✅ Q10 ANSWERED 2026-08-12 — option (A), DEV-only on `wms2-wineco-dev`. NO STAND-IN IS
> NEEDED: that tenant carries the ticket's ACTUAL named subject, and it is the only DEV tenant with
> `V2.2.13`.** All ids below verified SELECT-only on 2026-08-12.
>
> | Role | Subject on `wms2-wineco-dev` |
> |---|---|
> | **The SKU** (AC10 — "system SKU, including ice packs") | **`ICE PACK`, `itemdata.id = 874400`**, `client_id = 0` (`cl_nr='System'`, `System-Client`), `defultype_id = 4` (Case), `putawaylocation_id` **NULL**. It is the **only** System-client SKU on the tenant |
> | **The destination** (AC2/AC6/M10) | **`ICEPACK`, `location.id = 225817`** — `location_type = flowbin`, area *"Storage and Picking"* (`useforstorage` + `useforpicking`, **not** `useforgoodsin`), `entity_lock = 0`. So it sits behind the picker's **advanced/storage tier** with the lock warning, not the default tier |
> | **The FLA** | **`fix_location_assignment.id = 22742154`** binds 225817 → **874400**, `active`, bounds **36 / 60 / 84**. ⚠ **Bound to its OWN SKU, so rule (f) does NOT exclude it** — this is the M10(c) happy path, not a blocked row |
> | **AC8 — an invalid EXISTING config** | **SKU `1135`, `itemdata.id = 740645`** (client `ECV` 512500) → **`Club08`, `location.id = 225755`, type `cases and pallets`**. It is the tenant's **only** off-default-lane configuration. ⚠ **Use it for AC8 deliberately and NOT for M4** — `cases and pallets` is the fourth type `storeBoxOnLocation` does not switch on, and the review brief's **M1b proved it THROWS** `Unsupported location type cases and pallets`. It is a genuine invalid-existing-config subject and a trap as a happy path |
> | **AC11 — client-owned** | 8,803 SKUs have `putawaylocation_id IS NULL`; e.g. `WINE750` (52350, `TCOMPANY`), `9007.16` (60550, `ARW`) |
> | **M10(d) — foreign-bound flowbin, must NOT be offered** | e.g. **`00-A01`, `location.id = 63785`**, FLA-bound to `23RHRSVPNBTL` (20371549). **1,344 of 2,068 flowbins** qualify |
>
> **Two plan claims this measurement falsified:**
> 1. ~~"all 2,720 SKUs point at `PutAwayLane`"~~ — true of **hydra**. On wineco-dev **ZERO** SKUs point at
>    the lane and **8,803 are NULL**, because `V2.2.13` shipped `DROP NOT NULL` + stop-seeding. **M3
>    ("inherits") therefore has 8,803 subjects rather than a hunt.**
> 2. ~~"the reported invalid Ice Pack configuration is a PRD-only state"~~ — the *exact* pairing
>    (SKU 52072 → location 52075) is PRD-only, but **an equivalent `ICE PACK` SKU + `ICEPACK` flowbin +
>    active FLA all exist on wineco-dev**, so the reported scenario is fully reproducible on DEV.
>
> **Not chosen, and why:** `nywh-hydra-uat` also has an `ICE PACK` System SKU (3279555) — but it has **no
> `ICE PACK` location** and sits at Flyway head **`V2.2.10`**, so `putawaylocation_id` is still `NOT
> NULL`, `putaway_config_audit` does not exist and `client.defaultputawaylocation_id` is absent: **AC4
> and AC9 are untestable there.** Same for `wsl-wineco-uat` (also `V2.2.10`). ⚠ **If anyone later wants
> UAT coverage, `V2.2.13` must be applied to UAT first** — that is a prerequisite, not a preference.

| # | Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| **M1** | Details overlay shows no stray id row | DEV (post-A1+B1) | 1. Master Data → SKU 2. eye icon on `ICE PACK` | overlay renders **"Default Putaway Location: PutAwayLane"**; **no** `PutawayLocationId` row anywhere | |
| **M2** | A1 without `B1-pre` — **observe the hazard, do NOT deploy it** | **local `yarn dev` or a branch preview — NOT DEV** | run the UI locally against a build carrying A1 but **without** `'putawayLocationId'` in `exclude-fields`; open the overlay | a `PutawayLocationId` raw-integer row **DOES** appear. **This is the hazard §6.1 predicts** — confirm it, then confirm the `exclude-fields` line removes it. Do not skip: it proves the mitigation is load-bearing. ⚠ **r2: this is an OBSERVATION, not a deployment.** r1 read as "deploy A1 only to DEV" — but §5.1 row 4 now makes `B1-pre` a hard prerequisite of A1, and DEV auto-deploys on push, so shipping the ordering the row forbids in order to watch it fail is not a test, it is the defect | |
| **M3** | Effective value when nothing is configured | DEV (post-A2, post-`V2.2.13`) — ✅ **`V2.2.13` APPLIED to `wms2-wineco-dev` 2026-08-12 (confirmed by Nam), so this row and M5 are UNBLOCKED.** The prerequisite was previously unverifiable from here: the verify script only checks the migration FILE exists in the repo, never that any database has it | pick a SKU whose `putawaylocation_id` is NULL; open the dialog | shows *"Inherits: Standard putaway lane — Put Away Lane"*. **Never the machine name `PutAwayLane`** | |
| **M4** | Set a valid destination end-to-end | DEV (post-B2) | dialog → pick an **eligible** location → Submit | success toast; overlay re-reads and shows the new name; `SELECT putawaylocation_id FROM itemdata WHERE id=…` matches; a `putaway_config_audit` row exists with SKU + previous + new + user + timestamp (AC9) | |
| **M5** | Clear back to default | DEV (post-B2, post-`V2.2.13`) | dialog → **Clear / Use default** → confirm | request URL has **no** `?locationId=` at all; DB value becomes **NULL**; overlay flips to *"Inherits: …"*; an audit row records the clear (AC4) | |
| **M6** | 422 reaches the operator (**the CORS landmine**) | DEV (post-B2) | pick a **blocked** location (fix-assigned or locked) → Submit. Watch the browser Network tab | the toast shows the **specific validation message**. ⚠ If it shows the generic *"network or server issue"* AND the response has no `Access-Control-Allow-Origin`, 2732's handler used `response.reset()` — file against 2732; `resetBuffer()` is the fix. **No unit test can catch this** (MockMvc installs no `CorsFilter`) | |
| **M7** | Permission gate — read-only user | DEV (post-B1) | ⚠ **REWRITTEN r7 — the r6 instruction was untestable as worded.** Log in as a user who is **NOT a member of the `sb_admin` Keycloak GROUP** — the role arrives in the `groups` claim, not `resource_access`, so "without the `sb_admin` resource role on `om1-api`" describes a condition that is true of *every* user including real admins. **The `KEYCLOAK_CLIENT` check is DELETED: it was never the discriminator.** Then open the SKU screen and the overlay. **Second half, and do not skip it:** repeat as a **real `sb_admin`**, and **hard-reload directly onto the SKU screen** — that reload is the exact scenario in which 2732's non-reactive computed left a genuine admin permanently locked out, and it is invisible if you only ever navigate in from another page | read-only user: the configured value **is visible**; the pencil and Submit are **present and disabled with a tooltip** — not hidden (AC1 for read-only users + AC12's UI half). `sb_admin` after a hard reload: the pencil is **enabled**, on the first paint after auth settles | |
| **M8** | Permission enforcement — the backend boundary (**AC12, not automatable**) | DEV (post-2732 Phase 1-API) | as a non-`sb_admin`, `curl -X PUT '/v3/putawayConfig/sku/874400?locationId=…'` | **403**, not 500 and not 200. ⚠ **A 500 now means SBDEV-2863's repair REGRESSED** — not that 2732 mis-merged. `Authority.IS_SB_ADMIN` renders `hasAuthority('sb_admin')` since `675b4a1` (2026-08-07), so 2732 carrying that constant is **correct**; row 0e is discharged. Cross-check verify row `X-authz-constant`, which catches the same regression statically. `standaloneSetup` (`BaseControllerUnitTest:52-58`) cannot assert this and the IT lane is down (SBDEV-2217), so **this row IS the AC12 evidence** | |
| **M9** | The resolver is not called from the controller | DEV (post-A2) | `curl '/v3/itemData/874400/effectivePutawayDestination'` | **200** with the 7-field envelope. **A 500 with `IllegalTransactionStateException` means the controller calls the resolver directly** (§3.2/§3.6). No mocked test can prove this | |
| **M10** | ⚠ **REWRITTEN 2026-08-09 — r3.** **D1 — pick faces ARE offered, the write SUCCEEDS, and a foreign-bound flowbin is excluded** | DEV (post-B2) | **(a)** open the dialog and search for a known flowbin by name and for `ICE`; **(b)** read the always-visible scope banner and the advisory; **(c)** save `ICE PACK` to its own pick face through the UI; **(d)** then try a flowbin whose `FixLocationAssignment` belongs to a *different* SKU (1,344 of 2,068 on wineco dev qualify) | **(a)** the picker **DOES** return flowbin rows, `ICE PACK` among them; **(b)** the banner shows the computed `{eligibleCount}`/`{totalCount}` (never hard-coded — r3 F-1) and the advisory says the destination is **routed via putaway, not placed directly**, and that the stock arrives when someone puts it away rather than when the receipt closes; **(c)** the write **SUCCEEDS** — a SKU-scope pick-face write is legal under Q12 → (iv-b); **(d)** the foreign-bound flowbin is **not offered** (2732 rule (f)). ⚠ **r2's version of this row asserted the exact opposite on every point — picker returns no flowbins, API returns 422 — and cited `skuWriteRejectsPickFaceDestination`, a test 2732 DELETED on 2026-08-08. It could never pass against a correct implementation.** Record (c)'s response body — it is also M6's CORS evidence |
| **M11** | Persistence after refresh (**AC5**) | DEV (post-B2) | set a value → hard-refresh (F5) → reopen the overlay | the new value shows. `masterData.skuData` rehydrates from `localStorage['vuex-web']` but `skuData.vue:304` always refetches (§3.8.5) | |
| **M12** | Receiving display is unregressed | DEV (post-B1) | open Receiving → an open notice → the receive form | "Inbound Putaway Staging" renders exactly as before B1. **B1 moves `receivingForm.vue`'s constants — this row proves 2731 was not regressed** | |
| **M14** | ✅ **EXECUTED 2026-08-12 — SQL LAYER PASSED; R11 CLOSED ON THE ROW SET. HTTP layer still open (needs a bearer token).** <br><br> **Run, and better than this row asked for:** rather than compare `totalElements` to a remembered pre-A4 baseline, the shipped predicate was executed directly against **`dev_wh01_om1`**. `WHERE name <> 'PutAwayLane'` returns **2,738** of **2,739** locations, and the single excluded row is exactly the one `PutAwayLane`. That is **arithmetically complete — no location is missing and no baseline is needed**, which is stronger evidence than the comparison this row specified. Zero NULL-name rows, so the `<>` predicate drops nothing silently. <br><br> **A4's new query also verified on PG14:** term `ICE` → 1 row, term `ice` → 1 row (case-insensitivity confirmed on real data, not just in the `@Query` text), and it executes without error — the portability the H2-only lane could not show. <br><br> ⚠ **AND A FINDING THAT NARROWS R11 RETROSPECTIVELY:** the match-everything wildcard the design forbids — `lower(name) LIKE lower(concat('%','','%'))` — **also returns 2,738**. So on this tenant a blank term routed through the filtered query would NOT have lost a single row. **R11's silent-row-loss scenario does not materialise here.** The split-query design is still right, because it makes the guarantee structural instead of resting on one tenant measured once — but the risk was narrower than the plan feared, and that is worth knowing before anyone treats R11 as a near-miss. <br><br> **STILL OPEN (needs a token, not a DB):** the HTTP layer — that `?name=` binds to `""` and normalises rather than 400-ing, and that the two shipped pickers' own requests are unchanged end-to-end. The service routing is unit-tested; the binding is not. | ~~DEV (post-A4, **before** B2)~~ **DONE (SQL) / token needed (HTTP)** |
| ~~**M14** (original wording)~~ | ⚠ NEW 2026-08-12 — R11's other half: the two SHIPPED pickers still return their FULL sets (Phase A4) | DEV (post-A4, **before** B2) | **(a)** `curl '/v3/putawayConfig/eligibleLocations?scope=WAREHOUSE&size=1'` and the same for `scope=MERCHANT&subjectId=<a client id>`, and record `page.totalElements` for each; **(b)** compare against the pre-A4 value — take it from the DEV build running before this PR merged, or from `SELECT count(*) FROM location WHERE name <> 'PutAwayLane'`; **(c)** repeat with `&name=` (empty) and `&name=%20%20%20` (whitespace); **(d)** then open the **Operation Options** control and the **shipper** screen in the UI and confirm each picker still lists what it listed yesterday | **(a)+(b)** `totalElements` is **IDENTICAL** to the pre-A4 value on both scopes; **(c)** identical again — an empty or whitespace term is not a search; **(d)** both shipped screens unchanged. ⚠ **RECORD BOTH COUNTS, AND DO NOT CONFUSE THEM — the plan quotes two numbers for this endpoint and they measure different things.** `totalElements` is **2,564** at *every* scope on wineco-dev, because the candidate query takes only the excluded lane name and the `Pageable` — **there is no scope parameter in it**; scope decides each row's `eligible` verdict, never which rows come back. The **~516** figure in §8.4 row 3a and §3.5a is the count of rows with `eligible: true` at WAREHOUSE/MERCHANT (against ~2,554 at SKU — that gap *is* the pick faces, legal at SKU scope under Q12 → (iv-b) and refused at the other tiers). **So seeing 2,564 at merchant scope is CORRECT, not a regression.** A drop in `totalElements` is the R11 defect (revert `b40a990`, one commit); a shift in the eligible count with `totalElements` intact is a validator change and is NOT A4's. ⚠ **THIS ROW EXISTS BECAUSE A4's UNIT TESTS STRUCTURALLY CANNOT SHOW IT.** They prove the filtered query is never *reached* for a blank term (`blankNameIsIdenticalToNoNameFilter`) and that the shared query carries no name predicate — but "the SQL Postgres actually runs returns the same rows on a real tenant" needs a real tenant. R11's failure mode is **silent**: a dropped legal destination produces no toast, no 4xx and no log line, and the operator concludes the location was never configured. **Do not archive 2643 on the strength of a green suite alone** | |
| **M13** | SQL-level sanity | DEV DB | `SELECT id, putawaylocation_id FROM itemdata WHERE id=874400;` then `SELECT * FROM putaway_config_audit WHERE itemdata_id=874400 ORDER BY id DESC LIMIT 5;` | value matches the UI; audit rows carry all six required fields (SKU, facility, previous, new, user, timestamp) | |

#### 7.5a Manual execution log — FIRST REAL RUN, 2026-08-13 (wineco/wsl, `dev_wh01_om1`, user `panderson`)

| Row | Result |
|---|---|
| **M1** — no raw `putawayLocationId` row in the details overlay | ✅ **PASS.** A1 widened the payload; §6.1's `fullDetails.vue` hazard did not materialise |
| **M4** — set a valid destination end-to-end | ✅ **PASS.** `itemdata(874400).putawaylocation_id = 225817` (`ICEPACK`), `modified 14:22:45.892Z` |
| **M5** — clear back to inherited | ✅ **PASS.** Back to `NULL`, second audit row `225817 ICEPACK → NULL`. ⚠ Confirms the store **omits** `locationId` from the query string rather than sending `null` — the D-A clearing contract, and the one thing a Jest test of the action could not prove end-to-end |
| **M6** — a rejected write surfaces the SERVER's message | ✅ **PASS, and it also clears `response.reset()`.** Provoked with a temporary, reverted `UPDATE location SET area_id = 51555 WHERE id = 225817`: a real 422 whose specific text — "its area is not used for goods-in or storage" — reached the toast. A cross-origin body is unreadable to JS without `Access-Control-Allow-Origin`, so the message arriving **is** the CORS evidence (see the `resetBuffer()` landmine) |
| **M10(a)** — flow bins ARE offered at SKU scope | ✅ **PASS** — `ICEPACK` appeared and was selectable |
| **M10(d)** — a foreign-bound flow bin is NOT offered | ✅ **PASS, discovered accidentally.** `ICEPACK` is fix-assigned to 874400, and the picker correctly withheld it while editing `Savory Sipce PDX` (929408) |
| **M11** — the value survives a reload | ✅ **PASS** — F5 re-reads from the API, not from persisted Vuex |
| **M13** — SQL/audit sanity | ✅ **PASS.** `putaway_config_audit` id 8804: scope `SKU`, subject 874400 `ICE PACK`, tenant `wineco`, facility `wsl`, previous `NULL`, new `225817 ICEPACK`, channel **`typed`**, `changed_by panderson`. All six AC9 fields present. Audit stamped 40 ms BEFORE `itemdata.modified` — audit first, then the entity |
| *(not on the plan)* — a rejected write neither writes nor audits | ✅ **PASS.** After M6's 422, `putawaylocation_id` was unchanged and no audit row was written. The validator runs before both |

**Still outstanding:** **M7** (the permission gate — needs a non-`sb_admin` login, plus the
hard-reload-as-admin half), **M12** (receiving display unregressed), **M3**, **M8**, **M9**.
**M2** is moot — `B1-pre` shipped ahead of A1 exactly as §8 designed, so the window it tested never existed.

> [!danger] **⚠ AC9 CANNOT BE EVIDENCED BY "AN AUDIT ROW EXISTS" — 8,803 ALREADY DID, BEFORE ANY USER ACTION.**
> `V2.2.13` normalised the old sentinel: every SKU explicitly pointed at `PutAwayLane` (id 51605) was set to
> `NULL`, because in the four-tier model "not configured" IS "inherits the standard lane" — and it wrote one
> audit row per SKU, all `channel = 'migration'`, `changed_by = 'V2.2.13'`, all at `2026-08-11 13:50:50Z`.
> **Any AC9 check must filter `channel <> 'migration'`** or it passes on migration provenance. Same vacuity
> class as the verify-script traps, this time living in the data. Non-migration rows before this run: **0**.

> [!warning] **⚠ FIVE FALSE FACTS NOW FOUND IN §3.8.2a — treat every unchecked figure there as fiction.**
> | claimed | measured 2026-08-13 |
> |---|---|
> | 2,564 candidate locations | **2,738** |
> | 13 sequential round-trips | **14** |
> | 2,554 eligible at SKU scope | **1,206** |
> | `ICEPACK` is in an `Inbound` area, `useforstorage = false` | **`Storage and Picking`, `useforgoodsin = false`, `useforstorage = true`** |
> | pick faces dominate the eligible set | the eligible set is **entirely** `ADVANCED`; zero `DEFAULT` for a Case SKU |
>
> ⚠ **AND THE CONSEQUENCE IS A PRODUCT QUESTION, NOT BOOKKEEPING.** All 8,804 SKUs on this tenant are
> `defultype_id = 4` (Case); the ONE goods-in area holds 12 locations that permit either unit-load type 5 or
> nothing at all. So **zero** goods-in destinations exist for any SKU here, and the ticket's headline use
> case — point a consumable SKU at its dedicated bin — sits behind the "Show storage locations" toggle by
> default. The single pre-existing real override (`2015 Roosevelt Pinot Noir` → `Club08`) is a storage
> location too. **Defaulting that toggle off hides the primary path on this tenant.**

> [!done] **THE TOGGLE QUESTION IS SPUN OUT — [SBDEV-2947](https://app.clickup.com/t/868kr048e), raised 2026-08-13.**
> **It is deliberately NOT 2643's to answer, and 2643 does not wait on it.** The toggle belongs to
> SBDEV-2732's shared `defaultPutawayLocationField` / `LocationPicker`, so changing its default moves
> tier 2 and tier 3 as well; 2643's own code is merged, on dev, and behaves correctly once the toggle is on.
> Blocking a finished ticket on someone else's product call would have been the wrong trade.
>
> The measured basis is carried on 2947 in full so nobody re-queries the tenant — including a figure this
> section never had: **2,068** locations a Case SKU can use, **all** `ADVANCED`. Its four options, in
> ascending cost: (1) default the toggle **ON at SKU scope only** — recommended, tier 1 IS the dedicated-bin
> tier and the lock warning still renders; (2) default it on when zero `DEFAULT`-tier rows are eligible —
> data-driven, but silently flips a safety default; (3) discoverability only — **already merged** as
> wms2-web-ui #56's tier-split caption, so option 3 is the standing safety net whatever else is decided;
> (4) fix the tenant's `useforgoodsin` / `location_constraint` data — arguably the real gap, but it changes
> receiving far beyond this screen.
>
> ⚠ **One genuinely separate finding, recorded there and owned by nobody yet:** `HubAndSpoke-01`…`-10`
> (type `System`, in the goods-in area) have **no `location_constraint` rows at all**, so they accept no
> unit-load type whatsoever. That is why the goods-in tier is empty rather than merely narrow. If those
> ten are meant to receive hub-and-spoke transfers, the gap predates every putaway ticket.

### 7.6 e2e lane

No Cypress/Playwright suite is wired for this area (`cypress/` exists but is excluded from Jest and
carries no SKU spec). **e2e coverage is the manual plan above**, specifically the M4 → M5 → M11 chain
(set → clear → survive refresh) and M10 (D1's boundary, proven from both sides — the picker's omission
and the API's 422). Recorded as a deliberate gap, not an omission.

### 7.7 Observability lane

| Signal | Source | What it proves |
|---|---|---|
| `wms2.putaway.resolution{source="SKU_OVERRIDE"}` **> 0** | 2732's `PutawayResolutionMetrics`, inherited | **2643's own adoption gate.** Zero = the feature shipped inert (pre-mortem PM2) |
| `wms2.putaway.config.changed{scope="SKU"}` | same | writes are landing through the validated writer, not the legacy GET |
| `wms2.putaway.resolution.rejected` | same | a configured destination is failing P1 at receive time. ⚠ **r2: this is no longer D1's residual risk** (there is none — pick faces cannot be configured). Non-zero now means either a **pre-existing** DB-written configuration is invalid (2731's PRD case, exactly what filed that ticket) or a write-time predicate and a receive-time check disagree — **a 2732 bug, worth escalating rather than accepting** |
| HTTP 500 rate on `/v3/itemData/*/effectivePutawayDestination` | logs | a non-zero rate is the `IllegalTransactionStateException` signature (M9's failure mode) |
| `SpelEvaluationException` / `EL1004E` in logs | logs | **Should already be zero everywhere** since SBDEV-2863 `675b4a1` repaired the constant. Any occurrence now is a **regression of 2863**, not a 2643 or 2732 defect — same signal as verify row `X-authz-constant` |
| `40P01` / `DeadlockLoserDataAccessException` on `/receiving/receive` | logs | §7.4 row 8's lock-order inversion, armed by a storage-location or pick-face config. **Must be log-based** — `/receiving/receive` returns 200-with-`errors`, never 5xx, so an HTTP-status alert misses it entirely |

### 7.8 Test execution — FILLED IN 2026-08-12 (PRs 1 + 2 only)

Measured in the per-ticket worktrees, not the main checkouts. Both roots stated, always.

| Lane | Command | Result |
|---|---|---|
| A1 units | `mvn -o test -Dtest=ItemdataServiceUnitTest` | **36 run / 0 fail** (32 pre-existing + 4 new) |
| Compile | `mvn -o clean compile` | clean — catches the DI/signature drift an incremental compile misses |
| B1-pre Jest | `node_modules/.bin/jest test/components/masterData/material/skuData/` | **1 pass / 1 total** |
| Web full | `node_modules/.bin/jest` | **251 pass**, 27/28 suites. ⚠ `test/NuxtLogo.spec.js` fails to run — **pre-existing, reproduced on clean develop** |
| Verify (develop) | `PROJECT_ROOT=v2/wms2-api WEB_UI_ROOT=v2/wms2-web-ui` | `23 pass / 70 fail / 0 skip` |
| Verify (worktrees) | `PROJECT_ROOT=<api wt> WEB_UI_ROOT=<web wt>` | **`31 pass / 62 fail / 0 skip`** — 8 gains, **0 regressions** |

**Rows turned green:** `A1-id`, `A1-async`, `A1-name`, `A1-repo`, `A1-neg-res`, `A1-t1`, `A1-t2`, `A1-t3`,
`B1-exclude`, `B1-jest`. Every remaining red maps to an unshipped phase — §8.0a criterion (3) holds.

⚠ **`archunit_store` was NOT mutated.** Confirmed by `git status` after every run; targeted `-Dtest=<Class>`
does not touch it (only a full `mvn test` does). The full API suite was deliberately **not** run — skill
rule 4 — so the 2/4442 known `develop` failures (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`)
are quoted from the project record rather than measured here.

**Mutation evidence, both directions.** Four mutants run against the A1 tests:

| Mutant | Caught by |
|---|---|
| `put` moved inside `isPresent` | `whenConfiguredButDangling` + `shouldSourceIdFromTheEntity…` |
| id sourced from `location.get().getId()` | both of the above |
| `location.map(Location::getId).orElse(fk)` | **only** `shouldSourceIdFromTheEntity…` — the reason that test exists |
| fixture ids harmonised (55555 → 100) | the asserted **fixture premise** — silently green before that guard existed |

Also negative-tested: `A1-t2` after widening, and B1-pre's Jest assertion (`putawayLocationIdFoo` fails).

#### 7.8a PR 4 — Phase A4 (measured 2026-08-12)

| Lane | Command | Result |
|---|---|---|
| A4 units | `mvn test -Dtest=PutawayDestinationQueryServiceUnitTest,PutawayConfigControllerUnitTest` | **44 run / 0 fail** (A4's own 6 + 2732's 14 in the same two classes + 24 siblings) |
| Full API suite | `mvn clean test` | **4955 run / 2 fail** — both the known `develop` baseline: `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` (8 violations across **five** classes — `MobileReplenishService:1024`, `PickLineRealignmentService:80,81`, `ReplenishGeneratorService:210`, `ToteStateService:80,96`, `UnitloadBusinessService:751,755` — **none** in a file A4 touches) and `MobilePalletizingServiceTest`. **Zero new red.** ⚠ An earlier version of this row named only three of the five classes; corrected after a review lane re-derived the list. The substantive point was unaffected, but a half-quoted baseline is how a *new* violation later gets mistaken for an old one |
| Verify (worktree) | `PROJECT_ROOT=<api wt>` | **`54 pass / 42 fail / 0 skip`** — all 7 `A4-*` rows green; the 42 reds are **25 B2 + 15 B1 + the 2 dialog rows**, every one an unbuilt UI phase |
| ArchUnit store | `git status` after the full suite | **mutated, and reverted** — the full `mvn test` does touch it (targeted `-Dtest` runs do not) |

> [!warning] **⚠ `-Dtest='A+B'` REPORTED `Tests run: 0` AS SUCCESS.** The first attempt at the targeted lane
> used the `+` separator — which is the **method** separator — so it matched no class, ran nothing, and with
> `-DfailIfNoTests=false` exited 0 with no output. It looked like a clean pass. **Use commas between test
> CLASSES.** This is the recorded `@Nested` landmine wearing a second face, and §5.5a's command was
> corrected from `+` to `,`.

**Mutation evidence — three source mutants, applied and reverted:**

| Mutant | Caught by |
|---|---|
| blank term routed through the FILTERED query (the R11 defect) | 3 of A4's 6 tests error **and 7 of 8 of SBDEV-2732's merged `EligibleLocationsRead` tests break** — the blast radius R11 predicts, demonstrated |
| filter made case-**sensitive** and prefix-anchored | exactly `theFilteredQueryLowercasesBothSidesAndKeepsItsSiblingsPredicates` |
| a name predicate added to the SHARED unfiltered query | that same test's R11 assertion (`doesNotContain(":nameFilter")`) |

> [!danger] **⚠ AND THE MOST IMPORTANT VERIFY ROW DID NOT WORK — a fifth distinct failure mode for this
> script, on top of the four already recorded.**
>
> `A4-split` is the row that asserts R11 itself. Its first version stayed **GREEN** while the shared query
> was mutated exactly as the row's own description forbids: the negative demanded `nameFilter` appear
> *after* a `countQuery`, but the defect lands in the `value` query, which comes **first**. The row was a
> true assertion about a place the defect cannot occur.
>
> It was only caught because the mutants were run against **both** the tests and the script — the unit test
> caught this mutant on its own, so a test-only mutation pass would have concluded the gate worked. Rewritten
> as a positive with a **tempered-greedy gap** (`@Query((?:(?!@Query)(?!nameFilter)[\s\S])*?…findPutawayCandidates\()`),
> then re-negative-tested against two variants — the predicate in the `value` query **and** in the
> `countQuery` alone. Both now red.
>
> **The lesson generalises:** negative-testing a verify row is not the same as negative-testing the tests,
> and a row whose regex encodes an assumption about *where* in a file a defect will appear is only as good
> as that assumption. Prefer tempered-greedy containment over positional `{0,N}` gaps.

#### 7.8c PR 5 — Phase B1 (measured 2026-08-12, commit `0b5f06a`)

| Lane | Command | Result |
|---|---|---|
| B1 spec | `jest test/components/masterData/material/skuData/skuData.spec.js` | **9 run / 0 fail** (8 gate + 1 added for `editPutaway`) |
| ⚠ 2731 guard | `jest test/components/receiving/open/receive/` | **44 / 0** — the row that matters, since B1 moves constants `receivingForm.vue` consumes |
| Web full | `jest` | **259 passed**, 27/28 suites. `test/NuxtLogo.spec.js` fails to RUN — pre-existing, reproduced on clean develop |
| Lint | `eslint` on the 3 source files | **33 problems / 0 errors — EXACTLY the count on the same files on develop**, verified per-file, so the new module is clean and the diff adds nothing |
| Verify | `PROJECT_ROOT=<api wt> WEB_UI_ROOT=<web wt>` | **`69 pass / 27 fail / 0 skip`** — 54 → 69, **all 20 `B1-*` green, 0 PASS→FAIL**; every red is B2 |

**Both lanes PASSED (0 High).** Code review: 0 High / 7 Medium / 11 Low, verdict *"merge after M1–M5"*; all seven Mediums and six Lows applied. Conformance: PASS with one required fix.

> [!danger] **⚠ THE FINDING TO CARRY INTO EVERY FUTURE PHASE: RESTORING PARKED GATE TESTS BY CHECKOUT
> SILENTLY REVERTS WHATEVER SHIPPED SINCE.**
>
> B1 reconstituted `skuData.spec.js` with `git checkout tdd-gate/SBDEV-2643 -- <file>`. That branch was cut
> at gate time, **before PR 1 merged** — and PR 1 had *strengthened* the one assertion it carried, from
> `toContain('putawayLocationId')` to `toMatch(/'putawayLocationId'/)`, with a comment explaining that
> `toContain` also passes on `'putawayLocationIdFoo'`. The checkout reverted the assertion **and deleted its
> reasoning**, and the suite stayed green at 8/8 — measured: mutating `exclude-fields` to
> `'xputawayLocationIdFoo'` left every test passing. Contained only because verify row `B1-exclude` catches
> the same mutant, and §8.0a criterion 2 could not see it because it grades verify rows, not assertions.
>
> **Both lanes found it independently, and I had not noticed.** A parked gate branch is a **snapshot of the
> plan's intent at gate time, not a superset of what has shipped**. §8.0a's carry-forward rule now means:
> **MERGE the parked tests onto the current file; never check out over it.** B2 restores
> `editSkuPutawayDialog.spec.js` from that same branch — this applies directly.

| # | Finding | Why it survived my own passes |
|---|---|---|
| **M6** | ⚠ **The row pencil had NO rendering coverage, and my comment named the wrong cause.** I blamed `v-data-table`'s stub for swallowing it; the real cause is that `v-tooltip: true` never invokes the activator slot **both** buttons live in. So the "present and disabled" assertion was silently grading only the overlay button — the affordance D5 argues for at length was covered by a source regex alone. Fixed by stubbing the tooltip to invoke its activator; both controls render and the count is 2 | I wrote a confident mechanism I never verified by dumping the rendered tree. The count-pin I added *for* robustness was itself pinned to the stub list |
| **M1** | The `editPutaway` javadoc claimed both callers pass `id` **and `itemNr`**. The table row carries **no `itemNr`** (`ViewDtoService.getItemDataViewPage` emits 10 fields, not that one) — so B2 keying dialog chrome on it would render blank from the pencil and correctly from the overlay | I asserted a payload shape from plausibility instead of reading the projection. **A comment can pre-seed a bug in a phase that has not been written yet** |
| **M3** | The §5.8 deviation I was about to escalate **did not exist**. The requirement is on the **tooltip text**, not the `disabled` binding, so naming the blocking ticket satisfies §5.8 and §5.6 verbatim at zero cost. My comment also *overstated* the conflict — `B1-disabled` is unanchored and would have survived option (b); only the Jest source assertion is anchored | I conflated the two halves of one requirement and then reasoned confidently from the conflation. **Both lanes converged on the same resolution independently** |
| **M7** | The mock's "mirror the real module's shape" comment was false on three keys; the missing `pagination.totalItems` made `totalPages` **NaN** and rendered `length="NaN"` | A fidelity claim nobody had checked against `store/masterData/skuData.js` |
| **M2 / M4 / L1 / L5 / L9** | overlay button disabled with **no** tooltip while the same file argued disabled controls need one; `editPutaway` untested **and** `$toast.info` absent from the mock, so the first test written for it would die on scaffolding; a dead `eslint-disable`; a test regex truncating at a nested `</template>` and passing by luck; a `mounted()` comment contradicting 2732's sibling | Each is a small internal inconsistency of exactly the kind a second reader sees and the author does not |

**Verify rows fixed this phase (4 stale + 2 tightened):** `B1-disabled`, `B1-neg-vif` and `B1-jest2` still asserted the r6 identifier `isPutawayConfigAdmin` — **three rows that would have stayed red against a fully correct r7 implementation**, in the phase whose gate has been specified wrong twice. `B1-word3` was a line-based ERE that could not see a multi-line import. And `B1-perm`'s third conjunct had gone **permanently vacuous** at the r7 rename — it forbade an identifier that no longer exists, so the row's whole "not a computed" half asserted nothing while reporting PASS; retargeted at `isSbAdmin() {` and negative-tested.

**Design note taken:** the permission tooltip now says *"This setting is managed by SiteBoss support"* rather than *"contact your administrator"* — `sb_admin` is a staff group, so no customer administrator can grant it and the old wording sent users to someone who cannot help.

**Flagged, not fixed (out of B1's scope):** three more commented-out corpses survive in `skuData.vue` (an upload-CSV button, a Create-New/Export pair, and a **duplicate `#[footer.prepend]` block directly above the live one**). §3.8.1's delete-the-corpse logic is now half-applied in that file.

#### 7.8b A4's two independent lanes — both PASSED, 0 High, 9 findings fixed

| Lane | Verdict | Findings |
|---|---|---|
| **3a conformance** (`verifier`, opus) | **PASS** | 2 required fixes + 2 doc nits — all applied. It re-derived all three mutants independently and got identical numbers |
| **3b code review** | **PASS — "merge after two one-line fixes"** | **0 High**, 3 Medium, 5 Low. M1/M2/M3 + L1/L3/L5 applied; L2/L4 accepted as notes |

**The findings that mattered, and what they say about this plan's own habits:**

| # | Finding | Why it survived my own passes |
|---|---|---|
| **M1** | The new query was **published over HAL** — `RestConfiguration:47` is `ANNOTATED` and the repo carries `@RepositoryRestResource`, so query methods export **by default**. `GET /v3/location/search/findPutawayCandidatesByName?nameFilter=` was reachable by any `wms_user` and would run the match-everything wildcard §3.5a forbids — **falsifying the invariant its own javadoc asserted two paragraphs below**. Fixed with `@RestResource(exported = false)` | I reasoned "match the sibling", and the sibling is the file's **only** unannotated method out of 21. Matching a convention I had checked against a single neighbour instead of the file. Same class as the **SBDEV-1666** landmine, which is already in this vault |
| **M2** | The javadoc credited verify row `A4-inquery` with pinning the excluded-lane clause and the `ORDER BY`. It pins **neither** — the unit test does | I wrote that citation *before* hardening the row, and never re-read it after. The duplication this phase accepts is only defensible while a reader can find the real guard |
| **M3** | "A metacharacter can only widen, never narrow" was **false, and measured**: backslash is the default `LIKE` escape char, so on H2 2.3.232 `A%B`→3 rows, `A\%B`→**1**, and a term ending in `\`→**zero rows** | I asserted an absolute about SQL semantics from reasoning, in three places, and used it as design justification. Still unescaped — scoped decision, recorded above — but the claim is corrected |
| **L1** | The case-folding assertion was three loose checks a **prefix-only** regression satisfied, while its own message claimed to rule that out | The exact vacuity class this plan had already fixed twice. Now asserts the whole pattern; negative-tested |
| **L3** | The overload loop pinned `value` + `readOnly` but not **propagation**, so a later `REQUIRES_NEW` would open a second tenant transaction with nothing red | I wrote "so the two cannot diverge" while the test could not see transaction settings at all. Negative-tested |
| **L5** | "Can reorder an unsorted page" — **wrong reason**: this query has a total ordering (`ORDER BY` + unique `l.name`) | A wrong reason beside a right decision. Dropped, not reworded |

**Two things the lanes established that I had understated:**
- **The new JPQL *is* parse-validated in CI.** `OmsNotificationConfigContextLoadTest` really boots (21.7 s measured) and bootstraps `LocationRepository`, so a malformed `CONCAT`/`LOWER`/`:nameFilter` breaks the boot rather than shipping green. My PR draft had claimed nothing parses it.
- **The reshaped gate tests were worse than "unsatisfiable".** The lane diffed against `tdd-gate/SBDEV-2643` and found them **internally contradictory**: the gate's own javadoc mandates the filter be in the query, yet its remedy ("extend the stub") combined with an assertion about narrowing is satisfiable *only* by the service-side `stream().filter()` that javadoc forbids. Under the split design they don't even fail cleanly — `search("RACK")` NPEs on the unstubbed sibling. Reshaping was the correct resolution, not a bend-to-fit.

> [!note] **⚠ FLAGGED FOR SBDEV-2732, NOT FIXED HERE (§14 principle 1).** With A4's sibling now explicitly
> closed, `findPutawayCandidates` is the **only** unannotated query method left in `LocationRepository`, so
> `GET /v3/location/search/findPutawayCandidates` stays exported — and it is the query the two shipped
> pickers use. Pre-existing, not A4's regression, and out of A4's scope. Worth a deliberate decision by
> whoever owns 2732 rather than leaving it as the file's odd one out.

**Also caught, and worth keeping:** verify row `A4-branch` (`no LIKE '%%'`) went red against a **correct**
implementation, because the service's own javadoc *quoted* the wildcard it forbids. A code-shape row cannot
tell code from prose. Fixed by paraphrasing in the javadoc — the same paraphrase-not-quote convention
`PutawayDestinationQueryService` already uses further up the file for exactly this reason.

> [!danger] **⚠ A SIXTH FAILURE MODE, AND IT HIT FOUR TIMES IN TWO PHASES: A NEGATIVE ROW CANNOT TELL CODE
> FROM PROSE — AND A POSITIVE ROW CANNOT EITHER.**
>
> Every occurrence was a **correct implementation turned red by its own explanatory comment**:
>
> | Row | What the comment quoted | Phase |
> |---|---|---|
> | `A4-branch` | the forbidden match-everything wildcard, while explaining not to use it | A4 |
> | `B1-neg-cfg` + the `gateComesFromTheSharedRoleHelper` test | the two dead gate forms, while explaining they are dead | B1 |
> | `B1-neg-corpse` | the deleted block's placeholder labels, while explaining they were deleted | B1 |
>
> **And the mirror image, which is worse because it fails SILENTLY:** the `editPutaway` javadoc quoted the
> `:disabled` binding, which would have kept the *positive* source-text assertion
> `toMatch(/:disabled="!isSbAdmin"/)` **green with no real binding in the template at all**. Found by
> probing what the rendered-tree assertion actually matched, not by any red row.
>
> **Convention, now used throughout both files: DESCRIBE the forbidden or asserted string, never quote it**,
> and say in the comment that the paraphrase is deliberate so the next editor does not "helpfully" restore
> the literal. The alternative — teaching every row to strip comments — is a Vue/Java comment parser in
> bash, which is not worth building.

### 7.9 Deliberately-skipped coverage

| What | Why |
|---|---|
| Any Testcontainers integration test | v2 IT harness is down (SBDEV-2217). New ITs are `@Disabled` with `TODO(SBDEV-2217)` |
| `@PreAuthorize` enforcement as a controller test | `BaseControllerUnitTest:52-58` uses `standaloneSetup` — no filter chain, no method-security advisor (F2). Proven by **SBDEV-2863's** SpEL test + manual **M8**. *(F2 is unaffected by 2863 and still stands — 2863 fixed the expression, not the harness.)* |
| The CORS/`reset()` interaction | MockMvc installs no `CorsFilter`, so no unit test can reproduce it. Manual **M6** |
| Resolver propagation semantics | a Mockito mock has no propagation semantics — a mocked test passes against a controller that calls the resolver directly. Code-shape check `A2-neg-res` + manual **M9** |
| `ItemDataController.java:182`'s `.get(0)` `IndexOutOfBoundsException` | pre-existing (F6), zero UI consumers, out of scope. Named so it is not "discovered" mid-implementation |
| The 9 endpoints `Authority.IS_SB_ADMIN` breaks | SBDEV-2863's scope |
| A SKU table column | Q4 answered no column |

---

## 8. Rollout

**2643 ships zero migrations, so there is no operator gate and no per-tenant apply step** — the whole
Flyway hazard class that dominates 2732's rollout simply does not apply here.

| Order | Phase | Repo | Branch | Merge target | Deploy note |
|---|---|---|---|---|---|
| ~~1~~ | ~~**A0** (detector, test-only)~~ **RETIRED r5 — do not cut this branch** | ~~`wms2-api`~~ | ~~`fix/SBDEV-2643-A0-sb-admin-spel`~~ | — | **SBDEV-2863 shipped it on 2026-08-07** (PR #134, `675b4a1`). The rollout now starts at `B1-pre` |
| 2 | **B1-pre** (one line) | `wms2-web-ui` | `feature/SBDEV-2643-B1-exclude-field` | `develop` | `exclude-fields` += `'putawayLocationId'`. **A provable no-op today** — and a **HARD PREREQUISITE of step 3**, not a preference (§5.1 row 4) |
| 3 | **A1** | `wms2-api` | `feature/SBDEV-2643-A1-itemdata-details-putaway-id` | `develop` | DEV auto-deploys on push. **Must not merge until step 2 is deployed** |
| ~~—~~ | ~~*gate*~~ ✅ **SATISFIED 2026-08-11 (merge `889298d`)** | — | — | — | ~~wait for SBDEV-2732 Phase 1-API's merge commit to land on `develop`~~ (§8.1 — **still assert ancestry before opening each PR**; the local checkout goes stale, and it was 48 commits behind on 2026-08-12). ⚠ **And confirm §5.1 row 0e was honoured** — if 2732 merged with `Authority.IS_SB_ADMIN`, every 2732 write 500s and AC12 is unmeetable until SBDEV-2863 lands |
| 4 | **A2** | `wms2-api` | `feature/SBDEV-2643-A2-sku-effective-putaway` | `develop` | new 2643-owned `SkuPutawayQueryService` + the read endpoint. **Touches no 2732 file** |
| ~~5~~ | ~~**A3**~~ **DELETED r6 — do not cut this branch.** D-D is 2732's, shipped as PR #142 (merge `41c8257`) | ~~`wms2-api`~~ | — | — | — |
| **5a** | **A4** — the `name` search parameter (**NEW r7**) | `wms2-api` | `feature/SBDEV-2643-A4-eligible-locations-name-search` | `develop` | §3.5a. ⚠ **Touches `PutawayConfigController` + `PutawayDestinationQueryService`, which 2732 owns and which serve the WAREHOUSE and MERCHANT pickers too.** DEV auto-deploys on push, so **the empty-search identity test must be green before this merges** — a predicate bug here degrades two shipped screens, not just 2643's. Must land before B2 (the picker's search box binds to it) |
| 6 | **B1** | `wms2-web-ui` | `feature/SBDEV-2643-B1-sku-putaway-surface` | `develop` | Edit button `disabled` + tooltip until B2 lands |
| ~~—~~ | ~~*gate:* wait for SBDEV-2732 Phase 2-UI (`LocationPicker.vue`) on `develop`~~ | — | — | — | ✅ **SATISFIED 2026-08-11** — Phase 2 merged in full (web PRs #42-#49). No gate remains |
| 7 | **B2** | `wms2-web-ui` | `feature/SBDEV-2643-B2-sku-putaway-dialog` | `develop` | then M4–M11, then close 2643 |

### 8.0a How the TDD-gate tests travel across the six PRs — **DECIDED 2026-08-12**

> [!important] **§8's ordering STANDS, and the gate tests move with their phase. Decided by Nam Park
> 2026-08-12 when the TDD gate surfaced the conflict.**
>
> **The conflict.** `wms-tdd-gate` produces **one worktree per repo**, so all 14 API tests were written
> on the A1 branch and all 23 UI tests on the `B1-pre` branch. But §8 mandates **six PRs in a fixed
> order** with a hard deploy gate. Left as-is, **A1's PR would contain failing tests for A2 and A4** —
> every early PR red in CI, which trains reviewers to ignore red.
>
> **The rejected alternative.** Land everything as one PR per repo and drop the ordering. Refused,
> because `B1-pre`-before-A1 is not a preference: DEV auto-deploys on push, and A1 without `B1-pre`
> renders a stray `PutawayLocationId` raw-integer row on **every** SKU details overlay (§6.1, R4).
> Collapsing the order to make the gate tidier ships a known user-visible defect.
>
> **The rule: each PR carries ONLY the tests its own phase turns green.** Later phases inherit earlier
> tests by branching from `develop` *after* the previous PR merged — never from the sibling branch
> (§8.1, and the recorded PR #51 orphan).

| PR | Phase | Tests that travel with it | Left behind for later |
|---|---|---|---|
| 1 | `B1-pre` | `skuData.spec.js` → **`excludesRawPutawayLocationId`** only | the other 7 in that file |
| 2 | **A1** | `ItemdataServiceUnitTest.PutawayLocationIdInDetails` (4) | — |
| 3 | **A2** | `ItemDataControllerUnitTest.EffectivePutawayDestination` (5) | — |
| 4 | **A4** | `PutawayDestinationQueryServiceUnitTest.NameSearchParameter` (**6** as built, not the planned 5 — `theLegacyThreeArgFormIsTheSameCodePath` was added) **+ the widened `takesScopeAndOptionalSubjectId`, which also gained a `required = false` assertion, and its sibling `isReadOnlyOnTheTenantTransactionManager`, fixed to assert EVERY overload** (a `findFirst()` over `getDeclaredMethods()` would have become order-dependent the moment A4 added a second one) | — |
| 5 | **B1** | the remaining 7 in `skuData.spec.js` (relabel, pencil, corpse, the 4 gate tests) | — |
| 6 | **B2** | `editSkuPutawayDialog.spec.js` (15) | — |

> [!warning] **⚠ CONSEQUENCE THE DECISION CARRIES: `verify → 0 fail` IS NOT A PER-PR EXIT CRITERION.**
> Established while executing PR 1 + PR 2 on 2026-08-12. This corrects the criterion originally handed
> to `wms-plan-executor`.
>
> Because each PR carries only its own phase's tests, rows belonging to **parked** phases stay RED until
> those phases ship. So the per-PR exit criterion is three-part, not one:
> 1. every verify row belonging to **this** phase is green;
> 2. **no row that was green on `develop` has gone red** — this is the real regression signal;
> 3. every remaining red is attributable, row by row, to a phase that has not shipped yet.
>
> `Result: N pass, 0 fail` becomes reachable **only at the LAST PR** — and ⚠ **that is NO LONGER PR 6.**
> Corrected 2026-08-12: the A4 server-side search box was split out of B2 into a follow-up PR (wiring it
> converts the shared picker from client-side filtering to debounced server-side search, changing behaviour
> for four shipped screens with no gate coverage). **PR 6 therefore lands at `94 pass / 2 fail`**, the two
> being `A4-debounce` and `A4-neg-banner`; `0 fail` moves to the search-box PR. Anyone applying the executor
> skill's generic "0 fail" gate to PRs 1-6 will either block on a correct build or, worse, "fix" it by
> deleting the parked rows.
>
> **Measured for PR 1 + PR 2 — matched script version, md5 confirmed identical across both runs:**
>
> | | `develop` | worktrees |
> |---|---|---|
> | Result | 23 pass / 70 fail / 0 skip | **31 pass / 62 fail / 0 skip** |
> | rows FAIL → PASS | — | **8** — all eight `A1-*` rows plus `B1-exclude` and `B1-jest` |
> | rows PASS → FAIL | — | **0** |
>
> ⚠ **A CORRECTION WORTH READING, because the mistake is easy to repeat.** The first version of this box
> claimed `30 pass / 63 fail` and **2 regressions** (`A2-nested`, `B2-jest1`). Both figures were wrong,
> and the code-review lane caught it. The regression count came from diffing against the **TDD-gate
> snapshot** — taken when all 37 gate tests were still in the worktrees — rather than against
> `develop`. Those two rows are bare `file_exists` checks; they were red on `develop` all along and
> never moved. **Always baseline a phase against `develop`, never against an intermediate working
> state:** the intermediate state ceases to exist the moment the tests are parked, so any "regression"
> measured from it is an artifact. Verified independently before correcting.

**Two rules that follow, and both have bitten this codebase before:**

1. ⚠ **Do NOT `@Disabled` the not-yet-due tests and re-arm them later.** That is what 2732 did, and
   re-arming was *not* the one-line delete its own notice promised: two of the disabled checks encoded
   the design the gate **anticipated** rather than the one that shipped, and following the notice
   literally *"would have damaged the code"* — it would have added `@Transactional` to a controller that
   must not have it and un-paginated a paginated read. Tests that are not yet due should be **absent from
   the branch**, not present and switched off.
2. ⚠ **Verify ancestry before advancing the stack** — `git merge-base --is-ancestor` per §8.1. Six
   sequential PRs is exactly the shape that produced the PR #51 orphan.

### 8.1 The stacked-PR ancestry gate — spelled out as commands

**Do NOT open A2 or A3 against 2732's branch.** Both target `develop`. This is the exact failure that
orphaned PR #51: a stacked PR whose base was merged out of order, leaving the stacked commits
unreachable. The rule is **merge base-first INTO `develop`, then verify ancestry before advancing.**

```bash
export PATH="$HOME/.sdkman/candidates/java/current/bin:$HOME/.sdkman/candidates/maven/current/bin:$PATH"
cd /home/nampark/dev/wms-claude/v2/wms2-api
git fetch origin --prune

# 1. Confirm 2732's Phase-1 merge is ACTUALLY on develop — not just that its PR says "merged".
#    r6: it IS, as of 2026-08-11 — merge commit 889298d, review commit 0837289. Assert it anyway;
#    the local checkout can be stale (the recorded SBDEV-2781 landmine), and a stale tree makes the
#    verify script report contract drift when the real cause is an unpulled develop (§13).
git log origin/develop --oneline --grep='SBDEV-2732' | head
BASE=$(git log origin/develop --format=%H --grep='SBDEV-2732' -1)
test -n "$BASE" || { echo "SBDEV-2732 Phase 1 is NOT on develop — A2 is blocked"; exit 1; }

# 2. Confirm the constructs A2 depends on exist at that commit. "Merged" is not "present".
git show --stat "$BASE" | grep -E 'PutawayDestinationQueryService|PutawayDestinationResolver|V2\.2\.11'
git grep -l 'class PutawayDestinationQueryService' "$BASE" -- src/main/java || \
  { echo "facade absent at BASE — re-read 2732's PR before writing tests"; exit 1; }

# 3. Branch from origin/develop AT OR AFTER that merge — never from 2732's feature branch.
git switch -c feature/SBDEV-2643-A2-sku-effective-putaway origin/develop
git merge-base --is-ancestor "$BASE" HEAD || { echo "ANCESTRY FAIL — 2732's merge is not in this branch"; exit 1; }

# 4. Re-assert immediately before opening the PR, and again before merging it.
git fetch origin && git merge-base --is-ancestor "$BASE" HEAD && echo "ancestry OK"
```

Repeat verbatim for A3 and, with `wms2-web-ui` and 2732's **Phase 2-UI** merge, for B2.

### 8.2 Blast radius

| Phase | Blast radius of a defect | Gate |
|---|---|---|
| ~~A0 (detector)~~ | **retired r5 — shipped by SBDEV-2863 `675b4a1`.** 2643 adds no test here | — |
| ~~A0 (swap)~~ | **removed from 2643's scope in r2, then made moot in r5:** SBDEV-2863 repaired the constant, so there is no unfixed constant and no nine 500-ing endpoints | verify `X-authz-constant` (regression guard) + manual **M8** (**403**) |
| B1-pre | none — a one-line no-op today | `B1-exclude` |
| A1 | a cosmetic stray row on every SKU details overlay **if `B1-pre` was skipped** — which §5.1 row 4 forbids | **M2** locally (confirm the hazard) then **M1** on DEV (confirm the fix) |
| A2 | one new read endpoint; 500 if the resolver is called directly | `A2-neg-res` + **M9** |
| ~~A3 (fallback only)~~ | **deleted r6** — 2732 shipped D-D | — |
| **A4** (NEW r7) | ⚠ **THE WIDEST IN THIS PLAN, and it is not 2643's own screen.** `eligibleLocations` already serves 2732's **WAREHOUSE** and **MERCHANT** pickers. A `name` predicate that leaks into the unfiltered path silently removes legal destinations from **two shipped screens**, with no error surfaced — an operator would simply not see a location they are entitled to pick. Everything else in this plan fails loudly; this one fails quietly | **`A4-t-empty` (the empty-search identity test) is the gate** — plus `A4-inquery`, `A4-neg-native`, and re-running 2732's own `test/components/admin/parametersAndConfiguration/` suite |
| B1 | `receivingForm.vue` regression (2731's just-merged display) | `receivingForm.spec.js` + **M12** |
| B2 | **one SKU per write.** The narrowest tier in the whole feature family. Its **worst** outcome is a legible refusal, not a bad configuration: an ineligible destination cannot be selected *and* cannot be written | write validation (2732) + the receive-time backstop + **M10** proving both sides of the boundary |

### 8.3 Rollback

Every phase is code-only and independently revertible; **no migration means no forward-only
constraint** anywhere in this plan. A1's revert is safe even after B1 deploys (`exclude-fields` naming
an absent key is a no-op). B2's revert leaves the pencil button `disabled` — degraded, not broken.
Any SKU value written through 2643 is undone by 2732's own Clear, or by one `UPDATE itemdata SET
putawaylocation_id = <lane id> WHERE id = …`.

### 8.4 Closure conditions

1. **`bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh`** → 0 FAIL and
   **0 SKIP**. A green run with SKIPs means phases are still blocked, not that the work is done.
2. **M1–M13 recorded**, including ~~**M2**~~ and **M10**
   (proves D1's boundary from both sides — the picker's omission *and* the API's 422).
   **Status 2026-08-13: 9 of 14 done** — M1, M4, M5, M6, M10(a), M10(d), M11, M13 pass; **M7, M12, M3, M8,
   M9 remain**, and M7 is the only one needing an account we do not have to hand. **M2 is struck, not
   skipped:** it tested the window where B1 ships before A1, and §8's ordering shipped `B1-pre` first by
   design, so the window never existed. Full log in **§7.5a**.
   ⚠ **[SBDEV-2947](https://app.clickup.com/t/868kr048e) is NOT a closure condition.** It came out of this
   run and its finding is real, but it is a product decision on 2732's shared control. 2643 closes on its
   own AC; 2947 closes on someone's call about a default.
3. **`wms2.putaway.resolution{source="SKU_OVERRIDE"} > 0`** on DEV — the adoption gate. ⚠ Do **not**
   accept 2732 §8.1's tier-2/3 condition as 2643's gate (§5.1 row 8).
3a. **A4 regression evidence: 2732's WAREHOUSE and MERCHANT pickers still offer their full candidate sets** after the `name` parameter lands. Concretely — with no search term, the merchant/warehouse picker count must be unchanged from pre-A4 (≈516 at those scopes on wineco-dev). ⚠ **This cannot be inferred from 2643's own tests passing**: A4 is the one change in this plan whose failure mode lands on someone else's screen (§8.2).
4. ✅ **ALL OPEN QUESTIONS CLOSED *that are 2643's to close*** — ⚠ **Q16 was raised 2026-08-13 and is NOT
   one of them**: it is the "Show storage locations" default, spun out to
   [SBDEV-2947](https://app.clickup.com/t/868kr048e) because it lives in 2732's shared control. **2643 may
   close with Q16 open.** Of the rest: Q2, Q6 and Q5→D12 closed r6 (2732 adopted the specs); **Q10 and Q11 closed r7 (2026-08-12) by measurement** — Q10 → (A) DEV-only on `wms2-wineco-dev` with the ticket's real subject (`ICE PACK` 874400 / `ICEPACK` 225817 / FLA 22742154), Q11 → `client 0/System` exists on every reachable tenant. **Review-brief Decision 3 is fully answered** (Q3 → mirror 2732's copy; Q4 → option (ii), which added Phase A4). Decisions 1 and 2 of that brief remain unreturned and **block nothing here**.
5. ~~**§5.1 row 0e resolved by someone**~~ — ✅ **DONE: SBDEV-2863 merged 2026-08-07** (PR #134, `675b4a1`). The constant is repaired, so 2732 **should** carry `Authority.IS_SB_ADMIN`.
   Until then AC12 is unmeetable and closing 2643 on it would be an over-claim.
6. **§10.3's ten corrections sent to 2732's author**, C4 and C10 in particular.

---

## 9. Alternatives Considered

### 9.1 Offer pick faces behind an advisory warning — **REJECTED in r2 (was r1's D1)**

r1's plan of record: offer the 511 `useforpicking` locations alongside the 92 eligible ones, behind a
per-row banner naming SBDEV-2821, on the reasoning that the ticket is a *configuration* deliverable and
the "Receiving Behavior Boundary" defers what receiving does with the value.

**Pros (as r1 argued them):** the feature can express the configuration the ticket was filed to create;
the ICE PACK location is findable; the config/runtime split is a coherent shape in general.

**Cons — and the first one is fatal, not a tradeoff:**

1. **The write does not succeed. It 422s.** A config/runtime split is legitimate only if the *config*
   write is permitted. 2732 makes a SKU-scope pick-face destination an **unconditional** reject:
   `:722` — P2.7(c) is *"absolute at all three scopes — tier 1 included, and this is load-bearing for
   D15"*; `:792-795` — *"Tier 1 (SKU) is exempt from (a), (b) and (d) — **but NOT from (c)**,
   deliberately… (A 2026-08-04 revision briefly added (c) to this exemption list; reverted the same
   day.)"*; and `:2211` ships the enforcing unit test **`skuWriteRejectsPickFaceDestination`**. So r1
   would have shipped **a picker offering ~511 rows whose selection cannot be saved at all** — two dead
   ends instead of one, the second of which looks like a bug in the new feature.
2. **It does what 2732's own open question declines, for the same physical reason.** 2732 **Q9**
   (`:2561`) asks whether P2.4 should admit pick locations and answers *"**No** — the narrow reading
   ships safely and can be widened later… widening P2.4 is a one-clause change **but §7.6 row 8's
   deadlock-retry prerequisite becomes hard**, because picking locks the same rows in the opposite order
   far more often than replenishment does."* And 2732 `:2308`(i) makes the deferred *"stock-move
   deadlock-retry hardening"* ticket **"an absolute prerequisite before Q9 widens P2.4 to admit pick
   locations."* r1 answered a hard infrastructure prerequisite with a UI banner.
3. **2643 cannot divergence-document its way out of a validator it does not own.** 2732's test fails the
   moment 2643's picker is used. The only coherent version of r1's D1 was a *change request against
   2732 P2.7(c)* — which would then inherit 2732's deadlock-ticket price, making the short-term outcome
   identical to r2's anyway.

**Rejected. r2's D1 enforces P2.7(c) and ships the 92** — see §10.1 D1. The ticket's use case is not
abandoned, it is **sequenced**: 2732 `:722` already assigns tier-1 pick-face relaxation to
**SBDEV-2821**, and §3.8.2a makes the restriction legible in the UI so the operator learns *why* the
location is absent. **Also rejected: building a 2643-owned SKU-scope validator** — it would duplicate
six safety-critical predicates, violating §14's principle 2 and D3's entire rationale (§9.3(a)).

### 9.2 Stack on SBDEV-2821 so configuration and receiving land together — **REJECTED**

Wait for SBDEV-2821 to make pick-face receiving actually work, then ship 2643 against a validator that
genuinely permits the ticket's destination — no divergence, no warning, no residual risk.

**Pros:** the cleanest possible semantics — the picker offers exactly what receiving accepts.

**Cons:** SBDEV-2821 is **Open with no plan document**, and it carries the resident-UL/Fix B machinery
that 2732 D15 deliberately deferred plus 2732's own unresolved Q11 and C2b. Stacking on it makes 2643's
critical path **2731 → 2732 Phase 1 → 2732 Phase 2 → 2821 (unplanned) → 2643** — the longest chain
available, gated on a ticket nobody has scoped. Meanwhile the ticket is `urgent` and the requester is
waiting on a **configuration UI**, which is orthogonal to receiving behaviour: the ticket's own
"Receiving Behavior Boundary" section says so explicitly.

**Rejected.** 2643 ships the configuration surface for the 92 locations that *are* configurable today
and *names* the gap in the UI (§3.8.2a). **When 2821 relaxes P2.7(c) for tier 1, the scope banner is
deleted and 511 rows become eligible with no 2643 code change at all** — the predicate authority is
2732's validator, server-side (D3), so the picker's eligible set widens by itself. That is the payoff for
not duplicating the predicate: r2's design absorbs 2821 for free, where r1's would have needed the
advisory class, the `PICK_FACE` reason and the banner all unwound.

### 9.3 Widen `ViewDtoService.getLocationView()` and filter client-side — **REJECTED (D3)**

Add `staginglane`, `transferlane`, `automationlane`, `crossdockinglane`, `gate`, `typeId`,
`useforgoodsin`, `useforstorage`, `useforpicking`, `entityLock` and a `fixAssigned` marker to
`getLocationView()` (`:806-832`), then implement the predicate set in Vue — literally what 2732 §3.11.2
mandates.

**Pros:** no new endpoint; reuses `store/masterData/storageLocation.js:51`'s existing fetch; the
666-row payload is small enough to filter client-side (§2.2).

**Cons:** (a) it re-implements **six safety-critical predicates in JavaScript**, guaranteeing divergence
from `PutawayDestinationValidator` the first time either side changes — and 2732's own §12 changelog
shows P2.5 flipped and reverted the same day and P2.7(c) arriving on 2026-08-06, so "either side
changes" is not hypothetical; (b) it widens a payload **four other screens** consume, for the benefit of
one dialog; (c) `fixAssigned` is not a column at all — it is an `EXISTS` over
`fix_location_assignment`, so the "just add fields" framing is already false; (d) it puts the eligibility
verdict in the client, where a stale bundle silently offers a location the server rejects.

**Rejected per D3.** D-D ships `GET /v3/putawayConfig/eligibleLocations?scope=SKU` with **server-side**
predicate evaluation delegating to 2732's validator — one source of truth, matching the ticket's own
"ONE shared service" spirit. `getLocationView()` is left byte-for-byte unchanged.

### 9.4 Absorb 2643 into SBDEV-2732 as a "Phase 3-UI" — **REJECTED**

Delete this plan; add the SKU dialog, `describeForSku` and the eligible-locations read to 2732 as a
third phase, and ship one coherent feature.

**Pros:** no stacked-PR hazard (R1), no `ItemDataControllerUnitTest` collision (R2), no unwritten-contract
risk (R5) — 2732 would own both sides of every contract, so nothing could drift.

**Cons:** **2732 explicitly carved this out** — its §0.2 row 45 marks the SKU edit surface *"out of THIS
plan — that is SBDEV-2643's SKU edit form"* and its §10.4 Q3 records that 2643 is materially bigger than
"add a field". 2732 is already **2848 lines** and carries a gated migration, an absolute operator gate,
two open blocking questions of its own (2732's Q12 and Q8) and three pre-mortem scenarios; absorbing 2643 would
add a fourth phase and a second repo's UI work. ⚠ **r2 note:** r1 also argued that D1's divergence
"cannot coherently live inside the plan that declares P2.7(c) absolute" — **that argument is void, because
r2's D1 is not a divergence.** The remaining grounds (2732's explicit carve-out at its §0.2 row 45, its
size, its own open questions) still hold on their own. There is also
a scheduling argument in the other direction: **2643's picker is less blocked than 2732's own.** 2732's
2732's Q12 (may a tier-2/3 default target a club lane?) is entirely about P2.7(a); at SKU scope P2.3 rejects all
lane flags unconditionally, so **2732's Q12 answer cannot change 2643's eligible set.** 2643 can proceed while
2732's hardest open question is still open.

**Rejected.** 2643 stays a separate, thin, stacked plan — with §8.1's ancestry gate as the structural
answer to R1 and a new nested test class as the answer to R2.

### 9.5 Also considered, briefly

| Option | Verdict |
|---|---|
| Fix `Authority.IS_SB_ADMIN` globally (repoint at `"isAimAdmin()"`, or alias `isSbAdmin()` on the root) | **Rejected for 2643.** Both silently change the semantics of 9 unrelated endpoints. SBDEV-2863 owns that call. §3.1 |
| Add a "Default Putaway Location" column to the SKU table | **Rejected (Q4).** Needs a second API change (`getItemDataViewPage:915-924`) and hits F3's persistedState staleness. The overlay + dialog satisfy AC1. Add later if operators ask |
| Build a second, SKU-specific picker instead of reusing `LocationPicker.vue` | **Rejected (Q7).** Two pickers means two implementations of a safety-critical filter. Cost accepted: B2 hard-blocks on 2732 Phase 2-UI |
| Put `describeForSku` on `ItemdataService` beside `getItemdataDetails` | **Rejected (F5).** `ItemdataService.java:15` is a bare `@Service` with no `@Transactional` anywhere; the `MANDATORY` resolver would throw `IllegalTransactionStateException` from there exactly as from a controller |
| Add a count-and-confirm preview flow to the SKU dialog | **Rejected (Q8).** Answered by 2732's own signature: `setSku` carries no `confirmIncompatibleSkus`; only `setMerchant`/`setWarehouse` do. One SKU has no blast radius |
| Offer `PutAwayLane` itself in the picker | **Rejected (Q3/F8).** It passes every predicate, so pinning tier 1 to the tier-4 fallback is possible and produces a silently-inert configuration. **Clear is the only route back** |

---

## 10. Open Questions / Resolved Decisions

### 10.1 Recorded decisions — decided, do not re-open

| # | Decision | Rationale |
|---|---|---|
| **D1** ⭐ **REVERSED IN r2, RE-REVERSED IN r3 — this row is r3's** | ⚠ **REWRITTEN 2026-08-09. The r2 text below the strikethrough is SUPERSEDED; do not implement it.** **The picker OFFERS pick faces, including flowbins**, at SKU scope — tier 1 is exempt from 2732's P2.7 rule (e), and a SKU-scope pick-face write is legal under Q12 → (iv-b). The r2 exclusion would hide **511 savable locations on hydra DEV, `ICE PACK` among them** — the very configuration the parent bug is about. **What the picker must still exclude is a flowbin fix-assigned to a *different* SKU** (2732's new **rule (f)**, added 2026-08-09): those rows save cleanly and then fail at *every* putaway, which is worse than r1's "unsavable rows" because the failure is deferred and detached from its cause. On `wms2-wineco-dev` that is **1,344 of the 2,555** rows the picker would otherwise offer (53%); on `wms2-hydra-dev2`, **154 of 603**. `blockingReason` is **2732's enum** — 2643 still may not extend it from its own PR (MUST-4); 2732 owns that change. The **advisory** returns in r1's shape and must say the destination is *routed via putaway*, not placed directly — and state the operational consequence: **the stock is not on the pick face when the receipt closes; it arrives when someone puts it away.** The always-visible scope banner (§3.8.2a) stays, with r3's computed `{eligibleCount}`/`{totalCount}`. ~~**r2: ENFORCE 2732's P2.7(c). The SKU picker offers ONLY the 92 genuinely-eligible locations; pick faces are NOT selectable.** P2.5 (fix-assigned) also stays absolutely blocked. **2643 adds no `advisory` field, does not extend `blockingReason` with `PICK_FACE`, and builds no SKU-scope validator of its own.** What 2643 *does* build is the **always-visible scope banner** (§3.8.2a) naming **SBDEV-2821** and **SBDEV-2732 Q9**, plus a matching picker empty state~~ | **This is correct SEQUENCING, not a divergence, and not a compromise.** ① **A SKU-scope pick-face write is an unconditional 422** — 2732 `:722` (*"absolute at all three scopes — tier 1 included… load-bearing for 2732's D15"*), `:792-795` (*"tier 1 is exempt from (a), (b) and (d) — **but NOT from (c)**, deliberately"*, with the 2026-08-04 exemption *"reverted the same day"*), and 2732 ships **`skuWriteRejectsPickFaceDestination`** (`:2211`) to enforce it. **Offering rows that cannot be saved is strictly worse than not offering them.** ② **2732 already owns the relaxation and has assigned it:** `:722` — *"**SBDEV-2821** relaxes this for tier 1 only, alongside P2.5."* 2643's job is to ship the surface that becomes correct-and-complete the moment 2821 lands — and because D3 keeps predicate evaluation server-side in 2732's validator, **that widening needs zero 2643 code** (§9.2). ③ **2732 Q9 (`:2561`) answers "No" to exactly this widening**, and `:2308`(i) makes the deferred deadlock-retry ticket *"an absolute prerequisite before Q9 widens P2.4 to admit pick locations."* r1 answered a hard infrastructure prerequisite with a UI banner; r2 does not incur the prerequisite at all (§5.1 row 9). ④ **The cost is real and is stated, not hidden:** the ICE PACK location the ticket names is **not** configurable through 2643, and 496/496 flowbins are excluded. **That cost was unavoidable under every coherent option** — including r1's, whose only coherent form was a change request against 2732 that would have inherited the same deadlock gate. ⑤ **The residual risk is now a UI legibility risk, not a data risk:** an operator must not conclude the search is broken. §3.8.2a is the mitigation and it is a verified deliverable (`B2-banner`, `B2-banner2`, `scopeBannerNamesBlockingTicket`). See §9.1 for the rejected option, §11 PM3, §15 |
| **D2** (r2: **narrowed**) | **2643 ships the DETECTOR ONLY** — a test that **EVALUATES the SpEL string** against a real expression root. The correct expression is `Authority.getExpForRole(Authority.SB_ADMIN_ROLE)` → `hasAuthority('sb_admin')`, but **applying it in `PutawayConfigService` / `PutawayConfigController` is 2732's review or [SBDEV-2863](https://app.clickup.com/t/868knmx18)'s, not 2643's** (§3.1 r2 box, §5.1 row 0e). The 9 pre-existing broken endpoints are SBDEV-2863's | `Authority.java:14` `IS_SB_ADMIN = "isSbAdmin()"` names a method that exists nowhere; the only admin predicate is `isAimAdmin()` (`CustomMethodSecurityExpressionRoot.java:77`), so 9 sites 500 for everyone. Safe with no `ROLE_` prefix because `CustomMethodSecurityExpressionHandler.java:19` calls `setDefaultRolePrefix(null)`. **A direct `isAimAdmin()` call cannot catch this class of defect** — `CustomMethodSecurityExpressionRootUnitTest:170-206` is proof: it has been green for the whole life of the bug |
| **D3** | **Server-side predicate evaluation:** `GET /v3/putawayConfig/eligibleLocations?scope=SKU`. Do **not** widen `getLocationView()`; do **not** re-implement predicates in Vue | §9.3 |
| **D4** | **AC7 is asserted as an invariant, not built for.** One DB per facility (2732 §2.4); `/v3/location/detailView` and every repository read are inherently facility-scoped by the tenant datasource | Building anything for AC7 would be dead code |
| **D5** | **No table column** on the SKU grid (**Q4**) | §9.5. Avoids a second API change and F3's stale-rehydrate hazard |
| **D6** | **Strict reuse of `LocationPicker.vue`** (**Q7**) | 2732 `:1607` requires the same tiering and lock warning for the SKU picker. Cost: B2 hard-blocks on 2732 Phase 2-UI. Accepted |
| **D7** | **No count-and-confirm flow** (**Q8**) | 2732's `setSku` signature carries no `confirmIncompatibleSkus` |
| **D8** | **The tier-4 lane is excluded from the picker; "Clear / Use default" is the only route back** (**Q3**) | `PutAwayLane` (50155) passes every SKU-scope predicate, so it is selectable — and pinning it produces identical receiving behaviour to NULL but a *different* configuration (tier 1 pinned vs. fall-through to tiers 2/3/4). The exclusion compares against the machine **name** constant, never the display label |
| **D9** | **AC8's richer signal comes from D-B's envelope, not from the details map** (**Q6**) | Keeps precedence and compatibility logic in exactly one place. The details map gains only the id (§3.3), which is enough to distinguish "invalid" from "inherits" |
| **D10** | **The UI gate is `disabled` + tooltip, never `v-if`** | The ticket says read-only users **may view**. Hiding the field fails AC1 for them; hiding the button hides that the capability exists |
| **D11** | **`ItemDataController.java:93`'s misleading log is raised in 2732's review; 2643 fixes it only if 2732 ships without it** (§0.1 row 11) | One line, and 2732 §3.5 rewrites the whole method. Duplicating the fix invites a conflict. ⚠ *r2 renumbering note:* r1 tagged this decision "(Q9)", which collides with **2732's** Q9 (the P2.4/pick-location question D1 now cites). 2643 has no Q9 of its own; the reference is §0.1 row 11 |
| **D12** (r2, **new**) | **2732 owns D-D (`GET /putawayConfig/eligibleLocations`). §3.5 is a full specification handed over; A3 is 2643's named fallback with a decision deadline before A3's TDD gate** | Resolves **Q5**. 2732 `:1605` mandates a picker filtered over `/location/detailView`, which exposes none of the flags (`ViewDtoService.java:815-822`), so **2732's own Step 19 (`:2036`) is blocked identically** — the endpoint is on 2732's critical path with or without 2643. Building it here would invert the dependency direction of the feature family and leave 2643 owning an endpoint inside 2732's controller. §3.5's ownership box; §5.1 row 0d |
| **D13** (r2, **new**) | **`describeForSku` lives in 2643's own `service/SkuPutawayQueryService.java`, not as a method added to 2732's `PutawayDestinationQueryService`** | The `Propagation.MANDATORY` resolver needs **a** `@Transactional(value="tenantTransactionManager", readOnly=true)` bean between controller and resolver; it does not need that bean to be 2732's file. Converts the plan's hardest ordering constraint from a three-way merge into a compile-time type dependency, and drops R1's cross-plan write surface to zero in the plan of record. §3.2 |
| **D14** (r2, **new**) | **`LocationPicker.vue`'s props/events contract is SPECIFIED in §3.8.2b and handed to 2732**, rather than waited for | Resolves **Q6** to *specified-pending-acceptance*. Waiting forfeits every user-visible AC while the ticket runs `urgent`; specifying costs at worst one dialog's binding rewrite, detected by `B2-picker`. The shape is the repo's own idiom at `createBol.vue:68-76` — the file's only `v-autocomplete` (§10.3 C7) |

### 10.2 Open questions

| # | Question | Blocking? | Recommendation / next action |
|---|---|---|---|
| ~~**Q2**~~ ✅ **CLOSED 2026-08-11 from the merged code — the assumption HELD** | `/preview` **does** accept `scope=SKU`: `PutawayConfigController.java:93-95` takes `@RequestParam PutawayScope scope` + optional `subjectId`, and `:113-116` has an explicit `scope == PutawayScope.SKU` branch reading the subject SKU's `defultypeId` for the P2.6 pre-check. The envelope is the 7-field record at `:47-53` — `{locationId, locationName, compatible, incompatibleSkuCount, totalSkuCount, exampleIncompatibleSku, blockingReason}` — so `compatible` + `blockingReason` are meaningful and the three counts are degenerate exactly as predicted. **B2 may gate Save on `preview`; no extra round-trip needed.** ⚠ **But one NEW gap replaces it:** `BlockingReason` is `{LOCKED, FIX_ASSIGNED, LANE}` and `blockingReasonFor` (`:133-152`) returns **`null` for three of the seven rejection throw keys** while `compatible` is already `false` — so the picker can be told "blocked, reason unknown", and **MUST-4's this-SKU-vs-another-SKU distinction is still unnameable** (1,345 of 2,068 flowbins on wineco-dev are FLA-bound). **2732 owns the fix and has accepted it** as its r-next §3.11.0a (step 18a), adding `BOUND_TO_ANOTHER_SKU`, `AREA_NOT_USABLE`, `FLOWBIN_SCOPE`, `TYPE_INCOMPATIBLE`. **B2's advisory is blocked on 18a, not on a question.** *(Original question retained below.)* <br><br> **What does `GET /putawayConfig/preview?scope=SKU` return?** 2732 §3.5a specifies a 7-field envelope whose `incompatibleSkuCount` / `totalSkuCount` / `exampleIncompatibleSku` are degenerate at SKU scope (the subject *is* one SKU ⇒ 0-or-1 of 1). 2643 wants `compatible` + `blockingReason` as its pre-Save gate. **2732 never states whether `preview` accepts `scope=SKU` at all.** | **YES for the dialog's Save-gating design** — not for the write, which always returns a real 422 | **OPEN.** Assume `{compatible, blockingReason, locationId, locationName}` are meaningful and the three counts are `0/1/null`. Confirm with 2732's author before B2's TDD gate. If `preview` rejects `scope=SKU`, B2 gates on the write's 422 alone — workable, one extra round-trip for the operator |
| ~~**Q6**~~ ✅ **CLOSED 2026-08-11** | **2732 ACCEPTED §3.8.2b VERBATIM** into its r-next §3.11.5 (`value` / `items` / `disabled` / `item-text` / `item-value`; `@input` + `@select`-emits-the-full-row), and added a server-supplied `tier` field (`DEFAULT` / `ADVANCED`) so the two-tier split is no longer a client-side flag test. It also corrected the precedent citation to `createBol.vue:68-76` — C7 discharged. **B2 is blocked on the component EXISTING (2732 step 19), not on its contract.** *(Original question retained below.)* <br><br> **`LocationPicker.vue`'s props/events API is unspecified.** 2732 §3.11.2 specifies the component's *behaviour* (two tiers, the storage toggle, the lock warning, `/location/detailView` as the source) but there is **no prop list, no event list and no `v-model` contract** in 2732 §3.11.2, §3.11.3 or Step 19 (`:2035`). ⚠ 2732 also grounds it in `createBol.vue:109-121, :125` — a citation r2 **verified as WRONG** (§10.3 C7) | **YES for B2** | **SPECIFIED — awaiting acceptance (D14).** r2 promotes r1's interim guess to a **written spec at §3.8.2b**, grounded in the *real* precedent at `createBol.vue:68-76`, and makes 2732's acceptance a §5.1 row 0b item. **Do not start B2 until 2732 accepts it or returns a counter-spec** — a picker whose contract changes mid-implementation is R5 (§11.0) in its most expensive form. Note `@select` must emit the **full row**, so the caller reads `blockingReason` without re-deriving it (§14 principle 2) |
| ~~**Q10**~~ ✅ **CLOSED 2026-08-12 — (A) DEV-only on `wms2-wineco-dev`, and NO stand-in is needed** | **The ticket's actual named subject exists on the designated tenant.** `ICE PACK` `itemdata.id = 874400` (`client_id = 0`, `cl_nr='System'`, Case, `putawaylocation_id` NULL) **and** `ICEPACK` `location.id = 225817` (flowbin, *Storage and Picking*, unlocked) **and** an active FLA `22742154` binding the two, bounds 36/60/84 — all verified SELECT-only 2026-08-12. wineco-dev is also the **only** DEV tenant at `V2.2.13`, so AC4 + AC9 are reachable. **The full subject table is in §7.5.** ⚠ **Two plan claims were falsified in the process:** "all 2,720 SKUs point at `PutAwayLane`" is a **hydra** fact — on wineco-dev **zero** do and **8,803 are NULL** (V2.2.13 stop-seeding), so M3 has 8,803 subjects; and the reported configuration is **not** PRD-only in substance, only in its exact ids. **UAT was REJECTED with cause:** `nywh-hydra-uat` has an `ICE PACK` System SKU (3279555) but **no `ICE PACK` location** and sits at Flyway `V2.2.10` — `putawaylocation_id` still `NOT NULL`, no `putaway_config_audit`, no `client.defaultputawaylocation_id`. Same for `wsl-wineco-uat`. **Applying `V2.2.13` to UAT is a hard prerequisite of any UAT coverage.** | No — closed | **DONE. Use §7.5's ids verbatim; do not re-derive them.** |
| ~~**Q11**~~ ✅ **CLOSED 2026-08-12 — YES, and on every tenant** | `SELECT id, cl_nr, name FROM client WHERE cl_nr='System' OR id=0` returns **`0 | System | System-Client`** on `wms2-wineco-dev`, `wms2-hydra-dev2`, `wsl-wineco-uat` and `nywh-hydra-uat` (PRD copy unreachable; SBDEV-2731 independently recorded `client_id = 0` `System-Client` there). So `ClientService.getSystemClient()`'s `cl_nr='System'` lookup resolves, the null-return case 2732 §7.6 warns about does not arise on any reachable tenant, and **AC10's subject class exists.** The subject SKU itself — `ICE PACK` 874400 — **is** a `client_id = 0` row, so AC10 and AC11 are both covered from §7.5's table. | No — closed | **DONE. No query to re-run before writing AC10's test.** |
| **Q16** ⚠ **RAISED 2026-08-13 BY THE MANUAL RUN, AND IMMEDIATELY HANDED OFF** | **Should "Show storage locations" default ON?** The picker offers only the goods-in tier until it is enabled, and on `wms2-wineco-dev` **zero** goods-in locations are usable by any SKU — all 8,804 are Case, the one goods-in area's 12 locations permit Pallet or nothing, and `HubAndSpoke-01`…`-10` carry **no `location_constraint` rows at all**. 2,068 locations a Case SKU can use, **all** `ADVANCED`. So this ticket's headline workflow — point a consumable SKU at its dedicated bin — is reachable only after a deliberate extra step, and both real overrides on the tenant (`ICEPACK`, `Club08`) are storage locations. In testing, three SKUs showed an empty dropdown before we understood why, and the first read was "the screen is broken" | **NO — and deliberately so.** 2643's code is merged and correct once the toggle is on | **SPUN OUT to [SBDEV-2947](https://app.clickup.com/t/868kr048e) (868kr048e), filed 2026-08-13 with the full measured basis.** It is 2732's shared `defaultPutawayLocationField` / `LocationPicker`, so any change moves tiers 2 and 3 as well — holding a finished ticket on that would be the wrong trade. Recommendation there: **default ON at SKU scope only** (tier 1 *is* the dedicated-bin tier; the lock warning still renders). Option 3, discoverability, is **already merged** as wms2-web-ui #56's tier-split caption and stands as the safety net regardless. ⚠ Do not "fix" this by flagging `useforgoodsin` on a tenant area — that changes receiving far beyond this screen |
| ~~**Q5**~~ | ~~**Who ships D-D (the eligible-locations read)?**~~ | — | **RESOLVED in r2 by D12: 2732 owns it.** §3.5 is a full specification handed over; A3 is 2643's named fallback with a decision deadline before A3's TDD gate (§5.1 row 0d). Grounds: 2732's own Step 19 (`:2036`) is blocked by the identical gap, so the endpoint is on 2732's critical path regardless; building it in 2643 inverts the feature family's dependency direction; and if 2732 later reshapes `blockingReason`/`PutawayScope`, 2643 would own a broken endpoint in someone else's controller. **Still requires a written answer — an unsettled hand-over is the same schedule risk it always was** |

### 10.3 Corrections to SBDEV-2732's own citations — **flagged for 2732's author**

> [!done] **r6 STATUS SWEEP 2026-08-11 — three of these are now FIXED IN 2732, and one still is not.**
> 2732's r-next rewrite of its §3.11 (2026-08-11) **discharged C7** (precedent corrected to
> `createBol.vue:68-76`, and the non-existent "Lookup" button removed), **discharged C10(a)** (the
> front-matter's rolled-back tier-1 P2.7(c) exemption is moot — the merged validator has no P2.7(c) at
> all), and **discharged C10(b)** — the `:1605` "exactly P2.4" client-side filter was deleted as
> **unimplementable**, which is the strongest possible confirmation of that finding: `getLocationView()`
> (`ViewDtoService.java:806-832`) exposes none of the predicate columns, so four of five predicates were
> never evaluable in Vue. It also fixed C2/C3 (the `skuData.vue` actions-column coordinates, in its §0
> row 38 and §4) and a "Step 26" cited twice that never existed.
> **✅ C4 DISCHARGED 2026-08-11 — sent AND fixed.** Raised on the SBDEV-2732 ticket (comment
> `90110259704031`, assigned to David Oppenheim) and corrected in the plan. Every coordinate was
> re-verified against `origin/develop` **before** sending, rather than trusted from this table: the real
> path is `components/masterData/material/skuData/skuData.vue`, the commented create/edit block is
> **`:100-123`**, the live actions column is `:95-99`, `exclude-fields` is `:130`, and `:142` was right.
> ⚠ **The wrong range appeared FOUR times, not the three C4 documented** — §0.2 row 45, §6, §8.1's
> "unblock 2643" note, and §10.4 Q3 — all four now corrected.
>
> **✅ C1, C5, C6, C8, C9 ALSO SENT AND FIXED 2026-08-11** (comment `90110259706169`). ⚠ **Three had been
> overtaken by events and the corrections in this table were themselves stale**, so all were re-derived
> against `origin/develop` first: **C1** the path half stands but the `/v3/**` rule moved to **`:143`** and
> Phase 1-API widened its matcher to `"/v3/**", "/putawayConfig/**"` — this plan cited `:136` in **six**
> places, all corrected; **C5** active sites are now `:80, 108, 121, 134, 143, 155, 176, 200` with
> `:190, 261, 285, 315` commented, and **its "all 8 are broken" premise died with SBDEV-2863** on
> 2026-08-07; **C6** appeared **3 times in 2732, not 1**, and the same wrong class name was in
> `sbdocs/9-System/templates/wms-plan-template.md:123` — fixed, the highest-leverage of the five since the
> template seeds every future plan; **C8** is `:104-118` and the stockunit sibling moved to `:183-190`
> (SBDEV-2821 inserted `getPutAwayCandidateLocations` between them), while C8's verdict is now stated by
> the code's own javadoc — *HAL-exported consumers only, no longer drives putaway*; **C9** method `:73-82`,
> `@Caching` block `:66-72` above it.
>
> **⚠ PATTERN — every finding in this table under-counted its own occurrences** (C4: 4 not 3; C6: 3 not 1).
> When acting on any remaining row, grep the whole target file rather than fixing the row that reported it.
> That is exactly how `:107-131` survived in three other sections after C4 was first written.
>
> **§10.3 is now fully discharged.**

**Ten findings** from verifying 2732's contracts against disk at `6bc709a` / `4ce39a1`. **C1–C9 are
*citation* defects** — an implementer following them lands in the wrong file or the wrong hunk. **C10
(added in r2) is not a citation defect: it is 2732 contradicting itself, twice, on the exact rules 2643
depends on.** **Fix them in 2732 rather than propagating them.**

| # | 2732 (or the brief) says | Actual | Severity |
|---|---|---|---|
| **C1** | `SecurityConfiguration.java` is under `config/` | It is `src/main/java/net/aim_ai/wms/SecurityConfiguration.java`. **`config/SecurityConfiguration.java` does not exist.** Line `:136` is correct | low — path only |
| **C2** | `skuData.vue:100-123` is *the* actions block, implying no actions column exists | There are **TWO** `item.actions` templates: an **ACTIVE** one at `:95-99` rendering a live eye button (`:97` `@click="showDetails(item)"`), and the commented pencil/trash/menu block at `:100-123`. **An actions column already exists and already ships one button** | **medium** — changes the UI work from "create a column" to "add a second button" |
| **C3** | `skuData.vue:142` is the load-bearing line for the details overlay | `:142` is correct for the label map, but the load-bearing line is **`:130`** `:exclude-fields="['id','itemNr','version']"` — that is what makes A1's added key render as a stray row | **medium** |
| **C4** | **2732 §0.2 row 45** cites `components/masterData/skuData.vue:107-131, 142` | **Wrong in BOTH path and range.** The real path has two extra segments: `components/masterData/material/skuData/skuData.vue`. The commented block is **`:100-123`**, not `:107-131`. Only `:142` is right. ⚠ **2732 §10.4 Q3 and §8.1's "unblock 2643" note repeat the wrong `:107-131` range** | **HIGH** — this is the row that scopes 2643, and both of its coordinates are wrong |
| **C5** | **2732 §3.12** cites *"the pattern used throughout `AdminController.java:93, 121, 134, 147, 156`"* | Actual active `@PreAuthorize` lines: **`80, 108, 121, 134, 143, 155, 176, 194`**. Only `121` and `134` match. (`:184, 248, 269, 297` are **commented out**.) And every one of those 8 sites is **broken** (F1/D2) | **medium** — the cited "pattern" is a pattern of 500s |
| **C6** | **2732 §7.7 row 7** names **`BaseControllerTest`** | The class is **`BaseControllerUnitTest`** (`src/test/java/net/aim_ai/wms/common/base/BaseControllerUnitTest.java:34`). There is a separate `BaseControllerIntegrationTest`. **`BaseControllerTest` does not exist.** The template `wms-plan-template.md` §6 carries the same wrong name | **medium** — an implementer extends a class that is not there |
| **C7** (r2: **upgraded to CONFIRMED WRONG**, with the real coordinates) | **2732 §3.11.2 `:1594`** grounds `LocationPicker.vue` in `createBol.vue:109-121` (inline `v-autocomplete`) + `:125` (a *"Lookup"* button opening a search dialog) | **CONFIRMED WRONG on all three counts.** Path: `components/outbound/bol/create/createBol.vue` — 2732's is short one segment. **`:100-130` is a run of plain `<v-text-field>`s** (Carrier, Truck Number, Seal Number / Tag, Tracker ID) — no autocomplete at the cited range. The file's **only** `v-autocomplete` is at **`:68-76`** — an *Order Batch* picker: `v-model="orderBatchId"` `:69`, `:items="orderBatches"` `:70`, `item-text="label"` `:74`, `item-value="value"` `:75`. And **`grep -n 'Lookup\|lookup'` over the whole file returns NOTHING** — there is no Lookup button anywhere in it. ✅ **But the *shape* 2732 wanted does exist, at `:68-76`, and it is the repo's idiom** — which is what makes §3.8.2b's spec cheap. The other confirmed (naive) precedent is `moveFixedLocation.vue:13` | **medium** — the named precedent for a component 2643 consumes is off by ~40 lines, names the wrong control type at the cited range, and invents a control that does not exist |
| **C8** | `LocationRepository.getStorageLocationsForPutAwayItemData` spans `:104-120` | **`:104-111`.** `:112-119` is the sibling `getStorageLocationsForStockUnitItemData`. And the method is worse than described: its predicate is `a.useforstorage = 'true'` **and it is stockunit-driven**, returning only locations where the SKU already has stock — unusable as a picker on two independent grounds | low — 2732's verdict (do not use it) is right for a stronger reason than stated |
| **C9** | `ItemdataService.setPutAwayLocation` spans `:68-76` | The method does span `:68-76`, but its `@Caching`/`@CacheEvict` block sits **above** it at `:62-67`. Anyone editing "`:68-76`" will move the method away from its annotations | low |
| **C10** (r2, **new — the only DESIGN-level finding in this table**) | **(a)** 2732's own front matter `:114-119` states the 2026-08-06 revision leaves *"P2.5 scope-dependent; **tier 1 exempt from P2.7(c)**"*. **(b)** 2732 §3.11.2 `:1605` mandates *"The picker's filter must be **exactly P2.4** (`useforgoodsin OR useforstorage`)… Offering anything P2.4 rejects produces a 422 the operator cannot act on."* | **2732 contradicts itself on both.** **(a) The tier-1 P2.7(c) exemption does NOT exist in the body.** `:711` says P2.7(c) is *"**Absolute at all three scopes** — tier 1 included"*; `:792-795` says *"Tier 1 (SKU) is exempt from (a), (b) and (d) — **but NOT from (c)**, deliberately"* and records that *"(a) 2026-08-04 revision briefly added (c) to this exemption list; **reverted the same day**"*; and `:2211` ships `skuWriteRejectsPickFaceDestination` to enforce the reject. **The front matter documents a state that was rolled back — on the exact rule 2643's D1 turns on.** ⚠ **2643's r1 was drafted against the front-matter reading and had to be reversed** (§15). **(b) `:1605`'s mandated filter offers what `:722`'s validator rejects.** P2.4 admits a `useforpicking` area that *also* carries `useforgoodsin` or `useforstorage` — **511 of 666 locations on hydra DEV** (§2.2) — and P2.7(c) then rejects every one of them. So **2732's own picker, at merchant and warehouse scope, offers 511 rows whose selection 422s** — the identical defect r1's D1 was reversed for, at larger scale, and with no equivalent of 2643's scope banner. ✅ **2732's own Q12 (`:2558`) independently reaches the same conclusion from the other direction:** verified SELECT-only on `wsl-wineco-uat`, `Club01`–`Club08` (ids 225748+) have **all five lane flags FALSE** and sit in area 51553 with **`useforpicking = TRUE`** — they are *"live multi-SKU pick faces, not staging lanes"* (`Club01`: 114 ULs / 27 SKUs / 973 bottles). **So 2732's own named tier-2 use case — "Club assembly lane" — is also blocked by P2.7(c)**, and Q12 states the three coherent answers, of which (i) is *"P2.7(c) stands… belongs with SBDEV-2821's pick-face work"* — **which is exactly r2's D1, arrived at independently.** That corroboration is the strongest available evidence that r2's D1 is right and that `:1605` and `:114-119` are the things that need fixing | **HIGH** — (a) is why r1 was wrong; (b) means 2732's Phase-2 picker is **unimplementable as specified**. §2.2's measurement is the first evidence of it |

**Two more, not citation errors but worth 2732's attention:**

- **`IdempotencyFilter.java:262`'s Javadoc names `ItemdataService.setPutAwayLocation`** — it goes stale
  the moment 2732 §3.5 rewrites that method.
- **2732 §8.1 (`:2293`) makes non-zero tier-2/3 metric usage a condition for closing 2643.** That is the
  wrong signal for a SKU-tier ticket: `MERCHANT_OVERRIDE`/`WAREHOUSE_DEFAULT` can stay at zero forever
  while 2643 works perfectly. **2643's own gate is `resolution{source="SKU_OVERRIDE"} > 0`** (§5.1
  row 8, §8.4).

### 10.4 Closed questions — do not re-investigate

> **r2 numbers these rows (Critic F-2).** `Q3`, `Q4`, `Q7` and `Q8` were cited ~20 times across §0, §3,
> §4, §7, §10.1 and §13 and **defined nowhere** — the same defect class as the missing `R<n>` register
> (§11.0), in the adjacent namespace. A pointer such as *"Q4 answered NO COLUMN (§10)"* sent the reader
> to a section that did not contain a Q4. Every `Q<n>` citation in this document now resolves to a
> numbered row below, or to §10.2 for the still-open ones (Q2, Q6, Q10, Q11).
>
> **Numbering note:** there is deliberately **no Q1** — r1's Q1 (pick faces) was promoted to decision
> **D1** and lives in §10.1. **Q5** is struck (superseded by D3). Where this document discusses a
> question belonging to *SBDEV-2732* rather than to 2643 — 2732's own Q3, Q8, Q9 and Q12 — it is written
> **"2732's Qn"** explicitly; a bare `Qn` always means 2643's.

| # | Question | Answer |
|---|---|---|
| **Q3** | **Should the tier-4 `PutAwayLane` itself be offered in the SKU picker?** | **No — excluded (D8).** It passes every SKU-scope predicate (measured: id 50155, `entity_lock=0`, area `Inbound`, `useforgoodsin=TRUE`, all lane flags FALSE, 0 FLA rows), so it *would* be selectable. But pinning tier 1 to the lane and clearing the override produce **identical receiving behaviour and different configurations** — the pinned SKU stops inheriting a future merchant or warehouse default. "Clear / Use default" is the only supported way back. Excluded by the `STORAGE_LOCATION_PUTAWAY_LANE` **name** constant (§0.3 row 32), never by a hard-coded id |
| **Q4** | **Does the SKU table get a "Default Putaway Location" column?** | **No — overlay and dialog only (D5).** `getItemDataViewPage` (`ViewDtoService.java:895-931`, projection `:915-924`) does not project it, so a column means a second API change; and `masterData.skuData` is persisted to `localStorage['vuex-web']` (`plugins/persistedState.client.js:26-29`), so a stale rehydrated row could render a pre-write value (F3). The overlay always refetches (`skuData.vue:304`), so it is safe. Revisit only if operators ask |
| **Q7** | **Does 2643 build its own picker or reuse 2732's `LocationPicker.vue`?** | **Strictly reuse (D6).** 2732 `:1607` states the same tiering and lock warning apply to the SKU picker. A second picker means a second implementation of a safety-critical filter set that 2732 revised twice in three days. Cost, accepted: **B2 hard-blocks on 2732 Phase 2-UI**, not just Phase 1-API. Mitigated by §3.8.2b, which specifies the props/events contract 2732 never defined and hands it over |
| **Q8** | **Does the SKU screen need 2732's count-and-confirm preview flow?** | **No — answered by 2732's own signature.** `PUT /putawayConfig/sku/{itemdataId}` takes only `locationId`; `confirmIncompatibleSkus` exists **only** on `setMerchant` and `setWarehouse` (2732 §3.5a). Count-and-confirm is a bulk-blast-radius device and one SKU has no blast radius. 2643 needs only the **blocking** signal (`compatible` / `blockingReason`), not the confirmation dance (D7). ⚠ Not to be confused with **2732's** Q8, referenced in §10.5 |
| **Q13** | Does 2732's Q12 (club/staging lanes via P2.7(a)) block 2643's picker? | **No.** Q12 is a tiers-2/3 question and at SKU scope **P2.3 rejects all lane flags unconditionally**, so its answer cannot change 2643's eligible set. ✅ **r2 addition — Q12 does something more useful than block: it corroborates D1.** Q12 was *re-framed by measurement* on 2026-08-06 (`:2558`): wineco's `Club01`–`Club08` have **`staginglane = FALSE`**, all lane flags FALSE, and **`useforpicking = TRUE`** — they never passed through rule (a) at all and are **blocked by P2.7(c)** instead. So 2732's *own* named tier-2 use case is blocked by the same rule that blocks 2643's, and Q12's answer (i) — *"P2.7(c) stands… belongs with SBDEV-2821's pick-face work"* — **is r2's D1, reached independently for the club case.** §10.3 C10 |
| **Q14** | Does a preloaded, client-side-filtered picker scale? | **Yes** at 666 locations (measured). 2732's Q2 is NO-PROBLEM for this tenant. AC3's "searchable" needs a search *box*, not a server-search endpoint — D3 puts predicates server-side for correctness, not scale |
| **Q15** | Is there v1 prior art to port? | **No.** SBDEV-2642 shipped zero commits (2732 §10.5). Nothing to port, and the Jakarta-vs-javax question is moot |
| **Q16** | Does `getItemdataDetails` need a `@Transactional`? | **No**, and adding one would be a scope creep. It has none today (`ItemdataService.java:15` is a bare `@Service`), works because every FK on `Itemdata` is a manual `Long` with no lazy association, and A1 adds **zero** queries |
| **Q17** | Where did the invalid ICE PACK configuration come from? | `ItemDataController.java:88-90` — raw `save()` with zero validation (2732 §10.5). Fixed by 2732 §3.5, not by 2643 |
| **Q18** | Does 2643 need `V2.2.13`? | **For AC4 and AC9, yes — transitively.** For its own code, **no**: 2643 ships zero migrations and A1's added key is read-only |

---

## 11. Risk register and pre-mortem

### 11.0 Risk register — R1…R10

> **r2 adds this section.** r1 cited `R1`, `R2`, `R4` and `R5` seven times as *"(§11)"* and **defined
> them nowhere** — a reader following *"see R2 (§11)"* landed on the pre-mortem. Every `R<n>` citation in
> this document now resolves here.

| # | Risk | Sev / likelihood | Mitigation, and where it lives | r2 change |
|---|---|---|---|---|
| **R1** | **Stacked-PR merge-order orphan.** A 2643 PR opened against 2732's *branch*, or branched from `origin/develop` before 2732's Phase-1 merge landed, then orphaned when 2732 is squashed / rebased / force-pushed on review feedback. **This is the recorded failure that orphaned PR #51** | **HIGH** severity, MEDIUM likelihood | §8.1's four-step ancestry gate as literal commands, run **before opening the PR and again before merging** — not once at branch time. `git merge-base --is-ancestor "$BASE" HEAD`. Plus §8.1 step 2, which asserts the *constructs* exist at the base commit, because a merged-then-reworked PR is the same failure with a green checkmark. §11 **PM1** | **↓ REDUCED.** r1 had 2643 writing into four 2732 files (a method into the facade, a security-annotation swap in two more, `blockingReason`/`advisory` in a fourth). **r2's plan of record writes into zero** — D13 moves `describeForSku` into 2643's own `SkuPutawayQueryService`, §5.1 row 0e removes the swap, D12 hands D-D over, and D1's reversal deletes the enum/field mutations. What remains is a **type-level** dependency: a compile error, not a three-way merge |
| **R2** | **`ItemDataControllerUnitTest.java` merge conflict.** 2732 Step 9 rewires `ItemDataController:80-95` and must edit the `@Nested SetPutAwayLocation` class at `:119-158`; 2643 A1/A2 edit the same file | HIGH likelihood, **LOW** severity (a conflict, not a defect) | 2643 appends a **NEW** `@Nested EffectivePutawayDestination` class at EOF (`:374`) and **never touches `:119-158`** (§0.2 row 44, §4). It touches `:91-102` only for the constructor arity. Verify row `A2-nested` | unchanged — this one is irreducible, both plans genuinely need that file |
| **R3** | **`ItemdataService.java` conflict.** 2732 rewrites `setPutAwayLocation` (`:62-76`); 2643 edits `getItemdataDetails` (`:166-171`) | MEDIUM likelihood, LOW severity | Different hunks ~45 lines apart; should auto-merge. **Watch the import block** — that is where these conflict in practice | unchanged |
| **R4** | **API/UI deploy-window skew.** A1 merges, DEV auto-deploys on push, and until the `exclude-fields` line is live every SKU details overlay renders a stray raw-integer `PutawayLocationId` row (§6.1) | MEDIUM, **user-visible** | **`B1-pre` is a HARD PREREQUISITE of A1** — one line, a provable no-op today, deployed first (§5.1 row 4, §8 step 2). Verify row `B1-exclude`; manual **M2** observes the hazard locally, **M1** confirms the fix on DEV | **↓ REDUCED.** r1 framed the ordering as a "safe trick" / "prefer that ordering"; r2 makes it a gate, so the window closes by construction rather than by discipline |
| **R5** | **Building on a contract that changes.** Every contract in §3.2 / §3.4 / §3.5 is on unwritten code, and 2732 has a visible revision history: its §12 changelog shows P2.5 flipped and reverted the same day, P2.7(c) became implementable only on 2026-08-06, and 2732's own **D18** (`:103-106`) records **no independent review pass** plus a prior **CRITICAL** finding | **MEDIUM–HIGH**, and it already fired once | ⛔ **§3's blocking banner** + `CONTRACT-PROVISIONAL` headings on all three subsections + §5.9's first checklist item: **re-derive every §3 contract from 2732's *merged* PR before writing a single test.** Temporal mitigation only — §8.1's ancestry gate | **⚠ CONFIRMED, not theoretical.** r1's D1 was built on 2732's front-matter claim (`:114-119`) that tier 1 is exempt from P2.7(c); the body says the opposite and records the exemption reverted the same day (§10.3 **C10a**). **r2 exists because R5 fired.** That is why the hedge was promoted from a bullet to a banner |
| ~~**R6**~~ | ~~**F1 makes AC12 unprovable.**~~ **✅ CLOSED 2026-08-09 (r5).** SBDEV-2863 `675b4a1` repaired the constant *and* shipped the SpEL-evaluation test, so the `@PreAuthorize` sites 2643 and 2732 rely on now return **403/200 correctly**. **The residual risk is narrower and different:** `standaloneSetup` (`BaseControllerUnitTest:52-58`) still evaluates no `@PreAuthorize` and the `@SpringBootTest` lane is still down (SBDEV-2217) — that is **F2**, which 2863 did not touch | ~~MEDIUM~~ **LOW** | 2863's `@Nested AuthorityExpressionsResolve` + manual **M8** (**403**, not 500, not 200) + verify row **`X-authz-constant`** (regression guard, runs today, negative-tested against `6bc709a`) | **↕ RESOLVED BY REPAIR, not by re-homing.** r1 mitigated it by editing 2732's files; r2 re-homed it to 2732's review / SBDEV-2863; **2863 simply fixed it.** ⚠ Row 0e and `X-2732-authz` are **deleted, not just satisfied** — the probe would have failed a *correct* 2732. **AC12's backend half is no longer blocked; only F2's automation gap remains** |
| **R7** | **The picker cannot be built as 2732 specifies.** `/location/detailView` exposes none of the eligibility flags (`ViewDtoService.java:815-822`), so 2732 `:1605`'s mandated client-side P2.4 filter has nothing to filter on — and **2732's own Step 19 (`:2036`) is blocked identically** | MEDIUM, **schedule risk for BOTH tickets** | D3 (server-side evaluation) + D-D (§3.5), **owned by 2732 per D12** with A3 as 2643's fallback and a decision deadline (§5.1 row 0d) | **↑ SHARPENED.** r1 left ownership as an open question while keeping A3 and 8 producer verify rows. r2 resolves ownership (D12) and re-scopes the verify rows so 2643 asserts only what it writes (§13) |
| **R8** | **v2 IT harness down** (SBDEV-2217) — no Testcontainers lane, so no test can prove Spring wiring, propagation or `@PreAuthorize` | LOW (known, stable) | Gate on `mvn test` + `mvn clean compile`; any new IT `@Disabled` with `TODO(SBDEV-2217)`; SDKMAN PATH export; **baseline the 2 known `develop` failures** (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) before the first change. §7.1, §7.9 | unchanged |
| **R9** | **`mvn test` mutates tracked files** — `src/test/resources/archunit_store/{stored.rules, 5fb3fee0-…}` (F4). A new unguarded `Optional.get()` either fails the build or **silently freezes** into the store | LOW severity, HIGH likelihood | `git checkout src/test/resources/archunit_store/` before **every** commit (§5.9). Verify row `X-archunit` fails a dirty store | unchanged |
| **R10** | **Verify-script false green.** The `verify-plan-template` `perl -0777 -ne` and `grep` helpers **exit 0 when they cannot open the file**, so every multi-line assertion about a **new** file passes vacuously — and 2643 creates several. Recorded landmine; SBDEV-2736 scored 57 pass / 0 fail on the build carrying the defect its ticket was written to catch | MEDIUM | **Every** helper opens with `[ -f "$2" ] || return 1`, negative helpers included (script `:139-169`), with the reasoning in the script header. Plus the script's SELF-TEST block and the negative-testing discipline in §7.5 | **↓ FURTHER REDUCED in r2.** The 2732 gate now greps **class declarations** instead of `[ -f ]` and **escalates SKIP → FAIL** once a SBDEV-2732 merge is on `origin/develop` — closing the "renamed-on-merge facade SKIPs every 2732-blocked check forever" fail-quiet. Three checks weaker than their names (`A2-env`, `B2-jest4`, `B1-jest2`) were strengthened |
| **R11** (NEW r7) | **A4's `name` predicate degrades SOMEONE ELSE'S screen, silently.** `eligibleLocations` is shared by 2732's WAREHOUSE and MERCHANT pickers. If the filter is not strictly a no-op when `name` is null or blank, those two pickers lose legal destinations — and the failure surfaces as *absence*, with no toast, no 4xx, no log line. An operator concludes the location was never configured, or that the search is broken. **This is the only risk in the plan whose blast radius lands outside 2643's own screen** (§8.2). | **MEDIUM likelihood, HIGH cost, LOW detectability** — and low detectability is what makes it worth a row. 2643's own tests can be fully green while both other tiers are broken | (a) `A4-t-empty` asserts the empty-search identity **first**, before any positive filter test; (b) the filter is applied **inside** the candidate query, so there is one code path rather than a pre/post split; (c) §5.7 and §8.4 row 3a require re-running 2732's `test/components/admin/parametersAndConfiguration/` suite and confirming the unfiltered merchant/warehouse count is unchanged (≈516 on wineco-dev); (d) A4 merges as its own PR, so a revert is one commit <br><br> ⚠ **STATUS 2026-08-12 — MITIGATED IN CODE, NOT YET CLOSED.** Mitigation (b) was **superseded by something stronger**: rather than one shared code path, A4 leaves the unfiltered query *untouched* and adds a sibling (§3.5a's implementation box), so the blank-term SQL is identical **by construction** and `blankNameIsIdenticalToNoNameFilter` asserts the filtered query is never even reached. The R11 mutant was run: it breaks **7 of 8 of 2732's own merged tests**, so the blast radius is now loudly detected rather than silent — which was the whole problem. **Still open:** the residual is that no unit test can show what Postgres returns on a real tenant. **Manual row M14 is the closure evidence and it has not been run.** Do not treat A4 as done, or archive 2643, on the green suite alone. ⚠ Note mitigation (c) names a **`wms2-web-ui` Jest suite** — A4's PR touches no UI file, so that half is **B2's obligation**, not a step A4 skipped |

**The irreducible residue, stated rather than resolved:** 2643 is a consumer of an **unapproved**
interface. r2 removes every *textual* coupling from the plan of record, but `Resolution`, `Source` and
`PutawayScope` are 2732 types wherever the methods live. **The only real mitigation for that is temporal
— wait for 2732's merge commit (§8.1) — not architectural.** The two alternatives are "duplicate the
predicates" (rejected, §9.3) and "merge 2643 into 2732" (rejected, §9.4), and both are worse.

### 11.1 Pre-mortem — three ways this ships and still fails

### PM1 — It ships as an orphan, and the API half silently disappears

A2's PR was opened against **2732's feature branch** rather than `develop`, or was branched from
`origin/develop` *before* 2732's Phase-1 merge landed. 2732's branch is then squashed, rebased or
force-pushed on review feedback. A2's commits become unreachable; GitHub still shows the PR as open and
mergeable; a later merge succeeds and drops `SkuPutawayQueryService` and the new endpoint on the floor.
B2 deploys against an endpoint that returns 404, and the dialog shows an empty effective value with no
error — because `getSkuEffectivePutaway` has no `catch` and Nuxt swallows it.

⚠ **r2 variant, and it is the one the verify script now catches:** 2732 merges but with the facade
**renamed or relocated**. r1's `phase_2732_present()` was three `[ -f ]` tests, so it would have stayed
false and reported **"blocked on SBDEV-2732"** for every 2732-blocked check — the *wrong story*, since the real state is
"the contract drifted". r2 greps the class declarations and escalates **SKIP → FAIL** once a SBDEV-2732
**merge commit** is on `origin/develop` (SHOULD-8).

> **The probe is deliberately narrow, and deliberately unwindowed.** A first cut used
> `git log origin/develop --grep=SBDEV-2732`, which matched **four** commits on 2026-08-07 — `89de3f0`,
> `b623561` (SBDEV-2731) and `a991c9e`, `a2bd0e9` (SBDEV-2854) — none of them a 2732 merge, all merely
> *citing* 2732 as a dependency. That escalated every correctly-blocked SKIP into a FAIL, i.e. the drift
> detector became the false signal it exists to prevent. It now matches **merge commits carrying a 2732
> branch name** (`Merge pull request #N from Org/feature/SBDEV-2732-…`, the verified shape on this repo),
> and scans **all** merges: a `-50` window would make the probe expire silently ~29 days after 2732's
> merge on this repo's cadence (192 merges on `develop`), which merely defers the fail-quiet rather than
> closing it. Negative-tested three ways: silent today, fires on a simulated real 2732 merge, ignores the
> four false positives above.

This is not hypothetical: it is the recorded failure that orphaned **PR #51**.

*Detector:* `git merge-base --is-ancestor "$BASE" HEAD` (§8.1) run **immediately before opening the PR
and again before merging it** — not once at branch time. Plus a post-merge
`git grep -l 'describeForSku' origin/develop -- src/main/java` returning a hit. Plus manual **M9**
(a 404 or 500 rather than a 7-field 200).

*Mitigation:* §8.1's four-step command block, verbatim, per stacked phase. **Never `--base` a 2643 PR on
a 2732 branch.** And do not trust "2732 is merged" — step 2 of that block asserts the *constructs*
exist at the base commit, because a merged PR whose content was reworked is the same failure with a
green checkmark. **r2 adds a second layer:** D13 puts `describeForSku` in a 2643-owned file, so the
orphan variant where 2643's method is dropped *out of 2732's file during 2732's own rework* cannot
happen — that file is not 2732's to rework.

### PM2 — It ships completely, every test is green, and nothing is ever configured

All six phases land. The dialog works. And **2,720 of 2,720 SKUs still point at `PutAwayLane`**, because
2732's stop-seeding and scoped backfill either never applied to a tenant (`V2.2.13` merged but not
applied — 2732's own pre-mortem P1) or applied and nobody used the new screen. Operators do not know the
capability exists: the pencil button is one more icon on a master-data table nobody was told changed.
The ticket closes on green tests, and the requester reports the same problem in six weeks.

**This is the most likely failure**, because every automated signal is green in exactly this state — the
verify script passes, both test suites pass, and the manual plan passes on a stand-in SKU nobody uses.

*Detector:* **`wms2.putaway.resolution{source="SKU_OVERRIDE"}` stuck at zero** two weeks after B2.
Corroborate in SQL per tenant: `SELECT count(DISTINCT putawaylocation_id) FROM itemdata;` still returning
**1**, or `SELECT count(*) FROM putaway_config_audit WHERE scope='SKU';` returning **0**. ⚠ Note that
2732 §8.1's tier-2/3 condition would **not** detect this — those counters can be non-zero while the SKU
tier stays inert, and vice versa.

*Mitigation:* §8.4 makes `source="SKU_OVERRIDE" > 0` a **closure condition**, not a nice-to-have — the
ticket cannot be closed against an inert feature. Plus: hand the requester the exact click path and the
stand-in SKU in the PR description, and confirm one real configuration on UAT with them present before
closing. Q10 exists precisely so that confirmation has a real subject.

### PM3 — It ships, it is correct, and the operator concludes it is broken

**r2 rewrote this scenario, because r1's version described a failure mode r2's design makes
impossible.** r1's PM3 was *"an operator saves a pick-face configuration and every receipt for that SKU
then fails"* — which could not happen even under r1, because the **write** 422s (§9.1, §10.3 C10a). With
D1 reversed, no operator can configure an incompatible destination through 2643 at all. **The real
residual risk is not a bad configuration. It is a good feature that reads as a broken one.**

The scenario: B2 ships. Scott Dalton opens the SKU screen for the Ice Pack SKU — the worked example in
his own ticket — clicks the new pencil, types `ICE` into the location search, and gets **nothing**. He
tries the flowbin's name. Nothing. The list he can see holds 92 rows, none of which is the location he
filed the ticket about, and 496 of the warehouse's locations are flowbins. **He concludes the search box
is broken, or that the feature was built wrong, and reopens the ticket** — which is materially worse than
r1's scenario, because it burns the requester's trust in a feature that is behaving exactly as designed.

Second variant, subtler and more likely at scale: an operator *does* find a plausible-looking storage
location, saves it, and it works. Then receipts of that SKU hold `FOR UPDATE` on that Location row for a
whole multi-case receipt — **arming §7.4 row 8's lock-order inversion, which has no deadlock-retry
infrastructure.** This is 2732's accepted risk (`:2308`(i), `:1607`), not a new one, and it is the reason
the storage tier must stay behind a toggle.

*Detector:* the ticket being reopened, or a support question of the form *"the location picker doesn't
show our bins"*. There is **no metric for a misread UI** — which is precisely why the mitigation has to
be in the UI text rather than in observability. For the second variant: **`40P01` /
`DeadlockLoserDataAccessException` in the logs on `/receiving/receive`** — and it **must** be log-based,
because that endpoint returns 200-with-`errors` and never a 5xx, so an HTTP-status alert misses it
entirely. Also watch `wms2.putaway.resolution.rejected`: under r2 a non-zero value means a *pre-existing*
DB-written configuration is invalid, or a write-time predicate and a receive-time check disagree — the
latter is a 2732 bug worth escalating, not an accepted state.

*Mitigation, four layers:* (1) **the always-visible scope banner** (§3.8.2a) — ⚠ **r7: it no longer says
"pick faces are not yet selectable" and no longer names SBDEV-2821 (merged) or 2732 Q9.** It states that
a pick-face destination is **routed via putaway, not placed directly**, plus the consequence and the
computed eligible count — so what is *confirmed and explained* is now the **placement deferral**, not a
short list; (2) the **picker's empty state** repeats the same facts, because a client-side filter can
yield zero rows even when thousands are eligible (⚠ "even with 92 eligible" was an `wh01_hydra_v2`
measurement under r2's exclusion set — SKU scope now returns **2,554** on wineco-dev); (3)
**the banner wording is reviewed by Scott Dalton / David Oppenheim before B2 merges** (§5.7, §5.9) —
the person who will misread it is the person who filed the ticket, so he should approve the sentence; (4)
for the second variant, the picker **defaults to the `useforgoodsin` tier** with storage behind 2732
§3.11.2's explicit toggle and lock-contention warning, so arming the deadlock path takes two deliberate
operator actions. *Kill path for a regretted configuration:* one Clear in the dialog, or
`UPDATE itemdata SET putawaylocation_id = <lane id> WHERE id = …`.

**And the honest framing for the requester, which belongs in the PR description, not buried here:**
*"This ticket ships the configuration surface. The specific location in your example is a pick face;
pick-face putaway is SBDEV-2821 and is not yet supported by receiving, so it is not offered here yet —
the screen will offer it automatically once 2821 lands, with no further UI work."*

---

## 12. Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | **All callsites enumerated** — every §0 row covered by §3 Design or excluded with rationale | ✓ §0 (85 rows across 3 sub-tables) → §3 / §4. Every out-of-scope row carries `no — owned by SBDEV-2732 <section>` or an explicit `out` rationale |
| 2 | **Adjacent shapes** — other classes/methods sharing the pattern that need the new behavior | ✓ §0.1 rows 29–31 (the 4 other `putawaylocation_id` write paths — all 2732's), row 34 (`BoxtypeService.java:87` shares the *key name* on a different entity — deliberately NOT swept), §0.2 row 53 (its test), §6.2 (the 15 payload consumers), §0.3 row 85 (mobile UI, out) |
| 3 | ⚠ **r7: re-answered for A4.** **Backward compatibility** — API contract, DB schema, persisted state, frontend payload, error-response shape; explicit "What Does NOT Change" | ✓ §6 (13-row table), §6.1 (the `fullDetails` stray-row hazard + its no-op pre-fix), §6.2 (all 15 call sites: 3 + 12 + 0), §6.3 (18-item **What Does NOT Change**) |
| 4 | **Concurrency** — races, lock ordering, optimistic-lock retry, deadlock, idempotency under retry | ✓ §7.4 rows 5, 6, 8 — including that **2643 is the surface that arms** 2732's accepted lock-order inversion (`transferUnitLoadToLocation:150` before UL/SU at `:293-294`, no retry infra) — ⚠ **r2: 2643 does NOT widen the armed set** (D1 reversed; §5.1 row 9 records why no deadlock-retry prerequisite is inherited). §11.1 PM3's storage-location variant + the log-based `40P01` detector |
| 5 | **Multi-tenant** — cross-tenant queries, tenant context propagation, per-tenant cache/pool scoping; v2 scalability checklist filled | ✓ §7.3 rows 2, 4 (`tenantTransactionManager` literal; the `allEntries=true` trap 2643 must not touch), §7.4 (all 10 rows), §10.1 D4 (AC7 is structurally satisfied — one DB per facility) |
| 6 | **Error handling** — every new throw path has a handler or a documented contract change | ✓ §3.2 (`IllegalTransactionStateException` → 500 if the resolver is called from a controller; prevented by `A2-neg-res` + M9), §3.4 (`BusinessException` on the new endpoint), §3.8.3 (422/409 land in `catch`, not `results.errors`; `e.response.data` surfaced), §3.8.3's CORS/`reset()` landmine + M6, §3.3 (the dangling-FK case becomes *representable* rather than throwing) |
| 7a | **DB verified** | ✓ frontmatter `db_verified: true` + `db_verified_note`; §2.1–§2.2 (every number re-measured SELECT-only on `wms2-hydra-dev2` 2026-08-07, independently of the analysis lane); §7.5's Q10 subject problem |
| 7b | **Observability** — logs, metrics, Grafana panels, alert thresholds | ✓ §7.7 (6 signals), §5.1 row 8 (the panel ops must add, and why 2732's closure signal is the wrong one for 2643), §8.4 item 3, §11 PM2's detector. §0.1 row 11 / D11 covers the one **log** defect (`:93` renders the new value as `oldLocation`) |
| 8 | **Rollout / migration** — Flyway version, backfill, deploy-order, feature flags, sysprop rows, rollback | ✓ §5.1 rows 1, 4, 5 (**zero migrations, zero backfill, zero flags** — each with a rationale, not a blank), §8 (7-step order), §8.1 (the ancestry gate as executable commands), §8.3 (rollback: code-only, no forward-only constraint anywhere) |
| 9 | **Test coverage** — unit + integration + manual smoke; named classes and methods | ✓ §7.1 (17 named Java methods), §7.2 (14 named Jest tests), §7.5 (**13 manual rows**, incl. M2 which proves a mitigation is load-bearing and M10 which proves D1's boundary from **both** sides — the picker's omission and the API's 422 — rather than a happy path), §7.6 (e2e = the M4→M5→M11 chain, recorded as a deliberate gap), §7.9 (7 skipped items, each with a reason). No performance target is claimed, so no perf test |
| 10 | **Cross-version (v1↔v2)** | **no — v2-only, and deliberately.** v1 has no equivalent UI and no 4-tier resolver; SBDEV-2642 (the v1 sibling) shipped **zero commits** across all five repos and was closed as superseded (2732 §10.5). There is nothing to port in either direction and no paired v1 plan is warranted |
| 11 | **Alternatives considered** — at least 2, each with an explicit rejection rationale | ✓ §9 — **4 primary** (offer pick faces behind an advisory / stack on 2821 / widen `getLocationView` / absorb into 2732), each with pros, cons and an explicit rejection, plus **6 more** in §9.5. ⚠ **r2 inverted §9.1**: what r1 rejected is what r2 ships, and r1's own D1 is now the rejected option — with the three grounds spelled out (the write 422s; 2732 Q9 declines the same widening; 2643 cannot divergence-document a validator it does not own) |
| 12 | **Principles the plan is graded against are STATED** | ✓ **§14** (r2 addition — MUST-7). r1 was audited against five principles it never wrote down, so a reviewer could not check the plan against them and the author could not tell when one was being traded away |
| 13 | **Risks cited are DEFINED** | ✓ **§11.0** (r2 addition — MUST-6). r1 cited R1/R2/R4/R5 seven times as "(§11)" and defined none of them; §11 was the pre-mortem |
| 14 | **Revision history is auditable** | ✓ **§15** (r2 addition) — every r1→r2 change tied to the Architect finding or user decision that drove it |

---

## 13. Acceptance

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh`

Run as:

```bash
# API checks
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
WEB_UI_ROOT=/home/nampark/dev/wms-claude/v2/wms2-web-ui \
  bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh
```

⚠ When run against a **worktree**, point `PROJECT_ROOT` / `WEB_UI_ROOT` at the worktree (or a symlink
shadow root), or the script grades the main checkouts instead of the work.

⚠ **r7 — THE SKIP COUNT IS ALREADY ZERO, so the old "watch the SKIP count" advice no longer detects
anything.** Every 2732-blocked branch resolved when 2732 merged, so **all 93 rows now run** and the current
baseline is **`23 pass / 70 fail / 0 SKIP`** (api `bcfdc47`, web `e702a42`). Consequences for reading a run:

- **Every FAIL is 2643's own unimplemented work.** There is no "blocked on 2732" hiding place left.
- **The pass count is the number to watch, and it must only rise with implementation.** If it rises
  without a corresponding deliverable, a check has gone vacuous — that happened to `A4-neg-native`,
  which was green on an untouched tree until it was conjoined with its positive.
- **Adding rows must move the FAIL count by exactly the number added.** The 7 A4 rows first landed
  behind an undefined `if` guard and silently did not run at all; the totals stayed `23/63` and the run
  looked unchanged rather than broken. **Check the arithmetic, not just the colours.**
- §8.4 still requires **0 FAIL and 0 SKIP** at closure.

> [!note] **r6 — the SKIP→FAIL escalation was EXERCISED on 2026-08-11 and it works. Three measured baselines:**
>
> | `PROJECT_ROOT` | Result | Reading |
> |---|---|---|
> | main checkout, **before** 2732 merged | `11 pass / 22 fail / 50 skip` | correct — 2732 genuinely absent upstream |
> | main checkout (`develop` @ `fd90487`), **after** 2732 merged | `11 pass / 72 fail / 0 skip` | **escalation fired**: all 50 SKIPs became FAILs |
> | a 2732-bearing tree (`0837289`) | `11 pass / 38 fail / 34 skip` | 34 rows correctly return to SKIP — they are blocked on **Phase 2**, not Phase 1-API |
> | same tree, **after** the r6 script fixes | **`11 pass / 39 fail / 34 skip`** ← **quote this one** | +1 row: `B1-neg-cfg` is new |
>
> **The escalation behaves exactly as change 2 below specifies. But note what it cannot distinguish:** the
> middle row is a **stale local checkout**, not contract drift. The probe reads the merge from
> `origin/develop` and the constructs from `PROJECT_ROOT`, so an unpulled `develop` presents identically to
> a renamed-on-merge facade. Both need action, but different action — **pull before you diagnose PM1.**
> **✅ The script was fixed on 2026-08-11 and re-baselined — three defects, one of them a permanently-red row:**
> 1. **`B1-cfg` asserted `appAdminGroup`** — dead config. It now asserts
>    `hasResourceRole('sb_admin', …)`, and a new **`B1-neg-cfg`** row rejects `appAdminGroup` *and*
>    `hasRealmRole` (guarded on the computed existing, so it is not a vacuous negative). **Negative-tested
>    four ways:** correct gate ⇒ both PASS; the old dead-config gate ⇒ both **FAIL** (the old row would have
>    PASSED it); `hasRealmRole` ⇒ both FAIL; unimplemented tree ⇒ both FAIL.
> 2. **`migration_2211_present()` grepped `^V2\.2\.11__`** while every comment and message around it said
>    `V2.2.13` — 2732 renumbered on 2026-08-10. So the dependency line printed *"ABSENT → AC4 / AC9
>    unreachable"* **even against a tree that has the migration**: a permanently-red row indistinguishable
>    from an honest blocker (the recorded failure mode). Fixed and proven — the old script says `ABSENT` on
>    the 2732 worktree, the new one says `PRESENT`.
> 3. **Stale text**: the skip banner said *"plan status: draft, nothing merged"*, and the per-row reasons
>    said *"blocked on Phase 1-API + Phase 2-UI"*. Both now name **Phase 2 (step 19 + step 18a)**.
>
> Audited at the same time, per the recorded landmine that an undefined check function records bash's 127 as
> a plain FAIL: **no undefined invocations, no dead checks, no duplicate definitions.** The three
> `check_*` names that resolve to nothing are comment-only records of deleted rows.

**Three r2 changes to how the script grades:**

1. **The 2732 gate greps class declarations, not file existence** (`class PutawayDestinationQueryService`
   / `class PutawayConfigController` / `class PutawayConfigService`). r1's `[ -f ]` test meant an **empty
   file** passed the gate, and the header's claim that it *"tests for the CONSTRUCTS, not for a merge
   message"* was not true of the code beneath it.
2. **SKIP escalates to FAIL once SBDEV-2732 is merged.** If a SBDEV-2732 **merge commit** is on
   `origin/develop` but the constructs are absent under `PROJECT_ROOT`, the honest verdict is **contract
   drift (PM1)**, not "blocked" — so those rows FAIL and say so. The probe matches a 2732 **branch name
   on a merge commit** and scans all merges: a bare `--grep=SBDEV-2732` matches commits that merely cite
   the ticket (4 such on 2026-08-07), and any `-N` window lets the signal expire silently. Without this, a renamed-on-merge facade
   SKIPs every 2732-blocked check forever while reporting a plausible story.
3. **The `A3-*` rows are split by accountability** (D12). **Consumer** rows — the dialog sources its
   items from `eligibleLocations`, does **not** call `/location/detailView`, and does **not** re-derive
   predicates in JS — are asserted against 2643's own files. **Contract** rows run only once the endpoint
   exists, *whoever* shipped it. **2643 does not assert the shape of constructs it did not write**, which
   is the only honest posture once D-D is handed to 2732.

### 13.1 The ticket's 12 acceptance criteria — reachability

> [!important] **REFRESHED r7 (2026-08-12) — READ THIS BEFORE THE TABLE; ITS ❌ MARKS ARE STALE.**
>
> Every ❌ in the table below reads "blocked on 2732 Phase 1-API" or "blocked on 2732 Phase 2-UI".
> **2732 is fully merged, so none of those blocks exist.** Rather than rewrite twelve rows in place and
> risk losing the reasoning each one records, the corrected status is stated once here and the table is
> kept as the derivation.
>
> | AC | r6 verdict | r7 verdict |
> |---|---|---|
> | **1** | 🟡 partly | ✅ **reachable** — A1 for the id, A2 for effective/inherited |
> | **2** | ❌ blocked ×2 | ✅ **reachable** — `PUT /putawayConfig/sku/{itemdataId}` and `LocationPicker.vue` both merged |
> | **3** | ❌ blocked | ✅ **reachable** — the picker renders `locationName — areaName` (`areaName` is on the `EligibleLocation` record). The AC3 reinterpretation stands: `Location` has no code column |
> | **4** | ❌ **HARD-BLOCKED** on `V2.2.13 DROP NOT NULL` | ✅ **reachable on `wms2-wineco-dev`** — `V2.2.13` applied 2026-08-11 13:50:50 and `Itemdata.java` no longer carries `@NotNull`. ⚠ Not reachable on `wh01_hydra_v2`, which is **INACTIVE on DEV** and therefore never migrated and never served — moot, not broken |
> | **5** | ❌ | ✅ reachable (follows AC2) |
> | **6** | ❌ blocked on the validator | ✅ **reachable** — `PutawayDestinationValidator` + `PutawayDestinationRules` merged, and all 7 `BlockingReason` values exist. Both reinterpretations stand ("active" → `entityLock`, "shipping lane" → `gate`) |
> | **7** | ✅ already true | ✅ unchanged |
> | **8** | 🟡 partly | ✅ **reachable** — A1 makes "invalid" distinguishable; the `compatible`/`warning` half is served by the merged preview |
> | **9** | ❌ **HARD-BLOCKED** on `putaway_config_audit` | ✅ **reachable** — table + `PutawayConfigAuditService` merged. ⚠ **The six-field obligation stands and is NOT discharged:** confirm 2732's table records SKU, facility, previous, new, user, timestamp |
> | **10** | ❌ | 🟡 **unblocked technically, but Q10 + Q11 still open** — no Ice Pack SKU on hydra DEV, and whether the target tenant has a `cl_nr='System'` row is unverified |
> | **11** | ❌ | ✅ reachable — plentiful client-owned subjects |
> | **12** | ❌, one clause unautomatable | 🟡 **unchanged in substance.** F1 is fixed (SBDEV-2863) so the backend half is met; **F2 STANDS** — `BaseControllerUnitTest:52-58` uses `standaloneSetup`, so `@PreAuthorize` is never evaluated, and the `@SpringBootTest` lane is still down (**SBDEV-2217**). Permission enforcement remains **manual-only**: row **M8** (expect 403) and r7's rewritten **M7** |
>
> **Revised summary: of 12 ACs — 9 are now fully reachable, 2 are reachable but gated on open questions
> rather than on code (AC10 on Q10/Q11, AC12's end-to-end clause on the dead IT lane), and 0 are blocked
> on another ticket.** Three still require the documented reinterpretation of ticket language against
> columns that do not exist (AC3, AC6 ×2). **The single largest change since r6: there is no longer any
> AC whose blocker belongs to someone else.**

| AC | Ticket wording (abridged) | Repo | Test lane | Phase | Reachability |
|---|---|---|---|---|---|
| **1** | WMS V2 displays the Default Putaway Location on the SKU | api + ui | Java (`ItemdataServiceUnitTest`) + Jest (`skuData.spec.js`) | A1, B1 / A2, B2 | 🟡 **PARTLY REACHABLE NOW.** The name already displays (`skuData.vue:142`, `skuInfo.vue:104`); adding the **id** needs no 2732. Showing the **effective/inherited** value is **blocked on 2732 Phase 1-API** |
| **2** | Authorized users can select a valid warehouse location through the UI | api + ui | Jest (`editSkuPutawayDialog.spec.js`, `skuData.spec.js` store) + manual **M4** | B2 | ❌ **blocked on 2732 Phase 1-API** (`PUT /putawayConfig/sku/{id}`) **and Phase 2-UI** (`LocationPicker.vue`) |
| **3** | Location selector is searchable and displays meaningful location information | ui | Jest | A3, B2 | ❌ **blocked on 2732 Phase 2-UI** + A3. ⚠ **Reinterpreted:** the ticket's `CODE — Human Name` pair does not exist — `Location` has **no code column**. Rendered as `locationName — areaName` (§3.9) |
| **4** | Users can clear an alternate location and return to standard Putaway Lane behavior | api + ui | Java (2732's `setSkuDestination(item, null)`) + Jest (`clearOmitsLocationIdEntirely`) + manual **M5** | B2 | ❌ **HARD-BLOCKED on `V2.2.13 DROP NOT NULL`** — `itemdata.putawaylocation_id` is `NOT NULL` in DB *and* `@NotNull` at `Itemdata.java:49`. **The single most blocking AC**, and it needs `V2.2.13` **applied**, not merely merged |
| **5** | Saved values persist after refresh and reopening the SKU | ui | Jest partly + manual **M11** | B2 | ❌ depends on AC2. ⚠ `masterData.skuData` **is** persisted to `localStorage['vuex-web']` (F3) — the overlay is safe because `skuData.vue:304` always refetches, and D5's no-column decision removes the stale-row path |
| **6** | Only valid, active, stock-compatible locations can be selected | api + ui | Java (`PutawayConfigControllerUnitTest` eligible/not-offered partition) + Jest | A3, B2 | ❌ **blocked on 2732's `PutawayDestinationValidator`.** ⚠ **Reinterpreted twice:** "active" has **no column** → `entityLock == NOT_LOCKED` (P2.2); "shipping lane" has no flag → nearest is `gate` (§3.9). ✅ **r2: this AC is now met WITHOUT divergence** — D1 reversed, so "only valid locations can be selected" is literally true: the picker offers the 92 that pass every predicate, P2.7(c) included. ⚠ **The cost is scope, and it is stated in the UI:** the ticket's own worked example (a flowbin) is not among them until SBDEV-2821 (§3.8.2a) |
| **7** | Locations are scoped to the applicable warehouse/facility | api | **none needed** | — | ✅ **ALREADY TRUE.** One DB per facility (2732 §2.4); every read is facility-scoped by the tenant datasource. **Asserted as an invariant (D4) — nothing is built for it** |
| **8** | Invalid or inactive existing configurations are surfaced safely | api + ui | Java (`shouldHandleMissingOptionalReferences` rewritten; `incompatibleConfigCarriesWarning`) + Jest | A1, A2, B2 | 🟡 **PARTLY REACHABLE NOW.** A1's unconditional id makes "invalid" *distinguishable* today (§3.3) — before it, `ItemdataServiceUnitTest:498` **enforced** the ambiguity. The `compatible`/`warning` half is **blocked on 2732 Phase 1-API** |
| **9** | Changes are recorded in an audit or activity log | api | Java (2732's `PutawayConfigAuditService.record`) + manual **M4**, **M13** | B2 | ❌ **HARD-BLOCKED on `putaway_config_audit`** (DB: 0 such tables). 2732 N11 + `V2.2.13`. **Verify 2732's table carries all six required fields** — SKU, facility, previous, new, user, timestamp |
| **10** | System SKUs, including ice packs, support this configuration | api | Java (a System-client SKU writes) + manual | B2 | ❌ depends on AC2. ⚠ **Q10 + Q11 OPEN** — no Ice Pack SKU exists on hydra DEV, and whether HMG has a `cl_nr='System'` row is unverified (PRD has `client_id = 0`) |
| **11** | Client-owned SKUs also support the configuration where applicable | api | Java + manual **M4** | B2 | ❌ depends on AC2. **Plentiful subjects:** all 2,720 SKUs on hydra DEV are client-owned |
| **12** | Automated tests cover viewing, setting, changing, clearing, invalid-location validation, and **permission enforcement** | both | Java + Jest for 5 of 6 verbs; **MANUAL-ONLY for permission enforcement** | A1…B2 | ❌ **and one clause is not automatable — but the blocker changed in r5.** ⚠ **F2 STANDS:** `BaseControllerUnitTest.java:52-58` uses `standaloneSetup` — no security filter chain, no method-security advisor — so `@PreAuthorize` is **never evaluated**; the `@SpringBootTest` lane is down (**SBDEV-2217**). ✅ **F1 IS FIXED:** SBDEV-2863 `675b4a1` (2026-08-07) repaired `Authority.IS_SB_ADMIN` **and** shipped the SpEL-evaluation test, so row 0e is discharged and **someone else has already supplied the working annotation.** **Consequence, restated: AC12's backend half is met; what remains unautomatable is proving it end-to-end**, which is manual **M8** (expect **403**). Base class is **`BaseControllerUnitTest`**, not `BaseControllerTest` (C6) |

**Summary: of 12 ACs — 1 is already satisfied (AC7), 2 are partly reachable today (AC1's id half,
AC8's distinguishability half), 9 are blocked on 2732 Phase 1-API. Two are hard-blocked on `V2.2.13`
specifically (AC4 on `DROP NOT NULL`, AC9 on `putaway_config_audit`). Three require documented
reinterpretation of ticket language against columns that do not exist (AC3 "location code", AC6
"active" and "shipping lane"). One (AC12's permission-enforcement clause) cannot be automated at all in
the available lanes.**

---

## 14. Design principles

> **r2 adds this section (MUST-7).** r1 was reviewed against five principles it never stated anywhere —
> so a reviewer could not audit the plan against them, and the author could not notice when one was being
> traded away. **Principle 3 is the one r1 failed, and failing it silently is what produced the D1
> reversal.** Each principle names where it is enforced and where it is currently strained.

| # | Principle | What it means here | Enforced by | Status in r2 |
|---|---|---|---|---|
| **1** | **Thin consumer with a ~~hard~~ TEMPORAL boundary** | 2643 builds the operator surface and the one API gap 2732 does not fill. It does not repair, extend or re-annotate 2732's code **while 2732 is in flight** | §4's "files 2643 writes into that 2732 owns: zero in the plan of record"; D13 (own the facade file); D12 (hand D-D over); §5.1 row 0e (the `@PreAuthorize` swap is not 2643's); verify `A2-neg-2732f` | ⚠ **AMENDED r7, deliberately and with the cost stated.** The principle held for the right reason and has now expired for the right reason. **2732 is merged (both phases) and ready to archive, so there is no concurrent PR to collide with** — and §11.0 already said this residue was *"temporal, not architectural"*. Holding the boundary past that point **inverts its purpose**: it would force B2 to ship a second `LocationPicker` host with a second preview gate and a second confirm path, and 2732 §3.11.2 names three copies of a confirmation gate as exactly how one ends up without it. So B2 now edits two 2732-owned files (`defaultPutawayLocationField.vue`, `store/admin/configuration.js`) — see §3.8. **The price is real and is paid in §5.7's testing row:** those files serve WAREHOUSE and MERCHANT too, so 2643 inherits a regression surface it did not have before. ⚠ **This amendment does NOT license the r1 breaches** — those were a *security-annotation swap* and a *2643-specific field bolted into a 2732 enum*, which principle 2 forbids independently of who owns the file |
| **2** | **One source of truth for predicates** | Eligibility is decided **once**, server-side, by 2732's `PutawayDestinationValidator`. Vue never re-derives a predicate, and 2643 never adds a competing classification | D3 / §9.3; verify `A3-neg-view` (`getLocationView` not widened), `A3-neg-pred` (no predicate names in the dialog), `B2-neg-dv`; `@select` emitting the full row (§3.8.2b) so the caller never recomputes | ✅ **honoured, and r2 closed the one leak.** r1 added a 2643-specific `advisory` field and a `PICK_FACE` value to a 2732 enum — 2643-specific classification inside a 2732 type. Both deleted with D1's reversal |
| **3** | **Divergence documented, never silent** | If 2643 departs from 2732, it says so, in the plan and in the UI. **And the departure must be described against what 2732 actually says** — a divergence documented against a misread contract is a *silent* divergence wearing a label | §9.1 (the rejected option, with 2732 line cites); §10.3 C10 (2732's self-contradiction, recorded rather than propagated); §3's `CONTRACT-PROVISIONAL` banner | ⚠ **r2 reframes this to a DEFERRAL rather than a divergence — there is no longer a divergence to document.** r1 documented D1 at length across §1.4, §9.1, §10.1 and PM3 — exemplary in form — but got its **mechanism** wrong: it asserted the write succeeded when 2732 422s it, and cited neither 2732 **Q9** (`:2561`) nor `:2308`(i)'s absolute deadlock prerequisite. **r2's D1 defers to SBDEV-2821 instead of diverging**, and cites both |
| **4** | **Legible failure over hidden failure** | An operator must always be able to tell *what* went wrong and *why*. A capability that is absent must say it is absent and name what will restore it | §3.8.2a's always-visible scope banner + empty state (naming SBDEV-2821 and 2732 Q9); M2 (confirm the hazard before confirming the fix); §7.7's **log-based** `40P01` detector, because `/receiving/receive` returns 200-with-`errors`; the CORS `reset()` vs `resetBuffer()` landmine carried with M6; §5.1 row 3 (a wrong `APP_ADMIN_GROUP` is a *visible* failure, not a silent hole) | ✅ **honoured, and it is what r2's D1 costs money to preserve.** Removing 511 rows creates a new silent failure — "the search is broken" — so the banner is a **deliverable with three verify rows**, not a nicety |
| **5** | **A green signal must be earnable** | The verify script must be capable of going red. SKIP is not PASS, a missing file is not "absent construct", and a check must fail on the pre-fix tree | Every helper opens `[ -f "$2" ] || return 1`; `skip()` is counted separately and §8.4 requires **0 SKIP**; the SELF-TEST block; the documented false-positive at the pencil check; R10 | ✅ **honoured, and hardened in r2.** The 2732 gate now greps class declarations and escalates SKIP→FAIL on a merge (SHOULD-8); `A2-env`, `B2-jest4` and `B1-jest2` were strengthened from checks weaker than their own names (SHOULD-10) |

**The tension these five do not resolve, left visible on purpose.** Principle 2 (one source of truth)
and principle 1 (thin consumer with a hard boundary) pull against each other: server-side evaluation in
2732's validator is what prevents semantic divergence, and it is also what makes every 2643 deliverable
touch 2732's world. r2 reduces the *textual* coupling to zero in the plan of record (D12, D13, row 0e),
but `Resolution`, `Source` and `PutawayScope` remain 2732 types wherever the code lives. **The residue is
temporal, not architectural** — see §11.0's closing note.

---

## 15. Revision log

### r7 — 2026-08-12 (this revision) — EVERY BLOCKER CLEARED; B2 SHRANK BY HALF; THE GATE WAS WRONG **AGAIN**; FIVE VERIFY ROWS WERE UNSATISFIABLE

Triggered by a status check while SBDEV-2732 wrapped up. **2732 is fully merged — both phases, 285/0 on
its own script — so 2643 has no external blockers left at all.** That good news is the smallest part of
this revision; clearing the blockers exposed four things that were wrong *in* the plan.

1. **⛔ NOTHING IS BLOCKED. Verify re-baselined: `23 pass / 63 fail / 0 SKIP`** (was 11/38/34), against
   api `bcfdc47` / web `e702a42`. **Zero skips is the headline** — every "blocked on 2732" branch has
   resolved, so every remaining FAIL is 2643's own unimplemented work. There is no hiding place left in
   the script. ⚠ Both local checkouts were **48 and 20 commits stale** when this started; the recorded
   SBDEV-2781 landmine, hit again. Fetch per repo before believing any grep.

2. **⚠ THE PERMISSION GATE WAS RE-SPECIFIED WRONG IN r6 — the revision that existed to fix it.**
   r6 replaced dead `appAdminGroup` with `$kc.hasResourceRole('sb_admin', $config.keycloak.clientId)`.
   **That returns `false` for 100% of real `sb_admin` users, permanently, on every tenant:** `sb_admin`
   is carried in the Keycloak **`groups` claim**, and group membership never appears under
   `resource_access` — no client argument can reach it. 2732 hit this in shipped code (a real admin got
   a permanently disabled control), fixed it in `util/keycloakRoles.js` by mirroring
   `JwtAccessTokenCustomizer.extractRoles`, and 2643 now imports that helper.
   **The lesson is about method, not Keycloak:** r6's form was "negative-tested four ways" and still
   wrong, because *a verify row can only prove the code matches the spec — never that the spec is
   correct.* Both wrong gates were derived by reasoning about where the role *should* live instead of
   reading a token. §3.11 rewritten; §5.1 row 3's ops action item **withdrawn** as never-relevant.
   Also: the gate must be **reactive data**, not a `computed` — `$kc` has no reactive dependencies, so a
   computed caches `false` forever. **Row `B1-perm` previously asserted a computed, i.e. it enforced the
   defect.**

3. **B2 SHRANK FROM 2.5 d TO ~1.0 d, because 2732 already built the hard half.**
   `defaultPutawayLocationField.vue` owns the preview gate, D11's confirm, all 7 `blockingReason`
   messages, the paginated accumulate, clear-omits-`locationId`, 422 surfacing and the permission gate —
   and its `scope` prop is documented *"'MERCHANT' / 'SKU' when steps 21 and SBDEV-2643 reuse this"*,
   with a `write()` branch that names 2643 as the owner of the SKU endpoint. B2 now **extends** it: five
   small deliverables instead of a parallel dialog. **§14 principle 1 is amended, not breached** — D13's
   "zero 2732-owned files" was a *temporal* guard against concurrent PRs (§11.0 said so), and holding it
   past the merge would force a second confirmation gate, which 2732 §3.11.2 identifies as how one ends
   up without it. **The price is named:** those files serve WAREHOUSE and MERCHANT, so §5.7 now owes
   their regression suites. ⚠ **A real integration constraint fell out of it:** `PUT
   /putawayConfig/sku/{itemdataId}` takes **no `confirmIncompatibleSkus`**, and at SKU scope preview's
   counts are degenerate — so the shared D11 confirm must be **skipped**, or the operator confirms into
   a write that cannot honour the answer.

4. **⚠ THE SCOPE BANNER CONTRADICTED ITS OWN D1 ROW FOR THREE REVISIONS, AND NAMED A SHIPPED TICKET.**
   §3.8.2a still carried r2's *"Pick faces are not yet selectable … tracked by SBDEV-2821"* while
   **D1 was re-reversed in r3** to *offer* pick faces. r4's log says the body was reconciled to r3; it
   missed this, and two verify rows kept the stale text enforceable. **SBDEV-2821 also merged
   2026-08-09.** So the banner would have told operators to wait for shipped work, about a restriction
   that does not exist. Rewritten to r3's actual meaning: **routed via putaway, not placed directly**,
   plus the operational consequence — which is the SBDEV-2731 defect class, not decoration.
   *Measured:* SKU scope offers **2,554** eligible rows on wineco-dev vs **516** at the other tiers; the
   gap **is** the pick faces.

5. **FIVE VERIFY ROWS COULD NOT PASS A CORRECT IMPLEMENTATION; ONE CONTRADICTED 2732'S OWN SCRIPT.**
   - **`A3-tx` asserted the OPPOSITE of what 2732 deliberately shipped.** It demanded
     `@Transactional(readOnly = true)` on `PutawayConfigController.eligibleLocations`; 2732 put the
     boundary on the query service, keeps **zero** `@Transactional` under `controller/`, and pins the
     absence with its own row **`P2A-ctl-no-tx`**. Two scripts in one feature family asserted
     contradictory things about one method. **Retired**, with `A3-lane` (grepped the controller for a
     constant that lives in the rules layer) and `A3-t1` (grepped for a test-method name 2643 invented
     and 2732 never used). Backing functions **deleted**, not left dead.
   - **`X-nomig` was a false FAIL**: it counted migrations in a version window and went red because
     *other tickets'* V2.2.12 / V2.2.13 exist. Now a **merge-base diff**, and it fails **closed**.
   - **`B2-store-ok` would have gone green on the duplication D3 forbids** — it required
     `eligibleLocations` to be *present* in the skuData store, which since A3's deletion means "add a
     second reader for 2732's endpoint". Inverted to `B2-one-elig`.

6. **A LATENT BUG IN THE SHARED HELPER, found only because the rows were tested against a synthetic
   conformant implementation.** `multiline_contains` interpolated its pattern into perl **source** with
   `/` as the regex delimiter, so **any pattern containing a slash was a perl syntax error** —
   `Unknown regexp modifier "/f"`, exit 255, recorded as an ordinary FAIL. Two r7 rows were red against
   correct code until this was fixed. It fails closed, so no historical green was false; but
   `multiline_not_contains` reads a non-zero exit as *"forbidden construct absent"*, i.e. the same bug
   there is a genuine **false green**, one keystroke away. Both now pass the pattern via the environment.
   ⚠ **This bug lives in `verify-plan-template.sh`'s idiom, so other plans' scripts likely carry it.**

**Audit evidence:** every row changed in r7 passes on a synthetic conformant tree and fails on
unimplemented develop, and **17 / 17 targeted mutations were caught** (one per row, each breaking only
that row's property). Done in throwaway git worktrees; both real checkouts left clean.

**ALL THREE OPEN ITEMS ANSWERED LATER THE SAME DAY (2026-08-12), and two of them changed the work.**

7. **✅ Q10 → (A) DEV-only on `wms2-wineco-dev`, and NO stand-in is needed.** Measured SELECT-only across
   four tenants. **The ticket's actual named subject is on the designated tenant:** `ICE PACK`
   `itemdata.id = 874400` (`client_id = 0` / `System`), the `ICEPACK` flowbin `location.id = 225817`, and
   an **active FLA `22742154`** binding the two (bounds 36/60/84) — bound to its *own* SKU, so rule (f)
   does not exclude it. Full subject table in §7.5. ⚠ **Three plan claims were falsified by measuring:**
   (a) ~~"all 2,720 SKUs point at `PutAwayLane`"~~ is a **hydra** fact — on wineco-dev **zero** do and
   **8,803 are NULL** post-`V2.2.13`; (b) ~~"the reported configuration is PRD-only"~~ — only its exact
   ids are; (c) **§7.5's designated stand-in `ICEBAGCHILLER` (18118466) was a HYDRA id on a WINECO
   tenant** — it does not exist there, so the manual plan could not have been executed as written. All 6
   references repointed to 874400.
   **UAT rejected with cause:** `nywh-hydra-uat` has an `ICE PACK` System SKU (3279555) but no `ICE PACK`
   location, and both UAT tenants sit at Flyway **`V2.2.10`** — `putawaylocation_id` still `NOT NULL`, no
   `putaway_config_audit`, no `client.defaultputawaylocation_id`, so **AC4 and AC9 are untestable there**.
   Applying `V2.2.13` to UAT is a prerequisite of any UAT coverage.
   ⚠ **A trap found in passing:** wineco-dev's *only* off-default-lane config is SKU `1135` (740645) →
   `Club08`, type **`cases and pallets`** — the type the review brief's M1b proved **throws**. It is an
   excellent **AC8** subject and a trap as an M4 happy path; §7.5 now says so.

8. **✅ Q11 → YES on every reachable tenant.** `client` row `0 | System | System-Client` exists on
   wineco-dev, hydra-dev2, wineco-uat and hydra-uat. `getSystemClient()`'s lookup resolves, 2732 §7.6's
   null-return warning does not arise, and the subject SKU 874400 **is** a `client_id = 0` row, so AC10
   and AC11 are both covered from one table.

9. **✅ Decision-3 Q3 → MIRROR 2732's already-approved wording; write no new copy.** 2732 step 19a's
   variant-A sentence lives in `messages.properties` as
   `putawayDestinationDivertedToLane=Received to %1$s. Putaway will move it to %2$s — the stock is not on
   %2$s until then.` §3.8.2a now specifies the configure-time mirror of it. ⚠ **It is a mirror, not a
   reuse:** that key is emitted only when a receipt was actually diverted (absent, not null, otherwise),
   there is no receipt at config time to bind its arguments, and `wms2-web-ui` has **no `vue-i18n`**.
   The §5.7 product-review item drops from blocker to courtesy — but the two strings must move together.

10. **✅ Decision-3 Q4 → option (ii): 2643 SHIPS THE SERVER-SIDE SEARCH. NEW SCOPE — Phase A4 (§3.5a).**
    2732's Q2 close assigned this to 2643 in writing (*"as a parameter on `eligibleLocations`"*) and
    **it was never built**: the endpoint takes only `scope`, `subjectId`, `Pageable`. Measured cost of
    not having it — the store accumulates every page at `size=200`, so **2,564 candidates on wineco-dev
    = 13 sequential round-trips before the operator can type** (wineco-uat 2,703/14; hydra 602/4).
    A4 adds `@RequestParam(required = false) String name` plus an in-query case-insensitive contains.
    **⚠ The empty-search identity contract is the load-bearing part** — tiers 2 and 3 call the same
    endpoint with no `name`, so a predicate bug silently *shrinks the WAREHOUSE and MERCHANT pickers*
    with no error shown. **⚠ And it creates a new way to get the banner wrong:** with a search applied
    `totalElements` counts matches, so the counts must be captured ONCE from the unfiltered read
    (`A4-neg-banner`). **Effort: B2 stays ~1.0 d, ticket total ~1.5 d.**

**Verify after the three answers: `23 pass / 70 fail / 0 SKIP`** — the 7 new fails are A4, and the pass
count did not move, which is the correct signal for added unimplemented scope. **24/24 mutations caught**
(17 rewritten rows + 7 new A4 rows). ⚠ **The A4 round hit three further script traps, all caught by
running the rows rather than reading them: an undefined function in an `if` GUARD deleted all 7 rows
silently (total stayed 23/63, so it looked unchanged, not broken); `A4-neg-native` passed vacuously on an
untouched tree; and a PCRE `(?i)` handed to the ERE helper matched literally.** All three are documented
in the script header — the guard one is a genuinely new variant of the recorded landmine.

**What remains open:** D1 still rests on Q12 → (iv-b), and review-brief **Decision 1 and 2 are still
unreturned** (Decision 3 is now fully answered). Nothing blocks implementation.

### r6 — 2026-08-11 — 2732 PHASE 1-API MERGED; PHASE A3 DELETED; THE PERMISSION GATE WAS BUILT ON DEAD CONFIG

Triggered by a status check, and it moved four blockers at once.

1. **SBDEV-2732 Phase 1-API MERGED** — `889298d` (+ review commit `0837289`), `V2.2.13` on develop **and
   applied to `wms2-wineco-dev`** (2026-08-11 13:50:50). Every §5.1 row-0 construct re-verified by symbol
   grep on `origin/develop`. **A2 is unblocked** and branches from `889298d`. **AC4 + AC9 are reachable**
   — on wineco-dev only.
2. **Phase A3 DELETED.** 2732's r-next §3.11.0 **adopted §3.5's specification verbatim** as its step 18a,
   settling Q5/D12 in writing and reclaiming 1.5 d. It extended the spec with a server-computed `tier`
   field and a bulk design — 5 queries, not 2,739 × `validate()`, because `isUnitloadTypePermitted` keys
   on `location.type_id` (8 distinct values). 2643 is now a pure consumer.
3. **Q6 CLOSED** — §3.8.2b's props/events contract accepted verbatim into 2732 §3.11.5. **Q2 CLOSED** from
   the merged code: `/preview` does accept `scope=SKU` and the 7-field envelope is as assumed. **A new,
   narrower blocker replaces Q2:** `BlockingReason` maps three of six throw keys to `null` and cannot
   express MUST-4's this-SKU-vs-another distinction — 2732 accepted that fix too (its §3.11.0a).
4. ⚠ **THE PERMISSION GATE WAS SPECIFIED AGAINST DEAD CONFIG.** §3.11's `isPutawayConfigAdmin` read
   `nuxt.config.js:167`'s `appAdminGroup`; **WMS V2 does not use `APP_ADMIN_GROUP` any more**, nothing
   reads it, and 2732 §3.12 says so independently. Re-specified as
   `$kc.hasResourceRole('sb_admin', $config.keycloak.clientId)` — a **resource** role on `om1-api`
   (`SecurityConfiguration.java:85-86`, `Authority.java:17`), so `hasRealmRole` would be silently false.
   §5.1 row 3 retired; verify row `B1-cfg` and manual row **M7** must be rewritten before B1's TDD gate.
5. **§10.3 swept:** C7, C10(a) and C10(b) are **discharged** by 2732's rewrite — C10(b) by 2732 *deleting*
   the filter as unimplementable, the strongest confirmation available. **C4 is still open.**
6. **The verify script's SKIP→FAIL escalation was exercised and works** (three measured baselines in §13).
   Quote `11 pass / 38 fail / 34 skip` as the pre-implementation baseline, not the stale-checkout `72/0`.

**What did NOT change:** D1 still rests on Q12 → (iv-b), and the three-decision review brief is still
unanswered. If Decision 3 comes back "wrong", D1 and 2732's §3.11.5a per-scope table both move.

### r5 — 2026-08-09 — PHASE A0 RETIRED; SBDEV-2863 SHIPPED IT

Triggered by a status sweep, not by a review: `origin/develop` had moved two merges ahead of the local
checkout this plan was written against (`6bc709a` → `fd90487`), and one of them closed F1 outright.
**The recorded SBDEV-2781 landmine — diff `develop..origin/develop` per repo before enumerating —
applied here and caught it.**

| # | What changed | Driver | Where |
|---|---|---|---|
| **★1** | **Phase A0 DELETED, not deferred.** [SBDEV-2863](https://app.clickup.com/t/868knmx18) merged 2026-08-07 (PR #134, `675b4a1` + `d8e0137`, merge `7d9d38e`) and shipped **both** halves: `Authority.java:44` → `IS_SB_ADMIN = "hasAuthority('" + SB_ADMIN_ROLE + "')"`, **and** a `@Nested AuthorityExpressionsResolve` class (+210 lines) that evaluates the constant through the real `CustomMethodSecurityExpressionHandler`. A0's two planned tests are strictly subsumed | SBDEV-2863 merging | banner, §0 rows 20–26 + 50, §2.5, §3.1 (fenced as historical), §4, §5 phase count, §5.1 rows 0c/0e/7, §5.2, §5.8, §7 test matrix, §7.5 M8, §8 rollout, §8.2, §11.0 R6, §13.1 AC12 |
| **★2** | **§5.1 row 0e DISCHARGED — by repair, not avoidance.** "2732 must not merge carrying `@PreAuthorize(Authority.IS_SB_ADMIN)`" is now **backwards**: that annotation is correct, and 2732 §3.12's six sites need no change | same | §5.1 row 0e, §3.1 r2 box, §12 item 5 |
| **★3** | **Two verify rows were reporting falsely; both fixed.** `A0-ctx1` asserted the *broken* spelling survives in `Authority.java` — **permanently red since 2026-08-07**, indistinguishable from unfinished work. `A0-spel` required `parseExpression(Authority.<CONST>)` literally and read FAIL against a shipped test that does exactly what A0 specified | empirical run against `origin/develop` | verify script |
| **★4** | **`X-2732-authz` DELETED — it would have failed a *correct* SBDEV-2732.** It asserted `PutawayConfigService` does **not** carry `@PreAuthorize(Authority.IS_SB_ADMIN)`, which is precisely the line 2732 §3.12 is right to write. Replaced by **`X-authz-constant`**, a regression guard asserting the *working* form in `Authority.java` — it runs today (no 2732 file needed) and was **negative-tested**: PASS on `origin/develop`, FAIL on pre-fix `6bc709a`, FAIL if the constant is deleted | the recorded landmine *"a verify check that fails a correct implementation is worse than none"* | verify script |
| **★5** | **R6 closed and downgraded to LOW; AC12's backend half unblocked.** What remains is **F2 only** — `standaloneSetup` evaluates no `@PreAuthorize` and the IT lane is down (SBDEV-2217) — so **M8 stays the AC12 evidence, now expecting 403**, and a 500 means 2863 regressed | same | §11.0 R6, §13.1 AC12, §7.5 M8 |

**Net effect: 0.5 d of work removed, one blocking prerequisite discharged, and two false verify signals
retired.** Nothing in r5 touches the D1 / (iv-b) design; r3 and r4 stand unchanged.

### r4 — 2026-08-09 — BODY RECONCILED TO r3

r3 reversed D1 in its banner but **left the body asserting r2 in five places**. Anything downstream of this
plan — a TDD gate above all — would have read the body, not the banner, and encoded the abandoned design.

| # | What was still asserting r2 | Now |
|---|---|---|
| **1** | §7 test **`eligibleLocationsNeverOffersPickFace`** — *"a `useforpicking`-area location is **not offered**, ever — P2.7(c) is absolute"*, mirroring 2732's `skuWriteRejectsPickFaceDestination` at `:2211` | **INVERTED** to `eligibleLocationsOffersPickFaces`. **This was the single most dangerous row in the plan:** a gate run would have made "never offer a pick face" a contract the executor may not weaken — the exact opposite of r3. The mirrored 2732 test was **deleted** 2026-08-08 and `:2211` no longer resolves |
| **2** | §7 test **`eligibleLocationsNeverRelaxesFixAssigned`** — *"a fix-assigned location is not offered, ever — P2.5 is absolute"* | **REWRITTEN** to `eligibleLocationsExcludesFlowbinAssignedToAnotherSku`. P2.5's absolute reject is dropped; a SKU pointed at **its own** pick face is the intent. Paired with a positive test so "exclude everything fix-assigned" cannot pass |
| **3** | **M10** — manual test instructing the tester to confirm the picker returns **no** flowbins and the API returns **422** | **REWRITTEN** — the picker DOES return flowbins, the write SUCCEEDS, and a foreign-bound flowbin is excluded. The r2 row could never pass against a correct implementation |
| **4** | **§10.1 D1** — still headed *"REVERSED IN r2 … pick faces are NOT selectable"* | **REWRITTEN as r3's**, r2 text struck through and retained |
| **5** | **frontmatter `db_verified_note`** — closed with *"2643 therefore offers only the 92 eligible locations"*, the first conclusion any reader hits | **REWRITTEN**, r2 struck through, r3's conclusion stated first |

**Also folded in — two things that postdate r3:**

- **2732 gained P2.7 rule (f)** (2026-08-09 review). Tier 1 is exempt from rule (e) but **not** from (f): a
  flowbin fix-assigned to a **different** SKU must not be offered. **1,344 of 2,555 candidate rows on
  `wms2-wineco-dev` (53%)**, 154 of 603 on `wms2-hydra-dev2`. Consequences: the exclusion set is **never
  empty**, so r3's *"on HMG production the exclusion set is empty"* no longer holds; and `blockingReason`
  needs an own-vs-foreign distinction, which is **2732's enum to extend** (MUST-4).
- **2732's P1 skip narrowed** to `sltname == 'flowbin'` only. Does not change this plan's dependency —
  `ICE PACK` is a flowbin — but the wider `useforpicking OR flowbin` form must not be restated here.

**Dependency cleared:** SBDEV-2821 **merged to `develop` 2026-08-09** (PR #135, merge `fd90487`). Putaway can
now surface a configured destination, which is what r2's deferral was waiting on.

**Not addressed by r4:** this plan is still `draft` and still blocked on 2732's Phase-1 API, which is itself
blocked on Q12 sign-off. r4 is a consistency pass, not an approval.

### r3 — 2026-08-07

Driven by the **Critic pass (verdict ITERATE — 2 BLOCKING, 7 non-blocking)**, plus three integrity
defects found by direct inspection of r2's artefacts. Every r2 defect was the **same class**: the
changelog claimed work that was not in the code. That is worth naming, because this plan's whole premise
is that a claim must be machine-checkable.

| # | Change | Driver | Where |
|---|---|---|---|
| **1** | **Scope-banner counts de-hard-coded.** `92` / `666` are measurements of `wh01_hydra_v2` on 2026-08-07; a banner asserting them to an operator whose warehouse has neither is *confidently wrong* — a worse failure than the silent one the banner exists to prevent, and an inversion of §14 principle 4. Now `{eligibleCount}` / `{totalCount}`, computed from the `eligibleLocations` response (reading a server verdict, so principle 2 is untouched). New verify row **`B2-banner3`** + Jest `scopeBannerCountIsComputedNotLiteral` | **Critic F-1 (BLOCKING)** | §3.8.2a, script `B2-banner3` |
| **2** | **`Q3`, `Q4`, `Q7`, `Q8` defined.** Cited ~20 times, defined nowhere — the same defect as r1's missing `R<n>` register, in the adjacent namespace. §10.4 rows are now numbered `Q3`/`Q4`/`Q7`/`Q8` + `Q13`–`Q18`. **No `Q1`** (promoted to D1); `Q5` struck. 2732's own questions are always written *"2732's Qn"* — and the first draft of this fix reused `Q9`, colliding with 2732's Q9 in the banner copy, so that row became `Q13` | **Critic F-2 (BLOCKING)** | §10.4 |
| **3** | **Drift probe unwindowed.** My own SHOULD-8 fix carried `-50`, which made it expire silently ~29 days after 2732's merge (192 merges on `develop`; the 50th-most-recent is 2026-07-09) — deferring the fail-quiet rather than closing it, while R10 and §15 called it closed | **Critic F-3** | script `git_has_2732_merge`, §11.0 R10 |
| **4** | **`B2-jest4` comment hole closed** — requires a matcher *call* and forbids an intervening `//`. ⚠ The first attempt used a bare `(?!//)`, which **terminates perl's `m/.../` delimiter**, so the check could never pass. Caught by negative-testing; a check that cannot pass is worse than one that cannot fail | **Critic F-4** | script `check_B2_jest_store_asserts_no_legacy` |
| **5** | **`receivingForm.vue` citations corrected in 6 places.** Constants are `:221-222` (not `:216-217`), comment `:215-220` (not `:210-215`), `isPutawayDestinationApplied` `:296-300`, `isPutawayOverride` `:301-305`, `putawayDisplay` `:309-314`. B1's deliverable pointed an implementer at prose. §10.3 grades this exact defect class in 2732 as HIGH (C4) — the standard must survive contact with this document | **Critic F-5** | §0.3 row 73, §3.7, §4, §6 |
| **6** | r1 remnants removed: M4's dead *"(non-advisory)"* parenthetical; `check_A3_test_three_classes` → `check_A3_test_two_classes` | **Critic F-6** | §7.5 M4, script |
| **7** | Stale **"44 checks"** replaced with *"every 2732-blocked check"* — r1 skipped 44, r2 skips 51, and the number moves with every added check | **Critic F-7** | §11.0 R10, PM1, §13, §15 |
| **8** | Script header `:27` now names `SkuPutawayQueryServiceUnitTest` (the one place SHOULD-9 had not landed) | **Critic F-8** | script header |
| **8b** | **`A3-t1` strengthened.** Was a bare substring grep for `eligibleLocations` under the label *"controller test covers eligibleLocations"* — satisfied by an import or a comment. §13 claims CONTRACT-side rows *"assert properties any correct implementation must have"*, and a substring is not one. Now requires the named §7.1 method `eligibleLocationsSkuScopeTwoClasses`. A fallback-only row (D12 hands D-D to 2732) that cannot fail is still worthless | **Critic F-9** | script `check_A3_test_two_classes` |
| **9** | **Three r2 integrity defects fixed by direct inspection**, all "changelog ≠ code": (a) `A0-swap` / advisory-banner check *functions* were deleted per MUST-5 but their `run` call sites survived — `command not found` the moment 2732 merged; (b) the drift probe matched any commit *citing* 2732 (4 real matches: `89de3f0`, `b623561`, `a991c9e`, `a2bd0e9`), escalating 73 correct SKIPs to FAIL — the detector became the false signal it exists to prevent; (c) `X-2732-authz`, `A2-neg-badconst`, `B2-banner`, `B2-banner2` were listed as ADDED in the header but existed only as comments | direct inspection | script |

**Verify state after r3:** `bash -n` clean; **zero** dangling call sites, **zero** orphan definitions, **zero**
duplicate `run` wirings; baseline **13 pass / 24 fail / 51 skip**, exit 1. `B2-banner3` and the tightened
`B2-jest4` were negative-tested in both directions (fail on the defect, pass on a correct
implementation, fail on a missing file).

> ⚠ **The r2 rows below are HISTORY, not the current design.** r3 re-reversed D1 and r4 reconciled the body to it. A row here saying *"pick faces are not selectable"* records what r2 decided on 2026-08-07 — it is **not** an instruction.

### r2 — 2026-08-07

Driven by the Architect review (SOUND-WITH-CHANGES, 13 required changes) and by the user's **reversal of
D1**. Every row names what changed and what drove it.

| # | Change | Driver | Where |
|---|---|---|---|
| **★1** | **D1 REVERSED.** The picker offers only the 92 eligible locations; **pick faces are not selectable**. Reframed from *"deliberate documented divergence"* to **correct sequencing** — 2732 `:722` already assigns tier-1 pick-face relaxation to SBDEV-2821. The *"an operator can save a configuration that later fails at receive"* residual-risk framing is **deleted as false**: a SKU-scope pick-face write is an unconditional 422 (`:722`, `:792-795`, enforced by `skuWriteRejectsPickFaceDestination` at `:2211`) | **User decision**, on Architect MUST-1. r1 would have shipped ~511 rows whose selection cannot be saved — two dead ends instead of one | §1.4, §3.5, §9.1, §9.2, §10.1 D1, §11.1 PM3, §13.1 AC6, M10, frontmatter `db_verified_note` |
| **★2** | **M10 rewritten.** r1 asserted *"the picker **offers** it… the write **succeeds**"* — **false, and the row could never pass.** r2 asserts the picker does **not** offer pick faces and that a curl'd pick-face write **422s** | same | §7.5 M10 |
| **★3** | **Scope banner added as a deliverable.** Always visible above the picker, plus a matching empty state, naming **SBDEV-2821** and **SBDEV-2732 Q9** and stating the eligible count — so an operator who cannot find their location learns *why* rather than concluding the search is broken | same (preserves principle 4, which the reversal would otherwise have cost) | §3.8.2a, §4, §7.2, §5.7, PM3; verify `B2-banner`, `B2-banner2` |
| **★4** | **D1's apparatus deleted:** the 2643-specific `advisory` field on a 2732 type, the `PICK_FACE` addition to 2732's `blockingReason` enum, and the "receiving not yet supported" per-row warning. **The storage-location lock-contention warning is KEPT** — that hazard is real and 2732 `:1607` requires it | same; **also resolves MUST-4** (these were the two undeclared 2732-file mutations missing from §4) | §3.5, §4, §7.1, §7.2; the old `A3-advis` row is **deleted** and replaced by `A3-neg-advis` / `B2-neg-advis`, which assert the apparatus is *gone* |
| **★5** | **No deadlock-retry prerequisite is inherited**, stated explicitly so nobody re-adds it. That price applied only to r1's D1, which did what 2732 Q9 declines | same | §5.1 **row 9**, §7.4 row 8 |
| **★6** | **2732 Q9 (`:2561`) and §7.6 row 8(i) (`:2308`) now cited** — as the reason r1's approach was rejected | **MUST-2**, satisfied by rejection rather than by pricing | §9.1, §10.1 D1, §5.1 row 9 |
| **★7** | **§10.3 gains C10** — 2732's Q12 (`:2558`) independently reaches r2's conclusion for the *club* case: wineco's `Club01`–`Club08` are live multi-SKU pick faces (`useforpicking = TRUE`, all lane flags FALSE), so 2732's own named tier-2 scenario is **also** blocked by P2.7(c) | user instruction + **SHOULD-13** | §10.3 C10, §10.4 |
| **8** | **§3.2, §3.4, §3.5 marked `CONTRACT-PROVISIONAL`**, with a blocking banner at the head of §3. §5.9's re-verify bullet promoted to that banner | **MUST-3** — 2732 is `draft` and 2732's own D18 (`:103-106`) records changed validator semantics with no independent pass and a prior CRITICAL finding | §3 head, §3.2, §3.4, §3.5, §5.9 |
| **9** | **A0's constant swap removed from 2643's scope.** The **detector stays** (highest-value near-term artefact); the swap becomes §5.1 row 0e, owned by 2732's review or SBDEV-2863. The two `A0-swap*` verify rows are deleted and replaced by a **prerequisite probe** (`X-2732-authz`) and a consumer negative (`A2-neg-badconst`) | **MUST-5** — a 2643 PR reverting a security annotation that 2732 deliberately writes in 2732's own file is the wrong home | §3.1, §4, §5.1 row 0e, §5.2, §5.4, §8, §8.2, §10.1 D2, §13.1 AC12, M8 |
| **10** | **§11.0 risk register added**, defining **R1–R10** with severity, mitigation and the r2 delta for each. Every `R<n>` citation now resolves | **MUST-6** — r1 cited R1/R2/R4/R5 seven times as "(§11)" and defined none | §11.0; refs at §1.3, §3.2, §3.4, §5.3, §5.4, §5.9, §6.1, §9.4 |
| **11** | **§14 design principles added** — five, with enforcement points and honest status. Principle 3 reworded to cover a *deferral* rather than a divergence | **MUST-7** | §14 |
| **12** | **Verify script's 2732 gate hardened** — greps class declarations instead of `[ -f ]`, and escalates **SKIP → FAIL** once a SBDEV-2732 **merge commit** is on `origin/develop` (branch-name match on merge commits only, unwindowed — a bare `--grep` matched 4 commits that merely cite 2732, and a `-50` window expires ~29 days after the merge). The header's *"tests for the CONSTRUCTS"* claim is now true of the code beneath it | **SHOULD-8** — a renamed-on-merge facade must not SKIP every 2732-blocked check forever | script `:187-`, §13 |
| **13** | **`describeForSku` moved into a 2643-owned `service/SkuPutawayQueryService.java`** (D13). Same transaction boundary, injecting 2732's resolver directly — the `MANDATORY` rule needs *a* transactional bean, not *2732's* bean. Test renamed to `SkuPutawayQueryServiceUnitTest` | **SHOULD-9** — drops the cross-plan write surface and de-risks R1/PM1 | §0.1 row 7, §3.2, §3.4, §4, §5.4, §7.1, §11.0 R1, PM1; verify `A2-facade`, `A2-tx`, `A2-fsvc`, new `A2-neg-2732f` |
| **14** | **Three weak checks strengthened.** `A2-env` asserted 4 fields under a "7-field" name → now asserts all 7. `B2-jest4` was a bare substring grep that passed if the spec asserted the opposite → now requires the `.not.`-first form. `B1-jest2` grepped for `disabled`, which any Vuetify spec contains → now anchored to `isPutawayConfigAdmin` + `.exists()` + `.attributes('disabled')`. **The required assertion forms are specified in §7.2 so they are writable, not guessable** | **SHOULD-10** | script; §7.2 |
| **15** | **`B1-pre` is now a HARD PREREQUISITE of A1**, not a "safe trick"/"prefer that ordering". **M2 reframed** as a local pre-`B1-pre` *observation*, not a deliberate deploy of a known cosmetic defect to a DEV that auto-deploys on push | **SHOULD-11** | §5.1 row 4, §5.3, §5.8, §6.1, §8 step 2, §8.2, M2 |
| **16** | **Q6's picker contract promoted to a written spec** (§3.8.2b) and handed to 2732, with a §5.1 row 0b acceptance item (D14). **C7 upgraded from "UNVERIFIED" to CONFIRMED WRONG** with real coordinates: `createBol.vue:100-130` is plain `v-text-field`s; the file's only `v-autocomplete` is at **`:68-76`**; `grep -n Lookup` returns **nothing** | **SHOULD-12** | §3.8.2b, §5.1 row 0b, §10.2 Q6, §10.3 C7 |
| **17** | **D-D specified fully but HANDED TO 2732** (D12), with A3 as a named fallback and a decision deadline before A3's TDD gate. **The 8 `A3-*` verify rows re-scoped** from *producer* to *consumer* assertions plus contract rows that run whoever ships the endpoint | Architect **Q3** recommendation | §3.5 ownership box, §5.1 row 0d, §5.5, §8, §10.1 D12, §10.2 Q5, §13; script's A3 block |
| **18** | Housekeeping: D11's stray "(Q9)" tag removed (it collided with **2732's** Q9, which D1 now cites); §12 gains rows 12–14; §8.4 gains closure conditions 5–6; frontmatter gains `revision: 2` | consistency pass | throughout |

**What r2 deliberately did NOT do**

- **Did not build a 2643-owned SKU-scope validator** (Architect option C). It would duplicate six
  safety-critical predicates and violate §14 principle 2 and D3's entire rationale. Explicitly rejected
  in §9.1.
- **Did not raise a change request against 2732's P2.7(c)** (Architect option A). It is the right *target
  state* and 2732 already owns it as SBDEV-2821 — but it is gated on the deadlock-retry ticket
  (`:2308`(i)), so the near-term outcome would be identical to r2's while adding a negotiation. Recorded
  in §9.1 ground 3.
- **Did not split the document** into "ships this week" / "asked of 2732" as separate files (Architect
  synthesis point 2). The same information is now carried by §3's banner, §4's zero-2732-files statement,
  D12/D13/row 0e and §5.8's honest read — without fragmenting a plan whose value is in its §0 and §2
  cross-references.
- **Did not re-measure the DB.** Every number in §2 is unchanged and was verified SELECT-only on
  2026-08-07; the reversal changes what the 92/511/154 split *means for the design*, not the split.

### r1 — 2026-08-07

Initial draft, written from a verified analysis bundle. Repos read at `wms2-api` `6bc709a` /
`wms2-web-ui` `4ce39a1`. DB measured SELECT-only on `wms2-hydra-dev2`. Reviewed by the Architect lane,
which returned **SOUND-WITH-CHANGES** with 7 MUST and 6 SHOULD changes — all applied above.

---

## 16. Notes

- **Recommended OMC composition.** Size class **Large** (2 repos, 6 phases, cross-subsystem, security
  work, a deliberate divergence from a sibling plan's contract). Pre-draft: `analyst` + `planner`
  (done — this document). Plan review: **`critic`** — mandatory, and it should specifically pressure-test
  **D1** and §10.3's corrections to 2732. Implementation: **`ralph`** per phase, with the verify script's
  exit code as the loop condition. Verification: verify-script + `verifier` (always). Code review:
  **`code-reviewer`** — mandatory at Large. Commits: `git-master` (6 logical commits across 2 repos).
- **Do not single-shot this.** The over-claim failure mode is structurally prevented only by
  ralph + verify-script-as-exit. Phase A2 still depends on another plan's unwritten **types** (§11.1 PM1)
  — though r2's D13 downgrades that from a file-level dependency to a compile-time one.
- **Re-read 2732's merged PR before A2's TDD gate writes a single test** (R5, §11.0, and §3's blocking
  banner). Its §12 changelog shows P2.5 flipped and reverted the same day, and P2.7(c) gaining an
  implementable predicate only on 2026-08-06. Every contract in §3 is on unwritten code.
- **Send §10.3 to 2732's author** as a standalone note. **Two matter most: C4** — 2732 §0.2 row 45, the
  row that scopes this entire ticket, has both the wrong path and the wrong line range — **and C10**,
  which is not a citation defect at all: 2732's front matter (`:114-119`) claims a tier-1 P2.7(c)
  exemption its own body reverted (`:792-795`), and 2732 §3.11.2 `:1605` mandates a picker whose filter offers
  **511 of 666** locations that `:722`'s validator then rejects. **2732's own Phase-2 picker is
  unimplementable as specified**, and 2643's §2.2 measurement is the first evidence of it.
- **Related tickets:** SBDEV-1938 (parent), SBDEV-2642 (v1 sibling, zero commits, superseded),
  SBDEV-2731 (MERGED — the display precedent and the wording constants), SBDEV-2732 (the blocking
  parent), SBDEV-2796 (bounds are advisory for receiving), SBDEV-2821 (pick-face receiving — the ticket
  D1's warning names), SBDEV-2863 (`Authority.IS_SB_ADMIN`), SBDEV-2217 (the dead IT lane).
- **Document history.** See **§15**. r1 2026-08-07 (initial draft); **r2 2026-08-07** (D1 reversed, plus
  the Architect lane's 7 MUST + 6 SHOULD changes). Repos read at `wms2-api` `6bc709a` / `wms2-web-ui`
  `4ce39a1`. DB measured SELECT-only on `wms2-hydra-dev2`. **Still open after r2: Q2, Q10, Q11**
  (Q5 → D12, Q6 → D14). **The decision most in need of requester confirmation is no longer D1 itself —
  it is §3.8.2a's banner wording**, because that is the sentence Scott Dalton reads when the ICE PACK
  location is not in the list.
