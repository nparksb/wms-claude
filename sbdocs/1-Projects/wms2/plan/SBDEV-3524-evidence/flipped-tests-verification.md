---
title: SBDEV-3524 flipped-tests verification — controlled experiment
type: report
status: final
date: 2026-09-26
related:
  - db-lane-tests.md
  - reset_and_run.sh
---

# SBDEV-3524 flipped-tests verification

## Question

A previous lane, running the full `tests/Unit` suite against a throwaway persistent MySQL 8 DB,
observed two tests flip pass→fail/error between `BASE` (`14526ab9`, origin/develop) and an
intermediate SBDEV-3524 commit (`f7adfde5`):

1. `Tests\Unit\Services\OrderShipperServiceTest::test_map_sort_field` — pass at BASE, **ERROR**
   (`UniqueConstraintViolationException` on `view_by_shipper_count_cache.shipper_id`) at the fix.
2. `Tests\Unit\Services\ShippingServiceTest::switching_a_parcel_to_pickup_clears_its_insurance_charge`
   — pass at BASE, **FAIL** (`'2400.00' matches expected 0.0`) at the fix.

That lane hypothesised test-order/DB-state pollution (the suite shares one persistent DB across
classes, never resetting it) shifted by SBDEV-3524's 11 added Cubing tests, but never proved it.
This experiment was commissioned to prove or disprove that, comparing `BASE` against the actual
ship commit `dc10b1ab` (branch `bug/SBDEV-3524`, containing `4bce80ba` + `f7adfde5` + `dc10b1ab`).

**Scope confirmed**: `git diff --stat 14526ab9 dc10b1ab` touches only
`app/Services/Cubing/{FitnessEvaluator,CubingCacheService,Parcel}.php`, `config/cubing.php`,
`CHANGELOG.md`, `scripts/cubing-comparison/README.md`, and adds
`tests/Unit/Services/Cubing/LargerBoxesFirstCubingTest.php` (11 tests). Nothing under
`app/Services/ShippingService.php`, `app/Services/Label/WillCallLabelService.php`,
`app/Services/ConfigurationService.php`, `app/Services/OrderShipperService.php`, or
`CarrierShipMethodLut` is touched.

## Headline result

**Neither flip reproduced when comparing BASE against the actual ship commit `dc10b1ab`.** Both
named tests came out **identically on every one of A/B/C/D**, in both isolation and the ordered
full suite:

| Test | Isolated A (BASE) | Isolated B (SHIP) | Full A (BASE) | Full B (SHIP) | Full C (BASE+test file) | Full D (SHIP−test file) |
|---|---|---|---|---|---|---|
| `OrderShipperServiceTest::test_map_sort_field` | **PASS** (16 asrt) | **PASS** (16 asrt) | **PASS** | **PASS** | **PASS** | **PASS** |
| `ShippingServiceTest::switching_a_parcel_to_pickup_clears_its_insurance_charge` | **FAIL** `'2400.00' matches expected 0.0` | **FAIL** (identical message) | **FAIL** (#37 in failure list) | **FAIL** (#37, identical message) | **FAIL** (#42) | **FAIL** (#38) |

Re-running the insurance test twice in isolation on A gave the byte-identical failure both times —
this is a deterministic, not flaky, outcome in this environment.

Full-suite totals (for context, not the verdict):

| Worktree | Tests | Errors | Failures | Warnings |
|---|---|---|---|---|
| A = BASE (14526ab9) | 4567 | 197 | 41 | 0 |
| B = SHIP (dc10b1ab) | 4578 | 197 | 41 | 0 |
| C = BASE + new test file only | 4578 | 203 | 46 | 3 |
| D = SHIP − new test file | 4567 | 195 | 42 | 0 |

(A vs D — same test count, product diff present in D only — differ by 2 errors / 1 failure
elsewhere in the suite, confirming the product diff does move a small number of *other*,
unrelated tests. It does not move either of the two named tests, in any of the four variants.)

## Decision rule applied

Per the brief's rule:

> Flipped tests pass alone in both A and B, AND the flip appears in C and/or vanishes in D →
> test-order pollution; SBDEV-3524's product change is exonerated.
> Flip appears in D, or a test fails alone in B but passes alone in A → the product change is
> implicated.
> Anything else → report exactly what you saw, without forcing it into a verdict.

- **`test_map_sort_field`**: passes alone in both A and B, and passes in every full-suite variant
  (A/B/C/D) — there is no flip anywhere to attribute. This is a stronger form of the first clause:
  not just "the flip is explained by pollution," but "no flip exists at all" against the real ship
  commit. **SBDEV-3524 is exonerated** for this test (it also isn't implicated by files touched:
  the diff never goes near `OrderShipperService.php` or `view_by_shipper_count_cache`).
- **`switching_a_parcel_to_pickup_clears_its_insurance_charge`**: fails identically in *every*
  variant tried, including alone in BASE with zero other tests having run. This doesn't match
  either clause cleanly (it never "passes alone in both A and B"), so per the rule this is the
  **"anything else"** bucket. Reported without forcing a verdict onto the pollution/product axis:
  whatever makes this test fail is present on BASE already, with zero predecessors, and is
  unchanged by the SBDEV-3524 diff (same message, same line, on SHIP). **SBDEV-3524 is exonerated**
  by a different argument than pollution — the test is broken/order-independent on develop itself,
  and the diff never touches any file the test exercises (`ShippingService`,
  `WillCallLabelService`, `ConfigurationService`, `CarrierShipMethodLut`,
  `ParcelInsuranceService`).

**Both tests are cleared of any SBDEV-3524 causation. Neither result depends on the product diff.**

## Why this differs from the prior lane's reported baseline

The prior lane's script was deleted and had to be rebuilt from the recipe document plus a memory
note; the rebuilt version (saved as `reset_and_run.sh` in this directory) reproduces the full
setup pipeline (landlord migrate → seed tenant row → tenant-initial baseline → tenant migration
drift-retry loop → `db:create-test-data` → phpunit) and is internally deterministic (repeat runs on
the same commit give byte-identical results). It is not possible from here to confirm exactly what
differed in the original (now-gone) script — this run cannot rule out a difference in retry-loop
detail, a different point-in-time migration set, or some now-irreproducible state — but this
environment's own repeated-run determinism means the discrepancy is not itself evidence of
flakiness in the suite; it is evidence that the exact reproduction recipe matters and this rebuild
does not byte-for-byte match whatever produced the original observation. Given that, this report
trusts what was actually observed here over the un-reproducible prior claim, and states the
mismatch plainly rather than forcing agreement.

One concrete, unrelated finding surfaced while investigating the insurance test's deterministic
failure: `database/migrations/landlord/2026_02_03_100000_add_label_automation_configurations.php`
seeds config rows via `INSERT INTO system_configurations (...) VALUES (...) ON DUPLICATE KEY
SKIP`, which is **not valid MySQL syntax** (`ON DUPLICATE KEY SKIP` — confirmed by hand: MySQL
returns `ERROR 1064 ... near 'SKIP'`). The migration's own `try/catch` swallows this every time,
logs it, and reports `DONE`, so `label_automation.will_call.carrier_codes` never actually gets a
row in this from-scratch environment (verified: `SELECT * FROM system_configurations WHERE
config_key='label_automation.will_call.carrier_codes'` → 0 rows, while sibling
`label_automation.*` keys from the same migration/file are present). `WillCallLabelService`'s
constructor default already includes `WCP`, so this alone does not explain the test failure and
was not chased further (out of scope for this task — the test's own failure is identical on BASE
and SHIP regardless of its ultimate cause). Flagging it here only because it is a genuinely broken
migration statement, unrelated to Cubing, worth a separate look.

## Polluter search (step 3)

Not applicable — no flip occurred in this reproduction, so there was no flip to trace to a
predecessor test. For completeness: PHPUnit's default discovery runs `tests/Unit/Services/*.php`
alphabetically; `OrderShipperServiceTest` and `ShippingServiceTest` both run with zero errors/one
identical failure regardless of whether the 11 Cubing tests exist (they live in a separate,
alphabetically-earlier `Cubing/` subdirectory and touch no shared tables with either flipped
test's fixtures) — consistent with the "no dependency on predecessor tests" conclusion above.

## Is the same pollution latent on develop?

No evidence of it in this experiment: neither test's outcome depended on what ran before it in any
of the four variants tested (including a true zero-predecessor isolation run), so this experiment
cannot confirm the "any added test could trigger it" hypothesis — if anything, the one fragile test
here (`switching_a_parcel_to_pickup...`) failed with zero predecessors, which argues against
cross-class pollution being the operative mechanism for it on this environment.

## Cleanup confirmation

- `docker rm -f oms-flipcheck-mysql` → removed.
- `docker network rm oms-flipcheck-net` → removed.
- `docker rmi oms-unit-php84-mongo-flipcheck` (derived image) → removed; base `oms-unit-php84`
  confirmed still present and untouched (`docker images | grep oms-unit-php84` → present, 4h old).
- `git worktree remove --force` for all four scratch worktrees (`A-base`, `B-ship`,
  `C-base-plus-test`, `D-ship-minus-test`) → removed; `git worktree list` on
  `v2/oms-laravel-api` confirms none remain.
- Scratch directory (`.../scratchpad/flipcheck`) removed, except the saved
  `reset_and_run.sh`, which was copied to this evidence directory before deletion.
- The read-only `.claude/worktrees/oms-laravel-api/SBDEV-3524` worktree was only read from
  (`vendor/`, `.env.testing`) and never mutated.

## Addendum (main session, 2026-09-26): the unnamed A-vs-D delta, measured per test

The table above shows A (BASE) and D (SHIP − new test file) differing by 2 errors / 1 failure with the
same test count, and names no test. Re-measured with the saved `reset_and_run.sh`, per-test via junit
(files + `diff.py` in `noise-check/`):

| Run | Commit | Tests | Errors | Failures |
|---|---|---|---|---|
| A1 | BASE 14526ab9 | 4567 | 195 | 43 |
| A2 | BASE 14526ab9 (repeat) | 4567 | 195 | 43 |
| D1 | SHIP dc10b1ab − LargerBoxesFirstCubingTest.php | 4567 | 197 | 41 |
| B1 | SHIP dc10b1ab | 4578 | 197 | 41 |

- A1 vs A2: **0** per-test changes (the full suite is repeatable run to run).
- A1 vs D1 and A1 vs B1: exactly **2** changes, both in `Tests\Unit\Jobs\CarrierTrackingBatchJobTest`
  (`it_ignores_an_unknown_carrier_status`, `it_records_the_check_for_a_response_with_no_status_key`),
  **failure → error on both, i.e. red on BASE and red on SHIP**. B1's 11 `LargerBoxesFirstCubingTest`
  tests all pass. Nothing else moves.
- **`CarrierTrackingBatchJobTest` is nondeterministic on BASE in isolation.** It was run alone
  (`--filter`, fresh DB each time) four times on the same BASE commit, and gave four results:
  3E/6F, 1E/11F, 1E/11F, 3E/9F (of 15 tests). The A-vs-D delta is inside that spread, so it says
  nothing about the product change, and the class is broken on develop regardless (9–12 of 15 red
  alone). It is time-sensitive (`now()->subHour()`, staleness thresholds) and unrelated to cubing.
- Note: an earlier rerun attempt silently ran with **no DB**. phpunit loads `.env.testing`
  (APP_ENV=testing), not `.env`, so the rewritten `.env` was ignored (1971 connection-refused errors).
  Fixed by pointing `.env.testing` at the container, with one DB-bound test as a positive control
  before the full runs.

**Verdict: across the full MySQL-backed `tests/Unit`, SBDEV-3524 changes the outcome of no
deterministic test.** The only movers are two already-red tests in a class that is nondeterministic
on develop by itself.
