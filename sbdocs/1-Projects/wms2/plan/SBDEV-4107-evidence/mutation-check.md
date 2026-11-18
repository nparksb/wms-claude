# SBDEV-4107 — mutation check — head: d77daa01

Lane: mut-4107 (test-engineer, opus), 2026-11-11. Ran in its own detached worktree, `.claude/worktrees/wms2-api/SBDEV-4107-mut`, at d77daa01. Every run used `TESTCONTAINERS_REUSE_ENABLE=false`, with one mvn at a time. Each mutant was restored with `git checkout`, and `git status` was empty before the next. Saved by the parent session.
Logs and PIT XML: `/private/tmp/claude-503/-Users-np1076-dev-spk-owl/accbb0fa-a9ea-4061-b4d7-305226e8dc0b/scratchpad/mut/`

**Control (unmutated):** the 9 gate IT classes plus GoodsReceiptPositionReturnFinishIT ran 21 tests, 0 failures, 0 errors.

## Hand-planted mutants: 13 of 14 killed, each with an attributable message
| Mutant | Red | Attributable | Message |
|---|---|---|---|
| M1: delete the assign re-check | IT 1 | yes | "expected the re-check, not the index, to refuse (the 'taken concurrently' WARN is logged only on the index-catch path)" |
| M2: drop the customerorder unique index | IT 1b, 2b, 5, 8 | yes | "2 open orders on lane A … must still be backed up by uq_customerorder_open_transferlane"; "index missing: uq_customerorder_open_transferlane (V2.2.51)" |
| M3: catch always rethrows | IT 1b, 2b | yes | "the unique violation must be mapped to the normal refusal, not escape as DataIntegrityViolationException" |
| M4: delete `lockById` (S1) | IT 3b | yes, via the WARN assertion (see note A) | "expected the re-check, not the index, to refuse" |
| M5: drop the staging unique index | IT 3, 8 | yes | "2 batches on L … uq_customerorder_batch_open_staginglane must back it up" |
| M6: delete the advice lock in receiveGoods | IT 4 | yes | "2 receipts for advice A … must wait for the advice lock and reuse the first one" |
| **M7: delete the finisher's advice lock** | **none** | **SURVIVED** | Every receive already holds the advice lock, and no test raced an adjust or delete against a receive. PIT cannot mutate this line, because forUpdate returns a value. |
| M8: updateAdviceWithPositions back to findById | IT 7 | yes | "duplicate AP number ADV-SBDEV4107-000000" |
| M9: GRP draw = `.size()` | IT 6 | yes | "duplicate GRP number GRT000001-000001: the count-based draw reissued a number a live row still holds" |
| M10: `flushMode=COMMIT` hint on findNumbersByAdviceId | IT 6b | yes | "a non-flushing draw numbers all three -000000" |
| M11: predicate `state < 600` | IT 8, 5 | yes | "predicate mismatch on uq_customerorder_open_transferlane" |
| M12a/b: DO guard `HAVING > 2` | IT 8b | yes | "no exception: the V2.2.51 guard must refuse two open orders on one transfer lane" (and the same for staging) |
| M13: re-check lambda returns `true` | IT 1, IT 2 | yes | the same re-check message, for assign and for activate |

**Note A (Low).** Under M4 the IT 3b subject still blocks, on the index entry rather than on lane L. So `subjectBlocked()` "on lane L's location lock" passes for the wrong reason, and the comment claiming the harness fails "observably BLOCKED" is false while the index exists. The kill holds through the WARN assertion. Fix the comment and the `.as()` text.

**M7 disposition.** This is the same gap as code-review Medium M1. It is addressed by `ReturnAdviceCorrectionFinishRaceIT`, whose subject is a GRP delete (commit 53db2d9f), plus the lock move (513ca9cb) and a unit InOrder check. M7 must be re-run on the new HEAD and be killed there.

## PIT, survivors on changed lines only
- **UniqueViolations** (target test TransferOrderServiceUnitTest, since no dedicated test exists): 5 of 6 killed. **NO_COVERAGE on `return false`**: no test passes a violation with no named CVE in its cause chain. Add a unit case with an unnamed SQLException(23503) cause, plus a null-cause case. Low.
- **TransferOrderService:** the survivor is the re-check lambda replaced by `true`. It is killed in the IT lane (M13). For unit hardening, stub a re-check that returns only a DIFFERENT lane and expect the refusal. Low.
- **BasicService.nextSuffix** (as of d77daa01): **3 boundary survivors.** `>= '0'`→`> '0'` lets a suffix ending in 0 be misread, so a live number is REISSUED. `<= '9'`→`< '9'` does the same for 9. `start > 0`→`>= 0` gives SIOOBE on an all-digit string. **MEDIUM** for the first two. Add the cases "X-000010" → 11, "X-000009" → 10, and an all-digit case. Re-run PIT, because 39aaec4c rewrote the parser.
- **CustomerorderBatchService:** no survivors on changed lines.
- **ReceivingService:** NO_COVERAGE on the FK-impossible "advice not found" branch after findAdviceIdById (Low/ignore). No mutant at the finisher lock line (see M7).

Final mut-worktree `git status`: empty.
