---
ticket: SBDEV-3672
kind: ralplan round 2 — Architect re-review
date: 2026-10-13
plan_snapshot: plan-snapshot-round2.md
verdict: APPROVE WITH CHANGES (no third round needed)
note: saved by the main session; the architect agent is read-only
---

# Round-1 findings

| ID | Verdict | Note |
|---|---|---|
| M1 audit | PARTIAL | MANDATORY method correct (MS:110 is REQUIRES_NEW); but `wms:requeue` IS counted by the egress watchdog → N1 |
| M2 lock | PARTIAL | FOR UPDATE + guarded DELETE correct; missed the 3 s tenant lock_timeout (LockTimeoutHibernateJpaDialect.java:213, application.properties:128) → N2 |
| M3 resend | RESOLVED | resendMessage links via saveServiceLog(..., original.getId()) (MS:186-196) |
| M4 entity column | RESOLVED | unmapped; RETURNING * maps entity columns by name |
| M5 CLUB fairness | RESOLVED | arithmetic + fallback trigger present (ODJ:136-139) |
| L1–L8 | RESOLVED | L7 tracked with OMS as intended |

# New in round 2 — soundness

- (a) createServiceLogInCallerTx MANDATORY on tenantTransactionManager: correct (OS.enqueue is MANDATORY, OS:41). MessageCleanupBatchService ages audit rows out normally. Watchdog DOES count it (N1).
- (b) resendConfirmed bound `r.id > o.last_message_id`: correct — Message ids from seqentities, allocationSize=1 (AbstractBaseEntity.java:19-24). Accepted gaps to state in R-9: a resend of an EARLIER attempt's row is not reconciled; if the final link failed, last_message_id points at the previous attempt.
- (c) native-only column + U15: sound.
- (d) D-ii: READ COMMITTED behaviour as planned; IDENTITY insert (OutboxMessage.java:54) makes the unique violation immediate → mappable to 409. Gaps N2, N4.
- (e) SET LOCAL lock_timeout: correct — StartupFlywayMigrator:292-299 default transactional config; no CONCURRENTLY. Add a comment citing V2.2.26:114.
- (f) NO_RECORD: PURGED derivable but boundary day (purge keys on modified_at, up to 24 h after ship under Fix C) → UNKNOWN; v1-era BOLs read PURGED (harmless). EMPTY_BOL under-specified → name the predicate (palletDtos source query as an exists) or drop it.
- (g) Principles/pre-mortem/rollback sound; add pre-mortem rows for N1 and N2/N4; rollback note on FAILED_TERMINAL chunk rows under the old image (manual UPDATE only); prefix critic Low labels (C-L4) to avoid collisions.

# New findings

| ID | Sev | Scenario | Fix |
|---|---|---|---|
| N1 | Medium | 3 requeues/week → SBDEV-3325 watchdog `failing` for ORDER_BATCH_SHIPPED_REQUEUE (destination not NULL/'N/A', null statuscodeanswer = failure); if sender = WMS instance name, operator can "Resend" the audit row → FAILED/503 row | destination = NULL; sender ≠ getWmsInstanceName() so resendMessage refuses (MS:163); OmsEgressWatchdogQueryIT fixture asserting zero findings |
| N2 | Medium | Concurrent requeue loser waits >3 s → CannotAcquireLockException → 500 (breaks "never 500"); I7's K=2 fixture can't see it | catch PessimisticLockingFailureException → 409 (precedent StockUnitController:421, PickingController:76); U14 #lockTimeout_maps409 |
| N3 | Medium | I6's unique violation fires at the C1 save (IDENTITY), before DELETE and audit write → mutation MANDATORY→REQUIRES_NEW survives | reflection pin U12 #auditWriteIsMandatoryTenantTx (+ optional IT: call outside tx throws IllegalTransactionStateException); re-point mutation target |
| N4 | Low | requeue lock covers IN_FLIGHT rows → dispatcher markSent (REQUIRES_NEW, OS:81) times out at 3 s → row re-POSTed after 15 min reclaim (OMS NOOP) | lock only status='FAILED_TERMINAL' rows; decide D-ii eligibility/in-flight reason from a plain read |
| N5 | Low | PURGED mislabelled on boundary day / v1-era; EMPTY_BOL left to executor | as (f) |

# Consensus addendum

- Antithesis: every round adds guards and each brings its own interaction (N1–N4); O2 (A+C + scripted replay) has none; D-ii stays a permanent feature for one row.
- Tension: P-4 (self-service, screen = system of record) vs P-5 (no new effect on existing machinery). N1 and N4 are P-5 regressions caused by P-4 features.
- Synthesis: keep O1; ship D-ii behind the retirement follow-up; make each guard's interaction an explicit test (watchdog fixture, lock-timeout 409, MANDATORY pin).
