---
name: dev-keycloak-token-claims-sid-no-auth-time
description: DEV WMS Keycloak access tokens carry sub + sid but NO auth_time / session_state; lifetime 7200 s (measured 2026-11-03)
metadata:
  node_type: memory
  type: reference
  originSessionId: a7d0928f-0a6e-42cd-a139-4f2850cf7a35
  modified: 2026-11-03T15:28:03.403Z
---

Decoded a DEV WMS access token (wms-dev-probe token, claim NAMES only) on 2026-11-03 for SBDEV-3509:
`sid` and `sub` present; **`auth_time` and `session_state` ABSENT**; `exp - iat` = **7200 s**.
PRD/UAT realm lifespans were not readable from here.

**Why it matters:** any client-side "which login is newer" logic cannot use `auth_time`; SBDEV-3509
used a retired-session list with a time-to-live instead. Don't assume a 2 h token outside DEV.
Note the probe token is a direct-grant token, and direct grant may omit `auth_time`. A browser-flow
token could carry it, so check before relying on its absence there.

**How to read it without leaking the token:** `bash -c 'source .claude/skills/wms-dev-probe/scripts/env.sh; …'`
then base64-decode the middle segment of `$TOKEN_FILE` and print `sorted(keys)` only. `token.sh`'s
stdout is a status line, not the token or a path.

Related: [[hub-envs-deploys]] · [[hub-wms-ui]]
