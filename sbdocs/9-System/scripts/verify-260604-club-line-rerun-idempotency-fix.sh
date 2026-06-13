#!/usr/bin/env bash
# verify-260604-club-line-rerun-idempotency-fix.sh
#
# Acceptance for `260604-club-line-rerun-idempotency-fix.md` (wms2).
#
# Fix A: ClubLineOrderProcessor.processOrder reconciles an existing package unit
#        load owned by the same order (reuse-on-reentry) with content re-validation,
#        instead of unconditionally throwing "Parcel label already in use".
# No orphan mutation / cleanup-on-rollback is added (see plan §3.3).
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-260604-club-line-rerun-idempotency-fix.sh
# Skip the mvn step (fast shape-only check):
#   $ SKIP_MVN=1 bash sbdocs/9-System/scripts/verify-260604-club-line-rerun-idempotency-fix.sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — perl -0777 so the regex can span newlines.
file_contains_ml() {
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}

SVC=src/main/java/net/aim_ai/wms/service
CLP=$SVC/ClubLineOrderProcessor.java

echo
echo "verify-260604-club-line-rerun-idempotency-fix — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- S1 — MeterRegistry dependency + Optional import (plan §3.1/§3.2) ----------

run S1a "S1 — ClubLineOrderProcessor imports java.util.Optional" \
    file_contains 'import\s+java\.util\.Optional;' "$CLP"
run S1b "S1 — MeterRegistry is a constructor-injected field" \
    file_contains 'private\s+final\s+MeterRegistry\s+meterRegistry' "$CLP"

echo

# --- S2 — reuse-on-reentry branch (plan §3.1) ---------------------------------
# The findByLabelidForUpdate result must be bound to an Optional and GATED by an
# ownership check, not thrown unconditionally.

# (multiline: the assignment may wrap across a newline after '=')
run S2a "S2 — findByLabelidForUpdate result bound to an Optional<Unitload>" \
    file_contains_ml 'Optional<Unitload>\s+\w+\s*=\s*[\s\S]{0,40}unitloadRepository\.findByLabelidForUpdate' "$CLP"
run S2b "S2 — ownership check: order.getParcelId()...equals(...getId())" \
    file_contains_ml 'order\.getParcelId\(\)[^;]*\.equals\([^;]*\.getId\(\)\)' "$CLP"
run S2c "S2 — idempotent re-run reuse path logs + returns the existing id" \
    file_contains_ml 'idempotent re-run[\s\S]{0,200}return\s+\w+\.getId\(\)' "$CLP"
run S2d "S2 — different-order conflict still throws 'Parcel label already in use'" \
    file_contains 'Parcel label already in use' "$CLP"

# GATED, not removed: the label-in-use throw must be PRECEDED by an ownership
# (getParcelId) check after findByLabelidForUpdate — i.e. it is no longer the
# unconditional first action. Discriminates old (no getParcelId between the lookup
# and the throw -> FAIL) from new (ownership gate in between -> PASS).
# Windows widened: the reuse + content-mismatch branches sit between the ownership
# check and the different-order throw. Old code had NO getParcelId between the lookup
# and the throw, so this still fails the pre-fix unconditional guard.
run S2e "S2 — 'Parcel label already in use' throw is gated by an ownership check" \
    file_contains_ml 'findByLabelidForUpdate[\s\S]{0,2000}getParcelId[\s\S]{0,2000}Parcel label already in use' "$CLP"

echo

# --- S3 — content re-validation helper (plan §3.1/§3.4c) ----------------------

run S3a "S3 — packageMatchesPositions helper present" \
    file_contains 'packageMatchesPositions\s*\(' "$CLP"
run S3b "S3 — helper reads UL contents via findByUnitloadId" \
    file_contains 'stockunitRepository\.findByUnitloadId\(' "$CLP"
run S3c "S3 — content-mismatch failure path present" \
    file_contains 'no longer match' "$CLP"
# Defensive: the helper must compare against the passed-in positions param, NOT re-query.
# (Review-only contract per plan §9.1; this catches the most likely wrong re-query.)
run S3d "S3 — helper does NOT re-query positions via findByOrderId" \
    file_not_contains 'customerorderPositionRepository\.findByOrderId' "$CLP"

echo

# --- S4 — observability counters (plan §3.2) ----------------------------------

run S4a "S4 — orphan_reused counter present" \
    file_contains 'wms2\.clubline\.orphan_reused' "$CLP"
run S4b "S4 — reuse_content_mismatch counter present" \
    file_contains 'wms2\.clubline\.reuse_content_mismatch' "$CLP"

echo

# --- Guardrail — cleanup-on-rollback was intentionally NOT added (plan §3.3) ---
# rollbackClubLineState must remain batch-state-only; no orphan delete/relabel wired in.
run G1 "G — no cleanupProcessedClubOrders method introduced (Fix B correctly dropped)" \
    file_not_contains 'cleanupProcessedClubOrders' "$SVC/CustomerorderBatchService.java"

echo

# --- Targeted unit test -------------------------------------------------------
mvn_test_passes() {
    local cls=$1
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-CLP "T — ClubLineOrderProcessorUnitTest passes" mvn_test_passes ClubLineOrderProcessorUnitTest
else
    skip T-mvn "Targeted unit-test run" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
