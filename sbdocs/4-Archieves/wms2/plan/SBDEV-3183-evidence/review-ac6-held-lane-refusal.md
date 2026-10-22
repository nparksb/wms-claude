---
ticket: SBDEV-3183
type: review
subject: commit 0ce3438c — AC-6 held-lane refusal IT
reviewed: 2026-10-20
verdict: APPROVE
---

# SBDEV-3183 AC-6: review of 0ce3438c (held-lane refusal IT)

The review was read-only, done with `git show` / `git grep` at `0ce3438c`. Maven was not run, because a suite was already running in that worktree.
The parent `b445b768` is an ancestor of `origin/develop`, and its tip is `b445b768`.
One DB probe was run on dev (`dev_wh01_om1`).

## Verdict: APPROVE

None of the findings blocks the commit. The AC retarget holds up, and the test checks the refusal it claims to check.
Every claim in the commit message checks out.

## 1. Is the AC retarget sound?

**Yes.**
- Only `Customerorder` has a lane binding. In `src/main/java/net/aim_ai/wms/model/`, `transferlane` appears only as `Customerorder.transferlaneId` (`Customerorder.java:54-55`, `@Column(name = "transferlane_id")`) and as the boolean `Location.transferlane` flag (`Location.java:35`).
- Only three places in `src/main` set the field to a non-null value. All are in `TransferOrderService`, and each runs the `getAvailableTransferLanesForUpdate` refusal first:
  - `:99` in `assignTransferLaneToTransferOrder`
  - `:131` in `activateTransferOrder`
  - `:154` in `activateAndAssignTransferLane`
- Every other `setTransferlaneId` call sets the field to null: `TransferOrderService:111` (unlink), `CustomerorderService:541` and `:1094`, and `CustomerorderBatchService:386`.
- No native or JPQL `UPDATE` touches `transferlane_id`. The bulk `UPDATE Customerorder` queries (`CustomerorderRepository:248`, `:282`, `:310`) change only `state` and `modified`.
- The only SQL that writes `transferlane_id` is in the one-off onboarding scripts (`04-schema-bridge.sh:10`), and it changes `state` only.
- No request body binds to the entity. There is no `@RequestBody Customerorder`, `copyProperties`, `readerForUpdating`, or `convertValue(..., Customerorder.class)` in `src/main`.
- The SDR write path is closed. `RestConfiguration.java:488` (also present on `origin/develop`) lists `net.aim_ai.wms.model.Customerorder.class,` in `SDR_WRITE_WITHDRAWN`.
- The MVC routes that reach the setters are `TransfersController` assign `:195`, reassign `:115` and activate `:168`. All three take `locationId` as a `@PathVariable`, which confirms the commit's point that hiding a lane from the offer list does not protect these routes.

## 2. Does the test check what it claims?

**Yes, and it cannot pass for the wrong reason.**
- The refusal query (`LocationRepository.java:147-160`) filters on exactly two things: `l.transferlane = true`, and `NOT EXISTS` an order with `co.transferlaneId = l.id AND co.id != :customerOrderId AND co.state < :state`. The state bound passed in is `FINISHED = 700`.
- The query has no client, batch or order-state filter, and the service methods (`TransferOrderService:89-99`, `:137-156`) check nothing else before throwing. Order 2 therefore cannot be refused because of its own state, client or batch.
- The test's setup step also acts as the control for lane A. Order 1 takes lane A without error, so lane A was a transfer lane and nobody else held it.
- Between that step and the two refusals, the only thing that changes is that order 1 now holds lane A at state 510, which is below 700. The refusal can only come from the held-lane exclusion.
- The lane-B control rules out a setup that refuses every call.
- The thrown type and message are reliable:
  - `new BusinessException("transfer lane is not available anymore. refresh and try again.")` uses the `placeholder` key with the text as a parameter, so `getMessage()` contains the text.
  - Exceptions from other failures, such as a missing transaction or a lock timeout, would not be `BusinessException`, so `isInstanceOf` filters them out.
  - The commit's mutation check confirms the text renders.
- Transactions commit as expected. The class is `@Transactional(propagation = NOT_SUPPORTED)`, and each service method opens and commits its own `tenantTransactionManager` transaction. The JDBC probes (`orderLane` and `orderState`) read the committed rows.
- No state leaks between test methods. `wipe()` runs in both `@BeforeEach` and `@AfterEach`. It deletes `customerorder` before `location` by `client_id = 9870`, so order 2's binding to lane B is removed before the lanes are. No other test in `src/test` uses the IDs 9870-9876.

## 3. Does the service method `activateTransferOrder` have a caller?

**No. The claim is true.** `git grep activateTransferOrder` over `src/main` finds:
- the service definition, `TransferOrderService.java:124`;
- the controller handler with the same name, `TransfersController.java:156`, which calls `activateAndAssignTransferLane` at `:168`, not the service method;
- a stale comment at `LocationRepository.java:146` (finding F-1).

## 4. Claims in the commit and comments

| Claim | Status |
|---|---|
| "Customerorder is the only entity with a transferlaneId" | Verified (section 1). |
| "its SDR writes are withdrawn" | Verified in code (`RestConfiguration.java:488`). I did not re-probe the "live 405 on dev". |
| "The refusal is copied into three service methods" | Verified (`:93-96`, `:125-128`, `:144-146`). |
| "existing happy-path test only proves a held lane stops being OFFERED" | Verified. The happy-path test only calls `availableLaneIdsFor`. |
| "Dev: 3 open orders hold 3 of 6 transfer lanes (2026-10-20)" | Verified on `dev_wh01_om1` today: `lanes=6`, `open_holding=3`, `held_lanes=3`. |
| Mutation reds | Plausible from the code. If either refusal is removed, order 2 is saved with lane A and the `orderLane(ORDER_2) isNull` assertion fails. I did not re-run them (no Maven). |

## Findings

| ID | Sev | Conf | File | Evidence | Fix |
|---|---|---|---|---|---|
| F-1 | LOW | HIGH | `src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java:146` (not touched by this commit) | The comment says `// transaction (assignTransferLaneToTransferOrder / activateTransferOrder).` That names the dead service method as a caller and leaves out `activateAndAssignTransferLane`, the live one. | Change it to `assignTransferLaneToTransferOrder / activateAndAssignTransferLane`, or list all three. |
| F-2 | LOW | HIGH | `TransferOrderService.java:120-133` (not touched by this commit) | `activateTransferOrder` has no caller in `src/main`, and the new test leaves it unpinned on purpose. It is a third copy of the refusal, it persists 505-with-lane, and its own WARNING says it must not be paired with assign. | Delete it as dead code (here or on a follow-up within this ticket), so nothing new can wire to the non-atomic shape. |
| F-3 | LOW | HIGH | `ActivateTransferAtomicityIT.java` (new test) | Uses fully qualified `org.assertj.core.api.Assertions.catchThrowable` and `net.aim_ai.wms.exceptions.BusinessException` inline, while the file imports AssertJ statically elsewhere. | Add `import static ...catchThrowable` and `import net.aim_ai.wms.exceptions.BusinessException`. This is cosmetic only. |
| F-4 | LOW | MEDIUM | `ActivateTransferAtomicityIT.java` (new test) | All three service methods share the same refusal text, so `hasMessageContaining` does not show which copy fired. Each call names its target method, so this does not hide anything today. | Optionally assert `((BusinessException) t).getKey()` together with the parameter. You could also leave it as is, since the call site makes it unambiguous. |
| F-5 | LOW | MEDIUM | `ActivateTransferAtomicityIT.java` (new test) | The "binds nothing / stays RAW" assertions after each refusal cannot fail on rollback grounds, because both methods throw before changing the entity. They still catch the case where the refusal is removed, which is their real job. | None needed. Optionally reword "the refused assign bound nothing" so it does not suggest a rollback is being exercised. |

## Open questions (low confidence, not blocking)

| ID | Sev | Conf | Evidence | Suggestion |
|---|---|---|---|---|
| OQ-1 | MEDIUM | LOW | Dev has `closed_with_lane = 23`: orders at `state >= 700` keep `transferlane_id`. The exclusion only counts holders with `state < 700`. Any path that moves such an order back below 700 would make it hold its lane again **without** going through the refusal, which could double-book the lane. I did not find such a path (bulk UPDATEs: `:248` sets PACKED and skips 800 only; `:282` and `:310` act on RAW/FUTURE_PICKING). I did not sweep every `setState`. | Grep `setState(` calls that can lower a Customerorder from 700 or 800, or null `transferlane_id` on finish/cancel. Outside AC-6's scope. |
| OQ-2 | LOW | LOW | `getAvailableTransferLanesForUpdate` locks every available transfer lane in the shared IT database. It has no client filter (`SBDEV-3250 ⚠ MULTI-ROW LOCK`). This only matters if ITs run in parallel against one database. | Existing behaviour, nothing to do unless parallel-IT flakiness shows up. |

## Positive observations

- The test's setup doubles as the lane-A control, and the free-lane control closes off a fixture that refuses everything. Together they leave the held-lane exclusion as the only possible cause of the refusal.
- Using `catchThrowable` instead of `assertThatThrownBy` is a deliberate choice, and the reason is stated: a missing refusal produces a failure message that names the method.
- The retarget is honest. The commit message and javadoc say the dead third copy is not pinned and explain why, rather than claiming coverage of all three.
- The dev reachability claim was grounded in a database query, and it reproduces.
