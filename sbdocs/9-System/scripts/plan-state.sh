#!/usr/bin/env bash
# plan-state.sh — derive a plan's ACTUAL state from the machine, not from its prose.
#
# Why this exists (SBDEV-2968, 2026-08-20). That plan's `status:` field is 6,775 characters of
# hand-written prose. It said "implementation NOT started, working trees are now EMPTY" while the
# worktrees held 46 dirty paths carrying the finished implementation — the field was written at 12:19
# and was wrong by 12:22. Recovering the true state cost about an hour of measurement. Every fact in
# that hour was machine-derivable; none of it was recorded anywhere a tool could read.
#
# So: state is DERIVED here and prose is never trusted. The plan body stays the place for decisions
# and narrative; this is the place for "where is it actually".
#
# Each of the six sources this consults lies in its own direction, and the whole point is to print
# them SIDE BY SIDE so a disagreement is visible instead of averaged away:
#
#   plan frontmatter  — hand-written, unvalidated, stale the moment code lands
#   git               — says "nothing happened" while work sits uncommitted
#   verify (mono)     — grades the MAIN checkouts, which are on other branches
#   verify (shadow)   — grades the worktrees, but its rows go stale or pre-pass
#   test suites       — green is meaningless without the known-failure baseline
#   ClickUp           — one status spans "plan written" .. "code done, uncommitted"
#
# Usage:
#   plan-state.sh SBDEV-2968              # fast: docs + git + verify both roots  (~5s)
#   plan-state.sh SBDEV-2968 --fetch      # also fetch origin/develop first, for true base staleness
#   plan-state.sh SBDEV-2968 --tests      # also run the test suites               (minutes)
#   plan-state.sh SBDEV-2968 --all        # --fetch --tests
#
# Exit code is NOT a verdict — 0 means the probe ran. Read the output.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "FATAL: needs bash >= 4 (associative arrays, mapfile). You are on ${BASH_VERSION:-unknown}." >&2
  echo "       macOS /bin/bash is 3.2 — use \`brew install bash\` or run under a modern bash." >&2
  exit 2
fi
set -uo pipefail

MONO="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
TICKET="${1:-}"
DO_FETCH=0; DO_TESTS=0
shift || true
for a in "$@"; do
  case "$a" in
    --fetch) DO_FETCH=1 ;;
    --tests) DO_TESTS=1 ;;
    --all)   DO_FETCH=1; DO_TESTS=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done
if [ -z "$TICKET" ]; then
  echo "usage: plan-state.sh <TICKET|plan-basename> [--fetch] [--tests] [--all]" >&2
  exit 2
fi

b()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
warn(){ printf '\033[33m%s\033[0m\n' "$*"; }
bad() { printf '\033[31m%s\033[0m\n' "$*"; }
ok()  { printf '\033[32m%s\033[0m\n' "$*"; }

echo "═══ plan-state: $TICKET ═══"
dim "monorepo: $MONO   $( [ $DO_FETCH = 1 ] && echo '(fetching)' )$( [ $DO_TESTS = 1 ] && echo ' (running tests)' )"

# ── 1. the plan document ────────────────────────────────────────────────────────────────────────
b "1. Plan document"
mapfile -t PLANS < <(find "$MONO/sbdocs/1-Projects" "$MONO/sbdocs/4-Archieves" \
                          -name "${TICKET}*.md" -not -path '*/reviews/*' 2>/dev/null | sort)
if [ "${#PLANS[@]}" -eq 0 ]; then
  bad "  no plan doc found under 1-Projects/ or 4-Archieves/ for '$TICKET'"
  PLAN=""
else
  PLAN="${PLANS[0]}"
  [ "${#PLANS[@]}" -gt 1 ] && warn "  ${#PLANS[@]} candidates; using the first"
  for p in "${PLANS[@]}"; do
    loc=1-Projects; case "$p" in *4-Archieves*) loc=4-Archieves ;; esac
    echo "  ${p#$MONO/}   [$loc]"
  done
  # Frontmatter, first line only — a status field can be thousands of characters of narrative.
  fm() { sed -n '/^---$/,/^---$/p' "$PLAN" | grep -m1 "^$1:" | cut -d: -f2- | sed 's/^ *//'; }
  echo "  updated:     $(fm updated)"
  echo "  db_verified: $(fm db_verified)"
  st="$(fm status)"
  echo "  status:      ${st:0:150}$( [ ${#st} -gt 150 ] && echo " …[${#st} chars total]" )"
  [ "${#st}" -gt 400 ] && warn "  ⚠ status is ${#st} chars of prose — treat as narrative, not as state"
fi

# ── 2. worktrees and git ────────────────────────────────────────────────────────────────────────
b "2. Implementation worktrees (git is the only source that cannot be hand-edited)"
# -not -path '*/.verify-root/*': this script builds its own shadow root under .claude/worktrees/,
# and without the exclusion the probe discovers its own scratch directory and reports it as a repo.
mapfile -t WTS < <(find "$MONO/.claude/worktrees" -maxdepth 2 -mindepth 2 -type d -name "$TICKET" \
                        -not -path '*/.verify-root/*' 2>/dev/null | sort)
declare -A WT_FOR_REPO=()
if [ "${#WTS[@]}" -eq 0 ]; then
  warn "  none — nothing has been implemented in a worktree for this ticket"
else
  for wt in "${WTS[@]}"; do
    repo="$(basename "$(dirname "$wt")")"
    WT_FOR_REPO["$repo"]="$wt"
    [ $DO_FETCH = 1 ] && git -C "$wt" fetch -q origin develop 2>/dev/null
    br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    head="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)"
    ahead="$(git -C "$wt" rev-list --count origin/develop..HEAD 2>/dev/null || echo '?')"
    behind="$(git -C "$wt" rev-list --count HEAD..origin/develop 2>/dev/null || echo '?')"
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    printf '  %-18s %s @ %s\n' "$repo" "$br" "$head"
    printf '  %-18s %s commit(s) ahead of origin/develop, %s behind, %s uncommitted path(s)\n' "" "$ahead" "$behind" "$dirty"
    if [ "$ahead" = "0" ] && [ "$dirty" != "0" ]; then
      bad  "  ${repo}: WORK EXISTS BUT IS UNCOMMITTED — invisible to git log, CI, review and diffs;"
      bad  "  ${repo}: one stray checkout or worktree prune from being lost. Commit it."
    elif [ "$ahead" = "0" ] && [ "$dirty" = "0" ]; then
      dim  "  ${repo}: clean and level with develop — implementation not started here"
    elif [ "$dirty" != "0" ]; then
      warn "  ${repo}: $ahead committed, plus $dirty uncommitted path(s) on top"
    else
      ok   "  ${repo}: $ahead commit(s), clean tree"
    fi
    [ "$behind" != "0" ] && [ "$behind" != "?" ] && \
      warn "  ${repo}: base is $behind commit(s) STALE — re-verify before a PR (the SBDEV-2781 trap: the fix may already be on develop)"
    git -C "$wt" log --oneline origin/develop..HEAD 2>/dev/null | sed 's/^/      /'
  done
fi
[ $DO_FETCH = 0 ] && dim "  (base staleness is measured against the LAST FETCH; pass --fetch for a live answer)"

# ── 3. verify script, both roots ────────────────────────────────────────────────────────────────
# ⚠ Verify scripts DO NOT share a PROJECT_ROOT convention. Measured 2026-08-20 across the 44 scripts
# that define one: 37 expect the SUB-REPO root (…/v2/wms2-api) and 7 expect the MONOREPO root. Pass
# the wrong shape and every path assertion fails, which prints as a plausible wall of honest-looking
# reds — the first version of this probe did exactly that for SBDEV-3011 and reported 3 pass / 51 fail
# against a plan whose real score is 54 / 0. So the convention is DETECTED from the script, per script.
# Verify rows that shell out to `mvn`/`yarn` FAIL FOR WANT OF A BINARY when the toolchain is not on
# PATH, and a 127 records as an ordinary red — indistinguishable from unimplemented work. SBDEV-3011
# read as 49/5 instead of 54/0 for exactly this reason. Put the toolchain on PATH before grading.
TOOLPATH=""
for d in "$HOME/.sdkman/candidates/maven/current/bin" "$HOME/.sdkman/candidates/java/current/bin"; do
  [ -d "$d" ] && TOOLPATH="$TOOLPATH$d:"
done
if [ -s "$HOME/.nvm/alias/default" ]; then
  nvmv="$(cat "$HOME/.nvm/alias/default")"
  for d in "$HOME/.nvm/versions/node/v$nvmv"*/bin; do [ -d "$d" ] && TOOLPATH="$TOOLPATH$d:"; done
fi
[ -n "$TOOLPATH" ] && export PATH="$TOOLPATH$PATH"
command -v mvn >/dev/null || warn "  ⚠ mvn not on PATH — any mvn-dependent verify row will red spuriously"

b "3. Verify script — shadow root vs mono root"
VS=""
if [ -n "$PLAN" ]; then
  cand="$MONO/sbdocs/9-System/scripts/verify-$(basename "$PLAN" .md).sh"
  [ -f "$cand" ] && VS="$cand"
fi
if [ -z "$VS" ]; then
  VS="$(find "$MONO/sbdocs/9-System/scripts" -name "verify-${TICKET}*.sh" 2>/dev/null | head -1)"
fi
if [ -z "$VS" ] || [ ! -f "$VS" ]; then
  echo "  no verify script — expected for T2 and below (assertions live in JUnit/Jest); only a T3 plan opts into one"
else
  echo "  ${VS#$MONO/}"
  PR_DEFAULT="$(grep -m1 -oE 'PROJECT_ROOT="\$\{PROJECT_ROOT:-[^}]*\}"' "$VS" | sed 's/.*:-//; s/}"$//')"
  ROOTKIND=mono
  case "$PR_DEFAULT" in
    *'$('*)         ROOTKIND=mono ;;                  # computed from BASH_SOURCE — monorepo shape
    */v1/*|*/v2/*)  ROOTKIND=repo ;;
  esac
  TARGET_REPO="$(basename "$PR_DEFAULT")"
  dim "  PROJECT_ROOT convention: $ROOTKIND-rooted${PR_DEFAULT:+  (default: ${PR_DEFAULT#$MONO/})}"

  SHADOW_ARG=""; MONO_ARG=""
  if [ "$ROOTKIND" = repo ]; then
    # The script grades ONE repo and wants that repo's root. No symlink tree needed: point it straight
    # at the worktree. A multi-repo plan is only partly covered by such a script — say so.
    MONO_ARG="$PR_DEFAULT"
    if [ -n "${WT_FOR_REPO[$TARGET_REPO]:-}" ]; then
      SHADOW_ARG="${WT_FOR_REPO[$TARGET_REPO]}"
    fi
    echo "  grades repo: $TARGET_REPO$( [ "${#WT_FOR_REPO[@]}" -gt 1 ] && echo "  ⚠ this plan touches ${#WT_FOR_REPO[@]} repos — the script covers only this one" )"
  else
    # Monorepo-shaped: build a symlink mirror with every worktree'd repo swapped in, because the
    # script's default grades the MAIN checkouts, which sit on whatever branch you left them on.
    if [ "${#WTS[@]}" -gt 0 ]; then
      VROOT="$MONO/.claude/worktrees/.verify-root/$TICKET"
      rm -rf "$VROOT"; mkdir -p "$VROOT/v1" "$VROOT/v2"
      for p in "$MONO"/v1/*/ "$MONO"/v2/*/; do
        [ -d "$p" ] || continue
        ln -sfn "${p%/}" "$VROOT/$(basename "$(dirname "${p%/}")")/$(basename "${p%/}")"
      done
      ln -sfn "$MONO/sbdocs" "$VROOT/sbdocs"
      for repo in "${!WT_FOR_REPO[@]}"; do
        for v in v1 v2; do
          [ -e "$MONO/$v/$repo" ] && ln -sfn "${WT_FOR_REPO[$repo]}" "$VROOT/$v/$repo"
        done
      done
      SHADOW_ARG="$VROOT"
    fi
    MONO_ARG="$MONO"
  fi

  mono="$(PROJECT_ROOT="$MONO_ARG" bash "$VS" 2>&1 | grep -E '^Result:' | tail -1)"
  if [ -n "$SHADOW_ARG" ]; then
    shadow="$(PROJECT_ROOT="$SHADOW_ARG" bash "$VS" 2>&1 | grep -E '^Result:' | tail -1)"
  else
    shadow=""
  fi
  printf '  shadow (the worktree%s):  %s\n' "$( [ "$ROOTKIND" = mono ] && echo 's')" "${shadow:-<no worktree to grade>}"
  printf '  mono   (main checkout%s): %s\n' "$( [ "$ROOTKIND" = mono ] && echo 's')" "${mono:-<no Result line>}"

  # Which number is the answer depends on WHERE the work lives, and getting this backwards is easy:
  # for a MERGED plan the worktree is stale and the shadow root reads as "nothing implemented".
  work_in_wt=0
  for repo in "${!WT_FOR_REPO[@]}"; do
    a="$(git -C "${WT_FOR_REPO[$repo]}" rev-list --count origin/develop..HEAD 2>/dev/null || echo 0)"
    d="$(git -C "${WT_FOR_REPO[$repo]}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    { [ "$a" != "0" ] || [ "$d" != "0" ]; } && work_in_wt=1
  done
  if [ -n "$shadow" ] && [ "$shadow" = "$mono" ]; then
    if [ "$work_in_wt" = 0 ]; then
      dim  "  → IDENTICAL, and expected: no un-merged work in the worktree, so both roots hold the"
      dim  "    same content. This is the normal reading for a merged plan."
    else
      warn "  ⚠ IDENTICAL while the worktree DOES carry un-merged work — so either the roots are not"
      warn "    actually different or the script ignores PROJECT_ROOT. Neither number is evidence yet."
    fi
  elif [ "$work_in_wt" = 1 ]; then
    ok   "  → SHADOW is authoritative: the work lives in the worktree, un-merged."
  elif [ -n "$shadow" ]; then
    warn "  → MONO is authoritative: no worktree carries un-merged work, so the worktree is a stale"
    warn "    snapshot and its low score is not evidence of anything. If the plan says merged, grade"
    warn "    the checkout that contains the merge."
  fi
  dim "  reds worth checking by hand: a row naming the wrong file is a PERMANENT red that reads as"
  dim "  honest work-not-done (SBDEV-2968 F3/F4), and a row can pre-pass and assert nothing at all."
fi

# ── 4. suites ───────────────────────────────────────────────────────────────────────────────────
b "4. Test suites"
if [ $DO_TESTS = 0 ]; then
  dim "  skipped — pass --tests (minutes, not seconds)"
  dim "  green here means nothing without (a) the repo's known-failure baseline and (b) a mutation"
  dim "  check: on SBDEV-2968 a fail-OPEN mutant left 100/100 targeted tests green."
else
  for repo in "${!WT_FOR_REPO[@]}"; do
    wt="${WT_FOR_REPO[$repo]}"
    if [ -f "$wt/pom.xml" ]; then
      echo "  $repo (maven) …"
      JH="$HOME/.sdkman/candidates/java/21.0.11-ms"; MVN="$HOME/.sdkman/candidates/maven/3.9.15/bin"
      grep -q '<java.version>8' "$wt/pom.xml" 2>/dev/null && JH="$HOME/.sdkman/candidates/java/8.0.412-tem"
      out="$(cd "$wt" && JAVA_HOME="$JH" PATH="$MVN:$JH/bin:$PATH" \
              mvn -B -o test -Djacoco.skip=true -Dmaven.javadoc.skip=true 2>&1 | \
              grep -E 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+\s*$' | tail -1)"
      echo "    ${out:-<no summary — build likely failed before tests>}"
      # `mvn test` REWRITES this tracked file; leaving it dirty makes the next probe report phantom work.
      if ! git -C "$wt" diff --quiet -- src/test/resources/archunit_store/ 2>/dev/null; then
        git -C "$wt" checkout -- src/test/resources/archunit_store/ && dim "    (reverted archunit_store, which mvn mutates)"
      fi
      dim "    compare against the known baseline, not against zero — v2 develop carries 2 failures"
    elif [ -f "$wt/package.json" ] && [ -x "$wt/node_modules/.bin/jest" ]; then
      echo "  $repo (jest) …"
      out="$(cd "$wt" && node_modules/.bin/jest --ci 2>&1 | grep -E '^(Tests|Test Suites):' )"
      sed 's/^/    /' <<<"$out"
      dim "    compare the TESTS line, not the SUITES line — a suite that dies at import level leaves"
      dim "    'Tests: N passed' green while the exit code is red"
    else
      dim "  $repo: no runnable suite found (no pom.xml, no installed jest)"
    fi
  done
fi

# ── 5. what remains, split by whether a machine can answer it ──────────────────────────────────
b "5. Prerequisites still open (parsed from the plan's §5.1 table)"
if [ -n "$PLAN" ]; then
  # Rows read `| **P1** | … | **YES** |`; a closed one is struck through as `~~**P3**~~` or marked Done.
  found=0
  while IFS= read -r line; do
    id="$(sed -n 's/^| *\**\(P[0-9]\+\)\**.*/\1/p' <<<"$line")"
    [ -z "$id" ] && continue
    case "$line" in *'~~'*) continue ;; esac
    case "$line" in *'| Done |'*|*'Done |'*) continue ;; esac
    case "$line" in *'YES'*) found=1; echo "  $id  ${line:0:0}$(sed 's/^| *\**P[0-9]*\**  *| *//; s/ *|.*$//' <<<"$line" | cut -c1-110)" ;; esac
  done < <(grep -E '^\| *\*{0,2}P[0-9]+' "$PLAN")
  [ $found = 0 ] && dim "  none parsed (either all closed, or the plan does not use the §5.1 table shape)"
else
  dim "  no plan doc to parse"
fi

b "6. Not machine-knowable — these need a named owner, not another probe run"
cat <<'TXT'
  · anything CORS / browser-exposure — neither curl nor a same-origin unit test applies CORS
    filtering, so only a real browser reading the header from JS can confirm it
  · per-tenant DB audits across environments (dev/UAT/prd × each tenant) — and an empty result set
    is not self-evidently an all-clear: it can mean "the at-risk role has no exclusive holder here"
  · manual QA on a handheld / real device
  · mutation-checking the new assertions: break what each one protects, confirm red. A green suite
    is not evidence that the suite would notice the defect.
  · ClickUp status — not readable from bash. Open the ticket:
TXT
if [ -n "$PLAN" ]; then
  u="$(sed -n '/^---$/,/^---$/p' "$PLAN" | grep -m1 '^ticket_url:' | cut -d: -f2- | tr -d ' "')"
  [ -n "$u" ] && echo "      $u"
fi
echo
dim "probe complete — the exit code is not a verdict."
