---
name: wms-v1-vs-v2-dev-api-hostnames
description: v1 dev API is the per-warehouse subdomain wms-api.<client>.dev.sbo.li; v2 is the single tenantless wms-api.dev.sbo.li/v3 — the tenant-looking host is v1
metadata:
  type: reference
---

**v2 dev API = `https://wms-api.dev.sbo.li/v3`** — ONE deployment for all tenants; the tenant is
chosen by the `X-Tenant-ID` + `facility_code` headers (see [[wms2-dev-landlord-is-dev-landlord-not-landlord]]).

**v1 dev API = `https://wms-api.<client>.dev.sbo.li`** — e.g. `wms-api.wineco.dev.sbo.li`. v1 has no
in-app tenant routing, so it gets one deployment per warehouse, hence the client in the hostname.

**The trap:** `wms-api.wineco.dev.sbo.li` reads like "the v2 API for tenant wineco" — the tenant
subdomain looks like v2 multi-tenancy when it is actually v1's per-warehouse split. It is **v1**.
`v2/wms2-web-ui/nuxt.config.js:89` reinforces the error with a commented-out
`baseURL: 'https://wms-api.wineco.dev.sbo.li/v3'`. Cost me a whole QA session called "blocked".

**Symptom when you aim v2 calls at v1:** `401 invalid_token` with an XML
`<UnauthorizedException>` body and `Cannot convert access token to JSON`. That string comes from
legacy `spring-security-oauth2` `JwtAccessTokenConverter.decode()`, which exists **only** in
`v1/wms-api` (`JwtAccessTokenCustomizer.java`) and appears nowhere in v2 develop. It reads as a bad
token or a Keycloak misconfiguration; it actually means **wrong application**. The token is fine.

**Three cheap discriminators — GET `/v3` unauthenticated and read the repo names:**
- v1 → `mywmsUser`, `mywmsGroupMywmsRole`, `billoflading` (legacy `Mywms*` entities)
- v2 → `user`, `userGroup`, `userGroupUser`, `userGroupUserRole`, `userRole`
- `GET /api-docs` → **401 on v1** (its permitAll lists `/v2/api-docs/**`, not `/api-docs`), **200 on v2**
- v1 `/actuator/health` shows `clientConfigServer` + `discoveryComposite` (Spring Cloud Config/Eureka)

**Authoritative way to find the API URL for any environment** — do not guess and do not trust
`nuxt.config.js`: fetch the deployed UI and read `window.__NUXT__.config.axios.baseURL` out of the
inline script (`curl -s https://<ui-host> | grep __NUXT__`). Get the UI host from
`landlord.tenant_discovery.web_redirect_url` (see [[wms2-tenant-discovery-key-is-warehouse-client]]).

**The working v2 dev header pair is `X-Tenant-ID: wineco` + `facility_code: wsl`.** Not `wh01` —
that is the *database* name (`dev_wh01_om1`), not the facility code, and guessing it yields a bare
`401` that looks like a token problem (see the trap above). Derive it, never guess:
`SELECT t.name, c.warehouse, c.active FROM tenant t JOIN tenant_db_configuration c ON c.tenant_id=t.id`
on the landlord-dev MCP. On dev only `wineco/wsl` has `active = true`; hydra and shipitez rows exist
but are inactive.
