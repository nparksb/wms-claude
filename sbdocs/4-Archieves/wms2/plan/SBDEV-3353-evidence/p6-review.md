head: 744f6d6c

# Code Review — SBDEV-3353 744f6d6c (wms2-api)

**Commit:** `744f6d6c` "NeverMatcherNullBlindnessArchTest lexers skip Java text blocks"
**File:** `src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java` (test-only, +41/-2)
**Reviewer:** independent pass (code-reviewer agent), separate from authoring session. Tree: `.claude/worktrees/wms2-api/SBDEV-3353-review`, detached at `744f6d6c`.

## Method

- Read the full diff (`git show 744f6d6c`) plus the surrounding class (methodArgsOpen, findOffenders, spanEnd, stripComments, skipTextBlock, both `@Test` methods) to see how the new code is actually wired in, not just the hunk.
- Ran the real test class: `mvn -o test -Dtest=NeverMatcherNullBlindnessArchTest -Dsurefire.failIfNoSpecifiedTests=false` → **Tests run: 4, Failures: 0, Errors: 0** (exit 0). `pgrep -fl "surefire|failsafe"` showed nothing running before I started.
- `mcp__…__lsp_diagnostics` on the file failed to start the language server (exit code 1) — no JDK 21 on this machine (`sdk list java` shows only `25-open` installed), so jdtls couldn't attach. Treated the successful Maven compile+test run as the stronger, already-obtained evidence for this file; noting the LSP gap rather than silently skipping the check.
- Built a byte-for-byte scratch replica of `TEXT_BLOCK`/`skipTextBlock`/`spanEnd`/`stripComments`/`methodArgsOpen`/`findOffenders` (copy-paste from the reviewed file) in the scratchpad, per the "standalone replay" instruction, to run adversarial probes and mutants without touching the reviewed tree.
- Built a second scratch harness (`TreeScan.java`) that walks the **real** `src/test/java` tree with a toggle for text-block-awareness on/off, to A/B the actual production lexer against the live codebase (isolates only the one variable this commit changed).

## Findings

### [LOW] Stale class-level javadoc still describes the bug this commit fixes
**File:** `src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java:106-110`
**Confidence:** HIGH

The class javadoc still reads:

> "**Text blocks are a known lexer gap.** `stripComments` does not understand `"""`, so a text block containing an odd number of `"` desynchronises it for the rest of that file and real `//` comments below would survive into the scan. Measured: 8 files use text blocks, all with even parity... If a future text block reds this rule on a commented-out example, fix the lexer; do not exempt the file."

Confirmed via `git show 744f6d6c^:...` that this paragraph is **pre-existing**, untouched by this commit — and this commit is exactly "fix the lexer." It is now false: the lexer does understand `"""` as of this commit. This is also the sole hit for `grep -c '"""'` in the file (see the self-scan finding below) — harmless to the scanner (it's inside a `/** */` block comment, which `stripComments` swallows wholesale without inspecting content, so it does not desync anything), but it will mislead the next reader into thinking the gap is still open and possibly re-doing this work or writing around a bug that no longer exists.
**Fix:** Replace the paragraph with a short note that the gap was closed by SBDEV-3353 p5 (`skipTextBlock`), or delete it now that `REFERENCE_NULL_BLIND`/lexer coverage includes text blocks.

### [INFO] The "removes only its own case" framing is slightly stronger than what the code actually does — not a defect
**Confidence:** HIGH (empirically measured, not inferred)

I copied the exact `spanEnd`/`stripComments`/`skipTextBlock` production code into a scratch harness and ran two mutants against the two new assertions (lines 364-373):

| Mutant | case1 (odd-quote description, spanEnd-targeting) | case2 (text block + trailing comment, stripComments-targeting) |
|---|---|---|
| baseline (both branches present) | PASS | PASS |
| A: remove `spanEnd`'s text-block branch | **FAIL** | **FAIL** |
| B: remove `stripComments`'s text-block branch | PASS | **FAIL** |

Removing `spanEnd`'s branch kills **both** assertions, not "only case 1" — structurally unsurprising, since `methodArgsOpen` calls `spanEnd` on the `.description(...)` span for both snippets, so both need it. Removing `stripComments`'s branch kills only case2 and leaves case1 green, which matches the commit message's own (more careful) parenthetical: *"the stripComments mutant survived the first case alone."* Net effect: both new assertions are demonstrably non-vacuous — each is killed by at least one real mutant of the code it's meant to protect — so the rail itself is sound; only the looser paraphrase ("reddens only case 1") overstates precision. Not blocking, just correcting the record for whoever reads this later.

### [INFO] No behavioral change on the live tree today — confirmed, not just claimed
**Confidence:** HIGH

Built `TreeScan.java`, an exact copy of the production `NEVER_VERIFY`/`DESCRIPTION_CALL`/`VERIFIED_CALL`/`REFERENCE_NULL_BLIND`/`methodArgsOpen`/`spanEnd`/`stripComments`/`skipTextBlock`, with one boolean flag gating whether the two lexers take the new text-block branch. Ran it twice over the live `src/test/java` (575 files, same tree both times — isolates the lexer as the only variable):

```
aware=false  scanned=575  neverSpans=1222  offenders=0  unbalanced=0
aware=true   scanned=575  neverSpans=1222  offenders=0  unbalanced=0
```

Identical in every field. This corroborates the pre-existing (now stale, see above) javadoc's own measurement that the 8-11 files carrying text blocks in this tree have even quote parity, so the bug was latent, not live — and confirms the fix doesn't silently move `neverSpans`/`unbalanced` counts against the hardcoded floors (`isGreaterThan(300)`/`isGreaterThan(400)` at lines ~249-257, unmodified by this commit and still comfortably clear at 575/1222). Of the ~10 files that `grep -l '"""'` turns up, only `FileImportControllerUnitTest.java` combines a text block with `never()`, and its `never()` sites all use bare `any()` already (compliant either way), so this file could not have exercised the bug regardless.

### Check 1 — is `skipTextBlock` correct for real Java text blocks? PASS (empirically probed)

Reasoned through, then verified with an adversarial scratch harness (8 probes against the real `spanEnd`):

- **Escaped `\"""` inside a block:** the backslash-consumes-2-chars rule (`j += 2`) eats the backslash + the first of the following run of quotes, so an escaped quote correctly cannot contribute to a 3-quote closing run — matches real javac (escape processing is delimiter-search-visible, not just content-visible).
- **A block containing a lone `"` and a lone `""`:** neither is 3-in-a-row, so `startsWith(TEXT_BLOCK, j)` correctly stays false and they pass through as ordinary content. Verified (`odd-quote-in-block` probe): closes exactly at the real end, ignoring the internal `)` too.
- **`\` line continuation:** treated identically to any other escape (`j += 2`); since it's a line lexer this class doesn't need to interpret it, and it can't accidentally break the delimiter search since it just advances two chars.
- **Content ending in `"` right before the closing `"""` (unescaped, i.e. 4 raw quotes: `""""`):** probe `4-quotes-unescaped` returns `-1` (UNBALANCED) for the enclosing call — because the first 3 of the 4 quotes are consumed as the closing delimiter (matches real javac's own greedy left-to-right rule for this exact ambiguous shape, which is itself a compile error in real Java), leaving a lone stray `"` that opens an unterminated ordinary string and correctly desyncs the rest. This is the *correct* behavior for an input shape that is itself invalid/ambiguous in real Java — the tool degrades the same way the real compiler would, and (per the class's own design) reports it as `<UNBALANCED>` rather than silently mis-scanning.
- **The escaped form of the same case** (`\"` then real closing `"""`, i.e. 5 chars after content): probe `escaped-adjacent-quote` closes cleanly at the true end — the form real Java actually requires for this content.
- **Unterminated block:** probe returns `-1`, matching the documented "runs to the end, like an unterminated string" contract, and matching `noNeverVerifyUsesAReferenceTypedMatcher`'s design of surfacing `<UNBALANCED>` rather than swallowing the site.

No defects found in this method.

### Check 2 — can the new branch misfire on non-text-block code? PASS

- **Char literal `'"'`:** the outer dispatch is `if (c=='"' && startsWith(TEXT_BLOCK,i)) ... else if (c=='"' || c=='\'')`. A char literal's first character is `'`, not `"`, so the text-block branch is never entered for it; it falls straight to the pre-existing char/string branch, unaffected. Probe `char-lit-quote` confirms `verify('"').save(x)` closes correctly.
- **Char literal `'('`:** same reasoning; probe `char-lit-paren` confirms.
- **Order of checks:** the text-block check is `c=='"' && startsWith(...)`, checked *before* the plain `c=='"' || c=='\''` branch — it must be, since it's the more specific case (3 quotes vs. 1), and this was the actual pre-existing bug (the plain-string branch would previously always fire first on a text block's opening `"`, closing after only the first two quotes). Both lexers keep this ordering. Realistic Java source cannot produce 3 raw, un-escape-broken quote characters in a row except at an actual text-block delimiter or inside a comment (comments are consumed wholesale by their own branch before any inner content is re-examined) — confirmed empirically by the 575-file, zero-diff tree scan above, which is the strongest evidence against a misfire on this codebase's actual code.

### Check 3 — self-scan: PASS on mechanics, FLAGGED on staleness (see LOW finding above)

`grep -c '"""'` in the file returns exactly **1**, inside the javadoc paragraph flagged above — not in executable code, so it cannot desync the file's own scan (block comments are skipped as an opaque span, never fed back through the quote/text-block dispatch). Floor counts (`scanned`/`neverSpans`) are unaffected, per the tree-scan A/B above.

### Check 4 — mutants: see the INFO finding above (both real mutants kill at least one assertion; framing note only, not a defect).

### Check 5 — files that already carry text blocks: see the INFO finding above (`TreeScan.java` A/B, 575 files, identical before/after). No newly-flagged or newly-hidden site.

## Positive observations

- The fix is minimal and correctly scoped (one file, test-only, 43 lines) for a MEDIUM finding from p5.
- Both new rail assertions are non-vacuous by mutation (each is killed by a real removal of the code path it's meant to pin), and `containsExactly` (not `hasSize`) is used, consistent with this file's own established discipline against `<UNBALANCED>`-padding tautologies.
- `skipTextBlock`'s escape handling (`j += 2` on backslash) correctly makes the delimiter search escape-aware, matching real javac semantics for the genuinely tricky boundary case (quote content adjacent to the closing delimiter) — including reproducing the *same ambiguity* real Java has for the unescaped form, rather than inventing divergent behavior.
- The runtime-built `q3 = q+q+q` keeps the test file itself free of a live `"""`, consistent with the file's established pattern (`anyStr = "any"+"String()"`, etc.) of keeping rail fixtures out of reach of a mechanical grep-and-replace or the rule's own self-scan.

## Recommendation

**COMMENT.** No CRITICAL or HIGH issues, and no functional defect found in the lexer change itself after extensive adversarial probing (8 hand-built edge cases) and a controlled 575-file A/B scan of the live tree. One LOW-severity, HIGH-confidence documentation-staleness issue (the class javadoc still claims the fixed gap is open) should be cleaned up before or shortly after this merges, since it directly concerns the code this commit touches and will mislead the next reader. Safe to push; consider a fast follow-up (or amend, author's call) for the javadoc.
