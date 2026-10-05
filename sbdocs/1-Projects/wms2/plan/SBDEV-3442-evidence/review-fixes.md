# SBDEV-3442: how each review finding was handled (author pass, 2026-09-24)

Reviews: code-review.md (APPROVE, 1 Medium + 7 Low) and concurrency-review.md (APPROVE, 4 Low), both on ee523d44.
Fixes: ba03785c.

## code-review.md
| # | Action |
|---|---|
| M1 | Fixed. N2 now names StockunitBusinessService.transferStockToUnitLoad (Stockunit before Unitload; verified: `findByIdForUpdate(sourceStockunitId)` precedes `unitloadRepository.findByIdForUpdate(sourceStockunitUnitloadId)`), a concurrent Move Stock or pick confirm. closeBOL removed. |
| L1 | Fixed by dropping the per-branch list. The comment states the rule (nothing above the lock locks or writes, so everything after follows UL(source)), with how that was derived (by construction, measured on the location branch by the probe IT), and says why it is not enumerated. N1/N2 name transferStock, which covers :439/:481/:495. |
| L2 | Fixed: N2 now covers the Damaged in/out updates made right after the lock. |
| L3 | Fixed: IT javadoc narrows the claim. No stock in the fixture means no owning Pickingorder, so a Pickingorder-first mutant would pass; recorded as a blind spot, not measured. |
| L4 | Fixed: test 1 asserts the move completes after the holder rolls back. Mutation-checked: flipping the location branch's isMoveStock check (refuse after the lock) turns it red with that assertion's message; the block readings stay green. |
| L5 | Fixed: backend_xid is read in the same confirming statement as "still blocked by our holder". |
| L6 | Fixed: the comment records that every rejection now waits for this lock and can hit lock_timeout first. |
| L7 | Fixed: N3 covers either scanned field. |
| L8 | Fixed: new unit test scanDestination_shouldLockTheCanonicalSourceLabel. Mutation-checked: removing the dto rewrite (keeping the resolver call) gives "Argument(s) are different! Wanted: findByLabelidForUpdate("CASE-1")". |

## concurrency-review.md
| # | Action |
|---|---|
| L1 | Same as code-review M1; fixed. |
| L2 | Same as code-review L2; fixed. |
| L3 | Fixed: N1 names the likeliest partner (a concurrent move of the source's parent or child). The accepted-residual line now reads "the same unit load or one of its ancestors". The reviewer's coarse exposure query (TRANSFER pairs from the same source location within 60 s, different operators, Hydra prd, 90 days) returned 0, with 167 same-operator pairs as the positive control; recorded here alongside floor.md's same-label query. |
| L4 | The consult (architect-consult.md, the architect's own file, not edited) misses two sites. First, createFixedLocationAssignment → recalculateForItem locks replenishorder rows after UL(source); Hydra prd has never had a replenishorder row. Second, the sendToClearing tail (ignoreLock=true) adds no new order edge. Both are recorded here. |

Open question from the concurrency lane: the "3 s lock_timeout" assumes the running Hydra prd image carries SBDEV-3250. Not stated to operators; the PR body will not quote it.

## re-review.md (ba03785c): APPROVE, 10 Lows; fixed in the next commit
| Low | Action |
|---|---|
| IT assertion message still named "a Pickingorder" | Reworded: "in this stockless fixture, the destination Location". |
| L4 only half-done (outcome null, not position) | Test 1 also asserts the source now stands on DEST. |
| L6 Nirvana-sentinel sub-case | Recorded in the call-site comment. |
| "measured by MoveUnitloadLockOrderProbeIT" overclaims | Now says it measures against the destination Location lock only, and that the stockless fixture cannot see a Pickingorder lock. |
| N2 named 2 of ~12 caller families | Now "any concurrent transferStockToUnitLoad on the same unit load (it has many callers: ... among them)", no closed list. |
| "right after this lock" (Damaged) | Now says after the guards, reaching the database at the next flush, before any Pickingorder lock. |
| N1 "now deadlocks" | Now conditional on the tree holding stock that backs a pick line. |
| N2 exposure unmeasured by floor.md's query (unitload_record cannot see stock moves) | The reviewer's stockrecord join on Hydra prd (quoted in re-review.md §N2) returned 6 rows, all RECEIVING / STOCK_CREATED 24–47 s before a move, and none from a stock transfer or pick. So the positive control came back and the N2 population is 0. Recorded here as the N2 exposure instrument. |
| Inline query duplicated BlockedBackendReads; timeout message wrong when a block was seen but never confirmed | New BlockedBackendReads.confirmedBlockedStatementAndXid (plus a Confirmed record) used by the probe; the timeout now throws LEFT_WAIT_BEFORE_CONFIRMED in that case, like its siblings. |
| "describe one instant" wording | Replaced: the helper's javadoc states the actual reason the read is valid (one status copy; a blocked backend cannot take another lock while waiting). |
