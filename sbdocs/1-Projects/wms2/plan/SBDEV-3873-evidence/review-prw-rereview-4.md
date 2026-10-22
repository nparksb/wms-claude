head: b9c870d

# SBDEV-3873 PR-W — re-review 4 (scoped: b9c870d vs 35555dc, L-F)

Reviewer: independent code-reviewer lane (not the author). Read-only.

## Scope check
- `b9c870d^` = `35555dc`. One file changed: `test/store/noSdrPatchOnAdviceCyclecount.spec.js` (+30/−5). Test-only, no production code. Worktree clean.
- Changes: `targetPath` rewritten, new `braceDepth` helper, four keying controls. Nothing else.

## L-F resolution
| L-F part | Resolved? | Evidence |
|---|---|---|
| `${…}` closing `}` ended the `url:` capture | Yes | Neutralisation (`${…}` → `*`) now runs before extraction. ``url: `${base}/client/${id}` `` keys `/client/` (new control, line 295). |
| first `url:` anywhere won, including body-nested | Yes for the options-object form | Smallest brace depth wins, ties → last. Controls 296–298 cover nested-before, nested-before + variable, nested-after. |
| Add the two measured inputs as controls | Yes | Lines 295, 296 (+ two extra). |

- `npx jest test/store/noSdrPatchOnAdviceCyclecount.spec.js`: 55/55 pass.
- Real-tree census unchanged: "the PATCH call-site census is exactly the known set" is green against the unchanged `KNOWN_PATCH_CALLS` (`store/admin/shippers.js` `/client/`, `store/common/order.js` `/customerorder/`).
- SDR detection (`findSdrPatches`) does not use `targetPath`, so it is unaffected.
- Author's LF1–LF3 mutants line up with the controls they claim to kill (I reasoned about each against the diff; I did not re-run them).

## Findings

### High / Medium
None.

### Low

**L-G. The `url` key regex also matches a member access `.url`, so a positional call whose URL expression ends in `x.url` before `,`/`}` now keys `<dynamic>` (regression vs 35555dc).** Confidence: HIGH (measured).
File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js:145` — `/\burl\s*(?::\s*([^,}\n]*)|(?=\s*[,}]))/g`
Measured old → new:
- `('/client/' + obj.url, body)`: `/client/` → `<dynamic>`
- `(this.url, { note: '/x/' })`: `/x/` → `<dynamic>` (accidentally better)
At 35555dc the shorthand test required `[{,]` before `url`; the new combined regex dropped that anchor, so `\b` after `.` qualifies. No PATCH call in the real tree has this shape (`git grep '[.]url\s*[,}]'` hits only non-PATCH plugin code), and the call is still counted, so there is no silent miss. The only effect is a less specific census key.
Fix: anchor the key to object-key position, e.g. `/(?:^|[{,]\s*)url\s*(?::\s*([^,}\n]*)|(?=\s*[,}]))/g` (or `(?<![.\w$])url`), and add `('/client/' + obj.url, body)` → `/client/` as a control.

**L-H. The docstring "a `url` nested in the body loses" only holds for the options-object form. In the positional form the body object is itself depth 1, so its `url:` still wins.** Confidence: HIGH (measured), pre-existing.
File: `test/store/noSdrPatchOnAdviceCyclecount.spec.js:137-141`
`('/client/' + id, { url: '/x/' })` keys `/x/` at both 35555dc and b9c870d. This is not a regression, but the new comment overstates the guarantee. Not in the tree, and there is no silent miss.
Fix: either make depth-0 positional text win (if the call text has a non-`url` literal at depth 0 before the first `{`, prefer it), or narrow the comment to "in an options object (`$axios({ … })`/`$request`), a `url` nested in the body loses".

### Not findings (checked)
- Braces inside string literals (`url: '/a{b'`) skew `braceDepth` uniformly for later keys. Measured: it still picks the top-level `url:`. It is fine.
- A nested `${fn({a:1})}` (a `}` inside an interpolation) gives `<dynamic>` both before and after. This is pre-existing and documented in the header as a known desync.
- `url: a ? b.url : '/client/'` keys `/client/` both before and after.

## Verdict
**APPROVE.** L-F is fixed, the real-tree census is unchanged, and the change is confined to the spec. There are two new Lows, both census-keying refinements with no silent-miss path. L-G is a small regression introduced by this commit. Per house rule, fix both in the same pass.

Counts: CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 2 (L-G new regression, L-H pre-existing/doc).
