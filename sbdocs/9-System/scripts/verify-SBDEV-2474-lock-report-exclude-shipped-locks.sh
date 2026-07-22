#!/usr/bin/env bash
# verify-SBDEV-2474-lock-report-exclude-shipped-locks.sh
# Machine-checkable acceptance for SBDEV-2474 — Exclude Shipped Locks from the
# default Lock Report View (WMS v2). Two-view design:
#   View A lock_overview_dto_view  -> WHERE COALESCE(entity_lock,0) <> 405  (default)
#   View B lock_overview_all_view  -> unfiltered (backs "Include Shipped Locks")
#
# Run:  bash sbdocs/9-System/scripts/verify-SBDEV-2474-lock-report-exclude-shipped-locks.sh
# Exit 0 iff every check passes. Paste the output into the implementation report.
#
# Spans two repos. Override roots via env:
#   API_ROOT=...     (default: v2/wms2-api)
#   WEB_UI_ROOT=...  (default: v2/wms2-web-ui)
# RUN_MVN=1 also runs the targeted unit test.

set -u

API_ROOT="${API_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
WEB_UI_ROOT="${WEB_UI_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"
RUN_MVN="${RUN_MVN:-0}"

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

# --- paths ---
MIG="$API_ROOT/src/main/resources/db/migration/V2.2.03__lock_report_exclude_shipped.sql"
ONB="$API_ROOT/src/main/resources/db/v1-to-v2-onboarding/schema/V2.1.17__lock_report_exclude_shipped.sql"
IFACE="$API_ROOT/src/main/java/net/aim_ai/wms/model/LockOverviewRow.java"
ALL_ENT="$API_ROOT/src/main/java/net/aim_ai/wms/model/LockOverviewAllDtoView.java"
DEF_ENT="$API_ROOT/src/main/java/net/aim_ai/wms/model/LockOverviewDtoView.java"
ALL_REPO="$API_ROOT/src/main/java/net/aim_ai/wms/repo/jpa/LockOverviewAllDtoViewRepository.java"
DEF_REPO="$API_ROOT/src/main/java/net/aim_ai/wms/repo/jpa/LockOverviewDtoViewRepository.java"
RESTCFG="$API_ROOT/src/main/java/net/aim_ai/wms/RestConfiguration.java"
CTRL="$API_ROOT/src/main/java/net/aim_ai/wms/controller/ReportController.java"
SVC="$API_ROOT/src/main/java/net/aim_ai/wms/service/ReportService.java"
STORE="$WEB_UI_ROOT/store/reports/lock.js"
VUE="$WEB_UI_ROOT/components/reports/lockReport.vue"

# === Phase 1 — DB views (rows 1, 9) ===
check_P1_migration_exists()      { [ -f "$MIG" ]; }
check_P1_default_view_excludes() { file_contains 'lock_overview_dto_view' "$MIG" && file_contains '<>[[:space:]]*405' "$MIG"; }
check_P1_all_view_created()      { file_contains 'lock_overview_all_view' "$MIG"; }
check_P1_coalesce_guard()        { file_contains 'COALESCE\([^)]*entity_lock[^)]*\)[[:space:]]*<>[[:space:]]*405' "$MIG"; }
# Onboarding parity (row 9) — new delta, byte-parity with migration; NOT an edit to V1.2.04
check_P1_onboarding_exists()     { [ -f "$ONB" ]; }
check_P1_onboarding_excludes()   { file_contains 'lock_overview_dto_view' "$ONB" && file_contains '<>[[:space:]]*405' "$ONB"; }
check_P1_onboarding_all_view()   { file_contains 'lock_overview_all_view' "$ONB"; }

# === Phase 1 — Java (rows 2-6) ===
check_P1_iface_exists()          { [ -f "$IFACE" ] && file_contains 'interface[[:space:]]+LockOverviewRow' "$IFACE"; }
check_P1_all_entity()            { [ -f "$ALL_ENT" ] && file_contains '@Table\(name[[:space:]]*=[[:space:]]*"lock_overview_all_view"\)' "$ALL_ENT"; }
check_P1_all_entity_impl()       { file_contains 'implements[[:space:]].*LockOverviewRow' "$ALL_ENT"; }
check_P1_def_entity_impl()       { file_contains 'implements[[:space:]].*LockOverviewRow' "$DEF_ENT"; }
check_P1_all_repo()              { [ -f "$ALL_REPO" ] && file_contains 'path[[:space:]]*=[[:space:]]*"lockOverviewAllDtoView"' "$ALL_REPO"; }
check_P1_all_repo_query()        { file_contains 'lock_overview_all_view' "$ALL_REPO"; }
check_P1_restcfg()               { file_contains 'LockOverviewAllDtoView\.class' "$RESTCFG"; }
check_P1_ctrl_includeShipped()   { file_contains 'includeShipped' "$CTRL"; }
check_P1_svc_includeShipped()    { file_contains 'exporLockReport\([^)]*includeShipped' "$SVC" || file_contains 'boolean[[:space:]]+includeShipped' "$SVC"; }
# Read path is intentionally NOT wrapped in a tx (flat view entity + materialized list; matches
# sibling export methods) — code review corrected the initial @Transactional plan. Assert absence.
check_P1_svc_no_tx()             { file_not_contains '^[[:space:]]*@Transactional' "$SVC"; }
check_P1_svc_shared_builder()    { file_contains 'buildLockReportRows\(' "$SVC"; }

# NEGATIVE — default path untouched (scoped to the default repo; the all-view must NOT appear there)
check_P1_neg_default_view()      { file_contains 'lock_overview_dto_view' "$DEF_REPO"; }
check_P1_neg_no_all_in_default() { file_not_contains 'lock_overview_all_view' "$DEF_REPO"; }

# === Phase 2 — Web UI (rows 11-12) ===
check_P2_store_all_resource()    { file_contains 'lockOverviewAllDtoView' "$STORE"; }
# Store must select the embedded rel key for the chosen resource — either the literal
# all-view key or a dynamic _embedded[resource] lookup keyed on the resource name.
check_P2_store_embedded_key()    { file_contains '_embedded\.lockOverviewAllDtoView|_embedded\??\.?\[resource\]' "$STORE"; }
check_P2_store_no_dead_state()   { file_not_contains '&state=' "$STORE"; }
check_P2_vue_toggle()            { file_contains 'includeShipped' "$VUE"; }

echo
echo "verify-SBDEV-2474 — Lock Report exclude-shipped acceptance"
echo "  API_ROOT=$API_ROOT"
echo "  WEB_UI_ROOT=$WEB_UI_ROOT"
echo
echo "-- Phase 1: DB views --"
run P1-mig      "V2.2.03 migration exists"                       check_P1_migration_exists
run P1-defv     "default view lock_overview_dto_view excludes 405" check_P1_default_view_excludes
run P1-coal     "default view uses COALESCE(entity_lock,0)<>405"  check_P1_coalesce_guard
run P1-allv     "all-view lock_overview_all_view created"         check_P1_all_view_created
run P1-onb      "onboarding delta V2.1.17 exists (not a V1.2.04 edit)" check_P1_onboarding_exists
run P1-onbx     "onboarding default view excludes 405"            check_P1_onboarding_excludes
run P1-onba     "onboarding all-view created"                     check_P1_onboarding_all_view
echo
echo "-- Phase 1: Java --"
run P1-iface    "LockOverviewRow interface exists"               check_P1_iface_exists
run P1-allent   "LockOverviewAllDtoView maps lock_overview_all_view" check_P1_all_entity
run P1-allimpl  "LockOverviewAllDtoView implements LockOverviewRow" check_P1_all_entity_impl
run P1-defimpl  "LockOverviewDtoView implements LockOverviewRow"  check_P1_def_entity_impl
run P1-allrepo  "all-repo exposed at path lockOverviewAllDtoView" check_P1_all_repo
run P1-allrq    "all-repo native query targets lock_overview_all_view" check_P1_all_repo_query
run P1-restcfg  "RestConfiguration exposeIdsFor LockOverviewAllDtoView" check_P1_restcfg
run P1-ctrl     "ReportController reads includeShipped"           check_P1_ctrl_includeShipped
run P1-svc      "ReportService.exporLockReport has includeShipped" check_P1_svc_includeShipped
run P1-builder  "ReportService uses shared buildLockReportRows"    check_P1_svc_shared_builder
run P1-notx     "ReportService export read path is not tx-wrapped"  check_P1_svc_no_tx
run P1-neg1     "default repo still targets lock_overview_dto_view" check_P1_neg_default_view
run P1-neg2     "default repo does NOT reference the all-view"     check_P1_neg_no_all_in_default
echo
echo "-- Phase 2: Web UI --"
run P2-store    "store references lockOverviewAllDtoView resource" check_P2_store_all_resource
run P2-embed    "store reads _embedded.lockOverviewAllDtoView key" check_P2_store_embedded_key
run P2-nostate  "store no longer sends dead state=undefined param" check_P2_store_no_dead_state
run P2-toggle   "lockReport.vue has Include-Shipped toggle"        check_P2_vue_toggle
echo

# === Optional targeted unit test (behavioral) ===
if [ "$RUN_MVN" = "1" ]; then
    echo "-- Unit test --"
    if ( cd "$API_ROOT" && mvn test -Dtest=ReportServiceUnitTest -DfailIfNoTests=false -q 2>&1 \
         | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0" ); then
        printf "  PASS  %-10s  %s\n" "P1-utest" "ReportServiceUnitTest passes"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "P1-utest" "ReportServiceUnitTest passes"; FAIL=$((FAIL+1))
    fi
else
    skip "P1-utest" "ReportServiceUnitTest" "set RUN_MVN=1 to run"
fi

echo
echo "NOTE: the ONLY verification of the default-view behavior itself is the §7.3 SQL"
echo "      gate (SELECT count(*) FILTER (WHERE stockunitlock=405) FROM lock_overview_dto_view = 0);"
echo "      Testcontainers ITs are @Disabled under SBDEV-2217. Run the SQL gate before release."
echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
