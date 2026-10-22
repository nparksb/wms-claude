---
title: "SBDEV-1512 — Critic review (ralplan consensus, independent lane)"
ticket: "SBDEV-1512"
reviewer: "critic lane"
date: "2026-09-15"
target: "SBDEV-1512-snapshot-rev2.md (immutable snapshot of sbdocs/1-Projects/wms2/plan/SBDEV-1512-receive-damaged-from-returns.md)"
verdict: "ITERATE"
---

# Critic review — SBDEV-1512

**Verdict: ITERATE.** The design is sound and the §1.3 reframe (grade the lock, not the location) is
correct and independently verified. But five High findings stand between this document and an
implementable plan, and three of them are places where a named deliverable cannot be executed as
written or where the plan's own stated guarantee is unreachable in the running system.

**Reference point.** Every code claim below was derived against `origin/develop`, fetched
2026-09-15: `v2/wms2-api` @ `9e294d4b`, `v1/wms-api` @ `4cdd945`, `v1/qa-api` @ `b905d77`,
`v1/qa-ui` @ `ad4284b`. The local `v2/wms2-api` checkout was not read.

## What holds (so the ITERATE is not read as a rejection of the design)

Verified against `origin/develop`, not taken from the plan:

- `stock_view.damaged` is `sum(CASE WHEN ((su.entity_lock = 103) OR (ul.entity_lock = 103)) THEN su.amount ELSE (0)::numeric END)`
  and references no location name. §1.3's reframe is correct and is the most valuable paragraph here.
- `transaction_detail` **is** a union of per-`activitycode` arms — `0 AS damaged` appears in six arms
  and `coalesce(CASE WHEN sr.activitycode = ''DAMAGED'' AND sr.type = ''STOCK_CREATED''` in one,
  with the label `CASE` (`WHEN tr.damaged != 0 THEN ''Damaged''`) applied per row. §1.3's correction
  to `wms-damaged-capability.md` §6(b) is right, and Alternative D's rejection reason 1 is right.
- Exactly three `setEntityLock(...QUALITY_FAULT)` sites: `StockunitService:585`, `UnitloadService:179`,
  `MobileMoveUnitloadService:563` (instrument: `git grep -n "setEntityLock(" origin/develop -- src/main/java`,
  full listing read). See L2 for the blind spot the plan did not state.
- `receiveGoods` is `public void`, with exactly two callers (`ReceivingController:437`,
  `ReturnAdviceAutoReceiveService:653`). The source-compatible-return-type argument in §3.2 is right.
- `600`/`601`/`602` are taken in `WmsConstants` (`RETURN_AUTO_RECEIVE_PARTIAL`, `PRINTER_NOT_AVAILABLE`,
  `RETURN_AUTO_RECEIVE_ABORTED`); `git grep -n "= 603" -- src/main/java` returns nothing. 603 is free.
- §0 row 11 holds: the warning envelope is built generically (`warning.put("code", autoReceiveOutcome.code())` …),
  so a fourth `Status` needs no controller edit.
- W2's rejection is honest and load-bearing: v1 `AdviceRestController` has
  `if (advicePosition.getAmountOfBottles() < 0)` and then `position.setNotifiedamount(...)` before
  `receivingService.receiveGoods(pos.getId(), null, false, pos.getNotifiedamount().intValue(), ...)`,
  which hits `throw new BusinessException("argumentMustBeGreaterZero", "amount", amountBottles)`.
- Defect A is real: `dispositionSelection.vue` assigns `this.chosenDisposition = preferred_disposition.disposition_id`
  in `mounted()` and emits only from `changedDisposition()`, wired as `@change="changedDisposition"`.
- §1.4 and §8 constraint 4 handle the ShipItEZ/v1 environment truth correctly and explicitly
  ("Do not report this ticket as 'fixed for ShipItEZ in production'"). Criterion 7's specific trap is
  not present.

---

## HIGH

### H1 — The plan's central wire design makes every damaged receipt an over-delivery, and the document never says so

`AdviceRestController` (v2) sets the notified quantity from the **undamaged** field only:

> `position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles()));`

§3.1 pins `amount_of_bottles` to "the **undamaged** quantity | **No** [change]", while §3.2 makes
`AutoReceiveLine.amount` "the **total** to receive". So for a 7+3 line the WMS stores
`adviceposition.notifiedamount = 7` and then receives 10 against it. `ReceivingService.receiveGoods`
contains:

> `if (amountReceived + amountBottles > notifiedAmount) { throw new BusinessException("Not allowed to receive more than notified! Notified: " ... ` 

guarded by `if (!advice.getAllowoverdelivery())`. The design survives **only** because `create()`
hard-codes `adviceEntity.setAllowoverdelivery(true);` for every advice it builds. The plan does not
contain the strings `overdeliver`, `allowoverdelivery` or `notifiedamount` anywhere in §3–§9
(instrument: `grep -n -i "overdeliver\|allowover\|notifiedamount"` over the snapshot — the only hits
are E3 in the frontmatter and M5). This is a silent, unpinned, single-flag dependency under the
entire feature.

The consequences the plan also does not state:

1. Every damaged return permanently breaks the invariant the plan's own evidence uses as its health
   check — E3's *"all 1037 RETURN advices are FINISHED with `goodsreceiptposition.amount == notifiedamount`"*.
   After this ships, that query returns a growing population of mismatches and nobody has been told
   it is expected.
2. The receiving screen reads "ordered 7 / received 10" (`receiving_dto_view` /
   `ReceivingDtoViewRepository`), and `AdviceRepository`'s `SUM(ap.notifiedamount)` understates
   required quantity. The supporting evidence file's E6 confirms this blast radius and confirms it
   does **not** reach the three report functions — but E6's conclusion never made it into the plan.
3. §6 "Backward Compatibility" asserts eight rows of impact and lists none of this.

**To close H1:** add a §3 subsection stating that the receive is deliberately an over-delivery
against `notifiedamount`; cite `setAllowoverdelivery(true)` as the enabling precondition; add a unit
test pinning that `create()` still sets it (so the day someone flips it, a named test fails rather
than every mixed return); add a row to §6 naming the two Java consumers and the receiving screen;
and add an assertion to I1 that `adviceposition.notifiedamount = 7` while `goodsreceiptposition.amount = 10`,
so the intended asymmetry is graded rather than discovered.

### H2 — `DAMAGE_FAILED` is invisible to the only caller. §3.4's core property is false as written.

§3.4 justifies the new status with:

> `isWarning()` … "The caller must be told. The controller turns it into `200` + warning envelope, which OMS does parse (a `204` is short-circuited)."

The caller on this path is **qa-api**, not the OMS Laravel app. `AdviceRestController` emits
`body.put("status", "success");` alongside the warning map, and `qa-api`'s
`flask_app/common_util/wms_api.py` `send_wms_create_advice` does:

> `if data.get('status') != 'success': raise WmsException(...)` … `return {'status': 'success'}`

It never reads `warning`. So a `DAMAGE_FAILED` produces: a `service_log` row (only because
`insert_wms_response_in_service_log(url, request, data)` runs before the status check), a `LOG.error`,
and a counter the estate does not scrape. **The operator at the QA station sees an unqualified
success, the WMS UI shows a `FINISHED` advice, and the damaged bottles are received as normal
sellable stock.** That is the original defect, re-created in the failure path, with the advice now
closed so the dock path cannot recover it either.

T1.9 cannot detect this: it asserts the envelope is *produced*. Nothing in §7 asserts anyone
*consumes* it. This is precisely criterion 1's failure mode — an AC that passes while the client's
damaged report stays empty.

**To close H2:** either (a) add to Phase 2 a qa-api change that inspects `data.get('warning')` on a
200 and surfaces it (a `service_log` row is not a notification), with a named test; or (b) state
explicitly that `DAMAGE_FAILED` is a log-and-metric-only outcome invisible to every operator, delete
"The caller must be told" from §3.4, and say who is expected to notice it and how. Option (b) is
honest but then §3.4's justification for a fourth `Status` over reusing `PARTIAL` weakens, and that
should be argued rather than assumed.

### H3 — Phase 4's producer half names a file that does not contain the defect

§0 row 6, §3.9 and §4 row 11 all attribute the string-shaped error payload to
`v1/qa-api flask_app/views/parcel_info.py`:

> "`views/parcel_info.py` assigns `{'status': 'failure', 'messages': str(exc)}` — a **string**"

It does not. `parcel_info.py`'s branch is only:

> `if result.get('status') == 'failure': response = result; code = 400`

The single producer on `origin/develop` is **`flask_app/view_helpers/returns_helper.py:420`**
(instrument: `git grep -n "'messages': str(" origin/develop -- flask_app` → exactly one hit; the
surrounding block is the compensating-rollback path inside `process_managed_returned_parcel`). An
implementer working from §4 row 11 opens `parcel_info.py`, finds nothing matching the description,
and either invents a change or ships the consumer half alone — which §3.9 itself says is the wrong
fix ("fixing only the consumer leaves the producer free to break the next consumer").

T4.2 inherits the error: it names `tests/test_unit/.../test_parcel_info.py` for a behaviour that
lives in `returns_helper`.

**To close H3:** retarget §0 row 6, §3.9, §4 row 11 and T4.2 to
`flask_app/view_helpers/returns_helper.py` and its compensating-rollback branch, and re-check
whether `parcel_info.py` needs any change at all.

### H4 — T1.7, "the single most important assertion in the plan", is unspecified on the axis that actually breaks

§3.3 declares `private void applyDamage(...) throws BusinessException, FacadeException`. But
`setLockDamaged` reaches `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_DAMAGED).orElseThrow(() -> new EntityNotFoundException(...))`
and `unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_BOX).orElseThrow(() -> new EntityNotFoundException(...))`
— **unchecked**. `moveStockToNewDamagedContainer` opens with
`locationRepository.findByIdForUpdate(damagedLocation.getId())`, whose 5 s `lock_timeout` surfaces as
an unchecked Spring `PessimisticLockingFailureException`. §7.3 row 8 already asserts "a timeout
surfaces as `DAMAGE_FAILED`", which is only true if the damage loop catches `RuntimeException`.

The plan never says it does. The existing receive loop does, and carries an explicit warning that it
is not optional:

> "RuntimeException is NOT optional. … Catching only the checked pair would let that escape as an HTTP 500 with positions already committed, no counter and no named-SKU log — bypassing this entire mitigation."

If the damage loop catches only the declared pair, an unchecked throw escapes `execute()` →
`create()` → HTTP 500, **after** every position has been received and **before** `markFinished` runs.
The advice is left `OPEN` with all its stock already received — an operator dock-receiving it doubles
the stock, which is the exact hazard §3.4 introduced `DAMAGE_FAILED` to avoid. And §3.5's conditional
pre-flight does not close it: the pre-flight is a `readOnly` gate, and §3.5 itself says "it does not
close" the window.

T1.7 as written — `applyDamage_returnsDamageFailedWhenSetLockDamagedThrows` — does not say which
exception. A test stubbing `BusinessException` passes while the real failure modes escape.

**To close H4:** state in §3.3/§3.4 that the damage loop catches `BusinessException | FacadeException | RuntimeException`,
with the same rationale as the receive loop; split T1.7 into a checked case and an **unchecked** case
(`EntityNotFoundException`), and require the mutation check on both.

### H5 — The recovery story for a failed damage step has no data behind it

§3.4: "Recovering from a failed damage step is a manual damage move in the existing UI
(`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`), not a re-receive." §5.1 row 1 and §3.2 both state the design
"stores the damaged quantity nowhere new" — verified: E1's `%damag%` scan finds nothing on `advice`,
`adviceposition` or `goodsreceiptposition`, and no migration is added.

So when the damage step fails, the WMS holds **no record anywhere** of how many units of which SKU
were damaged. `AutoReceiveOutcome` carries `failedSku` but no quantity; the `stockrecord` comment
`"RETURN DAMAGED " + positionExternalId` exists only if `setLockDamaged` succeeded. The operator
asked to perform a manual damage move has no source for the number except a `LOG.error` line joined
by correlation id — which, per H2, they will never be shown.

The same gap applies to the `PARTIAL` recovery route the plan leans on throughout: a dock operator
re-receiving an `OPEN` advice receives `notifiedamount` (= undamaged) and the damaged units vanish
silently. That is the defect this ticket exists to fix, re-created in the documented recovery path.

**To close H5:** either persist the damaged quantity (a column on `adviceposition`, which re-tiers
the ticket and needs Nam's call), or write it into a durable, queryable place that already exists
(the `ADVICE_IMPORT` `Message` row's answer field carries `autoReceiveOutcome.description()` — make
the description carry SKU and quantity), and name the query an operator runs to recover. State
explicitly that the dock-recovery path drops the damaged quantity, so nobody treats it as a working
fallback.

---

## MEDIUM

### M1 — Alternative C's disqualifying reason is false

§9 Alternative C: "(c) a fully-damaged line gives `amountBottlesPerCase = 0`, and `amountBottles -= 0`
**never terminates** — an infinite loop in a `@Transactional` method holding a tenant connection.
That last point alone disqualifies it."

The loop is unreachable. `receiveGoods` guards it ~170 lines earlier:

> `if (amountBottlesPerCase < 1) { throw new BusinessException("argumentMustBeGreaterZero", "amountBottlesPerCase", amountBottlesPerCase); }`

A fully-damaged line throws a clean `BusinessException` before the `while`. Reasons (a) and (b) still
stand and are sufficient, so the conclusion survives — but the *decisive* reason is wrong, and
criterion 3 asks whether the rejections are honest against the code. Fix the rationale or drop (c).

### M2 — T1.10 passes against a no-op implementation

T1.10: "An advice with no damaged key produces no `setLockDamaged` interaction and a `204`". That is
a `never()` assertion with no positive control. An implementation in which `applyDamage` was never
written at all, or is never called on any path, satisfies it perfectly. The plan already knows this
failure mode — it flags exactly it on T1.5 ("a `never()` on a method nobody calls passes vacuously")
— and then does not apply the same guard one row later. Add the ungated positive control (the same
test class must contain a damaged-key case proving the interaction *does* occur).

### M3 — No unit test grades the success path of `applyDamage`, so PIT cannot see the most obvious mutant

T1.6 grades `bind`. T1.7/T1.8 grade failures. T1.10 grades the zero case. T1.11 grades `receiveGoods`'s
return. **Nothing** asserts that on a 7+3 line `setLockDamaged` is invoked with `new BigDecimal(3)`
against the id `receiveGoods` returned. A mutant swapping `line.damagedAmount()` for `line.amount()`,
or dropping the `damagedAmount > 0` guard, survives every unit test in §7.1 and is caught only by I1
— an integration test, which the PIT recipe (`-DtargetTests='net.aim_ai.wms.unit.service.…'`) does not
run. The repo rule is "mutation-check every new assertion with PIT scoped to the changed class"; that
rule cannot reach the plan's primary behaviour as tested. Add a `ReturnAdviceAutoReceiveServiceUnitTest`
row asserting the argument captured on `setLockDamaged`, with a fixture where `damagedAmount != amount`
(a 3-of-10 fixture, not a 5-of-5 one, so the swap mutant lands in a distinguishing band).

### M4 — §5.3's qa-api snippet raises `KeyError` on a payload that omits the key

§5.3 checklist: `'amount_of_bottles_damaged': returned_items[item.item_id]['qty_damaged'] or 0`.

`returned_items` is `keyed_returned_items = {item['item_id']: item for item in returned_items}`
(`returns_helper.py`) — raw request dicts. The rest of the codebase treats the key as optional:
`returns_helper.py` uses `returned_item.get('qty_damaged', 0)` in two places. A subscript here is a
500 on every return whose client payload omits `qty_damaged`, shipped into **live v1 production
traffic on day one** per §8 constraint 1. Use `.get('qty_damaged', 0) or 0`, and give T2.1 a case
with the key absent.

### M5 — T3.2's expected result is factually wrong

T3.2: "Unset / unmatched preference → no emit, **select renders empty** (the OQ-3 case)".

`dispositionSelection.vue` declares `data() { return { chosenDisposition: 1, } }`. When
`preferred_disposition` is undefined, `mounted()` assigns nothing and the `v-select` renders
disposition **1**, not the `placeholder="Choose Option"`. T3.2 would fail against correct code, and
the natural way to make it pass — defaulting `chosenDisposition` to `null` — is an unrequested
behaviour change that also changes what the parent's untouched `disposition: 1` means. Restate T3.2
as "no emit occurs; `chosenDisposition` remains at its `1` default".

### M6 — "No new sysprop … adding a flag would create a second way for the feature to be silently off" is false; one already exists

§3.1. `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` already is that second way: it gates
`ReturnAdviceAutoReceiveService` entirely, so on a tenant where it is off, qa-api sends
`amount_of_bottles_damaged`, the WMS parses it, and **nothing** applies damage — the damaged units
are simply never received, exactly as today, with no warning and no log. Because `resolveRefs` never
runs, §3.5's `Damaged` pre-flight does not run either. The claim as written is a completeness claim
("none", "a second way") and is wrong on its own axis. Restate it as: no *new* flag is added, and
name the existing flag as a pre-existing silent-off path with its degradation stated in §6.

### M7 — Sub-T3 follow-ups are filed as "proposed", contradicting the policy the same paragraph cites

§10's follow-ups section opens: "Per the ticket policy, a finding whose own tier is under T3 goes
onto **this** ticket; a T3 finding is proposed" — and is then titled "Ranked follow-ups found during
analysis (**proposed, not filed**)", containing FU-1 (T2), FU-2 (T1), FU-4 (T2) alongside FU-5 (T3).
`wms-triage` is explicit: "Never drop a finding to stay tidy. A finding recorded only in a plan
**dies when that plan is archived**." FU-2 in particular is a live HTTP 500 on the REGULAR advice
path that burns `externalid`, ranked "do first" — it should be a comment on SBDEV-1512 now, not a
row in a document that gets archived. Move FU-1, FU-2 and FU-4 onto the ticket; leave only FU-5 as a
proposal.

### M8 — §5.2's test range omits T1.11 (criterion 8: confirmed, and slightly worse than stated)

§5.2 says "Tests T1.1–T1.10 (§7)"; §7.1 runs to T1.11 and §8's Phase 1 gate says "T1.1–T1.11".
§5.2 is the odd one out. It matters more than a numbering nit because T1.11
(`ReceivingServiceUnitTest.receiveGoods_returnsCreatedStockunitIds`) is the only test in a
**different class** — an implementer ticking §5.2's boxes drops the one row that guards the
signature change §3.2 depends on. Correct §5.2 to T1.1–T1.11.

---

## LOW

- **L1 — §0 census (c) overcounts.** "`AdviceDto|AdvicePositionDto` across `controller/` → 2
  controllers (`AdviceRestController`, `FileImportController`)". Re-run:
  `git grep -l -E "AdviceDto|AdvicePositionDto" origin/develop -- src/main/java/net/aim_ai/wms/controller`
  returns **one** file. `FileImportController` references only `AdviceUploadDto`
  (`importInboundBols(@RequestBody List<AdviceUploadDto> adviceList, …)`). The conclusion (§0 row 14,
  out of scope) is unaffected; the stated count is not what the stated instrument produces.
- **L2 — the QUALITY_FAULT enumeration's blind spot is understated.** §1.2 names only "a native-SQL
  `UPDATE`". There is a fourth way to arrive at `entity_lock = 103` that names no constant:
  `StockunitService:577` `stockUnitDest.setEntityLock(stockUnit.getEntityLock());` propagates whatever
  the source carried. The count of three *literal* sites is right; "no path in v2 receives stock into
  a damaged state" leans on it and should name the propagating write as the blind spot, because
  Alternative A's rejection reason 1 is built on the invariant.
- **L3 — §3.10 says "three" and shows four.** Heading: "Why D1 covers all three reporting surfaces";
  the table has four rows; the prose says "misses the third and fourth entirely". Pick one; the
  fourth (the OMS wire) is not a reporting surface, which is probably the intent.
- **L4 — §3.7's "twice" undercounts.** `git grep -n "FAIL_ON_UNKNOWN_PROPERTIES" origin/develop -- src/main/java`
  on `v1/wms-api` returns three: `WebConfigurer:47`, `WebConfigurer:81`, **and `StartApplication:61`**.
  Direction of the claim is unaffected; the number is wrong in a paragraph whose whole point is that
  a code read of this kind has been wrong before.
- **L5 — no effort estimate anywhere, and no Acceptance Criteria section.** Four phases across three
  repos with no per-phase estimate, and §7 is a test inventory rather than numbered ACs. `wms-tdd-gate`
  is chartered to "write failing tests from a reviewed plan's **acceptance criteria**"; it will have to
  synthesise them from §7.
- **L6 — §3.3/§3.4 never say how `createdStockunitIds` survives between the two loops.** §3.4 mandates
  "Receive **all** positions first, then apply damage"; §3.3's signature is
  `applyDamage(AutoReceiveLine line, List<Long> createdStockunitIds)`. The map/list that carries ids
  from loop 1 to loop 2 is left to the implementer, on a path where getting the association wrong
  damages an arbitrary unit load — the exact hazard Alternative B was rejected to avoid.
- **L7 — §7.3 row 2 counts one extra transaction per damaged position; it is two.** `setLockDamaged`
  calls `triggerReplenishmentMaintenance(stockUnit.getItemdataId())` after
  `moveStockToNewDamagedContainer` returns, and `recalculateForItem` is `@Transactional(REQUIRED)` —
  with no ambient transaction it opens its own. Sequential, so the "slots, not milliseconds" argument
  still holds, but the row's arithmetic is off by one per damaged position.

---

## Criterion-by-criterion summary

| # | Criterion | Verdict |
|---|---|---|
| 1 | Testable ACs that grade the thing that matters | **Fails.** I1/I2 grade `entity_lock = 103` correctly and the §1.3 rule is applied to them. But T1.9 (H2) and T1.10 (M2) both pass while the outcome stays broken, T3.2 asserts a false expectation (M5), and no AC grades `notifiedamount` (H1) or recovery (H5). |
| 2 | Mutation-readiness | **Fails.** The plan states the attributable-kill and dominant-band rules in the §7 preamble, applies them well to T1.4 and T1.5 — and then leaves the primary behaviour (M3) reachable only by an integration test PIT does not run, and T1.10 vacuous. |
| 3 | Fair alternatives | **Mostly passes.** A, B, D and E are argued against the real code and their rejections hold. C's decisive reason is false (M1). |
| 4 | Risk-mitigation clarity | **Passes.** Owners are named in §5.1; §7.3 row 6 says "recorded, not mitigated" rather than "monitor"; FU-4 names "ask Brent". The exception is H5, where the mitigation is an operator action with no data source. |
| 5 | Concrete verification steps | **Mostly passes.** §7.5 M1–M9 are executable and M9 is an unusually good blind-spot closer. Gaps: H3 (wrong file), L6 (unspecified plumbing), M8 (dropped test). |
| 6 | Claim discipline | **Mixed.** Method-and-blind-spot is stated inline far more often than is typical here, and E1/E6's zero-claims carry real positive controls. But the audit lands where the repo's own rule predicts: the three claims that break (L1, L2, M6) are all completeness claims, and not one of them is a number. The quantitative claims reproduced exactly. |
| 7 | Scope and tier honesty | **Passes on environment truth** (§1.4, §8 constraint 4 are exemplary — no implication that ShipItEZ gets this in production). **Fails on the ticket policy** (M7) and gives no effort estimates at all (L5). Phases 3 and 4 are genuinely separate defects, but bundling them is policy-compliant and each is independently shippable, which is argued well. |
| 8 | Known nit | **Confirmed and slightly worse than stated** — see M8. |

---

## The single weakest claim in the plan

§3.4, the `isWarning()` row:

> "**The caller must be told.** The controller turns it into `200` + warning envelope, which OMS does parse (a `204` is short-circuited)."

It is the load-bearing justification for introducing a fourth `Status`, and it is false against the
only caller on this path. `AdviceRestController` emits `body.put("status", "success")` next to the
warning; `qa-api`'s `send_wms_create_advice` branches solely on
`if data.get('status') != 'success'` and never reads `warning`. Nothing in §7 can detect this,
because T1.9 grades the producer and no row grades a consumer. It is the plan's one genuinely
unfalsifiable assertion: it is stated as a property of the system, it is wrong, and the test suite
designed around it is structurally incapable of noticing.
