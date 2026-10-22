# SBDEV-3674 — §0 Affected Sites, enumerated

**Scope:** `v2/wms2-api` at `origin/develop`, read only via `git grep` / `git show` / a
`git archive origin/develop src/main src/test` extraction into the session scratchpad. No worktree,
no checkout, no `mvn`. Date: 2026-10-07.

---

## 0. Instruments, and what each one can and cannot see

| id | instrument | what it matched |
|---|---|---|
| **I1** | `git grep -n "createServiceLog\|createMessage" origin/develop -- 'src/main/**/*.java'` | 56 lines (declarations + comments + calls) |
| **I2** | ast-grep `$RECV.createMessage($$$ARGS)` and `$RECV.createServiceLog($$$ARGS)`, Java grammar, over the extracted `src/main` | **37** + **2** = **39** receiver-qualified calls |
| **E1** | enclosing-method walk — script over the extracted tree, nearest 4-space-indented method declaration above each site plus the annotations immediately above it | enclosing method + its annotations, per site |
| **E2** | `grep -n "Transactional\|^@Service\|^@RestController\|^public class"` over each of the 12 calling files | class- and method-level `@Transactional` inventory |
| **E3** | caller sweep `grep -rn "<methodName>" src/main` for `sendAfterCommit`, `reportPendingReversalsOnShippedPallets`, `reconcileCurrentTenant`, `sendList`, `createAll`, `writeServiceLog`, `dispatchOne` | outward transaction walk |
| **E4** | `git show origin/develop:src/main/resources/application.properties` | `spring.jpa.open-in-view=false` (line 85) |
| **E5** | `git grep -n "Transactional\|TransactionTemplate\|PlatformTransactionManager"` over `IdempotencyFilter`, `TenantFilter`, `FunctionGuardInterceptor`, `SdrFunctionGuard`, `WebConfig` | **zero hits** |
| **E6** | `grep -ln "TransactionTemplate\|PlatformTransactionManager"` over all 12 calling files | **zero hits** — no programmatic transaction anywhere in the calling files |
| **D1** | `mcp__nywh-hydra-prd__execute_sql` — 3 read-only queries | per-process row counts, advice population, sequence head |

**Blind spots, stated inline because the counts below are completeness claims:**

- **I2 cannot see** a call with no receiver (`createServiceLog(...)` bare). That is deliberate — those
  are the self-invocations — but it means I2's 39 is *external calls only*, and the 2 internal ones
  were recovered from I1 instead.
- **I2 would wrongly count** a `this.createServiceLog(...)` as external. Checked:
  `grep -rn "this.createServiceLog\|this.createMessage" src/main` → **zero**. Both I2
  `createServiceLog` matches are on the field `messageService`.
- **Neither instrument sees** a reflective, SpEL-mediated, or method-reference call.
  Checked: `grep -rn "::createMessage\|::createServiceLog\|\"createServiceLog\"\|\"createMessage\""`
  over `src/main` → **zero**. Positive control: the same grep's `getMethod(` arm returned 10 real hits,
  so the instrument was working when it returned zero on the other arms.
- **Neither sees** a proxy obtained via `AopContext.currentProxy()`, `@Lookup`, or a subclass override.
  Checked: `grep -rn "extends MessageService\|AopContext\|@Lookup"` over `src/main` → **zero**.
- **E1 is a regex walk, not a parser.** It can mis-attribute a site inside an anonymous inner class to
  the enclosing *outer* method. Two sites are inside anonymous inner classes
  (`BillofladingService:1707`, inside a `new TransactionSynchronization() { afterCommit() }`, and
  `OmsNotificationService`'s deferred branch). Both were read by hand and are reported from the hand read,
  not from E1.
- **D1 is one environment** (Hydra PRD). It says nothing about ShipItEZ or WineCo.

---

## 1. Count reconciliation — your 39 is CONFIRMED, the file count is 12 not 13

I2 and I1 agree, per file, exactly:

| file | sites | entry point |
|---|---|---|
| `controller/AdminActionController.java` | 2 | createMessage |
| `controller/ItemDataController.java` | 3 | createMessage |
| `controller/rest/AdviceRestController.java` | 6 | createMessage |
| `controller/rest/OrderRestController.java` | 9 | createMessage |
| `controller/rest/SkuRestController.java` | 4 | createMessage |
| `controller/rest/TransactionReportRestController.java` | 4 | createMessage |
| `schedulejob/StockSummaryExportJob.java` | 3 | createMessage |
| `service/OmsNotificationService.java` | 4 | createMessage |
| `service/OrderBatchCreationService.java` | 1 | createMessage |
| `service/job/OutboxDispatchService.java` | 1 | createMessage |
| `schedulejob/PendingReversalReconciliationJob.java` | 1 | **createServiceLog** |
| `service/BillofladingService.java` | 1 | **createServiceLog** |
| **total** | **39** | **12 files** |

Plus **2** internal self-calls, both inside `MessageService.resendMessage` — `MessageService.java` is a
13th file only if you count the callee's own file. Your "13 files" is right on that reading; the
external-caller file count is **12**. Flagged because the already-corrected §4 of the v1 plan says
"the other **37** external call sites, in 12 files", which mixes the two: 37 is the `createMessage`-only
count, whose file count is **10**; 12 is the file count for all 39.

`ItemDataController:184`, `SkuRestController:196`, `SkuRestController:334` are comments, confirmed not
matched by I2. `ReturnAdviceAutoReceiveService:703`, `MessageService:67/68/71/72/76/77`,
`OutboxDispatchService:272`, `BillofladingService:1675`, `SkuRestController:171/315` are declarations or
javadoc — likewise not matched.

---

## 2. The two proxy sites — confirmed, exactly 2

Only a call to `createServiceLog` **from another bean** goes through the CGLIB proxy and gets a real
`REQUIRES_NEW`. I2 found exactly two such calls, and the blind-spot checks above rule out the
mechanisms that could hide a third.

`MessageService` implements no interface, so Spring proxies it with CGLIB; both `createMessage`
overloads are one-liners that call `createServiceLog(...)` **unqualified on `this`**:

```java
public Message createMessage(String sender, String receiver, String message, String process, String destination, String stateCode) throws BusinessException {
    return createServiceLog(sender, receiver, message, process, destination, MessageStatus.CREATED, stateCode, null);
}
```

so `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` on
`createServiceLog` is **inert on 37 of 39 external sites and on both internal ones**.

---

## 3. ⚠ The mechanism is worse than "rolls back with the caller" on 3 sites

`createServiceLog`'s first act is

```java
m.setNumber(basicService.generateMessageNumber(WmsConstants.EntityPrefixes.EMPTY_PREFIX, "WEBSERVICE_MESSAGE"));
```

→ `BasicService.getNextSequenceNumber` → `SequenceTransactionService.getNextSequenceNumber`, which is
a **separate bean** carrying
`@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`. The proxy
**does** apply there. So **every** invocation of `createServiceLog` burns a `WEBSERVICE_MESSAGE`
sequence number in its own committed transaction, whatever happens to the `message` row. That is
exactly why the gap is measurable as burned-number-minus-surviving-row, and it holds at all 41 sites.

Three distinct outcomes for the row itself:

1. **No enclosing transaction** (34 of 39 sites) → `SimpleJpaRepository.save`'s own `REQUIRED` opens
   one and commits. **Row survives.** Today's behaviour is correct by accident, as
   `SkuRestController:172` already says in as many words.
2. **Inside an enclosing transaction** (1 site: `OrderBatchCreationService:212`) → the insert joins it
   and **rolls back with it**.
3. **Inside an `afterCommit()` callback** (4 sites: `OmsNotificationService:124/146/156` on the deferred
   path, and `:56` is case 1 or 2 depending on caller) → `AbstractPlatformTransactionManager.processCommit`
   runs `triggerAfterCommit()` **before** `cleanupAfterCompletion()`, so the thread still has an active
   transaction bound. A `REQUIRED` `save` therefore *participates* in a transaction that has already
   committed: `status.isNewTransaction()` is false so nothing commits, `status.isNewSynchronization()` is
   false so nothing flushes, and the EntityManager is closed at cleanup. **The insert is silently lost —
   no row, no exception.**

Case 3 is the repo's own stated model, at `BillofladingService:1676`: *"a REQUIRED write from afterCommit
would join the finished transaction and be lost"*. It is the most severe of the three and it is the one
that explains a loss rate without a corresponding error rate.

---

## 4. Enclosing-transaction walk — the outward sweep

**`OrderBatchCreationService.createAll` is the only caller whose own method carries `@Transactional`.**
Derived two ways: E1 (annotation directly above the enclosing declaration) and E2 (`@Transactional`
inventory per file). E2 output for all 12 files:

- **Zero class-level `@Transactional`** on any of the 12.
- Method-level, in a calling file: `OrderBatchCreationService:69`
  `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`
  on `createAll` — and the site at `:212` is the last statement of that method, inside it.
- `BillofladingService` has 4 `@Transactional` methods, but none of them lexically encloses `:1707`;
  that site is inside an `afterCommit()` callback registered by a `private` method.
- `OutboxDispatchService:161` is `REQUIRES_NEW`, but that is `cleanupSent`, not a caller of
  `writeServiceLog`. `dispatchBatch`'s own javadoc states it is *"NOT `@Transactional` — each phase is a
  short, independent tx managed via `outboxService`"*, and `writeServiceLog` is called from
  `dispatchOne`, which runs between those phases with no tx held.

**Nothing opens a transaction around a request.** Four independent reasons, each separately checked:

- `spring.jpa.open-in-view=false` (**E4**, `application.properties:85`) — no OSIV EntityManager, let
  alone an OSIV transaction. Corroborated by six in-code javadocs that reason from it, e.g.
  `LocationRepository:129` *"(spring.jpa.open-in-view=false) a locking query here throws
  TransactionRequiredException"*.
- `IdempotencyFilter`, `TenantFilter`, `FunctionGuardInterceptor`, `SdrFunctionGuard`, `WebConfig`
  contain **no** `@Transactional`, `TransactionTemplate` or `PlatformTransactionManager` (**E5**).
- No programmatic transaction in any of the 12 calling files (**E6**).
- Spring Data REST's `RestConfiguration` is irrelevant here: none of the 39 sites is on an SDR route.

**Two transaction managers.** `landlordTransactionManager` is `@Primary`, so a bare `@Transactional` in
`net.aim_ai.wms.service` targets the **landlord** DB while `net.aim_ai.wms.repo.jpa` repositories inherit
the **tenant** one. This does not bite at any of the 39 sites: the one enclosing annotation
(`OrderBatchCreationService:69`) names `tenantTransactionManager` explicitly, and every other site has no
enclosing annotation at all. Worth keeping in view for the *fix*, though — a bare `@Transactional(REQUIRES_NEW)`
added to `createMessage` would bind the **landlord** manager and write the row through the wrong
EntityManager.

**Threads.** `StockSummaryExportJob.sendList` runs on a dedicated `oms-export-consumer` thread
(`new Thread(consumerTask, "oms-export-consumer")`, body `while ((chunk = omsQueue.take()) != POISON_PILL) { sendList(chunk); }`),
wrapped in `new TenantAwareTaskDecorator().decorate(...)`. Spring transactions are thread-bound, so
none is inherited; the tenant context is propagated explicitly by the decorator. All 3 sites are
therefore case 1.

---

## 5. Lock inventory (built first, as asked)

`@Lock(LockModeType.PESSIMISTIC_WRITE)` — **15 methods across 12 tenant repositories**
(`Adviceposition`, `Billoflading`, `CustomerorderBatch`, `CustomerorderCancellationLog`,
`CustomerorderPosition`, `Customerorder`, `Location` ×2, `LosSequencenumber`, `Pickingorder` ×2,
`Replenishorder`, `Stockunit` ×2, `Unitload` ×2). Plus **2 native `FOR UPDATE` queries**
(`StockunitRepository:312` `… FOR UPDATE OF stockunit`; `OutboxMessageRepository:55`
`FOR UPDATE SKIP LOCKED`) and ~31 bulk `@Modifying` UPDATE/DELETEs, which take a row lock per matched
row exactly as `FOR UPDATE` does. This enumeration is taken from the repo's own
`LockTimeoutHibernateJpaDialect` javadoc and independently reproduced by
`git grep -n "PESSIMISTIC_WRITE\|ForUpdate\|FOR UPDATE"`.

**None of those 12 repositories is `ClientRepository` or `UserRepository`** — which matters, because the
only FK constraints on `message` are:

```
ADD CONSTRAINT fk78dylen835o1gw7d9snc2gg6e FOREIGN KEY (operator_id) REFERENCES public.mywms_user(id);
ADD CONSTRAINT fkgvo2vw6xgtws6ognjlnrxyi5x FOREIGN KEY (client_id)   REFERENCES public.client(id);
ADD CONSTRAINT fkrhfk4t3u7wncmmjl3igsnhyc9 FOREIGN KEY (redeliver_id) REFERENCES public.message(id);
```

An INSERT into `message` therefore takes a `FOR KEY SHARE` lock on one `mywms_user` row and one
`client` row. That is the only way a `REQUIRES_NEW` message insert could ever block on a lock its own
outer transaction holds.

> ⚠ I got this wrong on the first pass. A single `grep "message.*FOREIGN KEY"` returned only the
> `redeliver_id` constraint, because `ALTER TABLE ONLY public.message` and `ADD CONSTRAINT … FOREIGN KEY`
> sit on **different lines**. The positive control (`grep -c "FOREIGN KEY"` → 128 in the same file) is
> what exposed it. A one-line grep over a two-line DDL statement is a false zero that reads exactly like
> a true one.

The two writers that lock those parent rows are `ClientRepository:116`
`@Query("UPDATE Client c SET c.printerreceivingId = NULL WHERE c.printerreceivingId = :printerId")` and
`UserRepository:131` `@Query("DELETE FROM User u WHERE u.id = :userId")` (called from
`UserService:287`). Neither is on any of the 39 call sites' enclosing-transaction paths, and neither
service writes a service-log row.

---

## 6. §0 Affected Sites

Column shorthand:

- **Proxy?** — `Y` only where `createServiceLog` is called from another bean.
- **Encl. tx** — `none` / `caller's tx` / `afterCommit` / `fresh thread`.
- **Derived** — `E1`/`E2`/`E3`/`E4`/`E5`/`E6` as defined in §0; `hand` = read by hand.
- **A/O** — ATTEMPT (must survive a business rollback) vs OUTCOME (should roll back with it).
- **Deadlock?** — would adding a real `REQUIRES_NEW` here risk the lock-holding deadlock.

### 6.1 Egress audits — WMS POSTed to OMS (sender = WMS, receiver = OMS)

| # | File | Quoted snippet | Entry | Proxy? | Encl. tx | Derived | Process + status | A/O | Deadlock? |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `controller/AdminActionController.java` | `MessageProcessType.TEST_CRM_CONNECTIVITY,` … `reachable` ⏎ `? WmsConstants.MessageStatus.SENT` | createMessage | N | none | E1,E2,E4,E5 | TEST_CRM_CONNECTIVITY · SENT\|FAILED | **ATTEMPT** — the whole output of the endpoint is "did OMS answer". A probe that ran must stay on record. | No — no enclosing tx, nothing to suspend |
| 2 | `controller/AdminActionController.java` | `MessageProcessType.TEST_CRM_CONNECTIVITY,` … `WmsConstants.MessageStatus.FAILED,` ⏎ `"503", null);` (in `catch (Exception e)`) | createMessage | N | none | E1,E2,E4,E5 | TEST_CRM_CONNECTIVITY · FAILED | **ATTEMPT** — same, for the unreachable-host arm | No |
| 3 | `controller/ItemDataController.java` | `HttpRestService.NO_HTTP_RESPONSE_CODE,` ⏎ `e.toString());` (inside `catch (RuntimeException e)` around the POST) | createMessage | N | none | E1,E2,E4,E5 | STOCK_UPDATE · FAILED | **ATTEMPT** — SBDEV-3325 added this precisely so an outage leaves a record; the row is the only evidence the POST was tried | No |
| 4 | `controller/ItemDataController.java` | `HttpRestService.isSuccess(respMap)` ⏎ `? WmsConstants.MessageStatus.SENT` … `respMap.get("answer"));` | createMessage | N | none | E1,E2,E4,E5 | STOCK_UPDATE · SENT\|FAILED | **ATTEMPT** — the POST is irreversible; OMS already has the data | No |
| 5 | `controller/ItemDataController.java` | `message = messageService.createMessage(` … `"503", null);` (only assignment-form in this file) | createMessage | N | none | E1,E2,E4,E5 | STOCK_UPDATE · FAILED | **ATTEMPT** — serialization failed, nothing sent; still an attempt that consumed an operator action | No |
| 6 | `schedulejob/StockSummaryExportJob.java` | `destination,` ⏎ `WmsConstants.MessageStatus.FAILED,` ⏎ `HttpRestService.NO_HTTP_RESPONSE_CODE,` ⏎ `outcome);` | createMessage | N | fresh thread (`oms-export-consumer`) | E1,E3,hand | INVENTORY_FULL_EXPORT · FAILED | **ATTEMPT** | No — separate thread, no inherited tx |
| 7 | `schedulejob/StockSummaryExportJob.java` | `delivered` ⏎ `? WmsConstants.MessageStatus.SENT` … `respMap.get("answer"));` | createMessage | N | fresh thread | E1,E3,hand | INVENTORY_FULL_EXPORT · SENT\|FAILED | **ATTEMPT** — a chunk OMS received cannot be un-received | No |
| 8 | `schedulejob/StockSummaryExportJob.java` | `message = messageService.createMessage(` … `"503", null);` (only assignment-form in this file) | createMessage | N | fresh thread | E1,E3,hand | INVENTORY_FULL_EXPORT · FAILED | **ATTEMPT** | No |
| 9 | `service/OmsNotificationService.java` | `null, processType, WmsConstants.OMS_URL_NOT_CONFIGURED,` ⏎ `WmsConstants.MessageStatus.FAILED, "503", null);` | createMessage | N | **caller's tx** — runs inline in `sendAfterCommit` before the deferral branch; 7 of its callers are `@Transactional` business methods (E3: `ManageOrderService` ×4, `StockChangeNotificationService`) | E1,E3,hand | (any) · FAILED | **ATTEMPT** — "OMS URL not configured" is a config fault; suppressing it because the business tx rolled back hides a standing misconfiguration | **Low** — the callers hold business locks (`Customerorder`, `Pickingorder`), but the message insert needs `FOR KEY SHARE` on `mywms_user`/`client` only, which none of them locks |
| 10 | `service/OmsNotificationService.java` | `payload, processType, urlPath,` ⏎ `WmsConstants.MessageStatus.SENT,` ⏎ `code, answer);` | createMessage | N | **`afterCommit`** (deferred branch) or none (sync branch) | hand (`:84-88` registers `afterCommit() { doSend(...) }`) | (any) · SENT | **ATTEMPT** — strongest case in the table: OMS has the notification. This is a **silent-loss** site today, not a rollback site (§3 case 3) | **Low** — by `afterCommit` the outer tx has committed and released its row locks; only pool slots remain |
| 11 | `service/OmsNotificationService.java` | `WmsConstants.MessageStatus.FAILED,` ⏎ `code, answer);` (the non-2xx arm, below `LOG.error("OMS notification NOT DELIVERED …")`) | createMessage | N | **`afterCommit`** or none | hand | (any) · FAILED | **ATTEMPT** — a delivery failure that vanishes is the worst possible row to lose; silent-loss site | Low |
| 12 | `service/OmsNotificationService.java` | `WmsConstants.MessageStatus.FAILED,` ⏎ `"503", null);` (inside `catch (Exception e)` in `doSend`) | createMessage | N | **`afterCommit`** or none | hand | (any) · FAILED | **ATTEMPT** — transport exception; silent-loss site | Low |
| 13 | `service/job/OutboxDispatchService.java` | `msg.getPayload(),` ⏎ `msg.getProcessType(),` ⏎ `msg.getDestinationUrl(),` (in `private void writeServiceLog`) | createMessage | N | none — `dispatchBatch` javadoc: *"NOT `@Transactional` — each phase is a short, independent tx … Phase 2 HTTP POST runs with no tx held"*; `writeServiceLog` is called from `dispatchOne`, between phases | E1,E2,E3 | (outbox row's own) · SENT\|FAILED | **ATTEMPT** — mirrors the outbox row's own committed outcome | No |

### 6.2 Ingress audits — OMS called WMS (sender = OMS, receiver = WMS)

| # | File | Quoted snippet | Entry | Proxy? | Encl. tx | Derived | Process + status | A/O | Deadlock? |
|---|---|---|---|---|---|---|---|---|---|
| 14 | `controller/rest/AdviceRestController.java` | `MessageProcessType.ADVICE_IMPORT,` … `MessageStatus.RECEIVED,` ⏎ `Integer.toString(status.value()), auditAnswer);` (`auditAnswer` is unique to this site) | createMessage | N | none — `create()` is not `@Transactional`; its own comment at `:524` says so | E1,E2,E4,E5 | ADVICE_IMPORT · RECEIVED | **ATTEMPT** — the comment above it says it outright: *"The ADVICE_IMPORT row is the only durable per-request record"* | No |
| 15 | `controller/rest/AdviceRestController.java` | `MessageProcessType.ADVICE_IMPORT,` … `MessageStatus.FAILED,` ⏎ `Integer.toString(HttpStatus.BAD_REQUEST.value()), null);` | createMessage | N | none | E1,E2,E4,E5 | ADVICE_IMPORT · FAILED | **ATTEMPT** — records a rejected submission; nothing was written to roll back | No |
| 16 | `controller/rest/AdviceRestController.java` | `MessageProcessType.ADVICE_TRANSFER_IMPORT,` … `MessageStatus.RECEIVED,` ⏎ `… HttpStatus.NO_CONTENT.value()` | createMessage | N | none | E1,E2,E4,E5 | ADVICE_TRANSFER_IMPORT · RECEIVED | **ATTEMPT** | No |
| 17 | `controller/rest/AdviceRestController.java` | `MessageProcessType.ADVICE_TRANSFER_IMPORT,` … `MessageStatus.FAILED,` | createMessage | N | none | E1,E2,E4,E5 | ADVICE_TRANSFER_IMPORT · FAILED | **ATTEMPT** | No |
| 18 | `controller/rest/AdviceRestController.java` | `MessageProcessType.ADVICE_HUB_AND_SPOKE_IMPORT,` … `MessageStatus.RECEIVED,` | createMessage | N | none | E1,E2,E4,E5 | ADVICE_HUB_AND_SPOKE_IMPORT · RECEIVED | **ATTEMPT** | No |
| 19 | `controller/rest/AdviceRestController.java` | `MessageProcessType.ADVICE_HUB_AND_SPOKE_IMPORT,` … `MessageStatus.FAILED,` | createMessage | N | none | E1,E2,E4,E5 | ADVICE_HUB_AND_SPOKE_IMPORT · FAILED | **ATTEMPT** | No |
| 20 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_IMPORT,` … `MessageStatus.FAILED,` (the only ORDER_BATCH_IMPORT site in this file; in `catch (WebserviceBusinessExceptionClientSide e)`) | createMessage | N | none — `createAll` has already rolled back and returned | E1,E2,E4,E5 | ORDER_BATCH_IMPORT · FAILED | **ATTEMPT** — and note the asymmetry with #28: today the FAILED row survives while its RECEIVED sibling does not | No |
| 21 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_UPDATE_PRIORITY,` … `MessageStatus.RECEIVED,` | createMessage | N | none | E1,E2,E4,E5 | ORDER_BATCH_UPDATE_PRIORITY · RECEIVED | **ATTEMPT** | No |
| 22 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_UPDATE_PRIORITY,` … `MessageStatus.FAILED,` | createMessage | N | none | E1,E2,E4,E5 | ORDER_BATCH_UPDATE_PRIORITY · FAILED | **ATTEMPT** | No |
| 23 | `controller/rest/OrderRestController.java` | `errors.isEmpty() ? WmsConstants.MessageStatus.RECEIVED : WmsConstants.MessageStatus.FAILED,` (unique in the repo) | createMessage | N | none — each `customerorderService.cancelOrder` has its own tx (comment at `:597`: *"open-in-view is false, giving each cancelOrder its own persistence context"*) | E1,E2,E4,E5,hand | ORDER_BATCH_CANCELLED_FROM_PSD · RECEIVED\|FAILED | **ATTEMPT** — its own comment: *"These rows are the instrument this defect was diagnosed from (8 rows on Hydra PRD …)"* | No |
| 24 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_CANCELLED_FROM_PSD,` … `MessageStatus.FAILED,` ⏎ `… HttpStatus.BAD_REQUEST.value()` | createMessage | N | none | E1,E2,E4,E5 | ORDER_BATCH_CANCELLED_FROM_PSD · FAILED | **ATTEMPT** | No |
| 25 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_QA_FINISHED,` … `MessageStatus.RECEIVED,` | createMessage | N | none — per-order `packageOrder` commits individually | E1,E2,E4,E5 | ORDER_BATCH_QA_FINISHED · RECEIVED | **ATTEMPT** | No |
| 26 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_QA_FINISHED,` … `MessageStatus.FAILED,` | createMessage | N | none | E1,E2,E4,E5 | ORDER_BATCH_QA_FINISHED · FAILED | **ATTEMPT** | No |
| 27 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_FINISHED_TRANSFER,` … `MessageStatus.RECEIVED,` | createMessage | N | none — `billofladingService.finishTransfer` has already returned and committed | E1,E2,E4,E5 | ORDER_BATCH_FINISHED_TRANSFER · RECEIVED | **ATTEMPT** | No |
| 28 | `controller/rest/OrderRestController.java` | `MessageProcessType.ORDER_BATCH_FINISHED_TRANSFER,` … `MessageStatus.FAILED,` | createMessage | N | none | E1,E2,E4,E5 | ORDER_BATCH_FINISHED_TRANSFER · FAILED | **ATTEMPT** | No |
| 29 | `controller/rest/SkuRestController.java` | `MessageProcessType.SKU_IMPORT,` … `MessageStatus.RECEIVED,` ⏎ `Integer.toString(HttpStatus.OK.value()), null);` | createMessage | N | none — `skuBatchCreateUpdateService.upsertAll` has returned and committed | E1,E2,E4,E5 | SKU_IMPORT · RECEIVED | **ATTEMPT** | No |
| 30 | `controller/rest/SkuRestController.java` | `MessageProcessType.SKU_IMPORT,` … `MessageStatus.FAILED,` ⏎ `… HttpStatus.UNPROCESSABLE_ENTITY.value()` — preceded by the correct NOTE at `:171` | createMessage | N | none | E1,E2,E4,E5 | SKU_IMPORT · FAILED | **ATTEMPT** | No |
| 31 | `controller/rest/SkuRestController.java` | `MessageProcessType.SKU_UPDATE,` … `MessageStatus.RECEIVED,` ⏎ `Integer.toString(HttpStatus.OK.value()), null);` | createMessage | N | none — `upsertAll` holds the itemdata `FOR UPDATE` locks (`:248`) but has **committed and released them** before this line | E1,E2,E4,E5,hand | SKU_UPDATE · RECEIVED | **ATTEMPT** | No — the locks are gone by the time this runs |
| 32 | `controller/rest/SkuRestController.java` | `MessageProcessType.SKU_UPDATE,` … `MessageStatus.FAILED,` — preceded by the correct NOTE at `:315` | createMessage | N | none | E1,E2,E4,E5 | SKU_UPDATE · FAILED | **ATTEMPT** | No |
| 33 | `controller/rest/TransactionReportRestController.java` | `MessageProcessType.REPORT_TRANSACTION_SUMMARISED,` … `MessageStatus.RECEIVED,` | createMessage | N | none — read-only report handler | E1,E2,E4,E5 | REPORT_TRANSACTION_SUMMARISED · RECEIVED | **ATTEMPT** | No |
| 34 | `controller/rest/TransactionReportRestController.java` | `MessageProcessType.REPORT_TRANSACTION_SUMMARISED,` … `MessageStatus.FAILED,` | createMessage | N | none | E1,E2,E4,E5 | REPORT_TRANSACTION_SUMMARISED · FAILED | **ATTEMPT** | No |
| 35 | `controller/rest/TransactionReportRestController.java` | `MessageProcessType.REPORT_TRANSACTION_DETAILED,` … `MessageStatus.RECEIVED,` | createMessage | N | none | E1,E2,E4,E5 | REPORT_TRANSACTION_DETAILED · RECEIVED | **ATTEMPT** | No |
| 36 | `controller/rest/TransactionReportRestController.java` | `MessageProcessType.REPORT_TRANSACTION_DETAILED,` … `MessageStatus.FAILED,` | createMessage | N | none | E1,E2,E4,E5 | REPORT_TRANSACTION_DETAILED · FAILED | **ATTEMPT** | No |
| 37 | `service/OrderBatchCreationService.java` | `// save service log once for all batches — REQUIRES_NEW commits independently of the outer tx` ⏎ … `MessageProcessType.ORDER_BATCH_IMPORT,` … `MessageStatus.RECEIVED,` | createMessage | N | **`createAll`'s own tx** (`:69`, `tenantTransactionManager`, `rollbackFor = {WebserviceBusinessExceptionClientSide, BusinessException}`) | E1,E2 | ORDER_BATCH_IMPORT · RECEIVED | ⚠ **OUTCOME** — the only such verdict in the table. See §6.4. | **Low** — `createAll` writes `customerorderbatch`/`customerorder`/`customerorderposition`/`shipperid` and takes **no** pessimistic lock and no lock on `client` or `mywms_user`. The cost is **+1 pool slot**, not a lock inversion. See §7. |

### 6.3 Ops watchdog rows — the two proxy sites (sender = WMS, receiver = OPS)

| # | File | Quoted snippet | Entry | Proxy? | Encl. tx | Derived | Process + status | A/O | Deadlock? |
|---|---|---|---|---|---|---|---|---|---|
| 38 | `schedulejob/PendingReversalReconciliationJob.java` | `messageService.createServiceLog(` ⏎ `WMS_SENDER, OPS_RECEIVER, body, PROCESS,` ⏎ `null, WmsConstants.MessageStatus.CREATED, null, null);` | **createServiceLog** | **Y** | none — enclosing `reconcileCurrentTenant` is private and un-annotated; its caller `reconcile()` is `@Scheduled` only, with no `@Transactional` anywhere in the chain (E1,E2,E3) | E1,E2,E3 | PENDING_REVERSAL_RECONCILE · CREATED | **ATTEMPT** — the row *is* the alert; REQUIRES_NEW here just opens the only transaction | No |
| 39 | `service/BillofladingService.java` | `messageService.createServiceLog(WmsConstants.SERVICE_LOG_SENDER_WMS, WmsConstants.SERVICE_LOG_RECEIVER_OPS, body,` ⏎ `PENDING_REVERSAL_SHIPPED_PROCESS, null, WmsConstants.MessageStatus.CREATED, null, null);` | **createServiceLog** | **Y** | **`afterCommit`** — registered by `reportPendingReversalsOnShippedPallets`, called from `closeBOL` (`:686`) and `finishTransfer` (`:1618`), both `@Transactional(tenantTransactionManager)` | hand, E3 | PENDING_REVERSAL_SHIPPED · CREATED | **ATTEMPT** — the BOL has shipped; the record must outlive anything | No — already `REQUIRES_NEW`, already in production, and by `afterCommit` the outer row locks are released (its own javadoc at `:1677` says so) |

### 6.4 The two internal self-calls

| # | File | Quoted snippet | Entry | Proxy? | Encl. tx | Derived | Process + status | A/O | Deadlock? |
|---|---|---|---|---|---|---|---|---|---|
| I-1 | `service/MessageService.java` | `Message failed = createMessage(` … `MessageStatus.FAILED,` ⏎ `"503", null);` (in `resendMessage`'s transport `catch`) | createMessage (unqualified) | N | none — `resendMessage` is un-annotated; its caller is a controller endpoint | E1,E2 | (original row's process) · FAILED | **ATTEMPT** — an operator pressed resend and it failed | No |
| I-2 | `service/MessageService.java` | `Message newMessage = createMessage(` … `HttpRestService.isSuccess(respMap) ? MessageStatus.SENT : MessageStatus.FAILED,` | createMessage (unqualified) | N | none | E1,E2 | (original row's process) · SENT\|FAILED | **ATTEMPT** | No |

⚠ **Both are hostile to a `REQUIRES_NEW` on `createMessage`.** `resendMessage` mutates and re-`save()`s
the returned `Message` (`failed.setResent(true); failed.setRedeliverId(...); messageRepository.save(failed);`).
If `createMessage` became `REQUIRES_NEW` *and* were routed through a proxy, the returned entity would be
**detached** at those four lines and the `setResent`/`setRedeliverId` updates would be lost or would
re-insert. The v1 plan flags exactly this at the end of its §3.3. In v2 the self-call means a bare
annotation on `createMessage` leaves these two sites un-proxied and therefore *accidentally* safe — but
anyone who "completes" the fix with a self-injected proxy breaks them. This is the single most likely
way to turn this ticket into a new defect.

---

## 6.5 The one OUTCOME verdict, justified

Site #37 (`OrderBatchCreationService:212`) is the only site whose row is written **before** the business
transaction it describes has committed. It writes

> process `ORDER_BATCH_IMPORT`, status `RECEIVED`, `statuscodeanswer = "204"`

inside `createAll`. The `"204"` is a claim about the HTTP response the request will receive. If
`createAll` then throws, the controller returns **400**, and a surviving row would assert a 204 that was
never sent. Making this site `REQUIRES_NEW` would make a **false** row durable.

The right shape here is not `REQUIRES_NEW` — it is to **move the write out of `createAll` and up into
`OrderRestController.create()`**, after `createAll` returns, next to its existing FAILED sibling (#20).
That makes the pair symmetric (today the FAILED row survives and the RECEIVED one does not), removes the
only enclosing transaction in the whole table, and removes the only new pool slot (§7). It also deletes
the false comment rather than relocating it.

I am recording this as the analysis, not as the decision — the sentence that needs Nam's yes is "the
RECEIVED row describes the response, so it belongs after the commit, not inside it."

**Everything else in the table is ATTEMPT.** The unifying rule, which is more durable than the
39-row enumeration: *a `message` row records an interaction across the WMS/OMS boundary — an inbound
request that arrived, or an outbound POST that was made. Both are facts about the outside world, and no
rollback of WMS-internal state can un-make them.* The one exception is a row that quotes a response code
the request has not yet returned.

---

## 7. Pool-slot arithmetic — the real cost, not a lock inversion

Because `SequenceTransactionService.getNextSequenceNumber` is **already** `REQUIRES_NEW` on a separate
bean, the nesting depth today and after a fix is:

| | today | with `REQUIRES_NEW` honoured |
|---|---|---|
| site with no enclosing tx (34 of 39) | seq tx (1 conn, commits and releases) → row insert (1 conn) — **peak 1** | identical — **peak 1** |
| site #37, inside `createAll` | outer `createAll` (conn 1) + seq tx (conn 2) — **peak 2** | outer (conn 1) + `createServiceLog` (conn 2) + seq tx (conn 3) — **peak 3** |

So the pre/post delta is **+1 concurrent connection at exactly one site**. The tenant pool is
`tc.getMaxPoolSize()` with a default of 5 (`TenantDynamicRoutingDataSource:200`), and
`application.properties:111` records that *"prd's only active `tenant_db_configuration` row is
`max_pool_size=5`"*. Three of five slots for one order-batch import is a real number, but it is bounded
and it is a cron-free, request-path operation. Moving the write to the controller (§6.4) removes it
entirely.

**No lock-ordering hazard at any of the 39.** Derived by intersecting the §5 lock inventory with the §4
enclosing-transaction walk: the only site with an enclosing transaction is #37, whose transaction holds
no `@Lock(PESSIMISTIC_WRITE)`, no native `FOR UPDATE`, and no lock on `client` or `mywms_user` — the only
two tables an INSERT into `message` needs a `FOR KEY SHARE` on. The sequence hop itself does take
`LosSequencenumberRepository.findByClassnameForUpdate` (`PESSIMISTIC_WRITE`), but it already does so
today at all 41 sites, and nothing else in the codebase locks the `los_sequencenumber` row for
`WEBSERVICE_MESSAGE`. Blocking is in any case bounded: `wms.tenant.lock-timeout-ms=3000` is applied as
`SET LOCAL lock_timeout` per lock acquisition by `LockTimeoutHibernateJpaDialect`.

---

## 8. Sibling sweep — every propagation claim about these two methods

Method: four greps over the extracted `src/main` **and** `src/test` — `does NOT fire|does not fire`,
`commits independently|commit independently`, `REQUIRES_NEW` filtered to lines also mentioning
service-log/createMessage/createServiceLog/audit, and `self-invo|self invo|selfInvo`. A fifth pass on
`same bean|same-bean|proxy-based|through the proxy|bypasses the proxy` found no additional claim about
*these* methods. **Blind spot:** a comment that describes the behaviour without naming propagation, the
proxy, or either method name would be missed by all five.

**Exactly 4 comments in `src/main` make a propagation claim about `createServiceLog` or `createMessage`.
Zero in `src/test`.**

| # | File | Quoted snippet | Verdict |
|---|---|---|---|
| S1 | `controller/rest/SkuRestController.java` (above site #30) | `// NOTE: MessageService.createMessage internally self-invokes createServiceLog on the same bean,` ⏎ `// so its @Transactional(REQUIRES_NEW) does NOT fire (see plan §3.4). The log persists here` ⏎ `// because no outer tx is active, NOT because REQUIRES_NEW provides isolation.` | ✅ **TRUE** — and it states the mechanism *and* the reason the row survives anyway. This is the wording the other sites should converge on. |
| S2 | `controller/rest/SkuRestController.java` (above site #32) | identical text | ✅ **TRUE** |
| S3 | `service/OrderBatchCreationService.java` (above site #37) | `// save service log once for all batches — REQUIRES_NEW commits independently of the outer tx` | ❌ **FALSE** — the proxy is bypassed, so there is no REQUIRES_NEW, and this row is the **one** in the whole codebase that genuinely rolls back with its caller. The comment asserts the exact opposite of the behaviour at the one site where it matters. |
| S4 | `service/BillofladingService.java:1675-1679` (javadoc above site #39) | `rollback as a false "shipped" record. {@code createServiceLog} is REQUIRES_NEW, which is required` ⏎ `here — a REQUIRED write from afterCommit would join the finished transaction and be lost — and it` ⏎ `briefly holds a second pool connection while the outer one is still being released` | ✅ **TRUE as written, at this site** — this is one of the two proxy sites, so the annotation really does fire. ⚠ But the bare clause *"`createServiceLog` is REQUIRES_NEW"* reads as a property of the method rather than of this call. Any reader who carries it to a `createMessage` site gets S3's error. Worth a four-word qualifier (`…is REQUIRES_NEW, and reached here through the proxy…`) rather than a rewrite. |

**Adjacent but not about these methods** — listed so a future sweep does not re-flag them:
`OutboxService:19` (`All mark* methods use REQUIRES_NEW so each row's outcome commits independently`) and
`RestIdempotencyService:266` are both TRUE and about different beans; `OutboxDispatchService:123`
(*"separate bean, so Spring proxy enforces REQUIRES_NEW correctly"*) is TRUE and about `outboxService`,
not `messageService`.

---

## 9. Existing test coverage — structurally blind, confirmed

### 9.1 `MessageServiceUnitTest`

Blind, for **two independent reasons**, either of which alone is sufficient:

1. `@InjectMocks private MessageService messageService;` — a **raw instance**, never a Spring bean, so
   there is no CGLIB proxy in the test at all. The distinction between a proxied and a self-invoked call
   does not exist in this harness.
2. `@Mock private MessageRepository messageRepository;` and `@Mock private BasicService basicService;`.
   The three assertions in the `CreateMessage` nest are:
   - `assertThat(result.getSender()).isEqualTo("WMS")` and siblings — field copies off the returned
     in-memory object;
   - `verify(messageRepository).save(any(Message.class))` — proves `save` was **called**, which is true
     in every propagation scenario including the silent-loss one;
   - `assertThat(result.getOperatorId()).isEqualTo(100L)` — operator resolution.

**No assertion in this class would have to change.** `verify(messageRepository).save(...)` is precisely
the assertion that cannot distinguish "called and committed" from "called and discarded", because
Mockito's stub returns before the persistence context ever matters. Adding propagation assertions here is
not possible — you would be asserting about a proxy that the harness does not construct.

### 9.2 Other tests that touch these methods

39 `verify(messageService).createMessage(...)` / `createServiceLog(...)` call-verification sites across
`AdminActionControllerUnitTest`, `ItemDataControllerUnitTest`, `AdviceRestControllerUnitTest`,
`OrderRestControllerUnitTest`, `TransactionReportRestControllerUnitTest`, `StockSummaryExportJobUnitTest`,
`OmsNotificationServiceUnitTest`, `OutboxDispatchServiceUnitTest`, `PendingReversalReconciliationJobUnitTest`,
`BillofladingServiceUnitTest`. Every one of them mocks `MessageService` itself, so they assert the
*arguments* of the call and nothing about what the row does afterwards.

Two integration tests mock it away explicitly, and say why:

- `CancelOrderRollbackIntegrationTest:90` — `// MessageService is mocked so OmsNotificationService.doSend's createMessage call` ⏎ `// doesn't need a fully-seeded Message entity (clientId, operatorId, etc.).`
- `NestedSendAfterCommitIT` — `@MockitoBean private net.aim_ai.wms.service.MessageService messageService;`
  with a javadoc stating *"The invariant under test is 'does the nested callback reach the transport at
  all' — the audit write is downstream of it"*.

So the repo has a full-context test that drives the exact afterCommit path and deliberately stops one
layer short of the row.

### 9.3 The concrete harness a real test would use

**`BaseRollbackIntegrationTest`**, not `BaseIntegrationTest`. The distinction is load-bearing:

- `BaseIntegrationTest` carries a class-level `@Transactional("tenantTransactionManager")`, so every
  test method runs inside a test transaction that is rolled back at the end. Service `@Transactional`
  boundaries are **not** real there, and every `createMessage` site would appear to be "inside a
  transaction". It cannot grade this ticket.
- `BaseRollbackIntegrationTest` **intentionally omits `@Transactional`** — its own javadoc, quoted as
  the two source lines it occupies:
  `* Intentionally omits @Transactional so that service @Transactional boundaries` /
  `* are real: each test method can observe whether a rollback actually occurred.`
  That is the harness. `NestedSendAfterCommitIT` already extends it.

Three traps a test on this base must handle, all of them already documented in-repo:

1. **Seed `los_sequencenumber` for `WEBSERVICE_MESSAGE` first.** `NestedSendAfterCommitIT`'s javadoc
   records that `SequenceTransactionService.getNextSequenceNumber` creates a `LosSequencenumber` without
   setting its `@Version`, and since `classname` is the `@Id` Hibernate treats it as detached — *"the
   first use of ANY sequence key with no existing row fails. Live tenants escape only because migrations
   seed their rows."* A test that does not seed the row fails for the wrong reason and reads as a
   reproduction.
2. **Seed `mywms_user` (incl. the anonymous user) and `client`.** `message` has real FKs to both (§5),
   and `createServiceLog` falls back to `userRepository.findByName(WmsConstants.USER_ANONYMOUS)`.
3. **Assert by primary key, never `isEmpty()`/`hasSize()`.** Repository tests in this repo commit rather
   than roll back when they get the wrong transaction manager, so a count-based assertion can pass on
   residue from a sibling test.

A **deadlock** assertion would additionally need Testcontainers rather than the H2 lane, because
`SET LOCAL lock_timeout` is PostgreSQL-only and `LockTimeoutHibernateJpaDialect:150` degrades to a WARN
on H2. `PostgresDeadlockDetectorControlIT` is the existing precedent.

---

## 10. Cross-version note — v1 SBDEV-3266

### 10.1 §4 has already been corrected — today, citing this ticket

`sbdocs/1-Projects/wms1/plan/SBDEV-3266-oms-message-rows-lost-in-aftercommit.md` §4 now opens:

> ⚠️ **CORRECTED 2026-10-07 (SBDEV-3674). The original text of this section was false, and it is why
> v2 was never swept.**

and quotes the old text as a blockquote. **The sentence you asked me to refute is no longer asserted** —
it survives only as a quotation of what was removed. So the answer to "what in §4 is false" is: nothing
is, as of the current file; the correction landed before I read it.

For the record, the original claim and its corrected form:

| | |
|---|---|
| **was** | *"v2 already has `@Transactional(REQUIRES_NEW)` on its `createServiceLog` … **Nothing here ports forward.**"* |
| **should be** | "v2 carries the annotation on `createServiceLog`, but it is honoured at **2 of 41** call sites. The other 39 reach it through `createMessage`, which calls it unqualified on `this`, so the proxy is bypassed and §3.2 Option 1's own verdict — *inert* — applies. The bug class ports forward in full." |

The self-contradiction you identified was real and is exactly why it was wrong: §3.2 Option 1 declares
`@Transactional(REQUIRES_NEW)` on `createServiceLog` **"Inert. … Spring's proxy is bypassed, so the
annotation is never honoured"**, and §4 then cited the presence of that same annotation in v2 as proof
v2 was protected. The corrected text says so itself.

### 10.2 Two residual inaccuracies in the corrected §4

- **"the other 37 external call sites, in 12 files"** — 37 is the `createMessage`-only count, whose file
  count is **10**; 12 is the file count for all **39**. One or the other number should move. (§1.)
- ⚠ **"Its largest exposure is … on Hydra PRD 235 of 237 advice imports have no `ADVICE_IMPORT`
  service-log row, from a controller that carries no `@Transactional` at all."** The second clause
  **refutes the first**: a controller with no `@Transactional`, under `open-in-view=false`, has **no
  enclosing transaction**, so the row has nothing to roll back with. SBDEV-3674's mechanism cannot
  explain those 235.

  I probed it (**D1**, Hydra PRD, read-only):

  | | |
  |---|---|
  | `advice` rows | 237 (235 `REGULAR`, 2 `RETURN`), 2026-07-12 → 2026-09-30 |
  | `message` rows with `process='ADVICE_IMPORT'` | **2** — created 2026-08-05 and 2026-09-23 |
  | advices with any `message` row within −5s/+30s, by type | `RETURN` **2 of 2**; `REGULAR` 108 of 235 (and the 108 are `INVENTORY_FULL_EXPORT` cron traffic, not import rows) |

  The 2 `ADVICE_IMPORT` rows line up with the 2 `RETURN` advices — the OMS QA return flow, which
  `CLAUDE.md` records as calling `PUT {host}/rest/advice/create`. Static read: `adviceRepository.save`
  has **7 call sites outside** `AdviceRestController.create()` — `ReceivingService:238`,
  `AdviceService:268/319/433/467`, `FileImportController:500` — and `AdviceRepository` is **SDR-exported**
  (`@RepositoryRestResource(collectionResourceRel = "advice", path = "advice")`, no `exported = false`),
  so `POST /api/advice` creates an advice with no service-log row by design.

  **Most probable reading: the 235 `REGULAR` advices never entered that controller, so no row was ever
  attempted.** That is an endpoint-usage fact, not a lost write, and it should not be carried into
  SBDEV-3674's §0 as this ticket's "largest exposure".

  **Confidence: high on the refutation, UNSURE on the replacement.** I did not identify which of the 8
  paths actually creates Hydra's `REGULAR` advices; proving that needs a separate probe (correlate
  `advice.created` against `goodsreceipt`, or check the OMS side's egress log). Until someone does, the
  honest §0 sentence is "the `ADVICE_IMPORT` gap is not yet attributed to this defect."

### 10.3 v1 §3.2 Option 2 and §3.3 — what transfers and what does not

**v1 considered and rejected** annotating `createMessage` itself (Option 2), on two grounds:

- **blast radius** — all 50 external callers would get it at once, including every controller export
  path;
- **semantics** — *"it would make it impossible for any message row anywhere to roll back with its
  business transaction, which §3.3(2) justifies only for paths where a POST demonstrably happened."*

It **chose** Option 3 instead: route 10 specific `createMessage` calls in `ManageOrderService` to
`createMessageInNewTransaction`, a method that already existed, was already `REQUIRES_NEW`, and was
already proven in production by `BolClosedEventListener`. §3.3 then enumerated the blast radius honestly:
of 9 non-deferred sites in those five methods, **6 had no live transaction** (so REQUIRES_NEW just
becomes their only transaction) and **3 did** (`ReleaseOrderJobService.releaseOrder`), all three in a
scheduled job off the request path. Its pool arithmetic is the same shape as §7 here, including the same
correction: the `getNextSequenceNumber` REQUIRES_NEW hop was already in the baseline, so the real depth
on those 3 sites is 3 connections where it was 2 — **delta +1**.

**Transfers to v2 unchanged:**

- The **pool-slot framing**, verbatim: *"Pool exhaustion counts simultaneously-held slots, not elapsed
  milliseconds."* v2's tenant pool is 5 on prd, so this binds harder here than it did in v1.
- The **semantic test** — survive a rollback only where the interaction demonstrably happened. v2's
  answer differs from v1's only because v2's population differs: 38 of 39 v2 sites sit outside any
  transaction, so for them the test is moot and the question is the **afterCommit silent loss** instead.
- The **carve-out**: a FAILED row can survive on a path where the POST did not fire
  (serialization threw first), so *do not describe a surviving row as proof the POST happened*. Applies
  verbatim to v2 sites #5, #8 and #12.
- The **"do not extend this to `resendMessage`"** warning, for the detached-entity reason — §6.4 above.

**Does NOT transfer:**

- **Option 3 is unavailable in v2.** v2 has **no `createMessageInNewTransaction`**. v1 could route
  specific callers to an existing, production-proven REQUIRES_NEW method; v2 would have to *create* one,
  which removes Option 3's entire advantage (zero new surface, already proven) and turns it into Option 4
  in v1's own table, which v1 rejected.
- **Option 2's blast-radius objection lands differently.** v1 weighed 50 sites that *would start* behaving
  differently. In v2, 34 of 39 sites have no enclosing transaction, so `REQUIRES_NEW` there changes the
  connection count by **zero** and the behaviour by **nothing** — it becomes their only transaction, as
  it already does today via `save`'s `REQUIRED`. The *real* blast radius of annotating `createMessage` in
  v2 is: **1 site changes rollback semantics** (#37, and §6.4 argues that one wants relocating rather than
  annotating), **4 sites change from silently-lost to persisted** (#10–#12 and #9, which is the point of
  the ticket), and **2 self-call sites are not reached at all** (I-1, I-2 — and must not be, §6.4).
  That is a far narrower blast radius than v1's 50, and it is the main reason v2's option set is not v1's.
- **v1's Option 1 verdict ("inert, not a hazard")** is true in v1 because `createServiceLog` had **0**
  external callers there. In v2 it has **2**, and both already rely on the annotation firing
  (`BillofladingService:1676` explicitly). So in v2 the annotation is **not** dead code and must not be
  removed as part of "cleaning up an inert annotation" — a plausible and wrong simplification.

---

## 11. What I did not establish

- Which code path actually creates Hydra PRD's 235 `REGULAR` advices (§10.2).
- Whether ShipItEZ and WineCo show the same per-process distribution — D1 covered Hydra PRD only.
- Whether `OmsNotificationService.sendAfterCommit`'s inline `:56` branch (#9) is ever reached inside a
  transaction *in practice*; I established that 7 of its callers are `@Transactional`, not that the
  `urlPath == null` branch has fired on any of them.
- The 6-argument `createMessage` overload (`…, String destination, String stateCode)`, which hard-codes
  `MessageStatus.CREATED`: every one of the 39 external sites and both internal ones passes 8 arguments.
  I did not run an argument-arity count to confirm the 6-arg overload is dead, so this is an observation
  from reading the I2 output, not a verified claim.
