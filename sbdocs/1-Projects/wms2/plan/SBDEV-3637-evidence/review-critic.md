# SBDEV-3637 — CRITIC review (independent pass)

**Plan under review:** `sbdocs/1-Projects/wms2/plan/SBDEV-3637-replenish-redirect-lock-order.md` (r1)
**Code read:** `.claude/worktrees/wms2-api/SBDEV-3637-readonly`, detached at `ec42f43a` (confirmed:
`git log --oneline -1` → *"Merge pull request #453 from SiteBossInc/feature/SBDEV-2624-sku-rename-in-place"*).
**Reviewer:** ralplan critic lane. Read-only; no edits, no `mvn`, no HEAD change.
**Independence:** `review-architect.md` was present in the evidence directory and was **not** read.

**Verdict: ITERATE.** The design is sound in its core move — the descending edge genuinely cannot be
reordered, and declining to wait there is the right shape. But the plan's *safety argument for the
other half* (keeping the plain waiting finder on the ascending edge) rests on a completeness claim
that the code contradicts, and one of its seven mutants is equivalent. Six findings block.

---

## 1. What I verified and found correct

Stated first so the blocking list is not read as a general verdict on quality. Every item here I
resolved against the worktree, not against the plan's own evidence lanes.

| plan claim | probe | result |
|---|---|---|
| 17 `stockunitRepository.findByIdForUpdate` call sites | `git grep -n` + `git grep -c \| awk` sum | **17**, two instruments agree ✓ |
| `redirectSource(Replenishorder, Stockunit, Share, boolean)` already carries `recalcPath` and `currentSource` | read of the declaration | ✓ — Fix B needs **no signature change** to get its inputs |
| the ⚠ block ends *"acquire the two stock-unit locks in ascending id order and delete this comment"* | read | ✓ verbatim |
| §2.2 — the pipeline is `.map(this::mapCandidate).sorted(…).findFirst()` with no `.filter` | read of the stream expression | ✓ |
| §2.2 — `getAvailableReplenishmentSources` has no location predicate beyond the area flag and the lane flags | read of the native query | ✓ — `area.useforreplenish = true` and `(:excludeLanes = FALSE OR (loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE))`, nothing else locational |
| `ReplenishorderService.redirectSource` D7 ascending branch | read | ✓ verbatim: *"// Ascending-id lock order (D7): closes the redirect-vs-redirect cycle X: A->B / Z: B->A."* with `if (oldStockUnitId != null && oldStockUnitId < newStockUnitId)` |
| `MobileReplenishService` `TreeSet` ascending | read | ✓ `SortedSet<Long> lockIds = new TreeSet<>();` then the `for (Long id : lockIds)` lock loop |
| in-repo second instrument for the `-2` hint | `StockunitRepository` | ✓ *"PostgreSQLDialect.withTimeout translates only 0 (NO_WAIT) and -2 (SKIP_LOCKED) and returns the lock string unchanged for every other value"*; `LockTimeoutHibernateJpaDialect` carries the same statement plus the `lookupswitch` detail |
| `wms.tenant.lock-timeout-ms` = 10000 test / 3000 main | `git grep -rn` over both resource roots | ✓ `application-postgres-integration.properties:187` = 10000, `application.properties:119` = 3000 |
| both partial UNIQUE indexes exist in `db/migration` and in the onboarding schema | `git grep -n` | ✓ `V2.2.00__base_v2_schema.sql` and `V2.1.04__replenishorder_performance_indexes.sql` |
| `switchSourceToUnitLoad` is gone | `git grep` → exit 1, zero output; positive control `git grep -c redirectSource` returns hits in 5+ files | ✓ true absence, instrument working |
| `findByUnitloadId` has no `ORDER BY` and its sibling `findIdsByUnitloadIdAndItemdataIdOrderById` has one (P-1) | read | ✓ |
| §7.3 — `ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock` stays green | read of the test | ✓ confirmed: it stubs `when(stockunitRepository.findByIdForUpdate(SU_SRC)).thenReturn(Optional.empty())` and drives `recalculateForItem`, so `currentSource == null` routes it to the plain finder under `[arch-2]`. Its weakening comment is verbatim: *"finder is caught only IF NOBODY STUBS IT"* / *"If you tighten anything here, tighten the two weakened ones."* |
| §7.3 — U-11b's assertions | read | ✓ `lockOrder.verify(stockunitRepository).findByIdForUpdate(MOVED_STOCK_ID)` … `.findByIdForUpdate(99L)`, `MOVED_STOCK_ID = 42L` |
| Fix D — `CONTENDED → return null` is benign at the recalc caller | read of `recalculateOrder` | ✓ `Sourced sourced = ensureValidSource(order, ctx); if (sourced == null) { return; }` — no write, no cancel |
| AC-10 — skip-locked still returns the row **locked**, so `changeReservedAmount`'s own `findByIdForUpdate(staleStockUnit.getId())` stays a same-mode no-op | read of `StockunitBusinessService:509` | ✓ |
| every referenced existing test class resolves | `git ls-files` over 14 names | ✓ 12 resolve; the only two missing are the two the plan declares new |

**The three rejections are argued, not asserted, and all three are fair:**
- *NOWAIT* is rejected on a mechanism (`55P03` is a statement error → `25P02` poisons the whole
  transaction → the item sweep dies), sourced to an in-code comment. Strongest form.
- *pre-query-and-lock-both-ascending* is rejected on **sequencing**, not cost — you cannot know the
  target before `isSourceUsable` has read the source under its lock, and SBDEV-3244 F3 forbids the
  pre-lock read that would let you. The plan explicitly refuses the weaker "it's an extra query"
  framing. This is the single best-argued passage in the document.
- *always-skip-locked* is rejected on a **measured** number (77% of second locks are ascending) and
  its strongest form is stated first ("one lock method, one branch fewer"). The derivation's blind
  spots are named inline (one tenant, one instant, the `preferredAreaId` tiebreak dropped).

---

## 2. Blocking findings

### H1 — §0 derives 17 sites, tabulates 10, and the 7 dropped ones are not triaged

The §0 table has 11 rows but row 11 is a native query, not a `findByIdForUpdate` site. Mapping the
rows onto the grep:

| plan row | resolves to |
|---|---|
| 1, 2, 3 | `ReplenishmentOrderMaintenanceService` :424, :579, :256 |
| 4–7 | `ReplenishorderService` :259, :260, :262, :264 |
| 8 | `MobileReplenishService` :775 |
| 9 | `StockunitBusinessService` :202 (see **M4** — mislabelled) |
| 10 | `ReplenishorderService` :338 |

That is **10 of 17**. Not accounted for anywhere in the plan:

```
CustomerorderPositionService.java:148   findByIdForUpdate(pickingPosition.getPickfromstockunitId())
PickingorderBusinessService.java:566    findByIdForUpdate(sourceStockId)
StockunitBusinessService.java:277       destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)
StockunitBusinessService.java:472       findByIdForUpdate(staleStockUnit.getId())      // changeAmount
StockunitBusinessService.java:509       findByIdForUpdate(staleStockUnit.getId())      // changeReservedAmount
StockunitService.java:1060              findByIdForUpdate(stockUnitId)
MobileReplenishService.java:218         findByIdForUpdate(mobileOrder.getSourceStockId())
```

A table headed "Affected sites" that opens with a 17-site derivation and then prints 10 rows with no
"the other 7 were triaged out because …" line is a scope-shedding shape, not a judgement call. **Fix:**
either tabulate all 17 with an explicit out-of-scope verdict each, or state the filter that reduced
17 to 10 and show it is the filter you meant.

### H2 — `transferStockToUnitLoad` takes two Stockunit locks in ROLE order, and it is a live counterparty to the edge the fix deliberately leaves blocking

This is the one that matters. In `StockunitBusinessService.transferStockToUnitLoad` (declared at
`:178`):

```java
final Long sourceStockunitId = sourceStockunit.getId();
sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)        // :202  src SU
    .orElseThrow(() -> new BusinessException("Source stock unit " + sourceStockunitId + " not found"));
…
    final Long dstSuId = destinationStockUnit.getId();
    destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)         // :277  dst SU
        .orElseThrow(() -> new EntityNotFoundException("Stockunit", dstSuId));
```

Two `PESSIMISTIC_WRITE` Stockunit acquisitions, **src then dst, with no id comparison anywhere
between them** — the identical defect this ticket exists to close, in a method on the move choke
point, on stock units of the **same itemdata** (the dst SU is selected by
`stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())`). So it contends for exactly the
pairs the replenish recalc contends for.

Now take §4 Fix B's own case table, first row:

> `targetId > sourceId` (ascending), recalc path → **plain** `findByIdForUpdate` — *already globally
> ordered, therefore already deadlock-free*

Counter-example, both sides plain waits, both after the fix:
- recalc holds `S_low` (source, `:424`) and waits on `S_high` (target, `:579`) — ascending, plain.
- `transferStockToUnitLoad` holds `S_high` (src, `:202`) and waits on `S_low` (dst, `:277`).

ABBA. `40P01`. Unchanged by this fix.

"Already globally ordered, therefore already deadlock-free" is only true against counterparties that
are themselves id-ordered. The plan enumerates its counterparties as writer 2 (`ReplenishorderService`,
ascending) and writer 4 (`MobileReplenishService`, ascending) and reasons from those two. It never
asks whether the enumeration is complete, and it is not.

I am **not** saying the hybrid is the wrong design — the measured 77% argument survives this, because
the remedy for H2 is to id-order `transferStockToUnitLoad`'s pair (a separate, cheap change), not to
convert the ascending edge to skip-locked. What fails is the **claim**. **Fix:** either (a) name
`transferStockToUnitLoad` as a residual in AC-8 and in the Fix F replacement comment, and propose it
alongside P-1; or (b) fold the one-line id-ordering of `:202`/`:277` into this ticket. Until one of
those lands, the sentence "already globally ordered, therefore already deadlock-free" must not appear
in the plan or in the code.

### H3 — AC-8's "two pre-existing residuals" is a count claim with no derivation and it is wrong

> **"All Stockunit locks are id-ordered" is NOT assertable and no AC may assume it** — **two**
> pre-existing residuals block it, both named in §0

Good instinct (the plan correctly refuses the "all are id-ordered" claim), wrong execution: "two" is
itself an exactly-N completeness claim, carries no derivation method and no blind spots, and omits
the `transferStockToUnitLoad` pair from **H2** — and, separately, the 7 unexamined sites from **H1**.
This is precisely the pattern `prose-enumerations-rot` and `a-guard-fences-the-mechanism-you-aimed-at`
exist to catch. **Fix:** replace the count with the rule — *"the residual set is every site that takes
two or more Stockunit locks without comparing ids; derived by `git grep -n stockunitRepository.findByIdForUpdate`
over `src/main/java` plus a per-method read; blind spots: bulk `@Modifying` row locks, dirty-checked
flush UPDATEs, and locks taken through another repository's join query"* — and then list what that
rule currently returns.

### H4 — `holdsLowerSourceLock`'s name and javadoc are inverted relative to its body

```java
/** true when this transaction already holds a lock on a stock unit whose id is BELOW the target's. */
private static boolean holdsLowerSourceLock(Stockunit currentSource, Long targetId) {
    return currentSource != null && currentSource.getId() > targetId;
}
```

The body returns true when the held source is **above** the target — the descending edge, which is
correct for the intent (that is the edge that must not wait). The javadoc says the opposite. The
method name says the opposite. Both branches of the ternary then read backwards to anyone who trusts
the doc.

This is not cosmetic: the call site is `(!recalcPath || holdsLowerSourceLock(…)) ? skipLocked : plain`,
so a future reader who "corrects" the body to match the documented contract inverts the entire fix —
ascending edges start deferring spuriously (the silent failure mode R-3 names) and the descending edge
goes back to blocking. No proposed test or mutant detects a doc/name/body disagreement. **Fix:** rename
to `targetIsBelowHeldSource` (or `holdsHigherSourceLock`) and rewrite the javadoc to match the body.

### H5 — M-6 is an equivalent mutant; U-C cannot kill it

> **M-6** | flip `>` to `>=` in `holdsLowerSourceLock` | U-C (the same-row case must not reach either finder)

`>` and `>=` differ only at `sourceId == targetId`. That case **never reaches the comparison**. In
`redirectSource`, before the target-lock line:

```java
if (currentSource != null && Objects.equals(candidate.stockUnitId, currentSource.getId())) {
    if (!recalcPath) {
        return false;
    }
    …
    replenishorderRepository.save(order);
    return true;
}
```

Both paths return. `holdsLowerSourceLock` is therefore only ever evaluated with `candidate.stockUnitId
!= currentSource.getId()`, so the mutant is behaviourally identical to the original and PIT will report
it SURVIVED forever. U-C asserts that neither finder is called a second time in the same-row case —
true under `>` **and** under `>=`, because the Fix E branch returns first. U-C grades the Fix E return,
not the comparison operator.

§7.5's own warning (*"M-6's fixture must include an equal-id row"*) does not rescue it: no reachable
fixture can put an equal-id row at that line. **Fix:** drop M-6 and replace it with a reachable boundary
mutant — e.g. `>` → `<` (inverts the branch; dies at U-A *and* U-B with attributable messages), and add
an off-by-one pair `sourceId = targetId + 1` / `sourceId = targetId - 1` to the U-A/U-B fixtures so the
boundary is exercised from both sides.

### H6 — `AbstractReplenishRedirectPgFixture` cannot build §7.2's fixture, and §5 does not list it as modified

§7.1 claims the fixture *"already builds the shape this fix needs"*. It does not. Its two seeding
helpers are **private** and hard-code the values §7.2 needs to vary:

```java
private void area(long id, String name) {
    jdbcTemplate.update(
        "INSERT INTO location_area (… useforpicking, useforreplenish, "
            + "useforstorage, usefortransfer, usefordeepstorage, client_id, entity_lock, created, modified) "
            + "VALUES (?, 0, ?, false, false, true, true, true, true, false, ?, 0, now(), now())",
        id, name, CLIENT);
}

private void location(long id, String name, long areaId, Long rackId, long typeId) {
    jdbcTemplate.update(
        "INSERT INTO location (… staginglane, transferlane, automationlane, crossdockinglane, gate, …) "
            + "VALUES (?, 0, 0, 0, 0, ?, ?, ?, ?, ?, false, false, false, false, false, 0, now(), now())",
        …);
}
```

Every area it can create is `useforreplenish = true`; every location it can create has
`staginglane = false, transferlane = false`. §7.2 requires `AREA_LANE (useforreplenish = false)` with
two lanes `LANE_1`, `LANE_2` — the move destinations, without which
`reassignOrCancelForMovedStockUnit` returns at its first guard (`isReplenishableDestination(destination)
→ return;`) and the IT is vacuous rather than red.

So the new IT must either (a) modify the base class — make `area`/`location` protected and
parameterise `useforreplenish`, which touches four existing subclasses (`ManualCutCooldownEndToEndIT`,
`ReplenishmentHeldShareIT`, `ReplenishorderRedirectSourceIT`, `ReservationCutAttributionIT`) — or
(b) issue its own `jdbcTemplate.update` inserts and take on the `wipe()` ordering itself. §5's file
change summary lists neither; `AbstractReplenishRedirectPgFixture.java` does not appear in it at all.

**Fix:** decide (a) or (b), list the file in §5, and if (a), add a §7.3 row stating that the four
existing subclasses are expected green and why.

---

## 3. Non-blocking findings

### M1 — §7.1 and §7.2 contradict each other on raw JDBC lock holders

§7.1: *"Do **not** drive locks through a raw `JdbcTemplate`"*, with the reason (an autocommit
`DriverManagerDataSource` releases a `SELECT … FOR UPDATE` lock at statement end, and two sibling ITs
already have that defect).

§7.2 IT-2: *"park a **raw JDBC holder** on the target row"*.

If IT-2's holder is autocommit, the lock is gone before the worker reaches the skip-locked read, the
worker succeeds, and IT-2 asserts `CONTENDED` against a row nobody holds — a green that proves
nothing. **Fix:** state IT-2's holder explicitly (`Connection` with `setAutoCommit(false)`, held open
across a `CyclicBarrier`, closed in a `finally`), or reuse the `TransactionTemplate(tenantTransactionManager)`
holder the IT-1 choreography already uses. One sentence.

### M2 — AC-11 is false as written and is itself ungradeable

> **AC-11** Every new assertion is mutation-checked with an attributable kill. — *§7.5 M-1 … M-7*

§7.5 has 7 mutants. The plan introduces roughly 19 new assertions (U-A…U-I = 9, IT-1a…IT-1e = 5,
IT-2, IT-3a/b/c = 3, IT-4). Assertions with **no** named mutant: U-I (the WARN), IT-3a (the positive
control), IT-2 (the `backend_xid` probe — the plan's own "only assertion that distinguishes ordered
from happened-not-to-deadlock"), IT-4 (starvation), and U-A's stated killer ("always-skip-locked")
never appears as an M-row. **Fix:** either add the missing rows or narrow AC-11 to the assertions
§7.5 actually covers and say which are covered by construction instead.

### M3 — Fix C conflates "the skip-locked finder missed" with "the row vanished"

§4 Fix C maps *"`targetStock == null` from the **skip-locked** finder → `CONTENDED`"*. But
`SELECT … FOR UPDATE SKIP LOCKED` returns zero rows for **two** reasons: the row is locked, or the row
is not there. On the move path the skip-locked finder is used unconditionally, so a candidate deleted
between the candidate query and the lock is reported `CONTENDED` and **deferred forever** instead of
`NO_CANDIDATE` → cancelled. The observable symptom is a repeating `SBDEV-3637 REDIRECT_CONTENDED` on
the same order+target pair — which is exactly the live-lock signature §7.6's manual plan tells the
operator to investigate, so the two conditions are indistinguishable in production too.

Probability is low (the candidate came from a query moments earlier in the same transaction), but the
plan presents the mapping as clean and it is not. **Fix:** either disambiguate after a skip-locked miss
(`stockunitRepository.existsById(candidate.stockUnitId)`, non-locking, one cheap statement, only on the
miss path) or state the conflation in the `RedirectOutcome` javadoc and in Fix E's WARN so the operator
knows a permanent CONTENDED can mean a vanished row.

### M4 — §0 row 9's citation does not resolve to the named method

Row 9 reads `service/StockunitBusinessService.java · changeReservedAmount —
sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)`.

The quoted snippet is `StockunitBusinessService:202`, which is inside **`transferStockToUnitLoad`**
(declared `:178`). `changeReservedAmount` is declared at `:508` and its locking read is
`findByIdForUpdate(staleStockUnit.getId())` at `:509`. §3 quotes the *correct* snippet for
`changeReservedAmount` (*"`findByIdForUpdate(staleStockUnit.getId())` then `entityManager.refresh`"*),
so the plan has both forms and merged them into one row.

This is not a typo with no consequence — it is the mechanism by which **H2** got lost. Labelling
`transferStockToUnitLoad`'s first SU lock as "changeReservedAmount, a re-lock no-op on a row this
transaction already holds" is precisely what removes it from consideration as an independent
two-lock acquirer.

### M5 — `pg_stat_database.deadlocks = 0` has no control in the environment it was measured in

The plan says the reading *"is only meaningful because `PostgresDeadlockDetectorControlIT` is the
standing positive control that the counter is not inert on the pinned `postgres:14-alpine`."* That IT
controls the **test lane**. It says nothing about whether the counter is live on `wsl-wineco-uat`,
`nywh-hydra-prd` or `nywh-hydra-uat`. Separately, `pg_stat_database.deadlocks` is cumulative since
`stats_reset`, and the plan does not report `stats_reset` for any of the three — a 0 after a recent
reset or a recent restart is indistinguishable from a true zero. **Fix:** add `stats_reset` to the §1
table (one extra column in the same query), and say plainly that the in-lane control does not transfer
to the live servers.

### M6 — the severity argument overstates what the unique indexes bound

§0: *"Two UNIQUE partial indexes … cap the number of active same-item orders"*, and §2.3 shape 4 calls
recalc × recalc reachable only through *"a two-active-orders-per-item configuration, which the unique
indexes restrict."*

`idx_replenishorder_active_item_dest` is `(itemdata_id, destination_id) WHERE (state < 700)` (verified
in `V2.2.00__base_v2_schema.sql`). It caps active same-item orders **per destination** — N distinct
destinations permit N active orders for one item. The repo's own test proves it:
`ReplenishorderRedirectSourceIT:379` seeds `replen(ORDER_Y, Y_NUMBER, SU_B, LOC_B, LOC_DEST_Y, …)`
alongside ORDER_X on `LOC_DEST`, same `ITEM`, both `state = 300`. The plan even relies on this in §7.2
(*"two distinct destinations are **mandatory**"*) — so the two sections contradict each other on what
the index means. **Fix:** in §0 and §2.3, state the cap as per-destination, and let the measured zero
stand on its own as a measurement (three tenants, one instant) rather than borrowing structural force
it does not have.

### M7 — three alternatives absent, one of them already proven in this repo

- **Native `FOR UPDATE SKIP LOCKED`.** `OutboxMessageRepository` already does this, literally
  (`FOR UPDATE SKIP LOCKED` in the query text), pinned by `OutboxLaneClaimIT`'s
  `.contains("FOR UPDATE SKIP LOCKED")`. That route needs no dialect disassembly, no `@QueryHints`
  plumbing argument, and no `HibernatePropertiesCustomizer` blind spot (§4 Fix A names that blind spot
  and then has to spend AC-2/IT-3c closing it). The `-2` hint is probably still the right call — JPQL
  keeps the H2 lanes parsing (§9 v2-only #4) and the entity comes back managed at the right lock mode —
  but a plan that spends a paragraph on `javap` output while never naming the working in-repo
  precedent has not represented the alternative at its strongest.
- **Catch `40P01` and retry the order.** Close to today's behaviour on `recalculateOpenOrders` ("logs
  and skips"). Not named.
- **Do nothing.** The plan's own §0 verdict is LOW severity, zero measured ≥2-order items, zero
  measured deadlocks, no production occurrence. It never weighs that against a T3's cost. A critic
  pass has to say: the plan's strongest evidence points at the cheapest option it never considers.
  I think the fix is still worth doing (a topology defect at a choke point is worth closing while the
  context is loaded), but the plan should argue that rather than assume it.

### M8 — the replacement comment would install a false claim where the old one stood

Fix B's drafted comment opens:

> `// Ascending-id lock order: matches ReplenishorderService.redirectSource's D7 branch and`
> `// MobileReplenishService's TreeSet.`

This is not an ascending-id lock order. D7 genuinely reorders the two acquisitions; the `TreeSet`
genuinely sorts. Fix B keeps role order and makes the inverting edge non-blocking — a different and
weaker property, which the plan elsewhere explains well (*"True global ascending ordering is
structurally unavailable on this path"*). Writing "matches D7" into the code puts a false equivalence
at the exact site the old ⚠ block occupied, and the old block's whole lesson was that three successive
attempts to argue this path safe were each wrong. **Fix:** open the replacement with what is true —
*"Role-ordered acquisition retained; the inverting edge declines to wait instead of reordering,
because the source lock is already held and SBDEV-3244 F3 forbids reading it unlocked."*

### M9 — a declared floor deviation, undeclared

The floor requires one failing test first, failing for the right reason. §6.2 step 1 gives that for the
ABBA (IT-1c expecting `40P01` pre-fix) — good. But it also says `StockunitSkipLockedIT` *"cannot compile
before Fix A"* and should be landed in step 2, so **AC-2 has no red-first**. That may be unavoidable,
but it should be stated as a deviation with a substitute, not buried in a parenthetical. **Fix:** write
IT-3b/IT-3c against `findByIdForUpdate` first, watch them fail (it waits; the SQL has no `skip locked`),
then re-point them at the new finder. That is a genuine red-first for Fix A and it costs one commit.

### M10 — IT-1e passes for an implementation that does nothing on the move path

Under the pre-seize choreography, post-fix **both** sides hit a contended target and **both** defer. So
IT-1e's *"both moves commit, and neither order is `CANCELED` — each is `PROCESSABLE`, either redirected
or deferred with its original source"* is satisfied by a mutant that returns `CONTENDED`
unconditionally on the move path. The kill for that mutant exists — `ReplenReassignOnNonReplenishableMoveIT`
AC2 (the redirect-succeeds case) — but the plan never names it. **Fix:** add an M-row *"make the move
path always return CONTENDED → `ReplenReassignOnNonReplenishableMoveIT` AC2 goes red"*, and tighten
IT-1e to assert the specific post-state each order is in rather than a disjunction.

---

## 4. Low

- **L1** — §7.1: *"SBDEV-3637 becomes its fourth subclass."* `git grep -ln AbstractReplenishRedirectPgFixture`
  returns four existing subclasses (`ManualCutCooldownEndToEndIT`, `ReplenishmentHeldShareIT`,
  `ReplenishorderRedirectSourceIT`, `ReservationCutAttributionIT`) plus the fixture itself and
  `TestClassTransactionManagerArchTest` (a reference, not a subclass). It would be the **fifth**.
- **L2** — §7.2 names `AREA_REPLEN / LOC_1 / LOC_2 / AREA_LANE / LANE_1 / LANE_2 / UL_1 / UL_2 / S1 / S2 /
  O1 / O2`. The inherited fixture uses `AREA_A / AREA_B / LOC_A / LOC_B / LOC_C / LOC_DEST / LOC_DEST_Y /
  UL_A / UL_B / SU_A / SU_B / SU_C / ORDER_X / ORDER_Y`. An executor following §7.2 literally will end up
  with two naming schemes in one class. Restate §7.2 in the inherited vocabulary (`SU_A = 9990 < SU_B = 9991`
  already gives the low/high pair the test needs).
- **L3** — M-3 ("set `wms.tenant.lock-timeout-ms=500` in the lane") is a properties-file mutant, not a PIT
  mutant, and it mutates the lane for every IT in it. Worse, at `lock_timeout 500 < deadlock_timeout 1000`
  **both** sides time out, so IT-1b (`hasSize(1)`) fails first with *"expected size 1 but was 2"* — a
  non-attributable message — before IT-1c's SQLSTATE assertion is reached. Label M-3 manual and state
  that IT-1b is expected to fail first, or scope the timeout change to one transaction.
- **L4** — `holdsLowerSourceLock(currentSource, candidate.stockUnitId)` unboxes `candidate.stockUnitId`
  at `currentSource.getId() > targetId`. The guard above null-checks `candidate`, not
  `candidate.stockUnitId`. The inline comment *"unboxing compare, both non-null here"* is asserted, not
  derived. One sentence naming why `mapCandidate`'s `toLong(row[0])` cannot be null would settle it.
- **L5** — P-6 describes `StockunitBusinessService.transferStock` as taking *"src-SU → src-UL → src-location
  → dst-UL → dst-SU → dst-location"* and frames the hazard as *"may form a cycle through `Location`"*. The
  code takes src-SU (`:202`) → dst-SU (`:277`) → dst-Location (`:281`): there is a **direct SU→SU
  role-ordered pair**, no Location needed. See **H2**.

---

## 5. Answers to the five enforcement questions

1. **Principle–option consistency** — **FAILS on one clause.** The principle ("match the three sibling
   writers' ascending discipline") does not select the chosen option, which is not ascending at all; the
   plan knows this and argues it well in the pre-query rejection, but then re-asserts the ascending
   framing in Fix B's comment (**M8**) and in the case table's safety claim (**H2**). The option is right;
   two of its stated justifications are not.
2. **Fair alternatives** — **mostly PASS.** The three named rejections are all argued at strength
   (NOWAIT on `25P02`, pre-query on sequencing, always-skip-locked on a measurement with its blind spots
   declared). Three alternatives are missing entirely (**M7**), one of which is already working in this
   repo.
3. **Risk mitigation clarity** — **PASS.** R-1 through R-6 each carry a checkable action: R-1 a named SQL
   probe with pass criteria, R-2 the §7.3 rewrite rows plus a stop rule, R-3 U-A as a regression pin, R-4
   U-H + M-4, R-5 a sequencing decision, R-6 AC-8. None is a reassurance. R-1 correctly states its own
   blind spot (both ShipItEZ prd roles denied).
4. **Testable acceptance criteria** — **FAILS on two.** AC-11 is not gradeable (**M2**). AC-8 is written as
   a limit, which is the right instinct, but its "two residuals" is a false count (**H3**). AC-5's IT-1e
   leg is satisfiable by a do-nothing move path (**M10**). AC-1/2/3/4/6/7/9/10/12/13 each map to a named
   test and are gradeable.
5. **Concrete verification steps (the floor)** — **PASS with one undeclared deviation.** DB query ✓
   (three tenants, two denied, stated). Failing test first ✓ for the ABBA, ✗ for Fix A (**M9**). Mutation
   with attributable kills — partially (**H5**, **M2**). Independent review ✓ (this lane). Full suite vs an
   adjacent baseline ✓, with the flaky-IT rerun rule carried.

**Overclaiming check.** The plan is unusually disciplined here — most completeness words carry a
derivation and a blind spot inline, and it explicitly refuses both of the two claims the brief warned
about ("the move path becomes deadlock-free", "all Stockunit locks are id-ordered"). The violations I
found are: *"two pre-existing residuals"* (**H3**), *"already globally ordered, therefore already
deadlock-free"* (**H2**), *"Re-source writers … three, not four"* (a count that is sound on its own axis
but inherits **H1**'s incompleteness), and *"its fourth subclass"* (**L1**).

**Zero-result controls.** The 0-items-with-≥2-orders and 0-deadlocks readings both carry the
three-tenant caveat and the ShipItEZ `permission denied` note, in the frontmatter, in §1, and again in
R-1 — correctly repeated at each point of use. The `deadlocks` control is in the wrong environment
(**M5**), and the indexes do less structural work than claimed (**M6**).

**Does the concurrency test prove what it claims?** Yes, uniquely well — IT-2's `backend_xid` probe is
genuinely the only mechanism in the plan that distinguishes "ordered correctly" from "happened not to
deadlock", the plan says so in those words, and `MoveUnitloadLockOrderProbeIT` really does carry that
mechanism (*"a NULL `backend_xid` while blocked means no row lock or write came before"*). IT-1b's
`hasSize(1)` with its stated derivation (both failing = serialised elsewhere; neither = vacuous) is the
right anti-vacuity guard. The one hole is IT-2's holder (**M1**).

**Scope honesty.** P-1 through P-6 are genuine follow-ups, each with blast radius and cost, and the plan
names P-1 as the one it would do first and as *"the other half of making the move path's claim true"* —
that is honest. The one piece of quiet shedding is **H1**/**H2**: `transferStockToUnitLoad` is the same
defect class as the ticket, in scope by any reading of "affected sites", and it is neither tabled nor
proposed.

---

## VERDICT

ITERATE

**Blocking (must clear before the TDD gate):**

1. **H1 (High)** — §0 tabulates 10 of the 17 sites its own derivation returns. *Clear by:* tabulating all
   17 with a per-site in/out verdict, or stating the filter that reduces 17 to 10.
2. **H2 (High)** — `StockunitBusinessService.transferStockToUnitLoad` takes src-SU (`:202`) then dst-SU
   (`:277`) in role order and is a live ABBA counterparty to the ascending edge the fix leaves blocking,
   which falsifies *"already globally ordered, therefore already deadlock-free"*. *Clear by:* deleting
   that justification and naming the residual in AC-8 + Fix F, **or** folding the one-line id-ordering of
   `:202`/`:277` into this ticket.
3. **H3 (High)** — AC-8's *"two pre-existing residuals"* is an uncontrolled count and is wrong. *Clear by:*
   replacing the count with the derivation rule plus its blind spots, then listing what the rule returns.
4. **H4 (High)** — `holdsLowerSourceLock`'s name and javadoc are inverted relative to its body; nothing
   tests a doc/body disagreement and "correcting" the body inverts the fix. *Clear by:* renaming to
   `targetIsBelowHeldSource` and rewriting the javadoc to match `currentSource.getId() > targetId`.
5. **H5 (High)** — M-6 is an equivalent mutant: `>` vs `>=` is unreachable because the equal-id case
   returns at the SBDEV-3618 Fix E branch, and U-C grades that return, not the operator. *Clear by:*
   replacing M-6 with `>` → `<` (dies at U-A and U-B) and adding `sourceId = targetId ± 1` rows to the
   U-A/U-B fixtures.
6. **H6 (High)** — `AbstractReplenishRedirectPgFixture`'s `area()` and `location()` are private and
   hard-code `useforreplenish = true` / no lanes, so §7.2's fixture is not buildable and §5 omits the file.
   *Clear by:* choosing base-class modification (and listing the four existing subclasses as expected
   green in §7.3) or local inserts, and listing the file in §5.

**Non-blocking, worth fixing in the same pass:** M1 (IT-2's raw JDBC holder vs §7.1's own prohibition),
M2 (AC-11 covers ~7 of ~19 assertions), M3 (skip-locked miss conflates contended with vanished),
M4 (§0 row 9 cites `transferStockToUnitLoad:202` under the label `changeReservedAmount`),
M5 (`deadlocks = 0` control is in the test lane, and `stats_reset` is unreported),
M6 (the unique index caps per **destination**, not per item), M7 (native `FOR UPDATE SKIP LOCKED`,
retry-on-40P01, and do-nothing are unrepresented), M8 (the replacement comment's "matches D7" is false),
M9 (AC-2 has no red-first; declare it and give the substitute), M10 (IT-1e passes for a do-nothing move
path).

**Low:** L1 (fifth subclass, not fourth), L2 (§7.2's parallel naming scheme), L3 (M-3 is a manual
lane-wide mutant and IT-1b fails first non-attributably), L4 (`candidate.stockUnitId` unboxing asserted
not derived), L5 (P-6 mischaracterises the transferStock pair as a cycle through `Location`).

**Not re-litigated, per the brief:** D1 (CONTENDED defers on both paths). I checked what breaks under
defer and found three things worth saying, none of which argues for cancel: M3 (a vanished row defers
forever and is indistinguishable from contention), M10 (the IT as written cannot tell defer from
do-nothing), and the observation — which the plan already makes at P-3 — that trying the next candidate
instead of giving up at `findFirst()` is the natural mitigation and is deliberately out of this PR.
