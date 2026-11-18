---
lane: code-reviewer (Phase 3b, round 2) — saved by main session 2026-11-06
head: e60a10c4
scope: git diff 85daa64b..e60a10c4 (03850bb0, fd1a5378, e60a10c4)
verdict: APPROVE (0 High, 0 Medium, 4 Low, 1 open question)
---

# Round-1 findings: status
- Code M1: fixed and correct (§10.z verbatim).
- Code L2–L7: fixed. The L7 deviation is justified: it asserts never() on the P and L′ locks.
- Code L1 (WIP subject): open; the main session owns it.
- Security L1 and L2: fixed.

# Mutation probes (scratchpad copy)
| Mutant | Description | Result |
|---|---|---|
| a | drop `assignment = null` | killed (requestedamount 84) |
| b | re-add the A1 late lock | killed by both stale-hint tests |
| c | P→L′ above the lock-free refusals | killed |
| d | hoist the two L′-guarded checks above P→L′ | SURVIVES, 101/0 → L-1 |

# Findings
| ID | Sev / Conf | Site | Scenario | Fix |
|---|---|---|---|---|
| L-1 | Low / HIGH | FixLocationAssignmentService.move: the "stay UNDER the L′ lock" checks (findByAssignedlocationId(L′), findByStoragelocationId(L′)) | Mutant d passes all unit tests. AC-11 is very likely blind to it too (refill is blocked on F either way). | Add an InOrder unit test: lockById(2L) before both checks. Confirm mutant d goes red. |
| L-2 | Low / HIGH | ReplenishmentOrderMaintenanceServiceUnitTest stale-hint tests: `destinationId isNull()` | Without a findActiveLocationIdByItemdataId stub, a mutant that aligns without the lock still leaves null, so the assertion cannot fail on its own. | Add a lenient stub returning Optional.of(55L) in both tests. |
| L-3 | Low / HIGH | ReplenishorderServiceUnitTest: @Mock ItemdataRepository + 2× `never().findById` | The dependency was removed, so these are true by construction. | Delete the mock and both lines (the guarded thing can no longer happen). |
| L-4 | Low / MED | ReplenishOrderJob: two WARNs touched by this diff log the full throwable | PessimisticLockingFailureException carries SQL (the security-L2 concern). | Class name at WARN, throwable at DEBUG. |
| Q-1 | Low / LOW | move: the `atDestination` projection now runs before lockById(L′) | A mobile confirm could set an order's destination to L′ in between. The re-point would then hit idx_replenishorder_active_item_dest → DataIntegrityViolation rollback instead of a clean refusal. No data damage. | Accept and narrow the comment, or re-check under L′. |

Pre-existing, not a regression: hint fired + FLA gone under the lock → the unlocked findActiveLocationIdByItemdataId could see a new FLA (also in r1).

# Main-session disposition
Fix all four Lows. Q-1: re-check under L′ (cheap; keeps the early refusal and restores serialisation).
Also fold in conformance-r2 gap 2: never() P/L′ locks on the in-processing and not-a-flowbin refusals.
L-3: delete approved by the main session. The mock is no longer injected, so the assertion guards nothing; this is not weakening.
