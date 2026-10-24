#!/usr/bin/env bash
# merge-preflight.sh: read-only readiness report for merging one or more PRs.
#
# usage: merge-preflight.sh [--base <branch>] <repo-dir> <PR> [<PR> ...]
#        --base defaults to develop. Use --base main for v2/siteboss-frontend (main IS its dev branch).
#
# Per PR it reports:
# - state, and base (STACKED if not the base branch);
# - mergeability;
# - each CI check with the head SHA its run graded and whether the base moved after that run;
# - STALE-OVERLAP: the base changed files this PR touches since the PR's merge-base;
# - a trial merge (CONFLICT + files);
# - Flyway version collisions.
# Across the PRs given it reports file overlap.
#
# ⚠ File overlap is NOT the semantic-conflict test. On 2026-10-15 the reds sat in DIFFERENT files: a
# rail added in one PR, a bare never() in another. Only a full suite on the actual merge catches that.
# Once any PR merges, every remaining PR's check graded a stale base (SKILL.md, rule 2).
#
# Changes nothing. Exit codes: 0 = report complete; 3 = report INCOMPLETE (a head could not be read);
# 2 = usage or fetch failure. Exit 0 is not a merge verdict; read the report.
set -uo pipefail

BASE_BRANCH=develop
[ "${1:-}" = --base ] && { BASE_BRANCH=${2:?--base needs a branch}; shift 2; }
REPO=${1:?usage: merge-preflight.sh [--base <branch>] <repo-dir> <PR> [<PR> ...]}
shift
[ $# -ge 1 ] || { echo "usage: merge-preflight.sh [--base <branch>] <repo-dir> <PR> [<PR> ...]" >&2; exit 2; }
for PR in "$@"; do [[ "$PR" =~ ^[0-9]+$ ]] || { echo "PR must be a number, not a branch or URL: $PR" >&2; exit 2; }; done
cd "$REPO" || exit 2
git fetch -q origin || { echo "git fetch failed" >&2; exit 2; }
BASE_REF=origin/$BASE_BRANCH
git rev-parse -q --verify "$BASE_REF" >/dev/null || { echo "no $BASE_REF" >&2; exit 2; }
GITV=$(git version | awk '{print $3}')
MT_OK=1; printf '2.38\n%s\n' "$GITV" | sort -V -C || MT_OK=0   # sorted ascending means 2.38 <= this git   # merge-tree --write-tree needs git >= 2.38
TIP=$(git rev-parse "$BASE_REF")
NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
TIP_TIME=$(gh api "repos/$NWO/activity?ref=$BASE_BRANCH&per_page=5" --jq "[.[] | select(.after==\"$TIP\")][0].timestamp // empty" 2>/dev/null)
TIP_SRC=pushed
[ -n "$TIP_TIME" ] || { TIP_TIME=$(TZ=UTC0 git log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd "$BASE_REF"); TIP_SRC="committed (no push record; push may be later)"; }
echo "repo: ${NWO:-$(basename "$(pwd)")}   $BASE_REF: ${TIP:0:8} ($TIP_SRC $TIP_TIME)   git $GITV"
echo
INCOMPLETE=0
# Per-PR maps kept as files: macOS ships bash 3.2, which has no associative arrays (declare -A).
KV=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }; trap 'rm -rf "$KV"' EXIT INT TERM
# A failed write marks the report incomplete: a lost entry silently skipped the cross-PR checks.
kv_set() { printf '%s\n' "$3" > "$KV/$1.$2" || { echo "   ** could not record $1 for #$2 **"; INCOMPLETE=1; }; }
kv_get() { cat "$KV/$1.$2" 2>/dev/null; }
# Strict UTC 'YYYY-MM-DDTHH:MM:SSZ' (every GitHub timestamp these scripts read) -> epoch seconds.
# GNU date takes -d; BSD/macOS needs -j -f. Anything else -- trailing junk, an offset, fractional
# seconds, an impossible date BSD would normalize (Feb 30 -> Mar 2), "" which GNU reads as today --
# prints nothing and returns 1, and every caller treats an empty value as "cannot decide".
epoch_of() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  local e; e=$(date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null) || return 1
  [ "$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" = "$1" ] || return 1
  printf '%s\n' "$e"
}
nonempty() { grep -c . || true; }

for PR in "$@"; do
  J=$(gh pr view "$PR" --json number,title,state,isDraft,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null) \
    || { echo "== #$PR: not found"; INCOMPLETE=1; continue; }
  get() { jq -r "$1" <<<"$J"; }
  HEAD=$(get .headRefOid); BASE=$(get .baseRefName); STATE=$(get .state)
  echo "== #$PR  $(get .title)"
  echo "   state: $STATE$( [ "$(get .isDraft)" = true ] && echo ' (DRAFT)')   head: ${HEAD:0:8} ($(get .headRefName))"
  if [ "$BASE" = "$BASE_BRANCH" ]; then
    echo "   base: $BASE_BRANCH"
  else
    BPR=$(gh pr list --head "$BASE" --state all --json number,state \
          --jq 'sort_by(if .state=="OPEN" then 0 elif .state=="MERGED" then 1 else 2 end) | map("#\(.number) \(.state)") | join(", ")' 2>/dev/null)
    echo "   base: $BASE  ** STACKED ** (PR(s) from that branch: ${BPR:-none})"
    echo "         merge the base PR first, then retarget: 'gh pr edit $PR --base $BASE_BRANCH' (deleteBranchOnMerge is off;"
    echo "         GitHub will NOT retarget). Re-trigger CI by pushing (merge $BASE_BRANCH in: fires 'synchronize')."
  fi
  echo "   mergeable: $(get .mergeable) / $(get .mergeStateStatus)"
  # checks: CheckRun has name/conclusion/status/detailsUrl; legacy StatusContext has context/state
  CHECKS=$(jq -r '.statusCheckRollup[]? | [(.name // .context // "?"),
      (if ((.conclusion // "") == "") then (.status // .state // "?") else .conclusion end),
      (.detailsUrl // .targetUrl // "")] | @tsv' <<<"$J")
  if [ -z "$CHECKS" ]; then
    echo "   checks: NONE (the PR conflicts, its base is not $BASE_BRANCH, or this repo runs no PR CI; see SKILL.md's repo table). Absent is not green."
  else
    while IFS=$'\t' read -r NAME RES URL; do
      RID=$(grep -oE '/runs/[0-9]+' <<<"$URL" | head -1 | cut -d/ -f3)
      if [ -n "$RID" ]; then
        RJ=$(gh run view "$RID" --json headSha,createdAt 2>/dev/null)
        RS=$(jq -r '.headSha // ""' <<<"$RJ"); RC=$(jq -r '.createdAt // ""' <<<"$RJ")
        NOTE=""
        [ -n "$RS" ] && [ "$RS" != "$HEAD" ] && NOTE=" ** graded ${RS:0:8}, not the current head **"
        TE=$(epoch_of "$TIP_TIME"); RE=$(epoch_of "$RC")
        [ -z "$RC" ] && NOTE="$NOTE ** cannot read run $RID: treat as stale **"
        [ -n "$RC" ] && { [ -z "$TE" ] || [ -z "$RE" ]; } && NOTE="$NOTE ** cannot compare $BASE_BRANCH push time with this run: treat as stale **"
        [ -n "$TE" ] && [ -n "$RE" ] && [ "$TE" -ge "$RE" ] && NOTE="$NOTE ** $BASE_BRANCH moved at or after this run ($TIP_TIME >= $RC; merge-one refuses a tie) **"
        echo "   check: $NAME = $RES  (run $RID on ${RS:0:8} at $RC)$NOTE"
      else
        echo "   check: $NAME = $RES"
      fi
    done <<<"$CHECKS"
  fi
  [ "$STATE" != OPEN ] && { echo; continue; }

  if ! git cat-file -e "$HEAD^{commit}" 2>/dev/null; then
    git fetch -q origin "pull/$PR/head" 2>/dev/null || git fetch -q origin "$HEAD" 2>/dev/null
  fi
  if ! git cat-file -e "$HEAD^{commit}" 2>/dev/null; then
    echo "   ** HEAD NOT AVAILABLE locally: overlap, stale and conflict checks NOT RUN for this PR (report incomplete) **"
    INCOMPLETE=1; echo; continue
  fi
  MB=$(git merge-base "$HEAD" "$BASE_REF" 2>/dev/null)
  [ -n "$MB" ] || { echo "   ** no merge-base with $BASE_REF: checks NOT RUN **"; INCOMPLETE=1; echo; continue; }
  PRFILES=$(git diff --no-renames --name-only "$MB" "$HEAD" | sort)
  kv_set FILES "$PR" "$PRFILES"
  echo "   files: $(nonempty <<<"$PRFILES")   $BASE_BRANCH commits since PR base: $(git rev-list --count "$MB..$BASE_REF")"
  MOVED=$(comm -12 <(echo "$PRFILES") <(git diff --no-renames --name-only "$MB" "$BASE_REF" | sort) | sed '/^$/d')
  if [ -n "$MOVED" ]; then
    echo "   ** STALE-OVERLAP **: $BASE_BRANCH changed $(nonempty <<<"$MOVED") file(s) this PR also touches since its base:"
    sed 's/^/         /' <<<"$MOVED" | head -15
    echo "         -> merge $BASE_BRANCH into the branch and run the FULL suite on the merge before trusting any check"
  fi
  if [ $MT_OK -eq 1 ]; then
    MTOUT=$(git merge-tree --write-tree --name-only "$BASE_REF" "$HEAD" 2>&1); MTRC=$?
    if [ $MTRC -eq 0 ]; then echo "   trial merge into $BASE_BRANCH: clean (textual only; says nothing about semantics)"
    elif [ $MTRC -eq 1 ]; then echo "   ** CONFLICT ** trial merge into $BASE_BRANCH:"; sed -n '2,/^$/p' <<<"$MTOUT" | sed '/^$/d;s/^/         /'
    else echo "   ** trial merge FAILED to run (rc=$MTRC): $(head -1 <<<"$MTOUT") **"; INCOMPLETE=1; fi
  else
    echo "   ** trial merge NOT RUN: git $GITV < 2.38 has no merge-tree --write-tree **"; INCOMPLETE=1
  fi
  # Flyway: versions this PR adds (db/migration and db/landlord-migration)
  V=$(grep -E '(^|/)db/(landlord-)?migration/V[^/]+__[^/]+\.sql$' <<<"$PRFILES" | sed -E 's#.*/(db/[^/]+)/V([^_]+)__.*#\1 \2#' | sort -u)
  if [ -n "$V" ]; then
    kv_set FLY "$PR" "$V"
    while read -r DIR VER; do
      [ -z "$VER" ] && continue
      ONBASE=$(git ls-tree --name-only "$BASE_REF" "src/main/resources/$DIR/" 2>/dev/null | grep -E "/V${VER}__" | grep -v -F "$(grep -E "$DIR/V${VER}__" <<<"$PRFILES")")
      MAX=$(git ls-tree --name-only "$BASE_REF" "src/main/resources/$DIR/" 2>/dev/null | sed -nE 's#.*/V([^_]+)__.*#\1#p' | sort -V | tail -1)
      MSG="   flyway: $DIR V$VER"
      [ -n "$ONBASE" ] && MSG="$MSG  ** COLLIDES with $BASE_BRANCH: $ONBASE **"
      [ -n "$MAX" ] && [ "$(printf '%s\n%s\n' "$VER" "$MAX" | sort -V | tail -1)" != "$VER" ] && MSG="$MSG  ** LOWER than $BASE_BRANCH max V$MAX: applies only with out-of-order enabled (wms2-api: app.flyway.out-of-order=true); confirm the ordering is intended **"
      echo "$MSG"
    done <<<"$V"
  fi
  echo
done

PRS=("$@")
if [ ${#PRS[@]} -gt 1 ]; then
  echo "== file overlap between the PRs given (NOT the semantic-conflict test; see header)"
  for ((i=0; i<${#PRS[@]}; i++)); do for ((j=i+1; j<${#PRS[@]}; j++)); do
    A=${PRS[i]}; B=${PRS[j]}
    FA=$(kv_get FILES "$A"); FB=$(kv_get FILES "$B")
    [ -n "$FA" ] && [ -n "$FB" ] || continue
    O=$(comm -12 <(echo "$FA") <(echo "$FB") | sed '/^$/d')
    [ -n "$O" ] && { echo "   #$A x #$B: $(nonempty <<<"$O") file(s)"; sed 's/^/      /' <<<"$O" | head -10; }
    YA=$(kv_get FLY "$A"); YB=$(kv_get FLY "$B")
    if [ -n "$YA" ] && [ -n "$YB" ]; then
      FC=$(comm -12 <(sort <<<"$YA") <(sort <<<"$YB") | sed '/^[[:space:]]*$/d')
      [ -n "$FC" ] && echo "   ** #$A x #$B: same Flyway version(s): $(tr '\n' ' ' <<<"$FC")**"
    fi
  done; done
fi
[ $INCOMPLETE -eq 1 ] && { echo; echo "REPORT INCOMPLETE: a PR could not be read or checked (see 'not found' / 'NOT RUN' / 'NOT AVAILABLE' lines above)"; exit 3; }
exit 0
