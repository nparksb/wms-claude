---
title: SBDEV-3736 — independent code review, round 1
ticket: SBDEV-3736
lane: code-reviewer
date: 2026-10-15
head: 666fe51a
base: origin/develop 371d8a09
worktree: .claude/worktrees/wms2-api/SBDEV-3736 (branch feature/SBDEV-3736-returns-audit-linkage)
verdict: COMMENT
counts: { high: 0, medium: 3, low: 10 }
---

# SBDEV-3736 — code review r1 (A, S1, S2, S3, S8)

The review was read-only. No Maven or jdtls ran in the worktree, because another lane may share it and concurrent runs give false reds. I took compile and suite evidence from the implementer's `clean verify -Pci` run (8288/861 green). DB facts come from read-only queries against **WineCo PRD** (`wsl-wineco-prd`) and **Hydra PRD**, run on 2026-10-15.

## Stage 1 — spec / design conformance

| Item | Verdict |
|---|---|
| A — endpoint, native set-based query, method-level gate on `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`, both prefixes pinned | Conforms to consult §1: unsorted Pageable, fixed ORDER BY, `ur` kept out of countQuery, safe `= ''` arm, LEFT JOIN position, stripped label on both output and join |
| A — field coverage vs report §7 | **Partial**: field 9 (receiving user, `goodsreceiptposition.operator_id`) and the carrier parcel id (`customerorder.parcelexternalnumber`, field 3) are not projected (M3) |
| S1 | Conforms. `LocalDateTime.now(UTC)` is correct under `hibernate.jdbc.time_zone=UTC` (`application.properties:186`) |
| S2 | Conforms (entity `saveAndFlush`, then the shared position bulk update) |
| S3 | Conforms. The only `getOrdernumber()` consumer that branches on the value is `UnitloadBusinessService.classify:780` (`startsWith("GRP")`), and `IBOL…` cannot match it. `transaction_detail` gains order_number/transaction_number on DAMAGED rows, as decision 4 accepted |
| S8 | Placement and mechanism conform to consult §5. **One design premise in §5 risk 2 is false** (M1), and one requested javadoc note is missing (L2) |

## Findings

### [MEDIUM] M1 — S8 closes the adjust window on the most likely mis-key, because RETURN advices allow over-delivery
- **Files:** `src/main/java/net/aim_ai/wms/service/ReceivingService.java:607` (`finishReturnAdviceIfComplete(advice);`) together with `controller/rest/AdviceRestController.java:285` (`adviceEntity.setAllowoverdelivery(true);`)
- **Confidence:** HIGH on the facts. The severity depends on Nam's call.
- **Evidence:** Consult §5 risk 2 says: *"Over-receipt is impossible with `allowoverdelivery=false` … so 'complete' is reachable only by exactly-notified totals."* That is false for RETURN advices. On WineCo PRD, `select type, allowoverdelivery, count(*) from advice` returns `RETURN | true | 2822` and no RETURN row with `false`. The `ReceivingService:411` over-delivery guard is therefore skipped for every RETURN advice.
- **Failure scenario:** A dock operator receives the last open position of a RETURN advice and keys 50 instead of 5.
  - The `>=` test is satisfied, so S8 flips the advice and every position to FINISHED in the same transaction.
  - `GoodsReceiptPositionService.checkAndGetGoodsReceiptPosition` refuses both adjust and delete unless the advice is `OPEN` (`"Advice in state=… expected=OPEN"`).
  - Before S8 the advice stayed OPEN and the receipt could be corrected. Now it can be fixed only at stock level (manage inventory), and the over-keyed RETURN `StockChangeDto` has already gone to OMS.
  - The consult accepted the closed window on the premise that only exact totals complete an advice. With over-delivery allowed, the closed window catches exactly the over-key.
- **Fix:** This is escalation trigger (3): it disputes the design, not the code. Nam has to choose one of:
  - (a) accept it, and state the corrected premise in the PR and consult;
  - (b) allow `adjust`/`delete` on a FINISHED **RETURN** advice, re-opening it, or re-running the finisher after the adjust;
  - (c) set `allowoverdelivery=false` on new RETURN advices. That is a contract change to the OMS create path.

  Whatever the choice, correct the consult §5 risk 2 sentence.

### [MEDIUM] M2 — no committed test crosses the Spring Data / Hibernate seam, and the client filter is never exercised
- **Files:**
  - `src/test/java/net/aim_ai/wms/integration/ReturnsAuditQueryIntegrationTest.java:318-336` (`params(...)` always binds `client = null`; `rows()` runs the `@Query` text through `NamedParameterJdbcTemplate`)
  - `src/main/java/net/aim_ai/wms/repo/jpa/AdvicepositionRepository.java:108`
  - `src/main/java/net/aim_ai/wms/service/ViewDtoService.java:1044`
- **Confidence:** HIGH.
- **Issue:** No committed test covers any of the following:
  - Hibernate binding of `OffsetDateTime` and of a null or `''` `String` in a native query;
  - the `offset/fetch` that Hibernate appends to a CTE statement;
  - interface-projection binding of the lowercase PG aliases (`adviceid` → `getAdviceId`);
  - `toDate` on the actual runtime type;
  - the `totalElements`/page split.

  The client arm `(c.cl_nr = CAST(:clientNumber AS text) OR … IS NULL OR … = '')` is executed in no committed test with a value or with `''`. A mutant that drops the client predicate, or turns `=` into `<>`, survives the whole suite. The ArchUnit rail checks only the arm's shape.

  The implementer's throwaway smoke test proved all of this once (implementation-report §"Throwaway Spring Data smoke test", which passed for `null`, `""`, a value and page size 1) and then was not committed. A Spring Data or Hibernate bump is exactly what would break this seam silently.
- **Fix (must close before PR):** Commit that smoke test as a permanent `BasePostgresIntegrationTest` IT that calls `ViewDtoService.getReturnsAudit` through the real repository. Assert:
  - with a second client's RETURN advice in the window: (i) `clientNumber=null` and `""` return both clients' rows, and (ii) `clientNumber=<A>` returns only A's rows, with a matching `totalElements`;
  - with size 1, page 0 and page 1 give disjoint rows with the same `totalElements`;
  - `adviceCreated` and `receivingCompletedAt` are non-null `Date`s equal to the seeded instants.

  Mutation-check the client arm against it.

### [MEDIUM] M3 — report §7 fields 9 (receiving user) and 3 (carrier parcel id) are not projected
- **File:** `src/main/java/net/aim_ai/wms/repo/projection/ReturnsAuditView.java` (whole interface). The SELECT list is at `AdvicepositionRepository.java:135-143`.
- **Confidence:** MEDIUM. The consult gives no explicit column list, and the gate's REQUIRED_GETTERS omit both fields, so this may be intended scope.
- **Issue:** The field map rates both fields class (a), WMS-available:
  - field 9: `goodsreceiptposition.operator_id`, the system user (`mywms_user.name`);
  - field 3: carrier id via `customerorder.parcelexternalnumber`.

  Neither appears in the audit row. Both are 1:1 joins that would not change the countQuery: `operator_id` is a FK to one user, and `co` is unique per parcel (see L5).
- **Fix:** Add `ru.name AS receivedBy` (via `LEFT JOIN mywms_user ru ON ru.id = g.operator_id`) and `co.parcelexternalnumber AS carrierParcelId`. Alternatively, record in the plan/PR that they are deliberately out of scope.

### [LOW] L1 — S8 javadoc's "only writer" claim is false, so the invariant is not enforced on the other writer
- **File:** `ReceivingService.java:658` (`This method is the only writer of {@code goodsreceiptposition}`)
- **Confidence:** HIGH.
- **Issue:** `GoodsReceiptPositionService.adjust:111` also writes `goodsreceiptposition.amount`, with no upper bound on `newAmount`. Adjusting a receipt up on an OPEN RETURN advice can make every position complete without finishing the advice. That reproduces the S8 latent state through a path S8 does not hook. `receiveGoods` is the only *creator*, not the only writer.
- **Fix:** Reword the javadoc to "only creator", and name `adjust` as a known non-finishing writer. Optionally make the finisher package-visible and call it from `adjust` (that touches another service, so weigh it against tier).

### [LOW] L2 — consult-requested javadoc note on the auto-path optimistic-lock misreport is missing
- **File:** `ReceivingService.java:654-668`
- **Confidence:** HIGH.
- **Issue:** Consult §5 risk 3 says an `ObjectOptimisticLockingFailureException` from the finisher on the auto path's last line is caught by `executeInternal`'s `RuntimeException` arm and misreported as PARTIAL, *"Acceptable, but note it in the javadoc."* The javadoc mentions the lost-finish race but not this.
- **Fix:** Add one sentence to the S8 javadoc, or to `ReturnAdviceAutoReceiveService.executeInternal`'s catch comment.

### [LOW] L3 — over-delivery also undermines the race analysis: possible deadlock on a complete-but-OPEN advice
- **File:** `ReceivingService.java:689-692` (`for (Adviceposition position : positions) { position.setState(FINISHED); advicepositionRepository.save(position); }`)
- **Confidence:** MEDIUM. Reasoned, not reproduced.
- **Issue:** Consult risk 1 ("two finishers would each need to see the other's uncommitted row") assumes exact totals. Suppose an advice already has every position complete but is still OPEN, which the lost-finish race or legacy data can produce. Two concurrent over-receipts on different positions A and B then both see "complete":
  - T1 holds `FOR UPDATE` on A (`:383`) and saves B;
  - T2 holds B and saves A;
  - PostgreSQL raises 40P01 and one receive rolls back. Otherwise, if the transactions serialise, one gets an `@Version` clash on the advice.

  The SBDEV-3615 controller mapping covers the optimistic-lock case but not a deadlock.
- **Fix:** Skip positions already FINISHED and save in ascending id order. That narrows the window but does not close it. Otherwise accept the risk and document it next to risk 1. The real fix, an advice-row lock, is escalation trigger (2), as the consult says.

### [LOW] L4 — SQL `fullyReceived` and the Java S8 invariant disagree on a NULL `notifiedamount`
- **Files:** `AdvicepositionRepository.java:119` (`bool_and(received >= notifiedamount)`) vs `ReceivingService.java:684` (`p.getNotifiedamount() != null && …`)
- **Confidence:** HIGH on semantics. The population is 0: WineCo PRD has 0/10,173 RETURN and 0/43,252 REGULAR positions with a NULL `notifiedamount`.
- **Issue:** `bool_and` ignores NULL inputs. An advice with one full position and one NULL-notified position reports `fullyReceived = true`, while S8 treats the same advice as incomplete. The audit is supposed to be the detection flag for S8's lost finishes, so the two should agree.
- **Fix:** `bool_and(coalesce(received >= notifiedamount, false))`, plus one IT fixture row.

### [LOW] L5 — `co` DISTINCT ON is redundant, and the "cross-client leak" concern is moot
- **File:** `AdvicepositionRepository.java:129-134`
- **Confidence:** HIGH.
- **Issue:** `customerorder.externalnumber` is **UNIQUE** per tenant DB (`V2.2.00__base_v2_schema.sql:3308`, `ADD CONSTRAINT index_customerorder_externalnumber UNIQUE (externalnumber)`; present on WineCo PRD). So "lowest id wins across clients" cannot happen. Measured on WineCo PRD: 2,822 RETURN advices, 0 with >1 matching order, 0 matched to another client's order. On Hydra PRD: 0 cross-client externalnumbers. The implementation report is also wrong on two points:
  - "If two clients share an externalnumber" cannot happen;
  - "`co` … is also unindexed" is false, since the UNIQUE index serves `IN (…)`.
- **Fix:** Simplify to `LEFT JOIN customerorder co ON co.externalnumber = adv.parcel_id`. Optionally add `AND co.client_id = adv.client_id` as belt-and-braces. Correct the two report bullets.

### [LOW] L6 — retargeted never() sites replaced, rather than kept alongside, the bulk-update negative
- **File:** `src/test/java/net/aim_ai/wms/unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java`, hunks at old `:760`, `:814`, `:1185`, `:1245`, `:1446`
- **Confidence:** MEDIUM.
- **Issue:** `never().updateAdviceToStateById(eq(FINISHED), any())` became `never().saveAndFlush(any())`. Two things limit the risk:
  - a dedicated test (`markFinished_shouldNotUseBulkAdviceStateUpdate_whenCalled`) pins the bulk call away inside `markFinished`;
  - most sites keep the position bulk `never()`.

  But if some other path regressed to `updateAdviceToStateById` on a PARTIAL or SKIPPED path, the edited sites would no longer see it. The `FileImportControllerUnitTest:1145` and `AdviceRestControllerUnitTest:595` edits did the stronger thing and **added** the `saveAndFlush` negative next to the old one.
- **Fix:** Keep both `never()` lines at each retargeted site, as the two controller tests do.

### [LOW] L7 — the S8 × markFinished interplay on the auto path has no test
- **Files:** `ReturnAdviceAutoReceiveService.java:878` and `ReceivingService.java:607`
- **Confidence:** HIGH that the gap exists. The behaviour reads correct: the advice is FINISHED by the last `receiveGoods`, then `markFinished` is a no-op dirty-check followed by the position bulk update.
- **Issue:** The RAAR tests mock `receivingService`, and the `ReceivingService` tests mock the repositories. Nothing proves that a full auto-receive ends with the advice FINISHED once, `modified > created`, and no optimistic-lock clash between the two finishers.
- **Fix:** One Postgres IT through `execute()` with a 2-position plan. Assert `advice.state`, `modified`, `version` and both positions FINISHED.

### [LOW] L8 — the S3 IT seeds the post-S3 stockrecord by hand
- **File:** `TransactionDetailReturnOrderRefsIntegrationTest.java` (AC-10 fixture, `stockrecord(st, 9548L, SKU_DAMAGED, "DAMAGED", "STOCK_CREATED", …, "IBOL000841-000002", …)`)
- **Confidence:** HIGH.
- **Issue:** AC-10 proves that the resolver handles the new shape. Each hop that produces the shape (`applyDamage` → `setLockDamaged` → `moveStockToNewDamagedContainer` → `transferStockToUnitLoad` → `createStockUnit`/`recordTransferStockUnit`) is proven only with mocks, so no test shows that a real damaged return writes `stockrecord.ordernumber`.
- **Fix:** Optional. Fold it into the L7 IT by giving one line `damagedAmount > 0` and asserting that the DAMAGED `STOCK_CREATED` row carries the position number.

### [LOW] L9 — no bound on the `[from, to)` window; every page is a full `unitload_record` scan plus a count
- **File:** `ReportController.java:433-443`
- **Confidence:** HIGH.
- **Issue:** The `ur` CTE measured 0.41 s for a 30-day window on WineCo PRD (`unitload_record` reltuples 6,805,807, no `ordernumber` index). That is acceptable. But `from=1970…&to=2100…` with the max page size runs the all-time join on every page request. The consult and report accept the scan (R2-3), and nothing caps the range.
- **Fix:** Optional. Reject windows over N days (e.g. 366), or note the accepted cost in the javadoc.

### [LOW] L10 — controller edge cases are untested
- **File:** `ReportController.java:440-442`
- **Confidence:** HIGH.
- **Issue:** No test covers `from >= to` → 422 (`ApiInvalidParameterException`), a missing `from`/`to`, or an offset form. `+02:00` must be sent URL-encoded as `%2B02:00`, because a raw `+` decodes to a space and gives a 400. `ReportReadGateUnitTest` covers only the 403 paths, and there is no positive "holder gets 200" case for `/returnsAudit`.
- **Fix:** Add a `from == to` → 422 case and a holder → 200 case to `ReportReadGateUnitTest`.

## Checked and clean

- **countQuery vs content.** Every extra join in the content query is at most 1:1 per `(adv, ap, g)` row:
  - `itemdata`, `goodsreceipt` and `unitload` by FK;
  - `adv_rcv` per advice;
  - `ur` by DISTINCT ON;
  - `co` by DISTINCT ON and also the UNIQUE constraint.

  Both statements share an identical `adv` CTE, so totals match under every filter value.
- **Paging stability.** `ORDER BY adv.created DESC, adv.id, ap.id, g.id` is a total order. `ap.id` is NULL only on the single row of a position-less advice, and `g.id` is NULL only on the single row of an unreceived position.
- **Timezones.** `advice.created`, `goodsreceiptposition.created` and `unitload_record.created` are all `timestamp with time zone` on PRD, and binding `OffsetDateTime` preserves the instant.
- **`unitload_record` shapes on PRD.** Every `(ordernumber, label)` with `activitycode='RETURN'` has exactly one row (12,452 CREATED-only and 7,894 TRANSFERRED-only), so DISTINCT ON never has to choose on PRD today. The S3 SEND_TO_NIRVANA/DAMAGED records carry `activitycode` `DAMAGED`/`SEND_TO_NIRVANA`, never `RETURN`, so they cannot pollute `ur`.
- **Projection aliases.** `AdviceNoticeView` (`AdviceRepository:115/145`) is a production precedent for camelCase aliases on `Page<interface>` native queries.
- **`toDate`.** `ViewDtoService:180` handles `Date`, `Instant`, `OffsetDateTime` and `LocalDateTime`.
- **S2.** `markFinished` runs in its own transaction after `receiveGoods` committed, so `findById` reads the fresh version and there is no stale-version save. Reading the advice before the position bulk update's `clearAutomatically` is the correct order.
- **S8 transactional placement.** It runs inside `receiveGoods`'s tenant transaction, after the receive loop, using entity saves only, so the SBDEV-3615 carrier write cannot be discarded. `findByAdvicepositionIdIn` is JPQL, so AUTO flush includes this call's new `grp` rows. REGULAR, TRANSFER and HUB_AND_SPOKE return at the type guard.
- **S1.** `receiptdate` is set only on the create branch (the guard test pins no re-stamp), and `new Goodsreceipt()` has a single site.

## Positive observations

- Gate discipline:
  - the gate is method-level, with a comment explaining why;
  - it is pinned on both prefixes in `Sbdev3017TrancheGateContextTest` (227 → 229, with the delta explained);
  - it is backed by a request-level 403 on each prefix.
- The IT grades the shipped `@Query` text read off the annotation rather than a copy. Its fixture covers every shape the field map warned about: relabelled UL, position-less advice, 2025 CREATED shape, fan-out, a duplicate put-away record, and the half-open bound. The mutation-pass additions (A10–A12) each pin one variable.
- `isNull()` replaced `any()` on the manual "Transfer To Damaged" stubs and verifies, so the 5-arg path is now proven to pass a null `orderNumber`.
- The S1 test moves the JVM zone to UTC+14 to make a bare `now()` fail. That is a good adversarial fixture.

## Recommendation

**COMMENT** (no High at HIGH confidence).
- **M2** must be closed before the PR: commit the Spring-seam IT and mutation-check the client arm.
- **M1** needs Nam's decision, because it disputes a consult premise (escalation trigger 3). Do not resolve it inside the executor lane.
- **M3** needs a scope confirmation.
- The Lows are cheap, and per the house rule they get fixed in the same pass.
