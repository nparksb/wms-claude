# merge-one.sh: ancestry re-review round 2 (scoped to the R-M1, R-L1..R-L5 fixes)

Reviewer: code-reviewer lane, read-only, 2026-10-21. Files: `.claude/skills/wms-merge/scripts/merge-one.sh`
(98 lines) and SKILL.md rule 3. merge-one.sh was not run.

**Verdict: APPROVE.** 0 Critical, 0 High, 0 Medium, 5 Low. All six prior fixes are correct as written.

## The questions I was asked

- **Is `mergeCommit` populated right after `gh pr merge --merge` returns?** Yes. `gh pr merge` calls the
  synchronous GraphQL `mergePullRequest` mutation, which creates the merge commit before it returns.
  `gh pr view 547 --json mergeCommit,state` returns `6a9312aa…`/`MERGED`. A merge queue would make the
  merge asynchronous, but there isn't one: `rules/branches/develop` returns 403 (the plan has no rulesets or
  protection, as SKILL rule 4 says). Brief read-after-write lag is possible in theory (L2 below). It fails
  safe, because the script exits 3 with a WARNING.
- **Does `git fetch origin develop` bring in the merge commit object?** Yes. The merge commit becomes the
  develop tip at merge time. It can only drop off develop if someone force-pushes develop in the few seconds
  between the merge and the fetch. In that case `rev-parse` fails and the script exits 3 with the WARNING,
  which is safe.
- **`set -u` on new variables:** `MC` and `MP` are always assigned, possibly to the empty string. Neither
  `RC` nor `FP` is read before it is assigned. No unbound-variable path.
- **Exit codes against SKILL:** 0 means merged onto TIP. 1 means REFUSED, from `die`, before any merge.
  2 means a usage or infrastructure error before the merge, or a failed `gh pr merge`. 3 means MERGED with a
  WARNING. This matches rule 3's "Exit 3 means MERGED, not refused". The `--merge` flag guarantees two
  parents, so `$MC^1` is the base side. On #547, `^1` is a49e6ebd, the prior develop.
- R-L1 (`>=`): correct. R-L3: the createdAt regex and the numeric FP guard are sound, and stderr from the
  force-push `gh api` call is no longer hidden. R-L4: `pull/$PR/head` lands in FETCH_HEAD, which is enough
  for `merge-base` to see the object.

## Findings

### [LOW] L1. The WARNING is garbled when `mergeCommit` is empty, and the cause is discarded
`merge-one.sh:88-92`, Confidence: HIGH
```bash
MC=$(gh pr view "$PR" --json mergeCommit -q '.mergeCommit.oid // empty' 2>/dev/null)
...
echo "WARNING: merged, but could not read merge commit ${MC:0:8}'s first parent; ..." >&2
```
When `MC` is empty, the message reads "could not read merge commit 's first parent". Two different failures
(no oid from GitHub, and an oid that would not resolve locally) produce the same text, and `2>/dev/null` on
both line 88 and line 89 throws away the reason. This runs against R-L3's "stderr not hidden" direction.
Fix: drop the two `2>/dev/null`, and branch the message:
`[ -z "$MC" ] && echo "WARNING: merged, but GitHub returned no mergeCommit for #$PR; ..." >&2`.

### [LOW] L2. No retry on a transient empty `mergeCommit`
`merge-one.sh:88`, Confidence: LOW
The mutation is synchronous, so this probably never fires. If it does fire, it produces a spurious exit 3
on a clean merge. Fix (optional): `for i in 1 2 3; do MC=$(...); [ -n "$MC" ] && break; sleep 2; done`.

### [LOW] L3. The header comment does not document the exit codes
`merge-one.sh:1-19`, Confidence: HIGH
The header lists the refusal conditions but not 0/1/2/3. The SKILL documents only 3. A caller reading the
script alone cannot tell that exit 3 means MERGED. Fix: add `# exit: 0 merged onto graded base; 1 refused
(nothing merged); 2 usage/infra error or gh merge failed (nothing merged); 3 MERGED with a WARNING, check
the base by hand`.

### [LOW] L4. SKILL §2c's refusal list leaves out the ancestry path and the post-merge exit 3
`SKILL.md` §2c ("It refuses if:"), Confidence: HIGH
The list still says only "the base was **pushed** after the graded run". It does not mention the ancestor
branch, the force-push probe, MERGEABLE, or exit 3. Rule 3 is correct, but §2c is the copy that sits next to
the command a user runs. Fix: replace the last bullet with a pointer to rule 3, or add a line: "exit 3 =
merged, base moved during the merge or could not be checked. Re-run the suite on develop."

### [LOW] L5. `die` writes to stdout while the other errors write to stderr (pre-existing)
`merge-one.sh:37`, Confidence: HIGH
REFUSED messages go to stdout, but the usage errors, exit-2 errors, and (since R-L5) the WARNINGs go to
stderr. A caller that captures only stderr misses why a merge was refused. Fix: `die() { echo "REFUSED: $*" >&2; exit 1; }`.

## Open questions
None.

## Positive observations
- R-M1 reads **our** merge commit instead of the base tip, so it is immune to another PR moving develop after
  us. This is the right design, and it is verified on #547.
- Every post-merge failure fails safe: anything uncertain exits 3 with a WARNING, never 0.
- The R-L2 best-effort caveat is consistent across the script comment (66-68), the header (13-14), and rule 3.
