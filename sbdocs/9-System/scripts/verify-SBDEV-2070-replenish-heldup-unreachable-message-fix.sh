#!/usr/bin/env bash
# verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh
#
# Machine-checkable acceptance for
#   SBDEV-2070-replenish-heldup-unreachable-message-fix.md
#
# Scope: mobile-UI MESSAGE fix only (v2/wms2-mobile-ui). No backend change.
# Target is a JS/Vue (Nuxt 2) repo, so checks are grep-based file_contains /
# file_not_contains, plus an OPTIONAL jest run of the helper spec.
#
# For each of the 3 sites: a POSITIVE check (new helper/message present) and a
# NEGATIVE check (old strings gone). Exits non-zero on any FAIL.
#
#   $ bash sbdocs/9-System/scripts/verify-SBDEV-2070-replenish-heldup-unreachable-message-fix.sh
#
# Env:
#   PROJECT_ROOT   defaults to the wms2-mobile-ui dir below; override for other clones.
#   SKIP_JEST=1    skip the helper unit-test run (grep checks still run).

set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-mobile-ui}"
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

file_contains()     { grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains() { ! grep -qE "$1" "$2" 2>/dev/null; }

HELPER=util/replenishMessages.js
PAGE=pages/replenish.vue
ALL=components/replenish/process/AllReplenList.vue
HELD=components/replenish/process/HeldUpList.vue
SPEC=test/util/replenishMessages.spec.js

echo
echo "verify-SBDEV-2070 — replenish held-up message-fix acceptance"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

# --- H — shared helper exists & branches --------------------------------------
run H0a  "H — util/replenishMessages.js exists"                     test -f "$HELPER"
run H0b  "H — exports heldUpReplenMessage (toast full-form)"        file_contains 'export function heldUpReplenMessage' "$HELPER"
run H0c  "H — exports heldUpChipMessage (chip terse-form)"          file_contains 'export function heldUpChipMessage' "$HELPER"
run H0d  "H — has qty>0 branch (Number check)"                      file_contains 'qty\s*>\s*0' "$HELPER"
run H0e  "H — 'No replenishable stock' fallback branch present"     file_contains 'No replenishable stock' "$HELPER"
run H0f  "H — terse chip 'Stock on non-replenishable location' present" \
                                                                    file_contains 'Stock on non-replenishable location' "$HELPER"

echo

# --- S1 — pages/replenish.vue selectOrder toast -------------------------------
run S1a  "S1 — helper imported in pages/replenish.vue"              file_contains "import\s+\{\s*heldUpReplenMessage\s*\}\s+from\s+'~/util/replenishMessages'" "$PAGE"
run S1b  "S1 — toast uses heldUpReplenMessage(item)"                file_contains 'heldUpReplenMessage\(item\)' "$PAGE"
run S1c  "S1 — old 'Unable to Perform Replenishment Request' gone"  file_not_contains 'Unable to Perform Replenishment Request' "$PAGE"
run S1d  "S1 — old raw ': \${item.qtyOnNonReplenishableLocation}' interpolation gone" \
                                                                    file_not_contains ':\s*\$\{item\.qtyOnNonReplenishableLocation\}' "$PAGE"
run S1e  "S1 — AC4: roId-set rows still open into source step (setProcess '2_source')" \
                                                                    file_contains "setProcess',\s*'2_source'" "$PAGE"

echo

# --- S2 — AllReplenList.vue chip (text + severity) ----------------------------
run S2a  "S2 — heldUpChipMessage imported in AllReplenList.vue"     file_contains 'heldUpChipMessage' "$ALL"
run S2b  "S2 — chip renders heldUpChip(item)"                       file_contains 'heldUpChip\(item\)' "$ALL"
run S2c  "S2 — old 'Inventory Unreachable @' chip text gone"        file_not_contains 'Inventory Unreachable @' "$ALL"
run S2d  "S2 — old 'x {{ item.qtyOnNonReplenishableLocation }} items' interpolation gone" \
                                                                    file_not_contains 'x \{\{ ?item\.qtyOnNonReplenishableLocation ?\}\} items' "$ALL"
run S2e  "S2 — guard v-if=\"(!item.source)\" preserved"             file_contains 'v-if="\(!item\.source\)"' "$ALL"
run S2f  "S2 — chip severity now state-bound (:color qty>0 ? warning : grey)" \
                                                                    file_contains ":color=\"item\.qtyOnNonReplenishableLocation > 0 \? 'warning' : 'grey'\"" "$ALL"
run S2g  "S2 — hard-coded chip <v-chip color=\"error\" gone (comment block untouched)" \
                                                                    file_not_contains '<v-chip color="error"' "$ALL"

echo

# --- S3 — HeldUpList.vue chip (text + severity) -------------------------------
run S3a  "S3 — heldUpChipMessage imported in HeldUpList.vue"        file_contains 'heldUpChipMessage' "$HELD"
run S3b  "S3 — chip renders heldUpChip(item)"                       file_contains 'heldUpChip\(item\)' "$HELD"
run S3c  "S3 — old 'Inventory Unreachable @' chip text gone"        file_not_contains 'Inventory Unreachable @' "$HELD"
run S3d  "S3 — old 'x {{ item.qtyOnNonReplenishableLocation }} items' interpolation gone" \
                                                                    file_not_contains 'x \{\{ ?item\.qtyOnNonReplenishableLocation ?\}\} items' "$HELD"
run S3e  "S3 — guard v-if=\"(!item.roSourceName)\" preserved"       file_contains 'v-if="\(!item\.roSourceName\)"' "$HELD"
run S3f  "S3 — chip severity now state-bound (:color qty>0 ? warning : grey)" \
                                                                    file_contains ":color=\"item\.qtyOnNonReplenishableLocation > 0 \? 'warning' : 'grey'\"" "$HELD"
run S3g  "S3 — hard-coded held-up chip <v-chip color=\"error\" gone (anchored to tag; skips commented block)" \
                                                                    file_not_contains '<v-chip color="error"' "$HELD"

echo

# --- Optional: helper unit test -----------------------------------------------
# No yarn on PATH; run jest via node (nvm). Node path is auto-detected, override
# with NODE_BIN=/path/to/node if needed.
jest_helper_passes() {
    local node_bin
    node_bin="${NODE_BIN:-$(command -v node || ls "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | tail -1)}"
    [ -n "$node_bin" ] || return 1
    "$node_bin" node_modules/.bin/jest --testPathPattern=replenishMessages >/dev/null 2>&1
}

if [ "${SKIP_JEST:-0}" = "0" ]; then
    run T-spec "T — replenishMessages.spec.js exists"  test -f "$SPEC"
    run T-jest "T — helper unit test passes"           jest_helper_passes
else
    skip T-jest "helper unit-test run" "SKIP_JEST=1 set"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
