---
head: 8be948ce4ef049190285aed9edaba9690b2c42b2
scope: 8be948ce only (comment-only; answers L1 of code-rereview-4.md)
reviewer: independent code-reviewer lane (not the author)
date: 2026-09-26
verdict: APPROVE
---

# SBDEV-3362: code re-review 5 (8be948ce)

**head:** `8be948ce4ef049190285aed9edaba9690b2c42b2`. The worktree is clean: the commit applies cleanly without merge conflicts, and the diff is comment-only.

**File:** `src/test/java/net/aim_ai/wms/integration/CustomerorderForceCancelOutboxIntegrationTest.java:206-208` (+3/-1; comment-only)

## The change

```java
// Quoted, so CO-CANCELLED-4 cannot match CO-CANCELLED-41. H2-specific format
// (`VALUES ( /* 1 */ 'CO-CANCELLED-4' )`): Postgres renders it `=(CO-CANCELLED-4)`, so a
// port of this test to the Testcontainers lane must change this line — it fails, not passes.
```

Extends the one-line comment at `:206` with two additional lines explaining:
1. This format is H2-specific.
2. The exact H2 violation message format: `VALUES ( /* 1 */ 'CO-CANCELLED-4' )`.
3. How Postgres renders the same violation differently: `=(CO-CANCELLED-4)`.
4. The consequence for future porting: changing the Testcontainers lane will require changing this assertion.

## Verification

**Word-diff confirms comment-only (no code tokens changed):**
All additions and deletions are within comment text (lines starting with `//`). No Java code tokens, variable names, method calls, or logic changed.

**H2 message format is accurately cited:**
Code-rereview-4.md, Evidence section (line 36-39): `"The real H2 message, from this passing run's own log (TEST-…xml:247, SqlExceptionHelper ERROR): Unique index or primary key violation: … VALUES ( /* 1 */ 'CO-CANCELLED-4' )"`. The comment cites `VALUES ( /* 1 */ 'CO-CANCELLED-4' )` exactly as it appears in the log.

**Postgres message format is accurately cited:**
Code-rereview-4.md, L1 section (line 63): `"Postgres reports the value differently: Detail: Key (idempotency_key)=(CO-CANCELLED-4) already exists."` The comment cites `=(CO-CANCELLED-4)`, which is the key format from the PG detail message, accurately.

**L1 of code-rereview-4 is answered:**

| Finding | Original suggestion | Actual fix | Status |
|---------|---|---|---|
| L1: The quoted-key needle is tied to H2's message format; Postgres renders it differently. | Extend `:206` comment to "Quoted as H2 renders it (PG would render `=(…)`)" | Added 3-line comment block explaining the H2 format (with the exact value), the PG format, and the consequence ("port must change this line — fails, not passes") | **ADDRESSED** |

The fix goes beyond the minimal suggestion — it provides not just the formats but the exact message fragments and a clear warning for future maintainers. This is an upgrade, not a deviation.

## Issues

- **Critical:** 0
- **High:** 0
- **Medium:** 0
- **Low:** 0

No new issues found. The comment is factually accurate, well-sourced, and does not introduce any new defects.

## Positive observations

- The comment cites exact message fragments from the passing test run, making it verifiable (code-rereview-4.md proves both fragments in its Evidence section).
- The addition serves the stated purpose: documenting why this test is H2-only and what a future port to the Postgres lane would need to change.
- The tone is practical for maintainers ("fails, not passes") — it alerts them to **not** assume the test is vacuous if it ever gets ported.
- The message formats (H2 and Postgres) differ enough that a naive port would produce a red, not a silent green, which is the desired failure mode.

## Recommendation

**APPROVE.** L1 of code-rereview-4 is fully addressed. The comment is accurate, sourced from the passing test's own log, and helps prevent accidental breakage or silent test vacuity in a future Postgres port. No other issues found.
