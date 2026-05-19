#!/usr/bin/env bash
# verify-SBDEV-2233-nametypeservice-date-format-pattern-fix.sh
# Machine-checkable acceptance for SBDEV-2233.
#
# Validates:
#   Fix A — NameTypeService.java:22 uses 'T'HH (24-hour) not 'T'hh (12-hour)
#   Fix B — FileExportService.java uses static CELL_TIMESTAMP_FORMAT with yyyy (calendar year)
#           and the old `new SimpleDateFormat("YYYY-MM-dd ...")` allocations are gone
#   Fix C — Dead `import java.text.SimpleDateFormat;` removed from 3 service files
#   T1/T2 — Targeted unit tests pass
#   R1   — Repo-wide hardening grep returns 0 hits for the deprecated patterns
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2233-nametypeservice-date-format-pattern-fix.sh
#
# Override default project root:
#   PROJECT_ROOT=/path/to/v2/wms2-api bash sbdocs/9-System/scripts/verify-SBDEV-2233-...sh

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1
    local desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1
    local desc=$2
    local reason=$3
    printf "  SKIP  %-8s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- assertion helpers ---
file_contains()      { grep -qE "$1" "$2"; }
file_not_contains()  { ! grep -qE "$1" "$2"; }
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3
    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}
mvn_test_passes() {
    local test_class=$1
    local mvn_bin
    mvn_bin=$(command -v mvn 2>/dev/null || echo "/home/nampark/.sdkman/candidates/maven/current/bin/mvn")
    "$mvn_bin" test -Dtest="$test_class" -DfailIfNoTests=false 2>&1 \
        | grep -qE "BUILD SUCCESS"
}

# --- file paths ---
NTS="src/main/java/net/aim_ai/wms/service/NameTypeService.java"
FES="src/main/java/net/aim_ai/wms/service/FileExportService.java"
SUS="src/main/java/net/aim_ai/wms/service/StockunitService.java"
MRS="src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java"
MPS="src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java"

# === Fix A — NameTypeService hh → HH ==========================================

check_A1_24hour_pattern_present() {
    # Positive: new 24-hour pattern present.
    file_contains "'T'HH:mm:ss\\.SSSZ" "$NTS"
}

check_A2_12hour_pattern_gone() {
    # Negative: old 12-hour pattern gone.
    file_not_contains "'T'hh:mm" "$NTS"
}

# === Fix B — FileExportService YYYY → yyyy, static formatter ==================

check_B1_static_formatter_declared() {
    # Positive: a static DateTimeFormatter field named CELL_TIMESTAMP_FORMAT exists.
    file_contains "static final DateTimeFormatter[[:space:]]+CELL_TIMESTAMP_FORMAT" "$FES"
}

check_B1b_calendar_year_pattern() {
    # Positive: the field uses lowercase yyyy + HH (calendar year + 24-hour).
    file_contains "yyyy-MM-dd HH:mm:ss\\.SSS" "$FES"
}

check_B2_week_year_pattern_gone() {
    # Negative: old YYYY week-year pattern is gone from the file.
    file_not_contains "YYYY-MM-dd" "$FES"
}

check_B3_simpledateformat_allocation_gone() {
    # Negative: no more `new SimpleDateFormat(` calls anywhere in this file.
    file_not_contains "new SimpleDateFormat\\(" "$FES"
}

check_B4_fileexport_import_gone() {
    # Negative: import becomes dead after Fix B removes the 4 allocations.
    file_not_contains "^import java\\.text\\.SimpleDateFormat;" "$FES"
}

# === Fix C — Dead imports of SimpleDateFormat removed =========================

check_C1_stockunit_import_gone() {
    file_not_contains "^import java\\.text\\.SimpleDateFormat;" "$SUS"
}

check_C2_mobilereplenish_import_gone() {
    file_not_contains "^import java\\.text\\.SimpleDateFormat;" "$MRS"
}

check_C3_mobilepicking_import_gone() {
    file_not_contains "^import java\\.text\\.SimpleDateFormat;" "$MPS"
}

# === R1 — Repo-wide hardening =================================================

check_R1_no_deprecated_patterns_repo_wide() {
    # Project-wide negative: neither deprecated pattern should remain anywhere in src/main/java.
    # If grep finds anything, exit non-zero; if it finds nothing, grep exits 1 → invert.
    ! grep -rnE "'T'hh:mm|YYYY-MM-dd" src/main/java >/dev/null 2>&1
}

check_R1b_no_service_field_simpledateformat() {
    # No `private ... SimpleDateFormat` field on any service class (thread-safety hygiene).
    ! grep -rnE "private[[:space:]]+(static[[:space:]]+)?(final[[:space:]]+)?SimpleDateFormat[[:space:]]" \
        src/main/java/net/aim_ai/wms/service >/dev/null 2>&1
}

# === Run all checks ==========================================================

echo
echo "verify-SBDEV-2233 — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A1   "NameTypeService.java:22 uses 'T'HH (24-hour)"                check_A1_24hour_pattern_present
run A2   "NameTypeService.java has no 'T'hh (12-hour gone)"            check_A2_12hour_pattern_gone

run B1   "FileExportService has static CELL_TIMESTAMP_FORMAT field"    check_B1_static_formatter_declared
run B1b  "FileExportService formatter uses yyyy-MM-dd HH:mm:ss.SSS"    check_B1b_calendar_year_pattern
run B2   "FileExportService has no YYYY-MM-dd (week-year gone)"        check_B2_week_year_pattern_gone
run B3   "FileExportService has no 'new SimpleDateFormat(' left"       check_B3_simpledateformat_allocation_gone
run B4   "FileExportService SimpleDateFormat import removed"           check_B4_fileexport_import_gone

run C1   "StockunitService.java SimpleDateFormat import removed"       check_C1_stockunit_import_gone
run C2   "MobileReplenishService.java SimpleDateFormat import removed" check_C2_mobilereplenish_import_gone
run C3   "MobilePickingService.java SimpleDateFormat import removed"   check_C3_mobilepicking_import_gone

run R1   "Repo-wide: no 'T'hh:mm or YYYY-MM-dd patterns in src/main/java"  check_R1_no_deprecated_patterns_repo_wide
run R1b  "No 'private SimpleDateFormat' field on any service class"       check_R1b_no_service_field_simpledateformat

# Targeted JUnit tests — code-shape greps prove existence; the test proves behaviour.
# Comment out / uncomment as appropriate; default to running both:
run T1   "NameTypeServiceUnitTest passes"   mvn_test_passes NameTypeServiceUnitTest
run T2   "FileExportServiceUnitTest passes"  mvn_test_passes FileExportServiceUnitTest

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
