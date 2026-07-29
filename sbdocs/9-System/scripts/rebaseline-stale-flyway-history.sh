#!/usr/bin/env bash
#
# rebaseline-stale-flyway-history.sh
#
# For a tenant DB whose flyway_schema_history is WRONG (records an obsolete linear
# history, or is empty) while the schema itself already sits at the V2.2.00
# base-dump watermark: re-baseline the history to a single 2.2.00 row, then apply
# the remaining db/migration deltas with Flyway.
#
# Built for Hydra production (wh01_hydra_v2), which was provisioned 2025-12-13 from
# the then-current db/migration (V1.0.01..V1.1.05). Everything after that — V1.2.x
# UTC + V2.1.01..V2.1.16 — was applied WITHOUT being recorded, so Flyway believes
# the DB is at 1.1.05 and would try to replay V2.2.00 (the full base dump) onto a
# populated schema.
#
# WHY DELETE+INSERT INSTEAD OF DROP+CREATE
#   The existing table carries grants (e.g. wh01_hydra_v2_app, wms2_landlord_app).
#   backfill-flyway-history.sh --drop-existing would DROP the table and recreate it,
#   silently discarding those grants and reassigning ownership. Deleting the rows and
#   inserting the baseline preserves the table, its owner, and its ACL.
#
# SAFETY
#   Refuses unless the schema is verified to be exactly at the baseline watermark:
#   every V2.1.x marker present AND every post-baseline delta absent. That second
#   check is the important one — V2.2.03 is a bare ALTER TABLE ADD COLUMN with no
#   IF NOT EXISTS, so re-running it against a DB that already has those columns fails.
#
set -euo pipefail

HOST="localhost"; PORT="25061"; DBNAME="wh01_hydra_v2"; DBUSER="wh03_om1"
REPO=""; BASELINE="2.2.00"; DRY_RUN="no"; SKIP_DUMP="no"
OUTDIR="./flyway-rebaseline-$(date +%Y%m%d-%H%M%S)"

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'
log(){ printf '%s[%s]%s %s\n' "$BLU" "$(date +%H:%M:%S)" "$RST" "$*"; }
ok(){ printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
die(){ printf '%s[FATAL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage(){ cat <<EOF
Re-baseline a stale/empty flyway_schema_history, then apply pending migrations.

  PGPASSWORD_DB=... $0 --repo /path/to/wms2-api [--dry-run]

  --repo PATH       wms2-api checkout (branch deployed to this env)
  --host/--port     default $HOST:$PORT
  --dbname NAME     default $DBNAME
  --dbuser ROLE     default $DBUSER
  --baseline VER    version to stamp as already-applied (default $BASELINE)
  --outdir DIR      where backups land (default ./flyway-rebaseline-<ts>)
  --skip-dump       skip the pg_dump safety net (only if you already have one)
  --dry-run         print every statement, change nothing
Env: PGPASSWORD_DB  password for --dbuser (required)
EOF
}

while [[ $# -gt 0 ]]; do case "$1" in
  --repo) REPO="$2"; shift 2;; --host) HOST="$2"; shift 2;; --port) PORT="$2"; shift 2;;
  --dbname) DBNAME="$2"; shift 2;; --dbuser) DBUSER="$2"; shift 2;;
  --baseline) BASELINE="$2"; shift 2;; --outdir) OUTDIR="$2"; shift 2;;
  --skip-dump) SKIP_DUMP="yes"; shift;; --dry-run) DRY_RUN="yes"; shift;;
  -h|--help) usage; exit 0;; *) die "unknown arg: $1";;
esac; done

[[ -n "${PGPASSWORD_DB:-}" ]] || die "PGPASSWORD_DB not set"
[[ -n "$REPO" ]] || die "--repo required"
MIG="$REPO/src/main/resources/db/migration"
BACKFILL="$REPO/src/main/resources/db/backfill-flyway-history.sh"
[[ -d "$MIG" ]] || die "no migration dir: $MIG"
[[ -f "$BACKFILL" ]] || die "no backfill script: $BACKFILL"
command -v psql >/dev/null || die "psql not on PATH"
command -v flyway >/dev/null || die "flyway not on PATH"

PSQL=(psql -h "$HOST" -p "$PORT" -U "$DBUSER" -d "$DBNAME" -X -tA)
q(){ PGPASSWORD="$PGPASSWORD_DB" "${PSQL[@]}" -c "$1"; }

log "Target: $DBUSER@$HOST:$PORT/$DBNAME"
q 'select 1' >/dev/null || die "cannot connect"
ok "connected — server $(q 'show server_version')"
ok "repo $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?') @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"

# ---------------------------------------------------------------- guard 1 ---
# Schema must already be at the baseline watermark: V2.1.x markers all present.
log "Guard 1/3 — confirm schema is at the $BASELINE watermark"
declare -A PRESENT=(
  [V2.1.01_uq_unitload_labelid]="select count(*) from pg_constraint where conname='uq_unitload_labelid'"
  [V2.1.03_order_monitor_view]="select count(*) from pg_views where viewname='order_monitor_view'"
  [V2.1.10_rest_idempotency]="select count(*) from pg_tables where tablename='rest_idempotency'"
  [V2.1.11_outbox_message]="select count(*) from pg_tables where tablename='outbox_message'"
  [V2.1.12_cancellation_log]="select count(*) from pg_tables where tablename='customerorder_cancellation_log'"
  [V2.1.15_api_timestamp_fmt]="select count(*) from los_sysprop where syskey='API_TIMESTAMP_FORMAT'"
)
MISSING=0
for k in "${!PRESENT[@]}"; do
  v="$(q "${PRESENT[$k]}")"
  if [[ "$v" == "0" ]]; then warn "MISSING $k"; MISSING=$((MISSING+1)); fi
done
UFR="$(q "select case when pg_get_viewdef('public.replenishment_monitor_view'::regclass,true) like '%useforreplenish%' then 1 else 0 end")"
[[ "$UFR" == "1" ]] || { warn "MISSING V2.1.16 flag-based replenishment_monitor_view"; MISSING=$((MISSING+1)); }
[[ "$MISSING" == "0" ]] || die "$MISSING baseline marker(s) missing — this DB is NOT at $BASELINE. Stop and inspect."
ok "all baseline markers present (V2.1.01..V2.1.16)"

# ---------------------------------------------------------------- guard 2 ---
# Nothing ABOVE the baseline may already be applied, or migrate will re-run a
# non-idempotent script (V2.2.03) and fail.
log "Guard 2/3 — confirm no post-$BASELINE delta is already applied"
declare -A ABSENT=(
  [V2.2.01_section_name_ro_id]="select count(*) from pg_attribute where attrelid='public.replenishment_monitor_view'::regclass and attname in ('section_name','ro_id') and attnum>0 and not attisdropped"
  [V2.2.02_lock_overview_all_view]="select count(*) from pg_views where viewname='lock_overview_all_view'"
  [V2.2.03_moved_columns]="select count(*) from information_schema.columns where table_name='replenishorder' and column_name like 'moved\\_%'"
  [V2.2.04_lane_sysprops]="select count(*) from los_sysprop where syskey in ('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED','REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED')"
)
FOUND=0
for k in "${!ABSENT[@]}"; do
  v="$(q "${ABSENT[$k]}")"
  if [[ "$v" != "0" ]]; then warn "ALREADY PRESENT ($v): $k"; FOUND=$((FOUND+1)); fi
done
[[ "$FOUND" == "0" ]] || die "$FOUND post-baseline delta(s) already applied — re-baselining at $BASELINE would make Flyway re-run them. V2.2.03 is NOT idempotent. Stop."
ok "no post-baseline deltas present — safe to stamp at $BASELINE"

# ---------------------------------------------------------------- guard 3 ---
log "Guard 3/3 — seqentities headroom (seed migrations allocate from it)"
SEQ="$(q 'select last_value from public.seqentities')"; MAXS="$(q 'select coalesce(max(id),0) from los_sysprop')"
if [[ "$SEQ" -gt "$MAXS" ]]; then ok "seqentities=$SEQ > max los_sysprop id=$MAXS"
else warn "seqentities=$SEQ <= max los_sysprop id=$MAXS — seed INSERTs may collide; investigate before --apply"; fi

# ------------------------------------------------------- checksum for base ---
# Reuse backfill-flyway-history.sh's CRC32 (Flyway's own algorithm) rather than
# reimplementing it, so `flyway validate` agrees afterwards.
CK="$(PGPASSWORD_OWNER=x "$BACKFILL" --dbname "$DBNAME" --owner "$DBUSER" --up-to "$BASELINE" --dry-run 2>/dev/null \
      | grep -oE "checksum=-?[0-9]+" | tail -1 | cut -d= -f2)"
[[ -n "$CK" ]] || die "could not compute checksum for $BASELINE"
BASE_SCRIPT="$(cd "$MIG" && ls V${BASELINE}__*.sql)"
BASE_DESC="$(printf '%s' "$BASE_SCRIPT" | sed -E "s/^V${BASELINE}__//; s/\\.sql$//; s/_/ /g")"
ok "baseline row: $BASE_SCRIPT  checksum=$CK"

REBASE_SQL=$(cat <<SQL
BEGIN;
DELETE FROM "flyway_schema_history";
INSERT INTO "flyway_schema_history"
  ("installed_rank","version","description","type","script","checksum","installed_by","installed_on","execution_time","success")
VALUES (1, '$BASELINE', '$BASE_DESC', 'SQL', '$BASE_SCRIPT', $CK, '$DBUSER', now(), 0, TRUE);
COMMIT;
SQL
)

if [[ "$DRY_RUN" == "yes" ]]; then
  log "--dry-run — nothing will change"
  echo "$REBASE_SQL"
  echo; log "then: flyway -url=jdbc:postgresql://$HOST:$PORT/$DBNAME -user=$DBUSER -locations=filesystem:$MIG migrate"
  exit 0
fi

mkdir -p "$OUTDIR"

# ------------------------------------------------------------------ backup ---
log "Backups → $OUTDIR"
PGPASSWORD="$PGPASSWORD_DB" "${PSQL[@]}" -c "\\copy (select * from flyway_schema_history order by installed_rank) to '$OUTDIR/flyway_schema_history.csv' csv header"
ok "history rows archived to $OUTDIR/flyway_schema_history.csv ($(q 'select count(*) from flyway_schema_history') rows)"
# Best-effort: these are rollback aids, not preconditions. A view that does not
# exist yet is fine (V2.2.02 creates lock_overview_all_view from nothing), and a
# missing one must not abort the run.
for v in replenishment_monitor_view lock_overview_dto_view lock_overview_all_view; do
  if [[ "$(q "select count(*) from pg_views where schemaname='public' and viewname='$v'")" == "1" ]]; then
    q "select pg_get_viewdef('public.$v'::regclass,true)" > "$OUTDIR/pre_$v.sql"
    ok "saved pre-change definition of $v"
  else
    warn "$v does not exist yet — no pre-image to save"
  fi
done
if [[ "$SKIP_DUMP" == "no" ]]; then
  log "pg_dump (this can take a while)"
  PGPASSWORD="$PGPASSWORD_DB" pg_dump -h "$HOST" -p "$PORT" -U "$DBUSER" -d "$DBNAME" -Fc -f "$OUTDIR/$DBNAME.dump"
  ok "full dump: $OUTDIR/$DBNAME.dump ($(du -h "$OUTDIR/$DBNAME.dump" | cut -f1))"
else warn "--skip-dump: relying on your external backup"; fi

# -------------------------------------------------------------- rebaseline ---
log "Re-baselining history to a single $BASELINE row (table/owner/grants preserved)"
PGPASSWORD="$PGPASSWORD_DB" psql -h "$HOST" -p "$PORT" -U "$DBUSER" -d "$DBNAME" -X -v ON_ERROR_STOP=1 -q <<<"$REBASE_SQL"
ok "history now: $(q "select count(*)||' row @ '||max(version) from flyway_schema_history")"

# ------------------------------------------------------------------ migrate --
# Capture the exit status BEFORE piping. Piping into grep would mask a failed
# migrate behind grep's status, and a trailing '|| true' (needed for a
# non-matching grep) would swallow it entirely — the script would report success
# on a half-migrated production database.
log "flyway migrate"
set +e
MOUT="$(PGPASSWORD="$PGPASSWORD_DB" flyway -url="jdbc:postgresql://$HOST:$PORT/$DBNAME" \
        -user="$DBUSER" -password="$PGPASSWORD_DB" -locations="filesystem:$MIG" migrate 2>&1)"
MRC=$?
set -e
printf '%s\n' "$MOUT" | grep -E 'Migrating|Successfully|up to date|ERROR' | sed 's/^/      /' || true
if [[ $MRC -ne 0 ]]; then
  printf '%s\n' "$MOUT" | grep -iE 'error|caused|sql state' | head -8 | sed 's/^/      /' || true
  die "flyway migrate FAILED (exit $MRC). The DB may be PARTIALLY migrated.
       History baseline was already rewritten — do NOT re-run this script.
       Inspect flyway_schema_history for a success=false row, fix the cause,
       run 'flyway repair', then 'flyway migrate'. Backups: $OUTDIR"
fi

# ------------------------------------------------------------------ verify ---
log "Verify"
set +e
VOUT="$(flyway -url="jdbc:postgresql://$HOST:$PORT/$DBNAME" -user="$DBUSER" -password="$PGPASSWORD_DB" \
        -locations="filesystem:$MIG" validate 2>&1)"
VRC=$?
set -e
printf '%s\n' "$VOUT" | grep -E 'validated|ERROR' | sed 's/^/      /' || true
[[ $VRC -eq 0 ]] || warn "validate returned $VRC — review the output above"
q "select installed_rank||'  '||version||'  '||script||'  success='||success from flyway_schema_history order by installed_rank" | sed 's/^/      /'
echo
for k in "${!ABSENT[@]}"; do printf '      %-34s now=%s\n' "$k" "$(q "${ABSENT[$k]}")"; done
echo
ok "done — backups in $OUTDIR"
