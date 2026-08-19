#!/usr/bin/env bash
# verify-SBDEV-2994-move-stock-unknown-destination-container-generic-error.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2994-move-stock-unknown-destination-container-generic-error.md
#
# Usage
# -----
#   PROJECT_ROOT=/path/to/v2/wms2-api \
#   MOBILE_ROOT=/path/to/v2/wms2-mobile-ui \
#   WEB_ROOT=/path/to/v2/wms2-web-ui \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2994-...sh
#
# Point all three roots at the implementation worktree (or a symlink shadow root). Left at
# their defaults this grades the main checkouts, not the work.
#
# REVISION 2 — 2026-08-18, after the ralplan consensus review (plan §14).
# ----------------------------------------------------------------------
# Revision 1 negative-tested at 4 pass / 21 fail / 1 skip, which looked healthy. The review
# then BUILT a wrong-implementation tree and demonstrated that FIVE rows (A3, B3, C1, T2, T3)
# PASSED against implementations wrong in exactly the way those rows exist to catch. Rewritten
# here. The recurring defect in all five was the same one this script had already been burned
# by twice: a FILE-SCOPED grep cannot express "in this method" or "in this construct", so any
# token appearing elsewhere in a 600-line file makes the row free.
#
# Design rules:
#   1. Every helper fails CLOSED on a missing file. The stock template's helpers fail OPEN, so
#      `file_not_contains` on a nonexistent path reports a false PASS — which is how a new-file
#      assertion green-lights work that was never done.
#   2. A row that cannot fail is worse than no row. A row that passes on a WRONG implementation
#      is worse still: it actively certifies the defect.
#   3. Code-shape greps prove a call exists; only tests prove it works. RUN_MVN=1 rows carry the
#      behavioural weight and are part of final acceptance (plan §8.7).
#
# BASELINE DISCIPLINE
# -------------------
# Run BEFORE any code change. Expected on origin/develop (api d2bedc0, mobile 8e623b8):
#   PASS  the FOUR parity pins only — A3, P1, P2, P3 — constructs already correct that must
#         stay green through the fix. Everything else FAILs.
#   Measured 2026-08-18 on origin/develop: Result: 4 pass, 41 fail, 1 skip.
# A red parity pin at baseline means the tree is not what this plan was written against.
# A green Fix row at baseline means the ROW is wrong, not the code — rewrite it before trusting
# any later green.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
MOBILE_ROOT="${MOBILE_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-mobile-ui}"
WEB_ROOT="${WEB_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }
[ -d "$MOBILE_ROOT" ] || { echo "FATAL: MOBILE_ROOT=$MOBILE_ROOT not found"; exit 2; }
[ -d "$WEB_ROOT" ]    || { echo "FATAL: WEB_ROOT=$WEB_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

SVC="src/main/java/net/aim_ai/wms/service/StockunitService.java"
ELIG="src/main/java/net/aim_ai/wms/service/DestinationEligibilityService.java"
CTL="src/main/java/net/aim_ai/wms/controller/StockUnitController.java"
ADVICE="src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java"
CONST="src/main/java/net/aim_ai/wms/service/WmsConstants.java"
MSG_BASE="src/main/resources/messages.properties"
MSG_EN="src/main/resources/messages_en_US.properties"
TEST_SVC="src/test/java/net/aim_ai/wms/unit/service/StockunitServiceTransferStockDestinationTest.java"
TEST_ELIG="src/test/java/net/aim_ai/wms/unit/service/DestinationEligibilityServiceUnitTest.java"
TEST_CTL="src/test/java/net/aim_ai/wms/unit/controller/StockUnitControllerUnitTest.java"
MOB_VUE="$MOBILE_ROOT/components/moveStock/scanDestination.vue"
MOB_STORE="$MOBILE_ROOT/store/moveStock.js"
MOB_SPEC="$MOBILE_ROOT/test/components/move-damaged-reason-payload.spec.js"
WEB_VUE="$WEB_ROOT/components/handlingUnits/popups/transferStock.vue"

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}
skip() { printf "  SKIP  %-8s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1)); }

# --- assertion helpers (all fail CLOSED on a missing file) --------------------
file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_exists()       { [ -f "$1" ]; }

file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    [ -f "$file" ] || return 1
    # `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` yields "0\n0" and breaks the
    # arithmetic. Capture unconditionally instead.
    count=$(grep -cE "$pattern" "$file"); [ -n "$count" ] || count=0
    [ "$count" -ge "$n" ]
}

# Match across lines with a TEMPERED gap — (?:(?!FORBID).)*? rather than .*? — so the match
# cannot silently span past the construct it is scoped to. This is the fix for the five rows
# the review showed could pass on a wrong implementation.
# BASELINE DEFECT FOUND AND FIXED (2026-08-18): the first form spliced the patterns straight
# into the perl SOURCE. Perl then parsed `@PostMapping` / `@ExceptionHandler` as ARRAY variables
# and interpolated them to nothing, collapsing the negative lookahead to `(?!)` — which always
# fails, so the tempered gap could never consume a character and the regex could never match.
# Effect: C4 passed VACUOUSLY on the unfixed tree, and C1/C2/C3 would have stayed red even after
# a correct implementation — the "permanently red row is indistinguishable from unimplemented
# work" trap. Patterns now arrive via the environment, where perl treats them as plain strings
# and does no `@`/`$` interpolation.
file_contains_within() {
    local start=$1 forbid=$2 end=$3 file=$4
    [ -f "$file" ] || return 1
    VW_START="$start" VW_FORBID="$forbid" VW_END="$end" \
      perl -0777 -ne 'exit 1 unless /$ENV{VW_START}(?:(?!$ENV{VW_FORBID}).)*?$ENV{VW_END}/s' "$file"
}

# Print the source BETWEEN two anchors. Some assertions are genuinely per-method and cannot be
# expressed as one regex: C3 must say "transferStock's EntityNotFoundException catch does not use
# e.getMessage()", but bulkTransferStock's catch legitimately DOES, and a file-scoped regex
# happily matches the wrong one — which false-RED'd C3 against a CORRECT implementation during
# positive testing. Slice first, then assert on the slice.
method_slice() {
    local start=$1 end=$2 file=$3
    [ -f "$file" ] || return 1
    # /ms — WITHOUT /m an end-anchor starting with ^ matches only at file offset 0, so the slice
    # silently returns empty and every row built on it is permanently red (that made B8
    # unsatisfiable by construction — critic N2).
    #
    # ⚠ DO NOT put a comment between the env assignments and `perl`. A backslash continuation onto
    # a COMMENT line swallows the continuation: the assignments become their own command and perl
    # runs with VW_START/VW_END UNSET, so the regex degenerates to /(.*?)/ , matches empty at
    # offset 0, and EVERY method_slice row (C2, C3, C4, D3) silently goes red against a correct
    # implementation. Cost me a full debugging cycle; found only by positive-testing D3.
    VW_START="$start" VW_END="$end" perl -0777 -ne 'print $1 if /$ENV{VW_START}(.*?)$ENV{VW_END}/ms' "$file"
}

# ITERATION-2 (critic N3): strip comments before grepping. Java tokens present only inside
# `// TODO:` comments satisfied EIGHT B-rows, so an EMPTY STUB of DestinationEligibilityService
# scored identically to a correct implementation. Any row asserting a code construct must read
# CODE, not prose. (T2/T3 were hardened for this in revision 2; the PRODUCTION files were not.)
code_only() {
    [ -f "$1" ] || return 1
    perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"
}
code_contains()     { [ -f "$2" ] || return 1; code_only "$2" | grep -qE "$1"; }
code_not_contains() { [ -f "$2" ] || return 1; ! code_only "$2" | grep -qE "$1"; }

mvn_available() { command -v mvn >/dev/null 2>&1; }
mvn_test_passes() {
    # NOT `-q`: it sets Maven's log level to WARN, and both "BUILD SUCCESS" and Surefire's
    # "Tests run:" summary are INFO — so under -q a PASSING build prints nothing and the row
    # records FAIL. Revision 1 had this bug; every maven row could only ever be red.
    # CRITIC N16: the old form was `grep -qE "BUILD SUCCESS|Tests run:..."` with
    # -DfailIfNoTests=false — so a class with ZERO @Test methods (or no class at all) produced
    # BUILD SUCCESS and scored green. Require Surefire to report at least one test RUN, and require
    # zero failures/errors on that same line.
    mvn test -Dtest="$1" -DfailIfNoTests=false 2>&1 \
      | grep -qE "Tests run: [1-9][0-9]*,.*Failures: 0,.*Errors: 0"
}

# === K — message keys and constants ==========================================
# Bare camelCase keys (the SBDEV-2732 cohort), per plan §5.4.
K_UL='transferStockDestinationUnitloadNotFound'
K_LOC='transferStockDestinationLocationNotFound'
K_USE='transferStockDestinationNotUsable'

check_K1_keys_in_base_bundle() {
    file_contains "^$K_UL=" "$MSG_BASE" && file_contains "^$K_LOC=" "$MSG_BASE" && file_contains "^$K_USE=" "$MSG_BASE"
}
check_K2_keys_in_en_us_bundle() {
    file_contains "^$K_UL=" "$MSG_EN" && file_contains "^$K_LOC=" "$MSG_EN" && file_contains "^$K_USE=" "$MSG_EN"
}
# REVIEW FIX: asserting a key EXISTS is not enough. `…UnitloadNotFound=Container not found.`
# satisfies K1/K2 while failing the entire point of the ticket, which is to NAME the container.
# ITERATION-2 FIX: this checked $MSG_BASE only. With Locale.getDefault()=en_US on every real
# container, messages_en_US.properties is the bundle that actually RENDERS — so the row audited
# the one that does not. Both, now.
check_K3_keys_interpolate_identifier() {
    file_contains "^$K_UL=.*%1" "$MSG_BASE"  && file_contains "^$K_LOC=.*%1" "$MSG_BASE" &&
    file_contains "^$K_USE=.*%1" "$MSG_BASE" &&
    file_contains "^$K_UL=.*%1" "$MSG_EN"    && file_contains "^$K_LOC=.*%1" "$MSG_EN" &&
    file_contains "^$K_USE=.*%1" "$MSG_EN"
}
check_K4_constants_declared() {
    file_contains 'MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND[[:space:]]*=' "$CONST" &&
    file_contains 'MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND[[:space:]]*=' "$CONST" &&
    file_contains 'MSG_TRANSFER_DESTINATION_NOT_USABLE[[:space:]]*=' "$CONST"
}

# === A — Fix A: method parameters raise BusinessException ====================
check_A1a_destination_label_throws_business() {
    file_contains 'new BusinessException\(WmsConstants\.MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND' "$SVC"
}
check_A1b_old_label_entitynotfound_gone() {
    file_not_contains 'EntityNotFoundException\("UnitLoad not found by labelid: "' "$SVC"
}
check_A2a_destination_location_throws_business() {
    file_contains 'new BusinessException\(WmsConstants\.MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND' "$SVC"
}
check_A2b_old_location_entitynotfound_gone() {
    file_not_contains 'EntityNotFoundException\("Location not found by name: " \+ locationName' "$SVC"
}
# REVIEW FIX (was A3): revision 1 grepped the literal "UnitLoadType not found by name: ", which
# survives at :225 and :391 — so blanket-converting :157, the exact failure this row exists to
# catch, still PASSED. Count instead: 34 today; Fix A removes exactly the two parameter-derived
# ones, so >=30 remaining proves the other sites kept their type rather than being swept.
# PARITY PIN, not a Fix row — green before AND after; belongs with P1-P3.
# ITERATION-2 FIX: the threshold was 32 and was OFF BY ONE. Arithmetic: 34 today, Fix A converts
# 2 away (-2), and A4 — added in the same revision — converts the unguarded .get() at :169 INTO an
# EntityNotFoundException (+1). A correct implementation therefore sits at 33, and a >=32 threshold
# silently tolerated exactly one extra blanket conversion. Demonstrated: 34 -> 33 correct -> 32
# with one extra site swept -> still PASSED.
check_A3_internal_lookups_kept_their_type() {
    # ITERATION-2 (critic N4): counted LINES INCLUDING COMMENTS, and §5 Fix A prescribes a comment
    # block containing the literal "EntityNotFoundException" — so a plan-conformant implementer got
    # one free wrong conversion and this still passed. Count code only.
    local n
    n=$(code_only "$SVC" 2>/dev/null | grep -cE 'EntityNotFoundException') || n=0
    [ -n "$n" ] && [ "$n" -ge 33 ]
}
# The 14th site (plan §0.1 row 14).
check_A4_unguarded_optional_get_fixed() {
    # Two prior attempts were wrong and both are recorded because the failure modes differ:
    #  (a) `file_not_contains 'defaultUnitLoadType\.get\(\)'` — a bare negation on ONE spelling;
    #      renaming the local defeated it (critic N15).
    #  (b) `code_contains 'UNIT_LOAD_TYPE_BOX\)\s*\.orElseThrow'` — VACUOUS, that construct
    #      already exists at :225 on the unfixed tree, so the row passed at baseline.
    # Anchor on the actual defect site instead: the createUnitload call at :169 that dereferences
    # the Optional inline. Rename-proof, because the argument POSITION is what is asserted.
    code_not_contains 'createUnitload\(palletLocation,[^;]*\.get\(\)\.getId\(\)' "$SVC"
}

# === B — Fix B: shared, TOTAL destination-eligibility collaborator ===========
check_B1_collaborator_exists()     { file_exists "$ELIG"; }
check_B2_assert_form_declared()    { code_contains 'public void assertCanReceiveStock\(' "$ELIG"; }
check_B3_predicate_form_declared() { code_contains 'public boolean canReceiveStock\(' "$ELIG"; }
# REVIEW FIX (was B3): revision 1 grepped GOING_TO_DELETE file-wide in StockunitService, where it
# already appears at :368/:421/:465/:514 — so a guard OMITTING To-Delete still passed. Scope to
# the collaborator, a new file containing only this rule.
check_B4_allowlist_not_denylist()  { code_contains 'BusinessObjectLockState\.NOT_LOCKED' "$ELIG" && code_not_contains 'BusinessObjectLockState\.QUALITY_FAULT' "$ELIG"; }
check_B5_shipped_branch_present()  { code_contains 'STORAGE_LOCATION_SHIPPED' "$ELIG"; }
check_B6_nirvana_branch_present()  { code_contains 'STORAGE_LOCATION_NIRVANA' "$ELIG"; }
# ON_HOLD was DROPPED (plan §5 Fix B): zero rows tenant-wide, and its claimed precedent guards
# the SOURCE. This row asserts the drop, so silently re-adding it is caught.
check_B7_on_hold_branch_dropped()  { check_B3_predicate_form_declared && code_not_contains 'BusinessObjectLockState\.ON_HOLD' "$ELIG"; }
# Totality contract (plan §5 Fix B / PM-1): the predicate must never throw.
# ITERATION-2 FIX — this row could not see its own primary failure mode. It forbade the literal
# 'orElseThrow' and nothing else, so a predicate using `.get()` with no null guard (PM-1 EXACTLY)
# passed. It also false-RED in the other direction: the forbid pattern `public [a-z]` does not
# match `private`, so a legitimate orElseThrow in a private helper below canReceiveStock tripped it.
#
# A regex cannot carry a totality contract. Slice the predicate body and assert BOTH mechanisms
# named in plan §5 Fix B / PM-1 are handled: no throwing accessor, and an explicit null guard on
# getStoragelocationId() (findById(null) raises InvalidDataAccessApiUsageException). The behavioural
# proof belongs to the two named tests in $TEST_ELIG, required below and run by M2.
check_B8_predicate_is_total() {
    local body
    check_B3_predicate_form_declared || return 1
    # ITERATION-2 (critic N2), two defects: the end-anchor needed /m (fixed in method_slice), and
    # banning `.get()` outright rejected the idiomatic correct form
    # `if (!loc.isPresent()) return false; ... loc.get().getName()`. Ban only the THROWING accessor
    # and require an explicit null guard on the FK.
    # The end-anchor must also match END-OF-CLASS: canReceiveStock is typically the last method,
    # so an anchor of "next member declaration" alone never matches and the slice comes back empty
    # (row permanently red against a CORRECT implementation — found by positive testing).
    # NOTE the non-capturing group. An UNGROUPED alternation binds at TOP LEVEL, splitting the
    # whole regex into /START(.*?)ANCHOR/ or /\z/ — the second matches trivially with $1 EMPTY,
    # so the row read red against a CORRECT implementation. Found only by positive testing.
    body=$(code_only "$ELIG" | VW_START='public boolean canReceiveStock' VW_END='(?:^\s*(?:public|protected|private)\s|\z)' \
             perl -0777 -ne 'print $1 if /$ENV{VW_START}(.*?)$ENV{VW_END}/ms') || return 1
    [ -n "$body" ] || return 1
    printf '%s' "$body" | grep -qE 'orElseThrow' && return 1
    printf '%s' "$body" | grep -qE 'getStoragelocationId\(\)[[:space:]]*==[[:space:]]*null|null[[:space:]]*==[[:space:]]*[A-Za-z]*\.getStoragelocationId\(\)|isPresent\(\)|orElse\(' || return 1
    return 0
}
# The contract itself is behavioural, so require the two tests that actually exercise it.
check_B8b_totality_tests_exist() {
    file_contains 'nullStoragelocation|StoragelocationId_returnsFalse|unresolvableLocation' "$TEST_ELIG"
}
check_B9_predicate_read_only_tx()  { code_contains 'readOnly[[:space:]]*=[[:space:]]*true' "$ELIG"; }
# CRITIC N1 — B12/B13 were WIRED INTO THE RUNNER BUT NEVER DEFINED. bash returned 127, which `run`
# records as an ordinary FAIL, so the script could never reach `0 fail` and §8.7's acceptance target
# was unreachable no matter what anyone implemented. Worse, the sysprop gate and the ungated-Nirvana
# invariant had ZERO working verification: a shadow that GATED the Nirvana refusal — leaving the
# SBDEV-2995 data-loss path open, exactly what B13 exists to forbid — scored identically to correct.
# The definitions were lost when an edit aborted on an assertion before writing; only the `run`
# lines landed. This is the vault's documented "row naming an undefined fn reads as an honest FAIL".
check_B12_eligibility_sysprop_gate() {
    code_contains 'SYSTEM_PROPERTY_TRANSFER_DESTINATION_ELIGIBILITY_ENABLED_KEY' "$CONST" &&
    code_contains 'TRANSFER_DESTINATION_ELIGIBILITY_ENABLED|SYSTEM_PROPERTY_TRANSFER_DESTINATION_ELIGIBILITY_ENABLED_KEY' "$ELIG"
}
# The Nirvana refusal must sit OUTSIDE the gated block (plan §12 Q6). Slice from the assert form's
# signature up to the gate check and require the Nirvana constant to appear BEFORE it.
check_B13_nirvana_guard_ungated() {
    local pre
    check_B2_assert_form_declared || return 1
    pre=$(code_only "$ELIG" | VW_START='public void assertCanReceiveStock' VW_END='TRANSFER_DESTINATION_ELIGIBILITY_ENABLED' \
            perl -0777 -ne 'print $1 if /$ENV{VW_START}(.*?)$ENV{VW_END}/ms') || return 1
    [ -n "$pre" ] || return 1
    printf '%s' "$pre" | grep -qE 'STORAGE_LOCATION_NIRVANA'
}
# ADDED after the 2026-08-19 review (both lanes flagged it independently): the shadow WARN was
# implemented but pinned NOWHERE — not by a test, not by a row. Deleting LOG.warn from the
# non-enforcing branch scored 153/153 targeted, 5170-run parity and 53/53 here. Since plan §5 Fix B
# calls that line "load-bearing rather than a nicety" and §8.1 calls it "the only test of the
# mechanism that retires R3", its absence has to be detectable. Slice assertCanReceiveStock from the
# gate read to the end of the method and require a WARN inside it.
check_B14_shadow_warn_emitted_when_gate_off() {
    # ⚠ FALSE-RED FIXED on first run: this originally sliced from the sysprop constant, assuming the
    # gate is read inline in assertCanReceiveStock. It is read via a private enforcing() helper defined
    # AFTER both entry points, so the slice captured enforcing()'s body (no LOG.warn) and the row read
    # red against a CORRECT implementation. Anchor the METHOD instead, which is what the row is about.
    local body
    body=$(code_only "$ELIG" | VW_START='public void assertCanReceiveStock' VW_END='(?:^\s*(?:public|protected|private)\s|\z)' \
             perl -0777 -ne 'print $1 if /$ENV{VW_START}(.*?)$ENV{VW_END}/ms') || return 1
    [ -n "$body" ] || return 1
    printf '%s' "$body" | grep -qE 'LOG\.warn' || return 1
    printf '%s' "$body" | grep -qE 'SBDEV-2994 shadow'
}
check_B10_guard_invoked_by_service() { code_contains 'assertCanReceiveStock\(' "$SVC"; }
check_B11_probe_uses_predicate()     { code_contains 'canReceiveStock' "$CTL"; }

# === C — Fix C: controller net, operator-safe body, estate-wide logging ======
# REVIEW FIX (was C1): a file-wide count is satisfied by a catch in a DIFFERENT method, or one
# left commented out. Anchor from the transferStock signature, forbidding the next @PostMapping.
check_C1_catch_inside_transferStock() {
    file_contains_within 'public ResponseEntity<Object> transferStock' '@PostMapping' 'catch \(EntityNotFoundException' "$CTL"
}
# ITERATION-2 FIX — C2 was anchored FILE-WIDE while its sibling C3 was hardened with method_slice.
# So bulkTransferStock's catch logging satisfied it while transferStock's did not log at all.
# C1 proved the catch exists in transferStock, C2 proved SOME catch logs, and nothing joined them.
check_C2_catch_logs_error() {
    local body
    body=$(method_slice 'public ResponseEntity<Object> transferStock' 'public ResponseEntity<Object> bulkTransferStock' "$CTL") || return 1
    printf '%s' "$body" | sed -n '/catch (EntityNotFoundException/,$p' | grep -qE 'LOG\.error'
}
# REVIEW FIX (new): the body must NOT leak e.getMessage() to the operator. Two reviewers rated
# this High — the plan classifies these as engineer-only faults, so routing
# "Location not found with id: 3421" to a handheld contradicts its own split rule.
# BASELINE DEFECT FOUND AND FIXED: the first form was `! file_contains_within ...`, which passed
# on the unfixed tree because the catch it inspects does not exist there — a negation over an
# absent construct is vacuously true. Require the catch to EXIST first, then assert it is clean.
# Scoped to transferStock ONLY (slice ends at bulkTransferStock's signature). Requires the catch
# to exist, then asserts the text after it carries no e.getMessage() — i.e. the operator-facing
# body is the fixed support string, not the raw entity/PK text.
check_C3_no_raw_message_in_response() {
    local body
    body=$(method_slice 'public ResponseEntity<Object> transferStock' 'public ResponseEntity<Object> bulkTransferStock' "$CTL") || return 1
    printf '%s' "$body" | grep -qE 'catch \(EntityNotFoundException' || return 1
    # ITERATION-2 (critic N5): the old form forbade only the INLINE spelling, so
    #   String detail = e.getMessage(); errors.add(getErrorMessage("Runtime Error", detail));
    # passed while shipping the exact leak two lanes rated High. Forbid ANY reference to the
    # exception's message inside the catch, not just the inline one.
    ! printf '%s' "$body" \
        | sed -n '/catch (EntityNotFoundException/,$p' \
        | grep -qE 'e\.getMessage|e\.getLocalizedMessage'
}
# REVIEW FIX (new): the one-line estate-wide observability fix Fix C alone does not provide.
# ITERATION-2 FIX — this was a BARE NEGATION, so DELETING the log line entirely satisfied it: the
# correct implementation and a strictly-worse-than-today one were indistinguishable. It also failed
# OPEN on a missing $ADVICE, violating this script's own design rule #1. Now: the handler must
# CONTAIN a warn-or-error call, and must NOT contain a debug one.
check_C4_advice_logs_above_debug() {
    local body
    body=$(method_slice 'handleEntityNotFound' '@ExceptionHandler' "$ADVICE") || return 1
    [ -n "$body" ] || return 1
    printf '%s' "$body" | grep -qE 'LOG\.(warn|error)\(' || return 1
    ! printf '%s' "$body" | grep -qE 'LOG\.debug\('
}

# === W — Fix B, web half ====================================================
check_W1_new_toast_wording()      { file_contains "Container is not available to receive stock" "$WEB_VUE"; }
check_W2_old_toast_wording_gone() { file_not_contains "Container does not exist" "$WEB_VUE"; }

# === D — Fix D: mobile parity ===============================================
check_D1_store_probes_endpoint()   { file_contains 'isUnitLoadIdValid' "$MOB_STORE"; }
check_D2_submit_probes_container() { file_contains 'checkContainer' "$MOB_VUE"; }
# ITERATION-2 FIX — the anchor BACKTRACKED onto the wrong occurrence. `currentMode === 'existing'`
# appears three times in the .vue (showReason at :128, submit()'s if, and the payload object's
# isTransferExistingContainer). Perl matched the third, after which no further `currentMode ===`
# exists, so ANY checkContainer below the payload satisfied the row — i.e. exactly the unscoped
# placement D3 forbids. Slice submit()'s existing-mode block instead, the way C3 slices transferStock.
check_D3_probe_scoped_to_existing_mode() {
    local body
    body=$(method_slice "if \(this\.currentMode === 'existing'\)" "else if \(this\.currentMode === 'new'\)" "$MOB_VUE") || return 1
    [ -n "$body" ] || return 1
    printf '%s' "$body" | grep -qE 'checkContainer'
}
check_D4_submit_is_async() { file_contains 'async submit\(' "$MOB_VUE"; }
# CRITIC N10 — §5 Fix D names two acceptance criteria (the exact toast, and fail-OPEN on a probe
# error) and NEITHER had a row. A shadow shipping fail-CLOSED (`return false` in the catch — the
# precise stockUnits.js:215-218 bug the plan cites) with the toast reduced to 'Invalid container'
# scored identical to a correct implementation.
check_D5_toast_copy_specified() {
    file_contains 'is not available to receive stock' "$MOB_VUE"
}
# Fail-OPEN: the probe's own catch must not return false. Slice checkContainer's body in the store.
check_D6_probe_fails_open() {
    local body
    body=$(code_only "$MOB_STORE" 2>/dev/null | VW_START='checkContainer' VW_END='(?:^\s*async |\z)' \
             perl -0777 -ne 'print $1 if /$ENV{VW_START}(.*?)$ENV{VW_END}/ms') || return 1
    [ -n "$body" ] || return 1
    printf '%s' "$body" | sed -n '/catch/,$p' | grep -qE 'return[[:space:]]+false' && return 1
    return 0
}
# The mobile Jest specs that pin both behaviours must exist (§8.4).
check_D7_mobile_specs_present() {
    [ -f "$MOB_SPEC" ] && grep -qE 'checkContainer' "$MOB_SPEC"
}

# === P — parity pins: already correct, must STAY correct =====================
# REVIEW FIX (was P1): 'getErrorMessage("Entity Not Found"' is exactly what Fix C adds to
# transferStock, so post-fix the row could no longer distinguish bulk's catch from the new one —
# it became unfalsifiable the moment the fix landed. Anchor to bulkTransferStock instead.
check_P1_bulk_catch_retained() {
    file_contains_within 'public ResponseEntity<Object> bulkTransferStock' 'public ResponseEntity<Object> adjust' 'catch \(EntityNotFoundException' "$CTL"
}
check_P2_transactional_annotation_intact() {
    file_contains '@Transactional\(value = "tenantTransactionManager", rollbackFor = \{BusinessException\.class, FacadeException\.class\}\)' "$SVC"
}
check_P3_replen_guard_comment_intact() {
    file_contains 'Intentionally NOT triggering replenishment maintenance' "$SVC"
}

# === T — tests ===============================================================
check_T1_service_test_exists()     { file_exists "$TEST_SVC"; }
check_T2_eligibility_test_exists() { file_exists "$TEST_ELIG"; }
# REVIEW FIX (was T2): revision 1 grepped `getKey()`, which a file containing only
# `/* getKey() */` satisfied. Require an assertion form AND equality — a merely-non-null
# getKey() passes even when the 1-arg ctor set key="placeholder" (plan R13).
check_T3_tests_assert_key_equality() {
    file_contains 'getKey\(\)\)[[:space:]]*\.isEqualTo|assertEquals\([^,]*,[^)]*getKey\(\)' "$TEST_SVC"
}
# REVIEW FIX (was T3): `Properties` && `.load(` passed on two comment lines, and also passed the
# ISO-8859-1 Properties.load(InputStream) form the taxonomy warns against. Require a UTF-8 reader.
check_T4_bundle_test_uses_utf8_reader() {
    file_contains 'InputStreamReader\(' "$TEST_SVC" && file_contains 'UTF_8|UTF-8' "$TEST_SVC"
}
check_T5_controller_test_pins_field_not_type() {
    file_contains 'errors\[0\]\.field' "$TEST_CTL"
}
# REVIEW FIX (new): the ONLY automated proof the advice mapping exists at all. Without
# setControllerAdvice, standaloneSetup does not register RestExceptionHandler and every claim
# about status codes in the controller lane is theatre.
check_T6_controller_advice_registered() { file_contains 'setControllerAdvice' "$TEST_CTL"; }
# REVIEW FIX (new): pin the bulkTransferStock behaviour change Fix A causes. No row in revision 1
# could detect it.
check_T7_bulk_loop_continuation_pinned() {
    file_contains 'continuesLoop|deadLabel_continues|reportsEveryRow' "$TEST_CTL"
}
# REVIEW FIX (new): makes R1 falsifiable rather than prose.
# ADDED 2026-08-19: B14 pins the code shape; this pins that a TEST observes it. Without this a future
# author can satisfy B14 with a log line no assertion reads.
check_T9_shadow_warn_asserted_in_tests() {
    file_contains 'ListAppender' "$TEST_ELIG" && file_contains 'SBDEV-2994 shadow' "$TEST_ELIG"
}
check_T8_log_emission_asserted() { file_contains 'LogCaptor|ListAppender' "$TEST_CTL"; }

# === runner ==================================================================
echo
echo "verify-SBDEV-2994 (rev 2) — Move Stock unknown/retired destination container"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  MOBILE_ROOT=$MOBILE_ROOT"
echo "  WEB_ROOT=$WEB_ROOT"
echo

echo "-- Message keys & constants --"
run K1  "K1  keys in base messages.properties"            check_K1_keys_in_base_bundle
run K2  "K2  keys in messages_en_US.properties"           check_K2_keys_in_en_us_bundle
run K3  "K3  key VALUES interpolate the identifier"       check_K3_keys_interpolate_identifier
run K4  "K4  message-key constants on WmsConstants"       check_K4_constants_declared
echo
echo "-- Fix A: method parameters -> BusinessException --"
run A1a "A1a destination label throws BusinessException"  check_A1a_destination_label_throws_business
run A1b "A1b old label EntityNotFoundException gone"      check_A1b_old_label_entitynotfound_gone
run A2a "A2a destination location throws BusinessException" check_A2a_destination_location_throws_business
run A2b "A2b old location EntityNotFoundException gone"   check_A2b_old_location_entitynotfound_gone
run A3  "A3  [pin] internal lookups KEPT their type (>=33)" check_A3_internal_lookups_kept_their_type
run A4  "A4  unguarded Optional.get() at :169 fixed"      check_A4_unguarded_optional_get_fixed
echo
echo "-- Fix B: shared, total eligibility collaborator --"
run B1  "B1  DestinationEligibilityService exists"        check_B1_collaborator_exists
run B2  "B2  assertCanReceiveStock declared"              check_B2_assert_form_declared
run B3  "B3  canReceiveStock predicate declared"          check_B3_predicate_form_declared
run B4  "B4  ALLOWLIST (NOT_LOCKED), not a denylist"      check_B4_allowlist_not_denylist
run B5  "B5  Shipped branch present"                      check_B5_shipped_branch_present
run B6  "B6  Nirvana branch present"                      check_B6_nirvana_branch_present
run B7  "B7  ON_HOLD branch deliberately absent"          check_B7_on_hold_branch_dropped
run B8  "B8  predicate is TOTAL (no throw + null guard)"  check_B8_predicate_is_total
run B8b "B8b totality tests exist in the test class"      check_B8b_totality_tests_exist
run B9  "B9  predicate is readOnly tx"                    check_B9_predicate_read_only_tx
run B10 "B10 service invokes the assert form"             check_B10_guard_invoked_by_service
run B11 "B11 probe uses the predicate form"               check_B11_probe_uses_predicate
run B12 "B12 eligibility sysprop gate wired"              check_B12_eligibility_sysprop_gate
run B13 "B13 Nirvana refusal is UNGATED (SBDEV-2995)"     check_B13_nirvana_guard_ungated
run B14 "B14 shadow WARN emitted when gate is OFF"        check_B14_shadow_warn_emitted_when_gate_off
echo
echo "-- Fix C: controller net, operator-safe --"
run C1  "C1  catch is INSIDE transferStock"               check_C1_catch_inside_transferStock
run C2  "C2  the catch logs at ERROR"                     check_C2_catch_logs_error
run C3  "C3  body does NOT leak e.getMessage()"           check_C3_no_raw_message_in_response
run C4  "C4  RestExceptionHandler no longer debug-only"   check_C4_advice_logs_above_debug
echo
echo "-- Fix B (web half) --"
run W1  "W1  desktop toast reworded"                      check_W1_new_toast_wording
run W2  "W2  old 'Container does not exist' gone"         check_W2_old_toast_wording_gone
echo
echo "-- Fix D: mobile parity --"
run D1  "D1  store probes isUnitLoadIdValid"              check_D1_store_probes_endpoint
run D2  "D2  submit() probes the container"               check_D2_submit_probes_container
run D3  "D3  probe scoped to 'existing' mode"             check_D3_probe_scoped_to_existing_mode
run D4  "D4  submit() is async"                           check_D4_submit_is_async
run D5  "D5  Fix D toast copy as specified"               check_D5_toast_copy_specified
run D6  "D6  probe fails OPEN, not closed"                check_D6_probe_fails_open
run D7  "D7  mobile spec covers checkContainer"           check_D7_mobile_specs_present
echo
echo "-- Parity pins (green before AND after) --"
run P1  "P1  bulkTransferStock catch retained"            check_P1_bulk_catch_retained
run P2  "P2  tenantTransactionManager + rollbackFor"      check_P2_transactional_annotation_intact
run P3  "P3  SBDEV-2033 replen-recalc guard comment"      check_P3_replen_guard_comment_intact
echo
echo "-- Tests --"
run T1  "T1  service destination test class exists"       check_T1_service_test_exists
run T2  "T2  eligibility test class exists"               check_T2_eligibility_test_exists
run T3  "T3  tests assert getKey() EQUALITY"              check_T3_tests_assert_key_equality
run T4  "T4  bundle test uses a UTF-8 reader"             check_T4_bundle_test_uses_utf8_reader
run T5  "T5  controller test pins errors[0].field"        check_T5_controller_test_pins_field_not_type
run T6  "T6  setControllerAdvice registered"              check_T6_controller_advice_registered
run T7  "T7  bulk loop-continuation pinned"               check_T7_bulk_loop_continuation_pinned
run T8  "T8  log emission asserted (R1 falsifiable)"      check_T8_log_emission_asserted
run T9  "T9  shadow WARN asserted by a test"              check_T9_shadow_warn_asserted_in_tests
echo

# Code-shape greps prove a call exists; these prove it works.
# NOTE: `mvn test` MUTATES the tracked archunit_store — revert it before committing.
# Two suites fail on clean develop; compare against that baseline, not against zero.
if [ "${RUN_MVN:-0}" = "1" ]; then
    if mvn_available; then
        echo "-- Targeted maven runs --"
        run M1 "M1  StockunitServiceTransferStockDestinationTest" mvn_test_passes StockunitServiceTransferStockDestinationTest
        run M2 "M2  DestinationEligibilityServiceUnitTest"        mvn_test_passes DestinationEligibilityServiceUnitTest
        run M3 "M3  StockUnitControllerUnitTest"                  mvn_test_passes StockUnitControllerUnitTest
        run M4 "M4  StockunitServiceTransferStockGuardTest"       mvn_test_passes StockunitServiceTransferStockGuardTest
        # REVIEW FIX: revision 1 never ran this class — the one Fix B is most likely to break.
        run M5 "M5  StockunitServiceUnitTest (Fix B regressions)" mvn_test_passes StockunitServiceUnitTest
        echo
    else
        # Without this guard bash's 127 records as a plain FAIL, making a missing maven
        # indistinguishable from failing tests.
        skip M1-M5 "M1-M5 targeted maven runs" "mvn not on PATH"
    fi
else
    skip M1-M5 "M1-M5 targeted maven runs" "set RUN_MVN=1 to enable"
fi

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
