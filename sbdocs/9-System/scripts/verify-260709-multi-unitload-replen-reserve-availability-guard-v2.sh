#!/usr/bin/env bash
# verify-260709-multi-unitload-replen-reserve-availability-guard-v2.sh
#
# Acceptance for plan:
#   sbdocs/1-Projects/wms2/plan/260709-multi-unitload-replen-reserve-availability-guard.md
#
# v2 PORT of v1 multi-unit-load replenishment availability guard (commit 1ff0d85).
# validateUnitLoadEntry must reject a UL whose AVAILABILITY (amount - reservedamount) is below
# the requested qty — up front, with the clear new key MsgUnitLoadStockAlreadyReserved — instead
# of passing a fully-reserved UL to the additive reserve path (which throws
# CANNOT_RESERVE_MORE_THAN_AVAILABLE "(0.0000)"). A self-source add-back credits the template's own
# recoverable share (requestedamount capped at reserved) under a reserved>0 guard, null-safe.
#
# Baseline expectation: the code checks (G1a/G-null/G2*/G3a) FAIL before implementation (guard absent);
# G1neg passes trivially at baseline (the gross check is still present) and FLIPS to the real assertion
# once the gross check is replaced; the mvn behavioral gate FAILS until AC-1..AC-8 are implemented.
#
# Run:  bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard-v2.sh
# Exit 0 iff all checks pass. Override PROJECT_ROOT for a non-default checkout.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run()  { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-8s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }
# set +u around the sdkman source: sdkman-init.sh references unbound vars that would trip set -u.
mvn_test_passes() { set +u; source "$HOME/.sdkman/bin/sdkman-init.sh" >/dev/null 2>&1; local rc; mvn -o test -Dtest="$1" -DfailIfNoTests=false -Dmaven.javadoc.skip=true >/dev/null 2>&1; rc=$?; set -u; return $rc; }

MRS=src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java
PROPS=src/main/resources/messages_en_US.properties
TEST=src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java

# Extract the validateUnitLoadEntry method body (signature → next 'private '/'public ' or EOF) into a temp
# so the code checks below are METHOD-SCOPED — the gross getAmount().compareTo pattern legitimately appears
# elsewhere (e.g. checkSource, another gate, applyExplicitSourceToOrder).
METHOD_BODY="$(awk '/private +MultiUnitLoadInstruction +validateUnitLoadEntry/{f=1}
                    f{print}
                    f && /^    }/{exit}' "$MRS" 2>/dev/null)"
mb_contains()      { printf '%s' "$METHOD_BODY" | grep -qE "$1"; }
mb_not_contains()  { ! printf '%s' "$METHOD_BODY" | grep -qE "$1"; }
file_contains()    { grep -qE "$1" "$2" 2>/dev/null; }

echo
echo "verify-260709-multi-unitload-replen-reserve-availability-guard-v2 — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- G1a: null-safe availability read (not getAvailableamount()) -------------
run G1a  "validateUnitLoadEntry computes availability via getAmount().subtract(...) (not getAvailableamount())" \
    mb_contains 'getAmount\(\)\.subtract\('
# --- G-null: reservedamount NULL-guard present -------------------------------
run Gnull "validateUnitLoadEntry null-guards reservedamount (getReservedamount() == null / reservedOrZero)" \
    mb_contains 'getReservedamount\(\)\s*==\s*null|reservedOrZero'
# --- G1neg: the OLD gross check is GONE from validateUnitLoadEntry ------------
run G1neg "gross gate getAmount().compareTo(dto.getQty()) is GONE from validateUnitLoadEntry" \
    mb_not_contains 'getAmount\(\)\.compareTo\(\s*dto\.getQty\(\)\s*\)'

# --- G2a: self-source key compares stockunitId to matching.getId() -----------
run G2a  "self-source add-back keys on template.getStockunitId().equals(matching.getId())" \
    mb_contains 'getStockunitId\(\)[^;]*\.equals\('
# --- G2b: credit capped at reserved via min() --------------------------------
run G2b  "self-source credit caps at reserved: getRequestedamount()...min(...)" \
    mb_contains 'getRequestedamount\(\)[^;]*\.min\(|min\([^;]*getRequestedamount'
# --- G2c: the reserved>0 guard gates the add-back ----------------------------
run G2c  "add-back gated by reserved > 0 (compareTo(BigDecimal.ZERO) > 0)" \
    mb_contains 'compareTo\(\s*BigDecimal\.ZERO\s*\)\s*>\s*0'

# --- G3a/G3b: new message key present in throw + properties ------------------
run G3a  "MobileReplenishService throws MsgUnitLoadStockAlreadyReserved" \
    file_contains 'MsgUnitLoadStockAlreadyReserved' "$MRS"
run G3b  "messages_en_US.properties defines MsgUnitLoadStockAlreadyReserved" \
    file_contains '^MsgUnitLoadStockAlreadyReserved=' "$PROPS"

# --- G-assert: throwing ACs key on the new MESSAGE, not just the exception ---
run Gassert "MobileReplenishServiceUnitTest asserts hasMessageContaining(MsgUnitLoadStockAlreadyReserved)" \
    file_contains 'hasMessageContaining\(\s*"MsgUnitLoadStockAlreadyReserved"' "$TEST"

# --- behavioral gate — unit tests (incl. AC-4/AC-6/AC-7/AC-8) ----------------
if command -v mvn >/dev/null 2>&1 || [ -f "$HOME/.sdkman/candidates/maven/current/bin/mvn" ]; then
    run G4 "mvn test MobileReplenishServiceUnitTest passes (incl. AC-1..AC-8)" \
        mvn_test_passes MobileReplenishServiceUnitTest
else
    skip G4 "mvn behavioral gate" "mvn not on PATH (source sdkman-init.sh)"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ] || exit 1
