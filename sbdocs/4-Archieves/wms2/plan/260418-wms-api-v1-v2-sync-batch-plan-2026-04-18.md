---
title: "WMS API v1 → v2 Sync — Batch Port Plan (2026-04-18)"
ticket: ""
ticket_url: ""
type: migration
priority: Normal
status: implemented
project: [wms2-api]
version: v2
requester: ""
created: 2026-04-18
updated: 2026-04-18
related:
  - ../../../3-Resources/reports/wms-api-v1-commits-post-2026-03-20-applicability.md
  - ../../../2-Areas/wms-v1-v2-sync/README.md
  - ../../../2-Areas/wms-v1-v2-sync/sync-log.md
tags:
  - plan
  - migration
  - wms-api
  - v2
  - sync
---

# WMS API v1 → v2 Sync — Batch Port Plan (2026-04-18)

## 1. Problem Statement

v1/wms-api `develop-arden` has drifted from v2/wms2-api `develop-arden` since the 2026-03-20 bulk-sync baseline. Of 49 non-merge commits in that window, the applicability report classifies 28 as already in v2, 6 as not applicable, 3 as a revert trio (1 port candidate), 9 SHAs in Bucket E, and 3 Bucket B judgment calls. SBDEV-2072 and SBDEV-2079 "merge" commits are empty (single-parent, zero diff) — no hidden work.

This batch plan phases the remaining work so it can be executed in a single 2–4 hour focused session, producing atomic per-commit ports with clear verification gates.

## 2. Scope & Inventory

**Total non-merge commits since 2026-03-20:** 49.

| Bucket | Count | Action taken in this plan |
|---|---|---|
| A — Already in v2 | 28 | Skip (no sections here; covered by applicability report §5) |
| B — Verify / judgment call | 3 | Phase 0 + Phase 3 |
| C — Not applicable | 6 | Skip (covered by applicability report §7) |
| D — Revert trio | 3 (net 1 port) | Phase 2 — `d52046e` |
| E — Needs porting | 9 SHAs (5 unique subjects after removing 2 duplicate pairs and 2 empty merges) | Phases 1–4 |

**Ported subjects in this session:**

1. `4c8d500` — Import SKU with non-existing Shipper Code causes 500 (*FileImportController*)
2. `98fce54` — Newly created BOL has shipped date (*BillofladingService*)
3. `8957b9a` — Empty open BOL shows SKU data in Excel export (*BillofladingPositionRepository*)
4. `d52046e` — Pallet name duplicate validation (*ReceivingController*)
5. `4a0a26e` — `transaction_detail` function (new feature — Flyway migration `V1.26.28_wms_functions.sql`, 362 lines)

**Bucket B to resolve in Phase 0 / Phase 3:** `f0bef13` (cron auto-flush — architectural judgment), `50edfe7` (pre-QA OMS cancellation — verify in v2), `46130c3` (parcel cancelled message — verify).

## 3. Phased Implementation Plan

| Phase | Goal | Items | Effort | Gate before next |
|---|---|---|---|---|
| **0** | Pre-flight verification | Bucket B verifications × 3; confirm Bucket D `d52046e` absent from v2 | 30–60 min | Updated scope list |
| **1** | Low-risk standalone bug fixes | `4c8d500`, `98fce54`, `8957b9a`, `46130c3` (if ported) | 1–2 h | `mvn test` green |
| **2** | Validation fix | `d52046e` | 30 min | `mvn test` green |
| **3** | Judgment-call items | `f0bef13`, `50edfe7` | 30–60 min | Decision logged in plan |
| **4** | Feature work | `4a0a26e` transaction_detail function | 2+ h | Plan subsection reviewed, migration tested |
| **5** | (N/A — merges were empty) | — | — | — |

## 4. Per-commit Migration Detail

### 4.1 `4c8d500` — Import SKU non-existing Shipper Code (Phase 1)

- **v1 file:** `src/main/java/net/aim_ai/wms/controller/FileImportController.java` (5+ / 3-)
- **v2 file (expected):** same path (v2 preserved controller structure)
- **Bug in v1:** SKU bulk import throws 500 when the uploaded row references a shipper/client code that doesn't exist; error should be a per-row validation failure, not a server error.
- **v2 adaptation:**
  - Read v1 diff and translate `javax.*` imports to `jakarta.*` if any.
  - If v2 already has a broader null-safety wrapper via Phase 5 `orElseThrow`, the fix likely collapses to an `orElseThrow(() -> new BusinessException("Shipper not found: " + code))`. Verify.
- **Files to touch:** `FileImportController.java`.
- **Tests:** add unit test `fileImport_nonExistingShipperCode_returns422WithRowError` (or equivalent — match v1 test if it added one).
- **Commit subject:** `port v1 4c8d500 — Import SKU tolerates non-existing shipper code`.
- **Risk:** Low.

### 4.2 `98fce54` — BOL shipped date on create (Phase 1)

- **v1 file:** `src/main/java/net/aim_ai/wms/service/BillofladingService.java` (1+)
- **v2 file (expected):** same path
- **Bug in v1:** freshly created BOLs are created with `shippedDate` set; should be null until actually shipped.
- **v2 adaptation:** single-line fix, almost certainly identical — one field initialization to remove / null.
- **Tests:** add unit test `createBOL_doesNotPopulateShippedDate` or update an existing test to assert null.
- **Commit subject:** `port v1 98fce54 — new BOL has no shipped date until shipped`.
- **Risk:** Low.

### 4.3 `8957b9a` — Empty open BOL shows SKU data in Excel export (Phase 1)

- **v1 file:** `src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java` (11+ / 8-)
- **v2 file (expected):** same path
- **Bug in v1:** repository query for BOL position export returns rows even when the BOL has no positions — likely a JOIN vs LEFT JOIN or an empty-aware filter missing.
- **v2 adaptation:**
  - Inspect v2's current query for the same method. If v2 uses JPQL / Spring Data with a different JOIN shape, translate the filter rather than cherry-picking the SQL.
  - Jakarta namespace applies; no `javax.*` imports here most likely.
- **Tests:** add repository test `findBolPositionsForExport_emptyBol_returnsEmptyList`; if no IT harness, at minimum a Testcontainers integration test.
- **Commit subject:** `port v1 8957b9a — empty BOL export returns no SKU rows`.
- **Risk:** Low-Medium (query-level change; exercise with Testcontainers).

### 4.4 `d52046e` — Pallet name duplicate validation (Phase 2)

- **v1 file:** `src/main/java/net/aim_ai/wms/controller/ReceivingController.java` (5+)
- **v2 file (expected):** same path
- **Bug in v1:** creating a pallet with a duplicate name was silently accepted; now rejects with a validation error.
- **v2 adaptation:**
  - v2 may already have the check via the Phase 5 `orElseThrow` / `findByLabelidIgnoreCase` pattern — verify first.
  - If missing, port the validation. Prefer throwing `BusinessException` or `ApiInvalidParameterException` so `RestExceptionHandler` returns 422, not 500.
- **Tests:** add `createPallet_duplicateName_throwsBusinessException`.
- **Commit subject:** `port v1 d52046e — pallet creation rejects duplicate names`.
- **Risk:** Low (validation only).
- **Verification before porting:** Bucket D's `0fbf74e` and `d364033` are revert pair; `d52046e` is the final v1 state. Confirm v2 lacks this check.

### 4.5 `4a0a26e` — `transaction_detail` function (Phase 4)

- **v1 file:** `src/main/resources/db/migration/V1.26.28_wms_functions.sql` (362+)
- **v2 target path:** `src/main/resources/db/migration/V<next-available>__wms_transaction_detail_function.sql`
- **Nature:** Flyway SQL migration adding a new PostgreSQL stored function used for detailed transaction reporting.
- **v2 adaptation — judgment required:**
  - **Option A (straight port):** copy the SQL into a v2 Flyway migration with the next available version number on v2's migration sequence.
  - **Option B (re-express in v2's idiom):** If v2 elsewhere prefers Spring Data + Caffeine-cached reads over PostgreSQL functions, translate the function's logic into a `@Repository` + service layer.
  - **Option C (defer):** If the reporting feature is v1-specific and not a product requirement for v2 yet, skip with rationale; track in a new ticket.
- **Decision inputs:**
  - Does v2 already have any `db/migration/*wms_functions*` files? If yes, Option A is the established pattern.
  - Does the caller of this function also need to be ported? (Look for any Java service/controller changes in the merge commits around 2026-04-15.)
- **Tests:** integration test via Testcontainers invoking the function on a seeded DB, asserting row count and shape.
- **Commit subject:** `port v1 4a0a26e — add transaction_detail function (Flyway migration)` *(if Option A)*.
- **Risk:** Medium-High — SQL migrations are forward-only in Flyway. Migration version ordering matters; choose the next free version. Validate syntax/parameters for v2's Postgres version before merging.
- **Not tested unless explicit:** performance on production-scale data.

### 4.6 Bucket B — Phase 0 verifications and Phase 3 decisions

#### 4.6.1 `f0bef13` — Cron job auto-flush (Phase 3 judgment)

- **v1 change:** added `@Cacheable`-style 30s TTL to `BasicService.showLog()` + catch Spring's `OptimisticLockingFailureException` (not just `javax.persistence.OptimisticLockException`) in `ReplenishOrderJob` / `OrderReleaseJob` + `@Transactional` on `recalculateOpenOrders()`.
- **v2 state (observed):**
  - Retry expansion present via v2 `25001a9` "Phase 1 — transaction safety enforcement + optimistic lock retry expansion".
  - `@Transactional` on `recalculateOpenOrders()` is **absent** in v2 (`ReplenishmentOrderMaintenanceService.java:67,71`).
  - `BasicService.showLog()` caching is **absent**.
  - Phase 3 Redis cache (`7c6bcf7`) is an unrelated architectural alternative.
- **Decision tree:**
  - **Does v2 reproduce the v1 auto-flush symptom?** If yes → port the missing `@Transactional` + `showLog()` cache. If no → add a comment in `ReplenishmentOrderMaintenanceService` + `BasicService` explaining why it was intentionally skipped, and record the rationale in `sync-log.md`.
  - **Way to answer:** run v2 cron jobs on a representative tenant DB and check for `StaleObjectStateException` in logs; or run a unit test that simulates concurrent entity modification + native query (mirrors v1 repro).

#### 4.6.2 `50edfe7` — Allow OMS cancellation for pre-QA club orders (Phase 0 verify)

- **v1 files:** `CustomerorderService.java` (56+) + `CustomerorderServiceUnitTest.java` (152+).
- **v2 most likely home:** `14a4a81` "Phase 7 Part A — fix 4 cancel flow bugs + consolidate duplicate code".
- **Verification:** grep `CustomerorderService.java` in v2 for `isOmsPreQaPackedCancellationAllowed` / `forceCancelOrder` used with a club-batch guard. If present → Bucket A. If absent → port.

#### 4.6.3 `46130c3` — Parcel cancelled message (Phase 0 verify, then Phase 1 if needed)

- **v1 file:** `src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizingService.java` (3+/3-).
- **Probable issue:** incorrect message key / formatting for parcel-cancelled notification.
- **Verification:** diff v2's `MobilePalletizingService.java` against v1's pre-fix version at the same 3 line range; if v2 shows the fixed text, Bucket A. Otherwise include in Phase 1.

## 5. Verification & Testing Strategy

- **Per-phase gate:** `mvn test` green on `wms2-api`. No new failures introduced by the phase's commits (ignore known pre-existing H2/integration errors already documented in v2 archive plans).
- **Per-commit tests:** every commit adds or updates at least one unit test covering the specific behavior change. For repository-layer changes (Phase 1 — 4.3, Phase 4 — 4.5), add a Testcontainers integration test.
- **Regression safety:** after Phase 1 and Phase 4 complete, run `mvn verify` (full integration suite) and compare against the baseline from `develop-arden` HEAD before the session started.
- **Manual QA list for the follow-up ticket:**
  - Bulk SKU upload with a bad shipper code → 422 with row-level error (not 500).
  - Create a new BOL → `shippedDate == null` in the UI and DB.
  - Export an empty BOL → Excel has no SKU rows.
  - Create a pallet with an already-used label → validation error shown.
  - Invoke `transaction_detail` via the UI/report it powers → expected shape + row count.

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Phase 4 Flyway migration conflicts with v2's migration sequence number | Medium | High | Check v2's `db/migration/` directory for next-available version; never reuse or reorder existing versions. |
| Phase 4 SQL function syntax incompatible with v2's Postgres | Low | High | Test on local Testcontainers instance before merging; v2 and v1 both run PostgreSQL — should be compatible. |
| Phase 3 `f0bef13` port creates redundant caching with v2 Phase 3 Redis | Medium | Medium | Explicit decision tree in §4.6.1; document the chosen path in `sync-log.md`. |
| `d52046e` (Phase 2) conflicts with existing v2 pallet-creation logic | Low | Medium | Verify absent in v2 first (Phase 0); use `findByLabelidIgnoreCase` if v2 has it. |
| Tests from v1 can't be ported verbatim (different Mockito / Jakarta imports) | Medium | Low | Rewrite tests in v2 idiom; reference existing v2 test classes for pattern. |
| Plan underestimates Leonardo's `4a0a26e` function scope (callers not identified) | Medium | High | Phase 0 grep: find callers of `transaction_detail` in v1 Java code. If callers exist, port them too. |
| Bucket B verification surfaces a new port candidate | Low | Low | Append to Phase 1 or Phase 3 as discovered. |

## 7. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| HTTP 500 on bad SKU import | 500 with stack trace | 422 with row-level error | **Improved** |
| New BOL `shippedDate` | Populated | Null | **Expected** — UI code should already handle null |
| Empty BOL export | Shows phantom SKU rows | Empty Excel | **Improved** |
| Duplicate pallet name | Silently accepted | 422 validation error | **Breaking at API surface** — operators expecting silent success must be notified |
| `transaction_detail` function | Does not exist | Available via Flyway migration | **Additive** |
| Cron `@Transactional` / `showLog()` cache | Present in v1, absent in v2 | Depends on Phase 3 decision | **Case-by-case** |

## 8. Branch & PR Strategy

- **Branch per phase** from `develop-arden`:
  - `sync/wms2-api/phase1-standalone-bugs`
  - `sync/wms2-api/phase2-pallet-name-validation`
  - `sync/wms2-api/phase3-judgment-items`
  - `sync/wms2-api/phase4-transaction-detail`
- **PR per phase** — review independently. Fast-forward merge into `develop-arden` once reviewed.
- **Commit message format** (per repo CLAUDE.md commit protocol):
  ```
  port v1 <sha> — <summary>

  <body — explain v2 adaptations if non-obvious>

  Constraint: v2 uses tenantTransactionManager + Jakarta namespace
  Confidence: high | medium | low
  Scope-risk: narrow | moderate | broad
  Not-tested: <edge case or leave blank>

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```

## 9. Sync-log Update Protocol

- After each phase lands, append (or update) a row in `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md` — do NOT wait until Phase 4 completes to record Phase 1's progress.
- Final row after all phases: `wms-api` anchor advanced to `257b6e2` (current v1 HEAD at time of plan writing — re-verify on session day).
- If Phase 3 produces a "skip with rationale" decision, the rationale lives in the plan (§4.6.1) AND is one-line-summarized in the sync-log Notes column.

## 10. Rollback Plan

- **Per-commit revert:** every v2 commit is atomic and traceable to a v1 SHA; `git revert <v2-sha>` is the primary rollback.
- **Per-phase revert:** if Phase 4 fails QA, revert the Flyway migration with a new DOWN migration (Flyway forward-only) — never delete the migration file.
- **Sync-log consistency:** on any rollback, move the `wms-api` anchor back to the last-good pre-rolled-back SHA in the log and note the regression.

## 11. References

- Applicability report: [`../../../3-Resources/reports/wms-api-v1-commits-post-2026-03-20-applicability.md`](../../../3-Resources/reports/wms-api-v1-commits-post-2026-03-20-applicability.md)
- Sync workflow: [`../../../2-Areas/wms-v1-v2-sync/README.md`](../../../2-Areas/wms-v1-v2-sync/README.md)
- Sync log: [`../../../2-Areas/wms-v1-v2-sync/sync-log.md`](../../../2-Areas/wms-v1-v2-sync/sync-log.md)
- Prior batch port (March 2026): [`../../../4-Archieves/wms2/plan/260424-V1_Develop_Arden_Commits_March2026_Port.md`](../../../4-Archieves/wms2/plan/260424-V1_Develop_Arden_Commits_March2026_Port.md)
- Consolidated picking fixes port: [`../../../4-Archieves/wms2/plan/260424-V2_Consolidated_Picking_Fixes_Port.md`](../../../4-Archieves/wms2/plan/260424-V2_Consolidated_Picking_Fixes_Port.md)

## 12. Implementation Status

| Phase | Status | v2 commits | Notes |
|-------|--------|-----------|-------|
| 0 | **Closed 2026-04-18** | — | All Bucket B / D verifications complete. Results: `46130c3` absent → ported in Phase 1. `50edfe7` **already in v2** (Phase 7 Part A footprint at `CustomerorderService.java:553,558,578,605-606`) → moved to Bucket A, no port needed. `d52046e` absent in v2 → port in Phase 2. `f0bef13` v2-state inspected (retry expansion ✅; `showLog()` cache ❌; `@Transactional` on `recalculateOpenOrders()` ❌) — judgment call remains for Phase 3. |
| 1 | **Implemented + tested 2026-04-18** on `sync/wms2-api/phase1-standalone-bugs` | Port commits: `c0f3f1b` (v1 `4c8d500`), `3a67497` (v1 `98fce54`), `cb5740d` (v1 `8957b9a`), `275a7dd` (v1 `46130c3`). Test commit: `4840be9` | 4 ports + 1 test commit. Test results: MobilePalletizingServiceUnitTest 44/0/0 (+2 new: `portV1_46130c3_*`), BillofladingServiceUnitTest 55/0/0 (+1 new: `portV1_98fce54_*`), FileImportControllerUnitTest 33/0/0 (1 updated: `shouldRejectSkuWithNonExistentClient` now asserts FIX instead of BUG). **Deliberately skipped:** Testcontainers integration test for `cb5740d` (getOpenBOLSkuAmountDetail JPQL rewrite) because `BillofladingPositionRepositoryTest` is `@Disabled` for a pre-existing landlord datasource env issue — add when env is fixed. Branch not merged. |
| 2 | **Implemented + tested 2026-04-18** on `sync/wms2-api/phase2-pallet-name-validation` | Port commit: `0eb8f2f` (v1 `d52046e`). Test commit: `5669d57` | 1 port + 1 test commit. Test result: ReceivingControllerUnitTest 31/0/0 (+1 new: `portV1_d52046e_shouldRejectDuplicatePalletName`). First test-pass failed because it asserted `never()`-called downstream createPallet, but v1 patch doesn't early-return — test revised to match actual ported behavior (gate caught the expectation mismatch). Branch not merged. |
| 3 | **Decided 2026-04-18 — no port needed** | (no commits) | `50edfe7` already in v2 (resolved in Phase 0). `f0bef13` judgment: **SKIP with rationale.** v1 fix targeted StaleObjectStateException caused by (a) `BasicService.showLog()` running a raw native query each log call → triggering Hibernate auto-flush, and (b) `recalculateOpenOrders()` lacking `@Transactional`. v2 mitigates both architecturally: `BasicService.showLog()` delegates to `syspropService.getSysvalue()` which is Caffeine/Redis-cached (Phase 3 `7c6bcf7`) — no native query auto-flush trigger; and `recalculateOpenOrders(...)` catches `Exception` per-order in the inner loop (lines 86-89 of `ReplenishmentOrderMaintenanceService.java`) providing fault isolation that v1 lacked. Phase 1 transaction-safety expansion (`25001a9`) covers the retry side. Empty `sync/wms2-api/phase3-judgment-items` branch deleted. **Follow-up:** filing a separate investigation for the broader question of "should `ReplenishmentOrderMaintenanceService` have class-level `@Transactional(tenantTransactionManager)`?" — this is not needed to skip `f0bef13` but is a real tech-debt observation. |
| 4 | **Implemented + tested (env-limited) 2026-04-18** on `sync/wms2-api/phase4-transaction-detail` | `cfc46d4` (port + smoke test), `120db54` (@Disabled fix) | 1 new Flyway migration + 1 integration test (disabled). Option A (straight port) chosen: v2 already had `transaction_detail` in `V1.1.04__wms_functions.sql` with an older body, and v2 Java callers already expect the function signature. New `V2.1.07__update_transaction_detail_pick_amount_filter.sql` (398 lines) does `CREATE OR REPLACE` to add the `and sr.amount != 0` filter to the PICKING branch. `V1.1.04` unchanged (Flyway immutability). Smoke integration test in `ClientRepositoryIntegrationTest.GetTransactionDetailSmokeTest` annotated `@Disabled` with the same rationale as `BillofladingPositionRepositoryTest` — pre-existing landlord datasource env issue (HikariConfig: dataSource or jdbcUrl is required). **Full behavioral verification (zero-amount PICKING filter under seeded stockrecords) is a follow-up** once CI landlord wiring is confirmed. Branch not merged. |

### 12.3 Full suite verification

- Integrated all three phase branches into a temporary `test/phase1-2-4-integration` branch (clean ort-strategy merges, no conflicts).
- `mvn test`: **Tests run: 3811, Failures: 0, Errors: 0, Skipped: 65** → **BUILD SUCCESS**.
  - 64 pre-existing skips (mostly `@Disabled("landlord datasource")` and Keycloak-env classes)
  - +1 new skip: Phase 4 smoke test `@Disabled` on the same landlord rationale
- No regressions from Phase 1 / Phase 2 / Phase 4 in the combined test suite.
- Integration branch deleted after verification.

### 12.1 Phase 1 summary

| v1 SHA | v2 SHA | File | Verdict |
|--------|--------|------|---------|
| `4c8d500` | `c0f3f1b` | `controller/FileImportController.java` | Added `if (client.isPresent())` guard before SKU duplicate check to prevent NSEE when shipper code is unknown. |
| `98fce54` | `3a67497` | `service/BillofladingService.java` | Added explicit `setShipped(null)` at BOL creation path. |
| `8957b9a` | `cb5740d` | `repo/jpa/BillofladingPositionRepository.java` | Rewrote `getOpenBOLSkuAmountDetail` native query to start FROM `customerorder` and JOIN through `billoflading_position` so empty BOLs return zero rows. |
| `46130c3` | `275a7dd` | `service/mobile/MobilePalletizingService.java` | Unified parcel-not-found and order.CANCELED messages in `scanParcel()` to "The parcel has been cancelled and cannot be palletized!". Bucket B-confirmed port. |

### 12.4 Completion verification (2026-05-21)

Re-analyzed current `develop` branch. All fixes confirmed present — shipped via independent paths after topic branches were deleted:

| Fix | Verdict | Notes |
|---|---|---|
| Phase 1 — SKU import shipper guard | ✅ Present | `FileImportController.java:325,343` — `if (!client.isPresent())` guard |
| Phase 1 — BOL shippedDate null | ✅ Present | `BillofladingService.java:239` — `setShipped(null)` |
| Phase 1 — Empty BOL export | ✅ Present | `BillofladingPositionRepository.java:43–62` — INNER JOIN query |
| Phase 1 — Parcel-cancelled message | ✅ Present | `MobilePalletizingService.java:97,113` — unified message |
| Phase 2 — Duplicate pallet name | ✅ Intentional v2 delta | `UnitloadService.createUnitload()` returns existing pallet (idempotent); v1 rejected with 422 — v2 behavior is by design |
| Phase 3 — Judgment calls | ✅ No port needed | Confirmed at time of execution |
| Phase 4 — transaction_detail filter | ✅ Present | `V2.1.07__update_transaction_detail_pick_amount_filter.sql` on `develop`; callers wired. Smoke test `@Disabled` due to pre-existing landlord CI env issue (infra ticket, not code gap) |

**Archived 2026-05-21.** Open item: re-enable `GetTransactionDetailSmokeTest` once CI landlord datasource is fixed.

> Acceptance script: none (sync/migration plan — no verify-*.sh generated).

---

### 12.2 Phase 1 verification

- Atomic per-commit: ✅ — one v1 subject per v2 commit; all carry `(cherry picked from)`-style `port v1 <sha> — ...` subjects with OMC trailers.
- Compile check: ✅ `mvn compile -q -DskipTests -T 4` exit 0 (silent — clean).
- Test suite: not run — v1 commits added no tests, so no mechanical port. Manual QA checklist in §5.
- Merge posture: on topic branch, NOT fast-forwarded into `develop-arden` yet. Await compile + review.
