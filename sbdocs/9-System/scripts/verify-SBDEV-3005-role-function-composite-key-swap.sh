#!/usr/bin/env bash
# verify-SBDEV-3005-role-function-composite-key-swap.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-3005-role-function-composite-key-swap.md
#
#   $ PROJECT_ROOT=/path/to/v2/wms2-api \
#       bash sbdocs/9-System/scripts/verify-SBDEV-3005-role-function-composite-key-swap.sh
#
# Exit 0 only when every check passes. Paste the final "Result:" line into the
# completion report — a prose "DONE" is not acceptance.
#
# Run it BEFORE the first code change to capture the FAIL baseline. A verify
# script that has never been seen red has not been tested.
#
# The M rows shell out to maven, so JAVA_HOME and PATH must reach a JDK 21 + maven:
#   export JAVA_HOME=~/.sdkman/candidates/java/21.0.11-ms
#   export PATH="$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH"
# Set SKIP_MVN=1 to skip them for a fast code-shape-only pass.
#
# NOTE ON SCOPE: /rest/util/initDB is DEAD CODE (confirmed by the requester
# 2026-08-19, slated for deletion). Its 138 addFunctionToRole call sites are
# deliberately NOT asserted here. Do not add rows for them.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-8s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-8s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-8s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# --- assertion helpers -------------------------------------------------------
# Every helper fails CLOSED on a missing file. `file_not_contains` and the perl
# helpers would otherwise report PASS for a file that does not exist, which
# false-greens every assertion about a file a refactor moved or renamed.

file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

# Multi-line (whole-file) regex match. Perl exits 0 when it cannot open the
# file, so the -f guard is mandatory, not defensive.
file_contains_ml() {
    [ -f "$2" ] || return 1
    perl -0777 -ne "exit(/$1/s ? 0 : 1)" "$2"
}
file_not_contains_ml() {
    [ -f "$2" ] || return 1
    perl -0777 -ne "exit(/$1/s ? 1 : 0)" "$2"
}

# Tree-scoped grep — refactor-proof: asserts a construct's presence/absence
# anywhere under src/main, so the row survives code moving between files.
tree_contains()     { grep -rqE "$1" src/main/java; }
tree_not_contains() { ! grep -rqE "$1" src/main/java; }

# NOTE — the verify-plan-template version of this helper is BROKEN and reports FAIL on a
# passing run. It pipes `mvn -q` into `grep -qE "BUILD SUCCESS|Tests run..."`, but `-q`
# suppresses INFO output, so neither string is ever emitted: maven exits 0 while the grep
# finds nothing. Confirmed here (exit 0, 1223 bytes of output, zero matches for either
# pattern). Use the EXIT CODE as the signal, and additionally require a real surefire
# summary so a run that silently executed no tests cannot pass.
mvn_test_passes() {
    local out rc count
    out=$(mvn test -Dtest="$1" -DfailIfNoTests=false -Djacoco.skip=true 2>&1); rc=$?
    [ "$rc" -eq 0 ] || return 1
    # Require Skipped: 0 AND a minimum test count. Both holes were measured:
    #  * a class-level @Disabled reports "Tests run: 1, Failures: 0, Errors: 0, Skipped: 1" with
    #    exit 0, so without the Skipped check a disabled class certifies itself green;
    #  * every test here lives in an @Nested class, so surefire also emits
    #    "Tests run: 0, Failures: 0, Errors: 0" for the OUTER class — which alone satisfied a
    #    bare "[0-9]+" pattern, meaning deleting the @Nested classes would still pass.
    count=$(printf '%s' "$out" \
        | grep -oE "Tests run: [0-9]+, Failures: 0, Errors: 0, Skipped: 0" \
        | grep -oE "[0-9]+" | sort -rn | head -1)
    [ -n "$count" ] && [ "$count" -ge "${2:-1}" ]
}

ID_SRC=src/main/java/net/aim_ai/wms/model/UserRoleUserFunctionId.java
CTRL=src/main/java/net/aim_ai/wms/controller/UserRoleController.java
ADMIN=src/main/java/net/aim_ai/wms/controller/AdminController.java
UFS=src/main/java/net/aim_ai/wms/service/UserFunctionService.java
ACC=src/main/java/net/aim_ai/wms/service/AccessService.java
URS=src/main/java/net/aim_ai/wms/service/UserRoleService.java
UGS=src/main/java/net/aim_ai/wms/service/UserGroupService.java
UCTRL=src/main/java/net/aim_ai/wms/controller/UserController.java
UGCTRL=src/main/java/net/aim_ai/wms/controller/UserGroupController.java
T_CTRL=src/test/java/net/aim_ai/wms/unit/controller/UserRoleControllerUnitTest.java
T_URS=src/test/java/net/aim_ai/wms/unit/service/UserRoleServiceUnitTest.java
T_UFS=src/test/java/net/aim_ai/wms/unit/service/UserFunctionServiceUnitTest.java
T_ACC=src/test/java/net/aim_ai/wms/unit/service/AccessServiceUnitTest.java
T_TXB=src/test/java/net/aim_ai/wms/unit/service/UserRoleServiceTransactionBoundaryTest.java

# === R — the record's contract is unchanged (AC-9) ============================
# The fix is "callers conform to the record", NOT "flip the record". If someone
# reorders the components instead, R1 goes red and every other row would have
# gone falsely green.
check_R1_record_order_unchanged() {
    file_contains_ml \
      '@Column\(name = "rolelist_id".{0,120}?Long rolelistId,.{0,200}?@Column\(name = "functionlist_id".{0,120}?Long functionlistId' \
      "$ID_SRC"
}

# === A — no reversed construction survives anywhere (AC-1) ===================
# Tree-scoped on purpose: whether the construction lives in the controller or
# has moved into UserRoleService (plan Fix D), the invariant is the same.
check_A1_correct_order_exists() {
    tree_contains 'new UserRoleUserFunctionId\(\s*roleId\s*,\s*functionId\s*\)'
}
check_A2_no_reversed_bare() {
    tree_not_contains 'new UserRoleUserFunctionId\(\s*functionId\s*,\s*roleId\s*\)'
}
# A1 alone is weak: a COMMENT containing the correct construction satisfies it, and
# once Fix D moves the construction into UserRoleService, A2/A3 are absence-only and
# go vacuously green if the lambda parameter is renamed. A4 pins the real site.
check_A4_construction_inside_the_method() {
    file_contains_ml 'replaceRoleFunctions(?:(?!\bpublic\b).)*?new UserRoleUserFunctionId\(\s*roleId\s*,' "$URS"
}
check_A3_no_reversed_boxed() {
    tree_not_contains 'new UserRoleUserFunctionId\(\s*Long\.valueOf\(functionId\)\s*,\s*Long\.valueOf\(roleId\)\s*\)'
}

# === B — UserFunctionService.addRoleToFunction (AC-2, AC-4) ==================
check_B1_service_correct_order() {
    file_contains 'new UserRoleUserFunctionId\(\s*roleId\s*,\s*functionId\s*\)' "$UFS"
}
check_B2_service_no_reversed() {
    file_not_contains 'new UserRoleUserFunctionId\(\s*functionId\s*,\s*roleId\s*\)' "$UFS"
}
# The guard at :49 reads (roleId, functionId) and must keep doing so — after the
# fix the read and the write finally describe the same row (idempotency).
check_B3_guard_orientation_intact() {
    file_contains 'findByRolelistIdAndFunctionlistId\(\s*roleId\s*,\s*functionId\s*\)' "$UFS"
}

# === C — AccessService.addFunctionToGroup, the paired change (AC-3) ==========
# LANDMINE: this call site was reversed too, cancelling B's bug. Fixing B alone
# silently breaks addFunctionToGroup. C1 red + B1 green == the bug just moved.
# Method-scoped, NOT file-scoped: addFunctionToUser at :102 already has the
# correct shape, so a file-wide grep for it passes on the BROKEN code and proves
# nothing about :146. The tempered gap stops at the next method declaration.
check_C1_group_call_unreversed() {
    file_contains_ml \
      'addFunctionToGroup\((?:(?!\bpublic\b).)*?addRoleToFunction\(\s*connector_role\.getId\(\)\s*,\s*function\.getId\(\)\s*\)' \
      "$ACC"
}
check_C2_no_reversed_group_call() {
    file_not_contains 'addRoleToFunction\(\s*function\.getId\(\)\s*,\s*connector_role\.getId\(\)\s*\)' "$ACC"
}
# addFunctionToUser at :102 was already correct — it must stay that way.
check_C3_user_call_still_correct() {
    file_contains_n_times 'addRoleToFunction\(\s*connector_role\.getId\(\)\s*,\s*function\.getId\(\)\s*\)' "$ACC" 2
}
file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    [ -f "$file" ] || return 1
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

# === D — atomicity (AC-5, AC-6, AC-7) =======================================
check_D1_service_method_exists() {
    file_contains 'replaceRoleFunctions\s*\(' "$URS"
}
# Tempered-greedy gap: the annotation must belong to THIS method. The gap forbids
# ';' and '@', so it can span the annotation's own continuation lines and the
# method's modifiers but cannot leap over another method body or another
# annotation. An unbounded .*? under /s would match a tenantTransactionManager
# annotation on some unrelated method and false-green.
#   Do NOT tempt the gap with `public` — the method declaration itself contains
#   `public`, so forbidding it makes this row permanently red, which is
#   indistinguishable from unimplemented work.
# Validated against 4 variants: correct (green), annotation-on-another-method
# (red), no-annotation (red), bare @Transactional i.e. landlord TM (red).
check_D2_tenant_transaction_manager() {
    file_contains_ml \
      '@Transactional\(\s*(?:(?:value|transactionManager)\s*=\s*)?"tenantTransactionManager"(?:(?![;@]).)*?\breplaceRoleFunctions' \
      "$URS"
}
# AdminController is the base class of 43 controllers. @Transactional there
# would open a tenant transaction around every endpoint in the application.
check_D3_admincontroller_untouched() {
    file_not_contains '@Transactional' "$ADMIN"
}
check_D4_controller_delegates() {
    file_contains 'userRoleService\.replaceRoleFunctions\(' "$CTRL"
}
# REVISED: Fix D is a SET DIFFERENCE, not delete-all-then-reinsert. Hibernate's
# ActionQueue runs inserts before deletes, so deleting and re-inserting the same
# (rolelist_id, functionlist_id) in one transaction is a duplicate-key path — and
# repo.flush() does not even compile here (CrudRepository, not JpaRepository).
# So assert the diff shape: a membership test inside the method, and NO blanket
# deleteAll of everything the find returned.
check_D5_computes_set_difference() {
    # Both guarded branches, not merely the substring `contains(` — a delete-all-then-reinsert
    # mutant was MEASURED green against the looser pattern because an unrelated line still
    # mentioned desired.contains(...).
    file_contains_ml 'replaceRoleFunctions(?:(?!\bpublic\b).)*?if\s*\(\s*!\s*desired\.contains\(' "$URS" \
      && file_contains_ml 'replaceRoleFunctions(?:(?!\bpublic\b).)*?if\s*\(\s*!\s*existing\.containsKey\(' "$URS"
}
check_D7_no_blanket_delete_all() {
    # Conjunctive with D1 on purpose: a bare negative would PASS while the method
    # does not exist yet, which is a fail-open row.
    check_D1_service_method_exists \
      && file_not_contains_ml 'replaceRoleFunctions(?:(?!\bpublic\b).)*?deleteAll\(' "$URS"
}
# Dedup now comes from using a Set rather than a .distinct() call.
check_D8_uses_a_set() {
    file_contains_ml 'replaceRoleFunctions(?:(?!\bpublic\b).)*?Set<Long>' "$URS"
}
# The second mapping of this table (UserRole.functions, @ManyToMany EAGER) must not
# be dragged into the transaction — see plan §11.
check_D9_does_not_load_userrole() {
    check_D1_service_method_exists \
      && file_not_contains_ml 'replaceRoleFunctions(?:(?!\bpublic\b).)*?userRoleRepository\.findById\(' "$URS"
}

# === F — AccessService reads the wrong column (latent) ======================
check_F1_group_read_by_rolelist() {
    file_not_contains 'findByFunctionlistId\(\s*role\.getId\(\)\s*\)' "$ACC"
}
check_F2_reads_use_rolelist() {
    file_contains_n_times 'findByRolelistId\(\s*role\.getId\(\)\s*\)' "$ACC" 2
}
# Scoped to saveRoleFunctions. `deletRole` at :77 legitimately keeps its own delete
# loop — plan §0 row 15 defers that method — so a FILE-WIDE negative here is
# permanently red, which is indistinguishable from unimplemented work.
check_D6_controller_loop_removed() {
    file_not_contains_ml 'saveRoleFunctions\((?:(?!\bpublic\b).)*?userRoleUserFunctionRepository\.delete\(' "$CTRL"
}

# === E — the misleading log line (AC-10) ====================================
check_E1_no_printer_log_in_role_controller() {
    file_not_contains 'delete printer with Id' "$CTRL"
}
# The identical "is deleted" string is LEGITIMATE at :80 inside deletRole, so a
# plain grep for it would be unfixable. What is wrong is the save path logging it
# with reqMap.get("roleId") — that argument shape only occurs in saveRoleFunctions.
check_E2_no_false_delete_success_log() {
    file_not_contains 'is deleted ",\s*reqMap\.get' "$CTRL"
}

# === T — the tests actually assert orientation (AC-8) =======================
# The pre-existing tests verify save(any(UserRoleUserFunction.class)), which is
# blind to the composite key: they pass on the broken code. A captor is the
# whole point.
# T1 previously asserted merely that the string "ArgumentCaptor" appeared in either test file —
# permanently green, because UserRoleControllerUnitTest uses ArgumentCaptor<Long> for the payload
# widening test, nothing to do with the composite key. AC-8 now cites T2+T3, which are real.
# T1 is repurposed to pin what NOTHING else did: that the annotation test checks propagation and
# readOnly, without which a NOT_SUPPORTED + readOnly=true mutant is 100% green.
check_T1_propagation_and_readonly_asserted() {
    file_contains 'tx\.propagation\(\)' "$T_URS" && file_contains 'tx\.readOnly\(\)' "$T_URS"
}
check_T2_asserts_rolelist_column() {
    file_contains 'getRolelistId\(\)' "$T_CTRL" || file_contains 'getRolelistId\(\)' "$T_URS"
}
check_T3_no_blind_save_only_assertion() {
    # At least one save-verification must be captor-based rather than any()-based.
    file_contains 'ArgumentCaptor<UserRoleUserFunction>' "$T_CTRL" \
      || file_contains 'ArgumentCaptor<UserRoleUserFunction>' "$T_URS"
}
# "mentions addFunctionToGroup" is already true today, so that assertion proved
# nothing. A column-level assertion is NOT achievable here either — AccessServiceUnitTest
# mocks UserFunctionService, so no composite key is ever built in this lane; demanding
# getRolelistId() would make this row permanently red.
# What actually guards Fix C is the delegation ORDER: the pre-existing test pinned
# addRoleToFunction(30L, 200L) — function first — which encoded AccessService:146's
# reversed call as correct. Assert that pin is gone and replaced.
# AC-16 — the Fix F stubs. The pre-existing tests stubbed findByFunctionlistId with a
# ROLE id, which made them pass against the wrong-column read. No stub may name that
# query any more (the repository method itself stays, for the Spring Data REST surface).
check_T5_no_wrong_column_stub() {
    file_not_contains 'when\(userRoleUserFunctionRepository\.findByFunctionlistId\(' "$T_ACC"
}
# AC-5 — the transaction-boundary slice test must exist AND assert on the tenant manager
# by name. Without the name assertion it would pass against a bare @Transactional.
# All three bare strings appear in this file's class javadoc, so name-matching alone was
# comment-satisfiable. Require the actual verifications instead.
check_T6_tx_boundary_test_asserts() {
    file_contains 'verify\(tenantTransactionManager\)\.rollback\(' "$T_TXB" \
      && file_contains 'verify\(landlordTransactionManager, never\(\)\)' "$T_TXB" \
      && file_contains 'getPropagationBehavior\(\)' "$T_TXB" \
      && file_contains 'isReadOnly\(\)' "$T_TXB"
}
check_T4_group_path_regression_test() {
    file_not_contains 'addRoleToFunction\(\s*30L\s*,\s*200L\s*\)' "$T_ACC" \
      && file_contains 'addRoleToFunction\(\s*200L\s*,\s*30L\s*\)' "$T_ACC"
}

# === S — the correct sibling sites are untouched (AC-11) ====================
# §0 rows 4-7. Any red here means the fix over-reached into records that were
# already right (see plan §3 for why they are right).
check_S1_usergroupservice_unchanged() {
    file_contains 'new UserGroupUserId\(\s*groupId\s*,\s*userId\s*\)' "$UGS"
}
check_S2_usercontroller_unchanged() {
    file_contains 'new UserGroupUserId\(\s*Long\.valueOf\(groupId\)\s*,\s*Long\.valueOf\(userId\)\s*\)' "$UCTRL"
}
check_S3_userroleservice_grouprole_unchanged() {
    file_contains 'new UserGroupUserRoleId\(\s*groupId\s*,\s*roleId\s*\)' "$URS"
}
check_S4_usergroupcontroller_unchanged() {
    file_contains 'new UserGroupUserRoleId\(\s*groupId\s*,\s*Long\.valueOf\(roleId\)\s*\)' "$UGCTRL"
}

# === Execution ==============================================================
echo
echo "SBDEV-3005 — role↔function composite key orientation + atomic replace"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "R — record contract unchanged (the fix is on the callers)"
run R1 "UserRoleUserFunctionId still declares (rolelistId, functionlistId)" check_R1_record_order_unchanged
echo
echo "A — no reversed construction survives anywhere under src/main"
run A1 "a correctly-ordered (roleId, functionId) construction exists"        check_A1_correct_order_exists
run A2 "no bare reversed (functionId, roleId) construction"                  check_A2_no_reversed_bare
run A3 "no boxed reversed (Long.valueOf(functionId), ...) construction"      check_A3_no_reversed_boxed
run A4 "the construction INSIDE replaceRoleFunctions is (roleId, ...)"       check_A4_construction_inside_the_method
echo
echo "B — UserFunctionService.addRoleToFunction"
run B1 "constructs the key as (roleId, functionId)"                          check_B1_service_correct_order
run B2 "no reversed construction remains in the service"                     check_B2_service_no_reversed
run B3 "the existence guard still reads (roleId, functionId)"                check_B3_guard_orientation_intact
echo
echo "C — AccessService (PAIRED with B: fixing B alone breaks addFunctionToGroup)"
run C1 "addFunctionToGroup passes (connector_role, function)"                check_C1_group_call_unreversed
run C2 "no reversed (function, connector_role) call remains"                 check_C2_no_reversed_group_call
run C3 "both addFunctionToUser and addFunctionToGroup use the same order"    check_C3_user_call_still_correct
echo
echo "D — atomic replace under the tenant transaction manager"
run D1 "UserRoleService.replaceRoleFunctions exists"                         check_D1_service_method_exists
run D2 "it is @Transactional(value=\"tenantTransactionManager\")"            check_D2_tenant_transaction_manager
run D3 "AdminController still has NO @Transactional (43 subclasses)"         check_D3_admincontroller_untouched
run D4 "the endpoint delegates to the service method"                        check_D4_controller_delegates
run D5 "computes a set difference (membership test present)"                  check_D5_computes_set_difference
run D6 "the controller no longer owns the delete loop"                       check_D6_controller_loop_removed
run D7 "no blanket deleteAll inside the method (insert-before-delete trap)" check_D7_no_blanket_delete_all
run D8 "dedup via Set<Long>, not .distinct()"                               check_D8_uses_a_set
run D9 "does NOT load UserRole in the tx (2nd @ManyToMany mapping)"         check_D9_does_not_load_userrole
echo
echo "F — AccessService wrong-column reads (latent, plan Fix F)"
run F1 "no findByFunctionlistId(role.getId()) remains"                      check_F1_group_read_by_rolelist
run F2 "both sites now use findByRolelistId(role.getId())"                  check_F2_reads_use_rolelist
echo
echo "E — log lines"
run E1 "no 'delete printer with Id' in UserRoleController"                   check_E1_no_printer_log_in_role_controller
run E2 "no false 'is deleted' success log on the save path"                  check_E2_no_false_delete_success_log
echo
echo "T — tests assert the composite key, not any()"
run T1 "annotation test asserts propagation + readOnly, not just value"      check_T1_propagation_and_readonly_asserted
run T2 "getRolelistId() is asserted"                                         check_T2_asserts_rolelist_column
run T3 "the captor is typed to UserRoleUserFunction"                         check_T3_no_blind_save_only_assertion
run T4 "AccessServiceUnitTest no longer pins the reversed call"         check_T4_group_path_regression_test
run T5 "no test stubs the wrong-column findByFunctionlistId (AC-16)"   check_T5_no_wrong_column_stub
run T6 "tx-boundary test asserts rollback + propagation + readOnly (AC-5)" check_T6_tx_boundary_test_asserts
echo
echo "S — already-correct sibling sites untouched (plan §0 rows 4-7)"
run S1 "UserGroupService:81 unchanged"                                       check_S1_usergroupservice_unchanged
run S2 "UserController:327 unchanged"                                        check_S2_usercontroller_unchanged
run S3 "UserRoleService.addGroupToRole unchanged"                            check_S3_userroleservice_grouprole_unchanged
run S4 "UserGroupController:111 unchanged"                                   check_S4_usergroupcontroller_unchanged
echo
echo "M — test suites (slow; set SKIP_MVN=1 to bypass)"
if [ "${SKIP_MVN:-0}" = "1" ]; then
    skip M1 "UserRoleControllerUnitTest"  "SKIP_MVN=1"
    skip M2 "UserFunctionServiceUnitTest" "SKIP_MVN=1"
    skip M3 "AccessServiceUnitTest"       "SKIP_MVN=1"
    skip M4 "UserRoleServiceUnitTest"     "SKIP_MVN=1"
    skip M5 "UserRoleServiceTransactionBoundaryTest" "SKIP_MVN=1"
else
    run M1 "UserRoleControllerUnitTest passes (>=17)"  mvn_test_passes UserRoleControllerUnitTest 17
    run M2 "UserFunctionServiceUnitTest passes (>=8)" mvn_test_passes UserFunctionServiceUnitTest 8
    run M3 "AccessServiceUnitTest passes (>=39)"      mvn_test_passes AccessServiceUnitTest 39
    run M4 "UserRoleServiceUnitTest passes (>=13)"    mvn_test_passes UserRoleServiceUnitTest 13
    run M5 "UserRoleServiceTransactionBoundaryTest passes (>=3)" mvn_test_passes UserRoleServiceTransactionBoundaryTest 3
fi
echo
echo "X — cannot be verified by this script"
skip X1 "Postgres actually rolls the ROWS back (AC-5, end-to-end)" \
        "the tx boundary IS now covered by T6/M5's slice test; only the real-DB commit/rollback stays manual — plan §8 M4, which must DROP an existing function or the delete set is empty"
skip X2 "prd tenant wh01_hydra_v2 corruption audit (P2)" \
        "no prd MCP in the authoring session; run the plan §7.1-P1 query there"
echo
# `mvn test` rewrites the tracked ArchUnit freeze store. Restore it so a clean-tree check after a
# full verify run does not show a spurious modification.
if [ "${SKIP_MVN:-0}" != "1" ] && [ -d src/test/resources/archunit_store ]; then
    git checkout -- src/test/resources/archunit_store 2>/dev/null || true
fi

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ] || exit 1
