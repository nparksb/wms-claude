#!/usr/bin/env bash
# Acceptance script for the v2 port of "Duplicate Replenishment Orders"
# Plan: sbdocs/1-Projects/wms2/plan/260709-duplicate-replenishment-orders-concurrent-generation.md
# Scope: index-backed correctness + graceful DataIntegrityViolationException handling + NEW-1 proxy fix.
# NO advisory lock is ported (intentional v1<->v2 divergence — see plan §8).
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-260709-duplicate-replenishment-orders-concurrent-generation-v2.sh
#   RUN_TESTS=1 bash .../verify-...-v2.sh      # also run the targeted unit tests
set -uo pipefail

ROOT="${WMS2_API_ROOT:-v2/wms2-api}"
GEN="$ROOT/src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java"
SVC="$ROOT/src/main/java/net/aim_ai/wms/service/ReplenishorderService.java"
REPO="$ROOT/src/main/java/net/aim_ai/wms/repo/jpa/ReplenishorderRepository.java"
GEN_TEST="$ROOT/src/test/java/net/aim_ai/wms/unit/service/ReplenishGeneratorServiceUnitTest.java"
SVC_TEST="$ROOT/src/test/java/net/aim_ai/wms/unit/service/ReplenishorderServiceUnitTest.java"
SLICE="$ROOT/src/test/java/net/aim_ai/wms/integration/ReplenishDupConcurrencySliceIT.java"

# strip comment/JavaDoc lines so greps don't match prose (e.g. {@link #calculateOrder} or "getMostSpecificCause would…")
code() { grep -vE '^\s*(\*|//|/\*)' "$1" | grep -v '@link'; }

pass=0; fail=0
run() { # <id> <description> <fn>
  local id="$1" desc="$2" fn="$3"
  if "$fn"; then echo "PASS [$id] $desc"; pass=$((pass+1));
  else echo "FAIL [$id] $desc"; fail=$((fail+1)); fi
}

# 1 — NEW-1: self-injection present + same-bean calls routed via self (method-anchored, not line-anchored)
check_new1_self() {
  grep -Eq '@Lazy' "$GEN" && grep -Eq 'private +ReplenishGeneratorService +self' "$GEN" || return 1
  # both refill same-bean calls + the 3-arg->4-arg hop route through self
  [ "$(code "$GEN" | grep -c 'self\.calculateOrder(') " -ge 3 ] || return 1
  # negative: no bare same-bean calculateOrder( CALL left (exclude method DECLARATIONS + self. calls), comments stripped
  local bare
  bare=$(code "$GEN" | grep -nE '(^|[^.])\bcalculateOrder\(' | grep -v 'self\.calculateOrder(' \
         | grep -vE '\b(public|private|protected|Replenishorder)\b.*calculateOrder\(' || true)
  [ -z "$bare" ]
}

# 2 — 3-arg catches DIVE|UnexpectedRollbackException and discriminates before returning null
check_graceful_3arg() {
  grep -Eq 'catch *\( *DataIntegrityViolationException *\| *UnexpectedRollbackException' "$GEN" \
    && grep -q 'isActiveDupViolation(' "$GEN"
}

# 3 — discriminator: constraint-name match PRIMARY (idx_replenishorder_active_item) + re-check fallback
check_discriminator() {
  grep -q 'ConstraintViolationException' "$GEN" \
    && grep -q 'getConstraintName()' "$GEN" \
    && grep -q 'idx_replenishorder_active_item' "$GEN" \
    && grep -q 'openOrderExistsFor(' "$GEN"
}

# 3b — must walk the cause chain (getCause + instanceof ConstraintViolationException), NOT call getMostSpecificCause
check_no_mostspecific() {
  code "$GEN" | grep -q 'getCause()' \
    && code "$GEN" | grep -q 'instanceof ConstraintViolationException' \
    && ! code "$GEN" | grep -q 'getMostSpecificCause('
}

# 4 — deterministic surfacing: a flush() follows the insert (save()+flush() is equivalent to saveAndFlush)
check_flush() { grep -Eq 'replenishorderRepository\.(saveAndFlush|flush)\(' "$GEN"; }

# 5 — desktop create has the same guarded catch
check_graceful_create() {
  grep -Eq 'catch *\( *DataIntegrityViolationException *\| *UnexpectedRollbackException' "$SVC" \
    && grep -q 'isActiveDupViolation(' "$SVC"
}

# 6 — existing pre-check retained (first-line optimization, null-return contract)
check_precheck_retained() {
  grep -q 'findByStateLessThanAndItemdataId(' "$GEN" && grep -q 'return null;' "$GEN"
}

# 7 — createOrderFromTemplate (multi-UL split) NOT guarded by the discriminator
check_split_unguarded() {
  awk '/Replenishorder +createOrderFromTemplate\(/{f=1} f{print} /^    }$/{if(f)exit}' "$GEN" \
    | grep -Eq 'isActiveDupViolation|openOrderExistsFor' && return 1
  return 0
}

# 8 — DIVERGENCE GUARD (negative): no advisory-lock machinery introduced by this port
check_no_advisory_lock() {
  ! grep -rq 'AdvisoryLockRepository' "$ROOT/src/main/java" \
    && ! grep -rq 'pg_advisory_xact_lock' "$ROOT/src/main" \
    && ! grep -Eq 'REPLENISH.*=.*1000[0-9][0-9]L' "$ROOT/src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java" 2>/dev/null || true
  # the AdvisoryLockService line for REPLENISH_ORDER=100002L pre-exists; assert NO *new* demand-lock id:
  ! grep -rq 'AdvisoryLockRepository\|pg_advisory_xact_lock\|ADVISORY_CLASS_REPLENISH' "$ROOT/src/main"
}

# 9 — tests present: 3 target behaviors + guards + the @Disabled slice
check_tests_present() {
  grep -q 'calculateOrder_returnsNull_onActiveDupViolation_whenOpenOrderExists' "$GEN_TEST" \
    && grep -q 'calculateOrder_routesThroughSelf_soRequiresNewEngages' "$GEN_TEST" \
    && grep -q 'calculateOrder_rethrows_whenNumberConstraintViolation' "$GEN_TEST" \
    && grep -q 'create_returnsNull_onActiveDupViolation' "$SVC_TEST" \
    && grep -q '@Disabled' "$SLICE"
}

run 1  "NEW-1: @Lazy self-injection + 3 same-bean calls routed via self; no bare same-bean calculateOrder" check_new1_self
run 2  "3-arg calculateOrder catches DIVE|UnexpectedRollbackException + discriminates"                   check_graceful_3arg
run 3  "discriminator: constraint-name idx_replenishorder_active_item (primary) + openOrderExistsFor"    check_discriminator
run 3b "discriminator walks cause chain (no getMostSpecificCause)"                                       check_no_mostspecific
run 4  "deterministic surfacing: flush() after insert"                                                   check_flush
run 5  "desktop create has the same guarded catch"                                                       check_graceful_create
run 6  "existing (item,dest) pre-check retained"                                                         check_precheck_retained
run 7  "createOrderFromTemplate (multi-UL split) NOT guarded"                                            check_split_unguarded
run 8  "DIVERGENCE GUARD: no advisory-lock repo / pg_advisory_xact_lock / new demand-lock id"            check_no_advisory_lock
run 9  "TDD tests present (3 target + number-constraint guard + @Disabled slice)"                        check_tests_present

if [ "${RUN_TESTS:-0}" = "1" ]; then
  echo "--- running targeted unit tests ---"
  ( cd "$ROOT" && source "$HOME/.sdkman/bin/sdkman-init.sh" 2>/dev/null; \
    mvn -o test -Dtest=ReplenishGeneratorServiceUnitTest,ReplenishorderServiceUnitTest 2>&1 \
    | grep -E "Tests run:|BUILD" | tail -3 )
fi

echo "-----------------------------------------"
echo "verify-260709-dup-replen-v2: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
