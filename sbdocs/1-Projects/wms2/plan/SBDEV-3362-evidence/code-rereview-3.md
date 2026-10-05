---
head: b4a2f55f0bab73c155027745eec272a343d23696
scope: b4a2f55f only (test-only; answers R1 of code-rereview-2.md)
reviewer: independent code-reviewer lane (not the author)
date: 2026-09-26
verdict: APPROVE
---

# SBDEV-3362: code re-review 3 (b4a2f55f)

**head:** `b4a2f55f0bab73c155027745eec272a343d23696`. The worktree is clean (`git status --short` is empty).
**File:** `src/test/java/net/aim_ai/wms/integration/CustomerorderForceCancelOutboxIntegrationTest.java:196-209`

## Stage 1: does it answer R1?
Yes. R1 said the class-level `isInstanceOf(DataIntegrityViolationException.class)` would also pass on NOT NULL, length or FK failures. The commit adds a root-cause check that requires both the H2 unique-violation wording and this order's key value. The fix is different from the one R1 suggested (`hasMessageContaining("idempotency_key")`). The author's reason holds up: the column name appears in the echoed INSERT column list, so that check would match any failure on this table. I confirmed this from the logged message below.

## Evidence: the actual H2 message (not guessed)
`target/failsafe-reports/TEST-…CustomerorderForceCancelOutboxIntegrationTest.xml:78-79` and the SqlExceptionHelper ERROR log at `:263-264`:

```
unique index or primary key violation: "public.constraint_index_9 on public.outbox_message(idempotency_key nulls first) values ( /* 1 */ 'co-cancelled-4' )"; sql statement:
insert into outbox_message (aggregate_id,aggregate_type,…,idempotency_key,…,id) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,default) [23505-232]
```

Note: the report on disk is from the **mutant** run (`to contain: "co-cancelled-1004"`, which is 4 + 1000, failing at `:209` in the lambda and `:206`). Its timestamp is 21:24:23, 11 s before the commit. No on-disk artifact shows the committed version passing. But the committed assertion's two needles, `"unique"` and `"co-cancelled-4"`, are both in the message above, so the pass follows from the measured message.

## Answers to the specific questions

1. **Can "co-cancelled-<id>" appear for reasons other than the violation clause?** No.
   - The echoed SQL uses `?` placeholders. The logger prints the same statement, and no bound values are logged.
   - H2's 23505 text is `Unique index or primary key violation: {0}`, and `{0}` carries only the offending tuple of that one index.
   - The other integrity codes in `_messages_en.prop` (H2 2.3.232) are:
     - `23502` `NULL not allowed for column {0}`: no value.
     - `23503/23506` `Referential integrity constraint violation`: the value would be an FK id, not the key string.
     - `23513` check.
     - `22001` `Value too long for column {0}: {1}`: this one **does** echo the value, so an over-long key that starts with `CO-CANCELLED-4` would match the second needle. It would fail the `"unique"` needle, though. The two conjuncts cover each other's gap, and neither is redundant.
2. **Prefix aliasing (id 4 vs 41/42):** theoretically possible in the substring, but not reachable here.
   - The message contains exactly one value: the one that collided.
   - `setUp` runs `outboxMessageRepository.deleteAll()`, so the only row that can collide is the one seeded with `"CO-CANCELLED-" + order.getId()`.
   - A collision on `CO-CANCELLED-41` would need a seeded `…-41` row, and none exists.
   - Hardening is cheap anyway (L1).
3. **Is `.contains("unique")` meaningful?** Yes. It is the only needle that separates 23505 from 22001 (see 1).
   - "unique" does not occur in the echoed INSERT: no column name contains it.
   - It also matches H2's PK-violation wording. The PK is `id … default` (identity), so that path cannot carry the key value and still fails needle 2.
   - It is locale-robust. `DbException`'s static init (sources `:70-90`) stores `translation + "\n" + original`, so the English "Unique index…" is always present, even under a German, French or other JVM locale.
   - It would also hold on Postgres ("violates unique constraint", with the Detail showing the value), although this class only runs on H2.
4. **Is the lambda wrapped so failures report correctly?** Yes, measured. `satisfies(ThrowingConsumer)` runs the inner `assertThat(...).as(...)` and collects its AssertionError into an `AssertJMultipleFailuresError`. The report shows both descriptions: the outer "the duplicate key must fail… not some unrelated failure", then the inner "root cause must be a unique violation…". It also shows actual vs expected and the lambda line `:209`. `rootCause()` fails loudly if there is no cause, so a cause-less exception cannot silently pass.

## Issues

- **High:** 0
- **Medium:** 0
- **Low:** 3

### L1 [Low]: the key needle has no delimiter, so prefix aliasing is possible in principle
Confidence: HIGH that it is unreachable today; LOW that it matters.
```java
.contains(("CO-CANCELLED-" + order.getId()).toLowerCase()));
```
`co-cancelled-4` is a substring of `co-cancelled-41`. This cannot happen in this test (see Q2). The only case is a future fixture that seeds a neighbouring key, which would then pass on the wrong row.
**Fix:** include H2's quote delimiters: `.contains("'" + ("CO-CANCELLED-" + order.getId()).toLowerCase() + "'")`. This is still H2-specific. Alternatively, assert the violation clause more tightly: `.contains("outbox_message(idempotency_key")` plus the quoted value. The `outbox_message(idempotency_key` fragment appears only in the index clause, not in the INSERT column list, which renders as `outbox_message (aggregate_id,…`.

### L2 [Low]: `toLowerCase()` without a Locale
Confidence: MEDIUM.
```java
String.valueOf(root.getMessage()).toLowerCase()
… ("CO-CANCELLED-" + order.getId()).toLowerCase()
```
This is harmless today: neither needle contains a capital `I`, so a Turkish-locale JVM gives the same result. It is still the textbook locale trap, and a later needle such as "INDEX" would break under `tr`.
**Fix:** use `.containsIgnoringCase("unique").containsIgnoringCase("CO-CANCELLED-" + order.getId())` on the raw message. That drops both `toLowerCase` calls and the `String.valueOf`, while a null message still fails, with AssertJ's "actual is null".

### L3 [Low]: the evidence on disk is the mutant run; only one conjunct was mutation-checked
Confidence: HIGH.
- The failsafe report left in `target/` is the red mutant run, so there is no on-disk green run of b4a2f55f.
- Only the value needle was mutated (`+1000`). The `"unique"` needle was not mutated. It is analytically sound (Q3), but it has no red measured behind it.
**Fix:** re-run the IT once so a green report sits beside the commit, and state in the PR body which needle was mutated. Optionally, mutate `"unique"` to `"unique-x"` and confirm red.

## Positive observations
- The author measured the R1 suggestion vacuous instead of just adopting it. The diagnosis (the INSERT column list echoes every column name) is exactly right: the logged message shows it.
- Asserting the duplicated **value** is stronger than asserting the column name. It pins column, value and this order in one needle, since only `idempotency_key` could hold `CO-CANCELLED-<id>`.
- The inline comment explains why the column-name check was rejected, which fences off a well-meaning "simplification" back to it.
- The mutant went red with the assertion's own description, not an unrelated error. This is the right kind of red.

## Recommendation
**APPROVE.** The assertion is sound against H2 2.3.232's real message: it is not vacuous, it is locale-robust, and it reports correctly. The three Lows are cheap hardening. Under the house rule on Lows, fold L1 and L2 in (one line each) if the branch is touched again, and do L3 before the PR.
