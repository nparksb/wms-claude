## Changes from r2

| Finding | Resolution |
|---|---|
| Architect N1 = Critic H1 (null `entity_lock` NPE at `:310`) | §6.1 now has a "fixture state" block. After the first scanGate, jdbc sets 6b/10a/10b to pallet `entity_lock` 0. 6a mirrors closeBOL `:664-678`: pallet and child go to Shipped with lock 405 (`SHIPPED`), and the child's stockunits get lock 405. Preconditions are asserted before the call. AC-6b's description now says the pallet is on the GATE. The block notes this is the first PG-lane run of `scanDestination` and that it goes through BLOCK_REALIGN. |
| Critic H1 (STOP rule) | §5.8 Step 2 now classifies the throwable before concluding anything. An NPE, an `EntityNotFound`, or a setup/teardown failure means "fix the fixture". Only a non-null `BusinessException`/`FacadeException` from a guard in `scanDestination` or `transferUnitLoadToLocation` disproves §2. The AC-10 rule uses the same classification. |
| Critic M1 (teardown residue) | §6.1 fixture block: a `purgeByPrefix` override that mirrors `MobileTruckLoadingClosedBolPurgeIT:143-155`. New labels `BOUT-948710..948713` (grep: only 948701/948702 exist in `src/test`). AC-10b calls `status.setRollbackOnly()`. |
| Architect N2 = Critic M2 (HTTP 200 + `errors`) | §6.2 now expects HTTP 200 with `{"errors":[…]}`. selectDestination's success body is `true`. The Accept-Language header is dropped: the message resolves via `Locale.getDefault()` (`BusinessException:50`), so expect English text or the raw key. The ADR consequence is corrected. |
| Critic M3 (assertion order) | AC-1 and AC-3 IT use `catchThrowable`, then data assertions, then key and site, so each pre-fix red is "positions deleted". |
| Architect N3 | AC-10b uses `FOR NO KEY UPDATE NOWAIT`, and its positive control asserts the pallet id comes back. |
| Architect N4 | §5.7: stub only R5 with `thenReturn(1)`, plus `verify(bps, never()).assertPalletNotShipped(any(), eq(MOVE_UNITLOAD_D0_RECHECK))`. |
| Architect N5 = Critic L2 | §6: the ListAppender is attached in `@BeforeEach` after the context loads and detached in `@AfterEach`. It filters on logger name, WARN and the prefix, then checks `getArgumentArray()[0] == site` (exact enum equality). |
| Architect N6 + Critic L4 | AC-6b's javadoc explains where the state comes from. The §8 observability line is rewritten. |
| Critic L1 | The AC-2 "into the try" mutant is marked equivalent. Only "after the try" counts. |
| Critic L3 | Step 2's compile-only list is completed. |
| Critic L5 | AC-9 fixtures are saved through the repository with `name = PREFIX+…` and an explicit id. |
| Critic L6 | §6.2 snapshots X's position rows before running. |
| Architect optional cut | §8 R2 row removed. §2.1 says "unreachable" in one line. |

