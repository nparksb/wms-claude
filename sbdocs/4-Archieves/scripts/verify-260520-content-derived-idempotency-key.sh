#!/usr/bin/env bash
# verify-260520-content-derived-idempotency-key.sh
#
# Acceptance script for: Content-derived idempotency key — remove Idempotency-Key header requirement
# Plan: sbdocs/1-Projects/wms2/plan/260520-content-derived-idempotency-key.md
# Base: SBDEV-2222 PR #11 (SHA 0373141)
#
# Run after every implementation pass from the v2/wms2-api project root:
#   $ bash sbdocs/9-System/scripts/verify-260520-content-derived-idempotency-key.sh
#
# Modes:
#   PRE_IMPL_MODE=1  — pre-implementation: positive-existence checks may FAIL,
#                      negative `file_not_contains` checks on existing files that
#                      haven't been modified yet are reported as SKIP.
#   SKIP_MVN=1       — skip JUnit invocations (lint-only loops).
#
# Exit code 0 iff all checks PASS (SKIP is neutral).

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
PRE_IMPL_MODE="${PRE_IMPL_MODE:-0}"
MVN="${MVN:-/home/nampark/.sdkman/candidates/maven/3.9.15/bin/mvn}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-14s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-14s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-14s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

run_neg() {
    local id=$1 desc=$2 pattern=$3 file=$4
    if [ ! -f "$file" ]; then
        if [ "$PRE_IMPL_MODE" = "1" ]; then
            skip "$id" "$desc" "file not yet modified (PRE_IMPL_MODE)"; return
        else
            printf "  FAIL  %-14s  %s  (file missing: %s)\n" "$id" "$desc" "$file"; FAIL=$((FAIL+1)); return
        fi
    fi
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        printf "  PASS  %-14s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-14s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

file_contains()    { test -f "$2" && grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains(){ test -f "$2" && ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_ml() {
    test -f "$2" || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/ms; exit 1' "$2" 2>/dev/null
}

FILTER=src/main/java/net/aim_ai/wms/landlord/config/IdempotencyFilter.java
SERVICE=src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java
CLAUDEMD=CLAUDE.md
OMSMAP=../../sbdocs/3-Resources/architecture/wms2-oms-integration-map.md
FILTER_TEST=src/test/java/net/aim_ai/wms/unit/landlord/IdempotencyFilterUnitTest.java
REPO=src/main/java/net/aim_ai/wms/repo/jpa/RestIdempotencyRepository.java
APPPROPS=src/main/resources/application.properties

echo "=== verify-260520-content-derived-idempotency-key ==="
echo "    PROJECT_ROOT=$PROJECT_ROOT"
echo "    PRE_IMPL_MODE=$PRE_IMPL_MODE  SKIP_MVN=${SKIP_MVN:-0}"
echo

# ---------------------------------------------------------------------------
# A.1 — Fall-through gap removed
# Old code: String key = request.getHeader(IDEMPOTENCY_HEADER);
#           if (key == null || key.isBlank()) { chain.doFilter(...); return; }
# New code: String rawHeader = request.getHeader(IDEMPOTENCY_HEADER);
#           ... compute bodyHash + auto-gen key from sha256HexComposite ...
#
# Most reliable signal: the old bare variable 'key = request.getHeader(...)' is GONE
# (renamed to rawHeader). Also confirm the new variable name IS present.
# ---------------------------------------------------------------------------
echo "--- A — Fall-through gap removed / variable renamed ---"

run_neg A-1 \
    "Old 'String key = request.getHeader(IDEMPOTENCY_HEADER)' assignment gone" \
    'String key = request\.getHeader\(IDEMPOTENCY_HEADER\)' \
    "$FILTER"

run A-1b \
    "New 'rawHeader' variable from getHeader present (dual-path key logic)" \
    file_contains 'rawHeader' "$FILTER"

echo

# ---------------------------------------------------------------------------
# A.2 / A.5 — New sha256HexComposite helper exists
# ---------------------------------------------------------------------------
echo "--- A — sha256HexComposite helper added ---"

run A-2 \
    "IdempotencyFilter has sha256HexComposite method" \
    file_contains 'sha256HexComposite' "$FILTER"

run A-2b \
    "sha256HexComposite uses md.update() for prefix (method+path) + body separately" \
    file_contains_ml 'sha256HexComposite[\s\S]+?md\.update' "$FILTER"

echo

# ---------------------------------------------------------------------------
# A.3 — Body buffered BEFORE header check
# ContentCachingRequestWrapper must appear before the Idempotency-Key header read.
# Grep for line ordering: ContentCachingRequestWrapper line must precede
# request.getHeader(IDEMPOTENCY_HEADER).
# ---------------------------------------------------------------------------
echo "--- A — Body buffered before header decision ---"

run A-3 \
    "ContentCachingRequestWrapper creation present in filter (body always buffered)" \
    file_contains 'new ContentCachingRequestWrapper' "$FILTER"

# Verify ordering: ContentCachingRequestWrapper line-number < getHeader line-number
check_buffering_order() {
    local wrapper_line header_line
    wrapper_line=$(grep -n 'new ContentCachingRequestWrapper' "$FILTER" | head -1 | cut -d: -f1)
    header_line=$(grep -n 'getHeader(IDEMPOTENCY_HEADER)' "$FILTER" | head -1 | cut -d: -f1)
    if [ -z "$wrapper_line" ] || [ -z "$header_line" ]; then return 1; fi
    [ "$wrapper_line" -lt "$header_line" ]
}
run A-3b \
    "ContentCachingRequestWrapper appears BEFORE getHeader(IDEMPOTENCY_HEADER) in source" \
    check_buffering_order

echo

# ---------------------------------------------------------------------------
# A.4 — Auto-gen key used when no header
# The filter must call sha256HexComposite in the no-header branch.
# ---------------------------------------------------------------------------
echo "--- A — Auto-gen key in no-header branch ---"

run A-4 \
    "Filter calls sha256HexComposite for the no-header (else/absent) key path" \
    file_contains_ml '(else|rawHeader.*isBlank|rawHeader.*null)[\s\S]{0,200}sha256HexComposite' "$FILTER"

run A-4b \
    "Filter passes auto-gen key to tryClaim()" \
    file_contains 'tryClaim' "$FILTER"

echo

# ---------------------------------------------------------------------------
# A.6 — KEY_REGEX validation scoped to header-override path only
# The KEY_REGEX.matcher call must appear inside the header-present branch,
# not unconditionally at the top of doFilterInternal.
# ---------------------------------------------------------------------------
echo "--- A — KEY_REGEX scoped to header-override branch ---"

run A-6 \
    "KEY_REGEX.matcher appears inside the explicit-header branch (near rawHeader / IDEMPOTENCY_HEADER)" \
    file_contains_ml '(rawHeader|IDEMPOTENCY_HEADER)[\s\S]{0,400}KEY_REGEX\.matcher' "$FILTER"

echo

# ---------------------------------------------------------------------------
# A.7 — RestIdempotencyService CONFLICT comment
# Note: uses ERE alternation with | (not \|)
# ---------------------------------------------------------------------------
echo "--- A — CONFLICT comment in RestIdempotencyService ---"

run A-7 \
    "RestIdempotencyService.tryClaim has auto-generated-key CONFLICT comment" \
    file_contains 'auto-gen|auto-generated|mathematically' "$SERVICE"

echo

# ---------------------------------------------------------------------------
# A.8 — CLAUDE.md updated
# ---------------------------------------------------------------------------
echo "--- A — CLAUDE.md contract updated ---"

run A-8 \
    "CLAUDE.md mentions auto-generates / auto-derived idempotency key" \
    file_contains 'auto-generates|auto-derived|auto generates' "$CLAUDEMD"

run_neg A-8b \
    "CLAUDE.md no longer says 'OMS must send' Idempotency-Key (mandatory header gone)" \
    'OMS must send.*Idempotency-Key' \
    "$CLAUDEMD"

echo

# ---------------------------------------------------------------------------
# A.9 — wms2-oms-integration-map.md updated
# ---------------------------------------------------------------------------
echo "--- A — wms2-oms-integration-map.md updated ---"

run A-9 \
    "wms2-oms-integration-map.md references updated idempotency contract (optional or auto)" \
    file_contains 'optional|auto-gen|auto-derived|content.derived' "$OMSMAP"

echo

# ---------------------------------------------------------------------------
# A.10 — Tests updated
# ---------------------------------------------------------------------------
echo "--- A — IdempotencyFilterUnitTest updated ---"

run A-10 \
    "IdempotencyFilterUnitTest has auto_generates_key_when_no_header test" \
    file_contains 'auto_generates_key_when_no_header|autoGeneratesKey|auto_generated_key' "$FILTER_TEST"

run A-10b \
    "IdempotencyFilterUnitTest has deduplicates_identical_requests_without_header test" \
    file_contains 'deduplicates_identical_requests_without_header|deduplicatesIdenticalRequests|without_header' "$FILTER_TEST"

run A-10c \
    "IdempotencyFilterUnitTest has header_overrides_auto_generated_key test" \
    file_contains 'header_overrides|headerOverrides|explicit.*header.*override|override.*header' "$FILTER_TEST"

run A-10d \
    "IdempotencyFilterUnitTest has filter_skips_dedup_when_content_length_over test (C2)" \
    file_contains 'skips_dedup_when_content_length|content_length_over|maxBodyBytes|max_body_bytes|over.*5MB|body.*too.*large' "$FILTER_TEST"

echo

# ---------------------------------------------------------------------------
# C2 — Body-size cap
# ---------------------------------------------------------------------------
echo "--- C2 — Body-size cap in IdempotencyFilter ---"

run C2-1 \
    "IdempotencyFilter has maxBodyBytes field / app.idempotency.max-body-bytes @Value" \
    file_contains 'maxBodyBytes|max-body-bytes' "$FILTER"

run C2-2 \
    "IdempotencyFilter has contentLen > maxBodyBytes guard (body-size cap)" \
    file_contains 'contentLen.*maxBodyBytes|maxBodyBytes.*contentLen|getContentLength\(\)' "$FILTER"

run C2-3 \
    "application.properties contains app.idempotency.max-body-bytes" \
    file_contains 'app\.idempotency\.max-body-bytes' "$APPPROPS"

echo

# ---------------------------------------------------------------------------
# C3 — Bridge-mode (transition safety)
# ---------------------------------------------------------------------------
echo "--- C3 — Bridge-mode in RestIdempotencyService + RestIdempotencyRepository ---"

run C3-1 \
    "RestIdempotencyService has bridgeMode field / app.idempotency.bridge-mode @Value" \
    file_contains 'bridgeMode|bridge-mode' "$SERVICE"

run C3-2 \
    "RestIdempotencyService calls findByRequestHashAndMethodAndPath in bridge path" \
    file_contains 'findByRequestHashAndMethodAndPath' "$SERVICE"

run C3-3 \
    "RestIdempotencyRepository has findByRequestHashAndMethodAndPath JPQL method" \
    file_contains 'findByRequestHashAndMethodAndPath' "$REPO"

run C3-4 \
    "application.properties contains app.idempotency.bridge-mode" \
    file_contains 'app\.idempotency\.bridge-mode' "$APPPROPS"

echo

# ---------------------------------------------------------------------------
# Negative checks — regression guards from SBDEV-2222
# The underlying DB-backstop existence checks in each controller must remain.
# ---------------------------------------------------------------------------
echo "--- N — DB backstop existence checks preserved in controllers ---"

ORDER_RC=src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java
ADVICE_RC=src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java
SKU_RC=src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java

run N-1 \
    "OrderRestController still calls findByBatchid (DB unique backstop preserved)" \
    file_contains 'customerorderBatchRepository\.findByBatchid' "$ORDER_RC"

run N-2 \
    "AdviceRestController still calls findByExternalid" \
    file_contains 'adviceRepository\.findByExternalid' "$ADVICE_RC"

run N-3 \
    "SkuRestController still calls findByClientIdAndItemNr" \
    file_contains 'itemdataService\.findByClientIdAndItemNr' "$SKU_RC"

# The filter class must NOT be annotated @Component — it must be a @Bean wired
# via SecurityFilterChain.addFilterAfter (regression guard from SBDEV-2222).
run_neg N-4 \
    "IdempotencyFilter is NOT @Component (must remain @Bean in SecurityConfiguration)" \
    '@Component' \
    "$FILTER"

# Must still use jakarta.servlet (not javax) — Jakarta namespace invariant.
run_neg N-5 \
    "IdempotencyFilter does NOT import javax.servlet (must use jakarta)" \
    'import javax\.servlet' \
    "$FILTER"

echo

# ---------------------------------------------------------------------------
# JUnit tests
# ---------------------------------------------------------------------------
echo "--- T — JUnit tests ---"

mvn_unit_test_passes() {
    "$MVN" test -Dtest="$1" -DfailIfNoTests=false -q 2>/dev/null
}
mvn_it_test_passes() {
    "$MVN" verify -Dit.test="$1" -DfailIfNoTests=false -DskipUnitTests=true -q 2>/dev/null
}

if [ "${SKIP_MVN:-0}" = "0" ]; then
    run T-FILT \
        "IdempotencyFilterUnitTest passes (mvn test)" \
        mvn_unit_test_passes IdempotencyFilterUnitTest
    run T-SVC \
        "RestIdempotencyServiceUnitTest passes (mvn test)" \
        mvn_unit_test_passes RestIdempotencyServiceUnitTest
    run T-FILT-IT \
        "IdempotencyFilterIT passes (mvn verify -Dit.test)" \
        mvn_it_test_passes IdempotencyFilterIT
else
    skip T-mvn "JUnit runs skipped" "SKIP_MVN=1"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
