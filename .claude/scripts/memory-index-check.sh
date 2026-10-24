#!/usr/bin/env bash
# memory-index-check.sh: SessionStart nudge to consolidate the auto-memory index before it overflows.
#
# Silent when everything is fine. Prints a SessionStart JSON notice when either:
#   - MEMORY.md is over WARN_BYTES (default 22500, about 92% of the 24.4 KB load limit; past the limit,
#     index lines are dropped from every session's context), or
#   - the last consolidation (stamp file .last-consolidation, a YYYY-MM-DD) is older than MAX_DAYS (default 35).
# After consolidating, re-stamp:  date +%F > "$STAMP" (the exact path is printed in the notice)
# How to consolidate: move each long cluster line into a hub-<topic>.md memory and point the index at it
# (done 2026-10-15: 26.3 KB -> 22.0 KB, 9 hubs, all 262 links still reachable). Archive the notes of shipped tickets.
set -uo pipefail
# Claude Code names a project's memory dir after its path with every non-alphanumeric turned into '-'
# (/Users/np1076/dev/spk/owl -> -Users-np1076-dev-spk-owl). Was hardcoded to the Linux box's path, so on
# the Mac the `[ -f "$IDX" ] || exit 0` below exited silently while the index overflowed.
# Candidates, first one holding a MEMORY.md wins: the session's project dir, then owl's MAIN checkout
# (a session started from an owl worktree has a worktree-path project dir; whichever of the two Claude
# Code keys memory by, the index is found rather than silently skipped).
PROJ=${CLAUDE_PROJECT_DIR:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)}
[ -n "$PROJ" ] || exit 0
MAINP=$(CDPATH= cd -- "$PROJ" 2>/dev/null && CDPATH= cd -- "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd -P)
MEM=""
for P in "$PROJ" $MAINP; do
  C=$HOME/.claude/projects/$(printf '%s' "$P" | sed 's/[^A-Za-z0-9]/-/g')/memory
  [ -f "$C/MEMORY.md" ] && { MEM=$C; break; }
done
[ -n "$MEM" ] || exit 0
IDX=$MEM/MEMORY.md
STAMP=$MEM/.last-consolidation
WARN_BYTES=${WARN_BYTES:-22500}; MAX_DAYS=${MAX_DAYS:-35}
[ -f "$IDX" ] || exit 0
SIZE=$(wc -c < "$IDX" | tr -d ' ')   # BSD wc pads with spaces
REASONS=()
[ "$SIZE" -gt "$WARN_BYTES" ] && REASONS+=("MEMORY.md is $SIZE bytes (warn at $WARN_BYTES; the load limit is about 24.4 KB, and lines past it are dropped)")
D=$(head -1 "$STAMP" 2>/dev/null)
# GNU date -d, else BSD date -j -f (macOS); the regex keeps BSD from accepting trailing junk.
if [[ "$D" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && LAST=$(date -d "$D" +%s 2>/dev/null || date -j -f %Y-%m-%d "$D" +%s 2>/dev/null); then
  AGE=$(( ( $(date +%s) - LAST ) / 86400 ))
  [ "$AGE" -gt "$MAX_DAYS" ] && REASONS+=("last consolidation was $AGE days ago ($D)")
else
  REASONS+=("no consolidation stamp at $STAMP")
fi
[ ${#REASONS[@]} -eq 0 ] && exit 0
MSG="Memory index needs consolidation: $(IFS='; '; echo "${REASONS[*]}"). Move long cluster lines into hub-<topic>.md memories, archive shipped-ticket notes, verify every previously linked memory is still reachable, then re-stamp with: date +%F > $STAMP"
python3 -I -c 'import json,sys; m=sys.argv[1]; print(json.dumps({"systemMessage": "⚠ " + m, "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": m}}))' "$MSG"
