#!/usr/bin/env bash
# verify-260709-duplicate-replenishment-orders-concurrent-generation.sh
#
# Acceptance for plan:
#   sbdocs/1-Projects/wms1/plan/260709-duplicate-replenishment-orders-concurrent-generation.md
#
# Stop duplicate replenishment orders caused by concurrent generation, using
# TRANSACTION-SCOPED advisory locks only (auto-release; no session-lock leak class):
#   Fix A — serialize doCalculation via @Transactional doCalculationGuarded() + self,
#           first stmt pg_try_advisory_xact_lock(RUN) (skip if busy).
#   Fix B — @Transactional calculateOrder takes BLOCKING pg_advisory_xact_lock(DEMAND)
#           then re-checks existsOpenForItemAndDestination before insert.
#           MUST NOT touch createOrderFromTemplate (the legit multi-UL split).
#   Fix C — data remediation via the app cancel path (no raw SQL) — not code-checked here.
#
# A session-lock implementation (pg_advisory_unlock / finally-unlock) MUST FAIL this gate.
# DRAFT/REVIEWED plan: expected to FAIL until implemented. Once green, acceptance holds.
#
# Run:  bash sbdocs/9-System/scripts/verify-260709-duplicate-replenishment-orders-concurrent-generation.sh
# Exit 0 iff all checks pass. Override PROJECT_ROOT for a non-default checkout.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v1/wms-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0
run()  { local id=$1 desc=$2; shift 2; if "$@" >/dev/null 2>&1; then printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1)); else printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-8s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }
file_contains()  { grep -qE "$1" "$2" 2>/dev/null; }
file_lacks()     { ! grep -qE "$1" "$2" 2>/dev/null; }
mvn_test_passes(){ mvn -o test -Dtest="$1" -DfailIfNoTests=false -Dmaven.javadoc.skip=true >/dev/null 2>&1; }

LOCKREPO=src/main/java/net/aim_ai/wms/repo/jpa/AdvisoryLockRepository.java
CONST=src/main/java/net/aim_ai/wms/service/WmsConstants.java
JOB=src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java
GEN=src/main/java/net/aim_ai/wms/service/ReplenishGeneratorService.java
ROREPO=src/main/java/net/aim_ai/wms/repo/jpa/ReplenishorderRepository.java
CONCIT=$(find src/test -name ReplenishAdvisoryLockConcurrencyIT.java 2>/dev/null | head -1)
TXBOUNDIT=$(find src/test -name ReplenishGenerationTransactionBoundaryIT.java 2>/dev/null | head -1)

echo
echo "verify-260709-duplicate-replenishment-orders-concurrent-generation — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- §8.1  transaction-scoped lock wrappers (both variants), NO session lock ---
run A1a "AdvisoryLockRepository defines pg_try_advisory_xact_lock (Fix A, non-blocking)" \
    file_contains 'pg_try_advisory_xact_lock' "$LOCKREPO"
run A1b "AdvisoryLockRepository defines blocking pg_advisory_xact_lock (Fix B)" \
    file_contains 'pg_advisory_xact_lock\(' "$LOCKREPO"
run A1c "NO session-scoped advisory lock/unlock anywhere (leak-free by design)" \
    bash -c "! grep -rqE 'pg_advisory_unlock|pg_try_advisory_lock\\(|[^_]pg_advisory_lock\\(' src/main/java"

# --- §8.2  classifiers ---------------------------------------------------------
run A2a "WmsConstants defines ADVISORY_CLASS_REPLENISH_RUN" \
    file_contains 'ADVISORY_CLASS_REPLENISH_RUN' "$CONST"
run A2b "WmsConstants defines ADVISORY_CLASS_REPLENISH_DEMAND" \
    file_contains 'ADVISORY_CLASS_REPLENISH_DEMAND' "$CONST"

# --- §8.3  Fix A: transactional guarded run via self, acquires run lock --------
run A3a "doCalculationGuarded declaration is annotated @Transactional" \
    bash -c "grep -Pzoq '@Transactional[^\\n]*\\n\\s*public void doCalculationGuarded' '$JOB'"
run A3b "doCalculationGuarded acquires the run lock (tryXactLock)" \
    file_contains 'tryXactLock' "$JOB"
run A3c "doCalculation delegates through the self proxy" \
    file_contains 'self\.doCalculationGuarded' "$JOB"

# --- §8.4  Fix B: lock-bearing calculateOrder is REQUIRES_NEW + BLOCKING lock ---
# REQUIRES_NEW (not REQUIRED) so a swallowed no-stock FacadeException cannot roll back
# a job caller's REQUIRES_NEW tx (C-R2).
run B4a "ReplenishGeneratorService uses @Transactional with REQUIRES_NEW propagation" \
    bash -c "grep -Pzoq '@Transactional\\([^)]*Propagation\\.REQUIRES_NEW' '$GEN'"
run B4b "calculateOrder takes the BLOCKING demand lock (xactLock, non-try)" \
    bash -c "grep -qE '[^y]xactLock\\(|\\.xactLock\\(' '$GEN'"

# --- §8.5  Fix B: proxy-entry guarantee (self field + self-routed calls) --------
run B5a "ReplenishGeneratorService has a self-injected field" \
    bash -c "grep -qE 'ReplenishGeneratorService\\s+self' '$GEN'"
run B5b "same-bean calculateOrder calls routed via self.calculateOrder(" \
    file_contains 'self\.calculateOrder\(' "$GEN"

# --- §8.6  Fix B: idempotency finder consulted before create -------------------
run B6a "ReplenishorderRepository has existsOpenForItemAndDestination" \
    file_contains 'existsOpenForItemAndDestination' "$ROREPO"
run B6b "calculateOrder consults the existence check" \
    file_contains 'existsOpenForItemAndDestination' "$GEN"

# --- §8.7  multi-UL split preserved: createOrderFromTemplate NOT guarded -------
run B7 "createOrderFromTemplate does NOT consult the existence check" \
    bash -c "awk '/createOrderFromTemplate\\(/{f=1} f&&/existsOpenForItemAndDestination/{bad=1} /^    }/{if(f&&seen)exit; if(f)seen=1} END{exit bad?1:0}' '$GEN'"

# --- §8.9  concurrency proof test present --------------------------------------
run C9 "ReplenishAdvisoryLockConcurrencyIT present" \
    bash -c "[ -n \"$CONCIT\" ] && [ -f \"$CONCIT\" ]"
# --- C-R2 rollback-isolation guard present (symmetric with C9) -----------------
run C10 "ReplenishGenerationTransactionBoundaryIT present (REQUIRES_NEW rollback isolation)" \
    bash -c "[ -n \"$TXBOUNDIT\" ] && [ -f \"$TXBOUNDIT\" ]"

# --- §8.7  behavioral gate — unit tests ----------------------------------------
if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T1 "ReplenishOrderJobUnitTest passes (skip-when-locked)" \
        mvn_test_passes ReplenishOrderJobUnitTest
    run T2 "ReplenishGeneratorServiceUnitTest passes (skip-when-open / null-dest / multi-UL split)" \
        mvn_test_passes ReplenishGeneratorServiceUnitTest
else
    skip T1 "ReplenishOrderJobUnitTest" "SKIP_MVN=1 set"
    skip T2 "ReplenishGeneratorServiceUnitTest" "SKIP_MVN=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
