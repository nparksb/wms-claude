---
ticket: SBDEV-3659
type: review
lane: code-reviewer (independent; not the authoring context)
reviewed: c99cf1c0 on bugfix/SBDEV-3659-delete-retired-lane-exclusion-sysprop
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3659
date: 2026-10-16
verdict: APPROVE (in-repo); two sbdocs runbook follow-ups (Medium / Low-Medium)
---

# SBDEV-3659 — code review of c99cf1c0

The reviewer did not run mvn or modify the worktree, because a full suite was running there. Evidence comes from git, file reads and read-only SELECTs on 4 PRD tenant DBs plus wineco dev.

## Summary

- Files reviewed: 4 in the commit, plus the files around them: V2.2.04, V2.2.37 and its IT, backfill-flyway-history.sh, SyspropService, 8 test files with comments about the key, 3 other v2 repos and the sbdocs runbooks.
- Counts by severity: CRITICAL 0 · HIGH 0 · MEDIUM 1 · LOW-MEDIUM 1 · LOW 6. The MEDIUM and LOW-MEDIUM findings are in sbdocs, outside git and outside the commit.
- Stage 1 (spec): **pass.** The migration deletes by syskey alone, the WmsConstants key is gone, the fixture uses a literal, and the IT copies the V2.2.37/DeadCancel harness. This is what the ticket and Nam's 2026-10-16 decision asked for.

## Requested checks

### 1. Flyway version collision: CLEAR
- Ran `git fetch -q`. origin/develop = `dd601fe9`, and `git merge-base --is-ancestor origin/develop c99cf1c0` holds, so the branch base is current.
- Swept all 433 `refs/remotes/origin/*` refs plus every local head with `ls-tree src/main/resources/db/migration/`. The **only** `V2.2.39*` is this branch's `V2.2.39__delete_retired_lane_exclusion_sysprop.sql`. No ref carries anything at V2.2.39 or V2.2.4x.
- The working trees of the other wms2-api worktrees have no untracked V2.2.39 either.
- origin/develop tops out at `V2.2.38__rts_choose_destination.sql`, so 2.2.39 is the next free number and the IT's `PRE_FIX_WATERMARK = "2.2.38"` is the correct predecessor.
- Recheck at merge time (wms-merge preflight). This is a standard race, not a finding.

### 2. Remaining references: none live
- `git grep REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES` over the whole wms2-api tree at c99cf1c0:
  - `SYSTEM_PROPERTY_REPLENISH_EXCLUDE_*` has 0 hits, so nothing will fail to compile against the deleted constant.
  - The fixture no longer imports `WmsConstants`. Its only remaining mention is in Javadoc (line 231).
  - The remaining hits are prose: `ReplenishmentOrderSourceSyncService:122`, `MobileReplenishService:1104` and test Javadoc. They are worded historically ("was gated on", "is not read") and stay accurate.
  - The applied `V2.2.04` cannot be edited. The new IT and the fixture use literals.
- wms2-web-ui and wms2-mobile-ui (origin/develop and origin/main): **0 hits.** The web-ui System Properties screen (`components/admin/parametersAndConfiguration/*`) is generic: it lists and edits whatever rows exist. Its only special case is `DEFAULT_PUTAWAY_LOCATION`. No UI expects this key.
- siteboss-frontend origin/main: 0 hits.
- oms-laravel-api: hits only in release docs (see L1).
- H2 lane: test `application*.properties` set `spring.flyway.enabled=false`, and no data.sql or initDB seed mentions the key, so H2 is unaffected.

### 3. Migration header claims: accurate
- The backfill sentence matches `src/main/resources/db/backfill-flyway-history.sh`. With no `--up-to` it records "every V*.sql present". With a cap it skips only `ver_tuple(version) > cap`, so `--up-to 2.2.39` also records V2.2.39 without running it. "no --up-to, or one at or above it" is therefore correct. See L2 for a wording nit.
- "pinned by ReplenishLaneExclusionUnconditionalArchTest": that test exists at `src/test/java/net/aim_ai/wms/unit/repo/ReplenishLaneExclusionUnconditionalArchTest.java`.
- "dev carries a pre-V2.2.04 wording": confirmed. dev_wh01_om1's description starts `SBDEV-1666: exclude staging/transfer lanes as replenish sour…`, while PRD starts `SBDEV-1666: when true, staging lanes and transfer lanes are …`. Matching on syskey is the right choice.
- "Idempotent" is pinned by `secondApply_shouldBeANoOp`.
- Blast radius, from read-only SELECTs on 2026-10-16:

| DB | rows for the key | workstation | client_id | sysvalue | Flyway |
|---|---|---|---|---|---|
| wh01_om1_v2 (WineCo PRD) | 1 | DEFAULT | 0 | true | 2.2.38 |
| wh01_hydra_v2 (Hydra PRD) | 1 | DEFAULT | 0 | true | |
| wh02_shipitez_v2 (ShipItEZ NY PRD) | 1 | DEFAULT | 0 | true | |
| wh01_shipitez_v2 (ShipItEZ LA PRD) | 1 | DEFAULT | 0 | true | |
| dev_wh01_om1 (wineco dev) | 1 | DEFAULT | 0 | true | |

  Each tenant loses exactly one row, and nothing reads it.

### 4. ITs that relied on the V2.2.04 row: none break or go vacuous
- `AbstractReplenishRedirectPgFixture.withLaneSysprop` (lines 247-262) reads `saved` as nullable. It deletes and then inserts the DEFAULT/client-0 row itself, asserts `fixtureSyspropService.getSysvalue(LANE_SYSPROP)` equals the seeded value, and in `finally` restores either the value or the absence. Before this commit `saved` was `"false"` (the seeded row). Now it is `null`, so the row is removed afterwards, which matches the post-V2.2.39 state. The premise assertion still makes both the `true` and `false` rows non-vacuous.
- `ReplenishLaneExclusionUnconditionalIT` and `ReplenishorderRedirectSourceIT` read the key only through `withLaneSysprop`.
- `SyspropService.getSysvalue` (line 334) is a plain `findSysvalueBySyskey` with `unless = "#result == null"`. It does not auto-create rows, so a test cannot silently recreate the row.
- No other test reads the key: the grep in check 2 found nothing.
- The `los_sysprop` seed and width scanners (`SyspropMigrationDescriptionWidthTest` and the `*SeedConsistencyTest` classes) inspect `INSERT` statements only. A DELETE-only file gives them nothing to flag.

### 5. Stale "kept" wording
- In the repo: `git grep` for "constant and the V2.2.04-seeded row are kept", "row is kept" and "row stays" finds no remaining claim about this key. The only one was the deleted WmsConstants comment.
- Outside the repo (sbdocs and oms-laravel-api): see M1, LM1 and L1.

## Findings

### [MEDIUM] M1. Post-migration sysprop runbook re-creates the row V2.2.39 deletes
- File: `sbdocs/2-Areas/runbooks/wms2-post-v1-migration-sysprop-activation.md` lines 151, 169, 200 and 435. sbdocs is not in git and not in this commit.
- Confidence: HIGH.
- Evidence: the runbook's "forced" list INSERTs the key and then UPDATEs it:
  > `('REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED', 'true', 'Operation Options', 'SBDEV-1666: staging and transfer lanes are never selected as a replenishment source.'),` … `INSERT INTO public.los_sysprop … ON CONFLICT (client_id, syskey, workstation) DO NOTHING;`
  
  The note at line 151 says:
  > "Setting it below is harmless and keeps the script unchanged; it no longer switches anything."
- Issue: on the next v1→v2 onboarding, after V2.2.39 has run, this step puts the dead row back. Its description promises an effect, which is the exact state SBDEV-3659 removes. The note at line 151 is now false. The verify query at line 435 JOINs on the expected list, so it would report the resurrected row as `OK`.
- Fix:
  1. Remove the key from all three VALUES lists (1A/1B insert, the (b) UPDATE, and the verify JOIN).
  2. Fix the "Same 10 keys" count.
  3. Rewrite the line-151 note: "Deleted by V2.2.39 (SBDEV-3659); do not seed."
  4. Mark the change ⏳ pending-merge(SBDEV-3659), the same way the sysprop catalog is marked.

### [LOW-MEDIUM] L-M1. The baseline-path watermark probe for V2.2.04 reads `false` once V2.2.39 has run
- File: `sbdocs/2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md` lines 476-479 (§6.1).
- Confidence: MEDIUM. It only matters for a psql-provisioned DB that ran all files including V2.2.39 and has no history table.
- Evidence:
  > `SELECT 'V2.2.04', (count(*)=2)::text FROM los_sysprop WHERE syskey IN ('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED', 'REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED')`
- Issue: after V2.2.39 the count is 1, so V2.2.04 reads `false` while V2.2.05 and later read `true`. The rule at line 513 is "a gap … is not a clean watermark — stop and escalate". The runbook therefore fails safe (escalate) rather than stamping too low, but it raises a false alarm on every such DB.
- Related script: `sbdocs/9-System/scripts/rebaseline-stale-flyway-history.sh:111` uses `count != 0` as an ABSENT guard. That still trips on the surviving sibling, so the script is **unaffected**.
- Fix: probe V2.2.04 on the sibling only, `(count(*)=1) … WHERE syskey='TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED'`, with a comment that V2.2.39 deletes the other row. Consider adding probe rows up to V2.2.39, per the runbook's own rule at line 517. Rows for V2.2.37 and V2.2.38 are already missing, which is a pre-existing gap.

### [LOW] L1. The OMS release notes for v2.0.150 say "(the row is kept)"
- Files: `v2/oms-laravel-api` `docs/releases/owl-v2.0.150/developer.md:71` and `manifest.json:343`, on origin/develop and origin/main.
- Confidence: HIGH.
- Evidence:
  > "the lane-exclusion sysprop REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED is no longer read (the row is kept)"
- Issue: this was true for that release. Do not edit it. The release that carries V2.2.39 needs its own line, though, or readers will take "kept" as current.
- Fix: in the next release manifest, say V2.2.39 deletes the row on every tenant (one DEFAULT row each; all 4 PRD tenants hold `true`). The row disappears from System Properties, and behaviour does not change.

### [LOW] L2. Migration header: "backfilled past V2.2.39" versus "at or above it"
- File: `src/main/resources/db/migration/V2.2.39__delete_retired_lane_exclusion_sysprop.sql:11-12`.
- Confidence: HIGH.
- Evidence:
  > `A DB whose history is backfilled past V2.2.39 (db/backfill-flyway-history.sh with no --up-to, or one at or above it)`
- Issue: "past" reads as strictly above, while the parenthesis (correctly) includes the case where the cap equals 2.2.39. V2.2.37 uses the same phrasing, so the inconsistency matches precedent.
- Fix (optional; the file is not yet applied anywhere, so it can still be edited before merge): "backfilled through V2.2.39 or beyond".

### [LOW] L3. V2.2.04's header claims `SyspropService.getSysvalue` auto-creates rows; it does not
- File: `src/main/resources/db/migration/V2.2.04__seed_lane_behavior_sysprop_toggles.sql:17-18` (pre-existing, not in this diff).
- Confidence: HIGH.
- Evidence:
  > "safe against a row auto-created by SyspropService.getSysvalue"
  
  versus `SyspropService.java:334-336`, which is a read-only `findSysvalueBySyskey`.
- Issue: the file is applied and cannot be edited. This matters here only because a reader of V2.2.39 might fear the row comes back by itself. It cannot: there is no `src/main` reader, and the getter does not insert.
- Fix: none in the file. Optionally add one clause to V2.2.39's header: "nothing re-creates it: getSysvalue is read-only and nothing reads the key".

### [LOW] L4. The IT builds SQL by string concatenation
- File: `RetiredLaneExclusionSyspropRemovalMigrationIT.java:131` (`rows`) and `:139-143` (`insertOverride`).
- Confidence: HIGH.
- Evidence:
  > `"SELECT count(*) FROM los_sysprop WHERE syskey = '" + syskey + "'"`
- Issue: every input is a compile-time constant in a throwaway Testcontainers DB, so there is no security impact. It copies the DeadCancel harness verbatim. It is noted for completeness.
- Fix (optional): use `PreparedStatement`, or leave it for parity with the precedent.

### [LOW] L5. Historical Javadoc reads "V2.2.04 seeds it OFF" without mentioning V2.2.39
- File: `src/test/java/net/aim_ai/wms/integration/service/ReplenishLaneExclusionUnconditionalIT.java:33-35`.
- Confidence: MEDIUM.
- Evidence:
  > "Before this ticket the order generator and the cron recalc skipped lane stock only when the setting was ON, and V2.2.04 seeds it OFF."
- Issue: the sentence is framed in the past ("Before this ticket") and stays correct, but "seeds" is present tense. This is a cosmetic nit.
- Fix (optional): "V2.2.04 seeded it OFF (V2.2.39 deletes it)".

### [LOW] L6. All four PRD tenants carry `true`, so the change is visible in the UI
- Evidence: the table in check 3.
- Confidence: HIGH.
- Issue: there is no behaviour change, but operators on WineCo, Hydra and both ShipItEZ warehouses will see the row disappear from System Properties. That belongs in the ticket or the release note (see L1), so that nobody "restores" it.
- Fix: one line on the ticket or in the release note.

## Open questions (low confidence, not blocking)
- None. The IT is mutation-checked as the brief describes (DEFAULT-only, LIKE '%LANE%' and extra-row mutants all go red). The IT's design confirms that a DEFAULT-only, client-0-only or over-broad delete is caught: a single override row on a non-DEFAULT workstation under client 3659, plus a whole-table count delta of exactly 2, plus the sibling survivor check.

## Positive observations
- The migration deletes by syskey alone and never by description. That was the right call, as the different dev wording shows.
- The IT asserts its controls before acting: the row is present (2 rows) at 2.2.38, the sibling is present, and V2.2.39 exists on the classpath before Flyway targets it. Its absence assertions therefore cannot be vacuous.
- One override row covers both dimensions (workstation and client), and the whole-table count delta bounds over-deletion.
- The fixture handles the row's absence correctly and still proves the services read the value they seed, so `ReplenishLaneExclusionUnconditionalIT` keeps its teeth.
- The commit follows the V2.2.37 precedent in shape, header style and the IT harness. Its diff is minimal: 4 files, and no unrelated changes.
- The sbdocs sysprop catalog (§6 row, §11.1, change log line 866) is already updated with ⏳ pending-merge(SBDEV-3659) markers.

## Recommendation
**APPROVE** c99cf1c0. No CRITICAL or HIGH findings. The in-repo findings are all LOW. Before the ticket moves past `pr submitted`, fix M1 (runbook resurrects the row) and L-M1 (§6.1 probe) in sbdocs. They are outside git and outside this commit, but they belong on this ticket by the findings-go-on-the-current-ticket rule.

---

# Round 2 — 2026-10-16

Scope:
- (a) Commit `f03a03e5` on top of `c99cf1c0`. Its parent is `c99cf1c0`, and `c99cf1c0`'s parent is `dd601fe9` = origin/develop.
- (b) The two sbdocs runbooks edited for M1 and L-M1.
- (c) The SBDEV-3659 rows in the sysprop catalog.

No mvn run, and nothing in the worktree was modified.

## (a) f03a03e5

### L3 correction: the coordinator is right, and my round-1 L3 was partly wrong
- What round 1 got right: `getSysvalue(String)` (`SyspropService.java:333-336`) is a read-only `findSysvalueBySyskey`.
- What round 1 got wrong: it implied that no `SyspropService` read inserts. `getStringDefault(Client, String, String, String)` does insert. When all four lookups miss, it falls through to:
  > `createSystemProperty(clientService.getSystemClient(), WmsConstants.SystemProperty.WORKSTATION_DEFAULT, key, defaultValue, null, null, false, false);` (line 263)
  
  The SBDEV-3135 comment block at lines 245-262 documents this.
- Retraction: the round-1 suggestion to write "getSysvalue is read-only" in V2.2.39 is withdrawn. On its own it would mislead.
- The V2.2.04 header's phrase "a row auto-created by SyspropService.getSysvalue" names the wrong method but describes real behaviour. No action: the file is applied.

### New header wording: verified, one precision nit
- "No code path recreates it": **true.**
  - `git grep REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES HEAD -- src/main/java` finds only 2 comment lines (`ReplenishmentOrderSourceSyncService:122`, `MobileReplenishService:1104`).
  - The two generic creators take their key from a caller. `UtilRestController.createSystemPropertyIfNotExists` (line 980) receives only literal keys from initDB, and none of them is this one. `setSysvalue` is called by name.
  - So nothing in `src/main` can ask for this key.
- "an operator could still add it by hand in System Properties": **true.** `SystemPropertyController.createSystemProperty` (`POST /systemProperty/create`, line 102) accepts any `key` that has no row.
- "backfilled through V2.2.39 or beyond (… no --up-to, or --up-to 2.2.39 or higher)": **correct** against `backfill-flyway-history.sh`, which skips only `ver_tuple(version) > cap`. L2 is closed.

**[LOW] R2-L1. "default-value lookup" names too narrow a set of methods.**
- Confidence: HIGH.
- File: `V2.2.39__delete_retired_lane_exclusion_sysprop.sql:12`.
- Evidence:
  > "SyspropService's default-value lookup does INSERT a missing row, but only for a key it is asked for"
- Issue: the inserting tail is reached by every method that delegates to the 4-argument `getStringDefault`. That includes `getString(String)` (line 145) and `getString(Client, String, String)` (line 152), which pass `defaultValue = null` and so insert a row with a NULL value. Read literally, "default-value lookup" points at `getStringDefault` only. The conclusion is unaffected, because no `src/main` code names the key.
- Fix (optional): "SyspropService's getString/getStringDefault family does INSERT a missing row (createSystemProperty, line 263), but only for a key it is asked for". This is cosmetic. The file is not applied anywhere yet, so it can still be edited before merge.

**[LOW] R2-L2. Two new lines are wider than the files around them.**
- Confidence: HIGH.
- Files and evidence:
  - V2.2.39 line 13 is 160 characters. Every other line in that header is ≤ 120.
  - In the `ReplenishLaneExclusionUnconditionalIT` Javadoc, the edited line 34 ("…seeded it OFF (SBDEV-3659's V2.2.39 has since deleted the row). On an OFF tenant the system could therefore create, or re-point, an order whose own source the picker") also runs past the class's wrap width.
- Fix: rewrap both. Cosmetic.

L5 is closed: "seeded it OFF (SBDEV-3659's V2.2.39 has since deleted the row)".

## (b) Runbooks

### `wms2-post-v1-migration-sysprop-activation.md` (M1): CLOSED
- The key is absent from all three SQL lists:
  - Step 1 `forced` VALUES: 9 entries counted, lines 158-178.
  - Step 2 UPDATE VALUES: 9 entries, comment "Same 9 keys".
  - §5 verify JOIN: 13 entries, comment "expect: 13 rows … Fewer than 13 rows".
  
  The line counts match the prose.
- The line-151 note now forbids putting the key back: "is not in this script, and must not be re-added", with a ⏳ pending-merge(SBDEV-3659) marker on the V2.2.39 claim.
- Line 129 keeps the history: "Corrected to 10 below. That is 9 since 2026-10-16". It is coherent.
- §3 "These 13 keys" (line 340) is a **different** list, the v1-only stamp. I counted 13 entries there, and it is unaffected. Counts that look alike are not evidence of a missed edit.
- A grep for `10 keys|14 rows|14 keys|ten keys|fourteen` finds no stale current count.

**[LOW] R2-L3. The frontmatter still records the old 14-row audit and has not been re-dated.**
- Confidence: HIGH.
- Evidence: line 11 `verified_by` reads "§5 passed 14/14 after activating the 4 keys still at seed value", while `updated: 2026-09-11`.
- Issue: as dated history, 14/14 was true on 2026-09-11. A reader who compares it with "expect: 13 rows" may think one row is missing, and `updated:` does not show the 2026-10-16 edit.
- Fix:
  1. Bump `updated: 2026-10-16`.
  2. Append to `verified_by`: "2026-10-16 SBDEV-3659: lane-exclusion key removed from §1/§5 — §5 now expects 13".

### `wms2-apply-pending-tenant-flyway.md` (L-M1): CLOSED
- The probe is now:
  > `-- V2.2.04 seeded two keys, but V2.2.39 (SBDEV-3659) deletes REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED, … SELECT 'V2.2.04', (count(*)=1)::text FROM los_sysprop WHERE syskey = 'TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED'`
- It is correct both before and after the merge, because the sibling is untouched either way, so it needs no pending-merge marker.
- `rebaseline-stale-flyway-history.sh:111` (`count != 0`) is still unaffected, as noted in round 1.
- Not this ticket: `updated: 2026-09-01` is not bumped (LOW, same as R2-L3). The §6.1 table also still has no rows for V2.2.37 to V2.2.39, which is a pre-existing gap against the runbook's own rule at line 517.

## (c) Sysprop catalog: correct, two small updates

The §6 row (line 282), the §11.1 row (line 612) and the 2026-10-16 changelog row (line 866) agree with the code:
- The delete matches by syskey alone.
- The constant is deleted.
- "Until V2.2.39 applies, the row stays and changing its value has no effect".
- A fresh DB gets the row from V2.2.04 and then loses it to V2.2.39.
- The ⏳ pending-merge(SBDEV-3659) markers are on both claims.

**[LOW] R2-L4. "ShipItEZ PRD and WineCo PRD unmeasured" is now stale.**
- Confidence: HIGH.
- File: catalog line 282.
- Evidence: the row says "Every v2 tenant measured 2026-10-05 already had it `true` (Hydra PRD + 4 UATs); ShipItEZ PRD and WineCo PRD unmeasured", and later "Live 2026-10-16: present, `true` … on dev, Hydra PRD and WineCo PRD".
- My read-only SELECTs on 2026-10-16 (round 1, check 3) found `true` on **both** ShipItEZ PRDs as well: `wh02_shipitez_v2` and `wh01_shipitez_v2`, each with 1 row, DEFAULT, client 0.
- Fix: drop "unmeasured" and say "all four PRD DBs (Hydra, WineCo, ShipItEZ NY + LA) `true`, 1 DEFAULT row each, 2026-10-16".

**[LOW] R2-L5. The frontmatter and the headline total do not reflect this change.**
- Confidence: MEDIUM.
- Evidence:
  - `updated: 2026-10-06` was not bumped for the 2026-10-16 edits.
  - Line 44 says "**133** constants — 132 `SYSTEM_PROPERTY_*_KEY`". A plain count of `SYSTEM_PROPERTY_*_KEY` declarations gives 140 on origin/develop and 139 at HEAD.
- Issue: the total was already out of date before this ticket, so this is not a regression. SBDEV-3659 removes one more constant without noting it.
- Fix:
  1. Bump `updated:`.
  2. Either recount the total against origin/develop after merge, or add "(−1 SBDEV-3659 ⏳)". A full recount belongs to the next 90-day re-verification (due 2026-12-09), not to this ticket.

## Round-1 items routed elsewhere (accepted)
- L1 and L6 go on the ticket and PR (release-note line, operator notice). I agree; there is no code change.
- L4 needs no change; it matches the DeadCancel precedent. I agree.

## Round 2 tally
- New: 5 LOW (R2-L1 to R2-L5). There is no CRITICAL, HIGH or MEDIUM.
- Closed: M1, L-M1, L2 and L5. L3 is corrected: the round-1 premise was partly wrong, and the new header is accurate.

## Round 2 verdict
**APPROVE** at `f03a03e5`. Every remaining item is LOW and cosmetic or doc-only:
- R2-L1 and R2-L2 are optional header and Javadoc polish, still editable before merge.
- R2-L3 to R2-L5 are sbdocs frontmatter and live-census refreshes.

Per the fix-every-Low rule, apply them in the same pass if convenient. None of them blocks the merge.
