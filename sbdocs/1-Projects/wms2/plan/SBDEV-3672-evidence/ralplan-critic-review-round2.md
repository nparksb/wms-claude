---
ticket: SBDEV-3672
kind: ralplan round 2, step 4 — Critic re-evaluation (deliberate)
date: 2026-10-13
plan_snapshot: plan-snapshot-round2.md
verdict: APPROVE (required edits RE-1..RE-3 before wms-tdd-gate)
note: saved by the main session; the critic lane is read-only
---

# Round-1 findings

All resolved: H1 (§3 P-1..P-5 + §9 pre-mortem, 4 scenarios), H2 (native-only column, U15, Step 6 gate, Rollback; OutboxMessage has @DynamicUpdate, IDENTITY, no @DynamicInsert → INSERT names mapped columns only; claim is native RETURNING *), M1 (U4 byte fixture; WmsObjectMapper.java:42 NON_NULL), M2 (resendConfirmed; MS:203-217), M3 (design; tests PARTIAL → N1), M4 (Prereq 5 gate; ClientCallbackService:46-63), M5 (R-3; ODJ:136-139), M6 (E2E table; SDR PUT /sysprop evicts via SdrCacheEvictionEventHandler:125), M7 (O1–O4), M8 (runbook; SendClientCallbackJob:79-81 — name the "LWC ~:2290" lookup column before the run), L1–L9.

# New Medium

- **N1 — two mutation targets unkillable by their named tests.**
  - "MANDATORY → REQUIRES_NEW (I6)": IDENTITY ids make OS.enqueue's save (OS:56) insert immediately, so I6's planted key throws at C1 before the audit row exists → I6 passes under either propagation.
  - "D-ii DELETE guard/rowcount (I6/I7)": I6 fails before DELETE; I7's loser locks zero rows → NONE; the winner's DELETE succeeds with or without the guard.
  - Fix: (a) U12 `#createServiceLogInCallerTxIsMandatory` (reflection) + a case whose failure comes AFTER the audit write (stub deleteTerminalById → 0; assert rollback + no audit row); (b) pin the DELETE guard in a unit test (rowcount 0 → exception, never RECHUNK) or drop it from the target list as unpinned belt-and-braces.
- **N2 — "the egress watchdog never counts `wms:requeue`" is FALSE.** egress-failures.sql counts every message row with destination NOT NULL and <> 'N/A', partitions by process, `failing` when last 3 fail `statuscodeanswer ~ '^2\d\d$'`; audit row's null code → 3 requeues = false finding. Fix: destination 'N/A' (existing exclusion) or SENT/"200"; pin in I4/O4 + an OmsEgressWatchdogQueryIT case.

# Minor

- m1 Step 6 "PRD: all six" FALSE — PRD landlord tenant_db_configuration has 4 rows, all at 2.2.37. Derive the list from landlord.
- m2 409 mapping: a unique violation marks the tx rollback-only; catching and returning normally → UnexpectedRollbackException → 500. The exception must propagate out of @Transactional and be mapped to a 409 ProblemDetail at controller/advice; U14 #raceConflict_maps409 throws from the service mock.
- m3 I6 setup trap: plant the key on a row OUTSIDE the predicate (different aggregate_type), else D-i runs.
- m4 resend reconciliation covers only the linked (latest) message — say so in UI/docs; narrow P-4 wording.
- m5 prefix cross-refs (A-M3 / C-M2).
- m6 O1 RECHUNK tag count: 1 or N — pick one.
- m7 EXPLAIN ANALYZE also on WineCo PRD (message 1.82 M rows vs c1wh 0.50 M); dual-island concern checked: WineCo max(id)=seqentities.last_value.
- m8 E2E Requeue row racy: run the forcing UPDATE before restoring the URL.

# Claim discipline (round-2 text)

TRUE: byte-identical ≤K payload; tenant missing V2.2.39 still enqueues/claims/dispatches; only the link + new endpoints fail; V2.2.37 on all four PRD DBs; rows leave only as SENT or via D-ii (src/main); NOOP excluded from callbacks; D-ii unreachable under the lock; loser → NONE. FALSE: watchdog never counts it (N2); "all six" (m1). UNPROVEN: never 500 for a race (m2). IMPRECISE: "createMessage REQUIRES_NEW at MS:110" (:110 is createServiceLog; conclusion holds).

# Criteria

1 Pass · 2 Pass · 3 Pass · 4 PARTIAL (N1) · 5 Pass (m8) · 6 Pass · 7 Pass.

Required before wms-tdd-gate: RE-1 = N1(a)+(b); RE-2 = N2; RE-3 = m1. m2–m8 foldable during the gate.

Open: audit row statuscodeanswer 'REQUEUE' for Service Log filtering? Guard Service Log resend against the audit row (sender/process or 'N/A').
