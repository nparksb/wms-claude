#!/usr/bin/env bash
# verify-260614-outbox-stuck-aggregate-metric.sh
# Machine-checkable acceptance for plan 260614-outbox-stuck-aggregate-metric.md
# (SBDEV-2381 Prereq #8 — wire the stuck-aggregate gauge).
#
#   $ PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#       bash sbdocs/9-System/scripts/verify-260614-outbox-stuck-aggregate-metric.sh
#
# Exit 0 iff every check passes. Baseline (pre-implementation) is expected to FAIL.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
file_contains() { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
mvn_test_passes() {
    # Require >=1 test actually ran with 0 failures/errors. Do NOT accept bare "BUILD SUCCESS":
    # with -DfailIfNoTests=false a MISSING test class also builds green → would false-pass (the
    # exact over-claim the critic flagged). The "Tests run: [1-9]..." floor closes that gap.
    mvn test -Dtest="$1" -DfailIfNoTests=false 2>&1 \
        | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0"
}

CONST=src/main/java/net/aim_ai/wms/service/WmsConstants.java
REPO=src/main/java/net/aim_ai/wms/repo/jpa/OutboxMessageRepository.java
PROJ=src/main/java/net/aim_ai/wms/repo/projection/OutboxStuckAggregateView.java
SVC=src/main/java/net/aim_ai/wms/service/job/OutboxDispatchService.java
JOB=src/main/java/net/aim_ai/wms/schedulejob/OutboxDispatcherJob.java

# --- C1: sysprop gate constant (site 1) ---
check_C1() { file_contains 'SYSTEM_PROPERTY_OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED_KEY\s*=\s*"OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED"' "$CONST"; }

# --- C2: projection interface exists with both accessors (site 3) ---
check_C2_file() { [ -f "$PROJ" ]; }
check_C2_count() { file_contains 'long\s+getHeldAggregates\(\)' "$PROJ"; }
check_C2_age()   { file_contains 'long\s+getOldestAgeSeconds\(\)' "$PROJ"; }

# --- C3: detection query (site 2) — FAILED_TERMINAL blocker + lower-id EXISTS gate ---
check_C3_method()  { file_contains 'findStuckAggregateStats\(\)' "$REPO"; }
check_C3_terminal(){ file_contains "blk.status\s*=\s*'FAILED_TERMINAL'" "$REPO"; }
check_C3_lowerid() { file_contains 'blk\.id\s*<\s*held\.id' "$REPO"; }
check_C3_held()    { file_contains "held.status IN \('PENDING',\s*'FAILED_RETRY',\s*'IN_FLIGHT'\)" "$REPO"; }
check_C3_floor()   { file_contains 'GREATEST\(0,' "$REPO"; }

# --- C4: gated sampling method on the dispatch service (site 4) ---
check_C4_method() { file_contains 'sampleStuckAggregates\(\)' "$SVC"; }
check_C4_gate()   { file_contains 'SYSTEM_PROPERTY_OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED_KEY' "$SVC"; }

# --- C5: MultiGauge registration in the job (site 5) ---
check_C5_import()  { file_contains 'MultiGauge' "$JOB"; }
check_C5_count()   { file_contains 'MultiGauge\.builder\("wms2.outbox.stuck_aggregate"\)' "$JOB"; }
check_C5_age()     { file_contains 'MultiGauge\.builder\("wms2.outbox.stuck_aggregate.oldest_age_seconds"\)' "$JOB"; }
check_C5_sample()  { file_contains 'sampleStuckAggregates\(\)' "$JOB"; }
# tags must be CONSTRUCTED (not the bare word "tenant", which already appears in a log line at OutboxDispatcherJob:70)
check_C5_tags()    { file_contains 'Tags\.of\("tenant"' "$JOB" && file_contains '"facility"' "$JOB"; }
# clear-on-lock-busy: an empty-rows register must exist (the actual clear); behavior proven by C6-job
check_C5_clear()   { file_contains 'register\(List\.of\(\),\s*true\)' "$JOB"; }

# --- C6: targeted tests pass (BEHAVIOR, not just shape — these are the load-bearing proofs) ---
check_C6_svc()  { mvn_test_passes OutboxDispatchServiceUnitTest; }   # NEW class (gate ON/OFF)
check_C6_job()  { mvn_test_passes OutboxDispatcherJobUnitTest; }     # EXISTING class — 2 old tests + new gauge/clear/mixed/exception tests
check_C6_it()   { mvn_test_passes OutboxStuckAggregateIntegrationTest; }   # Testcontainers — query correctness + cost

echo
echo "verify-260614-outbox-stuck-aggregate-metric — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run C1         "C1 — sysprop gate constant added"                check_C1
run C2-file    "C2 — projection interface file exists"           check_C2_file
run C2-count   "C2 — projection getHeldAggregates()"             check_C2_count
run C2-age     "C2 — projection getOldestAgeSeconds()"           check_C2_age
run C3-method  "C3 — repo findStuckAggregateStats() added"       check_C3_method
run C3-term    "C3 — query keys on FAILED_TERMINAL blocker"      check_C3_terminal
run C3-lowid   "C3 — query gates on lower-id sibling"            check_C3_lowerid
run C3-held    "C3 — held set is PENDING/FAILED_RETRY/IN_FLIGHT" check_C3_held
run C3-floor   "C3 — age floored with GREATEST(0,...)"           check_C3_floor
run C4-method  "C4 — sampleStuckAggregates() on dispatch svc"    check_C4_method
run C4-gate    "C4 — sampling is sysprop-gated"                  check_C4_gate
run C5-import  "C5 — job uses MultiGauge"                        check_C5_import
run C5-count   "C5 — registers wms2.outbox.stuck_aggregate"     check_C5_count
run C5-age     "C5 — registers ...oldest_age_seconds"           check_C5_age
run C5-sample  "C5 — job calls sampleStuckAggregates()"          check_C5_sample
run C5-tags    "C5 — rows tagged via Tags.of(tenant,facility)"   check_C5_tags
run C5-clear   "C5 — empty-rows register on lock-busy (clear)"   check_C5_clear

# Behavioral proofs — REQUIRED for sign-off (shape greps above are necessary but not sufficient).
run C6-svc     "C6 — OutboxDispatchServiceUnitTest passes"       check_C6_svc
run C6-job     "C6 — OutboxDispatcherJobUnitTest passes"         check_C6_job
run C6-it      "C6 — OutboxStuckAggregateIT passes"              check_C6_it

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
