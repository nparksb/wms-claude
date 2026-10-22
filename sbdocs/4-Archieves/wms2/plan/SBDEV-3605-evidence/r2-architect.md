# SBDEV-3605 — Architect re-review, round 2 (2026-09-30)
VERDICT: SOUND-WITH-CHANGES (0 High). All 11 r1 findings are RESOLVED (H1, H2, M1–M4, L1–L5), with evidence from daf64d41.

## New in r2
- N1 (Medium): a negative X.requestedamount breaks the credit == release invariant.
  - attributed = ownShare.min(req) = −4, which the guard skips; remainder = ownShare + 4, so the release exceeds ownShare.
  - zeroIfNegative then strips the other holders.
  - Fix: `req = safe(order.getRequestedamount()).max(ZERO)`, plus test U-3b (req −4, res 8 → 0 FINISHED rows, MANUAL −8).
  - Latent: DEV has 0 negative/NULL values out of 389,091 rows.
- N2 (Medium/Low): S7 alone moves the two-order failure later without closing it.
  - checkReservedStock passes the scan; the S5/S6 Optional probe then throws at scanDestination/confirm into the mobile catch-all.
  - Option (a): S7 counts, and on >1 throws a BusinessException naming both orders. Option (b): defer S7 into P-S5S6.
  - R5 must name where it fails.
- N3 (Low): the §7 #4 "no cycle vs another multi-UL" claim is too broad.
  - finish's transferStockToUnitLoad locks the destination SU late, not in ascending order (SBS:202–283).
  - Reword to "no cycle within the order + source-SU set". The residual is bounded by 409.
  - CODE_REPLENISHMENT is not in BLOCK_REALIGN_CODES, so there is no PO↔SU inversion.
- N4 (Low): IT-7 must assert that A's rows are CREATED +qty and then FINISHED −qty.
- N5 (Low): MobileReplenishServiceUnitTest has 13 findByUnitloadId references; any that become unused raise UnnecessaryStubbingException under strict stubs. List them.
- Low: U-9 must register both advices, RestExceptionHandler @Order(0) and MobileEndpointExceptionHandler, to prove which one wins.

## Verified OK
- Two changeReservedAmount calls on the same locked SU: the re-lock is not an upgrade, and the auto-flush happens before the second JPQL, so no delta is lost.
- Id-only resolution happens before any Stockunit read, so every lock is a first touch; the only remaining upgrades are Unitload rows (pre-existing, 409 if stale).
- The sums run before save #1.
- The 409 mapping is confirmed.
