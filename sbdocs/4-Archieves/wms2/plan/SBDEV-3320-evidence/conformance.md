# SBDEV-3320 — Conformance verification

**Lane:** `cart-verifier` (independent). **Date:** 2026-09-11.
**Subject:** `feature/SBDEV-3320-cart-unitload-mint` @ `1d722693`, one commit off `origin/develop` @ `6dc054e1`
(`git merge-base HEAD origin/develop` = `6dc054e152d7a0cb4906daf91589bca98587d3c0` — confirmed, no drift).

**Where I ran things.** The harness provisioned me `.claude/worktrees/wms2-api/SBDEV-3320-review`
(detached at `1d722693`) for reads. The full suite ran in
`.claude/worktrees/wms2-api/SBDEV-3320`; a third maven was live in `-review` at the time (another
lane), but the two are different worktrees, so no shared-`target/` false reds. Mutation runs used a
throwaway worktree under my scratchpad (`git worktree add --detach`), removed afterwards — the
implementation worktree was left byte-identical and clean (`git status --porcelain` empty, HEAD still
`1d722693`). No `git checkout --` / `restore` / `stash` was used anywhere.

**Every command below was re-run by me. Nothing is quoted from the implementer.**

---

## Overall verdict: **PASS**

Ten of ten gradeable decisions VERIFIED (D11 verified as correctly *absent*). Full suite green.
Compile green. No stray files. Two documentation-level nits and one claim-accuracy correction are
recorded at the end; none of them affects the verdict.

---

## Per-decision verdicts

### D1 — narrow `transferUnitLoadToCart` entry point · **VERIFIED**

| Sub-claim | Evidence |
|---|---|
| `transferUnitLoadToCart(Unitload, Unitload, String, String, String)` exists | `UnitloadBusinessService.java:312`, `@Transactional(value = "tenantTransactionManager", …)` |
| Old body is now a private shared core taking `boolean allowNestingExemption` | `UnitloadBusinessService.java:344` `private void transferUnitLoadToCarrierCore(…, boolean allowNestingExemption)` |
| `transferUnitLoadToCarrier` keeps its **exact** original signature | Byte-identical between `origin/develop` and HEAD, and still on the same line number (284) in both. Verified by diffing the two `grep -n "public void transferUnitLoadToCarrier"` outputs, not by eye. |
| …and passes `false` | `:285` → `transferUnitLoadToCarrierCore(…, false)` |
| New entry asserts **source is Tote AND destination is Cart** before delegating with `true` | `:314-331` — two independent type lookups, each `BusinessException` on mismatch ("accepts only a Tote as source" / "accepts only a Cart as destination"), then `:333` delegates with `true` |
| Cycle guards / parent detach / location propagation / `unitload_record` audit are **inherited, not duplicated** | The diff adds **zero** lines below the delegation — the only edit inside the old body is the one-line gate at `:409`. Confirmed structurally: `git show` on this file produces exactly two hunks, `@@ -282,6 +282,66 @@` (the new method) and `@@ -346,7 +406,11 @@` (the gate). Nothing else in the core moved. |

The exemption reaches exactly one site: `if (!allowNestingExemption && sourceType != null && !sourceType.getOnotherunitloadallowed())` (`:409`).

**Mutation-checked.** Flipped the delegation flag `true` → `false`. Result: `Tests run: 48,
Failures: 1` — the single kill is
`UnitloadBusinessServiceUnitTest$TransferUnitLoadToCart.transferUnitLoadToCart_shouldAttachTote_despiteToteNotAllowedOnOtherUnitLoad`.
The sibling `$TransferUnitLoadToCarrier` nested class (5 tests) stayed **green**, which is the
surviving control proving the public method's gate is genuinely untouched rather than globally
disabled.

### D2 — mint in `processPick`, never in `rapidPickingConnectPackageAndType` · **VERIFIED**

- The mint call sits at `MobilePickingService.java:541`, inside `processPick` (declared `:442`).
  `awk` over lines 442-560 finds **no other method declaration**, so 541 is unambiguously inside
  `processPick` — not in an intervening helper.
- `rapidPickingConnectPackageAndType` is declared at `:1123`. The two hunks in this file are
  `@@ -535,6 +535,12 @@` and `@@ -1474,4 +1480,105 @@` (the latter appends the three new private
  helpers at the end of the class). Old line 1123 lies between them, so the method is **literally
  unmodified**.
- `CODE_ASSIGN_TOTE` appears at exactly two call sites in `src/main` (`:536` location transfer,
  `:1497` cart attach) — there is no second tote-assignment path that was missed.

### D3 — gate on `pickingOrder.getSectionId()` → `Section.getSectionpickingtype() == TOTES_ON_CART` · **VERIFIED**

`isCartPickingSection` (`MobilePickingService.java:1521-1545`):

- hop 1 null-guarded: `sectionId == null` → `LOG.warn` + `return false`;
- hop 2 null-guarded: `pickingType == null` → `LOG.warn` + `return false`;
- `TOTES_ON_CART` → `true`; `RAPID_PICKING` → `false`;
- `default:` → `LOG.error` + `throw new BusinessException("unknown pickingType=" + pickingType)` —
  it **throws**, it does not silently skip.

`WmsConstants.SectionPickingType` (`service/WmsConstants.java:602-609`) declares exactly those two
constants, so the `default` arm is reachable only from a DB value outside the enum.

**Mutation-checked.** Changed the `TOTES_ON_CART` arm to `return false` (the "feature silently off"
mutant). Result: `Tests run: 112, Failures: 4` — D3's own gate, D5, D6' and D8 all went red, while
the D2 `RAPID_PICKING` pin correctly **survived** (its assertion — no mint — is still true under the
mutant). That is the right kill/survive split, and it proves the four processPick assertions are
load-bearing rather than vacuously green.

### D5 — attach **after** `transferUnitLoadToLocation` · **VERIFIED (both halves)** — highest-risk item

**Half 1 — the source order is right.** `MobilePickingService.java:536` is the location transfer;
`:541` is `attachToteToPickerCart(...)`. Straight-line code in the same block, attach second.

**Half 2 — the premise is real, independently confirmed.** I did not take the comment's word for it.
`grep -n "setCarrierunitloadId"` in `UnitloadBusinessService` returns two sites: `:268`
(`setCarrierunitloadId(null)` followed by a `save`) and `:425` (the carrier write in the core).
Line 268 falls inside `transferUnitLoadToLocation` (declared `:159`, next method `:284`), so that
method really does null the carrier link and persist it. An attach placed first would be silently
undone.

*Nit:* the code comment and commit message both say "clears `carrierunitload_id` **at its head**".
It is cleared at `:268`, near the *end* of a ~125-line method, not at its head. The ordering
requirement is unaffected — only the prose is imprecise.

**Half 3 — a test actually pins it, and it is an InOrder verify.**
`processPick_shouldAttachCartAfterLocationTransfer_becauseLocationTransferClearsTheCarrier`
(MobilePickingServiceUnitTest:~3223) uses `Mockito.inOrder(unitloadBusinessService)` and verifies
`transferUnitLoadToLocation` then `transferUnitLoadToCart`. It is **not** an end-state assertion.

**Mutation-checked — this is the single most important measurement on the ticket.** I moved the
`attachToteToPickerCart(...)` call to *before* the `transferUnitLoadToLocation(...)` call and
re-ran `MobilePickingServiceUnitTest`:

```
[ERROR] Tests run: 112, Failures: 1, Errors: 0, Skipped: 0
[ERROR]   MobilePickingServiceUnitTest$ProcessPickCartMinting
            .processPick_shouldAttachCartAfterLocationTransfer_becauseLocationTransferClearsTheCarrier:3223
org.mockito.exceptions.verification.VerificationInOrderFailure: Wanted but not invoked:
unitloadBusinessService.transferUnitLoadToCart(...)
```

Exactly one kill, and it is the D5 test. Every other test in the class — including the three
end-state-shaped cart assertions — stayed green under the reordering, which is precisely the
blindness the lead warned about and confirms the InOrder verify is the only thing standing between
this ticket and a silent no-op.

### D6′ — reuse the Cart at the picker's location; mint only if absent · **VERIFIED**

`findOrMintPickerCart` (`MobilePickingService.java:1565-1585`):

| Sub-claim | Evidence |
|---|---|
| reuse via `findByStoragelocationId` filtered to type Cart | `:1571-1576` — loops `unitloadRepository.findByStoragelocationId(userLocation.getId())` and returns the first whose `typeId` equals the Cart type id. Repository method exists: `UnitloadRepository.java:47`. |
| mint only if absent | The `createUnitload` call at `:1584` is after the loop, reached only on no match. |
| label from the sequence machinery, never the picking order number | `createUnitload(userLocation, cartType.getId(), client.getId(), WmsConstants.CODE_PICKING)` resolves to the 4-arg overload `UnitloadService.java:186` → `:190`, whose first statement is `basicService.generateNumber(WmsConstants.EntityPrefixes.UNITLOAD, "UNIT_LOAD")`. **Traced through both hops myself.** The picking order number is not in scope in this helper — `findOrMintPickerCart` takes only a `Location`, so it structurally *cannot* derive a label from it. |
| SYSTEM client | `:1583` `Client client = clientService.getSystemClient();` — not `getCallersClient()` (which is what the *tote* path 50 lines up uses, so the distinction is deliberate, not a copy-paste). |

Pinned behaviourally by `processPick_shouldReuseExistingCart_whenOneIsAlreadyAtThePickerLocation`,
which asserts `verify(unitloadService, never()).createUnitload(any(), eq(6L), any(), any())` plus a
positive `transferUnitLoadToCart(any(), eq(existingCart), …)`. The `never()` matchers are bare
`any()` in every reference position — correct per the SBDEV-3136 null-blindness rule, and the test's
own comment shows the declared signature was checked rather than the matcher name.

### D7′ — no release step; nothing routes a Cart through `relocateEmptiedContainer` · **VERIFIED**

- `relocateEmptiedContainer` is declared at `UnitloadBusinessService.java:543` (old line 483). The
  file's last hunk ends at old line ~356, so the method — **including its
  `case UNIT_LOAD_TYPE_CART: → STORAGE_LOCATION_EMPTY_PALLETS` branch at `:559-561`** — is
  untouched. Verified by hunk range, not by reading the diff for absence.
- Its three `src/main` callers are `StockunitBusinessService:358`, `:378`,
  `PickingorderBusinessService:606` and `BillofladingService:896`. None is reachable from the new
  code: the cart is never emptied, never retired, and never passed to any of them. The new code
  contains no call to `relocateEmptiedContainer`, `sendToNirvana`, or any retire path — the only
  outbound calls are `transferUnitLoadToCart` and `createUnitload`.

### D9 — `setLockOnHold` refuses only a **non-Cart** carrier · **VERIFIED**

`StockunitService.java:457-471`. The guard became
`if (carrierOpt.map(carrier -> !isCartCarrier(carrier)).orElse(false))`. Behaviour table:

| carrier row | pre-fix | post-fix |
|---|---|---|
| absent (`Optional.empty`) | no throw | no throw — unchanged |
| present, Pallet/other | throw | throw — unchanged |
| present, Cart | throw | **no throw** — the intended narrowing |

`isCartCarrier` (`:851-856`) null-guards `getTypeId()` and uses `.map(...).orElse(false)`, so a
missing `unitload_type` row degrades to "not a Cart" (i.e. still refused) rather than NPE-ing.

**Non-Cart carrier is still refused — confirmed two ways.** (a) The pre-existing sibling
`StockunitServiceUnitTest$SetLockOnHoldExtended.throwsWhenUnitloadIsOnCarrier` ran and **passed** in
my full-suite run (grepped out of the surefire XML by method name, not from a per-class `.txt`).
(b) **Mutation-checked**: I reverted the guard to the pre-fix behaviour
(`carrierOpt.map(carrier -> true)`) and got `Tests run: 82, Failures: 1` — the sole kill was
`setLockOnHold_shouldNotRefuse_whenCarrierIsCart`, while `$SetLockOnHold` (2 tests) and the non-Cart
sibling stayed green.

*Bonus, correctly handled:* the pre-fix code used `isPresent()` + implicit `get()`; the rewrite uses
`.map(...)`, which keeps `OptionalSafetyArchTest` satisfied without adding a frozen violation.

### D10 — `TransferOrderService` stops the carrier ascent at a Cart · **VERIFIED**

`TransferOrderService.java:364-381`. Inside the ascent loop, after `carrierOpt.isPresent()`:
`Unitload carrier = carrierOpt.orElseThrow(); if (isCartCarrier(carrier)) { break; } unitLoad = carrier;`.
A non-Cart carrier still re-roots (`unitLoad = carrier` plus the `carrierCache.put`), so the walk is
unchanged for Pallets.

**A control test exists and is real.**
`TransferOrderServiceUnitTest$TransferLineCarrierAscent` holds a matched pair built from one shared
`arrangeToteCarriedBy(carrier, typeName, typeId)` fixture — `getTransferLineUnitLoads_shouldNotReRootOntoCart`
(expects `T-0004`) and `getTransferLineUnitLoads_shouldStillAscendThroughANonCartCarrier`
(expects `P-0001`). Same fixture, opposite expectations: the control cannot pass if the traversal
were simply broken.

**Mutation-checked.** Neutralised the break (`if (false) { break; }`). Result:
`Tests run: 54, Failures: 1` — only `shouldNotReRootOntoCart` died; the Pallet control survived.

### D11 — re-read hardening in `transferUnitLoadToLocation` · **VERIFIED ABSENT (correct)**

`transferUnitLoadToLocation` spans `UnitloadBusinessService.java:159-283`. This file's two hunks
start at old line 282 (the insertion point *after* the method) and old line 346. **No line of
`transferUnitLoadToLocation` is in the diff.** I checked this by hunk range rather than by grepping
for the hardening's symbols, because a rename would defeat a symbol grep. D11 is absent, as
required. No finding.

---

## Independent checks requested

### 1 — Nine new tests exist and are real · **VERIFIED, with a count correction**

`git show HEAD -- 'src/test/java/*' | grep -c '^+.*@Test'` = **15 added, 0 removed, 0 `@Disabled`
added.** Distribution:

| Class | added `@Test` |
|---|---|
| `MobilePickingServiceUnitTest$ProcessPickCartMinting` (new nested class) | 5 |
| `UnitloadBusinessServiceUnitTest$TransferUnitLoadToCart` (new nested class) | 4 |
| `UnitloadBusinessServiceCartContractUnitTest` (new file) | 3 |
| `TransferOrderServiceUnitTest$TransferLineCarrierAscent` (new nested class) | 2 |
| `StockunitServiceUnitTest$SetLockOnHoldExtended` (existing class, +1) | 1 |

**The lead's per-class breakdown is slightly off but the arithmetic reconciles.** All five tests in
`ProcessPickCartMinting` are added by *this commit* (there is only one commit off develop), so
"2 pre-existing there" is not true relative to `origin/develop`. What is true is that 6 of the 15
were written at the TDD-gate stage and were already present when the 6479 baseline was captured:
6479 + 9 = 6488 exactly, and "3 gate reds" matches the three gate assertions among those 6
(the D1 contract gate, the D3 mint gate, the D9 hold gate — the other three are pins that passed).
**Relative to `origin/develop` the suite grows by 15, so develop's own total is 6473, not 6479.**
That is a bookkeeping correction, not a defect.

**All 15 ran and passed — confirmed from the surefire XML by method name**
(`grep -rl '<methodName>' target/surefire-reports/`, per the `@Nested`/`Tests run: 0` trap), never
from a per-class `.txt`. 15/15 PASS, plus the D9 non-Cart sibling control `throwsWhenUnitloadIsOnCarrier`
PASS.

**Are they real?** Beyond running, I killed a mutant for each of D1, D3, D5, D9 and D10 (details in
each section above). Seven distinct test methods were killed across the five mutants, each mutant
attributable to its own assertion, with a surviving control on the D1, D2, D9 and D10 pairs. The
tests are load-bearing, not decorative.

### 2 — Full suite 6488 / 0 / 0 / 1 skipped · **VERIFIED**

```
$ export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
$ cd .claude/worktrees/wms2-api/SBDEV-3320 && mvn -o clean test
[WARNING] Tests run: 6488, Failures: 0, Errors: 0, Skipped: 1
[INFO] BUILD SUCCESS
[INFO] Total time:  03:40 min
```

**Failures compared, not totals:** 0 failures / 0 errors against a claimed baseline of 3 (the
intentional gate reds). The three gate reds are gone and nothing new is red — that is the comparison
that matters, and it passes.

The 1 skipped is `net.aim_ai.wms.landlord.config.TenantPoolEndpointSecurityTest` (2 tests, 1
skipped). That class is not in the diff and is unrelated to this ticket — pre-existing.

**One thing I could not verify independently:** I did not capture a fresh `origin/develop` baseline
myself — doing so needs a sixth Maven run in yet another worktree and the failure-count comparison
above already discharges the question. There is **no baseline log in the evidence directory**
(`SBDEV-3320-evidence/` holds only `architect-consult.md` and `db-evidence.md`), so the "6479 / 3
failures" figure rests on the implementer's word. I am reporting my own run's absolute result
instead: **0 failures, 0 errors**, which is unconditionally the required state regardless of what
the baseline was.

### 3 — `mvn -o clean compile` succeeds · **VERIFIED**

Run as its own goal, before and separate from the test run, precisely because the D1 change alters
method visibility and Spring proxying:

```
[INFO] BUILD SUCCESS
[INFO] Total time:  8.776 s
COMPILE_EXIT=0
```

### 4 — No stray files · **VERIFIED**

The commit touches exactly 10 files: 4 `src/main`, 5 `src/test`, 1 archunit store entry. No `.env`,
no `migration.env`, no IDE files, no `.DS_Store` — checked by pattern
(`grep -Ei '\.env|\.idea|\.iml|migration\.env|\.vscode|\.DS_Store'` → no match), not by eye.
Working tree is clean (`git status --porcelain` empty) with no untracked leftovers.

**archunit store:** exactly one file changed
(`src/test/resources/archunit_store/5fb3fee0-6caf-4f48-a5cd-5271da610572`), `1 file changed,
1 deletion(-)` — **a removal, and the only store change.** The removed line is:

```
-Method <net.aim_ai.wms.service.TransferOrderService.getTransferLineUnitLoads(
   net.aim_ai.wms.model.Customerorder, boolean, java.lang.String)>
   calls method <java.util.Optional.get()> in (TransferOrderService.java:367)
```

That is the `carrierOpt.get()` at the D10 edit site, genuinely replaced by `orElseThrow()`. No
additions to the store anywhere — so the change is a shrink, not a freeze of a new violation.

---

## Findings (none blocking)

1. **Low — imprecise prose, two copies.** "clears `carrierunitload_id` **at its head**" appears in
   both the `MobilePickingService.java:538` comment and the commit message. It is cleared at
   `UnitloadBusinessService.java:268`, near the method's *end*. The ordering constraint is real and
   correctly implemented; only the location is wrong. Worth fixing in the comment so a future reader
   who greps the head of `transferUnitLoadToLocation`, finds nothing, and concludes the constraint
   was imaginary does not then reorder the calls.
2. **Low — orphaned javadoc.** `MobilePickingServiceUnitTest` has two consecutive `/** … */` blocks
   before the D5 test (~:3196): a "D2 PIN — passes today; it is a regression pin, NOT a gate"
   block immediately followed by the D5 block. Java attaches only the second, so the D2 PIN
   paragraph is a floating comment sitting above the wrong test — the D2 pin it describes is 60
   lines further down. Cosmetic; move or delete it.
3. **Informational — conditional assertions in two tests.**
   `transferUnitLoadToCart_shouldAttachTote_…` and `setLockOnHold_shouldNotRefuse_whenCarrierIsCart`
   both wrap their message assertion in `if (thrown != null && thrown.getMessage() != null)`, which
   is the shape that can go vacuously green. **I mutation-checked both rather than reasoning about
   them** — each killed its mutant (D1 and D9 above), so they do have teeth today. The first is
   additionally backed by an unconditional `ArgumentCaptor` assertion. No action required; noted
   because the shape is fragile to future edits.
4. **Informational — D3's `default:` arm is a live behaviour change, and it conforms.** A section
   whose `sectionpickingtype` is neither `TOTES_ON_CART` nor `RAPID_PICKING` now throws out of
   `processPick`, breaking picking for that section where it previously worked. That is exactly what
   D3 specifies ("an unrecognised picking type throws rather than silently skipping"), so it is
   conformant — but it is the one blast-radius item in this commit that a DB check would settle.
   I did not run that query (no DB tooling in this lane); if `lane-db` has not already confirmed
   that every `section.sectionpickingtype` on Hydra PRD and WineCo UAT is one of the two constants,
   that check is worth having before merge. Null and empty-string are already safe (hop-2 guard
   returns false) — the exposure is a third non-empty value only.
