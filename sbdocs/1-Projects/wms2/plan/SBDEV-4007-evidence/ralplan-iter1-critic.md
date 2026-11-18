# SBDEV-4007 ralplan iteration 1 — Critic review (transcribed by lead; lane cannot write files)

**VERDICT: ITERATE** (adversarial mode — 3+ High/Med on terminal-transition classification). Core design sound; spot-checks of
validateClubLine, size guard, clubRequirements, processOrder setParcelId, rollbackClubLineState, claim gate, cron, OSIV, V2.2.46 all correct.

| # | Sev | Finding | Fix |
|---|---|---|---|
| 1 | High | `setWaitForTasksToCompleteOnShutdown(false)` → SIGTERM interrupts → "any other Exception → FAILED+restore" ⇒ rolling deploy FAILS runs, defeating D3 | only Business/Facade terminal; shutdown flag / interrupt / transient DB errors → abandon lease; AC: interrupt IT ends DONE |
| 2 | High | FAILED and rollback as two writes + swallowing rollback ⇒ FAILED job with batch at 527 = permanent orphan | one fenced non-swallowing tx; on its failure leave RUNNING; AC: `FAILED ⇒ batch≠527` with failure injection |
| 3 | High | unique-violation re-read in same tx impossible (Postgres abort; JPA flush at commit); AC-2 only tests the index | `INSERT … ON CONFLICT … DO NOTHING RETURNING id` then select, or REQUIRES_NEW + caller retry; concurrent submit IT |
| 4 | Med | `processOrderFenced` lacks rollbackFor; Business/Facade checked (`BusinessException.java:14`) ⇒ UnexpectedRollbackException hides the message (260520 §5.4) | rollbackFor on every new tx; LeaseLost unchecked; AC-9 asserts lastError = shortfall |
| 5 | Med | TDD gate: ACs target non-existent classes → compile failures | state strategy: committed throwing skeletons; label AC-12 a pin |
| 6 | Med | legacy timeout body not tolerated by `clubRuns.js:460`; QUEUED-at-timeout → error toast for a run that still happens | body the UI handles, or document P1→P2 gap; AC-10 covers QUEUED |
| 7 | Med | kill-switch scope undefined | poller skips when '0'; inline legacy refuses batch with live job; in AC-14 |
| 8 | Med | poller hand-off: running on the shared scheduler pool (size 14) or claim-then-reject strands a lease | check activeCount < workers, submit a task that claims on the executor thread |
| 9 | Med | manual plan: batches reused, no lane/stock precondition, no snapshot/restore | per-scenario batch + query incl. lane & stock; wms-dev-probe snapshot/diff |
| 10 | Med | D1 said per-order progress; plan derives from parcel_id → add to Q1 ack; confirm parcel_id null pre-run on dev | (lead ran it: 9/9 runnable batches have 0 orders with parcel_id) |
| 11 | Low | native version bump vs `@Version` | native `WHERE id AND attempt` for all job writes |
| 12 | Low | DDL id has no default | state entity extends AbstractBaseEntity |
| 13 | Low | AC-11 weak (index already forces one claimer) | AC-7 strict: zero rows by superseded attempt |
| 14 | Low | AC-6 "test hook" unnamed | spy on ClubRunStepService / callback seam |
| 15 | Low | P3 kick holds global all-tenant lane lock up to 5 iterations | cap at 1 |
| 16 | Low | second legacy GET now waits instead of refused — note in §6 | |
| 17 | Low | completeness words: name the 4 fenced methods; "every AC is JUnit" false for cypress AC | |

Risks: R-5 open for QUEUED (#6); R-8 contradicted by shutdown setting (#1); R-9 partial (#8); R-12 uncovered (no poll interval in P2); R-13 deferred.
Flyway/rollout: V2.2.46 unclaimed; grants match V2.2.42 "no GRANT"; state initDB seeding / code default for WMS_CLUBLINE_ASYNC.
To APPROVE: fix #1–#4, document #5 & #7, fix manual table (#9).
