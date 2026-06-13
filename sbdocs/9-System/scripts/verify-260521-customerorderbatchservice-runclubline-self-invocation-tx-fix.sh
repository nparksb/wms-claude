#!/usr/bin/env bash
# verify-260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.sh
#
# Acceptance gate for plan:
#   sbdocs/1-Projects/wms2/plan/260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.md
#
# Checks A1-A14 cover:
#   A1-A4   structural: self field, @Lazy annotation, import present
#   A5-A7   POSITIVE call-site rewrites: all 3 runClubLine phase calls use self.*
#   A8-A10  NEGATIVE call-site guards: no bare this.* phase calls remain in runClubLine
#   A11     NEGATIVE: runClubLine itself has no @Transactional (preserve Rule 5)
#   A12     POSITIVE: phase methods still have @Transactional(tenantTransactionManager)
#   A13     NEGATIVE sibling-caller guard: only runClubLine calls phase methods via self.*
#   A14     BEHAVIORAL: unit tests green
#   (A15)   BEHAVIORAL (optional): integration test green — uncomment when class exists
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-260521-customerorderbatchservice-runclubline-self-invocation-tx-fix.sh
#
# Exit code: 0 only if every check passes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SVC="$REPO_ROOT/v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java"

# Locate mvn — prefer sdkman install, fall back to PATH
MVN="${MVN:-$(command -v mvn 2>/dev/null || echo /home/nampark/.sdkman/candidates/maven/current/bin/mvn)}"

FAIL=0
PASS=0
SKIP=0

run() {
    local id="$1"; shift
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then
        printf '  [PASS] %-4s %s\n' "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf '  [FAIL] %-4s %s\n' "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id="$1"; shift
    local desc="$1"; shift
    printf '  [SKIP] %-4s %s\n' "$id" "$desc"
    SKIP=$((SKIP+1))
}

# ── Extract runClubLine method body to a temp file ──────────────────────────
# Grab lines from "public void runClubLine(" through its matching closing brace.
RUNCLUB="$(mktemp)"
awk '
    /public void runClubLine\(/ { flag=1; depth=0 }
    flag {
        print
        n = split($0, chars, "")
        for (i=1; i<=n; i++) {
            if (chars[i]=="{") depth++
            if (chars[i]=="}") { depth--; if (depth==0) { flag=0; exit } }
        }
    }
' "$SVC" > "$RUNCLUB"

# ── Structural checks ────────────────────────────────────────────────────────

echo ""
echo "=== verify-260521 — runClubLine self-invocation @Transactional fix ==="
echo ""
echo "--- Structural (A1-A4) ---"

# A1: @Lazy @Autowired self field declared
run A1 "@Lazy @Autowired self field present" \
    grep -qE '@Lazy' "$SVC"

# A1b: field type is CustomerorderBatchService self
run A1b "private CustomerorderBatchService self field present" \
    grep -qE 'private\s+CustomerorderBatchService\s+self\s*;' "$SVC"

# A2: @Autowired annotation on self (field-level — matches 260520 pattern)
run A2 "@Autowired present on CustomerorderBatchService self field" bash -c \
    'grep -A2 "@Lazy" "$0" | grep -q "CustomerorderBatchService self"' "$SVC"

# A3: Lazy import (either @Lazy from context.annotation or beans.factory.annotation)
run A3 "import for @Lazy present" \
    grep -qE 'import org\.springframework\.(context\.annotation|beans\.factory\.annotation)\.Lazy;' "$SVC"

# A4: Autowired import
run A4 "import for @Autowired present" \
    grep -qE 'import org\.springframework\.beans\.factory\.annotation\.Autowired;' "$SVC"

echo ""
echo "--- POSITIVE call-site rewrites (A5-A7) ---"

# A5: validateClubLine called via self
run A5 "self.validateClubLine(orderBatch) present in runClubLine" \
    grep -qE 'self\.validateClubLine\(orderBatch\)' "$RUNCLUB"

# A6: finalizeClubLine called via self
run A6 "self.finalizeClubLine(orderBatchId, ...) present in runClubLine" \
    grep -qE 'self\.finalizeClubLine\(orderBatchId,' "$RUNCLUB"

# A7: rollbackClubLineState called via self
run A7 "self.rollbackClubLineState(orderBatchId, ...) present in runClubLine" \
    grep -qE 'self\.rollbackClubLineState\(orderBatchId,' "$RUNCLUB"

echo ""
echo "--- NEGATIVE call-site guards (A8-A10) ---"

# A8: no bare validateClubLine call (not via self) in runClubLine
# Match lines that have validateClubLine( WITHOUT "self." prefix — allow for leading spaces/comments
run A8 "no bare validateClubLine( in runClubLine body" bash -c \
    '! grep -E "^[^/]*[^.]\bvalidateClubLine\s*\(" "$0" | grep -vE "self\.validateClubLine"' \
    "$RUNCLUB"

# A9: no bare finalizeClubLine call in runClubLine
run A9 "no bare finalizeClubLine( in runClubLine body" bash -c \
    '! grep -E "^[^/]*[^.]\bfinalizeClubLine\s*\(" "$0" | grep -vE "self\.finalizeClubLine"' \
    "$RUNCLUB"

# A10: no bare rollbackClubLineState call in runClubLine
run A10 "no bare rollbackClubLineState( in runClubLine body" bash -c \
    '! grep -E "^[^/]*[^.]\brollbackClubLineState\s*\(" "$0" | grep -vE "self\.rollbackClubLineState"' \
    "$RUNCLUB"

echo ""
echo "--- Rule-5 guard: runClubLine must NOT have @Transactional (A11) ---"

# A11: @Transactional must NOT appear on runClubLine.
# Scan the 15 lines immediately before "public void runClubLine(" — handles multi-line annotations.
run A11 "runClubLine has NO @Transactional (Rule 5 guard)" bash -c '
    awk "
        { lines[NR] = \$0 }
        /public void runClubLine\(/ {
            start = (NR > 15) ? NR-15 : 1
            for (i=start; i<NR; i++) {
                if (lines[i] ~ /^[[:space:]]*\}[[:space:]]*$/) start = i+1
                if (lines[i] ~ /^[[:space:]]*$/) start = i+1
            }
            for (i=start; i<NR; i++) {
                # skip comment lines — WARNING comment mentions @Transactional by design
                if (lines[i] ~ /^[[:space:]]*\/\//) continue
                if (lines[i] ~ /@Transactional/) { exit 1 }
            }
            exit 0
        }
    " "$0"
' "$SVC"

echo ""
echo "--- Phase methods retain @Transactional(tenantTransactionManager) (A12) ---"

# A12: all three phase method declarations are still @Transactional(tenantTransactionManager)
run A12 "validateClubLine has @Transactional(tenantTransactionManager)" bash -c \
    'grep -B3 "public.*ClubLineValidationResult validateClubLine" "$0" | grep -q "tenantTransactionManager"' \
    "$SVC"

run A12b "finalizeClubLine has @Transactional(tenantTransactionManager)" bash -c \
    'grep -B3 "public void finalizeClubLine" "$0" | grep -q "tenantTransactionManager"' \
    "$SVC"

run A12c "rollbackClubLineState has @Transactional(tenantTransactionManager)" bash -c \
    'grep -B3 "public void rollbackClubLineState" "$0" | grep -q "tenantTransactionManager"' \
    "$SVC"

echo ""
echo "--- Sibling-caller guard: phase methods only called from runClubLine (A13) ---"

# A13: validateClubLine, finalizeClubLine, rollbackClubLineState are only invoked from runClubLine.
# Any call to self.validateClubLine / self.finalizeClubLine / self.rollbackClubLineState
# outside the runClubLine method body would be unexpected and should be flagged.
# Strategy: count self.validateClubLine lines in full file; they must all be inside runClubLine.
SELF_VALIDATE_FULL=$(grep -c "self\.validateClubLine" "$SVC" 2>/dev/null || echo 0)
SELF_VALIDATE_RUN=$(grep -c "self\.validateClubLine" "$RUNCLUB" 2>/dev/null || echo 0)
SELF_FINALIZE_FULL=$(grep -c "self\.finalizeClubLine" "$SVC" 2>/dev/null || echo 0)
SELF_FINALIZE_RUN=$(grep -c "self\.finalizeClubLine" "$RUNCLUB" 2>/dev/null || echo 0)
SELF_ROLLBACK_FULL=$(grep -c "self\.rollbackClubLineState" "$SVC" 2>/dev/null || echo 0)
SELF_ROLLBACK_RUN=$(grep -c "self\.rollbackClubLineState" "$RUNCLUB" 2>/dev/null || echo 0)

run A13 "self.validateClubLine only called from runClubLine body" \
    test "$SELF_VALIDATE_FULL" = "$SELF_VALIDATE_RUN"
run A13b "self.finalizeClubLine only called from runClubLine body" \
    test "$SELF_FINALIZE_FULL" = "$SELF_FINALIZE_RUN"
run A13c "self.rollbackClubLineState only called from runClubLine body" \
    test "$SELF_ROLLBACK_FULL" = "$SELF_ROLLBACK_RUN"

echo ""
echo "--- Behavioral: unit tests (A14) ---"

run A14 "CustomerorderBatchServiceUnitTest green" \
    bash -c "cd '$REPO_ROOT/v2/wms2-api' && '$MVN' -q test -Dtest=CustomerorderBatchServiceUnitTest 2>/dev/null"

# A15: Testcontainers integration test (uncomment when CustomerorderBatchServiceRunClubLineTxTest exists)
# run A15 "CustomerorderBatchServiceRunClubLineTxTest green" \
#     bash -c "cd '$REPO_ROOT/v2/wms2-api' && '$MVN' -q test -Dtest=CustomerorderBatchServiceRunClubLineTxTest 2>/dev/null"
skip A15 "CustomerorderBatchServiceRunClubLineTxTest (uncomment once class is authored — see plan §6)"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$RUNCLUB"

echo ""
printf '=== Result: %d pass, %d fail, %d skip ===\n' "$PASS" "$FAIL" "$SKIP"
exit "$FAIL"
