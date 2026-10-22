# merge-one.sh ancestry fixes: scoped re-review

- Reviewed: `/home/nampark/dev/wms-claude/.claude/skills/wms-merge/scripts/merge-one.sh` (whole file, 85 lines), `SKILL.md` rule 3 (l.40-46), against the prior review `merge-one-ancestry-review.md` (M1, M2, L1-L5).
- Mode: read-only. Script NOT executed. Read-only `gh api` probes only (wms2-api). Date: 2026-10-21.
- **Verdict: COMMENT (approve; no blocking finding).** 7 findings: 0 High, 1 Medium, 6 Low. M1, L1, L2, L3, L4 are correctly fixed. M2 is fixed in intent but its instrument can raise a false WARNING (R-M1).

## Probes run (evidence)

| Probe | Result | What it settles |
|---|---|---|
| `activity?ref=develop&activity_type=force_push&per_page=5` | 2 rows, `2026-05-29T18:51:38Z`, `2026-05-29T18:28:48Z`, newest first, `ref=refs/heads/develop` | server-side type filter works; `ref=develop` (short form) is accepted |
| `activity?ref=develop&per_page=5` vs `...&direction=asc` | default returns 2026-10-21 first; `asc` returns 2026-03-14 first | default order is **newest-first (desc)** |
| `gh run view <id> --json createdAt` | `"2026-10-21T15:42:08Z"` | same `YYYY-MM-DDTHH:MM:SSZ` shape as activity `timestamp` |
| `actions/runs/39628067366` | `pull_requests[0].base.sha = ccaa4e939ae2` = current `origin/develop` | see R-L6 (optional stronger instrument) |

## Fix-by-fix verification

- **M1 (force-push probe on ancestor path), l.68-70: correct.** Default order is desc and the type filter is server-side, so the 5 rows are the 5 newest force-pushes; any force-push after `$RC` is necessarily among them (if there were more than 5 after RC, all 5 are after RC, count is 5). `per_page=5` cannot miss one. String `>` on two UTC `...Z` second-precision timestamps is a correct chronological comparison. `gh api` non-zero (HTTP error, jq error) dies via `||`. Residuals: R-L1, R-L2, R-L3.
- **`set -uo pipefail` + `git merge-base ...; ANC=$?` (l.65): correct.** No `-e`, so a 1 or 128 does not abort; `$?` is the merge-base exit code (redirection does not alter it); `ANC` is always set, so `-u` is satisfied. `pipefail` is irrelevant (no pipeline).
- **L1 (exit >1 refuses separately), l.66: correct.** 0 = ancestor, 1 = not, anything else (128 bad object, 129 usage) dies with its own message. Behaviour change noted in R-L4.
- **L2, l.43: correct.** `rev-parse --verify -q "origin/$BASE^{commit}"` returns non-zero with empty stdout on failure; `||` die fires. TIP is now always a full 40-hex commit id, which also makes the `select(.after==$TIP)` in `pushed_at` and the `case "$TIP" in "$GBASE"*` prefix test well-defined.
- **L3, l.80: correct.** One merge site, both paths fall through to it; `--no-pr-check` path also reaches it. gh failure exits 2 (distinct from REFUSED's 1; shares 2 with usage/fetch errors, both "did not merge", acceptable).
- **L4: correct.** Header l.12-15 and SKILL.md rule 3 both now state the two-way rule and the force-push condition. Wording overclaim: R-L2.
- **M2 (post-merge first-parent warning), l.82-85: intent right, instrument wrong.** See R-M1.
- **L5: not fixed by design.** Agree it is pre-existing and not a regression; still open.

## Findings

### [MEDIUM] R-M1. Post-merge check reads the branch tip, not our merge commit: false WARNINGs (and a stale-fetch false WARNING)
File: merge-one.sh:83-85 · Confidence: HIGH
```
git fetch -q origin "$BASE_BRANCH" 2>/dev/null
MP=$(git rev-parse -q --verify "origin/$BASE_BRANCH^1" 2>/dev/null)
[ "$MP" = "$TIP" ] || echo "WARNING: the merge commit's first parent is ${MP:0:8}, ..."
```
`origin/$BASE^1` is the first parent of whatever the tip is at fetch time, which is our merge commit only if nobody else merged between our `gh pr merge` and this fetch. Three false-WARNING paths:
1. Another merge lands right after ours (exactly the busy-develop situation rule 2 cares about): tip = their merge, `^1` = our merge commit != TIP: WARNING says "develop moved during the merge" when it did not.
2. The fetch fails (error suppressed by `2>/dev/null`, exit unchecked): `origin/develop` is still TIP, so `MP = TIP^1` != TIP: WARNING, always.
3. Merge queue / async merge (not configured today): tip not yet our commit.
Also a false NEGATIVE is impossible only by luck: the message names "the merge commit" but the code never identifies it. The cost of a false WARNING is an unnecessary develop re-grade, and repeated false alarms train the operator to ignore the one real one (the reason the check exists).
Fix: identify our merge commit and read its parent, and say when it cannot:
```
MC=$(gh pr view "$PR" --json mergeCommit -q '.mergeCommit.oid // empty')
if [ -z "$MC" ] || ! git fetch -q origin "$BASE_BRANCH" || ! MP=$(git rev-parse -q --verify "$MC^1"); then
  echo "WARNING: could not read #$PR's merge commit / its first parent: check by hand that it is ${TIP:0:12}"
elif [ "$MP" != "$TIP" ]; then
  echo "WARNING: #$PR's merge commit ${MC:0:8} has first parent ${MP:0:8}, not the graded base tip ${TIP:0:8}: $BASE_BRANCH moved before the merge; re-grade develop"
fi
```
(`post-merge-verify.sh:43-45` already reads `mergeCommit` the same way, so this reuses an existing pattern.)

### [LOW] R-L1. `>` excludes a force-push in the same second as the run start
File: merge-one.sh:69 · Confidence: HIGH (that it exists) / LOW (that it matters)
```
--jq "[.[] | select(.timestamp > \"$RC\")] | length"
```
Both clocks have 1-second resolution. A force-push in the same second as `createdAt` (ordering unknowable) passes. This is a safety gate; ties should refuse.
Fix: `>=`.

### [LOW] R-L2. Force-push probe is rejection-only on an API known to drop events; comment and SKILL rule 3 state it as a guarantee
File: merge-one.sh:13-14, 62-63; SKILL.md:42-43 · Confidence: MEDIUM
```
# ... It assumes <base> only moved forward since the run started, so a force-push after the run start refuses.
```
```
contains it, so only a force-push of the base after the run started refuses.
```
The same rule 3 records that the activity API missed a whole push of ccaa4e93. If it misses a force-push the same way, `FP=0` and the ancestor path accepts. The 2020-cutoff positive control proves the query shape, not completeness. Also, delete-and-recreate of the branch is recorded as `branch_deletion`/`branch_creation`, not `force_push`, so a rewind done that way is invisible to this filter.
Fix: reword to "refuses if GitHub's activity API records a force-push (or branch deletion) of <base> after the run started; the API can miss events, so this is best-effort". Optionally widen the filter: drop `activity_type` and select `.activity_type == "force_push" or .activity_type == "branch_deletion"` with a larger `per_page` (filtering client-side reintroduces the per_page window issue, so use e.g. `per_page=100`), or adopt R-L6. Enabling "block force pushes" on develop would make the assumption true by construction.

### [LOW] R-L3. Missing/odd `createdAt` or `FP` fails open or with a misleading message
File: merge-one.sh:58, 69-70 · Confidence: MEDIUM
```
RS=$(jq -r .headSha <<<"$RJ"); RC=$(jq -r .createdAt <<<"$RJ")
...
[ "${FP:-0}" -eq 0 ] || die "$BASE_BRANCH was force-pushed after the graded run started ($RC): re-grade"
```
- If `createdAt` were absent, `RC="null"`; every digit-led timestamp sorts below `"null"`, so the count is 0 and the probe silently passes (fail-open). gh returns it today, so this is defensive.
- `${FP:-0}`: an empty FP (only possible if gh exits 0 with no output) is treated as "no force-push": fail-open. A non-integer FP makes `[ -eq ]` error (exit 2) and the `||` dies with "was force-pushed", which is fail-closed but false.
- `2>/dev/null` on the gh call hides the API's own error text from the die message.
Fix: validate RC (`[[ "$RC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || die "run $RID has no createdAt"`), validate FP (`[[ "$FP" =~ ^[0-9]+$ ]] || die "unexpected force-push probe answer '$FP'"`), drop `:-0`, and keep stderr.

### [LOW] R-L4. L1 changes behaviour for heads not on any fetched branch (fork PRs), and the hint names a fetch the script does not do
File: merge-one.sh:33, 65-66 · Confidence: MEDIUM
```
git fetch -q origin || ...
...
[ "$ANC" -le 1 ] || die "... (git exit $ANC): fetch the PR head and retry"
```
Before L1, exit 128 fell through to the push-time path, which could pass. Now a PR whose head is not on an origin branch (fork PR; `git fetch origin` does not fetch `refs/pull/*`) always refuses. Fail-closed, so correct, but the operator must know the refspec. The script can do it itself.
Fix: before l.65, `git fetch -q origin "pull/$PR/head" 2>/dev/null || true` (fetches the object; harmless when already present). Then 128 really means something is wrong.

### [LOW] R-L5. Post-merge WARNING does not change the exit status, and prints after "Next: post-merge-verify.sh"
File: merge-one.sh:81, 85 · Confidence: MEDIUM
The WARNING is the only signal that develop now carries an ungraded combination, yet the script exits 0 and the last success line already told the operator to move on. A caller that checks only the exit code (or an agent summarising) loses it.
Fix: emit the WARNING before the "merged" line, and/or exit with a distinct code (e.g. 3 = "merged, but the base moved: re-grade develop") and document it in SKILL.md rule 3 next to the WARNING sentence. Exit 3 is unambiguous since nothing else uses it.

### [LOW] R-L6. A direct graph instrument for B0 may exist (would remove the API dependency from the ancestor path)
File: merge-one.sh:65-70 · Confidence: LOW
The guarantee the ancestor path needs is B0 ⊂ HEAD, where B0 is the base sha the run's `refs/pull/N/merge` was built on. The run object carries `pull_requests[0].base.sha`; for run 39628067366 it is `ccaa4e939ae2` (equal to current develop, so this probe cannot tell "base at trigger time" from "base now"). If it is the base at trigger time, `git merge-base --is-ancestor "$B0" "$HEAD"` proves the graded tree equals the landed tree with no dependence on the activity API, and would also close L5 (a retargeted PR's run has `base.ref != $BASE_BRANCH`).
Fix: verify the field's semantics on a run whose base has since moved; if confirmed, replace/augment the force-push probe with it and check `base.ref`.

## Still open from the prior review
- **L5 (retargeted PR graded on a feature base):** deliberately not fixed; pre-existing, not a regression. R-L6 is a possible one-stone fix.

## Positive observations
- Every new path fails closed except the documented best-effort API probes (R-L2/R-L3); the exit-code capture (`; ANC=$?`) is the idiomatic, `-e`-safe form.
- One merge site (L3) removes the shotgun-surgery risk in a safety gate; gh failure now has a distinct exit code.
- `rev-parse --verify ...^{commit}` (L2) makes every downstream comparison against TIP well-defined.
- The author ran a positive control (2020 cutoff returns 2) rather than only the negative case; that is the right way to prove a rejection probe can reject.
- SKILL.md rule 3 now records the activity-API miss with its concrete sha, so the reason for the two-way rule is preserved.

## Counts
0 Critical, 0 High, 1 Medium (R-M1), 6 Low (R-L1..R-L6). Verdict: COMMENT.
