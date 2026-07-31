#!/usr/bin/env bash
#
# apply-pending-tenant-flyway.sh
#
# Discover every tenant database from an environment's landlord and report /
# apply any pending Flyway migrations from that environment's wms2-api branch
# (db/migration).
#
# The tenant list is NOT hard-coded: it comes from landlord.tenant_db_configuration,
# so clients onboarded in the future are picked up automatically.
#
# Companion runbook:
#   sbdocs/2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md
#
# ENVIRONMENTS
#   --env is REQUIRED and has no default. On an operator workstation all three
#   environments are reachable at localhost and differ only by tunnel port, so a
#   forgotten flag would silently target the wrong fleet — e.g. pushing a
#   develop-only migration into UAT, or into PRODUCTION. Making the choice
#   explicit is the guard.
#
#     dev   landlord dev_landlord  @ localhost:25060 as wms_landlord
#           tenants @ localhost:25060 · branch 'develop'
#           (auto-deploys on push — see runbook §5.4)
#     uat   landlord landlord      @ localhost:25062 as wms_landlord
#           tenants @ localhost:25062 · branch 'release'
#     prd   landlord wms2_landlord @ localhost:25061 as wms2_landlord_app
#           tenants @ localhost:25061 · branch 'main'
#           (PRODUCTION — --apply additionally requires --confirm-production)
#
#   NOTE all three differ in the landlord DB NAME, and prd also differs in the
#   landlord ROLE ('wms2_landlord_app', not 'wms_landlord'). That is why the role
#   is part of the --env profile rather than a fixed default.
#
#   A database literally named 'landlord' ALSO exists on the dev server; it is
#   stale (one abandoned row, no L001) and is NOT what the dev app reads.
#   Pointing at it returns a plausible-looking tenant list rather than an error,
#   which is why the L001 preflight below exists.
#
#   PRODUCTION CO-TENANCY HAZARD: the prd server hosts exactly ONE v2 database
#   (wh01_hydra_v2) alongside six LIVE v1 databases (wh01_hydra, wh01_om1,
#   wh01_shipitez, wh02_hydra, wh02_shipitez, wh01_hmg). Those v1 DBs have no
#   flyway_schema_history and must NEVER be migrated with this migration set.
#   The only thing keeping them out of scope is that the tenant list comes from
#   wms2_landlord.tenant_db_configuration, which lists only the v2 DB — so never
#   hand-feed a database name past that discovery step on prd.
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
#   On --env prd, --apply is gated a second time behind --confirm-production.
#   The branch guard alone is not enough there: 'main' is reached by promotion
#   merge, so a stale local 'main' checkout is on the right branch yet the wrong
#   commit, and --status would report a *short* pending list rather than a
#   suspicious one. The extra flag forces the operator to have looked.
#
set -euo pipefail

# ---------------------------------------------------------------- defaults ---
# Empty = "not set explicitly on the command line"; filled from the --env profile
# after parsing, so an explicit flag wins regardless of argument order.
ENV_NAME=""
LANDLORD_HOST="localhost"
LANDLORD_PORT=""
LANDLORD_DB=""
# Profile-driven, NOT a fixed default: prd's landlord role is 'wms2_landlord_app'
# while dev/uat use 'wms_landlord'. Hard-coding one would make the prd profile
# silently wrong in a way that looks like a password failure.
LANDLORD_USER=""
EXPECTED_BRANCH=""
IS_PRODUCTION="no"

# Tenant db_url in the landlord is the APPLICATION's view (e.g. dev.sbo.li:25060).
# An operator on a workstation reaches the same servers through an SSH tunnel.
# These override the host:port parsed out of db_url.
TENANT_HOST_OVERRIDE="localhost"
TENANT_PORT_OVERRIDE=""
TENANT_OVERRIDE_DISABLED="no"

REPO="${WMS2_API_REPO:-}"
MODE="status"
INCLUDE_INACTIVE="no"
ONLY_WAREHOUSE=""
ALLOW_BRANCH_MISMATCH="no"
CONFIRM_PRODUCTION="no"

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; BLU=$'\033[1;34m'; DIM=$'\033[2m'; RST=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$BLU" "$(date +%H:%M:%S)" "$RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$*"; }
die()  { printf '%s[FATAL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Apply pending wms2-api tenant Flyway migrations across every tenant DB in an
environment.

  PGPASSWORD_LANDLORD=... $0 --env dev|uat|prd --repo /path/to/wms2-api [--apply]

Required:
  --env dev|uat|prd        Environment profile. NO DEFAULT — all three are reachable
                           at localhost and differ only by port, so this must be
                           stated explicitly.

                             dev  landlord dev_landlord@localhost:25060
                                  as wms_landlord · branch 'develop'
                             uat  landlord landlord@localhost:25062
                                  as wms_landlord · branch 'release'
                             prd  landlord wms2_landlord@localhost:25061
                                  as wms2_landlord_app · branch 'main'
                                  PRODUCTION — --apply needs --confirm-production

Options:
  --repo PATH              wms2-api checkout. Default: \$WMS2_API_REPO
  --status                 Report only (DEFAULT). Read-only.
  --apply                  Run 'flyway migrate' on tenants that have a history table.
  --warehouse NAME         Limit to one warehouse code (e.g. nywh). Repeatable-safe.
  --include-inactive       Also process rows with active = false (default: skip).
  --allow-branch-mismatch  Permit --apply from a branch other than the env's.
                           Needed for the dev pre-merge flow (runbook §5.4).
  --confirm-production     Required alongside --apply when --env prd. Assert that
                           the change-control checklist (runbook §5.5) is done.

  --landlord-host HOST     Override the --env profile. Default: $LANDLORD_HOST
  --landlord-port PORT     Override the --env profile.
  --landlord-db NAME       Override the --env profile.
  --landlord-user ROLE     Override the --env profile's landlord role.
  --tenant-host HOST       Override host from db_url. Default: $TENANT_HOST_OVERRIDE
  --tenant-port PORT       Override port from db_url. Override the --env profile.
  --no-tenant-override     Use db_url host:port verbatim (run from inside the env).
  -h, --help

Env:
  PGPASSWORD_LANDLORD  password for --landlord-user (required)

Tenant credentials are read from landlord.tenant_db_configuration and are never printed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)                 ENV_NAME="$2"; shift 2;;
    --repo)                REPO="$2"; shift 2;;
    --status)              MODE="status"; shift;;
    --apply)               MODE="apply"; shift;;
    --warehouse)           ONLY_WAREHOUSE="$2"; shift 2;;
    --include-inactive)    INCLUDE_INACTIVE="yes"; shift;;
    --allow-branch-mismatch) ALLOW_BRANCH_MISMATCH="yes"; shift;;
    --confirm-production)  CONFIRM_PRODUCTION="yes"; shift;;
    --landlord-host)       LANDLORD_HOST="$2"; shift 2;;
    --landlord-port)       LANDLORD_PORT="$2"; shift 2;;
    --landlord-db)         LANDLORD_DB="$2"; shift 2;;
    --landlord-user)       LANDLORD_USER="$2"; shift 2;;
    --tenant-host)         TENANT_HOST_OVERRIDE="$2"; shift 2;;
    --tenant-port)         TENANT_PORT_OVERRIDE="$2"; shift 2;;
    --no-tenant-override)  TENANT_OVERRIDE_DISABLED="yes"; shift;;
    -h|--help)             usage; exit 0;;
    *) die "unknown argument: $1 (try --help)";;
  esac
done

# --------------------------------------------------------- env resolution ---
# Fill anything not given explicitly from the --env profile. Explicit flags win,
# whatever order they appeared in.
case "$ENV_NAME" in
  dev)
    : "${LANDLORD_PORT:=25060}"; : "${LANDLORD_DB:=dev_landlord}"
    : "${LANDLORD_USER:=wms_landlord}"
    : "${TENANT_PORT_OVERRIDE:=25060}"; EXPECTED_BRANCH="develop";;
  uat)
    : "${LANDLORD_PORT:=25062}"; : "${LANDLORD_DB:=landlord}"
    : "${LANDLORD_USER:=wms_landlord}"
    : "${TENANT_PORT_OVERRIDE:=25062}"; EXPECTED_BRANCH="release";;
  prd)
    : "${LANDLORD_PORT:=25061}"; : "${LANDLORD_DB:=wms2_landlord}"
    : "${LANDLORD_USER:=wms2_landlord_app}"
    : "${TENANT_PORT_OVERRIDE:=25061}"; EXPECTED_BRANCH="main"
    IS_PRODUCTION="yes";;
  "") die "--env is required (dev|uat|prd). See --help; there is deliberately no default.";;
  *)  die "unknown --env '$ENV_NAME' (expected 'dev', 'uat' or 'prd')";;
esac

# Second gate on production, on top of the branch check below. 'main' is reached
# by promotion merge, so being *on* main does not prove being on the *current*
# main — and a stale checkout under-reports the pending set instead of
# over-reporting it, which is the direction that fails quietly.
if [[ "$IS_PRODUCTION" == "yes" && "$MODE" == "apply" && "$CONFIRM_PRODUCTION" != "yes" ]]; then
  printf '%s[FATAL]%s %s\n' "$RED" "$RST" "--apply against PRODUCTION requires --confirm-production" >&2
  printf '      %s\n' \
    "Before re-running, confirm (runbook §5.5):" \
    "  1. 'git fetch origin main' — the checkout is at CURRENT origin/main, not a stale one" \
    "  2. the pending list from --status is the one you expect for this release" \
    "  3. every pending migration is additive, or the deploy window is agreed" \
    "  4. a backup/snapshot of wh01_hydra_v2 exists" >&2
  exit 1
fi

if [[ "$TENANT_OVERRIDE_DISABLED" == "yes" ]]; then
  TENANT_HOST_OVERRIDE=""; TENANT_PORT_OVERRIDE=""
fi

# ------------------------------------------------------------- preflight ----
[[ -n "${PGPASSWORD_LANDLORD:-}" ]] || die "PGPASSWORD_LANDLORD not set (password for '$LANDLORD_USER')"
[[ -n "$REPO" ]] || die "--repo not set (path to the wms2-api checkout)"
MIGRATION_DIR="$REPO/src/main/resources/db/migration"
[[ -d "$MIGRATION_DIR" ]] || die "not a wms2-api checkout: $MIGRATION_DIR missing"
command -v psql   >/dev/null || die "psql not on PATH"
command -v flyway >/dev/null || die "flyway not on PATH"

log "Preflight (env: $ENV_NAME)"
if [[ "$IS_PRODUCTION" == "yes" ]]; then
  printf '  %s** PRODUCTION (%s) — landlord %s@%s:%s/%s **%s\n' \
    "$RED" "$ENV_NAME" "$LANDLORD_USER" "$LANDLORD_HOST" "$LANDLORD_PORT" "$LANDLORD_DB" "$RST"
fi
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
HEAD_SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"
# '|| true': under `set -o pipefail` a non-matching grep fails the whole
# pipeline, which would abort the script whenever HEAD carries no semver tag.
HEAD_TAG="$(git -C "$REPO" tag --points-at HEAD 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
# PRODUCTION ONLY. On 'main' the tag is almost never ON HEAD: main is reached by a
# promotion merge from release, so the semver tag sits on the merged-in commit. The
# prod build workflow resolves the version with `git describe --abbrev=0` for exactly
# this reason — mirror it, otherwise prod always prints an untagged-looking HEAD.
#
# Deliberately NOT done for dev/uat: there, an empty tag is a signal worth seeing
# (uat should be deployed from a tagged release), and `describe` would paper over it
# with whatever ancient tag happens to be reachable — on develop that is v0.0.1.
if [[ -z "$HEAD_TAG" && "$IS_PRODUCTION" == "yes" ]]; then
  DESC_TAG="$(git -C "$REPO" describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"
  [[ -n "$DESC_TAG" ]] && HEAD_TAG="$DESC_TAG (reachable, not on HEAD)"
fi
ok "repo $REPO"
ok "branch '$BRANCH' @ $HEAD_SHA${HEAD_TAG:+ (tag $HEAD_TAG)}"

# Staleness check. A checkout that is BEHIND its remote passes the branch test
# yet yields a pending list that is too SHORT — migrations the release needs are
# simply absent from disk, so the fleet reports "all current" while the deploy
# goes out against an older schema than it expects.
if UPSTREAM_SHA="$(git -C "$REPO" rev-parse --short "origin/$EXPECTED_BRANCH" 2>/dev/null)"; then
  if [[ "$BRANCH" == "$EXPECTED_BRANCH" && "$HEAD_SHA" != "$UPSTREAM_SHA" ]]; then
    if git -C "$REPO" merge-base --is-ancestor HEAD "origin/$EXPECTED_BRANCH" 2>/dev/null; then
      warn "checkout is BEHIND origin/$EXPECTED_BRANCH ($HEAD_SHA vs $UPSTREAM_SHA) — 'git pull' first"
      printf '      %s\n' "A stale checkout under-reports pending migrations; that failure is silent."
      [[ "$IS_PRODUCTION" == "yes" && "$MODE" == "apply" ]] && \
        die "refusing to --apply to production from a checkout behind origin/$EXPECTED_BRANCH"
    else
      warn "checkout differs from origin/$EXPECTED_BRANCH ($HEAD_SHA vs $UPSTREAM_SHA) — local commits present"
    fi
  fi
else
  warn "origin/$EXPECTED_BRANCH not found locally — run 'git fetch origin $EXPECTED_BRANCH' to enable the staleness check"
fi
if [[ "$BRANCH" != "$EXPECTED_BRANCH" ]]; then
  warn "branch is '$BRANCH', not '$EXPECTED_BRANCH' — $ENV_NAME runs the '$EXPECTED_BRANCH' branch"
  # A mismatched checkout makes the pending set wrong in the dangerous direction:
  # migrations that exist only on a newer branch are reported as "pending" for
  # this environment, and --apply would push them in ahead of the release. Reading
  # is harmless, so --status only warns.
  if [[ "$MODE" == "apply" && "$ALLOW_BRANCH_MISMATCH" != "yes" ]]; then
    printf '      %s\n' \
      "Migrations present only on '$BRANCH' would be applied to $ENV_NAME early." \
      "Intentional (e.g. applying an additive migration from a feature branch" \
      "before merging to develop — runbook §5.4)? Re-run with --allow-branch-mismatch."
    die "refusing to --apply from '$BRANCH' against $ENV_NAME"
  fi
fi

# Lexical sort (NOT sort -V) so this list and the SQL-side list are ordered
# identically for comm(1). Versions are zero-padded (2.2.00..2.2.99), so lexical
# and version order agree; consistency between the two sides is what matters.
FILE_VERSIONS="$(find "$MIGRATION_DIR" -maxdepth 1 -name 'V*.sql' -printf '%f\n' \
            | sed -E 's/^V([0-9.]+)__.*/\1/' | sort -u)"
HIGHEST="$(printf '%s\n' "$FILE_VERSIONS" | sort -V | tail -1)"
ok "migration set: $(printf '%s\n' "$FILE_VERSIONS" | wc -l) scripts, highest = $HIGHEST"

# ------------------------------------------------------- discover tenants ---
log "Discovering tenants from $LANDLORD_USER@$LANDLORD_HOST:$LANDLORD_PORT/$LANDLORD_DB"

# L001 gate, doubling as a wrong-landlord detector.
#
#   (a) Deploy gate (runbook §7): a JAR that reads 'active' against a landlord
#       without the column loads an EMPTY tenant cache and rejects every tenant —
#       fail-silent-open, no crash to alert on. Catch it here, before the deploy.
#   (b) Wrong-landlord detector: on the dev server a stale DB named 'landlord'
#       sits beside the live 'dev_landlord'. It holds one plausible-looking row
#       whose db_url even points at the right host, so nothing downstream would
#       flag it — but it never got L001, so this probe does.
L001_COLS="$(PGPASSWORD="$PGPASSWORD_LANDLORD" psql \
  -h "$LANDLORD_HOST" -p "$LANDLORD_PORT" -U "$LANDLORD_USER" -d "$LANDLORD_DB" \
  -X -tA -c "
    SELECT count(*) FROM information_schema.columns
     WHERE table_name IN ('tenant_discovery','tenant_db_configuration')
       AND column_name = 'active';" 2>&1)" \
  || die "landlord L001 probe failed: $L001_COLS"

if [[ "$L001_COLS" != "2" ]]; then
  bad "landlord '$LANDLORD_DB' is missing the L001 'active' column(s) (found $L001_COLS/2)"
  printf '      %s\n' \
    "Either this is the WRONG landlord DB for --env $ENV_NAME," \
    "or L001__add_active_flag.sql has not been applied yet (runbook §7)." \
    "Deploying a JAR that reads 'active' against this landlord rejects every tenant."
  die "refusing to continue against a pre-L001 landlord"
fi
ok "landlord L001 'active' column present on both tables"

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

  # Integrity of what IS applied. Pending entries are expected here, so they are
  # ignored — this question is only "has an applied script been changed?".
  #
  # Two distinct drifts land here, and the distinction changes nothing about the
  # remedy but everything about reading the output:
  #   checksum    — the file CONTENT changed
  #   description — the FILENAME after the '__' changed (content may be identical)
  # Flyway's own message suggests `repair` for both. For a *content* change that is
  # usually wrong: repair realigns the recorded checksum WITHOUT re-executing, so
  # new statements silently never run. See runbook §8.1.
  if ! VOUT="$(flyway -url="jdbc:postgresql://$HOST:$PORT/$URL_DBNAME" \
                -user="$DB_USER" -password="$DB_PASS" \
                -locations="filesystem:$MIGRATION_DIR" \
                -ignoreMigrationPatterns='*:pending' validate 2>&1)"; then
    DRIFT="drift"
    grep -qi 'checksum mismatch'    <<<"$VOUT" && DRIFT="checksum drift"
    grep -qi 'description mismatch' <<<"$VOUT" && DRIFT="description drift (file renamed)"
    bad "validate FAILED ($DRIFT on an applied migration) — do not migrate"
    printf '%s\n' "$VOUT" | grep -iE 'mismatch|checksum|detected|migration' | head -4 | sed 's/^/      /' || true
    printf '      %s\n' "Do NOT 'flyway repair' a content change — it stamps without re-running (runbook §8.1)."
    R_ERROR+=("$WAREHOUSE/$URL_DBNAME: $DRIFT"); continue
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
