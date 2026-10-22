---
title: SBDEV-3736 — review r1 fixes (code M1–M3, L1–L10; security L1–L3)
ticket: SBDEV-3736
lane: executor
date: 2026-10-15
worktree: .claude/worktrees/wms2-api/SBDEV-3736 (branch feature/SBDEV-3736-returns-audit-linkage)
base_head: 666fe51a
head: a538785e (not pushed)
---

# SBDEV-3736 — review r1 fixes

## Commits (on top of 666fe51a)

| SHA | Findings | Subject |
|---|---|---|
| e095df5c | code M1, L1, L2, L3, L4 (Java) | fix(receiving): finish a RETURN advice only on an exact match per position |
| 339da0fc | code M3, L4 (SQL), L5 · security L3 | fix(report): returns audit - receiving user, carrier parcel id, exact completion, client-scoped order |
| dab72eeb | code M2 | test(report): returns audit through Spring Data and Hibernate on PostgreSQL |
| 889da101 | code L9, L10 · security L1, L2 | fix(report): cap the returns audit window at 366 days |
| c9e05f29 | code L6 | test(returns): keep the bulk-update never() beside the entity-save negative |
| a538785e | code L7, L8 | test(returns): auto-receive finishes once and stamps the damaged order number |

The sbdocs side, outside git, was also edited:
- `architect-consult.md` §5 risk 2: the false "over-receipt is impossible" sentence is struck through and the correction is recorded.
- `implementation-report.md`: the two L5 bullets are corrected.

## Per finding

Mutation method:
- Hand mutants only, run with `scratchpad/r1mut.py`.
- For each mutant, the source file is copied to the scratchpad, edited with the anchor count asserted, and the named class or classes are run (`mvn -o test`/`verify`, JDK 21). The file is then restored by copy.
- `git diff | sha1sum` matched before and after the whole run (`baf94cdd…`).
- Logs are at `scratchpad/r1mut-<id>.log`.

### Code M1: S8 finishes on an EXACT match (Nam's decision) · e095df5c
- **Change:** `ReceivingService.finishReturnAdviceIfComplete` now completes only when `compareTo(notifiedamount) == 0` on every position. It used to accept `>= 0`.
- **Javadoc:** it now states the over-delivery premise and why the match must be exact. The premise is that `AdviceRestController` sets `allowoverdelivery=true` on every RETURN advice; WineCo PRD has 2,822 of 2,822 such advices.
- **Tests:** in `ReceivingServiceUnitTest$ReceiveGoods`:
  - `…shouldFinishReturnAdvice_whenEveryPositionIsReceivedExactly`: 5/5 + 5/5 → FINISHED.
  - `…shouldLeaveReturnAdviceOpen_whenEveryPositionIsOverReceived`: 50/5 + 6/5 → OPEN, nothing saved.
  - `…shouldLeaveReturnAdviceOpen_whenOnePositionIsExactAndAnotherIsOverReceived`: 5/5 + 6/5 → OPEN, no position finished.
- **Mutant K1** (`== 0` → `>= 0`): **KILLED** by both OPEN tests.
  - "M1: 50 of 5 and 6 of 5 is an OVER-key, not completion — finishing on >= would close the advice…"
  - "M1: 5 of 5 (exact) with 6 of 5 (over) is not an exact match on EVERY position…"
- **DB fact:** WineCo PRD has 0 over-received RETURN positions today, so the change alters no current data.

### Code L1: "only writer" javadoc · e095df5c
- **Change:** the javadoc now says `receiveGoods` is the only *creator*.
- It also names `GoodsReceiptPositionService.adjust` as a writer that does not finish. An over-key adjusted back down to exactly the notified amount leaves the advice complete but OPEN. The audit flags that case with `fullyReceived=true` and `adviceState=OPEN`.
- Calling the finisher from `adjust` is **not** done; see "Not fixed".
- Javadoc only, so there is no mutant.

### Code L2: auto-path optimistic-lock misreport · e095df5c
- **Change:** one javadoc paragraph on S8. A finisher OL failure on the auto path's last line is caught by the per-line `RuntimeException` arm and reported as PARTIAL. The advice stays OPEN and dock-receivable. This is accepted per consult §5 risk 3.
- Javadoc only.

### Code L3: deadlock / race on complete-but-OPEN · e095df5c
- **Analysis (in the javadoc):** exact match removes the double-finisher window.
  - Every receive adds at least 1 unit (`amountBottles >= 1`) to a position it holds `FOR UPDATE`.
  - So a receive on an already-exact position over-receives it, and that transaction never sees "complete".
  - For two finishers to run at once, each would need the other's position already exact. The other's own receive would then over-receive it.
- **Hardening, as prescribed:** positions are saved in ascending id order, and already-FINISHED positions are skipped.
- **Tests:**
  - `…shouldSavePositionsInAscendingIdOrder_whenReturnAdviceCompletes` (lookup returns id 11 before id 10; InOrder save 10 then 11).
  - `…shouldNotResaveFinishedPosition_whenReturnAdviceCompletes`.
- **Mutant K2** (drop `.sorted(…)`): **KILLED**. "Verification in order failure / Wanted but not invoked: advicepositionRepository.save(…)".
- **Mutant K3** (drop the FINISHED filter): **KILLED**. "advicepositionRepository.save(…) Never wanted here".

### Code L4: NULL `notifiedamount`, SQL and Java made to agree · e095df5c (Java), 339da0fc (SQL)
- **Choice:** align, rather than keep `>=` as a separately named audit fact.
- **SQL:** `fullyReceived` is now `bool_and(coalesce(received = notifiedamount, false))`, the finisher's exact rule.
  - `fullyReceived && adviceState = OPEN` therefore means exactly "a finish was missed": a lost race, or an adjust back down.
  - An over-received advice now reads `fullyReceived=false` with `receivingCompletedAt=NULL`, matching its OPEN state.
  - The projection, repository and view javadoc say so.
- **Tests:**
  - Java: `…shouldLeaveReturnAdviceOpen_whenAPositionHasNoNotifiedAmount`.
  - JDBC IT: A13, one full position plus one NULL-notified position: `returnsAudit_shouldReportNoCompletion_whenAPositionHasNoNotifiedAmount`.
  - JDBC IT: A14, 3 received against 2 notified: `…_whenAPositionIsOverReceived`.
- **Mutant K4** (Java: NULL counts as complete): **KILLED**. "L4: a NULL notifiedamount cannot be matched…"
- **Mutant S1** (drop `coalesce`): **KILLED** by the A13 test. The row dump shows `fullyreceived=true`.
- **Mutant S2** (`=` → `>=`): **KILLED** by the A14 test. "3 received against 2 notified is an over-key…"

### Code M3: receivedBy + carrierParcelId · 339da0fc
- **SQL:** `LEFT JOIN mywms_user ru ON ru.id = g.operator_id`, then `ru.name AS receivedBy` and `co.parcelexternalnumber AS carrierParcelId`.
- **Projection and DTO:** `ReturnsAuditView` gained `getReceivedBy` and `getCarrierParcelId`, and `ViewDtoService` maps both.
- **countQuery:** unchanged in cardinality. Its `adv` CTE gained only the `a.client_id` column, so it stays identical to the content query's CTE.
- **Tests:**
  - Contract: `REQUIRED_GETTERS` +2, and new `findReturnsAudit_shouldKeepUserAndOrderLookupsOutOfCountQuery_whenDeclared`.
  - JDBC IT (A1): `returnsAudit_shouldReportReceivingUser_whenReceived` and `…ReportCarrierParcelId…`.
  - The Spring IT asserts both, with the grp operator (`returns-clerk`) distinct from the goodsreceipt operator (`anonymous`).
- **Mutants:**
  - **S6** (`g.operator_id` → `gr.operator_id`): **KILLED**. "M3: the goodsreceiptPOSITION's operator — the goodsreceipt's own operator is 'anonymous'".
  - **S7** (`parcelexternalnumber` → `clientordernumber`): **KILLED** by both ITs.
  - **K9** (DTO drops `receivedBy`): **KILLED** by the Spring IT.
  - **S8** (countQuery gains the `mywms_user` join): **KILLED** by the contract test.

### Code L5 / security L3: client-scoped merchant order, DISTINCT ON dropped · 339da0fc
- **Change:** the `co` CTE selects `o.client_id` and `parcelexternalnumber`, and the join adds `AND co.client_id = adv.client_id`.
- **DISTINCT ON:** removed. `index_customerorder_externalnumber` is UNIQUE. I verified its presence on 2026-10-15 on WineCo PRD (`wh01_om1_v2`), Hydra PRD (`wh01_hydra_v2`), ShipItEZ NY PRD (`wh02_shipitez_v2`) and ShipItEZ C1 PRD (`wh01_shipitez_v2`).
- **Tests:**
  - JDBC IT A15 (client B advice; parcel id matches a client A order): `returnsAudit_shouldNotResolveMerchantOrder_whenTheMatchingOrderBelongsToAnotherClient`.
  - Spring IT RB01: `getReturnsAudit_shouldNotResolveAnotherClientsOrder_whenTheParcelIdMatchesIt`.
- **Mutant S3** (drop the client predicate): **KILLED** by both. "customerorder 736015 belongs to client A, the advice to client B — the co join must carry co.client_id = adv.client_id…"

### Code M2: permanent Spring Data / Hibernate IT · dab72eeb
- **New:** `integration/ReturnsAuditRepositoryIntegrationTest` (`BasePostgresIntegrationTest`, rolled back).
  - It goes through `ViewDtoService.getReturnsAudit` and the real `findReturnsAudit`.
  - The window is in 2031, so no committed row from another class can enter it.
- **Fixture:** client A has RA01 (fully received) and RA02 (unreceived); client B has RB01.
- **Five tests:**
  - null and `''` return all 3 rows, ordered `created DESC`, with `totalElements=3`;
  - `RAUDIT-A` → [RA02, RA01] with total 2, and `RAUDIT-B` → [RB01] with total 1;
  - size 1, pages 0–2: disjoint, total 3 each, page 3 empty;
  - every column mapped, with `adviceCreated`, `receivedAt` and `receivingCompletedAt` equal to `Date.from(seeded instant)`;
  - the cross-client order does not resolve.
- **Mutant S4** (client arm → `true OR`, both statements): **KILLED**. "client A's two advices only — client B's RB01 here means the client predicate is dropped".
- **Mutant S5** (`=` → `<>`, both statements): **KILLED** by 3 tests, the same message among them.

### Code L9 / security L1: window cap · 889da101
- **Change:** `ReportController.returnsAudit` rejects `Duration.between(from, to) > 366 days` with `ApiInvalidParameterException("the date range may not exceed 366 days", "to")`.
- **Status code:** 422, the same contract as `checkPageBounds`, this controller's export bounds and the existing `from >= to` check. `BusinessException` also maps to 422 in `RestExceptionHandler:161`, so neither exception family offers a 400.
- **Tests** (`ReportReadGateUnitTest`, plain MockMvc with the real `RestExceptionHandler`):
  - `returnsAudit_shouldAccept_whenWindowIsExactlyTheCap`: 2025-10-01 → 2026-10-02 → 200.
  - `returnsAudit_shouldReject_whenWindowExceedsTheCap`: one second over → 422, with the service never called.
- **Mutant K5** (cap disabled): **KILLED** by the exceeds test.
- **Mutant K6** (`> 0` → `>= 0`): **KILLED** by the exactly-the-cap test.

### Security L2: allow-path 200 on both prefixes · 889da101
- **Change:** `gatedEndpointsAreReachableWhenTheFunctionIsHeld` now asserts `isEqualTo(200)` for `/v3/report/returnsAudit` and `/v3/dashboard/returnsAudit`.
- **The review's suggested mutant is equivalent here.**
  - **K7** (remove `@DateTimeFormat` from `from`): **SURVIVED**.
  - **K7b** (`ISO.DATE_TIME` → `ISO.DATE`): **SURVIVED**.
  - Spring's `String → OffsetDateTime` conversion parses ISO-8601 without the annotation, so `@DateTimeFormat` does not affect binding here. I kept it as documentation.
- **Replacement mutants** that do change behaviour:
  - **K7c** (`@GetMapping` → `@PostMapping`): **KILLED**. "holding WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW must reach the returns audit on /v3/report" (expected 200, got 405).
  - **K7d** (DashboardController mapped at `/v3/dashboardX`): **KILLED** on the dashboard leg alone. "…must reach the inherited returns audit on /v3/dashboard".

### Code L10: controller edge cases · 889da101
- **Tests:**
  - `returnsAudit_shouldReject_whenFromEqualsTo` → 422, service never called;
  - `…_whenToIsMissing` → 400;
  - `…shouldBindOffsetForm_whenPlusIsUrlEncoded`: `from=…T02:00:00%2B02:00` → 200, and the service receives the instant `2026-10-01T00:00Z`.
- The URL-encoded test sends a `URI`, because a MockMvc String template re-encodes `%` as `%252B`.
- **Mutant K8** (`!from.isBefore(to)` → `from.isAfter(to)`): **KILLED** by the from == to test.
- The holder → 200 case is security L2 above.

### Code L6: bulk-update negatives kept beside the entity-save negative · c9e05f29
- **Change:** all 5 retargeted sites in `ReturnAdviceAutoReceiveServiceUnitTest` again carry their original `never().updateAdviceToStateById(…)` line, verbatim from 371d8a09, next to the `never().saveAndFlush(any())` added in round 0. No assertion was removed.
- `NeverMatcherNullBlindnessArchTest` stays green and its inventory is unchanged at 9. The restored lines use `eq(FINISHED)`/literals, and the rule does not flag those.
- **Mutant K12** (the PARTIAL catch arm also calls `adviceRepository.updateAdviceToStateById(FINISHED, …)`): **KILLED** by exactly the restored lines:
  - `executeReportsPartialFailure…:774`
  - `executeCatchesUncheckedExceptionFromReceiveGoods:830`
  - `executeDoesNotCallMarkFinishedWhenAnyPositionFails:1265`
- The `saveAndFlush` negatives alone would not have caught K12.

### Code L7 + L8: auto-receive interplay and damaged order number on PostgreSQL · a538785e
- **New test:** `ReturnAdviceAutoReceiveIntegrationTest.autoReceive_shouldFinishAdviceOnceAndStampDamagedOrderNumber_whenEveryPositionIsReceived`.
  - Two positions; position A carries 2 damaged of 6.
  - It runs through `execute()`.
- **Assertions:**
  - outcome SUCCESS;
  - advice FINISHED with `version == 1` (written once) and `modified > created`;
  - both positions FINISHED;
  - every DAMAGED `STOCK_CREATED` stockrecord for the SKU has `ordernumber = 'APOS-94011'`, and there is at least one.
- **Fixture correction:** `persistPosition` returned an entity with no `number`, unlike the controller's saved entity, so `bind()` carried null to the damaged move. On the first run the L8 assertion found `[null, null]`. The helper now sets the number it persisted. Production was not at fault: the controller passes the saved entity.
- **Mutants:**
  - **K10a** (markFinished forces a second write): **KILLED**. "L7: the advice is written FINISHED exactly once…" (version 2).
  - **K10b** (S8 call removed and markFinished reverted to the bulk update, i.e. pre-ticket code): **KILLED** by the same test.
  - **K11** (`applyDamage` passes `null` instead of `line.number()`): **KILLED**. "L8: the damaged transfer's STOCK_CREATED row must carry adviceposition.number (S3)…"

### Security I2: noted
The gate stays on `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`. The `returnsAudit` javadoc still says why: the gate is method-level, and this is the Receiving Report's function. If a dedicated screen ships under a different menu function, re-point the gate and both tranche pin rows in the same change. I added no further code.

## Suite

Command: `mvn -o -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` (JDK 21). Result: BUILD SUCCESS.

| Lane | Before (666fe51a) | After (working tree = a538785e) | Delta |
|---|---|---|---|
| Surefire (unit) | 8288 run, 0 F, 0 E, 1 skip | **8300** run, 0 F, 0 E, 1 skip | +12: ReceivingServiceUnitTest +6, ReturnsAuditQueryContract +1, ReportReadGate +5 |
| Failsafe (IT) | 861 run, 0 F, 0 E, 23 skip | **872** run, 0 F, 0 E, 23 skip | +11: ReturnsAuditQueryIT +5, ReturnsAuditRepositoryIT +5, ReturnAdviceAutoReceiveIT +1 |

`git status` is clean after the commits. There is no ArchUnit store drift.

## Not fixed / for Nam

1. **Adjust after an over-key leaves the advice OPEN forever (consequence of M1).**
   - The correction path is: over-key → advice stays OPEN → operator adjusts down to exact. After that nothing finishes the advice. A further receive would over-receive again, and `AdviceService.close` refuses RETURN advices.
   - The audit flags such an advice: `fullyReceived=true` with `adviceState=OPEN`.
   - Closing it properly means calling the finisher from `GoodsReceiptPositionService.adjust`. That needs the private `finishReturnAdviceIfComplete` exposed as a new public service entry point and a cross-service call. Under the "new service method → stop" rule I did not do it.
   - **Proposed:** a T1/T2 follow-up on this ticket, which is not yet on dev. Blast radius: adjust on OPEN RETURN advices only.
2. **`@DateTimeFormat` on `returnsAudit` is decorative.** The removal mutants K7 and K7b survive because Spring parses ISO offsets without it. It is harmless, and I left it in.
3. **No advice-row lock (L3).** The exact-match argument rules out two finishers running at once, and the id-ordered saves are belt-and-braces. The lost-finish race (both receives leave the advice OPEN) remains, as the consult accepted, and the audit detects it.
