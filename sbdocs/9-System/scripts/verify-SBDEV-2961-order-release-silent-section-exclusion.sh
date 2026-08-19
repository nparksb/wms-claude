#!/usr/bin/env bash
# verify-SBDEV-2961-order-release-silent-section-exclusion.sh   (r2 — post-review)
#
# Acceptance for: sbdocs/1-Projects/wms2/plan/SBDEV-2961-order-release-silent-section-exclusion.md
#
# Usage
#   PROJECT_ROOT=/path/to/v2/wms2-api WEB_UI_ROOT=/path/to/v2/wms2-web-ui \
#       bash sbdocs/9-System/scripts/verify-SBDEV-2961-order-release-silent-section-exclusion.sh
#
# Run it TWICE, and at least once WITHOUT SKIP_MVN:
#   1. BEFORE any change — capture the FAIL baseline.
#   2. AFTER implementation — require "Result: N pass, 0 fail". Paste that line in the report.
#
# r1 POSTMORTEM — why this file changed:
#   * r1's mvn_test_passes used `mvn test -q`, which suppresses BOTH "BUILD SUCCESS" and the
#     "Tests run:" line (they are INFO). The row was therefore PERMANENTLY RED on a green build,
#     making "0 fail" unattainable and inviting the implementer to set SKIP_MVN=1 — deleting the
#     only non-grep evidence in the script. r1 also reported "negative-tested: 3 pass / 21 fail",
#     but 3+21 = 24 = the grep rows ONLY; the two Maven rows were never executed. Do not repeat that.
#   * r1's file_contains_exactly_n_times used `grep -cE ... || echo 0`. grep -c PRINTS "0" and EXITS 1
#     on zero matches, so the `||` appended a second line: count="0\n0" -> integer error -> FAIL for a
#     bogus reason.
#   * r1 anchored all six B_* rows on the literal "orderRelease-noSection-" (an OptimisticLockRetry op
#     name). r2 drops OptimisticLockRetry, so those rows would have gone red on a CORRECT build.
#   * r1's B_guard_present never asserted the `return`, so an implementation that stamps and then falls
#     through to releaseOrder passed every row — defeating the one guarantee plan §3.2.5 exists for.
#   * r1 pinned a VACUOUS test (verifyNoInteractions on a mock that is not a dependency).
#
# NOTE: `mvn test` MUTATES the tracked archunit_store — revert it afterwards.
# NOTE on worktrees: point PROJECT_ROOT at the per-ticket worktree (or a symlink shadow root),
#       otherwise this grades the main checkout instead of the work.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
WEB_UI_ROOT="${WEB_UI_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }
[ -d "$WEB_UI_ROOT" ] || echo "WARN: WEB_UI_ROOT=$WEB_UI_ROOT not found — Fix D rows will FAIL"

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-26s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-26s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-26s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

# --- helpers: ALL fail closed on a missing file or unresolvable block ---------
# The stock template's file_not_contains is `! grep -qE p f`; on a missing file grep exits 2 and the
# `!` flips it to PASS, so every negative assertion about an absent file passes vacuously. Guarded.

file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

# Counts matches on CODE lines only — comment-only lines are stripped first.
# Caught by running this script: the TDD gate's own scaffolding Javadoc contained the literal
# "propagation = Propagation.REQUIRES_NEW", which made B2_propagation's count 2 and greened the row
# on a method that carried no annotation at all. Same false-green family as the preceded_by fix.
# Safe for the @Query counts too: those literals live in Java strings, not comment-only lines.
file_contains_exactly_n_times() {
    local pattern=$1 file=$2 n=$3 count
    [ -f "$file" ] || return 1
    count=$(grep -vE '^[[:space:]]*(//|\*|/\*)' "$file" | grep -cE "$pattern")
    [ "${count:-0}" -eq "$n" ] 2>/dev/null
}

# <pattern> must appear within <n> lines BEFORE <signature>, IGNORING COMMENT LINES. Used to bind an
# annotation to the method it annotates.
# r2 hazard: the un-filtered version was satisfied by a COMMENT. Given how loudly the plan documents
# "never drop REQUIRES_NEW", a line like `// REQUIRES_NEW is mandatory here (SBDEV-2961)` above an
# un-annotated method is likely to be written — and it would have greened the row labelled
# "<-- r1's defect", which must be the hardest row in this file, not the softest.
preceded_by() {
    local signature=$1 pattern=$2 n=$3 file=$4
    [ -f "$file" ] || return 1
    grep -B "$n" -E "$signature" "$file" 2>/dev/null \
        | grep -vE '^[[:space:]]*(//|\*|/\*)' \
        | grep -qE "$pattern"
}

# Code-only forward window from <anchor>. Comment lines are stripped BEFORE the window is applied, so
# <n> counts STATEMENTS, not prose.
#
# That ordering matters and was got wrong once. Stripping after `grep -A n` makes the window
# comment-length-sensitive: adding an explanatory comment inside the guard pushed its exit `return;`
# past a 14-raw-line window while a *different* `return;` (the short-circuit) stayed inside — so
# B3_guard_returns kept passing for the wrong reason. Windowing over code only removes that whole class
# of drift: the assertions no longer move when the comments do.
_code_window() {
    local anchor=$1 n=$2 file=$3
    [ -f "$file" ] || return 1
    grep -vE '^[[:space:]]*(//|\*|/\*)' "$file" 2>/dev/null | grep -A "$n" -E "$anchor"
}

# Code-only slice BETWEEN two code anchors. Preferred over a fixed-size window wherever a natural
# closing landmark exists: it is immune to both comment volume AND statement count.
#
# The fixed window needed a magic number threaded between two walls — large enough to reach the guard's
# exit `return;` (code offset 15), small enough to stop before the pre-round's `basicService.showLog()`
# (offset ~19), which would have falsely tripped B3_warn_ungated. Any later edit inside the guard would
# have pushed it back out. Anchoring the end on the pre-round gate removes the guesswork.
_code_block_between() {
    local start=$1 end=$2 file=$3
    [ -f "$file" ] || return 1
    grep -vE '^[[:space:]]*(//|\*|/\*)' "$file" 2>/dev/null | awk -v s="$start" -v e="$end" '
        $0 ~ s { inb = 1; print; next }
        inb && $0 ~ e { exit }
        inb { print }
    '
}
block_between_contains() {
    local start=$1 end=$2 pattern=$3 file=$4 blk
    blk=$(_code_block_between "$start" "$end" "$file") || return 1
    [ -n "$blk" ] || return 1
    printf '%s\n' "$blk" | grep -qE "$pattern"
}
block_between_not_contains() {
    local start=$1 end=$2 pattern=$3 file=$4 blk
    blk=$(_code_block_between "$start" "$end" "$file") || return 1
    [ -n "$blk" ] || return 1          # unresolvable anchors -> FAIL, never a vacuous pass
    ! printf '%s\n' "$blk" | grep -qE "$pattern"
}
block_between_contains_at_least() {
    local start=$1 end=$2 pattern=$3 file=$4 count=$5 blk c
    blk=$(_code_block_between "$start" "$end" "$file") || return 1
    [ -n "$blk" ] || return 1
    c=$(printf '%s\n' "$blk" | grep -cE "$pattern")
    [ "${c:-0}" -ge "$count" ]
}
followed_by() {
    local anchor=$1 pattern=$2 n=$3 file=$4
    _code_window "$anchor" "$n" "$file" | grep -qE "$pattern"
}
not_followed_by() {
    local anchor=$1 pattern=$2 n=$3 file=$4
    [ -f "$file" ] || return 1
    grep -qE "$anchor" "$file" || return 1     # anchor absent -> FAIL, never a vacuous pass
    ! _code_window "$anchor" "$n" "$file" | grep -qE "$pattern"
}
# <pattern> must appear at least <count> times in the code-only window.
followed_by_at_least() {
    local anchor=$1 pattern=$2 n=$3 file=$4 count=$5 c
    [ -f "$file" ] || return 1
    c=$(_code_window "$anchor" "$n" "$file" | grep -cE "$pattern")
    [ "${c:-0}" -ge "$count" ]
}

# Inclusive slice: first line matching <start> through the next line matching <end>. Gives real
# CONTAINMENT — the two release queries are near-identical, so a file-wide grep cannot tell them
# apart. Ablation-proven in r1: removing only the stream filter flipped A1 green while
# A2_list_filter_retained stayed green.
_block() {
    local start=$1 end=$2 file=$3
    [ -f "$file" ] || return 1
    awk -v s="$start" -v e="$end" '
        $0 ~ s { inb = 1 }
        inb    { print }
        inb && $0 ~ e { exit }
    ' "$file"
}
block_contains() {
    local start=$1 end=$2 pattern=$3 file=$4 blk
    blk=$(_block "$start" "$end" "$file") || return 1
    [ -n "$blk" ] || return 1
    printf '%s\n' "$blk" | grep -qE "$pattern"
}
block_not_contains() {
    local start=$1 end=$2 pattern=$3 file=$4 blk
    blk=$(_block "$start" "$end" "$file") || return 1
    [ -n "$blk" ] || return 1              # markers unresolvable -> FAIL, never a vacuous pass
    ! printf '%s\n' "$blk" | grep -qE "$pattern"
}

# `-o` (offline) is deliberate: without it, two concurrent runs contend on the shared ~/.m2 and can fail
# for reasons that have nothing to do with the code. A code-review lane hit exactly that and got
# `41 pass, 3 fail` with ALL THREE Maven rows red at once, which re-ran clean standalone.
# ⚠ ALL THREE M-ROWS RED SIMULTANEOUSLY IS THE SIGNATURE OF A COLLISION, NOT OF BROKEN CODE — re-run
# serially before believing it. (`-o` is safe here: every dependency is already in ~/.m2 by the time the
# grep rows above have passed, since they require a built tree.)
mvn_test_passes() {
    local out
    out=$(mvn -o test -Dtest="$1" -Dsurefire.failIfNoSpecifiedTests=false 2>&1)
    printf '%s\n' "$out" | grep -qE "BUILD SUCCESS" || return 1
    # Require tests to have ACTUALLY RUN: with failIfNoSpecifiedTests=false a non-existent class
    # yields BUILD SUCCESS, which would pass vacuously.
    # ", Skipped: 0" closes the last hole: a fully @Disabled class reports
    # "Tests run: N, Failures: 0, Errors: 0, Skipped: N", which would otherwise match.
    printf '%s\n' "$out" | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0, Skipped: 0"
}
mvn_test_compile_passes() { mvn -o clean test-compile 2>&1 | grep -qE "BUILD SUCCESS"; }

# --- targets ------------------------------------------------------------------
REPO_F=src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderPositionRepository.java
CO_REPO_F=src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderRepository.java
PROJ_F=src/main/java/net/aim_ai/wms/repo/projection/OrderReleaseInfoView.java
JOB_F=src/main/java/net/aim_ai/wms/schedulejob/OrderReleaseJob.java
SVC_F=src/main/java/net/aim_ai/wms/service/job/ReleaseOrderJobService.java
METRICS_F=src/main/java/net/aim_ai/wms/schedulejob/JobMetrics.java
MONITOR_F=src/main/java/net/aim_ai/wms/repo/jpa/OrderMonitorViewRepository.java
GUARD_T=src/test/java/net/aim_ai/wms/unit/schedulejob/OrderReleaseJobSectionGuardTest.java
JOB_T=src/test/java/net/aim_ai/wms/unit/schedulejob/OrderReleaseJobTest.java
OPENPARCELS_F="$WEB_UI_ROOT/components/outbound/pickPack/openParcels.vue"
PARCELDETAILS_F="$WEB_UI_ROOT/components/outbound/pickPack/parcelDetails.vue"
CONSTANTS_F="$WEB_UI_ROOT/util/constantValues.js"

# Block markers — each confirmed unique in its file.
STREAM_START='org.hibernate.fetchSize'
STREAM_END='Stream<OrderReleaseInfoView> streamOrderReleaseInfo'
LIST_START='rel = "getOrderReleaseInfo"'
LIST_END='List<OrderReleaseInfoView> getOrderReleaseInfo'
# The guard is inline in processOrderGroup. Anchored on the null test itself (NOT a bare "getSectionId",
# which a comment or javadoc mention would shift) and asserted with a bounded forward window rather than a
# brace slice — see followed_by above for why the brace anchor was unsafe in both directions.
GUARD_ANCHOR='getSectionId\(\)[[:space:]]*==[[:space:]]*null'
GUARD_END='orderStatus > RAW'
GUARD_WINDOW=14   # retained for rows where a window is genuinely the right shape

# === Fix A — release query surfaces the section ===============================
check_A1_filter_removed()  { block_not_contains "$STREAM_START" "$STREAM_END" 'AND sec\.id is not null' "$REPO_F"; }
check_A1_alias_added()     { block_contains "$STREAM_START" "$STREAM_END" 'sec\.id[[:space:]]+AS[[:space:]]+sectionId' "$REPO_F"; }
check_A1_join_order_client(){ block_contains "$STREAM_START" "$STREAM_END" 'JOIN client[[:space:]]+ON co\.client_id' "$REPO_F"; }
check_A1_orderby_intact()  { block_contains "$STREAM_START" "$STREAM_END" 'ORDER BY co\.prio DESC.*co\.id ASC' "$REPO_F"; }
check_A_filter_count_one() { file_contains_exactly_n_times 'AND sec\.id is not null' "$REPO_F" 1; }
check_A2_list_alias()      { block_contains "$LIST_START" "$LIST_END" 'sec\.id[[:space:]]+AS[[:space:]]+sectionId' "$REPO_F"; }
check_A2_list_filter_kept(){ block_contains "$LIST_START" "$LIST_END" 'AND sec\.id is not null' "$REPO_F"; }
check_A2_list_join_kept()  { block_contains "$LIST_START" "$LIST_END" 'JOIN client[[:space:]]+ON cob\.client_id' "$REPO_F"; }
check_A3_projection()      { file_contains 'Long[[:space:]]+getSectionId\(\)[[:space:]]*;' "$PROJ_F"; }

# === Fix B — CAS in its own transaction ======================================
check_B1_cas_method()      { file_contains 'int[[:space:]]+markClientHasNoSection' "$CO_REPO_F"; }
check_B1_cas_modifying()   { preceded_by 'int[[:space:]]+markClientHasNoSection' '@Modifying' 4 "$CO_REPO_F"; }
# Allow-list, NOT `state < :assigned`: the wide form relabels RAW_ON_HOLD/55-58 as 45 if a section is
# removed from a client, destroying the stock-hold diagnosis (plan §3.2.2).
check_B1_cas_allowlist()   { file_contains 'co\.state[[:space:]]+IN[[:space:]]*\([[:space:]]*:raw,[[:space:]]*:futurePickingDate[[:space:]]*\)' "$CO_REPO_F"; }
check_B1_cas_not_wide()    { file_not_contains 'co\.state[[:space:]]*<[[:space:]]*:assigned' "$CO_REPO_F"; }
# Bulk JPQL bypasses AuditingEntityListener, so `modified` must be set explicitly or there is no
# per-row evidence of WHEN an order was stamped (plan §3.2.2, manual §6.4 #6).
check_B1_cas_sets_modified(){ file_contains 'co\.modified[[:space:]]*=[[:space:]]*CURRENT_TIMESTAMP' "$CO_REPO_F"; }
# THE r1 KILLER: a REQUIRED write joins the caller's readOnly tx and is silently discarded.
# preceded_by now strips comment lines, so a `// REQUIRES_NEW ...` note cannot green this.
check_B2_requires_new()    { preceded_by 'markClientHasNoSection\((final[[:space:]]+)?long' 'REQUIRES_NEW' 3 "$SVC_F"; }
# NOT a bare file_contains: releaseOrder ALREADY carries Propagation.REQUIRES_NEW at :119, so a
# file-wide check passes on the unfixed build and proves nothing about the new method. Caught by
# negative-testing this script. Pre-fix count is 1; B2 must add the second.
check_B2_propagation()     { file_contains_exactly_n_times 'Propagation\.REQUIRES_NEW' "$SVC_F" 2; }
check_B2_tenant_tm()       { preceded_by 'markClientHasNoSection\((final[[:space:]]+)?long' 'tenantTransactionManager' 3 "$SVC_F"; }
check_B3_guard_present()   { file_contains "$GUARD_ANCHOR" "$JOB_F"; }
# §3.2.5: without the return, the order falls through to releaseOrder and gets relabelled RAW_ON_HOLD.
# TWO returns are required, not one: the short-circuit's (already-marked) and the guard's own exit. A
# single-`return;` assertion is satisfied by the short-circuit alone, so it would stay green even if the
# guard-exit return — the whole anti-clobber guarantee — were deleted.
check_B3_guard_returns()   { block_between_contains_at_least "$GUARD_ANCHOR" "$GUARD_END" 'return;' "$JOB_F" 2; }
check_B3_calls_cas()       { block_between_contains "$GUARD_ANCHOR" "$GUARD_END" 'markClientHasNoSection' "$JOB_F"; }
check_B3_skip_counter()    { block_between_contains "$GUARD_ANCHOR" "$GUARD_END" 'tenantOrdersSkippedNoSection' "$JOB_F"; }
check_B3_marked_counter()  { block_between_contains "$GUARD_ANCHOR" "$GUARD_END" 'tenantOrdersMarkedNoSection' "$JOB_F"; }
check_B3_warn()            { block_between_contains "$GUARD_ANCHOR" "$GUARD_END" 'LOG\.warn' "$JOB_F"; }
check_B3_warn_ungated()    { block_between_not_contains "$GUARD_ANCHOR" "$GUARD_END" 'showLog' "$JOB_F"; }
# Regression guard against r1's defect being reintroduced inside the guard.
check_B3_no_direct_save()  { block_between_not_contains "$GUARD_ANCHOR" "$GUARD_END" 'customerorderRepository\.save' "$JOB_F"; }
# Cost fix both reviewers flagged: without this the CAS opens a REQUIRES_NEW tx per section-less order
# PER TICK (~110/min) instead of per transition.
check_B3_short_circuit()   { block_between_contains "$GUARD_ANCHOR" "$GUARD_END" 'CLIENT_HAS_NO_SECTION' "$JOB_F"; }
# §3.2.4: at state 45 the pre-round runs with positions still RAW and can return without releasing.
check_B4_preround_gate()   { file_contains 'orderStatus > RAW[[:space:]]*&&.*CLIENT_HAS_NO_SECTION' "$JOB_F"; }

# === Fix C — two meters ======================================================
check_C_skip_method()   { file_contains 'public void tenantOrdersSkippedNoSection' "$METRICS_F"; }
check_C_marked_method() { file_contains 'public void tenantOrdersMarkedNoSection' "$METRICS_F"; }
check_C_skip_name()     { file_contains 'orders_skipped_no_section' "$METRICS_F"; }
check_C_marked_name()   { file_contains 'orders_marked_no_section' "$METRICS_F"; }

# === Fix D — web UI picking-date remedy ======================================
check_D_openparcels()      { file_contains "state === 'No Section'" "$OPENPARCELS_F"; }
check_D_parceldetails()    { file_contains "state === 'No Section'" "$PARCELDETAILS_F"; }
# getStateCode does an unguarded code[0].code — removing this entry is a client-side TypeError.
check_D_statelist_intact() { file_contains "name: 'No Section', code: 45" "$CONSTANTS_F"; }

# === Fix E — Order Monitor dashboard bucket ==================================
check_E_widened()   { file_contains_exactly_n_times 'co\.state IN \(0, ?45\)' "$MONITOR_F" 4; }
check_E_old_gone()  { file_not_contains 'co\.state = 0 AND co\.pickingdate' "$MONITOR_F"; }

# === Tests ===================================================================
check_T_guard_test_exists() { [ -f "$GUARD_T" ]; }
check_T_never_releases()    { file_contains 'never\(\)\)\.releaseOrder' "$GUARD_T"; }
# Method names follow the TDD-gate convention <method>_should<Outcome>_when<Condition>, so this greps
# the name the gate actually wrote, not the plan's earlier shorthand.
check_T_warm_map()          { file_contains 'whenOrderHealsFrom45AndFixMapIsWarm' "$GUARD_T"; }
# r1 pinned a test that could not fail; make sure it was not copied forward.
check_T_no_vacuous_oms()    { file_not_contains 'verifyNoInteractions\(manageOrderService\)' "$GUARD_T"; }
check_T1_existing_stubbed() { file_contains 'getSectionId' "$JOB_T"; }

# === Runner ==================================================================
echo
echo "verify-SBDEV-2961 (r2) — order release silent section exclusion"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  WEB_UI_ROOT=$WEB_UI_ROOT"
echo

echo "Fix A — release query surfaces the section"
run A1_filter_removed      "A1 stream: section filter removed"            check_A1_filter_removed
run A1_alias_added         "A1 stream: sec.id AS sectionId"               check_A1_alias_added
run A1_join_order_client   "A1 stream: client joined on co.client_id"     check_A1_join_order_client
run A1_orderby_intact      "A1 stream: co.id ASC tiebreaker intact"       check_A1_orderby_intact
run A_filter_count_one     "A  exactly one section filter left in file"   check_A_filter_count_one
run A2_list_alias          "A2 list: sectionId alias added"               check_A2_list_alias
run A2_list_filter_kept    "A2 list: filter retained (HAL unchanged)"     check_A2_list_filter_kept
run A2_list_join_kept      "A2 list: still joined on cob.client_id"       check_A2_list_join_kept
run A3_projection          "A3 projection exposes Long getSectionId()"    check_A3_projection
echo

echo "Fix B — CAS the state in its own transaction"
run B1_cas_method          "B1 CustomerorderRepository CAS method"        check_B1_cas_method
run B1_cas_modifying       "B1 CAS is @Modifying"                         check_B1_cas_modifying
run B1_cas_allowlist       "B1 CAS state allow-list (raw, futurePicking)" check_B1_cas_allowlist
run B1_cas_not_wide        "B1 CAS does NOT use state < :assigned"        check_B1_cas_not_wide
run B1_cas_sets_modified   "B1 CAS sets co.modified explicitly"           check_B1_cas_sets_modified
run B2_requires_new        "B2 writer is REQUIRES_NEW  <-- r1's defect"   check_B2_requires_new
run B2_propagation         "B2 Propagation.REQUIRES_NEW present in file"  check_B2_propagation
run B2_tenant_tm           "B2 writer names tenantTransactionManager"     check_B2_tenant_tm
run B3_guard_present       "B3 sectionId == null branch"                  check_B3_guard_present
run B3_guard_returns       "B3 guard RETURNS (skips releaseOrder)"        check_B3_guard_returns
run B3_calls_cas           "B3 guard calls the CAS method"                check_B3_calls_cas
run B3_short_circuit       "B3 short-circuits when already state 45"      check_B3_short_circuit
run B3_skip_counter        "B3 per-tick skip counter"                     check_B3_skip_counter
run B3_marked_counter      "B3 transition counter"                        check_B3_marked_counter
run B3_warn                "B3 emits LOG.warn"                           check_B3_warn
run B3_warn_ungated        "B3 WARN not behind showLog()"                 check_B3_warn_ungated
run B3_no_direct_save      "B3 no repository.save inside the guard"       check_B3_no_direct_save
run B4_preround_gate       "B4 pre-round gate excludes state 45"          check_B4_preround_gate
echo

echo "Fix C — two meters"
run C_skip_method          "C JobMetrics.tenantOrdersSkippedNoSection"    check_C_skip_method
run C_marked_method        "C JobMetrics.tenantOrdersMarkedNoSection"     check_C_marked_method
run C_skip_name            "C counter orders_skipped_no_section"          check_C_skip_name
run C_marked_name          "C counter orders_marked_no_section"           check_C_marked_name
echo

echo "Fix D — web UI picking-date remedy"
run D_openparcels          "D openParcels allows 'No Section'"            check_D_openparcels
run D_parceldetails        "D parcelDetails allows 'No Section'"          check_D_parceldetails
run D_statelist_intact     "D stateList still maps 'No Section'->45"      check_D_statelist_intact
echo

echo "Fix E — Order Monitor dashboard bucket"
run E_widened              "E order_imported widened in all 4 queries"    check_E_widened
run E_old_gone             "E no bare co.state = 0 bucket left"           check_E_old_gone
echo

echo "Tests"
run T_guard_test_exists    "T guard test class exists"                    check_T_guard_test_exists
run T_never_releases       "T asserts releaseOrder never called"          check_T_never_releases
run T_warm_map             "T covers warm-map self-heal (B4)"             check_T_warm_map
run T_no_vacuous_oms       "T r1's vacuous OMS assertion not reused"      check_T_no_vacuous_oms
run T1_existing_stubbed    "T1 OrderReleaseJobTest stubs getSectionId"    check_T1_existing_stubbed
echo

echo "Maven (slow; SKIP_MVN=1 to skip — but run WITHOUT it at least once)"
if [ "${SKIP_MVN:-0}" = "1" ]; then
    skip M_test_compile "mvn clean test-compile" "SKIP_MVN=1"
    skip M_guard_test   "guard unit test passes" "SKIP_MVN=1"
    skip M_job_tests    "all OrderReleaseJob* tests pass" "SKIP_MVN=1"
else
    # test-compile, not compile: `compile` builds main only and misses the ctor-arity breaks in the
    # three existing job test classes (plan §5.2 step 11).
    run M_test_compile  "mvn clean test-compile"           mvn_test_compile_passes
    run M_guard_test    "guard unit test passes"           mvn_test_passes OrderReleaseJobSectionGuardTest
    run M_job_tests     "all OrderReleaseJob* tests pass"  mvn_test_passes 'OrderReleaseJob*'
fi
echo

# NOT asserted here, deliberately:
#  - Fix A has NO automated proof: OrderReleaseSectionQueryIT ships @Disabled because the v2
#    Testcontainers lane cannot boot (SBDEV-2217). Greps prove the SQL text changed, not that the
#    query returns the right rows. Plan §6.4 #1/#4 are the only live evidence.
#  - Fix E likewise has no automated test; §6.4 #5 is the only evidence.
#  Do NOT read "0 fail" as "the queries are correct".
skip IT_section_query "OrderReleaseSectionQueryIT"      "v2 IT harness broken — SBDEV-2217"
skip IT_dashboard     "order_imported bucket behaviour" "native SQL, no IT lane — manual §6.4 #5"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
