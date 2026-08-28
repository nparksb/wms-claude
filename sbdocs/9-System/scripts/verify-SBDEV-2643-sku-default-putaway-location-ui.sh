#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# BASELINE LABEL — added 2026-08-08. A baseline without the state it was measured
# against expires silently, which is how SBDEV-2732 ended up instructing operators
# that >8 passes meant a vacuous check while its script returned 9 every run.
#
#   Measured: 31 pass, 62 fail, 0 SKIP   <-- CURRENT, after PR 1 (B1-pre) + PR 2 (A1), 2026-08-12
#   Against : the PER-TICKET WORKTREES  .claude/worktrees/wms2-api/SBDEV-2643
#                                       .claude/worktrees/wms2-web-ui/SBDEV-2643
#   Unimplemented baseline: 23 pass, 70 fail, 0 SKIP against the main checkouts
#                           (v2/wms2-api develop bcfdc47, v2/wms2-web-ui develop 488102c)
#
# ⚠ ALWAYS SAY WHICH ROOT A `Result:` LINE CAME FROM. The two differ by design, and quoting the
# main-checkout number while describing worktree work is how a phase gets reported as unstarted.
#
# ⚠ `0 fail` IS NOT REACHABLE UNTIL PR 6, and that is correct — see plan §8.0a. Each of the six PRs
# carries only its own phase's tests, so rows for parked phases are legitimately red. The per-PR
# criterion is three-part: (1) this phase's rows green, (2) NO already-merged phase's row regressed
# (this is the real signal), (3) every remaining red attributable to an unshipped phase.
# Phases green as of PR 1 + PR 2: all eight A1-* rows, plus B1-exclude.
#   Note    : 63 -> 70 fails is the 7 NEW Phase A4 rows (§3.5a, the `name` search parameter added when
#             Q4 was answered as option (ii)). Pass count did NOT move, which is the correct signal:
#             new unimplemented scope must add FAILs only.
#   State   : SBDEV-2732 FULLY MERGED (both phases). ZERO skips — every 2732 gate has resolved, so
#             every remaining FAIL is 2643's own unimplemented work. There is no longer any
#             "blocked on 2732" hiding place in this script.
#
#   Superseded baselines, kept so a stale number is recognisable rather than trusted:
#     11 pass / 38 fail / 34 skip   — r6, 2026-08-11, 2732 Phase 1-API only
#      5 pass / 32 fail / 51 skip   — pre-2732, api 6bc709a / web 4ce39a1
#     72 pass / 0 fail              — ⚠ NEVER VALID. Measured against a stale local checkout; it is
#                                     recorded here only because it was once quoted as real.
#
# r7 EMPIRICAL AUDIT (2026-08-12) — every row changed or added in r7 was tested both ways against a
# synthetic conformant implementation in a throwaway git worktree, not merely eyeballed:
#   - each rewritten/new row PASSES on the conformant tree and FAILS on unimplemented develop;
#   - 24 / 24 targeted mutations were CAUGHT (17 on the rewritten rows + 7 on the new A4 rows), one per
#     row, each breaking only that row's property;
#   - the `multiline_contains` / `multiline_not_contains` slash bug was found BY that audit — two r7
#     rows were red against a correct implementation until the helpers were fixed.
#
# THREE MORE TRAPS THE A4 ROUND HIT, all found by running the rows rather than reading them:
#   1. ⚠ AN UNDEFINED FUNCTION IN AN `if` GUARD DELETES ROWS SILENTLY. The A4 block was first wrapped in
#      `if phase_selected 2 || phase_selected 1; then` — `phase_selected` exists in SBDEV-2732's script,
#      not this one. Bash returned 127, the guard was false, and all 7 rows VANISHED: the total stayed
#      23/63 and the run looked unchanged, not broken. `bash -n` accepts it, and an audit that checks
#      only `run` targets never looks at guards. This is strictly worse than the known "undefined fn
#      reads as an honest FAIL" trap. AUDIT GUARDS TOO.
#   2. ⚠ A NEGATIVE THAT PASSES BEFORE THE WORK STARTS. `A4-neg-native` was green on an untouched tree,
#      because with no `name` parameter there is nothing for `nativeQuery=true` to sit near. It was the
#      only green among seven new rows, which is what gave it away. Now conjoined with the positive.
#   0. ⚠⚠ `[ -d "$root/.git" ]` DISABLES A CHECK IN EVERY WORKTREE RUN. In a git worktree `.git` is a
#      FILE (`gitdir: …`), not a directory — so `origin_develop_resolvable` returned false for every
#      worktree and the SKIP→FAIL staleness escalation went silently inert, printing "⚠ STALENESS
#      UNCHECKED" and continuing. Worst possible placement: `wms-plan-executor` REQUIRES worktree runs,
#      so the primary intended mode was the one mode where the escalation could not fire. Use `-e`, and
#      prefer `git -C "$root"` over `cd`. Found 2026-08-12 by the Phase-3a lane during PR 1/PR 2.
#      ⚠ Any other verify script guarding on `.git` being a directory has the same hole.
#   3. ⚠ TWO REGEX FLAVOURS IN ONE FILE. `file_contains` / `file_not_contains` are ERE (`grep -qE`);
#      `multiline_contains` / `multiline_not_contains` are perl. A PCRE `(?i)` handed to the ERE helper
#      is matched LITERALLY, so `A4-t-empty` was red against a conformant test. Check which helper you
#      are calling before using `(?i)`, lookahead, or non-greedy quantifiers.
# Re-record this baseline after any implementation pass. A rising pass count with no implementation
# behind it means a check went vacuous.
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
# 3. PHASE A0 IS RETIRED — SBDEV-2863 SHIPPED BOTH HALVES (2026-08-07, PR #134,
#    commits 675b4a1 + d8e0137, merge 7d9d38e). Authority.java:44 now reads
#    IS_SB_ADMIN = "hasAuthority('" + SB_ADMIN_ROLE + "')", and the SAME commit
#    added the @Nested AuthorityExpressionsResolve class to
#    CustomMethodSecurityExpressionRootUnitTest — a strict superset of the
#    detector A0 was going to build (resolves-without-exception; TRUE for an
#    sb_admin; FALSE for a non-admin; agrees with isAimAdmin(); prefix-independent;
#    plus a harness self-test). There is nothing left for 2643 to add here.
#      - DELETED  A0-spel, A0-root, A0-bare, A0-ctx1, A0-ctx2, A0-test
#      - RETIRED  X-2732-authz  -> replaced by X-authz-constant (see below)
#      - KEPT     A2-neg-badconst, on a NEW rationale (see its comment)
#    Two of those rows were already reporting falsely against origin/develop when
#    this edit was made (measured 2026-08-09):
#      - A0-ctx1 asserted the constant STILL reads "isSbAdmin()". 2863 changed it,
#        so the row was PERMANENTLY RED and indistinguishable from unfinished work.
#      - A0-spel required parseExpression(Authority.<CONST>) literally; the shipped
#        test binds the constant to a local first, so it read FAIL against a test
#        that does exactly what A0 specified.
#    X-2732-authz was worse than stale: it asserted PutawayConfigService does NOT
#    carry @PreAuthorize(Authority.IS_SB_ADMIN) — the line SBDEV-2732 §3.12
#    deliberately writes, and which is now CORRECT. It would have gone red against
#    a correct SBDEV-2732 and blocked it. Replaced by a guard on the constant
#    itself, which is what AC12 actually depends on and needs no 2732 file.
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
F_LOC_REPO="$API/repo/jpa/LocationRepository.java"                   # A4: where the search predicate lives

T_EXPR_ROOT="$APITEST/unit/CustomMethodSecurityExpressionRootUnitTest.java"
T_ITEMDATA_SVC="$APITEST/unit/service/ItemdataServiceUnitTest.java"
T_ITEMDATA_CTL="$APITEST/unit/controller/ItemDataControllerUnitTest.java"
T_SKU_QUERY_SVC="$APITEST/unit/service/SkuPutawayQueryServiceUnitTest.java"
T_CFG_CTL="$APITEST/unit/controller/PutawayConfigControllerUnitTest.java"
T_QUERY_SVC="$APITEST/unit/service/PutawayDestinationQueryServiceUnitTest.java"  # A4's behavioural rows

V_SKUDATA="$UI/components/masterData/material/skuData/skuData.vue"
V_DIALOG="$UI/components/masterData/material/skuData/editSkuPutawayDialog.vue"
V_WORDING="$UI/components/masterData/material/skuData/putawayWording.js"
V_RECV_FORM="$UI/components/receiving/open/receive/receivingForm.vue"
V_FULLDETAILS="$UI/components/common/fullDetails.vue"
V_PICKER="$UI/components/common/LocationPicker.vue"                  # 2732 SHIPPED this (merged)
# --- r7 (2026-08-12) — three constructs 2732 SHIPPED that 2643 now consumes rather than rebuilds.
# V_FIELD is the load-bearing one: it already owns the preview gate, D11's count-and-confirm, the
# 7-value blockingReason message map, the paginated accumulate, clear-omits-locationId and the
# sb_admin gate, and its `scope` prop is documented "'MERCHANT' / 'SKU' when steps 21 and SBDEV-2643
# reuse this". B2 extends it; it does not clone it.
V_FIELD="$UI/components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue"
V_KCROLES="$UI/util/keycloakRoles.js"                                # 2732 SHIPPED this
S_CONFIG="$UI/store/admin/configuration.js"                          # 2732 SHIPPED this
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
    [ -f "$2" ] && [ -r "$2" ] || return 1
    ! grep -qE "$1" "$2"
}

# code_not_contains <regex> <file> — like file_not_contains, but IGNORES comment-only lines
# (`//`, `*`, `/*`). Added 2026-08-27 (SBDEV-3017) after a MEASURED false red: the row asserting the
# legacy setPutAwayLocation endpoint is deleted went red against correct code, because the deletion
# left a TOMBSTONE COMMENT naming the very path it forbids. Prose about a deleted symbol is exactly
# what a good deletion leaves behind, so any negative row on a deleted symbol needs this, not
# file_not_contains. Fails closed on a missing file, same as its sibling.
code_not_contains() {
    [ -f "$2" ] && [ -r "$2" ] || return 1
    ! grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" | grep -qE "$1"
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
# ⚠ FIXED r7 (2026-08-12) — A SLASH IN THE PATTERN USED TO BE A PERL SYNTAX ERROR.
# The old body was:  perl -0777 -ne "exit(/$1/s ? 0 : 1)" "$2"
# The shell interpolated the pattern into the perl SOURCE, where `/` is the regex delimiter. So a
# pattern like  SKU:\s*'admin/configuration/setSkuPutawayDestination'  closed the regex at the first
# slash and perl died with `Unknown regexp modifier "/f"` — exit 255, recorded as an ordinary FAIL.
# `@` and `$` were interpolated as perl variables for the same reason, so `'@/util/keycloakRoles'`
# could never match either.
#
# It fails CLOSED, so it never produced a false green — but it makes any slash-bearing assertion
# UNSATISFIABLE, which is the recorded failure mode "a permanently-red row is indistinguishable from
# unimplemented work". Two r7 rows (B1-cfg, B2-sku-write) hit it, and both were red against a
# synthetic CONFORMANT implementation, which is how it was caught.
#
# Only one pre-existing call carried a slash and it escaped them (`\/\/`), so no historical result
# changes; an escaped `\/` is still just `/` under the new form.
#
# The pattern now travels in the ENVIRONMENT and is compiled at runtime, so the shell never sees it as
# perl source. Delimiters, `@`, `$` and `'` are all literal.
multiline_contains() {
    [ -f "$2" ] || return 1
    MLC_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{MLC_PAT}/s ? 0 : 1)' "$2"
}

# multiline_not_contains <perl-regex> <file>
# Same fix as multiline_contains — and here the old form was WORSE than fail-closed. A perl syntax error
# exits 255, which this helper's caller reads as "pattern not found" = the NEGATIVE PASSES. So a
# slash-bearing negative assertion was a genuine FALSE GREEN: it reported "the forbidden construct is
# absent" without ever having looked. No such call existed, but the trap was one keystroke away.
multiline_not_contains() {
    [ -f "$2" ] || return 1
    MLC_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{MLC_PAT}/s ? 1 : 0)' "$2"
}

# file_exists <file>  — for NEW files, so their absence is a FAIL not a PASS
file_exists() { [ -f "$1" ]; }

# mvn_test_passes <TestClass>
# NOTE: -Dtest='Outer#method' silently no-ops for @Nested tests (false green) —
# always pass a CLASS name here, never Class#method.
mvn_test_passes() {
    [ -d "$PROJECT_ROOT" ] || return 1
    (cd "$PROJECT_ROOT" && mvn test -Dtest="$1" -DfailIfNoTests=false 2>&1 \
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
    # ⚠ SAME `.git`-is-a-file BUG AS origin_develop_resolvable, FIXED 2026-08-12 — and this instance was
    # the more damaging of the two. It gates `contract_drift`, i.e. the CONTRACT DRIFT / pre-mortem-PM1
    # detector. With `-d` this returned false for every worktree, so in the invocation mode
    # `wms-plan-executor` mandates, PM1 could not be detected AT ALL: a 2732 merge on origin/develop
    # whose constructs were absent locally would have reported rows as "SKIP — blocked on 2732" instead
    # of FAIL. Found only because the first instance was fixed and the file was then swept for others —
    # the first fix alone would have left this one silently dead.
    [ -e "$1/.git" ] || return 1
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
# ⚠ FIXED 2026-08-12 — `[ -d "$1/.git" ]` DISABLED THIS CHECK IN EVERY WORKTREE RUN.
# In a git worktree, `.git` is a FILE containing `gitdir: /path/to/.git/worktrees/<name>`, not a
# directory. So the old guard returned 1 for any worktree, `origin_develop_resolvable` reported false,
# and the SKIP→FAIL staleness escalation went silently inert — printing "⚠ STALENESS UNCHECKED" and
# moving on.
#
# That is the worst possible place for it to fail: `wms-plan-executor` REQUIRES the script to be run
# against per-ticket worktrees (never the main checkout), so the primary intended invocation mode was
# the one mode in which the escalation could not fire. Found by the Phase-3a conformance lane, which
# noticed the warning and observed that its own `git diff origin/develop` resolved fine.
#
# `-e` covers both shapes; the rev-parse is the real test anyway.
origin_develop_resolvable() {   # $1 = repo root
    [ -e "$1/.git" ] || return 1
    git -C "$1" rev-parse --verify --quiet origin/develop >/dev/null 2>&1
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
# V2.2.13 is 2732's migration. 2643 ships ZERO migrations, so this is a
# dependency probe only — never an assertion about 2643's own work.
# ⚠ FIXED 2026-08-11: this greppped '^V2\.2\.11__' while every comment and message
# around it said V2.2.13. 2732 renumbered V2.2.11 -> V2.2.13 on 2026-08-10 (V2.2.11
# was claimed by PR #138), so the probe could never match and the dependency line
# below reported "ABSENT -> AC4 / AC9 unreachable" even against a tree that HAS the
# migration. A dependency probe that is wired to a version nobody ships is a
# permanently-red row, indistinguishable from an honest blocker.
migration_2213_present() {
    ls "$PROJECT_ROOT/src/main/resources/db/migration/" 2>/dev/null | grep -q '^V2\.2\.13__'
}

# === A0 — RETIRED 2026-08-09; delivered in full by SBDEV-2863 =================
#
# All five A0 rows and the A0-test row are DELETED, not skipped. SBDEV-2863
# (PR #134, merged 2026-08-07, commits 675b4a1 + d8e0137) repaired the constant
# AND added the SpEL-evaluation detector in the same commit, so every property A0
# asserted is now either true-by-construction or covered by a test on develop:
#
#   A0-spel / A0-root / A0-bare  ->  @Nested AuthorityExpressionsResolve in
#                                    CustomMethodSecurityExpressionRootUnitTest,
#                                    which parses and evaluates the constant
#                                    against a root built through the real
#                                    CustomMethodSecurityExpressionHandler.
#   A0-ctx1                      ->  INVERTED by the fix. Asserting the broken
#                                    spelling survives is now asserting a defect.
#                                    Replaced by X-authz-constant below.
#   A0-ctx2                      ->  still true (no isSbAdmin() alias was added;
#                                    2863 took fix option (1), not (3)) but it is
#                                    2863's invariant to hold, not 2643's.
#
# Deleting beats skipping here: a permanently-skipped row implies work someone
# still owes, and nobody owes this.

# CROSS-CUTTING PREREQUISITE — the one property AC12 genuinely depends on.
# Not a 2643 deliverable and not a 2732 deliverable: it guards against a
# REGRESSION of SBDEV-2863 underneath both of them. If Authority.IS_SB_ADMIN ever
# goes back to naming a method on the expression root, every @PreAuthorize that
# uses it — including all six of 2732 §3.12's — returns HTTP 500 to every caller,
# sb_admin included, and AC12 becomes unmeetable again for both tickets.
#
# Runs today: it reads Authority.java only, so it needs no 2732 file and is never
# blocked. Asserting the WORKING form (rather than the absence of the broken one)
# is deliberate — an absence check would also pass if someone deleted the constant.
check_X_authz_constant_repaired() {
    file_contains "IS_SB_ADMIN\s*=\s*\"hasAuthority\('\"\s*\+\s*SB_ADMIN_ROLE" "$F_AUTHORITY" \
      || file_contains "IS_SB_ADMIN\s*=\s*\"hasAuthority\('sb_admin'\)\"" "$F_AUTHORITY"
}

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
# ⚠ WIDENED 2026-08-12 during execution, and the direction of the fix matters.
# This demanded the literal `containsKey("putawayLocationId")`. The shipped test asserts
# `containsEntry("putawayLocationId", 999L)` — which proves everything containsKey proves, PLUS the
# value. So the row was red against an implementation that is STRICTLY STRONGER than the row required.
#
# The Phase-3a conformance lane caught it and made the right call: **add or widen, never swap
# containsEntry for containsKey.** Trading value coverage for a green light is the failure this script
# exists to prevent — a verify row must never dictate a weaker assertion than the test already makes
# (§14 principle 5: a green signal must be EARNABLE, not weakenable).
#
# Root cause worth recording: the row was written against §3.3's prose, which prescribed editing the
# EXISTING test at :498 with containsKey. §8.0a later endorsed a new @Nested PutawayLocationIdInDetails
# class instead, and §3.3's table was never reconciled — so the row encoded a phrasing the plan had
# already superseded. It was red at the TDD-gate baseline too, not introduced by the implementation.
#
# Still non-vacuous: it requires an id-present assertion ADJACENT to the name-absent one, which is the
# actual AC8 distinguishability signal. Negative-tested after widening — see below.
check_A1_test_asserts_dangling_fk_signal() {
    multiline_contains 'contains(?:Key|Entry)\("putawayLocationId"[\s\S]{0,400}?doesNotContainKey\("putawayLocation"\)' "$T_ITEMDATA_SVC" \
      || multiline_contains 'doesNotContainKey\("putawayLocation"\)[\s\S]{0,400}?contains(?:Key|Entry)\("putawayLocationId"' "$T_ITEMDATA_SVC"
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
# ⚠ UPDATED 2026-08-12 for the §3.4 option-(a) decision. This required
# `Resolution describeForSku(Long`, i.e. the ORIGINAL bare-Resolution return type. That return type WAS
# the defect: reporting the configured resolution's P1 verdict made `compatible` disagree with both the
# writer (which exempts flowbins from P1) and receiving (which reports the verdict against the PLACEMENT,
# after divertPickFaceToLane). See §3.4's decision box.
#
# So the row now pins the DECISION rather than the old shape: the facade must return the two-resolution
# `PutawayDisplay`, and must NOT return a bare `Resolution` — reverting to that reintroduces the defect.
# The negative is the load-bearing half; without it the row would go green again on a revert that merely
# renamed things.
check_A2_facade_method() {
    multiline_contains 'PutawayDisplay\s+describeForSku\s*\(\s*Long' "$F_SKU_QUERY_SVC" \
      && multiline_not_contains 'Resolution\s+describeForSku\s*\(' "$F_SKU_QUERY_SVC" \
      && multiline_contains 'putawayDestinationResolver\.divertPickFaceToLane\s*\(' "$F_SKU_QUERY_SVC"
}
# ⚠ that third clause was `file_contains 'divertPickFaceToLane'` — a bare token that occurs THREE times
# in the file, twice in javadoc. Deleting the actual call and keeping the prose left the row green. Caught
# in scoped re-review, and it is the same vacuity class this very commit had just fixed on A2-enum and
# A2-fsvc2 — introduced in the row rewritten to "pin the DECISION". Now requires the receiver + the call.
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
# 2643's OWN new file must not be admin-gated — RATIONALE REPLACED 2026-08-09.
#
# This row was written when Authority.IS_SB_ADMIN was broken, and it read as "do not
# adopt the broken constant". SBDEV-2863 repaired the constant, so that reason is void
# and the row now stands on the reason that actually survives: the effective-destination
# read is deliberately NOT admin-gated (plan §3.4) — the ticket requires read-only users
# to see the value. An admin gate here would be a functional defect, not a security one.
# The row is unchanged in code and unchanged in verdict; only its justification moved.
check_A2_neg_no_bad_constant() {
    file_not_contains 'Authority\.IS_SB_ADMIN' "$F_SKU_QUERY_SVC"
}
# check_X_2732_not_merged_with_broken_constant was DELETED 2026-08-09.
#
# It asserted PutawayConfigService does NOT carry @PreAuthorize(Authority.IS_SB_ADMIN).
# That was correct only while the constant was broken. SBDEV-2863 fixed it, so the line
# 2732 §3.12 deliberately writes is now the RIGHT line — and this row would have gone
# red against a correct SBDEV-2732 and read as "2732 must not merge". Replaced by
# check_X_authz_constant_repaired, which guards the property that actually matters.
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
# ⚠ NARROWED 2026-08-12 during A2's implementation — the original asserted the TYPE NAME
# `PutawayDestinationResolver` is absent from ItemDataController, and that FAILS ANY CORRECT
# IMPLEMENTATION of §3.4's envelope.
#
# §3.4 puts the `Resolution` -> JSON mapping in the controller. Mapping a record necessarily names its
# type, in the method signature if nowhere else, and an import does not help — the import line contains
# the string too. So the row demanded a mapping that cannot be written.
#
# The decisive evidence is 2732's own precedent: `ReceivingController` names
# `PutawayDestinationResolver` FOUR times doing exactly this mapping, and it is merged, reviewed and
# correct. A 2643 row forbidding what 2732 shipped is the row being wrong, not the code.
#
# What the D-F invariant actually protects is that the controller must never INVOKE the resolver:
# `resolve(...)` is `Propagation.MANDATORY` and there is zero @Transactional under controller/, so a
# call from there raises IllegalTransactionStateException — an unchecked exception, hence a 500 on every
# request. The bean-reference half is already covered by `A2-neg-res` (lowercase
# `putawayDestinationResolver`, i.e. no field and no injection). This row now covers the CALL, which is
# the distinct and genuinely dangerous half.
check_A2_neg_resolver_type_absent_from_controller() {
    file_contains 'skuPutawayQueryService' "$F_ITEMDATA_CTL" \
      && file_not_contains '[Rr]esolver\s*\.\s*resolve\s*\(' "$F_ITEMDATA_CTL" \
      && file_not_contains 'divertPickFaceToLane' "$F_ITEMDATA_CTL"
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
# ⚠ TIGHTENED 2026-08-12 — was `file_contains 'SKU_OVERRIDE'`, which the test FIXTURE satisfies
# (`Source.SKU_OVERRIDE` when building the stub) even if nothing ever asserts `$.source`. Row name said
# "asserts", check said "mentions". Now requires the assertion shape.
check_A2_asserts_source_is_enum_name() {
    multiline_contains 'jsonPath\("\$\.source"\)[\s\S]{0,40}?\.value\("SKU_OVERRIDE"\)' "$T_ITEMDATA_CTL"
}
check_A2_facade_unit_test_exists() { file_exists "$T_SKU_QUERY_SVC"; }

# MEDIUM (code review, 2026-08-12) — `sourceLabel` is DUPLICATED in ItemDataController and 2732's
# ReceivingController by deliberate choice (§14 principle 1 forbids editing 2732's enum for this). The
# Javadoc claims compile-time safety, and that is true for an ADDED Source — a switch expression must be
# exhaustive. It is NOT true for the likely failure: a one-sided RENAME. Change "Merchant default" in one
# file and the two screens label the same tier differently, with nothing red anywhere.
# This row pins all four literals in BOTH files, so a one-sided rename fails.
check_A2_source_labels_agree_across_both_controllers() {
    local f
    for f in "$F_ITEMDATA_CTL" "$API/controller/ReceivingController.java"; do
        [ -f "$f" ] || return 1
        file_contains '"SKU override"'           "$f" || return 1
        file_contains '"Merchant default"'       "$f" || return 1
        file_contains '"Warehouse default"'      "$f" || return 1
        file_contains '"Standard putaway lane"'  "$f" || return 1
        # ⚠ The SECOND cross-controller literal duplicate, added by A2's diversion mapping
        # (ItemDataController's inline lane label vs ReceivingController.laneLabel). It has NO
        # compile-time backstop — it is a ternary on a string constant, not an exhaustive switch — so a
        # one-sided rename to e.g. "Putaway Lane" would make the receiving screen and the SKU screen
        # narrate the SAME diversion with different wording, silently. This is the only guard.
        file_contains '"Put Away Lane"'          "$f" || return 1
    done
    return 0
}
# ⚠ TIGHTENED 2026-08-12 — was a bare `describeForSku` grep, matched by the class Javadoc. Vacuous.
# Now requires an actual CALL on the service under test.
check_A2_facade_test_covers_sku() {
    multiline_contains 'service\.describeForSku\s*\(' "$T_SKU_QUERY_SVC"
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
# ⚠ check_A3_readonly_tenant_tx DELETED r7. It demanded a controller-level readOnly tenant transaction
# around eligibleLocations. 2732 shipped NO controller transaction on purpose (the boundary is on
# PutawayDestinationQueryService; zero @Transactional exists under controller/) and pins the absence
# with its own row `P2A-ctl-no-tx`. The two scripts asserted opposite things about one method. Deleted
# rather than left dead so nobody re-wires it from an older revision — see the retirement note at the
# A3 row block.
# NEGATIVE — D1 (r2): no 2643-specific classification was bolted onto 2732's type.
# `advisory` and PICK_FACE existed only to carry the reversed D1.
check_A3_neg_no_advisory_class() {
    file_not_contains '(PICK_FACE|"advisory")' "$F_CFG_CTL"
}
# --- CONSUMER rows: 2643's own files, asserted whoever owns the producer -------
# The picker's items come from the eligibility endpoint, not from a client-side
# filter over some other payload.
# REPOINTED r7 — the read is 2732's `getEligiblePutawayLocations` in store/admin/configuration.js, which
# the shared wrapper dispatches. 2643 consumes it through the wrapper rather than fetching its own page.
check_A3_consumer_sources_from_endpoint() {
    file_contains 'putawayConfig/eligibleLocations' "$S_CONFIG"
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
# ⚠ check_A3_excludes_tier4_lane DELETED r7. It grepped the CONTROLLER for
# STORAGE_LOCATION_PUTAWAY_LANE; the exclusion is real but lives in 2732's rules/query layer, where
# 2732 asserts it as `P2A-lane-name`.
#
# ⚠ check_A3_test_two_classes DELETED r7. It required the test method name
# `eligibleLocationsSkuScopeTwoClasses`, invented by 2643 for a phase it no longer ships and never used
# by 2732. It could only ever be red. (Its r3 hardening was correct in principle — a bare substring
# grep is worthless — but hardening a row that asserts someone else's test naming just made the wrong
# row sharper.)
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
# POSITIVE: the permission gate exists, reads the `sb_admin` RESOURCE role, and is
# applied as :disabled — never v-if.
#
# ⚠ REWRITTEN 2026-08-11 (plan r6). This row used to assert `appAdminGroup`, which
# WMS V2 DOES NOT USE ANY MORE — nothing in wms2-web-ui reads it, so the old
# assertion demanded dead config and would have gone green on a gate that can never
# grant anyone access (`nuxt.config.js:167`'s vestigial default vs. a real group
# path). The backend boundary is `@PreAuthorize(Authority.IS_SB_ADMIN)` and
# authorities come from `resource_access.om1-api.roles` with the prefix stripped
# (SecurityConfiguration.java:85-86), so the UI must mirror it with
# hasResourceRole('sb_admin', <clientId>) — hasRealmRole is silently false.
# ⚠ REWRITTEN r7 (2026-08-12). This asserted an `isPutawayConfigAdmin` COMPUTED, and a computed is
# precisely the defect SBDEV-2732's review round found and fixed as a High: `$kc` is a plain injected
# object whose getters read a closure variable that is null until the fire-and-forget `initKeycloak()`
# resolves, so a computed over it has ZERO reactive dependencies — Vue 2 evaluates it once, caches
# `false`, and never re-evaluates. The observed symptom was a real sb_admin getting a permanently
# disabled control. The row as written would have ENFORCED that defect on 2643.
# The gate must be reactive DATA assigned from the awaited resolver.
check_B1_permission_reactive_data() {
    # ⚠ The third conjunct USED to forbid `isPutawayConfigAdmin() { ... $kc ... }` — the r6 computed. Once
    # r7 renamed the gate, that assertion became permanently, silently TRUE: it forbade an identifier that
    # no longer exists anywhere, so the row's whole "not a computed" half stopped asserting anything while
    # still reporting PASS. Retargeted at the CURRENT name, which is the form that could actually regress:
    # someone "tidying" the reactive data + async mounted() into a one-line computed over $kc.
    file_contains 'isSbAdmin' "$V_SKUDATA" \
      && multiline_contains 'await\s+resolveSbAdmin\s*\(' "$V_SKUDATA" \
      && multiline_contains 'isSbAdmin\s*:\s*false' "$V_SKUDATA" \
      && multiline_not_contains 'isSbAdmin\s*\(\s*\)\s*\{' "$V_SKUDATA"
}
# ⚠ REWRITTEN r7 (2026-08-12) — the r6 form asserted `hasResourceRole('sb_admin', clientId)`, which
# SBDEV-2732 then PROVED returns false for 100% of real sb_admins, permanently, on every tenant:
#   (a) `sb_admin` is carried in the JWT via the Keycloak GROUP, i.e. the `groups` claim, and group
#       membership does not appear under `resource_access` at all; and
#   (b) keycloak-js resolves ONE client's roles, while `$config.keycloak.clientId` is the build-wide
#       KEYCLOAK_CLIENT and the token is issued by the PER-TENANT client from tenant discovery — two
#       independent sources on one deployment serving every tenant hostname.
# 2732 shipped the fix as `util/keycloakRoles.js`, which MIRRORS the API's own
# `JwtAccessTokenCustomizer.extractRoles` (every client under resource_access, PLUS every `groups`
# entry). 2643 imports that helper; it does not write a third role reader.
check_B1_gate_uses_shared_role_helper() {
    [ -f "$V_KCROLES" ] || return 1
    multiline_contains "resolveSbAdmin[\\s\\S]{0,80}?from\\s+'@/util/keycloakRoles'" "$V_SKUDATA"
}
# NEGATIVE, non-vacuous — same guard idiom as B1-neg-vif. A bare "appAdminGroup is
# absent" passes trivially today (the computed does not exist at all), so REQUIRE the
# computed first, then assert the dead config and the wrong Keycloak helper are absent.
# REWRITTEN r7 — now guards all THREE dead/narrower forms, not two. `hasResourceRole` joins the list
# because r6 specified it and 2732 disproved it; a reader who remembers r6 is the likeliest person to
# re-add it. Conjoined with a presence assertion so the row cannot pass vacuously on an absent file.
check_B1_neg_dead_gate_forms() {
    file_contains 'isSbAdmin' "$V_SKUDATA" \
      && file_not_contains 'appAdminGroup' "$V_SKUDATA" \
      && file_not_contains 'hasRealmRole' "$V_SKUDATA" \
      && file_not_contains 'hasResourceRole' "$V_SKUDATA"
}
# ⚠ RENAMED r7 — `isPutawayConfigAdmin` -> `isSbAdmin`, AND THREE ROWS WERE MISSED WHEN IT HAPPENED.
# r7 replaced r6's computed `isPutawayConfigAdmin()` with reactive data `isSbAdmin` (§3.11) and updated
# B1-perm / B1-cfg / B1-neg-cfg to match — but B1-disabled, B1-neg-vif and B1-jest2 kept the DEAD name, so
# all three would have stayed RED against a fully correct r7 implementation. A permanently-red row is
# indistinguishable from unimplemented work (the recorded landmine), and here three of them sat in the
# phase whose gate has already been specified wrong twice. Caught 2026-08-12 by reading the rows BEFORE
# writing the code rather than after. Same class as the A4-inquery repoint: a rename lands in the code and
# in the plan, and the script keeps asserting the identifier that no longer exists.
check_B1_gate_is_disabled_not_vif() {
    multiline_contains ':disabled="!\s*isSbAdmin' "$V_SKUDATA"
}
# NEGATIVE, non-vacuous. A bare "v-if=isSbAdmin is absent" passes trivially while the
# gate does not exist at all — it would have reported PASS before B1 was written. So the
# check first REQUIRES the gate to exist, then asserts it is not used as a v-if.
# D10: read-only users may VIEW.
check_B1_neg_gate_not_vif() {
    file_contains 'isSbAdmin' "$V_SKUDATA" \
      && file_not_contains 'v-if="!?\s*isSbAdmin' "$V_SKUDATA"
}
# POSITIVE — §3.7: the 2731 wording constants were EXTRACTED to a shared module
# rather than copy-pasted a third time, and receivingForm.vue now imports them.
check_B1_wording_module_exists() { file_exists "$V_WORDING"; }
check_B1_wording_module_has_both_constants() {
    file_contains "DEFAULT_PUTAWAY_LANE_NAME\s*=\s*'PutAwayLane'" "$V_WORDING" \
      && file_contains "DEFAULT_PUTAWAY_LANE_LABEL\s*=\s*'Put Away Lane'" "$V_WORDING"
}
# ⚠ WAS line-based ERE (`file_contains`), which cannot see a MULTI-LINE import — and a two-constant
# import from a long '@/components/masterData/material/skuData/putawayWording' path is exactly the shape
# prettier breaks across lines. The row was red against a correct import purely because of where the
# newlines fell. `multiline_contains` (perl, /s) judges the contract instead of the formatting; the
# tempered gap keeps the match inside ONE import statement so it cannot span two unrelated ones.
check_B1_recv_form_imports_shared() {
    # BOTH gaps tempered against `from`, so the whole match must stay inside ONE import statement. With the
    # second gap left as `[\s\S]*?` the row could be satisfied by "NAME imported from the WRONG module,
    # plus some later unrelated import from putawayWording" — the recorded unbounded-lazy-gap failure mode.
    multiline_contains 'import\s*\{(?:(?!\bfrom\b)[\s\S])*?DEFAULT_PUTAWAY_LANE_NAME(?:(?!\bfrom\b)[\s\S])*?from\s*.@/components/masterData/material/skuData/putawayWording' "$V_RECV_FORM"
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
# ⚠ WAS a label-only negative, and a review lane PROVED it toothless: it forbade a header whose TEXT is
# "Default Putaway Location", so the actual D5 violation — moving the pencil into its own column headed
# "Edit" — sailed straight through, as did `B1-pencil` (not column-aware) and the jest region test (which
# was false-greening for its own reason). D5 had NO enforcement anywhere in the gate.
# Now counts the header entries, which is what "no new column" actually means. The label negative is kept
# as the second conjunct: it is cheap and it catches the other spelling of the same mistake.
check_B1_neg_no_table_column() {
    [ -f "$V_SKUDATA" ] || return 1
    perl -0777 -ne '
        my ($h) = /headers:\s*\[(.*?)\],\s*$/ms;
        exit 1 unless defined $h;
        my $n = () = $h =~ /value:/g;
        exit($n == 9 ? 0 : 1);
    ' "$V_SKUDATA" \
      && multiline_not_contains "headers[\s\S]{0,600}?Default Putaway Location" "$V_SKUDATA"
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
# ⚠ (a) RENAMED r7 to isSbAdmin with the two rows above — this was the third missed one.
# ⚠ (b) The (b)+(c) halves are what forced the spec to MOUNT and inspect the rendered pencil rather than
#       stopping at `wrapper.vm.isSbAdmin`. The gate tests as parked asserted the FLAG plus the template
#       source text, which cannot show that the button is present-and-disabled rather than absent — and
#       "present, disabled" IS D10. So the spec gained a mounted assertion instead of this row being
#       relaxed to match it: the row was right and the test was the thing that was thin.
check_B1_jest_asserts_disabled_not_hidden() {
    file_contains 'isSbAdmin' "$J_SKUDATA" \
      && file_contains '\.exists\(\)' "$J_SKUDATA" \
      && file_contains "\.(attributes|props)\(\s*['\"]disabled['\"]" "$J_SKUDATA"
}

# === B2 — the edit dialog and the write (§3.8.2, §3.8.3) ====================

# === A4 — the `name` search parameter on eligibleLocations (§3.5a, NEW r7) ==========
# Q4 was answered (ii): 2643 ships the server-side search that SBDEV-2732's own Q2 close assigned to it
# ("SBDEV-2643 Phase B2 as a parameter on eligibleLocations"). Measured driver: 2,564 candidate locations
# on wms2-wineco-dev = 13 sequential round-trips at size 200 before the operator can type.
check_A4_controller_name_param() {
    multiline_contains 'eligibleLocations\([\s\S]{0,400}?RequestParam\([^)]*required\s*=\s*false[^)]*\)\s*String\s+name' "$F_CFG_CTL"
}
check_A4_service_name_param() {
    multiline_contains 'eligibleLocations\(\s*PutawayScope\s+scope\s*,\s*Long\s+subjectId\s*,\s*String\s+name' "$F_QUERY_SVC"
}
# POSITIVE: case-insensitive contains, and it must be IN the query. A post-filter would page over 2,564
# rows to return 3 -- the round-trips this phase exists to remove.
#
# ⚠ REPOINTED r7 (2026-08-12) FROM $F_QUERY_SVC TO $F_LOC_REPO, and this is the third time a row in this
# script has gone stale by naming the wrong FILE rather than the wrong pattern. As written it asked the
# SERVICE for a LOWER(...) that A4 correctly put in the REPOSITORY, so it was red against a conformant
# implementation -- and the temptation on a red row is to "fix" the code toward the row, which here would
# have meant filtering in the service: precisely the 2,564-row post-filter the row exists to forbid.
# A row that names a file is a claim about layering, and layering is what changes during implementation.
#
# ⚠ HARDENED after a review lane found it GREEN on a broken query (2026-08-12). The single-pattern version
# could not tell the `value` query from the `countQuery`: mutating ONLY the value query to a case-sensitive
# prefix match — i.e. breaking the query that decides WHICH ROWS COME BACK, while leaving the count correct —
# left this row PASS, because the untouched countQuery satisfied the regex on its own. Only the unit test
# caught it, since that reads `q.value()` specifically. A row that accepts "the pattern appears SOMEWHERE in
# this annotation" is satisfied by the least important half of it.
# Now asserted per-query, each with a tempered gap so neither half can borrow the other's correctness.
check_A4_filter_in_query() {
    # Both sides lower-cased, contains-not-prefix, term bound as a parameter (never concatenated) -- in the
    # VALUE query, tempered so the match cannot run past `countQuery` and satisfy itself there.
    multiline_contains '(?i)@Query\(\s*value\s*=\s*(?:(?!countQuery)[\s\S])*?lower\s*\(\s*l\.name\s*\)\s*like\s*lower\s*\(\s*concat\s*\(\s*.%.\s*,\s*:nameFilter\s*,\s*.%.\s*\)' "$F_LOC_REPO" \
      && multiline_contains '(?i)countQuery\s*=\s*(?:(?!@Query)[\s\S])*?lower\s*\(\s*l\.name\s*\)\s*like\s*lower\s*\(\s*concat\s*\(\s*.%.\s*,\s*:nameFilter\s*,\s*.%.\s*\)' "$F_LOC_REPO"
}
# ⚠⚠ THE R11 ROW, AND THE ONE THIS PHASE ACTUALLY TURNS ON. A4 adds a SECOND repository query rather than
# parameterising the existing one, so that an unsearched read -- what SBDEV-2732's two SHIPPED pickers do --
# executes the same SQL string it executed before this phase, byte for byte. This row asserts the split held:
# the original query must still carry NO name predicate. If it ever does, the WAREHOUSE and MERCHANT
# pickers are running SQL that was never measured on any tenant, and their failure mode is silent -- a
# missing legal destination with no toast, no 4xx and no log line.
#
# ⚠⚠ THIS ROW'S FIRST VERSION DID NOT WORK, AND IT WAS THE MOST IMPORTANT ROW IN THE PHASE. Negative-tested
# 2026-08-12 by actually inserting `AND (:nameFilter IS NULL OR LOWER(l.name) LIKE ...)` into the shared
# query — the precise R11 defect — and the row stayed GREEN. Its negative demanded `nameFilter` appear
# somewhere AFTER a `countQuery` and before the 2-arg declaration, but the mutation lands in the `value`
# query, which comes FIRST. So the row asserted a real property of a place the defect does not occur.
# `PutawayDestinationQueryServiceUnitTest` caught the same mutation on its own; had the row been trusted as
# the gate, this phase would have shipped with its headline guarantee unverified.
#
# Now written as a POSITIVE with a tempered-greedy gap: there must EXIST a @Query block that reaches the
# 2-argument declaration without passing through `nameFilter` — or through another `@Query`, which is what
# stops the match from starting at some earlier, unrelated query in this 300-line repository and skipping
# over the mutated one. Re-negative-tested after rewriting: MUT-1 now turns it red.
check_A4_r11_query_split() {
    check_A4_filter_in_query \
      && multiline_contains 'Page<Location>\s+findPutawayCandidatesByName\s*\(' "$F_LOC_REPO" \
      && multiline_contains '@Query\((?:(?!@Query)(?!nameFilter)[\s\S])*?Page<Location>\s+findPutawayCandidates\s*\(' "$F_LOC_REPO"
}
# POSITIVE: the SERVICE branches on a blank term instead of passing a wildcard. §3.5a rules out LIKE '%%'
# explicitly -- a match-everything wildcard changes the plan the database picks and can reorder an
# unsorted page. The branch is what makes the byte-identical guarantee reachable from the caller.
check_A4_service_branches_on_blank() {
    multiline_contains 'isEmpty\(\)[\s\S]{0,200}?findPutawayCandidates\s*\([\s\S]{0,200}?findPutawayCandidatesByName\s*\(' "$F_QUERY_SVC" \
      && multiline_not_contains "LIKE\\s*'%%'" "$F_QUERY_SVC"
}
# NEGATIVE and LOAD-BEARING: JPQL, not native SQL -- the H2 test lane, same constraint 2732 pinned as P2A-h2.
# ⚠ CONJOINED, because the bare negative PASSED VACUOUSLY. Before A4 is written there is no `name`
# parameter at all, so "no nativeQuery near eligibleLocations" is trivially true and the row reported
# PASS on an untouched tree -- the exact failure the file header warns about ("if that count rises
# without a corresponding implementation step, a check has gone vacuous"). It was caught by reading the
# first run of the new rows, where it was the ONLY green among seven.
# Now it requires the parameter to EXIST first, so it can only be green once there is something to judge.
# ⚠ ALSO REPOINTED r7 to $F_LOC_REPO with A4-inquery — `nativeQuery` is a @Query attribute, so it could
# only ever have appeared in the repository. Against the service file this row was asserting the absence of
# something that could not be present there: vacuous for a second reason, on top of the one below.
check_A4_neg_not_native() {
    check_A4_service_name_param \
      && multiline_not_contains 'nativeQuery\s*=\s*true[\s\S]{0,400}?findPutawayCandidatesByName' "$F_LOC_REPO"
}
# NEGATIVE: the banner must NOT read its counts from a search-narrowed page. With `name` applied,
# totalElements counts MATCHES, so "{eligibleCount} of this warehouse's {totalCount}" silently becomes
# "of this search" -- confidently wrong, per keystroke (§14 principle 4).
# ⚠ MADE FAIL-CLOSED. As written this row was GREEN FOR ABSENCE-OF-WORK REASONS: it forbade a search term
# near a `totalCount =` assignment, and the dialog has no such assignment at all — so it passed before the
# search box existed and would have read to a reviewer as protection that had been earned. That is the
# "negative that passes before the work starts" trap this script's own header documents (the A4-neg-native
# lesson), and it is most dangerous in the follow-up PR, where someone will see it already green.
#
# Now it requires the search wiring to EXIST before judging it, so today it reports RED — honestly, as
# "not yet built" — and only turns green when the debounced term is wired AND the banner is not recomputed
# from a searched read. Expect this row and A4-debounce to be the two reds at PR 6.
#
# 🔴 OBSOLETE 2026-08-26 (SBDEV-2960) — this paragraph claimed the banner's capture-once guard had
# executable coverage via `capturesTheBannerCountsOnceAndRearmsOnReopen`. **That test no longer exists.**
# SBDEV-2960 deleted the dialog's count line and the `captureCounts` latch with it, so there is nothing
# left in the dialog to capture once. Do not read this row as backed by a test.
# ⚠ TWICE CORRECTED. Fail-closed was right but the first attempt got both halves wrong:
#   (a) it accepted a bare COMMENT — inserting `<!-- TODO A4: debounce -->` turned it green (seventh
#       instance of comment-vs-code on this ticket), so the debounce conjunct now requires a CALL;
#   (b) it looked in $V_DIALOG, where the debounce must NOT live: B2-neg-raw forbids the dialog from
#       mounting the picker and B2-one-elig forbids a second reader, so the term gets wired in the shared
#       FIELD or the PICKER. As written it could only go green by putting the debounce exactly where B2's
#       architecture forbids — pressuring the follow-up author to relax the row instead of satisfying it.
# 🔴 THIS ROW IS NOW TRIVIALLY GREEN AND MUST NOT BE READ AS EVIDENCE — SBDEV-2960, 2026-08-26.
# Its third conjunct asserts that no `search…(totalCount|counts) =` assignment appears in $V_DIALOG. The
# dialog now has NO counts at all, so that conjunct is satisfied by absence, permanently, whatever A4
# does. And the test this paragraph named as carrying the rule executably
# (`capturesTheBannerCountsOnceAndRearmsOnReopen`) was DELETED with the latch.
#
# ⚠ THE HAZARD DID NOT GO AWAY, IT MOVED. `defaultPutawayLocationField`'s four counts — `totalCount`,
# `eligibleCount`, `eligibleDefaultCount`, `eligibleAdvancedCount` — are live-computed and unlatched, and
# the field's read passes no search term today. If A4 wires the debounced `name` search, a searched read
# reports the count of MATCHES and those four degrade to a match-relative denominator with no error
# anywhere. **Whoever lands A4 owns re-pointing this row at the FIELD and writing the latch test there.**
# Until then: this row guards wiring it cannot judge, and nothing executable guards the rule.
check_A4_neg_banner_from_search() {
    file_exists "$V_DIALOG" \
      && { multiline_contains '(debounce|setTimeout)\s*\(' "$V_FIELD" \
           || multiline_contains '(debounce|setTimeout)\s*\(' "$V_PICKER"; } \
      && multiline_not_contains '(?i)(searchTerm|search|query)[\s\S]{0,200}?(totalCount|counts)\s*=' "$V_DIALOG"
}
# POSITIVE: the caller debounces. A search firing per keystroke re-introduces the cost A4 removes.
#
# ⚠ THIS ROW AND A4-neg-banner ARE UI ROWS AND THEY MOVED TO THE B2 BLOCK in r7. A4's PR is API-ONLY
# (§3.5a): it ships the parameter, and the search box that sends it ships with B2, which is the only
# consumer. Left under the A4 heading they were two permanently-red rows in A4's own PR gate, which is how
# a real regression gets waved through as "one of the expected reds". Under B2 they gate the phase that
# actually creates the file they inspect.
# ⚠ Requires a CALL, not the word: the bare form went green on a comment. And repointed to where the term
# is actually wired — see check_A4_neg_banner_from_search for why it cannot be the dialog.
check_A4_debounced() {
    multiline_contains '(debounce|setTimeout)\s*\(' "$V_FIELD" \
      || multiline_contains '(debounce|setTimeout)\s*\(' "$V_PICKER"
}
# POSITIVE: the empty-search identity contract is TESTED, not merely asserted in prose. Tiers 2 and 3
# call this endpoint with no `name`, so a predicate bug that narrows the unfiltered set silently shrinks
# the WAREHOUSE and MERCHANT pickers -- with no error shown to the operator.
# ⚠ Uses multiline_contains (perl), NOT file_contains (grep -E). `(?i)` is a PCRE construct and is NOT
# valid ERE — under `grep -qE` it is matched literally, so the row was red against a conformant test
# named `eligibleLocationsBlankNameIsIdenticalToNoNameFilter`. Mixing the two regex flavours across
# these helpers is a standing trap: file_contains/file_not_contains are ERE, multiline_* are perl.
# ⚠ REPOINTED r7 from $T_CFG_CTL to $T_QUERY_SVC. The identity contract is BEHAVIOURAL — it is about which
# query runs — so it belongs where the method body is exercised, not where the controller's signature is
# reflected over. And a name-only match is not enough for the one row this phase most needs to be honest:
# the test must show the filtered query is NEVER REACHED on a blank term, because a test that merely
# compares row lists would also pass if a blank term ran a match-everything wildcard.
check_A4_test_empty_search_identity() {
    multiline_contains '(?i)(emptySearch|blankName|nameNull|withoutName|noNameFilter)' "$T_QUERY_SVC" \
      && multiline_contains 'never\(\)\s*\)\s*\.\s*findPutawayCandidatesByName' "$T_QUERY_SVC"
}

check_B2_dialog_exists() { file_exists "$V_DIALOG"; }
# ============================================================================
# ⚠ B2 RESHAPED r7 (2026-08-12) — 2732 ALREADY BUILT MOST OF THIS. READ THIS FIRST.
# ============================================================================
# `defaultPutawayLocationField.vue` (2732 step 20, merged `ec01dd7`) already owns the preview gate,
# D11's count-and-confirm, the full 7-value blockingReason message map, the paginated accumulate, the
# clear-omits-locationId rule, the 422/409 surfacing, the Vuetify double-submit re-entry guard, and the
# sb_admin gate via `resolveSbAdmin`. Its own props document `scope` as "'MERCHANT' / 'SKU' when steps
# 21 and SBDEV-2643 reuse this", `subjectId` as "Required at SKU scope", and its `write()` has a SKU
# branch that deliberately bails with "This scope cannot be saved from this screen" and the comment
# "SKU scope belongs to SBDEV-2732's sibling ticket (SBDEV-2643 B2) and has its own endpoint".
#
# So B2 EXTENDS that component; it does not clone it. The rows below therefore moved from "the dialog
# implements X" to "the dialog delegates X, and X is wired for SKU scope". A second copy of the preview
# gate is now a DEFECT this script must catch, not the deliverable it used to assert.
#
# ⚠ THIS CROSSES THE §14-PRINCIPLE-1 BOUNDARY ON PURPOSE, and r7 amends the principle rather than
# quietly breaching it. D13's "2643 writes into ZERO 2732-owned files" was a TEMPORAL guard against
# two in-flight PRs colliding — §11.0 said so at the time ("the residue is temporal, not
# architectural"). 2732 is merged and ready to archive, so the collision risk is gone and the cost has
# inverted: keeping the boundary now means shipping a second confirmation gate, which §3.11.2 names as
# exactly how one of them ends up without it.
check_B2_dialog_reuses_2732_field() {
    file_contains '(DefaultPutawayLocationField|default-putaway-location-field)' "$V_DIALOG" \
      && multiline_contains "scope\\s*=\\s*[\"']SKU[\"']" "$V_DIALOG"
}
# NEGATIVE: the dialog must NOT mount the raw picker. LocationPicker is presentational — it renders the
# tiers the server decided and emits a selection. Mounting it directly bypasses the preview gate, the
# blockingReason map and the typed write, which is the whole reason the wrapper exists.
check_B2_neg_dialog_bypasses_wrapper() {
    file_exists "$V_DIALOG" \
      && file_not_contains '(LocationPicker|location-picker)' "$V_DIALOG"
}
# NEGATIVE: no second copy of the preview gate / confirm recount in 2643's dialog.
check_B2_neg_no_duplicate_preview_gate() {
    file_exists "$V_DIALOG" \
      && file_not_contains '(previewPutawayConfig|incompatibleSkuCount|confirmIncompatibleSkus)' "$V_DIALOG"
}
# POSITIVE: the wrapper's scope→writer map gains SKU, so the shared Save path can actually write tier 1
# instead of erroring "This scope cannot be saved from this screen."
check_B2_field_writer_handles_sku() {
    multiline_contains "SKU:\\s*'admin/configuration/setSkuPutawayDestination'" "$V_FIELD"
}
# NEGATIVE and load-bearing: the SKU write must NOT send confirmIncompatibleSkus. The endpoint does not
# take it — `PutawayConfigController.setSku` is `(@PathVariable Long itemdataId, @RequestParam(required
# = false) Long locationId)` and its javadoc is explicit: "SKU scope writes straight through: the blast
# radius is one SKU, so D11's count-and-confirm does not apply and there is no confirmIncompatibleSkus
# parameter to honour." At SKU scope `preview`'s counts are degenerate (0-or-1 of 1), so a shared
# `incompatibleSkuCount > 0` test would raise a confirm dialog in front of a write that cannot honour
# the answer — a confirmation the operator cannot actually give.
check_B2_neg_sku_write_sends_no_confirm() {
    # ⚠ Gap TEMPERED against `async ` rather than a {0,600} budget, which covered barely half of an action
    # that runs ~1,100 chars to its handler. ⚠ CORRECTION: an earlier version of this comment claimed the
    # old form went green on a param injected into the catch. Re-review could not reproduce that — the old
    # form failed too, but only by accident: `setSkuPutawayDestination` appears a SECOND time inside the
    # catch's console.error string, exactly 600 chars from the first anchor, so a one-word edit to that log
    # message would have flipped it. The row was saved by coincidence, which is reason enough to temper it.
    # The tempered form was verified properly: red on a catch injection, red on a success-path injection,
    # green when the param appears in the NEIGHBOURING action. Same repair as B2-body, one row away.
    multiline_not_contains 'setSkuPutawayDestination(?:(?!async )[\s\S])*?confirmIncompatibleSkus' "$S_CONFIG"
}
# POSITIVE: the SKU path skips D11's confirm rather than inheriting it by accident.
check_B2_sku_skips_d11_confirm() {
    multiline_contains "scope\\s*===\\s*'SKU'" "$V_FIELD"
}
# ============================================================================
# ⚠ BANNER ROWS REWRITTEN r7 (2026-08-12) — THEIR PREMISE EXPIRED TWICE.
# ============================================================================
# These asserted that the banner names SBDEV-2821 as "the ticket that will make pick faces selectable"
# and 2732 Q9 as "the design decision behind the current restriction". BOTH halves are now false:
#
#   1. D1 was RE-REVERSED in r3. The SKU picker DOES offer pick faces, including flowbins — tier 1 is
#      exempt from 2732's P2.7 rule (e). §3.8.2a was never reconciled to that; it still carries r2's
#      "Pick faces (flowbins) are not yet selectable as a SKU default" text, which contradicts the D1
#      row three sections earlier. r4 claimed to reconcile the body to r3 and missed this.
#   2. SBDEV-2821 MERGED on 2026-08-09 (PR #135, merge fd90487, ClickUp `on dev`). A banner telling an
#      operator to wait for a ticket that already shipped is confidently wrong — the §14-principle-4
#      inversion this banner block was written to prevent.
#
# Measured confirmation that pick faces are offered: 2732 reports SKU scope returning 2,554 eligible
# rows on wms2-wineco-dev against 516 at merchant/warehouse scope. The gap IS the pick faces.
#
# What the banner must say instead is r3's D1 text: a pick-face destination is ROUTED VIA PUTAWAY, not
# placed directly at receipt — and the operational consequence, that the stock is not on the pick face
# when the receipt closes; it arrives when someone puts it away. That is the SBDEV-2731 defect class
# (the screen showing ICE PACK while stock lands on PutAwayLane), so it is not optional copy.
#
# The banner lives on 2643's dialog, not on the wrapper: the wrapper serves three scopes and this
# statement is true only at SKU scope.
# ⚠ ANCHORED TO THE BANNER ELEMENT. The old pattern matched `(routed|diverted)…putaway` ANYWHERE in the
# file, and after the banner was rewritten to mirror 2732's approved copy it matched only the PRE-EXISTING
# `effective.divertedTo` line — so the row would have stayed green with the banner deleted outright, while
# its own comment block says that copy "is not optional". Tempered against `</v-alert>` so the phrase must
# sit inside the banner it is supposed to be gating.
check_B2_banner_states_routed_via_putaway() {
    file_exists "$V_DIALOG" \
      && multiline_contains '<v-alert(?:(?!</v-alert>)[\s\S])*?(?i:putaway will move|routed via putaway)(?:(?!</v-alert>)[\s\S])*?</v-alert>' "$V_DIALOG"
}
# The operational consequence, not just the mechanism. "Routed via putaway" means nothing to an
# operator who does not already know it implies a delay before the stock is on the face.
check_B2_banner_states_consequence() {
    file_exists "$V_DIALOG" \
      && multiline_contains '(not on the pick face|arrives when|until someone puts|after putaway)' "$V_DIALOG"
}
# NEGATIVE: the expired framing must not survive. Either string means the banner is telling operators
# to wait for shipped work, or that a destination they can in fact select is unselectable.
check_B2_neg_banner_expired_framing() {
    file_exists "$V_DIALOG" \
      && file_not_contains 'SBDEV-2821' "$V_DIALOG" \
      && file_not_contains 'not yet selectable' "$V_DIALOG"
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
# ⚠ check_B2_dialog_handrolled_validation DELETED r7. It required `validated()` + `$toast.error` IN THE
# DIALOG, copied from the editPackagingDialog idiom. Under reuse the dialog validates nothing — the
# wrapper owns Save-gating (`saveDisabled` = !canEdit || saving || blockingReason != null) and the
# toasts. Keeping the row would have forced a hand-rolled validator whose only job was to duplicate a
# gate that already exists, and duplicating that gate is the defect B2-neg-dup now catches.
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
# POSITIVE: the write action targets 2732's validated endpoint. REPOINTED r7 from the skuData store to
# `store/admin/configuration.js`, where `setWarehousePutawayDestination` and
# `setMerchantPutawayDestination` already live and where the wrapper dispatches from. Tier 1 sitting in
# a different store module than tiers 2 and 3 is how the three drift apart.
check_B2_store_targets_putawayconfig() {
    file_contains '\$put\(`?/putawayConfig/sku/' "$S_CONFIG"
}
# NEGATIVE — the headline UI check. The legacy GET is unvalidated, unaudited,
# the wrong verb, and its @CacheEvict(allEntries=true) flushes EVERY tenant.
# r7: checked in BOTH stores, since the write moved to admin/configuration.js and the skuData store
# must not keep a second path to the same field.
check_B2_neg_no_legacy_endpoint() {
    file_not_contains 'setPutAwayLocation' "$S_CONFIG" \
      && file_not_contains 'setPutAwayLocation' "$S_SKUDATA"
}
check_B2_neg_no_legacy_in_dialog() {
    file_not_contains 'setPutAwayLocation' "$V_DIALOG"
}
# POSITIVE: Clear OMITS the query parameter entirely (2732 §3.5a: omitted => clear).
# Sending ?locationId= or ?locationId=null would not clear — `locationId` is a `required = false Long`,
# so the literal string "null" is a 400, not a clear. REPOINTED r7 to admin/configuration.js.
check_B2_clear_omits_param() {
    multiline_contains 'setSkuPutawayDestination[\s\S]{0,700}?locationId[\s\S]{0,120}?(!=\s*null|==\s*null|append\()' "$S_CONFIG"
}
check_B2_neg_no_null_in_querystring() {
    file_not_contains 'locationId=\$\{?(null|data\.locationId\s*\|\|)' "$S_CONFIG"
}
# POSITIVE: 422/409 bodies reach the operator. A bare "network or server issue"
# toast hides every validation message the ticket asks to be actionable. REPOINTED r7.
# ⚠ This is the row the 2732 review round proved matters: "every 409/422 message was discarded" was one
# of its six defects, in this exact component family.
# ⚠ RESHAPED — the original asserted `response.data` within 900 chars of the action name, which the correct
# implementation does NOT contain and a COMMENT easily does. Both sibling writers surface the body through
# the shared `putawayWriteError` helper; inlining the expression to satisfy a regex would have duplicated
# that helper, and mentioning it in prose would have satisfied the row from a comment (caught before
# shipping, 2026-08-12 — the fifth instance of the comment-vs-code trap on this ticket).
# Now pins the real mechanism in two halves: the action routes its failure through the helper, AND the
# helper reads the response body. Neither half is satisfiable by prose in the action.
check_B2_surfaces_response_body() {
    # Gap TEMPERED against `async `, not a character budget: the original `{0,900}` was too small for a
    # documented action (measured 1,126 chars to the handler), so a correct implementation failed on
    # comment length. `async ` begins the next action, which bounds the match to this one's own extent —
    # the containment the window was reaching for, without a number that must grow with every comment.
    multiline_contains 'setSkuPutawayDestination(?:(?!async )[\s\S])*?putawayWriteError\s*\(\s*error\s*\)' "$S_CONFIG" \
      && multiline_contains 'function\s+putawayWriteError[\s\S]{0,300}?error\.response\.data' "$S_CONFIG"
}
# POSITIVE: read-after-write refetches THIS SKU, not the whole table.
# ⚠ REPOINTED from $S_SKUDATA to $V_SKUDATA. The row asked the skuData STORE to dispatch `getSkuDetail`,
# which would mean a store action dispatching a sibling action in its own module purely to satisfy a grep.
# The requirement is behavioural — "after a write, THIS SKU's detail is re-read, and the table is not
# re-paged" — and it is the SCREEN that owns it: the dialog emits `saved`, skuData.vue re-reads the one
# row. Fourth row on this ticket that named the wrong file rather than the wrong property.
# The re-paging half is unaffected and still guarded by B2-neg-page against the config store.
check_B2_refetches_detail() {
    # ⚠ The old second conjunct (`getSkuDetail` appears in $V_SKUDATA) was VACUOUS: showDetails already
    # used it on develop, so that half passed pre-B2 and detected nothing. Replaced with the property that
    # is actually B2's — the saved handler is WIRED to the dialog — so both conjuncts are B2-gated.
    multiline_contains 'onPutawaySaved[\s\S]{0,400}?showDetails\s*\(' "$V_SKUDATA" \
      && multiline_contains '@saved\s*=\s*"onPutawaySaved"' "$V_SKUDATA"
}
check_B2_neg_does_not_repage_table() {
    multiline_not_contains "setSkuPutawayDestination[\s\S]{0,900}?dispatch\('searchSkuData'" "$S_CONFIG"
}
# POSITIVE: the effective-destination read action exists and hits 2643's SKU-scope endpoint.
# ⚠ TIGHTENED r7. The bare `effectivePutawayDestination` grep now passes on 2732's merged
# `getEffectivePutawayDestination`, which reads `/client/{id}/effectivePutawayDestination` — the
# MERCHANT tier. A row that goes green on someone else's endpoint for a different tier is not a check.
# 2643's A2 read is the itemData path, and the path is what distinguishes them.
check_B2_effective_read_action() {
    file_contains 'itemData/\$\{[^}]+\}/effectivePutawayDestination' "$S_CONFIG" \
      || file_contains 'itemData/\$\{[^}]+\}/effectivePutawayDestination' "$S_SKUDATA"
}
# CONTEXT — D3: the picker did NOT go back to /location/detailView client-side.
check_B2_neg_not_detailview_backed() {
    file_not_contains 'location/detailView' "$V_DIALOG"
}
# CONTEXT — D3 / §14 principle 2: exactly ONE eligibleLocations reader in the UI, and it is 2732's.
# ⚠ REWRITTEN r7 — the 2026-08-08 form demanded `eligibleLocations` be PRESENT in the skuData store.
# That was right when 2643 expected to ship the reader itself (Phase A3). A3 is deleted and 2732 shipped
# `getEligiblePutawayLocations` in store/admin/configuration.js, so the old row now forces 2643 to add a
# SECOND reader for the same endpoint — it would go green on precisely the duplication D3 forbids.
# Inverted: the shared store has it, and neither 2643-adjacent module re-implements it.
check_B2_single_eligible_reader() {
    file_contains 'eligibleLocations' "$S_CONFIG" \
      && file_not_contains 'eligibleLocations' "$S_SKUDATA" \
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
# V2.2.13, someone added SQL to this ticket.
# ⚠ REWRITTEN r7 (2026-08-12) — the version-range form below was a FALSE FAIL, and it went red the
# moment OTHER tickets shipped migrations. It counted `V2.2.1[2-9]` etc. in the migration directory and
# demanded zero; by 2026-08-12 develop carries V2.2.12 (PR #137, transaction-detail UL picks) and
# V2.2.13 (SBDEV-2732), so the row failed because someone else's work exists. That is the recorded
# failure mode "a permanently-red row is indistinguishable from unimplemented work".
#
# The property this row actually wants is DIFFERENTIAL: 2643 adds no migration OF ITS OWN. Compare
# against the merge-base with develop, not against an absolute version window — that stays correct no
# matter how far the version head advances.
# ⚠ FAILS CLOSED. If the merge-base cannot be resolved (no git, no origin/develop, detached shadow
# root) this row goes RED rather than green. An unresolvable baseline means the question "did 2643 add
# a migration?" was not answered, and principle 5 says an unanswered question is not a pass.
check_X_no_new_migration() {
    local base added
    base=$(git -C "$PROJECT_ROOT" merge-base HEAD origin/develop 2>/dev/null) || return 1
    [ -n "$base" ] || return 1
    added=$(git -C "$PROJECT_ROOT" diff --name-only --diff-filter=A "$base" HEAD \
        -- src/main/resources/db/migration/ 2>/dev/null | wc -l) || return 1
    [ "$added" -eq 0 ]
}
# The @NotNull on Itemdata is 2732's to remove, not 2643's.
check_X_notnull_not_touched_by_2643() {
    file_contains 'putawaylocationId' "$F_ITEMDATA_MODEL"
}
# INVERTED 2026-08-27 (SBDEV-3017). This row used to assert the legacy endpoint was STILL PRESENT,
# on 2732 §10.4 Q5's reasoning that 2643 simply never calls it so asserting its absence would be
# wrong. That premise expired: GET /v3/itemData/setPutAwayLocation and the orphaned
# ItemdataService.setPutAwayLocation were DELETED at Nam's instruction on 2026-08-27, because a
# mutating GET on a controller outside FunctionGuardInterceptor.GUARDED is ungated the moment its
# @RequiresFunction is lost — which a review measured actually happening against all 5673 tests.
#
# Left as-is it would be a PERMANENTLY-RED row, which is worse than no row: indistinguishable from
# unfinished work. Inverted rather than deleted, because the direction that is now load-bearing is
# the negative — the endpoint must not come BACK. The API pins this properly in
# PutawayConfigActionGuardUnitTest#theDeletedLegacySkuPathHasNotReturned (all verbs, type-resolved);
# this row is the cross-repo echo, and the JUnit pin is the authority.
check_X_legacy_endpoint_deleted() {
    code_not_contains 'setPutAwayLocation' "$F_ITEMDATA_CTL"
}
# L7 (2026-08-27): the SERVICE half had no row in either script — only the JUnit pin — while the commit
# message presented both halves as pinned in both places. ItemdataService.setPutAwayLocation delegated
# into the validated writer and @RequiresFunction cannot gate a service method, so it was the ungatable
# twin of the endpoint above and deserves the same cheap echo.
check_X_legacy_service_method_deleted() {
    code_not_contains 'setPutAwayLocation' "$F_ITEMDATA_SVC"
}
# archunit_store must not be committed dirty — `mvn test` mutates it.
check_X_archunit_store_clean() {
    (cd "$PROJECT_ROOT" && git diff --quiet -- src/test/resources/archunit_store/ 2>/dev/null)
}
# CROSS-CUTTING GUARD — NOT a 2643 deliverable, and no longer 2732-gated.
#
# SUPERSEDED 2026-08-09. This block used to explain why the script probed 2732's
# file for the broken constant. SBDEV-2863 (PR #134) repaired Authority.java:44 to
# hasAuthority('sb_admin'), which makes 2732 §3.12's six @PreAuthorize sites correct
# as written and voids the whole premise. What remains worth guarding is that the
# repair does not regress underneath either ticket — that is
# check_X_authz_constant_repaired, defined above beside the A2 negative it pairs
# with. It reads Authority.java only, so unlike its predecessor it runs today.

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
if migration_2213_present; then
    echo "  V2.2.13 (2732's)       : PRESENT -> AC4 / AC9 reachable"
else
    echo "  V2.2.13 (2732's)       : ABSENT  -> AC4 (clear) and AC9 (audit) unreachable"
fi
echo

# Phase A0 is RETIRED — SBDEV-2863 (PR #134, 2026-08-07) shipped the constant fix and
# the SpEL detector together. Its five rows are deleted, not skipped; see the block at
# the head of this file. The surviving cross-cutting guard runs with the other X- rows.
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
    run A2-labels    "A2 — the four sourceLabel literals agree in BOTH controllers" check_A2_source_labels_agree_across_both_controllers
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
# ============================================================================
# ⚠ THREE ROWS RETIRED HERE IN r7 (2026-08-12). READ BEFORE RE-ADDING ANY OF THEM.
# ============================================================================
# SBDEV-2732 shipped `eligibleLocations` on 2026-08-11 (PR #142, merge 41c8257), and these three rows
# then went RED against a CORRECT implementation. They are the recorded failure mode "verify rows go
# stale when a refactor moves code between files", in its worst form: 2643 asserting the internal shape
# of a construct another ticket owns.
#
#   A3-tx    — asserted `@Transactional(tenantTransactionManager, readOnly=true)` on
#              PutawayConfigController.eligibleLocations. 2732 deliberately shipped NO controller
#              transaction — the boundary lives on PutawayDestinationQueryService, and there is zero
#              @Transactional under controller/ by design — and 2732 PINS THAT with its own verify row
#              `P2A-ctl-no-tx` ("NEG: controller exposes it but owns NO transaction").
#              ⚠ TWO SCRIPTS IN ONE FEATURE FAMILY ASSERTED OPPOSITE THINGS ABOUT THE SAME METHOD.
#              2643's was the wrong one. Whichever implementation satisfied one would fail the other.
#   A3-lane  — grepped the CONTROLLER for STORAGE_LOCATION_PUTAWAY_LANE. The exclusion is real but
#              lives in the rules/query layer; 2732 asserts it correctly via `P2A-lane-name`.
#   A3-t1    — grepped for the test method name `eligibleLocationsSkuScopeTwoClasses`, which 2643
#              invented for a phase it no longer ships. 2732's tests never used that name, so the row
#              could only ever be red.
#
# The property all three were reaching for — "the endpoint 2643 consumes is correctly built" — is
# 2732's to assert, and 2732 asserts it. 2643's accountability starts at the CONSUMER rows below.
# Do not re-add these by copying an older revision of this script.
if dd_endpoint_present; then
    run A3-map       "A3 — GET /eligibleLocations mapped"                         check_A3_endpoint_mapping
    run A3-scope     "A3 — carries a PutawayScope parameter"                      check_A3_scope_param
    run A3-neg-advis "A3 — no advisory field / PICK_FACE reason (D1 reversed)"    check_A3_neg_no_advisory_class
    run A3-neg-stor  "A3 — NOT backed by getStorageLocationsForPutAwayItemData"   check_A3_neg_not_backed_by_storage_query
    run A3-t2        "A3 — test proves FIX_ASSIGNED stays BLOCKED (P2.5 absolute)" check_A3_test_fix_assigned_stays_blocked
else
    blocked A3-map      "A3 — GET /eligibleLocations mapped"                         "D-D not shipped — 2732 owns it (D12); A3 is the fallback"
    blocked A3-scope    "A3 — carries a PutawayScope parameter"                      "D-D not shipped — 2732 owns it (D12)"
    blocked A3-neg-advis "A3 — no advisory field / PICK_FACE reason (D1 reversed)"   "D-D not shipped — 2732 owns it (D12)"
    blocked A3-neg-stor "A3 — NOT backed by getStorageLocationsForPutAwayItemData"   "D-D not shipped — 2732 owns it (D12)"
    blocked A3-t2       "A3 — test proves FIX_ASSIGNED stays BLOCKED"                "D-D not shipped — 2732 owns it (D12)"
fi
# CONSUMER rows — 2643's OWN files. THESE are what 2643 is accountable for whoever
# ships the producer. They need the dialog, so they follow B2's gate.
if phase_2732_present && phase_2732_ui_present; then
    run A3-consume   "A3 — picker items come from /putawayConfig/eligibleLocations" check_A3_consumer_sources_from_endpoint
    run B2-neg-pred  "B2 — dialog re-implements NO predicate client-side (D3; was mis-ID'd A3-neg-pred)"      check_A3_neg_no_client_side_predicates
else
    blocked A3-consume  "A3 — picker items come from /putawayConfig/eligibleLocations" "needs 2732 step 18a (eligibleLocations) + this plan's B2 dialog"
    blocked B2-neg-pred "B2 — dialog re-implements NO predicate client-side (D3)"      "needs 2732 step 18a (eligibleLocations) + this plan's B2 dialog"
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
run B1-perm      "B1 — gate is REACTIVE DATA, not a \$kc computed (r7)"       check_B1_permission_reactive_data
run B1-cfg       "B1 — gate imports 2732's shared role helper (r7)"          check_B1_gate_uses_shared_role_helper
run B1-neg-cfg   "B1 — no appAdminGroup / hasRealmRole / hasResourceRole (r7)" check_B1_neg_dead_gate_forms
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

echo "--- Phase A4 — the name search parameter (§3.5a, NEW r7: Q4 -> (ii)) ---"
# ⚠ NO GUARD, DELIBERATELY. The first draft of this block wrapped these seven rows in
# `if phase_selected 2 || phase_selected 1; then` — and `phase_selected` DOES NOT EXIST in this script
# (it was borrowed from SBDEV-2732's). Bash returned 127, the `if` evaluated false, and ALL SEVEN ROWS
# SILENTLY DISAPPEARED: the total stayed at 23 pass / 63 fail, so the run looked unchanged rather than
# broken. `bash -n` passes an undefined function, and an audit that checks only `run` targets does not
# look at guards. This is a NEW variant of the recorded "undefined fn reads as an honest FAIL" trap —
# in a guard it is worse than a false FAIL, because the rows do not appear at all.
# Every other phase block here is unguarded; these follow suit.
run A4-ctl       "A4 — controller takes an optional String name"           check_A4_controller_name_param
run A4-svc       "A4 — query service takes the name parameter"            check_A4_service_name_param
run A4-inquery   "A4 — case-insensitive filter applied IN the query"      check_A4_filter_in_query
run A4-split     "A4 — R11: the UNSEARCHED query is untouched (split, not parameterised)" check_A4_r11_query_split
run A4-branch    "A4 — service BRANCHES on a blank term, no LIKE '%%'"    check_A4_service_branches_on_blank
run A4-neg-native "A4 — JPQL not native SQL (H2 lane, cf 2732 P2A-h2)"    check_A4_neg_not_native
run A4-t-empty   "A4 — empty-search identity is TESTED (tiers 2/3 safety)" check_A4_test_empty_search_identity
# A4-neg-banner and A4-debounce moved to the B2 block — they inspect $V_DIALOG, which B2 creates. See
# check_A4_debounced for why leaving them here was worse than a coverage gap.
echo

echo "--- Phase B2 — edit dialog and the write ---"
if phase_2732_present && phase_2732_ui_present; then
    run B2-dialog    "B2 — editSkuPutawayDialog.vue exists"                      check_B2_dialog_exists
    run B2-field     "B2 — REUSES 2732's defaultPutawayLocationField at SKU scope (r7)" check_B2_dialog_reuses_2732_field
    run B2-neg-raw   "B2 — does NOT mount LocationPicker directly (r7)"          check_B2_neg_dialog_bypasses_wrapper
    run B2-neg-dup   "B2 — no second copy of the preview gate (r7)"              check_B2_neg_no_duplicate_preview_gate
    run B2-sku-write "B2 — wrapper's scope→writer map gains SKU (r7)"            check_B2_field_writer_handles_sku
    run B2-neg-conf  "B2 — SKU write sends NO confirmIncompatibleSkus (r7)"      check_B2_neg_sku_write_sends_no_confirm
    run B2-skip-d11  "B2 — SKU path skips D11's confirm (r7)"                    check_B2_sku_skips_d11_confirm
    run B2-neg-form  "B2 — no v-form/rules/Vuelidate"                            check_B2_neg_no_vform_rules
    run B2-banner    "B2 — banner says pick faces are ROUTED VIA PUTAWAY (r7)"   check_B2_banner_states_routed_via_putaway
    run B2-banner2   "B2 — banner states the operational consequence (r7)"       check_B2_banner_states_consequence
    run B2-neg-bann  "B2 — expired 'SBDEV-2821 / not yet selectable' framing gone (r7)" check_B2_neg_banner_expired_framing
    run B2-banner3   "B2 — banner counts COMPUTED, not hard-coded tenant numbers" check_B2_banner_count_not_hardcoded
    run B2-neg-advis "B2 — no per-row advisory / PICK_FACE state (D1 reversed)"   check_B2_neg_no_advisory_state
    run B2-clear     "B2 — Clear / Use default affordance present"                check_B2_clear_affordance
    run B2-endpoint  "B2 — store action targets PUT /putawayConfig/sku/"          check_B2_store_targets_putawayconfig
    run B2-neg-leg   "B2 — legacy setPutAwayLocation NOT in either store"        check_B2_neg_no_legacy_endpoint
    run B2-neg-leg2  "B2 — legacy setPutAwayLocation NOT in the dialog"           check_B2_neg_no_legacy_in_dialog
    run B2-clearq    "B2 — Clear OMITS locationId entirely"                       check_B2_clear_omits_param
    run B2-neg-null  "B2 — never sends locationId=null in the query string"       check_B2_neg_no_null_in_querystring
    run B2-body      "B2 — surfaces response.data so 422s reach the operator"     check_B2_surfaces_response_body
    run B2-refetch   "B2 — re-dispatches getSkuDetail after a write"              check_B2_refetches_detail
    run B2-neg-page  "B2 — does NOT re-dispatch searchSkuData (keeps the page)"   check_B2_neg_does_not_repage_table
    run B2-eff       "B2 — effective-destination read hits the itemData path (r7)" check_B2_effective_read_action
    run B2-neg-dv    "B2 — dialog not backed by /location/detailView (D3)"        check_B2_neg_not_detailview_backed
    run B2-one-elig  "B2 — exactly ONE eligibleLocations reader, and it is 2732's (r7)" check_B2_single_eligible_reader
    run A4-neg-banner "B2 — banner counts NOT taken from a search-narrowed page (A4's consumer)" check_A4_neg_banner_from_search
    run A4-debounce  "B2 — the A4 search box is debounced"                        check_A4_debounced
    run B2-jest1     "B2 — editSkuPutawayDialog.spec.js exists"                   check_B2_jest_dialog_spec_exists
    run B2-jest2     "B2 — store spec exists"                                     check_B2_jest_store_spec_exists
    run B2-jest3     "B2 — store spec asserts the putawayConfig endpoint"         check_B2_jest_store_asserts_endpoint
    run B2-jest4     "B2 — store spec asserts the legacy GET is never called"     check_B2_jest_store_asserts_no_legacy
else
    for c in \
      "B2-dialog|editSkuPutawayDialog.vue exists" \
      "B2-field|REUSES 2732's defaultPutawayLocationField at SKU scope (r7)" \
      "B2-neg-raw|does NOT mount LocationPicker directly (r7)" \
      "B2-neg-dup|no second copy of the preview gate (r7)" \
      "B2-sku-write|wrapper's scope→writer map gains SKU (r7)" \
      "B2-neg-conf|SKU write sends NO confirmIncompatibleSkus (r7)" \
      "B2-skip-d11|SKU path skips D11's confirm (r7)" \
      "B2-neg-form|no v-form/rules/Vuelidate" \
      "B2-banner|banner says pick faces are ROUTED VIA PUTAWAY (r7)" \
      "B2-banner2|banner states the operational consequence (r7)" \
      "B2-neg-bann|expired 'SBDEV-2821 / not yet selectable' framing gone (r7)" \
      "B2-banner3|banner counts COMPUTED, not hard-coded tenant numbers" \
      "B2-neg-advis|no per-row advisory / PICK_FACE state (D1 reversed)" \
      "B2-clear|Clear / Use default affordance present" \
      "B2-endpoint|store action targets PUT /putawayConfig/sku/" \
      "B2-neg-leg|legacy setPutAwayLocation NOT in either store" \
      "B2-neg-leg2|legacy setPutAwayLocation NOT in the dialog" \
      "B2-clearq|Clear OMITS locationId entirely" \
      "B2-neg-null|never sends locationId=null in the query string" \
      "B2-body|surfaces response.data so 422s reach the operator" \
      "B2-refetch|re-dispatches getSkuDetail after a write" \
      "B2-neg-page|does NOT re-dispatch searchSkuData" \
      "B2-eff|effective-destination read hits the itemData path (r7)" \
      "B2-neg-dv|dialog not backed by /location/detailView (D3)" \
      "B2-one-elig|exactly ONE eligibleLocations reader, and it is 2732's (r7)" \
      "B2-jest1|editSkuPutawayDialog.spec.js exists" \
      "B2-jest2|store spec exists" \
      "B2-jest3|store spec asserts the putawayConfig endpoint" \
      "B2-jest4|store spec asserts the legacy GET is never called" ; do
        blocked "${c%%|*}" "B2 — ${c#*|}" "needs this plan's B2 (2732 Phase 2 is MERGED as of 2026-08-11)"
    done
fi
echo

echo "--- Cross-cutting invariants (runnable in every phase) ---"
run X-nomig      "X — 2643 ships ZERO migrations"                            check_X_no_new_migration
run X-notnull    "X — Itemdata.putawaylocationId untouched by 2643"          check_X_notnull_not_touched_by_2643
run X-legacy     "X — legacy setPutAwayLocation endpoint DELETED (SBDEV-3017)"    check_X_legacy_endpoint_deleted
run X-legacy-svc "X — legacy ItemdataService.setPutAwayLocation DELETED (SBDEV-3017)" check_X_legacy_service_method_deleted
run X-archunit   "X — archunit_store is clean (mvn test mutates it)"         check_X_archunit_store_clean
# CROSS-CUTTING GUARD — runs today, never blocked. A FAIL means SBDEV-2863's repair
# regressed, which silently 500s every admin-gated endpoint in BOTH tickets.
run X-authz-constant "X — SBDEV-2863's IS_SB_ADMIN repair still in place (AC12)"  check_X_authz_constant_repaired
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
    # A0-test retired with phase A0 — CustomMethodSecurityExpressionRootUnitTest is
    # SBDEV-2863's file now, green on develop, and not 2643's to gate on.
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
    echo "  ⚠ $SKIP check(s) SKIPPED — blocked on SBDEV-2732 PHASE 2 (web UI + step 18a),"
    echo "    which is NOT STARTED. Phase 1-API merged 2026-08-11 (889298d), so anything blocked"
    echo "    on Phase 1-API now FAILs as contract drift rather than skipping."
    echo "    A green run with SKIPs is NOT 'done'. The plan's §8.4 requires 0 fail AND 0 skip."
fi

[ "$FAIL" -eq 0 ]
