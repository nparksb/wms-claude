---
head: 0dc762d23a790a5bf20d6efda641599fbdb9ed68
scope: 0dc762d2 only (test-only; answers L1-L3 of code-rereview-3.md)
reviewer: independent code-reviewer lane (not the author)
date: 2026-09-26
verdict: APPROVE
---

# SBDEV-3362: code re-review 4 (0dc762d2)

**head:** `0dc762d23a790a5bf20d6efda641599fbdb9ed68`. The worktree is clean: `git status --short` is empty, and the working file is byte-identical to `HEAD:` (checked with diff).
**File:** `src/test/java/net/aim_ai/wms/integration/CustomerorderForceCancelOutboxIntegrationTest.java:205-210` (+4/-3; there is nothing else in the commit)

## The change
```java
.rootCause()
// Quoted, so CO-CANCELLED-4 cannot match CO-CANCELLED-41.
.satisfies(root -> assertThat(String.valueOf(root.getMessage()))
    .as("root cause must be a unique violation on this order's CO-CANCELLED key")
    .containsIgnoringCase("unique")
    .containsIgnoringCase("'CO-CANCELLED-" + order.getId() + "'"));
```

## Evidence
- **The report on disk is the final passing run of the committed code.** The four timestamps are in order:
  - source mtime: 21:31:44
  - `.class`: 21:31:51
  - failsafe XML/TXT: 21:32:54 and 21:32:55
  - commit: 21:33:13

  The report reads `tests="2" errors="0" failures="0"`, with both testcases present and no `<failure>` or `<error>`.
- **The compiled class is the committed version.** `javap` shows:
  - `ldc "unique"` followed by `AbstractStringAssert.containsIgnoringCase`
  - an indy concat recipe `'CO-CANCELLED-\u0001'` (the quotes are compiled in) followed by `containsIgnoringCase`
  - no `toLowerCase` and no `"not null"` mutant residue
- **The real H2 message, from this passing run's own log** (`TEST-…xml:247`, SqlExceptionHelper ERROR):
  ```
  Unique index or primary key violation: "public.CONSTRAINT_INDEX_9 ON public.outbox_message(idempotency_key NULLS FIRST) VALUES ( /* 1 */ 'CO-CANCELLED-4' )"; SQL statement:
  ```
  The raw message keeps the original case: `'CO-CANCELLED-4'`, in single quotes. The lowercase form quoted in rereview-3 came from the old `toLowerCase()`. The quoted needle `'CO-CANCELLED-4'` therefore matches exactly, even before case-folding. `"unique"` matches `Unique` under the ignore-case comparison.
- **`containsIgnoringCase` is genuinely locale-free.** I checked the resolved AssertJ version: Boot 3.5.9 pins `assertj.version` 3.27.6. In `org.assertj.core.internal.Strings.containsIgnoreCase` (javap), both sides get `toLowerCase(Locale.ROOT)`. So the Turkish-`I` trap is closed inside the library as well, not just moved there.
- **Mutant line numbers:** `:207` is the `.satisfies(` line. A lambda-internal AssertionError is reported there, so the author's "red at :207" for mutants A and B is consistent with this file.

## L1-L3 of code-rereview-3

| # | Finding | Status | Basis |
|---|---|---|---|
| L1 | The key needle had no delimiter, so a `-4` needle could match `-41` | **ADDRESSED** | The needle is now `'CO-CANCELLED-<id>'` with H2's quote delimiters. The closing `'` rules out `-41`, and the opening `'` rules out a longer prefix. The optional tighter `outbox_message(idempotency_key` fragment was not adopted. That is acceptable: the value is quoted and the table holds exactly one seeded row. |
| L2 | `toLowerCase()` without a Locale | **ADDRESSED** | Both `toLowerCase` calls are gone. `containsIgnoringCase` uses `Locale.ROOT` (verified in the 3.27.6 bytecode). `String.valueOf` was kept: a null message becomes `"null"` and still fails loudly. |
| L3 | The evidence on disk was the mutant run, and only one conjunct had been mutated | **ADDRESSED** | A green report of the committed bytecode is on disk (see Evidence). Mutant A (`"unique"` changed to `"not null"`) now covers the conjunct that was previously unmutated. Mutant B (a wrong key) covers the value needle. The commit message names both mutants. The rereview-3 note to also state this in the PR body is still to do when the PR is written. It is not a code defect. |

## Issues

- **Critical:** 0
- **High:** 0
- **Medium:** 0
- **Low:** 1

### L1 [Low]: the quoted-key needle is tied to H2's message format
Confidence: HIGH on the fact; LOW that it matters.
`CustomerorderForceCancelOutboxIntegrationTest.java:210`

Postgres reports the value differently: `Detail: Key (idempotency_key)=(CO-CANCELLED-4) already exists.` That has parentheses and no single quotes. If this class is ever moved to the Testcontainers PG lane, the needle would go red. It would fail loudly, not pass vacuously, so the failure mode is safe.

The class is currently H2-only by construction: `BaseRollbackIntegrationTest:36` uses `jdbc:h2:mem:…MODE=PostgreSQL`, and the class javadoc `:42`/`:53` says so. This is informational, not blocking.

**Fix (optional):** extend the existing comment at `:206` to "Quoted as H2 renders it (PG would render `=(…)`)". That way a future port knows why it went red.

## Positive observations
- Each Low was answered in the way that was suggested, and each claim was backed by a measurement: a green report is on disk, and both conjuncts have a mutant that went red.
- The one-line comment at `:206` states why the quotes are there. That guards against someone "simplifying" them away.
- The earlier comment block (`:200-204`) still holds: the INSERT uses `?` placeholders, so the quoted value appears only in the violation clause, and the passing log confirms this.

## Recommendation
**APPROVE.** L1-L3 are all ADDRESSED. The quoted, case-insensitive needle matches H2 2.3.232's actual message byte for byte. Nothing else in the commit is wrong. The single new Low is an optional comment and does not block.
