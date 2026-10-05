# SBDEV-2624 wms2-api review round 1 fixes

- Worktree: `.claude/worktrees/wms2-api/SBDEV-2624`
- Base: `086cb309`. New HEAD: **`02a20c56`**
- Commits:
  - `147e1df2` D-M3
  - `02a20c56` Lows
- Status: not pushed, not rebased (ahead 10, behind 13), `git status` clean.
- Inputs: `review-impl-wms2-code.md`, `review-impl-wms2-security.md`, `conformance-wms2.md` Gaps, plan §10 D-M3.
- Toolchain: JDK 21.0.8. Before every Maven run, `pgrep -fl "surefire|failsafe|plexus-classworlds"` was empty. Runs were sequential and none used `&`.

## Findings → fix → test → mutant

Every mutant was applied to a copy, run, and restored from `/tmp/sbdev2624-r1/<name>.orig`. Each restore was `cmp`-verified. A no-op control mutant (S0) stayed green (36/0/0), which shows the harness does report survivors.

| Finding | Fix | Test | Mutant → result |
|---|---|---|---|
| **D-M3** / code M1 / security M1: rename by id without previous_sku | `rename()`: `previousSku == null \|\| !oldCode.equals(previousSku)` → 108 `"item_id=X is C, expected previous_sku (none sent)"`, WARN `SKU_RENAME_PRECONDITION`. `SKU_RENAME_BY_ID_RECOVERY` removed (0 hits in src/main) | unit `upsertAll_idHitWithoutPreviousSku_rowAtOtherCode_throws108`; IT `update_byFacilityItemIdWithoutPreviousSku_rejected` | S1 / I1 "by-id recovery" → KILLED in both lanes, own message |
| **D-M3** stale sku lookup (code M1 #1/#2/#3) | `upsertAll`: when `via == sku` and the reloaded `item_nr != sku`, set `row = null` (WARN `SKU_RENAME_STALE_LOOKUP`) and fall to the uncached re-check by code | unit `upsertAll_staleSkuLookup_isDiscardedNotRenamed`, `upsertAll_sameBatchRevert_doesNotRenameBack`; IT `update_staleCachedSkuHit_isNotARename` (warm cache, rename behind it, `{sku:B}`) | S2 / I2 "trust a stale sku hit" → KILLED (unit 3 reds, IT 1) |
| **D-M3** exact via (code L8b) | The controller records the step in `viaByClient` (new `upsertAll` parameter). `previous_sku == sku` is recorded as the sku step (step 2 is skipped). A missing entry defaults to sku | controller `update_idHit_recordsViaFacilityItemId`, `update_previousSkuHit_recordsViaPreviousSku`, `update_previousSkuEqualsSku_recordsViaSku`; unit `upsertAll_foundRowWithoutRecordedVia_defaultsToSkuStep`, `upsertAll_rename_logsRecordedVia` ×3 | C2, C3, C3b, S3, S7 → all KILLED |
| **D-M3** / code L2: blank previous_sku | `normalize()`: blank after trim → `null` | `update_blankPreviousSku_normalizesToNull`, `update_paddedPreviousSku_isTrimmed` | C1 "trim only" → KILLED |
| **D-M3** redefined AC-2a | IT `update_byFacilityItemIdWithPreviousSkuMatchingRow_renames` (id + `previous_sku=D`, row at D → renamed, 200); unit `upsertAll_idHitWithPreviousSkuMatchingRow_renames` | — | — |
| Conformance gap: D-M2 IT twin | — | IT `update_previousSkuEqualsSku_rowAtOtherCode_rejected` (422, exact 108 text, X unchanged, no new row) | I3 "CAS skips when previous_sku == sku" → KILLED |
| Conformance M12 attribution | (a) The shape test pins `lower(itemdata) = lower(:oldItemNr) AND itemdata = :oldItemNr`. (b) AC-10a asserts `(C,"a")==1` first | `StockrecordRenameQueryShapeUnitTest`, AC-10a | U "drop the exact conjunct" → shape test KILLED (was GREEN); I5 → IT KILLED at **its own** message `'drop the exact conjunct'` |
| code L1: every DIVE reported as duplicate | `translate()`: 105 only when the cause chain has SQLState `23505` or a Hibernate `ConstraintViolationException` named `uk3l3dgof3l6mc1dl7s3lmida65`. Anything else is **rethrown unchanged**. That is the pre-ticket behaviour (`@ExceptionHandler(Exception)` → 500), and I picked it because a neutral 422 would still claim a client error for what may be a schema or server fault. The tx still rolls back (RuntimeException) | `upsertAll_nonUniqueIntegrityViolation_isNotReportedAsDuplicate` ×5: 23505, constraint name, 22001, 23503+other name, no cause | S5a (every DIVE → 105), S5b (drop SQLState arm), S5c (drop name arm) → all KILLED |
| code L3+L4, security I3: duplicate (client, sku) | `rejectDuplicateKey` in create and update, keyed `List.of(client_id, sku)` → 422 **105** `"duplicate value sku B found in request for client C"`. I used 105 because its text says exactly what is wrong (a duplicate value inside the request); FIELD_MALFORMED_FORMAT or FIELD_NOT_SET would misdescribe it, and 105 is not an OMS resend marker | `update_duplicateClientSku_rejected`, `create_duplicateClientSku_rejected`, `update_sameSkuTwoClients_accepted` | C4, C4b "key on sku alone" → KILLED |
| security L3: several renames per request | update: count DTOs with `previous_sku != sku`. A second one → 422 **103** `"field previous_sku has wrong format for request: one rename per request, found a second for sku D"`. After D-M3 every rename carries previous_sku ≠ sku, so this counts an exact upper bound before any lock is taken | `update_twoRenames_rejected`, `update_oneRenamePlusPlainEdits_accepted` | C5 (`> 2`), C5b (count every previous_sku) → KILLED |
| security L4: log forging | `rejectControlCharacters` in create, update and delete. ISO control characters in `sku` and `previous_sku` → FIELD_NOT_SET. The second argument is fixed so the value is never echoed. **Deviation:** `sku_name` allows TAB, see below | `update_controlCharacterInSku_rejected`, `…InPreviousSku…`, `create_lineBreakInSkuName_rejected`, `update_tabInSkuName_accepted`, `update_tabInSku_rejected`, `delete_controlCharacterInSku_rejected` | C6, C6b, C6c, C6d, C6e, C8 → all KILLED |
| security L1: unscoped reload | `row.getClientId() != clientId` → treated as a miss | `upsertAll_reloadedRowOfOtherClient_isMiss` | S4 → KILLED |
| security L2: delete fallback | Fallback is now `itemdataRepository.findByClientIdAndItemNr` (uncached). The code CAS (108, 400) runs on whichever path found the row | `delete_codeFallback_usesUncachedRepository`, `delete_codeFallback_casMismatchRejects` | C7 (cached fallback; 5 reds), C7b (CAS on the id path only) → KILLED |
| code L5: failure inside the rewrite | (no prod change; test only) | `upsertAll_rewriteLockTimeout_translatedTo109`: `CannotAcquireLockException` from `renameItemdataForClient` → 109 `"item_id=X, retry"`, no saveAndFlush | S6 "rewrite outside translate()" → KILLED |
| code L6: AC-4d probe and pool leak | Probe `pg_blocking_pids(pid) @> ARRAY[rawPid]`, with the raw session's `pg_backend_pid()`. `shutdownNow()` moved to a finally around the whole body | AC-4d | I6 (probe a wrong pid) → KILLED (the probe is pid-specific and still sees the real wait) |
| code L7: message rows left behind | Checked first: **259** `message` rows (SKU_IMPORT/SKU_UPDATE) carrying `SBDEV2624C/D` had accumulated in the reused container. `wipe()` now deletes them | IT `wipe_removesMessageRowsOfThisClass` (positive control: a row exists before the wipe) | I4 "no message cleanup" → KILLED |
| code L8a: `Write<T>` | Replaced by `Supplier<T>` | (covered by AC-12) | — |
| Info I1, I2 | I1: no change needed. I2: superseded by the blank → null normalization | — | — |

### Gate-test edits (allowed by D-M3, stated)
1. **AC-2a IT:** `update_byFacilityItemIdWithoutPreviousSku_recoversRename` was rewritten as `update_byFacilityItemIdWithPreviousSkuMatchingRow_renames` (fixture row at D, request `previous_sku = D`).
2. **`viaCases`:**
   - `Arguments.of(null, null, "B", "sku", true)` was removed. It is now the stale-lookup test.
   - `Arguments.of(X, null, "A", "facility_item_id", true)` was removed. It is now the 108 test.
   - The test now asserts the recorded via. The recovery column is gone.

### Other test edits, none weakening
- The AC-12 `dataIntegrityViolation` fixture and `upsertAll_shouldRollbackEntireBatch_whenSaveFails` now carry a `SQLException(…, "23505")` cause. Their assertions are unchanged. Without the cause they no longer model a unique violation.
- `upsertAll_rename_appliesAllFieldsAndLogsRename`: the now-vacuous "no `BY_ID_RECOVERY` line" assertion became "no `SKU_RENAME_PRECONDITION` line".
- The delete unit tests (`Delete`, `DeleteByFacilityItemId`) stub `itemdataRepository.findByClientIdAndItemNr` instead of the cached service. The lookup moved there (L2); the assertions are unchanged.
- `NeverMatcherNullBlindnessArchTest` inventory: `SkuRestControllerUnitTest` 4 → 8. These are four new `never().upsertAll(…)` sites, and the 8th position is still the primitive `boolean failIfExists`.
- `upsertAll` signature: `viaByClient` added. The annotation test's reflection lookup gained one `Map.class`.

### Deviation needing Nam's eye: security L4 and `sku_name`
Read-only prd counts, run 2026-10-03:

| tenant DB | itemdata | `item_nr <> trim(item_nr)` | control chars in `item_nr` | control chars in `name` |
|---|---|---|---|---|
| `wh01_hydra_v2` (nywh-hydra-prd) | 2814 | 1 | 0 | 72 |
| `wh01_om1_v2` (wsl-wineco-prd) | 10770 | 1 | 0 | 23 |
| `wh02_shipitez_v2` (nywh-shipitez-prd) | 1506 | 0 | 0 | 36 |
| `wh01_shipitez_v2` (c1wh-shipitez-prd) | 3588 | 1 | 0 | 77 |

- Every control character in `name` is **TAB (0x09)**: 75 + 34 + 38 + 80 occurrences, and none of any other kind.
- Rejecting every ISO control character in `sku_name`, as asked, would make every OMS edit of those **208 products** fail with 422.
- A TAB cannot break a log line. Also, `sku_name` is not written by any of the new audit lines.
- So `sku_name` rejects every control character **except TAB**, while `sku` and `previous_sku` reject all of them (0 prd rows affected).
- Two tests pin both halves (C6c).
- If Nam wants TAB rejected too, it is a one-argument change (`hasControlCharacter(sku.getSkuName(), false)`). Those 208 names would first need cleaning.

### Code open question: padded legacy `item_nr`
- Ran the queries above: **3** padded rows across all prd tenants (Hydra 1, WineCo 1, ShipItEZ c1wh 1).
- Each costs at most one 108 plus one guarded resend on its first edit.
- No action needed before rollout.

### Accepted residual (follows Nam's rule as written)
- Case: a double-stale cache, where `(c,B) → X` is stale, `(c,A)` is a stale miss, and X really is at A. For `{sku:B, previous_sku:A}`, D-M3's rule discards the sku hit and creates `(c,B)`, leaving X at A.
- Cause: the uncached re-check is by code only, so it does not consult previous_sku.
- It needs two independent stale entries for the same item, and it is logged by `SKU_RENAME_STALE_LOOKUP`.
- I did not widen the re-check beyond what D-M3 specifies.

## PIT: `SkuBatchCreateUpdateService` (JDK 21, scoped)
- Command: `mvn -o test-compile` then `mvn -o org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.service.SkuBatchCreateUpdateService -DtargetTests=net.aim_ai.wms.unit.service.SkuBatchCreateUpdateServiceUnitTest`.
- Result: **54 generated, 52 killed (96%), 2 survived, 0 no coverage**.
- Both survivors are the equivalents already explained in `impl-wms2.md`:
  1. `:150 lambda$upsertAll$1` "replaced return value with null". This is the step-5 `saveAndFlush` lambda, and its return value is discarded (the row is managed).
  2. `:127 removed call to setScale`. `Itemdata.scale` is initialized to 0 at the field.

## Suites (fresh, final tree = `02a20c56`)
| Check | Result |
|---|---|
| Targeted unit (10 classes: the conformance lane's list) | 124 run, 0 F, 0 E |
| `mvn -o verify -Dit.test=SkuRenameInPlaceIT,SkuRestControllerIntegrationTest,SkuRestControllerAtomicityIntegrationTest` | SkuRenameInPlaceIT **17/17**, SkuRestControllerIntegrationTest 3/3, Atomicity 3/3, BUILD SUCCESS |
| `mvn -o clean compile` | BUILD SUCCESS |
| `mvn -o clean test` | **7850 run, 0 F, 0 E, 1 skipped**. Baseline 7821/0/0/1: +29 new tests (+11 service, +18 controller), no new failure |
| Intermediate commit `147e1df2` (exported with `git archive` to /tmp, built separately) | `clean verify` on the targeted units 87/0 plus SkuRenameInPlaceIT 16/16, so the D-M3 commit builds and passes on its own |
| Placeholder scan of `git diff 086cb309` (TODO/FIXME/HACK/@Disabled/System.out) | 0 hits |

## Still open (unchanged by this round)
- M-5 UAT EXPLAIN (pre-merge).
- The cross-repo prefix verify row (P3).
- Rebase onto origin/develop (13 behind) and re-run `NeverMatcherNullBlindnessArchTest`, which both sides touch.
- **The OMS half of D-M3**: the guarded 108 resend must send `previous_sku = D`. Until it does, the OMS's current resend, which omits previous_sku, now gets a 108 from wms2 instead of a recovery. That is safe (no write), but the AC-2a recovery does not complete until the OMS lands its half.
- New WARN token `SKU_RENAME_STALE_LOOKUP` should be added to plan §7.4.

---

## Round 2 (review `review-r2-wms2-fixes.md`, plan §10 E-1)

- New HEAD: **`e727b9de`** "SBDEV-2624: review round 2 — uncached previous_sku lookup, review Lows". It is one commit on top of `02a20c56`.
- Not pushed, not rebased (ahead 11, behind 13). `git status` is clean.

The mutant protocol is unchanged: copy to `/tmp/sbdev2624-r1/<name>.orig`, apply, run, restore, `cmp`. The no-op control R0 stayed green (53/0/0).

| Finding | Fix | Test | Mutant → result |
|---|---|---|---|
| **M1** / E-1 #5: a stale cached miss for previous_sku creates a twin | `resolveForUpdate` step 2 → `itemdataRepository.findByClientIdAndItemNr` (uncached) | unit `update_previousSkuStep_isUncached` (service stubbed with a stale miss, repository with X; asserts X reaches upsertAll and the service is never called). IT `update_staleCachedMissForPreviousSku_stillRenames`: warm (c,A) miss, X moved to A behind the cache, `{sku:B, previous_sku:A}` → `idsFor(C,"A","B") == [X]`. IT `update_doubleStaleCache_stillRenames`: also warm (c,B) → X → renamed, the stockrecord rewritten, no twin | R1 "cached step 2" → unit KILLED (3 reds). IT KILLED: **both** stale ITs red with their own messages |
| **L1**: missing via defaulted to the sku step (unguarded create) | Default → `VIA_FACILITY_ITEM_ID`, the strictest: `rename()`'s CAS answers 108 or performs a previous_sku-verified rename | `upsertAll_foundRowWithoutRecordedVia_defaultsToIdStep_noPreviousSku_throws108` (no write at all) and `…_previousSkuMatches_renames` (only X written). These replace round 1's `…_defaultsToSkuStep`, whose behaviour the reviewer flagged | R2 "default via = sku" → KILLED (both) |
| **L2**: the AC-12 rollback fixture had drifted onto the create path | `existing.setClientId(1L)`. Asserts `saveAndFlush(existing)` (update flush) and `never()` a create-branch re-check. Sweep: every other hand-built `Itemdata` that reaches `upsertAll` goes through `item()`, which sets the client; the remaining `new Itemdata()` are `saveAndFlush` return copies or the deliberate foreign-client row | `upsertAll_shouldRollbackEntireBatch_whenSaveFails` | R3 "fixture without client id" → KILLED |
| **L3** | Plan amendment E-1 (Nam ack). No code | — | — |
| **L4** / E-1 #4: wrong code for control characters | `FIELD_MALFORMED_FORMAT` (103): "field sku has wrong format for request (control characters are not allowed)" | the 6 round-1 control-character tests, with descriptions updated | R4 "back to 100" → KILLED (3 reds) |
| **L5a**: U+2028/U+2029 | Rejected in sku, previous_sku and sku_name | `update_unicodeLineSeparators_rejected`, `update_skuName_edgeTrimmedButLineSeparatorRejected` | R6 "ISO controls only" → KILLED |
| **L5b**: edge control characters were silently trimmed | `rejectControlCharacters` runs **before** `normalize()` in create, update and delete. sku and previous_sku are checked raw. sku_name is checked as trimmed (TAB allowed, edge whitespace still stripped as before) | `update_edgeControlCharacterInSku_rejectedBeforeTrim` (`"B\n"`), `update_edgeControlCharacterInPreviousSku_rejectedBeforeTrim` (`"\u0001A"`) | R5 / R5b "check after trim" → KILLED |
| **L6**: unbounded cause walk | `MAX_CAUSE_DEPTH = 16` | `upsertAll_causeCycle_terminates` (a → b → a, `assertTimeoutPreemptively(5s)`, rethrown unchanged) | R7 "no depth cap" → KILLED (timeout) |

**prd evidence for L5** (read-only, 2026-10-04, all four tenants; positive controls returned true for each pattern):
- 0 `item_nr` with an edge control character.
- 0 `item_nr` and 0 `name` containing U+2028/U+2029.

So the stricter checks reject nothing real.

**Note for Nam:**
- E-1 #5 extends D-M3's "uncached re-check by code" to the previous_sku step. Its rules are unchanged:
  - still no rename without previous_sku;
  - still the CAS and the collision check;
  - the stale-sku discard is untouched.
- Round 1's "accepted residual" (double-stale) is **closed**, and so is the silent single-stale case the reviewer found.

### Round 2 suites (fresh, final tree = `e727b9de`)
| Check | Result |
|---|---|
| Targeted unit (the same 10 classes) | 132 run, 0 F, 0 E |
| `mvn -o verify -Dit.test=SkuRenameInPlaceIT,SkuRestControllerIntegrationTest,SkuRestControllerAtomicityIntegrationTest` | SkuRenameInPlaceIT **19/19**, 3/3, 3/3, BUILD SUCCESS |
| `mvn -o clean compile` | BUILD SUCCESS |
| `mvn -o clean test` | **7857 run, 0 F, 0 E, 1 skipped**. Baseline 7850/0: +7 (service +2, controller +5), no new failure |
| Placeholder scan of the round-2 diff | 0 hits |

PIT was not re-run this round (not requested). The service changes are a default constant and a loop bound, and both are pinned by R2 and R7.

---

# Round 3 — `review-r3-wms2-fixes.md` (L-b, L-d, I-1; L-a/L-e in the OMS repo; L-c/plan E-1 #4 already in the plan)

- **New HEAD: `f35352d7`** on top of `e727b9de`. One new commit, nothing amended, not pushed. `git status` clean. Main checkout `v2/wms2-api` not touched. JDK 21; no other Maven running (`pgrep` empty) before each run. Mutants: `SkuRestController.java` copied to `/tmp/sbdev2624r3/`, mutated in place (the `rejectControlCharacters` line moved after `normalize()`), restored from the copy; `git status` shows the controller unmodified.

| Finding | Fix | Test | Mutant | Result |
|---|---|---|---|---|
| **L-b** create/delete pre-trim check unpinned | none (code was correct) | `create_edgeControlCharacterInSku_rejectedBeforeTrim` (`"B\n"` -> 422, description 103); `delete_edgeControlCharacterInSku_rejectedBeforeTrim` (`"B\n"` -> 400, 103, `never().delete`) | M-create: check after `normalize()` at `create()` -> RED, only the create test. M-delete: same at `delete()` -> RED, only the delete test | KILLED (each by its own test) |
| **L-d** stale DisplayName | `create_lineBreakInSkuName_rejected` DisplayName now says `FIELD_MALFORMED_FORMAT (create)` | same test | n/a | done |
| **I-1** dead `t.getCause() == t` | loop step is `t = t.getCause()`; the `MAX_CAUSE_DEPTH` cap stays | `upsertAll_causeCycle_terminates` (still green; guards the cap) | n/a | done |
| **L-c** whitespace-only sku now 103 not 100 | already recorded in plan §10 E-1 #4 | - | - | done |

## Round 3 verification
- `SkuRestControllerUnitTest` + `SkuBatchCreateUpdateServiceUnitTest`: 93 run (55 + 38), 0 F, 0 E (was 53 + 38).
- `mvn -o clean test`: **7859 run, 0 F, 0 E, 1 skipped** (baseline 7857 + 2 new tests), BUILD SUCCESS.
