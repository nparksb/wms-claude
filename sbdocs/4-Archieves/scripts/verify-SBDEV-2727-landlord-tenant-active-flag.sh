#!/usr/bin/env bash
# verify-SBDEV-2727-landlord-tenant-active-flag.sh
# Machine-checkable acceptance for: Landlord tenant `active` flag (deactivate clients without deleting rows)
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#       bash sbdocs/9-System/scripts/verify-SBDEV-2727-landlord-tenant-active-flag.sh
#
# Exit 0 iff all checks pass. Paste output into the implementation report.

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

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

# Extract a single method body (brace-naive: from the signature line to the next
# line that is a lone closing brace at method indentation) so negative checks are
# scoped to ONE method, not the whole file. Good enough for these small methods.
method_body() {
    local sig=$1 file=$2
    awk -v sig="$sig" '
        $0 ~ sig {inb=1}
        inb {print}
        inb && /^    \}/ {exit}
    ' "$file"
}

MODEL_DISC="src/main/java/net/aim_ai/wms/landlord/model/TenantDiscovery.java"
MODEL_DBC="src/main/java/net/aim_ai/wms/landlord/model/TenantDbConfiguration.java"
REPO_DISC="src/main/java/net/aim_ai/wms/landlord/jpa/TenantDiscoveryRepository.java"
REPO_DBC="src/main/java/net/aim_ai/wms/landlord/jpa/TenantDbConfigurationRepository.java"
SVC="src/main/java/net/aim_ai/wms/landlord/service/LandlordService.java"
RDS="src/main/java/net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java"
LOADER="src/main/java/net/aim_ai/wms/landlord/config/TenantConfigLoader.java"
ACTUATOR="src/main/java/net/aim_ai/wms/controller/actuator/TenantPoolEndpoint.java"
DDL="src/main/resources/db/landlord/L001__add_active_flag.sql"

# --- P0: operator DDL script ---
check_P0_ddl_exists()      { [ -f "$DDL" ]; }
# Assert the ALTER targets the table AND the active-column spec appears in its statement
# (awk-scoped to the statement so a single shared spec line can't satisfy both tables).
check_P0_disc_column()     { awk '/ALTER TABLE +tenant_discovery/{f=1} f{print} /;/{if(f)exit}' "$DDL" | grep -qE 'active +boolean +NOT NULL +DEFAULT +true'; }
check_P0_dbc_column()      { awk '/ALTER TABLE +tenant_db_configuration/{f=1} f{print} /;/{if(f)exit}' "$DDL" | grep -qE 'active +boolean +NOT NULL +DEFAULT +true'; }

# --- P1: entity fields (initialized = true) ---
check_P1_disc_field()      { file_contains 'private +Boolean +active += +Boolean\.TRUE' "$MODEL_DISC"; }
check_P1_disc_column_nn()  { file_contains '@Column\(name += +"active", +nullable += +false\)' "$MODEL_DISC"; }
check_P1_disc_jsonignore() { file_contains '@JsonIgnore' "$MODEL_DISC"; }
check_P1_dbc_field()       { file_contains 'private +Boolean +active += +Boolean\.TRUE' "$MODEL_DBC"; }

# --- P1: derived queries ---
check_P1_disc_query()      { file_contains 'findByKeyAndActiveTrue' "$REPO_DISC"; }
check_P1_dbc_query()       { file_contains 'findByActiveTrue' "$REPO_DBC"; }
check_P1_dbc_wh_query()    { file_contains 'findByWarehouseAndActiveTrue' "$REPO_DBC"; }

# --- P1: service wiring (positive + method-scoped negative) ---
check_P1_svc_disc_pos()    { file_contains 'findByKeyAndActiveTrue' "$SVC"; }
check_P1_svc_dbc_pos()     { file_contains 'findByActiveTrue' "$SVC"; }
# NEGATIVE (method-scoped): getAllDbConfigurations must no longer call findAll();
# getTenantDiscoveryByKey must no longer call findByKey(. Tree/file-wide would
# false-positive on getAllAuthConfigurations' legit findAll and repo declarations.
check_P1_svc_dbc_neg()     { ! method_body 'getAllDbConfigurations'   "$SVC" | grep -qE '\.findAll\(\)'; }
check_P1_svc_disc_neg()    { ! method_body 'getTenantDiscoveryByKey'  "$SVC" | grep -qE '\.findByKey\('; }

# --- P1: actuator guard ---
check_P1_actuator_guard()  { file_contains 'findByWarehouseAndActiveTrue|getActive\(\)' "$ACTUATOR"; }

# --- P1: cron-job tenant enumeration (site 11 / §3.7) ---
JOBS=(
  OrderReleaseJob CleanUpOldMessagesJob OutboxDispatcherJob StaleClubBatchCleanupJob
  ReleaseExpiredPickingOrdersFromUserJob StockSummaryExportJob ReplenishOrderJob RestIdempotencyCleanupJob
)
JOBDIR="src/main/java/net/aim_ai/wms/schedulejob"
# Positive: the job enumerates via findByActiveTrue().
check_job_pos() { file_contains 'tenantDbConfigurationRepository\.findByActiveTrue\(\)' "$JOBDIR/$1.java"; }
# Negative: the job no longer calls the unfiltered findAll() for enumeration.
check_job_neg() { file_not_contains 'tenantDbConfigurationRepository\.findAll\(\)' "$JOBDIR/$1.java"; }
# Global negative: after this change, NO main-source caller of tenantDbConfigurationRepository.findAll()
# should remain (LandlordService:69 is converted in §3.3; the 8 jobs in §3.7).
check_no_findall_anywhere() {
    ! grep -rqE 'tenantDbConfigurationRepository\.findAll\(\)' src/main/java
}

# --- P2: evictAbsentPools + wiring ---
check_P2_evict_method()    { file_contains 'void +evictAbsentPools\(\)' "$RDS"; }
check_P2_evict_removes()   { method_body 'void evictAbsentPools' "$RDS" | grep -qE 'removeTenant\('; }
check_P2_loader_calls()    { file_contains 'evictAbsentPools\(\)' "$LOADER"; }

echo
echo "verify-SBDEV-2727 — landlord tenant active flag"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "P0 — operator DDL"
run P0-ddl    "L001 script exists"                         check_P0_ddl_exists
run P0-disc   "L001 adds active to tenant_discovery"       check_P0_disc_column
run P0-dbc    "L001 adds active to tenant_db_configuration" check_P0_dbc_column
echo
echo "P1 — entities / queries / service / actuator"
run P1-e1     "TenantDiscovery.active = Boolean.TRUE"       check_P1_disc_field
run P1-e1c    "TenantDiscovery.active @Column nullable=false" check_P1_disc_column_nn
run P1-e1j    "TenantDiscovery.active @JsonIgnore"          check_P1_disc_jsonignore
run P1-e2     "TenantDbConfiguration.active = Boolean.TRUE" check_P1_dbc_field
run P1-q1     "TenantDiscoveryRepository.findByKeyAndActiveTrue" check_P1_disc_query
run P1-q2     "TenantDbConfigurationRepository.findByActiveTrue" check_P1_dbc_query
run P1-q3     "TenantDbConfigurationRepository.findByWarehouseAndActiveTrue" check_P1_dbc_wh_query
run P1-s1     "LandlordService uses findByKeyAndActiveTrue" check_P1_svc_disc_pos
run P1-s2     "LandlordService uses findByActiveTrue"       check_P1_svc_dbc_pos
run P1-s1n    "getAllDbConfigurations no longer calls findAll()"  check_P1_svc_dbc_neg
run P1-s2n    "getTenantDiscoveryByKey no longer calls findByKey(" check_P1_svc_disc_neg
run P1-act    "TenantPoolEndpoint guards inactive tenant"   check_P1_actuator_guard
echo
echo "P1 — cron-job tenant enumeration (findByActiveTrue)"
for j in "${JOBS[@]}"; do
    run "P1-j+:$j" "$j enumerates findByActiveTrue()" check_job_pos "$j"
    run "P1-j-:$j" "$j no longer calls findAll()"     check_job_neg "$j"
done
run P1-jall   "no tenantDbConfigurationRepository.findAll() remains in main" check_no_findall_anywhere
echo
echo "P2 — immediate force-evict"
run P2-m1     "evictAbsentPools() method present"           check_P2_evict_method
run P2-m2     "evictAbsentPools() calls removeTenant()"     check_P2_evict_removes
run P2-w1     "TenantConfigLoader calls evictAbsentPools()" check_P2_loader_calls
echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
