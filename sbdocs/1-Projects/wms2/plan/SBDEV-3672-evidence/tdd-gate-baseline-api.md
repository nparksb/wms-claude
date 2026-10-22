---
ticket: SBDEV-3672
kind: tdd-gate-baseline
repo: v2/wms2-api
date: 2026-10-13
---

# SBDEV-3672 — TDD gate baseline (wms2-api)

- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3672`
- **Branch:** `fix/SBDEV-3672-chunk-bol-shipped`, base `origin/develop` `a4fd6490`, **no commits** (tests are uncommitted working-tree changes)
- **Production code touched:** none (`git status` shows `src/test/**` only)
- **Plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-3672-chunk-bol-shipped-notification.md` §5, §6, §7 (AC-A/B/B1/C/D/D2), §8

## Compile strategy

Tests for behaviour that existing code already reaches are real behavioural tests. They compile today and fail at an assertion. Every new symbol (chunker, `BolOmsNotificationService`, the repo/service link and requeue methods, `createServiceLogInCallerTx`, the two controller handlers) is reached by reflection: classes are loaded with `Class.forName`, methods are looked up by name plus parameter count (or, for handlers, by mapping path), and the declared set is asserted before anything else. A missing symbol therefore fails at an assertion that names it, not at compile time. Two dispatcher seams also avoid the new symbols:
- **Retry budget.** `setBolShippedBudgetIfPresent(29)` sets the field only if `bolShippedMaxAttempts` exists.
- **Link call.** The link is observed through `mockingDetails(outboxService).getInvocations()`, and made to fail through a name-keyed default `Answer`.

## Contract names the gate fixed (the executor must match these, or update the tests in its first commit)

| Symbol | Name/shape the tests expect |
|---|---|
| Sysprop key | `"WMS_BOL_SHIPPED_OMS_CHUNK_SIZE"` (literal in U5–U8) |
| WmsConstants | `SYSTEM_PROPERTY_BOL_SHIPPED_OMS_CHUNK_SIZE_KEY`, `SYSTEM_PROPERTY_BOL_SHIPPED_OMS_CHUNK_SIZE_DEFAULT_VALUE` = `"40"` (U9, read reflectively) |
| Migration | `src/main/resources/db/migration/V2.2.39__bol_shipped_chunk_size_and_outbox_message_link.sql` (plan §6 name); seed INSERT contains `'WMS_BOL_SHIPPED_OMS_CHUNK_SIZE', '40'`, `WHERE NOT EXISTS`, `workstation = 'DEFAULT'` |
| Chunker | `net.aim_ai.wms.service.BolShippedNotificationChunker#split(BillOfLadingWebServiceDto, int)` → `List` |
| Dispatcher field | `int bolShippedMaxAttempts` (U10 sets it reflectively when present) |
| Property | `app.outbox.dispatcher.bol-shipped-max-attempts=29` in **`src/main/resources/application.properties`** (read from disk, not classpath) |
| Link | `OutboxService.linkServiceLog(outboxId, messageId)`, called with args `(1L, 777L)`, `@Transactional(tenantTransactionManager, REQUIRES_NEW)`; `OutboxMessageRepository.linkServiceLog` with 2 params: native `@Modifying`, SQL names `last_message_id` and contains neither `version` nor `modified_at` |
| Link-failure counter | `wms2.outbox.service_log_link.failed{process_type=ORDER_BATCH_SHIPPED}` (tag key `process_type`) |
| Row-set query | `OutboxMessageRepository.findBolNotificationRows` with 1 param: native, not `@Modifying`; SQL contains `'bill_of_lading'`, `'bill_of_lading_chunk'`, `100000`, `between`, `left join message`, `last_message_id`, `redeliver_id`, `'^2'`, and no `for update` |
| Requeue UPDATE | `OutboxMessageRepository.requeueBolTerminal` with 2 params: native `@Modifying`; SQL (whitespace-stripped, lower-cased) contains `update outbox_message`, `status='failed_terminal'`, `status='failed_retry'`, `attempts=0`, `destination_url=:`, `returning id`, and no `idempotency_key` |
| Service | `net.aim_ai.wms.service.BolOmsNotificationService#status` (1 param): `@Transactional(tenantTransactionManager, readOnly=true, REQUIRED)`. `#requeue` (1 param): `@Transactional(tenantTransactionManager, readOnly=false, REQUIRED)` |
| Audit write | `MessageService.createServiceLogInCallerTx` (exactly one declaration): `@Transactional(tenantTransactionManager, MANDATORY)` |
| Endpoints | `BillOfLadingController`: `@GetMapping("/omsNotificationStatus/{id}")` and `@PostMapping("/requeueOmsNotification/{id}")` (no `@GetMapping`), each `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING)` and nothing else |

## Tests written

| Test class | Method | Criterion | Gate result |
|---|---|---|---|
| `unit/service/BillofladingServiceUnitTest$Sbdev3672ChunkedBolShippedNotification` | `closeBol_atOrBelowK_payloadIsByteEqualToTodaysFixture` | U4 / AC-A | **expected pass**: pins the ≤K path (1 row, `BILL_OF_LADING`, id, null key so OS:49 assigns a UUID, DEFAULT lane, payload byte-equal to the fixture) |
| ″ | `closeBol_exactlyK_staysOneRow` | U4 boundary | **expected pass**: pin (40 parcels at K=40 → 1 row) |
| ″ | `closeBol_aboveK_enqueuesChunkRowsWithKeysUnder64` | U5 / AC-A | correct failure |
| ″ | `hubAndSpokeAboveK_isChunked` | U6 | correct failure |
| ″ | `transferOffsiteAndIntracompanyAboveK_stayOneRow` | U6 / AC-A | **expected pass**: pin (transfers stay 1 row) |
| ″ | `anyChunkSerializeFailure_enqueuesNothingAndThrows` | U7 | correct failure |
| ″ | `chunkSize_missingOrBlank_40NoWarn` | U8 | correct failure |
| ″ | `chunkSize_garbageOrZero_40WithWarn` | U8 | correct failure |
| ″ | `chunkSize_above60_clampsTo60WithWarn` | U8 (K-clamp mutation target) | correct failure |
| `unit/db/BolShippedOmsChunkSizeSeedConsistencyTest` (new) | `seedMatchesConstant` | U9 | correct failure (file absent) |
| `unit/service/job/OutboxDispatchServiceUnitTest` | `bolShippedChunkRow_retriesUntil29` | U10 / AC-C | correct failure |
| ″ | `bolShippedSingleRow_retriesUntil29` | U10 / AC-C | correct failure |
| ″ | `otherProcessType_terminalAt5` | U10 / AC-C | **expected pass**: pin (CUSTOMER_ORDER still terminal at 5, both branches) |
| ″ | `bolShipped400_terminalImmediately` | U10 | **expected pass**: pin |
| ″ | `bolShippedMaxAttempts_deployedValueIs29` | U10 / AC-C (extra: deployed property) | correct failure |
| ″ | `bolShippedRow_linksServiceLogId` | U11 | correct failure |
| ″ | `linkFailureIn2xxBranch_neverCallsMarkRetryOrMarkTerminal` | U11 + O2 / AC-B1 | correct failure (positive control: link never attempted) |
| ″ | `otherProcessTypes_notLinked` | U11 | **expected pass, vacuous today** (no link exists). It becomes meaningful once the link lands |
| `unit/model/OutboxMessageMappingUnitTest` (new) | `entityDoesNotMapLastMessageId` | U15 / AC-B1 (C-H2) | **expected pass**: pins an invariant; see the mutation note below |
| `unit/service/BolShippedNotificationChunkerUnitTest` (new) | `splitContractExists` | U1–U3 contract | correct failure (class absent) |
| `unit/service/BolOmsNotificationServiceUnitTest` (new) | `statusIsReadOnlyTenantTx` | U12 | correct failure (class absent) |
| ″ | `requeueIsReadWriteTenantTx` | U12 | correct failure (class absent) |
| ″ | `requeueUpdateTouchesOnlyFailedTerminalRows` | U13 / AC-D (A-N4 SQL text) | correct failure (method absent) |
| `unit/repo/OutboxBolNotificationContractUnitTest` (new) | `repositoryLinkIsNativeAndTouchesOnlyLastMessageId` | Fix B-1 / A-L2 | correct failure |
| ″ | `serviceLinkIsRequiresNewTenantTx` | Fix B-1 | correct failure |
| ″ | `bolRowSetQueryCoversBothShapesAndResend` | Fix B-2 | correct failure |
| `unit/service/MessageServiceUnitTest` | `createServiceLogInCallerTxIsMandatory` | U12 / AC-D2 | correct failure |
| `unit/controller/BillOfLadingControllerUnitTest` | `omsNotificationStatus_isGatedGet` | U14 (verb + gate) | correct failure |
| ″ | `requeue_isPost` | U14 | correct failure |
| `security/Sbdev3017TrancheGateContextTest` | +2 `row(...)` lines, `thePinHasNotBeenQuietlyShrunk` 227→229 | G1 | `everyTrancheRouteCarriesItsIntendedFunctions` correct failure ("2 of 229 routes wrong… ROUTE NOT DEPLOYED"); size test passes at 229 |
| `integration/outbox/BolChunkOutboxClaimIT` (new, failsafe) | `terminalChunkDoesNotHoldSiblings` | I1 | **pass. The behaviour already exists (pins infrastructure)**: the claim gate and lane split predate the ticket |
| ″ | `sharedAggregateId_wouldWedgeSiblings` | I1 positive control | pass. Proves the fail-closed gate is live in this fixture, so I1's "not held" is not vacuous |
| ″ | `defaultLaneNeverClaimsChunkRows` | I2 | **pass. The behaviour already exists (pins infrastructure)** |
| `integration/outbox/OutboxMigrationV2239IT` (new, failsafe) | `addsNullableColumn` | I9 | correct failure (file absent) |
| ″ | `seedIsIdempotent` | I9 | correct failure (file absent) |

## Failure-output excerpts (attributable)

```
closeBol_aboveK_enqueuesChunkRowsWithKeysUnder64:3799 [SBDEV-3672 Fix A: a 95-parcel BOL at the default K=40 must enqueue 3 chunk rows (40/40/15), not one oversized BILL_OF_LADING row] Expected size: 3 but was: 1
hubAndSpokeAboveK_isChunked:3837 [... a 41-parcel HUB_AND_SPOKE BOL at K=40 must be chunked into 2 rows] Expected size: 2 but was: 1
anyChunkSerializeFailure_enqueuesNothingAndThrows:3890 [SBDEV-3672 Fix A: every chunk is serialized BEFORE any is enqueued, and a failure on any chunk must throw FacadeException so the close rolls back (SBDEV-2221)] Expecting actual not to be null
chunkSize_missingOrBlank_40NoWarn:3920 [chunk size <missing> must fall back to K=40, so 41 parcels make 2 chunk rows] Expected size: 2 but was: 1
chunkSize_garbageOrZero_40WithWarn:3944 [chunk size 'abc' must fall back to K=40, so 41 parcels make 2 chunk rows] Expected size: 2 but was: 1
chunkSize_above60_clampsTo60WithWarn:3965 [chunk size 100 must clamp to 60, so 61 parcels make 2 chunk rows (unclamped K=100 would make 1)] Expected size: 2 but was: 1
seedMatchesConstant:42 [SBDEV-3672 Fix B-1: the V2.2.39 migration must exist; ...] Expecting path: src/main/resources/db/migration/V2.2.39__bol_shipped_chunk_size_and_outbox_message_link.sql to exist
bolShippedChunkRow_retriesUntil29:744 [SBDEV-3672 Fix C: an ORDER_BATCH_SHIPPED BILL_OF_LADING_CHUNK row at attempts=5 must NOT go terminal (non-2xx branch (ODS:181)) — the budget is 29 attempts (~24 h), not maxAttempts=5] expected: 0L but was: 1L
bolShippedSingleRow_retriesUntil29:744 [... BILL_OF_LADING row at attempts=5 must NOT go terminal ...] expected: 0L but was: 1L
bolShippedMaxAttempts_deployedValueIs29:815 [SBDEV-3672 Fix C: the BOL-shipped retry budget (29 attempts ~ 24.05 h) must be set in src/main/resources/application.properties ...] expected: "29" but was: null
bolShippedRow_linksServiceLogId:868 [SBDEV-3672 Fix B-1: after writeServiceLog, an ORDER_BATCH_SHIPPED row must call OutboxService.linkServiceLog(outboxId, messageId) exactly once] Expected size: 1 but was: 0
linkFailureIn2xxBranch_neverCallsMarkRetryOrMarkTerminal:887 [positive control — the link must actually be attempted, or the no-retry assertions below are vacuous] Expected size: 1 but was: 0
splitContractExists -> load:53 SBDEV-3672: class net.aim_ai.wms.service.BolShippedNotificationChunker does not exist yet (plan §6 adds it)
statusIsReadOnlyTenantTx / requeueIsReadWriteTenantTx -> load:106 SBDEV-3672: class net.aim_ai.wms.service.BolOmsNotificationService does not exist yet (plan §6 adds it)
requeueUpdateTouchesOnlyFailedTerminalRows -> uniqueMethod:92 [SBDEV-3672: OutboxMessageRepository must declare exactly one requeueBolTerminal(2 args)] Expected size: 1 but was: 0
repositoryLinkIsNativeAndTouchesOnlyLastMessageId / bolRowSetQueryCoversBothShapesAndResend / serviceLinkIsRequiresNewTenantTx -> uniqueMethod:93 [... must declare exactly one linkServiceLog(2 args) | findBolNotificationRows(1 args) | OutboxService ... linkServiceLog(2 args)] Expected size: 1 but was: 0
createServiceLogInCallerTxIsMandatory:529 [SBDEV-3672 Fix D-3: MessageService must declare exactly one createServiceLogInCallerTx] Expected size: 1 but was: 0
omsNotificationStatus_isGatedGet / requeue_isPost -> sbdev3672HandlerFor:889 [SBDEV-3672: BillOfLadingController must map exactly one handler to /omsNotificationStatus/{id} | /requeueOmsNotification/{id}] Expected size: 1 but was: 0
Sbdev3017TrancheGateContextTest.everyTrancheRouteCarriesItsIntendedFunctions:1002 [... 2 of 229 routes wrong ...] {BillOfLadingController /v3/billOfLading/omsNotificationStatus/{id}=ROUTE NOT DEPLOYED ... expected WEB_UI_VIEW_BILL_OF_LADING, BillOfLadingController /v3/billOfLading/requeueOmsNotification/{id}=ROUTE NOT DEPLOYED ...}
OutboxMigrationV2239IT.addsNullableColumn:73 / seedIsIdempotent:114 [SBDEV-3672 Fix B-1: V2.2.39 must exist] Expecting path: ...V2.2.39__bol_shipped_chunk_size_and_outbox_message_link.sql to exist
```

## Verdict counts

- **New tests:** 34. Surefire has 29 new methods plus the G1 rows added to an existing test. Failsafe has 5 new methods.
- **Correct failures (fail at an assertion naming the missing behaviour):** 25:
  - 22 new surefire methods;
  - the existing `Sbdev3017TrancheGateContextTest#everyTrancheRouteCarriesItsIntendedFunctions`, red because of the 2 new G1 rows;
  - 2 failsafe I9 methods.
- **Expected passes, by design:** 7 surefire pins (U4 ×2, U6 transfer, U10 ×2, U11 `otherProcessTypes_notLinked`, U15), plus 3 failsafe ITs whose behaviour already exists (I1, its positive control, I2).
- **Adjusted during Step 4:** 2.
  - The U4 byte fixture was hand-guessed first and failed on key order. The real fixture was captured by running the unchanged a4fd6490 serializer and pasted in. Today's output puts `positions` first and the header after it.
  - The U10 assertions were first plain `verify(never())`, which fails with a bare Mockito message. They now count invocations under an `.as(...)` that names the budget, the attempt and the branch.
- **Setup problems / compile errors / unexpected passes:** 0.
- **Regressions in the touched classes:** none. 214 pre-existing tests across the 10 surefire classes all pass, and `thePinHasNotBeenQuietlyShrunk` passes at 229.

**U15 mutation note.** U15 passes today because there is no column yet, so nothing maps it. Its killing mutation (plan §8, "entity field added") would mean adding a `lastMessageId` field, or an `@Column(name="last_message_id")`, to `OutboxMessage`. The gate may not edit `src/main`, so this was **not** run. Reasoning only: the test scans declared fields and `@Column` names case-insensitively for `lastmessageid` / `last_message_id`, and its positive control asserts that the scan sees `id`, `aggregateType`, `aggregateId`, `status` and `version`. **The executor must run the mutation in its own commit.** The same applies to every mutation target in §8.

## Deferred to the executor's first commit (the symbol does not exist, so it cannot be expressed in compiling Java)

| # | Test | Reason |
|---|---|---|
| U1 | `BolShippedNotificationChunkerUnitTest#splitsEveryKParcelsKeepingItemsWithTheirParcel` | needs `BolShippedNotificationChunker.split` (add to the gate's class; drop/keep `splitContractExists`) |
| U2 | `…#straddlingPalletIsCopiedWithSameLabel` / `#neverEmitsEmptyPalletOnlyChunk` / `#slicesAreCopiesNotViews` / `#singlePalletOf1528Gives39Chunks` | same |
| U3 | `…#everyChunkCarriesFullHeaderSameBolIdAndZeroBasedChunkIndex` | same + DTO `chunk_index`/`chunk_count` accessors |
| U12 | `BolOmsNotificationServiceUnitTest#confirmedCountsPurgedSentRows` / `#resendConfirmedCountsAsConfirmed` / `#failedBeatsPending` / `#noRows_emptyBol_vs_purged_vs_unknown` / `#purged_onlyBeyondRetentionPlusOneDay_boundaryIsUnknown` / `#emptyBol_matchesRunShippingPhaseTopLevelClassification` / `#openBol_isNotShipped` / `#legacyOversizedRow_isLabelledLegacy` | needs `BolOmsNotificationService`, `findBolNotificationRows` row projection, retention helper |
| U13 | `BolOmsNotificationServiceUnitTest#requeue_inFlightOnly_returnsNoneWithReason` / `#resendConfirmedRows_areNotRequeued` / `#legacyOversizedRow_isRequeuedWhole_notRechunked` / `#transfer_isPlainRequeue` / `#requeueUsesCurrentShippedUrl` / `#concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter` / `#auditRow_namesReturnedIds` / `#auditRow_destinationNA_codeREQUEUE_senderNotInstance` / `#auditRow_isNotResendable` | needs the service, `requeueBolTerminal`, `createServiceLogInCallerTx`, `ORDER_BATCH_SHIPPED_REQUEUE` (`#requeueUpdateTouchesOnlyFailedTerminalRows` is already written) |
| U14 | `BillOfLadingControllerUnitTest#lockTimeout_maps409` / `#nothingEligible_is200None` | needs a `BolOmsNotificationService` mock (the type) and the handlers (`#requeue_isPost` is already written) |
| I3 | `BolOmsNotificationRowsIT#findsBothShapesOnlyForThisBol` | needs `findBolNotificationRows` + V2.2.39 column |
| I4 | `…#requeueFlipsOnlyTerminalRowsKeepsKeysAndWritesOneAuditRow` | needs service + `requeueBolTerminal` + audit write |
| I4b | `…#requeueUpdate_skipsRowsNoLongerTerminal` | needs `requeueBolTerminal` |
| I5 | `…#lastMessageIdLeftJoinReportsPurgedMessage` / `#resendWith2xxRedeliverIdReconciles` / `#resendWith5xxDoesNot` / `#resendOfEarlierAttemptIsNotReconciled` | needs `findBolNotificationRows` + column |
| I7 | `…#concurrentRequeue_oneRequeuesOtherReturnsNone` | needs service |
| I8 | `…#linkUpdateLeavesVersionAndModifiedAtUnchanged` | needs `OMR.linkServiceLog` + column |
| I10 | `MessageServiceCallerTxIT#auditRowRollsBackWithCallerTx` / `#withoutCallerTx_throwsIllegalTransactionState` | needs `createServiceLogInCallerTx` |
| I11 | `OmsEgressWatchdogQueryIT#requeueAuditRows_yieldZeroFindings` (+ URL-destination positive control) | needs `ORDER_BATCH_SHIPPED_REQUEUE` and the Fix D-3 audit-row shape (could be hand-inserted rows; deferred so the executor writes it from the real audit write rather than a guessed copy) |
| O1 | counter `wms2.outbox.requeued{aggregate_type,mode}` in U13/I4/I7 | needs service |
| O3 | requeue INFO line (ListAppender) in U13 | needs service |
| O4 | audit-row fields in I4 + I11 | needs audit write |

## Traps for the executor

1. **`SET LOCAL lock_timeout` is a no-op in the IT harness.** `OutboxItFlyway.migrateProduction` sets `executeInTransaction(false)`, so I9 cannot observe it. It applies only under `StartupFlywayMigrator`. PostgreSQL only WARNs here; it does not fail.
2. **Serialize every chunk through `MAPPER`.** U7 swaps `BillofladingService.MAPPER` for a spy whose second `writeValueAsString` throws. Any other mapper evades the test.
3. **Name the key in every resolver WARN.** U8 filters WARN events on the literal `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE`. Club's resolver already does this.
4. **`serialize_failed` must count 1 per BOL.** U7 sums the counter under both `aggregate_type` tag values. Either tag works; it must not count once per chunk.
5. **Unit tests do not run `@Value`.** U10 sets the field reflectively only if it exists. Keep the field name `bolShippedMaxAttempts`, or update `setBolShippedBudgetIfPresent`.
6. **Every chunk row needs `processType=ORDER_BATCH_SHIPPED` and `destinationUrl` = the shipped URL.** U5 asserts both. Each chunk's first pallet must also carry the straddling pallet's label.

## Run commands (toolchain: `JAVA_HOME=~/.sdkman/candidates/java/21*`, Maven offline, one invocation at a time)

```bash
# Unit lane, final consolidated run (10 classes; commas; reports confirmed present):
mvn -o test -Dtest='BillofladingServiceUnitTest,OutboxDispatchServiceUnitTest,BolShippedOmsChunkSizeSeedConsistencyTest,OutboxMessageMappingUnitTest,BolShippedNotificationChunkerUnitTest,BolOmsNotificationServiceUnitTest,OutboxBolNotificationContractUnitTest,MessageServiceUnitTest,BillOfLadingControllerUnitTest,Sbdev3017TrancheGateContextTest' -Dsurefire.failIfNoSpecifiedTests=false
#   -> Tests run: 243, Failures: 23, Errors: 0, Skipped: 0   (50 XML report files written)
#   The 23 failures = the 22 new failing methods + everyTrancheRouteCarriesItsIntendedFunctions (G1).

# Failsafe lane (the two new ITs; surefire selected to nothing):
mvn -o verify -Dit.test='BolChunkOutboxClaimIT,OutboxMigrationV2239IT' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dfailsafe.failIfNoSpecifiedTests=false
#   -> Tests run: 5, Failures: 2, Errors: 0, Skipped: 0
#      BolChunkOutboxClaimIT 3/3 pass; OutboxMigrationV2239IT 2/2 fail (file absent)
#   failsafe-reports: TEST-...BolChunkOutboxClaimIT.xml, TEST-...OutboxMigrationV2239IT.xml present
```

Earlier iterations: run 1 (9 classes): 238 run, 23 failed, including U4 before its fixture was captured. Run 2 (BOL + dispatch only): 174 run, 11 failed. Run 3 (gate context alone): 5 run, 1 failed. `mvn -o -q test-compile` was clean before the first run.

## `git -C <worktree> status --short`

```
 M src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java
 M src/test/java/net/aim_ai/wms/unit/controller/BillOfLadingControllerUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/service/BillofladingServiceUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/service/MessageServiceUnitTest.java
 M src/test/java/net/aim_ai/wms/unit/service/job/OutboxDispatchServiceUnitTest.java
?? src/test/java/net/aim_ai/wms/integration/outbox/BolChunkOutboxClaimIT.java
?? src/test/java/net/aim_ai/wms/integration/outbox/OutboxMigrationV2239IT.java
?? src/test/java/net/aim_ai/wms/unit/db/BolShippedOmsChunkSizeSeedConsistencyTest.java
?? src/test/java/net/aim_ai/wms/unit/model/OutboxMessageMappingUnitTest.java
?? src/test/java/net/aim_ai/wms/unit/repo/OutboxBolNotificationContractUnitTest.java
?? src/test/java/net/aim_ai/wms/unit/service/BolOmsNotificationServiceUnitTest.java
?? src/test/java/net/aim_ai/wms/unit/service/BolShippedNotificationChunkerUnitTest.java
```
