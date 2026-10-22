#!/usr/bin/env bash
# merge-one.sh: merge ONE PR, pinned to the head that was graded. The guards live here so they can't be
# skipped in prose.
#
# usage: merge-one.sh <repo-dir> <PR> <graded-head-sha> [--base <branch>] [--check <name>]
#        merge-one.sh <repo-dir> <PR> <graded-head-sha> --no-pr-check "<local-suite evidence>" --graded-base <base-sha> [--base <branch>]
#
# Refuses unless every one of these holds:
# - the PR is OPEN, not a draft, and MERGEABLE;
# - its base is <base> (default develop), re-read now, so a stacked PR can't merge into its feature base;
# - its current head equals <graded-head-sha>. A push after grading means re-grade;
# - the PR check (--check, default "test") concluded success ON that head, and EITHER the current <base> tip
#   is an ancestor of that head (the graded tree already contains it; a best-effort probe also refuses a
#   recorded force-push of <base> since the run started) OR <base> was not PUSHED after that run started (GitHub's activity API gives the
#   push time; commit dates can be older than pushes);
# - for repos with no PR CI: --no-pr-check "<where the local suite on the merge ran, with counts>" AND
#   --graded-base <the base SHA that local merge was built on>, which must equal origin/<base> now.
# Both SHAs must be at least 12 hex characters (a short prefix can match anything).
# Then: gh pr merge --merge --match-head-commit <graded-head-sha>  (GitHub refuses if the head moved).
# Exit: 0 merged onto the graded base tip · 1 refused, nothing merged · 2 usage/setup error, or gh merge failed
#       and the PR did not read MERGED (nothing merged as far as the script can tell; confirm with gh pr view
#       before retrying) · 3 MERGED, with a WARNING (base moved during the merge, the merge commit could not be
#       read, or gh pr merge failed but the PR reads MERGED, possibly merged by someone else or as a squash).
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: merge-one.sh <repo-dir> <PR> <graded-head-sha> [options]" >&2; exit 2; }
REPO=$1; PR=$2; GRADED=$3; shift 3
BASE_BRANCH=develop; CHECK=test; NOPR=""; GBASE=""
while [ $# -gt 0 ]; do case "$1" in
  --base|--check|--no-pr-check|--graded-base) [ $# -ge 2 ] && [ -n "$2" ] || { echo "$1 needs a value" >&2; exit 2; }
    case "$1" in --base) BASE_BRANCH=$2;; --check) CHECK=$2;; --no-pr-check) NOPR=$2;; --graded-base) GBASE=$2;; esac
    shift 2;;
  *) echo "unknown arg $1" >&2; exit 2;;
esac; done
[[ "$GRADED" =~ ^[0-9a-f]{12,40}$ ]] || { echo "graded head must be 12-40 hex chars" >&2; exit 2; }
[ -z "$NOPR" ] || [[ "$GBASE" =~ ^[0-9a-f]{12,40}$ ]] || { echo "--no-pr-check needs --graded-base <12-40 hex sha>" >&2; exit 2; }
cd "$REPO" || exit 2
git fetch -q origin || { echo "git fetch failed" >&2; exit 2; }
git fetch -q origin "pull/$PR/head" 2>/dev/null || true  # fork heads are not in refs/heads
J=$(gh pr view "$PR" --json state,isDraft,baseRefName,headRefOid,mergeable,statusCheckRollup) || exit 2
g() { jq -r "$1" <<<"$J"; }
die() { echo "REFUSED: $*" >&2; exit 1; }
[ "$(g .state)" = OPEN ] || die "state $(g .state)"
[ "$(g .isDraft)" = false ] || die "draft"
[ "$(g .baseRefName)" = "$BASE_BRANCH" ] || die "base is '$(g .baseRefName)', not $BASE_BRANCH (stacked? retarget first)"
HEAD=$(g .headRefOid)
case "$HEAD" in "$GRADED"*) ;; *) die "head is ${HEAD:0:8}, graded ${GRADED:0:8}: re-grade the new head";; esac
[ "$(g .mergeable)" = MERGEABLE ] || die "mergeable=$(g .mergeable)"
TIP=$(git rev-parse --verify -q "origin/$BASE_BRANCH^{commit}") || die "cannot resolve origin/$BASE_BRANCH"
pushed_at() {  # when the current base tip was pushed; falls back to its commit date (flagged)
  local t; t=$(gh api "repos/$NWO/activity?ref=$BASE_BRANCH&per_page=5" --jq "[.[] | select(.after==\"$TIP\")][0].timestamp // empty" 2>/dev/null)
  [ -n "$t" ] && echo "$t"; }
if [ -n "$NOPR" ]; then
  case "$TIP" in "$GBASE"*) ;; *) die "$BASE_BRANCH is ${TIP:0:8}, but the local suite graded a merge on ${GBASE:0:8}: re-grade";; esac
  echo "no PR check (repo runs none). Local evidence on base ${GBASE:0:12}: $NOPR"
else
  NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner) && [ -n "$NWO" ] || { echo "gh repo view failed" >&2; exit 2; }
  URL=$(jq -r --arg c "$CHECK" '.statusCheckRollup[]? | select((.name // .context)==$c) | (.detailsUrl // .targetUrl // "")' <<<"$J" | head -1)
  CO=$(jq -r --arg c "$CHECK" '.statusCheckRollup[]? | select((.name // .context)==$c) | (.conclusion // .state // "")' <<<"$J" | head -1)
  [ "$CO" = SUCCESS ] || die "check '$CHECK' is '${CO:-absent}'"
  RID=$(grep -oE '/runs/[0-9]+' <<<"$URL" | head -1 | cut -d/ -f3)
  [ -n "$RID" ] || die "cannot find the run behind check '$CHECK'"
  RJ=$(gh run view "$RID" --json headSha,createdAt) || die "cannot read run $RID"
  RS=$(jq -r .headSha <<<"$RJ"); RC=$(jq -r .createdAt <<<"$RJ")
  [[ "$RC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || die "run $RID has no usable createdAt ($RC)"
  [ "$RS" = "$HEAD" ] || die "check '$CHECK' graded ${RS:0:8}, not the head ${HEAD:0:8}"
  # If the base tip is already an ancestor of the graded head, the check graded a tree that contains it, so
  # when the tip was pushed does not matter. This also covers a tip GitHub's activity API never records
  # (seen 2026-10-21: a develop merge with no push record and no push run). It assumes <base> only moved
  # forward since the run started, so a force-push after the run start refuses. A missing object (exit 128)
  # refuses with its own message rather than falling through. The force-push probe is best-effort: it can only
  # reject, it relies on the same activity API that missed a push, and a branch delete-and-recreate is not
  # recorded as a force_push.
  git merge-base --is-ancestor "$TIP" "$HEAD" 2>/dev/null; ANC=$?
  [ "$ANC" -le 1 ] || die "cannot check whether $BASE_BRANCH tip ${TIP:0:8} is in head ${HEAD:0:8} (git exit $ANC): fetch the PR head and retry"
  if [ "$ANC" -eq 0 ]; then
    FP=$(gh api "repos/$NWO/activity?ref=$BASE_BRANCH&activity_type=force_push&per_page=5" \
          --jq "[.[] | select(.timestamp >= \"$RC\")] | length") || die "cannot read $BASE_BRANCH force-push activity"
    [[ "$FP" =~ ^[0-9]+$ ]] || die "unreadable $BASE_BRANCH force-push count ('$FP')"
    [ "$FP" -eq 0 ] || die "$BASE_BRANCH was force-pushed after the graded run started ($RC): re-grade"
    echo "graded: run $RID on ${RS:0:8} at $RC; $BASE_BRANCH tip ${TIP:0:8} is an ancestor of the graded head"
  else
    TIPT=$(pushed_at)
    [ -n "$TIPT" ] || die "no push record for $BASE_BRANCH tip ${TIP:0:8} in GitHub's activity API, and it is not an ancestor of the graded head, so whether it moved after the graded run can't be proven: re-grade (merge it in, push, wait for the check)"
    [ "$(date -d "$TIPT" +%s)" -le "$(date -d "$RC" +%s)" ] \
      || die "$BASE_BRANCH was pushed after the graded run ($TIPT > $RC): re-grade on the new $BASE_BRANCH (merge it in, push, wait for the check)"
    echo "graded: run $RID on ${RS:0:8} at $RC; $BASE_BRANCH tip ${TIP:0:8} pushed $TIPT"
  fi
fi
UNSURE=0
if ! gh pr merge "$PR" --merge --match-head-commit "$HEAD"; then
  # A timeout can land after GitHub already merged: re-read before calling it a failure.
  [ "$(gh pr view "$PR" --json state -q .state)" = MERGED ] \
    || { echo "gh pr merge failed and #$PR does not read MERGED; confirm with 'gh pr view $PR' before retrying" >&2; exit 2; }
  # Possibly merged by someone else (even as a squash), so never report a clean 0 from here.
  echo "WARNING: gh pr merge reported failure, but #$PR is MERGED (by this call or another); verify the merge by hand" >&2
  UNSURE=1
fi
# The merge pins only the head: <base> may have moved between the fetch above and the merge. Read OUR merge
# commit (not the base tip, which another PR may already have moved) and check its first parent.
MC=""
for i in 1 2 3; do
  MC=$(gh pr view "$PR" --json mergeCommit -q '.mergeCommit.oid // empty'); [ -n "$MC" ] && break; [ "$i" -lt 3 ] && sleep 3
done
git fetch -q origin "$BASE_BRANCH" || echo "WARNING: git fetch origin $BASE_BRANCH failed after the merge" >&2
MP=$( [ -n "$MC" ] && git rev-parse --verify "$MC^1" )
DONE="merged #$PR at ${HEAD:0:8}. Next: post-merge-verify.sh"
[ "$UNSURE" -eq 0 ] || DONE="merged #$PR (reconciled after a gh pr merge failure; not proven to be this call's merge). Next: post-merge-verify.sh"
if [ -z "$MC" ]; then
  echo "WARNING: merged, but GitHub returned no merge commit for #$PR; check its first parent was ${TIP:0:8} by hand" >&2
  echo "$DONE"; exit 3
elif [ -z "$MP" ]; then
  echo "WARNING: merged, but merge commit ${MC:0:8}'s first parent could not be read; check it was ${TIP:0:8} by hand" >&2
  echo "$DONE"; exit 3
elif [ "$UNSURE" -eq 1 ]; then
  # Not necessarily our merge: a squash or rebase by someone else also leaves the PR MERGED, so don't name a cause.
  echo "WARNING: merge commit ${MC:0:8} has first parent ${MP:0:8} (graded base tip ${TIP:0:8}); check the merge method and parents by hand" >&2
  echo "$DONE"; exit 3
elif [ "$MP" != "$TIP" ]; then
  echo "WARNING: merge commit ${MC:0:8}'s first parent is ${MP:0:8}, not the graded base tip ${TIP:0:8}: $BASE_BRANCH moved during the merge; re-run the suite on develop" >&2
  echo "$DONE"; exit 3
fi
echo "merged #$PR at ${HEAD:0:8} onto ${TIP:0:8}. Next: post-merge-verify.sh"
