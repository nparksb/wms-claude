---
title: "SBDEV-2731 — Alternate putaway location is displayed wrong and rejected on receive: receiving uses the whole-UL transfer primitive against a flowbin pick face"
ticket: "SBDEV-2731"
ticket_url: "https://app.clickup.com/t/868kgfuyf"
type: "bugfix"
severity: "high"
priority: "urgent"
status: "MERGED 2026-08-07 — wms2-api #133 @ 6bc709a + wms2-web-ui #39 @ 4ce39a1 on develop (opened 2026-08-06); plan reconciled to as-shipped code same day; PR2 SCOPE RELOCATED to SBDEV-2732 (D14, 2026-08-02) then ONWARD to SBDEV-2821 (2732 D15, 2026-08-04); F3/Q5 capacity owned by SBDEV-2796; this ticket closes on PR1"
project: ["wms2-api", "wms2-web-ui"]
version: "v2"
requester: "Brent Campbell"
assignee: "Nam Park / David Oppenheim"
created: "2026-07-31"
updated: "2026-08-06"
revision: 4
db_verified: true
depends_on: []   # none. SBDEV-2729 is referenced only as a precedent for PR staging (§9 D3),
                 # not as a dependency: nothing here consumes 2729's code. Recorded explicitly
                 # 2026-08-06 so the empty list reads as a decision, not an omission.
db_verified_note: >
  Verified 2026-07-31 against FOUR environments: HMG/hydra PRD (`wms2-hydra`,
  tunnel :25061), HMG/hydra UAT (`nywh-hydra-uat`, :25062), hydra dev
  (`wms2-hydra-dev2`, :25060) and wineco dev (`wms2-wineco-dev`). All reads were
  SELECT-only.

  "HMG" is the former name of the Hydra `nywh` warehouse (confirmed by the
  requester), so SBDEV-2729/2643's "HMG" and this ticket's "NYWH" are the same
  place. PRD is the reporting environment.

  PROVEN ON THE FAILING ROW (PRD): location `ICE PACK` = id 52075,
  `type_id = 2` (`flowbin`), whose only `location_constraint` row permits
  `unitloadtype_id = 1` (`PickLocation`). SKU `ICE PACK` = id 52072,
  `client_id = 0` (`System-Client`), `defultype_id = 4` (`Case`),
  `putawaylocation_id = 52075`. Case (4) into flowbin (2, allows only 1) yields
  the reported message verbatim. Root cause is certain, not inferred.

  ALSO PROVEN: `ICE PACK` is the ONLY SKU on PRD with a non-`PutAwayLane`
  destination (0 such SKUs on UAT and both dev tenants). Zero stockunits exist
  for SKU 52072, independently confirming the full rollback. The failing advice
  is still OPEN — adviceposition 52077 / advice IBOL000221 / notified 1000 /
  unitloadtype_id 4. `REQUIRE_RECEIVING_TO_CONTAINER = FALSE` on PRD, so the
  loose-case path is live and the defect is reachable.

  INVARIANT across all four environments: every OCCUPIED flowbin holds exactly
  one `PickLocation` unit load, 1:1 — 1,780 flowbin ULs, all `PickLocation`,
  ZERO `Case` ULs in any flowbin anywhere. Empty flowbins are a normal state
  (45 of PRD's 179).

  PRD flowbin cross-tab (has FixLocationAssignment × holds UL) has only two
  states: 45 (no, no) and 134 (yes, yes) — zero mixed — and 0 cases where an
  FLA's `assignedunitload_id` fails to resolve to a UL actually at that
  location. SKU 52072 has 0 FLA rows anywhere.
related:
  - sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md
  - sbdocs/1-Projects/wms2/plan/SBDEV-2729-system-sku-receiving-null-label-token.md
  - sbdocs/4-Archieves/wms1/plan/SBDEV-2229-transferStockToUnitLoad-toctou-lock-fix.md
tags:
  - plan
  - wms2
  - receiving
  - putaway
  - flowbin
  - fix-location-assignment
  - location-constraint
---

# SBDEV-2731 — Alternate putaway location is displayed wrong and rejected on receive

**Ticket:** [SBDEV-2731](https://app.clickup.com/t/868kgfuyf)
**Project:** wms2-api + wms2-web-ui | **Version:** v2 | **Type:** bugfix
**Priority:** urgent
**Status:** **MERGED 2026-08-07** — [wms2-api #133](https://github.com/SiteBossInc/wms2-api/pull/133) @ `6bc709a` + [wms2-web-ui #39](https://github.com/SiteBossInc/wms2-web-ui/pull/39) @ `4ce39a1`, both on `develop`.

> **This ticket closes on PR1 scope.** 6 of its 12 acceptance criteria are NOT delivered here and are owned elsewhere — including the headline *"Ice Pack SKU can be received successfully into the Ice Pack location"*, which belongs to [SBDEV-2821](https://app.clickup.com/t/868km8j9z). The full disposition is recorded on the ticket. **The reported 1,000-unit ICE PACK receipt still fails.** §5/§7/§8/§9 reconciled to as-shipped code 2026-08-06 — see §12
**Date:** 2026-07-31 (last updated 2026-08-06)

**Parent:** SBDEV-1938 (Receive to Different Location Other then Putaway)
**Config sibling:** SBDEV-2643 (Configure SKU Default Putaway Location in UI) — explicitly defers receiving behaviour to this ticket
**Prerequisite, already merged:** SBDEV-2729 (PR #108, merge `72a58d6`)

> **This is not a v2 regression.** v1 is equivalent line-for-line and carries all
> three defects — see §3.

---

## ⚠ SCOPE CHANGE — PR2 RELOCATED TO SBDEV-2732 (2026-08-02)

**This ticket now closes on PR1.** PR2's subject matter — `ReceivingService` destination resolution,
flowbin classification, resident-UL resolution, loop dispatch — is owned by **SBDEV-2732**, which holds
the four-tier putaway precedence contract. Two plans were rewriting the same method; 2732 is the right
owner. See `SBDEV-2732-configurable-default-putaway-location-hierarchy.md` §5.2 (decision D14).

**What 2732 imported: the OWNERSHIP, not the gated work.** 2732 deliberately did **not** absorb PR2's
four-item gate (Q5 / C2b / Q1 / Q4), because Q5 decides whether Fix B exists at all and C2b is a
confirmed destructive defect. Importing that would have re-blocked an otherwise-implementable plan.
**When Q5 is answered, whatever Fix B work survives lands in 2732 by construction — this ticket will be
closed.** The gate below therefore transfers with the subject matter; it is not discharged.

**Keep §§ F3, F4, F5, C2b and Q1–Q5 in this document.** They are the evidence trail behind 2732's
decision D13 (tiers 2 and 3 restricted to staging / goods-in areas) and behind the still-open product
question. Do not delete them because the code moved.

**⚠ CLOSING THIS TICKET DOES NOT FIX THE REPORTED FAILURE.** The ICE PACK case is 1,000 units into a
flowbin pick face via a **SKU-level (tier-1)** override. 2732's D13 exempts tier 1, and **F3 — no capacity
gate anywhere against `FixLocationAssignment` bounds of 36/60/84 — is unresolved.** PR1 makes the error
actionable and shows the operator the real destination, which is genuine value and should ship. **It is
not "receiving works."** Close this ticket with that stated explicitly, or the 1,000-unit receipt will
still fail and everyone will believe it was fixed.

**✅ THE REPORTED FAILURE NOW HAS AN OWNER — [SBDEV-2796](https://app.clickup.com/t/868kk4rmv)** (filed
2026-08-02). The §12 closing precondition is satisfied. 2796 holds the **Q5 product decision** (four
options, recommendation (d)), the **F3 capacity gate**, and **C2b**, and is tracked in 2732 §8.4 and
§10.4 Q10 as a **blocker on Phase 1b for tier-1 destinations**.

> **Why 2796 exists rather than leaving this with 2732.** The review found the handoff leaked in exactly
> one place that mattered: 2732 took the *code ownership* but D13 **exempts tier 1**, which is precisely
> the ICE PACK case — so the reported bug had no owner at all. Worse than "still broken": when 2732 Phase
> 1b ships direct placement, the receipt **succeeds**, putting 1,000 units into an 84-capacity bin and
> converting a visible rollback into a silent ~12× over-bound pick face that replenishment keys off.

---

## ⚠ REVIEW STATUS — read before implementing

### Second review pass — Architect + Critic, 2026-08-02 (post-D14 scope change)

Both lanes ran independently against the reduced scope and converged: the **D14 split is right in
direction but was leaky**, and PR1 was **NOT READY** as written — every blocker a document defect, with
the underlying Fix A / Fix C engineering sound. **All findings below are now actioned in this document.**

| # | Finding | Resolution |
|---|---|---|
| 1 | **F3/Q5 had no owner.** 2732 `:667` said "Tracked in §10"; it was not in 2732 §10.4 (Q1–Q9) or §8.4, and no follow-up ticket existed. | **[SBDEV-2796](https://app.clickup.com/t/868kk4rmv) filed.** Added to 2732 §8.4 + §10.4 Q10; 2732 `:667` now names it. |
| 2 | **Key-name collision.** 2731 shipped `BusinessException.UnitLoadTypeNotAllowedOnLocation`; 2732 declares `unitloadTypeNotPermittedOnLocation` at `:191` as a **hard prerequisite it consumes** (2732 §5.1 row 0, §7.2 step 6). 2732 would have failed on a key that never existed. | **Adopted 2732's name and neutral text** — §5 Fix C, §6, §7.2 step 2, `check_C1`/`M1`/`M2`/`M9`. |
| 3 | **Putaway remedy on a 35-caller primitive.** `:191` also serves picking, palletizing, truck loading, transfers, nirvana — 34 callers with no configured destination, for whom *"Update the SKU's Default Putaway Location"* is actively misleading. §0 row 17 had the evidence; the plan hadn't applied it. | **Remedy clause dropped.** New negatives `C6`/`M10` keep it out. |
| 4 | **`0 fail` was unreachable.** `M3`–`M8` assert the three `Flowbin*`/`SkuAlready*` keys, which §7.2 step 2 forbids in PR1 and routed to a PR2 that no longer exists. PR1's completed state was a **red** run. | **`M3`–`M8` converted to `skip`** with the same D14 reason as `B1`–`B15`. Not deleted — the spec must stay visible. |
| 5 | **Stale baseline.** §7.2 step 1 said `8 pass, 33 fail, 2 skip` and *"if it differs, develop has moved"*. It differs because the **script** moved. | **Baseline re-measured: `9 pass, 15 fail, 24 skip`.** All 15 fails verified to have teeth. |
| 6 | **Two incompatible Fix A templates**, and one was invalid Vue 2 — `DEFAULT_PUTAWAY_LANE_NAME` is module scope, and Vue 2 compiles with `with(this)`, so inside `{{ }}` it warns *"not defined on the instance"* and renders empty. | **§5 now states one template** (`{{ putawayDisplay }}`). `check_A1` retargeted. |
| 7 | **A pinned test breaks silently.** `UnitloadBusinessServiceUnitTest:207-208` asserts `.hasMessageContaining("not allowed on location")`, which no candidate message contains. §8.2 said *"extend"*. | **§8.2 now says rewrite `:193, 208`; never loosen.** |
| 8 | **Three `@InjectMocks` fixtures NPE** on the new constructor param — Mockito injects `null` for an unmatched param. | **§7.2 step 3 now adds `@Mock LocationTypeRepository` to all three.** |
| 9 | **`findNameById` returns null** for a missing id (JPQL scalar projection) → *"cannot hold a null unit load."* | **§5 Fix C now has a non-id fallback**, reconciled with T15. |
| 10 | **Fix A had zero behavioural coverage** — `RUN_TESTS=1` ran only maven, so T20a (the always-true-override guard) was unenforced. | **`A9` + `T3` added** with a `jest_test_passes` helper. |
| 11 | **RELOCATED marking missing at most contact points** — notably §5's `### Fix B` heading, reached after ~200 lines of copy-pasteable Java. Since B* became skips, following it turns the script **green on skips**, not red. | **Banners added** at §0 rows 3-6, §5 Fix B, §7.1, §7-HS, §7-V2, §8.1, §8.4, §11. |
| 12 | Three defects **in 2732** (not this plan's): `locationTypeRepository.findNameById` does not exist; `check_UBS_new_key` asserted the opposite of §3.6.1; `U-source` was skipped as "2731 PR1 owns this" when PR1 delivers a binary marker, not a tier source. | **All three fixed in 2732 + its verify script.** |

**Steelman that did not survive:** that PR2 should have stayed here, since 2731 is the customer-filed
urgent bug and 2731's own analysis is why 2732 knows what to build. It fails on one point — **Fix B was
never shippable** (Q5 unanswered, options (a)/(d) delete it outright, C2b confirmed destructive with T8
asserting the wrong behaviour as correct, F1 contradicting §5). Keeping it would have parked a
permanently-blocked PR2 inside an urgent ticket. Its two landed hits — nothing held the bug, and the
split was asymmetric on obligations — are both closed by SBDEV-2796.

**Cleared on the merits:** the `PutAwayLane` vs `Put Away Lane` analysis (called the plan's best work),
and verify-script trustworthiness — the repo's fail-open landmine is genuinely closed here
(`file_not_contains` and `file_contains_n_times` both carry `[ -f "$2" ] || return 1`).

**Still an open judgement call, deliberately NOT changed:** both lanes recommended dropping Fix A's
`(SKU override)` marker, because 2732 §3.11.1 replaces the whole label with a four-tier `sourceLabel`
chip off a new endpoint one phase later, making the marker throwaway. It is **kept** — it is specified,
tested and correct today, and deleting scope is the requester's call, not the reviewer's. See §5 Fix A's
interim note.

### First pass — Architect, 2026-07-31

Verdict **SOUND WITH RESERVATIONS**. The full write-up was never persisted to disk (the
`scratchpad/SBDEV-2731-architect-review.md` path referenced by earlier revisions does not exist); its
findings are the F1–F8.7 sections reproduced below, which remain the record.

**PR1 (Fix A + Fix C) is ready.** **PR2 (Fix B) is BLOCKED** — three HIGH findings,
all the same species: the plan models `createFixedLocationAssignment` and
`transferStockToUnitLoad` as narrower than they actually are. All three were
independently verified against the code and PRD before being accepted here.

### F3 (HIGH, CONFIRMED — the blocker) — Fix B would put 1,000 units into an 84-capacity bin

`FixLocationAssignment` carries `lowerbound` / `middlebound` / `upperbound`
(`model/FixLocationAssignment.java:19,22,25`). The 2-arg
`createFixedLocationAssignment(location, itemData)` seeds them from three
sysprops (`FixLocationAssignmentService.java:84-86`) — **on PRD those are
36 / 60 / 84, and all 134 existing FLAs sit at exactly `lowerbound=36`,
`upperbound=84`.**

The ticket's receipt is **1,000 units**. `transferStockToUnitLoad` has **no
capacity gate anywhere**, so Fix B would silently load a pick face to roughly
**12× its configured ceiling**, and replenishment logic keyed on those bounds
would then see a permanently over-bound bin.

This is the finding that blocks PR2. It is not a coding detail — it means
"receive 1,000 ice packs directly into a pick face" may be the wrong operation
regardless of which primitive is used, and needs a product answer (see Q5).

### F4 (HIGH, CONFIRMED) — auto-create drags replenishment into the receive transaction

`createFixedLocationAssignment:104` calls `triggerReplenishmentMaintenance(itemData.getId())`
→ `replenishmentOrderMaintenanceService.recalculateForItem(...)`, which is
`@Transactional(tenantTransactionManager, rollbackFor={BusinessException, FacadeException})`
(`ReplenishmentOrderMaintenanceService.java:111-112`) and whose downstream
`recalculateOrder` takes `findByIdForUpdate` on `Replenishorder`
(`:200-208`, and `:179` carrying the comment *"AC8: serialize w/ cron"*).

So D1′'s auto-create pulls **`Replenishorder` pessimistic locks into the receiving
transaction**. This invalidates three of my own claims: §7-HS row 2 ("no new
pooled connection"), E2 ("the FLA auto-create is the one non-idempotent effect"),
and **E3's "no cycle is introduced" — which never considered `Replenishorder` at
all**, though `ReplenishOrderJob` locks it first.

**Additional hazard, beyond the Architect's finding:** `triggerReplenishmentMaintenance`
swallows everything in `catch (Exception)` with a `LOG.warn`. Because
`recalculateForItem` is `REQUIRED` and joins the *receiving* transaction, a
`BusinessException` thrown inside it marks the shared transaction rollback-only —
so catching it does **not** rescue the receipt. It converts a clean failure into
an opaque `Transaction rolled back because it has been marked as rollback-only`
at commit, with the real cause only in a warn log.

### F5 (HIGH — conclusion confirmed, mechanism corrected)

The Architect reported the new `FOR UPDATE` source-Location lock as falling on the
tenant's `Spawn` row. **That mechanism is wrong.** `UnitloadService.createUnitload:171`
does `unitload.setStoragelocationId(location.getId())` where `location` is
`inboundWorkStation`; `spawnLocation` is only passed to
`unitloadRecordService.recordForCreateUnitLoad` as a *history* marker.

**But the conclusion stands, and is arguably worse.** The locked source row is the
single `STORAGE_LOCATION_INBOUND_NAME` location — which **all** receiving flows
through. And today's `transferUnitLoadToLocation` loads the source with a plain
`findById` (no lock), so Fix B introduces a **new tenant-wide serialisation point
on the Inbound location for every flowbin receipt**, held for the whole multi-case
transaction. E1's "contention is same-SKU only" is therefore wrong and must be
rewritten.

### Also fixed from the review

- Fix C's message told the operator to "change the location's type" — precisely
  the data-integrity trap §1.3 Q5 warns against. Reworded.
- `check_B15` greps for the literal `C2a` while §5 B3's comment said "§10 C2" — an
  implementer copying it verbatim would fail the script. Comment aligned.

### F1 (HIGH) — layering: receiving must not become a master-data mutator

Accepted. As sketched, `ReceivingService` gains `FixLocationAssignmentRepository`
**and** `FixLocationAssignmentService` and then *creates* an FLA — i.e. receiving
starts mutating replenishment master data, on a service that already carries ~24
dependencies. F4 is the concrete symptom: the write has effects the calling layer
cannot see.

⚠ **This acceptance is not yet reflected in the body, and the two disagree.** §5 Fix B
still sketches the method inside `ReceivingService` with three new dependencies, §6
lists that shape, and verify checks `B1`/`B5`/`B6`/`B7`/`B8`/`B13` all assert it — so
an implementer who follows *this* section turns the script red, and one who follows §5
reintroduces the layering violation. Deliberately left unreconciled until Q5 resolves,
because option (a) or (d) deletes Fix B entirely and the rework would be wasted. **Do
not code from §5 Fix B without reading this first.**

**If PR2 proceeds, move `resolveFlowbinResidentUnitload` into
`FixLocationAssignmentService`** (which already owns `createFixedLocationAssignment`,
the FLOWBIN guard at `:120`, and the replenishment trigger). `ReceivingService`
then takes **one** new dependency instead of three and simply asks for a resident
unit load. This also gives the extraction seam for F2 — the plan currently adds a
**fourth** copy of the flowbin-dispatch idiom (after `MobilePutAwayService:472-500`,
`StockunitService:181-213`, `MobilePutAwayService:263-283`), and D1′'s divergence is
an argument *for* a shared collaborator with an explicit policy parameter, not
against one.

### F8.7 (MEDIUM, actioned) — the acceptance gate could green with the C2 bug present

`check_B11` matches only the **name** `saveGoodsreceiptPosition`, which is satisfied
even if it is still called *before* the transfer — the very defect C2 fixes — and
`check_B15` is only a comment marker. The real guards are T8/T8a, which skip when
`RUN_TESTS=0`. So `Result: N pass, 0 fail` was reachable with the corruption in
place. **Fixed:** the script now exits `2` with `NOT ACCEPTANCE` if all checks pass
while `RUN_TESTS != 1`. §8.5's final acceptance run must use `RUN_TESTS=1`.

### C2b (BLOCKING, CONFIRMED) — C2's reordering would make receipt correction destructive

Found by the Critic pass; **verified**. Receipt corrections run through
`GoodsReceiptPositionService`, live via `GoodsReceiptPositionController:72,104`:

- `delete` (`:159-167`): `stockunitRepository.findById(position.getStockunitId())`
  → `stockunitBusinessService.sendStockUnitToNirvana(stockUnit, STOCK_REMOVED, …)`
  → then `unitloadRepository.findById(position.getUnitloadId())`.
- `adjust` (`:84-88`): same `position.getStockunitId()` read.

**C2 as written repoints those fields at the resident pick-face rows.** So deleting
or adjusting a single goods-receipt position would call `sendStockUnitToNirvana` on
**the entire flowbin balance** and then operate on the FLA's assigned unit load —
wiping the bin for a one-case correction, and retiring the assignment's UL.

So C2 inverts: keeping `GRP` pointed at the **transient** Case UL is arguably
*safer*, because `sendToNirvana` retires that row (relocated, `entity_lock =
GOING_TO_DELETE`, `labelid` mangled) rather than deleting it — a correction would
then act on an emptied, retired UL instead of live pick-face stock. The
reporting-fidelity concern that motivated C2 is strictly cosmetic by comparison.

**Three candidate resolutions, to be decided with Q5 (none chosen yet):**
1. Leave the GRP write where it is; accept the retired-row reference; document the
   mangled-label reporting oddity.
2. Keep C2's reordering **and** make `adjust`/`delete` reject flowbin-routed
   positions with an actionable message — larger scope, touches a second service.
3. Record both: transient ids for correction, destination ids in a new column —
   schema change, out of scope here.

**Method lesson for §0:** my enumeration grepped callers of the *symbols I was
changing*. This consumer reads a **field** (`GRP.stockunitId`) that no changed
symbol mentions, so the method structurally could not surface it. Any future plan
that repoints a persisted FK must grep readers of the **column/field**, not just
callers of the method. **T8 as written asserts the defective state as correct and
must not be implemented until this is resolved.**

### Steelman that survives

The Architect's antithesis — that this belongs in **SBDEV-2643's config validator**
(reject flowbins as configurable destinations, making Bug B unreachable in one
place) — is materially strengthened by F3. It also lands a hit I have to concede:
**D1′'s premise that "the operator recorded intent unambiguously" is contradicted
by my own §0 row 16**, since `putawaylocation_id` is writable by an unvalidated
CSV import (`FileImportController.java:383`). An import typo is not intent.

---

## 0. Affected sites (enumeration before drafting)

Built by grep, not memory. Every **IN** row is visited by §5 Fix Design; every
**OUT** row carries a rationale.

| # | File:line | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `wms2-web-ui` `components/receiving/open/receive/receivingForm.vue:12` | hard-coded literal `Put Away Lane` | Bug A | **IN** — Fix A |
| 2 | `wms2-web-ui` `receivingForm.vue:206` | dead `putawayStaging` data prop, never bound | Bug A | **IN** — Fix A |
| 3 | `ReceivingService.java:454-457` | `putAwayLocation` resolved only when `carrier == null` | Bug B / D2 | **→ SBDEV-2732 (D14)** — was Fix B |
| 4 | `ReceivingService.java:492` | `transferUnitLoadToLocation` — wrong primitive for a flowbin | Bug B (primary) | **→ SBDEV-2732 (D14)** — was Fix B |
| 5 | `ReceivingService.java:479-486` | `Goodsreceiptposition` built + saved **before** the transfer | consequence C2 | **→ SBDEV-2732 (D14)** — was Fix B; see C2b before touching |
| 6 | `ReceivingService.java:495` | `createCaseLabel` for a UL that the flowbin path retires | consequence C1 | **→ SBDEV-2732 (D14)** — was Fix B |
| 7 | `UnitloadBusinessService.java:180-190` | `location_constraint` exact-match gate — **logic is correct, keep it** | symptom source | **IN** — Fix C (message only) |
| 8 | `UnitloadBusinessService.java:191` | raw concatenated, ID-laden `BusinessException` | Bug C | **IN** — Fix C |
| 9 | `ReceivingController.java:285-286` | `BusinessException` surfaced verbatim to the operator | Bug C | **IN** — Fix C |
| 10 | `StockunitService.java:189,198` | raw concatenated flowbin messages (`"SKU already assigned to flow bin "`, `"Flow bin has different SKU "`) | same class as Bug C | **OUT** — adjacent; different workflow (manual move stock). File as a follow-up. Fix C's new keys are named so this path can adopt them later without renaming. |
| 11 | `MobilePutAwayService.java:472-500` | **precedent P1** — flowbin ⇒ `transferStockToUnitLoad` into the FLA resident UL | not a defect | N/A — source of the fix pattern |
| 12 | `StockunitService.java:181-213` | **precedent P2** — same dispatch + both rejection branches | not a defect | N/A — source of the fix pattern |
| 13 | `MobilePutAwayService.java:263-283` | **precedent P3** — same FLOWBIN/OVERSTOCK classification for target suggestion | not a defect | N/A |
| 14 | `FixLocationAssignmentService.java:120` | refuses to create an FLA unless the location type is FLOWBIN | constraint to respect | N/A — Fix B reuses this service |
| 15 | `V2.2.00__base_v2_schema.sql:4663` + `model/ReceivingDtoView.java:47,173` | `receiving_dto_view.defaultputawaylocationname` already exposes the destination | already correct | N/A — Fix A consumes it |
| 16 | `ItemdataService.java:72`, `ItemDataController.java:90`, `SkuBatchCreateUpdateService.java:53`, `FileImportController.java:383` | write `putawaylocation_id` with no location-type / stock-eligibility validation | related | **OUT** — SBDEV-2643 owns config-time validation |
| 17 | 24 other `transferUnitLoadToLocation` call sites | `MobileTransferOrderService:392`; `MobilePutAwayService:148,183,185,206,494,498`; `ParcelMonitorViewService:394`; `FixLocationAssignmentService:162`; `MobileMoveUnitloadService:319,446,450`; `ReceivingService:616,637`; `UnitloadBusinessService:346,428,446`; `MobileTruckLoadingService:244`; `PickingorderBusinessService:310`; `CustomerorderService:573`; `StockunitService:213,338`; `MobilePickingService:535` | no — each passes a destination already type-compatible, or is itself the nirvana/clearing path | **OUT** — enumerated and cleared |

### 0.1 Why row 4 is the primary site

`receiveGoods` is the **only** caller that passes a *SKU-configured, operator-chosen*
destination into `transferUnitLoadToLocation` without first classifying the
location type. Every other caller either targets a known-compatible location
(gates, lanes, clearing, nirvana, empty-pallet pools) or does classify —
rows 11-13. Receiving is the one gap.

---

## 1. Problem Statement

### 1.1 User-visible symptom

A SKU with an alternate Default Putaway Location configured shows the **wrong
destination** on the receiving screen, and completing the receipt fails with:

```
Unit load type ID 4 not allowed on location Ice Pack with location type ID 2
```

The receipt rolls back entirely — no inventory is created, and the operator
cannot receive the goods at all.

Reported against warehouse NYWH (= HMG), SKU `ICE PACK`, configured destination
`Ice Pack`, quantity 1000.

### 1.2 Reproduction

1. Configure a SKU's `itemdata.putawaylocation_id` to a **flowbin** (pick-face)
   location. On PRD this is already the live state for SKU `ICE PACK`.
2. Create an inbound BOL for that SKU and open the receiving workflow.
3. Observe the screen shows `Put Away Lane` regardless of the configured value.
4. Receive without a carrier pallet (`REQUIRE_RECEIVING_TO_CONTAINER = FALSE`).
5. The receipt fails with the message above; no stock is created.

The originating advice is **still open on PRD** and can be used as the
reproduction vehicle: adviceposition `52077`, advice `IBOL000221`, notified
`1000`, `unitloadtype_id = 4`.

### 1.3 DB verification (analysis-protocol gate §8) — `db_verified: true`

All queries SELECT-only. "HMG" is the former name of Hydra `nywh`, so
`wms2-hydra` (PRD) and `nywh-hydra-uat` (UAT) are that tenant; PRD is where the
defect was reported.

**Q1 — the failing rows (PRD).**

```sql
SELECT l.id, l.name, l.type_id, lt.sltname,
       (SELECT string_agg(lc.unitloadtype_id::text,',') FROM location_constraint lc
         WHERE lc.storagelocationtype_id = l.type_id) AS allowed_ul
FROM location l JOIN location_type lt ON lt.id = l.type_id
WHERE l.name ILIKE '%ice%';
```
→ `52075 | ICE PACK | 2 | flowbin | 1` — area "Storage and Picking",
`useforstorage = t`, `entity_lock = 0`.

```sql
SELECT id, item_nr, client_id, defultype_id, putawaylocation_id
FROM itemdata WHERE item_nr = 'ICE PACK';
```
→ `52072 | ICE PACK | 0 (System-Client) | 4 (Case) | 52075`.

**Case (4) into a flowbin that permits only PickLocation (1) reproduces the
reported message exactly.** The diagnosis is proven on the live row, not
inferred from the seed.

**Q2 — why dev and UAT could not reproduce it.** PRD carries the **canonical**
`location_type` ids `0-7` (fresh-provisioned from `V2.2.00__base_v2_schema.sql`,
where `2 = flowbin`). UAT and both dev tenants are **v1→v2 migrated** and their
ids are `1, 50051-50057` — **there is no id 2 at all**. That is why the ticket's
"location type ID 2" is unreproducible off PRD.

**Q3 — blast radius.** `ICE PACK` is the **only** SKU on PRD with a
non-`PutAwayLane` destination; UAT, hydra-dev and wineco-dev have **zero**. The
alternate-destination feature is effectively unexercised in production.

**Q4 — the rollback claim.** `SELECT count(*) FROM stockunit WHERE itemdata_id = 52072`
→ **0 rows, 0 total amount.** Nothing was ever partially received, which
independently confirms the `@Transactional(rollbackFor = …)` analysis in §2.3.

**Q5 — the flowbin invariant, four environments.**

| Environment | flowbin ULs | distinct flowbin locations | `Case` ULs in a flowbin |
|---|---|---|---|
| wineco-dev | `PickLocation` × 1344 | 1344 | **0** |
| hydra-dev | `PickLocation` × 154 | 154 | **0** |
| hydra-UAT | `PickLocation` × 148 | 148 | **0** |
| **hydra-PRD** | `PickLocation` × 134 | 134 | **0** |

**1,780 flowbin unit loads across four independent tenants; every one is a
`PickLocation`; not a single `Case` UL has ever occupied a flowbin.** Every
*occupied* flowbin is exactly 1:1. Empty flowbins are normal — 45 of PRD's 179.

This is the load-bearing evidence for §5 Fix B: **retyping the `ICE PACK`
location to dodge the constraint is a data-integrity trap, not a config
workaround.** It would put a `Case` UL into a pick face for the first time in
the system's history and break the invariant that replenishment and picking rely
on.

**Q6 — FLA ↔ UL pairing (PRD), which sets the Fix B guard.**

```sql
SELECT (fla.id IS NOT NULL) AS has_fla,
       EXISTS (SELECT 1 FROM unitload u WHERE u.storagelocation_id = l.id) AS has_ul,
       count(*)
FROM location l LEFT JOIN fix_location_assignment fla ON fla.assignedlocation_id = l.id
WHERE l.type_id = 2 GROUP BY 1,2;
```
→ only two states: `f,f → 45` and `t,t → 134`. **Zero mixed.** Plus **0** cases
where an FLA's `assignedunitload_id` fails to resolve to a UL actually at that
location, and **0** FLA rows for SKU `52072` anywhere.

So `has_fla ⟺ has_ul` on real data, and `ICE PACK` sits squarely in the clean
"empty, unassigned" case — which is what makes D1′ (§10) safe.

**Q7 — sysprops.** `REQUIRE_RECEIVING_TO_CONTAINER = FALSE` on PRD (so the
loose-case path is live); `INBOUND_UPDATE_STOCK_IMMEDIATELY = true`;
`MAXIMUM_RECEIVING_DURING_INBOUND = 1000`. **On UAT the
`REQUIRE_RECEIVING_TO_CONTAINER` row is absent entirely** — harmless today
(`Boolean.parseBoolean(null)` is `false`) but worth noting for anyone testing
the D2 carrier branch on UAT.

---

## 2. Root Cause Analysis

### Bug A — the destination is never displayed (UI, data-independent)

`v2/wms2-web-ui/components/receiving/open/receive/receivingForm.vue:9-13`:

```html
<label for="idPutawayString" class="font-weight-bold">Inbound Putaway Staging</label>
...
<label class="ml-4">Put Away Lane</label>   <!-- HARD-CODED -->
```

The screen renders a **constant**. The `putawayStaging` data property declared at
line 206 is never bound to anything — grep confirms exactly one occurrence in
the file.

The real value is already on the wire and needs no backend work:
`receiving_dto_view.defaultputawaylocationname`
(`V2.2.00__base_v2_schema.sql:4663`, `LEFT JOIN location loc ON loc.id = itemdata.putawaylocation_id`),
surfaced by `ReceivingDtoView.java:47,173`, and the component already fetches
that payload at `receivingForm.vue:357`
(`/receivingDtoView/search/findByAdvicepositionid`). This is a bind-the-existing-field fix.

This is data-independent: it misreports for **every** SKU with an override, on
every tenant, and always has.

### Bug B — the destination IS honoured, then rejected (routing, PRIMARY)

`ReceivingService.java:454-457` does resolve the override — but only without a carrier:

```java
Location putAwayLocation = (carrier == null)
    ? locationRepository.findById(itemdata.getPutawaylocationId())
        .orElseThrow(() -> new BusinessException("entityNotFoundForId", …))
    : null;
```

then `:492` moves the whole freshly-created unit load there:

```java
unitloadBusinessService.transferUnitLoadToLocation(
    unitload, putAwayLocation, false, codeReceiving, adviceposition.getNumber(), null);
```

`UnitloadBusinessService.java:180-190` then correctly refuses:

```java
List<LocationConstraint> locationConstraintList =
    locationConstraintRepository.findByStoragelocationtypeId(destinationLocation.getTypeId());
if (locationConstraintList != null && !locationConstraintList.isEmpty()) {
    // exact unitloadtype match required
    throw new BusinessException("unitloadtypeId=" + unitload.getTypeId() + …);
}
```

The UL type is `adviceposition.getUnitloadtypeId()` (← `itemdata.defultype_id`),
resolved at `:399` — universally `4` (`Case`).

**Two things make this a design gap rather than a bad check:**

1. The gate is **skipped entirely** when the destination's type has no
   `location_constraint` rows. That is the only reason `PutAwayLane` (type
   `cases and pallets`) works — see §1.3 Q1.
2. A flowbin is *modelled* to hold one permanent `PickLocation` UL fed by
   replenishment (§1.3 Q5, 1,780 ULs, zero exceptions). Moving a `Case` UL onto
   it is foreign to the model — so the correct fix is **the right primitive**,
   not a relaxed constraint.

**The primitive already exists, in three places** (§0 rows 11-13). The idiom is:
classify the destination by `LocationType.sltname`; **flowbin ⇒ move the STOCK
into the flowbin's resident FLA unit load; otherwise ⇒ move the whole UL.**
`MobilePutAwayService.java:472-500` is the closest analogue — it is doing the
same job (getting received goods into a pick face) from the mobile putaway
screen. Receiving is the one place that never learned the dispatch.

`sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md` documents both
halves: §5.1-5.2 the dispatch, §4.2 receiving's unconditional transfer.

**Bug B also has a silent-discard half (D2).** Because `:454` guards on
`carrier == null`, a SKU with an override received **onto a carrier pallet** has
its configured destination dropped with no message at all. The ticket forbids
this explicitly: *"The system should not silently ignore the configured
destination or route inventory elsewhere."* Latent on PRD today
(`REQUIRE_RECEIVING_TO_CONTAINER = FALSE`) but reachable whenever an operator
selects a pallet.

### Bug C — the error is not actionable, and nothing validates before submit

`UnitloadBusinessService.java:191` throws a **raw concatenated string** — no
message-bundle key, internal IDs only, no SKU context. `ReceivingController.java:285-286`
passes it straight through:

```java
} catch (BusinessException e) {
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
```

So the operator sees `unitloadtypeId=4 not allowed on location=Ice Pack with
location type=2` under the heading "Runtime Error".

Note **SBDEV-2729 did not fix this.** PR #108 routed unexpected
`RuntimeException`s to a generic operator message and added the receive-loop
`LOG.error` — which does now capture this failure with business context. But a
`BusinessException` is deliberately surfaced verbatim, so the ID-laden text still
reaches the screen.

### 2.3 No partial commit (answers the ticket's open question)

The ticket asks *"whether the receipt partially succeeds before the error."*
It does not. `receiveGoods` is annotated at `:302`:

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
```

The throw lands on loop iteration 1, after a `Unitload`, `Stockunit`,
`Stockrecord` and `Goodsreceiptposition` have been written — all of which roll
back. §1.3 Q4 confirms it empirically: zero stockunits exist for the SKU after
repeated operator attempts. The only residue is sequence-number gap burn.

---

## 3. Not a regression — v1 parity

There is no regression chain. v1 is equivalent line-for-line and carries all
three defects:

| Defect | v2 | v1 |
|---|---|---|
| Bug A hard-coded label | `wms2-web-ui receivingForm.vue:12` | `wms-web-ui receivingForm.vue:12` (identical) |
| Bug B wrong primitive | `ReceivingService.java:492` | `ReceivingService.java:521-523` |
| Bug C raw message | `UnitloadBusinessService.java:191` | `UnitloadBusinessService.java:138` |

**SBDEV-2642 ("V1 Fix: Ability to Set Default PutAway other then PutAway") is
Closed, but `git log --all --grep=2642` in `v1/wms-api` returns nothing** — it was
closed without a code change. The v1 "fix" was configuring a destination whose
location type accepts a `Case` UL. Per D4 this plan is v2-only; v1 parity is
recorded for the sync sweep.

---

## 4. Architecture Overview

```
Receiving workstation (wms2-web-ui)
  receivingForm.vue
    :357  GET /receivingDtoView/search/findByAdvicepositionid
            → receiving_dto_view.defaultputawaylocationname   ← Bug A ignores this
    :12   renders the literal "Put Away Lane"                 ← Bug A
    POST /receiving/receive
       │
       ▼
ReceivingController.receive  :267-301
    :285  catch BusinessException → getErrorMessage(...e.getMessage())   ← Bug C
       │
       ▼
ReceivingService.receiveGoods  :302  @Transactional(tenantTransactionManager, rollbackFor=…)
    :344  advicepositionRepository.findByIdForUpdate    ← pessimistic lock held for the whole method
    :399  unitloadType ← adviceposition.getUnitloadtypeId()   (= 4 Case)
    :454  putAwayLocation ← itemdata.putawaylocation_id  ONLY IF carrier == null   ← Bug B / D2
    :462  while (amountBottles > 0)                      one iteration per case
    :472    createUnitload(inboundWorkStation, type 4, …)
    :474    createStockUnit(...)
    :479      Goodsreceiptposition built + saved         ← C2 (written pre-transfer)
    :492    transferUnitLoadToLocation(unitload, putAwayLocation, …)   ← Bug B PRIMARY
                 │
                 ▼
            UnitloadBusinessService  :180  location_constraint gate
                 :191  throw BusinessException("unitloadtypeId=… not allowed …")   ← Bug C
    :495    createCaseLabel(unitload, …)                 ← C1
```

### Key files

| File | Lines | Role |
|---|---|---|
| `wms2-web-ui/components/receiving/open/receive/receivingForm.vue` | 9-13, 206, 357 | Receiving screen; hard-coded destination label |
| `wms2-api/.../service/ReceivingService.java` | 302, 344, 399, 454-457, 462-499 | `receiveGoods`; destination resolution + per-case loop |
| `wms2-api/.../service/UnitloadBusinessService.java` | 180-191, 330-352 | Constraint gate; `sendToNirvana` (soft retire) |
| `wms2-api/.../service/StockunitBusinessService.java` | 179-188, 192-201, 209-290 | `transferStockToUnitLoad`; canonical lock order |
| `wms2-api/.../service/mobile/MobilePutAwayService.java` | 472-500 | **Precedent P1** — the flowbin dispatch to copy |
| `wms2-api/.../service/StockunitService.java` | 181-213 | **Precedent P2** — dispatch + both rejection branches |
| `wms2-api/.../service/FixLocationAssignmentService.java` | 120, 162 | FLA creation; FLOWBIN-only guard |
| `wms2-api/.../controller/ReceivingController.java` | 267-301, 318-322 | `/receive`; `REQUIRE_RECEIVING_TO_CONTAINER` |
| `wms2-api/src/main/resources/messages.properties` | 1 | Base bundle (locale-independent) — Fix C |
| `wms2-api/src/main/resources/messages_en_US.properties` | 1-8 | en_US bundle — Fix C |

---

## 5. Fix Design

### Fix A — bind the receiving screen to the real destination

**File:** `v2/wms2-web-ui/components/receiving/open/receive/receivingForm.vue`
**PR:** 1

Before (`:9-13`):

```html
<td><label for="idPutawayString" class="font-weight-bold">Inbound Putaway Staging</label></td>
<td><label class="ml-4">Put Away Lane</label></td>
```

After — render the effective destination, and distinguish the standard lane from
an explicit override (wording per SBDEV-2643):

```html
<td><label id="lblPutawayString" class="font-weight-bold">Default Putaway Location</label></td>
<td>
  <span id="idPutawayString" aria-labelledby="lblPutawayString" class="ml-4">
    {{ putawayDisplay }}
    <span v-if="isPutawayOverride" class="text--secondary"> (SKU override)</span>
    <span v-if="isPutawayDestinationApplied === false" class="text--secondary"> (not used — receiving to container)</span>
  </span>
</td>
```

> ### ⚠ AMENDED DURING IMPLEMENTATION (2026-08-02) — review finding M1
>
> **The block above is as-shipped. An earlier revision omitted `isPutawayDestinationApplied` and the
> second qualifier span, and that version was wrong.**
>
> `ReceivingService.java:454-457` resolves the SKU's configured destination **only when
> `carrier == null`** — on the container path `putAwayLocation` is never even looked up (it is literally
> `null`) and `:492` routes to `transferUnitLoadToCarrier`. The UI posts
> `carrierUnitloadId = (noContainer ? null : parentContainer.unitLoadId)` and `validate()` rejects
> `!parentContainer && !noContainer`, so at submit time:
>
> | State | Posted carrier | Destination honoured? |
> |---|---|---|
> | `noContainer === true` | `null` | **yes** |
> | `noContainer === false` | non-null (validate guarantees it) | **no** — UL goes onto the carrier |
>
> Without the guard the screen asserted `ICE PACK (SKU override)` on **both** paths — claiming a
> destination the receipt then ignores. For tenants with `REQUIRE_RECEIVING_TO_CONTAINER` **on**, the
> opt-out switch is not even rendered (`v-if="!requireReceiveToContainer"`), so `noContainer` is pinned
> `false` and *every* receipt took the ignoring path. That directly contradicts the one AC this plan
> claims PR1 satisfies — *"receiving screen clearly displays the effective destination"*.
>
> **As shipped — SUPERSEDED 2026-08-06, see the TRI-STATE box below.** This box's original text read
> *"`isPutawayDestinationApplied() { return this.noContainer === true }`; `isPutawayOverride` ANDs it; the
> qualifier renders when it is false."* That binary form **shipped in `94e87d2` and was then corrected in
> `04175fa`** — the two-row table above is only true at submit time, and the screen renders long before
> submit. Read the tri-state box before touching this computed.
>
> **Why the value stays visible rather than being blanked.** The field is labelled *"Default Putaway
> Location"* — SKU **configuration**, which is true on both paths and is what the operator would go and
> change. Blanking would delete real information and could not distinguish *"no destination configured"*
> from *"destination not used this time"*. Both review lanes independently endorsed value-plus-qualifier
> over blanking. The qualifier deliberately does **not** name where the goods *do* go: the UL goes onto
> the carrier and reaches no location until a later operator-scanned putaway
> (`MobilePutAwayService:148/183/206/494`), so naming a destination there would be a fresh false claim —
> and naming the carrier is scope creep into SBDEV-2732 §3.11.1.
>
> **Wording** (`(not used — receiving to container)`, chosen by the requester 2026-08-02): leads with the
> consequence, not the mechanism, and is parenthetical to match the sibling `(SKU override)` chip. The
> earlier bare form `— receiving to container` was rejected because it parses as *"receiving ICE PACK into
> a container"* — silent on whether the ICE PACK **location** applies, i.e. the same ambiguity M1 exists
> to remove. Pinned exactly by `T21`.
>
> ⚠ ~~**Known limitation, accepted:** the equivalence is exact **at submit time**. Before the operator
> chooses, `noContainer` defaults to `false`, so the field shows the qualifier as a *prediction* of the
> default path. Correct at the only moment that matters — `validate()` gates submit — but call it out in
> §8.4 row 1 so it is not re-reported as a bug.~~
>
> ### ⚠ TRI-STATE — this limitation was NOT acceptable, and is fixed (2026-08-06, review finding #1, commit `04175fa`)
>
> The paragraph struck through above was wrong to accept. "A prediction of the default path" is a
> **claim the operator has not made and cannot yet submit** — `validate():470` rejects
> `!parentContainer && !noContainer`, so the state the qualifier described is precisely the state in
> which no receipt can happen. And it was not an edge case: it is the **first paint on every tenant with
> `REQUIRE_RECEIVING_TO_CONTAINER = false`**, i.e. exactly the population that configures alternate
> putaway locations. Shipping it would have re-created M1's defect with the sign flipped — the screen
> asserting a destination-truth the submit path has not established.
>
> The form has **three** states, so the computed returns three values:
>
> ```js
> isPutawayDestinationApplied() {
>   if (this.noContainer === true) return true
>   if (this.requireReceiveToContainer === true || this.parentContainer) return false
>   return null
> }
> ```
>
> | Condition | Value | Meaning |
> |---|---|---|
> | `noContainer === true` | `true` | destination IS honoured |
> | `requireReceiveToContainer === true` | `false` | container mandated, switch hidden, `noContainer` can never become true |
> | `parentContainer` set | `false` | operator chose a container |
> | otherwise | `null` | **undetermined — render no qualifier** |
>
> Two things are load-bearing and must not be "simplified":
>
> 1. **The template tests `=== false`, never `!`.** `!null` is `true`, so a falsy test restores the exact
>    bug. Pinned statically by verify check `A10` and behaviourally by `T24`.
> 2. **The `requireReceiveToContainer` clause.** Drop it and the container-mandating tenant — where the
>    qualifier is correct and needs no operator action — falls through to `null` and says nothing.
>    Pinned by `T25`.
>
> `isPutawayOverride` correspondingly ANDs on `=== true`, not on truthiness.

> ⚠ **Two corrections from the 2026-08-02 review — both were real defects.**
>
> 1. **This block previously interpolated `{{ putawayStaging || DEFAULT_PUTAWAY_LANE_NAME }}`, which does
>    not work.** `DEFAULT_PUTAWAY_LANE_NAME` is a module-scope `const` (the `<script>` block opens at
>    `receivingForm.vue:198`, `export default` at `:202`). Vue 2 compiles render functions with
>    `with(this)`, so an identifier inside `{{ }}` resolves **only** against the component instance —
>    Vue logs *"Property or method 'DEFAULT_PUTAWAY_LANE_NAME' is not defined on the instance but
>    referenced during render"* and renders **empty**. Inside a `computed` the same const is fine
>    (ordinary closure over module scope), which is why `putawayDisplay` is the correct seam. The
>    document also stated both templates in two places and they contradicted each other; **this is now
>    the only template**, and `check_A1` pins `{{ putawayDisplay`.
> 2. **The element was a `<label id="idPutawayString">` while `:9` already has
>    `<label for="idPutawayString">`.** `for` must reference a *labelable* form element, which a second
>    `<label>` is not. Changed to a `<span>`.
>
>    ⚠ **CORRECTED AGAIN during implementation (2026-08-02) — correction 2 was itself incomplete.**
>    A `<span>` is **not labelable either** (`for` accepts only `input` / `select` / `textarea` /
>    `button` / `meter` / `output` / `progress`), so swapping `<label>` for `<span>` left `for` just as
>    inert — it simply moved from "dangling id" to "non-labelable target". Neither form creates a
>    programmatic association. Found independently by both the implementation pass and the code-review
>    lane. **As shipped:** `<label id="lblPutawayString">` + `<span id="idPutawayString"
>    aria-labelledby="lblPutawayString">`, with `for` dropped. SBDEV-2732 must not inherit the
>    assumption that the `<span>` change fixed this.

**Interim by design.** This binds `defaultputawaylocationname` off `receiving_dto_view` and derives a
**binary** override marker by comparing to `PutAwayLane`. SBDEV-2732 §3.11.1 replaces the data source one
phase later with `GET /receiving/getPutawayDestination/{advicePositionId}` (§3.8), rendering
`locationName` plus a **four-tier `sourceLabel` chip** and a `compatible === false` banner — at which
point `putawayDisplay`, `isPutawayOverride` and both constants are deleted. That is correct: tier 1 is
the only tier that exists today, and 2732 §5.1 row 0 makes this binding its hard prerequisite. The
follow-up note at the end of this section is therefore **already owned by 2732**, not unassigned.

> ⚠ **The lane's name is `PutAwayLane`, NOT `Put Away Lane`.**
> `WmsConstants.java:771` defines `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"`,
> and `ReceivingService.java:634` looks the location up **by that exact name**.
> `defaultputawaylocationname` is `location.name`, so it carries `PutAwayLane`.
> PRD data confirms it (`putaway_loc = 'PutAwayLane'` for all 9 lane-default SKUs).
> `Put Away Lane` with spaces exists **only** as the old hard-coded display label
> being deleted. Comparing against it makes `isPutawayOverride` **always true**, so
> every SKU would render "(SKU override)" — and T19/T20 must not hard-code the
> spaced literal either, or they pass while production is wrong.

Bind the previously-dead prop in the existing `noticePosition` watcher (the
payload is already fetched at `:357`):

```js
// noticePosition watcher, alongside qtyExpected/qtyReceived
this.putawayStaging = newVal.defaultputawaylocationname || null
```

```js
// Mirrors WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE (WmsConstants.java:771) — the
// LOCATION NAME, not a display label. The backend compares the same field to this
// exact string at ReceivingService.java:602 and :634.
const DEFAULT_PUTAWAY_LANE_NAME = 'PutAwayLane'
const DEFAULT_PUTAWAY_LANE_LABEL = 'Put Away Lane'   // operator-facing text only

computed: {
  isPutawayOverride() {
    return !!this.putawayStaging && this.putawayStaging !== DEFAULT_PUTAWAY_LANE_NAME
  },
  // Never render the machine name to operators: the screen previously showed
  // "Put Away Lane", so mapping the default back preserves that wording while the
  // COMPARISON above uses the real location name.
  putawayDisplay() {
    if (!this.putawayStaging) return DEFAULT_PUTAWAY_LANE_LABEL
    return this.putawayStaging === DEFAULT_PUTAWAY_LANE_NAME
      ? DEFAULT_PUTAWAY_LANE_LABEL
      : this.putawayStaging
  },
}
```

Template binds `{{ putawayDisplay }}` (not `putawayStaging` directly).

> **Preferred longer-term shape (Critic B-1(ii)):** stop string-matching the lane in
> the UI altogether — add a `defaultputawaylocationisoverride` boolean (or the location
> type name) to `receiving_dto_view` and drive the marker off **type**, matching how
> §5 B2 classifies server-side. String comparison in the UI is the same class of
> defect as F6's name-based backend predicate. Recorded as a follow-up rather than
> done here, because it widens PR1 into a view migration.

**Why not a backend change:** the field is already in `receiving_dto_view` and
already on the response the screen consumes. Nothing else is needed.

**Why keep a fallback at all** (⚠ **corrected 2026-08-02 during implementation:** this parenthetical
previously read *"the fallback value is `PutAwayLane` … not the spaced display literal"*, which
**contradicted the authoritative `putawayDisplay` code block above, T20, and the shipped code** — all
three return `DEFAULT_PUTAWAY_LANE_LABEL` = `'Put Away Lane'` for a null field. The *comparison* uses
the machine name `PutAwayLane`; the *render* never shows it. The code block was right and the prose was
stale — flagged by the code-review lane as liable to mislead whoever picks up SBDEV-2732):
`defaultputawaylocationname`
comes from a `LEFT JOIN`, so it is null when `putawaylocation_id` is null.
`putawaylocation_id` is NOT NULL in practice on all four tenants, but the
fallback keeps the display honest rather than blank if that ever changes.

### Fix B — classify the destination and use the right primitive

> # ⛔ DO NOT IMPLEMENT ANY OF THIS UNDER SBDEV-2731
>
> **RELOCATED to [SBDEV-2732](https://app.clickup.com/t/868kgfzt9) (D14, 2026-08-02), and STILL GATED.**
> Everything from here to the end of Fix B is **specification retained as an evidence trail**, not work.
> It is reproduced so it transfers intact — the code moved, the analysis stayed.
>
> **Two independent reasons it is not implementable as written:**
> 1. **Q5 is unanswered** ([SBDEV-2796](https://app.clickup.com/t/868kk4rmv)). Options (a) and (d) — the
>    recommended one — **delete Fix B entirely.** Writing it now is likely wasted work.
> 2. **C2b is a confirmed destructive defect.** B3's `Goodsreceiptposition` reordering would make
>    `GoodsReceiptPositionService.delete`/`adjust` nirvana the **entire flowbin balance** for a one-case
>    correction. **T8 asserts the defective state as correct.**
>
> Also unreconciled: **F1** is accepted above but §5/§6 below still sketch the rejected
> three-dependency shape inside `ReceivingService`; **F4** (`Replenishorder` locks pulled into the
> receive transaction) and **F5** (a new tenant-wide lock on the shared Inbound location) are open.
>
> ⚠ **The verify script will NOT catch you.** `B1`–`B15` are now **skips**, so implementing this turns the
> script *green on skipped checks* — it does not turn it red as an earlier revision of §7.2 claimed.
> Nothing here is gated. The only thing standing between this code and a destructive merge is this box.

**File:** `v2/wms2-api/.../service/ReceivingService.java`
**PR:** ~~2~~ **→ SBDEV-2732**

**B1 — resolve the destination for both carrier and loose-case paths (D2).**
Replace the `carrier == null` ternary at `:454-457` so the override is always
resolved, and let a non-default destination win over the carrier:

```java
// SBDEV-2731 D2: the SKU's configured destination must never be silently
// discarded. Previously this was resolved only when carrier == null, so
// receiving onto a pallet dropped the override with no message.
Location putAwayLocation = locationRepository.findById(itemdata.getPutawaylocationId())
    .orElseThrow(() -> new BusinessException("entityNotFoundForId",
        Location.class.getSimpleName(), itemdata.getPutawaylocationId()));
LocationType putAwayLocationType = locationTypeRepository.findById(putAwayLocation.getTypeId())
    .orElseThrow(() -> new EntityNotFoundException("LocationType", putAwayLocation.getTypeId()));
final boolean isDefaultPutawayLane =
    WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE.equals(putAwayLocation.getName());
// A configured override outranks the operator's carrier selection.
final boolean routeToConfiguredDestination = (carrier == null) || !isDefaultPutawayLane;
```

**B2 — hoist the flowbin resolution above the loop.** Resolved **once**, before
any row is written, so an unusable configuration fails before the operator's
1000-unit receipt does any work:

```java
final boolean destinationIsFlowbin = WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN
        .equals(putAwayLocationType.getSltname());
Unitload flowbinResidentUnitload = null;
if (routeToConfiguredDestination && destinationIsFlowbin) {
    flowbinResidentUnitload = resolveFlowbinResidentUnitload(putAwayLocation, itemdata);
}
```

`resolveFlowbinResidentUnitload` implements **D1′** (§10):

```java
/**
 * SBDEV-2731 (D1'): receiving may deposit into a flowbin pick face, but only via the
 * bin's resident PickLocation unit load — a Case unit load has never occupied a flowbin
 * on any tenant (1,780 ULs audited, zero exceptions).
 *
 * Auto-create is DELIBERATELY narrower than the equivalents in MobilePutAwayService:479
 * and StockunitService:192, which create an assignment with fewer checks. Receiving is a
 * bulk automated path, so it creates one only in the unambiguous case and otherwise
 * refuses with an actionable message. Do NOT loosen this to match those call sites, and
 * do NOT tighten it back to an unconditional reject — a hard reject leaves the ICE PACK
 * receipt failing, which is the defect this ticket exists to fix.
 *
 * The "holds no unit load" condition is defence-in-depth: on all four audited tenants
 * (has-FLA) and (holds-UL) are perfectly correlated, so it guards no observed population.
 * It is not dead code — it is the guard that keeps an unexpected mixed state from
 * silently producing a second UL in a pick face.
 */
private Unitload resolveFlowbinResidentUnitload(Location flowbin, Itemdata itemdata)
        throws BusinessException {
    Optional<FixLocationAssignment> atLocation =
            fixLocationAssignmentRepository.findByAssignedlocationId(flowbin.getId());

    if (atLocation.isPresent()) {
        final FixLocationAssignment fla = atLocation.get();
        if (!fla.getItemdataId().equals(itemdata.getId())) {
            final String otherSku = itemdataRepository.findNameById(fla.getItemdataId());
            throw new BusinessException("BusinessException.FlowbinAssignedToOtherSku",
                    flowbin.getName(), otherSku, itemdata.getItemNr());
        }
        final Long residentUlId = fla.getAssignedunitloadId();
        return unitloadRepository.findById(residentUlId)
                .orElseThrow(() -> new EntityNotFoundException("UnitLoad", residentUlId));
    }

    // No assignment on the bin. Auto-create only in the unambiguous case.
    Optional<FixLocationAssignment> skuElsewhere =
            fixLocationAssignmentRepository.findByItemdataId(itemdata.getId());
    if (skuElsewhere.isPresent()) {
        final Long otherLocId = skuElsewhere.get().getAssignedlocationId();
        final String otherLocation = locationRepository.findById(otherLocId)
                .map(Location::getName).orElse(String.valueOf(otherLocId));
        throw new BusinessException("BusinessException.SkuAlreadyAssignedToFlowbin",
                itemdata.getItemNr(), otherLocation, flowbin.getName());
    }
    if (!unitloadRepository.findByStoragelocationId(flowbin.getId()).isEmpty()) {
        throw new BusinessException("BusinessException.FlowbinOccupiedWithoutAssignment",
                flowbin.getName(), itemdata.getItemNr());
    }

    final FixLocationAssignment created =
            fixLocationAssignmentService.createFixedLocationAssignment(flowbin, itemdata);
    LOG.info("SBDEV-2731 auto-created FixLocationAssignment id={} for sku={} on flowbin={} "
            + "during receiving", created.getId(), itemdata.getItemNr(), flowbin.getName());
    final Long createdUlId = created.getAssignedunitloadId();
    return unitloadRepository.findById(createdUlId)
            .orElseThrow(() -> new EntityNotFoundException("UnitLoad", createdUlId));
}
```

`createFixedLocationAssignment` allocates the resident `PickLocation` UL as well
as the FLA row, and already refuses non-FLOWBIN types (`:120`) — so it is reused
rather than reimplemented.

**B3 — dispatch inside the loop, and resolve C1 + C2.** Replace `:479-495`:

```java
Unitload unitload = unitloadService.createUnitload(inboundWorkStation, unitloadType.getId(),
        client.getId(), codeReceiving, spawnLocation, boxType.getId());
Stockunit stockUnit = stockunitBusinessService.createStockUnit(client, itemdata,
        new BigDecimal(amount), false, unitload, codeReceiving,
        adviceposition.getNumber(), inboundWorkStation, unitloadTypeName);

Stockunit receivedStockUnit = stockUnit;
if (flowbinResidentUnitload != null) {
    // Flowbin: move the STOCK into the bin's resident PickLocation UL and retire the
    // transient Case UL. Mirrors MobilePutAwayService:494.
    receivedStockUnit = stockunitBusinessService.transferStockToUnitLoad(
            stockUnit, flowbinResidentUnitload, stockUnit.getAmount(), codeReceiving,
            adviceposition.getNumber(), null, false, true);
} else if (routeToConfiguredDestination) {
    unitloadBusinessService.transferUnitLoadToLocation(unitload, putAwayLocation, false,
            codeReceiving, adviceposition.getNumber(), null);
} else {
    unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier,
            codeReceiving, adviceposition.getNumber(), null);
}

// C2: write the goods-receipt position AFTER the move, against the SURVIVING stock unit
// and its unit load. On the flowbin path transferStockToUnitLoad merges into the
// resident UL's existing stock unit, so the original stockUnit/unitload can be retired;
// recording them would point the receipt at rows renamed to "<label>-X-<id>" at Nirvana.
//
// ⚠ The AMOUNT must be this case's received quantity, NOT receivedStockUnit.getAmount().
// transferStockToUnitLoad returns the DESTINATION stock unit
// (StockunitBusinessService:392) after doing
// destinationStockUnit.setAmount(destinationStockUnit.getAmount().add(amount)) — so its
// amount is the CUMULATIVE flowbin balance. See §10 C2a for why that would be corrupting.
grpCount = saveGoodsreceiptPosition(goodsreceipt, adviceposition, user, client,
        receivedStockUnit.getId(),        // surviving stock unit id
        receivedStockUnit.getUnitloadId(),// surviving unit load id
        new BigDecimal(amount),           // THIS case's quantity — never the merged total
        grpCount);

// C1: no case label on the flowbin path — see §10 C1.
if (flowbinResidentUnitload == null) {
    try {
        outputStream.write(sharedService.createCaseLabel(unitload, receivedStockUnit,
                advice, goodsreceipt, warehouseName));
    } catch (IOException e) {
        throw new FacadeException("adding to byte stream failed: " + e.getMessage());
    }
}
```

`saveGoodsreceiptPosition` is a private extraction of the existing `:479-486`
block, taking the surviving `Stockunit` and reading `getUnitloadId()` from it.

**B4 — guard the post-commit print on a non-empty stream (C1 follow-through).**
Verified 2026-07-31: after the loop, `ReceivingService:541-552` does
`byte[] labelData = outputStream.toByteArray()` and calls
`printService.cupsPrint(printerAddress, labelData)` inside `afterCommit`. If
**every** case on a receipt routes to a flowbin, C1 leaves `outputStream` empty
and an **empty print job is sent to CUPS**. It cannot roll back the receive (the
call is wrapped in `try/catch FacadeException` + `LOG.error`), but it may emit a
blank page or a CUPS error. Add the guard:

```java
if (Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY))) {
    byte[] labelData = outputStream.toByteArray();
    if (labelData.length == 0) {
        // SBDEV-2731 C1: an all-flowbin receipt produces no case labels by design.
        LOG.debug("no case labels to print for adviceposition={}", adviceposition.getNumber());
    } else {
        // ... existing registerSynchronization block unchanged
    }
}
```

**Constructor dependencies — resolved, not hedged** (verified against the real
constructor 2026-07-31; constructor injection only):

| Dependency | Status in `ReceivingService` |
|---|---|
| `LocationRepository` | already present (`:63`) |
| `UnitloadTypeRepository` | already present (`:71`) |
| `ItemdataRepository` | already present (`:75`) |
| `StockunitBusinessService` | already present (`:91`) |
| `LocationTypeRepository` | **ADD** |
| `FixLocationAssignmentRepository` | **ADD** |
| `FixLocationAssignmentService` | **ADD** |

So **three** new constructor parameters, not four.

**Repository signatures — verified, do not re-check:**

| Call | Real signature |
|---|---|
| `fixLocationAssignmentRepository.findByAssignedlocationId(Long)` | → `Optional<FixLocationAssignment>` (`:22`) |
| `fixLocationAssignmentRepository.findByItemdataId(Long)` | → `Optional<FixLocationAssignment>` (`:28`) — **`Optional`, not `List`** |
| `unitloadRepository.findByStoragelocationId(Long)` | → `List<Unitload>` (`:42`) — exists |
| `itemdataRepository.findNameById(Long)` | → `String` (`:35`) |
| `unitloadTypeRepository.findNameById(Long)` | → `String` (`:19`) |
| `stockunitBusinessService.transferStockToUnitLoad(...)` | → `Stockunit` (`:179`, 8-arg; a 9-arg overload at `:188` accepts a preloaded `FixLocationAssignment`) |

⚠ `findByAssignedlocationId`, `findByItemdataId` and `findByStoragelocationId` all
carry `@RestResource` and are therefore **HTTP-exposed**. Fix B only reads through
them, so no exposure change — but per the SBDEV-1666 landmine, never assume a
service-layer branch can gate a `@RestResource`-exported query.

**Why not relax the constraint gate instead:** §1.3 Q5. Zero `Case` ULs have
ever occupied a flowbin across 1,780 audited ULs. Permitting one would make
receiving the first writer to break an invariant that picking and replenishment
depend on.

### Fix C — actionable, bundle-keyed constraint message

**Files:** `UnitloadBusinessService.java`, both message bundles
**PR:** 1

The gate's **logic is unchanged** — message and context only.

Before (`:191`):

```java
throw new BusinessException("unitloadtypeId=" + unitload.getTypeId()
    + " not allowed on location=" + destinationLocation.getName()
    + " with location type=" + destinationLocation.getTypeId());
```

After — resolve human-readable names and use a bundle key:

```java
// SBDEV-2731 Fix C. NOTE the key name is SBDEV-2732's, by agreement: 2732 §5.1 row 0
// declares "UnitloadBusinessService:191 already throws the NEUTRAL
// unitloadTypeNotPermittedOnLocation" as a HARD PREREQUISITE it consumes, and §7.2
// step 6 says "Do not re-specify :191 — that is 2731 PR1's line."
//
// findNameById is a JPQL scalar projection and returns NULL for a missing id, which
// would render "cannot hold a null unit load". Fall back to a neutral word, NOT to the
// id — T15 asserts no bare numeric id reaches the operator.
final String unitloadTypeName = Objects.toString(
        unitloadTypeRepository.findNameById(unitload.getTypeId()), "unknown");
// The null check is NOT redundant with the Optional (review finding #3, commit 89de3f0).
// Location.typeId is a nullable Long and SimpleJpaRepository.findById ASSERTS a non-null
// id — it throws IllegalArgumentException, a RuntimeException, which ReceivingController
// converts to "unexpected internal error, contact support", destroying the very message
// this fix ships. Reachable because a derived query maps a null SIMPLE_PROPERTY to
// `IS NULL`, not to no-match: a location_constraint row with storagelocationtype_id IS NULL
// makes the list non-empty and drives the throw site with a null type id. The pre-fix
// concatenation rendered "location type=null" harmlessly, so calling findById unguarded
// would be a strict regression. Covered by T14d.
final String locationTypeName = destinationLocation.getTypeId() == null
        ? "unknown"
        : locationTypeRepository.findById(destinationLocation.getTypeId())
                .map(LocationType::getSltname).orElse("unknown");
LOG.warn("location constraint rejected transfer: unitloadId={} unitloadTypeId={} ({}) "
        + "destinationLocation={} locationTypeId={} ({})",
        unitload.getId(), unitload.getTypeId(), unitloadTypeName,
        destinationLocation.getName(), destinationLocation.getTypeId(), locationTypeName);
throw new BusinessException("unitloadTypeNotPermittedOnLocation",
        unitloadTypeName, destinationLocation.getName(), locationTypeName);
```

> ⚠ **The ids are still recoverable — from the `LOG.warn`, not the operator message.** Both `orElse`
> branches deliberately drop to `"unknown"` rather than `String.valueOf(typeId)`, because T15 forbids a
> bare numeric id in the user-facing text. The log line above carries every id, so support loses nothing.

**Dependency:** `UnitloadBusinessService` already injects `unitloadTypeRepository`
(`:49`) but **not** `LocationTypeRepository` — add that one constructor parameter.

**PR1 ships exactly ONE key**, added to **both** `messages_en_US.properties` **and**
`messages.properties` (SBDEV-2729 established that the base bundle is required so
the key resolves under any JVM default locale):

```properties
unitloadTypeNotPermittedOnLocation=Unit load type %1$s is not permitted on location %2$s (location type %3$s).
```

> ⚠ **Reworded 2026-08-06 (review finding #4, commit `89de3f0`) — this is the as-shipped string.**
> The original template was `A %1$s unit load is not permitted on location %2$s (location type %3$s).`
> It rendered `A unknown unit load` on the T14c fallback path and `A Inbound Pallet unit load` for any
> vowel-initial type. Leading with `Unit load type` sidesteps the indefinite article entirely and drops
> the awkward doubled "unit load".
>
> **The KEY NAME did not change**, so SBDEV-2732's §5.1 row 0 prerequisite is unaffected — only the text
> moved. **If you are implementing 2732: assert against the string above, not the struck-through one.**

> ⚠ **No remedy clause here — deliberately.** An earlier revision ended this message with *"Update the
> SKU's Default Putaway Location before receiving…"*. That is **wrong for this throw site**, and §0 row 17
> is the evidence: `transferUnitLoadToLocation` has **24 production call sites** — mobile transfer,
> putaway, parcel monitor, move-unitload, truck loading, picking, customer order, nirvana clearing. Only
> the **receiving** path resolves a configured putaway destination at all, so the remedy is actively
> misleading — a picker hitting a constraint on a mobile move would be told to reconfigure a SKU.
>
> > ⚠ **Count corrected 2026-08-06 (review finding #5).** This paragraph previously said "24 other
> > production call sites" and then, in the same breath, "34 of the 35 callers" — **the plan contradicted
> > itself**, and the original implementation comment copied the wrong figure. The verified number is
> > **24** (`grep -rn '\.transferUnitLoadToLocation('` over `src/main/java` at `origin/develop`).
> >
> > Also: **the receiving path now has TWO entry points**, not one — the web receive screen, and RETURN
> > advice auto-receive (`ReturnAdviceAutoReceiveService:556`, SBDEV-2778, merged after this plan was
> > written). That *strengthens* the neutral-key decision: 2778's consumer is OMS, a machine, which can
> > act on "reconfigure the SKU" even less than a picker can.
>
> SBDEV-2732 §3.6.1 reached the same conclusion independently and splits it: the **neutral** key lives
> here, and a putaway-specific `putawayDestinationNotPermitted` (naming the configured tier and the
> fallback lane) is thrown by 2732's resolver, **where the putaway context actually exists**.
> Verify negatives `C6` and `M10` keep the remedy out of this site.
>
> The unprefixed key name also matches the bundle's dominant convention — cf.
> `STORAGELOCATION_LOCKED=The location %1$s is locked. ( Lock code = %2$s ).` at `messages_en_US.properties:287`.

**The three `Flowbin*` / `SkuAlreadyAssignedToFlowbin` keys below are NOT PR1's.** They are thrown only by
Fix B and moved to SBDEV-2732 with it (D14). Recorded here as the relocated spec; verify checks `M3`–`M8`
are **skipped**, not deleted. Do not add them to the bundles under this ticket — unreachable
operator-facing strings invite a reviewer to wire them up prematurely.

```properties
# ── RELOCATED to SBDEV-2821 (D14 -> 2732, then 2732 D15 -> 2821) — do NOT add in PR1 ──
BusinessException.FlowbinAssignedToOtherSku=Pick location "%1$s" is already assigned to SKU %2$s, so SKU %3$s cannot be received into it. Choose a different Default Putaway Location.
BusinessException.SkuAlreadyAssignedToFlowbin=SKU %1$s is already assigned to pick location "%2$s" and cannot also be received into "%3$s". Clear the existing assignment first.
BusinessException.FlowbinOccupiedWithoutAssignment=Pick location "%1$s" already holds stock but has no SKU assignment, so SKU %2$s cannot be received into it. Ask an administrator to reconcile the location.
```

**Pre-submit validation.** Because Fix B's B2 hoists resolution above the loop,
an unusable configuration now fails **before** the first row is written. That
converts "fails after writing 4 rows then rolls back" into "fails immediately",
which satisfies the ticket's *"detected before final submission where practical"*
without a new endpoint. A pre-flight GET was considered and rejected: it would
duplicate the rule in two places and could disagree with the write path under
concurrent config change.

---

## 6. File Change Summary

| File | Change | Description | PR |
|---|---|---|---|
| `wms2-web-ui/components/receiving/open/receive/receivingForm.vue` | modify | Bind destination label to `defaultputawaylocationname`; mark overrides; bind the dead `putawayStaging` prop | 1 |
| `wms2-api/.../service/UnitloadBusinessService.java` | modify | Bundle-keyed, name-bearing constraint message + `LOG.warn` context | 1 |
| `wms2-api/src/main/resources/messages_en_US.properties` | modify | **ONE** new key: `unitloadTypeNotPermittedOnLocation` (2732's name — its §5.1 row 0 prerequisite). The three `Flowbin*`/`SkuAlready*` keys are **not** PR1's. | 1 |
| `wms2-api/src/main/resources/messages.properties` | modify | Same one key (locale-independent fallback) | 1 |
| ~~`wms2-api/.../service/ReceivingService.java`~~ | **RELOCATED** | **Not this ticket.** D2 destination resolution, flowbin classification, resident-UL resolution and loop dispatch are owned by **SBDEV-2732** (D14) — see 2732 §5.2 Phase 1-API step 15. The gated part (Fix B proper) stays blocked on Q5/C2b/Q1/Q4 and lands wherever Q5's answer sends it. | **→ 2732** |
| ~~`wms2-api/src/test/.../ReceivingServiceUnitTest.java`~~ | **RELOCATED** | Fix B unit coverage follows Fix B to **SBDEV-2732**. | **→ 2732** |
| `wms2-api/src/test/.../UnitloadBusinessServiceUnitTest.java` | modify | Fix C message assertions (§8.2) | 1 |
| `wms2-web-ui/test/components/receiving/open/receive/receivingForm.spec.js` | new | Fix A display coverage (§8.3). Path mirrors the component, matching the suite's convention. **Now gated** — verify `A9` (exists) + `T3` (passes). | 1 |
| `sbdocs/9-System/scripts/verify-SBDEV-2731-…sh` | new | Machine-checkable acceptance | — |

No Flyway migration. Message bundles are code resources; no schema or sysprop
change is required.

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Area | Requirement |
|---|---|
| **DB state** | **None blocking for PR1** — PR1 is a Vue binding and a message string; it touches no data. ⚠ The old text here read *"PR2 alone makes advice `IBOL000221` receivable"*, which is **not a promise this ticket makes**: PR2 relocated (D14) and the ICE PACK receipt stays broken after PR1. Whether it ever becomes receivable is [SBDEV-2796](https://app.clickup.com/t/868kk4rmv)'s Q5 decision. §1.3 Q6's four-condition proof is retained as evidence for that decision, not as a PR1 prerequisite. |
| **Branch** | `bugfix/SBDEV-2731-alternate-putaway-location-not-honored-receiving` off `develop` in **both** repos. `wms2-api` currently has `bugfix/SBDEV-2777-…` checked out — do **not** write onto it. |
| **Deploy order** | ⚠ **INVERTED from the original.** PR1 is no longer "first among two of ours" — it is now an **external hard dependency of SBDEV-2732 Phase 1a** (2732 §5.1 row 0: 2732 assumes `receivingForm.vue` already binds `putawayStaging` and that `:191` already throws the neutral `unitloadTypeNotPermittedOnLocation`). **PR1 must merge before 2732 Phase 1a**, and if PR1 is abandoned or reworked, 2732 §3.6.1 and its display contract must be re-scoped back into that plan. |
| **Feature flags / sysprops** | None added. `REQUIRE_RECEIVING_TO_CONTAINER` is read but not changed; note it is **absent** on UAT (§1.3 Q7) if testing D2 there. |
| **Config** | None. |
| **Data migration** | None. |
| **External systems** | `INBOUND_UPDATE_STOCK_IMMEDIATELY = true` on PRD, so a successful receive fires an OMS stock-change message as it does today. The flowbin path must keep doing so — covered by §8.1 T7. |
| **Access** | PRD/UAT verification used SELECT-only `psql` over the existing tunnels (:25061 / :25062). The UAT and PRD MCP servers were not running in-session; restart Claude Code with the tunnels up to use them. |
| **Monitoring** | The new `LOG.info` on auto-create and `LOG.warn` on constraint rejection are the observability hooks — see §7-HS row 7. |

### 7.2 Ordered steps — two PRs (D3)

**PR1 — display + actionable error (low risk, ships first)**

1. Re-run the verify script to confirm the baseline still matches §9's recorded
   **`Result: 9 pass, 15 fail, 24 skip`** before editing anything. **BASELINE LABEL: measured pre-2731-merge against `origin/develop` api `169065c` / ui `743142e` (2026-08-06). It expires the moment PR #133/#39 merge — re-measure and re-record rather than trusting this line.** If it differs,
   `develop` has moved under this plan — reconcile before starting.
   ⚠ **Re-measured 2026-08-02.** The previous figure (`8 pass, 33 fail, 2 skip`) is stale
   and will NOT reproduce: the **script** changed when `B1`–`B15` and `M3`–`M8` became
   skips and `A8`/`A9`/`C6`/`M10`/`T3` were added. That is not develop drift — do not go
   hunting for a phantom regression.
2. Add **only** `unitloadTypeNotPermittedOnLocation` to `messages_en_US.properties`
   **and** `messages.properties`. Two constraints on this step:
   - **The key name is SBDEV-2732's, not a free choice.** 2732 §5.1 row 0 declares it a
     hard prerequisite and §7.2 step 6 consumes it. A different name breaks 2732 at
     implementation time on a key that never existed.
   - **No putaway remedy clause in the text** — `:191` has **24 call sites** (corrected
     2026-08-06; this line previously said "35 callers, 34 of which"), and only the
     receiving path resolves a configured destination. Guarded by `C6` / `M10`.

   ⚠ The three `Flowbin*` / `SkuAlreadyAssigned*` keys are thrown **only by Fix B**, which
   relocated to SBDEV-2821 (D14 sent them to 2732; 2732 D15 sent them onward). Do **not** add them here. Verify `M3`–`M8` are **skips**, so
   omitting them is what greens the script.
3. Rewrite the `:191` throw in `UnitloadBusinessService` with the bundle key + `LOG.warn`;
   add the `LocationTypeRepository` constructor parameter (verified absent; `unitloadTypeRepository`
   is already injected at `:49`). Use the null-safe fallbacks in §5 Fix C — `findNameById` is a
   JPQL scalar projection and returns `null` for a missing id.
   ⚠ **Then add `@Mock LocationTypeRepository` to all three `@InjectMocks` fixtures** —
   `UnitloadBusinessServiceUnitTest:73`, `UnitloadBusinessServiceReplenBranchTest:68`,
   `UnitloadBusinessServiceReplenSyncTest:46`. Mockito passes `null` for a constructor
   parameter with no matching `@Mock`, so without this the constraint-rejection path NPEs.
4. **Rewrite** (not extend) `UnitloadBusinessServiceUnitTest:193, 208` per §8.2 — including
   that the message contains no bare `unitloadtypeId=` / `location type=` token.
   ⚠ `:208` currently pins `.hasMessageContaining("not allowed on location")`, which the new
   message does **not** contain. It **will** fail. **Tighten the assertion to the new rendered
   text — never loosen it to make it pass.**
5. Fix A in `receivingForm.vue` + the Jest spec per §8.3, at
   `test/components/receiving/open/receive/receivingForm.spec.js`.
   ⚠ Bind `{{ putawayDisplay }}` — **not** `{{ putawayStaging || DEFAULT_PUTAWAY_LANE_NAME }}`,
   which cannot work in Vue 2 (see §5 Fix A).
6. `mvn test -Dtest=UnitloadBusinessServiceUnitTest` and the web-ui Jest spec
   (`node_modules/.bin/jest --testPathPattern=receivingForm` under nvm node — no `yarn` on PATH).
   Then `mvn clean compile` (SBDEV-2217: the Testcontainers IT lane cannot boot, so compile +
   unit tests are the gate).
7. Re-run the verify script with `RUN_TESTS=1` to `Result: 27 pass, 0 fail, 22 skip` (**27, not 26 —
   the code review added check `A10`, 2026-08-06**); paste the
   literal line into the PR. A default (`RUN_TESTS=0`) run **cannot** constitute acceptance — the
   script exits `2` with `NOT ACCEPTANCE`.
8. Commit; PR into `develop`. ⚠ **Notify SBDEV-2732's implementer that its Phase 1a prerequisite
   is now satisfied** (2732 §5.1 row 0).

**GATE — transferred with the work, NOT discharged. Now owned by [SBDEV-2796](https://app.clickup.com/t/868kk4rmv) + SBDEV-2732.**

> This gate does not apply to PR1 and never blocked it. It is reproduced because it travels with the
> relocated subject matter: whoever picks up Fix B under 2732 inherits all four items unchanged. Q5 and
> C2b are 2796's; Q1 and Q4 go to 2732 with the code.

| Gate | Blocks because |
|---|---|
| **Q5** answered (a/b/c/d) | Determines whether Fix B exists at all. Under (a) or (d) most PR2 steps below are deleted rather than executed. |
| **C2b** resolved | The `Goodsreceiptposition` repointing is destructive as designed (`GoodsReceiptPositionService.delete:159-167`). T8 currently asserts the defective state as correct. |
| **Q1** answered | C1 label suppression is operator-visible. |
| **Q4** answered | D2's predicate is name-based and its blast radius is wider than flowbins (F6). |

Also unresolved and required before coding, if Q5 keeps Fix B: **F1** (move
`resolveFlowbinResidentUnitload` into `FixLocationAssignmentService` — §5/§6 and verify
checks `B1`/`B5`/`B6`/`B7`/`B8`/`B13` still describe the rejected three-dependency
shape), **F5**'s Inbound-row lock re-scoping, and **F4**'s `Replenishorder` lock-order
question.

**PR2 — flowbin routing (the behaviour change) — RELOCATED to SBDEV-2821 (via 2732 D14, then 2732 D15) AND STILL GATED**

> **⚠ DESTINATION UPDATED 2026-08-06 — this bundle is now owned by [SBDEV-2821](https://app.clickup.com/t/868km8j9z), not SBDEV-2732.**
> D14 (2026-08-02) sent it to 2732; **2732's D15 (2026-08-04) then deferred tier-1 pick-face placement onward to SBDEV-2821**, and this
> bundle went with it. The pointer below was never updated, which left five artifacts named here belonging to a plan that does not carry them:
>
> | Artifact | Kind | Now owned by |
> |---|---|---|
> | `resolveFlowbinResidentUnitload` (F1 — move into `FixLocationAssignmentService`) | code | SBDEV-2821 |
> | `saveGoodsreceiptPosition` repointing (C2b — destructive as designed) | code | SBDEV-2821 |
> | `BusinessException.FlowbinAssignedToOtherSku` | message key | SBDEV-2821 |
> | `BusinessException.SkuAlreadyAssignedToFlowbin` | message key | SBDEV-2821 |
> | `BusinessException.FlowbinOccupiedWithoutAssignment` | message key | SBDEV-2821 |
>
> None of the five exists in `wms2-api` source, none is named in SBDEV-2732's plan, and this document explicitly declines to ship them —
> so until 2026-08-06 they had **no owner anywhere**. Verify checks `M3`–`M8` and `B1`/`B5`–`B8`/`B13` remain skipped here, deliberately.
>
> **All relocation pointers in this document now name SBDEV-2821 directly** (corrected 2026-08-06) — a grep or tail-read previously landed on the superseded 2732 destination. The spec and evidence trail stay here; the ownership does not.

> **Do not execute these steps under this ticket.** Ownership of `ReceivingService` destination resolution
> moved to SBDEV-2732 on 2026-08-02, and **onward to [SBDEV-2821](https://app.clickup.com/t/868km8j9z) on
> 2026-08-04 (2732 D15)**. The steps and the gate below are **retained deliberately** — they are the
> specification and the evidence trail that transfer with the work, not leftovers.
>
> **Gate status, updated 2026-08-06:**
> - **Q5 is ANSWERED** — SBDEV-2796, option **(c)** *"valid, and bounds are advisory for receiving"*. So
>   **Fix B survives**; it is no longer conditional.
> - **Q11 is ANSWERED** — *"advisory for replenishment"* too, 2026-08-06. Costs no code (the bounds are
>   only ever comparison predicates), **but only holds if resident-UL resolution is correct** — if
>   placement creates a second unit load, refill keeps firing and cancel never does.
> - **C2b remains an unresolved destructive defect** and is now *the* binding gate on Fix B.
>
> Whatever survives lands in **SBDEV-2821**, not 2732 §5.2 (the `ReceivingService:451-459` / `:492`
> dispatch fork is still the extension point).
>
> **This ticket closes on PR1 and does not wait for any of this.**

8. Add B1 destination resolution + B2 flowbin hoist + `resolveFlowbinResidentUnitload`, with the D1′ comment block verbatim.
9. Extract `saveGoodsreceiptPosition` and apply the B3 loop dispatch, including the C1 label suppression and C2 reordering.
10. Add §8.1 tests — **AC 2 regression guard first**, so the unchanged `PutAwayLane` path is protected before the new branch is trusted.
11. `mvn test -Dtest=ReceivingServiceUnitTest`, then the full suite. Expect exactly the 2 known pre-existing develop failures (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) and **revert the `archunit_store` mutation** that `mvn test` makes to that tracked file.
12. Re-run the verify script to `Result: N pass, 0 fail`; paste the line into the PR.
13. Commit; PR into `develop`.

---

## 7-HS. Horizontal Scalability Validation (v2 — MANDATORY)

> ### 📋 THIS SECTION ANALYSES THE RELOCATED FIX B — it is not PR1's gate
>
> **PR1's verdict on every row below is "No".** PR1 is a Vue template binding plus a message string: it
> introduces **no new state, no new transaction, no new lock, no new scheduled-job interaction, and no
> new external notification.** The one PR1-relevant change is `UnitloadBusinessService` gaining a
> `LocationTypeRepository` and one extra `findById` on an already-failing path.
>
> Every ⚠ **CORRECTED to Yes** below (rows 2, 3, 8, 10) and all of E1/E2/E3 concern **Fix B**, which moved
> to SBDEV-2732 (D14). A reviewer gating PR1 on this section will read blockers that do not apply.
> Retained in full because it is the concurrency analysis that transfers with the work.

| # | Concern | Verdict |
|---|---|---|
| 1 | **In-JVM state** — new Caffeine / map / static / ThreadLocal | **No** — no new state; all resolution is per-request from repositories. |
| 2 | **Connection pool math** — per-request DB connections | ⚠ **CORRECTED to Yes** (was "No"). Architect F4: `createFixedLocationAssignment:104` → `triggerReplenishmentMaintenance` → `recalculateForItem`, which is `@Transactional(REQUIRED)` and drives `recalculateOrder`'s `Replenishorder` `findByIdForUpdate`. Still one pooled connection (REQUIRED joins), but the transaction now does materially more work and holds more locks. See E2/E4. |
| 3 | **Scheduled jobs** | ⚠ **CORRECTED to Yes** (was "N/A — no `@Scheduled` touched"). Fix B's auto-create shares `recalculateForItem` with `ReplenishOrderJob:176`, which is exactly the lock-order inversion F4 describes. Not touching a `@Scheduled` annotation is not the same as not interacting with a scheduled job. See E3. |
| 4 | **Long transactions** — connection held across I/O or many repo calls | **Yes** — see Evidence E1. |
| 5 | **Request affinity** | **No** — nothing cached per JVM between requests. |
| 6 | **Retry / idempotency** | **Yes** — see Evidence E2. |
| 7 | **Tenant context** — propagation across async/scheduled | **No** — entirely inside the request-scoped tenant transaction; no `@Async`. |
| 8 | **Distributed lock correctness** — locks inside `tenantTransactionManager`, timeout configured | **Yes** — see E3, **which is itself corrected**: its "no cycle is introduced" conclusion was derived from a lock enumeration that omitted `Replenishorder`. Fix B introduces `Replenishorder` locks via F4, and `ReplenishOrderJob:176` locks that table first. The cycle question is **reopened**, not answered. |
| 9 | **Cache invalidation** | **No** — `FixLocationAssignment`, `Location`, `Unitload` and `Stockunit` are not `@Cacheable`. Confirm during implementation with `grep -n "@Cacheable" service/FixLocationAssignmentService.java service/LocationService.java`; if any is cached, add the matching `@CacheEvict` and revisit this row. |
| 10 | **External notifications** — deferred to `afterCommit` | ⚠ **CORRECTED to Yes** (was "No (unchanged)"). The OMS stock-change message and label print do still fire post-commit, but F4 adds a **new** side effect the original verdict missed: `recalculateForItem` can cancel or re-source open `Replenishorder`s, which is an outward-facing state change not deferred to `afterCommit`. Flagged by the Architect and omitted from my first correction pass. |

### Evidence

**E1 — long transaction (row 4).** `receiveGoods` already holds a pessimistic
lock on `Adviceposition` (`:344 findByIdForUpdate`) for its whole duration, and
the loop runs once per case (workflow doc §9 item 6: 12 cases ⇒ 12 iterations).
Fix B adds, on the flowbin path, a pessimistic lock on the **shared resident
flowbin UL** — acquired inside `transferStockToUnitLoad` (`:257`) and therefore
held to commit. Consequence: **concurrent receipts of the same SKU serialise on
that one UL for the length of the whole multi-case receipt.**

⚠ **CORRECTED — the original text here claimed "contention is same-SKU only". That
was wrong (Architect F5).** `transferStockToUnitLoad:250` locks the **source**
Location `FOR UPDATE`. On the receiving path the new Case UL is created at
`inboundWorkStation` (`UnitloadService.createUnitload:171` sets
`storagelocationId` from the `location` argument; `spawnLocation` is only a history
marker passed to `recordForCreateUnitLoad`). That source row is the single
`STORAGE_LOCATION_INBOUND_NAME` location **through which all receiving flows**.

So the contention is **tenant-wide across all receiving**, not same-SKU. And it is
**new**: today's `transferUnitLoadToLocation` loads the source location with a plain
`findById` (no lock), so nothing on this path currently locks Inbound. Precedent P1
does not carry the hazard because its source unit load sits at a real lane, not at
the shared Inbound row.

Partial mitigation: B2 resolves the resident UL once before the loop, and
`MAXIMUM_RECEIVING_DURING_INBOUND = 1000` bounds the loop. But with **no retry
infrastructure on this path**, every concurrent receipt in the warehouse would
serialise behind a flowbin receipt for that receipt's whole duration.

**This is no longer "documented and accepted".** It is an open design question
folded into Q5: if PR2 proceeds, the Inbound-row lock must be re-scoped or avoided
(e.g. by not routing the transient UL through `transferStockToUnitLoad` at all).
The SBDEV-1762 precedent does **not** cover this, because that case accepted
*same-lane* contention, not a tenant-global serialisation point.

**E2 — retry/idempotency (row 6).** ⚠ **CORRECTED: auto-creating an FLA is NOT "the
one non-idempotent effect".** Architect F4 established that
`createFixedLocationAssignment` performs at least three: it creates the resident
`PickLocation` unit load, inserts the FLA row, **and** calls
`triggerReplenishmentMaintenance` → `recalculateForItem`, which recalculates and can
cancel open `Replenishorder`s for the SKU. The paragraph below reasons only about
the FLA row and is therefore incomplete; the replenishment recalculation's replay
behaviour has **not** been analysed.

Additional hazard: `triggerReplenishmentMaintenance` swallows everything in
`catch (Exception)` with a `LOG.warn`. Because `recalculateForItem` is `REQUIRED`
and joins the receiving transaction, a `BusinessException` raised inside it marks
that shared transaction rollback-only — so the catch does **not** rescue the
receipt. It converts a clean, attributable failure into an opaque
`Transaction rolled back because it has been marked as rollback-only` at commit,
with the real cause only in a warn-level log.

The original (incomplete) FLA-row analysis follows, retained because it is still
correct as far as it goes: It is safe under replay because the four-condition guard
is re-evaluated inside the transaction: a retry after a rolled-back attempt sees
no FLA (the create rolled back too) and recreates it; a retry after a *committed*
attempt takes the `atLocation.isPresent()` branch and reuses it. Two replicas
racing the first receipt for the same SKU both attempt the create; one commits
and the other fails on the FLA uniqueness constraint or the pessimistic UL lock,
rolling back its whole receipt. That is correct-but-unfriendly, and is the same
class as E1.

**Confirmed at DB level (PRD, 2026-07-31) — the contingency is closed.**
`fix_location_assignment` carries **three** unique constraints, so the database,
not just the application guard, enforces the invariant:

| Constraint | Definition |
|---|---|
| `uk_qakwvmdhdymic54v3dgie46wa` | `UNIQUE (assignedlocation_id)` — one assignment per location |
| `uk_k2oy160252pn1o7comeeqbjt8` | `UNIQUE (itemdata_id)` — **one assignment per SKU** |
| `uk_9fquk8dxneipre4peebi9pacj` | `UNIQUE (assignedunitload_id)` — one assignment per unit load |

Consequences, all favourable:

1. The replica race **provably** fails on a unique violation rather than
   double-creating — E2's argument no longer rests on an assumption.
2. `UNIQUE (itemdata_id)` means D1′'s "SKU is unassigned elsewhere" condition is
   **DB-enforced**, so the application check is defence-in-depth over a real
   constraint rather than the sole protection. It also explains why
   `findByItemdataId` returns `Optional` rather than `List`.
3. Auto-create can never silently produce a second assignment for a SKU.

**E3 — lock ordering (row 8).** `StockunitBusinessService:192-201` documents the
canonical order as **Pickingorder before Stockunit/Unitload/Location**, then locks
source SU (`:209`) → source UL (`:245`) → source Location (`:250`) → destination
UL (`:257`) → destination SU (`:284`) → destination Location (`:290`). Fix B makes
receiving hold `Adviceposition` **before** that chain.

⚠ **CORRECTED: the "no cycle is introduced" conclusion below is withdrawn.** It was
derived from an enumeration that omitted `Replenishorder` entirely. Via F4, Fix B
newly pulls `Replenishorder` `findByIdForUpdate` into the receiving transaction,
and `ReplenishOrderJob:176` acquires that table first — so a receiving-vs-cron
cycle is now *possible* and has not been ruled out. `recalculateOrder`'s own comment
(*"AC8: serialize w/ cron"*) shows the serialisation was designed for the cron
caller, not for a caller already holding `Adviceposition` plus the Inbound Location.
**This must be resolved before PR2.**

The original (now-insufficient) reasoning: `Adviceposition` is locked
by no other path, so no cycle is introduced via *that* row. Lock timeout is the configured
`jakarta.persistence.lock.timeout`. Archived SBDEV-2229 hardened this method's
TOCTOU reads, so the chain is already the reviewed version.

---

## 7-V2. v2-only constraint checklist

> 📋 **Row 2's ⚠ CORRECTED entry is about Fix B only** (relocated, D14). **PR1 introduces no new
> transactional boundary at all** — Fix C changes the *arguments* to an existing throw inside an existing
> transaction, and Fix A is client-side. Rows 1, 5, 6 and 7 hold for PR1 as written.

| # | Constraint | Verdict |
|---|---|---|
| 1 | **OSIV disabled** | **Addressed** — every new repository read in Fix B sits inside `receiveGoods`'s existing `@Transactional`. No lazy association is touched outside a transaction; all reads are explicit `findById` calls (no-JPA-association codebase). |
| 2 | **Transaction manager** | ⚠ **CORRECTED** — "no new `@Transactional` is introduced" is **false**. Fix B's auto-create newly joins a proxied `@Transactional(tenantTransactionManager, REQUIRED, rollbackFor={BusinessException, FacadeException})` on a *different* bean — `ReplenishmentOrderMaintenanceService.recalculateForItem:111-112` — plus its `recalculateOrder` children at `:163` and `:200`. The transaction *manager* is the correct one, so routing is safe; but the claim that no new transactional boundary is entered was wrong, and it is the reason E2/E3 under-modelled the change. Original text: `receiveGoods:302` already specifies `value = "tenantTransactionManager", rollbackFor = {BusinessException, FacadeException}`; the new `BusinessException`s therefore roll back correctly. `transferStockToUnitLoad:178` carries the same annotation and joins the caller's transaction. |
| 3 | **`readOnly = true`** | **N/A** — no new read-only service method. |
| 4 | **Caffeine invalidation** | **N/A** pending the row-9 grep above — none of the touched entities is currently `@Cacheable`. |
| 5 | **Jakarta namespace** | **Addressed** — no new imports beyond existing repositories/services; nothing copied from v1. |
| 6 | **H2-compatible test SQL** | **Addressed** — all §8 tests are Mockito unit tests with no SQL. The v2 Testcontainers lane is broken under SBDEV-2217, so no IT is added; see §8.5. |
| 7 | **`BaseControllerTest`** | **N/A** — no controller endpoint is added or changed. Fix C alters an exception *message*, not `ReceivingController`'s signature or mapping. |
| 8 | **Micrometer metrics** | **No new metric.** Receiving is high-frequency, but the two new log lines (E1/row 7) are sufficient for a change with exactly one production consumer (§1.3 Q3). If alternate destinations become common, add a counter on the auto-create branch — noted as a follow-up, not done here. |

---

## 8. Testing Plan

### 8.1 Unit — `ReceivingServiceUnitTest` — ⛔ RELOCATED to SBDEV-2821 (via 2732 D14 -> D15)

> **Do not write these under SBDEV-2731.** PR1 touches nothing in `ReceivingService`; verify `T1` is a
> permanent skip for that reason. Retained as the relocated test specification.
>
> ⚠ **T8 must not be implemented as written** — it asserts C2b's defective state as correct. See §10 C2b.

Add `@Nested class ReceiveGoodsPutawayRouting`:

| # | Method | Asserts |
|---|---|---|
| T1 | `shouldTransferWholeUnitLoadWhenDestinationIsNotFlowbin()` | **AC 2 REGRESSION GUARD.** Destination type `cases and pallets` ⇒ `transferUnitLoadToLocation` called once per case; `transferStockToUnitLoad` **never** called; a case label **is** produced. Write this first. |
| T2 | `shouldTransferStockIntoResidentUnitLoadWhenDestinationIsFlowbin()` | Flowbin + matching FLA ⇒ `transferStockToUnitLoad(stockUnit, residentUl, amount, …, false, true)`; `transferUnitLoadToLocation` **never** called. |
| T3 | `shouldAutoCreateAssignmentWhenFlowbinEmptyAndSkuUnassigned()` | All four D1′ conditions ⇒ `createFixedLocationAssignment(flowbin, itemdata)` called once, and the returned FLA's resident UL is the transfer destination. |
| T4 | `shouldRejectWhenFlowbinAssignedToDifferentSku()` | `BusinessException` with key `BusinessException.FlowbinAssignedToOtherSku`; **no** `createUnitload`, **no** transfer. |
| T5 | `shouldRejectWhenSkuAlreadyAssignedToAnotherFlowbin()` | key `BusinessException.SkuAlreadyAssignedToFlowbin`; nothing created. |
| T6 | `shouldRejectWhenFlowbinHoldsStockButHasNoAssignment()` | key `BusinessException.FlowbinOccupiedWithoutAssignment`; nothing created. |
| T7 | `shouldStillSendStockChangeMessageOnFlowbinPath()` | The OMS stock-change gate (`:505-523`) fires for a REGULAR advice on the flowbin path exactly as on the lane path. |
| T8 | `shouldRecordGoodsreceiptPositionAgainstSurvivingStockUnit()` | **C2.** `Goodsreceiptposition.stockunitId` / `unitloadId` equal the `Stockunit` **returned by** `transferStockToUnitLoad` and its `unitloadId` — not the transient pre-transfer ids. |
| T8a | `shouldRecordPerCaseAmountNotMergedFlowbinTotal()` | **C2a — the corrupting case.** Stub `transferStockToUnitLoad` to return a destination stock unit whose amount is the *merged* total (e.g. existing 500 + 83), then assert the saved `Goodsreceiptposition.amount` is **83**, not 583. Also assert that summing the GRP amounts across a 12-case receipt equals the notified quantity, so the `allowoverdelivery` check at `:373-378` stays correct. |
| T9 | `shouldNotPrintCaseLabelOnFlowbinPath()` | **C1.** `sharedService.createCaseLabel` never invoked when routing to a flowbin. |
| T10 | `shouldRouteToConfiguredDestinationEvenWhenCarrierSelected()` | **D2.** Carrier present + non-`PutAwayLane` override ⇒ configured destination wins; `transferUnitLoadToCarrier` **not** called. |
| T11 | `shouldStillUseCarrierWhenSkuHasNoOverride()` | **D2 regression guard.** Carrier present + destination *is* `PutAwayLane` ⇒ `transferUnitLoadToCarrier` called, as today. |
| T12 | `shouldResolveFlowbinAssignmentOnceForMultiCaseReceipt()` | **E1.** 12 cases ⇒ `findByAssignedlocationId` invoked once, not 12 times. |
| T13 | `shouldFailBeforeCreatingAnyRowWhenConfigurationUnusable()` | Rejection happens before the first `createUnitload` — the pre-submit-validation claim in Fix C. |

### 8.2 Unit — `UnitloadBusinessServiceUnitTest` (Fix C, PR1)

> ⚠ **`:193, 208` must be REWRITTEN, not extended — and it WILL fail first.** Line `:208` currently pins
> the old raw-ID text:
>
> ```java
> )).isInstanceOf(BusinessException.class)
>   .hasMessageContaining("not allowed on location");
> ```
>
> The new message (`Unit load type %1$s is not permitted on location %2$s (location type %3$s).` —
> **reworded 2026-08-06, review finding #4; this is the as-shipped template**) does not
> contain that substring, and neither does the bundle-miss fallback. So `mvn test -Dtest=UnitloadBusinessServiceUnitTest`
> in step 6 fails **by design**. **Tighten the assertion to the new rendered content — never loosen it to
> green.** An earlier revision said only "extend", which made deleting the guard the path of least
> resistance. SBDEV-2732 §3.6.1 carries the same instruction for the same line.
>
> ⚠ **Also add `@Mock LocationTypeRepository`** to this fixture (`:73`) and to
> `UnitloadBusinessServiceReplenBranchTest:68` / `UnitloadBusinessServiceReplenSyncTest:46` — see §7.2 step 3.

Rewrite the existing `should throw exception when unit load type not allowed on location` test (`:193-208`):

| # | Method | Asserts |
|---|---|---|
| T14 | `shouldRejectWithActionableMessageNamingLocationAndUnitLoadType()` | Message contains the location **name** and the UL **type name**. |
| T15 | `shouldNotLeakInternalIdsInConstraintMessage()` | Message contains **no** `unitloadtypeId=`, `location type=` or bare numeric id. This is the assertion that would have caught the original defect. |
| T16 | ~~`shouldStillPermitMatchingUnitLoadType()`~~ | **Gate logic unchanged** — a permitted type still passes. ⚠ **No new test was written.** The requirement is already met by the pre-existing `should successfully transfer with location constraints matching unitload type` (`UnitloadBusinessServiceUnitTest:673`), which was left untouched and unrenamed. Coverage is satisfied; the `T16` label does not appear in the suite. |
| T17 | ~~`shouldSkipConstraintCheckWhenLocationTypeHasNoConstraints()`~~ | The `PutAwayLane` behaviour (empty constraint list ⇒ allow) is preserved. ⚠ **No new test was written** — covered by the pre-existing `should handle empty location constraint list` (`:978`) and `should handle null location constraint list` (`:1000`). Same note as T16. |

**Added by the code review (2026-08-06, commit `89de3f0`) — not in the original spec:**

| # | Method | Asserts |
|---|---|---|
| T14b | `shouldResolveConstraintMessageFromBaseBundle()` | The key resolves from **`messages.properties`** under `Locale.ROOT`, **and** each file carries its own copy, read directly via `Properties.load` with an explicit UTF-8 reader. **This is the only assertion that can fail if the base-bundle copy is deleted** — `messages.properties` is the parent of every locale bundle, so deleting the key from `messages_en_US.properties` changes nothing under an en_US JVM and T14 stays green. Without T14b the entire rationale for duplicating the key had zero protection. |
| T14c | `shouldFallBackToNeutralWordWhenNameLookupsMiss()` | Both name lookups miss ⇒ `unknown`/`unknown`, and **no digit anywhere** in the message. The plan devoted three comment lines to these fallbacks but nothing exercised them — replacing both with a sentinel left the suite green. |
| T14d | `shouldRenderBusinessExceptionWhenLocationTypeIdIsNull()` | A null `Location.typeId` still yields a `BusinessException`, **and `findById` is never called with null** (`verify(..., never())`). Pins the guard added for review finding #3 — the guard must short-circuit, not rely on Spring Data tolerating null. |

### 8.3 Unit — `receivingForm.spec.js` (Fix A, PR1)

wms2-web-ui has a Jest suite; run via `node_modules/.bin/jest` under nvm node (no `yarn` on PATH).

| # | Test | Asserts |
|---|---|---|
| T18 | `renders the SKU's configured putaway location` | `defaultputawaylocationname: 'ICE PACK'` ⇒ rendered text contains `ICE PACK`, not `Put Away Lane`. |
| T19 | `marks a non-default destination as an override` | `(SKU override)` shown for `ICE PACK`; **absent for the literal `PutAwayLane`** (no spaces — using `'Put Away Lane'` here makes the test pass while production is wrong). |
| T20 | `falls back to the friendly lane label when the field is null` | Null ⇒ rendered text is **`Put Away Lane`** (the display label), no override marker. ⚠ **Corrected 2026-08-02** — this row previously expected the machine name `PutAwayLane`, contradicting `putawayDisplay`, which returns `DEFAULT_PUTAWAY_LANE_LABEL` for null. Writing it the old way pins the wrong string. The *comparison* uses `PutAwayLane`; the *render* never shows it. |
| T20a | `does not mark the default lane as an override` | **Regression guard for the string bug.** `defaultputawaylocationname = 'PutAwayLane'` ⇒ `isPutawayOverride` is **false**. Without this, the always-true bug is invisible. |
| T20b | `renders the friendly label for the default lane` | **Display-mapping guard.** `'PutAwayLane'` ⇒ rendered text is `Put Away Lane`, so the machine name never reaches an operator; `'ICE PACK'` renders unchanged. |
| T21 | `does not claim the SKU override when receiving to a container` | **Review finding M1.** `noContainer: false` ⇒ field is exactly `ICE PACK (not used — receiving to container)`; **no** `(SKU override)`. Pins the full string, because the qualifier's *wording* is the fix — a bare `— receiving to container` re-creates the ambiguity. |
| T22 | `claims the SKU override only when the destination is actually applied` | **M1's other branch.** `noContainer: true` ⇒ exactly `ICE PACK (SKU override)`, and the field contains neither `not used` nor `container`. Same SKU as T21 — the only difference is `noContainer`, so the pair pins the *branch*, not the rendering. |
| T23 | `associates the field with its label for screen readers` | **Verifier finding G5.** `aria-labelledby="lblPutawayString"` present, `#lblPutawayString` exists, and `for` has **not** returned (it must reference a labelable element; a `<span>` is not one). Nothing else in the suite or the verify script pins the association. |

**Added by the code review (2026-08-06, commit `04175fa`) — not in the original spec:**

| # | Test | Asserts |
|---|---|---|
| T24 | `says nothing about container usage before the operator has chosen` | **Review finding #1.** Mounts with **no `setData` at all**, so `data()`'s own `noContainer: false` / `parentContainer: null` render — the state the operator actually sees first. Field must be exactly `ICE PACK`: no `not used`, no `(SKU override)`. |
| T25 | `says "not used" when the tenant mandates receiving to a container` | `REQUIRE_RECEIVING_TO_CONTAINER = true` hides the switch, so `noContainer` can never become true and the qualifier **is** correct with no operator action. Field must be exactly `ICE PACK (not used — receiving to container)`. This is what stops the fix for T24 being "just hide the qualifier until `parentContainer` is set". |

> ⚠ **`mountForm` takes `noContainer: null` to mean "leave `data()`'s default alone" — `null`, not
> `undefined`.** A JS default parameter fires on `undefined`, so `{ noContainer: undefined }` silently
> collapses back to `true` and the test asserts the opposite state. This was caught only because T24/T25
> failed on the first run.
>
> ⚠ **T21 now also sets `parentContainer`.** `noContainer: false` alone is the *indeterminate* default,
> not a container choice — post-tri-state it renders no qualifier, so the original fixture no longer
> described the state T21 is about.

> **All ten are mutation-proven, not merely observed green** (T18–T23 on 2026-08-02; T24/T25 on
> 2026-08-06). Reverting the component fails all; injecting the spaced-literal bug fails **only**
> T20a/T20b; reverting the qualifier to the bare `— receiving to container` fails **only** T21; deleting
> `aria-labelledby` fails **only** T23; reverting the tri-state guard to the binary
> `noContainer === true` fails **only** T24; dropping the `requireReceiveToContainer` clause fails
> **only** T25.
>
> ⚠ **An earlier draft of this spec asserted against `wrapper.text()` and PASSED on unmodified code** — the
> hard-coded literal satisfied "contains Put Away Lane", and the card title already renders the item
> number, so `toContain('ICE PACK')` was vacuous too. Every assertion is now scoped to `#idPutawayString`
> via a `putawayField()` helper. Do not loosen it back to page-wide text.

### 8.4 Manual test plan

> **PR1's manual plan is rows 1, 6 and 7 only.** Rows 2-5, 8 and 9 all require Fix B on PRD and are
> **relocated to SBDEV-2821** (via 2732 D14 -> D15) — row 3's expected result is additionally **undefined until
> [SBDEV-2796](https://app.clickup.com/t/868kk4rmv) answers Q5**. Do not sign those rows off under this ticket.
>
> ⚠ **Row 1's expected result changes under PR1 alone.** The operator will now see the true destination
> `ICE PACK (SKU override)` on screen — and then, on submit, Fix C's *"Unit load type Case is not permitted
> on location ICE PACK (location type flowbin)."* (Wording updated 2026-08-06, review finding #4.) The two halves finally agree and name the same place, which
> is the improvement. But it is a **new visible contradiction** for the one PRD SKU in this state: the
> screen advertises a destination the system then refuses. Expected and acceptable; call it out in the
> closing comment so it is not re-reported as a regression.

| # | Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| 1 | Receiving screen shows the real destination | PRD (read) / UAT | Open receiving for SKU `ICE PACK`. **Then toggle "Do Not Receive to Container" both ways.** | Switch **on** (`noContainer`) ⇒ `ICE PACK (SKU override)`. Switch **off / container selected** ⇒ `ICE PACK (not used — receiving to container)` — see §5 Fix A's M1 amendment. Never `Put Away Lane`. ⚠ **Two expected-but-odd behaviours, neither a bug:** (a) on first paint, before the operator chooses, `noContainer` defaults `false` so the qualifier shows as a *prediction* of the default path; (b) where `REQUIRE_RECEIVING_TO_CONTAINER` is **on** the switch is not rendered at all, so the qualifier always shows and the override is genuinely never applied. | |
| 2 | **The ticket's headline case** | HMG PRD after PR2 | Receive advice `IBOL000221` (adviceposition 52077), 1000 units | Receipt succeeds; no constraint error | |
| 3 | Stock lands in the pick face | HMG PRD | After #2: `SELECT count(*) FROM unitload WHERE storagelocation_id = 52075;` plus the SU amount **and** `SELECT lowerbound, upperbound FROM fix_location_assignment WHERE assignedlocation_id = 52075;` | **Exactly one** UL at 52075, of type `PickLocation`. ⚠ **This row previously asserted "holding 1000 units" as success — that was the assertion that should have surfaced F3.** 1000 units against an `upperbound` of 84 is a ~12× overfill, so the expected result here is **undefined until Q5 is answered** and must be rewritten to match the chosen option. Do not sign this row off against the old expectation. | |
| 4 | **Invariant preserved (§1.3 Q6)** | HMG PRD | `SELECT fla.assignedunitload_id, (SELECT count(*) FROM unitload u WHERE u.storagelocation_id=52075) FROM fix_location_assignment fla WHERE fla.assignedlocation_id=52075;` | One FLA; its `assignedunitload_id` equals the single UL actually at 52075 | |
| 5 | Manual putaway is bypassed | HMG PRD | Open mobile putaway | No putaway task for the received ice packs | |
| 6 | Standard lane unaffected | UAT | Receive any normal SKU (destination `PutAwayLane`) | Unchanged: UL moves to the lane, case label prints | |
| 7 | Actionable error on a bad config | UAT | Point a SKU at a flowbin already assigned to another SKU; receive | Message names both SKUs and the location; **no** internal IDs; nothing committed | |
| 8 | Available for picking | HMG PRD | Allocate an order needing an ice pack | Allocates and picks from location `ICE PACK` | |
| 9 | OMS visibility | HMG PRD | After #2, check the `message` / outbox rows | A stock-change message was produced, as for a lane receipt | |

### 8.5 Post-implementation gate

- `mvn test -Dtest=UnitloadBusinessServiceUnitTest` green. ⚠ **`ReceivingServiceUnitTest` is NOT PR1's gate** — PR1 touches nothing in `ReceivingService`; it relocated with Fix B and verify `T1` is a permanent skip. **Do not** use `-Dtest='Outer#method'` for `@Nested` tests — it silently matches nothing and reports a false green.
- Jest: `node_modules/.bin/jest --testPathPattern=receivingForm` green under nvm node (no `yarn` on PATH). Fix A is half of PR1 and this is its only behavioural gate.
- Full `mvn test`: expect exactly 2 pre-existing failures (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`). **Revert the `archunit_store` file** that `mvn test` mutates.
- `mvn clean compile` must pass — the SBDEV-2217 IT lane cannot boot, so compile + unit tests are the gate. **No integration test is added**; recorded here as deliberately-skipped coverage with that reason.
- Verify script with **`RUN_TESTS=1`** reports **`Result: 27 pass, 0 fail, 22 skip`**; paste the literal line into the PR. (Was 26 before the review added `A10` on 2026-08-06.)
  ⚠ **`0 fail` on a default run is not acceptance** — the script exits `2` with `NOT ACCEPTANCE` when `RUN_TESTS != 1`, because a bundle key can exist and still not resolve, and `isPutawayOverride` can be always-true while satisfying every grep.
  ⚠ **The 22 skips are load-bearing. Never green this script by deleting them** — they are the relocated Fix B specification (`B1`–`B15`, `M3`–`M8`, `T1`).

### 8.6 Deliberately-skipped coverage

| Gap | Reason |
|---|---|
| Testcontainers integration test for the flowbin transfer | v2 IT harness cannot boot (SBDEV-2217). Manual rows 2-4 substitute. |
| Concurrency test for two replicas racing the FLA auto-create | No multi-replica test harness exists. Reasoned through in E2; the uniqueness-constraint check is in E2's implementation note. |
| Automated e2e allocate→pick→consume | No e2e harness for the mobile picking flow. Manual row 8. |

---

## 9. Acceptance

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2731-alternate-putaway-location-not-honored-receiving.sh`
`PROJECT_ROOT` is the **monorepo root** containing both `v2/wms2-api` and
`v2/wms2-web-ui` — not a single project root as in sibling scripts, because this
plan spans two repositories.

**Baseline on unmodified code, re-measured 2026-08-02 after the D14 scope change:**

```
Result: 9 pass, 15 fail, 24 skip          (exit 1)
```

> ⚠ **The previous figure `8 pass, 33 fail, 2 skip` is superseded and will not reproduce.** The tree did
> not move — the **script** did: `B1`–`B15` and `M3`–`M8` became skips, `T1` became a permanent skip, and
> `A8`/`A9`/`C6`/`M10`/`T3` were added. §7.2 step 1 tells the implementer to treat a mismatch as develop
> drift, so this figure must stay in sync or it sends them chasing nothing.

The 9 pre-fix passes are all intentional and **none is evidence of a fix**:

| Check | Why it passes pre-fix |
|---|---|
| `X1`-`X5` | File-existence guards for the five target files. |
| `C4` | **Genuine regression guard** — the constraint-gate lookup must survive Fix C, which is message-only. Must pass before *and* after. |
| `A5` | **Wrong-implementation guard**, vacuous pre-fix by construction: it asserts the spaced literal `'Put Away Lane'` never appears in a comparison, and pre-fix the file contains no comparison at all. Earns its place only once Fix A is written. Labelled `[guard: passes pre-fix]` in the output. |
| `C6`, `M10` | Same class — negatives keeping the putaway remedy clause out of the 35-caller site and the neutral key. Nothing to violate them yet. Both labelled `[guard: passes pre-fix]`. |

**All 15 failures were confirmed to have teeth** against the unmodified tree — `A1`-`A4`, `A6`-`A9`
(Fix A), `C1`-`C3`, `C5` (Fix C), `M1`, `M2`, `M9` (bundles).

**Acceptance for PR1: `Result: 27 pass, 0 fail, 22 skip` with `RUN_TESTS=1`** (25 pass + `T2` + `T3`;
skips drop from 24 to 22 as `T2`/`T3` become live). There is **no** mid-flight state any more — this
ticket ships one PR. `0 fail` on a default run exits `2` with `NOT ACCEPTANCE`.

**Two false-green traps were found and closed while building this script — both
proven by running them, not reasoned about:**

1. `check_A1` originally asserted bare `putawayStaging`, which **already exists
   pre-fix** as the dead data prop at `receivingForm.vue:206` — it passed on
   unmodified code. Tightened to assert the template interpolation
   `{{ putawayStaging`.
2. The template's `file_not_contains` **fails open**. Demonstrated with a
   realistic one-character path typo (`receivingFrom.vue` for
   `receivingForm.vue`): the template helper returned **PASS**, falsely proving
   Fix A against a file that does not exist, while the guarded override correctly
   failed — and still correctly failed on the real file where the defect is
   present. This matters specifically because Fix A lives in a different repo
   from Fix B/C.

> **Verify-script hazard, proven 2026-07-31.** `verify-plan-template.sh` defines
> no `perl` helper (its set is `run`, `skip`, `file_contains`,
> `file_contains_n_times`, `file_not_contains`, `class_has_method`,
> `mvn_test_passes`). Its **`file_not_contains` fails OPEN**: on a missing file
> `grep -qE` exits 2 and the leading `!` turns that into a PASS. Since Fix A
> targets a file in a *different repo*, a mistyped path would green silently. The
> generated script therefore overrides it with
> `file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }`
> and adds a positive existence check per target file. `file_contains` is safe
> as written (exit 2 stays non-zero ⇒ FAIL).

### ⚠ This map assumes PR2 ships. It does not — and it is no longer this ticket's to ship (D14).

> PR2's scope moved to SBDEV-2732 and remains gated on Q5/C2b/Q1/Q4. **The AC rows below that depend on Fix B are therefore NOT satisfied by closing this ticket on PR1.** Read them as the acceptance map for the relocated work, not as this ticket's exit criteria.

The table below was written when Fix B was in scope. **PR2 is blocked on Q5**, and the
answer changes which ACs are met — this is the honesty gap the Critic flagged as B-6:

| Q5 answer | Ticket ACs that go **unmet** |
|---|---|
| **(a)** reject flowbins at config time | Four, including the headline: *"valid alternate destinations are honoured"*, *"received inventory and Unit Load placed in the configured location"*, *"manual putaway is bypassed"*, and *"Ice Pack SKU can be received successfully into the Ice Pack location"*. Option (a) fixes the display and the error message — it does **not** get ice packs into the ice-pack location. Saying otherwise would be dishonest to the requester. |
| **(d)** receive to the lane, replenishment fills the bin | *"placed **directly** into that location"* is unmet as literally worded, but the operator's goal is met (stock reaches the pick face without a manual putaway step). Requires the requester to accept the reworded outcome. |
| **(b)** or **(c)** | The table below applies as written, subject to the C2b/F1/F4/F5 rework. |

**Under PR1 alone, exactly two ACs are met:** *"receiving screen clearly displays the
effective destination"* and *"validation errors are actionable and do not rely only on
internal IDs"*. Everything else remains open. Do not mark this ticket resolved on PR1.

### Ticket AC → coverage (as designed with Fix B in scope)

| Ticket acceptance criterion | Covered by |
|---|---|
| Receiving loads the configured Default Putaway Location | Already true before this plan — `ReceivingService:454` and `receiving_dto_view` both resolve it. The defect was display and routing, not loading. §2 Bug A/B |
| Receiving screen clearly displays the effective destination | Fix A; T18-T20; manual row 1 |
| Valid alternate destinations are honoured | Fix B; T2, T3; manual row 2 |
| Received inventory and Unit Load placed in the configured location | Fix B; T2; manual rows 3-4. **Note the semantics differ from the ticket's wording:** the stock is placed in the location's *resident* `PickLocation` unit load; the transient `Case` UL is retired. A `Case` UL is never placed in a pick face — see §1.3 Q5. |
| Manual putaway is bypassed when direct putaway succeeds | Fix B (stock lands at its final location); manual row 5 |
| No unnecessary putaway task remains open | Manual row 5. Putaway is lane-scan-driven (no task entity), so there is nothing to close programmatically. |
| Standard Putaway Lane behaviour unchanged when no override exists | T1, T11, T17; manual row 6 |
| Invalid location/UL combinations detected before final submission where practical | Fix B's B2 hoist + T13. **No separate pre-flight endpoint** — rationale in Fix C. |
| Validation errors actionable, not internal IDs only | Fix C; T14-T15; manual row 7 |
| Receipt and inventory history record the final destination | **Partially covered, and honestly qualified.** T8 asserts the `Goodsreceiptposition` points at the surviving stock unit / UL. `Stockrecord` history is written by `createStockUnit` and `transferStockToUnitLoad` unchanged. **Not independently verified** that stock history renders the flowbin as the destination — manual row 3 inspects live state, not the history report. Do not sign off without checking the stock-history view for the received ice packs. |
| Ice Pack SKU can be received successfully into the Ice Pack location | Fix B; T2/T3; **manual row 2 is the definitive evidence.** Requires PR2 on PRD. |
| Automated tests cover valid + invalid alternate locations, incompatible UL types, cleared overrides, standard fallback | valid T2/T3 · invalid T4-T6 · incompatible UL type T14-T17 · **cleared override T20 only (UI); there is no backend test for `putawaylocation_id` reverting to the lane, because T1 already covers "destination is the lane" which is the same code path** · standard fallback T1/T11 |

---

## 10. Open Questions / Resolved Decisions

Resolved with the requester during analysis (2026-07-31):

| # | Question | Decision | Rationale |
|---|---|---|---|
| D1 | *(superseded — see D1′)* | — | Retired once PRD showed the `ICE PACK` flowbin has no FLA, which would have left the ticket's headline AC failing after PR2. |
| **D1′** | Flowbin with no `FixLocationAssignment` — reject, or create one? | **Narrow auto-create.** Create only when all four hold: destination is a flowbin · bin has no FLA · bin holds no UL · SKU is unassigned elsewhere. Reject actionably otherwise. | The operator already recorded intent unambiguously by setting `putawaylocation_id` to a flowbin, so creating the assignment *implements* that intent rather than inventing one. Both in-codebase precedents (`MobilePutAwayService:479`, `StockunitService:192`) auto-create, so this is consistent with them; the four-condition guard is what keeps it narrower. And code alone closes the ticket — no coordinated data step, no stranded `IBOL000221`. **QA hits AC 3 (happy path) first, not AC 4.** |
| **D2** | Carrier selected *and* SKU has an override — which wins? | **The configured destination wins and bypasses the carrier.** | The ticket forbids silently ignoring the destination. Today `:454` discards it with no message. Guarded by T10/T11 so the no-override carrier path is unchanged. |
| **D3** | One PR or phased? | **Two.** PR1 = Fix A + Fix C. PR2 = Fix B. | Mirrors SBDEV-2729's staging; keeps the behaviour change reviewable alone and ships the better error message first. |
| **D4** | Pair a v1 plan? | **v2 only now**; record v1 parity as pending for the sync sweep. | v1 is line-for-line equivalent (§3) but this ticket is filed as v2, and SBDEV-2642 is already closed. |
| **C1** | The flowbin path retires the `Case` UL — what about its case label? | **Suppress the case label on the flowbin path.** | The label exists to be scanned during manual putaway, and the flowbin path *is* the bypass of manual putaway — the ticket asks for that bypass explicitly. The UL it would identify is intentionally retired, and `sendToNirvana` rewrites `labelid` to `<label>-X-<id>`, so a printed label would not even scan. Relabelling against the resident UL was considered and rejected: that UL is permanent and already labelled, so a per-receipt "case label" for it is semantically wrong. **⚠ This is the one operator-visible behaviour change in the plan — confirm with the requester before PR2 merges.** |
| **C2** | `Goodsreceiptposition` is written before the transfer — does it dangle? | ⚠ **RESOLUTION RETRACTED — see C2b. Do not implement as written.** Originally: write the GRP row after the move, from the `Stockunit` returned by `transferStockToUnitLoad`. | `sendToNirvana` (`UnitloadBusinessService:346-352`) does **not** delete — it relocates to Nirvana, sets `entityLock = GOING_TO_DELETE`, and renames `labelid`. There is no `unitloadRepository.delete` anywhere in `src/main/java`. So the row survives and the FK holds. But it would be a *retired* UL with a mangled label, and — sharper — on the **second and later** receipts `transferStockToUnitLoad` merges into the resident UL's existing stock unit, so `GRP.stockunitId` would also reference a retired row. Recording the survivor fixes both. Guarded by T8. Precedent for GRP↔UL mattering: SBDEV-2485 (staging-lane `printable` derives from GRP membership). **⚠ But take only the IDs from the survivor — see C2a.** |
| **C2a** | Which `amount` does the reordered GRP row record? | **This case's received quantity, never the returned stock unit's amount.** | Found while verifying C2, and it would have been a corrupting bug. `transferStockToUnitLoad` does `destinationStockUnit.setAmount(destinationStockUnit.getAmount().add(amount))` and **returns the DESTINATION stock unit** (`StockunitBusinessService:392`). So `receivedStockUnit.getAmount()` is the **cumulative flowbin balance**, not the case quantity — a 1000-unit receipt in 12 cases would write GRP amounts of 83, 166, 249 … instead of 83 each. That is not merely a reporting error: **`ReceivingService:373-378` sums `Goodsreceiptposition::getAmount` to enforce `allowoverdelivery`**, so inflated rows would make later receipts falsely trip the over-delivery guard. `saveGoodsreceiptPosition` therefore takes the surviving **ids** from the post-transfer result and the **pre-transfer per-case amount** separately. Guarded by T8a. |

### Still open

> **None of these block PR1, and none is owned by this ticket any more.** Q5 (with F3 and C2b) went to
> **[SBDEV-2796](https://app.clickup.com/t/868kk4rmv)**; Q1 and Q4 travel with the code to **SBDEV-2732**.
> Retained here in full because 2796 and 2732 reference this section as the source.

| # | Question | Owner |
|---|---|---|
| **Q5** | **BLOCKS PR2.** Should receiving deposit 1,000 units into a pick face whose configured `upperbound` is 84 (F3)? Three coherent answers: **(a)** a flowbin is never a valid receiving destination — reject it at config time in SBDEV-2643, making Bug B unreachable and reducing this ticket to Fix A + Fix C; **(b)** it is valid, and receiving must respect `upperbound` — overflow routes to the lane or to overstock, which is a materially larger feature than this plan; **(c)** it is valid and bounds are advisory for receiving, accepted explicitly with the over-bound state documented. Note the requester's stated goal (SBDEV-2643) is a *pick* location for ice packs, so (a) contradicts the stated intent while (b) is the honest version of it. **(d)** — added after the Critic pass, and it may be the best of the four: **receive to the `PutAwayLane` as today, and let existing replenishment fill the pick face from there.** The bin's `lowerbound`/`middlebound`/`upperbound` already exist to drive exactly that, `recalculateForItem` already maintains the orders, and 134 PRD bins are already fed this way — so ice packs reach the `ICE PACK` location through the mechanism designed for it, respecting capacity, with **no** new receiving branch, no FLA auto-create, no `Replenishorder` locks in the receive transaction (F4), no Inbound-row lock (F5) and no `GoodsReceiptPosition` repointing (C2b). It does not satisfy the ticket's literal "manual putaway is bypassed / placed directly into that location" wording, but it satisfies the operator's actual goal — stock ends up in the ice-pack pick face without a manual putaway step.
| | **Fairness note (Critic finding):** my earlier framing was slanted. **(a) is under-costed** — it silently fails four ticket ACs, including the headline *"Ice Pack SKU can be received successfully into the Ice Pack location"*, since rejecting the configuration means the ice packs still cannot be received to that location. It resolves the *error message* and the *display*, not the operator's actual need. **My revised recommendation: (d)**, with (a) as the interim guard only if (d) needs design time. | **[SBDEV-2796](https://app.clickup.com/t/868kk4rmv)** — requester (Brent / Scott). Filed 2026-08-02; also blocks SBDEV-2732 Phase 1b for tier-1. |
| Q1 | C1 label suppression is an operator-visible change — does the warehouse expect a printed label for goods received straight into a pick face? | **SBDEV-2732** (travels with the code); requester decides before that work merges |
| ~~Q2~~ | **RESOLVED 2026-07-31.** `fix_location_assignment` has unique constraints on `assignedlocation_id`, `itemdata_id` **and** `assignedunitload_id` — see §7-HS E2. The replica race fails cleanly and D1′'s SKU-uniqueness condition is DB-enforced. | — |
| Q4 | **D2 is broader than "flowbin vs lane".** `routeToConfiguredDestination = (carrier == null) \|\| !isDefaultPutawayLane` is keyed on the destination *not being* `PutAwayLane`, so **any** non-lane destination now outranks a selected carrier — including plain stock locations like wineco's `Club08`. All four combinations are correct per D2's intent (see §5 B1), but this changes carrier-path behaviour for every override SKU, not just flowbin ones. Impact is currently nil (`REQUIRE_RECEIVING_TO_CONTAINER = FALSE` on all tenants; 1 override SKU on PRD, 1 on wineco-dev), but confirm the intent covers non-flowbin overrides too. Also: when the override wins, the operator's selected carrier is left linked at the workstation — verify nothing needs `unlinkSelectedPallet`. | **SBDEV-2732** (travels with the code); requester + implementer |
| Q3 | Should `StockunitService:189,198` (§0 row 10) adopt Fix C's new keys? Same defect class, different workflow. | Follow-up ticket |

---

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ `db_verified: true` — §1.3 Q1-Q7, four environments incl. PRD; root cause proven on the live failing row; queries + results recorded inline |
| 1 | **All callsites enumerated** | ✓ **for PR1** — Fix A is one component, and Fix C's site was enumerated with all 24 other `transferUnitLoadToLocation` callers (§0 row 17); that enumeration is what drove the remedy clause out of the message. ⚠ **NO for the relocated Fix B**, falsified by C2b: §0 enumerates callers of the *symbols being changed*, but C2b's consumer (`GoodsReceiptPositionService.adjust`/`delete`) reads a persisted **field** (`GRP.stockunitId`/`unitloadId`) that no changed symbol names. **Method lesson, carried to SBDEV-2732 + SBDEV-2796:** any plan repointing a persisted FK must grep readers of the **column/field**, not just callers of the method. |
| 2 | **Adjacent bugs** | ✓ §0 row 10 (`StockunitService` raw messages) found by pattern-grep, excluded with rationale + Q3; row 16 (unvalidated config writers) routed to SBDEV-2643 |
| 3 | **Backward compatibility** | ✓ No API, schema or payload change. Error-response *text* changes (Fix C) — §6 notes it; the response shape is unchanged. Behaviour changes are D2 and C1, both flagged; C1 has an open confirmation (Q1) |
| 4 | **Concurrency** | ✓ **N/A for PR1** — Fix A is client-side and Fix C adds one `findById` inside an already-failing path in an existing transaction. **No new lock, no new transaction, no new shared state.** ⚠ **Open for the relocated Fix B**, where all three sub-analyses were corrected or withdrawn: E1's scope was wrong (the Inbound row is tenant-global, not same-SKU — F5); E2 missed two of three non-idempotent effects and the rollback-only hazard (F4); E3's "no cycle" is withdrawn because the enumeration omitted `Replenishorder` (F4). That work transfers to SBDEV-2732 unresolved. |
| 5 | **Multi-tenant** | ✓ All reads are tenant-scoped inside `tenantTransactionManager`; no cross-tenant query. Verified the defect is tenant-config-dependent (canonical vs migrated `location_type` ids — §1.3 Q2) |
| 6 | **Error handling** | ✓ Four new `BusinessException` paths, each with a bundle key in both files, each covered by a test (T4-T6, T14-T15), each rolling back via the existing `rollbackFor` |
| 7 | **Observability** | ✓ `LOG.info` on FLA auto-create (the one non-idempotent effect), `LOG.warn` with full context on constraint rejection. No new metric — §7-V2 row 8 states why |
| 8 | **Rollback / migration** | ✓ None needed — no Flyway change, no sysprop row, no backfill. Deploy order in §7.1 |
| 9 | **Test coverage** | ✓ §8.1 T1-T13, §8.2 T14-T17, §8.3 T18-T20, manual §8.4 rows 1-9, skipped coverage declared §8.6 |
| 10 | **Cross-version (v1↔v2)** | ✓ §3 — v1 carries all three defects at named lines; deferred to the sync sweep per D4, not silently dropped |

---

## 12. Implementation Status

**PR1 implemented 2026-08-02; rebased onto fresh `origin/develop` and code-reviewed 2026-08-06.**
Not yet pushed — no PR opened.

| Item | Status |
|---|---|
| PR1 branch | `bugfix/SBDEV-2731-alternate-putaway-location-not-honored-receiving` in **both** repos |
| PR1 commits — `wms2-api` | `b623561` Fix C (bundle-keyed constraint message) · `89de3f0` code-review response |
| PR1 commits — `wms2-web-ui` | `94e87d2` Fix A (bind the real destination) · `04175fa` code-review response |
| PR2 branch / commits | **N/A — relocated to SBDEV-2821** (D14 sent it to 2732; 2732 D15 sent it onward). This ticket closes on PR1. |
| Rebase | 2026-08-06 onto `origin/develop` (`169065c` api / `743142e` ui). One conflict, in `messages.properties`: develop's SBDEV-2632 added `placeholder=%1s` to the base bundle at the same spot. Purely additive — both kept. |
| Verify baseline (pre-fix) | `Result: 9 pass, 15 fail, 24 skip` (recorded §7.2 step 1) |
| Verify final | **`Result: 27 pass, 0 fail, 22 skip`** with `RUN_TESTS=1`, run against a symlink shadow root so it grades the worktrees, not the main checkouts. 27 rather than the planned 26: the review added `A10`. |
| `mvn clean compile` | BUILD SUCCESS |
| `mvn test` summary | 79 pass / 0 fail across `UnitloadBusinessServiceUnitTest`, `UnitloadBusinessServiceReplenBranchTest`, `UnitloadBusinessServiceReplenSyncTest`, `ReceivingServiceUnitTest` |
| Jest summary | `receivingForm.spec.js` 10 pass / 0 fail; ESLint 0 errors (21 pre-existing warnings, none on changed lines) |
| Tests added | **api** — `UnitloadBusinessServiceUnitTest`: T14 (exact rendered message), T14b (base-bundle isolation via `Locale.ROOT` + direct `Properties` reads), T14c ("unknown" fallback), **T14d** (null `location.typeId` — review #3), T15 (no id leak). `@Mock LocationTypeRepository` added to the two sibling fixtures. **web-ui** — `receivingForm.spec.js`: T18/T19/T20/T20a/T20b/T21/T22/T23, plus **T24** (untouched defaults) and **T25** (container-mandating tenant) from review #1/#2. |

### Code review — 2026-08-06 (first review of the implementation; both earlier passes reviewed the *plan*)

0 Critical, 0 High, 3 Medium, 6 Low. Verdict **COMMENT** — nothing blocked merge. Actioned:

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | MED | `isPutawayDestinationApplied` was binary but the form has three states — the untouched default render claimed `(not used — receiving to container)` before the operator had chosen, on every non-container-mandating tenant | Fixed — tri-state `true`/`false`/`null`, template tests `=== false` |
| 2 | MED | No test pinned the component's own defaults; every case wrote `noContainer` first, and the container-mandating tenant was never exercised | Fixed — T24 + T25 |
| 3 | MED | `locationTypeRepository.findById(null)` → `IllegalArgumentException` → HTTP 500, replacing the very message this ticket ships | Fixed — short-circuit guard + T14d |
| 4 | LOW | `A unknown unit load` / `A Inbound Pallet unit load` | Fixed — reworded to `Unit load type %1$s is not permitted…`; key name unchanged |
| 5 | LOW | Comment claimed "35 callers … 34 of them"; actual is 24 call sites | Fixed — corrected, and records SBDEV-2778 as a second entry point |
| 6 | LOW | T14b's `Properties.load(InputStream)` decodes ISO-8859-1 vs `ResourceBundle`'s UTF-8 | Fixed — explicit UTF-8 reader |
| 8 | LOW | Verify script had no static guard for the M1 amendment's guard | Fixed — `A10` added, negative-tested |
| 7, 9 | LOW | T14c's `doesNotContainPattern("\d")` redundant behind an exact `hasMessage` (not vacuous); 12-param constructor smell | **Not actioned** — no behaviour at stake; #9 is pre-existing and the PR adds the minimum one param |

All new assertions negative-tested: removing the null guard fails T14d only; reverting the binary guard fails T24 only; dropping the `requireReceiveToContainer` clause fails T25 only; loosening `=== false` fails A10.

**Reviewed interaction with work merged after implementation:** SBDEV-2778's `ReturnAdviceAutoReceiveService:556` calls `receiveGoods(id, null, …)` — carrier-null, so it reaches `ReceivingService:492` and this ticket's throw site, wrapping the `BusinessException` as the *cause* of an OMS-facing `WebserviceBusinessExceptionClientSide`. OMS's payload is byte-identical before and after (the cause is never interpolated into `description`; `getErrorMap()` returns only `{status, description}`); only the stack-trace header improves. Nothing pattern-matches the old message text — the only hits for `"not allowed on location"` / `"unitloadtypeId="` anywhere in `src/` are two comments in the test. SBDEV-2781's receiving work (both repos) does not overlap; `defaultputawaylocationname` is still in `receiving_dto_view`.
| ClickUp status | `in development` (set 2026-07-31). **On PR1 merge: move to `pr submitted`, then close.** The follow-up precondition is **satisfied** — [SBDEV-2796](https://app.clickup.com/t/868kk4rmv) was filed 2026-08-02 and holds Q5 + F3 + C2b. The closing comment **MUST** still say all three of the following, or this ticket reads as "receiving fixed" when it is not: |

**Required closing comment — do not paraphrase away any of the three points:**

1. **The reported 1,000-unit ICE PACK receipt still fails.** PR1 ships the display fix and an actionable
   error message. It does **not** make the receipt succeed. Two of the ticket's acceptance criteria are
   met (*"receiving screen clearly displays the effective destination"* and *"validation errors are
   actionable and do not rely only on internal IDs"*); the rest remain open.
2. **The routing work moved to SBDEV-2732; the product decision behind it is [SBDEV-2796](https://app.clickup.com/t/868kk4rmv).**
   2796 must be answered before anyone can say whether ice packs will ever be received directly into the
   ice-pack location — the recommended option **(d)** reaches the same operator outcome via replenishment
   rather than direct placement.
3. **One new visible oddity on PRD**, for the single SKU in this state: the receiving screen will now
   correctly show `ICE PACK (SKU override)` and the submit will then correctly refuse it. That is the two
   halves finally agreeing, not a regression — see §8.4 row 1.
