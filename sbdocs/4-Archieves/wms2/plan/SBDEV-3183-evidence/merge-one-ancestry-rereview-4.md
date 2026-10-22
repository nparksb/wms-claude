# merge-one.sh: ancestry re-review round 4 (the rereview-3 N1-N6 fixes + open question)

Reviewer: code-reviewer lane, read-only, 2026-10-21. Files: `.claude/skills/wms-merge/scripts/merge-one.sh`
(110 lines), `SKILL.md` rule 3 and section 2c. The script was never run with a real PR. Checks: `bash -n` (clean);
argument-path probes that exit before any `gh` call; a `set -u` probe of the guard idiom.

**Verdict: APPROVE.** 0 Critical, 0 High, 1 Medium, 3 Low. N1-N6 are all fixed correctly. The one Medium sits in
the new open-question path.

## Fixes verified

- **N1 (line 23, 27): correct under `set -u`.** `[ $# -ge 2 ] && [ -n "$2" ] || {...}` short-circuits, so `$2` is
  never expanded when it is unset (probed: prints the guard message, no "unbound variable"). Probes, all exit 2:
  no args (usage), `--base` (needs a value), `--base ""` (needs a value), `--no-pr-check x` without `--graded-base`,
  `--bogus` (unknown arg), bad sha, `--check` with no value, nonexistent repo dir.
  Note: `--base --check` swallows `--check` as the base name. That fails safe, because the base compare refuses.
- **N2 (line 99): fixed.** `-q` is gone, so git prints its own error. The empty-MC subshell still yields MP="".
- **N3 (line 96): fixed.** `[ "$i" -lt 3 ] && sleep 3` skips the sleep after attempt 3. The loop's final status
  is 1, which is harmless without `-e`.
- **N4: fixed.** The SKILL 2c `--no-pr-check` example now carries `--graded-base <base-sha>`.
- **N5: fixed.** The refusal list now has MERGEABLE and the ancestor / force-push / no-push-record judgement, and it
  points at rule 3.
- **N6 (line 47): fixed.** `NWO=$(...) && [ -n "$NWO" ] || {...; exit 2;}` is correct.
- **Open question (lines 87-91): implemented.** Both outcomes of the re-read are correct. A failed `gh pr view`
  gives empty state, which is not MERGED, so exit 2. State MERGED prints the WARNING and falls through to the
  merge-commit check, which ends in exit 0 or 3 (lines 100-110) like the normal path.

## Findings

### [MEDIUM] R1. The reconcile path can report exit 0 for a merge this script did not perform
`merge-one.sh:87-91`, then 106-110. Confidence: MEDIUM.
```bash
if ! gh pr merge "$PR" --merge --match-head-commit "$HEAD"; then
  [ "$(gh pr view "$PR" --json state -q .state)" = MERGED ] || { echo "gh pr merge failed" >&2; exit 2; }
  echo "WARNING: gh pr merge reported failure, but #$PR is MERGED; ..." >&2
fi
```
`gh pr merge` can fail because someone else merged the PR first (a squash or rebase merge, or a merge after a
base move). The script then reads state MERGED and carries on. The only gate left is "first parent of the merge
commit == TIP". A squash commit on an unmoved base also passes that check, so the script exits **0** ("merged onto
the graded base tip") although the PR head is not an ancestor of the result. The rest of the script holds the
invariant that every post-merge uncertainty ends in exit 3. This path emits a WARNING and can still exit 0, and
the header ("0 merged onto the graded base tip") no longer describes it exactly.
Fix (smallest): set `RECON=1` in that branch. Before the final `echo` (line 110), do
`[ -z "${RECON:-}" ] || { echo "merged #$PR (reconciled after a gh failure) ..."; exit 3; }`. Alternatively, require
`git merge-base --is-ancestor "$HEAD" "$MC"` on that path and exit 3 otherwise. Add "or a gh failure that
reconciled to MERGED" to the exit-3 line of the header and of SKILL 2c.

### [LOW] R2. The 2c refusal list omits the `--no-pr-check` base refusal
`SKILL.md` 2c refusal list, script line 52. Confidence: HIGH.
The script refuses when `origin/<base>` is not the `--graded-base` ("local suite graded a merge on X: re-grade").
The list covers only the PR-check path. The prose above the list says `--graded-base` "must still be the base's
tip", which hints at it, but the list is meant to enumerate refusals.
Fix: add a bullet "with `--no-pr-check`: the base tip is not `--graded-base`", or fold it into the rule 3 pointer.

### [LOW] R3. Exit-2 wording is ambiguous now that exit 2 can follow a merge that reconciles
`merge-one.sh:20`, `SKILL.md` 2c. Confidence: MEDIUM.
"2 usage/setup error or gh merge failed" is still true (nothing merged: state was not MERGED). It never says so,
and a caller cannot tell from the text whether exit 2 is safe to retry. If the re-read itself fails (network
down), the PR may have merged and exit 2 hides it.
Fix: say "2 usage/setup error, or gh merge failed and the PR did not read MERGED (confirm with `gh pr view` before
retrying)".

### [LOW] R4. `gh repo view` is now a hard exit-2 gate on the `--no-pr-check` path, which never uses NWO
`merge-one.sh:47`. Confidence: HIGH.
`NWO` is used only by `pushed_at` and the force-push probe, both inside the PR-check branch. A transient `gh repo
view` failure now stops a no-PR-CI merge for nothing. It fails safe (exit 2, nothing merged).
Fix: move line 47 into the `else` branch, before the first `pushed_at` / force-push use.

## Positive observations
- The `[ $# -ge 2 ] && ... ||` guard is safe under `set -u` and covers the empty-value case in one line.
- The MERGED re-read reuses the existing merge-commit verification instead of duplicating it.
- The SKILL text, header and script now agree on exit codes 0/1/2/3, apart from R1 and R3.
