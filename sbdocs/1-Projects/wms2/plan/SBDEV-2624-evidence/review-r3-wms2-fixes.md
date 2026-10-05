# SBDEV-2624 wms2-api: review of round-2 fix commit e727b9de (r3)
head: e727b9def0ba9ddab5a4022c6e9a14d7c549eafe (worktree .claude/worktrees/wms2-api/SBDEV-2624, clean)
Scope: `git show e727b9de`, 5 files. Checked against review-r2 M1, L1-L6, fix-r1 "Round 2", plan §10 D-M2/D-M3/E-1.
Re-run (JDK 21, no other Maven running): SkuRestControllerUnitTest 53/0/0, SkuBatchCreateUpdateServiceUnitTest 38/0/0. Mutants not re-run (no edits allowed); kill claims checked by reading each assertion against its mutant.

## Verdict: COMMENT. 0 CRITICAL, 0 HIGH, 0 MEDIUM, 5 LOW, 4 Info
Every claimed fix is correct. No new defect in logic. The open item is evidence: what the pre-trim check rejects in prd was measured on the wrong side.

## Stage 1: each fix
- **M1 / E-1 #5: correct.** `SkuRestController.java:493` step 2 → `itemdataRepository` (uncached). The service's `trim()` is not lost, because `normalize()` already trimmed previous_sku. Interaction with the cache: a step-2 hit returns before step 3, so the stale (c,sku) entry is never read (this is what closes double-stale). A step-2 miss means the row was not at previous_sku when it was read. Step 3 is still cached, and a stale hit there is still discarded by D-M3 → uncached re-check by code. No new cached read was added. The `finally` eviction is unchanged and stays the only clear. The unit test (`isSameAs(x)` + `never()` on the service) and both ITs fail under "cached step 2": the single-stale IT creates a twin, so `idsFor` has 2 ids.
- **L1: correct.** `SkuBatchCreateUpdateService.java:87` defaults to `VIA_FACILITY_ITEM_ID`. The default is reachable only when `existing != null` with no via. create passes `emptyMap()` (`:149`) and update records a via for every key, so it is latent, as the r2 review said. When `existing == null` the via is never read: the re-check row holds `itemNr == code`, so `rename()` is unreachable. Both new tests fail under "default = sku": the first writes a create, the second leaves X at A.
- **L2: correct.** `setClientId(1L)` plus `saveAndFlush(argThat(i -> i == existing))` plus `never()` on the re-check. The create path would flush a new instance, so the pin is real.
- **L4: correct.** 103 on all three fields. All 7 description assertions updated.
- **L5a/L5b: correct as coded** (`:527-546`). The check runs first in create `:98`, update `:231` and delete `:384`. sku_name is checked after trim.
- **L6: correct.** The cap is 16. The real chain DIVE → Hibernate CVE → PSQLException is about 3 deep. A chain that hits the cap returns false and is rethrown as a 500, which matches E-1 #1. The 2-cycle test with `assertTimeoutPreemptively` fails under the no-cap mutant.

## Issues
[LOW] L-a: the prd evidence for the pre-trim reject does not measure the population at risk. Confidence HIGH on the gap, LOW on real exposure.
- The OMS sends `trim(product_sku)` with PHP's default mask, which strips only space, `\t\n\r\0\x0B` (oms `WmsApiService.php:1902`, `:2019`, `:1652`). Edge `\x01-\x08`, `\x0C` and `\x0E-\x1F` survive. Java `trim()` used to strip them, and now they get 103 (update/create) or 400 (delete).
- D-M2 sends `previous_sku = $sku` on every update by id. So a product whose SKU has one of these edge characters would fail every update, create and delete, including delete by id: the sku check runs before the id is used.
- The fix log counted wms2 `item_nr`. Since 260610 (FreeScout #959) wms2 has trimmed `item_nr` on create, so that count was bound to be near zero.
- Fix: before the OMS deploy, count per OMS tenant DB: `product_sku REGEXP '^[\x01-\x1f]|[\x01-\x1f]$'` (with a positive control). Or record it as an accepted, loud failure mode. A failure here is a logged 103, never silent.

[LOW] L-b: the move to pre-trim is pinned only on update. Confidence HIGH (by reading).
- The edge tests (`SkuRestControllerUnitTest:1095`, `:1108`) call `update()`. `create_lineBreakInSkuName_rejected` and `delete_controlCharacterInSku_rejected` use interior characters, which fail before and after trim alike.
- So the mutant "rejectControlCharacters after normalize()" survives in `create()` (`:98`) and in `delete()` (`:384`).
- Fix: add a `"B\n"` sku test for create (expect 422/103) and for delete (expect 400, `never().delete`).

[LOW] L-c: an error code changed on an error path that the fix log does not mention. A sku of only whitespace and control characters (for example `"\n"`, `" \t"`) used to get 100 FIELD_NOT_SET after trim and now gets 103. The OMS never sends it, since its trim empties these. Fix: note it under E-1 #4, or accept it.

[LOW] L-d: the test name is stale. `SkuRestControllerUnitTest:1056` DisplayName still says "-> 422 FIELD_NOT_SET (create)", while the body asserts 103. Fix: rename it.

[LOW] L-e: two docs no longer match the code.
- Cross-repo: the OMS `WmsApiService.php:1726-1728` and `:1753` say wms2 trims edge control characters in previous_sku. wms2 now rejects them with 103 and trims only edge spaces. Behaviour is not affected, because the OMS edge guard skips first.
- Plan: E-1 #4 says "422/103", but delete answers 400/103, and E-1 does not mention U+2028/U+2029.
- Fix: one line in each.

## Info
- I-1: `t.getCause() == t ? null : …` at `:247` is dead code, since `Throwable.getCause()` already returns null for a self-cause. Harmless.
- I-2: under the R7 mutant, the timed-out thread keeps spinning because a tight loop ignores interrupts. This affects mutant runs only.
- I-3: step 2's repository read joins step 1 in loading X into the request's tenant EM. If OSIV binds that EM, `upsertAll`'s `findById` returns the same instance and does not re-read. This is pre-existing (step 1 has the same shape), and the version check at flush still answers 109. Not introduced here.
- I-4: the edge check on sku_name after trim means `"Name\n"` is still stored as `"Name"`. That matches the OMS, which trims names too.

## Positive observations
- The M1 fix is the minimal one the r2 review proposed. It stays inside D-M3, and one IT for each stale scenario carries an assertion message that names its mutant.
- L1 changed the pinned test's expected behaviour instead of keeping it. L2 pins the update path through object identity, not through status alone.
- The fix log names a no-op control (R0) and records which mutant each test kills.
