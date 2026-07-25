#!/usr/bin/env bash
# verify-SBDEV-2485-club-split-unitload-reprint-label-v2.sh
#
# Acceptance for the v2 plan:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2485-club-split-unitload-reprint-label.md
#
# Fix A: club staging-lane `printable` flag must reflect reprint eligibility
# — remaining stock AND active (NOT_LOCKED) — NOT goodsreceiptposition membership.
# The receiving-only query (findPrintableUnitLoadIds) and its threading through
# buildDtoList are removed.
#
# Run:
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2485-club-split-unitload-reprint-label-v2.sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains() { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line regex (spans newlines) via perl -0777 — require NOT_LOCKED ADJACENT to
# setPrintable (unique to the new code) rather than a bare file-scoped match.
file_contains_ml() { PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/; exit 1' "$2" 2>/dev/null; }
# Key off mvn's own exit code (non-zero on failure). Do NOT grep stdout: `-q`
# suppresses the reactor summary, and a pipe would discard mvn's exit status.
mvn_compiles()    { mvn -q clean compile >/dev/null 2>&1; }
mvn_test_passes() { mvn -q test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1; }

SVC=src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java
TEST=src/test/java/net/aim_ai/wms/unit/service/CustomerorderBatchServiceUnitTest.java

echo
echo "verify-SBDEV-2485 (v2) — club split-UL reprint eligibility"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Fix A positive -----------------------------------------------------------
run A-pos-stock "printable gated on remaining stock (entry.getValue() > 0)" \
    file_contains 'entry\.getValue\(\)\s*>\s*0' "$SVC"
run A-pos-lock  "printable gated on active UL (NOT_LOCKED adjacent to setPrintable)" \
    file_contains_ml 'setPrintable\([\s\S]{0,240}NOT_LOCKED|NOT_LOCKED[\s\S]{0,240}setPrintable\(' "$SVC"

# --- Fix A negatives (old receiving-only gate is gone) -------------------------
run A-neg1 "old goodsreceiptposition gate removed from setPrintable" \
    file_not_contains 'setPrintable\(printableUnitLoadIds\.contains\(' "$SVC"
run A-neg2 "findPrintableUnitLoadIds no longer called in the service" \
    file_not_contains 'findPrintableUnitLoadIds' "$SVC"
run A-param "buildDtoList no longer declares/threads printableUnitLoadIds" \
    file_not_contains 'printableUnitLoadIds' "$SVC"

# --- Test coverage ------------------------------------------------------------
run T-split  "split-UL printable test exists (no goodsreceiptposition -> printable)" \
    file_contains 'whenSplitUnitLoadHasStockAndNotLocked' "$TEST"
run T-locked "locked-UL test exists (entityLock != NOT_LOCKED -> not printable)" \
    file_contains 'shouldNotMarkPrintable_whenUnitLoadLocked' "$TEST"
run T-nostub "no leftover findPrintableUnitLoadIds Mockito stub in the test" \
    file_not_contains 'findPrintableUnitLoadIds\(anySet\(\)\)' "$TEST"

# --- Build + behavioral test --------------------------------------------------
run C-compile "mvn clean compile succeeds" mvn_compiles
run T-unit    "CustomerorderBatchServiceUnitTest passes" \
    mvn_test_passes CustomerorderBatchServiceUnitTest

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
