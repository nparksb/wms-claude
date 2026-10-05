I fixed every finding you listed on branch `bugfix/SBDEV-3487-d0-purge-closed-bol`, in three commits. The unit tests, the four ITs and the full unit suite all pass, and every new assertion went red when I broke the line it protects. Nothing is pushed.

## Commits (worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487`)
- `956eda99` SBDEV-3487: review fixes — CLOSED constant in the queries; production comments
- `49b87c99` SBDEV-3487: review fixes — unit tests for the 1-row path, the WARN and a null label
- `45d00ad7` SBDEV-3487: review fixes — PG fixture javadocs, bounded purge hooks, IS NULL controls

## Per-finding
| # | Status | What changed |
|---|---|---|
| M1 | fixed | The fixture's class javadoc and the `OutboundPalletLabelGuard` mock javadoc now say: the probe and race ITs use TL3465 labels and take D0's no-match exit; the two SBDEV-3487 subclasses use BOUT labels and run D0's purge and rebuild. The "Shared by" list names all four ITs. The nanoTime claim now credits `runKey`, not `PREFIX`. |
| M2 | fixed | The `seedPallet(String,String)` javadoc describes the hook order: move to `SEEDED_LOCATION_ID`, then the prefix purge, then delete by exact label. It also says why that order is required. |
| L1 | fixed | `seedOpenBol` moved above the `advanceBolToTruckLoadingAtGate` javadoc, so that javadoc sits on its method again. |
| L2 | fixed | Added `HandleTruckOffLoadingNoClear#oneRowDeleteDoesNotRecheck`: `never()` on the re-check, and it verifies R4 gets `List.of(10L, 20L)`. |
| L3 | fixed | AC-9 has a null-state row for R5 (childless) and a null-state child under the TRUCK_LOADING control parents for R4 and R6. They use repository save, PREFIX names and no preset id. |
| L4 | fixed | Both `zeroRowDeleteWithRowGoneWarnsAndContinues` tests assert exactly one WARN starting "SBDEV-3487: pallet position". The ListAppender is detached in `finally`. |
| L5 | fixed | Both IT class javadocs say "Pre-fix (reproduced at `682483fe`, before the fix)" and then describe what the fixed code does. |
| L6 | fixed | Added `protected void beforePrefixPurge(Connection)` / `afterPrefixPurge(Connection)`, called inside the bounded purge callback. `exec` is now `protected static`. Both subclasses run their fixed-label statements through `exec` there, and the free-standing autocommit statements are gone. |
| L7 | fixed (no `@Qualifier`) | `tx()` gets a javadoc saying it opens a landlord transaction and nothing wrapped in it is atomic. The AC-9 javadoc says each repository call commits in its own tenant transaction. |
| L8 | fixed | The CLOSED-BOL finder and R3–R6 now build the state check from `WmsConstants.BillOfLadingState.CLOSED`. R3–R6 share one `NOT_CLOSED_PREDICATE` constant. |
| L9 | fixed | `ShippedGuardSite` imported in `MobileTruckLoadingService`; the long line is split. |
| L10 | fixed | New test AC-8(e): a null label makes no finder call, no throw and no WARN. The guard has a one-line comment saying why failing open on null is safe. |
| L11 | fixed | Added to the finder javadoc: null means no CLOSED row, because `bp.number` is NOT NULL (V2.2.00). |
| L12 | fixed | The write-service comment now says the backstop inherits D0's post-B2 position (chosen by SBDEV-3418), and that this is what makes it race-free against closeBOL. |
| L14 | fixed | The Fix C (V2) comment says the rejection deliberately comes after `transferUnitLoadToLocation`'s locks, that the early rejection belongs to SBDEV-3490, and not to move the backstop out of the purge. I checked those locks in `UnitloadBusinessService`: owning pickingorders first, then DEST with `FOR UPDATE`. |
| L13 | not done | The plan fixes the enum names. |
| Security L-1 | not done | Left for the owner to decide. |

## Mutation table (each restored byte-identical, confirmed with `cmp`, then `touch` and recompile)
| Mutant | Test | Red |
|---|---|---|
| V1 `deleted == 0` → `true` | `NoClear#oneRowDeleteDoesNotRecheck` | Never wanted here: `assertPalletNotShipped(<any>, SCAN_GATE_D0_RECHECK)` |
| Remove the R4 call (`deleteBolPositionsCarrierIdsNoClear`) | `NoClear#oneRowDeleteDoesNotRecheck` | Wanted but not invoked: `deleteBolPositionsCarrierIdsNoClear([10, 20])` |
| Delete the V2 `LOG.warn` | `HandleTruckOffLoading#zeroRowDeleteWithRowGoneWarnsAndContinues` | "exactly one 'already gone' WARN…": Expected size 1 but was 0 |
| Delete the V1 `LOG.warn` | `NoClear#zeroRowDeleteWithRowGoneWarnsAndContinues` | Same message, size 0 |
| Delete the null guard | `AssertPalletNotShipped#nullLabelMakesNoFinderCall` | Never wanted here: `findClosedBolNameBySourceUnitLoadLabel`, invoked with `[null]` |
| R5 without the IS NULL arm | AC-9 `repositoryDeletesNeverRemoveClosedRows` | "control: R5 must still delete a null-state row" and "R5 must report 1 row…" |
| R6 without the IS NULL arm | AC-9 | "control: R6 must still delete a null-state child (the IS NULL arm)" |
| R4 without the IS NULL arm | AC-9 | "control: R4 must still delete a null-state child (the IS NULL arm)" |

Each IT mutant changed only its own query (diff lines 148 / 156 / 204), and each red names only that query's control.

## Test counts (logs in the scratchpad)
- **6 unit classes:** 147 run, 0 failures (`unit6.log`).
- **4 ITs** (`mvn -o verify`, all four class names exist): 17 run, 0 failures (`it4.log`).
  - `MobileTruckLoadingClosedBolPurgeIT` 5, `MobileMoveUnitloadClosedBolPurgeIT` 5, `MobileTruckLoadingRaceIT` 3, `MobileTruckLoadingLockOrderProbeIT` 4.
  - After the run the container holds 0 `BOUT-9487%` unitload rows, 0 matching `unitload_record` rows and 0 `TL3465-%` rows, so the hooks cleaned up.
- **Full `mvn -o test`:** 6889 run, 0 failures, 0 errors, 1 skipped, BUILD SUCCESS (`3487-full-unit-reviewfix.log`). The earlier run was 6887 / 0 / 0 / 1; the +2 are the two new unit tests.
- **Mutant logs:** `mut-*.log` and `mut-*.diff`.

## Unexpected
- **Constant visibility:** fields in a Java interface can't be `private`, so `NOT_CLOSED_PREDICATE` is implicitly public. Its javadoc says it isn't meant for callers.
- **Seeded location id in the hook:** `exec` can only bind strings, and `storagelocation_id` is bigint. So the hook puts `SEEDED_LOCATION_ID` straight into the SQL text instead of binding it. It's a compile-time `0L`, and the code has a comment saying so.
- **The V1 `if (true)` mutant was a real gap:** my new test was the only one that went red, which confirms nothing covered that line before.
- **No independent review yet:** no review lane has looked at this round's fix commits.