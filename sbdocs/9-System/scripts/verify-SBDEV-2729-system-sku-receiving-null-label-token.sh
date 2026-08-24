#!/usr/bin/env bash
# verify-SBDEV-2729-system-sku-receiving-null-label-token.sh
#
# Machine-checkable acceptance for:
#   sbdocs/1-Projects/wms2/plan/SBDEV-2729-system-sku-receiving-null-label-token.md
#
# Bug: System SKU (ICE PACK) cannot be received. String.replace(CharSequence,
#      CharSequence) is null-hostile; four of the twelve ZPL token sources in
#      SharedService.createCaseLabel are nullable columns. A null itemdata.winetype
#      aborts receiveGoods and rolls back the whole receive, and ReceivingController
#      echoes the raw NPE text to the operator.
#
# Usage:
#   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
#     bash sbdocs/9-System/scripts/verify-SBDEV-2729-system-sku-receiving-null-label-token.sh
#
# Exit code 0 only when every check passes. Paste the final "Result:" line into
# the plan's §16 Implementation Status before claiming the work is done.
#
# IMPORTANT — the plan splits the work into PR1 (urgent) and PR2 (hardening), so a
# whole-script "0 fail" is only attainable after PR2. PR1's gate is "0 fail among its
# NAMED SUBSET" (plan §7.2). Checks B1-B12, C1-C5, D1, D4, D5, D6, S1 and S2 belong to
# PR2 and are EXPECTED to fail while PR1 is in review. State which subset a pasted
# result line refers to.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

# mvn / java are installed via SDKMAN on this machine and are NOT on a default
# non-interactive PATH. Without this, the T* test checks FAIL for an environment
# reason rather than an assertion reason — a misleading red. Add SDKMAN's
# current candidates if they exist, then gate the T* checks on mvn actually
# being runnable (see MVN_AVAILABLE below).
for _c in java maven; do
    _bin="$HOME/.sdkman/candidates/$_c/current/bin"
    [ -d "$_bin" ] && case ":$PATH:" in *":$_bin:"*) ;; *) PATH="$_bin:$PATH" ;; esac
done
export PATH
if command -v mvn >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
    MVN_AVAILABLE=1
else
    MVN_AVAILABLE=0
fi

PASS=0
FAIL=0
SKIP=0

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
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-10s  %s  (%s)\n" "$id" "$desc" "$reason"
    SKIP=$((SKIP+1))
}

# --- assertion helpers -------------------------------------------------------

file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }

file_contains_n_times() {
    local pattern=$1 file=$2 n=$3 count
    count=$(grep -cE "$pattern" "$file" 2>/dev/null || echo 0)
    [ "$count" -ge "$n" ]
}

# Always pass a WHOLE class name here. `-Dtest='Outer#method'` silently no-ops
# for @Nested test classes in this repo and reports a false green —
# SharedServiceUnitTest uses @Nested CreateCaseLabel.
# Gate on the EXIT CODE, not on grepping stdout: `-q` suppresses both
# "BUILD SUCCESS" and the "Tests run:" summary, so a stdout grep can never match
# and every T* check would report a false FAIL on a passing test suite.
mvn_test_passes() {
    local test_class=$1
    mvn test -Dtest="$test_class" -DfailIfNoTests=false -q >/dev/null 2>&1
}

SHARED=src/main/java/net/aim_ai/wms/service/SharedService.java
STOCKU=src/main/java/net/aim_ai/wms/service/StockunitService.java
ORDERMV=src/main/java/net/aim_ai/wms/service/OrderMonitorViewService.java
UNITLOADSVC=src/main/java/net/aim_ai/wms/service/UnitloadService.java
RECVCTRL=src/main/java/net/aim_ai/wms/controller/ReceivingController.java
ULCTRL=src/main/java/net/aim_ai/wms/controller/UnitLoadController.java
MSGS=src/main/resources/messages_en_US.properties

# === Fix A — SharedService.createCaseLabel ===================================
# §0.1 rows 0-6, 9, 11-13

# Helpers exist.
check_A_nulltoempty_helper() {
    file_contains 'static\s+String\s+nullToEmpty\s*\(\s*String' "$SHARED"
}
check_A_requireconfig_helper() {
    file_contains 'requireConfig\s*\(\s*String\s+value\s*,\s*String\s+syskey\s*\)' "$SHARED"
}
check_A_requireconfig_not_private() {
    # HIGH-1: `private static String requireConfig` is a GUARANTEED compile break —
    # Fix B calls it from StockunitService (same package). Must be package-private.
    ! grep -qE 'private\s+static\s+String\s+requireConfig' "$SHARED"
}
check_A_requireconfig_isblank() {
    # Must reject blank, not only null (plan §8.1 shouldThrowBusinessExceptionWhenWarehouseNameBlank)
    file_contains 'value\s*==\s*null\s*\|\|\s*value\.isBlank\(\)' "$SHARED"
}
check_A_requireconfig_throws_business() {
    # The THROWN key must equal the BUNDLE key, or resolveMessage misses and the operator
    # sees the raw key — the exact failure the locale fix exists to prevent. In revision 3
    # A4 required the old key while M1/M1b required the new one: both passed, feature broken.
    file_contains 'throw new BusinessException\("BusinessException\.MissingReceivingConfiguration"' "$SHARED"
}

# PRIMARY site: {product_type} guarded.
check_A_product_type_guarded() {
    file_contains 'replace\("\{product_type\}",\s*nullToEmpty\(itemdata\.getWinetype\(\)\)\)' "$SHARED"
}
check_A_product_type_unguarded_gone() {
    file_not_contains 'replace\("\{product_type\}",\s*itemdata\.getWinetype\(\)\)' "$SHARED"
}

# Other proven-nullable sources.
check_A_case_type_guarded() {
    # MUST be caseTypeName, not nullToEmpty(boxtype.getName()): the §0.1 row 0 boxtype
    # guard DELETES the `boxtype` local, so the old form is unwriteable. A7 and A0b were
    # mutually unsatisfiable in revision 3 — `0 fail` was mathematically unreachable.
    file_contains 'replace\("\{case_type\}",\s*caseTypeName\)' "$SHARED"
}
check_A_case_type_unguarded_gone() {
    file_not_contains 'replace\("\{case_type\}",\s*boxtype\.getName\(\)\)' "$SHARED"
}
check_A_purchase_order_guarded() {
    file_contains 'replace\("\{purchase_order\}",\s*nullToEmpty\(purchaseOrder\)\)' "$SHARED"
}
check_A_purchase_order_unguarded_gone() {
    file_not_contains 'replace\("\{purchase_order\}",\s*purchaseOrder\)' "$SHARED"
}

# Defensive sources (NOT NULL in DB but same mechanism).
check_A_product_name_guarded() {
    file_contains 'replace\("\{product_name\}",\s*nullToEmpty\(itemdata\.getName\(\)\)\)' "$SHARED"
}
check_A_sku_guarded() {
    file_contains 'replace\("\{SKU\}",\s*nullToEmpty\(itemdata\.getItemNr\(\)\)\)' "$SHARED"
}
check_A_shipper_guarded() {
    file_contains 'replace\("\{shipper\}",\s*nullToEmpty\(client\.getName\(\)\)\)' "$SHARED"
}
check_A_uload_guarded() {
    file_contains 'replace\("\{u_load\}",\s*nullToEmpty\(unitload\.getLabelid\(\)\)\)' "$SHARED"
}
check_A_user_guarded() {
    file_contains 'replace\("\{user\}",\s*nullToEmpty\(operator\.getName\(\)\)\)' "$SHARED"
}

# Required config: ZPL template + warehouse name both go through requireConfig.
check_A_zpl_required() {
    # Must prove the ZPL TEMPLATE is the wrapped value. The old first branch was
    # `requireConfig\(\s*$`, which matched ANY line ending in `requireConfig(` and
    # therefore proved nothing. Match across the wrapped call instead.
    grep -Pzoq 'requireConfig\(\s*\n?\s*syspropService\.getSysvalue\(\s*WmsConstants\.SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY' "$SHARED" \
        || file_contains 'requireConfig\(\s*syspropService\.getSysvalue\(WmsConstants\.SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY' "$SHARED"
}
check_A_warehouse_required() {
    file_contains 'requireConfig\(warehouseName,\s*WmsConstants\.SYSTEM_PROPERTY_WAREHOUSE_NAME_KEY\)' "$SHARED"
}
check_A_warehouse_unguarded_gone() {
    # Accept EITHER shape: a new `warehouse` local, or `warehouseName = requireConfig(...)`
    # reassigned in place (which leaves the .replace line textually unchanged and is
    # perfectly correct). So assert that requireConfig guards it, rather than that the
    # .replace line changed — the naive form FALSE-FAILS on the reassignment idiom.
    file_contains 'requireConfig\(\s*warehouseName' "$SHARED" \
        || file_not_contains 'replace\("\{warehouse\}",\s*warehouseName\)' "$SHARED"
}

# §0.1 row 0 — the boxtype findById(null) crash (nullable on 80.1% of live ULs).
check_A_boxtype_null_guarded() {
    file_contains 'unitload\.getBoxtypeId\(\) == null' "$SHARED"
}
check_A_boxtype_unguarded_orelsethrow_gone() {
    # Clause 1 used to be `findById(...)\s*$`, which false-failed the perfectly correct
    # wrapped form:  findById(id)\n  .map(Boxtype::getName)\n  .orElse(""). Dropped —
    # a formatting spec, not a semantic one. The -Pzoq clause carries the real weight
    # and is newline-tolerant.
    ! grep -Pzoq 'boxtypeRepository\.findById\(unitload\.getBoxtypeId\(\)\)[\s\S]{0,80}?\.orElseThrow' "$SHARED"
}

# MEDIUM-12 / N14 — the warehouseName check must be HOISTED to ReceivingService:429,
# before the per-case loop. Checked inside createCaseLabel only, it writes N rows and
# then rolls back, which is not "fail fast" in any useful sense.
RECVSVC=src/main/java/net/aim_ai/wms/service/ReceivingService.java
check_A_warehouse_hoisted_to_caller() {
    grep -Pzoq 'requireConfig\([\s\S]{0,300}?SYSTEM_PROPERTY_WAREHOUSE_NAME_KEY' "$RECVSVC"
}

# Signature propagates the checked exception.
check_A_signature_throws() {
    file_contains 'createCaseLabel\((.|\n)*throws BusinessException' "$SHARED" || \
    grep -A6 'public byte\[\] createCaseLabel' "$SHARED" | grep -qE 'throws BusinessException'
}

# Blank (not "N/A") is the chosen substitution in this file — plan §10 D1.
# Accept BOTH the ternary and the if-form: pinning the exact ternary text made this
# a FORMATTING spec, so a correct `if (value == null) { return ""; }` would fail.
check_A_blank_not_na() {
    grep -Pzoq 'String nullToEmpty\(String[^)]*\)\s*\{[^}]*""[^}]*\}' "$SHARED" \
        && ! grep -Pzoq 'String nullToEmpty\(String[^)]*\)\s*\{[^}]*"N/A"' "$SHARED"
}

# === Fix B — StockunitService label builders ==================================
# §0.2 rows 14-17, 19-20

check_B_createcaselabel_product_type_guarded() {
    file_contains 'replace\("\{product_type\}",\s*(SharedService\.)?nullToEmpty\(itemData\.getWinetype\(\)\)\)' "$STOCKU"
}
check_B_createcaselabel_unguarded_gone() {
    file_not_contains 'replace\("\{product_type\}",\s*itemData\.getWinetype\(\)\)' "$STOCKU"
}
check_B_warehouse_unguarded_gone() {
    # Both builders had `.replace("{warehouse}", warehouseName)` — neither may remain raw.
    # Same reassignment tolerance as A18: requireConfig on warehouseName is sufficient.
    file_contains_n_times 'requireConfig\(\s*warehouseName' "$STOCKU" 2 \
        || file_not_contains 'replace\("\{warehouse\}",\s*warehouseName\)' "$STOCKU"
}
check_B_shipper_guarded() {
    file_contains 'replace\("\{shipper\}",\s*(SharedService\.)?nullToEmpty\(client\.getName\(\)\)\)' "$STOCKU"
}
check_B_multistock_clientname_guarded() {
    file_contains 'replace\("\{shipper\}",\s*(SharedService\.)?nullToEmpty\(clientName\)\)' "$STOCKU"
}
check_B_uload_guarded_twice() {
    # One per builder.
    file_contains_n_times 'replace\("\{u_load\}",\s*(SharedService\.)?nullToEmpty\(unitLoad\.getLabelid\(\)\)\)' "$STOCKU" 2
}
check_B_product_name_guarded() {
    file_contains 'replace\("\{product_name\}",\s*(SharedService\.)?nullToEmpty\(itemData\.getName\(\)\)\)' "$STOCKU"
}
check_B_sku_guarded() {
    # {SKU} is uppercase — it escaped the old lowercase-only S1 sweep entirely,
    # so StockunitService:555 had NO assertion at all before this was added.
    file_contains 'replace\("\{SKU\}",\s*(SharedService\.)?nullToEmpty\(itemData\.getItemNr\(\)\)\)' "$STOCKU"
}
check_B_required_config_used() {
    # Total calls >= 4 (ZPL + warehouse, per builder) AND warehouse-specific >= 2.
    # LINE-BASED on purpose. Two holes have been closed here:
    #   (1) counting >=2 matching lines passed when ONE builder was done and the other
    #       was entirely unguarded;
    #   (2) the -Pzo replacement used a lazy [\s\S]{0,1200}? window that spanned OUT of
    #       createCaseLabel and INTO createCaseLabelMultiStock (~25 lines apart), so one
    #       call in EACH builder passed with warehouseName unguarded in both.
    # Formulation validated by the architect against four trees: correct impl (4/2) PASS;
    # one-call-per-builder (2/0) FAIL; builder1-only (2/1) FAIL; unmodified develop (0/0) FAIL.
    file_contains_n_times '(SharedService\.)?requireConfig\('                 "$STOCKU" 4 \
    && file_contains_n_times '(SharedService\.)?requireConfig\(\s*warehouseName' "$STOCKU" 2
}
# §10 D1 keeps "*" in this helper. A revision-3 draft flipped it to "" for cross-path
# consistency; reverted on architect recommendation because it would change printed
# output on 80.1% of live ULs (10,718/13,381) for a purely cosmetic gain, inside an
# urgent PR, in a method both reviews independently certified correct.
check_B_boxtype_helper_still_star() {
    file_contains 'orElse\("\*"\)' "$STOCKU"
}
check_B_boxtype_helper_null_branch_intact() {
    file_contains 'getBoxtypeId\(\) == null' "$STOCKU"
}
# The "*" markers in createCaseLabelMultiStock mean "multiple differing values",
# NOT "missing" — a different semantic that must survive.
check_B_multistock_star_markers_intact() {
    file_contains_n_times 'replace\("\{(product_name|SKU|product_type|size)\}",\s*"\*"\)' "$STOCKU" 4
}

# === Fix C — OrderMonitorViewService {lane_id} ================================
# §0.2 rows 19-20

check_C_lane_id_guarded() {
    file_contains 'replace\("\{lane_id\}",\s*automationLane\.getName\(\) != null \? automationLane\.getName\(\) : "N/A"\)' "$ORDERMV"
}
check_C_lane_id_unguarded_gone() {
    file_not_contains 'replace\("\{lane_id\}",\s*automationLane\.getName\(\)\)' "$ORDERMV"
}
check_C_carrier_code_value_guarded() {
    # :247 guarded the OBJECT (shipperID) but not the VALUE (getExternalid()) —
    # the same half-guard defect this plan names at SharedService:78.
    # NEWLINE-TOLERANT: the line-based form false-failed a wrapped ternary, which is how
    # the plan's own After-sample was written. Same trap as A18/B3/A0b.
    grep -Pzoq 'replace\("\{carrier_code\}",[\s\S]{0,120}?shipperID != null && shipperID\.getExternalid\(\) != null' "$ORDERMV"
}
check_C_carrier_code_halfguard_gone() {
    file_not_contains 'replace\("\{carrier_code\}",\s*shipperID != null \? shipperID\.getExternalid\(\) : "N/A"\)' "$ORDERMV"
}
# The pre-existing guards must survive untouched.
check_C_existing_guards_intact() {
    file_contains_n_times '!= null \?.*: "N/A"' "$ORDERMV" 12
}

# === Fix D — ReceivingController stops leaking raw runtime messages ===========
# §0.3 rows 22-23

check_D_no_raw_runtime_message_echo() {
    # No `catch (RuntimeException ...)` block may still push e.getMessage() to the client.
    # Assert ONLY on errors.add(...) statements — never on the log call.
    # Five failure modes have been found in this one check across four revisions:
    #   (1) `grep -A4` too narrow for Fix D's 7-line LOG.error         -> false-PASS
    #   (2) awk counting braces on `} catch (...) {` (nets zero)       -> false-PASS
    #   (3) a leak wrapped across two lines, or via a local alias      -> false-PASS
    #   (4) neutralising the LOG.error NAME left its ARGUMENTS in the block, so keeping
    #       the harmless `LOG.error("...", e.getMessage(), e)` went red -> false-FAIL
    #   (5) matching only getMessage() missed getLocalizedMessage() and toString().
    #       getLocalizedMessage() is HOUSE STYLE here — ReceivingController already uses
    #       it 5x in its FacadeException catches                        -> false-PASS
    # Hence: flatten the block, match all three accessors reaching errors.add(), plus the
    # alias form, and FLUSH AT END so an unbalanced brace fails loudly instead of silently.
    ! awk '
        function flush() {
            if (blk == "") return
            if (blk ~ /errors\.add\([^;]*e\.(getMessage|getLocalizedMessage|toString)\(\)/) print "LEAK"
            else if (blk ~ /=[ ]*e\.(getMessage|getLocalizedMessage|toString)\(\)/) print "LEAK"
            blk = ""
        }
        /catch \(RuntimeException/ { flush(); inblk=1; depth=1; blk=" "; next }
        inblk {
            blk = blk " " $0
            n=gsub(/\{/,"{"); m=gsub(/\}/,"}")
            depth += n - m
            if (depth<=0) { inblk=0; flush() }
        }
        END { if (inblk) { print "LEAK" } else flush() }   # unbalanced block => loud failure
    ' "$RECVCTRL" | grep -q LEAK
}
check_D_generic_user_message_present() {
    file_contains 'unexpected internal error' "$RECVCTRL"
}
check_D_receive_logs_business_context() {
    # Must appear INSIDE the LOG.error call, not merely somewhere nearby. A loose
    # `grep -A8 'catch (RuntimeException'` false-passes on the pre-existing
    # `getMessageResponse(advicePositionId.toString(), "RECEIVED")` a few lines
    # below the catch block.
    grep -zoE 'LOG\.error\("Unexpected error during receive:[^;]*advicePositionId[^;]*;' "$RECVCTRL" \
        >/dev/null 2>&1
}
check_D_all_six_runtime_catches_still_present() {
    file_contains_n_times 'catch \(RuntimeException' "$RECVCTRL" 6
}
# BusinessException/FacadeException messages MUST still reach the user — that is
# how Fix A's actionable sentence is surfaced (plan §5 Fix D).
check_D_entitynotfound_caught_first() {
    # HIGH-2: EntityNotFoundException extends RuntimeException and carries actionable
    # operator text ("Printer not found with id: 5"). Fix D must NOT swallow it into
    # the generic sentence. Require one catch per RuntimeException catch (6), and
    # require it to appear BEFORE the RuntimeException catch in the file.
    file_contains_n_times 'catch \(EntityNotFoundException' "$RECVCTRL" 6 && \
    [ "$(grep -n 'catch (EntityNotFoundException' "$RECVCTRL" | head -1 | cut -d: -f1)" \
      -lt "$(grep -n 'catch (RuntimeException' "$RECVCTRL" | head -1 | cut -d: -f1)" ]
}
check_D_business_message_still_echoed() {
    grep -A3 'catch (BusinessException' "$RECVCTRL" | grep -qE 'e\.getMessage\(\)'
}

# === Fix E — checked-exception propagation ===================================
# §0.3 row 24

check_E_reprintlabel_throws_business() {
    file_contains 'public void reprintLabel\(Unitload unitLoad, Long printerId\).*throws.*BusinessException' "$UNITLOADSVC"
}
check_E_unitloadcontroller_catches_business() {
    grep -A10 'unitloadService\.reprintLabel' "$ULCTRL" | grep -qE 'catch \(BusinessException'
}

# === Message bundle ==========================================================

MSGS_BASE=src/main/resources/messages.properties
check_msg_key_added() {
    file_contains '^BusinessException\.MissingReceivingConfiguration=' "$MSGS"
}
check_msg_base_bundle_exists() {
    # Without a base bundle, ResourceBundle.getBundle("messages", Locale.getDefault())
    # resolves ONLY under en_US; en / en_GB / de_DE all fall back to the raw key.
    [ -f "$MSGS_BASE" ] && file_contains '^BusinessException\.MissingReceivingConfiguration=' "$MSGS_BASE"
}
check_msg_key_actionable() {
    # Ticket wording: must tell the operator to contact an administrator, and must
    # blame the WAREHOUSE/tenant config rather than the SKU (plan §5 Fix A note 1).
    # Must tell the operator to contact an administrator, and must NOT blame the SKU —
    # the missing thing is tenant/warehouse config (plan §5 Fix A, choice 1).
    grep -E '^BusinessException\.MissingReceivingConfiguration=' "$MSGS" \
        | grep -qiE 'administrator' \
        && ! grep -E '^BusinessException\.MissingReceivingConfiguration=' "$MSGS" | grep -qiE 'selected .*SKU'
}
check_msg_key_has_param_impl() {
    # Accept BOTH positional forms. The bundle uses %1$s 110x and %1s 22x; the bare
    # %1s block is the legacy camelCase tail (lines 310-337) where this key lands, so
    # either is correct and both work at runtime (%1s parses as width-1 %s). Matching
    # only '%1s' FALSE-FAILS if a reviewer normalises the key to %1$s.
    grep -E '^BusinessException\.MissingReceivingConfiguration=' "$MSGS" | grep -qE '%1\$?s'
}
check_msg_key_has_param() { check_msg_key_has_param_impl; }

# S1 only catches `.replace("{t}", x.getFoo())`. A bare variable —
# `.replace("{warehouse}", warehouseName)` — never matched, so a NEW raw site of
# that shape escaped the sweep entirely. Allowed bare args are the vetted locals.
check_sweep_no_bare_variable_in_replace() {
    ! grep -rnE '\.replace\("\{[A-Za-z_]+\}",\s*[a-z][a-zA-Z0-9_]*\)' \
        src/main/java --include=*.java \
      | grep -vE 'nullToEmpty|requireConfig|createdDate|created_date|caseTypeName|purchaseOrder|warehouse\)'
}

# === D7 — service-level business-context log (ticket AC: BOL ID + SKU) ========
# The controller holds only advicePositionId, so it structurally CANNOT satisfy the
# ticket's "log the Inbound BOL ID and SKU" requirement. The log must live in
# receiveGoods, where advice and itemdata are already loaded.
check_D7_service_context_log() {
    file_contains 'receiveGoods failed' "$RECVSVC" \
    && grep -Pzoq 'receiveGoods failed[\s\S]{0,700}?getDeliverynotenumber\(\)' "$RECVSVC" \
    && grep -Pzoq 'receiveGoods failed[\s\S]{0,700}?getItemNr\(\)' "$RECVSVC"
}
check_D7_rethrows_unchanged() {
    # Must rethrow the SAME exception object — wrapping it would change rollback
    # semantics, which §12 row 4 depends on.
    grep -Pzoq 'receiveGoods failed[\s\S]{0,900}?throw e;' "$RECVSVC"
}

# === M7 — cached null must not defeat the fail-fast recovery path =============
SYSPROPSVC=src/main/java/net/aim_ai/wms/service/SyspropService.java
check_M7_getsysvalue_not_caching_null() {
    # NO [^)]* fencing: the @Cacheable key SpEL already contains ')' characters
    # (T(...TenantContext).getCurrentTenant()?.getFacilityCode()), so a fenced regex can
    # never span the annotation. Revision 3's version false-failed in BOTH attribute orders.
    grep -Pzoq 'unless\s*=\s*"#result == null"[\s\S]{0,400}?public String getSysvalue' "$SYSPROPSVC"
}

# === Repo-wide sweep: no unguarded token replace left anywhere ===============
# Catches a fix applied to the named sites while a new/other site stays raw.
# Allowed forms: nullToEmpty(...), String.valueOf(...), a literal, a ternary
# guard, or a local already proven non-null (createdDate / created_date).
check_sweep_no_unguarded_getter_in_replace() {
    # Token class MUST be [A-Za-z_], not [a-z_]: the uppercase token {SKU} escapes a
    # lowercase-only class, which silently exempted StockunitService:555 from the sweep
    # (proven in review). Uppercase tokens in this codebase: {SKU}.
    ! grep -rnE '\.replace\("\{[A-Za-z_]+\}",\s*[a-zA-Z][a-zA-Z0-9_]*\.get[A-Z][a-zA-Z0-9_]*\(\)\)' \
        src/main/java --include=*.java
}

# === Wire into the runner ====================================================

echo
echo "verify-SBDEV-2729-system-sku-receiving-null-label-token — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo
echo "Fix A — SharedService.createCaseLabel null-safe tokens + fail-fast config"
run A1  "nullToEmpty helper exists"                       check_A_nulltoempty_helper
run A2  "requireConfig helper exists"                     check_A_requireconfig_helper
run A2b "requireConfig is NOT private (compile break)"    check_A_requireconfig_not_private
run A3  "requireConfig rejects blank as well as null"     check_A_requireconfig_isblank
run A4  "requireConfig throws BusinessException(key)"     check_A_requireconfig_throws_business
run A0  "boxtype_id null guarded (80% of live ULs)"      check_A_boxtype_null_guarded
run A0b "unguarded boxtype orElseThrow gone"             check_A_boxtype_unguarded_orelsethrow_gone
run A5  "{product_type} guarded (PRIMARY SITE)"           check_A_product_type_guarded
run A6  "{product_type} unguarded form gone"              check_A_product_type_unguarded_gone
run A7  "{case_type} guarded"                             check_A_case_type_guarded
run A8  "{case_type} unguarded form gone"                 check_A_case_type_unguarded_gone
run A9  "{purchase_order} guarded"                        check_A_purchase_order_guarded
run A10 "{purchase_order} unguarded form gone"            check_A_purchase_order_unguarded_gone
run A11 "{product_name} guarded"                          check_A_product_name_guarded
run A12 "{SKU} guarded"                                   check_A_sku_guarded
run A13 "{shipper} guarded"                               check_A_shipper_guarded
run A14 "{u_load} guarded"                                check_A_uload_guarded
run A15 "{user} guarded"                                  check_A_user_guarded
run A16 "ZPL template goes through requireConfig"         check_A_zpl_required
run A17 "warehouseName goes through requireConfig"        check_A_warehouse_required
run A18 "{warehouse} raw substitution gone"               check_A_warehouse_unguarded_gone
run A19 "createCaseLabel throws BusinessException"        check_A_signature_throws
run A21 "warehouseName requireConfig hoisted to :429"    check_A_warehouse_hoisted_to_caller
run A20 "blank (not N/A) is the substitution — D1"        check_A_blank_not_na

echo
echo "Fix B — StockunitService createCaseLabel + createCaseLabelMultiStock"
run B1  "{product_type} guarded"                          check_B_createcaselabel_product_type_guarded
run B2  "{product_type} unguarded form gone"              check_B_createcaselabel_unguarded_gone
run B3  "{warehouse} raw substitution gone (both)"        check_B_warehouse_unguarded_gone
run B4  "{shipper} guarded (createCaseLabel)"             check_B_shipper_guarded
run B5  "{shipper} guarded (multiStock clientName)"       check_B_multistock_clientname_guarded
run B6  "{u_load} guarded in both builders"               check_B_uload_guarded_twice
run B7  "required-config check present in both"           check_B_required_config_used
run B10 "{product_name} guarded"                          check_B_product_name_guarded
run B11 "{SKU} guarded (uppercase — S1 blind spot)"       check_B_sku_guarded
run B8  "getBoxTypeNameFromUnitLoad still returns *"      check_B_boxtype_helper_still_star
run B9  "getBoxTypeNameFromUnitLoad null branch intact"   check_B_boxtype_helper_null_branch_intact
run B12 "multiStock \"*\" markers intact (differing vals)" check_B_multistock_star_markers_intact

echo
echo "Fix C — OrderMonitorViewService {lane_id}"
run C1  "{lane_id} guarded with N/A"                      check_C_lane_id_guarded
run C2  "{lane_id} unguarded form gone"                   check_C_lane_id_unguarded_gone
run C3  "pre-existing N/A guards intact (>=12)"          check_C_existing_guards_intact
run C4  "{carrier_code} value guarded (half-guard fix)"  check_C_carrier_code_value_guarded
run C5  "{carrier_code} half-guard form gone"            check_C_carrier_code_halfguard_gone

echo
echo "Fix D — ReceivingController error surfacing"
run D1  "no catch(RuntimeException) echoes e.getMessage()" check_D_no_raw_runtime_message_echo
run D2  "generic user-facing message present"             check_D_generic_user_message_present
run D3  "receive logs advicePositionId context"           check_D_receive_logs_business_context
run D4  "all 6 RuntimeException catches still present"    check_D_all_six_runtime_catches_still_present
run D5  "BusinessException message STILL echoed"          check_D_business_message_still_echoed
run D6  "EntityNotFoundException caught FIRST (6x)"      check_D_entitynotfound_caught_first

echo
echo "Fix E — checked-exception propagation"
run E1  "reprintLabel throws BusinessException"           check_E_reprintlabel_throws_business
run E2  "UnitLoadController catches BusinessException"    check_E_unitloadcontroller_catches_business

echo
echo "Message bundle"
run M1  "BusinessException.MissingReceivingConfiguration"  check_msg_key_added
run M1b "base messages.properties has the key (locale)"  check_msg_base_bundle_exists
run M2  "message tells operator to contact administrator" check_msg_key_actionable
run M3  "message takes the syskey as %1s"                 check_msg_key_has_param

echo
echo "Repo-wide sweep"
run S1  "no unguarded getter inside any .replace(\"{...}\")" check_sweep_no_unguarded_getter_in_replace
run S2  "no bare-variable arg in any .replace(\"{...}\")"    check_sweep_no_bare_variable_in_replace
run D7  "receiveGoods logs BOL number + SKU"              check_D7_service_context_log
run D7b "receiveGoods rethrows e unchanged"               check_D7_rethrows_unchanged
run M7  "getSysvalue does not cache null (Fix F)"         check_M7_getsysvalue_not_caching_null

echo
echo "Targeted JUnit tests (code-shape greps prove the call exists, not that it works)"
if [ "$MVN_AVAILABLE" -eq 1 ]; then
    run T1  "SharedServiceUnitTest passes"                mvn_test_passes SharedServiceUnitTest
    run T2  "StockunitServiceUnitTest passes"             mvn_test_passes StockunitServiceUnitTest
    run T3  "ReceivingControllerUnitTest passes"          mvn_test_passes ReceivingControllerUnitTest
    run T4  "UnitloadServiceUnitTest passes"              mvn_test_passes UnitloadServiceUnitTest
    echo "  NOTE: 'mvn test' MUTATES the tracked archunit_store — git checkout it before committing."
else
    skip T1 "SharedServiceUnitTest passes"                "mvn/java not on PATH — source SDKMAN and re-run"
    skip T2 "StockunitServiceUnitTest passes"             "mvn/java not on PATH — source SDKMAN and re-run"
    skip T3 "ReceivingControllerUnitTest passes"          "mvn/java not on PATH — source SDKMAN and re-run"
    skip T4 "UnitloadServiceUnitTest passes"              "mvn/java not on PATH — source SDKMAN and re-run"
    echo "  NOTE: T* skipped for an ENVIRONMENT reason, not a passing assertion."
    echo "        Final acceptance requires T1-T4 to actually run and pass."
fi

# Behavioural coverage that greps cannot express — these live in the plan's
# §8.4 manual test plan and must be signed off by a human on UAT.
echo
echo "Manual-only (plan §8.4)"
skip MAN1 "NULL-winetype SKU receives end-to-end on UAT"  "manual — requires UAT tenant + printer"
skip MAN2 "putaway + allocate + pick the received stock"  "manual — full lifecycle, ticket AC"
skip MAN3 "missing WAREHOUSE_NAME shows actionable msg"   "manual — mutates tenant sysprop, must be restored"

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
