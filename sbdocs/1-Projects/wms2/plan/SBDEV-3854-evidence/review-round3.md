---
ticket: SBDEV-3854
lane: final review (round 3) — round-2 fixes only
reviewed: v2/wms2-api diff daa56ee5..299cdea6 (PR #552) + two sbdocs edits
date: 2026-10-21
verdict: APPROVE (minor findings only)
---

# SBDEV-3854 — round-3 review of the round-2 fixes

## Scope and method
`git diff daa56ee5 299cdea6`: 4 files, +65/-16. Read-only, maven not run (per instruction). Every claim below was checked against `git show 299cdea6:<path>`.

## Stage 1 — does the delta match what was expected?
| Expected | Present | Notes |
|---|---|---|
| (1) `deleteUnitLoad`: `locked == null ||` → same BusinessException; `unitLoadId` declaration moved | Yes | `UnitloadService.java:770-782`. The declaration now sits under the SBDEV-3854 lock comment (round-2 Nit 3 closed). The lock comment changed from "before anything reads it" to "before its amount or lock state is used", which closes round-2 Nit 1 and is now true. |
| (2) IT: `postsCarryingThisSku()` helper, payload asserts MANUAL_REMOVAL and -12, new recount-to-zero happy-path IT | Yes | `DeleteContainerWithStockIT.java:181-195, 219-223, 244, 272, 294-311`. The now-unused imports (`any`, `argThat`, `contains`, `never`, `times`, `verify`) were removed. |
| (3) Unit: `deleteUnitLoad_shouldRefuse_whenAStockUnitWasDeletedMeanwhile` | Yes | `UnitloadServiceUnitTest.java:1684-1696` |
| (4) ArchTest comment id range | Yes | 38540-38551 now matches the highest constant, `CYCLECOUNT_POSITION = 38551L` (round-2 Nit 2 closed) |

Nothing unexpected is in the delta. The only extra is the lock-comment rewording noted in (1), which is a requested nit fix.

## Correctness checks
- **(1) is correct.** `LockReads.forUpdate` returns `Optional.empty()` on both branches (finder miss, or the managed-branch `SELECT ... FOR UPDATE` returning no row), so `orElse(null)` covers both. The method is `@Transactional(rollbackFor = BusinessException…)` and the throw happens before any mutation. `EntityNotFoundException` is still used elsewhere in the file, so the import is not orphaned.
- **The new unit test kills the mutant.** Before the fix the code threw `EntityNotFoundException`, which `extends RuntimeException`, not `BusinessException`. So `isInstanceOf(BusinessException.class)` goes red against daa56ee5. `verifyNoInteractions` proves the refusal comes before any mutation.
- **Is the helper vacuous? No.** The filter `getMethod().getName().equals("post") && getArguments().length == 2` matches `HttpRestService.post(String,String)` (`HttpRestService.java:95`). `post` has no overloads or varargs, and `postWithIdempotencyKey` (`:116`) has a different name. `OmsNotificationService.doSend:118` calls `httpRestService.post(urlPath, payload)`. Two positive controls in the same class read the same helper and require a non-empty result:
  - `deleteUnitLoad_shouldRetireStockAndContainer_*`: `.singleElement()`
  - `recountSingleUnitLoad_shouldRetireStockAndContainer_*`: `.hasSize(1)`

  A rename of `post`, an arity change, or an SKU missing from the payload would turn those two red. That makes the two `isEmpty()` assertions meaningful. The `@BeforeEach` `when(httpRestService.post(anyString(), anyString()))` stubbing call is removed from registered invocations by Mockito, and its `""` payload holds no SKU anyway. `@MockitoBean`'s default `MockReset.AFTER` clears invocations between tests, so the controls cannot be satisfied by an earlier test's post.
- **New recount IT.** The path is sound. `recountSingleUnitLoad` is now `@Transactional` (`MobileCycleCountService.java:191`), and the code runs createEntity → save FINISHED → `sendStockUnitToNirvana` → `sendToNirvana` → `sendStockChangeMessage`, with the POST after commit. The fixture satisfies every precondition: one SU, no children, UL and SU `entity_lock` 0, no FLA. Cleanup covers `cyclecount_position`, `stockrecord`, `unitload_record` by client and `message` by SKU.

## Is the OutboxDispatcherJob rationale true? Partly
- TRUE: it ticks in the IT context. `@Scheduled(cron = "${app.cron.outbox-dispatcher:*/15 * * * * *}")` (`OutboxDispatcherJob.java:62,83`) is activated by the unconditional `@EnableScheduling` in `SchedulingEnablementConfig`. `app.cron=false` (`application-postgres-integration.properties:194`) only gates `SchedulingConfiguration`, and the IT properties do not set `app.cron.outbox-dispatcher`.
- TRUE: inside this class's context, `OutboxDispatchService` is injected with the `@MockitoBean`, so it is "this same mocked transport".
- NOT TRUE as a justification: the dispatcher sends through `httpRestService.postWithIdempotencyKey(...)` (`OutboxDispatchService.java:172`, its only call on the bean). The helper's `"post"` name filter already excludes those calls, and so did the old `verify(never()).post(any(), any())`. The SKU filter is therefore not what keeps dispatcher traffic out. The only other `post/2` caller that could fire in the background is `StockSummaryExportJob:579`, and it is registered only by `SchedulingConfiguration` (`app.cron=true`), so it is off. "stays null-safe" is also no reason for the change, because `any()` already matches null.
- Net: the rewrite is harmless and arguably more readable, but the javadoc gives the wrong reason (see L1).

## Findings

### [LOW] L1 — helper javadoc gives a reason that does not hold
File: `src/test/java/net/aim_ai/wms/integration/service/DeleteContainerWithStockIT.java:183-188` · Confidence: HIGH
Issue: the javadoc says the SKU filter keeps OutboxDispatcherJob's posts out. The dispatcher calls `postWithIdempotencyKey`, which the `"post"` + arity-2 filter already excludes. The old `never().post(any(), any())` was neither exposed to the dispatcher nor null-unsafe.
Fix: reword along these lines: "The method-name filter excludes OutboxDispatcherJob, which still ticks here (it reads its own cron key, not app.cron) and posts through postWithIdempotencyKey on this same mock. The SKU filter is a defensive scope to this class's fixture." Or drop the SKU filter.

### [LOW] L2 — the recount happy-path IT does not check what it sent
File: `DeleteContainerWithStockIT.java:309` · Confidence: HIGH
Issue: `hasSize(1)` counts the POST but does not check the URL, the activity code (`CODE_CYCLE_COUNT`) or the delta (-12). The sibling delete test checks all three. A recount that sent the wrong activity code or a delta of 0 would stay green. This matters because round-2 N-M1 concerns exactly this delta.
Fix: mirror the delete test: `.singleElement().satisfies(p -> { assertThat(p.url()).contains("stockUpdate"); assertThat(p.payload()).contains(WmsConstants.CODE_CYCLE_COUNT).contains("-12"); })`.

### [LOW] L3 — a vanished stock unit is reported as "moved off"
File: `src/main/java/net/aim_ai/wms/service/UnitloadService.java:779-781` · Confidence: HIGH
Issue: the comment says "Gone, or moved elsewhere", but for the gone case the operator reads "Stock unit N was moved off container X". The unit test pins that wording (`UnitloadServiceUnitTest.java:1693`). The message is readable but inaccurate when the row was removed. (Round-2 nit, still open: "Nothing was deleted" is also untrue mid-bulk-delete.)
Fix: "Stock unit N on container X changed (moved or removed) while it was being deleted. This container was not deleted; try again." Then update both unit-test `hasMessageContaining`s to a shared fragment.

### [LOW] L4 — the reworded comment lines are over 120 columns
File: `UnitloadService.java:765` (121 chars), `:775` (135 chars) · Confidence: MEDIUM (I did not confirm whether `gradle/checkstyle.xml` is enforced in the Maven build)
Fix: rewrap.

### [MEDIUM] L5 — cycle-count workflow §8 says "No pessimistic locks in the cycle-count path", which the code contradicts
File: `sbdocs/3-Resources/workflows/wms2-cycle-count-workflow.md` §8, the last bullet · Confidence: HIGH
Issue: both recount paths reach `StockunitBusinessService.changeAmount`, which takes `LockReads.forUpdate(...)` (PESSIMISTIC_WRITE / `findByIdForUpdate`, `StockunitBusinessService.java:603`). Since SBDEV-3854 that lock is held until the recount transaction commits. The bullet just above it was edited in this round ("bind … in one transaction"), so the section now asserts transaction semantics next to a false locking claim. Someone doing deadlock or lock-order analysis would be misled.
Fix: "The stock unit is row-locked (PESSIMISTIC_WRITE via LockReads in changeAmount) and, since SBDEV-3854, held to the recount's commit. Cyclecount/CyclecountPosition rely on @Version only."

### [LOW] L6 — cycle-count workflow §8 says "No REQUIRES_NEW anywhere in this flow"
File: same doc, §8 closing line · Confidence: MEDIUM
Issue: `CyclecountPositionService.createEntity` → `BasicService.generateNumber` → `SequenceTransactionService.getNextSequenceNumber`, which is `@Transactional(REQUIRES_NEW)` (`SequenceTransactionService.java:23`). So a rolled-back recount still burns a position number. That is benign, but the absolute claim is false.
Fix: "Only the position-number sequence draw runs REQUIRES_NEW (it survives a rollback)."

### [LOW] L7 — stale line anchors in the cycle-count workflow
File: same doc · Confidence: HIGH
- §6 says `changeAmount()` is `@Transactional` "at `StockunitBusinessService.java:362`". It is now at `:600-601`.
- §9 says "`MessageService.sendStockChangeMessage` line 101". It is now at `:157`.
- §9 also says the POST "Fires only when the recount path produces a non-zero delta". `recountSingleUnitLoad` always sends, so a 0 diff still gets a STOCK_UPDATE (`MobileCycleCountService` builds `diff` and always calls `sendStockChangeMessage`).

These may predate this delta, but they sit in the sections edited this round.
Fix: replace the line numbers with symbol anchors and qualify the §9 claim.

### [LOW] L8 — stockunit design doc: two over-statements in the edited rows
File: `sbdocs/3-Resources/design/wms2-stockunit-design.md:95, :112` · Confidence: MEDIUM
- `:112` says "STOCK_UPDATE goes after commit". It goes only when `notifyCRM` is true (`UnitloadService.java:796`). `deleteUnitLoadRecursive` passes `false` to its inner calls and sends once at the end.
- `:95` says "Re-fetches SU from DB after changeAmount". Per the code comment (`StockunitBusinessService` around `:580`), the `findById` returns the managed instance, and that instance is current only because `changeAmount` locked and refreshed it. When the amount was already 0 it is the caller's instance, not a DB re-read. This is likely pre-existing text.

Everything else in the two rows checks out against the code: rollbackFor B+F, the reservation guard, the self-invocation, the "moved off or vanished" refusal, id order, children in id order, all-or-nothing, the `FixLocationAssignmentService.delete` pre-refusal (`:274`).
Fix: add "(when notifyCRM)" to row 112 and "managed/refreshed instance" to row 95.

## Open questions (outside the delta; surfaced, not blocking)
- **[MEDIUM] Round-2 N-M1 is not addressed and has no recorded disposition.** `countBySKURecount` still takes its OMS delta from a plain read before the lock, and `recountSingleUnitLoad` takes it from the client DTO. I grepped `sbdocs/1-Projects/wms2/plan/` and the evidence folder for "N-M1" and found no disposition, and there is no plan doc for SBDEV-3854 in `1-Projects/wms2/plan/`. Either fix it or record it on the ticket and in the T3 proposal (L8/P13), as round 2 asked. Confidence: HIGH that it is open. Whether it is deferred on purpose I cannot see.
- **Round-2 N-L1, N-L3 and N-L4 are also unaddressed, with no recorded disposition.** N-L1 is the ids-only projection: `findByUnitloadId` still loads full entities. N-L3 is the "per container" lock-order comment. N-L4 is proof that the position was written before the refusal. The house rule says to fix Lows too, so confirm they were consciously deferred.
- `postsCarryingThisSku()` would not see a leak through any channel other than direct `post/2`, for example an outbox row dispatched later. That is fine today because STOCK_UPDATE does not go through the outbox. Note it if STOCK_UPDATE ever moves to the outbox.

## Severity counts
CRITICAL 0 · HIGH 0 · MEDIUM 1 (L5, a doc) · LOW 7 (L1-L4, L6-L8) · Open questions: 1 MEDIUM (N-M1 disposition) plus 2 informational

## Positive observations
- The refusal fix is minimal and right: one guard covers both race outcomes, and the unit test genuinely kills the pre-fix code, because of the exception type.
- The helper is not vacuous. Two positive controls in the same class read the same helper, and the payload now pins -12 on the wire (round-2 N-L5 closed).
- The new happy-path recount IT closes round-2 N-L6. It asserts the stock unit on Nirwana, the container retired and the position FINISHED, all from the DB.
- Round-2 Nits 1, 2 and 3 are closed exactly as suggested.

## Recommendation
**APPROVE.** Nothing blocks at HIGH confidence. Take L1-L3 and L5-L8 in one small doc-and-comment pass (house rule: fix Lows too). Record a disposition for round-2 N-M1, N-L1, N-L3 and N-L4 before the PR leaves review.
