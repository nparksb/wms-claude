#!/usr/bin/env bash
# verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2732-configurable-default-putaway-location-hierarchy.md
#
# Usage
# -----
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh
#   $ PROJECT_ROOT=/somewhere/else RUN_MVN=1 bash .../verify-SBDEV-2732-....sh
#
# Exit code 0 iff every check passes. Checks are grouped by rollout phase so the
# output reads in the order §8.1 says to ship them.
#
# ============================================================================
# NEGATIVE CONTROL — READ THIS BEFORE ACCEPTING ANY "N pass, 0 fail" RESULT
# ============================================================================
# A green run means NOTHING until it has been replayed against the PRE-CHANGE
# tree and observed to FAIL there. SBDEV-2736 scored 57 pass / 0 fail on the
# very build that contained the defect the ticket was written to catch.
#
#   git stash && bash sbdocs/9-System/scripts/verify-SBDEV-2732-....sh ; git stash pop
#
# The stashed run MUST produce a large number of FAIL lines. If it reports
# 0 fail, THE SCRIPT IS BROKEN, not the implementation.
#
# BASELINE RE-RECORDED 2026-08-04 against `origin/develop` (supersedes the 2026-07-31 baseline):
#     PHASE=all   9 pass, 159 fail, 3 skip   (171 checks)   <-- whole-plan
#     PHASE=1     9 pass, 153 fail, 3 skip   (165 evaluated,   6 filtered)
#     PHASE=2     8 pass,   6 fail, 3 skip   ( 17 evaluated, 154 filtered)
#
#     ARITHMETIC SELF-CHECK: 165 + 17 = 182 = 171 + 11, the 11 checks running in both phases.
#
#     WHY IT MOVED from the 2026-07-31 baseline (8/153/4, 161 checks):
#       * migration renamed V2.2.08 -> V2.2.10 (D16 — V2.2.08 was taken by SBDEV-2801, V2.2.09 by
#         SBDEV-2778, both merged 2026-08-04).
#       * migration renamed V2.2.10 -> V2.2.13 on 2026-08-06 — SBDEV-2854 (PR #132, open and pushed)
#         took V2.2.10 to keep the sequence contiguous. M-exists now looks for the V2.2.13 filename.
#       * +5 NEW checks for P2.5 / P2.7(c), the D15 enforcement point: V-fixloc, V-fixabs, T-skufix,
#         T-merchfix, T-stagingok. There were previously ZERO fix-assignment checks in this script.
#       * stale `1a-API` / `1b-API` section LABELS corrected to `1-API`. The runtime bucketing was
#         already single-phase (`phase()` is only ever called with 1 / 2 / all) — only the comments
#         and echo headers were stale, so no check changed bucket.
#
#     THE 9 PRE-IMPLEMENTATION PASSES ARE ALL LEGITIMATE, none vacuous — verified 2026-08-04. They are
#     preservation / must-not-regress assertions against code that already exists (E-col, E-lane,
#     UBS-neg4, UBS-lock, S3-pos1, S3-pos2, W-onetx, W-2102, W-neg4), two of them explicit NEG checks.
#     A 10th pass appearing without a corresponding implementation step is a red flag.
#
#     NEGATIVE CONTROL for the 5 new checks (run 2026-08-04): all five FAIL on the unimplemented tree,
#     and they fail CLOSED rather than vacuously — `file_contains_i` and `file_not_contains_multiline`
#     both open with `[ -f "$2" ] || return 1`, so a missing file is a FAIL, not a silent pass. Note
#     V-fixabs is a NEGATIVE assertion (the validator must NOT compare `getItemdataId` near
#     `findByAssignedlocationId`): it goes green on the correct ABSOLUTE form and red if someone
#     implements the mismatch-only form, which belongs to SBDEV-2821, not here.
#     pinned to `all` and therefore run in every phase (counted 3x instead of 1x ⇒ +16). Every phase
#     shows exactly 8 passes for that reason — those checks must stay green throughout, not just at
#     the end. If this arithmetic stops holding, a `phase` marker was lost or a run line crossed a
#     section boundary.
#
#     BUCKETS ARE NOT PURELY SECTIONAL — 19 checks carry a `runp` per-check override, because section
#     granularity was wrong in BOTH directions, and needed TWO correction rounds:
#       under-covering  E-const (the WmsConstants key Phase 1a step 2 ships) sat in the 1b section
#       over-demanding  round 1: C-writers ("three writers" — 1a ships two), C-evictcl (merchant
#                       cache), C-audit (audit table, deferred to 1b by O1)
#                       round 2: CTL-auth (demands 3 @PreAuthorize; 1a ships setSku + setWarehouse
#                       only, so it is split into CTL-auth2 for 1a and CTL-auth for 1b), H-cl (the
#                       onClient handler O2 says cannot compile in 1a), and the five A-* audit-service
#                       checks (their entity and repository are bucketed 1b)
#     Every one of those made `PHASE=1a` 0-fail UNREACHABLE — the exact failure O4 exists to prevent,
#     re-created one layer down. If you add a check, ask which phase SHIPS it, not which section it
#     reads best in.
#
#     (was 8 pass, 133 fail, 1 skip across 141 checks pre-revision. The PASS count must stay at 8:
#      it is the vacuity tripwire. A run reporting materially more than 8 passes on an unimplemented
#      tree means a check lost its teeth — W-nocgrd did exactly that and had to be conjoined.)
#
#     PLACEMENT TRAP, learned the hard way: the `phase` markers MUST live in the RUN block at the
#     bottom, not beside the check-function definitions. All 159 `run` calls execute after every
#     definition, so markers placed among the definitions leave CURRENT_PHASE stuck at whatever the
#     last one set — which silently made PHASE=2 run everything and PHASE=1a run nothing.
# All 8 pre-existing passes are deliberate PRESERVATION checks that must be green
# both before AND after implementation:
#     E-col, E-lane, UBS-lock, S3-pos1, S3-pos2, W-onetx, W-2102, W-neg4
# W-neg4 is inherently vacuous before implementation — it asserts a symbol that
# does not exist yet is not present in a file. That is unavoidable for a
# "never wire X into Y" check, and it becomes load-bearing the moment the
# resolver exists. Every other negative check FAILS on the pre-change tree
# because of the `[ -f ]` guards, which is the fix for template defect #2
# working as intended.
# If a future run reports materially MORE than 8 passes on an unimplemented
# tree, a check has gone vacuous — find it before trusting the script.
#
# ============================================================================
# TWO TEMPLATE DEFECTS ARE FIXED HERE — do not "simplify" them back
# ============================================================================
# 1. PROJECT_ROOT: verify-plan-template.sh ships a stale macOS v1 path
#    (/home/nampark/dev/wms-claude/v1/wms-api). This plan targets v2/wms2-api on
#    this machine, so the default is corrected below.
#
# 2. file_not_contains FAILS OPEN on a missing file: `grep` exits 2 when it
#    cannot open the path, and the leading `!` flips that non-zero into PASS.
#    Every helper that takes a path therefore starts with `[ -f "$2" ] || return 1`.
#    This matters doubly for the multi-line helper: `perl -0777 -ne` EXITS 0 when
#    it cannot open the file, so every multi-line assertion about a not-yet-created
#    file would false-green. Nine of this plan's files are new, so without the
#    guard roughly a third of this script would pass on an empty tree.

set -u
# ABORT GUARD, added 2026-08-09. `set -u` kills the script on an unbound variable mid-run — and it then
# prints NO "Result:" line, having silently skipped every remaining check. That happened during this
# session's audit: deleting a block took `CFGTEST=` with it and the run died at check 6 of ~180, which
# from a distance looked like a short clean pass. Anything consuming this script (ralph, CI, a human
# skimming) must treat a MISSING Result line as FAILURE. This trap makes that unmissable.
trap 'rc=$?; [ "${VERIFY_COMPLETED:-0}" = "1" ] || { echo; echo "*** ABORTED before completion (exit $rc) — checks after this point DID NOT RUN. Do NOT read this as a pass. ***"; }' EXIT

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
UI_ROOT="${UI_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-web-ui}"
RUN_MVN="${RUN_MVN:-0}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

# --- runner -----------------------------------------------------------------

# --- phase filter (ordering hazard O4) ---------------------------------------
# A whole-plan run shows ~90 FAILs for unbuilt later-phase work, so "0 fail" is UNREACHABLE as a
# per-phase exit condition and a ralph loop gated on it would never terminate. Select a phase with:
#
#     PHASE=1 bash verify-SBDEV-2732-....sh     # Phase 1-API  (no Flyway)
#     PHASE=1 bash verify-SBDEV-2732-....sh     # Phase 1-API  (carries V2.2.13)
#     PHASE=2  bash verify-SBDEV-2732-....sh     # web UI
#     bash verify-SBDEV-2732-....sh              # everything (default)
#
# !! MAPPING CAVEAT — READ BEFORE USING THIS AS A MERGE GATE !!
# The buckets below are assigned at SECTION granularity and are a FIRST CUT. They have not been
# validated check-by-check against §5.2's step tables. Assignment is deliberately CONSERVATIVE: a
# section that spans both phases is bucketed to 1b, so a PHASE=1a run may under-report rather than
# demand work 1a does not ship. Before trusting `PHASE=1a … 0 fail` as the ralph exit condition,
# walk §5.2's Phase-1a step table and confirm every check it implies is actually in the 1a bucket.
PHASE="${PHASE:-all}"
# GUARD added 2026-08-06. The plan (§11.1) told implementers to run `PHASE=1a|1b|2`, but the
# only values this script recognises are 1, 2 and all — every phase() call uses those. An
# unrecognised value matches no check, filters ALL of them, and exits 0 having verified
# NOTHING. Since §11.2 makes `PHASE=<phase> 0 fail` the ralph exit condition, a typo would
# read as a clean pass. Fail loudly instead.
case "$PHASE" in
    1|2|all) ;;
    *) echo "FATAL: unknown PHASE='$PHASE' (expected 1, 2 or all)" >&2; exit 2 ;;
esac
CURRENT_PHASE=all
FILTERED=0

phase() { CURRENT_PHASE="$1"; }

# runp <phase> <id> <desc> <cmd...> — per-check override for checks that sit in a section belonging to
# a DIFFERENT phase. Section granularity alone was wrong in both directions: it left the WmsConstants
# key (Phase 1a step 2) in the 1b bucket, and it put "three writers" / merchant-cache / audit checks in
# the 1a bucket, which made `PHASE=1a` 0-fail UNREACHABLE — the precise failure O4 exists to prevent.
runp() { local p=$1; shift; local save=$CURRENT_PHASE; CURRENT_PHASE=$p; run "$@"; CURRENT_PHASE=$save; }

phase_selected() {
    [ "$PHASE" = "all" ] && return 0
    [ "$CURRENT_PHASE" = "all" ] && return 0
    [ "$CURRENT_PHASE" = "$PHASE" ]
}

run() {
    local id=$1 desc=$2
    shift 2
    if ! phase_selected; then
        FILTERED=$((FILTERED+1))
        return 0
    fi
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-12s  %s\n" "$id" "$desc"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-12s  %s\n" "$id" "$desc"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-12s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- assertion helpers ------------------------------------------------------
# EVERY helper below guards on file existence FIRST. See defect #2 above.

# file_contains <extended-regex> <file>
file_contains() {
    [ -f "$2" ] || return 1
    grep -qE "$1" "$2"
}

# file_not_contains <extended-regex> <file>
# FIXED: the `[ -f ]` guard stops a missing file from passing via grep's exit 2.
file_not_contains() {
    [ -f "$2" ] || return 1
    ! grep -qE "$1" "$2"
}

# code_not_contains <regex> <file> — file_not_contains, but ignoring COMMENT-ONLY lines.
# ⚠ Required for any negative row about a DELETED symbol: a good deletion leaves a tombstone comment
# naming what it removed, and that comment satisfies a plain negative grep, reddening the row against
# CORRECT code. Ported here 2026-08-27 (SBDEV-3017 review L5) — these two rows had been passing only
# because a tombstone happened to capitalise one letter differently than the pattern, i.e. by luck.
# Both guards are load-bearing: [ -f ] because ! grep on a missing file PASSes; [ -r ] because on an
# unreadable file grep exits 2 and ! inverts the no-match into a PASS too.
code_not_contains() {
    [ -f "$2" ] && [ -r "$2" ] || return 1
    ! grep -vE '^[[:space:]]*(//|\*|/\*|#)' "$2" | grep -qE "$1"
}

# file_contains_n_times <extended-regex> <file> <n>
file_contains_n_times() {
    [ -f "$2" ] || return 1
    local count
    count=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$count" -ge "$3" ]
}

# file_contains_exactly_n <extended-regex> <file> <n>
file_contains_exactly_n() {
    [ -f "$2" ] || return 1
    local count
    count=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$count" -eq "$3" ]
}

# file_contains_multiline <perl-regex> <file>
# FIXED: `perl -0777 -ne` exits 0 when it cannot open the file, so the guard is
# load-bearing — without it every multi-line assertion about a NEW file passes.
# ⚠ TRAP, found by the step-18a TDD gate 2026-08-11: the pattern is interpolated into a perl
# /.../ match, so an UNESCAPED '/' in the pattern TERMINATES the delimiter and the perl program
# becomes a syntax error. Perl then exits non-zero and the row reports a plain FAIL — so the check
# is unsatisfiable, and it looks exactly like honest unimplemented work. `P2-eligible-endpoint` was
# written as file_contains_multiline '@GetMapping\(\s*"/eligibleLocations"\s*\)' and FAILED against a
# known-correct synthetic implementation. Either escape it as '\/' or use file_contains (grep -E),
# which has no delimiter. This joins the documented family: fail-open on missing files, vacuous
# negatives, and rows naming an undefined function.
file_contains_multiline() {
    [ -f "$2" ] || return 1
    perl -0777 -ne 'exit(/'"$1"'/s ? 0 : 1)' "$2"
}

# file_not_contains_multiline <perl-regex> <file>
# Same guard, inverted verdict. A missing file is a FAIL, never a pass.
file_not_contains_multiline() {
    [ -f "$2" ] || return 1
    ! perl -0777 -ne 'exit(/'"$1"'/s ? 0 : 1)' "$2"
}

# method_body <sed-BRE-matching-the-signature-line> <file>
# Prints from the signature line to the first line that is exactly four-space `}` — a method close at
# class-member indentation. ADDED 2026-08-11: two rows in the PR #139 round were written with
# `[\s\S]{0,N}` windows and both were wrong about their own N, one failing a CORRECT implementation
# and the other only by luck. A window is a guess about formatting; the body is the actual scope. Use
# this for any assertion of the form "X does / does not appear INSIDE method M", and always pair a
# negative with a positive on the same extraction so an empty extraction cannot pass vacuously.
method_body() {
    [ -f "$2" ] || return 1
    sed -n "/$1/,/^    }/p" "$2"
}

# code_only — filter stdin down to lines that are not `//`, `*` or `/*` comment lines.
# ADDED 2026-08-11: the first form of H-delneg failed because the COMMENT explaining why the delete
# must not call validateOnly contains the word "validateOnly". Every negative assertion in this file
# is exposed to that, and this codebase's comment-to-code ratio makes it likely rather than exotic:
# a prose mention is not a call. Pipe method_body through this before any grep for a symbol.
code_only() { grep -vE '^[[:space:]]*(//|\*|/\*)'; }

# vue_code_only <file> — strips BOTH JS comments and HTML comment BLOCKS, then prints the rest.
# ADDED 2026-08-11 after an independent verify lane demonstrated U19-warn staying green with the
# deadlock warning deleted and the words `deadlock`/`lock`/`receipt` left behind inside an
# `<!-- ... -->` block. `code_only` is line-oriented and only drops //, * and /* LINES, so an HTML
# comment's interior survives it. Any assertion about a .vue TEMPLATE must use this instead.
# ⚠ HARDENED 2026-08-12. It stripped whole-line comments only, so a TRAILING `//` note on a line that
# begins with code survived — and an independent lane demonstrated `U-degraded` going GREEN on the
# PRE-FIX file with six lines of the form `const X = 1 // putawayDestinationUnconfirmed: false` appended
# and no F3 code present at all. The real component has exactly ONE trailing comment today, so this was
# a future failure mode, not a live false green: a refactor that deletes the code but leaves a note
# mentioning the symbol re-greens the row.
#
# ⚠ WHAT THIS CAN AND CANNOT SEE — read before trusting any row built on it.
#
# It closes COMMENT channels. It cannot close STRING channels, and no comment-stripper can: a row token
# sitting in a string literal, a template literal, or a `<template>` text node is indistinguishable from
# code to a line-oriented filter. An independent lane greened `U-degraded` on the pre-fix file four ways
# through those channels. **The row's teeth come from Jest, not from here** — the same lane confirmed all
# four mutations that matter are each caught by exactly one test. Treat these regexes as a cheap
# structural cross-check, never as proof on their own.
#
# The lookbehind is `(?<!\w:)`, NOT `(?<!:)` and NOT `(?<![:\w])`:
#   `https://x`      -> `s:` before `//`, a scheme, so SPARED (else every URL truncates into a false FAIL)
#   `const A = 0 ://note` -> ` :` before `//`, not a scheme, so STRIPPED
# `(?<!:)` missed the second form entirely — a comment channel surviving a fix aimed at comment channels
# — and `(?<![:\w])` (suggested, measured, rejected) misses it too, since `:` is precisely what it skips.
# Residual: `case 1://note` still survives (`1:` reads as a scheme). Contrived; left alone deliberately.
#
# ⚠ Known latent false-FAIL, no live exposure: a protocol-relative string (`'//cdn.example.com/x'`) or
# `url.split('//')` gets truncated. Zero such lines exist in the seven files these rows assert against.
# The `(?<![\x27"])` on the block strip guards the same shape one level up — an unbalanced `/*` inside a
# string (e.g. `globPattern: '/*'`) otherwise pairs with a later real `*/` and deletes ~180 lines,
# turning correct code red.
vue_code_only() {
    [ -f "$1" ] || return 1
    perl -0777 -pe 's/<!--.*?-->//gs; s{(?<![\x27"])/\*.*?\*/}{}gs' "$1" \
      | grep -vE '^[[:space:]]*(//|\*|/\*)' \
      | perl -pe 's{(?<!\w:)//.*$}{}'
}

# file_contains_i <extended-regex> <file>   (case-insensitive)
file_contains_i() {
    [ -f "$2" ] || return 1
    grep -qiE "$1" "$2"
}

# file_exists <file>
file_exists() { [ -f "$1" ]; }

# mvn_test_passes <TestClassName>
# Whole classes only: `-Dtest='Outer#method'` silently no-ops for @Nested tests
# (false green), and most of these suites use @Nested.
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# --- path shorthands --------------------------------------------------------

SRC=src/main/java/net/aim_ai/wms
TST=src/test/java/net/aim_ai/wms
MIG=src/main/resources/db/migration/V2.2.13__putaway_destination_hierarchy.sql
MSG=src/main/resources/messages_en_US.properties

RESOLVER=$SRC/service/PutawayDestinationResolver.java
CFGSVC=$SRC/service/PutawayConfigService.java
VALIDATOR=$SRC/service/PutawayDestinationValidator.java
# ⚠ DEAD as of 2026-08-11, and deliberately kept with this note rather than deleted: the file it names has
# NEVER existed in any commit, and no row references this variable. The plan cited it as the extraction's
# behaviour-preservation guard three times. When that test is finally written (it must land BEFORE the
# PutawayDestinationRules extraction), wire P2-validator-tests-intact to it -- and guard the helper against a
# missing file first, or the row passes vacuously.
VTEST=$TST/unit/service/PutawayDestinationValidatorUnitTest.java   # currently absent -- see note above
AUDITSVC=$SRC/service/PutawayConfigAuditService.java
METRICS=$SRC/service/PutawayResolutionMetrics.java
AUDITENT=$SRC/model/PutawayConfigAudit.java
AUDITREPO=$SRC/repo/jpa/PutawayConfigAuditRepository.java
HANDLER=$SRC/config/PutawayConfigRepositoryEventHandler.java

ITEMDATA=$SRC/model/Itemdata.java
CLIENT=$SRC/model/Client.java
CONSTANTS=$SRC/service/WmsConstants.java
LCSVC=$SRC/service/LocationConstraintService.java
UBS=$SRC/service/UnitloadBusinessService.java
RECSVC=$SRC/service/ReceivingService.java
IDSVC=$SRC/service/ItemdataService.java
IDCTL=$SRC/controller/ItemDataController.java
RECCTL=$SRC/controller/ReceivingController.java
SKUCTL=$SRC/controller/rest/SkuRestController.java
SKUBATCH=$SRC/service/SkuBatchCreateUpdateService.java
IMPORTCTL=$SRC/controller/FileImportController.java

CTXTEST=$TST/smoke/PutawayResolverContextLoadTest.java
CFGCTL=$SRC/controller/PutawayConfigController.java
QSVC=$SRC/service/PutawayDestinationQueryService.java     # step A boundary lives here, not the controller
BRENUM=$SRC/service/BlockingReason.java                   # MOVED out of the controller 2026-08-11 (layering)
RULES=$SRC/service/PutawayDestinationRules.java            # step C: the extracted pure evaluator
RULESTEST=$TST/unit/service/PutawayDestinationRulesUnitTest.java
PURITY=$TST/unit/config/PutawayRulesPurityArchTest.java
LREPO=$SRC/repo/jpa/LocationRepository.java               # step A's paged candidate query
CLIENTCTL=$SRC/controller/ClientController.java
MPAS=$SRC/service/mobile/MobilePutAwayService.java
SECCFG=$SRC/SecurityConfiguration.java
EXHANDLER=$SRC/exceptions/RestExceptionHandler.java
SYSPROPCTL=$SRC/controller/SystemPropertyController.java
QRYSVC=$SRC/service/PutawayDestinationQueryService.java

# ============================================================================
# PHASE 1-API — V2.2.13 migration (§3.2, §3.3, §3.4a, §3.14, §5.1)
# R-12 FIX: this section was mislabelled "PHASE 1a". The migration is Phase 1b per O1/O3 — Phase 1a
# carries NO Flyway change at all. Leaving the wrong label here would have mis-bucketed every migration
# check when the O4 PHASE=1|2 filter is added, making a 1a run demand DDL that 1a does not ship.
# ============================================================================

check_M_exists()            { file_exists "$MIG"; }
check_M_drop_not_null()     { file_contains 'ALTER +COLUMN +putawaylocation_id +DROP +NOT +NULL' "$MIG"; }
# The backfill must be SCOPED to the PutAwayLane id — a blanket NULL discards
# genuine overrides (§5.1). Assert both the UPDATE and the lane-name predicate.
check_M_backfill_scoped()   { file_contains_multiline 'UPDATE.*itemdata.*SET.*putawaylocation_id\s*=\s*NULL.*WHERE.*PutAwayLane' "$MIG"; }
check_M_backfill_not_blanket() { file_not_contains 'SET +putawaylocation_id *= *NULL *;' "$MIG"; }
check_M_client_column()     { file_contains 'ADD +COLUMN.*defaultputawaylocation_id +bigint' "$MIG"; }
check_M_client_fk_named()   { file_contains 'ADD +CONSTRAINT +fk_client_defaultputawaylocation' "$MIG"; }
check_M_sysprop_seed()      { file_contains "DEFAULT_PUTAWAY_LOCATION" "$MIG"; }

# H5 FIX — check_M_sysprop_seed above is matched by a COMMENT mentioning the key, and the entire §6
# back-compat argument rests on the seeded value being the empty string. A migration that seeded a real
# location id would silently change receiving behaviour on all 5 tenants and still pass every other
# migration check. Assert the blank value, and forbid the obvious wrong forms.
check_M_sysprop_seed_blank() {
    file_contains_multiline "'DEFAULT_PUTAWAY_LOCATION'\s*,\s*''" "$MIG"
}
check_M_sysprop_seed_not_populated() {
    file_not_contains_multiline "'DEFAULT_PUTAWAY_LOCATION'\s*,\s*'[^']" "$MIG"
}
check_M_sysprop_group()     { file_contains "Operation Options" "$MIG"; }
# id must come from the shared sequence, never a literal (seqentities dual-island landmine)
check_M_seq_not_literal()   { file_contains "nextval\('public\.seqentities'\)" "$MIG"; }
check_M_idempotent()        { file_contains 'WHERE +NOT +EXISTS' "$MIG"; }
check_M_audit_table()       { file_contains 'CREATE +TABLE +IF +NOT +EXISTS +public\.putaway_config_audit' "$MIG"; }
check_M_audit_index()       { file_contains 'CREATE +INDEX +IF +NOT +EXISTS +putaway_config_audit_scope_subject_idx' "$MIG"; }
# The audit table gets its own bigserial — it must NOT draw from seqentities.
check_M_audit_bigserial()   { file_contains 'id +bigserial' "$MIG"; }

# ============================================================================
# PHASE 1-API — entities & constants (§3.2, §3.3, §3.4a)
# ============================================================================

# NEGATIVE: the @NotNull immediately above putawaylocation_id must be gone.
check_E_notnull_gone()      { file_not_contains_multiline '\@NotNull\s*\n\s*\@Column\(name = "putawaylocation_id"\)' "$ITEMDATA"; }
check_E_itemdata_col_kept() { file_contains '@Column\(name = "putawaylocation_id"\)' "$ITEMDATA"; }

check_E_client_field()      { file_contains_multiline '\@Column\(name = "defaultputawaylocation_id"\)\s*\n\s*private Long defaultputawaylocationId' "$CLIENT"; }
check_E_client_getter()     { file_contains 'public Long getDefaultputawaylocationId\(\)' "$CLIENT"; }
check_E_client_setter()     { file_contains 'public void setDefaultputawaylocationId\(' "$CLIENT"; }
# NEGATIVE: the new merchant column must NOT be @NotNull — NULL means "inherit".
# NOT VACUOUS: the field must EXIST first. Without that conjunct the "@NotNull
# directly above it" pattern trivially fails to match on today's Client.java,
# which has no such field at all — a false green.
check_E_client_field_nullable() {
    file_contains '@Column\(name = "defaultputawaylocation_id"\)' "$CLIENT" \
        && file_not_contains_multiline '\@NotNull\s*\n\s*\@Column\(name = "defaultputawaylocation_id"\)' "$CLIENT"
}

check_E_constant()          { file_contains 'SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY *= *"DEFAULT_PUTAWAY_LOCATION"' "$CONSTANTS"; }
# The tier-4 fallback constant STAYS (§3.4b / §10.2).
check_E_lane_constant_kept() { file_contains 'STORAGE_LOCATION_PUTAWAY_LANE *= *"PutAwayLane"' "$CONSTANTS"; }

check_E_audit_entity()          { file_contains '@Table\(name = "putaway_config_audit"\)' "$AUDITENT"; }
check_E_audit_identity_id()     { file_contains 'GenerationType\.IDENTITY' "$AUDITENT"; }
# Must NOT extend AbstractBaseEntity — that would pull it into the seqentities id space.
check_E_audit_no_base_entity()  { file_not_contains 'extends +AbstractBaseEntity' "$AUDITENT"; }
check_E_audit_repo()            { file_exists "$AUDITREPO"; }
# NEGATIVE: the audit repo must NOT be HAL-exported — an audit log is not writable over REST.
check_E_audit_repo_not_exported() { file_not_contains '@RepositoryRestResource' "$AUDITREPO"; }

# ============================================================================
# PHASE 1-API — predicate P1 extraction + message replacement (§3.4b, §3.6)
# ============================================================================

check_P1_method()           { file_contains 'public boolean isUnitloadTypePermitted\( *Long +storagelocationtypeId, *Long +unitloadtypeId *\)' "$LCSVC"; }
check_P1_uses_list_query()  { file_contains 'findByStoragelocationtypeId' "$LCSVC"; }
# The EMPTY-LIST FAIL-OPEN branch is mandatory (D6). Without it, location types
# System and NoRestriction (zero constraint rows) would be wrongly rejected.
check_P1_fail_open()        { file_contains_multiline 'isEmpty\(\)\s*\)\s*\{\s*\n\s*return true' "$LCSVC"; }
check_P1_long_equals()      { file_contains 'getUnitloadtypeId\(\)\.equals\(' "$LCSVC"; }

check_UBS_delegates()       { file_contains 'locationConstraintService\.isUnitloadTypePermitted\(' "$UBS"; }
# NEGATIVE: the raw-string-concatenation throw at :191 must be GONE.
check_UBS_raw_concat_gone()   { file_not_contains 'not allowed on location=' "$UBS"; }
check_UBS_raw_unitloadtype_gone() { file_not_contains '"unitloadtypeId=" *\+' "$UBS"; }
# CORRECTED 2026-08-02: this previously asserted putawayDestinationNotPermitted was
# PRESENT here — the exact opposite of §3.6.1, which says that key is thrown by the
# resolver and NOWHERE ELSE. :191 gets the NEUTRAL key (delivered by SBDEV-2731 PR1).
check_UBS_new_key()         { file_contains 'unitloadTypeNotPermittedOnLocation' "$UBS"; }
# NEGATIVE: the putaway-specific key must NOT leak into this 24-caller backstop.
# CONJOINED 2026-08-06: was a bare file_not_contains, which is VACUOUS —
# putawayDestinationNotPermitted exists in zero files today, so "absent from UBS" is
# trivially true and stays true until the resolver ships. Plan §11.1 already prescribed
# the conjoined form ("appears in PutawayDestinationResolver.java and NOT in
# UnitloadBusinessService.java"); the script shipped only the second half. Requiring the
# symbol to be PRESENT in the resolver first makes this fail closed today and pass only
# when the key exists AND has not leaked into the backstop.
check_UBS_putaway_key_absent() {
    file_contains 'putawayDestinationNotPermitted' "$RESOLVER" \
      && file_not_contains 'putawayDestinationNotPermitted' "$UBS"
}
# NEGATIVE: the old in-method constraint loop must be gone (replaced by delegation).
check_UBS_loop_gone()       { file_not_contains 'boolean +foundPermittingConstraint' "$UBS"; }
# The SBDEV-2232 caller-holds-locks contract comment must survive untouched.
check_UBS_lock_contract_kept() { file_contains 'Caller must hold all row-level' "$UBS"; }

check_MSG_key()             { file_contains '^putawayDestinationNotPermitted=' "$MSG"; }
# The message must name a remedy, not just the failure.
check_MSG_actionable()      { file_contains '^putawayDestinationNotPermitted=.*%1\$s.*%2\$s.*%3\$s.*%4\$s.*%5\$s' "$MSG"; }

# ============================================================================
# PHASE 1-API — resolver, validator, audit, metrics (§3.1, §3.4c, §3.13, §3.14)
# ============================================================================

check_R_exists()            { file_exists "$RESOLVER"; }
check_R_service()           { file_contains '@Service' "$RESOLVER"; }
check_R_four_sources()      { file_contains_multiline 'enum Source *\{[^}]*SKU_OVERRIDE[^}]*MERCHANT_OVERRIDE[^}]*WAREHOUSE_DEFAULT[^}]*STANDARD_PUTAWAY_LANE' "$RESOLVER"; }
check_R_resolve_signature() { file_contains 'Resolution +resolve\( *Itemdata +itemdata, *Client +client, *Long +unitloadtypeId *\)' "$RESOLVER"; }
# MANDATORY propagation is the structural mitigation for the invisible-deadlock
# class: it makes REQUIRES_NEW unrepresentable inside the lock-holding tx
# (UnitloadBusinessService.java:214-215, SBDEV-2232 §3.0).
check_R_tenant_tm()         { file_contains 'tenantTransactionManager' "$RESOLVER"; }
check_R_mandatory()         { file_contains 'Propagation\.MANDATORY' "$RESOLVER"; }
check_R_no_requires_new()   { file_not_contains 'Propagation\.REQUIRES_NEW' "$RESOLVER"; }
# Landmine A1: getStringDefault INSERTs on a total cascade miss (SyspropService:234),
# so the resolver must NOT be readOnly and must NOT use that method.
check_R_not_readonly()      { file_not_contains 'readOnly *= *true' "$RESOLVER"; }
check_R_no_getStringDefault() { file_not_contains 'getStringDefault' "$RESOLVER"; }
# Landmines A3 (client-blind query) + A4 (cache key omits clientId).
# ── CORRECTED 2026-08-09 — the bare substring failed a conformant implementation. ───────────────
# What landmines A3/A4 forbid is SyspropService.getSysvalue: it is client-blind
# (`order by client_id LIMIT 1`) and its cache key omits clientId. §3.4a states the property as
# "SyspropService.getSysvalue is never called". But `getSysvalue` is ALSO the plain entity accessor
# on Sysprop — and the resolver reaches the row through findBySyskeyAndClientIdAndWorkstation, which
# check_R_tier3_read_path REQUIRES, and then has to read the value off it. So the two rows were
# mutually unsatisfiable: the required query hands back an entity the forbidden token is the only way
# to read. Narrowed to the SERVICE call, which is the thing the landmine is actually about.
check_R_no_getSysvalue()    { file_not_contains 'syspropService\.getSysvalue|SyspropService\.getSysvalue' "$RESOLVER"; }
# Tier 3 must read via the non-auto-creating, uncached native query.
# X7 FIX. This check previously REQUIRED findSysvalueByClientIdAndSyskey — the method the plan
# forbids as landmine A6 (no `workstation` predicate, while the unique constraint is
# (client_id, syskey, workstation), so it returns an arbitrary row). The script therefore demanded
# the defect and failed a correct implementation, making §11.2's "0 fail" exit condition
# unreachable. Now: require the uniquely-keyed derived query, and forbid the landmine.
check_R_tier3_read_path()   { file_contains 'findBySyskeyAndClientIdAndWorkstation' "$RESOLVER"; }
check_R_tier3_no_landmine() { file_not_contains 'findSysvalueByClientIdAndSyskey' "$RESOLVER"; }
check_R_tier3_workstation_default() { file_contains 'WORKSTATION_DEFAULT' "$RESOLVER"; }
# Landmine A2: blank-after-trim means "not configured", not a parse failure.
check_R_blank_handled()     { file_contains 'trim\(\)' "$RESOLVER"; }
# §3.1.4: AdviceRestController:542 sets itemdataId = null — tier 1 must be skippable.
check_R_null_sku_guarded()  { file_contains 'itemdata *(!=|==) *null' "$RESOLVER"; }
check_R_tier4_by_name()     { file_contains 'STORAGE_LOCATION_PUTAWAY_LANE' "$RESOLVER"; }
check_R_business_exception() { file_contains 'BusinessException' "$RESOLVER"; }
# It must never throw a bare RuntimeException — ReceivingController:298-300 would
# swallow it into "contact support" (§3.6.2).
check_R_no_raw_runtime()    { file_not_contains 'throw +new +RuntimeException' "$RESOLVER"; }

check_V_exists()            { file_exists "$VALIDATOR"; }
check_V_uses_p1()           { file_contains 'isUnitloadTypePermitted' "$VALIDATOR"; }
# P2.4: OR, not AND, and NOT useforstorage alone — PutAwayLane sits in an area
# with useforstorage=false / useforgoodsin=true (L-PRE.10, §3.4c).
# ⚠ STEP C SPLIT THE CHAIN ACROSS TWO FILES (2026-08-11). These rows assert that the putaway validation
# code implements a given predicate. Until step C that was one file; it is now the
# PutawayDestinationValidator facade (loading + throwing) plus the PutawayDestinationRules evaluator
# (deciding). SIX of these rows were pinned to $VALIDATOR and went RED the moment step C merged -- the
# predicates were correct and 129 putaway tests passed; the rows were looking in the old place. Searching
# the CHAIN keeps each row meaning what its description says, and survives a future re-split.
#
# ⚠ AND THE REASON THIS REACHED develop: the PHASE=1 line read "220 pass, 6 fail" on the step C branch and
# was reported as "220 pass / 0 fail" -- the six were misattributed to the U-* UI rows, which PHASE=1
# filters out. A summary line is not a verdict; read the FAIL rows.
chain_contains() {      # $1 = extended regex
    { [ -f "$VALIDATOR" ] && grep -qE "$1" "$VALIDATOR"; } \
      || { [ -f "$RULES" ] && grep -qE "$1" "$RULES"; }
}
# code_contains_ml <perl-regex> <file> — multiline match over COMMENT-STRIPPED source.
# ADDED 2026-08-11: `file_contains_multiline` reads the raw file, so U20-preview's
# 'saveDisabled()[\s\S]{0,200}blockingReason' was satisfied by the javadoc ABOVE saveDisabled, which
# explains why a non-null blockingReason must disable Save. Deleting the actual guard left the row
# green. That is the SIXTH time prose has satisfied or broken a row in this file (P2-br-7, NOSTUB,
# P2A-lane-name, P2C-pure, U19-negflag, this) — and the first where the comment was written in the
# same change as the row. Any multiline assertion about CODE SHAPE must strip comments.
code_contains_ml() {    # $1 = perl regex, $2 = file
    [ -f "$2" ] || return 1
    code_only < "$2" | perl -0777 -ne "exit(/$1/s ? 0 : 1)"
}

chain_contains_ml() {
    [ -f "$2" ] || return 1   # $1 = perl regex
    { [ -f "$VALIDATOR" ] && perl -0777 -ne "exit(/$1/s ? 0 : 1)" "$VALIDATOR"; } \
      || { [ -f "$RULES" ] && perl -0777 -ne "exit(/$1/s ? 0 : 1)" "$RULES"; }
}

check_V_goodsin_or_storage() { chain_contains 'getUseforgoodsin'; }
check_V_storage_too()        { chain_contains 'getUseforstorage'; }
# P2.3 lane flags
# Pinned to $RULES, not the chain, and deliberately: getStaginglane is the ONE predicate that legitimately
# appears in BOTH files -- the facade reads it to decide whether to load the area (the lane exemption), the
# evaluator reads it to REJECT at SKU scope. A chain-level check therefore could not detect its removal from
# the evaluator. Decisions belong to the evaluator by construction (PutawayRulesPurityArchTest), so that is
# where a P2.3 row should look. It also now covers all FOUR flags; the old proximity regex named only two,
# and its {0,400} window silently encoded "these sit in one block" -- an assumption step C ended (transferlane
# is now ~100 lines ABOVE staginglane, and in the reverse order the regex demanded).
check_V_lane_flags()        {
    file_contains 'getTransferlane'      "$RULES" \
    && file_contains 'getAutomationlane' "$RULES" \
    && file_contains 'getGate'           "$RULES" \
    && file_contains 'getStaginglane'    "$RULES" \
    && file_contains 'getCrossdockinglane' "$RULES"
}
check_V_entity_lock()       { chain_contains 'NOT_LOCKED'; }
# NEGATIVE: the picker/validator must NOT be built on the useforstorage-only query,
# which can never return PutAwayLane (§0.1 row 34).
check_V_not_storage_query() { file_not_contains 'getStorageLocationsForPutAwayItemData' "$VALIDATOR"; }

# --- P2.5 / P2.7(c) --- SUPERSEDED 2026-08-08 by Q12 -> option (iv-b) -------------------------------
# The 2026-08-04 text here instructed the OPPOSITE of the current design and has been REMOVED rather
# than annotated, because a reader who greps this file lands on the instruction, not on the correction:
#   it said these must "reject at ALL THREE scopes, SKU included", and that "SBDEV-2821 relaxes them to
#   mismatch-only". Both are now false. SBDEV-2821 adopted option (iii) and relaxes nothing.
# Under (iv-b) the CONFIGURATION is legal at every scope, including a pick face or a fix-assigned
# location; the PLACEMENT is what is refused, by the runtime gate in receiving (W-gate/W-gatenear/
# W-gateord). Safety moved from write-time to run-time; the guarantee is unchanged.
# ── REWRITTEN 2026-08-08 for Q12 -> option (iv-b) ────────────────────────────────────────────────
# These two checks enforced the OPPOSITE of the current design and would have blocked it.
#   V-fixloc  asserted the validator calls findByAssignedlocationId (i.e. P2.5 exists at all).
#   V-fixabs  asserted it does so ABSOLUTELY, with no itemdataId comparison — the D15 mechanism.
# Under (iv-b) CONFIGURATION is widened at every scope: a pick face or fix-assigned destination is a
# LEGAL config. The absolute reject is dropped; safety moves to a RUNTIME gate in receiving (W-gate).
# A gate asserting the superseded design is worse than no gate — it fails the correct implementation.
# ── REPLACED 2026-08-09 (second pass) — SAME DEFECT THE AUDIT ABOVE WAS RUN TO REMOVE ───────────
# check_V_no_fixloc_absolute was a proximity NEGATIVE:
#   file_not_contains_multiline 'findByAssignedlocationId[\s\S]{0,400}(reject|throw|BusinessException|FIX_ASSIGNED)'
# It is the identical construction to check_V_no_pickface_reject and check_V_rule_e_not_area_flag,
# which THIS audit removed a few lines above for failing a conformant tree — and it was missed in that
# sweep. It now also contradicts the design outright: P2.7 rule (f), added 2026-08-09 by review,
# REQUIRES the validator to read findByAssignedlocationId and throw when the flowbin belongs to a
# DIFFERENT SKU. A correct implementation of rule (f) cannot pass this check. The regex cannot tell an
# ABSOLUTE reject from a MISMATCH-SCOPED one, because it cannot tell WHY something throws.
#
# Replaced by the POSITIVE property that actually separates (iv-b) from the superseded design:
# P2.5 rejected on the mere PRESENCE of a FixLocationAssignment, with no itemdataId comparison (that
# was the D15 mechanism). Rule (f) rejects only on MISMATCH. So the distinguishing, greppable property
# is that the fix-assignment branch COMPARES the assignment's itemdataId. An absolute reject has no
# such comparison; a mismatch-scoped one cannot work without it.
check_V_fixloc_reject_is_mismatch_scoped() {
    file_exists "$VALIDATOR" \
      && file_contains_multiline 'findByAssignedlocationId[\s\S]{0,400}getItemdataId' "$VALIDATOR"
}
# REPLACED 2026-08-09 after an empirical audit against a synthetic CONFORMANT implementation.
# check_V_no_pickface_reject and check_V_rule_e_not_area_flag were proximity NEGATIVES:
#   file_not_contains_multiline 'getUseforpicking[\s\S]{0,400}(reject|throw|BusinessException|FIX_ASSIGNED)'
# A correct validator reads getUseforpicking to build its isPickFace flag and then throws nearby for an
# UNRELATED reason (entityLock, lane flags). The regex cannot tell WHY something throws, so both checks
# FAILED the conformant tree — they would have blocked the implementation, the same defect already shipped
# once in check_W_uses_resolution. "Does not reject BECAUSE OF useforpicking" is not expressible as a grep.
#
# Replaced with the POSITIVE property that actually distinguishes (iv-b) from the superseded design:
# rule (e)'s flowbin reject must be SCOPE-GUARDED. P2.7(c) rejected at all three scopes; rule (e) rejects
# at merchant/warehouse only. A scope test next to the flowbin throw is the observable difference.
check_V_rule_e_scope_guarded() {
    file_exists "$VALIDATOR" \
      && file_contains_multiline '[Ss]cope[\s\S]{0,200}flowbin' "$VALIDATOR"
}
# CFGTEST — restored 2026-08-09. My previous edit deleted this assignment along with the two negatives
# above it, and under `set -u` the first reference to $CFGTEST aborted the whole run silently at check 6
# of ~180. The script reported nothing after V-ruleEscope and still exited 0 for the checks it had run.
CFGTEST=$TST/unit/service/PutawayConfigServiceUnitTest.java
check_T_sku_pickface_test() { file_contains_i 'skuWritePermitsPickFaceDestination' "$CFGTEST"; }
# INVERTED 2026-08-08 (iv-b): configuration is widened at ALL scopes, merchant included.
check_T_merch_pickface_test() { file_contains_i 'merchantWritePermitsPickFaceDestination' "$CFGTEST"; }
check_T_staging_ok_test()   { file_contains_i 'merchantWritePermitsStagingLane' "$CFGTEST"; }
# P2.7 rule (e), added 2026-08-08. (iv-b) widened configuration at every scope, which re-opened a hazard
# P2.5's absolute reject had been closing as a SIDE EFFECT: putaway auto-creates a FixLocationAssignment
# (storeBoxOnLocation:479-482) binding a flowbin to the FIRST SKU put away, and the table is
# UNIQUE(assignedlocation_id) AND UNIQUE(itemdata_id) — so every later SKU under a merchant/warehouse
# default breaks. 46 FLA-free flowbins on HMG PRD, 656 on wineco UAT.
# The predicate is the LOCATION TYPE, not the area flag: keying on useforpicking would re-ban the club
# lanes (cases and pallets) and undo Q12. All three checks are needed — the reject alone would pass an
# implementation that bans flowbins everywhere, including tier 1 where the binding is the intent.
check_V_no_flowbin_tier23()  { chain_contains 'sltname'; }
check_T_merch_flowbin_reject() { file_contains_i 'merchantWriteRejectsFlowbinDestination' "$CFGTEST"; }
check_T_sku_flowbin_ok()       { file_contains_i 'skuWritePermitsFlowbinDestination' "$CFGTEST"; }
check_T_merch_casespallets_ok() { file_contains_i 'merchantWritePermitsCasesAndPalletsDestination' "$CFGTEST"; }
# ── ADDED 2026-08-09 (second pass) — P2.7 rule (f) had ZERO coverage in this script ──────────────
# Rule (f) was added to the plan on 2026-08-09 by review and the script was never updated: nothing
# here asserted it ships. It is not a nicety — the tier-1 exemption from rule (e) is otherwise WEAKER
# than the runtime rule it mirrors, so without (f) a configuration saves cleanly and then fails at
# EVERY putaway with nothing naming the cause. 1,344 of 2,555 candidate flowbins on wms2-wineco-dev
# are already FLA-bound, so this is the common case rather than an edge.
# All THREE are required: the two rejects alone would pass an implementation that bans every
# fix-assigned flowbin at tier 1, which is the over-reject (iv-b) exists to prevent.
check_T_rule_f_foreign_flowbin()  { file_contains_i 'skuWriteRejectsFlowbinAssignedToAnotherSku' "$CFGTEST"; }
check_T_rule_f_sku_owns_other()   { file_contains_i 'skuWriteRejectsWhenSkuAlreadyOwnsADifferentPickFace' "$CFGTEST"; }
check_T_rule_f_own_pickface_ok()  { file_contains_i 'skuWritePermitsItsOwnFixAssignedPickFace' "$CFGTEST"; }
# NEG: rule (e) must NOT be implemented with the area flag — that re-bans the clubs.
check_V_rule_e_not_area_flag() {
    file_contains 'sltname' "$VALIDATOR" \
      && file_not_contains_multiline 'getUseforpicking[\s\S]{0,200}(reject|throw|BusinessException)' "$VALIDATOR"
}
# (iv-b) placement split — BOTH halves must be pinned. Asserting only the divert would let an
# implementation that never places anything (option iv-a, not chosen) pass.
RECTEST=$TST/unit/service/ReceivingServiceUnitTest.java
check_T_pickface_not_placed() { file_contains_i 'pickFaceDestinationIsNotPlacedAtReceipt' "$RECTEST"; }
check_T_staging_is_placed()   { file_contains_i 'stagingLaneDestinationIsPlacedAtReceipt' "$RECTEST"; }

check_A_exists()            { file_exists "$AUDITSVC"; }
# MANDATORY: an audit row that can survive a rolled-back config change is worse
# than none (§3.14).
check_A_mandatory()         { file_contains 'Propagation\.MANDATORY' "$AUDITSVC"; }
check_A_tenant_tm()         { file_contains 'tenantTransactionManager' "$AUDITSVC"; }
check_A_username()          { file_contains 'SecurityContextUtils\.getUserName\(\)' "$AUDITSVC"; }
check_A_channel()           { file_contains_i 'channel' "$AUDITSVC"; }

check_MT_exists()           { file_exists "$METRICS"; }
check_MT_registry()         { file_contains 'MeterRegistry' "$METRICS"; }
check_MT_resolution()       { file_contains 'wms2\.putaway\.resolution' "$METRICS"; }
check_MT_rejected()         { file_contains 'wms2\.putaway\.resolution\.rejected' "$METRICS"; }
check_MT_cfg_rejected()     { file_contains 'wms2\.putaway\.config\.rejected' "$METRICS"; }
check_MT_cfg_changed()      { file_contains 'wms2\.putaway\.config\.changed' "$METRICS"; }
# The `source` tag is the ONLY detector for pre-mortem P2 (feature ships inert).
check_MT_source_tag()       { file_contains '"source"' "$METRICS"; }

# ============================================================================
# PHASE 1-API — config-write services (§3.5, §3.10)
# ============================================================================

check_C_exists()            { file_exists "$CFGSVC"; }
check_C_three_writers()     { file_contains_multiline 'setSkuDestination[\s\S]*setMerchantDestination[\s\S]*setWarehouseDestination' "$CFGSVC"; }
check_C_tenant_tm()         { file_contains_n_times 'tenantTransactionManager' "$CFGSVC" 3; }
check_C_rollback_for()      { file_contains 'rollbackFor *= *\{ *BusinessException\.class, *FacadeException\.class *\}' "$CFGSVC"; }
check_C_validates()         { file_contains 'putawayDestinationValidator\.' "$CFGSVC"; }
check_C_audits()            { file_contains 'putawayConfigAuditService\.' "$CFGSVC"; }
check_C_metrics()           { file_contains 'putawayResolutionMetrics\.' "$CFGSVC"; }
# Cache eviction: itemdata (2 keys), clients (2 keys), sysprops (1 key) — §3.10.
check_C_evict_itemdata()    { file_contains '@CacheEvict\(value *= *"itemdata"' "$CFGSVC"; }
check_C_evict_itemdata_2keys() { file_contains_n_times '@CacheEvict\(value *= *"itemdata"' "$CFGSVC" 2; }
check_C_evict_clients()     { file_contains_n_times '@CacheEvict\(value *= *"clients"' "$CFGSVC" 2; }
check_C_evict_sysprops()    { file_contains '@CacheEvict\(value *= *"sysprops"' "$CFGSVC"; }
# NEGATIVE: never flush all tenants' entries.
check_C_no_all_entries()    { file_not_contains 'allEntries *= *true' "$CFGSVC"; }
# Clearing the WAREHOUSE override writes '' — it must NOT delete the sysprop row.
check_C_no_sysprop_delete() { file_not_contains 'syspropRepository\.delete' "$CFGSVC"; }

# INVERTED 2026-08-27 (SBDEV-3017). Both rows used to assert that ItemdataService and
# ItemDataController DELEGATE to PutawayConfigService rather than raw-saving — correct while each
# still owned a putaway write. Neither does now: ItemDataController.setPutAwayLocation (a mutating
# GET, ungated because ItemDataController is outside FunctionGuardInterceptor.GUARDED) and the
# orphaned ItemdataService.setPutAwayLocation were both DELETED at Nam's instruction, and with them
# the PutawayConfigService injection in each class (ItemDataController 14 ctor args -> 13).
#
# Left as-written both would be PERMANENTLY RED — worse than no row, being indistinguishable from
# unfinished work. Inverted, because 2732's actual invariant survives in a stronger form: there is
# now exactly ONE validated, audited SKU-putaway writer, reached only through
# PutawayConfigController.setSku (@RequiresFunction(WEB_UI_VIEW_ITEM_DATA)). The authority is
# PutawayConfigActionGuardUnitTest#onlyTheFourGatedHandlersMayCallTheSetters, an ArchUnit
# type-resolved call-site rule; these two rows are the cheap cross-file echo of it.
check_IDS_no_putaway_write()   { code_not_contains 'putawayConfigService\.' "$IDSVC"; }
check_IDCTL_no_putaway_write() { code_not_contains '(itemdataService\.setPutAwayLocation|putawayConfigService\.)' "$IDCTL"; }
# NEGATIVE: ItemDataController:80 allEntries=true (flushes ALL tenants) must be gone.
check_IDCTL_all_entries_gone() { file_not_contains 'allEntries *= *true' "$IDCTL"; }
# NEGATIVE: the raw unvalidated save at :88-90 must be gone.
# GENERALISED 2026-08-27 (SBDEV-3017 review M1). This pinned the EXACT two-line text of the old body,
# down to the local variable name `newItemData`. A mutant writing the same defect without that local —
# `return ResponseEntity.ok(itemdataRepository.save(itemData));` — passed it. The row nominally guards
# "no raw unvalidated save in this controller" and guarded one transcription of it. Now pins the actual
# hazard: this controller must not touch the putaway field at all. Authority is the ArchUnit rule
# PutawayConfigActionGuardUnitTest#onlyTheValidatedWriterMayWriteThePutawayField, which enforces it
# across ALL of src/main; this row is the cheap file-scoped echo.
check_IDCTL_raw_save_gone() { code_not_contains 'setPutawaylocationId' "$IDCTL"; }

# ============================================================================
# PHASE 1-API — stop seeding the PutAwayLane id at all FOUR write sites (§3.2)
# ============================================================================
# These are the NEGATIVE checks that matter most: if they pass while §3.2's
# positive checks fail, the feature ships inert (pre-mortem P2).

# SkuRestController: the create AND update paths each looked up the lane id.
# Both lookups must be gone (0 occurrences of the lookup in the file).
check_S1_lane_lookup_gone()   { file_not_contains 'defaultPutawayLocationId' "$SKUCTL"; }
check_S1_findByName_gone()    { file_not_contains 'findByName\(WmsConstants\.STORAGE_LOCATION_PUTAWAY_LANE\)' "$SKUCTL"; }
# SkuBatchCreateUpdateService: parameter and setter both gone.
check_S2_param_gone()         { file_not_contains 'Long +defaultPutawayLocationId' "$SKUBATCH"; }
check_S2_setter_gone()        { file_not_contains 'setPutawaylocationId\(defaultPutawayLocationId\)' "$SKUBATCH"; }
# FileImportController: the setter is gone but the SBDEV-2037 lane-PRESENCE guard stays.
check_S3_setter_gone()        { file_not_contains 'setPutawaylocationId\(location\.get\(\)\.getId\(\)\)' "$IMPORTCTL"; }
check_S3_guard_kept()         { file_contains 'STORAGE_LOCATION_PUTAWAY_LANE' "$IMPORTCTL"; }
check_S3_guard_error_kept()   { file_contains 'putaway location does not exist' "$IMPORTCTL"; }

# ============================================================================
# PHASE 1-API — receiving wiring (§3.7, §3.8)
# ============================================================================

check_W_resolver_called()   { file_contains 'putawayDestinationResolver\.resolve\(' "$RECSVC"; }

# H5 FIX — the single most important behavioural assertion in this plan, previously unchecked.
# `if (carrier == null)` wrapping the RESOLUTION is literally SBDEV-2731's root cause: the old code
# resolved the SKU destination only on the non-carrier path. check_W_resolver_called above is
# satisfied by an implementation that reintroduces exactly that bug. This forbids it.
# CONJOINED so it is not a vacuous negative. A bare "resolve( is not carrier-guarded" passes on the
# unmodified tree simply because resolve( does not exist yet — which is how a check silently loses its
# teeth (cf. W-neg4, and the standing "more than 8 passes on an unimplemented tree" rule). Requiring the
# symbol to be PRESENT first makes this fail closed today and pass only when it is present AND unguarded.
check_W_resolve_not_carrier_guarded() {
    file_contains 'putawayDestinationResolver\.resolve\(' "$RECSVC" \
      && file_not_contains_multiline 'if\s*\(\s*carrier\s*==\s*null\s*\)[^;]{0,300}?putawayDestinationResolver\.resolve\(' "$RECSVC"
}

# C4 — conversely, the HARD-FAIL *must* be carrier-guarded, or a config error irrelevant to a carrier
# receipt aborts it (D10 says surface-and-warn, never block). Note this is the mirror image of the
# check above and the two must not be conflated: resolution unguarded, hard-fail guarded.
check_W_requirecompatible_carrier_guarded() {
    file_contains_multiline 'if\s*\(\s*carrier\s*==\s*null\s*\)[^}]{0,200}?requireCompatible\(' "$RECSVC"
}
check_W_metrics_called()    { file_contains 'putawayResolutionMetrics\.' "$RECSVC"; }
# NEGATIVE: the carrier-only ternary at :454-457 is SBDEV-2731's root cause and must be GONE.
check_W_ternary_gone()      { file_not_contains_multiline 'Location putAwayLocation = \(carrier == null\)' "$RECSVC"; }
check_W_old_var_gone()      { file_not_contains 'Location +putAwayLocation *=' "$RECSVC"; }
# The resolved destination must be what is handed to transferUnitLoadToLocation.
# CONJOINED 2026-08-08 (iv-b). On its own this passes against UNCONDITIONAL placement — which is
# precisely the defect: a pick-face destination placed at receipt is SBDEV-2731's reported bug.
# Placement must exist AND be gated on useforpicking.
# CORRECTED 2026-08-08 — the previous form BLOCKED THE CHANGE IT GUARDS.
# It demanded the literal `transferUnitLoadToLocation(unitload, putaway.location()`. Under (iv-b) a
# pick-face destination must be RETARGETED to the lane before placement, so a conformant impl writes
#   Location placement = isPickFace ? standardLane : putaway.location();
#   transferUnitLoadToLocation(unitload, placement, ...);
# — which FAILED the old check, while an impl that places the pick face unconditionally (SBDEV-2731's
# reported bug) PASSED it. Exactly inverted. Assert instead that the resolution REACHES placement and
# that the retarget exists, without dictating the variable name at the call site.
check_W_uses_resolution() {
    file_contains 'putaway\.location\(\)' "$RECSVC" \
      && file_contains 'transferUnitLoadToLocation\(' "$RECSVC" \
      && file_contains 'getUseforpicking' "$RECSVC"
}
# The (iv-b) gate itself: receiving diverts a pick-face destination to the lane instead of placing.
# STRUCTURAL, updated 2026-08-08: the gate is `useforpicking == TRUE || sltname == 'flowbin'`. The area
# flag alone is data-contingent — it holds only because every flowbin on both measured tenants happens to
# sit in a picking area. The reported failure is a location-TYPE property, so the type must be tested too.
# CASE FIX 2026-08-09: the audit's conformant tree calls getSltname() with no lowercase `sltname`
# variable, and file_contains is case-sensitive — so the gate check failed a correct implementation.
check_W_pickface_gate() {
    file_contains 'getUseforpicking' "$RECSVC" && file_contains_i 'sltname' "$RECSVC"
}
# P1 must be SKIPPED for a pick-face destination at config-write time, or ICE PACK cannot be configured:
# flowbin permits only unitloadtype 1 (PickLocation) and ICE PACK's defultype_id is 4 (Case), so P1 is
# FALSE and rejects the config even after P2.5/P2.7(c) are dropped. The validator must therefore read
# sltname (rule (e) already requires that) AND guard its P1 call.
# NOT a chain_contains row, and the reason is worth recording: the flowbin skip is deliberately implemented
# TWICE -- the facade short-circuits it (line ~140) so the constraint read never fires for a flowbin, which
# is what preserves the pre-step-C query profile, and the evaluator skips it again (line ~258) so its own
# decision is correct for any caller that builds Ctx differently. Step C's mutation battery found that
# redundancy the hard way: removing the evaluator's skip left all 50 facade tests green. A single grep for
# `unitloadTypePermitted` matches the Ctx ACCESSOR in the evaluator and so passes even when the facade's
# service call is gone -- verified vacuous on 2026-08-11. Both halves therefore get their own assertion.
check_V_p1_skipped_for_pickface() {
    file_contains_multiline 'flowbin[\s\S]{0,200}isUnitloadTypePermitted' "$VALIDATOR" \
      && file_contains_multiline 'isFlowbin\(ctx\)[\s\S]{0,140}ctx\.unitloadTypePermitted\(\)' "$RULES"
}
# PROXIMITY: the gate must be near the placement, not merely somewhere in the file — a log line
# satisfies the bare positive above.
# ── REPLACED 2026-08-09 — jointly unsatisfiable with check_W_gate_before_requirecompatible. ─────
# The old form demanded `getUseforpicking` within 400 chars of `transferUnitLoadToLocation(`. But
# §3.7.1 mandates the gate ABOVE the per-case loop ("Placed HERE ... ABOVE the per-case loop at
# :462") while §3.7.2 puts the placement INSIDE it — ~3,000 chars apart in a conformant tree, and
# necessarily so, because W-gateord independently forces the gate above `requireCompatible`, which
# is itself above the loop. The only ways to satisfy both were to name the token in a comment or to
# add a redundant second guard at the placement: a check satisfiable only by decoration. Fourth
# instance of the class this script's 2026-08-09 audit removed elsewhere.
#
# Replaced by the property the row was named for — that the gate REACHES the placement rather than
# merely existing in the file. The honest chain is: the pick-face test retargets the destination
# variable, and the placement uses that same variable. An implementation that computes the gate and
# then places the ORIGINAL destination anyway — SBDEV-2731's reported bug — fails the second clause.
check_W_gate_near_placement() {
    file_contains_multiline 'getUseforpicking[\s\S]{0,600}putaway *=' "$RECSVC" \
      && file_contains_multiline 'transferUnitLoadToLocation\(\s*unitload,\s*putaway\.location\(\)' "$RECSVC"
}
# ORDERING: the gate must run BEFORE requireCompatible and retarget to the lane, or P1 is evaluated
# against the pick face and every pick-face-configured SKU's receipt hard-fails. Measured on HMG PRD:
# flowbin (type 2) has ONE location_constraint row permitting only unitloadtype 1 (PickLocation), and
# ICE PACK's defultype_id is 4 (Case) — so P1 is FALSE and requireCompatible would throw.
check_W_gate_before_requirecompatible() {
    file_contains_multiline 'getUseforpicking[\s\S]{0,600}requireCompatible\(' "$RECSVC"
}
# NEG — THE ONE THAT MATTERS. The gate must live in ReceivingService, NOT in ReceivingController.
# receiveGoods has TWO callers: ReceivingController:284 and ReturnAdviceAutoReceiveService:556, and
# the second passes carrier=null. A gate placed in the controller would leave return auto-receive
# placing stock straight onto a pick face — the reported bug, on the path nobody watches.
check_W_gate_not_in_controller() {
    file_contains 'getUseforpicking' "$RECSVC" \
      && file_not_contains 'getUseforpicking' "$RECCTL"
}
# Resolution must stay HOISTED above the per-case loop (O(1) per receipt, §7.6 #4).
check_W_hoisted_above_loop() { file_contains_multiline 'putawayDestinationResolver\.resolve\([\s\S]{0,3000}while \(amountBottles > 0\)' "$RECSVC"; }
# receiveGoods stays ONE tenant transaction.
check_W_one_tx()            { file_contains 'tenantTransactionManager' "$RECSVC"; }

check_W_endpoint()          { file_contains 'getPutawayDestination' "$RECCTL"; }
# ReceivingController:314 raw literals replaced with constants.
check_W_literals_gone()     { file_not_contains 'Arrays\.asList\("PutAwayLane", *"InboundWorkstation", *"EmptyPallets"\)' "$RECCTL"; }
check_W_constants_used()    { file_contains 'WmsConstants\.STORAGE_LOCATION_PUTAWAY_LANE' "$RECCTL"; }

# The SBDEV-2102 fix in mobile putaway must survive untouched (§3.7.4).
check_W_sbdev2102_kept()    { file_contains 'storePalletBackOnPutawayLane' "$SRC/service/mobile/MobilePutAwayService.java"; }

# NEGATIVE: the resolver must NOT be wired inside transferUnitLoadToLocation —
# that method has 24 call sites across picking, palletizing, truck loading, transfers,
# on-hold and nirvana (§2.8). COUNT CORRECTED 2026-08-06: the plan said 35; the measured
# figure is 24 for transferUnitLoadToLocation (33 combined with transferUnitLoadToCarrier's
# 9). SBDEV-2731's own code review caught the same error.
# CONJOINED 2026-08-06 for the same reason as UBS-neg4 above: putawayDestinationResolver
# exists nowhere yet, so the bare negative was vacuous. The plan excused this as
# "unavoidable for a 'never wire X into Y' check" (§11.1) — but W-nocgrd three rows earlier
# solves the identical shape by conjoining, so it is entirely avoidable.
check_W_not_in_transfer() {
    file_contains 'putawayDestinationResolver\.resolve\(' "$RECSVC" \
      && file_not_contains 'putawayDestinationResolver' "$UBS"
}

# ============================================================================
# PHASE 1-API — Spring Data REST write hole (§3.9) + permissions (§3.12)
# ============================================================================

check_H_exists()            { file_exists "$HANDLER"; }
check_H_annotation()        { file_contains '@RepositoryEventHandler' "$HANDLER"; }
check_H_component()         { file_contains '@Component' "$HANDLER"; }
check_H_before_create()     { file_contains '@HandleBeforeCreate' "$HANDLER"; }
check_H_before_save()       { file_contains '@HandleBeforeSave' "$HANDLER"; }
# All THREE holes: Itemdata, Client AND Sysprop (deviation A1 — the warehouse
# tier has the largest blast radius and PUT /sysprop/{id} is what the UI calls).
check_H_itemdata()          { file_contains 'Itemdata +incoming' "$HANDLER"; }
check_H_client()            { file_contains 'Client +incoming' "$HANDLER"; }
check_H_sysprop()           { file_contains 'Sysprop +incoming' "$HANDLER"; }
# The Sysprop handler must react ONLY to our key — every other sysprop passes through.
check_H_syskey_guarded()    { file_contains 'SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY' "$HANDLER"; }
# It must delegate so the config service's @CacheEvict applies (§3.10 row 4).
check_H_delegates()         { file_contains 'putawayConfigService\.' "$HANDLER"; }
# The previous-value read must suppress auto-flush or it reads back the NEW value (§3.9).
# R-3 FIX — this was an X7-class inversion: it required `FlushModeType.COMMIT` in the HANDLER, but the
# corrected §3.9 moves the previous-value read into PutawayConfigService.readCommittedDestination AND
# drops the flush mode entirely (with OSIV off the merged entity is detached, so there is nothing to
# auto-flush and the setting was a proven no-op). So the old check FAILED a conformant implementation and
# PASSED one that left the misplaced read in the handler. Assert the honest properties instead.
check_H_prev_read_in_service() { file_contains 'readCommittedDestination' "$CFGSVC"; }
check_H_prev_read_getresultlist() { file_contains 'getResultList\(' "$CFGSVC"; }
check_H_no_getsingleresult()   { file_not_contains 'getSingleResult\(' "$CFGSVC"; }
# C3: create and save must be SEPARATE handler methods — a combined @HandleBeforeCreate @HandleBeforeSave
# binds a null id into `where id = ?1` and breaks every HAL POST of Itemdata/Client/Sysprop.
# ── CORRECTED 2026-08-09 — the check could never pass, on ANY tree. ─────────────────────────────
# The multi-line helpers run the pattern through `perl -0777 -ne`, and in Perl an unescaped `@name`
# inside a regex INTERPOLATES AS AN ARRAY. @HandleBeforeCreate and @HandleBeforeSave are both empty,
# so the pattern collapsed to /\s+/ — which matches any file containing whitespace. As a NEGATIVE
# that is a permanent FAIL: a conformant handler with the two annotations sixty lines apart still
# "contained" the pattern. Verified by hand on the implemented tree (match at rc=0). The three
# other multi-line patterns in this script escape the sigil correctly (\@NotNull, \@Column); these
# two did not. Same class of defect as the removed proximity negatives — a check that cannot pass.
check_H_create_save_split()    { file_not_contains_multiline '\@HandleBeforeCreate\s+\@HandleBeforeSave' "$HANDLER"; }
check_H_after_handlers()       { file_contains '@HandleAfterSave' "$HANDLER"; }
# N-1: BusinessException is CHECKED, so SDR wraps it in UndeclaredThrowableException and the client gets
# a 500 instead of the 422 RestExceptionHandler:118-124 would have returned. The handler must therefore
# throw the unchecked PutawayConfigValidationException and declare no checked throws.
check_H_unchecked_exception()  { file_contains 'PutawayConfigValidationException' "$HANDLER"; }
# Architect re-review: the handler must validate the DELTA, not the state. Without an early return when
# the destination is unchanged, every HAL PATCH of ANY field re-validates the existing destination and
# config rot becomes an edit lock (the Ice Pack row becomes un-PATCHable for any field).
check_H_delta_not_state()      { file_contains 'readCommittedDestination' "$HANDLER" \
                                   && file_contains_multiline 'Objects\.equals|== *previous|equals\(previous' "$HANDLER"; }

# §3.5a — the typed write surface (resolves N-3 and R-5). Without it the merchant/warehouse writers have
# ZERO callers (dead code), their @CacheEvict never fires, §3.12's @PreAuthorize claim is false, and
# D11's count-and-confirm has nowhere to live (SDR ignores unknown query params and a @HandleBefore*
# handler cannot see them).
# X4 — §3.1.5 cites these two by name and neither existed. C1 (MANDATORY resolver reached from a
# non-transactional controller) is the defect that would have shipped broken on the URGENT path, and
# until now nothing in this script covered it at all.
check_N2_readonly_facade() {
    file_exists "$QRYSVC" \
      && file_contains_multiline '\@Transactional\([^)]*readOnly\s*=\s*true' "$QRYSVC" \
      && file_contains 'tenantTransactionManager' "$QRYSVC"
}
check_N2_controller_delegates_not_resolves() {
    file_contains 'putawayDestinationQueryService\.' "$RECCTL" \
      && file_not_contains 'putawayDestinationResolver\.' "$RECCTL"
}
# Phase 1a ships setSkuDestination + setWarehouseDestination; C-writers (all three) is 1b, which left
# 1a with no existence check on its own two writers.
check_C_1a_writers() {
    file_contains 'setSkuDestination' "$CFGSVC" && file_contains 'setWarehouseDestination' "$CFGSVC"
}
check_CTL_exists()          { file_exists "$CFGCTL"; }
check_CTL_preview()         { file_contains '/preview' "$CFGCTL"; }

# ── ADDED 2026-08-09 by the Phase-3a conformance lane. ──────────────────────────────────────────
# The independent verifier found FIVE in-scope Phase-1-API items unbuilt behind a 176/0 green run,
# TWO of them shipping as `throw new UnsupportedOperationException`. Every row that was supposed to
# cover them is an EXISTENCE grep that a throwing stub satisfies: check_W_endpoint is
# file_contains 'getPutawayDestination'; check_CTL_preview is file_contains '/preview';
# check_N2_readonly_facade checks the file, the annotation and a string, and never a method body.
# A gate that cannot tell a stub from an implementation is not a gate. These rows fail on a stub.
#
# The blunt one first: NO putaway class may still carry gate scaffolding. This single row would
# have caught items 1 and 3 on its own.
# ⚠ HARDENED 2026-08-11: this compared raw file text, so a COMMENT that merely NAMES the pattern
# false-FAILED the row -- which is exactly what happened when step A's javadoc explained why a stub is
# dangerous. A prose mention is not a stub, the same way a prose mention is not a declaration (see
# `code_only` and the P2-br-7 note). Strip comment lines first, so the row means what it says.
# It still fires on a real stub: proven by step A's gate, where it correctly caught the signature-only
# scaffolding and blocked PHASE=1 from reaching 0-fail until a real body existed.
nostub_free() {   # $1 = file
    [ -f "$1" ] || return 1
    ! code_only < "$1" | grep -qE 'throw +new +UnsupportedOperationException'
}
check_NOSTUB_putaway() {
    nostub_free "$QRYSVC" \
      && nostub_free "$CFGCTL" \
      && nostub_free "$RESOLVER" \
      && nostub_free "$CFGSVC" \
      && nostub_free "$VALIDATOR"
}
# The facade must actually RESOLVE, not merely exist and be annotated (C1/N2).
check_N2_facade_resolves()  { file_contains 'putawayDestinationResolver\.resolve\(' "$QRYSVC"; }
# ...for BOTH entry points: the advice position (the receiving display) and the client (N9).
# Method NAMES alone are satisfied by two throwing stubs — true of the tree this round was called in
# to judge. Anchor each name to the repository read its own body must perform, so the row means what
# its description says rather than leaning on NOSTUB to cover it.
check_N2_facade_both() {
    file_contains_multiline 'describeForAdvicePosition[\s\S]{0,700}advicepositionRepository\.findById' "$QRYSVC" \
      && file_contains_multiline 'describeForClient[\s\S]{0,700}clientRepository\.findById' "$QRYSVC"
}
# N9 — the merchant screen's inherited value. Had NO row at all, which is why it was never built.
check_N9_endpoint()         { file_contains 'effectivePutawayDestination' "$CLIENTCTL"; }
# ...and it must go through the facade, never the MANDATORY resolver (same C1 rule as §3.8).
check_N9_uses_facade()      { file_contains 'putawayDestinationQueryService' "$CLIENTCTL"; }
# CONJOINED, for the reason check_W_resolve_not_carrier_guarded is conjoined: on the unmodified tree
# ClientController exists but has no putaway code at all, so the bare negative PASSED there — a
# vacuous row that only ever goes red by accident. Requiring the endpoint FIRST makes it fail closed
# today and pass only when the endpoint is present AND routed through the facade.
check_N9_no_resolver() {
    file_contains 'effectivePutawayDestination' "$CLIENTCTL" \
      && file_not_contains 'putawayDestinationResolver\.resolve\(' "$CLIENTCTL"
}
# The preview must compute the D11 numbers, not just answer the route.
# FAILS-OPEN FIX (round-2 conformance lane): the alternative `countIncompatibleSkus` was ALREADY in
# this controller, inside requireConfirmation, while preview was still a throwing stub — so the row
# written to prove the preview computes counts was exactly as blind as the check_CTL_preview it
# replaced. Only summariseScope is new to the preview.
check_CTL_preview_counts()  { file_contains 'putawayConfigService\.summariseScope' "$CFGCTL"; }

# §3.9.1 — the three direct-save paths the SDR handler cannot see. §11.1 claimed these three rows
# were "now IN the script"; they did not exist, so nothing ever checked SystemPropertyController and
# the file never entered the diff.
# FAILS-OPEN FIX: `|` binds loosest, so the second alternative — ANY mention of the constant —
# satisfied the whole pattern on its own, and rejectGuardedPutawayKey's own body mentions it. Proven
# by mutation: deleting BOTH guard calls left this row GREEN. Alternation dropped.
check_N1_syspropctl_create_guard() {
    file_contains_multiline 'createSystemProperty[\s\S]{0,400}rejectGuardedPutawayKey' "$SYSPROPCTL"
}
# Strengthened to assert ORDER. The guard must run BEFORE findBySyskey(key).get(0) — landmine A3's
# client-blind shape on a write — and mere presence somewhere in the method did not say that.
check_N1_syspropctl_updatevalue_guard() {
    file_contains_multiline 'updateValue[\s\S]{0,400}rejectGuardedPutawayKey[\s\S]{0,400}findBySyskey' "$SYSPROPCTL"
}
check_N1_sysprop_delete_handler()  { file_contains '@HandleAfterDelete' "$HANDLER"; }
# D12's second half. Without it, ONE click on the configuration screen's delete button makes tier 3
# unreachable from the UI -- create now rejects the syskey, so nothing could re-create the row.
# FAILS-OPEN FIX: the 900-char window ran off the end of the old 5-line THROWING requireWarehouseRow
# and matched a save() in later code, so the row passed on a tree where the method could only throw.
# Requiring the CONSTRUCTION between the two anchors is what distinguishes re-creating a row from
# merely being near a save.
check_N1_d12_recreates_row() {
    file_contains_multiline 'requireWarehouseRow[\s\S]{0,900}new Sysprop\(\)[\s\S]{0,900}syspropRepository\.save' "$CFGSVC"
}

# Step 17a — putaway must surface the FOUR-TIER destination, not itemdata.putawaylocation_id.
# 2821 shipped tier 1 only, correct while that column held every SKU's destination; V2.2.13 nulls it,
# and step 15 diverts pick-face destinations at every tier -- so a merchant- or warehouse-scope
# destination left on tier 1 strands the unit load on the lane with nowhere the screen will send it.
check_17a_resolver_wired()  { file_contains 'putawayDestinationResolver\.resolve\(' "$MPAS"; }
# NOTE the character class: `[^)]*` does NOT work here. The forbidden call is
# getPutAwayCandidateLocations(currentSku.getId(), currentSku.getPutawaylocationId()) -- `[^)]*`
# stops at the `)` of getId(), so it never matches the exact call it exists to forbid, and the row
# passed on the unmodified tree. Caught by the negative control, which is what it is for.
check_17a_not_tier1_column() {
    file_contains 'getPutAwayCandidateLocations' "$MPAS" \
      && file_not_contains_multiline 'getPutAwayCandidateLocations\([\s\S]{0,80}getPutawaylocationId\(\)' "$MPAS"
}
# Tier 4 must map back to null: resolve() always answers, and passing the lane id would offer the
# lane the unit load is being moved OFF as somewhere to move it TO.
# ── ADDED 2026-08-10 after the 3b re-review. ────────────────────────────────────────────────────
# The re-review measured that this script was INERT for the entire 3b fix round: 190/0 before and
# after, and a revert of any fix would also have been 190/0. It confirmed by grepping for divertedTo,
# PutawayDisplay, auditAndEvictSku, putawayConfig/, SecurityConfiguration, updateClient and :SYSTEM —
# zero hits each. A gate that cannot see a round of changes is not gating that round.
# NOTE: grep, not the multiline helper. That helper interpolates the pattern into perl's m/.../, so
# an unescaped `/` — and this pattern is all URL paths — terminates the regex early. It failed CLOSED
# here, but it is the fourth distinct way a check in this file can be wrong about its own syntax
# (after perl @-interpolation, `|` precedence, and `[^)]*` stopping at inner punctuation).
check_SEC_putawayconfig_gated() {
    file_contains '"/putawayConfig/\*\*"\)\.hasAnyAuthority' "$SECCFG"
}
check_SEC_updateclient_guard() {
    file_contains_multiline 'updateClient[\s\S]{0,2000}rejectGuardedPutawayKey' "$SYSPROPCTL"
}
check_H7a_422_handler() {
    file_contains 'ExceptionHandler\(PutawayConfigValidationException\.class\)' "$EXHANDLER"
}
check_H_sysprop_create_guard() {
    file_contains_multiline '\@HandleBeforeCreate[\s\S]{0,300}Sysprop incoming' "$HANDLER"
}
# The create path must NOT call the admin-gated validateOnly unconditionally: that made every HAL
# POST of itemdata/client require sb_admin. Assert the early return exists on both.
check_H_create_early_return() {
    file_contains_multiline 'onBeforeCreate\(Itemdata incoming\)[\s\S]{0,600}getPutawaylocationId\(\) == null' "$HANDLER" \
      && file_contains_multiline 'onBeforeCreate\(Client incoming\)[\s\S]{0,600}getDefaultputawaylocationId\(\) == null' "$HANDLER"
}
# The After phase must reach the EVICTING writers, not the audit-only one.
check_H_after_evicts()      { file_contains 'auditAndEvictSku|auditAndEvictMerchant|auditAndEvictWarehouse' "$HANDLER"; }
check_CFG_evict_variants()  { file_contains 'auditAndEvictSku' "$CFGSVC" \
                                && file_contains "':SYSTEM'" "$CFGSVC"; }
# The carrier must clear BEFORE any early return, and its key must carry the tenant.
check_H_carrier_clear_first() {
    file_contains_multiline 'validateDelta\([\s\S]{0,900}pendingPreviousValue\.get\(\)\.remove[\s\S]{0,600}Objects\.equals' "$HANDLER"
}
check_H_carrier_tenant_keyed() {
    file_contains_multiline 'carrierKey\([\s\S]{0,600}getFacilityCode' "$HANDLER"
}
RECCTLTEST=$TST/unit/controller/ReceivingControllerUnitTest.java

# ADDED 2026-08-11 (wms2-api PR #148). An independent conformance lane TRANSPOSED the two args of
# `putawayDestinationDivertedToLane` and all 4927 API tests stayed green: ExceptionMessageService is
# mocked with anyString()/any(Object[].class) and the only assertion was `divertedReason` non-empty.
# Transposed, the sentence tells an operator the stock was received to the PICK FACE and will move to
# the LANE — the exact inversion of what happened, on the screen this ticket exists to make truthful.
#
# ⚠ MUST use code_contains_ml, not file_contains_multiline. The call site now carries a comment saying
# "%1$s is where the stock LANDS, %2$s is what was CONFIGURED" — a comment-blind grep for the order
# would be satisfied by that prose alone, which is the ninth instance of this trap in this script.
# The positive regex alone rejects the transposition: after swapping, `getName()` precedes
# `laneLabel(` and there is no second `getName()` for the pattern to reach.
#
# Deliberately NOT coupled to the captor's local variable name. A first draft matched
# `\bargs\.capture\(\)`; a correct rewrite that renamed the local would have gone red for no reason.
# The load-bearing assertion is the EXPECTATION ORDER in `containsExactly`, which is name-independent.
check_P2_diverted_argorder() {
    code_contains_ml 'putawayDestinationDivertedToLane[\s\S]{0,120}laneLabel\([\s\S]{0,120}getName\(\)' "$RECCTL" \
    && code_contains_ml 'ArgumentCaptor<Object\[\]>[\s\S]{0,400}\.capture\(\)' "$RECCTLTEST" \
    && code_contains_ml 'containsExactly\("Put Away Lane", *"ICE PACK"\)' "$RECCTLTEST"
}

# §3.8 (iv-b): the display must report the placement as well as the configuration.
check_N2_display_reports_divert() {
    file_contains 'PutawayDisplay' "$QRYSVC" \
      && file_contains 'divertPickFaceToLane' "$QRYSVC" \
      && file_contains 'divertedTo' "$RECCTL"
}

check_17a_lane_means_null() {
    file_contains_multiline 'STANDARD_PUTAWAY_LANE[\s\S]{0,200}return null' "$MPAS"
}
check_CTL_confirm_param()   { file_contains 'confirmIncompatibleSkus' "$CFGCTL"; }
check_CTL_preauthorize()    { file_contains_n_times '@PreAuthorize' "$CFGCTL" 3; }
# Phase 1a ships only setSku + setWarehouse; setMerchant is 1b (client column needs V2.2.13).
check_CTL_preauthorize_1a() { file_contains_n_times '@PreAuthorize' "$CFGCTL" 2; }
# The writers must be reachable — this is the dead-code guard the plan condemns elsewhere.
check_CTL_calls_service()   { file_contains 'putawayConfigService\.' "$CFGCTL"; }
# Preview is a resolver consumer, so it needs the §3.1.5 read-facade treatment, not a bare controller call.
check_CTL_no_direct_resolve() { file_not_contains 'putawayDestinationResolver\.' "$CFGCTL"; }
check_H_no_checked_throws()    { file_not_contains 'throws +BusinessException' "$HANDLER"; }
check_H_preauthorize()      { file_contains '(PreAuthorize|IS_SB_ADMIN|isSbAdmin)' "$HANDLER"; }

check_H_ctl_preauthorize()  { file_contains 'Authority\.IS_SB_ADMIN' "$IDCTL"; }

# ── ADDED 2026-08-11 for the PR #139 review round (3 findings, all accepted). ──────────────────
# Same lesson as the 3b round above: a gate that cannot see a round of changes is not gating it.
# Each row below was negative-tested by reverting its fix and confirming the row goes FAIL.

# P1 — DELETE /v3/sysprop/{id} on the guarded key must reach an sb_admin gate. D12 accepts the
# resulting STATE; that is not a statement about the audience, and block C of SecurityConfiguration
# grants /v3/sysprop/** to wms_user in spite of its "Admin-Only" label.
check_H_delete_authorized() {
    file_contains_multiline 'onBeforeDelete\(Sysprop incoming\)[\s\S]{0,900}requireWarehouseConfigWriteAuthority\(\)' "$HANDLER"
}
# The gate must exist on the proxied @Service (§3.9.4) AND carry the authority — a method that is
# present but unannotated is the silent-no-op shape this ticket has already been bitten by.
check_CFG_delete_gate_annotated() {
    file_contains_multiline '\@PreAuthorize\(Authority\.IS_SB_ADMIN\)\s*\n\s*public void requireWarehouseConfigWriteAuthority' "$CFGSVC"
}
# It must run BEFORE the carrier is touched: a denied delete that has already stashed leaves an entry
# on a POOLED thread, which a later request can take and turn into a false audit row.
check_H_delete_gate_first() {
    file_contains_multiline 'requireWarehouseConfigWriteAuthority\(\)[\s\S]{0,600}pendingPreviousValue\.get\(\)\.remove' "$HANDLER"
}
# NEG: the delete must NOT be routed through validateOnly. That validates the row's OLD value, so a
# rotted config (locked location, lane) would become undeletable — §3.9.3's trap in its worst form.
# Scoped to the method BODY, and paired with a positive on the same extraction: an empty extraction
# (renamed method, reformatted brace) would otherwise satisfy the negative half for free.
check_H_delete_not_via_validateonly() {
    local body
    body=$(method_body 'public void onBeforeDelete(Sysprop incoming)' "$HANDLER" | code_only) || return 1
    printf '%s' "$body" | grep -q 'requireWarehouseConfigWriteAuthority' || return 1
    ! printf '%s' "$body" | grep -q 'validateOnly'
}

# P2a — the HAL channel must enforce D11's ABSOLUTE half at tiers 2/3. The validator is necessarily
# called there with no SKU and no unit-load type, so P2.6 never runs and HAL accepted a destination
# the typed endpoint refuses with 422.
check_CFG_hal_absolute_reject() {
    file_contains_multiline 'validateOnly\([\s\S]{0,900}rejectIfIncompatibleWithEveryScopedSku' "$CFGSVC" \
      && file_contains 'putawayDestinationIncompatibleForEverySku' "$CFGSVC"
}
# The MERCHANT create path must not fall through to skusInScope's findAll(): a HAL POST /v3/client has
# no id yet, so the write would be judged against EVERY SKU in the tenant. Body-scoped for the same
# reason as the row above — the window form of this check failed a correct implementation.
check_CFG_hal_no_tenant_wide_merchant() {
    local body
    body=$(method_body 'private void rejectIfIncompatibleWithEveryScopedSku' "$CFGSVC") || return 1
    printf '%s' "$body" | grep -q 'PutawayScope\.MERCHANT' \
      && printf '%s' "$body" | grep -q 'subjectId == null' \
      && printf '%s' "$body" | grep -q 'skusInScope'
}
# NEG: the PARTIAL case must stay permitted on HAL. Spring Data REST ignores unknown query
# parameters, so confirmIncompatibleSkus can never reach a @HandleBefore* handler; rejecting partial
# incompatibility here would be an edit lock on the live shipper screen.
check_CFG_hal_partial_still_allowed() {
    file_contains_multiline '>= skus\.size\(\)' "$CFGSVC"
}

# P2b — the typed writers must recompute and write inside ONE tenant transaction, and must name the
# TENANT manager (a bare @Transactional binds the @Primary landlord manager). rollbackFor is
# load-bearing: without it this outer boundary tries to commit a transaction the inner writer already
# marked rollback-only, and every 422/409 surfaces as a 500 UnexpectedRollbackException.
check_CTL_writers_transactional() {
    file_contains_n_times '@Transactional\(value = "tenantTransactionManager", rollbackFor = Exception\.class\)' "$CFGCTL" 2
}
check_T_review_round_tested() {
    file_contains 'requireWarehouseConfigWriteAuthority' "$TST/unit/config/PutawayConfigRepositoryEventHandlerUnitTest.java" \
      && file_contains 'putawayDestinationIncompatibleForEverySku' "$TST/unit/service/PutawayConfigServiceUnitTest.java" \
      && file_contains 'tenantTransactionManager' "$TST/unit/controller/PutawayConfigControllerUnitTest.java"
}

# ============================================================================
# PHASE 1-API — tests (§7.1, §7.2)
# ============================================================================

check_T_resolver_test()     { file_exists "$TST/unit/service/PutawayDestinationResolverUnitTest.java"; }
check_T_cfg_test()          { file_exists "$TST/unit/service/PutawayConfigServiceUnitTest.java"; }
check_T_handler_test()      { file_exists "$TST/unit/config/PutawayConfigRepositoryEventHandlerUnitTest.java"; }
check_T_ctx_test()          { file_exists "$CTXTEST"; }
# The context-load test is the only thing that catches DI drift across six new
# beans; it must be @Disabled with the SBDEV-2217 TODO, not silently deleted.
check_T_ctx_disabled()      { file_contains 'TODO\(SBDEV-2217\)' "$CTXTEST"; }
check_T_ctx_autowires()     { file_contains 'PutawayDestinationResolver' "$CTXTEST"; }

# The landmine assertions must exist AS TESTS, not just as design prose.
check_T_no_getstringdefault_asserted() { file_contains 'getStringDefault' "$TST/unit/service/PutawayDestinationResolverUnitTest.java"; }
check_T_null_sku_asserted()            { file_contains_i 'null' "$TST/unit/service/PutawayDestinationResolverUnitTest.java"; }
check_T_fail_open_asserted()           { file_contains_i 'empty' "$TST/unit/service/LocationConstraintServiceUnitTest.java"; }
# UnitloadBusinessServiceUnitTest:193,208 pinned the raw-ID text and MUST be
# updated deliberately — assert the OLD text is gone, not that the file changed.
# SCOPED 2026-08-06: was a bare grep for 'not allowed on location' over the whole file.
# SBDEV-2731 PR1 (#133) correctly removes the pinned assertion but retains the string inside
# an explanatory COMMENT at UnitloadBusinessServiceUnitTest:207, so the unscoped grep stays
# FAIL against a correct tree — sending the implementer hunting for an assertion that no
# longer exists, or "fixing" it by deleting a useful comment from a merged commit.
# Match assertion syntax, not the bare phrase.
check_T_old_message_assertion_gone() {
    local f="$TST/unit/service/UnitloadBusinessServiceUnitTest.java"
    [ -f "$f" ] || return 1
    # Strip comment lines BEFORE matching. Scoping to assertion syntax was not enough: SBDEV-2731's
    # merged test explains the removal in a comment that QUOTES the assertion verbatim at :207 —
    #   // which pinned `.hasMessageContaining("not allowed on location")` — the raw,
    # so the check stayed red against correct code for a second, subtler reason. Verified 2026-08-07
    # against the merged tree: comment-stripped, the assertion is genuinely gone.
    ! grep -vE '^[[:space:]]*(//|\*|/\*)' "$f" | grep -qE 'hasMessageContaining\("not allowed on location'
}
# CORRECTED 2026-08-02: the old alternation was 'putawayDestinationNotPermitted|not
# permitted on a'. Neither branch can match. The putaway key is deliberately ABSENT from
# this site (§3.6.1), and the neutral message reads "...not permitted on location %2$s",
# so "on a" never appears. Assert the neutral key / its rendered wording instead.
check_T_new_message_asserted()         { file_contains 'unitloadTypeNotPermittedOnLocation|not permitted on location' "$TST/unit/service/UnitloadBusinessServiceUnitTest.java"; }

# ============================================================================
# PHASE 2-UI — web UI (§3.11)
# ============================================================================

UI_RECFORM=$UI_ROOT/components/receiving/open/receive/receivingForm.vue
UI_EDITPARAM=$UI_ROOT/components/admin/parametersAndConfiguration/editParamAndConfig.vue
UI_EDITSHIPPER=$UI_ROOT/components/admin/shippers/editShipper.vue
UI_PICKER=$UI_ROOT/components/common/LocationPicker.vue
UI_PICKERSPEC=$UI_ROOT/test/components/common/locationPicker.spec.js
UI_ADDPARAM=$UI_ROOT/components/admin/parametersAndConfiguration/addParamAndConfig.vue
UI_PUTAWAYFIELD=$UI_ROOT/components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue
UI_OPSOPTIONS=$UI_ROOT/components/admin/parametersAndConfiguration/operationOptions/operationOptions.vue
UI_CONFIGSTORE=$UI_ROOT/store/admin/configuration.js
UI_SYSKEYUTIL=$UI_ROOT/util/putawayConfig.js
UI_SHIPPERSTORE=$UI_ROOT/store/admin/shippers.js
UI_KCROLES=$UI_ROOT/util/keycloakRoles.js
UI_PERSIST=$UI_ROOT/plugins/persistedState.client.js

# NEGATIVE: the hardcoded "Put Away Lane" literal must be gone FROM THE TEMPLATE.
# PREMISE CORRECTED 2026-08-06: this asserted the literal is absent from the FILE, which is
# the opposite of what SBDEV-2731 PR1 (#39) ships. That PR deliberately RETAINS the wording
# as a named constant — receivingForm.vue:222
#   const DEFAULT_PUTAWAY_LANE_LABEL = 'Put Away Lane'   // operator-facing text only
# and explains at :307 that mapping the machine name 'PutAwayLane' back to that label
# preserves the operator-facing wording. The old form would therefore fail forever against
# correct merged code. What must actually be gone is the literal INLINE IN THE TEMPLATE
# (the un-bound hard-coded render at the old :12); a named constant in <script> is correct.
check_U_hardcoded_gone()    { file_not_contains '>[[:space:]]*Put Away Lane[[:space:]]*<' "$UI_RECFORM"; }
# NOT VACUOUS: `putawayStaging: null` ALREADY exists at receivingForm.vue:206 as a
# dead data property that is never read or written (exactly 1 occurrence today).
# Requiring >= 2 occurrences is what proves it is actually bound and populated.
check_U_binds_staging()     { file_contains_n_times 'putawayStaging' "$UI_RECFORM" 2; }
# TIGHTENED 2026-08-02: was `file_contains_i 'source'`, satisfied by the word "source"
# in any comment, import path or unrelated prop. §3.11.1 specifies the four-tier chip is
# driven by the resolver's `sourceLabel` field, so assert that field by name.
# ⚠ vue_code_only, not file_contains. This row was satisfied by an HTML COMMENT: deleting every CODE
# use of `sourceLabel` (the chip, the data prop, the reset, the assignment) left only the comment
# "The envelope sends `sourceLabel` ready to display" and the row stayed GREEN. Its header records a
# 2026-08-02 tightening from `file_contains_i 'source'` to `'sourceLabel'` — that tightened the SYMBOL
# axis and left the PROSE axis wide open. Eighth prose-vs-code trap in this file.
check_U_shows_source() {
    [ -f "$UI_RECFORM" ] || return 1
    vue_code_only "$UI_RECFORM" | grep -qE 'putawaySourceLabel'
}
# PRESERVATION, added 2026-08-06. SBDEV-2731 PR1 (#39) ships a TRI-STATE `isPutawayDestinationApplied`
# returning true/false/null, and the template MUST compare `=== false`. `!null` is `true`, so rewriting it
# as a falsy test silently restores the bug 2731 fixed — on first paint, for every tenant with
# REQUIRE_RECEIVING_TO_CONTAINER=false, i.e. exactly the population that configures alternate putaway
# locations. This plan adds `sourceLabel` to the same block, so this plan can break it.
# Fails until #39 merges (the symbol does not exist on develop yet) — that is correct, it is a
# post-prerequisite preservation check, not a pre-implementation one.
check_U_tristate_kept()     { file_contains 'isPutawayDestinationApplied === false' "$UI_RECFORM"; }
# ⚠ STRENGTHENED 2026-08-11 (step 19). This was `file_exists` and nothing else, so `touch
# components/common/LocationPicker.vue` turned it green. `U-negq` beside it was a bare
# file_not_contains on a symbol nobody would type, which is a VACUOUS NEGATIVE the moment the file
# exists -- it passed for an empty file too. Both now assert the component's actual shape.
#
# ⚠ EVERY NEGATIVE HERE PIPES THROUGH code_only, and it is not defensive habit: the component's own
# header comment explains WHY it must not read `useforgoodsin` ("Reading `useforgoodsin` here would
# reintroduce it"), and cites `area.useforgoodsin ? DEFAULT : ADVANCED` as the SERVER's rule. A raw
# grep would therefore FALSE-FAIL the correct implementation -- the fifth time this file has hit the
# prose-vs-code trap (after P2-br-7, NOSTUB, P2A-lane-name, P2C-pure).
picker_code() { [ -f "$UI_PICKER" ] || return 1; code_only < "$UI_PICKER"; }

# §11.1a's `U-diverted`, ADDED 2026-08-11. It was named in the acceptance table and existed nowhere in
# this script — the eighth such row, after the seven steps 19-21 closed. It covers step 19a item 3, which
# is the entire reason §3.11.1 still exists: under (iv-b) a pick-face destination is configured but NOT
# placed at receipt, so without this rendering the screen shows `ICE PACK` while the unit load lands on
# `PutAwayLane` — an operator-visible lie, and the same defect class as SBDEV-2731, the bug this whole
# ticket descends from.
#
# ⚠ SCOPE, stated rather than implied. §11.1a says "on a line distinct from `putawayStaging`". A grep
# CANNOT verify template structure — that lesson cost two attempts on U20-uncond, where enumerating
# known-bad conditions missed `v-if="items.length > 0"` and the proximity form then false-FAILED correct
# code because a regex cannot tell a preceding element from an enclosing one. So this row asserts the
# three things that ARE textually checkable:
#   (a) BOTH fields render — §11.1a says "both", and `divertedReason` without `divertedTo` (or the
#       reverse) is the likely half-implementation;
#   (b) `putawayStaging` SURVIVES — §3.11.1: "never by overwriting `putawayStaging`: the admin's
#       configured value must stay visible beside where the stock will actually land";
#   (c) they are not interpolated into the SAME mustache, which is the cheap way to smuggle the
#       diversion into the existing line.
# Whether they land on genuinely separate lines is behavioural and belongs to a Jest spec, which step
# 19a must add. This row does not claim to cover that.
#
# ⚠ BOTH of the non-obvious clauses were WRONG on the first attempt, caught by validating the row
# against near-miss implementations rather than trusting it:
#   - clause (b) grepped bare `putawayStaging`, which matches `putawayStagingXX` as a SUBSTRING — so
#     renaming the prop away (i.e. overwriting the admin's configured value, the exact thing §3.11.1
#     forbids) left the row GREEN. Now word-anchored. This is the same substring trap that produced ten
#     false "ASSERTS NOTHING" verdicts on the V-* rows earlier.
#   - clause (c) checked for both symbols inside ONE mustache. The realistic violation is
#     `{{ putawayStaging }} {{ divertedTo }} {{ divertedReason }}` — three separate interpolations on
#     one LINE — which sailed through. grep is line-oriented, and "on a line distinct from" is exactly a
#     per-line claim, so the check is now simply: no single line carries both symbols.
#
# ⚠ vue_code_only, not code_only: §3.11.1's own wording will very likely be quoted in a template
# comment beside the markup, and `code_only` is line-oriented so it does not strip `<!-- -->` blocks.
# That is the trap U19-warn shipped with.
# §3.11.1 / review F3, ADDED 2026-08-12. The silent catch left the screen presenting an UNVERIFIED
# destination as confirmed. Post-2732 that is an affirmative false claim, not a neutral omission: the
# screen's vocabulary now includes diversion notices, so their absence reads as "not diverted". The seed
# comes from the tier-1-only DTO column, and tier 1 is exactly where SBDEV-2643 puts pick faces, which
# (iv-b) ALWAYS diverts — so the degraded screen displayed the tier most likely re-routed while
# suppressing the notice, and labelled it "(SKU override)" as well.
#
# The last two clauses are the ones that took a rewrite to get right:
#   - the RESET must precede the positionId guard. It used to sit after it, so a position with no
#     advicepositionid kept the previous line's diversion on screen — a third early-return path D14/D15
#     never reached. The regex pins the ORDER, not just presence.
#   - the stamp must be claimed once and re-checked after BOTH awaits (success and failure). Two reads
#     overlap within one mount, and a stale FAILURE landing on a newer SUCCESS rendered the unconfirmed
#     notice beside a live diversion notice — two contradictory warnings (F3 review, D33/D34).
#     The windows here are deliberately UNBOUNDED: the first version allowed 600 chars between the two
#     rechecks against an actual distance of 467, so ~130 characters of added code — two more envelope
#     assignments — would have turned this row red on a correct implementation. These three tokens occur
#     nowhere else in the file, so an unbounded gap is both sufficient and stable.
#   - the flag must NOT be set on the empty-envelope path. A 200 with no body is unreachable in
#     production but IS what SBDEV-2731's spec returns for this endpoint, so setting it there flips
#     **T19/T22** — tests step 19a must preserve. (Said T24/T25 until measured: those assert the ABSENCE
#     of the qualifier and stay GREEN under the mutation. This was the FIFTH site carrying that wrong
#     citation, and the one a maintainer of THIS row reads first.)
check_U_degraded_unconfirmed() {
    [ -f "$UI_RECFORM" ] || return 1
    vue_code_only "$UI_RECFORM" | grep -qE 'putawayDestinationUnconfirmed: false' \
    && vue_code_only "$UI_RECFORM" | grep -qE 'this\.putawayDestinationUnconfirmed = true' \
    && vue_code_only "$UI_RECFORM" | grep -qE 'if \(this\.putawayDestinationUnconfirmed\) return false' \
    && vue_code_only "$UI_RECFORM" | grep -qE 'id="idPutawayUnconfirmed"' \
    && vue_code_only "$UI_RECFORM" \
         | perl -0777 -ne 'exit(/putawayDestinationUnconfirmed && isPutawayDestinationApplied !== false/s ? 0 : 1)' \
    && vue_code_only "$UI_RECFORM" \
         | perl -0777 -ne 'exit(/loadPutawayDestination\(\)[\s\S]{0,900}?putawayDestinationUnconfirmed = false[\s\S]{0,300}?if \(!positionId\) return/s ? 0 : 1)' \
    && ! vue_code_only "$UI_RECFORM" \
         | perl -0777 -ne 'exit(/if \(!envelope\)[\s\S]{0,160}putawayDestinationUnconfirmed/s ? 0 : 1)' \
    && vue_code_only "$UI_RECFORM" \
         | perl -0777 -ne 'exit(/seq = \+\+this\.putawayRequestSeq[\s\S]*?seq !== this\.putawayRequestSeq[\s\S]*?seq !== this\.putawayRequestSeq/s ? 0 : 1)'
}

check_U_diverted() {
    [ -f "$UI_RECFORM" ] || return 1
    vue_code_only "$UI_RECFORM" | grep -qE 'id="idPutawayDiverted"' \
    && vue_code_only "$UI_RECFORM" | grep -qE '\{\{ *putawayDivertedReason *\}\}' \
    && vue_code_only "$UI_RECFORM" | grep -qE 'putawayDivertedTo' \
    && vue_code_only "$UI_RECFORM" | grep -qE 'envelope\.divertedTo' \
    && vue_code_only "$UI_RECFORM" | grep -qE 'envelope\.divertedReason' \
    && vue_code_only "$UI_RECFORM" | grep -qE 'putawayDisplay' \
    && vue_code_only "$UI_RECFORM" | grep -qE '\bputawayStaging\b' \
    && ! vue_code_only "$UI_RECFORM" \
         | grep -qE 'putawayDisplay.*putawayDiverted|putawayDiverted.*putawayDisplay'
}

check_U_picker_exists() {
    file_exists "$UI_PICKER" \
    && file_contains 'v-autocomplete' "$UI_PICKER" \
    && picker_code | grep -qE ':items="offeredItems"' \
    && picker_code | grep -qE '^\s*value:' \
    && picker_code | grep -qE '^\s*items:'
}

# The tier comes off the SERVER's field. Both literals must appear in CODE, not prose.
check_U19_tier_from_server() {
    picker_code | grep -qE "tier === 'DEFAULT'" \
    && picker_code | grep -qE "tier === 'ADVANCED'"
}

# §3.11 defect 1: no client-side flag test, and never the payload that carries no flags.
# ⚠ TIGHTENED 2026-08-11 after an independent verify lane broke the first form TWICE, and both
# mutations were green on Jest as well — the only gap in this batch that NEITHER gate covered:
#   (a) it grepped $UI_PICKER ONLY, so `if (this.selectedRow.useforgoodsin) ...` added to
#       defaultPutawayLocationField.vue passed;
#   (b) it grepped only useforgoodsin|useforstorage|useforpicking, so `row.staginglane !== true &&
#       row.sltname !== 'flowbin'` added INSIDE LocationPicker.vue passed. `staginglane`, `sltname`
#       and `entity_lock` — 3 of the 5 symbols §11.1a names — were checked nowhere at all, and
#       staginglane/sltname are precisely the two predicates that INVERT between scopes (§3.11.5a),
#       so a client-side test of them is the most damaging version of this defect.
#
# ⚠ SCOPE, and why it is not §11.1a's literal repo-wide form: eight existing files legitimately
# reference these columns to DISPLAY them on master-data grids — functionalArea.vue,
# locationType.vue, storageLocation.vue, batchDetails.vue, clubRunDetails.vue, itemsTable.vue,
# store/masterData/locationType.js, store/outbound/club.js (count independently confirmed). Showing
# a column is not testing a predicate, so the repo-wide row would fail forever against correct code.
# This is the scoped form, and the rationale now lives ON THIS ROW rather than on U-neg-detailview.
check_U19_no_client_flag_test() {
    [ -f "$UI_PICKER" ] || return 1
    for f in "$UI_PICKER" "$UI_PUTAWAYFIELD" "$UI_EDITPARAM" "$UI_ADDPARAM" "$UI_EDITSHIPPER"; do
        [ -f "$f" ] || continue
        vue_code_only "$f" \
            | grep -qiE 'useforgoodsin|useforstorage|useforpicking|staginglane|sltname|entity_?lock' \
            && return 1
    done
    ! picker_code | grep -qE 'location/detailView'
}

# The caller owns the paginated read; the component must not fetch at all.
check_U19_no_fetch() {
    [ -f "$UI_PICKER" ] || return 1
    ! picker_code | grep -qE '\$axios|\$get\(|\$fetch'
}

check_U19_item_fields() {
    file_contains 'item-text="locationName"' "$UI_PICKER" \
    && file_contains 'item-value="locationId"' "$UI_PICKER"
}

# `eligible` is absolute — there is no third "offered with a warning" state (§3.11.5).
check_U19_eligible_absolute() { picker_code | grep -qE 'eligible === true'; }

# The advanced tier's lock warning (§7.6 row 8) is mandatory and must be GATED on the toggle,
# not always-on: an always-visible warning is one operators learn to ignore.
check_U19_advanced_warning() {
    vue_code_only "$UI_PICKER" | perl -0777 -ne 'exit(/v-if="showAdvanced"[\s\S]{0,900}deadlock/s ? 0 : 1)' \
    && vue_code_only "$UI_PICKER" | grep -qiE 'lock' \
    && vue_code_only "$UI_PICKER" | grep -qiE 'receipt'
}

# @select must carry the resolved ROW, not the id the caller already has.
check_U19_select_emits_row() {
    picker_code | grep -qE "\\\$emit\('select', selected\)" \
    && picker_code | grep -qE 'offeredItems\.find'
}

# An already-saved ADVANCED destination stays visible with the toggle closed, or the field renders
# empty and tells the operator nothing is configured when something is.
check_U19_selected_row_visible() { picker_code | grep -qE 'row\.locationId === this\.value'; }

# ==========================================================================================
# SBDEV-2732 step 20 — Operation Options (§3.11.2)
# ==========================================================================================

putaway_ui_code() {   # every step-19/20 putaway surface, comments stripped
    for f in "$UI_PICKER" "$UI_PUTAWAYFIELD" "$UI_EDITPARAM" "$UI_ADDPARAM" "$UI_SYSKEYUTIL"; do
        [ -f "$f" ] && code_only < "$f"
    done
}

# N1 / §3.9.1 — the typed write, and NOT the three generic sysprop actions. Two of those three
# bypass the event handler entirely, so reusing one ships the warehouse tier unvalidated and
# unaudited; it is the tier every SKU and every un-overridden merchant falls back to.
check_U_warehouse_typed() {
    [ -f "$UI_CONFIGSTORE" ] || return 1
    file_contains 'setWarehousePutawayDestination' "$UI_CONFIGSTORE" \
    && file_contains_multiline "setWarehousePutawayDestination[\s\S]{0,2600}putawayConfig.warehouse" "$UI_CONFIGSTORE" \
    && code_only < "$UI_EDITPARAM" | grep -qE 'isDefaultPutawayLocation\) return' \
    && code_only < "$UI_ADDPARAM"  | grep -qE 'isDefaultPutawayLocation\) return'
}

# The picker's rows come from the typed read, via a store action.
check_U_picker_source() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE "getEligiblePutawayLocations" \
    && file_contains_multiline "getEligiblePutawayLocations[\s\S]{0,3000}putawayConfig.eligibleLocations" "$UI_CONFIGSTORE"
}

# ⚠ SCOPED TO THE PUTAWAY SURFACES, DELIBERATELY, and §11.1a's wording is wrong. It asks for "no
# .vue or store file" to reference /location/detailView or the predicate flags. Repo-wide that is
# unsatisfiable: eight existing files -- functionalArea.vue, storageLocation.vue, locationType.vue
# and others -- reference useforgoodsin / useforstorage / staginglane / sltname because they DISPLAY
# those columns on master-data grids, which is correct. Displaying a column is not testing a
# predicate. A repo-wide row would fail forever against correct code, which is the one thing worse
# than a missing row.
check_U_neg_detailview() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    ! putaway_ui_code | grep -qE 'location/detailView|getStorageLocationsForPutAwayItemData' \
    && ! code_only < "$UI_CONFIGSTORE" | grep -qE "eligibleLocations[\s\S]{0,200}detailView"
}

# The paginated read must be ACCUMULATED — 516 of 2,739 rows are eligible on wineco-dev, so one
# page silently truncates the list and the operator concludes their location does not exist.
check_U20_paging_accumulated() {
    [ -f "$UI_CONFIGSTORE" ] || return 1
    file_contains_multiline "getEligiblePutawayLocations[\s\S]{0,2000}(for \(;;\)|while \(|do \{)" "$UI_CONFIGSTORE" \
    && file_contains_multiline "getEligiblePutawayLocations[\s\S]{0,2000}(totalPages|last === false)" "$UI_CONFIGSTORE" \
    && file_contains_multiline "getEligiblePutawayLocations[\s\S]{0,2000}totalElements" "$UI_CONFIGSTORE"
}

# The config-health gate: preview is called, and a non-null blockingReason DISABLES Save rather
# than offering a button that can only 422.
check_U20_preview_gate() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'previewPutawayConfig' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'saveDisabled' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'saveDisabled' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'blockingReason != null'
    # ⚠ NO PROXIMITY WINDOW HERE, on purpose. The first form was
    #   code_contains_ml 'saveDisabled\(\)[\s\S]{0,200}blockingReason'
    # and it STAYED GREEN when the guard was deleted from saveDisabled -- because ~130 chars later
    # the file declares blockingReasonText(), and the window bled into the next method. Identical
    # to P2A-svc-tx, whose {0,400} matched a different method's annotation. `blockingReason != null`
    # is the guard's exact shape and appears nowhere else in the file (the template tests plain
    # truthiness; the preview assignment has no comparison), so it needs no window at all.
}

# D11 — the exact count travels, because the writer recomputes it and 409s a stale confirmation.
check_U20_d11_confirm() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'showConfirm' \
    && file_contains_multiline 'incompatibleSkuCount > 0[\s\S]{0,200}showConfirm = true' "$UI_PUTAWAYFIELD" \
    && code_contains_ml 'confirmSave\(\)[\s\S]{0,400}write\(this\.incompatibleSkuCount\)' "$UI_PUTAWAYFIELD"
}

# The edit AND add dialogs both branch, and both render the typed field rather than the text input.
check_U_param_branch() {
    # ⚠ The TEMPLATE must branch, not merely mention the flag. The first form grepped for the bare
    # identifier, which also appears in the computed and in the submit guard — so replacing the
    # template's v-if with v-if="false" (a dead branch, picker never rendered) left the row GREEN.
    file_contains 'v-if="isDefaultPutawayLocation"' "$UI_EDITPARAM" \
    && file_contains 'default-putaway-location-field' "$UI_EDITPARAM" \
    && file_contains 'v-if="isDefaultPutawayLocation"' "$UI_ADDPARAM" \
    && file_contains 'default-putaway-location-field' "$UI_ADDPARAM"
}

# ⚠ The control must render whether or not a DEFAULT_PUTAWAY_LOCATION row exists (§3.11.2). The seed
# may not have run, and D12 lets an operator DELETE the row -- and since POST /systemProperty/create
# REJECTS this syskey, a list-driven control leaves the warehouse tier permanently unreachable, with
# no way for the operator to re-create the row and get the control back.
check_U20_unconditional() {
    [ -f "$UI_OPSOPTIONS" ] || return 1
    file_contains 'default-putaway-location-field' "$UI_OPSOPTIONS" \
    && file_exists "$UI_ROOT/test/components/admin/paramAndConfigPutawayBranch.spec.js" \
    && file_contains 'NO DEFAULT_PUTAWAY_LOCATION row' "$UI_ROOT/test/components/admin/paramAndConfigPutawayBranch.spec.js" \
    && file_contains 'list is completely empty' "$UI_ROOT/test/components/admin/paramAndConfigPutawayBranch.spec.js"
}
# ⚠ THIS ROW DELIBERATELY DELEGATES THE BEHAVIOURAL HALF TO JEST, and the history is why.
#   v1 enumerated the two guard conditions I happened to imagine; an independent lane then wrapped
#   the control in `v-if="items.length > 0"` — LITERALLY the defect the row exists to block — and the
#   row stayed green. Enumerating known-bad conditions cannot work.
#   v2 rejected ANY v-if/v-show within 700 chars before the element. That FALSE-FAILED correct code:
#   the search field above the data table has a `v-if="showSearch"`, and a regex cannot tell a
#   PRECEDING element from an ENCLOSING one. Widening the window makes it worse, not better.
# The honest split: this row asserts the control is present and that the reachability SPECS exist;
# `D6`/`D7` in that spec mount the screen with a list containing no such row and with an empty list,
# which does catch `v-if="items.length > 0"` (independently confirmed). A grep cannot verify template
# enclosure — claiming otherwise produces exactly the two failure modes above.

# The syskey literal lives in exactly ONE place; three surfaces branch on it and a repeated literal
# drifts in two of them. A mistyped branch silently falls back to the free-text field -- which is
# the defect §3.11.2 exists to remove, and it would look like "the picker just didn't render".
check_U20_syskey_single_source() {
    [ -f "$UI_SYSKEYUTIL" ] || return 1
    file_contains "DEFAULT_PUTAWAY_LOCATION_SYSKEY = 'DEFAULT_PUTAWAY_LOCATION'" "$UI_SYSKEYUTIL" \
    && ! code_only < "$UI_EDITPARAM" | grep -qE "'DEFAULT_PUTAWAY_LOCATION'" \
    && ! code_only < "$UI_ADDPARAM"  | grep -qE "'DEFAULT_PUTAWAY_LOCATION'" \
    && ! code_only < "$UI_OPSOPTIONS" | grep -qE "'DEFAULT_PUTAWAY_LOCATION'"
}

check_U20_specs_exist() {
    file_exists "$UI_ROOT/test/store/admin/configurationPutaway.spec.js" \
    && file_exists "$UI_ROOT/test/components/admin/defaultPutawayLocationField.spec.js" \
    && file_exists "$UI_ROOT/test/components/admin/paramAndConfigPutawayBranch.spec.js"
}

# ==========================================================================================
# SBDEV-2732 step 21 — shipper screen / merchant tier (§3.11.3)
# ==========================================================================================

# ⚠ THE NEGATIVE §11.1a ASKED FOR, and it guards a genuinely invisible defect. `editShipper` is
# `$patch('/client/{id}', data)` — the HAL path: no validation, no audit, no cache eviction, and no
# way to carry D11's confirmation. editShipper.vue's save() sends the WHOLE shipper object, so if
# `defaultputawaylocationId` is ever present on it, changing a printer silently overwrites the
# putaway destination through the unvalidated path, clobbering whatever the typed endpoint last set.
# The destructure must also NOT be a `delete` in place, which would mutate the live form object and
# blank the control the operator is looking at.
check_U_neg_shipper_patch() {
    [ -f "$UI_SHIPPERSTORE" ] || return 1
    code_only < "$UI_SHIPPERSTORE" | grep -qE 'defaultputawaylocationId, \.\.\.payload' \
    && code_only < "$UI_SHIPPERSTORE" | grep -qE '\$patch\(`/client/\$\{payload\.id\}`, payload\)' \
    && ! code_only < "$UI_SHIPPERSTORE" | grep -qE 'delete data\.defaultputawaylocationId'
}

# The three-state control binds the envelope's `inherited` BOOLEAN. A Vue-side comparison against
# 'MERCHANT_OVERRIDE' is a second copy of the precedence rules — the SBDEV-2731 failure mode, where
# the operator saw tier 1 while tiers 2 and 3 decided.
check_U_merchant_inherited() {
    [ -f "$UI_EDITSHIPPER" ] || return 1
    code_only < "$UI_EDITSHIPPER" | grep -qE 'inherited !== false' \
    && code_only < "$UI_EDITSHIPPER" | grep -qE 'effectivePutawayDestination|getEffectivePutawayDestination' \
    && ! code_only < "$UI_EDITSHIPPER" | grep -qE 'MERCHANT_OVERRIDE'
}

# ⚠ AND NOT /client/detailView, which §3.11.3 NAMES as the source but which does not carry the
# column: ViewDtoService.getClientView() (:934-957) hand-builds an eight-key DTO (id, clientName,
# clientNumber, sectionName, enablereceiving, printerName, printerreceivingId, sectionId). Same class
# of defect as §3.11 defect 1 for /location/detailView. The plan's wording is wrong, not the code.
# ⚠ grep, NOT file_contains_multiline. That helper runs `perl -0777 -ne "exit(/$1/s ? 0 : 1)"`, so an
# unescaped `/` in the pattern TERMINATES perl's match delimiter and the row fails against correct
# code. Both of this step's first-draft rows hit it (`client/...`, `putawayConfig/merchant`) — the same
# trap as P2-eligible-endpoint. Earlier rows dodged it only by writing `putawayConfig.warehouse` with a
# dot. grep -E has no delimiter, so URL patterns belong there.
check_U21_merchant_read_source() {
    [ -f "$UI_CONFIGSTORE" ] || return 1
    code_only < "$UI_CONFIGSTORE" | grep -qE 'getEffectivePutawayDestination' \
    && code_only < "$UI_CONFIGSTORE" | grep -qE '/client/.*/effectivePutawayDestination' \
    && ! code_only < "$UI_EDITSHIPPER" | grep -qE 'client/detailView'
}

# The merchant write is its own typed endpoint, and the wrapper picks the action by SCOPE.
check_U21_merchant_typed_write() {
    [ -f "$UI_CONFIGSTORE" ] || return 1
    file_contains 'setMerchantPutawayDestination' "$UI_CONFIGSTORE" \
    && code_only < "$UI_CONFIGSTORE" | grep -qE '/putawayConfig/merchant/' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE "MERCHANT: 'admin/configuration/setMerchantPutawayDestination'" \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE "WAREHOUSE: 'admin/configuration/setWarehousePutawayDestination'"
}

# Tier 2 is rendered on the shipper screen, at MERCHANT scope, with the client as subject.
check_U_shipper_field() {
    [ -f "$UI_EDITSHIPPER" ] || return 1
    file_contains 'default-putaway-location-field' "$UI_EDITSHIPPER" \
    && file_contains 'scope="MERCHANT"' "$UI_EDITSHIPPER" \
    && file_contains ':subject-id=' "$UI_EDITSHIPPER"
}

check_U21_specs_exist() {
    file_exists "$UI_ROOT/test/store/admin/shippersPutaway.spec.js" \
    && file_exists "$UI_ROOT/test/components/admin/editShipperPutaway.spec.js"
}

# ==========================================================================================
# SBDEV-2732 step 22 — config health + persistedState (§3.11.4, §3.11 step 22)
# ==========================================================================================

# ⚠ The exclusion is NESTED, which the original single top-level destructure could not express:
# `admin` is a root key and the putaway rows live at admin.configuration.operationOptions. It must
# also NOT be a `delete` — the reducer runs against the LIVE state on every mutation, so deleting
# would empty the table the operator is looking at.
check_U_persist_excluded() {
    [ -f "$UI_PERSIST" ] || return 1
    # ⚠ WIDENED 2026-08-11: the exclusion now covers the whole `admin.configuration` sub-tree,
    # because its `systemSettings` sibling carries a PLAINTEXT CUPS credential (see RV-persist).
    # The shape this row used to pin is therefore gone BY DESIGN, not by regression.
    code_only < "$UI_PERSIST" | grep -qE 'configuration, \.\.\.rest' \
    && code_only < "$UI_PERSIST" | grep -qE 'withoutPutawayConfig' \
    && ! code_only < "$UI_PERSIST" | grep -qE 'delete admin\.configuration'
}

# REGRESSION: the three original root exclusions and the app-specific key survive. Losing any of them
# reinstates SBDEV-2726's cross-app leak or the stale-timezone bug.
check_U22_persist_regression() {
    [ -f "$UI_PERSIST" ] || return 1
    code_only < "$UI_PERSIST" | grep -qE 'warehouseTimezone, selectedWarehouse, warehouses' \
    && code_only < "$UI_PERSIST" | grep -qE "key: 'vuex-web'" \
    && code_only < "$UI_PERSIST" | grep -qE "setWarehouseTimezone"
}

# Config health for an ALREADY-SAVED destination that has stopped being usable. Step 19 refuses to
# offer an ineligible row even when it is the current value, so without this the field renders EMPTY
# and reads as "nothing configured" — while receiving is in fact diverting those receipts.
check_U22_config_health() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'configuredIsInvalid' \
    && file_contains 'v-if="configuredIsInvalid"' "$UI_PUTAWAYFIELD" \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'allRows' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'reasonText\('
}

# The unfiltered candidate set has to be RETAINED: `eligibleItems` alone cannot tell "ineligible, and
# here is why" from "not a candidate at all".
check_U22_keeps_unfiltered_rows() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'allRows' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'result\.items' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'eligible === true'
    # ⚠ LOOSENED deliberately. The first form pinned the exact two assignment statements AND their
    # order, so a behaviour-preserving reorder of two adjacent lines turned it RED while all 169
    # tests stayed green — the same false-red failure mode already on record for this script
    # (V-lanes under step C). The behaviour it guards is "the unfiltered set is retained and the
    # eligible subset derived from it", which these three independent facts capture without
    # encoding statement order.
}

# It must NOT fire for an unset tier, nor before the candidate set has loaded — a false alarm on a
# valid live configuration for as long as the request takes.
check_U22_health_guards() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'selectedId == null \|\| this\.allRows\.length === 0'
}

check_U22_specs_exist() {
    file_exists "$UI_ROOT/test/plugins/persistedStatePutaway.spec.js" \
    && file_exists "$UI_ROOT/test/components/admin/putawayConfigHealth.spec.js"
}

# ==========================================================================================
# REVIEW ROUND 2026-08-11 — three independent lanes (conformance, code review, security) on
# PRs #42-#45. These rows pin the fixes so they cannot regress. Every one was negative-tested.
# ==========================================================================================

# ⚠ HIGH, found by BOTH the review and security lanes independently. The gate was
#   canEdit() { return this.$kc.hasResourceRole('sb_admin', this.$config.keycloak.clientId) }
# which is broken twice over:
#  (a) NOT REACTIVE — `$kc` is a plain injected object whose getters read a closure variable that is
#      null until the fire-and-forget initKeycloak() resolves, so the computed had ZERO reactive
#      dependencies: Vue 2 cached `false` on first paint and never re-evaluated. A real sb_admin
#      reloading onto the Operation Options tab (its index is persisted, so F5 restores it) got a
#      permanently disabled control.
#  (b) NARROWER THAN THE BACKEND — `JwtAccessTokenCustomizer.extractRoles` harvests roles from EVERY
#      client under `resource_access` plus the `groups` claim, while hasResourceRole reads ONE client;
#      and `$config.keycloak.clientId` is a build-wide env var whereas the token is issued by the
#      PER-TENANT client from tenant discovery. An sb_admin the API authorises could be locked out.
check_RV_gate_mirrors_api() {
    [ -f "$UI_KCROLES" ] || return 1
    # Shapes, not bare words: the first form grepped for the WORD `groups`, which survived when the
    # harvesting `if` was killed and left `tokenParsed.groups.forEach` behind as dead code.
    code_only < "$UI_KCROLES" | grep -qE 'Object\.keys\(resourceAccess\)' \
    && code_only < "$UI_KCROLES" | grep -qE 'Array\.isArray\(tokenParsed\.groups\)' \
    && code_only < "$UI_KCROLES" | grep -qE 'resolveSbAdmin' \
    && code_only < "$UI_KCROLES" | grep -qE 'kc\.ready'
}

# NEGATIVE: the component must not reach for hasResourceRole or the build-wide clientId again.
check_RV_gate_no_client_lookup() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    ! vue_code_only "$UI_PUTAWAYFIELD" | grep -qE 'hasResourceRole' \
    && ! vue_code_only "$UI_PUTAWAYFIELD" | grep -qE 'keycloak\.clientId'
}

# The gate must read REACTIVE data, resolved after the auth barrier.
check_RV_gate_reactive() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'isSbAdmin: false' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'isSbAdmin = await resolveSbAdmin' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'return this\.isSbAdmin'
}

# ⚠ HIGH (review lane, proven): the wrapper is never destroyed between shippers, so shipper A's
# unsaved selection, preview and confirmed count survived into shipper B — and when both INHERIT,
# `value` is null for both, the value watcher never fires, and Save wrote A's location against B's
# clientId with A's confirmed count.
check_RV_subject_reset() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'subjectId\(\)' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'resetForSubject' \
    && code_contains_ml 'resetForSubject\(\)[\s\S]{0,300}showConfirm = false' "$UI_PUTAWAYFIELD"
    # ⚠ The bare `showConfirm = false` grep was vacuous: the Cancel button's @click handler in the
    # template carries the same text, so removing it from resetForSubject() left the row green.
}

# ⚠ MEDIUM: `ComUtil.getErrorMessage` does not exist, so the ternary guarding it was permanently dead
# and every 422/409 became "network or server issue" — discarding the actionable half of D11.
check_RV_write_error_surfaced() {
    [ -f "$UI_CONFIGSTORE" ] || return 1
    code_only < "$UI_CONFIGSTORE" | grep -qE 'function putawayWriteError' \
    && ! code_only < "$UI_CONFIGSTORE" | grep -qE 'ComUtil\.getErrorMessage' \
    && code_only < "$UI_CONFIGSTORE" | grep -qE 'putawayWriteError\(error\)'
}

# ⚠ MEDIUM: a mid-pagination failure returned an empty set, and the panel then stated "0 of 0
# locations can be used as a putaway destination" — an affirmative claim, not an error state.
check_RV_partial_read() {
    [ -f "$UI_CONFIGSTORE" ] || return 1
    code_only < "$UI_CONFIGSTORE" | grep -qE 'partial: truncated' \
    && code_only < "$UI_CONFIGSTORE" | grep -qE 'partial: true' \
    && code_only < "$UI_PUTAWAYFIELD" | grep -qE 'loadIncomplete' \
    && file_contains 'v-if="loadIncomplete"' "$UI_PUTAWAYFIELD"
}

# ⚠ MEDIUM: Vuetify 2's VBtn derives `disabled` from the `disabled` prop ONLY — `:loading` does not
# disable it — so a double-click on "Save anyway" wrote twice.
check_RV_confirm_guard() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'if \(this\.saving\) return' \
    && file_contains_multiline ':loading="saving"[\s\S]{0,80}:disabled="saving"' "$UI_PUTAWAYFIELD"
}

# ⚠ MEDIUM: re-preview after a successful write rather than zeroing a count that is still true —
# otherwise a second Save sends no confirmation and the writer 409s.
check_RV_repreview() {
    [ -f "$UI_PUTAWAYFIELD" ] || return 1
    code_only < "$UI_PUTAWAYFIELD" | grep -qE 'refreshPreview' \
    && code_contains_ml "emit\('saved'[\s\S]{0,400}refreshPreview" "$UI_PUTAWAYFIELD"
}

# ⚠ HIGH for a secret at rest (security lane): `admin.configuration.systemSettings` sat one identifier
# away in the same destructure and carries CUPS_SERVER_ADDRESS_PASSWORD in PLAINTEXT. The exclusion
# now covers the whole sub-tree, and the rehydration is healed like this file's two precedents.
check_RV_persist_subtree() {
    [ -f "$UI_PERSIST" ] || return 1
    code_only < "$UI_PERSIST" | grep -qE 'configuration, \.\.\.rest' \
    && code_only < "$UI_PERSIST" | grep -qE 'setOperationOptions' \
    && code_only < "$UI_PERSIST" | grep -qE 'setSystemSettings'
}

check_RV_specs_exist() {
    file_exists "$UI_ROOT/test/util/keycloakRoles.spec.js" \
    && file_exists "$UI_ROOT/test/support/kcMock.js" \
    && file_contains 'C15' "$UI_ROOT/test/components/admin/defaultPutawayLocationField.spec.js" \
    && file_contains 'C19' "$UI_ROOT/test/components/admin/editShipperPutaway.spec.js"
}

check_U19_spec_covers_contract() {
    file_exists "$UI_PICKERSPEC" \
    && file_contains "ADVANCED" "$UI_PICKERSPEC" \
    && file_contains_i 'deadlock' "$UI_PICKERSPEC" \
    && file_contains "emitted\\('select'\\)" "$UI_PICKERSPEC"
}
# NEGATIVE: the picker must NOT use the useforstorage-only query — it can never
# return PutAwayLane (§3.11.2 / L-PRE.10).
check_U_picker_not_storage_query() {
    [ -f "$UI_PICKER" ] || return 1
    ! picker_code | grep -qE 'getStorageLocationsForPutAwayItemData'
}
# check_U_param_branch — REPLACED by the step-20 form above (was a bare literal grep).
# check_U_shipper_field — REPLACED by the step-21 form above (was a bare literal grep, and the
# literal no longer even appears in editShipper.vue: the value is read from the envelope, not bound
# to a client field, precisely so it cannot ride the HAL PATCH).
# check_U_persist_excluded — REPLACED by the step-22 form above. The old body was
# `file_contains_i 'putaway' "$UI_PERSIST"`, which any COMMENT mentioning putaway would satisfy.

# ============================================================================
# RUNNER
# ============================================================================

echo
echo "verify-SBDEV-2732 — configurable default putaway location hierarchy"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo "  UI_ROOT=$UI_ROOT"
echo "  RUN_MVN=$RUN_MVN"
echo
echo "  REMINDER: a '0 fail' result is meaningless until replayed against the"
echo "            pre-change tree (git stash) and observed to FAIL there."
echo

phase 1
echo "-- Phase 1-API — V2.2.13 migration -------------------------------------------"
run M-exists      "V2.2.13 migration file exists"                     check_M_exists
run M-dropnn      "itemdata.putawaylocation_id DROP NOT NULL"          check_M_drop_not_null
run M-backfill    "backfill is SCOPED to the PutAwayLane id"           check_M_backfill_scoped
run M-noblanket   "NEG: no blanket 'SET putawaylocation_id = NULL;'"    check_M_backfill_not_blanket
run M-clientcol   "client.defaultputawaylocation_id added"             check_M_client_column
run M-clientfk    "FK is explicitly named fk_client_defaultputawaylocation" check_M_client_fk_named
run M-sysprop     "DEFAULT_PUTAWAY_LOCATION sysprop seeded"            check_M_sysprop_seed
run M-seedblank   "sysprop seeded BLANK ('') not a real location id"   check_M_sysprop_seed_blank
run M-seedneg     "NEG: sysprop not seeded with a populated value"     check_M_sysprop_seed_not_populated
run M-group       "seeded into groupname 'Operation Options'"           check_M_sysprop_group
run M-seq         "sysprop id from nextval(seqentities), not a literal" check_M_seq_not_literal
run M-idem        "seed is idempotent (WHERE NOT EXISTS)"              check_M_idempotent
run M-audit       "putaway_config_audit table created"                 check_M_audit_table
run M-auditidx    "putaway_config_audit index created"                 check_M_audit_index
run M-auditseq    "audit table uses its own bigserial (not seqentities)" check_M_audit_bigserial
echo

phase 1
echo "-- Phase 1-API — entities & constants ----------------------------------------"
run E-notnull     "NEG: @NotNull above putawaylocation_id removed"      check_E_notnull_gone
runp all E-col         "@Column(putawaylocation_id) retained"               check_E_itemdata_col_kept
run E-clientfld   "Client.defaultputawaylocationId field added"        check_E_client_field
run E-clientget   "Client getter added"                                check_E_client_getter
run E-clientset   "Client setter added"                                check_E_client_setter
run E-clientnull  "NEG: merchant field is NOT @NotNull"                check_E_client_field_nullable
runp 1 E-const       "SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY added" check_E_constant
runp all E-lane        "STORAGE_LOCATION_PUTAWAY_LANE retained (tier 4)"    check_E_lane_constant_kept
run E-auditent    "PutawayConfigAudit entity maps the table"           check_E_audit_entity
run E-auditid     "audit entity uses GenerationType.IDENTITY"          check_E_audit_identity_id
run E-auditbase   "NEG: audit entity does not extend AbstractBaseEntity" check_E_audit_no_base_entity
run E-auditrepo   "PutawayConfigAuditRepository exists"                check_E_audit_repo
run E-auditexp    "NEG: audit repo is NOT @RepositoryRestResource"     check_E_audit_repo_not_exported
echo

phase 1
echo "-- Phase 1-API — predicate P1 + actionable message ---------------------------"
run P1-method     "LocationConstraintService.isUnitloadTypePermitted"  check_P1_method
run P1-query      "reuses findByStoragelocationtypeId"                 check_P1_uses_list_query
run P1-failopen   "empty constraint list returns true (FAIL-OPEN)"     check_P1_fail_open
run P1-equals     "Long.equals comparison retained"                    check_P1_long_equals
run UBS-deleg     "UnitloadBusinessService delegates to the predicate" check_UBS_delegates
run UBS-neg1      "NEG: 'not allowed on location=' raw concat gone"    check_UBS_raw_concat_gone
run UBS-neg2      "NEG: '\"unitloadtypeId=\" +' raw concat gone"        check_UBS_raw_unitloadtype_gone
run UBS-neg3      "NEG: in-method foundPermittingConstraint loop gone" check_UBS_loop_gone
run UBS-key       "throws the NEUTRAL unitloadTypeNotPermittedOnLocation" check_UBS_new_key
run UBS-neg4      "NEG: putaway-specific key absent from the backstop"  check_UBS_putaway_key_absent
runp all UBS-lock      "SBDEV-2232 caller-holds-locks contract preserved"   check_UBS_lock_contract_kept
run MSG-key       "message key added to messages_en_US.properties"     check_MSG_key
run MSG-args      "message names subject/dest/type/loctype/remedy"     check_MSG_actionable
echo

phase 1
echo "-- Phase 1-API — resolver / validator / audit / metrics ----------------------"
run R-exists      "PutawayDestinationResolver exists"                  check_R_exists
run R-service     "annotated @Service"                                 check_R_service
run R-sources     "all four Source enum constants present"             check_R_four_sources
run R-sig         "resolve(Itemdata, Client, Long) signature"          check_R_resolve_signature
run R-tm          "uses tenantTransactionManager"                      check_R_tenant_tm
run R-mandatory   "Propagation.MANDATORY (forbids a new tx)"           check_R_mandatory
run R-noreqnew    "NEG: no Propagation.REQUIRES_NEW (deadlock class)"  check_R_no_requires_new
run R-noro        "NEG: not readOnly=true (landmine A1)"               check_R_not_readonly
run R-nogsd       "NEG: never calls getStringDefault (A1 auto-INSERT)" check_R_no_getStringDefault
run R-nogsv       "NEG: never calls getSysvalue (A3 client-blind, A4)" check_R_no_getSysvalue
run R-tier3       "tier 3 via findBySyskeyAndClientIdAndWorkstation"   check_R_tier3_read_path
run R-tier3neg    "tier 3 does NOT use landmine-A6 findSysvalueBy..."  check_R_tier3_no_landmine
run R-tier3ws     "tier 3 pins workstation=DEFAULT"                    check_R_tier3_workstation_default
run R-blank       "blank-after-trim handled (landmine A2)"             check_R_blank_handled
run R-nullsku     "null Itemdata guarded (AdviceRestController:542)"   check_R_null_sku_guarded
run R-tier4       "tier 4 resolves PutAwayLane by name"                check_R_tier4_by_name
run R-bex         "failures are BusinessException"                     check_R_business_exception
run R-noraw       "NEG: no bare RuntimeException thrown"               check_R_no_raw_runtime
run V-exists      "PutawayDestinationValidator exists"                 check_V_exists
run V-p1          "validator reuses predicate P1"                      check_V_uses_p1
run V-goodsin     "P2.4 checks useforgoodsin"                          check_V_goodsin_or_storage
run V-storage     "P2.4 checks useforstorage too (OR, not AND)"        check_V_storage_too
run V-lanes       "P2.3 checks the lane flags"                         check_V_lane_flags
run V-fixmismatch "P2.7(f) fix-assignment reject is MISMATCH-scoped, not absolute" check_V_fixloc_reject_is_mismatch_scoped
run V-ruleEscope  "P2.7(e) reject is SCOPE-GUARDED, not absolute"        check_V_rule_e_scope_guarded
run T-skupick     "test: SKU-scope write PERMITS a pick-face destination"   check_T_sku_pickface_test
run T-merchpick   "test: merchant-scope write PERMITS a pick-face destination" check_T_merch_pickface_test
run T-stagingok   "test: merchant-scope write PERMITS a staging lane (P2.7a)" check_T_staging_ok_test
run V-noflowbin23 "P2.7(e): validator keys on sltname (not the area flag)" check_V_no_flowbin_tier23
run T-mflowbin    "test: merchant write REJECTS a flowbin destination"  check_T_merch_flowbin_reject
run V-flowbin1ok  "test: SKU write PERMITS a flowbin destination"       check_T_sku_flowbin_ok
run T-mclubok     "test: merchant write PERMITS cases-and-pallets"      check_T_merch_casespallets_ok
run T-fFgn        "test: rule (f) rejects a flowbin bound to ANOTHER sku"  check_T_rule_f_foreign_flowbin
run T-fOwn        "test: rule (f) rejects a sku that owns another face"    check_T_rule_f_sku_owns_other
run T-fOwnOk      "test: rule (f) PERMITS a sku's own fix-assigned face"   check_T_rule_f_own_pickface_ok
run V-lock        "P2.2 checks NOT_LOCKED"                             check_V_entity_lock
run V-negq        "NEG: not built on getStorageLocationsForPutAwayItemData" check_V_not_storage_query
runp 1 A-exists      "PutawayConfigAuditService exists"                   check_A_exists
runp 1 A-mandatory   "audit writer is Propagation.MANDATORY"              check_A_mandatory
runp 1 A-tm          "audit writer uses tenantTransactionManager"         check_A_tenant_tm
runp 1 A-user        "records SecurityContextUtils.getUserName()"         check_A_username
runp 1 A-channel     "records the write channel (typed vs hal)"           check_A_channel
run MT-exists     "PutawayResolutionMetrics exists"                    check_MT_exists
run MT-registry   "holds a MeterRegistry"                              check_MT_registry
run MT-res        "wms2.putaway.resolution counter"                    check_MT_resolution
run MT-rej        "wms2.putaway.resolution.rejected counter"           check_MT_rejected
run MT-crej       "wms2.putaway.config.rejected counter"               check_MT_cfg_rejected
run MT-cchg       "wms2.putaway.config.changed counter"                check_MT_cfg_changed
run MT-tag        "'source' tag present (pre-mortem P2 detector)"      check_MT_source_tag
echo

phase 1
echo "-- Phase 1-API — config-write services & cache -------------------------------"
run C-exists      "PutawayConfigService exists"                        check_C_exists
runp 1 C-writers     "three writers: sku / merchant / warehouse"          check_C_three_writers
run C-tm          "tenantTransactionManager on all three"              check_C_tenant_tm
run C-rollback    "rollbackFor = {BusinessException, FacadeException}"  check_C_rollback_for
run C-validate    "invokes the validator"                              check_C_validates
runp 1 C-audit       "invokes the audit writer"                           check_C_audits
run C-metrics     "invokes the metrics holder"                         check_C_metrics
run C-evictid     "@CacheEvict on itemdata"                            check_C_evict_itemdata
run C-evictid2    "itemdata eviction covers BOTH keys"                 check_C_evict_itemdata_2keys
runp 1 C-evictcl     "clients eviction covers BOTH keys"                  check_C_evict_clients
run C-evictsp     "sysprops eviction present"                          check_C_evict_sysprops
run C-noall       "NEG: no allEntries=true (cross-tenant flush)"       check_C_no_all_entries
run C-nodel       "NEG: warehouse clear is UPDATE '', not DELETE"      check_C_no_sysprop_delete
run IDS-nowrite   "ItemdataService has NO putaway write (SBDEV-3017)"    check_IDS_no_putaway_write
run IDCTL-nowrite "ItemDataController has NO putaway write (SBDEV-3017)"  check_IDCTL_no_putaway_write
run IDCTL-neg1    "NEG: allEntries=true removed from ItemDataController" check_IDCTL_all_entries_gone
run IDCTL-neg2    "NEG: raw unvalidated save removed"                  check_IDCTL_raw_save_gone
echo

phase 1
echo "-- Phase 1-API — stop seeding the PutAwayLane id (4 sites) -------------------"
run S1-neg1       "NEG: SkuRestController defaultPutawayLocationId gone" check_S1_lane_lookup_gone
run S1-neg2       "NEG: SkuRestController lane findByName gone"        check_S1_findByName_gone
run S2-neg1       "NEG: SkuBatchCreateUpdateService parameter gone"    check_S2_param_gone
run S2-neg2       "NEG: SkuBatchCreateUpdateService setter gone"       check_S2_setter_gone
run S3-neg1       "NEG: FileImportController setter gone"              check_S3_setter_gone
runp all S3-pos1       "SBDEV-2037 lane-presence guard retained"            check_S3_guard_kept
runp all S3-pos2       "SBDEV-2037 guard error message retained"            check_S3_guard_error_kept
echo

phase 1
echo "-- Phase 1-API — receiving wiring --------------------------------------------"
run W-call        "ReceivingService calls the resolver"                check_W_resolver_called
run W-nocgrd      "NEG: resolution NOT inside if(carrier==null) [2731]" check_W_resolve_not_carrier_guarded
run W-rqcgrd      "hard-fail IS inside if(carrier==null) [C4/D10]"     check_W_requirecompatible_carrier_guarded
run W-metrics     "ReceivingService records the resolution metric"     check_W_metrics_called
run W-neg1        "NEG: carrier-only ternary gone (SBDEV-2731 cause)"  check_W_ternary_gone
run W-neg2        "NEG: old putAwayLocation variable gone"             check_W_old_var_gone
run W-uses        "placement uses putaway.location() AND is gated"    check_W_uses_resolution
run W-gate        "(iv-b) gate reads useforpicking AND sltname"        check_W_pickface_gate
run V-p1skip      "P1 skipped for pick-face destinations at write time" check_V_p1_skipped_for_pickface
run W-gatenear    "gate sits NEAR the placement, not just in the file"  check_W_gate_near_placement
run W-gateord     "gate runs BEFORE requireCompatible (P1 vs the lane)" check_W_gate_before_requirecompatible
run W-gateloc     "NEG: gate in ReceivingService, NOT the controller"   check_W_gate_not_in_controller
run T-pickface    "test: pick-face destination NOT placed at receipt"   check_T_pickface_not_placed
run T-stgplaced   "test: staging-lane destination IS placed at receipt" check_T_staging_is_placed
run W-hoist       "resolution stays hoisted above the per-case loop"   check_W_hoisted_above_loop
runp all W-onetx       "receiveGoods still one tenant transaction"          check_W_one_tx
run W-endpoint    "getPutawayDestination endpoint added"               check_W_endpoint
run W-neg3        "NEG: raw pallet-location literal set gone"          check_W_literals_gone
run W-const       "constants used at ReceivingController:314"          check_W_constants_used
runp all W-2102        "SBDEV-2102 storePalletBackOnPutawayLane preserved"  check_W_sbdev2102_kept
runp all W-neg4        "NEG: resolver NOT wired inside transferUnitLoadToLocation (24 call sites)" check_W_not_in_transfer
echo

phase 1
echo "-- Phase 1-API — Spring Data REST write hole & permissions -------------------"
run H-exists      "PutawayConfigRepositoryEventHandler exists"         check_H_exists
run H-ann         "@RepositoryEventHandler present"                    check_H_annotation
run H-comp        "@Component (auto-registration)"                     check_H_component
run H-bc          "@HandleBeforeCreate present"                        check_H_before_create
run H-bs          "@HandleBeforeSave present"                          check_H_before_save
run H-id          "guards Itemdata HAL writes"                         check_H_itemdata
run H-delta       "handler validates the DELTA not the state [regression]" check_H_delta_not_state
runp 1 H-cl      "guards Client HAL writes [O2: 1b only]"                           check_H_client
run H-sp          "guards Sysprop HAL writes (deviation A1)"           check_H_sysprop
run H-key         "Sysprop handler keys on DEFAULT_PUTAWAY_LOCATION"   check_H_syskey_guarded
run H-deleg       "delegates so @CacheEvict applies"                   check_H_delegates
run H-prevsvc     "previous-value read lives in PutawayConfigService"   check_H_prev_read_in_service
run H-prevlist    "previous-value read uses getResultList"             check_H_prev_read_getresultlist
run H-prevneg     "NEG: no getSingleResult (C3 NoResultException)"     check_H_no_getsingleresult
run H-split       "NEG: create/save handlers are SEPARATE [C3]"        check_H_create_save_split
run H-after       "@HandleAfterSave present (audit after commit) [N-2]" check_H_after_handlers
run H-unchecked   "handler throws unchecked PutawayConfigValidationEx" check_H_unchecked_exception
run H-nochecked   "NEG: handler declares no 'throws BusinessException'" check_H_no_checked_throws
run CTL-exists    "PutawayConfigController exists [N-3]"               check_CTL_exists
run CTL-preview   "preview endpoint (D11 count + config health)"       check_CTL_preview
run CTL-confirm   "confirmIncompatibleSkus param exists [D11/R-5]"     check_CTL_confirm_param
runp 1 N2-facade "readOnly tenant-tx query facade exists [C1/X4]"     check_N2_readonly_facade
runp 1 NOSTUB     "NEG: no gate scaffolding left in any putaway class"  check_NOSTUB_putaway
runp 1 N2-resolve "facade actually calls resolve() [not a stub]"        check_N2_facade_resolves
runp 1 N2-both    "facade covers advice-position AND client entry"      check_N2_facade_both
runp 1 N9-ep      "GET /client/{id}/effectivePutawayDestination [N9]"   check_N9_endpoint
runp 1 N9-facade  "N9 goes through the facade"                          check_N9_uses_facade
runp 1 N9-nores   "NEG: ClientController never calls the resolver [C1]" check_N9_no_resolver
runp 1 CTL-pvcnt  "preview computes the D11 counts, not just a route"   check_CTL_preview_counts
runp 1 N1-create  "SystemPropertyController.create rejects the key"     check_N1_syspropctl_create_guard
runp 1 N1-update  "SystemPropertyController.updateValue rejects it"     check_N1_syspropctl_updatevalue_guard
runp 1 N1-del     "@HandleAfterDelete audits the cleared key [D12]"     check_N1_sysprop_delete_handler
runp 1 N1-d12     "setWarehouse re-creates a deleted row [D12 trap]"    check_N1_d12_recreates_row
runp 1 17a-wired  "putaway surfaces the four-tier destination [17a]"     check_17a_resolver_wired
runp 1 17a-neg    "NEG: putaway no longer reads the tier-1 column"       check_17a_not_tier1_column
runp 1 17a-lane   "tier 4 maps to null, lane is not a destination"       check_17a_lane_means_null
runp 1 SEC-gate   "putawayConfig requires wms_user, not just auth [SEC]"  check_SEC_putawayconfig_gated
runp 1 SEC-updcl  "updateClient rejects the guarded row [3rd save path]"  check_SEC_updateclient_guard
runp 1 EX-422     "PutawayConfigValidationException maps to 422 [N7a]"    check_H7a_422_handler
runp 1 H-sysprop  "@HandleBeforeCreate(Sysprop) closes POST /v3/sysprop"  check_H_sysprop_create_guard
runp 1 H-noadmin  "NEG: create path does not force sb_admin on all POSTs" check_H_create_early_return
runp 1 H-evict    "After phase reaches the EVICTING writers"              check_H_after_evicts
runp 1 CFG-evict  "per-scope evict variants + the :SYSTEM clients key"    check_CFG_evict_variants
runp 1 H-clr1st   "carrier clears BEFORE the no-delta early return"       check_H_carrier_clear_first
runp 1 H-tenant   "carrier key is tenant-scoped [cross-tenant audit]"     check_H_carrier_tenant_keyed
runp 1 N2-divert  "display reports the placement, not just the config"    check_N2_display_reports_divert
runp 1 N2-deleg  "NEG: ReceivingController delegates, never resolves"  check_N2_controller_delegates_not_resolves
runp 1 C-1awrit  "1a: setSku + setWarehouse writers exist"            check_C_1a_writers
runp 1 CTL-auth2 "1a: both writes carry @PreAuthorize [AC11]"         check_CTL_preauthorize_1a
runp 1 CTL-auth  "1b: all 3 writes carry @PreAuthorize [AC11]"        check_CTL_preauthorize
run CTL-svc       "controller delegates to PutawayConfigService"       check_CTL_calls_service
run CTL-noresolve "NEG: controller never calls the resolver [C1]"      check_CTL_no_direct_resolve
run H-auth        "handler enforces the admin authority"               check_H_preauthorize
run H-ctlauth     "typed config endpoint carries @PreAuthorize"        check_H_ctl_preauthorize
# PR #139 review round (2026-08-11). runp 1 explicitly: all three fixes are Phase 1-API, and O4's
# lesson is that section-inherited phase buckets have been wrong in both directions here.
runp 1 H-delauth  "DELETE of the guarded syskey is admin-gated [P1]"    check_H_delete_authorized
runp 1 CFG-delgate "the gate is @PreAuthorize'd on the proxied @Service" check_CFG_delete_gate_annotated
runp 1 H-delorder "gate runs BEFORE the carrier is stashed [P1]"        check_H_delete_gate_first
runp 1 H-delneg   "NEG: delete NOT routed through validateOnly [§3.9.3]" check_H_delete_not_via_validateonly
runp 1 CFG-halabs "HAL enforces D11's ABSOLUTE reject at tiers 2/3 [P2]" check_CFG_hal_absolute_reject
runp 1 CFG-halnew "merchant CREATE never widens to a tenant-wide scan"   check_CFG_hal_no_tenant_wide_merchant
runp 1 CFG-halpart "NEG: PARTIAL incompatibility still permitted on HAL" check_CFG_hal_partial_still_allowed
runp 1 CTL-tx     "typed writers recompute+write in ONE tenant tx [P2]"  check_CTL_writers_transactional
runp 1 T-review   "all three review fixes are asserted as tests"         check_T_review_round_tested
echo

phase 1
echo "-- Phase 1-API — tests ------------------------------------------------------"
run T-res         "PutawayDestinationResolverUnitTest exists"          check_T_resolver_test
run T-cfg         "PutawayConfigServiceUnitTest exists"                check_T_cfg_test
run T-hnd         "PutawayConfigRepositoryEventHandlerUnitTest exists" check_T_handler_test
run T-ctx         "PutawayResolverContextLoadTest exists (DI gate)"    check_T_ctx_test
run T-ctxdis      "context-load test tagged TODO(SBDEV-2217)"          check_T_ctx_disabled
run T-ctxwire     "context-load test autowires the resolver"           check_T_ctx_autowires
run T-lm1         "landmine A1 asserted as a test"                     check_T_no_getstringdefault_asserted
run T-lm2         "null-SKU path asserted as a test"                   check_T_null_sku_asserted
run T-lm3         "empty-constraint fail-open asserted as a test"      check_T_fail_open_asserted
run T-msg1        "NEG: old raw-ID message assertion removed"          check_T_old_message_assertion_gone
run T-msg2        "new message asserted (tightened, not loosened)"     check_T_new_message_asserted
echo

# === STEP 18a — the API half of Phase 2 (added by the TDD gate 2026-08-11) ====================
#
# GATED HERE: deliverables 3 + 4 only (§3.11.0's eligibleLocations read, §3.11.0a's BlockingReason
# extension). Their contract is DERIVED from the merged validator's SEVEN rejection keys -- the
# validator has 9 throw sites carrying 8 distinct keys, and the 8th (entityNotFoundForId) is a
# not-found error rather than an eligibility rejection. The plan's §3.11.0a says "six" because it
# merges locked + isALane into one table row; counted from the validator, not the plan. A review
# lane has little room to reshape this.
#
# DELIBERATELY ABSENT — do not add without a review pass: P2-rules-pure, P2-validator-facade,
# P2-validator-tests-intact, P2-eligible-bulk. Those four gate the PutawayDestinationRules
# extraction and the refactor of the MERGED, live PutawayDestinationValidator. §11.1a of the plan
# lists them; this script deliberately does not yet assert them, and that gap is recorded rather
# than hidden — a row that silently does not exist is how a phase reads as done when it is not.
# === STEP A (§3.11.0.1) — REWRITTEN 2026-08-11 =================================================
#
# The five superseded P2-eligible-* rows asserted an UNPAGINATED endpoint hosted ON THE CONTROLLER.
# Step A puts the read on PutawayDestinationQueryService with a Pageable, so those rows would have
# FAILED a correct implementation -- the third time this plan wrote a row that fails correct code.
# They are replaced, not edited, and the ids change so a stale reference cannot resolve.
check_P2A_svc_method() {
    file_contains_multiline 'Page<EligibleLocation>\s+eligibleLocations\s*\(' "$QSVC"
}
check_P2A_pageable() {
    file_contains_multiline 'eligibleLocations\s*\([^)]*Pageable' "$QSVC"
}
# The boundary belongs on the query service: one snapshot across the tables, readOnly skips
# Hibernate's dirty-check per entity, and open-in-view=false makes a transaction mandatory.
# ⚠ ADJACENCY, not proximity. The first form used a {0,400} window and FALSE-PASSED: it matched a
# DIFFERENT method's annotation followed by the word "eligibleLocations" inside a javadoc, against a
# stub carrying no @Transactional whatsoever. A window is a guess about layout; require the annotation
# to immediately precede the signature.
check_P2A_svc_tx() {
    file_contains_multiline '@Transactional\([^)]*tenantTransactionManager[^)]*readOnly\s*=\s*true[^)]*\)\s*public\s+Page<EligibleLocation>\s+eligibleLocations' "$QSVC"
}
# NEGATIVE, non-vacuous: require the controller to EXPOSE the endpoint, then require it NOT to own the
# transaction. A bare "no @Transactional near eligibleLocations" passes trivially before the mapping exists.
check_P2A_ctl_exposes_no_tx() {
    file_contains '@GetMapping\("/eligibleLocations"\)' "$CFGCTL" \
      && ! file_contains_multiline '@GetMapping\("/eligibleLocations"\)[\s\S]{0,300}?@Transactional' "$CFGCTL"
}
# ⚠ Prose-satisfiable in its first form -- the stub's own javadoc names the constant, so a bare grep
# passed with zero code referencing it. Same defect as P2-br-7 had. Require the constant to be PASSED
# to the candidate query, which a comment cannot satisfy.
check_P2A_lane_by_name() {
    file_contains_multiline 'findPutawayCandidates\(\s*WmsConstants\.STORAGE_LOCATION_PUTAWAY_LANE' "$QSVC" \
      && file_not_contains "'Put Away Lane'" "$QSVC"
}
# LEFT, not INNER: an inner join makes an area-less location VANISH instead of appearing as
# ineligible, and §3.11.0.1 requires ineligible rows to be returned with a reason.
check_P2A_left_join() {
    file_contains_multiline 'findPutawayCandidates' "$LREPO" \
      && file_contains_multiline 'LEFT JOIN LocationArea' "$LREPO"
}
# H2 lane: JPQL only. Every other query in LocationRepository is nativeQuery = true and Postgres-shaped.
check_P2A_h2() {
    file_contains_multiline 'findPutawayCandidates' "$LREPO" \
      && ! file_contains_multiline 'findPutawayCandidates[\s\S]{0,200}?nativeQuery' "$LREPO" \
      && file_not_contains '::bigint' "$QSVC"
}
# ONE authority for P2. The service must DELEGATE to the validator, never re-derive the predicates --
# the hazard PutawayConfigController's own comment names.
check_P2A_delegates_to_validator() {
    file_contains 'putawayDestinationValidator\.validate\(' "$QSVC"
}
check_P2A_neg_no_p2_copy() {
    file_contains 'eligibleLocations' "$QSVC" \
      && file_not_contains 'getStaginglane\(|getTransferlane\(|getUseforgoodsin\(\s*\)\s*&&|getEntityLock\(' "$QSVC"
}

check_P2_blockingreason_7() {
    # ⚠ REPOINTED 2026-08-11: the enum MOVED from PutawayConfigController to service/BlockingReason.java.
    # Step A needed the same key->reason mapping, which forced either a service->controller import (a
    # layering inversion no other service in this repo has) or a second copy of the switch. Moving the
    # type removed the choice. The WIRE CONTRACT DID NOT MOVE -- Jackson serializes by name(), so the
    # JSON is byte-identical; only the Java home changed. Done while PR #141 was unmerged, when free.
    # No closing-brace anchor now: as a TOP-LEVEL enum the members sit at indent 4 and the brace at 0,
    # so the previous '\n    \}' anchor would never match -- and the constants are the claim anyway.
    file_contains_multiline 'enum +BlockingReason +\{[\s\S]*?BOUND_TO_ANOTHER_SKU' "$BRENUM" \
      && file_contains_multiline 'enum +BlockingReason +\{[\s\S]*?AREA_NOT_USABLE' "$BRENUM" \
      && file_contains_multiline 'enum +BlockingReason +\{[\s\S]*?FLOWBIN_SCOPE' "$BRENUM" \
      && file_contains_multiline 'enum +BlockingReason +\{[\s\S]*?TYPE_INCOMPATIBLE' "$BRENUM" \
      && file_not_contains 'enum +BlockingReason' "$CFGCTL"
}
# All SEVEN validator REJECTION keys must be mapped (not six -- see the note above). The two
# rule-(f) keys must NOT still land on the generic FIX_ASSIGNED -- that is the mapping SBDEV-2643
# MUST-4 needs split.
# ⚠ TIGHTENED 2026-08-11 after code review (MEDIUM-3), twice over:
#   (i) the three bare key names are also prose-satisfiable -- anchored to `case "<key>":` instead;
#   (ii) only ONE of the two rule-(f) directions was asserted, so re-mapping
#        putawayDestinationBoundToAnotherSku while leaving skuAlreadyBoundToAnotherPickFace on
#        FIX_ASSIGNED would have passed. Both directions are now required.
# ⚠ REPOINTED with the enum -- the mapper moved too, as BlockingReason.forKey(String), so the enum owns
# its own key mapping and the controller and step A's read consume ONE authority instead of two copies.
check_P2_blockingreason_map() {
    file_contains 'case +"putawayDestinationAreaNotUsable":' "$BRENUM" \
      && file_contains 'case +"putawayDestinationFlowbinNotAllowedForScope":' "$BRENUM" \
      && file_contains 'case +"putawayDestinationTypeIncompatible":' "$BRENUM" \
      && file_contains_multiline 'case +"putawayDestinationBoundToAnotherSku":[^;]*BOUND_TO_ANOTHER_SKU' "$BRENUM" \
      && file_contains_multiline 'case +"skuAlreadyBoundToAnotherPickFace":[^;]*BOUND_TO_ANOTHER_SKU' "$BRENUM" \
      && file_contains 'BlockingReason\.forKey\(' "$CFGCTL"
}

# === STEP B (§3.11.0.2) — the characterization guard that step C requires ======================
#
# The plan cited PutawayDestinationValidatorUnitTest as step C's behaviour-preservation guard THREE
# times, including a row asserting byte-identity to 889298d. The file had never existed in any commit.
# These rows assert the guard is real, covers the whole predicate chain, and pins the two things a
# refactor is most likely to change silently: message ARGUMENTS and predicate ORDER.
#
# ⚠ Byte-identity is deliberately NOT asserted yet. It can only be anchored to the commit that writes
# the test, and the honest version of that row belongs to whoever starts step C -- pinning it here would
# freeze a file nobody has reviewed. What IS asserted is coverage, which is what makes it a guard.
check_P2B_guard_exists() { file_exists "$VTEST"; }

# All 8 keys the validator can throw. Enumerated, because the coverage this replaces reached 4 of 8.
check_P2B_all_keys() {
    file_contains 'entityNotFoundForId' "$VTEST" \
      && file_contains 'putawayDestinationLocked' "$VTEST" \
      && file_contains 'putawayDestinationIsALane' "$VTEST" \
      && file_contains 'putawayDestinationFlowbinNotAllowedForScope' "$VTEST" \
      && file_contains 'putawayDestinationAreaNotUsable' "$VTEST" \
      && file_contains 'putawayDestinationBoundToAnotherSku' "$VTEST" \
      && file_contains 'skuAlreadyBoundToAnotherPickFace' "$VTEST" \
      && file_contains 'putawayDestinationTypeIncompatible' "$VTEST"
}
# Predicate ORDER is behaviour: the live order is not the P2.x numbering, and blockingReason is
# wire-visible. 1,345 of 2,068 flowbins on wms2-wineco-dev fail two or more predicates.
check_P2B_precedence() { file_contains 'class Precedence' "$VTEST"; }
# getKey() alone cannot catch a dropped message argument -- resolveMessage swallows
# IllegalFormatException and degrades the 422 detail silently. The guard must assert getMessage too.
check_P2B_message_args() {
    file_contains 'getMessage\(\)' "$VTEST" && file_contains 'getKey\(\)' "$VTEST"
}
# The branches that were free to break silently before step B.
check_P2B_previously_uncovered() {
    file_contains 'crossdockinglane|setCrossdockinglane' "$VTEST" \
      && file_contains 'setGate' "$VTEST" \
      && file_contains 'setAutomationlane' "$VTEST" \
      && file_contains_i 'flowbin skip|skipped for a flowbin' "$VTEST"
}

# === STEP D (§3.11.0.3) — the scope-scan N+1 ====================================================
#
# ~8,800 queries on one ungated GET /preview?scope=WAREHOUSE: the callers looped validate() over every
# SKU in the tenant (8,804 on wms2-wineco-dev) and isUnitloadTypePermitted's derived query is not
# @Cacheable, so it re-executed per iteration. Fixed by evaluating once per distinct unit-load TYPE
# (measured: 1 distinct defultype_id on that tenant), NOT by extracting anything -- step D no longer
# depends on step C.
check_P2D_memoized() {
    # No proximity window: the gap between the signature and computeIfAbsent is 542 chars (measured),
    # and the first form used {0,200} -- a window is a guess about layout, and it false-FAILED the
    # correct implementation. Anchor on the two constructs that actually constitute the memo instead.
    file_contains 'incompatibilityTest\(' "$CFGSVC" \
      && file_contains 'Predicate<Itemdata>' "$CFGSVC" \
      && file_contains 'verdictByUnitloadType\.computeIfAbsent' "$CFGSVC"
}
# NEGATIVE: neither caller may still call validate() directly inside its loop -- that is the N+1.
check_P2D_neg_no_per_sku_validate() {
    file_contains 'incompatibilityTest\(' "$CFGSVC" \
      && file_not_contains_multiline 'for \(Itemdata sku : skus\) \{[\s\S]{0,120}?putawayDestinationValidator\.validate\(' "$CFGSVC"
}
# SKU scope must NOT group: there the verdict is genuinely per-SKU (rule (f)) and the population is one.
check_P2D_sku_scope_ungrouped() {
    file_contains_multiline 'if \(scope == PutawayScope\.SKU\) \{[\s\S]{0,160}?isCompatible\(' "$CFGSVC"
}
# The validator stays the ONE authority -- the fix memoizes its verdict, it does not reimplement it.
check_P2D_validator_still_authority() {
    file_contains 'putawayDestinationValidator\.validate\(' "$CFGSVC"
}

# === STEP C (§3.11.0.4) — the extraction ========================================================
check_P2C_rules_exists()   { file_exists "$RULES"; }
# Purity is pinned by an ArchUnit rule, NOT by this grep -- a textual check cannot see a transitive
# dependency, and the rule asserts the class EXISTS first so it cannot pass vacuously.
check_P2C_purity_archtest() { file_exists "$PURITY" && file_contains 'noClasses\(\)' "$PURITY"; }
# ⚠ code_only, not raw text. The first form false-FAILED the correct implementation: the class's own
# javadoc says "no repositories, no @Transactional", and a raw grep cannot tell a promise from a
# violation. That is the FOURTH time a row in this file has been satisfied-or-broken by prose (P2-br-7,
# P2A-lane-name, NOSTUB, and now this). Any row asserting the ABSENCE of a symbol must strip comments.
check_P2C_rules_pure() {
    file_exists "$RULES" \
      && ! code_only < "$RULES" | grep -qE '^import net\.aim_ai\.wms\.repo' \
      && ! code_only < "$RULES" | grep -qE '@Transactional'
}
# An injected @Service, not a static utility: the next requirement here is a sysprop or a metric, and
# PutawayDestinationResolver already establishes the injected-collaborator pattern for exactly that.
check_P2C_rules_is_bean() {
    file_contains '@Service' "$RULES" && file_not_contains 'public static Verdict evaluate' "$RULES"
}
# The order is behaviour: blockingReason is wire-visible and multi-failure is the majority path at SKU
# scope. An ordered list also keeps a collecting fold (all reasons) addable without a rewrite.
check_P2C_ordered_chain()  { file_contains_multiline 'List<Rule> CHAIN = List\.of\(' "$RULES"; }
# List<Object>, never Object[] -- a record with an array field gets identity equals, so the obvious
# assertion fails against a correct implementation. Three such gates have already been written here.
check_P2C_verdict_list()   { file_contains 'List<Object> args' "$RULES"; }
# The facade loads, delegates and throws. P2.1 stays there (Ctx presupposes a resolved Location), so it
# keeps exactly ONE literal key -- any other means a predicate moved back in, unseen by the derivation.
check_P2C_facade_delegates() {
    file_contains 'putawayDestinationRules\.evaluate\(' "$VALIDATOR" \
      && file_contains_exactly_n 'new BusinessException\("' "$VALIDATOR" 1
}
# The seam the extraction created is tested DIRECTLY -- mutation testing found two behaviours that the
# facade masks (the P2.6 flowbin skip and rule (f)'s isFlowbin gate) and that step B cannot reach.
check_P2C_seam_tested() {
    file_exists "$RULESTEST" \
      && file_contains_i 'flowbinSkipIsEnforcedByTheEvaluatorItself' "$RULESTEST" \
      && file_contains_i 'ruleFDirectionOneIsGatedOnFlowbinByTheEvaluatorItself' "$RULESTEST"
}

phase 1
echo "-- Phase 2 step C — the extracted pure evaluator ----------------------------"
run P2C-exists            "step C: PutawayDestinationRules exists"               check_P2C_rules_exists
run P2C-purity-arch       "step C: purity pinned by an ArchUnit rule"            check_P2C_purity_archtest
run P2C-pure              "NEG: no repo import, no @Transactional"               check_P2C_rules_pure
run P2C-bean              "step C: an injected @Service, not a static utility"    check_P2C_rules_is_bean
run P2C-ordered           "step C: the chain is an ORDERED list"                  check_P2C_ordered_chain
run P2C-verdict-list      "step C: Verdict.args is a List, not an Object[]"       check_P2C_verdict_list
run P2C-facade            "step C: facade delegates; keeps only P2.1's key"       check_P2C_facade_delegates
run P2C-seam-tested       "step C: the new seam is tested directly"               check_P2C_seam_tested
echo

phase 1
echo "-- Phase 2 step D — the scope-scan N+1 -------------------------------------"
run P2D-memoized          "step D: verdict memoized per unit-load type"          check_P2D_memoized
run P2D-neg-per-sku       "NEG: no validate() left inside a per-SKU loop"        check_P2D_neg_no_per_sku_validate
run P2D-sku-ungrouped     "step D: SKU scope deliberately NOT grouped"           check_P2D_sku_scope_ungrouped
run P2D-authority         "step D: validator remains the ONE authority"          check_P2D_validator_still_authority
echo

phase 1
echo "-- Phase 2 step B — the validator characterization guard --------------------"
run P2B-exists            "step B: PutawayDestinationValidatorUnitTest EXISTS"   check_P2B_guard_exists
run P2B-all-keys          "step B: all 8 validator throw keys asserted"          check_P2B_all_keys
run P2B-precedence        "step B: multi-failure PRECEDENCE pinned"              check_P2B_precedence
run P2B-message-args      "step B: asserts getMessage(), not only getKey()"      check_P2B_message_args
run P2B-uncovered         "step B: the 4-of-8 coverage gaps are closed"          check_P2B_previously_uncovered
echo

phase 2
echo "-- Phase 2 step 18a — the API half (eligibleLocations + BlockingReason) ----"
run P2A-svc-method        "step A: Page<EligibleLocation> on the QUERY SERVICE"  check_P2A_svc_method
run P2A-pageable          "step A: takes a Pageable (bounded, not whole-tenant)" check_P2A_pageable
run P2A-svc-tx            "step A: readOnly tenant tx on the service method"    check_P2A_svc_tx
run P2A-ctl-no-tx         "NEG: controller exposes it but owns NO transaction"  check_P2A_ctl_exposes_no_tx
run P2A-lane-name         "step A: tier-4 lane excluded by the NAME constant"   check_P2A_lane_by_name
run P2A-left-join         "step A: LEFT JOIN so area-less rows stay visible"    check_P2A_left_join
run P2A-h2                "NEG: JPQL not native; H2 lane stays green"           check_P2A_h2
run P2A-validator         "step A: delegates to validate() — ONE authority"     check_P2A_delegates_to_validator
run P2A-neg-p2copy        "NEG: no second copy of P2 in the service"            check_P2A_neg_no_p2_copy
run P2-br-7               "BlockingReason gains the 4 new values"              check_P2_blockingreason_7
run P2-br-map             "5 case arms incl. BOTH rule-(f) dirs (test pins the rest)" check_P2_blockingreason_map
run P2-diverted-argorder  "diversion copy args are lane-first, and a test pins it" check_P2_diverted_argorder
echo

phase 2
echo "-- Phase 2-UI — web UI ------------------------------------------------------"
# UN-SKIPPED 2026-08-07: SBDEV-2731 PR1 merged (api 6bc709a / ui 4ce39a1), so the checks it owned
# now run against real merged code instead of being deferred to it.
run U-neg1        "NEG: no inline 'Put Away Lane' literal in template"  check_U_hardcoded_gone
run U-bind        "receivingForm binds putawayStaging"                  check_U_binds_staging
# CORRECTED 2026-08-02: previously skipped as "SBDEV-2731 PR1 owns this (D12)".
# It does not — 2731 PR1 ships a BINARY "(SKU override)" marker off a string compare,
# not a four-tier source. The sourceLabel chip is this plan's own 1a-UI work (§3.11.1).
run U-source      "receivingForm shows the setting source"             check_U_shows_source
run U-diverted    "receivingForm renders divertedTo AND divertedReason"  check_U_diverted
run U-degraded    "F3: a failed read renders UNCONFIRMED, not confirmed"  check_U_degraded_unconfirmed
run U-tristate    "PRESERVE 2731 tri-state: '=== false', never '!'"    check_U_tristate_kept
run U-picker      "LocationPicker.vue exists"                          check_U_picker_exists
run U-negq        "NEG: picker not built on useforstorage-only query"  check_U_picker_not_storage_query
# ⚠ RENAMED 2026-08-11 to the ids §11.1a actually names. The plan's acceptance table cites SEVEN UI
# rows that did not exist in this script at all -- U-picker-source, U-neg-detailview,
# U-neg-flags-in-js, U-picker-tier, U-warehouse-typed (step 20) and U-neg-shipper-patch,
# U-merchant-inherited (step 21). An acceptance criterion with no row is not a criterion, and a row
# whose id the plan never mentions is invisible to anyone reading the plan. Steps 19/20 close five.
run U-picker-tier "picker keys on the SERVER's tier field"             check_U19_tier_from_server
run U-neg-flags-in-js "NEG: no client-side predicate-flag test"        check_U19_no_client_flag_test
run U19-nofetch   "NEG: picker never fetches — caller supplies items"  check_U19_no_fetch
run U19-fields    "item-text=locationName / item-value=locationId"     check_U19_item_fields
run U19-eligible  "ineligible rows never offered (no third state)"     check_U19_eligible_absolute
run U19-warn      "advanced tier carries the deadlock lock warning"    check_U19_advanced_warning
run U19-selrow    "@select emits the resolved ROW, not the id"         check_U19_select_emits_row
run U19-saved     "a saved ADVANCED value stays visible"               check_U19_selected_row_visible
run U19-spec      "locationPicker.spec.js covers the contract"         check_U19_spec_covers_contract

# --- step 20 (§3.11.2)
run U-warehouse-typed "the typed write, NOT the generic sysprop actions"  check_U_warehouse_typed
run U-picker-source "picker items come from /putawayConfig/eligibleLocations" check_U_picker_source
run U-neg-detailview "NEG: no putaway surface touches /location/detailView" check_U_neg_detailview
run U20-paging    "the paginated read is ACCUMULATED across pages"      check_U20_paging_accumulated
run U20-preview   "preview gate; blockingReason disables Save"          check_U20_preview_gate
run U20-d11       "D11 confirm carries the exact incompatible count"    check_U20_d11_confirm
run U20-uncond    "the control renders with NO sysprop row present"     check_U20_unconditional
run U20-syskey    "the syskey literal has ONE home"                     check_U20_syskey_single_source
run U20-specs     "the three step-20 specs exist"                       check_U20_specs_exist

# --- step 21 (§3.11.3)
run U-neg-shipper-patch "NEG: putaway field never rides the client PATCH"  check_U_neg_shipper_patch
run U-merchant-inherited 'the 3-state control binds the inherited flag'  check_U_merchant_inherited
run U21-readsrc   "merchant value read from effectivePutawayDestination"  check_U21_merchant_read_source
run U21-typed     "merchant write is the typed endpoint, picked by scope" check_U21_merchant_typed_write
run U21-specs     "the two step-21 specs exist"                          check_U21_specs_exist

# --- review round (PRs #42-#45), 2026-08-11
run RV-gate-api   "the gate mirrors the API's role harvesting"           check_RV_gate_mirrors_api
run RV-gate-neg   "NEG: no hasResourceRole / build-wide clientId"        check_RV_gate_no_client_lookup
run RV-gate-react "the gate is REACTIVE, resolved after kc.ready"        check_RV_gate_reactive
run RV-subject    "switching subject resets selection+preview+dialog"    check_RV_subject_reset
run RV-writeerr   "the server's 409/422 message reaches the operator"    check_RV_write_error_surfaced
run RV-partial    "a truncated candidate read is stated as such"         check_RV_partial_read
run RV-confirm    "Save anyway cannot double-submit"                     check_RV_confirm_guard
run RV-repreview  "the count is re-read after a successful write"        check_RV_repreview
run RV-persist    "the whole admin.configuration sub-tree is excluded"   check_RV_persist_subtree
run RV-specs      "the review-round regression specs exist"             check_RV_specs_exist

# --- step 22 (§3.11.4 + config health)
run U22-persistreg "REGRESSION: root exclusions + vuex-web key survive"   check_U22_persist_regression
run U22-health    "invalid EXISTING config is surfaced, by name+reason"   check_U22_config_health
run U22-allrows   "the unfiltered candidate set is retained"             check_U22_keeps_unfiltered_rows
run U22-guards    "no false alarm when unset or still loading"           check_U22_health_guards
run U22-specs     "the two step-22 specs exist"                          check_U22_specs_exist
run U-param       "Operation Options dialog has the syskey branch"     check_U_param_branch
run U-shipper     "editShipper carries defaultputawaylocationId"       check_U_shipper_field
run U-persist     "persistedState excludes the putaway config keys"    check_U_persist_excluded
echo

phase all
echo "-- Targeted JUnit runs (RUN_MVN=1 to enable) ------------------------------"
# Whole classes only — `-Dtest='Outer#method'` silently no-ops on @Nested.
# NOTE: 2 of 4442 tests already FAIL on clean develop (OptionalSafetyArchTest,
# MobilePalletizingServiceTest). Do not attribute them to this change.
# NOTE: `mvn test` MUTATES the tracked archunit_store — `git checkout` it after.
if [ "$RUN_MVN" = "1" ]; then
    run MVN-res   "PutawayDestinationResolverUnitTest passes"          mvn_test_passes PutawayDestinationResolverUnitTest
    run MVN-cfg   "PutawayConfigServiceUnitTest passes"                mvn_test_passes PutawayConfigServiceUnitTest
    run MVN-hnd   "PutawayConfigRepositoryEventHandlerUnitTest passes" mvn_test_passes PutawayConfigRepositoryEventHandlerUnitTest
    run MVN-lc    "LocationConstraintServiceUnitTest passes"           mvn_test_passes LocationConstraintServiceUnitTest
    run MVN-ubs   "UnitloadBusinessServiceUnitTest passes"             mvn_test_passes UnitloadBusinessServiceUnitTest
    run MVN-rec   "ReceivingServiceUnitTest passes"                    mvn_test_passes ReceivingServiceUnitTest
    run MVN-recc  "ReceivingControllerUnitTest passes"                 mvn_test_passes ReceivingControllerUnitTest
    run MVN-ids   "ItemdataServiceUnitTest passes"                     mvn_test_passes ItemdataServiceUnitTest
    run MVN-idc   "ItemDataControllerUnitTest passes"                  mvn_test_passes ItemDataControllerUnitTest
    run MVN-sku   "SkuRestControllerUnitTest passes"                   mvn_test_passes SkuRestControllerUnitTest
    run MVN-imp   "FileImportControllerUnitTest passes"                mvn_test_passes FileImportControllerUnitTest
    run MVN-ent   "EntityUnitTest passes"                              mvn_test_passes EntityUnitTest
    run MVN-cc    "CacheConfigTest passes"                             mvn_test_passes CacheConfigTest
    run MVN-tx    "TransactionManagerArchTest passes"                  mvn_test_passes TransactionManagerArchTest
else
    skip MVN-all  "targeted JUnit runs"                                "set RUN_MVN=1"
fi
echo

# FIXED 2026-08-09: VERIFY_COMPLETED was set ONLY in the PHASE=all branch, so every phase-scoped
# run printed the "ABORTED before completion" banner even after finishing cleanly -- useless noise in
# the one mode §11.2 gates on, and it trains the reader to ignore the banner that exists to be loud.
VERIFY_COMPLETED=1
if [ "$PHASE" = "all" ]; then
    echo "Result: $PASS pass, $FAIL fail, $SKIP skip   (PHASE=all)"
else
    echo "Result: $PASS pass, $FAIL fail, $SKIP skip, $FILTERED filtered out   (PHASE=$PHASE)"
    echo "  NOTE: $FILTERED checks belong to other phases and were not evaluated."
    echo "        A 0-fail here gates ONLY phase $PHASE — it is not whole-plan acceptance."
fi
echo
echo "Before accepting a 0-fail result, run the negative control:"
echo "  git stash && bash \$0 ; git stash pop     # MUST produce many FAIL lines"
echo

[ "$FAIL" -eq 0 ]
