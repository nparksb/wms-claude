---
title: "SBDEV-2732 — Configurable System & Merchant Default Putaway Location Hierarchy (v2)"
ticket: "SBDEV-2732"
ticket_url: "https://app.clickup.com/t/868kgfzt9"
type: feature
priority: high
status: "MERGED (Phase 1-API) 2026-08-11 — wms2-api PR #139 into develop, merge commit 889298d, review-round commit 0837289. V2.2.13 is on develop. ClickUp moved to `on dev`. Merged develop re-verified: 4824 tests / 2 pre-existing failures, verify PHASE=1 209 pass 0 fail. PHASE 2 NOT STARTED — every UI acceptance criterion is still open, so the feature is API-reachable only and ships inert (sysprop seeded blank). Do NOT archive until Phase 2 lands. §​3.11 REWRITTEN 2026-08-11 (r-next) against the merged code: Step 19 was unimplementable (`/location/detailView` carries none of the predicate columns), so PHASE 2 NOW CARRIES API WORK — new step 18a: a pure `PutawayDestinationRules` evaluator, `GET /putawayConfig/eligibleLocations` (bulk, 5 queries), and 4 more `BlockingReason` values. Q2 closed; SBDEV-2643's row 0b + 0d satisfied. STEP 18a PARTIALLY IMPLEMENTED 2026-08-11 — deliverable 4 (BlockingReason +4 values, all 7 rejection keys mapped) is in wms2-api PR #141 (branch feature/SBDEV-2732-phase2-eligible-locations, commit 5e4aacc), NOT merged. Deliverables 1+2 (PutawayDestinationRules extraction + validator facade) are HELD pending an independent review lane. Deliverable 3 (eligibleLocations) is BLOCKED on deliverable 1 — it reduces to per-row validate() (~16,400 queries/request) or a second copy of P2, both forbidden by §3.11.0.1; its 5 gate tests are written and @Disabled. STEPS C AND D MERGED 2026-08-11 — PR #145 (merge 5a6d517, the PutawayDestinationRules extraction, mutation-verified) and PR #144 (merge 27845cd, the ~8,800-query N+1 fixed WITHOUT step C). ⚠ Step C was reported as `PHASE=1 220 pass / 0 fail` in its commit message, PR body and ClickUp comment; the run was actually 220/6 — six `V-*` rows still grepped the validator for predicates the step moved into the new evaluator. Rows repointed and negative-tested; merged develop reads `PHASE=1` 226 pass / 0 fail, `PHASE=all` 240 pass / 6 fail — and the 6 are exactly the `U-*` wms2-web-ui rows for steps 19-22, i.e. the whole remaining gap is the UI half. ALL THREE REVIEW FOLLOW-UPS MERGED 2026-08-11 — wms2-web-ui #46 (merge aac55d4, the logout blob-clear across all THREE exits), wms2-api #146 (merge 0517c94, the corrected javadoc plus 5 re-armed tests), wms2-mobile-ui #31 (merge 2e5a995, the same logout clear; most of SBDEV-2732 does NOT apply to mobile). Merged develop re-verified per repo: web 216 Jest / 0 fail, mobile 39 / 0 fail, api 38 targeted / 0 fail / 0 skipped, zero false-claim phrases left; PHASE=all 283 pass / 1 fail and the 1 is U-source (step 19a). Three DEV deploys fired. SBDEV-2930 filed for the mobile per-page reset gap, which #31 does NOT close. ⚠ THE sb_admin GATE QUESTION IS NOW CLOSED STATICALLY, no live-session check needed: `sb_admin` is carried in the JWT via the Keycloak GROUP, i.e. the `groups` claim (confirmed with the user 2026-08-11), and both the API's `extractRoles` (`GROUP_ELEMENT_IN_JWT = "groups"`, harvested at :98) and `util/keycloakRoles.js` read that claim. **AND THAT SHARPENS H1b FROM "NARROWER THAN THE BACKEND" TO "WOULD NEVER HAVE WORKED AT ALL"** — group membership does not appear under `resource_access`, so the original `hasResourceRole('sb_admin', clientId)` returned false for 100% of real sb_admins on every tenant regardless of KEYCLOAK_CLIENT, permanently. STEP 19a IS BUILT 2026-08-11 — wms2-web-ui #47 (merge 83c6e97) + wms2-api #147 (merge 509be61), merged in that order 2026-08-11; copy = variant A chosen by Nam and moved out of a hardcoded controller literal into messages.properties, so a product revision is a properties edit. **verify PHASE=all 285 pass / 0 fail — the whole script green for the first time.** **EVERY STEP OF BOTH PHASES IS NOW BUILT AND MERGED. verify PHASE=all 285 pass / 0 fail against merged develop in both repos, zero stderr.** The plan is complete bar an optional product read of the diversion wording (a one-line properties edit) and the SBDEV-2930 mobile follow-up, which is a separate ticket. READY TO ARCHIVE once someone confirms the wording. REVIEW ROUND DONE 2026-08-11 on PRs #42-#45 (three independent lanes): conformance PASS, but 2 High + 4 Medium defects in shipped behaviour, ALL FIXED in the tip commit — the permission gate locked out real sb_admins (a non-reactive computed, AND narrower than the API's own role harvesting), one shipper's unsaved selection was written against the NEXT shipper, every 409/422 message was discarded, a second Save 409'd, 'Save anyway' double-submitted, and a truncated location read was reported as an empty facility. Also excluded a PLAINTEXT CUPS credential from localStorage. 207 tests, 16/16 review mutations caught, 10 RV-* rows negative-tested, PHASE=2 65/1. ALL FOUR PHASE-2 UI PRs MERGED TO DEVELOP 2026-08-11, base-first — #42 (merge 9edb743), #43 (ec01dd7), #44 (536ac2b), #45 (bb6fd22); every branch verified an ancestor of develop, no orphans. Review fixes were REDISTRIBUTED onto their owning branches first (step 20 `1f2e4a1`, step 21 `fa7a256`, step 22 `74164cd`) so each merge was safe on its own — the gate fix landed WITH #43, not after it. Merged develop re-verified: 208 Jest tests / 0 failures, PHASE=1 226/0, PHASE=2 65/1, PHASE=all 283 pass / 1 fail — and the single fail is U-source, i.e. step 19a. Four Docker Image CI runs fired, so this is deploying to DEV. **PHASE 2 IS NOW COMPLETE EXCEPT STEP 19a**, which is blocked on PRODUCT SIGN-OFF for its diversion copy, not on code. STEP 22 DONE 2026-08-11 — wms2-web-ui PR #45 (`0e88b1c`, open, STACKED on #44): config health for invalid EXISTING configs + the persistedState exclusion, 18 tests, 15/15 mutations caught. **verify PHASE=2 is now 55 pass / 1 fail and the 1 is step 19a — the ONLY Phase 2 item left, and it is blocked on PRODUCT SIGN-OFF for its diversion copy, not on code.** MERGE ORDER: #42 -> #43 -> #44 -> #45. STEP 21 DONE 2026-08-11 — wms2-web-ui PR #44 (`f5f3e44`, open, STACKED on #43): the merchant tier, 22 tests, 15/15 mutations caught, verify PHASE=2 49 pass / 2 fail (only steps 19a and 22 remain). ⚠ §3.11.3 named the WRONG read source — `/client/detailView` does not carry the column — and has been CORRECTED in place; this plan has now twice assumed a detailView carries a column it does not. MERGE ORDER: #42 -> #43 -> #44. STEP 20 DONE 2026-08-11 — wms2-web-ui PR #43 (`cf2ced2`, open, STACKED on #42; merge #42 first): the warehouse tier is settable from the UI through the TYPED endpoint, 33 tests, 16/16 mutations caught, verify PHASE=2 43 pass / 3 fail (the 3 are steps 19a/21/22). ⚠ §11.1a named SEVEN UI acceptance rows that did not exist in the verify script; steps 19/20 closed five, and one of them (`U-neg-flags-in-js`) is UNSATISFIABLE as worded — 8 existing master-data files legitimately display those columns — so it is implemented scoped to the putaway surfaces. STEP 19 DONE 2026-08-11 — wms2-web-ui PR #42 (`91d500e`, open), the tiered LocationPicker: 17 tests, 12/12 mutations caught, verify PHASE=2 33 pass / 4 fail (the 4 are steps 20/21/22). Ships INERT — no page references it yet. STEPS 4, A and B ALL MERGED TO DEVELOP 2026-08-11 — PR #143 (merge a8129c7, the validator characterization guard), PR #141 (merge 913f017, BlockingReason +4 values and the enum moved to the service layer), PR #142 (merge 41c8257, the paginated eligibleLocations read). Verify against merged develop: PHASE=1 214/0, PHASE=all 228 pass / 6 fail — the 6 are all U-* rows for the wms2-web-ui steps 19-22, which #142 exists to unblock. Three Docker Image CI runs fired on push to develop, so this is deployed to DEV. STEP C (the extraction) is unblocked and has a real guard; STEP D (summariseScope's ~8,800-query N+1) remains unowned. STEP 18a RESEQUENCED 2026-08-11 after an independent design-review lane (critic SOUND-WITH-CHANGES + architect): the extraction is NO LONGER a prerequisite of the read. §3.11.0 now specifies four ordered steps -- A: ship the eligibleLocations read PAGINATED with per-row validate() behind PutawayDestinationQueryService, which unblocks steps 19-22 and SBDEV-2643 B2 with ZERO changes to live validation code; B: write PutawayDestinationValidatorUnitTest against the MERGED validator (it has NEVER existed -- the plan wrongly named it as the guard three times) and merge it alone; C: then extract PutawayDestinationRules as a zero-dependency @Service pinned by ArchUnit; D: re-point summariseScope/countIncompatible, where the real measured problem is (~8,800 queries on a live ungated GET /preview). ClickUp stays `on dev` (Phase 1's state; PR #141 does not regress it)."
approval_note: >
  APPROVED 2026-08-09 by the ticket owner (Nam Park), on the instruction to run wms-tdd-gate.
  IMPLEMENTED 2026-08-10 — Phase 1-API only. wms2-api PR #139
  (https://github.com/SiteBossInc/wms2-api/pull/139) into develop, branch
  feature/SBDEV-2732-putaway-destination-hierarchy, 22 commits off origin/develop fd90487.
  Suite 4819 tests / 2 failures, both pre-existing (OptionalSafetyArchTest at its frozen baseline of
  8 violations, none in a touched class; MobilePalletizingServiceTest). verify-SBDEV-2732 PHASE=1:
  209 pass, 0 fail, negative-controlled against a detached worktree at origin/develop.
  REVIEW ROUND 2026-08-11 (Codex on PR #139, 3 findings, all accepted and fixed): the HAL sysprop
  DELETE had no sb_admin gate (P1); the HAL path skipped P2.6 at tiers 2/3 (P2a); the typed writers
  recomputed and wrote in separate transactions (P2b). 12 tests + 9 verify rows added, each
  negative-controlled. See Sec 12.
  Migration is V2.2.13 (V2.2.11 was taken by PR #138 and V2.2.12 is also taken).
  Phase 2 (web UI) NOT started. NOT merged, NOT deployed, NOT archived.
  Basis: Q12 -> (iv-b) closed on the owner's decision; SBDEV-2821 merged (gate 3); and two review
  passes -- the three (iv-b) decisions (independent, sound-with-changes) and the sections D18 left
  unreviewed (2026-08-09, sound-with-changes, F-1..F-4 fixed; see Sec 12).
  SCOPE OF THE APPROVAL, stated so it is not over-read:
    - The second review pass was run by the same agent that had authored edits earlier in that
      session. It is NOT an independent pass in the sense D18 originally intended.
    - Sec 3.9 (Spring Data REST write hole), 3.10 (cache coherence), 3.11 (Phase-2 picker),
      3.13 (metrics), 6 (backward compatibility) and 7.6 (horizontal scalability) remain
      UNREVIEWED. None is in the Sec 7.1 test set the TDD gate writes, so the gate is not blocked
      on them -- but they must be reviewed before the Phase 1-API PR merges.
    - The "12 Critic findings" gate was retired as undischargeable (see the banner), not satisfied.
project: [wms2]
version: v2
db_verified: true
depends_on:
  # Pinned 2026-08-06. Re-verify every claim about these tickets if a sha moves — this plan
  # previously asserted four things about SBDEV-2731 that were true of its PLAN and false of its CODE.
  - {ticket: SBDEV-2731, sha: 6bc709a}    # MERGED 2026-08-07 — PR #133 api @ 6bc709a, #39 ui @ 4ce39a1.
                                          # Prerequisite 0 SATISFIED. Claims about it re-verified same day.
  - {ticket: SBDEV-2854, sha: 68274b0}    # MERGED 2026-08-07 (PR #132). Its V2.2.10 is on develop, but
                                          # must still be APPLIED per tenant BEFORE this plan's V2.2.13.
  - {ticket: SBDEV-2863, sha: 675b4a1}    # MERGED 2026-08-07 (PR #134, merge 7d9d38e). NOT a blocker —
                                          # recorded because it silently REMOVED one: Authority.IS_SB_ADMIN
                                          # named a non-existent SpEL method until this landed, so all six
                                          # of this plan's @PreAuthorize sites would have returned HTTP 500
                                          # to everyone. Now renders hasAuthority('sb_admin'). KEEP the
                                          # constant as written; see the warning box in Sec 3.12.
  - {ticket: SBDEV-2821, sha: fd90487}    # MERGED 2026-08-09 (PR #135, feature commit cfb6d49). Gate 3
                                          # CLEARED. Was `UNMERGED` until 2026-08-09.
                                          # ADDED 2026-08-08 (Q15 -> (A)). NEW dependency, and it REVERSES
                                          # the order §8.4 previously stated. Under Q12 -> (iv-b) step 15
                                          # diverts pick-face destinations to the putaway lane; 2821 is
                                          # what makes them OFFERABLE at putaway. Ship 2821 first, then
                                          # extend its candidate surfacing to all four tiers (step 17a).
db_verified_tenants:
  fresh_seed: [wh01_hydra_v2t]
  migrated:   [wh01_hydra_v2, wsl-wineco-uat, wms2-hydra]   # a fresh-seed-only sample cannot exhibit
                                                            # migrated-tenant hazards — see §3.4c P2.7(c)
requester: "David Oppenheim"
created: 2026-07-31
updated: 2026-08-09
related:
  - SBDEV-1938
  - SBDEV-2642
  - SBDEV-2643
  - SBDEV-2731
  - SBDEV-2217
  - SBDEV-2037
  - SBDEV-2102
  - SBDEV-2232
tags:
  - plan
---

# SBDEV-2732 — Configurable System & Merchant Default Putaway Location Hierarchy (v2)

**Ticket:** [SBDEV-2732](https://app.clickup.com/t/868kgfzt9)
**Project:** wms2 | **Version:** v2 | **Type:** feature
**Priority:** high
**Status:** **approved 2026-08-09** — cleared for `wms-tdd-gate`. No source file under `v2/wms2-api/` or `v2/wms2-web-ui/` has been touched yet. See `approval_note` in the frontmatter for what the approval does **not** cover (§3.9, §3.10, §3.11, §3.13, §6, §7.6 remain unreviewed and must be before the Phase 1-API PR merges).
**Date:** 2026-07-31 · **Updated:** 2026-08-08 · **Design changelog:** §12
**Ships AFTER [SBDEV-2821](https://app.clickup.com/t/868km8j9z)** — order reversed 2026-08-08 by Q15 → (A); see §8.4

> ## 🔔 REVISION 2026-08-04 — SBDEV-2796 / Q5 ANSWERED: option (c). READ BEFORE ANY OTHER SECTION.
>
> The B/A answered [SBDEV-2796](https://app.clickup.com/t/868kk4rmv) (= SBDEV-2731 Q5 = this plan's §10.4
> **Q10**) with **(c): "It is valid and bounds are advisory for receiving."** Not the carried-over
> recommendation (d). Direct placement into a pick face is legitimate, `FixLocationAssignment.upperbound`
> is **not** enforced at receive time, and the over-bound state is accepted and documented.
>
> **(c) is the answer that maximises this plan's scope** — so on 2026-08-04 the author elected to **DEFER
> the tier-1 path** rather than absorb it. See the four decisions below.
>
> ---
>
> ### DECISIONS TAKEN 2026-08-04 (author) — these define the implementable scope
>
> **D15 — tier-1 direct placement is DEFERRED to a follow-up ticket.** ⚠ **RESTATED 2026-08-08: it is not merely deferred, it is CANCELLED.** SBDEV-2821 adopted **option (iii) — route at putaway**, so tier-1 pick-face destinations are *never* directly placed by anyone. The guarantee D15 wanted still holds; what changes is the enforcement point, which moves from refusing the configuration to a runtime rule in receiving (see the conflict box under §3.4c P2.7(c)). Original text follows. This plan ships the resolver (all
> four tiers' *resolution*), the merchant/warehouse config surface, the display endpoint, write-time
> validation, the audit table and the backfill — plus direct placement **for non-pick-face destinations at any tier** *(⚠ 2026-08-08: was "for tiers 2/3 only" — Q12 → iv-b splits on the destination, not the tier)*. Placing a
> receipt onto a **pick face** is out of scope here **at every tier** — step 15 diverts it to the lane and putaway routes it.
>
> *What the deferral removes from this plan, all of it previously blocking:* 2731's **Fix B** (flowbin
> classification + resident-UL resolution), **C2b**, **Q1**, **Q4**, **F1**, **F4**, **F5**, and **Q11**
> (replenishment against a permanently over-bound bin — still needs a B/A answer). **All of it now owned by
> [SBDEV-2821](https://app.clickup.com/t/868km8j9z)** (filed 2026-08-04). **Q1/Q4 here mean
> *2731's* Q1/Q4, not this plan's own §10.4 Q1/Q4, which remain open and in scope.** None of those
> can arise without pick-face placement: no repointing ⇒ no C2b; no over-bound bin ⇒ no Q11.
> **Consequence: this plan no longer waits on anything unowned.**
>
> [!done] **Flyway version RENUMBERED to `V2.2.11` (2026-08-06) — `V2.2.10` went to SBDEV-2854**
> ⚠ **This banner records the 2026-08-06 event. The file is now `V2.2.13` — renumbered AGAIN on
> 2026-08-10; see §12's top entry. Do not read the numbers below as current.**
> **SBDEV-2854** occupies `V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop.sql` on branch
> `bugfix/SBDEV-2854-replenish-non-flowbin-destination`, shipped in **PR #132 — open and pushed**. It
> originally took `V2.2.11` and left `V2.2.10` reserved for this plan, but that gap is **unsafe**: there
> is no `outOfOrder(true)` and no `validateOnMigrate(false)` anywhere, and `StartupFlywayMigrator` catches
> `FlywayException`, logs and **continues** — so a tenant that applied the higher number before this
> plan's lower one landed would boot normally and silently stop receiving that and every later migration
> until someone read the log or ran `flyway repair`. SBDEV-2854 is an urgent client fix and deploys
> first, so it took the contiguous number; its own §5.1 **H3** records the consequence directly —
> *"SBDEV-2732 must now take a later version"*.
> **This plan then took `V2.2.11`, renumbered throughout on 2026-08-06.** Flyway head on `origin/develop`
> is still `V2.2.09`; `V2.2.10` is held by an open PR and is therefore invisible to
> `ls src/main/resources/db/migration/` on `develop`. **Re-sweep every remote branch for the next free
> version immediately before the PR** — that sweep is what caught this collision, and D16 below still
> mandates it.
>
> **D16 — one migration, `V2.2.13`.** §2.9 originally reserved *two* versions and wrote both as `V2.2.08`;
> §5.2 had already removed that split. Resolved as **one** file,
> `V2.2.13__putaway_destination_hierarchy.sql`. Renumbered **three times**: `V2.2.08` → `V2.2.10` on
> 2026-08-04 because `V2.2.08` (SBDEV-2801) and `V2.2.09` (SBDEV-2778) both merged that day; `V2.2.10`
> → `V2.2.11` on 2026-08-06 when SBDEV-2854 took `V2.2.10` (banner above); and `V2.2.11` → `V2.2.13`
> on 2026-08-10 when PR #138 claimed `V2.2.11` and a third branch already held `V2.2.12`. **Re-sweep
> every remote branch for the next free version immediately before the PR** — unmerged branches hold
> invisible versions, which is exactly how all three collisions happened. That sweep is now a script:
> `db/check-migration-version-collision.sh` (SBDEV-2916).
>
> **D17 — the §6 receipt-correction guard STAYS, and correction is documented as unavailable for
> directly-placed receipts.** Not relaxed. Relaxing it is only safe once C2b is fixed, and C2b is now
> deferred with the tier-1 path — so the guard is the option that cannot nirvana a location. Note this
> decision is required **even with tier 1 deferred**, because D13 rule (d) lets tiers 2/3 target staging
> lanes whose areas are not `useforgoodsin`.
>
> **D18 — the plan goes through a review lane before approval.** Status stays `draft`. The 2026-08-04
> revisions changed validator predicate semantics (P2.5, P2.7(c)) and have had no independent pass; the
> previous Critic pass returned 12 findings including a CRITICAL one. Review → address → approve →
> `wms-tdd-gate` → implement.
>
> **⚠ SUBSTANTIALLY DISCHARGED 2026-08-09 — status STAYS `draft` pending sign-off.** Two passes have now run:
>
> 1. **The three (iv-b) decisions** (P2.7 rule (e), the P1 skip, SBDEV-2643's D1 revert) — independent
>    pass, **sound-with-changes**, all three corrections folded in and recorded in §12.
> 2. **The remaining sections** (resolver §3.1, audit table §3.14, `V2.2.13` §5.1, D11/P2.6) — reviewed
>    2026-08-09, **sound-with-changes**, four defects found and fixed (F-1…F-4, §12). Verified sound in
>    that pass: the `ReceivingService` citations, `application.properties:55/:70`,
>    `LocationRepository.findByName`, the zero-`@Transactional`-in-`controller/` premise behind §3.1.5,
>    and the `putaway_config_audit` DDL against `V2.2.13`'s pre-image INSERT (every `NOT NULL` supplied;
>    `version` / `previous_value_unavailable` covered by defaults).
>
> **⚠ THE "12 CRITIC FINDINGS" GATE IS RETIRED AS UNDISCHARGEABLE.** It cannot be met as written: the 12
> are **not enumerated anywhere in this plan**, and this repo's history for the file begins 2026-08-07 —
> *after* the Critic passes that produced them. There is nothing to re-check against. The 2026-08-09 pass
> above replaces it. Recorded rather than quietly dropped, because an obligation nobody can close reads
> like outstanding work forever.
>
> **Still NOT reviewed, and named so the gap is explicit:** §3.9 (Spring Data REST write hole), §3.10
> (cache coherence), §3.11 (Phase-2 picker, Vue), §3.13 (metrics), §6 (backward compatibility), §7.6
> (horizontal scalability), and the `V2.2.13` SQL beyond column consistency and statement ordering.
>
> **Remaining gates before `wms-tdd-gate` can run — ONE, down from three:**
> 1. **This plan reviewed end-to-end and flipped off `draft`.** Still outstanding.
> 2. ~~Q12 → (iv-b) signed off~~ — ✅ **CLOSED 2026-08-09 by the ticket owner.** **(iv-b) is the
>    decision**, reaffirmed by @Nam Park on 2026-08-09, and §7.1's tests derive from it as written.
>    It was put to @David Oppenheim and @Brent Campbell on 2026-08-08 with no reply recorded — **that
>    is an outstanding notification, not an outstanding gate**, and it does not hold the TDD gate.
>    **Precedent, same family, same week:** SBDEV-2821's Q4 (route-at-putaway) was adopted on David's
>    endorsement plus the ticket owner's direction, with Brent never replying to the hand-off — and it
>    shipped and merged. (iv-b) is the *same design decision* one tier wider. If either objects later,
>    Q12 reopens and (i)–(iii)/(iv-a) return to the table; until then it is settled.
> 3. ~~SBDEV-2821 merged~~ — ✅ **CLEARED 2026-08-09.** `wms2-api` **PR #135 merged to `develop`** (merge
>    `fd90487`, feature commit `cfb6d49`); ClickUp `on dev`. Step 17a's foundation — putaway candidate
>    surfacing — is now on `develop`, together with §3.2a's `cases and pallets` handling in **both** type
>    switches.
>
> Running the gate before (1) writes tests against text that the review can still change — and gate tests
> are a contract the executor may not weaken, so a wrong one is worse than none. **(2) is no longer part
> of that risk:** the design is fixed by owner decision, so §7.1 can be written against it today.
>
> ---
>
> **Lifted by (c).** The tier-1 direct-placement *block* is gone — but under **D15** the tier-1 path is
> deferred anyway, so this matters only to the follow-up ticket. (The block was written as "blocks Phase
> 1b"; that split was removed in §5.2 and direct placement sits in **Phase 1-API**.)
>
> **Still corrected here, because it is a live defect either way:** **P2.5** and **P2.7(c)** rejected
> pick-face / fix-assigned destinations *"absolutely at all three scopes"* while §3.4c exempted tier 1 from
> only (a), (b) and (d) — **not (c)**. A flowbin *is* a pick face, so the ICE PACK configuration could not
> have been saved at **any** scope, which made (c) unimplementable and made this plan's own predicted
> "silent ~12× over-bound bin" unreachable. Both are revised below (P2.5 scope-dependent; tier 1 exempt
> from P2.7(c)) so the follow-up ticket inherits a validator that admits the configuration (c) authorises.
>
> **Hard prerequisite, unchanged and NOT yet met:** **D12** requires SBDEV-2731 PR1 merged to `develop`
> first. As of 2026-08-04 that work is committed in both repos but **never pushed and has no PR**, and this
> plan's resolver consumes the neutral message key `unitloadTypeNotPermittedOnLocation` that PR1
> introduces — so merging this plan first would reference a message that does not exist. Order is fixed:
> 2731 API → 2731 UI → this plan. Do **not** branch this plan off the 2731 branch (stacked-PR orphan trap).

**Parent:** SBDEV-1938 "WMSv2 — Receive to Different Location Other then Putaway" (Open)
**Absorbs:** SBDEV-2731 (per D8/D9 — its slice is **Phase 1**, separately mergeable). **Unblocks:** SBDEV-2643.
**db_verified:** true — evidence from `wh01_hydra_v2` (v1→v2 migrated copy) and `wh01_hydra_v2t` (fresh-seeded copy), MCPs `wms2-hydra-dev2` / `wms2-hydra-v2t`.

> **Phases — SUPERSEDED, see §5.2 and §8.1.** This paragraph described the old **four-merge** `1a`/`1b` split; §5.2 collapsed it to **two merges — Phase 1-API then Phase 2-UI** — and D16 collapsed the two migrations into one `V2.2.13`. **Both of its gating claims are also false:** `V2.2.13` *does* add a column an entity maps (`client.defaultputawaylocation_id`), and `ddl-auto` is **`none`**, not `validate` (`application.properties:70`; `:69` has `validate` commented out) — so nothing validates the schema at startup and there is no "exempt from the operator gate" half. Read **§8.1** for the real merge order and gate. *(Kept only so a reader who remembers the 1a/1b vocabulary knows where it went; every `1a`/`1b` label still surviving in §0 and §4 is stale — treat every API row as Phase 1-API.)*
>
> **Read §5.2 O1–O5 before starting any phase.** Three things whose phase is counter-intuitive: the audit *writer* (O1 — the table ships in 1a so the backfill pre-image has somewhere to land, but the entity, service and audit rows are 1b), `onClient` in the event handler (O2 — 1b; written in 1a it will not compile), and stop-seeding the lane id (O3 — 1a, and it must travel in the **same commit** as `V2.2.13`).

---

## 0. Affected Sites

Enumerated against disk on 2026-07-31 (not from memory). Every **in-scope** row is visited by a §3 sub-section or a §5 phase step; every **out-of-scope** row carries a one-line rationale. **Phase** column per D9: `1a` = API + `V2.2.13`, `1b` = API + `V2.2.13`, `2` = web UI.

### 0.1 API — `v2/wms2-api/src/main/java/net/aim_ai/wms/`

| # | File:line | Construct | Verdict | Phase | §3 / rationale |
|---|---|---|---|---|---|
| 1 | `service/ReceivingService.java:454-457` | `carrier == null ? findById(itemdata.getPutawaylocationId()) : null` | **in — replace** | 1a | §3.7 |
| 2 | `service/ReceivingService.java:491-495` | placement fork; carrier branch never consults the destination (**SBDEV-2731 root cause**) | **in — rework** | 1a | §3.7 |
| 3 | `service/ReceivingService.java:601-612` | name-equality check against `PutAwayLane` for inbound-pallet assign | **in — audit, must not break when destination ≠ lane** | 1a | §3.7.3 |
| 4 | `service/ReceivingService.java:634-637` | unassign inbound pallet → `findByName(PutAwayLane)` | **in — audit, unchanged** | 1a | §3.7.3 |
| 5 | `service/mobile/MobilePutAwayService.java:113-117` | `if (!locationArea.getUseforgoodsin() && !storageLocation.equals(Clearing)) throw BusinessException("unitloadNotInInboundArea")` — the **first** guard in the method | **in — audit; THIS is the exception a storage-area direct placement actually hits** | 1b | §3.7.4, §6 |
| 5a | `service/mobile/MobilePutAwayService.java:121-128` | requires the UL to be on `PutAwayLane`, else `unitLoadNotInPutAwayLane` — runs **after** row 5, so a unit load sitting in a storage area never reaches it | **in — audit, unchanged; NOT the exception a direct placement produces** | 1b | §3.7.4 |
| 6 | `service/mobile/MobilePutAwayService.java:190-206` | `storePalletBackOnPutawayLane` (SBDEV-2102 fix) | **in — audit, must not regress** | 1b | §3.7.4 |
| 7 | `service/mobile/MobileMoveUnitloadService.java:362-366` | creates inbound pallet at putaway lane by name | **in — audit, unchanged** | 1b | §3.7.4 |
| 8 | `controller/rest/SkuRestController.java:85-88, 144-146` | create path seeds `putawaylocation_id` = PutAwayLane id | **in — stop seeding; same commit as `V2.2.13`** | **1a** | §3.2, **O3** |
| 9 | `controller/rest/SkuRestController.java:198-201, 257-259` | update path, same | **in — stop seeding; same commit as `V2.2.13`** | **1a** | §3.2, **O3** |
| 10 | `service/SkuBatchCreateUpdateService.java:36, 53` | `itemData.setPutawaylocationId(defaultPutawayLocationId)` | **in — parameter removed; same commit as `V2.2.13`** | **1a** | §3.2, **O3** |
| 11 | `controller/FileImportController.java:355-359, 383` | CSV import seeds the lane id; `:355` guard is the SBDEV-2037 fix | **in — stop seeding, keep an equivalent guard; same commit as `V2.2.13`** | **1a** | §3.2, **O3** |
| 12 | `model/Itemdata.java:49-51` | `@NotNull @Column(name="putawaylocation_id") private Long putawaylocationId` | **in — drop `@NotNull`; same commit as `V2.2.13`** | 1a | §3.2 |
| 13 | `service/ItemdataService.java:62-76` | `setPutAwayLocation` — dead (0 production callers) but has the **correct** targeted 2-key `@CacheEvict` | **in — promote to the single validated writer** | 1a | §3.5 |
| 13a | `service/ItemdataService.java:47-50` | `getById` is **`@Cacheable`**, and `ItemDataController:89-90` mutates the returned instance **in place** | **in — writers MUST use `itemdataRepository.findById`, never this** | 1a | §3.5 |
| 14 | `controller/ItemDataController.java:80-95` | `@CacheEvict(allEntries=true)` + `@GetMapping` that mutates + **raw save, zero validation**, and **no `@PreAuthorize` today** | **in — route through §3.5, fix the evict; adding authz is a back-compat change** | 1a | §3.5, §3.12, §6 |
| 15 | `service/UnitloadBusinessService.java:188-237` | constraint allow-list + raw-ID `BusinessException` at `:191` — **also serves 21 non-receiving call sites** | **in — extract predicate; `:191` gets the NEUTRAL key `unitloadTypeNotPermittedOnLocation`, the putaway-specific key is thrown by the resolver** | 1a | §3.4b, §3.6.1 |
| 16 | `repo/jpa/LocationConstraintRepository.java:16-17` | only `findByStoragelocationtypeId` | **in — reused as-is, no new method** | 1a | §3.4b (rationale below) |
| 17 | `service/LocationConstraintService.java:27-39` | only `createEntity` | **in — home of the new predicate** | 1a | §3.4b |
| 18 | `model/Client.java:10-22` | tenant-PU entity carrying per-facility config | **in — new nullable FK field** | 1b | §3.3 |
| 19 | `repo/jpa/SyspropRepository.java:35-36` | `findBySyskeyAndClientIdAndWorkstation` → `Optional<Sysprop>`, uniquely keyed on the real constraint `(client_id, syskey, workstation)` | **in — THE tier-3 read path** | 1a | §3.4a |
| 19a | `repo/jpa/SyspropRepository.java:46-48` | `findSysvalueByClientIdAndSyskey` — **no `workstation` predicate**; `order by client_id` is a no-op when `client_id` is fixed ⇒ arbitrary row | **in — deliberately NOT used; landmine A6** | 1a | §3.4a |
| 20 | `service/SyspropService.java:164-234` | `getStringDefault` 4-tier cascade, **INSERTs on total miss at `:234`** | **in — deliberately NOT used** | 1a | §3.4a, §9 A4 |
| 21 | `controller/rest/AdviceRestController.java:572` `createHubAndSpoke` | `:684` `position.setItemdataId(null)`, `:685` sets `unitloadtypeId` | **in — null-SKU contract, reachable from the DISPLAY endpoint only** | 1a | §3.1.4 |
| 21a | `service/ReceivingService.java:356-357` | `itemdataRepository.findById(adviceposition.getItemdataId())` — `findById(null)` raises `InvalidDataAccessApiUsageException` **96 lines before** the resolver | **out — pre-existing hub-and-spoke *receive* gap, NOT fixed here** | — | §10 Q4 |
| 22 | `controller/rest/AdviceRestController.java:139` `create` (REGULAR/RETURN) | `:396` sets `unitloadtypeId` | **in — optional early-validate hook** | 1b | §3.9 |
| 23 | `controller/rest/AdviceRestController.java:453` `createTransfer` | `:527` sets `unitloadtypeId` | **in — same** | 1b | §3.9 |
| 24 | `controller/FileImportController.java:489` | `position.setUnitloadtypeId(...)` (inbound-BOL import) | **in — same** | 1b | §3.9 |
| 25 | `service/AdviceService.java:145` `acceptHubAndSpokeAdvice` | materialises `Unitload` **without** `receiveGoods` | **out** — no `Itemdata`, no receipt destination decision; auto-accept plumbing. §10 Q4. |
| 26 | `controller/ReceivingController.java:285-300` | catch ladder; `:298-300` swallows `RuntimeException` into "contact support" | **in — resolver failures must be `BusinessException`** | 1a | §3.6.2 |
| 26a | `controller/**` (whole tree) | **ZERO `@Transactional`** — the only 3 matches are comments, two of which state the controller has no transaction | **in — a `MANDATORY` call from a controller throws `IllegalTransactionStateException`, a bare `RuntimeException`** | 1a | §3.1.5, §3.8 |
| 27 | `controller/ReceivingController.java:314` | hard-coded `{"PutAwayLane","InboundWorkstation","EmptyPallets"}` raw literals | **in — replace literals with constants** | 1a | §3.7.3 |
| 28 | `model/ReceivingDtoView.java:47, 173` | `defaultputawaylocationname` — already projected by `receiving_dto_view` (`V2.2.00__base_v2_schema.sql:4663, 4676`) | **in — read-only reuse, view NOT changed** | 1a | §3.8 (D9) |
| 29 | `model/ReceivedDtoView.java` | sibling projection for `/reports/receiving-report` | **out** — historical report of what was received; the *destination actually used* is already in `UnitloadRecord`. No new column. |
| 29a | `service/GoodsReceiptPositionService.java:151-152` | goods-in **area guard** immediately before `deletePosition`, reached from `delete` (`:98`) and `adjust` (`:124`); `deletePosition` then calls `sendStockUnitToNirvana` (`:165`) and, when nothing remains, `sendToNirvana` (`:171`) | **in — N-22.** Cannot fire today because receiving's destination is always the goods-in lane; **direct placement makes it throw**, so `delete`/`adjust` break for exactly the receipts this feature redirects, and the guard is the only thing between a correction and nirvana-ing a UL on a live storage face | 1 | §6, M21 |
| 29b | `controller/GoodsReceiptPositionController.java` | exposes `delete` and `adjust` | **in — N-22**, same cause | 1 | §6, M21 |
| 30 | `config/CacheConfig.java:31-69` | `sysprops` 2 min, `clients` 5 min, `locations` 5 min, `itemdata` 5 min **× two profiles** | **in — eviction + freshness contract, no file change** | 1a/1b | §3.10 |
| 31 | `RestConfiguration.java:34-48, 55-60` | `RepositoryDetectionStrategies.ANNOTATED`; only bean-validation validators ⇒ **`POST`, `PATCH` and `DELETE`** `/v3/{itemdata,client,sysprop}` write unvalidated | **in — the D7 write hole; `POST` matters as much as `PATCH`** | 1a (+`onClient` 1b) | §3.9 (O2) |
| 31a | `controller/SystemPropertyController.java:47-90` `POST /v3/systemProperty/create` | direct `syspropRepository.save()` at `:77` — **Spring Data REST publishes no event**, so the §3.9 handler never fires and the D7 guard is bypassed entirely | **in — must reject `syskey == DEFAULT_PUTAWAY_LOCATION`** | 1a | §3.9.1 |
| 31b | `controller/SystemPropertyController.java:93-120` `POST /v3/systemProperty/updateValue` | direct `syspropRepository.save()` at `:107`, reached via `findBySyskey(key).get(0)` — the client-blind shape of landmine A3, on a write | **in — must reject `syskey == DEFAULT_PUTAWAY_LOCATION`** | 1a | §3.9.1 |
| 31c | `DELETE /v3/sysprop/{id}` (SDR-exported, called by `store/admin/configuration.js:125-147`, axios at `:127`) | live "delete" button on the Operation Options dialog; the plan defines no delete handler, so the row can be removed unvalidated and unaudited | **in — accepted and audited, see D12** | 1a | §3.9.1 |
| 32 | `service/WmsConstants.java:771` | `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"` | **in — stays, becomes the tier-4 fallback only** | 1a | §3.4b |
| 32a | `service/WmsConstants.java:731, 1163` | `UNIT_LOAD_TYPE_BOX = "Case"`; `SystemProperty.WORKSTATION_DEFAULT = "DEFAULT"` (nested class `SystemProperty`) | **in — reused, not changed** | 1a | §3.4a, §3.4c |
| 33 | `service/mobile/MobilePutAwayService.java:217-305` `calculatePutAwayList` | classification via `LocationType.sltname`; area predicate | **in — audit only, no change** | 1b | §3.7.4 |
| 34 | `repo/jpa/LocationRepository.java:104-118` `getStorageLocationsForPutAwayItemData` *(⚠ re-derived 2026-08-11 — was `:104-120`. Javadoc `:104-110`, `@RestResource` `:111`, `@Query` `:112-117`, signature `:118`. The `...ForStockUnitItemData` sibling is now **`:183-190`**, not adjacent — SBDEV-2821 inserted `getPutAwayCandidateLocations` at `:120-180` between them. The merged javadoc at `:105-109` now states this query is **HAL-exported consumers only and no longer drives putaway**)* | native predicate `location_area.useforstorage='true'` — **can never return `PutAwayLane`** (L-PRE.10) | **out as a selector** — must NOT back the Phase-2 picker or the validator. §3.4c. |
| 34a | `repo/jpa/LocationRepository.java:21-22` | `findByName` → `Optional<Location>`, **no `client_id` filter**; `location.name` has **no unique constraint** (`V2.2.00…sql:959-979`, `name varchar(255) NOT NULL`) | **in — defines what tier 4 resolves; the backfill predicate MUST match it exactly** | 1a | §5.1 |
| 34b | `repo/jpa/LocationRepository.java:52` `findByIdForUpdate` | taken at `UnitloadBusinessService.java:158` + `entityManager.refresh` **before** the Unitload write at `:293-294` — Location→UL, **inverting** the SBDEV-2232 SU→UL→Location order | **in — accepted risk with a named detector; blast radius grows from "an inbound lane" to "any live storage/pick location"** | 1b | §7.6 #8, §8.2 |
| 35 | `controller/rest/UtilRestController.java:760` | provisioning/util lane lookup | **out** — provisioning tooling, no receipt path. |
| 36 | `service/ReportService.java:182` | `view.getDefaultputawaylocationname()` | **out** — read-only reporting column, unchanged semantics. |
| 38 | `repo/jpa/LocationRepository.java:37-47` `getAvailableStagingLanes` | **`@RestResource`-exported** JPQL: `WHERE l.staginglane = true AND NOT EXISTS (CustomerorderBatch ob WHERE ob.staginglaneId = l.id AND ob.id != :batchId AND ob.state < :state)` — **verified `origin/develop` 2026-08-04: there is NO stock or unit-load predicate.** A staging lane holding received inventory is still offered to the next club batch. | **in — audit, unchanged; see §6 N-23** | 1-API | §6 N-23 |
| 39 | `service/CustomerorderBatchService.java:895, 911` + `controller/ClubLineController.java:307` | consume row 38 and assign the chosen lane to a batch; `BillofladingService:732/:829` and `CustomerorderBatchService:382/:402/:713` clear it; truck loading ships what sits on the lane | **in — audit, unchanged; the consumer that makes a club-lane destination unsafe** | 1-API | §6 N-23 |
| 40 | `repo/jpa/StockunitRepository.java:198, 216` | `AND loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE` — **unconditional, no sysprop gate** (verified 2026-08-04); sysprop-gated siblings at `StockunitRepository:180/:233`, `ItemdataRepository:78/:119/:154`, `UnitloadRepository:148`, `FixLocationAssignmentRepository:64/:91` (SBDEV-1666) | **in — audit, unchanged; defines what a lane destination costs** | 1-API | §6 N-23 |
| 37 | `service/BoxtypeService.java:87` | `details.put("putawayLocation", ...)` | **out** — display detail map for box types, unrelated to precedence. |

### 0.1b NEW constructs this plan introduces (so §0 stays a complete inventory)

| # | New construct | Why it must exist | Phase | § |
|---|---|---|---|---|
| N1 | `service/PutawayDestinationResolver.java` | the one shared 4-tier resolver; `Propagation.MANDATORY` | 1a | §3.1 |
| N2 | `service/PutawayDestinationQueryService.java` | `readOnly = true` tenant-tx facade so **non-transactional controllers can reach the resolver at all** | 1a | §3.1.5, §3.8 |
| N3 | `LocationConstraintService.isUnitloadTypePermitted` | predicate P1, single source of truth incl. the empty-list fail-open | 1a | §3.4b |
| N4 | `service/PutawayDestinationValidator.java` | predicate P2 per scope + the D11 incompatible-SKU count | 1a | §3.4c |
| N5 | `service/PutawayConfigService.java` | validated + audited writers, cache eviction, `validateOnly` / `auditAndEvict` for the event handler, and **the authorization boundary** (§3.12) | 1a (SKU + sysprop) / 1b (merchant) | §3.5 |
| N6 | `service/PutawayResolutionMetrics.java` | 4 counters; the only detector for pre-mortems P2 and P3 | 1a | §3.13 |
| N7 | `config/PutawayConfigRepositoryEventHandler.java` | **⚠ PHASE COLUMN STALE — see §5.2 O2.** The `1a`/`1b` split was removed; there is only **Phase 1-API**, so `onItemdata`, `onSysprop` **and** `onClient` all ship together in the single API commit alongside `client.defaultputawaylocation_id`. The old "written in 1a it will not compile" hazard no longer exists. | closes the SDR write hole for `PATCH`/`POST`/`DELETE` on the three exported repositories — all three handlers ship together in the single API commit *(superseded 1a/1b wording removed 2026-08-06: a tail-read or grep was landing on it and getting the opposite instruction)* | 1-API | §3.9 (**O2**) |
| N7a | `PutawayConfigValidationException extends RuntimeException` + an `@ExceptionHandler` in `RestExceptionHandler` | the handler must throw **unchecked** or SDR wraps it and the client gets a 500 instead of 422 | 1a | §3.9.3 |
| N8 | `GET /receiving/getPutawayDestination/{advicePositionId}` | the entire 2731 display contract + `compatible` | 1a | §3.8 |
| N9 | `GET /client/{id}/effectivePutawayDestination` | the merchant screen's **Inherited** value — §3.11.3 is unrenderable without it | 1b | §3.8 |
| N10 | `GET /putawayConfig/preview?scope=…&locationId=…` | D11's incompatible-SKU count — the config-health signal D3 asked for and D6 dropped | 1a | §3.4c, §3.5a |
| N11 | `model/PutawayConfigAudit.java` + repository + `service/PutawayConfigAuditService.java` | **⚠ PHASE COLUMN STALE — see §5.2 O1.** With one API phase the table, entity, repository, service **and** audit rows all ship together, so **AC15 IS claimed by this plan** — the "1a validates + WARN-logs and does not claim AC15" interim state is gone. Do not implement the WARN-log stub. | the audit AC. The **table**, entity, repository, service and audit rows all ship together in the single API commit, so **AC15 IS claimed by this plan** *(superseded 1a/1b wording removed 2026-08-06 — it contradicted the correction in the preceding cell)* | 1-API | §3.14 (**O1**) |
| N12 | `db/migration/V2.2.13__putaway_destination_hierarchy.sql` | **one** migration (decided 2026-08-04): preflight guard, `DROP NOT NULL`, `putaway_config_audit` table, reversible pre-image, scoped backfill, `client.defaultputawaylocation_id` + guarded FK, `DEFAULT_PUTAWAY_LOCATION` sysprop seeded `''` | 1-API | §5.1 |
| N14 | `controller/PutawayConfigController.java` + `PutawayConfigPreview` | the typed write surface; the only place D11's count-and-confirm can live | 1a (`preview`, `setSku`, `setWarehouse`) / 1b (`setMerchant`) | §3.5a |

### 0.2 Web UI — `v2/wms2-web-ui/` (Phase 2)

| # | File:line | Construct | Verdict | § |
|---|---|---|---|---|
| 38 | `components/receiving/open/receive/receivingForm.vue` | ⚠ **STALE — this row describes the pre-SBDEV-2731 file. Corrected r-next 2026-08-11.** PR1 (`4ce39a1`) shipped the binding: `putawayStaging` is `:228` and is bound at `:336` from `newVal.defaultputawaylocationname`; the tri-state is `:296-300`; the `=== false` test is `:24`; the override chip is `:19`. **What is still missing is the diversion rendering** (`divertedTo` / `divertedReason`) | **in — narrowed, step 19a** | §3.11.1 |
| 39 | `components/admin/parametersAndConfiguration/editParamAndConfig.vue:23-30` (+ `addParamAndConfig.vue:22`) | generic sysprop dialog, `groupName` branches only | **in — add a `syskey` branch with a tiered location picker** | §3.11.2 |
| 40 | `components/admin/shippers/editShipper.vue:14-80` | merchant form; no putaway field, no inherited-vs-configured concept | **in — new three-state field** | §3.11.3 |
| 41 | `store/admin/configuration.js:73-93` (`PUT /sysprop/{id}`), `:95-123` (`POST /systemProperty/create`, axios at `:99`), `:125-147` (`DELETE /sysprop/{id}`, axios at `:127`), `:254-264` | the generic dialog's three write actions plus the groupname read | **in — the `DEFAULT_PUTAWAY_LOCATION` branch writes through `PUT /putawayConfig/warehouse`, NOT through any of these three** | §3.11.2 |
| 42 | `store/admin/shippers.js` (`:47` `PATCH /client/{id}`) | `GET /client/detailView`, `POST /client/create`, `PATCH /client/{id}` | **in — read the new field via `detailView`; write it through `PUT /putawayConfig/merchant/{clientId}`** | §3.11.3 |
| 43 | `plugins/persistedState.client.js:22-25` | persists the **entire** `admin` module (incl. `admin.configuration.operationOptions`) to `localStorage['vuex-web']` | **in — add exclusion** | §3.11.4 |
| 44 | `layouts/default.vue:264-268, 284-286`; `store/index.js:92-117`; `nuxt.config.js:167` | `adminMenu` never referenced; `'super-admin'` returned unconditionally; `APP_ADMIN_GROUP` read nowhere | **in — bounded decision, not a framework** | §3.12 |
| 45 | `components/masterData/material/skuData/skuData.vue:100-123, 142` *(⚠ corrected 2026-08-11 per SBDEV-2643 §10.3 **C4** — the path was missing its `material/skuData/` segments and the range was off by seven lines. An actions column already exists at `:95-99` with a live eye button, and the load-bearing line for the details overlay is `:130`'s `exclude-fields`, not `:142`)* | create/edit block commented out; `putawayLocation` already displayed read-only | **out of THIS plan** — that is SBDEV-2643's SKU edit form. §10 Q3 records that 2643 is materially bigger than "add a field". |
| 46 | `components/putaway/storePallet.vue:14-23` (mobile UI) | free-text scan, no expected destination shown | **out** — `wms2-mobile-ui` is a third phase, not in D4. Follow-up ticket, §8.4. |

---

## 1. Problem Statement

Receiving in v2 can send inbound stock to exactly **one** destination per SKU, and that destination is not really configurable.

**What the operator sees.** Receiving a case of a SKU whose putaway location was pointed at an incompatible location fails with:

```
unitloadtypeId=4 not allowed on location=Ice Pack with location type=2
```

thrown at `service/UnitloadBusinessService.java:235`. It leaks raw database ids, names no remedy, and arrives *after* the first unit load has already been created inside `receiveGoods`' single transaction — so the whole receipt rolls back with a message no warehouse user can act on. (Reproduced structurally on `wh01_hydra_v2t`: `unitload_type 4 = Case`, `location_type 2 = flowbin`, and `location_constraint` for `flowbin` has exactly one row permitting `unitloadtype_id=1 (PickLocation)`. `Ice Pack` itself exists only on NYWH UAT/prod.)

**What is missing.** There is no warehouse-level default and no merchant-level default. The ticket asks for a four-tier precedence — SKU → merchant → warehouse → standard putaway lane — configurable from the UI, validated, permission-gated, and audited.

**Why "just set the SKU field" is not an answer.** Three independent facts, all verified:

1. The SKU field is `NOT NULL` in DDL (`V2.2.00__base_v2_schema.sql:951`) and `@NotNull` on the entity (`model/Itemdata.java:49`), and **all four** write paths unconditionally seed it with the `PutAwayLane` id (§0.1 rows 8–11). On `wh01_hydra_v2`, **2,720 of 2,720 rows (100 %)** point at the single location `PutAwayLane` (id 50155). There is no "unset" state, so there is nothing for a lower tier to inherit *into*.
2. There is **no validated write path**. `controller/ItemDataController.java:88-90` is a raw `save()` with zero validation, reached by a `@GetMapping` that mutates state; `service/ItemdataService.setPutAwayLocation` (**`:73-82`**, cache block `:66-72` — re-derived 2026-08-11) has **zero production callers** and would not have validated anyway (it loads the old location only for a log line). And `PATCH /v3/itemdata/{id}` bypasses both — `RestConfiguration.java:47` uses `RepositoryDetectionStrategies.ANNOTATED` and `:55-60` registers only bean-validation validators. This is almost certainly how the invalid Ice Pack configuration was created.
3. The destination is **structurally ignored on the carrier path**. `ReceivingService.java:454-457` reads `itemdata.getPutawaylocationId()` **only when `carrier == null`**; on a carrier receipt `putAwayLocation` is hard-`null` and the unit load goes onto the carrier. That is a branch, not a data problem.

**Two corrections to the ticket's framing**, for the record:

- **SBDEV-2642 ("V1 Fix: Ability to Set Default PutAway other then PutAway") shipped no code.** Zero commits across all five repos, `assignees: []`, `attachments_count: 0`, closed 2026-07-25 — 1,247 s (≈21 min) **before** SBDEV-2732 was created. It was closed as superseded, not delivered. v1 `ReceivingService.java:521-523` is the same single-tier lookup and is strictly *worse* than v2 (bare `NoSuchElementException` vs message-keyed `BusinessException`). **There is no v1 prior art to port; jakarta-vs-javax is moot.** This is greenfield in both stacks.
- **"Receiving does not display or honor the SKU destination" (SBDEV-2731) is not an accurate code diagnosis.** The API *does* read it (`ReceivingService.java:455`) and `receiving_dto_view` *does* project `defaultputawaylocationname` (`V2.2.00__base_v2_schema.sql:4663` → `model/ReceivingDtoView.java:47, 173`). The real defects are (a) the unvalidated write path above, (b) a UI that never renders the existing column — `receivingForm.vue:9-13` hardcodes the literal string "Put Away Lane" — and (c) the carrier branch at `ReceivingService.java:454-457`.

---

## 2. Current Architecture

### 2.1 The resolution call path (the "is" state)

```java
// ReceivingService.java:451-457 — hoisted ABOVE the per-case loop at :462. Preserve that.
Location spawnLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_SPAWN)
    .orElseThrow(() -> new BusinessException("entityNotFoundForName", ...));
Location putAwayLocation = (carrier == null)
    ? locationRepository.findById(itemdata.getPutawaylocationId())
        .orElseThrow(() -> new BusinessException("entityNotFoundForId", Location.class.getSimpleName(), itemdata.getPutawaylocationId()))
    : null;

// ReceivingService.java:491-495 — per created unit load
if (carrier == null) {
    unitloadBusinessService.transferUnitLoadToLocation(unitload, putAwayLocation, false, codeReceiving, adviceposition.getNumber(), null);
} else {
    unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, codeReceiving, adviceposition.getNumber(), null);
}
```

Two properties to preserve: resolution is hoisted out of the loop, and `receiveGoods` is **one** tenant transaction (`:302`) so a bad destination fails on the first case and everything rolls back.

**Finding that materially de-risks D2.** On the non-carrier path, `transferUnitLoadToLocation` **already** places the unit load directly into the SKU's configured location. D2's "direct placement, bypass manual putaway" therefore requires **no new placement mechanism** — the only change is *which* `Location` the code hands to the existing call. And v2 has **no putaway-task entity**: `MobilePutAwayService.calculatePutAwayList` (`:217-305`) derives suggestions on the fly from unit loads sitting on the putaway lane. A directly-placed unit load simply never appears in that list, so *"no orphan putaway task remains open"* is satisfied with nothing to suppress. (Resolves open question 6 from the analysis bundle.)

### 2.2 Validation (the only compatibility gate today)

```java
// UnitloadBusinessService.java:188-237, inside transferUnitLoadToLocation (declared :125)
List<LocationConstraint> locationConstraintList =
    locationConstraintRepository.findByStoragelocationtypeId(destinationLocation.getTypeId());
if (locationConstraintList != null && !locationConstraintList.isEmpty()) {     // <-- FAIL-OPEN on empty
    boolean foundPermittingConstraint = false;
    for (LocationConstraint locationConstraint : locationConstraintList) {
        if (locationConstraint.getUnitloadtypeId().equals(unitload.getTypeId())) { foundPermittingConstraint = true; break; }
    }
    if (!foundPermittingConstraint) {
        throw new BusinessException("unitloadtypeId=" + unitload.getTypeId()
            + " not allowed on location=" + destinationLocation.getName()
            + " with location type=" + destinationLocation.getTypeId());   // :191 — the only raw-concat throw here
    }
}
```

**`location_constraint` is a pure allow-list, but an EMPTY list for a location type permits everything.** Live allow-list on `wh01_hydra_v2t` (8 rows): flowbin→PickLocation; overstock box→Case; overstock pallet→Case, Pallet; totes→Tote; packages→Package; cases and pallets→Case, Pallet. Location types **0 `System`** and **1 `NoRestriction`** have zero rows ⇒ unrestricted. A validator written as "missing row = disallowed" would reject configurations that work correctly today. This fail-open branch is **mandatory** to replicate (D6).

Three predicates run *before* the constraint check inside the same method and must be mirrored by write-time validation but **not** duplicated at receive time (they already run): destination lock check `:156-158` (`entityLock != NOT_LOCKED` → `FacadeException("STORAGELOCATION_LOCKED")`, skipped on `ignoreLock=true`), and `FixLocationAssignment` `:161-177` (carrier ban → `CARRIER_NOT_ON_FIXLOC`; SKU mismatch → `WRONG_ITEMDATA_FIXASSIGNMENT`).

Sibling throws at `:157, :167, :174` all use message keys via `exceptionMessageService.getMessage(...)`. `:191` is the **only** raw-concatenated one in the method — which is exactly why it leaks ids.

### 2.3 There is no "active" flag on `location` — DB evidence

```
location          : id, additionalcontent, created, entity_lock, modified, version, xpos, ypos, zpos,
                    name, client_id, area_id, rack_id, type_id,
                    staginglane, transferlane, automationlane, crossdockinglane, gate
location_area     : useforgoodsin, useforgoodsout, useforpicking, useforreplenish,
                    useforstorage, usefortransfer, usefordeepstorage   (all boolean NOT NULL)
location_constraint: id, name, number, storagelocationtype_id, unitloadtype_id
```

The ticket's requirement "*Be active*" has **no column to test**. §3.4c redefines validity as a concrete predicate over what exists. Closest proxy for "active": `entity_lock == BusinessObjectLockState.NOT_LOCKED (0)`; full enum at `WmsConstants.java:1188-1195` (`NOT_LOCKED=0, GOING_TO_DELETE=2, PICKED_FOR_GOODSOUT=100, QUALITY_FAULT=103, ON_HOLD=104, NOT_FOUND=403, TRANSFER=404, SHIPPED=405`). There is also no `shippinglane` flag — "shipping" is `gate == true` and/or `staginglane == true`.

### 2.4 Facility scoping is already solved — DB evidence

The tenant schema (52 tables) contains **no `warehouse` and no `facility` table**, and `location` has **no facility discriminator column**. Sysprop `Contact Line = 'NY East - Warehouse'` confirms one DB = one physical warehouse, matching the documented `tenant_name` + `facility_code` → 4-char routing key → per-facility DB topology.

**One database per facility.** The ticket's "prefer warehouse-specific configuration rather than a single tenant-wide location ID" is satisfied *automatically*: a tenant-wide row **is** warehouse-scoped because the database is the facility boundary. Likewise "one value per merchant per warehouse" is satisfied by one row per `client` per tenant DB. **No facility dimension, no composite key, no join table.** This deletes a large slice of the ticket's presumed data-model work.

### 2.5 Sysprop storage — DB evidence and four landmines

`los_sysprop` columns: `id, additionalcontent, created, entity_lock, modified, version, description, groupname, hidden, syskey, sysvalue, workstation NOT NULL, client_id NOT NULL`. Unique constraint **`UNIQUE (client_id, syskey, workstation)`** = `uk8tcoe23qui9q3ancbhx662iqb` (`V2.2.00__base_v2_schema.sql:3600-3603`), PK `(id)` at `:3400-3404`, FK on `client_id` at `:5334-5337`.

On `wh01_hydra_v2t`, **all 131 rows are `client_id = 0` / `workstation = 'DEFAULT'` across all 9 groupnames** — the per-client sysprop tier has **never been used in production**. No `PUTAWAY`-named key exists yet.

| # | Landmine | Evidence | Consequence for this design |
|---|---|---|---|
| A1 | `SyspropService.getStringDefault` **INSERTs** a row on a total cascade miss | `SyspropService.java:234` `createSystemProperty(getSystemClient(), WORKSTATION_DEFAULT, key, defaultValue, ...)` | Resolver may not be `readOnly`; "clear the override" cannot be a DELETE of the system row. **§3.4a avoids this method entirely.** |
| A2 | Blank vs null | tier hits return `sysprop.getSysvalue().trim()`; the UI writes `sysvalue=''` when a field is cleared | Blank-after-trim **must** mean "not configured". Same class as the JPQL `IS NULL`/`= ''` trap in `CLAUDE.md` §Query Patterns. |
| A3 | `getSysvalue(key)` is **client-blind** | `SyspropRepository.java:29-31` — `... where syskey = :syskey and workstation='DEFAULT' order by client_id LIMIT 1`; the comment at `:28` literally says *"legacy code incorrectly assumes one result"* | Consumed by `SyspropService.java:288-291`, the workhorse accessor. If merchant-scoped rows ever exist for a key it collapses them to the lowest `client_id`. **Never read a client-scoped key through it.** |
| A4 | the `sysprops` Caffeine cache key **omits `clientId`** | key = `facilityCode + ':' + #key` at `SyspropService.java:53, 95, 288, 303`; cache at `CacheConfig.java:36` (200 entries / 2 min) | Caching any client-scoped key through those methods serves one merchant's value to every merchant. |
| A5 | `setSysvalue` cannot write a merchant row | `SyspropService.java:303-320`; `:306` hard-codes `clientService.getSystemClient().getId()` + `DEFAULT` | A merchant-scoped sysprop **writer does not exist**. |

A3 + A4 + A5 + "never used in production" are four independent reasons the **merchant** tier must not be a sysprop row. See §3.3 and §9 A1.

### 2.6 Audit — nothing to extend

Schema search for `%audit%`, `%history%`, `revinfo`, `%changelog%` returned **zero tables**. `grep "Audited|Envers|RevisionEntity"` → zero hits, no dependency. Spring Data auditing gives **timestamps only** (`model/AbstractBaseEntity.java:16-17, 29-33`) — there is **no `@CreatedBy`/`@LastModifiedBy` and no `AuditorAware` bean**, so the framework does not capture *who*. `Stockrecord` / `UnitloadRecord` / `InventoryRecord` are stock-movement history, not config history.

The **only** entity-audit precedent is hand-rolled and domain-specific: `model/CustomerorderCancellationLog.java` + `service/CancellationLogService.java` (`@Transactional(value="tenantTransactionManager", propagation = Propagation.MANDATORY)`, `IDENTITY` id, explicit `tenantName`/`facilityCode` columns, `createdBy = SecurityContextUtils.getUserName()`). **Imitate that.** Do not introduce Envers for this ticket.

### 2.7 Cache topology in scope

`config/CacheConfig.java` defines four caches **twice** — Caffeine at `:31-42` (`@Profile("!redis")`) and Redis at `:49-69` (`@Profile("redis")`). **Both must stay in sync.**

| Cache | TTL | Key expression | Relevance |
|---|---|---|---|
| `sysprops` | 2 min | `facilityCode + ':' + #key` (**no clientId**) | tier 3 — read path deliberately uncached (§3.4a) |
| `clients` | 5 min | `facilityCode + ':' + #clientNumber` (`ClientService.java:53`) and `facilityCode + ':SYSTEM'` (`:100`) | **tier 2 lands here** — needs eviction |
| `locations` | 5 min | — | destination lookups |
| `itemdata` | 5 min | `facilityCode + ':id:' + #id` (`ItemdataService.java:47`) and `facilityCode + ':' + #clientId + ':' + #itemNr` (`:52`) | tier 1 — correct 2-key evict already written at `:59-67` |

**A 2–5 min TTL means a config change is not immediately visible.** §7.3 must not validate through a stale cache. Mitigating fact: `receiveGoods` loads its `Client` via `clientRepository.findById(adviceposition.getClientId())` (`ReceivingService.java:369-370`) — **uncached** — so the *receiving* path never reads a stale tier-2 value. Only the admin screens can.

### 2.8 Transaction & observability constraints

- `transferUnitLoadToLocation` is `Propagation.REQUIRED` and its sibling carries the explicit contract at `UnitloadBusinessService.java:259-260`: *"joins the caller's transaction. Caller must hold all row-level locks before invoking this method (SBDEV-2232 §3.0). Do NOT call from a non-transactional context."* ⇒ **the resolver must never open `REQUIRES_NEW`** — that produces a Postgres deadlock the detector cannot see (parent idle-in-transaction, hangs forever).
- `transferUnitLoadToLocation` / `transferUnitLoadToCarrier` have **33 call sites** (24 + 9) across picking, palletizing, truck loading, transfer orders, on-hold, nirvana and the empty-pool. **The resolver is wired at the receiving call-sites only, never inside `transferUnitLoadToLocation`.**
- **OSIV risk is LOW**: `Itemdata`, `Location`, `Client`, `LocationConstraint`, `LocationType`, `LocationArea`, `UnitloadType`, `Sysprop` all use manual `Long` FK ids with no JPA associations. `Location.equals` (`:163-168`) is id-based; `AbstractBaseEntity.hashCode()` (`:76-79`) deliberately returns `getClass().hashCode()`.
- **Micrometer: there is no counter or timer anywhere on the receiving path.** Zero hits for `MeterRegistry|Counter|Timer` in `ReceivingService`, `UnitloadBusinessService`, `ReceivingController`. `schedulejob/JobMetrics.java` is cron-only. Instrumentation is **net-new** (§3.13).
- `IdempotencyFilter` guards `/rest/**` only — `/v3/receiving/receive` and `/v3/itemData/*` are **outside** it.
- **`ddl-auto` is `none`** (`application.properties:70`; `:69` has `validate` commented out) — so entity/DDL drift does **not** fail startup. Every entity field added in §3 must still land in the same commit as its DDL, but the enforcement is **runtime, not startup**: a mapped column with no DB column fails `42703` on every SELECT that touches it, per request, with healthy probes. `validate` is the **test** profile only.

### 2.9 Flyway / repo state

Migration head on `origin/develop` is **`V2.2.09__seed_return_advice_auto_receive_sysprop.sql`** ⇒ **next free version is `V2.2.13`** — one migration (D16, 2026-08-04). **`V2.2.08`** was taken by SBDEV-2801 and **`V2.2.09`** by SBDEV-2778, both merged that day; `V2.2.13` was verified free across `origin/develop` **and every remote branch**. **Re-verify with a full remote-branch sweep immediately before the PR** — unmerged branches hold invisible versions, which is exactly how the original `V2.2.08` reservation collided. Three hard facts:

1. **The running app DOES invoke Flyway, on every boot — this reverses the plan's original premise.** `app.flyway.migrate-on-startup=true` (`application.properties:133`) + `landlord/config/StartupFlywayMigrationRunner.java` (an `ApplicationRunner`, default-ON via `matchIfMissing = true`) migrate the landlord and then **every active tenant DB** before readiness (SBDEV-2801, merged 2026-08-04; see `v2/wms2-api/CLAUDE.md` §Database). **But a tenant DB with no `flyway_schema_history` is SKIPPED, not auto-baselined** — and the Hydra DEV copy is exactly such a DB (§8.1). So on that tenant merging changes nothing and the migration silently never applies until it is repaired once with `db/backfill-flyway-history.sh` ⚠ **CORRECTED 2026-08-11 on the ticket owner's information: `wh01_hydra_v2` is INACTIVE on DEV.** The only active DEV tenant is WineCo's `dev_wh01_om1`. `StartupFlywayMigrator` iterates ACTIVE tenants only, so an inactive DB is never migrated and never served — there is no `42703`, and no operator repair is owed. Everything below about backfilling its Flyway history is MOOT for DEV. It would matter only if that tenant were reactivated..
2. **`ddl-auto` is `none`, not `validate`** — `application.properties:70`; `:69` has `validate` commented out, and the value flows into both EMFs (`LandlordDatabaseConfig.java:32-50`, `TenantDatabaseConfig.java:32-63`). `validate` is the **test** profile only. **Consequence: a missing column does NOT prevent startup.** The app boots clean and then fails `42703 column ... does not exist` on every Hibernate SELECT that touches the mapped column — per-request, with green liveness/readiness probes. See §8.1's detector.
3. **The IT harness scans `classpath:db/v1-to-v2-onboarding/schema`, not `db/migration/`** (`v2/wms2-api/CLAUDE.md:141`) ⇒ `V2.2.13` is **invisible** to integration tests. No IT can prove the DDL.

Branch off **`develop`** explicitly. *(The local checkout has sat on unrelated ticket branches; do not assume it is on `develop`, and do not branch off another ticket's branch — stacked-PR orphan trap.)*

---

## 3. Design

Four tiers, one resolver, one validator, one audit writer, one metrics holder. Everything below is additive except §3.2 (the nullability change) and §3.6 (the message replacement).

```
                                  PutawayDestinationResolver.resolve(itemdata, client, unitloadtypeId)
                                                   │
  Tier 1  SKU        itemdata.putawaylocation_id  NOT NULL ──► SKU_OVERRIDE
                        │ NULL  (new — V2.2.13 drops NOT NULL)
  Tier 2  Merchant   client.defaultputawaylocation_id  NOT NULL ──► MERCHANT_OVERRIDE
                        │ NULL  (new column — V2.2.13)
  Tier 3  Warehouse  los_sysprop(client_id = <system>, syskey='DEFAULT_PUTAWAY_LOCATION')  non-blank ──► WAREHOUSE_DEFAULT
                        │ absent / blank-after-trim
  Tier 4  Fallback   location WHERE name = WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE ──► STANDARD_PUTAWAY_LANE
```

### 3.1 `PutawayDestinationResolver` — the one shared service

**Rationale.** The ticket's central AC is *"precedence is defined in ONE shared backend service"*. Every consumer (receiving, the config-write validators, the receiving-display endpoint, Phase 2's inherited-vs-configured display) calls the same method, so the four-tier semantics — including the sentinel subtleties — exist in exactly one place and are unit-testable in isolation.

**New file:** `src/main/java/net/aim_ai/wms/service/PutawayDestinationResolver.java`

```java
@Service
public class PutawayDestinationResolver {

    public enum Source { SKU_OVERRIDE, MERCHANT_OVERRIDE, WAREHOUSE_DEFAULT, STANDARD_PUTAWAY_LANE }

    /** Immutable resolution outcome. {@code configuredFor} is the human label of the tier that won
     *  (SKU number / merchant cl_nr / "warehouse" / "standard lane") for operator-facing messages. */
    public record Resolution(Location location, Source source, String configuredFor) {}

    /**
     * Resolves the effective putaway destination for one receipt line. Pure resolution + P1
     * classification: it NEVER throws on incompatibility — see {@link Resolution#compatible()}.
     *
     * <p>MANDATORY propagation, deliberately: (a) it structurally forbids a new transaction, which is
     * what makes the {@code REQUIRES_NEW}-inside-a-lock-holding-tx deadlock (SBDEV-2232 §3.0,
     * {@code UnitloadBusinessService.java:259-260}) unreachable by construction; (b) it joins the
     * caller's read-write transaction so the {@code readOnly} question does not arise; (c) it makes an
     * accidental non-transactional call fail loudly instead of silently auto-committing.
     *
     * <p><b>MANDATORY means a controller cannot call this directly</b> — there is ZERO
     * {@code @Transactional} anywhere under {@code controller/}. Read callers go through
     * {@link PutawayDestinationQueryService} (§3.8). See §3.1.5.
     *
     * @param itemdata       MAY BE NULL — {@code AdviceRestController.java:684} sets
     *                       {@code position.setItemdataId(null)} on the hub-and-spoke path. Reachable
     *                       from the display endpoint; see §3.1.4.
     * @param client         never null; the merchant owning the receipt line.
     * @param unitloadtypeId the unit-load type that will be created, from
     *                       {@code adviceposition.getUnitloadtypeId()}. MAY BE NULL ⇒ {@code compatible}
     *                       is reported as {@code true} (unknowable, so do not claim a conflict).
     */
    @Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)
    public Resolution resolve(Itemdata itemdata, Client client, Long unitloadtypeId)
            throws BusinessException { ... }

    /** Throws iff {@code !r.compatible()}. Split out so the CALLER decides whether a mismatch is
     *  fatal — receiving calls it only when {@code carrier == null} (§3.7.2, D10); the display
     *  endpoint never calls it. */
    public void requireCompatible(Resolution r) throws BusinessException { ... }
}
```

**`Resolution` carries `compatible` rather than throwing.** The resolver is hoisted and runs for *both* receiving branches (which is what fixes 2731), but on the carrier path the resolved destination is **never applied**, so an incompatibility there is not an error. Making the throw a separate, caller-invoked step is what lets one resolution serve a fatal path and a non-fatal path without a flag argument.

```java
public record Resolution(Location location, Source source, String configuredFor,
                         boolean compatible, String incompatibilityReason) {}
```

#### 3.1.1 Tier evaluation order and the exact "configured" test

| Tier | Test | Notes |
|---|---|---|
| 1 SKU | `itemdata != null && itemdata.getPutawaylocationId() != null` | honest only after §3.2 + the §5.1 backfill |
| 2 Merchant | `client.getDefaultputawaylocationId() != null` | §3.3 |
| 3 Warehouse | raw sysvalue non-null **and** `!raw.trim().isEmpty()` **and** parses as a `Long` | §3.4a; landmine A2 |
| 4 Fallback | always | `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE)` |

A tier that is *configured* but whose location id does not resolve to a `location` row is a **hard failure**, not a fall-through (D6). A tier that is *not configured* falls through silently. These are different states and must not be conflated.

#### 3.1.2 What the resolver validates at receive time — and what it deliberately does not

The resolver applies **only** predicate **P1 (compatibility)** — §3.4b — to the winning tier. It does **not** apply the broader suitability predicate **P2** (§3.4c) at receive time.

**Rationale, and this is load-bearing:** applying P2 at receive time would make the resolver *stricter* than `transferUnitLoadToLocation` and would break receipts that work today. Specifically, `PutAwayLane` on `wh01_hydra_v2t` sits in area `Inbound` with `useforstorage = false` — a suitability predicate that required `useforstorage` would reject tier 4 itself. P2 is a *"is this a sane thing to configure"* question and belongs at config-write time only. P1 is byte-for-byte the semantics already enforced at `UnitloadBusinessService.java:188-237`, so hoisting it earlier changes *when* and *how* the failure is reported, never *whether*.

The lock check (`:163-165`) and `FixLocationAssignment` checks (`:169-184`) are also **not** duplicated at receive time — `transferUnitLoadToLocation` still runs them a few lines later. Duplicating them would double the queries for no behavioural gain.

#### 3.1.3 Failure semantics

`requireCompatible(...)` — **called by receiving only when `carrier == null`** (§3.7.2), never by the display endpoint:

```java
throw new BusinessException("putawayDestinationNotPermitted",
        resolution.configuredFor(),                 // %1$s  "SKU 12345" | "merchant WINE01" | "warehouse default"
        resolution.location().getName(),            // %2$s  "Ice Pack"
        unitloadTypeName,                           // %3$s  "Case"
        locationTypeName,                           // %4$s  "flowbin"
        WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE); // %5$s  remedy anchor
```

**`putawayDestinationNotPermitted` is thrown HERE, in the resolver, and NOWHERE ELSE.** In particular it is **not** thrown at `UnitloadBusinessService.java:235`: that throw site also serves picking, palletizing, truck loading, transfers, on-hold and nirvana — 21 call sites with no configured putaway destination, for whom the remedy clause ("clear the configured destination") is actively misleading. `:191` gets the neutral key `unitloadTypeNotPermittedOnLocation` instead (§3.6.1). The putaway-specific key belongs where the putaway context exists, and keeping it out of `:191` is also what removes any need to pipe `unitloadRepository.findLabelidById` / `unitloadTypeRepository.findNameById` lookups into that method.

It **must** be a `BusinessException` (never a bare `RuntimeException`): `ReceivingController.java:283-300` catches `BusinessException` and surfaces `e.getMessage()`, but `:298-300` swallows `RuntimeException` into *"Receiving failed due to an unexpected internal error. Please contact support."* — which would defeat the ticket's error-handling AC outright. **`IllegalTransactionStateException` is exactly that forbidden class** — see §3.1.5.

**A dangling configured id is still a hard failure** (D6), distinct from an incompatibility: a tier that is *configured* but whose location id resolves to no `location` row throws immediately from `resolve(...)` on **both** branches, because that is config rot with no valid destination at all, not a workflow mismatch. A tier that is *not configured* falls through silently. Three states, three behaviours — do not collapse them.

#### 3.1.4 The null-SKU path (§0.1 row 21) — a DISPLAY-endpoint contract, not a receive-path one

`AdviceRestController.java:684` sets `position.setItemdataId(null)` on `createHubAndSpoke` while `:685` still sets a `unitloadtypeId`. Contract: **`itemdata == null` skips tier 1 and starts at tier 2**, with `configuredFor` degrading to the merchant / warehouse label. `PutawayDestinationResolverUnitTest.nullItemdataSkipsTierOne` asserts `resolve(null, client, typeId)` returns a non-null `Resolution` and never touches `itemdataRepository`.

**Scope of the contract: the display endpoint only.** A hub-and-spoke position cannot reach the resolver during a *receipt*. `receiveGoods` calls `itemdataRepository.findById(adviceposition.getItemdataId())` at `:356-357`, **96 lines before** the resolver at `:451`; `findById(null)` raises `InvalidDataAccessApiUsageException`, and `createStockUnit` (`:476`) needs a non-null `itemdata` regardless. The receipt therefore fails earlier, for a **pre-existing** reason this plan does not fix (§0.1 row 21a, §10 Q4).

The contract is nevertheless required, because **`GET /receiving/getPutawayDestination` resolves per advice position and genuinely can be handed one with a null `itemdataId`** — that is where a naive resolver 500s. Manual row **M12 is stated against the endpoint, not against a receipt**; stated against a receipt it could never pass.

#### 3.1.5 Reaching a `MANDATORY` resolver from a non-transactional controller

`Propagation.MANDATORY` on `resolve(...)` is the structural anti-`REQUIRES_NEW` device and stays. Its consequence is that **no controller may call it**: there is **zero `@Transactional` anywhere under `controller/`** — **re-measured 2026-08-09 on `origin/develop`: six matches, all of them comments** (`mobile/PickingController.java:346`, `rest/AdviceRestController.java:172, 286, 316`, `rest/SkuRestController.java:167, 281`), several of which explicitly state the controller has no transaction. *(Was "three matches"; the count grew, the conclusion did not.)* A `MANDATORY` call from there raises `IllegalTransactionStateException: No existing transaction found for transaction marked with propagation 'mandatory'`, a bare `RuntimeException`, on **every single call**. OSIV does not help: even when enabled it opens an `EntityManager`, never a transaction — and it is disabled (`application.properties:55` `spring.jpa.open-in-view=false`). Since §3.8's endpoint declares only `throws BusinessException`, `RestExceptionHandler` would map it to a 500 — and under D9 that endpoint is the *sole* data source for the entire 2731 display feature, in **Phase 1**.

**Every read caller therefore goes through a read-only tenant-tx facade:**

```java
@Service
public class PutawayDestinationQueryService {
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public Resolution describeForAdvicePosition(Long advicePositionId) throws BusinessException { … }

    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public Resolution describeForClient(Long clientId) throws BusinessException { … }   // §3.11.3, N9
}
```

`readOnly = true` is safe **precisely because** §3.4a never touches `getStringDefault` — there is no auto-INSERT to accommodate (landmine A1). That decision is what makes this facade possible; had tier 3 gone through `getStringDefault`, no read-only facade could exist.

**No mocked unit test can prove this wiring.** A Mockito mock has no propagation semantics, so §7.1's `getPutawayDestinationShape` passes against a controller that calls the resolver directly. Proving it needs a real Spring context (blocked by SBDEV-2217) or a code-shape assertion — hence verify rows `check_N2_readonly_facade` (the facade exists and is annotated `readOnly = true`) and `check_N2_controller_delegates_not_resolves` (§3.8), plus manual row **M20**.

### 3.2 Tier 1 — make the SKU column nullable (D5)

**Rationale.** `NULL` is the only honest representation of "inherit". The alternatives were both rejected in §9 (A2, A3). This is the plan's single non-additive change and its primary compatibility risk.

**DDL** — `V2.2.13`, statement 2 (statement 1 is the preflight guard; full ordered script in §5.1):

```sql
ALTER TABLE public.itemdata ALTER COLUMN putawaylocation_id DROP NOT NULL;
```

Forward-only, cannot fail on existing data. The FK to `location(id)` (`V2.2.00...sql:5686-5690`) and the index `itemdata_putawaylocation_id_index` (`:4468-4471`) are unaffected — a nullable FK column is still enforced when non-null, and the index still serves the lookup.

**Entity** — remove the `@NotNull` above `putawaylocationId` at `model/Itemdata.java:49`. Keep the `@Column`. (`@NotNull` is what Spring Data REST's bean-validation validators enforce at `RestConfiguration.java:55-60`; leaving it would keep HAL writes of `null` rejected while typed writes succeeded — an inconsistency worse than either state.)

**Stop seeding — 4 sites, all in Phase 1, all in the same commit as `V2.2.13` (O3):**

| Site | Change |
|---|---|
| `SkuRestController.java:85-88` (create) | delete the `defaultPutawayLocationId` lookup |
| `SkuRestController.java:144-146` (create → `upsertAll`) | drop the argument |
| `SkuRestController.java:198-201` (update) | delete the lookup |
| `SkuRestController.java:257-259` (update → `upsertAll`) | drop the argument |
| `SkuBatchCreateUpdateService.java:36` | remove the `Long defaultPutawayLocationId` parameter |
| `SkuBatchCreateUpdateService.java:53` | delete `itemData.setPutawaylocationId(defaultPutawayLocationId)` — new SKUs are created with `NULL` = inherit |
| `FileImportController.java:383` | delete `itemData.setPutawaylocationId(location.get().getId())` |
| `FileImportController.java:355-359` | **keep an equivalent guard.** The SBDEV-2037 comment stays true in spirit — a missing `PutAwayLane` still breaks tier 4. Convert it from "the import needs the lane" to "the tenant needs the lane": keep the `findByName` presence check and the `errors.add(...)`, drop only the `.get().getId()` use. |

**Read-site null guards — 2 sites:**

- `ReceivingService.java:455` — subsumed entirely by §3.7; the ternary disappears.
- `ItemdataService.java:71` — `locationRepository.findById(itemData.getPutawaylocationId())` currently NPEs on `null`. Rewritten in §3.5.

**Test fixtures that assert the field is required — update deliberately, never by loosening an assertion** (≈10 sites): `common/fixtures/TestDataFactory.java:694`, `unit/model/EntityUnitTest.java:345, 370`, `unit/repo/ItemdataRepositoryTest.java:32`, `unit/service/ItemdataServiceUnitTest.java:592`, `MobileReplenishServiceH2Test:141`, `PickingorderBusinessServiceH2Test:279`, `ReplenishOrderControllerH2Test:148`, plus the two `@Disabled` ITs `ReplenishorderRepositoryIntegrationTest:66` and `CustomerorderBatchServiceParallelStreamRegressionIT:187`.

### 3.3 Tier 2 — merchant column on `client`

**Rationale.** `client` is a tenant-PU entity (`model/Client.java:10-22`) already carrying per-facility operational config (`enablereceiving`, `printerreceiving_id`, `section_id`). Because one facility == one tenant DB (§2.4), a column on `client` satisfies *"one value per merchant per warehouse"* **structurally, for free** — no composite key, no facility column, no join table. A typed FK gives referential integrity a `sysprop.sysvalue text` cannot, and it sidesteps landmines A3, A4 and A5 entirely. The repository is already REST-exposed (`ClientRepository.java:18-19`), and `/client/detailView` already feeds the Phase-2 merchant screen.

**DDL** — `V2.2.13`, statement 1 (Phase 1; the FK gets the re-apply guard shown in §5.1):

```sql
ALTER TABLE public.client
    ADD COLUMN IF NOT EXISTS defaultputawaylocation_id bigint NULL;
ALTER TABLE public.client
    ADD CONSTRAINT fk_client_defaultputawaylocation
        FOREIGN KEY (defaultputawaylocation_id) REFERENCES public.location(id);
```

Named FK constraint (not auto-generated) so it is greppable and droppable. No index — `client` is a tiny table and the column is read by primary-key lookup of the client, never filtered on.

**Entity** — `model/Client.java`, beside `printerreceivingId`:

```java
@Column(name = "defaultputawaylocation_id")
private Long defaultputawaylocationId;    // NULL = inherit from the warehouse default
```

with getter/setter. **No `@NotNull`.**

**Deploy-order coupling:** this field and the DDL must be deployed together, and the DDL must be applied *first*. See §5.1 row 1 and pre-mortem P1 — on an un-migrated database the application **starts normally and then fails `42703` on every `client` read**. (It does *not* refuse to boot: `ddl-auto` is `none`, not `validate`.)

**Cache eviction** — the `clients` cache has two key shapes (`ClientService.java:53` and `:100`). The merchant writer (§3.5) carries:

```java
@Caching(evict = {
    @CacheEvict(value = "clients",
        key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #client.clNr"),
    @CacheEvict(value = "clients",
        key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':SYSTEM'")
})
```

The `:SYSTEM` eviction is unconditional and cheap — SpEL cannot cheaply ask "is this the system client", and evicting one extra key from a 100-entry cache costs nothing.

### 3.4 Tier 3, tier 4, and the two predicates

#### 3.4a Tier 3 — system-client sysprop, read through the non-auto-creating path

**Rationale.** groupname **`Operation Options`** is rendered generically by the existing Admin screen via `GET /sysprop/search/findByGroupname` (`SyspropRepository.java:22-23` → `SyspropService.getSystemByGroupname:256-286`), so the ticket's requested *Admin → Parameters → Configuration → Operational Options* path lands with **zero new UI plumbing**. 29 keys already live there on `wh01_hydra_v2t` (`INBOUND_UPDATE_STOCK_IMMEDIATELY`, `REQUIRE_RECEIVING_TO_CONTAINER`, `PICK_PATH_DIRECTION`, …).

**New constant** — `service/WmsConstants.java`, beside `SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY` at `:1136`:

```java
public static final String SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY = "DEFAULT_PUTAWAY_LOCATION";
```

**Read path — this resolves landmine A1.** The resolver reads:

```java
String raw = syspropRepository
        .findBySyskeyAndClientIdAndWorkstation(
                WmsConstants.SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY,
                clientService.getSystemClient().getId(),
                WmsConstants.SystemProperty.WORKSTATION_DEFAULT)
        .map(Sysprop::getSysvalue)
        .orElse(null);      // absent row == not configured — see "the seed is a convenience" below
```

**`getSystemClient()` may return `null` — guard it.** `ClientService.java:101-109` returns `null` when no `cl_nr = 'System'` row exists (its own javadoc says so). Tier 3 must resolve it through an explicit `BusinessException`, never dereference it: an NPE there is a bare `RuntimeException`, the class §3.6.2 forbids, and `ReceivingController:298-300` would swallow it into "contact support".

```java
Client systemClient = Optional.ofNullable(clientService.getSystemClient())
        .orElseThrow(() -> new BusinessException("entityNotFoundForName", Client.class.getSimpleName(), "System"));
```

Note that `getSystemClient()` **is** `@Cacheable(value = "clients", key = … + ':SYSTEM')` (`ClientService.java:100`), so tier 3's *system-client lookup* is cached even though its *sysprop value read* is not. That is harmless — the system client's identity does not change — and a cache read inside a `readOnly` transaction is fine. §7.6 row 9 records it so the "receiving reads the tier values uncached" claim is not over-stated.

**LANDMINE A6 — `findSysvalueByClientIdAndSyskey` must never be used for this key.** `SyspropRepository.java:46-48`'s SQL is `select sysvalue from los_sysprop where client_id = :clientId and syskey = :syskey order by client_id LIMIT 1` — **it has no `workstation` predicate**, while the unique constraint is `(client_id, syskey, workstation)` (`uk8tcoe23qui9q3ancbhx662iqb`). The repository's own comment above it ("*this is unique constraint guaranteed to return one result*") is **wrong for this method**, and `order by client_id` is a no-op when `client_id` is already fixed — so with more than one workstation row for the key, **the value returned is arbitrary**.

That is reachable, not theoretical: `getSystemByGroupname` (`SyspropRepository.java:53-71`) filters on `groupname` **only** — no `client_id`, no `workstation` — so the generic Admin dialog lists and `PUT`s whatever rows exist, and `createSystemProperty` accepts an arbitrary workstation (`SyspropService.java:55, 61-75`). `ReceivingService.java:429-431` is a correct precedent for `WAREHOUSE_NAME`, but a **bad** precedent for a **UI-writable** key.

`findBySyskeyAndClientIdAndWorkstation` (`SyspropRepository.java:35-36`) is genuinely unique on the constraint, returns `Optional<Sysprop>`, is a derived query (no `@Query`), and is **not** `@Cacheable`. Reading tier 3 through it, and only through it, gives four properties the design depends on:

- `SyspropService.getStringDefault` is **never called** ⇒ no auto-INSERT (A1), so the resolver has no write path and no 23505 replica race on `uk8tcoe23qui9q3ancbhx662iqb`. This is also what lets §3.1.5's facade be `readOnly = true`.
- `SyspropService.getSysvalue` is **never called** ⇒ no client-blind `order by client_id LIMIT 1` collapse (A3) and no clientId-less cache key (A4).
- Neither method is `@Cacheable`, so tier 3 is still read uncached and the §3.10 freshness contract is unchanged.
- "Clear the warehouse default" is still an **UPDATE to `''`**, not a DELETE, and blanking is still stable because nothing auto-recreates the row.

Additionally, the event handler (§3.9) **rejects a write to this syskey on any workstation other than `DEFAULT`**, so the ambiguous state cannot be created through the UI in the first place. Unit test `workstationScopedRowIsIgnored`; verify row `check_R_tier3_workstation_qualified` plus a negative asserting `findSysvalueByClientIdAndSyskey` appears nowhere in the resolver.

**Value format: the numeric `location.id`.** Rationale: tier 2 stores an id, so both configurable tiers agree and the Phase-2 picker writes one shape; ids survive a location rename; **`location.name` has no unique constraint** (`V2.2.00__base_v2_schema.sql:959-979` — `name varchar(255) NOT NULL`, nothing more), the same fact that drives §5.1's backfill preflight guard. Cost: the value is not human-legible in the raw sysprop table — mitigated by writing the location name into the sysprop `description` on every write (§3.5) and by the Phase-2 picker (§3.11.2).

**Seed** — `V2.2.13`, final statement, modelled exactly on `V2.2.04` (draw `id` from `nextval('public.seqentities')`, never a literal; `INSERT ... WHERE NOT EXISTS` for idempotency):

```sql
INSERT INTO public.los_sysprop
    (id, version, entity_lock, hidden, syskey, sysvalue, workstation, client_id, groupname, description, created, modified)
SELECT nextval('public.seqentities'), 0, 0, false,
       'DEFAULT_PUTAWAY_LOCATION', '',            -- '' = not configured (landmine A2)
       'DEFAULT', 0, 'Operation Options',
       'SBDEV-2732: warehouse-level default putaway destination, stored as a location.id. Blank = not configured; receiving then falls through to the standard PutAwayLane. Set via Admin > Parameters > Configuration > Operation Options.',
       now(), now()
WHERE NOT EXISTS (
    SELECT 1 FROM public.los_sysprop
    WHERE syskey = 'DEFAULT_PUTAWAY_LOCATION' AND client_id = 0 AND workstation = 'DEFAULT');
```

Seeded **blank**, so no tenant's behaviour changes when the migration is applied. **This is the single most load-bearing line in the whole migration** — the entire §6 back-compat argument rests on it, and a migration that seeded a real location id would pass every other check while silently changing behaviour on all five tenants. Verify row `check_M_sysprop_seed_blank` asserts the literal `''` **in the INSERT's SELECT list**, not merely that the key name appears somewhere in the file.

**The seed is a convenience, not a dependency.** An absent row yields `Optional.empty()` ⇒ `null` ⇒ not-configured, which is exactly the same behaviour as a blank value. Seeding explicitly only makes the key **visible in the generic admin dialog** before the first write. That is why the seed can sit in `V2.2.13` while tier 3 itself is live from Phase 1: `PUT /putawayConfig/warehouse` (§3.5a) creates the row on first write if the seed has not run.

#### 3.4b Predicate P1 (compatibility) — extract, do not reinvent

**New method on `service/LocationConstraintService.java`:**

```java
/**
 * SBDEV-2732 — single source of truth for "may a unit load of this type sit on a location of this type".
 *
 * <p>An EMPTY constraint list for the location type permits EVERY unit-load type. That fail-open branch
 * is not a bug and must not be "fixed": location types {@code System} and {@code NoRestriction} carry
 * zero {@code location_constraint} rows on live tenants and are legitimately unrestricted. A predicate
 * written as "missing row = disallowed" would reject configurations that work correctly today.
 *
 * <p>Deliberately uses the existing {@code findByStoragelocationtypeId} + in-memory scan rather than a
 * new {@code existsBy...} query: the list fetch reproduces {@code UnitloadBusinessService.java:188-237}
 * byte-for-byte, which is the whole point, whereas an {@code exists} formulation needs two round-trips
 * to express the same fail-open rule and invites drift.
 */
public boolean isUnitloadTypePermitted(Long storagelocationtypeId, Long unitloadtypeId) {
    List<LocationConstraint> constraints =
        locationConstraintRepository.findByStoragelocationtypeId(storagelocationtypeId);
    if (constraints == null || constraints.isEmpty()) {
        return true;                                       // fail-open — see javadoc
    }
    for (LocationConstraint c : constraints) {
        if (c.getUnitloadtypeId().equals(unitloadtypeId)) {   // correct Long.equals
            return true;
        }
    }
    return false;
}
```

`UnitloadBusinessService.java:188-237` is then rewritten to call it (§3.6), so the rule exists once. **No new repository method** — §0.1 row 16 stays as-is.

> [!warning] **⚠ P1 MUST NOT BE APPLIED TO A PICK-FACE DESTINATION — at write time OR at receive time. Added 2026-08-08.**
>
> §5.2 step 7 has the validator apply **P1 + P2**. P1 is `isUnitloadTypePermitted(destinationType, unitloadType)`
> and it asks *"can a unit load of the SKU's default type sit here?"* **For a pick face that is the wrong
> question, and it answers "no".**
>
> Measured on HMG PRD: flowbin (`type_id = 2`) has **exactly one** `location_constraint` row, permitting
> `unitloadtype_id = 1` (`PickLocation`); `ICE PACK`'s `defultype_id` is **4** (`Case`). **So P1 is FALSE and
> rejects the `ICE PACK` configuration — even after P2.5 and P2.7(c) are dropped.** Relaxing those two does
> not make the config writable; P1 still refuses it.
>
> **Why the question is wrong.** Under (iv-b) no Case unit load ever sits on the pick face. Receiving diverts
> to the lane; putaway merges the stock into the flowbin's **resident `PickLocation` unit load**
> (`storeBoxOnLocation:499-513`) and retires the Case UL en route. P1 is testing a unit load that will never
> be there.
>
> **Rule: skip P1 when the destination is a `flowbin`** — predicate **`sltname == 'flowbin'` ONLY**, at
> **config-write time** (the validator, §5.2 step 7). Without it `ICE PACK` cannot be configured.
>
> **⚠ CORRECTED 2026-08-09 BY REVIEW — the predicate was `area.useforpicking == TRUE || sltname ==
> 'flowbin'`, and the wider disjunct is a defect.** Read the whole box before implementing.

> [!warning] **⚠ THE `useforpicking` DISJUNCT RELOCATES SBDEV-2731'S BUG TO PUTAWAY. Corrected 2026-08-09.**
>
> **The justification above is true of exactly one branch out of four.** *"Putaway merges the stock into the
> resident `PickLocation` unit load and retires the Case UL"* describes `storeBoxOnLocation`'s **flowbin**
> branch only. The others do the opposite:
>
> | Destination type | What putaway actually does | Is P1 the right question? |
> |---|---|---|
> | `flowbin` | merges into the resident `PickLocation` UL — **no whole-UL transfer** | **No.** Skip P1. |
> | `overstock box` / `overstock pallet` | `transferUnitLoadToLocation` — **re-runs P1 verbatim** at `UnitloadBusinessService:187-200` | **Yes.** Keep P1. |
> | `cases and pallets` (club lanes) | `transferUnitLoadToLocation` (once SBDEV-2821 ships §3.2a) | **Yes.** Keep P1. |
> | anything else | throws | — |
>
> So for three of the four, skipping P1 at write time does **not** remove the check — it moves the failure
> from a 422 the operator can act on to a throw during putaway. **That is SBDEV-2731's reported error, one
> step downstream.**
>
> **The population is real.** A `useforpicking` area contains non-flowbin types: on `wms2-hydra-dev2`, 12
> `overstock box` + 3 `overstock pallet` sit in picking areas; on `wms2-wineco-dev`, 69 `cases and pallets`
> (the clubs) do. Not currently *exploitable* on either — every SKU's `defultype_id` is `Case` on both, and
> `overstock box` permits Case — so this is a **structural** defect, not a live one. But note `overstock
> pallet` permits **Pallet only** on wineco and **Case + Pallet** on hydra-dev2: constraint config is
> per-tenant, so "no SKU can fail" is a data fact that can change with no code change.
>
> **Narrowing costs the club use case nothing.** `cases and pallets` has **zero** `location_constraint` rows
> on wineco (P1 fails open) and permits Case + Pallet on hydra-dev2 (P1 passes). `ICE PACK` is a flowbin, so
> it stays configurable.
>
> **Use the SAME predicate as rule (e).** Both track the same thing — the branch where putaway merges into a
> resident UL. See the "three predicates" box below.

> [!warning] **⚠ THERE IS NO P1 SKIP AT RECEIVE TIME — it is an ORDERING requirement. Corrected 2026-08-09.**
>
> This box previously said to skip P1 at *"both enforcement points"*. At receive time nothing is skipped:
> **step 15's gate runs first and retargets to the lane**, so `requireCompatible` evaluates P1 against
> `PutAwayLane` and passes. Stating it as a "skip" invites an implementation that adds a real skip branch
> inside `requireCompatible` — which would then also fire for **staging and cross-dock** destinations, which
> are *not* diverted and where P1 is the only compatibility check standing.
>
> **Implement as:** config-write skips P1 for flowbins; receive-time runs the gate **before**
> `requireCompatible` and never skips.

> [!warning] **⚠ P1's INPUT COLUMN — state which one P2.6 means. Added 2026-08-09.**
>
> This box describes P1 as asking *"can a unit load of **the SKU's default type** sit here?"* and cites
> *"`ICE PACK`'s `defultype_id` is 4"*. Two problems:
>
> 1. **`defultype_id` exists only on `itemdata`** (checked against `information_schema`) — `ICE PACK` is a
>    *location*, so that attribution is wrong. The substance (a Case UL against a PickLocation-only flowbin)
>    is right; the column reference is not. Fix it before it becomes a test fixture.
> 2. **Receiving does not use `itemdata.defultype_id`.** `ReceivingService:399` takes the receipt's unit-load
>    type from **`adviceposition.getUnitloadtypeId()`** — per-advice, operator/EDI-supplied. So a write-time
>    P1 keyed on `defultype_id` is not a sound predictor of the receive-time check.
>
> Unpopulated today (all 42,377 advice positions and all 8,804 SKUs on `wms2-wineco-dev` are `Case`), but
> **P2.6 must say which column it enumerates.**
>
> **✅ RESOLVED 2026-08-09 — P2.6 enumerates `itemdata.defultype_id`, and is declared a HEURISTIC
> PRE-CHECK.** Both halves of that sentence are load-bearing:
>
> - **Why `defultype_id`:** it is the only unit-load type knowable when a configuration is written. A
>   configuration has no advice positions yet, and future ones do not exist to enumerate. Keying on
>   `adviceposition.unitloadtypeId` would make P2.6 unevaluable at write time — the one place it runs.
> - **Why heuristic, stated plainly:** receiving takes the actual type from
>   `adviceposition.getUnitloadtypeId()` (`ReceivingService:399`), which is operator/EDI-supplied per
>   advice. **So P2.6 passing does NOT guarantee the receipt passes**, and P2.6 is therefore *not* an
>   authority — the runtime check at `UnitloadBusinessService:188-237` is. P2.6's job is to move the
>   common failure out of the receipt and into the config dialog, not to make the failure class
>   unreachable. §3.1.2 already says the same thing about receive-time P1; this makes it explicit at
>   write time too.
> - **What was rejected, and why:** enumerating *every* type an advice *could* carry. A flowbin permits
>   only `PickLocation`, so that reading rejects nearly every pick-face configuration — including
>   `ICE PACK` — and would re-create SBDEV-2731 at config time. It also cannot be tested meaningfully:
>   the enumerated set would be "all unit-load types", making P2.6 equivalent to "the destination
>   permits everything".
> - **Divergence is observable, not silent:** a receipt whose advice carries a type that write-time P2.6
>   did not see fails at the runtime check with the actionable `putawayDestinationNotPermitted` message
>   (§3.1.3), naming the configured tier. That is the intended fallback, not a gap.
>
> **Corrected alongside:** this box's own opening sentence attributes `defultype_id` to `ICE PACK` the
> *location*. The column exists only on `itemdata` — the substance (a `Case` unit load against a
> `PickLocation`-only flowbin) is right, the attribution was not. Do not let it become a test fixture.
>
> **Test consequence:** §7.1's P2.6 tests must assert against `itemdata.defultype_id` and must **not**
> assert that a P2.6 pass implies a receive-time pass. A test asserting the latter encodes a guarantee
> this plan explicitly declines to make.

> **`Club08` passes P1 only by accident** — `cases and pallets` has **zero** `location_constraint` rows, so
> P1 fails *open*. Do not mistake that for the rule working.
>
> **Fail-open is not a hazard to fix here, and this is the one property to preserve.** Write-time P1 and
> runtime P1 are the same code over the same table, so they fail open together — write-time is never
> *stricter* than runtime, which is the invariant that matters. It is wide (`NoRestriction` 122 + `System` 20
> + `cases and pallets` 510 = **652 of 2,739** locations on `wms2-wineco-dev`), but the real gate for those
> is `storeBoxOnLocation`'s switch coverage, not `location_constraint`. **Making write-time stricter than
> runtime is how SBDEV-2731 comes back.**

#### 3.4c Predicate P2 (suitability) — config-write time only

The ticket's "*Be active*" has no column (§2.3). P2 is the concrete replacement, evaluated **only** when a configuration is written:

| # | Check | Source |
|---|---|---|
| P2.1 | the `location` row resolves by id | `locationRepository.findById` |
| P2.2 | `entityLock == BusinessObjectLockState.NOT_LOCKED` | closest proxy for "active"; `WmsConstants.java:1188-1195` |
| P2.3 | none of `staginglane / transferlane / automationlane / crossdockinglane / gate` is `TRUE` | `model/Location.java:33-41` |
| P2.4 | its `location_area` has `useforgoodsin == TRUE` **OR** `useforstorage == TRUE` | **OR, not AND, and not `useforstorage` alone** — `PutAwayLane` on `wh01_hydra_v2t` sits in area `Inbound` with `useforstorage=false, useforgoodsin=true`. This is also why the Phase-2 picker must **not** be built on `LocationRepository.getStorageLocationsForPutAwayItemData` (`:104-111`), whose native predicate is `location_area.useforstorage='true'` and which therefore **can never return `PutAwayLane`** (§0.1 row 34). |
| P2.5 | no `FixLocationAssignment` on the destination | **⚠ DROPPED 2026-08-08 (Q12 → iv-b) — this is NO LONGER a write-time reject at any scope. Do not implement it; the historical rationale is retained below because it explains why the runtime gate in step 15 must ship in the same change.** ~~Absolute reject at all three scopes~~ — `fixLocationAssignmentRepository.findByAssignedlocationId(destId).isPresent()` ⇒ reject. Structurally safe to treat as a single-row test: `fix_location_assignment` carries `UNIQUE (assignedlocation_id)` **and** `UNIQUE (itemdata_id)` (`V2.2.00__base_v2_schema.sql:3760-3763`, `:3712-3715`), so a location has at most one assignment and a SKU at most one pick face — the `Optional`-returning finder can never raise `IncorrectResultSizeDataAccessException`. **⚠ This is DELIBERATELY STRICTER THAN THE RUNTIME CHECK, and that is the whole mechanism enforcing D15.** At runtime `UnitloadBusinessService.java:178-184` rejects only on *SKU mismatch* (`WRONG_ITEMDATA_FIXASSIGNMENT`), so pointing a SKU at *its own* pick face is legal there — and SBDEV-2796's answer (c) says it is a legitimate operation. This plan nonetheless refuses to **write** that configuration, because tier-1 pick-face placement is deferred (D15) and `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally: there is no runtime gate to stop it, so **refusing the config is the only thing that keeps the deferred path unreachable.** **⚠ REVISED 2026-08-08.** This previously read *"SBDEV-2821 must relax this to the mismatch-only form as part of shipping tier-1 placement, not before"* — which assumed 2821 would ship direct placement. **Under 2821's adopted option (iii) it will not.** Neither live override carries an FLA, so **P2.5's relaxation is not required by (iii) at all**; the predicate that actually blocks those configs is P2.7(c) clause 1. Relaxing P2.5 to the mismatch-only form remains *optional and harmless* (it mirrors the runtime rule at `UnitloadBusinessService.java:178-184`), but it is **not** what unblocks anything. See the conflict box under P2.7(c). *(A 2026-08-04 revision briefly made P2.5 mismatch-only; reverted the same day — it permitted the config while the placement path stayed ungated, which put a second unit load on a location whose `assignedunitload_id` is `UNIQUE`. See §12.)* Do **not** add a carrier clause here: `:173-176`'s `CARRIER_NOT_ON_FIXLOC` fires when the *moved unit load has child unit loads*, not on the receipt's `carrier` parameter — it has no write-time inputs and is unreachable from `receiveGoods`, whose UL is freshly created at `ReceivingService.java:474`. |
| P2.6 | **P1** holds for `itemdata.defultype_id` across the scope — **a heuristic pre-check, not a guarantee** (resolved 2026-08-09; see the box below) | see below |

#### P2.7 — tiers 2 and 3 destination rules (D13) — ⚠ RE-FRAMED 2026-08-08 (Q12 → iv-b)

> **D13 was a CONFIGURATION rule because direct placement was ungated. Under (iv-b) it becomes a PLACEMENT
> rule, and the enforcement point moves from write-time to run-time.**
>
> - **What may be CONFIGURED** — widened. Any tier may name any location putaway can legitimately receive
>   into, **pick faces included**. Rule **(c)'s absolute pick-face / fix-assignment reject is DROPPED at all
>   three scopes**; it was the mechanism gating a placement path that is now gated directly.
> - **What may be PLACED AT RECEIPT** — unchanged in spirit, and now explicit: staging, goods-in and
>   cross-dock destinations are placed directly (rules (a), (b), (d) below). **Pick faces are not** — step 15's
>   `useforpicking` gate diverts them to the lane for putaway to route.
> - **P2.1–P2.4 and P2.6 are untouched** and still reject locked, shipping, transfer and gate locations. Those
>   are wrong destinations for putaway as much as for receiving.
>
> The rules below are otherwise retained, including the measured justification in the CORRECTION note.

**Merchant- and warehouse-scope destinations must satisfy ALL of:**

| | Rule for tiers 2/3 | Why |
|---|---|---|
| a | `staginglane` **or** `crossdockinglane` **may be TRUE** — these are *permitted*, not banned | They **are** the use case. The ticket's named tier-2 scenarios are "Club assembly lane" and "Cross-dock or fast-turn staging area". |
| b | `transferlane`, `automationlane`, `gate` must be FALSE | Not receipt destinations; `gate` is truck loading. |
| c | ⛔ **DROPPED 2026-08-08 (Q12 → iv-b) — DO NOT IMPLEMENT THIS REJECT.** This row read *"**not** a pick face (`area.getUseforpicking()` ⇒ reject) and **not** fix-assigned … Absolute at all three scopes"*. **A pick-face or fix-assigned destination is now a LEGAL configuration at every scope.** What is refused is the *placement*, by the runtime gate in receiving (§5.2 step 15). **Implementing this row as written re-breaks SBDEV-2731's reported bug** — it is what stopped `ICE PACK` being configurable. | **Canonical status: this row.** Do not restate it elsewhere; §3.4c is the single authoritative statement. The only surviving scope restriction is **rule (e)** below, which bars `flowbin`-*type* destinations at merchant/warehouse scope for a different reason (FLA auto-binding). |

> [!done] **✅ Q12 ANSWERED 2026-08-08 — option (iv-b), SPLIT: configure anywhere; place everywhere EXCEPT pick faces.**
>
> **Configuration (write-time) — relaxed, with ONE narrow exception.** Any tier may name any location putaway
> can legitimately receive into, **pick faces included** — except that **tiers 2/3 may not target a
> `flowbin`-type location** (P2.7 rule **e**), because putaway auto-creates a `FixLocationAssignment` binding
> it to the first SKU and multi-SKU scopes then break. **Tier 1 is exempt, and club lanes are unaffected**
> (they are `cases and pallets`, not `flowbin`). P2.1–P2.4 and P2.6 still reject locked, shipping, transfer and gate
> locations — wrong destinations for putaway too. **P2.7(c)'s absolute pick-face / fix-assignment reject is
> dropped at all three scopes.**
>
> **Placement (run-time), when `carrier == null` — split on one predicate:**
>
> | Resolved destination | Receiving does | Then |
> |---|---|---|
> | **pick face** — `area.useforpicking == TRUE` **OR** `location_type.sltname == 'flowbin'` | **does NOT place** — receipt goes to the standard putaway lane | destination consumed at **putaway** (SBDEV-2821) |
> | anything else — staging, goods-in, cross-dock | **places directly**, as today | no putaway step |
>
> **Why split rather than uniform.** Cross-dock and staging lanes genuinely want the stock placed immediately —
> that is the ticket's "fast-turn" intent — and they carry none of the pick-face risk. Uniform (iv-a) would
> have silently dropped that. The split costs one predicate at one call site.
>
> **The club use case ships — but NOT on this plan alone.** Club lanes are pick faces (`useforpicking = true`,
> verified on `wsl-wineco-uat`), so a merchant default of `CLUB-A` is configurable and receiving diverts it to
> the lane. **No stock lands on a live 27-SKU pick face at receipt, and C2b stays unreachable.**
> 
> ⚠ **But two other things must ship before it works end to end, and neither is in this plan's original scope:**
> 1. **`MobilePutAwayService` must handle `cases and pallets`.** ✅ **CONFIRMED BY TEST 2026-08-09** — SBDEV-2821's
>    M1b was run on `wsl-wineco-uat`: the scan of `Club08` was **accepted** and the store then threw
>    **`Unsupported location type cases and pallets`**. This is measured, not inferred. Its switch covers only `flowbin`, `overstock
>    box` and `overstock pallet` (`WmsConstants:736-738`); `cases and pallets` is a fourth constant (`:741`)
>    and falls to `default:`, which **throws** for club locations. **Owned by SBDEV-2821 §3.2a** as of
>    2026-08-08. Until it ships, a club destination saves, diverts, and then **throws at putaway**.
> 2. **Putaway must offer the destination for tiers 2/3** — SBDEV-2821 surfaces it for tier 1 only.
>    **Step 17a of this plan**, and it depends on 2821 merging first.
> 
> Earlier revisions of this box asserted the club case *"ships, safely"* on this plan alone. **That was
> false** — it assumed `storeBoxOnLocation` already handled the type, which it does not.
>
> *Provenance: (iv-b) chosen by the ticket owner (Nam Park) 2026-08-08, following SBDEV-2821's option (iii),
> and **reaffirmed 2026-08-09. This is the decision — Q12 is CLOSED and blocks nothing.** It was put to
> @David Oppenheim and @Brent Campbell on the ticket 2026-08-08 with no reply recorded; that is an
> outstanding **notification**, not a pending approval. Precedent: SBDEV-2821's Q4 shipped on David's
> endorsement plus owner direction, with no Brent reply. If either objects later, Q12 reopens — options
> (i)–(iii) and (iv-a) are preserved in §10.4.*
>
> **⚠ THE RELAXATION AND THE GATE ARE ONE CHANGE.** P2.5/P2.7(c) were absolute for exactly one stated reason —
> *"`ReceivingService.java:454-457 → :491` places tier-1 destinations unconditionally… refusing the config is
> the only thing that keeps the deferred path unreachable."* Under (iv-b) the runtime gate replaces that
> mechanism, so **the gate must land in the same change as the relaxation.** A 2026-08-04 revision relaxed the
> predicates while the placement path stayed ungated and was reverted the same day (§12) — the failure mode is
> identical, and it is SBDEV-2731's reported bug. `pickFaceDestinationIsNotPlacedAtReceipt` (step 15) is the
> test that keeps them coupled.

> **"Not a pick face" is `location_area.useforpicking`. Added 2026-08-06 — until then this clause had NO
> implementable predicate anywhere in this plan, while §7.1 mandated a test (`skuWriteRejectsPickFaceDestination`)
> that could not be written.** Only the fix-assignment clause was concrete, so in practice P2.7(c) enforced
> half of what it claims and D15's by-construction guarantee rested on that half.
>
> `useforpicking` is this codebase's existing answer to "is this a pick face", not a new invention:
> `MobilePickingService.java:1193`, `StockunitRepository.java:119,134,149,248`,
> `ReplenishmentMonitorViewRepository.java:73`, and — decisively — **SBDEV-2854** adopts exactly this axis
> for the mirror-image question on the replenishment side (`isPickingArea`, destination `useforpicking` ::
> source `useforreplenish`). Using the same column keeps the two features from answering "can this location
> take stock" differently.
>
> **SBDEV-2854 also proves the gap was populated, not theoretical.** Its `db_verified` data records **70
> wineco club locations** in area *"Storage and Picking"* with `useforpicking = true` and **zero**
> `FixLocationAssignment` rows — FLA-free pick faces at scale on a client tenant. `Club01` (id 225748) clears
> P2.3 (no lane flags), P2.5 (no FLA) and P2.7(c)-as-previously-implementable. Since **direct placement ships
> for tiers 2/3 in this plan**, a warehouse- or merchant-scope default pointed at a club location would have
> put receipts straight onto a live pick face — a route none of the SBDEV-2821 hand-off warnings cover,
> because those are all written about *tier 1* and about *relaxing* P2.5/P2.7(c). Nothing is relaxed here;
> the predicate simply never existed.
>
> **MEASURED 2026-08-06 — the hazard is LIVE, including on production.** `Storage and Picking` carries
> `useforstorage = TRUE` **and** `useforpicking = TRUE`, so club locations clear P2.4. Verified SELECT-only:
>
> | Tenant | `useforstorage` | Locations in picking areas | **FLA-free (the exposed set)** |
> |---|---|---|---|
> | `wsl-wineco-uat` | TRUE (area 51553) | 2,219 | **726** |
> | `wms2-wineco-dev` | TRUE (area 51553) | same area config | same shape |
> | **`wms2-hydra` (HMG/NYWH PRD)** | **TRUE** | 191 | **58** |
> | `wms2-hydra-v2t` (fresh-seeded) | — no picking area is also storage/goods-in | 0 | **0** |
>
> `Club01`–`Club08` (ids 225748+) each read: area 51553, all five lane flags FALSE, `entity_lock = 0`,
> **`fla_rows = 0`** — so they pass P2.2, P2.3, P2.4, P2.5 and P2.7(c)-as-previously-implementable, every one.
>
> **The exposed set is 726 locations on wineco UAT and 58 on HMG production — not the ~70 clubs inferred from
> SBDEV-2854's plan.** Any of them was a legal tier-2/3 default under the old predicate set, and tiers 2/3
> ship direct placement.
>
> **Why this was missed, and the lesson for every future P2 measurement:** §3.4c's P2.7 "CORRECTION" was
> measured on `wh01_hydra_v2t` — the fresh-seeded copy, and per the last row **the one tenant that
> structurally cannot exhibit this**. A predicate validated only against fresh-seed data is validated
> against the case that cannot fail. **Re-run every P2 measurement against a migrated tenant (`wineco`,
> `hydra` PRD) as well as `v2t`.** Reproduce with:
> ```sql
> SELECT a.name, a.useforgoodsin, a.useforstorage, a.useforpicking, count(*) AS locations,
>        count(*) FILTER (WHERE f.id IS NULL) AS fla_free
> FROM location l JOIN location_area a ON a.id = l.area_id
> LEFT JOIN fix_location_assignment f ON f.assignedlocation_id = l.id
> WHERE a.useforpicking = true GROUP BY 1,2,3,4 ORDER BY 1;
> ```
| d | P2.4's area test is **relaxed for tiers 2/3**: a staging or cross-dock lane qualifies **regardless** of its area's `useforgoodsin`/`useforstorage` flags | Measured necessity, not preference — see the correction immediately below. |
| **e** | **tiers 2/3 may NOT target a `flowbin`-type location** (`location_type.sltname == 'flowbin'` ⇒ reject). **Tier 1 is exempt.** | **ADDED 2026-08-08.** Not a placement rule — a *multi-SKU* rule, and the only restriction (iv-b) reinstates. See the box below. |

> [!warning] **Why rule (e) exists — FLA auto-creation binds a location to ONE SKU, permanently.**
>
> (iv-b) widened configuration at every scope, which re-opened a hazard that P2.5's absolute reject had been
> closing **as a side effect**. It is not a placement problem — the runtime gate handles that — so removing
> the gate's justification did not remove this.
>
> **The mechanism.** A tier-2/3 default resolves to an FLA-free flowbin. Receiving diverts it to the lane
> (step 15). At putaway, `MobilePutAwayService.storeBoxOnLocation:499-506` **auto-creates** a
> `FixLocationAssignment` binding that location to **whichever SKU is put away first**. The table carries
> `UNIQUE (assignedlocation_id)` **and** `UNIQUE (itemdata_id)`
> (`V2.2.00__base_v2_schema.sql:3760-3763`, `:3712-3715`). **Every subsequent SKU under that default then
> fails** — at `verifyScannedLocation:447-453` or `UnitloadBusinessService:180-183`.
>
> **Blast radius is the whole scope, not one SKU.** A merchant default applies to every SKU that merchant
> receives; the first one silently claims the bin and the rest break. A warehouse default is worse.
>
> **Measured exposure** (SELECT-only, 2026-08-08), FLA-free flowbins reachable as a tier-2/3 destination:
>
> | Tenant | flowbin (FLA-free) | `cases and pallets` (FLA-free) |
> |---|---|---|
> | `wms2-hydra` (HMG PRD) | **46** | 0 — none exist |
> | `wsl-wineco-uat` | **656** | 70 (the club lanes) |
>
> **Why tier 1 is exempt, and why this costs the club use case nothing.** A *SKU-scope* default binding its
> own location to itself is precisely the intent — that is what a dedicated `ICE PACK` bin **is**, and it is
> the runtime rule already (`UnitloadBusinessService.java:178-184` rejects only on SKU *mismatch*). And the
> club lanes are **`cases and pallets`, not `flowbin`** — `storeBoxOnLocation` never reaches the FLA branch
> for them, so they are unaffected by rule (e). **The 656 hazardous locations are excluded; the 70 clubs are
> not.** Rule (e) closes the hazard without touching the use case Q12 was asked about.
>
> **Do not implement this as "reject pick faces at tiers 2/3."** That would re-ban the clubs and undo Q12.
> The predicate is the **location type**, not the area flag: `sltname == 'flowbin'`.

| **f** | **TIER 1 must reject a flowbin whose `FixLocationAssignment` belongs to a DIFFERENT SKU**, and reject a SKU whose own FLA is on a different location. Tier 1 stays exempt from rule (e) itself. | **ADDED 2026-08-09 by review.** Rule (e)'s tier-1 exemption is *strictly weaker than the runtime rule it claims to mirror*. See the box below. |

> [!warning] **Why rule (f) exists — the tier-1 exemption does NOT mirror the runtime rule, it is weaker.**
>
> Rule (e)'s rationale says tier 1 is exempt because it *"is the runtime rule already
> (`UnitloadBusinessService.java:178-184` rejects only on SKU **mismatch**)"*. **An unconditional exemption
> does not reject on mismatch at all.** As written, nothing at write time stops SKU `A`'s tier-1 default
> naming a flowbin whose FLA belongs to SKU `B`, or two SKUs naming the same FLA-free flowbin. The
> exemption's own justification argues *for* implementing the mismatch check, not for omitting it.
>
> **The population is large and already exists:**
>
> | Tenant | flowbins | already FLA-bound |
> |---|---|---|
> | `wms2-wineco-dev` | 2,068 | **1,344 (65%)** |
> | `wms2-hydra-dev2` | 496 | **154 (31%)** |
>
> Every one is a legal tier-1 target for the ~8,800 / ~2,720 SKUs that do not own it.
>
> **The failure is late, silent at write time, and permanent.** The config saves; receipts divert to the lane
> (step 15); then **every putaway of that SKU fails at the scan** — `verifyScannedLocation:444`
> (`itemDataNotMatchFixedAssignment`) or `:441` (`scannedLocationHasDifferentFixedAssignment`) — with nothing
> naming the configuration that caused it.
>
> **Note the enforcement asymmetry.** `storeBoxOnLocation`'s flowbin branch calls `transferStockToUnitLoad`,
> **not** `transferUnitLoadToLocation`, so it never reaches `UnitloadBusinessService:169-185`.
> `verifyScannedLocation` is the *only* guard, and it is a **separate REST call**
> (`PutawayController:100` vs `:114`). `transferStockToUnitLoad`'s mixed-stock guards (`:236`, `:266`) both
> short-circuit when the destination UL is empty, so a *depleted* fix-assigned bin would accept a foreign
> SKU's stock silently while the FLA still names the original SKU. Pre-existing, and zero such bins on
> `wms2-wineco-dev` today — but tier-1 configuration at scale is what makes it reachable.
>
> **Implement as the mismatch-only form of P2.5, at SKU scope:**
> ```java
> // reject if the destination bears an FLA for a different SKU
> fixLocationAssignmentRepository.findByAssignedlocationId(destId)
>     .filter(fla -> !fla.getItemdataId().equals(itemdataId))
>     .ifPresent(fla -> reject(FIX_ASSIGNED_TO_OTHER_SKU));
> // reject if this SKU already owns a different pick face (mirrors verifyScannedLocation:437-445
> // and StockunitService:186-190's "SKU already assigned to flow bin")
> fixLocationAssignmentRepository.findByItemdataId(itemdataId)
>     .filter(fla -> !fla.getAssignedlocationId().equals(destId))
>     .ifPresent(fla -> reject(SKU_ALREADY_ASSIGNED_ELSEWHERE));
> ```
> Costs one repository call you already make. **§3.4c's P2.5 row calls this relaxation "optional and
> harmless" — it is neither. It is the tier-1 half of rule (e),** and the `UNIQUE` constraints
> (`assignedlocation_id`, `itemdata_id`) make both checks single-row and exact.
>
> ✅ **Already proven in code.** SBDEV-2821 shipped precisely this predicate as SQL on the method 2732
> inherits — `LocationRepository.getPutAwayCandidateLocations`'s second leg carries
> `AND NOT EXISTS (SELECT 1 FROM fix_location_assignment fla WHERE fla.assignedlocation_id = l.id AND
> fla.itemdata_id <> :itemDataId)`, verified against live data (own pick face admitted, foreign one
> excluded). **2732 must not weaken that clause when it extends the method to tiers 2–4.**

> [!note] **Gap 2 — rule (e) does not cover a pre-existing FLA on a NON-flowbin type at tiers 2/3.**
>
> Rule (e) closes FLA *auto-creation*, which is flowbin-only — verified: all the
> `createFixedLocationAssignment` call sites checked (`MobilePutAwayService:481`,
> `MobileMoveStockService:274`, `MobileMoveUnitloadService:345`, `StockunitService:193`) are gated on
> `sltname == 'flowbin'`. But `UnitloadBusinessService:169-185` enforces FLA SKU-match on **any** location
> type. Currently unpopulated — every FLA row on both measured tenants sits on a flowbin — so this is low
> severity. **The complete tier-2/3 statement is "reject any FLA-bearing destination (old P2.5) AND any
> flowbin (rule e)".** Rule (e) alone is half of it.

> [!note] **Gap 3 — P2.4 and putaway's own area gate disagree.**
>
> `verifyScannedLocation:427` requires `area.useforstorage == TRUE || location.staginglane`. **P2.4 admits
> `useforgoodsin` OR `useforstorage`.** A goods-in-only pick face therefore saves, diverts, and then throws
> `locationNotUsableForStorage` at putaway. Empty on both reachable tenants — every `useforpicking` area also
> carries `useforstorage = TRUE` — so this is *data, not structure*, which is the same shape as the miss that
> produced the 656-flowbin surprise. **SBDEV-2821 already aligned its candidate query to
> `verifyScannedLocation`'s gate; P2.4 should say why it deliberately differs, or match it.

> [!important] **THREE PREDICATES, NOT ONE — and one of the three call sites had the wrong one.**
> **Added 2026-08-09 by review.** This plan uses two genuinely different "is this a pick face" tests. They
> look interchangeable and are not. Name them separately in code so nobody "harmonises" them later.
>
> | Call site | What it actually tracks | Correct predicate | Was |
> |---|---|---|---|
> | **P2.7 rule (e)** — tiers 2/3 flowbin reject | FLA **auto-binding** (flowbin-only branch) | `sltname == 'flowbin'` | ✅ correct |
> | **P1 skip** (§3.4b) — config-write | putaway **merges into a resident UL** instead of transferring a whole UL | `sltname == 'flowbin'` | ❌ **was `useforpicking OR flowbin`** |
> | **Step 15 placement gate** (§5.2) — receive | *don't drop a whole UL onto a live pick face* — an **area** property | `useforpicking OR sltname == 'flowbin'` | ✅ correct |
>
> Suggested names: **`isFlaAutoBindingLocation(loc)`** (rows 1–2) and **`isPickFaceForPlacement(loc)`**
> (row 3). The step-15 gate's `OR` is deliberate and stays — the reported failure is a location-*type*
> property while `useforpicking` is an *area* property, and nothing in the schema ties them.

> [!warning] **SBDEV-2643's picker must exclude flowbins bound to another SKU — and the enum is THIS plan's.**
> **Added 2026-08-09 by review.**
>
> 2643 r3 reverts D1 and offers pick faces again, which is correct under (iv-b). But with rule (f) in place
> the picker must not offer a flowbin already bound to a *different* SKU — those rows save cleanly and then
> fail at **every** putaway, which is worse than r1's "offers rows that cannot be saved" because the failure
> is deferred and detached from its cause.
>
> | Tenant | rows the picker would offer | of which fix-assigned flowbins |
> |---|---|---|
> | `wms2-wineco-dev` | 2,555 | **1,344 (53%)** |
> | `wms2-hydra-dev2` | 603 | **154 (26%)** |
>
> **`blockingReason` is this plan's enum** (§3.5a), currently `LOCKED | FIX_ASSIGNED | LANE | null`. It needs
> a value meaning *"fix-assigned to a different SKU"* — 2643 cannot add it from its own PR (its MUST-4), so
> **this plan owns the change.** `FIX_ASSIGNED` already exists and can carry it if the message distinguishes
> own-vs-foreign.
>
> **Also for 2643:** the exclusion set is not empty anywhere once rule (f) applies. The r3 banner's claim
> that *"on HMG production the exclusion set is empty — every candidate qualifies"* stops being true.

> [!note] **A measurement dispute this plan should settle.** The 2026-08-09 review brief recorded *"r2's
> population of 603 matches none of these three tenants, so its numbers came from somewhere else again and
> are treated as unusable."* **That is wrong and should not be propagated.** r2's chain reproduces exactly on
> `wms2-hydra-dev2` (`wh01_hydra_v2`), the tenant 2643's own `db_verified_note` names: 666 total → **603**
> pass P2.2+P2.3+P2.4 → **511** in a `useforpicking` area (496 flowbin + 12 overstock box + 3 overstock
> pallet) → **92** remain; **154** fix-assigned. All five figures re-derived independently. r2's numbers are
> **stale-by-design-change, not misattributed.** The brief's own "HMG PRD" row (229/191/229) is a *different
> database* — hydra **production** — and labelling both "HMG" is what made them look reconcilable. Keep the
> PRD-vs-DEV distinction explicit: they differ ~3× on flowbin count (46 FLA-free on PRD vs 342 on dev2).**

**CORRECTION — the first version of P2.7 was self-defeating, and the data proves it.** It said "restricted
to staging / goods-in area types" while P2.3 rejected any location with `staginglane = TRUE` and P2.4
required the *area* to be `useforgoodsin OR useforstorage`. Measured on `wh01_hydra_v2t` (all 35 locations
joined to their areas): all **6** staging lanes sit in areas that are **neither** goods-in nor storage, so
they failed P2.4 *and* were banned outright by P2.3; the only P2.4-passing locations were the **3**
goods-in ones — the Inbound area, which contains `PutAwayLane` itself. **Under the three predicates
together a merchant or warehouse default could be set to essentially nothing except the tier-4 lane it
would have fallen through to anyway.** That is tension T1 recurring one predicate later: the gate that
makes pre-mortem P3 survivable is again the one that makes the tier settable only to what you already had,
and it banned precisely the two scenarios the ticket names. Rules (a) and (d) above are the fix.

**Recompute the admissible set per tenant before implementing** — as §3.4c already does for D11. If it is
still ≈1 on a real tenant, D13 needs rethinking rather than documenting. *(Caveat: `wh01_hydra_v2t` is a
35-location fresh-seeded copy and is not PRD-representative; the contradiction was between three
predicates over two columns, not an artifact of that data.)*

Tier 1 (SKU) is **exempt** from (a), (b) and (d).

> **⚠ SUPERSEDED 2026-08-08 (Q12 → iv-b).** This paragraph read *"exempt from (a), (b) and (d) — **but NOT
> from (c)**, deliberately. Rule (c) is the D15 enforcement point: tier 1 … may not target a pick face or a
> fix-assigned location while tier-1 placement is deferred."* **Rule (c) is now dropped at ALL scopes, tier 1
> included** — see the canonical P2.5 row in this section's table. Tier-1 placement is not "deferred" any
> more; under (iv-b) **no** tier is directly placed at a pick face, so the write-time reject that stood in
> for a runtime gate is gone and the gate itself does the work (§5.2 step 15).
>
> *(Historical note retained: a 2026-08-04 revision briefly added (c) to this exemption list and was reverted
> the same day — because at that time the placement path really was ungated. It is gated now. See §12.)*

**Why.** SBDEV-2731's Architect review found (F3) that `FixLocationAssignment` carries
`lowerbound`/`middlebound`/`upperbound` (`model/FixLocationAssignment.java:19,22,25`), seeded **36 / 60 /
84 on PRD**, and that `transferStockToUnitLoad` has **no capacity gate anywhere**. So a 1,000-unit receipt
directed at that pick face loads it to roughly **12x its configured ceiling**, after which replenishment
logic keyed on those bounds sees a permanently over-bound bin. Its verdict: *"receive 1,000 ice packs
directly into a pick face may be the wrong operation regardless of which primitive is used."*
D2 direct placement does exactly that, and this plan had **no capacity concept at all**.

Restricting tiers 2/3 to staging / goods-in areas is where the ticket's club and fast-turn use cases
actually live — so no business capability is lost. It also **subsumes the H1 lock mitigation**: keeping
receiving off live pick faces is the same outcome the tiered picker was reaching for, so implement it
once, here, and have the §3.11.5 picker simply reflect it at merchant/warehouse scope (rendered by
§3.11.2 and §3.11.3).

> **D13's justification changed on 2026-08-04 — keep the rule, drop the reason.** D13 was originally
> justified as *"sidesteps F3 without inventing a capacity subsystem."* SBDEV-2796's answer (c) makes
> bounds advisory at receive time, so **there is no longer an F3 to sidestep** and that argument no longer
> supports anything. D13 should stand on its two surviving grounds — it is where the named use cases live,
> and it subsumes the H1 lock mitigation — **not** on capacity. Anyone revisiting D13 must not resurrect
> the F3 rationale.

> **RESOLVED 2026-08-04 — capacity is deliberately NOT handled, by product decision.**
> Tier 1 is exempt because a SKU-level override is the operator's explicit per-SKU choice. **The reported
> ICE PACK failure is precisely that case** — 1,000 units into a flowbin pick face via a tier-1 override.
>
> [SBDEV-2796](https://app.clickup.com/t/868kk4rmv) answered the F3 / Q5 product question with
> **(c): the pick face is a valid destination and the bounds are advisory for receiving.** So:
>
> - **No capacity gate is built.** `FixLocationAssignment.lowerbound`/`middlebound`/`upperbound` are
>   **not** consulted before `transferStockToUnitLoad`. A 1,000-unit receipt into an 84-capacity bin
>   **succeeds**, and the resulting ~12× over-bound bin is an **accepted state**, not a defect.
> - **The tier-1 block is lifted.** Direct placement may ship for tier-1 destinations. *(The block was
>   written as "blocks Phase 1b"; that split no longer exists — §5.2 — and direct placement is in
>   Phase 1-API.)*
> - **(c) obliges this plan to document the accepted state**, which is what this block now does, and to
>   surface it: the over-bound outcome must be visible in the §3.13 metrics/log so an over-bound bin is
>   *observable* even though it is permitted. Silence was never part of the decision.
>
> ⚠ **What (c) did NOT answer, and what therefore still gates the tier-1 path.** Two SBDEV-2796
> acceptance criteria survive its own answer:
>
> 1. **Replenishment behaviour against a permanently over-bound bin is still undefined.** Replenishment
>    keys off the very bounds (c) just made advisory for receiving — `recalculateForItem` maintains orders
>    from them. (c) makes over-bound bins reachable *and* permanent, so the "or make them unreachable"
>    escape is gone. **Nobody owns this.** Referred back to the B/A — §8.4.
> 2. **C2b** — the destructive `Goodsreceiptposition` repointing — is neither resolved nor ruled out by
>    (c). It is now **live and blocking** for the surviving Fix B work. See §5.2 D14 IMPORT LIMIT and §6.
>
> **DEFERRED under D15 (2026-08-04).** Rather than absorb (1) and (2), the author deferred the whole
> tier-1 pick-face path to a follow-up ticket — **[SBDEV-2821](https://app.clickup.com/t/868km8j9z)**. **This
> plan therefore ships direct placement for non-pick-face destinations only**, at any tier *(⚠ 2026-08-08: was "tiers 2/3 only" — the split is on the destination)*, and neither (1) nor (2) gates it — no pick-face placement means no over-bound bin and no
> repointing. Both travel to the follow-up, along with C2b, Q1, Q4, F1, F4 and F5. The P2.5 / P2.7(c)
> corrections below still land here, so the follow-up inherits a validator that admits the configuration
> (c) authorises.

**P2.6 is what moves the failure out of the receipt and into the config dialog.** `adviceposition.unitloadtypeId` is derived from `itemdata.getDefultypeId()` (`ReceivingService.java:227 → :236`, `:279 → :288`), so the incompatible pair *(SKU's default unit-load type, configured destination's location type)* is fully determinable **before any receipt exists**. It does not make the failure class unreachable — D11 deliberately lets an admin accept a partially-incompatible destination — but it does guarantee nobody meets it for the first time mid-receipt.

**Per-scope rule (D11):**

- **SKU scope** — one pair: `P1(destination.typeId, itemdata.defultypeId)`. **An absolute reject —
  but only where P1 is evaluated at all.** Blast radius is one SKU, so where it applies there is
  nothing to trade off.

  > [!warning] **⚠ ORDERING, ADDED 2026-08-09 — the P1 skip runs BEFORE P2.6/D11, not after.**
  >
  > Read without this, D11 contradicts (iv-b) and re-blocks the parent bug. §3.4b skips P1 entirely when
  > the destination's `location_type.sltname == 'flowbin'`. `ICE PACK` is `Case` (`defultype_id = 4`) into
  > a flowbin that permits only `PickLocation` — so an *unskipped* P1 rejects it, and **"absolute reject"
  > at SKU scope would refuse the exact configuration SBDEV-2731 exists to make savable**, which
  > SBDEV-2643 r3/r5 depends on being legal.
  >
  > **Correct evaluation order at write time:** resolve the destination → **if `sltname == 'flowbin'`,
  > P1 and therefore P2.6 are SKIPPED for that destination** → otherwise evaluate P2.6, and at SKU scope
  > a failure is an absolute reject. The skip is `sltname == 'flowbin'` **only**, never the
  > `useforpicking` form (§3.4b).
  >
  > Test consequence: `skuWritePermitsPickFaceDestination` (§7.1) is the test that pins this. If it fails
  > while a D11 test passes, D11 was implemented ahead of the skip.
- **Merchant scope** — evaluate against `SELECT DISTINCT defultype_id FROM itemdata WHERE client_id = ?`.
  Return the **count of incompatible SKUs** and one example. **Reject outright only at 100 %
  incompatibility**; otherwise accept on **explicit admin confirmation**
  (`PUT …?confirmIncompatibleSkus=<n>` must match the count the **writer** recomputes at write time — not
  merely the count the preview returned — so a stale confirmation cannot slip through. §3.5a).
- **Warehouse scope** — same, against `SELECT DISTINCT defultype_id FROM itemdata`.

**Why count-and-confirm rather than an absolute reject.** The live allow-list is narrow —
`flowbin→PickLocation` only, `overstock box→Case` only, `totes→Tote` only, `packages→Package` only — so on
a tenant with a normal Case/Pallet/Tote/Package mix the only location types compatible with *every* SKU
are the fail-open ones (`System`, `NoRestriction`) and `cases and pallets`. **On `wh01_hydra_v2t` that is
exactly `PutAwayLane`'s own type (7).** An absolute reject would therefore make the warehouse tier
settable only to something type-equivalent to the lane you already had — turning "ships inert"
(pre-mortem P2) from a rollout risk into a *structural certainty*. Count-and-confirm keeps the write-time
gate loud without making the feature unusable.

**Admissible-set size.** On `wh01_hydra_v2t`,
`location_type` has 8 rows; the types compatible with all of `{Case, Pallet, Tote, Package}` are
`{System, NoRestriction, cases and pallets}` = **3 of 8**, and only one of those three is a location an
operator would plausibly choose. Under D11 the admissible set becomes *every* location type, ranked by
incompatible-SKU count, with 100 %-incompatible ones still refused. **Implementation note:** compute this
per tenant at validation time — do not hard-code 3/8, which is one tenant's arithmetic.

**Scope limit on the relaxation.** D11 relaxes the **unit-load-type compatibility** predicate only. A
**locked** destination (`entityLock != NOT_LOCKED`) remains an **absolute reject at all three scopes**,
validated at write time for merchant and warehouse as well as SKU.

> **⚠ CORRECTED 2026-08-08 (Q12 → iv-b).** This paragraph also listed a **fix-assigned** destination as an
> absolute reject, on the reasoning that it "can never work for any SKU". **That is no longer true and is no
> longer the design.** P2.5 is **dropped** — see its canonical row in the §3.4c table, which is the single
> authoritative statement of its status. A fix-assigned destination is a legal configuration at every scope;
> what is refused is the *placement*, by the runtime gate (§5.2 step 15). **Do not restate P2.5's status
> anywhere else in this document — reference the §3.4c row.** Restating it is how it came to be asserted
> three different ways by two editors working the same file on 2026-08-08. **Lanes are NOT in that list — P2.3 is not absolute.** P2.7 rules (a) and (d) deliberately
*permit* `staginglane` and `crossdockinglane` for tiers 2/3 (they are the ticket's named club-assembly and
cross-dock use cases) while (b) still bans `transferlane`, `automationlane` and `gate`. So the correct
statement is: **locked is absolute at all three scopes; lane handling is per-tier.** *(⚠ 2026-08-08: this sentence also listed **fix-assigned** as absolute. Dropped by Q12 → iv-b — see the canonical rule (c) row above. Locked remains absolute.)*
*(Corrected 2026-08-04 — the old "a lane can never work" wording predated P2.7(a)/(d) and contradicted them.)* Without that, a merchant or warehouse default on
a locked or fix-assigned location passes validation and then hard-fails *every* receipt in scope with
`STORAGELOCATION_LOCKED` / `WRONG_ITEMDATA_FIXASSIGNMENT` — messages that never mention putaway
configuration.

**The incompatible-SKU count is also the config-health signal** that D3 asked for and D6's switch to
hard-fail dropped. It is surfaced by the preview endpoint (N10) and rendered by §3.11.2 and §3.11.3.

### 3.5 Config-write services — the validated, audited writers

**Rationale.** The ticket's "changes are recorded in an audit log" and "precedence in ONE shared service" ACs both require that *every* write funnels through one place. Three typed writers, one per tier, all in a new `service/PutawayConfigService.java`:

```java
@Service
public class PutawayConfigService {

    public enum Scope { SKU, MERCHANT, WAREHOUSE }

    @PreAuthorize(Authority.IS_SB_ADMIN)                      // §3.12 — the authorization boundary
    @Transactional(value = "tenantTransactionManager",
                   rollbackFor = {BusinessException.class, FacadeException.class})
    // N-4: takes the LOADED ENTITY, not an id. The reused key expressions are
    // `…+':id:'+#itemData.id` and `…+':'+#itemData.clientId+':'+#itemData.itemNr`
    // (ItemdataService.java:62-67) — SpEL binds them to a parameter *named* `itemData` of type
    // Itemdata. With the old `(Long itemdataId, …)` signature neither expression can resolve and
    // every SKU write throws SpelEvaluationException at runtime. Load via
    // `itemdataRepository.findById` (never `itemdataService.getById`, which is @Cacheable — L1).
    @Caching(evict = { /* the two itemdata keys from ItemdataService.java:62-67, verbatim */ })
    public Itemdata setSkuDestination(Itemdata itemData, Long locationIdOrNull) throws BusinessException;

    @PreAuthorize(Authority.IS_SB_ADMIN)
    @Transactional(value = "tenantTransactionManager",
                   rollbackFor = {BusinessException.class, FacadeException.class})
    // N-4: same defect, worse — §3.3's key is `…+':'+#client.clNr`, so a `(Long clientId, …)`
    // signature makes `#client` unresolvable and EVERY merchant write throws.
    @Caching(evict = { /* the two clients keys from §3.3, verbatim */ })
    public Client setMerchantDestination(Client client, Long locationIdOrNull) throws BusinessException;

    @PreAuthorize(Authority.IS_SB_ADMIN)
    @Transactional(value = "tenantTransactionManager",
                   rollbackFor = {BusinessException.class, FacadeException.class})
    @CacheEvict(value = "sysprops",
        key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + T(net.aim_ai.wms.service.WmsConstants).SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY")
    public Sysprop setWarehouseDestination(Long locationIdOrNull) throws BusinessException;
}
```

Each method: (1) read the **previous** value, (2) run **P2** for its scope when `locationIdOrNull != null`, (3) write, (4) call `PutawayConfigAuditService.record(...)`, (5) `metrics.configChanged(scope, channel)`. `locationIdOrNull == null` clears the override — no validation needed, still audited. The warehouse writer writes `sysvalue = ''` for a clear (never a DELETE), creates the row if the `V2.2.13` seed has not run yet, and refreshes `description` with the resolved location name.

**Three further members exist for the event handler (§3.9), on the same bean:** `readCommittedDestination`, `validateOnly` and `auditAndEvict`. `validateOnly` also carries `@PreAuthorize(Authority.IS_SB_ADMIN)` — it is the authorization boundary for the HAL channel (§3.12).

**Existing-code cleanup carried here (§0.1 rows 13, 14):**

- `service/ItemdataService.setPutAwayLocation` (**`:73-82`** — ⚠ re-derived 2026-08-11, was `:68-76`) is **promoted, not deleted** — it already carries the correct targeted 2-key `@CacheEvict`, in a `@Caching` block at **`:66-72`** that sits ABOVE the method, so an edit scoped to the method's own lines moves it away from its annotations (SBDEV-2643 §10.3 **C9**). Was cited as `:62-67` that `ItemDataController.java:80` gets wrong. It is rewritten to delegate to `PutawayConfigService.setSkuDestination` and its `locationRepository.findById(itemData.getPutawaylocationId())` at `:71` gains a null guard (the previous value is now legitimately `NULL`).
- `controller/ItemDataController.java:80` — `@CacheEvict(value="itemdata", allEntries = true)` **flushes every tenant's entries**. Replaced by delegation to `ItemdataService.setPutAwayLocation`, so the correct 2-key eviction applies. The `@GetMapping`-that-mutates smell at `:81` is **left as-is** — the web UI calls it, and changing the verb is a breaking API change outside this ticket's scope (§10 Q5).

### 3.5a `PutawayConfigController` — the typed write surface

**Why this exists.** It is the **only** caller of the three writers above, and the UI writes every tier
through it (§3.11.2, §3.11.3). Without it those writers would be dead code — the exact smell §1 condemns
in `ItemdataService.setPutAwayLocation` — their `@CacheEvict` would never fire, and the only live write
path would be the silently-registered event handler.

**It is also where D11's count-and-confirm lives, and it can live nowhere else.** Spring Data REST's
`RepositoryEntityController` **ignores unknown query parameters**, and a `@HandleBefore*` handler receives
only the entity — it cannot see `?confirmIncompatibleSkus=<n>` without injecting `HttpServletRequest` into
the handler bean, which would also break the keep-it-CGLIB constraint in §3.9.4.

```java
@RestController
@RequestMapping("/putawayConfig")
public class PutawayConfigController {

    // ---- PREVIEW (N10). Read-only. Drives D11's count-and-confirm AND the picker's health signal.
    // Not admin-gated: it reveals no more than the location list the picker already shows.
    @GetMapping("/preview")
    @Transactional(value = "tenantTransactionManager", readOnly = true)   // §3.1.5 facade rule
    public PutawayConfigPreview preview(@RequestParam PutawayScope scope,
                                        @RequestParam(required = false) Long subjectId,
                                        @RequestParam Long locationId) throws BusinessException;
    // { locationId, locationName, compatible, incompatibleSkuCount, totalSkuCount,
    //   exampleIncompatibleSku, blockingReason }   // blockingReason: LOCKED | FIX_ASSIGNED | LANE | null

    // ---- WRITES. All three admin-gated, all three delegate to PutawayConfigService.
    @PutMapping("/sku/{itemdataId}")
    @PreAuthorize(Authority.IS_SB_ADMIN)
    public void setSku(@PathVariable Long itemdataId,
                       @RequestParam(required = false) Long locationId)    // omitted ⇒ clear
            throws BusinessException;

    @PutMapping("/merchant/{clientId}")
    @PreAuthorize(Authority.IS_SB_ADMIN)
    public void setMerchant(@PathVariable Long clientId,
                            @RequestParam(required = false) Long locationId,
                            @RequestParam(required = false) Integer confirmIncompatibleSkus)
            throws BusinessException;

    @PutMapping("/warehouse")
    @PreAuthorize(Authority.IS_SB_ADMIN)
    public void setWarehouse(@RequestParam(required = false) Long locationId,
                             @RequestParam(required = false) Integer confirmIncompatibleSkus)
            throws BusinessException;
}
```

**Callers load the entity, then pass it (N-4).** `PutawayConfigController` takes `@PathVariable Long
itemdataId` / `clientId`, but `PutawayConfigService.setSkuDestination` / `setMerchantDestination` take the
**loaded entity** so their reused `@CacheEvict` SpEL (`#itemData.id`, `#client.clNr`) can bind. The
controller therefore loads via `itemdataRepository.findById` / `clientRepository.findById` — **never**
`itemdataService.getById`, which is `@Cacheable` and would hand back a cached instance the writer then
mutates in place before eviction fires. Do not "simplify" the writers back to id parameters: that is a
runtime `SpelEvaluationException` on every write, not a style preference.

**The confirmation contract (D11).** For MERCHANT and WAREHOUSE scope the writer recomputes the
incompatible-SKU count itself and compares it to `confirmIncompatibleSkus`:

| Situation | Result |
|---|---|
| count == 0 | write proceeds; `confirmIncompatibleSkus` ignored |
| count > 0, param absent | **409** + the count + one example SKU — "re-issue with `confirmIncompatibleSkus=<n>`" |
| count > 0, param == recomputed count | write proceeds; the count is recorded on the audit row |
| count > 0, param ≠ recomputed count | **409** — the SKU set changed between preview and write; **stale confirmations must never slip through** |
| count == total (100 % incompatible) | **422**, unconditionally — no confirmation can override it |
| destination locked | **422**, unconditionally — absolute at all three scopes (P2.1, §3.4c) |
| destination **fix-assigned**, or a **pick face** | **accepted — no longer a write-time reject.** ⚠ CHANGED 2026-08-08 (Q12 → iv-b): P2.5 and P2.7(c) are relaxed at all three scopes; the configuration is legal and the **placement** is what is refused, by step 15's `useforpicking` gate (§3.4c) |
| destination is a `transferlane` / `automationlane` / `gate` | **422**, unconditionally (P2.7(b)) |
| destination is a `staginglane` / `crossdockinglane` | **422 at SKU scope** (P2.3); **permitted at merchant/warehouse scope** (P2.7(a)+(d)) — per-tier, not absolute |

Recomputing rather than trusting the preview is the point: the two calls are separated by however long the
admin spent reading the dialog, and SKUs can be created in between.

**HAL is not closed off, and must not be.** The `@RepositoryEventHandler` (§3.9) still guards
`PATCH /v3/itemdata/{id}` and friends, whether the write comes from a script, an integration or a stale
client — that is what makes the "ONE shared service" and audit ACs true. HAL writes simply cannot carry a
confirmation, so they get the strict rule; see §3.9.8.

**`setWarehouse` is the only write path for `DEFAULT_PUTAWAY_LOCATION`.** The two direct-save methods on
`SystemPropertyController`'s two direct-save endpoints are closed against this syskey, and the SDR delete is accepted but audited — §3.9.1.

**Phase placement.** `setSku`, `setWarehouse` and `preview` are **Phase 1** (no schema dependency: tier 3
is a sysprop row, and a missing row already reads as "not configured", §3.4a). `setMerchant` is
**Phase 1** — `client.defaultputawaylocation_id` does not exist until `V2.2.13` (ordering hazard O2).

### 3.6 The actionable message (D6) and the error envelope

#### 3.6.1 Two message keys, thrown from two different places

The raw-concatenated throw at `UnitloadBusinessService.java:235` serves **24 call sites**, only one of
which is receiving. Replacing it with a putaway-specific message would put a misleading remedy
("clear the configured putaway destination") in front of pickers, palletizers, truck loaders and transfer
operators. So the failure is reported by **two** keys:

| Key | Thrown from | Audience |
|---|---|---|
| `unitloadTypeNotPermittedOnLocation` | `UnitloadBusinessService.java:235` — the shared, context-free backstop for all 24 call sites | anyone moving a unit load anywhere |
| `putawayDestinationNotPermitted` | `PutawayDestinationResolver.requireCompatible(...)` — §3.1.3, and **nowhere else** | a receiving operator whose *configured* destination is wrong |

**`UnitloadBusinessService.java:188-237` becomes:**

```java
if (!locationConstraintService.isUnitloadTypePermitted(destinationLocation.getTypeId(), unitload.getTypeId())) {
    throw new BusinessException("unitloadTypeNotPermittedOnLocation",
            unitloadTypeRepository.findNameById(unitload.getTypeId()),             // %1$s
            destinationLocation.getName(),                                          // %2$s
            locationTypeRepository.findById(destinationLocation.getTypeId())        // %3$s
                    .map(LocationType::getSltname)
                    .orElse(String.valueOf(destinationLocation.getTypeId())));
}
```

> ⚠ **Corrected 2026-08-02 (architect + critic review of SBDEV-2731).** This block previously called
> `locationTypeRepository.findNameById(...)`, **which does not exist** — `repo/jpa/LocationTypeRepository.java`
> declares only `findBySltname` plus `CrudRepository`. The `findById(...).map(LocationType::getSltname)`
> form above is the one that compiles, and it is what SBDEV-2731 PR1 will actually write at `:191`.
> Note `unitloadTypeRepository.findNameById` **does** exist (`UnitloadTypeRepository.java:19`) — but it is a
> JPQL scalar projection and returns **null** for a missing id, so `%1$s` needs a non-id fallback rather
> than being passed straight through.

Three lookups, all name-only. **Do not** pipe `unitloadRepository.findLabelidById` or a remedy anchor into
this site: the neutral key has no remedy clause precisely because there is no configured destination in
the general case, and adding a fourth lookup here would cost a query on every one of the 24 call sites'
transfers.

**Keys in `src/main/resources/messages_en_US.properties`** (printf style, matching
`STORAGELOCATION_LOCKED=The location %1$s is locked. ( Lock code = %2$s ).` at `:287`):

```properties
# SHIPPED BY SBDEV-2731 PR1 (#133) — this plan CONSUMES it, does not author it.
unitloadTypeNotPermittedOnLocation=Unit load type %1$s is not permitted on location %2$s (location type %3$s).

# THIS PLAN'S key.
putawayDestinationNotPermitted=Cannot put away %1$s to location %2$s: a %3$s unit load is not permitted on a %4$s location. Change the configured putaway destination, or clear it so receiving falls back to %5$s.
```

> **⚠ The neutral key's TEXT changed on 2026-08-06 and this plan quoted the superseded version.** It read
> `A %1$s unit load is not permitted on location %2$s (location type %3$s).` — reworded by 2731's code
> review (finding #4, commit `89de3f0`) because it rendered *"A unknown unit load"* on the fallback path
> and *"A Inbound Pallet unit load"* for vowel-initial types. Corrected here 2026-08-06 against the
> as-shipped bundle (`messages_en_US.properties:342` on the #133 head).
>
> **The KEY NAME did not change**, so §5.1 prerequisite 0 and §3.6.1's two-key split are unaffected —
> only the rendered text moved. Any test or verify pattern asserting the *wording* must use the string
> above. This plan's `T-msg2` matches on `not permitted on location`, which is present in both, so it is
> unaffected either way.

Neither leaks a raw id. The putaway-specific key additionally names the **tier that was configured**
(`%1$s` = `Resolution.configuredFor()` — "SKU 12345" / "merchant WINE01" / "warehouse default") and the
**remedy anchor** (`%5$s` = `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE`), which is exactly the context
the shared site does not have.

**`unit/service/UnitloadBusinessServiceUnitTest.java:193, 208` pins the current raw-ID text
(`.hasMessageContaining("not allowed on location")`) and WILL break by design. Update it to assert the
rendered `unitloadTypeNotPermittedOnLocation` content — never loosen the assertion to make it pass.** A
verify row asserts `putawayDestinationNotPermitted` appears in `PutawayDestinationResolver.java` and
**not** in `UnitloadBusinessService.java`.

#### 3.6.2 Error envelope

`ReceivingController.java:283-300`: `BusinessException` → `errors.add(getErrorMessage("Runtime Error", e.getMessage()))` (operator sees the text); `RuntimeException` → generic "contact support". **Every resolver and validator failure is a `BusinessException`.** A `ReceivingControllerUnitTest` case asserts a resolver rejection surfaces the message text, not the generic string.

> **`receiveGoods` has TWO callers, and only one is an operator. Added 2026-08-06 — this plan previously modelled only the first.**
>
> | Caller | Consumer | Error surface |
> |---|---|---|
> | `controller/ReceivingController.java:284` | a human at the receiving screen | the catch ladder above; 200-with-`errors` |
> | `service/ReturnAdviceAutoReceiveService.java:556` | **OMS — a machine** | its own catch at `ReturnAdviceAutoReceiveService:555-560` |
>
> The second path is return-advice auto-receive, shipped by **SBDEV-2778**, which this plan otherwise
> mentions only in connection with it taking Flyway `V2.2.09`.
>
> **Transactionally it is safe and needs no change** — state that plainly so nobody re-opens it:
> `executeInternal` is private and not `@Transactional`, but `receiveGoods` itself carries
> `@Transactional(value="tenantTransactionManager", rollbackFor={…})` at `ReceivingService.java:302`, so the
> `MANDATORY` resolver joins that transaction exactly as on the controller path. §7.7a row 1 covers it by
> construction. There is no C1-class defect here.
>
> **What is NOT covered is the error surface, and three of this plan's design commitments assume a human:**
> - §3.6's whole message design is *"name a remedy, not just the failure"* — `MSG-actionable` demands five
>   format args including a remedy clause. A machine cannot act on a remedy string.
> - **D10's "surface-and-warn, never block"** has no operator to warn on this path.
> - §8.2's blast radius and pre-mortem **P3** (the 200-with-`errors` detector trap) are both written for the
>   operator path only.
>
> **Required before Phase 1-API closes:** decide whether a resolver rejection on the auto-receive path should
> (a) fail the line and report to OMS, or (b) fall back to tier 4 and warn — and add the matching
> `ReturnAdviceAutoReceiveService` test. This is an unmodelled *production* entry point into the exact method
> §3.7 rewires; the risk is low but it is not zero, and it is cheap to close now.

### 3.7 Receiving wiring (D2)

> **Scope note (D15, 2026-08-04) — ⚠ SUPERSEDED 2026-08-08 by Q12 → (iv-b). Read the replacement first.**
>
> **Replacement:** everything in this section still applies to whatever destination the resolver returns, and
> there is still **no per-*tier* branch here** — but there is now exactly **one per-*destination* branch**:
> step 15's `useforpicking` gate. A pick-face destination is **not** placed here at any tier; it is diverted
> to the standard putaway lane and consumed at putaway (SBDEV-2821). Everything else is placed as this
> section describes. **This is not the duplicated receive-time check P2.6 warns against** — P2.6 forbids
> re-running the *config-write* predicate at receive time. This gate tests something write-time validation
> deliberately no longer tests, because (iv-b) permits the configuration.
>
> ~~"Direct placement for tiers 2/3 only" is enforced entirely at **config-write time** (P2.5 / P2.7(c),
> §3.4c), because `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally
> and adding a second gate here would duplicate the check at receive time — the anti-pattern P2.6 exists to
> avoid. Consequence to keep in mind while implementing: this section is *why* those two predicates must stay
> absolute until [SBDEV-2821](https://app.clickup.com/t/868km8j9z) ships.~~ **The enforcement point moved
> from write-time to run-time; the predicates are relaxed here, in this plan, in the same change as the
> gate.**

#### 3.7.1 Replace the ternary

`ReceivingService.java:451-459` becomes:

```java
Location spawnLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_SPAWN)
    .orElseThrow(() -> new BusinessException("entityNotFoundForName", Location.class.getSimpleName(), WmsConstants.STORAGE_LOCATION_SPAWN));

// SBDEV-2732 — resolved for BOTH branches (the old code resolved only when carrier == null,
// which is SBDEV-2731's root cause). Hoisted above the per-case loop at :462 deliberately:
// one resolution per receipt, and a bad destination fails before any unit load is created.
PutawayDestinationResolver.Resolution putaway =
    putawayDestinationResolver.resolve(itemdata, client, unitloadType.getId());
// `compatible` tag added so the carrier-path "surfaced but not applied" case is observable WITHOUT
// polluting wms2.putaway.resolution.rejected, which alerts on >0 as pre-mortem P3's indicator.
putawayResolutionMetrics.resolved(putaway.source(), carrier != null, putaway.compatible());

// SBDEV-2732 — THE ONLY call site of requireCompatible on the receiving path.
// Guarded by carrier == null because on the carrier path the resolved destination is never
// applied (§3.7.2), so a config error irrelevant to this receipt must not abort it (D10).
// Placed HERE, beside the hoisted resolve and ABOVE the per-case loop at :462 — NOT inside the
// fork — so a bad destination still fails before any unit load is created (§2.1's preserved
// property). Calling it inside the loop would fail on case 2..n after case 1 already existed.
if (carrier == null) {
    putawayDestinationResolver.requireCompatible(putaway);   // throws BusinessException naming tier + remedy
} else if (!putaway.compatible()) {
    LOG.warn("SBDEV-2732 carrier receipt: resolved destination {} (source={}) is not permitted for "
             + "unit-load type {}; destination surfaced but not applied. advicePosition={}",
             putaway.location().getName(), putaway.source(), unitloadType.getId(),
             adviceposition.getNumber());
    // No separate counter: the single resolved(...) call above already tags compatible=false,
    // so this case is queryable as resolution{carrier="true",compatible="false"}.
}
```

**This is the one place a `carrier == null` guard is correct.** Do not confuse it with the *resolution*
above, which must stay unguarded — a carrier-guarded `resolve(...)` is precisely SBDEV-2731's root cause.
Verify enforces both directions: `check_W_resolve_not_carrier_guarded` (resolution NOT inside the guard)
and `check_W_requirecompatible_carrier_guarded` (the hard-fail IS inside it).

The `Location`-not-found `BusinessException` currently thrown by the ternary at `:456` moves inside the resolver, where it can name which *tier* held the dangling id.

**Tests for this wiring** are listed in §7.1 under `ReceivingServiceUnitTest`:
`nonCarrierPathStillFailsOnIncompatibleDestination`, `carrierPathDoesNotFailOnIncompatibleDestination`,
`resolveIsCalledForBothBranches`, `resolverInvokedOnceAboveLoop`.

#### 3.7.2 The placement fork — and the honest limit of D2 on the carrier path

```java
if (carrier == null) {
    unitloadBusinessService.transferUnitLoadToLocation(unitload, putaway.location(), false,
            codeReceiving, adviceposition.getNumber(), null);
} else {
    unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier,
            codeReceiving, adviceposition.getNumber(), null);
}
```

The fork's *shape* is unchanged. Only `putaway.location()` replaces `putAwayLocation`.

**Decision, and it is a deliberate scope boundary.** On the **non-carrier** path, D2's direct placement is already the existing mechanism (§2.1) — the only change is the destination. On the **carrier** path, the unit load goes onto the carrier as today, and the resolved destination is **surfaced, not applied**:

> A carrier pallet is a physical pallet the operator is building at their workstation. Directing individual cases to distinct locations while they sit on one shared pallet is physically incoherent — and the pallet may hold SKUs from several merchants with different resolved destinations. Forcing the resolved destination here would either split the pallet or silently pick one SKU's destination for all of them.

So "honor" is discharged on the carrier path as: (a) the destination is resolved and returned by the display endpoint (§3.8) so the operator sees it before scanning; (b) a `WARN` is logged and `putawayResolutionMetrics.resolved(source, carrier=true)` records it when a **non-tier-4** destination is resolved for a carrier receipt; (c) the pallet's later putaway is where the destination applies, and `MobilePutAwayService.calculatePutAwayList` already suggests locations there. This satisfies SBDEV-2731's "should not silently ignore" (it is neither silent nor ignored) without inventing pallet-splitting. §9 A5 records the rejected alternative; §10 Q1 flags it for business confirmation.

#### 3.7.3 Inbound-pallet name checks (§0.1 rows 3, 4, 27)

`ReceivingService.java:601-612` compares a location name against `PutAwayLane` to decide inbound-pallet assignment, and `:634-637` moves the pallet back to the lane on unassign. Both are about **where the inbound pallet lives**, not where received stock goes, and both stay correct when a receipt's destination is not the lane. **Audited, unchanged.** `ReceivingController.java:314`'s raw literal set `{"PutAwayLane","InboundWorkstation","EmptyPallets"}` is replaced with `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE`, `STORAGE_LOCATION_INBOUND_NAME` and the empty-pallets constant — a mechanical de-duplication so a future lane rename cannot silently break pallet listing.

#### 3.7.4 Mobile putaway (§0.1 rows 5, 5a, 6, 7, 33)

No code change. Four behavioural notes for §6:

- **The exception a direct placement actually produces is `unitloadNotInInboundArea`, not `unitLoadNotInPutAwayLane`.** `MobilePutAwayService.java:113-117` runs **first**: `if (!locationArea.getUseforgoodsin() && !storageLocation.equals(Clearing)) throw new BusinessException("unitloadNotInInboundArea")`. A unit load placed directly into a storage or pick area sits in an area with `useforgoodsin = false`, so it trips that guard and **never reaches** the lane check at `:121-128`. Any operator note, manual row or training material that names `unitLoadNotInPutAwayLane` for this scenario is wrong.
- `MobilePutAwayService.java:121-128` (`unitLoadNotInPutAwayLane`) still fires for a unit load that *is* in an inbound-flagged area but not on the lane itself — e.g. one moved to `InboundWorkstation`. Unchanged, and unaffected by this plan.
- **Correction path for a misplaced unit load.** Neither guard offers a remedy in the putaway screen, so an operator who scans a directly-placed unit load must move it with `MobileMoveUnitloadService` (mobile "Move Unit Load") or the web **Transfer Stock** screen (`transferStock.vue`). Naming that path is the answer to the long-open recoverability question: the unit load is not stuck, it is simply already at its destination and the putaway screen has nothing to do with it. Manual row **M13a** exercises the move; **M13** asserts the correct exception text.
- `MobilePutAwayService.java:190-206` `storePalletBackOnPutawayLane` is the **SBDEV-2102 fix**; its "pallet must be on the current user's location" guard must survive untouched. The verify script asserts it.

### 3.8 Receiving display — and a scope reduction against D8

**Finding.** `receiving_dto_view` already projects `defaultputawaylocationname` (`V2.2.00__base_v2_schema.sql:4663`, joined at `:4676` via `LEFT JOIN location loc ON loc.id = i.putawaylocation_id`), surfaced at `model/ReceivingDtoView.java:47, 173`, and `ReceivingDtoView` is already in `exposeIdsFor` (`RestConfiguration.java:42`).

**Therefore the view needs no change.** D8 assigned `receiving_dto_view` / `ReceivingDtoView` ownership to this plan on the premise that a view change was needed and only one plan could own it. The evidence says otherwise, and adding an *effective* destination to a SQL view would be actively worse: the four-tier precedence plus P1 compatibility is not expressible in the view's SQL, and a projected view column couples the view and the `ReceivingDtoView` entity into every future change (weaker than the original `ddl-auto=validate` claim — `ddl-auto` is `none` — but the coupling is real: any view change must land with the entity or reads break at runtime). D8's **substance** is honored unchanged — this plan owns the receiving-display contract and SBDEV-2731 must not be worked independently — while its **mechanism** shrinks to zero DDL. Net: one less migration statement, one less `ddl-auto` coupling.

**New endpoint** instead — and it **MUST NOT** call the resolver directly. `resolve(...)` is
`Propagation.MANDATORY` and controllers are not transactional; the facade and its rationale are in
**§3.1.5**. The controller delegates to that facade and maps the returned `Resolution` to the JSON
envelope:

```java
// controller/ReceivingController.java — delegates only, opens no transaction of its own
@GetMapping(path = "/getPutawayDestination/{advicePositionId}", produces = "application/json")
public Map<String, Object> getPutawayDestination(@PathVariable Long advicePositionId)
        throws BusinessException {
    // §3.1.5 facade supplies the tenant transaction the MANDATORY resolver requires
    return toEnvelope(putawayDestinationQueryService.describeForAdvicePosition(advicePositionId));
}
// envelope: { locationId, locationName, source, sourceLabel, configuredFor, compatible, warning }
```

The facade returns the domain `Resolution`, **not** the JSON map, so that `describeForClient(Long)`
(§3.1.5) can back `GET /client/{id}/effectivePutawayDestination` (N9, the merchant screen's inherited
value) without duplicating precedence logic. Each controller owns its own envelope mapping; neither
re-derives the tiers.

**One additional NEGATIVE verify check beyond §3.1.5's `check_N2_readonly_facade`:**
`check_N2_controller_delegates_not_resolves` — assert `putawayDestinationResolver` **never** appears in
`ReceivingController.java`. Without it, an implementer can satisfy every positive check by creating the
facade *and still* calling the resolver directly from the controller — which reintroduces the
`IllegalTransactionStateException` in §3.1.5 while the script stays green.

`source` is the enum name (`SKU_OVERRIDE` | `MERCHANT_OVERRIDE` | `WAREHOUSE_DEFAULT` | `STANDARD_PUTAWAY_LANE`) so Vue never re-derives the precedence; `sourceLabel` is the display string ("SKU override", "Merchant default", "Warehouse default", "Standard putaway lane"); `compatible` reports **P1** without throwing, so the form can warn *before* the operator commits a receipt; `warning` carries the rendered `putawayDestinationNotPermitted` text when `compatible == false`.

Resolved **per advice position**, not per list row — the open-receiving list can be hundreds of rows and N resolver calls there would be 1–4 queries each. Needs a `BaseControllerUnitTest` subclass and a `SecurityConfiguration` review (it is a read under the existing `/receiving/**` rules).

### 3.9 Closing the Spring Data REST write hole (D7, extended to `Sysprop`)

**Rationale.** While `PATCH /v3/itemdata/{id}`, `PATCH /v3/client/{id}` and `PATCH /v3/sysprop/{id}` write unvalidated (`RestConfiguration.java:47` + `:55-60` register only bean-validation validators), the ACs "precedence lives in ONE shared service" and "changes are recorded in an audit log" are **literally unachievable** — and this is the most likely way the invalid Ice Pack configuration was created.

**Extension beyond D7's letter:** D7 names `Itemdata` and `Client`. `Sysprop` is added, because the **warehouse** tier is the highest-blast-radius tier (a bad value hard-fails receiving for *every* merchant) and `PUT /sysprop/{id}` is precisely what the existing generic admin dialog calls (`store/admin/configuration.js:73-93`). Guarding two of three holes would leave the worst one open. D7's own rationale already cites `PATCH /v3/sysprop/{id}` as unguarded.

**The handler guards SDR-shaped writes ONLY.** `@RepositoryEventHandler` methods fire only on events that
Spring Data REST's own `RepositoryEntityController` publishes. Any code that calls
`repository.save()` directly — from a controller, a service or a scheduled job — bypasses it completely,
silently, with no compile-time or startup signal. There are **17 direct `save()` calls on the three
guarded entities** across the codebase; this plan routes **one** of them (`ItemDataController.java:88-90`)
through `PutawayConfigService` and explicitly closes **three more** in §3.9.1. The remaining thirteen do
not touch a putaway destination field today; if one ever does, the handler will not see it. That is a
property of the mechanism, not a defect to be fixed here — state it so nobody later assumes the handler
is a universal invariant.

#### 3.9.1 Three write paths the handler does not cover

| Path | Why the handler misses it | Required change |
|---|---|---|
| `POST /v3/systemProperty/create` (`SystemPropertyController.java:47-90`, save at `:77`) | direct `syspropRepository.save()`, no SDR event | **Reject** `syskey == DEFAULT_PUTAWAY_LOCATION` with the standard 422 + a message pointing at `PUT /putawayConfig/warehouse`. |
| `POST /v3/systemProperty/updateValue` (`:93-120`, save at `:107`) | direct save, and it selects its target with `findBySyskey(key).get(0)` — the client-blind shape of landmine A3, on a write | **Reject** the same syskey, same message. (The client-blind selection is left alone; it is a pre-existing defect on other keys and out of scope.) |
| `DELETE /v3/sysprop/{id}` (SDR-exported; live button, `store/admin/configuration.js:125-147`, axios at `:127`) | the plan defines no delete handler, so the row could be removed unvalidated and unaudited | **D12 — accept the delete, audit it.** See below. |

**D12 — the decision on delete.** Deleting the `DEFAULT_PUTAWAY_LOCATION` row is **accepted**, not
refused. An absent row and a blank row are the same state to the resolver (§3.4a), so a delete can only
ever move tier 3 to "not configured" — the safe direction, and one the operator can already reach by
clearing the value. Refusing it would mean throwing from a handler and giving the operator an error on a
button that works for every other row, for no safety gain.

Two obligations come with accepting it:

1. **Audit it.** A `@HandleAfterDelete` on `Sysprop` — returning immediately unless
   `syskey == DEFAULT_PUTAWAY_LOCATION` — calls `PutawayConfigService.auditAndEvict(WAREHOUSE, …)` with
   `new_location_id = NULL`, so AC15 still holds. The **previous** value comes from a
   `@HandleBeforeDelete` that reads it and parks it on the same request-scoped carrier the save path uses
   (§3.9.6); that `Before` method performs no validation and never throws.
2. **Keep the key settable after it is gone.** Because `POST /v3/systemProperty/create` now rejects this
   syskey, an operator who deletes the row must not be locked out of re-creating it. §3.11.2 therefore
   renders the `DEFAULT_PUTAWAY_LOCATION` control **unconditionally** in Operation Options — driven by
   `PutawayConfigController`, not by the presence of a row in the `findByGroupname` list — and
   `setWarehouseDestination` **creates the row if it is absent**. Without this pairing, D12 is a trap:
   one click and the warehouse tier becomes unreachable from the UI until an operator runs SQL.

Every other syskey deletes exactly as it does today.

**Message parity.** All three rejections use the same rendered text as the HAL and typed channels, so an
operator meets one message for one mistake regardless of which screen produced it (§3.6.1).

Verify rows: `check_N1_syspropctl_create_guard`, `check_N1_syspropctl_updatevalue_guard`,
`check_N1_sysprop_delete_handler`. Manual rows **M9b** and **M9c**.

#### 3.9.2 Handler shape — create and save are separate methods

**New file:** `src/main/java/net/aim_ai/wms/config/PutawayConfigRepositoryEventHandler.java`

**`@HandleBeforeCreate` and `@HandleBeforeSave` MUST NOT share a method.** On a create the entity id is
`null`, so a shared method that reads the previous value by `incoming.getId()` binds `null` into
`where id = ?1`; with `getSingleResult()` that raises `NoResultException`, a `RuntimeException` that
breaks **every** HAL `POST` of `Itemdata`, `Client` and `Sysprop` — all three are exported
(`ItemdataRepository:18`, `ClientRepository:18`, `SyspropRepository:15`), so the blast radius is unrelated
master-data creation. On the create path there is genuinely no previous value: skip the read.

```java
@Component                      // NOT interface-implementing — see §3.9.4
@RepositoryEventHandler
public class PutawayConfigRepositoryEventHandler {

    // ---- CREATE: there is genuinely no previous value. Never read one. ----
    @HandleBeforeCreate
    public void onItemdataCreate(Itemdata incoming) {          // unchecked throws only — §3.9.3
        putawayConfigService.validateOnly(SKU, incoming, null);
    }

    // ---- SAVE: read the committed previous value, then validate the DELTA ----
    @HandleBeforeSave
    public void onItemdataSave(Itemdata incoming) {
        Long previous = putawayConfigService.readCommittedDestination(SKU, incoming.getId());
        if (Objects.equals(previous, incoming.getPutawaylocationId())) return;   // not a putaway write
        putawayConfigService.validateOnly(SKU, incoming, previous);
        pendingPreviousValue.put(SKU, incoming.getId(), previous);
    }

    // ---- AFTER: audit + evict, once the entity write has committed ----
    @HandleAfterCreate
    public void onItemdataCreated(Itemdata saved) {
        putawayConfigService.auditAndEvict(SKU, saved, null);   // previous_location_id = NULL, correctly
    }

    @HandleAfterSave
    public void onItemdataSaved(Itemdata saved) {
        putawayConfigService.auditAndEvict(SKU, saved, pendingPreviousValue.take(SKU, saved.getId()));
    }

    // Client: same four-method shape. Phase 1 only — Client.defaultputawaylocationId does not exist
    // until V2.2.13 (ordering hazard O2), so writing onClient* in Phase 1 will not compile.

    // Sysprop: same shape, plus @HandleBeforeDelete (reads the previous value, never throws) and
    // @HandleAfterDelete (audits the clear) per D12 / §3.9.1. Every method returns immediately unless
    // syskey == DEFAULT_PUTAWAY_LOCATION. Also reject a non-DEFAULT workstation row for that syskey
    // (landmine A6) — otherwise the generic admin dialog can create a row tier 3 never reads.
}
```

On the **create** path `previous_location_id = NULL` is the *correct* audit value — there genuinely is no
previous value, and this is the only case in which the `previous_value_unavailable` column is relevant
(§3.14; on the save path the read always succeeds, see §3.9.5).

```java
// service/PutawayConfigService.java — the committed-value read, save path only.
// ONE QUERY PER SCOPE. A single query parameterised only by id would make a HAL PATCH /v3/client/{id}
// read the ITEMDATA row whose id happened to equal the client id and audit it as that merchant's
// previous value — silent wrong data, no exception.
@Transactional(value = "tenantTransactionManager", readOnly = true)
public Long readCommittedDestination(PutawayScope scope, Long subjectId) {
    if (subjectId == null) return null;                      // create path: nothing to read
    final String sql = switch (scope) {
        case SKU       -> "select putawaylocation_id        from itemdata where id = ?1";
        case MERCHANT  -> "select defaultputawaylocation_id from client   where id = ?1";
        // WAREHOUSE is a sysprop row, not an FK: sysvalue is text and may be '' (landmine A2).
        // Blank-after-trim means "not configured", so it must read back as NULL here, not as 0.
        case WAREHOUSE -> "select nullif(trim(sysvalue), '')::bigint from los_sysprop where id = ?1";
    };
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter(1, subjectId);
    List<?> rows = q.getResultList();                        // getResultList, ONCE — never getSingleResult
    if (rows.isEmpty() || rows.get(0) == null) return null;
    return ((Number) rows.get(0)).longValue();
}
```

#### 3.9.3 Validate the DELTA, never the state

Every `@HandleBefore*` method **returns immediately when the putaway destination field is unchanged**:

```java
Long previous = putawayConfigService.readCommittedDestination(scope, incoming.getId());
if (Objects.equals(previous, incomingDestination)) return;   // not a putaway write — do not validate
putawayConfigService.validateOnly(scope, incoming, previous);
```

**Why this is load-bearing.** Validating the *state* rather than the *delta* would make **every** HAL
`PATCH /v3/itemdata/{id}` — changing *any* field — re-run P2 against the SKU's **existing** destination,
and likewise for `PATCH /v3/client/{id}`. That turns config rot into an **edit lock**: the NYWH `Itemdata`
row pointing at `Ice Pack` — the row this entire ticket exists because of — would become un-PATCHable for
*any* field, and a location that later acquires `entity_lock != 0` would brick HAL edits for every SKU and
merchant pointing at it. That is a straight regression against master-data maintenance that works today.

It is reachable, not theoretical: `store/admin/shippers.js:47` PATCHes `/client/${id}`, and
`ClientController` declares **no** `PATCH` mapping — so the live shipper screen lands on Spring Data REST
and goes through this handler on every save.

Verify row `check_H_delta_not_state` and unit test `unrelatedFieldEditIsNotValidated`.

#### 3.9.4 Registration — silent when it fails, and easy to break

A `@Component` carrying `@RepositoryEventHandler` is auto-registered by Spring Data REST's
`AnnotatedHandlerBeanPostProcessor` — no `RestConfiguration` change. **Registration is silent when it
fails**, which is why §7.4 requires a controller test that PATCHes an invalid value through HAL and
asserts a 422; no code-shape grep can prove the handler is wired.

**Keep the handler bean interface-free.** Spring Data REST resolves handler methods off the *user* class,
so a CGLIB proxy is fine — but if the handler implements an interface it becomes a JDK dynamic proxy and
**registration fails silently**, which is pre-mortem P3's exact failure mode. Do not let it implement an
interface.

**Do not put `@PreAuthorize` on the handler methods.** Spring Data REST registers the handler bean through
its own `AnnotatedHandlerBeanPostProcessor`, while Spring Security's method-security advisor is applied by
a different bean post-processor; depending on BPP ordering SDR can capture the **raw target** rather than
the security proxy, in which case the annotation is inert and the guard silently never fires. The
authorization check therefore lives on `PutawayConfigService` — an ordinary `@Service`, reliably proxied,
invoked from outside the bean by the handler (§3.12). `AccessDeniedException` is unchecked, so it
propagates out of the handler cleanly and Spring Security maps it to **403** before any validation runs.
Manual row **M16a**: a non-`sb_admin` `PATCH /v3/sysprop/{id}` must return 403, not 422 and not 200.

#### 3.9.5 Why the previous value needs its own query, and why no flush mode is involved

Spring Data REST's PATCH/PUT loads the entity, merges the payload, then fires `BeforeSaveEvent`, so the
in-memory field already holds the **new** value; the committed one must come from a separate query, which
is what `readCommittedDestination` is for.

**No `FlushModeType` manipulation is needed or wanted.** With OSIV off (`application.properties:55`) the
instance SDR merged into is **detached** — there is no persistence context to auto-flush, so
`setFlushMode(FlushModeType.COMMIT)` would change nothing. The native query returns the committed value
because the entity is detached, not because a flush was suppressed. Write the query; do not add a flush
mode, and do not document one.

Because the read always succeeds on the save path, the `previous_value_unavailable` column (§3.14) is only
ever `true` in one situation: nothing. It exists as a defensive marker and, on the **create** path,
`previous_location_id = NULL` with `previous_value_unavailable = false` is the correct record — there was
no previous value to be unavailable.

#### 3.9.6 Transaction shape — Before validates, After audits and evicts

`@HandleBeforeSave` / `@HandleBeforeCreate` fire from `RepositoryEntityController` **before**
`repository.save()`, outside any transaction; with `spring.jpa.open-in-view=false` there is not even an
open persistence context. `PutawayConfigAuditService` is `Propagation.MANDATORY` (§3.14, copied from
`CancellationLogService.java:33`), so it **cannot be called from a `Before` handler** — that raises
`IllegalTransactionStateException` and HAL PATCH returns 500. `MANDATORY` stays correct for the *typed*
writers, where it guarantees the audit row commits with the change or not at all.

**A single `@Transactional validateAndAudit(...)` called from the `Before` phase is NOT the answer and must
not be implemented.** It would open and **commit its own transaction before** SDR calls `repository.save()`,
which runs in its own transaction (`SimpleJpaRepository`). Two transactions: if the save then fails —
optimistic lock, FK violation, anything — the audit row survives a change that never happened, which is
what §3.14 calls "worse than none". It would satisfy AC15 with false records.

**The shape is split across the two phases:**

```java
// PutawayConfigRepositoryEventHandler — validation only, and it must throw UNCHECKED (§3.9.7)
@HandleBeforeSave                       // separate from @HandleBeforeCreate (§3.9.2)
public void onItemdataSave(Itemdata incoming) {
    Long previous = putawayConfigService.readCommittedDestination(SKU, incoming.getId()); // null on create
    if (Objects.equals(previous, incoming.getPutawaylocationId())) return;                 // §3.9.3
    putawayConfigService.validateOnly(SKU, incoming, previous);   // throws unchecked on reject
    pendingPreviousValue.set(previous);                           // request-scoped carrier, see below
}

// Audit AFTER the entity write has committed, so the row can never outlive a failed save
@HandleAfterSave @HandleAfterCreate
public void onItemdataAfter(Itemdata saved) {
    putawayConfigService.auditAndEvict(SKU, saved, pendingPreviousValue.getAndClear());
}
```

```java
// service/PutawayConfigService.java
@Transactional(value = "tenantTransactionManager", readOnly = true)
public Long readCommittedDestination(PutawayScope scope, Long entityId) { ... }   // null-safe on create

@PreAuthorize(Authority.IS_SB_ADMIN)                                              // §3.12
public void validateOnly(PutawayScope scope, Object incoming, Long previous) { ... } // no tx, no write

@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void auditAndEvict(PutawayScope scope, Object saved, Long previousLocationId) { ... }
```

Three properties this buys:
1. **The audit row cannot outlive a failed write** — it is written after SDR's save has committed, so
   §3.14's rationale holds on the HAL channel as well as the typed one.
2. **The previous value has somewhere to live** — the `Before` phase reads it and hands it to the `After`
   phase explicitly, rather than being orphaned by a signature that has no parameter for it.
3. **Eviction lands after the write**, not before — no window in which a concurrent read repopulates a
   stale entry that then lives out the full 5-minute TTL.

The handler **validates and audits only — it must never write the entity**; SDR saves it immediately
afterwards, so a write here means a double save.

**Open sub-decision for the implementer:** the request-scoped carrier between the two phases. A
`@RequestScope` bean is the clean option; a `ThreadLocal` is not, because the tenant-context precedent in
this codebase shows how easily those leak across async boundaries. Whichever is chosen, it must be
cleared unconditionally — a leaked previous value on a pooled thread would attribute one tenant's prior
location to another's audit row.

#### 3.9.7 Exception type — `PutawayConfigValidationException`, unchecked, 422

`BusinessException extends Exception` (`exceptions/BusinessException.java:14`) — it is **checked**. Spring
Data REST invokes `@HandleBefore*` through `AnnotatedEventHandlerInvoker` → `ReflectionUtils.invokeMethod`,
which rethrows only `RuntimeException`/`Error` and wraps a checked cause in
`UndeclaredThrowableException`. A `BusinessException` thrown from a handler therefore never reaches
`RestExceptionHandler`'s 422 mapping (`:118-124`) and the client gets a generic **500** — which would
leave the plan's highest-blast-radius guard with no usable proof at all, since M9 is what proves the
handler is registered.

**The handler throws a new unchecked `PutawayConfigValidationException extends RuntimeException`, with an
`@ExceptionHandler` in `RestExceptionHandler` returning 422 and the rendered message.** Chosen over SDR's
`RepositoryConstraintViolationException` because (a) it lands on **422**, the same status
`RestExceptionHandler:118-124` already returns for `BusinessException`, so the HAL and typed channels give
operators the same status and the same message for the same mistake; (b) `RepositoryConstraintViolationException`
is built around a Spring `Errors`/field-binding payload, and this rejection is not a field-binding failure
— it is a cross-entity rule about `location_constraint`, so the shoehorned payload would read worse to the
operator and to whoever writes the UI banner; and (c) it keeps the actionable-message rendering in one
place rather than splitting it across two exception shapes. **`BusinessException` stays on the typed path**
— the service layer is unchanged; only the handler boundary differs.

Follow-through: `RestExceptionHandler` gains the mapping; the handler methods declare **no** `throws`
clause, and a verify row asserts `throws BusinessException` is absent from the handler file; §3.6.1's
message keys render identically on both channels; and **M9's expected result is "all three HAL writes
return 422 with the actionable message"** — not "4xx", which is loose enough to be satisfied by the
500-via-`UndeclaredThrowableException` failure this decision exists to prevent. A 500 there is a
documented hard stop for pre-mortem P3.

#### 3.9.8 Channel tagging

The handler passes `channel = "hal"` to the audit writer and the metrics counter; the typed writers pass `channel = "typed"`; `V2.2.13`'s backfill pre-image rows carry `channel = "migration"` (§5.1). A non-zero `hal` count after Phase 2 ships is the signal that a client is still bypassing the intended UI.

**HAL writes cannot carry a confirmation.** D11's count-and-confirm requires a query parameter that SDR discards (§3.5a), so the handler applies the **strict** rule on the HAL channel: any incompatibility ⇒ reject. An admin who needs to accept a partially-incompatible destination must use `PutawayConfigController`. The rejection message must say so explicitly, or the HAL 422 looks like a bug.

### 3.10 Cache coherence

| Write | Cache | Keys evicted | Where |
|---|---|---|---|
| SKU destination | `itemdata` | `facilityCode+':id:'+#itemData.id` **and** `facilityCode+':'+#itemData.clientId+':'+#itemData.itemNr` | reuses `ItemdataService.java:62-67` verbatim; the comment at `:59-61` states the rule that the two `@Cacheable` and two `@CacheEvict` key expressions must stay in sync |
| Merchant destination | `clients` | `facilityCode+':'+clNr` **and** `facilityCode+':SYSTEM'` | §3.3 |
| Warehouse destination | `sysprops` | `facilityCode+':'+DEFAULT_PUTAWAY_LOCATION` | §3.5 — defensive only; the resolver's read path is uncached |
| any of the above via HAL | same as above | same | the event handler cannot carry `@CacheEvict` for another bean's keys ⇒ it **delegates to `PutawayConfigService`**, which does. This is the second reason the handler exists rather than just validating inline. |

**Both cache profiles.** `CacheConfig.java` declares the four caches twice (`:31-42` Caffeine, `:49-69` Redis). No new cache is added, so **no `CacheConfig` change is required** — a fact worth stating explicitly, because "add a cache" is the reflex here and it would have to be done twice. `unit/config/CacheConfigTest.java` already guards the pairing.

**Freshness contract.** Receiving never reads a stale **tier value**: `receiveGoods` loads `Client` via `clientRepository.findById` (`ReceivingService.java:369-370`, uncached), `Itemdata` via `itemdataRepository.findById` (`:357`, uncached), and tier 3's `sysvalue` through the uncached derived query `findBySyskeyAndClientIdAndWorkstation` (`SyspropRepository.java:35-36`, not `@Cacheable`). The receiving path is **not** entirely cache-free: tier 3 dereferences `clientService.getSystemClient()`, which **is** `@Cacheable(value = "clients", key = … + ':SYSTEM')` (`ClientService.java:100`). That is harmless — the system client's identity does not change — and a cache read inside a read-only transaction is fine. The **admin screens** can show a value up to 5 min stale after another replica's write under the Caffeine profile. §7.3 rows encode "re-read after the write in the same session" rather than "wait out the TTL".

### 3.11 Phase 2 — web UI (`v2/wms2-web-ui`), plus one API read

> [!warning] **§3.11 REWRITTEN 2026-08-11 against merged `889298d` / `4ce39a1` (r-next). Five defects, one fatal.**
>
> Everything below was verified `file:line` against the merged code on 2026-08-11. The previous text was
> written **before** Q12 → (iv-b) and **before** Phase 1-API existed; it was not merely stale, and
> **Step 19 as written was unimplementable.** Recorded here because two of its instructions would have
> shipped the exact defect SBDEV-2731 was opened for.
>
> 1. **FATAL — the client-side filter cannot exist.** The old text mandated *"sourced from
>    `/location/detailView` and filtered client-side on P2.3/P2.4."* `getLocationView()`
>    (`ViewDtoService.java:806-832`) emits exactly eight keys — `id`, `locationName`, `clientNumber`,
>    `clientName`, `areaName`, `locationType`, `created`, `modified`. It carries **no `entity_lock`, no
>    lane flags, and no area `useforgoodsin` / `useforstorage`**. Four of the five predicates are
>    therefore not evaluable in Vue at all. `areaName` is an area *name*, not its flags.
> 2. **The mandated filter was the wrong filter.** The old text said *"exactly P2.4"* and *"a pick-only
>    area is not offered."* Under (iv-b) the merged validator has **no P2.7(c) and no P2.5**, and the
>    real predicate set is **scope-dependent in five places** (§3.11.5a). A P2.4-only filter both
>    over-offers (locked rows, transfer lanes, gates) and under-offers (the club lanes that are this
>    ticket's own tier-2 use case).
> 3. **§3.11.1 was ~70% already shipped by SBDEV-2731 PR1** (`4ce39a1`), and what remained was not what
>    the old text described. Missing instead: the **diversion** rendering, a field family that did not
>    exist when §3.11.1 was written.
> 4. **The `createBol.vue` precedent citation was wrong on all three counts** (SBDEV-2643 §10.3 C7):
>    `:100-130` is a run of plain `v-text-field`s, the file's only `v-autocomplete` is at **`:68-76`**,
>    and `grep -n 'Lookup'` over the whole file returns nothing.
> 5. **`persistedState` shape was wrong.** It is a single top-level reducer at
>    `plugins/persistedState.client.js:22-25` naming three keys — not a per-module exclusion list.

#### 3.11.0 The eligible-locations read — **PAGINATED, and it needs no refactor** (resequenced r-next+1)

> [!warning] **RESEQUENCED 2026-08-11 after an independent design-review lane. The previous version of
> this section made a refactor of merged, live validation code a PREREQUISITE of a read-only feature.
> It does not have to be, and the reason it appeared to be was a response-shape choice this plan never
> examined.**
>
> **Root cause, stated plainly:** "return every location in the tenant, unpaginated" is what made
> per-row `validate()` expensive; that expense is what made the extraction a prerequisite; and that
> prerequisite is what put steps 19–22 behind a rewrite of the write path. **Paginate and the
> prerequisite dissolves.** At page size 50 a per-row `validate()` is ~50 iterations — cheaper than the
> `GET /preview` endpoint already merged and shipping (§3.11.0.3). This repo sets
> `api.paging.max-size=5000` (`application.properties:109`) and **12 typed controllers already accept
> `Pageable`**, so the unpaginated `List<Map<String, Object>>` was the anomaly, not the alternative.
>
> **Two factual errors in the superseded version, both load-bearing, both recorded so they are not
> repeated:**
> 1. It named **`PutawayDestinationValidatorUnitTest`** as the extraction's behaviour-preservation
>    guard, in three places, including a verify row asserting byte-identity to `889298d`. **That file
>    has never existed in any commit on any branch** (`git log --all --diff-filter=A` returns nothing).
>    The whole safety argument rested on an artifact that does not exist. See §3.11.0.2.
> 2. Its arithmetic was wrong in both directions — "four repository lookups" understated, "6 lookups ≈
>    16,400 queries" overstated. **The true maximum is five** (a flowbin skips the
>    `location_constraint` lookup; a non-flowbin skips FLA direction 1; the two are mutually exclusive),
>    and the L1-corrected naive figure is **~8,200**. The conclusion "unacceptable" survives; the number
>    that justified it did not.

##### 3.11.0.0 The four steps, in order — and why this order

| # | Step | Touches live validation code? | Unblocks |
|---|---|---|---|
| **A** | **`GET /putawayConfig/eligibleLocations`, paginated, per-row `validate()`**, behind `PutawayDestinationQueryService` | **No** | **steps 19–22 and SBDEV-2643 B2, immediately** |
| **B** | Write `PutawayDestinationValidatorUnitTest` against the **merged** validator; merge it alone | No | step C |
| **C** | Extract `PutawayDestinationRules`; validator becomes a facade over it | Yes | step D |
| **D** | Collapse the `summariseScope` / `countIncompatible` N+1 | **No — revised 2026-08-11** | — |

**Why A first.** It is the deliverable everything else waits on, and it is the only step with no risk to
merged code. Shipping it first means the extraction is then judged on its own merit rather than as a
prerequisite — which is the only honest way to judge it, because as a prerequisite it was never
compared against alternatives.

**Why B before C, and never after.** A characterization test written *after* a refactor pins the
refactored behaviour, not the merged behaviour, and is worthless as a guard. B must merge separately so
it is provably green against the **un**refactored validator first.

**Why D is in scope at all.** It is where the measured problem actually is (§3.11.0.3), and if C lands
without D the plan will claim to have removed an N+1 while the worst instance survives untouched.

⚠ **REVISED 2026-08-11 — D no longer depends on C, and shipped first (PR #144).** The dependency was an
artefact of *how* this section proposed to fix it (build a `Ctx`, call the extracted `evaluate`), not of
the defect. Memoizing the existing validator's verdict per distinct `defultypeId` achieves the same
collapse while touching no validation logic. **This is the second time in this plan that a step's
prerequisite turned out to be an artefact of the proposed mechanism rather than the problem** — step A
was the first (an unpaginated response shape). Worth pausing on before declaring the next dependency.

##### 3.11.0.1 Step A — the endpoint, with no extraction

```java
// service/PutawayDestinationQueryService.java — NOT the controller. See the boundary note below.
@Transactional(value = "tenantTransactionManager", readOnly = true)
public Page<EligibleLocation> eligibleLocations(PutawayScope scope, Long subjectId, Pageable pageable)
        throws BusinessException;

public record EligibleLocation(Long locationId, String locationName, String areaName,
                               String locationType, String tier, boolean eligible,
                               PutawayConfigController.BlockingReason blockingReason) {}
```

**The boundary goes on the query service, not the controller.** `PutawayDestinationQueryService`
exists for exactly this — its own javadoc calls it *"the read-only tenant-transaction facade. The ONLY
way a controller may reach the `MANDATORY` resolver"*. Three reasons beyond convention:

1. **One snapshot.** The read spans five tables; without a shared transaction those are five
   independent snapshots and an eligibility answer can straddle a concurrent FLA write. With 1,345 FLA
   rows and putaway auto-creating them, that is a live race, not a theoretical one.
2. `readOnly = true` is load-bearing for memory, not decoration — Spring propagates it to
   `Session.setDefaultReadOnly(true)`, skipping Hibernate's dirty-check snapshot per entity.
3. `PutawayConfigController` is already the **only** controller in the repo carrying a real
   `@Transactional` (three, all from Phase 1), and `ClientController:64` still asserts *"there is zero
   `@Transactional` under `controller/`"* — merged code containing a comment its own sibling
   falsified. A fourth annotation deepens that drift. The controller reduces to envelope mapping, the
   way `ClientController.effectivePutawayDestination` already is.

**Contract:**

| Field | Contract |
|---|---|
| `tier` | `"DEFAULT"` when `location_area.useforgoodsin`, else `"ADVANCED"`. Computed **server-side** — the flag is in no payload the UI can see |
| `eligible` | `validate(...)` did not throw for this `(scope, location, subject)` |
| `blockingReason` | the key it threw, mapped through §3.11.0a's enum |

- **`subjectId` is required at SKU scope** and ignored otherwise — P2.7(f) and P2.6 both need the
  subject SKU.
- **Ineligible rows are RETURNED, not filtered out.** With 1,345 of 2,068 flowbins FLA-bound, silently
  omitting them is its own confusion; the picker must be able to show a row and say why it is blocked.
  Order by `useforgoodsin DESC, name` so §3.11.5's two-tier grouping survives paging.
- **Exclude the tier-4 lane** by `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE` (`WmsConstants.java:771`)
  — the machine name, never an id, never the display label `'Put Away Lane'`.
- **Page-scoped evaluation.** Load the three small tables once (8 + 8 + 5 rows), let the database filter
  and page `location`, and evaluate only the page's rows — one FLA-by-location-ids query per page
  instead of a whole-table load. That is O(page), not O(tenant), and it survives 10× where the
  unpaginated contract does not (27,390 rows is ~30 MB of managed entities *and* a 27,390-element JSON
  array; a picker that renders 27k rows is not a picker).

> **Per-row `validate()` here is deliberate and is NOT the anti-pattern the superseded section
> forbade.** The forbidden thing was per-row evaluation over an unbounded set. Over a bounded page it
> is ~50 calls, the small tables are L1-served after the first, and it keeps **one** authority for P2.
> Do not "optimise" it into a second copy of the predicates — that is the hazard
> `PutawayConfigController`'s own comment names.

##### 3.11.0.2 Step B — write the guard that this plan wrongly claimed already existed

`PutawayDestinationValidatorUnitTest` does not exist. Actual coverage of the predicate chain today is
**indirect**: `PutawayConfigServiceUnitTest` constructs a *real* `PutawayDestinationValidator` over
mocked repositories (deliberately — stubbing it would be tautological). Measured against the chain, that
reaches **4 of 8 keys**. Unexercised:

| Branch | Status |
|---|---|
| P2.2 `putawayDestinationLocked` | ✗ every fixture sets `NOT_LOCKED`; the `null`-`entityLock` guard too |
| P2.4 `putawayDestinationAreaNotUsable` | ✗ **never fires** — the only neither-goods-in-nor-storage fixture gets the lane exemption at MERCHANT and is caught by P2.3 first at SKU |
| `transferlane` / `automationlane` / `gate` | ✗ ✗ ✗ all three `rejectIfTrue` sites unreached |
| P2.3 `crossdockinglane` | ✗ |
| P2.7(e) at WAREHOUSE scope | ✗ scope asymmetry untested |
| P2.7(f) dir-1 gated on `isFlowbin` (a **non**-flowbin bound to another SKU must PASS) | ✗ — the (iv-b) "P2.5 is dropped" semantics are unpinned |
| **P2.6 flowbin skip** | ✗ nothing asserts an incompatible-type flowbin still PASSES at SKU scope — the ICE PACK case |
| P2.6 `defaultUnitloadTypeId == null` skip; `locationType == null`; `subjectItemdataId == null` | ✗ |
| **which key wins on multi-failure** | ✗ entirely |

**So a reordering, an inverted lane flag, a dropped `isFlowbin` gate, a lost flowbin skip, or a broken
lock check would all ship green today.** Six of eight keys are effectively unguarded.

Step B must produce, from a real validator over mocked repositories: **all 8 distinct keys**, every row
above, and at least three deliberately multi-failing locations asserting the **winning** key. **Assert
`getKey()` AND `getMessage()`** — only the latter catches a dropped message argument (§3.11.0.4 M1).

##### 3.11.0.3 Step D — the N+1 that is already merged, and is bigger than the one this plan set out to avoid

`PutawayConfigService.countIncompatible` (`:417-427`) and `summariseScope` (`:462-479`) loop
`validate()` over `skusInScope(...)`, which at WAREHOUSE scope is `itemdataRepository.findAll()` —
**8,804 SKUs on `wms2-wineco-dev`, all with `defultype_id` set.** The `locationId` is constant across
the loop, so the three `findById` calls collapse in L1, but
`locationConstraintRepository.findByStoragelocationtypeId` is a **derived query with no `@Cacheable`**
and re-executes every iteration: **~8,800 queries on a single `GET /putawayConfig/preview?scope=WAREHOUSE`,
already live, and deliberately not admin-gated.**

That is larger than the number this plan used to justify the extraction, and the plan never mentioned it.
Step D builds **one** `Ctx` for the constant `locationId` outside the loop and varies only
`subjectItemdataId` + `defaultUnitloadTypeId` — which is why those two must be `evaluate` **parameters**,
not `Ctx` fields.

**Acceptance criterion for D, stated as a number because the whole justification is a number:** assert
the query count before and after (Hibernate statistics or a datasource proxy in a unit test). Nothing
else can gate "one constraint query instead of 8,800", and no textual verify row can.

##### 3.11.0.4 Step C — the extraction, with the four things the review found missing

```java
// service/PutawayDestinationRules.java — a @Service bean with ZERO dependencies, not a static utility.
public record Ctx(Location location, LocationType type, LocationArea area,
                  Long flaItemdataIdForLocation,   // FLA bound to this location, or null
                  Long flaLocationIdForSku,        // pick face this SKU already owns, or null
                  boolean unitloadTypePermitted) {}

public record Verdict(boolean eligible, String messageKey, List<Object> args) {}

public Verdict evaluate(PutawayScope scope, Ctx ctx, Long subjectItemdataId, Long defaultUnitloadTypeId)
```

1. **`defaultUnitloadTypeId` is a fourth PARAMETER.** P2.6's throw carries two args and
   `messages.properties:24` is `Location %1$s does not accept unit load type %2$s, …`. Without it the
   facade's rethrow supplies one arg, `String.format` raises `IllegalFormatException`,
   `BusinessException` **catches it** and falls back to `concatenateKeyAndParameter`, and the live 422
   `detail` silently degrades to `"putawayDestinationTypeIncompatible, 'GoodsIn01'"`. `getKey()` is
   unaffected — which is exactly why no existing test would catch it, since they all assert `getKey()`
   by design. A parameter, not a `Ctx` field: it is per-subject, like `subjectItemdataId`, and putting
   it in `Ctx` duplicates one scalar 2,739 times.
2. **P2.1 stays in the facade.** `Ctx` presupposes a resolved `Location`; `entityNotFoundForId` needs a
   `locationId` that `Ctx` does not carry. **`evaluate`'s behaviour for a null `ctx.location()` is
   undefined and must stay undefined** — the facade guarantees it never happens, and the bulk read
   sources locations from a query where they always resolve.
3. **The evaluation ORDER is the contract.** The live order is **not** the P2.x numbering — it is
   P2.2 → flowbin derivation → P2.3 (SKU staging/crossdock) → transferlane → automationlane → gate →
   P2.7(e) → P2.4 (with the lane exemption) → P2.7(f) dir 1 → dir 2 → **P2.6 last**. `evaluate` returns
   the **first** failing predicate. This is behaviour, not style: `blockingReason` is wire-visible, and
   **1,345 of 2,068 flowbins fail two or more predicates**, so multi-failure is the majority path at SKU
   scope, not an edge. A "tidy up the numbering" refactor changes which key wins. Model the chain as an
   **ordered list of predicates** so a later collecting fold (`evaluateAll`, for a picker that wants
   *all* reasons) is addable without a rewrite.
4. **`unitloadTypePermitted` is built short-circuited:**
   `flowbin ? true : constraintService.isUnitloadTypePermitted(location.getTypeId(), defaultUnitloadTypeId)`.
   Eager evaluation is logically equivalent (the service returns `true` for a null type and fails open on
   an empty constraint set) but would issue a `location_constraint` query for 2,068 of 2,739 locations
   that the merged path skips — a query-profile change inside a commit claiming behaviour preservation.

**A `@Service` bean, not `static`.** The purity is worth protecting — a class with no repository fields
structurally cannot touch a datasource, which matters most in a codebase whose worst mistake is a bare
`@Transactional` hitting the landlord DB. But `static` is the wrong protector: **pin it with an ArchUnit
rule** (no dependency on `..repo..`, no `@Transactional`), which this repo already runs and which a
textual verify row cannot match. And `static` fights the next requirement: a sysprop-gated predicate
would have to be hoisted into `Ctx` by *every* caller, and `PutawayDestinationResolver:59-65` already
establishes the opposite pattern for metrics, arguing the counter must live *inside* the rejecting method
*"rather than at the call site: … a counter that lives beside the caller can be forgotten by the next
caller added."*

**`Verdict.args` is a `List<Object>`, not `Object[]`.** A record with an array field gets
array-**identity** `equals`, so the obvious assertion — `assertThat(verdict).isEqualTo(new Verdict(...))`
— fails against a correct implementation. That is the third gate this plan would have written to fail a
correct implementation.

**Null-guard the `Ctx` builder** on `location.getAreaId()` and `getTypeId()`. Eager construction makes two
conditional loads unconditional, and `findById(null)` raises `IllegalArgumentException` → HTTP 500 where
today the request passes. Measured zero nulls across all 2,739 rows on `wms2-wineco-dev`, so no live data
reaches it — guard anyway rather than rely on the data.

##### 3.11.0.5 The divergence rule — write it down or the shared evaluator rots

One `evaluate` serves a **throwing writer** (must be exact) and a **bulk reader** (must be cheap). They
will diverge. The rule that keeps that safe, and it is one-directional:

> **The shared evaluator may make the read more PERMISSIVE than the write. Never stricter.**

A reader stricter than the writer *hides a legal destination* — a silent failure with no error to trace.
That is precisely the direction the existing SQL restatement got wrong:
`LocationRepository.getPutAwayCandidateLocations`'s own javadoc admits it is *"deliberately STRICTER than
the Java gate, not an exact mirror"* and that the two *"agree on today's data"* — duplication that has
already drifted, documented rather than prevented. When the writer gains a check the reader cannot
afford, that check stays in the **facade**, outside `evaluate`; reader-`eligible == true` then no longer
implies the write succeeds, which is fine because the preview is already advisory and the writer already
recomputes.

**Not shared, ever:** mobile putaway's `verifyScannedLocation`. P2 deliberately does not run at receive
time — `PutawayDestinationValidator:18-24` — because applying it there would reject tier 4 (`PutAwayLane`
sits in an `Inbound` area with `useforstorage = false`) and break receipts that work today. Scope the
ArchUnit rule to who may depend on the rules bean.

##### 3.11.0.6 Deliberately NOT doing

- **No Caffeine cache** on `location_type` / `location_area` / `location_constraint`. 21 rows total;
  every `@Cacheable` key in this repo is hand-prefixed for tenancy, so each new cache is a fresh
  cross-tenant leak surface. Paging removes the need. *(A `@Cacheable` on
  `isUnitloadTypePermitted` was raised as a cheap prior fix for §3.11.0.3's live N+1 — it needs
  invalidation analysis against `createEntity` and the HAL `@RepositoryRestResource` before anyone
  asserts it is safe, and step D removes the need. Recorded as an option, not adopted.)*
- **No `@PreAuthorize` on the new read.** It matches `preview`'s explicit rationale — *"it reveals no
  more than the location list the picker already shows"*. Stated so an implementer does not guess and a
  reviewer does not have to ask.
- **`PutawayDestinationResolver.resolve`'s `Propagation.MANDATORY` is a non-issue here** — this read
  never calls the resolver. Stated so a reader does not have to verify it.

#### 3.11.0a `BlockingReason` needs four more values — and this plan owns the enum

`PutawayConfigController.java:65` ships `{LOCKED, FIX_ASSIGNED, LANE}`, and its own Javadoc `:58-64`
records the gap: nothing distinguishes a flowbin bound to **this** SKU (legal under the rule-(e) tier-1
exemption) from one bound to **another** (illegal under rule (f)). Worse, `blockingReasonFor(...)`
(`:133-152`) returns **`null` for every unmapped key** while `compatible` is already `false` — so the
picker is told "blocked, reason unknown."

| Validator throw | Current mapping | r-next mapping |
|---|---|---|
| `putawayDestinationBoundToAnotherSku` (`:179`) | `FIX_ASSIGNED` | **`BOUND_TO_ANOTHER_SKU`** |
| `skuAlreadyBoundToAnotherPickFace` (`:190`) | `FIX_ASSIGNED` | **`BOUND_TO_ANOTHER_SKU`** |
| `putawayDestinationAreaNotUsable` (`:128`) | **`null`** | **`AREA_NOT_USABLE`** |
| `putawayDestinationFlowbinNotAllowedForScope` (`:112`) | **`null`** | **`FLOWBIN_SCOPE`** |
| `putawayDestinationTypeIncompatible` (`:149`) | **`null`** | **`TYPE_INCOMPATIBLE`** |
| `putawayDestinationLocked` (`:80`) / `putawayDestinationIsALane` (`:95, :201`) | `LOCKED` / `LANE` | unchanged |

**Scale of the omission, measured 2026-08-11:** on `wms2-wineco-dev` **1,345 of 2,068** flowbins are
already FLA-bound — so at SKU scope the single most common rejection is the one the enum cannot name.
Three keys mapped to `null` means three more silent classes.

> **Ownership note for SBDEV-2643:** 2643 MUST-4 forbids 2643 extending this enum from its own PR, and
> correctly so. That makes the extension **this plan's obligation, in Phase 2**, and 2643's picker is
> blocked on it exactly as this plan's two are.

#### 3.11.1 Receiving form — **narrowed**: SBDEV-2731 shipped the display; this plan adds the diversion

**Do not rewrite this component.** PR #39 (`4ce39a1`) already delivered the label binding, the source
chip position, the tri-state guard and the label mapping. Verify before editing:

| Construct | `receivingForm.vue` | Status |
|---|---|---|
| `putawayStaging` data prop | `:228` | **live** — bound at `:336` from `newVal.defaultputawaylocationname` |
| `isPutawayDestinationApplied` tri-state | `:296-300` | **live** — returns `true` / `false` / `null` |
| Template tests `=== false` | `:24` | **live, load-bearing** (`:20-23` carries the comment explaining why) |
| `isPutawayOverride` ANDs on `=== true` | `:301-304` | **live** |
| Name-vs-label constants | `:221-222` | **live** — `'PutAwayLane'` for comparison, `'Put Away Lane'` for display |

**Three changes only:**

1. **Re-source, do not re-shape.** Replace the `:336` assignment from `newVal.defaultputawaylocationname`
   with `GET /receiving/getPutawayDestination/{advicePositionId}` (`ReceivingController.java:80-87`),
   assigning **`envelope.locationName`** into `putawayStaging`. Keeping `putawayStaging` a location
   **name** preserves `isPutawayOverride` (`:302-304`) and the label computed (`:307-313`)
   **byte-for-byte**, so SBDEV-2731's `A10` / `T24` / `T25` stay green. Everything else arrives in new
   data props — never by widening the meaning of `putawayStaging`.
2. **Render `sourceLabel` as a subdued chip** beside the existing `(SKU override)` span at `:19`. The
   envelope supplies `source` (the enum NAME) *and* `sourceLabel` (the display string) precisely so Vue
   never re-derives precedence (`ReceivingController.java:105-106`).
3. **NEW, and the reason this subsection still exists — render the diversion.** The envelope carries
   `divertedTo` + `divertedReason` **only when (iv-b)'s gate retargeted the receipt**
   (`ReceivingController.java:113-119`), and `warning` only when P1 failed against the *placement*
   (`:122-124`). Both are **absent, not null**, in the common case.

> **Why item 3 is not optional.** Under (iv-b) a pick-face destination is configured but **not placed**
> at receipt: the receipt goes to the standard lane and putaway routes it. Without this rendering the
> screen shows `ICE PACK` while the unit load lands on `PutAwayLane` — an operator-visible lie, and the
> same defect class as SBDEV-2731 itself. Required copy, per SBDEV-2643 D1: say the destination is
> **routed via putaway**, not placed directly, **and** state the consequence — *the stock is not on the
> pick face when the receipt closes; it arrives when someone puts it away.*

Render `divertedTo` as a distinct line, never by overwriting `putawayStaging`: the admin's configured
value must stay visible beside where the stock will actually land. **The wording needs product sign-off
(Scott Dalton / David Oppenheim) before merge** — it is what an operator reads to understand why stock
is not where the configuration says it is.

#### 3.11.2 Warehouse default — Operation Options

`editParamAndConfig.vue:23` and `addParamAndConfig.vue:22` both branch on
`groupName == 'Operation Options' || groupName === 'System Settings'`, rendering a free-text
`v-text-field` for `sysvalue`. Add a nested `syskey === 'DEFAULT_PUTAWAY_LOCATION'` branch rendering
**`defaultPutawayLocationField.vue`** at `scope=WAREHOUSE` instead of the text field.

> [!note] **CORRECTED 2026-08-11.** This said "rendering `LocationPicker` (§3.11.5)". Step 20 introduced
> a wrapper instead, because the preview gate, D11's count-and-confirm and the typed write are needed in
> **four** places — the edit dialog, the add dialog, the unconditional Operation Options control, and
> step 21's shipper screen — and three copies of a confirmation gate is how one ends up without it.
> `LocationPicker` stays presentational. A verify lane flagged that §3.11.3 was corrected in place while
> this section was not; that inconsistency is what this note closes.

**Render the control unconditionally** — whether or not a `DEFAULT_PUTAWAY_LOCATION` row appears in the
`findByGroupname` list (`store/admin/configuration.js:52`). Two independent reasons: `V2.2.13`'s seed may
not have run on a given tenant, and D12 lets an operator delete the row. Since
`POST /v3/systemProperty/create` rejects this syskey (§3.9.1), a list-driven control leaves the warehouse
tier unreachable from the UI in both cases. `setWarehouseDestination` creates the row on first write
(§3.5).

**Write path: `PUT /putawayConfig/warehouse` (`PutawayConfigController.java:204-207`).** Never
`PUT /sysprop/{id}` and never `POST /systemProperty/create`. The generic dialog's three existing write
actions — `configuration.js:73-93` (`$put /sysprop/${id}`), `:95-123` (`$post /systemProperty/create`),
`:125-147` (`$delete /sysprop/${id}`) — stay in place for every **other** syskey. **Two of the three
bypass the event handler entirely** (§3.9.1), so reusing them ships an unvalidated, unaudited warehouse
tier — the highest-blast-radius tier in the plan. Add one new action for the typed endpoint.

**Config-health gate before Save.** Call `GET /putawayConfig/preview?scope=WAREHOUSE&locationId=<id>`
(`PutawayConfigController.java:93`) and render `incompatibleSkuCount` / `totalSkuCount` /
`exampleIncompatibleSku`. A non-zero count drives D11's confirm dialog, which re-issues the write with
`confirmIncompatibleSkus=<n>`; a **non-null `blockingReason` disables Save outright**. The envelope is a
7-field record (`PutawayConfigController.java:47-53`) — bind it, do not re-derive any of it.

#### 3.11.3 Merchant default — shipper screen

`editShipper.vue` gains one field in the existing stack (`:32-45` is the Assigned-Zone select — label
`:32`, `v-select` `:37-45`; `:50-63` is the Receiving-Printer select — both are the idiom to copy).

> [!warning] **CORRECTED 2026-08-11 (step 21) — this section named the wrong read source, and it is the
> SAME defect §3.11 defect 1 caught for `/location/detailView`.**
>
> The original text said the field is *"bound to `defaultputawaylocationId` and read from
> `/client/detailView` (`store/admin/shippers.js:20-22`)"*. **The column is not in that payload.**
> `ViewDtoService.getClientView()` (`:934-957`) hand-builds the DTO and puts exactly eight keys: `id`,
> `clientName`, `clientNumber`, `sectionName`, `enablereceiving`, `printerName`, `printerreceivingId`,
> `sectionId`. Adding it there would touch a DTO five other screens consume, for no gain.
>
> **Implemented against `GET /client/{id}/effectivePutawayDestination`** (N9), which already carries
> everything the three-state control needs — including the `inherited` boolean. Recorded as a plan
> defect rather than silently worked around, because the same wrong assumption has now appeared
> **twice** in this plan: a `detailView` endpoint presumed to carry a column it does not.

**Write through `PUT /putawayConfig/merchant/{clientId}` (`PutawayConfigController.java:186-189`), not
through `editShipper`.** `store/admin/shippers.js:45-55` is `$patch('/client/${id}', data)` (`:47`) — the
HAL path, which carries no validation, no audit, no cache eviction and cannot carry D11's confirmation.
`editShipper.vue:129-132`'s `save()` dispatches exactly that, so the new field must be **excluded from
the patched payload** and written by its own dispatch. A field that rides along in the existing PATCH
silently defeats the whole typed write surface.

**The three-state control is now directly bindable — do not re-derive it.**
`GET /client/{id}/effectivePutawayDestination` (`ClientController.java:67-79`) returns
`{locationId, locationName, source, configuredFor, inherited}`, where **`inherited` is already the
boolean the control needs** (`:78` — `source != MERCHANT_OVERRIDE`):

| State | Condition | Presentation |
|---|---|---|
| **Configured** | `inherited === false` | `locationName`, normal weight |
| **Inherited** | `inherited === true` | `locationName` greyed, with `source` naming the tier it came from |
| **Cleared** | operator action | `locationId` omitted → the validator returns early (`PutawayDestinationValidator.java:66-68`), so clearing is always legal |

Same `LocationPicker` at `scope=MERCHANT`, and the same
`GET /putawayConfig/preview?scope=MERCHANT&subjectId=<clientId>&locationId=<id>` driving
`incompatibleSkuCount` and the confirm dialog.

#### 3.11.4 persistedState — corrected coordinates

`plugins/persistedState.client.js:22-25` is a **single top-level reducer** (`reducer:` on `:24`) excluding
exactly three keys — `warehouseTimezone`, `selectedWarehouse`, `warehouses`. Everything else,
**including the whole `admin` module and therefore `admin.configuration.operationOptions`**, is persisted
to `localStorage['vuex-web']`.

This is the same failure class as the stale-timezone bug (SBDEV-2726): a rehydrated prior value
overwrites the fetched one, and cross-tenant it would show one tenant's location id in another tenant's
admin screen. Add the putaway config keys to the exclusion. Note the plugin's self-heal idiom at
`:30-31` — a re-assert from a dedicated key after rehydration — if the simple exclusion proves
insufficient for already-deployed browsers.

#### 3.11.5 `components/common/LocationPicker.vue` — the component contract

**Precedent (corrected).** The repo's only `v-autocomplete` in that family is
`components/outbound/bol/create/createBol.vue:68-76` — `v-model` `:69`, `:items` `:70`,
`item-text="label"` `:74`, `item-value="value"` `:75`. The other naive precedent is
`moveFixedLocation.vue:13`. **There is no "Lookup" button anywhere in `createBol.vue`** — the old
citation invented a control that does not exist.

**Props / events.** This is the contract SBDEV-2643 §3.8.2b specified and handed to this plan (2643 `Q6`
/ `D14`); adopting it verbatim closes 2643 §5.1 row 0b.

| Prop | Type | Contract |
|---|---|---|
| `value` | `Number` or `null` | `v-model` — the selected `locationId`; `null` means cleared / inherit |
| `items` | `Array` | rows from `/putawayConfig/eligibleLocations`, **passed in by the caller**, not fetched by the component. ⚠ **That read is PAGINATED as of 2026-08-11 (§3.11.0.1)** — the caller owns paging and accumulation, and must handle a partial set rather than assuming one response is the whole facility. **`totalCount`** reads the envelope's `totalElements`; **`eligibleCount` is necessarily counted from the accumulated rows** — corrected 2026-08-11: the `EligibleLocation` record carries no such field, so the original "reads the page metadata" was true of one number only. |
| `disabled` | `Boolean` | the permission gate (§3.12) |
| `item-text` / `item-value` | `String` | `'locationName'` / `'locationId'` |

| Event | Payload |
|---|---|
| `@input` | the `locationId`, for `v-model` |
| `@select` | **the full row**, so the caller reads `blockingReason` / `tier` without re-deriving anything |

**Two tiers, driven by the server's `tier` field — never by a client-side flag test:**

| Tier | Contents | Presentation |
|---|---|---|
| default | `tier === 'DEFAULT'` (`useforgoodsin`) | shown immediately in the autocomplete |
| advanced | `tier === 'ADVANCED'` (storage-only) | behind an explicit **"Show storage locations"** toggle that reveals the lock-contention warning |

**The advanced tier's warning stays, unchanged and mandatory.** Pointing a tier-2/3 default at a live
storage location moves a `FOR UPDATE` lock onto a row replenishment and transfer also lock, in the
opposite order (§7.6 row 8). The text must say that receiving holds a lock on the chosen location for the
duration of a whole multi-case receipt, and that a location in active use may cause receipts to fail with
a deadlock. **There is no deadlock-retry infrastructure in this codebase** (SBDEV-1762: an up-front
lane-Location lock is a cross-caller `40P01` anti-pattern).

**The currently-selected row is always offered, tier notwithstanding — added 2026-08-11 from step 19's
implementation.** A tier-2/3 default already saved against a storage location carries
`tier === 'ADVANCED'`, so the two-tier filter above, read literally, leaves it out of the autocomplete's
items and the field renders **empty** — telling an operator nothing is configured when something is. The
tier gate exists to stop a storage location being *chosen* without the warning, not to hide one already
in effect. `eligible` is **not** relaxed by this: a saved destination that has since become invalid stays
unoffered, because surfacing it is step 22's job. **Steps 20, 21 and SBDEV-2643's SKU picker all inherit
this**, since all three can load a previously-saved advanced-tier value.

**An unrecognised `tier` fails CLOSED** (step 19). Only `DEFAULT` and `ADVANCED` are offered; anything
else appears in neither tier, because promoting an unknown value to the visible tier is precisely how a
storage location reaches an operator without the lock warning.

**Ineligible rows are not offered.** `eligible === false` rows are excluded from `items` by the caller;
the picker renders no third "offered with a warning" state. When the eligible set is small relative to
the facility, the caller shows `{eligibleCount}` of `{totalCount}` so an operator never concludes the
search is broken (SBDEV-2643 §3.8.2a).

##### 3.11.5a The eligible set is scope-dependent in five places — measured

The old §3.11.2's single "exactly P2.4" filter cannot express this. Derived from
`PutawayDestinationValidator.java:63-193` as merged:

| Predicate | SKU (tier 1) | MERCHANT / WAREHOUSE (tiers 2/3) |
|---|---|---|
| P2.2 `entity_lock == 0` (`WmsConstants.java:1209`) | reject | reject |
| `transferlane` / `automationlane` / `gate` | reject | reject |
| `staginglane` / `crossdockinglane` | **reject** (`:94-95`) | **PERMIT** — no reject fires; rationale at `:88-91` |
| `sltname == 'flowbin'` (`WmsConstants.java:736`) | **PERMIT** — rule (e) tier-1 exemption (`:111`) | **reject** (`:111-113`) |
| area `useforgoodsin OR useforstorage` | require (`:126-128`) | require **unless** staging/cross-dock (`:120`) |
| P2.7(f) FLA coherence (`:164-193`) | apply — needs `subjectId` | n/a |
| P2.6 unit-load-type heuristic (`:137-150`) | apply, **skipped for flowbin** (`:146`) | apply |

**Measured 2026-08-11, SELECT-only, both DEV tenants:**

| Tenant | total locations | SKU-scope eligible | merchant/warehouse eligible | flowbins (of which FLA-bound) |
|---|---|---|---|---|
| `wms2-wineco-dev` (`dev_wh01_om1`) | 2,739 | **2,554** | **516** | 2,068 (1,345) |
| `wms2-hydra-dev2` (`wh01_hydra_v2`) | 666 | **602** | **112** | 496 |

Zero locked rows on either tenant, so P2.2 excludes nothing today — it is a correctness guard, not a
filter. The `PutAwayLane` exclusion accounts for the 1-row gap against SBDEV-2643's 2,555.

**This settles §10 Q2, and settles it differently per scope.** Q2 asked whether a preloaded,
client-side-filtered picker scales, with the remedy *"if any tenant exceeds ~2,000, add a search
parameter."* **Phase 2's own two pickers do not cross the threshold** — 516 and 112 rows. **SKU scope
does** — 2,554 on wineco-dev. So the remedy belongs to whoever ships the SKU picker (SBDEV-2643 Phase
B2), and it is a **paging/search parameter on `/putawayConfig/eligibleLocations`**, not on
`/location/detailView` — the latter would re-open defect 1 by inviting a client-side filter over a
payload carrying no flags. **Recorded as an explicit hand-off, not a silent cap.**

### 3.12 Permissions — bounded decision (AC item 7)

**There is no frontend role gating in this app.** `layouts/default.vue:284-286` returns the `'super-admin'` menu unconditionally for every authenticated user; `adminMenu` (`:264-268`) is never referenced; `APP_ADMIN_GROUP` (`nuxt.config.js:167`) is read nowhere. `store/index.js:92-101` `getUserRoles` and `:103-117` `getAffiliatedGroupsByUsername` already fetch roles, and nothing gates on them.

> [!warning] **`Authority.IS_SB_ADMIN` was BROKEN when this section was written, and is now FIXED. Added 2026-08-09.**
>
> Between `ded4d644` (2025-10-29) and 2026-08-07 the constant was the string `"isSbAdmin()"`, naming a
> SpEL method that existed on no expression root — the rename that introduced it moved
> `IS_AIM_ADMIN`/`isAimAdmin()` but left the root's method named `isAimAdmin()`. **Every
> `@PreAuthorize(Authority.IS_SB_ADMIN)` therefore threw `SpelEvaluationException EL1004E` inside the
> authorization check and returned HTTP 500 to every caller, a genuine `sb_admin` included.** Had this
> plan merged as written before that date, **all six of its admin-gated writes would have 500'd for
> everyone** — and neither M16 nor M16a would have read as a security failure, only as a broken endpoint.
>
> **[SBDEV-2863](https://app.clickup.com/t/868knmx18) fixed it — merged 2026-08-07, `wms2-api` PR #134,
> commits `675b4a1` + `d8e0137`, merge `7d9d38e`, ClickUp `on dev`.** `Authority.java:44` now reads
> `IS_SB_ADMIN = "hasAuthority('" + SB_ADMIN_ROLE + "')"`, and the same commit added a `@Nested
> AuthorityExpressionsResolve` test that evaluates the constant through the real
> `CustomMethodSecurityExpressionHandler`.
>
> **Consequences for this plan — all favourable, and no edit is required:**
> - **Every `@PreAuthorize(Authority.IS_SB_ADMIN)` below is CORRECT as written.** Keep the constant; do
>   **not** swap it for `Authority.getExpForRole(Authority.SB_ADMIN_ROLE)`. Since `675b4a1` the two
>   render the identical string, and 2863's `getExpForRole_expressionResolves` asserts that equality so
>   they cannot drift.
> - **SBDEV-2643 §5.1 row 0e — *"2732 must NOT merge carrying `Authority.IS_SB_ADMIN`"* — is
>   DISCHARGED**, and its verify probe `X-2732-authz` has been **deleted**: it asserted the *absence* of
>   this annotation and **would have failed this plan's correct implementation**. It is replaced by
>   `X-authz-constant`, a regression guard on `Authority.java` itself.
> - **M16 / M16a now expect 403 and mean what they say.** A **500** on either is a regression of 2863,
>   not a defect in this plan.
> - Prerequisite §5.1 row 7 is updated to match.

> [!note] **HOW `sb_admin` ACTUALLY REACHES THE TOKEN — confirmed with the user 2026-08-11, and it
> closes the residual risk this section carried.**
>
> `sb_admin` is granted by **Keycloak GROUP membership**, so it arrives in the **`groups`** claim — not
> under `resource_access`. Both sides read it: the API's `JwtAccessTokenCustomizer.extractRoles`
> harvests `GROUP_ELEMENT_IN_JWT = "groups"` (`:98`), and `util/keycloakRoles.js` reads
> `tokenParsed.groups`. **A genuine `sb_admin` therefore gets an enabled control, verifiable without a
> live session.**
>
> ⚠ **This makes the original gate worse than recorded.** `hasResourceRole('sb_admin', clientId)` reads
> `resource_access[clientId].roles`, and a group membership is not there — so it returned `false` for
> **every real `sb_admin`, on every tenant, permanently**, independent of `KEYCLOAK_CLIENT`. H1b was not
> a deployment-dependent edge case; the control would simply never have enabled for anyone entitled to
> it.
>
> **WMS operational users are unaffected either way:** they are assigned `wms_user` and/or `wms_admin`
> only, and never touch these admin write endpoints. `sb_admin` gating is also the house pattern rather
> than something this plan introduced — at this plan's base commit `fd90487` the API already carried 13
> `@PreAuthorize(Authority.IS_SB_ADMIN)` gates (12 in `AdminController`, 1 in
> `ReplenishmentReconciliationController`), and all 18 live gates use it.
>
> Observation, not an action: `Authority.getExpAppAdminGroupOrSbAdminGroup(...)` and
> `getExpAppUserGroupOrAppAdminGroup(...)` are **defined and never used anywhere**. If product ever
> wants WMS admins to self-serve putaway config rather than routing through SiteBoss staff, that helper
> is where the wms_admin-or-sb_admin expression already exists — a product decision, not a defect.

**Decision:** the security boundary is the **backend**, and it is enforced **in `PutawayConfigService`, not on the event-handler methods**.

- `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigController`'s three write endpoints (the pattern used throughout `controller/AdminController.java` — ⚠ **re-derived 2026-08-11 (SBDEV-2643 §10.3 C5): the ACTIVE sites are `:80, 108, 121, 134, 143, 155, 176, 200`, and `:190, 261, 285, 315` are commented out. Only `121` and `134` matched the list previously cited here. And the sites are no longer broken — SBDEV-2863 repaired the constant on 2026-08-07** — superseded citation was `:93, 121, 134, 147, 156`).
- `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigService.setSkuDestination`, `setMerchantDestination`, `setWarehouseDestination` **and `validateOnly`**. `validateOnly` is the method the event handler calls, so this is what makes the HAL channel admin-only.
- **Nothing on the handler methods.** Spring Data REST registers handler beans via its own `AnnotatedHandlerBeanPostProcessor`; Spring Security's method-security advisor comes from a different post-processor, and depending on ordering SDR may capture the raw target rather than the security proxy — in which case an annotation on a handler method is **inert and silently never fires**. `PutawayConfigService` is an ordinary `@Service`, reliably proxied, and the handler invokes it from outside the bean, so the check cannot be bypassed by proxy-capture. §3.9.4.
- `AccessDeniedException` is unchecked, so it propagates out of the handler and Spring Security maps it to **403** — ahead of any 422 from validation.

Phase 2 additionally *hides* the fields — a convenience, not a control.

> [!warning] **`affiliatedGroups` CANNOT EXPRESS THIS GATE — corrected 2026-08-11 after review.**
>
> This section prescribed `affiliatedGroups`, and a review lane was right that Phase 2 used something
> else. But the prescription is not implementable: `affiliatedGroups` comes from
> `GET /userGroup/search/findByUsername` and holds WMS **`mywms_group.name`** values — measured on
> `wms2-wineco-dev` they are `CS-REP`, `GROUP000008`, `GROUP000009`, … — warehouse groups, with nothing
> role-like and no `sb_admin` anywhere. Gating on it would hide the field from everyone or no-one.
>
> **What Phase 2 does instead** (`util/keycloakRoles.js`): mirror the API's own resolution.
> `JwtAccessTokenCustomizer.extractRoles` (`:86-106`) harvests roles from **every** client under
> `resource_access` **plus** the `groups` claim, and `hasAuthority('sb_admin')` tests that set. The
> client gate reads the same two claim sites, so it cannot be narrower than the endpoint it fronts.
>
> ⚠ **The first implementation was narrower, and it was a real lockout.** It called
> `$kc.hasResourceRole('sb_admin', $config.keycloak.clientId)` — one client's roles, and that clientId
> was `process.env.KEYCLOAK_CLIENT`, a build-wide value, while the token is issued by the **per-tenant**
> client from tenant discovery. Worse, it was a **computed over a non-reactive injected object**, so it
> cached `false` from the pre-init render and never recovered.

**Proof.** Manual row **M16** (typed endpoints ⇒ 403) and **M16a** (`PATCH /v3/sysprop/{id}` as a non-`sb_admin` ⇒ 403, not 422 and not 200). A verify row asserts `@PreAuthorize` appears in `PutawayConfigService.java` and **not** in `PutawayConfigRepositoryEventHandler.java`.

**Explicitly out of scope:** introducing a general web-UI role-gating framework. That is a cross-cutting change touching every screen and belongs in its own ticket (§8.4). Stating this is what keeps the AC from being *implicitly* unmet: the AC is met by backend enforcement, and the frontend gap is named rather than papered over.

### 3.13 Observability — net-new

There is no `MeterRegistry`, `Counter` or `Timer` anywhere on the receiving path (§2.8). **New file** `src/main/java/net/aim_ai/wms/service/PutawayResolutionMetrics.java`, modelled on `schedulejob/JobMetrics.java` (a final class holding an injected `MeterRegistry`, one method per event):

| Metric | Type | Tags | Answers |
|---|---|---|---|
| `wms2.putaway.resolution` | counter | `source` (4 values), `carrier` (true/false), **`compatible` (true/false)**, `tenant` | **Is the feature actually in use?** The tier-2/3 counts staying at zero is pre-mortem P2's leading indicator. The `compatible` tag makes the carrier-path "destination surfaced but not applied" case queryable as `resolution{carrier="true",compatible="false"}` **without** polluting `resolution.rejected`, which alerts on `>0`. |
| `wms2.putaway.resolution.rejected` | counter | `scope`, `reason`, `tenant` | receive-time backstop firings — pre-mortem P3's leading indicator |
| `wms2.putaway.config.rejected` | counter | `scope`, `reason`, `channel` (typed/hal), `tenant` | write-time validation working |
| `wms2.putaway.config.changed` | counter | `scope`, `channel`, `tenant` | who is still bypassing the UI (`channel="hal"` > 0) |

Cardinality is bounded: `source` 4 × `carrier` 2 × **`compatible` 2** × `tenant` 5 = **80** series for the busiest metric. `tenant` matches `JobMetrics`' existing convention.

### 3.14 Audit table (D7 / ticket AC)

**New table** in `V2.2.13` (Phase 1 — the backfill pre-image needs somewhere to land, §5.1), modelled on `customerorder_cancellation_log`. The **entity, repository and audit service are Phase 1** (O1); Phase 1 creates the table and writes only the migration pre-image rows. Note that `CustomerorderCancellationLog` uses `GenerationType.IDENTITY` and does **not** extend `AbstractBaseEntity` — so this table gets its own `bigserial` and never touches `seqentities`, which sidesteps the dual-island id-space landmine on migrated tenants.

```sql
CREATE TABLE IF NOT EXISTS public.putaway_config_audit (
    id                         bigserial PRIMARY KEY,
    version                    integer      NOT NULL DEFAULT 0,
    tenant_name                varchar(50)  NOT NULL,
    facility_code              varchar(10)  NOT NULL,
    scope                      varchar(16)  NOT NULL,     -- SKU | MERCHANT | WAREHOUSE
    subject_id                 bigint       NULL,         -- itemdata.id | client.id | NULL
    subject_label              varchar(255) NOT NULL,     -- SKU number | client cl_nr | 'WAREHOUSE'
    previous_location_id       bigint       NULL,
    previous_location_name     varchar(255) NULL,
    previous_value_unavailable boolean      NOT NULL DEFAULT false,
    new_location_id            bigint       NULL,         -- NULL = override cleared
    new_location_name          varchar(255) NULL,
    channel                    varchar(16)  NOT NULL,     -- typed | hal | migration
    changed_by                 varchar(255) NULL,
    changed_at                 timestamptz  NOT NULL
);
CREATE INDEX IF NOT EXISTS putaway_config_audit_scope_subject_idx
    ON public.putaway_config_audit (scope, subject_id, changed_at DESC);
```

Location **names** are denormalised alongside the ids so the log stays readable after a location is renamed or deleted. No FK to `location` — an audit row must survive its subject.

**New service** `service/PutawayConfigAuditService.java`, `@Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)` exactly like `CancellationLogService.recordCancellation`. `changedBy` from `SecurityContextUtils.getUserName()` (already used at `ReceivingService.java:359, :508`); `tenantName`/`facilityCode` from `TenantContext.getCurrentTenant()`. `MANDATORY` guarantees the audit row commits with the config change or not at all — an audit that can survive a rolled-back change is worse than none.

**No new REST endpoint for reading the log in Phase 1.** The table is queryable by support via SQL; a UI for it is a follow-up (§8.4). The AC says "recorded", not "displayed".

---

## 4. File Change Summary

### Phase 1 — `v2/wms2-api` (**1a** unless the row says 1b)

| File | Add/Modify/Delete | Phase | Description |
|---|---|---|---|
| `src/main/resources/db/migration/V2.2.13__putaway_destination_hierarchy.sql` | **Add** | 1-API | **one** migration, statement order load-bearing (§5.1): preflight guard; `itemdata.putawaylocation_id DROP NOT NULL`; `putaway_config_audit` table + index; backfill pre-image; scoped NULL backfill; `client.defaultputawaylocation_id` + guarded named FK; `DEFAULT_PUTAWAY_LOCATION` sysprop seeded `''` |
| `service/PutawayDestinationResolver.java` | **Add** | 1a | §3.1 — the one shared 4-tier resolver, `Propagation.MANDATORY` |
| `service/PutawayDestinationQueryService.java` | **Add** | 1a | §3.1.5 — `readOnly = true` tenant-tx facade; the only way a controller reaches the resolver |
| `service/PutawayConfigService.java` | **Add** | 1a (merchant writer 1b) | §3.5 — validated + audited writers, `validateOnly` / `auditAndEvict` / `readCommittedDestination`, cache eviction, `@PreAuthorize` boundary |
| `service/PutawayDestinationValidator.java` | **Add** | 1a (MERCHANT scope 1b) | §3.4c — predicate P2 per scope + the D11 incompatible-SKU count |
| `service/PutawayConfigAuditService.java` | **Add** | 1b | §3.14 — `MANDATORY` audit writer |
| `service/PutawayResolutionMetrics.java` | **Add** | 1a | §3.13 — 4 Micrometer counters |
| `model/PutawayConfigAudit.java` | **Add** | 1b | §3.14 entity, `IDENTITY` id, no `AbstractBaseEntity` |
| `repo/jpa/PutawayConfigAuditRepository.java` | **Add** | 1b | plain `CrudRepository`, **not** `@RepositoryRestResource` |
| `config/PutawayConfigRepositoryEventHandler.java` | **Add** | 1a (`onClient*` 1b — O2) | §3.9 — HAL write guard for `Itemdata`, `Sysprop`, `Client`, incl. the `@HandleBeforeDelete` / `@HandleAfterDelete` pair (D12) |
| `exceptions/PutawayConfigValidationException.java` | **Add** | 1a | §3.9.7 — unchecked; the handler cannot throw `BusinessException` |
| `controller/PutawayConfigController.java` + `PutawayConfigPreview` | **Add** | 1a (`setMerchant` 1b) | §3.5a — the typed write surface and D11's count-and-confirm |
| `controller/RestExceptionHandler.java` | Modify | 1a | `@ExceptionHandler` for `PutawayConfigValidationException` ⇒ 422 with the rendered message (§3.9.7) |
| `controller/SystemPropertyController.java` | Modify | 1a | `:77` and `:107` reject `syskey == DEFAULT_PUTAWAY_LOCATION` (§3.9.1) |
| `model/Itemdata.java` | Modify | 1a | remove `@NotNull` at `:49` — same commit as `V2.2.13` |
| `model/Client.java` | Modify | 1b | add `defaultputawaylocationId` + accessors — same commit as `V2.2.13` |
| `service/WmsConstants.java` | Modify | 1a | add `SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY` |
| `service/LocationConstraintService.java` | Modify | 1a | add `isUnitloadTypePermitted` (§3.4b) |
| `service/UnitloadBusinessService.java` | Modify | 1a | `:180-193` delegates to the predicate; `:191` raw-concat throw → the **neutral** `unitloadTypeNotPermittedOnLocation` (§3.6.1) |
| `service/ReceivingService.java` | Modify | 1a | `:451-459` resolver call replaces the ternary; `:492` uses `putaway.location()` |
| `service/ItemdataService.java` | Modify | 1a | `setPutAwayLocation` delegates to `PutawayConfigService`; null guard at `:71` |
| `controller/ItemDataController.java` | Modify | 1a | `:80` `allEntries=true` → delegation; `:88-90` raw save → service call |
| `controller/ReceivingController.java` | Modify | 1a | add `getPutawayDestination` delegating to the §3.1.5 facade; `:314` literals → constants |
| `controller/ClientController.java` | Modify | 1b | add `GET /client/{id}/effectivePutawayDestination` (N9), delegating to the facade |
| `controller/rest/SkuRestController.java` | Modify | 1a | drop the lane lookup + argument at `:85-88, 144-146, 198-201, 257-259` — same commit as `V2.2.13` |
| `service/SkuBatchCreateUpdateService.java` | Modify | 1a | drop the `defaultPutawayLocationId` parameter (`:36`) and the setter (`:53`) |
| `controller/FileImportController.java` | Modify | 1a | drop the setter at `:383`; keep an equivalent lane-presence guard at `:355-359` |
| `src/main/resources/messages_en_US.properties` | Modify | 1a | add **both** `unitloadTypeNotPermittedOnLocation` and `putawayDestinationNotPermitted` (§3.6.1) |
| `src/test/.../unit/service/PutawayDestinationResolverUnitTest.java` | **Add** | 1a (tier-2 cases 1b) | §7.1 |
| `src/test/.../unit/service/PutawayConfigServiceUnitTest.java` | **Add** | 1a | §7.1 |
| `src/test/.../unit/config/PutawayConfigRepositoryEventHandlerUnitTest.java` | **Add** | 1a | §7.1 |
| `src/test/.../unit/controller/PutawayConfigControllerUnitTest.java` | **Add** | 1a | §7.1 — the D11 confirmation contract (409/422 split) |
| `src/test/.../smoke/PutawayResolverContextLoadTest.java` | **Add** | 1a | §7.2 — DI-wiring gate, `@Disabled` TODO(SBDEV-2217) |
| `src/test/.../unit/service/UnitloadBusinessServiceUnitTest.java` | Modify | 1a | `:193, 208` — new neutral message, deliberately |
| `src/test/.../unit/service/ReceivingServiceUnitTest.java` | Modify | 1a | resolver interaction + carrier path |
| `src/test/.../unit/service/LocationConstraintServiceUnitTest.java` | Modify | 1a | fail-open + allow/deny matrix |
| `src/test/.../unit/service/ItemdataServiceUnitTest.java` | Modify | 1a | `:418, 455, 482, 592` — nullable previous value |
| `src/test/.../unit/controller/ItemDataControllerUnitTest.java` | Modify | 1a | `:111, 120, 128, 138, 153` — the live write path is now validated |
| `src/test/.../unit/controller/ReceivingControllerUnitTest.java` | Modify | 1a | new endpoint + `BusinessException` envelope |
| `src/test/.../unit/controller/SystemPropertyControllerUnitTest.java` | Modify | 1a | `create` / `updateValue` reject the guarded syskey (§3.9.1) |
| `src/test/.../unit/controller/rest/SkuRestControllerUnitTest.java` | Modify | 1a | no seeded lane id |
| `src/test/.../unit/controller/FileImportControllerUnitTest.java` | Modify | 1a | no seeded lane id, guard retained |
| `src/test/.../unit/model/EntityUnitTest.java` | Modify | 1a | `:345, 370` — field no longer required |
| `src/test/.../unit/repo/ItemdataRepositoryTest.java` | Modify | 1a | `:32` |
| `src/test/.../common/fixtures/TestDataFactory.java` | Modify | 1a | `:694` |
| 3 H2 tests + 2 `@Disabled` ITs | Modify | 1a | listed in §3.2 |

### Phase 2 — `v2/wms2-web-ui` **+ one API read** (**1a-UI** = receiving form only; everything else is **1b-UI**)

> ⚠ **r-next: Phase 2 is no longer UI-only.** The three `2-API` rows below are new and they **gate**
> every UI row — no picker can filter client-side, because `/location/detailView` carries none of the
> predicate columns (§3.11 defect 1). See §3.11.0 and §3.11.0.1.

| File | Add/Modify/Delete | Phase | Description |
|---|---|---|---|
| `service/PutawayDestinationRules.java` | **Add** | **2-API** | §3.11.0.1 — the pure predicate evaluator (`evaluate(scope, Ctx, subjectId) -> Verdict`). No repositories, no Spring |
| `service/PutawayDestinationValidator.java` | Modify | **2-API** | §3.11.0.1 — becomes a facade over `PutawayDestinationRules`. **Behaviour-preserving: `PutawayDestinationValidatorUnitTest` must pass UNMODIFIED** |
| `controller/PutawayConfigController.java` | Modify | **2-API** | §3.11.0 `GET /eligibleLocations` (bulk — 5 queries, never per-row `validate()`); §3.11.0a `BlockingReason` +4 values and 3 corrected key mappings |
| `components/receiving/open/receive/receivingForm.vue` | Modify | 1a-UI | **NARROWED (r-next) — SBDEV-2731 PR1 already shipped the label binding, the tri-state and the override chip.** Re-source `putawayStaging` (`:228`, currently bound at `:336`) from `getPutawayDestination`; add the `sourceLabel` chip at `:19`; **render `divertedTo` / `divertedReason` / `warning`** (§3.11.1). Preserve `=== false` at `:24` |
| `store/receiving/*.js` | Modify | 1a-UI | fetch `getPutawayDestination` |
| `plugins/persistedState.client.js` | Modify | 1a-UI | `:22-25` exclusion list |
| `components/common/LocationPicker.vue` | **Add** | 1b-UI | props/events per **§3.11.5**; two tiers driven by the server's `tier` field; advanced tier carries the lock warning. Precedent is `createBol.vue:68-76` — **the old `:109-125` citation was wrong on all three counts** (§3.11 defect 4) |
| `components/admin/parametersAndConfiguration/editParamAndConfig.vue` | Modify | 1b-UI | `syskey` branch → tiered picker, writing `PUT /putawayConfig/warehouse` |
| `components/admin/parametersAndConfiguration/addParamAndConfig.vue` | Modify | 1b-UI | same |
| `store/admin/configuration.js` | Modify | 1b-UI | new action calling `PUT /putawayConfig/warehouse` + `GET /putawayConfig/preview`; the three existing sysprop write actions stay for other syskeys |
| `components/admin/shippers/editShipper.vue` | Modify | 1b-UI | three-state merchant default field, `PUT /putawayConfig/merchant/{clientId}` |
| `store/admin/shippers.js` | Modify | 1b-UI | read `defaultputawaylocationId` from `detailView`; new action for the typed write + `effectivePutawayDestination` |
| `test/.../receivingForm.spec.js`, `LocationPicker.spec.js`, `editShipper.spec.js` | **Add** | 1a-UI / 1b-UI | §7.1 — first tests in these areas |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| **0** | **External dependency — SBDEV-2731 PR1 merged to `develop`** (D12) | This plan assumes `receivingForm.vue` already binds `putawayStaging`, and that `UnitloadBusinessService:191` already throws the **neutral** `unitloadTypeNotPermittedOnLocation`. Both are 2731 PR1's deliverables, not this plan's. | 2731 | **New constraint: this plan can no longer merge independently.** If 2731 PR1 is abandoned or reworked, §3.6.1 and the display contract must be re-scoped back into this plan. |
| 1 | **Database state** | **Repair the Hydra DEV copy first** — it has no `flyway_schema_history`, so `StartupFlywayMigrator` **skips** it and `V2.2.13` would never apply: run `db/backfill-flyway-history.sh --up-to <its true watermark>` once against that DB. **Then confirm `V2.2.10` (SBDEV-2854) is already applied to THAT tenant — PR #132 merged 2026-08-07 (`68274b0`), so it is on `develop`, but **merged is not applied**; see §8.1 merge 0b. Applying `V2.2.13` to a tenant that has not yet received `V2.2.10` wedges that tenant against 2854 permanently** (`outOfOrder=false` skips the lower version, `validateOnMigrate=true` then fails every boot, and `StartupFlywayMigrator` swallows it). Then `V2.2.13` applied to **every** DEV tenant **BEFORE the Phase 1-API PR merges** (§8.1 — the single gated merge); then UAT before UAT deploy; then prod before prod deploy. Flyway head on `origin/develop` reads **`V2.2.09`** at start. | operator + author | **HARD BLOCKER on the Phase 1-API merge.** `V2.2.13` **does** add a column an entity maps (`client.defaultputawaylocation_id`), so the whole migration is gated — there is no gate-free half. DEV **auto-deploys on push**, and because `ddl-auto` is **`none`** the app **starts fine** and then throws `42703` on every `client` SELECT — silently, with green probes. On tenants that *do* have Flyway history the runtime migrator (SBDEV-2801) applies `V2.2.13` at boot and self-heals; the history-less DEV copy is the one that does not. Follow the `sbdocs/2-Areas/` Flyway tenant runbook with `--env dev`. See §8.1 and pre-mortem **P1**. |
| 2 | **Feature flags / system properties** | `DEFAULT_PUTAWAY_LOCATION` seeded by `V2.2.13` with `sysvalue = ''`. **No behaviour toggle.** | migration | D2 declined a sysprop gate; back-compat rests on "no config ⇒ no behaviour change", proven in §6. Blank = not configured (landmine A2). The seed is a convenience, not a dependency (§3.4a). |
| 3 | **Config / env changes** | None. No new property, no new cache, no Jasypt secret, no Keycloak client. | — | `CacheConfig` deliberately unchanged (§3.10) — the four caches already exist in both profiles. |
| 4 | **Deploy-order dependencies** | Each API phase merges and deploys **before** its UI phase. 1a-UI depends on `GET /receiving/getPutawayDestination`; 1b-UI depends on `PutawayConfigController`, `GET /client/{id}/effectivePutawayDestination` and `client.defaultputawaylocationId` in `/client/detailView`. No OMS dependency. | author | SBDEV-2731 and SBDEV-2643 must **not** be worked independently while this is open (D8, §8.1). |
| 5 | **Data migration** | **Scoped backfill inside `V2.2.13`, ordered after the `DROP NOT NULL` and after the pre-image INSERT** — see below. | migration | Without it the feature ships **inert** for all 2,720 existing SKUs (pre-mortem **P2**). |
| 6 | **External systems** | None. No OMS notification, no printer change, no Keycloak realm change. Receipt labels (`sharedService.createCaseLabel`) are unchanged. | — | |
| 7 | **Access / permissions** | `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigController`'s three write endpoints **and** on `PutawayConfigService`'s three writers plus `validateOnly` — **not** on the event-handler methods. No new Keycloak role, no new group. **✅ The constant is sound as of SBDEV-2863 `675b4a1` (merged 2026-08-07, PR #134): `Authority.java:44` renders `hasAuthority('sb_admin')`. Before that date it named a non-existent SpEL method and all six of these sites would have returned HTTP 500 to everyone, `sb_admin` included — see the warning box in §3.12. Keep `Authority.IS_SB_ADMIN`; do NOT swap it.** | author | §3.12. An annotation on a handler method may be inert (§3.9.4), which is why the service is the boundary. Frontend gating is convenience only; the framework is out of scope. |
| 8 | **Monitoring / alerts** | Three items: (a) a Grafana panel for `wms2.putaway.resolution` split by `source`; (b) an alert on `wms2.putaway.resolution.rejected > 0`; (c) **a deadlock detector** — alert on `40P01` / `DeadlockLoserDataAccessException` on `/receiving/receive`. | author + ops | §3.13. The tier-2/3 series staying at zero is pre-mortem **P2**'s only detector. (c) is the named detector for §7.6 row 8's lock-order inversion, and it **must be log/exception-based**: `/receiving/receive` returns 200-with-`errors`, never a 5xx, so an HTTP-status alert misses it entirely. |

#### The D5 backfill — scoped, reversible, and order-sensitive

**The backfill runs, and it is scoped — not blanket.** `location.name` has **no unique constraint**
(`V2.2.00__base_v2_schema.sql:959-979` — `name varchar(255) NOT NULL`, nothing more), so nothing in the
schema prevents two rows named `PutAwayLane`; every statement below is written so that an ambiguous or
absent lane fails **loudly and first** rather than half-applying.

```sql
-- ============ V2.2.13, STATEMENT 1: preflight guard — MUST be first, before any DDL ============
-- Tier 4 resolves the fallback by NAME with no client filter (LocationRepository.java:21-22,
-- Optional<Location>), so it throws IncorrectResultSizeDataAccessException at runtime if the name is
-- ambiguous. Fail the migration here, BEFORE the DROP NOT NULL, rather than leaving a half-applied
-- schema the app then fails 42703 against on every read (ddl-auto=none; pre-mortem P1).
DO $$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM public.location WHERE name = 'PutAwayLane';
    IF n <> 1 THEN
        RAISE EXCEPTION
          'SBDEV-2732: tier-4 fallback ambiguous or absent (% rows named PutAwayLane). '
          'Resolve before migrating: tier 4 uses findByName with no client filter.', n;
    END IF;
END $$;

-- ============ V2.2.13, STATEMENT 2: widen the column ============
ALTER TABLE public.itemdata ALTER COLUMN putawaylocation_id DROP NOT NULL;

-- ============ V2.2.13, STATEMENT 3: create putaway_config_audit + index ============
-- Placed ahead of the backfill so statement 4's pre-image has somewhere to land. Full DDL in §3.14 —
-- reference it, do not duplicate it here.

-- ============ V2.2.13, STATEMENT 4: pre-image — MUST run BEFORE the backfill ============
-- Records what the backfill is about to discard, so "we destroyed intent" becomes "we recorded it and can
-- replay it": the §7.3 rollback drill is then a single UPDATE ... FROM putaway_config_audit.
--
-- ORDER IS LOAD-BEARING. The pre-image reads exactly the rows the backfill is about to null. If the
-- UPDATE runs first, putawaylocation_id is already NULL, the join to location matches nothing, and this
-- INSERT silently records ZERO rows — a reversibility record that is empty while appearing to succeed.
--
-- Column list matches §3.14 exactly: subject_id (NOT entity_id), and the three NOT NULL columns
-- subject_label / tenant_name / facility_code are all supplied. `channel = 'migration'` is the third
-- legal value alongside typed|hal — any CHECK constraint must admit it.
INSERT INTO public.putaway_config_audit
       (tenant_name, facility_code, scope, subject_id, subject_label,
        previous_location_id, previous_location_name,
        new_location_id, new_location_name,
        channel, changed_by, changed_at)
SELECT current_database(),           -- one DB per facility, so this is provenance, not a discriminator
       'MIGRATION',                  -- facility_code is NOT NULL; no facility identity exists in-DB
       'SKU',
       i.id,
       COALESCE(i.item_nr, i.name, i.id::text),   -- subject_label is NOT NULL
       l.id,
       l.name,
       NULL,                         -- new_location_id: the override is being cleared
       NULL,
       'migration',
       'V2.2.13',
       now()
  FROM public.itemdata i
  JOIN public.location l ON l.id = i.putawaylocation_id
 WHERE l.name = 'PutAwayLane'
   AND NOT EXISTS (SELECT 1 FROM public.putaway_config_audit
                    WHERE channel = 'migration' AND scope = 'SKU');   -- idempotent on re-apply

-- ============ V2.2.13, STATEMENT 5: scoped backfill — AFTER the pre-image ============
-- IN (SELECT ...) not = (SELECT ...): IN cannot abort on 0 or N rows. And NO client_id filter, so the
-- set nulled is *definitionally* what tier 4 resolves — the two can never disagree.
UPDATE public.itemdata i
   SET putawaylocation_id = NULL
 WHERE i.putawaylocation_id IN (
        SELECT l.id FROM public.location l WHERE l.name = 'PutAwayLane');
```

**Verify the pre-image actually captured something** — a silently-empty reversibility record looks
identical to success:

```sql
-- run immediately after V2.2.13; both counts must be equal and non-zero on a tenant with SKUs
SELECT (SELECT count(*) FROM putaway_config_audit WHERE channel='migration' AND scope='SKU') AS captured,
       (SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL)                       AS nulled;
```

**Rollback drill** (§7.3 M19) is one statement, which is the whole point of the pre-image:

```sql
UPDATE public.itemdata i
   SET putawaylocation_id = a.previous_location_id
  FROM public.putaway_config_audit a
 WHERE a.channel = 'migration' AND a.scope = 'SKU' AND a.subject_id = i.id
   AND i.putawaylocation_id IS NULL;
```

**No `client_id` filter on the backfill predicate — deliberately.** Tier 4 resolves by name with no client
filter (`LocationRepository.java:21-22`), so any extra predicate here could diverge from it in both
directions: with a `client_id = 0` filter, a tenant whose lane had `client_id <> 0` would have nothing
nulled while tier 4 resolved fine (a silent pre-mortem-P2 on that tenant), and with two lanes the
migration would pick one while `findByName` threw at runtime. Matching tier 4 exactly, plus statement 1's
uniqueness guarantee, is what makes the two agree by construction. (On `wh01_hydra_v2` the lane does have
`client_id = 0`, so this removes a latent divergence, not a live one.)

**Statement order is load-bearing** — **one** migration, `V2.2.13`, in this order: preflight guard →
`DROP NOT NULL` → **create `putaway_config_audit`** → pre-image INSERT → backfill UPDATE → `client`
column + guarded FK → sysprop seed. §5.2 Phase 1 Step 3 restates it at the point of use.
*(Reworded 2026-08-06: this read as two migrations sharing one version number — residue of D16's
two-migrations→one collapse that a blanket version replace preserved.)*

**Idempotency.** `flyway migrate` never re-runs an applied version, so "migrate twice" is a vacuous gate —
use `psql -f` applied twice to a scratch DB instead. For that to be clean, the FK in `V2.2.13` needs a
guard, since Postgres has no `ADD CONSTRAINT IF NOT EXISTS`:

```sql
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_client_defaultputawaylocation') THEN
        ALTER TABLE public.client
          ADD CONSTRAINT fk_client_defaultputawaylocation
          FOREIGN KEY (defaultputawaylocation_id) REFERENCES public.location(id);
    END IF;
END $$;
```

The pre-image INSERT is also not naturally idempotent — a second apply would duplicate rows. Guard it with
`WHERE NOT EXISTS (SELECT 1 FROM putaway_config_audit WHERE channel = 'migration' AND scope = 'SKU')`.

**The argument for it.** Without *some* backfill, all 2,720 existing SKUs keep pointing at `PutAwayLane`, tier 1 wins every receipt, and tiers 2–3 are unreachable for every existing SKU — the feature ships inert (pre-mortem P2). A **blanket** `SET putawaylocation_id = NULL` would be wrong: it would discard genuine overrides, and genuine overrides demonstrably exist (the `Ice Pack` configuration on NYWH that produced the ticket's error).

**Is a genuine override distinguishable from a seeded default on existing data?** For rows equal to the lane id, no — and that is exactly why nulling *only those rows* is safe:

1. Every one of the four write paths seeds the lane id **unconditionally** (§0.1 rows 8–11); the SKU screen is read-only (`skuData.vue:100-123` create/edit commented out); so a row equal to the lane id is a seeded default with probability ≈ 1.
2. Rows **not** equal to the lane id are genuine overrides by construction — no code path ever writes a non-lane value except a deliberate human action. The predicate leaves every one of them untouched. `Ice Pack` survives.
3. The only semantic loss is a SKU *deliberately* pinned to `PutAwayLane`, which becomes "inherit". At the instant the migration runs this is **behaviour-preserving by construction**: `client.defaultputawaylocation_id` does not exist yet (it arrives in `V2.2.13`, created `NULL`) and no `DEFAULT_PUTAWAY_LOCATION` row exists or is non-blank, so no tier-2/3 value can exist, so "inherit" resolves through to tier 4 = `PutAwayLane` — the identical destination.
4. After the migration, "pinned to the lane" *is* expressible: select `PutAwayLane` explicitly in the SKU UI and the row gets a non-NULL tier-1 value that outranks tiers 2–3.

So the backfill is lossless on genuine overrides, behaviour-preserving at apply time, and it is the only thing that makes tiers 2–3 reachable. The DB evidence (100 % of rows equal the lane id on `wh01_hydra_v2`) is the *argument for* the scoped predicate, not a licence for a blanket one.

**Verification** (§7.3 SQL row): before → `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL` = 0; after → equals the pre-migration count of rows at the lane id; and `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NOT NULL` equals the pre-migration count of non-lane rows, **unchanged**.

### 5.2 Phased Implementation — TWO phases, plus one external prerequisite (D9 / D12)

**The ordering hazards O1–O5 are written into the steps, not merely referenced**, because a hazard in a
footnote gets read after it bites.

> ## ⚠ SCOPE CHANGE — D12 / D14 (2026-08-02). READ BEFORE THE TABLE BELOW.
>
> A plan for **SBDEV-2731** exists and is further along than this one:
> `sbdocs/1-Projects/wms2/plan/SBDEV-2731-alternate-putaway-location-not-honored-receiving.md`
> — 1,372 lines, `db_verified` against **four** environments including PRD, Architect-reviewed
> **SOUND WITH RESERVATIONS**, **PR1 ready**.
>
> **Q7 is CLOSED: it builds no competing resolver.** Zero occurrences of resolver / tier / precedence /
> merchant. This plan remains sole owner of the precedence contract.
>
> **But 2731 PR1 already delivers what this plan called Phase 1**, and better: the `receivingForm.vue`
> destination binding, the `UnitloadBusinessService:191` neutral message, four message keys across
> **both** properties files (this plan missed `messages.properties` entirely), and the matching tests.
>
> **D12 — Phase 1 is DELETED from this plan.** It is 2731 PR1's work. This plan becomes
> **Phase 1-API** + **Phase 2-UI**, and gains a hard prerequisite: *2731 PR1 merged to `develop`*.
> §3.6.1 no longer specifies `:191` — this plan only *consumes* the neutral key and throws
> `putawayDestinationNotPermitted` from the resolver.
>
> **D14 — this plan takes OWNERSHIP of `ReceivingService` destination resolution** (was 2731 PR2), so
> there is exactly one owner. **2731 closes on PR1.**
>
> **D14 IMPORT LIMIT — deliberate, and the reason this plan stays implementable.** 2731 PR2 is not
> merely "blocked"; it carries a **four-item gate that must be closed in writing before any coding**
> (2731 §7.2): **Q5** — *which determines whether its Fix B exists at all; under options (a) or (d) most
> PR2 steps are deleted rather than executed*; **C2b** — BLOCKING, the `Goodsreceiptposition` repointing
> is destructive as designed (`GoodsReceiptPositionService.delete:159-167`) and a test currently asserts
> the defective state as correct; **Q1**; **Q4**. Three further findings (F1 layering, F4 `Replenishorder`
> lock order, F5 Inbound-row lock re-scoping) must also close if Q5 keeps Fix B.
> **Therefore this plan imports the OWNERSHIP, not the gated work.** Flowbin classification and
> resident-UL resolution are recorded in §10 as **gated scope, explicitly outside Phase 1**, pending
> Q5/C2b/Q1/Q4. Importing them literally would re-block an otherwise-implementable plan on four external
> decisions. **Whoever answers Q5 must then decide where the surviving Fix B work lands — here, by
> construction, since 2731 will be closed.**
>
> **UPDATE 2026-08-04 — Q5 is answered (c), so the import limit partially collapses.** (c) is neither (a)
> nor (d), so by this block's own terms **Fix B exists and most of PR2's steps are executed, not deleted** —
> and "where the surviving work lands" is answered by construction: **here.** Consequences:
>
> - **Flowbin classification and resident-UL resolution move from *gated scope* into scope.** They can no
>   longer sit in §10 as "explicitly outside Phase 1"; direct placement into a pick face is exactly what
>   (c) authorises, and it is what those two pieces implement.
> - **F1 (layering), F4 (`Replenishorder` lock order) and F5 (Inbound-row lock re-scoping) must now close** —
>   this block already made them conditional on "if Q5 keeps Fix B", and Q5 kept it.
> - **C2b is now the binding gate, not Q5.** It is BLOCKING as written, unresolved by (c), and it carries a
>   consequence this plan's own §6 version missed: per SBDEV-2796, repointing
>   `Goodsreceiptposition.stockunitId`/`unitloadId` at the flowbin's resident rows makes
>   `GoodsReceiptPositionService.delete:159-167` `sendStockUnitToNirvana` **the entire flowbin balance** for
>   a one-case correction — and a test currently asserts the defective state as correct.
> - **Q1 and Q4 remain open** and still gate the Fix B import.
>
> So the gate went from four items to **three (C2b, Q1, Q4)** plus **three findings (F1, F4, F5)** that were
> previously conditional and became mandatory. **Net: (c) enlarged this plan.**
>
> **RESOLVED by D15 (2026-08-04): the enlargement is declined.** The tier-1 pick-face path is deferred to a
> follow-up ticket, so **Fix B is NOT imported after all** — flowbin classification and resident-UL
> resolution stay out of scope, and C2b, Q1, Q4, F1, F4 and F5 travel with them. The import limit this
> block argued for therefore **holds**, on a different basis than originally stated: not "Q5 is unanswered"
> but "the answer was taken and the resulting scope was deliberately deferred." The phase table below
> describes the correct scope again, with one change: ~~**direct placement is tiers 2/3 only**~~ → **⚠ RESTATED 2026-08-08 (Q12 → iv-b): direct placement is split on the DESTINATION, not the tier.** Any tier may resolve any destination; a **pick face** is never placed at receipt (step 15 diverts it to the lane), and everything else is. 
>
> **What neither plan fixed while F3 was open — now superseded.** The reported ICE PACK failure is 1,000
> units into a flowbin pick face via a **tier-1 (SKU-level)** override, and **D13 exempts tier 1**. PR1
> makes the error actionable and shows the true destination — real value — but **it is not "receiving
> works", and 2731 must not be closed in a way that implies the reported failure is fixed.** *(2026-08-04:
> F3 is now answered (c) — the receipt is permitted to succeed and over-fill the bin. The reported failure
> becomes fixable once the C2b/Q1/Q4 gate closes and Fix B lands here.)*

| Phase | Repo | Ships | Flyway? | Closes |
|---|---|---|---|---|
| *(external)* | — | **SBDEV-2731 PR1** — receiving-screen destination binding, `UnitloadBusinessService:191` neutral message, 4 keys in **both** properties files, tests. **Hard prerequisite for this plan.** | no | **SBDEV-2731** |
| **1-API** | `wms2-api` | Resolver (all 4 tiers) + `Resolution`/`Source` (frozen contract) · validator P1+P2 with D11 count-and-confirm and D13's non-pick-face restriction · `PutawayConfigService` (3 writers) · `PutawayConfigController` (preview + 3 writes) · HAL event-handler guard + the direct-`save()` guards (N1) · `PutawayDestinationQueryService` + display endpoint · resolver wired into `ReceivingService` (**D14: this plan owns that surface**) · audit table + writer · direct placement · **`V2.2.13`** (preflight → `DROP NOT NULL` → audit table → pre-image → backfill → `client` column + guarded FK → sysprop seed) + stop-seeding in the same commit | **YES** | — |
| **2-UI** | `wms2-web-ui` | Admin Operation Options field · merchant field (configured / inherited / cleared) · location picker restricted per D13 · config-health surfacing | no | **SBDEV-2732** |

#### Why the boundary is "is the tier REACHABLE?" — retained, because it still governs ONE rule

An earlier revision split this into 1a/1b on "does it need Flyway?". That was wrong, and the reasoning is
worth keeping even though the split is gone: **tier reachability is governed by the backfill.** While
`itemdata.putawaylocation_id` is `NOT NULL` and all four sites seed it, 2,720/2,720 rows point at
`PutAwayLane`, tier 1 wins 100 % of receipts, and tiers 2–4 are unreachable no matter what else ships.

> **O3 — THE ONE ORDERING RULE THAT SURVIVES.** `V2.2.13` and **stop-seeding must land in the SAME
> COMMIT**. Ship the code first and `POST /rest/sku` plus the CSV import fail with `23502`; ship the
> constraint change first and every new SKU silently re-acquires a tier-1 value, reintroducing the
> inertness the backfill just cleared, one row at a time.
>
> **O1** — the audit table ships in this phase, so AC15 is met here (no deferral).
> **O2** — the event handler covers `Itemdata`, `Client` **and** `Sysprop`; `Client` is no longer a
> later-phase problem because there is no later API phase.
> **O4** — gate on `PHASE=1` 0-fail, never whole-plan 0-fail.

#### Phase 1-API — `v2/wms2-api`, carries `V2.2.13`. Branch `feature/SBDEV-2732-putaway-destination-hierarchy`

**Prerequisite: SBDEV-2731 PR1 merged** (§5.1 row 0) — this phase assumes `receivingForm.vue` already
binds `putawayStaging` and that `:191` already throws the neutral `unitloadTypeNotPermittedOnLocation`.

| Step | Work | Gate |
|---|---|---|
| 1 | `git checkout develop && git pull`, then branch. **The tree is currently on `bugfix/SBDEV-2777-…` — do not build on it, and do not let the TDD gate write onto it.** | `git branch --show-current` |
| 2 | **TDD gate.** Write the failing §7.1 tests for the resolver, P1, the confirmation contract, the delta rule and the display endpoint. Confirm each fails *for the right reason*. **Pause for approval.** | red for the right reason |
| 3 | **`V2.2.13` AND stop-seeding, in ONE commit (O3).** Migration in the §5.1 order: preflight guard → `DROP NOT NULL` → create `putaway_config_audit` + index → pre-image INSERT → backfill UPDATE → `client.defaultputawaylocation_id` + guarded FK → `DEFAULT_PUTAWAY_LOCATION` seeded `''`. Stop seeding at all four sites; update the ≈10 fixtures deliberately. | `psql -f` twice on a scratch DB, second run clean; full `mvn test` |
| 4 | `WmsConstants` key; `PutawayDestinationResolver` + `Resolution` + the `Source` enum; the `getSystemClient()` null guard (§3.4a). **`Propagation.MANDATORY`; never `REQUIRES_NEW`.** Freeze the `Source`/`Resolution` contract here — the UI consumes it. | unit tests + `mvn clean compile` |
| 5 | `LocationConstraintService.isUnitloadTypePermitted` (P1). **Must replicate the empty-constraint-list fail-open at `UnitloadBusinessService.java:190`** or it rejects configurations that work today. | `emptyConstraintListPermitsEverything` |
| 6 | **Consume** the neutral key 2731 PR1 added at `:191`; throw `putawayDestinationNotPermitted` from the **resolver** only (§3.6.1). **Do not re-specify `:191` — that is 2731 PR1's line.** | resolver message test |
| 7 | `PutawayDestinationValidator` — P1 + P2 for **all three scopes**, including P2.7 (D13), the **locked** absolute (P2.1), P2.7's per-tier lane rules and D11's count-and-confirm. **⚠ REVISED 2026-08-08 (Q12 → iv-b): do NOT implement a fix-assigned or pick-face reject.** P2.5 and P2.7(c) are relaxed at all three scopes — the configuration is legal, and the placement is gated at run time by step 15. **But implement P2.7 rule (e):** reject a `flowbin`-type destination at **merchant and warehouse scope only** — putaway's FLA auto-creation would bind it to one SKU. Predicate is `location_type.sltname`, **not** the area flag; using `useforpicking` here re-bans the club lanes and undoes Q12. **The relaxation and that gate must land in the same change** (§3.4c). **⚠ ALSO implement P2.7 rule (f) (added 2026-08-09):** at **tier 1**, reject a flowbin whose `FixLocationAssignment` belongs to a *different* SKU, and reject a SKU whose own FLA sits on a different location — the tier-1 exemption from rule (e) is otherwise strictly weaker than the runtime rule it claims to mirror. **And apply the P1 skip with `sltname == 'flowbin'` ONLY** — the superseded `useforpicking OR flowbin` form relocates SBDEV-2731's error to putaway for overstock and club destinations (§3.4b). | unit tests — **must include `skuWritePermitsPickFaceDestination` and `merchantWritePermitsStagingLane`. The old `skuWriteRejectsFixAssignedLocation` / `skuWriteRejectsPickFaceDestination` / `merchantWriteRejectsFixAssignedLocation` are DELETED — they assert the superseded design and would fail a correct implementation** |
| 8 | `PutawayResolutionMetrics` (4 counters; the `compatible` tag). | unit tests |
| 9 | `PutawayConfigService`: `setSkuDestination`, `setMerchantDestination`, `setWarehouseDestination`, `readCommittedDestination` (**one query per scope**), `validateOnly`, `auditAndEvict`; authorization enforced **here**, not on the handler (N5). Rewire `ItemdataService.setPutAwayLocation` and `ItemDataController:80-95`. | unit tests |
| 10 | `PutawayConfigController` — `preview` + all three writes and the 409/422 confirmation contract (§3.5a). | `BaseControllerUnitTest` |
| 11 | **§3.9.1 direct-save guards:** `SystemPropertyController:77` and `:107` reject the guarded syskey; the delete-path decision implemented. | HAL + direct-save tests |
| 12 | `PutawayConfigRepositoryEventHandler` — `Itemdata`, `Client` **and** `Sysprop` (O2); separate create/save methods (§3.9.2); validate the **delta**, not the state; unchecked `PutawayConfigValidationException`. | HAL PATCH ⇒ **422** |
| 13 | `PutawayConfigAudit` entity + repository + `PutawayConfigAuditService` (`MANDATORY`). | `mvn clean compile` |
| 14 | `Client.defaultputawaylocationId` + accessors. **Same commit as `V2.2.13`** — otherwise every `client` read fails `42703` on any tenant the migration has not reached (`ddl-auto=none`, so it is a runtime failure, not a startup one). | context loads + a `client` read against a migrated tenant |
| 15 | Wire the resolver into `ReceivingService.java:451-459`. `requireCompatible` inside `if (carrier == null)` **above the loop** (§3.7.1); constants at `ReceivingController:314`. **Add the (iv-b) placement gate here:** if the resolved destination's area has `useforpicking = true` **OR its `location_type.sltname` is `flowbin`**, **do not place there** — fall back to the standard putaway lane (tier 4) and leave the destination for putaway. **The OR is deliberate, not belt-and-braces:** the reported failure is a location-*type* property (a flowbin's `location_constraint` permits only `PickLocation`), while `useforpicking` is an *area* property, and nothing in the schema ties them. Today every flowbin on both measured tenants happens to sit in a picking area — **that is data, not structure.** `sltname` is already read by P2.7 rule (e), so the second disjunct is free. Otherwise place as step 17 specifies. **This plan owns this surface (D14).** | `ReceivingServiceUnitTest` — **must include `pickFaceDestinationIsNotPlacedAtReceipt` and `stagingLaneDestinationIsPlacedAtReceipt`** |
| 16 | `PutawayDestinationQueryService` (`readOnly = true`) + `GET /receiving/getPutawayDestination/{advicePositionId}` + `GET /client/{id}/effectivePutawayDestination` — **the controller must not call the resolver** (C1). | controller tests |
| 17 | Direct placement + traceability (`UnitloadRecord` names the final destination) — **for NON-pick-face destinations only (Q12 → iv-b).** Pick-face destinations never reach this step; step 15's gate diverts them to the lane. **The gate in step 15 is what makes that true — it is no longer enforced by refusing the configuration, because (iv-b) permits pick-face configs at every scope.** **If you relax P2.5/P2.7(c) without step 15's gate in the same change, SBDEV-2731's reported failure returns.** | `ReceivingServiceUnitTest` |
| **17a** | **NEW 2026-08-08 (Q15 → (A)) — extend putaway's candidate surfacing to all four tiers.** SBDEV-2821 ships the repository method that adds a SKU's configured destination to the putaway candidate list, but reads **tier 1** (`itemdata.putawaylocation_id`) only. Step 15 diverts pick-face destinations at **every** tier, so merchant- and warehouse-scope defaults must be surfaced too: pass `Resolution.locationId()` from `PutawayDestinationResolver` into that method instead of the raw `itemdata` column. **Do not build a second surfacing path, and do not widen the `@RestResource`-exported `getStorageLocationsForPutAwayItemData`** (SBDEV-2821 §3.2). **This step is why `depends_on` now names SBDEV-2821** — if that ticket has not merged, this step has nothing to extend and step 15's gate strands the destination. | `MobilePutAwayService` unit test: a **merchant**-scope pick-face default appears in the candidate list for a SKU with **no stock anywhere** **⚠ AND THIS PLAN IS WHAT BREAKS THAT READ.** `V2.2.13` drops the `NOT NULL`, stops seeding, and runs `UPDATE itemdata SET putawaylocation_id = NULL WHERE … name = 'PutAwayLane'`, so the column's meaning changes from *"always populated, lane by default"* to *"NULL means no override"*. **SBDEV-2821 must handle `NULL` from day one, before `V2.2.13` exists** — today the column is `NOT NULL`, so a naive implementation will not crash and will look correct, then break **later** when this migration lands. Recorded as a hard requirement in SBDEV-2821 §0. **Step 17a must REPLACE that raw read with the four-tier `Resolution`, not add a second reader.** |
| 18 | `PutawayResolverContextLoadTest` (`@Disabled TODO(SBDEV-2217)`); `mvn clean compile`; full `mvn test`; **revert the mutated `archunit_store`**. | **`PHASE=1` verify run: 0 fail** |

#### Phase 2 — `v2/wms2-web-ui` **+ step 18a in `wms2-api`**. Closes SBDEV-2732

| Step | Work |
|---|---|
| **18a-A** | ✅ **MERGED 2026-08-11 — PR #142, merge `41c8257`. Was: DO THIS FIRST — it unblocks 19–22 and SBDEV-2643 B2 with ZERO changes to live validation code.** `GET /putawayConfig/eligibleLocations`, **PAGINATED**, per-row `validate()`, behind `PutawayDestinationQueryService` (§3.11.0.1). Returns ineligible rows with reasons; orders by `useforgoodsin DESC, name`. **Resequenced 2026-08-11** — the previous form made step C a prerequisite; pagination dissolves that. |
| **18a-4** | ✅ **MERGED 2026-08-11 (merge `913f017`)** — `BlockingReason` +4 values, all 7 rejection keys mapped (§3.11.0a). wms2-api PR #141 (`5e4aacc` + `4699dbb`) — ON DEVELOP. |
| **18a-B** | ✅ **MERGED 2026-08-11 (merge `a8129c7`) — wms2-api PR #143 (`29fa719`) — ON DEVELOP.** `PutawayDestinationValidatorUnitTest` written against the MERGED validator: 50 tests, all 8 throw keys, the six previously-uncovered branches, multi-failure precedence, and `getMessage()` as well as `getKey()`. **Not a TDD gate** — it characterizes merged behaviour, so it is green on the first run; the skill's rule 2 forbids that shape, so it was not used. **14 mutations applied to the validator, all 14 caught**, validator left byte-identical to `889298d`. 5 new `P2B-*` verify rows, negative-tested against a tree without the guard. **Step C is now unblocked.** |
| **18a-C** | ✅ **MERGED 2026-08-11 — wms2-api PR #145 (`e9a8e7b`), merge `5a6d517`.** `PutawayDestinationRules` extracted as a zero-dependency `@Service`, validator now a loading+throwing facade. **Step B's 50 assertions pass UNTOUCHED** — one line of fixture wiring, supplying the collaborator as a real `@Spy` not a `@Mock` (a mock would have made all 50 characterize a stub). All five review conditions met: `defaultUnitloadTypeId` a 4th `evaluate` param, P2.1 in the facade, ordered `List<Rule>` returning the FIRST objection, `Verdict.args` a `List`, purity pinned by ArchUnit (which asserts existence first, since a rule over a missing class passes vacuously). ⚠ **MUTATION TESTING FOUND A REAL GAP A GREEN SUITE HID:** two mutations survived — the P2.6 flowbin skip and rule (f)'s `isFlowbin` gate — because the extraction put each behaviour behind TWO guards and a facade-built `Ctx` cannot reach the rules-level copy. Behaviour preserved; the new SEAM was untested. Closed by `PutawayDestinationRulesUnitTest` (13 tests, no mocks — the payoff of extracting); both now caught. Also removed dead code the refactor left behind (an orphaned `rejectIfTrue`, 0 callers), caught by the redesigned derivation's new facade-purity assertion. 8 new `P2C-*` rows, negative-tested. ⚠ **AND THE VERIFY RESULT WAS REPORTED WRONG:** the commit message, PR body and ClickUp comment all said `PHASE=1 220 pass / 0 fail`. The run actually read **220 pass / 6 fail** — six `V-*` rows had gone red because they grepped `$VALIDATOR` for predicates this step moved into `$RULES`. The rows were stale, the code was correct, and the six were misattributed to the `U-*` UI rows *which `PHASE=1` filters out*. Rows repointed and all negative-tested 2026-08-11; merged develop now reads **`PHASE=1` 226 pass / 0 fail**. |
| **18a-D** | ✅ **MERGED 2026-08-11 — wms2-api PR #144 (`a10bc08`), merge `27845cd`.** ⚠ **AND IT DID NOT NEED STEP C.** §3.11.0.3 specified fixing this by building a `Ctx` and calling the extracted `evaluate`, which made D depend on C — a refactor of merged validation code. The same collapse comes from memoizing the EXISTING validator's verdict per distinct `defultypeId`: at tiers 2/3 the only per-SKU input is `defultypeId` (rule (f) runs solely inside `if (scope == SKU)`, one site at `PutawayDestinationValidator:133`), so grouping is **equivalent, not approximate** — and that assumption is pinned by step B's merged `ruleFDoesNotRunAtMerchantScope`. **Measured: 8,804 SKUs, 1 distinct `defultype_id` → 8,804 evaluations collapse to 1.** SKU scope deliberately not grouped. 4 new `P2D-*` rows, negative-tested. |
| 19 | ✅ **DONE 2026-08-11 — wms2-web-ui PR #42 (`91d500e`), MERGED, merge `9edb743`.** 17 tests, 12/12 mutations caught, 11 verify rows each negative-tested. Ships **inert** — no page references it yet; steps 20/21 are its callers. ⚠ **One design point was found by a test, not by the plan: the CURRENTLY-SELECTED row must bypass the tier gate.** A pure `tier` filter drops an already-saved `ADVANCED` destination out of `items`, so `v-autocomplete` renders an EMPTY field and tells the operator nothing is configured when something is. `eligible` stays absolute, so an invalid saved destination is still not re-offered (that is step 22's job). Also decided beyond the plan's letter: an **unrecognised tier fails CLOSED** (promoting it would show a storage location without the lock warning), and the picker **drops ineligible rows itself** rather than trusting the caller. ⚠ **Its two pre-existing verify rows were hollow** — `U-picker` was `file_exists`, `U-negq` a bare `file_not_contains`; `touch LocationPicker.vue` turned both green. Both strengthened, 9 `U19-*` rows added. Was: `LocationPicker.vue` — props/events per **§3.11.5**; `items` supplied by the caller from **`/putawayConfig/eligibleLocations`**; two tiers driven by the server's `tier` field; advanced tier carries the lock warning. **NEVER `/location/detailView`** — it carries none of the predicate columns (§3.11 defect 1) — and **never** `getStorageLocationsForPutAwayItemData`. ⚠ *r-next deletes "offer only P2.7-eligible areas (D13)": since (iv-b) D13 is a **placement** rule, and the eligible set is scope-dependent (§3.11.5a).* |
| **19a** | ✅ **BUILT 2026-08-11 — wms2-web-ui PR #47 (`eed9e2a`) MERGED (merge `83c6e97`); copy in wms2-api PR #147 (`6cc86d5`) MERGED (merge `509be61`), merged FIRST as required.** Copy is **variant A, chosen by Nam**, and now lives in `messages.properties` (key `putawayDestinationDivertedToLane`) rather than hardcoded at `ReceivingController:118` — so a product revision is a properties edit, not a Java change. 15 tests + SBDEV-2731's 10 preserved, 9/9 mutations caught, **verify PHASE=all 285 pass / 0 fail — the whole script green for the first time.** ⚠ Mutation testing found a gap two of my own tests could not reach: deleting the per-position reset SURVIVED, because the normal path's assignments clear the fields anyway — it only matters on the early-return paths (rejected request, empty envelope), which is the worse case. D14/D15 drive that. Was: ⏸ blocked on PRODUCT SIGN-OFF for the copy, not on code. The API half is already merged and verified:** `ReceivingController` supplies `sourceLabel` (:106), `divertedTo` (:117), `divertedReason` (:118) and `warning` (:123), so nothing server-side remains. Its acceptance row **`U-diverted` was named in §11.1a and existed nowhere in the verify script until 2026-08-11** — the eighth such gap, and it covered item 3, the entire reason §3.11.1 still exists. Now added and validated the only way a row for unbuilt work can be: it goes GREEN against a correct implementation and stays RED for five near-misses (either field alone, both smuggled onto the same line as `putawayStaging`, both only inside an HTML comment, and `putawayStaging` renamed away). **NEW (r-next) — the receiving form had no step.** Re-source `putawayStaging` from `GET /receiving/getPutawayDestination/{advicePositionId}`, add the `sourceLabel` chip, and **render `divertedTo` / `divertedReason` / `warning`** (§3.11.1). Preserve the tri-state: template tests `=== false` (`receivingForm.vue:24`), `isPutawayOverride` ANDs on `=== true`. **Diversion copy needs product sign-off before merge.** |
| 20 | ✅ **DONE 2026-08-11 — wms2-web-ui PR #43 (`cf2ced2`), MERGED, merge `ec01dd7`. Was stacked on #42.** 33 tests, 16/16 mutations caught, 10 verify rows negative-tested. New `defaultPutawayLocationField.vue` owns the preview gate, D11's confirm and the typed write — **one wrapper, not three copies**, since §3.11.2 needs it in the edit dialog, the add dialog AND the unconditional control, and step 21 needs it again at MERCHANT scope. New store actions `setWarehousePutawayDestination` / `previewPutawayConfig` / `getEligiblePutawayLocations`; the paginated read is **accumulated** and `totalCount` comes from `totalElements`. A cleared value **omits** `locationId` rather than sending `locationId=null` (it is `required=false Long`, so the literal would 400). The syskey literal now lives only in `util/putawayConfig.js`. Was: `editParamAndConfig.vue` / `addParamAndConfig.vue` `syskey` branch → `PUT /putawayConfig/warehouse` (**not** `PUT /sysprop/{id}`, **not** `POST /systemProperty/create` — N1). |
| 21 | ✅ **DONE 2026-08-11 — wms2-web-ui PR #44 (`f5f3e44`), MERGED, merge `536ac2b`. Was stacked on #43.** 22 tests (the commit message understated this as 20), 15/15 mutations caught, 5 verify rows negative-tested. ⚠ **THIS ROW'S READ SOURCE IS WRONG AND WAS NOT FOLLOWED** — see §3.11.3's correction: `/client/detailView` does NOT carry `defaultputawaylocationId`. Implemented against `GET /client/{id}/effectivePutawayDestination`. `inherited` bound not re-derived; the picker binds the shipper's OWN id (null when inherited); the field is **destructured out** of editShipper's PATCH payload (not `delete`d, which would mutate the live form object). The step-20 wrapper now picks its write action by scope. Was: `editShipper.vue` three-state merchant field (configured / inherited / cleared) → `PUT /putawayConfig/merchant/{clientId}`, inherited value from `effectivePutawayDestination`, `incompatibleSkuCount` driving D11's confirm dialog. ⚠ **r-next: `inherited` is ALREADY a boolean in the envelope (`ClientController.java:78`) — bind it, do not re-derive. And the field must be EXCLUDED from `store/admin/shippers.js:47`'s `$patch('/client/{id}')` payload**, or it rides the HAL path and defeats the typed write surface (§3.11.3). |
| 22 | ✅ **DONE 2026-08-11 — wms2-web-ui PR #45 (`0e88b1c`), MERGED, merge `bb6fd22`. Was stacked on #44.** 18 tests, 15/15 mutations caught, 5 verify rows negative-tested. The config-health gap was **created by step 19, correctly**: it refuses to offer an ineligible row even when it is the saved value, so an invalid config rendered as an EMPTY field — indistinguishable from unset, though the two behave differently at receipt time (unset falls through; invalid-but-set is still stored and gets diverted silently). The warning names the location, translates `blockingReason`, and says receipts are going to the standard lane meanwhile. Save stays ENABLED so it can be fixed. ⚠ **The persistedState reducer was a single TOP-LEVEL destructure and could not express the nested exclusion** — reshaped, rebuilding `admin.configuration` rather than deleting from it (the reducer runs against LIVE state, so a delete would empty the operator's table). |
---

## 6. Backward Compatibility

> ### ⚠ N-22 — DIRECT PLACEMENT BREAKS GOODS-RECEIPT CORRECTION (verified in code)
>
> `GoodsReceiptPositionService.java:151-152` guards receipt correction with an area check immediately
> before `deletePosition`:
> ```java
> if (!area.getUseforgoodsin()) {
>     throw new BusinessException("UnitLoad not in area for goods in anymore. found location=" + location);
> }
> ```
> It is reached from **both** `delete` (`:98`) and `adjust` (`:124`). **Today it can never fire**, because
> receiving's destination is always the inbound `PutAwayLane`, whose area is goods-in — structurally the
> same "harmless only because the destination is always the lane" assumption as H1.
>
> **After D2 direct placement into a tier-1 destination** (D13 exempts tier 1, so any storage or pick
> location) the position's unit load is no longer in a goods-in area, so **`delete` and `adjust` on that
> goods-receipt position throw.** Receipt correction becomes impossible for exactly the receipts this
> feature redirects, and it fails silently until an operator tries to fix a mis-receipt.
>
> The guard is also load-bearing in a second way: `deletePosition` proceeds to
> `sendStockUnitToNirvana(…, STOCK_REMOVED, …)` (`:165`) and, when no stock units or children remain,
> `sendToNirvana(unitLoad)` (`:171`). So it is the only thing standing between a correction and
> nirvana-ing a unit load that now sits on a live storage face.
>
> **This is C2b's lesson applied to this plan:** `Goodsreceiptposition.unitloadId` / `.stockunitId` are
> read by a consumer that **no changed symbol mentions**, which is why four review passes over §0 never
> surfaced it. If N-21's rule (d) lets tiers 2/3 target staging lanes whose areas are not goods-in, this
> breaks for those tiers too — not only tier 1.
>
> **Required before implementation:** add `GoodsReceiptPositionService` and
> `GoodsReceiptPositionController` to §0; decide explicitly whether the guard is relaxed for
> directly-placed receipts or whether correction is documented as unavailable for them; add a §7.3 manual
> row (receive to a non-lane destination, then `delete` and `adjust` that position). Note the guard throws
> a raw-concatenated `BusinessException` — the same family as `:191`, and newly reachable.
>
> **2026-08-04 — this is no longer conditional, and it is worse than described.** SBDEV-2796 answered (c):
> tier-1 direct placement into a pick face is authorised, so the "after D2 direct placement" premise above
> is now **certain**, not hypothetical. Two additions:
>
> - **The failure mode above is the *benign* one.** It assumes the position still points at its own newly
>   created rows, so the guard merely throws. But 2731's **C2b** — now live, see §5.2 — repoints
>   `Goodsreceiptposition.stockunitId`/`unitloadId` at the flowbin's **resident** pick-face rows. If the guard
>   is then *relaxed* (one of the two options this block asks us to choose between), `delete` proceeds to
>   `sendStockUnitToNirvana` (`:165`) and `sendToNirvana(unitLoad)` (`:171`) against **the whole flowbin
>   balance** — nirvana-ing every unit in the bin to correct one case. **So "relax the guard" is only safe if
>   C2b is fixed first.** The two decisions are coupled and must be taken together, not in either order.
> - A test currently **asserts the defective repointing as correct** (2731 review, C2b), so it will have to be
>   changed, not merely extended — and changing a passing test to make room for a fix needs an explicit
>   reviewer note or it looks like the fix broke it.
>
> ### ⚠ N-23 — A TIER-2/3 STAGING-LANE DESTINATION HANDS RECEIVED STOCK TO THE CLUB BATCH SUBSYSTEM (verified in code, 2026-08-04)

> D13 rule (a) *permits* `staginglane` and `crossdockinglane` for tiers 2/3, and the ticket's own named
> tier-2 scenario is **"Club assembly lane"**. Nothing in §0 or §3 asked what else owns those lanes. Two
> consequences, both verified against `origin/develop`:
>
> **1. Club lanes are allocated without any regard for resident stock — this can ship or nirvana a receipt.**
> `LocationRepository.getAvailableStagingLanes` (`:37-47`) is:
> ```
> WHERE l.staginglane = true
>   AND NOT EXISTS (SELECT ob FROM CustomerorderBatch ob
>                   WHERE ob.staginglaneId = l.id AND ob.id != :batchId AND ob.state < :state)
> ```
> **There is no stock or unit-load predicate at all.** A lane holding received inventory is "available".
> Path: `ClubLineController:307` → `CustomerorderBatchService:895` → `:911` assigns it; `BillofladingService:732/:829`
> and `CustomerorderBatchService:382/:402/:713` clear it; truck loading ships what sits on the lane.
>
> Scenario: merchant default = the club assembly lane → a receipt lands there → a club batch is later assigned
> to the same lane → **the received stock is shipped with the batch or cleared off the lane.** Blast radius is
> inventory loss, and D17 has already documented receipt correction as unavailable for exactly these receipts,
> so there is no clean unwind. Note the query is **`@RestResource`-exported**, so the frontend can call it
> directly — a service-layer guard would not cover it (same class of trap as SBDEV-1666).
>
> **2. Stock on a staging or transfer lane is structurally invisible to replenishment sourcing.**
> `StockunitRepository:198` and `:216` carry `AND loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE`
> **unconditionally — no sysprop gate** (the SBDEV-1666 display corrections). So a tier-2/3 lane destination
> creates inventory replenishment can never source. That is probably *correct* for cross-dock and fast-turn —
> the stock is meant to leave, not to feed pick faces — and probably *wrong* for anything else. The plan never
> asked, so it is recorded here rather than assumed either way.
>
> **Required before implementation:** answer §10.4 **Q12** (below). If club lanes are excluded, P2.7 rule (a)
> must name `crossdockinglane` plus *non-club* staging lanes rather than `staginglane` wholesale — and
> "non-club" needs a definition, because `Location` has no such flag; the only available signal is whether the
> lane is ever referenced by a `CustomerorderBatch`, which is historical, not declarative. If club lanes are
> allowed, this plan owes a §7.3 manual row (receive onto a staging lane, then assemble a club batch on it) and
> an explicit operator warning.

> **DECIDED — D17 (2026-08-04): keep the guard.** Receipt correction is **documented as unavailable for
> directly-placed receipts**; the guard is not relaxed. Relaxing it is only safe once C2b is fixed, and C2b
> is deferred with the tier-1 path (D15), so keeping the guard is the only option that cannot nirvana a
> location. **This decision is required even under D15**, because D13 rule (d) lets tiers 2/3 target
> staging lanes whose areas are not `useforgoodsin` — so a tier-2/3 direct placement reaches the same
> guard. Implementation obligations that remain: add `GoodsReceiptPositionService` /
> `GoodsReceiptPositionController` to §0, add the §7.3 manual row (receive to a non-lane destination, then
> `delete` and `adjust`), and make the thrown message actionable — it is a raw-concatenated
> `BusinessException` today, the same family as `:191`, and newly reachable.


| Change | Compatible? | Why / mitigation |
|---|---|---|
| `itemdata.putawaylocation_id` DROP NOT NULL | **Yes, with a hard deploy order** | Widening a constraint never breaks existing rows. But the *code* change (stop seeding) requires the DDL first: on an un-migrated DB, `POST /rest/sku` and the CSV import fail with `23502 null value in column "putawaylocation_id"`. They travel in one commit (O3) and `V2.2.13` must be applied promptly after the Phase 1-API merge. |
| Scoped NULL backfill | **Yes — behaviour-preserving at apply time** | Only rows equal to the `PutAwayLane` id are nulled; no tier-2/3 value can exist yet, so they resolve through to tier 4 = the same location. Non-lane overrides untouched. §5.1. |
| `@NotNull` removed from `Itemdata` | **Yes** | Removing bean validation only widens what is accepted. HAL and typed writes now agree. |
| `client.defaultputawaylocation_id` added (`V2.2.13`) | **Yes, with a hard deploy order** | Nullable additive column; every existing row reads `NULL` = inherit. `ddl-auto` is `none`, so the entity field without the column does **not** prevent startup — it fails `42703` per request instead, which is harder to notice. This is what gates the merge. §5.1 row 1, §8.1. |
| `putaway_config_audit` and `client.defaultputawaylocation_id` both created in `V2.2.13` | **Yes** | One migration (D16), one gated merge — **there is no gate-free half any more**. A table no entity maps is harmless in either direction; the *column* is what gates. |
| `DEFAULT_PUTAWAY_LOCATION` seeded `''` | **Yes** | Blank = not configured ⇒ tier 3 never wins until someone sets it. An absent row behaves identically, so a tenant that has not yet had `V2.2.13` applied is also unaffected. |
| `SystemPropertyController` rejects one syskey; `DELETE` on it is audited (D12) | **Yes** | Every other syskey behaves exactly as today. The delete still succeeds and still removes the row; it merely writes an audit row as well, and the Operation Options control stays available so the tier can be re-set. §3.9.1, §3.11.2. |
| Resolver at the receiving call-sites | **Yes** | With no tier-2/3 config and post-backfill NULL tier-1, `resolve` returns `STANDARD_PUTAWAY_LANE` — the same `Location` the old ternary produced for 100 % of `wh01_hydra_v2`'s SKUs. |
| P1 hoisted before the loop | **Yes, strictly better** | Same predicate, same fail-open branch, evaluated earlier. A receipt that succeeded before still succeeds; one that failed still fails, now before any unit load exists and with a message naming the remedy. |
| `UnitloadBusinessService.java:235` message replaced with the **neutral** key | **Behaviour yes, text no** | Any consumer string-matching `"not allowed on location"` breaks. Known consumers: `UnitloadBusinessServiceUnitTest:193, 208` (updated). Grep found no production string-match. The 21 non-receiving call sites get a message with no putaway remedy clause, which is the point (§3.6.1). |
| `ItemDataController` `allEntries=true` → 2-key evict | **Yes, strictly better** | Narrower eviction. Worst case a stale entry survives up to 5 min in a cache that was previously being flushed wholesale for every tenant. |
| `ReceivingController:314` literals → constants | **Yes** | Same three values, resolved from the constants they should always have used. |
| New endpoint + new table + new counters | **Yes** | Purely additive. |
| Direct placement to a non-lane destination | **Yes, but visible** | Not a new mechanism (§2.1). Consequence: scanning a directly-placed unit load in mobile putaway throws the pre-existing **`unitloadNotInInboundArea`** from `MobilePutAwayService.java:113-117` — **not** `unitLoadNotInPutAwayLane`, which is at `:121-128` and is never reached for a unit load sitting in a storage or pick area. Pre-existing guard, newly reachable. Correction path is mobile "Move Unit Load" (`MobileMoveUnitloadService`) or the web Transfer Stock screen. Manual rows **M13**/**M13a** + operator note. §3.7.4. |

### What Does NOT Change

- `transferUnitLoadToLocation` / `transferUnitLoadToCarrier` **signatures and internals**, apart from `:180-193`'s delegation and `:191`'s message. **None of the other 21 call sites** (picking, palletizing, truck loading, transfer orders, on-hold, nirvana, empty-pool) is touched, and the resolver is never called from inside them.
- `receiving_dto_view` and `ReceivingDtoView` — **no DDL, no entity change** (§3.8).
- `ReceivedDtoView` and `/reports/receiving-report`.
- `receiveGoods`' transaction shape: still one `@Transactional(value="tenantTransactionManager", …)` at `:302`; resolution still hoisted above the loop; a bad destination still rolls the whole receipt back.
- `config/CacheConfig.java` — no new cache, so no change in either profile.
- Label printing (`sharedService.createCaseLabel`), the `WAREHOUSE_NAME` read at `:429-431`, `INBOUND_UPDATE_STOCK_IMMEDIATELY` (`:518`), and the over-delivery pessimistic lock at `:344-345`.
- `MobilePutAwayService` — no code change at all, including both guards at `:113-117` and `:121-128`, `calculatePutAwayList` (`:217-305`), and `storePalletBackOnPutawayLane` (`:190-206`) with its SBDEV-2102 "pallet must be on the current user's location" guard.
- `FileImportController.java:355-359`'s SBDEV-2037 lane-presence guard (kept, repurposed).
- Any OMS notification, outbox message, printer configuration, or Keycloak artefact.
- Mobile UI (`wms2-mobile-ui`) — not in D4's phasing.

---

## 7. Testing Strategy

**Known lane constraints — do not rediscover:**

- v2 Testcontainers ITs **cannot boot** (SBDEV-2217). Gate on unit + H2 tests and `mvn clean compile`; leave ITs `@Disabled` with `TODO(SBDEV-2217)`.
- **2 of 4442 tests already fail on clean `develop`** (`OptionalSafetyArchTest` ArchUnit drift, `MobilePalletizingServiceTest`). Do not attribute them to this change; do not "fix" them here.
- `mvn test` **MUTATES the tracked `archunit_store`** — `git checkout` it before committing.
- `-Dtest='Outer#method'` **silently no-ops for `@Nested` tests** (false green). Most of these suites use `@Nested` ⇒ run whole classes.
- A new `@Service` bean needs `mvn clean compile` **plus a context-load test** — unit tests and incremental compile both miss DI wiring drift.
- **`V2.2.13` is invisible to the IT harness** (it scans `db/v1-to-v2-onboarding/schema`, not `db/migration/`) ⇒ no automated test can prove the DDL. It is proven by the §7.3 SQL rows and the scratch-DB double-apply only.
- `mvn`/`java` need the SDKMAN PATH export.

### 7.1 Unit lane

| Test class | Test | Asserts |
|---|---|---|
| `PutawayDestinationResolverUnitTest` (**new**) | `tier1WinsWhenSkuConfigured` | non-null `putawaylocationId` ⇒ `SKU_OVERRIDE`, and neither `client` nor sysprop is read |
| | `tier2WinsWhenSkuNull` | tier 1 NULL, `client.defaultputawaylocationId` set ⇒ `MERCHANT_OVERRIDE` |
| | `tier3WinsWhenSkuAndMerchantNull` | ⇒ `WAREHOUSE_DEFAULT` from the sysprop id |
| | `tier4WhenNothingConfigured` | ⇒ `STANDARD_PUTAWAY_LANE` by name |
| | **`blankSysvalueFallsThrough`** | `''`, `'   '` ⇒ tier 4, **not** a parse failure (landmine A2) |
| | **`nullItemdataSkipsTierOne`** | `resolve(null, client, typeId)` returns non-null; `itemdataRepository` never touched (§3.1.4 / `AdviceRestController:684`) |
| | **`neverCallsGetStringDefault`** | `verify(syspropService, never()).getStringDefault(any(), any(), any(), any())` — landmine A1 as an executable assertion |
| | **`neverCallsGetSysvalue`** | landmines A3 + A4 as an executable assertion |
| | **`workstationScopedRowIsIgnored`** | a `DEFAULT_PUTAWAY_LOCATION` row on a non-`DEFAULT` workstation is not read (landmine A6) |
| | **`missingSystemClientRaisesBusinessException`** | `getSystemClient()` returning `null` ⇒ `BusinessException`, never an NPE (§3.4a) |
| | `configuredTierWithDanglingIdHardFails` | configured id with no `location` row ⇒ `BusinessException` naming the tier, **not** a fall-through (D6) |
| | `resolveNeverThrowsOnIncompatibility` | P1 false ⇒ `Resolution.compatible() == false`, and `resolve` returns normally (§3.1) |
| | `requireCompatibleThrowsPutawayKey` | `requireCompatible` on an incompatible `Resolution` ⇒ `putawayDestinationNotPermitted`, naming tier, destination, reason, remedy |
| | `requireCompatibleAlsoThrowsForTier4` | the lane itself incompatible ⇒ same exception (parity with today) |
| `LocationConstraintServiceUnitTest` | **`emptyConstraintListPermitsEverything`** | the fail-open branch — the single most dangerous thing to get wrong (D6) |
| | `matrixAllowDeny` | flowbin→PickLocation only; cases-and-pallets→Case+Pallet; `NoRestriction`→everything |
| `PutawayConfigServiceUnitTest` (**new**) | `skuWriteValidatesAndAudits` | P2 runs; one audit row with previous+new; both `itemdata` keys evicted |
| | `skuWriteRejectsIncompatibleDestination` | SKU scope is an absolute reject (§3.4c) |
| | `merchantWriteRequiresConfirmationWhenSomeSkusIncompatible` | count > 0 with no `confirmIncompatibleSkus` ⇒ reject; message names the count + one example SKU |
| | `merchantWriteRejectsOnlyAtTotalIncompatibility` | count == total ⇒ reject unconditionally, no confirmation accepted |
| | ~~`merchantWriteRejectsFixAssignedLocation`~~ | ⚠ **DELETED 2026-08-08 (Q12 → iv-b).** P2.5's write-time reject is dropped at all three scopes. Its verify check `T-merchfix` was removed from the script the same day. |
| | **`merchantWriteRejectsFlowbinDestination`** | **ADDED 2026-08-08 — P2.7 rule (e).** Merchant scope rejects a `flowbin`-type destination; putaway's FLA auto-creation would bind it to the first SKU and break every other SKU under that merchant. Verify: `V-noflowbin23` |
| | **`skuWritePermitsFlowbinDestination`** | **ADDED 2026-08-08** — tier 1 is exempt from rule (e); a SKU binding its own pick face is the intent. **Both tests are needed**: the reject alone would pass an implementation that bans flowbins everywhere. Verify: `V-flowbin1ok` |
| | **`merchantWritePermitsCasesAndPalletsDestination`** | **ADDED 2026-08-08** — guards the club use case. Rule (e) keys on `sltname == 'flowbin'`, so `cases and pallets` must still pass at merchant scope. This test fails if someone implements rule (e) with `useforpicking`. |
| | ~~`skuWriteRejectsFixAssignedLocation`~~ | ⚠ **DELETED 2026-08-08 (Q12 → iv-b).** It asserted the D15 enforcement point (P2.5, absolute at SKU scope), which no longer exists — under (iv-b) the config is legal and the *placement* is refused. Its verify checks `T-skufix` / `V-fixloc` were removed. **This test would fail a correct implementation.** |
| | ~~`skuWriteRejectsPickFaceDestination`~~ → **`pickFaceDestinationIsNotPlacedAtReceipt`** | ⚠ **REPLACED 2026-08-08 (Q12 → iv-b), and it moves out of `PutawayConfigServiceUnitTest` into `ReceivingServiceUnitTest`** (step 15). A pick face is now a **legal configuration at every scope**; what is refused is placing a receipt there. Pair it with `stagingLaneDestinationIsPlacedAtReceipt` — together they pin both halves of the split. Verify check `V-fixabs` removed. |
| | `skuWritePermitsPickFaceDestination` (**new**) | The positive half of the relaxation: an FLA-free pick face is **accepted** at SKU scope. **Fixture must be an FLA-free pick face** (the real shape: wineco's club locations — `useforpicking` true, zero FLA rows). Without this, nothing pins that the reject was actually dropped. |
| | `merchantWritePermitsStagingLane` | P2.7(a): `staginglane` / `crossdockinglane` are **permitted** at merchant/warehouse scope — guards against re-introducing the "a lane can never work" over-reject. Verify: `T-stagingok` |
| | **`skuWriteRejectsFlowbinAssignedToAnotherSku`** | **ADDED 2026-08-09 — P2.7 rule (f).** Tier 1 naming a flowbin whose FLA belongs to a different SKU ⇒ **422**. Without this the config saves and then fails at *every* putaway (`scannedLocationHasDifferentFixedAssignment`), with nothing naming the cause. **1,344 of 2,068 flowbins on `wms2-wineco-dev` are already FLA-bound**, so this is the common case, not the edge. |
| | **`skuWriteRejectsWhenSkuAlreadyOwnsADifferentPickFace`** | **ADDED 2026-08-09 — rule (f), other direction.** Mirrors `verifyScannedLocation:437-445` / `StockunitService:186-190`. `UNIQUE(itemdata_id)` makes it a single-row test. |
| | **`skuWritePermitsItsOwnFixAssignedPickFace`** | **ADDED 2026-08-09.** The positive half — pointing a SKU at the flowbin **it already owns** must still be accepted; that is the intent rule (e)'s tier-1 exemption exists for. **All three are needed**: without this one, an implementation that bans every fix-assigned flowbin at tier 1 would pass. |
| | **`p1IsSkippedOnlyForFlowbinDestinations`** | **ADDED 2026-08-09 — the corrected §3.4b predicate.** P1 is skipped for `sltname == 'flowbin'` and **still applied** to `overstock box` / `overstock pallet` / `cases and pallets`. **This test is the whole point of the correction** — the superseded `useforpicking OR flowbin` form relocates SBDEV-2731's error to putaway, where `transferUnitLoadToLocation` re-runs P1 at `UnitloadBusinessService:187-200`. Fixture must be a non-flowbin type **inside a `useforpicking` area** (12 `overstock box` + 3 `overstock pallet` exist on `wms2-hydra-dev2`; 69 `cases and pallets` on `wms2-wineco-dev`). |
| | **`p1IsNotSkippedAtReceiveTime`** | **ADDED 2026-08-09.** `requireCompatible` contains **no skip branch**; the step-15 gate runs *before* it and retargets to the lane. Guards against a skip that would also fire for staging / cross-dock destinations, which are **not** diverted and where P1 is the only compatibility check. |
| | `warehouseWriteRejectsLockedLocation` | absolute reject at warehouse scope |
| | `readCommittedDestinationUsesPerScopeQuery` | one case per scope; a MERCHANT read must **not** touch `itemdata` (§3.9.2) |
| | `clearWritesNullAndAudits` | `null` ⇒ no validation, still audited, `new_location_id IS NULL` |
| | **`warehouseClearWritesEmptyStringNotDelete`** | `sysvalue=''`, row still present |
| `PutawayConfigControllerUnitTest` (**new**) | `confirmationAbsentWithNonZeroCountReturns409` | the 409 branch of §3.5a's contract |
| | `confirmationCountMismatchIsRejected` | a stale count ⇒ 409, never a write |
| | `totalIncompatibilityReturns422` | and `blockingReason` ⇒ 422 |
| | `countRecomputedNotTrustedFromPreview` | the writer recomputes; the preview value is never authoritative |
| `PutawayConfigRepositoryEventHandlerUnitTest` (**new**) | `halItemdataWriteValidates` / `halClientWriteValidates` / `halSyspropWriteValidatesOnlyOurKey` | validation fires; other sysprops pass through untouched |
| | **`unrelatedFieldEditIsNotValidated`** | destination unchanged ⇒ the handler returns before validating (§3.9.3) — the edit-lock regression guard |
| | **`createPathNeverReadsPreviousValue`** | `@HandleBeforeCreate` does not call `readCommittedDestination` (§3.9.2) |
| | **`handlerThrowsUncheckedNotBusinessException`** | the rejection is a `PutawayConfigValidationException` (§3.9.7) |
| | **`syspropDeleteIsAudited`** | deleting the guarded syskey still deletes, and writes one audit row with `new_location_id IS NULL`; deleting any other syskey writes none (D12) |
| `SystemPropertyControllerUnitTest` | `createRejectsGuardedSyskey` / `updateValueRejectsGuardedSyskey` | §3.9.1; every other syskey still writes |
| `UnitloadBusinessServiceUnitTest` | `:193, 208` **rewritten** | rendered `unitloadTypeNotPermittedOnLocation`; **assertion tightened, never loosened**. A companion case asserts `putawayDestinationNotPermitted` is **not** produced here |
| `ReceivingServiceUnitTest` | `resolverInvokedOnceAboveLoop` | one `resolve` call for an N-case receipt |
| | `resolveIsCalledForBothBranches` | resolver called even when `carrier != null` — the 2731 regression guard |
| | `nonCarrierPathStillFailsOnIncompatibleDestination` | `carrier == null` + incompatible ⇒ `BusinessException`, and **no `Unitload` was created** |
| | `carrierPathDoesNotFailOnIncompatibleDestination` | `carrier != null` + incompatible ⇒ receipt completes, WARN logged, and the single `resolved(...)` counter carries `compatible="false"`; there is **no** separate counter |
| | `carrierPathPlacesOnCarrierAndWarns` | UL goes to the carrier; WARN + metric on a non-tier-4 source |
| | `resolverFailurePropagatesAsBusinessException` | never a bare `RuntimeException` (§3.6.2) |
| `ReceivingControllerUnitTest` | `getPutawayDestinationShape` | all 7 fields; `source` is the enum name |
| | `businessExceptionSurfacesMessage` | not the generic "contact support" string |
| `ItemDataControllerUnitTest` | `:111-153` extended | the live write path validates + audits; no `allEntries` eviction |
| `SkuRestControllerUnitTest`, `FileImportControllerUnitTest` | extended | created SKUs have `putawaylocationId == null`. **The lane-presence guard clause is `FileImportController`'s only** (clarified 2026-08-09): §0.1 rows 8/9, §3.2 and §5.3 all delete `SkuRestController`'s `findByName(PutAwayLane)` lookup — it existed solely to seed the id — and `S1-neg2` enforces the deletion. `S3-pos1`/`S3-pos2` pin the surviving SBDEV-2037 guard in `FileImportController`. Nothing is left unguarded: a missing lane fails at the resolver's tier-4 lookup, which names the tier |
| `EntityUnitTest`, `ItemdataRepositoryTest`, `TestDataFactory`, 3 H2 tests | updated | field no longer required |

### 7.2 Integration / context-load lane

| Test | State | Note |
|---|---|---|
| `PutawayResolverContextLoadTest` (**new**, `smoke/`) | `@Disabled` `TODO(SBDEV-2217)` | Autowires `PutawayDestinationResolver`, `PutawayDestinationQueryService`, `PutawayConfigService`, `PutawayDestinationValidator`, `PutawayResolutionMetrics`, `PutawayConfigRepositoryEventHandler`, `PutawayConfigController` (plus `PutawayConfigAuditService` from 1b) and asserts non-null. **Seven new beans is exactly the DI-drift risk unit tests cannot see.** Modelled on `smoke/ReplenishReassignContextLoadTest.java`. Run with `RUN_MVN=1` once the harness is restored. |
| `SkuRestControllerAtomicityIntegrationTest` | stays `@Disabled` | would otherwise prove the no-seed change end to end |
| `ReplenishorderRepositoryIntegrationTest:66`, `CustomerorderBatchServiceParallelStreamRegressionIT:187` | fixtures updated, stay `@Disabled` | |
| **`V2.2.13` themselves** | **no automated coverage** | harness scans a different directory (§2.9). Covered by §7.3 SQL rows plus the scratch-DB double-apply in Steps 3 and 20 only. **State this in both PR bodies.** |

### 7.3 Manual Test Plan (mandatory)

Every row assumes: **the migration its phase carries has been applied to the tenant first** — `V2.2.13` (§5.1 row 1). Cache note: after any config write, re-read **in the same browser session** — a 5-min Caffeine TTL means another replica may serve a stale value, so **do not** validate a config change by loading the screen on a different replica.

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| M1 | No config ⇒ no behaviour change | DEV `wh01_hydra_v2t` | Apply `V2.2.13` (one migration; the old "+ one more for the 1b run" reflected the superseded two-phase split). Receive a case of any SKU, no carrier. | Unit load lands on `PutAwayLane` exactly as before; `wms2.putaway.resolution{source="STANDARD_PUTAWAY_LANE"}` +1 | |
| M2 | Backfill correctness and pre-image capture | DEV DB | `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL` and `... IS NOT NULL` before/after; then the `captured` / `nulled` query in §5.1 | NULL count == pre-migration lane-id count; NOT NULL count unchanged; `captured == nulled` and both **non-zero** | |
| M3 | Warehouse default honored | DEV | Admin → Parameters → Configuration → Operation Options → set `DEFAULT_PUTAWAY_LOCATION` to a compatible storage location. Receive, no carrier. | Stock lands at that location; `source="WAREHOUSE_DEFAULT"` | |
| M4 | Merchant beats warehouse | DEV | Set a different compatible location on one merchant (Admin → Shippers). Receive for that merchant, then for another. | Merchant's location for the first; warehouse default for the second; sources `MERCHANT_OVERRIDE` / `WAREHOUSE_DEFAULT` | |
| M5 | SKU beats merchant | DEV | Set a third compatible location on one SKU. Receive it. | SKU's location; `source="SKU_OVERRIDE"` | |
| M6 | Clear cascades upward | DEV | Clear the SKU override → receive; clear the merchant → receive; blank the sysprop → receive. | Destination walks merchant → warehouse → `PutAwayLane`; the sysprop **row still exists** with `sysvalue=''` | |
| M7 | **Write-time rejection (the whole point of D6)** | DEV | Try to set a SKU whose `defultype_id` is `Case` to a `flowbin` location. | Rejected at save with a message naming SKU, destination, reason and remedy. **Nothing persisted**; `wms2.putaway.config.rejected` +1 | |
| M8 | **Merchant-scope count-and-confirm (D11)** | DEV | (a) Set a merchant default incompatible with *some* of its SKUs, no confirmation. (b) Re-issue with `confirmIncompatibleSkus=<n>` where `<n>` is the returned count. (c) Re-issue with a deliberately wrong `<n>`. (d) Set one incompatible with **all** of them. (e) Set a **locked** location. | (a) **409** naming the count and one example SKU; nothing persisted. (b) **write succeeds**, count recorded on the audit row. (c) **409** — stale confirmations never slip through. (d) **422**, no confirmation accepted. (e) **422** with `blockingReason=LOCKED`. `wms2.putaway.config.rejected` increments on each rejection | |
| M9 | **HAL bypass is closed** | DEV | `curl -X PATCH /v3/itemdata/{id} -d '{"putawaylocationId": <incompatible>}'`; repeat for `/v3/client/{id}` and `/v3/sysprop/{id}`. | All three **422** with the actionable message — **not** 4xx-in-general and **not** 500: a 500 means the handler threw a checked exception (§3.9.7). `wms2.putaway.config.rejected{channel="hal"}` +3. **A 2xx here means the event handler is not registered — hard stop.** | |
| M9a | **HAL edit of an unrelated field still works** | DEV | On the SKU whose destination is *already* invalid, `PATCH /v3/itemdata/{id}` changing only `description`; repeat on a client via the live shipper screen. | **2xx.** Validating the state rather than the delta would turn config rot into an edit lock (§3.9.3) | |
| M9b | **Direct-save bypass is closed** | DEV | `POST /v3/systemProperty/create` and `POST /v3/systemProperty/updateValue` with `key=DEFAULT_PUTAWAY_LOCATION`; then the same two calls with any other key. | The guarded key is **rejected** with a message pointing at `PUT /putawayConfig/warehouse`; every other key writes exactly as today. **A success on the guarded key means N1 was not fixed — these endpoints publish no SDR event, so the handler cannot see them** (§3.9.1) | |
| M9c | **Delete is accepted, audited, and not a trap (D12)** | DEV | Press the delete button on the `DEFAULT_PUTAWAY_LOCATION` row in Operation Options. Then, **without any SQL**, set a warehouse default again from the same screen. | The row is deleted and the operation reports success; one `putaway_config_audit` row records the clear with `new_location_id IS NULL`; receiving falls through to tier 4. The Operation Options screen **still offers the control** and setting it **re-creates the row**. Deleting any other sysprop behaves exactly as today | |
| M10 | **Receive-time backstop** | DEV DB + UI | Configure a valid destination, then `UPDATE location SET type_id = <incompatible> WHERE id = ...` behind the app's back. Receive. | Receipt **hard-fails** with the actionable message (not silently rerouted); whole receipt rolled back, no `goodsreceiptposition` rows; `wms2.putaway.resolution.rejected` +1 | |
| M11 | Carrier receipt | DEV | With a merchant default set, receive **onto a carrier pallet**. | Unit load on the carrier (unchanged); receiving form **displays** the configured destination + source; WARN logged; `resolution{carrier="true"}` +1 | |
| M12 | Hub-and-spoke null SKU | DEV | Receive against a `createHubAndSpoke` advice position (`itemdataId IS NULL`). | No 500. Resolution starts at tier 2 | |
| M13 | Mobile putaway not broken, and the message is the expected one | DEV mobile | After a direct placement to a **storage-area** location, scan that unit load in mobile putaway. | Pre-existing **`unitloadNotInInboundArea`** message from `MobilePutAwayService.java:113-117` (expected, not a crash) — **not** `unitLoadNotInPutAwayLane`, which is unreachable for a storage-area unit load. A unit load actually on the lane still puts away normally, and `storePalletBackOnPutawayLane` still enforces its user-location guard | |
| M13a | **Recovery path for a misplaced unit load** | DEV mobile + web | Take the unit load from M13 and move it with mobile "Move Unit Load" (`MobileMoveUnitloadService`); repeat with the web **Transfer Stock** screen. | Both move it successfully. This is the documented remedy an operator is given when putaway refuses a directly-placed unit load — the unit load is not stuck (§3.7.4) | |
| M13b | **Multi-case receipt into a location under concurrent replenish/transfer** | DEV | Point the warehouse tier at a live **storage** location (the advanced tier of the picker). Start a multi-case receipt into it while a replenishment or transfer task is working the same location. | Either both complete, or the receipt fails with a rollback and a `40P01` / `DeadlockLoserDataAccessException` appears in the log. **Record which.** This is the only manual probe for §7.6 row 8's lock-order inversion; note that `/receiving/receive` returns 200-with-`errors`, so watch the log, not the HTTP status | |
| M14 | Inventory history names the real destination | DEV DB | After M3, `SELECT * FROM unitload_record WHERE unitload_id = ... ORDER BY id` | Destination location is the configured one, not `PutAwayLane` | |
| M15 | Audit trail | DEV DB | After M5 + M6 + M9, `SELECT * FROM putaway_config_audit ORDER BY changed_at` | One row per change; correct `scope`, `subject_label`, previous/new (id **and** name), `changed_by` = the Keycloak user, `channel` `typed`/`hal` | |
| M16 | Permissions — typed endpoints | DEV | Repeat M5 as a non-`sb_admin` user, via UI **and** via curl against `PUT /putawayConfig/sku/{id}`. | 403 from the API; the field is hidden/disabled in the UI | |
| M16a | **Permissions — HAL channel** | DEV | As a non-`sb_admin` user: `curl -X PATCH /v3/sysprop/{id}` changing `DEFAULT_PUTAWAY_LOCATION`; repeat on `/v3/itemdata/{id}`. | **403**, not 422 and not 200. A 200 means the authorization check is inert — which is exactly what happens if `@PreAuthorize` is placed on the event-handler methods instead of on `PutawayConfigService` (§3.9.4, §3.12). **Hard stop.** | |
| M17 | Receiving form shows source | DEV | Open the receive form for a SKU with a merchant default. | Value is the effective location (**not** the literal "Put Away Lane") plus a "Merchant default" chip | |
| M18 | persistedState isolation | DEV | Set a value on tenant A, switch to tenant B in the same browser, open the config screen. | Tenant B shows **its own** value — no bleed from `localStorage['vuex-web']` | |
| M19 | Rollback drill | DEV | On a copy: run the §5.1 one-statement replay (`UPDATE itemdata … FROM putaway_config_audit WHERE channel='migration'`), blank the sysprop, `UPDATE client SET defaultputawaylocation_id = NULL`, redeploy the previous app version. | Receiving works exactly as pre-change; every SKU is back on its recorded pre-migration destination; the `client` column and audit table are harmlessly orphaned (§8.3) | |
| M20 | **The display endpoint is reachable at all** | DEV | `curl GET /receiving/getPutawayDestination/{advicePositionId}` against a real advice position. | **200** with the 7-field envelope. A 500 with `IllegalTransactionStateException: No existing transaction found … 'mandatory'` means the controller calls the resolver directly instead of the §3.1.5 facade — no mocked unit test can catch this. **Hard stop for Phase 1.** | |
| M21 | **Receipt correction after direct placement (N-22)** | DEV | Receive a SKU whose tier-1 destination is a **non-lane** location, then `delete` **and** `adjust` that goods-receipt position | Per the §6 decision: either both succeed, or both fail with an actionable message that names the destination and says correction is unavailable for directly-placed receipts. **A raw `"UnitLoad not in area for goods in anymore"` is a FAIL** — that is the unhandled path. | |

### 7.4 e2e lane

M3 → M5 → M6 → M17 executed in one browser session against DEV constitute the e2e path: configure at three tiers through the real UI, receive through the real receiving screen, observe the effective destination in the form and the stock in the resulting location. Automated e2e is **not** added — there is no e2e harness for wms2-web-ui and building one is out of scope.

### 7.5 Observability lane

| Check | How |
|---|---|
| all four counters registered | `GET /actuator/metrics/wms2.putaway.resolution` etc. after one receipt |
| tag cardinality bounded | `source` ≤ 4, `carrier` ≤ 2, **`compatible` ≤ 2**, `scope` ≤ 3, `channel` ≤ 3 (`typed`/`hal`/`migration`), `tenant` ≤ 5 ⇒ **≤ 80 series** on `wms2.putaway.resolution` |
| **tier-2/3 adoption is observable** | after Phase 2, `wms2.putaway.resolution{source="MERCHANT_OVERRIDE"}` + `{source="WAREHOUSE_DEFAULT"}` > 0. **This is pre-mortem P2's only detector** and the §8.1 gate for closing 2731/2643. |
| backstop is quiet | `wms2.putaway.resolution.rejected` == 0 in steady state; alert on > 0 |
| bypass is visible | `wms2.putaway.config.changed{channel="hal"}` should trend to 0 after Phase 2 |

### 7.6 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | introduce state that exists in only one replica? | **No — BY DESIGN, re-verify post-implementation** | No new cache, no `ConcurrentHashMap`, no static. The four existing caches are reused; `CacheConfig` is untouched. `PutawayResolutionMetrics` holds only counters (`MeterRegistry` is per-replica by design and aggregated by the scraper). **One caveat:** §3.9.6's previous-value carrier between the `Before` and `After` handler phases is request-scoped state; it must be a `@RequestScope` bean or a `ThreadLocal` cleared unconditionally, and it is per-request, not per-replica. |
| 2 | **Connection pool math** | change per-request DB connection usage? | **No — BY DESIGN, re-verify post-implementation** | The resolver adds at most 4 short queries **inside the caller's existing transaction** — same connection, no new pool, no new tenant. Net query delta on the receiving path is ≈ +2 (it also *removes* the old `findById`). |
| 3 | **Scheduled jobs** | add or modify a `@Scheduled` job? | **N/A** | No job is added or touched. |
| 4 | **Long transactions** | hold a transaction across more repository calls or external I/O? | **Yes, marginally — BY DESIGN, re-verify post-implementation** | +≈4 index-backed lookups inside `receiveGoods`' existing transaction, all before the per-case loop. No HTTP, no printer call, no broker. Expected added duration < 5 ms vs HikariCP `connectionTimeout` — immaterial. Config writers are single-entity transactions. (The *lock hold* duration is the separate concern in row 8.) |
| 5 | **Request affinity** | assume a follow-up request lands on the same replica? | **No — BY DESIGN, re-verify post-implementation** | `getPutawayDestination` is stateless and re-resolves from the DB. |
| 6 | **Retry / idempotency** | rely on single-execution semantics? | **No — BY DESIGN, re-verify post-implementation** | Config writes are idempotent last-writer-wins on a single column, protected by the entity `@Version`. `/v3/receiving/receive` is outside `IdempotencyFilter` (which guards `/rest/**`) — unchanged by this plan, not made worse. The audit table may gain a duplicate row if a client retries a config write; duplicate audit rows are harmless and, in fact, the correct record of two requests. |
| 7 | **Tenant context** | use `TenantContext` across an async boundary? | **No — BY DESIGN, re-verify post-implementation** | Everything runs on the request thread. `PutawayConfigAuditService` reads `TenantContext.getCurrentTenant()` synchronously. No `@Async`, no `CompletableFuture`. |
| 8 | **Distributed lock correctness** | add or rely on cross-replica locking? | **YES — accepted risk with named mitigations** | The resolver itself takes no lock and cannot open `REQUIRES_NEW` (`MANDATORY`). It does not follow that no transaction exists: §3.1.5's read facade opens a `readOnly = true` tenant transaction and §3.9.6's `auditAndEvict` opens a read-write one; `MANDATORY` means the resolver *joins* a transaction. **The real exposure is a lock-order inversion that this change makes newly reachable.** `transferUnitLoadToLocation` takes `findByIdForUpdate` on the **destination** Location at `:150` *before* touching Unitload/Stockunit at `:293-294` — Location→UL, **inverting the SBDEV-2232 canonical SU→UL→Location order**. That is harmless today only because receiving's destination is *always* the inbound `PutAwayLane`, a row only receiving and mobile putaway touch. Once tiers 1–3 can point at a live storage or pick location, a receipt holds `FOR UPDATE` on that row for the **whole multi-case receipt**, including across per-case `createCaseLabel` rendering (`ReceivingService.java:491-498`, both inside the loop), while picking, replenishment and transfer lock in SU→UL→Location order. There is **no deadlock-retry infrastructure** in this codebase (SBDEV-1762: "up-front lane-Location lock is an anti-pattern (cross-caller 40P01)"). **Four requirements, all specified elsewhere in this plan:** (i) the deferred "stock-move deadlock-retry hardening" ticket is a prerequisite before any tenant points tier 2 or tier 3 at a live storage location — and an absolute prerequisite before Q9 widens P2.4 to admit pick locations; (ii) the location picker is **tiered** — `useforgoodsin` by default, `useforstorage` behind an explicit "advanced" toggle carrying this lock warning (§3.11.5, Step 19 — *r-next: was "§3.11.2, Step 26"; there is no Step 26*); (iii) manual row **M13b** exercises a multi-case receipt into a location concurrently being picked or replenished; (iv) the **40P01 / `DeadlockLoserDataAccessException` detector** on `/receiving/receive` is budgeted as §5.1 row 8 item (c) — it must be log/exception-based, because that endpoint returns **200-with-`errors`**, never a 5xx, so an HTTP-status alert misses it entirely (the same trap as pre-mortem P3). |
| 9 | **Cache invalidation** | write to a cached entity? | **Yes — three of them; BY DESIGN, re-verify post-implementation** | `itemdata` (2 keys, reusing the correct expressions at `ItemdataService.java:62-67`), `clients` (2 keys, §3.3), `sysprops` (1 key, defensive). Under the **Redis** profile eviction propagates across replicas; under **Caffeine** it does not, so another replica can serve a stale config for up to its TTL. **Accepted**, because (a) the *receiving* path reads all three tiers uncached (§3.10), so no receipt is ever misrouted by a stale cache, and (b) the exposure is admin-screen display only. §7.3's cache note encodes it. HAL writes reach the same evictions because the event handler delegates to `PutawayConfigService`. |
| 10 | **External notifications** | send HTTP/message to an external system inside a transaction? | **No — BY DESIGN, re-verify post-implementation** | No OMS notification, no outbox message, no printer call. Label printing at `ReceivingService.java:498` is unchanged and already outside the failure path. |

#### Evidence (for the "Yes" rows)

| Concern # | What was done / verified | Reference |
|---|---|---|
| 4 | resolution hoisted above the per-case loop, so the added queries are O(1) per receipt, not O(cases) | §3.7.1; loop at `ReceivingService.java:462` |
| 9 | eviction key expressions copied verbatim from the existing correct implementation, not re-derived | `ItemdataService.java:59-67`; `ClientService.java:53, 100` |
| 9 | receiving path is uncached on the three **tier value** reads, but **not** entirely cache-free | `ReceivingService.java:357` (`itemdataRepository.findById`), `:369-370` (`clientRepository.findById`), `SyspropRepository.java:35-36` (`findBySyskeyAndClientIdAndWorkstation`, a derived query, not `@Cacheable`). Tier 3 additionally dereferences `clientService.getSystemClient()`, which **is** `@Cacheable(value="clients", key=…+':SYSTEM')` (`ClientService.java:100`) — harmless, since the system client's identity does not change, and safe under `readOnly` (a cache read inside a read-only tx is fine). `ClientService.java:101-109` returns `null` when no `cl_nr='System'` row exists, so tier 3 `orElseThrow`s a `BusinessException` rather than dereferencing it (§3.4a): an NPE there would be a bare `RuntimeException`, the class §3.6.2 forbids, and `ReceivingController:298-300` would swallow it into "contact support". |
| 9 | `CacheConfig` needs no change ⇒ the two-profile sync trap is avoided entirely | `CacheConfig.java:31-42, 49-69`; guarded by `unit/config/CacheConfigTest.java` |
| 8 | `Propagation.MANDATORY` chosen specifically to make `REQUIRES_NEW` unrepresentable | §3.1; `UnitloadBusinessService.java:259-260` |

### 7.7 v2-only constraint checklist (8 rows, explicit verdict each)

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | Every new tenant service method carries `@Transactional(value = "tenantTransactionManager", …)` — a **bare** `@Transactional` silently binds to the `@Primary` landlord TM | **BY DESIGN — re-verify post-implementation** | resolver `MANDATORY` + tenant TM; query facade `readOnly = true` + tenant TM; writers `rollbackFor = {BusinessException, FacadeException}` + tenant TM; audit `MANDATORY` + tenant TM. `unit/config/TransactionManagerArchTest.java` enforces it; verify-script rows P1-TX-* assert the literal string per file. |
| 2 | The resolver must **not** be `readOnly = true` (landmine A1) and must **not** open `REQUIRES_NEW` | **BY DESIGN — re-verify post-implementation** | `Propagation.MANDATORY` with no `readOnly`. A1 is moot anyway — `getStringDefault` is never called (§3.4a), asserted by `neverCallsGetStringDefault`. `MANDATORY` is kept deliberately, but it constrains **who may call** `resolve(...)`: the non-transactional display endpoint goes through the §3.1.5 read facade, and the non-transactional SDR event handler never calls the resolver or a `MANDATORY` audit writer from its `Before` phase (§3.9.6). Every call-site must be confirmed transactional — §7.7a. |
| 3 | OSIV is disabled ⇒ load entities inside the transaction or return ids/DTOs | **BY DESIGN — re-verify post-implementation** | All eight entities involved use manual `Long` FK ids with **no JPA associations**; `Resolution` holds a fully-loaded `Location` obtained inside the caller's transaction. |
| 4 | Cache evictions cover every write path, in **both** profiles | **BY DESIGN — re-verify post-implementation** | §3.10; no new cache ⇒ nothing to duplicate. HAL writes delegate to `PutawayConfigService` so they share the evictions. |
| 5 | Jakarta namespace only (`jakarta.*`) | **BY DESIGN — re-verify post-implementation** | Nothing is ported from v1 (SBDEV-2642 shipped no code). New entity mirrors `CustomerorderCancellationLog`'s `jakarta.persistence.*` imports. |
| 6 | H2-safe SQL in anything a non-Testcontainers test exercises | **BY DESIGN — re-verify post-implementation** | No new `@Query`. The only native SQL is `readCommittedDestination`'s three per-scope statements; the SKU and MERCHANT forms are H2-compatible, and the WAREHOUSE form's `nullif(trim(sysvalue),'')::bigint` is **Postgres-specific** — if any H2 test exercises it, use `CAST(... AS BIGINT)` instead. `V2.2.13` is Postgres-only but runs in no test (§7.2). |
| 7 | New/changed endpoints need a `BaseControllerUnitTest` subclass | **BY DESIGN — re-verify post-implementation** | `getPutawayDestination` covered in `ReceivingControllerUnitTest`; `PutawayConfigController` in `PutawayConfigControllerUnitTest`; `SystemPropertyController`'s guards in `SystemPropertyControllerUnitTest`; the HAL PATCH guard needs its own controller test (M9 is its manual twin). |
| 8 | Entity/DDL drift ⇒ entity and DDL land together | **BY DESIGN — re-verify post-implementation**, with the §5.1 row-1 blocker | `Client.defaultputawaylocationId` and `PutawayConfigAudit` both land in the single Phase 1-API commit alongside `V2.2.13`. **`ddl-auto` is `none`, so drift does not fail startup — it fails `42703` per request.** `develop` merge ⇒ DEV auto-deploy; the runtime migrator applies `V2.2.13` at boot on tenants that have Flyway history, but **skips the history-less Hydra DEV copy**, which is why §5.1 row 1 requires repairing that copy and pre-applying. Still the single most likely way this plan ships broken (pre-mortem P1). |

> **Verdict semantics.** Every verdict in §7.6 and §7.7 describes *design intent about code that does not
> exist yet*, which is why none of them reads PASS. **The verify script and the post-implementation gate
> hold the real PASS/FAIL; these two tables hold intent only.**

### 7.7a Resolver call-site transaction audit (MANDATORY before Phase 1 merges)

`resolve(...)` is `Propagation.MANDATORY`, so **every** call-site must already be inside a tenant
transaction or it throws `IllegalTransactionStateException` at runtime — a failure no grep check and no
mocked unit test can detect. Enumerate and confirm each:

| # | Call-site | Transaction present? | Evidence / required change |
|---|---|---|---|
| 1 | `ReceivingService.receiveGoods` (§3.7.1, resolution hoisted above the per-case loop) | **Yes — pre-existing** | `@Transactional(value = "tenantTransactionManager", …)` at `ReceivingService.java:302`. No change needed. |
| 2 | `ReceivingController.getPutawayDestination` (§3.8) | **Only via the facade** | There is **zero** `@Transactional` in `ReceivingController.java` and none anywhere under `controller/`. The controller therefore delegates to `PutawayDestinationQueryService.describeForAdvicePosition`, annotated `@Transactional(value = "tenantTransactionManager", readOnly = true)` (§3.1.5). This is **Phase 1 Step 14**; manual row M20 is the proof. |
| 3 | `PutawayConfigRepositoryEventHandler` (§3.9) | **Never calls the resolver, and never a `MANDATORY` writer from `Before`** | `@HandleBeforeSave`/`@HandleBeforeCreate` fire from `RepositoryEntityController` *before* `repository.save()`, outside any transaction; OSIV is off (`application.properties:55`) so there is not even a persistence context. The `Before` phase calls only `readCommittedDestination` (`readOnly = true`, opens its own) and `validateOnly` (no transaction, no write); the audit lands in the `After` phase via `auditAndEvict`, which opens its own read-write tenant transaction **after** SDR's save has committed (§3.9.6). |
| 4 | Typed config-write endpoints (§3.5, §3.5a) | **Yes — by construction** | Each writer is annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {…})`. `PutawayConfigController.preview` carries `readOnly = true` for the same reason as row 2. |
| 5 | `GET /client/{id}/effectivePutawayDestination` (N9, §3.11.3, Phase 1) | **Must reuse the §3.1.5 facade** | It goes through `PutawayDestinationQueryService.describeForClient` for the same reason as row 2 — do not let it call the resolver from a controller. |

**Adequacy note.** `readOnly = true` on rows 2 and 5 is safe **only** because §3.4a reads tier 3 via
`SyspropRepository` and never calls `SyspropService.getStringDefault`, which INSERTs on a total cascade
miss (`SyspropService.java:234`, landmine A1). `neverCallsGetStringDefault` is the assertion that keeps
that invariant true; if it is ever deleted, rows 2 and 5 become write-in-readOnly-transaction bugs.

### 7.8 Deliberately-skipped coverage

| What | Why |
|---|---|
| Automated test for `V2.2.13` | The IT harness scans `db/v1-to-v2-onboarding/schema`, not `db/migration/` (§2.9). Covered by M2 + the scratch-DB double-apply in Steps 3 and 20. |
| Automated e2e | No e2e harness exists for `wms2-web-ui`; building one is out of scope. Covered by §7.4's manual path. |
| `AdviceService.acceptHubAndSpokeAdvice` (§0.1 row 25) | No `Itemdata`, no receipt destination decision. §10 Q4. |
| Mobile UI (`storePallet.vue`) | Not in D4's phasing. §8.4. |
| A UI for reading `putaway_config_audit` | The AC says "recorded", not "displayed". §8.4. |
| Concurrency test on config writes | Single-column last-writer-wins under `@Version`; no invariant spans two rows. |

---

## 8. Rollout

### 8.1 Merge order — TWO merges plus an external prerequisite; the DEV-apply gate binds to merge 1

**One migration, one gated merge.** Earlier revisions split this into two migrations across four
merges so an ungated slice could ship first. D12 removed that: the ungated slice is now **SBDEV-2731 PR1**,
which is not this plan's merge at all. What remains is a single `V2.2.13` that adds
`client.defaultputawaylocation_id` — a column `Client` maps — so **merge 1's operator gate is absolute.**

**Q7 is CLOSED (D12).** The earlier blocker here read "confirm nobody is mid-flight on an overlapping
resolver". The SBDEV-2731 plan now exists and was inspected: it contains **zero** occurrences of resolver,
tier, precedence or merchant, and builds no competing resolution. This plan remains sole owner of the
precedence contract, and **Q7 no longer blocks the TDD gate.**

| # | Merge | Operator gate | Verify on DEV after |
|---|---|---|---|
| **0** | ~~**SBDEV-2731 PR1** → `develop`~~ **MERGED 2026-08-07** — api `6bc709a`, ui `4ce39a1`. Prerequisite 0 satisfied. *(external prerequisite, D12)* | none | 2731's own verify script; **then close SBDEV-2731 on PR1 — and say explicitly in the ticket that the reported 1,000-unit ICE PACK receipt is NOT yet fixed** (it is a tier-1 override into a pick face). *(2026-08-04: F3 itself is answered — SBDEV-2796 chose (c), so that receipt is now **permitted** to succeed and over-fill the bin. What still gates it is no longer the product question but **C2b, Q1, Q4** and the new **Q11**, and the Fix B work those gate now lands in this plan — §5.2, §10.4.)* |
| **0b** | ~~**SBDEV-2854 (PR #132) → `develop`**~~ **MERGED 2026-08-07** (`68274b0`). **STILL OPEN: `V2.2.10` applied to every tenant this plan's `V2.2.13` will reach** *(external prerequisite, added 2026-08-06)* | `V2.2.10` | **Ordering is load-bearing and runs the other way from what you would guess.** 2854 renumbered *down* from `V2.2.13` to `V2.2.10` to keep the sequence contiguous, so this plan moved to `V2.2.13`. If `V2.2.13` is applied **first**, `V2.2.10` arrives out-of-order: `outOfOrder=false` skips it and `validateOnMigrate=true` then throws *"Detected resolved migration not applied to database: 2.2.10"* on every subsequent boot — caught by `StartupFlywayMigrator.java:150`, logged, and **swallowed**, so the tenant silently stops receiving that and every later migration. This is the exact failure the renumber was performed to avoid, with the roles reversed. Verify with `SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 3;` before applying `V2.2.13` anywhere. |
| **1** | **1-API** → `develop` (DEV auto-deploys) | **`V2.2.13` applied to every DEV tenant FIRST** (operator, Flyway runbook `--env dev`). Absolute: the merge adds `Client.defaultputawaylocationId`. `ddl-auto` is **`none`**, so the context starts anyway and instead throws **`42703`** on every `client` read — DEV looks healthy while receiving and the client screens error per request (pre-mortem P1). **Repair the history-less Hydra DEV copy with `db/backfill-flyway-history.sh` first**, or the boot-time migrator skips it and `V2.2.13` never applies there. The Hydra dev copy has **no `flyway_schema_history`**, so verify via `information_schema.columns` + a `los_sysprop` query, never Flyway history. Per-tenant precheck first: `SELECT count(*) FROM location WHERE name='PutAwayLane';` must be exactly 1 (verified on `wh01_hydra_v2` and `wh01_hydra_v2t`; **the other three v2 tenants are unverified**). | `PHASE=1` verify 0-fail; M1, M2 (backfill counts **and** `captured == nulled`); M9 (all three HAL PATCHes ⇒ **422**); M10; M12 |
| **2** | **2-UI** → `develop` | none | M3, M5–M7, M11, M13, M13a, M13b, M14, M16, M17, M18 — **then close SBDEV-2732** |

**Why the Phase 1-API gate is absolute.** DEV auto-deploys on push. The app *does* run Flyway at boot
(SBDEV-2801) — but it **skips a tenant DB with no `flyway_schema_history`**, and the Hydra DEV copy is one,
so there `V2.2.13` never applies. And because `ddl-auto` is **`none`**, the app does not refuse to start:
it boots green and fails `42703 column client.defaultputawaylocation_id does not exist` on every read.
So merging Phase 1-API before the operator has migrated **takes DEV down** — the ordinary merge workflow is
itself the failure path (pre-mortem P1). Verification there is unusual: the Hydra dev copy has **no
`flyway_schema_history` table**, so "check Flyway history" is invalid — confirm via
`information_schema.columns` and a `los_sysprop` query instead.

**Per-tenant precondition, and it binds the single Phase 1-API merge.** The preflight guard lives in `V2.2.13`
and aborts unless exactly one location is named `PutAwayLane`. Verified = 1 on `wh01_hydra_v2` and
`wh01_hydra_v2t`; **the other three v2 tenants are unverified.** Run
`SELECT count(*) FROM location WHERE name='PutAwayLane';` on each before scheduling `V2.2.13` — a zero is
tolerated by today's code (`FileImportController:355-359` exists precisely because a tenant can lack the
lane) but will abort this migration.

**After both merges**

1. **Close SBDEV-2731** as delivered — its display half is 1a-UI, its honor half is §3.7. It must not be
   worked independently (D8/D9).
2. **Unblock SBDEV-2643.** Its backend already exists and is now validated and audited. But §10 Q3: it is
   materially bigger than "add a field" — `skuData.vue:100-123` has its create/edit block commented out,
   so it needs a SKU edit form built from scratch. Estimate accordingly.
3. **Do not declare the feature delivered on green tests.** Gate on adoption:
   `wms2.putaway.resolution{source="MERCHANT_OVERRIDE"|"WAREHOUSE_DEFAULT"} > 0` (§7.5). This is the only
   detector for pre-mortem P2 — the plan's most likely failure, in which everything ships, every test is
   green, and no operator ever sets a tier-2/3 value.

**UAT** — apply `V2.2.13` **first** (UAT `wsl` trails; confirm its Flyway head), then
deploy, then M1/M3/M4/M5. **Production** — apply both **first** to the single v2 prod tenant, then deploy.
Ship with all three tiers unconfigured and enable per merchant on request, so the blast radius at cutover
is zero by construction.

### 8.2 Blast radius per tier

| Tier | Blast radius of a bad value | Gate |
|---|---|---|
| SKU | one SKU | write validation + receive backstop |
| Merchant | all SKUs of one merchant | write validation across the merchant's DISTINCT `defultype_id` set |
| **Warehouse** | **every receipt for every merchant** | write validation across the tenant's DISTINCT `defultype_id` set, with an explicit count-and-confirm above zero and an unconditional 422 at 100 % (D11); seeded blank; `sb_admin` only, enforced in `PutawayConfigService`; event handler covers `PATCH /v3/sysprop/{id}` and `DELETE /v3/sysprop/{id}`; `SystemPropertyController`'s two direct-save endpoints reject the syskey (§3.9.1). Pre-mortem **P3**. |

### 8.3 Rollback

Code: revert the PRs for the phases being rolled back. Data: `V2.2.13` is **forward-only** and needs no down-migration to make the previous app version work — see M19. Restoring `NOT NULL` requires the §5.1 one-statement replay from `putaway_config_audit` first (falling back to `UPDATE itemdata SET putawaylocation_id = <laneId> WHERE putawaylocation_id IS NULL` if the pre-image is missing); the `client` column and the audit table can be left in place harmlessly (the reverted app never reads them, and with `ddl-auto=none` nothing inspects the schema at startup — extra columns and tables are inert). **Do not drop `client.defaultputawaylocation_id` or `putaway_config_audit` on a rollback** — a re-roll-forward would then need a second migration version, and dropping the audit table destroys the only record of what the backfill discarded.

### 8.4 Explicit follow-ups (not in this plan)

- **[SBDEV-2821](https://app.clickup.com/t/868km8j9z) — tier-1 direct placement onto a pick face. OWNS everything D15 defers.** Filed 2026-08-04 so the deferred bundle has an owner: 2731 **Fix B** (flowbin classification + resident-UL resolution), **C2b**, 2731's **Q1**/**Q4**, **F1**, **F4**, **F5**, **Q11**, the coupled receipt-correction-guard decision, and the over-bound observability obligation. **It also owns the relaxation of P2.5 and P2.7(c)** — and carries the warning that relaxing either without the placement work in the same change re-enables the broken path, because `ReceivingService.java:454-457 → :491` places tier-1 destinations with no gate. **SBDEV-2821 is what delivers the reported ICE PACK receipt**, which neither 2731 PR1 nor this plan does. **Q11 was answered on 2026-08-06 — "bounds are advisory for replenishment", the same as for receiving.** ~~Strict order unchanged: 2731 PR1 → this plan → SBDEV-2821.~~ **⚠ THE ORDER IS REVERSED — see Q15 below. It is now `2731 PR1 → SBDEV-2821 → this plan`.**

  > **⚠ THIS BULLET IS SUPERSEDED — SBDEV-2821 adopted option (iii) on 2026-08-08.** It no longer builds direct
  > placement, so **Fix B, C2b, F1, F4, F5, the receipt-correction-guard decision and the three `Flowbin*`
  > message keys are all OUT OF SCOPE THERE** — none of them is being built by anyone. 2821 instead routes at
  > putaway: the container receives, and the SKU's configured location is consumed by `MobilePutAwayService`,
  > whose `storeBoxOnLocation:497-514` already performs flowbin classification, FLA auto-creation and
  > resident-UL merging. **C2b becomes unreachable** rather than deferred, because `Goodsreceiptposition` is
  > never repointed. 2731's **Q1** is closed (label prints; no code) and **Q4** is closed (option (iii)).
  >
  > **UPDATED AGAIN 2026-08-08 (Q12 → iv-b).** This plan permits pick-face destinations at every scope and
  > **diverts them at receipt** (step 15's `useforpicking` gate) rather than placing them. What 2821 needs from
  > here is that the configuration be writable — delivered by relaxing P2.5/P2.7(c) **in the same change as the
  > gate**. Non-pick-face destinations are still placed at receipt by step 17 and never reach putaway.
  >
  > **✅ Q15 — the tier seam — RESOLVED 2026-08-08 as (A). THIS PLAN NOW SHIPS *AFTER* SBDEV-2821.**
  >
  > Under (iv-b) putaway must consume **pick-face destinations for all four tiers**, but SBDEV-2821's plan is
  > written for **tier 1 only** (it reads `itemdata.putawaylocation_id` directly). The two candidate splits
  > were:
  >
  > - **(A) 2821 ships tier 1 only, independently** — it needs nothing from this plan and is gated only on M1,
  >   so it **delivers the reported ICE PACK fix immediately**. This plan then extends putaway to consume the
  >   full four-tier `Resolution`.
  > - **(B) 2821 waits for this plan's resolver** and consumes all four tiers in one change. Cleaner seam, one
  >   implementation — but it puts the reported production bug behind this entire plan.
  >
  > **(A) chosen by the ticket owner (Nam Park), 2026-08-08.** Schedule-only and reversible; nothing in either
  > design changes if it is revisited.
  >
  > **⚠ WHAT THIS COSTS THIS PLAN — a new dependency and a new step.** The bullet above used to end *"Strict
  > order unchanged: 2731 PR1 → this plan → SBDEV-2821"*, written when 2821 was the follow-up that *consumed*
  > this plan's output. **Under (iv-b) the arrow reverses.** Step 15's gate diverts a pick-face destination to
  > the standard putaway lane — and putaway can only offer that destination once SBDEV-2821 §3.2 ships,
  > because `getStorageLocationsForPutAwayItemData` (`LocationRepository:104-111`) returns only locations
  > where the SKU **already has stock**. Consequences, all recorded:
  >
  > - `depends_on:` gains **SBDEV-2821** (frontmatter).
  > - **§5.2 gains step 17a** — extend 2821's candidate surfacing from `itemdata.putawaylocation_id` to the
  >   full four-tier `Resolution`. Without it, merchant- and warehouse-scope pick-face defaults are diverted
  >   by step 15 and then never offered.
  > - **Degraded, not broken, if the order is violated:** the operator can still *manually scan* the
  >   destination (`MobilePutAwayService.verifyScannedLocation:412-456` accepts it), so shipping this plan
  >   first makes the destination undiscoverable rather than unreachable — a UX regression against the
  >   ticket's intent, not data loss.
  >
  > See `SBDEV-2821-tier1-direct-placement-onto-pick-face.md` §0 and §3.2.

  > **⚠ ORPHANED ARTIFACT found 2026-08-06 — three message keys with no owner.** SBDEV-2731's plan
  > (revision 4, §5) records these as *"RELOCATED to SBDEV-2732 (D14) — do NOT add in PR1"*:
  > ```properties
  > BusinessException.FlowbinAssignedToOtherSku=Pick location "%1$s" is already assigned to SKU %2$s, so SKU %3$s cannot be received into it. Choose a different Default Putaway Location.
  > BusinessException.SkuAlreadyAssignedToFlowbin=SKU %1$s is already assigned to pick location "%2$s" and cannot also be received into "%3$s". Clear the existing assignment first.
  > BusinessException.FlowbinOccupiedWithoutAssignment=Pick location "%1$s" already holds stock but has no SKU assignment, so SKU %2$s cannot be received into it. Ask an administrator to reconcile the location.
  > ```
  > **They are thrown only by Fix B — and D14 (2026-08-02) sent them here, but D15 (2026-08-04) then sent
  > Fix B onward to SBDEV-2821.** The keys did not follow. A grep of `sbdocs/1-Projects/wms2/plan/` finds
  > them **only** in the 2731 document: this plan does not carry them, SBDEV-2821 does not mention them,
  > and 2731 is explicitly not adding them. **They belong to SBDEV-2821, with Fix B.** Add them to that
  > ticket rather than to this plan's bundle — an unreachable operator-facing string invites a reviewer to
  > wire it up prematurely, which is precisely why 2731 declined to ship them.
  >
  > **This is the third artifact orphaned by the same mechanism** — F3/Q5 (became SBDEV-2796), the D15
  > bundle (became SBDEV-2821), and now these keys. Each time, scope moved between tickets and something
  > attached to it did not. **When D-decisions relocate scope, enumerate what travels with it:** code,
  > tests, message keys, verify checks, and open questions.
- **[SBDEV-2796](https://app.clickup.com/t/868kk4rmv) — pick-face capacity (F3 / Q5). ANSWERED 2026-08-04: option (c), "valid, and bounds are advisory for receiving."** No capacity gate is built; a 1,000-unit receipt into an 84-capacity bin succeeds and the over-bound bin is an accepted, documented state. **The tier-1 direct-placement block is lifted** — but under **D15** that path is deferred anyway, so Fix B, flowbin classification and resident-UL resolution stay OUT of this plan. The three items below travel to the follow-up: **Three items remain open and two of them are that ticket's own unmet ACs:**
  - **Replenishment behaviour against a permanently over-bound bin — ANSWERED 2026-08-06 ("advisory for replenishment"); owned by [SBDEV-2821](https://app.clickup.com/t/868km8j9z).** SBDEV-2796 AC: *"Replenishment behaviour against an over-bound bin is defined, or over-bound bins are made unreachable"*; (c) deleted the second branch. **Referred back to the B/A.** Tracked here as **§10.4 Q11**.
  - **C2b** — the destructive `Goodsreceiptposition` repointing. SBDEV-2796 AC: *"C2b is resolved or explicitly ruled out of scope by the chosen option"*; (c) does neither. Now the binding gate on Fix B (§5.2, §6).
  - **The capacity-check AC is VOIDED by its own answer** — *"if direct placement survives the decision, a capacity check exists before the transfer"* is unsatisfiable under (c), which declines the check by design. It should be struck from SBDEV-2796 rather than left failing.
- `wms2-mobile-ui` `storePallet.vue:14-23` — show the expected destination on the mobile putaway scan.
- General web-UI role gating (`layouts/default.vue:284-286`, `adminMenu`, `APP_ADMIN_GROUP`) — §3.12.
- A read UI for `putaway_config_audit`.
- `ItemDataController.java:81` — `@GetMapping` that mutates state; changing the verb is a breaking API change.
- Advice-create early validation (§0.1 rows 22–24), if not taken up in Phase 1.
- `AdviceService.acceptHubAndSpokeAdvice` placement review (§0.1 row 25).
- "Stock-move deadlock-retry hardening" (the deferred SBDEV-1762 follow-up) — **a prerequisite before any tenant points a merchant or warehouse default at a live pick location**. §7.6 row 8.
- `SystemPropertyController.updateValue`'s client-blind `findBySyskey(key).get(0)` (`:100-105`) — landmine A3's shape on a write path, affecting every other syskey. Out of scope here; this plan only closes the one key.

---

## 9. Alternatives Considered

**A1 — Merchant tier as a client-scoped `los_sysprop` row (`client_id = <merchant>`).**
Attractive because `SyspropService.getStringDefault` (`:164`) *already* implements a 4-tier cascade — tier 2 "client, ignore workstation" (`:193-205`) and tier 4 "system client, DEFAULT workstation" (`:223-232`) map exactly onto the ticket's merchant and warehouse tiers, needing **no new DDL at all**. There is even an abandoned breadcrumb: `ReceivingService.java:422` is a commented-out reference to that very method.
**Rejected on four independent landmines.** (i) `getStringDefault` **INSERTs** on a total miss (`:234`), so the resolver could write, and clearing the system row is self-undoing. (ii) `getSysvalue` — the accessor most callers reach for — is **client-blind** (`SyspropRepository.java:29-31`, `order by client_id LIMIT 1`, comment: *"legacy code incorrectly assumes one result"*), so any future caller collapses all merchants to the lowest `client_id`. (iii) the `sysprops` cache key **omits `clientId`** (`SyspropService.java:53, 95, 288, 303`), so caching a client-scoped key serves one merchant's value to every merchant. (iv) `setSysvalue` **cannot write a merchant row** at all (`:306` hard-codes the system client), so a writer would have to be built anyway. Add that the per-client tier has **never** been used in production (131/131 rows `client_id=0` on `wh01_hydra_v2t`) and it would be the first real use, on the receiving hot path. A typed nullable FK on `client` (§3.3) costs one additive column and gives referential integrity a `sysvalue text` cannot.

**A2 — Keep `NOT NULL` and use a value sentinel: "has an override" ⇔ `putawaylocationId != laneId`.**
Zero DDL, zero migration, no deploy-order coupling — genuinely the cheapest option, and it was the analysis lane's first reading.
**Rejected.** It makes an *explicit* SKU choice of `PutAwayLane` indistinguishable from "unset", so the ticket's "clear each override independently" AC is unachievable at tier 1. It re-entrenches the hard-coded `"PutAwayLane"` name (`WmsConstants.java:771`) as load-bearing *semantics* rather than a mere fallback, which is precisely what the ticket asks to remove. And it silently changes meaning if a tenant ever renames or duplicates the lane. NULL costs one forward-only `ALTER` that cannot fail on existing data.

**A3 — A third column `itemdata.putawaylocation_source` as an explicit discriminator.**
Most explicit of the three; no sentinel ambiguity and no `NOT NULL` change.
**Rejected** on write-path churn: every one of the four seeding sites plus both read sites plus the ≈10 fixtures would have to maintain *two* fields in agreement, and any path that updates one and not the other produces a state the resolver cannot interpret. NULL carries the same information in one field that already exists.

**A4 — Reuse `SyspropService.getStringDefault` for the warehouse tier only.**
Would give tier 3 for free and matches the abandoned breadcrumb at `ReceivingService.java:422`.
**Rejected** solely because of the `:234` auto-INSERT: the resolver would acquire a write path on the receiving hot path, could not be reasoned about as a read, and two replicas racing on a cold key would collide on `uk8tcoe23qui9q3ancbhx662iqb` (`V2.2.00...sql:3600-3603`). `SyspropRepository.findBySyskeyAndClientIdAndWorkstation` (`:35-36`) reads the same row with no write and no cache. **Do not substitute `findSysvalueByClientIdAndSyskey` (`:46-48`) — that is landmine A6** (no `workstation` predicate against a `(client_id, syskey, workstation)` unique constraint ⇒ arbitrary row). `ReceivingService.java:429-431` is a valid precedent for the *shape* of a direct repository read, but it reads `WAREHOUSE_NAME`, which is not UI-writable, so it is **not** a precedent for skipping the workstation predicate.

**A5 — Force the resolved destination on the carrier path (move the carrier, or split it).**
The most literal reading of SBDEV-2731's "honor".
**Rejected as physically incoherent.** A carrier pallet is one physical object; its cases may belong to several merchants with different resolved destinations, so "the" destination is undefined. Moving the whole carrier would relocate other merchants' stock; splitting it at receive time invents a workflow nobody asked for. §3.7.2 discharges "honor" as surface-plus-suggest on the carrier path, which is neither silent nor ignoring. Recorded in §10 Q1 for business confirmation.

**A6 — `exported = false` on the HAL write methods instead of a `RepositoryEventHandler`.**
Structurally airtight: no unvalidated write path can exist if the endpoint does not exist.
**Rejected for `Client` and `Sysprop` on evidence:** the web UI *depends* on those endpoints — `store/admin/shippers.js:47` uses `PATCH /client/{id}` and `store/admin/configuration.js:73-93` uses `PUT /sysprop/{id}`. Disabling them breaks shipped features. It would be viable for `Itemdata` alone (the SKU screen is read-only), but guarding one of three holes while validating the other two through a handler is worse than one uniform mechanism. Adopted D7's handler for all three, extended to `Sysprop` (§3.9). Note that `exported = false` would not have helped with §3.9.1's direct-save endpoints either — those are hand-written controllers, not SDR routes.

**A7 — Extend `receiving_dto_view` with the effective destination and source.**
D8's presumed mechanism; would let the open-receiving *list* show the destination with no extra calls.
**Rejected on evidence** (§3.8): the view already projects `defaultputawaylocationname`, so nothing is missing for tier 1; four-tier precedence plus P1 compatibility is not expressible in that SQL; and a projected view column couples view and entity into every future change (the mechanism is runtime read failure, not `ddl-auto=validate` — `ddl-auto` is `none`). A per-position endpoint keeps the precedence in the one shared service, which is the ticket's own AC.

---

## 10. Open Questions / Resolved Decisions

### 10.1 Recorded decisions (D1–D12 — decided, not re-opened)

| # | Decision | Where it lands |
|---|---|---|
| D1 | **2732 owns the shared resolver.** All four tiers, config storage, validation and admin UI live here; 2643 and 2731 become thin consumers. | §3.1, §8.1 |
| D2 | **Direct placement, bypass manual putaway.** No sysprop gate; back-compat rests on "no config ⇒ no behaviour change". | §3.7, §6. **Refined by evidence:** on the non-carrier path this is the *existing* mechanism, and v2 has no putaway-task entity to suppress (§2.1). |
| D3 | *(superseded by D6)* fall back down the chain and warn loudly | — |
| D4 | **Phase 1 API, Phase 2 web UI**; TDD gate on Phase 1, re-run at Phase 2 start. | §5.2 |
| D5 | **DROP NOT NULL + stop seeding** at the 4 sites; NULL = inherit. | §3.2. **Backfill resolved** in §5.1. |
| D6 | **Validate at config-write time (primary) + hard-fail at receive time (backstop).** Never silently reroute. The empty-constraint-list fail-open branch is mandatory. The raw-ID message at `:191` is replaced. | §3.4b, §3.4c, §3.6 |
| D7 | **One `@RepositoryEventHandler`** routing HAL writes through the same validator + audit writer. | §3.9. **Extended to `Sysprop`** — see 10.3 A1. |
| D8 | **One plan; 2732 owns the receiving-display contract; 2731 closes as a subset.** | §8.1. **Mechanism reduced:** no `receiving_dto_view` change is needed (§3.8) — see 10.3 A2. |
| D9 | **SUPERSEDED 2026-08-04 — two merges, one migration.** Originally four phases (1a-API / 1a-UI / 1b-API / 1b-UI) split on tier reachability, with the migration split in two and only the second carrying the operator gate. §5.2 collapsed the API phases into **Phase 1-API**, and D16 collapsed the migration into a single **`V2.2.13`** — which adds a mapped column, so **the one migration carries the gate**. Current shape: **Phase 1-API → Phase 2-UI**. Residual `1a`/`1b` labels in §0 and §4 are stale. | §5.2, §8.1, D16 |
| D10 | **A carrier receipt is never aborted by a putaway-config error.** The resolver runs on both branches, but `requireCompatible` is called only when `carrier == null`; on the carrier path an incompatibility is a WARN plus a `compatible="false"` metric tag, because the resolved destination is never applied there. | §3.7.1, §3.7.2 |
| D11 | **Count-and-confirm at merchant and warehouse scope, not an absolute reject.** Above zero incompatible SKUs the write returns 409 with the count; the caller re-issues with `confirmIncompatibleSkus=<n>`, which the writer **recomputes** and compares. 100 % incompatible, locked, fix-assigned and lane destinations are unconditional 422s. SKU scope stays an absolute reject. | §3.4c, §3.5a |
| D12 | **`DELETE` of the `DEFAULT_PUTAWAY_LOCATION` sysprop is accepted, not refused** — an absent row and a blank row are the same state to the resolver, so the delete can only move tier 3 in the safe direction. It is **audited** (`@HandleBeforeDelete` reads the previous value, `@HandleAfterDelete` records the clear), and §3.11.2 renders the control unconditionally so a delete cannot lock the tier out of the UI. | §3.9.1, §3.11.2 |

### 10.2 Adopted assumptions (routine calls, no genuine fork)

| Assumption | Adopted because |
|---|---|
| Merchant tier = `client.defaultputawaylocation_id bigint NULL REFERENCES location(id)` | one facility == one tenant DB, so "one value per merchant per warehouse" is satisfied structurally; typed FK > `sysvalue text`; avoids landmines A1/A3/A4/A5. §9 A1. |
| Warehouse tier = system-client sysprop `DEFAULT_PUTAWAY_LOCATION`, groupname `Operation Options`, seeded `''` | the Admin screen already renders that group generically via `GET /sysprop/search/findByGroupname` ⇒ the ticket's requested Admin path with zero new UI plumbing. Precedent `ReceivingService.java:428-431`. |
| Audit = a new narrow table, no Envers | Envers absent; Spring Data auditing captures timestamps only; the sole precedent is `CustomerorderCancellationLog` + `CancellationLogService`. §2.6. |
| Facility scoping needs no new dimension | no `warehouse`/`facility` table, no discriminator column on `location`; one DB per facility. §2.4. |
| Warehouse-tier value format = numeric `location.id` | agrees with tier 2's FK; survives renames; picker writes the id. Legibility restored via the sysprop `description` + the Phase-2 picker. |
| `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE` stays | it becomes the **tier-4 fallback constant** only; it stops being written as a seeded tier-1 value. |
| The resolver is wired at the receiving call-sites, never inside `transferUnitLoadToLocation` | that method has **24 call sites** across picking, palletizing, truck loading, transfers, on-hold and nirvana. §2.8. |

### 10.3 Deviations from the brief, with rationale (raise at review)

| # | Deviation | Rationale |
|---|---|---|
| A1 | **D7 extended to `Sysprop`**, not just `Itemdata` + `Client`. | The warehouse tier has the largest blast radius (§8.2) and `PUT /sysprop/{id}` is exactly what the existing generic admin dialog calls (`store/admin/configuration.js:73-93`). Guarding two of three holes leaves the worst one open. D7's own rationale already names `PATCH /v3/sysprop/{id}`. |
| A2 | **No `receiving_dto_view` / `ReceivingDtoView` change**, contrary to D8's presumed mechanism. | The view already projects `defaultputawaylocationname` (`V2.2.00...sql:4663, 4676` → `ReceivingDtoView.java:47, 173`). Precedence + compatibility are not expressible in that SQL, and a projected view column would couple the two forever (runtime read failure, not `ddl-auto=validate` — `ddl-auto` is `none`). D8's *substance* (2732 owns the display contract; 2731 not worked independently) is fully honored. §3.8, §9 A7. |
| A3 | **Receive-time validation is P1 only**, not the full suitability predicate. | Applying P2 at receive time would be *stricter* than `transferUnitLoadToLocation` and would reject receipts that work today — `PutAwayLane` itself sits in an area with `useforstorage = false`. §3.1.2. |
| A4 | **New `LocationConstraintService` method uses the existing list query**, not a new `existsBy...`. | Reproducing `UnitloadBusinessService.java:188-237` byte-for-byte is the point; an `exists` formulation needs two round-trips to express the same fail-open rule and invites drift. §3.4b. Excludes analysis-bundle site 29. |
| A5 | **Carrier path surfaces rather than forces** the resolved destination. | §9 A5. Flagged for business confirmation in Q1. |

### 10.4 Open questions

| # | Question | Blocking? | Recommendation |
|---|---|---|---|
| Q1 | On a **carrier** receipt with a non-tier-4 destination configured, should WMS surface-and-warn (this plan, D10) or hard-block the carrier receipt? | **No** — surface-and-warn is strictly less disruptive and can be tightened later. | Confirm with David Oppenheim during Phase 1 review. A hard block is a one-line change in §3.7.1 (drop the `carrier == null` guard around `requireCompatible`) if the business wants it. |
| ~~Q2~~ | Location count per facility — does a preloaded, client-side-filtered picker scale? | **CLOSED 2026-08-11 (r-next), and it splits by scope.** | **Measured, SELECT-only (§3.11.5a): `wms2-wineco-dev` 2,739 locations → 2,554 eligible at SKU scope but only **516** at merchant/warehouse; `wms2-hydra-dev2` 666 → 602 / **112**. So **this plan's two pickers do NOT cross the ~2,000 threshold** and need no search endpoint. **SKU scope does** — the remedy is handed to SBDEV-2643 Phase B2 as a paging/search parameter on **`/putawayConfig/eligibleLocations`**, NOT on `/location/detailView` (which would re-open §3.11 defect 1). Recorded as an explicit hand-off, not a silent cap. |
| Q3 | SBDEV-2643 scope: `skuData.vue:100-123` has its create/edit block **commented out**, so 2643 needs a SKU edit form built from scratch, not "add a field". | **No** — different ticket. | Re-estimate 2643 after Phase 1 lands; its backend is already done and now validated. |
| Q4 | Does `AdviceService.acceptHubAndSpokeAdvice` (`:145`) need the resolver? It materialises `Unitload` + `CustomerorderBatch` + `Customerorder` **without** going through `receiveGoods`. | **No** — excluded in §0.1 row 25. | Review after Phase 1 with a real hub-and-spoke advice on DEV. |
| Q5 | `ItemDataController.java:81` is a `@GetMapping` that mutates state. | **No** | Left as-is — the web UI calls it and changing the verb is a breaking API change. §8.4. |
| ~~Q7~~ | ~~**SBDEV-2731 is `in development` with no plan doc on disk.**~~ **CLOSED 2026-08-02 by D12/D14.** The 2731 plan exists and was inspected; ownership of `ReceivingService` destination resolution is now formally this plan's, and 2731 closes on its PR1 (display + neutral message). | **No longer blocking.** | See §10.2 D12/D14 and `SBDEV-2731-…md` §6. Superseded — do not re-investigate. |
| **Q10** | **Pick-face capacity (F3 / SBDEV-2731 Q5).** Should receiving deposit a full receipt into a pick face whose `upperbound` is 84? Nothing checks `FixLocationAssignment` bounds before `transferStockToUnitLoad`. D13 exempts tier 1, which is exactly the reported ICE PACK case (1,000 units). | **ANSWERED 2026-08-04 — no longer blocking, and the path it gated is DEFERRED (D15).** | **[SBDEV-2796](https://app.clickup.com/t/868kk4rmv): the B/A chose (c) — "valid, and bounds are advisory for receiving."** Not the recommendation (d). No capacity gate is built; the over-bound bin is an accepted, documented state; the tier-1 direct-placement block is lifted. **But (c) did not close two of that ticket's own ACs:** replenishment behaviour against a permanently over-bound bin is still undefined and awaiting a B/A answer (**new Q11**, owned by [SBDEV-2821](https://app.clickup.com/t/868km8j9z)), and **C2b** is neither resolved nor ruled out — it is now the binding gate on the surviving Fix B work (§5.2, §6). See the revision banner at the top and the §3.4c D13 note. |
| **Q12** | **May a tier-2/3 default target a *club* assembly lane?** D13 rule (a) permits `staginglane` wholesale and the ticket names "Club assembly lane" as a tier-2 scenario — but `getAvailableStagingLanes` (`LocationRepository:37-47`) allocates lanes to club batches **with no stock predicate**, so a receipt sitting on that lane can be shipped or cleared with the next batch (§6 **N-23**, verified 2026-08-04). Separately, lane stock is unconditionally invisible to replenishment sourcing (`StockunitRepository:198/:216`). | ~~**YES** — blocks the P2.7(a) wording and the Phase 2 location picker~~ **→ NO. CLOSED 2026-08-09 on the ticket owner's decision; nothing is blocked on it.** | **OPEN — needs the B/A, and RE-FRAMED 2026-08-06 by measurement: this question was asked about the wrong predicate.** Q12 assumes club lanes are reached through rule (a) (`staginglane` permitted wholesale). **On the real data they are not.** Verified SELECT-only on `wsl-wineco-uat`: `Club01`–`Club08` (ids 225748+) have **`staginglane = FALSE`** and every other lane flag FALSE; they sit in area 51553 *Storage and Picking* with **`useforpicking = TRUE`**, and `Club01` holds **114 unit loads / 27 distinct SKUs / 973 bottles**. They are **live multi-SKU pick faces**, not staging lanes. **Consequence: the ticket's named tier-2 use case — "Club assembly lane", "sending fast-turn club inventory directly to a designated club lane" — is, on this data, a request to point a merchant default at a PICK FACE. That is exactly what P2.7(c) forbids at all three scopes, and exactly what D15 defers to SBDEV-2821 for tier 1.** So the previously-proposed "safe answer" (narrow rule (a) to `crossdockinglane` + non-club staging) does not address wineco's clubs at all — they never passed through rule (a) — and with P2.7(c) now implementable they are blocked by rule (c) instead. **The real question is therefore: does this plan ship the club use case at all?** Three coherent answers: **(i)** no — P2.7(c) stands, the ticket's club scenario is out of scope for tiers 2/3 and belongs with SBDEV-2821's pick-face work; **(ii)** yes for clubs specifically — which needs the same resident-UL/Fix B machinery D15 deferred, i.e. it pulls SBDEV-2821 back into this plan; **(iii)** yes, but only onto *empty* club lanes (`Club08` is empty today), which needs a stock predicate that `getAvailableStagingLanes` does not have. **✅ ANSWERED 2026-08-08 — option (iv-b), split.** A fourth option emerged from SBDEV-2821's decision. **Configuration is widened at every tier — a pick face, club lane included, is a legal destination. Placement is split:** a **pick-face** destination is *not* placed at receipt (the receipt goes to the standard lane and putaway routes it, where `MobilePutAwayService.storeBoxOnLocation:497-514` already handles pick faces correctly); **every other** destination — staging, goods-in, cross-dock — is still placed directly at receipt, preserving the ticket's fast-turn intent that uniform (iv-a) would have dropped. **The club use case ships, no stock lands on a live pick face at receipt, and C2b stays unreachable.** Consequences: §5.2 **step 15 gains the `useforpicking` gate**; **step 17 survives, restricted to non-pick-face destinations**; P2.5 / P2.7(c) relaxed at all scopes; D13 re-framed from a configuration rule to a placement rule. §7.1's two conflicting tests resolve as: `merchantWritePermitsStagingLane` **passes**, `skuWriteRejectsPickFaceDestination` is **replaced** by `pickFaceDestinationIsNotPlacedAtReceipt` — the config is legal, the *placement* is what is refused. *Provenance: chosen by the ticket owner 2026-08-08 and **reaffirmed 2026-08-09 — Q12 is CLOSED, not pending.** It was put to the B/A on the ticket 2026-08-08 with no reply recorded; that is an outstanding **notification**, not an outstanding approval, and it does not gate the TDD gate or the implementation. Same pattern as SBDEV-2821's Q4, which was adopted on David Oppenheim's endorsement plus the ticket owner's direction — Brent Campbell never replied to that hand-off — and which shipped and merged 2026-08-09. If either objects later, Q12 reopens and (i)–(iii)/(iv-a) return to the table.* |
| **Q11** | **Replenishment against a permanently over-bound bin.** SBDEV-2796's answer (c) makes bounds advisory *for receiving* and makes over-bound bins reachable **and permanent** — but replenishment keys off those same bounds (`recalculateForItem` maintains orders from them). What should replenishment do when on-hand is ~12× `upperbound`? | **NO for this plan — DEFERRED with the tier-1 path (D15).** It is SBDEV-2796 AC *"Replenishment behaviour against an over-bound bin is defined, or over-bound bins are made unreachable"*, and (c) removed the second branch. **Why it cannot arise here — and note the reason is P2.5/P2.7(c), NOT the absence of placement code:** `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally, so nothing at receive time would stop an over-bound bin. What stops it is that **the configuration cannot be written** — P2.5 and P2.7(c) reject a pick-face or fix-assigned tier-1 destination at write time. If either predicate is ever relaxed without also answering this question, over-bound bins become reachable immediately. **⚠ BOTH PREDICATES WERE RELAXED 2026-08-08 (Q12 → iv-b) — the precondition held: the question was answered first, on 2026-08-06 ("advisory for replenishment"), so relaxing them is safe in the order it actually happened. Note also that under (iv-b) receiving no longer places onto a pick face at any tier, so the over-bound bin can now only be created by putaway, where `storeBoxOnLocation:497-514` merges into the resident UL — which is exactly what the "Caveat that travels to SBDEV-2821" requires.** ~~Blocks the tier-1 follow-up, not this plan.~~ | **ANSWERED 2026-08-06: "advisory for replenishment" too. Owned by [SBDEV-2821](https://app.clickup.com/t/868km8j9z).** Verified against the code, this costs **nothing to implement** — the bounds are never asserted as invariants, only used as comparison predicates: `FixLocationAssignmentRepository.getRefillFixedLocations:45` / `getRefillFixedLocationIds:72` gate on `stockunit.amount < fla.lowerbound`, so at 1,000 vs 36 **no replenishment order is ever created**; `ReplenishorderRepository.getIdsToCancelReplenishOrders:149` / `...Page:156-162` select `stockUnit.amount >= fixAssignment.upperbound`, so any open order is **cancelled** on the next sweep; `recalculateForItem` (`ReplenishmentOrderMaintenanceService.java:112`) iterates only `PROCESSABLE` orders and is a no-op for the SKU. **Caveat that travels to SBDEV-2821:** both cancel queries join `fixAssignment.assignedunitload_id = stockUnit.unitload_id` and so read the **resident** unit load only — if direct placement creates a *second* UL on the location, refill keeps firing and cancel never does, and the system replenishes a bin already holding 1,000 units. "Advisory" is correct **only if Fix B's resident-UL resolution is correct**. |
| Q8 | Has the history-less Hydra DEV copy been repaired, and `V2.2.13` applied to **every** DEV tenant, before the Phase 1-API merge? | **YES — blocks the Phase 1-API merge**, not the work, and not the Phase 2-UI merge. | §5.1 row 1, §8.1. DEV auto-deploys on push; the runtime migrator self-heals tenants that have Flyway history but **skips** those that do not, and `ddl-auto=none` means the failure is a per-request `42703`, not a failed boot. Pre-mortem P1. |
| Q9 | Should P2.4 admit a **pick-only** area (`useforpicking` with neither `useforgoodsin` nor `useforstorage`)? As written it does not, so a pick location can never be configured as a putaway destination and the picker does not offer one. | **No** — the narrow reading ships safely and can be widened later. | Keep P2.4 as written for Phase 1. Confirm with David Oppenheim whether receiving-direct-to-pick is a wanted workflow; if it is, widening P2.4 is a one-clause change **but §7.6 row 8's deadlock-retry prerequisite becomes hard**, because picking locks the same rows in the opposite order far more often than replenishment does. |

### 10.5 Closed questions (answered by the analysis lanes — do not re-investigate)

| Question | Answer |
|---|---|
| Is there v1 prior art to port from SBDEV-2642? | **No.** Zero commits in all five repos, no assignees, no attachments, closed 2026-07-25 ≈21 min *before* 2732 was created ⇒ superseded, not delivered. v1 `ReceivingService.java:521-523` is the same single-tier lookup and strictly worse. Jakarta-vs-javax is moot. |
| Unique index on `los_sysprop(client_id, syskey, workstation)`? | **Yes** — `uk8tcoe23qui9q3ancbhx662iqb`, `V2.2.00...sql:3600-3603`. |
| Can a sysprop row carry facility scope? | It does not need to — one DB per facility. §2.4. |
| Does the receiving screen's "source of setting" need a new API field? | **Yes**, derived server-side. The sentinel/precedence logic is far too subtle to re-implement in Vue. §3.8. |
| What constitutes a "putaway task" in v2, and what gets suppressed? | **Nothing.** There is no task entity; `MobilePutAwayService.calculatePutAwayList` (`:217-305`) derives suggestions on the fly from unit loads on the lane, so a directly-placed unit load simply never appears. §2.1. |
| Where does the invalid Ice Pack config come from? | `ItemDataController.java:88-90` raw `save()` with zero validation, and/or `PATCH /v3/itemdata/{id}`. `ItemdataService.setPutAwayLocation` has zero production callers and would not have validated anyway. §1. |
| (Q6) Does the `@HandleBeforeSave` previous-value read need `FlushModeType.COMMIT`? | **No.** With OSIV off the merged entity is **detached**, so there is no persistence context to auto-flush and the flush mode changes nothing. The plain native query returns the committed value. Do not set a flush mode and do not document one. §3.9.5. |

### 10.6 Pre-mortem — three ways this ships and still fails

**P1 — It ships and the application will not start (or SKU creation 23502s).**
`V2.2.13` is merged but not applied on some tenant. Because `ddl-auto` is **`none`**, the context starts normally — then every Hibernate read of `client` fails **`42703 column ... does not exist`**, per request, while liveness and readiness stay green. Or the stop-seeding code reaches a tenant where `V2.2.13` has not run and a new SKU insert hits `NOT NULL` on `putawaylocation_id`. **DEV auto-deploys on push, and although the app now runs Flyway at boot (SBDEV-2801) it SKIPS any tenant DB without `flyway_schema_history` — the Hydra DEV copy is exactly that** — so the ordinary merge workflow *is* still the failure path. **The original detector in this plan ("the app will not start") never fires; it was written against `ddl-auto=validate`, which this codebase does not use.** Detect instead with a per-tenant `information_schema.columns` check (§8.1) plus an alert on `42703` in the logs.
*Leading indicator:* startup `SchemaManagementException` naming `client.defaultputawaylocation_id`, or `POST /rest/sku` / CSV import returning `null value in column "putawaylocation_id" violates not-null constraint`.
*Mitigation:* §5.1 row 1 is a **hard blocker on merge 1, not on the work** — apply `V2.2.13` to every DEV tenant first, verified by reading `flyway_schema_history` (note: the Hydra dev copy has **no** `flyway_schema_history`; verify there by querying `los_sysprop` for the new key and `information_schema.columns` for the new column). §8.1 orders it explicitly. For the `23502` half, O3 keeps stop-seeding and `V2.2.13` in one commit and §8.1 merge 1 requires the operator to apply `V2.2.13` promptly after that merge. M1 + M2 are the first post-deploy checks.

**P2 — It ships completely and does nothing.**
Every tier-1 value still points at `PutAwayLane` (backfill skipped, or run blanket-and-reverted), or Phase 2 never lands so no operator can set a tier-2/3 value, or the sysprop stays `''` forever. Receiving behaves exactly as before, the code is all present, every test is green, and the two urgent siblings get closed against a feature nobody is using. **This is the most likely failure**, because every automated signal is green in this state.
*Leading indicator:* `wms2.putaway.resolution{source="STANDARD_PUTAWAY_LANE"}` ≈ 100 % of receipts two weeks after Phase 2, with `MERCHANT_OVERRIDE` + `WAREHOUSE_DEFAULT` still at **zero**. Corroborate in SQL: `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL` == 0, `SELECT count(*) FROM client WHERE defaultputawaylocation_id IS NOT NULL` == 0, `SELECT sysvalue FROM los_sysprop WHERE syskey='DEFAULT_PUTAWAY_LOCATION'` == `''`.
*Mitigation:* the scoped backfill ships **inside** `V2.2.13`, in Phase 1, so it cannot be forgotten separately and tiers 1/3/4 are genuinely live at the first merge; §3.13's `source` tag exists specifically to make inertness visible (there is no other way to see it); §8.1's third post-merge gate makes non-zero tier-2/3 usage a **condition for closing 2731 and 2643**, so the tickets cannot be closed against an inert feature.

**P3 — A single warehouse-tier write halts receiving for every merchant.**
An operator sets `DEFAULT_PUTAWAY_LOCATION` to a location incompatible with a common unit-load type, and write validation does not stop it — because the `@RepositoryEventHandler` was never actually registered (a `@Component` + `@RepositoryEventHandler` that Spring Data REST fails to pick up is **silent**; nothing logs, nothing throws), or because the write arrived on a path the handler cannot see: `POST /v3/systemProperty/create`, `POST /v3/systemProperty/updateValue`, or a `DELETE` (§3.9.1). Then §3.1.3's hard-fail backstop fires on **every** receipt for **every** merchant, and D6's "never silently reroute" turns a config typo into a warehouse-wide stoppage.
*Leading indicator:* `wms2.putaway.resolution.rejected{scope="WAREHOUSE"}` spikes from zero; simultaneously `/receiving/receive` starts returning 200-with-`errors` at a high rate (it never returns a 5xx, so an HTTP-status alert would miss it entirely).
*Mitigation, five layers:* (1) seeded `''`, so no tenant is exposed until someone writes; (2) **`PUT /putawayConfig/warehouse` is the only write path** — the two `SystemPropertyController` direct-save endpoints reject this syskey (§3.9.1), which closes the bypasses the handler structurally cannot see, and `DELETE` can only move the tier to "not configured" (D12); (3) the handler covers `PATCH /v3/sysprop/{id}` (deviation A1) and is proven wired by manual test **M9** — a 2xx there is a documented hard stop, and a **500** means the handler threw a checked exception (§3.9.7), because no code-shape grep can prove event-handler registration; (4) write-time P2.6 counts the tenant's incompatible SKUs and demands an explicit `confirmIncompatibleSkus` above zero, refuses outright at 100 %, and refuses a locked, fix-assigned or lane destination unconditionally (D11) — so a warehouse default that breaks *any* SKU cannot land silently; (5) `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigService` narrows who can do it at all (§3.12), with **M16a** proving the HAL channel is gated too.
*Kill path:* a **one-statement UPDATE to `''`**, which restores tier-4 behaviour for every merchant immediately. Blanking is stable because tier 3 reads through `SyspropRepository.findBySyskeyAndClientIdAndWorkstation` and never through `getStringDefault`, so nothing auto-recreates the value (landmine A1). Prefer the UPDATE over a DELETE: both stop the bleeding, but the UPDATE keeps the row — and therefore the audit subject and the admin-dialog entry — in place.

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh`

```bash
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
  bash sbdocs/9-System/scripts/verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh
```

Checks are grouped by phase so the output reads in rollout order. One POSITIVE check per §3 sub-section; a NEGATIVE check wherever new code replaces old — including all four seeding sites and the raw-concat throw at `UnitloadBusinessService.java:235`. `mvn_test_passes` rows cover the touched test classes (whole classes, never `Outer#method` — that silently no-ops on `@Nested`).

**Two template defects are fixed in this script, and both matter here:**

1. `PROJECT_ROOT` defaults to `/home/nampark/dev/wms-claude/v2/wms2-api` (the template ships a stale macOS path).
2. **`file_not_contains` FAILS OPEN on a missing file** — `grep` exits 2, and the leading `!` flips that to PASS. Every helper that can be handed a path gets `[ -f "$2" ] || return 1`, including the `perl -0777 -ne` multi-line helper: `perl` **exits 0 when it cannot open the file**, so every multi-line assertion about a not-yet-created file would false-green. Nine of this plan's new files are asserted with multi-line patterns, so without this fix roughly a third of the script would pass on an empty tree.

**A "N pass, 0 fail" result is meaningless until it has been replayed against the pre-change tree and observed to FAIL there.** SBDEV-2736 scored 57 pass / 0 fail on the very build that contained the defect the ticket was written to catch. Before accepting any implementation report:

```bash
git stash && bash sbdocs/9-System/scripts/verify-SBDEV-2732-....sh ; git stash pop
```

The negative-control run **must** show a large number of FAIL lines. If it shows 0 fail, the script is broken, not the implementation.

**Negative control, current baseline against the unmodified tree — now recorded PER PHASE (O4).** The
script takes `PHASE=1|2` (**not** `1a|1b` — those were never valid, and an unknown value now exits 2
rather than filtering every check and reporting a silent all-green); a whole-plan run can never reach
0 fail while later phases are unbuilt, so **each phase gates on its own subset**:

**Baseline re-measured 2026-08-07, POST-2731-MERGE** — api `6bc709a`, ui `4ce39a1`. This supersedes the
pre-merge record; it expires again when this plan's own Phase 1-API work starts landing.

| Run | Result | Evaluated / filtered |
|---|---|---|
| `PHASE=all` (default) | `15 pass, 167 fail, 1 skip` | 183 / 0 |
| `PHASE=1` | `12 pass, 161 fail, 1 skip` | 174 / 9 |
| `PHASE=2` | `10 pass, 7 fail, 1 skip` | 18 / 165 |

**Re-recorded again 2026-08-08 after the Q12 → (iv-b) script fixes.** Four checks were **removed** and eight
**added** (net +4 fail). The removed four asserted the *superseded* design and would have failed a correct
implementation: `V-fixloc` / `V-fixabs` demanded P2.5's absolute reject exist, and `T-skufix` / `T-merchfix`
demanded SKU- and merchant-scope writes *reject* a fix-assigned location. **Under (iv-b) all four assert the
opposite of the intent.** A gate encoding the old design is worse than no gate — it blocks the change it is
meant to guard. The pass count is unchanged at **15**, which is the signal that nothing went vacuous.

**Re-measured 2026-08-09 during Phase 1-API implementation** — base `fd90487` (post-SBDEV-2821 merge),
after the three unsatisfiable rows recorded in §12 were replaced:

| Run | Unmodified `fd90487` | Implemented (this branch) |
|---|---|---|
| `PHASE=1` | `12 pass, 164 fail, 1 skip, 9 filtered` | **`176 pass, 0 fail, 1 skip, 9 filtered`** |

The negative control was taken from a **detached worktree at `origin/develop`**, not from `git stash` —
stash only reverts the uncommitted delta, and by this point most of the work was already committed, so a
stashed run would have graded the implementation against itself and reported a meaningless near-green.

The 12 baseline passes are all *preservation* rows (`UBS-key`/`UBS-neg1`/`UBS-neg2` shipped with 2731 PR1;
`S3-pos1`/`S3-pos2`, `W-2102`, `W-onetx`, `E-col`, `E-lane` assert things that must not change), so the
count being >8 is expected here rather than a vacuity signal.

**Arithmetic self-check:** 174 + 18 = 192 = 183 + 9. **The overlap constant is now 9, not 11** — the 8
`phase all` preservation checks plus the **1** remaining SKIP. It was 11 when three checks were skipped;
`U-neg1` and `U-bind` were un-skipped on the merge (SBDEV-2731 owned them and now ships them), leaving
only the pre-existing `mvn` skip.

**What the merge flipped, and why each is right:**

| Check | Before | After | Why |
|---|---|---|---|
| `UBS-key`, `UBS-neg1`, `UBS-neg2`, `T-msg2` | FAIL | **PASS** | 2731 shipped the neutral key and removed the raw concatenations |
| `T-msg1` | FAIL | **PASS** | needed a second fix — see below |
| `U-neg1`, `U-bind` | SKIP | **PASS** | un-skipped; 2731 owned them and has now merged |
| `U-tristate` | FAIL | **PASS** | 2731's tri-state is present and this plan has not yet touched that block |
| `UBS-neg4`, `W-neg4` | FAIL | **FAIL** | correct — conjoined, and the resolver does not exist yet |

**`T-msg1` needed fixing twice, and the second reason is worth recording.** Scoping it to assertion
syntax (`hasMessageContaining(`) was not enough: 2731's merged test explains the removal in a comment
that **quotes the assertion verbatim** at `UnitloadBusinessServiceUnitTest.java:207` —
`// which pinned \`.hasMessageContaining("not allowed on location")\` — the raw,`. The check now strips
comment lines before matching. **A negative check must exclude the prose that describes what it forbids**,
or documentation of a fix reads as the defect. **The overlap constant is 9** — the 8
`phase all` preservation checks *plus the single remaining SKIP*, because `skip()` never calls `phase_selected()` and
so is never filtered. The previous derivation attributed the whole overlap to preservation checks and
silently dropped the skips. There are **3** SKIPs, and only **2** belong to SBDEV-2731 PR1 (`U-neg1`,
`U-bind`) — `U-source` was converted from skip to run on 2026-08-02 — plus the pre-existing `mvn` skip.

**Why 7 and not the previously recorded 8.** Three separate corrections landed on 2026-08-06 and they
move in opposite directions, so the net is not obvious:
- `UBS-neg4` and `W-neg4` were **vacuous** (bare `file_not_contains` for symbols that exist in zero
  files) and are now **conjoined**, so both correctly FAIL pre-implementation: **−2** from the old count
  of 9. §11.1 had already prescribed the conjoined form for `UBS-neg4`; the script shipped only half of it.
- The count had drifted 8 → 9 → (projected) 13 as prerequisites moved. After the conjoin it is the count
  of **real preservation checks** and stops drifting with every prerequisite merge. That stability is the
  point of the fix, not the number itself.
- All three phases now read the same 7, which is the strongest form of the invariant.
- **`U-tristate` (added 2026-08-06) fails today and should.** It asserts SBDEV-2731's tri-state comparison
  survives this plan's edits to the same template block, and the symbol does not exist on `develop` until
  #39 merges. It is a *post-prerequisite* preservation check: expect it to flip to PASS on the merge, and
  to stay PASS through Phase 2. If it is red *after* #39 lands, Phase 2 broke it.
pinned to every phase** (counted 3× instead of 1× ⇒ +16). That is why the preservation checks stay green in every phase
(the per-phase pass counts differ — 15 / 12 / 10 — because non-preservation checks bucket differently) — those checks must stay green *throughout* implementation, not merely at the end. If this
arithmetic stops holding, a phase marker was lost or a check crossed a section boundary.
**The ralph exit condition is `PHASE=<phase>` 0-fail, never whole-plan 0-fail.**

**Buckets are not purely sectional.** Section granularity alone is wrong in *both* directions, and **23**
checks carry a per-check phase override. Two shapes of error to watch for when assigning a new check:
- **under-covering** — e.g. `E-const`, the `WmsConstants` key **Phase 1 Step 4 ships**, belongs to the 1a
  bucket even though the constant is described in a §3.4a subsection a section-based split reads as 1b;
- **over-demanding** — `C-writers` (asserts *three* writers; 1a ships two), `C-evictcl` (the merchant
  cache) and `C-audit` (audit *rows*, deferred to 1b by O1) must **not** sit in the 1a bucket, or
  `PHASE=1` 0-fail becomes **unreachable** — precisely the failure O4 exists to prevent.

The sectional assignments are a first cut. Walk §5.2's step tables before treating any `PHASE=<phase>`
0-fail as a merge gate.

**The 7 pre-implementation passes are all deliberate preservation checks** and must stay green
*throughout* implementation, not merely at the end: `E-col` (the `@Column` survives the `@NotNull`
removal), `E-lane` (the tier-4 constant survives), `UBS-lock` (the SBDEV-2232 caller-holds-locks contract
comment survives), `S3-pos1`/`S3-pos2` (the SBDEV-2037 lane-presence guard survives), `W-onetx`
(`receiveGoods` stays one tenant transaction), `W-2102` (the SBDEV-2102 fix survives).

`W-neg4` is **no longer among them** — it asserted that the resolver is never wired into the
24-call-site `transferUnitLoadToLocation`, but as a bare negative against a symbol that exists nowhere
it was vacuous. Conjoined 2026-08-06, it now fails pre-implementation and passes only once
`putawayDestinationResolver.resolve(` is present in `ReceivingService` **and** absent from
`UnitloadBusinessService` — which is the property actually worth asserting.

**The pass-count tripwire.** Every check about code that does not exist yet must **fail closed** on the
unmodified tree, so the pre-implementation pass count must stay at exactly **15** (post-2731-merge; it was 7
before that merge). **If a pre-implementation run reports materially more than 15 passes, a check has gone
vacuous — find it before trusting the script.** Re-derive this from a measured run after every prerequisite
merge rather than trusting this paragraph; it has moved four times (8 → 9 → 7 → 15) and every move was real.
This number has moved three times (8 → 9 → 7) and each move was a real defect, not drift: re-derive it
from a measured run after every prerequisite merge rather than trusting this paragraph.
Three vacuity traps are already known and fixed; a new check must be checked against all three:

| Check | Why it was vacuous | Fix |
|---|---|---|
| `E-clientnull` | asserted the merchant field is not `@NotNull`, but the field does not exist in today's `Client.java`, so the pattern trivially failed to match | require the field to **exist** first |
| `U-bind` | asserted `putawayStaging` appears in the receiving form, but a dead `putawayStaging: null` property **already exists** at `receivingForm.vue:206` | require ≥ 2 occurrences |
| `W-nocgrd` | asserted the resolver call is *not* wrapped in `if (carrier == null)` — SBDEV-2731's literal root cause and the single most important behavioural guarantee here — but `putawayDestinationResolver.resolve(` does not exist yet, so "not guarded" was trivially true | **conjoin**: the symbol must be *present* before the negative is evaluated |

`W-nocgrd` surfaced only because the pass count moved from 8 to 9 — **the tripwire caught it, not review.**
`W-neg4` remains inherently vacuous pre-implementation (it asserts a not-yet-existing symbol is absent);
that is unavoidable for a "never wire X into Y" check and is why it is counted among the 8.

**Checks this revision adds that the script does not yet carry** — `check_N1_syspropctl_create_guard`,
`check_N1_syspropctl_updatevalue_guard`, `check_N1_sysprop_delete_handler`, an assertion that
`@PreAuthorize` appears in `PutawayConfigService.java` and **not** in
`PutawayConfigRepositoryEventHandler.java`, and an assertion that `putawayDestinationNotPermitted` appears
in `PutawayDestinationResolver.java` and **not** in `UnitloadBusinessService.java`.
~~**STATUS 2026-08-06: all of these are now IN the script**~~ — **FALSE, and it cost this plan three
unbuilt sites. Corrected 2026-08-09 by the Phase-3a conformance lane.** `grep -c` for the three
`check_N1_*` functions returned **0**: they were never added. Because nothing checked
`SystemPropertyController`, that file never entered the diff, and both of its direct-`save()` endpoints
were still writing tier 3 unvalidated and unaudited on a **176 pass, 0 fail** run. A status line
asserting coverage that does not exist is worse than an acknowledged gap — it stops anyone looking.
The three rows now exist (`N1-create`, `N1-update`, `N1-del`), plus `N1-d12` for D12's re-create
obligation. The conjoined `UBS-neg4` half of this claim was true.
The baseline table above has been re-recorded from measured runs; the pre-implementation pass count is
**7**, not 8. Re-run the negative control and re-record again after SBDEV-2731 PR1 merges.

### 11.1a Acceptance rows r-next adds — MANDATORY, and every one must be negative-controlled

> **STATUS 2026-08-11.** Seven rows were written and negative-controlled: `P2-eligible-endpoint`, `P2-eligible-scope`, `P2-eligible-lane`, `P2-eligible-neg-lbl`, `P2-eligible-h2` (all RED — deliverable 3 not built) and **`P2-br-7`, `P2-br-map` (GREEN)**. Both green rows were tightened after code review: the first form grepped bare constant names, which the fix's own javadoc spells out as prose, so documentation partially satisfied the row that verifies the code. They now anchor to the enum body and to `case "<key>":`, and were re-tested both ways.
>
> **Four rows deliberately still do not exist** — `P2-rules-pure`, `P2-validator-facade`, `P2-validator-tests-intact`, `P2-eligible-bulk` — because they gate the held deliverables. ⚠ **`P2-eligible-bulk`'s absence means nothing automated would catch a per-row `validate()` loop**, which is exactly why deliverable 3 was stopped by judgement rather than by a red row. The script names all four in a comment block rather than omitting them silently.

The rows below do not exist in the script yet. **`origin/develop` is the unimplemented tree, so it is the
negative control**: write each row, run it against `develop`, and confirm it FAILS before implementing.
Three failure modes have bitten this repo's verify scripts and all three apply here:

1. **`perl -0777 -ne` helpers fail OPEN on a missing file** (exit 0), so every multi-line assertion about a
   NEW file (`PutawayDestinationRules.java`, `LocationPicker.vue`) false-greens. Add `[ -f "$2" ] || return 1`
   to every helper.
2. **A row naming an undefined shell function records bash's 127 as a plain FAIL**, indistinguishable from
   unimplemented work. Audit for undefined / unwired / duplicate check functions.
3. **A "N pass, 0 fail" means nothing until the pre-fix tree is replayed and the rows go red.**

| id | Asserts |
|---|---|
| *(step C)* `P2-rules-pure` | ⚠ **and add an ArchUnit rule — a textual grep for absent imports cannot enforce purity, an ArchUnit rule can, and this repo already runs them.** `service/PutawayDestinationRules.java` exists and imports **no** repository and **no** Spring stereotype — the evaluator is pure (§3.11.0.1) |
| `P2-validator-facade` | `PutawayDestinationValidator` calls `PutawayDestinationRules.evaluate(` and no longer inlines the predicate chain |
| `P2-validator-tests-intact` | ⚠ **UNWRITABLE AS SPECIFIED — corrected 2026-08-11.** This row claimed `PutawayDestinationValidatorUnitTest` is *"byte-identical to `889298d`"*. **That file has never existed in any commit on any branch** (`git log --all --diff-filter=A` returns nothing), so there is no baseline to hold it against, and the plan named it as the extraction's guard in three places. Real coverage of the validator today is INDIRECT — `PutawayConfigServiceUnitTest` constructs a real validator over mocked repositories — and measured against the predicate chain it reaches **4 of 8 keys**: `putawayDestinationLocked`, `putawayDestinationAreaNotUsable`, the three `rejectIfTrue` lane flags and the P2.6 flowbin skip are all unexercised. **Replacement obligation: WRITE that test against the merged validator and merge it BEFORE deliverable 1**, covering all 8 keys plus multi-failure precedence, asserting `getKey()` AND `getMessage()` (only the latter would catch a dropped message argument). Then re-anchor this row to that commit. Also add an existence guard to the helper (`[ -f "$2" ]` then `return 1`) — the template's `perl -0777` form fails OPEN on a missing file, so as written this row would have gone GREEN while asserting nothing. |
| *(step A — REWRITE)* `P2-eligible-endpoint` | ⚠ **the five `P2-eligible-*` rows describe the SUPERSEDED unpaginated, controller-hosted endpoint and must be rewritten for §3.11.0.1**: the read lives on `PutawayDestinationQueryService`, takes a `Pageable`, and returns `Page<EligibleLocation>`. As written they would fail a correct step-A implementation. **New rows step A needs:** the read is on the query service not the controller; it accepts `Pageable`; ineligible rows are returned rather than filtered; the ordering clause is present. |
| ~~`P2-eligible-bulk`~~ | ⚠ **RETIRED 2026-08-11 — this row asserted the OPPOSITE of the resequenced design.** Under step A, per-row `validate()` over a bounded page is correct and deliberate (§3.11.0.1), so a row forbidding `validate(` in that path would fail a correct implementation. What step D needs instead is a **counted query-budget assertion** (§3.11.0.3) — a textual row cannot express "one constraint query instead of 8,800". |
| `P2-eligible-lane-excluded` | the tier-4 exclusion compares `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE`, never a hard-coded id and never the display label |
| `P2-eligible-h2` | **negative** — no `::bigint`, no `nullif(` in the new queries; JPQL with plain joins only (§7.7 row 6) |
| `P2-br-7` | `BlockingReason` has 7 values including `BOUND_TO_ANOTHER_SKU`, `AREA_NOT_USABLE`, `FLOWBIN_SCOPE`, `TYPE_INCOMPATIBLE` |
| `P2-br-map` | all six validator throw keys are mapped in `blockingReasonFor`; no **known** key falls to the `default: return null` arm (§3.11.0a) |
| `U-picker-source` | the picker's `items` come from a store action calling `/putawayConfig/eligibleLocations` |
| `U-neg-detailview` | **negative** — no picker, dialog or putaway store action references `/location/detailView` (§3.11 defect 1) |
| `U-neg-flags-in-js` | **negative** — no `.vue` or store file tests `useforgoodsin` / `useforstorage` / `staginglane` / `entity_lock` / `sltname`; predicates stay server-side (D3) |
| `U-picker-tier` | the two-tier split is driven by the server's `tier` field (`'ADVANCED'`), not a client-side flag test |
| `U-tristate` | **preservation** — `receivingForm.vue` still tests `=== false` (`:24`) and `isPutawayOverride` still ANDs on `=== true`. SBDEV-2731's `A10` / `T24` / `T25` stay green |
| `U-diverted` | `receivingForm.vue` consumes **both** `divertedTo` and `divertedReason`, on a line distinct from `putawayStaging` (§3.11.1). ⚠ Corrected 2026-08-11 — this row read "renders both", which the implementation does not and should not do: `divertedReason` is the sentence an operator reads, while `divertedTo` **gates** the block (`v-if="putawayDivertedTo && …"`) and is never printed. Naming the location twice in one alert is noise, and the copy already contains it via `%2$s`. The row asserts both are wired, not both are displayed. |
| `U-degraded` | on a FAILED destination read `receivingForm.vue` renders `#idPutawayUnconfirmed` instead of the `(SKU override)` qualifier, resets the flag before the `advicepositionid` guard, and does **not** set it on the empty-envelope path (review F3, 2026-08-12) |
| `U-degraded` (extended) | …and the destination read claims a `putawayRequestSeq` stamp, re-checked after **both** awaits, so a straggling response cannot repaint state (F3 review M1, 2026-08-12) |
| `P2-diverted-argorder` | the two args of `putawayDestinationDivertedToLane` are passed **lane-first, configured-second** at the `ReceivingController` call site, and `ReceivingControllerUnitTest` captures the real `Object[]` to pin it (wms2-api PR #148). ⚠ Added 2026-08-11 because a conformance lane **transposed those args and all 4927 API tests stayed green** — `ExceptionMessageService` is mocked with `anyString(), any(Object[].class)` and the only assertion was `divertedReason` non-empty. A transposition inverts the sentence: it tells the operator the stock was received to the pick face and will move to the lane. This row and that test are the only two things standing between that inversion and production. |
| `U-warehouse-typed` | the `DEFAULT_PUTAWAY_LOCATION` branch dispatches the **new typed** action; **negative** — it does not reuse `editParamAndConfig` / `addParamAndConfig` / the sysprop `$delete` |
| `U-neg-shipper-patch` | **negative** — `defaultputawaylocationId` never appears in `store/admin/shippers.js`'s `$patch` payload (§3.11.3) |
| `U-merchant-inherited` | the three-state control binds the envelope's `inherited` boolean; **negative** — no Vue-side comparison against `'MERCHANT_OVERRIDE'` |
| `U-persist` | the putaway config keys are in `persistedState.client.js`'s reducer exclusion (`:24`) |

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | **Large** | ~14 new files, ~18 modified, two Flyway migrations one of which carries a data backfill, two repos, cross-subsystem (receiving + SKU master data + admin config + Spring Data REST), and a hard deploy-order coupling on merge 1 |
| **Pre-draft step** | done — `analyst` + 3 analysis lanes + `planner` (ralplan, deliberate mode) | this document |
| **Plan-review step** | done — `architect` + `critic` | see §12 |
| **Implementation shape** | **`ralph`**, exit condition = `PHASE=<phase>` 0 fail from the verify script, **never whole-plan 0 fail** (O4) | 29 steps across four phases with ordering constraints (O1–O5) that a single `executor` pass will not respect |
| **Verification step** | verify script **+ `verifier`** (mandatory) | plus the §11.1 negative control, per phase |
| **Code-review step** | **`code-reviewer`**, fix every High/Medium | seven new beans, one Spring Data REST event handler, one new exception mapping |
| **Commit step** | **`git-master`** | Phase 1 is at least five logical commits, and the **first one is atomic by requirement**: `V2.2.13` + stop-seeding + fixtures together (O3). Then resolver + predicate + message keys, config service + controller + direct-save guards, event handler, receiving wiring + display endpoint |

---

## 12. Design Changelog

Substantive design changes since the initial draft, in the order they were settled. Everything above this
section states the **current** design directly; this is the only place the superseded alternatives are
recorded.

- **2026-08-11 — §3.11.0 RESEQUENCED after an independent design-review lane on the held deliverables. The
  extraction is no longer a prerequisite of the read, and the reason it appeared to be was a response-shape
  choice this plan never examined.** Two lanes, both opus: critic **SOUND-WITH-CHANGES** (extraction is right,
  wrong order, incomplete `Ctx`), architect **change the packaging and the sequence**. Neither disputed that a
  shared predicate is the correct seam — a narrow SQL restatement cannot express
  `isUnitloadTypePermitted`'s fail-open (the only reason club lanes pass) or the `sltname`-not-`useforpicking`
  keying, and `LocationRepository.getPutAwayCandidateLocations` is the in-repo proof, its own javadoc admitting
  it is *"deliberately STRICTER than the Java gate"* and merely *"agrees on today's data"*.
  - **ROOT CAUSE: the unpaginated contract.** "Return every location in the tenant" made per-row `validate()`
    expensive → made the extraction a prerequisite → put a read-only feature behind a rewrite of the write
    path. At page size 50 per-row `validate()` is ~50 calls, cheaper than the `GET /preview` already shipping.
    `api.paging.max-size=5000` and 12 controllers already take `Pageable`; the unpaginated `List` was the
    anomaly. **New order: A (paginated read, no live-code change) → B (write the guard) → C (extract) → D
    (fix `summariseScope`).**
  - ⚠ **`PutawayDestinationValidatorUnitTest` HAS NEVER EXISTED in any commit on any branch**, and this plan
    named it as step C's behaviour-preservation guard three times, including a verify row asserting
    byte-identity to `889298d`. Actual coverage is indirect and reaches **4 of 8 keys**: `locked`,
    `areaNotUsable`, all three `rejectIfTrue` lane flags, `crossdockinglane`, P2.7(e) at WAREHOUSE, the
    rule-(f) `isFlowbin` gate, the **P2.6 flowbin skip** (the ICE PACK case) and multi-failure precedence are
    all unexercised. Compounding: the row would have **failed OPEN** on the missing file. Step B now owns it.
  - ⚠ **`Ctx` was incomplete**: no `defaultUnitloadTypeId`, so the facade could not supply P2.6's second
    message argument; `String.format` raises, `BusinessException` **catches**, and the live 422 `detail`
    silently degrades. `getKey()` is unaffected — which is why every existing test, all of which assert
    `getKey()` deliberately, would have missed it. Now a 4th `evaluate` parameter. P2.1 stays in the facade.
  - ⚠ **The evaluation ORDER is the contract and was unstated.** Live order is not the P2.x numbering
    ((e) → (4) → (f) → (6), P2.6 last). **1,345 of 2,068 flowbins fail two or more predicates**, so which key
    wins is the majority path at SKU scope and is wire-visible through `blockingReason`. Now written down,
    with the chain to be modelled as an ordered predicate list so `evaluateAll` is addable later.
  - **Packaging changed:** `@Service` bean not `static` (ArchUnit pins purity better, and
    `PutawayDestinationResolver:59-65` already establishes the injected-metric pattern `static` would
    forbid); transaction boundary on `PutawayDestinationQueryService` not the controller (which is already
    the repo's only `@Transactional`-bearing controller, and `ClientController:64` still claims otherwise);
    `Verdict.args` as `List<Object>` not `Object[]` (array-identity `equals` would fail a correct impl —
    the third gate this plan would have written to fail correct code).
  - **Arithmetic corrected three ways:** "four lookups" understated, "6 lookups ≈ 16,400 queries"
    overstated; true max is **five** and the L1-corrected naive figure is **~8,200**. Same pattern as the
    six-vs-seven key miscount.
  - **New: the divergence rule** (§3.11.0.5) — *the shared evaluator may make the read more permissive than
    the write, never stricter*. A stricter reader hides a legal destination, which is a silent failure and is
    the direction the existing SQL restatement already got wrong.
  - **Acceptance changed:** `P2-eligible-bulk` **retired** (it asserted the opposite of step A, and would
    fail a correct implementation); the five `P2-eligible-*` rows must be **rewritten** for the paginated,
    query-service-hosted shape; step D's gate is a **counted query-budget assertion**, since no textual row
    can express "one constraint query instead of 8,800".

- **2026-08-11 — step C DONE (PR #145, `e9a8e7b`): the extraction, and mutation testing earned its
  keep.** Step B's 50 assertions passed untouched, which is the claim the refactor rests on — but
  **two mutations survived it**: removing the P2.6 flowbin skip (the ICE PACK case) and rule (f)
  direction 1's `isFlowbin` gate. Cause: the extraction put each behaviour behind TWO guards (the
  facade short-circuits `unitloadTypePermitted` for a flowbin, and only LOADS
  `flaItemdataIdForLocation` for one), so a facade-built `Ctx` can never exercise the rules-level
  check. **Behaviour was preserved; the new seam was untested, and "50/50 still pass" would have
  looked like proof.** Closed by a direct evaluator suite (13 tests, no mocks). Lesson worth
  keeping: a refactor that adds a seam needs tests AT the seam, and only mutation testing shows it.
  - The facade's laziness is load-bearing: eager `Ctx` construction would 500 on a null `area_id`
    under the lane exemption, and would re-add the two FLA queries per call that **step D had just
    removed**. An extraction that silently undoes the previous step is the failure mode here.
  - The redesigned key derivation caught **dead code the refactor left behind** — an orphaned
    `rejectIfTrue` with 0 callers still holding a literal key.
  - ⚠ **Fourth prose-vs-code trap in the verify script:** `P2C-pure` false-FAILED correct code
    because the class's own javadoc says "no `@Transactional`". Any row asserting the ABSENCE of a
    symbol must strip comments — now standard via `code_only`.
  - ⚠⚠ **AND THE STEP WAS REPORTED GREEN WHEN IT WAS NOT.** The commit message, PR #145's body and the
    ClickUp comment all recorded `PHASE=1 220 pass / 0 fail`. The actual line read **220 pass, 6
    fail** — and the six were **misattributed to the `U-*` UI rows, which `PHASE=1` filters out**, so
    the number was rationalised instead of read. The failures were real but were the script's fault,
    not the code's: `V-goodsin`, `V-storage`, `V-lanes`, `V-noflowbin23`, `V-lock` and `V-p1skip` all
    grepped `$VALIDATOR` for predicates step C had just moved into `$RULES`. **A refactor that moves
    code between files invalidates every verify row pinned to the old file, and those rows go red in
    the same run that proves the refactor worked** — which is exactly when a "behaviour-preserving"
    framing makes them easy to dismiss. Fixed 2026-08-11: five rows now search the whole chain
    (facade OR evaluator, via new `chain_contains` helpers), and `V-lanes` is pinned to `$RULES`
    deliberately, because `getStaginglane` is the one predicate legitimately in BOTH files (the facade
    reads it to decide whether to load the area) so a chain-level check could not detect its removal
    from the evaluator. `V-lanes` also now asserts **all four** lane flags; the old proximity regex
    named only two and its `{0,400}` window silently encoded "these sit in one block" — an assumption
    step C ended. Merged develop: **`PHASE=1` 226 pass / 0 fail**.
- **2026-08-12 — INDEPENDENT REVIEW OF PR #50 (two lanes again). Both PASS, no High, no Medium.**
  Follow-ups in wms2-web-ui PR #51 (`01e8d8a`), **MERGED 2026-08-12 (merge `488102c`)**. The value this round was almost entirely in the GATES, not the code.
  - **My suspected token hole was real mechanically and unreachable in production.** I flagged that the
    stamp was claimed BELOW the `positionId` guard, so a call returning at that guard never bumped the
    counter and an in-flight earlier read could repaint. The reviewer proved the mechanism with a probe
    (shadowing the `itemToReceive` computed) and then proved it unreachable: `itemToReceive` has exactly
    **one** writer, `openNoticeTable.vue:274`, which commits BEFORE the `:276` route push while the form
    is unmounted; there is no `<keep-alive>` anywhere; and the `setItemToReceive, null` that would empty
    it in place is commented out at `:267`. Hoisted the claim above the guard anyway — one line, closes
    the shape, and makes the data-block comment's claim ("closes that door") actually true.
  - **A diagnosability regression I introduced.** The token guard was placed ABOVE the `console.error`,
    so a stale failed read was logged **nowhere** — someone investigating intermittently wrong
    destinations would open the console and find nothing, because the read that failed was the stale one.
    Only the STATE is stale; the failure is always real. Log first, then guard. No test constrained it.
  - **`U-degraded` was defeated 4 MORE ways** after the trailing-comment fix: a `://`-form comment, JS
    string literals, a template literal, and a hidden `<template>` text node. I closed the comment channel
    (`(?<!\w:)` — and note the lane's suggested `(?<![:\w])` does NOT close it, since `:` is exactly what
    that lookbehind skips; measured both). The two STRING channels remain open and **no comment-stripper
    can ever close them**, so `vue_code_only`'s header now says plainly that the row's teeth come from
    Jest and these regexes are a cheap cross-check only. That is the honest fix; a tenth clever regex
    would not have been.
  - Also fixed in the row: the empty-envelope negative was `[^\n]`, i.e. **same-line only**, so the
    braced multi-line form a developer would actually write passed it; the stamp clause allowed 600 chars
    between the two rechecks against an actual 467, so ~130 characters of added code would have turned it
    red on a correct implementation (the stale-row trap this plan already records); and `vue_code_only`'s
    block-comment strip false-FAILed correct code if any string contained an unbalanced `/*`
    (`globPattern: '/*'` deleted ~180 lines) — now guarded, and verified to stay PASS.
  - **The wrong-test citation had a FIFTH site** — the verify script's own `U-degraded` header, the file
    that grades the fix. Corrected. And the correction to it in the plan carried an off-by-two on the very
    line it nominates as the tightest anchor.
  - **D11 is the only coverage of the WARNING block's tri-state**, incidentally, because it omits
    `noContainer`. Its name says nothing about that, so tidying its setup would silently delete the last
    gate on that state — the same hole the unconfirmed block had until D31. Comment added telling future
    editors not to.
  - The copy's advice half ("if it keeps happening, report it") was asserted by **nothing** — deleting it
    left 44/44 green. Now pinned in D24.
  - Both lanes independently re-measured every falsifiable claim in this plan's §12 and confirmed them
    exactly, including "passed ALL 40 tests" (they rolled the component back to `e702a42` to check) and
    "fails 6, D23 among them" (exactly 6: D6, D7, D8, D10, D14, D23).
  - **Post-merge verification on `origin/develop`**, fresh detached checkouts of both repos: Jest
    **250 passed / 250** across 26 green suites, verify **287 pass / 0 fail / 1 skip**, ancestry confirmed.
    Four regressions replayed against the SHIPPED code, each caught by its own test: notice gate
    `=== true` → **D31**, catch-path staleness guard removed → **D33**, success-path guard removed →
    **D34**, the copy's advice half deleted → **D24** (uncovered before #51). Also confirmed the L1 hoist
    is present: the stamp claim is at `:641`, the `positionId` guard at `:643-644`.
  - ⚠ **`test/NuxtLogo.spec.js` is red and always has been.** It imports `components/NuxtLogo.vue`, which
    has **never existed** (0 commits, ever); the spec dates from `3462148 initial check in the code`
    (2024-07-16). Every "26 suites" figure in this plan was taken with `--testPathIgnorePatterns=NuxtLogo`
    and read as "all suites". It is 26 green of **27**. Unrelated to this ticket, and now filed as
    **SBDEV-2931** — it makes every unfiltered `yarn test` in this repo exit non-zero, which trains
    everyone to filter and to read a red suite as normal. That habit is exactly how a real failure hides.
- **2026-08-12 — INDEPENDENT REVIEW OF PR #49 (two lanes, conformance + code review). Verdict PASS with
  2 Medium; follow-ups in wms2-web-ui PR #50.** Nothing shipped was wrong; the gaps were in what the
  gates could SEE.
  - ⚠ **My own race finding was WRONG in its harmful half, and the correction matters.** I reported that
    a straggling response could paint a PREVIOUS position's destination onto the current line. It cannot:
    selecting a line is a route change (`openNoticeTable.vue:274-276` →
    `pages/receiving/openNotice/receive.vue:14`), so the form REMOUNTS and `advicepositionid` cannot
    change under a live instance. My test proved a race by calling the method twice on one instance,
    which production reaches only WITHIN one position.
  - **M1 (Medium) — the same-mount overlap is real.** `mounted()` does not await `updateQuantities()`,
    and every `receive()` re-runs it, so two reads overlap; the flag was cleared only at call entry and
    never set false on success. A straggling FAILURE therefore landed on a newer SUCCESS and rendered
    `#idPutawayUnconfirmed` **beside a live `#idPutawayDiverted`** — "any putaway re-route could not be
    checked" next to a re-route notice proving one was. Two contradictory warnings, and the rational
    operator distrusts the load-bearing one. Both orderings over-warn (the entry reset precedes the
    await, so a failure can never be masked), which is why it is Medium not High. Fixed with a
    `putawayRequestSeq` stamp re-checked after BOTH awaits — D33/D34.
  - **M2 (Medium) — the new notice's `null` tri-state had no test, and the gap was exploitable.**
    Substituting its gate `!== false` → `=== true` **passed all 40 tests**; the identical substitution on
    the diversion block fails 6, including D23 which exists for exactly this. On a non-mandating tenant
    first paint is `applied === null`, so a later "tidy" would have silently removed the notice from the
    most common operator view — the very tri-state mistake the template comment warns about. I verified
    both halves of that asymmetry myself before fixing. D31 is the D23 analogue.
  - **`U-degraded` was prose-satisfiable, in a way `vue_code_only` was built to prevent.** It stripped
    whole-line comments only, so a TRAILING `//` note on a code line survived: the pre-fix file plus six
    `const X = 1 // <token>` lines scored the row GREEN with zero F3 code. The **ninth** instance of this
    trap in this script and the first to defeat the mitigation written for the eighth. `vue_code_only`
    now strips trailing comments too, with a `(?<!:)` lookbehind so it does not eat `https://`. Replayed
    the exploit after the fix: variants A/B/C all FAIL, the real file PASSes.
  - The row's ordering clause was also **adjacency, not order** — `advicepositionid` occurs 5× and the
    regex only proved the reset sat next to one of them. Now anchored on the method with both landmarks
    in sequence, and the request token is pinned too.
  - **L1 — the "would flip T24/T25" rationale named the wrong tests in four places** (component
    docblock, D29's title and body, plan §12), and the spec contradicted itself: its item-2 header said
    correctly that T24/T25 stay green, 167 lines above a comment asserting the opposite. Measured: the
    mutation breaks **T19 + T22 + D29**; T22 (`receivingForm.spec.js:221`,
    `toBe('ICE PACK (SKU override)')`) is the real anchor — `:219` is that test's `mountForm(...)` call, an
    off-by-two the PR #50 review caught **in the correction itself**, on the one citation nominated as
    "the tightest anchor". The constraint was always real — the citation
    a reader would check to confirm it was not. On a change whose point is that the screen stops
    asserting what it cannot support, that is the same defect class one level up.
  - **L2** — two comments still described `putawaySource === null` as "the DEGRADED path", which F3's own
    guard had just excluded; narrowed to "seeded/in-flight (and the empty envelope)". **L4** — D26 claimed
    a discriminating pair but asserted only the benign half; the failed-read-no-seed half was
    *unreachable* through `mountForm`, whose DTO mock always seeded a value. Added a `seed` parameter and
    D32. **L3** — the copy now says "if it keeps happening, report it", because
    `describeForAdvicePosition` can fail permanently (`orElseThrow(entityNotFoundForId)`), against which
    retrying is futile.
  - Both lanes independently confirmed the DESIGN. The code reviewer added an argument I had not made:
    blanking the field would not withhold an answer, it would **manufacture** one, because
    `putawayDisplay` maps a blank to "Put Away Lane" — indistinguishable from a successful tier-4 read,
    and the one answer an operator is least likely to double-check.
  - Suite **250 passed / 250, 26 green suites of 27**; verify **287 pass / 0 fail / 1 skip**. Four new mutations, each
    caught by exactly the one test written for it — notice-gate→**D31**, catch-recheck→**D33**, success-recheck→**D34**, seed-suppression→**D32**. ⚠ These were labelled M2/M11/M12/M13 until the PR #50 review pointed out that **M11/M12/M13 collide with §5.1's manual DEV rows** of the same names in this very document, and that the F3 numbers were never defined anywhere — a reader could not check the mapping as written. Named by what they mutate instead.
  - **MERGED 2026-08-12 as wms2-web-ui PR #50 (`b62f5ba`, merge `4a8a0e0`).** Re-verified on merged
    `origin/develop` from fresh detached checkouts of both repos: Jest 250/250 across 26 GREEN suites (27 total — see the NuxtLogo note), verify
    287 pass / 0 fail / 1 skip, ancestry confirmed. The two Medium mutations were **replayed against the
    shipped code**, not only against the branch: `=== true` on the notice gate is caught by D31, and
    removing the stale-failure guard by D33. A green suite proves the tests pass; replaying the
    mutation on `develop` is what proves the gap is actually closed where it matters.
- **2026-08-12 — REVIEW F3 RESOLVED. Nam chose the recommended option (keep the value, strip the
  certainty) over both a toast and blanking the field.** wms2-web-ui PR #49 (`f6c4ad9`), **MERGED 2026-08-12 (merge `e702a42`)**.
  - `D19` **inverted**. It asserted that the degraded path correctly labels the value a SKU override,
    reasoning that the seed is tier 1 by construction — which is TRUE and insufficient. Being right about
    the TIER is not being right about the DESTINATION: the same failed read also cost the (iv-b)
    diversion check. Its old justification cited T24/T25, but those never reach the catch — their mock
    falls through to `Promise.resolve(null)`, the empty-envelope early return. `D29` now pins that
    boundary and T24/T25 stayed green untouched.
  - Added `D24`–`D30` and the `U-degraded` verify row. 7 mutations, each caught by a distinct test:
    flag never set (D19/D24/D27/D28), guard removed (D19), notice never renders (D24/D28), tri-state gate
    dropped (D27), flag not reset between positions (D28), empty envelope treated as failure (D29),
    resets moved back below the guard (D30). Verify row separately negative-tested on 6 mutations.
  - ⚠ **Found while writing D30: a THIRD early-return path leaked state.** The resets sat below the
    `advicepositionid` guard, so selecting a position without one kept the previous line's diversion
    notice on screen. D14/D15 were written for the reject and empty-envelope returns and named them
    explicitly; nobody enumerated the guard above them. Fixed by making the reset unconditional.
  - ⚠ **Two test-harness traps cost two false results before the suite went green.** VTU's `setData`
    deep-MERGES plain objects, so re-setting `noticePosition` to an equal-but-new object never changes the
    reference and the non-deep watcher does not fire — the position switch silently did not happen. And
    `itemToReceive` is read through a computed over the NON-reactive mock store, so mutating
    `$store.state...itemToReceive` mid-test cannot change `positionId`. D10's idiom (`$axios.$get
    .mockImplementation` + calling `loadPutawayDestination()` directly) is the only reliable lever, and
    both rewritten tests now use it.
  - Suite **246 passed / 246 total, 26 suites**; verify **287 pass / 0 fail / 1 skip**.
  - **Re-verified on merged `origin/develop`** from fresh detached checkouts of BOTH repos (not the
    implementation worktree): Jest 246/246 across 26 suites, verify 287 pass / 0 fail / 1 skip,
    `merge-base --is-ancestor e702a42 origin/develop` confirmed.
- **2026-08-11 — THE REVIEW LANE ON PR #47 FOUND A COPY DEFECT NO GATE COULD SEE, AND IT IS THE ONLY
  FINDING IN THIS TICKET THAT WOULD HAVE HARMED AN OPERATOR SILENTLY.** Closed by wms2-api PR #148
  (`049d15b`), **MERGED (merge `bcfdc47`)**.
  - The lane **transposed the two args of `putawayDestinationDivertedToLane` and the whole API suite
    stayed green — 4927 tests, zero failures.** Transposed, the sentence reads *"Received to ICE PACK.
    Putaway will move it to Put Away Lane — the stock is not on Put Away Lane until then"*: it names the
    pick face as where the stock IS and the lane as where it is GOING, the exact inversion of the truth,
    on the one screen this ticket exists to make truthful. Same defect class as SBDEV-2731.
  - **Why two good tests both missed it.** `ReceivingControllerUnitTest` mocks `ExceptionMessageService`
    with `anyString(), any(Object[].class)` and asserted only `divertedReason` non-empty;
    `DiversionCopyUnitTest` asserts the BUNDLE, not the controller, because the ResourceBundle parent
    chain makes child-file deletion invisible to any other approach. Each is correct alone. **The gap
    was the join between them, and no verify row covered it either** — so the fix is both an
    `ArgumentCaptor<Object[]>` assertion and the new `P2-diverted-argorder` row.
  - Row negative-tested against five mutations: controller args transposed **FAIL**, test expectation
    transposed **FAIL**, `laneLabel()` bypassed so raw `PutAwayLane` leaks **FAIL**, assertion weakened
    back to `isNotEmpty()` (the original gap) **FAIL**, captor local renamed consistently **PASS**.
  - ⚠ **Ninth prose-satisfiable-grep trap in this script.** The call site now carries a comment reading
    *"%1$s is where the stock LANDS, %2$s is what was CONFIGURED"* — a comment-blind grep is satisfied
    by that prose with the code transposed underneath. The row uses `code_contains_ml`. A first draft
    also matched `\bargs\.capture\(\)` and would have gone red on a correct variable rename; the row is
    now name-independent, since the load-bearing assertion is the expectation ORDER.
  - ⚠ **Shadow-root recipe correction.** `wms-plan-executor` describes a monorepo symlink tree, but
    **this script takes `PROJECT_ROOT` as the wms2-api repo root itself** (`:117`) plus a separate
    `UI_ROOT` (`:118`). Pointing it at a monorepo shadow scored **4 pass / 282 fail** — a result that
    looks like catastrophic regression and is purely harness misconfiguration.
  - Also removed a dead ternary arm at `ReceivingController:139`: `r.location() == null ? "the
    configured destination" : …` is unreachable because `PutawayDisplay.diverted()` already requires a
    resolved configured location. It read as a defensive guard while being a second, silent copy variant
    no test could reach.
  - **Post-merge verification on `origin/develop` for BOTH repos** (fresh detached checkouts, not my
    worktrees): verify **286 pass / 0 fail / 1 skip** (`PHASE=all`, was 285/0 — this row is the +1);
    web-ui Jest **239 passed / 239 total, 26 suites**; API `ReceivingControllerUnitTest` +
    `DiversionCopyUnitTest` green. Merge ancestry confirmed with `merge-base --is-ancestor` in both.
- **2026-08-12 — POST-MERGE REVIEW OF STEP 19a FOUND 2 HIGH DEFECTS, both mine, both the same mistake:
  the step widened what a field MEANS and left consumers encoding the old meaning.** Fixed in
  wms2-web-ui PR #48 (`c46823a`), **MERGED 2026-08-11 (merge `2884085`)**.
  - ⚠ **F1 — `(SKU override)` rendered for tiers 2 AND 3.** `isPutawayOverride` was "name set AND name
    != PutAwayLane AND applied", which **was** sound while `putawayStaging` came from
    `receiving_dto_view.defaultputawaylocationname` — a TIER-1-ONLY column, so a non-lane name was a SKU
    override by construction. Step 19a re-sourced the field from the FOUR-tier resolver and left the
    qualifier untouched. Reproduced: **"BULK-01 (SKU override) Warehouse default"**, and
    **"ICE PACK (SKU override) SKU override"** with the tier stated twice. The line self-contradicts and
    answers "why is this SKU going here" with the wrong tier.
    **This is the "re-source, don't re-shape" hazard §3.11.1 warned about, landing on a CONSUMER rather
    than on the assignment — the warning was read as being about the assignment only.** It was also,
    strictly, the Vue-side precedence derivation item 2 forbids: a location-NAME comparison standing in
    for the source tier. `D5` missed it because it grepped for quoted enum names and this derivation
    contains none.
  - ⚠ **F2 — the diversion contradicted "(not used — receiving to container)".** The destination is
    honoured IFF the operator opted out of a container, but the diversion was gated only on
    `divertedTo`, so on the container path both rendered — and both halves of the diversion sentence are
    false there. **On a tenant with `REQUIRE_RECEIVING_TO_CONTAINER=true` the tri-state is `false` for
    EVERY receipt, so the contradiction is permanent, not transient.** `warning` had the identical gap.
    Gated on `!== false`, never a truthy test, because `null` means "not chosen yet" and the destination
    may still apply — the same tri-state mistake SBDEV-2731's review round already fixed once.
  - ⚠ **F3 (MEDIUM) is NOT fixed and needs a product decision:** the silent catch leaves the configured
    pick face on screen with no diversion line and no tier label — **byte-identical to the pre-SBDEV-2731
    lie, on the one screen this ticket exists to make truthful.** `console.error` is invisible in a
    warehouse, so a per-tenant outage is indefinite and silent. "Degraded, not blank" is the right
    instinct; the flaw is that the degraded state ASSERTS something it could not verify. `D3` pins the
    current behaviour deliberately.
  - **My suspicion about an out-of-order response race was WRONG, and the lane's reasoning is better than
    mine:** `itemToReceive` is committed in exactly one place, immediately followed by a route change, so
    the component is destroyed rather than reused and the two calls that can overlap carry identical
    ids. Real as a mechanism, unreachable on this screen — and live the moment anyone adds in-place
    position navigation.
  - **Three more of my own tests were weaker than they read:** the fixture reused the location name as
    the SKU's item number, so `wrapper.text()` matched it from the CARD TITLE — defeating scoping for
    the whole file, which the preserved SBDEV-2731 spec's own header explicitly warns about; `D5` was
    quote-form dependent; `D8`'s "distinct element" claim was narrower than it reads. Fixed.

- **2026-08-11 — STEP 19a MERGED, in the required order: wms2-api #147 (merge `509be61`) then
  wms2-web-ui #47 (merge `83c6e97`).** The API first, because the wording resolves server-side.
  Verified on merged develop rather than on the branches: the key is present in BOTH bundle files, the
  old hardcoded literal is gone (0 occurrences), `loadPutawayDestination` / `idPutawayDiverted` /
  `putawaySourceLabel` are all live, and **SBDEV-2731's `isPutawayDestinationApplied === false`
  survived** — the preservation §3.11.1 demanded. Web suite 231 passed / 0 failed; API targeted 47 / 0.
  Two DEV deploys fired.
  - **`verify PHASE=all` — 285 pass, 0 fail, 0 stderr, against merged develop in both repos.** Every
    row this plan ever specified is now green, including the eight §11.1a rows that had existed only in
    the acceptance table.

- **2026-08-11 — STEP 19a IS BUILT, and the copy blocker was dissolved rather than waited on.**
  wms2-web-ui PR #47 (`eed9e2a`) + wms2-api PR #147 (`6cc86d5`); **#147 merges first.**
  - **The blocker was the WORDING, not the code** — and the API half was already merged and verified
    (`sourceLabel:106`, `divertedTo:117`, `divertedReason:118`, `warning:123`), so nothing server-side
    was outstanding. Copy is **variant A, chosen by Nam**: *"Received to %1$s. Putaway will move it to
    %2$s — the stock is not on %2$s until then."* It satisfies both halves SBDEV-2643 D1 requires:
    routed VIA PUTAWAY rather than placed, and the CONSEQUENCE.
  - ⚠ **AN UNREVIEWED OPERATOR-FACING SENTENCE WAS ALREADY SHIPPING.** `ReceivingController:118`
    carried a hardcoded literal — *"configured destination is a pick face; putaway will route it"* —
    on merged develop and deployed to DEV. Had step 19a rendered `divertedReason` verbatim, that
    developer-written sentence would silently have BECOME the operator-facing copy. It was also the
    only operator-facing string this ticket added that was NOT a message key, so it could not be
    localised and every wording tweak needed a Java change and a deploy. Now
    `putawayDestinationDivertedToLane` in both bundle files, resolved through the existing
    `ExceptionMessageService`. **Generalisable: "needs product sign-off" is not a reason to leave the
    string in Java — move it to the bundle FIRST and the decision stops blocking the build.**
  - A first draft also added a `divertedToLabel` envelope field mirroring `source`/`sourceLabel`.
    **Removed before merge**: the resolved sentence already contains the label and the only consumer
    gates on `divertedTo`, so it was envelope surface with no reader.
  - ⚠ **Mutation testing found a gap two of my own tests structurally could not reach.** Deleting the
    per-position reset SURVIVED, because on the normal path the assignments at the end of
    `loadPutawayDestination()` clear the fields anyway. The reset only matters on the EARLY-RETURN
    paths — a rejected request or an empty envelope — and that is the worse case: the operator is still
    told the stock is going elsewhere, about a position we could not even read. `D14`/`D15` drive it.
  - **`verify PHASE=all` is 285 pass / 0 fail — the entire script green for the first time**, including
    `U-diverted`, which §11.1a named and which existed nowhere in the script until today.

- **2026-08-11 — checked whether wms2-mobile-ui needed the same fixes. MOSTLY NO, and the one that
  applied exposed a gap in my own web fix.**
  - **Not applicable to mobile:** no putaway-config surface at all (zero references to
    `defaultputawaylocation` / `DEFAULT_PUTAWAY_LOCATION` / `LocationPicker` / `eligibleLocations` /
    `putawayConfig`), no `admin` store module, and although the façade exposes `hasResourceRole`
    **nothing calls it** — so the non-reactive-gate defect, H2, M1-M4 and config health cannot exist
    there. Steps 19-22 are admin screens; mobile is scanning workflows.
  - **Applicable: the logout blob-clear** — wms2-mobile-ui PR #31 (`5439c49`), MERGED, merge `2e5a995`. `vuex-mobile`
    appeared in exactly ONE place in that repo — where it is created — and was never removed.
  - ⚠ **The rationale differs, and that is the interesting part.** Mobile's blob holds NO credentials
    (no `admin` module), so it is not a secrets problem there; the exposure is OPERATIONAL, and worse
    on that app because handhelds are SHARED BETWEEN SHIFTS. Every workflow module persists a
    `process` step marker plus its working set, and **five of ten workflow pages reset nothing on
    entry** (cancellation, cycle-count, move-stock, move-unitload, transfer-order). `putaway.vue`
    already carries a `created()` reset with a comment about stale persisted state breaking a
    sub-screen — the same bug, patched one page at a time. **Filed as SBDEV-2930**, not folded in: it
    needs five workflow screens touched.
  - ⚠⚠ **AND CHECKING MOBILE EXPOSED A THIRD EXIT MY WEB FIX HAD MISSED.** Mobile has the same
    `onAuthLogout` handler — Keycloak reporting the session ended without going through our own logout
    (an SSO logout in another tab, or a back-channel logout). It cleared the token and left the blob.
    I had covered the two exits I happened to look at, **which is exactly the failure mode that fix's
    own commit message warns about.** Corrected in wms2-web-ui #46 (`5953925`, L8 added) as well as in
    mobile. It is reached WITHOUT the user touching the app, so it is the longest-lived of the three
    cases, not the most obscure. **Generalisable: "I covered both exits" is a countable claim — go
    count them, in every app that shares the pattern.**

- **2026-08-11 — the two review follow-ups are now FIXED, not just filed.**
  - **`vuex-web` is cleared on logout** — wms2-web-ui PR #46 (`469715e` + `5953925`), MERGED, merge `aac55d4`. Logout removed only
    `kcToken`, so the whole persisted root state survived for the next user of a shared warehouse
    browser profile — and that blob carried `CUPS_SERVER_ADDRESS_PASSWORD` in plaintext until step 22
    excluded the sub-tree. An exclusion stops new writes; it cannot evict a blob a browser already
    holds. **Two exits** now clear via one helper: the façade's `logout()` (both menu components) and
    the plugin's internal auto-logout on token-refresh failure — the exit a user does not choose.
    7 tests, 5/5 mutations caught. **Mutation testing again caught a false claim in my own comment:**
    making only the façade clear SURVIVED the first suite, which falsified the spec's own statement
    that both exits were covered.
  - **The stale gate-era javadoc is corrected** — wms2-api PR #146 (`7c941e4`), MERGED, merge `0517c94`. It described
    `eligibleLocations` as a signature-only stub no controller reached; step A had filled the body and
    added the mapping in the same commit, so anyone auditing whether the picker's read works would
    have concluded it does not.
  - ⚠ **AND THE SAME STALE EXPECTATION HAD A WORSE SECOND HOME.** Five shape checks in
    `PutawayConfigControllerUnitTest.EligibleLocationsEndpoint` were `@Disabled` "until the endpoint
    exists", with a notice saying *"TO RE-ARM: delete this `@Disabled`"* — and **following that
    literally would have damaged the code.** Three of the five encoded the design the gate
    ANTICIPATED: one asserted the CONTROLLER carries `@Transactional` (step A deliberately put the
    boundary on the service; `P2A-ctl-no-tx` forbids it on the controller, and the test's own failure
    message said so while asserting the opposite), one asserted a `List` return where the read returns
    `Page`, and one pinned the parameters before `Pageable` existed. Deleting the annotation and
    "fixing" the failures would have added `@Transactional` to a controller that must not have it and
    un-paginated the read. All five now assert the shipped design; **5 skipped tests are live again.**
    **Generalisable: a "re-arm me later" note is a claim about a future that may not arrive as
    predicted — re-arming means re-deriving the assertion, not just deleting the annotation.**
  - The old javadoc wording is **paraphrased, not quoted**, in the correction, so a future audit
    grepping those phrases does not match the fix and re-raise a closed finding.

- **2026-08-11 — ALL FOUR PHASE-2 UI PRs MERGED TO DEVELOP**, base-first, each retargeted to `develop`
  as its predecessor landed: #42 → `9edb743`, #43 → `ec01dd7`, #44 → `536ac2b`, #45 → `bb6fd22`. Every
  branch verified an ancestor of `develop` after its own merge — no orphans (the failure mode that
  produced the #51 orphan on an earlier stack).
  - **The redistribution paid off at the second merge.** The reactive gate and all four Mediums were on
    `develop` the moment #43 landed, verified by grepping merged `develop` rather than trusting the
    branch: `return this.isSbAdmin` present, `hasResourceRole` gone. Had the fixes still been on the
    tip, DEV would have carried the disabled-gate defect through three deploys.
  - Merged `develop` re-verified independently: **208 Jest tests / 0 failures** (only the pre-existing
    `NuxtLogo` suite fails to run, as it does on clean develop), **`PHASE=1` 226/0**, **`PHASE=2` 65/1**,
    **`PHASE=all` 283 pass / 1 fail** — the single fail is `U-source`, step 19a. ESLint: 2 errors on the
    touched files, both pre-existing (`prefer-const`, `vue/no-mutating-props`).
  - Four `Docker Image CI` runs fired on the four pushes to `develop`, so this is deploying to DEV.

- **2026-08-11 — the review fixes were REDISTRIBUTED onto their owning branches**, so each PR is
  independently sound rather than depending on the tip. Step 20 `1f2e4a1`, step 21 `fa7a256`, step 22
  `74164cd`. Every tip passes on its own: **96 / 159 / 188 / 208** tests.
  - **The ownership rule used: the branch that makes a defect REACHABLE owns its fix.** That is not the
    same as the branch that introduced the file. H2 lives in step 20's component, but all three call
    sites there are `scope="WAREHOUSE"` with no `subjectId`, so the subject cannot change and the
    defect is unreachable — it belongs to step 21, which introduces MERCHANT scope and a changing
    subject. Likewise the merchant writer's error handling and the `editShipper` watcher coupling are
    step 21's; the persisted-credential exclusion is step 22's.
  - **Two tests had to MOVE between spec files**, because a test belongs with the branch that can
    exhibit the defect: the M2/M3/M4 regressions were written into step 22's config-health spec but
    pin step 20 behaviour, so they moved to step 20's spec. `S16` (the merchant-writer message) moved
    the other way, into step 21.
  - **Verified by comparing code-line multisets, not by eyeballing the diff.** All **11 production
    files are byte-equivalent** to the monolithic fix; the only differences are in two spec files
    (deliberately relocated tests) and comment wording. That check earned its keep: it found **one
    dropped assertion** — the rewritten M2 test had lost `not.toHaveBeenCalledWith` on the bare
    write, which is the exact thing that used to 409. Restored.
  - ⚠ **A parse error in a spec file reads as a healthy suite.** A bad splice left a stray `})`, and
    the run reported **169 passed** while that whole file silently contributed zero tests. Same trap as
    a mutation harness that judges by parsing a summary line instead of the exit code: `Tests:` counts
    only what actually ran. Check `Test Suites:` too.

- **2026-08-11 — INDEPENDENT REVIEW ROUND on PRs #42-#45 (conformance + code review + security, three
  lanes). Conformance PASS, but 2 High and 4 Medium defects in SHIPPED BEHAVIOUR, all fixed.** 207
  tests, 16/16 review-round mutations caught, 10 new `RV-*` verify rows each negative-tested,
  `PHASE=2` 65 pass / 1 fail (the 1 is step 19a).
  - ⚠ **H1 — THE PERMISSION GATE LOCKED OUT REAL ADMINS. Both lanes found it independently.**
    `canEdit()` was a **computed over `$kc`** — a plain injected object whose getters read a closure
    variable that is `null` until the *fire-and-forget* `initKeycloak()` resolves. A computed with
    **zero reactive dependencies** evaluates once and caches, so first paint cached `false` and never
    recovered. **Step 22 is what made it an everyday path:** the Operation Options tab index is
    persisted, so F5 restores it and the unconditional control mounts in the very first paint. Fixed
    by resolving the role in `mounted()` after `await $kc.ready`, into reactive data.
  - ⚠ **H1b — and the gate was NARROWER THAN THE BACKEND.** `hasResourceRole(role, clientId)` reads one
    client's roles; `JwtAccessTokenCustomizer.extractRoles` harvests **every** `resource_access` client
    **plus** the `groups` claim. The clientId passed was `process.env.KEYCLOAK_CLIENT` — build-wide —
    while the token comes from the **per-tenant** client. Now mirrored in `util/keycloakRoles.js`, which
    names the Java method as source of truth so the two cannot drift. See §3.12.
  - ⚠ **H2 — one shipper's unsaved selection was WRITTEN AGAINST THE NEXT SHIPPER.** The wrapper is
    never destroyed between shippers (`v-if="shipper"` stays true; Vuetify's overlay renders its slot
    regardless) and the `value` watcher synced `selectedId` only. **When both shippers inherit, `value`
    is `null` for both, so the watcher never fires** — Save wrote A's location against B's clientId
    with A's confirmed count. Fixed with a `subjectId`/`scope` watcher resetting selection, row,
    preview and dialog.
  - **M1 — `ComUtil.getErrorMessage` never existed**, so the ternary guarding it was permanently dead
    and every 409/422 became "network or server issue" — discarding the actionable half of D11.
  - **M2 — zeroing the count after a successful write** hid a warning that was still true, and made a
    second Save send no confirmation → the writer recomputed the same count and 409'd.
  - **M3 — Vuetify 2's `VBtn` derives `disabled` from the `disabled` prop ONLY; `:loading` does not
    disable it.** Two clicks on "Save anyway" wrote twice.
  - **M4 — a mid-pagination failure returned an empty set**, and the panel then stated "0 of 0 locations
    can be used as a putaway destination" — an affirmative claim contradicting the toast beside it.
  - ⚠ **A PLAINTEXT CREDENTIAL, one identifier away in the destructure step 22 was already editing.**
    `admin.configuration.systemSettings` carries `CUPS_SERVER_ADDRESS_PASSWORD` in plaintext (confirmed
    against wineco-dev) and was persisted to `localStorage`; nothing clears `vuex-web` on logout, so on
    a shared warehouse workstation it survived for the next user. Exclusion widened to the whole
    sub-tree. **Clearing `vuex-web` on logout is NOT fixed here** — broader than this ticket, filed as
    a follow-up rather than smuggled in.
  - Confirmed sound by the security lane: the gate is **correctly non-load-bearing** (no write reachable
    with `canEdit === false`), URL construction has **no injection**, and the HAL `PATCH /client/{id}`
    hole is closed by `PutawayConfigRepositoryEventHandler.onBeforeSave` → `validateOnly`, **not** by
    the UI strip. Latent trap recorded: that strip is safe *because this is PATCH* — SDR merges, so an
    absent field is an empty delta; switching to `$put` makes it a silent tier-2 **clear**.
  - ⚠ **Six of my own tests would have passed against broken code:** `toContain('2')` subsumed by
    `toContain('2739')`; `toContain('7')` satisfied by the `2739` already on screen; a PATCH-payload
    assertion whose fixture never carried the field; three that set `selectedId` directly and never
    exercised `onSelect`; three asserting `wrapper.vm.saveDisabled` while `v-btn` was stubbed, leaving
    the real binding unverified. **And every `$kc` mock was synchronously-ready — which is exactly why
    H1 was invisible to 205 passing tests.** A shared façade double now mirrors the real one, including
    a not-yet-initialised variant.
  - ⚠ **Verify-script findings from a lane that broke 17 rows:** a **live shell bug** (backticks in a
    double-quoted description made bash execute `inherited`); `U-neg-flags-in-js` checked **one file and
    3 of the 5 symbols** §11.1a names — `staginglane`, `sltname`, `entity_lock` were checked **nowhere**,
    and two of those are the scope-*inverting* predicates, so the lane's client-side flag tests were
    green on **both** gates; `U19-warn` was satisfiable by prose inside an **HTML comment** (seventh
    prose-vs-code trap — `code_only` is line-oriented, hence the new `vue_code_only`); `U20-uncond`
    missed `v-if="items.length > 0"`, *the exact defect it exists to block*, and my first re-tightening
    then **false-FAILED correct code** because a regex cannot distinguish a preceding element from an
    enclosing one; `U22-allrows` went **red on a behaviour-preserving reorder**. Nine further rows miss
    a defect in their own requirement but are covered by Jest.
  - ⚠ **I stated that `PHASE=2` filters to UI rows only. That is false** — 12 rows flip on
    `PROJECT_ROOT` alone, and against a stale API checkout the same command reads **43/13**, not 55/1.
    My figures were produced against a detached worktree at `origin/develop` and the lane reproduced
    them, so the numbers were honest and the explanation was not.
  - **Follow-ups filed, not smuggled in:** clear `vuex-web` on logout; and
    `PutawayDestinationQueryService.java:169-181` on merged `develop` still says "SIGNATURE ONLY — NOT
    IMPLEMENTED" and "NOT REACHABLE", both false, so anyone auditing whether the UI's read works will
    conclude it does not.

- **2026-08-11 — step 22 DONE (wms2-web-ui PR #45, `0e88b1c`, stacked on #44): config health + the
  persistedState exclusion.** 18 tests, 15/15 mutations caught, full suite 169 passed / 0 failed.
  **`PHASE=2` is now 55 pass / 1 fail, and the 1 is step 19a** — the only Phase 2 item left, and it is
  blocked on product sign-off for its copy, not on code.
  - **The config-health gap was created by step 19, deliberately and correctly.** §3.11.5 forbids
    offering an ineligible row, and step 19's `T17` pins that even for the saved value. So an invalid
    configuration rendered as an EMPTY field — **indistinguishable from unset, while the two behave
    differently at receipt time**: unset falls through to the next tier, whereas invalid-but-set is
    still stored and receiving's (iv-b) gate diverts those receipts to the standard lane, silently, per
    SKU. Worth generalising: **a rule that hides invalid data has to be paired with a rule that
    announces it**, or the correct filter becomes a silent failure. Step 19's own `T17` comment had
    already deferred this here, which is the only reason it was not lost.
  - A location stops being usable **without anyone touching this config** — its area flags change, it
    is locked, it becomes a lane, its `location_type` stops permitting the SKU's unit-load type, or
    another SKU claims it as a fix-assigned pick face. None of those edits happen on this screen, so
    there is no natural moment at which an operator would find out.
  - ⚠ **§3.11.4's instruction was not directly implementable either.** It says "add the putaway config
    keys to the exclusion", but `persistedState.client.js`'s reducer is a **single top-level
    destructure** and the target is nested at `admin.configuration.operationOptions`. Reshaped to a
    nested exclusion that REBUILDS `admin.configuration` — a `delete` would mutate the live state the
    reducer runs against and empty the table the operator is looking at (pinned by `P4`).
  - ⚠ **Mutation testing found a guard nothing else covered:** without `allRows.length === 0`, a valid
    live configuration is announced as broken for as long as the read takes. Every other test awaited
    the read first, so **first paint was untested** — the state an operator on a slow tenant actually
    sees. `H11` now drives a deliberately-unresolved promise.
  - Three negative tests on the new rows first read as "asserts nothing" and were **invalid mutations**
    rather than vacuous rows: each renamed a DEFINITION and left the call site, so the grep still
    matched while the code was broken. Verified by running Jest under all three (5, 9 and 4 tests red)
    instead of accepting the verdict — **a "vacuous" verdict on a row is itself a claim that needs
    checking.**

- **2026-08-11 — step 21 DONE (wms2-web-ui PR #44, `f5f3e44`, stacked on #43): the merchant tier.**
  20 tests, 15/15 mutations caught, full suite 151 passed / 0 failed. Closes the LAST TWO §11.1a UI
  rows that had never existed (`U-neg-shipper-patch`, `U-merchant-inherited`) — all seven now exist.
  - ⚠ **§3.11.3 NAMED THE WRONG READ SOURCE, and it is the SAME defect §3.11 defect 1 already caught
    once in this plan.** It said the field is read from `/client/detailView`; that payload has eight
    hand-built keys and `defaultputawaylocationId` is not among them. Implemented against
    `GET /client/{id}/effectivePutawayDestination` and **§3.11.3 has been corrected in place**. Worth
    generalising: **this plan has now twice assumed a `detailView` endpoint carries a column it does
    not.** Any future step that says "read X from a detailView" should be checked against the DTO
    builder, not against the entity.
  - The invisible defect the step had to avoid: `editShipper` is `$patch('/client/{id}')` — the HAL
    path — and `save()` sends the WHOLE shipper object. Once `defaultputawaylocationId` is on that
    object, **changing a printer silently overwrites the putaway destination through a path with no
    validation, no audit and no cache eviction.** Stripped by destructuring, not `delete`, which would
    mutate the live form object and blank the operator's control. Both halves pinned and both
    mutations red.
  - ⚠ **Two of my own tests were wrong in ways only mutation exposed.** `C7` guarded its file read on
    `EditShipper.__file`, which vue-jest does not set — so it read `''` and asserted nothing; the
    mutation that exposed it was *behaviour-preserving* (`inherited !== false` →
    `source !== 'MERCHANT_OVERRIDE'`), which is exactly the kind a purely behavioural suite cannot
    see. And the wrapper's RENDERING of `inheritedFrom` was untested, because `C5` only checks that
    the parent passes the prop and `shallowMount` never renders the child.
  - ⚠ **The perl-delimiter trap again, twice in one batch.** `file_contains_multiline` runs
    `perl -0777 -ne "exit(/$1/s ? 0 : 1)"`, so the unescaped `/` in `client/...` and
    `putawayConfig/merchant` terminated the match delimiter and both rows failed against correct code.
    Earlier rows had dodged it only by accident, writing `putawayConfig.warehouse` with a dot.
    **URL-shaped patterns belong in `grep -E`, which has no delimiter.**

- **2026-08-11 — step 20 DONE (wms2-web-ui PR #43, `cf2ced2`, stacked on #42): the warehouse tier is
  settable from the UI.** 33 tests, 16/16 mutations caught, full suite 129 passed / 0 failed, no new
  ESLint errors. The typed write surface is used and the three generic sysprop actions are untouched
  for the other ~145 syskeys (pinned by `S11`, `D3`, `D5` rather than asserted in prose).
  - ⚠ **§11.1a NAMED SEVEN UI ROWS THAT DID NOT EXIST IN THE VERIFY SCRIPT AT ALL** —
    `U-picker-source`, `U-neg-detailview`, `U-neg-flags-in-js`, `U-picker-tier`, `U-warehouse-typed`,
    `U-neg-shipper-patch`, `U-merchant-inherited`. The script had `U-picker`, `U-negq`, `U-param`,
    `U-shipper`, `U-persist` instead. **An acceptance criterion with no row is not a criterion**, and
    a row whose id the plan never mentions is invisible to anyone reading the plan. Steps 19/20 close
    five; `U-neg-shipper-patch` and `U-merchant-inherited` are step 21's.
  - ⚠ **AND ONE OF THEM CANNOT EVER PASS AS WORDED.** `U-neg-flags-in-js` asks that no `.vue` or
    store file reference `useforgoodsin` / `useforstorage` / `staginglane` / `entity_lock` /
    `sltname`. **Eight existing files do** — `functionalArea.vue`, `storageLocation.vue`,
    `locationType.vue` and others — and they are correct: they **display** those columns on
    master-data grids. Displaying a column is not testing a predicate. Implemented scoped to the
    putaway surfaces; the literal repo-wide form would fail forever against correct code, which is
    worse than a missing row. **§11.1a's wording is the defect, not the code.**
  - ⚠ **SIXTH prose-vs-code trap, and the first where the comment shipped in the SAME change as the
    row.** `U20-preview` asserted `saveDisabled()[\s\S]{0,200}blockingReason` via
    `file_contains_multiline`, which reads the RAW file — and the javadoc above `saveDisabled`
    explains why a non-null `blockingReason` must disable Save. Deleting the actual guard left the row
    green. Added a `code_contains_ml` helper. **The tightened form still passed**, because the
    `{0,200}` window bled into `blockingReasonText()` ~130 chars later — identical to `P2A-svc-tx`'s
    `{0,400}` matching another method's annotation. Now anchored to the exact expression
    `blockingReason != null`, which needs no window. **Two independent trap classes on one row.**
  - ⚠ **`U-param` asserted that an identifier EXISTS, not that the template branches on it.**
    `isDefaultPutawayLocation` also appears in the computed and in the submit guard, so replacing the
    template's `v-if` with `v-if="false"` — a dead branch where the picker never renders — left the
    row green. It now greps the template attribute itself.
  - The control renders **unconditionally**, which §3.11.2 requires and which is easy to mistake for
    styling: an unseeded tenant or a D12 delete leaves no row, and because
    `POST /systemProperty/create` rejects this syskey, a list-driven control would leave the
    warehouse tier permanently unreachable with no way to re-create the row.

- **2026-08-11 — step 19 DONE (wms2-web-ui PR #42, `91d500e`): the tiered `LocationPicker`.** 17 tests,
  12/12 mutations caught, ESLint clean, full suite 96 passed / 0 failed (`test/NuxtLogo.spec.js` fails
  to run on clean `develop` too). Ships inert — nothing renders it until steps 20/21.
  - **A test found a requirement the plan did not state: the currently-selected row must bypass the
    tier gate.** §3.11.5 specifies a two-tier filter on `tier`, and a literal reading of it drops an
    already-saved `ADVANCED` destination out of `items` — so `v-autocomplete` renders an **empty
    field** and an operator is told nothing is configured when something is. The gate exists to stop a
    storage location being *chosen* without the lock warning, not to hide one already in effect.
    `eligible` stays absolute, so an invalid saved destination is still not silently re-offered; step
    22 owns surfacing it. **Written into §3.11.5 so steps 20/21 and SBDEV-2643's picker inherit it.**
  - Two calls made beyond the plan's letter, both conservative: an **unrecognised `tier` fails
    CLOSED** (promoting it to the visible tier is the one way a storage location reaches an operator
    without the §7.6-row-8 warning), and the picker **drops `eligible === false` rows itself** rather
    than trusting the caller, which §3.11.5 assigns to the caller.
  - ⚠ **Both of the picker's pre-existing verify rows asserted nothing.** `U-picker` was
    `file_exists`; `U-negq` was a bare `file_not_contains` on a symbol nobody would type. **`touch
    components/common/LocationPicker.vue` turned both green** — the exact shape §11 warns about, and
    it survived every earlier review of this plan because a filename-level row *looks* like coverage.
    Strengthened, plus 9 `U19-*` rows; all 11 negative-tested.
  - ⚠ **Fifth prose-vs-code trap, and this time in a file I wrote in the same change:** the
    component's header comment explains why it must *not* read `useforgoodsin`, and cites the
    server's `area.useforgoodsin ? DEFAULT : ADVANCED` rule — so the raw negative false-FAILED the
    correct implementation. Every negative now pipes through `code_only`. Two more script traps in the
    same batch: a `{0,400}` proximity window shorter than the `v-alert` block it spanned (the same
    class as the `V-lanes` window step C broke), and `emitted('select')` used as an **ERE**, where the
    parens are grouping metacharacters and the pattern matches `emitted'select'`.
  - ⚠ **And two of my own MUTATIONS were invalid, each briefly reporting a real row as vacuous.** One
    was paren-unbalanced, so the suite failed to *run* — printing `Tests: 0 total`, which a
    summary-line parser reads as **zero failures** and reports as SURVIVED. Verdicts now come from
    jest's exit code. The other replaced only lowercase `deadlock` while the spec also contains
    `DEADLOCK` and the row greps case-insensitively. **A mutation harness needs its own negative
    control: a uniform verdict across many rows means the harness broke, not the script.**

  - ⚠ **The first negative-test pass of those repointed rows was itself invalid** and said all ten
    "ASSERT NOTHING": the mutations suffixed the token (`getUseforgoodsin` → `getUseforgoodsinXX`),
    which **still matches the regex as a substring**. Only an infix mutation (`getUseforXXgoodsin`)
    actually breaks it. Re-run that way, 9 of 10 went correctly red — and the tenth was a genuine
    vacuity: `V-p1skip`'s alternation matched the `Ctx` **accessor** in the evaluator, so it passed
    with the facade's `isUnitloadTypePermitted` service call deleted. It now pins both halves
    separately, all four mutations red.

- **2026-08-11 — step D SHIPPED (PR #144, `a10bc08`) and it did NOT need step C.** The ~8,800-query N+1
  on the ungated `GET /preview?scope=WAREHOUSE` is fixed by evaluating once per distinct
  `defultypeId` rather than once per SKU. **Measured: 8,804 SKUs, exactly 1 distinct
  `defultype_id` on `wms2-wineco-dev` → 8,804 evaluations collapse to 1.**
  - **Equivalence, not approximation:** at tiers 2/3 the only per-SKU input is `defultypeId` —
    rule (f) is the sole per-SKU predicate and runs only inside `if (scope == SKU)`
    (`PutawayDestinationValidator:133`), so `subjectItemdataId` is passed but unread. **Pinned by
    step B's merged `ruleFDoesNotRunAtMerchantScope`** — if that assumption ever breaks, that test
    goes red and the grouping must be revisited in the same commit.
  - **The step-C dependency this section asserted was an artefact of the proposed mechanism**, not
    of the defect. Same shape of error as step A's unpaginated contract. Two for two.
  - 3 of the 7 new tests failed pre-fix; 4 are preservation guards that pass on both sides,
    including that `exampleIncompatibleSku` stays the first failure in ITERATION order rather than
    the first SKU of the first failing type group.
  - ⚠ **Two of the 4 new verify rows were wrong on first write:** one used a `{0,200}` proximity
    window against a real gap of **542** characters (false-FAIL on correct code), the other called
    **`multiline_not_contains`, a helper this script does not define** — that name belongs to the
    SBDEV-2643 script — so bash returned 127 and the row read as an honest FAIL. Both fixed and
    negative-tested; the undefined-function audit was re-run across the whole script.

- **2026-08-11 — MERGED TO DEVELOP: steps 4, A and B, in that dependency order.** #143 first (merge
  `a8129c7`) because a characterization guard landing after the refactor is worthless; then #141
  (`913f017`); then #142 (`41c8257`), whose base had to be **retargeted from #141's branch to
  `develop`** before it could merge — merging it as-authored would have merged into an
  already-merged feature branch rather than develop.
  - **Verified against merged develop rather than trusting the PR pages:** the three touched test
    classes 88 run / 0 fail, `PHASE=1` **214/0**, `PHASE=all` **228 pass / 6 fail** — all six
    remaining failures are `U-*` rows for the web-UI steps 19-22.
  - ⚠ **Merging deployed to DEV.** `docker-image-develop.yml` triggers on `push: [develop]` and its
    `pull_request` trigger is commented out — which is also why **no CI ran on any of the three
    PRs** (`checks=0` on all of them) and **none had a human review** (`reviewDecision` empty). The
    evidence base for all three was the author's own test runs plus three subagent review lanes.
    Recorded because it is the honest description of what gated this work: nothing automated did.

- **2026-08-11 — step B DONE (PR #143, `29fa719`): the guard this plan claimed already existed now
  exists, and it is mutation-proven.** 50 tests characterizing the merged `PutawayDestinationValidator`.
  - **Deliberately NOT a TDD gate.** It characterizes already-merged behaviour, so it is green on the
    first run — and `wms-tdd-gate`'s rule 2 forbids writing tests that pass immediately, so the skill
    was not invoked. Forcing step B into gate shape would have been a category error. A red test here
    would have been a bug report against merged code; none were.
  - **Mutate-then-check replaced "fails for the right reason": 14 mutations, all 14 caught**, then
    reverted (validator byte-identical to `889298d` in the commit). Notably caught: the P2.6 flowbin
    skip removal (the ICE PACK case), a dropped message argument, an **argument transposition**, and
    moving P2.6 ahead of rule (f).
  - **The 4-of-8 coverage gap is closed**: P2.2 locked, P2.4 areaNotUsable (which had never fired),
    all three `rejectIfTrue` flags, `crossdockinglane`, P2.7(e) at WAREHOUSE, the rule-(f) `isFlowbin`
    gate, the P2.6 flowbin skip, and multi-failure precedence.
  - **Two things pinned that `getKey()` cannot see**: message ARGUMENTS (presence *and relative
    order* — a transposition is invisible to a presence-only assertion, and
    `skuAlreadyBoundToAnotherPickFace` takes `(sku, name)` where every sibling takes `(name, …)`),
    and predicate ORDER, which is not the P2.x numbering.
  - `P2-validator-tests-intact`'s byte-identity claim is still NOT wired, on purpose: it can only be
    anchored to this commit, and that row belongs to whoever starts step C rather than freezing an
    unreviewed file. Coverage rows (`P2B-*`) are wired instead and were negative-tested.

- **2026-08-11 — step 18a IMPLEMENTED IN PART: deliverable 4 only, in PR #141 (`5e4aacc`).** `BlockingReason` went
  from 3 values to 7 and `blockingReasonFor` now maps every rejection key. **The plan undercounted: there are 7
  rejection keys, not six** — the validator has 9 throw sites carrying 8 distinct keys, and §3.11.0a merges
  `putawayDestinationLocked` and `putawayDestinationIsALane` into one table row. The 8th, `entityNotFoundForId`, is a
  not-found error, unreachable only because `preview()` pre-resolves the location outside its `try` — **that
  pre-resolve is now pinned by a test**, because a plausible "unify the error handling" refactor would otherwise
  reinstate the defect with every test and both verify rows green.
  - **Wire-visible:** both rule-(f) keys now emit `BOUND_TO_ANOTHER_SKU` instead of `FIX_ASSIGNED` on an endpoint
    already on `develop`. Zero consumers across `wms2-api`, `wms2-web-ui` and `wms2-mobile-ui`. `FIX_ASSIGNED` is
    retained but unreachable — a consumer switching on it would silently stop matching, not fail.
  - **Reviewed in three lanes** (verifier PASS/0 blockers, code review, scoped re-review): 0 critical, 0 high;
    7 medium findings, all fixed. Every new guard proven by mutate-then-check rather than asserted.
  - **Deliverables 1+2 held, 3 blocked** — see the step-18a row. Steps 19-22 stay blocked behind them.

- **2026-08-11 — SBDEV-2643's remaining citation findings C1, C5, C6, C8, C9 raised and fixed. Three of
  them were overtaken by events, and the *corrections* had gone stale too**, so every coordinate below
  was re-derived against `origin/develop` rather than taken from the filing:
  - **C1** — the path half stands (`SecurityConfiguration.java` is at `net/aim_ai/wms/`, there is no
    `config/` variant), but the line has MOVED: the `/v3/**` rule is now **`:143`**, not `:136`, and
    Phase 1-API *widened its matcher* to `"/v3/**", "/putawayConfig/**"`. SBDEV-2643 cited `:136` in
    six places; all six corrected there.
  - **C5** — active `@PreAuthorize` sites are now `:80, 108, 121, 134, 143, 155, 176, 200` (8) with
    `:190, 261, 285, 315` commented. **C5's own list was also stale.** And its premise — *"every one of
    those 8 sites is broken"* — died with SBDEV-2863 on 2026-08-07.
  - **C6** — `BaseControllerTest` does not exist (`BaseControllerUnitTest:33`; the sibling is
    `BaseControllerIntegrationTest`). **It appeared 3 times here, not the 1 C6 documented**, and the
    same wrong name was in `sbdocs/9-System/templates/wms-plan-template.md:123` — fixed, which is the
    highest-leverage of the five since that template seeds every future plan.
  - **C8** — `:104-118`, and the stockunit sibling moved to `:183-190` because SBDEV-2821 inserted
    `getPutAwayCandidateLocations` between them. C8's verdict (do not use this query for the picker) is
    now stated by the code itself: its javadoc says HAL-exported consumers only, no longer drives putaway.
  - **C9** — method `:73-82`, `@Caching` block `:66-72` above it.
  - **Pattern worth noting:** every finding checked so far under-counted its occurrences (C4: 4 not 3,
    C6: 3 not 1, **C9: 2 not 1** — §1's problem statement carried the stale `:68-76` too, and was caught
    only by a post-edit sweep for residuals). Grep the whole file for a bad citation; do not fix only
    the row that reported it.

- **2026-08-11 — SBDEV-2643's finding C4 accepted and fixed: the `skuData.vue` citation was wrong in
  both path and range, in FOUR places** — §0.2 row 45, §6, §8.1's "unblock 2643" note, and §10.4 Q3
  (C4 itself documented three). Verified against `origin/develop`: the real path is
  `components/masterData/material/skuData/skuData.vue` — two segments were missing — and the
  commented create/edit block is **`:100-123`**. `:142` was correct. Raised on the ticket for the
  record, since Phase 2's UI steps are read against these coordinates. **Two adjacent facts verified
  at the same time, both of which change the shape of the 2643 UI work:** an actions column
  **already exists** at `:95-99` and already ships a live eye button, so that work is "add a second
  button to an existing column", not "create a column"; and the line that makes a newly-added
  payload key render as a stray raw row is **`:130`**'s `exclude-fields`, not `:142`.

- **2026-08-11 (r-next) — §3.11 REWRITTEN against merged `889298d` / `4ce39a1`; Phase 2 gains API work.**
  Phase 2 had never been re-derived after Q12 → (iv-b) or after Phase 1-API merged, and **Step 19 was
  unimplementable as written.** Five defects, verified `file:line`:
  - **(1) FATAL — the mandated client-side filter cannot exist.** `getLocationView()`
    (`ViewDtoService.java:806-832`) emits eight keys and carries **no `entity_lock`, no lane flags, no
    area `useforgoodsin`/`useforstorage`** — four of five predicates are not evaluable in Vue. **Fix:**
    §3.11.0's `GET /putawayConfig/eligibleLocations`, which makes Phase 2 **not UI-only** (new step 18a).
  - **(2) The mandated filter was the wrong filter.** "Exactly P2.4" both over- and under-offers; the
    merged validator's predicate set is **scope-dependent in five places** (§3.11.5a) and has no
    P2.7(c)/P2.5 at all. The old "P2.7-eligible areas (D13)" phrasing no longer denotes anything —
    since (iv-b), D13 is a *placement* rule.
  - **(3) §3.11.1 was ~70% already shipped by SBDEV-2731 PR1**, and the part that was missing did not
    exist when it was written: the **diversion** rendering (`divertedTo` / `divertedReason`). Without it
    the screen shows `ICE PACK` while stock lands on `PutAwayLane` — SBDEV-2731's own defect class.
    Narrowed, and given the step it never had (19a).
  - **(4) The `createBol.vue:109-125` precedent was wrong on all three counts** (SBDEV-2643 §10.3 C7):
    that range is plain `v-text-field`s, the only `v-autocomplete` is `:68-76`, and no "Lookup" button
    exists anywhere in the file. **(5) `persistedState` is a single top-level reducer at `:22-25`.**
  - **Two decisions taken, both to avoid a second copy of P2** (the hazard
    `PutawayConfigController.java:104-106` names): the predicates are **extracted** into a pure
    `PutawayDestinationRules.evaluate(...)` that both the throwing validator and the bulk read call, and
    the bulk read is **5 queries, not 2,739 × `validate()`** — `isUnitloadTypePermitted` is keyed on
    `location.type_id` (8 distinct values), not location id.
  - **`BlockingReason` extension accepted as THIS plan's work** (§3.11.0a): 3 of 6 throw keys mapped to
    `null`, and the enum could not name the commonest SKU-scope rejection — **1,345 of 2,068 flowbins on
    `wms2-wineco-dev` are already FLA-bound.** SBDEV-2643 MUST-4 forbids 2643 doing it.
  - **Q2 closed** (splits by scope, §3.11.5a). **SBDEV-2643's `Q6`/row 0b and `D12`/row 0d are both
    satisfied**, which deletes 2643's fallback Phase A3.
  - ⚠ **Unrelated but found while verifying, and it is live:** `wh01_hydra_v2` (Hydra DEV) still has **no
    `flyway_schema_history`**, so `V2.2.13` never applied there — `client.defaultputawaylocation_id` is
    absent, `itemdata.putawaylocation_id` is still `NOT NULL`, `putaway_config_audit` does not exist.
    §8.1's merge-1 gate (Q8) was **not** satisfied, and with `ddl-auto=none` that tenant boots green and
    throws `42703` on every `client` read — pre-mortem **P1**, exactly as predicted. Operator action:
    `db/backfill-flyway-history.sh`, then migrate. Not a Phase 2 blocker, but it blocks testing on that
    tenant. `wms2-wineco-dev` is correct (`V2.2.13` applied 2026-08-11 13:50).

- **2026-08-11 — the PR #139 review round. Three findings, all accepted; two of them found holes this
  plan had reasoned itself into.**
  - **P1 — the HAL `DELETE` had no authorization at all.** D12 (§3.9.1) settled that deleting the
    `DEFAULT_PUTAWAY_LOCATION` row is *accepted*, since an absent row and a blank row are the same
    state to the resolver. What D12 did not say, and what the implementation then assumed, is who may
    cause it: **"the resulting state is legal" is not "any caller may produce it."** Every other write
    to tier 3 reaches an `sb_admin` gate — the typed `PUT /putawayConfig/warehouse`, and both HAL
    create and HAL save through `validateOnly` — but a delete carries no destination to validate, so
    it passed through `onBeforeDelete` to the audit capture and nothing else. `SecurityConfiguration`
    block C, whose comment reads *"Admin-Only WMS Endpoints"*, grants `/v3/sysprop/**` to
    **`wms_user`**, so any warehouse operator could clear the warehouse-wide destination and reroute
    every later receipt to the fallback lane. Fixed with
    `PutawayConfigService.requireWarehouseConfigWriteAuthority()` — authorization and nothing else, on
    the reliably-proxied `@Service` per §3.9.4, called **before** the carrier is touched so a 403
    strands no entry on a pooled thread. **`validateOnly` deliberately cannot serve as this gate:** it
    would extract the row's OLD value and validate *that*, making a rotted config (locked location,
    lane) undeletable — §3.9.3's validate-the-state trap in its worst form.
  - **P2a — the HAL channel never ran P2.6 at tiers 2/3, so D11's absolute reject was typed-only.** At
    merchant and warehouse scope the validator is necessarily called with no SKU and no unit-load type
    (there is no single SKU at those scopes), which is correct for the scope-level rules and silently
    skips the one per-SKU rule. The typed endpoint refuses a destination no SKU in scope can use
    (422 `putawayDestinationIncompatibleForEverySku`); HAL accepted it, and then every later
    non-carrier receipt in that scope fails. Reachable, not theoretical — `store/admin/shippers.js:47`
    PATCHes `/v3/client/{id}`, so **HAL is the live shipper screen's channel for tier 2**, the same
    fact §3.9.3 relies on for the edit-lock argument. Only the **absolute** half is enforced there:
    the partial case is count-and-confirm, and Spring Data REST discards unknown query parameters, so
    `confirmIncompatibleSkus` can never reach a `@HandleBefore*` handler (the same constraint that put
    D11 in a typed controller in the first place, §3.5a). Rejecting partial incompatibility on HAL
    would make the shipper screen unable to save a default the typed endpoint accepts with
    confirmation — trading an edit lock on a live screen for a guard that channel structurally cannot
    implement. The scan runs only on a real destination **delta**, which is what keeps it off the
    shipper screen's ordinary save path and preserves §3.9.5's "a MERCHANT read must never touch
    `itemdata`".
  - **P2b — `requireConfirmation` and the write ran in separate transactions.** D11's whole rationale
    is that the preview's count is stale by the time the admin acts, so the writer recomputes; but the
    recompute committed in its own read-only transaction and the write opened another, leaving a
    second, smaller window in which a concurrent SKU create makes the just-passed check wrong. Both
    typed writers now carry `@Transactional(value = "tenantTransactionManager", rollbackFor =
    Exception.class)`. **`rollbackFor` is load-bearing, not decoration:** the service writers declare
    `rollbackFor = BusinessException.class`, so a rejection marks the now-shared transaction
    rollback-only, and under the default rules (unchecked only) this outer boundary would then attempt
    to *commit* it — `AbstractPlatformTransactionManager` answers that with
    `UnexpectedRollbackException`, turning **every 422 and 409 in the class into a 500**. Both
    exceptions on this path are checked, so the broad rule is the correct one.
  - **The verify script was inert for this round too, and its own new rows were wrong twice.** Nine
    rows added (`H-delauth`, `CFG-delgate`, `H-delorder`, `H-delneg`, `CFG-halabs`, `CFG-halnew`,
    `CFG-halpart`, `CTL-tx`, `T-review`), each negative-controlled by reverting its fix. Two were
    initially written as `[\s\S]{0,N}` windows and **both were wrong about their own N** — one failed
    a correct implementation, the other passed only by luck. They are now scoped to the actual method
    body via a new `method_body` helper. `H-delneg` then failed a *second* time because the comment
    explaining why the delete must not call `validateOnly` contains the string `validateOnly`; hence
    `code_only`, and the rule that every body-scoped negative is paired with a positive on the same
    extraction so an empty extraction cannot pass vacuously. **Fifth and sixth distinct ways a check
    in this file has been wrong about its own syntax.**

- **2026-08-10 — the migration is now `V2.2.13`. Third renumbering, and the one that produced a
  tool.** `V2.2.11` was claimed by **PR #138** the same day, and a third branch already held
  `V2.2.12`. Flyway versions are append-only and never reused, so two files at one version wedge the
  chain on every database that already applied either.
  - **Confirmed free by sweeping ALL remote branches**, not by `ls db/migration/`. That listing shows
    a stale head *by construction* — unmerged branches hold versions nothing local can see, which is
    precisely how this happened three times (`V2.2.08` → `V2.2.10` → `V2.2.11` → `V2.2.13`).
  - **Renamed with `git mv`** (history preserved) plus every in-repo reference: the migration's own
    header, `WmsConstants`, `Itemdata`, `Client`, `PutawayConfigService`, `MobilePutAwayService` and
    its test. Outside the repo: this plan, its verify script, **SBDEV-2643**'s plan and verify script
    (its AC4/AC9 are blocked on this file *by name*), **SBDEV-2821**'s plan, the plan README, and
    SBDEV-2854's dependency note.
  - **⚠ The blanket find-and-replace rewrote this plan's own history, and had to be repaired.** The
    2026-08-06 renumbering banner in §0 records a PAST event — it said "renumbered to `V2.2.11`" and
    "SBDEV-2854 originally took `V2.2.11`" — and the sweep silently turned both into `V2.2.13`,
    leaving the banner self-contradictory ("originally took V2.2.13… now takes V2.2.13"). Repaired
    2026-08-10: the banner states the numbers *as they were on the day*, carries a pointer to this
    entry, and D16 now lists all three renumberings. **SBDEV-2854's plan §824 documents this exact
    trap from its own version move; the warning was there and was not heeded.** A version rename is
    not a global replace — dated statements, superseded banners and changelog entries must keep the
    numbers they had.
  - **The sweep is now a script.** `db/check-migration-version-collision.sh` (**SBDEV-2916**, PR #140)
    does what was done by hand here, and the same ticket enables `app.flyway.out-of-order` so a lower
    version merging late no longer stops that database migrating at all — measured behaviour, not
    assumed: without it `migrate()` throws `FlywayValidateException` and `StartupFlywayMigrator`
    swallows the failure per tenant, so the symptom is a database quietly stuck on an old schema.

- **2026-08-10 — PHASE 3b REVIEW (code + security): 5 High, 10 Medium fixed; §3.8 had a gap that
  re-created the parent bug.** Two independent lanes, run in parallel after 3a passed.
  - **§3.8's display envelope never mentioned the (iv-b) divert — H3.** The endpoint returned the
    CONFIGURED destination while receiving diverts a pick face to the lane, so the operator was shown
    `Ice Pack` and the stock landed on `PutAwayLane`. **That is SBDEV-2731's own failure mode,
    re-created by the change that fixes it**, and under (iv-b) it is the common case rather than an
    edge. **Resolved 2026-08-10 by the ticket owner as option (b):** the envelope carries BOTH —
    `locationName`/`source` stay the configured destination, and a new `divertedTo` (plus
    `divertedReason`) names the actual placement, absent when they agree. `compatible` becomes P1's
    verdict against the PLACEMENT. §3.8's field list is superseded by this entry; Phase 2's Vue work
    must consume the 9-field envelope.
  - **Authorization: `/putawayConfig` is not under `/v3`.** `SecurityConfiguration` gates `/v3/**` at
    `wms_user`; everything else falls through to `anyRequest().authenticated()`. The ungated preview
    was therefore reachable by any principal holding a valid tenant-realm JWT with **zero app
    authorities**. §3.5a's "reveals no more than the location picker already shows" is true of the
    INFORMATION and false of the AUDIENCE, because the picker is served from `/v3`. Added to the
    `wms_user` matcher, which also gives the three writers a URL-level backstop.
  - **`POST /v3/sysprop` was an unguarded tier-3 write** — `Sysprop` had `@HandleBeforeSave` and
    `@HandleBeforeDelete` but no `@HandleBeforeCreate`, so a HAL create set the warehouse default
    with no validation, no authority check and no audit row. Newly reachable *because* of this plan:
    D12 accepts deleting the row and §3.9.1 closed `SystemPropertyController.create` against
    re-creating it, leaving the SDR create as the way in.
  - **`PutawayConfigValidationException` shipped without its `@ExceptionHandler`** (§0.1b N7a
    specified both halves), so every HAL rejection was a bare 500 while the type's own javadoc
    promised "the intended 422". The handler's unit test asserted the exception TYPE propagates —
    true either way. Another assertion that could not fail.
  - **`auditAndEvict` evicted nothing**, leaving the shipper screen's cache stale for the full TTL on
    every save; and both evict key sets were wrong — the `sysprops` key omitted the tenant prefix
    every other key in the codebase carries, and the `clients` keys used an `':id:'` form copied from
    the `itemdata` cache that `ClientService` does not have.
  - **`updateClient` is the third direct-save path** (§3.9.1 names only create/updateValue/delete).
    Re-pointing the guarded row's `client_id` moves it off the SYSTEM client, silently reverting
    tier 3 to "not configured" with no audit row. Guarded 2026-08-10 on the ticket owner's decision.
  - **Two defects I introduced while fixing the review, both caught before landing.** (a) A first cut
    at the ThreadLocal fix parked the taken value on an INSTANCE FIELD of a singleton handler — a
    data race across concurrent requests, worse than the leak it replaced. (b) The new create
    handlers called `validateOnly` unconditionally, and that method carries
    `@PreAuthorize(IS_SB_ADMIN)`, so every HAL `POST /v3/itemdata` and `/v3/client` began demanding
    `sb_admin` where `wms_user` sufficed — a functional regression on the SKU and shipper creation
    screens.
  - **`M6`/`SEC-M2` — the unbounded WAREHOUSE-scope scan behind `/preview` (a `findAll()` plus one
    constraint query per SKU; ~8,800 on `wms2-wineco-dev`) is DEFERRED to Phase 2** on the ticket
    owner's decision. The audience is now `wms_user` rather than any authenticated principal, which
    removes the amplification vector; the scan itself remains.
  - **Still open, and it is the same blind spot throughout:** nothing tests the HAL authorization
    path. The handler's test mocks `PutawayConfigService`, so it cannot observe `@PreAuthorize`, and
    `PutawayResolverContextLoadTest` cannot run under SBDEV-2217. The "registration is SILENT when it
    fails" risk §3.9.4 names has no evidence against it. Only a real HAL request closes that.

- **2026-08-09 — PHASE 3a CONFORMANCE LANE: five in-scope items were unbuilt behind a green gate, two
  of them throwing stubs.** An independent verifier re-ran every command and found that
  `PHASE=1 → 176 pass, 0 fail` was **not** evidence of a complete Phase 1-API. What it missed:
  - **`PutawayDestinationQueryService` shipped as `throw new UnsupportedOperationException` (×2)**, so
    `GET /receiving/getPutawayDestination/{advicePositionId}` returned **HTTP 500 on every call** —
    the entire SBDEV-2731 display contract, the reason the parent ticket exists. The four
    `GetPutawayDestination` gate tests **stub the facade**, so nothing in a 4,786-test suite ever
    reached the method; `PutawayResolverContextLoadTest` would have autowired the real bean but is
    correctly deferred under SBDEV-2217. A stubbed collaborator plus a deferred integration lane can
    hide an unimplemented service completely.
  - **`PutawayConfigController.preview` (N10)** — same, a throwing stub.
  - **`GET /client/{id}/effectivePutawayDestination` (N9)** — zero occurrences in `src/`. It had **no
    verify row at all**, which is why it was never built.
  - **`SystemPropertyController` (§3.9.1, rows 31a–31c)** — never touched; both direct-`save()`
    endpoints still wrote tier 3 unvalidated and unaudited. Root cause is the false §11.1 status line
    corrected above.
  - **Step 17a** — putaway candidate surfacing never extended past tier 1.
  **Why the gate was blind:** every covering row was an EXISTENCE grep a throwing stub satisfies —
  `check_W_endpoint` is `file_contains 'getPutawayDestination'`, `check_CTL_preview` is
  `file_contains '/preview'`, `check_N2_readonly_facade` checks the file, an annotation and a string
  and never a method body. **Eleven rows added** that fail on a stub, led by `NOSTUB` (no putaway
  class may contain `throw new UnsupportedOperationException`), which alone catches two of the five.
  All eleven negative-tested against a detached worktree at `origin/develop`: 11/11 red there,
  green here. `N9-nores` was conjoined after it passed **vacuously** on the base.
  - **D12 was a trap as implemented.** `setWarehouseDestination` threw when the sysprop row was
    absent, while the new `create` guard refuses that syskey — so one click on the configuration
    screen's delete button would have made tier 3 unreachable from the UI until someone ran SQL.
    §3.9.1 calls for the writer to re-create the row; it now does, mirroring `V2.2.13`'s seed exactly.
  - **A real ArchUnit violation was hiding behind a pre-existing red.** `OptionalSafetyArchTest` fails
    on `develop`, so "2 failures, same as baseline" looked clean — but the baseline is **8**
    violations and the run showed **12**, the four new ones all in rule (f). Matching the failure
    COUNT says nothing about the contents. Rewritten to `.map(...).orElse(null)`.
  - **Script defect:** `VERIFY_COMPLETED=1` was set only in the `PHASE=all` branch, so every
    phase-scoped run printed the "ABORTED before completion" banner after finishing cleanly — noise
    in the only mode §11.2 gates on, and it trains the reader to ignore the banner that exists to be
    loud. Fixed.

- **2026-08-09 — IMPLEMENTATION (Phase 1-API): three more verify-script rows could not pass a
  conformant tree, and one plan sentence contradicted §0.** Found by driving `PHASE=1` to zero. All
  three are the class the 2026-08-09 script audit was run to eliminate (`V-nofixabs`,
  `check_V_no_pickface_reject`, `check_V_rule_e_not_area_flag`) — a check that fails correct code is
  worse than no check, because the only way past it is to decorate the code.
  - **`H-split` could never pass on ANY tree — a Perl sigil bug.** The multi-line helpers run the
    pattern through `perl -0777 -ne`, where an unescaped `@name` inside a regex **interpolates as an
    array**. `'@HandleBeforeCreate\s+@HandleBeforeSave'` therefore collapsed to `/\s+/`, which matches
    any file containing whitespace — so this NEGATIVE was a permanent FAIL regardless of the handler's
    shape. Three sibling patterns in the same script escape the sigil (`\@NotNull`, `\@Column`); two did
    not. Both fixed. The second, `check_N2_readonly_facade`'s `@Transactional\(...readOnly`, failed
    *open* rather than closed — it was silently matching any `(...readOnly = true`, which is why nothing
    flagged it.
  - **`R-nogsv` and `R-tier3-read-path` were mutually unsatisfiable.** `R-nogsv` forbade the substring
    `getSysvalue` anywhere in the resolver; `R-tier3-read-path` **requires**
    `findBySyskeyAndClientIdAndWorkstation`, which returns a `Sysprop` entity whose value can only be
    read with `getSysvalue()`. What landmines A3/A4 actually forbid is `SyspropService.getSysvalue` (the
    client-blind `order by client_id LIMIT 1` helper with the clientId-less cache key), which is how
    §3.4a states it. Narrowed to the service call.
  - **`W-gatenear` was jointly unsatisfiable with `W-gateord`.** It demanded `getUseforpicking` within
    400 chars of `transferUnitLoadToLocation(`, but §3.7.1 mandates the gate **above** the per-case loop
    and §3.7.2 puts the placement **inside** it — ~3,000 chars apart, and necessarily so, since
    `W-gateord` independently forces the gate above `requireCompatible`, itself above the loop. The only
    ways to satisfy both were a comment naming the token or a redundant second guard at the placement.
    Replaced with the property the row was named for: the gate **retargets** the destination variable
    and the placement **uses** the retargeted value. An implementation that computes the gate and then
    places the original destination anyway — SBDEV-2731's reported bug — fails the second clause.
    Negative-tested both ways.
  - **§7.1's "the lane-presence guard still reports a missing lane" applies to `FileImportController`
    only.** §0.1 rows 8/9, §3.2's site table and §5.3 all say to **delete** `SkuRestController`'s
    `findByName(PutAwayLane)` lookup, and `S1-neg2` enforces the deletion; the guard survives in
    `FileImportController` (SBDEV-2037), where `S3-pos1`/`S3-pos2` pin it. Deleting it leaves nothing
    unguarded: the resolver's tier-4 lookup fails a missing lane at receipt and names the tier.
  - **Two implementation refinements against §3 as written.** (a) `PutawayResolutionMetrics.resolved`
    takes the `carrier` flag as a third argument, matching §3.7.1's own snippet — the two-argument form
    could not express §3.7.2's "surfaced but not applied" case. (b) `readCommittedDestination` reads the
    **WAREHOUSE** tier by `syskey` when `subjectId` is null and by row id otherwise: §3.9.5's snippet is
    id-keyed only, but the typed writer passes null, so an id-only read would have audited
    `previous = NULL` on every typed warehouse write.

- **2026-08-09 — SECOND REVIEW PASS: the sections D18 left unreviewed. Verdict sound-with-changes; four
  defects fixed.** Covers the resolver (§3.1), the audit table (§3.14), `V2.2.13` (§5.1), and D11/P2.6.
  - **F-1 — every pre-2731 `UnitloadBusinessService` citation was stale, and two had teeth.** 2731 PR1
    added 47 lines / removed 2 to that file; anchors taken before it were never re-measured (offsets
    **+8** before the message block, **+45** after). `:182`, cited as the empty-constraint **fail-open**
    that step 5 orders the implementer to replicate, is the `WRONG_ITEMDATA_FIXASSIGNMENT` throw — *a
    reject with the opposite polarity*; the fail-open is `:190`. `:191`, cited by step 6 and §3.6.1 as
    2731's neutral-key throw with "do not re-specify `:191`", is `boolean foundPermittingConstraint =
    false;`; the throw is `:235`. Also re-anchored: `:170-175`→`:178-184` (the SKU-mismatch rule, not the
    carrier check), `:180-193`→`:188-237`, `:214-215`→`:259-260` (the SBDEV-2232 lock warning),
    `:150`→`:158`, `:156-158`→`:163-165`, `:161-177`→`:169-184`, `:162-167`→`:173-176`. **41 citation
    replacements in total.** Every claim's *substance* verified correct — this was a pointer defect, not
    a design defect. ⚠ Note the defect propagated into shipped code: `UnitloadBusinessService:199-201`
    carries a comment repeating "the NEUTRAL key at `:191`", copied from this plan. Fixing that comment
    belongs to a wms2-api change, not here.
  - **F-2 — the `MobilePutAwayService` citations went stale the day SBDEV-2821 merged.** They were
    **correct at `6bc709a`**; 2821 added 34 lines on 2026-08-09 and the same-day edit that marked gate 3
    "CLEARED" did not re-take them. `storeBoxOnLocation:471-489` — the citation behind *"putaway already
    handles pick faces correctly"*, the load-bearing premise of Q12 → (iv-b) and quoted in the review
    brief given to the Decision-1 reviewer — is now 2821's new area gate; the FLA auto-create is `:505`,
    the virtual-UL resolve `:508`, the merge `:513`. Re-anchored to `:497-514`, with `:479-482`→`:499-506`,
    `:479-487`→`:499-513`, `calculatePutAwayList :212-283`→`:217-305`, and the `verifyScannedLocation`
    family `:403-447`→`:412-456`, `:418`→`:427`, `:428-437`→`:437-445`, `:430-444`→`:447-453`,
    `:437`→`:444`. Also normalised `:119-126`→`:121-128`, an internal inconsistency for the same guard.
  - **F-3 — D11's SKU-scope "absolute reject" contradicted the (iv-b) P1 skip.** Read literally it
    re-blocks `ICE PACK` (`Case` → flowbin), the exact configuration SBDEV-2731 exists to make savable
    and which SBDEV-2643 r3/r5 depends on being legal. Fixed with an explicit ordering box: **the
    `sltname == 'flowbin'` skip runs BEFORE P2.6/D11**, and `skuWritePermitsPickFaceDestination` is the
    test that pins it.
  - **F-4 — P2.6's input column was still unspecified**, by the plan's own 2026-08-09 warning box.
    **Resolved: P2.6 enumerates `itemdata.defultype_id` and is declared a HEURISTIC PRE-CHECK**, with the
    runtime check authoritative — because a configuration has no advice positions to enumerate, and the
    rejected alternative ("every type an advice could carry") rejects nearly every pick-face
    configuration and re-creates SBDEV-2731 at config time. The box's misattribution of `defultype_id` to
    the *location* `ICE PACK` is corrected in place.
  - **F-6 — §3.1.5's "only three matches" is now six**, all still comments; the MANDATORY-facade
    conclusion is unaffected.
  - **Process note:** the "re-check the previous Critic pass's 12 findings" gate is **retired as
    undischargeable** — see the banner. The findings are enumerated nowhere and predate this repo's
    history for the file.

- **2026-08-09 — verify script: `V-nofixabs` CONTRADICTED rule (f) and is replaced; rule (f) had no
  coverage at all.** Found during implementation, when a conformant validator failed the check.
  - **The contradiction.** `check_V_no_fixloc_absolute` was a proximity negative —
    *no `reject|throw|BusinessException|FIX_ASSIGNED` within 400 chars of `findByAssignedlocationId`* —
    written on 2026-08-08 to prove P2.5's absolute reject was gone. **P2.7 rule (f), added 2026-08-09
    by review, requires exactly that throw**: a flowbin bound to a *different* SKU must be rejected.
    A correct implementation of rule (f) cannot pass it.
  - **It is the third instance of a defect that script's own audit was run to remove.** The same
    2026-08-09 audit deleted two sibling proximity negatives (`check_V_no_pickface_reject`,
    `check_V_rule_e_not_area_flag`) with the note *"the regex cannot tell WHY something throws… they
    would have blocked the implementation"* — and missed this one, which is the identical shape.
  - **Replaced the way the audit replaced the other two: with the positive property.** P2.5 rejected on
    the mere *presence* of a `FixLocationAssignment`, with no `itemdataId` comparison — that absence
    *was* the D15 mechanism. Rule (f) rejects only on *mismatch*, which cannot work without the
    comparison. So the new row **`V-fixmismatch`** asserts `findByAssignedlocationId … getItemdataId`.
    Negative-tested: passes the mismatch-scoped validator, fails a synthetic absolute-reject one, and
    fails on a missing file (guarded twice — `file_exists` plus the helper's `[ -f ]`).
  - **Coverage gap closed.** The script had **zero** checks for rule (f). Three rows added for the test
    names §7.1 already mandates — `T-fFgn`, `T-fOwn`, `T-fOwnOk`. All three are required: the two
    rejects alone would pass an implementation that bans *every* fix-assigned flowbin at tier 1, which
    is the over-reject (iv-b) exists to prevent.

- **2026-08-09 — Q12 CLOSED on the ticket owner's decision; the "B/A sign-off" gate is removed.**
  (iv-b) was chosen by the owner on 2026-08-08 and reaffirmed on 2026-08-09. The plan had been carrying
  it as a **blocking gate awaiting a B/A reply**, which mis-stated who owns the call: the outstanding
  item is a **notification** to @David Oppenheim / @Brent Campbell, not an approval the work waits on.
  Precedent in the same family and the same week — SBDEV-2821's Q4 was adopted on David's endorsement
  plus owner direction, Brent never replied to the hand-off, and it shipped and merged 2026-08-09.
  **Effect: the gates before `wms-tdd-gate` drop from two to one** — end-to-end review and flipping off
  `draft`. §7.1 can be written against (iv-b) today. If either objects later, Q12 reopens and
  (i)–(iii)/(iv-a) are preserved in §10.4.

- **2026-08-09 — `Authority.IS_SB_ADMIN` was a latent 500 for all six admin-gated writes; SBDEV-2863
  fixed it before this plan shipped.** Found by a status sweep, not a review: `origin/develop` had moved
  two merges past the checkout this plan was written against (`6bc709a` → `fd90487`).
  - **The defect.** From `ded4d644` (2025-10-29) to 2026-08-07 the constant was `"isSbAdmin()"`, naming a
    SpEL method on no expression root. Every `@PreAuthorize` using it threw `EL1004E` **inside** the
    authorization check and returned **HTTP 500 to every caller, `sb_admin` included**. This plan writes
    that annotation at six sites (§3.5 `:905, 917, 925`, §3.9 `:1491`, §3.5a `:972, 978, 985`), so
    merging before 2026-08-07 would have shipped a security boundary that failed open-to-nobody — and
    M16/M16a would have read as "endpoint broken", not "authorization broken".
  - **The fix.** [SBDEV-2863](https://app.clickup.com/t/868knmx18), PR #134 (`675b4a1` + `d8e0137`, merge
    `7d9d38e`), merged 2026-08-07. `Authority.java:44` now renders `hasAuthority('sb_admin')`, plus a
    `@Nested AuthorityExpressionsResolve` test evaluating the constant through the real handler.
  - **Effect here: no design change and no edit to the annotations.** §3.12 gains a warning box, §5.1
    row 7 records the dependency. **Keep `Authority.IS_SB_ADMIN`** — swapping it to
    `getExpForRole(SB_ADMIN_ROLE)` is now a no-op that 2863's own test would still pass, so it is churn.
  - **SBDEV-2643's blocking prerequisite on this plan is discharged.** Its row 0e (*"2732 must not merge
    carrying `Authority.IS_SB_ADMIN`"*) is void, and its verify probe `X-2732-authz` — which asserted the
    **absence** of the annotation, and **would have failed this plan's correct implementation** — has
    been deleted and replaced by a regression guard on `Authority.java`.

- **2026-08-09 — Flyway: `V2.2.13` re-confirmed free, and the banner's "head is `V2.2.09`" is stale.**
  SBDEV-2854 **merged 2026-08-07** (PR #132, `68274b0`), so `V2.2.10` is on `origin/develop` and the head
  is **`V2.2.10`**, not `V2.2.09`-with-an-open-PR as the top banner states. A fresh sweep of **every**
  remote branch on 2026-08-09 found no version above `V2.2.10`, so **`V2.2.13` remains correct for this
  plan.** The D16 instruction stands: re-sweep all remotes immediately before the PR, because unmerged
  branches hold invisible versions. **Unchanged and still binding:** `V2.2.10` must be **applied** per
  tenant before `V2.2.13` (§8.1 merge 0b) — merged is not applied.

- **2026-08-09 — FIRST INDEPENDENT REVIEW of the three (iv-b) decisions; three corrections landed.** The
  decisions were reviewed against the merged code at `6bc709a` and re-measured on `wms2-wineco-dev` and
  `wms2-hydra-dev2`. Verdict: **sound-with-changes on all three.** This is the pass D18 required for the
  (iv-b) rewrite — it does **not** discharge D18 for the rest of the plan, which is still unreviewed.
  - **P1 skip narrowed to `sltname == 'flowbin'`** (§3.4b). The `useforpicking` disjunct was a defect: for
    `overstock box` / `overstock pallet` / `cases and pallets` destinations, putaway does a **whole-unit-load
    transfer** that re-runs P1 verbatim at `UnitloadBusinessService:187-200`, so skipping it at write time
    relocated SBDEV-2731's error to putaway rather than removing it. Structural, not yet live — every SKU's
    `defultype_id` is `Case` on both measured tenants.
  - **"Skip at both enforcement points" corrected to an ORDERING requirement.** There is no P1 skip at
    receive time; step 15's gate simply runs first. Stating it as a skip invited one that would also fire for
    staging and cross-dock destinations, which are never diverted.
  - **P2.7 rule (f) ADDED** — tier 1 must reject a flowbin whose FLA belongs to a different SKU. Rule (e)'s
    tier-1 exemption was *strictly weaker* than the runtime rule it cited as justification. **1,344 of 2,068
    flowbins on `wms2-wineco-dev` already carry an FLA**, so this is the common case. §3.4c's P2.5 row called
    this relaxation "optional and harmless"; it is neither.
  - **SBDEV-2643's picker must exclude foreign-bound flowbins**, and `blockingReason` is this plan's enum to
    extend. 53% of the rows the picker would offer on wineco-dev are affected.
  - Recorded but not fixed: **Gap 2** (non-flowbin FLA at tiers 2/3 — unpopulated), **Gap 3** (P2.4 vs
    `verifyScannedLocation`'s `useforstorage` gate — unpopulated), and **P1's input column** (receiving reads
    `adviceposition.unitloadtype_id`, not `itemdata.defultype_id`; and `defultype_id` is an `itemdata` column,
    so the box's *"`ICE PACK`'s `defultype_id`"* attribution is wrong).
  - Also corrected: the review brief's claim that **r2's 603 figure "matches none of these tenants"** is
    false — it reproduces exactly on `wh01_hydra_v2`. The brief conflated hydra **PRD** with hydra **DEV**,
    both labelled "HMG".
  - **Confirmed sound, no change:** rule (e)'s `sltname == 'flowbin'` predicate (all
    `createFixedLocationAssignment` sites checked are flowbin-gated, so it tracks the mechanism exactly);
    keying on `sltname` rather than `location_type.id` (the id is 2 on fresh-seeded PRD, 50052 / 51502 on
    migrated tenants); and the P1 fail-open behaviour, which must stay — write-time P1 must never be stricter
    than runtime P1.
  - **Corroborated by implementation:** SBDEV-2821 (PR #135) shipped rule (f)'s predicate as SQL on
    `getPutAwayCandidateLocations` — the very method this plan extends to tiers 2–4 — reached independently
    from the code side and verified against live data. **Do not weaken that clause when extending it.**

- **2026-08-08 (later) — Q15 answered (A); THE SHIP ORDER REVERSED; the (iv-b) residue swept.** Q12 → (iv-b)
  landed earlier the same day but left five passages asserting the design it replaced. All corrected:
  - **Order is now `2731 PR1 → SBDEV-2821 → this plan`,** not the reverse. (iv-b)'s step-15 gate diverts
    pick-face destinations to the putaway lane, and only SBDEV-2821 makes them offerable there —
    `getStorageLocationsForPutAwayItemData` (`LocationRepository:104-111`) returns only locations where the
    SKU already has stock. `depends_on` gains SBDEV-2821; **§5.2 gains step 17a** (extend that surfacing from
    tier 1 to the full four-tier `Resolution`). Violating the order is degraded-not-broken — the operator can
    still scan the destination manually. §8.4.
  - **P2.5 and P2.7(c) lead-ins** still read *"Absolute reject at all three scopes"* above their own
    supersession notes. Marked DROPPED at the top of each cell, where an implementer reads first.
  - **§3.7's D15 scope note** still said the two predicates *"must stay absolute until SBDEV-2821 ships"* and
    that a receive-time gate would duplicate P2.6. Replaced: the gate tests what write-time validation
    deliberately no longer tests, so P2.6 does not apply to it.
  - **§3.5a's contract table** still returned 422 for a fix-assigned destination. Split: locked still 422;
    fix-assigned and pick-face are accepted.
  - **§7.1 and §5.2 step 7** still mandated `skuWriteRejectsFixAssignedLocation`,
    `skuWriteRejectsPickFaceDestination` and `merchantWriteRejectsFixAssignedLocation` — **tests that would
    fail a correct implementation.** Deleted, matching the four verify checks removed from the script
    (`V-fixloc`, `V-fixabs`, `T-skufix`, `T-merchfix`), and `skuWritePermitsPickFaceDestination` added so the
    relaxation is pinned positively rather than merely unpinned.
  - **§10.4 Q11's safety argument** rested on the configuration being unwritable. It is writable now — but
    the precondition it named ("if either predicate is relaxed *without answering this question*") was met:
    Q11 was answered 2026-08-06, two days before the relaxation.
  - **Lesson, and it is the same one as the orphaned message keys:** a decision recorded in one box does not
    propagate itself. When a rule moves from write-time to run-time, grep every passage that cites the old
    predicate — including the test tables and the verify script, which are the two places a stale rule turns
    into a red build that looks like honest work.

- **2026-08-06 (later) — reconciled against SBDEV-2731 revision 4.** 2731's plan was itself reconciled to
  its as-shipped code that day, which resolved the divergence flagged in the entry below. Three concrete
  impacts on this plan, all now fixed:
  - **The neutral message TEXT changed** (2731 review finding #4, commit `89de3f0`) and §3.6.1 quoted the
    superseded string. As-shipped is `Unit load type %1$s is not permitted on location %2$s (location type
    %3$s).` **The key NAME is unchanged**, so prerequisite 0 and the two-key split are unaffected.
  - **Three `Flowbin*` message keys are ORPHANED.** D14 relocated them here with Fix B; D15 then sent Fix B
    on to SBDEV-2821 and the keys did not follow. They exist only in 2731's document. Recorded in §8.4 as
    belonging to SBDEV-2821. **Third artifact orphaned by the same mechanism** (after F3/Q5 → SBDEV-2796 and
    the D15 bundle → SBDEV-2821): when a D-decision moves scope, enumerate what travels with it.
  - **2731 ships a tri-state `isPutawayDestinationApplied`** whose template comparison must stay `=== false`
    (`!null` is `true`, so a falsy rewrite restores the bug on first paint for exactly the tenants that
    configure alternate destinations). This plan edits the same template block, so it can break it —
    §3.11.1 now carries the requirement and `U-tristate` pins it.
  - 2731 independently confirms the **24 call sites** figure and the **second `receiveGoods` entry point**,
    both already corrected here.

- **2026-08-06 — second review pass (architect + critic), after the delta since 2026-08-04.** Four things had
  landed since the last review: Q11 answered, the Flyway renumber, SBDEV-2854 shipping adjacent
  destination-gating changes, and SBDEV-2731 PR1 reaching PR. Findings folded in:
  - **P2.7(c) clause 1 had no implementable predicate** — "not a pick face" was named but never defined,
    while §7.1 mandated a test for it. Now `location_area.useforpicking`, matching SBDEV-2854's
    `isPickingArea`. SBDEV-2854's data proved the gap was populated (70 FLA-free wineco club pick faces),
    which made a **tier-2/3** default onto a live pick face reachable — a route D15's warnings never
    covered, since those are all about tier 1 and about *relaxing* the predicates. **Measured 2026-08-06 and
    CONFIRMED LIVE, including on production:** `Storage and Picking` is `useforstorage = TRUE`, so the exposed
    set is **726** FLA-free pick faces on `wsl-wineco-uat` and **58** on `wms2-hydra` (HMG PRD) — an order of
    magnitude beyond the ~70 clubs inferred from SBDEV-2854's plan. **The measurement that missed it was taken
    on `wh01_hydra_v2t`, the one tenant that structurally cannot exhibit it** (no picking area there is also
    storage or goods-in). Re-run every P2 measurement against a migrated tenant, not only fresh-seed.
  - **Merge order 0b added.** The renumber to `V2.2.13` only protects tenants if SBDEV-2854's `V2.2.10`
    merges and applies **first**; the reverse order reproduces the exact silent-wedge the renumber avoids.
    Neither §5.1 row 1 nor the §8.1 table carried that constraint.
  - **"35 callers" was wrong in 11 places.** Measured: `transferUnitLoadToLocation` **24** call sites
    (**21** non-receiving, 3 from `ReceivingService`), `transferUnitLoadToCarrier` **9**, combined **33**.
    SBDEV-2731's own code review caught the same error independently. The §3.6.1 two-key argument survives
    unchanged at 24 — only the figure was wrong.
  - **`receiveGoods` has a second production caller** — `ReturnAdviceAutoReceiveService:556` (SBDEV-2778),
    whose consumer is OMS, a machine. Transactionally safe; the *error surface* is unmodelled (§3.6.2).
  - **Verify-script integrity.** `UBS-neg4` and `W-neg4` were vacuous bare negatives against symbols that
    exist nowhere and are now conjoined; `T-msg1` and `U-neg1` asserted things **contradicted by what
    SBDEV-2731 actually ships** (a retained label constant, a removed assertion surviving in a comment);
    `PHASE=1a` — which §11.1 told implementers to run — filtered every check and exited **0**. Baseline
    re-measured at **7 pass** across all three phases, and stable now that the vacuous checks fail closed.
  - **Meta-finding worth carrying forward:** several of this plan's assertions about what SBDEV-2731
    delivers were written against 2731's *plan*, and 2731's implementation diverged during its own code
    review. Every remaining "SBDEV-2731 PR1 owns this" claim — in §11.1 and in the script's skip reasons —
    needs one pass against the merged commits, not against the ticket.

- **2026-08-04 — D15/D16/D17/D18 (author decisions after the (c) answer).** **D15:** tier-1 pick-face
  placement **deferred** to a follow-up; this plan ships direct placement for tiers 2/3 only, which sends
  Fix B, C2b, Q1, Q4, F1, F4, F5 and Q11 out of scope and leaves the plan waiting on nothing unowned.
  Superseded: the post-(c) reading that this plan must absorb Fix B. **D16:** **one** migration,
  `V2.2.13__putaway_destination_hierarchy.sql` — supersedes §2.9's two reserved versions (both written as
  `V2.2.08`) and the `V2.2.08` number itself, taken by SBDEV-2801 on 2026-08-04. **D17:** the §6
  receipt-correction guard **stays**; correction is documented unavailable for directly-placed receipts —
  supersedes "decide whether to relax it", and required even under D15 because D13 rule (d) puts tiers 2/3
  on non-goods-in staging lanes. **D18:** review lane before approval; status stays `draft`.
- **2026-08-04 — SBDEV-2796 / Q5 answered (c), "bounds are advisory for receiving".** The single largest
  scope change since the draft. Superseded: the assumption that F3 would be answered restrictively (options
  (a) or (d)), which is what let this plan park 2731's Fix B, flowbin classification and resident-UL
  resolution as *gated scope* and justify D13 as "sidesteps F3". Under (c) none of that holds — Fix B
  survives and lands here, F1/F4/F5 become mandatory, C2b becomes the binding gate, and D13 keeps its rule
  but loses its stated reason. **P2.5 / P2.7(c) were briefly relaxed and then
  reverted the same day.** The relaxation (SKU scope rejecting only on FLA *mismatch*, tier 1 exempt from
  P2.7(c)) was correct about the runtime semantics but unsound in combination with D15: it permitted the
  tier-1 pick-face *configuration* while the *placement* path stayed ungated —
  `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally — which would put
  a second unit load on a location whose `assignedunitload_id` is `UNIQUE`. Both predicates are therefore
  **absolute at all three scopes**, and that is now the documented mechanism enforcing D15; the follow-up
  ticket relaxes them to the mismatch-only form when it ships tier-1 placement. Two of
  SBDEV-2796's own ACs did not survive its answer: the capacity-check AC is **voided**, and the
  replenishment-against-an-over-bound-bin AC is now **compulsory and open** (new **Q11**, owned by SBDEV-2821 from 2026-08-04). Full
  consequence list in the revision banner at the top of this document.

- **`putawayDestinationNotPermitted` moved out of `UnitloadBusinessService:191` and split into two keys** — that throw site serves 24 call sites, 21 of which have no configured putaway destination and for whom a "clear the configured destination" remedy is misleading (§3.6.1).
- **`Resolution` carries `compatible` instead of the resolver throwing** — the resolver must run on the carrier branch to fix 2731, but the destination is never applied there, so the throw became a separate caller-invoked `requireCompatible` (§3.1, D10).
- **A `readOnly = true` query facade was added between controllers and the `MANDATORY` resolver** — there is zero `@Transactional` under `controller/`, so a direct call would have thrown `IllegalTransactionStateException` on every request to the 2731 display endpoint (§3.1.5).
- **Tier 3 reads `findBySyskeyAndClientIdAndWorkstation`, not `findSysvalueByClientIdAndSyskey`** — the latter has no `workstation` predicate against a `(client_id, syskey, workstation)` unique constraint, so it returns an arbitrary row (landmine A6, §3.4a).
- **Merchant and warehouse writes became count-and-confirm rather than an absolute reject** — an absolute reject would have made the warehouse tier settable only to something type-equivalent to the lane it replaces, turning "ships inert" into a structural certainty (D11, §3.4c).
- **The event handler splits create from save, and validates the delta rather than the state** — a shared method would have broken every HAL `POST` of the three exported entities, and state validation would have turned existing config rot into an edit lock on unrelated fields (§3.9.2, §3.9.3).
- **The handler validates in `Before` and audits in `After`, and throws an unchecked `PutawayConfigValidationException`** — a single `@Transactional validateAndAudit` in `Before` would commit an audit row before SDR's save, letting the record outlive a failed write; and a checked `BusinessException` is swallowed into a 500 by SDR's reflective invoker (§3.9.6, §3.9.7).
- **`FlushModeType.COMMIT` was dropped from the previous-value read** — with OSIV off the merged entity is detached, so there is nothing to flush and the flush mode changes nothing (§3.9.5, closed Q6).
- **The backfill preflight guard, statement ordering and dropped `client_id` filter** — a scalar subquery aborts mid-migration on a duplicate lane name, the pre-image must precede the backfill or it silently records zero rows, and any client filter could diverge from tier 4's `findByName` (§5.1).
- **The migration split into `V2.2.13` (Phase 1) and `V2.2.13` (Phase 1)** — the phase boundary is tier *reachability*, not "does it need Flyway": leaving the `DROP NOT NULL` and backfill in 1b would have shipped a one-tier resolver that passed `PHASE=1` 0-fail. Only **b** adds a column an entity maps, so only **b** carries the operator-before-merge gate (D9, §5.2, §8.1).
- **`PutawayConfigController` added as the typed write surface** — without it the three writers had no callers, and D11's confirmation parameter has nowhere to live, since Spring Data REST discards unknown query parameters (§3.5a).
- **`SystemPropertyController`'s two direct-save endpoints were closed and the sysprop `DELETE` was brought under audit** — `@RepositoryEventHandler` fires only on Spring Data REST's own events, so a direct `repository.save()` bypasses the D7 guard entirely; delete is accepted because absent == not configured, paired with an unconditional Operation Options control so it cannot lock the tier out of the UI (§3.9.1, D12).
- **Authorization moved from the event-handler methods onto `PutawayConfigService`** — Spring Data REST may capture the raw handler target rather than the security proxy, in which case `@PreAuthorize` on a handler method is silently inert (§3.12, §3.9.4).
- **The mobile-putaway back-compat note now names `unitloadNotInInboundArea`** — `MobilePutAwayService:113-117` runs before the lane check, so a directly-placed unit load never reaches `unitLoadNotInPutAwayLane`; the recovery path (mobile Move Unit Load / web Transfer Stock) is named alongside it (§3.7.4, §6, M13/M13a).
- **The degraded path no longer presents an unverified destination as confirmed (review F3, wms2-web-ui PR #49 — merge `e702a42`, 2026-08-12)** — `loadPutawayDestination`'s catch left the seeded tier-1 value on screen, labelled `(SKU override)`, with no diversion notice. Each half was defensible and together they lied. **Silence stopped being neutral the moment this ticket gave the screen a vocabulary for diversions:** their absence now reads as *"not diverted, walk to the pick face"*. And the fallback is not tier-agnostic — the seed comes from `receiving_dto_view.defaultputawaylocationname`, a **tier-1-only** column, and tier 1 is exactly where SBDEV-2643 puts pick faces, which under (iv-b) are **always** diverted to the lane. So the degraded screen displayed the one tier most likely to have been re-routed, while suppressing the notice that says so. Resolved by keeping the value (it is correct whenever the default is not a pick face, so blanking discards usually-right information) and removing the certainty: the qualifier is suppressed and `#idPutawayUnconfirmed` explains what could not be checked and how to retry. **Rejected: a toast.** The existing comment's reasoning holds — this fires on every position change, so a toast turns an outage from degraded into unusable. Two boundaries were load-bearing: the flag is set in the **catch only**, because a 200 with no body is unreachable in production but *is* what SBDEV-2731's spec returns (`receivingForm.spec.js:45`), and treating it as failure would flip **T19/T22** (corrected 2026-08-12 — it said T24/T25, which the F3 review measured and disproved: those assert the ABSENCE of the qualifier, so suppressing it cannot flip them); and the resets moved **above** the `advicepositionid` guard, closing a third early-return path that let a previous position's diversion persist — the same bleed D14/D15 exist to prevent, through a door neither reached.
- **The diversion copy's argument ORDER is now pinned by a test and a verify row (wms2-api PR #148, 2026-08-11)** — the review lane on PR #47 transposed the two args of `putawayDestinationDivertedToLane` and **all 4927 API tests stayed green**. Two tests bracket that copy and neither owned the join: `ReceivingControllerUnitTest` mocks `ExceptionMessageService` with `anyString(), any(Object[].class)` and asserted only that `divertedReason` was non-empty, while `DiversionCopyUnitTest` deliberately asserts the *bundle* rather than the controller (the ResourceBundle parent chain makes child deletion invisible otherwise). Both choices are right in isolation; the gap was between them. A transposition is not cosmetic — it tells the operator the stock was received to the **pick face** and will move to the **lane**, the exact inversion of what happened, on the screen this ticket exists to make truthful, and the same defect class as SBDEV-2731. Closed with an `ArgumentCaptor<Object[]>` assertion (`containsExactly("Put Away Lane", "ICE PACK")`) plus the `P2-diverted-argorder` row. Also removed a dead ternary arm at `ReceivingController:139` — `r.location() == null ? "the configured destination" : …` was unreachable, since `PutawayDisplay.diverted()` already requires a resolved configured location, so it read as a guard while actually being a second silent copy variant no test could reach.
- **The location picker became tiered, with a lock warning on the advanced tier** — pointing a default at a live storage or pick location moves a `FOR UPDATE` onto a row picking and replenishment lock in the opposite order, in a codebase with no deadlock-retry infrastructure (§3.11.2, §7.6 row 8).

---

## 13. Notes

- **Reference workflow doc:** `sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md` §4.2 / §5.2 / §5.3. There is **no** receiving/putaway *design* doc in `sbdocs/3-Resources/design/` — consider writing one after this ships, since this plan introduces the first shared destination-resolution service.
- **Doc drift to fix after implementation:** the workflow doc's putaway section will need the four-tier precedence; `sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md` needs rows for `PutawayDestinationResolver` and `PutawayConfigService`. Run `/verify-docs` against the Phase-1 diff.
- **Migrated-copy id landmine:** on `wh01_hydra_v2` (v1→v2 migrated) `PutAwayLane` is `id=50155, type_id=50057, area_id=50104`; on `wh01_hydra_v2t` (fresh-seeded) it is `id=8, type_id=7`. **No test fixture or migration may assume low ids**, and the ticket's quoted ids (`unitloadtypeId=4`, `location type=2`) resolve on the **fresh** copy only.
- Neither Hydra copy contains an `Ice Pack` location — it exists only on NYWH UAT/prod, so M7/M10 must construct an equivalent incompatible pair (e.g. `Case` → a `flowbin` location) rather than looking for that name.
- **Status:** `draft` = pending approval. No source file under `v2/wms2-api/` or `v2/wms2-web-ui/` has been modified. Design review (`architect` + `critic`) is complete and folded in; §12 records what changed.
