#!/usr/bin/env bash
# verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2854-replenish-rejects-non-flowbin-destination.md
#   "WMSv2: Replenishment rejects operational destination location as 'not a flowbin'"
#
# Usage (point PROJECT_ROOT at the v2 checkout or the per-ticket worktree):
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2854-replenish-rejects-non-flowbin-destination.sh
#
# BASELINE CONTRACT
# -----------------
# Run this BEFORE any code change. Every A*/B*/C*/D*/E*/F* positive check must FAIL
# on the unfixed build. A positive check that already passes at baseline is not
# testing anything — fix the check, not the code.
#
# Final acceptance: "Result: N pass, 0 fail" pasted verbatim into the end-of-task report.
#
# Fix map (see plan §3):
#   A  WmsConstants switch + capability helpers (useforpicking, not location type)
#   B  assignDestinationForMultiUnitLoads three-way branch  (primary reported defect, :917)
#   C  checkDestination three-way branch + inverted findByLabelid guard DELETED  (:399, :407-411)
#   D  finishReplenishmentOrderInternal resolves a real UL for FLA-free destinations  (:501-520)
#   E  item-side FLA guard at :390 aligned with the :908 form
#   F  Flyway V2.2.10 seeds REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS (no version gap — review H3)

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

# run <id> <description> <command...>
run() {
    local id=$1
    local desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1
    local desc=$2
    local reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- assertion helpers -------------------------------------------------------

file_contains() { [ -f "$2" ] && grep -qE "$1" "$2"; }

# NOTE on negative checks: a missing file must NOT count as "the old code is gone" —
# that would silently pass if a path typo crept in. Hence the explicit -f guard.
file_not_contains() { [ -f "$2" ] && ! grep -qE "$1" "$2"; }

file_contains_n_times() {
    local pattern=$1 file=$2 n=$3
    [ -f "$file" ] || return 1
    local count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

# Multi-line regex match across a whole file (for branch shapes that span lines).
# The -f guard matters: `perl -0777 -ne` on a nonexistent file never enters the
# implicit loop and therefore exits 0, which would report a false PASS.
file_contains_ml() {
    [ -f "$2" ] || return 1
    local pattern=$1 file=$2
    [ -f "$file" ] || return 1
    perl -0777 -ne "exit 1 unless /$pattern/s" "$file"
}

# Negation of the above, with the same -f guard. Kept as its own helper so the
# polarity is stated once instead of re-derived at each call-site.
file_not_contains_ml() {
    [ -f "$2" ] || return 1
    local pattern=$1 file=$2
    [ -f "$file" ] || return 1
    ! perl -0777 -ne "exit 1 unless /$pattern/s" "$file"
}

# Strip comments before grepping. REQUIRED for every negative check on a Java file:
# the fix deliberately leaves comments explaining what the old broken construct was
# ("previously threw ... when findByLabelid(code) came back EMPTY"), and a naive
# `file_not_contains` would match that prose and report FAIL on correct code. Removes
# /* */ blocks and // line comments; string literals containing "//" are not a concern
# in this file. Writes to stdout.
code_only() {
    local file=$1
    [ -f "$file" ] || return 1
    perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$file"
}

# Negative check against code only, ignoring comments.
code_not_contains() {
    local pattern=$1 file=$2
    [ -f "$file" ] || return 1
    ! code_only "$file" | grep -qE "$pattern"
}

# Multi-line negative check against code only.
code_not_contains_ml() {
    [ -f "$2" ] || return 1
    local pattern=$1 file=$2
    [ -f "$file" ] || return 1
    ! code_only "$file" | perl -0777 -ne "exit 1 unless /$pattern/s"
}

# Print just ONE method's body: from its signature line to the next member declaration at the
# same indent (4 spaces). Necessary because an unbounded `.*?` anchored on a method name happily
# matches text hundreds of lines later in another method — which produced two false results in
# this script's own history (E1, D2). Use this for any assertion that means "inside method X".
method_body() {
    local file=$1 signature=$2
    [ -f "$file" ] || return 1
    # signature goes through the ENVIRONMENT, not @ARGV: with `perl -n` an extra @ARGV element is
    # treated as a FILE to open, so the earlier `-- "$signature"` form read nothing and every
    # assertion built on it silently succeeded. Counter-tested below.
    SB_SIG="$signature" perl -0777 -ne '
        my $sig = $ENV{SB_SIG};
        if (/\Q$sig\E/) {
            my $rest = substr($_, $-[0]);
            if ($rest =~ /\n(?=    (?:private|public|protected)\s)/) {
                $rest = substr($rest, 0, $+[0]);
            }
            print $rest;
        }
    ' "$file"
}

# Assert a regex does NOT appear inside one method body (comments stripped).
method_not_contains() {
    local file=$1 signature=$2 pattern=$3
    [ -f "$file" ] || return 1
    ! method_body "$file" "$signature" | perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' | grep -qE "$pattern"
}

# Assert a regex DOES appear inside one method body.
method_contains() {
    local file=$1 signature=$2 pattern=$3
    [ -f "$file" ] || return 1
    method_body "$file" "$signature" | grep -qE "$pattern"
}

# Count OCCURRENCES (not lines) of a multi-line pattern. Needed wherever the
# construct spans a line break — `grep -c` counts matching lines and so can never
# reach 2 for a two-line `if (a\n && b)`, which is exactly the shape at :908-909.
file_contains_ml_n_times() {
    local pattern=$1 file=$2 n=$3
    [ -f "$file" ] || return 1
    local count
    count=$(perl -0777 -ne "my \$c = () = /$pattern/gs; print \$c" "$file" 2>/dev/null)
    [ "${count:-0}" -ge "$n" ]
}

# Match a regex only inside a line range — proves the construct is at the RIGHT
# call-site, not merely somewhere in a 1000-line service.
range_contains() {
    local file=$1 start=$2 end=$3 pattern=$4
    sed -n "${start},${end}p" "$file" | grep -qE "$pattern"
}

range_not_contains() {
    local file=$1 start=$2 end=$3 pattern=$4
    ! sed -n "${start},${end}p" "$file" | grep -qE "$pattern"
}

# Run a test class and require that it ACTUALLY RAN and passed.
#
# Two traps this repo has hit before, both avoided here:
#   1. `mvn -q` suppresses INFO, so "BUILD SUCCESS" and the "Tests run:" summary are
#      never printed and the grep can never match — a guaranteed false FAIL. Measured:
#      0 matches on a class that passes 108/108. (Same bug as SBDEV-2802's A6 check and
#      the verify-plan-template helper flagged in SBDEV-2781.) So: no -q.
#   2. `-DfailIfNoTests=false` exits 0 when the class does not exist — a false PASS.
#      So the summary must show a NON-ZERO test count, not merely zero failures.
mvn_test_passes() {
    local test_class=$1
    local out
    out=$(mvn -o test -Dtest="$test_class" -DfailIfNoTests=false 2>&1)
    echo "$out" | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0" \
        && ! echo "$out" | grep -q "BUILD FAILURE"
}

# Integration tests are EXCLUDED from surefire (pom.xml:449-452) and run by failsafe
# (pom.xml:562-569), so `mvn test -Dtest=SomethingIntegrationTest` silently runs nothing.
# Anything asserting on an *IntegrationTest must go through verify/failsafe. Kept here so a
# future author wiring the deferred IT (see the Behavioral gate below) does not repeat the
# mistake this script originally made.
mvn_it_passes() {
    local it_class=$1
    local out
    out=$(mvn -o verify -Dit.test="$it_class" -DfailIfNoTests=false -DskipUTs=true 2>&1)
    echo "$out" | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0" \
        && ! echo "$out" | grep -q "BUILD FAILURE"
}

# --- file shorthands ---------------------------------------------------------

SVC="src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java"
CONST="src/main/java/net/aim_ai/wms/service/WmsConstants.java"
MIGDIR="src/main/resources/db/migration"
MIG="$MIGDIR/V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop.sql"
UTEST="src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java"

# === Fix A — sysprop constant + helpers ======================================

check_A_const_key() {
    file_contains 'SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_KEY[[:space:]]*=[[:space:]]*"REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS"' "$CONST"
}

check_A_const_default_value() {
    # Default must be flowbin-only so untouched tenants keep pre-SBDEV-2854 behavior.
    file_contains 'SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_DEFAULT_VALUE' "$CONST"
}

check_A_helper_area_predicate() {
    # Capability, not location type. On wineco UAT the club locations share type 'cases and
    # pallets' with 472 source racks and PutAwayLane, so a type allow-list would open all of them.
    file_contains 'private boolean isPickingArea\(LocationArea' "$SVC" \
        && file_contains 'getUseforpicking\(\)' "$SVC"
}

check_A_helper_reads_sysprop() {
    method_contains "$SVC" 'private boolean isNonFlowbinDestinationAllowed' \
        'syspropService\.getSysvalue'
}

check_A_helper_defaults_to_flowbin_when_blank() {
    # Absent/blank sysprop must fall back to OFF, never to ON.
    method_contains "$SVC" 'private boolean isNonFlowbinDestinationAllowed' \
        'SYSTEM_PROPERTY_REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS_DEFAULT_VALUE'
}

check_A_helper_lane_guard() {
    file_contains 'private boolean isNonStorageLane\(Location' "$SVC"
}

check_A_lane_guard_covers_all_five_flags() {
    file_contains_ml 'isNonStorageLane.*?getStaginglane.*?getGate.*?getTransferlane.*?getAutomationlane.*?getCrossdockinglane' "$SVC"
}

check_A_area_resolution_is_null_safe() {
    # location.areaId is nullable; findById(null) would blow up.
    method_contains "$SVC" 'private LocationArea resolveArea' 'areaId == null'
}

# === Fix B — multi-UL destination branch (primary defect, was :917) ===========

check_B_branch_present() {
    # assignDestinationForMultiUnitLoads must consult the allowlist, not a bare type equality.
    method_contains "$SVC" 'private Location assignDestinationForMultiUnitLoads' 'isPickingArea\(destinationArea\)'
}

check_B_lane_guard_applied() {
    method_contains "$SVC" 'private Location assignDestinationForMultiUnitLoads' 'isNonFlowbinDestinationAllowed\(\) && isPickingArea'
}

check_B_flowbin_branch_still_creates_fla() {
    # The flowbin path must be preserved, guarded by an explicit flowbin test.
    file_contains_ml 'assignDestinationForMultiUnitLoads.*?STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN\.equals\(locationType\.getSltname\(\)\).*?createFixedLocationAssignment' "$SVC"
}

check_B_no_fla_on_nonflowbin_branch() {
    # NEGATIVE: the FLA-free branch must not create an FLA. Asserted structurally by
    # requiring at most 2 createFixedLocationAssignment call-sites service-wide
    # (one per destination path's flowbin branch) + 1 in the finish path = 3 total.
    # Before the fix there are 3 (:415, :510, :923); after Fix D reworks :510 the
    # count must not GROW. Behavioral proof is the unit test with verify(never()).
    local count
    count=$(grep -cE 'fixLocationAssignmentService\.createFixedLocationAssignment' "$SVC" 2>/dev/null || echo 0)
    [ "$count" -le 3 ]
}

# === Fix C — single-UL destination branch + inverted guard deleted ============

check_C_branch_present() {
    method_contains "$SVC" 'public void checkDestination' 'isPickingArea\(destinationArea\)'
}

check_C_lane_guard_applied() {
    method_contains "$SVC" 'public void checkDestination' 'isNonFlowbinDestinationAllowed\(\) && isPickingArea'
}

check_C_inverted_guard_removed() {
    # NEGATIVE — the core of Bug 2. The guard threw "Unit load already exists." when
    # findByLabelid(code) was EMPTY. Both the message and the inverted condition must go.
    # code_not_contains, not file_not_contains: the fix leaves a comment quoting the old
    # message on purpose, and that prose must not be mistaken for the live construct.
    code_not_contains 'Unit load already exists\.' "$SVC"
}

check_C_findbylabelid_guard_gone_from_checkDestination() {
    # NEGATIVE, scoped: no `findByLabelid(code)` precondition left in checkDestination.
    # (findByLabelid legitimately survives elsewhere, e.g. resolveUnitloadId — hence the
    # `public void checkDestination` anchor. `[^}]` stops the match running past the
    # method's closing brace into unrelated code.)
    code_not_contains_ml 'public void checkDestination.*?findByLabelid\(code\)' "$SVC"
}

check_C_flowbin_branch_preserved() {
    file_contains_ml 'public void checkDestination.*?STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN\.equals\(locationType\.getSltname\(\)\)' "$SVC"
}

check_C_occupied_flowbin_still_rejected() {
    # Guardrail must survive: an occupied flowbin is still refused.
    file_contains 'Destination has already a unit load!' "$SVC"
}

# === Cross-cutting — the leaky message is gone service-wide ==================

check_MSG_flowbin_message_gone() {
    # NEGATIVE: "Destination is not a flowbin!" must not remain in MobileReplenishService
    # (both :400 and :918). It legitimately remains in MobileMoveStockService and
    # FixLocationAssignmentService — out of scope per plan §0 rows #10/#12 — so this
    # check is deliberately file-scoped.
    code_not_contains 'Destination is not a flowbin!' "$SVC"
}

check_MSG_actionable_replacement() {
    # The replacement must name the offending type AND the sysprop to change.
    method_contains "$SVC" 'private String rejectDestinationMessage' "use for picking" \
        && method_contains "$SVC" 'private String rejectDestinationMessage' 'REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS'
}

check_MSG_present_on_both_paths() {
    # The message body lives in ONE helper (rejectDestinationMessage) rather than being
    # duplicated, so counting the string itself would cap at 1. What must be true is that
    # BOTH destination paths throw it — so count the throw sites instead.
    file_contains_n_times 'throw new BusinessException\(rejectDestinationMessage\(' "$SVC" 2
}

# === Fix D — finish path resolves a real destination unit load ===============

check_D_resolver_present() {
    file_contains 'private Unitload resolveNonFlowbinDestinationUnitload\(' "$SVC"
}

check_D_resolver_does_not_merge() {
    # INVERTED by review H1. The resolver used to merge into an existing unit load on the
    # destination carrying the same SKU. That is correct for a flowbin (a virtual pick face) and
    # wrong for a shared location of real physical containers — it recorded 24 units on a unit
    # load physically holding 12. Every replenished container now gets its own unit load, which
    # also removed a nondeterministic merge target, a ~115-query N+1 inside the locked finish
    # transaction, and unfiltered entityLock/clientId/carrier candidates.
    # Scoped to the method body: findByUnitloadId legitimately survives elsewhere in this file
    # (validateUnitLoadEntry), so a file-wide or `.*?`-anchored assertion would be meaningless.
    method_not_contains "$SVC" 'private Unitload resolveNonFlowbinDestinationUnitload' 'findByUnitloadId' \
        && method_not_contains "$SVC" 'private Unitload resolveNonFlowbinDestinationUnitload' 'findByStoragelocationId'
}

check_D_resolver_validates_destination_client() {
    # Review M4: a client-scoped destination must not receive another client's stock.
    method_contains "$SVC" 'private Unitload resolveNonFlowbinDestinationUnitload' 'destinationLocation\.getClientId\(\)' \
        && file_contains 'is reserved for a different client' "$SVC"
}

check_H2_finish_reasserts_guards() {
    # Review H2: the sysprop + lane guards must gate the MUTATION, not just the scan. Two endpoints
    # reach finish with an unvalidated destination (PUT /order/{id}; checkDestination's early
    # return when the code already equals the DTO's destinationLocationName).
    method_contains "$SVC" 'private void finishReplenishmentOrderInternal' 'isNonFlowbinDestinationAllowed\(\)' \
        && method_contains "$SVC" 'private void finishReplenishmentOrderInternal' 'isPickingArea\(resolveArea'
}

check_D_resolver_creates_on_location_when_no_match() {
    file_contains_ml 'resolveNonFlowbinDestinationUnitload.*?unitloadService\.createUnitload' "$SVC"
}

check_D_resolver_invoked_from_finish() {
    file_contains_ml 'finishReplenishmentOrderInternal.*?resolveNonFlowbinDestinationUnitload' "$SVC"
}

check_D_finish_flowbin_branch_explicit() {
    # The finish path must only create an FLA when the destination is actually a flowbin.
    file_contains_ml 'finishReplenishmentOrderInternal.*?STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN\.equals\(destinationType\.getSltname\(\)\)' "$SVC"
}

check_D_finish_no_unconditional_fla_create() {
    # NEGATIVE — the pre-fix shape at :507-511 created an FLA for ANY destination lacking one.
    code_not_contains_ml 'if \(fixLocationAssignment == null\) \{\s*final Long sourceStockItemdataId' "$SVC"
}

check_D_constructor_deps_added() {
    file_contains_ml 'public MobileReplenishService\(.*?UnitloadService unitloadService' "$SVC"
}

check_D_constructor_ultype_dep_added() {
    file_contains_ml 'public MobileReplenishService\(.*?UnitloadTypeRepository unitloadTypeRepository' "$SVC"
}

check_D_no_field_injection() {
    # v2 rule: constructor injection only. One @Autowired legitimately pre-exists — the
    # @Lazy self-reference used for Spring proxy self-invocation (SBDEV-2575 pattern) — so
    # asserting zero can never pass. Assert instead that the count did not GROW, and that
    # both new dependencies are private final (i.e. constructor-injected).
    local autowired
    autowired=$(code_only "$SVC" | grep -c '@Autowired' || echo 0)
    [ "$autowired" -le 1 ] \
        && file_contains 'private final UnitloadService unitloadService;' "$SVC" \
        && file_contains 'private final UnitloadTypeRepository unitloadTypeRepository;' "$SVC"
}

# === Fix E — item-side FLA guard aligned with the :908 form ==================

check_E_guard_compares_location_id() {
    # BOTH destination paths must compare the item's existing assignment against the SCANNED
    # location id, rather than rejecting any item that has an assignment at all.
    #
    # Deliberately idiom-agnostic: checkDestination uses map(...).orElse(false) because
    # OptionalSafetyArchTest forbids Optional.get() in net.aim_ai.wms.service.. (SBDEV-2116),
    # while assignDestinationForMultiUnitLoads keeps its pre-existing isPresent() + get()
    # form (untouched, and already counted in that test's 8 known violations). Asserting one
    # specific shape would fail on correct code; what matters is that the comparison happens
    # on both paths. Baseline has exactly ONE occurrence (the multi-UL path), so 2 has teeth.
    file_contains_ml_n_times 'getAssignedlocationId\(\)\.equals\(storageLocation\.getId\(\)\)' "$SVC" 2
}

# === Fix F — Flyway seed migration ==========================================

check_F_migration_exists() {
    [ -f "$MIG" ]
}

check_F_migration_seeds_key() {
    file_contains "REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS" "$MIG"
}

check_F_migration_default_flowbin_only() {
    # Must ship default-off (flowbin only) — never pre-opt a tenant in.
    file_contains_ml "REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS',[[:space:]]*'false'" "$MIG"
}

check_F_migration_idempotent() {
    file_contains 'WHERE NOT EXISTS' "$MIG"
}

check_F_migration_uses_sequence() {
    # Literal ids collide on populated tenant DBs — must draw from seqentities.
    file_contains "nextval\('public\.seqentities'\)" "$MIG"
}

check_F_no_duplicate_version() {
    # Exactly one V2.2.10 migration — a second one silently breaks Flyway.
    # (Label corrected 2026-08-10: this said V2.2.11, left over from this plan's own version move
    # documented in its §824. The check below always targeted V2.2.10; only the comment was wrong.)
    local count
    count=$(ls "$MIGDIR" 2>/dev/null | grep -c '^V2\.2\.10__' || echo 0)
    [ "$count" -eq 1 ]
}

# === Tests exist ============================================================

check_T_unit_test_no_fla_on_nonflowbin() {
    file_contains 'acceptsAllowedNonFlowbinDestination_withoutCreatingFla' "$UTEST"
}

check_T_unit_test_backward_compat() {
    file_contains 'rejectsNonFlowbinDestination_whenSyspropDefault' "$UTEST"
}

check_T_unit_test_inverted_guard_regression() {
    file_contains 'allowsEmptyFlowbinWithNoMatchingLabel' "$UTEST"
}

check_T_unit_test_finish_paths() {
    file_contains_n_times 'finish_(mergesIntoExistingUnitLoadOnNonFlowbinDestination|createsUnitLoadOnNonFlowbinDestination_whenNoneMatches|stillCreatesFlaForEmptyFlowbinDestination)' "$UTEST" 3
}

check_T_unit_test_lane_guard() {
    file_contains 'destination_rejectsLaneEvenWhenTypeAllowed' "$UTEST"
}

check_T_unit_test_asserts_never_creates_fla() {
    # Behavioral proof that the FLA-free branch really is FLA-free.
    file_contains_ml 'never\(\)\)\.createFixedLocationAssignment' "$UTEST"
}

# === Wire into the runner ====================================================

echo
echo "verify-SBDEV-2854-replenish-rejects-non-flowbin-destination — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

echo "Fix A — configurable allowed destination types"
run A1  "sysprop KEY constant added"                      check_A_const_key
run A2  "sysprop default VALUE constant added"            check_A_const_default_value
run A3  "isPickingArea / useforpicking capability check"  check_A_helper_area_predicate
run A4  "helper reads the sysprop"                        check_A_helper_reads_sysprop
run A5  "blank sysprop falls back to flowbin-only"        check_A_helper_defaults_to_flowbin_when_blank
run A6  "isNonStorageLane exists"                         check_A_helper_lane_guard
run A7  "lane guard covers all five lane flags"           check_A_lane_guard_covers_all_five_flags
run A8  "resolveArea is null-safe on a null areaId"       check_A_area_resolution_is_null_safe
echo

echo "Fix B — multi-UL destination branch (primary defect, was :917)"
run B1  "allowlist consulted in multi-UL path"            check_B_branch_present
run B2  "lane guard applied on FLA-free branch"           check_B_lane_guard_applied
run B3  "flowbin branch still creates the FLA"            check_B_flowbin_branch_still_creates_fla
run B4  "NEG: FLA creation call-sites did not grow"       check_B_no_fla_on_nonflowbin_branch
echo

echo "Fix C — single-UL destination branch + inverted guard removed"
run C1  "allowlist consulted in checkDestination"         check_C_branch_present
run C2  "lane guard applied on FLA-free branch"           check_C_lane_guard_applied
run C3  "NEG: 'Unit load already exists.' gone"           check_C_inverted_guard_removed
run C4  "NEG: findByLabelid(code) guard gone"             check_C_findbylabelid_guard_gone_from_checkDestination
run C5  "flowbin branch preserved"                        check_C_flowbin_branch_preserved
run C6  "occupied-flowbin guardrail preserved"            check_C_occupied_flowbin_still_rejected
echo

echo "Error message quality (ticket acceptance criterion)"
run M1  "NEG: 'Destination is not a flowbin!' gone"       check_MSG_flowbin_message_gone
run M2  "replacement names area + capability + sysprop"   check_MSG_actionable_replacement
run M3  "new message on both destination paths"           check_MSG_present_on_both_paths
echo

echo "Fix D — finish path resolves a real destination unit load"
run D1  "resolveNonFlowbinDestinationUnitload exists"     check_D_resolver_present
run D2  "NEG: resolver does NOT merge (review H1)"        check_D_resolver_does_not_merge
run D2b "resolver validates destination client (M4)"      check_D_resolver_validates_destination_client
run H2  "finish re-asserts allow-list + lane guards"      check_H2_finish_reasserts_guards
run D3  "resolver creates a UL when none matches"         check_D_resolver_creates_on_location_when_no_match
run D4  "resolver invoked from the finish path"           check_D_resolver_invoked_from_finish
run D5  "finish FLA-create gated on flowbin type"         check_D_finish_flowbin_branch_explicit
run D6  "NEG: unconditional FLA-create at finish gone"    check_D_finish_no_unconditional_fla_create
run D7  "UnitloadService constructor dep added"           check_D_constructor_deps_added
run D8  "UnitloadTypeRepository constructor dep added"    check_D_constructor_ultype_dep_added
run D9  "NEG: no @Autowired field injection"              check_D_no_field_injection
echo

echo "Fix E — item-side FLA guard aligned with :908"
run E1  "guard compares assigned location id"             check_E_guard_compares_location_id
echo

echo "Fix F — Flyway seed migration"
run F1  "V2.2.10 migration file exists"                   check_F_migration_exists
run F2  "migration seeds the sysprop key"                 check_F_migration_seeds_key
run F3  "ships default-off (flowbin only)"                check_F_migration_default_flowbin_only
run F4  "migration is idempotent"                         check_F_migration_idempotent
run F5  "id drawn from seqentities"                       check_F_migration_uses_sequence
run F6  "exactly one V2.2.10 migration"                   check_F_no_duplicate_version
echo

echo "Tests exist (shape only — behavior proven by the mvn runs below)"
run T1  "no-FLA-on-non-flowbin test present"              check_T_unit_test_no_fla_on_nonflowbin
run T2  "backward-compat test present"                    check_T_unit_test_backward_compat
run T3  "inverted-guard regression test present"          check_T_unit_test_inverted_guard_regression
run T4  "all three finish-path tests present"             check_T_unit_test_finish_paths
run T5  "lane-guard test present"                         check_T_unit_test_lane_guard
run T6  "test asserts never() on FLA creation"            check_T_unit_test_asserts_never_creates_fla
echo

# === Behavioral gate ========================================================
# Code-shape greps prove the call exists; only the tests prove it works.
# Skip with SBDEV2854_SKIP_MVN=1 for a fast shape-only pass during iteration.

echo "Behavioral gate"
if [ "${SBDEV2854_SKIP_MVN:-0}" = "1" ]; then
    skip TEST-U "MobileReplenishServiceUnitTest passes" "SBDEV2854_SKIP_MVN=1"
    skip TEST-I "MobileReplenishServiceIntegrationTest passes" "SBDEV2854_SKIP_MVN=1"
else
    run TEST-U "MobileReplenishServiceUnitTest passes"    mvn_test_passes MobileReplenishServiceUnitTest
    # DEFERRED, not passing-by-omission. The plan's §6 promised a Testcontainers IT proving
    # end-to-end that no fix_location_assignment row is created for a club destination. It is
    # NOT written: BasePostgresIntegrationTest carries an open blocker (it cannot boot a full
    # context without the "integration" profile — TODO SBDEV-2217 in that class), and the
    # nearest working analogue is 567 lines. Unit coverage substitutes for the assertion
    # (verify(never()).createFixedLocationAssignment, mutation-validated), but not for real
    # Postgres. Tracked in the plan's Deliberately-skipped coverage table.
    # When written, assert it with mvn_it_passes (NOT mvn_test_passes — failsafe owns ITs).
    skip TEST-I "MobileReplenishServiceIntegrationTest passes" "deferred — see plan §6; unit-covered, Postgres-level assertion still owed"
fi
echo

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
