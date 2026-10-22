# SBDEV-1512 — second review pass over the fixes (`5136ed87..e01bce85`)

**Scope:** the three fix commits only — `89b444b2` (5 HIGHs), `ebb6bb5f` (3 Mediums + 8 Lows),
`e01bce85` (7 PIT gaps). Everything at or below `5136ed87` treated as settled.

**Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1512-rereview`,
detached at `e01bce85`. All mutation probes were applied by copying the file to the scratchpad
first and restoring from that copy; `git status --porcelain` is empty at the end of this review, so
the tree is byte-identical to `e01bce85`. No `git checkout --` / `restore` / `stash` was run.

---

## Verdict: **PASS-WITH-FINDINGS**

The production fixes are correct. I found no defect in `src/main` introduced by these three commits.
Specifically, the two items the lead flagged as previously missed — the F1 `continue` and the F2
pre-flight — are genuinely present **and** genuinely pinned: I reverted each one and the named test
went red.

**No existing assertion was deleted or loosened**, with one exception (M-2 below) that is a real
weakening.

*Derivation:* `git diff 5136ed87..e01bce85 -- src/test/ | grep '^-' | grep -v '^---'` returns exactly
6 removed lines — 3 javadoc/`@DisplayName` version strings, 2 SQL literals, 1 constructor argument
list. *Blind spots:* this catches deletions and in-place modifications but not a weak assertion
added alongside a strong one, and not a behaviour change smuggled into a shared helper. I checked
the helpers separately: every helper the new tests use (`planWithDamagedLines`, `receivedStockunit`,
`validReturnDtoWithDamaged`) is a new addition, and the pre-existing ones the new tests call
(`returnDtoWithPositions`, `stubResolvableItemAndBox`, `printer`, `arrange`, `capturePosition`)
have no `-` line in the scope diff.

The findings are all in the **test layer**: one newly-added assertion is vacuous (proven by a
surviving mutant), two fixes shipped with no test at all, and one integration-test assertion was
weakened by the literal→constant swap.

---

## Findings

### M-1 · Medium — T1.19's "must NOT be stamped" assertion is vacuous; the stamp-the-attempt defect survives it

**File:** `src/test/java/net/aim_ai/wms/unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java`,
`applyDamage_failure_returnsDamageFailedAndStillFinishes`

```java
        // and the position must NOT be stamped, or the recovery worklist loses it forever
        verify(advicepositionRepository, never()).save(any());
```

**What is wrong.** This test stubs `receivingService.receiveGoods`, `stockunitRepository.findById`
and `stockunitService.setLockDamaged`, but it never stubs `advicepositionRepository.findById`.
Mockito therefore returns `Optional.empty()`, and `stampDamageApplied`'s body —

```java
        advicepositionRepository.findById(advicePositionId).ifPresent(position -> {
            position.setDamageappliedat(java.time.LocalDateTime.now());
            advicepositionRepository.save(position);
        });
```

— no-ops. `save` is unreachable *in this test* whether or not the stamp was called, so the negative
verify can never fail. It is the "negative assertion on a fixture nobody wrote" shape. The three
sibling damage tests all stub `findById`; this one does not.

**Measured, not argued.** MUTANT-C1b rewrote `applyDamage` to stamp the **attempt** rather than the
success — `setLockDamaged` wrapped in `try`, `self.stampDamageApplied(...)` moved into a `finally`,
the original success-only stamp block deleted. That is verbatim the defect the surrounding comment
says the column exists to prevent ("stamping the ATTEMPT would make that worklist silently miss
every real failure"). Result: `ReturnAdviceAutoReceiveServiceUnitTest` **72 run, 0 failures,
BUILD SUCCESS**. The mutant survived.

**Failure scenario.** A later refactor moves the stamp into a `finally` (a natural-looking
"always record the attempt" cleanup). Every damage failure now writes `damageappliedat`. The
recovery worklist is `notifieddamagedamount > 0 AND damageappliedat IS NULL`, so it returns zero
rows for every real failure. The damaged units stay at `entity_lock = 0`, sellable, and nothing
ever points an operator at them — the exact silent loss SBDEV-1512 exists to remove. The suite
stays green.

**Fix.** Add the stub the siblings already have, so the assertion becomes live:

```java
        when(advicepositionRepository.findById(anyLong())).thenReturn(Optional.of(new Adviceposition()));
```

then re-run MUTANT-C1b and confirm it goes red.

---

### M-2 · Medium — replacing the `entity_lock = 103` literal with the constant dropped the only cross-check against `stock_view`

**File:** `src/test/java/net/aim_ai/wms/integration/ReturnAdviceAutoReceiveIntegrationTest.java`,
`mixedReturn_receivesTotalAndLocksDamagedPortion`

```java
-                + "WHERE su.itemdata_id = ? AND su.entity_lock = 103", ITEMDATA);
+                + "WHERE su.itemdata_id = ? AND su.entity_lock = ?", ITEMDATA,
+            WmsConstants.BusinessObjectLockState.QUALITY_FAULT);
```

**What is wrong.** `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql`, inside
`CREATE OR REPLACE VIEW public.stock_view`, hardcodes the literal:

```sql
            WHEN ((su.entity_lock = 103) OR (ul.entity_lock = 103)) THEN su.amount
        END) AS damaged,
```

`applyDamage`'s own javadoc names `stock_view.damaged` as one of the three surfaces this feature
must satisfy. Before the swap, the test pinned the Java-produced row against the same literal the
view matches on — a genuine cross-check between two independently-maintained artefacts. After the
swap both sides of that check read `WmsConstants.BusinessObjectLockState.QUALITY_FAULT`, so a
change to the constant is invisible to the test. The assertion message still says "(103)", which is
now prose rather than a check.

**Failure scenario.** Someone renumbers `QUALITY_FAULT` (say to deconflict with a new lock state).
The whole Java suite, including this integration test, stays green. The view still tests `= 103`,
so `stock_view.damaged` returns 0 for every auto-received damaged return and the client's damaged
report is empty — the original SBDEV-1512 symptom, re-landed under a green suite.

**Fix.** Keep the constant in the query (it reads better), and add the pin it replaced:

```java
        assertThat(WmsConstants.BusinessObjectLockState.QUALITY_FAULT)
            .as("stock_view.damaged in V2.2.00__base_v2_schema.sql hardcodes 103; if this constant "
                + "moves, the view stops seeing damaged stock")
            .isEqualTo(103);
```

Better still, assert against `stock_view.damaged` directly — that grades the surface the client
actually reads.

*(The sibling swap `entity_lock = 0` → `NOT_LOCKED` has the same shape but I am not counting it:
0 is the absence of a lock, not a code the view discriminates on.)*

---

### M-3 · Medium — M2's `size() != 1` strengthening has no test; reverting it to `isEmpty()` survives the entire suite

**File:** `src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java`, `applyDamage`

```java
        if (createdStockunitIds == null || createdStockunitIds.size() != 1) {
            throw new BusinessException("SBDEV-1512: expected exactly one stock unit for advice "
```

**What is wrong.** The strengthening is correct, but nothing grades it. All four damage-path tests
stub `receivingService.receiveGoods(...)` to return `List.of(7001L)` — a single element. No test
passes a list of size 0, 2 or `null`.

*Derivation:* `grep -n "receiveGoods" ReturnAdviceAutoReceiveServiceUnitTest.java` → 24 hits; the
four in the damage section (lines ~1602, ~1625, ~1657, ~1689) are all `.thenReturn(List.of(7001L))`.
*Blind spot:* the receive-path tests above use `doThrow`/`doAnswer`, but every one of them builds
lines with `damagedAmount = 0`, so `applyDamage` is never entered. The integration test runs the
real `receiveGoods` with `amountCases = 1`, which by construction returns exactly one id.

**Measured.** MUTANT-C2 reverted the condition to `createdStockunitIds.isEmpty()`. Full suite:
**6650 run, 0 failures, 0 errors, 1 skipped, BUILD SUCCESS**. Survived.

**Failure scenario.** The `amountCases = 1` call shape changes (e.g. a future multi-case receive).
`get(0)` then damages one case of several, `damageappliedat` is stamped anyway, and the position
drops out of the recovery worklist permanently — a silent partial damage. That is precisely what
M2 was raised to prevent, and the guard would be free to regress unnoticed.

**Fix.** One row:

```java
    @Test
    @DisplayName("M2 — a receive that created more than one stock unit refuses to damage a subset")
    void applyDamage_refusesWhenReceiveCreatedMoreThanOneStockunit() throws Exception {
        when(receivingService.receiveGoods(anyLong(), any(), anyBoolean(), anyInt(), anyInt(), anyInt(), any(), any()))
            .thenReturn(List.of(7001L, 7002L));

        var outcome = service.execute(planWithDamagedLines(1, 3));

        assertThat(outcome.status()).isEqualTo(AutoReceiveOutcome.Status.DAMAGE_FAILED);
        verify(stockunitService, never()).setLockDamaged(any(), any(), any(), anyBoolean(), any());
    }
```

---

### L-1 · Low — M3's `damage_outstanding_after_partial` counter and log have zero coverage in either lane

**File:** `ReturnAdviceAutoReceiveService.executeInternal`, the receive-loop catch block.

*Derivation:* `grep -rn "damage_outstanding_after_partial\|damage_stamp_failed" src/test/` → **0 hits**,
with a positive control in the same scan (`grep -rn "DAMAGE_APPLY_FAILED" src/test/` → 1 hit), so
the zero is a real zero and not a broken instrument. *Blind spot:* the scan is by metric-name
literal; a test could in principle exercise the branch without naming the counter, but any
assertion on it would have to contain that string.

The only integration test for that path,
`ReturnAdviceAutoReceiveIntegrationTest.partialFailure_leavesAdviceOpenWithEarlierPositionsReceived`,
is `@Disabled` under SBDEV-3259 — confirmed in my failsafe run (3 skipped, all three pre-existing
SBDEV-3259 markers, none introduced by this scope).

**On the lead's question 5 — it cannot double-count.** I verified by reading `executeInternal`: the
partial branch ends in `return AutoReceiveOutcome.partial(...)`, which sits inside the receive loop,
textually above the damage loop. A call that reaches `damage_outstanding_after_partial` therefore
never reaches `damage_failed`, and vice versa. `limit(received)` is also correct — `received` is
incremented only after a successful `receiveGoods`, and the stream iterates the same
`plan.lines()` list in the same order, so `limit(received)` is exactly the already-committed prefix
and excludes the line that failed. *Blind spot:* a caller retrying `execute()` after a partial
would increment both counters, but that is two events, not a double count.

**Fix.** A 3-line plan whose third `receiveGoods` throws, asserting
`meterRegistry.get("wms2.returns.autoreceive.damage_outstanding_after_partial").counter().count()`
is 1 and that it is 0 when no received line carried damage.

---

### L-2 · Low — the `%N$s` positional fix is not pinned; the bare `%Ns` form survives

**File:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java`, case
`RETURN_AUTO_RECEIVE_DAMAGE_FAILED`.

**Measured.** MUTANT-C3 reverted the template to the bare `'%1s' ... %2s ... '%3s' ... %4s` form.
Full suite: **6650 run, 0 failures, BUILD SUCCESS**. Survived.

The only assertion on the rendered text is in T1.19:

```java
        assertThat(outcome.description())
            .doesNotContain("%")
            .contains("IBOL012604");
```

Both forms render without a literal `%` and both contain the advice number, because on this
argument list arity and order happen to match. The bare form's one observable difference at the
tested arity is that `%2s` is `%s` with a minimum width of 2, so `total = 1` renders as
`received all  1 position(s)` with a stray leading space — which nothing asserts. The fix is
correct (the comment's reasoning is right); it simply has no guard.

**Fix.** Replace the two loose assertions with the rendered string, or at minimum add
`.contains("received all 1 position(s)")`.

---

### L-3 · Low — `verify(adviceRepository, never()).save(any())` in the F2 test is structurally vacuous

**File:** `ReturnAdviceAutoReceiveServiceUnitTest.resolveRefs_rejectsWhenDamagedLocationMissing`

```java
        assertThatThrownBy(() -> service.validate(dto))
            .as("create() is not transactional, so a post-save throw burns externalid permanently — "
                + "this must fail in resolveRefs, before adviceRepository.save")
            .isInstanceOf(WebserviceBusinessExceptionClientSide.class);
        verify(adviceRepository, never()).save(any());
```

`ReturnAdviceAutoReceiveService` never calls `adviceRepository.save` on any path, so the verify can
never fail. *Derivation:* `grep -n "adviceRepository\." ReturnAdviceAutoReceiveService.java` → 3
hits: two are comment text (the R9 note and a §3.5 note), the third is
`adviceRepository.updateAdviceToStateById(...)` in `markFinished`. *Blind spot:* grep is
file-scoped and blind to reflective invocation; it does not rule out a callee saving through a
different bean, though the mock is injected only into this service and `validate()` calls only
`self.resolveRefs` and `printService.isPrintAvailable`.

The pre-persist ordering the `.as(...)` message claims is real, but it is enforced in
`AdviceRestController.create` — `validate(adviceDto)` at :318, `adviceRepository.save(adviceEntity)`
at :322 — not in the class under test, and no assertion here observes it.

The `assertThatThrownBy` half **is** live: MUTANT-B (whole pre-flight block deleted) turned this
test red. So the finding is only that the second line advertises coverage it does not provide.

**Fix.** Drop the `verify`, or move the ordering claim to a controller-level test that can actually
observe both calls.

---

### L-4 · Low — `stampDamageApplied`'s `rollbackFor` is inert, and the new catch's safety rests on an invariant nothing asserts

**File:** `ReturnAdviceAutoReceiveService.stampDamageApplied`

```java
    @Transactional(value = "tenantTransactionManager",
        rollbackFor = {BusinessException.class, FacadeException.class})
    public void stampDamageApplied(Long advicePositionId) {
```

The method declares no checked exceptions and its body cannot raise either of those types, so
`rollbackFor` never applies. Cosmetic, but it reads as a deliberate boundary decision and is not one.

**On the lead's question 4 — the fix is correct today.** Propagation is the default `REQUIRED`, and
it does start a fresh transaction because nothing on the call chain is transactional:
`AdviceRestController.create`, `execute`, `executeAsIntegrationUser`, `executeInternal` and
`applyDamage` carry no `@Transactional`, and `StockunitService.setLockDamaged` is **not** annotated
either — its transactional unit is `UnitloadService.moveStockToNewDamagedContainer`
(`@Transactional(value = "tenantTransactionManager", ...)`), which commits before control returns.
So the damage is already committed when the stamp runs, and a stamp failure cannot roll it back.
The `catch (RuntimeException e)` also covers the realistic failures — `stampDamageApplied` can only
surface unchecked Spring exceptions.

**The proxy hop.** The unit tests do `ReflectionTestUtils.setField(service, "self", service)`, so
they point `self` at the raw instance and **cannot** observe the hop at all. The mechanism is
proven live by `ReturnAdviceAutoReceiveIntegrationTest.markFinished_commitsBothFlipsAtomically`,
which passes in the failsafe lane against a real Spring context and whose atomicity assertion
requires the `self`-routed transaction to actually start. `stampDamageApplied` uses the identical
`@Lazy @Autowired` self field and is `public`. *Blind spot:* that proves the mechanism, not this
particular method's boundary — no test observes `stampDamageApplied`'s transaction directly.

**The unasserted invariant.** If anyone later annotates a caller (`execute`, or `create`),
`REQUIRED` would join that transaction instead of starting one. The swallowed exception would then
leave the outer transaction rollback-only, and the commit would fail with
`UnexpectedRollbackException` — silently rolling back the damage the catch was written to protect,
and doing so *because* of the catch. Note `REQUIRES_NEW` is not a free answer here (it is the
documented deadlock shape in this repo when taken inside a lock-holding transaction), so the right
remedy is a rail, not a propagation change.

**Fix.** Drop the inert `rollbackFor`; record the invariant as an ArchUnit rule or at least a
comment on `applyDamage` stating that no caller may be `@Transactional`.

---

### L-5 · Low — the cap extension to REGULAR advices is safe on live data, but the comment's "negative rows already exist" claim is unsupported by the tenants I checked

The cap in the unconditional save loop now applies to **every** advice type, not just RETURN. The
constant's justification comment was measured for the SBDEV-2778 scope, where it only ever graded
RETURN. I re-measured across both types:

| DB | type | positions | max notifiedamount | > 100,000 | < 0 |
|---|---|---|---|---|---|
| Hydra PRD (`wms2-hydra`) | REGULAR | 246 | 1,680 | 0 | 0 |
| Hydra PRD | RETURN | 1 | 12 | 0 | 0 |
| wsl-wineco UAT | REGULAR | 42,590 | 14,784 | 0 | 0 |
| wsl-wineco UAT | RETURN | 10,067 | 12 | 0 | 0 |

So the cap has ≥6.8x headroom against the largest REGULAR advice ever recorded on these tenants and
rejects nothing live — the extension is safe, and the comment's 14,784 figure reproduces exactly.

Two notes:

1. The comment `// ... and rows with a negative value already exist in the estate` is **not
   supported** by either tenant I queried — 0 negative rows across 52,904 positions. *Blind spot:*
   I queried 2 of the ~6 reachable tenant DBs; the claim may hold on a shipitez or hydra-uat
   schema I did not check. I am flagging it as unverified, not as false.
2. The new cap throw fires inside the position loop, i.e. **after** `adviceRepository.save` at :322.
   A capped-out advice therefore burns its externalid and leaves a partially-written advice while
   returning 400. That is the pre-existing FU-2 shape the surrounding comments already acknowledge,
   not a new defect class — but it is a new throw site on the REGULAR path, which previously had
   none. Zero live rows would hit it.

---

### Informational — both unit test classes run `@MockitoSettings(strictness = Strictness.LENIENT)`

`AdviceRestControllerUnitTest:40` and `ReturnAdviceAutoReceiveServiceUnitTest:91`. Pre-existing, not
introduced by this scope, but worth stating because it is the amplifier behind M-1 and M-3: an
unmatched or mistyped stub raises nothing. It is also why
`resolveRefs_doesNotRequireDamagedLocation_whenNothingIsDamaged` can stub `locationRepository
.findByName(...)` and then assert it was never called without an `UnnecessaryStubbingException`.

---

## What checked out clean

- **H2/H3/S1 (`AdviceRestController`).** The `null → 0` coalescing is explicit and does not unbox
  (`Integer rawDamaged = ...; int damaged = rawDamaged == null ? 0 : rawDamaged;`); the sum is
  computed as `long`; the cap grades the **total** against `ReturnAdviceAutoReceiveService
  .MAX_UNITS_PER_POSITION`; and the `< 0` check on `amount_of_bottles_damaged` sits in the
  unconditional loop beside its `amount_of_bottles` sibling, not in `resolveRefs`. The four new
  controller rows are real boundary pins, not comfortable values: exactly 100,000 must be
  **accepted** (separates `>` from `>=`), an explicit 0 must be **accepted** (separates `< 0` from
  `<= 0`), 2e9 + 2e9 must be **rejected** (only a wide computation can, since the int sum wraps
  negative and passes `> 100_000`). All four use bare `verify(..., never()).save(any())`, avoiding
  the typed-matcher overload hole, and `anyBoolean()` rather than `any()` on the primitive
  parameter.
- **F1 `continue` — present and genuinely pinned.** MUTANT-A appended `break;` after the
  `if (damageOutcome == null)` block. `applyDamage_failureOnOnePosition_stillDamagesTheRest` went
  **red** at its `verify(stockunitService, times(3)).setLockDamaged(...)`. The first-failure-wins
  guard is also correct: `failedSku()` is asserted to be `SKU001`.
- **F2 pre-flight — present, conditional, pre-persist, genuinely pinned.** MUTANT-B deleted the
  whole block; `resolveRefs_rejectsWhenDamagedLocationMissing` went **red**. It uses
  `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_DAMAGED)` — byte-for-byte the same
  lookup `StockunitService:770` performs at execute time — so the pre-flight and the real resolution
  cannot disagree. It runs before `adviceRepository.save` (controller :318 vs :322), throws
  `ENTITY_DOES_NOT_EXISTS` with the generic `Location` class name rather than the literal "Damaged",
  and the conditional half has its own row asserting `findByName` is never called when nothing is
  damaged. *(That row's liveness I reasoned rather than measured: an unconditional guard would both
  call `findByName` and throw on the `Optional.empty()` stub, failing the test twice over.)*
- **F3 `DAMAGE_APPLY_FAILED` / `Status.DAMAGE_FAILED`.** Defined, surfaced to the caller through
  `AdviceRestController:556` as `reason().name()`, and asserted in T1.19. Adding the constant is
  safe: `grep -rn "FailureReason\."` across `src/main` and `src/test` finds no `switch` over the
  enum, only equality comparisons.
- **The `(int) totalAmount` narrowing in `resolveRefs`** sits below both the `< 1` and the
  `> MAX_UNITS_PER_POSITION` guards (confirmed by reading the ordering: `< 0` on `rawDamaged`, then
  the `long` sum, then `< 1`, then the cap, then the cast), so it cannot wrap.
- **`ReceivingService.receiveGoods`** — the javadoc now sits above `@Transactional` rather than
  between it and the declaration, the annotation is unchanged, and the full suite (which loads
  Spring contexts) is green, so nothing de-wired.
- **The migration version rename was a correction, not drift.**
  `V2.2.31__cancellation_log_pickingorder_position_id.sql` exists and
  `V2.2.32__adviceposition_notified_damaged_amount.sql` is the ticket's migration — the test's old
  `V2.2.31` javadoc was stale text.
- **The `Box` unit-load type is not a second F2-shaped gap.** `setLockDamaged` also resolves
  `UNIT_LOAD_TYPE_BOX` by name with an unchecked `orElseThrow`, which looks like the same
  misconfiguration class. It is not reachable here: `AdviceRestController`'s position loop resolves
  that same row and throws `ENTITY_DOES_NOT_EXISTS` before `execute` is ever called, so a tenant
  missing it cannot create an advice position at all.
- **Suite.** 6650 / 0 failures / 0 errors / 1 skipped, BUILD SUCCESS — re-derived myself, matching
  the figure I was given.
- **The two integration tests the diff touched do not run in `mvn test`** (`pom.xml` surefire
  excludes `**/*IntegrationTest.java`; confirmed — no surefire report for either class, against a
  positive control of 22 report files for `ReturnAdviceAutoReceiveServiceUnitTest`). I ran the
  failsafe lane for them separately: 12 run / 0 failures / 3 skipped, and all 3 skips are
  pre-existing SBDEV-3259 `@Disabled` markers. `mixedReturn_receivesTotalAndLocksDamagedPortion`,
  the test whose assertions this scope edited, **passes**.

---

## Commands run

| # | Command | Result |
|---|---|---|
| 1 | `git log --oneline -6`, `git diff --stat 5136ed87..e01bce85` | detached at `e01bce85`; 8 files, +504/−27 |
| 2 | `git diff 5136ed87..e01bce85 -- src/main/` / `-- src/test/` | full read of scope |
| 3 | `git diff 5136ed87..e01bce85 -- src/test/ \| grep '^-' \| grep -v '^---'` | 6 removed lines (see verdict) |
| 4 | `mvn -o clean test` | **6650 / 0 F / 0 E / 1 S — BUILD SUCCESS** (3:01) |
| 5 | `grep -rn "STORAGE_LOCATION_DAMAGED" src/main/` | pre-flight matches `StockunitService:770` exactly |
| 6 | `grep -rn "entity_lock" src/main/resources/db/migration/ \| grep 103` | `V2.2.00:4700` — `stock_view.damaged` hardcodes 103 |
| 7 | `ls src/main/resources/db/migration/ \| grep 'V2\.2\.3'` | V2.2.31 = cancellation_log; V2.2.32 = this ticket |
| 8 | `grep -rn "damage_outstanding_after_partial\|damage_stamp_failed" src/test/` + positive control `DAMAGE_APPLY_FAILED` | 0 hits / control 1 hit → real zero |
| 9 | `grep -n "@MockitoSettings" <both test classes>` | both `Strictness.LENIENT` |
| 10 | `mcp wms2-hydra execute_sql` — max/min/over-cap/negative `notifiedamount` by advice type | REGULAR max 1,680; 0 over cap; 0 negative |
| 11 | `mcp wsl-wineco-uat execute_sql` — same query | REGULAR max 14,784 over 42,590 rows; 0 over cap; 0 negative |
| 12 | **MUTANT-A** `continue` → `break`, `mvn -o test -Dtest=ReturnAdviceAutoReceiveServiceUnitTest` | **KILLED** — 72/1 F, `applyDamage_failureOnOnePosition_stillDamagesTheRest` |
| 13 | **MUTANT-B** F2 pre-flight block deleted, same command | **KILLED** — 72/1 F, `resolveRefs_rejectsWhenDamagedLocationMissing` |
| 14 | **MUTANT-C** (C1 impure + C2 + C3), `mvn -o test` full suite | 1 F, attributable to C1's double-stamp artefact only; T1.19 green |
| 15 | **MUTANT-C1b** stamp moved to `finally`, original block deleted, `-Dtest=ReturnAdviceAutoReceiveServiceUnitTest` | **SURVIVED** — 72 / 0 F / BUILD SUCCESS → M-1 |
| 16 | **MUTANT-C2+C3** (`isEmpty()` + bare `%Ns`), `mvn -o test` full suite | **SURVIVED** — 6650 / 0 F / 0 E / 1 S / BUILD SUCCESS → M-3, L-2 |
| 17 | restore all 3 files from scratchpad backup; `git status --porcelain` | **empty** — tree byte-identical to `e01bce85` |
| 18 | `ls target/surefire-reports/ \| grep -i IntegrationTest` + positive control | no report → ITs excluded from surefire |
| 19 | `mvn -o verify -Dit.test='ReturnAdviceAutoReceiveIntegrationTest,AdvicePositionDamagedColumnsIntegrationTest'` | **12 run / 0 F / 0 E / 3 S — BUILD SUCCESS** |
| 20 | parse `target/failsafe-reports/TEST-...ReturnAdviceAutoReceiveIntegrationTest.xml` | 3 skips all pre-existing SBDEV-3259; edited test passes |
