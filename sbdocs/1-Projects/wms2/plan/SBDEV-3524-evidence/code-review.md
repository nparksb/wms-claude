---
ticket: SBDEV-3524
kind: independent-code-review
repo: v2/oms-laravel-api
commit: 4bce80ba (branch bug/SBDEV-3524, base origin/develop 14526ab9)
reviewer: code-reviewer lane (independent, not the author)
date: 2026-09-26
verdict: APPROVE (non-blocking fixes recommended; one operational follow-up)
---

# SBDEV-3524 code review: larger-boxes-first tie-break

## Code Review Summary

**Files reviewed:** 4 changed (`app/Services/Cubing/FitnessEvaluator.php`, `app/Services/Cubing/CubingCacheService.php`, `config/cubing.php`, `tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php`), plus context files (`EvolutionarySolver.php`, `GreedyPacker.php`, `Parcel.php`, `CubingService.php`, `ParcelCreationService.php`, `ProcessAutocubeJob.php`, DTOs, schema, seed data, `scripts/cubing-comparison/`, and the audit README).
**Total findings:** 13. There is also a list of open questions.

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 |
| LOW | 12 |

### Evidence I gathered myself

All commands ran against the worktree, which was mounted read-only in `oms-unit-php84`. Nothing in the worktree was modified.

- `LargerBoxesFirstCubingTest`: **7/7 pass, 49 assertions.**
- `FitnessEvaluatorTest`, `EvolutionarySolverTest`, `GreedyPackerTest`, `CubingServiceTest`: **23/23 pass.** `SkuGroupingCubingTest`: 15/15 pass.
- Whole `tests/Unit/Services/Cubing` directory: 200 tests, **0 failures**, and 71 errors. All 71 errors are `SQLSTATE[HY000] [2002] Connection refused`, because no MySQL was reachable from the container. They are DB-bound resolver suites, and none of them asserts a fitness value.
- **Pre- and post-fix simulation.** I ran `scratchpad/sim/sim.php` with the production weights and config, using the ticket's 6pk (min 4), 9pk (min 7) and 12pk (min 7) catalog:
  - 30 bottles, weight 0 (pre-fix): `{"12+12+6":245,"12+9+9":255}` over 500 runs.
  - 30 bottles, weight 0.5 (post-fix): `{"12+12+6":500}` over 500 runs.
  - The same fix also covers sibling quantities. At 39 bottles, pre-fix gave `12+9+9+9` in 20/100 runs; post-fix gave `12+12+9+6` in 100/100. At 42 bottles, pre-fix gave `12+12+9+9` in 57/100; post-fix gave `12+12+12+6` in 100/100.
  - 15, 21, 24, 27, 33, 45 and 48 bottles were unchanged: the same single shape before and after.
- **Proxy-soundness search.** I ran `scratchpad/lbf*.py` over the catalogs {1,3,6,9,12}, {3,6,9,12}, {1,2,3,6,12}, {1,2,3,4,6,12}, {1,2,3,5,6,7,9,12}, {1,3,6,9,12,24}, {2,4,6,8,12} and {3,4,6,8,12}, up to 8 parcels, at the **minimum parcel count** and with equal max box and equal total capacity. It found **0 disagreements** between sum-of-squares and lexicographic "larger first", and 0 ties. The positive control is the unconstrained search, which did find disagreements, so the search can detect them.
- `php -l` is clean on all 4 files. `pint --test`: the new test file fails 3 rules (see L7). The two app files also fail Pint, but they fail identically at base `14526ab9`, so that is pre-existing.

---

## Stage 1: Spec compliance

**PASS.** The requirement was: when box sets are otherwise equal, prefer larger boxes first, so 30 bottles cube as 12+12+6 rather than 12+9+9. The change also stops the solution cache from serving pre-fix tied answers.

- The fix does solve the reported symptom. The rate went from 51% `12+9+9` to 0% over 500 runs.
- It solves the right problem. The root cause was an exact fitness tie (-30088 for both sets: -30000 parcels, +12 largest, -100 for 2 SKU splits, 0 empty). Candidate order, GA randomness and the cache then picked between the tied sets.
- Nothing extra was added. There is one new weighted term, a config key, a cache version bump and one test class.
- Missing:
  - The already-persisted parcels of the reported order are not corrected (M1).
  - There is no CHANGELOG entry (L8).

---

## Answers to the seven review questions

### Q1: Is the "pure tie-break" claim true?

**Yes, for data sourced from the DB with the shipped weights.** The reason is not the one the docblock gives. The claim rests on integrality, which the code never states:

1. **Every other weight is a whole number:** `-1, -100000, -10000, 1, -100000, -100000, -50, -10` (`FitnessEvaluator.php:34-42`). The count terms (`empty_package_count`, `package_total_count`, `underfill`, `unpacked`, `sku_split`, `mixed_parcel`) return `int`.
2. **`largest_package` is `slotCntMax`, and that comes from `max_capacity int`** (`database/schema/tenant-baseline.sql:845`, `:2255`, `:2285`), cast with `(float)` in `PackagingTypeResolver.php:1059/1415`. So differences between candidates are whole slots.
3. **`empty_space` is `Σ max(0, slotEqMax·slotCntMax − filledVolume)`** (`Parcel.php` `getEmptyVolume`).
   - The clamp never fires. `canAcceptItem` requires `slotEq <= slotEqMax`, and `canFit` or `floor(emptySlots/slotCnt)` caps the slots, so `filledVolume <= capacity volume`.
   - For two candidates that pack the same units, `Σ filledVolume` is identical, including fractional `slotCnt` such as `decimal(5,2)` 0.33 (`tenant-baseline.sql:2743`).
   - So `Δempty_space = Δ Σ(slotEqMax·slotCntMax)`. `slotEqMax` is `slot_equiv_lut.volume`, and every seeded row is an integer: 0, 7, 50, … 187, 375, 500, 750, 1500, … (`tenant-seed-data.sql:4992-5037`).
   - Candidates with different unpacked units differ by at least 100000 anyway.
4. Therefore, the sum of all other terms is an integer for every complete candidate. Two candidates either tie exactly or differ by at least 1. The new term contributes `0.5·S` with `S ∈ (0,1]`, so the gap between two candidates is `< 0.5`. **It cannot flip a winner.**

**Where the claim can fail.** None of these has repo evidence of reaching production; they are Open Questions:

- **The `POST /cubing/calculate` API** accepts `package_types.*.slot_cnt_max` as `numeric|min:1` and `slot_eq_max` as `numeric|min:0` (`CubingController.php:151-153`), so fractional values such as 12.5 or 749.9995 are accepted.
  - Worked flip: A = {12pk, 12pk, 6pk} all at 750, B = {12pk@750, 9pk@749.9995, 9pk@749.9995}, 30 bottles, all full.
  - B has 0.009 mL less empty volume. A's tie-break advantage is 0.5·(0.36−0.34) = 0.01. **A wins against the other terms.**
  - This is contrived and API-only.
- **Tenant `slot_equiv_lut.volume` is `decimal(9,2)`** (`tenant-baseline.sql:3731`). A tenant row such as 187.50 makes empty-space differences fractional (multiples of 0.01·slots), and the tie-break could then override them. I could not query production OMS MySQL (no MCP for it). See OQ1.
- **Weights can be overridden from the environment:** `(float) env('CUBING_WEIGHT_*')` in `config/cubing.php`. For example, `CUBING_WEIGHT_EMPTY_SPACE=-0.25` means one 750-slot difference is worth 187.5 and still dominates, but a combined `-ΔE+ΔL` could reach 0.25. The config comment "Keep below 1.0 so it never outweighs any other term" states the wrong invariant. The real condition is `w_lbf · max ΔS < min non-zero |Σ w_i·Δterm_i|`. There are no `CUBING_WEIGHT_*` overrides in the repo. I cannot see deployed envs (OQ1).

**Imprecision in the docblock (L2).** The docblock says the term "only decides between box sets every other term scores identically". In fact it decides whenever the **weighted sum** of the other terms ties. Individual terms can differ and cancel, for example `ΔL = +1 slot` against `ΔE = +1 mL`. That is still acceptable tie-break behaviour, but the wording is wrong.

### Q2: Does it ever rank a non-"larger first" set above a larger-first one?

**Not at the parcel count the solver actually picks, on the catalogs I tested.**

- `package_total_count` (-10000 per parcel) forces the minimum feasible parcel count. `largest_package` already prefers the larger maximum box. So the new term only ever compares sets with **equal count, equal max box and equal total capacity volume**.
- In that region, the search above found no case where sum-of-squares disagrees with lexicographic larger-first, across 8 catalogs up to 8 parcels.
- Sum-of-squares is Schur-convex, so it respects majorization (the prefix-sum dominance order). It only disagrees with lexicographic order on non-majorization-comparable pairs. The minimum-count constraint leaves almost none of those.

Known limitations:

1. **Residual exact ties at one parcel above the minimum.** For example, 12+9+9+9+3 against 12+12+6+6+6 (40 to 42 bottles, {3,6,9,12} catalog): both give 396/42². This is only reachable when the 4-parcel solution is infeasible, for example through min-fill or `max_item_quantity` caps.
2. **Disagreement outside the minimum count.** Example: (12,9,9,9,1) against (12,12,6,6,4) at 40, with sum-of-squares 388 against 376. Sum-of-squares prefers the lexicographically smaller set. This is unreachable in practice, because four parcels hold 40.
3. **The docblock's own limitation example is wrong** (L1). 12+6+6+6 against 9+9+9+3 does **not** tie in fitness: `largest_package` separates them by +3.
4. **"Larger" means slot count, not size** (L4). A 6-slot 1500 mL magnum box (9000 mL) counts as half the size of a 12-slot 750 box (9000 mL). `GreedyPacker::packIntoParcels` orders "largest" by `slotEqMax·slotCntMax` (`GreedyPacker.php:146-149`), so the codebase has two definitions of "larger". I could not construct a realistic tie across different slot equivalents (empty-space differences separate them first), so this is Low with LOW confidence.
5. **It is a proxy for the PO rule, not for cost.** The commit message cites $183.72 against $192.06, but the term never consults rates. That is fine, because the PO chose the rule. Just don't describe it as a cost optimisation.

### Q3: Where is the fitness score compared, persisted or logged?

| Site | Effect of the new term |
|---|---|
| `CubingService.php:136-156`: `$existing->fitnessScore > $response->fitnessScore` (cached against fresh) | Safe. Both scores come from the same `SOLVER_VERSION` key space, because v4 entries are unreachable under v5 keys. The comparison is now decisive where it used to tie. Before the fix, a tie made `>` false, so the fresh coin-flip overwrote the cache; it is now deterministic. |
| `CubingCacheService.php:193/213`: stored `fitness_score` in Redis | Keys are versioned (`cubing:v5:{tenant}:{hash}`, `:166`). v4 entries simply age out (24h TTL). |
| `autocubequeue.fitness_score` column (`2025_12_10_120000_create_autocubequeue_table.php:35`) | **Nothing writes to it.** `git grep fitness` in `app/Models`, `ScheduledJobs` and `Resources` returns nothing for it, so it is a dead column. |
| `ProcessAutocubeJob.php:96`, `CubingService.php:162`, `SmokeTestOrderFlowCommand.php:600` | Logs only. |
| `Cubing3DComparison` `v1_fitness`/`v2_fitness`, `CompareCubing3DJob` | 3D only (`FitnessEvaluator3D`), so unaffected. |
| `scripts/cubing-comparison/rewrite_harness.php:73` | Its weight set lacks the key, so it gets 0.5 by default. `README.md:8` claims "fitness weights (identical between the two engines)", meaning v1 Python and PHP. That is now false (L9). |

One caveat: the cache key does not include the weights (pre-existing). If someone changes `CUBING_WEIGHT_*`, including the new knob, v5 entries survive and get fitness-compared across weight sets (L10).

### Q4: Is the SOLVER_VERSION bump sufficient?

**Yes, for the slot cache.**

- `CubingCacheService` is the only cache in the 2D path: `CubingService::calculate` checks `getCachedSolution`/`peekCachedSolution` at `:64-84` and `:137`.
- `Cubing3DCacheService` and the result store in `ProcessAutocube3DJob.php:119` serve 3D results only, and `CuberService` goes through the 3D pipeline. None of them serves a slot 12+9+9.
- During a rolling deploy, old pods read and write v4 keys and new pods use v5, so nothing is shared.
- **What the bump cannot fix is already-persisted parcels (M1).** `ParcelCreationService` writes parcels inside the order transaction. Order 9-25-26-1, and any order cubed as a tie in the affected window, keeps its 12+9+9 parcels until someone force-recubes it.

### Q5: Does the fix cover the production path?

**Yes, every slot entry point goes through `EvolutionarySolver` and `FitnessEvaluator`.**

- The normal order path is `ParcelCreationService::createParcelsForLockedOrder`:
  - It partitions lines by `cubing_method` (`:312`).
  - It calls `runCubing2D` (`:329`), which calls `$this->cubingService->cubeOrderModel($order, $cubeLines)` (`:385`).
  - `CubingService::cubeOrderModel` (`:255`) calls `calculate()` (`:370`), which checks the cache and then calls `$this->solver->solve($groupableItems, …)` (`:97`).
  - The solver scores every individual with `fitnessEvaluator->evaluate` (`EvolutionarySolver::evaluatePopulation`).
- `ProcessAutocubeJob.php:81` calls the same `cubeOrderModel`. Note, though, that its `applyCubingResults` is a TODO that only logs (`:128-150`), so it persists nothing (pre-existing).
- `AutocubeHandler.php:29` runs `processQueue()` on the same service. The controllers (`CubingController`, `OrderPackagingController`, `ParcelController`) go through `ParcelCreationService` or `CubingService`.
- **Forced package** (`CubingService.php:297-324`): `$packageTypes = [$forced]`. Every box is identical, so the new term is constant across candidates of equal count. No behaviour change, which is correct.
- **Ship-alone** (`CubingService.php:466`): `evaluate([$parcel], 1)`. With a single parcel S = 1, so the term is a constant +0.5 and ranking is unchanged. The test pins this.
- **Not covered:** products with `cubing_method = '3d'`, which use `Cubing3DService` and `FitnessEvaluator3D`, and the `CuberService` planning pipeline. The audit README says all 3,941 WineCo products are slot products. I did not verify the ShipItEZ/Kintera SKU's `cubing_method` (OQ3).
- `GreedyPacker::pack`/`packFirstFitDecreasing` are reached only as a "should not happen" fallback (`EvolutionarySolver.php:171`).

### Q6: Test quality

- **The solver test is effectively deterministic after the fix.**
  - Population size = clamp(30 units × 3 types) = 90.
  - The seeds are: the guess [12,12,12]; the optimistic individuals [6,6,6], [9,9,9] and [12,12,12]; and 86 uniform random length-3 genomes.
  - P(a random genome is the multiset {12,12,6}) = 3/27 = 1/9, so P(none in 86) = (8/9)^86 ≈ 4×10⁻⁵ per run. That is before 10 generations of crossover and mutation have any chance to produce it.
  - {12,12,6} is the unique fitness maximum:
    - {12,12,12} and {12,12,9} decode to a 6-bottle remainder, which underfills the 12pk (min 7) or the 9pk (min 7).
    - {12,9,6} leaves 3 units unpacked.
    - 4-box sets pay -10000.
  - Upper bound on a flake ≈ 20 × 4×10⁻⁵ ≈ 8×10⁻⁴ per execution. Empirically it was 500/500. Before the fix the test goes red with probability ≈ 1 − 0.5²⁰, and `fitness_prefers_…` goes red every time (equal scores fail `assertGreaterThan`), so both core tests guard the fix.
- **The boundary tests guard almost nothing (L5).**
  - `larger_boxes_first_never_buys_an_extra_parcel` only fails once the weight reaches about 10⁴/0.245 ≈ 4×10⁴.
  - `larger_boxes_first_never_outweighs_empty_space` only fails once the weight reaches about 2250 mL/0.0102 ≈ 2.2×10⁵.
  - `…_is_bounded_below_one_unit_of_any_other_term` asserts `weight < 1.0` on the **default**, because `PROD_WEIGHTS` omits the key. It never reads `config/cubing.php`, and `< 1` is not the real invariant (Q1).
  - None of the three sits at the actual margin, which is a pair whose other-term totals differ by exactly 1 while the tie-break favours the loser.
- **A fixture-shape assertion (L6).** `the_default_fills_in_for_weight_sets_that_predate_it` asserts `assertArrayNotHasKey('larger_boxes_first', self::PROD_WEIGHTS)`, which tests the fixture, not the code. The constant is named `PROD_WEIGHTS` but deliberately differs from production config, so anyone who syncs it with config breaks a test for no behavioural reason.
- The `(0,1]` range loop is mathematically trivial for positive capacities, but harmless.

### Q7: Style

- The production code matches the file. It uses `if (!$parcel->isEmpty())`, has the same docblock shape as its siblings, gets its breakdown key added, and merges its default through `array_merge`.
- The `CubingCacheService` v5 note is a `//` line outside the docblock. It follows the v4 precedent, but v2 and v3 sit inside the docblock (L11).
- The new test file fails Pint (L7).

---

## Findings

### MEDIUM

**[MEDIUM] M1. Already-cubed orders keep their tied 12+9+9 parcels. Deploying the fix does not correct the reported order.**
File: `app/Services/ParcelCreationService.php:329-340` (persists parcels) and `app/Services/Cubing/CubingCacheService.php:34`
Confidence: HIGH
Issue:
- The cache bump only affects future `calculate()` calls.
- Order 9-25-26-1, which quoted $192.06, and every other order cubed during the tie window still hold persisted parcels in the 12+9+9 or 12+12+9+9 shapes. The simulation shows 39 and 42 bottles were affected too, at 20% and 57%.
- Nothing in the change recubes them or sizes the population.

Fix:
- Before closing the ticket, force-recube 9-25-26-1 if it has not shipped.
- Run a read-only query for unshipped orders with more than one parcel of the same SKU where a smaller box precedes an unfilled larger alternative. Or simply list unshipped multi-parcel slot orders created since SBDEV-919 landed, and recube them.
- Put the count on the ticket.

### LOW

**[LOW] L1. The docblock's limitation example does not tie.**
File: `app/Services/Cubing/FitnessEvaluator.php` (new `calculateLargerBoxesFirstScore` docblock, "Limitation: … (12+6+6+6 vs 9+9+9+3) can still tie")
Confidence: HIGH
Issue: `largest_package` scores 12 against 9, so 12+6+6+6 wins by 3 before the tie-break is consulted.
Fix: Use a real residual tie, for example 12+9+9+9+3 against 12+12+6+6+6 (both 396/42²). Add that it is reachable only when the minimum parcel count is infeasible.

**[LOW] L2. "Only decides between box sets every other term scores identically" is imprecise.**
File: `app/Services/Cubing/FitnessEvaluator.php:28-32`
Confidence: HIGH
Issue: The term decides whenever the *weighted sum* of the other terms ties. Individual terms can differ and cancel, for example ΔL = +1 slot against ΔE = +1 mL.
Fix: Reword to "only decides between box sets whose other terms sum to the same fitness".

**[LOW] L3. The "pure tie-break" guarantee has unstated integrality preconditions, and the config comment states the wrong bound.**
File: `config/cubing.php` (the "Keep below 1.0 so it never outweighs any other term" comment), `app/Http/Controllers/Api/CubingController.php:151-153`, `database/schema/tenant-baseline.sql:3731`
Confidence: MEDIUM
Issue:
- The guarantee holds only while every other weight is an integer, `max_capacity` is an integer and `slot_equiv_lut.volume` is an integer.
- The calculate API accepts fractional capacities and volumes, and a worked flip exists (Q1).
- `volume` is `decimal(9,2)`.
- Weights can be overridden to fractions from the environment.

Fix:
- Document the precondition in the docblock and in the config comment.
- Preferably, make the tie-break structural rather than numeric. Either compare `(fitness, lbfScore)` lexicographically in the three `usort` comparators in `EvolutionarySolver`, or round the other-terms sum before adding the term.
- At minimum, log a warning when a configured weight is non-integer.

**[LOW] L4. "Larger" is measured in slots, while GreedyPacker measures it in nominal volume.**
File: `app/Services/Cubing/FitnessEvaluator.php` (`$capacity = $parcel->getMaxSlots()`) against `app/Services/Cubing/GreedyPacker.php:146-149`
Confidence: LOW
Issue:
- A 6-slot 1500 mL box and a 12-slot 750 mL box hold the same 9000 mL, but the tie-break weights them 36 against 144.
- In mixed slot-equivalent catalogs, this differs from the size order the decoder already uses.

Fix: Consider `slotEqMax * slotCntMax` as the capacity, which is consistent with `empty_space` and `GreedyPacker`. The 12+12+6 test is unaffected because all boxes are 750. Otherwise, document that the choice of slots is deliberate.

**[LOW] L5. The boundary tests are far from the real margin, and the bound test never reads config.**
File: `tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php`, the tests `larger_boxes_first_never_buys_an_extra_parcel`, `larger_boxes_first_never_outweighs_empty_space` and `larger_boxes_first_is_bounded_below_one_unit_of_any_other_term`
Confidence: HIGH
Issue: The first two only fail at weights of about 4×10⁴ and 2×10⁵ (see Q6), and the third checks the default rather than the configured weight.
Fix:
- Add a margin test: a pair whose non-tie-break totals differ by exactly 1 (for example, a `largest_package` difference of 1) while the tie-break favours the loser. Assert that the loser still loses.
- Assert the bound against `(new FitnessEvaluator())` built from `config('cubing.fitness_weights')` in a Laravel TestCase, or against the config array loaded directly.

**[LOW] L6. `PROD_WEIGHTS` is misnamed, and one test asserts the fixture's shape.**
File: `tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php` (`PROD_WEIGHTS` const and `the_default_fills_in_for_weight_sets_that_predate_it`)
Confidence: HIGH
Issue: The constant is named for production but deliberately omits the new key, and a test asserts that omission. Syncing the constant with config breaks the test without any change in behaviour.
Fix: Rename the constant to `PRE_SBDEV_3524_WEIGHTS`, or build the legacy weight set inline in that one test and drop the `assertArrayNotHasKey` on the fixture.

**[LOW] L7. The new test file fails Pint.**
File: `tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php`
Confidence: HIGH
Issue: `pint --test` reports `concat_space` (`' . json_encode` should be `'.json_encode`), `new_with_parentheses` (`new GreedyPacker()` should be `new GreedyPacker`) and phpdoc param spacing. It also flags the combined `/** @param … @return string */` one-liner on `shape()`.
Fix: Run `./vendor/bin/pint tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php`. The Pint failures in the app files pre-exist at base, so don't widen the diff.

**[LOW] L8. No CHANGELOG entry.**
File: `CHANGELOG.md` (`[Unreleased]` / `### Fixed`)
Confidence: MEDIUM
Issue: Recent develop fixes add entries, and SBDEV-919 documented its new weights and env keys there.
Fix: Add a "Fixed" entry naming `larger_boxes_first` / `CUBING_WEIGHT_LARGER_BOXES_FIRST`, the v5 cache bump, and the fact that this intentionally diverges from v1 on ties.

**[LOW] L9. The comparison-harness README now makes a false parity claim.**
File: `scripts/cubing-comparison/README.md:8`
Confidence: HIGH
Issue: The README says "fitness weights (identical between the two engines)". The PHP engine now adds a term that v1 Python lacks. It applies through the default even though `rewrite_harness.php` passes a legacy weight set.
Fix: Amend the line to say the PHP engine carries an extra tie-break term that does not exist in v1 (SBDEV-3524).

**[LOW] L10. The cache key does not include the weights, so the new env knob can mix weight sets (pre-existing pattern).**
File: `app/Services/Cubing/CubingCacheService.php:161-167`
Confidence: HIGH
Issue: Changing `CUBING_WEIGHT_LARGER_BOXES_FIRST`, or any other weight, leaves v5 entries live. They are then compared in `CubingService.php:143` against fresh scores computed under different weights. The class docblock itself says "scores computed under different weight sets are not comparable".
Fix: Fold a short hash of `config('cubing.fitness_weights')` into the key, next to `SOLVER_VERSION`. Alternatively, note that any weight change requires a version bump.

**[LOW] L11. The v5 note sits outside the version docblock.**
File: `app/Services/Cubing/CubingCacheService.php:32-34`
Confidence: HIGH
Issue: The v2 and v3 notes are inside the docblock. v4 and now v5 are `//` lines below it.
Fix: Move the v4 and v5 lines into the docblock list.

**[LOW] L12. The solver test is probabilistic, though the flake chance is negligible.**
File: `tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php` (`solver_cubes_thirty_bottles_as_twelve_twelve_six_on_every_run`)
Confidence: HIGH
Issue: The flake probability is at most about 8×10⁻⁴ per execution, before evolution can repair a bad seed (Q6). This is informational, not a defect.
Fix: Optional. Add a comment recording the seeding argument so a future maintainer does not "fix" a flake by dropping the loop.

---

## Open Questions (low-confidence or unverifiable; surfaced, not blocking)

- **OQ1 [would be HIGH if true]. Non-integer volumes or weights in deployed environments.**
  - Run `SELECT slot_equiv_lut_id, volume FROM slot_equiv_lut WHERE volume <> FLOOR(volume);` on each tenant DB (ShipItEZ, WineCo, Hydra, …).
  - Check the deployed env for any `CUBING_WEIGHT_*`.
  - A non-empty result from either makes L3 reachable in production. I had no OMS MySQL access in this lane.
- **OQ2. The DB-bound suites were not run here.** `V1PackagingParityTest` builds `new FitnessEvaluator` from config and asserts V1 box parity. If any parity fixture depended on a tie resolving the old way, it would now differ. Run the full `tests/Unit/Services/Cubing` suite against the `owltest` DB and compare with the baseline.
- **OQ3. The Kintera SKU's `cubing_method`.** If the affected SKU were `3d`, this fix would not touch it (Q5). The ticket's 12+9+9 slot shape strongly implies a slot product, but it is worth one query.

## Positive observations

- The root-cause analysis is exact. The -30088 tie reproduces by hand, and the fix targets the scorer instead of patching the GA or the cache.
- The single-parcel invariance (S = 1) is a clean property. It keeps ship-alone and forced-package choices provably unchanged, and a test pins it.
- The term goes through `array_merge` over `DEFAULT_WEIGHTS`, so env and config sets from before SBDEV-3524 keep working. A test covers that, along with the new `getDetailedBreakdown` key.
- The cache version bump includes a comment explaining why. The cached-against-fresh `>` comparison becomes deterministic as a side benefit.
- Both core tests go red before the fix: the evaluator test every time, and the solver test with probability ≈ 1 − 2⁻²⁰. The failure messages embed the breakdowns and the observed shape histogram, which is good diagnosability.
- The same fix also resolves the sibling quantities (39 and 42 bottles) without any special-casing.

## Recommendation

**APPROVE.** There are no CRITICAL or HIGH findings. Recommended before merge, each cheap: L1 (wrong docblock example), L5 (a margin test), L7 (Pint on the new file) and L8 (CHANGELOG). M1 is an operational follow-up for the ticket, not a code change: recube the reported order and size the affected population. Resolve OQ1 with one query per tenant DB, because a non-empty result there would make the "pure tie-break" claim false in production.
