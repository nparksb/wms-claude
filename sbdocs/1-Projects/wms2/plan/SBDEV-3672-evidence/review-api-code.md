---
ticket: SBDEV-3672
kind: review
lane: api-code
repo: v2/wms2-api
head: ad8ff63e (round 1 fb89bd31, round 2 1866ab66, round 3 057d0e3b)
base: origin/develop (merge-base of the review worktree)
date: 2026-10-16
verdict: APPROVE (round 4; no open findings)
---

# SBDEV-3672 wms2-api code review (lane api-code)

Worktree: `.claude/worktrees/wms2-api/SBDEV-3672-review-code` (detached at fb89bd31). Diff: `git diff origin/develop...HEAD` (32 files, +3,894/-38).

## Evidence I collected

| Instrument | Result |
|---|---|
| `mvn -o test` on 11 classes (the new and changed unit tests plus `NeverMatcherNullBlindnessArchTest` and `SelfInvokedTransactionalArchTest`) | 278 run, **2 failures**, both in `NeverMatcherNullBlindnessArchTest` (H1). Every other class is green. |
| `mvn -o verify` failsafe on `BolOmsNotificationRowsIT`, `MessageServiceCallerTxIT`, `OutboxMigrationV2240IT`, `BolChunkOutboxClaimIT`, `OmsEgressWatchdogQueryIT` | 47 run, 0 failures, BUILD SUCCESS |
| PRD read-only probe on all 4 tenant DBs (c1wh-shipitez `wh01_shipitez_v2`, nywh-hydra `wh01_hydra_v2`, nywh-shipitez `wh02_shipitez_v2`, wsl-wineco `wh01_om1_v2`) | On each DB the app role owns both `outbox_message` and `los_sysprop`. Flyway max is **2.2.38**. No `last_message_id` column exists yet and no `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` row exists. Row counts of BOL outbox rows in FAILED_RETRY or FAILED_TERMINAL: c1wh 1 (outbox 11135), all others 0. |
| `StartupFlywayMigrator:292-299` | Uses Flyway's default `executeInTransaction`, so `SET LOCAL` in V2.2.40 is in scope. A failed tenant migration leaves the boot green and freezes that tenant (`:310+`). The plan's Step 6 gate covers this. |
| `OutboxService.markRetry:96-97` | Caps the shift at 16 and computes in `long`, so 29 attempts cannot overflow the backoff. |

## Code Review Summary

**Files reviewed:** 32 (all main files read in full; tests read where they pin a focus item)
**Total issues:** 13

- HIGH: 1
- MEDIUM: 1
- LOW: 11

## Issues

### [HIGH] H1: `NeverMatcherNullBlindnessArchTest` is red, so the build fails
- **Files:** `src/test/java/net/aim_ai/wms/unit/service/BolOmsNotificationServiceUnitTest.java:372` and `:499`; inventory in `src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java`
- **Confidence:** HIGH (reproduced)
- **Failure output:**
  - `noNeverVerifyUsesAReferenceTypedMatcher:286` flags `BolOmsNotificationServiceUnitTest:372 -> anyList()`, `:372 -> anyString()`, and `:499 -> anyString()` ×2.
  - `primitiveCapableMatchersMatchInventory:835` reports `BolOmsNotificationServiceUnitTest: expected 0, found 1` and `OutboxDispatchServiceUnitTest: expected 5, found 8`.
- **Concrete harm:** CI gates deploy on tests (memory *wms2-no-pipeline-runs-tests*), so the PR cannot merge. The flagged sites are also null-blind for real:
  - `verify(outboxRepo, never()).requeueBolTerminal(anyList(), anyString())` stays green if a regression calls `requeueBolTerminal(eligible, null)`. A null URL is exactly the case the blank-URL guard at `BolOmsNotificationService:181-184` exists for.
- **Fix:**
  - At `:372` and `:499`, replace `anyList()`/`anyString()` with bare `any()`. Neither parameter is primitive or varargs.
  - The new `markRetry(any(), any(), anyInt())` sites are correct, because `int` is primitive. Update the inventory to `OutboxDispatchServiceUnitTest:8` after reading each signature, and add a `BolOmsNotificationServiceUnitTest` entry if any `anyLong()` on a primitive remains.
- **Related process gap:** `impl-api-executor.md` §"Full suite on the final commit" still holds the placeholder `@@SUITE@@`. The full suite was never recorded, and this red is the proof that it did not run green. See M1.

### [MEDIUM] M1: no full-suite evidence at the reviewed head
- **File:** `sbdocs/.../SBDEV-3672-evidence/impl-api-executor.md` ("Full suite on the final commit")
- **Confidence:** HIGH
- **Issue:** Floor item 5 (full suite against the known baseline) is unmet. H1 shows that the targeted runs missed a cross-cutting arch rule.
- **Fix:** Fix H1, then run the CI command copied from the run log (`-Pci`, memory *wms2-test-suite-baseline-and-h2-verdict*) and record the counts against the baseline.

### [LOW] L1: `runShippingPhase` lost its javadoc
- **File:** `BillofladingService.java:430-444` (the old javadoc ends at `:440`; the new method's javadoc starts at `:441`)
- **Confidence:** HIGH
- **Issue:** `enqueueBolShippedNotification` and its javadoc were inserted between `runShippingPhase`'s javadoc and the method. Two doc comments now sit back to back. The first one (the SBDEV-3728 sharing note and the DETACHED-on-return warning) no longer attaches to `runShippingPhase`, and the IDE and javadoc tooling show the wrong text on both methods.
- **Fix:** Move `enqueueBolShippedNotification` below `runShippingPhase`, or above the old javadoc block.

### [LOW] L2: the row set and the requeue do not filter on `process_type`
- **Files:** `OutboxMessageRepository.java` `findBolNotificationRows` WHERE clause; `requeueBolTerminal`
- **Confidence:** HIGH that the gap exists; latent today
- **Issue:** Rows are selected by `aggregate_type`/`aggregate_id` only, and the requeue then rewrites `destination_url` to the WEBSERVICE_ORDER_BATCH_SHIPPED URL for every selected row. Today `BILL_OF_LADING` and `BILL_OF_LADING_CHUNK` have exactly one producer, `ORDER_BATCH_SHIPPED`; I checked with `git grep aggregateType(` across `src/main`.
- **Failure scenario:** A future BOL-aggregate notice (for example, loaded-to-truck keyed on the BOL) would be counted in the status N math. `confirmed` could then go negative, because N comes from the key or is 1. Worse, a requeue would re-point that notice at the shipped endpoint.
- **Fix:** Add `AND o.process_type = 'ORDER_BATCH_SHIPPED'` to `findBolNotificationRows` (the index still serves the aggregate predicate) and the same predicate to `requeueBolTerminal`'s WHERE.

### [LOW] L3: the link-failure counter tag key breaks the class's own convention
- **File:** `OutboxDispatchService.java`, `linkServiceLog` (`"process_type"`) vs `:77` `TAG_PROCESS_TYPE = "processType"` (used by `wms2.outbox.message_log.failed`)
- **Confidence:** HIGH
- **Issue:** Two failure counters from the same method family carry differently spelled tag keys, so a dashboard filter on one misses the other. The plan wrote `{process_type}`, but the class idiom is `processType`. This is the code following the plan against the surrounding code.
- **Fix:** Use `TAG_PROCESS_TYPE`, and amend the plan and the observability docs to match.

### [LOW] L4: link failure is logged without its stack trace
- **File:** `OutboxDispatchService.java`, `linkServiceLog` catch block
- **Confidence:** HIGH
- **Issue:** It logs only `e.getMessage()`. The sibling `writeServiceLog` catch passes the exception. A missing-column failure on a tenant where V2.2.40 failed is exactly the case that needs the SQLState.
- **Fix:** Pass `e` as the last argument at WARN, or log the message at WARN and the stack at DEBUG.

### [LOW] L5: the legacy label uses the current K, not the K in force at close
- **File:** `BolOmsNotificationService.java:263-284` (`legacyParcels`)
- **Confidence:** MEDIUM
- **Failure scenario:**
  - A post-deploy 50-parcel BOL is closed at K=60, so it is one row. An admin lowers K to 40 while that row is PENDING or FAILED. The screen now says "1 legacy notification (50 parcels)" for a row that is not legacy.
  - An invalid K sysprop also WARNs on every status read, which is noisy.
- **Fix:** Accept and document it, or use the fixed historical threshold for legacy, for example `> CHUNK_SIZE_CEILING`, or compare against the row's `created_at` versus the deploy.

### [LOW] L6: the requeue reads every payload it never uses
- **File:** `BolOmsNotificationService.java:167`
- **Confidence:** HIGH
- **Issue:** The requeue calls `findBolNotificationRows`, which projects `singleRowPayload`. For a legacy row that is up to ~664 KB read for nothing.
- **Fix:** Add a slim variant without the payload column, or accept the cost (requeues are rare).

### [LOW] L7: the requeue counter increments before commit
- **File:** `BolOmsNotificationService.java:214`
- **Confidence:** HIGH (the executor also noted it)
- **Issue:** A commit failure after the increment over-counts by one, which breaks the plan's "+1 per successful call".
- **Fix:** Increment in `TransactionSynchronization.afterCommit`, or document the window.

### [LOW] L8: `existsTopLevelPallet` lacks the per-method `@RestResource(exported = false)`
- **File:** `BillofladingPositionRepository.java:214`
- **Confidence:** HIGH
- **Issue:** This is not exploitable. The repository is `exported = false` at type level and SDR detection is ANNOTATED (`RestConfiguration:913`). The neighbouring custom queries (`:190`, `:202`) carry the method annotation anyway.
- **Fix:** Add it, for consistency and so it stays unexported if the type-level flag is ever reverted.

### [LOW] L9: the status DTO's wire shape differs between the unit lane and production
- **Files:** `BolOmsNotificationStatusDto`; `WebConfigurer:74-83` (`NON_NULL`)
- **Confidence:** HIGH
- **Issue:** In production `noRecordReason`, `chunkCount`, `legacyParcels` and `chunkIndex` are **omitted** when null. The unit lane's response (standaloneSetup) prints them as `null`. A UI that tests `=== null` breaks.
- **Fix:** Note this for the UI lane. Optionally add a full-context assertion of the absent keys.

### [LOW] L10: plan text drifts from what shipped and from PRD
- **File:** plan §0/§4/§5/§6/§7, "V2.2.39" throughout; Prereq 1 "PRD is at V2.2.37"
- **Confidence:** HIGH
- **Issue:**
  - The migration shipped as **V2.2.40**.
  - All 4 PRD DBs are at **2.2.38**, queried today.
  - The K resolver lives in the chunker, while §6 places it in BOLS.
  - The 409 "precedents" (`StockUnitController:421`, `mobile/PickingController:76`) return 200 with an errors map, not a 409.
- **Fix:** Update the plan in the docs pass.

### [LOW] L11: the K resolver is duplicated, not shared
- **Files:** `BolShippedNotificationChunker.resolveChunkSize` vs `CustomerorderBatchService.resolveClubLineOmsChunkSize`
- **Confidence:** LOW (a judgment call)
- **Issue:** Same discipline, two copies. Acceptable, since the plan says "exactly the club resolver's shape".
- **Fix:** Optional: extract a shared `resolveClampedPositiveInt(raw, default, ceiling, key, log)`.

## Open Questions (low-confidence findings; surfaced, not blocking)

### [HIGH?] Q1: does a real PG `55P03` surface as `PessimisticLockingFailureException`?
- **Where:** `BillOfLadingController.requeueOmsNotification`
- **Confidence:** LOW
- **Issue:** U14 mocks the service to throw `CannotAcquireLockException`. No test drives a real lock timeout through the `@Modifying` native `requeueBolTerminal` repository proxy. If Hibernate wraps it as `GenericJDBCException`/`JpaSystemException`, it is a 500. The plan's own I7 note says the 3 s path is never exercised. Mitigation in the code today: `RestExceptionHandler` also maps `PessimisticLockingFailureException` to 409, so a failed translation is the only risk.
- **Probe:** A short IT. Hold `SELECT … FOR UPDATE` on a FAILED_TERMINAL row from a second connection, call `requeue`, and assert a `PessimisticLockingFailureException` subtype.

### [MEDIUM?] Q2: the plan Step 3 PRD `EXPLAIN ANALYZE` of the `resendConfirmed` subquery has not run
- **Confidence:** LOW
- **Issue:** The executor deferred it. The column does not exist on PRD yet, but a representative variant can run: `EXISTS (SELECT 1 FROM message r WHERE r.id > :someRecentMessageId AND r.redeliver_id = :id AND r.statuscodeanswer ~ '^2')` on c1wh and WineCo. This is a release prerequisite, not a code defect.

### [LOW?] Q3: EMPTY_BOL is read at status time, not at close time
- **Where:** `BolOmsNotificationService.noRecordReason`
- **Confidence:** LOW
- **Issue:** A path that deletes `billoflading_position` rows of a CLOSED BOL after close would make a BOL whose rows were purged read EMPTY_BOL instead of PURGED/UNKNOWN. SBDEV-3487's NOT_CLOSED predicate suggests CLOSED rows are protected. I did not sweep every delete path.

## Focus-item checklist (verified unless noted)

| Item | Result |
|---|---|
| Chunker: K boundary | `> k` triggers. The cut is lazy, so exactly K gives 1 chunk and K+1 gives 2. M6 killed by U4 `closeBol_exactlyK_staysOneRow`. |
| Parcel straddling a pallet | A new slice of the same pallet (same label) opens after each cut. A new pallet's first parcel at a full chunk cuts first, so no empty slice is left behind. |
| Empty pallets | Ride in the open chunk; trailing ones join the last chunk. An all-empty BOL has parcelCount 0 ≤ K and is never split. |
| `n > 99_999` | `bodies.size() >= SPAN` throws `FacadeException` (rolls back the close) = plan's "throws if n > 99_999". Key ≤ 45 chars. |
| ≤K payload byte-identical | The ≤K path serializes the untouched `dto`. The new Integer fields are null, and `WmsObjectMapper.shared()` (NON_NULL) omits them; field order is unchanged. Pinned by the U4 fixture. |
| Serialize-all-before-enqueue, rollback | Every payload is serialized before the first `enqueue`. `IOException` throws `FacadeException` inside `closeBOL`'s `rollbackFor=Exception`. |
| `serialize_failed` once per BOL | Yes: the loop exits on the first throw; the tags are never null. |
| `maxAttemptsFor` on both branches | `isTerminal` (HTTP branch) and the exception branch. 400/404/422 still terminal. |
| Link in its own try/catch | Yes, in all four call sites; it cannot propagate to `dispatchOne`'s catch. Restricted to ORDER_BATCH_SHIPPED. Null id → no-op. |
| `writeServiceLog` returns the id | Returns the saved id, or null on any failure path. |
| Status math, precedence | `confirmed = N − pending − failed`. FAILED › PENDING › CONFIRMED. NOT_SHIPPED unless CLOSED/TRANSFER. The TRANSFER state is reached only through `runShippingPhase`, so it has emitted. |
| NO_RECORD reasons | EMPTY_BOL → PURGED (`shipped < today − (ret+1)`) → UNKNOWN. The boundary day is UNKNOWN. Retention comes from the shared `safeOutboxRetentionDays`. `shipped` and `today` both come from `timezoneService.todayInWarehouse()` (`BOLS:842`). |
| EMPTY_BOL predicate vs `BOLS:548-560` | Same source rows (`billoflading_id`), same child test (`carrier_id ∈ this BOL's ids`), same garbage shape. `NOT IN` is null-safe because `c.id` is a non-null PK. Pinned by IT `emptyBolPredicate_…` (5 shapes). |
| `resendConfirmed` subquery | FAILED_TERMINAL only. `r.id > last_message_id`, `redeliver_id = last_message_id`, `~ '^2'`. A null `last_message_id` gives false. IT I5 is green. |
| Requeue UPDATE … RETURNING | Guard `status='FAILED_TERMINAL'`. 0 rows → NONE, no audit row, no counter (U13 + I4b + I7, all green). The empty `IN ()` is guarded by `eligible.isEmpty()`. The blank URL is refused with a one-arg `BusinessException`. |
| Audit row | destination `N/A`, code `REQUEUE`, sender `wms:requeue`, process `ORDER_BATCH_SHIPPED_REQUEUE`, answer serialized by Jackson from a map. I4 and I11 are green, I11 with a positive control. |
| `createServiceLogInCallerTx` | MANDATORY, `tenantTransactionManager`, called from another bean. I10 covers the rollback and the no-tx cases. |
| 409 outside the service tx | The catch is in the controller, around the proxied `requeue`. Its shape matches `RestExceptionHandler:384-390` (title, detail, `retryable`, which nests at `$.properties.retryable` in production, per memory). |
| Counter tags | Never null (L3 covers the key spelling). |
| `@Transactional` | `status` readOnly; `requeue` read-write with `rollbackFor=BusinessException`; `linkServiceLog` REQUIRES_NEW; `createServiceLogInCallerTx` MANDATORY. All name `tenantTransactionManager`. No self-invocation; `SelfInvokedTransactionalArchTest` is green. |
| `last_message_id` native-only | No entity field (U15). Read and written only in native SQL. |
| `lock_timeout` interplay | The link UPDATE and the requeue run under the 3 s tenant timeout. The requeue locks only FAILED_TERMINAL rows, which the dispatcher never claims. The link does not touch `version` or `modified_at` (I8). |
| Migration | `SET LOCAL lock_timeout='5s'` is in scope under the production migrator. `ADD COLUMN IF NOT EXISTS` is nullable with no default, so it is metadata-only. The seed matches `V2.2.29:37-50`, guarded by `(syskey, workstation='DEFAULT')`. Safe on all 4 PRD DBs: the app role owns both tables, and neither the column nor the seed exists yet. Residual risk: a lock wait behind a long close tx fails the migration on that tenant, and the boot stays green. The plan's Step 6 gate and P-5 cover this. |
| Test traps | `never(any())` on primitives: none (`anyInt` used correctly). Wrong-typed reference matchers: **H1**. Varargs captors: none. ITs clean up by id and are NOT_SUPPORTED. The I7 fixture uses one tenant DB with 2 connections. |

## Design disputes (separate from code)

None blocking.
- L2 asks for a defensive predicate the plan did not specify.
- L3 notes that the plan's metric tag spelling contradicts the class idiom.
- L5 questions whether the "legacy" detection should key on the current K.

## Positive observations

- The guarded `UPDATE … RETURNING` gives natural idempotency without `FOR UPDATE`. The 0-rows branch is pinned deterministically (U13, I4b) rather than relying on the latch IT.
- The link is isolated in its own try/catch, with a comment that explains why it must stay that way, and the 2xx-branch failure is mutation-tested (M10).
- The chunker is pure, copies its slices rather than taking `subList` views, and a surviving mutant (M3) led to removing dead code.
- The executor's mutation table is unusually complete; every ★ target in plan §8 has a recorded red.
- The I11 positive control runs inside a rolled-back transaction, so the shared watchdog fixture stays clean.
- `requeue` gained `rollbackFor = BusinessException.class`, so a checked exception from the audit write cannot commit the flip without its audit row. This is a real catch beyond the plan.

## Recommendation

**REQUEST CHANGES.** H1 (arch test red, build fails) is HIGH at HIGH confidence. After the fix, run and record the full suite (M1). Every other finding is Low; fix them in the same pass per the repo's "fix Low too" rule.

---

## Round 2 (scoped, head 1866ab66)

Scope: `fb89bd31..1866ab66` (c8782d2a, 1866ab66; 10 files). The review worktree was moved with `checkout --detach 1866ab66`. Mutants were run on a scratchpad copy and the file restored afterwards; `git status` is clean.

### Evidence

| Instrument | Result |
|---|---|
| Unit classes, the same 11 as round 1 + `TestClassTransactionManagerArchTest` | **286 run, 0 failures.** `NeverMatcherNullBlindnessArchTest` is green (10/10). `TestClassTransactionManagerArchTest` is green (6/6). |
| Failsafe: `BolOmsNotificationRowsIT` (12 tests, including the 2 new ones), `MessageServiceCallerTxIT`, `OutboxMigrationV2240IT`, `BolChunkOutboxClaimIT`, `OmsEgressWatchdogQueryIT` | 49 run, 0 failures |
| `requeueBlockedPastLockTimeout_is409AtTheController`, ×3 (once inside the class run, twice alone) | 3/3 green |
| `EXPLAIN` on c1wh-shipitez PRD, run on the row-set WHERE including the new `process_type` predicate | Plan is unchanged: `BitmapOr` of two `Bitmap Index Scan on index_outbox_message_aggregate_order`. `process_type` is applied as a heap `Filter` on the few rows recovered. |
| PRD `outbox_message.last_error`, max length (c1wh: 6 rows, WineCo: 8 rows) | 101 characters on both |

### Verdict per round-1 finding

| # | Verdict | Note |
|---|---|---|
| H1 | **Fixed** | Bare `any()` at the three reference-typed sites; inventory `OutboxDispatchServiceUnitTest:8` with the signature-read comment. The arch test is green. |
| M1 | **Fixed (not re-verified by me)** | The fixer says a suite of record was run on the final head. That is the lead's lane; I re-ran only the scoped classes. |
| L1 | **Fixed** | Pure move: a sorted-line diff of `BillofladingService` between the two heads is empty. `enqueueBolShippedNotification` now sits at `:837`, after `runShippingPhase` (`:444`). |
| L2 | **Fixed** | The fence is in both reads (one shared `BOL_ROWS_FROM_WHERE`) and in the UPDATE. The new IT `otherProcessTypeOnSameAggregate_isNeitherReadNorFlipped` covers it, and the fixer's R7/R8 mutants were killed. The index plan is unchanged (see Evidence). |
| L3 | **Accepted (lead decision); the comment is accurate** | `"process_type"` is in fact the majority spelling in `src/main` (14 sites, `serialize_failed` among them); `processType` appears only in this class's `TAG_PROCESS_TYPE` meters. Nit: the parenthetical "(plan §8 O2)" sits after `serialize_failed`, but O2 specifies *this* counter (`service_log_link.failed{process_type}`). Move it one clause earlier. |
| L4 | **Fixed** | The exception is now the last WARN argument. |
| L5 | **Fixed** | Legacy is now keyed on `CHUNK_SIZE_CEILING` (60). The test covers 61 → legacy, 60 → not, and 50 at K=40 → not. The status read no longer touches the K sysprop. |
| L6 | **Fixed** | `findBolNotificationRowsForRequeue` uses `CAST(NULL AS text)` for the payload. The shared fragments keep the two reads identical otherwise. |
| L7 | **Fixed in code; one test went vacuous** | See R2-1 below. |
| L8 | **Fixed** | |
| L9 | **Handed to the UI lane** (as asked). The new `omsNotificationStatus_wireFieldNames` pins all 11 + 8 names. | |
| L10 | **Open (docs)**; the lead fixed the V2.2.39 → .40 references. | |
| L11 | **Declined, accepted.** Out of scope; I marked it optional. | |
| Q1 | **Answered: yes.** A real 55P03 reaches the controller as `PessimisticLockingFailureException`. Fixer's R9: with the catch removed, the IT errors with exactly that type. | |
| Q2 | **Answered** by the lead: c1wh 3.5 ms, WineCo 13.6 ms. | |
| Q3 | Open, unchanged | |

### Lead's specific checks

- **`process_type` filter:** the index is still used, and the plan shape is unchanged (EXPLAIN above). The UPDATE's fence is independent of the caller's ids (IT).
- **After-commit telemetry:**
  - It does **not** fire on rollback. The mutant MA (moving the work to `afterCompletion`, which also runs on rollback) is **killed** by `rolledBackRequeue_isNotCounted:567`.
  - It is **skipped on NONE** in the code: both NONE returns precede the registration.
  - O1/O3 still mean something for the success path: "nothing before commit", then +1 and the `rows=` line after `commit()`.
  - **But see R2-1:** the NONE-path "no counter" asserts became vacuous.
- **`lastError` redaction:**
  - Covers `http`, `https`, any scheme, userinfo, port and query string, and runs **before** the 300-character abbreviation (pinned by the 400-character case).
  - Two defects: **R2-2** (quadratic time) and **R2-3** (bare hostnames leak).
- **`TestClassTransactionManagerArchTest` exemption:** honest about *why* NOT_SUPPORTED is needed: own tenant transactions, committed reads across two threads and across a second JDBC session. One overclaim, **R2-4**.
- **Lock-timeout IT:**
  - **Deterministic:** the holder's `SELECT … FOR UPDATE` completes before the request is submitted, so the UPDATE must block. The holder is waiting on nothing, so there is no deadlock.
  - **Released:** `holder.rollback()` sits in `finally`, inside try-with-resources (close), and `pool.shutdownNow()` is in the outer `finally`.
  - **Safe on the PG lane:** it uses one extra raw `DriverManager` connection outside any pool, and the request uses one app connection.
  - It costs about 10 s of `lock_timeout` per run. 3/3 green.

### New findings (round 2)

#### [LOW] R2-1: the NONE-path "no counter" assertions are now vacuous
- **File:** `BolOmsNotificationServiceUnitTest`: `concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter` and `requeue_inFlightOnly_returnsNoneWithReason`
- **Confidence:** HIGH (mutant MC survived)
- **Issue:** Since L7, the counter can only move inside `afterCommit`. These two tests never call `commit()`, so a regression that registers the telemetry on the 0-rows NONE path stays green. That is the plan's mutation target "audit row written when the UPDATE returned 0 ids" extended to the counter.
- **Mutant MC:** a registration added inside `if (requeued.isEmpty())` survived; `BolOmsNotificationServiceUnitTest` stayed 24/24 green. I7 cannot back this up: its loser usually takes the read-sees-nothing path (plan §8 says so).
- **Fix:** Call `commit()` in both tests before asserting that `wms2.outbox.requeued` is empty and no `requeue ` log line exists. Alternatively, assert `TransactionSynchronizationManager.getSynchronizations()` is empty after a NONE.

#### [LOW] R2-2: the redaction regex is quadratic in long runs of scheme characters
- **File:** `BolOmsNotificationService.java`, the `URL` pattern
- **Confidence:** HIGH on the mechanism; LOW on reachability
- **Issue:** `[A-Za-z][A-Za-z0-9+.-]*://` has no left anchor. At every start position inside a long run of `[A-Za-z0-9+.-]` that has no `://`, the greedy scheme quantifier scans to the end of the run, so `find()` costs O(n²).
- **Measured** (JDK, `"HTTP 500: " + "a".repeat(n)`): 10k chars → 0.59 s, 50k → 15.8 s, 100k → 62 s.
- **Why it matters:** `last_error` is `text` and holds `"HTTP <code>: " + <OMS answer body>`, unbounded. The redaction runs inside `status()`'s read-only transaction, so it holds a tenant connection for the whole scan, on every page refresh, per failed chunk.
- **Reachability is low today:** PRD max `last_error` is 101 characters. OMS is internal, and HTML or JSON bodies break such runs with spaces, quotes or colons.
- **Fix:**
  - Bound and anchor the scheme: `(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]{0,31}://[^\s"']+`. Measured at 11 ms for 100k and 27 ms for 1M.
  - Mutant MD swapped this in and `BolOmsNotificationServiceUnitTest` stayed green (24/24), so it is a drop-in.
  - Optionally also cap the input first, e.g. `StringUtils.left(lastError, 4096)`, then redact, then abbreviate.

#### [LOW] R2-3: bare hostnames survive the redaction
- **File:** same method
- **Confidence:** MEDIUM
- **Issue:** `HttpRestService` uses `RestClient` over `SimpleClientHttpRequestFactory`, and its transport errors read `I/O error on POST request for "<url>": <cause message>`. The URL is redacted. The cause message is not, and it can name the host without a scheme:
  - `UnknownHostException` → `api-oms.example`;
  - TLS errors → `No subject alternative DNS name matching api-oms.example found`.
- **Verified:** `I/O error on POST request for "<oms-url>": api-oms.example`.
- **Severity:** low, because the secret material (userinfo, query) lives in the URL and is redacted; a hostname is not a credential.
- **Fix:** Also replace the host parsed from the current shipped-URL sysprop, as a literal, or document "URLs only" in the javadoc, which today promises the endpoint is hidden.

#### [LOW] R2-4: the exemption reason overclaims what `cleanUp()` deletes
- **File:** `TestClassTransactionManagerArchTest.java`, the `BolOmsNotificationRowsIT` entry
- **Confidence:** HIGH
- **Issue:** The entry says "every row it writes is recorded by id … and deleted in cleanUp()". In fact:
  - `setUp()` find-or-creates the `sbdev3672-requeue-operator` `User` row, which is never deleted. It is idempotent by name, so this is harmless.
  - The `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop is *updated and restored*, not inserted and deleted.
- **Fix:** Reword to "…deleted in cleanUp(), except the find-or-create operator user, which is reused across runs; the shipped-URL sysprop is restored".

#### [LOW] R2-5: a test's DisplayName overclaims
- **File:** `rolledBackRequeue_isNotCounted`
- **Confidence:** HIGH
- **Issue:** The DisplayName says "neither counted nor logged", but the test asserts only the counter.
- **Fix:** Add a `ListAppender` assertion that no `requeue ` line exists after the rollback, or trim the name.

### Round 2 recommendation

**APPROVE.** Nothing High or Medium remains. H1 and every in-scope Low from round 1 are fixed, and both arch rails, the 286 unit tests and the 49 ITs are green on 1866ab66. Per the repo's "fix Lows too" rule, fix R2-1 to R2-5 in the same pass; R2-1 and R2-2 are each a few lines.

### Round 2 addendum: the `legacy` threshold (ceiling vs K), requested by the lead after the docs lane flagged it

**Where:** `BolOmsNotificationService.legacyParcels` (`:290-302`). It returns `parcels > BolShippedNotificationChunker.CHUNK_SIZE_CEILING` (60, `BolShippedNotificationChunker.java:46`) for a single non-SENT `BILL_OF_LADING` row of a REGULAR or HUB_AND_SPOKE BOL. The javadoc at `:283-289` already explains why. This was the fix for my own round-1 L5. Plan §5 Fix B-3, "Legacy row (A-L6)" (`plan:177`), still says "parcels > K".

**Verdict: an acceptable deviation, not a code defect.** It needs a plan amendment of A-L6 and the §6/docs text, not a code change. The code comment already exists. Reasoning:

1. **What `legacy` has to mean.** The label is an operator hint: "this row is requeued whole and **cannot fit one OMS call**, so use the §7 manual recipe". Whether a row fits is a property of OMS cost (~0.19 s per parcel, analysis §6) against the 15 s read timeout. It is not a property of the K knob. `CHUNK_SIZE_CEILING` is exactly that boundary: 60 × 0.19 ≈ 11.4 s, the last size that fits with margin. K is an operator choice at or below it. Keying the label on the ceiling asks the right question.

2. **Under-labelling at K=20, 21–60 parcels.**
   - **Is such a row oversized for OMS?** By the model the plan uses for both chunking and the clamp, no: it fits one call. The evidence agrees. Analysis §8 shows 281–329-parcel rows timing out once and then succeeding, and nothing at or below 60 failing.
   - **If an admin lowered K to 20 because OMS got slower** (per-parcel cost up), a 21–60 row could time out and would go unlabelled. In that world the 60 ceiling is wrong for the chunker's clamp too. That is a coupled-constant risk to fix at the constant, not in the label.
   - **What under-labelling costs:** the UI shows "0/1 · 1 failed" instead of "1 legacy notification (N parcels)". Requeue behaves identically either way (the UI never blocks it, plan:218), and a failed requeue is visible as failed. No data path depends on the flag.
   - **Who is exposed:** pre-deploy single rows with 21–60 parcels still non-SENT. My round-1 PRD probe found BOL rows in FAILED_RETRY or FAILED_TERMINAL only on c1wh (one row, outbox 11135, 1,528 parcels, labelled correctly by either rule). The other three PRD DBs had none. A transient PENDING row at deploy retries under the new 29-attempt budget. The exposed population is **zero today and can only shrink**: no row created after deploy is a single row above K.

3. **What K-based labelling would cost (the upside of the ceiling):**
   - **It would mislabel post-deploy rows**, a population that grows rather than shrinks. A 40-parcel BOL closed at K=40 is one legitimate row. If an admin later lowers K to 20, every such row still non-SENT flips to "legacy (40 parcels)", and the runbook would send operators to a manual sliced replay for a row that fits one call.
   - **It would flap** with every K edit.
   - **It would put the K sysprop read, and its WARN on a bad value, back on every status read.**
   - "Read K once" does not help. The status read cannot know the K **in force at close**, which is the only K that would make "parcels > K" mean "should have been chunked".

4. **A false negative is the safer error here.** A false "legacy" sends operators to a manual replay. That is exposed work: it needs the OMS credential, and per the R-1 gate each call can fire a merchant callback. A missing label leaves the ordinary requeue, which OMS treats idempotently (it NOOPs parcels it has already shipped).

**What to do:**
- Amend plan §5 Fix B-3 A-L6 to read "parcels > `CHUNK_SIZE_CEILING` (60): the most one OMS call can carry, independent of K".
- Make the same edit in the BOL truck-loading workflow doc's status section, and add a sentence to R-6/§7: "the label does not track K; if OMS cost per parcel rises, revisit `CHUNK_SIZE_CEILING`, which governs both the clamp and the label".
- No code change. The javadoc at `BolOmsNotificationService:283-289` is accurate and already states the "not today's K" rationale. `legacyOversizedRow_isLabelledLegacy` pins 61 → legacy, 60 → not, and 50 at K=40 → not.

---

## Round 3 (scoped, head 057d0e3b)

Scope: `1866ab66..057d0e3b` (0f54c0bf, 057d0e3b; 5 files). The review worktree was moved with `checkout --detach 057d0e3b`. Mutants were run on a scratchpad copy and the file restored afterwards; `git status` is clean.

### Evidence

| Instrument | Result |
|---|---|
| `BolOmsNotificationServiceUnitTest`, `OutboxDispatchServiceUnitTest`, `TestClassTransactionManagerArchTest`, `NeverMatcherNullBlindnessArchTest` | **288 run, 0 failures** |
| Mutant MC (round-2 survivor: the telemetry also registered on the 0-rows NONE path) | **Killed**: `concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter:478` |
| Mutant MQ (the old unanchored quadratic URL pattern restored) | **Killed**: `lastError_redactionIsLinear:609`, "execution timed out after 1000 ms" |
| Mutant MB (host guard `isNotBlank(omsHost)` → `omsHost != null`) | **Survived.** See R3-1. |
| Linearity | The new `URL` pattern is byte-identical to the one I measured in round 2: 11 ms for 100k characters, 27 ms for 1M, against 62 s for 100k with the old pattern. The host pass is a `Pattern.quote` literal, so it is linear too. |

### Verdicts on round 2

| # | Verdict | Note |
|---|---|---|
| R2-1 | **FIXED** | Both NONE tests now play `commit()` before asserting no counter and no `requeue ` line. MC is killed. |
| R2-2 | **FIXED** | Lookbehind plus a `{0,31}` scheme, with the rationale in the javadoc. MQ is killed by the timing test. |
| R2-3 | **FIXED** | The host comes from the current shipped-URL sysprop and is replaced case-insensitively after the URL pass, before the abbreviation. The limitation (a host from an earlier endpoint is not caught) is stated in the javadoc. The new test covers the unknown-host and TLS (`OMS.TEST`) shapes. |
| R2-4 | **FIXED** | The exemption now names both exceptions: the kept operator user and the restored sysprop. |
| R2-5 | **FIXED** | `rolledBackRequeue_isNotCounted` now asserts there is no `requeue ` log line either. |
| L3 comment | **FIXED** | "(plan §8 O2)" now attaches to this counter's `"process_type"`. |

### Lead's checks on the redaction

- **Linear:** yes (see Evidence).
- **Coverage:**
  - Any `scheme://`, including `http`/`https`, userinfo, port and query string, up to whitespace or a quote.
  - Bare host from an unknown-host or TLS error: yes, for the **currently configured** host.
  - Not covered: a host that names a different endpoint configured earlier (documented), and an IP address in a cause message. `SimpleClientHttpRequestFactory`'s `ConnectException`/`SocketTimeoutException` messages carry no IP, so this is acceptable.
- **Over-redaction:**
  - The status code (`HTTP 500`) and `Read timed out` survive; both are pinned by the tests.
  - Cosmetic only: `[^\s"']+` also swallows trailing non-space punctuation glued to a URL (e.g. `http://h/x</pre>` or `…/x),` becomes `<oms-url>`). Nit; no fix needed.
  - The host pass is a substring match, so a configured host that is a substring of other words would over-redact them. Real hosts are FQDNs, so this is negligible.
- **Timing test flakiness:**
  - Low risk. The bound is 1 s and the fixed pattern takes about 11 ms (around 90× headroom, even allowing a cold JIT). The quadratic version needs 62 s, so the test discriminates by 60×.
  - `assertTimeoutPreemptively` runs the body on another thread. That is fine here: `status()` uses no transaction synchronization or security context, and the Mockito stubs are shared.
  - If CI ever flakes, raising the bound to 5 s keeps it a killer.
- **Blank sysprop:**
  - Safe in the code: `omsHost()` returns `""` for null, blank, an unparseable value (`IllegalArgumentException` caught) or a URL without a host, and `isNotBlank` skips the host pass.
  - **Untested**, though. See R3-1.

### Watchdog README (`scripts/oms-egress-watchdog/README.md`) vs `egress-failures.sql`

- **Accurate:**
  - `'N/A'` is the inbound exclusion at `egress-failures.sql:91` (rationale at `:31-33`).
  - The key format `<tenant>/<warehouse> failing message:<process>` matches `run.sh:34`'s whole-key rule, `test-run.sh:90`, and README `:82-83`.
  - The I11 pin is named correctly.
  - The 29 attempts / ~24 h figures match the code.
- Inaccurate or incomplete: R3-2.

### New findings (round 3)

#### [LOW] R3-1: the blank or unset shipped-URL path of the host redaction is untested, and its guard is load-bearing
- **File:** `BolOmsNotificationService.redactedLastError` / `omsHost()`; `BolOmsNotificationServiceUnitTest`
- **Confidence:** HIGH (mutant MB survived)
- **Issue:** Every test stubs a real `SHIPPED_URL`. If the `isNotBlank` guard regressed to `!= null`, then `Pattern.quote("")` would match the empty string at every position, and `replaceAll` would put `<oms-host>` between every character of every `lastError`. MB shows no test would notice.
- **Fix:** Add one test that stubs the sysprop as `null`, `""` and `"not a url"`, and asserts that `lastError` comes back with only its URL redacted (e.g. `"HTTP 504: gateway"` unchanged).

#### [LOW] R3-2: the README's "keep `failing` red for a day" understates the effect and names only one of the two keys
- **File:** `scripts/oms-egress-watchdog/README.md`, the "A poisoned BOL-shipped row" bullet
- **Confidence:** HIGH (read against `egress-failures.sql:6-30`, `:84-132`)
- **Issue 1, duration:** `failing` means the most recent N attempts of a (path, process) inside the lookback window all failed. A poisoned row writes about 30 FAILED `message` rows over 24 h, so the streak starts at its first failed attempt and **clears only when N newer `ORDER_BATCH_SHIPPED` sends succeed** (or those rows leave the lookback). On a low-traffic tenant that can be longer than a day.
- **Issue 2, second key:** with chunking, one BOL during an OMS outage parks up to N chunk rows in FAILED_RETRY, and each counts as an attempt on the `outbox` path. So `<tenant>/<warehouse> failing outbox:ORDER_BATCH_SHIPPED` goes red too. The README's single-key ack example would leave that one red.
- **Fix:** Reword to "…can keep `failing` red until N later BOL-shipped sends succeed (possibly more than a day on a low-traffic tenant)". Add that an ack may need both keys: `message:ORDER_BATCH_SHIPPED` and `outbox:ORDER_BATCH_SHIPPED`, joined with `|`.

#### [nit] R3-3: the host `Pattern` is compiled once per failed chunk
- **Issue:** `Pattern.compile(Pattern.quote(omsHost), CASE_INSENSITIVE)` runs inside `redactedLastError`, so a 39-chunk failure compiles it 39 times. The cost is negligible.
- **Fix (optional):** Compile it once alongside `omsHost` in `status()` and pass the `Pattern` in.

### Round 3 recommendation

**APPROVE.** Every round-2 finding and the L3 comment reference are FIXED. The redaction is linear, and the timing test kills the quadratic pattern. Fix R3-1 (one test) and R3-2 (two README sentences) in the same pass, per the repo's "fix Lows too" rule; R3-3 is optional.

---

## Round 4 (scoped, head ad8ff63e)

Scope: `057d0e3b..ad8ff63e` (README, `BolOmsNotificationService`, `BolOmsNotificationServiceUnitTest`). The review worktree was moved with `checkout --detach ad8ff63e`. The mutant was run on a scratchpad copy and the file restored afterwards; `git status` is clean.

### Evidence

- **`BolOmsNotificationServiceUnitTest`:** 27 run, 0 failures.
- **Mutant MB4, re-running the `isNotBlank` mutant:**
  - The guard moved into `omsHostPattern()`, so I applied the equivalent mutation there: drop the `isBlank → NO_HOST` branch and compile `Pattern.quote(host == null ? "" : host)`. That is the empty-string pattern R3-1 warned about.
  - **Killed** by `lastError_withoutAConfiguredHost_isNotInterleaved:615` on the first input, `[sysprop <null>]`.

### Verdicts

| # | Verdict | Note |
|---|---|---|
| R3-1 | **FIXED** | The new test covers `null`, `""`, `"   "`, `"not a url"`, `"http://[bad"` and `"/relative/path"`. Each asserts the error text passes through with only its URL redacted and no `<oms-host>`. The guard is now structural: `omsHostPattern()` never returns an empty-string pattern, and the javadoc says why. |
| R3-2 | **FIXED** | The README now says the red lasts until N later sends succeed (or the failures leave the lookback), possibly more than a day. It names the `outbox` path, and its ack example covers both keys. |
| R3-3 | **FIXED** | The host `Pattern` is compiled at most once per `status()` call (lazily, on the first failed row). |

### Lead's questions

- **Behaviour when the sysprop changes between reads:** unchanged. The `Pattern` is a local variable of `status()`, built on the first failed row of **this** read from the sysprop value at that moment. Nothing is cached across reads. The next read picks up a new URL, subject only to the existing `sysprops` cache, which an admin edit evicts, the same as before. Within one read every chunk uses one host, which is what you want.
- **Shared mutable state:**
  - None. `URL` and `NO_HOST` are `static final` compiled `Pattern`s; `Pattern` is immutable and thread-safe, and every use creates its own `Matcher`.
  - The per-read host `Pattern` never escapes the method, so there is no cross-thread or cross-tenant sharing. The sysprop it reads comes from the tenant-keyed cache, as before.
  - `NO_HOST` is `(?!)`, which can never match, and it is compared by identity, so a NO_HOST sentinel cannot leak into the replacement.
  - `redactedLastError` would NPE on a `null` `Pattern`, but its only caller (`:157`) always assigns one first.
- **README ack key spellings:** exact.
  - `run.sh` builds the key as `"$tenant/$warehouse $kind $path:$process"` and matches with `grep -qxE`, so the regex must cover the whole line.
  - The path literals are `'message'` (`egress-failures.sql:82`) and `'outbox'` (`:96`).
  - So `<tenant>/<warehouse> failing (message|outbox):ORDER_BATCH_SHIPPED` matches both findings as whole keys. "Copied from the summary line" holds: `run.sh` appends the failing keys to the summary, joined by `;`.

### Round 4 recommendation

**APPROVE.** R3-1, R3-2 and R3-3 are FIXED; no new findings. Across rounds 1–4, every finding of mine is fixed except three I accepted as not code changes: L10 (plan text, open for the docs pass), L11 (declined, optional) and Q3 (open question, no product path known). The `legacy`-threshold addendum is a docs amendment only.
