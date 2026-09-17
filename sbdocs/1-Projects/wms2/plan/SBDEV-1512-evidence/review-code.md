# SBDEV-1512 Phase 1 — code review (correctness · concurrency · maintainability)

**Lane:** code quality only. Plan conformance is graded elsewhere and is not assessed here.
**Tree reviewed:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1512`, 4 commits
(`e8bcbbe3`, `6bf54176`, `17a9f062`, `5136ed87`) off `origin/develop` @ `4bef7e77`.
Diff base `git diff origin/develop...HEAD` — 13 files, +1175/−26.

**Instruments run (not just read):**

All Maven below ran in a **dedicated worktree**,
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1512-codereview`, detached at the
same commit `5136ed87` (`git diff 5136ed87 --stat` → empty, working tree clean). No other build was
running: `pgrep -af "[m]aven|[s]urefire"` was empty of builds at start. This matters because
concurrent Maven in one worktree produces false reds in this repo, and an earlier pass of this
review was run in the shared tree while other lanes were building — **those numbers are discarded
and none of them is cited here.**

- `mvn -o clean test -Dtest='AdviceRestControllerUnitTest,ReturnAdviceAutoReceiveServiceUnitTest,DamagedReturnApiSurfaceContractUnitTest,ReceivingControllerUnitTest' -Dsurefire.failIfNoSpecifiedTests=false`
  → **Tests run: 181, Failures: 0, Errors: 0, Skipped: 0. BUILD SUCCESS.**
  `clean` is deliberate — without it `mvn test` will happily run stale classes left in
  `target/test-classes`. Comma selector, not `+`: a `+` matches nothing and leaves the previous
  run's surefire XML in place, which reads as a verdict for code that never ran.
  The run includes `AdviceRestControllerUnitTest$DamagedQuantity` (4/4) and
  `DamagedReturnApiSurfaceContractUnitTest` (4/4), the two new unit surfaces.
- Compilation of `src/main` is covered by the above (it compiles before surefire).
- Two claims below are proven by **executing** Java rather than reading it — see M1 and L2. Both were
  run standalone via `java P.java` on JDK 21.0.11-ms and do not depend on the build at all.
- **Not run:** the Postgres IT lane (`ReturnAdviceAutoReceiveIntegrationTest`,
  `AdvicePositionDamagedColumnsIntegrationTest`). Those were read, not executed. Every statement
  below about them is about their *source*, never about a pass/fail I observed.
- **What a green here does and does not prove.** It proves the 181 existing + new unit assertions
  hold. It says nothing about the untested paths in H1 — a passing suite is exactly what you get
  when the code under discussion is never reached, which is the finding.

**Overall.** The production logic is correct as far as I can falsify it, the reuse of
`setLockDamaged` is the right call for the reason given, and the two-loop ordering is sound. The
defect is not in what the code does — it is that the half of the change the author's own comments
call "load-bearing" is asserted by nothing, and one arithmetic edge on an unauthenticated endpoint.

---

## HIGH

### H1 — The entire failure/recovery half of this change is untested; six named mutations survive

The DAMAGE_FAILED path is where all the new judgement lives, and it is graded by zero tests.

Census — `grep -rn "DAMAGE_FAILED\|damageFailed\|applyDamage\|stampDamageApplied" src/test/java`
returns **one** hit, and it is a comment, not an assertion:

```
src/test/java/net/aim_ai/wms/integration/ReturnAdviceAutoReceiveIntegrationTest.java:441:
    + "succeed outright; DAMAGE_FAILED here means setLockDamaged threw")
```

The other two hits the grep returns are false positives in unrelated files (`LockOverviewViewIT`'s
`UNITLOAD = 9603L`, and a `260331` comment in `ReplenishmentOrderMaintenanceServiceUnitTest`).
Method of this census: literal-name grep over `src/test/java`. **Blind spot:** it would miss a test
that reaches the path without naming it — so I cross-checked with a second instrument below, which
agrees.

Second instrument. `ReturnAdviceAutoReceiveServiceUnitTest` now injects two new mocks:

```java
    @Mock
    private StockunitService stockunitService;

    @Mock
    private StockunitRepository stockunitRepository;
```

Neither is referenced by any test — no `when(...)`, no `verify(...)`. That is not visible as a
failure because Mockito's strict stubs police unused *stubbings*, not unused *mocks*. The mechanism:
**every** `ResolvedLine` / `AutoReceiveLine` the suite constructs passes `damagedAmount = 0` (the
diff changes 6 construction sites and every one appends a literal `0`), so
`if (line.damagedAmount() <= 0) continue;` skips the whole damage loop in every unit test that
reaches `executeInternal`.

Mutations that survive the full 181-test green run:

| # | Mutation | Why nothing catches it |
|---|---|---|
| 1 | Delete `self.markFinished(plan.adviceId())` reachability on the damage-failure path (return early instead) | No test drives a damage failure |
| 2 | In `applyDamage`, replace the null/empty `throw` with `return` | No test drives an empty id list |
| 3 | Move `self.stampDamageApplied(...)` to *before* `setLockDamaged` | The one test that asserts `damageappliedat IS NOT NULL` is the success path, where both orders stamp |
| 4 | Reorder `damageFailed(...)`'s args to `(adviceNumber, sku, total, correlationId)` | Nothing renders code 603; an operator would read `received all SKU position(s) ... sku '2'` |
| 5 | Change `case DAMAGE_FAILED ->` in `getErrorCodeName` to fall through to the generic name | Nothing reads the 603 name |
| 6 | In `resolveRefs`, delete the `rawDamaged < 0` throw, or revert the cap to `getAmountOfBottles()` | `setAmountOfBottlesDamaged` appears in **no** `ReturnAdviceAutoReceiveServiceUnitTest` test (`grep -rn setAmountOfBottlesDamaged src/test/java` → 3 files, none of them that one); the existing cap rows at `:910`/`:922` still set only `setAmountOfBottles(100_001)` / `(100_000)`, which with `damaged = null → 0` grade exactly what they graded before the change |

Mutation 4 matters more than it looks, because the code's own comment on `damageFailed` says the
arity is "load-bearing" and that a wrong call "would ship a literal `%4s` to an unauthenticated
caller" — and then nothing asserts the arity or the order. That is the shape the lead warned about:
a comment standing in for evidence.

**Cost to close:** small. Four `ReturnAdviceAutoReceiveServiceUnitTest` rows cover 1–5 with the
existing mocks (stub `stockunitService.setLockDamaged` to throw, assert `status() == DAMAGE_FAILED`,
`received() == total()`, `verify(adviceRepository).updateAdviceToStateById(FINISHED, ...)`, and
`assertThat(outcome.description()).contains(adviceNumber, sku, correlationId)` with
`.doesNotContain("%")`). Two `resolveRefs` rows cover 6.

---

## MEDIUM

### M1 — `int` overflow lets an unauthenticated caller persist a **negative** `notifiedamount`

`AdviceRestController` (position save loop, `create`):

```java
                    if (advicePosition.getAmountOfBottles() < 0) {
                        throw new WebserviceBusinessExceptionClientSide(WmsConstants.FIELD_MALFORMED_FORMAT, null,"amount_of_bottles", advicePosition);
                    }
                    ...
                    if (advicePosition.getAmountOfBottlesDamaged() != null
                            && advicePosition.getAmountOfBottlesDamaged() < 0) {
```
```java
                    int damaged = rawDamaged == null ? 0 : rawDamaged;
                    position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles() + damaged));
```

Both guards are per-field and sign-only; the controller has no magnitude cap. The sum is `int`.
Executed, not reasoned (`java P.java`, JDK 21.0.11-ms):

```
int sum = -294967296
BigDecimal = -294967296
```

with `amount_of_bottles = 2000000000`, `amount_of_bottles_damaged = 2000000000` — each of which
passes its own `>= 0` check.

**This is new.** Before this change the line was
`position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles()))` after the `< 0`
check, so `notifiedamount` could be absurdly large but was *always* non-negative. It can now be
negative.

**Reachability.** `resolveRefs`' `MAX_UNITS_PER_POSITION` cap does not cover this, because
`validate(adviceDto)` runs at `AdviceRestController:318` only `if (autoReceive)` and the save loop
runs unconditionally. The reachable shapes are exactly the ones the author's own comment enumerates
as the reason this validation belongs here — a REGULAR advice, and a RETURN on a tenant with
`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED = false`. That comment claims this tier "is the floor"
against "an arbitrary value straight into `notifiedamount`, which feeds `SUM(ap.notifiedamount) as
qtyRequired` and `orderedbottles`". It floors the sign of each operand, not of the sum.

Secondary effect: `ReceivingService.receiveGoods` compares against
`adviceposition.getNotifiedamount().intValue()` in its over-delivery guard, so a negative value
makes the position permanently un-receivable by the dock path too.

I am *not* claiming a realistic OMS caller sends this; `permitAll()` on `/rest/advice/create` with
the tenant taken from an unauthenticated header is what makes it worth a line of code.

**Fix (one line):** widen before the check —
`long total = (long) advicePosition.getAmountOfBottles() + damaged;` then reject
`total < 0 || total > MAX_UNITS_PER_POSITION` (or `Math.addExact` inside a try). Note `resolveRefs`
is *not* exposed, and for a good reason worth recording: its `totalAmount < 1` guard catches the
overflow, because the wrap of two non-negative `int`s can only land in `[-2^31, -2]` — never a small
positive. That is luck, not design, and it does not protect the controller.

### M2 — `applyDamage` silently damages only the first stock unit of a multi-case receive, then stamps it as done

```java
        Long stockunitId = createdStockunitIds.get(0);
```

guarded only by the null/empty check above it. Correct **today** — the one call site passes
`amountCases = 1` (`receivingService.receiveGoods(line.advicePositionId(), null, false,
line.amount(), line.amount(), 1, line.boxtypeId(), plan.printer())`) — but the new `receiveGoods`
javadoc explicitly advertises the opposite contract: *"the list has `amountCases` entries for a
multi-case receive"*. So the method's declared contract and its single consumer's assumption
disagree, and nothing enforces the assumption.

The failure mode if they ever diverge is the bad kind: entries `1..n` go undamaged, `setLockDamaged`
returns normally, `stampDamageApplied` runs, and the position is stamped — which **removes it from
the recovery worklist forever**. A partial damage is then indistinguishable from a complete one.
`applyDamage`'s own comment already argues that silently skipping damage "would be the failure mode
this whole feature exists to remove"; this is that failure mode one `amountCases` change away.

**Fix:** make the assumption an assertion —
`if (createdStockunitIds.size() != 1) throw new BusinessException(...)` — same shape and same cost
as the null/empty guard directly above it.

### M3 — A receive failure leaves damage outstanding with no signal that distinguishes it

The two-loop ordering (Q1) is correct and I would not change it — see the Answers section. But its
stated cost is only half-mitigated. When position `k` fails to receive, `executeInternal` returns
`AutoReceiveOutcome.partial(...)` and increments `wms2.returns.autoreceive.partial_failure` — the
**pre-existing** counter, shared with every return that carries no damaged quantity at all. The new
`wms2.returns.autoreceive.damage_failed` counter fires only for a failure *inside* the damage loop,
which this case never reaches. The PARTIAL log line names `failedSku` and `received`, and says
nothing about damage.

So on the path the code comment singles out as the ordering's real cost, the only discovery route is
someone independently deciding to run
`SELECT ... WHERE notifieddamagedamount > 0 AND damageappliedat IS NULL`. Nothing schedules it,
nothing gauges it, nothing mentions it in the operator-facing warning. (Per this repo's standing
context, nothing scrapes Prometheus yet either, so a counter alone would not be a control — but a
flag in the PARTIAL log line would be.)

**Fix (cheap):** add `damagePending={}` to the PARTIAL `LOG.error`, computed as
`plan.lines().stream().anyMatch(l -> l.damagedAmount() > 0)`. One argument, and it turns a silent
state into a greppable one.

---

## LOW

### L1 — Javadoc placed *between* the annotation and the declaration is not javadoc

`ReceivingService`:

```java
    @Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
    /**
     * SBDEV-1512: returns the ids of the {@link Stockunit}s this call created, in creation order.
```

A doc comment must precede the *entire* declaration, annotations included. In this position the
javadoc tool treats it as an ordinary comment and drops it, and most IDE hovers do the same. The
18-line "why a return value / why source-compatible" rationale — which is the most useful prose in
the diff — is invisible everywhere except the file itself. Move the block above `@Transactional`.

### L2 — `%1s` is not positional in Java; it is a width specifier

`WmsConstants`, the new 603 template:

```java
                description = "return advice '%1s' received all %2s position(s) but could not lock the "
                    + "damaged quantity on sku '%3s'; the advice is complete and the damage move is "
                    + "outstanding (correlationId %4s)";
```

Positional is `%N$s`. Executed:

```
[return advice 'ADV-1' received all  1 position(s) sku 'SKU' (correlationId uuid-here)]
```

— note the double space before `1`: `%2s` pads to a minimum width of 2. The rendering is otherwise
correct **only because the arguments happen to be supplied in the same order as the digits**. The
siblings (601 `RETURN_AUTO_RECEIVE_PARTIAL`, 602 `RETURN_AUTO_RECEIVE_ABORTED`) use the same idiom,
so this is house style rather than a regression, and I am not asking for a sweep. What I would fix
is the new entry's comment, which reasons about `%4s` as though it were an index ("a wrong-arity
call site ships a literal `%4s`"): that belief is what eventually produces a genuinely misordered
message, and it is the belief that makes mutation 4 in H1 invisible. Use `%1$s`…`%4$s` here.

### L3 — T1.18 claims three paths and tests two

`AdviceRestControllerUnitTest$DamagedQuantity`:

```java
    @DisplayName("T1.18 — a negative damaged quantity is rejected on all three paths that skip resolveRefs")
```

with javadoc *"Each of these three shapes reaches the write without ever entering `resolveRefs`"*.
The body covers `(1) REGULAR advice` and `(2) RETURN advice on a tenant with
RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED = false`. There is no `(3)`.

The third shape — a RETURN with an empty positions list — is *vacuous*, not omitted by oversight: a
position-level field cannot be validated when there are no positions. So the right fix is the words,
not a third case. As written the display name is a completeness claim that the test does not carry,
which is exactly what a later reader will trust instead of re-deriving.

### L4 — Two test files name migration `V2.2.31`; the migration that shipped is `V2.2.32`

`AdvicePositionDamagedColumnsIntegrationTest` — class javadoc (*"the two nullable columns the plan's
`V2.2.31` migration must add"*) and both `@DisplayName`s (`"V2.2.31 adds notifieddamagedamount…"`,
`"V2.2.31 adds damageappliedat…"`). The file on disk is
`src/main/resources/db/migration/V2.2.32__adviceposition_notified_damaged_amount.sql`. The test
asserts against `information_schema`, not against a version, so it stays green while pointing at a
filename that does not exist — the kind of stale pointer that costs someone twenty minutes during
an incident.

### L5 — Literal `103` where `WmsConstants.BusinessObjectLockState.QUALITY_FAULT` exists

`ReturnAdviceAutoReceiveIntegrationTest`:

```java
                + "WHERE su.itemdata_id = ? AND su.entity_lock = 103", ITEMDATA);
```

plus `entity_lock = 0` for the sellable query and `103` again in the `@DisplayName`. The constant is
the same one `moveStockToNewDamagedContainer` writes
(`damagedStock.setEntityLock(WmsConstants.BusinessObjectLockState.QUALITY_FAULT)`). The test's
comment argues the literal is deliberate because `stock_view.damaged` hardcodes `103` — a fair
point for the *value*, but it can still be interpolated so a future constant change fails loudly
here rather than silently grading the wrong lock. Repo rule: no magic numbers where `WmsConstants`
has one.

### L6 — A damage that actually succeeded can be reported to the caller as "could not lock the damaged quantity"

`applyDamage` calls `self.stampDamageApplied(...)` as its last statement, in a separate transaction
(correctly annotated — see Q4). The comment documents the *crash* window between the two. It does
not cover the *throw* window: if `setLockDamaged` commits and `stampDamageApplied` then throws
(deadlock, lock timeout, connection loss), the exception unwinds into the damage-loop catch and the
caller receives code 603 — "could not lock the damaged quantity on sku X" — for stock that **is**
locked. The worklist then also lists a position that needs nothing.

Self-correcting rather than dangerous, because the runbook has to verify current damaged stock
before acting anyway (which the code says, and which is the right instruction). Worth one added
clause in the comment so the next reader knows the message can be wrong in this direction, and worth
noting that no runbook for this worklist is present in this diff.

### L7 — Fully-qualified types inline where the file imports everything else

`ReturnAdviceAutoReceiveService`: `new java.math.BigDecimal(line.damagedAmount())` and
`position.setDamageappliedat(java.time.LocalDateTime.now())`. Every other type in the class is
imported. `ReturnAdviceAutoReceiveIntegrationTest` does the same with `java.math.BigDecimal` in five
places, and `ReceivingControllerUnitTest` with `java.util.List.of()` in three. Cosmetic, but it is
the tell of an edit made without touching the import block.

### L8 — `stampDamageApplied` declares `rollbackFor` for exceptions it cannot throw

```java
    @Transactional(value = "tenantTransactionManager",
        rollbackFor = {BusinessException.class, FacadeException.class})
    public void stampDamageApplied(Long advicePositionId) {
```

The method declares no checked exceptions and its body (`findById().ifPresent(save)`) throws
neither. Copied from siblings where the attribute is load-bearing. Harmless at runtime; it costs a
reader a search for the checked path that justifies it. (The `value =` half **is** required and
correct — see Q4.)

Also in that method: `.ifPresent(...)` silently no-ops if the position has vanished, leaving
`damageappliedat` null and the position on the worklist forever. Unreachable in practice (the row
was written moments earlier in the same request) and failing open is the right default here, so I
am recording it, not asking for a change.

---

## Answers to the eight questions

**1. Two-loop ordering — sound?** Yes, and I would not change it. `executeInternal` is entered with
no transaction (`execute` is deliberately non-`@Transactional`; class javadoc and `:624`), and
`receiveGoods` is `@Transactional` per call, so each position commits independently. A per-position
interleave therefore really would leave an OPEN advice with some stock at `entity_lock = 103`, and
the dock re-receive that follows really would double it. *Is the claimed recovery sufficient?* In
the database, yes — `notifieddamagedamount` is written by the controller's save loop **before**
`execute` is ever called, so the column is on the row no matter where the receive died, and the
worklist finds positions `1..k-1` exactly. What is *not* sufficient is discovery: nothing signals
that a PARTIAL had damage outstanding (M3).

**2. `applyDamage` throwing on a null/empty id list — right call?** Right call. Failing loud beats
silently dropping the damage, which is the defect the feature exists to remove. And it is **not** a
new failure mode on the `permitAll()` endpoint: the throw is caught two frames up by
`catch (BusinessException | FacadeException | RuntimeException e)`, converted to
`AutoReceiveOutcome.damageFailed(...)`, and the caller-facing `description` is built from the
sanitised 603 template — **never** from `e`. I checked specifically for exception-derived data
crossing `/rest/**`: the only place `e` is used is `LOG.error(..., e)`. Clean. The narrower problem
is M2 — the guard checks emptiness but not the size the caller actually assumes.

**3. `DAMAGE_FAILED` running `markFinished` — safe? Can an operator get stuck?** Safe, and the
reasoning holds: all `N` positions received, so leaving the advice OPEN is the double-receive
hazard. The operator is **not** stuck — recovery is the manual "Transfer To Damaged" row action
(`StockUnitController.transferToDamaged`, `@RequiresFunction(WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)`),
which operates on a stock-unit id and does not care about advice state. Nothing about FINISHED
blocks it. Untested, though (H1, mutation 1).

**4. `stampDamageApplied` in a separate transaction — documenting sufficient? Annotation correct?**
The annotation is correct and both halves matter: `adviceposition` is a tenant entity, and
`landlordTransactionManager` is `@Primary`, so a bare `@Transactional` would bind the wrong
datasource. Public + `self.` is right too — a private `@Transactional` gets no advice at all.
Documenting the window is *nearly* sufficient: at-least-once with a verify-first runbook is a
reasonable trade for a two-column change. Two gaps: the throw direction is undocumented and produces
a *wrong message* rather than just a stale flag (L6), and the runbook the comment depends on is not
in this diff.

**5. `void → List<Long>` — correct? All exits covered? Caller identical?** Correct.
`receiveGoods` has exactly **one** `return` (`return createdStockunitIds;`) and 12 `throw`s between
`:317` and `:640` — method: `awk` over that range piped to `grep -n "return\|throw new"`; blind
spot: a `return` inside a lambda would be missed, and none of the 12 is one. `createdStockunitIds.add(stockUnit.getId())`
sits immediately after `createStockUnit` **inside** the per-case loop, so a multi-case receive
genuinely yields `amountCases` entries in creation order. `ReceivingController` is unchanged and
behaves identically — Java discards return values. The three `doNothing()` → `doReturn(List.of())`
edits in `ReceivingControllerUnitTest` are the minimum required and change no assertion. Compiles
clean; 181 tests green.

**6. Cap moved to the total — verify. Does `R15`'s `< 1` on the total weaken anything?** The stated
reason is correct: with the cap on `getAmountOfBottles()` alone, `100_000 + 100_000` would receive
200_000 units against a 100_000 cap, because `receiveGoods` is called with `line.amount()`, which is
now the total. Moving it is right. `R15` does not weaken: the only newly-accepted shape is
(0 undamaged, N damaged), which is a genuine N-unit line; and the overflow case still lands `< 1`
because a wrapped sum of two non-negative `int`s is always in `[-2^31, -2]`. Both changes are
**untested** (H1, mutation 6) — the existing `100_001` / `100_000` rows still exercise only the
undamaged field.

**7. Concurrency / lock ordering.** No new problem. `executeInternal` holds no transaction, so
`setLockDamaged` is entered from outside one — byte-for-byte the same shape as the existing manual
path, `StockUnitController.transferToDamaged`, which likewise does
`stockunitRepository.findById(...)` outside a transaction and then calls it. Atomicity still lives
entirely in `moveStockToNewDamagedContainer`, whose `locationRepository.findByIdForUpdate(...)`
remains its **first** statement (verified in `UnitloadService`, unchanged by this diff), so the D3
ordering invariant is intact and no caller-held lock can invert against it. The detached
`Stockunit` handed to `setLockDamaged` matches the existing caller exactly, so no new merge/version
hazard. On connection hold: with `spring.jpa.open-in-view=false` and no outer transaction, each
`@Transactional` unit borrows and returns its own connection, so the request now takes roughly `3N`
short borrows where it took `N` — more churn, no sustained hold. Benign.

**8. Test quality — are the assertions real?**
`AdviceRestControllerUnitTest$DamagedQuantity`: **real**, all four. T1.17 would go red on a deleted
ternary (unboxing NPE ⇒ not `NO_CONTENT`) and pins the deliberate null/0 asymmetry. D6-A uses 7+3
rather than 5+5, so an undamaged/damaged swap is visible. T1.18 asserts `BAD_REQUEST` on two paths
that genuinely bypass `resolveRefs`, and `verify(returnAdviceAutoReceiveService, never()).validate(any())`
confirms the bypass rather than assuming it. I could not construct a broken implementation of the
controller arithmetic that passes them.
`ReturnAdviceAutoReceiveIntegrationTest.mixedReturn_...` (source read; **not executed** by me):
strong by construction. It grades `entity_lock = 103` as primary and location as explicitly
secondary — the right axis, since `stock_view.damaged` never reads the location name. It asserts the
locked amount is **3**, not 10 and not 7, which kills the `damagedAmount`/`amount` swap. It asserts
the 7-unit remainder stays at `entity_lock = 0`. It grades the `stockrecord` DAMAGED axis as a
**sum delta**, which correctly survives the `withReuse(true)` container leaving rows behind — a trap
this repo has been bitten by, handled here properly. And it asserts `damageappliedat IS NOT NULL`.
My one reservation is scope, not rigour: it is one scenario, the happy path, and the assertions
carry the whole feature. The gap is H1 — everything this test does not reach.

---

## What I would fix first

**H1** — write the four DAMAGE_FAILED unit rows plus the two `resolveRefs` rows. It is under an
hour with mocks that are already injected, and it is the only finding here that changes whether the
next person can safely edit this code. **M1** is the one-line fix I would land in the same commit.
