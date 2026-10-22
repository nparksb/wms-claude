# merge-one.sh: ancestry re-review round 5 (the rereview-4 R1-R4 fixes)

Reviewer: code-reviewer lane, read-only, 2026-10-21. Files: `.claude/skills/wms-merge/scripts/merge-one.sh`
(115 lines), `SKILL.md` rule 3 and section 2c. Not run against GitHub.

Checks: `bash -n` is clean. I also ran a stubbed dry run with fake `gh` and `git` on PATH, in
`/tmp/claude-1000/-home-nampark-dev-wms-claude/106c745f-922c-4987-90b6-23ad90878c48/scratchpad/mr5/`. Observed exit codes:

| Scenario | rc |
|---|---|
| clean merge, first parent == TIP | 0 |
| gh merge fails, then the PR reads MERGED, first parent == TIP | **3** |
| gh merge fails, the PR does not read MERGED | 2 |
| first parent != TIP | 3 |
| no merge commit returned | 3 |
| first parent unreadable | 3 |
| `--no-pr-check` with `gh repo view` broken | 0 (NWO is no longer needed) |
| PR-check path with `gh repo view` broken | 2 (before the merge) |

**Verdict: APPROVE.** 0 Critical, 0 High, 0 Medium, 2 Low (new). R1-R4 are fixed in behaviour. Their documentation
was carried over only partly; see N1.

## R1-R4

- **R1: FIXED (script).** Lines 87-95, 115:
  ```bash
  UNSURE=0
  if ! gh pr merge "$PR" --merge --match-head-commit "$HEAD"; then
    [ "$(gh pr view "$PR" --json state -q .state)" = MERGED ] \
      || { echo "gh pr merge failed and #$PR does not read MERGED; confirm with 'gh pr view $PR' before retrying" >&2; exit 2; }
    echo "WARNING: gh pr merge reported failure, but #$PR is MERGED (by this call or another); verify the merge by hand" >&2
    UNSURE=1
  fi
  ...
  [ "$UNSURE" -eq 0 ] || exit 3
  ```
  The stub confirms rc=3 on the reconcile path even when the first parent equals TIP. Every other post-merge branch
  (lines 104-113) already exits 3. That leaves one way to reach exit 0: `gh pr merge --merge` succeeded **and** a
  merge commit was read **and** `MP == TIP`. That path proves the first parent is the graded base tip.
  The documentation part of the rereview-4 fix ("add it to the exit-3 line of the header and of SKILL 2c") was
  not done. See N1.
- **R2: FIXED.** SKILL 2c now has the bullet "with `--no-pr-check`: the base tip no longer equals `--graded-base`;".
  It matches script line 51: `die "$BASE_BRANCH is ${TIP:0:8}, but the local suite graded a merge on ${GBASE:0:8}: re-grade"`.
- **R3: FIXED in the SKILL and the runtime message, NOT in the header.** SKILL 2c says "2 setup/merge error (nothing
  merged as far as the script can tell; confirm with `gh pr view` before retrying)". Script line 91 prints "confirm
  with 'gh pr view $PR' before retrying". Header line 20 still says only `2 usage/setup error or gh merge failed`.
  See N1.
- **R4: FIXED.** Line 54, `NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner) && [ -n "$NWO" ] || {...; exit 2; }`,
  now sits inside the `else` (PR-check) branch. It runs before both uses: `pushed_at` (line 80) and the force-push
  probe (line 74). The `--no-pr-check` path never expands `$NWO`, so `set -u` is safe. With `gh repo view` broken
  in the stub, that path merged with rc=0.

## Regression sweep

- **No `die` after the merge.** After line 88 the script only warns or exits 2 or 3. The post-merge `git fetch`
  failure only warns (line 102).
- **`set -u`:** every variable read after the merge (`TIP`, `HEAD`, `MC`, `MP`, `UNSURE`, `i`) is assigned on every
  path. `NWO` is read only inside the branch that assigns it.
- **`pipefail`:** `jq ... | head -1` (lines 55-56) can SIGPIPE, but only inside an assignment and without `-e`, so
  the value is unaffected. When the `grep` on line 58 finds nothing, `RID` is empty, and the script refuses with
  exit 1 before merging.
- **Exit 0 requires the proof:** `MP` comes from `git rev-parse --verify "$MC^1"`, and the script compares the full
  40-character `MP` to the full `TIP`.
- **Header vs behaviour:** the refusal bullets (lines 8-18) match the code. The exit lines do not; see N1.

## New findings

### [LOW] N1. The header and SKILL exit-code text lag the R1/R3 behaviour
Confidence: HIGH.
- `merge-one.sh:20-21` reads:
  `# Exit: 0 merged onto the graded base tip · 1 refused, nothing merged · 2 usage/setup error or gh merge failed`
  `#       · 3 MERGED, with a WARNING (base moved during the merge, or the merge commit could not be read).`
  - The exit-3 causes leave out "gh pr merge failed but the PR reads MERGED" (UNSURE=1).
  - Exit 2 does not say "nothing merged as far as the script can tell; confirm with `gh pr view` before retrying".
- `SKILL.md` rule 3 lists exit 3 only for "first parent is not the graded base tip ... or if it cannot read it".
  SKILL 2c defers to rule 3 for the meaning of exit 3.

Failure scenario: GitHub times out but completes the merge. An operator sees rc=3 and reads rule 3, which says
"the base moved during the merge, so re-run the suite on develop". That is the wrong diagnosis. The real
uncertainty is who merged the PR and how (possibly a squash by someone else). The operator re-runs the suite and
never checks that the merge was a true `--merge` of the graded head. Nothing unsafe gets merged, but the
operator's follow-up is misdirected.

Fix:
- Header line 20: `2 usage/setup error, or gh merge failed and the PR does not read MERGED (confirm with gh pr view before retrying)`.
- Header line 21: add `, or gh pr merge failed but the PR reads MERGED (possibly merged by another, verify by hand)`.
- Rule 3: add the same cause to its exit-3 sentence.

### [LOW] N2. On the reconcile path, stdout's last line claims a clean result and a cause line can be wrong
`merge-one.sh:114-115`, also line 111. Confidence: HIGH (observed in the stub, scenario B).
```bash
echo "merged #$PR at ${HEAD:0:8} onto ${TIP:0:8}. Next: post-merge-verify.sh"
[ "$UNSURE" -eq 0 ] || exit 3
```
- With UNSURE=1 and `MP == TIP`, stdout ends "merged #1 at bbbbbbbb onto aaaaaaaa", the exit-0 wording, and the
  script exits 3. The WARNING goes to stderr only. A caller that captures stdout alone (an agent summarising the
  run) sees the success line.
- On the same path, if another actor squash- or rebase-merged the PR, `MP != TIP` is likely. Line 111 then
  blames "develop moved during the merge; re-run the suite on develop", which is a misleading cause.

Fix: when `UNSURE=1`, print a distinct final line, for example
`merged #$PR (reconciled after gh failure; verify merge method and parents by hand). Next: post-merge-verify.sh`,
and exit 3 before the generic line. Optionally, on that path, check
`git merge-base --is-ancestor "$HEAD" "$MC"` and name a squash or rebase as the cause.

## Positive observations
- The R1 fix is minimal and puts the reconcile path on the same exit-3 rule as every other post-merge uncertainty.
  The exit-0 invariant ("the first parent of a real `--merge` commit equals the graded TIP") now holds on every path.
- R4 removes a needless failure point from the no-PR-CI path without weakening the PR-check path.
- The exit-2 message on line 91 now tells the operator what to do before retrying.

## Re-review of N1/N2 fixes

Scope: `merge-one.sh` header lines 20-23, the post-merge block (lines 96-115), SKILL rule 3's exit-3 sentence, and
the SKILL 2c exit-code pointer. `bash -n` is clean. I re-ran the stub scenarios with the same fake `gh` and `git`.

**Verdict: APPROVE.** N1 and N2 are fixed. 0 Critical, 0 High, 0 Medium, 1 Low (new, cosmetic).

### N1: FIXED
- Header, lines 20-23:
  - Exit 2 now reads "usage/setup error, or gh merge failed and the PR did not read MERGED (nothing merged as far as
    the script can tell; confirm with gh pr view before retrying)".
  - Exit 3 now lists "or gh pr merge failed but the PR reads MERGED, possibly merged by someone else or as a squash".
- SKILL rule 3 adds this sentence: "It also exits 3 when `gh pr merge` reported failure but the PR reads MERGED: then
  it is not proven to be this call's merge (someone else may have merged it, even as a squash), so check the merge
  method and parents by hand."
- SKILL 2c now reads "**3 merged with a WARNING** (see rule 3 for what each warning asks of you)". It no longer
  hard-codes the "re-run the suite" advice, so it stays correct for every exit-3 cause.

The header, rule 3, 2c and the code now agree on all four exit codes.

### N2: FIXED
```bash
elif [ "$UNSURE" -eq 1 ]; then
  echo "WARNING: merge commit ${MC:0:8} has first parent ${MP:0:8} (graded base tip ${TIP:0:8}); check the merge method and parents by hand" >&2
  echo "merged #$PR (reconciled after a gh pr merge failure; not proven to be this call's merge). Next: post-merge-verify.sh"; exit 3
```
- This branch is ordered before the `MP != TIP` branch, so the reconcile path no longer blames "develop moved
  during the merge".
- The trailing `[ "$UNSURE" -eq 0 ] || exit 3` is gone. With it gone, the final "onto TIP" success line can no
  longer print before an exit 3.

### Exit-0 reachability
The only fall-through to the final `echo` (line 115, exit 0) needs all four of these:
1. `MC` is non-empty.
2. `MP` is non-empty.
3. `UNSURE` is 0, which means `gh pr merge --merge --match-head-commit` returned success.
4. `MP == TIP`, compared as full SHAs.

Every other post-merge branch ends in an explicit `exit 3`. No `die` follows line 88.

### Stub results
| Scenario | rc | Last stdout line |
|---|---|---|
| A: clean, MP == TIP | 0 | "merged #1 at bbbbbbbb onto aaaaaaaa" |
| B: reconcile, MP == TIP | 3 | "merged #1 (reconciled ...; not proven to be this call's merge)" |
| B2: reconcile, MP != TIP | 3 | same reconcile line; does not blame "develop moved" |
| B3: reconcile, no merge commit | 3 | |
| B4: reconcile, MP unreadable | 3 | |
| C: gh fails, PR not MERGED | 2 | |
| D: base moved | 3 | |
| E: no merge commit | 3 | |
| F: MP unreadable | 3 | |
| G: `--no-pr-check`, `gh repo view` broken | 0 | |
| H: PR-check path, `gh repo view` broken | 2 | exits before the merge |

(A "state read empty" probe was a stub artifact: the stub defaults an empty STATE to MERGED. In the real script an
empty `gh pr view` state is not MERGED, so it exits 2, as rereview-4 verified.)

### [LOW] N3. A reconcile run that also hits the "no merge commit" or "MP unreadable" branch ends on the generic stdout line
`merge-one.sh:104-109`. Confidence: HIGH (stub B3/B4).
The `-z "$MC"` and `-z "$MP"` branches come before the `UNSURE` branch. With UNSURE=1 they print
"merged #$PR at ${HEAD:0:8}. Next: ..." and drop the "reconciled; not proven to be this call's merge" wording.
The exit code is still 3, and the reconcile WARNING already went to stderr on line 94, so nothing is unsafe. A
caller that reads only stdout loses the reconcile context in these two sub-cases.
Fix (optional): in those two branches, append `$( [ "$UNSURE" -eq 1 ] && echo " (reconciled after a gh pr merge failure)")`
to the stdout line, or set a suffix variable once at line 95 and use it on every exit-3 stdout line.

## Re-review of N3 fix

Scope: `merge-one.sh` lines 105-121, the `DONE` variable and the four exit-3 branches. `bash -n` is clean.
I re-ran the stub with stderr dropped, to show what a caller that reads only stdout would see.

**Verdict: APPROVE.** N3 is fixed. 0 Critical, 0 High, 0 Medium, 0 Low new findings.

### The change
```bash
DONE="merged #$PR at ${HEAD:0:8}. Next: post-merge-verify.sh"
[ "$UNSURE" -eq 0 ] || DONE="merged #$PR (reconciled after a gh pr merge failure; not proven to be this call's merge). Next: post-merge-verify.sh"
```
All four exit-3 branches now run `echo "$DONE"; exit 3`.
- `DONE` is assigned before any branch reads it, so `set -u` is safe.
- When `UNSURE=0`, the `||` assignment does not run, and with no `-e` the test's status is harmless.
- The exit-0 line (line 121) still uses its own "onto TIP" text and does not read `DONE`.

### Exit-0 reachability (unchanged)
Exit 0 is reached only by falling through all four branches. That needs:
1. `MC` is non-empty.
2. `MP` is non-empty.
3. `UNSURE` is 0, which means `gh pr merge` succeeded.
4. `MP == TIP`.

### Stub results (last stdout line)
| Scenario | rc | Last stdout line |
|---|---|---|
| A: clean | 0 | "merged #1 at bbbbbbbb onto aaaaaaaa" |
| B: reconcile, MP == TIP | 3 | reconciled / not proven |
| B2: reconcile, MP != TIP | 3 | reconciled / not proven |
| B3: reconcile, no merge commit | 3 | reconciled / not proven (the N3 case, now fixed) |
| B4: reconcile, MP unreadable | 3 | reconciled / not proven (the N3 case, now fixed) |
| C: gh fails, PR not MERGED | 2 | |
| D: base moved | 3 | generic |
| E: no merge commit | 3 | generic |
| F: MP unreadable | 3 | generic |
| G: `--no-pr-check` clean, `gh repo view` broken | 0 | |
| H: PR-check path, `gh repo view` broken | 2 | |

The exit codes are identical to the previous round.
