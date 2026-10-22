---
title: SBDEV-3736 — implementation report (A, S1, S2, S3, S8)
ticket: SBDEV-3736
lane: executor
date: 2026-10-15
code_pin: worktree .claude/worktrees/wms2-api/SBDEV-3736, branch feature/SBDEV-3736-returns-audit-linkage, base origin/develop 371d8a09, HEAD 666fe51a (not pushed)
---

# SBDEV-3736 — implementation report

## Commits (on top of the TDD-gate commit 0094559d)

| SHA | Subject |
|---|---|
| 0ce4754f | feat(report): read-only returns audit endpoint on a set-based native query [SBDEV-3736] |
| ee30fa1f | fix(receiving): stamp goodsreceipt.receiptdate in UTC when the receipt is created [SBDEV-3736] |
| 48c06138 | fix(returns): finish an auto-received RETURN advice through the entity [SBDEV-3736] |
| d817101f | fix(returns): carry the advice position number on a damaged return's transfer [SBDEV-3736] |
| e009e700 | fix(receiving): finish a RETURN advice once every position is fully received [SBDEV-3736] |
| 86013146 | test(arch): ReturnAdviceAutoReceiveServiceUnitTest never() inventory 7 -> 9 [SBDEV-3736] |
| 666fe51a | test(returns): close mutation survivors on the returns audit and the finishers [SBDEV-3736] |

Nothing is pushed. The working tree is clean, and `src/test/resources/archunit_store` was not mutated by any run.

## What was built (design followed as written, with no redesign)

- **A**
  - `AdvicepositionRepository.findReturnsAudit(OffsetDateTime from, OffsetDateTime to, String clientNumber, Pageable)` is a native query. The repo is already `exported = false`.
  - The query is built from CTEs:
    - `adv`: RETURN advices with `[from, to)` on `a.created` and the safe optional client arm.
    - `pos_rcv` / `adv_rcv`: per-position received totals, then `bool_and` per advice.
    - `ur`: `DISTINCT ON (ordernumber, label)` over `unitload_record` with `activitycode='RETURN'` and any recordtype, restricted to the window's position numbers.
    - `co`: `DISTINCT ON (externalnumber)` over customerorder for the merchant order number. It has no client match, following the V2.2.25 `rco` precedent.
  - Joins and output rules:
    - The UL is joined by FK `goodsreceiptposition.unitload_id`.
    - The label is output with `-X-[0-9]+$` stripped, and `ur` is joined on the stripped label.
    - `adviceposition` and `goodsreceiptposition` are LEFT JOINed.
    - The ORDER BY is fixed.
  - The `countQuery` has no `unitload_record`, no `customerorder` and no 1:1 joins.
  - Projection: `repo/projection/ReturnsAuditView`. It has the 10 required getters plus `adviceExternalId`, `adviceState`, `adviceCreated`, `clientNumber`, `goodsreceiptNumber`, `positionExternalId`, `itemNumber`, `notifiedAmount`, `notifiedDamagedAmount` and `receivedAt`. Timestamps are `Object`, as in `AdviceNoticeView`.
  - `ViewDtoService.getReturnsAudit` returns `{content, totalElements}`.
  - Handler: `ReportController` `GET /returnsAudit`, with method-level `@RequiresFunction(WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW)`.
    - Parameters: `from` and `to` (ISO date-time), `page`, `size`, and an optional `clientNumber`.
    - It calls `checkPageBounds` and rejects `from >= to` with a 422.
    - It uses unsorted `PageRequest.of(page, size)`.
- **S1:** `goodsreceiptTemp.setReceiptdate(LocalDateTime.now(ZoneOffset.UTC))`, only on the create branch.
- **S2:** `markFinished` now does `findById` → `setState(FINISHED)` → `saveAndFlush`, then the unchanged position bulk update. The advice is written first, because the bulk update's `clearAutomatically` would otherwise evict it. A missing advice throws `EntityNotFoundException`. `updateAdviceToStateById` is kept, with zero callers; the gate tests reference it.
- **S3:**
  - `AutoReceiveLine` gained a trailing `String number`, taken from the persisted position in `bind()`. This avoids an extra lookup.
  - `applyDamage` → `setLockDamaged(..., principal, orderNumber)`, a new overload. The 5-arg form delegates `null`.
  - That calls `moveStockToNewDamagedContainer(..., comment, orderNumber)`, which now has 7 args, and then `transferStockToUnitLoad`.
- **S8:** `ReceivingService.finishReturnAdviceIfComplete(advice)` runs after the receive loop's catch.
  - It applies only to RETURN advices that have at least one position.
  - It uses `findByAdviceId` + `findByAdvicepositionIdIn` and sums only non-null amounts. `grp.amount` is nullable and `Map.merge` rejects null.
  - The completion test is `>= notifiedamount`, with a null notified amount counting as not complete.
  - On completion it sets FINISHED and saves the entity for each position and for the advice (`save`). It never uses the bulk update.
  - There is no new repository or service method and no advice-row lock.

### Existing tests retargeted (as the gate baseline anticipated, with no assertion loosened)

- **`ReturnAdviceAutoReceiveServiceUnitTest`**
  - 11 `updateAdviceToStateById` verifies were retargeted:
    - Positive checks became `saveAndFlush(argThat(id==1 && FINISHED))`.
    - `never()` checks became `never().saveAndFlush(any())`.
  - The 2 gate tests that themselves assert `never().updateAdviceToStateById` were left untouched.
  - In `setUp`, lenient `findById(1L)` / `saveAndFlush` stubs were added; `markFinished` is now a precondition read.
  - The `setLockDamaged` stubs and verifies moved to the 6-arg overload. The two `never()` checks keep the 5-arg form and add the 6-arg form.
  - The `AutoReceiveLine` fixtures pass `IBOL012604-%06d`, so line 1 is `IBOL012604-000000`, as the gate note required.
- **`FileImportControllerUnitTest`, `AdviceRestControllerUnitTest`:** the old `never()` was kept, and `never().saveAndFlush(any())` was added.
- **`moveStockToNewDamagedContainer` 6→7 arg sites** in `StockunitServiceUnitTest` (×6), `StockunitServiceAuditCommentClampUnitTest` (×2), `StockunitServiceParcelSourceRefusalUnitTest` (×5) and `UnitloadServiceUnitTest` (×3):
  - Strict stubs and verifies on the manual path use `isNull()`.
  - Lenient stubs and `never()` checks use bare `any()`.
  - Direct calls pass `null`.
- **`NeverMatcherNullBlindnessArchTest`:** the inventory for `ReturnAdviceAutoReceiveServiceUnitTest` went from 7 to 9. The two new `never()` on the overload carry `anyBoolean()` on the primitive `boolean printLabel`. I read the declaration before changing the count.

## Per-test-class results (final full run, `clean verify -Pci`)

| Class | Run | Fail |
|---|---|---|
| ReceivingServiceUnitTest (all nested) | 64 | 0 |
| ReturnAdviceAutoReceiveServiceUnitTest | 89 | 0 |
| StockunitServiceDamagedOrderNumberUnitTest | 2 | 0 |
| UnitloadServiceUnitTest | 110 | 0 |
| ReportReadGateUnitTest | 12 | 0 |
| ReturnsAuditQueryContractUnitTest | 5 | 0 |
| Sbdev3017TrancheGateContextTest | 5 | 0 |
| StockunitServiceUnitTest / AuditCommentClamp / ParcelSourceRefusal | 113 / 13 / 43 | 0 |
| StockUnitControllerUnitTest / FileImportControllerUnitTest / AdviceRestControllerUnitTest | 84 / 48 / 76 | 0 |
| ReturnsAuditQueryIntegrationTest (PG 14) | 18 | 0 |
| TransactionDetailReturnOrderRefsIntegrationTest (PG 14) | 10 | 0 |
| StockunitDamagedRollbackIntegrationTest (PG 14) | 1 | 0 |
| Context-load smoke (`*ContextLoadTest`), SurfaceInventory, SdrUncalledSurfaceNotExported, SdrMutatingSearchNotExported | 6 + 1 + 3 + 1 | 0 |
| All `*ArchTest` + `PostgresTestHarnessPinTest` + `TestIdentifierCount*` | 143 | 0 |

`mvn clean compile` passes (rc=0).

### Throwaway Spring Data smoke test (not committed)

The gate IT runs the SQL through `NamedParameterJdbcTemplate`, so Hibernate binding, paging and projection mapping had no proof. I ran a throwaway `BasePostgresIntegrationTest` subclass that seeded one return and called `findReturnsAudit` through the real repository and `ViewDtoService`.

- It passed with `clientNumber` set to `null`, to `""` and to a value, and with page size 1. `totalElements` was correct.
- Projection binding worked with the lowercase aliases.
- `receivingCompletedAt` arrives as `java.time.Instant`.
- I deleted the file afterwards; a copy is in the session scratchpad.
- **Suggestion:** commit an equivalent as a permanent IT. It is the only test that crosses the Hibernate native-query and projection seam.

## Mutation results

### PIT (scoped per class, JDK 21; mutants on lines this ticket changed)

| Class | Mutants on changed lines | Killed | Notes |
|---|---|---|---|
| ReceivingService | 12 | 12 | All attributable to the S1/S8 tests. The REGULAR, position-less and partial guards each kill their own negated conditional, and the `>=` boundary is killed. |
| ReturnAdviceAutoReceiveService | 2 | 1 | `setState` removal was killed by `markFinished_shouldSaveAdviceEntityAsFinished`. The not-found lambda was NO_COVERAGE; it is closed below as J9. |
| StockunitService | 1 | 1 | |
| UnitloadService | 0 | 0 | PIT cannot mutate argument passing; the change is covered by hand mutant J4. |

Whole-class scores, for context and mostly pre-existing code: Receiving 88/184, AutoReceive 98/125, Stockunit 132/188, Unitload 130/145.

### Hand mutants, Java

PIT does not reach argument swaps or the removal of a non-void call. Method: copy the file to the scratchpad, edit it, run the 5 test classes, then copy it back.

| # | Mutant | Result | Killing test / message |
|---|---|---|---|
| J1 | `line.number()` → `line.positionExternalId()` | KILLED | applyDamage_shouldPassAdvicePositionNumber… "S3: orderNumber … must be the position NUMBER" |
| J2 | `now(ZoneOffset.UTC)` → bare `now()` | KILLED | receiveGoods_shouldStampUtcReceiptdate… "not the JVM default zone (UTC+14 …)" |
| J3 | overload passes `null` to the damaged move | KILLED | setLockDamaged_shouldPassOrderNumberToDamagedMove… "S3: the orderNumber must reach the damaged move" |
| J4 | helper passes `null` to `transferStockToUnitLoad` | KILLED | moveStockToNewDamagedContainer_shouldForwardOrderNumber… "S3: the damaged transfer's stockrecord rows …" |
| J5 | 5-arg delegates `comment` instead of `null` | KILLED | setLockDamaged_shouldPassNullOrderNumber… "the 5-arg form must delegate null"; also 5 strict-stub mismatches |
| J6 | `saveAndFlush(advice)` removed from `markFinished` | KILLED | markFinished_shouldSaveAdviceEntityAsFinished: "Wanted but not invoked: adviceRepository.saveAndFlush"; 7 retargeted tests also red |
| J7 | S8 `adviceRepository.save(advice)` removed | KILLED | receiveGoods_shouldFinishReturnAdviceViaEntitySave… "FINISHED must be written through the ENTITY" |
| J8 | S8 per-position `save` removed | **SURVIVED → closed** | New `receiveGoods_shouldSaveEveryPositionEntity_whenReturnAdviceCompletes`: "Wanted but not invoked: advicepositionRepository.save(…)" |
| J9 | `orElseThrow` → `orElseGet(Advice::new)` in `markFinished` | **NO_COVERAGE → closed** | New `markFinished_shouldThrowAndLeavePositionsAlone_whenAdviceIsMissing`: "Expecting code to raise a throwable" |

### Hand mutants, native SQL

PIT cannot reach native SQL. Method: copy `AdvicepositionRepository.java`, edit it, run `ReturnsAuditQueryIntegrationTest`, then copy it back. Each anchor count was asserted before the edit.

| # | Mutant | Result | Killing test / message |
|---|---|---|---|
| M1 | `activitycode='RETURN'` → `recordtype='TRANSFERRED'` | KILLED | (3) …PutawayRowIsTheSecondCreatedRow "any recordtype (R2-1) …" |
| M2 | `ur` joined on the unstripped label (`ur.label = u.labelid`) | KILLED | (1) …KeepPutawayDestination… "unitload_record keeps the ORIGINAL label; ur.label = u.labelid would blank this" |
| M3 | label strip dropped from the output | KILLED | (1) …ReportStrippedLabel… "join the UL by FK … and strip '-X-[0-9]+$'" |
| M4 | RETURN type filter dropped (value + count) | KILLED | (7) …TypeIsNotReturn "REGULAR advice IBOL973608" |
| M5 | `LEFT JOIN adviceposition` → INNER | KILLED | (2) both A2 tests: "A2 must produce exactly one audit row … was: 0" |
| M6 | completion read from `advice.state` | KILLED | (2)/(6) three tests: "invariant needs >= 1 position", A6, A7 |
| M7 | `bool_and` → `bool_or` | **SURVIVED → closed** | New A10 fixture + `returnsAudit_shouldReportNoCompletion_whenOnlySomePositionsAreFullyReceived` (row dump shows `fullyreceived=true`) |
| M8 | upper bound dropped | **SURVIVED → closed** | New A11 (created == `to`) + `returnsAudit_shouldExcludeAdvice_whenCreatedExactlyAtTheUpperBound` "[from, to): created == to … is outside the window" |
| M10 | `< :to` → `<= :to` | KILLED (by the new A11 test) | same message as M8 |
| M9 | `DISTINCT ON` dropped from `ur` | **SURVIVED → closed** | New A12 (put-away recorded twice) + `returnsAudit_shouldKeepOneRowPerUnitLoad_whenThePutawayIsRecordedTwice` "must be DISTINCT ON (ordernumber, label) …"; the countQuery agreement test also goes red |

Mutant "join the UL by label instead of FK": there is no label column on `goodsreceiptposition` to join the UL on, so I took this to mean the `ur` label join, which is M2. M3 covers the output side.

**All 4 survivors and the 1 NO_COVERAGE were closed with additive tests only.** New fixture rows only add new advices, and no existing assertion changed. Each closing test was re-run against its mutant and confirmed red with an attributable message (round 2).

## Full suite vs baseline

The command is the one CI ran at the base commit: `mvn -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` (`-o` locally).

| Lane | Baseline: CI run 38667148714 @ 371d8a09 | Branch @ 666fe51a | Delta |
|---|---|---|---|
| Surefire (unit) | 8264 run, 0 F, 0 E, 1 skip | 8288 run, 0 F, 0 E, 1 skip | +24 |
| Failsafe (IT) | 842 run, 0 F, 0 E, 23 skip | 861 run, 0 F, 0 E, 23 skip | +19 |

Per-class reconciliation (CI log `-- in` lines vs the local log) shows the delta is exactly the new tests:

- **Unit (+24):**
  - ReportReadGate +3
  - ReturnsAuditQueryContract +5
  - ReceivingServiceUnitTest$ReceiveGoods +8 (7 gate + 1 mine)
  - RAAR$Execute +4 (3 gate + 1 mine)
  - RAAR$FollowUpRegression +1
  - StockunitServiceDamagedOrderNumber +2
  - UnitloadService$MoveStockToNewDamagedContainerBoundary +1
- **IT (+19):** ReturnsAuditQueryIntegrationTest +18 (15 gate + 3 mine) and TransactionDetailReturnOrderRefs +1.

There are no other per-class changes, and BUILD SUCCESS.

## Landmines / notes

- **Changing a test assertion requires a fresh compile before mutation runs.** The hand harness relies on `mvn test`/`verify` recompiling the restored source. A copy-restore bumps the mtime, so it does recompile. The final full run was `clean`, so no mutant bytecode survived.
- **Mutation harness exposure on the IT seam.** The gate IT executes the SQL text off the annotation through JDBC. It is blind to anything Hibernate or Spring Data does: parameter binding, the appended `offset/fetch`, and projection alias binding. The throwaway smoke test above covered that seam once; see the suggestion above.
- **Performance.** `ur` scans `unitload_record` filtered by `ordernumber IN (window's positions)`. Per the gate contract there is no index on `ordernumber`, so every page is one sequential scan of about 6.8M rows on WineCo PRD. That is accepted per the consult and report (R2-3). ~~`co` is one scan of `customerorder` filtered by `externalnumber IN (…)`, which is also unindexed.~~ **Corrected (review r1 L5):** `customerorder.externalnumber` has the UNIQUE index `index_customerorder_externalnumber`, which serves the `IN (…)`.
- ~~**Merchant order lookup has no client match,** following the V2.2.25 `rco` precedent. If two clients share an `externalnumber`, the lowest `customerorder.id` wins.~~ **Corrected (review r1 L5 / security L3):** two clients cannot share an `externalnumber` — it is UNIQUE per tenant DB (present on WineCo, Hydra, ShipItEZ NY and ShipItEZ C1 PRD, checked 2026-10-15). The lookup now also matches `co.client_id = adv.client_id` and drops the redundant `DISTINCT ON`; see `fixes-r1.md`.
- **S8 behaviour changes stated in the consult still apply:**
  - Dock completion now closes the `adjust` correction window for RETURN advices.
  - A concurrent last-two-positions receive can leave an advice OPEN; the audit's `fullyReceived` flags it.
- **Nothing stopped me.** No new repository or service method was needed beyond `findReturnsAudit` and the planned `setLockDamaged` overload. No `findByIdForUpdate` was added and there is no Flyway change.
- **The independent review lane (floor item 4) has not been run;** it is the orchestrator's next step.
