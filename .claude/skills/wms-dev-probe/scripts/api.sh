#!/usr/bin/env bash
# api.sh METHOD PATH [JSON]: call the DEV WMS v2 API as the cached token's user.
# Sends X-Tenant-ID + facility_code. Prints the body, then "HTTP <code>".
# Exit: 0 = 2xx; 1 = any other HTTP status; 2 = usage/transport failure (HTTP 000).
#   ⚠ StockUnitController-style endpoints answer a business error as HTTP 200 + {"errors":[...]}, which
#     exits 0: read the body, or test it (`| grep -q '"errors"'`) before chaining.
# The token is passed as a header FILE (curl -H @file), the body on stdin: neither appears in argv.
# /api/public/* is called without a token (the dev API answers 401 to a token there).
set +x; set -uo pipefail
. "$(dirname "$0")/env.sh" || exit 2
M=${1:?usage: api.sh METHOD PATH [JSON]}; P=${2:?usage}; B=${3-}
case "$P" in /*) ;; *) echo "PATH must start with /" >&2; exit 2;; esac
PUBLIC=0; case "$P" in /api/public/*) PUBLIC=1;; esac
call() {
  local auth=(); [ $PUBLIC -eq 1 ] || auth=(-H "@$HDR_FILE")
  if [ -n "$B" ]; then
    printf '%s' "$B" | curl -s --max-time 60 -w '\nHTTP %{http_code}\n' -X "$M" "$WMS_DEV_HOST$P" "${auth[@]}" \
      -H "X-Tenant-ID: $WMS_DEV_TENANT" -H "facility_code: $WMS_DEV_FACILITY" -H 'Content-Type: application/json' --data-binary @-
  else
    curl -s --max-time 60 -w '\nHTTP %{http_code}\n' -X "$M" "$WMS_DEV_HOST$P" "${auth[@]}" \
      -H "X-Tenant-ID: $WMS_DEV_TENANT" -H "facility_code: $WMS_DEV_FACILITY"
  fi
}
if [ $PUBLIC -eq 0 ] && [ ! -s "$HDR_FILE" ]; then "$(dirname "$0")/token.sh" >/dev/null || exit 2; fi
OUT=$(call); CODE=$(tail -1 <<<"$OUT" | awk '{print $2}')
if [ "$CODE" = 401 ] && [ $PUBLIC -eq 0 ]; then
  echo "(401: refreshing the token once)" >&2
  "$(dirname "$0")/token.sh" >/dev/null || exit 2
  OUT=$(call); CODE=$(tail -1 <<<"$OUT" | awk '{print $2}')
fi
printf '%s\n' "$OUT"
case "$CODE" in 2??) exit 0;; 000|"") exit 2;; *) exit 1;; esac
