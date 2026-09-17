# SBDEV-3320 — code review, pass 2 (fix delta only)

- **Scope**: `git diff a220be2a 8140a568` — 10 files, +434/−50. Everything up to `a220be2a` is settled by
  `code-review.md` and is **not** re-litigated here.
- **Subject**: `8140a568` "SBDEV-3320: mint a Cart unit load and hang picking totes off it", branch
  `feature/SBDEV-3320-cart-unitload-mint`, PR #350 open.
- **Reviewed in**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3320-review2`
  (detached at `8140a568`). Mutants ran in a second, disposable worktree `SBDEV-3320-mut`, since removed.
  No `git checkout --` / `git restore` / `git stash` anywhere; every mutant was applied with `perl -pi`
  and restored from a `/tmp` copy. `git status --short` verified empty in both worktrees before teardown.
- **Verdict**: **the three fail-open changes are correct, the M-4 hoist is clean and coverage went UP
  rather than down, and the IT's cart-count assertion is genuinely load-bearing — all measured, not
  reasoned.** The build claim is confirmed exactly. **0 High, 2 Medium, 6 Low.** Nothing here blocks the
  PR on correctness; M2-1 is a real coverage hole on a live picking path and M2-2 is a stale claim of
  exactly the kind this repo keeps getting bitten by.

---

## 1. Instruments

### Full build — independently re-run, claim confirmed

```
cd .claude/worktrees/wms2-api/SBDEV-3320-review2
export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
mvn -o clean verify
```

| Lane | Measured | Claimed | |
|---|---|---|---|
| surefire | `Tests run: 6522, Failures: 0, Errors: 0, Skipped: 1` | 6522/0 | ✅ |
| failsafe | `Tests run: 395, Failures: 0, Errors: 0, Skipped: 31` | 395/0 | ✅ |
| build | `BUILD SUCCESS`, 08:02 min | — | ✅ |

**FAILURES compared, not totals** (per `CLAUDE.md`): zero failures and zero errors in both lanes, against
review pass 1's measured baseline of surefire 6513/0 and failsafe **395/0/Errors: 1**. The single failsafe
error from H-1 is gone and nothing took its place. Java 21.0.11, Maven 3.9.15.

### Mutation results

Six mutants, each applied alone, each restored by file copy before the next.

| # | Mutant | Lane run | Result |
|---|---|---|---|
| **MUT-A** | `findOrMintPickerCart`: `if (cartType == null) {` → `if (false) {` | `MobilePickingServiceUnitTest` | **KILLED** — `…whenTenantHasNoCartType:3554 » NullPointer Cannot invoke "UnitloadType.getId()" because "cartType" is null` |
| **MUT-B** | `findOrMintPickerCart`: `if (client == null) {` → `if (false) {` | `MobilePickingServiceUnitTest` → **118/0 BUILD SUCCESS**; escalated to `MobilePickingServiceIntegrationTest` → **3/0 BUILD SUCCESS** | **SURVIVED** — see **M2-1** |
| **MUT-C** | `if (cartType.getId().equals(candidate.getTypeId()))` → `if (true)` | `MobilePickingServiceUnitTest` | **KILLED twice** — `…shouldSelectTheCart_whenNonCartUnitLoadsShareThePickerLocation:3464` and `…shouldMintCart_whenOnlyNonCartUnitLoadsAreAtThePickerLocation:3497`. **M-1 is genuinely dead.** |
| **MUT-F** | `StockunitService`: `carrierOpt.map(carrier -> !unitloadService.isCartCarrier(carrier))` → `map(carrier -> false)` | `StockunitServiceUnitTest` | **KILLED twice** — `SetLockOnHoldExtended.throwsWhenUnitloadIsOnCarrier:957` **and** `setLockOnHold_shouldNotRefuse_whenCarrierIsCart » UnnecessaryStubbing` |
| **MUT-G** | `TransferOrderService`: `if (unitloadService.isCartCarrier(carrier))` → `if (false)` | `TransferOrderServiceUnitTest` | **KILLED** — `TransferLineCarrierAscent.getTransferLineUnitLoads_shouldNotReRootOntoCart:1584` |
| **MUT-H** | `attachToteToPickerCart`: `if (true) { return; }` inserted before the mint | `MobilePickingServiceIntegrationTest` | **KILLED** — `mobilePickingService_Tote_Test:716 … Expected size: 1 but was: 0` |

MUT-B was escalated because a targeted-class survival is not a survival. I enumerated every class that
can reach the line — `grep -rln "processPick(" src/test/java` returns exactly three:
`MobilePickingServiceUnitTest` (survived), `MobilePickingServiceIntegrationTest` (survived),
`PickingControllerUnitTest` (mocks `MobilePickingService` outright, cannot reach it). The survival is
complete, not partial.

MUT-F is the interesting kill: it dies **twice**, and the second detector is new. Making the D9 stub
strict (`when(...)` rather than `lenient().when(...)`) means a mutant that never reaches the guard now
trips `UnnecessaryStubbing`. The L-1 remedy bought a second, independent detector on top of the
assertion it was aimed at.

---

## 2. The questions you asked me to attack

### 2.1 Is the `default:`-arm fail-open reasoning actually right? — **Yes, and it is stronger than you argued.**

Your argument was that `SectionService.create` and `CustomerorderService.processPackaging` *select an
action* and have no safe default, whereas this answers a yes/no question that does. I checked both
precedents rather than taking them on trust, and both hold:

- `CustomerorderService.processPackaging:635-646` — `TOTES_ON_CART` → `transferUnitLoadToLocation(…
  EmptyTotes …)`, `RAPID_PICKING` → `sendToNirvana(…)`. Two mutually exclusive dispositions of a
  physical tote; doing neither strands it. No safe default. ✅
- `SectionService.create:66-77` — `RAPID_PICKING` additionally calls
  `losStorageLocationService.createLocation(…)`. Also action-selecting. ✅ And it is a **write-boundary**
  check, which is the stronger form of the same point: strictness belongs where the value enters the
  system, leniency where it is read back. Your change puts each on the correct side.

Two things I can add that the comment does not claim, both of which make the fail-open safer than
"probably fine":

- **The fail-open degrades to exactly the pre-ticket behaviour, not to a novel state.** I traced every
  consumer of the new carrier link and none of them requires it: `StockunitService.setLockOnHold`'s D9
  narrowing and `TransferOrderService`'s D10 break are both *conditional relaxations* that are no-ops
  when `carrierunitloadId` is null, and `processPackaging`'s TOTES_ON_CART arm routes through
  `transferUnitLoadToLocation`, which clears the carrier at `UnitloadBusinessService:268` — a no-op on a
  tote that never had one. A cartless tenant sits in a **supported** state.
- **Therefore the two costs are not comparable.** Fail-open costs "an optional feature silently does not
  work". Throw costs "every operator in that section gets a 500 on every pick". Escalating a degradation
  into an outage to buy yourself a notification is the wrong trade, and it is the trade you already
  rejected once on H-1.

**On your specific worry — the tenant misconfigured mid-rollout who never finds out — you are right to
raise it, but the three branches are not equally exposed and the answer is not "throw".** The
`default:` arm needs a *third free-text value*, which you measured as absent on every live DB. The other
two (`findOrMintPickerCart`'s missing Cart type and missing system client) are **tenant-provisioning**
failures: present from that tenant's first boot, silent forever, and hitting every pick. That is the
realistic version of your scenario, and the fix for it is the detection channel, not the throw — see
**L2-5**, which is where I think this concern actually lands.

### 2.2 Null-return contract at every call site — **honoured; no NPE reachable.**

`findOrMintPickerCart` has exactly one caller (`grep -rn "findOrMintPickerCart" src/main/java` →
declaration + one call at `MobilePickingService:1509`). The guard is immediate:

```java
Unitload cart = findOrMintPickerCart(userLocation);
if (cart == null) {
    return;   // tenant has no Cart type — already logged; picking proceeds without a cart
}
unitloadBusinessService.transferUnitLoadToCart(tote, cart, …);
LOG.debug("… cart={} …", tote.getLabelid(), cart.getLabelid(), …);
```

Both dereferences (`transferUnitLoadToCart`'s argument, `cart.getLabelid()`) sit after the guard.
Nothing follows the early `return` that needed to run. **No NPE is reachable.**

Null-rather-than-`Optional` is fine here: private method, single caller, and `orElse(null)` + an explicit
check is what `OptionalSafetyArchTest` pushes you toward anyway. Not a finding. The comment on that line
*is* a finding — see **L2-1**.

I also confirmed the third guard is real rather than defensive noise: `ClientService.getSystemClient():101-109`
genuinely returns `null` (it catches `NoSuchElementException` from `clientOptional.get()`), so the check
is against documented behaviour, not a hypothetical.

### 2.3 Is `LOG.error` a log-flood risk? — **Yes, and it is the weak link in the whole fail-open story.** See **L2-5**.

### 2.4 M-4 — right home, no cycle, injection not newly load-bearing, coverage went UP

- **No cycle.** `UnitloadService`'s 24 constructor dependencies contain neither `StockunitService` nor
  `TransferOrderService` (it takes `StockunitRepository` and `StockunitBusinessService`, not the service).
  The new edges are `StockunitService → UnitloadService` and `TransferOrderService → UnitloadService`,
  both one-directional.
- **The injection is not newly load-bearing.** Both callers already held `UnitloadService` *and already
  called it*: `StockunitService:260`, `:335`, `:543`; `TransferOrderService:502`. Neither constructor
  changed in this delta. Context loading cannot newly break, and the full `verify` — which boots the real
  Spring context in the failsafe lane — passed.
- **No field went dead in production code.** `TransferOrderService.unitloadTypeRepository` survives at
  `:498`; `StockunitService.unitloadTypeRepository` at `:242/:249/:329/:332/:539`. (One *test* stub did go
  dead — **L2-2**.)
- **Coverage did not vanish; it grew.** MUT-F and MUT-G both still die (above), so the callers' pins are
  intact. And the predicate itself went from *zero* direct tests — it was private in two places, only ever
  exercised transitively through one true-path stub each — to four, including two negatives no test
  covered before: an unresolvable `unitload_type` row, and a null unit load. `UnitloadService` is the
  right home: it already owns `createUnitload`, `assertCarrierChainIsAcyclic` and the three delete walks,
  i.e. it is already the class that knows what a carrier is.
- One behaviour **widened**: `isCartCarrier(null)` returns `false` where both private originals would
  have thrown NPE. That is the right direction and it is tested. The javadoc does not mention it — **L2-6**.

### 2.5 Could the IT's cart-count assertion pass for a wrong reason? — **No. Measured.**

You asked specifically about leftovers from sibling test methods. I did not settle this by reading
`@Transactional`; I broke the mint and looked at the number:

```
MUT-H: attachToteToPickerCart → `if (true) { return; }` before the mint
→ mobilePickingService_Tote_Test:716
   Expected size: 1 but was: 0
```

**"but was: 0"** is the answer. With the mint suppressed, `unitloadRepository.findAll()` filtered to the
Cart type yields an empty list — so there is no residue from `mobileRapidPickingService_Rapid_Test` or
`…_RapidPass_Test` propping the count up, and the `hasSize(1)` is carried entirely by this test's own
mint. Three independent reasons back that up: `BaseIntegrationTest` is `@Transactional("tenantTransactionManager")`
(SBDEV-3242 landed the qualifier, so rollback actually binds the tenant EM); the two rapid tests use a
different section (`SBDEV3240-Zone-Rapid`); and `attachToteToPickerCart` is called from exactly one place,
`MobilePickingService:554` inside `processPick`, which the rapid path never enters.

**Your reasoning about *what* is asserted is also right.** `transferUnitLoadToLocation` nulls the carrier
at `UnitloadBusinessService:268`, and `finalizePicking` routes the tote through it, so asserting a
non-null `carrierunitload_id` after a completed pick would assert the bug. Declining to assert it is
correct.

But the assertion you *did* write proves less than the fixture comment claims it does, and the gap is
closable — see **L2-3**.

### 2.6 L-1 / L-2 fixes — both good

- **L-1**: `satisfiesAnyOf(t -> assertThat(t).isNull(), t -> assertThat(t).hasMessageNotContaining(…))`
  closes the hole properly. A throwable with a **null message** now fails *both* arms (AssertJ's
  `hasMessageNotContaining` fails on a null message rather than passing vacuously), which was the exact
  mutant the old `if (thrown != null && thrown.getMessage() != null)` waved through.
- **L-2**: nothing was lost. The deleted D8 test's only assertion was
  `verify(unitloadBusinessService).transferUnitLoadToCart(any, any, eq(CODE_ASSIGN_TOTE), any, any)`, and
  `eq(WmsConstants.CODE_ASSIGN_TOTE)` is still asserted at four sites in that class (`:3378`, `:3381`,
  `:3422`, `:3465`). The M-1 test that took its slot is **strictly stronger** — it pins `eq(existingCart)`
  as the second argument, which the deleted test never did.

### 2.7 M-3 fix — correct, and provably behaviour-neutral

`carrierCache.put(carrier.getId(), carrier)` uses the right key: at the break, `unitLoad` is the tote and
`carrier` is the cart, so `unitLoad.getCarrierunitloadId() == carrier.getId()`, which is what the DTO
phase looks up at `TransferOrderService:456`. Both the cache hit and the pre-existing
`unitloadRepository.findById` fallback produce the same `carrier.getLabelid()`, so **the DTO output is
byte-identical** — this is purely the removed double-fetch. No collision risk: the cart is never itself an
element of `resultList` (it has no carrier of its own, so the `while` never runs on it), and nothing
iterates `carrierCache.values()` — the only reads are `put` at `:364/:384/:388` and `get` at `:456`.

---

## 3. Findings

Ranked. Every severity gets fixed per the standing instruction.

### MEDIUM

**M2-1 — the null-system-client fail-open is an untested guard on a live picking path; the mutant survives both lanes.**
`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

```java
Client client = clientService.getSystemClient();
if (client == null) {
    LOG.error("findOrMintPickerCart: no system client (cl_nr={}) in this tenant — not attaching a cart. "
        + "Picking continues.", WmsConstants.SYSTEM_CLIENT_NUMBER);
    return null;
}
```

Measured, replacing that condition with `if (false)`:

```
mvn -o test -Dtest=MobilePickingServiceUnitTest
→ Tests run: 118, Failures: 0, Errors: 0 — BUILD SUCCESS

mvn -o verify -Dit.test=MobilePickingServiceIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
→ Tests run: 3, Failures: 0, Errors: 0 — BUILD SUCCESS
```

This is the survival you asked me to check for, and by your own stated bar it is a Medium. The cause is
visible in the fixtures: `MobilePickingServiceUnitTest:237` stubs
`lenient().when(clientService.getSystemClient()).thenReturn(testClient)` in the **outer** `@BeforeEach`
and no test overrides it, while the IT's `@BeforeEach` now deliberately seeds the system client. Nowhere
in `src/test` does a picking test drive `getSystemClient()` to null — the only two classes that stub it
null are `PutawayDestinationResolverUnitTest:258` and `PrintServiceUnitTest:315`.

Its two siblings are covered, which is what makes the gap conspicuous rather than systematic: MUT-A
(missing Cart type) and MUT-D (the `default:` arm, which you checked) both die. This one branch was
written and never pinned.

Note the failure mode if it regresses is **not** a silent no-cart — it is `NullPointerException` at
`client.getId()`, inside `processPick`, i.e. the picking outage the whole fail-open design exists to
prevent. That is what MUT-A produced verbatim on its branch.

*Remedy: **code***. One test alongside `processPick_shouldNotThrowAndNotAttach_whenTenantHasNoCartType`:

```java
when(clientService.getSystemClient()).thenReturn(null);   // overrides the outer lenient stub
Pickingorder result = mobilePickingService.processPick(testPickingOrder, testPosition, "TOTE-001");
assertThat(result).isNotNull();
verify(unitloadService, never()).createUnitload(any(), any(), any(), any());
verify(unitloadBusinessService, never()).transferUnitLoadToCart(any(), any(), any(), any(), any());
```

It must set `testPosition.setPicktounitloadId(null)` and `testPickingOrder.setOperatorId(1L)` and run
under the `MockedStatic<SecurityContextUtils>` block like its siblings, and it must leave
`unitloadRepository.findByStoragelocationId` on the shared `emptyList()` stub so the reuse scan falls
through to the mint — otherwise it tests nothing. Re-run MUT-B afterwards and confirm it goes red.

---

**M2-2 — `isCartPickingSection`'s javadoc still asserts the `throw` you withdrew, eight lines above the code that does the opposite.**
`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

```java
 * <p>Note this answers "this section does cart picking", NOT "this order was actually merged" —
 * a deliberate choice: a cart of one is still a cart, and there is no stored signal for the
 * latter. Both hops are null-guarded; an unrecognised picking type throws rather than silently
 * skipping, matching {@code SectionService.create} and {@code CustomerorderService}. Do not
 * shorten this to an unguarded {@code section.getSectionpickingtype().equals(...)} …
```

The body now reads `LOG.error(…); return false;`, and the inline comment directly beneath it argues at
length for *why* it must not throw and why those two precedents do not apply. The javadoc is the first
thing a reader — or an IDE hover, or the next reviewer — sees, and it currently states the merge-blocking
behaviour that H-1 was raised to remove, citing the same two classes as authority for it.

I am calling this Medium rather than Low on this repo's own track record: a withdrawn claim surviving in
a sibling copy is the recurring failure mode here (`fixing-a-false-claim-tends-to-produce-a-new-one`,
`retitling-a-section-leaves-the-rule-asserted-below-it`, `absence-of-a-path-is-not-absence-of-the-guarantee`).
A maintainer who reads the javadoc and "restores consistency" by re-adding the throw re-lands H-1 — and
would be doing so with the file's own documentation on their side.

*Remedy: **code** (documentation)*. Replace the clause with the withdrawal, e.g. "an unrecognised picking
type is logged at ERROR and treated as *not* a cart section — deliberately unlike `SectionService.create`
and `CustomerorderService.processPackaging`, which select an action and have no safe default; see the
inline comment on the `default` arm." The "do not shorten this to an unguarded `.equals(...)`" sentence is
still true and should stay. While you are in there, grep the ticket's other artefacts for the same
withdrawn claim — a token grep for `throw` is not a sweep; grep the *rule* ("unrecognised", "unknown
picking type", the two precedent class names).

---

### LOW

**L2-1 — the early-return comment names one of the two things a null cart now means.**
`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java`

```java
if (cart == null) {
    return;   // tenant has no Cart type — already logged; picking proceeds without a cart
}
```

`findOrMintPickerCart` returns null for **two** reasons — no Cart `unitload_type` row, and no system
client — and the IT's own assertion message correctly enumerates three fail-open causes. This comment
enumerates one. Prose enumerations rot; state the rule instead.

*Remedy: **code***. `// a required configuration row is missing (already logged) — picking proceeds without a cart`.

---

**L2-2 — a now-dead stub in the D9 test, kept alive by `lenient()`, under a comment that is no longer true.**
`src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java`

```java
// Consumed only by the post-fix, type-aware guard. isCartCarrier was hoisted to
// UnitloadService (M-4, one home for the predicate), so here it is a collaborator and
// must be stubbed; the predicate's OWN behaviour is covered by UnitloadServiceUnitTest.
lenient().when(unitloadTypeRepository.findById(6L)).thenReturn(Optional.of(cartType));
when(unitloadService.isCartCarrier(cartUnitload)).thenReturn(true);
```

After the hoist, `setLockOnHold` never touches `unitloadTypeRepository` at all (verified: none of
`StockunitService`'s five `unitloadTypeRepository` call sites — `:242`, `:249`, `:329`, `:332`, `:539` —
is inside it). The stub is consumed by nothing; only the `lenient()` keeps it from failing strict-stubs.
The first sentence of the comment — "Consumed only by the post-fix, type-aware guard" — is now false, and
the sentence appended after it does not retract it.

Worth deleting rather than leaving: a dead `lenient()` stub is indistinguishable from a live one, and the
`cartType` local it feeds becomes dead with it.

*Remedy: **code***. Delete the stub, the `cartType` fixture if nothing else uses it, and the stale first
sentence; keep the surviving explanation of why `isCartCarrier` is stubbed.

---

**L2-3 — the IT fixture comment claims an end-to-end proof the assertion explicitly declines to make.**
`src/test/java/net/aim_ai/wms/integration/service/mobile/MobilePickingServiceIntegrationTest.java`

```java
// Seeding it makes
// mobilePickingService_Tote_Test the only end-to-end proof in the repo that a Cart really is
// minted and a real Tote really ends up hanging off it in a database; every other test of this
// feature mocks UnitloadBusinessService and so never exercises the carrier write.
```

Sixty lines later the assertion comment says the opposite, correctly:

```java
// NOTE the assertion is on the CART's existence, not on the tote still carrying it.
```

Both halves of the first claim cannot be true. The *mint* is proven (MUT-H kills it). The *carrier write*
is not asserted anywhere in this test — a mutant deleting the `transferUnitLoadToCart(tote, cart, …)` call
would leave this IT green (the unit lane catches it, so this is a documentation defect, not a coverage
hole).

The better fix is to make the claim true, because it is cheap: `transferUnitLoadToCart` → the shared core
→ `processTransfer` writes a `unitload_record` row with activity code `CODE_ASSIGN_TOTE`, and unlike
`carrierunitload_id` that row **survives** `finalizePicking`. `UnitloadRecordRepository` already exists.
One assertion that a record exists for the tote with `CODE_ASSIGN_TOTE` and the cart as its target closes
the one thing this test says it proves and doesn't.

*Remedy: **code***. Add the `unitload_record` assertion, or failing that trim the comment to "…the only
end-to-end proof that a Cart really is minted in a database", and delete the "and a real Tote really ends
up hanging off it" clause and the "never exercises the carrier write" contrast, which only reads as a
claim about this test.

---

**L2-4 — the cart assertion scans the whole table where it means "at this picker's location".**
`src/test/java/net/aim_ai/wms/integration/service/mobile/MobilePickingServiceIntegrationTest.java`

```java
for (Unitload u : unitloadRepository.findAll()) {
    if (cartTypeId.equals(u.getTypeId())) {
        cartsMinted.add(u);
    }
}
… .hasSize(1);
```

Correct **today** — MUT-H proved it — but `findAll()` reads a database shared by every IT class in the
cached Spring context, so the count is only 1 because nothing else has ever minted a Cart. The next test
anywhere in the suite that mints one turns this red for a reason that has nothing to do with this test,
and the failure will be read as a cart-minting regression. The following line already fetches
`pickerLocation`; scoping the scan to `unitloadRepository.findByStoragelocationId(pickerLocation.getId())`
is the same measurement, robust, and subsumes the second assertion.

*Remedy: **code***. Scope the scan to the picker location.

---

**L2-5 — three per-pick `LOG.error` calls with no dedup and no other detection channel.**
`src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java` — the `default:` arm plus both
`findOrMintPickerCart` guards, each shaped like:

```java
LOG.error("findOrMintPickerCart: no '{}' unitload_type row in this tenant — not attaching a cart. "
    + "Picking continues; seed the type to enable cart picking.", WmsConstants.UNIT_LOAD_TYPE_CART);
```

**Answering your question directly: the level is right and the flood is real, and they are separate
problems.** ERROR is defensible precisely because it is the *only* channel — this repo publishes
Micrometer metrics but nothing scrapes them, so a counter would be invisible and a demotion to WARN would
bury it. But the two provisioning branches fire **once per pick, per operator, forever**, for a single
static misconfiguration: a busy TOTES_ON_CART warehouse emits thousands of identical ERROR lines a day
and nothing escalates any of them. That is simultaneously too loud to read and too quiet to alert on, and
it is exactly the "misconfigured mid-rollout who never finds out" case from your question 1 — the
detection gap, not the fail-open, is what leaves that tenant in the dark.

*Remedy: **code**, cheap version*: log the first occurrence per cause at ERROR and subsequent ones at
DEBUG, via a small `AtomicBoolean`/`Set` guard scoped per tenant key. *Or **ticket note*** if you would
rather not carry state in this service — in which case say on SBDEV-3320 that cart-picking has no
operational alarm, so a tenant provisioned without the `Cart` `unitload_type` row or without the system
client will silently never get carts. Do **not** fix this by throwing.

---

**L2-6 — two small documentation gaps in the delta's own new prose.**

(a) `src/main/java/net/aim_ai/wms/service/TransferOrderService.java` — the M-3 comment overstates:

```java
// Cache before breaking: every OTHER exit from this walk populates
// carrierCache, and the DTO phase below looks the carrier up by id.
```

The missing-carrier exit ten lines down (`} else { break; }` at `:390`) does not populate it — it has
nothing to populate it with. "every OTHER exit" is false as written; "the other exits either populate it
or have no carrier to cache" is true.

(b) `src/main/java/net/aim_ai/wms/service/UnitloadService.java` — the hoisted javadoc documents two of
the three false cases:

```java
 * <p>Returns false for a null {@code typeId} and for a type row that cannot be resolved: …
```

The code also returns false for a null `carrier`, which is a **widening** over both private originals
(they would have thrown NPE) and is tested by
`UnitloadServiceUnitTest$IsCartCarrier.isCartCarrier_shouldBeFalse_forNullInputs`. Undocumented new
behaviour is the kind a later reader "tidies away".

*Remedy: **code** (documentation), both one-liners.*

---

**L2-7 — the M-3 cache fix has no test, and nothing would notice if it regressed.**
`src/main/java/net/aim_ai/wms/service/TransferOrderService.java`

```java
carrierCache.put(carrier.getId(), carrier);
break;
```

`TransferOrderServiceUnitTest$TransferLineCarrierAscent` asserts only on the returned DTO list, and the
DTO output is identical with or without the line (§2.7) — so by construction no behavioural test can
catch its removal, and none does. That is fine for a pure performance fix, but it means the double-fetch
this line removes can come back silently, which is precisely what happened to "Fix B2" in the first place.

*Remedy: **code**, if cheap*: one `verify(unitloadRepository, never()).findById(cartId)` after the
existing D10 assertion in `getTransferLineUnitLoads_shouldNotReRootOntoCart`, which pins the cache hit
without asserting on timing. *Otherwise a ticket note* recording that the line is a perf guard with no
test is acceptable — it is the least important item in this report.

---

## 4. What I checked and found clean

- **Full `mvn -o clean verify` re-run independently**: surefire 6522/0/0, failsafe 395/0/0, BUILD SUCCESS.
  Failures compared against the pass-1 baseline, not totals. H-1's single failsafe error is gone.
- **M-1 is genuinely dead** — `if (true)` now killed by two separate tests (MUT-C).
- **The missing-Cart-type guard is covered** (MUT-A killed).
- **Both M-4 call-site pins survive the hoist** (MUT-F, MUT-G killed), and MUT-F gained a second detector
  from the strict stub the L-1 fix introduced.
- **No Spring cycle and no new injection**: `UnitloadService` depends on neither caller; both callers
  already held and used it. The failsafe lane boots the real context and passes.
- **No dead production field** after the hoist in either caller.
- **`isCartPickingSection`'s two null branches** (null `sectionId`, null `pickingType`) are unchanged and
  still `LOG.warn` + `return false` — the `default:` arm is now consistent with them, which it was not before.
- **The IT's committed `los_sequencenumber` seed** is sound: it is idempotent (counts first), asserts its
  own visibility from a fresh connection, and `TestDatabaseConfig` confirms `landlordDataSource` **is** the
  single H2 instance the tenant repositories also see (the `tenantDynamicRoutingDataSource` mock delegates
  `getConnection()` straight to it), so the `@Qualifier` choice is correct rather than lucky. It matches
  `AdviceServiceRollbackIntegrationTest`'s existing pattern.
- **The IT's system-client and Cart-type seeds do not disturb the two rapid tests** — both still pass in
  the 395/0 lane, and neither reaches `attachToteToPickerCart` (one call site, `processPick:554`).
- **The D8 deletion lost nothing** — `eq(CODE_ASSIGN_TOTE)` still asserted at four sites; its replacement
  additionally pins the cart argument.
- **The L-1 fix genuinely closes its hole** — a null-message throwable now fails both `satisfiesAnyOf` arms.
- **Both fail-open precedents verified in source**, not taken on trust (§2.1).

## 5. What to do next

1. **M2-1** — the one real gap. Add the null-system-client test and re-run MUT-B to confirm it dies.
2. **M2-2** — fix the javadoc before anyone reads it as licence to restore the throw, and grep the rule
   rather than the token when sweeping for siblings of the claim.
3. **L2-1, L2-2, L2-3, L2-4, L2-6** — mechanical, one pass.
4. **L2-5** — decide: per-cause dedup in code, or a ticket note recording that cart picking has no alarm.
5. **L2-7** — optional one-line `never()` verify, or a ticket note.

None of these is a merge blocker. If you land M2-1 and M2-2 and note the rest, I would ship it.

### Note on this review's own instruments

Every verdict above that could be measured was measured: six mutants, each run alone in a disposable
worktree, plus a full independent `verify`. The two questions I would have got wrong from reading alone
are both in §2: MUT-B's survival (I predicted it from the fixtures, but a targeted-class run would have
been a *partial* survival and I would have had to escalate anyway), and the IT leftover question, where
`@Transactional("tenantTransactionManager")` on the base class is a correct argument that still would not
have told me the count was 0 rather than 1-by-luck. MUT-H did. Pass 1's closing note — that a reviewer's
static errors point toward "safe, no action" — held again here: my only pre-measurement doubt was whether
MUT-C had really been killed, and it had been, twice.
