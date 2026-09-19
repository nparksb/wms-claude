---
name: review-rounds-leave-their-own-fix-commits-unreviewed
description: "Every review round ends by producing a fix commit the round itself could not have seen, so 'reviewed' is never true of the last thing you did — Nam has caught this twice by asking"
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

**Do not wait to be asked.** Both times the gap was closed by Nam's question, not by me. Related:
[[idle-review-subagent-is-not-a-passing-review]], [[address-low-review-findings-too]],
[[fixing-a-false-claim-tends-to-produce-a-new-one]].
