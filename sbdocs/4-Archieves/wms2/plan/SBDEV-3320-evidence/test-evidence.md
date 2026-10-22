# SBDEV-3320 — test evidence (measured, not asserted)

The conformance lane correctly flagged that the original baseline figure rested on my word with no
artifact behind it. These are measured runs; the logs are named for each.

## Baselines and results

| Run | Tree | Result |
|---|---|---|
| **`origin/develop` baseline** | detached worktree at `4c2ae57b` | **6498 tests, 0 failures, 0 errors, 1 skipped** — BUILD SUCCESS |
| **Branch, post-rebase** | `feature/SBDEV-3320-cart-unitload-mint` @ `a220be2a` | **6513 tests, 0 failures, 0 errors, 1 skipped** — BUILD SUCCESS |

**Reconciliation: 6498 + 15 = 6513.** The 15 is the number of `@Test` methods this branch adds
relative to develop, independently derived by the conformance lane
(`git show HEAD -- 'src/test/java/*' | grep -c '^+.*@Test'`). Both sides of that arithmetic are now
measured rather than claimed.

The 1 skipped test is `TenantPoolEndpointSecurityTest`, which is skipped on develop too and is not
touched by this diff.

## Superseded figures — recorded so the earlier numbers are not mistaken for current

An earlier baseline of **6479 / 3 failures** was captured against `6dc054e1`, the branch's original
base, *after* the TDD-gate tests were written — so it already contained 6 of the 15 tests, 3 of them
the intentional gate reds. That is why 6479 + 9 = 6488 was the pre-rebase result. All three figures
are consistent; only the last row of the table above describes the current tree.

`origin/develop` **moved during this session** (`6dc054e1` → `4c2ae57b`, 6 commits, including
SBDEV-3319 which edits `processPick` — the same method this ticket edits). The branch was rebased
and everything re-run; the pre-rebase numbers are kept here only to explain the arithmetic.

## Mutation testing

Seven mutants, each killed by exactly its own assertion, with a surviving control wherever the
change narrows rather than adds behaviour:

| # | Mutant | Killed by | Control that survived |
|---|---|---|---|
| M3 | cart attach moved BEFORE `transferUnitLoadToLocation` | D5 `InOrder` test | every other cart assertion stayed green |
| M4 | reuse loop disabled (always mint) | D6′ reuse test | — |
| M5 | `RAPID_PICKING` falls through to minting | D2 pin | — (this is what proved the pin is no longer vacuous) |
| M6 | Cart break removed from the transfer-order ascent | D10 Cart test | D10 Pallet control stayed green |
| M7 | Cart exemption removed from the hold guard | D9 Cart test | `throwsWhenUnitloadIsOnCarrier` stayed green |

M3 and M4 were re-verified after the `never()` matchers were widened for
`NeverMatcherNullBlindnessArchTest`, since widening a matcher can silently weaken an assertion.
Both still killed.

The conformance lane independently ran five of its own mutants (D1 flag flip, D3 gate inversion, D5
reorder, D9 guard revert, D10 break removal) in a throwaway worktree and reached the same verdict.

## Why the D5 test is an `InOrder` verify and not an end-state assertion

`transferUnitLoadToLocation` clears `carrierunitload_id` at `UnitloadBusinessService:268` — near the
END of a method spanning `:159–:279`, not in its opening lines. With `UnitloadBusinessService` mocked
the clear never actually runs, so both orderings produce an identical end state and an end-state
assertion cannot tell them apart. Only the call order distinguishes them.
