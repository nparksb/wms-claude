# SBDEV-3320 — code review

- **Subject**: `a220be2a` "SBDEV-3320: mint a Cart unit load and hang picking totes off it", branch `feature/SBDEV-3320-cart-unitload-mint`, one commit off `origin/develop @ 4c2ae57b`.
- **Rebased mid-review.** §§1–5 were gathered at `1d722693` on `6dc054e1`; the branch was then rebased onto `4c2ae57b` (which brought in SBDEV-3319 and five other commits). **The production diff is byte-identical across the rebase** — `git diff 4c2ae57b...a220be2a --stat -- src/main/java` reports the same four files, and the only change to `MobilePickingService` is +4 lines of comment. Every finding re-verified against the rebased tree; line numbers in quoted snippets are post-rebase. §7 assesses the SBDEV-3319 interaction.
- **Reviewed in**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3320-review` (a separate worktree — the implementation worktree had another lane's Maven build running). Moved to `a220be2a` after the rebase.
- **Reviewer lane**: independent; no code was changed. Four mutants were applied and restored by file copy; `git status --short` is clean in both worktrees.
- **Verdict**: the design decisions D1/D2/D3/D5/D6′/D7′/D9/D10 hold up under adversarial reading and against all four live databases — but **the integration lane is red because of this change**, and `mvn test` cannot see it. **1 High, 4 Medium, 6 Low.**

> **⚠ Merge blocker.** `mvn -o verify` fails: `MobilePickingServiceIntegrationTest.mobilePickingService_Tote_Test:615 » Business unknown pickingType=PICK`, thrown from the new `isCartPickingSection`. CI runs `verify` and gates the image build on it, so merging as-is turns `develop` red and silently stops deploying. See **H-1**.

---

## 1. Instruments

### Unit lane (re-run, not trusted)

```
export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
cd .claude/worktrees/wms2-api/SBDEV-3320-review && mvn -o test
```

**`Tests run: 6488, Failures: 0, Errors: 0, Skipped: 1` — BUILD SUCCESS.** Matches the reported 6488/0.

### Integration lane — RED

```
mvn -o verify -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
```

**`Tests run: 388, Failures: 0, Errors: 1, Skipped: 31` — BUILD FAILURE.** The single error is caused by this commit (H-1). Everything else in the lane is green, so this is a clean one-error regression, not a noisy baseline.

**Re-run on the rebased `a220be2a`: `Tests run: 395, Failures: 0, Errors: 1, Skipped: 31` — BUILD FAILURE, same single error.** (395 vs 388 is SBDEV-3319's seven new ITs, all green.) The rebase did not fix it and could not have: the `default: throw` at `MobilePickingService:1551` and the `"PICK"` fixture at `MobilePickingServiceIntegrationTest:182` are both still present, unchanged, on both sides of the rebase.

Running `verify` was not optional diligence: `mvn test` runs surefire only, and the defect lives exclusively in the failsafe lane. The `-Dtest=ZzzNone` pairing is what makes it affordable — it selects surefire to nothing so you do not pay for the 6,488-test unit run first.

**Re-confirmed in isolation**, as the only build in that worktree, to rule out the concurrent-Maven false-red mode:

```
mvn -o verify -Dit.test=MobilePickingServiceIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
→ Tests run: 3, Failures: 0, Errors: 1 — BUILD FAILURE, identical throw
```

Every Maven invocation in this review ran in the dedicated `SBDEV-3320-review` worktree; the implementation worktree was only ever read from (`git show`, `git diff`, file reads).

### Mutation checks

Per the standing floor ("mutation-check every new assertion"), I broke what each new guard protects and confirmed red:

| # | Mutant | Result | Killed by |
|---|---|---|---|
| M1 | `findOrMintPickerCart`: `if (cartType.getId().equals(candidate.getTypeId()))` → `if (true)` | **SURVIVED** — 112 tests, 0 failures, BUILD SUCCESS | — |
| M2 | `StockunitService`: `carrierOpt.map(carrier -> !isCartCarrier(carrier))` → `map(carrier -> false)` (never refuse any carrier) | killed | `StockunitServiceUnitTest$SetLockOnHoldExtended.throwsWhenUnitloadIsOnCarrier:957` |
| M3 | `TransferOrderService`: `if (isCartCarrier(carrier))` → `if (false)` (drop the ascent break) | killed | `TransferOrderServiceUnitTest$TransferLineCarrierAscent.getTransferLineUnitLoads_shouldNotReRootOntoCart:1580` |
| M4 | `MobilePickingService`: move `attachToteToPickerCart(...)` **before** `transferUnitLoadToLocation(...)` | killed | `MobilePickingServiceUnitTest$ProcessPickCartMinting.processPick_shouldAttachCartAfterLocationTransfer…:3223` |

M4 is the valuable one and it holds: the D5 ordering trap is genuinely pinned by an `InOrder` verify that an end-state assertion could not have caught.

### Live databases

Queried Hydra PRD (`wms2-hydra`), Hydra UAT (`nywh-hydra-uat`) and WineCo UAT (`wsl-wineco-uat`); WineCo dev refused the connection twice (the known first-query-after-idle drop) and is the one gap in this table.

| Fact | Hydra PRD | Hydra UAT | WineCo UAT |
|---|---|---|---|
| `Cart` = `unitload_type` id | 6 | 6 | 6 |
| `Cart.unitloadallowed` | **true** | true | true |
| `Tote.onotherunitloadallowed` | **false** | false | false |
| existing `unitload` rows with `type_id=6` | — | 0 | 0 |
| distinct `section.sectionpickingtype` | `TOTES_ON_CART` (2 rows, 0 NULL) | `TOTES_ON_CART` | `RAPID_PICKING`, `TOTES_ON_CART` |
| `unitload` rows at `location_area.name='users'` locations | 0 across 8 user locations (no picking in flight at query time) | — | — |

`Cart.unitloadallowed = true` is the one that had to be checked and was not stated in the brief: the shared core still applies the **destination** gate (`if (destinationType != null && !destinationType.getUnitloadallowed()) throw`), and the exemption does not cover it. It passes on every tenant, so the attach will not throw there.

---

## 2. The four questions the brief flagged hardest

### 2.1 D1 — did the shared-core extraction change anything?

**No. The core body is byte-identical to the pre-change `transferUnitLoadToCarrier` body except the one gate line.** Verified mechanically rather than by eye:

```
git show origin/develop:…/UnitloadBusinessService.java | sed -n '285,367p'  >  old_body
sed -n '345,431p' …/UnitloadBusinessService.java                            >  new_body
diff -u old_body new_body
```

produces exactly one hunk — the comment block plus `if (!allowNestingExemption && sourceType != null && …)`. Everything the brief asked about is therefore provably intact: both SBDEV-3091 cycle guards (the `seen` ascent set and the `CARRIER_SELF_REFERENCE` / `CARRIER_IS_ITS_OWN_CARRIER` / `CARRIER_HIERARCHY_CYCLE` throws), the parent detach, the destination `unitloadallowed` gate, the `processTransfer` call and with it the `unitload_record` audit row. Exception types are unchanged.

**`@Transactional` placement is correct.**
- `transferUnitLoadToCarrier` keeps `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` and its exact 5-arg signature — all 8 callers hit the proxy exactly as before.
- `transferUnitLoadToCart` carries the identical annotation, and its only caller (`MobilePickingService.attachToteToPickerCart`) invokes it **cross-bean** through `unitloadBusinessService`, so the proxy applies and `Propagation.REQUIRED` joins `processPick`'s tenant transaction.
- The private core has no annotation, which is right: it is reachable only from those two, so the self-invocation carries no proxy but also needs none — the transaction is already open. No caller now bypasses a transaction that it previously had.

### 2.2 Is the Tote→Cart assertion airtight?

**Yes.** Both hops are:

```java
final String toteTypeName = tote.getTypeId() == null ? null
    : unitloadTypeRepository.findById(tote.getTypeId())
        .orElseThrow(() -> new EntityNotFoundException("UnitLoadType", tote.getTypeId())).getName();
if (!WmsConstants.UNIT_LOAD_TYPE_TOTE.equals(toteTypeName)) { throw new BusinessException(…); }
```

- **`typeId == null` on either side** → name is `null` → `!"Tote".equals(null)` is `true` → **refused**. The null case fails closed, which is the direction you want; a `null.equals(...)` inversion would have been the bug here and it is not present.
- **`unitload_type` row missing** → `EntityNotFoundException`, not a silent exemption.
- **Type name mis-cased or renamed on a tenant** → refused (the same brittleness `relocateEmptiedContainer` already logs a WARN about; not new).
- There is **no other path** to `allowNestingExemption = true`: the private core has exactly two call sites, and `grep` confirms the literal `true` argument appears only inside `transferUnitLoadToCart`, after both assertions.

Covered by `UnitloadBusinessServiceUnitTest$TransferUnitLoadToCart` — four tests including "refuses a source that is not a Tote" and "refuses a destination that is not a Cart". The `typeId == null` case specifically is **not** covered (see L-new below), but the behaviour is correct.

### 2.3 `findOrMintPickerCart` reuse selection

- **Several Carts at one location**: takes the first one the derived query returns. See **M-2** — this is reachable and the ordering is nondeterministic.
- **A Cart belonging to another picker**: not possible by construction — the reuse key is `locationRepository.findByName(SecurityContextUtils.getUserName())`, one Location row per username, so "this picker's location" is already private to the picker. The real exposure is a **shared login** (Hydra PRD has user locations named `admin` and `anonymous`), under which all pickers on that account collapse onto one cart. That is the known limitation the javadoc records, not a defect.
- **A Cart holding another order's totes**: intended (D6′ — "a cart of one is still a cart"), and harmless: the cart is system-client-owned, so every client-scoped query filters it out.
- **Linear scan performance: not a problem.** The scan is `findByStoragelocationId(userLocation)`, whose population is the cart plus the totes currently mid-pick for that one picker. Measured on Hydra PRD: **0 rows across all 8 user locations**, i.e. no historical accumulation at all. It cannot grow with order volume, only with the number of orphaned totes (see **L-3**).

### 2.4 `isCartPickingSection` throwing on an unknown picking type

**This is the question that turned out to have teeth — it is H-1.** My first answer, from reading alone, was "throwing is right": it is the literal shape of `CustomerorderService.processPackaging` (`default: LOG.error("unknown picking type={}", …); throw new BusinessException("unknown packageType=" + pickingType);`), it uses the better-behaved of the two exception types in play, and no NULL or third value exists on any live database. Running `verify` disproved the part that mattered.

Two claims of that reasoning were wrong:

1. **"Already fatal further upstream."** The upstream switch that throws `RuntimeException` on an unknown type lives in `resumePickingOrderIfExists`, **not** on the path into `processPick`. Nothing between the picking-order list and `processPick` interrogates `sectionpickingtype` at all. `isCartPickingSection` is the **first** code to read that column on this path, so the throw is a brand-new failure mode, not defence in depth.
2. **"Empirically unreachable."** True of tenant data, false of the codebase: `MobilePickingServiceIntegrationTest:182` seeds `s.setSectionpickingtype("PICK")`. That fixture had been valid for as long as it existed precisely *because* nothing on this path read the value — and `isCartPickingSection` now turns it into a failed pick.

What survives is the design point: the value space for this free-text column is wider than `{TOTES_ON_CART, RAPID_PICKING}` in practice, and the throw converts an unrecognised-configuration condition into a **hard picking outage for that section**. That is a much larger blast radius than the precedent I cited, because there the picking type *selects* the action and there is no safe default. Here there is one: don't attach a cart. It is also inconsistent with `isCartPickingSection`'s own two null branches, which both `LOG.warn` and `return false`.

See **H-1** for the recommendation.

---

## 3. Findings

Ranked. Every severity gets fixed per the standing instruction; the remedy column says whether that means code or a ticket note.

### HIGH

**H-1 — `isCartPickingSection`'s `default: throw` turns a green integration test red, and would turn an unrecognised section into a picking outage.**
`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

```java
default:
    LOG.error("isCartPickingSection: unknown picking type={} on section={}", pickingType, section.getName());
    throw new BusinessException("unknown pickingType=" + pickingType);
```

Measured, `mvn -o verify`:

```
[ERROR] MobilePickingServiceIntegrationTest.mobilePickingService_Tote_Test:615 » Business unknown pickingType=PICK
[ERROR] Tests run: 388, Failures: 0, Errors: 1, Skipped: 31 — BUILD FAILURE

net.aim_ai.wms.exceptions.BusinessException: unknown pickingType=PICK
    at MobilePickingService.isCartPickingSection(MobilePickingService.java:1539)
    at MobilePickingService.attachToteToPickerCart(MobilePickingService.java:1492)
    at MobilePickingService.processPick(MobilePickingService.java:542)
    at MobilePickingServiceIntegrationTest.mobilePickingService_Tote_Test(:615)
```

The trigger is `MobilePickingServiceIntegrationTest:182` — `s.setSectionpickingtype("PICK")`, a value invented by that test's own fixture. It has been harmless since the test was written because **no code on the `processPick` path had ever read that column**; the switch that would have rejected it lives in `resumePickingOrderIfExists`, which this test never calls. `isCartPickingSection` is the first reader, and it converts a working end-to-end tote pick into a 500.

Two reasons this is High rather than "fix the fixture":

- **It stops the deploy.** `.github/workflows/docker-image-develop.yml` runs `mvn -B -ntp clean verify` and the image `build` job declares `needs: test`. A red push run skips `build` entirely, so no image is pushed and neither Portainer webhook fires. The failure mode is "develop goes red and quietly stops deploying", and the only signal is the Actions tab. The PR check is advisory and cannot block the merge.
- **The behaviour it exposes is the real issue.** `sectionpickingtype` is a free-text `varchar(255) NOT NULL` with no constraint and no enum. The fixture proves the value space is wider than the two constants in practice; a tenant configured with a third value would now have *every pick in that section* fail, where today it picks fine. `isCartPickingSection` answers "should I attach a cart?", which has a safe negative answer — unlike `processPackaging`, whose switch selects the action and has none.

*Remedy: **code**, two parts.*

1. **Fail open in the `default` arm** — `LOG.error(...); return false;` — matching the method's own two null branches, which already log and return `false`. An unrecognised section then picks exactly as it does today: no cart, no outage. If you disagree and want the throw kept, that is a legitimate call, but it needs to be a deliberate one and it still needs part 2.
2. **Change the IT fixture to `TOTES_ON_CART`** (`MobilePickingServiceIntegrationTest:182`). This is worth more than making the lane green: with a real cart section, `mobilePickingService_Tote_Test` would mint a real Cart and attach a real Tote against Postgres — the only end-to-end proof the whole design works, and the one instrument that would also have caught **M-1**. Add an assertion on the tote's `carrierunitload_id` while you are there.

Do not do part 2 alone. It makes the lane green while leaving the production behaviour both unchanged and untested.

---

### MEDIUM

**M-1 — the Cart type filter in `findOrMintPickerCart` is untested, and the mutant survives the whole suite.**
`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

```java
for (Unitload candidate : unitloadRepository.findByStoragelocationId(userLocation.getId())) {
    if (cartType.getId().equals(candidate.getTypeId())) {
```

Replacing that condition with `if (true)` leaves `MobilePickingServiceUnitTest` at **112 tests, 0 failures, BUILD SUCCESS** (measured). No test in the class ever supplies a non-Cart candidate: the shared fixture stubs `findByStoragelocationId(anyLong())` to `emptyList()`, and the one reuse test returns a single `existingCart`.

This matters more than an ordinary coverage gap because **the list this filters is guaranteed non-empty of non-Carts in production**. `transferUnitLoadToLocation(tote, userLocation, …)` runs one line before the attach, so by the time `findOrMintPickerCart` scans, every mid-pick tote of this picker is at that location. If the filter regresses, the first *tote* is returned as "the cart" and `transferUnitLoadToCart` throws either `CARRIER_SELF_REFERENCE` (if it is the same tote) or `"accepts only a Cart as destination"` — picking stops for that operator, and no lane in the repo would have caught it.

*Remedy: **code***. Two tests: (a) `findByStoragelocationId` returns `[tote(typeId=1L), cart(typeId=6L)]` → assert `transferUnitLoadToCart` is called with `eq(cart)` and `createUnitload` never; (b) returns `[tote(typeId=1L)]` only → assert `createUnitload(any(), eq(6L), any(), any())` **is** called. Re-run M1 afterwards and confirm it now goes red.

---

**M-2 — nothing serialises the mint on the user location; two Carts can be created, and the reuse scan has no `ORDER BY`.**
`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java` — `Unitload cart = findOrMintPickerCart(userLocation);`

`processPick` takes `pickingorderRepository.findByIdForUpdate(pickingOrderId)` — a row lock on the **picking order**, not on the picker's location. Two concurrent `processPick` transactions for the same operator on two different picking orders (two devices, a reclaim, a retry after the `PessimisticLockingFailureException` catch in `PickingController`) both scan, both see no Cart, and both call `createUnitload`. There is no unique index to stop it: this repo declares zero unique indexes in its tenant migrations.

The consequence is not corruption — it is that `findByStoragelocationId(Long)` is a derived query with **no `ORDER BY`**, so once two Carts exist the picker's subsequent totes split between them in whatever order Postgres returns rows. The cart model quietly stops matching the physical cart, which is the one thing the feature exists to represent.

*Remedy: **ticket note** is defensible given the narrow window and cosmetic blast radius — but if you want the cheap code fix, make the scan deterministic (`min(id)` / sort by id) so at least the split is stable and one cart wins. A real fix needs a lock on the user `Location` row or a partial unique index on `(storagelocation_id) WHERE type_id = <cart>`, which is a bigger call than this ticket should make.*

---

**M-3 — `TransferOrderService` breaks out of the ascent without caching the Cart, so the DTO phase re-queries it.**
`src/main/java/net/aim_ai/wms/service/TransferOrderService.java`

```java
Unitload carrier = carrierOpt.orElseThrow();
if (isCartCarrier(carrier)) {
    break;
}
unitLoad = carrier;
carrierCache.put(unitLoad.getId(), unitLoad);
```

Every other exit from this walk puts the resolved carrier in `carrierCache`. This one does not, so downstream the DTO builder's `carrierCache.get(unitLoad.getCarrierunitloadId())` — i.e. `get(cartId)` — misses and falls through to `unitloadRepository.findById(...)`, once per cart-carried tote per order position. That is precisely the double-fetch the surrounding code was written to remove ("Fix B2: single findById per carrier traversal step (was double)").

*Remedy: **code***. One line: `carrierCache.put(carrier.getId(), carrier);` immediately before `break;`.

---

**M-4 — `isCartCarrier` is a byte-identical copy in two services, and a third Cart test already exists elsewhere.**
`StockunitService.java` and `TransferOrderService.java` both declare:

```java
private boolean isCartCarrier(Unitload carrier) {
    if (carrier.getTypeId() == null) { return false; }
    return unitloadTypeRepository.findById(carrier.getTypeId())
        .map(type -> WmsConstants.UNIT_LOAD_TYPE_CART.equals(type.getName()))
        .orElse(false);
}
```

"What counts as a Cart" is exactly the kind of predicate that drifts once it has two homes — and it already has a third, differently-shaped home in `UnitloadBusinessService.relocateEmptiedContainer` (`switch (type.getName()) { case WmsConstants.UNIT_LOAD_TYPE_CART: …`). The repo's own history makes the argument: SBDEV-3119's comment in `UnitloadService` calls out "the THIRD copy of this walk" as the copy that mattered most to the completeness of the fix.

*Remedy: **code***. Hoist to one method — `UnitloadService` is the natural home and both services already sit alongside it — and call it from both. Mechanical, low risk, and it means the next Cart-awareness fix lands once.

---

### LOW

**L-1 — the D9 test's assertion is conditional and can pass vacuously.**
`src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java`

```java
if (thrown != null && thrown.getMessage() != null) {
    assertThat(thrown.getMessage()).as(…).doesNotContain("on another unit load");
}
```

A mutant that throws with a `null` message, or that returns before reaching the guard at all, satisfies this test without executing a single assertion. The real narrowing *is* pinned — M2 was killed by the sibling `throwsWhenUnitloadIsOnCarrier` — but this test's own contribution is weaker than its name and its javadoc claim.

*Remedy: **code***. Make it unconditional: `assertThat(thrown).satisfiesAnyOf(t -> assertThat(t).isNull(), t -> assertThat(t).hasMessageNotContaining("on another unit load"))`, or stub the remaining collaborators so the method runs to completion and assert it does not throw at all.

---

**L-2 — the D8 test does not exercise the scenario it is named for, and that scenario is unreachable anyway.**
`MobilePickingServiceUnitTest.processPick_shouldReattachToCurrentPickersCart_whenToteStillCarriesAPreviousCart`

It sets `testUnitload.setCarrierunitloadId(5999L)` as "the previous picker's cart", but `stubHappyPathToToteAssignment()` stubs `unitloadRepository.findByLabelid("TOTE-001")` to `Optional.empty()`, so the code path **creates** the tote and never reads that field; and `unitloadBusinessService` is a mock, so nothing clears or sets a carrier. The assertion it then makes (`verify(…).transferUnitLoadToCart(…)`) is already made verbatim by the D3 and D5 tests. It is a fixture the CUT cannot observe, wrapped around a duplicate assertion — a green test that proves nothing new.

Separately, the real D8 handover is unreachable: when picker B resumes an order whose positions already carry `picktounitloadId`, `processPick` takes the else-branch and throws `toteName + " not on user location but " + location.getName()` because the tote is still at picker A's location. No re-attach happens, and none is needed. That is pre-existing behaviour, correctly untouched.

*Remedy: **code***. Delete it as a duplicate, or retarget it at that else-branch and re-title it. Leaving it named D8 will mislead the next reader into thinking handover is handled.

---

**L-3 — one cancel path leaves the tote attached to the cart forever.**
`CustomerorderBatchService` (the "Handle picking tote cleanup" block) cancels the `PickingorderUnitload` and nulls `customerOrder.setPickingtoteId(null)` **without moving the tote**. Nothing else clears `carrierunitload_id`, so that tote stays a child of the cart indefinitely.

Every other end-of-life path does detach, because each routes through `transferUnitLoadToLocation`, which clears the carrier at its head — verified for all three: `CustomerorderService.processPackaging` (TOTES_ON_CART → EmptyTotes), `PickingorderBusinessService.cleanUpCancelledOrder` (→ `sendToClearing`), `CustomerorderService.cancelOrder` (→ `sendToNirvana`). So the lifecycle closes everywhere except here.

The orphan itself is pre-existing — that tote already lingered at the user location and already fails the "not on empty totes location" check on reuse. What this change adds is a permanent carrier link on it, and one extra row in `findOrMintPickerCart`'s scan per orphan, forever.

*Remedy: **ticket note***. Record it on SBDEV-3320; the fix belongs to whichever ticket owns that batch-cancel path, not to this one.

---

**L-4 — `transferUnitLoadToCart` resolves both `unitload_type` rows, then the core resolves the same two again.**
Four `unitloadTypeRepository.findById` calls where two would do (`sourceType` / `destinationType` inside `transferUnitLoadToCarrierCore` repeat the entry-point's lookups). Free at runtime — same transaction, Hibernate L1 cache — but it is the kind of thing a reader stops on.

*Remedy: **ticket note**, or leave as-is.* Passing the resolved types into the core would widen its signature for zero behavioural gain, which is the worse trade.

---

**L-5 — a Cart is now a scannable carrier sitting at a user location holding mid-pick totes.**
`MobileMoveUnitloadService` accepts any scanned label; moving the cart would drag every attached tote to the destination. This fails closed rather than corrupting — `PickLineRealignmentService.assertNoActivePickFor` refuses a `BLOCK_REALIGN` move of stock behind an active pick — and nothing prints a cart label today, so there is no barcode to scan. Worth knowing before someone adds cart-label printing.

*Remedy: **ticket note** only. Do not add a guard for it now.*

---

**L-6 — the `typeId == null` case of the Tote→Cart assertion has no test.** *(referred to as "L-new" in §2.2)*
`UnitloadBusinessServiceUnitTest$TransferUnitLoadToCart` covers wrong-source-type and wrong-destination-type but not a null `typeId` on either side. The behaviour is correct (null name → `!equals` → refused; verified by reading, see §2.2) and the case is near-unreachable on live data, but it is the branch a future "helpful" refactor to `Objects.equals(toteTypeName, TOTE)` would silently invert.

*Remedy: **code***, if cheap — one parameterised test asserting both null-typeId directions are refused. Otherwise a ticket note is acceptable.

---

## 4. Item 6 — carrier-reader sweep

The brief asked whether any of the ~41 child-readers or ~27 carrier-readers that a picking tote now reaches was missed. **I did not find one.** Enumerated from `grep -rn "getCarrierunitloadId()\|findByCarrierunitloadId" src/main/java` (32 + 41 sites) and classified:

| Site | Reaches a picking tote? | Why it is fine |
|---|---|---|
| `StockunitService.setLockOnHold` | yes | **handled — D9** |
| `TransferOrderService` ascent | yes | **handled — D10**; its justification checks out, `getBatchLocationsByItemIdAndTransferableAreas` really does carry `area.name = 'users'` with no entity-lock filter |
| `MobileCycleCountService` ×5 | cart only | all five are `stockUnitList.isEmpty() → throw "No stock found"` *before* the child check, so a scanned Cart is refused earlier than the carrier branch; a scanned tote has no children |
| `UnitloadService` delete walks ×3 + `assertCarrierChainIsAcyclic` | cart only | reads the scanned UL's children; the tote has none. Deleting a Cart would correctly refuse ("Container has child container!") |
| `PickingorderBusinessService:594` | no | reads the **pick-from** unit load's carrier (the source pallet), not the tote's |
| `BillofladingPositionService.assertParcelCarrierNotShipped` | no | parcel-monitor only; and fails open when the carrier has no BOL position |
| `BillofladingService.combineStock` / `:652` / `:1578` | no | operates on pallet/parcel trees on a shipping lane |
| `PickLineRealignmentService.collectTree` | cart only | reached only by a cart move, which then correctly refuses via `assertNoActivePickFor` (see L-5) |
| `ViewDtoService:593`, `UnitloadService.getUnitloadDetails:619`, `MobileMoveUnitloadService:187`, `CustomerorderBatchService:1316`, `getDetailViewByKeyword` | yes | display-only — the tote now renders a parent-container name of `UL-…`. Informative, not wrong |
| `transferUnitLoadToLocation`'s fixed-location guard | no | checks whether the UL *being moved* has children; the tote has none |

The one genuinely new reachability is that a **Cart** is now a live carrier at a user location, and every guard above refuses it early rather than mishandling it.

## 5. Other things verified clean

- **Location constraints cannot refuse the mint.** `UnitloadService.createUnitload` writes the row directly and never consults `location_constraint` — the same reason `MobilePalletizingService` can mint a Pallet anywhere. So D7′'s concern (EmptyPallets does not permit Cart) genuinely only bites on the retire path, which the design avoids.
- **ArchUnit frozen store shrank by one line** — `TransferOrderService:367`'s `Optional.get()` became `orElseThrow()` and the entry was removed from `src/test/resources/archunit_store/5fb3fee0-…`. That is the right direction; a baseline that only ever grows is the failure mode, and this is the opposite.
- **`@Transactional` convention**: both new annotations specify `value = "tenantTransactionManager"` with `rollbackFor = {BusinessException.class, FacadeException.class}`.
- **`OptionalSafetyArchTest` compliance**: the `.map(...).orElse(false)` in `StockunitService` and the `orElseThrow()` in `TransferOrderService` both avoid `Optional.get()`, and the inline comments say why — correct, since that rule is pure call-site presence with no dataflow analysis.
- **D6′ label provenance**: `createUnitload(Location, typeId, clientId, activityCode)` → `basicService.generateNumber(EntityPrefixes.UNITLOAD, "UNIT_LOAD")`. Not derived from the picking order number, as decided.
- **System-client ownership** keeps the Cart out of every client-scoped query, including `TransferOrderService`'s own `customerOrder.getClientId().equals(currentUnitLoad.getClientId())` filter — which the D10 break correctly leaves evaluating the **tote's** client, not the cart's.

## 6. What to do next

1. **H-1 first** — it is the merge blocker, and part 2 of its remedy (a real `TOTES_ON_CART` fixture in `MobilePickingServiceIntegrationTest`) is also the cheapest way to get end-to-end coverage of the whole feature against Postgres.
2. **M-1** — add the two `findOrMintPickerCart` tests and re-run the M1 mutant to confirm it now dies. If the IT fixture from H-1 lands first, check whether it kills M1 on its own; it may.
3. **M-3, M-4, L-1, L-2, L-6** — mechanical, low risk, one pass.
4. **M-2, L-3, L-4, L-5** — ticket notes on SBDEV-3320. None of them should hold up the PR, and M-2's real fix (a lock on the user `Location` row, or a partial unique index) is a bigger call than this ticket should make on its own.
5. **Re-run `mvn -o verify`, not `mvn -o test`, before the PR.** This whole finding was invisible to the unit lane; a green 6,513 says nothing about the 395 tests that gate the deploy. The post-rebase 6513/0 you measured is a *surefire* count and does not contradict H-1.
6. **Nothing from SBDEV-3319 needs action** — see §7. The cancellation guard correctly precedes the mint, and no orphan Cart or audit row can survive a rollback.

### Note on the review's own instruments

My §2.4 verdict from static reading was wrong in two specifics, and running `verify` is what caught it. Both errors pointed the same way — toward "this is safe, no action" — which is the direction a reviewer's errors usually point. Worth remembering that the brief's question 4 was the one I was most confident about and the only one that turned out to contain a defect.

### Suggested memory (for Nam to accept or drop)

`sectionpickingtype` is free text with a third live value in the repo's own fixtures (`"PICK"` at `MobilePickingServiceIntegrationTest:182`), and the only code that rejects unknown values sits in `resumePickingOrderIfExists` — **not** on the `processPick` path. Any new `switch` on that column reaches values the constants do not cover.

---

## 7. Interaction with SBDEV-3319 (post-rebase)

SBDEV-3319 "cancelled positions must stop picking" landed on `develop` mid-review and edits the same method. Assessed against the rebased tree at `a220be2a`.

### 7.1 Does a cancelled pick reach the cart mint? — **No. Your reading is right.**

The ordering inside one transaction is:

| line | what |
|---|---|
| `:468` | `pickingorderBusinessService.assertPickNotCancelled(pickingPosition);` — SBDEV-3319 **G2** |
| `:544` | `transferUnitLoadToLocation(tote, userLocation, …)` |
| `:554` | `attachToteToPickerCart(pickingOrder, tote, userLocation, customerOrder);` — the mint |

G2 throws `FacadeException`, and `processPick` declares `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, so a cancelled position short-circuits before any tote or cart work. Confirmed.

### 7.2 Can a Cart be minted and then rolled back? — **Yes, and that is fine. Can it survive a rollback? — No.**

There is a *second* cancellation guard **after** the mint, which the brief did not mention: `assertPickNotCancelled(pickingPosition, copForLock, lockedCustomerOrder)` at `PickingorderBusinessService:817`, inside `confirmPick` — SBDEV-3319's **G1**, "the mandatory, unbypassable stop". `processPick` calls `confirmPick` at the end, so the window mint-then-reject is real. That is deliberate on SBDEV-3319's part (a position can be cancelled between G2 and G1); it is not a flaw in either change.

What happens in that window:

| write | propagation | survives rollback? |
|---|---|---|
| Cart `unitload` row (`unitloadRepository.save`) | caller's tenant tx | **no** — rolls back |
| `unitload_record` CREATED row | `UnitloadRecordService` declares **no `@Transactional` at all** — no class-level, no method-level — so it joins the caller's tx | **no** — rolls back |
| tote's `carrierunitload_id` write | caller's tenant tx | **no** — rolls back |
| `los_sequencenumber` increment | `BasicService.generateNumber` → `getNextSequenceNumber` → `SequenceTransactionService:23`: `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` | **YES — commits independently** |

**So no orphan Cart can survive a rollback, and no orphan audit row either.** The only residue is a burned `UNIT_LOAD` sequence number — a gap in the `UL-…` series.

**This is not a new class of leak, and I would not spend code on it.** The *tote* is minted ten lines earlier in the same block through the same `createUnitload` → `generateNumber` path, so a rejected pick already burned one `UNIT_LOAD` number before this ticket. The cart mint makes it two. Same for the retry path: `PickingController`'s `PessimisticLockingFailureException` catch re-enters `processPick`, which re-scans `findByStoragelocationId`, correctly finds nothing (the previous attempt rolled back) and mints afresh — one more burn per attempt, bounded by the retry count.

Two corollaries worth recording on the ticket rather than fixing:

- **Your D7′ "never retired" reasoning is untouched by this.** It is a statement about the happy path; a rolled-back mint leaves no row to retire.
- **Burned numbers are a forensic asset here, not just noise.** A gap in the `UL-…` series is evidence that `processPick` reached the tote-assignment block and then rolled back — which is exactly the signal you would want if H-1's throw ever fires in production.

### 7.3 `getPickingOrderSummaries` — **no interaction.**

It is called from exactly one place in `src/main`: `MobilePickingService:685`, inside `getPickingOrders`, which SBDEV-3320 does not touch. `git diff 4c2ae57b...a220be2a` contains no reference to it. The added `State.CANCELED` argument is consumed entirely inside SBDEV-3319's own JPQL. Nothing in this change reads picking-order summaries.

### 7.4 H-1's premise re-checked against SBDEV-3319

SBDEV-3319 added 35 lines to `WmsConstants` but **none to `SectionPickingType`**, which still declares exactly `TOTES_ON_CART` and `RAPID_PICKING`. H-1 stands unchanged, and the rebased integration lane confirms it empirically (§1).

### 7.5 One thing to know about the merged test file (informational, not a finding)

SBDEV-3320 added five `lenient()` stubs to `MobilePickingServiceUnitTest`'s **outer** `@BeforeEach` (`sectionRepository.findById(1L)`, `unitloadTypeRepository.findByName(CART)`, `findByStoragelocationId(anyLong())`, `createUnitload(…, eq(6L), …)`, `clientService.getSystemClient()`). SBDEV-3319's new `@Nested` class inherits all of them, and because the shared `testSection` is `TOTES_ON_CART`, **any SBDEV-3319 test that reaches the tote-assignment block now also mints a cart.** It merges cleanly and the suite is green (6513/0), so this is not a defect — but the two tickets' unit tests are no longer independent, which is worth remembering the next time one of them goes red for a reason that looks unrelated.
