# Sourced by the wms-dev-probe scripts. Dev only, by construction.
set +x   # never trace: these scripts handle a password and a bearer token
#
# Credentials: ~/.config/wms-dev-probe/credentials, owned by you, mode 600. It is PARSED, never
# shell-sourced, so a password may contain $ % \ ; spaces. One KEY=VALUE per line; the value is
# everything after the first '='. Allowed keys only:
#     WMS_DEV_USER  WMS_DEV_PASSWORD  WMS_DEV_KEY  WMS_DEV_TENANT  WMS_DEV_FACILITY
# The host, DB allow-list and paths are NOT overridable from that file.
WMS_DEV_HOST=https://wms-api.dev.sbo.li            # the ONLY API host these scripts talk to
WMS_DEV_DB_SERVER=wms2-wineco-dev                  # the ONLY DB (MCP server name -> dev_wh01_om1)
WMS_DEV_DB_ALLOW=dev_wh01_om1
CRED=$HOME/.config/wms-dev-probe/credentials
umask 077
mkdir_secure() {  # $1 = dir; refuse a symlink, a dir we don't own, or a loose mode
  mkdir -p -m 700 "$1" 2>/dev/null
  if [ -L "$1" ] || [ ! -O "$1" ] || [ "$(stat -c %a "$1" 2>/dev/null)" != 700 ]; then
    echo "refusing: insecure dir $1 (fix: rm -rf '$1' && mkdir -m 700 '$1')" >&2; return 2
  fi
}
# tokens: per-boot runtime dir when available; snapshots: persistent cache (survive a reboot)
STATE=${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/wms-dev-probe}; STATE=${STATE:-$HOME/.cache/wms-dev-probe/run}
SNAPDIR=$HOME/.cache/wms-dev-probe/snap
mkdir_secure "$HOME/.cache/wms-dev-probe" && mkdir_secure "$STATE" && mkdir_secure "$SNAPDIR" || { return 2 2>/dev/null || exit 2; }

WMS_DEV_USER=""; WMS_DEV_PASSWORD=""; WMS_DEV_KEY=wsl-wineco; WMS_DEV_TENANT=wineco; WMS_DEV_FACILITY=wsl
if [ -e "$CRED" ]; then
  if [ ! -f "$CRED" ] || [ -L "$CRED" ] || [ ! -O "$CRED" ] || [ "$(stat -c %a "$CRED")" != 600 ]; then
    echo "refusing: $CRED must be a regular file you own, mode 600 (fix: chmod 600 '$CRED')" >&2; return 2 2>/dev/null || exit 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; [ -z "$line" ] && continue; case "$line" in \#*) continue;; esac
    k=${line%%=*}; v=${line#*=}
    case "$k" in
      WMS_DEV_USER|WMS_DEV_PASSWORD|WMS_DEV_KEY|WMS_DEV_TENANT|WMS_DEV_FACILITY) printf -v "$k" '%s' "$v";;
      *) echo "warning: ignoring unknown key '$k' in $CRED" >&2;;
    esac
  done < "$CRED"
fi
for v in WMS_DEV_KEY WMS_DEV_TENANT WMS_DEV_FACILITY; do
  [[ "${!v}" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "refusing: $v='${!v}' must be [A-Za-z0-9_-]" >&2; return 2 2>/dev/null || exit 2; }
done
SAFE_USER=$(printf '%s' "$WMS_DEV_USER" | tr -c 'A-Za-z0-9_.-' '_')
TOKEN_FILE=$STATE/token-$WMS_DEV_KEY-$SAFE_USER    # per user: switching users never reuses a token
HDR_FILE=$TOKEN_FILE.hdr                           # "Authorization: Bearer ..." for curl -H @file
