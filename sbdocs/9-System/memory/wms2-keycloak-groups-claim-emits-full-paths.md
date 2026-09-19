---
name: wms2-keycloak-groups-claim-emits-full-paths
description: "Nam 2026-08-26 (IMPORTANT): Keycloak group /sb_admin IS the WMS sb_admin role, likewise /wms_admin and /wms_user — the group is mapped to a BARE client role on om1-api, and that bare role is what hasAuthority() matches; the full-path groups entry matches nothing and no code strips paths"
metadata:
  node_type: memory
  type: reference
---

> ## ⚠ THE RULE — Nam, 2026-08-26. "Remember this, it's very important."
>
> **The Keycloak group `/sb_admin` IS the `sb_admin` role inside the WMS app. Same for `/wms_admin`
> and `/wms_user`.** Group and app role are one identity, not two axes to reconcile.
> **The WMS token decoder does that role mapping from the token.**

## The decoder that does it

`JwtAccessTokenCustomizer` — wired as the authentication converter at
**`SecurityConfiguration.java:112`**, `.jwtAuthenticationConverter(jwtAccessTokenCustomizer(...))`.
Its `extractRoles` builds the authority set from **both** claim sources:

```java
// every client under resource_access, every role — BARE
jwt.path("resource_access").elements().forEachRemaining(e ->
    e.path("roles").elements().forEachRemaining(r -> roles.add(r.asText())));
// every groups entry — VERBATIM, full path kept
jwt.path("groups").elements().forEachRemaining(r -> roles.add(r.asText()));
```

**Measured on kc2.dev.sbo.li / realm `wineco` / client `om1`, 2026-08-26** (password grant, JWT decoded):

| account | `groups` | `resource_access[om1-api].roles` |
|---|---|---|
| `panderson` (sb_admin) | `/sb_admin`, `/wms_admin`, `/wms_user`, `/warehouse/wsl` | `wms_admin`, **`sb_admin`**, `wms_user` |
| `sbtest` (customer admin) | `/wms_user`, `/warehouse/develop`, `/warehouse/wsl` | `wms_user` |

So the authority set holds **both** forms, and `hasAuthority('sb_admin')` matches the **bare** copy that
came in via `resource_access`. Keycloak emits each group as a client role as well — that is the mapping,
and it happens in Keycloak plus the decoder, never by string-munging in Java (nothing in `src/main`
strips a path; `CustomMethodSecurityExpressionRoot.isAimAdmin()` just calls
`hasAuthority(SB_ADMIN_ROLE)`).

**Practical rule:** to test whether a user *holds* an app role, read `resource_access[<client>].roles`.
To ask who *should* hold it, the answer is the Keycloak group of the same name. `hasResourceRole` CAN
see `sb_admin` — under `om1-api`, not under the `om1` auth client, and that clientId mismatch (not any
groups-claim property) is why SBDEV-2732's first UI gate failed.

## 🔴 Dead security config that reads as authoritative

`SecurityConfiguration.java:83-89` defines a `jwtAuthenticationConverter()` bean:

```java
authoritiesConverter.setAuthorityPrefix("");
authoritiesConverter.setAuthoritiesClaimName("resource_access.om1-api.roles");
```

**It is never wired.** Line 112 passes `jwtAccessTokenCustomizer(...)` instead, so this bean has zero
effect. Anyone reading `SecurityConfiguration` top-down will conclude authorities come from
`om1-api` only — they come from **every** client plus `groups`. Delete it or wire it; do not reason
from it. (I did, and was wrong for two messages.)

## What the repo's docs get wrong

`Authority.java:62-66` and `wms2-keycloak-role-matrix.md:174` say the mapper "must emit the BARE group
name, not the full path (`/wms/wh/wms_admin`)". The realm emits full paths and every gate still passes,
because the bare copy arrives via `resource_access`. The docs' conclusion ("this works") is right; the
stated mechanism is wrong. **Do not "fix" Keycloak to emit bare group names** — that is not what makes
this work.

Still a real operational dependency: if the group→client-role mapping were dropped in Keycloak, the 20
`IS_SB_ADMIN` gates and `/actuator/**` would close **silently** — no lane evaluates `@PreAuthorize`, and
`TenantPoolEndpointSecurityTest` is `@Disabled`.

## Re-running the probe

```
curl -s -X POST https://kc2.dev.sbo.li/realms/wineco/protocol/openid-connect/token \
  -d grant_type=password -d client_id=om1 -d username=<u> --data-urlencode "password=<p>"
```
base64-decode the JWT payload, read `groups` and `resource_access`. Tenant discovery gives realm/client:
`GET https://wms-api.dev.sbo.li/api/public/authConfig?key=<key>`; the dev landlord's `tenant_discovery`
lists keys (only **`wsl-wineco`** is active; UI at `https://wsl-wineco.wms.dev.sbo.li`).

See [[sb-admin-is-siteboss-super-admin-via-groups-claim]],
[[wms2-authz-axis-keycloak-coarse-functions-fine]], [[wms2-web-ui-headless-browser-recipe]].
