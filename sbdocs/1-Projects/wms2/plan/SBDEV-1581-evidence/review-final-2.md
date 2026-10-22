---
ticket: SBDEV-1581
kind: review
lane: scoped check of ecb43857 (final-review fixes)
date: 2026-10-18
verdict: APPROVE (one Medium design note, Lows)
---

# SBDEV-1581 review of ecb43857

Read-only, mvn not run. Evidence: `git show ecb43857`, `EmptyPalletCleanupJobService.cleanupEmptyPallets`, `EmptyPalletCleanupJob.runFor`, the unit test class, the seed IT, `grep` of seven/seventh.

Counts: CRITICAL 0, HIGH 0, MEDIUM 1, LOW 4.

## Checks requested

1. Rule vs javadoc. Implemented exactly: `result.candidates() > 0 && result.moved() == 0 && (result.failed() > 0 || result.refused() == result.candidates())`. Javadoc and catalog line 389 state the same expression. `candidates` is `ids.size()`, the SELECTED ids. Every id lands in exactly one of the six other buckets (switch over all four enum outcomes, two catches), so selected == processed == sum of the others, and the `Result` javadoc "candidates is the sum of the other six" is true. Consequence: `refused == candidates` implies `moved == 0`; the `moved == 0` term only matters for the `failed` arm. Reason selection (`failed > 0` first, else AllRefused) is consistent; the else arm is reachable only when failed == 0 and refused == candidates.
2. Branch tests (each would fail if the branch were removed):
   - `refused == candidates` arm: `allRefusedIsATenantFailure`, `singleRefusedCandidateIsAllRefused` (verify tenantFailure AllRefused, never success).
   - `failed > 0` arm: line 366 (3 failed), `refusalsPlusOneUnexpectedFailureIsATenantFailure` (3 refused + 1 failed, so the `||` cannot be turned into `refused == candidates` only).
   - `candidates > 0` guard: `zeroCandidatesIsASuccess` (0 == 0 would otherwise be a failure).
   - `moved == 0` guard on the failed arm: line 383 (moved 1, failed 2, success).
   - Success side: `someRefusedRestSkippedIsASuccess`, `allButOneRefusedAndOneMovedIsASuccess`.
   - Reason tags are asserted per arm. Sound.
3. New false claims: none material. See L-1, L-2 for residue. Implementer's "Unit +3" arithmetic checks (4 new, 1 replaced). PIT counts (54 killed, 26 tests) and the full-suite counts are not verifiable read-only; I did not rely on them.
4. Seed IT absence check: sound. The target is `max(version < 2.2.41)` from `Flyway.info().all()` on the classpath (nulls for repeatables filtered), not hard-coded; it follows V2.2.40 landing. It would also go red if another earlier migration seeded the keys (non-vacuity), and head presence is still asserted. Only the upper bound `SEED_VERSION` is a literal, matching the seed filename.

## Issues

### [MEDIUM] M-1: a single refused candidate now stalls last_success, including a race-driven one
File: `EmptyPalletCleanupJob.java`: `result.refused() == result.candidates()`; test `singleRefusedCandidateIsAllRefused`
Confidence: MEDIUM
Issue: the all-refused arm cannot tell a type-wide constraint from "one row". With candidates == 1 (the common steady state once the backlog drains) a single pallet that a constraint always rejects withholds `last_success` for the whole group fire every night, which is the stall the re-review M-2 decision accepted not having. A race-driven refusal (`Result` javadoc: has-stock / is-carrier backstop, "Unitload not found") on a lone candidate does the same once, falsely. The test pins this deliberately, but neither the job javadoc nor catalog 4.6a mentions that the single-candidate case is included, and the `Result` javadoc says race refusals "clear on their own".
Fix: either accept and state it in the javadoc and catalog ("including a run with one candidate"), or require `candidates >= 2` (or a refused threshold) for the arm and keep the single case a success with an ERROR log. Needs a decision, not blocking.

### [LOW] L-1: "the newest job" in test javadocs is a current-state claim
File: `SchedulingConfigurationUnitTest.java:87` and `SchedulingReconcileIdempotencyUnitTest.java:119`: "(the newest job: emptyPalletCleanup, SBDEV-1581)"
Confidence: HIGH
Issue: replaces a closed count with another claim that goes false with the next job. "for a single-zone tenant" is correct per line 112 but equally prose. The constant is still the literal `7`.
Fix: drop the parenthetical, or derive from `CONFIGURED_JOB_NAMES.size()`.

### [LOW] L-2: residual count-named test and stale-prone strings
File: `SchedulingConfigurationUnitTest.java:982` `fullRegistrationIsReportedAsAllSeven`; `SchedulingConfiguration.java:146` "Before SBDEV-3198 all seven ..." (dated, acceptable)
Confidence: HIGH
Issue: the DisplayName was restated but the method name still says AllSeven. The implementer's claim "remaining hits are historical" holds for main sources; the method name is the exception.
Fix: rename to `fullRegistrationIsReportedAsAllOfThem`.

### [LOW] L-3: inconsistent tenant naming across the two ERROR branches
File: `EmptyPalletCleanupJob.java`, the two `LOG.error` calls
Confidence: HIGH
Issue: the AllRefused ERROR omits the refused count (equals candidates, so fine) but the pair is otherwise formatted differently, and neither ERROR branch has a test on the log line (the implementer says the INFO/wording survivors are accepted). The AllRefused text asserts "likely a location constraint", which is a guess; a race or a seed gap can also do it.
Fix: optional; soften to "e.g. a location constraint".

### [LOW] L-4: seed IT `SEED_VERSION` is not tied to `SEED_FILE`
File: `EmptyPalletCleanupSeedMigrationIT.java`: `MigrationVersion.fromVersion("2.2.41")` vs `SEED_FILE = ".../V2.2.41__..."`
Confidence: LOW
Issue: two literals for one fact. If the file is renumbered, test 2 fails loudly (resource missing) but test 1 stays green with a stale bound.
Fix: derive the version from the SEED_FILE name.

## Positive observations
- The rule is stated identically in code comment, job javadoc, catalog and commit message, and the tests name each arm.
- Non-vacuity in the seed IT is derived, so SBDEV-3672's V2.2.40 needs no edit.
- The `Result` javadoc now states the rule by exception type and drops the unreachable STORAGELOCATION_LOCKED.

## Recommendation
APPROVE. Decide M-1 (document or gate single-candidate) and fix the Lows in the same pass.
