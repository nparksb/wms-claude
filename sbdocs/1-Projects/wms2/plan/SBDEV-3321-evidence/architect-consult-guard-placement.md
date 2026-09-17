---
title: "SBDEV-3321 — architecture consult: where the pending-reversal guard goes"
type: evidence
subtype: architect-consult
status: answered
ticket: SBDEV-3321
tier: T2
version: v2
repo: v2/wms2-api
code_base: "origin/develop @ e113467b (fetched 2026-09-16; same head lane A and lane B analysed). Every code citation is `git show origin/develop:<path>` — the local checkout was not read."
db_evidence: "mcp__wms2-hydra__execute_sql, database wh01_hydra_v2 (Hydra PRD, read-only), 2026-09-16 16:44 UTC"
created: 2026-09-16
owner: Nam Park
---

# Answer in one paragraph

**The guard is the wrong primary instrument, and I would not build it as specified.** The invariant
you want — *stock a pending reversal is committed to must not be freely relocatable* — already has an
expression in this system, `stockunit.entity_lock = PICKED_FOR_GOODSOUT`, and every operator movement
chokepoint already reads it. The defect is not a missing consumer-side check; it is that **two of the
three cancel paths tear that fence down in the same transaction that writes the row claiming the stock
back**. Fix the **producers** (4 named lock-clear sites, all inside cancel paths) and the fence is
restored at three chokepoints *for free*, with **no new lookup, no new discriminator, no self-block,
and no risk of blocking the cure** — because `completeReversal` was already built to clear the lock
and flush before it moves (SBDEV-3326). One consumer-side widening is still needed
(`MobileMoveUnitloadService`, which compares `== ON_HOLD` only). And one thing is a **hard
prerequisite at any tier and under any design**: there is currently **no waive action**, so a
fail-closed fence can strand stock with no operator path out at all. §4 is the most important
section in this document.

If the team still prefers the pending-reversal lookup guard, §7 gives that design honestly, including
the discriminator that actually works (it is not an activity code — see §2.2).

---

## 0. The three facts that reshape the question

All three were measured on `origin/develop` for this consult and are not in either lane doc.

### 0.1 The reversal's own cure takes the SAME code path, with the SAME activity codes, as the hand move it is supposed to block

`CancellationReversalService`:

```java
stockunitService.transferStock(stockUnit, log.getAmountPicked(), false, log.getPickfromlocationname(), null, null, false);
```

That is `StockunitService.transferStock` — **the exact method behind `POST /v3/stockUnit/transferStock`,
web Move Stock**. Inside it, the whole-container arm passes `WmsConstants.CODE_MANUAL_TRANSFER` and
the mint-a-new-container arm passes `WmsConstants.CODE_MANUAL_SPLIT` — the same constants an operator
hand-move produces, because it *is* the same lines of code.

**Consequence:** the obvious precedent in this repo — `PickLineActivityCodeClassifier`, which sits in
*both* of the chokepoints you named and already solves "which callers are hand moves" for SBDEV-2481 —
**cannot be reused here.** It discriminates the reversal from a hand move at exactly 0% accuracy,
because they are indistinguishable on that axis. Any plan that reaches for it will produce a guard
that either blocks the cure or fences nothing. Method: read `StockunitService.transferStock` end to
end on `origin/develop` and matched its six `transferStockToUnitLoad` calls and one
`transferUnitLoadToLocation` call against the call in `CancellationReversalService`. Blind spot: I did
not trace the `isTransferToExistingContainer = true` prologue, which the reversal never enters
(it passes `false`).

### 0.2 The self-block is real, it is not a deadlock, and it is path-dependent

Your brief says the cancel path "calls `sendToClearing` in its own transaction and would deadlock
against its own guard". The mechanism is different and worse.

`sendToClearing` → `transferUnitLoadToLocation` carries
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`
— propagation `REQUIRED`, i.e. it **joins** the cancel's transaction. `recordCancellation` is
`@Transactional(..., propagation = Propagation.MANDATORY)`, so it too runs in that same transaction.
There are not two transactions, so there is nothing for Postgres to deadlock. What actually happens
is that a guard placed in `processTransfer` **reads the cancel's own uncommitted log rows**, throws
`BusinessException`, and — because `rollbackFor` lists it — **rolls the entire cancel back**. The
operator's cancel fails outright. That is a total loss of the primary operation, not a hang.

And it does not happen uniformly. Measured ordering, by reading each cancel entry point on
`origin/develop`:

| Cancel path | Writes the log row | Moves the tote | A `processTransfer` guard would… |
|---|---|---|---|
| `CustomerorderService.cancelOrder` | `:922` → `cancelOrderPosition` → `CustomerorderPositionService:143` | `:950` `sendToClearing(tote, CODE_TRANSFER, …)` | **refuse the cancel** — rows exist first |
| `CustomerorderService.forceCancelOrder` | `:424` | `:491` / `:527` `sendToClearing(pickingTote/parcel, …)` | **refuse the cancel** — rows exist first |
| `PickingorderBusinessService.cleanUpCancelledOrder` | `:732` `cancelOpenPickLines` | `:698` `sendToClearing(tote, CODE_TRANSFER, …)` | **pass** — the move precedes the rows |

**This asymmetry is the trap.** A chokepoint guard would break two of three cancel paths and leave the
third green, which is exactly the shape that survives a test suite written against one path. It is
also brittle in the other direction: any future reordering of `cleanUpCancelledOrder` silently arms
the third.

Method: `git grep -n` for `recordCancellation|sendToClearing|setEntityLock` restricted to the three
cancel classes on `origin/develop`, then read each hit's enclosing method. Blind spot: line numbers
drift; the *ordering* claim is what matters and is re-derivable from the same grep.

### 0.3 The lock the two paths clear is not operator-removable, and the pick-to lock is the only fence that ever existed

`WmsConstants.BusinessObjectLockState`:

```java
public static final int NOT_LOCKED = 0;
public static final int PICKED_FOR_GOODSOUT = 100;
public static final int QUALITY_FAULT = 103;
public static final int ON_HOLD = 104;
public static final int SHIPPED = 405;
...
public static final int[] OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD };
```

`PICKED_FOR_GOODSOUT` is **not** in `OPERATOR_REMOVABLE`, so `POST /stockUnit/removeLock`
(`StockunitService:918`, the `:961` clear) refuses it. That is what makes it a real fence rather than
a suggestion — and simultaneously what makes §4's missing waive action a blocking problem.

---

## 1. Placement — stated as an invariant

### 1.1 The invariant I would implement (producer side)

> **A transaction that writes a `customerorder_cancellation_log` row with `reversal_required = true`
> must not, in that same transaction, clear the goods-out lock on the stock that row claims.**

The mechanism this fences is a **field write**: `stockunit.entity_lock ← NOT_LOCKED`, inside a cancel.
It is deliberately phrased on the write, not on a method name, per the same reasoning lane A used for
its census — a rename hides a method grep and cannot hide a field write.

**The closed set, and how it was derived.** `git grep -n` on `origin/develop`, restricted to
`src/main/java`, for `setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED)`,
`setEntityLock(BusinessObjectLockState.NOT_LOCKED)` and `setEntityLock(0)` — 63 hits — then filtered
to those whose receiver is a `Stockunit`, then to those inside a cancel path. That leaves **four**:

| Site | Reachable? | Today's effect |
|---|---|---|
| `CustomerorderService:953` — `"toteStock.forEach(su -> su.setEntityLock(...NOT_LOCKED))"` in `cancelOrder` | **live, the common path** | tote stock fully unlocked → both move arms open |
| `PickingorderBusinessService:701` — `"stockUnits.forEach(su -> su.setEntityLock(...NOT_LOCKED))"` in `cleanUpCancelledOrder` | live | same |
| `CustomerorderService:523` — parcel stock in `forceCancelOrder` | live (its own comment calls this "the reachable arm") | same |
| `CustomerorderService:488` — tote stock in `forceCancelOrder` | the file's own comment marks this branch **currently unreachable in production** | latent |

Three Stockunit clear sites are outside cancel paths and are **correct as they are** — name them in
the code so the next reader does not "fix" them:
`CancellationReversalService:350` (the cure), `StockunitService:961` (`removeLock`, already refuses
`PICKED_FOR_GOODSOUT`), `MobileMoveUnitloadService:602` (release-to-pool, which already refuses
anything but `NOT_LOCKED`/`QUALITY_FAULT`:
`"Can't move! stock=… has different lock="`). `StockunitBusinessService:133/134` and
`StockunitService:213` write the field on a brand-new row, not a clear.

**Blind spots of that census, inline.** Complete for compiled Java field writes in `src/main` on this
head. Blind to: (a) the **two bulk JPQL statements** in `BillofladingService`
(`"UPDATE Stockunit s SET s.entityLock = :lock"` at `:675` and `:1601`) — they set the lock, not
clear it to zero, but they *overwrite* whatever the fence was, and they are outside the grep's shape;
(b) direct DB edits / operator psql; (c) branches not merged to develop; (d) v1;
(e) a lock value computed at runtime rather than written as the constant.

### 1.2 What the invariant buys, mechanism by mechanism

Restore the fence and the *existing* guards close three of the four movement mechanisms with no new
code:

| Mechanism | Guard that already refuses a locked source | Closed by lock preservation? |
|---|---|---|
| inter-container stock move (`StockunitBusinessService.transferStockToUnitLoad`, 19 call sites) | its `if (!ignoreLock)` block: `"Source stockUnit=" + … + " is locked=" + lock` | **YES** |
| web Move Stock whole-container arm (`StockunitService:539`) | `SourceLockGuard.assertSourceUnlockedForContainerRelocation` — refuses **any** non-zero lock (SBDEV-3341, Nam's decision 2026-09-14) | **YES** |
| mobile transfer picking whole-container arm (`MobileTransferOrderService:408`) | same static guard | **YES** |
| mobile **Move Unit Load** (`MobileMoveUnitloadService.scanUnitLoad:157/163`, `scanDestination`) | `== WmsConstants.BusinessObjectLockState.ON_HOLD` **only** | **NO — this is the one hole** |

`SourceLockGuard`'s own javadoc already records the divergence as accepted:

> *"`MobileMoveUnitloadService` refuses `ON_HOLD` alone and explicitly PERMITS `QUALITY_FAULT`, so
> mobile Move Unit Load still relocates containers this guard now refuses. That divergence is
> accepted, not overlooked."*

That acceptance was made for `QUALITY_FAULT` and `SHIPPED`. **SBDEV-3321 is the evidence that revisits
it for `PICKED_FOR_GOODSOUT`**, and it is exactly the arm lane A measured as succeeding on T-0002
today. So the consumer-side change is *one* change, in one class, and it is a narrowing of a
comparison rather than a new lookup.

### 1.3 Honest statement of what escapes

The set is **not** closed. Named escapes, with the reason each is in or out:

1. **`BillofladingService` ×2 bulk JPQL** — `"UPDATE Unitload u SET u.storagelocationId = :shippedLocationId, u.entityLock = :lock"` at `:665` and `:1591`, each paired with a `"UPDATE Stockunit s SET s.entityLock = :lock"` at `:675` / `:1601`. These enter neither `processTransfer` nor `transferStockToUnitLoad`, and they **overwrite** the fence rather than respecting it. **Recommendation: exclude, with the reason recorded in the code.** A BOL close is a terminal, audited, multi-order operation; refusing it because one line of one order has a pending reversal halts outbound shipping for a bookkeeping row, and the remedy an operator would need is not available at the truck. What I would do instead is make it **visible**: have the close path count pending reversals over the pallets it is shipping and, when non-zero, write one `MessageService.createServiceLog` row naming the order and tote. That is the same channel lane B recommends for F5, costs no new dependency, and converts a silent overwrite into a durable record. Do **not** state anywhere that the chokepoint guard "covers all relocations" — this is the counterexample.
2. **Direct DB edits.** Out of scope for any code-level design; worth one line in the plan.
3. **A future operator entry point** that reads the lock with a `== ON_HOLD`-shaped comparison. This is the recurrence risk, and it is why the fix needs an **ArchUnit or source rail**, not just a widened `if`: a rule that every comparison of `stockunit.getEntityLock()` in an operator-move path is against `NOT_LOCKED`, not against a specific non-zero state. Per `a-guard-fences-the-mechanism-you-aimed-at`, state in the javadoc which mechanisms the guard covers and which are covered elsewhere — never assert a total.

---

## 2. The self-deadlock / discriminator question

### 2.1 Under the recommended design there is nothing to discriminate

This is the strongest argument for the producer-side fix, so I want to make it explicit rather than
leave it implied.

- **The cancel's own tote teardown is unaffected.** `sendToClearing` calls
  `transferUnitLoadToLocation(unitload, clearingLocation, true, …)` — `ignoreLock = true` — and
  `processTransfer` has **no source-stock check at all** (its absent source guard is deliberate and
  documented at length in `transferUnitLoadToLocation`'s javadoc, load-bearing for truck loading).
  A stock lock that survives the cancel therefore cannot refuse the cancel's own move. No self-block,
  on any of the three paths, regardless of ordering.
- **The cure is already unlock-then-move.** `CancellationReversalService` clears the lock and flushes
  *before* calling `transferStock`, and its own comment says exactly why the flush is load-bearing —
  `transferStockToUnitLoad` re-reads with `findByIdForUpdate` then `entityManager.refresh(...)`,
  which discards in-memory state. So the reversal already passes a fence it re-erects on the residue.
  SBDEV-3326 built this discriminator; SBDEV-3321 does not need to build another.

**The discriminator is a state transition the reversal performs and an operator cannot**: clearing
`PICKED_FOR_GOODSOUT`. It cannot be spoofed by an ordinary operator path because
`OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD }` excludes it, so `POST /stockUnit/removeLock` refuses
it and there is no other clear site reachable from a controller (census in §1.1). That is a
capability-based discriminator, not a flag, and it is already enforced.

### 2.2 If you build the lookup guard instead, here is the discriminator that works — and three that do not

| Candidate | Verdict |
|---|---|
| **Activity code** (reuse `PickLineActivityCodeClassifier`) | **Does not work.** §0.1 — the reversal emits `CODE_MANUAL_TRANSFER` / `CODE_MANUAL_SPLIT`, byte-identical to web Move Stock, because it *is* web Move Stock's method. |
| **A new `ignoreLock`-style boolean threaded from the caller** | Works mechanically, but the flag must be threaded through `StockunitService.transferStock` — a **public** method behind a gated controller endpoint. Anything reachable from a controller is reachable by an operator unless a separate check stops it, so the flag would need its own `@RequiresFunction`-equivalent, at which point you have rebuilt the capability check that `OPERATOR_REMOVABLE` already gives you. Worse ratio than §2.1. |
| **A `ThreadLocal` reversal marker set in `completeReversal`** | Works, and matches the repo idiom (`TenantContext`), but inherits its hazard: SBDEV-3190 was exactly a leaked singleton/thread-scoped state bug in this codebase, and every `TenantContext` use site in `schedulejob/` carries a `finally { clear(); }` for that reason. Unspoofable (no setter reachable from a controller), but it adds a new invisible coupling between two services for a problem §2.1 already solves. |
| **Order the guard against the log row's own state** (`reversal_completed_at IS NULL`) | **Does not work.** `completeReversal` stamps `reversal_completed_at` *after* the movement loop, so the row is still pending while the cure is moving. The guard would refuse the cure. |

If the lookup guard is built anyway, use the **ThreadLocal marker**, set it in `completeReversal`
inside a `try`/`finally`, and pin the `finally` with a test that throws mid-loop.

---

## 3. Fail-open vs fail-closed

Two different questions get conflated here; separate them.

**The guard's own verdict is fail-CLOSED and must be.** When the lookup returns nothing, there is no
pending reversal, so the move proceeds — that is not "failing open", it is the guard answering
correctly. When the lookup returns a row, the move is refused. There is no third state to be lenient
about. The standing lesson
(`enhancement-paths-must-fail-open-on-missing-config`) does not apply to this axis: that lesson is
about *configuration* prerequisites of an enhancement path, and this is not an enhancement hanging off
a host operation — it is the safety property itself. Under the recommended §1 design the point is
moot: the "lookup" is `stockunit.entity_lock`, a `NOT NULL`-in-practice column already read by three
guards, with `SourceLockGuard`'s documented and measured decision that **null is permissive**
(0 nulls out of 804 stockunit rows on Hydra PRD 2026-09-14, with the non-zero total as the positive
control). Keep that.

**The sysprop gate, if you add one, must fail OPEN — i.e. the guard stays ON.** Lane A §2.7 suggests a
sysprop defaulting ON, on the SBDEV-3340 precedent. If you do that, read it with
`SyspropService.getIntValue`-style tolerance, **not** with
`Boolean.parseBoolean(syspropService.getSysvalue(KEY))`. That shape is the §3.1 landmine lane B
documents: `SyspropRepository.findSysvalueBySyskey` returns `null` for an absent row and
`Boolean.parseBoolean(null)` is `false`, so a forgotten seed migration silently **disables the
safety check on every tenant, forever**, with nothing but an absence to notice. Write it as
"engaged unless the row explicitly says `false`":

```java
String raw = syspropService.getSysvalue(KEY);
boolean engaged = raw == null || raw.isBlank() || !"false".equalsIgnoreCase(raw.trim());
```

**My actual recommendation: do not add a sysprop at all.** SBDEV-3340's shadow-mode sysprop existed
because that check could reject moves that had always been permitted at a *destination-configuration*
level, across tenants with wildly different `location_constraint` data. This change has no such
tenant-data dependence — it restores a lock that one of the three cancel paths already leaves in place
today, live on PRD, on the only two totes that have ever been in this state. A kill switch here is a
switch that turns the ticket off.

---

## 4. Operator impact — and the blocking prerequisite

### 4.1 Lane A's eight-path list: confirmed, and it is the argument *against* the chokepoint guard, not a caveat on it

I re-derived it and agree with every row. `processTransfer` is reached by `sendToClearing`,
`relocateEmptiedContainer`, `transferUnitLoadToCarrier`/`ToCart`, and by receiving, putaway, truck
loading, parcel-monitor, flow-bin housekeeping and the finished-picking hop. An unconditional guard
there halts outbound. Lane A's conclusion stands and the brief already accepts it.

What lane A does not say, and should be in the plan: **`transferUnitLoadToLocation`'s javadoc declares
the absence of a source guard to be the house rule**, with a measured justification —

> *"**THE RULE — where a source-lock policy belongs: in the caller.** This method enforces the
> DESTINATION only. … Hydra PRD, 2026-09-14: 204 `TRUCKLOADING` moves across 199 unit loads … A
> carried-stock guard under `!ignoreLock` refuses all of them."*

So a guard inside `processTransfer` is not merely risky — it contradicts a rule that was written,
measured and pinned three weeks ago by SBDEV-3341, and would need that decision reversed first. The
§1 design honours it: the policy goes **in the callers**, which is where `SourceLockGuard` already
lives.

### 4.2 Blast radius of the recommended change

| Who feels it | What changes |
|---|---|
| An operator moving stock off a cancelled tote via **web Move Stock** | Already refused today on the split arm (`is locked=100`) for per-position cancels; after the fix, also refused for order cancels. Newly refused on the whole-container arm via `SourceLockGuard`. |
| An operator relocating a cancelled tote via **mobile Move Unit Load** | **Newly refused.** This is the change with real floor impact. |
| Anyone marking cancelled stock **damaged** | The two damaged arms in `StockunitService.transferStock` pass `ignoreLock = true`, so the split-to-Damaged route still works. The whole-container route to Damaged is refused by `SourceLockGuard`. That asymmetry is pre-existing (SBDEV-3341's own subject), not created here — but say so in the plan rather than letting a reviewer find it. |
| Cancel itself, truck loading, receiving, putaway, BOL close | **Unaffected** — all pass `ignoreLock = true` or never read the source stock lock. |

### 4.3 ⚠ Can it strand an operator with no way forward? **Yes — today, and this is the blocking prerequisite**

`OrderCancellationController` (`@RequestMapping("/v3/cancellation")`,
`@RequiresFunction(WmsConstants.FunctionEnum.MOBILE_UI_VIEW_CANCELLATION)` at class level) exposes
exactly five operations — read end to end, so this is an enumeration by construction, not a sample:

```
GET  /list                     POST /scan-tote
GET  /{customerOrderId}/detail POST /{customerOrderId}/initiate
                               POST /{customerOrderId}/complete
```

**There is no waive, no abandon, no dismiss.** A `git grep -in "waiv"` over `src/main/java` returns
two hits, both comments, neither an action. And `completeReversal` carries **three** hard refusals that
each end `"— manual intervention required"`: unresolvable `picktostockunit_id`, null
`pickfromlocationname`, and a source lock that is neither `NOT_LOCKED` nor `PICKED_FOR_GOODSOUT`.

Chain that together:

> a row that `completeReversal` refuses → stock stays at `PICKED_FOR_GOODSOUT` → `removeLock` refuses
> it (`OPERATOR_REMOVABLE` excludes 100) → every move path refuses it → **no operator, at any
> permission level, has an action that resolves the state.** The only remedy is a DBA.

That is true of *any* fail-closed design here — the lookup guard has precisely the same property, with
the added twist that its fence (a log row) is not even visible on the Stock Units screen, so the
operator sees a refusal naming a state they cannot see. **The lock at least renders.**

**Therefore: `POST /v3/cancellation/{id}/waive` — recording an operator, a timestamp and a mandatory
reason, stamping `reversal_completed_at` with a `waived` marker, and clearing the lock — is a
prerequisite of this ticket, not a follow-up.** Lane A's Option D for bypass #2 rejects waiving *from
a no-argument bulk endpoint*, and that rejection is right; a named-operator, single-order, reason-bearing
waive is a different thing and is the missing half of the workflow. Gate it on its own function
constant, not on `MOBILE_UI_VIEW_CANCELLATION` — and note the three-part requirement in
`wms2-adding-a-function-constant-needs-three-things` (enum + `initDB` grant line + seed migration);
omitting the grant line makes it unusable by everyone.

If the team will not take the waive in this ticket, then **do not ship a fail-closed fence in this
ticket either.** Ship detection first (lane B's F5 Service Log row), and keep the fence for the PR
that carries the waive. Shipping the fence alone converts a 47-day bookkeeping strand into a
permanently immovable pallet.

---

## 5. The error contract

### 5.1 Use the 1-arg constructor knowingly, or add a real key

```java
public BusinessException(String message) {
    super(resolveMessage(Locale.getDefault(), "placeholder", message));
    this.key = "placeholder";
    this.parameter = new Object[]{message};
}
```

So **`getKey()` returns the literal `"placeholder"`** for every message-only throw. A test asserting
`getKey()` on such an exception pins nothing — it passes for *any* 1-arg `BusinessException` anywhere
in the call chain. The 2-arg form `BusinessException(String key, Object... parameter)` sets a real
key, and `getMessage()` resolves it through the `messages` bundle — which means, per that class's own
javadoc, that `getMessage()` returns **the key while the key is missing from the bundle and localised
prose once it is present**, so asserting on rendered text couples the test to translation state.

**Recommendation:** add a proper key, e.g.
`BusinessException.CancellationReversalPending`, with a bundle entry and positional parameters. Then
assertions use `getKey()` and are stable. ⚠ Use `%1$s`-style positional forms, not bare `%Ns` — per
`java-bare-percent-ns-is-not-positional`, `%2s` is a width specifier, not an argument index, and the
existing `INVALID_SYSPROP_VALUE` comment shows the correct form. If the team prefers to stay with the
1-arg style for consistency with `SourceLockGuard`'s messages, then **assert on message substrings and
say in the test why `getKey()` is useless here** — do not assert `getKey()` and call it a pin.

### 5.2 What the operator must see

The existing precedent is right and should be followed. `SourceLockGuard.describe(...)`:

> *"SBDEV-3226 precedent: a bare lock CODE reaches the warehouse floor as `is locked=100` and tells
> the operator nothing they can act on. … the code is kept (it is what a support ticket quotes) and
> the human-readable state is appended."*

Under the §1 design the operator already gets
`Source stockUnit=60941 is locked=100 (Picked)`. **That is still not actionable** — it names neither
the order nor the exit. Extend it, in `SourceLockGuard` and in `transferStockToUnitLoad`'s
`!ignoreLock` block, to name the blocking order and tote and the screen that resolves it. Something
like:

> `Stock unit 60941 on tote T-0002 is reserved for goods-out (100) by a pending cancellation reversal
> for order 000026-000001. Complete or waive the reversal on the Cancellation screen before moving it.`

Resolving the order number costs one lookup by the container axis (§7.1) and is worth it: a refusal
that names the exit is the difference between a 20-second fix and a support ticket. Note the cost
honestly — a refusal path now performs a query it did not before; it runs only on the refusal branch,
so the hot path is untouched.

---

## 6. Test surface — which lane can observe what

Three lanes, and they are not interchangeable. Facts taken from `v2/wms2-api/CLAUDE.md` and lane B §6,
and the two that bite hardest are restated because they produce green tests that prove nothing.

| # | Assertion | Lane | Why that lane, and the trap |
|---|---|---|---|
| 1 | each of the four cancel sites leaves `entity_lock = PICKED_FOR_GOODSOUT` when `reversal_required = true` | **unit** (Mockito, `extends BaseServiceUnitTest`, `STRICT_STUBS`) | An `ArgumentCaptor` on `stockunitRepository.save(...)`. ⚠ Assert the *value captured*, not `verify(never())` on the setter — a `never()` on a primitive-arg method needs `anyLong()`/`anyInt()`, since `any()` returns null and NPEs at unboxing **before** the verification runs (`NeverMatcherNullBlindnessArchTest` inventories these). |
| 2 | `transferStockToUnitLoad` refuses a source at 100 | **unit** — already covered by `StockunitBusinessServiceUnitTest` | No new lane needed; add a row, do not rebuild. |
| 3 | `SourceLockGuard` refuses 100 on the container arm | **unit** — `StockunitServiceUnitTest.TransferStockSourceLockGuard` exists, including two placement pins | Note its javadoc's warning that a top-of-method placement *looks* safe and is not. |
| 4 | mobile Move Unit Load refuses a source at 100 | **unit** — `MobileMoveUnitloadServiceUnitTest` | This is the new refusal; it needs both a 100 row and a 0 row, or a `!=`→`==` mutant survives. |
| 5 | **the cancel still completes end to end with the lock preserved** | **full-context** | This is the assertion that actually retires the self-block worry, and it cannot be made in a unit test — the interaction is the transaction. Use the **MockMvc/H2 lane** (`application-integration.properties`, `jdbc:h2:mem:wms_integration;MODE=PostgreSQL`, `H2Dialect`), which predates SBDEV-3239 and is the cheap one. It can carry this because nothing in the design needs Postgres-only SQL. |
| 6 | `completeReversal` still moves stock with the lock preserved on arrival | **full-context** — `CancellationReversalLockClearIntegrationTest` already exists; extend it | Keeps the cure pinned against a future "tidy-up" of the SBDEV-3326 clear. |
| 7 | anything using `FOR UPDATE SKIP LOCKED`, `make_interval`, `now() - interval` or other PG-only SQL | **Testcontainers only** | The H2 lane silently tests nothing. Avoid needing this: keep any new predicate in JPQL with Java-bound parameters. |

**Two traps that would make a green meaningless here:**

- **Tenant repository tests COMMIT; they do not roll back** (they run on the wrong transaction
  manager). Assert by re-reading a specific id, never with `isEmpty()`/`hasSize()` — a sibling test's
  residue satisfies those. And a bare `@PersistenceContext` yields the **landlord** EM, which does not
  manage `Stockunit` at all, so a `flush()` through it is a silent no-op — `CancellationReversalService`
  documents exactly this and uses `@PersistenceContext(unitName = "tenant")`. Any new test helper must
  do the same.
- **`mvn test` never runs the failsafe lane.** Run `mvn verify`. For one integration class:
  `mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` — never
  `mvn failsafe:integration-test`, which reports `Tests run: 0` and **BUILD SUCCESS** for any class.

**Mutation checks (the floor, not optional).** For each new assertion, break what it protects and
confirm red:
- flip the preserved lock back to `NOT_LOCKED` at each of the four cancel sites → test 1 red at that site;
- widen mobile's comparison back to `== ON_HOLD` → test 4 red;
- delete the `entityManager.flush()` in `completeReversal` → test 6 **may stay green** (PIT already
  survived that mutant there, because Hibernate `FlushMode.AUTO` carries it). Do not read that as a
  passing mutation check; the honest move is to record it as a known-unkillable line with the reason,
  as that file already does.
- ⚠ The lane-A mutation check — "key the predicate on `picktostockunit_id` and confirm red" — only
  applies to the §7 design. Under §1 there is no predicate to mis-key; the equivalent check is
  "clear the lock and confirm the move succeeds".

---

## 7. If you build the lookup guard anyway

I would not, but the design should be on record so it is not re-derived badly.

### 7.1 Predicate — container axis primary, and it is 1:N

Lane A is right that `picktostockunit_id` is NULL on all 16 PRD rows and a guard keyed on it fences
nothing. Confirmed independently for this consult
(`mcp__wms2-hydra__execute_sql`, `wh01_hydra_v2`, 2026-09-16 16:44 UTC), plus **one fact lane A does
not report**: the nine `reversal_required = false` rows carry `picktounitload_id = NULL` as well, so
the container axis is populated *only* on rows that need it — 7 of 16.

⚠ **The container hop fans out 1:N.** Log row 1 (`picktounitload_id = 60938`) resolves to unit load
17662 (`T-0002`), which carries **four** stock units (60941/60947/60952/60957, all `entity_lock = 100`,
amounts 24/12/12/12). So a container-axis guard on a *stock* move refuses moving **any** stock on that
tote, including stock no reversal claims. On T-0002 every unit happens to be claimed, so PRD does not
show the over-reach — but the over-reach is structural, and the plan must decide it deliberately
rather than discover it. (For a tote, refusing the whole container is arguably right. Say so.)

### 7.2 Placement, given §0.2

- **`StockunitBusinessService.transferStockToUnitLoad`** — put it inside the existing
  `if (!ignoreLock)` block, alongside the six lock checks, *not* at the top of the method. Every
  system caller that must pass already passes `ignoreLock = true`, so the block is the ready-made
  exemption set and you inherit its call-site reasoning instead of re-deriving it.
- **`UnitloadBusinessService.processTransfer`** — **no.** §0.2 and §4.1: it breaks two of three cancel
  paths and contradicts SBDEV-3341's stated rule. If container relocation must be fenced, do it the
  way SBDEV-3341 did — **in the callers**, via a static guard the operator-facing callers invoke, and
  add `MobileMoveUnitloadService` to `SourceLockGuard`'s caller set.
- Discriminator: the ThreadLocal marker of §2.2, with a `finally`-clear pinned by a throwing test.

### 7.3 Query shape

Lane A's JPQL is correct — the subquery, not a join, because this repo declares no JPA associations.
Two additions:

- Add the `reversalCompletedAt IS NULL` leg **and** a positive control in the test that a *completed*
  row does not match, or a dropped leg is invisible (lane B's wineco-dev control is exactly this
  shape: 5 rows pass the `reversal_required` leg and are excluded by the completion leg).
- ⚠ **`V2.2.31` has not reached Hydra PRD.** Lane A measured 23 columns with no
  `pickingorder_position_id`. Anything reading that column fails on PRD until Flyway runs. The
  container-axis predicate does not need it — keep it that way.

---

## 8. Recommendation, ranked

| # | Change | Cost | Why first |
|---|---|---|---|
| **1** | **`POST /v3/cancellation/{id}/waive`** — named operator, mandatory reason, stamps completion, clears the lock; new function constant with all three parts | ~½ day | §4.3. **Blocking** for anything fail-closed. Also independently useful: it resolves the 7 PRD rows without a DBA. |
| **2** | **Preserve `PICKED_FOR_GOODSOUT` at the four cancel lock-clear sites when `reversal_required = true`** | ~2 h | §1. Closes 3 of 4 mechanisms with zero new lookup code, no discriminator, no self-block. |
| **3** | **Narrow `MobileMoveUnitloadService`'s `== ON_HOLD` comparisons** to refuse any non-`NOT_LOCKED` source stock lock — ideally by calling `SourceLockGuard` | ~2 h | §1.2. The one remaining live hole, and the arm lane A measured as open today. |
| **4** | **Message upgrade** — name the order, the tote and the Cancellation screen in both refusal sites | ~2 h | §5.2. Without it the fence produces support tickets instead of fixes. |
| **5** | **Service Log row from BOL close** when it ships pallets carrying pending reversals | ~3 h | §1.3. Converts the one accepted escape from silent to recorded. |
| **6** | Source rail (ArchUnit or a source assertion) that operator-move lock comparisons are against `NOT_LOCKED` | ~3 h | §1.3. This is a recurrence class, not a one-off. |
| — | The pending-reversal lookup guard at the chokepoints | ~2 days | §7. Strictly more code, strictly more risk, and it needs items 1 and 4 anyway. |

Items 2+3+4 are one PR and are, on my reading, the whole of SBDEV-3321's technical content. Item 1 is
the prerequisite. **Tier: this stays T2** — multi-file and a contract change on the refusal shape, but
predictable and reversible. It escalates to T3 only if the team takes the §7 design, or if the waive
action turns out to need an OMS-side signal (it should not: waiving changes no stock).

---

## 9. What I did not verify

- I did not run the suite. Every claim above is from source reading, `git grep` on `origin/develop`,
  and one PRD query — no test was executed for this consult.
- I did not check the two v2 UIs for what they render on these refusals, so §5.2's claim that the
  message reaches the operator verbatim rests on `SourceLockGuard`'s javadoc ("Both consumers render
  the message verbatim"), which I did not re-derive.
- The PRD query covers **one** tenant-facility pair (`wh01_hydra_v2`). Lane B established that this is
  the only one of six reachable v2 DBs with any pending reversal at all, so the population claim is
  sound, but per-tenant lock conventions were not re-checked here.
- I did not enumerate `src/test` for tests that would break under §1 — item 2 will red at least one
  existing test, and `UnitloadBusinessServiceUnitTest.TransferUnitLoadToLocationSourceLockAsymmetry`
  explicitly pins the absence of a source guard, so **confirm which reds are by-design before treating
  any of them as a flake** (lane A §2.9 makes the same point).
