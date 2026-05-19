#!/usr/bin/env bash
# verify-SBDEV-2238-4.2-rest-controller-pii-log-reduction.sh
#
# Static-verification harness for the SBDEV-2238-4.2 plan
# (REST controller PII log reduction and body redaction).
#
# Runs entirely from grep + file-existence assertions, plus optional
# targeted JUnit runs. No DB connection required.
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2238-4.2-rest-controller-pii-log-reduction.sh
#
# Exit codes:
#   0 = all checks passed
#   non-zero = at least one check failed (count of failures)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
API_ROOT="$REPO_ROOT/v2/wms2-api"
SRC="$API_ROOT/src/main/java/net/aim_ai/wms"
TEST="$API_ROOT/src/test/java/net/aim_ai/wms"
RES="$API_ROOT/src/main/resources"

UTIL="$SRC/util/RestPayloadLogSummary.java"
ORDER_CTRL="$SRC/controller/rest/OrderRestController.java"
ADVICE_CTRL="$SRC/controller/rest/AdviceRestController.java"
SKU_CTRL="$SRC/controller/rest/SkuRestController.java"
FILEIMPORT_CTRL="$SRC/controller/FileImportController.java"
IDEMP_FILTER="$SRC/landlord/config/IdempotencyFilter.java"
LOGBACK="$RES/logback-spring.xml"

UTIL_TEST="$TEST/unit/util/RestPayloadLogSummaryUnitTest.java"
FILEIMPORT_TEST="$TEST/unit/controller/FileImportControllerTest.java"
IDEMP_TEST="$TEST/unit/landlord/config/IdempotencyFilterUnitTest.java"

FAIL=0
PASS=0
SKIP=0

check()    { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name"; FAIL=$((FAIL+1)); fi; }
checkneg() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL  $name"; FAIL=$((FAIL+1)); else echo "PASS  $name"; PASS=$((PASS+1)); fi; }
skip()     { local name="$1"; local reason="$2"; echo "SKIP  $name  ($reason)"; SKIP=$((SKIP+1)); }
section()  { echo; echo "=== $1 ==="; }

mvn_test_passes() {
    local test_class=$1
    (cd "$API_ROOT" && mvn test -Dtest="$test_class" -DfailIfNoTests=false -q 2>&1) \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

echo
echo "verify-SBDEV-2238-4.2 — running acceptance checks"
echo "  REPO_ROOT=$REPO_ROOT"
echo "  API_ROOT=$API_ROOT"
echo

# --- 1. Fix B — RestPayloadLogSummary utility presence ---------------------

section "1. Fix B — RestPayloadLogSummary utility"

check "Fix B: RestPayloadLogSummary.java exists" \
    test -f "$UTIL"

check "Fix B: RestPayloadLogSummary declares public static of(...)" \
    grep -qE "public[[:space:]]+static[[:space:]].*[[:space:]]of[[:space:]]*\(" "$UTIL"

check "Fix B: RestPayloadLogSummary emits 'size=' token" \
    grep -qE '"size=' "$UTIL"

check "Fix B: RestPayloadLogSummary handles null list (early return / null check)" \
    grep -qE "items[[:space:]]*==[[:space:]]*null|null[[:space:]]*==[[:space:]]*items|Objects\.isNull\(items" "$UTIL"

# --- 2. Fix B — call-site applications in three named controllers ----------

section "2. Fix B — named-controller call-sites use RestPayloadLogSummary"

check "Fix B: OrderRestController imports RestPayloadLogSummary" \
    grep -qE "import[[:space:]]+.*\.util\.RestPayloadLogSummary" "$ORDER_CTRL"

check "Fix B: OrderRestController references RestPayloadLogSummary.of" \
    grep -qE "RestPayloadLogSummary\.of\(" "$ORDER_CTRL"

check "Fix B: AdviceRestController imports RestPayloadLogSummary" \
    grep -qE "import[[:space:]]+.*\.util\.RestPayloadLogSummary" "$ADVICE_CTRL"

check "Fix B: AdviceRestController references RestPayloadLogSummary.of" \
    grep -qE "RestPayloadLogSummary\.of\(" "$ADVICE_CTRL"

check "Fix B: SkuRestController imports RestPayloadLogSummary" \
    grep -qE "import[[:space:]]+.*\.util\.RestPayloadLogSummary" "$SKU_CTRL"

check "Fix B: SkuRestController references RestPayloadLogSummary.of" \
    grep -qE "RestPayloadLogSummary\.of\(" "$SKU_CTRL"

# Negative — no LOG.info that passes a list-like variable directly (i.e. without .size() or summary).
# Allowed: LOG.info(... orderBatchList.size() ...), LOG.info(... RestPayloadLogSummary.of(orderBatchList, ...) ...).
# Forbidden: LOG.info(... orderBatchList ...) where the next char is not `.` (so .size() or method calls remain allowed).

checkneg "Fix B NEGATIVE: OrderRestController has no LOG.info that passes orderBatchList without .method()" \
    grep -nE 'LOG\.info\([^)]*orderBatchList[^.)]' "$ORDER_CTRL"

checkneg "Fix B NEGATIVE: AdviceRestController has no LOG.info that passes adviceList without .method()" \
    grep -nE 'LOG\.info\([^)]*adviceList[^.)]' "$ADVICE_CTRL"

checkneg "Fix B NEGATIVE: SkuRestController has no LOG.info that passes skuList without .method()" \
    grep -nE 'LOG\.info\([^)]*skuList[^.)]' "$SKU_CTRL"

# --- 3. Fix A — FileImportController demoted body-logging lines ------------

section "3. Fix A — FileImportController body-logging demoted to DEBUG"

check "Fix A: FileImportController.java exists" \
    test -f "$FILEIMPORT_CTRL"

check "Fix A: FileImportController contains at least one LOG.debug('create finished with {}', adviceList) line" \
    grep -qE 'LOG\.debug\("create finished with \{\}", adviceList\)' "$FILEIMPORT_CTRL"

checkneg "Fix A NEGATIVE: FileImportController has no LOG.info('create finished with {}', adviceList) — full-list INFO log gone" \
    grep -qE 'LOG\.info\("create finished with \{\}", adviceList\)' "$FILEIMPORT_CTRL"

checkneg "Fix A NEGATIVE: FileImportController has no LOG.info that passes adviceList without .method() (general)" \
    grep -nE 'LOG\.info\([^)]*adviceList[^.)]' "$FILEIMPORT_CTRL"

# --- 4. Fix C — IdempotencyFilter MDC push/remove --------------------------

section "4. Fix C — IdempotencyFilter MDC push and remove"

check "Fix C: IdempotencyFilter.java exists" \
    test -f "$IDEMP_FILTER"

check "Fix C: IdempotencyFilter imports org.slf4j.MDC" \
    grep -qE "import[[:space:]]+org\.slf4j\.MDC" "$IDEMP_FILTER"

check "Fix C: IdempotencyFilter calls MDC.put(\"idempotencyKey\", ...)" \
    grep -qE 'MDC\.put\(\s*"idempotencyKey"' "$IDEMP_FILTER"

check "Fix C: IdempotencyFilter calls MDC.remove(\"idempotencyKey\")" \
    grep -qE 'MDC\.remove\(\s*"idempotencyKey"' "$IDEMP_FILTER"

check "Fix C: IdempotencyFilter wraps remove in a finally block" \
    grep -qE '\bfinally\b' "$IDEMP_FILTER"

# --- 5. Fix C — logback-spring.xml references idempotencyKey ---------------

section "5. Fix C — logback-spring.xml exposes idempotencyKey via MDC"

check "Fix C: logback-spring.xml exists" \
    test -f "$LOGBACK"

check "Fix C: logback-spring.xml references idempotencyKey (MDC pattern token)" \
    grep -qE "idempotencyKey" "$LOGBACK"

# --- 6. Tests --------------------------------------------------------------

section "6. Unit tests"

check "Test: RestPayloadLogSummaryUnitTest exists" \
    test -f "$UTIL_TEST"

check "Test: RestPayloadLogSummaryUnitTest covers null-list case" \
    grep -qE 'nullList|of_null|null.*returnsSizeZero' "$UTIL_TEST"

check "Test: RestPayloadLogSummaryUnitTest covers ellipsis after MAX_IDS" \
    grep -qE 'ellipsis|sixItems|moreThan|exceeds|truncat' "$UTIL_TEST"

check "Test: FileImportControllerTest asserts no INFO line for adviceList body-log" \
    grep -qE 'doesNotLogFullListAtInfo|ListAppender' "$FILEIMPORT_TEST"

check "Test: IdempotencyFilterUnitTest exists" \
    test -f "$IDEMP_TEST"

check "Test: IdempotencyFilterUnitTest covers MDC clean after request" \
    grep -qE 'mdcClean|mdcDoesNotLeak|removesIdempotencyKey' "$IDEMP_TEST"

# --- 7. Behavioural — mvn test ---------------------------------------------

section "7. Behavioural — targeted unit tests pass"

if command -v mvn >/dev/null 2>&1; then
    if test -d "$API_ROOT"; then
        check "mvn test -Dtest=RestPayloadLogSummaryUnitTest passes" \
            mvn_test_passes RestPayloadLogSummaryUnitTest
        check "mvn test -Dtest=IdempotencyFilterUnitTest passes" \
            mvn_test_passes IdempotencyFilterUnitTest
        check "mvn test -Dtest=FileImportControllerTest passes" \
            mvn_test_passes FileImportControllerTest
    else
        skip "mvn test (targeted)" "API_ROOT not present"
    fi
else
    skip "mvn test (targeted)" "mvn not on PATH"
fi

# --- Summary ---------------------------------------------------------------

echo
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
exit "$FAIL"
