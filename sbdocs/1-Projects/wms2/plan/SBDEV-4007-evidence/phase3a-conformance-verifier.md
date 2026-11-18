# SBDEV-4007 P1 — Phase 3a conformance verifier (transcribed by lead; lane cannot write files)

Reviewed: `git diff 68a20d76..311e93e9` (6 commits, 34 files, +3134/−10). Lane: oh-my-claudecode:verifier (opus), 2026-11-04. The lane read code only and ran nothing.

**Verdict: GAPS / REQUEST_CHANGES.** The code matches §0 and §3 with no High design deviation. The gap is the test coverage of the AC-7 fence, plus the doc row (§0 row 18).

- **Placeholders:** none. The grep of added lines for TODO|FIXME|@Disabled|assumeTrue|UnsupportedOperationException returned 0 hits.
- **Legacy validate:** body moved verbatim into `buildClubLineValidation`.
- **`processOrder`:** REQUIRED, so it joins the fenced tx.
- **§0 rows 1, 2, 4, 5, 6, 7, 12:** conform. Row 3 is unchanged. Row 10 is pinned. Row 16 is extended. **Row 18 is not done.**

| # | Sev | §-ref | Finding | Fix |
|---|---|---|---|---|
| 1 | **High** | §3.3 / AC-7 | The fence is tested only in validate. Any one of these deletions leaves every test green: `renewLease` in `processOrderFenced`; `renewLease` or `markDone==0` in fenced finalize; `renewLease` in `failJob`. | Add ITs where a spy reclaims mid-run (age the lease, then `claimNext`). (a) Inside the 2nd `processOrderFenced`: that order gets no parcel and the job row is unchanged. (b) Before finalize: batch ≠530 and job ≠DONE. (c) `failJob(stale)`: LeaseLost is thrown and the batch stays 527. Mutation-check each. |
| 2 | Med | §0 row 18 | `wms2-club-run-workflow.md` is not updated: no §7/§9.9 correction and no STUCK reconcile procedure, although the `wms2.clubrun.job.stuck` alert points at it. The scheduled-jobs catalog is also missing `ClubRunJobPollerJob`. | Phase 4 docs |
| 3 | Low | §3.5 | Code uses cron `*/4`, while the plan says `*/5` (plan lines ~265, 271). `*/4` is justified: `*/5` hits second 50, which RECONCILE_CRON owns. | Update the plan |
| 4 | Low | §3.4 | The poison-guard message has no "last owner", because the claim overwrites `lease_owner`. Justified. | Record as a deviation |
| 5 | Low | §3.5 | The `ClubRunShutdownGuard` comment claims the flag is raised before the executor interrupts. The lane thinks that in Spring 6.1+ `shutdownNow` runs on ContextClosedEvent, i.e. before lifecycle stop(). The lane did not check this. Either way the interrupt branch abandons. | Check the Spring source; fix the comment |
| 6 | Low | AC-8 | The tests can't tell the native `findOriginalBatchState` read from `lease.originalBatchState()`, because the two agree in both cases. | Add a case: lease null, native 525 → resume |
| 7 | Low | AC-15b | `rejectedKickIsHarmless` asserts only the swallow, the counter and the QUEUED DTO; "poller later runs it" is not asserted. | Narrow the AC, or cite AC-14b plus the ITs |
| 8 | Low | AC-9e | The job is seeded at attempt 4, so the claim goes straight to `markStuck`; the `doThrow` on failJob is never reached. | Seed so that the failJob-fails loop is actually exercised |
| 9 | Low | AC-2 | The two latched threads may serialize; ON CONFLICT is proven only sequentially. | Optionally hold T1's tx open after its insert so T2 blocks |
| 10 | Low | §3.4 / AC-9b | `failJob` on a 527 batch with no original_batch_state leaves the batch at 527. §3.4 allows it; the AC-9b wording does not. | Reword AC-9b |
| 11 | Low | metric | Poller over-submission increments `kick_rejected`, mixing noise with real submit-kick rejections. | Split the counter |
| 12 | Low | §3.6 | The 3 new routes catch only `BusinessException\|EntityNotFoundException`; other errors go to RestExceptionHandler. The legacy GET has a RuntimeException arm. | Accept with a note, or add the arm (it must be sanitized; see security #2) |

AC status:
- VERIFIED: AC-1, 3, 4, 5, 6, 6b, 9, 9b (wording caveat), 9c, 9d, 10, 11 (smoke), 12 (pin), 13, 14, 14b, 14c, 15.
- PARTIAL: AC-2 (#9), AC-7 (#1), AC-8 (#6), AC-9e (#8), AC-15b (#7).

§3 deviations, all justified or neutral:
1. Cron `*/4`.
2. No last owner in the poison-guard message.
3. Lease seconds are a constructor param on CustomerorderBatchService (SBDEV-3304 forbids a @Value field there); sync-wait is a @Value field on the controller.
4. `RETURNING *`.
5. Counting discard lambda.
6. Redundant TenantContext set in the poller task.
7. Legacy GET maps STUCK to the errors shape.
