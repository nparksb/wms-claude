#!/usr/bin/env bash
# ticket-lease.sh: one Claude session at a time per ticket's branches and worktrees (on this machine).
#
# usage: ticket-lease.sh claim   <TICKET> ["<what you're doing>"]   exit 0 = yours; 1 = held by another live session
#        ticket-lease.sh check   <TICKET>                           exit 0 = free, yours or stale; 1 = held by another live session
#        ticket-lease.sh release <TICKET> [--force]                 drops your lease (--force: someone else's)
#        ticket-lease.sh list
#
# Why: on 2026-10-15 a peer session rebased and pushed SBDEV-3736 while this one stacked SBDEV-3775 on the
# old local SHA, which left the stack orphaned and slipped pin rows into its path. Another session also
# removed the 3736 worktree mid-flight. ListAgents shows WHO is running, not WHAT they are touching.
#
# A lease records the owning session (CLAUDE_CODE_SESSION_ID), its Claude process (CLAUDE_PID) and when it
# was claimed or last refreshed (any `claim` by the owner refreshes it). It is STALE, and can be taken
# over, when the owner process is gone, when that PID now belongs to something that isn't `claude`, or when
# it is older than LEASE_MAX_HOURS (default 12) without a refresh.
#
# Limits:
# - This machine only. Cloud/remote sessions can't be seen; check ListAgents for those.
# - Subagents inherit their parent's session id, so a lease does NOT separate parallel lanes of one session.
#   Keep lanes out of each other's worktree by instruction (memory review-lanes-must-not-share-a-worktree).
# Leases live in .claude/worktrees/.leases/ (git-ignored). Every write is atomic (ln / rename).
set -uo pipefail
DIR=/home/nampark/dev/wms-claude/.claude/worktrees/.leases
MAXH=${LEASE_MAX_HOURS:-12}
mkdir -p "$DIR"
ME=${CLAUDE_CODE_SESSION_ID:-}; MYPID=${CLAUDE_PID:-}
CMD=${1:?usage: ticket-lease.sh claim|check|release|list ...}

field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
status() {  # $1 = lease file -> mine | live | stale
  local s p e; s=$(field "$1" session); p=$(field "$1" pid); e=$(field "$1" epoch)
  if [ -n "$ME" ] && [ "$s" = "$ME" ]; then echo mine; return; fi
  if [ -n "$e" ] && [ $(( $(date +%s) - e )) -gt $(( MAXH * 3600 )) ]; then echo stale; return; fi
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null && [ "$(ps -o comm= -p "$p" 2>/dev/null)" = claude ]; then echo live
  else echo stale; fi
}
show() { echo "   session=$(field "$1" session) pid=$(field "$1" pid) claimed=$(field "$1" claimed) note=$(field "$1" note)"; }
write_lease() {  # $1 = target tmp file, $2 = note (newlines/control chars stripped)
  local note; note=$(printf '%s' "$2" | tr -d '\000-\037')
  printf 'session=%s\npid=%s\nclaimed=%s\nepoch=%s\nnote=%s\n' "$ME" "$MYPID" "$(date -Is)" "$(date +%s)" "$note" > "$1"
}

case "$CMD" in
  list)
    shopt -s nullglob; any=0
    for f in "$DIR"/*; do [ -f "$f" ] || continue; any=1; echo "$(basename "$f"): $(status "$f")"; show "$f"; done
    [ $any -eq 1 ] || echo "no leases";;
  claim|check|release)
    T=${2:?ticket required}; [[ "$T" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad ticket id" >&2; exit 2; }
    F=$DIR/$T
    if [ "$CMD" = release ]; then
      [ -f "$F" ] || { echo "$T: no lease"; exit 0; }
      if [ "$(status "$F")" = mine ] || [ "${3:-}" = --force ]; then rm -f "$F"; echo "$T: released"; exit 0
      else echo "$T: held by another session; not yours to release (--force only if you know it's dead)"; show "$F"; exit 1; fi
    fi
    ST=free; [ -f "$F" ] && ST=$(status "$F")
    case "$ST" in
      live) echo "$T: HELD by another live session; coordinate (SendMessage) before touching its branch or worktree"; show "$F"; exit 1;;
      mine) if [ "$CMD" = claim ]; then   # refresh (note + time), atomically
              TMP=$(mktemp "$DIR/.$T.XXXXXX"); write_lease "$TMP" "${3:-$(field "$F" note)}"; mv -f "$TMP" "$F"; fi
            echo "$T: yours"; exit 0;;
      stale) echo "$T: stale lease (owner gone, PID reused, or older than ${MAXH}h)"; show "$F"
             [ "$CMD" = check ] && exit 0;;
      free) [ "$CMD" = check ] && { echo "$T: free"; exit 0; };;
    esac
    [ -n "$ME" ] || { echo "no CLAUDE_CODE_SESSION_ID in the environment; cannot claim" >&2; exit 2; }
    if [ "$ST" = stale ]; then
      # Only one claimant can rename the stale file away; the loser's mv fails because the source is gone.
      mv "$F" "$DIR/.stale.$T.$$" 2>/dev/null || { echo "$T: another session is taking over this stale lease; re-check"; exit 1; }
      rm -f "$DIR/.stale.$T.$$"
    fi
    TMP=$(mktemp "$DIR/.$T.XXXXXX"); write_lease "$TMP" "${3:-}"
    if ln "$TMP" "$F" 2>/dev/null; then rm -f "$TMP"
    else rm -f "$TMP"; echo "$T: claimed by another session a moment ago"; show "$F"; exit 1; fi
    [ "$(field "$F" session)" = "$ME" ] || { echo "$T: lost the race"; show "$F"; exit 1; }
    echo "$T: claimed";;
  *) echo "usage: ticket-lease.sh claim|check|release|list ..." >&2; exit 2;;
esac
