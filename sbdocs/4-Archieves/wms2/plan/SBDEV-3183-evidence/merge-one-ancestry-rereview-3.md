# merge-one.sh: ancestry re-review round 3 (the rereview-2 L1..L5 fixes)

Reviewer: code-reviewer lane, read-only, 2026-10-21. Files: `.claude/skills/wms-merge/scripts/merge-one.sh`
(104 lines), `SKILL.md` rule 3 (lines 40-47) and §2c (lines 117-133). merge-one.sh was NOT run. Checks done:
`bash -n` (clean), a bash probe of `${1:?}` exit status, and a probe of the empty-MC `MP=$(...)` subshell.

**Verdict: APPROVE.** 0 Critical, 0 High, 0 Medium, 6 Low. All five rereview-2 fixes are correct.

## The fixes, one by one

- **L5, `die` to stderr (line 39): correct, and it breaks no caller.** Nothing parses merge-one's output.
  `grep -rn merge-one .claude` finds only SKILL.md (rule 3, the repo table, the §2c usage block) and
  `.claude/skills/README.md:43`. All of them are prose for an agent running it through the Bash tool, which
  captures both streams. `merge-preflight.sh`, `post-merge-verify.sh` and `flip-pending-markers.sh` neither call
  it nor read its output. Every diagnostic now goes to stderr: REFUSED, usage, exit-2 and WARNING. The success
  lines (`graded: ...`, `no PR check ...`, `merged #...`) go to stdout. That split is consistent.
- **L3, exit-code header (lines 20-21): correct for every path that goes through the script's own code.**
  See N1 for the one gap (`${n:?}` exits 127).
- **L2, retry loop (line 91): correct under `set -uo pipefail`.** `MC` is assigned before the loop, so `-u` has
  nothing to catch. There is no pipe, so `pipefail` does not apply. With no `-e`, a failing `gh pr view` does not
  abort the loop: its stderr shows (no `2>/dev/null` any more), MC stays empty, and the loop retries.
  `// empty` turns a null `mergeCommit` into "". There is one wasted `sleep 3` after the third failure (N3).
- **L1, empty-MC branch (lines 93-96): correct.** When MC is empty, `MP=$( [ -n "$MC" ] && git rev-parse ... )`
  runs a subshell whose `[` returns 1, so there is no output and MP="". The assignment's non-zero status is
  ignored because there is no `-e`. I probed this: `MP=[] st=1`. The `-z "$MC"` branch is tested before
  `-z "$MP"`, so the "GitHub returned no merge commit" message wins. The two failures now read differently,
  and neither message prints an empty `${MC:0:8}`.
- **Post-merge fetch failure warns (line 92): correct.** If the fetch fails and the object is missing, rev-parse
  fails and the script exits 3 with the "first parent could not be read" WARNING, after the fetch WARNING.
  This fails safe.
- **SKILL §2c exit codes plus a rule-3 pointer (line 125): present, and consistent with the header and rule 3**
  (0 / 1 / 2 / 3 = merged with WARNING).
- **Message accuracy:** the #550 output matches line 78 exactly ("graded: run <RID> on <8> at <RC>; develop tip
  <8> is an ancestor of the graded head") and line 104 ("merged #550 at 5d3718dd onto ccaa4e93").

## Findings

### [LOW] N1. Missing positional or option arguments exit 127, not the documented 2
`merge-one.sh:23,26-29`, Confidence: HIGH (probed)
```bash
REPO=${1:?usage}; PR=${2:?usage}; GRADED=${3:?usage: graded head sha}; shift 3
  --base) BASE_BRANCH=${2:?}; shift 2;;
```
In a non-interactive bash, `${x:?}` exits with status **127**. The probe `bash -c 'X=${1:?usage}'` gives
exit=127. The new header says "2 usage/setup error". A wrapper that branches on 2 would misread this. Nothing
merges on this path, so the impact is cosmetic.
Fix: `[ $# -ge 3 ] || { echo "usage: ..." >&2; exit 2; }` before line 23. For options, use
`[ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }`. Or document 127 in the header.

### [LOW] N2. `rev-parse -q` still discards the reason the first-parent read failed
`merge-one.sh:93`, Confidence: HIGH
```bash
MP=$( [ -n "$MC" ] && git rev-parse -q --verify "$MC^1" )
```
The fix removed `2>/dev/null`, but `-q` with `--verify` suppresses the error message too, so
rereview-2 L1's "the cause is discarded" half remains for the `-z "$MP"` branch. The impact is small: the
preceding fetch WARNING, when one prints, usually explains it.
Fix: drop `-q` (`git rev-parse --verify "$MC^1"`) so git prints `fatal: Needed a single revision`.

### [LOW] N3. The retry loop sleeps after its final attempt
`merge-one.sh:91`, Confidence: HIGH
```bash
for _ in 1 2 3; do MC=$(gh pr view ...); [ -n "$MC" ] && break; sleep 3; done
```
On three empty reads, the loop waits 3 s more before it gives up, adding 9 s instead of 6 s.
Fix: `for i in 1 2 3; do ...; [ -n "$MC" ] && break; [ $i -lt 3 ] && sleep 3; done`. Optional.

### [LOW] N4. The SKILL §2c `--no-pr-check` example omits the required `--graded-base`
`SKILL.md:122`, Confidence: HIGH
```bash
.claude/skills/wms-merge/scripts/merge-one.sh <repo-dir> <PR> <sha> --no-pr-check "yarn test on merge <sha>: <pass>/<fail>"
```
The prose two lines below says `--graded-base` is required, and the script's line 33 exits 2 without it. A
copy-pasted example therefore always fails. It fails safe (exit 2, nothing merged), but the example is wrong.
Fix: append `--graded-base <base-sha>` to the example, as the script header's line 6 already does.

### [LOW] N5. The §2c "It refuses if" list is still stale next to its own pointer
`SKILL.md:126-132`, Confidence: HIGH
The last bullet ("the base was **pushed** after the graded run") describes only the non-ancestor path. The list
leaves out three refusals: `mergeable != MERGEABLE` (line 45), "no push record" (line 81) and the force-push
probe (line 77). The new sentence "see rule 3" mitigates this, but the list still reads as complete. It is the
same rot as rereview-2 L4, half-fixed.
Fix: make the list end with "... or the base moved after the graded run (judged as in rule 3)", and add
"not MERGEABLE". Or drop the list and keep only the pointer. That fits the house rule: state the rule, don't
enumerate it.

### [LOW] N6. A failed `gh repo view` makes the refusal message misleading (pre-existing)
`merge-one.sh:47-50,81`, Confidence: MEDIUM
`NWO=$(gh repo view ...)` is unchecked. If it fails, NWO is empty. On the non-ancestor path, `pushed_at`
queries `repos//activity` with `2>/dev/null`, gets nothing back, and the script refuses with "no push record for
develop tip ... in GitHub's activity API". That blames the activity API for what is really a `gh` or auth
failure. On the ancestor path, the force-push call fails visibly, because its stderr is not suppressed, so this
affects only the non-ancestor path. It fails safe (exit 1).
Fix: `NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner) && [ -n "$NWO" ] || { echo "cannot resolve repo" >&2; exit 2; }`.

## Open questions (low confidence, not blocking)

- **[LOW] Exit 2 after `gh pr merge` can still mean merged** (`merge-one.sh:87`), Confidence: LOW. A client-side
  timeout or network drop after the server-side mutation succeeded returns non-zero, so the script reports exit 2
  "gh merge failed" for a PR that GitHub merged. The header and SKILL do not claim that exit 2 means nothing
  merged, so this is a gap, not a contradiction. Fix (optional): on that failure, run
  `gh pr view "$PR" --json state -q .state`. If it reads `MERGED`, fall through to the merge-commit checks
  instead of exiting 2.

## Positive observations
- Every post-merge uncertainty still ends in exit 3 with a WARNING, never in exit 0. The new empty-MC branch
  keeps that property.
- The diagnostics/stdout split is now uniform, and it costs nothing, because no script consumes the output.
- The header, rule 3 and §2c now agree on what exit codes 0-3 mean.
