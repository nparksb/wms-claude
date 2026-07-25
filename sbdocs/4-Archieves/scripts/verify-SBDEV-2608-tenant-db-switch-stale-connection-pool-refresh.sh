#!/usr/bin/env bash
# verify-SBDEV-2608-tenant-db-switch-stale-connection-pool-refresh.sh
# Machine-checkable acceptance for SBDEV-2608 — tenant DB switch not applied without restart.
#
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2608-tenant-db-switch-stale-connection-pool-refresh.sh
#
# Exit 0 only when every check passes.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
skip() { printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
# Gate on the actual build exit code — NOT a passing sub-line (a partial-failure reactor
# still prints "Tests run: N, Failures: 0" for the passing module, which would false-PASS a grep).
mvn_test_passes()   { mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1; }

RDS=src/main/java/net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java
LOADER=src/main/java/net/aim_ai/wms/landlord/config/TenantConfigLoader.java
ENDPOINT=src/main/java/net/aim_ai/wms/controller/actuator/TenantPoolEndpoint.java
PROPS=src/main/resources/application.properties

# --- Fix B: single holder map + evict-changed sweep + lowercased cache keys ---
# B1 shape check accepts EITHER a single PoolHolder map OR the (discouraged) two-map form,
# so it does not block the recommended single-holder design.
check_B_holder_or_sourcemap() {
    file_contains 'PoolHolder|poolHolders|poolSourceConfig' "$RDS"
}
check_B_source_populated()  { file_contains 'new PoolHolder\(|poolSourceConfig\.put\(' "$RDS"; }
check_B_source_cleared()    { file_contains 'poolHolders\.remove\(|poolSourceConfig\.remove\(' "$RDS"; }
check_B_evict_method()      { file_contains 'evictChangedPools\s*\(' "$RDS"; }
check_B_compare_method()    { file_contains 'connectionConfigEquals\s*\(' "$RDS"; }
# NEGATIVE (now able to fail): the connectionConfigEquals body must NOT reference `modified`.
# -Pz makes grep treat the file as one record so [^}]* spans newlines up to the method's first `}`.
check_B_ignores_modified()  { ! grep -Pzq 'connectionConfigEquals\s*\([^)]*\)\s*\{[^}]*[Mm]odified' "$RDS"; }
# POSITIVE: loader must lowercase the KEY-source getters (root fix for the key-case hazard, plan 5.1.a).
# Tightened past a bare toLowerCase() so an unrelated lowercase elsewhere can't false-PASS it.
check_B_loader_lowercase()  { file_contains 'getName\(\)\.toLowerCase|getWarehouse\(\)\.toLowerCase' "$LOADER"; }
check_B_loader_sweep()      { file_contains 'evictChangedPools\s*\(' "$LOADER"; }

# --- Fix A: actuator evict endpoint, admin-gated, cache-then-unconditional-evict, lowercased key ---
check_A_endpoint_exists()   { test -f "$ENDPOINT"; }
check_A_endpoint_id()       { file_contains '@Endpoint\(\s*id\s*=\s*"tenantpool"' "$ENDPOINT"; }
check_A_write_operation()   { file_contains '@WriteOperation' "$ENDPOINT"; }
check_A_lowercase_key()     { file_contains 'toLowerCase\(' "$ENDPOINT"; }
check_A_cache_put()         { file_contains 'dbConfigCache\.put\(' "$ENDPOINT"; }
check_A_unconditional_evict(){ file_contains 'removeTenant\(' "$ENDPOINT"; }
# NEGATIVE: the endpoint must NOT gate its force on the change-comparison (no evictChangedPools/If call).
check_A_not_conditional()   { file_not_contains 'evictIfConfigChanged|evictIfChangedOrForce' "$ENDPOINT"; }
check_A_exposure()          { file_contains 'management\.endpoints\.web\.exposure\.include=.*tenantpool' "$PROPS"; }

echo
echo "verify-SBDEV-2608 — tenant DB switch / stale pool"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run B1  "Fix B — holder (or source) config remembered"     check_B_holder_or_sourcemap
run B2  "Fix B — source config stored on build"            check_B_source_populated
run B3  "Fix B — holder/source cleared on removeTenant"    check_B_source_cleared
run B4  "Fix B — evictChangedPools present"                check_B_evict_method
run B5  "Fix B — connectionConfigEquals present"           check_B_compare_method
run B6  "Fix B — compare ignores modified timestamp (NEG)" check_B_ignores_modified
run B7  "Fix B — loader lowercases cache keys"             check_B_loader_lowercase
run B8  "Fix B — loader calls evictChangedPools"           check_B_loader_sweep
echo
run A1  "Fix A — TenantPoolEndpoint file exists"           check_A_endpoint_exists
run A2  "Fix A — @Endpoint(id=\"tenantpool\")"             check_A_endpoint_id
run A3  "Fix A — @WriteOperation present"                  check_A_write_operation
run A4  "Fix A — lowercases key (key-case hazard)"         check_A_lowercase_key
run A5  "Fix A — cache put present (ordering)"             check_A_cache_put
run A6  "Fix A — unconditional removeTenant (force)"       check_A_unconditional_evict
run A7  "Fix A — force is NOT change-gated (NEG)"          check_A_not_conditional
run A8  "Fix A — tenantpool exposed via actuator"          check_A_exposure
echo

# Behavior — targeted unit tests (code-shape greps prove the call exists, not that it works).
if command -v mvn >/dev/null 2>&1; then
    run T1 "unit — routing DS evict/rebuild"  mvn_test_passes TenantDynamicRoutingDataSourceEvictRebuildTest
    run T2 "unit — loader auto-evict + mixed-case" mvn_test_passes TenantConfigLoaderAutoEvictTest
    run T3 "unit — endpoint auth"             mvn_test_passes TenantPoolEndpointSecurityTest
else
    skip T1 "unit — routing DS evict/rebuild" "mvn not on PATH"
    skip T2 "unit — loader auto-evict + mixed-case" "mvn not on PATH"
    skip T3 "unit — endpoint auth"            "mvn not on PATH"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
