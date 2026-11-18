head: 9432c12

# SBDEV-3991 (SBDEV-3128 P2, wms2-web-ui): implementation code review, round 3 (scoped)

- Scope: only `e61f9ab..9432c12` (4 files, +62/-12), worktree `.claude/worktrees/wms2-web-ui/SBDEV-3991`.
- Server claims checked against `v2/wms2-api` `origin/develop` @ `09683d18`.
- Tests (Node 18.20.5): the 3 specs give **78/78 passing** with `--coverage=false`. `boundDefaultsUi.spec.js` alone with coverage ON (jest.config `collectCoverage: true`) gives **36/36**, and all 6 template-wiring pins pass under instrumentation.
- Mutations were run on a `git archive 9432c12` copy in the session scratchpad (node_modules symlinked). The worktree was not modified (`git status --short` is empty), and no checkout, restore or stash was run.

## Per-finding status

| r2 finding | Status | Evidence |
|---|---|---|
| N1 (Medium): reset offered under SYSTEM_INVALID | **RESOLVED** | `util/boundDefaults.js:130-132` `canResetBounds` now requires `row.defaultSource !== 'SYSTEM_INVALID'`. The javadoc (`:124-128`) now states the real server behaviour, which matches `SyspropService.parseLongOrDefault` and `FixLocationAssignmentService.systemDefaultBounds` ("a value Long.parseLong rejects still throws"). The spec was flipped to `false` for both Overridden and Inherited-out-of-date (`test/util/boundDefaults.spec.js:167-171`). The `'the built-in system default'` branch and its spec are gone. Mutation: dropping the guard → red. |
| N2 (Low): digit check after the 10^13 check | **RESOLVED** | `util/boundDefaults.js:84-89`: `significantDigits` now runs before `n >= UPPER_LIMIT`. The new spec `9999999999999.9999` → `/too many digits/` exists. Mutation: restoring the old order → red. `1e13` still gets "must be less than" (1 significant digit), so the F6 spec still holds. |
| N3 (Low): template wiring not pinned; `clearing` reset not asserted | **RESOLVED** | 6 source-scan pins plus `expect(scope.clearing).toBe(false)`. Every r2 gap mutation now goes red: the menu calls `resetBounds(item)` directly · OK only closes · the dialog Clear loses its `v-if`. Further mutations, also red: `:disabled="!canResetBounds(item)"` dropped · `clearing` not reset in `finally` · SL `@accept-confirm` → `clearDefaultsItem = null` · SL Set `v-if="isFlowbin(item)"` → `true` · chip `{{ item.boundsStatus }}` changed. The pins read the raw SFC, so coverage cannot disarm them (verified above). None can be met by accident, because each requires the specific handler and argument name. |

### `resetConfirmText` now assumes `defaultBounds` holds real values: are all paths gated?
Yes. `resetConfirmText` is rendered only in the reset `v-dialog` (`fixedLocation.vue:219`). That dialog is shown only while `resetBoundsItem !== null` (`:209`). `resetBoundsItem` is set only by `askResetBounds` (`:369-370`). `askResetBounds` has exactly one caller, the menu button at `:137`, which carries `:disabled="!canResetBounds(item)"`. A disabled Vuetify `v-btn` sets the native `disabled` attribute and does not emit click. No other file references `askResetBounds`, `resetConfirmText` or `resetBoundsItem`. The pin at the spec's "reset item opens the confirm" test protects this gate, and removing `:disabled` goes red.

Residual (theoretical): `defaultBoundsLine` (`util/boundDefaults.js:143-144`) also returns `'(system default invalid)'` when *any* triple value is null, whatever the source. If the server ever sent `LOCATION`/`SYSTEM` with a null value, the reset would be enabled and the confirm would read "…with (system default invalid)?". The server cannot send that today: LOCATION needs an all-non-null triple (the CHECK constraint plus `effectiveDefaultBounds`), and SYSTEM is emitted only after a successful parse. No change is needed. See N5 for an optional hardening.

## New findings

### N4 [Low, conf MEDIUM]: one pin depends on attribute order and adjacency, and a Prettier run breaks it
File: `test/components/masterData/location/boundDefaultsUi.spec.js` ("Fixed Locations: the reset item opens the confirm…").
```
expect(FL_T).toMatch(/:disabled="!canResetBounds\(item\)" @click="askResetBounds\(item\)"/)
```
Harmless edits that turn it red (on the scratch copy): swapping the two attributes; putting a line break between them; `v-on:click=` instead of `@click=`. Most importantly, running `prettier --write` on the 3 SFCs (the repo has `lintfix` and `lint:prettier` scripts, with printWidth at its default of 80) breaks **this pin and only this one**. The other 5 survive, because `[^>]*` / `[\s\S]` span newlines. In practice the risk is small: 222 `.vue` files already fail `prettier --check`, so nobody runs lintfix routinely. But when it does fail, it fails on formatting rather than behaviour.
Fix: match the whole tag and test the two attributes separately, e.g.
`const btn = FL_T.match(/<v-btn[^>]*askResetBounds\(item\)[^>]*>/); expect(btn).not.toBeNull(); expect(btn[0]).toMatch(/:disabled="!canResetBounds\(item\)"/)`.
The `@click=` vs `v-on:click=` spelling is acceptable to keep strict.

### N5 [Low, conf LOW]: optional hardening, so the reset gate does not rest only on `defaultSource`
File: `util/boundDefaults.js:130-132`.
`canResetBounds` checks `defaultSource` but not that the effective triple is present. `defaultBoundsLine` already treats "any null" as invalid. Aligning the two (e.g. `&& defaultBoundsLine(row) !== '(system default invalid)'`, or a shared `hasValidDefault(row)`) would make the comment at `fixedLocation.vue:374` true by construction rather than by server contract. Not reachable with the current server, so this is not a blocker.

## Storage Locations "Clear replenishment defaults" under an unparseable sysprop: note only, no UI change
Server (`FixLocationAssignmentService.updateLocationBoundDefaults`, origin/develop): `Bounds effective = clear ? systemDefaultBounds() : …` runs **unconditionally on clear**, even when the location has no Inherited assignment. With an unparseable `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_*` sysprop, every clear throws NFE. `LocationController.updateBoundDefaults` catches only `BusinessException`, so the result is a 500. The `@Transactional` rolls back, so nothing is half-written.

UI effect: `store/masterData/storageLocation.js:124-127` catches the rejection, logs, toasts `apiErrorReason(error) || GENERIC_ERROR` and returns false. The confirm stays open, `clearing` resets in `finally`, and there is no data harm. The UI **cannot** gate this the way it gates the reset. The Storage Locations row describes the location and carries no `defaultSource`. SYSTEM_INVALID is a tenant-wide sysprop state that appears only on Fixed Location rows, and detecting it here would need an extra fetch, which is out of proportion. The detail line ("…revert to the system default") is accurate whenever the clear can succeed.

Recommendation: no UI change. Add one line to the PR body (beside the conformance F3/F4/F5 notes) and attach this to the server ticket rather than the UI one: the server should either skip `systemDefaultBounds()` when `writeThroughInherited` has nothing to update, or turn the NFE into a `BusinessException` naming the bad sysprop, so the operator gets an actionable message instead of a generic 500. The same translation would also benefit reset and create. This is server scope (wms2-api), sub-T3, and belongs on the existing SBDEV-3128 / P1 ticket per the findings policy.

## Mutation summary (scratch copy of 9432c12)
Red, as expected (10): SYSTEM_INVALID guard dropped · digit/limit order reverted · menu → `resetBounds(item)` · OK only closes · `:disabled` canReset dropped · dialog Clear `v-if` dropped · `clearing` not cleared in finally · SL accept → null · SL Set `v-if` → true · chip text changed.
Red but should be green, which is brittleness (N4): attribute swap · newline between the attributes · `v-on:click` · `prettier --write`.

## Positive observations
- N1 was fixed the way r1-F8 originally proposed, and the javadoc now cites the real server contract rather than an assumed fallback.
- The N2 fix carries a comment explaining *why* the order matters (`Number()` rounding), so a later "tidy-up" is less likely to undo it.
- The pins read the raw SFC rather than the compiled render, so coverage instrumentation cannot disarm them. This was checked, not just claimed.
- The pins include a negative assertion (`not.toMatch(/@click="resetBounds\(item\)"/)`) on top of the positive ones.

## Verdict
**APPROVE.** N1, N2 and N3 are all RESOLVED, and each is protected by a mutation-verified test. No new defect was introduced. The `resetConfirmText` assumption holds on every path, since the only entry point is gated by `canResetBounds`. The new findings are N4 (Low, a brittle test pin) and N5 (Low/LOW-conf, optional hardening). Under the repo's "address Lows too" convention, N4 is a 2-line spec change worth folding in before the PR. N5 is optional. The Storage Locations clear under an unparseable sysprop needs a PR-body note and a server-side proposal, not a UI change.
