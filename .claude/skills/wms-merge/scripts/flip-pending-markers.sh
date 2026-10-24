#!/usr/bin/env bash
# flip-pending-markers.sh: flip a ticket's doc markers from pending to merged, once ALL its PRs are merged.
#
# usage: flip-pending-markers.sh <TICKET> "<merge note>" --prs "<repo-dir>:<PR> [<repo-dir>:<PR> ...]" [--apply]
#   e.g. flip-pending-markers.sh SBDEV-3755 "#510 ebb52109, #513 3734751f, 2026-10-15" \
#          --prs "v2/wms2-api:510 v2/wms2-api:513" --apply
#
# The convention (wms-plan-executor Phase 4): doc text describing code not yet on develop carries
#     ⏳ pending-merge(SBDEV-####)
# This flips each one to
#     ✓ merged(SBDEV-####: <merge note>)
# The token is per TICKET, so --prs must list EVERY PR of the ticket, in every repo, and all must be
# MERGED, or nothing is flipped. Otherwise the first of two PRs would mark everything merged.
#
# - Matching tolerates the variants editors and LLMs produce (⏳️ with U+FE0F, NBSP or extra spaces,
#   spaces inside the parens). Other near-misses (hyphenated "pending-merge" without the parens, the
#   ticket after the phrase, legacy free text) are LISTED for hand-editing, never auto-edited.
# - Skips 4-Archieves/, .trash/, .obsidian/, .omc/. Preserves CRLF/LF. Writes atomically.
# - Only *.md. A doc that QUOTES the convention with this real ticket number would be flipped too;
#   use SBDEV-#### in examples.
# - Without --apply: dry run. sbdocs/ is not git, so there is no undo.
set -uo pipefail

T=${1:?usage: flip-pending-markers.sh <TICKET> "<merge note>" --prs "<repo>:<PR> ..." [--apply]}
NOTE=${2:?merge note required}; shift 2
PRS=""; APPLY=0
while [ $# -gt 0 ]; do case "$1" in
  --prs) PRS=${2:?}; shift 2;;
  --apply) APPLY=1; shift;;
  *) echo "unknown arg $1" >&2; exit 2;;
esac; done
[ -n "$PRS" ] || { echo "--prs is required: every PR of $T, as <repo-dir>:<PR>" >&2; exit 2; }
# The MAIN checkout of the owl repo, whichever symlink, copy or git worktree this script runs from.
# Anchored on git's common dir, not on this file's path: run from a worktree copy of owl, a
# path-derived root would flip that worktree's sbdocs instead of the live vault in the main checkout.
# Keep in sync with the copy in .claude/scripts/ticket-lease.sh. Prints nothing (return 1) if it
# cannot be resolved; callers refuse on that.
main_root() {
  local src=${BASH_SOURCE[0]} d n=0 common
  while [ -L "$src" ] && [ $n -lt 20 ]; do   # follow symlinks; BSD readlink has no -f
    d=$(CDPATH= cd -P -- "$(dirname -- "$src")" >/dev/null && pwd) || return 1
    src=$(readlink -- "$src"); case "$src" in /*) ;; *) src=$d/$src;; esac; n=$((n+1))
  done
  [ -L "$src" ] && return 1                  # still a link after 20 hops: refuse, don't guess
  d=$(CDPATH= cd -P -- "$(dirname -- "$src")" >/dev/null && pwd) || return 1
  # cd into the common dir rather than --path-format=absolute: git < 2.31 echoes that flag back with
  # rc 0, which made the root "." (cwd-relative). git's own failure must stop here: `cd -- ""` is a
  # successful no-op in bash, so an unchecked empty answer resolved to this file's own directory.
  # env -u: a GIT_DIR/GIT_COMMON_DIR exported by a git hook would redirect git to another repo.
  local g; g=$(env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE git -C "$d" rev-parse --git-common-dir 2>/dev/null) && [ -n "$g" ] || return 1
  common=$(CDPATH= cd -- "$d" >/dev/null && CDPATH= cd -- "$g" >/dev/null && pwd -P) || return 1
  case "$common" in /*/.git) dirname -- "$common";; *) return 1;; esac
}
MONO=${MONO_ROOT:-$(main_root)} || { echo "cannot resolve the owl repo root; set MONO_ROOT" >&2; exit 2; }
[ -n "$MONO" ] || { echo "cannot resolve the owl repo root; set MONO_ROOT" >&2; exit 2; }
ROOT=${SBDOCS_ROOT:-$MONO/sbdocs}
# A missing root walks nothing and would report "0 flipped" as a clean run.
[ -d "$ROOT" ] || { echo "no sbdocs at $ROOT" >&2; exit 2; }

ALL=1
for rp in $PRS; do
  R=${rp%%:*}; N=${rp##*:}; case "$R" in /*) ;; *) R=$MONO/$R;; esac
  ST=$(cd "$R" 2>/dev/null && gh pr view "$N" --json state -q .state 2>/dev/null)
  echo "   PR $rp: ${ST:-NOT FOUND}"
  [ "$ST" = MERGED ] || ALL=0
done
[ $ALL -eq 1 ] || { echo "not all PRs of $T are MERGED: nothing flipped"; [ $APPLY -eq 1 ] && exit 1; }
# Completeness hint: PRs in the same repos that mention the ticket but are missing from --prs.
for R in $( { for rp in $PRS; do echo "${rp%%:*}"; done; echo v2/wms2-api v2/wms2-web-ui v2/wms2-mobile-ui v2/oms-laravel-api v2/siteboss-frontend | tr ' ' '\n'; } | sort -u); do
  RR=$R; case "$RR" in /*) ;; *) RR=$MONO/$RR;; esac
  for N in $(cd "$RR" 2>/dev/null && gh pr list --state all --search "$T" --limit 30 --json number,title,body --jq "[.[] | select(((.title // \"\") + \" \" + (.body // \"\")) | test(\"$T([^0-9]|$)\"))] | .[].number" 2>/dev/null); do
    grep -qw -- "$R:$N" <<<"$PRS" || echo "   WARN: $R #$N mentions $T but is not in --prs: is it one of this ticket's PRs?"
  done
done

python3 -I - "$ROOT" "$T" "$NOTE" "$APPLY" "$ALL" <<'EOF'
import os, re, sys, tempfile
root, t, note, apply_, allm = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == '1', sys.argv[5] == '1'
skip = ('/4-Archieves/', '/.trash/', '/.obsidian/', '/.omc/')
tid = re.escape(t) + r'(?![0-9])'
# ⏳ optionally followed by U+FE0F, then any run of spaces/NBSP, then the token with flexible inner spaces
std = re.compile('⏳️?[  ]*pending-merge\\([  ]*' + tid + '[  ]*\\)')
near = re.compile(r'(' + tid + r'.{0,80}(pending[- ]merge|not yet merged|unmerged|branch-pending)'
                  r'|(pending[- ]merge|not yet merged|branch-pending).{0,80}' + tid + r')', re.I)
new = '✓ merged(' + t + ': ' + note + ')'
flips = 0; files = 0; listed = []; pending = []; bad = []
for d, _, fs in os.walk(root):
    p0 = d.replace('\\', '/') + '/'
    if any(s in p0 for s in skip): continue
    for f in fs:
        if not f.endswith('.md'): continue
        p = os.path.join(d, f)
        try:
            with open(p, encoding='utf-8', newline='') as fh: s = fh.read()
        except UnicodeDecodeError:
            bad.append(os.path.relpath(p, root)); continue
        n = len(std.findall(s))
        if n:
            files += 1; flips += n
            print(f"   {n}  {os.path.relpath(p, root)}")
            pending.append((p, std.sub(lambda m: new, s)))   # lambda: a backslash in the note stays literal
        for i, line in enumerate(s.splitlines(), 1):
            if near.search(line) and not std.search(line):
                listed.append(f"   {os.path.relpath(p, root)}:{i}: {line.strip()[:200]}")
if bad:
    print("files skipped (not UTF-8; check them by hand):"); print('\n'.join('   ' + b for b in bad))
if apply_ and allm:   # phase 2: every file was read and computed above; only now write
    import shutil
    for p, s2 in pending:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix='.flip-')
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as out: out.write(s2)
        shutil.copymode(p, tmp)   # mkstemp is 0600; keep the doc's mode
        os.replace(tmp, p)
print(f"standard markers for {t}: {flips} in {files} file(s)" + ("  -> FLIPPED" if apply_ and allm else "  (dry run)" if not apply_ else ""))
print("near-misses / legacy free text (edit by hand; NOT auto-flipped):")
print('\n'.join(listed) if listed else "   none")
sys.exit(3 if bad else 0)   # a skipped file may still hold a marker: not a clean run
EOF
