# PR #301 — code-correctness review, ROUND 2 (fix-verification of `cad2267f`)

- **Repo / branch**: `SiteBossInc/wms2-api`, `bugfix/SBDEV-3198-order-release`
- **Fix commit reviewed**: `cad2267f` ("PR #301 round-1 review fixes: correct stale/vacuous claims, no behavior change")
- **Round-1 commit**: `29a64776`
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-PART3-REVIEW2-CODE` (detached at `cad2267f`)
- **Lane**: code-correctness, round 2
- **Date**: 2026-09-03

---

## 0. Verification performed

| Check | Instrument | Result |
|---|---|---|
| Targeted suite | `mvn -o test -Dtest='OrderReleaseJob*,SchedulingConfigurationUnitTest,SchedulingReconcileIdempotencyUnitTest,AdminTriggerTenantScopeUnitTest,AdminActionControllerUnitTest,WholeRunSuccessGaugeUnitTest,NeverMatcherNullBlindnessArchTest'` | **159 run, 0 failures, 0 errors, 2 skipped — BUILD SUCCESS** (identical to round 1) |
| Behaviour change in fix | `git diff 29a64776..cad2267f` — 5 files, +71/−22 | **comments + 2 `@DisplayName`s + 1 assertion TIGHTENING only.** Zero `src/main` executable-line changes; the one test-logic change strengthens an assertion. |
| M-1 new claim re-derived | read `OrderReleaseJob.deriveSpecForCurrentTenant()` (`:146-159`), `TriggerSpec.isZoneInvariant` (`:96-109`), `zoneForTrigger()` (`:112`), registry-key format (`:877`) | **claim is correct** — see §M-1 |
| M-3 new claim re-derived | read `configureAllTasks()` (`:629-651`), `ReleaseExpiredPickingOrdersFromUserJob.runFor()` (`:137`) | **five-converted/one-not is correct**; one sub-clause of the new paragraph is not — see §N-2 |
| L-2 new comment re-derived | traced `runFor`'s per-tenant loop (`:181-220`) with the test fixture's stubs | **comment is now accurate**, including the no-`setId()` explanation |
| L-3 assertion re-derived | `grep -n "Failed to configure" SchedulingConfiguration.java` → per-group at `:892`, catch-all at `:902` | **`" for tenant(s)"` pins the per-group message and excludes the catch-all** |
| Fresh sweep for the same defect class | `grep -n "five single-trigger\|five still\|the converted job\|six jobs"` over the two touched `src/main` files | **two more stale "five" claims found in the same file** — see §N-1 |

---

## 1. Fix-verification table (round-1 findings)

| # | Lane | Finding (round 1) | Status |
|---|---|---|---|
| **M-1** | code | `TriggerSpec` "NOT-YET-REACHABLE" label false; `SchedulingConfiguration:797` "every tenant gets its own group" overstated | **FIXED** — both edits made; the *new* claims re-derived from source and correct |
| **M-2** | code | `skippedLockBusy` drop undocumented; `doesNotTouchTheWholeRunGauges`'s `@DisplayName` claims what its assertion can't support | **FIXED** — javadoc note added, `@DisplayName` narrowed, **assertions untouched** (verified line-by-line in the diff) |
| **M-3** | code | `:290-303` "five NOT-YET-CONVERTED jobs" asserted the precise inverse of reality | **FIXED, but see N-1/N-2** — the named paragraph is corrected and its five/one split is true; two sibling "five" claims in the same file were left, and one new sub-clause is inaccurate |
| **L-1** | code | nested class `@DisplayName("doCalculation")` names a gone method | **FIXED** — now `"runFor / runForCurrentTenant"`; both enclosed tests do call exactly those two |
| **L-2** | code | `viaFindByActiveTrue`'s inline comment names a mechanism the test doesn't exercise | **FIXED** — replacement comment traced against source and is correct on every clause, including the `.setId()` explanation |
| **L-3** | code | `"Failed to configure orderRelease group"` satisfied by either of two ERROR lines | **FIXED** — `.contains(" for tenant(s)")` chained on the same `m`; excludes the `"…groups"` catch-all at `:902` |
| **L-4** | code | `"Adds six more triggers every cycle"` is a floor, not a count | **FIXED** — reworded to "AT LEAST six … ≥6 and grows with divergence" |
| **L-5** | code | `triggerOrderReplenish` can report `false` for a run where `replenish` succeeded | **NOT FIXED — correctly.** Round 1 explicitly dispositioned this as "right for part 4, no consumer impact, noting only". No diff to `AdminActionController.java`. |
| **L-6** | code | inherited `markLastSuccess()` on an all-unreadable run | **NOT FIXED — correctly.** Round 1 explicitly said "Do not fix it in this PR; if it changes it should change across all five jobs at once." No diff. |
| **FC-1** | fact-check | `differentZonesMeanTwoGroups` `@DisplayName` still said "nine in all" | **FIXED** — now "ten in all" at `SchedulingConfigurationUnitTest.java:982`; matches the `+ 4` = 10 assertion |

**No round-1 finding was made worse, and no fix weakened a test.** The only assertion touched (`L-3`) got strictly stronger.

### M-1 — the new claim, re-derived rather than taken on trust

`deriveSpecForCurrentTenant()` (`OrderReleaseJob.java:158`) builds `"0 " + minutes + " " + hours + " * * *"`. With both sysprops at `*` the cron is `"0 * * * * *"` — six fields, and `isZoneInvariant` (`TriggerSpec.java:96-109`) loops `i = 1..5` requiring every one to be `"*"`, which holds. So `TriggerSpec.of` stamps `ZONE_INVARIANT`, and the registry key at `SchedulingConfiguration.java:877` is `JOB_NAME + "@" + cronExpression + "@" + zoneId` = **`orderRelease@0 * * * * *@zone-invariant`**, byte-identical for every tenant. The new javadoc's group-key string is exactly right, and so is "every tenant lands in ONE shared group today".

Two supporting points the new text gets right: the collapse really is *newly* live (the other three `TriggerSpec.of` callers — `cleanUpOldMessages:146`, `stockSummaryExport:183`, `staleClubBatchCleanup:112` — all have non-`*` hour sysprops per this file's own measurements, so none of them collapse), and the old text's exclusivity claim ("the only job routed through `of()` today is `staleClubBatchCleanup`", which was *already* false at `29a64776` given those three callers) was dropped rather than re-asserted.

### M-2 — placement checked for contradiction

The note sits between the "`doCalculation` is gone" paragraph and the "`releaseOrders` unchanged" paragraph (`OrderReleaseJob.java:67-77`). The file's other metrics paragraph (`:90-96`) enumerates `markLastRun`/`recordDuration`/`markLastSuccess`/`tenantSuccess`/`tenantFailure`/`tenantSkippedNotActivated` and never mentions `skippedLockBusy`, so there is nothing for the new note to contradict. The test change is `@DisplayName` + a comment; `assertThat(registry.find("wms2.cron.order_release.skipped_lock_busy").counter()).isNull()` and the three gauge assertions are unchanged.

---

## 2. New findings from a fresh read of the fix

### High

*None.*

---

### Medium

#### N-1 — the M-3 fix corrected one "five" claim and left two more in the same file, so `SchedulingConfiguration.java` now contradicts itself

M-3's fix rewrote `:290-303` to "the **ONE** remaining unconverted job". Two other present-tense count claims in the same file still say **five**, and both are now wrong in the same direction:

- `SchedulingConfiguration.java:118`:
  > `// LIVE for grouped jobs and forward-looking for the five still on CRON_SCHEDULE_ZONE.`

  Only **two** jobs still register through the 3-arg `register(...)` (`:1319`, which hard-codes `new TriggerSpec(cronExpression, CRON_SCHEDULE_ZONE.getID())`): `configureReplenish` (`:918`) and `configureReleaseExpiredPickingOrdersFromUser` (`:1044`). Introduced by `7b7db3b6` (step 3), stale since step 4.

- `SchedulingConfiguration.java:122-123`:
  > `Keyed in {@link #registrations} by {@code jobName} for the five` / `single-trigger jobs and by {@code jobName + "@" + cronExpression + "@" + zoneId} for grouped ones`

  Two single-trigger jobs, four grouped. This one is directly about the keying scheme this PR extends, so it is the paragraph a reader hits *first* when trying to understand `registryKey`.

  (Note this line does not match a naive `grep "five single-trigger"` — the phrase is split across the javadoc's line wrap at `five` / `single-trigger`. Worth knowing before anyone claims a clean sweep.)

Both are strictly pre-existing, exactly as M-3 itself was. What makes this Medium rather than Low is that the fix **changed the failure mode**: before `cad2267f` the file was uniformly, consistently wrong ("five" three times); now it says ONE in one place and five in two others, five lines and 170 lines apart from the constant they describe. A reader who lands on `:118` or `:123` has no signal that `:290` disagrees, and the disagreement is the kind that reads as "one of these describes a different axis" rather than "one of these is stale".

**Recommendation:** `:118` → "forward-looking for the **two** still on `CRON_SCHEDULE_ZONE`"; `:122-123` → "for the **two** single-trigger jobs". One word each. (`SchedulingConfiguration.java:1326` — *"That per-spec zone is what closes §1.2 for the converted job"*, singular, now four — is the same class of drift and worth the same one-word fix while in there.)

---

### Low

#### N-2 — the corrected M-3 paragraph implies exactly one job is still on `CRON_SCHEDULE_ZONE`; two are, and its carve-out for the second covers only the cron

New text at `SchedulingConfiguration.java:296-301`:

> "For that one job [`replenish`], the winning tenant's `*_TIMER_*` sysprops still drive every tenant's schedule, **and its firing zone is still `CRON_SCHEDULE_ZONE`**. … each converted job now supplies **its own cron AND its own zone** (or, for `releaseExpiredPickingOrdersFromUser`, a hard-coded cron with no per-tenant schedule sysprop at all), and the winning-tenant sysprops no longer reach any of them."

`releaseExpiredPickingOrdersFromUser` is counted among the five converted, and the parenthetical correctly excuses it from "its own cron" — but not from "its own zone", which it also does not have: `configureReleaseExpiredPickingOrdersFromUser` (`:1044`) calls the 3-arg `register(...)`, so it fires in `CRON_SCHEDULE_ZONE` like `replenish`. The first sentence's "**that one** job … firing zone is still `CRON_SCHEDULE_ZONE`" therefore reads as an exclusivity claim that is false.

Materially harmless — `"40 * * * * *"` is zone-invariant (every non-second field `*`), so the registered zone cannot change its firing instants, which is presumably why nobody has noticed. But this is a documentation-accuracy fix pass, and this is the paragraph it rewrote.

**Recommendation:** widen the carve-out to "a hard-coded, zone-invariant cron registered in `CRON_SCHEDULE_ZONE` — harmless, since the cron fires at identical instants in every zone", and drop "that one job" from the `CRON_SCHEDULE_ZONE` sentence.

#### N-3 — the fix commit message asserts "8 Low … All addressed"; there were 7, and 2 were deliberately not addressed

`cad2267f`'s body: *"found 0 High, 3 Medium …, **8 Low**. **All addressed:**"*. The two round-1 reports carry **seven** Lows — L-1…L-6 in the code lane, one in the fact-check lane — and its own bullet list names only five of them. The two it omits (L-5, L-6) were **correctly** left alone: round 1 explicitly dispositioned both as "note only / do not fix in this PR". So the code is right and only the message is wrong — but "All addressed" over a count that is both off by one and includes two intentional non-fixes is precisely the completeness-word defect M-3 was raised about, in the commit that fixes M-3.

**Recommendation:** amend to "7 Low: 5 addressed, 2 (L-5 `triggerOrderReplenish` return value, L-6 inherited `markLastSuccess`) deliberately deferred per the reviewer's own disposition."

#### N-4 — two garbled clauses in the new prose (nit)

Both introduced by `cad2267f`, both cosmetic:

- `OrderReleaseJob.java:69` — *"neither `runFor`'s two-key busy skip **nor `runForCurrentTenant()`'s logs anything** above DEBUG"* — the possessive has lost its noun; presumably "nor `runForCurrentTenant()`'s **records/logs**".
- `SchedulingConfigurationUnitTest.java:829-830` — *"`" for tenant(s)"` pins the PER-GROUP message this test actually exercises …, **not either**."* — trailing fragment; presumably "rather than matching either".

#### N-5 — "stale since step 5 part 3" understates by three steps (nit)

`SchedulingConfiguration.java:292` says the old paragraph was *"stale since step 5 part 3"*; the very next clause admits *"it was already wrong after steps 4, 5.1 and 5.2"*. The parenthetical rescues it, but the lead clause dates the staleness to this PR when the PR is what *revealed* it. One word: "stale **well before** step 5 part 3".

---

## 3. Things I specifically checked for and did NOT find

- **A fix that weakened a test.** The only assertion edit (L-3) adds a conjunct. No `@Disabled` added, no mock loosened, no `lenient()` introduced, no assertion deleted. `git diff --stat` shows +71/−22 across 5 files with zero executable-statement changes in `src/main`.
- **A copy-paste error between the two M-1 edits.** The `TriggerSpec` note and the `configureOrderReleaseGroups` note state the same fact from opposite ends and cross-reference each other; both name `"0 * * * * *"`, both name the `*`/`*` prd+UAT config, and neither claims the other's scope.
- **The M-2 javadoc contradicting the metrics paragraph below it.** It does not; `skippedLockBusy` appears in neither the `runForCurrentTenant`-skips list nor the per-order-metrics list.
- **A test whose behaviour changed when only its display name should have.** `doesNotTouchTheWholeRunGauges` and `differentZonesMeanTwoGroups` both kept every assertion byte-identical; the `DoCalculation` nested class kept its `@Disabled`.
- **Regression in the targeted suite.** 159/0/0/2 — the same numbers round 1 recorded at `29a64776`.

---

## Verdict

**APPROVE WITH NITS.** All 11 round-1 findings are correctly dispositioned: 9 fixed, 2 (L-5, L-6) deliberately deferred exactly as round 1 instructed, none touched-but-not-fixed and none made worse. Every new claim written by the fix pass was re-derived from source rather than taken on trust, and M-1's and M-3's central factual assertions hold. The fix is comment-and-display-name only; the single assertion change strengthens rather than weakens. The one Medium (N-1) is that the M-3 fix corrected one stale "five" and left two identical ones in the same file, converting a uniformly-wrong file into a self-contradictory one — three one-word edits close it, plus the two Low prose corrections (N-2, N-3). None of it blocks merge.
