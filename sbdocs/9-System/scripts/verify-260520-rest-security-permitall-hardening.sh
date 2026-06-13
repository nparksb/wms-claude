#!/usr/bin/env bash
# verify-260520-rest-security-permitall-hardening.sh
# Machine-checkable acceptance for plan: 260520-rest-security-permitall-hardening
#
# Purpose
# -------
# Verifies that /rest/** has been moved from permitAll() to authenticated()
# in SecurityConfiguration, that SecurityDisabledWarning exists as a standalone
# component, and that the required test class is in place.
#
# Usage
# -----
#   $ bash sbdocs/9-System/scripts/verify-260520-rest-security-permitall-hardening.sh
#
# Override project root for a different checkout:
#   $ PROJECT_ROOT=/path/to/v2/wms2-api bash verify-...sh
#
# Exit code 0 when all checks pass, non-zero otherwise.
# The implementing agent's end-of-task report MUST paste this script's final line:
#   Result: N pass, 0 fail, M skip

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
DOCS_ROOT="${DOCS_ROOT:-/home/nampark/dev/wms-claude/sbdocs}"
MVN="${MVN:-/home/nampark/.sdkman/candidates/maven/3.9.15/bin/mvn}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-8s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }

SC="src/main/java/net/aim_ai/wms/SecurityConfiguration.java"
SDW="src/main/java/net/aim_ai/wms/SecurityDisabledWarning.java"
TEST="src/test/java/net/aim_ai/wms/integration/config/SecurityFilterChainIntegrationTest.java"
OMS_MAP="${DOCS_ROOT}/3-Resources/architecture/wms2-oms-integration-map.md"

echo
echo "verify-260520-rest-security-permitall-hardening"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  DOCS_ROOT=$DOCS_ROOT"
echo

# ---------------------------------------------------------------------------
# AC-1  /rest/** REMOVED from permitAll() block
# ---------------------------------------------------------------------------
check_ac1_permitall_gone() {
    # The permitAll() block must not contain /rest/**
    # Look for /rest/** anywhere inside a requestMatchers(...).permitAll() call
    # Negative: "rest/**" should not appear on a line adjacent to .permitAll()
    file_not_contains '"/rest/\*\*"' "$SC" ||
        # More precise: check that the permitAll block no longer contains /rest/**
        # by checking the specific old pattern
        ! grep -A20 '\.permitAll\(\)' "$SC" 2>/dev/null | grep -q '"/rest/\*\*"'
}

check_ac1_negative() {
    # Simpler: the string "/rest/**" must not appear within 5 lines before .permitAll()
    ! grep -B5 '\.permitAll()' "$SC" | grep -q '"/rest/\*\*"'
}

run AC-1  "/rest/** NOT adjacent to .permitAll() in SecurityConfiguration"  check_ac1_negative

# ---------------------------------------------------------------------------
# AC-1b .requestMatchers("/rest/**").authenticated() is present
# ---------------------------------------------------------------------------
check_ac1b_authenticated_rule() {
    file_contains '\.requestMatchers\("/rest/\*\*"\)\.authenticated\(\)' "$SC"
}

run AC-1b ".requestMatchers(\"/rest/**\").authenticated() present in SecurityConfiguration"  check_ac1b_authenticated_rule

# ---------------------------------------------------------------------------
# AC-2  SecurityFilterChainIntegrationTest exists with restGet_noToken test
# ---------------------------------------------------------------------------
check_ac2_test_class_exists() {
    [ -f "$TEST" ]
}

check_ac2_test_method_exists() {
    file_contains 'restGet_noToken_returns401|restGet.*noToken.*401' "$TEST"
}

run AC-2a "SecurityFilterChainIntegrationTest file exists"          check_ac2_test_class_exists
run AC-2b "restGet_noToken_returns401 test method present"          check_ac2_test_method_exists

# ---------------------------------------------------------------------------
# AC-3  WithEnforceFalse nested class present (AC-3 property isolation)
# ---------------------------------------------------------------------------
check_ac3_nested_class() {
    file_contains 'class WithEnforceFalse|WithEnforceFalse' "$TEST"
}

run AC-3  "WithEnforceFalse nested class present in test"           check_ac3_nested_class

# ---------------------------------------------------------------------------
# AC-4  WithSecurityDisabled nested class present (AC-5 test home)
# ---------------------------------------------------------------------------
check_ac4_security_disabled_class() {
    file_contains 'class WithSecurityDisabled|WithSecurityDisabled' "$TEST"
}

run AC-4  "WithSecurityDisabled nested class present in test"       check_ac4_security_disabled_class

# ---------------------------------------------------------------------------
# AC-5  SecurityDisabledWarning.java exists as standalone component
# ---------------------------------------------------------------------------
check_ac5_file_exists() {
    [ -f "$SDW" ]
}

check_ac5_conditional_havingvalue_false() {
    file_contains 'havingValue\s*=\s*"false"' "$SDW"
}

check_ac5_not_nested_in_security_config() {
    # SecurityDisabledWarning must NOT be an inner class of SecurityConfiguration
    # (it must be a top-level file)
    [ -f "$SDW" ] && ! grep -q 'class SecurityDisabledWarning' "$SC"
}

run AC-5a "SecurityDisabledWarning.java file exists"                check_ac5_file_exists
run AC-5b "ConditionalOnProperty havingValue=\"false\" present"     check_ac5_conditional_havingvalue_false
run AC-5c "SecurityDisabledWarning is NOT nested in SecurityConfiguration"  check_ac5_not_nested_in_security_config

# ---------------------------------------------------------------------------
# AC-6  SecurityDisabledWarning uses jakarta (not javax) PostConstruct
# ---------------------------------------------------------------------------
check_ac6_jakarta_import() {
    file_contains 'import jakarta\.annotation\.PostConstruct' "$SDW"
}

check_ac6_no_javax_import() {
    file_not_contains 'import javax\.annotation\.PostConstruct' "$SDW"
}

run AC-6a "SecurityDisabledWarning imports jakarta.annotation.PostConstruct"  check_ac6_jakarta_import
run AC-6b "SecurityDisabledWarning does NOT import javax.annotation.PostConstruct"  check_ac6_no_javax_import

# ---------------------------------------------------------------------------
# AC-7  mvn test passes for SecurityFilterChainIntegrationTest
# ---------------------------------------------------------------------------
check_ac7_mvn_test() {
    "$MVN" test -Dtest=SecurityFilterChainIntegrationTest \
        -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

if [ -f "$TEST" ]; then
    run AC-7  "mvn test SecurityFilterChainIntegrationTest passes"  check_ac7_mvn_test
else
    skip AC-7 "mvn test SecurityFilterChainIntegrationTest" "test file not yet created"
fi

# ---------------------------------------------------------------------------
# AC-8  wms2-oms-integration-map.md updated with last_verified: 2026-05-20
# ---------------------------------------------------------------------------
check_ac8_doc_last_verified() {
    [ -f "$OMS_MAP" ] && file_contains 'last_verified:\s*2026-05-20' "$OMS_MAP"
}

run AC-8  "wms2-oms-integration-map.md last_verified: 2026-05-20"  check_ac8_doc_last_verified

# ---------------------------------------------------------------------------
echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
echo
[ "$FAIL" -eq 0 ]
