#!/usr/bin/env bash
# verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh
#
# Machine-checkable acceptance for
#   sbdocs/1-Projects/wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md
#
# SBDEV-2778 — "Return to Inventory" creates a RETURN inbound advice (BOL) that is never
# received and never closed.
#
# REWRITTEN 2026-08-03. BA decision (Brent Campbell): restore the v1/wms-api behavior —
# `type=RETURN` is auto-received and closed at create time, unconditionally, behind a
# default-ON kill switch. This SUPERSEDES SBDEV-2236, which deliberately deleted that block.
#
# The earlier revision of this script graded a `qa_confirmed`-gated design that no longer
# exists (Fix A and Fix D were deleted; the OMS repo left the plan entirely). Nothing here
# asserts anything about `qa_confirmed` any more.
#
# This is NOT a `git revert` of 7f9c250. v1's block has a defect worse than the reported bug:
# `v1:307` wraps receiveGoods in `if (printerOptional.isPresent())` with no else, while the
# FINISHED flips at v1:317-318 sit OUTSIDE that guard — so a tenant with no RETURN printer gets
# a phantom-closed return (FINISHED, zero goodsreceipt, inventory silently lost). The B7/B18/B19
# checks below exist specifically to stop that shape being ported.
#
# Usage:
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh
#
#   # including the slow mvn checks:
#   $ RUN_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2778-*.sh
#
# Exit code 0 only when every check passes. Paste the final `Result:` line into the plan's §11.
#
# IMPORTANT — negative-test this script before trusting it. A "N pass, 0 fail" means nothing
# until you have replayed the PRE-FIX files and watched it FAIL. `git stash` the change, run,
# confirm failures, then restore.

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
RUN_MVN="${RUN_MVN:-0}"

cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-10s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-10s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    printf "  SKIP  %-10s  %s  (%s)\n" "$1" "$2" "$3"; SKIP=$((SKIP+1))
}

file_contains()     { [ -f "$2" ] && grep -qE "$1" "$2" 2>/dev/null; }
# Fail closed: grep exits 2 on a missing file, which `!` would flip into a false PASS.
file_not_contains() { [ -f "$2" ] && ! grep -qE "$1" "$2" 2>/dev/null; }
# Multi-line variant — perl -0777 so the regex may span newlines.
# CRITICAL — every helper must FAIL CLOSED on a missing/unreadable file.
#
# With `perl -0777 -ne`, a file that cannot be opened means the implicit loop body never
# executes, so neither `exit 0` nor `exit 1` runs and perl terminates with status 0. Without
# the explicit `-f` guard below, every multi-line assertion PASSES against a file that does
# not exist — a false green that hides an entirely unimplemented fix. This was caught by
# negative-testing this script against the pre-fix tree; do not remove the guards.
file_contains_ml() {
    [ -f "$2" ] || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}
# NOTE: a missing file must FAIL here too. "The old construct is absent because the file is
# absent" is not evidence that anything was implemented.
file_not_contains_ml() {
    [ -f "$2" ] || return 1
    ! PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null
}
# Match a regex on at least N lines of a file.
file_contains_n_times() {
    [ -f "$2" ] || return 1
    local count
    count=$(grep -cE "$1" "$2" 2>/dev/null || echo 0)
    [ "$count" -ge "$3" ]
}
# Multi-line regex with /s (dot matches newline) — for "X appears before Y" ordering.
file_contains_ordered() {
    [ -f "$2" ] || return 1
    PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/s; exit 1' "$2" 2>/dev/null
}
file_not_contains_ordered() {
    [ -f "$2" ] || return 1
    ! PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/s; exit 1' "$2" 2>/dev/null
}
# ⚠ Do NOT add -q here. `mvn test -q` suppresses BOTH "BUILD SUCCESS" and the "Tests run:" summary,
# so the grep below can never match and M1-M4 become STRUCTURALLY UNPASSABLE — silently, while the
# class under test is actually 100% green. That made the plan's own mandatory RUN_MVN=1 acceptance
# line impossible to produce. Caught by the Phase-3a conformance lane, 2026-08-03.
#
# Read the surefire report rather than parsing stdout: it survives log-level changes, and "Failures: 0
# Errors: 0" in the report is a positive statement about THIS class, whereas "BUILD SUCCESS" is a
# statement about the whole reactor.
mvn_test_passes() {
    local cls="$1"
    rm -f target/surefire-reports/*"$cls"*.txt 2>/dev/null
    mvn test -Dtest="$cls" -DfailIfNoTests=false >/dev/null 2>&1
    local rpt
    rpt=$(ls target/surefire-reports/*"$cls"*.txt 2>/dev/null | head -1)
    [ -n "$rpt" ] || return 1                                  # no report => it never ran
    grep -qE "Failures: 0, Errors: 0" "$rpt" || return 1
    # Guard against a report that ran ZERO tests (the @Nested -Dtest='Outer#method' trap).
    ! grep -qE "Tests run: 0," "$rpt"
}

CTRL=src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java
DTO=src/main/java/net/aim_ai/wms/json/AdviceDto.java
SVC=src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java
CONST=src/main/java/net/aim_ai/wms/service/WmsConstants.java
RECV=src/main/java/net/aim_ai/wms/service/ReceivingService.java
CTRL_TEST=src/test/java/net/aim_ai/wms/unit/controller/rest/AdviceRestControllerUnitTest.java
SVC_TEST=src/test/java/net/aim_ai/wms/unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java
MIGRATION=src/main/resources/db/migration/V2.2.09__seed_return_advice_auto_receive_sysprop.sql

echo
echo "verify-SBDEV-2778 — RETURN advice auto-receive restored (v1 parity + kill switch)"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- Fix F — the default-ON kill switch --------------------------------------
#
# This block guards the single most likely way the fix silently fails in production.
# Every OTHER feature flag in this codebase is default-OFF and read as
#   Boolean.parseBoolean(syspropService.getSysvalue(KEY))
# (BillofladingService:762, ReplenishOrderJob:364, ReplenishGeneratorService:93, +6 more).
# Boolean.parseBoolean(null) == false, so an ABSENT ROW YIELDS OFF. For a default-ON flag that
# means any tenant without the V2.2.09 row keeps the exact bug this ticket exists to fix, and it
# looks identical to the pre-fix symptom. See plan §3 Fix F LANDMINE + R3.

run F1 "Fix F — WmsConstants declares the sysprop key constant" \
    file_contains 'SYSTEM_PROPERTY_RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED_KEY' "$CONST"
run F2 "Fix F — the key's string value is RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED" \
    file_contains '"RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED"' "$CONST"
run F3 "Fix F — V2.2.09 seed migration exists" \
    test -f "$MIGRATION"
run F4 "Fix F — the seed value is 'true' (DEFAULT ON, unlike every other flag)" \
    file_contains_ordered "RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED'\s*,\s*'true'" "$MIGRATION"
run F5 "Fix F — id comes from nextval('seqentities'), never a literal" \
    file_contains "nextval\('public\.seqentities'\)" "$MIGRATION"
run F6 "Fix F — seed is idempotent (INSERT ... WHERE NOT EXISTS)" \
    file_contains_ordered 'INSERT\s+INTO.*?WHERE\s+NOT\s+EXISTS' "$MIGRATION"
run F7 "Fix F — service exposes isAutoReceiveEnabled()" \
    file_contains 'boolean\s+isAutoReceiveEnabled\s*\(' "$SVC"

# F8 — the load-bearing negative, scoped to the METHOD BODY.
#
# An earlier revision used `Boolean\.parseBoolean[^;]{0,300}RETURN_ADVICE_AUTO_RECEIVE`, which was
# EVADABLE by the single most likely wrong implementation:
#     String raw = syspropService.getSysvalue(...RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED_KEY);
#     return Boolean.parseBoolean(raw);
# There is a `;` between the two tokens, so `[^;]` cannot bridge them and the check PASSED on the
# exact default-OFF bug R3 calls the most likely way this fix silently breaks. Match the body instead.
BODY_RE='boolean\s+isAutoReceiveEnabled\s*\([^)]*\)\s*\{(?:[^{}]|\{[^{}]*\})*\}'
check_F8() {
    [ -f "$SVC" ] || return 1
    file_contains 'isAutoReceiveEnabled' "$SVC" \
        && PATTERN="$BODY_RE" perl -0777 -ne '
              exit 1 unless /$ENV{PATTERN}/s;
              exit(($& =~ /Boolean\.parseBoolean/) ? 1 : 0);' "$SVC" 2>/dev/null
}
run F8 "Fix F — isAutoReceiveEnabled's BODY does not call Boolean.parseBoolean (would be default-OFF)" \
    check_F8
# F9 — the positive counterpart, also body-scoped. A file-wide grep would be satisfied by any
# unrelated "false".equalsIgnoreCase elsewhere in a two-method service.
# ⚠ The [-f] guard is LOAD-BEARING, not defensive. Without it this check PASSED against the pre-fix
# tree (no service file yet): `perl -0777 -ne` never enters its implicit loop on an unopenable file,
# so neither exit fires and perl returns 0. Caught by negative-testing this script — the exact
# fail-open shape documented in the helper comments above. Do not remove.
check_F9() {
    [ -f "$SVC" ] || return 1
    PATTERN="$BODY_RE" perl -0777 -ne '
        exit 1 unless /$ENV{PATTERN}/s;
        exit(($& =~ /"false"\.equalsIgnoreCase/) ? 0 : 1);' "$SVC" 2>/dev/null
}
run F9 "Fix F — the body disables ONLY on the literal \"false\" (default-ON semantics)" \
    check_F9
# F10 — an earlier revision was `isAutoReceiveEnabled|[Dd]efault[- ]ON`: unparenthesised alternation,
# whose left branch F7 already REQUIRES to exist, so it could never fail independently. Require the
# Javadoc/comment to actually precede the method.
run F10 "Fix F — a default-ON rationale comment precedes the method" \
    file_contains_ordered '[Dd]efault[- ]?ON.{0,900}?boolean\s+isAutoReceiveEnabled' "$SVC"
run F11 "Fix F — the comment warns against the parseBoolean house pattern by name" \
    file_contains 'Boolean\.parseBoolean' "$SVC"

# F12 — the seeded description must fit los_sysprop.description, which is varchar(255) per
# V2.2.00__base_v2_schema.sql:1376 (confirmed live on wsl-wineco-uat).
#
# Postgres does NOT truncate an over-long varchar — it raises 22001 — and Flyway runs each migration
# inside a transaction. So ONE over-long description aborts the WHOLE file: neither the kill-switch
# row nor the oms_integration user gets seeded, and the tenant is left with a failed migration that
# blocks every later V2.2.x. The first cut of V2.2.09 carried 268 chars, 13 over. Nothing else in the
# working lane catches this — every migration test that touches a real Postgres is in the @Disabled
# Testcontainers lane (SBDEV-2217) and the checks above are name-only greps. Flagged by the
# independent Codex review lane on PR #123, 2026-08-04.
#
# \x27 is a single quote: it keeps the perl program itself single-quote-free so bash cannot mangle it.
check_F12() {
    [ -f "$MIGRATION" ] || return 1
    local len
    len=$(perl -0777 -ne 'if (/\x27(SBDEV-2778:(?:[^\x27]|\x27\x27)*)\x27/) { my $v = $1; $v =~ s/\x27\x27/\x27/g; print length($v); } else { print -1 }' "$MIGRATION" 2>/dev/null)
    [ -n "$len" ] && [ "$len" -ge 1 ] && [ "$len" -le 255 ]
}
run F12 "Fix F — the seeded description fits varchar(255) (over-long aborts the whole migration)" \
    check_F12
run F13 "Fix F — a width guard test exists (the only non-@Disabled check on this)" \
    test -f src/test/java/net/aim_ai/wms/unit/db/SyspropMigrationDescriptionWidthTest.java

echo

# --- Fix B — ReturnAdviceAutoReceiveService ----------------------------------

run B1 "Fix B — ReturnAdviceAutoReceiveService exists" \
    test -f "$SVC"
# B2a — the DB-read step carries the read-only tenant tx; validate() itself must NOT, so the CUPS
# probe runs outside the transaction (otherwise we reproduce the ReceivingService:315 anti-pattern
# one level up). Assert both directions.
# ⚠ An earlier revision matched `\w+\s+\w+\s+resolveRefs`, which accepts `protected ResolvedRefs
# resolveRefs` — i.e. it CERTIFIED the broken shape. Spring's AnnotationTransactionAttributeSource
# has publicMethodsOnly=true, so a non-public @Transactional method gets NO transaction at all, and
# the failure is invisible to compile, tests and a naive grep. Require `public` explicitly.
run B2 "Fix B0 — resolveRefs is PUBLIC and READ-ONLY tenant-transactional (non-public = no tx at all)" \
    file_contains_ml '@Transactional\(\s*value\s*=\s*"tenantTransactionManager"\s*,\s*readOnly\s*=\s*true\s*\)\s*\n\s*public\s+ResolvedRefs\s+resolveRefs' "$SVC"
run B2c "Fix B0 — a @Lazy self-reference exists (proxy is required for the annotation to fire)" \
    file_contains_ml '@Lazy(?:[^;]|\n){0,120}ReturnAdviceAutoReceiveService\s+self\s*;' "$SVC"
run B2d "Fix B0 — resolveRefs is invoked via self., never bare this./unqualified" \
    file_contains 'self\.resolveRefs\(' "$SVC"
run B2e "Fix B0 — no bare this.resolveRefs( call (bypasses the proxy silently)" \
    file_not_contains 'this\.resolveRefs\(' "$SVC"
run B2b "Fix B2a — validate() itself is NOT transactional (CUPS probe outside the tx)" \
    file_not_contains_ml '@Transactional[^\n]*\n\s*public\s+\w+\s+validate\s*\(' "$SVC"
run B3 "Fix B — execute() exists" \
    file_contains 'public\s+void\s+execute\s*\(' "$SVC"
# execute() must NOT be transactional: wrapping it would hold one tenant connection across all N
# CUPS round-trips (ReceivingService:315), batch all N STOCK_UPDATE posts onto one commit, and
# poison the outer tx via receiveGoods' rollbackFor. See plan §3 B2b — three independent reasons.
run B4 "Fix B — execute() is NOT annotated @Transactional" \
    file_not_contains_ml '@Transactional[^\n]*\n\s*public\s+void\s+execute\s*\(' "$SVC"

# Relaxed: an earlier revision pinned the PARAMETER NAME (requestedPrinterId), failing an
# implementer who wrote findById(printerId) — a naming choice, not a behavior change.
run B5 "Fix B — printer resolution honors the caller-supplied printerId first (D3)" \
    file_contains_ordered 'resolvePrinter.{0,1500}?printerRepository\.findById\(' "$SVC"
run B6 "Fix B — falls back to the processdefault RETURN printer" \
    file_contains 'findByTypeAndProcessdefaultTrue\(\s*WmsConstants\.PrinterType\.RETURN\s*\)' "$SVC"
run B7 "Fix B — THROWS when no printer resolves (D2 — NOT v1:307's silent skip)" \
    file_contains_ml 'findByTypeAndProcessdefaultTrue\([^)]*\)\s*\n?\s*\.orElseThrow' "$SVC"
run B8 "Fix B — rejects a printerId whose type is not RETURN" \
    file_contains_ml 'PrinterType\.RETURN\.equals\(\s*\w+\.getType\(\)\s*\)' "$SVC"
# Boxtype: validate() must resolve the SAME boxtype the save loop will persist, via the same
# lookup the loop uses (AdviceRestController:247), so the two cannot disagree.
#
# Deliberately NOT asserted: getDefaultboxtypeId() / SYSTEM_PROPERTY_DEFAULT_BOX_TYPE_KEY /
# findByName. v1's three-step fallback chain (v1:279-304) is UNREACHABLE on the REST create path in
# BOTH versions — v1:258 / v2:261 unconditionally set boxtypeId from optionalBoxtype.get(), so it is
# always populated by the time any RETURN block runs (empirically confirmed: the repro row has
# boxtype_id=52000). Asserting the chain would force the implementer to add dead branches just to
# turn this script green, and v1's findByName would disagree with the loop's findByExternalid.
# See plan §3 B2, D5 and §10-Q10.
run B9 "Fix B — validate() resolves boxtype by the position's box_id (same lookup as :247)" \
    file_contains 'findByExternalid\(' "$SVC"
run B10 "Fix B — boxtype resolution failure throws (defensive orElseThrow)" \
    file_contains_ordered 'findByExternalid\(.{0,200}?\.orElseThrow' "$SVC"
run B11 "Fix B — uses DEFAULT_TYPE_NOT_EXIST as the boxtype failure code" \
    file_contains 'DEFAULT_TYPE_NOT_EXIST' "$SVC"
run B12 "Fix B — calls receiveGoods with the 8-arg signature" \
    file_contains 'receivingService\.receiveGoods\(' "$SVC"
run B13 "Fix B — flips adviceposition rows to FINISHED" \
    file_contains 'updateAdvicepositionToStateByAdviceId\(\s*AdviceState\.FINISHED' "$SVC"
run B14 "Fix B — flips the advice to FINISHED" \
    file_contains 'updateAdviceToStateById\(\s*AdviceState\.FINISHED' "$SVC"
run B15 "Fix B — partial failure raises RETURN_AUTO_RECEIVE_PARTIAL (not v1's GENERIC_ERROR)" \
    file_contains 'RETURN_AUTO_RECEIVE_PARTIAL' "$SVC"
run B16 "Fix B — partial-failure log names the failing SKU" \
    file_contains 'failedSku' "$SVC"
# NOTE: B17 is WEAK, not sound. C8 pins exactly one receiveGoods call-site, so a FINISHED flip placed
# INSIDE the loop still appears after that single call and B17 still passes. There is no sound static
# check for the all-or-nothing invariant (§3 B3 / §8 AC2) — it is guarded by tests T10/T12 and by
# RUN_MVN=1 M2, not by grep. Kept as a cheap smoke check only.
run B17 "Fix B — receive loop precedes the FINISHED flips (all-or-nothing ordering)" \
    file_contains_ordered 'receivingService\.receiveGoods\(.*?updateAdvicepositionToStateByAdviceId' "$SVC"

# --- §2 Bug 4 guard — do not port v1's phantom-close shape --------------------
# v1 wraps receiveGoods in `if (printerOptional.isPresent())` and flips state outside that guard.
# Restoring that shape would mark returns FINISHED having received nothing. B18 forbids the guard;
# B19 requires the negative test that proves the flips are unreachable on printer failure.
run B18 "Bug 4 — no printer-isPresent() guard around the receive (v1:307's shape)" \
    file_not_contains_ml 'if\s*\(\s*\w*[Pp]rinter\w*\.isPresent\(\)\s*\)' "$SVC"
run B19 "Bug 4 — service test proves the FINISHED flips never run when no printer resolves" \
    file_contains 'validateThrowsWhenNoPrinterIdAndNoProcessDefaultReturnPrinter' "$SVC_TEST"

# --- B3 hazard (c) — the two flips must be ONE transaction --------------------
# Called separately from a non-transactional execute(), updateAdvicepositionToStateByAdviceId and
# updateAdviceToStateById commit INDEPENDENTLY (both are @Modifying + bare @Transactional). A crash
# between them leaves positions FINISHED / advice OPEN, and ReceivingService:344 then refuses to
# dock-receive a non-OPEN position — a BOL no path can ever receive. See plan R13.
run B20 "Bug 4/R13 — markFinished() is @Transactional(tenantTransactionManager) and PUBLIC" \
    file_contains_ml '@Transactional\(\s*value\s*=\s*"tenantTransactionManager"\s*\)\s*\n\s*public\s+void\s+markFinished' "$SVC"
run B21 "R13 — execute() delegates the flips via self.markFinished (proxy required)" \
    file_contains 'self\.markFinished\(' "$SVC"
# The flips must live ONLY inside markFinished — a stray direct call from execute() would reintroduce
# the split-commit hazard. Each repo method should appear exactly once in the service.
run B22 "R13 — updateAdviceToStateById appears exactly once (only inside markFinished)" \
    bash -c '[ "$(grep -cE "updateAdviceToStateById\(" '"$SVC"' 2>/dev/null || echo 0)" -eq 1 ]'
run B23 "R13 — updateAdvicepositionToStateByAdviceId appears exactly once" \
    bash -c '[ "$(grep -cE "updateAdvicepositionToStateByAdviceId\(" '"$SVC"' 2>/dev/null || echo 0)" -eq 1 ]'

# --- B3 hazard (a) — unchecked exceptions must not escape ---------------------
# ReceivingService:503 is `catch (RuntimeException | BusinessException | FacadeException e) { throw e; }`
# and :336 Integer.parseInt(getSysvalue(MAXIMUM_RECEIVING_DURING_INBOUND)) throws NumberFormatException
# when unset. Catching only the checked pair lets an HTTP 500 escape with positions committed and no
# counter/log — Fix E bypassed entirely. See plan R14.
run B24 "R14 — execute() catches RuntimeException as well as BusinessException/FacadeException" \
    file_contains_ordered 'catch\s*\([^)]*RuntimeException[^)]*\)' "$SVC"
run B25 "R14 — service test forces an unchecked throw from receiveGoods" \
    file_contains 'executeWrapsUncheckedExceptionFromReceiveGoods' "$SVC_TEST"

# --- B3 hazard (b) — bulk flip must not over-reach ----------------------------
# updateAdvicepositionToStateByAdviceId is `WHERE a.adviceId = :adviceId` (AdvicepositionRepository:31)
# — it flips EVERY position of the advice. If plan.lines() is short of the persisted count, the loop
# skips a position and the bulk update marks it FINISHED anyway: Bug 4 in a new costume.
run B26 "Bug 4/R13 — bind() takes the saved positions (no self-issued DB read, exact line count)" \
    file_contains_ml 'bind\(\s*ValidatedAutoReceive[^)]*Advice\s+\w+[^)]*List<Adviceposition>' "$SVC"
run B27 "Bug 4 — service test covers a plan/persisted line-count mismatch" \
    file_contains 'executeThrowsWhenPlanLineCountDoesNotMatchPersistedPositions' "$SVC_TEST"
run B28 "Fix C — the controller collects the saved positions at :272" \
    file_contains 'savedPositions\.add\(\s*advicepositionRepository\.save\(' "$CTRL"

# --- D10 — validate() mirrors the reachable position checks -------------------
# Option (a) was DECIDED (plan D10). The sharp case: create() accepts amount_of_bottles = 0 (:230
# rejects only < 0) but ReceivingService:325 throws on < 1 — so a zero line passes a printer/boxtype-
# only B0 and then bricks mid-execute (R9/R15).
# Window widened 2500 -> 9000: the F1 caps, F6 sanitisation and F8 prerequisite checks all sit
# between resolveRefs' signature and this guard. Still anchored after resolveRefs so it cannot match
# an unrelated comparison elsewhere in the file.
run B29 "D10/R15 — resolveRefs rejects a position amount < 1 before anything is persisted" \
    file_contains_ordered 'resolveRefs.{0,9000}?getAmountOfBottles\(\)\s*<\s*1' "$SVC"
run B30 "D10/R15 — service test covers amount_of_bottles = 0" \
    file_contains 'validateThrowsWhenAmountOfBottlesIsZero' "$SVC_TEST"
# file_contains is line-based, and the call is now split across lines as
# `itemdataService\n    .findByClientIdAndItemNr(...)`. Match the method name alone.
run B31 "D10 — resolveRefs resolves itemdata per position (unknown SKU rejected pre-persist)" \
    file_contains 'findByClientIdAndItemNr\(' "$SVC"
run B32 "D10 — service test covers an unknown SKU" \
    file_contains 'validateThrowsWhenSkuUnknown' "$SVC_TEST"

echo

# --- Fix C — the gated call site in the controller ---------------------------

# The gate legitimately carries intervening conjuncts (the empty-positions skip), so this must not
# demand the two clauses be adjacent — only that they are &&-ed in the SAME expression. Bounded to
# 400 chars so it cannot pair a type check with an isAutoReceiveEnabled() call from elsewhere.
run C1 "Fix C — controller gates auto-receive on RETURN && the kill switch" \
    file_contains_ordered 'AdviceType\.RETURN\.equals\((?:(?!;).){0,400}?&&(?:(?!;).){0,400}?returnAdviceAutoReceiveService\.isAutoReceiveEnabled\(\)' "$CTRL"
run C2 "Fix C — controller invokes validate() with the DTO" \
    file_contains 'returnAdviceAutoReceiveService\.validate\(\s*adviceDto\s*\)' "$CTRL"
run C3 "Fix C — controller invokes execute()" \
    file_contains 'returnAdviceAutoReceiveService\.execute\(' "$CTRL"
run C4 "Fix C — ReturnAdviceAutoReceiveService is constructor-injected" \
    file_contains_ml 'public\s+AdviceRestController\((?:[^)]*\n)*?[^)]*ReturnAdviceAutoReceiveService' "$CTRL"
run C5 "Fix C — the field is assigned in the constructor" \
    file_contains 'this\.returnAdviceAutoReceiveService\s*=' "$CTRL"

# R9 / ORDERING — the single most important structural assertion in this script.
# validate() MUST be invoked BEFORE adviceRepository.save(...). If it runs after, a rejected
# advice has already committed externalid=RETURN{parcel_id} and every OMS retry then dies on the
# duplicate guard at :139-142, leaving the return unmanageable without DB intervention.
run C6a "R9 — validate() appears before a save (necessary, NOT sufficient — see C6b)" \
    file_contains_ordered 'returnAdviceAutoReceiveService\.validate\(.*?adviceRepository\.save\(' "$CTRL"
# C6a alone false-positives: adviceRepository.save( occurs at :198, :369 (createTransfer) and :494
# (createHubAndSpoke), so a validate() placed AFTER :198 still matches against the :369 save under /s.
# save(adviceEntity) occurs exactly once (:198), so the negative direction is the sound assertion.
# Compound so it cannot pass vacuously: the validate() call must EXIST, and save(adviceEntity)
# must not precede it. A bare negative passes when validate() is absent entirely.
check_C6b() {
    file_contains 'returnAdviceAutoReceiveService\.validate\(' "$CTRL" \
        && file_not_contains_ordered 'adviceRepository\.save\(\s*adviceEntity\s*\).*?returnAdviceAutoReceiveService\.validate\(' "$CTRL"
}
run C6b "R9 — validate() exists AND save(adviceEntity) does not precede it (sound ordering)" \
    check_C6b

# ADJACENCY — the gate and the auto-receive calls must live in the same guarded block, not merely
# coexist in the file. Replaces an earlier `file_not_contains 'receivingService.receiveGoods('`
# check, which was VACUOUS: Fix B deliberately moves receiveGoods out of the controller, so the
# negative passed by construction whether or not the gate existed.
# NOTE — C7 proves textual PROXIMITY, not block membership: under /s it would still pass with
# validate() sitting outside the `if`. C6b is the only sound structural check here. Kept as a cheap
# smoke test that the gate and the call were not written in unrelated parts of the method.
run C7 "Fix C — the switch gate and validate() are textually adjacent (weak proximity smoke test)" \
    file_contains_ordered 'isAutoReceiveEnabled\(\).{0,400}?returnAdviceAutoReceiveService\.validate\(' "$CTRL"
# Exactly one receiveGoods call-site in the service — proves the loop was not duplicated or
# accidentally left in the controller as well.
run C8 "Fix B — exactly ONE receiveGoods call-site in the service" \
    bash -c '[ "$(grep -cE "receivingService\.receiveGoods\(" '"$SVC"' 2>/dev/null || echo 0)" -eq 1 ]'
# The :151-156 comment claims RETURN advice "is eventually received via the mobile /receive path",
# which after this change is true only when the switch is OFF. Anchor on the ticket id so a
# file-wide match on some unrelated word cannot satisfy it.
run C9 "Fix C — stale ':151-156' comment refreshed (mentions SBDEV-2778)" \
    file_contains 'SBDEV-2778' "$CTRL"
run C10 "Fix B2a — isPrintAvailable checked in the service (CUPS-down fails before any receive)" \
    file_contains 'isPrintAvailable\(' "$SVC"
# D3 — printer_id must actually be READ now. AdviceDto already declares it (:41-42); the defect was
# that nothing consumed it. Assert the read, not the declaration.
run C11 "D3 — printer_id is now read from the DTO (was accepted and discarded)" \
    bash -c 'grep -qE "getPrinterId\(\)" '"$CTRL"' 2>/dev/null || grep -qE "getPrinterId\(\)" '"$SVC"' 2>/dev/null'
run C12 "D3 — AdviceDto still declares printer_id (contract unchanged)" \
    file_contains '@JsonProperty\("printer_id"\)' "$DTO"

# --- F1b — R9 at the batch level ---------------------------------------------
#
# R9 (C6a/C6b above) only makes the SINGLE-advice case retryable. Across a batch it does not hold:
# create() is not @Transactional and each receive commits in its own tenant tx, so if advice N fails,
# advices 1..N-1 have already moved stock and closed their BOLs while the caller gets ONE 400 for the
# whole request. OMS retries the same body, hits the duplicate guard, and the return is stuck with
# committed inventory behind it — the state R9 exists to prevent, now unclearable by deleting a row.
#
# The guard rejects the shape, because the endpoint can offer neither batch atomicity (no surrounding
# transaction) nor per-advice outcomes (one 204/400 for the list). Provably a no-op for real traffic:
# both return senders hard-code a one-element list, and all 5,226 ADVICE_IMPORT payloads logged on
# wineco-uat + wineco-dev + hydra-dev2 (2020-03-26 .. 2026-07-31) carry exactly one advice.
# Flagged by the independent Codex review lane on PR #123, 2026-08-04.
run C13 "F1b — a batch carrying a RETURN advice alongside another advice is rejected" \
    file_contains_ordered 'returnAdvices\s*>\s*0\s*&&\s*adviceList\.size\(\)\s*>\s*1' "$CTRL"
# Gated on the switch so OFF still restores pre-SBDEV-2778 behavior EXACTLY, batch shapes included.
# Ordering matters: the size test must precede the sysprop read so the single-advice path never pays.
run C14 "F1b — the guard is gated on the kill switch (OFF must not add a new rejection)" \
    file_contains_ordered 'adviceList\.size\(\)\s*>\s*1\s*&&\s*returnAdviceAutoReceiveService\.isAutoReceiveEnabled\(\)' "$CTRL"

echo

# --- Fix E — error codes -----------------------------------------------------
#
# Each new code needs the constant PLUS an arm in BOTH switches: getErrorCodeText (from :1247)
# and getErrorCodeName (~:1320). Hence >=3 occurrences.
#
# Do NOT copy the live bug at NOT_ENABLLED_FOR_RECEIVING = 500 (:1245), which has a
# getErrorCodeText arm (:1294) but is MISSING from getErrorCodeName and silently degrades to the
# generic name. Fixing that one is §10-Q11, not this ticket.

run E1 "WmsConstants declares RETURN_AUTO_RECEIVE_PARTIAL" \
    file_contains 'RETURN_AUTO_RECEIVE_PARTIAL\s*=' "$CONST"
run E2 "RETURN_AUTO_RECEIVE_PARTIAL appears >=3x (constant + BOTH switch arms)" \
    file_contains_n_times 'RETURN_AUTO_RECEIVE_PARTIAL' "$CONST" 3
run E3 "WmsConstants declares PRINTER_NOT_AVAILABLE (it did NOT exist before this ticket)" \
    file_contains 'PRINTER_NOT_AVAILABLE\s*=' "$CONST"
run E4 "PRINTER_NOT_AVAILABLE appears >=3x (constant + BOTH switch arms)" \
    file_contains_n_times 'PRINTER_NOT_AVAILABLE' "$CONST" 3
run E5 "Fix B — bind() exists (validated -> persisted position ids)" \
    file_contains 'public\s+\w+\s+bind\s*\(' "$SVC"
# §6.1 prereq 9 gates production enablement on these counters, so assert each NAME — a single
# `meterRegistry` mention (the old check) passes while four of six counters silently never ship.
run E6 "Observability — MeterRegistry injected" \
    file_contains 'MeterRegistry' "$SVC"
run E7 "Observability — .success counter" \
    file_contains 'wms2\.returns\.autoreceive\.success' "$SVC"
run E8 "Observability — .partial_failure counter" \
    file_contains 'wms2\.returns\.autoreceive\.partial_failure' "$SVC"
run E9 "Observability — .rejected_no_printer counter" \
    file_contains 'wms2\.returns\.autoreceive\.rejected_no_printer' "$SVC"
run E10 "Observability — .rejected_printer_unavailable counter" \
    file_contains 'wms2\.returns\.autoreceive\.rejected_printer_unavailable' "$SVC"
run E11 "Observability — .rejected_no_boxtype counter" \
    file_contains 'wms2\.returns\.autoreceive\.rejected_no_boxtype' "$SVC"
run E12 "Observability — .skipped_switch_off counter" \
    file_contains 'wms2\.returns\.autoreceive\.skipped_switch_off' "$SVC"

# NOTE — the getErrorMap() assertions from the previous revision are GONE ON PURPOSE.
# WebserviceBusinessExceptionClientSide:46-51 emits only status + description, so no WMS error
# code has ever reached OMS. That is a real defect, but it changes EVERY /rest error body and
# needs its own consumer audit, so it moved to §10-Q11 / its own ticket (plan D7). Asserting it
# here would force a cross-cutting change into an urgent, narrowly-scoped PR.

echo

# --- Preserved invariants ----------------------------------------------------
#
# SBDEV-2236's regression value is NOT discarded — it survives as the kill-switch-OFF case.
# Its verify script (4-Archieves/scripts/verify-SBDEV-2236-*.sh) is RETIRED by this ticket (R6);
# its negative assertions encode a contract the BA has withdrawn.

run G1 "2236 guard preserved — the without-auto-receive test still exists (switch-OFF case)" \
    file_contains 'shouldCreateReturnAdviceWithoutAutoReceive' "$CTRL_TEST"
# The `never()` assertions in that test are all negatives, so it can pass VACUOUSLY if the
# retargeted setup stops reaching the RETURN branch at all. A file-wide grep for
# ArgumentCaptor/AdviceState.OPEN also passes vacuously — the fixtures already contain several
# such matches. Anchor on the method name so the captor must appear INSIDE that test.
# Window shrunk 3000 -> 1200 and anchored on ArgumentCaptor: at 3000 chars under /s the match could
# leak past the end of this test into the NEXT one (the rewritten :567 begins immediately after), so a
# neighbour's AdviceState.OPEN would satisfy it without AC8 having a captor at all.
run G2 "2236 guard — the test itself captures the saved entity and asserts state == OPEN" \
    file_contains_ordered 'shouldCreateReturnAdviceWithoutAutoReceive(?:(?!@Test).)*?ArgumentCaptor(?:(?!@Test).)*?AdviceState\.OPEN' "$CTRL_TEST"
# Relaxed: an earlier revision pinned a 60-char Mockito expression including eq( and exact
# formatting, so any reformat of the retargeted test would fail a check about behavior.
run G3 "2236 guard — still asserts state is never set FINISHED when the switch is OFF" \
    file_contains_ordered 'never\(\)\)\.updateAdviceToStateById\(.{0,80}?FINISHED' "$CTRL_TEST"
# ReceivingService must not have been modified to hoist the CUPS check (deliberate follow-up,
# §10-Q6 — flag it here so an unplanned change is visible).
run G4 "ReceivingService.receiveGoods still @Transactional(tenantTransactionManager)" \
    file_contains_ml '@Transactional\(value\s*=\s*"tenantTransactionManager"[^)]*\)\s*\n\s*public\s+void\s+receiveGoods' "$RECV"

# Fix G — the five SBDEV-2236 tests that assert the ABSENCE of auto-receive. Three are inverted
# (renamed) and one deleted, so their old names must be gone. Verified line numbers on the
# pre-fix tree: :524, :567, :608, :650, :686.
run G5 "Fix G — stale 'ignore printer_id' test removed or renamed (:567)" \
    file_not_contains 'void\s+shouldCreateReturnAdviceAndIgnorePrinterId\s*\(' "$CTRL_TEST"
run G6 "Fix G — 'shouldCreateReturnAdviceInOpenState' inverted/renamed (:608)" \
    file_not_contains 'void\s+shouldCreateReturnAdviceInOpenState\s*\(' "$CTRL_TEST"
run G7 "Fix G — 'shouldNotInvokeReceivingServiceForReturnAdvice' inverted/renamed (:650)" \
    file_not_contains 'void\s+shouldNotInvokeReceivingServiceForReturnAdvice\s*\(' "$CTRL_TEST"
# The :58-67 comment justified the unwired ReceivingService/PrinterRepository mocks by citing
# SBDEV-2236. The mocks stay unwired (they live in the new service now) but the reason changed.
run G8 "Fix G — the unwired-mock comment no longer cites SBDEV-2236 as the reason" \
    file_not_contains_ordered 'Retained post-SBDEV-2236' "$CTRL_TEST"

echo

# --- New tests exist --------------------------------------------------------

run T1 "Tests — ReturnAdviceAutoReceiveServiceUnitTest exists" \
    test -f "$SVC_TEST"
run T2 "Tests — AC1 auto-receive on create covered" \
    file_contains 'shouldAutoReceiveReturnAdviceOnCreate' "$CTRL_TEST"
run T3 "Tests — AC2 advice marked FINISHED covered" \
    file_contains 'shouldMarkReturnAdviceFinishedOnCreate' "$CTRL_TEST"
# AC3 is R9's guard at the controller seam: an InOrder proof that validate() runs before save().
run T4 "Tests — AC3 validate-before-save ordering covered" \
    file_contains 'shouldValidateBeforeSavingAdvice' "$CTRL_TEST"
run T5 "Tests — AC3 uses InOrder (a plain verify() proves nothing about ordering)" \
    file_contains 'inOrder\(|InOrder' "$CTRL_TEST"
run T6 "Tests — AC4 REGULAR advice unaffected" \
    file_contains 'shouldNotAutoReceiveRegularAdvice' "$CTRL_TEST"
run T7 "Tests — AC5 switch-OFF skips auto-receive" \
    file_contains 'shouldSkipAutoReceiveForReturnAdviceWhenSwitchOff' "$CTRL_TEST"
run T8 "Tests — AC6 printerId reaches validate()" \
    file_contains 'shouldPassPrinterIdThroughToValidate' "$CTRL_TEST"
run T9 "Tests — AC7 validate() throwing yields 400 with nothing saved" \
    file_contains 'shouldReturn400WhenValidateThrows' "$CTRL_TEST"
run T10 "Tests — AC9 multi-position advice covered" \
    file_contains 'shouldAutoReceiveAllPositionsOfMultiPositionReturnAdvice' "$CTRL_TEST"
# AC12 / R3 — the default-ON landmine, asserted at the controller seam and not only in the service.
run T11 "Tests — AC12 the kill-switch decision is delegated, read once per advice" \
    file_contains 'shouldConsultKillSwitchExactlyOncePerAdvice' "$CTRL_TEST"
# The controller test CANNOT assert default-ON: ReturnAdviceAutoReceiveService is a @Mock there, so
# getSysvalue never reaches the real method. T15 (service test) is the real guard. Also assert the
# controller does not fork the semantics with its own sysprop read.
run T11b "Tests — AC12 asserts the controller does NOT read the switch sysprop itself" \
    file_contains_ordered 'shouldConsultKillSwitchExactlyOncePerAdvice.{0,1400}?never\(\)\)\s*\n?\s*\.getSysvalue' "$CTRL_TEST"
run T12 "Tests — partial-failure case covered in the service test" \
    file_contains 'executeThrowsPartialFailureAndDoesNotMarkFinishedWhenSecondPositionFails' "$SVC_TEST"
run T13 "Tests — CUPS probe asserted to run exactly once per advice (B2a)" \
    file_contains 'validateIsPrintAvailableCalledExactlyOnceForMultiPositionAdvice' "$SVC_TEST"
run T14 "Tests — the exact v1 receiveGoods argument tuple is pinned" \
    file_contains 'executePassesExactV1ArgumentTuple' "$SVC_TEST"
# Fix F unit coverage — absent row is the case that silently reintroduces the bug.
run T15 "Tests — sysprop absent-row case covered in the service test" \
    file_contains 'autoReceiveEnabledWhenSyspropRowAbsent' "$SVC_TEST"
run T16 "Tests — sysprop explicit-false case covered in the service test" \
    file_contains 'autoReceiveDisabledWhenSyspropFalse' "$SVC_TEST"
run T17 "Tests — F1b a RETURN advice batched with another advice is rejected" \
    file_contains 'shouldRejectReturnAdviceBatchedWithAnotherAdvice' "$CTRL_TEST"
run T18 "Tests — F1b two RETURN advices in one request are rejected" \
    file_contains 'shouldRejectMultipleReturnAdvicesInOneRequest' "$CTRL_TEST"
# The switch-OFF acceptance case is what stops F1b from quietly becoming an unconditional
# behavior change; without it the guard could tighten the kill-switch path unnoticed.
run T19 "Tests — F1b switch-OFF still accepts a mixed batch (kill switch stays faithful)" \
    file_contains 'shouldAcceptBatchedReturnAdviceWhenSwitchOff' "$CTRL_TEST"
run T20 "Tests — F1b a multi-advice REGULAR batch is untouched (no re-cap of bulk imports)" \
    file_contains 'shouldAcceptMultiAdviceRegularBatch' "$CTRL_TEST"

echo

# --- Targeted tests (slow; opt in with RUN_MVN=1) ---------------------------
# NOTE: `mvn test` MUTATES the tracked archunit_store — `git checkout` it afterwards.
# NOTE: clean-develop baseline is 2/4442 failing (OptionalSafetyArchTest,
#       MobilePalletizingServiceTest); those are NOT caused by this change.
# NOTE: AdviceRestControllerUnitTest uses @Nested — never use -Dtest='Outer#method',
#       it silently no-ops and reports a false green.
# NOTE: Surefire -Dtest overrides the *IntegrationTest exclude — do not name the @Disabled IT.

if [ "$RUN_MVN" = "1" ]; then
    run M1 "AdviceRestControllerUnitTest passes" mvn_test_passes AdviceRestControllerUnitTest
    run M2 "ReturnAdviceAutoReceiveServiceUnitTest passes" mvn_test_passes ReturnAdviceAutoReceiveServiceUnitTest
    run M3 "ReceivingControllerUnitTest passes (dock-receive regression)" mvn_test_passes ReceivingControllerUnitTest
    run M4 "FileImportControllerUnitTest passes (RETURN stays create-only — v1 parity)" mvn_test_passes FileImportControllerUnitTest
    run M5 "SyspropMigrationDescriptionWidthTest passes (V2.2.09 fits varchar(255))" mvn_test_passes SyspropMigrationDescriptionWidthTest
else
    echo "  ** WARNING: RUN_MVN=0. Every T* check is a NAME-ONLY grep, so sixteen EMPTY test methods"
    echo "  ** with the right names would satisfy '0 fail' while asserting nothing. The plan's §9"
    echo "  ** acceptance line REQUIRES RUN_MVN=1 (§6.2 step 13). This run is a fast pre-check only."
    skip M1 "AdviceRestControllerUnitTest passes" "set RUN_MVN=1 to run"
    skip M2 "ReturnAdviceAutoReceiveServiceUnitTest passes" "set RUN_MVN=1 to run"
    skip M3 "ReceivingControllerUnitTest passes" "set RUN_MVN=1 to run"
    skip M4 "FileImportControllerUnitTest passes" "set RUN_MVN=1 to run"
    skip M5 "SyspropMigrationDescriptionWidthTest passes" "set RUN_MVN=1 to run"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"

[ "$FAIL" -eq 0 ]
