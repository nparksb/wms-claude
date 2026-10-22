# SBDEV-3605 — Critic re-review, round 2 (2026-09-30), independent of the Architect
VERDICT: ITERATE (1 High). All 14 r1 findings are RESOLVED (per-finding evidence is in the message).

## New
- N1 HIGH — after D3′, U-1 cannot kill its "drop others" mutant.
  - Setup: res 8, others 3, req 5. Correct: FINISHED −5 only. Mutant: FINISHED −5 plus MANUAL −3. A FINISHED-only assert stays green.
  - Fix: U-1 asserts never() MANUAL_ADJUSTMENT with null-safe any(), or asserts the captor sum of deltas. U-3 asserts both rows.
  - Rule for §8: assert both codes or the total, never FINISHED alone.
- N2 Medium — a negative X.requestedamount gives remainder = ownShare − req > ownShare.
  - The release (9) no longer equals the credit (5), and recordChangeReservedAmount logs −9 (ledger drift).
  - Fix: req.max(ZERO), plus U-10 (req −4, ownShare 5 → MANUAL −5; mutant → total 9).
  - NULL or 0 req means the whole share goes to MANUAL — say so explicitly.
- N3 Medium — S7 on its own moves the two-order failure later.
  - Today: throws at the first UL scan (MobileMoveUnitloadService:186/:272), before anything moves.
  - After S7: the scan passes, then the S5/S6 Optional throws IncorrectResultSizeDataAccessException into the MobileEndpointExceptionHandler catch-all (500) at the destination step, often after the pallet has physically moved.
  - Fix: (a) S7 detects >1 and throws at scan, or (b) defer S7 into P-S5S6.
- N4 Low — the release site still masks max(0); only U-2/U-2b kill it. Say so.
- N5 Low — REPLENISH_ALREADY_FINISHED exists only in messages_en_US.properties. FacadeException.resolve uses Locale.getDefault(); on a miss it falls back to "key, ". Pre-existing. The manual test should expect whichever form the deployed locale yields, or add the key to the base bundle.
- N6 Low — finish's transferStockToUnitLoad takes unitload/location locks (the Unitload lock is an upgrade on the step-2 read) and, for BLOCK_REALIGN codes, pickingorder locks. Scope P3 and §7 #4 to order+SU rows; name the finish-path locks as unchanged.
- N7 Low — add U-8b: a scanned SU gone between steps 2 and 3 → MsgSourceStockNotFound, no release.
