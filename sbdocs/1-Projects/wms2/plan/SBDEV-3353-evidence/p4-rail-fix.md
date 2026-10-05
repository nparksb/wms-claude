# SBDEV-3353 — p4 rail fix + SBDEV-3442 rebase fixture fix

Worktree `.claude/worktrees/wms2-api/SBDEV-3353`, branch `bugfix/SBDEV-3353-refuse-move-stock-out-of-parcel`.
Two commits on top of `754ff476`. **Not pushed.**

| SHA | Subject |
|---|---|
| `14786f9d` | SBDEV-3353: rebase onto SBDEV-3442 — ParcelSourceStockMove fixtures stub findByLabelidForUpdate |
| `0cd17825` | SBDEV-3353: NeverMatcherNullBlindnessArchTest sees never().description(...) chains |

Both commits change test code only. `src/main` was never modified, apart from one mutant on a scratch copy that was restored and checked with `cmp` (`git status` clean).

## 1. The 7 reds from the rebase (commit `14786f9d`)

**Cause.** SBDEV-3442 (`45433631`) changed `MobileMoveUnitloadService.scanDestination:336` to `findByLabelidForUpdate`. `Sbdev3353ParcelSourceStockMove.arrive()` still stubbed `findByLabelid("PKG-0101")`, so all 7 cases threw `EntityNotFoundException: UnitLoad not found by labelid: PKG-0101`.

**Fix.** One line (`MobileMoveUnitloadServiceUnitTest.java:1848`): the stub now uses `findByLabelidForUpdate("PKG-0101")`. This is the same substitution SBDEV-3442 made in its sibling fixture (`:1449`). No assertion changed.

| Check | Result |
|---|---|
| Nested class after the fix | 7/0/0/0: 3 refusals carry the parcel key, and the 4 Case/Default controls move stock |
| **Mutant A**: delete `SourceContainerGuard.assertNotParcel(...)` at `MobileMoveUnitloadService:670` (scratch copy, EXIT-trap restore, `cmp` verified) | **3 red, 0 error**: the 3 refusals fail with `a Move Unit Load stock move out of a Package must be refused with key 'transferStockSourceIsParcel' — no SBDEV-3353 refusal was raised`. The 4 controls stay green. The fixtures do reach the guard. |
| **Probe B (same instance)**: the FOR UPDATE stub returns a *Case*-typed copy while `findById(SOURCE_ID)` still returns the Package | **3 red** with the same message. The guard reads the instance returned by the FOR UPDATE read. `transferStock(sourceUnitLoad, …)` receives the `:336` variable, and the guard at `:670` runs before the `:683` `findById` re-read. |

## 2. The rail fix (commit `0cd17825`)

### What changed in `NeverMatcherNullBlindnessArchTest`

- `NEVER_VERIFY` now ends at `never()`. It used to include `\)\s*\.\s*\w+\s*\(`, and that demanded verify's `)` right after `never()`.
- New `methodArgsOpen(src, afterNever)` walks the tail using two anchored patterns: `DESCRIPTION_CALL` (optional `.description(`) and `VERIFIED_CALL` (`).method(`), matched with `region()` + `lookingAt()`. The description body is skipped with the existing `spanEnd` lexer rather than a regex, so string and char literals are honoured. A `)` inside the description, or a concatenation spanning lines, cannot end it early. If the description cannot be closed, the method returns the description's own `(`. The caller's `spanEnd` then fails on that paren and the site is reported as `<UNBALANCED>` instead of being dropped.
- All three scan loops (main rule, `findOffenders`, primitive inventory) use `open = methodArgsOpen(...)` and `substring(open + 1, end)`. Plain `never()` spans behave exactly as before.
- Javadoc:
  - The `NEVER_VERIFY` doc records the old triple-silent gap and the new shape.
  - The class "Scope" section lists `never().description(<expr>)` as covered.
  - The "population 0" claim for non-identifier mocks was stale and is corrected: there are 2 sites, see below.
- Self-scan hardening. The rail's two deliberately unclosable snippets (the pre-existing `<UNBALANCED>` case and my new one) now build their parens at runtime from `lp`/`rp`/`q`, the same way the matcher names are built. Measured: written literally, the old one's span in the file-level self-scan closed about 450 lines later inside `stripComments`, by chance. Adding the new cases shifted where it closed, and the main rule went red on this file (`NeverMatcherNullBlindnessArchTest:316` in `unbalanced`). This was found with a Python port of the lexer and confirmed by the Maven run.

Size: 89 changed lines in the rail. That is 54 non-comment lines, of which about 20 are the new rail assertions and the rest is javadoc and comments. The detection-logic change itself is about 30 lines (pattern, two patterns, a 12-line helper, 6 loop lines). It is over the ~60 guideline in raw lines. I judged it not a rewrite, since the lexer, the matchers, the floors and the inventory are all untouched, but I am flagging it here.

### Positive control and mutants

Four cases were added to `detectorFiresOnTheMeasuredHistoricalShapes`:
1. `verify(repo, never().description("stop) here")).save(anyString())` returns `[anyString()]`. The `)` sits inside the description.
2. A multi-line `description("a " + reason + "(b)")` followed by `.save(any(Unitload.class))` on the next line returns `[any(Unitload.class)]`.
3. The compliant `never().description("x")).flip(anyBoolean(), any(), nullable(String.class))` returns empty.
4. An unclosable `never().description("x".save(anyString());` returns `[<UNBALANCED>]`.

| Mutant | Result |
|---|---|
| Delete the description-skip block in `methodArgsOpen` (a revert of the widening) | **1 red**: `detectorFiresOnTheMeasuredHistoricalShapes` fails on `[a never().description(...) chain must be scanned — including a ')' inside the description string, which a regex tail would stop at] Expecting actual: []` |
| Replace the `spanEnd` skip with "skip to the first `)`", i.e. a naive regex tail | **1 red**, same attributable message |

Both mutants were applied to scratch copies and restored with `cmp`.

### What the widened rail found across the 18 sites

A Python port of the lexer showed that 16 of the 18 sites now open a span. Tree-wide closed spans went from 1203 to 1221: those 16 sites plus 2 of the rail's own snippets. The Java main rule and the primitive-inventory test are both green after the change, so **no site was flagged and no inventory count moved**.

| Class | Sites | Verified call(s) | Verdict |
|---|---|---|---|
| StockunitServiceParcelSourceRefusalUnitTest | 6 (`:620 :622 :790 :796 :801 :804`) | `save(any())`, `flush()`, `findById(STOCK_UNIT_ID)`, `findById(SOURCE_UL_ID)`, `findAllById(any())` ×2 | clean: bare `any()` or a constant, no primitive-capable matcher |
| SourceContainerGuardUnitTest | 1 (`:212`) | `findById(any())` | clean |
| CancellationReversalServiceUnitTest | 1 (`:1092`) | `findById(any())` | clean |
| StaleClubBatchCleanupJobUnitTest | 5 (`:180 :222 :299 :320 :445`) | `tryLock(JOB, 7L)`, `tryLock(JOB, 3L)`, `unlock(JOB, 7L)`, `tryLock(JOB)`, `tryLock(JOB, overflowingId)` | clean: literals only, no matcher |
| AdvisoryLockServicePerTenantLockUnitTest | 2 (`:92 :184`) | `close()`, `prepareStatement("SELECT pg_advisory_unlock(?, ?)")` | clean. The `)` inside the SQL string is handled by the lexer. |
| SchedulingReconcileIdempotencyUnitTest | 1 scanned (`:615`, `cancel(true)`), clean. **2 still outside the scan** (`:393`, `:697`) | `verify(issuedFutures.get(i), …)` / `verify(bootFutures.get(i), …)`, both `.cancel(anyBoolean())` | These are not a description gap: they hit the documented **non-identifier mock** gap. Both are compliant, because `Future.cancel(boolean)` is a primitive and `anyBoolean()` is the required form. The javadoc now records this population as 2 (measured) rather than 0. The only other non-identifier `verify(…, never())` sites in the tree are 2 `MockedStatic` lambdas in `OmsNotificationServiceUnitTest`, which the javadoc already lists. |

**Real defects: 0. False positives: 0.** No test call site was changed, and `PRIMITIVE_MATCHER_INVENTORY` needed no bump because none of the 16 newly scanned spans holds a primitive-capable matcher.

### p4 LOW, folded in

`SourceContainerGuardUnitTest` now imports `org.springframework.data.rest.core.annotation.RestResource` and uses the simple name at `:258` and `:260`.

## 3. Verification

| Run | Result |
|---|---|
| `-Dtest='NeverMatcherNullBlindnessArchTest,SourceContainerGuardUnitTest,MobileMoveUnitloadServiceUnitTest*' -Dsurefire.failIfNoSpecifiedTests=false` | 86/0/0/0. Rail 4/0/0/0, SourceContainerGuardUnitTest 16/0/0/0, `$Sbdev3353ParcelSourceStockMove` 7/0/0/0. |
| Full `mvn -o clean test` at `0cd17825` | **run=7116 fail=0 err=0 skip=1**. The orchestrator's run at `754ff476` was 7116/3/4/1, and the 7 are now fixed. The total did not move because the 4 new rail cases are assertions inside an existing test method. Working tree clean afterwards. |

Every Maven command waited first until no `surefire`, `failsafe` or `plexus-classworlds` JVM from any worktree was running. A concurrent SBDEV-3493 `clean verify` was active when I started.

## Follow-up after p5-review.md (orchestrator, 2026-09-24)

- **p5 MEDIUM (text blocks): fixed.** It wasn't specific to `.description`. Neither lexer (`spanEnd`, `stripComments`) knew Java text blocks, and about 10 test files use them. A new `skipTextBlock` helper is used by both. The `TEXT_BLOCK` constant is spelled with escapes, so the rail's own source never contains three quotes in a row.
  - Two new self-test cases, built at runtime: an odd-quote text-block description, and the same followed by a trailing `// … (` comment.
  - Mutants: removing the `spanEnd` branch reddens only the first case; removing the `stripComments` branch reddens only the second. The first draft had only the first case, and the `stripComments` mutant SURVIVED it, which is why the second case exists.
- **p5 LOW (line count): corrected.** The rail diff in `0cd17825` is 83+10 = 93 lines, not 89.
- **p5 LOW (redundant `spanEnd`): left, with a reason.** `methodArgsOpen` computes `spanEnd` internally for the unclosable-description case, and callers compute it again. It has no correctness or measurable cost impact (a test-time scan of the source tree). Removing it would change `methodArgsOpen`'s return contract on three call sites of a rail that was just widened. Not worth the risk for a micro-optimisation.
- **Correction from p6-review.md:** removing the `spanEnd` text-block branch kills **both** new cases, not "only the first". Removing the `stripComments` branch kills only the second. Both assertions are non-vacuous. p6 also ran an A/B tree scan (575 files, `neverSpans=1222`, 0 offenders, 0 unbalanced, identical with and without the fix), confirming the gap was latent. p6's one Low (a stale class javadoc still calling text blocks "a known lexer gap") is fixed in the follow-up comment commit.
