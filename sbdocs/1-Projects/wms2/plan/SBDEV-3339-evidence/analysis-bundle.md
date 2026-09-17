# SBDEV-3339 — consolidated analysis bundle (input to plan drafting)

Target: `v2/wms2-api`, Java 21 / Spring Boot 3.5.9. Graded against `origin/develop` @ `221caed1` (local checkout was 35 behind; never read).
Tier **T3**. Ticket `in development`, retitled 2026-09-14.
Supporting detail: `db-evidence.md`, `architect-consult.md` (344 ln), `enumeration.md` (350 ln) in this directory.

---

## 1. Root cause

`CustomerorderService.cancelOrder` (`:722`), success branch (`orderCanBeCancelled == true`), identified by the log line `"cancelOrder: cancelling order positions"`:

1. loops `customerorderPositionService.cancelOrderPosition(...)` over every position,
2. sets `customerOrder.setState(WmsConstants.State.CANCELED)`,
3. saves, `finalizeBatchIfComplete`, enqueues `ORDER_BATCH_CANCELLED_FROM_WMS`.

It never performs the picking-tote teardown. **Three omissions**, not one:

| | clears stock `entity_lock` | nulls `pickingtote_id` | `sendToClearing(tote)` | sets `historytote` |
|---|---|---|---|---|
| `cancelOrder` success `:722` | ❌ | ❌ | ❌ | ❌ |
| `forceCancelOrder` `:407` | ✅ (+ the tote's **own** lock) | ✅ | ✅ | ✅ |
| `cleanUpCancelledOrder` `:599` | ✅ (stock only) | ✅ | ✅ | ✅ |

**Not a regression.** At the initial checkin (`a685e07b`) the success branch already had no teardown. Day-one omission.

## 2. Entry point and severity — the batch path

The live entry is **`POST /rest/order/cancelPositions`** (`OrderRestController:528`) — the OMS batch-cancel endpoint. It resolves the `CustomerorderBatch`, then **loops orders calling `cancelOrder(order, false)`**. So the defect sits on the *normal OMS cancellation path*, not a rare manual one.

Proven on Hydra PRD: `message.process = 'ORDER_BATCH_CANCELLED_FROM_PSD'` — 8 rows RECEIVED, 2026-07-31 → 2026-09-10, matching all 8 cancelled orders and both stranding dates. That process type is written only by `cancelPositions`. Control: 2066 message rows / 18 distinct processes.

`UtilRestController:1089` is the *other* `cancelOrder` call site and is **dead** — the class is annotated `@Service`, not `@RestController` (`:23`; positive control: `OrderRestController` carries `@RestController` + `@RequestMapping`). So `resetOrdersInReleasedStatus` does not route, and the architect's Q6 concern about it is moot.

**One live entry point: `OrderRestController:528`.**

### 2.1 Exposure window — why this took until 2026-07-31 to bite

Discriminator is the FIRST guard of `canOrderPositionBeCancelled`:
`if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) return false;` (650)

`false` ⇒ else branch ⇒ `cleanUpCancelledOrder` ⇒ **correct**. `true` ⇒ success branch ⇒ **strands**.
So the defect fires only while a position sits at **600 PICKED**. Hydra lingers there (7/7 stranded); WineCo UAT moves to 700 almost immediately (1.68M rows at 700, 74 at 600) and tore down 747/747.

## 3. Why the clear must be ORDER-level (settles ticket AC-1/AC-3)

A position-scoped clear is **not representable**:
- `pickingorder_position` has **no** pick-to-stockunit column (schema-verified on Hydra PRD).
- `picktounitload_id` FKs `pickingorder_unitload`, not `unitload`.
- `pickfromstockunit_id` is nulled at pick confirm — NULL on all 7 rows.
- `StockunitBusinessService.transferStockToUnitLoad` **merges by itemdata**, so two pick lines of one SKU become ONE stockunit row.

Clearing from `cancelOrderPosition` via `findByUnitloadId(tote)` would un-reserve stock belonging to sibling positions **still going out**.

**AC-3 resolves as: the two paths SHOULD disagree.** `cancelOrderPosition` stays position-scoped and must NOT clear; `cancelOrder` gains the teardown. Document the disagreement rather than removing it. (Note: `cancelOrderPosition` has exactly one production caller, so "protect other callers" is NOT the reason — the data model is.)

## 4. Fix design constraints (from the architect consult)

1. **Ordering — adopt `cleanUpCancelledOrder`'s:** `sendToClearing(tote)` FIRST, then `findByUnitloadId` → `setEntityLock(NOT_LOCKED)` → `saveAll`, then `historytote` + null `pickingtote_id`.
   - There is **no `entity_lock` guard** on the `sendToClearing` path — it passes `ignoreLock=true`. Neither sibling's ordering is guard-enforced.
   - The reason is **lock order**: `CODE_TRANSFER` ∈ `BLOCK_REALIGN_CODES`, so `transferUnitLoadToLocation` opens with a pessimistic `Pickingorder` pre-walk before any write. Clearing stock locks first issues Stockunit UPDATEs ahead of it, inverting canonical PO-before-SU.
   - **Measured caveat:** the inversion is theoretical here. `SELECT count(*) FROM pickingorder_position WHERE pickfromstockunit_id IN (60941,60947,60952,60957,159982,160025,160050)` → **0**. Positive control: only **1** row tenant-wide has a non-null `pickfromstockunit_id`. So write "it inverts the canonical order for no benefit", **not** "X breaks".
2. **`sendToClearing` moves a non-empty tote by design** — no emptiness guard, unlike `sendToNirvana` / `relocateEmptiedContainer` which both throw `"has stock!"`. Clearing is the correct destination (`STORAGE_LOCATION_CLEARING`, seeded in `V2.2.00`, marked "system used entity. DO NOT REMOVE OR LOCK IT!").
3. **Do NOT copy `forceCancelOrder`'s guard verbatim** — `pickingTote.getEntityLock() != BusinessObjectLockState.GOING_TO_DELETE` auto-unboxes a nullable `Integer`; `unitload.entity_lock` has no NOT NULL and no default ⇒ latent NPE. Use a null-safe comparison. **This is a sub-T3 finding in adjacent code; fix it on this ticket.**
4. **`sendToClearing`'s last two args are transposed** relative to its callee (`orderNumber`/`comment`). Pre-existing. **Copy the sibling's call shape verbatim; do NOT fix it here** — correcting it would change `unitload_record` semantics for every existing caller.
5. **Clear stock locks only, not the tote's own lock.** Measured: both stranded totes are at `entity_lock = 0`, and all 8 totes on the tenant are at 0. Copy `cleanUpCancelledOrder`'s shape (stock only); `forceCancelOrder`'s extra tote-lock clear is unnecessary here and drags in the NPE-prone guard.
6. **Placement is load-bearing:** the teardown must go AFTER the `cancelOrderPosition` loop. Chain is Batch ⊃ Pickingorder ⊃ Stockunit/Unitload throughout; the move path never touches CO/Batch, so no cycle.
7. **Null-guard the tote** — pick-pack orders reach the success branch with `pickingtoteId == null`. Both siblings carry SBDEV-2102 comments about exactly this.
8. **Do not disturb the SBDEV-3316 ordering pin** at `PickingorderBusinessService:648` (pinned by an `InOrder` test).

## 5. OPEN DECISION for the plan — partial-batch semantics

`cancelPositions` has **no transaction wrapper around its loop**; each `cancelOrder` commits independently, and neither controller is `@Transactional`. A throw mid-loop already leaves a partially-cancelled batch. The fix adds `sendToClearing` as a **new throw source**.

The plan must state explicitly: should a teardown failure on order N abort the remaining orders, or be contained per-order so the rest still cancel? Recommend contained-per-order with an ERROR log + metric, since aborting makes a cancel *less* complete than today — but this is a deliberate decision, not a default.

## 6. Test surface — a green suite will prove NOTHING

- `CustomerorderServiceUnitTest` is `@MockitoSettings(LENIENT)` (`:59`), so the STRICT_STUBS breakage premise is **false** for it. Only `PickingorderBusinessServiceUnitTest` is strict. An unstubbed **void** `sendToClearing` never throws under either.
- **No `cancelOrder` success-path test sets a non-null `pickingtoteId`** — the fixture at `:198-216` never calls it. So the fix breaks nothing, and a green suite afterwards is not evidence.
- Only `PickingorderBusinessServiceUnitTest:1547-1591` asserts a lock after cancel — that is the model for the new test.
- `CustomerorderPositionServiceUnitTest` has zero lock assertions (positive control: 603 lines, 25 `cancelOrderPosition` refs).

**Baseline:** 216 tests, 0 failures, 0 errors, 0 skipped across the three classes @ `221caed1`.

**Gate must write:** a `cancelOrder` success-path test WITH a non-null `pickingtoteId` asserting (a) stock `entity_lock == NOT_LOCKED`, (b) `pickingtote_id == null`, (c) `sendToClearing` invoked, (d) ordering via `InOrder`. Mutation-check each; the failure message must name the lock state.

## 7. Adjacent / out of scope

- **`CustomerorderBatchService.cancelBatch`** — identical defect, worse shape (nulls `pickingtote_id`, no lock clear, no `sendToClearing`, no `historytote` ⇒ residue invisible to the query that found the 7). **Vestigial:** zero `src/main` callers, no controller route, no UI reference in any of 5 repos (positive controls 144/21/235/122/5 files containing "cancel"). Superseded by `cancelPositions`. **DECIDED (Nam, 2026-09-14): propose for DELETION on this ticket; do not fix, do not fold into this diff.**
- **Doc drift, in scope for the same PR:** `wms2-cancel-cascade-workflow.md` carries 8 false claims (D-1…D-8), including §5's *"cancelBatch release[s] entity locks (so stock is returnable)"* — which tells a reader this defect is already fixed. Correct at least D-1/D-2. Doc is 69 days past its own re-verify date.
- **Out of scope:** `BusinessObjectLockState` is documented nowhere in `sbdocs/` — propose a doc ticket, do not absorb.
- **Out of scope:** `StockunitService.removeLock` refusing `PICKED_FOR_GOODSOUT` (`OPERATOR_REMOVABLE = {QUALITY_FAULT, ON_HOLD}`) is **why** the defect has no operator workaround — cite in §1 severity, do not widen the set.

## 8. Blind spots to state in the plan

- The `setEntityLock` grep has a proven miss: `BillofladingService:1599/1605` write `entityLock` via bulk JPQL (`SHIPPED` 405 — 328 of 804 PRD rows reach the DB only that way).
- `@Modifying updateStateByIds` (`CustomerorderRepository:166`) can write 800 and is invisible to a `setState` grep; its sole caller passes `PACKED`. Latent only.
- Fleet blast radius is **not** established — only Hydra PRD + the two WineCo tenants were reachable. Ticket **AC-5** (before/after on a UAT tenant) is runnable now that `wsl-wineco-uat` reconnected, but WineCo is a poor subject: it essentially never enters the exposure window.
- WineCo UAT's one orphaned tote unit (`T-0010`) has **no established provenance** — do not attribute it.
