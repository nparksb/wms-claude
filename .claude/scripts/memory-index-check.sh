#!/usr/bin/env bash
# memory-index-check.sh: SessionStart nudge to consolidate the auto-memory index before it overflows.
#
# Silent when everything is fine. Prints a SessionStart JSON notice when either:
#   - MEMORY.md is over WARN_BYTES (default 22500, about 92% of the 24.4 KB load limit; past the limit,
#     index lines are dropped from every session's context), or
#   - the last consolidation (stamp file .last-consolidation, a YYYY-MM-DD) is older than MAX_DAYS (default 35).
# After consolidating, re-stamp:  date +%F > ~/.claude/projects/-home-nampark-dev-wms-claude/memory/.last-consolidation
# How to consolidate: move each long cluster line into a hub-<topic>.md memory and point the index at it
# (done 2026-10-15: 26.3 KB -> 22.0 KB, 9 hubs, all 262 links still reachable). Archive the notes of shipped tickets.
set -uo pipefail
MEM=$HOME/.claude/projects/-home-nampark-dev-wms-claude/memory
IDX=$MEM/MEMORY.md
STAMP=$MEM/.last-consolidation
WARN_BYTES=${WARN_BYTES:-22500}; MAX_DAYS=${MAX_DAYS:-35}
[ -f "$IDX" ] || exit 0
SIZE=$(wc -c < "$IDX")
REASONS=()
[ "$SIZE" -gt "$WARN_BYTES" ] && REASONS+=("MEMORY.md is $SIZE bytes (warn at $WARN_BYTES; the load limit is about 24.4 KB, and lines past it are dropped)")
if [ -f "$STAMP" ] && LAST=$(date -d "$(head -1 "$STAMP")" +%s 2>/dev/null); then
  AGE=$(( ( $(date +%s) - LAST ) / 86400 ))
  [ "$AGE" -gt "$MAX_DAYS" ] && REASONS+=("last consolidation was $AGE days ago ($(head -1 "$STAMP"))")
else
  REASONS+=("no consolidation stamp at $STAMP")
fi
[ ${#REASONS[@]} -eq 0 ] && exit 0
MSG="Memory index needs consolidation: $(IFS='; '; echo "${REASONS[*]}"). Move long cluster lines into hub-<topic>.md memories, archive shipped-ticket notes, verify every previously linked memory is still reachable, then re-stamp with: date +%F > $STAMP"
python3 -I -c 'import json,sys; m=sys.argv[1]; print(json.dumps({"systemMessage": "⚠ " + m, "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": m}}))' "$MSG"
