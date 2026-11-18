# Lane 3: side effects vs transaction boundaries (dual-write and atomicity)

Code audited: `scratchpad/wms2-develop/src/main/java` (detached origin/develop df30fa62). Read-only.
Docs read first: tx-osiv map §4.3, §6, §10 (landmines 5–7); oms-integration-map outbox / sendAfterCommit notes.
Paths below are relative to `src/main/java/net/aim_ai/wms/`.

## Summary

| # | Sev | Conf | Finding | Status |
|---|---|---|---|---|
| F1 | MEDIUM | HIGH | `StockunitService.transferStock` prints a CUPS label INSIDE the tenant tx, after pallet/UL row locks are taken. A printer outage rolls the stock transfer back, and a label can print for a transfer that then fails at commit. | NEW |
| F2 | MEDIUM | MEDIUM | `afterCommit` OMS POSTs (`OmsNotificationService.doSend`) still hold the tenant JDBC connection. Hibernate runs in `DELAYED_ACQUISITION_AND_HOLD`, so a slow OMS (up to 5 s + 15 s) keeps a pool-5 slot plus a second slot for the REQUIRES_NEW service-log row. The sbdocs contradict each other on this. | NEW (contradicts one doc) |
| F3 | MEDIUM | MEDIUM | `ReleaseOrderJobService.releaseOrder` (REQUIRES_NEW) runs nested inside the streaming readOnly tx. Its ON_HOLD `sendAfterCommit` POST can then hold 3 tenant connections for up to 20 s per on-hold order. | NEW instance of landmine 5 + F2 |
| F4 | MEDIUM | HIGH (mechanism) / PLAUSIBLE (occurrence) | Optional picking-date and priority callbacks enqueue on aggregate `CUSTOMER_ORDER`, the same fail-closed ordering chain as RELEASE/STARTED/FINISHED/CANCEL. If one of them terminally fails, every later lifecycle event for that order is held. | NEW instance of the known stuck-aggregate pattern |
| F5 | LOW | HIGH | Outbox `markSent/markRetry/markTerminal` are unconditional, and claim/reclaim are native UPDATEs that do not bump `@Version`, so nothing fences a claim. Safety rests entirely on the per-lane session advisory lock. If `markSent` fails after a 2xx, the row goes to `markRetry` and is POSTed again. | NEW (latent) |
| F6 | LOW | HIGH | `StockSummaryExportJob` commits `inventory_record` rows per batch (REQUIRES_NEW) before that batch's OMS chunk is queued or sent. An aborted export leaves a snapshot that OMS never received. | NEW |
| F7 | LOW | MEDIUM | `UserController.createUser/updateUser` write Keycloak and the tenant DB in sequence with no compensation. `if (passwordChange)` can unbox null and NPE after both writes. | NEW |
| F8 | LOW | HIGH (putaway controller) / MEDIUM (service-only) | `@CacheEvict` runs before the controller-level tx commits (`PutawayConfigController.setMerchant/setWarehouse`), so a concurrent read can re-warm the pre-commit value for the full TTL. | KNOWN (accepted in `SdrCacheEvictionEventHandler` javadoc); new concrete sites |
| F9 | DOC | HIGH | tx-osiv map §6 table has drifted. `MobileReplenishService` registers nothing now, and 5 real registration sites are missing. | DOC DRIFT |
| F10 | INFO | HIGH | `HttpInTransactionArchTest` only catches *direct* `HttpRestService` calls, so it is blind to CUPS/IPP (F1), Keycloak and transitive calls. | RAIL GAP |

No CRITICAL/HIGH finding at HIGH confidence. No case found where OMS is told "shipped/done" and the WMS
then rolls back: every lifecycle notification is either outbox-MANDATORY (atomic) or deferred to afterCommit.

---

## F1: CUPS print inside the transfer transaction, under row locks  [MEDIUM / HIGH] NEW

- **Site:** `service/StockunitService.java:448-449` declares `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` on `transferStock`. Line 879 is `printService.cupsPrint(printer, caseLabel);`, the last statement of the method, inside the tx.
- **Locks held at that point:** on the pallet arm, `LockReads.forUpdate(... unitloadRepository::findByIdForUpdate)` at :540 (destination pallet `FOR UPDATE`). The in-code comments at :471-480 say `transferStockToUnitLoad` also locks the source unit load. I did not read the body of `transferStockToUnitLoad`.
- **Callee read:** `service/PrintService.java:103-170`. `submitCupsJob` makes two IPP round trips (`cupsClient.getPrinter(url)` then `cupsPrinter.print(job)`), and the app sets no explicit timeout on `CupsClient`, so any bound comes from cups4j's own defaults (not verified). Any exception becomes `FacadeException("PRINT_FAILED …")`.
- **Failure scenarios:**
  1. **Printer or CUPS outage rolls the stock move back.** `FacadeException` is in `rollbackFor`. The bulk endpoint `controller/StockUnitController.java:284` catches it per row, so during a CUPS outage *every* row of a "transfer + print label" batch reports `PRINT_FAILED` and none of them move. A missing default INBOUND printer (`EntityNotFoundException`, a RuntimeException, at :877) has the same effect.
  2. **Locks held across network I/O.** Other operators who touch the same pallet or unit load wait on `lock_timeout` (`LockTimeoutHibernateJpaDialect`) and fail with `PessimisticLockingFailure` while the IPP calls run.
  3. **Phantom label.** The print happens before commit-time flush. A flush or `@Version` failure at commit rolls back a split whose new unit-load label is already printed. The label number came from a REQUIRES_NEW draw (SBDEV-4047 comment at :524-528), so it is also burned.
- **Sibling inconsistency (invariant-over-instance):** `setLockDamaged` (:1037) prints *after* its helper tx has committed and swallows print failure. See the SBDEV-3086 F2/M1 comment at :1110-1125, which gives exactly this reasoning. `transferStock` was not given the same treatment. `CancellationReversalService:449` passes `printLabel=false`, so RTS is not affected.
- **Fix:** move the print out of the tx. Either `ReceivingService.printAfterCommit` (:763) or the `setLockDamaged` swallow-and-warn shape works. Use `cupsPrint` (not Checked) and catch `FacadeException`. Extend the arch rail (F10).

## F2: afterCommit HTTP still holds the tenant connection  [MEDIUM / MEDIUM] NEW, contradicts a doc

- **Mechanism (code + Spring/Hibernate defaults, not measured):**
  - `landlord/config/TenantDatabaseConfig.java:108-112` uses a bare `HibernateJpaVendorAdapter`. Its default `HibernateJpaDialect.prepareConnection=true` makes it put `hibernate.connection.handling_mode=DELAYED_ACQUISITION_AND_HOLD` into the EMF property map.
  - `application.properties` does not override `handling_mode` (grep: 0 hits).
  - `LockTimeoutHibernateJpaDialect.beginTransaction` (:208-220) acquires the connection at tx begin via `doWork(SET LOCAL lock_timeout)`.
  - Under HOLD the physical connection is released only when the EntityManager closes, in `JpaTransactionManager.doCleanupAfterCompletion`. That runs after `triggerAfterCommit` and `triggerAfterCompletion`.
- **Site:** `service/OmsNotificationService.java:84-96` registers `afterCommit → doSend`, and `doSend` (:116-170) calls `httpRestService.post` (connect 5 s / read 15 s, `HttpRestService.java:49-50`) and then `messageService.createMessage` (REQUIRES_NEW via `self`, `MessageService.java:110`). That is a second connection while the first is still held.
- **Hot path:** `MessageService.sendStockChangeMessage` → `StockChangeNotificationService.sendAfterCommit` → this path. It runs on every stock change from about 14 call sites (UnitloadService, StockunitService ×5, GoodsReceiptPositionService ×2, ReceivingService, MobileCycleCountService ×2, MobileMoveUnitloadService ×2). The 4 remaining `ManageOrderService` callbacks also use it.
- **Failure scenario:** OMS is slow or black-holed. Each mobile stock operation keeps its tenant connection, and its request thread, for up to 20 s *after* commit, plus one extra slot for the message row. With per-tenant `maximumPoolSize` 5 (`TenantDynamicRoutingDataSource.java:200`), about 2–3 concurrent operators starve the pool, and unrelated requests fail after Hikari's connection timeout. Row locks are released, so this is pool and latency exposure, not lock exposure.
- **Doc contradiction to resolve:**
  - `sbdocs/1-Projects/wms2/plan/SBDEV-3674-evidence/architect-fix-shape.md:341` says Hibernate "has already released the physical connection in `LogicalConnectionManagedImpl.afterTransaction()` … before `triggerAfterCommit`". That holds only under `…_RELEASE_AFTER_TRANSACTION`.
  - `SBDEV-3547-evidence/review-architect-round1.md:46-47`, `SBDEV-3410-evidence/p3-code-review.md:272` and the javadocs of `ReplenishmentMaintenanceTrigger` and `BillofladingService` (:2006-2010) all assume HOLD.
  - The comment on `ReceivingService.printAfterCommit` (:761, "to avoid holding DB connection during network I/O") rests on the same wrong premise: it avoids holding row locks, not the connection.
- **Probe to settle it:** an IT that registers an `afterCommit` callback and, inside it, reads Hikari `getActiveConnections()` for the tenant pool (or `pg_stat_activity` by `application_name`) and compares the count with the pre-tx baseline.
- **Fix direction:** move the remaining `sendAfterCommit` sites onto the outbox (oms-map "Phase-3"), or hand `doSend` to a bounded tenant-aware executor.

## F3: ON_HOLD POST from a REQUIRES_NEW nested in a streaming tx  [MEDIUM / MEDIUM] NEW instance

- **Path:** `schedulejob/OrderReleaseJob.java:399` → `ReleaseOrderJobService.streamOrderPositionsForEach` (`@Transactional(readOnly=true)`, :946; holds a cursor connection) → callback → `processOrderGroup` → `releaseOrder` (`REQUIRES_NEW`, :132; called at :593) → `customerOrderOnHold` at :262 / :608 → `ManageOrderService.customerOrderOnHold` (:61-105, body read) → `omsNotificationService.sendAfterCommit`.
- **Scenario:** each order that transitions to RAW_ON_HOLD fires its POST after the inner commit. During that POST the job holds: (1) the outer stream connection, (2) the inner connection (F2 HOLD), and (3) the `createMessage` REQUIRES_NEW connection. That is 3 of 5 tenant slots for up to 20 s per order, serially through the tick. On top of that, ON_HOLD has no retry if it fails (FAILED message row only; oms-map:256, known).
- Confidence MEDIUM because it inherits F2's premise. Without HOLD it is still 2 slots for 20 s.

## F4: optional callbacks share the fail-closed CUSTOMER_ORDER ordering chain  [MEDIUM] NEW instance

- **Sites:**
  - `service/PickingDateChangeNotificationService.java:48,107-113` uses aggregate `CUSTOMER_ORDER` with id = CO id.
  - `service/PriorityChangeNotificationService.java:101-104,133-139` uses `CUSTOMER_ORDER` when the order has no batch.
  - These share the chain with RELEASE (`ReleaseOrderJobService:795`), STARTED/FINISHED (`PickingorderBusinessService:401,561,1449`; `CustomerorderBatchService:947-976`), CANCEL (`CustomerorderService:873`), `BillofladingService:1150` and `CancellationReversalService:1007`.
- **Gate:** `repo/jpa/OutboxMessageRepository.java:47-53` keys only on `(aggregate_type, aggregate_id)` and treats `FAILED_TERMINAL` as blocking. It ignores `process_type`.
- **Scenario:** a tenant switches on `…UPDATE_PICKING_DATE_ACTIVATED`, but the OMS endpoint is missing or the URL is still the seeded `CHANGE-ME-FOR-NEW-CLIENT/…` (sysprop catalog :630). The picking-date row gets 404, goes terminal immediately (`OutboxDispatchService.isTerminal` :333-336), and holds PICKING_STARTED/FINISHED/CANCEL for that order indefinitely. The parcel never advances in OMS until someone follows the runbook (`wms2-unstick-held-outbox-aggregate.md`).
- **Fix:** give advisory or non-lifecycle events their own aggregate_type (for example `CUSTOMER_ORDER_META`), or exempt them from blocking in the gate.

## F5: outbox state transitions are not fenced  [LOW / HIGH] latent

- `service/OutboxService.java:81-118` (`markSent/markRetry/markTerminal`) do `findById` + `save`, with no `status='IN_FLIGHT'` predicate.
- `findAndClaimPending` (:37-62) and `reclaimStaleInFlight` (:68-79) are native UPDATEs that do not increment `version`, so `@Version` (`model/OutboxMessage.java:102`) cannot detect a re-claim.
- **Today this is safe** because each lane is serialized fleet-wide by `pg_try_advisory_lock` (`schedulejob/OutboxDispatcherJob.java:102-170`, `AdvisoryLockService.java:76-141`), and reclaim (15 min, `OutboxDispatchService:72`) runs only at the start of that lane's own tick.
- **Latent case:** the landlord session holding the advisory lock drops mid-tick. The lock is released silently and the tick continues. A second replica then runs the lane, and a tick longer than 15 min could reclaim and re-POST a row the first replica is still sending, with last-writer-wins on the status.
- **Separate, real today:** `dispatchOne` (:178-215) wraps `markSent` in the same `try`. If `markSent` throws after a 2xx (DB blip), the `catch` calls `markRetry` and the row is POSTed again. That is at-least-once delivery, and it relies on OMS honouring the idempotency key. Also, if `markRetry` then fails, the row stays IN_FLIGHT until the 15-min reclaim.
- **Fix:** add `AND status='IN_FLIGHT'` to the mark updates (native, returning the row count), and catch `markSent` failure separately so it is not treated as a send failure.

## F6: stock-summary export, local snapshot committed before OMS delivery  [LOW / HIGH] NEW

- `schedulejob/StockSummaryExportJob.java:485-534`: per batch, `inventoryRecordService.createEntitiesBulk` (REQUIRES_NEW, documented in §7) commits first, and only then is the chunk `offer`ed to the consumer thread that POSTs (`sendList` :570-685).
- **Scenario:** the consumer dies (OMS read timeout → rethrown, :579-600) or the offer times out, and the export aborts. `inventory_record` still holds rows for chunks that were never sent, or never even queued (the final batch is committed at :523, and its offer can time out at :525). Nothing links an inventory_record batch to its delivery outcome.
- Impact is a reporting/audit snapshot only. **Fix:** record a run id plus a delivered flag, or write the records after a 2xx.

## F7: Keycloak + tenant DB dual write in UserController  [LOW / MEDIUM] NEW

- `controller/UserController.java` around :366-405 (`createUser`): `keycloakService.createSingleUser` runs, then `userService.create` / `userRepository.save`. A RuntimeException from the DB write is not caught, so the caller gets 500 while the Keycloak user exists. A retry then hits "User already exists with the username or email" (:398). Recovery is only through `/import` (:330-362).
- Around :421-470 (`updateUser`): Keycloak is updated first, then the DB save, then `if (passwordChange)` on a `Boolean` read from the request map. That is an NPE when the field is absent, and it fires *after* both writes, so the client sees an error for work that succeeded. The password change itself is a third, separate write.
- No tx is involved, so there is no lock exposure. I did not read the body of `userService.create`.

## F8: cache evicted before the surrounding tx commits  [LOW] KNOWN pattern, new concrete sites

- `controller/PutawayConfigController.java:237,260` (`@Transactional` on the controller) wrap `PutawayConfigService.setMerchantDestination` (:179-183 evicts `clients`) and `setWarehouseDestination` (:231 evicts `sysprops`).
- The `@CacheEvict` fires when the service returns, which is before the controller tx commits. A concurrent reader re-warms the old committed value for the TTL: clients 5 min, sysprops 2 min (`config/CacheConfig.java:36-39`).
- The impact is narrower than it looks: the warehouse tier of `PutawayDestinationResolver` reads the repo directly (:218-224, uncached), so only cached readers are affected. The merchant tier depends on the `Client` the caller passes in, and I did not trace those callers.
- Service-only `@Transactional` + `@CacheEvict` pairs (`setSkuDestination` :133, `LocationService:157,187`, `SyspropService:64,377`) fire inside or outside the tx depending on advisor ordering. Both `@EnableTransactionManagement` and `@EnableCaching` use the default order, so that ordering is not pinned (MEDIUM conf).
- This is accepted on record: `config/SdrCacheEvictionEventHandler.java:109-116` explicitly declines `TransactionAwareCacheManagerProxy` because it would "re-time every existing in-transaction @CacheEvict". Caffeine being JVM-local across replicas is also documented there.

## F9: tx-osiv map §6 drift  [DOC]

`grep registerSynchronization` excluding comments finds 7 live sites:
- `OmsNotificationService:84`
- `ReceivingService:765`
- `ReplenishmentMaintenanceTrigger:106`
- `BolOmsNotificationService:229`
- `ClubRunJobService:263`
- `BillofladingService:1969`
- `BillofladingService:2038`

§6 lists `MobileReplenishService` (0 hits; its deferral moved to `ReplenishmentMaintenanceTrigger`, SBDEV-3286) and omits the last five. The last four are log/metric/service-log/executor-kick only. `ReplenishmentMaintenanceTrigger` uses `afterCompletion`, not `afterCommit`. Fix the doc's afterCommit-releases-connection claim together with F2.

## F10: arch rail scope  [INFO]

`src/test/.../unit/config/HttpInTransactionArchTest.java:63-84` flags only direct calls from `@Transactional` methods to `HttpRestService`. It misses:
- `PrintService.cupsPrint*` (cups4j IPP over HTTP), which is F1
- `KeycloakService` / `KeycloakPasswordVerifier` (none are in a tx today)
- any transitive call through a non-annotated helper

Suggest adding `PrintService.cupsPrint`/`cupsPrintChecked` and `CupsClient` to the forbidden targets, with an allow-list for `ReceivingService.printAfterCommit`.

---

## Checked and found clean (with what was read)

- **OmsNotificationService.sendAfterCommit (:52-112).** The guard needs both sync-active and actual-tx. On rollback the send is suppressed (afterCompletion log). `doSend` writes via the `self.` proxy REQUIRES_NEW, not a REQUIRED write in afterCommit. Failure is swallowed into a FAILED row with no auto-retry; that is KNOWN (oms-map:256). Nesting is guarded by `NestedCallSiteRailTest` per comment; I did not read that test.
- **ReplenishmentMaintenanceTrigger (whole file).** Uses `afterCompletion(STATUS_COMMITTED)` and REQUIRES_NEW via a `TransactionTemplate` on the tenant TM. The tenant is captured at request time and re-asserted, with cross-tenant refusal. Rollback skips the recalc. Failures go to WARN, and the cron is the backstop. The second-connection cost is documented and accepted (Nam 2026-10-08).
- **BolOmsNotificationService.requeue (:178-238).** The audit row is in the caller tx (MANDATORY). afterCommit only logs and meters. `requeueBolTerminal` is `WHERE status='FAILED_TERMINAL'`, so it cannot race the dispatcher (which only touches IN_FLIGHT).
- **BillofladingService.reportChildrenWithoutPosition / reportPendingReversalsOnShippedPallets (:1935-2073).** afterCommit does log/metric and a REQUIRES_NEW service log through the cross-bean proxy. Inactive sync is handled explicitly (inline emit / WARN). Exceptions are caught.
- **ClubRunJobService.kickAfterCommit (:261-284) + ClubRunExecutorConfig.** The executor runs after commit, so the claim sees the committed row. `TenantAwareTaskDecorator` captures the tenant on the request thread. Rejections are counted and not thrown, and the poller is the backstop.
- **ReceivingService.printAfterCommit (:763-775).** Both callers are `@Transactional` (`receiveGoods` :372, `printReceiveLabels` readOnly :708). Print failure is swallowed. It holds the connection per F2, but no row locks.
- **Outbox producers.** All 20 `outboxService.enqueue` sites go through `@Transactional(MANDATORY)` (`OutboxService:41`), so they are atomic with the business write, and a non-tx caller fails loudly. `ReleaseOrderJobService:783` de-dups via `isKeyPresent` (MANDATORY) plus the UNIQUE idempotency_key.
- **Outbox dispatcher.**
  - `dispatchBatch` is non-transactional.
  - Reclaim and claim are each REQUIRES_NEW, using `FOR UPDATE SKIP LOCKED` plus the cross-lane NOT EXISTS order gate. Row locks are committed before the HTTP call.
  - There is one dispatcher per lane fleet-wide (session advisory lock on a pinned landlord connection), and TenantContext is set and cleared per tenant.
  - `cleanupSent` is REQUIRES_NEW.
- **Direct HTTP callers are all outside any tx:**
  - `MessageController → MessageService.resendMessage`
  - `ItemDataController.sendStockUpdate`
  - `AdminActionController:212`
  - `BillOfLadingController:674 → BillofladingService.getFacilities` (class not annotated)
  - `MessageDummyController`
  - `EndpointHealthCheck` and `PlatformVersionCacheService`
  - `TokenController` (Keycloak)
  - `StockSummaryExportJob.sendList`, which runs on a `TenantAwareTaskDecorator` consumer thread. The producer does not POST.
- **Keycloak.** `KeycloakService`, `UserAdministrationController`, `AdminController`, `ManualEntryOverrideService` (explicitly not `@Transactional`; P1-A10 javadoc) and `KeycloakPasswordVerifier` (its own logout pool) are all called with no tx open.
- **Landlord + tenant writes.** `TenantWarehouseProvisioningService.provision` (:146-196) builds the schema first and writes the landlord rows last in `landlordTransaction`, then signals the registry. A partial failure leaves an unrouted DB that the next attempt adopts. Clean by design; I did not read `TenantDatabaseCreator.ensure` (password reset on adoption). Jobs read the landlord DB only.
- **Not present anywhere in `src/main`:** `@Async`, `@TransactionalEventListener`, `ApplicationEventPublisher.publishEvent`, websocket (`SimpMessagingTemplate`), mail (`JavaMailSender`). `KeycloakService.userCache` / `MultiTenantJwtDecoder` caches are not tx-bound.
- **SdrCacheEvictionEventHandler.** It fires after `SimpleJpaRepository.save` has committed (OSIV is off, and there is no outer tx on the SDR path).

## Not done / open

- F2 and F3 are reasoned from configuration and Spring/Hibernate defaults, not measured. Run the probe described in F2 before acting on them.
- I did not read the cups4j default socket timeouts. F1's lock-hold duration is therefore unbounded by app code but may be bounded by the library.
- I did not trace which callers of `PutawayDestinationResolver` obtain the `Client` from the cache (F8).
