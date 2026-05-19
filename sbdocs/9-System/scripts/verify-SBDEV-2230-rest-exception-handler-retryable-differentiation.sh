#!/usr/bin/env bash
# verify-SBDEV-2230-rest-exception-handler-retryable-differentiation.sh
#
# Machine-checkable acceptance for SBDEV-2230 — REST exception handler
# does not differentiate retryable vs non-retryable failures.
#
# Run:
#   bash sbdocs/9-System/scripts/verify-SBDEV-2230-rest-exception-handler-retryable-differentiation.sh
#
# The 13 acceptance criteria from §12.1:
#   1.  DataAccessResourceFailureException → 503 + Retry-After + retryable=true
#   2.  CannotAcquireLockException        → 503 + Retry-After + retryable=true
#   3.  DeadlockLoserDataAccessException  → 503 + Retry-After + retryable=true
#   4.  RecoverableDataAccessException    → 503 + Retry-After + retryable=true
#   5.  QueryTimeoutException             → 503 + Retry-After + retryable=true
#   6.  FacadeException                   → 500 + retryable=false
#   7.  ObjectOptimisticLockingFailureException → 409 + retryable=true (status unchanged)
#   8.  bare PessimisticLockingFailureException → 409 + retryable=true (status unchanged)
#   9.  BusinessException                 → 422 + retryable=false (status unchanged)
#  10.  EntityNotFoundException           → 404 + retryable=false (status unchanged)
#  11.  catch-all Exception               → 500 + retryable=false
#  12.  mvn test -Dtest=RestExceptionHandlerUnitTest exits 0
#  13.  No existing handler regressions

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

REH="src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java"
REEH="src/main/java/net/aim_ai/wms/exceptions/RestEndpointExceptionHandler.java"
TEST="src/test/java/net/aim_ai/wms/unit/exceptions/RestExceptionHandlerUnitTest.java"

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <command...>
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

file_contains() { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

file_contains_n_times() {
    local pattern=$1 file=$2 n=$3
    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

mvn_test_passes() {
    local test_class=$1
    mvn test -Dtest="$test_class" -DfailIfNoTests=false -q 2>&1 | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# === Sanity: both files exist ===============================================

check_files_exist_REH()  { [ -f "$REH" ]; }
check_files_exist_REEH() { [ -f "$REEH" ]; }
check_files_exist_TEST() { [ -f "$TEST" ]; }

# === H.1 — DataAccessResourceFailureException ===============================

check_H1_handler_present() {
    file_contains '@ExceptionHandler\(DataAccessResourceFailureException\.class\)' "$REEH"
}
check_H1_status_503() {
    grep -A 8 'handleResourceFailure' "$REEH" | grep -qE 'HttpStatus\.SERVICE_UNAVAILABLE'
}
check_H1_retry_after_30() {
    grep -A 12 'handleResourceFailure' "$REEH" | grep -qE '"Retry-After"' \
        && grep -qE 'RETRY_AFTER_SECONDS\s*=\s*"30"' "$REEH"
}
check_H1_retryable_true() {
    grep -A 12 'handleResourceFailure' "$REEH" | grep -qE 'setProperty\("retryable",\s*true\)'
}

# === H.2 — CannotAcquireLockException =======================================

check_H2_handler_present() {
    file_contains '@ExceptionHandler\(CannotAcquireLockException\.class\)' "$REEH"
}
check_H2_status_503() {
    grep -A 8 'handleCannotAcquireLock' "$REEH" | grep -qE 'HttpStatus\.SERVICE_UNAVAILABLE'
}
check_H2_retry_after() {
    grep -A 12 'handleCannotAcquireLock' "$REEH" | grep -qE '"Retry-After"'
}
check_H2_retryable_true() {
    grep -A 12 'handleCannotAcquireLock' "$REEH" | grep -qE 'setProperty\("retryable",\s*true\)'
}

# === H.2b — DeadlockLoserDataAccessException ================================

check_H2b_handler_present() {
    file_contains '@ExceptionHandler\(DeadlockLoserDataAccessException\.class\)' "$REEH"
}
check_H2b_status_503() {
    grep -A 8 'handleDeadlockLoser' "$REEH" | grep -qE 'HttpStatus\.SERVICE_UNAVAILABLE'
}
check_H2b_retry_after() {
    grep -A 12 'handleDeadlockLoser' "$REEH" | grep -qE '"Retry-After"'
}
check_H2b_retryable_true() {
    grep -A 12 'handleDeadlockLoser' "$REEH" | grep -qE 'setProperty\("retryable",\s*true\)'
}

# === H.2c — RecoverableDataAccessException ==================================

check_H2c_handler_present() {
    file_contains '@ExceptionHandler\(RecoverableDataAccessException\.class\)' "$REEH"
}
check_H2c_status_503() {
    grep -A 8 'handleRecoverableDataAccess' "$REEH" | grep -qE 'HttpStatus\.SERVICE_UNAVAILABLE'
}
check_H2c_retry_after() {
    grep -A 12 'handleRecoverableDataAccess' "$REEH" | grep -qE '"Retry-After"'
}
check_H2c_retryable_true() {
    grep -A 12 'handleRecoverableDataAccess' "$REEH" | grep -qE 'setProperty\("retryable",\s*true\)'
}

# === H.3 — QueryTimeoutException ============================================

check_H3_handler_present() {
    file_contains '@ExceptionHandler\(QueryTimeoutException\.class\)' "$REEH"
}
check_H3_status_503() {
    grep -A 8 'handleQueryTimeout' "$REEH" | grep -qE 'HttpStatus\.SERVICE_UNAVAILABLE'
}
check_H3_retry_after() {
    grep -A 12 'handleQueryTimeout' "$REEH" | grep -qE '"Retry-After"'
}
check_H3_retryable_true() {
    grep -A 12 'handleQueryTimeout' "$REEH" | grep -qE 'setProperty\("retryable",\s*true\)'
}

# === H.4 — FacadeException ==================================================

check_H4_handler_present() {
    file_contains '@ExceptionHandler\(FacadeException\.class\)' "$REEH"
}
check_H4_status_500() {
    grep -A 8 'handleFacadeException' "$REEH" | grep -qE 'HttpStatus\.INTERNAL_SERVER_ERROR'
}
check_H4_no_retry_after() {
    # H.4 must NOT carry a Retry-After header (permanent failure)
    ! (grep -A 12 'handleFacadeException' "$REEH" | grep -qE '"Retry-After"')
}
check_H4_retryable_false() {
    grep -A 12 'handleFacadeException' "$REEH" | grep -qE 'setProperty\("retryable",\s*false\)'
}

# === H.5 — ObjectOptimisticLockingFailureException (existing handler) =======

check_H5_status_unchanged_409() {
    grep -A 8 'handleOptimisticLock' "$REH" | grep -qE 'HttpStatus\.CONFLICT'
}
check_H5_retryable_true() {
    grep -A 8 'handleOptimisticLock' "$REH" | grep -qE 'setProperty\("retryable",\s*true\)'
}

# === H.6 — bare PessimisticLockingFailureException (existing handler) =======

check_H6_status_unchanged_409() {
    grep -A 8 'handlePessimisticLock' "$REH" | grep -qE 'HttpStatus\.CONFLICT'
}
check_H6_retryable_true() {
    grep -A 8 'handlePessimisticLock' "$REH" | grep -qE 'setProperty\("retryable",\s*true\)'
}

# === H.7 — EntityNotFoundException (existing handler) =======================

check_H7_status_unchanged_404() {
    grep -A 8 'handleEntityNotFound' "$REH" | grep -qE 'HttpStatus\.NOT_FOUND'
}
check_H7_retryable_false() {
    grep -A 8 'handleEntityNotFound' "$REH" | grep -qE 'setProperty\("retryable",\s*false\)'
}

# === H.8 — BusinessException (existing handler) =============================

check_H8_status_unchanged_422() {
    grep -A 8 'handleBusinessException' "$REH" | grep -qE 'HttpStatus\.UNPROCESSABLE_ENTITY'
}
check_H8_retryable_false() {
    grep -A 8 'handleBusinessException' "$REH" | grep -qE 'setProperty\("retryable",\s*false\)'
}

# === H.9 — catch-all Exception ==============================================

check_H9_handler_present() {
    file_contains '@ExceptionHandler\(Exception\.class\)' "$REEH"
}
check_H9_NOT_runtime_exception() {
    # Must NOT be RuntimeException.class (FacadeException is a checked exception)
    file_not_contains '@ExceptionHandler\(RuntimeException\.class\)' "$REEH"
}
check_H9_status_500() {
    grep -A 8 'handleUnexpected' "$REEH" | grep -qE 'HttpStatus\.INTERNAL_SERVER_ERROR'
}
check_H9_retryable_false() {
    grep -A 12 'handleUnexpected' "$REEH" | grep -qE 'setProperty\("retryable",\s*false\)'
}

# === Class-level annotation scope check (basePackages, not assignableTypes) ==

check_advice_scoped_to_rest_package() {
    # New advice must be scoped to the controller.rest package only.
    file_contains '@ControllerAdvice\(basePackages\s*=\s*"net\.aim_ai\.wms\.controller\.rest"\)' "$REEH"
}

check_existing_advice_unchanged_scope() {
    # Existing advice must remain unscoped (@ControllerAdvice with NO args).
    grep -E '^@ControllerAdvice' "$REH" | grep -qE '^@ControllerAdvice$'
}

# === No status-code regressions on H.5-H.8 ==================================
# These check that the patches were ADDITIVE only — no status code changed.

check_no_status_change_optimistic() {
    # H.5 line still uses CONFLICT not SERVICE_UNAVAILABLE
    grep -A 8 'handleOptimisticLock' "$REH" | grep -qvE 'SERVICE_UNAVAILABLE' || return 1
    grep -A 8 'handleOptimisticLock' "$REH" | grep -qE 'HttpStatus\.CONFLICT'
}

check_no_retry_after_on_existing_handlers() {
    # H.5-H.8 must NOT carry Retry-After headers
    ! grep -qE '"Retry-After"' "$REH"
}

# === Existing handlers (non-patched) — no regression ========================

check_existing_invalid_parameters_intact() {
    file_contains '@ExceptionHandler\(ApiInvalidParameterException\.class\)' "$REH" \
        && grep -A 6 'handleInvalidParameters' "$REH" | grep -qE 'invalidParameterStatus'
}
check_existing_constraint_intact() {
    file_contains '@ExceptionHandler\(ApiConstraintViolationException\.class\)' "$REH" \
        && grep -A 6 'handleConstraintException' "$REH" | grep -qE 'constraintViolationStatus'
}
check_existing_validation_intact() {
    file_contains '@ExceptionHandler\(MethodArgumentNotValidException\.class\)' "$REH"
}
check_existing_missing_user_intact() {
    file_contains '@ExceptionHandler\(ApiMissingUserException\.class\)' "$REH"
}
check_existing_sso_create_intact() {
    file_contains '@ExceptionHandler\(SsoCreateUserException\.class\)' "$REH"
}
check_existing_sso_group_intact() {
    file_contains '@ExceptionHandler\(SsoGroupMembershipException\.class\)' "$REH"
}
check_existing_sso_general_intact() {
    file_contains '@ExceptionHandler\(SsoException\.class\)' "$REH"
}
check_existing_nosuchelement_intact() {
    # NoSuchElementException stays at 404 (out of scope for retryable property)
    file_contains '@ExceptionHandler\(NoSuchElementException\.class\)' "$REH" \
        && grep -A 6 'handleNoSuchElement' "$REH" | grep -qE 'HttpStatus\.NOT_FOUND'
}

# === Test class extension checks ============================================

check_test_class_extended_new_nested_classes() {
    # Look for at least 5 new @Nested test inner classes for the new handlers
    file_contains 'class HandleResourceFailure'         "$TEST" \
        && file_contains 'class HandleCannotAcquireLock'    "$TEST" \
        && file_contains 'class HandleDeadlockLoser'        "$TEST" \
        && file_contains 'class HandleRecoverableDataAccess' "$TEST" \
        && file_contains 'class HandleQueryTimeout'         "$TEST" \
        && file_contains 'class HandleFacadeException'      "$TEST" \
        && file_contains 'class HandleUnexpected'           "$TEST"
}

check_test_throwing_controller_extended() {
    # ThrowingController gains new endpoints
    file_contains 'throwResourceFailure'        "$TEST" \
        && file_contains 'throwCannotAcquireLock'   "$TEST" \
        && file_contains 'throwDeadlockLoser'       "$TEST" \
        && file_contains 'throwRecoverableDataAccess' "$TEST" \
        && file_contains 'throwQueryTimeout'        "$TEST" \
        && file_contains 'throwFacadeException'     "$TEST" \
        && file_contains 'throwUnexpectedException' "$TEST"
}

check_test_wires_new_advice_in_mockmvc() {
    file_contains 'setControllerAdvice\(new RestEndpointExceptionHandler\(\)\)' "$TEST"
}

check_test_asserts_retryable_property() {
    # Tests must actually check the "retryable" body property
    file_contains_n_times '"retryable"' "$TEST" 6
}

check_test_asserts_retry_after_header() {
    file_contains '"Retry-After"' "$TEST" \
        || file_contains 'Retry-After' "$TEST"
}

# === Maven test execution ===================================================

check_mvn_RestExceptionHandlerUnitTest_passes() {
    mvn_test_passes RestExceptionHandlerUnitTest
}

# === Run the suite ==========================================================

echo
echo "verify-SBDEV-2230 — running acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run files-1 "Existing RestExceptionHandler.java present"      check_files_exist_REH
run files-2 "New RestEndpointExceptionHandler.java present"   check_files_exist_REEH
run files-3 "RestExceptionHandlerUnitTest.java present"        check_files_exist_TEST
echo

run scope-1 "New advice scoped to controller.rest basePackages" check_advice_scoped_to_rest_package
run scope-2 "Existing advice remains unscoped (no basePackages)" check_existing_advice_unchanged_scope
echo

run H.1-a "H.1 DataAccessResourceFailureException handler present"  check_H1_handler_present
run H.1-b "H.1 returns 503"                                         check_H1_status_503
run H.1-c "H.1 emits Retry-After: 30"                               check_H1_retry_after_30
run H.1-d "H.1 sets retryable=true"                                 check_H1_retryable_true
echo

run H.2-a "H.2 CannotAcquireLockException handler present"          check_H2_handler_present
run H.2-b "H.2 returns 503"                                         check_H2_status_503
run H.2-c "H.2 emits Retry-After"                                   check_H2_retry_after
run H.2-d "H.2 sets retryable=true"                                 check_H2_retryable_true
echo

run H.2b-a "H.2b DeadlockLoserDataAccessException handler present"  check_H2b_handler_present
run H.2b-b "H.2b returns 503"                                       check_H2b_status_503
run H.2b-c "H.2b emits Retry-After"                                 check_H2b_retry_after
run H.2b-d "H.2b sets retryable=true"                               check_H2b_retryable_true
echo

run H.2c-a "H.2c RecoverableDataAccessException handler present"    check_H2c_handler_present
run H.2c-b "H.2c returns 503"                                       check_H2c_status_503
run H.2c-c "H.2c emits Retry-After"                                 check_H2c_retry_after
run H.2c-d "H.2c sets retryable=true"                               check_H2c_retryable_true
echo

run H.3-a "H.3 QueryTimeoutException handler present"               check_H3_handler_present
run H.3-b "H.3 returns 503"                                         check_H3_status_503
run H.3-c "H.3 emits Retry-After"                                   check_H3_retry_after
run H.3-d "H.3 sets retryable=true"                                 check_H3_retryable_true
echo

run H.4-a "H.4 FacadeException handler present"                     check_H4_handler_present
run H.4-b "H.4 returns 500"                                         check_H4_status_500
run H.4-c "H.4 does NOT emit Retry-After"                           check_H4_no_retry_after
run H.4-d "H.4 sets retryable=false"                                check_H4_retryable_false
echo

run H.5-a "H.5 ObjectOptimisticLock status unchanged 409"           check_H5_status_unchanged_409
run H.5-b "H.5 sets retryable=true"                                 check_H5_retryable_true
echo

run H.6-a "H.6 bare PessimisticLock status unchanged 409"           check_H6_status_unchanged_409
run H.6-b "H.6 sets retryable=true"                                 check_H6_retryable_true
echo

run H.7-a "H.7 EntityNotFound status unchanged 404"                 check_H7_status_unchanged_404
run H.7-b "H.7 sets retryable=false"                                check_H7_retryable_false
echo

run H.8-a "H.8 BusinessException status unchanged 422"              check_H8_status_unchanged_422
run H.8-b "H.8 sets retryable=false"                                check_H8_retryable_false
echo

run H.9-a "H.9 catch-all @ExceptionHandler(Exception.class) present" check_H9_handler_present
run H.9-b "H.9 is NOT RuntimeException.class (must cover checked exceptions)" check_H9_NOT_runtime_exception
run H.9-c "H.9 returns 500"                                         check_H9_status_500
run H.9-d "H.9 sets retryable=false"                                check_H9_retryable_false
echo

run reg-1 "No status-change regression on H.5 (still CONFLICT)"     check_no_status_change_optimistic
run reg-2 "No Retry-After header bled into existing RestExceptionHandler" check_no_retry_after_on_existing_handlers
run reg-3 "Existing handleInvalidParameters intact"                 check_existing_invalid_parameters_intact
run reg-4 "Existing handleConstraintException intact"               check_existing_constraint_intact
run reg-5 "Existing handleValidationException intact"               check_existing_validation_intact
run reg-6 "Existing handleMissingUser intact"                       check_existing_missing_user_intact
run reg-7 "Existing handleSsoCreateUserError intact"                check_existing_sso_create_intact
run reg-8 "Existing handleSsoGroupLeaveOrJoinException intact"      check_existing_sso_group_intact
run reg-9 "Existing handleGeneralSsoException intact"               check_existing_sso_general_intact
run reg-10 "Existing handleNoSuchElement (404) intact"              check_existing_nosuchelement_intact
echo

run test-1 "Test class adds new @Nested classes for new handlers"   check_test_class_extended_new_nested_classes
run test-2 "Test class adds new ThrowingController endpoints"       check_test_throwing_controller_extended
run test-3 "Test wires new advice via setControllerAdvice"          check_test_wires_new_advice_in_mockmvc
run test-4 "Tests assert retryable body property"                   check_test_asserts_retryable_property
run test-5 "Tests assert Retry-After header"                        check_test_asserts_retry_after_header
echo

run mvn-1 "mvn test -Dtest=RestExceptionHandlerUnitTest passes"     check_mvn_RestExceptionHandlerUnitTest_passes
echo

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
