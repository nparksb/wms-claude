#!/usr/bin/env bash
# verify-SBDEV-2238-4.1-bol-closeBOL-outbox-migration.sh
#
# Static-verification harness for the SBDEV-2238-4.1 plan
# (BillofladingService.closeBOL OMS-notification outbox migration).
#
# Runs entirely from grep + file-existence assertions, plus one optional
# targeted JUnit run. No DB connection required.
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2238-4.1-bol-closeBOL-outbox-migration.sh
#
# Exit codes:
#   0 = all checks passed
#   non-zero = at least one check failed (count of failures)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
API_ROOT="$REPO_ROOT/v2/wms2-api"
SRC="$API_ROOT/src/main/java/net/aim_ai/wms"
TEST="$API_ROOT/src/test/java/net/aim_ai/wms"
MIG="$API_ROOT/src/main/resources/db/migration"

BOL_SVC="$SRC/service/BillofladingService.java"

FAIL=0
PASS=0
SKIP=0

check()    { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name"; FAIL=$((FAIL+1)); fi; }
checkneg() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL  $name"; FAIL=$((FAIL+1)); else echo "PASS  $name"; PASS=$((PASS+1)); fi; }
skip()     { local name="$1"; local reason="$2"; echo "SKIP  $name  ($reason)"; SKIP=$((SKIP+1)); }
section()  { echo; echo "=== $1 ==="; }

# --- helpers --------------------------------------------------------------

# Match a regex (extended) anywhere in a file.
file_contains() { grep -qE "$1" "$2"; }

# Assert a regex does NOT appear.
file_not_contains() { ! grep -qE "$1" "$2"; }

# Run a targeted JUnit class and require BUILD SUCCESS.
mvn_test_passes() {
    local test_class=$1
    (cd "$API_ROOT" && mvn test -Dtest="$test_class" -DfailIfNoTests=false -q 2>&1) \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# Extract the closeBOL(Long bolId) method body. The service contains TWO
# closeBOL overloads — closeBOL(Billoflading) (a 3-line wrapper) and
# closeBOL(Long bolId) (the real one with the OMS-notification block at
# ~line 651-660). Always target the (Long bolId) variant.
closebol_body() {
    awk '
        /public[[:space:]].*closeBOL[[:space:]]*\([[:space:]]*Long[[:space:]]+/ {flag=1}
        flag {print}
        flag && /^    \}/ {flag=0; exit}
    ' "$BOL_SVC"
}
export -f closebol_body 2>/dev/null || true

echo
echo "verify-SBDEV-2238-4.1 — running acceptance checks"
echo "  REPO_ROOT=$REPO_ROOT"
echo "  API_ROOT=$API_ROOT"
echo

# --- 0. Prerequisites (SBDEV-2221 must be merged) -------------------------

section "0. Prerequisites — SBDEV-2221 outbox infrastructure must be present"

check "Prereq: OutboxMessage entity present" \
    test -f "$SRC/model/OutboxMessage.java"
check "Prereq: OutboxService present" \
    test -f "$SRC/service/OutboxService.java"
check "Prereq: OutboxDispatcherJob present" \
    test -f "$SRC/schedulejob/OutboxDispatcherJob.java"
check "Prereq: V1.1.16__add_outbox_message.sql present" \
    test -f "$MIG/V1.1.16__add_outbox_message.sql"
check "Prereq: AdvisoryLockService declares OUTBOX_DISPATCHER = 100008L" \
    grep -qE "OUTBOX_DISPATCHER[[:space:]]*=[[:space:]]*100008L" "$SRC/service/AdvisoryLockService.java"

# --- 1. Pilot call-site rewrite (the actual fix in this plan) -------------

section "1. Pilot call-site rewrite — closeBOL uses outbox, not sendAfterCommit"

check "Fix A: BillofladingService imports OutboxMessage" \
    grep -qE "import[[:space:]]+.*\.model\.OutboxMessage;" "$BOL_SVC"

check "Fix A: BillofladingService constructor declares an OutboxService parameter" \
    grep -qE "OutboxService[[:space:]]+outboxService" "$BOL_SVC"

check "Fix A: BillofladingService.closeBOL calls outboxService.enqueue" \
    bash -c 'closebol_body() { awk "/public[[:space:]].*closeBOL[[:space:]]*\\([[:space:]]*Long[[:space:]]+/ {flag=1} flag {print} flag && /^    \\}/ {flag=0; exit}" "'"$BOL_SVC"'"; }; closebol_body | grep -qE "outboxService\\.enqueue\\("'

check "Fix A: enqueue payload sets aggregateType=\"BILLOFLADING\"" \
    bash -c 'closebol_body() { awk "/public[[:space:]].*closeBOL[[:space:]]*\\([[:space:]]*Long[[:space:]]+/ {flag=1} flag {print} flag && /^    \\}/ {flag=0; exit}" "'"$BOL_SVC"'"; }; closebol_body | grep -qE "aggregateType\\([[:space:]]*\"BILLOFLADING\""'

check "Fix A: enqueue payload sets processType=ORDER_BATCH_SHIPPED" \
    bash -c 'closebol_body() { awk "/public[[:space:]].*closeBOL[[:space:]]*\\([[:space:]]*Long[[:space:]]+/ {flag=1} flag {print} flag && /^    \\}/ {flag=0; exit}" "'"$BOL_SVC"'"; }; closebol_body | grep -qE "processType\\(.*ORDER_BATCH_SHIPPED"'

check "Fix A: enqueue payload sets idempotencyKey via UUID.randomUUID()" \
    bash -c 'closebol_body() { awk "/public[[:space:]].*closeBOL[[:space:]]*\\([[:space:]]*Long[[:space:]]+/ {flag=1} flag {print} flag && /^    \\}/ {flag=0; exit}" "'"$BOL_SVC"'"; }; closebol_body | grep -qE "idempotencyKey\\(.*UUID\\.randomUUID"'

checkneg "Fix A NEGATIVE: closeBOL no longer calls sendAfterCommit with ORDER_BATCH_SHIPPED" \
    bash -c 'closebol_body() { awk "/public[[:space:]].*closeBOL[[:space:]]*\\([[:space:]]*Long[[:space:]]+/ {flag=1} flag {print} flag && /^    \\}/ {flag=0; exit}" "'"$BOL_SVC"'"; }; body=$(closebol_body); echo "$body" | grep -qE "omsNotificationService\\.sendAfterCommit\\(" && echo "$body" | grep -qE "ORDER_BATCH_SHIPPED"'

# Scope the IOException-rethrow check to the catch (IOException ...) block only —
# the method signature itself declares "throws ... BusinessException", so a body-wide
# grep would falsely match the signature, not a rethrow inside the catch.
checkneg "Fix A NEGATIVE: closeBOL does NOT rethrow IOException as BusinessException (BOL state must survive serialize failure)" \
    bash -c 'awk "
        /public[[:space:]].*closeBOL[[:space:]]*\\([[:space:]]*Long[[:space:]]+/ {bodyflag=1}
        bodyflag && /catch[[:space:]]*\\([[:space:]]*IOException/ {catchflag=1}
        catchflag {print}
        catchflag && /^[[:space:]]*\\}/ {catchflag=0}
        bodyflag && /^    \\}/ {bodyflag=0; exit}
    " "'"$BOL_SVC"'" | grep -qE "throw[[:space:]]+new[[:space:]]+BusinessException"'

# --- 2. Observability ----------------------------------------------------

section "2. Observability — serialize-failed counter"

check "Counter: wms2.outbox.serialize_failed referenced in BillofladingService" \
    grep -qE 'wms2\.outbox\.serialize_failed' "$BOL_SVC"

check "Counter: serialize_failed tags include aggregateType + processType" \
    bash -c 'awk "/wms2\\.outbox\\.serialize_failed/,/\\)\\.increment\\(/" "'"$BOL_SVC"'" | grep -qE "\"aggregateType\"" \
              && awk "/wms2\\.outbox\\.serialize_failed/,/\\)\\.increment\\(/" "'"$BOL_SVC"'" | grep -qE "\"processType\""'

# --- 3. v2 constraint cross-checks ---------------------------------------

section "3. v2 constraint cross-checks"

check "closeBOL remains @Transactional(tenantTransactionManager) (no scope change in this plan)" \
    bash -c 'awk "/@Transactional/{cap=\$0; getline; if (\$0 ~ /closeBOL/) print cap}" "'"$BOL_SVC"'" | grep -qE "tenantTransactionManager" \
              || grep -B1 -E "public[[:space:]].*closeBOL[[:space:]]*\\(" "'"$BOL_SVC"'" | grep -qE "tenantTransactionManager"'

# --- 4. Tests -----------------------------------------------------------

section "4. Unit tests"

check "BillofladingServiceUnitTest mocks OutboxService" \
    grep -qE "@Mock[^A-Za-z0-9_]*OutboxService" "$TEST/unit/service/BillofladingServiceUnitTest.java"

check "BillofladingServiceUnitTest asserts enqueue was called with expected fields" \
    grep -qE 'enqueuesOutboxMessageWithExpectedFields' "$TEST/unit/service/BillofladingServiceUnitTest.java"

check "BillofladingServiceUnitTest asserts sendAfterCommit is NOT called for ORDER_BATCH_SHIPPED" \
    grep -qE 'doesNotCallSendAfterCommitForOrderBatchShipped' "$TEST/unit/service/BillofladingServiceUnitTest.java"

check "BillofladingServiceUnitTest covers IOException path increments serialize_failed counter (no rollback)" \
    grep -qE 'incrementsSerializeFailedCounterOnIOException_doesNotRollbackBolState' "$TEST/unit/service/BillofladingServiceUnitTest.java"

# Integration test inherited from SBDEV-2221; this plan extends it with caller-specific assertions.
check "BillofladingOutboxIntegrationTest exists (inherited from SBDEV-2221, extended here)" \
    test -f "$TEST/integration/BillofladingOutboxIntegrationTest.java"

# --- 5. Behavioural — mvn test --------------------------------------------

section "5. Behavioural — targeted unit test passes"

if command -v mvn >/dev/null 2>&1; then
    if "$API_ROOT" >/dev/null 2>&1 || test -d "$API_ROOT"; then
        check "mvn test -Dtest=BillofladingServiceUnitTest passes" \
            mvn_test_passes BillofladingServiceUnitTest
    else
        skip "mvn test -Dtest=BillofladingServiceUnitTest" "API_ROOT not present"
    fi
else
    skip "mvn test -Dtest=BillofladingServiceUnitTest" "mvn not on PATH"
fi

# --- Summary -------------------------------------------------------------

echo
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
exit "$FAIL"
