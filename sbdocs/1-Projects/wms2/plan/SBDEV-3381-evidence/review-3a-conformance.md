## Verification Report

**head:** `723e1ba0267ff93d689a0a1d3a154f692ab40419` (worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3381`). It contains `origin/develop` `91789cc7`, which I confirmed after a fresh fetch. Three commits: `373a31c0`, `babd1b88`, `723e1ba0`.

### Verdict
**Status**: PASS (on whether the code matches the plan)
**Confidence**: high
**Blockers**: 0

### Evidence (all fresh, run by me at HEAD)
| Check | Result | Command/Source | Output |
|---|---|---|---|
| Build | pass | `mvn -o -q clean compile` | `COMPILE_EXIT=0` |
| Unit tests | pass | `mvn -o -q test -Dtest='<the 10 classes>'` | **197 tests, 0 failures, 0 errors, 0 skipped**, read from 20 surefire XML files (nested classes included). `CancellationReversalServiceUnitTest` 88, `FunctionGuardArchTest` 26, `UserControllerPublicHandlerUnitTest` 15, `PendingReversalReconciliationJobUnitTest` 13, `UtilRestControllerSeedUnitTest` 10, `UtilRestControllerUnitTest` 27 (nested), `FunctionGuardMockMvcUnitTest` 7, `CancellationWaiveContractUnitTest` 6, `CancellationLogEntryDtoSerializationTest` 4, `OrderCancellationControllerUnitTest` 1 |
| Integration tests | pass | `mvn -o verify -Dit.test='CancellationReversalLockClearIntegrationTest,CancellationWaiveMigrationIT,PendingReversalOlderThanIntegrationTest' -Dtest=ZzzNone …` | 26 tests, 0 failures, 0 errors, BUILD SUCCESS. Split: LockClear 18, MigrationIT 3, OlderThan 5. `grep` of `target/failsafe-reports` shows all 4 T18 variants, T18b, the 4 T22 tests and T15 actually ran. The `[ERROR] An error has occured` in the log comes from the springdoc plugin (`ConnectException`), not from a test |
| Flyway collision | pass | `git fetch`, then `ls-tree` over 346 `origin/*` refs | The highest version on any remote ref is `V2.2.33__stockrecord_view`, which also shows the sweep works. No `V2.2.34` exists elsewhere |
| Placeholders | pass | diff grep for `TODO\|FIXME\|@Disabled\|assume*` | 0 hits |
| Full suite | not run | — | You told me not to run it. The orchestrator's full run was at `373a31c0` and I did not re-verify it |

### §0 in-scope rows
| # | Status | Evidence |
|---|---|---|
| 1 | VERIFIED | `OrderCancellationController`: `@PostMapping("/{customerOrderId}/waive") @RequiresFunction(...MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL)`. The class gate is unchanged |
| 2 | VERIFIED | The old inline outbox block was replaced by `enqueueReversalCompletedIfClosed(coId)`. The trigger is still level-based (a check on `findPendingReversals()`, with no edge check) and suppression was added |
| 2a | VERIFIED | The restore predicate gains `&& (waivedShareUnknown.contains(..) \|\| residue.getAmount().compareTo(waivedShare.getOrDefault(.., ZERO)) > 0)`. It is ANDed onto the existing terms |
| 2b | VERIFIED | `recoverPicktoStockunitId(log, caller)` is extracted and called by both complete and waive. It returns whether it recovered an id |
| 3 | VERIFIED | `toDetailDto` sets `reversalWaived`, `waiveReason`, `waiveStockReturned` and `waiveLockRetained`, and computes the last one only when `log.isReversalWaived() && picktostockunitId != null` |
| 4 | VERIFIED | Entity: `@Column(name="reversal_waived", nullable=false) private boolean reversalWaived = false;`, `reversal_waive_reason` TEXT, `Boolean reversalWaiveStockReturned` |
| 5 | VERIFIED | The DTO adds 4 fields, with boolean and `Boolean` types as specified |
| 6 | VERIFIED | `CancellationWaiveRequest { List<Long> positionIds; String reason; Boolean stockReturned; }` |
| 7–9 | VERIFIED | Finders untouched (no repo file in the diff). Waive locks through `findPendingReversalsForUpdateByCustomerorderId(coId)` |
| 10 | VERIFIED | `scanTote` is not in the diff |
| 11 | VERIFIED | New sentence is exactly `"Complete them on the mobile Cancellation screen, or have an outbound manager waive them there (Waive)."`. The tail text gains `waived rows carry reversal_waived=true and are excluded`, placed inside the existing parenthesis |
| 12 | VERIFIED | The partial index is untouched |
| 13 | VERIFIED | `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL = "MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL"` |
| 14 | VERIFIED | `grantFunction(...WAIVE..., role_outbound_manager, role_super_admin);` with a Q5 comment |
| 15 | VERIFIED | `V2.2.34__cancellation_reversal_waive.sql` matches the §3.6 SQL statement for statement: `ADD COLUMN IF NOT EXISTS` ×3, a CHECK guarded by `pg_constraint`, a `WHERE NOT EXISTS` function seed and a `WHERE NOT EXISTS` grant |
| 16–17 | VERIFIED (excluded) | `AccessAuditService` is not in the diff |
| 18 | VERIFIED | `audit-access-invariants.sql` adds `('step5_WAIVE_CANCELLATION', 'MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL', ARRAY['outbound-manager','super-admin'])` |
| 19 | VERIFIED | The name falls outside `MOBILE_UI_VIEW_%` |
| 20 | VERIFIED | `FunctionGuardInterceptor` is not in the diff |
| 21 | VERIFIED | `REVIEWED_METHOD_LEVEL_OVERRIDES` gains `"OrderCancellationController#waiveReversal"` |
| 22 | VERIFIED | `.hasSize(4)`, message "four mobile entries" |
| 24–28 | VERIFIED | See T11 and T13–T16 below |
| 35 | VERIFIED | New `seedWaiveOrder()` builder. It does not reuse the `@BeforeEach` order |
| 33 (docs) | MISSING (outside this lane's code scope) | `wms2-cancel-cascade-workflow.md` has 0 mentions of "waive" and `wms2-function-to-docs-map.md` has 0. §5.2 lists "Update the docs (§4)" as a step before the PR |

### §3 Design
| § | Status | Evidence |
|---|---|---|
| 3.1 | VERIFIED | Validation order and messages match: `"positionIds required"`, `"reason required"` (`isBlank`), `"reason too long (max 500)"` (checked on the trimmed text, `>`), `"stockReturned required"` |
| 3.2 | VERIFIED | Steps: validate → FOR UPDATE lock → `all` loaded after the lock, with an unknown id throwing `"position X is not on order Y"` → an empty target list returns `detail(coId)` → pre-validate (only write is the recovery save) → write → shared enqueue → exact log line `waiveReversal order={} positions={} stockReturned={} lockCleared={} lockRetained={} by={}`. `toteState` has four states and fails closed: Tote plus a matching label is ON, Package is PARCEL, any other known type is OFF, and a null id, missing view, null type, missing type row, label mismatch or null `toteLabelId` is UNKNOWN. The refusal `SHIPPED \|\| (hasStock && (lock==100 \|\| state!=OFF))` reproduces every `stockReturned=true` cell of the table. Clears happen only at lock 100, only when every target on the stock unit is ON, only for units not recovered in this call, and only when `ownsAllStock` holds |
| 3.3.1 | VERIFIED | Single builder. It checks for remaining pending rows first, then suppression (`anyMatch(isReversalWaived && FALSE.equals(stockReturned))` over `findByCustomerorderId`, logged at `LOG.info`), then the blank-sysprop `LOG.warn` and skip. Payload construction is unchanged |
| 3.3.2 | VERIFIED | `waivedShare` and `waivedShareUnknown` are built once from `findByCustomerorderId(coId)`, before the movement loop, and not from `logs` |
| 3.4 | VERIFIED | As rows 3–5. `waiveLockRetained = su!=null && lock==100 && amount>0 && toteState!=OFF` |
| 3.5 | VERIFIED | All five places are covered: constant, initDB, V2.2.34, `@RequiresFunction`, SET 9. The arch pins were updated in the same commit (`373a31c0`) |
| 3.6 | VERIFIED | As row 15 |
| 3.7 | VERIFIED | As row 11 |

### §7.1 tests and the §7.2a amendments
| Row | Status | Test and what it asserts |
|---|---|---|
| T1 | VERIFIED | `waiveReversal_shouldStampWaivedRowsAndNotTouchStock_whenLiveNirwanaCase`: row stamped, waived, reason trimmed, stockReturned kept; `stockunitRepository.save` and `transferStock` never called; lock 2 unchanged |
| T2 + amendment | VERIFIED | `…ClearPickedForGoodsout_whenOnToteAndOwned` (case ii, 100→0, no transfer) and `…whenEmptyOnToteAndNotRecovered` (i′, amount 0, ON, cleared) |
| T3 + amendment | VERIFIED | Amount above share → kept, and `waiveLockRetained=true`. Amount equal to share → cleared. An already-waived sibling counts. The null fixture is A(null)+B(3) waived in the same call on SU 3 → kept. A unit recovered in this call → kept and the row closed. Extra tests confirm that targets on another stock unit, and waived rows on another stock unit, are not counted. The fixture keeps `W_PUL_ID` different from the unit-load id, so an "id-comparison onTote" mutant would be caught |
| T4 | VERIFIED | `RefusalCase` has 9 cases: ii-ON, ii′-ON, ii′-PARCEL, 4 kinds of ii′-UNKNOWN, ii″-OFF at 100, SHIPPED. `verifyWaiveWroteNothing` checks that neither save is called, nothing is enqueued and nothing is transferred. The message must contain the position, SU id, lock text and `"its container reads <STATE> "` |
| T5 | VERIFIED | `ForeignLockCase` has 13 cases: QUALITY_FAULT, ON_HOLD, 403, 404, 100 with OFF, PARCEL or UNKNOWN (two kinds), and i′ at 100 with UNKNOWN, OFF or PARCEL. No save, lock unchanged, row closed. Every OFF and PARCEL unit load carries the log's label, which catches a "label-only" mutant |
| T5b | VERIFIED | `waiveReversal_shouldRefuse_whenClubUuidToteLabel`: a UUID label with a Tote labelled `C1-0063`, QUALITY_FAULT, amount 1, `true` → `BusinessException` and nothing written |
| T6 | VERIFIED | Waive payload, URL and aggregate type equal complete's captured values, with exactly 1 enqueue. The `false` variant enqueues nothing. A further test checks that the payload has an explicit empty `positions: []` |
| T7 + amendment | VERIFIED | The first waive closes the last row with `true` (control: 1 enqueue). The second waive: enqueue, `logRepository.save` and `stockunitRepository.save` are never called, and the first reason is kept |
| T8 | VERIFIED | Parameterized over 7 inputs: blank, null, 501 characters, empty ids, null ids, null stockReturned, unknown id. A 500-character reason with surrounding whitespace is accepted |
| T9 | VERIFIED | `InOrder`: the FOR UPDATE finder runs before `save(log)` |
| T10 | VERIFIED | `OrderCancellationControllerUnitTest`: an omitted `stockReturned` arrives as `null`; `false` binds as `Boolean.FALSE` |
| T11 | VERIFIED | A VIEW-only holder gets 403 on `/waive` and 200 on `/complete` (positive control). A waive holder gets past the gate (200 sentinel) |
| T12 | VERIFIED | The AC-4b set and `hasSize(4)` both pass |
| T13 | VERIFIED | `containsExactly("outbound-manager","super-admin")`, with a harness control on `MOBILE_UI_VIEW_CANCELLATION` |
| T14 | VERIFIED | Exactly one migration seeds the constant, and it starts with `V2.2.34__`. Its role set (comments stripped) equals initDB's, and the initDB set is checked to be non-empty |
| T15 | VERIFIED | The waived row is excluded, and an old row that was never waived is still returned (positive control) |
| T16 | VERIFIED | The alert text contains "waive" and "outbound manager" (case-insensitive) |
| T17 + amendment | VERIFIED | Columns absent at 2.2.33. At 2.2.34: boolean, NOT NULL, `DEFAULT false`, and an existing row reads false. Exactly 1 function row and the role set equals the expected set. After the grant table's uniqueness is dropped and the script is re-applied, counts are still function=1 and grants=2. The CHECK fails with SQLSTATE `23514` |
| T18 + amendment | VERIFIED | Positive control: complete alone gives outbox 0, then 1. The 4 variants cover waive-first and complete-first, each with `stockReturned` true and false. The waived stock unit is 0 / 100 / ON; the completed one is a separate unit, 3 / 100. Outbox after closing is 1 (or 0 for `false`). After the extra complete: row still waived, stamp unchanged, unit amount and lock unchanged, outbox 2 (or 0 for `false`). Counts are filtered by `aggregate_id` |
| T18b + amendment | VERIFIED | The unit load id is set on the pickingorder_unitload, the log's `picktostockunitId` is null, and a pick line holds the item. A precondition checks the recovery resolves. The waive (ii, `true`) is refused, and a DB re-read shows `picktostockunit_id` still NULL, the row pending and the lock still 100 |
| T19 / T19b | VERIFIED | A complete retry on a closed order re-enqueues with no transfer and no save. With a `false`-waived row present, it does not enqueue |
| T20 | VERIFIED | Complete closes the last row: no enqueue after a `false` waive, exactly one after a `true` waive |
| T21a | VERIFIED | All 4 keys appear in the JSON with the right values (`waiveStockReturned:false` is present, not dropped) |
| T21b | VERIFIED | ON, PARCEL and UNKNOWN → true; OFF → false; a non-waived row → false; fields mapped. A unit with amount 0 → false |
| T22 + amendment (c)(d) | VERIFIED | IT lane, base: waive A(1) `false` keeps the lock, then complete B(2) → residue 1 ends at lock 0. Variant with A null → 100. (c) A1(null)+A2(1) → 100. (d) A(null)+B(3) → not 100. The unit lane has matching T22a–d |
| §7.3 | VERIFIED | Both by-design reds were updated in `373a31c0` |

### §6 "What does NOT change"
No violations found. The diff doesn't touch `transferStock`, the movement loop, the 100→0 clear and flush, the finders or the index, `scanTote`, `detail`'s query, `GUARDED`, `GATED_WORKFLOWS`, SET 4, `removeLock`/`OPERATOR_REMOVABLE` or anything Keycloak. The residue save is still unflushed, because `waivedShare` is read before the loop. Complete's level trigger is still in place, and T19 and the T18 re-send pin it.

### Deviations
- **(a) A real `los_sysprop` row instead of `@MockitoSpyBean`: acceptable.** It follows the documented `UnfinishedStubbingException` precedent, removes the row in `@AfterEach`, and the T18 positive control (outbox = 1) shows the fixture can enqueue, so the zeros in the `false` variants mean something.
- **(b) Ownership rule also applied to the (i′) release: acceptable, since it is stricter.** For an empty unit the amount check always passes, so the only extra effect is to decline when a contributor's `amountPicked` is null, and it also declines when the unit's amount is null. Side effect: that empty unit stays at lock 100, and `waiveLockRetained` does not flag it because its amount is 0. Live exposure is 0 rows (null `amount_picked` measured 0 on c1wh and Hydra PRD).
- **(c) Release decisions made before the rows are stamped: acceptable, and needed.** `targets` and `all` share the same managed instances. If the rows were stamped first, every target would also count as "already waived" and its share would be summed twice, which would make the rule more permissive. Writes still go log rows first, then stock units, as the plan says.
- **(d) Log labels renamed to the enclosing method: acceptable.** `git grep` finds no reader of the old `completeReversal: sysprop` or `completeReversal: recovered` strings in src, tests or sbdocs. The new labels follow the repo rule that a log label must not carry another method's name.

### Gaps
- The docs update in §4 (cancel-cascade workflow waive section, function-to-docs-map §9) has not been done, and §5.2 requires it before the PR. Risk: low. Suggestion: do it in the verify-docs step.
- I did not re-run the full suite at HEAD, per your instruction. The orchestrator's full run was at `373a31c0`, and `723e1ba0` changes main code (a label and a redundant null guard). My targeted runs cover every class that touches it. Risk: low. Suggestion: the executor's pre-PR `mvn clean verify` closes this.
- I did not re-run the PIT result (90%) or the 13/13 hand mutants. I did check that fixtures exist to catch each named mutant (id-comparison, label-only, Package treated as OFF, `waivedShare` summed from `logs`). Risk: low.
- T22(d) asserts `isNotEqualTo(100)` rather than an exact lock. That is enough to catch the standalone-OR mutant it targets. Risk: low.

### Recommendation
APPROVE. The implementation matches every in-scope §0 row, §3.1–3.7, T1–T22 and the §7.2a amendments. Fresh compile, 197 unit and 26 IT tests are green, nothing in §6 changed, and the four deviations are either safe or stricter than the plan. The remaining work (docs update, full-suite run) belongs to later executor steps and doesn't change this verdict.
