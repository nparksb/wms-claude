#!/usr/bin/env bash
# verify-SBDEV-2218-parallelstream-against-hibernate-session.sh
#
# Acceptance for SBDEV-2218 — calculateUnitLoadAmounts parallelStream regression guard (v2).
# Plan:  sbdocs/1-Projects/wms2/plan/SBDEV-2218-parallelstream-against-hibernate-session.md
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2218-parallelstream-against-hibernate-session.sh
#
# Exit code is 0 if all checks pass, non-zero otherwise. The implementing
# agent's end-of-task report MUST paste this script's output before the work
# is accepted.
#
# Pre-implementation baseline expectation: 3 PRE checks PASS (already-done),
# Fix A/B/C/D checks FAIL (~10-12 fails expected).

# Ensure mvn is on PATH (sdkman manages the Maven installation on this machine).
# Source before set -u because sdkman-init.sh references ZSH_VERSION which is
# unbound in bash — set -u would cause an immediate exit.
# shellcheck source=/dev/null
[ -f /home/nampark/.sdkman/bin/sdkman-init.sh ] && source /home/nampark/.sdkman/bin/sdkman-init.sh

set -u

# Resolve PROJECT_ROOT relative to this script's own location so the script
# works regardless of which directory it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../v2/wms2-api" 2>/dev/null && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()      { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()  { ! grep -qE "$1" "$2" 2>/dev/null; }

# Multi-line variant — uses perl -0777 so the regex can span newlines.
file_contains_ml() {
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}

mvn_test_passes() {
    # n1 fix: also verify at least 1 test ran — -DfailIfNoTests=false lets an
    # empty selector silently pass. Check for "Tests run: [1-9]" in the log.
    local cls=$1
    local tmplog
    tmplog=$(mktemp /tmp/mvn-test-XXXXXX.log)
    if mvn test -Dtest="$cls" -DfailIfNoTests=false >"$tmplog" 2>&1 \
            && grep -qE "Tests run: [1-9]" "$tmplog"; then
        rm -f "$tmplog"
        return 0
    else
        echo "  [mvn output tail for $cls:]" >&2
        tail -20 "$tmplog" >&2
        rm -f "$tmplog"
        return 1
    fi
}

mvn_it_passes() {
    local cls=$1
    local tmplog
    tmplog=$(mktemp /tmp/mvn-it-XXXXXX.log)
    if mvn jacoco:prepare-agent failsafe:integration-test -Dit.test="$cls" -DfailIfNoTests=false >"$tmplog" 2>&1; then
        rm -f "$tmplog"
        return 0
    else
        echo "  [mvn IT output tail for $cls:]" >&2
        tail -20 "$tmplog" >&2
        rm -f "$tmplog"
        return 1
    fi
}

SVC=src/main/java/net/aim_ai/wms/service
TST_CFG=src/test/java/net/aim_ai/wms/unit/config
ITT=src/test/java/net/aim_ai/wms/integration/service

CSVC=$SVC/CustomerorderBatchService.java
ARCH=$TST_CFG/ParallelStreamSafetyArchTest.java
RGIT=$ITT/CustomerorderBatchServiceParallelStreamRegressionIT.java

echo
echo "verify-SBDEV-2218 — parallelStream regression-guard acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# === PRE — already-done baseline (3 PASS expected before any new work) =======

# PRE-1: NO class-level @Transactional on CustomerorderBatchService.
# The @Service annotation immediately precedes "public class CustomerorderBatchService".
# A class-level @Transactional would appear between @Service and the class declaration.
#
# m2 limitation: this regex matches a single-line @Transactional immediately before
# the class declaration (one \n gap). A multi-line form such as:
#   @Transactional(
#       value = "...")
#   public class CustomerorderBatchService
# would slip past because the closing ")" is on a different line before the class keyword.
# This is forward-looking only — the current file has no class-level annotation at all
# (verified 2026-05-09 via direct source read). If a multi-line form is ever introduced,
# the check would need a broader perl window. Acceptable risk: the ArchUnit test (Fix A)
# provides a runtime backstop for the method-level rule; class-level @Transactional
# removal is a one-time already-shipped fix (58ad0f36) that is extremely unlikely to regress.
run PRE-1 "Prereq — NO class-level @Transactional on CustomerorderBatchService" \
    bash -c '
        # Look for an @Transactional line that immediately precedes the class declaration
        # within ~5 lines of "public class CustomerorderBatchService".
        ! perl -0777 -ne "exit 0 if /\@Transactional[^\n]*\n[^\n]{0,50}public\s+class\s+CustomerorderBatchService/m; exit 1" '"$CSVC"' 2>/dev/null
    '

# PRE-2: calculateUnitLoadAmounts uses sequential .stream() and Collectors.toMap.
run PRE-2 "Prereq — calculateUnitLoadAmounts uses sequential unitLoads.stream().collect" \
    file_contains_ml 'unitLoads\.stream\(\)\s*\n?\s*\.collect' "$CSVC"

# PRE-3: NO parallelStream invocation in CustomerorderBatchService.java.
run PRE-3 "Prereq — NO .parallelStream() invocation in CustomerorderBatchService.java" \
    file_not_contains '\.parallelStream\s*\(' "$CSVC"

echo

# === Fix A — ArchUnit regression guard =======================================

run A1 "Fix A — ParallelStreamSafetyArchTest.java exists" \
    test -f "$ARCH"

run A2 "Fix A — ArchUnit test references noClasses().that().resideInAPackage" \
    bash -c 'test -f "'"$ARCH"'" && grep -qE "noClasses\(\)\.that\(\)\.resideInA(ny)?Package" "'"$ARCH"'" 2>/dev/null'

run A3 "Fix A — ArchUnit test references parallelStream as the rule subject" \
    bash -c 'test -f "'"$ARCH"'" && grep -qE "parallelStream" "'"$ARCH"'" 2>/dev/null'

run A4 "Fix A — ArchUnit test also bans BaseStream.parallel()" \
    bash -c 'test -f "'"$ARCH"'" && grep -qE "\"parallel\"|BaseStream" "'"$ARCH"'" 2>/dev/null'

run A5 "Fix A — ArchUnit test references SBDEV-2218 in the .because() rationale" \
    bash -c 'test -f "'"$ARCH"'" && grep -qE "SBDEV-2218" "'"$ARCH"'" 2>/dev/null'

# M1: ..business.. does not exist in v2 — rule must reference ..util.. instead.
run A6 "Fix A — ArchUnit test scopes ..util.. package (not non-existent ..business..)" \
    bash -c 'test -f "'"$ARCH"'" && grep -qE "net\.aim_ai\.wms\.util\.\." "'"$ARCH"'" 2>/dev/null'

run A7 "Fix A — ArchUnit test does NOT reference non-existent ..business.. package" \
    bash -c '! test -f "'"$ARCH"'" || ! grep -qE "net\.aim_ai\.wms\.business\.\." "'"$ARCH"'" 2>/dev/null'

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run A-test "Fix A — mvn test -Dtest=ParallelStreamSafetyArchTest passes" \
        mvn_test_passes ParallelStreamSafetyArchTest
else
    skip A-test "Fix A — ArchUnit test run" "SKIP_MVN=1 set"
fi

echo

# === Fix B — Deterministic-output IT =========================================

run B1 "Fix B — CustomerorderBatchServiceParallelStreamRegressionIT.java exists" \
    test -f "$RGIT"

run B2 "Fix B — IT references the deterministic test method name" \
    bash -c 'test -f "'"$RGIT"'" && grep -qE "calculateUnitLoadAmounts_isDeterministic_acrossRepeatedRuns" "'"$RGIT"'" 2>/dev/null'

run B3 "Fix B — IT references seed size 500 (AC-3 dataset)" \
    bash -c 'test -f "'"$RGIT"'" && grep -qE "\b500\b" "'"$RGIT"'" 2>/dev/null'

run B4 "Fix B — IT references iteration count 100 (AC-3 repeats)" \
    bash -c 'test -f "'"$RGIT"'" && grep -qE "\b100\b" "'"$RGIT"'" 2>/dev/null'

# m4 note: regex matches BaseIntegrationTest AND BaseControllerIntegrationTest (both extend
# the right base class). Both are acceptable for this plan's purposes; accepted as-is.
run B5 "Fix B — IT extends BaseIntegrationTest (H2 PostgreSQL mode per SBDEV-2217 deviation)" \
    bash -c 'test -f "'"$RGIT"'" && grep -qE "extends\s+BaseIntegrationTest" "'"$RGIT"'" 2>/dev/null'

# M2: Unitload.hashCode() is a constant — test must assert hasSize(500) (or equivalent)
# immediately after the first run to fail fast on id=null key collisions from un-flushed entities.
run B6 "Fix B — IT asserts baseline keySet hasSize(500) after first run (fail-fast on key collision)" \
    bash -c 'test -f "'"$RGIT"'" && grep -qE "hasSize\s*\(\s*(unitLoadCount|500)\s*\)|keySet\(\)\s*\)\s*\.hasSize" "'"$RGIT"'" 2>/dev/null'

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run B-test "Fix B — mvn IT for CustomerorderBatchServiceParallelStreamRegressionIT passes" \
        mvn_it_passes CustomerorderBatchServiceParallelStreamRegressionIT
else
    skip B-test "Fix B — IT run" "SKIP_MVN=1 set"
fi

echo

# === Fix C — Back-reference removal ==========================================

run C1 "Fix C — () -> amounts Collector supplier is gone (back-reference removed)" \
    file_not_contains '\(\)\s*->\s*amounts' "$CSVC"

run C2 "Fix C — calculateUnitLoadAmounts uses a renamed memoization map identifier (e.g. memoCache)" \
    bash -c '
        # Fix C path (a) renames the identifier to memoCache OR similar.
        # Accept any identifier OTHER than the original "amounts" that is passed into calc()
        # as the third argument. Conservative check: file references "memoCache" near calc(...) call,
        # OR uses Collectors.toMap with the 3-arg overload (no supplier) inside calculateUnitLoadAmounts.
        perl -0777 -ne "exit 0 if /private\s+Map<Unitload,\s*Integer>\s+calculateUnitLoadAmounts[\s\S]{0,800}memoCache/m; exit 1" "'"$CSVC"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /unitLoads\.stream\(\)\s*\n?\s*\.collect\(Collectors\.toMap\(\s*Function\.identity\(\),[\s\S]{0,200}calc\(unitLoad,\s*itemData,\s*\w+\),\s*\(a,\s*b\)\s*->\s*b\s*\)\s*\)/m; exit 1" "'"$CSVC"'" 2>/dev/null
    '

run C3 "Fix C — Collector uses the 3-arg toMap overload (no supplier) inside calculateUnitLoadAmounts" \
    bash -c '
        # m1 fix: anchor on the SBDEV-2218 regression guard comment (introduced by Fix D)
        # rather than the brittle method-signature literal. The comment immediately precedes
        # the stream call and survives any reformatting of parameter lists or blank lines.
        # Within 800 chars of the marker, the 3-arg toMap form ends with "(a, b) -> b)"
        # with NO 4th "() ->" supplier argument on the same toMap call.
        perl -0777 -ne "exit 0 if /SBDEV-2218 regression guard[\s\S]{0,800}Collectors\.toMap\([\s\S]{0,400}\(a,\s*b\)\s*->\s*b\s*\)\s*;/m; exit 1" "'"$CSVC"'" 2>/dev/null
    '

echo

# === Fix D — Comment hardening (regression marker) ===========================

run D1 "Fix D — CustomerorderBatchService.java references SBDEV-2218 near calculateUnitLoadAmounts" \
    bash -c '
        perl -0777 -ne "exit 0 if /SBDEV-2218[\s\S]{0,800}calculateUnitLoadAmounts/m; exit 1" "'"$CSVC"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /calculateUnitLoadAmounts[\s\S]{0,800}SBDEV-2218/m; exit 1" "'"$CSVC"'" 2>/dev/null
    '

run D2 "Fix D — Comment region cites Hibernate Session (the ticket failure-mode reason)" \
    bash -c '
        perl -0777 -ne "exit 0 if /calculateUnitLoadAmounts[\s\S]{0,800}Hibernate\s+Session/m; exit 1" "'"$CSVC"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /Hibernate\s+Session[\s\S]{0,800}calculateUnitLoadAmounts/m; exit 1" "'"$CSVC"'" 2>/dev/null
    '

run D3 "Fix D — Comment region references ParallelStreamSafetyArchTest by name (cross-link to Fix A)" \
    bash -c '
        perl -0777 -ne "exit 0 if /calculateUnitLoadAmounts[\s\S]{0,1200}ParallelStreamSafetyArchTest/m; exit 1" "'"$CSVC"'" 2>/dev/null \
        || perl -0777 -ne "exit 0 if /ParallelStreamSafetyArchTest[\s\S]{0,1200}calculateUnitLoadAmounts/m; exit 1" "'"$CSVC"'" 2>/dev/null
    '

echo

# === Codebase-wide hardening =================================================

# H1: Zero parallelStream invocations in production source code.
# Excludes Javadoc/inline comment lines (those starting with optional whitespace + "*" or "//").
# The TenantAwareTaskDecorator's Javadoc reference must be excluded.
run H1 "Hardening — zero .parallelStream() invocations in src/main/java (excluding Javadoc/comments)" \
    bash -c '
        count=$(grep -rn "\.parallelStream\s*(" src/main/java 2>/dev/null \
                | grep -vE "^[^:]+:[0-9]+:\s*\*" \
                | grep -vE "^[^:]+:[0-9]+:\s*//" \
                | grep -vE "^[^:]+:[0-9]+:\s*/\*" \
                | wc -l)
        [ "$count" -eq 0 ]
    '

# H2: Zero BaseStream.parallel() invocations in production source code.
# Pattern: ".parallel()" not preceded by "Predefined." (false positive guard).
run H2 "Hardening — zero stream.parallel() invocations in src/main/java (excluding Javadoc/comments)" \
    bash -c '
        count=$(grep -rn "\.parallel\s*(\s*)" src/main/java 2>/dev/null \
                | grep -vE "^[^:]+:[0-9]+:\s*\*" \
                | grep -vE "^[^:]+:[0-9]+:\s*//" \
                | grep -vE "^[^:]+:[0-9]+:\s*/\*" \
                | wc -l)
        [ "$count" -eq 0 ]
    '

# H3: ArchUnit dep is on the test classpath (sanity — should always pass).
run H3 "Hardening — archunit-junit5 is on the test classpath (sanity)" \
    file_contains 'archunit-junit5' pom.xml

echo

# === Regression sanity =======================================================

# R1: Existing CustomerorderBatchServiceUnitTest still passes after Fix C/D.
if [ "${SKIP_MVN:-0}" = "0" ]; then
    run R1 "Regression — CustomerorderBatchServiceUnitTest still passes after Fix C/D" \
        mvn_test_passes CustomerorderBatchServiceUnitTest
else
    skip R1 "Regression — CustomerorderBatchServiceUnitTest run" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
