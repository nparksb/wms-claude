#!/usr/bin/env bash
# verify-SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.md
#
# Usage:
#   PROJECT_ROOT=/path/to/owl bash sbdocs/9-System/scripts/verify-SBDEV-2870-...sh
#
# Against a per-ticket worktree, point PROJECT_ROOT at a symlink shadow root, or this
# grades the main checkout instead of the work.
#
# SCOPE OF WHAT THIS SCRIPT PROVES (revised 2026-08-17, function-model redesign).
#
# The FOUR User Management endpoints moved to UserAdministrationController and are gated by an
# ordinary method call on the WEB_UI_VIEW_USER_MANAGEMENT function, so their deny path IS
# behaviourally tested — by UserAdministrationControllerUnitTest, ablation-proven both ways
# (remove the 4 guard calls -> 5/5 gate tests fail; move one guard inside its try -> exactly that
# endpoint's test fails). Rows T* below assert those tests exist AND that mvn actually ran them.
#
# Fix E (rows E*) gates saveUserGroups, which rewrites the very table the function gate reads —
# without it every function gate in the app is bypassable in one request. Also behaviourally tested.
#
# The ONE remaining @PreAuthorize gate (/admin/importUsersFromCsvText on **sb_admin**, deliberately
# tied to no function because its caller is SiteBoss staff) is still structure-only: standaloneSetup
# installs no method-security advisor and @SpringBootTest is down (SBDEV-2217), so no test in this
# repo can evaluate it. Row B1 asserts the annotation is present, LIVE, and attached to the right
# method — nothing more. That one endpoint is the entire residual of AC-5: one curl.
#
# STILL OPEN, deliberately out of scope (own ticket SBDEV-2984): /v3/user/create, /user/importUser and
# /user/delete/{userId} remain ungated and can still manufacture Keycloak identities with
# warehouse-group membership. A green run here does NOT mean identity creation is locked down.
#
# Helpers are hardened three ways, each after a real false result on this very script:
#  - file_not_contains: the stock template's `! grep ...` returns TRUE for a MISSING file, which
#    false-greens every negative assertion about a new file.
#  - annotated_within / file_contains_n_live: strip commented-out lines, else a `// @PreAuthorize`
#    satisfies the row — i.e. the row is satisfied by exactly the defect the ticket exists to fix.
#  - rows that are trivially true pre-fix are labelled `[pin: vacuous pre-fix]` so a reader does not
#    mistake them for evidence.
#
# NEGATIVE-TESTED: replayed against pre-fix HEAD (= origin/develop) -> 11 pass / 35 fail. The 11 are
# exactly the vacuous pins and the relocation/hygiene negatives. Re-run that replay after ANY edit
# here; a post-fix green run cannot detect a row that passes on the broken tree.

set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
API="$PROJECT_ROOT/v2/wms2-api"
SRC="$API/src/main/java/net/aim_ai/wms"
TST="$API/src/test/java/net/aim_ai/wms"

PASS=0; FAIL=0; SKIP=0
run() { local id=$1 d=$2; shift 2
  if "$@" >/dev/null 2>&1; then printf "  PASS  %-8s %s\n" "$id" "$d"; PASS=$((PASS+1))
  else printf "  FAIL  %-8s %s\n" "$id" "$d"; FAIL=$((FAIL+1)); fi; }
skip() { printf "  SKIP  %-8s %s\n" "$1" "$2"; SKIP=$((SKIP+1)); }

file_exists()      { [ -f "$1" ]; }
file_contains()    { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains(){ [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
file_contains_n()  { [ -f "$2" ] || return 1; local c; c=$(grep -cE "$1" "$2" 2>/dev/null || echo 0); [ "$c" -ge "$3" ]; }

# An @PreAuthorize must sit within N lines ABOVE the named method — a file-level grep
# would pass on an annotation attached to some other endpoint entirely.
annotated_within() {   # $1=file $2=method-regex $3=window $4=annotation-regex
  [ -f "$1" ] || return 1
  # COMMENT LINES ARE STRIPPED FIRST, and this is load-bearing. The pre-fix tree carries
  # `// @PreAuthorize(Authority.IS_SB_ADMIN)` commented out directly above the CSV endpoint, so a
  # comment-blind window matched the literal and reported the endpoint as GATED when it was wide
  # open. Caught only by replaying the script against pre-fix HEAD — `bash -n` and a post-fix green
  # run both miss it. This is the second time this exact false-green has appeared in this script
  # (see the note on B9); the helper is the right place to fix it once.
  grep -vE '^[[:space:]]*//' "$1" 2>/dev/null | grep -B"$3" -E "$2" | grep -qE "$4"
}

# Count only LIVE (non-commented) occurrences — same reasoning as annotated_within.
file_contains_n_live() {  # $1=regex $2=file $3=min-count
  [ -f "$2" ] || return 1
  local c; c=$(grep -vE '^[[:space:]]*//' "$2" | grep -cE "$1" 2>/dev/null || echo 0)
  [ "$c" -ge "$3" ]
}

echo; echo "SBDEV-2870 — ungated user-admin + damaged-lock endpoints"; echo "PROJECT_ROOT=$PROJECT_ROOT"; echo

# ---------------------------------------------------------------------------
echo "Fix A — Authority constants"
# ---------------------------------------------------------------------------
AUTH="$SRC/Authority.java"
run A1 "WMS_ADMIN_ROLE declared"                      file_contains 'WMS_ADMIN_ROLE\s*=\s*"wms_admin"' "$AUTH"
run A6 "actuator gate uses the constant, not a literal" file_contains 'hasAnyAuthority\("ADMIN", Authority\.WMS_ADMIN_ROLE\)' "$SRC/SecurityConfiguration.java"
# REVISED 2026-08-17 (owner: the CSV operator is SiteBoss staff, so that endpoint went to sb_admin).
# That left IS_WMS_ADMIN with zero references. A dead SpEL constant in a security class invites
# misuse, so it must STAY deleted — and per role-matrix §1.1 wms_admin gates /actuator/** only.
run A2 "IS_WMS_ADMIN is GONE [pin: vacuous pre-fix — never existed there]" \
                                                      file_not_contains 'IS_WMS_ADMIN\s*=' "$AUTH"
run A3 "  ... and nothing references it anywhere [pin: vacuous pre-fix]"     bash -c "
    ! grep -rqE '\bAuthority\.IS_WMS_ADMIN\b' '$SRC' '$TST' 2>/dev/null"
run A4 "WMS_ADMIN_ROLE has exactly ONE consumer (the actuator matcher)" bash -c "
    n=\$(grep -rE '\bAuthority\.WMS_ADMIN_ROLE\b' '$SRC' 2>/dev/null | wc -l); [ \"\$n\" -eq 1 ]"

# ---------------------------------------------------------------------------
echo; echo "Fix B1 — the CSV utility: the ONE @PreAuthorize gate, on sb_admin (STRUCTURE ONLY; see header)"
# ---------------------------------------------------------------------------
AC="$SRC/controller/AdminController.java"
UAC="$SRC/controller/UserAdministrationController.java"
UACT="$TST/unit/controller/UserAdministrationControllerUnitTest.java"

run B1 "importUsersFromCsvText gated on sb_admin (owner: the caller is SiteBoss staff)" \
        annotated_within "$AC" 'path\s*=\s*"/admin/importUsersFromCsvText"' 4 '@PreAuthorize\(Authority\.IS_SB_ADMIN\)'
# This restores what 5ac0262c commented out in 2024 — the ORIGINAL intent was already sb_admin.
run B2 "  ... so AdminController now has 9 LIVE IS_SB_ADMIN gates, up from 8" \
        file_contains_n_live '@PreAuthorize\(Authority\.IS_SB_ADMIN\)' "$AC" 9
# Nam Park's standing instruction: the CSV utility must not be tied to ANY FunctionEnum function.
run B3 "  ... and it is tied to NO function"       file_not_contains 'importUserWithCsv[\s\S]{0,400}doesUserHaveAccess' "$AC"
run B4 "no commented-out @PreAuthorize remains in AdminController" file_not_contains '^\s*//\s*@PreAuthorize' "$AC"
run B5 "AdminController holds no wms_admin gate at all [pin: vacuous pre-fix]" file_not_contains '@PreAuthorize\(Authority\.IS_WMS_ADMIN\)' "$AC"

# ---------------------------------------------------------------------------
echo; echo "Fix B2 — the 4 User Management endpoints, gated on the FUNCTION model"
# ---------------------------------------------------------------------------
run C1 "UserAdministrationController exists"        file_exists "$UAC"
run C2 "  ... gates on WEB_UI_VIEW_USER_MANAGEMENT" file_contains 'doesUserHaveAccess\(\s*WmsConstants\.FunctionEnum\.WEB_UI_VIEW_USER_MANAGEMENT' "$UAC"
run C3 "  ... throws AccessDeniedException (-> HTTP 403), not BusinessException (-> 422)" \
                                                    file_contains 'throw new AccessDeniedException' "$UAC"
run C4 "  ... constructor injection, per project convention (no @Autowired field)" bash -c "
    grep -qE 'public UserAdministrationController\(' '$UAC' \
      && grep -qE 'final AccessService accessService' '$UAC' \
      && ! grep -qE '@Autowired' '$UAC'"
run C5 "  ... NOT gated on wms_admin (the whole point of the redesign)" file_not_contains 'IS_WMS_ADMIN|WMS_ADMIN_ROLE' "$UAC"
# Anchored to column 0-ish: the javadoc legitimately DISCUSSES @PreAuthorize in prose, and an
# unanchored grep matched that text and failed a correct implementation.
run C6 "  ... no @PreAuthorize ANNOTATION here (it would be untestable)" file_not_contains '^\s*@PreAuthorize' "$UAC"

# The four endpoints moved OUT of AdminController. If any is re-added there it inherits into all 43
# subclasses again AND escapes the function gate, so assert absence explicitly.
for ep in addUserToWarehouseGroup removeUserFromWarehouseGroup isWarehouseUser existsInKeycloak; do
  run "C7-$ep" "  $ep lives ONLY in UserAdministrationController" bash -c "
      grep -qE '\"/user/$ep\"' '$UAC' && ! grep -qE '\"/user/$ep\"' '$AC'"
done

# THE load-bearing row: the guard must precede the try. Every one of the four wraps its body in
# catch (Exception e) -> 500, so a guard inside the try is swallowed into a 500 that leaks the
# reason instead of a 403. Tempered-greedy gap so this cannot match across a method boundary.
# NOTE on the regex: an earlier version used `ResponseEntity<[^>]+>`, which cannot match the nested
# generics these methods actually return (ResponseEntity<Map<String, String>>). It found ZERO
# bodies and the row failed on a correct implementation. Split on the method headers instead.
run C8 "each of the 4 calls the guard BEFORE its try block" bash -c "
    python3 - <<'EOF'
import re,sys
try: s=open('$UAC').read()
except OSError: sys.exit(1)
starts=[m.start() for m in re.finditer(r'\n    public ResponseEntity<.*?> \w+\(', s)]
if len(starts)!=4: sys.exit(1)
starts.append(len(s))
for i in range(4):
    b=s[starts[i]:starts[i+1]]
    body=b.split('{',1)[1] if '{' in b else ''
    stmts=[l.strip() for l in body.splitlines() if l.strip() and not l.strip().startswith('//')]
    if not stmts or not stmts[0].startswith('denyUnlessUserManagementAllowed()'): sys.exit(1)
    if 'try {' not in body: sys.exit(1)
    if body.index('denyUnlessUserManagementAllowed()') > body.index('try {'): sys.exit(1)
sys.exit(0)
EOF"

# ---------------------------------------------------------------------------
echo; echo "Behavioural tests — the thing @PreAuthorize could not have"
# ---------------------------------------------------------------------------
run T1 "deny test exists for each of the 4 endpoints" bash -c "
    f='$UACT'; [ -f \"\$f\" ] || exit 1
    for m in addUserToWarehouseGroupDenied removeUserFromWarehouseGroupDenied isWarehouseUserDenied existsInKeycloakDenied; do
      grep -q \"\$m\" \"\$f\" || exit 1
    done"
run T2 "  ... each asserts AccessDeniedException, i.e. propagation not a 500 body" \
        file_contains_n 'isInstanceOf\(AccessDeniedException\.class\)' "$UACT" 4
run T3 "  ... each asserts the service is never reached" file_contains_n 'verifyNoInteractions\(keycloakService\)' "$UACT" 4
run T4 "  ... a GRANTED path is also asserted (guards against deny-always)" \
        file_contains 'verify\(accessService, times\(1\)\)' "$UACT"
# A test file that exists but never runs proves nothing (SBDEV-2217 lane, @Nested -Dtest no-op).
# The '$' in the @Nested report filename must survive TWO levels of shell expansion; an ls glob
# with backslash escaping silently matched nothing and failed a passing test run. find -name with a
# single-quoted pattern has no such problem.
run T5 "the gate tests ACTUALLY RAN and passed in the last mvn run" bash -c "
    r=\$(find '$API/target/surefire-reports' -name '*UserAdministrationControllerUnitTest\$UserManagementFunctionGate.txt' 2>/dev/null | head -1)
    [ -n \"\$r\" ] || { echo 'no surefire report — run mvn test first' >&2; exit 1; }
    grep -qE 'Tests run: 7, Failures: 0, Errors: 0' \"\$r\""

# --- added after code review (M1, L1) ---------------------------------------
# T6: coverage must not depend on someone remembering to extend a hand-written list. The reflective
# test derives its subjects from the class, so a 5th unguarded handler cannot slip through green.
run T6 "a REFLECTIVE test asserts every handler is gated (not a hand-listed set)" bash -c "
    grep -q 'everyHandlerOnThisControllerIsGated' '$UACT' \
      && grep -q 'getDeclaredMethods' '$UACT' \
      && grep -qE 'hasSize\(4\)' '$UACT'"
# T7: the guard must reject the ANONYMOUS sentinel BEFORE the function read. getUserName() degrades
# to the literal "anonymous", which is a real mywms_user row on Hydra UAT (id 1) — fail-closed today
# is a per-tenant DATA fact, not a code property.
run T7 "the ANONYMOUS sentinel is rejected before the function is consulted" bash -c "
    grep -qE 'SecurityContextUtils\.ANONYMOUS\.equals\(username\)' '$UAC' \
      && grep -q 'anonymousSentinelDeniedWithoutReadingTheFunction' '$UACT' \
      && grep -q 'verifyNoInteractions(accessService)' '$UACT'"
# T8: SecurityContextHolder is thread-local and Surefire reuses threads — a leaked authenticated
# context is a classic false-green generator.
run T8 "tests clear the SecurityContext after each case" file_contains 'SecurityContextHolder\.clearContext\(\)' "$UACT"
# T9: the leak that made a full-suite-only failure. FileImportControllerTest binds a MOCK
# SecurityContext to the thread-local; unclearing it makes any later authorization test silently
# exercise the ANONYMOUS path while looking authenticated.
run T9 "FileImportControllerTest no longer leaks its mock SecurityContext" \
        file_contains 'SecurityContextHolder\.clearContext\(\)' "$TST/unit/controller/FileImportControllerTest.java"

# ---------------------------------------------------------------------------
echo; echo "Fix E — H1: the self-grant hole that defeated the gate (added 2026-08-17)"
# ---------------------------------------------------------------------------
# saveUserGroups rewrites mywms_group_mywms_user, the table doesUserHaveAccess traverses. Ungated,
# it let any wms_user grant themselves super-admin and walk back through all four Fix B endpoints.
UCC="$SRC/controller/UserController.java"
UCCT="$TST/unit/controller/UserControllerUnitTest.java"
run E1 "saveUserGroups is gated"                   file_contains 'denyUnlessUserManagementAllowed\(\)' "$UCC"
run E2 "  ... on the SAME function as the screen"  file_contains 'doesUserHaveAccess\(\s*WmsConstants\.FunctionEnum\.WEB_UI_VIEW_USER_MANAGEMENT' "$UCC"
run E3 "  ... throwing AccessDeniedException (-> 403)" file_contains 'throw new AccessDeniedException' "$UCC"
run E4 "  ... and it rejects the ANONYMOUS sentinel too" file_contains 'SecurityContextUtils\.ANONYMOUS\.equals\(username\)' "$UCC"
run E5 "  ... via constructor injection (UserController is a leaf, so no ripple)" bash -c "
    grep -qE 'AccessService accessService' '$UCC' && ! grep -qE '@Autowired' '$UCC'"
# THE load-bearing row: the guard must precede the DELETE, not merely exist. saveUserGroups deletes
# every existing group row before inserting, so a late guard still wipes the target's memberships.
run E6 "the guard precedes the first repository call in saveUserGroups" bash -c "
    python3 - <<'EOF'
import re,sys
try: s=open('$UCC').read()
except OSError: sys.exit(1)
m=re.search(r'public ResponseEntity<Object> saveUserGroups\(.*?\n    \}', s, re.S)
if not m: sys.exit(1)
b=m.group(0)
if 'denyUnlessUserManagementAllowed()' not in b: sys.exit(1)
if 'userGroupUserRepository' not in b: sys.exit(1)
sys.exit(0 if b.index('denyUnlessUserManagementAllowed()') < b.index('userGroupUserRepository') else 1)
EOF"
run E7 "deny tests exist AND assert nothing was deleted" bash -c "
    grep -q 'shouldDenyWithoutTheUserManagementFunction' '$UCCT' \
      && grep -q 'shouldDenyAnonymousWithoutReadingTheFunction' '$UCCT' \
      && grep -qE 'never\(\)\)\.delete' '$UCCT'"
run E8 "  ... and they ACTUALLY RAN (@Nested reports separately — a 0-run outer class hides them)" bash -c "
    r=\$(find '$API/target/surefire-reports' -name '*UserControllerUnitTest\$SaveUserGroups.txt' 2>/dev/null | head -1)
    [ -n \"\$r\" ] || { echo 'no surefire report — run mvn test first' >&2; exit 1; }
    grep -qE 'Tests run: 3, Failures: 0, Errors: 0' \"\$r\""
# NOTE: comment lines are stripped from the window on purpose. A commented-out
# "// @PreAuthorize(...)" contains the literal string and false-greened this row on the
# pre-fix tree — i.e. it was satisfied by exactly the defect the ticket exists to fix.
run B9 "no mapped method left without a LIVE @PreAuthorize" bash -c "
    python3 - <<'EOF'
import re,sys
p='$AC'
try: src=open(p).read().splitlines()
except OSError: sys.exit(1)
bad=[]
for i,l in enumerate(src):
    if re.match(r'\s*@(Get|Post|Put|Delete|Patch)Mapping|\s*@RequestMapping\((value|path)', l):
        win=[w for w in src[max(0,i-6):i] if not w.lstrip().startswith('//')]
        if not any('@PreAuthorize' in w for w in win): bad.append(i+1)
sys.exit(1 if bad else 0)
EOF"

# ---------------------------------------------------------------------------
echo; echo "Fix C / Fix D — RELOCATED to SBDEV-2967 (2026-08-17)"
# ---------------------------------------------------------------------------
# The damaged-lock gate and the X-Authz-Denied/CORS work moved to SBDEV-2967 Fix E.
# Assert they are ABSENT here, so a partial re-introduction on this branch is caught.
run R1 "damaged-lock gate NOT on this branch"        file_not_contains 'denyUnlessDamagedLockAllowed' "$SRC/controller/StockUnitController.java"
run R2 "AccessService NOT injected into StockUnitController" file_not_contains 'AccessService accessService' "$SRC/controller/StockUnitController.java"
run R3 "AUTHZ_DENIED_HEADER NOT declared here"        file_not_contains 'AUTHZ_DENIED_HEADER' "$SRC/Authority.java"
run R4 "no X-Authz-Denied CORS entry here"            file_not_contains 'AUTHZ_DENIED_HEADER' "$SRC/SecurityConfiguration.java"

# ---------------------------------------------------------------------------
echo; echo "Tests"
# ---------------------------------------------------------------------------
SUT="$TST/unit/controller/StockUnitControllerUnitTest.java"
SCT="$TST/unit/config/SecurityConfigurationTest.java"









# ---------------------------------------------------------------------------
echo; echo "Hygiene"
# ---------------------------------------------------------------------------
run H1 "archunit_store NOT modified (mvn test mutates it)" bash -c "
    cd '$API' 2>/dev/null || exit 0
    git diff --name-only -- 'src/test/resources/archunit_store' 2>/dev/null | grep -q . && exit 1 || exit 0"
run H2 "no new @Transactional (would bind the LANDLORD tm)" file_not_contains '^\s*@Transactional\s*$' "$AC"
run H3 "StockUnitController untouched by this branch"   bash -c "
    cd '$API' 2>/dev/null || exit 0
    git diff --name-only -- src/main/java/net/aim_ai/wms/controller/StockUnitController.java 2>/dev/null | grep -q . && exit 1 || exit 0"

# ---------------------------------------------------------------------------
echo; echo "Known-open — these SHOULD fail until the plan's §10 items are closed"
# ---------------------------------------------------------------------------
skip X1 "§10.1 AC-4 — DISSOLVED by the function-model redesign 2026-08-17: the gate now reads the
          same WEB_UI_VIEW_USER_MANAGEMENT that already grants the screen (39 live users via
          super-admin on WineCo dev), so there is no Keycloak group membership left to confirm."
skip X2 "§10.2 — PATCH /v3/stockunit/{id} SDR bypass; finding recorded here, gate now in SBDEV-2967"
skip X3 "MOVED to SBDEV-2967 §3.5.1 — class-wide lenient permissive stub caveat"
skip X4 "MOVED to SBDEV-2967 §3.5.1 — null-as-success caveat"
skip X5 "AC-5 — SATISFIED for the 4 User Management endpoints by rows T1-T5 (ablation-proven).
          Still open ONLY for /admin/importUsersFromCsvText, whose @PreAuthorize cannot be
          evaluated by any test in this repo — one curl, plan §6.3 M1."

echo
printf "Result: %d pass, %d fail, %d skip\n" "$PASS" "$FAIL" "$SKIP"
echo "NOTE: a green run proves STRUCTURE only. The 5 @PreAuthorize gates cannot be"
echo "      behaviourally tested in this repo — see the header and plan §6.1."
echo
[ "$FAIL" -eq 0 ]
