#!/usr/bin/env bash
# ============================================================================
# RETIRED 2026-08-03 — SUPERSEDED BY SBDEV-2778. DO NOT RUN.
#
# This script asserted that AdviceRestController does NOT auto-receive a RETURN
# advice. SBDEV-2778 deliberately restored that behavior on BA decision, so every
# negative assertion below now encodes a contract that no longer exists: running
# it would report failures that are the CORRECT current behavior.
#
# The regression value did not disappear — it moved. The kill-switch-OFF case is
# covered by AdviceRestControllerUnitTest#shouldCreateReturnAdviceWithoutAutoReceive
# and by verify-SBDEV-2778-…sh checks G1/G2/G3.
#
# Kept (not deleted) as the historical record of the SBDEV-2236 contract, since
# sbdocs/ is not under version control and a deletion here is unrecoverable.
# ============================================================================
echo "RETIRED: verify-SBDEV-2236 is superseded by SBDEV-2778 (2026-08-03). Not run."
echo "  See sbdocs/4-Archieves/wms2/plan/SBDEV-2236-return-advice-auto-receive-fix.md"
echo "  and sbdocs/9-System/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh"
exit 0
# ---------------------------------------------------------------------------
# Original script preserved below, unreachable.
# ---------------------------------------------------------------------------
# # verify-SBDEV-2236-return-advice-auto-receive-fix.sh
# #
# # Acceptance for plan `SBDEV-2236-return-advice-auto-receive-fix.md`.
# #
# # This plan removes the auto-receive block from AdviceRestController.create(...)
# # for RETURN-type advices (lines 286-354). After the fix, RETURN advices land in
# # AdviceState.OPEN and follow the same receive path as REGULAR (mobile /receive →
# # ReceivingService.receiveGoods). The fix is a pure deletion with no new code added.
# #
# # Checks encoded here:
# #   §A — NEGATIVE: auto-receive block constructs absent from AdviceRestController
# #   §B — POSITIVE: legitimate RETURN guards still present in AdviceRestController
# #   §C — NEGATIVE: stale broken tests absent from AdviceRestControllerUnitTest
# #   §D — POSITIVE: new/rewritten correct tests present in AdviceRestControllerUnitTest
# #   §E — mvn test run (skippable via SKIP_MVN=1)
# #
# # Usage:
# #   # From monorepo root:
# #   bash sbdocs/9-System/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh
# #
# #   # Against a non-default project root:
# #   PROJECT_ROOT=/path/to/v2/wms2-api bash sbdocs/9-System/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh
# #
# #   # Skip maven test invocation (code-shape checks only):
# #   SKIP_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh
# #
# # Exit code is 0 only when every check passes (FAIL count == 0).
# # The implementing agent's end-of-task report MUST paste this script's output.

# set -u

# PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
# cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

# PASS=0
# FAIL=0
# SKIP=0

# run() {
#     local id=$1 desc=$2
#     shift 2
#     if "$@" >/dev/null 2>&1; then
#         printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
#     else
#         printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
#     fi
# }

# skip() {
#     printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
# }

# file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
# file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }

# mvn_test_passes() {
#     mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 \
#         | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
# }

# CTRL=src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java
# TST=src/test/java/net/aim_ai/wms/unit/controller/rest/AdviceRestControllerUnitTest.java

# echo
# echo "verify-SBDEV-2236 — RETURN-advice auto-receive fix acceptance checks"
# echo "  PROJECT_ROOT=$PROJECT_ROOT"
# echo

# # ============================================================================
# # §A — NEGATIVE checks: auto-receive block constructs must be gone from controller
# #      AC1, AC2, AC3
# # ============================================================================

# run A1 "AC1 — receivingService.receiveGoods not called from AdviceRestController" \
#     file_not_contains 'receivingService\.receiveGoods\(' "$CTRL"

# run A2a "AC2a — printerRepository.findById not called from AdviceRestController" \
#     file_not_contains 'printerRepository\.findById\(' "$CTRL"

# run A2b "AC2b — printerRepository.findByTypeAndProcessdefaultTrue not called from AdviceRestController" \
#     file_not_contains 'printerRepository\.findByTypeAndProcessdefaultTrue\(' "$CTRL"

# run A3a "AC3a — updateAdviceToStateById(FINISHED) not called from AdviceRestController.create context" \
#     file_not_contains 'adviceRepository\.updateAdviceToStateById\(AdviceState\.FINISHED' "$CTRL"

# run A3b "AC3b — updateAdvicepositionToStateByAdviceId(FINISHED) not called from AdviceRestController" \
#     file_not_contains 'advicepositionRepository\.updateAdvicepositionToStateByAdviceId\(AdviceState\.FINISHED' "$CTRL"

# echo

# # ============================================================================
# # §B — POSITIVE checks: legitimate RETURN guards must remain intact
# #      AC4
# # ============================================================================

# run B1 "AC4 — enablereceiving guard still present for RETURN+TRANSFER in AdviceRestController" \
#     grep -qiE 'enablereceiving' "$CTRL"

# run B2 "B2  — setType(RETURN) still present (type-assignment path preserved)" \
#     file_contains 'setType\(AdviceType\.RETURN\)' "$CTRL"

# run B3 "B3  — AdviceRestController.java file still exists (sanity)" \
#     test -f "$CTRL"

# run B4 "B4  — AdviceRestControllerUnitTest.java file still exists (sanity)" \
#     test -f "$TST"

# echo

# # ============================================================================
# # §C — NEGATIVE checks: stale broken test methods must be deleted
# #      AC7
# # ============================================================================

# run C1 "AC7a — shouldReturnBadRequestWhenExplicitReturnPrinterIdNotFound deleted from test" \
#     file_not_contains 'shouldReturnBadRequestWhenExplicitReturnPrinterIdNotFound' "$TST"

# run C2 "AC7b — shouldReturnBadRequestWhenExplicitPrinterIdIsNotReturnType deleted from test" \
#     file_not_contains 'shouldReturnBadRequestWhenExplicitPrinterIdIsNotReturnType' "$TST"

# run C3 "C3  — shouldCreateReturnAdviceAndAutoReceiveGoods renamed (old name gone)" \
#     file_not_contains 'shouldCreateReturnAdviceAndAutoReceiveGoods' "$TST"

# run C4 "C4  — shouldCreateReturnAdviceWithExplicitPrinterIdAndAutoReceiveGoods renamed (old name gone)" \
#     file_not_contains 'shouldCreateReturnAdviceWithExplicitPrinterIdAndAutoReceiveGoods' "$TST"

# echo

# # ============================================================================
# # §D — POSITIVE checks: new and rewritten test methods must exist
# #      AC5, AC6, and new tests from §6
# # ============================================================================

# run D1 "AC5 — shouldCreateReturnAdviceInOpenState test exists" \
#     file_contains 'shouldCreateReturnAdviceInOpenState' "$TST"

# run D2 "AC6 — shouldNotInvokeReceivingServiceForReturnAdvice test exists" \
#     file_contains 'shouldNotInvokeReceivingServiceForReturnAdvice' "$TST"

# run D3 "D3  — shouldNotMarkAdviceFinishedOnCreate test exists" \
#     file_contains 'shouldNotMarkAdviceFinishedOnCreate' "$TST"

# run D4 "D4  — shouldCreateReturnAdviceWithoutAutoReceive test exists (renamed from auto-receive)" \
#     file_contains 'shouldCreateReturnAdviceWithoutAutoReceive' "$TST"

# run D5 "D5  — shouldCreateReturnAdviceIgnoresPrinterId test exists (renamed from explicit-printer)" \
#     file_contains 'shouldCreateReturnAdviceIgnoresPrinterId' "$TST"

# run D6 "D6  — new tests use verify(receivingService, never()) pattern" \
#     file_contains 'verify\(receivingService,\s*never\(\)\)' "$TST"

# echo

# # ============================================================================
# # §E — Targeted maven test run (skip with SKIP_MVN=1)
# #      AC8
# # ============================================================================

# if [ "${SKIP_MVN:-0}" = "0" ]; then
#     run E1 "AC8 — AdviceRestControllerUnitTest passes (mvn test)" \
#         mvn_test_passes AdviceRestControllerUnitTest
# else
#     skip E1 "AC8 — AdviceRestControllerUnitTest mvn test run" "SKIP_MVN=1 set"
# fi

# echo
# echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
# [ "$FAIL" -eq 0 ]
