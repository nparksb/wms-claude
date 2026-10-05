## Re-review: SBDEV-3487 review-fix commits (`690a4109..HEAD`: 956eda99, 49b87c99, 45d00ad7)

**Verdict: APPROVE.** All 15 findings in scope (M1, M2, L1–L12, L14) are resolved. I found 3 new Lows and 1 low-confidence question, all in comments or test code. None is a production logic defect.

**What I checked**
- **Diff:** I read the whole diff across 10 files, plus the original review and the fixer's report. I never touched `v2/wms2-api`.
- **Tests:** I ran `BillofladingPositionServiceUnitTest` and `MobileMoveUnitloadServiceUnitTest` with `mvn -o test` after `pgrep` came back empty. All green: 25 + 45 tests.
- **Not re-run:** the 4 PG ITs and the fixer's mutants. Those rest on the p3c report. I read each new test for ways it could pass vacuously instead.
- **L8 SQL:** I ran `javap -v` on the compiled `BillofladingPositionRepository.class`. The worktree is clean, so the class matches HEAD. The pre and post query strings are byte-identical:
  - `...where u.labelid = :unitLoadLabelId and bp.state = 'CLOSED' order by bp.id limit 1`
  - `DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId AND (bp.state IS NULL OR bp.state <> 'CLOSED')`, and its `carrierId IN` twin, both appearing twice.
- **Constant:** `WmsConstants.BillOfLadingState.CLOSED = "CLOSED"`. Six other `repo.jpa` interfaces already import `WmsConstants`, so the new import isn't a new layering edge.

### Per original finding
| # | Status | Evidence |
|---|---|---|
| M1 | RESOLVED | The "Shared by" list names all 4 ITs. The no-match exit is scoped to the probe and race. The nanoTime claim now credits `runKey`. My old-wording grep ("no integration test", "Shared by", "PREFIX} carries", "only ever takes D0", "exercises only PHASE D0", "no assertion in either subclass") finds no stale copy. |
| M2 | RESOLVED | The javadoc's order (move to seeded location → sweep → delete by exact label) matches the hook call order in `purgeByPrefix`. Both FK explanations hold: the location is deleted last in `deleteAll`, and the parcel points at the pallet through `carrierunitload_id`. |
| L1 | RESOLVED | `seedOpenBol` moved above; the `advanceBolToTruckLoadingAtGate` javadoc sits on its method again. |
| L2 | RESOLVED | `oneRowDeleteDoesNotRecheck` stubs R3 to return 1, verifies `never()` on `SCAN_GATE_D0_RECHECK`, and pins R4's `List.of(10L, 20L)`. It isn't vacuous: the method runs directly, so any throw would fail it. |
| L3 | RESOLVED | There are null-state controls for R5 (count + result), R4 and R6. The null children are parented to the TRUCK_LOADING control parents, so each query's delete reaches them. |
| L4 | RESOLVED | See the ListAppender note below. |
| L5 | RESOLVED | Both class javadocs mark the pre-fix state (`682483fe`) and describe the fixed code. Each claim checks out against lines :502/:514 and :582/:590. |
| L6 | RESOLVED | See the hooks note below. One pointer to the old override was missed (N1). |
| L7 | RESOLVED (javadoc route) | The claims are true: `@Primary` sits on `landlordTransactionManager` (`LandlordDatabaseConfig:60-62`), and `MobileMoveUnitloadClosedBolPurgeIT#tenantTx()` exists at :97. The `@Qualifier` change is deferred, which the finding allowed. |
| L8 | RESOLVED | Byte-identical SQL, per `javap`. |
| L9 | RESOLVED | |
| L10 | RESOLVED | AC-8(e) verifies `never()` on the finder, which is the assertion that actually catches the mutant. Without the guard the mock returns null, so the no-throw and no-WARN checks alone would pass. The existing positive test at :601 shows `guardWarnings()`'s appender captures events. |
| L11 | RESOLVED | |
| L12 | RESOLVED | |
| L14 | RESOLVED | The comment is added. Its lock list is imprecise (OQ1). |

**L4 ListAppender:**
- **Right logger:** the test uses `LoggerFactory.getLogger(MobileMoveUnitloadService.class)`, the same logger as `LOG` at :27.
- **Detached:** the appender is removed in `finally`.
- **Right matcher:** `getMessage()` is the raw pattern, so `startsWith("SBDEV-3487: pallet position")` matches. `billofladingPositionService` is a mock, so no other WARN can be counted.
- **Not vacuous:** `hasSize(1)` goes red if the WARN line is deleted.
- **Nit:** `captured.stop()` is never called. That's harmless.

**L6 hooks:**
- **Order:** `SET lock_timeout = '30s'`, then `beforePrefixPurge`, then `deleteAll`, then `afterPrefixPurge`, all on one connection.
- **Bound:** it's a session-level `SET` on an autocommit connection, so the bound covers both hooks.
- **Error naming:** each hook statement goes through `exec`, so a failure names its statement.
- **Other subclasses:** the probe and race don't override the hooks (the defaults are no-ops) and define no `exec`, so widening `exec` to `protected static` changes nothing for them.
- **`@BeforeEach` purge (:181):** it now runs the hooks too. The labels are `static final`, so they are available there.

### New findings

**[LOW] N1: stale pointer to the removed override.** Confidence: HIGH.
File: `src/test/java/net/aim_ai/wms/integration/service/mobile/MobileMoveUnitloadClosedBolPurgeIT.java:108-109`
> `PREFIX-named so super's sweep removes it; the fixed-label pallets are moved off it first (see purgeByPrefix).`
- **Problem:** this class no longer overrides `purgeByPrefix`; the move now happens in `beforePrefixPurge`. A reader following the pointer lands on the base method, which moves nothing. This is a sibling copy the L6 rename missed. The other 4 references in this file were updated.
- **Fix:** `(see {@link #beforePrefixPurge})`.

**[LOW] N2: the fixture overstates what `MobileMoveUnitloadClosedBolPurgeIT` covers.** Confidence: MEDIUM.
File: `AbstractTruckLoadingPgFixture.java`, class javadoc (~:94-95) and the `OutboundPalletLabelGuard` mock javadoc (~:157-159).
> "The two SBDEV-3487 subclasses … so their scans DO run D0's purge and rebuild."
- **Problem:** in the move-unitload IT, `scanGate` is setup only. It runs once per fresh pallet (helper at :320-323) that has no earlier positions, so D0 matches and deletes nothing. That class's subject is the move-unitload purge (V2, `handleTruckOffLoading`), not D0's purge and rebuild. Only `MobileTruckLoadingClosedBolPurgeIT` actually exercises D0's purge, and the paragraph at ~:110 already names it as the positive control.
- **Why it matters:** this is the same failure mode as M1 in the other direction. A reader credits the move IT with D0 coverage it doesn't have.
- **Fix:** "their `scanGate` calls enter D0's match branch; `MobileTruckLoadingClosedBolPurgeIT` exercises D0's purge and rebuild, and `MobileMoveUnitloadClosedBolPurgeIT` exercises the move-unitload purge (V2)."

**[LOW] N3: `SEEDED_LOCATION_ID` is a boxed `Long`, not a compile-time constant.** Confidence: HIGH.
Files: `MobileTruckLoadingClosedBolPurgeIT.java:386-388` and `MobileMoveUnitloadClosedBolPurgeIT.java:409-411`. The constant is declared at `PgLaneFixtures.java:80`:
```java
public static final Long SEEDED_LOCATION_ID = 0L;
```
```java
// exec binds strings only; the seeded id is a constant, so it is inlined, not bound.
exec(con, "update unitload set storagelocation_id = " + PgLaneFixtures.SEEDED_LOCATION_ID + " where labelid = ?", label);
```
- **Report claim is wrong:** p3c says it is "a compile-time `0L`". A boxed `Long` is never a constant variable.
- **No injection risk:** the value is test-owned.
- **Failure scenario:** if it ever became null, the SQL would read `set storagelocation_id = null`. That silently nulls the column instead of failing, and the pallet then leaves the location FK behind without an error that names it.
- **Fix, either:**
  - give `exec` an `Object...` overload that uses `ps.setObject`, and bind the id;
  - or inline `String.valueOf(Objects.requireNonNull(PgLaneFixtures.SEEDED_LOCATION_ID))`.

  Either way, reword the comment to "a fixed test id".

### Open questions (low confidence, not blocking)

**[LOW] OQ1: the L14 comment's lock list is imprecise.** Confidence: LOW.
File: `MobileMoveUnitloadService.java:499-501`
> "transferUnitLoadToLocation has taken its locks (DEST, the owning pickingorders, the pallet row)"

Only DEST is certain. Here is each lock in turn:
- **DEST:** taken with `findByIdForUpdate` (`UnitloadBusinessService:245`). Correct.
- **Owning pickingorders:** `CODE_TRANSFER` is in `BLOCK_REALIGN_CODES`, so they are locked, but only if the pallet's stock backs any pick order. Often it backs none.
- **Pallet row:** no pessimistic lock is taken. `processTransfer` does a `findById` plus a `save` (around :523-527). The row lock comes when that UPDATE is flushed. That is probably the auto-flush that the backstop's own native select triggers, but I did not measure it.

The design point the comment exists to protect still holds. **Fix (optional):** "after transferUnitLoadToLocation's DEST lock (and any owning-pickingorder locks), and after the pallet's UPDATE is flushed".

### Positive observations
- **L8:** `NOT_CLOSED_PREDICATE` removes 4 of the 5 copies of the literal without changing a byte of SQL. The finder concatenates the constant inline, so all 5 now follow `WmsConstants`.
- **L6:** the hooks put the fixed-label statements under the same bound and the same error naming as the sweep, instead of copying the SET into the subclasses.
- **Mutation evidence:** there is one mutant per new assertion. The V1 `if (true)` mutant going red confirms L2 was a real coverage gap.
- **Test isolation:** AC-9's new rows each target one query, so each IS NULL mutant reds only its own control.
- **Comment rewrites:** the L5, L7 and L12 rewrites are accurate against the code. That includes the landlord-transaction claim in the `tx()` javadoc.

### Recommendation
**APPROVE.** N1–N3 and OQ1 are comment or test-hygiene Lows. Nam's standing rule is to fix Lows in the same pass, so they should go in before the PR. None of them blocks.