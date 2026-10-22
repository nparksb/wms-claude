#!/usr/bin/env bash
# post-merge-verify.sh: prove a merged PR reached its base branch, its CI passed, and (wms2-api) dev runs it.
#
# usage: post-merge-verify.sh <repo-dir> <PR> --marker <path>:<fixed-string> [--base <branch>] [--wait-run] [--wait-deploy]
#        post-merge-verify.sh <repo-dir> <PR> --no-marker ...      (only when no distinctive string exists; prints a warning)
#
# Checks, each a FAIL unless proven:
#   1. MERGED, into <base> (default develop). A PR merged into a stacked base is MERGED and never reaches
#      develop: the orphan trap.
#   2. The merge commit and the head are ancestors of origin/<base>.
#   3. Content: `git show origin/<base>:<path> | grep -F <string>`. Ancestry alone has lied (a revert on a
#      release cut; a rename).
#   4. EVERY workflow run on the merge commit: completed + success. Exit 3 if any are still running;
#      re-run with --wait-run to poll (up to ~30 min). A failed build after a passing test is often a
#      transient registry/Maven 5xx: read --log-failed, then 'gh run rerun <id> --failed'.
#   5. --wait-deploy (wms2-api only; repo identified by its GitHub name, not the directory): poll
#      https://wms-api.dev.sbo.li/api/public/version until the served SHA CONTAINS the merge commit. A
#      later merge deploying is fine; an exact-SHA match would false-red. Other repos have no deploy
#      probe; asking for one there is a FAIL, not a silent skip.
# Exit: 0 = all proven; 1 = a check failed; 3 = runs still in progress; 2 = usage/fetch error.
set -uo pipefail

REPO=${1:?usage}; PR=${2:?usage}; shift 2
MARKER=""; NOMARKER=0; WAITRUN=0; WAITDEP=0; BASE_BRANCH=develop
while [ $# -gt 0 ]; do case "$1" in
  --marker) MARKER=${2:?}; shift 2;;
  --no-marker) NOMARKER=1; shift;;
  --base) BASE_BRANCH=${2:?}; shift 2;;
  --wait-run) WAITRUN=1; shift;;
  --wait-deploy) WAITDEP=1; WAITRUN=1; shift;;
  *) echo "unknown arg $1" >&2; exit 2;;
esac; done
if [ -n "$MARKER" ]; then
  P=${MARKER%%:*}; S=${MARKER#*:}
  { [ -n "$P" ] && [ -n "$S" ] && [ "$P" != "$MARKER" ]; } || { echo "--marker must be <path>:<non-empty string>" >&2; exit 2; }
elif [ $NOMARKER -eq 0 ]; then
  echo "pass --marker <path>:<string only this PR adds> (or --no-marker, and say why in the report)" >&2; exit 2
fi
cd "$REPO" || exit 2
git fetch -q origin || { echo "git fetch failed" >&2; exit 2; }
NAME=$(gh repo view --json name -q .name 2>/dev/null)
FAIL=0; PEND=0
J=$(gh pr view "$PR" --json state,baseRefName,headRefOid,mergeCommit,mergedAt) || exit 2
STATE=$(jq -r .state <<<"$J"); BASE=$(jq -r .baseRefName <<<"$J")
HEAD=$(jq -r .headRefOid <<<"$J"); MC=$(jq -r '.mergeCommit.oid // empty' <<<"$J")
echo "#$PR ($NAME): $STATE into $BASE at $(jq -r '.mergedAt // "-"' <<<"$J"), merge commit ${MC:0:8}"
[ "$STATE" = MERGED ] || { echo "FAIL: not merged"; exit 1; }
[ -n "$MC" ] || { echo "FAIL: no merge commit recorded"; exit 1; }
[ "$BASE" = "$BASE_BRANCH" ] || { echo "FAIL: merged into '$BASE', not $BASE_BRANCH. Orphan risk: retarget/cherry-pick"; FAIL=1; }
for c in "$MC" "$HEAD"; do
  if git merge-base --is-ancestor "$c" "origin/$BASE_BRANCH" 2>/dev/null; then echo "ok:   ${c:0:8} is on origin/$BASE_BRANCH"
  else echo "FAIL: ${c:0:8} is NOT an ancestor of origin/$BASE_BRANCH"; FAIL=1; fi
done
if [ -n "$MARKER" ]; then
  N=$(git show "origin/$BASE_BRANCH:$P" 2>/dev/null | grep -c -F -- "$S")
  if [ "${N:-0}" -gt 0 ]; then echo "ok:   content '$S' present in $P on $BASE_BRANCH ($N)"
  else echo "FAIL: content '$S' NOT found in $P on $BASE_BRANCH"; FAIL=1; fi
else
  echo "WARN: no content check (--no-marker). Ancestry alone has been wrong before."
fi

runs() { gh run list --commit "$MC" --limit 50 --json databaseId,workflowName,event,status,conclusion \
           --jq '.[] | select(.event=="push") | "\(.databaseId)\t\(.workflowName)\t\(.status)\t\(.conclusion)"' 2>/dev/null; }
# A repo can have several push workflows on develop (wms2-mobile-ui has two) that queue at different
# moments, so "all completed" only counts once the SET of runs has stopped growing.
PREVN=-1
for i in $(seq 1 60); do
  R=$(runs); N=$(grep -c . <<<"$R")
  if [ -n "$R" ] && ! grep -qvP '\tcompleted\t' <<<"$R" && [ "$N" -eq "$PREVN" ]; then break; fi
  if [ -n "$R" ] && ! grep -qvP '\tcompleted\t' <<<"$R" && [ $WAITRUN -eq 0 ]; then
    AGE=$(( $(date +%s) - $(date -d "$(jq -r '.mergedAt' <<<"$J")" +%s) ))
    [ "$AGE" -gt 600 ] && break   # merged >10 min ago: every push workflow has long since queued
    sleep 45; R2=$(runs); [ "$(grep -c . <<<"$R2")" -eq "$N" ] && break; R=$R2; PEND=1; break
  fi
  [ $WAITRUN -eq 1 ] || break
  PREVN=$N; sleep 30
done
if [ -z "$R" ]; then
  echo "PEND: no push run found for ${MC:0:8} yet"; PEND=1
else
  while IFS=$'\t' read -r ID WF ST CO; do
    JOBS=$(gh run view "$ID" --json jobs --jq '[.jobs[] | "\(.name):\(if ((.conclusion // "") == "") then .status else .conclusion end)"] | join(" ")' 2>/dev/null)
    if [ "$ST" != completed ]; then echo "PEND: run $ID ($WF) is $ST  [$JOBS]"; PEND=1
    elif [ "$CO" = success ]; then echo "ok:   run $ID ($WF) success  [$JOBS]"
    else echo "FAIL: run $ID ($WF) $CO  [$JOBS]. A failed run skips the deploy: 'gh run view $ID --log-failed'; transient -> 'gh run rerun $ID --failed'"; FAIL=1
    fi
  done <<<"$R"
fi

if [ $WAITDEP -eq 1 ]; then
  if [ "$NAME" != wms2-api ]; then
    echo "FAIL: no deploy probe exists for '$NAME'. Verify the deploy by hand and record how (the UI repos have the :develop tag race)"; FAIL=1
  elif [ $PEND -eq 1 ] || [ $FAIL -eq 1 ]; then
    echo "skip deploy wait: runs not all successful"
  else
    for i in $(seq 1 30); do
      V=$(curl -s --max-time 10 https://wms-api.dev.sbo.li/api/public/version)
      SERVED=$(grep -oE 'develop-[0-9a-f]{40}' <<<"$V" | head -1 | cut -d- -f2)
      if [ -n "$SERVED" ] && { git cat-file -e "$SERVED^{commit}" 2>/dev/null || git fetch -q origin "$SERVED" 2>/dev/null; } \
         && git merge-base --is-ancestor "$MC" "$SERVED" 2>/dev/null; then
        echo "ok:   dev serves ${SERVED:0:8}, which contains ${MC:0:8}: $V"; break
      fi
      [ "$i" -eq 30 ] && { echo "FAIL: dev does not contain ${MC:0:8} after ~10 min: $V"; FAIL=1; }
      sleep 20
    done
  fi
fi
[ $FAIL -eq 1 ] && exit 1
[ $PEND -eq 1 ] && { echo "INCOMPLETE: runs still in progress; re-run with --wait-run"; exit 3; }
echo "ALL PROVEN"; exit 0
