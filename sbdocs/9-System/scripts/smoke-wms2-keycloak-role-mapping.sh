#!/usr/bin/env bash
# wms2 Keycloak group -> bare role mapping smoke (SBDEV-3116).
#
# WHY THIS EXISTS. Every @PreAuthorize(Authority.IS_SB_ADMIN) gate in wms2-api (hasAuthority('sb_admin'))
# and the /actuator/** matcher (hasAnyAuthority("ADMIN","wms_admin")) pass only if the token yields a
# BARE authority string. JwtAccessTokenCustomizer.extractRoles builds the authority set as
#     union( resource_access[<EVERY client>].roles , groups claim entries VERBATIM )
# (realm_access is ignored). With the Group Membership mapper's "full group path" ON, the groups entries
# are "/sb_admin" and match nothing, so the gates depend entirely on Keycloak also emitting each group as
# a bare client role. That is realm config: nothing in wms2-api writes or tests it, so losing it closes
# every admin gate with a green suite and no diff. Run this after any Keycloak realm change and per
# deploy, once per environment x realm.
#
# WHAT IT ASSERTS, for one subject in one realm, for each group G in EXPECT:
#   member     "/G" or "G" is in `groups`           -- the SUBJECT holds G. A FAIL here means "this subject
#                                                      cannot test G", not "the mapping is broken"
#   authority  bare "G" is in extractRoles' union    -- the exact string the gate matches (the invariant)
# plus an INFO line naming which resource_access client(s) carried G. If RA (the tenant's client_id from
# landlord tenant_auth_configuration: om1-api, or wms-user-admin for meridiandemo) is set and G arrived
# only via another client, it prints WARN: the gate still passes, but the realm differs from the others.
#
# LIMITS (cannot be closed from a token alone):
#   - `authority` cannot tell a group->role mapping from a role assigned directly to the user or via a
#     composite. Prefer a subject that holds G ONLY through group membership.
#   - The token comes from CLIENT (default om1, the WMS UI login client). A caller using another client
#     may see different mappers/scopes; pass that CLIENT to test it.
# Account history (who holds sb_admin on which env) lives on SBDEV-3116 and in
# 3-Resources/architecture/wms2-keycloak-role-matrix.md, not here.
#
# Usage (password on stdin; it never reaches argv, and the token is never printed):
#   printf '%s' "$PW" | KC=https://kc2.dev.sbo.li REALM=wineco RA=om1-api SUBJECT=<user> \
#       ./smoke-wms2-keycloak-role-mapping.sh
#   CLIENT   token client_id (default om1)
#   RA       optional; expected resource_access key (WARN-only, see above)
#   EXPECT   space-separated group names, [A-Za-z0-9_-] with subgroups as a/b (default "sb_admin wms_admin wms_user")
# Exit: 0 all PASS · 1 any FAIL · 2 setup/token error.
#
# `set -u` WITHOUT -e/pipefail is deliberate: has() relies on grep's non-zero exit, and every critical
# step (token rc, checked-count, final fail count) is tested explicitly. Do not "harden" it with -e.
set +x; set -u; set -f
KC="${KC:-}"; REALM="${REALM:-}"; SUBJECT="${SUBJECT:-}"
[ -n "$KC" ] && [ -n "$REALM" ] && [ -n "$SUBJECT" ] \
  || { echo "set KC (e.g. https://kc2.dev.sbo.li), REALM and SUBJECT" >&2; exit 2; }
RA="${RA:-}"; CLIENT="${CLIENT:-om1}"; EXPECT="${EXPECT:-sb_admin wms_admin wms_user}"

case "$KC" in https://*) ;; *) echo "refusing: KC must be https" >&2; exit 2;; esac
case "$KC" in *@*|*\?*|*'#'*) echo "refusing: KC must not carry userinfo, query or fragment" >&2; exit 2;; esac
for v in "$REALM" "$CLIENT" "${RA:-x}"; do
  case "$v" in *[!A-Za-z0-9_-]*|'') echo "refusing: odd realm/client value" >&2; exit 2;; esac
done
n=0; for g in $EXPECT; do n=$((n+1)); done
[ "$n" -gt 0 ] || { echo "EXPECT is empty" >&2; exit 2; }
for g in $EXPECT; do
  case "$g" in /*|*[!A-Za-z0-9_/-]*|'') echo "refusing: EXPECT entry '$g' is not [A-Za-z0-9_-]+ (subgroups as a/b, no leading /)" >&2; exit 2;; esac
done
[ -t 0 ] && { echo "pipe the password on stdin" >&2; exit 2; }
for c in curl python3 grep sed; do
  command -v "$c" >/dev/null 2>&1 || { echo "$c not on PATH" >&2; exit 2; }
done

RESP=$(curl -sS --proto '=https' --max-time 15 -X POST "${KC%/}/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "username=$SUBJECT" --data-urlencode "password@-") \
  || { echo "token request: transport failure to $KC" >&2; exit 2; }

# Decode in python; emit tagged lines only, never the token. A claim value carrying a TAB or newline
# could forge a tagged line, so it aborts instead (exit 4).
CLAIMS=$(printf '%s' "$RESP" | python3 -I -c '
import sys, json, base64
try:
    tok = json.load(sys.stdin).get("access_token") or ""
except Exception:
    tok = ""
if not tok:
    sys.exit(3)
try:
    p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
    c = json.loads(base64.urlsafe_b64decode(p))
except Exception:
    sys.exit(4)
def emit(tag, v):
    v = str(v)
    if "\n" in v or "\t" in v or "\r" in v:
        sys.exit(4)
    print("%s\t%s" % (tag, v))
emit("ISS", c.get("iss"))
for g in c.get("groups") or []:
    emit("G", g)
for client, body in (c.get("resource_access") or {}).items():
    for r in (body or {}).get("roles") or []:
        emit("R", r)
        emit("RC", "%s@%s" % (r, client))
')
rc=$?
case $rc in
  0) ;;
  3) echo "token request failed for $SUBJECT@$REALM (no access_token in the response)" >&2; exit 2;;
  *) echo "token for $SUBJECT@$REALM is malformed or carries an unsafe claim value (rc=$rc)" >&2; exit 2;;
esac

pass=0; fail=0; checked=0
row() { # status label detail
  printf '  %-4s  %-28s %s\n' "$1" "$2" "$3"
  case "$1" in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; esac
}
TAB=$(printf '\t')
has() { printf '%s\n' "$CLAIMS" | grep -qxF -e "$1"; }
carriers() { printf '%s\n' "$CLAIMS" | sed -n "s|^RC${TAB}$1@||p" | tr '\n' ' '; }  # | : EXPECT allows /, never |

echo "keycloak role-mapping smoke: $SUBJECT @ $(printf '%s\n' "$CLAIMS" | sed -n "s/^ISS${TAB}//p")  client=$CLIENT${RA:+  RA=$RA}"
for g in $EXPECT; do
  checked=$((checked+1))
  if has "G${TAB}/$g" || has "G${TAB}$g"; then row PASS "member     $g" ""
  else row FAIL "member     $g" "subject is not in group $g, so it cannot test the $g mapping"; fi
  # extractRoles' union: any client's bare role, or a bare (full-path OFF) groups entry
  if has "R${TAB}$g" || has "G${TAB}$g"; then row PASS "authority  $g" ""
  else row FAIL "authority  $g" "no bare '$g' in any resource_access client or groups: $g-gated endpoints will 403"; fi
  via=$(carriers "$g")
  if [ -n "$via" ]; then
    row INFO "  via" "resource_access: $via"
    if [ -n "$RA" ] && ! has "RC${TAB}$g@$RA"; then
      row WARN "  via" "'$g' not under expected client $RA (gate still passes; realm differs)"
    fi
  elif has "G${TAB}$g"; then
    row INFO "  via" "bare groups entry (full-group-path is OFF in this realm)"
  fi
done
[ "$checked" -gt 0 ] || { echo "EXPECT produced no checks" >&2; exit 2; }
echo "Result: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
