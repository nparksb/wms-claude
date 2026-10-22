# SBDEV-3637 — Lane B (architect): design verdict on the lock-ordering fix

**Tree read:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637-readonly` @ `ec42f43a`
(`Merge pull request #453 from SiteBossInc/feature/SBDEV-2624-sku-rename-in-place`). Read-only; no `mvn`,
no writes, no HEAD change.

**Verdict up front: GO-WITH-CHANGES.** The `-2` premise holds — I verified it in bytecode, not from the
javadoc. The hybrid shape (ascending → plain lock, descending → skip-locked) is the right primitive and
should NOT be simplified to always-skip-locked; I have a measured number for why. Seven changes are
required before implementation, listed in §10. The riskiest premise is not the `-2` hint; it moved. See §11.

---

## 1. Q1 — Does `-2` actually produce `FOR UPDATE … SKIP LOCKED` on the tenant EMF?

**YES. Established by disassembly of the exact artifact on the build classpath, not from the javadoc.**

### 1a. The dialect level

Jar: `~/.m2/repository/org/hibernate/orm/hibernate-core/6.6.39.Final/hibernate-core-6.6.39.Final.jar`.
`javap -p -c org/hibernate/dialect/PostgreSQLDialect.class`:

```
  private java.lang.String withTimeout(java.lang.String, int);
       0: iload_2
       1: lookupswitch  { // 2
                    -2: 46
                     0: 28
               default: 64
          }
      46: aload_0
      47: invokevirtual #377   // Method supportsSkipLocked:()Z
      50: ifeq          62
      53: aload_1
      54: invokedynamic #378   // makeConcatWithConstants:(Ljava/lang/String;)Ljava/lang/String;
      59: goto          63
      62: aload_1
      63: areturn
      64: aload_1              // default: the lock string UNCHANGED
      65: areturn
```

and

```
  public boolean supportsSkipLocked();
       0: iconst_1
       1: ireturn
  public boolean supportsWait();
       0: iconst_0
       1: ireturn
```

So `-2` is one of the two live cases and `supportsSkipLocked()` is hard `true`. This reproduces
`LockTimeoutHibernateJpaDialect.java`'s claim verbatim — *"compiles to a `lookupswitch` over exactly two
cases — `-2` (`SKIP_LOCKED`) and `0` (`NO_WAIT`) — and its `default` branch returns the lock string
**unchanged**"* — independently, from the bytecode rather than from the comment.

The route from a `PESSIMISTIC_WRITE` `LockOptions` into `withTimeout`:

```
  public java.lang.String getForUpdateString(java.lang.String, org.hibernate.LockOptions);
     …
     145: invokevirtual #274   // Method org/hibernate/LockOptions.getTimeOut:()I
     148: invokevirtual #276   // Method getWriteLockString:(Ljava/lang/String;I)Ljava/lang/String;
  public java.lang.String getWriteLockString(java.lang.String, int);
       3: invokevirtual #380   // Method getForUpdateString:(Ljava/lang/String;)Ljava/lang/String;
       7: invokevirtual #379   // Method withTimeout:(Ljava/lang/String;I)Ljava/lang/String;
```

`LockOptions.getTimeOut()` is passed straight in. So the hint value reaches the switch.

### 1b. The hint → `LockOptions` level

`org/hibernate/query/spi/AbstractCommonQueryContract.java` (sources jar, same version):

```java
			case HINT_SPEC_LOCK_TIMEOUT:
				if ( value != null ) {
					applyLockTimeoutHint( getInteger( value ) );
					return true;
				}
	…
	protected void applyLockTimeoutHint(int timeout) {
		getQueryOptions().getLockOptions().setTimeOut( timeout );
	}
```

`org/hibernate/jpa/internal/util/ConfigurationHelper.java`:

```java
	public static Integer getInteger(Object value) {
		if ( value instanceof Integer ) { return (Integer) value; }
		else { return Integer.valueOf( (String) value ); }
	}
```

`@QueryHint.value` is a `String`, so `"-2"` arrives as a `String` and `Integer.valueOf("-2")` handles it.
`LockOptions.java` declares `public static final int SKIP_LOCKED = -2;` and `setTimeOut` has no validation
beyond the `immutable` guard — it is a bare field assignment.

### 1c. Why SBDEV-3250's four hints were inert, and why this one is not

**The mechanism is the `default` branch, and it is value-dependent, not path-dependent.** The four removed
hints carried *positive millisecond* values. A positive int lands on `default: 64` → `aload_1; areturn` →
the lock string unchanged, and nothing anywhere else turns it into SQL
(`LockTimeoutHibernateJpaDialect.java`: *"the literal `lock_timeout` appears in **zero** hibernate-core
classes"*, with its own positive control). `-2` lands on a different branch of the same switch and is
translated into the lock STRING. Nothing about the inertness was about the hint plumbing, the
`@QueryHints` annotation, Spring Data, or the tenant EMF — all of that worked fine and still does. The
repo already states this correctly in two places, which is a second instrument agreeing with my
disassembly: `TenantDatabaseConfig.java` — *"the per-query `jakarta.persistence.lock.timeout` hint is
discarded by `PostgreSQLDialect` for every value except `0` and `-2`"* — and `StockunitRepository.java`
directly above the method being changed: *"PostgreSQLDialect.withTimeout translates only 0 (NO_WAIT) and
-2 (SKIP_LOCKED) and returns the lock string unchanged for every other value"*.

**So the design's highest-risk premise is sound, and SBDEV-3250 is positive evidence FOR it, not against
it.**

### 1d. Does anything on the tenant path strip or ignore query hints?

No, by two checks. (i) `git grep -n "repositoryBaseClass\|RepositoryFactoryBean"` over `src/main` returns
no hits that are repository-factory customisations — the ten hits are all `SimpleJpaRepository` mentions
inside javadoc prose. Spring Data's stock `AbstractJpaQuery.applyHints` therefore runs. (ii)
`TenantDatabaseConfig.tenantEntityManagerFactory` sets five vendor properties
(`hibernate.multiTenancy`, `hibernate.tenant_identifier_resolver`, `hibernate.dialect`,
`hibernate.hbm2ddl.auto`, `hibernate.temp.use_jdbc_metadata_defaults`) and seats a custom `JpaDialect`;
none of those touch query hints — `LockTimeoutHibernateJpaDialect` overrides only `beginTransaction`.
*Derivation: read of the whole `TenantDatabaseConfig.java` (168 lines) plus the whole
`LockTimeoutHibernateJpaDialect.java`. Blind spot: a `HibernatePropertiesCustomizer` or
`EntityManagerFactoryBuilderCustomizer` bean elsewhere would not be caught by reading these two files;
I did not sweep for one.*

### 1e. The "`spring.jpa.properties.*` never reaches the tenant PU" memory — does it matter here?

**Confirmed and irrelevant to this design.** `TenantDatabaseConfig.entityManagerFactoryBuilder` is
constructed with `new HashMap<>()` as its common-properties map, so `spring.jpa.properties.*` from
`application.properties` is not in the tenant PU's property map. That is exactly why the *fifth* inert
bound SBDEV-3250 names (*"a fifth was declared globally as
`spring.jpa.properties.jakarta.persistence.lock.timeout`"*) could never have worked. **But a
`@QueryHints` annotation is applied by Spring Data onto the `Query` object at execution time, not read
out of the PU property map** — the `AbstractCommonQueryContract` path in §1b is reached from
`Query.setHint`, not from PU bootstrap. So the empty vendor-property map is not a hazard for this design.
It *would* be a hazard for any attempt to set the hint globally; do not take that route.

---

## 2. Q2 — Interaction with SBDEV-3250's `SET LOCAL lock_timeout`

**Confirmed: `lock_timeout` cannot fire on a skip-locked acquisition.** PostgreSQL's `SKIP LOCKED` does
not enter the lock-wait queue at all — the row is filtered out of the result. `lock_timeout` bounds a
*wait*; there is no wait. `LockTimeoutHibernateJpaDialect` already records this for the one existing
skip-locked site: *"`OutboxMessageRepository.findAndClaimPending`, which is `SKIP LOCKED` and so never
waits."*

**What that means for the two paths — and this is an improvement, not a loss:**

The bound SBDEV-3250 added is **not a graceful yield**. When `lock_timeout` fires, PostgreSQL raises
`55P03`, which is a server-side statement ERROR, which aborts the whole transaction. The code says so
itself, in `ReplenishmentOrderMaintenanceService.recalculateForItem`: *"PostgreSQL puts the whole
transaction into an aborted state on ANY statement error: every subsequent statement then fails with
25P02"* — which is why that catch block rethrows anything carrying a `SQLException`
(`hasSqlCause`). So on the recalc path today, a 3-second wait on the target followed by a timeout
**poisons the entire `recalculateForItem` sweep for that item**, not just that one order. On the move
path it fails the operator's relocation (`StockUnitController` has a sibling handler for exactly this
shape: *"SBDEV-3622 O-4: a lock timeout (55P03) or deadlock (40P01) on the cut's lock spine is a refusal,
not a 500"*).

**Nothing depended on the removed wait.** The only consumer of the target lock is
`changeReservedAmount(targetStock, …)` immediately below it, whose own
`stockunitRepository.findByIdForUpdate(staleStockUnit.getId())` is then an upgrade on a row this
transaction already holds at `PESSIMISTIC_WRITE` → no new acquisition, no wait, no bound needed. And
`releaseHeld`/`cancelOrder` act on `currentSource`, which is held from `ensureValidSource`.

**So: on the descending edge, skip-locked replaces a bound that poisons the transaction when it fires
with a clean, in-band miss. That is strictly better, and it is the strongest argument for the design.**
The ascending edge keeps the `lock_timeout` bound unchanged, which is correct — there it is the backstop
of last resort for a wait that is already globally ordered and should never be long.

---

## 3. Q3 — Where the id comparison belongs, and whether F3 survives

### Minimal correct placement

**Immediately above the existing target lock, replacing this one line:**

```java
        Stockunit targetStock = stockunitRepository.findByIdForUpdate(candidate.stockUnitId).orElse(null);
```

Not earlier. Everything above that line in `redirectSource` either takes no lock at all or returns before
reaching one:

- `candidate == null` → `return false` — no lock.
- The SBDEV-3618 Fix E same-row branch → `replenishorderRepository.save(order)` and `return true`, locking
  no second stock unit (the row is `currentSource`, already held).
- `newRequested.compareTo(BigDecimal.ZERO) <= 0` → `return false` — no lock.

Moving the branch above any of those changes which path those cases take, for no benefit. The candidate
query `getAvailableReplenishmentSources` is a plain native SELECT and takes no lock, so the id is known
early and nothing forces the branch up.

### The null-source case the draft does not specify

`ensureValidSource` reads:

```java
        Stockunit source = order.getStockunitId() == null ? null
            : stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null);
```

`source` can be `null` for two reasons: a null `stockunitId`, or a `findByIdForUpdate` that found nothing.
**In both cases no stock-unit lock is held** — `FOR UPDATE` on a row that does not exist takes no lock.
`targetId > sourceId` has no defined value when there is no source, and the draft does not say. **It must
be: no current source ⇒ no descending edge ⇒ ordinary `findByIdForUpdate`.** This is not hypothetical —
`ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock` is built on exactly
that fixture (`when(stockunitRepository.findByIdForUpdate(SU_SRC)).thenReturn(Optional.empty());`) and
pins `inOrder.verify(stockunitRepository).findByIdForUpdate(candidateId);`. Get the null case wrong and
that test goes red for the wrong reason.

### Does SBDEV-3244 F3 survive?

**Yes, untouched.** F3 is a rule about `ensureValidSource`'s source read — *"load the source UNDER the
lock, as its FIRST touch in this transaction"* — and this change adds nothing above that read and does not
move it. The target-side invariant is F4 (*"the redirect target is written (changeReservedAmount) so it is
loaded under its lock too"*), and skip-locked is still a `PESSIMISTIC_WRITE` locking read: the row comes
back locked or not at all, so when it comes back it is still a first touch at `PESSIMISTIC_WRITE` and
`changeReservedAmount`'s own `findByIdForUpdate` is still a no-op upgrade. F4 survives.

### Does it trip `ReplenishmentFirstTouchInvariantUnitTest`?

**On the recalc path, no — but only by arithmetic, which is fragile.** In
`redirectSource_loadsTheTargetUnderItsLock` the source lock returns `Optional.empty()`, so the null-source
rule above applies and the plain finder is used; `candidateId = 99L` vs `SU_SRC = 20L` would also be
ascending if a source existed. Both routes keep `findByIdForUpdate(candidateId)`. **Green.**

The `verifyNoMoreInteractions(ignoreStubs(replenishorderRepository, stockunitRepository))` at the end of
that test is the thing to watch: adding a *new* `StockunitRepository` method and calling it on this path
would trip it unless the call is stubbed. On this fixture the new method is not called, so it stays green.

**The test that DOES break is on the move path — see §5.**

---

## 4. Q4 — Is ascending-id ordering the right primitive, given the descending edge is skip-locked?

**Keep the hybrid. Do not simplify to always-skip-locked.** Three reasons, one of them measured.

### 4a. Ascending-id is this repository's canonical stock-unit lock order, and `redirectSource` is the outlier

`git grep -n "ascending"` over `src/main/java/net/aim_ai/wms` (axis: the literal word, so it misses any
site that implements the order without saying so — a known under-count) returns **at least eight**
sites that assert ascending-id lock ordering as the house rule, including:

- `ReplenishorderService.java`, which performs **the identical operation** — re-sourcing a replenishment
  order — from the operator UI: *"// Ascending-id lock order (D7): closes the redirect-vs-redirect cycle
  X: A->B / Z: B->A."* followed by an explicit `if (oldStockUnitId != null && oldStockUnitId <
  newStockUnitId)` two-branch lock.
- `PickLineRealignmentService.java`: *"in ascending id order. This realizes the canonical lock order"*.
- `UnitloadBusinessService.java`: *"Locking ascending up front is the only way to guarantee a global
  ascending lock order across the tree"*.
- `MobileReplenishService.java`: *"lock {old SU} + the scanned SUs once, in ascending id order"*, with a
  `SortedSet<Long> lockIds = new TreeSet<>();`.
- plus `StockunitService`, `ReservationCut`, `BillofladingService`, `MobileTruckLoadingWriteService`.

**This widens the defect beyond what the `⚠ LOCK ORDERING` comment says.** The comment confines the
residual to *"two DIFFERENT orders"* on this same path. But `ReplenishorderService.redirectSource` locks
the same two kinds of row, for the same business reason, in ascending order, from a web request — so a
cron redirect and an operator redirect on the same `(A, B)` pair in opposite relative order is a *second*
cycle the comment does not name, and it needs no second cron. `MobileReplenishService`'s ascending set is
a third counterparty. An always-ascending maintenance path composes with all of them for free; a
skip-locked one merely declines to be the waiter on its own edge.

### 4b. Always-skip-locked would downgrade 82% of redirects for zero safety gain — measured

Measured on **`wsl-wineco-uat` / `wh01_om1_v2`**, the largest live v2 replenishment dataset (61,630
`replenishorder` rows, 570 at `state = 300`). For each PROCESSABLE order with a non-null `stockunit_id`, I
resolved the top candidate under the real eligibility predicate (`su.entity_lock = 0`, `ul.entity_lock =
0`, `loc.entity_lock = 0`, `area.entity_lock = 0`, `area.useforreplenish = true`, `s.amount >
reservedamount`) ordered by available descending:

| outcome | orders | share |
|---|---|---|
| no candidate at all → cancel path, no second lock | 144 | 25% |
| top candidate **is** the current source → SBDEV-3618 Fix E, **no second lock** | 97 | 17% |
| **ascending** edge (`target > source`) | 253 | 44% |
| **descending** edge (`target < source`) — the only rows needing skip-locked | **76** | **13%** |

Of the redirect attempts that take a second lock at all (329), **77% are ascending and 23% are
descending**. Always-skip-locked would convert the 253 ascending acquisitions from *"wait briefly, then
certainly succeed"* into *"succeed unless someone happens to hold the row right now"* — on an edge that is
already globally ordered and therefore already deadlock-free. A spurious defer there costs a full recalc
cadence (§7) and buys nothing.

*Derivation and its blind spots: one SQL query against `wsl-wineco-uat`, 2026-10-04. It approximates the
real comparator — `Comparator.comparing(c -> !Objects.equals(preferredAreaId, c.areaId)).thenComparing(
StockCandidate::getAvailable, reverseOrder())` — by dropping the preferred-area tiebreak, because
reconstructing `preferredAreaId` per order needs the source's unit load and location. Dropping it
reshuffles which candidate is top for items with sources in more than one replenishable area, so the
76/253 split is an estimate, not a count. It is also ONE tenant at ONE instant, and it is UAT. What it
does establish robustly is that the descending edge is **common, not exotic** — a looser query (does any
lower-id eligible candidate exist at all) returns 448 of 570 orders, 79%.*

### 4c. The argument FOR always-skip-locked, stated fairly, and why it loses

It is simpler: one lock method, one branch fewer, no `targetId`/`sourceId` comparison to get wrong, and it
removes the null-source edge case from §3 entirely. If the ascending edge really is free of contention,
the spurious-defer rate is near zero and the simplification is free.

It loses because the premise is unverifiable and the failure is silent. A spurious defer produces no
exception, no metric (nothing scrapes Prometheus here) and no operator-visible symptom — just an order
that quietly keeps an unusable source for another tick. You could not tell a 0.1% defer rate from a 10%
one without instrumenting for it. The hybrid keeps the common case deterministic, so there is nothing to
measure.

**Recommendation: hybrid, as drafted.**

---

## 5. Q5 — What the 3-way result breaks at the call sites

`redirectSource` is `private`. Callers, by `git grep -n "redirectSource" -- src/main` (axis: the literal
identifier; it is complete for Java callers here because the method is private and dispatch is neither
reflective nor proxy-mediated — blind to a future reflective caller, of which there is none today):

| caller | today | required mapping |
|---|---|---|
| `ensureValidSource` (recalc) | `if (redirectSource(order, source, share, true)) { …re-read…} cancelOrder(order, source, CANCELLED); return null;` | `REDIRECTED` → unchanged. `NO_CANDIDATE` → cancel + `return null`, unchanged. **`CONTENDED` → `return null` with NO cancel, NO write.** |
| `reassignOrCancelForMovedStockUnit` (move) | `if (!redirectSource(order, lockedSource, share, false)) { cancelOrder(order, lockedSource, CANCELLED); }` | `REDIRECTED` → unchanged. `NO_CANDIDATE` → cancel, unchanged. **`CONTENDED` → return, move proceeds.** |

### The SBDEV-2074 M5 interaction — this is a real trap

Today `redirectSource` returns `false` for **two** different things: "no candidate / target vanished /
`newRequested <= 0`", and "the reserve threw `FacadeException`". The second case has **already marked the
shared transaction rollback-only**, because `changeReservedAmount` is
`@Transactional(rollbackFor = FacadeException.class)` and joins this tx — the M5 comment spells out the
consequence: *"the outer commit will still surface `UnexpectedRollbackException` and roll the WHOLE unit —
for the move path that means the relocation is rejected (HTTP 422)"*.

**So the enum needs an invariant, stated in the code:**

> `CONTENDED` means *nothing was written and the transaction is NOT rollback-marked*. It is the only
> outcome a caller may treat as "carry on".

The `catch (FacadeException e)` arm must therefore map to **`NO_CANDIDATE`**, not `CONTENDED`. If it maps
to `CONTENDED`, the move path would "proceed" on a transaction that is already doomed, doing more work and
then failing at commit with a message further from the cause. This is the single easiest way to get the
3-way wrong, and the draft does not mention it.

### Tests that pin the boolean contract

Enumeration axis: `git grep -ln "redirectSource\|getAvailableReplenishmentSources" -- src/test` → 13
files. Blind spot: a test that drives this path without naming either symbol (e.g. through
`transferUnitLoadToLocation`) would be missed; `ReplenReassignOnNonReplenishableMoveIT` and
`MoveCronConcurrencyIT` are in the list, so the main ones are covered.

**The one that definitely breaks under "the move path always uses skip-locked":**

`src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceReassignTest.java`,
`reassignOrCancelForMovedStockUnit_shouldLockMovedStockBeforeShareAndBeforeCandidate_whenRedirecting`:

```java
        var lockOrder = inOrder(stockunitRepository, replenishorderRepository, stockunitBusinessService);
        lockOrder.verify(stockunitRepository).findByIdForUpdate(MOVED_STOCK_ID);
        lockOrder.verify(replenishorderRepository)
            .sumRequestedAmountOfOtherOpenOrdersOnStockunit(eq(MOVED_STOCK_ID), anyInt(), eq(ORDER_ID));
        lockOrder.verify(stockunitRepository).findByIdForUpdate(99L);
```

`MOVED_STOCK_ID = 42L`, candidate `99L` — an ascending pair, which under the draft is nonetheless routed to
skip-locked because it is the move path. The shared helper `stubRedirectSuccess` stubs
`findByIdForUpdate((Long) candidateRow[0])`, which would become an unused stub (it is `lenient()`, so no
`UnnecessaryStubbing` failure) while the real call goes to the new method and returns `Optional.empty()`
from the unstubbed mock → `CONTENDED` → no redirect → `assertThat(order.getStockunitId()).isEqualTo(99L)`
**fails**. Fixing it means re-pointing the stub and the `InOrder` row at the skip-locked method, i.e.
re-stating the SBDEV-3618 Fix D lock-order pin in the new vocabulary. That is correct work, not collateral
damage — but it must be in the plan, because it is the pin that proves Fix D still holds.

`ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock` stays green (§3).

`ReplenishmentOrderMaintenanceServiceUnitTest` (2,165 lines, 34 `findByIdForUpdate` references) and
`ReplenReassignOnNonReplenishableMoveIT` need a pass each; I did not read them line by line. **NOT
ESTABLISHED** which of their fixtures hit the target lock on the move path. Probe: `git grep -n
"findByIdForUpdate" src/test/java/net/aim_ai/wms/unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java`
and classify each by which of the two paths its fixture drives.

---

## 6. Q6 — Defer-on-move: what breaks?

### What the deferred state actually is

The move path is reached only when the destination is **non**-replenishable
(`if (isReplenishableDestination(destination)) { return; }` plus the same gate in
`ReplenishmentOrderSourceSyncService.syncForMovedStockUnit`). Under defer, nothing is written at all: the
order keeps `stockunitId` = the moved SU, keeps its reservation, and keeps its **old**
`requestedlocationId` — the replenishable location the SU just left. `isSourceUsable` has exactly this
predicate:

```java
        if (!locationId.equals(order.getRequestedlocationId())) {
            return false;
        }
```

so the next recalc tick sees the source as unusable and runs the ordinary redirect-or-cancel route. **The
self-healing path the product owner described is real and I verified it.**

### Who else reads that state — enumerated, with the method

Axis: the places that read `replenishorder.stockunit_id` or `stockunit.reservedamount` for a decision,
found by `git grep` on those symbols plus a read of the services named in the brief. Blind spot: SQL
views and Spring Data REST projections are not in that axis; a report screen reading a view would be
missed.

1. **SBDEV-2610 stranded-reservation reconciliation — SAFE, by construction.** Its predicate is
   `StockunitRepository.findStrandedReservationStockunitIds`: *"`AND NOT EXISTS (SELECT 1 FROM
   replenishorder r WHERE r.stockunit_id = su.id AND r.state < 700)`"*. A deferred order is `state = 300`
   and still points at the SU, so the SU is **not** stranded. `ReplenishmentReservationReconciliationService`
   additionally re-validates per row (`countStrandedReservationById`) immediately before mutating. It
   cannot release a deferred order's hold.
2. **Picking — unaffected.** Pick lines bind `pickingorder_position.pickfromstockunit_id`, a different
   FK; `PickLineRealignmentService.realignForMovedStockUnit` rewrites the label/location strings and
   explicitly never changes the stock unit (*"`pp.pickfromstockunitId` UNCHANGED (I-1)"*). The replen
   reservation reduces the SU's available amount for other consumers — a soft cost for one cadence, not a
   correctness break.
3. **Shipping / truck loading — cannot be the next step.** `PickLineActivityCodeClassifier` routes
   `CODE_SHIPPING`, `CODE_TRUCK_LOADING`, `CODE_PICKING`, `CODE_PACKAGING` and the receiving/putaway codes
   to `PASS_THROUGH`, and `UnitloadBusinessService.processTransfer` calls `syncForMovedStockUnit` **only**
   inside `if (… == Bucket.BLOCK_REALIGN)`. So the deferring path is reachable from exactly four activity
   codes: `CODE_MOVE_FIX_ASSIGNMENT`, `CODE_MANUAL_TRANSFER`, `CODE_TRANSFER`, `CODE_ON_HOLD`. *(Derivation:
   the two `Set.of(...)` literals in `PickLineActivityCodeClassifier`; unknown codes fail open to
   `PASS_THROUGH`. Blind spot: `PATCH /v3/stockunit/{id}` relocates inventory over Spring Data REST
   without going through this choke point at all — `UnitloadBusinessService`'s own javadoc says so,
   SBDEV-3017 Class A — but that route never called the replen sync either, so defer changes nothing
   there.)*
4. **The move's own caller — does NOT assume resolution.** `processTransfer` ignores the return (the
   method is `void`) and proceeds to `unitloadRecordService.recordForTransferUnitLoad` and the child
   recursion. The only thing it relies on is that no `BusinessException` is thrown — and the
   `state >= STARTED` guard that *does* throw runs **before** `redirectSource`, so defer cannot let a
   started replenishment's stock move. That guard is preserved.
5. **The amplification nobody has named: one move can defer N orders.** `processTransfer` loops
   `for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId()))` and then
   recurses into every child unit load. A pallet with 12 SKUs, each backing an active replen, is 12
   independent defer decisions in one transaction — and by the k-th the transaction already holds the
   order rows, moved SUs and redirect targets of the first k−1, which is precisely why ascending-from-here
   cannot be claimed on this path and the draft's point 3 is right.

### The real worst-case window

`REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` is **absent** on `wsl-wineco-uat` (the `los_sysprop` lookup
returns no row), so `getCadence()` falls through to
`SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_CADENCE_SECONDS_DEFAULT_VALUE = "0"` →
`shouldSkipForCadence()` returns `false` immediately → **the cadence gate is off**. The window is therefore
set by the job's own fire interval. `ReplenishOrderJob.deriveSpecForCurrentTenant()`:

```java
        return new TenantSchedule(TriggerSpec.of("20 " + minutes + " " + hours + " * * *", zone), zone);
```

with `REPLENISHMENT_TIMER_HOUR = '*'` and `REPLENISHMENT_TIMER_MINUTE = '*'` measured on
`wsl-wineco-uat` → `"20 * * * * *"` → **every minute, at second 20**. `REPLENISHMENT_TIMER_ACTIVATED =
'true'` and `NEW_CRON_JOB_ACTIVATED = 'true'`, so it is live.

**Worst case ≈ 60 s + one sweep duration**, extended if that occurrence is skipped by the JVM-wide
`RUNNING` guard or loses the per-tenant advisory lock. `MobileReplenishService` also calls
`recalculateOpenOrders(true)` (force, cadence-bypassing) on replenishment completion, and
`recalculateForItem` fires from `FixLocationAssignmentService`/`StockunitService.transferStock`, so in
practice it is usually much shorter. *I could not read the prd sysprops: `nywh-shipitez-prd` returns
"permission denied for table replenishorder" and `c1wh-shipitez-prd` "permission denied for table
los_sysprop"; both prd MCP endpoints resolve to `current_database() = 'wh01_hydra_v2'`, which looks like a
mislabelled entry.* **NOT ESTABLISHED on prd.** Probe: read `REPLENISHMENT_TIMER_{HOUR,MINUTE}` and
`REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` from `los_sysprop` on each prd tenant with a role that can
read it; if any tenant has set an hour/minute other than `*`, the window is that interval, not 60 s, and
the defer decision should be re-costed for that tenant.

### Verdict on defer-on-move

**Nothing breaks that I can find.** The one thing I would add to the plan: a `WARN` naming the order
number and the contended target id on every `CONTENDED`, on both paths. There is no counter and no state,
so a permanently contended target would defer forever with no symptom; a greppable line is the whole
mitigation and it costs one statement.

---

## 7. Q7 — Horizontal scalability (template §7 shape)

Load-bearing fact first: **the recalc cron DOES hold a distributed lock.** `ReplenishOrderJob` takes a
per-tenant two-key advisory lock on the **landlord** datasource —
`advisoryLockService.tryLock(AdvisoryLockService.JobLockId.REPLENISH_ORDER, tenantId)`, released in a
`finally`, at both the scheduled (`runFor`) and manual (`runForCurrentTenant`) entry points. So across N
replicas, at most one replica recalculates a given tenant at a time. **Cron-vs-cron contention on the
same tenant cannot happen across replicas**, which removes the `⚠` comment's own "two DIFFERENT orders"
scenario from the cron-vs-cron axis entirely. What remains unguarded is cron-vs-interactive (move,
mobile replenish, operator redirect) and `recalculateForItem` called from `StockunitService.transferStock`
/ `FixLocationAssignmentService`, neither of which takes the advisory lock.

| # | Concern | Verdict | One line |
|---|---|---|---|
| 1 | In-JVM state | **No** | The 3-way enum is a return value; no cache, static or `ThreadLocal` added. |
| 2 | Connection pool math | **No** | Same number of statements on the same tenant connection; skip-locked shortens the hold, never lengthens it. |
| 3 | Scheduled jobs | **No** | No job added or rescheduled; `ReplenishOrderJob` already holds `pg_try_advisory_lock(REPLENISH_ORDER, tenantId)` on the landlord pool. |
| 4 | Long transactions | **Improves** | Removes a wait of up to `wms.tenant.lock-timeout-ms` (default 3000) from the descending edge, so the move transaction's worst case shortens. |
| 5 | Request affinity | **N/A** | Nothing here is request-scoped or stateful across calls. |
| 6 | Retry / idempotency | **Yes — and it is satisfied** | `CONTENDED` is defined as "nothing written"; the retry is the next recalc tick, which recomputes from DB state. The §5 invariant (reserve-failure must NOT map to `CONTENDED`) is what makes this true. |
| 7 | Tenant context | **No** | No async boundary; everything runs on the caller's thread inside the tenant transaction. |
| 8 | Distributed lock correctness | **Yes — the point of the change** | Both finders stay inside `@Transactional("tenantTransactionManager")`; the ascending edge keeps the SBDEV-3250 bound, the descending edge replaces a transaction-poisoning 55P03 with an in-band miss. |
| 9 | Cache invalidation | **No** | `Stockunit`/`Replenishorder` are not Caffeine-cached on this path (no `@Cacheable` on either repository). |
| 10 | External notifications | **No** | No OMS/outbox write added; a deferred order emits no event, which is the same as today's "skip" outcome. |

**Does defer behave differently with N replicas?** Yes, and favourably: with the advisory lock, only one
replica's cron can be the deferrer for a tenant, so defers cannot pile up N-fold. The interactive paths
scale with request volume, not replica count.

---

## 8. Q8 — Rejected alternatives, re-examined on today's code

### (a) Unlocked source read — **rejection STANDS, and it is the strongest of the three**

It breaks SBDEV-3244 F3 outright. `ensureValidSource`'s own comment gives the mechanism — a plain finder
leaves the row at `EntityEntry` lock mode READ, making `changeReservedAmount`'s `findByIdForUpdate` a
version-checked **upgrade** that throws `StaleObjectStateException` from inside the locking call. It also
breaks AC-5: `share` and `desiredAmount` are computed from the source's `amount`/`reservedamount`, so a
pre-lock read converges on pre-winner numbers *even when nothing throws* — a silent wrong answer, which is
worse than the exception. Pinned by `ReplenishmentFirstTouchInvariantUnitTest`. Do not revisit.

### (b) Pre-query candidates and lock both ascending — **rejection STANDS, but the draft's reason is the weaker one**

The draft says it costs "an extra candidate query per order". True but incomplete. I checked whether the
query could be made cheap: `preferredAreaId` needs the source's `unitloadId`, and `RecalcContext` holds
`Map<Long, Unitload> unitloadsById` keyed by **unit-load** id, not by stock-unit id — `findUnitloadIdsByIdIn`
returns a bare `List<Long>` — so the context cannot resolve SU → UL and a scalar projection would have to be
added. That part is cheap and F3-safe (a scalar creates no `EntityEntry`; the repo already does this with
`findIdsByUnitloadIdAndItemdataIdOrderById`, *"ids only, so the … ascending `findByIdForUpdate` set is the
FIRST touch"*).

**The real reason it fails is sequencing, not cost.** To lock ascending you must know the target *before*
locking the source. But you only know whether you need a target at all after `isSourceUsable`, which needs
the source **entity** read under its lock. So you would have to run `getAvailableReplenishmentSources` for
**every** PROCESSABLE order every tick — 570 extra 4-table native joins per minute per tenant on WineCo
UAT, paid by the ~75% of orders whose source is fine — and you would be selecting the target from a read
taken *before* either row is locked, reintroducing exactly the pre-lock-decision staleness F3 exists to
eliminate. Caching the candidate set per item across the sweep does not rescue it: the set goes stale as
soon as one order in the sweep reserves from it.

So: true global ascending ordering is **structurally unavailable** on this path, and that is why a
skip-locked descending edge is the right answer rather than a compromise. The plan should say this, because
"an extra query" invites someone to argue the query is cheap.

### (c) NOWAIT — **rejection STANDS, and the reason should be strengthened**

`withTimeout(s, 0)` → `supportsNoWait()` → `iconst_1; ireturn` → `" … nowait"` (bytecode, §1a). PostgreSQL
then raises `55P03`, which is a **server-side statement error**, which aborts the transaction — not merely
rollback-only. `recalculateForItem`'s own SBDEV-3250 comment is the authority: *"PostgreSQL puts the whole
transaction into an aborted state on ANY statement error: every subsequent statement then fails with
25P02 … Swallowing therefore does not skip one order — it poisons the transaction."* Since `recalculateOrder`
is called there through a plain `this.`, a NOWAIT miss on **one** order kills the sweep for the whole item.
`SKIP LOCKED` is categorically different: no error is raised, the row is simply absent, and the transaction
stays usable. **That difference is the design's load-bearing property and deserves a sentence in the code,
not just in the plan** — it is the thing a future reader will try to "simplify" back to NOWAIT.

---

## 9. One thing the design does not fix, flagged rather than scoped in

`UnitloadBusinessService.processTransfer` iterates
`stockunitRepository.findByUnitloadId(unitload.getId())` — **no `ORDER BY`** — and locks each moved SU
plainly inside `reassignOrCancelForMovedStockUnit`. So a single move transaction acquires its *own* moved-SU
locks in unspecified order. Skip-locked on the **target** closes the move-vs-move cycle that runs through
targets, but not a cycle that runs through two transactions' moved-SU sets overlapping in opposite order
(possible when two carrier trees share descendants, or against `MobileReplenishService`'s ascending scanned
set). This is pre-existing, orthogonal, and out of SBDEV-3637's scope — but it means "the move path is now
deadlock-free" would be an overclaim. The honest claim is: **the move path no longer contributes the
target-acquisition edge.** Worth a sibling ticket (`ORDER BY s.id` on that finder is likely a one-line fix,
matching `findIdsByUnitloadIdAndItemdataIdOrderById`'s precedent), but propose it; do not fold it in.

---

## 10. Required changes (GO-WITH-CHANGES)

1. **Define the `CONTENDED` invariant in the enum's javadoc:** *nothing was written and the transaction is
   not rollback-marked*. Map the `catch (FacadeException e)` arm to `NO_CANDIDATE`, never `CONTENDED`
   (§5). This is the highest-value correction.
2. **Specify the null-source case:** no current source ⇒ no lock held ⇒ ordinary `findByIdForUpdate`
   (§3). `FOR UPDATE` on a missing row takes no lock, so there is no descending edge to avoid.
3. **Place the branch immediately above the existing target lock**, not earlier — the three earlier
   returns take no lock (§3).
4. **Re-point the SBDEV-3618 Fix D lock-order pin.**
   `ReplenishmentOrderMaintenanceServiceReassignTest.reassignOrCancelForMovedStockUnit_shouldLockMovedStockBeforeShareAndBeforeCandidate_whenRedirecting`
   verifies `findByIdForUpdate(99L)` on the move path and goes red; it must be rewritten against the
   skip-locked finder so Fix D stays pinned rather than un-pinned (§5).
5. **Add a `WARN` on every `CONTENDED`** naming the order number and the contended stock-unit id. There is
   no counter, no metric and no stranded-order detector; the log line is the only symptom a permanently
   contended target would ever produce (§6).
6. **Say in the code why `SKIP LOCKED` and not `NOWAIT`** — the 55P03-aborts-the-transaction asymmetry
   (§8c). Also delete the `⚠ LOCK ORDERING — NOT PROVED SAFE` block and replace it with what is now true,
   including the two counterparties the old block did not name (`ReplenishorderService.redirectSource`'s
   ascending D7 order, and `MobileReplenishService`'s ascending scanned set).
7. **State the honest scope** (§9): this closes the target-acquisition edge, not every deadlock on the move
   path.

**Optional, recommend as a follow-up not in this PR:** on `CONTENDED`, try the *next* candidate in the
already-materialised list instead of giving up at `findFirst()`. It costs no extra query and would convert
most defers into redirects. It changes the candidate-selection contract, so it wants its own test.

---

## 11. The single riskiest premise, and the cheapest probe

**It is no longer the `-2` hint.** That one is now established three ways (bytecode disassembly of
`PostgreSQLDialect.withTimeout`, the Hibernate source path from `HINT_SPEC_LOCK_TIMEOUT` to
`LockOptions.setTimeOut`, and two independent in-repo javadocs that already say the same thing).

**The riskiest premise is now the defer-window assumption: that a deferred order is resolved on the next
recalc tick, ~60 s later.** Everything in the product owner's decision rests on that window being short.
It rests on four conditions holding **per tenant**: `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` unset or
0, `REPLENISHMENT_TIMER_{HOUR,MINUTE}` both `*`, `REPLENISHMENT_TIMER_ACTIVATED = true`, and
`NEW_CRON_JOB_ACTIVATED = true`. I verified all four on **`wsl-wineco-uat` only**. On prd I was blocked —
both prd MCP endpoints report `current_database() = 'wh01_hydra_v2'` and the shipitez roles return
`permission denied` on `los_sysprop` and `replenishorder`. If any prd tenant has pinned the timer to a
specific hour (which the sysprops exist to allow, and which `ReplenishOrderJob`'s whole D′ conversion was
built around), the window is **hours**, and a replenishment order sitting for hours with a reservation on
stock that has physically moved to a transfer lane is a materially different decision from one sitting for
60 seconds. Note also the known cutover trap: `NEW_CRON_JOB_ACTIVATED = false` is the master gate for all
six cron jobs — a tenant in that state would never resolve a defer at all.

**Cheapest probe (one query, no code, ~2 minutes):** against each prd tenant DB with a role that can read
`los_sysprop`,

```sql
SELECT syskey, sysvalue FROM los_sysprop
 WHERE syskey IN ('REPLENISHMENT_RECALCULATION_CADENCE_SECONDS',
                  'REPLENISHMENT_TIMER_HOUR','REPLENISHMENT_TIMER_MINUTE',
                  'REPLENISHMENT_TIMER_ACTIVATED','NEW_CRON_JOB_ACTIVATED');
```

Pass condition: hour and minute both `*`, activated `true`, cadence absent or `0`, master gate `true`.
Any tenant that fails it needs the defer decision re-confirmed for that tenant before merge — or the plan
needs a bound that does not depend on the cron's cadence at all.

---

## 12. Supporting measurements (so they are not re-derived)

| fact | value | source |
|---|---|---|
| `replenishorder` rows / `state=300` | 61,630 / 570 | `wsl-wineco-uat`, `wh01_om1_v2`, 2026-10-04 |
| items with ≥2 active (`state<700`) orders | **0** | same |
| items with ≥2 active fix-location assignments | **0** (1,509 active FLAs, 1,509 distinct items) | same |
| partial unique indexes on `replenishorder` | `idx_replenishorder_active_item_dest` UNIQUE `(itemdata_id, destination_id) WHERE state<700`; `idx_replenishorder_active_item_no_dest` UNIQUE `(itemdata_id) WHERE state<700 AND destination_id IS NULL` | `pg_indexes`, present on `wsl-wineco-uat` **and** `nywh-hydra-prd` |
| `nywh-hydra-prd` replenishorder rows / `state=300` | 3 / 1 | `nywh-hydra-prd` |
| top-candidate edge split (570 PROCESSABLE orders) | 144 no candidate · 97 same-row · 253 ascending · 76 descending | `wsl-wineco-uat`, comparator approximated (see §4b blind spots) |

**A derivation worth keeping:** the `⚠` comment's cross-order scenario requires two active orders on the
**same itemdata**. A candidate for order *O* comes from `getAvailableReplenishmentSources` whose predicate
is `WHERE su.itemdata_id = :itemDataId`, and a stock unit carries one `itemdata_id`; so for *X*'s target to
be *Z*'s source, *X* and *Z* must share an item. The two partial unique indexes then permit that only when
the two orders have **different non-null `destination_id`s** — and destinations come from fix-location
assignments, of which no item has two active ones in the measured data. **The cross-order residual as the
comment states it has, on today's data, no population.** *Blind spots: one tenant, one instant, UAT;
`destination_id` can also be set by paths other than FLA alignment (I did not enumerate them); and this says
nothing about the cron-vs-`ReplenishorderService.redirectSource` and cron-vs-`MobileReplenishService` edges
in §4a, which need no second order and which the comment does not name.* That is the right reading of this
ticket: the residual the comment describes is nearly unpopulated, and the residual that actually matters is
one it does not describe.
