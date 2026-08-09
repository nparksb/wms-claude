#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# BASELINE LABEL — added 2026-08-08. A baseline without the state it was measured
# against expires silently, which is how SBDEV-2732 ended up instructing operators
# that >8 passes meant a vacuous check while its script returned 9 every run.
#
#   Measured: 5 pass, 32 fail, 51 skip
#   Against : v2/wms2-api develop 6bc709a, v2/wms2-web-ui develop 4ce39a1
#   State   : PRE-SBDEV-2732-Phase-1. The 51 skips are checks explicitly blocked on
#             2732's Phase 1-API / Phase 2-UI; they become live when those merge.
#
# This baseline expires on the SBDEV-2732 Phase-1 merge — re-record it then.
# Do not trust these numbers after that merge; re-measure.
#
# The 5 passes must all be preservation assertions about code that already exists.
# If that count rises without a corresponding implementation step, a check has gone
# vacuous: five did on 2026-08-08 (bare file_not_contains negatives against symbols
# present in zero files) and were conjoined. Check any new negative against that.
# ---------------------------------------------------------------------------
# verify-SBDEV-2643-sku-default-putaway-location-ui.sh
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2643-sku-default-putaway-location-ui.md
#
# Purpose
# -------
# Closes the over-claim gap: an executor (human or agent) can claim a phase is
# "DONE" without it actually being in the code. Every deliverable in the plan is
# encoded here as a grep assertion. Run after every implementation pass:
#
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#   WEB_UI_ROOT=/home/nampark/dev/wms-claude/v2/wms2-web-ui \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2643-sku-default-putaway-location-ui.sh
#
# Two roots, because SBDEV-2643 spans TWO repos. When verifying a per-ticket
# worktree, point BOTH at the worktree (or a symlink shadow root) or the script
# grades the main checkouts instead of the work.
#
# ============================================================================
# TEMPLATE FAIL-OPEN BUG — FIXED HERE. READ THIS BEFORE EDITING A HELPER.
# ============================================================================
# `sbdocs/9-System/templates/verify-plan-template.sh` ships assertion helpers
# built on `grep` / `perl -0777 -ne`. Both EXIT 0 WHEN THEY CANNOT OPEN THE
# FILE. Consequence: every multi-line assertion about a file that does not exist
# yet reports PASS. SBDEV-2643 CREATES SEVERAL NEW FILES
# (editSkuPutawayDialog.vue, putawayWording.js, SkuPutawayQueryServiceUnitTest,
# plus three Jest specs), so on today's tree the template's helpers would
# false-green all of them.
#
# FIX APPLIED: EVERY helper below begins with `[ -f "$2" ] || return 1` (or the
# positional equivalent). A missing file is a FAIL, never a PASS. Do not remove
# those guards, and do not add a helper without one.
#
# Second guard, for the negative helpers: `file_not_contains` on a missing file
# is doubly wrong — the construct is "absent" only because the file is absent.
# It carries the same existence check, so a negative check can never pass
# vacuously either.
#
# Other authoring rules honoured here
# -----------------------------------
# * Every deliverable gets at least one POSITIVE check (the new construct at the
#   right call site, matched by a specific class+method+arg regex).
# * Every replacement gets a NEGATIVE check (the old construct is gone).
# * No vacuous negatives; nothing asserts unreachable code.
# * Checks are grouped BY PHASE (A0 A1 A2 A3 B1 B2) so the output reads in
#   rollout order.
#
# HONESTY GATE — why a green run today does not mean "done"
# --------------------------------------------------------
# Almost every deliverable is blocked on SBDEV-2732, whose plan is `status:
# draft` and NONE of whose code is merged. Those checks are therefore gated
# behind an explicit block that reports **SKIP (blocked on SBDEV-2732)** rather
# than PASS, driven by `phase_2732_present`. Exit code is 0 only when every
# RUNNABLE check passes; the summary always names how many were skipped.
#
#   0 fail, N skip   =>  the runnable phases are done; N phases are still blocked.
#   0 fail, 0 skip   =>  this is the state the plan's §8.4 requires for closure.
#
# NEGATIVE-TEST THIS SCRIPT BEFORE TRUSTING IT (recorded landmine): replay the
# pre-fix tree and confirm the relevant checks FAIL. A "N pass, 0 fail" means
# nothing until you have watched it go red. See the SELF-TEST block at the end.
#
# ============================================================================
# REVISION 2 (2026-08-07) — WHAT CHANGED AND WHY
# ============================================================================
# 1. D1 REVERSED. The plan no longer offers pick faces behind an advisory
#    warning; it enforces SBDEV-2732's P2.7(c) and offers only the 92 eligible
#    locations. Consequences here:
#      - DELETED  A3-advis   (advisory field + PICK_FACE reason on a 2732 type)
#      - REPLACED B2-advis   -> B2-banner / B2-banner2: the dialog carries an
#                              ALWAYS-VISIBLE scope banner naming SBDEV-2821 AND
#                              SBDEV-2732, so an operator who cannot find their
#                              location learns why instead of concluding the
#                              search is broken (plan §3.8.2a).
# 2. THE 2732 GATE NO LONGER USES `[ -f ]`. It greps the CLASS DECLARATIONS, so
#    an empty or renamed file cannot pass it — and it ESCALATES SKIP -> FAIL once
#    `git log origin/develop --grep=SBDEV-2732` finds a merge. A merged-then-
#    renamed facade must not SKIP every 2732-blocked check forever while reporting "blocked";
#    that is contract drift (plan §11.1 PM1), not a blocked phase.
# 3. A0's CONSTANT SWAP IS OUT OF 2643's SCOPE. A 2643 PR must not revert a
#    security annotation that 2732 deliberately writes in 2732's own file.
#      - DELETED  A0-swap, A0-swap-neg  (they asserted 2643 edits 2732's file)
#      - ADDED    X-2732-authz    a PREREQUISITE PROBE, not a 2643 deliverable
#      - ADDED    A2-neg-badconst 2643's own new file never uses the constant
# 4. describeForSku MOVED to a 2643-OWNED service/SkuPutawayQueryService.java.
#      - A2-facade / A2-tx / A2-fsvc now target that file
#      - ADDED    A2-neg-2732file  it did NOT land in 2732's facade
# 5. A3 IS SPLIT BY ACCOUNTABILITY. D-D is handed to 2732 (plan D12), so 2643
#    cannot assert the shape of constructs it did not write. CONSUMER rows run
#    against 2643's own files; CONTRACT rows run only once the endpoint exists,
#    whoever shipped it.
# 6. THREE CHECKS WERE WEAKER THAN THEIR NAMES — strengthened:
#      - A2-env   named "7-field", asserted 4  -> asserts all 7
#      - B2-jest4 bare substring grep; PASSED if the spec asserted the opposite
#                 -> requires the `.not.`-first assertion form
#      - B1-jest2 grepped for "disabled", which any Vuetify spec contains
#                 -> anchored to isPutawayConfigAdmin + .exists() + attributes()
#    The required assertion forms are written into the plan's §7.2, so they are
#    specifiable rather than guessable.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
WEB_UI_ROOT="${WEB_UI_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"

[ -d "$PROJECT_ROOT" ] || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }
[ -d "$WEB_UI_ROOT" ]  || { echo "FATAL: WEB_UI_ROOT=$WEB_UI_ROOT not found";  exit 2; }

PASS=0
FAIL=0
SKIP=0

# --- paths (absolute, so no cd is needed and a wrong root fails loudly) -------

API="$PROJECT_ROOT/src/main/java/net/aim_ai/wms"
APITEST="$PROJECT_ROOT/src/test/java/net/aim_ai/wms"
UI="$WEB_UI_ROOT"

F_AUTHORITY="$API/Authority.java"
F_EXPR_ROOT="$API/CustomMethodSecurityExpressionRoot.java"
F_SEC_CONFIG="$API/SecurityConfiguration.java"
F_ITEMDATA_SVC="$API/service/ItemdataService.java"
F_ITEMDATA_CTL="$API/controller/ItemDataController.java"
F_VIEWDTO="$API/service/ViewDtoService.java"
F_QUERY_SVC="$API/service/PutawayDestinationQueryService.java"       # 2732 creates this
F_CFG_CTL="$API/controller/PutawayConfigController.java"             # 2732 creates this
F_CFG_SVC="$API/service/PutawayConfigService.java"                   # 2732 creates this
F_SKU_QUERY_SVC="$API/service/SkuPutawayQueryService.java"           # r2: 2643 OWNS this one
F_ITEMDATA_MODEL="$API/model/Itemdata.java"

T_EXPR_ROOT="$APITEST/unit/CustomMethodSecurityExpressionRootUnitTest.java"
T_ITEMDATA_SVC="$APITEST/unit/service/ItemdataServiceUnitTest.java"
T_ITEMDATA_CTL="$APITEST/unit/controller/ItemDataControllerUnitTest.java"
T_SKU_QUERY_SVC="$APITEST/unit/service/SkuPutawayQueryServiceUnitTest.java"
T_CFG_CTL="$APITEST/unit/controller/PutawayConfigControllerUnitTest.java"

V_SKUDATA="$UI/components/masterData/material/skuData/skuData.vue"
V_DIALOG="$UI/components/masterData/material/skuData/editSkuPutawayDialog.vue"
V_WORDING="$UI/components/masterData/material/skuData/putawayWording.js"
V_RECV_FORM="$UI/components/receiving/open/receive/receivingForm.vue"
V_FULLDETAILS="$UI/components/common/fullDetails.vue"
V_PICKER="$UI/components/common/LocationPicker.vue"                  # 2732 creates this
S_SKUDATA="$UI/store/masterData/skuData.js"
S_STORAGE_LOC="$UI/store/masterData/storageLocation.js"
S_PERSIST="$UI/plugins/persistedState.client.js"
J_SKUDATA="$UI/test/components/masterData/material/skuData/skuData.spec.js"
J_DIALOG="$UI/test/components/masterData/material/skuData/editSkuPutawayDialog.spec.js"
J_STORE="$UI/test/store/masterData/skuData.spec.js"
J_RECV_FORM="$UI/test/components/receiving/open/receive/receivingForm.spec.js"

# === runner ===================================================================

# run <id> <description> <command...>   — exit 0 => PASS, non-zero => FAIL
run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-14s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-14s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

# skip <id> <description> <reason>  — the check EXISTS but is not runnable yet.
# Deliberately NOT counted as a pass: a blocked phase must never read as done.
skip() {
    printf "  SKIP  %-14s  %s  (%s)\n" "$1" "$2" "$3"
    SKIP=$((SKIP+1))
}

# === assertion helpers — EVERY ONE existence-guarded (see header) =============

# file_contains <regex> <file>
file_contains() {
    [ -f "$2" ] || return 1
    grep -qE "$1" "$2"
}

# file_not_contains <regex> <file>   — a missing file FAILS, never passes vacuously
file_not_contains() {
    [ -f "$2" ] || return 1
    ! grep -qE "$1" "$2"
}

# file_contains_n_times <regex> <file> <n>
file_contains_n_times() {
    [ -f "$2" ] || return 1
    local count
    count=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$count" -ge "$3" ]
}

# multiline_contains <perl-regex> <file>
# Replaces the template's `perl -0777 -ne` helper, which EXITS 0 ON AN UNOPENABLE
# FILE. The explicit -f test in front is the whole point.
multiline_contains() {
    [ -f "$2" ] || return 1
    perl -0777 -ne "exit(/$1/s ? 0 : 1)" "$2"
}

# multiline_not_contains <perl-regex> <file>
multiline_not_contains() {
    [ -f "$2" ] || return 1
    perl -0777 -ne "exit(/$1/s ? 1 : 0)" "$2"
}

# file_exists <file>  — for NEW files, so their absence is a FAIL not a PASS
file_exists() { [ -f "$1" ]; }

# mvn_test_passes <TestClass>
# NOTE: -Dtest='Outer#method' silently no-ops for @Nested tests (false green) —
# always pass a CLASS name here, never Class#method.
mvn_test_passes() {
    [ -d "$PROJECT_ROOT" ] || return 1
    (cd "$PROJECT_ROOT" && mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0")
}

# === the SBDEV-2732 gate =====================================================
# Everything downstream of 2732 keys off this. It tests for the CONSTRUCTS, not
# for a merge message: a merged-then-reworked PR is the failure mode §11.1 PM1
# describes, and it would show a green checkmark.
#
# r2: this now GREPS THE CLASS DECLARATIONS. r1 used `[ -f ]`, which made the
# comment above untrue of the code below it — `[ -f ]` tests for FILES. Two
# consequences it had: (a) an EMPTY file passed the gate; (b) if 2732 landed with
# the facade renamed or relocated, the gate stayed false and every 2732-blocked check SKIPped
# FOREVER, reporting "blocked on SBDEV-2732" when the real state was "the
# contract drifted". (b) is closed by `contract_drift` below, not here.
phase_2732_present() {
    file_contains 'class[[:space:]]+PutawayDestinationQueryService' "$F_QUERY_SVC" \
      && file_contains 'class[[:space:]]+PutawayConfigController'   "$F_CFG_CTL" \
      && file_contains 'class[[:space:]]+PutawayConfigService'      "$F_CFG_SVC"
}
# The picker is a .vue SFC, so "the construct" is a component definition, not a
# class. An empty placeholder file must not pass.
phase_2732_ui_present() {
    file_contains '(export default|<template>)' "$V_PICKER"
}

# --- staleness escalation: SKIP is only honest while 2732 is genuinely unmerged.
# If a SBDEV-2732 merge IS on origin/develop but its constructs are absent from
# the tree being graded, "blocked" is the WRONG story — it is PM1 wearing a
# plausible face. Those rows FAIL and say why.
# r2 FIX — the first cut of this probe was `--grep='SBDEV-2732'` over ALL commits,
# which is a FALSE POSITIVE generator: any commit whose body merely *references* the
# ticket matches. Measured on 2026-08-07 it matched FOUR commits — 89de3f0, b623561
# (both SBDEV-2731) and a991c9e, a2bd0e9 (both SBDEV-2854) — none of them a 2732
# merge, all of them merely citing 2732 as a dependency. That escalated 73 correctly-
# blocked SKIPs into FAILs, i.e. the drift detector became the false signal this
# script exists to prevent.
#
# Narrowed to MERGE COMMITS whose subject carries a 2732 BRANCH name. GitHub writes
# "Merge pull request #133 from SiteBossInc/bugfix/SBDEV-2731-..." (verified shape on
# this repo's develop), so a branch-qualified match cannot be tripped by a body
# reference. --merges alone is not enough: a merge of a branch that merely mentions
# 2732 in its body would still match.
#
# ⚠ SECOND NARROWING BUG, caught by negative-testing the narrowing itself: an
# explicit prefix allow-list of (feature|bugfix|fix|hotfix) MISSES this repo's real
# branch names. Measured on origin/develop 2026-08-07, the last 12 merges used FIVE
# prefixes — bugfix, feature, chore, hotfix and **claude** — and the three `claude/`
# ones spell the ticket in LOWERCASE (`claude/sbdev-2801-report-500-utkj8x`). A 2732
# PR merged from `claude/sbdev-2732-...` would have gone undetected, i.e. the
# escalation this function exists for would silently not fire. So: match any branch
# SEGMENT, case-insensitively, and keep only the `from <owner>/<branch>` anchor —
# that anchor is what makes it branch-qualified rather than a body grep.
git_has_2732_merge() {   # $1 = repo root
    [ -d "$1/.git" ] || return 1
    # NO -N WINDOW (Critic F-3). The first cut read `-50`, which made the probe
    # SILENTLY EXPIRE: once 50 merges land after 2732's, it stops matching and every
    # downstream row reverts to "SKIP (blocked on SBDEV-2732)" — the exact fail-quiet
    # SHOULD-8 closed, merely deferred. Measured on wms2-api 2026-08-07: 192 merges on
    # develop, the 50th-most-recent dated 2026-07-09 — a ~29-day window. 2643's B2 is
    # the last of six phases across two repos and hard-blocks on 2732's Phase 2-UI, so
    # a >29-day gap is entirely plausible. Scanning all merges is monotonic and cheap.
    (cd "$1" && git log origin/develop --merges --format=%s 2>/dev/null) \
        | grep -qiE 'from [^ ]*/[^ ]*sbdev-2732'
}
origin_develop_resolvable() {   # $1 = repo root
    [ -d "$1/.git" ] || return 1
    (cd "$1" && git rev-parse --verify --quiet origin/develop >/dev/null 2>&1)
}
contract_drift() {
    if ! phase_2732_present && git_has_2732_merge "$PROJECT_ROOT"; then return 0; fi
    if ! phase_2732_ui_present && git_has_2732_merge "$WEB_UI_ROOT";  then return 0; fi
    return 1
}
# blocked <id> <description> <reason>
# SKIP when 2732 is genuinely unmerged; FAIL when it is merged but absent.
blocked() {
    if contract_drift; then
        printf "  FAIL  %-14s  %s  (CONTRACT DRIFT: a SBDEV-2732 merge is on origin/develop but its constructs are ABSENT here — this is PM1, not 'blocked')\n" "$1" "$2"
        FAIL=$((FAIL+1))
    else
        skip "$1" "$2" "$3"
    fi
}
# V2.2.11 is 2732's migration. 2643 ships ZERO migrations, so this is a
# dependency probe only — never an assertion about 2643's own work.
migration_2211_present() {
    ls "$PROJECT_ROOT/src/main/resources/db/migration/" 2>/dev/null | grep -q '^V2\.2\.11__'
}

# === A0 — repair the authorization expression (§3.1, D2) ======================

# POSITIVE: the detector test EVALUATES a SpEL string against a real expression
# root. A direct isAimAdmin() call cannot catch this class of defect — which is
# exactly why F1 survived 9 broken endpoints with a green test suite.
check_A0_spel_evaluated() {
    multiline_contains 'SpelExpressionParser.*?parseExpression\s*\(\s*Authority\.' "$T_EXPR_ROOT"
}
check_A0_evaluates_against_real_root() {
    multiline_contains 'new\s+CustomMethodSecurityExpressionRoot\s*\(.*?parseExpression' "$T_EXPR_ROOT" \
      || multiline_contains 'parseExpression.*?StandardEvaluationContext' "$T_EXPR_ROOT"
}
# POSITIVE: the bare-authority form is asserted, consistent with
# CustomMethodSecurityExpressionHandler.java:19 setDefaultRolePrefix(null).
check_A0_bare_authority_asserted() {
    file_contains "hasAuthority\('sb_admin'\)" "$T_EXPR_ROOT"
}
# CONTEXT (must stay true): the broken constant is still present and untouched.
# 2643 does NOT repair Authority.java — SBDEV-2863 owns that. If this FAILS,
# someone silently changed shared security wiring; go read §3.1 before merging.
check_A0_authority_constant_untouched() {
    file_contains 'IS_SB_ADMIN\s*=\s*"isSbAdmin\(\)"' "$F_AUTHORITY"
}
# CONTEXT: isAimAdmin() is still the only admin predicate on the root — i.e. no
# one "fixed" F1 by aliasing isSbAdmin() onto shared wiring (rejected option (a)).
check_A0_no_alias_added_to_root() {
    file_not_contains 'boolean\s+isSbAdmin\s*\(' "$F_EXPR_ROOT"
}
# r2: check_A0_writers_use_fixed_expression / check_A0_writers_drop_broken_constant
# were DELETED. They asserted that 2643 REMOVES @PreAuthorize(Authority.IS_SB_ADMIN)
# from PutawayConfigService.java — a line SBDEV-2732 §3.5/§3.9/§3.12 deliberately
# WRITES (2732 :905, :917, :925, :1491, and :972/:978/:985 on the controller). A
# 2643 PR reverting a 2732 security annotation in 2732's own file, days after 2732's
# review approved it, is the wrong home for that change.
#
# What replaces them:
#   - X-2732-authz    (cross-cutting) a PREREQUISITE PROBE. It fails if 2732's file
#                     lands still carrying the broken constant — the finding is
#                     preserved, the ownership is not claimed. Plan §5.1 row 0e.
#   - A2-neg-badconst 2643's OWN new file must never use the constant.
# The detector test above remains 2643's, and is the high-value half.

# === A1 — putawayLocationId in the details payload (§3.3, D-C) ================

# POSITIVE: the id key is emitted from getItemdataDetails.
check_A1_id_key_emitted() {
    file_contains 'details\.put\("putawayLocationId",\s*i\.getPutawaylocationId\(\)\)' "$F_ITEMDATA_SVC"
}
# POSITIVE: it is emitted OUTSIDE the FK-resolution guard, so a dangling FK still
# yields the id — that asymmetry IS the AC8 signal (§3.3). Asserts the id put
# precedes the findById on the same non-null branch.
check_A1_id_outside_fk_guard() {
    multiline_contains 'getPutawaylocationId\(\)\s*!=\s*null.*?details\.put\("putawayLocationId".*?locationRepository\.findById' \
        "$F_ITEMDATA_SVC"
}
# POSITIVE: the name key is unchanged in meaning — still only on a resolved FK.
check_A1_name_still_fk_guarded() {
    multiline_contains 'locationRepository\.findById.*?details\.put\("putawayLocation",' "$F_ITEMDATA_SVC"
}
# NEGATIVE: the details read must keep using the repository, NOT the @Cacheable
# getById. §7.4 rows 5/9 depend on this for read-after-write freshness across
# replicas; a future "optimisation" to getById would silently break it.
check_A1_uses_repo_findbyid() {
    multiline_contains 'getItemdataDetails\(Long id\)\s*\{\s*Itemdata i\s*=\s*itemdataRepository\.findById' \
        "$F_ITEMDATA_SVC"
}
# NEGATIVE: no transaction annotation was bolted onto getItemdataDetails, and the
# MANDATORY resolver was NOT called from here (F5).
check_A1_no_resolver_in_itemdata_service() {
    # CONJOINED 2026-08-08. Was a bare negative: 'putawayDestinationResolver' exists in ZERO files
    # (SBDEV-2732 has not shipped it), so "absent from ItemdataService" was trivially true and stayed
    # true no matter what was implemented. It would have gone on passing after a wrong implementation.
    # Require this plan's OWN work to be present first, so the negative only speaks once there is
    # something to speak about.
    file_contains 'putawayLocationId' "$F_ITEMDATA_SVC" \
      && file_not_contains 'putawayDestinationResolver' "$F_ITEMDATA_SVC"
}
# POSITIVE: the four existing tests were updated, not bypassed.
check_A1_test_asserts_id_present() {
    file_contains 'putawayLocationId' "$T_ITEMDATA_SVC"
}
check_A1_test_asserts_dangling_fk_signal() {
    multiline_contains 'containsKey\("putawayLocationId"\).*?doesNotContainKey\("putawayLocation"\)' "$T_ITEMDATA_SVC" \
      || multiline_contains 'doesNotContainKey\("putawayLocation"\).*?containsKey\("putawayLocationId"\)' "$T_ITEMDATA_SVC"
}
check_A1_test_asserts_null_id_omits_both() {
    multiline_contains 'doesNotContainKey\("putawayLocationId"\)' "$T_ITEMDATA_SVC"
}

# === A2 — the effective-destination read (§3.2 D-A, §3.4 D-B) ================

# POSITIVE: describeForSku exists in 2643's OWN service, with BOTH transaction
# clauses. r2/D13: it is NOT added to 2732's PutawayDestinationQueryService — the
# Propagation.MANDATORY rule needs *a* transactional bean between controller and
# resolver, not *2732's* bean, and owning the file turns a three-way merge into a
# compile error.
check_A2_facade_method() {
    file_contains 'Resolution\s+describeForSku\s*\(\s*Long' "$F_SKU_QUERY_SVC"
}
check_A2_facade_txmgr_and_readonly() {
    multiline_contains 'Transactional\(\s*value\s*=\s*"tenantTransactionManager"\s*,\s*readOnly\s*=\s*true\s*\)\s*(?:public\s+)?[^;{]*describeForSku' \
        "$F_SKU_QUERY_SVC"
}
# POSITIVE: the 2643-owned service is where the resolver call lives. Without this,
# A2-neg-res (resolver absent from the controller) could be satisfied by not
# calling the resolver at all.
check_A2_service_calls_resolver() {
    file_contains 'putawayDestinationResolver' "$F_SKU_QUERY_SVC"
}
# NEGATIVE — the D13 boundary, enforced rather than merely intended: describeForSku
# must NOT have been added to 2732's facade.
check_A2_neg_not_in_2732_facade() {
    # CONJOINED 2026-08-08 — 'describeForSku' exists in zero files; bare negative was vacuous.
    # The property worth asserting is that 2643's OWN service carries the method and 2732's facade
    # does not, i.e. the two are not both implementing it. Assert presence here, absence there.
    file_contains 'describeForSku' "$F_SKU_QUERY_SVC" \
      && file_not_contains 'describeForSku' "$F_QUERY_SVC"
}
# r2 (MUST-5): 2643's OWN new file must never adopt the broken constant. This is the
# half of the F1 finding 2643 legitimately owns — it constrains 2643's code, not 2732's.
# The effective-destination read is deliberately NOT admin-gated at all (plan §3.4),
# so the constant has no business appearing here under any spelling.
check_A2_neg_no_bad_constant() {
    file_not_contains 'Authority\.IS_SB_ADMIN' "$F_SKU_QUERY_SVC"
}
# r2 (MUST-5): PREREQUISITE PROBE, not a 2643 deliverable. Plan §5.1 row 0e says 2732
# must not merge carrying @PreAuthorize(Authority.IS_SB_ADMIN) — the constant names a
# SpEL method that does not exist (F1), so every admin-gated 2732 write would return
# 500 for everyone, sb_admin included. 2643 does NOT fix this (wrong home: it is 2732's
# own file). It DETECTS it, so the finding cannot be lost. A FAIL here is a message to
# 2732's reviewer / SBDEV-2863, not a defect in 2643.
check_X_2732_not_merged_with_broken_constant() {
    file_not_contains 'PreAuthorize\(Authority\.IS_SB_ADMIN\)' "$F_CFG_SVC"
}
# POSITIVE: the endpoint exists at the right path on the right controller.
check_A2_endpoint_mapping() {
    file_contains 'GetMapping\(path\s*=\s*"/\{id\}/effectivePutawayDestination"' "$F_ITEMDATA_CTL"
}
# POSITIVE: the handler delegates to the facade.
check_A2_delegates_to_facade() {
    file_contains 'skuPutawayQueryService\.describeForSku' "$F_ITEMDATA_CTL"
}
# NEGATIVE — D-F, the single most important check in this script.
# PutawayDestinationResolver.resolve is Propagation.MANDATORY and there is ZERO
# @Transactional anywhere under controller/, so a direct call raises
# IllegalTransactionStateException (a bare RuntimeException) => 500 on EVERY
# call. Without this row an implementer satisfies every positive check by adding
# the facade AND STILL calling the resolver from the controller.
# CONJOINED 2026-08-08 — both were bare negatives against a symbol existing in zero files.
# Gate them on this plan's own controller work being present, so they fail closed until then.
check_A2_neg_resolver_absent_from_controller() {
    file_contains 'skuPutawayQueryService' "$F_ITEMDATA_CTL" \
      && file_not_contains 'putawayDestinationResolver' "$F_ITEMDATA_CTL"
}
check_A2_neg_resolver_type_absent_from_controller() {
    file_contains 'skuPutawayQueryService' "$F_ITEMDATA_CTL" \
      && file_not_contains 'PutawayDestinationResolver' "$F_ITEMDATA_CTL"
}
# NEGATIVE: a putaway-config read must never touch the OMS notification path.
# Scoped to the new handler's body, because ItemDataController legitimately holds
# httpRestService for sendStockUpdate (:97-98) — a file-wide grep would be a
# false FAIL.
check_A2_neg_no_oms_in_handler() {
    multiline_contains 'effectivePutawayDestination\s*\([^)]*\)[^{]*\{(?:(?!httpRestService)(?!\n\s{4}\})[\s\S])*?\n\s{4}\}' \
        "$F_ITEMDATA_CTL"
}
# POSITIVE: the 7-field envelope is mapped, with `source` as the ENUM NAME.
# r2: this row was named "seven_fields" and asserted FOUR. A four-field envelope
# would have passed it while the UI silently lost `source` (the field 2732 §3.8
# exists to stop Vue re-deriving precedence) and `locationId` (what the picker
# pre-selects with). All seven are asserted now.
# `source` is matched with a word boundary so `sourceLabel` cannot satisfy it.
check_A2_envelope_seven_fields() {
    file_contains '"locationId"'   "$F_ITEMDATA_CTL" \
      && file_contains '"locationName"'  "$F_ITEMDATA_CTL" \
      && file_contains '"source"'        "$F_ITEMDATA_CTL" \
      && file_contains '"sourceLabel"'   "$F_ITEMDATA_CTL" \
      && file_contains '"configuredFor"' "$F_ITEMDATA_CTL" \
      && file_contains '"compatible"'    "$F_ITEMDATA_CTL" \
      && file_contains '"warning"'       "$F_ITEMDATA_CTL"
}
# POSITIVE: the new tests live in a NEW nested class, not inside 2732's
# @Nested SetPutAwayLocation at :119-158 (R2's merge-conflict mitigation).
check_A2_new_nested_test_class() {
    file_contains 'class\s+EffectivePutawayDestination' "$T_ITEMDATA_CTL"
}
check_A2_asserts_source_is_enum_name() {
    file_contains 'SKU_OVERRIDE' "$T_ITEMDATA_CTL"
}
check_A2_facade_unit_test_exists() { file_exists "$T_SKU_QUERY_SVC"; }
check_A2_facade_test_covers_sku() {
    file_contains 'describeForSku' "$T_SKU_QUERY_SVC"
}
# CONTEXT: SecurityConfiguration must NOT be widened for the new endpoint.
check_A2_security_config_unwidened() {
    file_contains 'hasAnyAuthority\("wms_user"\)' "$F_SEC_CONFIG" \
      && file_not_contains 'effectivePutawayDestination' "$F_SEC_CONFIG"
}

# === A3 — the eligible-locations read (§3.5, D-D / D3) =======================
#
# r2 / plan D12: D-D is SPECIFIED in the plan but HANDED TO 2732. A3 is 2643's
# named fallback, not its plan of record. 2643 therefore cannot assert the shape
# of constructs it did not write, and these rows are split accordingly:
#
#   CONSUMER rows  — asserted against 2643's OWN files. These are what 2643 is
#                    accountable for whoever ships the endpoint.
#   CONTRACT rows  — run only once the endpoint EXISTS, whoever shipped it. They
#                    are properties any correct implementation must have.
#
# DELETED in r2: check_A3_advisory_and_pick_face. It asserted a 2643-specific
# `advisory` field and a PICK_FACE extension to 2732's blockingReason enum — both
# were D1's apparatus, and both were undeclared mutations of a 2732-owned type.
# With D1 reversed a row is eligible or it is not offered; there is no third class.

dd_endpoint_present() { file_contains 'eligibleLocations' "$F_CFG_CTL"; }

check_A3_endpoint_mapping() {
    file_contains 'GetMapping\("/eligibleLocations"\)' "$F_CFG_CTL"
}
check_A3_scope_param() {
    file_contains 'PutawayScope\s+scope' "$F_CFG_CTL"
}
check_A3_readonly_tenant_tx() {
    multiline_contains 'Transactional\(\s*value\s*=\s*"tenantTransactionManager"\s*,\s*readOnly\s*=\s*true\s*\)[\s\S]{0,400}?eligibleLocations' \
        "$F_CFG_CTL"
}
# NEGATIVE — D1 (r2): no 2643-specific classification was bolted onto 2732's type.
# `advisory` and PICK_FACE existed only to carry the reversed D1.
check_A3_neg_no_advisory_class() {
    file_not_contains '(PICK_FACE|"advisory")' "$F_CFG_CTL"
}
# --- CONSUMER rows: 2643's own files, asserted whoever owns the producer -------
# The picker's items come from the eligibility endpoint, not from a client-side
# filter over some other payload.
check_A3_consumer_sources_from_endpoint() {
    file_contains 'putawayConfig/eligibleLocations' "$S_SKUDATA" \
      || file_contains 'putawayConfig/eligibleLocations' "$V_DIALOG"
}
# NEGATIVE — D3 / §14 principle 2, and NON-VACUOUS: it first requires the dialog to
# exist, then asserts it names no predicate. A bare "no predicate names present"
# would pass trivially against a file that does not exist yet (and file_not_contains
# would in fact FAIL then — but the two-part form documents the intent and survives
# a future helper change).
check_A3_neg_no_client_side_predicates() {
    file_exists "$V_DIALOG" \
      && file_not_contains '(useforpicking|useforgoodsin|useforstorage|entityLock|staginglane|crossdockinglane|fix_location_assignment)' "$V_DIALOG"
}
# NEGATIVE — D3: getLocationView() was NOT widened. Assert the projection still
# has exactly its 8 original keys and none of the eligibility fields.
check_A3_neg_locationview_unwidened() {
    file_not_contains 'dto\.put\("useforgoodsin"' "$F_VIEWDTO" \
      && file_not_contains 'dto\.put\("useforpicking"' "$F_VIEWDTO" \
      && file_not_contains 'dto\.put\("staginglane"' "$F_VIEWDTO" \
      && file_not_contains 'dto\.put\("entityLock"' "$F_VIEWDTO"
}
# NEGATIVE: the stockunit-driven repository method must NOT back the picker.
check_A3_neg_not_backed_by_storage_query() {
    file_not_contains 'getStorageLocationsForPutAwayItemData' "$F_CFG_CTL"
}
# POSITIVE: the tier-4 lane is excluded, compared against the MACHINE NAME
# constant (never the spaced display label) — Q3/D8.
check_A3_excludes_tier4_lane() {
    file_contains 'STORAGE_LOCATION_PUTAWAY_LANE' "$F_CFG_CTL"
}
# r3 (Critic F-9): was a bare substring grep for `eligibleLocations` under the label
# "controller test covers eligibleLocations" — satisfied by the string appearing
# anywhere, including an import or a comment. §13 claims the CONTRACT-side rows
# "assert properties any correct implementation must have", and a substring is not
# one. Now requires the named §7.1 test method, so the row means what its label says.
# (If D12's hand-over to 2732 holds, A3 never runs and this is a fallback-only row —
# but a fallback row that cannot fail is still worthless.)
check_A3_test_two_classes() {
    file_contains 'eligibleLocationsSkuScopeTwoClasses' "$T_CFG_CTL"
}
check_A3_test_fix_assigned_stays_blocked() {
    file_contains 'FIX_ASSIGNED' "$T_CFG_CTL"
}

# === B1 — the SKU screen surface (§3.7, §3.8.1, §3.11) ======================

# POSITIVE — the §6.1 mitigation. Without this, A1 renders a raw integer row
# labelled "PutawayLocationId" on every SKU details overlay.
check_B1_exclude_fields_has_id() {
    file_contains "exclude-fields=\"\['id',\s*'itemNr',\s*'version',\s*'putawayLocationId'\]\"" "$V_SKUDATA" \
      || multiline_contains "exclude-fields=\"\[[^\]]*'putawayLocationId'[^\]]*\]\"" "$V_SKUDATA"
}
check_B1_relabelled() {
    file_contains "'putawayLocation':\s*'Default Putaway Location'" "$V_SKUDATA"
}
check_B1_old_label_gone() {
    file_not_contains "'putawayLocation':\s*'Putaway Location'" "$V_SKUDATA"
}
# POSITIVE: the pencil affordance was added to the EXISTING active actions
# column, which already ships the eye button (C2).
#
# ⚠ FALSE-POSITIVE TRAP, found by negative-testing this script: a bare
# `item.actions .* mdi-eye-outline .* mdi-pencil-outline` multiline match PASSES
# on the UNMODIFIED tree, because the regex spans from the active template
# (:95-99, the eye) into the COMMENTED corpse (:100-123, which contains a
# pencil). It reported PASS before a line of B1 was written.
#
# The discriminator: the corpse's pencil is `<v-btn tile icon depressed>` with NO
# @click. A real affordance must carry a click handler. Requiring @click on the
# same v-btn as the pencil icon cannot match the corpse. Do not relax this back
# to an icon-only grep.
check_B1_pencil_in_actions_column() {
    multiline_contains '<v-btn[^>]*@click=[^>]*>\s*<v-icon>mdi-pencil-outline' "$V_SKUDATA"
}
# POSITIVE: the overlay's existing #actions slot hosts the second entry point,
# with zero changes to fullDetails.vue.
check_B1_uses_fulldetails_actions_slot() {
    file_contains '(v-slot:actions|#actions|slot="actions")' "$V_SKUDATA"
}
check_B1_fulldetails_untouched() {
    file_contains '<slot name="actions"></slot>' "$V_FULLDETAILS" \
      && file_not_contains 'putaway' "$V_FULLDETAILS"
}
# NEGATIVE: the commented pencil/trash/menu corpse at :100-123 is gone, and the
# trash button and "Something" menu were NOT resurrected.
check_B1_neg_corpse_deleted() {
    file_not_contains 'mdi-trash-can-outline' "$V_SKUDATA" \
      && file_not_contains 'mdi-dots-vertical' "$V_SKUDATA" \
      && file_not_contains 'Something 2' "$V_SKUDATA"
}
# POSITIVE: the permission gate exists, consumes nuxt.config.js:167's
# appAdminGroup for the FIRST time, and is applied as :disabled — never v-if.
check_B1_permission_computed() {
    file_contains 'isPutawayConfigAdmin' "$V_SKUDATA"
}
check_B1_consumes_app_admin_group() {
    file_contains 'appAdminGroup' "$V_SKUDATA"
}
check_B1_gate_is_disabled_not_vif() {
    multiline_contains ':disabled="!\s*isPutawayConfigAdmin' "$V_SKUDATA"
}
# NEGATIVE, non-vacuous. A bare "v-if=isPutawayConfigAdmin is absent" passes
# trivially while the computed does not exist at all — it would have reported PASS
# before B1 was written. So the check first REQUIRES the computed to exist, then
# asserts it is not used as a v-if. D10: read-only users may VIEW.
check_B1_neg_gate_not_vif() {
    file_contains 'isPutawayConfigAdmin' "$V_SKUDATA" \
      && file_not_contains 'v-if="!?\s*isPutawayConfigAdmin' "$V_SKUDATA"
}
# POSITIVE — §3.7: the 2731 wording constants were EXTRACTED to a shared module
# rather than copy-pasted a third time, and receivingForm.vue now imports them.
check_B1_wording_module_exists() { file_exists "$V_WORDING"; }
check_B1_wording_module_has_both_constants() {
    file_contains "DEFAULT_PUTAWAY_LANE_NAME\s*=\s*'PutAwayLane'" "$V_WORDING" \
      && file_contains "DEFAULT_PUTAWAY_LANE_LABEL\s*=\s*'Put Away Lane'" "$V_WORDING"
}
check_B1_recv_form_imports_shared() {
    file_contains 'import\s*\{[^}]*DEFAULT_PUTAWAY_LANE_NAME' "$V_RECV_FORM"
}
# NEGATIVE: receivingForm.vue no longer DECLARES the constants (no third copy).
check_B1_neg_recv_form_no_local_const() {
    file_not_contains "^const DEFAULT_PUTAWAY_LANE_NAME\s*=" "$V_RECV_FORM"
}
# CONTEXT — §3.8.5: no exclusion was added to persistedState. The overlay is
# safe because skuData.vue always refetches, and D5 means there is no column.
check_B1_persistedstate_untouched() {
    file_not_contains 'skuData' "$S_PERSIST"
}
# CONTEXT — D5: no table column was added.
check_B1_neg_no_table_column() {
    multiline_not_contains "headers[\s\S]{0,600}?Default Putaway Location" "$V_SKUDATA"
}
check_B1_jest_spec_exists() { file_exists "$J_SKUDATA"; }
# r2: this row used to be `file_contains 'disabled'`, which ANY Vuetify spec
# satisfies — the word appears in props, attrs and fixtures all over the repo, so
# the row could not distinguish "asserts disabled-not-hidden" from "mentions a
# Vuetify component". Anchored now to the three things the assertion must actually
# do (plan §7.2's REQUIRED ASSERTION FORM):
#   (a) name the computed under test,
#   (b) prove PRESENCE with .exists()  — this is the "not hidden" half, and it is
#       the half D10 turns on: read-only users may VIEW,
#   (c) read the real attribute/prop rather than matching rendered text.
check_B1_jest_asserts_disabled_not_hidden() {
    file_contains 'isPutawayConfigAdmin' "$J_SKUDATA" \
      && file_contains '\.exists\(\)' "$J_SKUDATA" \
      && file_contains "\.(attributes|props)\(\s*['\"]disabled['\"]" "$J_SKUDATA"
}

# === B2 — the edit dialog and the write (§3.8.2, §3.8.3) ====================

check_B2_dialog_exists() { file_exists "$V_DIALOG"; }
# POSITIVE: the dialog reuses 2732's picker rather than rolling a second one (D6).
check_B2_dialog_uses_shared_picker() {
    file_contains '(LocationPicker|location-picker)' "$V_DIALOG"
}
# r2 (D1 reversal): replaces the deleted check_B2_advisory_banner_names_ticket.
# r1 warned per-row on pick faces; r2 removes those rows entirely, so the failure
# mode inverts — an operator types "ICE", gets nothing, and concludes the search is
# broken. Plan §3.8.2a makes the ALWAYS-VISIBLE scope banner a deliverable and
# requires it to name BOTH the unblocking ticket and the design decision, so the
# restriction is traceable rather than folklore.
check_B2_scope_banner_names_unblocking_ticket() {
    file_contains 'SBDEV-2821' "$V_DIALOG"
}
check_B2_scope_banner_names_design_decision() {
    file_contains '(SBDEV-2732|2732 Q9)' "$V_DIALOG"
}
# r2 (Critic F-1, BLOCKING): the banner must state the eligible count, and §3.8.2a
# requires it COMPUTED from the eligibleLocations response — never a literal. 92 and
# 666 are measurements of wh01_hydra_v2 on 2026-08-07; they are wrong for every other
# tenant and for hydra DEV itself after any location is added. A banner that is
# confidently wrong is a worse failure than the silent one it exists to prevent
# (inverts §14 principle 4). B2-banner/B2-banner2 grep only for ticket strings, so a
# literal count sailed through every other gate in the plan.
check_B2_banner_count_not_hardcoded() {
    file_not_contains '\b(92|666)\b' "$V_DIALOG"
}
# POSITIVE: hand-rolled validated() + $toast, per the editPackagingDialog idiom.
check_B2_dialog_handrolled_validation() {
    file_contains 'validated\s*\(' "$V_DIALOG" && file_contains '\$toast\.error' "$V_DIALOG"
}
# NEGATIVE: no v-form/rules and no Vuelidate — the repo has no such idiom here.
check_B2_neg_no_vform_rules() {
    file_not_contains '(<v-form|:rules=|vuelidate|validations\s*:)' "$V_DIALOG"
}
# NEGATIVE: the removed pick-face rows were not smuggled back in client-side, and
# no 2643-specific "advisory" classification survives in the dialog.
check_B2_neg_no_advisory_state() {
    file_not_contains '(PICK_FACE|advisory)' "$V_DIALOG"
}
# POSITIVE: the Clear affordance exists.
check_B2_clear_affordance() {
    file_contains '(Clear|Use default)' "$V_DIALOG"
}
# POSITIVE: the write action targets 2732's validated endpoint.
check_B2_store_targets_putawayconfig() {
    file_contains '\$put\(`?/putawayConfig/sku/' "$S_SKUDATA"
}
# NEGATIVE — the headline UI check. The legacy GET is unvalidated, unaudited,
# the wrong verb, and its @CacheEvict(allEntries=true) flushes EVERY tenant.
check_B2_neg_no_legacy_endpoint() {
    file_not_contains 'setPutAwayLocation' "$S_SKUDATA"
}
check_B2_neg_no_legacy_in_dialog() {
    file_not_contains 'setPutAwayLocation' "$V_DIALOG"
}
# POSITIVE: Clear OMITS the query parameter entirely (2732 §3.5a: omitted => clear).
# Sending ?locationId= or ?locationId=null would not clear.
check_B2_clear_omits_param() {
    multiline_contains 'locationId\s*==\s*null\s*\?\s*'"''"'\s*:' "$S_SKUDATA"
}
check_B2_neg_no_null_in_querystring() {
    file_not_contains 'locationId=\$\{?(null|data\.locationId\s*\|\|)' "$S_SKUDATA"
}
# POSITIVE: 422/409 bodies reach the operator. A bare "network or server issue"
# toast hides every validation message the ticket asks to be actionable.
check_B2_surfaces_response_body() {
    file_contains 'response(\?)?\.data' "$S_SKUDATA"
}
# POSITIVE: read-after-write refetches THIS SKU, not the whole table.
check_B2_refetches_detail() {
    file_contains "dispatch\('getSkuDetail'" "$S_SKUDATA"
}
check_B2_neg_does_not_repage_table() {
    multiline_not_contains "setSkuPutawayLocation[\s\S]{0,900}?dispatch\('searchSkuData'" "$S_SKUDATA"
}
# POSITIVE: the effective-destination read action exists and hits the new endpoint.
check_B2_effective_read_action() {
    file_contains 'effectivePutawayDestination' "$S_SKUDATA"
}
# CONTEXT — D3: the picker did NOT go back to /location/detailView client-side.
check_B2_neg_not_detailview_backed() {
    file_not_contains 'location/detailView' "$V_DIALOG"
}
# CONTEXT — D3: storageLocation store untouched.
check_B2_storage_store_untouched() {
    # CONJOINED 2026-08-08 — 'eligibleLocations' exists in zero files, so "absent from the existing
    # storageLocation store" was trivially true. The real property is that the NEW skuData store owns
    # it and the pre-existing store is left alone: assert presence in one, absence in the other.
    file_contains 'eligibleLocations' "$S_SKUDATA" \
      && file_not_contains 'eligibleLocations' "$S_STORAGE_LOC"
}
check_B2_jest_dialog_spec_exists() { file_exists "$J_DIALOG"; }
check_B2_jest_store_spec_exists()  { file_exists "$J_STORE"; }
check_B2_jest_store_asserts_endpoint() {
    file_contains 'putawayConfig/sku' "$J_STORE"
}
# NEGATIVE: the store spec proves the legacy endpoint is never called.
#
# r2: r1's row was `file_contains 'setPutAwayLocation'` with the comment "asserted
# as NOT called" — a bare substring grep that PASSES if the spec asserts the exact
# OPPOSITE, or if the string only appears in a comment. It could not tell a proof
# from a contradiction. The required form (plan §7.2) writes `.not.` FIRST:
#     expect($put).not.toHaveBeenCalledWith(expect.stringContaining('setPutAwayLocation'))
#     expect(urls.join(' ')).not.toContain('setPutAwayLocation')
# so the row demands a `.not.` within ~200 chars BEFORE the endpoint name.
# r2 (Critic F-4): the `\.not\.` form fixed the assert-the-opposite hole but NOT the
# comment hole — any unrelated `.not.` matcher followed within 200 chars by
# `setPutAwayLocation` IN A COMMENT still passed, and a real store spec plausibly
# carries both. Now requires an actual matcher CALL (`.not.someMatcher(`) and forbids
# an intervening `//`, so a commented mention cannot satisfy it.
check_B2_jest_store_asserts_no_legacy() {
    # NOTE the escaped slashes: multiline_contains interpolates into perl `m/.../`,
    # so a bare `(?!//)` TERMINATES the delimiter and the check dies with a regex
    # syntax error — which exits non-zero, i.e. it can never PASS. Caught by
    # negative-testing; a check that cannot pass is worse than one that cannot fail.
    multiline_contains '\.not\.[A-Za-z]+\((?:(?!\/\/)[\s\S]){0,200}?setPutAwayLocation' "$J_STORE"
}

# === CROSS-CUTTING — invariants that must hold in every phase ================

# 2643 ships ZERO migrations. If a V2.2.* file appeared that is not 2732's
# V2.2.11, someone added SQL to this ticket.
check_X_no_new_migration() {
    local extra
    extra=$(ls "$PROJECT_ROOT/src/main/resources/db/migration/" 2>/dev/null \
        | grep -E '^V2\.2\.(1[2-9]|[2-9][0-9])__' | wc -l)
    [ "$extra" -eq 0 ]
}
# The @NotNull on Itemdata is 2732's to remove, not 2643's.
check_X_notnull_not_touched_by_2643() {
    file_contains 'putawaylocationId' "$F_ITEMDATA_MODEL"
}
# The legacy write endpoint stays in place, verb unchanged (2732 §10.4 Q5).
# 2643 simply never calls it. Asserting its ABSENCE would be wrong.
check_X_legacy_endpoint_still_present() {
    file_contains 'GetMapping\(path=\s*"/setPutAwayLocation/' "$F_ITEMDATA_CTL"
}
# archunit_store must not be committed dirty — `mvn test` mutates it.
check_X_archunit_store_clean() {
    (cd "$PROJECT_ROOT" && git diff --quiet -- src/test/resources/archunit_store/ 2>/dev/null)
}
# PREREQUISITE PROBE — NOT a 2643 deliverable. Plan §5.1 row 0e.
#
# Authority.IS_SB_ADMIN names a SpEL method that exists nowhere in src/, so any
# @PreAuthorize using it returns HTTP 500 for EVERY caller, a genuine sb_admin
# included (9 endpoints are dead today; SBDEV-2863 owns them). SBDEV-2732 writes
# that constant onto its own writers. If it merges that way, every putaway-config
# write 500s and 2643's AC12 is unmeetable — but the FIX is 2732's review's or
# SBDEV-2863's, never a 2643 PR reverting a 2732 security annotation in 2732's own
# file. This row preserves the FINDING without claiming the OWNERSHIP: it is
# labelled a prerequisite in the output, and it only runs once 2732's file exists.
# (the probe itself is check_X_2732_not_merged_with_broken_constant, defined above
#  beside the A2 negative it pairs with)

# === Wire into the runner ====================================================

echo
echo "verify-SBDEV-2643-sku-default-putaway-location-ui — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  WEB_UI_ROOT =$WEB_UI_ROOT"
echo
if phase_2732_present; then
    echo "  SBDEV-2732 Phase 1-API : PRESENT (class declarations found for facade + config ctl + config svc)"
else
    echo "  SBDEV-2732 Phase 1-API : ABSENT  -> A2 / A3 / B2 checks will SKIP, not PASS"
fi
if phase_2732_ui_present; then
    echo "  SBDEV-2732 Phase 2-UI  : PRESENT (LocationPicker.vue defines a component)"
else
    echo "  SBDEV-2732 Phase 2-UI  : ABSENT  -> B2 picker checks will SKIP, not PASS"
fi
# Staleness escalation, and its own honesty caveat: if origin/develop cannot be
# resolved we cannot tell "unmerged" from "merged-and-drifted", so we fall back to
# SKIP — and say so, rather than letting the softer verdict pass unremarked.
if contract_drift; then
    echo "  ⚠ CONTRACT DRIFT       : a SBDEV-2732 merge IS on origin/develop but its constructs are ABSENT here."
    echo "                           Downstream rows FAIL rather than SKIP — this is PM1, not a blocked phase."
elif ! origin_develop_resolvable "$PROJECT_ROOT" || ! origin_develop_resolvable "$WEB_UI_ROOT"; then
    echo "  ⚠ STALENESS UNCHECKED  : origin/develop is not resolvable in one or both repos, so SKIP could not be"
    echo "                           escalated to FAIL. Run 'git fetch origin --prune' in both and re-run."
fi
if migration_2211_present; then
    echo "  V2.2.11 (2732's)       : PRESENT -> AC4 / AC9 reachable"
else
    echo "  V2.2.11 (2732's)       : ABSENT  -> AC4 (clear) and AC9 (audit) unreachable"
fi
echo

echo "--- Phase A0 — the SpEL detector (test-only; runnable today, in full) ---"
run A0-spel      "A0 — detector test EVALUATES a SpEL Authority string"        check_A0_spel_evaluated
run A0-root      "A0 — evaluated against a real expression root"              check_A0_evaluates_against_real_root
run A0-bare      "A0 — asserts bare hasAuthority('sb_admin'), no ROLE_ prefix" check_A0_bare_authority_asserted
run A0-ctx1      "A0 — Authority.IS_SB_ADMIN left untouched (SBDEV-2863 owns)" check_A0_authority_constant_untouched
run A0-ctx2      "A0 — no isSbAdmin() alias added to shared wiring"           check_A0_no_alias_added_to_root
echo

echo "--- Phase A1 — putawayLocationId in the details payload (runnable today) ---"
run A1-id        "A1 — putawayLocationId emitted from getItemdataDetails"     check_A1_id_key_emitted
run A1-async     "A1 — id emitted OUTSIDE the FK guard (the AC8 signal)"      check_A1_id_outside_fk_guard
run A1-name      "A1 — name key still emitted only on a resolved FK"          check_A1_name_still_fk_guarded
run A1-repo      "A1 — details read still uses repo findById, not @Cacheable getById" check_A1_uses_repo_findbyid
run A1-neg-res   "A1 — MANDATORY resolver NOT called from ItemdataService"    check_A1_no_resolver_in_itemdata_service
run A1-t1        "A1 — tests assert the new key"                              check_A1_test_asserts_id_present
run A1-t2        "A1 — dangling-FK case asserts id-present + name-absent"     check_A1_test_asserts_dangling_fk_signal
run A1-t3        "A1 — null-id case asserts BOTH keys absent"                 check_A1_test_asserts_null_id_omits_both
echo

echo "--- Phase A2 — effective-destination read ---"
if phase_2732_present; then
    run A2-facade    "A2 — describeForSku(Long) in 2643's SkuPutawayQueryService" check_A2_facade_method
    run A2-tx        "A2 — that service: tenantTransactionManager + readOnly"     check_A2_facade_txmgr_and_readonly
    run A2-res       "A2 — the resolver is called from the SERVICE (D13)"         check_A2_service_calls_resolver
    run A2-neg-2732f "A2 — describeForSku did NOT land in 2732's facade (D13)"    check_A2_neg_not_in_2732_facade
    run A2-neg-badconst "A2 — 2643's own new file never uses IS_SB_ADMIN (MUST-5)" check_A2_neg_no_bad_constant
    run A2-map       "A2 — GET /{id}/effectivePutawayDestination mapped"          check_A2_endpoint_mapping
    run A2-deleg     "A2 — handler delegates to skuPutawayQueryService"           check_A2_delegates_to_facade
    run A2-neg-res   "A2 — resolver field ABSENT from ItemDataController (D-F)"   check_A2_neg_resolver_absent_from_controller
    run A2-neg-typ   "A2 — resolver TYPE absent from ItemDataController"          check_A2_neg_resolver_type_absent_from_controller
    run A2-neg-oms   "A2 — new handler does not touch httpRestService (no OMS)"   check_A2_neg_no_oms_in_handler
    run A2-env       "A2 — ALL SEVEN Resolution envelope fields mapped"           check_A2_envelope_seven_fields
    run A2-nested    "A2 — tests in a NEW nested class (avoids 2732 Step 9)"      check_A2_new_nested_test_class
    run A2-enum      "A2 — asserts source is the ENUM NAME (SKU_OVERRIDE)"        check_A2_asserts_source_is_enum_name
    run A2-fsvc      "A2 — SkuPutawayQueryServiceUnitTest exists"                 check_A2_facade_unit_test_exists
    run A2-fsvc2     "A2 — that test covers describeForSku"                       check_A2_facade_test_covers_sku
    run A2-sec       "A2 — SecurityConfiguration not widened"                     check_A2_security_config_unwidened
else
    blocked A2-facade   "A2 — describeForSku(Long) in 2643's SkuPutawayQueryService" "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-tx       "A2 — that service: tenantTransactionManager + readOnly"     "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-res      "A2 — the resolver is called from the SERVICE (D13)"         "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-neg-2732f "A2 — describeForSku did NOT land in 2732's facade (D13)"   "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-neg-badconst "A2 — 2643's own new file never uses IS_SB_ADMIN (MUST-5)" "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-map      "A2 — GET /{id}/effectivePutawayDestination mapped"          "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-deleg    "A2 — handler delegates to skuPutawayQueryService"           "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-neg-res  "A2 — resolver field ABSENT from ItemDataController (D-F)"   "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-neg-typ  "A2 — resolver TYPE absent from ItemDataController"          "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-neg-oms  "A2 — new handler does not touch httpRestService (no OMS)"   "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-env      "A2 — ALL SEVEN Resolution envelope fields mapped"           "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-nested   "A2 — tests in a NEW nested class (avoids 2732 Step 9)"      "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-enum     "A2 — asserts source is the ENUM NAME (SKU_OVERRIDE)"        "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-fsvc     "A2 — SkuPutawayQueryServiceUnitTest exists"                 "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-fsvc2    "A2 — that test covers describeForSku"                       "blocked on SBDEV-2732 Phase 1-API"
    blocked A2-sec      "A2 — SecurityConfiguration not widened"                     "blocked on SBDEV-2732 Phase 1-API"
fi
# r2 (MUST-5): the A0-swap / A0-swap-neg rows are GONE, not skipped. They asserted
# that 2643 removes @PreAuthorize(Authority.IS_SB_ADMIN) from PutawayConfigService.java
# — 2732's own file, where 2732 deliberately writes it. Their backing functions were
# deleted (see the block above ~:305); leaving the `run` rows behind would have fired
# `command not found` the moment 2732 landed, i.e. a permanent FAIL that also
# re-asserted the ownership reversal MUST-5 removed. Replaced by X-2732-authz
# (prerequisite probe, plan §5.1 row 0e) and A2-neg-badconst.
echo

echo "--- Phase A3 — eligible-locations read (D-D: SPECIFIED HERE, OWNED BY 2732 per D12) ---"
# CONTRACT rows. r2: these no longer assert that *2643* wrote the endpoint — D-D is
# handed to 2732 and A3 is only 2643's fallback, so asserting authorship would be
# asserting the shape of constructs 2643 may never write. They assert properties any
# correct implementation must have, and they run once the endpoint EXISTS, whoever
# shipped it.
if dd_endpoint_present; then
    run A3-map       "A3 — GET /eligibleLocations mapped"                         check_A3_endpoint_mapping
    run A3-scope     "A3 — carries a PutawayScope parameter"                      check_A3_scope_param
    run A3-tx        "A3 — readOnly tenant transaction"                           check_A3_readonly_tenant_tx
    run A3-neg-advis "A3 — no advisory field / PICK_FACE reason (D1 reversed)"    check_A3_neg_no_advisory_class
    run A3-lane      "A3 — tier-4 lane excluded via the NAME constant (D8)"       check_A3_excludes_tier4_lane
    run A3-neg-stor  "A3 — NOT backed by getStorageLocationsForPutAwayItemData"   check_A3_neg_not_backed_by_storage_query
    run A3-t1        "A3 — controller test covers eligibleLocations"              check_A3_test_two_classes
    run A3-t2        "A3 — test proves FIX_ASSIGNED stays BLOCKED (P2.5 absolute)" check_A3_test_fix_assigned_stays_blocked
else
    blocked A3-map      "A3 — GET /eligibleLocations mapped"                         "D-D not shipped — 2732 owns it (D12); A3 is the fallback"
    blocked A3-scope    "A3 — carries a PutawayScope parameter"                      "D-D not shipped — 2732 owns it (D12)"
    blocked A3-tx       "A3 — readOnly tenant transaction"                           "D-D not shipped — 2732 owns it (D12)"
    blocked A3-neg-advis "A3 — no advisory field / PICK_FACE reason (D1 reversed)"   "D-D not shipped — 2732 owns it (D12)"
    blocked A3-lane     "A3 — tier-4 lane excluded via the NAME constant (D8)"       "D-D not shipped — 2732 owns it (D12)"
    blocked A3-neg-stor "A3 — NOT backed by getStorageLocationsForPutAwayItemData"   "D-D not shipped — 2732 owns it (D12)"
    blocked A3-t1       "A3 — controller test covers eligibleLocations"              "D-D not shipped — 2732 owns it (D12)"
    blocked A3-t2       "A3 — test proves FIX_ASSIGNED stays BLOCKED"                "D-D not shipped — 2732 owns it (D12)"
fi
# CONSUMER rows — 2643's OWN files. THESE are what 2643 is accountable for whoever
# ships the producer. They need the dialog, so they follow B2's gate.
if phase_2732_present && phase_2732_ui_present; then
    run A3-consume   "A3 — picker items come from /putawayConfig/eligibleLocations" check_A3_consumer_sources_from_endpoint
    run A3-neg-pred  "A3 — dialog re-implements NO predicate client-side (D3)"      check_A3_neg_no_client_side_predicates
else
    blocked A3-consume  "A3 — picker items come from /putawayConfig/eligibleLocations" "blocked on SBDEV-2732 Phase 1-API + Phase 2-UI"
    blocked A3-neg-pred "A3 — dialog re-implements NO predicate client-side (D3)"      "blocked on SBDEV-2732 Phase 1-API + Phase 2-UI"
fi
# D3 is 2643's OWN decision and is assertable today: getLocationView() must not
# be widened whether or not 2732 has landed.
run A3-neg-view  "A3 — getLocationView() NOT widened (D3)"                    check_A3_neg_locationview_unwidened
echo

echo "--- Phase B1 — SKU screen surface (runnable today) ---"
run B1-exclude   "B1 — exclude-fields includes putawayLocationId (§6.1)"      check_B1_exclude_fields_has_id
run B1-label     "B1 — relabelled to 'Default Putaway Location'"             check_B1_relabelled
run B1-neg-lbl   "B1 — old 'Putaway Location' label gone"                    check_B1_old_label_gone
run B1-pencil    "B1 — pencil added to the EXISTING actions column"          check_B1_pencil_in_actions_column
run B1-slot      "B1 — uses fullDetails' #actions slot"                      check_B1_uses_fulldetails_actions_slot
run B1-fd        "B1 — fullDetails.vue itself untouched"                     check_B1_fulldetails_untouched
run B1-neg-corpse "B1 — commented pencil/trash/menu corpse deleted"          check_B1_neg_corpse_deleted
run B1-perm      "B1 — isPutawayConfigAdmin computed exists"                 check_B1_permission_computed
run B1-cfg       "B1 — consumes nuxt.config appAdminGroup (first ever read)" check_B1_consumes_app_admin_group
run B1-disabled  "B1 — gate applied as :disabled (D10)"                      check_B1_gate_is_disabled_not_vif
run B1-neg-vif   "B1 — gate is NOT v-if (read-only users may view)"          check_B1_neg_gate_not_vif
run B1-word      "B1 — shared putawayWording.js exists"                      check_B1_wording_module_exists
run B1-word2     "B1 — both 2731 constants, verbatim values"                 check_B1_wording_module_has_both_constants
run B1-word3     "B1 — receivingForm.vue imports from the shared module"     check_B1_recv_form_imports_shared
run B1-neg-word  "B1 — receivingForm.vue no longer declares them locally"    check_B1_neg_recv_form_no_local_const
run B1-persist   "B1 — persistedState.client.js untouched (§3.8.5)"          check_B1_persistedstate_untouched
run B1-neg-col   "B1 — no table column added (D5)"                           check_B1_neg_no_table_column
run B1-jest      "B1 — skuData.spec.js exists"                               check_B1_jest_spec_exists
run B1-jest2     "B1 — spec asserts disabled-not-hidden"                     check_B1_jest_asserts_disabled_not_hidden
echo

echo "--- Phase B2 — edit dialog and the write ---"
if phase_2732_present && phase_2732_ui_present; then
    run B2-dialog    "B2 — editSkuPutawayDialog.vue exists"                      check_B2_dialog_exists
    run B2-picker    "B2 — reuses 2732's LocationPicker (D6)"                     check_B2_dialog_uses_shared_picker
    run B2-valid     "B2 — hand-rolled validated() + \$toast idiom"               check_B2_dialog_handrolled_validation
    run B2-neg-form  "B2 — no v-form/rules/Vuelidate"                            check_B2_neg_no_vform_rules
    run B2-banner    "B2 — scope banner NAMES SBDEV-2821 (D1, §3.8.2a)"           check_B2_scope_banner_names_unblocking_ticket
    run B2-banner2   "B2 — scope banner NAMES 2732 Q9 as the reason (§3.8.2a)"    check_B2_scope_banner_names_design_decision
    run B2-banner3   "B2 — banner counts COMPUTED, not hard-coded tenant numbers" check_B2_banner_count_not_hardcoded
    run B2-neg-advis "B2 — no per-row advisory / PICK_FACE state (D1 reversed)"   check_B2_neg_no_advisory_state
    run B2-clear     "B2 — Clear / Use default affordance present"                check_B2_clear_affordance
    run B2-endpoint  "B2 — store action targets PUT /putawayConfig/sku/"          check_B2_store_targets_putawayconfig
    run B2-neg-leg   "B2 — legacy setPutAwayLocation NOT in the store"            check_B2_neg_no_legacy_endpoint
    run B2-neg-leg2  "B2 — legacy setPutAwayLocation NOT in the dialog"           check_B2_neg_no_legacy_in_dialog
    run B2-clearq    "B2 — Clear OMITS locationId entirely"                       check_B2_clear_omits_param
    run B2-neg-null  "B2 — never sends locationId=null in the query string"       check_B2_neg_no_null_in_querystring
    run B2-body      "B2 — surfaces response.data so 422s reach the operator"     check_B2_surfaces_response_body
    run B2-refetch   "B2 — re-dispatches getSkuDetail after a write"              check_B2_refetches_detail
    run B2-neg-page  "B2 — does NOT re-dispatch searchSkuData (keeps the page)"   check_B2_neg_does_not_repage_table
    run B2-eff       "B2 — effective-destination read action present"             check_B2_effective_read_action
    run B2-neg-dv    "B2 — dialog not backed by /location/detailView (D3)"        check_B2_neg_not_detailview_backed
    run B2-store-ok  "B2 — storageLocation store untouched"                       check_B2_storage_store_untouched
    run B2-jest1     "B2 — editSkuPutawayDialog.spec.js exists"                   check_B2_jest_dialog_spec_exists
    run B2-jest2     "B2 — store spec exists"                                     check_B2_jest_store_spec_exists
    run B2-jest3     "B2 — store spec asserts the putawayConfig endpoint"         check_B2_jest_store_asserts_endpoint
    run B2-jest4     "B2 — store spec asserts the legacy GET is never called"     check_B2_jest_store_asserts_no_legacy
else
    for c in \
      "B2-dialog|editSkuPutawayDialog.vue exists" \
      "B2-picker|reuses 2732's LocationPicker (D6)" \
      "B2-valid|hand-rolled validated() + toast idiom" \
      "B2-neg-form|no v-form/rules/Vuelidate" \
      "B2-banner|scope banner NAMES SBDEV-2821 (D1)" \
      "B2-banner2|scope banner NAMES 2732 Q9 as the reason" \
      "B2-banner3|banner counts COMPUTED, not hard-coded tenant numbers" \
      "B2-neg-advis|no per-row advisory / PICK_FACE state (D1 reversed)" \
      "B2-clear|Clear / Use default affordance present" \
      "B2-endpoint|store action targets PUT /putawayConfig/sku/" \
      "B2-neg-leg|legacy setPutAwayLocation NOT in the store" \
      "B2-neg-leg2|legacy setPutAwayLocation NOT in the dialog" \
      "B2-clearq|Clear OMITS locationId entirely" \
      "B2-neg-null|never sends locationId=null in the query string" \
      "B2-body|surfaces response.data so 422s reach the operator" \
      "B2-refetch|re-dispatches getSkuDetail after a write" \
      "B2-neg-page|does NOT re-dispatch searchSkuData" \
      "B2-eff|effective-destination read action present" \
      "B2-neg-dv|dialog not backed by /location/detailView (D3)" \
      "B2-store-ok|storageLocation store untouched" \
      "B2-jest1|editSkuPutawayDialog.spec.js exists" \
      "B2-jest2|store spec exists" \
      "B2-jest3|store spec asserts the putawayConfig endpoint" \
      "B2-jest4|store spec asserts the legacy GET is never called" ; do
        blocked "${c%%|*}" "B2 — ${c#*|}" "blocked on SBDEV-2732 Phase 1-API + Phase 2-UI"
    done
fi
echo

echo "--- Cross-cutting invariants (runnable in every phase) ---"
run X-nomig      "X — 2643 ships ZERO migrations"                            check_X_no_new_migration
run X-notnull    "X — Itemdata.putawaylocationId untouched by 2643"          check_X_notnull_not_touched_by_2643
run X-legacy     "X — legacy write endpoint still present (2732 Q5)"         check_X_legacy_endpoint_still_present
run X-archunit   "X — archunit_store is clean (mvn test mutates it)"         check_X_archunit_store_clean
# PREREQUISITE PROBE (plan §5.1 row 0e) — reports on SBDEV-2732, not on 2643. Skipped
# while 2732 is absent; once its file lands, a FAIL means 2732 merged with the broken
# constant and AC12 cannot be met by anyone until 2732/SBDEV-2863 repairs it.
if phase_2732_present; then
    run     X-2732-authz "X — PREREQ(2732/2863): 2732 did NOT merge with the broken IS_SB_ADMIN (0e)"  check_X_2732_not_merged_with_broken_constant
else
    blocked X-2732-authz "X — PREREQ(2732/2863): 2732 did NOT merge with the broken IS_SB_ADMIN (0e)"  "blocked on SBDEV-2732 Phase 1-API"
fi
echo

# === Optional: targeted JUnit / Jest runs =====================================
# A code-shape grep proves the call exists; a test proves it works. Enable with
# RUN_TESTS=1. Kept opt-in because `mvn test` MUTATES the tracked archunit_store
# and takes minutes.
#
#   RUN_TESTS=1 PROJECT_ROOT=... bash <this script>
#
if [ "${RUN_TESTS:-0}" = "1" ]; then
    echo "--- Targeted test runs (RUN_TESTS=1) ---"
    run A0-test  "A0 — CustomMethodSecurityExpressionRootUnitTest passes" mvn_test_passes CustomMethodSecurityExpressionRootUnitTest
    run A1-test  "A1 — ItemdataServiceUnitTest passes"                    mvn_test_passes ItemdataServiceUnitTest
    if phase_2732_present; then
        run A2-test  "A2 — ItemDataControllerUnitTest passes"              mvn_test_passes ItemDataControllerUnitTest
        run A2-test2 "A2 — SkuPutawayQueryServiceUnitTest passes"          mvn_test_passes SkuPutawayQueryServiceUnitTest
    else
        blocked A2-test  "A2 — ItemDataControllerUnitTest passes"          "blocked on SBDEV-2732 Phase 1-API"
        blocked A2-test2 "A2 — SkuPutawayQueryServiceUnitTest passes"      "blocked on SBDEV-2732 Phase 1-API"
    fi
    echo "  NOTE: run 'git checkout src/test/resources/archunit_store/' now — mvn test mutated it."
    echo
fi

# === SELF-TEST — negative-test this script before trusting it ================
# Recorded landmine: SBDEV-2736 scored 57 pass / 0 fail on the very build that
# carried the defect its ticket was written to catch. A green run proves nothing
# until you have watched the relevant checks go RED. Run this ONCE, per phase,
# before accepting any "DONE" claim:
#
#   git stash                                  # revert the phase's changes
#   bash <this script>                          # the phase's checks MUST turn FAIL
#   git stash pop
#
# Specifically confirm each of these FAILS on the pre-fix tree:
#   A1-id / A1-async     — before the details-map change
#   B1-exclude           — before the exclude-fields line
#   B1-neg-corpse        — while the commented :100-123 block is still present
#   B2-neg-leg           — if the store is pointed at /itemData/setPutAwayLocation
#   A2-neg-res           — TEMPORARILY add `putawayDestinationResolver` to
#                          ItemDataController and confirm this row turns FAIL.
#                          This is the one check nothing else can substitute for:
#                          a mocked unit test passes against a controller that
#                          calls the MANDATORY resolver directly, and production
#                          then 500s on every request.
# And confirm the fail-open fix works:
#   rm the not-yet-created files and verify B1-word / B2-dialog / A2-fsvc report
#   FAIL rather than PASS. On the unpatched template they PASS.

echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
if [ "$SKIP" -gt 0 ]; then
    echo
    echo "  ⚠ $SKIP check(s) SKIPPED — blocked on SBDEV-2732 (plan status: draft, nothing merged)."
    echo "    A green run with SKIPs is NOT 'done'. The plan's §8.4 requires 0 fail AND 0 skip."
fi

[ "$FAIL" -eq 0 ]
