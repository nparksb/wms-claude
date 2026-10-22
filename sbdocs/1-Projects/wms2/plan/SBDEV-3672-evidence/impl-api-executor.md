---
ticket: SBDEV-3672
kind: impl-report
repo: v2/wms2-api
branch: fix/SBDEV-3672-chunk-bol-shipped
base: origin/develop 4ce87ead
head: ad8ff63e
date: 2026-10-16
---

# SBDEV-3672 — wms2-api implementation report (opus executor, no ralph)

Worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3672`. Nothing pushed, no PR, no ClickUp.

## Commits

| sha | subject |
|---|---|
| `1213d9be` | SBDEV-3672: chunk the BOL-shipped OMS notification above K parcels (Fix A) |
| `616a4b87` | SBDEV-3672: last_message_id link and a 24 h retry budget for BOL-shipped rows (Fix B-1, Fix C) |
| `fb89bd31` | SBDEV-3672: per-BOL OMS notification status, requeue and its audit row (Fix B-2..4, Fix D) |
| `c8782d2a` | SBDEV-3672: review fixes — arch rails, process_type fence, after-commit telemetry, redacted lastError |
| `1866ab66` | SBDEV-3672: review fixes — SBDEV-3672 controller tests in their own @Nested, tag-spelling note |
| `0f54c0bf` | SBDEV-3672: review round 2 — linear host-aware lastError redaction, non-vacuous NONE telemetry asserts, watchdog README |
| `057d0e3b` | SBDEV-3672: review round 2 — the linear URL pattern is the one redaction bound, pinned by the timing test |
| `ad8ff63e` | SBDEV-3672: review round 3 — no-host redaction pinned, host pattern compiled once, watchdog README ack keys |

On top of the gate commits `29648d54` (tests) and `f47fa759` (V2.2.39 → V2.2.40 rename).

Flyway: `git fetch` + `check-migration-version-collision.sh V2.2.40` on 2026-10-16 → **FREE on every remote**; `origin/develop` head is still `4ce87ead`, highest migration `V2.2.39__delete_retired_lane_exclusion_sysprop.sql`.

## Per-story gate tests, before → after

| Story | Gate test | Before (gate) | After |
|---|---|---|---|
| 1 | `BillofladingServiceUnitTest$Sbdev3672ChunkedBolShippedNotification` U5, U6 hub, U7, U8 ×3 | 6 red (U4 ×2, U6 transfer were pins, green) | 9/9 green |
| 1 | `BolShippedOmsChunkSizeSeedConsistencyTest#seedMatchesConstant` | red (file absent) | green |
| 1 | `BolShippedNotificationChunkerUnitTest#splitContractExists` | red (class absent) | green |
| 2 | `OutboxDispatchServiceUnitTest` U10 ×3 red, U11 ×2 red (+2 U10 pins, 1 vacuous U11 pin green) | 5 red | 47/47 green |
| 2 | `OutboxBolNotificationContractUnitTest` link ×2 | red | green (`bolRowSetQueryCoversBothShapesAndResend` is Fix B-2: stayed red through Story 2, green in Story 3) |
| 2 | `OutboxMessageMappingUnitTest` (U15 pin) | green | green (mutation now run, see below) |
| 2 | `OutboxMigrationV2240IT` ×2 | red | 2/2 green |
| 3 | `BolOmsNotificationServiceUnitTest` 3 contract tests | red | green |
| 3 | `MessageServiceUnitTest#createServiceLogInCallerTxIsMandatory` | red | green |
| 3 | `BillOfLadingControllerUnitTest` `omsNotificationStatus_isGatedGet`, `requeue_isPost` | red | green |
| 3 | `Sbdev3017TrancheGateContextTest` (full context, pin 231) | 1 red (2 routes NOT DEPLOYED) | 5/5 green, after `mvn -o clean compile` |
| — | `BolChunkOutboxClaimIT` I1/I2 (infrastructure pins) | green | green |

## Deferred tests written, and how each was seen red

U1–U3 were written against a stub chunker (`split` returned `List.of(dto)`) before the real one: 6 of 7 red (`Expected size: 3 but was: 1`, `Expected size: 39 but was: 1`, two `IndexOutOfBounds Index: 1 Size: 1` from the single-chunk stub); `splitContractExists` green against the stub. Every Story 2/3 deferred test was written with its production code in the same step, so its red was produced by **removing or breaking the production line it protects** (the lead's alternative); each such run is a row of the mutation table below.

| Test (file) | Plan id | Red evidence |
|---|---|---|
| `BolShippedNotificationChunkerUnitTest` `splitsEveryKParcels…`, `straddlingPallet…`, `neverEmitsEmptyPalletOnlyChunk`, `slicesAreCopiesNotViews`, `singlePalletOf1528Gives39Chunks`, `everyChunkCarriesFullHeader…` | U1–U3 | stub run above; plus M3′, M7, M8 |
| `BolOmsNotificationRowsIT#linkUpdateLeavesVersionAndModifiedAtUnchanged` | I8 | M13, M13b |
| `BolOmsNotificationServiceUnitTest` `confirmedCountsPurgedSentRows` / `resendConfirmedCountsAsConfirmed` / `failedBeatsPending` / `noRows_emptyBol_vs_purged_vs_unknown` / `purged_onlyBeyondRetentionPlusOneDay_boundaryIsUnknown` / `emptyBol_matchesRunShippingPhaseTopLevelClassification` / `openBol_isNotShipped` / `legacyOversizedRow_isLabelledLegacy` (+ extra `unknownBol_isNotFound`) | U12 | R, X5, Q, X1, K, (S1/S2 for the SQL), X2, X3 |
| same class `requeue_inFlightOnly…` / `resendConfirmedRows_areNotRequeued` / `legacyOversizedRow_isRequeuedWhole_notRechunked` / `transfer_isPlainRequeue` / `requeueUsesCurrentShippedUrl` / `concurrentLoser_zeroRowsReturned…` / `auditRow_namesReturnedIds` / `auditRow_destinationNA_codeREQUEUE_senderNotInstance` / `auditRow_isNotResendable` | U13 | X4, C, P, P, P, D, W, H, H |
| same class `requeueCounterIsPerCallAndInfoLineCarriesRows` | O1 (unit) + O3 | N, O |
| `BillOfLadingControllerUnitTest` `lockTimeout_maps409` / `nothingEligible_is200None` (+ extra `omsNotificationStatus_returnsStatus`) | U14 | I, X6 |
| `BolOmsNotificationRowsIT#findsBothShapesOnlyForThisBol` | I3 | T, U |
| `…#requeueFlipsOnlyTerminalRowsKeepsKeysAndWritesOneAuditRow` | I4, O1, O4 | G |
| `…#requeueUpdate_skipsRowsNoLongerTerminal` | I4b | B′ |
| `…#lastMessageIdLeftJoinReportsPurgedMessage` / `#resendWith2xxRedeliverIdReconciles` / `#resendWith5xxDoesNot` / `#resendOfEarlierAttemptIsNotReconciled` | I5 | U, J (5xx). The two reconcile-direction tests were not separately mutated (see "Not done") |
| `…#concurrentRequeue_oneRequeuesOtherReturnsNone` | I7, O1 | B′ (also red without the guard) |
| `…#emptyBolPredicate_matchesRunShippingPhaseClassification` (extra, see Interpretations 8) | — | S1, S2 |
| `MessageServiceCallerTxIT` `auditRowRollsBackWithCallerTx` / `withoutCallerTx_throwsIllegalTransactionState` (+ positive control `control_auditRowCommitsWithCallerTx`) | I10 | E′, F |
| `OmsEgressWatchdogQueryIT#requeueAuditRows_yieldZeroFindings` (with its URL-destination positive control in the same case) | I11, O4 | G (clean build) |

## Mutation table

Each mutation: file copied to the scratchpad, mutated, the named test run, file copied back, `git diff --stat` clean. Final `git status` clean.

| # | Target (plan §8 row marked ★) | Killing test | Red? (failure line) |
|---|---|---|---|
| M1 | ★ K clamp at 60 removed (Story 1, in BOLS) | U8 `chunkSize_above60_clampsTo60WithWarn` | yes — `:3966 [chunk size 100 must clamp to 60 …]` |
| A | ★ K clamp at 60 removed (re-run after the resolver moved into the chunker) | same | yes — `:3966` |
| M2 | ★ `chunk_*` set on the ≤K path | U4 `closeBol_atOrBelowK_payloadIsByteEqualToTodaysFixture` | yes — `:3773 [the <=K payload must stay byte-identical …]` |
| M3 | trailing empty pallets as their own chunk (`if (true)`) | — | **survived**: the branch was dead (the cut is lazy, so the last chunk always holds a parcel). Removed the dead branch instead; see M3′ |
| M3′ | eager cut (cut right after the K-th parcel) | U2 `neverEmitsEmptyPalletOnlyChunk` | yes — `:103 [80 parcels at K=40 -> exactly 2 chunks …]` |
| M4 | HUB_AND_SPOKE not chunkable | U6 `hubAndSpokeAboveK_isChunked` | yes — `:3838` |
| M5 | transfers chunkable | U6 `transferOffsiteAndIntracompanyAboveK_stayOneRow` | yes — `:3854` |
| M6 | `>= K` instead of `> K` | U4 boundary `closeBol_exactlyK_staysOneRow` | yes — `:3784` |
| M7 | one header field dropped from chunks | U3 | yes — `:162` |
| M8 | a chunk's pallet list is a `subList` view of the source | U1/U2 ×5 | yes — 5 failures incl. `slicesAreCopiesNotViews:124` |
| M9 | ★ `maxAttemptsFor` type check removed (every type gets 29) | U10 `otherProcessType_terminalAt5` (+2 pre-existing tests) | yes — `:783` |
| M9b | exception branch back on `maxAttempts` | U10 ×2 | yes — `:744 [… (exception branch (ODS:193)) …]` |
| M10 | ★ link outside its own try | U11 `linkFailureIn2xxBranch_neverCallsMarkRetryOrMarkTerminal` | yes — error `QueryTimeout simulated link failure` |
| M11 | link not restricted to ORDER_BATCH_SHIPPED | U11 `otherProcessTypes_notLinked` | yes — `:906` (that pin is no longer vacuous) |
| M12 | ★ entity field added: `@Transient Long lastMessageId` | U15 | yes — `:57 [C-H2: last_message_id is native-only …]` |
| M12b | entity field `@Column(name="last_message_id") Long linkedMessage` | U15 | yes — `:57` |
| M13 | link SQL also sets `modified_at = NOW()` | I8 | yes — `:63 [A-L2: … must not touch it]` |
| M13b | link SQL bumps `version` | I8 | yes — `:60 [A-L2: … must not bump @Version]` |
| B | ★ D-i UPDATE without `status='FAILED_TERMINAL'` | U13 `requeueUpdateTouchesOnlyFailedTerminalRows` | yes — `:124 [A-N4 …]` |
| B′ | same mutation | I4b `requeueUpdate_skipsRowsNoLongerTerminal` | yes — `:322 [the status='FAILED_TERMINAL' guard matches none of them]`; I7 also red (`:361`) |
| C | ★ resendConfirmed rows not excluded from the eligible ids | U13 `resendConfirmedRows_areNotRequeued` | yes — `:385` |
| D | ★ audit row written when the UPDATE returned 0 ids | U13 `concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter` | yes — `:437` |
| E | ★ MANDATORY → REQUIRES_NEW | U12 `createServiceLogInCallerTxIsMandatory` | yes — `:538` |
| E′ | same | I10 `auditRowRollsBackWithCallerTx` (+ `withoutCallerTx…`) | yes — `:119 [MANDATORY joins the caller's tx …]` |
| F | ★ MANDATORY → REQUIRED | I10 `withoutCallerTx_throwsIllegalTransactionState` (U12 reflection kills it too, same assertion as E) | yes — `:127` |
| G | ★ audit destination changed from `'N/A'` (to a URL) | I4 | yes — `:296 [the egress watchdog's own exclusion literal]` |
| G (clean) | same | I11 `requeueAuditRows_yieldZeroFindings` | yes — `:303 [no failing/misrouted/stalled finding may name the requeue audit process]`. **Only with `mvn clean`**: the first, incremental run left I11 green because `AUDIT_DESTINATION` is a compile-time constant inlined into the test class, which was not recompiled. CI builds clean, so I11 is a real killer there |
| H | ★ audit sender = the instance name | U13 `auditRow_isNotResendable` (+ `…senderNotInstance`) | yes — `:496` |
| I | ★ controller 409 mapping removed | U14 `lockTimeout_maps409` | yes — error `CannotAcquireLockException: canceling statement due to lock timeout` |
| J | ★ `resendConfirmed` `^2` regex replaced by "any code" | I5 `resendWith5xxDoesNot` | yes — `:215` |
| K | ★ PURGED +1 day removed | U12 `purged_onlyBeyondRetentionPlusOneDay_boundaryIsUnknown` | yes — `:299 [shipped = today − retention − 1 is the boundary day …]` |
| N | counter increments by row count | O1 `requeueCounterIsPerCallAndInfoLineCarriesRows` | yes — `:519 [one operator action = one count …]` |
| O | INFO `rows` field wrong | O3 (same test) | yes — `:525` |
| P | requeue writes a stale URL | U13 `requeueUsesCurrentShippedUrl` (+3) | yes — `:426` |
| Q | precedence PENDING over FAILED | U12 `failedBeatsPending` | yes — `:254` |
| R | confirmed = surviving rows only (purged SENT not counted) | U12 `confirmedCountsPurgedSentRows` | yes — `:220` |
| T | chunk id range widened into the neighbours | I3 | yes — `:161` |
| U | `messagePresent` always true | I3, I5 `lastMessageIdLeftJoinReportsPurgedMessage` | yes — `:189` |
| W | audit names the eligible ids instead of the returned ones | U13 `auditRow_namesReturnedIds` | yes — `:453` |
| S1 | EMPTY_BOL predicate loses the garbage clause | `emptyBolPredicate_…` IT | yes — `:250` |
| S2 | EMPTY_BOL predicate: carrier must be null (dangling carrier lost) | same | yes — `:255` |
| X1 | PURGED checked before EMPTY_BOL | U12 `noRows_emptyBol_vs_purged_vs_unknown` | yes — `:280` |
| X2 | an OPEN BOL treated as shipped | U12 `openBol_isNotShipped` | yes — `:326` |
| X3 | legacy label ignores the BOL type | U12 `legacyOversizedRow_isLabelledLegacy` | yes — `:356` |
| X4 | NONE reasons swapped | U13 `requeue_inFlightOnly_returnsNoneWithReason` | yes — `:367` |
| X5 | resend-reconciled rows counted as failed | U12 `resendConfirmedCountsAsConfirmed` | yes — `:236` |
| X6 | requeue answered 202 instead of 200 | U14 `nothingEligible_is200None` | yes — `Status expected:<200> but was:<202>` |

All 15 plan §8 targets (★) are killed by the test the plan names. One survivor (M3) exposed dead code, which was removed.

## Full suite on the final commit

Command: `mvn -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` (CI's), clean `git status` before each run. Baseline at develop `4ce87ead` (CI run 38952436360): surefire 8443 / 0 / 0 / 1, failsafe 917 / 0 / 0 / 23.

**Suite of record — head `ad8ff63e`:** @@FINAL@@

Data points on earlier heads (not the suite of record):

| Head | Surefire run / fail / err / skip | Failsafe run / fail / err / skip | Note |
|---|---|---|---|
| `fb89bd31` | 8500 / **3** / 0 / 1 | not run (verify stops at the surefire failure) | `NeverMatcherNullBlindnessArchTest` ×2 (review H1) and `TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared` (BolOmsNotificationRowsIT not declared NOT_SUPPORTED-exempt). Fixed in `c8782d2a` |
| `c8782d2a` | — | — | run stopped by me: edits were saved while it compiled, so it would have graded a mixed tree; not cited |
| `1866ab66` | 8502 / 0 / 0 / 1 | 938 / 0 / 0 / 23 | green |
| `057d0e3b` | 8504 / 0 / 0 / 1 | 938 / 0 / 0 / 23 | green |

**Reconciliation against the baseline** (counts move only by tests this ticket adds; no pre-existing test removed or skipped):

- Surefire +62 (8443 → 8505): gate commit +29 (its baseline doc: 29 new surefire methods); Story 1 +6 (chunker U1–U3); Story 3 +22 (`BolOmsNotificationServiceUnitTest` +19, `BillOfLadingControllerUnitTest` +3); round 1 +2 (`rolledBackRequeue_isNotCounted`, `lastError_redactsUrlsBeforeAbbreviating`; the controller status test was replaced by the wire-names test, net 0); round 2 +2 (`lastError_redactsBareConfiguredOmsHost`, `lastError_redactionIsLinear`); round 3 +1 (`lastError_withoutAConfiguredHost_isNotInterleaved`). 29 + 6 + 22 + 2 + 2 + 1 = 62.
- Failsafe +21 (917 → 938): gate +5 (`BolChunkOutboxClaimIT` 3, `OutboxMigrationV2240IT` 2); Story 2/3 +14 (`BolOmsNotificationRowsIT` 10, `MessageServiceCallerTxIT` 3, `OmsEgressWatchdogQueryIT` +1); round 1 +2 (`otherProcessTypeOnSameAggregate_isNeitherReadNorFlipped`, `requeueBlockedPastLockTimeout_is409AtTheController`). 5 + 14 + 2 = 21.
- Skips unchanged (1 / 23).

## Review round 1 fixes

Sources: `review-api-code.md` (H1, M1, L1–L11, Q1–Q3), `review-api-security.md` (L1–L5, nit), `conformance-verifier.md` (2 Lows). Commits `c8782d2a` and `1866ab66`. Mutations ran with the same copy/mutate/restore discipline as above; the tree was clean after each.

| Finding | Fix | Test | Mutant → verdict |
|---|---|---|---|
| code H1: `NeverMatcherNullBlindnessArchTest` red | bare `any()` in the three `never()` sites (`findBolNotificationRows(Long)`, `requeueBolTerminal(List,String)`, `HttpRestService.post(String,String)`; all reference parameters). Inventory `OutboxDispatchServiceUnitTest` 5 → 8 (the three new `markRetry(…, int)` sites; `int` is primitive, signature read). No BolOms entry needed: its one `anyLong` was on a boxed `Long`, so it was widened instead | the arch test itself; `requeue_inFlightOnly_returnsNoneWithReason` | R1: NONE path calls `requeueBolTerminal(eligible, null)` → **red** `:395` (the old `anyList()/anyString()` would have stayed green) |
| (not in the review) `TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared` red at fb89bd31 | `BolOmsNotificationRowsIT` added to `EXEMPT_NON_TRANSACTIONAL`, with the reason (it commits, asserts by id across threads/sessions, cleans up by id) | the arch test | arch rail is its own guard |
| code M1: no full-suite evidence | suite of record run on the final head; see "Full suite on the final commit" | — | — |
| code L1 + conformance Low 1: `runShippingPhase` javadoc orphaned | `enqueueBolShippedNotification` (with its own javadoc) moved below `runShippingPhase` | compile | n/a (doc) |
| code L2 + security L1: no `process_type` fence | `AND o.process_type = 'ORDER_BATCH_SHIPPED'` in the row-set reads and `AND process_type = 'ORDER_BATCH_SHIPPED'` in `requeueBolTerminal` | IT `otherProcessTypeOnSameAggregate_isNeitherReadNorFlipped` (an `ORDER_BATCH_LOADED_TO_TRUCK` FAILED_TERMINAL row on the same `BILL_OF_LADING` aggregate: absent from both reads; not flipped when its id is handed to the UPDATE directly) | R7 read fence removed → **red** `:340`; R8 UPDATE fence removed → **red** `:346` |
| code L3: tag key spelling | **no change, rationale (lead decision):** keep `process_type`, as plan §8 O2 specifies and the gate pins; it matches `wms2.outbox.serialize_failed`, which Fix A also increments. A comment at the counter says the class mixes spellings knowingly | gate O2 unchanged | — |
| code L4: link failure logged without its stack | exception passed as the last WARN argument | none (log shape) | not mutation-checked: no assertion |
| code L5: legacy label used today's K | keyed on the fixed `CHUNK_SIZE_CEILING` (60): a row that fits one OMS call is never "legacy", whatever K is later; the status read no longer touches the K sysprop | `legacyOversizedRow_isLabelledLegacy` now 61 → legacy, 60 → not, 50 at K=40 → not | R4 threshold back to 40 → **red** `:369` |
| code L6: requeue read the payload | new `findBolNotificationRowsForRequeue` (same SQL from shared constant fragments `BOL_ROW_COLUMNS` / `BOL_ROWS_FROM_WHERE`, `CAST(NULL AS text)` for the payload); the status read keeps `findBolNotificationRows` (gate contract unchanged) | all I4/I7/requeue tests now go through it; the fence IT covers both reads | R7 kills both reads' fence |
| code L7: counter before commit | INFO line + counter registered as `TransactionSynchronization.afterCommit` (repo idiom: `OmsNotificationService`, `ReceivingService`). Unit tests open synchronization and play the commit | O1/O3 test now asserts nothing counted/logged before commit; new `rolledBackRequeue_isNotCounted`; I4/I7 (real commits) still +1 | R5 telemetry run immediately → **red** `:540` and `rolledBackRequeue_isNotCounted:567` |
| code L8: `existsTopLevelPallet` lacked `@RestResource(exported = false)` | added | none | not mutation-checked: type-level `exported = false` already hides it |
| code L9: production omits null fields (NON_NULL), unit lane prints `null` | noted for the UI lane (missing key = null); the controller wire test uses an all-non-null DTO so it pins names, not null handling | — | — |
| code L10: plan text drift (PRD at 2.2.38, resolver location, 409 precedents) | **not edited by me:** the plan is the lead's document; listed here and in Interpretations 2/9 for the docs pass. (The 2.2.39 → 2.2.40 references were fixed by the lead under security M1) | — | — |
| code L11: K resolver duplicated with the club one | **declined (optional per the reviewer):** extracting a shared resolver would change `CustomerorderBatchService`'s club path, which is outside this ticket; the plan asks for the club resolver's shape, not its code | — | — |
| code Q1 / lead item 6: does a real 55P03 reach the controller as `PessimisticLockingFailureException`? | **Yes, through the controller.** IT `requeueBlockedPastLockTimeout_is409AtTheController`: a second JDBC session holds `SELECT … FOR UPDATE` on the FAILED_TERMINAL row (released in `finally`); a standalone MockMvc over the real `BillOfLadingController` bean (real proxied service and repository, no exception advice) POSTs the requeue; it waits out the lane's 10 s `lock_timeout` and answers **409** with title "Requeue In Progress"; the row stays FAILED_TERMINAL and no audit row exists | the IT | R9 controller catch removed → **error** `:380 … PessimisticLockingFailureException: JDBC exception executing SQL [UPDATE outbox_message …` (which is the answer to Q1: Spring translates it to that exact type) |
| code Q2 / PRD EXPLAIN | done by the lead (c1wh 3.5 ms, WineCo 13.6 ms) | — | — |
| code Q3: EMPTY_BOL read at status time | not changed; no product path deletes positions of a CLOSED BOL that I know of (SBDEV-3487 NOT_CLOSED predicate); left as the reviewer's open question | — | — |
| security L2: `lastError` exposes the OMS URL | `redactedLastError`: every `scheme://…` URL replaced by `<oms-url>`, then abbreviated to 300 | `lastError_redactsUrlsBeforeAbbreviating` (timeout text with a userinfo+port+query URL; a 400-char body with a URL) | R2 redaction removed → **red** `:580`; R3 abbreviate-then-redact → **red** `:585` |
| security L3: no requeue cooldown | no change (lead: documented behaviour) | — | — |
| security L4 / L5 | no action / UI-side | — | — |
| security nit: `~ '^2'` vs the watchdog's `'^2\d\d$'` | **not changed:** the gate contract `bolRowSetQueryCoversBothShapesAndResend` pins the literal `'^2'`, and gate assertions are off limits. Raise with the lead if wanted | — | — |
| lead item 8: wire names | `omsNotificationStatus_wireFieldNames` pins all 11 top-level names (incl. top-level `legacy`, `legacyParcels`) and all 8 `failedChunks[]` names, plus their counts | the controller test | R6 `legacyParcels` renamed → **red** `No value at JSON path "$.legacyParcels"` |
| conformance Low 2: SBDEV-3672 controller tests outside a @Nested | moved into `@Nested class OmsNotification` (they were outer-class tests that surefire reports under a nested file, trap 3); class total 41 before and after; the nested report shows `Tests run: 5` | — | structural |

## Review round 2 fixes (`0f54c0bf`, `057d0e3b`)

| Finding | Fix | Test | Mutant → verdict |
|---|---|---|---|
| R2-1: NONE-path "no counter" asserts vacuous after L7 | both NONE tests play `commit()` (and capture the log) before asserting no counter and no `requeue ` line | `requeue_inFlightOnly_returnsNoneWithReason`, `concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter` | MC telemetry registered on the 0-rows path → **red** `:478`; MC2 registered on the nothing-eligible path → **red** `:405 [nor logs a requeue line]` |
| R2-2: quadratic URL regex | `(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]{0,31}://[^\s"']+`. A 4096-char pre-cap was tried in `0f54c0bf`, but it hid the quadratic mutant from the timing guard (MQ **survived**), so `057d0e3b` dropped it and the linear pattern is the single, pinned bound | `lastError_redactionIsLinear` (100k chars, `assertTimeoutPreemptively` 1 s) | MQ old pattern restored → **red** `:609 execution timed out after 1000 ms` |
| R2-3: bare host survives | the current shipped-URL sysprop's host is replaced case-insensitively by `<oms-host>` after the URL pass, before the cut; javadoc states the limit (an earlier endpoint's host is not caught) | `lastError_redactsBareConfiguredOmsHost` (unknown-host and TLS shapes) | MH host pass removed → **red** `:600`; MI case-sensitive → **red** `:601` |
| R2-4: exemption reason overclaimed | names the kept operator user and the restored sysprop | arch test | n/a (comment) |
| R2-5: DisplayName "nor logged" unasserted | `rolledBackRequeue_isNotCounted` asserts no `requeue ` line | same | ML telemetry moved to `afterCompletion` (runs on rollback) → **red** `:587` |
| L3 comment reference | "(plan §8 O2)" now sits on the `"process_type"` spelling it specifies | — | n/a |
| watchdog README (plan §6) | "Day to day": poisoned 24 h row + ack; requeue audit rows excluded via `'N/A'` (`egress-failures.sql:91`, checked: line 91 is `AND m.destination <> 'N/A'`). "Partial failure": BOL-shipped rows now retry ~24 h and large BOLs are chunked | — | — |
| legacy threshold | no change (lead decision; plan A-L6 amended) | — | — |

## Review round 3 fixes (`ad8ff63e`)

| Finding | Fix | Test | Mutant → verdict |
|---|---|---|---|
| R3-1: no test for a null/blank/unparseable shipped URL | `lastError_withoutAConfiguredHost_isNotInterleaved` over `null`, `""`, `"   "`, `"not a url"`, `"http://[bad"`, `"/relative/path"`: `lastError` comes back with only its URL redacted, never `<oms-host>` | that test | MB-equivalent (unset/unparseable host yields `""` and the empty-string pattern reaches the redaction) → **red** `:615 [sysprop <null>]` |
| R3-2: README understated the red and named one key | red lasts until N later BOL-shipped sends succeed (possibly > 1 day); a chunked BOL in an outage reddens `outbox` too; ack example `<tenant>/<warehouse> failing (message\|outbox):ORDER_BATCH_SHIPPED`. Key shape checked against `run.sh:141` (`key="$tenant/$warehouse $kind $path:$process"`) and the SQL's `path` values `message`/`outbox` | — | — |
| R3-3: host pattern compiled per row | `omsHostPattern()` compiles once per status read; a never-matching `NO_HOST` sentinel replaces the empty-string case | covered by R3-1 and R2-3 tests | (R3-1 mutant above) |

## Scaffolding edits to gate tests

1. **`BillOfLadingControllerUnitTest` `setUp`** (`fb89bd31`): `new BillOfLadingController(...)` gained the new `BolOmsNotificationService` constructor argument, with a `@Mock` field and its import. Genuinely broken setup: the controller needs the service injected (constructor injection, repo convention), so the gate's 8-argument call no longer compiles. No assertion touched.
2. **`BolShippedNotificationChunkerUnitTest`**: kept `splitContractExists` unchanged (it still guards the signature the producer calls); updated the class javadoc/`@DisplayName` from "gate" to describe the added U1–U3, and added imports. No assertion touched.
3. **`BolOmsNotificationServiceUnitTest`**: the three gate tests are unchanged; the class javadoc now says the behavioural tests were added; imports added for them.

No gate assertion was changed, weakened, skipped or deleted.

## Interpretations and deviations from the plan

1. **V2.2.40 built over two commits.** Story 1 created it with the seed only (U9 needs it); Story 2 prepended `SET LOCAL lock_timeout = '5s'` and the `ADD COLUMN`. Unreleased file, so no immutability issue. Final order: SET LOCAL, ALTER, seed.
2. **K resolver lives in `BolShippedNotificationChunker`** (moved there in Story 3 from a private BOLS method). Plan §4 lists the chunker as "pure splitter + K resolver", §6 lists the resolver under BOLS; the status service needs K for the legacy label, so it had to be shared. It takes the caller's `Logger`, so U8's WARN capture on the BOLS logger is unaffected (re-mutated: A).
3. **Chunker dead branch removed** after M3 survived; javadoc updated to say why (lazy cut).
4. **Audit row fields the plan leaves open:** `status = CREATED`, `receiver = getOmsInstanceName()`, `message` = the same audit JSON as `answer` (so the row is keyword-searchable). Plan-pinned fields are as specified (`process`, `destination 'N/A'`, `statuscodeanswer 'REQUEUE'`, `sender 'wms:requeue'`, operator = principal, answer `{bolId, outboxIds, mode, user}`).
5. **Legacy label only for REGULAR / HUB_AND_SPOKE BOLs**, and (since review round 1, L5) only above the fixed 60-parcel `CHUNK_SIZE_CEILING`, not today's K. A transfer is one row by design and never chunked. The lead amended plan A-L6 to match.
6. **`requeue` additions:** `rollbackFor = BusinessException.class` (a checked exception from the audit write would otherwise COMMIT the flip without its audit row); unknown BOL → `EntityNotFoundException` (404, same as status); blank `WEBSERVICE_ORDER_BATCH_SHIPPED` → `BusinessException` (built with the one-arg constructor to dodge the null-message trap) instead of nulling `destination_url`. The gate's attribute test still passes (it checks manager, readOnly, propagation only).
7. **`findBolNotificationRows` returns one extra column**, `singleRowPayload` (payload of a non-SENT `BILL_OF_LADING` row only), for the legacy parcel count. The gate's SQL contract is satisfied.
8. **EMPTY_BOL predicate is native** (`BillofladingPositionRepository.existsTopLevelPallet`) as the plan says, so U12 `#emptyBol_matchesRunShippingPhaseTopLevelClassification` can only pin the service's use of it. The predicate itself is pinned against PostgreSQL by an extra IT, `BolOmsNotificationRowsIT#emptyBolPredicate_matchesRunShippingPhaseClassification` (no positions / garbage only / pallet / child of a garbage parent / carrier in another BOL).
9. **409 mapping.** Plan's precedents (`StockUnitController:421`, `mobile/PickingController:76`) actually return 200 with an `errors` map, not a 409. Followed the plan's explicit "409 ProblemDetail" in the shape `RestExceptionHandler` uses. Note `RestExceptionHandler` already maps `PessimisticLockingFailureException` to a generic 409 "Resource Locked"; the controller mapping gives the requeue-specific title/detail the UI keys on, and U14 pins that text.
10. **I11 positive control** runs inside one uncommitted transaction and rolls back, rather than seeding the shared fixture, so `flaggedSetIsExact` and the other cases are untouched.
11. ~~Counter incremented inside the requeue tx~~: fixed in review round 1 (L7). The INFO line and the counter now run in `afterCommit`.
12. **Extra tests beyond §8:** `unknownBol_isNotFound`, `omsNotificationStatus_returnsStatus`, `MessageServiceCallerTxIT#control_auditRowCommitsWithCallerTx`, the EMPTY_BOL IT.
13. **`RestIdempotencyCleanupJob.safeOutboxRetentionDays(int)`** is now a public static helper (the instance method delegates); `BolOmsNotificationService` binds `app.outbox.dispatcher.retention-days` itself and applies the same floor.

## Not done / open

- Plan Step 3's PRD `EXPLAIN ANALYZE`: run by the lead (c1wh 3.5 ms, WineCo 13.6 ms).
- I5 `resendWith2xxRedeliverIdReconciles` / `resendOfEarlierAttemptIsNotReconciled`: no mutation targeted the reconcile direction specifically (J covers the code filter, U the join). A mutation dropping `r.redeliver_id = o.last_message_id` would be the next one to run.
- Docs (§6 docs row, except the watchdog README done in round 2) and the web-ui side are out of this task's scope.
