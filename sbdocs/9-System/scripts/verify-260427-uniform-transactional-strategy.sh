#!/usr/bin/env bash
# verify-260427-uniform-transactional-strategy.sh
#
# Acceptance script for plan:
#   260427-uniform-transactional-strategy.md
#
# Encodes each stage as grep assertions so an implementer's "DONE" claim
# is provable, not prose. Run after every implementation pass:
#
#   $ bash sbdocs/9-System/scripts/verify-260427-uniform-transactional-strategy.sh
#
# Exit 0 only when every active check passes.
# Set SKIP_MVN=1 to skip maven test runs (faster local iteration).
# Set STAGE=1 (or 2, 3, 4) to run only one stage's checks.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-14s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-14s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-14s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_n()   {
    local pat=$1 file=$2 n=$3
    local c; c=$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)
    [ "$c" -ge "$n" ]
}
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false >/dev/null 2>&1
}

SVC=src/main/java/net/aim_ai/wms/service
MOB=$SVC/mobile
RES=src/main/resources

# ---------------------------------------------------------------------------
echo
echo "verify-260427-uniform-transactional-strategy"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  STAGE=${STAGE:-all}"
echo

# ===========================================================================
# STAGE 1 — rollbackFor on bare @Transactional
# ===========================================================================
if [ "${STAGE:-all}" = "all" ] || [ "${STAGE:-}" = "1" ]; then
echo "── Stage 1: rollbackFor on bare @Transactional ─────────────────────────"
echo

# --- Class-level Pattern A services -----------------------------------------

# POSITIVE: rollbackFor present on class-level annotation
run S1-A1-pos "CustomerorderService class-level has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/CustomerorderService.java"

# NEGATIVE: bare @Transactional (class-level) is gone — must not match annotation
#           with no arguments at the class level (the line immediately before @Service/@Component or class keyword)
run S1-A1-neg "CustomerorderService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/CustomerorderService.java"

run S1-A2-pos "BillofladingService class-level has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/BillofladingService.java"

run S1-A2-neg "BillofladingService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/BillofladingService.java"

run S1-A3-pos "TransferOrderService class-level has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/TransferOrderService.java"

run S1-A3-neg "TransferOrderService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/TransferOrderService.java"

run S1-A4-pos "CustomerorderBatchService class-level has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/CustomerorderBatchService.java"

run S1-A4-neg "CustomerorderBatchService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/CustomerorderBatchService.java"

echo

# --- Method-level Pattern B services (bare → rollbackFor) -------------------

run S1-B1-pos "StockunitBusinessService:~123 has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/StockunitBusinessService.java"

run S1-B1-neg "StockunitBusinessService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$SVC/StockunitBusinessService.java"

run S1-B3-pos "UnitloadBusinessService has rollbackFor (all 3 methods)" \
    file_contains_n '@Transactional\s*\(.*rollbackFor' "$SVC/UnitloadBusinessService.java" 3

run S1-B3-neg "UnitloadBusinessService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$SVC/UnitloadBusinessService.java"

run S1-B6-pos "PickingorderBusinessService:~222 has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/PickingorderBusinessService.java"

run S1-B6-neg "PickingorderBusinessService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$SVC/PickingorderBusinessService.java"

run S1-B7-pos "StockunitService:~106 has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/StockunitService.java"

run S1-B7-neg "StockunitService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$SVC/StockunitService.java"

run S1-B8-pos "MobileReplenishService has rollbackFor (both methods)" \
    file_contains_n '@Transactional\s*\(.*rollbackFor' "$MOB/MobileReplenishService.java" 2

run S1-B8-neg "MobileReplenishService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$MOB/MobileReplenishService.java"

run S1-B10-pos "MobileMoveUnitloadService:~182 has rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$MOB/MobileMoveUnitloadService.java"

run S1-B10-neg "MobileMoveUnitloadService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$MOB/MobileMoveUnitloadService.java"

echo

# --- REQUIRES_NEW preservation guard (must never be removed) ----------------

run S1-RN1 "SequenceTransactionService REQUIRES_NEW preserved" \
    file_contains 'REQUIRES_NEW' "$SVC/SequenceTransactionService.java"

run S1-RN2 "MessageService createMessageInNewTransaction REQUIRES_NEW preserved" \
    file_contains 'REQUIRES_NEW' "$SVC/MessageService.java"

run S1-RN3 "ReleaseOrderJobService REQUIRES_NEW preserved" \
    file_contains 'REQUIRES_NEW' "$SVC/job/ReleaseOrderJobService.java"

run S1-RN4 "ReplenishOrderJobService REQUIRES_NEW preserved (multiple)" \
    file_contains_n 'REQUIRES_NEW' "$SVC/job/ReplenishOrderJobService.java" 6

echo

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run S1-mvn  "mvn test passes (full suite)" mvn_test_passes "*"
else
    skip S1-mvn "Full mvn test suite" "SKIP_MVN=1"
fi
echo

fi # end STAGE 1

# ===========================================================================
# STAGE 2 — Phantom-TX services annotated
# ===========================================================================
if [ "${STAGE:-all}" = "all" ] || [ "${STAGE:-}" = "2" ]; then
echo "── Stage 2: phantom-transaction services annotated ─────────────────────"
echo

run S2-C1 "FixLocationAssignmentService has @Transactional" \
    file_contains '@Transactional' "$SVC/FixLocationAssignmentService.java"

run S2-C2 "ReceivingService has @Transactional" \
    file_contains '@Transactional' "$SVC/ReceivingService.java"

run S2-C3 "MobileCycleCountService has @Transactional" \
    file_contains '@Transactional' "$MOB/MobileCycleCountService.java"

run S2-C4 "StockrecordService has @Transactional" \
    file_contains '@Transactional' "$SVC/StockrecordService.java"

run S2-C5 "CyclecountService has @Transactional" \
    file_contains '@Transactional' "$SVC/CyclecountService.java"

run S2-C6 "MobileTruckLoadingService has @Transactional" \
    file_contains '@Transactional' "$MOB/MobileTruckLoadingService.java"

run S2-C7 "ReplenishmentOrderMaintenanceService has @Transactional" \
    file_contains '@Transactional' "$SVC/ReplenishmentOrderMaintenanceService.java"

run S2-C8 "ReplenishGeneratorService has @Transactional" \
    file_contains '@Transactional' "$SVC/ReplenishGeneratorService.java"

run S2-C9 "MobilePalletizingService has @Transactional" \
    file_contains '@Transactional' "$MOB/MobilePalletizingService.java"

run S2-C10 "ManageOrderService has @Transactional" \
    file_contains '@Transactional' "$SVC/ManageOrderService.java"

run S2-C12 "LosSyspropService has @Transactional on write methods" \
    file_contains '@Transactional' "$SVC/LosSyspropService.java"

# No bare annotations introduced by Stage 2
run S2-C1-nb "FixLocationAssignmentService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$SVC/FixLocationAssignmentService.java"

run S2-C2-nb "ReceivingService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$SVC/ReceivingService.java"

run S2-C3-nb "MobileCycleCountService no bare @Transactional" \
    file_not_contains '^\s+@Transactional$' "$MOB/MobileCycleCountService.java"

echo

fi # end STAGE 2

# ===========================================================================
# STAGE 3 — Class-level converted to method-level; readOnly=true on reads
# ===========================================================================
if [ "${STAGE:-all}" = "all" ] || [ "${STAGE:-}" = "3" ]; then
echo "── Stage 3: class-level → method-level; readOnly=true on reads ──────────"
echo

# POSITIVE: readOnly = true appears in each converted service
run S3-D1-ro "CustomerorderService has readOnly = true" \
    file_contains 'readOnly\s*=\s*true' "$SVC/CustomerorderService.java"

run S3-D2-ro "BillofladingService has readOnly = true" \
    file_contains 'readOnly\s*=\s*true' "$SVC/BillofladingService.java"

run S3-D3-ro "TransferOrderService has readOnly = true" \
    file_contains 'readOnly\s*=\s*true' "$SVC/TransferOrderService.java"

run S3-D4-ro "CustomerorderBatchService has readOnly = true" \
    file_contains 'readOnly\s*=\s*true' "$SVC/CustomerorderBatchService.java"

run S3-D5-ro "AdviceService has readOnly = true" \
    file_contains 'readOnly\s*=\s*true' "$SVC/AdviceService.java"

# NEGATIVE: no bare class-level @Transactional remaining (checked without the parens)
run S3-D1-neg "CustomerorderService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/CustomerorderService.java"

run S3-D2-neg "BillofladingService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/BillofladingService.java"

run S3-D3-neg "TransferOrderService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/TransferOrderService.java"

run S3-D4-neg "CustomerorderBatchService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/CustomerorderBatchService.java"

run S3-D5-neg "AdviceService no bare class-level @Transactional" \
    file_not_contains '^@Transactional$' "$SVC/AdviceService.java"

# POSITIVE: write methods still have rollbackFor after class-level removal
run S3-D2-wrt "BillofladingService write methods retain rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/BillofladingService.java"

run S3-D1-wrt "CustomerorderService write methods retain rollbackFor" \
    file_contains '@Transactional\s*\(.*rollbackFor' "$SVC/CustomerorderService.java"

# POSITIVE: runClubLine method-level override preserved in CustomerorderBatchService
run S3-D4-cb "CustomerorderBatchService runClubLine method-level override preserved" \
    file_contains 'rollbackFor.*BusinessException' "$SVC/CustomerorderBatchService.java"

echo

fi # end STAGE 3

# ===========================================================================
# STAGE 4 — OSIV disabled
# ===========================================================================
if [ "${STAGE:-all}" = "all" ] || [ "${STAGE:-}" = "4" ]; then
echo "── Stage 4: OSIV disabled ───────────────────────────────────────────────"
echo

run S4-E1-pos "application.properties sets spring.jpa.open-in-view=false" \
    file_contains 'spring\.jpa\.open-in-view\s*=\s*false' "$RES/application.properties"

run S4-E1-neg "application.properties does not have open-in-view=true" \
    file_not_contains 'spring\.jpa\.open-in-view\s*=\s*true' "$RES/application.properties"

echo

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run S4-mvn "mvn verify (full suite incl Testcontainers)" \
        bash -c "mvn verify -q >/dev/null 2>&1"
else
    skip S4-mvn "Full mvn verify" "SKIP_MVN=1"
fi

echo

fi # end STAGE 4

# ===========================================================================
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
