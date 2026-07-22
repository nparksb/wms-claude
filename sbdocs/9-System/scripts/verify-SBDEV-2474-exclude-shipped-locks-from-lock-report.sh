#!/usr/bin/env bash
# verify-SBDEV-2474-exclude-shipped-locks-from-lock-report.sh
# Machine-checkable acceptance for SBDEV-2474 (V2): exclude shipped (stockunitlock=405)
# locks from the default Lock Report, with an optional includeShipped toggle.
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2474-exclude-shipped-locks-from-lock-report.sh
#
# Exit 0 iff all checks pass. Spans two repos (wms2-api + wms2-web-ui).
#
# Design note (post-critic 2026-07-04): the two backend queries live in ONE file.
# The JPQL on-screen query (findByKeyword) and the native export query
# (findByClientOffsetAndLimit) MUST be verified INDEPENDENTLY, or the script can
# pass with the primary on-screen fix missing. They are distinguishable:
#   - JPQL predicate uses a NAMED param:      :includeShipped = TRUE
#   - JPQL signature uses:                    @Param("includeShipped")
#   - native predicate uses a POSITIONAL param: ?5  (COALESCE(?5, FALSE) = TRUE)
#   - native signature is single-line:        findByClientOffsetAndLimit(... includeShipped)
# Regexes use [[:space:]] (portable) rather than \s (GNU/ugrep-only).

set -u

API_ROOT="${API_ROOT:-/Users/np1076/dev/spk/owl/v2/wms2-api}"
UI_ROOT="${UI_ROOT:-/Users/np1076/dev/spk/owl/v2/wms2-web-ui}"

REPO="$API_ROOT/src/main/java/net/aim_ai/wms/repo/jpa/LockOverviewDtoViewRepository.java"
SVC="$API_ROOT/src/main/java/net/aim_ai/wms/service/ReportService.java"
CTRL="$API_ROOT/src/main/java/net/aim_ai/wms/controller/ReportController.java"
STORE="$UI_ROOT/store/reports/lock.js"
COMP="$UI_ROOT/components/reports/lockReport.vue"

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

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

# --- 3.1 findByKeyword (JPQL / on-screen) — INDEPENDENT of the native query ---
# Named-param signature + named-param predicate + 405 literal.
check_31_param()     { file_contains '@Param\("includeShipped"\)' "$REPO"; }
check_31_predicate() { file_contains ':includeShipped[[:space:]]*=[[:space:]]*TRUE' "$REPO"; }
check_31_405()       { file_contains ':includeShipped[[:space:]]*=[[:space:]]*TRUE.*405' "$REPO"; }   # named-param + 405 on same JPQL line

# --- 3.2 findByClientOffsetAndLimit (native / export) — INDEPENDENT of JPQL ---
# Positional-param predicate + updated method signature (single-line).
check_32_sig()       { file_contains 'findByClientOffsetAndLimit\([^)]*includeShipped' "$REPO"; }
check_32_predicate() { file_contains 'COALESCE\([[:space:]]*\?5[[:space:]]*,[[:space:]]*FALSE[[:space:]]*\)[[:space:]]*=[[:space:]]*TRUE|\?5[[:space:]]*=[[:space:]]*TRUE' "$REPO"; }
check_32_405()       { file_contains '\?5.*405' "$REPO"; }   # positional-param + 405 on same native line

# --- 3.3 service + controller passthrough ---
check_33_svc_param() { file_contains 'exporLockReport\([^)]*includeShipped|exporLockReport\([^{]*Boolean' "$SVC"; }
check_33_svc_pass()  { file_contains 'findByClientOffsetAndLimit\([^)]*includeShipped' "$SVC"; }
check_33_ctrl_read() { file_contains 'includeShipped' "$CTRL"; }
check_33_ctrl_pass() { file_contains 'exporLockReport\([^)]*includeShipped' "$CTRL"; }

# --- 3.4 UI store: search URL param + export payload prop (checked separately) ---
check_34_store_search() { file_contains "includeShipped=" "$STORE"; }                 # &includeShipped= in searchReport URL
check_34_store_export() { file_contains 'includeShipped[[:space:]]*:' "$STORE"; }      # includeShipped: in export payload object
check_34_dead_state()   { file_not_contains "&state='[[:space:]]*\+[[:space:]]*data\.state" "$STORE"; }
check_34_comp_toggle()  { grep -qiE 'includeShipped|include shipped' "$COMP"; }

echo
echo "verify-SBDEV-2474 — Lock Report shipped-exclusion acceptance"
echo "  API_ROOT=$API_ROOT"
echo "  UI_ROOT=$UI_ROOT"
echo

echo "  [3.1] on-screen query (findByKeyword / JPQL)"
run 3.1a  "  has @Param(includeShipped)"              check_31_param
run 3.1b  "  named-param predicate (:includeShipped)" check_31_predicate
run 3.1c  "  excludes SHIPPED (405) in JPQL"          check_31_405
echo
echo "  [3.2] export query (findByClientOffsetAndLimit / native)"
run 3.2a  "  signature takes includeShipped"          check_32_sig
run 3.2b  "  positional-param predicate (?5)"         check_32_predicate
run 3.2c  "  excludes SHIPPED (405) in native"        check_32_405
echo
echo "  [3.3] service + controller passthrough"
run 3.3a  "  ReportService.exporLockReport takes flag" check_33_svc_param
run 3.3b  "  service forwards flag to repo"            check_33_svc_pass
run 3.3c  "  ReportController reads includeShipped"    check_33_ctrl_read
run 3.3d  "  controller forwards to service"           check_33_ctrl_pass
echo
echo "  [3.4] web UI"
run 3.4a  "  store search URL sends includeShipped"    check_34_store_search
run 3.4b  "  store export payload carries flag"        check_34_store_export
run 3.4c  "  dead &state= param removed"               check_34_dead_state
run 3.4d  "  component has Include Shipped toggle"      check_34_comp_toggle

# Behavior (not just shape): uncomment once tests exist. A green shape-check does
# NOT prove the build compiles — run these before accepting DONE.
# run build-test "mvn compiles + lock tests pass" bash -c \
#   "cd '$API_ROOT' && mvn test -Dtest=LockOverviewDtoViewRepositoryTest,ReportServiceUnitTest,ReportControllerUnitTest -q 2>&1 | grep -qE 'BUILD SUCCESS'"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
