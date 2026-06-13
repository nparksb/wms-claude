#!/usr/bin/env bash
# verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh
#
# Machine-checkable acceptance for plan:
#   SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md
#
# Bug: the Replenishment Monitor classifies "replenishable" stock by a hardcoded
# area-NAME list that includes the pick-only area 'Storage and Picking'. Fix:
# classify by the location_area.useforreplenish FLAG in BOTH read paths
#   (A) the inline native query ReplenishmentMonitorViewRepository.getReplenishViewSummary
#   (B) the deployed DB view replenishment_monitor_view (new Flyway migration)
#   (C) sync the commented DDL in ReplenishmentMonitorView.java
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh
#   PROJECT_ROOT=/path/to/v1/wms-api bash .../verify-260601-...sh
#
# Exit 0 only when every check passes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
# Match a regex on at least N lines of a file.
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

# --- targets ---
REPO="src/main/java/net/aim_ai/wms/repo/jpa/ReplenishmentMonitorViewRepository.java"
ENTITY="src/main/java/net/aim_ai/wms/model/ReplenishmentMonitorView.java"
MIG_DIR="src/main/resources/db/migration"
V0="$MIG_DIR/V1.0.02__wms_views.sql"

# === Fix A — inline query uses the flag, name list is gone ====================
# 'Storage and Picking' / 'Deep Storage' / 'Storage, Picking and Replenish (from)'
# appeared ONLY in the replenishable name list in this file → after the fix they
# must be gone entirely. ('Inbound' stays — it's the kept staging bucket.)
check_A_pickface_namelist_gone()   { file_not_contains "Storage and Picking" "$REPO"; }
check_A_deepstorage_namelist_gone(){ file_not_contains "Deep Storage" "$REPO"; }
check_A_replenish_namelist_gone()  { file_not_contains "'Storage and Replenish'" "$REPO"; }   # name list (quoted) gone; flag uses no quotes
check_A_typo_namelist_gone()       { file_not_contains "Storage, Picking and Replenish \(from\)" "$REPO"; }
# BOTH replenishable expressions must convert: the sum (THEN su.amount) AND the string_agg (THEN loc.name).
# t2 'available' uses `useforreplenish = false`, so a true-count of >=2 means both replenishable exprs flipped.
check_A_sum_expr_flag()            { file_contains "useforreplenish = true THEN su.amount" "$REPO"; }
check_A_both_repl_exprs_flag()     { file_contains_n_times "useforreplenish = true" "$REPO" 2; }
# Staging bucket must be intact as a single ARRAY[...] predicate, not merely 'Inbound' mentioned somewhere.
# Escape-agnostic: the native query renders '::' as '\:\:', so match the literals + order, not the casts.
check_A_staging_predicate_intact() { file_contains "ARRAY\['Inbound'.*'Default'.*'users'" "$REPO"; }

# === Fix B — new Flyway migration redefines the view by flag ==================
# Find a migration file (other than V1.0.02) that re-creates the view AND uses
# the flag for the replenishable bucket.
_mig_redefines_view() {
    grep -rlE "(CREATE OR REPLACE VIEW|CREATE VIEW)\s+replenishment_monitor_view" \
        "$MIG_DIR" 2>/dev/null | grep -v "V1.0.02__wms_views.sql"
}
check_B_migration_present() {
    local f; f=$(_mig_redefines_view) && [ -n "$f" ]
}
check_B_migration_flag_based() {
    local f; f=$(_mig_redefines_view) || return 1
    [ -n "$f" ] && grep -qiE "useforreplenish\s*=\s*TRUE" $f \
                && grep -qE "on_replenishable_location" $f
}
check_B_migration_no_pickface() {
    local f; f=$(_mig_redefines_view) || return 1
    [ -n "$f" ] && ! grep -qE "Storage and Picking" $f
}
# Migration must reproduce the deployed 17-col shape (has order_hold + on_non_replenishable_location + ro_source_name)
# and must NOT introduce the 26-col inline-query columns (section_name) — that shape change breaks CREATE OR REPLACE.
check_B_migration_deployed_shape() {
    local f; f=$(_mig_redefines_view) || return 1
    [ -n "$f" ] \
      && grep -qiE "order_hold" $f \
      && grep -qiE "on_non_replenishable_location" $f \
      && grep -qiE "ro_source_name" $f \
      && ! grep -qiE "section_name" $f
}
check_B_migration_staging_intact() {
    local f; f=$(_mig_redefines_view) || return 1
    [ -n "$f" ] && grep -qiE "'Inbound',\s*'Default',\s*'users'" $f
}

# === Fix C — entity comment synced (no pick-only area in the commented DDL) ====
check_C_entity_comment_synced() { file_not_contains "Storage and Picking" "$ENTITY"; }

# === Reference: original view definition still present (V1.0.02 untouched) =====
check_ref_v0_present() { [ -f "$V0" ]; }

echo
echo "verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "Fix A — inline query (ReplenishmentMonitorViewRepository.getReplenishViewSummary)"
run A1 "'Storage and Picking' removed from inline query"          check_A_pickface_namelist_gone
run A2 "'Deep Storage' name-list removed from inline query"       check_A_deepstorage_namelist_gone
run A3 "'Storage and Replenish' name literal removed"             check_A_replenish_namelist_gone
run A4 "comma-typo area name removed from inline query"           check_A_typo_namelist_gone
run A5 "SUM bucket uses 'useforreplenish = true THEN su.amount'"  check_A_sum_expr_flag
run A6 "BOTH replenishable exprs flipped (>=2 flag uses)"         check_A_both_repl_exprs_flag
run A7 "staging predicate byte-intact (Inbound/Default/users)"    check_A_staging_predicate_intact
echo
echo "Fix B — new Flyway migration for replenishment_monitor_view"
run B1 "migration redefining the view exists (not V1.0.02)"       check_B_migration_present
run B2 "migration replenishable bucket uses useforreplenish=TRUE" check_B_migration_flag_based
run B3 "migration replenishable bucket has no pick-only name"     check_B_migration_no_pickface
run B4 "migration reproduces deployed 17-col shape (not inline)"  check_B_migration_deployed_shape
run B5 "migration staging bucket intact (Inbound/Default/users)"  check_B_migration_staging_intact
echo
echo "Fix C — entity comment hygiene"
run C1 "commented DDL no longer lists 'Storage and Picking'"      check_C_entity_comment_synced
echo
echo "Reference"
run R1 "original V1.0.02__wms_views.sql still present"            check_ref_v0_present
echo

# === Behavioral proof (Testcontainers) =======================================
# Code-shape greps prove the predicate changed; the IT proves it computes right.
if [ "${RUN_MVN:-0}" = "1" ]; then
    run IT "ReplenishmentMonitorViewRepositoryIT passes" \
        bash -c 'mvn test -Dtest=ReplenishmentMonitorViewRepositoryIT -DfailIfNoTests=false -q 2>&1 | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"'
else
    skip IT "ReplenishmentMonitorViewRepositoryIT passes" "set RUN_MVN=1 to run Testcontainers IT"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
