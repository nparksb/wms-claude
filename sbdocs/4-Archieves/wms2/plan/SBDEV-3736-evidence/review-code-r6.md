---
head: 16ce87f7
reviewed: 2026-10-15
verdict: APPROVE
---
# Code review r6: comment-only fix for R5-L1 (16ce87f7)

- (1) Comment-only: `git show --stat` is 1 file, 3 insertions, 0 deletions; every changed line is a `//` comment. No code change.
- (2) Accurate: `GoodsReceiptPositionService` takes only the stock-unit lock (`lockStockUnitOnItsUnitLoad`, lines 199-211) and has no advice-position lock in `adjust` (94-125) or `delete` (137-141). The "NOT lock-covered" claim is correct.
- (2) Accurate: "best-effort snapshot" and "residual window" match R5-L1 and the javadoc at `ReceivingService.java:700-711`.
- (3) `finishReturnAdviceIfComplete` exists (`ReceivingService.java:766`, public, `@Transactional` tenant TM). Its javadoc bullet "Stale finish that remains" (lines 700-711) describes a sibling adjust/delete committing after the re-read and being unseen. The word "residual" does not appear there, but the described window matches the comment.
- Nit only, not blocking: the comment says "residual window" where the javadoc says "Stale finish that remains". A reader can follow either.
