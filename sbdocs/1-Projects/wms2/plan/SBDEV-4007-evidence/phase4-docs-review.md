# SBDEV-4007 P1 — Phase 4 docs/plan/PR-body review (transcribed by lead; lane cannot write files)

- **Lane:** oh-my-claudecode:verifier, 2026-11-05.
- **Checked:** code at d70beaaf. No Maven run.
- **Why it ran after the push:** Nam asked "were the changes reviewed?" after PR #622 was pushed. The docs, the plan edits and the PR body had never had an independent review.

**Verdict: ERRORS (REQUEST_CHANGES).**
- Correct: endpoints, HTTP codes, metric names, property defaults, cron, thresholds and error texts.
- The STUCK restore SQL is column-correct (V2.2.47 + V2.2.00), its `state = 527` guard matches `failJob`, and the `version + 1` bump is right (`@Version`). Leaving the job STUCK while restoring the batch is consistent, because the partial unique index covers QUEUED/RUNNING only.
- No surviving idle-backoff text. No doc claims raw exception text in `last_error`.

| # | Sev | Where | Finding | Fix / status |
|---|---|---|---|---|
| 1 | Med | workflow §8A, catalog §4.9, rest ref §9, sysprop changelog | Cite `e8bb583f`, which is pre-rebase and only on the backup branch | → `d70beaaf` (docs lane) |
| 2 | Med | sysprop §11.2 | Overstates the kill-switch race; the inline GET is refused while a live job exists, leaving only a TOCTOU window | Reword (docs lane) |
| 3 | Med | workflow §8A.6 step 3 | "batch 530 → mark job DONE" cannot happen (markDone runs in the same tx as finalize) | → "cannot happen; escalate" (docs lane) |
| 4 | Low | §8A.3 FAILED row | Cross-ref §8A.6 should be §8A.8 | docs lane |
| 5 | Low | §8A.6 step 6 | `last_error` belongs to the job, not the batch | docs lane |
| 6 | Low | §8A.6 step 2 | Undefined `:canceled` placeholder; should be `<> 800` | docs lane |
| 7 | Low | §8A.3 ABANDON; plan line ~247 | Missing the R2 exception: a Business/Facade exception always fails | docs lane (workflow); lead (plan) |
| 8 | Low | §8A.3, §8A.6 | Timing: a failJob-failed abandon keeps the lease (300 s per retry), failJob can first fail at attempt 2, so STUCK arrives about 10 min after the first failJob failure | docs lane |
| 9 | Low | plan §7 AC rows | Stale test names | Lead fixed **all 15**, not only the 5 the lane flagged: a full sweep of `Class#method` refs against `src/test/java`, re-run with a positive control → 0 missing |
| 10 | Info | `ClubRunJobWorkerIT` AC-9c `@DisplayName` | Says "prefixed lastError"; since F2 it is sanitized | Impl lane, local commit; pushing to PR #622 awaits Nam |

## Re-check (after fixes)

- #1–#9: fixed; #9 rests on the lead's positive-control sweep. Timing confirmed: about 15 min from a first failJob failure at attempt 2, about 20 min from attempt 1.
- One new error came from the lead's own #7 edit: the "next tick reclaims" clause was attached to the kept-lease cases, and a stale "shutdown waits for lease expiry" cell remained. Fixed.
- Reviewer confirmed against `ClubRunJobWorker`: SHUTDOWN and TRANSIENT use `abandon(..,true)`; INTERRUPTED and FAILJOB_FAILED use `abandon(..,false)`. **No further issues.**
