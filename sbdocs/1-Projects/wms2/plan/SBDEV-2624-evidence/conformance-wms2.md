# SBDEV-2624 Phase 3a conformance check: wms2-api

head: 086cb309b196127b35ea87f16a091f50075d107f (worktree .claude/worktrees/wms2-api/SBDEV-2624, merge-base 7762aa64, gate 39500235 + 7 commits; working tree clean before and after)
Date: 2026-10-02. Verifier lane (separate from the implementer). JDK 21.0.8, Maven 3.9.11. Before every Maven run, `pgrep -fl "surefire|failsafe|plexus-classworlds"` was empty. All Maven runs were sequential, none used `&`.

## Verdict
**PASS**, high confidence. 0 blockers. Pre-merge items still open and outside P1: M-5 UAT EXPLAIN, P2/P3.

## Evidence (fresh, run by me)
| Check | Command | Result |
|---|---|---|
| Compile | `mvn -o clean compile` | exit 0. Re-run exit 0 after the mutant restores |
| Targeted unit | `mvn -o test -Dtest=SkuBatchCreateUpdateServiceUnitTest,SkuRestControllerUnitTest,StockrecordRenameQueryShapeUnitTest,WmsConstantsSkuRenameUnitTest,ItemdataRepositorySdrExportUnitTest,OptionalSafetyArchTest,NeverMatcherNullBlindnessArchTest,CacheEvictionOnWriteUnitTest,TenantCacheKeyUnitTest,TestClassTransactionManagerArchTest` | 96 run, 0 F, 0 E |
| PG IT | `mvn -o verify -Dit.test=SkuRenameInPlaceIT,SkuRestControllerIntegrationTest,SkuRestControllerAtomicityIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false` | SkuRenameInPlaceIT 13/13, SkuRestControllerIntegrationTest 3/3, Atomicity 3/3, BUILD SUCCESS |
| Full suite | `mvn -o clean test` | 7821 run, 0 F, 0 E, 1 skipped. Baseline: 7811 / 19 F (the gate RF rows) / 1 skipped. +10 tests, all 19 gate reds now green, no new failure |
| Placeholders | `git diff origin/develop...HEAD` grep for `+` lines with TODO/FIXME/@Disabled/skip/assume | 0 hits. The delete handler's `// TODO check that no item exists` is pre-existing on origin/develop |
| 108/109 collision | `= 10[89];` across all 372 remote branches, with HEAD as positive control | only HEAD has them |
| develop drift | `git fetch`; HEAD..origin/develop = 13 commits (SBDEV-3608/3638) | `git merge-tree` is clean. Overlapping files: WmsConstants.java (sysprop deletions, unrelated) and NeverMatcherNullBlindnessArchTest.java. Re-run that arch test after the rebase |

## Hand mutants (verifier-applied, backups in /tmp/sbdev2624-verifier, each restore `cmp`-verified, one at a time)
| # | Mutant | Lane | Result |
|---|---|---|---|
| V1 | **D-M2**: the CAS skips when previous_sku == sku (`&& !previousSku.equals(code)`) | U | KILLED, 1/25: `upsertAll_previousSkuEqualsSku_rowAtOtherCode_throws108:622` "mutant 'CAS ignores previous_sku when it equals sku'" |
| V2 | AC-11: `setItemNr` moved before `renameItemdataForClient` | U | KILLED, 1/25: `upsertAll_rename_rewritesStockrecordBeforeMutatingAndFlushingItemdata:273` |
| V3 | AC-7a: create returns an empty `item_ids` | U | KILLED, 1/30: `create_returns200WithItemIdsBySku:743` "mutant 'empty map'" |
| V4 | AC-14: drop the delete CAS (`if (false && …)`) | U | KILLED, 1/30: `delete_byFacilityItemId_casOnSku_mismatchRejects:814` "mutant 'drop the CAS'" |
| V5 | **M13** AC-10b: no rewrite call (`int n = 0;`) | IT | KILLED, 2/13: AC-10b `:552` "mutant 'no rewrite call'…", AC-10a `:530` "expected 0 was 3" |
| V6 | **M12** AC-10a: drop `AND itemdata = :oldItemNr` | IT + shape | KILLED, 1/13, at `:531` "(c,'B') carries the old A rows" (3 → 4). The named `'drop the exact conjunct'` assertion at `:532` is never reached. StockrecordRenameQueryShapeUnitTest stays GREEN, so the conjunct is not pinned by CI text |

## §0 rows (wms2)
| Row | Status | Evidence |
|---|---|---|
| W1 create | VERIFIED | `upsertAll(..., true)`; `ResponseEntity.ok(successWithItemIds(itemIds))`; message-log status 200; uncached re-check plus `failIfExists` → 101 (AC-5c, AC-13 green; V3 killed) |
| W2 update | VERIFIED | `resolveForUpdate`: `findByIdAndClientId` → `previous_sku` (cached service) → `sku`, keyed by the request sku (C4); 200 + `item_ids`; IT AC-1/2a/2b/3/5/5b green |
| W3 delete | VERIFIED | client-scoped `findByIdAndClientId`; CAS on `item_nr == sku` → 400 + `SKU_DELETE_PRECONDITION`; a miss falls back to the code lookup; **still 204** (`HttpStatus.NO_CONTENT` at :410); V4 killed |
| W4 upsertAll | VERIFIED | reload; CAS 108; direct collision 105 naming X and Y; rewrite before any mutation; `saveAndFlush` at all 3 sites inside `translate()`; DIVE→105, Pessimistic/Optimistic→109 with the plan's fixed arguments; insertion-ordered map; `saved.getId()` on create |
| W5/W6 | VERIFIED (OUT) | ItemdataService untouched |
| W7 finally eviction | VERIFIED | untouched; AC-9 IT green |
| W8 SkuDto | VERIFIED | `facility_item_id` Long, `previous_sku` String; trimmed in `normalize()` |
| W9 | VERIFIED (OUT) | untouched |
| W10 StockrecordRepository | VERIFIED | `@Modifying` native query, text identical to §3.4; the type stays `exported = false` |
| W10b ItemdataRepository | VERIFIED | `findByIdAndClientId` with `@RestResource(exported = false)`; also adds `saveAndFlush`, `exported = false` (needed because the repo is not a JpaRepository). Reflection test green |
| W10c WmsConstants | VERIFIED | 108/109 with text and name arms; text `"sku rename precondition failed: %1s, %2s"` / `"sku concurrent modification: %1s, %2s"` |
| W11–W13 | VERIFIED (OUT) | not in the diff |
| W14 SDR | VERIFIED (OUT) | `Itemdata.class` in RestConfiguration (:498, :900); `SdrWriteWithdrawalContextTest` still pins `"Itemdata"`; the config package is not in the diff |

## §7.1 wms2 ACs
| AC | Status | Evidence |
|---|---|---|
| AC-1 | VERIFIED | IT green; gate red "[9530, 11828]"; M1 killed (impl) |
| AC-2a | VERIFIED | IT green; M2 killed (impl) |
| AC-2b | VERIFIED | IT green; M3, M4 killed (impl) |
| AC-3 (RG) | VERIFIED | IT green; M5 killed (impl) |
| AC-4 | VERIFIED | IT green; M6 killed (impl) |
| AC-4c | VERIFIED | IT green; M6 also reds it. The cached-service mutant was not applied; AC-11's InOrder on the direct repository covers it structurally |
| AC-4d | VERIFIED | IT green; raw `setAutoCommit(false)` connection, separate thread, polls `pg_stat_activity` for a lock wait, asserts the row first, then 422 / 105; M7 killed (impl) |
| AC-5 (RG) | VERIFIED | IT green; M9 killed (impl) |
| AC-5b | VERIFIED | 2 IT tests green; M8 killed (impl) |
| AC-5c | VERIFIED | unit green; U12 killed (impl) |
| AC-6 (RG) | VERIFIED | unit green; U10 killed (impl) |
| AC-7a | VERIFIED | unit green; V3 killed |
| AC-9 | VERIFIED | IT green; M10 killed (impl) |
| AC-10a | VERIFIED | IT green; V5 and V6 killed (V6 only partly attributable, see Gaps) |
| AC-10b | VERIFIED | IT green; V5 (M13) killed with its own message |
| AC-11 | VERIFIED | unit green; V2 killed |
| AC-12 | VERIFIED | 9 parameterised cases green (3 kinds × Rename/Create/PlainUpdate); U13, U14 killed (impl) |
| AC-13 | VERIFIED | unit green; U11 killed (impl) |
| AC-14 | VERIFIED | 3 unit tests green; V4 killed |
| §3.4 shape | VERIFIED | green; U6 killed (impl) |
| 108/109 | VERIFIED | green; U7 killed (impl) |
| SDR | VERIFIED | green; U8 killed (impl) |
| **D-M2** | VERIFIED (unit lane) | `upsertAll_previousSkuEqualsSku_rowAtOtherCode_throws108` asserts code 108, the exact description, X unchanged, no write, no rewrite; V1 killed. The production branch `previousSku != null && !oldCode.equals(previousSku)` already covered it, so the commit is test-only. No IT/HTTP-level twin |

## §7.4 log tokens
VERIFIED, all present in src/main:
- `SBDEV-2624 SKU_RENAME` INFO, with `via` and `stockrecordRows`
- `SKU_RENAME_PRECONDITION`, `SKU_RENAME_BY_ID_RECOVERY`, `SKU_RENAME_COLLISION` (WARN, service)
- `SKU_DELETE_PRECONDITION` (WARN, controller)

PIT pins the via/recovery tokens (impl report, 45/47 killed, 2 equivalent). PIT was not re-run here.

## §5.2 P1 acceptance / Acceptance
| Item | Status |
|---|---|
| every §7.1 wms2 row green | VERIFIED (fresh) |
| every named mutant red | VERIFIED: 6 re-run by me; the rest from the impl report |
| PIT on SkuBatchCreateUpdateService | PARTIAL: reported 96%, 2 equivalents with reasons that hold up; not re-run here |
| `mvn clean` then full suite = baseline | VERIFIED: 7821/0/0/1 |
| M-5 UAT EXPLAIN | OPEN: pre-merge, out of P1 |
| verify script (cross-repo prefix row) | NOT YET WRITTEN. Checked manually below |

## 200 vs 204
- create and update now return 200 with `{status, item_ids}`.
- Delete stays 204, and its business-exception path stays 400.
- Every remaining `NO_CONTENT`/`isNoContent` in the Sku tests is a delete test: unit :630 `delete_paddedSku…`, :681 `shouldDeleteSkuSuccessfully`, :786/:843 AC-14, and IT :346 `deleteTest`.
- IdempotencyFilterUnitTest was correctly left unchanged.

## Cross-repo (OMS worktree, read only; 9+ dirty files, mid-edit)
- `WMS_RESYNC_MARKERS = ['sku rename precondition failed', 'sku concurrent modification']` (WmsApiService.php:916). Each is a plain prefix of its wms2 text arm, ending before `:` and the first placeholder. MATCH.
- The OMS 108 parse regex `^sku rename precondition failed: item_id=(\d+) is (.+), expected <sent previous_sku>$` matches the wms2 rendering `"... item_id=X is C, expected B"`, pinned exactly by the D-M2 unit test.
- `resyncDescription` reads `description` from the decoded body, which is the key wms2 `getErrorMap()` emits, and accepts only 422. So the delete-CAS 108 (HTTP 400, suffix ` (delete)`) can never trigger a resend. That makes deviation 2 safe.
- Field names match: `facility_item_id` and `previous_sku` (`@JsonProperty` in SkuDto ↔ OMS payload keys); `item_ids` (wms2 body ↔ OMS `response.data.item_ids[$sku]`). `request_nonce` is sent by the OMS and ignored by wms2, as designed.

## Deviations
1. AC-10b literal `'RECEIVING'` → `'Received'`. ACCEPT. Every transaction_detail migration (V2.2.00/08/12/25) emits `''Received''`, so the gate filter was vacuous. M13 now reds it for the right reason.
2. Delete CAS reuses 108 with HTTP 400. ACCEPT. The plan fixes no code here, and the OMS resend path is 422-only (verified above).
3. `via` is derived in the service. ACCEPT. Log-only, and the gate pins `upsertAll`'s signature. Small inexactness: a `previous_sku` hit whose cached code went stale logs `sku`. Cosmetic.
4. Plain-update 105 arguments `"sku B"` / `"update of item_id=X"`. ACCEPT. The plan is silent, and they follow the per-site fixed-argument rule.
5. `Optional.get()` → `orElse(null)`. ACCEPT. Same behaviour; satisfies OptionalSafetyArchTest.

**M12 partly attributable.** ACCEPT as KILLED for the right cause: the 'a' row is rewritten into B, so the (c,'B') count goes 3 → 4. Low suggestion: put the `(C,"a") == 1` assertion before `(C,"B") == 3`, or add `AND itemdata = :oldItemNr` to the shape test.

## Gaps
- D-M2 has no IT/HTTP-level pin (unit lane with mocks only). Low. Optionally add an IT twin of AC-2b with `previous_sku = sku = B`.
- The exact-case conjunct is not text-pinned (V6 shape test stays green); only the IT guards it. Low.
- An edge the plan allows: a stale cached hit by `sku` whose DB row was renamed elsewhere, sent with no `previous_sku`, is renamed back through `SKU_RENAME_BY_ID_RECOVERY` (logged). It matches §3.3 step 3 as written, and the cross-replica gap is G4. Info.
- The cross-repo prefix verify-script row is not yet written. It is required by Acceptance and belongs to the P3 lane. Medium for ship, not a P1 conformance blocker.
- M-5 UAT EXPLAIN is still to be done before merge.
- Rebase onto the current origin/develop (13 commits) and re-run NeverMatcherNullBlindnessArchTest, which both sides touch.

## Recommendation
APPROVE (P1 conformance). The wms2 half builds §3.1–§3.4 and D-M2 as specified. Every wms2 §0 row and AC is verified with fresh evidence. The full suite equals baseline plus the new tests, and the 6 independently applied mutants are all killed.
