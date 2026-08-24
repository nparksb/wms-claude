#!/usr/bin/env bash
# verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh
#
# Machine-checkable acceptance for the PAIRED plans:
#   sbdocs/1-Projects/wms1/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md  (Fixes A[+C],D,H — Fix B DROPPED; Fix E DEFERRED, so no E row exists here)
#   sbdocs/1-Projects/wms2/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md  (Fixes D,F,G + P1-P3 pins; Fix E has NO row — E1 was deleted when Q1 rejected merge-into-existing-UL)
#
# This script spans FOUR repos. Point each root at a worktree (or a symlink
# shadow root) — never at a main checkout you have not branched:
#
#   $ V1_API=~/dev/wms-claude/.claude/worktrees/wms-api/SBDEV-3003 \
#     V2_API=~/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3003 \
#     V1_UI=~/dev/wms-claude/.claude/worktrees/wms-mobile-ui/SBDEV-3003 \
#     V2_UI=~/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-3003 \
#     bash sbdocs/9-System/scripts/verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh
#
# Exit 0 only when every check passes. Paste the final "Result:" line into the
# completion report — a prose "DONE" is not acceptance.
#
# RUN IT BEFORE THE FIRST CODE CHANGE to capture the FAIL baseline. Most rows
# below assert state that does not exist yet and MUST be red on arrival; a row
# that is green on the unfixed tree is a broken row, not a completed fix.
#
# The M rows shell out to maven. v1 needs JDK 8, v2 needs JDK 21:
#   export JAVA_HOME=~/.sdkman/candidates/java/21.0.11-ms
#   export PATH="$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH"
# Set SKIP_MVN=1 for a fast code-shape-only pass.
#
# SCOPE NOTES
#  * v2's StockunitBusinessService is ALREADY correct on the quantity defect. Rows
#    P1/P2/P3 are REGRESSION PINS on that existing behaviour, so they are expected to
#    pass on arrival — they are the THREE rows exempt from the all-red baseline. Their
#    value is only realised by mutation-checking them (see the plan §5 AC-4). CORRECTED 2026-08-20:
#    the previous note claimed "P1 and P3 were confirmed to go red when the v1 stale operand was
#    reinstated at v2 :373". That was FALSE for P3 — re-measured, P1 goes red and P3 stayed GREEN,
#    because the old P3 pattern keyed on a variable name that does not occur at :373. Whatever
#    mutation was originally run had been shaped to the row rather than to the defect. P3 has been
#    rewritten below and re-measured red on the same mutant. P2 correctly holds: it pins the lock,
#    an independent axis from the operand.
#  * DESIGN REVERSAL 2026-08-20: the pessimistic-lock approach was dropped. Rows asserting
#    findByIdForUpdate call sites in v1 (old A3/A4/B1/B2) and the "locks before the guard" wording
#    (old C1) were DELETED or rewritten — under the accepted design they could never go green, which
#    is indistinguishable from unfinished work. v2's P2 pin legitimately keeps its lock assertion,
#    because v2 really does lock.
#  * Fix D is scoped to the Move Stock components in this ticket. The other 26
#    unguarded scan components per UI are recorded in the plans, NOT asserted here.
#    That is a deliberate coverage cap — do not read a green run as "all guarded".

set -u

V1_API="${V1_API:-/home/nampark/dev/wms-claude/v1/wms-api}"
V2_API="${V2_API:-/home/nampark/dev/wms-claude/v2/wms2-api}"
V1_UI="${V1_UI:-/home/nampark/dev/wms-claude/v1/wms-mobile-ui}"
V2_UI="${V2_UI:-/home/nampark/dev/wms-claude/v2/wms2-mobile-ui}"

PASS=0
FAIL=0
SKIP=0

run() {
    local id=$1 desc=$2
    shift 2
    if "$@" >/dev/null 2>&1; then
        printf "  PASS  %-7s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else
        printf "  FAIL  %-7s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1))
    fi
}

skip() {
    local id=$1 desc=$2 reason=$3
    printf "  SKIP  %-7s  %s  (%s)\n" "$id" "$desc" "$reason"; SKIP=$((SKIP+1))
}

# --- assertion helpers -------------------------------------------------------
# Every helper fails CLOSED on a missing file. The perl and "not_contains"
# helpers would otherwise report PASS for a file that does not exist, which
# false-greens every assertion about a file a refactor moved or renamed.

file_contains()     { [ -f "$2" ] || return 1; grep -qE "$1" "$2"; }
file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }
# Comment-stripping variants (added 2026-08-20, row-discrimination lane). Strip comment lines
# BEFORE matching, so a comment can neither satisfy a negative row nor stand in for the code a
# positive row requires. This closes the trap that false-greened G2 on shadow B3b, where a TODO
# comment naming "a duplicate_transfer Counter registered on the injected MeterRegistry" was
# indistinguishable from the implementation.
code_contains()     { [ -f "$2" ] || return 1; grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" | grep -qiE "$1"; }
code_not_contains() { [ -f "$2" ] || return 1; ! { grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" | grep -qiE "$1"; }; }

# Multi-line (whole-file) regex. Perl exits 0 when it cannot open the file, so
# the -f guard is mandatory, not defensive.
#
# The pattern is passed through the ENVIRONMENT, never interpolated into the perl
# source. Both alternatives are actively broken and were MEASURED broken here:
#   perl -0777 -ne "exit(/$1/s ? 0 : 1)"
#     1. a pattern containing `//` (any Java-comment tolerance group) TERMINATES the
#        m// literal, so perl dies and the row is permanently red. This is how the
#        B1 row read as an honest FAIL against correctly-patched code.
#     2. a regex literal interpolates perl variables, so `@Transactional` is parsed
#        as an ARRAY and silently flattens to the empty string — the row then matches
#        far too much. Any pattern with @ or $ is affected, i.e. every annotation.
# Passing it as data fixes both classes at once.
file_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_RE="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_RE}/s ? 0 : 1)' "$2"
}
file_not_contains_ml() {
    [ -f "$2" ] || return 1
    VERIFY_RE="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_RE}/s ? 1 : 0)' "$2"
}

# Comment-stripped multiline variant (added 2026-08-20 for the G-e / G-f rows). Same
# pattern-as-data discipline as file_contains_ml, plus the comment strip — needed because a
# TODO naming the very construct a row requires would otherwise satisfy it. Measured: shadow
# Be1 is comment-only and its TODO contains the literal "(requireAuth || v3Scope)".
code_contains_ml() {
    [ -f "$2" ] || return 1
    grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" \
        | VERIFY_RE="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_RE}/s ? 0 : 1)'
}

# Tree-scoped grep under an explicit root — refactor-proof, so the row survives
# code moving between files inside the same repo.
tree_contains()     { [ -d "$2" ] || return 1; grep -rqE "$1" "$2"; }
tree_not_contains() { [ -d "$2" ] || return 1; ! grep -rqE "$1" "$2"; }

# The verify-plan-template version of this is BROKEN: it pipes `mvn -q` into a
# grep for "BUILD SUCCESS|Tests run", but -q suppresses both, so maven exits 0
# while the grep matches nothing and the row is permanently red. Use the EXIT
# CODE, and additionally require a real surefire summary with Skipped: 0 so a
# @Disabled class cannot certify itself green.
mvn_test_passes() {
    local root=$1 cls=$2 min=${3:-1} out rc count
    [ -d "$root" ] || return 1
    out=$(cd "$root" && mvn test -Dtest="$cls" -DfailIfNoTests=false \
            -Djacoco.skip=true -Dmaven.javadoc.skip=true 2>&1); rc=$?
    [ "$rc" -eq 0 ] || return 1
    count=$(printf '%s' "$out" \
        | grep -oE "Tests run: [0-9]+, Failures: 0, Errors: 0, Skipped: 0" \
        | grep -oE "[0-9]+" | sort -rn | head -1)
    [ -n "$count" ] && [ "$count" -ge "$min" ]
}

mvn_compiles() {
    [ -d "$1" ] || return 1
    (cd "$1" && mvn -q clean compile -Djacoco.skip=true -Dmaven.javadoc.skip=true) >/dev/null 2>&1
}

# --- paths -------------------------------------------------------------------
V1_SBS="$V1_API/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java"
V1_SUS="$V1_API/src/main/java/net/aim_ai/wms/service/StockunitService.java"
V2_SBS="$V2_API/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java"
V2_SUS="$V2_API/src/main/java/net/aim_ai/wms/service/StockunitService.java"
V2_OLR="$V2_API/src/main/java/net/aim_ai/wms/util/OptimisticLockRetry.java"
V2_SUC="$V2_API/src/main/java/net/aim_ai/wms/controller/StockUnitController.java"
V2_IDEMP="$V2_API/src/main/java/net/aim_ai/wms/landlord/config/IdempotencyFilter.java"
V2_RIS="$V2_API/src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java"
V1_SCAN="$V1_UI/components/moveStock/scanDestination.vue"
V2_SCAN="$V2_UI/components/moveStock/scanDestination.vue"
V1_AMT="$V1_UI/components/moveStock/inputAmount.vue"
V2_AMT="$V2_UI/components/moveStock/inputAmount.vue"
V2_STORE="$V2_UI/store/moveStock.js"

echo
echo "SBDEV-3003 — Move Stock lost update / phantom unit loads"
echo "  V1_API=$V1_API"
echo "  V2_API=$V2_API"
echo "  V1_UI=$V1_UI"
echo "  V2_UI=$V2_UI"
echo

# =============================================================================
echo "Fix A (+C) — v1: value and version must come from ONE snapshot (no lock; see plan §4)"
# =============================================================================
# A1 — the DEFECT CLASS as a generic negative: no `X.setAmount( Y.getAmount()` where Y is a
# DIFFERENT variable than X. Perl negative-lookahead + backreference, so it is name-agnostic.
#
# NOTE ON A PREVIOUS BROKEN VERSION OF THIS ROW: it forbade the literal substring
# `setAmount(sourceStockunit.getAmount().subtract`. Under the accepted design the CORRECT code is
# `sourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount))`, which CONTAINS that
# substring — so the row was permanently red and indistinguishable from unfinished work. Caught only
# by running the script against a patched shadow. Keep this row semantic, never substring-literal.
run A1 "v1 SBS: no setAmount whose operand is a DIFFERENT object than its receiver" \
    file_not_contains_ml '\b(\w+)\.setAmount\(\s*(?!\1\b)\w+\.getAmount\(\)' "$V1_SBS"

# A2 uses a BACKREFERENCE so the row asserts the *semantic* property — the object
# written is the object read — instead of pinning a variable name the implementer
# is free to choose. Refactor-proof and rename-proof.
# A2/P1 route through the perl helper, not grep -E. ERE backreferences (\1) are a GNU extension:
# POSIX does not define them, BSD/macOS grep and ugrep REJECT them outright ("invalid escape \1"),
# and a shell that exports a grep wrapper function is enough to trigger it. P1 is a REGRESSION PIN,
# so a portability-induced red there would read as "the v1 defect is back in v2".
run A2 "v1 SBS: a subtract whose receiver IS its own operand exists" \
    file_contains_ml '\b([A-Za-z_][A-Za-z0-9_]*)\.setAmount\(\s*\1\.getAmount\(\)\.subtract\(' "$V1_SBS"

# A3: the source must be re-fetched IN-TRANSACTION and the write must target that same
# instance. Design B takes NO lock, so a findByIdForUpdate row here would be permanently red.
# Assert instead that the rebind exists: sourceStockunit is reassigned from a repository fetch.
run A3 "v1 SBS: sourceStockunit is rebound from an in-tx repository fetch" \
    file_contains 'sourceStockunit = stockunitRepository\.findBy' "$V1_SBS"

# A4: containment — the rebind must happen INSIDE transferStockToUnitLoad, not in some other
# method. Tempered-greedy gap ([^\n] plus a newline not followed by a 4-space `public `) so the
# match cannot wander past the method boundary and false-green.
run A4 "v1 SBS: the rebind occurs inside transferStockToUnitLoad" \
    file_contains_ml 'transferStockToUnitLoad\(Stockunit(?:[^\n]|\n(?!    public ))*?sourceStockunit = stockunitRepository\.findBy' "$V1_SBS"

echo
# =============================================================================
echo "Fix C (folded into A) — availability guard must read the re-fetched instance"
# =============================================================================
# The guard must appear AFTER the rebind, inside the same method. Under the old design this row
# asserted "locks before the guard"; design B takes no lock, so that wording could never go green.
run C1 "v1 SBS: available-amount guard sits AFTER the in-tx rebind" \
    file_contains_ml 'sourceStockunit = stockunitRepository\.findBy(?:[^\n]|\n(?!    public ))*?requested is more than available' "$V1_SBS"

echo
# =============================================================================
echo "Fix D — mobile UI in-flight submit guard (Move Stock only, see SCOPE NOTES)"
# =============================================================================
for pair in "D1:$V2_SCAN:v2" "D2:$V1_SCAN:v1"; do
    id="${pair%%:*}"; rest="${pair#*:}"; f="${rest%:*}"; ver="${rest##*:}"
    run "$id" "$ver scanDestination.vue: submitting flag declared in data()" \
        file_contains_ml 'data\(\)\s*\{(?:[^\n]|\n(?!  \},))*?submitting:\s*false' "$f"
    # The `\{?\s*` is load-bearing. v1 writes the guard on one line; v2's was introduced by
    # SBDEV-2994 as a braced block (`if (this.submitting) {\n  return\n}`). Requiring `return`
    # immediately after the paren made this row red against a v2 file that genuinely has the guard —
    # a stale row reading as unfinished work. Do NOT "fix" that by reformatting the component.
    run "${id}b" "$ver scanDestination.vue: submit() early-returns while in flight" \
        file_contains_ml 'submit\s*\((?:[^\n]|\n(?!    \},))*?if\s*\(\s*this\.submitting\s*\)\s*\{?\s*return' "$f"
    run "${id}c" "$ver scanDestination.vue: Submit button is :disabled by submitting" \
        file_contains ':disabled="submitting"' "$f"
    # D1d/D2d NARROWED 2026-08-20 after a negative test. The row used to grep for any
    # `await this.$store.dispatch`, which SBDEV-2994's destination PROBE already satisfies — so it,
    # D1 and D1b all passed against the unfixed v2 file and could not tell "the probe is guarded"
    # from "the transfer is guarded". Name the transfer dispatch explicitly. Measured: red on
    # origin/develop 7f83d55, green after the fix.
    run "${id}d" "$ver scanDestination.vue: the TRANSFER dispatch is awaited" \
        file_contains 'await this\.\$store\.dispatch\(.moveStock/transferStock' "$f"
    # D1e/D2e — and it is wrapped by the flag. Adjacency is asserted deliberately rather than with a
    # wide gap: under /s an unbounded `.*?` would happily match a `submitting = true` from the probe
    # block above and a `finally` from anywhere below, which is the same false green the row exists
    # to prevent.
    # The gap before `finally` PERMITS an intervening catch. Forbidding it would false-red a correct
    # implementation that toasts the error — not hypothetical: this very file uses try/catch/finally
    # 60 lines earlier for the destination probe, and the transfer block passes today only because it
    # happens to omit the catch. Still tempered (no `},` = cannot leave the method), so it cannot
    # pair a `submitting = true` here with a `finally` belonging to some other method.
    run "${id}e" "$ver scanDestination.vue: the transfer dispatch is wrapped by the flag" \
        file_contains_ml 'this\.submitting\s*=\s*true\s*\n(?:\s*//[^\n]*\n)*\s*try\s*\{\s*\n(?:\s*//[^\n]*\n)*\s*await this\.\$store\.dispatch\(.moveStock/transferStock.(?:[^\n]|\n(?!    \},))*?finally\s*\{\s*\n\s*this\.submitting\s*=\s*false' "$f"
done

# inputAmount.vue is the wizard step BEFORE the destination scan and was changed by the same fix in
# both repos — its submit() awaits moveStock/selectStockUnit, so it has its own in-flight window.
# Added 2026-08-20: the original script asserted scanDestination only, so a half-applied Fix D
# (guard on one screen, not the other) would have passed.
for pair in "D4:$V2_AMT:v2" "D5:$V1_AMT:v1"; do
    id="${pair%%:*}"; rest="${pair#*:}"; f="${rest%:*}"; ver="${rest##*:}"
    run "$id" "$ver inputAmount.vue: submitting flag declared in data()" \
        file_contains_ml 'data\(\)\s*\{(?:[^\n]|\n(?!  \},))*?submitting:\s*false' "$f"
    run "${id}b" "$ver inputAmount.vue: submit() early-returns while in flight" \
        file_contains_ml 'submit\s*\((?:[^\n]|\n(?!    \},))*?if\s*\(\s*this\.submitting\s*\)\s*\{?\s*return' "$f"
    run "${id}c" "$ver inputAmount.vue: Submit button is :disabled by submitting" \
        file_contains ':disabled="submitting"' "$f"
    # The flag must be cleared in a finally, not after the await: a bare clear leaves the screen
    # permanently disabled after one network blip. Mutation-checked (plan §9).
    run "${id}d" "$ver inputAmount.vue: the flag is released in a finally" \
        file_contains_ml 'this\.submitting\s*=\s*true(?:[^\n]|\n(?!    \},))*?finally\s*\{\s*\n\s*this\.submitting\s*=\s*false' "$f"
done

echo
# =============================================================================
echo "Fix E / G — v2: no unconditional createUnitload per request; endpoint dedupe"
# =============================================================================
# ROW E1 DELETED 2026-08-20. It asserted that the pallet branch stops minting a unit load per
# request — i.e. merge-into-existing-UL, which Q1 explicitly REJECTED (it would change UL granularity
# and MANUAL_SPLIT report counts). Under the accepted design StockunitService:192 is deliberately
# unchanged and dedupe happens above the controller, so the row could never legitimately go green,
# which is indistinguishable from unfinished work. Same reasoning that deleted the v1 lock rows.
#
# =============================================================================
# SLICE 2 ROWS — REPLACED WHOLESALE 2026-08-20 after an adversarial measurement lane.
#
# The previous four rows (G1, G1b, G2, G3) were each MEASURED untrustworthy against 18 shadow
# implementations: 12 of 16 broken shadows scored a FULL GREEN (39 pass, 0 fail), i.e. a verdict
# indistinguishable from a correct implementation. Full record and the matrix:
#   sbdocs/1-Projects/wms2/plan/reviews/SBDEV-3003-slice2-row-discrimination.md
# Worst case was the old G1b: it false-greened B2 (auto-derive ungated), the ONE defect it existed
# to catch, because a counter guard `if (v3Scope)` elsewhere in the method supplied the identifier
# it grepped for — while also false-REDDING a correct implementation that renamed the boolean.
#
# These twelve rows were measured at 0 false greens and 0 false reds across all 18 shadows.
# G1c and G3d are GUARD rows: they legitimately PASS on the pristine tree and are exempt from the
# all-red baseline (joining P1-P3). Never read a green G1c alone as "the allow-list is right" —
# it is only meaningful paired with G1, the progress row.
#
# Every row is a named function or a documented helper call, never an inline `bash -c`: the lane's
# first drafts of G2a and G4 were written that way and both false-REDDED the correct shadow purely
# from quoting (grep -E ignores an inline (?i); `\$_` inside a nested double-quoted perl mangles).
# A row red for a quoting reason is the "exit 127 reads as an honest FAIL" trap in a different coat.
# =============================================================================

# --- Scope -------------------------------------------------------------------
# The exact path as a COMPLETE string literal on a CODE line. Both halves are load-bearing: the
# closing quote (else "/v3/stockUnit/transferStockToUnitLoad" satisfies it — measured on B8, and
# transferStockToUnitLoad is a REAL symbol in StockunitBusinessService, so that is a live
# confusion), and the ^[^/*]* comment exclusion (else a TODO satisfies it — measured on B3/B3b).
run G1 "v2 IdempotencyFilter: the exact /v3 transfer path is enrolled on a code line" \
    file_contains '^[^/*]*"/v3/stockUnit/transferStock"' "$V2_IDEMP"

# G1c (GUARD) — scope is an allow-list, NOT a /v3 prefix. Three conjuncts over comment-stripped
# source: (1) every /v3 literal in code IS the allow-listed path (catches B1's "/v3/" constant and
# B8's wrong path); (2) no prefix/regex test naming v3; (3) every startsWith targets a "/rest
# literal — which is what catches B15, an anyMatch(uri::startsWith) over the full-path allow-list
# that has B1's blast radius while keeping the exact path as its only /v3 literal.
# Conjunct 3 is an intentional tripwire: any new non-/rest prefix test reds this row and forces a
# decision instead of silently widening scope.
g1c_allowlist_not_prefix() {
  local f=$1 code
  [ -f "$f" ] || return 1
  code=$(grep -vE '^[[:space:]]*(//|\*|/\*)' "$f")
  printf '%s\n' "$code" | grep -oE '"/v3[^"]*"' \
    | grep -vxF '"/v3/stockUnit/transferStock"' | grep -q . && return 1
  printf '%s\n' "$code" | grep -qiE '(startsWith|regionMatches|indexOf|matches)\([^)]*v3' && return 1
  printf '%s\n' "$code" | grep -oE 'startsWith.{0,7}' \
    | grep -v '^startsWith("/rest' | grep -q . && return 1
  return 0
}
run G1c "v2 IdempotencyFilter: scope is a one-path allow-list, NOT a /v3 prefix" \
    g1c_allowlist_not_prefix "$V2_IDEMP"

# --- Key policy --------------------------------------------------------------
# G1b asserts the code SHAPE and names NO implementation identifier (the old version's fatal flaw).
# Between the header lookup and the auto-derive there must be an INTERMEDIATE branch that either
# fails open (chain.doFilter, plan G-b(i)) or rejects (SC_BAD_REQUEST, G-b(ii)) — the alternation
# deliberately does not pre-judge which option the plan settles on. Requiring
# `key = sha256HexComposite(` as the final else also pins that auto-derive stays REACHABLE for
# /rest/**, so the row cannot be satisfied by deleting it. The [ ]{8,} floors exclude javadoc.
run G1b "v2 IdempotencyFilter: an intermediate scope branch skips auto-derive (auto-derive kept for /rest)" \
    file_contains_ml 'getHeader\(IDEMPOTENCY_HEADER\)(?:[^\n]|\n(?!    \}))*?\n[ ]{8,}\} else if \((?:[^\n]|\n(?!    \}))*?(?:chain\.doFilter\(|SC_BAD_REQUEST)(?:[^\n]|\n(?!    \}))*?\n[ ]{8,}key = sha256HexComposite\(' "$V2_IDEMP"

# G1d — and that branch tests the SAME boolean computed from the request path. BACKREFERENCE, so
# it is name-agnostic and a rename stays green (measured on C2). Without this row G1b's shape is
# satisfied by an else-if on any unrelated condition while an allow-listed path keeps
# auto-deriving — measured on B16.
run G1d "v2 IdempotencyFilter: the intermediate branch tests the path-derived scope flag" \
    file_contains_ml 'final boolean (\w+) = \w+\((?:[^\n]|\n(?!    \}))*?\n[ ]{8,}\} else if \(\1\)' "$V2_IDEMP"

# --- Counter -----------------------------------------------------------------
# RETARGETED to RestIdempotencyService 2026-08-20, from IdempotencyFilter. These three rows used
# to grade the FILTER, which contradicted the plan's own G-d ("put it in RestIdempotencyService,
# not the filter") — so implementing the plan as written would have redded them, the same
# "satisfiable only by writing code in the wrong place" defect the original G1 had on this ticket.
# The plan is right, and it is now PROVEN rather than argued: a shadow with the counter in the
# filter FAILS `mvn clean compile` — SecurityConfiguration:161 `cannot find symbol: meterRegistry`,
# because the filter is `new`-ed there and is not a Spring bean. With the counter in the service
# (a real @Service), SecurityConfiguration needs no change and the build is SUCCESS.
# Registered AND incremented in ONE chain, starting on a code line at >= 4-space indent.
# Catches B4 (register with .increment() deleted) and both comment-only shadows.
run G2 "v2 IdempotencyFilter: the counter is registered AND incremented in one chain" \
    file_contains_ml '\n[ ]{4,}(?:Counter\.builder\(|\w*[Rr]egistry\.counter\()(?:[^\n]|\n(?!    \}))*?\.increment\(\)' "$V2_RIS"

# G2a — and it is the DUPLICATE-TRANSFER counter, named on a CODE line. code_contains strips
# comments, which is the whole difference from the old row: on B3b a TODO comment naming
# "a duplicate_transfer Counter registered on the injected MeterRegistry" greened the old G2
# outright, and B3 only stayed red by accident of that comment's word order.
run G2a "v2 IdempotencyFilter: the counter name identifies duplicate transfers (code, not a TODO)" \
    code_contains '(duplicate[_.]?transfer|transfer[_.]duplicate|idempotency[_.]duplicate)' "$V2_RIS"

# G2b RETARGETED to RestIdempotencyService 2026-08-20 — see the note above the counter rows.
# It fires on the RIGHT outcomes: the statement immediately before `return ClaimResult.REPLAYED`
# and before `return ClaimResult.IN_FLIGHT` must be a counting call, and there must be NO such
# call before `return ClaimResult.CLAIMED`. That third, NEGATIVE conjunct is what catches an
# increment on CLAIMED, which counts successes as duplicates and inverts the metric (shadow B4bp);
# an order-only regex over the method cannot see it. `count\w*\(|counter\(|increment\(` keeps the
# row name-agnostic — a direct meterRegistry.counter(...).increment() satisfies it as readily as a
# countDuplicate(...) helper.
g2b_counter_on_dedupe_outcomes() {
  local f=$1
  [ -f "$f" ] || return 1
  code_contains_ml '(?:count\w*\(|counter\(|increment\()[^;]*;\s*return ClaimResult\.REPLAYED'  "$f" || return 1
  code_contains_ml '(?:count\w*\(|counter\(|increment\()[^;]*;\s*return ClaimResult\.IN_FLIGHT' "$f" || return 1
  code_contains_ml '(?:count\w*\(|counter\(|increment\()[^;]*;\s*return ClaimResult\.CLAIMED'   "$f" && return 1
  return 0
}
run G2b "v2 RestIdempotencyService: the counter fires on REPLAYED and IN_FLIGHT, never on CLAIMED" \
    g2b_counter_on_dedupe_outcomes "$V2_RIS"

# --- Bridge-mode immunity (plan §2) ------------------------------------------
# Both halves are required because either alone is inert: the filter must pass a per-request
# suppression argument to tryClaim (a 5th arg after bodyHash) AND the service's bridge branch must
# be conjoined with it. Asserting the property bridge-mode=false would be a CONFIG claim, not a
# code guarantee. The [^;]*? gap keeps the match inside one statement while tolerating the nested
# parens of request.getMethod() / request.getRequestURI().
g4_bridge_mode_immunity() {
  local f=$1 s=$2
  [ -f "$f" ] && [ -f "$s" ] || return 1
  file_contains_ml 'tryClaim\([^;]*?bodyHash,\s*[!\w]' "$f" || return 1
  file_contains '^[^/*]*if \(bridgeMode[ )]*&&' "$s" || return 1
  return 0
}
run G4 "v2: the allow-listed path is immune to bridge mode (filter arg + service conjunct)" \
    g4_bridge_mode_immunity "$V2_IDEMP" "$V2_RIS"

# --- Client (wms2-mobile-ui store/moveStock.js) ------------------------------
# The header is actually SENT on the transferStock POST: the $post for that path, a headers object,
# and the header name, all inside the one action body (tempered on `\n  },`).
run G3 "v2 store/moveStock.js: the Idempotency-Key header is sent on the transferStock POST" \
    file_contains_ml '\$post\(.\/stockUnit\/transferStock.(?:[^\n]|\n(?!  \},))*?headers(?:[^\n]|\n(?!  \},))*?.Idempotency-Key.' "$V2_STORE"

# G3b — the two 409s are discriminated on the response BODY, and there is NO status-only 409 branch.
# Plan §3: "a blanket 'suppress 409' is a defect, not the fix" — the third conjunct is what encodes
# that, by FORBIDDING `status === 409`. Catches B5 (blanket suppress) and B11 (no discrimination).
g3b_two_409s_discriminated() {
  local f=$1
  [ -f "$f" ] || return 1
  code_contains 'idempotency-in-flight'    "$f" || return 1
  code_contains 'idempotency-key-conflict' "$f" || return 1
  code_not_contains 'status *={2,3} *409'  "$f" || return 1
  return 0
}
run G3b "v2 store/moveStock.js: both dedupe 409s discriminated by body, no status-only branch" \
    g3b_two_409s_discriminated "$V2_STORE"

# G3c — the nonce is per INTENT, not per attempt. Four conjuncts:
#   1. module-scope state (`let x = null`) — NOT Vuex state: the whole Vuex root is persisted to
#      localStorage['vuex-mobile'], so a persisted nonce would replay a later deliberate move for
#      the server's full 7-day retention window (cf. SBDEV-2726, same file family);
#   2. cleared in the initialize mutation, so the NEXT intent gets a fresh nonce;
#   3. NOT minted inside the transferStock action (catches B6, per-attempt nonce);
#   4. NOT dropped in a finally, which hands every retry a fresh nonce (catches B17).
g3c_nonce_per_intent() {
  local f=$1
  [ -f "$f" ] || return 1
  file_contains '^let [A-Za-z_][A-Za-z0-9_]* = null' "$f" || return 1
  file_contains_ml 'initialize\(state\)\s*\{(?:[^\n]|\n(?!  \},))*?\w+ = null' "$f" || return 1
  file_not_contains_ml 'async transferStock\(context, data\)\s*\{(?:[^\n]|\n(?!  \},))*?=\s*(?:crypto\.randomUUID|uuidv4|uuid|nanoid)\(' "$f" || return 1
  file_not_contains_ml 'async transferStock\(context, data\)\s*\{(?:[^\n]|\n(?!  \},))*?finally\s*\{(?:[^\n]|\n(?!  \},))*?= null' "$f" || return 1
  return 0
}
run G3c "v2 store/moveStock.js: the nonce is per-intent module state, not per HTTP attempt" \
    g3c_nonce_per_intent "$V2_STORE"

# G3d (GUARD) — the nonce charset satisfies the server's [A-Za-z0-9_\-]{1,64} key regex
# (IdempotencyFilter:69). A base64 nonce earns 400 invalid-idempotency-key BEFORE dedupe runs, so
# the feature is silently absent while every UI test passes (measured on B10).
run G3d "v2 store/moveStock.js: the nonce is not base64 (server key regex)" \
    code_not_contains "btoa\(|toString\('base64'\)" "$V2_STORE"

# --- G-e: a business FAILURE must never be cached as a success (plan §1a) ---------------------
# StockUnitController:127-130 returns HTTP 200 with an "errors" body on business failure and
# persistResponse:192 drops only non-2xx, so without this the cached "success" replays the FAILURE
# for the 7-day retention window: after the operator's blocker clears, the same nonce replays the
# error forever, and correcting the input yields a 409 key-conflict instead.
#
# Three conjuncts, all over comment-stripped code, all measured:
#   1. the failure flag is a conjunction whose FIRST operand is the path-derived scope boolean —
#      BACKREFERENCED to its declaration, so the row is name-agnostic (a rename stays green) and
#      an UNSCOPED check reds (shadow Be3, which would also change /rest/** behaviour);
#   2. that flag actually diverts the status fed to persistResponse (shadow Be2 detects the
#      condition and only LOGs it — the classic "sees the bug, does nothing" mutant);
#   3. the errors key is named in code, not only in a TODO (shadow Be1).
g5_errors_body_not_cached() {
  local f=$1
  [ -f "$f" ] || return 1
  # (?i:errors) — the operand is typically a CONSTANT (CARRIES_ERRORS), so a case-sensitive
  # 'errors' here false-REDDED the correct implementation. Measured.
  code_contains_ml 'final boolean (\w+) = \w+\(request\.getRequestURI\(\)\)(?:[^\n]|\n)*?boolean (\w+) = \1\s*&&(?:[^\n]|\n)*?(?i:errors)' "$f" || return 1
  code_contains_ml 'if \(\w+\)\s*\{[^}]{0,200}?effectiveStatus\s*=' "$f" || return 1
  # \\?" — inside a Java string the key is written \"errors\", so a bare '"errors"' pattern
  # cannot match (quote, errors, BACKSLASH, quote). Also measured: it returned 0 hits.
  code_contains '\\?"errors' "$f" || return 1
  return 0
}
run G5 "v2 IdempotencyFilter: a 2xx carrying an errors body is NOT cached on the allow-listed path" \
    g5_errors_body_not_cached "$V2_IDEMP"

# --- G-f: the allow-listed path requires auth IN CODE, not via a property (plan §1b) ----------
# The filter is added after BearerTokenAuthenticationFilter but AuthorizationFilter runs LAST, so
# it executes BEFORE the /v3/** hasAnyAuthority("wms_user") check. With app.idempotency
# .require-auth=false (the shipped default) a POST with NO Authorization header reaches tryClaim;
# absent tenant headers then route the write to the LANDLORD db where rest_idempotency does not
# exist -> 42P01 -> 500 instead of a clean 401. /rest/** is permitAll, which is why the property
# was benign there; /v3/** is not.
#
# BACKREFERENCE to the scope declaration is what makes this row meaningful: it is name-agnostic
# (a rename stays green) AND it rejects a gate widened by some UNRELATED condition — measured on
# shadow Bf2, `if (requireAuth || enforce)`, which reads correct and protects nothing.
run G6 "v2 IdempotencyFilter: the auth gate is widened by the path-derived scope flag, not a property" \
    code_contains_ml 'final boolean (\w+) = \w+\(request\.getRequestURI\(\)\)(?:[^\n]|\n)*?if \(requireAuth \|\| \1\)' "$V2_IDEMP"


echo
# =============================================================================
echo "Fix F — v2: OptimisticLockRetry javadoc must not teach the stale-operand shape"
# =============================================================================
# The vulnerable snippet is `fresh.setAmount(newAmount)` where newAmount was
# computed outside the lambda. Require the example's operand to be `fresh`.
run F1 "v2 OLR: javadoc no longer shows 'fresh.setAmount(newAmount)'" \
    file_not_contains 'fresh\.setAmount\(newAmount\)' "$V2_OLR"

# F2 was a MEASURED FALSE GREEN and is rewritten. The old pattern was
#   (?i)(recomput|derive)[^\n]*(re-?fetch|fresh|locked)
# which never mentioned @Version, "captured" or "absolute" — the things its own description claims
# it checks — so an incidental line in the EXAMPLE ("derived from the re-fetched instance")
# satisfied it. Measured: deleting the entire "necessary but not sufficient" paragraph AND the whole
# WRONG counter-example left F2 GREEN, with only F3 going red. The row certified this very commit
# for the wrong reason. Now require the substantive claim.
run F2 "v2 OLR: javadoc warns that a CAPTURED ABSOLUTE value is not caught by @Version" \
    file_contains_ml '(?i)(captur|pre-?comput)(?:[^\n]|\n(?! \*/))*?absolute(?:[^\n]|\n(?! \*/))*?\@Version' "$V2_OLR"

run F3 "v2 OLR: javadoc cites SBDEV-3003" \
    file_contains 'SBDEV-3003' "$V2_OLR"

echo
# =============================================================================
echo "Fix H — v1: mutating services must take identifiers, never entities (rows K1-K4)"
# =============================================================================
V1_SUC="$V1_API/src/main/java/net/aim_ai/wms/controller/StockUnitController.java"

# K1 — the transferStock retry lambda must stop capturing the Stockunit instance.
run H1 "v1 SUC: transferStock retry no longer captures 'final Stockunit su'" \
    file_not_contains 'final Stockunit su = stockUnit' "$V1_SUC"

# H2 — containment: no executeWithRetry lambda in this file may receive a Stockunit
# variable. Asserted as a count of the offending shape rather than a single line, so
# K2/K3 cannot be fixed while K1 is missed (or vice versa).
run H2 "v1 SUC: zero entity-passing transferStock/setLockOnHold sites (K1-K4)" \
    bash -c '[ -f "$1" ] || exit 1; [ "$(grep -cE "(setLockOnHold|transferStock)\((su|stockUnit)," "$1")" -eq 0 ]' _ "$V1_SUC"

# H3 — the id-taking service overload the fix depends on must actually exist, so H1/H2
# cannot be satisfied by simply deleting the retry wrapper.
run H3 "v1 StockunitService: an id-taking transferStock overload exists" \
    file_contains_ml 'public void transferStock\(\s*(Long|long)\s+\w+' "$V1_SUS"

echo
# =============================================================================
echo "Regression pins — v2 quantity handling is ALREADY correct (expected GREEN on arrival)"
# =============================================================================
# These two are the exempt rows from the all-red baseline (see SCOPE NOTES).
# They are only worth anything once mutation-checked: swap :373's operand for a
# stale reference and confirm P1 goes red.
run P1 "v2 SBS: a subtract whose receiver IS its own operand (locked-instance arithmetic)" \
    file_contains_ml '\b([A-Za-z_][A-Za-z0-9_]*)\.setAmount\(\s*\1\.getAmount\(\)\.subtract\(' "$V2_SBS"

run P2 "v2 SBS: transferStockToUnitLoad fetches the source FOR UPDATE" \
    file_contains_ml 'transferStockToUnitLoad\(Stockunit(?:[^\n]|\n(?!    public ))*?findByIdForUpdate\(' "$V2_SBS"

# P3 was MEASURED VACUOUS and is rewritten. It forbade one hard-coded variable name,
# `staleStockUnit`, which is not even in scope at :373 (it is a PARAMETER name in changeAmount /
# changeReservedAmount). Reintroducing the v1 defect realistically as
#   sourceStockunit.setAmount(callerSnapshot.getAmount().subtract(amount))
# turned P1 red and left P3 GREEN — the mutant survived the row whose whole job is to catch it.
# It now reuses A1's name-agnostic shape: any setAmount whose operand object differs from its
# receiver. Verified clean on unmutated v2 SBS (`:151` is setAmountstock, not setAmount() — no
# false red) and red on the mutant above.
run P3 "v2 SBS: no setAmount whose operand is a DIFFERENT object than its receiver" \
    file_not_contains_ml '\b(\w+)\.setAmount\(\s*(?!\1\b)\w+\.getAmount\(\)' "$V2_SBS"

echo
# =============================================================================
echo "Tests"
# =============================================================================
run T1 "v1: stale-operand unit test class exists" \
    bash -c '[ -n "$(find "$1/src/test" -name "StockunitBusinessServiceStaleOperandTest.java" 2>/dev/null)" ]' _ "$V1_API"

run T2 "v1: the stale-operand test asserts the post-lock value, not the stale one" \
    bash -c 'f=$(find "$1/src/test" -name "StockunitBusinessServiceStaleOperandTest.java" 2>/dev/null | head -1); [ -n "$f" ] && grep -qE "2976|isEqualByComparingTo" "$f"' _ "$V1_API"

# T3 RETARGETED 2026-08-20. It used to require a spec FILE named scanDestination* — a filename
# assertion, not a coverage one. It was red even against SBDEV-2994's real coverage
# (test/components/move-stock-destination-probe.spec.js) and would have been satisfied by an empty
# file with the right name. Assert instead that some spec imports the component AND exercises the
# in-flight flag.
run T3 "v2: a Jest spec imports moveStock/scanDestination and exercises the submitting guard" \
    bash -c '
      d="$1/test"; [ -d "$d" ] || exit 1
      for f in $(grep -rl "moveStock/scanDestination" "$d" 2>/dev/null); do
        grep -q "submitting" "$f" && exit 0
      done
      exit 1' _ "$V2_UI"

if [ "${SKIP_MVN:-0}" = "1" ]; then
    skip M1 "v1 clean compile" "SKIP_MVN=1"
    skip M2 "v2 clean compile" "SKIP_MVN=1"
    skip M3 "v1 StockunitBusinessServiceStaleOperandTest" "SKIP_MVN=1"
else
    run M1 "v1 clean compile" mvn_compiles "$V1_API"
    run M2 "v2 clean compile" mvn_compiles "$V2_API"
    run M3 "v1 StockunitBusinessServiceStaleOperandTest passes (>=2 tests, 0 skipped)" \
        mvn_test_passes "$V1_API" "StockunitBusinessServiceStaleOperandTest" 2
fi

echo
echo "-----------------------------------------------------------------------"
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
echo "-----------------------------------------------------------------------"
echo
echo "Reminder: rows A*, C*, D*, F*, G*, H*, T*, M3 MUST be red before the"
echo "fix and green after — EXCEPT D1/D1b, which SBDEV-2994 already satisfies on"
echo "the unfixed v2 tree (measured); D1c/D1d/D1e are the discriminating v2 rows."
echo "The B* and E* families no longer exist (deleted above) — do not hunt for"
echo "them. Rows P1-P3 pass on arrival by design and are worthless until"
echo "mutation-checked; P3 was rewritten 2026-08-20 after measuring the old one"
echo "vacuous. GUARD ROWS G1c and G3d also pass on the pristine tree and are"
echo "likewise exempt from the all-red baseline — a green G1c alone does NOT mean"
echo "the allow-list is right; it is only meaningful paired with G1. The Slice 2"
echo "G* family was replaced wholesale 2026-08-20 after 12 of 16 broken shadow"
echo "implementations scored a FULL GREEN against the previous four rows."
echo "Fix D covers Move Stock only — 26 other"
echo "unguarded scan components per UI are out of scope for this script."
echo

[ "$FAIL" -eq 0 ]
