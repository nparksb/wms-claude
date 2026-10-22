---
kind: review
lane: conformance
ticket: SBDEV-3672
head: fb89bd31
ui_head: af44fcc
date: 2026-10-16
verdict: PASS
---

# SBDEV-3672 conformance verification (plan vs build)

**Verdict: PASS.** 0 blockers, 2 Low findings (§5). The API worktree I graded is `.claude/worktrees/wms2-api/SBDEV-3672-review-verify` at `fb89bd31`, with the diff taken against `origin/develop`. The UI worktree is `.claude/worktrees/wms2-web-ui/SBDEV-3672` at **`af44fcc`**, which is one commit past the 938247a named in the brief ("review round 4"). I ran every command below myself. After the mutation runs, `git status --short` on the API worktree was empty.

## 1. Fresh evidence

| Check | Result | Command | Output |
|---|---|---|---|
| Compile | pass | `mvn -o -q clean compile` | exit 0, no output |
| Unit classes (9) + G1 | pass | `mvn -o test -Dtest=BillOfLadingControllerUnitTest,BolShippedOmsChunkSizeSeedConsistencyTest,OutboxMessageMappingUnitTest,OutboxBolNotificationContractUnitTest,BillofladingServiceUnitTest,BolOmsNotificationServiceUnitTest,BolShippedNotificationChunkerUnitTest,MessageServiceUnitTest,OutboxDispatchServiceUnitTest,Sbdev3017TrancheGateContextTest` | `Tests run: 271, Failures: 0, Errors: 0, Skipped: 0`, exit 0 |
| Per-class run counts | match source | same log | BolOmsNotificationServiceUnitTest 22 · BolShippedNotificationChunkerUnitTest 7 · OutboxDispatchServiceUnitTest 47 · `BillofladingServiceUnitTest$Sbdev3672ChunkedBolShippedNotification` 9 · OutboxBolNotificationContractUnitTest 3 · MessageServiceUnitTest 17 across its nested classes (`createServiceLogInCallerTxIsMandatory` is in `$GetMessageDetails`, 3) · BillOfLadingControllerUnitTest 41 = 41 `@Test` (the 5 new tests sit in `$ExportOutboundBolBulk`, 22) · Sbdev3017TrancheGateContextTest 5 · seed 1 · mapping 1 |
| ITs (failsafe) | pass | `mvn -o verify -Dit.test='MessageServiceCallerTxIT,OmsEgressWatchdogQueryIT,BolChunkOutboxClaimIT,BolOmsNotificationRowsIT,OutboxMigrationV2240IT' -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dfailsafe.failIfNoSpecifiedTests=false` | BolOmsNotificationRowsIT 10 · OutboxMigrationV2240IT 2 · BolChunkOutboxClaimIT 3 · OmsEgressWatchdogQueryIT 29 · MessageServiceCallerTxIT 3. `Tests run: 47, Failures: 0, Errors: 0`, `BUILD SUCCESS`. The only `[ERROR]` line is `springdoc-openapi:generate … Connection refused`, the offline doc-generation plugin, which does not affect the result |
| UI jest (4 specs) | pass | `npx jest --coverage=false` on outboundBolOmsStatus, serviceLogDeepLink, outboundBolsOmsStatus, serviceLogsGetLogDetail | `Test Suites: 4 passed · Tests: 73 passed, 73 total` |
| Full suite vs baseline | not run here | — | Step 4's `mvn clean verify` belongs to the implementation lane. I ran only the targeted classes |

Logs are in the session scratchpad: `verify-unit.log`, `verify-it.log`, `verify/mutations.log` and `verify/mutations2.log`.

## 2. Cross-repo contract (Q1)

**Verdict: consistent. No mismatch.**

- **Serializer.** `WebConfigurer.objectMapper()` (`@Primary`, also handed to `MappingJackson2HttpMessageConverter`) sets **no naming strategy**, so names are camelCase. It sets `Include.NON_NULL` and disables `WRITE_DATES_AS_TIMESTAMPS`. `application.properties:14` repeats `default-property-inclusion=NON_NULL`.
- **Field names.** Java records serialize under their component names.
  - `BolOmsNotificationStatusDto`: `state, noRecordReason, chunkCount, confirmed, pending, failed, resendConfirmed, retentionDays, legacy, legacyParcels, failedChunks[]`.
  - `FailedChunk`: `outboxId, chunkIndex, chunkCount, attempts, nextAttemptAt, lastError, lastMessageId, messagePresent`.
  - `legacy` and `legacyParcels` are **top-level** components of the status record.
  - `BolOmsRequeueResultDto`: `requeued, mode, reason`.
  - Every one of these names appears in the UI spec fixtures (`outboundBolOmsStatus.spec.js` keys counted), and the component reads exactly these (`outboundBolDetails.vue` `omsSummary`, `omsFailedChunks`, `chunkLabel`, `confirmRequeue`).
- **Enum strings.**
  - API `State {NOT_SHIPPED, FAILED, PENDING, CONFIRMED, NO_RECORD}`, `NoRecordReason {EMPTY_BOL, PURGED, UNKNOWN}` and `Mode {REQUEUE, NONE}`: the UI and the fixtures use exactly these literals.
  - The UI pre-filters on `outboundBol.state ∈ {'CLOSED','TRANSFER'}`. This equals `WmsConstants.BillOfLadingState.CLOSED`/`TRANSFER` and the server's NOT_SHIPPED predicate (`BolOmsNotificationService:115-116`). `getBolDetails` puts `state` in the map.
- **NON_NULL effects.** `noRecordReason`, `legacyParcels`, `chunkCount` (NO_RECORD), `chunkIndex` (single row), `nextAttemptAt` and `reason` (REQUEUE) are **omitted** when null, not sent as `null`. The UI tolerates absence everywhere: `chunkIndex === null || === undefined`, `result.reason || 'Nothing to requeue'`, and `legacyParcels` is read only when `legacy` is true. Note that the controller unit test's MockMvc printed `"noRecordReason":null`. That output comes from the standalone test converter, not the production mapper.
- **Instant.** `nextAttemptAt` is an ISO string under the production mapper. The UI never reads it, so its format is not part of the contract.
- **URLs.** `BillOfLadingController` is `@RequestMapping("/v3/billOfLading")` (`:42`) with `@GetMapping("/omsNotificationStatus/{id}")` and `@PostMapping("/requeueOmsNotification/{id}")`. The UI calls `'/billOfLading/omsNotificationStatus/' + id` and `'/billOfLading/requeueOmsNotification/' + id` (`store/outbound/outboundBols.js:180,191`) against `baseURL …/v3` (`nuxt.config.js:99,201`). J5 pins both paths.
- **Status codes.**
  - **404**: an unknown BOL raises `EntityNotFoundException`, which `RestExceptionHandler:200-210` maps to a 404 ProblemDetail. The store resolves `null` and the row is hidden.
  - **409**: the controller catches `PessimisticLockingFailureException` and returns a 409 ProblemDetail. The store returns `{conflict:true}` and the component shows "Another requeue is in progress — refresh and retry".
  - **200 NONE**: rendered as `requeueMessage = reason`.

## 3. §0 affected sites

| # | Status | Evidence |
|---|---|---|
| P1 | VERIFIED | `BillofladingService.enqueueBolShippedNotification` (diff `+399-458`). It chunks when `REGULAR ∨ HUB_AND_SPOKE` and `parcelCount > k`. Every chunk row gets aggregate `BILL_OF_LADING_CHUNK`, id `bol.id×100000+i`, key `BOL-SHIPPED-<id>-C<i>of<n>` and lane CLUB. All payloads are serialized before the first enqueue. It throws when `size ≥ 100000` |
| P2 | VERIFIED | `runShippingPhase` calls the helper. TRANSFER_* stay one row (U6 `transferOffsiteAndIntracompanyAboveK_stayOneRow`) |
| P3 | VERIFIED (none) | The diff does not touch `finishTransfer` |
| P4 | VERIFIED | `ODS.maxAttemptsFor` is used by `isTerminal` and the exception branch |
| P5 | VERIFIED | `writeServiceLog` returns the id. `linkServiceLog` runs in its own try/catch, for `ORDER_BATCH_SHIPPED` only |
| P6 | VERIFIED | Two handlers, both `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING)` |
| P7 | VERIFIED (none) | No change to `resendMessage`. The audit sender `wms:requeue` is refused (U13 `auditRow_isNotResendable`) |
| P8 | VERIFIED | Distinct aggregate ids (I1). Regression classes are green |
| P9 | VERIFIED | `MS.createServiceLogInCallerTx`, `@Transactional(tenantTransactionManager, MANDATORY)` |
| P10 | VERIFIED (none) | `scripts/` is not in the diff. I11 pins the exclusion with a positive control |
| U1 | VERIFIED | `outboundBolDetails.vue`: status row, failed list, Requeue button and confirm dialog |
| U2 | VERIFIED | `getBolOmsStatus` and `requeueBolOms` in `store/outbound/outboundBols.js` |
| U3 | VERIFIED | `serviceLog.vue` `openDeepLinkedMessage()` from `mounted`, numeric-only. It adds a `facility` guard beyond the plan |

## 4. Acceptance criteria and §8 rows

### §7 ACs

| AC | Status | Evidence |
|---|---|---|
| AC-A | VERIFIED | U4 byte fixture, `closeBol_exactlyK_staysOneRow`, U5, U6. Mutation M3b turned U4 red (§4.1) |
| AC-B | VERIFIED | U12 `confirmedCountsPurgedSentRows` and `resendConfirmedCountsAsConfirmed`; I5 `resendWith2xxRedeliverIdReconciles` |
| AC-B1 | VERIFIED | U15 `entityDoesNotMapLastMessageId`; U11 `linkFailureIn2xxBranch_neverCallsMarkRetryOrMarkTerminal`. Mutation M9 turned it red |
| AC-C | VERIFIED | U10 (4 tests plus `bolShippedMaxAttempts_deployedValueIs29`). Mutation M2 turned 2 tests red |
| AC-D | VERIFIED | I4: flips only this BOL's terminal rows, attempts 0, `NEW_URL`, keys kept, neighbour untouched, second call NONE, exactly one audit row. I7 concurrent: one REQUEUE, one NONE, one audit row, counter +1. U13 `resendConfirmedRows_areNotRequeued` |
| AC-D2 | VERIFIED | U14 `lockTimeout_maps409` (mutation M7 red). I11 watchdog invisibility. U13 `auditRow_isNotResendable`. I10 `auditRowRollsBackWithCallerTx` and `withoutCallerTx_throwsIllegalTransactionState`. **Step 3 EXPLAIN:** VERIFIED by lead evidence (2026-10-16: c1wh 3.5 ms, WineCo 13.6 ms, PK range scan; both under 200 ms) |
| Steps 4 (PR), 6, 7, 8 | N/A | Sanctioned. Step 4's full `mvn clean verify` is the implementation lane's |
| Step 5 (UI) | VERIFIED (J1–J5) | 73/73 jest. The PR is not yet open (N/A) |

### §8 test rows

All rows below are VERIFIED. Every named test exists and passed in my runs above.

| Row | Evidence |
|---|---|
| U1–U3 | `BolShippedNotificationChunkerUnitTest`, all 7 tests, including `singlePalletOf1528Gives39Chunks` |
| U4–U8 | `$Sbdev3672ChunkedBolShippedNotification`, 9 tests. U8 uses the ListAppender WARN presence/absence |
| U9 | `BolShippedOmsChunkSizeSeedConsistencyTest#seedMatchesConstant` |
| U10, U11 | `OutboxDispatchServiceUnitTest` `:765-805`, `:854-898` |
| U12 | 10 named methods plus `unknownBol_isNotFound`. Reflection asserts the TM value and propagation for `status` (readOnly), `requeue` (REQUIRED) and `createServiceLogInCallerTx` (MANDATORY) |
| U13 | All 10 named methods, plus `requeueCounterIsPerCallAndInfoLineCarriesRows` (O1/O3) |
| U14 | `requeue_isPost`, `lockTimeout_maps409`, `nothingEligible_is200None`, plus `omsNotificationStatus_isGatedGet` and `_returnsStatus` |
| U15 | `OutboxMessageMappingUnitTest#entityDoesNotMapLastMessageId` |
| G1 | Two `row(...)` entries, `/v3/billOfLading/omsNotificationStatus/{id}` and `/v3/billOfLading/requeueOmsNotification/{id}`, mapped to `WEB_UI_VIEW_BILL_OF_LADING`. Full context: 5/5 |
| I1, I2 | `BolChunkOutboxClaimIT`, plus the control `sharedAggregateId_wouldWedgeSiblings` |
| I3 | `findsBothShapesOnlyForThisBol` |
| I4, I4b | `requeueFlipsOnlyTerminalRowsKeepsKeysAndWritesOneAuditRow`, `requeueUpdate_skipsRowsNoLongerTerminal` |
| I5 | All 4 methods |
| I6 | N/A, removed by D10 |
| I7 | `concurrentRequeue_oneRequeuesOtherReturnsNone` |
| I8 | `linkUpdateLeavesVersionAndModifiedAtUnchanged` |
| I9 | `OutboxMigrationV2240IT#addsNullableColumn` and `#seedIsIdempotent`. The class is renamed and split; the V2.2.40 version is sanctioned |
| I10 | `MessageServiceCallerTxIT`: 2 named tests plus the positive control `control_auditRowCommitsWithCallerTx` |
| I11 | `OmsEgressWatchdogQueryIT#requeueAuditRows_yieldZeroFindings`, with a URL-destination positive control |
| O1 | U13 `requeueCounterIsPerCallAndInfoLineCarriesRows` + I4/I7: `requeuedCount(...) - before == 1.0` |
| O2 | U11: `service_log_link.failed{process_type}` == 1.0 |
| O3 | U13 ListAppender on the INFO line |
| O4 | I4 audit fields: `N/A` / `REQUEUE` / `wms:requeue` / operator / answer JSON. I11 covers watchdog invisibility |
| J1–J5 | 73 jest tests. Each J row has its named `describe`. J5: `store/outboundBolsOmsStatus.spec.js:36,53` assert the exact relative paths |
| UI E2E table | N/A (manual) |

### §6 file list

**VERIFIED.**

- Every api row is present: `BillofladingService`, the chunker, `BillOfLadingWebServiceDto`, `WmsConstants`, `OutboxService`, `ODS`, `OMR`, `MS`, `BolOmsNotificationService`, `RestIdempotencyCleanupJob` (`safeOutboxRetentionDays(int)` is public static), the controller, `application.properties:245` (`=29`), the migration (**V2.2.40**, sanctioned; `SET LOCAL lock_timeout='5s'` with the explanatory comment, nullable `ADD COLUMN IF NOT EXISTS`, and an idempotent seed guarded on `(syskey, workstation='DEFAULT')`), `OmsEgressWatchdogQueryIT` and `MessageServiceCallerTxIT`.
- Files beyond the list, all implied by the design:
  - `BillofladingPositionRepository.existsTopLevelPallet`: the B-3 EMPTY_BOL predicate. It matches `runShippingPhase`'s classification at `BillofladingService.java:552-562`, and `BolOmsNotificationRowsIT#emptyBolPredicate_matchesRunShippingPhaseClassification` pins it.
  - `BolNotificationRowView`.
  - The two DTO records.
- The ui rows are all present.
- The docs row (Step 8) is N/A.

### 4.1 Mutation spot-runs

I ran 12 mutations, against 11 of the plan's targets plus a corrected M3. For each one I copied the file to `scratchpad/verify/`, mutated it, ran the test, and restored the file by `cp`. Every run printed `restored: True`, and the worktree was clean afterwards.

| # | Plan target | Mutation | Killing test (observed red) |
|---|---|---|---|
| M1 | K clamp at 60 | return `configured` when > 60 | U8 `chunkSize_above60_clampsTo60WithWarn:3966` |
| M2 | `maxAttemptsFor` type check | always `maxAttempts` | U10 `bolShippedChunkRow_retriesUntil29`, `bolShippedSingleRow_retriesUntil29` |
| M3 | chunk_* on ≤K path | set after serialization | **survived. This was my mutation's fault, not the test's:** the payload was already serialized, so the change was unobservable. Discarded |
| M3b | chunk_* on ≤K path | `dto.setChunkIndex(0); setChunkCount(1)` before serialization | U4 `closeBol_atOrBelowK_payloadIsByteEqualToTodaysFixture:3773` |
| M4 | resendConfirmed not excluded | eligible = terminal only | U13 `resendConfirmedRows_areNotRequeued:385` |
| M5 | audit row on 0 ids | removed the empty-return guard | U13 `concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter:437` |
| M6 | MANDATORY → REQUIRES_NEW | propagation swap | U12 `MessageServiceUnitTest.createServiceLogInCallerTxIsMandatory:538` |
| M7 | controller 409 mapping removed | catch `IllegalStateException` instead | U14 `lockTimeout_maps409:934` (`CannotAcquireLockException` escapes) |
| M8 | PURGED +1 day removed | `minusDays(retentionDays)` | U12 `purged_onlyBeyondRetentionPlusOneDay_boundaryIsUnknown:299` |
| M9 | link outside its own try | link call moved before the try | U11 `linkFailureIn2xxBranch_neverCallsMarkRetryOrMarkTerminal:882` |
| M10 | audit sender = instance name | `getWmsInstanceName()` | U13 `auditRow_isNotResendable:496` and `auditRow_destinationNA_…:473` |
| M11 | D-i UPDATE without `status='FAILED_TERMINAL'` | removed the guard line from the native SQL | I4b `requeueUpdate_skipsRowsNoLongerTerminal:322`; I7 also red (`:361`) |

The executor ledger claims the targets I did not run: `^2` regex → I5, entity field → U15, audit destination → I4/I11, and MANDATORY → REQUIRED → I10. I did not re-run them. Each named test exists, passed, and on reading reaches the line in question:

- I11 builds its rows from `BolOmsNotificationService.AUDIT_DESTINATION`.
- U15 reflects over the entity's fields.
- I5 has both a 2xx and a 5xx resend case.

## 5. Findings (no blockers)

- **L1 (Low): orphaned javadoc.** The new helper `enqueueBolShippedNotification` and its javadoc were inserted **between** `runShippingPhase`'s existing javadoc (`BillofladingService.java:~431-443`, "closeBOL's work on a locked … ShippingPhase#bol()") and its signature. That javadoc is now a dangling block in front of the helper's own, and `runShippingPhase` has none. **Fix:** move the helper above the old javadoc, or below `runShippingPhase`.
- **L2 (Low): misplaced tests.** The five new SBDEV-3672 controller tests (`BillOfLadingControllerUnitTest:910-956`) sit inside the `@Nested ExportOutboundBolBulk` class. They run (22 in that nested class) and pass, but they report under the wrong group. **Fix:** move them into their own `@Nested`.
- **Note (no action):** the production mapper omits null fields (NON_NULL), so the wire never carries `"noRecordReason": null`. The UI handles both absent and null. A future spec fixture that asserts `=== null` on the store result would diverge from the wire.

## 6. Overall

**PASS.**

- Every in-scope §0 row, AC and §8 row is VERIFIED with fresh output, or N/A where sanctioned.
- The cross-repo contract matches on names, nesting, enum strings, URLs and status codes.
- Every mutation I ran was killed by its named test. The one survivor (M3) was my own ineffective mutation, and its corrected form M3b was killed.
- Two Low findings remain (L1, L2). They do not block, but under the fix-every-finding rule they belong in the executor's pass.

---

## Docs lane review (2026-10-16)

**Scope.** I reviewed the 5 docs listed in `SBDEV-3672-evidence/docs-update.md`.
- **Code.** Every cite was checked with `git show 1866ab66:<path>` (wms2-api) and `git show 63b0a89:<path>` (wms2-web-ui). The extracted files are in `scratchpad/verify/at1866/`. I did not run Maven and did not run any git command that writes in either worktree.
- **Limit on item 3.** No pre-edit copy of these docs exists: sbdocs is not in git, and `~/.claude/file-history` holds no backup of them. So the check for unwarranted rewrites is judged against the ledger and against current code, not against a textual diff.

**Verdict: PASS, with 3 Medium and 4 Low findings, all about markers or cite precision.** No High: every behavioural claim I checked matches the code.

### 1. Cites

Every `file:line` cite resolves at `1866ab66` / `63b0a89` and says what the doc claims, except the Low items in §5.

- **`BillofladingService`**: `:444` `runShippingPhase` · `:778-784` skipped_empty (the `if` is at 779) · `:786` helper call · `:837` helper · `:840`, `:846` type and parcel test · `:844` `resolveChunkSize` · `:852` id-span throw · `:885-889` chunk builder · `:837-896` whole helper (integration map).
- **Chunker** `:38,46,58,99`. **`WmsConstants`** `:1407-1408`, `:1412-1413`. **DTO** `:46,49`.
- **`OutboxDispatchService`**: `:107` `@Value(...:29)` · `:317-331` `linkServiceLog` · `:333-342` `isTerminal`/`maxAttemptsFor` (`:339-342` in the catalogs).
- **`BillOfLadingController`**: `:616-621`, `:628-642`, `:617`/`:629` (the mappings).
- **`OutboxMessageRepository`**: `:89-100` link · `:109-120` fenced FROM/WHERE · `:138-142` `resendConfirmed` · `:175-188` guarded UPDATE, which also carries `process_type`.
- **`BolOmsNotificationService`**: `:62-69` audit constants · `:152-153` confirmed · `:167-228` requeue · `:210` audit write · `:222-225` after-commit log and counter · `:237-246` `noRecordReason` · `:276` `redactedLastError` (`<oms-url>`, 300 chars) · `:290` legacy, which uses `CHUNK_SIZE_CEILING`=60 (so the ledger's "code ≠ plan" claim is true).
- **`outboundBolDetails.vue`**: `:81` row · `:197` tooltip · `:229` summary · `:296` 409 text.
- **`OutboxDispatcherJob`**: `:62-86` and `:136` (unchanged vs develop).
- **Other**: lock ids 100008/100009 (`AdvisoryLockService:262,269`) · `application.properties:249` `=29` · the V2.2.40 seed (`client_id=0`, `WHERE NOT EXISTS`) · `OutboxMessage.java` with no `last_message_id` field.

### 2. Marker check (`⏳ pending-merge(SBDEV-3672)`)

- **Spelling.** Every marker in all 5 docs uses the exact form: workflow 26, integration map 3, sysprop 6, jobs 4, entity 2. There are no variants.
- **Coverage.** Merged behaviour is correctly left unmarked: the outbox enqueue inside the close tx and the dispatch after commit (SBDEV-2221, workflow `:44` first sentence, `:115`, `:384`), and the DEFAULT/CLUB lanes (jobs `:408` first sentence).
- **Gaps.** Several unmerged sentences carry no marker; see §5.

### 3. Rewritten without cause

- **None found.** The §1 shipped bullet, the §3 diagram line, the §6.5 rewrite and the §7 SHIPPED row each replaced text that SBDEV-2221 had already made false (see §4).
- **Correctly left alone.** The pre-existing stale items the writer found are listed in docs-update §8, not silently "fixed": dispatcher cadence `*/3` vs the doc's `*/15`, batch-size 25 vs 10, and integration-map `:82`.

### 4. The SBDEV-2221 staleness claim

**TRUE, so the fix is not a regression.**
- **The change.** `6076743b` ("SBDEV-2221 transactional outbox pilot (BillofladingService.closeBOL)", 2026-05-17, merged to develop by `4e06a502` on 2026-05-18) deleted `omsNotificationService.sendAfterCommit(urlPath, payload, ORDER_BATCH_SHIPPED)`, which sat at line 656 of the parent. It replaced the call with `outboxService.enqueue(...)`.
- **On develop today.** `origin/develop` `BillofladingService` contains no `sendAfterCommit`. The shipped enqueue is at `:799-800`, and `:650-656` is the pallet loop.
- **Conclusion.** The doc's `sendAfterCommit` snippet and its "closeBOL (line 653)" cite were therefore stale from 2026-05-18, before the doc's own `last_verified: 2026-09-24`.

### 5. Findings

- **M1 (Medium), workflow `:331`, sentences 2–3: no marker.** "The service reads both row shapes through one native query fenced on `process_type`…" and "'Confirmed' means OMS answered HTTP 2xx…" describe the unmerged status endpoint. **Fix:** add the marker to each.
- **M2 (Medium), workflow `:349`, last sentence: no marker.** "The link is the native column `outbox_message.last_message_id`, written by the dispatcher…" comes after the paragraph's only marker. That column and its write are unmerged (V2.2.40). **Fix:** add the marker.
- **M3 (Medium), workflow `:315`, last two sentences: branch-only symbols and line numbers with no marker.**
  - **What is merged.** The paragraph's merged behaviour (SBDEV-2221 outbox, SBDEV-2737 empty skip) correctly has no marker.
  - **What is not.** "Otherwise `:786` calls `enqueueBolShippedNotification` (`:837`)" names a helper that does not exist on develop.
  - **The line numbers.** `:444`, `:778-784` and `:786` are branch numbers; develop has the skip and enqueue at `~:779-806`. A reader on develop lands on the wrong lines.
  - **Fix.** Mark that sentence, and note that the paragraph's cites are at `1866ab66` (the italic note at `:313` says so, but only for "citations", not for the symbol).
- **L1 (Low), workflow `:356`, `:357`, `:358`, `:362`+list `:364-365`, `:367`, `:371`: one trailing marker per multi-sentence paragraph.** Under a strict "every sentence" reading each needs its own marker; under paragraph scope they are fine. **Fix:** decide the convention and apply it.
- **L2 (Low), workflow `:349` `(:226)`: cite names half the condition.** It cites the "messagePresent and `WEB_UI_VIEW_MESSAGES`" condition, but `:226` is `canViewMessages()` only. The conjunction is at `outboundBolDetails.vue:102`. **Fix:** cite `:102` (with `:226`).
- **L3 (Low), workflow `:353` `(:118)`: cite points at the button text.** "shows when `failed > 0`" cites `:118`, which is the button text; the `v-if="omsStatus.failed > 0"` is at `:109`. **Fix:** cite `:109`.
- **L4 (Low), workflow `:331` `BolOmsNotificationService.java:115`: cite points at the caller.** It is cited for the `process_type` fence, but `:115` is the `status()` signature. The fence is `OutboxMessageRepository.java:112`, already cited alongside it (`:109-120`). **Fix:** drop `:115` or swap it for `:126`, the call.
- **Info, no action.** The workflow doc still has other branch-stale line cites outside the edited sections (§3 `closeBOL [line 277-699]`, §8 `finishTransfer` `:898`). These were not touched and are out of scope; the §13 row correctly says "other sections not re-verified".

---

## Docs re-check (057d0e3b)

**Scope:** `wms2-bol-truck-loading-workflow.md` §6.5, doc lines 311–371. Cites were read with `git show 057d0e3b:<path>` (api) and `63b0a89` (ui); no Maven, no git writes.

**Verdict: PASS. All 7 earlier findings are fixed, all 8 moved cites are correct, and the redaction text matches the code. One new Low item (R1).**

### 1. Earlier findings

| Finding | Status | Evidence |
|---|---|---|
| M1 | fixed | `:331`: the `process_type`-fence sentence and the "Confirmed means 2xx" sentence each carry a marker |
| M2 | fixed | `:349`: the `last_message_id` sentence is marked |
| M3 | fixed | `:315`: the sentence now says `enqueueBolShippedNotification` exists only on the branch, that the line numbers are at `057d0e3b`, and that develop has them at about `:779-806`; it is marked. The SBDEV-2221 and SBDEV-2737 sentences are merged behaviour and correctly stay unmarked. `BillofladingService.java` is identical at `1866ab66` and `057d0e3b` (the diff touches only `BolOmsNotificationService`, `OutboxDispatchService` and the watchdog README), so its `:444/:778-784/:786/:837` cites still hold |
| L1 | fixed | §6.5.2–6.5.5 now carry one marker per claim sentence |
| L2 | fixed | `:102` (`canViewMessages && chunk.messagePresent`) with `:226` |
| L3 | fixed | the button is cited at `:118` and its `v-if="omsStatus.failed > 0"` at `:109` |
| L4 | fixed | now cites the `findBolNotificationRows` call at `:131` at `057d0e3b` |

### 2. Moved `BolOmsNotificationService` cites at `057d0e3b`

All 8 match:

| Cite | What is there |
|---|---|
| `:131` | `findBolNotificationRows(bolId)` |
| `:161-162` | `confirmed = chunkCount - pending - failed`, then the state precedence |
| `:246-255` | `noRecordReason` |
| `:289` | `redactedLastError(String, String omsHost)` |
| `:176-237` | `@Transactional` … `requeue` … the return |
| `:62-69,219` | the audit constants and `createServiceLogInCallerTx` |
| `:231-234` | `afterCommit` log and counter |
| `:319` | `legacyParcels` |

The unmoved cites were also checked:
- `OutboxDispatchService` `:107`, `:317-331` and `:333-342` hold at `057d0e3b`. The only hunk there is `@@ -323,9 +323,9`, an in-place comment rewording.
- The `.vue` cites hold at `63b0a89`.

### 3. Redaction description

It matches the code (`:289-298`, host lookup `:302-310`):
- First `URL.replaceAll("<oms-url>")`.
- Then, if the host is not blank, `Pattern.quote(omsHost)` with `CASE_INSENSITIVE` is replaced by `<oms-host>`.
- Then `abbreviate(…, 300)`.
- The host is `URI.create(<current WEBSERVICE_ORDER_BATCH_SHIPPED sysprop>).getHost()`, and `""` when the value is unparseable.
- So the doc's caveat holds: a bare host from an endpoint configured earlier is not redacted.

### 4. Markers

§6.5 carries 50 markers, all spelled exactly `⏳ pending-merge(SBDEV-3672)`. The doc has 29 marked lines. Every claim sentence about unmerged behaviour is marked. Correctly unmarked:
- the SBDEV-2221/2737 sentences in `:315`;
- the context sentence in `:319` ("OMS costs about 0.19 s…");
- the "(`:246-255`.)" cite fragment at `:349`.

### 5. New finding

- **R1 (Low), `:371`: an imperative about the unmerged feature has no marker.** "**Do not requeue it.**" Under the "one marker per claim sentence" convention adopted in docs-update §10 it should carry one.
