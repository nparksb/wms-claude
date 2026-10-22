---
title: SBDEV-3736 — independent code review, round 2 (review-fix commits)
ticket: SBDEV-3736
lane: code-reviewer r2
date: 2026-10-15
head: a538785e24419d34204cb39f7437435f23896582
scope: git diff 666fe51a..a538785e (e095df5c, 339da0fc, dab72eeb, 889da101, c9e05f29, a538785e)
worktree: .claude/worktrees/wms2-api/SBDEV-3736
verdict: APPROVE (with Lows)
counts: { critical: 0, high: 0, medium: 0, low: 5, info: 2 }
---

# SBDEV-3736 — code review r2

This review was read-only. I made no worktree edits and ran no Maven. Evidence comes from the code at `a538785e`, from Spring 6.2.15 sources (`~/.m2`), and from read-only PRD queries run on 2026-10-15 against WineCo (`wsl-wineco-prd`), Hydra, ShipItEZ NY and ShipItEZ C1. Suite and mutant results come from the fixer's run (`fixes-r1.md`: 8300 unit and 872 IT, all green). I did not re-run them.

## 1. Round-1 resolution (checked against the code)

| Finding | Status | Evidence at a538785e |
|---|---|---|
| code M1 (exact match) | **RESOLVED** | `ReceivingService.java:709-710` `compareTo(p.getNotifiedamount()) == 0`. Two OPEN tests, 50/5+6/5 and 5/5+6/5, kill K1. One residual race remains: an over-key that runs concurrently with the finishing receive can still close the advice (R2-L1, not introduced by the fix). |
| code M2 (Spring seam IT) | **RESOLVED** | `ReturnsAuditRepositoryIntegrationTest` runs through `ViewDtoService` and the real repository. It covers null, `''`, A and B filters, paging with totals, and `Date` equality. It is rolled back, because `BasePostgresIntegrationTest:61` is `@Transactional("tenantTransactionManager")`, so the fixed ids do not collide on a reused container. |
| code M3 (receivedBy, carrierParcelId) | **RESOLVED** | Added to the SELECT, the projection and the DTO. `ru` joins on PK `mywms_user.id`, so it is at most 1:1. `co` relies on UNIQUE `externalnumber`, so it is also at most 1:1. The countQuery still has neither join, and a new contract test pins that. |
| code L1 ("only writer") | **RESOLVED** | The javadoc now says "only CREATOR" and names `adjust`. |
| code L2 (OL misreport note) | **RESOLVED** | Javadoc "Auto-receive path" paragraph. |
| code L3 (deadlock / race) | **RESOLVED** | I checked the exact-match argument against `receiveGoods`, which takes `FOR UPDATE` at `:383` and never writes a sibling position row. The argument holds: two finishers cannot run at once. The `.sorted()` is redundant (R2-L2). |
| code L4 (NULL notified) | **RESOLVED** | SQL `coalesce(received = notifiedamount, false)` with `received = coalesce(sum,0)` agrees with the Java rule on a NULL notified amount (false/false), a NULL grp amount (both skip it), a zero-notified unreceived position (true/true), a position-less advice (false/no-op) and BigDecimal scale (`compareTo` / numeric `=`). |
| code L5 / sec L3 (client-scoped `co`) | **RESOLVED** | `AND co.client_id = adv.client_id`, with `DISTINCT ON` dropped. I measured whether the client predicate **loses** any match today. It loses none: WineCo 2822/2822 same-client, Hydra 2/2, ShipItEZ NY 19/19, ShipItEZ C1 1047/1047, and 0 cross-client on all four. |
| code L6 (never() kept beside) | **RESOLVED** | All 5 sites now carry both negatives. The diff removes no line, and K12 is killed by exactly these lines, so they are not vacuous. |
| code L7 (finisher pair IT) | **RESOLVED** | It goes through the real `execute()`. Auto lines receive `undamaged + damaged`, which equals `notifiedamount` (`AdviceRestController:485`), so S8 does fire. See R2-L5 for one unpinned claim. |
| code L8 (damaged stockrecord) | **RESOLVED** | The same IT asserts `containsOnly("APOS-"+A)` and `isNotEmpty`, and K11 is killed. |
| code L9 / sec L1 (window cap) | **RESOLVED** | `ReportController:450`: `Duration.between(from,to).compareTo(366d) > 0` gives 422. The cap is inclusive, so a leap year (366 d) fits. Duration measures instants, so offsets and DST cannot skew it. `ApiInvalidParameterException` gives 422, the same as `from >= to` and `checkPageBounds`. Boundary tests sit at exactly 366 d and at +1 s, and K5 and K6 are killed. |
| code L10 (edge cases) | **RESOLVED** | `from == to` returns 422, missing `to` returns 400, and `%2B02:00` binds to the right instant. |
| sec L2 (allow-path 200) | **RESOLVED** | 200 on both prefixes, and K7c and K7d are killed. One stale comment remains (R2-L3). |
| sbdocs corrections | **RESOLVED** | `architect-consult.md:301` is struck through and corrected. `implementation-report.md:184` is corrected. |

## 2. Assertion-loosening check (3)

Every `-` line under `src/test` in `666fe51a..HEAD`:
- `ReturnsAuditQueryIntegrationTest`: the `advice(...)` helper gained a `clientId` overload. The old call is unchanged in behaviour.
- `ReturnsAuditQueryContractUnitTest`: `REQUIRED_GETTERS` was **extended** by 2.
- `ReceivingServiceUnitTest`: a comment was reworded, and `thisReceipt.setAmount(new BigDecimal(5))` was parameterised. The default overload still passes 5, so all pre-existing S8 tests (`:1479`, `:1498`, `:1515`, `:1616`, `:1632`, `:1648`) run the same fixture.

**No assertion was loosened, removed or retargeted.**

## 3. Surviving mutants K7 / K7b (4)

**The fixer's reasoning is sound.** Spring 6.2.15 `TemporalAccessorParser.parse` (lines 95-114) falls back to `defaultParse` → `OffsetDateTime.parse(text)` (ISO, line 178) whenever no `fallbackPatterns` are set. So:
- with `@DateTimeFormat` removed (K7), ISO parsing still succeeds;
- with `ISO.DATE` (K7b), the annotated parse fails, the ISO default succeeds, and the mutant is equivalent.

This is the framework parser itself, not the standalone MockMvc conversion service, so the result also holds for Boot's `WebConversionService` in production.

The replacement mutants are adequate for what the allow control has to detect:
- K7c (GET→POST, 405) checks reachability;
- K7d (dashboard prefix) checks the inherited twin.

Binding correctness is pinned separately by the `%2B02:00` instant test.

## 4. New findings (2)

### [LOW] R2-L1: a concurrent over-key can still FINISH the advice with an over-received position (stale completeness read)
- **File:** `ReceivingService.java:695-723`

  ```java
  boolean complete = positions.stream().allMatch(p -> p.getNotifiedamount() != null
          && receivedByPosition.getOrDefault(p.getId(), BigDecimal.ZERO).compareTo(p.getNotifiedamount()) == 0);
  ```

  The javadoc (`:667`) promises: *"On exact match an over-received advice stays OPEN, so the receipt stays correctable."*
- **Confidence:** MEDIUM. This is reasoned against PostgreSQL READ COMMITTED; I did not reproduce it.
- **Scenario:** Position B is already exactly received (committed), and A is short by n.
  1. T1 locks A `FOR UPDATE` and receives n, so A is exact. T1 then reads the grp totals: A exact, B exact. Result: complete.
  2. Concurrently, T2 locks B `FOR UPDATE`. Both B and the advice are still OPEN, because T1 has not committed. T2 receives 1 more on B (an over-key; RETURN allows over-delivery). T2's own finisher does not see T1's uncommitted A, so T2 does not finish.
  3. T1's flush runs `UPDATE adviceposition … WHERE id=B AND version=v` and blocks on T2's row lock.
  4. T2 commits. It never modified B's row, so the version is unchanged and T1's update succeeds.
  5. T1 commits the advice as FINISHED with B over-received. Adjust and delete are now refused (`checkAndGetGoodsReceiptPosition` requires OPEN), and that is exactly the outcome M1 was meant to prevent.
- **Is it a regression?** No. The same window existed under `>=`. But the M1 guarantee as written is stronger than the code.
- **Mitigation already in place:** the audit shows such an advice as `adviceState=FINISHED, fullyReceived=false`.
- **Population today:** 0. WineCo PRD has 0 over-received RETURN positions and 0 OPEN RETURN advices.
- **Fix (either):**
  - (a) Once `complete` is seen, lock each *other* OPEN position with the existing `findByIdForUpdate`, in ascending id order. Then re-run `findByAdvicepositionIdIn`; a new statement sees T2's committed grp. Return if the totals are no longer exact. Only a transaction that already saw "complete" takes the extra locks, so a non-finisher never waits on a finisher and the order cannot deadlock. This uses no new repository method.
  - (b) Keep the code and qualify the javadoc: "stays OPEN unless an over-key on another position commits concurrently with the finishing receive; the audit shows that as FINISHED + fullyReceived=false."

### [LOW] R2-L2: `.sorted(Comparator.comparing(Adviceposition::getId))` and its InOrder test pin `save()` call order, which is not the SQL lock order
- **Files:**
  - `ReceivingService.java:714-717`;
  - `ReceivingServiceUnitTest.receiveGoods_shouldSavePositionsInAscendingIdOrder_whenReturnAdviceCompletes` (`order.verify(advicepositionRepository).save(adviceposition)`).
- **Confidence:** HIGH.
- **Issue:**
  - `save()` on a managed entity is `em.merge` and issues no SQL. The UPDATEs are emitted at flush.
  - With `spring.jpa.properties.hibernate.order_updates=true` (`application.properties:102`, also in test resources), Hibernate sorts the updates by entity name and id regardless of call order.
  - So the javadoc's "Positions are still saved in ascending id order … so the row-lock order is deterministic" is true, but because of `order_updates`, not because of the sort.
  - K2 (drop the sort) was killed only because the mock records call order. In production, the mutant changes nothing.
  - The risk is maintenance only: someone may "simplify" `order_updates` away and believe the sort still protects lock order. The sort and the test do not.
- **Fix:** Cite `hibernate.order_updates` in the javadoc as the real guarantee, and keep or drop the sort. Rename or re-describe the unit test as "call order", or drop it. Optionally add an ArchUnit or property assertion that `order_updates=true` stays set.

### [LOW] R2-L3: stale comment in the allow control contradicts the K7 result
- **File:** `ReportReadGateUnitTest.java` (allow control, new lines): `// … A 400 here means the OffsetDateTime binding broke (e.g. @DateTimeFormat dropped)`
- **Confidence:** HIGH. K7 and K7b survive, and Spring's ISO fallback is confirmed above.
- **Fix:** Reword it to: "a 405/404 means the mapping broke; a 403 means over-gated. @DateTimeFormat is not load-bearing (Spring falls back to ISO parsing)."

### [LOW] R2-L4: fixer's open item confirmed, with refinements. An over-key corrected via `adjust` can leave a RETURN advice complete-but-OPEN
- **Files:**
  - `GoodsReceiptPositionService.java:90-125` (`adjust` → `position.setAmount(newAmount); goodsreceiptpositionRepository.save(position);`, with no finisher call);
  - `AdviceService.close:155` (`if (!advice.getType().equals(REGULAR)) throw …`).

  There is no other RETURN finisher: `markFinished` runs only on the auto path, and `acceptHubAndSpokeAdvice` and transfer accept are type-guarded.
- **Confidence:** HIGH on the mechanism.
- **Confirmed:** the advice stays OPEN when the adjusted position was the last non-exact one. A further receive over-receives again, and no other path finishes a RETURN advice.
- **Refinements:** "OPEN forever" is too strong.
  - (i) If any *other* position is still short, the next receive on it runs the finisher and finishes the advice.
  - (ii) An operator workaround exists: delete the over-keyed receipt (or `adjust` to 0, which calls `deletePosition`), then re-receive the exact remainder. That `receiveGoods` runs the finisher and the advice finishes. The cost is UL/label churn plus extra OMS stock messages.
- **Severity:** LOW.
  - The population is 0 on PRD.
  - The audit flags the state (`fullyReceived=true`, `adviceState=OPEN`).
  - A workaround exists.
  - The resulting state is the same class as the pre-ticket behaviour, in which every dock-completed RETURN advice stayed OPEN.
- **Fix:** The fixer's proposal is right. Make the finisher package-visible (or a small public method) and call it at the end of `adjust` and `delete` for RETURN advices. This is a T1 follow-up on this ticket, which is not yet on dev. Cover it with one unit test (adjust 50→5 on the last position → FINISHED) and one test that adjusting to a still-over amount leaves the advice OPEN.
- **Side observation (pre-existing, out of scope):** `adjust` emits its stock-change DTO with `CODE_RECEIVING_REGULAR` even for RETURN advices.

### [LOW] R2-L5: the L7 IT's "written by S8" claim is not pinned
- **File:** `ReturnAdviceAutoReceiveIntegrationTest.java` (new test). The assertion is `.as("L7: the advice is written FINISHED exactly once (by the last receive's S8 finisher) …").isEqualTo(1)`.
- **Confidence:** MEDIUM.
- **Issue:** `advice.version == 1` also holds if S8 does *not* fire on the auto path and `markFinished`'s entity save is the single write. The S8-call removal is still killed by the `ReceivingService` unit tests, so the gap is only in this IT's claim.
- **Fix:** Also assert `adviceposition.version = 1` for both positions. S8's entity saves bump the version; `markFinished`'s JPQL bulk update does not. Mutation-check this by removing the S8 call.

## 5. Checked and clean

- **Finisher edge cases:**
  - NULL `notifiedamount` → never complete.
  - Zero-notified position → complete when nothing is received, consistent with SQL. The population is 0 on WineCo PRD.
  - Already-FINISHED positions → skipped, which is harmless. `receiveGoods` refuses a non-OPEN position at `:386`, so the advice can only be completed through OPEN positions.
- **Flush and the SBDEV-3615 carrier move:** the finisher still uses entity saves only, with no `clearAutomatically`. `order_updates` puts all inserts before updates and runs Advice before Adviceposition. Pending carrier writes are not discarded.
- **Number generation:** `generateNumber` goes through `sequenceTransactionService`, a separate transaction. No sequence-row lock is held across the receive, so no deadlock cycle involving the finisher's B-update exists.
- **SQL cardinality and countQuery:**
  - `ru` is a PK join.
  - `co` is a UNIQUE `externalnumber` join. A NULL externalnumber never equi-joins.
  - The countQuery `adv` CTE gained only `a.client_id`, and the `adv`-filter text is identical in both statements.
- **366-day cap:** `from >= to` is checked first, so a negative Duration never reaches the cap check. The rejection message echoes only constants.
- **Restored `never()` lines:** non-vacuous, since K12 is killed by exactly those lines.

## 6. Informational

- **I1:** WineCo PRD has 133 FINISHED, position-less RETURN advices. The audit reads them as `fullyReceived=false`. That is consistent with the Java rule (no positions → not complete), and it is the inverse of the "missed finish" signal, not a defect. If the audit's consumers treat `FINISHED && !fullyReceived` as an alarm (R2-L1's signature), they need to exclude position-less advices.
- **I2:** Hydra PRD has 0 RETURN advices with `allowoverdelivery=false`, the same as WineCo, so the M1 premise holds there too.

## Positive observations

- The fixer refuted their own suggested mutant (K7) instead of forcing a kill, and replaced it with mutants that change behaviour.
- K12 proves that the restored `never()` lines are load-bearing, not decorative.
- `fixes-r1.md` is accurate for every claim I checked against the code. I found no overstated fix.
- The Spring seam IT seeds the grp operator distinct from the goodsreceipt operator, so the wrong-column mutant (S6) is detectable.

## Recommendation

**APPROVE.** I found no Critical, High or Medium findings, and every round-1 finding is resolved in code. Per house rule, the five Lows should be fixed in the same pass:
- R2-L1: either fix (a) or the javadoc qualification (b);
- R2-L2 and R2-L3: comment and javadoc only;
- R2-L5: one extra assertion;
- R2-L4: Nam's call. It goes on this ticket as the T1 follow-up the fixer proposed.
