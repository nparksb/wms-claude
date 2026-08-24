#!/usr/bin/env bash
# verify-SBDEV-2967-A-axios-403-denial-not-logout.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2967-A-axios-403-denial-not-logout.md
#
# Usage:
#   PROJECT_ROOT=/path/to/owl bash sbdocs/9-System/scripts/verify-SBDEV-2967-A-...sh
#
# PROJECT_ROOT is MONO-ROOTED — it must contain v2/wms2-web-ui. Against a per-ticket
# worktree, point it at a symlink shadow root or it grades the main checkout.
# (37 of 44 verify scripts want the SUB-REPO root; this one does not. Passing the
#  wrong shape reds every row as credible, honest-looking work-not-done.)
#
# Run BEFORE any change for the FAIL baseline. Acceptance is "Result: N pass, 0 fail".
#
# Helpers are hardened: the stock template's file_not_contains is `! grep ...`, which
# returns TRUE for a file that does not exist, false-greening every negative assertion
# about a NEW file. Each helper below requires the file to exist first.
set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
WEB="$PROJECT_ROOT/v2/wms2-web-ui"
API="$PROJECT_ROOT/v2/wms2-api"
SRC="$API/src/main/java/net/aim_ai/wms"
TST="$API/src/test/java/net/aim_ai/wms"

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 d=$2; shift 2
  if "$@" >/dev/null 2>&1; then printf "  PASS  %-9s %s\n" "$id" "$d"; PASS=$((PASS+1))
  else printf "  FAIL  %-9s %s\n" "$id" "$d"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-9s %s\n" "$1" "$2"; SKIP=$((SKIP+1)); }

file_exists()      { [ -f "$1" ]; }
dir_exists()       { [ -d "$1" ]; }
file_contains()    { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains(){ [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_contains_n()  { [ -f "$2" ] || return 1; local c; c=$(grep -cE "$1" "$2" 2>/dev/null || echo 0); [ "$c" -ge "$3" ]; }
tree_contains()    { [ -d "$2" ] || return 1; grep -rqE "$1" "$2"; }

AX="$WEB/plugins/axios.js"
# NOTE: the spec is axios-authz-403.spec.js, NOT axios.spec.js. The repo already has
# test/plugins/axios-auth-timing.spec.js (SBDEV-2554); a second file named axios.spec.js
# would read as the canonical one. An earlier draft of this script named the wrong file —
# a permanent red that reads as honest work-not-done.
SPEC="$WEB/test/plugins/axios-authz-403.spec.js"

echo; echo "SBDEV-2967-A — an authorization 403 must deny, not log out"; echo "PROJECT_ROOT=$PROJECT_ROOT"; echo

# --------------------------------------------------------------------------
echo "The fix"
# --------------------------------------------------------------------------
run A1 "plugins/axios.js exists"                            file_exists "$AX"
# THE defect: 403 must no longer be funnelled into the 401 retry/logout branch
# on the strength of its status alone.
run A2 "retryCondition discriminates on the authz header"   file_contains 'x-authz-denied' "$AX"
run A3 "  ... matched case-insensitively (axios lowercases response headers)" bash -c "
    f='$AX'; [ -f \"\$f\" ] || exit 1
    grep -qE \"headers\\[[\\\"']x-authz-denied[\\\"']\\]|headers\\.get\\([\\\"']x-authz-denied\" \"\$f\" ||
    grep -qiE 'toLowerCase\(\).*authz|authz.*toLowerCase\(\)' \"\$f\""
run A4 "  ... an authz denial returns false BEFORE awaitAuthReady" bash -c "
    f='$AX'; [ -f \"\$f\" ] || exit 1
    perl -0777 -ne 'exit 1 unless /x-authz-denied.*?return\s+false/s' \"\$f\""
# The SBDEV-2554 hardening must survive: a plain 401 still retries, and the
# init-window path is untouched.
run A5 "401 still enters the retry path (SBDEV-2554 preserved)"  file_contains 'status !== 401' "$AX"
run A6 "awaitAuthReady still called for non-authz failures"      file_contains 'awaitAuthReady' "$AX"
run A7 "the authenticated-session logout branch still exists"    file_contains '\$kc\.logout|kc\?\.logout' "$AX"
# The denial must be surfaced, not swallowed.
run A8 "the denial is surfaced to the operator"                  file_contains 'toast|notify|\$toast' "$AX"

# --------------------------------------------------------------------------
echo; echo "Tests"
# --------------------------------------------------------------------------
run T1 "axios plugin spec exists"                    file_exists "$SPEC"
run T2 "  ... asserts no retry on an authz 403"      file_contains 'doesNotRetryWhenXAuthzDeniedHeaderPresent' "$SPEC"
run T3 "  ... asserts the user is NOT logged out"    file_contains 'doesNotLogOutOnAnAuthorizationDenial' "$SPEC"
run T4 "  ... asserts a plain 401 still retries"     file_contains 'stillRetriesAPlain401WithoutTheHeader' "$SPEC"
run T5 "  ... asserts a HEADER-LESS 403 keeps today's behaviour" file_contains 'stillRetriesAHeaderlessForbidden' "$SPEC"
run T6 "  ... asserts case-insensitive header matching"          file_contains 'matchesTheHeaderRegardlessOfCase' "$SPEC"
run T7 "  ... pins that the terminal logout is unreachable"     file_contains 'anAuthorizationDenialNeverReachesTheTerminalLogout' "$SPEC"

# --------------------------------------------------------------------------
echo; echo "Inherited from SBDEV-2968 — the header contract this slice consumes"
# --------------------------------------------------------------------------
# If 2968 is ever reverted this slice is inert. These rows fail LOUDLY rather
# than letting the fix silently stop discriminating.
run X1 "Authority declares AUTHZ_DENIED_HEADER"       file_contains 'AUTHZ_DENIED_HEADER' "$SRC/Authority.java"
run X2 "the interceptor emits it on denial"           file_contains 'AUTHZ_DENIED_HEADER' "$SRC/security/FunctionGuardInterceptor.java"
run X3 "SecurityConfiguration exposes it via CORS"    file_contains 'AUTHZ_DENIED_HEADER' "$SRC/SecurityConfiguration.java"

# A red X row has TWO possible causes and they need opposite responses. Say which.
if ! grep -q 'AUTHZ_DENIED_HEADER' "$SRC/Authority.java" 2>/dev/null; then
  if git -C "$API" rev-parse --verify origin/develop >/dev/null 2>&1 &&
     git -C "$API" show origin/develop:src/main/java/net/aim_ai/wms/Authority.java 2>/dev/null |
       grep -q 'AUTHZ_DENIED_HEADER'; then
    behind=$(git -C "$API" rev-list --count HEAD..origin/develop 2>/dev/null || echo '?')
    echo
    echo "  ^^ X rows are red because THIS CHECKOUT IS STALE, not because 2968 is missing:"
    echo "     $API is $behind commit(s) behind origin/develop, which HAS the header."
    echo "     Fetch/rebase (or point PROJECT_ROOT at a current shadow root) and re-run."
  else
    echo
    echo "  ^^ X rows are red and origin/develop does NOT carry the header either."
    echo "     SBDEV-2968 may have been reverted — this slice is INERT until it is back."
  fi
fi

echo
echo "NOT machine-checkable — these need a browser, not this script:"
echo "  · that page JS can actually READ the header. curl applies no CORS policy and the"
echo "    DevTools Network panel renders unexposed headers anyway, so BOTH show the header"
echo "    even when JS cannot. Only headers.get('x-authz-denied') from the page discriminates."
echo "  · that the operator stays logged in through a real denial."
echo "  · mutation-check: restore the 'status !== 403' clause and confirm T2/T3 go RED."
echo
printf "Result: %d pass, %d fail, %d skip\n" "$PASS" "$FAIL" "$SKIP"
echo
[ "$FAIL" -eq 0 ]
