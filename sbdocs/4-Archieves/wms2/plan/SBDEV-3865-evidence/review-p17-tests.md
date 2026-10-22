---
head: 7fffc5739f519731ce12553f3b45922ae9748d56
ticket: SBDEV-3865
reviews: tip commit test(SBDEV-3865) answering L1, L2 of review-p17.md
verdict: APPROVE
---
# P17 test commit review (L1, L2)

Severity count: 0 Critical, 0 High, 0 Medium, 0 Low, 2 Info.

Scope: test-only diff to `MobilePickingServiceUnitTest.java` (+23 / -1).

## L2: closed
The assertion `.hasMessageContaining("assigned to user otheruser")` is on the Case 2 refusal test. Production throws
`"Parcel already assigned to user " + operator.getName()` (MobilePickingService.java ~:797) and the fixture's holder is named `otheruser`,
so it matches. No existing assertion was weakened: the diff changes only that one line; the `never()` verifications remain. The Case 3 sibling already pinned the same text.

## L1: closed, and it pins the invariant rather than the one mutant
Probe: detached worktree at the head sha, `mvn -o test -Dtest=MobilePickingServiceUnitTest -Djacoco.skip=true`. Base run is green (no failures reported).
Three orphan-refusing shapes, each applied alone, each reverted (probe worktree removed):

| Mutant | Result |
|---|---|
| M1 throw BusinessException("M1") when operator null and locked | RED at the test (`BusinessException M1`) |
| M2 widen guard to `operatorId != null OR locked` (user lookup) | RED (`EntityNotFound User not found by name: anonymous`) |
| M3 silently return false for orphan | RED (isTrue assertion) |

The author's orphanMUTANT is the same family as M2 plus a throw. Three distinct shapes (throw, lookup, quiet refusal) all fail, so it guards "orphan stays releasable and costs no caller lookup", not one string.

Non-vacuity: precondition sets `lockedtooperator=true` with `operatorId=null`, and asserts false afterwards, so the clear is observed (Pickingorder.setOperatorId clears the flag). The test deliberately does not mock `SecurityContextUtils`, so any caller lookup fails loudly (seen in M2) in addition to `verify(userRepository, never()).findByName(any())`.

## Strict-stubs hygiene: clean
This class has no `@MockitoSettings`, so STRICT_STUBS applies. All three stubs in the new test (`findByIdForUpdate`, `findByPickingorderId`, `save`) are consumed on the orphan path. No `lenient()`, no unused stubs, no unneeded `MockedStatic`. Full class passes at base (155 tests, 0 failures after reverting mutants).

## Info
- I1: the test title says "released" but the flow runs through Case 3 only because the position is STARTED (not picked). If the fixture's position state changed, the path would change; the `PROCESSABLE` assertion would flag it. No action.
- I2: the comment says "the job notes say it occurs"; fine as a pointer, but it ties the rationale to a document outside the repo. Optional: cite the SBDEV-3205 repository comment (`PickingorderRepository.java:98-113`) instead.

## Recommendation
APPROVE.
