head: 5a0afa4

# SBDEV-3991 (wms2-web-ui) — p2 implementation code review, round 4 (scoped)

Scope: `git diff 9432c12..5a0afa4`, which touches 3 files: `util/boundDefaults.js`, `test/util/boundDefaults.spec.js` and `test/components/masterData/location/boundDefaultsUi.spec.js`. The evidence is the worktree `.claude/worktrees/wms2-web-ui/SBDEV-3991`, which was clean at review time. All mutations ran in a `git archive HEAD` copy in the scratchpad, so the worktree was never modified.

## Evidence
- Targeted suites (the 3 specs): **79 passed / 79**.
- Full jest suite (the scratchpad copy at HEAD) is green. A mutant run gave 2739/2739 (see N6).
- `eslint` on the 3 changed files exits 0.
- The `console.log` at `fixedLocation.vue:511` during the UI spec is outside the diff and existed before this commit.

## Prior findings

### N4 [Low]: brittle template pin — RESOLVED
The new pin pulls the whole `<v-btn …>` tag whose click handler is `askResetBounds(item)`, using `@click` or `v-on:click`. It then asserts `expect(tag).not.toBe('')` and checks `:disabled="!canResetBounds(item)"` inside that tag on its own.

Mutation and brittleness matrix, UI spec:

| Mutation | Result | Wanted |
|---|---|---|
| Swap the attribute order | green | green |
| Newline between the attributes + `v-on:click` | green | green (`[^>]*` spans newlines) |
| Rename the handler (no `askResetBounds` tag) | **red** | red: the not-vacuous guard works |
| Remove `:disabled` | **red** | red |
| Move `:disabled` onto the parent `<v-list-item>` | **red** | red: the attribute is pinned to the same tag |
| `@click="resetBounds(item)"` / `v-on:click=…` / `@click.stop=…` | **red** | red |

The pin cannot pass vacuously. If an attribute value before the handler ever contained a `>`, the tag match would fail and the test would go red (fail-closed), not pass silently.

### N5 [Low]: canResetBounds should share defaultBoundsLine's validity rule — RESOLVED
`hasValidDefault(row)` (`util/boundDefaults.js:136-139`) is now the single rule, and both `canResetBounds` (`:131`) and `defaultBoundsLine` (`:148`) use it.
- **No null deref.** `hasValidDefault` runs only after `hasProvenance(row)` returns true (`!!row && typeof row.boundsInherited === 'boolean'`), on both call paths, and `&&` short-circuits. So `row` is never null when it runs.
- **`defaultBoundsLine` output is unchanged.** The old condition was `SYSTEM_INVALID || some(null/undefined)`. The new one is `!(source !== SYSTEM_INVALID && every(non-null))`, which is the same thing by De Morgan's law. Valid rows still format `"24 / 36 / 48 (location|system)"`, and the existing tests for that are green.
- **The new test is mutation-verified.** Reverting `canResetBounds` to the source-only check turns `boundDefaults.spec.js` red (1 failed), on the case "disabled when the effective default is missing a value, whatever the source says (r3 N5)".
- `resetConfirmText` (`fixedLocation.vue:372-375`) now has a stronger guarantee: `defaultBounds` can never be `'(system default invalid)'` when the reset is reachable.

## New findings

### N6 [Low, conf HIGH]: the `defaultSource !== 'SYSTEM_INVALID'` clause in `hasValidDefault` is unprotected by any test
File: `util/boundDefaults.js:137`
```js
return row.defaultSource !== 'SYSTEM_INVALID'
  && [row.defaultMinAmount, row.defaultHysteresis, row.defaultMaxAmount].every(...)
```
Mutant: delete the source clause, leaving only the values check. Result: **the full suite stays green (2739/2739)**. Every SYSTEM_INVALID fixture (`boundDefaults.spec.js:168`, `:198`) also carries a null triple, so the values check alone already rejects it.
Impact: none under today's server contract. `ViewDtoService.putBoundsProvenance` (wms2-api SBDEV-3128 worktree, `ViewDtoService.java:953-955`) emits SYSTEM_INVALID only when `effective == null`, so the mutant behaves the same as the real code on real data. The risk is a future server change that sends SYSTEM_INVALID with fallback values. The UI would still block that (the clause exists), but no test would notice if someone "simplified" the clause away.
Fix (optional, 1 line): add `expect(canResetBounds(fla({ boundsInherited: false, defaultSource: 'SYSTEM_INVALID' }))).toBe(false)`. The `fla()` fixture keeps the 24/36/48 triple, so this pins the source clause by itself.

### N7 [Low, conf HIGH]: the comment's invariant is narrower than the code's
File: `components/masterData/location/fixedLocations/fixedLocation.vue:374` (outside the diff, but it describes the invariant this diff changed)
```js
// Only reachable through canResetBounds, which excludes SYSTEM_INVALID, so defaultBounds holds real values.
```
The guarantee now comes from `hasValidDefault` (no SYSTEM_INVALID **and** all three values present). The comment is still true, but incomplete. The `canResetBounds` JSDoc (`util/boundDefaults.js:124-129`) likewise explains only SYSTEM_INVALID.
Fix: reword to "…which requires a valid effective default (hasValidDefault), so defaultBounds holds real values." Cosmetic.

## Positive observations
- One validity rule, defined once and documented as "the same rule defaultBoundsLine uses". The refactor is the minimal one and the behaviour is unchanged.
- The pin's comment explains why it is shaped this way (r3 N4), and the `not.toBe('')` guard closes the vacuous-pass hole that regex pins usually have.
- The negative pin now also covers `v-on:click`.

## Verdict
**APPROVE.** N4 and N5 are RESOLVED, and both are mutation-verified. No regression was found. N6 and N7 are new Lows, and neither blocks. Under the repo's "address Lows too" convention, each is a one-line follow-up: a test for N6, a comment for N7.
