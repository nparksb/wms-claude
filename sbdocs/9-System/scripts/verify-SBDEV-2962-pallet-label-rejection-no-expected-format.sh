#!/usr/bin/env bash
# verify-SBDEV-2962-pallet-label-rejection-no-expected-format.sh
#
# Acceptance for: sbdocs/1-Projects/wms2/plan/SBDEV-2962-pallet-label-rejection-no-expected-format.md
#
# Usage
#   PROJECT_ROOT=/path/to/v2/wms2-api bash sbdocs/9-System/scripts/verify-SBDEV-2962-....sh
#
# Run TWICE, and at least once WITHOUT SKIP_MVN:
#   1. BEFORE any change — capture the FAIL baseline. A script that cannot fail proves nothing.
#   2. AFTER  — require "Result: N pass, 0 fail". Paste that line into the completion report.
#
# HARDENING CARRIED OVER FROM SBDEV-2961 — every one of these was a real false green there:
#   * `mvn test -q` suppresses BOTH "BUILD SUCCESS" and "Tests run:" (INFO) -> row permanently red on a
#     green build. Never use -q here.
#   * `-o` on every mvn call: two concurrent runs sharing ~/.m2 turn ALL Maven rows red at once, which
#     reads as a defect. ALL-M-ROWS-RED IS A COLLISION SIGNATURE — re-run serially before believing it.
#   * `! grep -qE p f` fails OPEN on a missing file (grep exits 2, `!` flips it to PASS). Guarded.
#   * Counting without stripping comments lets a Javadoc mentioning the symbol satisfy the row.
#   * `grep -cE ... || echo 0` yields count="0\n0" -> integer error -> bogus FAIL.
#
# FOUND WHILE BASELINING *THIS* SCRIPT (all four were real, all four found by RUNNING it, not reading it):
#   * A row naming TWO Maven classes passes when only ONE exists and is green — the sibling fills the count.
#     One class per row. (This one false-GREENED on the unfixed build.)
#   * `mvn` is not on the default PATH here (SDKMAN). Every Maven row exited 127 and `run` logged it as an
#     ordinary FAIL — a false RED that is un-greenable and indistinguishable from a broken build. Now the
#     script resolves the toolchain itself and SKIPs with a loud reason if it still can't.
#   * A file-level `catch (RuntimeException)` row is satisfied by a guard in a DIFFERENT method of the same
#     file -> use method_body_contains.
#   * A `describeExpectedFormat` symbol census is satisfied by a call that never reaches the exception's
#     argument list -> use stmt_matches_exactly_across with a tempered `[^;]*` gap.
#
# NOTE: `mvn test` MUTATES the tracked archunit_store — revert it before staging.
# NOTE: point PROJECT_ROOT at the per-ticket worktree, or this grades the main checkout.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

# --- toolchain: mvn is NOT on the default PATH on this box (SDKMAN-managed) --------------------------
# Without this, every Maven row exits 127 (command not found) and `run` records it as an ordinary FAIL —
# indistinguishable from a real build failure, and un-greenable no matter how correct the code is. Same
# failure family as an undefined check function scoring 127. Resolve it here, and if it still cannot be
# found, SKIP the Maven rows loudly instead of failing them.
if ! command -v mvn >/dev/null 2>&1; then
    for c in "$HOME/.sdkman/candidates/maven/current/bin" "$HOME/.sdkman/candidates/java/current/bin"; do
        [ -d "$c" ] && PATH="$c:$PATH"
    done
    export PATH
fi
HAVE_MVN=0
command -v mvn >/dev/null 2>&1 && HAVE_MVN=1

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

# --- helpers: all fail CLOSED on a missing file ------------------------------
file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
# Negative rows over CODE only. A comment mentioning the forbidden symbol is not a use of it — a Javadoc
# reading "there is no getParameter() on this class" broke T_no_getparameter at the gate. This is the mirror
# of the SBDEV-2961 lesson where a comment SATISFIED a positive row.
code_not_contains()  {
    [ -f "$2" ] || return 1
    ! grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" | grep -qE "$1"
}

# Counts on CODE lines only — comment-only lines stripped first, so a Javadoc mentioning the symbol
# cannot satisfy a count row.
count_code_matches() {
    local pattern=$1 file=$2
    [ -f "$file" ] || return 1
    grep -vE '^[[:space:]]*(//|\*|/\*)' "$file" | grep -cE "$pattern"
}
code_matches_exactly() {
    local pattern=$1 file=$2 n=$3 c
    c=$(count_code_matches "$pattern" "$file") || return 1
    [ "${c:-0}" -eq "$n" ]
}
# Same, summed across several files — the six throwers live in three files.
code_matches_exactly_across() {
    local pattern=$1 n=$2; shift 2
    local total=0 f c
    for f in "$@"; do
        [ -f "$f" ] || return 1
        c=$(grep -vE '^[[:space:]]*(//|\*|/\*)' "$f" | grep -cE "$pattern")
        total=$((total + ${c:-0}))
    done
    [ "$total" -eq "$n" ]
}
# Same, but the pattern may span lines WITHIN ONE STATEMENT. The gap is tempered — [^;]* cannot cross a
# statement boundary — so this asserts "in the same statement", not merely "somewhere in the file". An
# unbounded .*? under /s would match a correct construct elsewhere and false-green (SBDEV-2961 lesson 4).
stmt_matches_exactly_across() {
    local pattern=$1 n=$2; shift 2
    local total=0 f c
    for f in "$@"; do
        [ -f "$f" ] || return 1
        c=$(perl -0777 -ne "my \$c = 0; \$c++ while /$pattern/g; print \$c" "$f") || return 1
        total=$((total + ${c:-0}))
    done
    [ "$total" -eq "$n" ]
}
# Extract ONE method body by brace-matching from its signature, so a row cannot be satisfied by a construct
# living in a DIFFERENT method of the same file.
method_body_contains() {
    local sig=$1 pattern=$2 file=$3
    [ -f "$file" ] || return 1
    MB_SIG="$sig" MB_PAT="$pattern" perl -0777 -ne '
        my ($sig, $pat) = ($ENV{MB_SIG}, $ENV{MB_PAT});
        exit 1 unless /\Q$sig\E/;
        my $i = index($_, "{", $+[0]);
        exit 1 if $i < 0;
        my ($depth, $j) = (0, $i);
        while ($j < length) {
            my $ch = substr($_, $j, 1);
            $depth++ if $ch eq "{";
            if ($ch eq "}") { $depth--; last if $depth == 0; }
            $j++;
        }
        exit 1 if $depth != 0;
        exit(substr($_, $i, $j - $i + 1) =~ /$pat/ ? 0 : 1);
    ' "$file"
}
mvn_test_passes() {
    local out
    out=$(mvn -o test -Dtest="$1" -Dsurefire.failIfNoSpecifiedTests=false 2>&1)
    printf '%s\n' "$out" | grep -qE "BUILD SUCCESS" || return 1
    printf '%s\n' "$out" | grep -qE "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0, Skipped: 0"
}
mvn_test_compile_passes() { mvn -o clean test-compile 2>&1 | grep -qE "BUILD SUCCESS"; }

# --- targets ----------------------------------------------------------------
BUNDLE=src/main/resources/messages_en_US.properties
CONV=src/main/java/net/aim_ai/wms/util/StringConverter.java
PALLET=src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizingService.java
TRUCK=src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java
MOVE=src/main/java/net/aim_ai/wms/service/mobile/MobileMoveStockService.java
T_CONV=src/test/java/net/aim_ai/wms/unit/util/StringConverterUnitTest.java
# ⚠ BusinessExceptionUnitTest, not a new BusinessExceptionMessageUnitTest — the class already exists.
T_MSG=src/test/java/net/aim_ai/wms/unit/exceptions/BusinessExceptionUnitTest.java
T_PALLET=src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePalletizingServiceTest.java
T_PALLET_FMT=src/test/java/net/aim_ai/wms/unit/service/mobile/MobilePalletizingScanPalletFormatTest.java
T_MOVE=src/test/java/net/aim_ai/wms/unit/service/mobile/MobileMoveStockServiceTest.java
T_TRUCK=src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingServiceTest.java

# === Fix A — the message gains an expected-format slot =======================
check_A_format_slot()    { file_contains 'noValidString=.*%2\$s' "$BUNDLE"; }
check_A_positional()     { file_contains 'noValidString=.*%1\$s' "$BUNDLE"; }
# The old form was `'%1s'` with no second slot. Its absence proves the line was actually edited.
check_A_old_form_gone()  { file_not_contains "noValidString=String is not valid: '%1s'$" "$BUNDLE"; }
# The three rows above all pass on `noValidString=%1$s %2$s`, which drops the entire deliverable. The PROSE
# is the fix — pin it. (Reported by the critic lane; the A rows were structural only.)
check_A_prose()          { file_contains 'noValidString=.*Expected format: %2\$s' "$BUNDLE"; }

# === Fix B — the describing helper ==========================================
check_B_helper()         { file_contains 'public static String describeExpectedFormat' "$CONV"; }
# It runs while building an error message, so it must never propagate a bad-sysprop exception.
# SCOPED TO THE HELPER BODY, not the file: §8.3 invites hardening convertFormatToRegex with its own
# catch (RuntimeException), which would green a file-level row while the new helper stayed UNGUARDED.
check_B_guarded()        { method_body_contains 'String describeExpectedFormat' \
                              'catch\s*\(\s*RuntimeException' "$CONV"; }
# Locale.ROOT, not the default FORMAT locale — ar-EG et al. render non-ASCII digits.
check_B_locale_root()    { method_body_contains 'String describeExpectedFormat' \
                              'String\.format\(\s*Locale\.ROOT' "$CONV"; }
# A large width ALLOCATES rather than throwing, so catch(RuntimeException) cannot bound the output; and an
# Integer.MAX_VALUE width raises OutOfMemoryError (an Error), which no catch can contain at all.
#
# ⚠ CHAIN-LEVEL ON PURPOSE. An earlier revision asserted `MAX_EXAMPLE_LENGTH` inside describeExpectedFormat's
# own body. Extracting the bounding into a truncate() helper — behaviour-preserving — turned this row RED in
# the very run that proved the bounding worked. That is the documented "verify rows go stale when a refactor
# moves code" trap, and "behaviour-preserving" is exactly what makes it easy to wave away. So assert the LINKS:
# the constant exists, the helper delegates, and the delegate does the bounding.
check_B_bounds_example() {
    file_contains 'MAX_EXAMPLE_LENGTH[[:space:]]*=' "$CONV" || return 1
    method_body_contains 'String describeExpectedFormat' 'truncate\(' "$CONV" || return 1
    method_body_contains 'String truncate' 'MAX_EXAMPLE_LENGTH' "$CONV" || return 1
    method_body_contains 'String truncate' 'substring' "$CONV"
}
# The heap screen must run on the PATTERN, before String.format — truncating cannot help when PRODUCING the
# value is what fails.
check_B_width_screen()   { method_body_contains 'String describeExpectedFormat' \
                              'hasOversizedWidth\(' "$CONV"; }
# Varargs: the accept condition is TWO OR'd regexes at 3 of the 6 sites (H2).
check_B_varargs()        { file_contains 'describeExpectedFormat\(String printingPattern, String\.\.\.' "$CONV"; }

# === Fix C — all SIX sites, counted ========================================
# The count IS the assertion. Five updated sites plus one missed one is WORSE than shipping nothing:
# the message would reference %2$s, String.format would raise MissingFormatArgumentException, and the
# guard at BusinessException:100 degrades the text to `noValidString, 'TEST1'` for that caller.
check_C_six_throws()     { code_matches_exactly_across 'BusinessException\("noValidString"' 6 "$PALLET" "$TRUCK" "$MOVE"; }
# A SYMBOL CENSUS, not a structural assertion — six calls assigned to unused locals, passed to the wrong
# exception, or sitting in LOG.debug all satisfy it. Kept for the per-file triangulation below; the real
# structural claim is check_C_six_wired.
check_C_six_described()  { code_matches_exactly_across 'describeExpectedFormat' 6 "$PALLET" "$TRUCK" "$MOVE"; }
# THIS is "the count IS the assertion": the helper call must sit inside the noValidString throw's own
# argument list. [^;]* is a tempered gap — it cannot cross a statement boundary, so this cannot be satisfied
# by a describeExpectedFormat call elsewhere in the file.
check_C_six_wired()      { stmt_matches_exactly_across 'BusinessException\("noValidString"[^;]*describeExpectedFormat' \
                              6 "$PALLET" "$TRUCK" "$MOVE"; }
# H2: the three two-regex sites must pass the SECOND accept pattern too, or the message shows an example
# that does not match the pattern printed beside it.
check_C_both_patterns()  { stmt_matches_exactly_across 'describeExpectedFormat\([^;]*convertedPrintingPattern' \
                              3 "$PALLET" "$TRUCK"; }
check_C_pallet_four()    { code_matches_exactly 'describeExpectedFormat' "$PALLET" 4; }
check_C_truck_one()      { code_matches_exactly 'describeExpectedFormat' "$TRUCK" 1; }
check_C_move_one()       { code_matches_exactly 'describeExpectedFormat' "$MOVE" 1; }
# MoveStock validates a DESTINATION against STRING_PATTERN_SEPARATE_STOCK and has no printing pattern.
# Passing null proves it did not inherit the pallet format — the whole reason the format is an argument.
check_C_move_null_first(){ file_contains 'describeExpectedFormat\([[:space:]]*null' "$MOVE"; }

# === Tests ==================================================================
# NOTE: this class ALREADY EXISTS (4 tests in @Nested ConvertFormatToRegex), so this row is a
# must-not-regress guard, not a work item — it is green at baseline. The real gate is
# T_conv_malformed below, which names a test that does not exist yet.
check_T_conv_exists()    { [ -f "$T_CONV" ]; }
# The load-bearing case: a malformed sysprop must degrade, not throw, inside an error path.
check_T_conv_malformed() { file_contains 'shouldNotThrow_whenPrintingPatternIsMalformed' "$T_CONV"; }
# H2 regression guard, and the two hazards catch(RuntimeException) cannot cover.
check_T_conv_both_pat()  { file_contains 'shouldReturnExampleAndBothPatterns' "$T_CONV"; }
# Both halves of the bounding story, by name: the render-then-truncate path AND the pre-screen that stops an
# OutOfMemoryError no catch could contain. Plus the guard that the screen does not over-reject a real pattern.
check_T_conv_bounds()    { file_contains 'shouldTruncate_whenExampleExceedsTheBound' "$T_CONV" \
                            && file_contains 'shouldSkipExample_whenWidthCouldExhaustHeap' "$T_CONV" \
                            && file_contains 'shouldStillRenderRealPatterns_whenWidthIsSmall' "$T_CONV"; }
check_T_conv_locale()    { file_contains 'shouldRenderAsciiDigits_regardlessOfDefaultLocale' "$T_CONV"; }
# ⚠ BusinessExceptionUnitTest ALREADY EXISTS — an earlier revision specced a new
# BusinessExceptionMessageUnitTest beside it. This row is therefore a guard; the discriminator is the new
# method name below plus M_unit_msg going red if that method's assertions fail.
check_T_msg_exists()     { [ -f "$T_MSG" ]; }
check_T_msg_renders()    { file_contains 'noValidString".*"TEST1"' "$T_MSG"; }
# Assert the RENDERED text via getLocalizedMessage(Locale.US): getMessage() uses Locale.getDefault(), which
# resolves the 14-key PARENT bundle on a non-en_US JVM and fails on correct code (§8.2).
check_T_msg_locale_us()  { file_contains 'getLocalizedMessage\(Locale\.US\)' "$T_MSG"; }
# Pins the §2.3 degradation: one-argument construction must fall back, not blow up.
check_T_msg_degrades()   { file_contains 'shouldDegradeToKeyAndParameters_whenOnlyOneArgumentGiven' "$T_MSG"; }
# getParameter() DOES NOT EXIST on BusinessException (§8.1). A test CALLING it cannot compile — catch it here
# rather than at the TDD gate's first mvn run. CODE-only: a Javadoc explaining the absence is not a call.
check_T_no_getparameter(){ code_not_contains 'getParameter\(\)' "$T_MSG"; }
# New sibling class, so a Maven row can gate it (MobilePalletizingServiceTest cannot — 1 pre-existing fail).
check_T_pallet_exists()  { [ -f "$T_PALLET_FMT" ]; }
check_T_pallet_format()  { file_contains 'shouldIncludeExpectedFormat' "$T_PALLET_FMT"; }
check_T_pallet_both()    { file_contains 'shouldNameBothAcceptPatterns' "$T_PALLET_FMT"; }
# C6 — the site whose pattern divergence justifies the entire per-call-site design, previously covered by a
# single manual row. ⚠ Corrected AT THE GATE: this lives in the EXISTING MobileMoveStockServiceTest, not a new
# MobileMoveStockFormatTest — the existing class is green on develop, so it can back a Maven row directly.
# Fourth "already exists" correction in this plan.
check_T_move_own_pat()   { file_contains 'selectDestination_shouldNameItsOwnPattern_whenDestinationMatchesNothing' "$T_MOVE"; }
# C5 — the truck-loading assertion lives in the existing (green) MobileTruckLoadingServiceTest.
check_T_truck_format()   { file_contains 'checkPallet_shouldIncludeExpectedFormat_whenLabelMatchesNoPattern' "$T_TRUCK"; }
# Landmine: BusinessException resolves its message eagerly, so hasMessageContaining("noValidString")
# FAILS on a correct implementation. Assert getKey()/getParameter() instead.
check_T_no_key_in_msg()  { file_not_contains 'hasMessageContaining\("noValidString"\)' "$T_PALLET"; }
# THE SWAP DETECTOR. Every other assertion is an unordered contains(), and a swapped (label, format) pair
# renders "String is not valid: '<format>'. Expected format: <label>" which satisfies contains(label) AND
# contains(format) AND the C_six_wired structural row. Ordered substrings are the only thing that catches it.
# Ablation-proven: swapping C2's two arguments turns MobilePalletizingScanPalletFormatTest red.
check_T_arg_order()      {
    file_contains "contains\(\"'TEST1'\. Expected format:\"\)" "$T_PALLET_FMT" || return 1
    file_contains "contains\(\"'TEST1'\. Expected format:\"\)" "$T_TRUCK" || return 1
    file_contains "contains\(\"'BADDEST'\. Expected format:\"\)" "$T_MOVE" || return 1
    file_contains 'isEqualTo\("String is not valid: .TEST1.\. Expected format: ' "$T_MSG"
}

# === Runner =================================================================
echo
echo "verify-SBDEV-2962 — pallet-label rejection must state the expected format"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "Fix A — message"
run A_format_slot      "A message has a %2\$s expected-format slot"  check_A_format_slot
run A_positional       "A message uses positional %1\$s"             check_A_positional
run A_old_form_gone    "A old single-slot message is gone"           check_A_old_form_gone
run A_prose            "A message actually says 'Expected format:'"  check_A_prose
echo
echo "Fix B — helper (guard rows scoped to the helper BODY, not the file)"
run B_helper           "B StringConverter.describeExpectedFormat"    check_B_helper
run B_varargs          "B takes varargs accept patterns"             check_B_varargs
run B_guarded          "B helper body catches RuntimeException"      check_B_guarded
run B_locale_root      "B formats with Locale.ROOT"                  check_B_locale_root
run B_bounds_example   "B bounds the example (constant->truncate chain)" check_B_bounds_example
run B_width_screen     "B screens oversized widths pre-format"        check_B_width_screen
echo
echo "Fix C — all six call sites (C_six_wired is the structural assertion)"
run C_six_throws       "C still exactly 6 noValidString throws"      check_C_six_throws
run C_six_described    "C 6 describeExpectedFormat symbols (census)" check_C_six_described
run C_six_wired        "C all 6 wired INTO the throw's arguments"    check_C_six_wired
run C_both_patterns    "C the 3 two-regex sites pass BOTH patterns"  check_C_both_patterns
run C_pallet_four      "C  palletizing: 4 of them"                   check_C_pallet_four
run C_truck_one        "C  truck loading: 1"                         check_C_truck_one
run C_move_one         "C  move stock: 1"                            check_C_move_one
run C_move_null_first  "C  move stock passes null printing pattern"  check_C_move_null_first
echo
echo "Tests"
run T_conv_exists      "T StringConverterUnitTest present (guard)"   check_T_conv_exists
run T_conv_malformed   "T covers malformed-pattern non-throw"        check_T_conv_malformed
run T_conv_both_pat    "T covers the both-accept-patterns case"      check_T_conv_both_pat
run T_conv_bounds      "T covers the huge-width allocation"          check_T_conv_bounds
run T_conv_locale      "T covers non-en_US default locale"           check_T_conv_locale
run T_msg_exists       "T BusinessExceptionUnitTest present (guard)" check_T_msg_exists
run T_msg_renders      "T constructs noValidString with 2 args"      check_T_msg_renders
run T_msg_locale_us    "T renders via getLocalizedMessage(Locale.US)" check_T_msg_locale_us
run T_msg_degrades     "T pins the one-argument degradation"         check_T_msg_degrades
run T_no_getparameter  "T does NOT call the absent getParameter()"   check_T_no_getparameter
run T_pallet_exists    "T new palletizing format test class"        check_T_pallet_exists
run T_pallet_format    "T palletizing asserts the format is passed"  check_T_pallet_format
run T_pallet_both      "T palletizing asserts BOTH accept patterns"  check_T_pallet_both
run T_move_own_pat     "T move stock asserts its OWN pattern"        check_T_move_own_pat
run T_truck_format     "T truck loading asserts the format is passed" check_T_truck_format
run T_no_key_in_msg    "T does NOT assert on the raw key in message" check_T_no_key_in_msg
run T_arg_order        "T pins ARGUMENT ORDER at every site"         check_T_arg_order
echo
echo "Maven (SKIP_MVN=1 to skip — but run WITHOUT it at least once)"
if [ "${SKIP_MVN:-0}" = "1" ] || [ "$HAVE_MVN" = "0" ]; then
    MVN_SKIP_WHY="SKIP_MVN=1"
    [ "$HAVE_MVN" = "0" ] && MVN_SKIP_WHY="mvn NOT FOUND — export the SDKMAN PATH and re-run; these rows are UNPROVEN, not passing"
    skip M_test_compile "mvn -o clean test-compile"        "$MVN_SKIP_WHY"
    skip M_unit_conv    "StringConverterUnitTest green"     "$MVN_SKIP_WHY"
    skip M_unit_msg     "BusinessExceptionUnitTest green"   "$MVN_SKIP_WHY"
    skip M_unit_pallet  "MobilePalletizingScanPalletFormatTest green" "$MVN_SKIP_WHY"
    skip M_unit_move    "MobileMoveStockServiceTest green"  "$MVN_SKIP_WHY"
    skip M_unit_truck   "MobileTruckLoadingServiceTest green" "$MVN_SKIP_WHY"
else
    run M_test_compile "mvn -o clean test-compile"         mvn_test_compile_passes
    # ONE CLASS PER ROW, deliberately. Specifying two classes together let the pre-existing
    # StringConverterUnitTest (4 green tests) satisfy the "Tests run: [1-9]... Failures: 0" check while the
    # other class did not exist at all — the row passed on the unfixed build and proved nothing. Caught by
    # running it. Per-class rows cannot be filled in by a sibling.
    run M_unit_conv    "StringConverterUnitTest green"      mvn_test_passes StringConverterUnitTest
    run M_unit_msg     "BusinessExceptionUnitTest green"    mvn_test_passes BusinessExceptionUnitTest
    run M_unit_pallet  "MobilePalletizingScanPalletFormatTest green" mvn_test_passes MobilePalletizingScanPalletFormatTest
    run M_unit_move    "MobileMoveStockServiceTest green"   mvn_test_passes MobileMoveStockServiceTest
    # ALREADY an executing gate for C5: testCheckPalletWithInvalidPattern asserts the message contains
    # "String is not valid", which survives Fix A only if Fix C is applied at that site (a one-argument
    # construction degrades to `noValidString, 'INVALID123'`). No pre-existing failures in this class.
    run M_unit_truck   "MobileTruckLoadingServiceTest green" mvn_test_passes MobileTruckLoadingServiceTest
fi
echo
# NOT asserted here, deliberately:
#  - MobilePalletizingServiceTest is NOT run as a gate row: it has ONE pre-existing failing method on
#    clean develop (testScanParcelBulkPalletAlreadyAssignedToGate), so the class can never report
#    "Failures: 0". Check its failing-method set by hand per plan §5.2 step 8.
skip M_pallet_class "MobilePalletizingServiceTest as a gate row" "1 pre-existing failure on develop — verify the method set by hand"

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
