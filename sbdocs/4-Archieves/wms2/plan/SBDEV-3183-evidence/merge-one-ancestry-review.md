# merge-one.sh ancestry short-circuit: independent review

- Reviewed: `/home/nampark/dev/wms-claude/.claude/skills/wms-merge/scripts/merge-one.sh` lines 58-68 (new block + reworded die), whole script read; `SKILL.md` rules 1-5; `post-merge-verify.sh` grepped.
- Mode: read-only. Script not executed. Date: 2026-10-21.
- **Verdict: COMMENT (approve with fixes recommended).** No High finding at high confidence. 7 findings: 0 High, 2 Medium, 5 Low.

## Soundness of the rule

Claim: if `origin/<base>` tip TIP is an ancestor of graded head HEAD, the graded check covered what lands.

- What lands: GitHub `--merge` always creates a merge commit. With TIP ⊂ HEAD, merge(HEAD, TIP) has exactly HEAD's tree. So the landed code == HEAD's tree.
- What was graded: for a `pull_request` workflow, the run tested `refs/pull/N/merge` = merge(HEAD, B0), where B0 = base tip when the run was triggered. Its tree == HEAD's tree **iff B0 ⊂ HEAD**.
- If the base only moves forward (B0 ⊂ TIP), then B0 ⊂ TIP ⊂ HEAD, so the graded tree == the landed tree. Sound. This holds for the #550 case (ccaa4e93 ⊂ 5d3718dd) and is if anything a *stronger* guarantee than the old push-time test.
- For a `push`-triggered check, the run tested HEAD itself; also sound.
- The guarantee breaks only when B0 ⊄ TIP: the base was rewound/force-pushed after the run, or the PR was retargeted from another base after the run (Finding M1, L5).

## Findings

### [MEDIUM] M1. Ancestor path assumes the base never rewinds; SKILL.md says there is no branch protection
File: merge-one.sh:58-66 · Confidence: MEDIUM
```
# If the base tip is already an ancestor of the graded head, the check graded a tree that contains it, so
# when the tip was pushed does not matter.
if git merge-base --is-ancestor "$TIP" "$HEAD" 2>/dev/null; then
```
SKILL.md rule 4: "no branch protection". If develop is force-pushed back (e.g. reverting a bad merge by reset) after the graded run, B0 ⊄ HEAD, so the run graded merge(HEAD, B0) which includes B0-only commits, while the landed tree is HEAD alone. The tested tree ≠ the landed tree, and the old push-time comparison (which would have caught the force-push as "pushed after the run") is skipped. Rare, but this gate exists for rare cases, and the code comment states the guarantee unconditionally.
Fix (either): (a) in the ancestor branch also refuse if GitHub's activity API shows any `force_push` on the base after `$RC`: `gh api "repos/$NWO/activity?ref=$BASE_BRANCH&activity_type=force_push&per_page=5" --jq '.[].timestamp'` compared to `$RC` (an empty answer is fine here: it's a rejection-only probe); or (b) enable "block force pushes" on develop and cite it in the comment. Reword the comment to state the assumption ("the base only moves forward").

### [MEDIUM] M2. Base can still move between `git fetch` (l.31) and `gh pr merge` (l.64); pre-existing, not widened
File: merge-one.sh:31,41,64 · Confidence: HIGH (that the race exists) / pre-existing
```
git fetch -q origin ...
TIP=$(git rev-parse "origin/$BASE_BRANCH")
...
gh pr merge "$PR" --merge --match-head-commit "$HEAD"
```
`--match-head-commit` pins only the head. If another merge lands on develop after the fetch, GitHub merges HEAD into a base the check never saw. The new block does not widen this: it removes the `pushed_at` API call, so the TIP-read-to-merge window is slightly shorter than the old path. Both paths share it.
Fix: after a successful merge, assert the merge commit's first parent equals `$TIP` (`MC=$(gh pr view "$PR" --json mergeCommit -q .mergeCommit.oid); git fetch -q origin; [ "$(git rev-parse "$MC^1")" = "$TIP" ]`), and print a loud "base moved during merge: re-grade develop now" otherwise. Better in `post-merge-verify.sh` (its l.10/51 checks prove ancestry, not that the first parent is the graded base) or here so it can't be skipped.

### [LOW] L1. Die message asserts "not an ancestor" when is-ancestor may have errored
File: merge-one.sh:62,68 · Confidence: HIGH
```
[ -n "$TIPT" ] || die "... and it is not an ancestor of the graded head, so whether it moved ..."
```
`is-ancestor` returns 1 for "no" and 128 for "bad object" (HEAD not fetched: fork PR, or head pushed between l.31 and l.32; or TIP unresolved, see L2); `2>/dev/null` merges both. Failing closed is correct, but the message misdirects the operator into re-grading when the real fix may be `git fetch origin <head>`.
Fix: capture the code: `git merge-base --is-ancestor "$TIP" "$HEAD" 2>/dev/null; ANC=$?`, branch on 0, and in the die say "not an ancestor" for 1 and "could not test ancestry (missing object; fetch the head?)" for 128.

### [LOW] L2. `TIP` from an unchecked `git rev-parse`
File: merge-one.sh:41 · Confidence: HIGH (pre-existing)
```
TIP=$(git rev-parse "origin/$BASE_BRANCH")
```
On failure rev-parse prints the literal arg to stdout, so TIP="origin/develop"-like text. Both paths happen to fail closed (is-ancestor errors; activity `select(.after==...)` finds nothing), but by luck, and with misleading messages.
Fix: `TIP=$(git rev-parse --verify -q "origin/$BASE_BRANCH^{commit}") || die "origin/$BASE_BRANCH not found after fetch"`.

### [LOW] L3. Duplicated merge+exit instead of one merge site
File: merge-one.sh:64-65 vs 73 · Confidence: HIGH
```
gh pr merge "$PR" --merge --match-head-commit "$HEAD" && echo "merged #$PR at ${HEAD:0:8}. Next: post-merge-verify.sh"
exit $?
```
`exit $?` is correct: on gh failure `&&` short-circuits and `$?` is gh's code; on success it is echo's 0 (no `set -e`, so no surprise). But the merge command now exists twice; a future guard added before l.73 will silently not apply to the ancestor path (the classic shotgun-surgery trap in a safety gate). Also a gh failure exits 1, indistinguishable from REFUSED's 1 (pre-existing).
Fix: make it `if ancestor; then echo ...; else <pushed_at checks + echo>; fi` and let both fall through to the single l.73 merge. Optionally map gh failure to a distinct code (e.g. `|| exit 3`).

### [LOW] L4. Header comment and SKILL.md rule 3 now overstate/understate the rule
File: merge-one.sh:12-13; SKILL.md rule 3 (l.40-41) · Confidence: HIGH
```
# - the PR check ... concluded success ON that head, and <base> was not PUSHED after that run started
```
```
re-reads the base, and refuses if the check graded a different head or the base moved after it.
```
Both say a post-run base push always refuses; it no longer does when the base tip is an ancestor of the head. Fix: add "...unless the current base tip is an ancestor of the graded head (then the graded tree is the landed tree)" in both places.

### [LOW] L5. Retargeted PRs: graded base may not be the current base
File: merge-one.sh:37,62 · Confidence: LOW
If a stacked PR was graded against a feature base and then retargeted to develop without a new run (retargeting does not re-trigger `pull_request` with default `types`, unless the skill's push does), the run graded merge(HEAD, featureBase). If featureBase ⊄ HEAD the graded tree contained extra code; with develop-tip ⊂ HEAD the ancestor path will accept it. The old path would usually also accept (develop push time likely precedes the run), so not a regression.
Fix: in the ancestor branch, require the run's event/base to match: `gh api repos/$NWO/actions/runs/$RID --jq '.pull_requests[0].base.ref'` == `$BASE_BRANCH` (verify this field's semantics before relying on it).

## Checked and fine
- `--no-pr-check` path: the new block is entirely inside the `else` (l.49-72); l.46-48 unchanged. Unaffected.
- Fail-closed on missing objects: any non-zero is-ancestor (1 or 128) falls through to the old push-time logic, which is the pre-change behaviour. Author's three exercises match this.
- HEAD equality: the ancestor test uses `$HEAD`, which l.57 already proved equals the run's `headSha`, and l.39 proved matches the graded prefix; merge is pinned with the full `$HEAD`.
- TIP freshness: read after the l.31 fetch, so it is as fresh as the old path's.
- Repo dir: `gh` resolves the repo from the cwd remote, same dir as `git fetch origin`; a `gh repo set-default` pointing elsewhere would desync them, but that is pre-existing and not touched by this change.
- TIP == HEAD: is-ancestor is true (reflexive); harmless (empty diff).

## Positive observations
- The new rule replaces a timestamp proxy with a direct graph fact, removing dependence on an API that demonstrably drops events; under forward-only base history it is strictly stronger.
- It still requires the run to be SUCCESS on exactly `$HEAD` before the shortcut.
- The comment explains why and names the fail-closed behaviour; the die message tells the operator what to do.
