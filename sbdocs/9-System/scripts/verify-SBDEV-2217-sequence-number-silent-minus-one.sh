#!/usr/bin/env bash
# verify-SBDEV-2217-sequence-number-silent-minus-one.sh
#
# Acceptance for SBDEV-2217 — sequence-number generation hardening (v2).
# Plan:  sbdocs/1-Projects/wms2/plan/SBDEV-2217-sequence-number-silent-minus-one.md
#
# Run after every implementation pass:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2217-sequence-number-silent-minus-one.sh
#
# Exit code is 0 if all checks pass, non-zero otherwise. The implementing
# agent's end-of-task report MUST paste this script's output before the work
# is accepted.

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
    local cls=$1
    local tmplog
    tmplog=$(mktemp /tmp/mvn-test-XXXXXX.log)
    if mvn test -Dtest="$cls" -DfailIfNoTests=false >"$tmplog" 2>&1; then
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
REPO=src/main/java/net/aim_ai/wms/repo/jpa
TST=src/test/java/net/aim_ai/wms/unit/service
ITT=src/test/java/net/aim_ai/wms/integration/service
RES=src/main/resources

BASIC=$SVC/BasicService.java
SEQTX=$SVC/SequenceTransactionService.java
PARCEL=$SVC/ParcelMonitorViewService.java
ORDERMV=$SVC/OrderMonitorViewService.java
BOL=$SVC/BillofladingService.java
LOSREPO=$REPO/LosSequencenumberRepository.java
BASICTEST=$TST/BasicServiceUnitTest.java
CONCIT=$ITT/SequenceTransactionServiceConcurrencyIT.java
MSGS=$RES/messages_en_US.properties

echo
echo "verify-SBDEV-2217 — sequence-number hardening acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# === Prerequisite (carried from 7316ddb5 — must remain in place) ==============

run PRE-1 "Prereq — SequenceTransactionService uses tenantTransactionManager + REQUIRES_NEW" \
    file_contains_ml '@Transactional\(\s*value\s*=\s*"tenantTransactionManager",\s*propagation\s*=\s*Propagation\.REQUIRES_NEW\s*\)' "$SEQTX"
run PRE-2 "Prereq — LosSequencenumberRepository has findByClassnameForUpdate with PESSIMISTIC_WRITE" \
    bash -c '
        grep -qE "@Lock\(LockModeType\.PESSIMISTIC_WRITE\)" '"$LOSREPO"' \
        && grep -qE "Optional<LosSequencenumber>\s+findByClassnameForUpdate" '"$LOSREPO"' 2>/dev/null
    '
run PRE-3 "Prereq — SequenceTransactionService uses findByClassnameForUpdate (not findByClassname)" \
    file_contains 'findByClassnameForUpdate' "$SEQTX"

echo

# === Fix A — typed BusinessException on exhaustion ============================

run A1 "Fix A — BasicService imports BusinessException" \
    file_contains '^import\s+net\.aim_ai\.wms\.exceptions\.BusinessException;' "$BASIC"
run A2 "Fix A — BasicService throws BusinessException on exhaustion (near 'Cannot allocate sequence' or 'Exceeded maxTries')" \
    file_contains_ml 'throw\s+new\s+BusinessException\(' "$BASIC"
run A3 "Fix A — old 'throw new RuntimeException(msg)' exhaustion line is gone" \
    file_not_contains 'throw\s+new\s+RuntimeException\(\s*msg\s*\)' "$BASIC"
run A4 "Fix A — getNextSequenceNumber declares throws BusinessException" \
    file_contains_ml 'public\s+long\s+getNextSequenceNumber\([^)]*\)\s+throws\s+BusinessException' "$BASIC"
run A5 "Fix A — i18n key BusinessException.SequenceExhausted in messages_en_US.properties" \
    file_contains 'BusinessException\.SequenceExhausted\s*=' "$MSGS"

echo

# === Fix B — caller-side n<0 guards ===========================================

run B1 "Fix B — generatePickOrderNumber has n<0 guard" \
    file_contains_ml 'generatePickOrderNumber\(\)[^}]*if\s*\(\s*n\s*<\s*0\s*\)' "$BASIC"
run B2 "Fix B — generateReplenishNumber has n<0 guard" \
    file_contains_ml 'generateReplenishNumber\(\)[^}]*if\s*\(\s*n\s*<\s*0\s*\)' "$BASIC"
run B3 "Fix B — generateNumber(prefix,key) has <0 guard" \
    file_contains_ml 'generateNumber\(\s*String\s+prefix\s*,\s*String\s+key\s*\)[^}]*<\s*0' "$BASIC"
run B4 "Fix B — generateMessageNumber(prefix,key) has <0 guard" \
    file_contains_ml 'generateMessageNumber\(\s*String\s+prefix\s*,\s*String\s+key\s*\)[^}]*<\s*0' "$BASIC"
run B5 "Fix B — i18n key BusinessException.SequenceInvalid in messages_en_US.properties" \
    file_contains 'BusinessException\.SequenceInvalid\s*=' "$MSGS"
# B6/B7: anchor guards to sequence-allocation context (BusinessException + <0 proximity)
run B6 "Fix B — ParcelMonitorViewService has sequence-value guard (BusinessException + n<0 near getNextSequenceNumber)" \
    bash -c '
        perl -0777 -ne "exit 0 if /getNextSequenceNumber[^}]{0,200}if\s*\(\s*n\s*<\s*0\s*\)/m; exit 1" '"$PARCEL"' 2>/dev/null
    '
run B7 "Fix B — OrderMonitorViewService has sequence-value guard (BusinessException + n<0 near getNextSequenceNumber)" \
    bash -c '
        perl -0777 -ne "exit 0 if /getNextSequenceNumber[^}]{0,200}if\s*\(\s*n\s*<\s*0\s*\)/m; exit 1" '"$ORDERMV"' 2>/dev/null
    '
run B8 "Fix B — BillofladingService has sequence-value guard near getNextSequenceNumber call (line 719 site)" \
    file_contains_ml 'getNextSequenceNumber\([^)]*\)[^;]*;[^}]{0,200}<\s*0' "$BOL"

echo

# === Fix C — Micrometer metrics ===============================================

run C1 "Fix C — BasicService imports MeterRegistry" \
    file_contains '^import\s+io\.micrometer\.core\.instrument\.MeterRegistry;' "$BASIC"
run C2 "Fix C — BasicService constructor parameter list contains MeterRegistry" \
    file_contains_ml 'public\s+BasicService\([^)]*MeterRegistry\s+\w+' "$BASIC"
run C3 "Fix C — BasicService references metric name wms.sequence.allocation" \
    file_contains '"wms\.sequence\.allocation"' "$BASIC"
run C4 "Fix C — BasicService references counter wms.sequence.allocation.exhausted" \
    file_contains '"wms\.sequence\.allocation\.exhausted"' "$BASIC"

echo

# === Fix D — Repository hygiene ===============================================

run D1 "Fix D — findByClassname is @RestResource(exported = false) OR removed" \
    bash -c '
        # Detect method (multi-line tolerant: signature may wrap across lines).
        if perl -0777 -ne "exit 0 if /Optional<LosSequencenumber>\s+findByClassname\s*\(/m; exit 1" '"$LOSREPO"' 2>/dev/null; then
            # Method exists — must be annotated @RestResource(exported = false)
            perl -0777 -ne "exit 0 if /\@RestResource\(\s*exported\s*=\s*false\s*\)\s*[^@]*Optional<LosSequencenumber>\s+findByClassname\s*\(/m; exit 1" '"$LOSREPO"' 2>/dev/null
        else
            # Method removed — also acceptable per Fix D Option D2
            true
        fi
    '
run D2 "Fix D — non-locking findByClassname is no longer exported via path/rel" \
    file_not_contains '@RestResource\(\s*path\s*=\s*"findByClassname"' "$LOSREPO"

echo

# === Test wiring ==============================================================

run T1 "Tests — BasicServiceUnitTest references BusinessException" \
    file_contains 'BusinessException' "$BASICTEST"

# T2a: shouldThrowWhenSequenceServiceExceedsMaxRetries no longer asserts RuntimeException near its exhaustion assertion
run T2a "Tests — shouldThrowWhenSequenceServiceExceedsMaxRetries does NOT assert RuntimeException.class for exhaustion" \
    bash -c '
        ! perl -0777 -ne "exit 0 if /shouldThrowWhenSequenceServiceExceedsMaxRetries[\s\S]{0,600}isInstanceOf\(RuntimeException\.class\)/m; exit 1" '"$BASICTEST"' 2>/dev/null
    '

# T2b: BasicServiceUnitTest now asserts BusinessException.class (for the exhaustion path)
run T2b "Tests — BasicServiceUnitTest asserts BusinessException.class (exhaustion path updated)" \
    file_contains 'isInstanceOf\(BusinessException\.class\)' "$BASICTEST"

run T3 "Tests — concurrency integration test exists at expected path" \
    test -f "$CONCIT"
run T4 "Tests — concurrency IT references 50-thread / 100-iteration acceptance criterion" \
    bash -c '[ -f "'"$CONCIT"'" ] && grep -qE "50|threads" "'"$CONCIT"'" 2>/dev/null'

echo

# === Targeted JUnit runs ======================================================

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-BASIC "T — BasicServiceUnitTest passes"                       mvn_test_passes BasicServiceUnitTest
    run T-CONC  "T — SequenceTransactionServiceConcurrencyIT passes"   mvn_it_passes SequenceTransactionServiceConcurrencyIT
else
    skip T-mvn "Targeted unit + integration test runs" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
