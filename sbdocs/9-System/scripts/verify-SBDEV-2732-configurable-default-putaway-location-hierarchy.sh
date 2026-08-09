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
#       * migration renamed V2.2.10 -> V2.2.11 on 2026-08-06 — SBDEV-2854 (PR #132, open and pushed)
#         took V2.2.10 to keep the sequence contiguous. M-exists now looks for the V2.2.11 filename.
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
#    (/Users/np1076/dev/spk/owl/v1/wms-api). This plan targets v2/wms2-api on
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
#     PHASE=1 bash verify-SBDEV-2732-....sh     # Phase 1-API  (carries V2.2.11)
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
    mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}

# --- path shorthands --------------------------------------------------------

SRC=src/main/java/net/aim_ai/wms
TST=src/test/java/net/aim_ai/wms
MIG=src/main/resources/db/migration/V2.2.11__putaway_destination_hierarchy.sql
MSG=src/main/resources/messages_en_US.properties

RESOLVER=$SRC/service/PutawayDestinationResolver.java
CFGSVC=$SRC/service/PutawayConfigService.java
VALIDATOR=$SRC/service/PutawayDestinationValidator.java
VTEST=$TST/unit/service/PutawayDestinationValidatorUnitTest.java
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
QRYSVC=$SRC/service/PutawayDestinationQueryService.java

# ============================================================================
# PHASE 1-API — V2.2.11 migration (§3.2, §3.3, §3.4a, §3.14, §5.1)
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
check_R_no_getSysvalue()    { file_not_contains 'getSysvalue' "$RESOLVER"; }
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
check_V_goodsin_or_storage() { file_contains 'getUseforgoodsin' "$VALIDATOR"; }
check_V_storage_too()        { file_contains 'getUseforstorage' "$VALIDATOR"; }
# P2.3 lane flags
check_V_lane_flags()        { file_contains_multiline 'getStaginglane[\s\S]{0,400}getTransferlane' "$VALIDATOR"; }
check_V_entity_lock()       { file_contains 'NOT_LOCKED' "$VALIDATOR"; }
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
# NEG, conjoined so it cannot pass vacuously on a tree where the validator does not exist yet.
check_V_no_fixloc_absolute() {
    file_exists "$VALIDATOR" \
      && file_not_contains_multiline 'findByAssignedlocationId[\s\S]{0,400}(reject|throw|BusinessException|FIX_ASSIGNED)' "$VALIDATOR"
}
# NEG: the validator must not reject on useforpicking either — that predicate now lives in receiving.
check_V_no_pickface_reject() {
    file_exists "$VALIDATOR" \
      && file_not_contains_multiline 'getUseforpicking[\s\S]{0,400}(reject|throw|BusinessException|FIX_ASSIGNED)' "$VALIDATOR"
}
# INVERTED 2026-08-08 (iv-b): SKU scope now PERMITS a pick-face / fix-assigned destination.
# REPOINTED 2026-08-08. VTEST is PutawayDestinationValidatorUnitTest, which appears ZERO times in the
# plan — §7.1 puts every write-scope test in PutawayConfigServiceUnitTest. Three checks were pointing at
# a class nobody will create, so they could never go green. Defect pre-dated the (iv-b) edits.
CFGTEST=$TST/unit/service/PutawayConfigServiceUnitTest.java
check_T_sku_pickface_test() { file_contains_i 'skuWritePermitsPickFaceDestination' "$CFGTEST"; }
# INVERTED 2026-08-08 (iv-b): configuration is widened at ALL scopes, merchant included.
check_T_merch_pickface_test() { file_contains_i 'merchantWritePermitsPickFaceDestination' "$CFGTEST"; }
check_T_staging_ok_test()   { file_contains_i 'merchantWritePermitsStagingLane' "$CFGTEST"; }
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

check_IDS_delegates()       { file_contains 'putawayConfigService\.' "$IDSVC"; }
check_IDCTL_delegates()     { file_contains '(itemdataService\.setPutAwayLocation|putawayConfigService\.)' "$IDCTL"; }
# NEGATIVE: ItemDataController:80 allEntries=true (flushes ALL tenants) must be gone.
check_IDCTL_all_entries_gone() { file_not_contains 'allEntries *= *true' "$IDCTL"; }
# NEGATIVE: the raw unvalidated save at :88-90 must be gone.
check_IDCTL_raw_save_gone() { file_not_contains_multiline 'setPutawaylocationId\(locationId\);\s*\n\s*Itemdata newItemData = itemdataRepository\.save\(itemData\);' "$IDCTL"; }

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
check_W_pickface_gate()     { file_contains 'getUseforpicking' "$RECSVC"; }
# PROXIMITY: the gate must be near the placement, not merely somewhere in the file — a log line
# satisfies the bare positive above.
check_W_gate_near_placement() {
    file_contains_multiline 'getUseforpicking[\s\S]{0,400}transferUnitLoadToLocation\(' "$RECSVC"
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
check_H_create_save_split()    { file_not_contains_multiline '@HandleBeforeCreate\s+@HandleBeforeSave' "$HANDLER"; }
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
      && file_contains_multiline '@Transactional\([^)]*readOnly\s*=\s*true' "$QRYSVC" \
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
check_CTL_confirm_param()   { file_contains 'confirmIncompatibleSkus' "$CFGCTL"; }
check_CTL_preauthorize()    { file_contains_n_times '@PreAuthorize' "$CFGCTL" 3; }
# Phase 1a ships only setSku + setWarehouse; setMerchant is 1b (client column needs V2.2.11).
check_CTL_preauthorize_1a() { file_contains_n_times '@PreAuthorize' "$CFGCTL" 2; }
# The writers must be reachable — this is the dead-code guard the plan condemns elsewhere.
check_CTL_calls_service()   { file_contains 'putawayConfigService\.' "$CFGCTL"; }
# Preview is a resolver consumer, so it needs the §3.1.5 read-facade treatment, not a bare controller call.
check_CTL_no_direct_resolve() { file_not_contains 'putawayDestinationResolver\.' "$CFGCTL"; }
check_H_no_checked_throws()    { file_not_contains 'throws +BusinessException' "$HANDLER"; }
check_H_preauthorize()      { file_contains '(PreAuthorize|IS_SB_ADMIN|isSbAdmin)' "$HANDLER"; }

check_H_ctl_preauthorize()  { file_contains 'Authority\.IS_SB_ADMIN' "$IDCTL"; }

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
check_U_shows_source()      { file_contains 'sourceLabel' "$UI_RECFORM"; }
# PRESERVATION, added 2026-08-06. SBDEV-2731 PR1 (#39) ships a TRI-STATE `isPutawayDestinationApplied`
# returning true/false/null, and the template MUST compare `=== false`. `!null` is `true`, so rewriting it
# as a falsy test silently restores the bug 2731 fixed — on first paint, for every tenant with
# REQUIRE_RECEIVING_TO_CONTAINER=false, i.e. exactly the population that configures alternate putaway
# locations. This plan adds `sourceLabel` to the same block, so this plan can break it.
# Fails until #39 merges (the symbol does not exist on develop yet) — that is correct, it is a
# post-prerequisite preservation check, not a pre-implementation one.
check_U_tristate_kept()     { file_contains 'isPutawayDestinationApplied === false' "$UI_RECFORM"; }
check_U_picker_exists()     { file_exists "$UI_PICKER"; }
# NEGATIVE: the picker must NOT use the useforstorage-only query — it can never
# return PutAwayLane (§3.11.2 / L-PRE.10).
check_U_picker_not_storage_query() { file_not_contains 'getStorageLocationsForPutAwayItemData' "$UI_PICKER"; }
check_U_param_branch()      { file_contains 'DEFAULT_PUTAWAY_LOCATION' "$UI_EDITPARAM"; }
check_U_shipper_field()     { file_contains 'defaultputawaylocationId' "$UI_EDITSHIPPER"; }
check_U_persist_excluded()  { file_contains_i 'putaway' "$UI_PERSIST"; }

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
echo "-- Phase 1-API — V2.2.11 migration -------------------------------------------"
run M-exists      "V2.2.11 migration file exists"                     check_M_exists
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
run V-nofixabs    "NEG: validator does NOT reject on fix-assignment (iv-b)" check_V_no_fixloc_absolute
run V-nopickrej   "NEG: validator does NOT reject on useforpicking (iv-b)"  check_V_no_pickface_reject
run T-skupick     "test: SKU-scope write PERMITS a pick-face destination"   check_T_sku_pickface_test
run T-merchpick   "test: merchant-scope write PERMITS a pick-face destination" check_T_merch_pickface_test
run T-stagingok   "test: merchant-scope write PERMITS a staging lane (P2.7a)" check_T_staging_ok_test
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
run IDS-deleg     "ItemdataService delegates to PutawayConfigService"  check_IDS_delegates
run IDCTL-deleg   "ItemDataController routes through the service"      check_IDCTL_delegates
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
run W-gate        "(iv-b) receiving gates placement on useforpicking"   check_W_pickface_gate
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
runp 1 N2-deleg  "NEG: ReceivingController delegates, never resolves"  check_N2_controller_delegates_not_resolves
runp 1 C-1awrit  "1a: setSku + setWarehouse writers exist"            check_C_1a_writers
runp 1 CTL-auth2 "1a: both writes carry @PreAuthorize [AC11]"         check_CTL_preauthorize_1a
runp 1 CTL-auth  "1b: all 3 writes carry @PreAuthorize [AC11]"        check_CTL_preauthorize
run CTL-svc       "controller delegates to PutawayConfigService"       check_CTL_calls_service
run CTL-noresolve "NEG: controller never calls the resolver [C1]"      check_CTL_no_direct_resolve
run H-auth        "handler enforces the admin authority"               check_H_preauthorize
run H-ctlauth     "typed config endpoint carries @PreAuthorize"        check_H_ctl_preauthorize
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
run U-tristate    "PRESERVE 2731 tri-state: '=== false', never '!'"    check_U_tristate_kept
run U-picker      "LocationPicker.vue exists"                          check_U_picker_exists
run U-negq        "NEG: picker not built on useforstorage-only query"  check_U_picker_not_storage_query
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
