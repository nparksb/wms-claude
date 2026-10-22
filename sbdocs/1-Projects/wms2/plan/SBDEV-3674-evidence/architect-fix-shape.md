# SBDEV-3674 — architect lane: the fix shape

**Scope:** questions A–D from the lead. Read-only, all code via `git show origin/develop:<path>` /
`git grep … origin/develop`. No worktree, no `mvn`. DB evidence from the `nywh-hydra-prd` MCP.

---

> ## ⚠ Correction added by the lead session, 2026-10-07 — read before using §A.1
>
> **This lane's recommendation (Option 1, self-injection), its §B deadlock verdict, its §C outbox
> scoping and its §D rail design all stand and were adopted.** One factual claim in §A.1 did not
> survive and is retracted here rather than edited in place, so the reasoning stays auditable.
>
> **Retracted:** *"`customerorder WHERE historytote IS NOT NULL` = 267 against 0 TOTE_ASSIGNED rows —
> ≥66% of the 402 is one process type."* The 267 lost `TOTE_ASSIGNED` notifications are real, but they
> burn **no** sequence numbers, so none of the 402 is attributable to them.
>
> **Measurement that settles it** (per-interval, full table, no sampling): for every interval between
> consecutive surviving `message` rows, count the business activity inside it, split by whether the
> interval burned a number.
>
> | | intervals | numbers burned | `goodsreceiptposition` inside | tote-assigned orders inside |
> |---|---|---|---|---|
> | BURN | 360 | 402 | **518** | **2** |
> | control | 2,639 | 0 | 2 | **265** |
>
> 265 of the 267 tote assignments fall in intervals that burned nothing — that is the discriminating
> half, and it is what retracts the 66% claim.
>
> ⚠ **Second-order correction (critic round 1):** the companion figure quoted here — *"518 of the
> tenant's 522 receipt positions fall inside burn intervals"* — is itself weak and must not be reused.
> It measures containment of a dense clustered stream by wide intervals: **138 of 402 burns occur in
> intervals with zero receipt activity**, and there is no dose-response (334 of 360 burn intervals burn
> exactly 1 and average 0.67 positions, while one interval holding 210 positions burned 3). The
> defensible form is day granularity — 304 burns across 17 receiving days (17.9/day) vs 98 across 69
> non-receiving days (1.42/day), 12.6× — which supports receiving as the **leading contributor at most
> ~66%**, not as the identity of the 402. **The retraction above is unaffected**, because it rests on
> the tote side, not on this number.
>
> **Why the two differ, and why it is the scope boundary with SBDEV-3267.** `TOTE_ASSIGNED` was a
> **double** deferral: `MobilePickingService` registered a synchronization whose callback itself called
> `sendAfterCommit`, so the inner registration landed in the list `triggerAfterCommit` was already
> iterating and was discarded unseen — *"no POST, no message row, no metric"* (its own SBDEV-3267
> comment in `src/main`). `createMessage` is never reached, so no number is spent.
> `STOCK_UPDATE` is a **single** deferral: `StockChangeNotificationService.sendAfterCommit` serializes
> synchronously and calls `omsNotificationService.sendAfterCommit` directly from the caller's
> transaction — it is not itself a callback. So the callback runs, the POST fires, `createMessage`
> allocates a number, and only the row is discarded.
>
> **A burned number therefore means `createMessage` was reached and its row was lost; a zero-row
> process type with no burn means the callback never ran at all.** (⚠ It does **not** mean the
> notification was delivered — `doSend` burns on all three exits, including the transport-exception
> catch where the POST never completed. This sentence was the fourth copy of that error and is
> corrected here too.) Those are opposite operational
> problems, and this is the only instrument that separates them. SBDEV-3674 owns the burns (audit
> loss); SBDEV-3267 owns the silent non-delivery. The 267 must not be added to the 402.

## Summary

Recommend **Option 1, self-injection** (`@Lazy @Autowired MessageService self`), with the two
`createMessage` overloads delegating `self.createServiceLog(...)`. It is a 4-line diff inside one
class, it touches **zero** of the 37 external call sites, and it is a **four-times-established
pattern in this exact package** — `CustomerorderBatchService`, `ReplenishGeneratorService`,
`ReplenishmentOrderMaintenanceService` and `ReturnAdviceAutoReceiveService` all hold a
`@Lazy @Autowired <Self> self` field, and one of them was added to fix *this same class of
proxy-bypass defect*.

The v1 plan's rejection of Option 3 transfers, but **its blast-radius arithmetic does not** — v2's
loss is not spread across 37 sites. DB-verified on Hydra PRD: of the five live `sendAfterCommit`
producers, two (`ORDER_BATCH_PICKING_TOTE_ASSIGNED`, `ORDER_BATCH_ON_HOLD`) have **zero rows ever**,
while the other three have healthy row counts, and all 33 non-`afterCommit` sites are writing rows
fine today. ~~**At least 267 of the 402 missing rows (66%) are one process type**~~ — **RETRACTED,
see the correction block at the top of this file.** `TOTE_ASSIGNED` was a *double* deferral: it burns
no sequence number at all, so none of the 402 is attributable to it. 265 of its 267 fall in intervals
that burned nothing.

On B: the deadlock constraint is **real in principle and empty in practice for this change** — I could
not construct a single site where the inner `message` INSERT would wait on a lock the outer
transaction holds. Do not let it shape the design.

On C: finishing the outbox migration would dissolve the *measured* loss (4 of 39 sites) but leaves
**35 sites structurally permanent**. This is not a holding fix — it is the correct end state, and it
is far cheaper than the migration. Do not sequence it behind Phase 3.

---

## A. Which mechanism — recommend Option 1 (self-injection)

### A.0 First, the fact that reframes the whole question

The lead's census is right (37 via `createMessage`, 2 direct) but **the loss is not distributed over
those 37**. `createServiceLog`'s missing `REQUIRES_NEW` only costs a row where there is an ambient
transaction that is already committed or will roll back. Everywhere else, `messageRepository.save()`
opens its own transaction (`SimpleJpaRepository` is `@Transactional`) and the row commits normally.

`SkuRestController` **already says this in `src/main`**, twice, verbatim:

> `// NOTE: MessageService.createMessage internally self-invokes createServiceLog on the same bean,`
> `// so its @Transactional(REQUIRES_NEW) does NOT fire (see plan §3.4). The log persists here`
> `// because no outer tx is active, NOT because REQUIRES_NEW provides isolation.`

— `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java`, at both the
`create()` and `update()` 422 handlers. The defect was known and documented; what was never done is
make the annotation fire.

Ambient-transaction census of the 39 sites (grep for `@Transactional` per owning class, on
`origin/develop`):

| owner | sites | ambient tenant transaction at the call? |
|---|---|---|
| `AdviceRestController` | 6 | **No** — zero `@Transactional` in the file (only 4 comment lines mentioning it, each saying `create()` is *not* transactional) |
| `OrderRestController` | 9 | **No** — the single `@Transactional` grep hit is a comment |
| `SkuRestController` | 4 | **No** — the 3 hits are the two NOTE comments above plus `// This handler has NO @Transactional` |
| `TransactionReportRestController` | 4 | **No** — zero hits |
| `ItemDataController` | 3 | **No** — the one hit is `"Opens no transaction of its own, deliberately. There is zero @Transactional under"` |
| `AdminActionController` | 2 | **No** — zero hits |
| `StockSummaryExportJob` | 3 | **No** — zero hits |
| `OutboxDispatchService` | 1 | **No** — `dispatchBatch` is `"NOT {@code @Transactional} — each"`, `dispatchOne` and `writeServiceLog` are plain private methods |
| `OrderBatchCreationService` | 1 | **Yes** — `createAll` is `@Transactional(value = "tenantTransactionManager", rollbackFor = {…})` and the call sits inside it |
| `OmsNotificationService` | 4 | **3 of 4 are the loss** — see below |
| direct `createServiceLog` (`BillofladingService`, `PendingReversalReconciliationJob`) | 2 | real `REQUIRES_NEW`, both already post-commit |

*Blind spot:* a class-level `@Transactional` on a superclass would not appear in a per-file grep.
`AdminActionController` and the four `*RestController`s extend `AdminController` /
`AbstractRestController`; I did not grep those two parents, so the "No" for those 24 sites rests on
the owning file only. Worth one grep during implementation — but the DB corroborates it: every one
of those process types has rows (`SKU_IMPORT` 25, `SKU_UPDATE` 16, `ORDER_BATCH_IMPORT` 156+26,
`INVENTORY_FULL_EXPORT` 994, `REPORT_TRANSACTION_DETAILED` 3, `ADVICE_IMPORT` 1+1), so whatever
their annotations say, those rows are committing.

`OmsNotificationService` is where the rows die. `sendAfterCommit` branches:

- **if-branch** (`isSynchronizationActive() && isActualTransactionActive()`) → registers a
  `TransactionSynchronization` whose `afterCommit()` calls `doSend`. The three `createMessage` calls
  in `doSend` then run with `EntityManagerHolder.transactionActive` still set (Spring clears it only
  in `cleanupAfterCompletion`, which has not run), so `save()` **joins a committed transaction and
  the participant's commit is a no-op**. Row discarded. Mechanism confirmed in the v1 sibling plan
  §2.1 against spring-tx sources; the ordering `doCommit → triggerAfterCommit → cleanupAfterCompletion`
  is unchanged in Spring 6.
- **else-branch** → `doSend` runs synchronously, and that branch is reached only when
  `!(syncActive && txActive)`, i.e. **when there is no real transaction**. Row commits fine.
- the fourth site (the `urlPath == null` FAILED row) runs **inline**, before the branch.

### A.1 The DB confirms exactly that split

```
process                             rows   first        last
ORDER_BATCH_PICKING_TOTE_ASSIGNED      0   —            —      ← sendAfterCommit, transactional caller
ORDER_BATCH_ON_HOLD                    0   —            —      ← sendAfterCommit, transactional caller
ORDER_BATCH_PALLETIZED               266   2026-07-16   2026-10-06
ORDER_BATCH_LOADED_TO_TRUCK           53   2026-07-15   2026-10-05
STOCK_UPDATE                          28   2026-07-12   2026-09-24
```

Two instruments, agreeing:

1. **Sequence arithmetic.** `select count(*) from message` = **3001**; `max(number)` = `0000003403`.
   3403 − 3001 = **402**, matching the ticket exactly. `message_archived` holds **0 rows**, so
   `CleanUpOldMessagesJob` (`MessageRepository.deleteMessages` →
   `"DELETE FROM message WHERE id IN (SELECT id FROM message AS m WHERE m.created < :refDate LIMIT :batchSize)"`,
   preceded by an `INSERT INTO message_archived`) has never run on this tenant. **The 402 is not a
   retention artefact** — this was the one confounder that could have voided the whole measurement.
2. **Business-volume arithmetic, independent of the sequence.**
   `count(*) from customerorder where historytote is not null` = **267**, against **0**
   `ORDER_BATCH_PICKING_TOTE_ASSIGNED` rows. 267 tote assignments, 267 lost notifications. This is
   the same instrument the v1 plan used for its Cliff 1, and it reproduces in v2.

~~So ≥267 of 402 (66%) is one process type on one branch.~~ **RETRACTED — see the correction block at
the top.** `TOTE_ASSIGNED` burns nothing (double deferral), so it accounts for none of the 402. The
leading contributor is receiving-driven `STOCK_UPDATE` at **at most ~66%** by day granularity, and
roughly a third of the 402 is unattributed — a missing
row leaves no process type behind, so no query can bucket it; `ORDER_BATCH_ON_HOLD` plus the inline
`urlPath == null` site plus rollback-path FAILED writes are the candidates. **I did not derive that
135, and it should not be asserted as any particular cause.**

Note `PALLETIZED` 266 ≈ `PICKING_FINISHED` 267, and `LOADED_TO_TRUCK` 53 ≈ `SHIPPED` 52 — paired
one-per-batch events tracking each other, so those three producers are losing essentially nothing.
Their callers (`MobilePalletizeWriteService`, `MobileTruckLoadingService`) carry javadoc saying as
much: `"{@code omsNotificationService.sendAfterCommit}, whose branch depends on whether a"` /
`"repository work before it reaches {@code sendAfterCommit}; inside an open transaction a"`.

### A.2 Option-by-option

**Option 1 — self-injection. CHOSEN.**

Not a novel pattern here; it is the sanctioned one. Four existing instances in
`net/aim_ai/wms/service/`:

- `CustomerorderBatchService`: `private CustomerorderBatchService self;` under
  `"Field-level {@code @Lazy} is used because constructor injection is not possible:"` /
  `"Spring cannot resolve a self-referential bean during construction."`
- `ReplenishGeneratorService`: `private ReplenishGeneratorService self;` under
  `"The one sanctioned exception to constructor injection (precedent: ReplenishmentOrderMaintenanceService)."`
- `ReplenishmentOrderMaintenanceService`: `private ReplenishmentOrderMaintenanceService self;` under
  `"<strong>Do not remove:</strong> without this field the sweep path bypasses AOP and"` /
  `"{@code findByIdForUpdate(@Lock PESSIMISTIC_WRITE)} throws {@code InvalidDataAccessApiUsageException}."`
  — **this is the same defect class as SBDEV-3674, already fixed this way in this package.**
- `ReturnAdviceAutoReceiveService`: `"Field-level {@code @Lazy} because constructor injection of self is not possible."`

Answering the lead's specific worry: **it does not interact badly with the existing cycle.**
`MessageService → StockChangeNotificationService → OmsNotificationService → MessageService` is broken
by `@Lazy` on the `stockChangeNotificationService` field. A self-reference is a *different* edge
(`MessageService → MessageService`), resolved by Spring's self-reference fallback in
`DefaultListableBeanFactory`, and `@Lazy` makes it a deferred proxy so it cannot deepen the cycle —
it is resolved after `MessageService` is fully constructed, exactly as the other four do it.

CGLIB is not a problem either: `MessageService` is declared `public class MessageService {` with no
`implements`, so Spring Boot proxies it with CGLIB (no `proxyTargetClass` / `EnableAspectJAutoProxy`
/ `exposeProxy` anywhere in `src/main` — I grepped all three, zero hits, so defaults apply). CGLIB
needs a non-final class and a callable constructor; both hold. A JDK-proxy scenario would have broken
this (no interface to proxy), which is worth stating because it is the one thing that would change
the answer.

`AopContext.currentProxy()` is the alternative to self-injection and is **not** used anywhere in
`src/main` (grep: zero hits) and would require `exposeProxy = true` globally. Rejected: no precedent,
wider blast radius than the fix.

**Option 2 — extract a `ServiceLogWriter` bean. Viable, second choice.**

Architecturally the cleanest boundary, and it has one real advantage over Option 1: it makes the
transaction boundary visible at the type level rather than hidden behind a `self` field. But it is
strictly more change for the same behaviour — a new bean, a new injection point, and
`MessageService` already participates in a dependency cycle, so a new collaborator is a new chance to
re-tangle it. And it does not remove the need to think about self-invocation: `resendMessage` and
`sendStockChangeMessage` would still call `createMessage` in-class.

Choose this over Option 1 only if the implementation lane finds that the `self` field trips
`ReplenishReassignContextLoadTest`-style context-load assertions, or if the plan also wants to move
`resendMessage`'s HTTP concern out of `MessageService`. Neither is in scope for SBDEV-3674.

**Option 3 — annotate both `createMessage` overloads. Rejected, but on a narrower ground than v1's.**

The v1 plan's §3.2 rejected this on (a) blast radius — 50 sites vs 10 — and (b) semantics: it would
make it impossible for *any* message row anywhere to roll back with its business transaction.

**(a) does not transfer.** v1 had 50 external callers of `createMessage` *and* a
`createMessageInNewTransaction` to route 10 of them to. v2 has 37 callers, **no**
`createMessageInNewTransaction`, and — crucially — 36 of those 37 have no ambient transaction, so for
them `REQUIRES_NEW` and the status quo are behaviourally identical. The arithmetic argument is
therefore nearly empty in v2.

**(b) does transfer, and it is sufficient on its own.** The one site with a live transaction,
`OrderBatchCreationService.createAll` at `messageService.createMessage(syspropService.getOmsInstanceName(),`,
writes a `RECEIVED` row for an inbound `ORDER_BATCH_IMPORT`. That row *should* roll back with a
failed import — it is an audit-of-attempt for work that did not happen. `REQUIRES_NEW` on
`createMessage` would pin it. The DB shows this path is live and bimodal (`ORDER_BATCH_IMPORT`:
156 `RECEIVED`, 26 `FAILED`), so this is not hypothetical.

There is a second, v2-only reason: annotating `createMessage` would **not** fix the in-class callers.
`resendMessage` calls `createMessage` unqualified at three sites, and `sendStockChangeMessage` is
in-class too — so Option 3 leaves a self-invocation defect behind while Option 1 removes the class of
defect. Option 3 is both less correct *and* less complete.

**Option 4 — make the 2-caller direct pattern general. Rejected.**

Explicitness is genuinely worth something, and the two existing direct callers show the pattern
reads well. But 37 call-site edits to achieve what 4 lines achieve, in 10 files, five of which are
inbound REST controllers that *want* the rollback semantics Option 4 would strip from them — the
explicitness buys nothing the method name does not already carry, and it makes every future caller
choose correctly with no compiler help. Worse, it inverts the default: a new caller writing
`createMessage` would silently get the broken behaviour, which is exactly today's failure mode.

### A.3 What would change my mind

- **If `MessageService` acquired an interface** — then it is JDK-proxied, `self` is an interface
  proxy, and `createServiceLog` must be on that interface. Option 2 becomes the answer.
- **If a context-load test fails on the `self` field.** `ReplenishmentOrderSourceSyncService` names
  `ReplenishReassignContextLoadTest` as the guard for its own `@Lazy` edge; if the equivalent goes
  red here, take Option 2. Per the memory rule, gate this on a clean compile *and* a context load —
  unit tests do not see DI wiring.
- **If the enumeration lane finds a site that is audit-of-attempt inside a live transaction and
  reached via `OmsNotificationService`.** That would mean one fix cannot serve both semantics and the
  plan needs a second method, not a different mechanism. I found none: all three `doSend` sites are
  audit-of-outcome by construction (they run after the POST).

---

## B. The deadlock constraint — real in principle, empty in practice. Do not design around it.

### B.1 Lock inventory

Grepped `origin/develop` `src/main` for all three forms:

- **17 `@Lock(LockModeType.PESSIMISTIC_WRITE)` sites** across 11 repositories
  (`Adviceposition`, `Billoflading`, `CustomerorderBatch`, `CustomerorderCancellationLog`,
  `CustomerorderPosition`, `Customerorder`, `Location` ×2, `LosSequencenumber`, `Pickingorder` ×2,
  `Replenishorder`, `Stockunit` ×2, `Unitload` ×2) — one of the 17 is a javadoc line in
  `LockTimeoutHibernateJpaDialect`, so **16 real**.
- **`findByIdForUpdate` declared on 8 repositories**, called from ~20 service/job sites.
- **2 native `FOR UPDATE` queries** outside the `@Lock` set, plus `OutboxMessageRepository`'s
  `FOR UPDATE SKIP LOCKED`.

That count is the repo's own, asserted in four repository files verbatim:
`"transaction -- the 15 @Lock sites, the 2 native FOR UPDATE queries, and the ~31 bulk"` /
`"@Modifying UPDATE/DELETEs, which take a row lock per matched row exactly as FOR UPDATE does."`
Two instruments (my grep: 16; the repo comments: 15) differ by one — immaterial to the verdict, and
the discrepancy is most likely `StockunitRepository.findByIdForUpdateSkipLocked`, added by SBDEV-3637
after those comments were written.

### B.2 Which of the 39 sites sit inside a lock-holding transaction

**Zero.** Plainly, as the lead invited.

- The **3 loss-bearing `doSend` sites cannot**, and this is structural rather than a grep result:
  the if-branch runs them in `afterCommit`, i.e. after `doCommit`, when every row lock the business
  transaction held has been released by the commit itself; the else-branch runs them only when
  `!(syncActive && txActive)`, i.e. when there is no real transaction, hence no locks. There is no
  third branch.
- The **28 controller + 3 job + 1 outbox sites** have no ambient transaction at all (§A.0), so
  nothing to hold a lock.
- **`OrderBatchCreationService:212` is the one site inside a live transaction**, and `createAll`
  takes no pessimistic lock: grepping the whole file for `findByIdForUpdate|ForUpdate` returns
  nothing. It inserts `customerorder` / `customerorderbatch` / `customerorderposition` rows, which
  hold locks on *those* rows — disjoint from `message` and `los_sequencenumber`.
- The **strongest lock-holder in the codebase already calls `createServiceLog` and already avoids
  this.** `BillofladingService.closeBOL` holds `billofladingRepository.findByIdForUpdate(bolId)`
  through its whole body, and `reportPendingReversalsOnShippedPallets` nevertheless writes its
  service-log row from inside `registerSynchronization(...)`/`afterCommit()`, with the comment
  `"Inline, before commit, so it must not claim the BOL shipped: closeBOL can still roll back."`
  That is the existing, correct precedent: the one place where the hazard shape was available, the
  code deferred past the commit.

**Conclusion: the constraint does not bind this change at any site.** Overweighting it would push the
design toward a flag, a second method pair, or an async hop — all of which cost more than they buy.

### B.3 Pool pressure — this change does not move the number

`REQUIRES_NEW` costs a second concurrent connection **only where there is a live transaction to
suspend**. By §B.2 that is **one** site, `OrderBatchCreationService:212`, on the inbound
`ORDER_BATCH_IMPORT` path.

The depth there is already two, not one, and the v1 plan's corrected arithmetic applies verbatim:
`createServiceLog` → `BasicService.generateMessageNumber` → `SequenceTransactionService.getNextSequenceNumber`,
which is itself `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`
on a **separate bean**, so its proxy already fires today. After the fix the stack at that one site is
outer `createAll` → `createServiceLog` [new] → `getNextSequenceNumber` = **3** where it was **2**.
Delta: **+1 slot, at one site, on one inbound REST path.**

Everywhere else the delta is **zero** — `REQUIRES_NEW` with nothing to suspend simply becomes the
only transaction, exactly as today. In particular the 267-row `TOTE_ASSIGNED` repair costs **no**
extra connection: it runs in `afterCommit`, where Hibernate has already released the physical
connection in `LogicalConnectionManagedImpl.afterTransaction()` (inside `EntityTransaction.commit()`,
before `triggerAfterCommit`).

So: per the memory rule, slots are what ran out, not milliseconds — and this change adds one slot on
one path. **It does not move the `replicas × tenants × maxPoolSize` number in any way that matters,
and SBDEV-3198's accepted pool-cap risk is not re-raised by it.**

One serialization point worth naming, because it is not a deadlock and will be mistaken for one:
`getNextSequenceNumber` calls `losSequencenumberRepository.findByClassnameForUpdate(key)` — a
`PESSIMISTIC_WRITE` on the single `los_sequencenumber` row for `"WEBSERVICE_MESSAGE"`. **Every**
message INSERT in the system serializes on that one row. That is pre-existing and **unchanged** by
this fix (the hop is already its own `REQUIRES_NEW`, so the lock is taken and released in the same
nested transaction, at the same nesting depth relative to the sequence hop). The outer transaction
never holds that row, so there is no lock-order inversion.

### B.4 `flush`-then-`REQUIRES_NEW` — cargo cult here

Not a mitigation for this change, for two reasons.

1. **Mechanically it is the wrong lever.** The deadlock shape (per the standing memory) is: the inner
   transaction waits on a row the outer holds, and Postgres cannot see it because the two are
   separate sessions, not a cycle in one. A flush does not *release* locks — it **acquires them
   earlier**. Flushing before entering `REQUIRES_NEW` makes the outer's pending writes locked sooner,
   which moves the needle toward the hazard, not away. The genuine mitigation is **table
   disjointness**: the inner transaction touches only `message` and `los_sequencenumber`, and no
   outer caller of `createMessage` locks either (§B.2).
2. **This repo already demands a named reader before accepting a flush**, and there is none.
   `CancellationReversalService` states the local standard:
   `"Deliberately NOT flushed, unlike the clear above — and the reason is narrower"` /
   `"than \"nothing reads this again\". Something can: …"` /
   `"What makes the flush unnecessary is that"` … `"PIT agrees: it"` /
   `"survived \"removed call to EntityManager::flush\" here while killing the same"` /
   `"mutant at the clear site, and a line no test can kill is indistinguishable from"` /
   `"one that does nothing."`
   Nothing reads the `message` row back inside the business transaction. A flush here would be a line
   no test can kill.

---

## C. Does the outbox make part of this moot? — No. 4 of 39, and the migration is not scheduled.

### C.1 Migration state

From `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` plus a live grep:

- **17 `outboxService.enqueue(OutboxMessage.builder()` sites** on `origin/develop`, across
  `AdviceService` ×3, `BillofladingService` ×2, `CancellationReversalService`,
  `CustomerorderBatchService` ×4, `CustomerorderService`, `PickingDateChangeNotificationService`,
  `PickingorderBusinessService` ×4, `PriorityChangeNotificationService`, `ReleaseOrderJobService`.
- **5 live `sendAfterCommit` producers remain**: `ManageOrderService` at
  `…ORDER_BATCH_ON_HOLD`, `…ORDER_BATCH_PICKING_TOTE_ASSIGNED`, `…ORDER_BATCH_PALLETIZED`,
  `…ORDER_BATCH_LOADED_TO_TRUCK`, plus `StockChangeNotificationService` (`STOCK_UPDATE`). The other
  `sendAfterCommit` grep hits are comments or the declaration itself.
- The doc records the remaining legacy sites as `"deferred to Phase-3"`. Phase 3 is not scheduled,
  and the standing memory has SBDEV-2238 Phase 2 itself as **not started** with three envelope
  problems open.

The lead is right that the outbox path has the property by accident: `writeServiceLog` is reached
from `dispatchOne`, from `dispatchBatch`, which is documented
`"Top-level entrypoint for one per-tenant tick. NOT {@code @Transactional} — each"`. So
`createServiceLog`'s inert annotation costs nothing there — not because `REQUIRES_NEW` fires, but
because there is no ambient transaction to join. That is the same accident protecting the 28
controller sites, and it is exactly as fragile: add a `@Transactional` to `dispatchBatch` and the
outbox starts losing service-log rows silently.

### C.2 Which sites the outbox would subsume, and which it never will

**Subsumable — 4 of 39.** The four `OmsNotificationService` `createMessage` sites become dead once
all five remaining `sendAfterCommit` producers migrate, because `doSend` is the only thing reaching
them. That is **the entire loss-bearing set**: the measured 402 would stop growing.

**Structurally permanent — 35 of 39:**

| group | sites | why the outbox never subsumes it |
|---|---|---|
| `AdviceRestController`, `OrderRestController`, `SkuRestController`, `TransactionReportRestController`, `ItemDataController`, `AdminActionController` | 28 | **Inbound** OMS→WMS audit rows (`RECEIVED` / `FAILED`). An inbound record is not an outbound notification — there is nothing to enqueue and nothing to dispatch. The lead named this and it is correct. |
| `StockSummaryExportJob` | 3 | A scheduled **export**, not an event. Its service-log rows record an export attempt and its HTTP outcome. (994 `INVENTORY_FULL_EXPORT` rows on Hydra PRD — the single largest process type.) |
| `OutboxDispatchService.writeServiceLog` | 1 | This **is** the outbox's own service-log writer, added by `"SBDEV-2238 follow-up (plan 260521): restores the {@code MessageService.createMessage()} call"`. Migrating the outbox cannot migrate it. |
| `OrderBatchCreationService` | 1 | Inbound `ORDER_BATCH_IMPORT` audit row, inside the import transaction, and it *should* roll back with a failed import. |
| `BillofladingService`, `PendingReversalReconciliationJob` (direct `createServiceLog`) | 2 | WMS→**ops** service-log notes (`SERVICE_LOG_RECEIVER_OPS`, `PENDING_REVERSAL_RECONCILE` — 5 rows CREATED on Hydra PRD). Not OMS notifications; no destination URL to dispatch to. |

### C.3 Verdict

**Fix it now, independently of the outbox.** Three reasons:

1. The fix is a 4-line diff; migrating five producers onto the outbox is a multi-ticket programme
   with an unstarted Phase 2 ahead of it. Sequencing a 4-line correctness fix behind that is
   indefensible for a loss running at 402 rows and growing on one tenant (and 42,542 on
   wineco-uat).
2. Even after a *complete* outbox migration, 35 sites keep calling a method whose declared
   `REQUIRES_NEW` is inert. Today they are saved by the accident of having no ambient transaction.
   The fix converts that accident into a guarantee, which is what makes future `@Transactional`
   additions safe rather than silently lossy.
3. The two framings are not in tension. The outbox is the right **transport**; `createServiceLog`
   honouring its own annotation is the right **audit-write boundary**. Finishing one does not
   discharge the other.

---

## D. The regression rail

### D.1 State the invariant, not the instance — and the measurement says which invariant

I measured three candidate forms over `src/main` on `origin/develop` (crude regex instrument on an
extracted tree; ArchUnit on bytecode would be more precise, and the two disagree in ways I name
below).

| form of the rule | sites flagged today | verdict |
|---|---|---|
| "no `@Transactional` method is reached **only** by self-invocation" (no external reference anywhere) | **18** | ✗ **Would MISS this bug.** `createServiceLog` has two external callers, so it is absent from the 18. Worse, most of the 18 are framework-dispatched entry points (`PutawayConfigController.setMerchant` is a request handler; `LandlordService.createTenant`) — high false-positive rate, and vacuous against the thing it was written for. |
| "no `@Transactional` method **is** self-invoked from its own class" | **37** distinct (class, method) pairs | ✗ Too wide. 25 of the 37 declare plain `REQUIRED` with the default manager, where proxy-bypass changes nothing. A 25-entry allowlist is a rule nobody will maintain. |
| "no self-invoked `@Transactional` method may declare an attribute only a fresh proxy hop can honour" (propagation ∈ {REQUIRES_NEW, NOT_SUPPORTED, NEVER, NESTED}, or `readOnly`, `isolation`, `timeout`) | **12** | ✓ **Tractable, and it contains the bug.** |

The 12, with their declarations:

| class | method | attribute |
|---|---|---|
| **`MessageService`** | **`createServiceLog`** | **`REQUIRES_NEW`** ← SBDEV-3674 |
| `ReplenishGeneratorService` | `calculateOrder` (4-arg → 5-arg) | `REQUIRES_NEW` |
| `CancellationReversalService` | `detail` | `readOnly` |
| `MobilePickingService` | `getPickingOrders`, `readOrder` | `readOnly` |
| `MobilePutAwayService` | `updateCurrentItemDataUnitLoadList` | `readOnly` |
| `PickingorderBusinessService` | `findDemandCancelledPickLineIds`, `isPickingOrderComplete` | `readOnly` |
| `PutawayConfigService` | `readCommittedDestination` | `readOnly` |
| `PutawayDestinationQueryService` | `eligibleLocations` | `readOnly` |
| `ScannedCodeResolver` | `canonicalUnitLoadLabel` | `readOnly` |
| `WarehouseStockReportService` | `streamStockCount` | `readOnly` — **false positive** |

Two of the 12 need naming before the rule is written, because they determine its final shape:

- **`ReplenishGeneratorService.calculateOrder` is a genuine second instance of the shape and is
  nonetheless benign.** The 4-arg overload is
  `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = {Faca…)`
  and its whole body is `return calculateOrder(itemDataId, amount, destinationId, priority, false);`
  — self-invoking the 5-arg overload, which carries the **same** annotation. The inner annotation is
  inert, but the outer hop already opened the fresh transaction, so behaviour is correct. This gives
  the rule its necessary refinement: **flag a self-invocation only when the self-*calling* method does
  not already supply the same attribute.** Under that refinement the rule flags **exactly 1 site
  today: `MessageService.createServiceLog`** — and it is the bug. No allowlist needed.
- **`WarehouseStockReportService.streamStockCount` is a false positive of my instrument, not a site.**
  The "call" my regex matched is inside a string:
  `"Use streamStockCount(Consumer); legacy bulk-load is OOM-prone. "` in a
  `UnsupportedOperationException` message. ArchUnit reads bytecode and will not make this mistake —
  which is itself the argument for writing the rail in ArchUnit rather than as a script.

**Recommendation:** write the rule as the **refined narrowed invariant over `propagation` only**, and
emit `readOnly` / `isolation` / `timeout` findings as a **separate reported list that does not fail
the build**. Rationale: losing `propagation` changes commit and rollback semantics (rows vanish, as
measured); losing `readOnly` costs a Hibernate dirty-check optimization and, at worst, lets a write
through that Postgres would otherwise have rejected — a different and much weaker failure. Failing
the build on 10 pre-existing `readOnly` sites would force an allowlist of 10 on day one, and an
allowlist that large is how a rail goes vacuous.

Cost: roughly the size of `HttpInTransactionArchTest` (~85 lines) plus a self-call-graph walk. The
general form over all four attributes would cost the same to write and ~10 allowlist entries to
land — so if the plan wants the wider net, the cost is the allowlist, not the code.

### D.2 Which of the five ArchUnit blind spots apply

| blind spot | applies? | why / mitigation |
|---|---|---|
| **Constructors** | **Yes** | `ArchRuleDefinition.methods()` — what `HttpInTransactionArchTest` uses — enumerates `JavaMethod` only. A constructor calling `createServiceLog(...)` on `this` would be invisible. **Use `codeUnits()`, not `methods()`,** for the *calling* side. |
| **Field initializers** | **Yes** | Compiled into the constructor, so the same `methods()` gap. Same mitigation. |
| **Method references (`this::createServiceLog`)** | **Yes — the sharpest one** | A `this::` reference compiles to `invokedynamic` + a synthetic lambda body; `getMethodCallsFromSelf()` on the enclosing method does not report it as a call to the target. Rewriting `createMessage` as `() -> createServiceLog(...)` or `this::createServiceLog` would reintroduce the exact defect and the rail would stay green. **Mitigation:** also inspect `getMethodReferencesFromSelf()` (ArchUnit ≥ 0.23) and walk synthetic `lambda$*` members of the same class. If that proves awkward, **say so in the rule's javadoc** — an undisclosed blind spot is worse than a disclosed one. |
| **Static initializers** | **No, materially** | `@Transactional` on a static method does not work at all, and a `static {}` block has no `this` to self-invoke on. Not a vector for this invariant. |
| **Subtypes** | **No, here** | `MessageService` has no subclass in `src/main` (it is referenced from 31 files, all as a collaborator). Relevant only if the general form is adopted and a `@Transactional` method is overridden — worth one sentence in the javadoc, not code. |

### D.3 `src/test` contamination

Solved by the existing idiom, which the rule must copy verbatim:

```java
appClasses = new ClassFileImporter()
    .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
    .importPackages("net.aim_ai.wms");
```

— `HttpInTransactionArchTest`. Without it, `src/test` classes land in the scan and a test fixture
named `createServiceLog` would either mask or fake a violation. Per the standing memory, a sibling
once survived only on a name coincidence; this is the one line that prevents the repeat.

### D.4 The positive control — and the gap in the existing rail

`HttpInTransactionArchTest` **has no positive control.** If `importPackages("net.aim_ai.wms")`
returned an empty set — a renamed root package, a `target/classes` that `mvn` never rebuilt (see the
standing `mvn test` / stale-`target` memory) — `methods().that().areAnnotatedWith(Transactional.class)`
matches nothing, `should(...)` is vacuously satisfied, and the test passes **green**. A broken
instrument and a clean codebase are indistinguishable, and the failure is silent in the direction
that confirms what you hoped.

Assert on the set **SCANNED**, not the set **FOUND**. Three assertions, all in the same scan, all
before the rule itself:

1. **The importer saw the tree.** `assertThat(appClasses).hasSizeGreaterThan(500);` and
   `assertThat(appClasses.contain(MessageService.class)).isTrue();` — a typed reference, so a package
   rename is a compile error rather than a silent zero.
2. **The annotation predicate matches.** `assertThat(transactionalMethods).hasSizeGreaterThan(150);`
   — I measured **202** `@Transactional`-annotated methods in `src/main`, so a floor of 150 is a live
   control that catches a wrong annotation FQN (`javax`/`jakarta` vs
   `org.springframework.transaction.annotation`) without being brittle. Per the memory rule, match
   the FQN, and reconcile with a second instrument if the number is ever load-bearing.
3. **The call-graph extractor works.** This is the control the other two cannot give, because it is
   the only part specific to *this* rule. Assert that the **unrefined** self-invocation scan finds
   **≥ 20** sites (I measured 37 distinct pairs) — i.e. the analyzer demonstrably detects
   self-invocation in this codebase — and only then assert the refined rule finds none. If
   `getMethodCallsFromSelf()` silently returns empty, control 3 goes red while the rule would have
   gone green.

Expected steady state: controls 1–3 green, refined rule **0 violations**. After the fix,
`createServiceLog` leaves the refined set (because `createMessage` will call it through `self`) but
**stays in the unrefined ≥20 set is not guaranteed** — so control 3 must be measured against the
post-fix tree, not the pre-fix one. Per the standing rule, **negative-test the rail against the
pre-fix file**: it must go RED on `origin/develop`'s `MessageService` and GREEN after. A rail that
was never seen red is not a rail.

---

## Trade-offs

| Option | Pros | Cons |
|---|---|---|
| **1. Self-injection (recommended)** | 4-line diff, one file; 4 existing precedents in the same package, one fixing this same defect class; zero call-site edits; fixes `resendMessage`/`sendStockChangeMessage` in-class calls too if they are also routed through `self`; CGLIB already in force | Hides the transaction boundary behind a `self` field — a reader of `createMessage` sees a normal call; needs a context-load check (DI wiring is invisible to unit tests); adds an edge to a class already in a `@Lazy`-broken cycle |
| **2. Extract `ServiceLogWriter`** | Boundary visible at the type level; no self-reference; testable in isolation | More change for identical behaviour; a new collaborator in a class already in a dependency cycle; does not by itself fix the in-class `createMessage` callers |
| **3. Annotate both `createMessage` overloads** | Smallest conceptual change; no new field or bean | Pins `OrderBatchCreationService`'s inbound `ORDER_BATCH_IMPORT` audit row against a rollback it *should* follow; leaves the in-class self-invocations broken; same semantic objection the v1 plan raised, which does transfer |
| **4. Per-site direct `createServiceLog`** | Explicit at every call site; no new mechanism | 37 edits in 10 files; strips rollback semantics from inbound audit rows that want them; leaves `createMessage` as a trap for the next caller — today's failure mode, preserved |

---

## References

All paths relative to `/home/nampark/dev/wms-claude/`. Code quoted from `origin/develop`.

- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/MessageService.java` — the defect:
  `return createServiceLog(sender, receiver, message, process, destination, MessageStatus.CREATED, status…)`
  unqualified at both overloads, against
  `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` on
  `createServiceLog`. Also the existing `@Lazy` cycle-breaker comment
  `"// @Lazy breaks the MessageService → StockChangeNotificationService → OmsNotificationService"`,
  and `public class MessageService {` with no `implements` (⇒ CGLIB).
- `…/service/OmsNotificationService.java` — the loss-bearing branch: `sendAfterCommit`'s
  `if (TransactionSynchronizationManager.isSynchronizationActive() && …isActualTransactionActive())`
  → `registerSynchronization` → `doSend`; three `messageService.createMessage(` calls inside
  `doSend`; the inline fourth under `if (urlPath == null)`.
- `…/controller/rest/SkuRestController.java` — the prior in-`src/main` disclosure, twice:
  `"// NOTE: MessageService.createMessage internally self-invokes createServiceLog on the same bean,"`
  / `"// so its @Transactional(REQUIRES_NEW) does NOT fire (see plan §3.4). The log persists here"`
  / `"// because no outer tx is active, NOT because REQUIRES_NEW provides isolation."`
- `…/service/BillofladingService.java` — the correct existing pattern: `closeBOL` holds
  `billofladingRepository.findByIdForUpdate(bolId)`, and
  `reportPendingReversalsOnShippedPallets` still writes via `registerSynchronization` /
  `afterCommit()` → `messageService.createServiceLog(WmsConstants.SERVICE_LOG_SENDER_WMS, …)`, under
  `"Inline, before commit, so it must not claim the BOL shipped: closeBOL can still roll back."`
- `…/service/job/OutboxDispatchService.java` — `writeServiceLog`, and
  `"Top-level entrypoint for one per-tenant tick. NOT {@code @Transactional} — each"` (why the outbox
  path is safe by accident).
- `…/service/OrderBatchCreationService.java` — the only in-transaction site:
  `@Transactional(value = "tenantTransactionManager", rollbackFor = {WebserviceBusinessExceptionClientSide.class, BusinessException.class})`
  on `createAll`, with `messageService.createMessage(syspropService.getOmsInstanceName(),` inside it.
- `…/service/SequenceTransactionService.java` — `getNextSequenceNumber`'s
  `@Transactional(…, propagation = Propagation.REQUIRES_NEW)` and
  `losSequencenumberRepository.findByClassnameForUpdate(key)` (the `los_sequencenumber`
  serialization point).
- `…/service/ReplenishmentOrderMaintenanceService.java` — self-injection precedent for this exact
  defect class: `"<strong>Do not remove:</strong> without this field the sweep path bypasses AOP and"`.
  Siblings: `CustomerorderBatchService` (`private CustomerorderBatchService self;`),
  `ReplenishGeneratorService`, `ReturnAdviceAutoReceiveService`.
- `…/service/ReplenishGeneratorService.java` — the second genuine, benign instance:
  `REQUIRES_NEW` 4-arg overload whose body is `return calculateOrder(itemDataId, amount, destinationId, priority, false);`.
- `…/repo/jpa/MessageRepository.java` — the purge I had to rule out:
  `"DELETE FROM message WHERE id IN (SELECT id FROM message AS m WHERE m.created < :refDate LIMIT :batchSize)"`
  and the `INSERT INTO message_archived` above it; `…/service/job/MessageCleanupBatchService.java`,
  `…/schedulejob/CleanUpOldMessagesJob.java`.
- `…/src/test/java/net/aim_ai/wms/unit/config/HttpInTransactionArchTest.java` — the rail idiom to
  copy (`ImportOption.Predefined.DO_NOT_INCLUDE_TESTS`) and the gap to not copy (no positive
  control). Sibling rails: `TransactionManagerArchTest`, `NestedCallSiteRailTest`,
  `NeverMatcherNullBlindnessArchTest`.
- `…/service/CancellationReversalService.java` — the repo's own standard for justifying a flush
  (`"What makes the flush unnecessary is that"` … `"PIT agrees"`), which the flush-first proposal
  fails.
- `sbdocs/1-Projects/wms1/plan/SBDEV-3266-oms-message-rows-lost-in-aftercommit.md` §2.1 (mechanism),
  §2.2 (the v1 cliffs), §3.2 (options + the retracted Revision-1 reasoning), §3.3 (blast radius,
  the corrected 3-deep arithmetic, the "slots not milliseconds" retraction).
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — outbox migration history
  (SBDEV-2221 pilot, SBDEV-2238 Phase 2, SBDEV-2381), and
  `"The remaining 11 sendAfterCommit call-sites are deferred to Phase-3."`
- **DB, `nywh-hydra-prd`** (2026-10-07): `message` 3001 rows / `max(number)='0000003403'`;
  `message_archived` **0 rows**; `process` × `status` distribution with
  `ORDER_BATCH_PICKING_TOTE_ASSIGNED` and `ORDER_BATCH_ON_HOLD` **absent**;
  `count(*) from customerorder where historytote is not null` = **267**.
