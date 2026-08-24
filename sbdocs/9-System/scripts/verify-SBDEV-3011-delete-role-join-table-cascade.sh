#!/usr/bin/env bash
# verify-SBDEV-3011-delete-role-join-table-cascade.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-3011-delete-role-join-table-cascade.md
#
#   $ PROJECT_ROOT=/path/to/v2/wms2-api \
#       bash sbdocs/9-System/scripts/verify-SBDEV-3011-delete-role-join-table-cascade.sh
#
# Exit 0 only when every check passes. Paste the final "Result:" line into the
# completion report — a prose "DONE" is not acceptance.
#
# Run it BEFORE the first code change to capture the baseline. Every row's EXPECTED
# baseline state is in the plan's §13.1 table and repeated in each row's label here as
# [exp:FAIL] or [exp:PASS-pin]. Roughly a third of these rows are GREEN at baseline BY
# DESIGN — they are regression pins, not defect detectors. A run that shows them green
# proves nothing on its own; read the exp: markers before concluding anything.
#
# The M rows shell out to maven, so JAVA_HOME and PATH must reach a JDK 21 + maven:
#   export JAVA_HOME=~/.sdkman/candidates/java/21.0.11-ms
#   export PATH="$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH"
# Set SKIP_MVN=1 to skip them for a fast code-shape-only pass.
#
# BASE_SHA (for row S1) defaults to the plan's stated base, develop @ 60aef02.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT DOES NOT USE TEMPERED-GREEDY REGEX GAPS
# ---------------------------------------------------------------------------
# The plan's §13.1 constraint 3 prescribes a tempered gap `(?:(?!;|@).)*?` for
# method-scoped rows. That gap CANNOT CROSS A `;`, so on any row that must span a
# multi-statement method body (A2, A4, C2, E2, T5, T6) it is permanently RED — which is
# constraint 8's own trap, self-inflicted. Rather than hand-tune a second regex per row,
# every scoped row here extracts the EXACT syntactic region first (brace-balanced method
# body, brace-balanced nested class, or the contiguous annotation block immediately
# preceding a signature) and then greps inside it. Consequences:
#   * a construct in a NEIGHBOURING method can never satisfy a row (no false green);
#   * a legitimate use elsewhere in the file can never fail one (no permanent red) —
#     this is what killed iteration 1's A4, since UserRoleService:109
#     (removeGroupFromRole) legitimately calls userGroupUserRoleRepository.delete;
#   * a missing method makes the region empty, and every scoped helper FAILS CLOSED on an
#     empty region, so "not implemented yet" reads as FAIL, never as a vacuous PASS.
# Negative rows additionally strip // and /* */ comments before matching, because §4.2's
# and §4.3's prescribed javadoc deliberately NAMES deleteById, findById, findAllById and
# clearAutomatically — so an uncommented-only match is mandatory, not defensive.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

BASE_SHA="${BASE_SHA:-60aef02}"

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-6s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-6s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-6s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# --- syntactic region extraction ------------------------------------------------
# jscope <file> <kind> <name> [--strip-comments]
#   kind=body   brace-balanced body of method <name>
#   kind=class  brace-balanced body of class/interface <name>  (for @Nested regions)
#   kind=decl   contiguous annotation lines immediately preceding <name> + its signature
# Prints the region to stdout. Exits non-zero if the file is missing or the region is
# not found — so every caller fails CLOSED.
jscope() {
    local file=$1 kind=$2 name=$3 strip=${4:-}
    [ -f "$file" ] || return 1
    JS_KIND="$kind" JS_NAME="$name" JS_STRIP="$strip" python3 - "$file" <<'PY'
import os, re, sys
kind = os.environ["JS_KIND"]; name = os.environ["JS_NAME"]
strip = os.environ.get("JS_STRIP", "") == "--strip-comments"
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()

def balanced(s, open_idx):
    depth = 0
    for i in range(open_idx, len(s)):
        if s[i] == '{': depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0: return s[open_idx:i+1]
    return None

out = None
if kind in ("body", "class"):
    if kind == "class":
        pat = re.compile(r'\b(?:class|interface|enum|record)\s+' + re.escape(name) + r'\b')
    else:
        # the identifier used as a declaration: name ( ... ) [throws ...] {
        pat = re.compile(r'(?<![\w.])' + re.escape(name) + r'\s*\(')
    for m in pat.finditer(src):
        brace = src.find('{', m.end() - 1)
        if brace == -1: continue
        # reject a call site: a ';' between the match and the brace means this was not a
        # declaration (e.g. `foo(x); ... {`)
        if ';' in src[m.end():brace]: continue
        body = balanced(src, brace)
        if body:
            out = body
            break
elif kind == "decl":
    # Collect the contiguous annotation / javadoc block immediately above the signature.
    # MUST handle MULTI-LINE annotations: the prescribed @Transactional(value = ...,
    # rollbackFor = ...) spans two lines, and @Query(...) often spans several. A naive
    # "line starts with @" backward walk stops at the continuation line and silently drops
    # the annotation — measured: it failed B1/B2 against a CORRECT fixture. Annotation
    # array values also contain braces (rollbackFor = {A.class, B.class}), so a
    # brace/semicolon scan backwards is wrong too. Balance parens+braces instead.
    def balanced_block(lines):
        t = "\n".join(lines)
        return (t.count('(') == t.count(')')) and (t.count('{') == t.count('}'))

    def is_decl_line(t):
        return t.startswith('@') or t.startswith('/*') or t.startswith('*') or t.endswith('*/')

    pat = re.compile(r'(?<![\w.])' + re.escape(name) + r'\s*\(')
    for m in pat.finditer(src):
        line_start = src.rfind('\n', 0, m.start()) + 1
        above = src[:line_start].rstrip('\n').split('\n')
        block = []
        for ln in reversed(above):
            t = ln.strip()
            if t == '' and not block:
                continue
            block.insert(0, ln)
            if not balanced_block(block):
                continue          # unclosed annotation — keep pulling lines upward
            if is_decl_line(block[0].strip()):
                continue          # a complete annotation/javadoc line; look for more above
            block.pop(0)          # overshot into the previous member
            break
        sig_end = src.find('{', m.end() - 1)
        sig_end = sig_end if sig_end != -1 else src.find(';', m.end() - 1)
        if sig_end == -1: continue
        out = ('\n'.join(block) + '\n' if block else '') + src[line_start:sig_end + 1]
        break

if out is None or not out.strip():
    sys.exit(1)
if strip:
    out = re.sub(r'/\*.*?\*/', ' ', out, flags=re.S)
    out = re.sub(r'//[^\n]*', ' ', out)
sys.stdout.write(out)
PY
}

# --- assertion helpers ----------------------------------------------------------
# All fail CLOSED on a missing file. The verify-plan-template versions of
# file_not_contains and the perl helpers report PASS for a file that does not exist,
# which false-greens every assertion about a file a refactor moved or a fix has not
# created yet (A7 and T9 below are both brand-new files).
file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

file_contains_ml() {
    [ -f "$2" ] || return 1
    perl -0777 -ne "exit(/$1/s ? 0 : 1)" "$2"
}

# scope_contains <file> <kind> <name> <regex...>   — ALL regexes must match in the region
scope_contains() {
    local file=$1 kind=$2 name=$3; shift 3
    local region; region=$(jscope "$file" "$kind" "$name") || return 1
    [ -n "$region" ] || return 1
    local re
    for re in "$@"; do
        printf '%s' "$region" | grep -qE "$re" || return 1
    done
    return 0
}

# scope_lacks <file> <kind> <name> <regex...>  — region must EXIST and match NO regex.
# Comments are stripped first (see header). The existence requirement is what makes an
# unimplemented method read as FAIL rather than as a vacuous PASS.
scope_lacks() {
    local file=$1 kind=$2 name=$3; shift 3
    local region; region=$(jscope "$file" "$kind" "$name" --strip-comments) || return 1
    [ -n "$region" ] || return 1
    local re
    for re in "$@"; do
        printf '%s' "$region" | grep -qE "$re" && return 1
    done
    return 0
}

# Strips // and /* */ comments from a whole file, then asserts the regex does NOT appear. Needed
# wherever a deliberate explanatory comment names the very construct a negative row forbids.
file_not_contains_uncommented() {
    [ -f "$2" ] || return 1
    ! python3 -c "
import re,sys
src=open(sys.argv[1],encoding='utf-8',errors='replace').read()
src=re.sub(r'/\*.*?\*/',' ',src,flags=re.S)
src=re.sub(r'//[^\n]*',' ',src)
sys.exit(0 if re.search(sys.argv[2],src) else 1)
" "$2" "$1"
}

# Asserts UserRoleRepository's extends clause names NO raw Spring Data supertype. Matched on the
# clause itself rather than the file, and tolerant of NoDeletePagingAndSortingRepository, which
# contains "PagingAndSortingRepository" as a substring.
extends_clause_lacks_raw_supertypes() {
    [ -f "$1" ] || return 1
    python3 -c "
import re,sys
src=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'interface\s+UserRoleRepository\s+extends\s+(.*?)\{', src, re.S)
if not m: sys.exit(1)
clause=m.group(1)
# a raw supertype is one of these names NOT preceded by an identifier character
bad=re.search(r'(?<![A-Za-z0-9_])(PagingAndSortingRepository|CrudRepository)\s*<', clause)
sys.exit(1 if bad else 0)
" "$1"
}

# The verify-plan-template's mvn_test_passes is BROKEN and reports FAIL on a passing run:
# it pipes `mvn -q` into a grep for "BUILD SUCCESS|Tests run...", but -q suppresses both,
# so maven exits 0 while the grep matches nothing. 62 red rows across 22 scripts —
# SBDEV-3014. Use the EXIT CODE, and additionally require a real surefire summary with
# Skipped: 0 and a minimum count, because:
#   * a class-level @Disabled reports "Tests run: 1, ... Skipped: 1" with exit 0, so
#     without the Skipped check a disabled class certifies itself green;
#   * these tests live in @Nested classes, so surefire also emits "Tests run: 0" for the
#     OUTER class — which alone satisfies a bare [0-9]+ pattern, meaning deleting the
#     @Nested classes would still pass.
mvn_test_passes() {
    local out rc count
    out=$(mvn test -Dtest="$1" -DfailIfNoTests=false -Djacoco.skip=true 2>&1); rc=$?
    [ "$rc" -eq 0 ] || return 1
    count=$(printf '%s' "$out" \
        | grep -oE "Tests run: [0-9]+, Failures: 0, Errors: 0, Skipped: 0" \
        | grep -oE "[0-9]+" | sort -rn | head -1)
    [ -n "$count" ] && [ "$count" -ge "${2:-1}" ]
}

# plan_status_section — prints ONLY the plan's §13.3 Implementation Status block.
# The X rows must not grep the whole plan: "P9:" and "M7:" also appear in the §6.1
# prerequisites and §7.5 manual-test tables, so a file-wide grep passed at baseline
# (measured) — a false green on exactly the rows meant to gate unrecorded work.
plan_status_section() {
    [ -f "$1" ] || return 1
    python3 - "$1" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'^###\s*13\.3\b.*?$(.*?)(?=^##\s|\Z)', src, re.S | re.M)
if not m or not m.group(1).strip():
    sys.exit(1)
sys.stdout.write(m.group(1))
PYEOF
}

# status_records <plan> <regex...> — every regex must appear inside §13.3, and the
# placeholder must be gone.
status_records() {
    local plan=$1; shift
    local sec; sec=$(plan_status_section "$plan") || return 1
    printf '%s' "$sec" | grep -qE '\(empty — to be filled' && return 1
    local re
    for re in "$@"; do
        printf '%s' "$sec" | grep -qE "$re" || return 1
    done
    return 0
}

# --- paths ---------------------------------------------------------------------
SVC=src/main/java/net/aim_ai/wms/service/UserRoleService.java
CTRL=src/main/java/net/aim_ai/wms/controller/UserRoleController.java
ADMIN=src/main/java/net/aim_ai/wms/controller/AdminController.java
RREPO=src/main/java/net/aim_ai/wms/repo/jpa/UserRoleRepository.java
RUFREPO=src/main/java/net/aim_ai/wms/repo/jpa/UserRoleUserFunctionRepository.java
UURREPO=src/main/java/net/aim_ai/wms/repo/jpa/UserUserRoleRepository.java
GREPO=src/main/java/net/aim_ai/wms/repo/jpa/UserGroupRepository.java
UREPO=src/main/java/net/aim_ai/wms/repo/jpa/UserRepository.java
VIEW=src/main/java/net/aim_ai/wms/repo/projection/RoleHolderNameView.java
NODEL=src/main/java/net/aim_ai/wms/repo/cinterface/NoDeletePagingAndSortingRepository.java
CTEST=src/test/java/net/aim_ai/wms/unit/controller/UserRoleControllerUnitTest.java
STEST=src/test/java/net/aim_ai/wms/unit/service/UserRoleServiceUnitTest.java
TXTEST=src/test/java/net/aim_ai/wms/unit/service/UserRoleServiceTransactionBoundaryTest.java
QTEST=src/test/java/net/aim_ai/wms/unit/repo/UserRoleQueryContractUnitTest.java
UGCTRL=src/main/java/net/aim_ai/wms/controller/UserGroupController.java
UCTRL=src/main/java/net/aim_ai/wms/controller/UserController.java
# ABSOLUTE, with an env override. A relative ../../sbdocs path resolves correctly from
# v2/wms2-api but NOT from a worktree at .claude/worktrees/<repo>/<TICKET>, where ../../ lands in
# .claude/worktrees. The X rows then failed CLOSED on a missing file — the right direction, but
# indistinguishable from unrecorded work, which is precisely the trap those rows exist to avoid.
# sbdocs/ is outside every sub-repo worktree, so it can never be reached relative to PROJECT_ROOT.
PLAN="${PLAN:-/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3011-delete-role-join-table-cascade.md}"

echo
echo "verify-SBDEV-3011 — delete-role join-table cascade + atomicity"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  BASE_SHA=$BASE_SHA   (row S1)"
echo "  exp: markers are the EXPECTED PRE-FIX state — see plan §13.1"
echo

echo "A — Fix A: refuse with 422, naming the holders"
run A1 "[exp:FAIL] UserRoleService declares deleteRole(Long" \
    file_contains 'void[[:space:]]+deleteRole\([[:space:]]*Long' "$SVC"
run A2 "[exp:FAIL] deleteRole body queries BOTH holder tables" \
    scope_contains "$SVC" body deleteRole \
        'userGroupUserRoleRepository\.findByRolelistId' \
        'userUserRoleRepository\.findByRolesId'
run A3 "[exp:FAIL] deleteRole body throws ApiInvalidParameterException" \
    scope_contains "$SVC" body deleteRole 'throw new ApiInvalidParameterException'
run A4 "[exp:FAIL] deleteRole body NEVER deletes a holder row (anti-cascade)" \
    scope_lacks "$SVC" body deleteRole \
        'userGroupUserRoleRepository\.delete\(' \
        'userUserRoleRepository\.delete\('
run A5 "[exp:FAIL] UserUserRoleRepository.findByRolesId on u.id.rolesId, unexported" \
    file_contains_ml 'findByRolesId' "$UURREPO"
run A5b "[exp:FAIL] ...and it navigates rolesId (not rolelistId) and is exported=false" \
    scope_contains "$UURREPO" decl findByRolesId 'u\.id\.rolesId' 'exported[[:space:]]*=[[:space:]]*false'
run A6 "[exp:FAIL] both findHolderNamesByIds use IN :ids and are unexported" \
    scope_contains "$GREPO" decl findHolderNamesByIds 'IN[[:space:]]+:ids' 'exported[[:space:]]*=[[:space:]]*false'
run A6b "[exp:FAIL] ...same on UserRepository" \
    scope_contains "$UREPO" decl findHolderNamesByIds 'IN[[:space:]]+:ids' 'exported[[:space:]]*=[[:space:]]*false'
run A6c "[exp:FAIL] both name queries alias AS id and AS name (TupleBackedMap would" \
    scope_contains "$GREPO" decl findHolderNamesByIds 'AS[[:space:]]+id' 'AS[[:space:]]+name'
run A6d "[exp:FAIL]   ...silently return null getters without them)" \
    scope_contains "$UREPO" decl findHolderNamesByIds 'AS[[:space:]]+id' 'AS[[:space:]]+name'
run A7 "[exp:FAIL] RoleHolderNameView declares getId() and getName()" \
    scope_contains "$VIEW" class RoleHolderNameView 'Long[[:space:]]+getId\(' 'String[[:space:]]+getName\('
run A8 "[exp:FAIL] describeHolders exists with a named holder cap constant" \
    file_contains_ml 'HOLDER_NAMES_IN_MESSAGE' "$SVC"
run A8b "[exp:FAIL] ...and deleteRole delegates the message to it" \
    scope_contains "$SVC" body deleteRole 'describeHolders'
echo

echo "B — Fix B: one tenant transaction"
run B1 "[exp:FAIL] deleteRole @Transactional names tenantTransactionManager (either spelling)" \
    scope_contains "$SVC" decl deleteRole \
        '@Transactional' \
        '(value|transactionManager)[[:space:]]*=[[:space:]]*"tenantTransactionManager"'
run B2 "[exp:FAIL] ...and rollbackFor covers the checked ApiInvalidParameterException" \
    scope_contains "$SVC" decl deleteRole 'rollbackFor' 'ApiInvalidParameterException\.class'
run B3 "[exp:PASS-pin] AdminController still has NO @Transactional (43 subclasses)" \
    file_not_contains '@Transactional' "$ADMIN"
echo

echo "C — Fix C: never materialise the entity"
run C1 "[exp:FAIL] deleteRoleById is @Modifying(flushAutomatically=true), unexported" \
    scope_contains "$RREPO" decl deleteRoleById \
        '@Modifying' 'flushAutomatically[[:space:]]*=[[:space:]]*true' \
        'exported[[:space:]]*=[[:space:]]*false'
run C1b "[exp:FAIL] ...and does NOT set clearAutomatically (would detach the caller's PC)" \
    scope_lacks "$RREPO" decl deleteRoleById 'clearAutomatically'
run C2 "[exp:FAIL] deleteRole body never loads or deleteByIds the role" \
    scope_lacks "$SVC" body deleteRole \
        'userRoleRepository\.deleteById\(' \
        'userRoleRepository\.findById\(' \
        'userGroupRepository\.findAllById\('
run C3 "[exp:FAIL] deleteByRoleId is @Modifying(flushAutomatically=true), unexported" \
    scope_contains "$RUFREPO" decl deleteByRoleId \
        '@Modifying' 'flushAutomatically[[:space:]]*=[[:space:]]*true' \
        'exported[[:space:]]*=[[:space:]]*false'
run C3b "[exp:FAIL] ...on f.id.rolelistId, and deleteRole CALLS it (AC-10: greppable)" \
    scope_contains "$RUFREPO" decl deleteByRoleId 'f\.id\.rolelistId'
run C3c "[exp:FAIL] ...deleteRole calls userRoleUserFunctionRepository.deleteByRoleId" \
    scope_contains "$SVC" body deleteRole 'userRoleUserFunctionRepository\.deleteByRoleId'
run C4 "[exp:FAIL] neither bulk method carries @Transactional (bare => landlord TM)" \
    scope_lacks "$RREPO" decl deleteRoleById '@Transactional'
run C4b "[exp:FAIL] ...same on deleteByRoleId" \
    scope_lacks "$RUFREPO" decl deleteByRoleId '@Transactional'
echo

echo "D — Fix D: close the parallel Spring Data REST item-resource DELETE"
run D1 "[exp:FAIL] UserRoleRepository extends NoDeletePagingAndSortingRepository" \
    file_contains 'interface[[:space:]]+UserRoleRepository[[:space:]]+extends[[:space:]]+NoDeletePagingAndSortingRepository<[[:space:]]*UserRole[[:space:]]*,[[:space:]]*Long[[:space:]]*>' "$RREPO"
# NOTE: NoDeletePagingAndSortingRepository CONTAINS the substring
# "PagingAndSortingRepository", so a naive negative on that name is permanently RED the moment
# Fix D lands (measured). Assert on the extends clause's direct supertypes instead.
run D2 "[exp:FAIL] ...and no longer names the raw supertypes directly in extends" \
    extends_clause_lacks_raw_supertypes "$RREPO"
run D3 "[exp:FAIL] NoDeletePagingAndSortingRepository gains @NoRepositoryBean" \
    file_contains '@NoRepositoryBean' "$NODEL"
run D4 "[exp:PASS-pin] ...and still suppresses deleteById + delete (arity pinned by T9)" \
    file_contains_ml '@RestResource\(exported = false\).{0,80}deleteById.*@RestResource\(exported = false\).{0,80}delete\(' "$NODEL"
run D5 "[exp:PASS-pin] the two SDR search resources the UI needs stay exported" \
    scope_contains "$RREPO" decl findByName '@RestResource' 'path[[:space:]]*=[[:space:]]*"findByName"'
echo

echo "E — the controller delegates and owns nothing"
run E1 "[exp:FAIL] deletRole calls userRoleService.deleteRole" \
    scope_contains "$CTRL" body deletRole 'userRoleService\.deleteRole'
run E2 "[exp:FAIL] deletRole touches no repository at all" \
    scope_lacks "$CTRL" body deletRole 'userRoleUserFunctionRepository' 'userRoleRepository'
run E3 "[exp:FAIL] deletRole declares throws ApiInvalidParameterException" \
    scope_contains "$CTRL" decl deletRole 'ApiInvalidParameterException'
echo

echo "T — tests (the two bug-pinning tests are DELETED, not adapted)"
# Comment-immune (constraint 6): the replacement block deliberately NAMES both deleted tests in a
# comment recording WHY they were deleted, which satisfied a bare negative grep (measured).
run T1 "[exp:FAIL] the two pinning tests are gone (comment mentions allowed)" \
    file_not_contains_uncommented 'deletesRoleAndFunctions|deletesRoleWithNoFunctions' "$CTEST"
run T2 "[exp:FAIL] controller test asserts 422 and 404 in the delete region" \
    scope_contains "$CTEST" class DeletRole 'isUnprocessableEntity' 'isNotFound'
run T3 "[exp:FAIL] refusalWritesNothingAtAll asserts never() on ALL FOUR tables" \
    scope_contains "$STEST" body refusalWritesNothingAtAll \
        'never\(\)\)\.deleteByRoleId' 'never\(\)\)\.deleteRoleById' \
        'userGroupUserRoleRepository' 'userUserRoleRepository'
run T4 "[exp:FAIL] neverLoadsTheRoleOrGroupEntities asserts never()).findById(" \
    scope_contains "$STEST" body neverLoadsTheRoleOrGroupEntities 'never\(\)\)\.findById\('
run T5 "[exp:FAIL] deleteRoleRefusalRollsBackOnTenantManager verifies rollback IN ITS BODY" \
    scope_contains "$TXTEST" body deleteRoleRefusalRollsBackOnTenantManager 'rollback\('
run T6 "[exp:FAIL] deleteRole tx definition is REQUIRED and writable, asserted in-body" \
    scope_contains "$TXTEST" body deleteRoleTransactionDefinitionIsAWritableRequiredTransaction \
        'PROPAGATION_REQUIRED' 'isReadOnly'
run T7 "[exp:FAIL] the refusal WARN log is asserted (ListAppender) in the delete region" \
    scope_contains "$STEST" class DeleteRole 'ListAppender' 'WARN'
run T8 "[exp:FAIL] the delete region does NOT assert BusinessException for the refusal" \
    scope_lacks "$STEST" class DeleteRole 'BusinessException'
run T9 "[exp:FAIL] UserRoleQueryContractUnitTest pins the resolved annotations" \
    scope_contains "$QTEST" class UserRoleQueryContractUnitTest \
        'clearAutomatically' 'exported\(\)' 'flushAutomatically'
run T9b "[exp:FAIL] ...and pins AC-11 by reflection, not only by manual test" \
    file_contains_ml 'NoDeletePagingAndSortingRepository' "$QTEST"
run T10 "[exp:FAIL] a zero-grant unheld role still deletes (replaces deletesRoleWithNoFunctions)" \
    file_contains_ml 'deletesAnUnheldRoleWithZeroGrants|ZeroGrant' "$STEST"
echo

echo "S — nothing else moved (scope discipline)"
if git rev-parse --verify --quiet "$BASE_SHA" >/dev/null 2>&1; then
    run S1 "[exp:PASS-pin] UserGroupController and UserController are untouched vs $BASE_SHA" \
        git diff --quiet "$BASE_SHA" -- "$UGCTRL" "$UCTRL"
else
    run S1 "[exp:PASS-pin] UserGroupController/UserController literals intact (BASE_SHA absent)" \
        bash -c 'grep -qE "delete printer with Id" "'"$UGCTRL"'" && grep -qE "ResponseEntity\.ok\(errorMap\)" "'"$UCTRL"'"'
fi
run S2 "[exp:PASS-pin] SBDEV-3005 intact: replaceRoleFunctions still on the tenant TM" \
    scope_contains "$SVC" decl replaceRoleFunctions 'tenantTransactionManager'
run S2b "[exp:PASS-pin] SBDEV-3005 intact: composite key still built (roleId, functionId)" \
    scope_contains "$SVC" body replaceRoleFunctions 'UserRoleUserFunctionId\([[:space:]]*roleId[[:space:]]*,[[:space:]]*functionId[[:space:]]*\)'
echo

echo "X — recorded-outcome gates (these FAIL until the plan's §13.3 carries the result)"
run X1 "[exp:FAIL] P3 tenant damage audit is recorded in the plan's §13.3" \
    status_records "$PLAN" 'P3:'
run X2 "[exp:FAIL] P9 and P11 dispositions are recorded in §13.3" \
    status_records "$PLAN" 'P9:' 'P11:'
run X4 "[exp:FAIL] the three BLOCKING manual rows M7/M8/M10 are recorded in §13.3" \
    status_records "$PLAN" 'M7:' 'M8:' 'M10:'
skip X3 "manual rows M1-M6, M9" \
      "operator click-path + SQL; the three BLOCKING ones are gated by X4"
echo

echo "M — targeted test classes"
if [ "${SKIP_MVN:-0}" = "1" ]; then
    skip M1 "UserRoleControllerUnitTest"            "SKIP_MVN=1"
    skip M2 "UserRoleServiceUnitTest"               "SKIP_MVN=1"
    skip M3 "UserRoleServiceTransactionBoundaryTest" "SKIP_MVN=1"
    skip M4 "UserRoleQueryContractUnitTest"         "SKIP_MVN=1"
    skip M5 "AccessServiceUnitTest (regression)"    "SKIP_MVN=1"
else
    run M1 "UserRoleControllerUnitTest passes (>=15)"   mvn_test_passes UserRoleControllerUnitTest 15
    run M2 "UserRoleServiceUnitTest passes (>=18)"      mvn_test_passes UserRoleServiceUnitTest 18
    run M3 "UserRoleServiceTransactionBoundaryTest passes (>=5)" mvn_test_passes UserRoleServiceTransactionBoundaryTest 5
    run M4 "UserRoleQueryContractUnitTest passes (>=5)" mvn_test_passes UserRoleQueryContractUnitTest 5
    run M5 "AccessServiceUnitTest still passes (>=39)"  mvn_test_passes AccessServiceUnitTest 39
fi
echo

# `mvn test` rewrites the tracked ArchUnit freeze store. Restore it so a clean-tree check
# after a full verify run does not show a spurious modification.
if [ "${SKIP_MVN:-0}" != "1" ] && [ -d src/test/resources/archunit_store ]; then
    git checkout -- src/test/resources/archunit_store 2>/dev/null || true
fi

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ] || exit 1
