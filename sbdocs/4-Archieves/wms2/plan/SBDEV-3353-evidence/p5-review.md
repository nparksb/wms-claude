head: 0cd17825

# SBDEV-3353 — P5 review of two unreviewed commits (`14786f9d`, `0cd17825`)

- **Scope:** `git show 14786f9d` and `git show 0cd17825` in `wms2-api`, per the task brief. Read-only,
  read-and-reason review; no Maven run (orchestrator IT run in progress); no git stash/checkout/restore.
- **Tree:** `.claude/worktrees/wms2-api/SBDEV-3353-review`, detached at `0cd17825`, mine alone.
- **Reviewer:** an independent lane (code-reviewer). Did not author either commit, `p4-rail-fix.md`, or
  `p4-review.md`.
- **Instrument used beyond reading:** the rail's own logic (`NEVER_VERIFY`, `DESCRIPTION_CALL`,
  `VERIFIED_CALL`, `methodArgsOpen`, `spanEnd`) was copied verbatim into a standalone `.java` file and run
  with plain `javac`/`java` (no Maven, no test suite, no project build) to get ground truth on regex/lexer
  behavior instead of hand-tracing it — hand-tracing `spanEnd`'s return convention once produced a wrong
  conclusion of my own (see Check B.1) until the standalone run corrected it.
- **Verdict: APPROVE.** No CRITICAL or HIGH finding. One MEDIUM finding: a real, reproduced, currently-dormant
  gap where a Java text-block `.description("""…""")` can make the widened rail silently drop the site
  (exactly the "triple-silent" failure class this commit exists to close), not covered by today's 18 real
  sites but also not documented as a known limitation. Two LOW findings (a doc/commit-message line-count
  discrepancy; a redundant re-scan on the unclosable-description path). Everything else in the two commits
  checks out as described.

## Check A — `14786f9d` (SBDEV-3442 rebase fixture fix)

**Claim:** the only change is stubbing `findByLabelidForUpdate` instead of `findByLabelid` in
`MobileMoveUnitloadServiceUnitTest$Sbdev3353ParcelSourceStockMove.arrive()`, no assertion changed, no stub
left dangling.

- `git show 14786f9d` touches exactly one file, one hunk, one line:
  `src/test/java/.../MobileMoveUnitloadServiceUnitTest.java:1848`:
  ```
  -            lenient().when(unitloadRepository.findByLabelid("PKG-0101")).thenReturn(Optional.of(source));
  +            lenient().when(unitloadRepository.findByLabelidForUpdate("PKG-0101")).thenReturn(Optional.of(source));
  ```
  This is an in-place **substitution**, not an addition next to a surviving old stub — so there is no
  second `findByLabelid("PKG-0101")` line left dangling for strict stubs to have caught or missed. Confirmed
  by reading the full `arrive()` method (`:1817`–`:1862`): the destination stub at `:1857`
  (`findByLabelid("C-0201")`) is unrelated — it stubs the *destination* label, which `scanDestination`
  still resolves via the plain (non-locking) finder, not the source.
- Repo-wide `grep -n "findByLabelid\b"` over this test class shows 15 other call sites, none referencing
  `"PKG-0101"` — no sibling stub for this fixture was left behind.
- **`lenient()` and strict stubs — answering the "is lenient hiding it?" question directly:** yes, in
  general `lenient()` opts a stub out of Mockito's `UnnecessaryStubbingException` (strict-stubs) check —
  that is its entire purpose. So *if* the rebase had left the old `findByLabelid("PKG-0101")` stub as a
  second, additional line rather than editing it in place, strict stubs would **not** have flagged it as
  dangling; only a passing/failing assertion or a manual diff read would have caught it. In this specific
  diff that risk does not materialize, because the change is a straight one-line substitution confirmed by
  `git show`, not an addition — but the safety net here is the diff shape, not the test framework.
- Sibling consistency: SBDEV-3442's own equivalent fixture at `:1449` uses the identical shape
  (`lenient().when(unitloadRepository.findByLabelidForUpdate("PKG-0001"))…`), so `14786f9d` is doing exactly
  what its commit message claims — the same substitution SBDEV-3442 made for its own sibling.

**Verdict: no issues. Confirmed exactly as described.**

## Check B — `0cd17825` (the rail widening)

### B.1 — Hand-walking `methodArgsOpen` / the description-skip logic

I built a standalone reproduction (`RailCheck*.java`, `javac`+`java`, no Maven) copying `NEVER_VERIFY`,
`DESCRIPTION_CALL`, `VERIFIED_CALL`, `methodArgsOpen`, and `spanEnd` verbatim, then ran the six shapes asked
for plus the two extra shapes the task named:

| Shape | Result | Correct? |
|---|---|---|
| `)` inside the description string (`.description("stop) here")`) | opens the span; finds `anyString()` in `.save(...)` | **Correct** |
| Multi-line description built from `+`-concatenated literals, verified call on the next line | opens the span; finds the offender | **Correct** |
| Escaped quote `\"` inside the description string | opens the span; finds the offender | **Correct** — via `spanEnd`'s pre-existing backslash-skip (`i += charAt(i)=='\\' ? 2 : 1`), unchanged by this commit, correctly reused here |
| Nested parens via `never().description(String.format("x(%s)", y))` | opens the span; finds the offender | **Correct** — `spanEnd`'s depth counter handles this generically, no special-casing needed |
| Java text block: `never().description("""…(paren)…""")` | **silently drops the site — no offender, no `<UNBALANCED>`** | **Gap — see Finding 1** |
| `verify(mock, times(0)).method(...)` — "something other than `.description` after `never()`" | `NEVER_VERIFY` itself never matches (it requires the literal text `never(`), so the site is out of scope, not mis-parsed | **Correct / N/A**, matches the task's own framing |

I initially hand-traced `spanEnd`'s return convention wrong (assumed it returns the index of the matching
`)`; it actually returns `i + 1`, one past it) and concluded the whole widening was broken. The standalone
run corrected that: `spanEnd(src, open)` returning one-past-the-close is exactly why `i = end` in
`methodArgsOpen` lands `VERIFIED_CALL`'s region start on **verify's own** closing paren (the second of the
two `))` after `.description(...)`), not on the description's own closing paren — the arithmetic in the
committed code is right. I record this in case it saves the next reader from making the same mistake by
hand.

**[MEDIUM] Finding 1 — a Java text block inside `.description(...)` can make `methodArgsOpen`/`spanEnd`
silently drop the site (the exact "triple-silent" failure class this commit exists to close).**
- **Confidence:** HIGH (reproduced against the exact committed regex/lexer code, standalone, twice, with
  two different text-block bodies).
- **File:** `src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java`, the
  `spanEnd` method (`:774`–`:789`, unchanged by this commit) as newly reused by `methodArgsOpen`
  (`:96`–`:106`, new in this commit).
- **Reproduction:** for
  ```java
  verify(repo, never().description("""
          one " quote and a ) paren
          """)).save(anyString());
  ```
  (a text block containing exactly one literal `"` — an odd count — plus a real `)`), `findOffenders(...)`
  returns `[]`. Nothing is added to `offenders`, `neverSpans` is not incremented for this site, and nothing
  is added to `unbalanced` either. The genuine `anyString()` offender two tokens later, inside `.save(...)`,
  is never seen. With an *even* count of literal `"` inside the text block, by contrast, it happens to
  self-correct and scan correctly (confirmed with two such cases) — so the failure mode is parity-dependent,
  not "text blocks always break it," which is what makes it a silent, intermittent gap rather than a loud
  one.
- **Why it happens:** `spanEnd`'s quote-skip clause (`c=='"' … while (charAt(i)!=q) …`) only understands a
  single-`"` string delimiter. A text block's opening `"""` is parsed by that same logic as two accidental
  zero-length "strings" (quote 1→quote 2, then quote 2→quote 3) followed by a "string" that runs from just
  after the third quote to whatever the *next* literal `"` character is — which, inside ordinary text-block
  content, is either the closing `"""` (if the content has zero or an even number of stray `"` chars) or
  some content character (if odd), and in the odd case the parse desynchronizes and can walk past or land on
  the wrong paren. `spanEnd` is pre-existing code (not touched by `0cd17825`) and never claimed text-block
  support; this commit is the first to route `.description(<expr>)` content — an arbitrary string
  expression — through it, which is exactly where a text-block description would land.
- **Is it live today?** No. Per `p4-rail-fix.md`'s own enumeration, all 18 real `.description(...)` sites
  measured are ordinary string literals or `+`-concatenations (e.g. `"SBDEV-3353 N1/P3-3: …"`); none uses a
  text block. So this does not misfire on anything the suite runs today, and the tree-wide floors
  (`scanned`, `neverSpans`, `unbalanced` — all unchanged, still passing per the author's own `mvn` run) would
  not be expected to catch it, since nothing in the real tree exercises it.
- **Why it's worth flagging anyway:** the class's own stated purpose is to close exactly this shape of gap
  — a formatting-only edit (switching a description to a text block for readability, which nothing forbids)
  silently disarming the rule with zero signal, no `<UNBALANCED>` entry, nothing. That is precisely the
  hazard the `never ()` -vs- `never()` whitespace probe and this very commit's `.description(...)` widening
  were both written to close. The class's "What is deliberately NOT flagged" javadoc section lists several
  known blind spots (qualified `Mockito.never()`, `MockedStatic`, `BDDMockito.should(never())`, `times(0)`,
  non-identifier mocks, explicit type witnesses, matcher-behind-a-helper) but does not mention text-block
  descriptions, so this rule's own coverage claim is — like the `.description()` gap this commit just closed
  — itself incomplete in a way nobody has yet noticed.
- **Fix (not a blocker):** either (a) teach `spanEnd` to recognize a `"""` delimiter as one atomic token
  (skip to the matching closing `"""`, not to the next bare `"`), or (b) narrower and cheaper, add one
  self-test case with an odd-quote-count text block description that currently reds under `containsExactly`,
  document the limitation in the `methodArgsOpen`/class javadoc next to the other listed exemptions, and
  file a follow-up ticket. Either is fine for a later pass; nothing here blocks this commit, since it
  strictly improves on the pre-commit state (0 of 18 real sites scanned → 16 of 18) and introduces no
  regression on any site that exists today.

### B.2 — Non-vacuity of the existing floor vs. the widening's own correctness

- The tree-wide floors (`scanned > 300`, `neverSpans > 400`, `unbalanced` must be empty — all at
  `:249`–`:262`, unchanged by this commit) are **not** sensitive to whether the new description-widening
  finds any of the 16 newly-opened real sites: the pre-existing non-description population alone (~839 of
  the measured 857 spans) already clears the 400 floor by a wide margin. So these floors continue to guard
  against the *general* "the scan broke / found nothing" failure mode, but they do **not**, by themselves,
  prove the description-widening is doing anything on the real tree.
- What *does* prove the widening works on real shapes is the four new cases in
  `detectorFiresOnTheMeasuredHistoricalShapes` (see B.3) — confirmed genuine by direct reproduction, not by
  the floor.
- **[LOW] the "16 of 18 sites… 1203 → 1221" measurement is reported in the commit message and
  `p4-rail-fix.md`, but is not pinned by any assertion.** `16 + 2 = 18 = 1221 - 1203`, so the arithmetic in
  the write-up is internally consistent, and I did not re-run Maven to re-derive the absolute numbers per
  the task constraint. But nothing in the suite asserts "at least N real (non-self) sites now open a
  description-chained span" — only the generic 400 floor and the hand-crafted self-test snippets. A future
  change that broke the widening specifically on some real-world description shape not resembling the four
  self-test snippets (e.g., the text-block case in Finding 1, or some other unanticipated shape) would not
  be caught by anything in this file. This is consistent with how the rest of the file already works
  (synthetic representative snippets rather than pinning exact site counts elsewhere), so it's a minor,
  pre-existing style of gap rather than a new one — not blocking.

### B.3 — The four new self-test cases: genuine positive controls?

Reproduced all four with the standalone harness, using the file's own real `anyStr`
(`"any" + "String()"`) and `anyCls` (`"any" + "(Unitload.class)"`) definitions:

| Case | Expected | Reproduced |
|---|---|---|
| 1. `)` inside description | `containsExactly(anyStr)` | `[anyString()]` — matches |
| 2. Multi-line concatenated description, verified call on next line | `containsExactly(anyCls)` | `[any(Unitload.class)]`-shape — matches |
| 3. Compliant `never().description("x")).flip(anyBoolean(), any(), nullable(String.class))` | `isEmpty()` | `[]` — matches (bare `any()`, `nullable(...)`, and `anyBoolean()` are all deliberately-unflagged shapes per the class's own exemption list) |
| 4. Unclosable `never().description("x".save(...)` | `containsExactly(UNBALANCED)` | `[<UNBALANCED>]` — matches |

For case 1, I also confirmed (by re-tracing with the **old** `NEVER_VERIFY` pattern, which required
`never()` to be followed immediately by verify's own closing `)`) that reverting the widening makes
`v.find()` match **nothing at all** for this input, since the literal text has `never().description(` where
the old pattern demanded `never())`. That reproduces the author's claimed mutant result ("delete the
description-skip block → 1 red, `Expecting actual: []`") by construction, without needing to run Maven — so
cases 1–4 are genuine positive controls, not vacuous assertions that would pass regardless of whether the
widening exists.

**Does the runtime-built-paren change to the pre-existing snippet weaken it?**
```
- assertThat(findOffenders("verify(repo, never()).save(" + anyStr + ";"))
+ assertThat(findOffenders("verify" + lp + "repo, never" + lp + rp + rp + ".save" + lp + anyStr + ";"))
```
with `lp = String.valueOf((char) 40)` (`(`) and `rp = String.valueOf((char) 41)` (`)`). Expanding the
right-hand side character-by-character reconstructs **exactly** the original literal string
`"verify(repo, never()).save(" + anyStr + ";"` — same characters, same concatenation boundaries, just built
from `char` codes instead of written as literal parens. The runtime value passed to `findOffenders` is
therefore unchanged; the assertion still pins precisely what it pinned before ("an unclosable span must be
REPORTED, not silently skipped"). The only effect of the rewrite is on the **source file's own literal
text** (no literal `)` character sits in this line anymore for the file's self-scan to trip over) — which
is exactly the stated reason (avoiding the ~450-line coincidental self-scan closure described in
`p4-rail-fix.md`). **No weakening.**

### B.4 — Size

`git diff --numstat 754ff476 0cd17825` for `NeverMatcherNullBlindnessArchTest.java` alone: **83 insertions,
10 deletions = 93 changed lines.** `p4-rail-fix.md` states "89 changed lines in the rail" —
**[LOW] off by 4 lines from the actual git diff numstat** (93, not 89). This does not change the
qualitative conclusion: 93 is still over the ~60-line "stop, it's its own ticket" guideline either way.

On the substantive question — is this a widen-in-place or a rewrite — I agree with the author's own
characterization: the core lexer (`spanEnd`, `stripComments`), the offender/primitive matcher patterns
(`REFERENCE_NULL_BLIND`, `PRIMITIVE_CAPABLE`), and the tree-wide floors are all untouched. What's new is one
regex split into three (`NEVER_VERIFY` narrowed + two new small patterns), one ~12-line helper
(`methodArgsOpen`), six call-site lines across three scan loops changed identically, four new self-test
assertions plus their `q`/`lp`/`rp` runtime-building preamble, and a substantial javadoc expansion (the
majority of the 93-line delta). That is a widening of one detection path with correspondingly-updated
documentation and tests, not a rewrite of the class — the "not a rewrite" judgment holds, even though the
line count itself is mis-stated by 4.

### B.5 — Corrected javadoc claim: 0 → 2 non-identifier-mock sites

Read `src/test/java/net/aim_ai/wms/schedulejob/SchedulingReconcileIdempotencyUnitTest.java` directly:

- `:391`–`:398` (`assertNothingWasCancelled`): `verify(issuedFutures.get(i), never().description(…)).cancel(anyBoolean());`
- `:696`–`:701`: `verify(bootFutures.get(i), never().description(…)).cancel(anyBoolean());`

Both confirmed:
1. The mock reference is `issuedFutures.get(i)` / `bootFutures.get(i)` — a method-call expression, not a
   bare identifier, so `NEVER_VERIFY`'s `\w+` for the mock position never matches either site regardless of
   the `.description(...)` widening. Correctly classified as the pre-existing "non-identifier mock" gap, not
   a new miss.
2. Both are `.cancel(anyBoolean())` on `java.util.concurrent.Future<?>.cancel(boolean)` — a **primitive**
   `boolean` parameter, so `anyBoolean()` is the compliant, non-null-blind form (matches the file's own
   documented rule that primitive-capable matchers on a primitive parameter are exempt on purpose). The
   corrected javadoc claim ("population 0 → 2, both compliant") is accurate at both cited lines.

**[LOW] Finding 2 — redundant re-scan on the unclosable-description path.** In `methodArgsOpen`, when the
description cannot be closed, `spanEnd(src, d.end() - 1)` is called and returns `< 0`, and the method
returns `d.end() - 1`. Every one of the three call sites then immediately calls `spanEnd(src, open)` again
with that same index, re-running the identical (deterministic, so identically-failing) O(n) scan a second
time before falling into the `<UNBALANCED>` branch. No correctness impact — `spanEnd`'s cost is bounded by
file length either way, and file lengths here are small — purely a style/efficiency nit. Confidence: HIGH
(directly readable from the diff at `:96`–`:106` and the three call sites `:224`–`:226`, `:415`–`:416`,
`:664`–`:666`). Not worth its own ticket; a one-line comment or minor restructuring (have `methodArgsOpen`
return the already-computed failure sentinel so the caller doesn't recompute) would close it if anyone is
already in this method for another reason.

## Check C — `SourceContainerGuardUnitTest` import change

```java
+import org.springframework.data.rest.core.annotation.RestResource;
...
-            org.springframework.data.rest.core.annotation.RestResource rr = UnitloadRepository.class
+            RestResource rr = UnitloadRepository.class
                 .getMethod("findParcelGuardViewById", Long.class)
-                .getAnnotation(org.springframework.data.rest.core.annotation.RestResource.class);
+                .getAnnotation(RestResource.class);
```
Pure import-and-simplify: the two inline FQN usages are replaced by an import plus the simple name, with no
change to the annotation being looked up, the method being reflected on, or the assertion below it
(`assertThat(rr).as(...).isNotNull()`, unchanged). This is exactly the p4 LOW ("Inline fully-qualified
`RestResource` type instead of an import") folded in as claimed, and it is trivial as described.

**Verdict: no issues. Confirmed trivial.**

## Positive observations

- `14786f9d` is a clean, minimal, correctly-scoped rebase fix — one line, no assertion drift, and it follows
  the exact precedent SBDEV-3442 set for its own sibling fixture rather than inventing a new shape.
- The `0cd17825` rail widening correctly closes the 18-site `.description()` blind spot for every shape I
  could construct except the (dormant, undocumented-either-way) text-block case — including the genuinely
  tricky ones: a `)` living inside a string, a multi-line `+`-concatenation, an escaped quote, and nested
  parens via `String.format(...)`, all handled correctly by reusing the existing paren-depth lexer rather
  than writing a second, weaker regex.
- The self-scan hardening (building the two deliberately-unclosable snippets' parens from `lp`/`rp`/`q` at
  runtime) is a real, well-reasoned fix to a real problem (a snippet's span closing ~450 lines away "by
  luck" in this file's own self-scan) — not cosmetic.
- The corrected non-identifier-mock population claim (0 → 2) is accurate at both cited lines, and the author
  did the harder, less self-serving thing of finding and reporting a mistake in their *own* rule's javadoc
  rather than leaving a stale "population 0" claim standing.

## Recommendation

**APPROVE.** No CRITICAL or HIGH finding at HIGH confidence in either commit. The one MEDIUM finding
(Finding 1: text-block descriptions can silently defeat the widened rail) is a real, reproduced gap, but it
is dormant against everything the suite runs today, confined to test-only rail code, and strictly additive
in risk terms — this commit still moves real coverage from 0 of 18 to 16 of 18 real sites with zero
regressions on anything that exists in the tree now. Recommend a fast follow-up (either harden `spanEnd` for
`"""` text blocks or document the limitation next to the class's other listed exemptions) rather than
blocking this commit on it. The two LOW findings (the 89-vs-93 line-count mismatch in the write-up; the
redundant re-scan on the unclosable-description path) are cosmetic and need no action before landing.
