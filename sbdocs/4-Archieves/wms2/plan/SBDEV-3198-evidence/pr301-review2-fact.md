# PR #301 round-2 fact-check — the fix commit's own new claims

- **PR**: https://github.com/SiteBossInc/wms2-api/pull/301, branch `bugfix/SBDEV-3198-order-release`
- **Commit under test**: `cad2267f` "PR #301 round-1 review fixes: correct stale/vacuous claims, no behavior change"
- **Previous commit (round-1 subject)**: `29a64776`. Base: `bb264b87`.
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-PART3-REVIEW2-FACT` (detached at `cad2267f`)
- **Date**: 2026-09-03
- **Lane**: independent fact-check, round 2 (a separate code lane ran in `SBDEV-3198-PART3-REVIEW2-CODE`)

**Overall verdict: 6 of 6 checked claims CONFIRMED — including a fresh independent DB re-measurement of the prd/UAT sysprop claim and a killed mutation proving the L-3 assertion tightening is load-bearing. Suite is 6291/0/0/67, byte-identical to the round-1 baseline. One NEW Low finding: the M-3 correction was applied in `SchedulingConfiguration.java` but the identically-stale sibling sentence in `TriggerSpec.java:20` — a file this same commit edited — was left saying "the five not-yet-converted jobs" when the true count is two.**

Diff shape of `cad2267f`: 5 files, +71/−22. Three `src/main` files (all javadoc-only) and two test files.

---

## Claim M-1(a) — "`orderRelease` routes through the zone-invariant collapse via `deriveSpecForCurrentTenant()`" — **CONFIRMED**

The chain, read end to end:

`OrderReleaseJob.java:152-158`
```java
String hours   = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_ORDER_TIMER_HOUR_KEY);
String minutes = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_ORDER_TIMER_MINUTE_KEY);
if (hours == null || hours.isBlank() || minutes == null || minutes.isBlank()) {
    return null;
}
ZoneId zone = timezoneService.getWarehouseZoneId(current.getFacilityCode());
return new TenantSchedule(TriggerSpec.of("0 " + minutes + " " + hours + " * * *", zone), zone);
```

`TriggerSpec.of(String, ZoneId)` is the collapsing factory (`TriggerSpec.java:43-51`), so `orderRelease` does route through it. Both consumers of the derivation use the same method — `SchedulingConfiguration.java:838` at registration and `OrderReleaseJob.java:198` at fire time — which is the property that makes the collapse safe. Sysprop key constants confirmed at `WmsConstants.java:1157` (`ORDER_TIMER_MINUTE`) and `:1159` (`ORDER_TIMER_HOUR`).

---

## Claim M-1(b) — "on prd hydra and all four UAT tenants, `ORDER_TIMER_HOUR`/`_MINUTE` both sit at `*`" — **CONFIRMED (independently re-measured today, not merely re-cited)**

The task flagged this as a possible copy-paste of an earlier measurement. Two separate checks:

**Citation accuracy.** The originating measurement lives at `TriggerSpec.java:66-72` ("true on prd hydra and all four UAT tenants, measured 2026-09-02"). The two new sentences cite it correctly and without embellishment — `TriggerSpec.java:74-77` says "(measured above)" and `SchedulingConfiguration.java:806-808` says "(measured 2026-09-02, see `TriggerSpec#of(String, ZoneId)`'s javadoc)". Neither widens the scope, changes the date, or drops the qualifier.

**Fresh measurement.** Rather than trust the citation, I queried all five DBs directly by psql (the MCP servers were all failing to connect this session; per the standing note, psql direct is the fallback). Read-only `SELECT`, one row per key per DB:

```sql
SELECT syskey, coalesce(sysvalue,'<NULL>'), coalesce(client_id::text,'-'), coalesce(workstation,'-')
FROM los_sysprop WHERE syskey IN ('ORDER_TIMER_HOUR','ORDER_TIMER_MINUTE') ORDER BY syskey, client_id;
```

| Environment | DB | `ORDER_TIMER_HOUR` | `ORDER_TIMER_MINUTE` |
|---|---|---|---|
| **prd** hydra nywh | `wh01_hydra_v2` @25061 | `*` | `*` |
| **uat** wsl-wineco | `wh01_om1_v2` @25062 | `*` | `*` |
| **uat** nywh-hydra | `wh01_hydra_v2` @25062 | `*` | `*` |
| **uat** nywh-shipitez | `wh02_shipitez_v2` @25062 | `*` | `*` |
| **uat** c1wh-shipitez | `wh01_shipitez_v2` @25062 | `*` | `*` |

Exactly one row each (`client_id=0`, `workstation=DEFAULT`) — no per-workstation override could shadow the value. Still `*`/`*` as of **2026-09-03**. The claim is current, not stale.

> Note on the query: `los_sysprop`'s columns are `syskey`/`sysvalue`, not `name`/`value`. A first attempt with `name` errored on all five identically — a reminder that a uniform error across every environment reads exactly like a uniform finding.

---

## Claim M-1(c) — "every tenant collapses into ONE shared group today" — **CONFIRMED (re-derived structurally AND confirmed empirically)**

This was the crux, and the sharpened question was: *if tenants are in DIFFERENT real timezones but their raw cron is zone-invariant, do they still merge into one group, or does something split them first?*

**Answer: they still merge. Nothing splits them.** Three independent facts:

**1. The collapse erases the zone before it can act as a key.** `TriggerSpec.java:93-104`:
```java
public static boolean isZoneInvariant(String cronExpression) {
    String[] f = cronExpression.trim().split("\\s+");
    if (f.length != 6) return false;
    for (int i = 1; i < 6; i++) { if (!"*".equals(f[i])) return false; }
    return true;
}
```
With `hours="*"`, `minutes="*"`, the cron is `"0 * * * * *"` → fields `["0","*","*","*","*","*"]` → indices 1..5 all `*` → `true`. `of(...)` (`:49-50`) then builds `new TriggerSpec(cronExpression, ZONE_INVARIANT)` — the tenant's real `ZoneId` argument is **discarded**, replaced by the `"zone-invariant"` sentinel (`:35`). Two tenants in New York and Los Angeles therefore produce byte-equal records.

**2. The grouping key is the spec alone — the resolved zone is never part of it.** `SchedulingConfiguration.java:843-847`:
```java
TriggerSpec spec = schedule.spec();
if ("UTC".equals(schedule.resolvedZone().getId())) { utcFallbacks.add(tenantKey); }
groups.computeIfAbsent(spec, k -> new ArrayList<>()).add(tenantKey);
```
`TenantSchedule` carries `resolvedZone()` alongside the spec, but it is consumed **only** for the UTC-fallback warning at `:844`. It never reaches `groups`. The registry key at `:877` is likewise `JOB_NAME + "@" + spec.cronExpression() + "@" + spec.zoneId()` — the sentinel, not the tenant zone. Fire-time membership at `OrderReleaseJob.java:205` is `own.spec().equals(spec)`, also spec-only.

So there is no second axis. Zone divergence is invisible to grouping once the collapse fires.

**3. Empirically, the deployed estate really does span two real zones and still collapses to one group.** Same psql sweep, `System Time Zone` (`WmsConstants.java:1002`):

| Environment | `System Time Zone` |
|---|---|
| prd hydra nywh | `America/New_York` |
| uat wsl-wineco | `America/Los_Angeles` |
| uat nywh-hydra | `America/New_York` |
| uat nywh-shipitez | `America/New_York` |
| uat c1wh-shipitez | `America/Los_Angeles` |

The four UAT tenants are split 2/2 across **two genuinely different zones**, yet all four derive the identical spec `TriggerSpec["0 * * * * *", "zone-invariant"]` and land in the single group `orderRelease@0 * * * * *@zone-invariant`. This is the strongest possible form of the claim — it is not "all tenants happen to be in one zone", it is "the collapse merges tenants that are demonstrably in different zones". The fix commit's wording ("landing every tenant in the single group … until an operator sets a tenant-specific hour/minute") is exactly right, and its "Mechanically safe (registration and fire-time membership both derive through the same method, so no tenant falls out of its group)" is the correct safety argument.

**One thing the claim does not say, and correctly does not need to:** a tenant *does* fall out if `getWarehouseZoneId` fails — `TriggerSpec.of` rejects a null zone at `:48` and `runFor`'s derivation catch (`OrderReleaseJob.java:199-204`) sets `anyReadFailure` and skips it. That is a failure path, not a grouping split, so it does not bear on the claim.

---

## Claim M-3 — "exactly ONE job (`replenish`) is unconverted" — **CONFIRMED**

Counted from `configureAllTasks()`'s actual call list (`SchedulingConfiguration.java:644-651`), not from the prose:

```java
configured += configureStaleClubBatchCleanupGroups(scheduler, scheduleSource, reconciling) ? 1 : 0;   // :644  grouped
configured += configureStockSummaryExportGroups(scheduler, scheduleSource, reconciling)     ? 1 : 0;   // :645  grouped
configured += configureCleanUpOldMessagesGroups(scheduler, scheduleSource, reconciling)     ? 1 : 0;   // :646  grouped
configured += configureOrderReleaseGroups(scheduler, scheduleSource, reconciling)           ? 1 : 0;   // :647  grouped
configured += onlyIfMissing(reconciling, "replenish", () -> configureReplenish(...))        ? 1 : 0;   // :648  single
configured += onlyIfMissing(reconciling, "releaseExpiredPickingOrdersFromUser", ...)        ? 1 : 0;   // :650  single
```

Six jobs: **4 grouped + 2 single-trigger**. The paragraph's load-bearing assertion is not "four are grouped" but *"For that one job, the winning tenant's `*_TIMER_*` sysprops still drive every tenant's schedule"* — and that is exactly right:

- `configureReplenish` (`:909-910`) reads `REPLENISHMENT_TIMER_HOUR`/`_MINUTE` in the **caller's** (winning-tenant) context. ✅ the one.
- `configureReleaseExpiredPickingOrdersFromUser` (`:1041-1042`) reads **no timer sysprop at all** — its cron is the hard-coded `"40 * * * * *"`. So no winning tenant drives it either, which is why the paragraph's parenthetical explicitly carves it out ("or, for `releaseExpiredPickingOrdersFromUser`, a hard-coded cron with no per-tenant schedule sysprop at all"). The carve-out is accurate and honest about the asymmetry.
- The four grouped jobs read their timer sysprops inside the per-tenant walk.

So on the axis the paragraph is actually about — *whose sysprops set the schedule* — exactly one job is unconverted. **CONFIRMED.**

### Low-1 (observation, not a contradiction) — the paragraph's closing clause drops a qualifier it needs

`SchedulingConfiguration.java:298-301` ends: *"…and the winning-tenant sysprops no longer reach any of them."* Read unqualified, that is false: `CRON_JOB_SHOW_LOG` is still read in the caller's (winning-tenant) context for **all six** jobs — `:768`, `:883`, `:915`, `:1007`, `:1041`, `:1184`. Read as scoped to the `*_TIMER_*` sysprops the paragraph's first sentence names, it is true. The ambiguity is inherited (the sentence it replaced said the same thing about `staleClubBatchCleanup` alone), but the M-3 fix widened its blast radius from one job to five. A three-word fix — "the winning-tenant **schedule** sysprops" — closes it. Not a blocker.

---

## Claim L-3 — `" for tenant(s)"` genuinely disambiguates the two error lines — **CONFIRMED (mutation-verified)**

The two ERROR lines inside `configureOrderReleaseGroups`:

| | Source | Rendered text | contains `"Failed to configure orderRelease group"`? | contains `" for tenant(s)"`? |
|---|---|---|---|---|
| per-group catch | `SchedulingConfiguration.java:892` | `Failed to configure orderRelease group TriggerSpec[…] for tenant(s) [upte-wh01]` | ✅ | ✅ |
| whole-method catch-all | `SchedulingConfiguration.java:902` | `Failed to configure orderRelease groups` | ✅ (as a prefix of "groups") | ❌ |

So the substring appears in **one but not the other**, exactly as the fix comment claims, and the round-1 L-3 diagnosis (the un-tightened assertion was satisfiable by either line) was correct. The test captures `ILoggingEvent::getFormattedMessage` (`SchedulingConfigurationUnitTest.java:344`), so `{}` placeholders are substituted before matching — the substring check operates on the rendered text above.

**Mutation check (the assertion is not vacuous).** I changed the per-group message at `:892` from `" for tenant(s) {}"` to `" covering {}"` and ran the class:

```
[ERROR] Tests run: 43, Failures: 1, Errors: 0, Skipped: 0
[ERROR] SchedulingConfigurationUnitTest$ProbeLoopAndRegistration.schedulerRejectingEveryTriggerReportsZero:830
```

The mutant was **KILLED**, and by exactly one test. The AssertJ failure output also settles a secondary question — it dumps every captured ERROR:

```
["Failed to configure staleClubBatchCleanup group TriggerSpec[…] for tenant(s) [upte-wh01]",
 "Failed to configure stockSummaryExport   group TriggerSpec[…] for tenant(s) [upte-wh01]",
 "Failed to configure cleanUpOldMessages   group TriggerSpec[…] for tenant(s) [upte-wh01]",
 "Failed to configure orderRelease         group TriggerSpec[…] covering       [upte-wh01]",   <- mutated
 "Failed to configure replenish task",
 "Failed to configure releaseExpiredPickingOrdersFromUser task"]
```

The whole-method catch-all **never fires** in this test (the per-group catch at `:891` swallows the `register()` throw before the outer catch sees it), so the tightened assertion pins precisely the one message that does fire. Note also that the three sibling grouped jobs' messages *do* contain `" for tenant(s)"` — which is why both `.contains(...)` clauses are needed together: the job name disambiguates the job, the tenant clause disambiguates the code path. Chaining is genuine conjunction in AssertJ (`contains` returns the same assertion object), so both are enforced.

Mutation reverted; `git status --porcelain` is empty and the tree is back at `cad2267f`.

---

## Full test suite — **6291 / 0 / 0 / 67, unchanged from the round-1 baseline**

```
$ export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
$ mvn -o test        # from SBDEV-3198-PART3-REVIEW2-FACT, detached at cad2267f
[WARNING] Tests run: 6291, Failures: 0, Errors: 0, Skipped: 0, Skipped: 67
[INFO] BUILD SUCCESS
[INFO] Total time:  02:37 min
```

**Tests run 6291, Failures 0, Errors 0, Skipped 67.** Byte-identical to round 1's measurement against `29a64776` — consistent with a commit that changed only javadoc, comments, `@DisplayName` strings, and one assertion tightening (which passes).

---

## No assertion was silently weakened — **CONFIRMED**

Mechanical check over the two touched test files, `29a64776..cad2267f`:

| File | assertion-bearing lines @29a64776 | @cad2267f |
|---|---|---|
| `SchedulingConfigurationUnitTest.java` | 129 | **129** |
| `OrderReleaseJobUnitTest.java` | 37 | **37** |

Filtering the diff to changed lines that are **not** comments and **not** `@DisplayName` leaves exactly one hunk across both files:

```diff
-                .anySatisfy(m -> assertThat(m).contains("Failed to configure orderRelease group"));
+                .anySatisfy(m -> assertThat(m).contains("Failed to configure orderRelease group")
+                        .contains(" for tenant(s)"));
```

That is a **tightening** (one predicate added, none removed), and it is mutation-verified above. Everything else in both files is a comment rewrite or a display string:

- `OrderReleaseJobUnitTest.java:96-103` — L-2 comment rewrite. The `when(...)` stub itself is unchanged.
- `:148` — `@DisplayName("doCalculation")` → `"runFor / runForCurrentTenant"` (L-1). Display string only.
- `:376` — dropped `skippedLockBusy` from a display name (M-2). **The assertion it referred to is untouched** — `assertThat(registry.find("wms2.cron.order_release.skipped_lock_busy").counter()).isNull()` still stands at `:397`, now with a comment stating plainly that it is a "still absent" sanity check rather than evidence of the manual-vs-scheduled split. This is the honest direction: the claim was weakened to match the assertion, the assertion was not weakened to match the claim.
- `SchedulingConfigurationUnitTest.java:982` — `"nine in all"` → `"ten in all"`, the round-1 fact-check lane's finding. Display string; the `hasSize(EXPECTED_TRIGGER_COUNT + 4)` = 10 it describes was already correct.

**Zero assertions removed, zero loosened, one tightened.**

---

## Supporting checks on the fix commit's other new claims

**M-2's factual content — CONFIRMED.** `grep -rn "skippedLockBusy" src/main/java/net/aim_ai/wms/` returns live call sites in `ReplenishOrderJob:120`, `StockSummaryExportJob:276`, `CleanUpOldMessagesJob:216` — and **none** in `OrderReleaseJob.java` (its only hit is the new M-2 javadoc at `:67`). Both of the job's busy skips log at DEBUG (`:222` in `runFor`, `:315` in `runForCurrentTenant`), so "nothing above DEBUG" holds for the lock-busy path specifically — the `LOG.info` at `:231` is the *activation* skip, a different branch, so the sentence's scoping is precise. The sibling comparison is also right: `StaleClubBatchCleanupJob:191` and `ReleaseExpiredPickingOrdersFromUserJob:190`/`:292` both log DEBUG and record no counter. And "nothing scrapes Prometheus in this estate yet" matches the standing estate note.

**L-4's new supporting citation — CONFIRMED.** The claim "this file's own `STOCK_SUMMARY_EXPORT_TIMER_HOUR` note elsewhere records three different values across environments" (`:1263-1264`) points at `:1284-1285`, which does exist and does record three distinct values: `3` on hydra prd, `18` on shipitez uat, `17` on wineco uat. The cross-reference resolves and the count is right.

---

## NEW finding (Low) — the M-3 correction missed its own sibling sentence, in a file this commit edited

`src/main/java/net/aim_ai/wms/schedulejob/TriggerSpec.java:19-21`:

> *"Outside `of()` itself, the canonical constructor has ONE call site in production: the one-arg `register` overload used by **the five not-yet-converted jobs**, which still register under the single process-wide `CRON_SCHEDULE_ZONE`."*

Two halves, measured separately:

- **"ONE call site" — TRUE.** `grep -rn "new TriggerSpec(" src/main/` returns exactly two hits: `TriggerSpec.java:49` (inside `of()` itself, explicitly excluded) and `SchedulingConfiguration.java:1318` (the one-arg `register` overload).
- **"the five not-yet-converted jobs" — FALSE.** That overload has exactly **two** production call sites: `SchedulingConfiguration.java:918` (`replenish`) and `:1044` (`releaseExpiredPickingOrdersFromUser`). The other four jobs go through the keyed overload at `:769`, `:884`, `:1008`, `:1185`. (The trailing "which still register under the single process-wide `CRON_SCHEDULE_ZONE`" is true of both of those two — `register` at `:1318` hard-codes `CRON_SCHEDULE_ZONE.getID()`.)

This is the *same* staleness class as M-3, in the *same* commit's *other* edited file, and it is arguably worse than the M-3 original: M-3's paragraph was at least internally consistent prose, whereas `TriggerSpec.java:20` now sits ~55 lines above the new M-1 note at `:74-83` that announces `orderRelease` **is** converted. A reader gets both claims from one screen of one file.

Severity **Low**, not Medium: it is a comment with no functional consequence, and the commit message for `cad2267f` does not assert a completeness word over this category (which is what elevated M-3). Fix is one phrase: *"used by the two remaining single-trigger jobs (`replenish`, `releaseExpiredPickingOrdersFromUser`)"*.

### Sibling sweep for the same staleness class

I swept `src/main` and `src/test` for every other "N not-yet-converted / N remaining" count. Four other sites, only one of which is wrong:

| Site | Text | Verdict |
|---|---|---|
| `TriggerSpec.java:20` | "the five not-yet-converted jobs" | **STALE — the finding above** |
| `SchedulingConfiguration.java:1467` | "restate this arithmetic again before step 5 groups the remaining five jobs" | Forward-looking instruction written at step 3, now *overdue* rather than false. Informational — the "restate before step 5" trigger has now fired and step 5 is complete. |
| `SchedulingConfigurationUnitTest.java:1292-1293` | "the two remaining single-trigger jobs (replenish, releaseExpiredPickingOrdersFromUser)" | **Correct** — already updated by `29a64776`. |
| `WholeRunSuccessGaugeUnitTest.java:277` | "the other four (not-yet-converted) job sections" | Scoped to that test file's own job sections, not to the codebase's conversion state. Loose wording, harmless. |
| `SchedulingConfiguration.java:291-296` | the M-3 correction itself | **Correct** as of this commit. |

So the correction landed in the one place round-1 named and missed exactly one sibling.

---

## Overall verdict

**All six checked claims CONFIRMED — M-1(a)/(b)/(c), M-3, L-3, and the no-weakened-assertions check — with M-1(b) independently re-measured against all five live DBs today rather than re-cited, M-1(c) confirmed empirically on a UAT estate that genuinely spans two timezones, and L-3 confirmed by a killed mutation; suite is 6291/0/0/67 unchanged; the single new finding is Low: `TriggerSpec.java:20` still says "the five not-yet-converted jobs" where the true count is two, the same staleness class the commit's own M-3 fix corrected one file over.**
