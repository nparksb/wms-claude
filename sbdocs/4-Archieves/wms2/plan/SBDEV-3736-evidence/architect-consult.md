---
title: SBDEV-3736 — T2 architect consult (A–E)
ticket: SBDEV-3736
lane: architect (single pass)
code_pin: wms2-api origin/develop 371d8a09 (fetched 2026-10-15)
date: 2026-10-15
---

# SBDEV-3736 — architect consult (one pass)

Scope is fixed (wms2-api only, no Flyway, no view change). All citations are `origin/develop` @ `371d8a09`,
read with `git show` / `git grep`. Background: report `261013-returns-audit-linkage-field-map.md` §7/§8,
`lane-wms.md` §3–§4.

## Summary

| # | Answer (one line) |
|---|---|
| 1 | `GET /v3/report/returnsAudit` on `ReportController` (it also registers as `/v3/dashboard/returnsAudit`), gated method-level on the **existing** `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`. Native `@Query` + interface projection in `repo/projection`, `Page<>` with an explicit `countQuery`, wrapped as `{content, totalElements}` by `ViewDtoService`. Put it on `AdvicepositionRepository`, which is `exported = false`. No migration, no new FunctionEnum constant. |
| 2 | Stamp `goodsreceiptTemp.setReceiptdate(LocalDateTime.now(ZoneOffset.UTC))` inside the only creator, `ReceivingService:451`. No other writer exists: SDR writes are disabled for `Goodsreceipt` and no native INSERT exists. |
| 3 | Fix this in `markFinished` only. `updateAdviceToStateById` has exactly one caller (`markFinished`). Replace that call with load → `setState` → `saveAndFlush`, as `AdviceService.close` does. Leave the shared `updateAdvicepositionToStateByAdviceId` untouched. |
| 4 | Add an `orderNumber` parameter to `UnitloadService.moveStockToNewDamagedContainer:174/192`, which today passes `null`. Thread it through a new `StockunitService.setLockDamaged` overload, with the old 5-arg form delegating `null`. Call it from `applyDamage:1005` with the position number. This changes `transaction_detail` DAMAGED rows (`transaction_number` and `order_number`, via the `rco` LATERAL) and the source UL's SEND_TO_NIRVANA `unitload_record`. Nothing else keys on `stockrecord.ordernumber`. |
| 5 | Invariant: a RETURN advice with ≥1 position, every one of them received in full (Σ`grp.amount` ≥ `notifiedamount`), is FINISHED. Enforce it at the end of `ReceivingService.receiveGoods`, which is the only path that writes a `goodsreceiptposition`. Use entity saves, not the `clearAutomatically` bulk update. Risks: (a) a rare lost-finish race, which degrades only to today's state; (b) completing on the dock now closes the `adjust` correction window; (c) SBDEV-3615's optimistic-lock "Conflict" path is what a version clash would surface as. SBDEV-3742 is OMS-side and has no contract coupling. |
| 6 | No T3 bump on any item: A no · B no · C no · D no · E no. Each uses existing functions and tables. The only new surfaces are one planned read query + projection (A) and one service overload (D). E becomes T3-adjacent only if someone insists on an advice-row lock: there is no `AdviceRepository.findByIdForUpdate`, so that lock would trip escalation trigger (2). Do not add it. |

---

## 1. Endpoint (A): placement, mapping, pagination, gate

### Placement — `ReportController`, `/v3/report/returnsAudit`

- `ReportController.java:32-33`: `@RequestMapping("/v3/report") public class ReportController extends AdminController`.
  This class owns the report read surface. It already serves the receiving report export
  (`:161-163`: `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW) @PostMapping(path= "/exportReceiving")`).
- **Dual registration is unavoidable.** `DashboardController.java:26`: `public class DashboardController extends ReportController`.
  Every handler declared on `ReportController` therefore also registers under `/v3/dashboard/...`. The
  existing pins say so (`Sbdev3017TrancheGateContextTest:186-195`: "Both prefixes are pinned for all 13
  ReportController-declared handlers … the dual mapping is INHERITANCE"). Pin **both** `/v3/report/returnsAudit`
  and `/v3/dashboard/returnsAudit` rows.
- `/v3` prefix: it comes from the class `@RequestMapping`. A `standaloneSetup` MockMvc unit test cannot see a
  wrong prefix, so path correctness must be pinned in the context-level `Sbdev3017TrancheGateContextTest`,
  which is keyed on **path** (`:197`: "Keyed on PATH, never on method name").
- Rejected alternatives:
  - `ReceivingController` (`/v3/receiving`): every handler there is the operational dock screen, gated
    `WEB_UI_VIEW_RECEIVING` (`:93`, `:420-421` `/receive`). An audit read does not belong to the dock.
  - `AdviceController` (`/v3/advice`): gated `WEB_UI_VIEW_INBOUND_BOL`, which also grants close/accept
    mutations (`:173-174`, `:282-283`). The fit is plausible but weaker, see the gate section below.

### Gate — existing `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` (no new constant)

- No UI screen is in scope, so "gate on its screen's function" resolves to the nearest existing read screen.
  That is the **Receiving Report**: wms2-web-ui `util/appMenuList.js:111`
  `{ text: 'Receiving Report', to: '/reports/receiving-report', fn: 'WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW' }`.
  Its backend twin is `ReportController:161` `/exportReceiving`. A returns audit is a receiving report
  filtered to `advice.type='RETURN'`.
- Constant: `WmsConstants.java:411` `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW`. It is already granted where the
  Receiving Report works, so there is no new constant and no initDB grant. **No migration.**
- Gate shape: use a **method-level** `@RequiresFunction`, never class-level. `ReportController` is not in
  `FunctionGuardInterceptor.GUARDED` (`FunctionGuardInterceptor.java:118-144` lists Lookup / Putaway / … /
  UserRole / UserGroup only). An unannotated handler here is therefore **silently ungated**, not
  fail-closed. Also see `ReportController:376`: "METHOD-level and NOT class-level: DashboardController extends ReportController".
- Tests:
  - Add the two `row(...)` lines next to `Sbdev3017TrancheGateContextTest:202-203`.
  - Add a case to `unit/controller/ReportReadGateUnitTest`. Remember the memory note *gate tests need UNGATED
    rows + full varargs*.

### Query + mapping convention — native `@Query`, interface projection, explicit `countQuery`

- Sibling precedent: `AdviceRepository.java:~100-150` `getOpenNoticesByKeyword` / `getClosedNoticesByKeyword`.
  Each one is `@Query(value = "select a.id as id, c.cl_nr as clientNumber, … ", countQuery = "select count(a.id) …", nativeQuery = true) Page<AdviceNoticeView> …(…, Pageable p)`.
  Projections are interfaces in `repo/projection/` (e.g. `AdviceDetailView`: `Long getId(); String getClientNumber(); …`).
  Use this pattern. The view-entity pattern (`ReceivingDtoView`, `@Table(name="receiving_dto_view")`) needs
  a DB view, which is out of scope.
- **Repository choice: `AdvicepositionRepository`.** It is `@RepositoryRestResource(…, exported = false)`
  (`AdvicepositionRepository.java:22`), so a new query method on it cannot leak through Spring Data REST.
  `AdviceRepository` is SDR-exported (`AdviceRepository.java:19`), and every query method added there needs
  `@RestResource(exported = false)`. Its siblings carry that annotation for exactly this reason
  (`:60-66`, "SBDEV-2781: NOT exported over HAL"). The grain is one row per position / received UL, so the
  position repo is also the natural home.
- Page envelope: route the result through a `ViewDtoService` method that returns
  `Map<String,Object>{content, totalElements}`, as `ViewDtoService:1040-1087` `getAdviceViewByKeyword` does
  (`pageData.put("totalElements", page.getTotalElements()); pageData.put("content", dtos);`).
- Controller parameters: copy the `page` / `size` `@RequestParam` shape of `ReportController:420-439`
  (`flowbinMonitorView`).
  - **Do not pass client sort through to a native query.** The siblings do
    `PageRequest.of(page, size, Sort.by(Sort.Order.asc(sort)))`. On this query, the many-joined native SQL
    would get `ORDER BY <raw property>` appended to it.
  - Use `PageRequest.of(page, size)` (unsorted) with a fixed
    `ORDER BY a.created DESC, a.id, ap.id, grp.id` inside the query, or an allow-list of aliases.
- SQL rules that bite here:
  1. **Optional `String` filter (client).** Use the safe native form from wms2-api `CLAUDE.md:239`:
     `AND (c.cl_nr = CAST(:clientNumber AS text) OR :clientNumber IS NULL OR :clientNumber = '')`.
     `OptionalStringFilterEmptyArmArchTest` fails the build without the `= ''` arm, and it also checks the
     `countQuery`.
  2. **Date range** (`from` / `to`, required).
     - Bind as `OffsetDateTime` / `Instant`, or `LocalDateTime` interpreted as UTC
       (`application.properties:186` `hibernate.jdbc.time_zone=UTC`).
     - Filter on `a.created`. The advice is the anchor: about 2.8k RETURN advices on PRD, and
       `index_advice_state` exists (`V2.2.00:3925`).
     - If the caller passes warehouse-local dates, convert them with `TimezoneService.getWarehouseZoneId()`
       (`TimezoneService.java:55`). `TransactionReportRestController:150` does this.
  3. **`unitload_record`.** Use the set-based `DISTINCT ON (ordernumber, label)` derived table from
     `lane-wms.md` §4, restricted to the page's position numbers:
     `WHERE ur.activitycode='RETURN' AND ur.ordernumber IN (SELECT ap.number FROM … filtered …)`.
     - Keep it out of the `countQuery`. `DISTINCT ON` guarantees at most one `ur` row per
       `(ordernumber, label)`, so the join cannot change cardinality, and the count does not need the
       6.8M-row scan.
     - Never use a per-row LATERAL here.
  4. **Receiving completion.**
     - Compute `CASE WHEN bool_and(coalesce(rcv.qty,0) >= ap.notifiedamount) OVER (PARTITION BY a.id) THEN max(grp.created) OVER (PARTITION BY a.id) END`,
       or an equivalent per-advice aggregate CTE.
     - **Never read `advice.state`.** Also expose a boolean `fully_received`. It doubles as the S8 safety
       net (§5).
  5. **Keep `LEFT JOIN adviceposition`.** There are 133 position-less historic advices (lane-wms §4
     correction).
  6. **Strip `-X-{id}`.** Use `regexp_replace(u.labelid, '-X-[0-9]+$', '')` for both the output and the
     `ur.label` join, never `ur.label = u.labelid`.
- **Damaged UL** (forward only, once D ships): `stockrecord` with `activitycode='DAMAGED' AND type='STOCK_CREATED' AND ordernumber = ap.number`
  gives the damaged container (`tounitload`).
  - Historic rows still need the clamped-comment fallback (`additionalcontent = 'RETURN DAMAGED ' || ap.externalid`).
  - Optional column; label it "best effort before <deploy date>".

## 2. S1 — `goodsreceipt.receiptdate`

- **The only creator:** `ReceivingService.java:449-458`:
  `final Goodsreceipt goodsreceiptTemp = new Goodsreceipt(); … setOperatorId(user.getId()); … goodsreceiptRepository.save(goodsreceiptTemp);`.
  - `git grep 'new Goodsreceipt\('` in `src/main` finds only that line.
  - There is no native `INSERT INTO goodsreceipt`.
  - SDR write verbs are closed for `Goodsreceipt` (`RestConfiguration.java:495`, in the write-disabled list).
  - Other references only read it: `UnitloadService:440`, `SharedService:51`, `BasicService:93/100`.
- **Column and field types:** `V2.2.00__base_v2_schema.sql:1174` `receiptdate timestamp with time zone`, and
  `Goodsreceipt.java:18` `private LocalDateTime receiptdate;`. UTC is consistent because
  `StartApplication.java:61-62` sets `TimeZone.setDefault(UTC)` / `user.timezone=UTC`, and
  `application.properties:186` sets `hibernate.jdbc.time_zone=UTC`.
- **Clock: `LocalDateTime.now(ZoneOffset.UTC)`.**
  - Precedent is `ReturnAdviceAutoReceiveService:1059` `position.setDamageappliedat(java.time.LocalDateTime.now())`.
    That form depends on `StartApplication.main` having run.
  - Spring test contexts do **not** run `main`. A test JVM on a non-UTC machine would therefore write a
    shifted instant with bare `now()`.
  - Do not add a `Clock` bean for this: none exists, and only `TimezoneService` takes a `Clock`.
- **Semantics.** Stamp it once, at receipt creation, meaning "first goods received against this advice".
  - Do **not** re-stamp it on later appends: the reuse branch at `:459-461` handles dock top-ups after a
    partial auto-receive.
  - Do **not** repurpose it as the completion time. Completion stays derived from positions (§7 field 11),
    or comes from the S8 finish.
- **Backfill:** none. The scope rules out a migration, and history stays NULL (0/20,346 rows), so the
  report must keep its `max(grp.created)` derivation.

## 3. S2 — `advice.modified` on `markFinished`

- `ReturnAdviceAutoReceiveService.java:954-958`:
  `@Transactional(value = "tenantTransactionManager") public void markFinished(Long adviceId) { advicepositionRepository.updateAdvicepositionToStateByAdviceId(AdviceState.FINISHED, adviceId); adviceRepository.updateAdviceToStateById(AdviceState.FINISHED, adviceId); }`
- **Every caller** (`git grep` across `src/main`):
  - `AdviceRepository.updateAdviceToStateById` (`AdviceRepository.java:28-38`, `@Modifying(clearAutomatically = true)`):
    the **only** caller is `ReturnAdviceAutoReceiveService:957`.
  - `AdvicepositionRepository.updateAdvicepositionToStateByAdviceId` (`:36-40`) has three callers:
    - `AdviceService:322` (`close`)
    - `AdviceService:436` (accept-transfer)
    - `ReturnAdviceAutoReceiveService:956`
  - On both `AdviceService` paths the advice itself is already written through the entity
    (`advice.setState(FINISHED); adviceRepository.saveAndFlush(advice);` at `:319-320` and `:433-434`), so
    their `advice.modified` is correct. Only the auto-receive path is wrong.
- **Recommendation: change `markFinished` only.**
  ```java
  advicepositionRepository.updateAdvicepositionToStateByAdviceId(AdviceState.FINISHED, adviceId); // unchanged
  Advice advice = adviceRepository.findById(adviceId).orElseThrow(...);
  advice.setState(AdviceState.FINISHED);
  adviceRepository.saveAndFlush(advice);   // @LastModifiedDate + @Version fire (AbstractBaseEntity:16,31,34)
  ```
  - Mirror `close()`'s ordering: advice save first, then the position bulk update. `findById` then runs
    before the `clearAutomatically` bulk update evicts anything.
  - `markFinished` runs in its own transaction via `self`, and nothing else is pending in it, so the
    eviction is harmless.
  - `updateAdviceToStateById` then has zero callers. Keep it (still `exported = false`), or delete it in
    the same PR. Deleting it removes a footgun.
- **Why not change the JPQL** (`SET a.state=:state, a.modified=CURRENT_TIMESTAMP`)? It is safe for blast
  radius (one caller). But it still skips `@Version` and keeps a second write idiom alive. The entity form
  is the house pattern (`close`, `accept`).
- **Position `modified`** also stays stale on all three paths. That is out of scope. Do not touch the
  shared method: changing it alters `close` and accept-transfer, which `AdviceServiceUnitTest:681/814/1489`
  pin with `inOrder`.
- **Tests that move:** `ReturnAdviceAutoReceiveServiceUnitTest` verifies `updateAdviceToStateById` at
  `:716, :760, :814, :845, :1185, :1203, :1245, :1268, :1446, :1666, :1861`.
  - Those become `saveAndFlush` captures asserting `getState()==FINISHED`.
  - Mutation-check them: drop the `setState` and the test must go red.
  - `FileImportControllerUnitTest:1144` and `AdviceRestControllerUnitTest:593-594` are `never()` checks.
    Retarget them to `saveAndFlush`, or they become vacuous.

## 4. S3 — damaged transfer `orderNumber`

- **Chain:**
  1. `ReturnAdviceAutoReceiveService.applyDamage:1005`
     `stockunitService.setLockDamaged(received, new BigDecimal(line.damagedAmount()), "RETURN DAMAGED " + line.positionExternalId(), false, null);`
  2. → `StockunitService.setLockDamaged:770` → `:830` `unitloadService.moveStockToNewDamagedContainer(containerLabel, stockUnit, location_damaged, unitLoadType.getId(), amount, comment);`
  3. → `UnitloadService:192-193` `stockunitBusinessService.transferStockToUnitLoad(stockUnit, container, amount, WmsConstants.CODE_DAMAGED, null, comment, false, true);`
     ← **the call site**.
- **Change:**
  - Add `String orderNumber` to `moveStockToNewDamagedContainer`. Its only main caller is `StockunitService:830`.
  - Add a `setLockDamaged(…, Principal principal, String orderNumber)` overload, with the existing 5-arg
    method delegating `null`.
  - The two `StockUnitController` callers (`:591`, `:633`, manual "Transfer To Damaged") keep the 5-arg form.
    Their `StockUnitControllerUnitTest:1255-1370` stubs stay valid.
  - In `applyDamage`, pass the **position number** (`IBOL…-NNNNNN`).
    - `AutoReceiveLine` carries `advicePositionId` and `positionExternalId`, not `number`.
    - Either add `number` to `AutoReceiveLine` when `bind()` builds it from the persisted position, or look
      it up from the id already loaded.
    - Do **not** pass `positionExternalId`. The resolver keys on `adviceposition.number`.
- **What `orderNumber` reaches inside `transferStockToUnitLoad`** (`StockunitBusinessService:179-428`):
  - `stockrecordService.recordTransferStockUnit(…, orderNumber, …)` (`:352`), or `recordRemoval` + `recordCreation` (`:413-414`).
    Both the source-side and destination-side `stockrecord` rows get `ordernumber`.
  - `sendStockUnitToNirvana(…, orderNumber, …)` (`:417`), and
    `unitloadBusinessService.relocateEmptiedContainer(sourceUnitload, CODE_SEND_TO_NIRVANA, orderNumber, comment)` (`:403`, `:423`).
    When the whole received amount is damaged, the **received UL's** SEND_TO_NIRVANA `unitload_record` now
    carries the IBOL number.
    - Its activitycode is not `RETURN`, so the audit's `ur` filter (`activitycode='RETURN'`) is unaffected.
    - It is the same rename that produces `-X-{id}`.
  - The damaged container's own CREATED `unitload_record` comes from `createNewUnitload(…, CODE_DAMAGED, null)`
    (`UnitloadService:186-187`, signature `:275`, which has no order param). It stays NULL. Leave it.
- **Consumers keyed on `stockrecord.ordernumber`.** Migrations: `git grep` over `db/migration` gives
  V2.2.00, V2.2.08, V2.2.12, V2.2.25 and V2.2.33.
  - **`transaction_detail` (V2.2.25, current definition):**
    - `tr.transaction_number = sr.ordernumber` → DAMAGED rows now show `IBOL…`.
    - The `rco` resolver (`V2.2.25:245-252`, `LEFT JOIN LATERAL … INNER JOIN advice ra ON … ra.type = 'RETURN' … WHERE rap.number = sr.ordernumber … LIMIT 1`)
      now **resolves for DAMAGED rows**. `order_number = coalesce(rco.clientordernumber,'')` becomes populated.
    - `package_number` stays `sr.tounitload`, because the `CASE` at `:200-202` keys on `activitycode = 'RETURN'` only.
    - Only `activitycode='DAMAGED' AND type='STOCK_CREATED'` rows are selected (`:266`). The source-side
      removal row is not.
    - The outer `UNION` (not `UNION ALL`) dedups. Rows that were byte-identical before can now differ.
      That is cosmetic, and in practice there are none.
    - **Accepted per scope.** Extend `TransactionDetailReturnOrderRefsIntegrationTest`: today it has no
      DAMAGED fixture, and `:349` only lists the column. Add a damaged return row and assert both
      `transaction_number` and `order_number`.
  - **`stockrecord_view` (V2.2.33:100-115)** exposes `sr.ordernumber` to `StockrecordView`, behind the Stock
    Unit Record screen. Damaged rows now show the IBOL number and become findable by it. That is a benefit,
    with no contract break.
  - V2.2.08 and V2.2.12 are superseded `transaction_detail` bodies. V2.2.00 holds the base schema plus the
    original function bodies.
  - **Java:** there is no repository finder on `stockrecord.ordernumber`. `StockrecordService:601` and
    `UnitloadRecordService:137` only `details.put("ordernumber", …)` for display.
  - **OMS:** `setLockDamaged` builds `StockChangeDto` without an order number (`StockunitService:~836+`),
    so OMS sees no change.
- **History is not rewritten.** Pre-deploy damaged rows keep NULL. The audit endpoint keeps the comment
  fallback.

## 5. S8 — finishing a partially auto-received RETURN advice

**Facts.**
- Partial auto-receive returns before `markFinished`. `ReturnAdviceAutoReceiveService:770-772`: "The advice
  deliberately stays OPEN (markFinished is below the loop and is NOT reached), so the ordinary dock path can
  still receive the remaining positions."
- `AdviceService.close:313-315` rejects non-REGULAR advices:
  `if (!advice.getType().equals(WmsConstants.AdviceType.REGULAR)) { throw new BusinessException("Close inbound BOL not allowed for type " …`.
- `ReceivingService` only ever **sets** OPEN (`:224`, `:257`, `:309`), and `receiveGoods` requires OPEN on
  both the position (`:384`) and the advice (`:402`).
- **`receiveGoods` is the only writer of `goodsreceiptposition`.** `new Goodsreceiptposition()` exists only
  at `ReceivingService:569`. `GoodsReceiptPositionService:111` only adjusts an existing row. `receiveGoods`
  has exactly two callers:
  - `ReceivingController:438` (dock)
  - `ReturnAdviceAutoReceiveService:750` (auto)

**Invariant.** *A RETURN advice is FINISHED iff it has ≥ 1 position and every position has
Σ `goodsreceiptposition.amount` ≥ `notifiedamount`.*
- Damage completion (`damageappliedat`) is deliberately **not** part of it. `DAMAGE_FAILED` already finishes
  with damage outstanding (`:855-857`), and the recovery worklist is keyed on the position, not the advice
  state.

**Where to enforce it.** At the tail of `ReceivingService.receiveGoods`, after the receive loop and its
`catch` (`:550-588`), still inside its `@Transactional`.
- Guard it with `AdviceType.RETURN.equals(advice.getType())`.
- Call a private `finishReturnAdviceIfComplete(advice)` helper. It uses only existing finders:
  - `advicepositionRepository.findByAdviceId(advice.getId())`
  - `goodsreceiptpositionRepository.findByAdvicepositionIdIn(ids)` (`GoodsreceiptpositionRepository:46`)
- If complete, the helper sets FINISHED on the advice and on each position **entity**, then saves. Do not
  call `updateAdvicepositionToStateByAdviceId` here:
  - It is `@Modifying(clearAutomatically = true)` with no `flushAutomatically`.
  - Mid-`receiveGoods` it would clear the persistence context after a flush that Hibernate's AUTO mode only
    guarantees for overlapping query spaces.
  - That risks discarding pending unitload/stockunit/carrier writes, including the SBDEV-3615 carrier move
    at `:425-441`.
  - Entity saves also fix `modified` for free, which is S2's lesson applied here.
- The auto path then finishes on its last line. `markFinished` still runs afterwards (`:876`) and is
  idempotent. The dock path finishes whichever call receives the last unit. One home, both paths.
- Also guard explicitly against `positions.isEmpty()`. The hook only runs after a receive, which implies a
  position, but `SKIPPED_NO_POSITIONS` (`:735-740`) proves that zero-position RETURN advices exist.

**Risks.**
1. **Lost-finish race (benign).**
   - Two dock users concurrently receive the *last two* positions of one advice. Each holds only its own
     position's `FOR UPDATE` (`:381`). Under READ COMMITTED, neither sees the other's uncommitted `grp`, so
     both conclude "incomplete".
   - The advice stays OPEN, which is today's behaviour, never worse. Double-finish is impossible: two
     finishers would each need to see the other's uncommitted row.
   - Closing the race needs an advice-row lock. `AdviceRepository` has no `findByIdForUpdate` (`git grep`:
     none), so that would mean a **new repository method**, which is escalation trigger (2). Do not add it.
   - Instead, rely on A's `fully_received AND state='OPEN'` as the detection flag.
2. **Correction window closes.** `GoodsReceiptPositionService.checkAndGetGoodsReceiptPosition:142-147`
   refuses adjust/delete unless the advice is OPEN.
   - Today a dock-completed RETURN advice stays OPEN, so a mis-keyed amount can still be adjusted. After S8
     it cannot.
   - That matches the fully auto-received case, which is already FINISHED. State it in the PR.
   - ~~Over-receipt is impossible with `allowoverdelivery=false` (`:408-417`), so "complete" is reachable only
     by exactly-notified totals.~~ **Corrected 2026-10-15 (code review r1 M1):** false for RETURN advices —
     `AdviceRestController:285` sets `allowoverdelivery=true` on every one (WineCo PRD: 2,822/2,822), so the
     `:408-417` guard is skipped and an over-key is accepted. **Nam's decision:** S8 finishes only on an EXACT
     match per position (`sum == notifiedamount`); an over-key leaves the advice OPEN and correctable. See
     `fixes-r1.md`.
3. **SBDEV-3615 (`bb4acecd`, on develop).**
   - It added a carrier write inside `receiveGoods` and mapped `ObjectOptimisticLockingFailureException` to
     a retryable "Conflict" in `ReceivingController` (`/receive` catch).
   - The finisher's `@Version` write on `advice` adds a theoretical second collision point. It occurs only
     if two transactions both write the same advice, which risk 1 shows cannot both reach the finish.
   - On the auto path, an optimistic-lock failure on the last line would be caught by `executeInternal`'s
     `catch (… RuntimeException e)` (`:758`) and **misreported as PARTIAL**. That path is single-threaded
     per advice (the create request), so no concurrent writer exists. Acceptable, but note it in the javadoc.
   - Rebase onto develop: the 3615 hunk sits at `:425-441`, directly above the goods-receipt block that S1
     edits.
4. **SBDEV-3742** lives in the OMS repo (`wms_warning_code`, "also true of a warned or aborted auto-receive"
   per `review-critic-r3.md`).
   - There is no wire coupling. `markFinished` and the new finisher send nothing to OMS, unlike REGULAR
     `close()`, which builds an `AdviceDto` (`AdviceService:324+`).
   - OMS keeps the warning as history even after WMS completes the advice. That is correct, but say so in
     the audit (A's `fully_received` vs the OMS warning).
   - A SKIPPED/ABORTED advice (nothing received) becomes finishable once the dock receives every position.
     That is intended.

**Tests** (inline, T2: no verify script):
- A dock `receiveGoods` IT on a RETURN advice with two positions, the first already received. Assert
  FINISHED, plus `advice.modified > created`.
- The same flow with one position short → stays OPEN.
- A REGULAR advice → never auto-finished. This is the guard mutant.
- A zero-position guard unit test.
- Mutation-check by removing the `RETURN` guard: the REGULAR test must go red.

## 6. Escalation check (per item)

| Item | New repo/service surface beyond plan? | Authz change? | Migration? | Verdict |
|---|---|---|---|---|
| A | One new native query method + one projection interface. **Planned, not a surprise.** Put it on the non-exported `AdvicepositionRepository` | New route gated by an **existing** function. No new constant, no grant | No | T2 |
| B | None | No | No | T1-in-T2 |
| C | None. Uses existing `findById`/`saveAndFlush`. Optionally delete the now-dead `updateAdviceToStateById` | No | No | T1-in-T2 |
| D | One overload `setLockDamaged(…, orderNumber)` + one param on `moveStockToNewDamagedContainer`. Anticipated by scope | No | No. `transaction_detail` output changes with the **unchanged** function body | T2 (report contract change, accepted) |
| E | None if built on `findByAdviceId` + `findByAdvicepositionIdIn`. **Becomes trigger (2)** only if an advice-row lock is demanded | No | No | T2. Do not add the lock |

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| A on `ReportController` + `RECEIVED_STOCK_OVERVIEW` (chosen) | Report family, read-only function, matches the Receiving Report menu | Twin `/v3/dashboard` route, which must be pinned |
| A on `AdviceController` + `INBOUND_BOL` | Advice-centric | That function also grants close/accept, so a broader population would see the audit |
| C entity save in `markFinished` (chosen) | House pattern, bumps `@Version` + `modified` | Touches about 11 unit-test verifies |
| C JPQL `SET modified=CURRENT_TIMESTAMP` | One-line change | Keeps the version-less write idiom |
| E finisher in `receiveGoods` (chosen) | Single writer of `grp`, so it covers both paths | Closes the adjust window, plus a benign lost-finish race |
| E finisher in each caller | No change to the shared service | Two copies of one invariant: a dock caller added later misses it |

## References

- `src/main/java/net/aim_ai/wms/controller/ReportController.java:32-33, 161-163, 376, 420-439`
- `src/main/java/net/aim_ai/wms/controller/DashboardController.java:26`
- `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:118-144`
- `src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java:72-80, 186-212`
- `src/main/java/net/aim_ai/wms/repo/jpa/AdviceRepository.java:19, 28-38, 60-150`
- `src/main/java/net/aim_ai/wms/repo/jpa/AdvicepositionRepository.java:22, 36-40`
- `src/main/java/net/aim_ai/wms/repo/jpa/GoodsreceiptpositionRepository.java:19, 46`
- `src/main/java/net/aim_ai/wms/service/ViewDtoService.java:1040-1087`
- `src/main/java/net/aim_ai/wms/service/WmsConstants.java:411`
- `src/main/java/net/aim_ai/wms/service/ReceivingService.java:337, 381-417, 449-461, 550-588`
- `src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java:735-740, 750, 758-772, 855-876, 954-958, 981-1006, 1059`
- `src/main/java/net/aim_ai/wms/service/AdviceService.java:313-322, 433-436`
- `src/main/java/net/aim_ai/wms/service/StockunitService.java:770, 830`
- `src/main/java/net/aim_ai/wms/service/UnitloadService.java:174-201, 275`
- `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:179-428`
- `src/main/java/net/aim_ai/wms/service/GoodsReceiptPositionService.java:111, 136-147`
- `src/main/java/net/aim_ai/wms/StartApplication.java:61-62`; `src/main/resources/application.properties:186`
- `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:1174, 3925`
- `src/main/resources/db/migration/V2.2.25__transaction_detail_return_order_refs.sql:186-266`
- `src/main/resources/db/migration/V2.2.33__stockrecord_view.sql:100-115`
- wms2-web-ui `util/appMenuList.js:44, 111`
- wms2-api `CLAUDE.md:232-241` (optional String filter rule)
