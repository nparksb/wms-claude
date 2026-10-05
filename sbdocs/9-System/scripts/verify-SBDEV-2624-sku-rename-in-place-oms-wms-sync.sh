#!/usr/bin/env bash
# verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync.sh — machine-checkable acceptance for
# SBDEV-2624 (SKU rename in place, OMS <-> WMS sync). Built from verify-plan-template.sh.
#
# ONE row, by design (plan "## Acceptance", K-r2 #8). It covers the only invariant no test in
# either repo can see: the OMS resync guard recognises a WMS 108/109 failure by
#   str_starts_with($description, WmsApiService::WMS_RESYNC_MARKERS[i])
# where $description is the text the WMS builds in WmsConstants.getErrorCodeText(). The two
# strings live in different repos, so rewording either one silently turns the resync off.
#
#   R1  WMS_RESYNC_MARKERS[0] is a plain prefix of the getErrorCodeText() text for 108
#       (SKU_RENAME_PRECONDITION_FAILED), and [1] of the text for 109 (SKU_CONCURRENT_MODIFICATION).
#
# Fails closed when: either file is missing or unreadable, getErrorCodeText() or a case arm is not
# found, the constant is not found or is not a single-line list of exactly two plain literals, a
# literal carries an escape, or a marker is empty (an empty marker is a prefix of everything).
# No %Ns stripping (K-r3 #10): the markers end before the first placeholder.
#
# PROJECT_ROOT = monorepo-shaped root holding v2/wms2-api and v2/oms-laravel-api — a symlink shadow
# root pointing both at the SBDEV-2624 worktrees (recipe: wms-plan-executor "Baselines"). There is
# no default on purpose: run without it and it would grade the main checkouts.
#
#   PROJECT_ROOT=<shadow root> bash sbdocs/9-System/scripts/verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync.sh

set -u

[ -n "${PROJECT_ROOT:-}" ] || { echo "FATAL: PROJECT_ROOT is not set (point it at a shadow root)"; exit 2; }
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <command...> — one PASS/FAIL line, with the command's output indented
# below it so a green shows what was compared and a red says why.
run() {
    local id=$1 desc=$2 out
    shift 2
    if out=$("$@" 2>&1); then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
        printf '%s\n' "$out" | sed 's/^/          /'
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"
        printf '%s\n' "$out" | sed 's/^/          /'
        FAIL=$((FAIL+1))
    fi
}

WMS_CONSTANTS=v2/wms2-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java
OMS_SERVICE=v2/oms-laravel-api/app/Services/WmsApiService.php

check_R1_markers_prefix_wms_text() {
    python3 - "$WMS_CONSTANTS" "$OMS_SERVICE" <<'PY'
import re, sys
java_path, php_path = sys.argv[1], sys.argv[2]
def die(msg):
    print(msg); sys.exit(1)
try:
    java = open(java_path, encoding='utf-8').read()
    php = open(php_path, encoding='utf-8').read()
except OSError as e:
    die(f"cannot read: {e}")

# The text arm: the body of getErrorCodeText(...), up to the next method declaration.
m = re.search(r'static\s+String\s+getErrorCodeText\s*\(', java)
if not m: die(f"getErrorCodeText( not found in {java_path}")
body = java[m.end():]
nxt = re.search(r'\n\s*(public|private|protected)\s+static\s', body)
body = body[:nxt.start()] if nxt else body

def wms_text(const):
    arm = re.search(r'case\s+' + const + r'\s*:\s*description\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', body)
    if not arm: die(f"case {const}: description = \"...\"; not found in getErrorCodeText()")
    lit = arm.group(1)
    if '\\' in lit: die(f"{const} literal has an escape, refusing to guess: {lit!r}")
    return lit

c = re.search(r'const\s+WMS_RESYNC_MARKERS\s*=\s*\[([^\]\n]*)\]\s*;', php)
if not c: die(f"single-line const WMS_RESYNC_MARKERS = [...]; not found in {php_path}")
items = [s.strip() for s in c.group(1).split(',') if s.strip()]
markers = []
for it in items:
    q = re.fullmatch(r"'([^'\\]*)'|\"([^\"\\$]*)\"", it)
    if not q: die(f"WMS_RESYNC_MARKERS element is not a plain literal: {it}")
    markers.append(q.group(1) if q.group(1) is not None else q.group(2))
if len(markers) != 2: die(f"WMS_RESYNC_MARKERS has {len(markers)} elements, expected 2: {markers}")

ok = True
for marker, const, code in zip(markers, ['SKU_RENAME_PRECONDITION_FAILED', 'SKU_CONCURRENT_MODIFICATION'], [108, 109]):
    text = wms_text(const)
    if marker == '':
        print(f"{code}: marker is empty (prefix of everything)"); ok = False
    elif text.startswith(marker):
        print(f"{code}: {marker!r} prefixes {text!r}")
    else:
        print(f"{code}: {marker!r} is NOT a prefix of {text!r}"); ok = False
sys.exit(0 if ok else 1)
PY
}

echo
echo "verify-SBDEV-2624-sku-rename-in-place-oms-wms-sync — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  wms2 -> $(readlink "$PROJECT_ROOT/v2/wms2-api" 2>/dev/null || echo '(not a symlink)')"
echo "  oms  -> $(readlink "$PROJECT_ROOT/v2/oms-laravel-api" 2>/dev/null || echo '(not a symlink)')"
echo

run R1 "each OMS WMS_RESYNC_MARKERS entry prefixes its wms2 108/109 getErrorCodeText() text" check_R1_markers_prefix_wms_text

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
