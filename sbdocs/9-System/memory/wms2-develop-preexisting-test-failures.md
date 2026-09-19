---
name: wms2-develop-preexisting-test-failures
description: "wms2-api develop baseline history; CURRENT (2026-09-01, 3b0d0ca6): 5937 tests / 0 failures, GREEN — a red is a signal. Was briefly red acb0639e..4670ecea. Never hardcode the count; mvn/java need SDKMAN PATH"
metadata:
  node_type: memory
  type: project
  originSessionId: dc852100-20de-46b4-bf13-e91702404d06
  modified: 2026-07-28T20:47:24.860Z
---

**Current baseline — 2026-07-28.** Clean `origin/develop` (4d81ed6b): `mvn test` → **4442 tests, 2 failures,
0 errors, 67 skipped**. Verified in an isolated `git worktree` off `origin/develop`.

1. `unit.config.OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` — ArchUnit `FreezingArchRule`
   reporting 4 violations drifted past the frozen baseline: `PickLineRealignmentService:80,81`,
   `ReplenishGeneratorService:210`, `MobileReplenishService.fulfillMultipleUnitLoadsTx:807`.
2. `unit.service.mobile.MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate` — expects
   "Pallet already assigned to gate", gets "The parcel has been cancelled and cannot be palletized!".

**Still red on 2026-08-25** (`origin/develop` @ `0d1e3e51`) — same two, four weeks on. Re-confirmed
incidentally: PIT's coverage phase names them and **aborts**, because mutation testing requires a
green suite (`2 tests did not pass without mutation when calculating line coverage`). So these two
reds block **every PIT run wider than a single explicitly-named class** — the scoped
`-DtargetClasses=X -DtargetTests=Y` form still works because neither red is in scope. Same reason they
make floor item 5 ("full suite vs the known baseline") a manual diff on every ticket. See
[[sbdev-3007-pit-scoped-only-verdict]].

**Supersedes the 2026-06-11 list** (BillofladingUnitTest shipped-date, RestExceptionHandler 404, UtilRest ×2 —
4 of 4194). Those are fixed; today's two are different drift. **Re-verify rather than trusting this list** — the
honest method is a throwaway worktree at `origin/develop`, which avoids stashing over the user's working tree.

**⚠️ LANDMINE — running the suite MUTATES a tracked file.** `FreezingArchRule` rewrites
`src/test/resources/archunit_store/5fb3fee0-6caf-4f48-a5cd-5271da610572` whenever `OptionalSafetyArchTest` runs
(it prunes entries whose methods were renamed/removed). After any `mvn test`, check `git status` and
`git checkout -- src/test/resources/archunit_store/` unless you intend to re-baseline. Letting it ride along in
a feature branch silently freezes real violations.

**⚠️ Nested-class test selection silently no-ops.** `-Dtest='Outer#method'` matches nothing for a JUnit 5
`@Nested` test and reports `Tests run: 0` with **BUILD SUCCESS** — a false pass that looks like a green TDD gate.
Run the whole outer class instead.

**PATH:** `mvn`/`java` are not on the default PATH — `export SDKMAN_DIR="$HOME/.sdkman"; source
"$SDKMAN_DIR/bin/sdkman-init.sh"` (java current = 21.x, right for wms2-api).
Related: [[run-v1-wms-api-testcontainers-its-locally]].

**RESOLVED 2026-08-26 — this memory is now HISTORY, do not act on it.** Both reds were fixed by SBDEV-3089 (PRs #200/#201/#202). `origin/develop` is **5620 tests / 0 failures / 67 skipped**, verified on the merged branch. A red `mvn test` is now a SIGNAL, not the baseline — do not excuse "the usual two".
Still true and still worth knowing: **`mvn test` mutates the tracked `archunit_store` file** — except that after the re-baseline the store is now STABLE across runs (md5 unchanged), so a dirty store now means something changed, not just that you ran the suite. See [[sbdev-3089-two-red-tests-on-develop]].

**Baseline re-measured 2026-08-27 on `origin/develop` @ `03da8115`: 5680 tests / 0 failures / 67 skipped,
BUILD SUCCESS.** (Was 5620, then 5673 earlier the same day — the count moves with every merge, so treat the
NUMBER as perishable and the INVARIANT as durable: **develop is green, so any red is a signal, never the
baseline.** Re-measure with `mvn -o clean test` against a fresh `origin/develop` before comparing.)

**⚠️ NO LONGER GREEN — re-measured 2026-09-01 on `origin/develop` @ `a44a2fb8`: 5846 tests / 1 failure /
67 skipped, BUILD FAILURE.** The one red is
`unit.config.TestIdentifierCountArchTest.noTestIdentifierEncodesASetSize`, added by **SBDEV-3169** in
`acb0639e` (2026-08-29) — a rule that fails the build when a set's size is written into a test identifier.
It shipped without sweeping its own siblings and immediately flagged two pre-existing names on develop:
`WmsConstantsPriorityUnitTest.fromOmsLevel_mapsAllFiveLevels` and `.toOmsLevel_mapsAllFiveCodes`
(`src/test/java/net/aim_ai/wms/unit/service/WmsConstantsPriorityUnitTest.java`). Note it matches spelled-out
number **words** ("Five"), not digits — sweeping for `[0-9]` misses it.

Consequences while this stands: (a) **1 failure is the baseline again**, so compare failure IDENTITY, not
count — confirm with a throwaway detached worktree at `origin/develop`, which is how this was separated from
an unrelated one-file change on SBDEV-3153; (b) PIT wider than a single named class aborts again on the
non-green suite, so the scoped `-DtargetClasses/-DtargetTests` form remains the only usable one
([[sbdev-3007-pit-scoped-only-verdict]]). Reported on SBDEV-3169 (`in development`, so the finding belongs
on it); fix is a rename plus `assertThat(...).hasSize(5)`, or `REVIEWED_PRE_EXISTING`.

The durable lesson is not the count: **an anti-drift rule must be run against the existing tree before it is
merged**, or it lands red — see [[a-guard-fences-the-mechanism-you-aimed-at]] and the sibling-sweep rule.

**GREEN AGAIN — 2026-09-01, later the same day.** `4670ecea` (SBDEV-2573, "name the priority tests for
the property, not the count") renamed `fromOmsLevel_mapsAllFiveLevels` / `toOmsLevel_mapsAllFiveCodes`, so
`TestIdentifierCountArchTest` passes. Measured on a branch merged with `origin/develop` @ `3b0d0ca6`:
**5937 tests / 0 failures / 67 skipped, BUILD SUCCESS.** So the red window was `acb0639e`..`4670ecea`, about
three days. Back to: **develop is green, so any red is a signal, never the baseline** — and the count moved
5846 -> 5937 in one day, which is the standing reason never to hardcode it.
