---
ticket: SBDEV-3524
kind: independent-re-review
repo: v2/oms-laravel-api
commit: f7adfde5 (parent 4bce80ba, reviewed in code-review.md)
reviewer: code-reviewer lane (independent, not the author)
date: 2026-09-26
verdict: APPROVE (0 Critical, 0 High, 0 Medium new; 11 Low)
---

# SBDEV-3524 re-review: f7adfde5 (response to L1-L12)

## Summary

| Severity | New in f7adfde5 |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 11 (N1-N11) |

The prior M1 is still open. It is operational: recube the already-cubed orders, tracked on the ticket. It is not re-counted here.

### Evidence I gathered myself

The worktree was mounted in `oms-unit-php84`. Mutants were bind-mounted over single files from the scratchpad, so no worktree file was modified.

- `LargerBoxesFirstCubingTest`: **10/10 pass, 57 assertions.**
- `pint --test`:
  - The test file and `config/cubing.php` are clean.
  - `CubingCacheService.php`, `FitnessEvaluator.php` and `Parcel.php` fail. `Parcel.php` also fails at base `14526ab9`, which I checked by running Pint on `git show 14526ab9:app/Services/Cubing/Parcel.php`. That is pre-existing, so it is not a finding.
- **Mutant: default weight back to 0.5.** The margin test, the 12+12+6 scorer test, the solver test and the never-outweighs-empty-space test **all still pass** (4 tests, 27 assertions). Only the `< 0.01` assertion in the bound test kills this mutant (N1).
- **Mutant: `$fitnessWeights ??= []`, so production ignores the config weights.** The whole `tests/Unit/Services/Cubing` directory ran 203 tests with 0 failures. The 71 errors are the known DB connection-refused errors. **The mutant survives** (N2).
- **Environment probe:** `-e CUBING_WEIGHT_LARGER_BOXES_FIRST=0.002` makes the bound test fail with "config/cubing.php and the evaluator default must agree" (N7).
- **Float-precision probe** (`scratchpad/prec.php`): a single (12,6)→(9,9) swap among N full 12-packs, adding the tie-break to a base fitness of about −10⁴·N:

  | N parcels | Tie-break contribution | ulp of the fitness | Tie-break survives? |
  |---|---|---|---|
  | 100 | 1.26e-8 | 2.2e-10 | yes |
  | 500 | 5.0e-10 | 1.1e-9 | yes |
  | 1000 | 1.25e-10 | 2.2e-9 | **no** |

- **Volume against slot sizing brute force** (`scratchpad/vol_vs_slot.py`): 4 catalogs, 2 to 60 bottles of 750 mL, up to 6 parcels. There were 63 tie cases and 14 sizing disagreements. All 14 are in the catalog that contains a synthetic `9@1000` box. There were none in the catalogs built from the seeded 750 and 1500 volumes.

---

## 1. L1-L12 status

| # | Status | Evidence |
|---|---|---|
| L1 | **RESOLVED** | The new example, 12+9+9+9+3 against 12+12+6+6+6, gives 144+243+9 = 396 and 288+108 = 396. Both have 42 full slots, max 12 and 4 SKU splits, so the other terms tie too. At 750 mL, volume sizing is proportional to slots, so the tie survives the L4 change. |
| L2 | **RESOLVED** | The docblock now says "box sets whose other terms sum to the same fitness". |
| L3 | **PARTIAL** (acceptable) | **Now done:** the preconditions are stated in the `FitnessEvaluator` docblock and in the `config/cubing.php` comment. The weight dropped from 0.5 to 0.001, below the 0.01 mL `decimal(9,2)` step. The prior worked API flip (749.9995, a 0.009 mL gap) no longer flips, since 0.001·0.02 = 2e-5 < 0.009. Env weights such as `EMPTY_SPACE=-0.25` (a 0.0025 gap) are also safe. **Still open:** it is still a numeric margin, not a structural (lexicographic) tie-break, and there is no warning for non-integer weights. A flip remains reachable only through `POST /cubing/calculate` with sub-0.001-scale capacities. The docblock admits this. |
| L4 | **RESOLVED** | `Parcel::getCapacityVolume()` is used. See the caveats in N8 and N9. |
| L5 | **PARTIAL** | **Now done:** the bound is asserted against `config/cubing.php` and against the evaluator default, with a real `< 0.01` bound, and a margin test was added. **Still open:** the margin test uses a 0.03 mL gap and does not kill the old 0.5 weight (N1). |
| L6 | **RESOLVED** | The constant is renamed to `PRE_SBDEV_3524_WEIGHTS`, and the fixture-shape `assertArrayNotHasKey` is gone. |
| L7 | **RESOLVED** | `pint --test` is clean on the test file. |
| L8 | **RESOLVED** | A CHANGELOG entry exists under `[Unreleased]` / `### Fixed`. Its accuracy points are in N11. |
| L9 | **RESOLVED** | `scripts/cubing-comparison/README.md:8-9` now names the extra term. |
| L10 | **RESOLVED in code** | The key is `cubing:v5-<fp12>:<tenant>:<hash>`, and the production path reads the config weights (see 2a). That path is untested (N2). |
| L11 | **RESOLVED** | The v4 and v5 notes moved into the docblock. |
| L12 | **RESOLVED** | A seeding comment was added, but it is inaccurate (N5). |

## 2. Questions on f7adfde5

### 2a. `CubingCacheService` construction and the fingerprint

- **Production gets the real weights.**
  - The only production consumer is `CubingService::__construct(... ?CubingCacheService $cacheService = null ...)` (`app/Services/Cubing/CubingService.php:31`). `CubingService` is resolved by container autowiring in `CubingController`, `ProcessAutocubeJob`, `AutocubeHandler`, `ParcelCreationService`, `OrderForcedPackageService`, `SmokeTestOrderFlowCommand` and `app(CubingService::class)` in `LegacyOrderCancelService:883`.
  - `app/Providers` has no binding for either class (`git grep Cubing app/Providers` shows only the 3D bindings).
  - So the container builds `CubingCacheService` with both parameters null, and `$config === null` selects `config('cubing.fitness_weights')`.
  - The evaluator is built the same way: `EvolutionarySolver` defaults to `new FitnessEvaluator()`, which reads config, and so does the ship-alone path at `CubingService:466`. The fingerprint and the evaluator therefore see the same config.
- **No app caller passes a `$config` array.** `git grep "new CubingCacheService"` finds only the new test, and that test passes the weights explicitly. The other three test classes mock the service.
- **The API is still a trap:** passing `$config` alone silently yields a constant hash of `[]` (N3).
- **Raw config against merged weights is adequate today.** `config/cubing.php:55-90` defines all 9 keys, so the raw config equals `array_merge(DEFAULT_WEIGHTS, config)`. They would diverge only if a future key were added to `DEFAULT_WEIGHTS` without a config line, and such a change should bump `SOLVER_VERSION` anyway (N4).
- **Key format is safe.**
  - `clearAll()` (`CubingCacheService.php:156-161`) is a log-only no-op, and no code parses keys.
  - `git grep 'cubing:v'` finds only the new test.
  - The runbook's `php artisan cache:forget cubing:*` (`docs/cubing-deployment.md:149`) still prefix-matches. It never globbed anyway, which is pre-existing.
  - An out-of-repo Redis pattern such as `cubing:v5:*` would miss the new keys. I found none in this repo.
  - Keys from the old weight set become unreachable and expire after the 24 h TTL.
- **JSON encoding is stable.** Weights are `(float)` casts. `json_encode` of floats is deterministic under `serialize_precision=-1`, and key order is the config file order, so reordering the file causes at most one cold cache.

### 2b. `getCapacityVolume()` / `getEmptyVolume()`

**Behaviour-identical.** The expression is the same, `slotEqMax * slotCntMax`, with the same operand order, so the IEEE result is identical. The `max(0, … - filledVolume)` is unchanged.

### 2c. Nominal-volume sizing

- **It is the internally consistent choice.** Among candidates the tie-break can decide (equal count, equal largest-slot bonus, equal empty space), Σ nominal volume is fixed, so sum-of-squares over volume is properly normalised. Under slots, Σ slots is not fixed, and unequal slot totals inflate S. That is why slot-S preferred {12@750, 9@1000} over {12@750, 12@750} in my brute force, which is the wrong direction.
- **A "12-slot box that accepts 1500 mL" filled with 750s** is rated at 18000 mL. It is already charged 9000 mL of empty space, so it only meets the tie-break against sets with the same empty space. In every such set I enumerated, volume and slots agreed.
- **The only disagreements were equal-volume, different-slot boxes** (`9@1000` against `12@750`). Volume leaves those as a residual exact tie, decided by candidate order. Slots picks the smaller-slot box. Neither choice is clearly worse (N8).
- **"Consistent with GreedyPacker" is half-true.**
  - `packIntoParcels`, the decoder, sorts by volume (`GreedyPacker.php:145-150`).
  - `pack()` (`:31`) and `packFirstFitDecreasing()` (`:349`) sort by `slotCntMax`, but they are fallback-only.
  - `largest_package` still measures slots (`FitnessEvaluator.php:146`) (N9).

### 2d. Float precision at weight 0.001

- **The case in your question is fine.** Fitness around −1e6 has an ulp of about 2.2e-10, and a contribution of about 1e-5 is roughly 5 orders of magnitude above it.
- **ΔS shrinks as 1/N².** At 100 parcels a single swap gives a ΔS of about 1.3e-5, not 0.01, so the contribution is about 1.3e-8. That is still about 57 times the ulp.
- **Absorption starts between 500 and 1000 parcels** (measured). At the old weight of 0.5 the threshold would be about 8 times higher.
- **Float noise in fractional-volume empty-space sums** is about 1e-12 per parcel, well below the signal.
- Orders of 6,000+ bottles are not a realistic slot-cubing shape, and absorption only restores the pre-fix coin flip, so this is Low (N10).

### 2e. New tests

| Test | Assessment |
|---|---|
| `larger_boxes_first_loses_to_a_hundredth_of_a_millilitre_scale_gap` | Not vacuous: the precondition assert is good. But the 0.03 mL gap against ΔS ≈ 0.02 flips only at a weight above about 1.5, so it **passes at 0.5** (N1). |
| `larger_boxes_first_weight_stays_below_the_empty_space_resolution` | Real guard; it is the one that kills the 0.5 mutant. `require config/cubing.php` inside a plain `PHPUnit\Framework\TestCase` works: `env()` is a composer-autoloaded helper and reads the process environment without a booted app. `.env*` files are not loaded unless an earlier Laravel-booted test loaded them, so the result depends on test order. None of `.env.testing` or `phpunit.xml` sets `CUBING_WEIGHT_*`. **A real env var does break it** (verified with 0.002) (N7). |
| `the_cache_key_changes_when_the_fitness_weights_change` | Not flaky. It tests only the explicit-weights path, never the production `config()` path (N2). `assertStringStartsWith('cubing:v5-')` is a shape assertion (N6). |
| `box_size_is_measured_in_nominal_volume_not_slots` | Good. It discriminates 0.5 (volume) from 0.556 (slots) and kills a revert to `getMaxSlots()`. |
| `the_default_fills_in_…` | Now asserts behaviour only. Good. |
| Solver loop comment | Wrong about seeding (N5). |

### 2f. CHANGELOG

- **Accurate:** the 30-bottle case, the −30088 tie, the v5 key plus fingerprint, the v1 divergence and the "keep their parcels until recubed" note.
- **Overstated** (N11):
  - "39 and 42 bottles were affected the same way" comes from the prior reviewer's simulation, not from observed orders. It is logically correct: 12+9+9+9 against 12+12+9+6 and 12+12+9+9 against 12+12+12+6 are exact ties by hand.
  - "never overrides parcel count, empty space, …" is unconditional. It drops the integer-weight and API-capacity preconditions that the docblock carries.
  - The Tests bullet says "down to 0.01 mL", but the test uses 0.03 mL (see N1).

## 3. Prior Open Questions

- **OQ1** (non-integer volumes or weights) is **improved**, not worsened. With a weight of 0.001, `decimal(9,2)` volumes and env weights with 0.01-step granularity no longer reach L3. Only the arbitrary-precision API path remains.
- **OQ2** (DB suites): the author reports a MySQL lane with 0 outcome changes in the cubing directory. I did not re-run it. Note that volume sizing is a behaviour change relative to 4bce80ba for catalogs that mix slot equivalents, so that lane is the right evidence.
- **OQ3** is unchanged.
- **The only regression-shaped change** is that the smaller weight lowers the float-absorption ceiling (N10), and that ceiling is not realistic.

---

## Findings

**[LOW] N1. The margin test does not guard the value it was written to reject.**
File: `tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php` (`larger_boxes_first_loses_to_a_hundredth_of_a_millilitre_scale_gap`)
Confidence: HIGH
Issue:
- The gap is 0.03 mL and ΔS is about 0.02, so the test flips only at a weight above about 1.5.
- The 0.5 mutant passes it (verified). The only guard against 0.5 is the `< 0.01` bound assertion.
Fix: Use a pair with a large ΔS (≥ 0.3) against a 0.01-0.03 mL gap, so that any weight ≥ about 0.05 goes red. Otherwise rename the test and drop "down to 0.01 mL" from the CHANGELOG.

**[LOW] N2. The production fingerprint path is untested.**
File: `app/Services/Cubing/CubingCacheService.php:47`
Confidence: HIGH
Issue: The mutant `$fitnessWeights ??= []` survives the whole Cubing directory (verified).
Fix: In a Laravel TestCase, change `config(['cubing.fitness_weights.larger_boxes_first' => …])` and assert that `app(CubingCacheService::class)->keyPrefix()` changes.

**[LOW] N3. Passing `$config` alone silently disables the fingerprint.**
File: `app/Services/Cubing/CubingCacheService.php:45-48`
Confidence: MEDIUM
Issue: No production caller does this today, but a future `new CubingCacheService($cfg)` gets a constant hash of `[]`.
Fix: Fall back to the config weights regardless of `$config`, or fingerprint `(new FitnessEvaluator)->getWeights()`.

**[LOW] N4. The fingerprint hashes raw config rather than the merged weights the evaluator uses.**
File: `app/Services/Cubing/CubingCacheService.php:47`
Confidence: MEDIUM
Issue: The two are equal today because the config lists all 9 keys. They drift only if a default is added without a config line.
Fix: Use the evaluator's merged weights. This is the same fix as N3.

**[LOW] N5. The solver-test comment claims "the GA seeds the 12+12+6 set directly".**
File: `LargerBoxesFirstCubingTest.php` (`solver_cubes_…` comment)
Confidence: HIGH
Issue: The seeds are the guess, one optimistic individual per type ([6,6,6], [9,9,9], [12,12,12]) and random genomes (`EvolutionarySolver.php:21-24, 319-328`). 12+12+6 arrives through random genomes with P(miss) ≈ 4e-5.
Fix: Reword the comment.

**[LOW] N6. A shape assertion on the version string.**
File: `LargerBoxesFirstCubingTest.php` (`assertStringStartsWith('cubing:v5-', …)`)
Confidence: HIGH
Issue: The next `SOLVER_VERSION` bump breaks this test with no behaviour change.
Fix: Drop the assertion, or assert that the prefix contains the fingerprint.

**[LOW] N7. The bound test depends on the process environment.**
File: `LargerBoxesFirstCubingTest.php` (`…_stays_below_the_empty_space_resolution`)
Confidence: MEDIUM
Issue:
- Setting `CUBING_WEIGHT_LARGER_BOXES_FIRST` in a CI or dev env fails the `assertSame($default, $configured)` check (verified).
- Whether `.env` has been loaded depends on whether a Laravel-booted test ran earlier.
Fix: Always keep the `0 < w < 0.01` assertion. Assert equality with the default only when `getenv('CUBING_WEIGHT_LARGER_BOXES_FIRST') === false`.

**[LOW] N8. Volume sizing leaves residual ties between equal-volume boxes with different slot counts.**
File: `app/Services/Cubing/FitnessEvaluator.php` (`calculateLargerBoxesFirstScore`)
Confidence: LOW
Issue: For example, `12@750` against `9@1000` or `6@1500`. Brute force found 14 such cases, all in a catalog with a synthetic 1000 mL box, and none with the seeded 750 and 1500 volumes.
Fix: Document this beside the existing limitation note. Optionally add a secondary slot-count tie-break if the PO means "more bottles".

**[LOW] N9. "The same measure empty_space and GreedyPacker use" is only partly true.**
File: `FitnessEvaluator.php` (docblock), against `GreedyPacker.php:31`, `GreedyPacker.php:349` and `FitnessEvaluator.php:146`
Confidence: HIGH
Issue: Only the decoder `packIntoParcels` uses volume. The fallback packers and `largest_package` use slots.
Fix: Say "the same measure empty_space and the GreedyPacker decoder use".

**[LOW] N10. The tie-break is absorbed by float precision at very large parcel counts.**
File: `FitnessEvaluator.php:80`
Confidence: MEDIUM
Issue:
- A single swap loses to the fitness ulp somewhere between 500 and 1000 parcels (measured).
- At 100 parcels the margin is still about 57 times the ulp.
- The failure mode is the pre-fix coin flip, not a wrong answer.
Fix: None needed. Optionally note it in the docblock. A lexicographic comparator would remove it (the old L3 suggestion).

**[LOW] N11. The CHANGELOG overstates some points.**
File: `CHANGELOG.md` (SBDEV-3524 entry)
Confidence: HIGH
Issue:
- "39 and 42 bottles were affected" is simulation-derived.
- "never overrides …" omits the preconditions.
- "down to 0.01 mL" overstates the test (see N1).
Fix: Change the first to "39 and 42 bottles tie the same way". Add "while weights and box capacities are integral / 0.01 mL-granular" to the second. Change the third to 0.03, or fix N1.

## Positive observations

- The weight change is correctly reasoned. The 0.01 mL resolution derivation (`decimal(9,2)` volume × integer `max_capacity`, with identical filled volume cancelling) is right, and the docblock now states both the invariant and its escape hatches.
- The fingerprint works on the production path. It is scoped per weight set, so pods with different env weights no longer share or cross-compare cached scores.
- The `getCapacityVolume()` extraction gives `empty_space` and the tie-break one definition of box size.
- The volume-sizing test discriminates between volume and slots and would catch a revert.
- All L1-L12 items were addressed in one focused commit, with no scope creep.

## Recommendation

**APPROVE.** There are no Critical, High or Medium findings in f7adfde5. Cheapest worthwhile follow-ups: N1 (a margin test that actually kills 0.5), N2 (a container-built fingerprint test) and N5/N11 (wording). The prior M1 stays open as an operational item on the ticket.
