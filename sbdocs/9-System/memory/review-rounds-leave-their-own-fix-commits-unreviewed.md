---
name: review-rounds-leave-their-own-fix-commits-unreviewed
description: "Every review round ends by producing a fix commit the round itself could not have seen. Run the lane unasked: it has found the worst remaining defect on 5 tickets, incl. all three phases of SBDEV-3410"
metadata:
  type: feedback
---

**The structure guarantees the gap.** A lane reviews commit N, finds things, you fix them in commit
N+1 — and N+1 ships unreviewed. Do it twice and half the branch has had no independent pass. On
**SBDEV-3398** Nam asked *"all the changes and fixes were reviewed?"* and the answer was no; the
second round found a High-adjacent Medium and two false claims of mine. On **SBDEV-3419** he asked
the identical question and the answer was no again — 3 of 6 commits, and the unreviewed set contained
**new production logic** (a `throw` replacing a lock) that no lane had ever seen.

**Why it matters more than it sounds:** the unreviewed commit is systematically the *riskiest* one.
It is written under the momentum of "just closing findings", it is the least rested, and its changes
are reactive rather than designed. On SBDEV-3419 that commit's production change turned out to be
*correct* while the **justification written beside it was false** — `findByIdForUpdate` returns the
already-managed instance (`@Transactional` + `open-in-view=false`, `@Lock` with no refresh hint), so
the "parcel_id may change between the unlocked read and the locked re-read" race it claimed to guard
is not expressible. A comment can be wrong in a way that outlives the code, and SBDEV-3418 had been
pointed at that exact block.

**How to apply.** After the last fix commit of a round, run one more pass **scoped to the fix commits
only** — not the whole branch again. Say in the prompt that these commits have never been reviewed
and that earlier lanes graded the code *before* their own findings were applied, or the lane will
assume the usual coverage. Prioritise by content, not by size: test-only and comment-only commits are
cheap to skim, but any fix commit carrying **production logic** deserves the same adversarial
treatment the original got. Two useful questions to hand it: *enumerate every way this branch can be
reached*, and *what did `origin/develop` do for each of those cases* — the second is what proved the
`throw` was not a regression.

## SBDEV-3410 made it three-for-three, and the finding is usually a CLAIM

Run on all three shipped phases of one ticket, the lane found the most serious remaining defect every
time — and none of them showed up as a red, because they are all "green test that grades nothing" or
"true-sounding statement that is false":

| phase | what only this lane found |
|---|---|
| P1 | the migration's guard was a **weakened copy** of a predicate already in `db/migration` (`V2.2.20`), dropping `indexprs IS NULL` and the `indnkeyatts` width pin — so a `UNIQUE (client_id, item_nr, lower(expr))` index passed the guard that exists to forbid exactly that |
| P2 | my fix for the lane's own M1 was **wrong in the same way as the original** (raw-SQL `CONCAT()` ignores NULLs, JPQL `CONCAT` renders as `\|\|` and propagates them), and a brand-new behavioural `equals` test was blind to a `==` mutant because its ids sat inside `java.lang.Long`'s cache |
| P3 | the new pin's whole non-vacuity story: a **dead assertion** carrying the non-vacuity claim (`getSearchResourceMappings` can never return null, verified in spring-data-rest-core 4.5.7 sources), plus a `WITHDRAWN` literal bound to nothing, so a rename passed vacuously |

**Two refinements from that run.** (1) Hand the lane the earlier reports so it reviews the DELTA
instead of re-deriving settled ground, and tell it *"assume a third defect is likely"* — it is a
different search than "check this diff". (2) When it finds a vacuous test, **mutation-check your own
fix before believing it**: the obvious mutant for P3's was renaming the repository method, which
breaks direct call sites and fails at COMPILE — a repo-wide break attributes nothing. The property
was "a stale literal is caught", so the mutant had to be the literal.

## 2026-09-23: five-for-five, and this time it got PAST THE PUSH

SBDEV-3418 and SBDEV-3458, same session, both **pushed and PR'd with an unreviewed tip commit**, and
Nam asked the same question a third time — *"Are the changes reviewed?"*. 3458 was the worse case: a
lane returned CHANGES REQUESTED on `8cb3d5b8`, the fix was **redesigned** in response (different
hooks, different transaction shape, different keys), and `dec515f0` went onto a PR having been read
by nobody. A redesign prompted by a review is the *least* covered code on the branch, not the most.

**The new lesson is about WHERE the gate sits.** Previous rounds caught this before shipping; here a
push checkpoint was printed, approved and executed while the tip was unreviewed, because the checklist
asked "is the suite green?" and never asked "has anything read the commit I am about to push?".

**So: the Phase 6 / ready-to-push block must carry a line naming the SHA each lane actually reviewed,
next to the tip SHA.** If they differ, that is a blocker in the block itself — not a footnote, and
not something to resolve after the push. Concretely:
`git log --oneline <last-reviewed-sha>..HEAD` must be empty, or the block says it is not and why.
Grep each lane's report header for the `head:` it recorded; do not assume a lane covered commits that
did not exist when it ran.

**Do not wait to be asked.** P1's own ticket comment declared this "now automatic, not on request" —
and it still was not automatic on P2, where Nam had to ask again, nor on 3418/3458, where it had to
be asked a third time after the code was already public. Treat the lane as part of the
definition of done, not as a thing each ticket rediscovers. Related:
[[idle-review-subagent-is-not-a-passing-review]], [[address-low-review-findings-too]],
[[fixing-a-false-claim-tends-to-produce-a-new-one]].

## 2026-09-24: asked twice more in one session (3473, then 3486), and the fix moved into the skill

On SBDEV-3473, Nam asked "were the changes reviewed?" and `0710d417` had been read by nobody. Its
review found 2 Mediums. On SBDEV-3486 he asked again after the PRs were open: `7763f6aa`, the fix for
a **High** (an IT that would have stopped dev deploys), had never been reviewed. The adversarial lane's
final report was written against the pre-fix commit. **The cause both times was misreading the
loop-ending rule:** "a fresh Low doesn't force another pass" was applied after a pass that HAD found a
High/Medium.

**This memory existed and still failed.** The rule lived here and never reached the checklist I
actually execute. So `wms-plan-executor`'s Phase 6 block now carries a mandatory
`Reviewed SHA: <sha> vs tip <sha>` line that blocks the push when the difference contains production
logic or a High/Medium fix, next to a paragraph that spells out the loop-ending rule. A lesson that
keeps recurring belongs in the skill's checklist, not only in memory.

**2026-09-26, SBDEV-3362 — the Low-only case too.** Pushed PR #422 with `2b706a3c` (fixes for five
re-review Lows: comments plus one tightened assertion) unreviewed, reasoning from the executor skill's
"a fresh Low does not by itself force another loop". Nam asked "Are all the fixes reviewed?" The skill
sentence was the loophole; it now says every fix commit — Low-only included — gets one scoped lane
before push, so the `Reviewed SHA` line ends at the tip.

## 2026-09-27 (SBDEV-3356 / SBDEV-3546): asked twice in one session; the PR BODY is unreviewed too

Nam asked "were the fixes reviewed?" about PR #423 and then again about PR #424. On #423, two fix
commits and the PR body had shipped unreviewed. The final-state pass found a present-tense caveat that a
sibling PR would make false, plus an identity claim ("the three DBs share the same rows") that a
label-level query then disproved for dev. On #424 the code had been reviewed at its final state, but the
**PR body, commit message and ticket comment** were written after the review and carried claims no lane
had seen.

**How to apply:** treat the push as the review gate. Push only after a pass covering (1) every fix commit
since the last review, and (2) the PR body, commit message and ticket comment, which are written after
the review by construction. When a reviewer flags an unbacked measurement claim, **measure it**. Rewording
around it is the weaker fix: it can dodge the claim and leave the question open.

## 2026-09-27 (SBDEV-3549): one lane for six rounds is not six independent reviews

Lane B reviewed every round of PR #426. From round 2 on it was mostly checking fixes it had asked for, which is
weaker than an unseen reviewer. And even after six rounds, the last PR-body edit and all three ticket comments had
never been read by a reviewer. When Nam asked "were the changes and fixes reviewed?", the honest answer was
"mostly".
**How to apply:** for the FINAL pass before calling work done, use a FRESH reviewer that has not seen the earlier
rounds. Point it at the unreviewed residue: the last PR-body edit, ticket comments, and anything posted after the
final round.

## 2026-09-27 (SBDEV-3550): a review-suggested fix can break an arch rule the targeted re-run never loads

A reviewer suggested adding `@Transactional(NOT_SUPPORTED)` to a new IT, to match its siblings. I added it and
re-ran the IT, the mutant and one context test, and the reviewer approved. CI's unit lane went red:
`TestClassTransactionManagerArchTest` requires every NOT_SUPPORTED/NEVER test class to be registered in
`EXEMPT_NON_TRANSACTIONAL`, with a reason, in the same commit. Neither the author nor the reviewer knew the rule,
and the targeted re-run never loaded that test.
**How to apply:** after ANY review-fix edit to a test class's annotations or base class, run the unit lane's
arch tests (`mvn test -Dtest='*ArchTest'`, cheap) before pushing. Targeted re-runs prove the behaviour, not the
repo's conventions about test classes.
