#!/usr/bin/env bash
#
# uat-apply-pending-tenant-flyway.sh
#
# Discover every tenant database from the UAT landlord and report / apply any
# pending Flyway migrations from the wms2-api release branch (db/migration).
#
# The tenant list is NOT hard-coded: it comes from landlord.tenant_db_configuration,
# so clients onboarded in the future are picked up automatically.
#
# Companion runbook:
#   sbdocs/2-Areas/runbooks/wms2-apply-pending-tenant-flyway-uat.md
#
# SAFETY MODEL
#   --status (default)  read-only; connects, classifies, prints. Changes nothing.
#   --apply             runs `flyway migrate` on tenants that ALREADY have a
#                       flyway_schema_history. Never touches un-stamped DBs.
#   Un-stamped DBs are reported as NEEDS-BASELINE and skipped, always. Baselining
#   is a deliberate one-time human step (see runbook §6) because V2.2.03 is a bare
#   ALTER TABLE ADD COLUMN with no IF NOT EXISTS — stamping at the wrong version
#   makes `migrate` fail, or silently skip a migration that was never applied.
#
set -euo pipefail

# ---------------------------------------------------------------- defaults ---
LANDLORD_HOST="localhost"
LANDLORD_PORT="25062"
LANDLORD_DB="landlord"
LANDLORD_USER="wms_landlord"

# Tenant db_url in the landlord is the APPLICATION's view (e.g. uat.sbo.li:25060).
# An operator on a workstation reaches the same servers through an SSH tunnel.
# These override the host:port parsed out of db_url. Empty = use db_url as-is.
TENANT_HOST_OVERRIDE="localhost"
TENANT_PORT_OVERRIDE="25062"

REPO="${WMS2_API_REPO:-}"
MODE="status"
INCLUDE_INACTIVE="no"
ONLY_WAREHOUSE=""

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; BLU=$'\033[1;34m'; DIM=$'\033[2m'; RST=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$BLU" "$(date +%H:%M:%S)" "$RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$*"; }
die()  { printf '%s[FATAL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Apply pending wms2-api tenant Flyway migrations across every UAT tenant DB.

  PGPASSWORD_LANDLORD=... $0 --repo /path/to/wms2-api [--apply]

Options:
  --repo PATH              wms2-api checkout (release branch). Default: \$WMS2_API_REPO
  --status                 Report only (DEFAULT). Read-only.
  --apply                  Run 'flyway migrate' on tenants that have a history table.
  --warehouse NAME         Limit to one warehouse code (e.g. nywh). Repeatable-safe.
  --include-inactive       Also process rows with active = false (default: skip).

  --landlord-host HOST     Default: $LANDLORD_HOST
  --landlord-port PORT     Default: $LANDLORD_PORT
  --landlord-db NAME       Default: $LANDLORD_DB
  --landlord-user ROLE     Default: $LANDLORD_USER
  --tenant-host HOST       Override host from db_url. Default: $TENANT_HOST_OVERRIDE
  --tenant-port PORT       Override port from db_url. Default: $TENANT_PORT_OVERRIDE
  --no-tenant-override     Use db_url host:port verbatim (run from inside the env).
  -h, --help

Env:
  PGPASSWORD_LANDLORD  password for --landlord-user (required)

Tenant credentials are read from landlord.tenant_db_configuration and are never printed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                REPO="$2"; shift 2;;
    --status)              MODE="status"; shift;;
    --apply)               MODE="apply"; shift;;
    --warehouse)           ONLY_WAREHOUSE="$2"; shift 2;;
    --include-inactive)    INCLUDE_INACTIVE="yes"; shift;;
    --landlord-host)       LANDLORD_HOST="$2"; shift 2;;
    --landlord-port)       LANDLORD_PORT="$2"; shift 2;;
    --landlord-db)         LANDLORD_DB="$2"; shift 2;;
    --landlord-user)       LANDLORD_USER="$2"; shift 2;;
    --tenant-host)         TENANT_HOST_OVERRIDE="$2"; shift 2;;
    --tenant-port)         TENANT_PORT_OVERRIDE="$2"; shift 2;;
    --no-tenant-override)  TENANT_HOST_OVERRIDE=""; TENANT_PORT_OVERRIDE=""; shift;;
    -h|--help)             usage; exit 0;;
    *) die "unknown argument: $1 (try --help)";;
  esac
done

# ------------------------------------------------------------- preflight ----
[[ -n "${PGPASSWORD_LANDLORD:-}" ]] || die "PGPASSWORD_LANDLORD not set (password for '$LANDLORD_USER')"
[[ -n "$REPO" ]] || die "--repo not set (path to the wms2-api checkout)"
MIGRATION_DIR="$REPO/src/main/resources/db/migration"
[[ -d "$MIGRATION_DIR" ]] || die "not a wms2-api checkout: $MIGRATION_DIR missing"
command -v psql   >/dev/null || die "psql not on PATH"
command -v flyway >/dev/null || die "flyway not on PATH"

log "Preflight"
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
HEAD_SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"
# '|| true': under `set -o pipefail` a non-matching grep fails the whole
# pipeline, which would abort the script whenever HEAD carries no semver tag.
HEAD_TAG="$(git -C "$REPO" tag --points-at HEAD 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
ok "repo $REPO"
ok "branch '$BRANCH' @ $HEAD_SHA${HEAD_TAG:+ (tag $HEAD_TAG)}"
[[ "$BRANCH" == "release" ]] || warn "branch is '$BRANCH', not 'release' — UAT runs the release branch"

# Lexical sort (NOT sort -V) so this list and the SQL-side list are ordered
# identically for comm(1). Versions are zero-padded (2.2.00..2.2.99), so lexical
# and version order agree; consistency between the two sides is what matters.
FILE_VERSIONS="$(find "$MIGRATION_DIR" -maxdepth 1 -name 'V*.sql' -printf '%f\n' \
            | sed -E 's/^V([0-9.]+)__.*/\1/' | sort -u)"
HIGHEST="$(printf '%s\n' "$FILE_VERSIONS" | sort -V | tail -1)"
ok "migration set: $(printf '%s\n' "$FILE_VERSIONS" | wc -l) scripts, highest = $HIGHEST"

# ------------------------------------------------------- discover tenants ---
log "Discovering tenants from $LANDLORD_USER@$LANDLORD_HOST:$LANDLORD_PORT/$LANDLORD_DB"

ACTIVE_FILTER="AND active"
[[ "$INCLUDE_INACTIVE" == "yes" ]] && ACTIVE_FILTER=""
WH_FILTER=""
[[ -n "$ONLY_WAREHOUSE" ]] && WH_FILTER="AND lower(warehouse) = lower('$ONLY_WAREHOUSE')"

# Unit-separator delimited so passwords containing ':' or '|' survive intact.
TENANTS="$(PGPASSWORD="$PGPASSWORD_LANDLORD" psql \
  -h "$LANDLORD_HOST" -p "$LANDLORD_PORT" -U "$LANDLORD_USER" -d "$LANDLORD_DB" \
  -X -tA -F$'\037' -c "
    SELECT warehouse, db_url, db_user_name, db_password, active
      FROM tenant_db_configuration
     WHERE 1=1 $ACTIVE_FILTER $WH_FILTER
     ORDER BY warehouse, db_url;" 2>&1)" \
  || die "landlord query failed: $TENANTS"

[[ -n "$TENANTS" ]] || die "no tenant rows returned (check --warehouse / --include-inactive)"
ok "$(printf '%s\n' "$TENANTS" | wc -l) tenant database(s) discovered"

# --------------------------------------------------------------- process ----
declare -a R_UPTODATE=() R_APPLIED=() R_PENDING=() R_BASELINE=() R_ERROR=()

while IFS=$'\037' read -r WAREHOUSE DB_URL DB_USER DB_PASS ACTIVE; do
  [[ -n "${WAREHOUSE:-}" ]] || continue

  # jdbc:postgresql://HOST:PORT/DBNAME[?params]
  URL_BODY="${DB_URL#jdbc:postgresql://}"
  URL_HOSTPORT="${URL_BODY%%/*}"
  URL_DBNAME="${URL_BODY#*/}"; URL_DBNAME="${URL_DBNAME%%\?*}"
  URL_HOST="${URL_HOSTPORT%%:*}"
  URL_PORT="${URL_HOSTPORT##*:}"; [[ "$URL_PORT" == "$URL_HOST" ]] && URL_PORT=5432

  HOST="${TENANT_HOST_OVERRIDE:-$URL_HOST}"
  PORT="${TENANT_PORT_OVERRIDE:-$URL_PORT}"

  echo
  log "── $WAREHOUSE → $URL_DBNAME ${DIM}(${HOST}:${PORT}, user $DB_USER, active=$ACTIVE)${RST}"
  [[ "$HOST:$PORT" != "$URL_HOST:$URL_PORT" ]] && \
    printf '  %s↻ db_url says %s:%s — using override %s:%s%s\n' "$DIM" "$URL_HOST" "$URL_PORT" "$HOST" "$PORT" "$RST"

  tpsql() { PGPASSWORD="$DB_PASS" psql -h "$HOST" -p "$PORT" -U "$DB_USER" -d "$URL_DBNAME" -X -tA "$@"; }

  if ! CONN="$(tpsql -c 'select 1' 2>&1)"; then
    bad "connection failed: $(printf '%s' "$CONN" | tr '\n' ' ' | cut -c1-140)"
    R_ERROR+=("$WAREHOUSE/$URL_DBNAME: connect failed"); continue
  fi

  HAS_HIST="$(tpsql -c "select count(*) from pg_tables where tablename='flyway_schema_history';" 2>/dev/null || echo 0)"

  if [[ "$HAS_HIST" != "1" ]]; then
    warn "no flyway_schema_history — NEEDS-BASELINE (skipped; see runbook §6)"
    R_BASELINE+=("$WAREHOUSE/$URL_DBNAME"); continue
  fi

  CURRENT="$(tpsql -c "select coalesce(max(version),'(none)') from flyway_schema_history where success;" 2>/dev/null || echo '?')"
  FAILED="$(tpsql -c "select count(*) from flyway_schema_history where not success;" 2>/dev/null || echo 0)"
  if [[ "$FAILED" != "0" ]]; then
    bad "$FAILED failed row(s) in flyway_schema_history — needs 'flyway repair' first"
    R_ERROR+=("$WAREHOUSE/$URL_DBNAME: failed history row(s)"); continue
  fi

  # Checksum integrity of what IS applied. Pending entries are expected here, so
  # they are ignored — this question is only "has an applied script been edited?".
  if ! VOUT="$(flyway -url="jdbc:postgresql://$HOST:$PORT/$URL_DBNAME" \
                -user="$DB_USER" -password="$DB_PASS" \
                -locations="filesystem:$MIGRATION_DIR" \
                -ignoreMigrationPatterns='*:pending' validate 2>&1)"; then
    bad "validate FAILED (checksum drift on an applied migration) — do not migrate"
    printf '%s\n' "$VOUT" | grep -iE 'checksum|detected|migration' | head -4 | sed 's/^/      /' || true
    R_ERROR+=("$WAREHOUSE/$URL_DBNAME: checksum drift"); continue
  fi

  # Pending = versions on disk minus versions recorded SUCCESS. Computed as a set
  # difference rather than scraped from `flyway info`, so a change to Flyway's
  # output format cannot silently report "0 pending" and skip a tenant.
  APPLIED_V="$(tpsql -c "select version from flyway_schema_history where success and version is not null order by 1;" | sort -u)"
  PENDING_LIST="$(comm -23 <(printf '%s\n' "$FILE_VERSIONS") <(printf '%s\n' "$APPLIED_V" | sed '/^$/d'))"
  PENDING="$(printf '%s\n' "$PENDING_LIST" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$PENDING" == "0" ]]; then
    ok "at $CURRENT — no pending migrations"
    R_UPTODATE+=("$WAREHOUSE/$URL_DBNAME @ $CURRENT"); continue
  fi

  PENDING_CSV="$(printf '%s\n' "$PENDING_LIST" | sed '/^$/d' | paste -sd, -)"

  if [[ "$MODE" == "status" ]]; then
    warn "at $CURRENT — $PENDING pending [$PENDING_CSV]. Re-run with --apply."
    R_PENDING+=("$WAREHOUSE/$URL_DBNAME @ $CURRENT → $HIGHEST (pending: $PENDING_CSV)")
    continue
  fi

  log "   applying $PENDING pending migration(s) [$PENDING_CSV]: $CURRENT → $HIGHEST"
  if MOUT="$(flyway -url="jdbc:postgresql://$HOST:$PORT/$URL_DBNAME" \
              -user="$DB_USER" -password="$DB_PASS" \
              -locations="filesystem:$MIGRATION_DIR" migrate 2>&1)"; then
    printf '%s\n' "$MOUT" | grep -E 'Migrating|Successfully applied|up to date' | sed 's/^/      /' || true
    NEW="$(tpsql -c "select coalesce(max(version),'?') from flyway_schema_history where success;")"
    ok "now at $NEW"
    R_APPLIED+=("$WAREHOUSE/$URL_DBNAME @ $CURRENT → $NEW")
  else
    bad "migrate FAILED — this tenant is PARTIALLY migrated; stop and read runbook §8"
    printf '%s\n' "$MOUT" | grep -iE 'error|caused|sql state' | head -6 | sed 's/^/      /' || true
    R_ERROR+=("$WAREHOUSE/$URL_DBNAME: migrate failed")
  fi
done <<< "$TENANTS"

# ---------------------------------------------------------------- summary ---
echo; log "Summary (mode: $MODE)"
# ${arr[@]+"${arr[@]}"} expands to NOTHING when the array is empty, unlike
# "${arr[@]:-}" which yields one empty string and reports a false count of 1.
print_group() { local c="$1" t="$2"; shift 2; [[ $# -eq 0 ]] && return 0
  printf '  %s%s%s (%d)\n' "$c" "$t" "$RST" "$#"; printf '      %s\n' "$@"; }
print_group "$GRN" "up to date"      ${R_UPTODATE[@]+"${R_UPTODATE[@]}"}
print_group "$GRN" "applied"         ${R_APPLIED[@]+"${R_APPLIED[@]}"}
print_group "$YEL" "pending"         ${R_PENDING[@]+"${R_PENDING[@]}"}
print_group "$YEL" "needs baseline"  ${R_BASELINE[@]+"${R_BASELINE[@]}"}
print_group "$RED" "errors"          ${R_ERROR[@]+"${R_ERROR[@]}"}

echo
if [[ ${#R_ERROR[@]} -gt 0 ]]; then
  die "${#R_ERROR[@]} tenant(s) errored — resolve before deploying"
fi
if [[ "$MODE" == "status" && ${#R_PENDING[@]} -gt 0 ]]; then
  printf '%s%s%s\n' "$YEL" "${#R_PENDING[@]} tenant(s) have pending migrations — re-run with --apply" "$RST"; exit 2
fi
if [[ ${#R_BASELINE[@]} -gt 0 ]]; then
  printf '%s%s%s\n' "$YEL" "${#R_BASELINE[@]} tenant(s) need a one-time baseline — runbook §6" "$RST"; exit 3
fi
ok "all tenants at $HIGHEST"
