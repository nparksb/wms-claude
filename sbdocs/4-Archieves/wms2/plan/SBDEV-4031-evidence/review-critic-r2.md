---
lane: critic (ralplan round 2, scoped, independent of the architect)
snapshot: plan-snapshot-r2.md sha1 7be5ab91
verified_against: origin/develop d6424491
verdict: APPROVE (the Mediums are test-spec edits to make before wms-tdd-gate; no third round)
saved_by: main session, summary of the lane's reply
---
# Critic review, round 2: APPROVE

All round-1 findings F1–F15 are CLOSED against the code. Five new snippets were spot-checked, and all hold.

## New findings

- **N1 (Medium).** AC-8 and AC-8b are green after step 1, so labelling them red-first gives the rejected "compile-error red". Relabel both as guards and drop them from step 2. Add a positive control to AC-8b: at least one caller per allowed class after step 5.
- **N2 (Medium).** AC-10b's pre-fix red is "expected BusinessException ('already targets the destination') but nothing was thrown". The DataIntegrityViolationException message belongs in the mutation column.
- **N3 (Medium).** `HeldRowLockRace` releases its lock the moment the subject blocks, and it never exposes the subject's pid or statement text. That breaks AC-9 (hold > 3 s → 409), AC-4e (55P03 caught per order) and the §8.1 `confirmedBlockedStatement` requirement. Use a custom two-latch holder, or use the `bumpUnderLock` hook: read the subject pid via `pg_blocking_pids`, call `confirmedBlockedStatement`, then sleep longer than lock-timeout-ms. AC-4e must pin item 1's order id below item 2's.
- **N4 (Medium-Low).** AC-10c parks too early, because step 2 calls `unitloadRepository.findById`. Park instead on `unitloadRepository.findByStoragelocationId`, matched on the old location id, and say how step 2 gets the FLA unit load.

## Low findings

- **L1.** Only the ≤35 `fixLocationAssignmentRepository.findById` stubs change, not all 60 `findById(` calls.
- **L2.** Give the explicit `@Query` for `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById`, and decide whether to keep or retire `findByStateLessThanEqualAndDestinationIdIsNull` (it still has test callers).
- **L3.** AC-8b must also assert there is no class-level `@Transactional` on `MobileReplenishService`.
- **L4.** `RecalcContext` is private, so AC-4d must drive the code through `recalculateOpenOrders(true)`.
- **L5.** AC-9 cannot seed "no UL" (NOT NULL FK). Seed the UL in Nirvana instead, which gives `Removal(null, null)`.
- **L6.** Scope the ADR's "every path that creates…" claim (operator creates are covered by P69, not this ticket). Reword v2 row 1, because R3's id finder runs outside a transaction.

## Open question

Does `FixLocationAssignmentServiceIT` actually trip `LockReadRail`? The rail's javadoc says rows seeded through the shared context sit at WRITE and are not reported (`LockReadRail.java:85-90`). Run that IT after Fix B/F before rewriting its 4 call sites.
