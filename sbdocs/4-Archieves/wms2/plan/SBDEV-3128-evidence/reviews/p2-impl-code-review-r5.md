head: f632497483cf889a709fc43ce2b021e1f8e056c8

# SBDEV-3991 p2 impl code review, round 5 (scope: 5a0afa4..f632497)

Diff touches exactly three files: fixedLocation.vue (1 comment), util/boundDefaults.js (1 JSDoc), test/util/boundDefaults.spec.js (+4 lines, 1 test). No executable code changed.

## Per-finding status

- N6 (test pinning the SYSTEM_INVALID check): CLOSED.
  The new test `canResetBounds(fla({ boundsInherited: false, defaultSource: 'SYSTEM_INVALID' }))` keeps the fixture's 24/36/48, so only the source check can reject it.
  Mutation (in a copy under /tmp/r5, worktree untouched): `hasValidDefault` first clause `row.defaultSource !== 'SYSTEM_INVALID'` replaced with `true`.
  Result: exactly 1 failed, 35 passed. The failing test is the new N6 test. It fails for the right reason and nothing else depends on it.
  Unmutated: 36/36 pass in the worktree (jest, node 18.20.5).
- N7 (comments name hasValidDefault): CLOSED.
  - util/boundDefaults.js JSDoc: "requires a valid default (hasValidDefault: not SYSTEM_INVALID, and all three values present)" matches `hasValidDefault` (SYSTEM_INVALID check plus every() of min/hyst/max not null/undefined). Accurate. The retained parseLongOrDefault rationale is now correctly scoped to the SYSTEM_INVALID exclusion.
  - fixedLocation.vue resetConfirmText: "requires a valid default (hasValidDefault ...) so defaultBounds holds real values". Accurate; resetConfirmText is reached only via canResetBounds.

## New findings

None.

## Verdict

APPROVE. Both Lows closed, mutation-verified; no behavior change; no regressions in the spec.
