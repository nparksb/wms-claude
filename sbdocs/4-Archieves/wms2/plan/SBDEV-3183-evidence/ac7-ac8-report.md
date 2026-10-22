---
ticket: SBDEV-3183
scope: AC-7 (PIT + hand mutants on SDR rules) and AC-8 (full suite vs fresh baseline, by name)
date: 2026-10-21
repo: v2/wms2-api
kind: measurement — no product code changed, nothing committed or pushed
---

# SBDEV-3183 — AC-7 / AC-8 measurement report

## Verdicts

- **AC-7: PASS.** PIT 110/110 mutants killed across all 7 `Sdr*` classes (0 survived, 0 no-coverage). Hand mutants: removing each of the 27 type rules and each of the 4 search overrides turned the security unit suite red 31/31 times, and every one has at least one failure whose message names that resource.
- **AC-8: PASS.** Full `-Pci` suite is green on both develop and baseline. Failing, erroring and skipped test **names** are identical in both lanes: 0 added, 0 removed.

Findings: **1**. It is a fault in the prescribed hand-mutant command, not in the product. See §5.

## 1. SHAs and worktrees

| Role | SHA | Worktree (left in place) |
|---|---|---|
| develop (measured) | `cb692ee680d18758f0de513f243df7ce7210078d` (= `origin/develop` at fetch, Merge PR #550; `cb692ee6` exactly, ancestor check OK) | `.claude/worktrees/wms2-api/SBDEV-3183-ac78` |
| baseline | `5016bb19f9491a9c55a54e5ec98851f577818f8f` = `944cc789^1` | `.claude/worktrees/wms2-api/SBDEV-3183-ac8-base` |

`gh pr view 527 --repo SiteBossInc/wms2-api --json mergeCommit` returns `944cc7897ee8ae44841c839ab08bfaa293c87fa8` ("SBDEV-3183 AC-5: log every SHADOW would-deny…"), so the baseline is the parent of PR #527's merge. ⚠ That baseline is **not** pre-SBDEV-3183. Earlier slices of the ticket were already in it (`SdrFunctionGuardUnitTest` has 40 tests there). Between baseline and develop there are 43 merges, and 12 of them are SBDEV-3183.

Toolchain: Maven 3.9.15, Java 21.0.11 (Microsoft), `JAVA_HOME=$HOME/.sdkman/candidates/java/21.0.11-ms`. Both worktrees show `git status --porcelain` empty after all runs.

## 2. Commands

```
# AC-8 — both worktrees, identical command
mvn -B -ntp clean verify -Pci -Dmaven.javadoc.skip=true -Dspringdoc.skip=true
# AC-7 PIT (develop worktree, after the suite)
mvn -o -q test-compile
mvn -o org.pitest:pitest-maven:mutationCoverage \
  -DtargetClasses='net.aim_ai.wms.security.SdrFunctionRules,net.aim_ai.wms.security.SdrFunctionGuard,net.aim_ai.wms.security.SdrRuleStartupCheck,net.aim_ai.wms.security.SdrRuleStartupAssertion,net.aim_ai.wms.security.SdrGuardMode,net.aim_ai.wms.security.SdrGuardModeProvider,net.aim_ai.wms.security.SdrVerdict' \
  -DtargetTests='net.aim_ai.wms.unit.security.*'
# AC-7 hand mutants, one per rule/override (delete the line range, run, capture XML, restore)
mvn -o -q test -Dtest='net/aim_ai/wms/unit/security/**' -Dsurefire.failIfNoSpecifiedTests=false
git checkout -- src/main     # after each mutant; git status confirmed clean every time
```

PIT scope was widened from the 4 named classes to every `Sdr*` class under `src/main/java/net/aim_ai/wms/security/`. All 4 named classes exist. The 3 extra are `SdrGuardMode`, `SdrGuardModeProvider` and `SdrVerdict`.

The hand-mutant filter is **not** the one in the brief. See Finding F1.

## 3. AC-8 — full suite, develop vs baseline

| Lane | develop pass / fail / error / skip | baseline pass / fail / error / skip | Maven console line (develop · base) | Wall time (develop · base) |
|---|---|---|---|---|
| Unit (surefire) | 8517 / 0 / 0 / 1 | 8433 / 0 / 0 / 1 | `Tests run: 8529 … Skipped: 1` · `8445 … Skipped: 1` | 12:37 · 18:02 |
| IT (failsafe) | 914 / 0 / 0 / 23 | 894 / 0 / 0 / 23 | `Tests run: 937 … Skipped: 23` · `917 … Skipped: 23` | (same build) |

Both builds ended `BUILD SUCCESS`. Counts in the per-state columns are **distinct `classname#name`** from the XML. The surefire console total is 11 higher on both sides because some parameterized cases repeat a display name. The offset is the same on both sides, so it does not affect the comparison.

### By name

| Set | Added (develop only) | Removed (baseline only) |
|---|---|---|
| Unit failures | none | none |
| Unit errors | none | none |
| Unit skipped | none | none |
| IT failures | none | none |
| IT errors | none | none |
| IT skipped | none | none |

The skipped sets are identical on both sides:
- **Unit (1):** `landlord.config.TenantPoolEndpointSecurityTest#evict_missingAdminRole_forbidden`
- **IT (23):**
  - `ReplenishDupConcurrencySliceIT#ac2_throwAfterSave_persistsNoReplenishorderRow`
  - `ClientControllerIntegrationTest#returnsAllClientsWithPagination`
  - `CyclecountRepositoryIntegrationTest$NativeSqlWithJoins` ×3
  - `LocationRepositoryIntegrationTest$NativeSqlQueries` ×3
  - `MessageRepositoryIntegrationTest$ArchiveMessages#shouldArchiveOldMessages`
  - `ReplenishorderRepositoryIntegrationTest$*`: 11 nested classes, skipped at class level
  - `KeycloakServiceIntegrationTest` ×3

### Why the totals differ (rough)

- **Unit +84:**
  - SBDEV-3183's own tests add +53: `SdrFunctionGuardUnitTest` 40→55, `SdrFunctionRulesUnitTest` 27→55, new `SdrMustStayOpenRailUnitTest` with 10.
  - Other tickets merged in the same window add the rest. New classes include `EmptyPalletCleanupJobUnitTest` (+26), `UnitloadBusinessServiceRelocateEmptyStoragePalletTest` (+17), `CustomerorderShipperServiceUnitTest` (+14), `OrderRestControllerUnitTest$UpdateShipperEndpoint` (+10) and others.
  - Large `*Test` → `*UnitTest` renames (job classes, `MobileTruckLoading/Palletizing/MoveUnitload`, `FileExport`) net to roughly zero.
- **IT +20:** new ITs `EmptyStoragePalletCandidatesIT` (9), `UnitloadSkipLockedIT` (4), `RelocateEmptyStoragePalletIT` (4), `EmptyPalletCleanupSeedMigrationIT` (2) and `IntegrationProfileDatabaseNameContextIntegrationTest` (1). In addition, `ActivateTransferAtomicityIT` went 2→3 and `CancelOrderRollbackIntegrationTest` went 3→2.

## 4. AC-7 — mutation checks

### 4.1 PIT (scoped, develop worktree)

| Class | Killed | Survived | No coverage |
|---|---|---|---|
| SdrFunctionGuard (incl. inner) | 57 | 0 | 0 |
| SdrRuleStartupAssertion | 21 | 0 | 0 |
| SdrFunctionRules | 11 | 0 | 0 |
| SdrGuardMode | 10 | 0 | 0 |
| SdrRuleStartupCheck | 6 | 0 | 0 |
| SdrGuardModeProvider | 3 | 0 | 0 |
| SdrVerdict | 2 | 0 | 0 |
| **Total** | **110** | **0** | **0** |

- PIT reports test strength 100% and line coverage of mutated classes 284/296.
- None of the 12 uncovered lines carries a mutant.
- 155 test executions, 1.41 per mutant.
- **Survivors: none.** Raw `mutations.xml` is in the scratchpad copy and in `target/pit-reports/` of the develop worktree.

### 4.2 Hand mutants (31 = 27 type rules + 4 search overrides)

- **Control:** with no mutation, the same filter ran 281 tests with 0 failures, 0 errors and exit 0.
- **Mutants:** each mutant deleted exactly the listed line range of `SdrFunctionRules.java`. A two-line range means a two-line `overrides.put(...)`. `git diff --stat` showed one file changed for each mutant.
- **Columns:**
  - *fails* = failing or erroring testcases.
  - *naming* = how many of those failures name the target in their message head (stack trace excluded).
  - *attribution* = `targeted` when a dedicated assertion description or message names the type, its REST path or the override path.
- **Excerpt:** the excerpt column shows the first targeted message for that mutant. Each kill message was checked individually.

| # | kind | target | lines | tests | fails | naming | result | attribution | first naming test | message excerpt |
|---|---|---|---|---|---|---|---|---|---|---|
|01|rule|User|L306|281|4|3|RED|targeted|SdrFunctionRulesUnitTest#everySlice1TypeHasARule(Class)[1]|[User is part of the authorization graph and must be gated in Slice 1] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [User |
|02|rule|UserFunction|L310|281|4|3|RED|targeted|SdrFunctionRulesUnitTest#everySlice1TypeHasARule(Class)[2]|[UserFunction is part of the authorization graph and must be gated in Slice 1] Expecting Optional to contain a value but it was empty. java.lang.AssertionError:|
|03|rule|UserGroup|L320|281|23|7|RED|targeted|SdrFunctionGuardUnitTest#shadowLogsEachReasonAtItsLevel(Reason, String)[1]|ontain exactly (and in same order): ["ERROR SHADOW: would deny WEB_UI_VIEW_GROUP on SDR[UserGroup] GET /v3/userGroup for user 'sbtest' (USER_NOT_PROVISIONED)"] but could not find the following elements: ["ERROR SHADOW: would deny WEB_UI_VIEW_GROU|
|04|rule|UserGroupUser|L323|281|4|3|RED|targeted|SdrFunctionRulesUnitTest#everySlice1TypeHasARule(Class)[4]|[UserGroupUser is part of the authorization graph and must be gated in Slice 1] Expecting Optional to contain a value but it was empty. java.lang.AssertionError|
|05|rule|UserRole|L332|281|6|3|RED|targeted|SdrFunctionRulesUnitTest#everySlice1TypeHasARule(Class)[5]|[UserRole is part of the authorization graph and must be gated in Slice 1] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [U|
|06|rule|Sysprop|L394|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#syspropRequiresViewSystemProperty|[GET /v3/sysprop/search/findByGroupname?groupName=Backend returns OMS_API_USER (a live prod credential on hydra) to any authenticated wms_user without this rule] Expect|
|07|rule|Message|L401|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#messageRequiresViewMessages|ByKeyword/findByProcess/findAllFromDaysPeriod/getDetailViewByKeyword expose order-payload message bodies to any authenticated wms_user without this rule] Expecting Optional to contain: ["WEB_UI_VIEW_MESSAGES"] but was empty. java.lang.AssertionErr|
|08|rule|StockrecordView|L406|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#stockrecordViewRequiresViewStockUnitRecord|tStockUnitRecord already gates the CSV of these exact rows on this function. Unruled, /v3/stockrecordView/search/findByKeyword serves the same rows PLUS item_name/cl_nr/cl_name to any authenticated wms_user — and an unruled type is allowed at ENFORCE|
|09|rule|Advice|L434|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#adviceRequiresViewInboundBol|[Advice's only SDR caller is PATCH /advice/{id} (saveComment, closedNoticeDescription.vue on /receiving/closedNotice/:id, which the web route guard gates on WEB_|
|10|rule|Cyclecount|L437|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#cyclecountRequiresViewCyclecount|[Cyclecount's only SDR caller is PATCH /cyclecount/{id} (saveComment, plannedCycleCountDescription.vue on /internalOps/cycleCount/planned/:id, gated on WEB_UI_VI|
|11|rule|Location|L443|281|4|2|RED|targeted|SdrFunctionRulesUnitTest#locationTypeRuleRequiresViewStorageLocation|[item DELETE /location/{id} is dispatched from storageLocation.vue on the Storage Locations screen (WEB_UI_VIEW_STORAGE_LOCATION)] Expecting Optional to contain: ["WEB_UI_|
|12|rule|Goodsreceiptposition|L465|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[1]|[Goodsreceiptposition must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError|
|13|rule|Itemunit|L469|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[2]|[Itemunit must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Itemunit|
|14|rule|LocationArea|L473|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[3]|[LocationArea must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Loca|
|15|rule|LocationRack|L478|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[4]|[LocationRack must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Loca|
|16|rule|LocationType|L481|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[5]|[LocationType must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Loca|
|17|rule|LockOverviewDtoView|L486|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[6]|[LockOverviewDtoView must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError:|
|18|rule|LockOverviewAllDtoView|L487|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[7]|[LockOverviewAllDtoView must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionErr|
|19|rule|Printer|L492|281|5|4|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[8]|[Printer must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Printer m|
|20|rule|ReceivingDtoView|L498|281|5|4|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[9]|[ReceivingDtoView must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [|
|21|rule|Replenishorder|L502|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[10]|[Replenishorder must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Re|
|22|rule|StockView|L505|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[11]|[StockView must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [StockVi|
|23|rule|Unitload|L511|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[12]|[Unitload must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Unitload|
|24|rule|Pickingorder|L519|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[13]|[Pickingorder must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Pick|
|25|rule|UnitloadRecord|L523|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[14]|[UnitloadRecord must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Un|
|26|rule|UnitloadType|L529|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[15]|[UnitloadType must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.AssertionError: [Unit|
|27|rule|ViewWarehouseLocationReport|L533|281|2|2|RED|targeted|SdrFunctionRulesUnitTest#needsGatingTypeRequiresExactlyItsScreenFunctions(Class, List)[16]|[ViewWarehouseLocationReport must carry a rule (needs-gating caller sweep 2026-10-20)] Expecting Optional to contain a value but it was empty. java.lang.Asserti|
|28|override|Location/search/findByGateTrue|L545-546|281|3|2|RED|targeted|SdrFunctionGuardUnitTest#searchOverrideReachesAccessService(String, String, String)[1]|[location/search/findByGateTrue must be checked against WEB_UI_VIEW_BILL_OF_LADING] Expecting actual: ["WEB_UI_VIEW_STORAGE_LOCATION"] to contain exactly (and|
|29|override|Location/search/getAllCrossDockingLanes|L550-551|281|3|2|RED|targeted|SdrFunctionGuardUnitTest#searchOverrideReachesAccessService(String, String, String)[2]|[location/search/getAllCrossDockingLanes must be checked against WEB_UI_VIEW_INBOUND_BOL] Expecting actual: ["WEB_UI_VIEW_STORAGE_LOCATION"] to contain exactl|
|30|override|Printer/search/findByType|L572-573|281|4|4|RED|targeted|SdrFunctionGuardUnitTest#searchOverrideReachesAccessService(String, String, String)[5]|[printer/search/findByType must be checked against WEB_UI_VIEW_PRINTER\|WEB_UI_VIEW_INBOUND_BOL\|WEB_UI_VIEW_CLIENT\|WEB_UI_VIEW_PARCEL_PICKING] Expecting actual: |
|31|override|ReceivingDtoView/search/findByKeyword|L578-579|281|4|4|RED|targeted|SdrFunctionGuardUnitTest#searchOverrideReachesAccessService(String, String, String)[7]|[receivingDtoView/search/findByKeyword must be checked against WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW] Expecting actual: ["WEB_UI_VIEW_INBOUND_BOL"] to contain e|

**Result: 31/31 red, and 31/31 have a failure that names the protected resource.**
- **How Location and Sysprop are named:** both get a dedicated test whose description names the REST path rather than the class. For example, `[item DELETE /location/{id} …]` and `[GET /v3/sysprop/search/findByGroupname … ]`.
- **Second line of defence:** for types like Sysprop, the full-set test `ruledDomainTypesMatchesTheFullRuleSet` also names the class, as `could not find the following elements: [net.aim_ai.wms.model.Sysprop]`.
- **Location overrides:** the two Location overrides (#28, #29) are named by `searchOverrideReachesAccessService`, which says `[location/search/findByGateTrue must be checked against …]`. The exact-set test also names them, as `SearchOverrideKey[… Location, searchPath=…]`.
- **Unattributable hand mutants: none.**

## 5. Findings

| # | Severity | Finding | Kind | Proposed fix |
|---|---|---|---|---|
| F1 | Medium (instrument) | **The brief's hand-mutant filter `-Dtest='net.aim_ai.wms.unit.security.*'` selects zero tests.** With `-Dsurefire.failIfNoSpecifiedTests=false`, Maven exits 0 and writes no surefire XML, so every mutant reads **green**. The first 3 mutants of the first loop did exactly that (`rc=0`, 0 reports); that loop was killed and discarded. Surefire matches `-Dtest` against class *paths*, so a dotted package plus `.*` matches nothing. PIT's `-DtargetTests` with the same string does work, because PIT globs class names. That is why PIT found tests and surefire did not. | Measurement-instrument gap, not product | Use `-Dtest='net/aim_ai/wms/unit/security/**'`, which gave 281 tests here. Also assert `tests > 0` from the XML before reading any exit code as a verdict. Worth a line in `sbdocs/9-System/mutation-testing-recipe.md` and in `hub-mutation-testing`. |

PIT survivors: **none**. Hand-mutant assertion gaps: **none**.

## 6. Raw artefacts (scratchpad, session-local)

Everything is under `/tmp/claude-1000/-home-nampark-dev-wms-claude/106c745f-922c-4987-90b6-23ad90878c48/scratchpad/`:

| What | Path |
|---|---|
| Suite logs | `dev-suite.log`, `base-suite.log` |
| develop XML (copied before PIT) | `dev-reports/{surefire,failsafe}-reports/` |
| Baseline XML | `.claude/worktrees/wms2-api/SBDEV-3183-ac8-base/target/{surefire,failsafe}-reports/` |
| PIT | `pit.log`, `mutations.xml` |
| Hand mutants (per mutant: removed lines, diffstat, Maven log, rc, reports) | `hm/NN.*`; control run in `hm/control.*` |
| Runner and parser | `handmut.sh`, `parse_hm.py`, `mutants.tsv` |
| AC-8 diff | `ac8-compare.txt` |
