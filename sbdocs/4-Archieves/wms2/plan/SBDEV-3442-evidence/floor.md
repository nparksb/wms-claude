# SBDEV-3442 floor evidence (author pass, 2026-09-24)

Commit under test: ee523d44 on bugfix/SBDEV-3442-scandestination-row-lock (base origin/develop 5fa9bef0).

## DB (exposure)
Hydra prd (only v2 prd client), 90 days: 0 pairs of TRANSFER + {TRANSFER,TRUCKLOADING,PALLETIZING,SHIPPING}
records on the same label by DIFFERENT operators within 60 s. Positive control: 6 same-operator pairs in the
same window. 98 TRANSFER records in 90 days. UAT MCPs unreachable today.

## Design
architect-consult.md; Nam chose option 1 (2 files, N1-N3 accepted residuals), 2026-09-24.
N1 claim spot-checked: UnitloadBusinessService.transferUnitLoadToLocation "Lock order: Pickingorder before Unitload/Stockunit/Location".

## Mutation checks (all attributable)
| Mutant | Killed by | Message |
|---|---|---|
| M1 revert :318 findByLabelidForUpdate -> findByLabelid | unit rail scanDestination_shouldLockTheSourceBeforeAnyGuard | NeverWantedButInvoked unitloadRepository.findByLabelid("CASE-1") |
| M1 (same) | IT test 1 | blocked statement "update Unitload ... where id=$13 and version=$14" (flush UPDATE), blockedXid=8523 |
| M1 (same) | IT test 2 | ObjectOptimisticLockingFailureException instead of BusinessException "Can not move unit load from ... Shipped" |
| M2 revert resolver canonicalUnitLoadLabel existsByLabelid -> findByLabelid(..).isPresent() | IT test 2 | ObjectOptimisticLockingFailureException (SBDEV-3244 lock upgrade version check) — test 1 stays green, as expected |
| PIT resolver :129 (x2), :174 negated conditional | ScannedCodeResolverUnitTest | KILLED |
PIT survivors (pit-mutations.xml) are all on lines this change does not touch.

## Green run on the fix
IT: MoveUnitloadLockOrderProbeIT 2/2; test 1 blocked on "select ... from Unitload ... for no key update" with backend_xid NULL,
move then completed (outcome null) after holder rollback. Unit: ScannedCodeResolverUnitTest + MobileMoveUnitloadService{Unit,}Test 101 run, 0 failed.
