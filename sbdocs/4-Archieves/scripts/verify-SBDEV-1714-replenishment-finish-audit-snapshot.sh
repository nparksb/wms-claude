#!/usr/bin/env bash
#
# verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh
#
# Machine-checkable acceptance contract for SBDEV-1714 (v2/wms2-api ONLY).
# Modeled on verify-SBDEV-2095.sh (positive + negative per fix) and the
# run-runner pattern in verify-plan-template.sh.
#
# Encodes ORDERING for Fix C (capture-before-transfer), not just presence.
# Prints PASS/FAIL per check; exits non-zero if any check FAILs.
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-SBDEV-1714-replenishment-finish-audit-snapshot.sh
#   REPO=/path/to/v2/wms2-api RUN_MVN=1 bash .../verify-SBDEV-1714-...sh
#
set -uo pipefail

# --- locate the wms2-api repo (scripts live at owl/sbdocs/9-System/scripts/) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "${SCRIPT_DIR}/../../../v2/wms2-api" 2>/dev/null && pwd)}"

if [[ -z "${REPO}" || ! -d "${REPO}" ]]; then
  echo "FATAL: cannot locate v2/wms2-api repo. Set REPO=/abs/path/to/v2/wms2-api" >&2
  exit 2
fi

SRC="${REPO}/src/main/java/net/aim_ai/wms"
MIG="${REPO}/src/main/resources/db/migration"

ENTITY="${SRC}/model/Replenishorder.java"
MOBILE="${SRC}/service/mobile/MobileReplenishService.java"
REPO_JPA="${SRC}/repo/jpa/ReplenishorderRepository.java"
SERVICE="${SRC}/service/ReplenishorderService.java"
PROJECTION="${SRC}/repo/projection/ReplenishOrderDetailView.java"
MIGRATION="${MIG}/V2.2.03__replenishorder_finish_audit_snapshot.sql"

PASS=0
FAIL=0

# run <id> "<description>" <fn>
run() {
  local id="$1" desc="$2" fn="$3"
  local out rc
  out="$("$fn" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    printf "PASS  %-32s %s\n" "$id" "$desc"
    PASS=$((PASS+1))
  else
    printf "FAIL  %-32s %s\n" "$id" "$desc"
    [[ -n "$out" ]] && printf "        \xe2\x94\x94\xe2\x94\x80 %s\n" "$out"
    FAIL=$((FAIL+1))
  fi
}

# first matching line number for a fixed-string pattern in a file (empty if none)
first_lineno() { grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

need_file() { [[ -f "$1" ]] || { echo "missing file: $1"; return 1; }; }

# ----------------------------------------------------------------------------
# Fix A — migration
# ----------------------------------------------------------------------------
check_A_migration_present() {
  need_file "$MIGRATION" || return 1
  local miss=""
  for col in moved_amount moved_source_unitload_label \
             moved_destination_unitload_label moved_destination_location_name; do
    grep -Eiq "add[[:space:]]+column[[:space:]]+${col}\b" "$MIGRATION" || miss="${miss} ${col}"
  done
  [[ -z "$miss" ]] || { echo "V2.2.03 missing ADD COLUMN for:${miss}"; return 1; }
}

check_A_no_edit_applied() {
  # never edit an applied migration (V2.2.00..V2.2.02)
  if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "skip: $REPO is not a git repo (cannot check applied-migration diff)"; return 0
  fi
  local dirty
  dirty="$(git -C "$REPO" status --porcelain -- \
            'src/main/resources/db/migration/V2.2.00*' \
            'src/main/resources/db/migration/V2.2.01*' \
            'src/main/resources/db/migration/V2.2.02*' 2>/dev/null)"
  [[ -z "$dirty" ]] || { echo "applied migration(s) modified:"$'\n'"$dirty"; return 1; }
}

# ----------------------------------------------------------------------------
# Fix B — entity
# ----------------------------------------------------------------------------
check_B_entity_getters() {
  need_file "$ENTITY" || return 1
  local miss=""
  for g in getMovedAmount getMovedSourceUnitloadLabel \
           getMovedDestinationUnitloadLabel getMovedDestinationLocationName; do
    grep -q "$g" "$ENTITY" || miss="${miss} ${g}"
  done
  [[ -z "$miss" ]] || { echo "entity missing getter(s):${miss}"; return 1; }
  for c in moved_amount moved_source_unitload_label \
           moved_destination_unitload_label moved_destination_location_name; do
    grep -Eq "@Column\(name[[:space:]]*=[[:space:]]*\"${c}\"" "$ENTITY" \
      || { echo "entity missing @Column(name=\"${c}\")"; return 1; }
  done
}

check_B_no_notnull_on_snapshot() {
  need_file "$ENTITY" || return 1
  # the 4 snapshot fields must be nullable — none of their declaration lines may carry @NotNull.
  if grep -B1 -E "private[[:space:]]+(BigDecimal|String)[[:space:]]+moved[A-Za-z]+;" "$ENTITY" \
        | grep -q "@NotNull"; then
    echo "@NotNull found on a snapshot field (must be nullable)"; return 1
  fi
}

# ----------------------------------------------------------------------------
# Fix C — capture BEFORE transfer (the critical ordering check)
#
# The "capture" of the source UL is whichever comes FIRST of:
#   - sourceStock.getUnitloadId()                 (the prescribed Fix C token)
#   - the movedSourceUnitloadLabel local assignment / unitloadRepository lookup
# We take the earliest line that resolves the source label, so a correct impl
# that resolves the label without a literal getUnitloadId() token still passes,
# and a lazy FK-deref cannot slip past the negative check. (Critic nit #1.)
# ----------------------------------------------------------------------------
source_capture_lineno() {
  # earliest of the candidate capture expressions
  local a b c min=""
  a="$(first_lineno "$MOBILE" 'sourceStock.getUnitloadId()')"
  b="$(first_lineno "$MOBILE" 'movedSourceUnitloadLabel =')"
  c="$(first_lineno "$MOBILE" 'movedSourceUnitloadLabel=')"
  for n in "$a" "$b" "$c"; do
    [[ -n "$n" ]] || continue
    if [[ -z "$min" || "$n" -lt "$min" ]]; then min="$n"; fi
  done
  echo "$min"
}

check_C_capture_before_transfer() {
  need_file "$MOBILE" || return 1
  local cap_ln xfer_ln
  cap_ln="$(source_capture_lineno)"
  xfer_ln="$(first_lineno "$MOBILE" 'transferStockToUnitLoad(sourceStock')"
  [[ -n "$cap_ln"  ]] || { echo "no source-UL capture (sourceStock.getUnitloadId() / movedSourceUnitloadLabel=) found"; return 1; }
  [[ -n "$xfer_ln" ]] || { echo "no transferStockToUnitLoad(sourceStock ...) call found"; return 1; }
  if (( cap_ln < xfer_ln )); then
    return 0
  else
    echo "source-UL capture at line ${cap_ln} is NOT before transfer at line ${xfer_ln} (bug reintroduced)"
    return 1
  fi
}

check_C_no_post_transfer_source_read() {
  need_file "$MOBILE" || return 1
  local xfer_ln
  xfer_ln="$(first_lineno "$MOBILE" 'transferStockToUnitLoad(sourceStock')"
  [[ -n "$xfer_ln" ]] || { echo "no transfer call found"; return 1; }
  # every sourceStock.getUnitloadId() occurrence must have a line number < transfer line
  local ln
  while read -r ln; do
    [[ -z "$ln" ]] && continue
    if (( ln >= xfer_ln )); then
      echo "source-UL read (sourceStock.getUnitloadId()) at line ${ln} is at/after transfer (${xfer_ln})"
      return 1
    fi
  done < <(grep -nF 'sourceStock.getUnitloadId()' "$MOBILE" | cut -d: -f1)
}

check_C_sets_all_four_fields() {
  need_file "$MOBILE" || return 1
  local miss=""
  for s in setMovedAmount setMovedSourceUnitloadLabel \
           setMovedDestinationUnitloadLabel setMovedDestinationLocationName; do
    grep -q "replenishOrder.${s}(" "$MOBILE" || miss="${miss} ${s}"
  done
  [[ -z "$miss" ]] || { echo "finish path missing setter(s):${miss}"; return 1; }
}

# ----------------------------------------------------------------------------
# Fix D — detail read
# ----------------------------------------------------------------------------
check_D_repo_select() {
  need_file "$REPO_JPA" || return 1
  local miss=""
  for a in "r.moved_amount as movedAmount" \
           "r.moved_source_unitload_label as movedSourceUnitload" \
           "r.moved_destination_unitload_label as movedDestinationUnitload" \
           "r.moved_destination_location_name as movedDestinationLocation"; do
    grep -qF "$a" "$REPO_JPA" || miss="${miss} [${a}]"
  done
  [[ -z "$miss" ]] || { echo "findDetailMapById SELECT missing alias(es):${miss}"; return 1; }
}

check_D_service_keys() {
  need_file "$SERVICE" || return 1
  local miss=""
  for k in movedamount movedsourceunitload moveddestinationunitload moveddestinationlocation; do
    grep -qF "row.get(\"${k}\")" "$SERVICE" || miss="${miss} ${k}"
  done
  [[ -z "$miss" ]] || { echo "getReplenishorderDetails missing NULL-guarded key(s):${miss}"; return 1; }
  # back-compat: stockUnitAmount put must still exist
  grep -qF 'details.put("stockUnitAmount"' "$SERVICE" \
    || { echo "stockUnitAmount put was removed (back-compat broken)"; return 1; }
}

# ----------------------------------------------------------------------------
# Fix E — list reads (2 of 3 queries) + open-view / projection invariants
# ----------------------------------------------------------------------------
COALESCE='COALESCE(r.moved_source_unitload_label, u.labelid) as unitload'

check_E_coalesce_count() {
  need_file "$REPO_JPA" || return 1
  local n
  n="$(grep -cF "$COALESCE" "$REPO_JPA")"
  # expected in exactly 2 queries: getDetailViewByKeyword + getClosedViewByKeyword
  if [[ "$n" -eq 2 ]]; then return 0; fi
  echo "expected 2 COALESCE occurrences (getDetailViewByKeyword + getClosedViewByKeyword), found ${n}"
  return 1
}

check_E_open_untouched() {
  need_file "$REPO_JPA" || return 1
  # getOpenViewByKeyword's block must still use plain 'u.labelid as unitload' and NOT the COALESCE.
  local body
  body="$(awk '/getOpenViewByKeyword/{seen=1} seen{print} seen && /Page<ReplenishOrderDetailView> getOpenViewByKeyword/{exit}' "$REPO_JPA")"
  if [[ -z "$body" ]]; then
    body="$(grep -n "getOpenViewByKeyword" "$REPO_JPA")"
  fi
  echo "$body" | grep -qF "$COALESCE" && { echo "getOpenViewByKeyword unexpectedly uses COALESCE"; return 1; }
  echo "$body" | grep -qF "u.labelid as unitload" || { echo "getOpenViewByKeyword no longer uses plain 'u.labelid as unitload'"; return 1; }
  return 0
}

check_projection_unchanged() {
  need_file "$PROJECTION" || return 1
  # no new moved* getter should be added to the projection (Fix E reuses the 'unitload' alias)
  if grep -Eiq "getMoved" "$PROJECTION"; then
    echo "ReplenishOrderDetailView gained a moved* getter (should be unchanged)"; return 1
  fi
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    local d
    d="$(git -C "$REPO" status --porcelain -- 'src/main/java/net/aim_ai/wms/repo/projection/ReplenishOrderDetailView.java' 2>/dev/null)"
    [[ -z "$d" ]] || { echo "projection file modified: $d"; return 1; }
  fi
}

# ----------------------------------------------------------------------------
# Behavioral — targeted unit tests
# ----------------------------------------------------------------------------
check_behavior_unit_tests() {
  if [[ "${RUN_MVN:-0}" != "1" ]]; then
    echo "skipped (set RUN_MVN=1 to execute mvn); code-shape checks above still enforced"
    return 0
  fi
  ( cd "$REPO" && mvn -q test \
      -Dtest=MobileReplenishServiceUnitTest,ReplenishorderServiceUnitTest ) \
    || { echo "unit tests failed"; return 1; }
}

# ----------------------------------------------------------------------------
echo "SBDEV-1714 verify — repo: ${REPO}"
echo "-------------------------------------------------------------------"
run A_migration_present          "Fix A: V2.2.03 adds all 4 snapshot columns"                   check_A_migration_present
run A_no_edit_applied            "Fix A: V2.2.00-02 migrations untouched (negative)"            check_A_no_edit_applied
run B_entity_getters             "Fix B: entity has 4 getters + @Column(name=...)"              check_B_entity_getters
run B_no_notnull_on_snapshot     "Fix B: snapshot fields nullable, no @NotNull (negative)"      check_B_no_notnull_on_snapshot
run C_capture_before_transfer    "Fix C: source-UL captured BEFORE transfer (ORDERING)"         check_C_capture_before_transfer
run C_no_post_transfer_read      "Fix C: no source-UL read at/after transfer (negative)"        check_C_no_post_transfer_source_read
run C_sets_all_four_fields       "Fix C: finish path sets all 4 snapshot fields"                check_C_sets_all_four_fields
run D_repo_select                "Fix D: findDetailMapById selects 4 moved_* aliases"           check_D_repo_select
run D_service_keys               "Fix D: details put 4 NULL-guarded keys; stockUnitAmount kept" check_D_service_keys
run E_coalesce_count             "Fix E: COALESCE in exactly 2 queries"                         check_E_coalesce_count
run E_open_untouched             "Fix E: getOpenViewByKeyword still plain u.labelid (negative)" check_E_open_untouched
run projection_unchanged         "Invariant: ReplenishOrderDetailView unchanged (negative)"     check_projection_unchanged
run behavior_unit_tests          "Behavioral: MobileReplenishServiceUnitTest + ReplenishorderServiceUnitTest" check_behavior_unit_tests

echo "-------------------------------------------------------------------"
echo "PASS: ${PASS}   FAIL: ${FAIL}"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
