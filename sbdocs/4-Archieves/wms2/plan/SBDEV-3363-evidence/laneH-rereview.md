# SBDEV-3363 — Lane H: scoped re-review of the fix pass (`2879d898`)

- **Worktree read (the only one):** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3363`
- **Scope:** `git show 2879d898` only — the fix pass answering `laneF-code-review.md` (5 Medium, 5 Low) and
  `laneG-conformance.md` (2 PARTIAL assertion gaps). `2a80ed7f` is **not** re-litigated.
- **Tree state at review:** `git status --porcelain` **empty**; no Maven process running (`ps` → none).
  I started no build; every verdict below is from reading code and the existing `target/` reports.
- **Bottom line:** **10 of 12 findings FIXED, 1 PARTIAL (L1), 1 FIXED-with-a-caveat.** No regression, no new
  false claim in the load-bearing comments — I checked all four of the claims flagged as high-risk and every
  one of them holds against the code it cites. Four new **Low**s, all in comment scope-creep or assertion
  strength; nothing above Low.

---

## Verdict table

| # | Verdict | One line |
|---|---|---|
| M1 | **FIXED** | 400 / `GENERIC_ERROR` / aborts-the-batch — all three verified against `OrderRestController` |
| M2 | **FIXED** | `poPositions.isEmpty() → return true` verified; the pre-existing-bug framing is right |
| M3 | **FIXED** | fixture 1 reseeded `markedforcancellation = true`; branch-neutral (flag is never *read* in `cancelOrder`) |
| M4 | **FIXED** | fixture 2 javadoc now describes the post-fix route; matches plan §3.1.1 |
| M5 | **FIXED** | fixture 4 added; all three RAPID preconditions genuinely met (see §2) — **but see N4** |
| L1 | **PARTIAL** | the past-tensing left `"No terminal path in either direction."` asserted in the present, 3 lines above a ⚠ saying the opposite |
| L2 | **FIXED** | `coPositions.get(0)` cost recorded — **but see N2**, the mitigation claim is unconditional where the code is conditional |
| L3 | **FIXED** | outbox row asserted — **but see N3**, the `.as()` names a `processType` the assertion never checks |
| L4 | **FIXED** | comment now names `pickingPositions.get(0)` and explicitly excludes `coPositions.get(0)` |
| L5 | **FIXED** | folded into M4; `pickingconfirmationsent = true` now labelled inert, correctly |
| Conf-1 (fixture 1 outbox) | **FIXED** | `aggregateId` is the right key, direction is non-vacuous, `findAll()` is safe here |
| Conf-2 (fixture 3 sibling) | **FIXED** (literal) | assertion added — **but see N5**, it cannot fail before an earlier assertion |

---

## 1. The four high-risk claims, checked against the code they cite

### 1.1 `OrderRestController.cancelPositions` — 400, not 500; aborts the batch. **HOLDS.**

New comment (`CustomerorderService.java`, RAPID guard block):

> "IndexOutOfBoundsException is caught by `OrderRestController.cancelPositions`' `catch (Exception e)` and
> rethrown as `WebserviceBusinessExceptionClientSide(GENERIC_ERROR)`, which still leaves as a 400 — but
> carrying GENERIC_ERROR rather than the WRONG_STATE OMS handles, and, unlike the ToteTeardownException arm
> which `continue`s, it aborts the REST of the batch…"

Every clause verified in `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java`:

- The per-order catch chain is `ToteTeardownException` → `BusinessException` → `FacadeException` →
  `catch (Exception e)` (`:613-615`). `IndexOutOfBoundsException` is a bare `RuntimeException`, matches none
  of the first three, lands in the last: `throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);` ✅
- That throw is inside the method's outer `try` (opened at `:545`), whose handler ends
  `return ResponseEntity.badRequest().body(e.getErrorMap());` → **400**, same exit as the `WRONG_STATE` arm. ✅
- The `ToteTeardownException` arm really does `continue` (`:603`) while this arm throws out of both nested
  loops — so "aborts the REST of the batch, so every not-yet-processed order in the same call goes
  uncancelled" is exact. Orders already processed earlier in the call keep their own committed cancels
  (each `cancelOrder` is its own transaction), which the wording does not contradict. ✅

The previous "generic 500" claim is gone. **FIXED.**

### 1.2 `canOrderPositionBeCancelled` returns true early for a position with no pick lines. **HOLDS.**

`src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java:59-69`:

```java
    public boolean canOrderPositionBeCancelled(CustomerorderPosition customerOrderPosition) {
        if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) {
            return false;
        }
        List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
        …
        if (poPositions.isEmpty()) {
            return true;
        }
```

The `isEmpty()` early exit is reached for any position **below** PACKED with no pick lines, which is exactly
the shape the comment names. So on `origin/develop`, a RAPID order at ASSIGNED with `historytote != null`
whose first position has no pick lines does reach `pickingPositions.get(0)` on an empty list — the guard
closes a pre-existing latent bug, as the rewrite now says. The comment's hedge ("could already throw") is the
right strength. **FIXED**, and the "must NOT be dropped if that skip is ever reverted" instruction is the
correct durable form.

### 1.3 The `customerorder_cancellation_log` / `completeReversal` claim in fixture 2's new javadoc. **HOLDS.**

New text: *"…its pick-to unitload is at 800 with no unitload and zero stock, so `completeReversal` would throw
'manual intervention required' on it and poison the order's whole reversal call."*

Verified in `CancellationReversalService.completeReversal`: inside the `for (CustomerorderCancellationLog log : logs)`
loop, after the SBDEV-3316 re-resolution attempt,

```java
            if (log.getPicktostockunitId() == null) {
                throw new BusinessException("Reversal for position " + log.getCustomerorderPositionId()
                    + " cannot be completed: no source stock unit could be resolved for the pick-to"
                    + " unit load (picktounitload_id=" + log.getPicktounitloadId() + ")"
                    + " — manual intervention required");
            }
```

(`CancellationReversalService.java:234-239`). It throws from inside the row loop, so one unresolvable row
aborts the whole `completeReversal` call — "poison the order's whole reversal call" is accurate, and the
quoted string matches verbatim. The zero-stock/`unitload_id = NULL` premise is the plan's own measured fact
(§3.1.1, `picktounitload_id 585000950`).

One note, not a defect: the plan calls the lost log row *"immaterial"*; the javadoc upgrades it to *"an
improvement"*. The mechanism cited is real, so this is a strengthening rather than a contradiction — but it is
a claim the plan does not make, and it is the direction comments drift in. Recorded, not filed.

### 1.4 The `markedforcancellation = true` reseed does not change the branch. **HOLDS.**

`grep -n "getMarkedforcancellation" CustomerorderService.java` returns exactly **one** read, at `:231`, inside
a diagnostic `details` map unrelated to `cancelOrder`. Inside `cancelOrder` the flag is only ever **written**
(`:995` false on the success branch, `:1066` true on the deferred branch). Branch selection keys on:
`isAlreadyCancelled` → `state` only (`:688-690`), the club-batch guard → the batch, `isShippedOrPastCancellationBoundary`
/ `isPackedOrPalletized` → `state`, the `anyMatch` → position states, then `canOrderPositionBeCancelled`.
**None of them reads the flag.** Fixture 1 therefore takes the same path seeded `true` as seeded `false`, and
the assertion `isFalse()` now genuinely pins `:995`. The commit's measured mutant
(*"Expecting value to be false but was true"*) is consistent with this and is the correct kill. **FIXED.**

---

## 2. Fixture 4 — does it actually reach the RAPID block? **YES.**

The block's three preconditions, each traced to the fixture:

| Precondition (`CustomerorderService.java`, RAPID `if`) | Fixture 4 | Met? |
|---|---|---|
| `section != null` — via `client.getSectionId()` then `sectionRepository.findById(...)` | `rapidClient.setSectionId(section.getId()); clientRepository.save(rapidClient);` on the **same** `clientId` the order carries | ✅ |
| `section.getSectionpickingtype().equals(RAPID_PICKING)` | `section.setSectionpickingtype(WmsConstants.SectionPickingType.RAPID_PICKING)`; the constant is `public static final String RAPID_PICKING = "RAPID_PICKING"` (`WmsConstants.java:670`), so `String.equals` matches the persisted value | ✅ |
| `customerOrder.getState() == ASSIGNED` | `newOrder("ORD-3363-RAPID", WmsConstants.State.ASSIGNED, false, true)` | ✅ |
| `customerOrder.getHistorytote() != null` | `order.setHistorytote("T-3363"); order = customerorderRepository.save(order);` — saved **before** `cancelOrder`, so the re-read inside sees it | ✅ |

`client.sectionId` is genuinely wired, and the visibility is sound: `BaseRollbackIntegrationTest` deliberately
omits `@Transactional`, so each repository call commits in its own transaction and `cancelOrder`'s
`clientRepository.findById(...)` re-reads the committed row rather than a stale first-level cache entry.
Hibernate 2LC is off; `spring.cache.type=none` is set on the base class.

Entity constraints are satisfied: `Section` declares `@NotNull` on `number`, `clientId` and `sectionpickingtype`
(`model/Section.java:11-17`) — the fixture sets all three plus `name`. `SectionRepository` exists
(`repo/jpa/SectionRepository.java`). So the fixture cannot die in setup and silently "pass" a different way.

Reaching the guard also requires the position to be skipped by the new guard-loop `continue` (the position is
CANCELED, so `canOrderPositionBeCancelled` is never consulted) — and the `anyMatch` pre-check does not throw
because `800 < CANCELED` is false. Traced end to end, the fixture lands on `pickingPositions` = empty list.

**Independent corroboration:** `target/failsafe-reports/` records
`Tests run: 4, Failures: 0, Errors: 0, Skipped: 0` for this class, with all four method names present
including `cancelOrder_shouldNotThrow_whenRapidFirstPositionHasNoPickLines`; `failsafe-summary.xml` shows
`413/0/0/31`, matching the commit message's claim and the +4 over the 409 baseline. And the measured mutant —
neutralising the guard makes this test throw `IndexOutOfBoundsException` — is **dispositive on its own**: an
`IndexOutOfBoundsException` can only come from `pickingPositions.get(0)`, which is inside the RAPID block.
A fixture that missed the block could not produce it. **Not vacuous. M5 FIXED.**

See **N4** for the one way this coverage could silently evaporate again.

---

## 3. The outbox assertion in fixture 1

```java
        assertThat(outboxMessageRepository.findAll())
            .as("cancelOrder must enqueue exactly one ORDER_BATCH_CANCELLED_FROM_WMS for this order")
            .filteredOn(m -> order.getId().equals(m.getAggregateId()))
            .hasSize(1);
```

- **Right key.** The enqueue is `.aggregateType("CUSTOMER_ORDER").aggregateId(customerOrder.getId())`
  (`CustomerorderService.java`, success branch). `OutboxMessage.aggregateId` is a `Long`
  (`model/OutboxMessage.java:63-64, 113`). `order.getId().equals(...)` is `Long.equals`, i.e. a **value**
  comparison — it correctly avoids the boxed-`Long` `==` trap that bites above 127. ✅
- **Direction is non-vacuous.** A filter matching nothing yields size **0**, and `hasSize(1)` fails. The
  assertion cannot pass by matching nothing. ✅
- **`findAll()` is safe here, for a non-obvious reason.** `BaseRollbackIntegrationTest` is deliberately
  **not** `@Transactional`, so every write in this class **commits** to the shared
  `jdbc:h2:mem:rollback_tenant` and rows accumulate across test methods (fixtures 3 and 4 also reach the
  success branch and enqueue their own rows). `findAll()` is therefore *not* scoped to this test — but the
  `filteredOn(aggregateId == order.getId())` narrows it to a sequence-unique order id, which is the
  assert-by-id form this suite requires. Cross-class contamination is also excluded: the context's
  `ddl-auto=create-drop` recreates the schema, and ids restart. ✅
- `OutboxService.enqueue` is `@Transactional(propagation = MANDATORY)` and is **not** `REQUIRES_NEW`, so the
  row commits with the order — no orphan row from a rolled-back cancel. `OutboxService` is a real bean (the
  test's `@MockitoBean`s are `HttpRestService`, `SyspropService`, `MessageService` only), and
  `syspropService.getSysvalue(anyString())` is stubbed so `destinationUrl` clears
  `Objects.requireNonNull`. ✅

**Conf-1 FIXED / L3 FIXED.** One nit filed as **N3**.

---

## 4. New findings

### N1 — Low · `PickingorderBusinessService` census comment still asserts the sentence it was edited to retract

`src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` (the three-bucket census inside
`cleanUpCancelledOrder`), as it stands after the fix pass:

```
        //   · flagged, state < 800, picking order >= FINISHED          -> was STRANDED (2): every CO
        //     position already CANCELED, so canOrderPositionBeCancelled was false at `>= PACKED` and
        //     cancel #2 only re-set the flag, while finishPickingOrder throws. No terminal path in
        //     either direction. This is the hazard CustomerorderService's deferred branch documents
        //     as theoretical — it materialised twice, on wms2-wineco-dev, stuck since 2026-02-06.
        //     ⚠ CLOSED BY SBDEV-3363: … there IS a terminal path.
```

The pass past-tensed `STRANDED → was STRANDED`, `is false → was false`, `only re-sets → only re-set`,
`has materialised → materialised` — and **stopped**. `"No terminal path in either direction."` is left as a
bare present-tense assertion three lines above a ⚠ that says the opposite, and `"finishPickingOrder throws"` is
also still present tense. This is the same shape as the finding L1 reported: the sentence survives the edit to
the heading above it.

The ⚠ does resolve it for a careful reader, which is why this is Low and not Medium — but a self-contradicting
comment is precisely what L1 asked to remove. **Suggested:** `"…cancel #2 only re-set the flag, while
finishPickingOrder threw. There was no terminal path in either direction."`

**L1 verdict: PARTIAL.**

### N2 — Low · "Mitigated downstream" is stated unconditionally; the mitigation is conditional

`CustomerorderService.java`, the new `coPositions.get(0)` note:

> "…a STARTED picking order belonging to the open position is not demoted to PROCESSABLE and its pick-to
> unitloads are not cancelled here. **Mitigated downstream** — cancelOrderPosition still cancels the open line
> and settles that picking order via its allTerminal tail…"

Two overstatements against `CustomerorderPositionService.cancelOrderPosition:155-163`:

1. The tail is guarded — `boolean allTerminal = poPositions.stream().allMatch(p -> p.getState() >= FINISHED);`
   and only then `pickingOrder.setState(allCanceled ? CANCELED : FINISHED)`. On a picking order that still
   carries a non-terminal line from another order, `allTerminal` is false and the picking order is **not**
   settled at all. "Settles that picking order" is true only in the all-terminal case.
2. It settles to `FINISHED`/`CANCELED` — it never demotes to `PROCESSABLE`, which is what the RAPID side-door
   was for. And `cancelOrderPosition` writes **no** `PickingorderUnitload` rows, so the "pick-to unitloads are
   not cancelled" half of the cost is not mitigated by it at all. The SBDEV-3339 block after the loop touches
   one `pickingorder_unitload` row via `findLatestByUnitloadLabelid`, not the set the RAPID block cancels.

laneF's L2 wrote "**Partly** mitigated"; the fix pass dropped the qualifier. The decision to leave `get(0)`
unfiltered is settled and I am not reopening it — this is only about the comment claiming more coverage than
the code gives. **Suggested:** restore "Partly mitigated" and add "when `allTerminal` holds".

### N3 — Low · fixture 1's outbox `.as()` names a `processType` the assertion never checks

`.as("cancelOrder must enqueue exactly one ORDER_BATCH_CANCELLED_FROM_WMS for this order")` — the predicate
filters on `aggregateId` alone. Today only one enqueue site can fire on this path, so the two coincide; the
description is nonetheless asserting something the assertion does not. One conjunct closes it:
`.filteredOn(m -> order.getId().equals(m.getAggregateId()) && WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS.equals(m.getProcessType()))`,
which also pins the `idempotencyKey`-sharing invariant the enqueue comment describes if you assert the key too.

### N4 — Low · fixture 4 is guard-sensitive but **wiring-blind**

The test's only assertion is `reloaded.getState() == CANCELED`. If someone later drops
`rapidClient.setSectionId(section.getId())`, changes the section's `sectionpickingtype`, or removes
`order.setHistorytote("T-3363")`, the RAPID block stops being entered, the guard stops being covered — and the
test **still passes**, because the order reaches CANCELED either way. That is M5's failure mode recurring
silently: the fixture would become the fourth `Client`-with-no-`sectionId` test without a red.

Cheapest durable close: a second RAPID fixture with a **non-empty** `pickingPositions` and a `STARTED` picking
order, asserting the picking order is demoted to `PROCESSABLE` and its pick-to unitloads go to `CANCELED`.
That assertion fails the moment the section wiring breaks, and it also covers the block's body, which no test
touches today. Filing as Low rather than Medium because the measured mutant does pin the guard **as of this
commit**.

### N5 — Low · fixture 3's new sibling assertion restates the fixture

```java
        CustomerorderPosition reloadedCancelled =
            customerorderPositionRepository.findById(cancelledPosition.getId()).orElseThrow();
        assertThat(reloadedCancelled.getState())
            .as("the already-cancelled sibling is skipped, not re-processed")
            .isEqualTo(WmsConstants.State.CANCELED);
```

It closes laneG's literal gap, so **Conf-2 is FIXED** — but I could not construct a mutant it kills first:

- delete the **cancel-loop** skip → `cancelOrderPosition` throws `"order position is beyond status PACKED"`,
  `rollbackFor = BusinessException` rolls the whole cancel back, and the **order-state** assertion above it
  fails first;
- delete the **guard-loop** skip → the order takes the deferred branch and stays at ASSIGNED; again the
  order-state assertion fails first.

So the sibling is seeded CANCELED and asserted CANCELED with nothing in between that can move it — the same
"restates the fixture" shape M3 condemned in fixture 1. It is harmless and it satisfies the plan's §8.1 row;
it just is not evidence. If you want it to carry weight, assert the **cancelled sibling's pick line** is
untouched too (fixture 3 seeds one at CANCELED — a `< PACKED` mutant band would move it), or assert
`cancellationLogService` wrote no row for it.

### Nit (not filed) — import ordering

`import net.aim_ai.wms.repo.jpa.OutboxMessageRepository;` is inserted between `PickingorderPositionRepository`
and `PickingorderRepository`, out of alphabetical order. Checkstyle is a **dependency** in `pom.xml:265-268`,
not a configured plugin, so nothing enforces this. Cosmetic.

---

## 5. Plan conformance

No contradiction with `sbdocs/1-Projects/wms2/plan/SBDEV-3363-deferred-cancel-terminal-path.md`:

- §3.1.1's accepted delta (the lost `customerorder_cancellation_log` row) is now **visible from the test**,
  which is what M4 asked for. The javadoc's added "for this row that is an improvement" goes one step beyond
  the plan's "immaterial" — grounded, noted in §1.3, not a conflict.
- §8.1's fixture-1 row ("one `ORDER_BATCH_CANCELLED_FROM_WMS` outbox row") is now satisfied modulo N3.
- §8.1's fixture-3 row ("the cancelled one is untouched") is now satisfied modulo N5.
- §8.2.1 already records both review-pass mutants with their kill messages, matching the commit message.
  Fixture 4 is new relative to §8.1's three-row table but is documented in §8.2.1 — no stale claim.
- §10 Q4 (Nam's option (a): skip outright, write no log row) is still what the code does; the fix pass adds
  no `recordCancellation` call.

## 6. Regression check on the fix pass

- `CustomerorderService.java` — the diff is **comments only**. Verified: the only non-comment lines in the
  hunk are unchanged (`coPositions.get(0)`, the `findByCustomerorderpositionId` call, the `if (!pickingPositions.isEmpty())`
  guard). No logic moved.
- `PickingorderBusinessService.java` — comment-only.
- The test file adds one overload (`newOrder(…, boolean markedForCancellation)`) delegating from the 3-arg
  form, so fixtures 2 and 3 keep `markedforcancellation = false` unchanged. Only fixture 1 and the new
  fixture 4 pass `true`. No existing fixture's shape moved.
- Nothing in the pass touches `src/main` behaviour, so the `413/0/0/31` failsafe result and the unchanged
  `6629/0/0/1` surefire count in the commit message are consistent with a comment-and-test-only change.

**No REGRESSED verdicts.**
