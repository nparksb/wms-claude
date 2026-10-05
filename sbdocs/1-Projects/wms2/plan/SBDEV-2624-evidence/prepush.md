# SBDEV-2624 — pre-push evidence (2026-10-04)

Nothing has been pushed and no PR has been opened. Both branches are rebased onto freshly fetched `origin/develop`, and `git merge-base --is-ancestor origin/develop HEAD` succeeds in both trees.

## HEADs after the rebase

| Repo | Branch | HEAD | origin/develop | Pre-rebase HEAD |
|---|---|---|---|---|
| wms2-api | feature/SBDEV-2624-sku-rename-in-place | `ef96c2a8deb23094d056fb2f005fde997a9b2a92` | `e3dfcc72` | `f35352d7` |
| oms-laravel-api | feature/SBDEV-2624-facility-item-id | `c21a2a6fe047746cf199368a5d7ab09af9573bbc` | `eebba258` | `2e48c0ed` (+ step-1 `1da56f09`) |

Both rebases ran non-interactively and finished with no conflicts (wms2 12/12 commits, OMS 10/10). Neither diff contains a migration file, so there is no Flyway version to collide.

## Step 1: the last r4 Low (OMS)

- **Test:** a new data-provider row in `it_skips_the_resend_when_the_reloaded_product_is_no_longer_syncable`: `'SKU is only a form feed' => ['empty sku', "\x0C"]`. The DB row's `product_sku` becomes `"\x0C"` between the first attempt and the reload. The test expects exactly one `rest/sku/update` (no resend) and a `resync-skipped` log with `reason = 'empty sku'`.
- **Green:** 4/4 provider rows.
- **Mutant:** `:1793` `trim((string) $fresh->product_sku, "\x00..\x20")` changed to `trim((string) $fresh->product_sku)`. Only the form-feed row goes red, and it fails for the right reason: `[empty sku] expected one update and no resend, got 2`. The SKU survived the default trim, the guard passed, and an update with sku `''` was resent. The file was restored from `/tmp/sbdev2624-mut/WmsApiService.php.orig` (sha `a2124b25…` matched before and after).
- **Sibling r4 Low (kill proof for `it_trims_edge_control_characters…`), run in the same harness:** default-trim mutants at `:1652` (previous_sku), `:1904` (buildSkuDataFromProduct sku) and `:2022` (delete sku) were all killed, with 1, 3 and 1 rows red. Restored, sha matched.
- **Still unpinned:** `:2030`, the delete **log** `sku` field, which is logging only and was not part of the requested scope.
- **DB targets checked before running:** `omsenv.sh` passes `-e DB_HOST/LANDLORD_HOST/REPORTING_HOST=oms-test-mysql`, `MONGODB_HOST=oms-test-mongo`, on `oms-test-net`. Real env vars take precedence over `.env.testing`, whose hosts are `127.0.0.1`, the container's own loopback, where nothing listens. `config/database.php` `testing` hardcodes `om1_owltest`. `oms-test-mysql` holds only `om1_owltest`, `om1_landlord_owltest` and `om1_owltest_reporting`.
- **Commit:** `1da56f09`, rebased to `c21a2a6f`, "SBDEV-2624: pin the masked trim on the empty-sku guard", with the Co-Authored-By trailer.

## Commits vs origin/develop

### wms2-api (12)
```
ef96c2a8 SBDEV-2624: review round 3 — create/delete edge-control tests, test name, dead check
ba1c886f SBDEV-2624: review round 2 — uncached previous_sku lookup, review Lows
0e37d1ed SBDEV-2624: review round 1 — every Low from the wms2 code and security reviews
fd330c57 SBDEV-2624: review round 1 — D-M3, no rename without previous_sku
d17ebea5 SBDEV-2624: D-M2 — pin the CAS when previous_sku == sku and the row holds another code
fc8d573b SBDEV-2624: upsertAll — orElse(null) instead of Optional.get() (OptionalSafetyArchTest)
8bd441b8 SBDEV-2624: mutation follow-up — kill PIT survivors in SkuBatchCreateUpdateService
eae093fb SBDEV-2624: AC-10b — filter transaction_detail on its display label 'Received'
22e9a395 SBDEV-2624: SkuRestController resolves by facility_item_id -> previous_sku -> sku and answers 200 with item_ids
7af379cb SBDEV-2624: upsertAll renames in place — reload, CAS, collision, ordered rewrite, translated flushes
9c20a39d SBDEV-2624: contract — codes 108/109 with text and name arms, findByIdAndClientId not exported
e035abf8 SBDEV-2624: TDD gate — failing acceptance tests and compile-only skeletons
```

### oms-laravel-api (10)
```
c21a2a6f SBDEV-2624: pin the masked trim on the empty-sku guard
122c606d SBDEV-2624: review round 3 — Java-parity trim on outbound SKUs, comments
1d7f9e78 SBDEV-2624: wrap the Known limit docblock line (review round 4)
e3685ea6 SBDEV-2624: review round 3 — Java-parity trim, assert reason key
113fbcb1 SBDEV-2624: review round 2 — attributable kill for unquoted previous_sku
cddb2c36 SBDEV-2624: review round 2 — api-docs reset to one line, regex metachar tests, review Lows
90949417 SBDEV-2624: D-M3 — guarded resend carries previous_sku = D
528a89ab SBDEV-2624: review round 1 — D-M2 expected code, guard hardening, review Lows
ccfded37 SBDEV-2624: rename a SKU in place at the WMS (OMS side, P2)
0a4b8e2b SBDEV-2624: TDD gate — failing acceptance tests and compile-only skeletons
```

## Diffstat vs origin/develop

### wms2-api
```
 .../wms/controller/rest/SkuRestController.java     | 153 +++-
 src/main/java/net/aim_ai/wms/json/SkuDto.java      |  24 +
 .../aim_ai/wms/repo/jpa/ItemdataRepository.java    |   9 +
 .../aim_ai/wms/repo/jpa/StockrecordRepository.java |  13 +
 .../wms/service/SkuBatchCreateUpdateService.java   | 240 +++++-
 .../java/net/aim_ai/wms/service/WmsConstants.java  |  17 +
 .../aim_ai/wms/integration/SkuRenameInPlaceIT.java | 677 ++++++++++++++++
 .../SkuRestControllerAtomicityIntegrationTest.java |   4 +-
 .../rest/SkuRestControllerIntegrationTest.java     |   4 +-
 .../unit/config/CacheEvictionOnWriteUnitTest.java  |   7 +-
 .../config/NeverMatcherNullBlindnessArchTest.java  |   6 +
 .../TestClassTransactionManagerArchTest.java       |   3 +
 .../controller/rest/SkuRestControllerUnitTest.java | 564 +++++++++++++-
 .../repo/ItemdataRepositorySdrExportUnitTest.java  |  37 +
 .../repo/StockrecordRenameQueryShapeUnitTest.java  |  49 ++
 .../SkuBatchCreateUpdateServiceUnitTest.java       | 849 ++++++++++++++++++++-
 .../service/WmsConstantsSkuRenameUnitTest.java     |  53 ++
 17 files changed, 2637 insertions(+), 72 deletions(-)
```

### oms-laravel-api
```
 .../Commands/BackfillFacilityWmsItemsCommand.php   |   2 +
 .../Api/Legacy/LegacyInventoryController.php       |   2 +-
 .../Api/Legacy/LegacyV2ProductController.php       |   6 +-
 .../Controllers/Api/Legacy/LegacyWmsController.php |  25 +-
 app/Http/Controllers/Api/ProductController.php     |  10 +-
 app/Jobs/BackfillFacilityWmsItemsJob.php           |   6 +
 app/Models/ProductWmsItem.php                      |  19 +-
 .../Legacy/LegacyInventoryAdjustService.php        |  53 +-
 app/Services/Legacy/LegacyProductUpdateService.php |  19 +-
 app/Services/WmsApiService.php                     | 381 ++++++++-
 app/Services/WmsFacilitySyncService.php            | 157 +++-
 storage/api-docs/api-docs.json                     |   2 +-
 tests/Feature/Api/FacilityWmsSyncTest.php          | 223 +++++
 .../Api/Legacy/LegacyV2ProductWmsSyncTest.php      |  90 ++
 .../Api/Legacy/LegacyWmsControllerItemIdTest.php   | 120 +++
 tests/Feature/Api/ProductControllerTest.php        | 125 +++
 .../Api/V1Services/V1ServicesControllerTest.php    |  73 ++
 tests/Feature/Services/WmsApiServiceTest.php       | 920 ++++++++++++++++++++-
 tests/Unit/Models/ProductWmsItemTest.php           |  26 +
 .../Legacy/LegacyInventoryAdjustmentAlertTest.php  |  36 +
 .../LegacyInventoryStockUpdateReallocationTest.php |  35 +
 .../LegacyProductUpdateServiceItemIdTest.php       |  67 ++
 22 files changed, 2228 insertions(+), 169 deletions(-)
```

## Test counts (all after the rebase, JDK 21 for wms2)

| Run | Result |
|---|---|
| wms2 `mvn clean compile` | BUILD SUCCESS |
| wms2 targeted unit: NeverMatcherNullBlindnessArchTest 4, TestClassTransactionManagerArchTest 5, CacheEvictionOnWriteUnitTest 17, SkuRestControllerUnitTest 55 (nested), SkuBatchCreateUpdateServiceUnitTest 38, WmsConstantsSkuRenameUnitTest 2, StockrecordRenameQueryShapeUnitTest 1, ItemdataRepositorySdrExportUnitTest 1 | **123 run, 0 F, 0 E, 0 S** |
| wms2 ITs via failsafe: SkuRenameInPlaceIT 19, SkuRestControllerIntegrationTest 3, SkuRestControllerAtomicityIntegrationTest 3 | **25 run, 0 F, 0 E, 0 S** (run twice, both green) |
| wms2 full `mvn clean test` | **7788 run, 0 F, 0 E, 1 skipped**, BUILD SUCCESS. Last recorded: 7859 / 0 / 0 / 1 |
| OMS §7.2 filter set + V1ServicesControllerTest | **326 passed** (5469 assertions). Last: 325 (+1 = the new form-feed row) |

**Why the wms2 total fell by 71.** Failures are unchanged at 0, and the drop comes from develop. Between the old base `7762aa64` and `e3dfcc72`, develop merged SBDEV-3638 ("delete the single-UL replenish endpoints"), which cut `MobileReplenishServiceUnitTest` by 84 test annotations and `ReplenishControllerUnitTest` by 12, plus small `MobileReplenishServiceH2Test` changes. It also merged SBDEV-3636 (ManualCutCooldown and others, adding tests). Summing the annotation deltas over surefire-lane files gives −74. The measured run delta is −71, and parameterized expansion plausibly accounts for the remaining 3 (for example `MobileReplenishServiceUnitTest` is 103 annotations but 117 runs). I did not reconcile that gap exactly, because that needs a full develop-only run. This branch's own test files were not changed by the rebase.

**The `[ERROR] An error has occured` line in the `mvn verify` output** comes from `springdoc-openapi:1.4:generate`. It tries to fetch from a running app and gets `ConnectException: Connection refused`, the build still ends in SUCCESS, and nothing in this branch causes it.

## Verify script: `sbdocs/9-System/scripts/verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync.sh`

The script has one row, R1. It checks that `WMS_RESYNC_MARKERS[0]` and `[1]` are each a plain prefix of the `getErrorCodeText()` text arm for 108 and 109. It fails closed when a file is missing or unreadable, when the method, a case arm or the constant is missing, when the constant is not a single-line list of exactly 2 plain literals, when a literal carries an escape, and when a marker is empty. `PROJECT_ROOT` has no default.

### (a) GREEN — shadow root with both ticket worktrees
```

verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync — running acceptance checks
  PROJECT_ROOT=/Users/np1076/dev/spk/owl/.claude/worktrees/.verify-root/SBDEV-2624
  wms2 -> /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-2624
  oms  -> /Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624

  PASS  R1        each OMS WMS_RESYNC_MARKERS entry prefixes its wms2 108/109 getErrorCodeText() text
          108: 'sku rename precondition failed' prefixes 'sku rename precondition failed: %1s, %2s'
          109: 'sku concurrent modification' prefixes 'sku concurrent modification: %1s, %2s'

Result: 1 pass, 0 fail, 0 skip
exit=0
```

As a control, the plain monorepo root (the main checkouts, not the work) is RED at the fail-closed branch, which shows the shadow root is what is being graded.

### (b) RED on base: detached origin/develop worktrees in the scratchpad, removed afterwards
```
base wms2 HEAD e3dfcc72, base oms HEAD eebba258

verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync — running acceptance checks
  PROJECT_ROOT=/private/tmp/claude-503/-Users-np1076-dev-spk-owl/f484decd-885c-4180-b84b-9440b4c11191/scratchpad/base-root
  wms2 -> /private/tmp/claude-503/-Users-np1076-dev-spk-owl/f484decd-885c-4180-b84b-9440b4c11191/scratchpad/base-wms2
  oms  -> /private/tmp/claude-503/-Users-np1076-dev-spk-owl/f484decd-885c-4180-b84b-9440b4c11191/scratchpad/base-oms

  FAIL  R1        each OMS WMS_RESYNC_MARKERS entry prefixes its wms2 108/109 getErrorCodeText() text
          single-line const WMS_RESYNC_MARKERS = [...]; not found in v2/oms-laravel-api/app/Services/WmsApiService.php

Result: 0 pass, 1 fail, 0 skip
exit=1
--- half-base (base wms2 + ticket OMS):
  FAIL  R1        each OMS WMS_RESYNC_MARKERS entry prefixes its wms2 108/109 getErrorCodeText() text
          case SKU_RENAME_PRECONDITION_FAILED: description = "..."; not found in getErrorCodeText()

Result: 0 pass, 1 fail, 0 skip
exit=1
```

### (c) RED on one-word rewordings in a /tmp shadow copy (the copy was deleted afterwards)
```
=== (c-marker) diff vs worktree:
916c916
<     public const WMS_RESYNC_MARKERS = ['sku rename precondition failed', 'sku concurrent modification'];
---
>     public const WMS_RESYNC_MARKERS = ['sku rename precondition failed', 'sku concurrent change'];

  FAIL  R1        each OMS WMS_RESYNC_MARKERS entry prefixes its wms2 108/109 getErrorCodeText() text
          108: 'sku rename precondition failed' prefixes 'sku rename precondition failed: %1s, %2s'
          109: 'sku concurrent change' is NOT a prefix of 'sku concurrent modification: %1s, %2s'

Result: 0 pass, 1 fail, 0 skip
exit=1
=== (c-wms2text) diff vs worktree:
1814c1814
<                 description = "sku rename precondition failed: %1s, %2s";
---
>                 description = "sku rename precondition violated: %1s, %2s";

  FAIL  R1        each OMS WMS_RESYNC_MARKERS entry prefixes its wms2 108/109 getErrorCodeText() text
          108: 'sku rename precondition failed' is NOT a prefix of 'sku rename precondition violated: %1s, %2s'
          109: 'sku concurrent modification' prefixes 'sku concurrent modification: %1s, %2s'

Result: 0 pass, 1 fail, 0 skip
exit=1
=== (c-empty) marker [1] = '':
  FAIL  R1        each OMS WMS_RESYNC_MARKERS entry prefixes its wms2 108/109 getErrorCodeText() text
          108: 'sku rename precondition failed' prefixes 'sku rename precondition failed: %1s, %2s'
          109: marker is empty (prefix of everything)

Result: 0 pass, 1 fail, 0 skip
exit=1
```

`c-marker` is the rewording you asked for, on the marker side. `c-wms2text` is the plan's own wording of that red, on the wms2 text side. `c-empty` covers the one fail-open case a prefix relation has, an empty marker.

## git status after all steps
```
# wms2-api
## feature/SBDEV-2624-sku-rename-in-place...origin/develop [ahead 12]
# oms-laravel-api
## feature/SBDEV-2624-facility-item-id...origin/develop [ahead 10]
```

Both trees are clean with no untracked files. **No `.omc` files appear in either diff**: `git diff --name-only origin/develop...HEAD | grep -c .omc` returns 0 for both repos. The base-check worktrees were removed and `git worktree list` shows no `base-*` entries. Nothing under `v2/*` was touched, and no checkout, restore or stash was used on tracked work.

## Not done (by instruction)
I did not push, open PRs or update ClickUp.
