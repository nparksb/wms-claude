---
title: "Runbook: Onboard a new WMS v2 tenant and warehouse (DEV / UAT / PRD)"
type: runbook
status: draft
version: "wms2-api v0.0.43+ (PR #557/#559) · oms-laravel-api v2.0.142+ (PR #824/#829/#850) · siteboss-frontend v2.0.52+ (PR #785/#789) — first shipped together in OWL release v2.0.161"
scope: wms2-api v2 + oms-laravel-api + siteboss-frontend / DEV + UAT + PRODUCTION
owner: nam.park@siteboss.net
created: 2026-11-09
updated: 2026-11-09
last_verified: ""
verified_by: ""
alert: "New client or new warehouse going live on WMS v2; replaces the unfinished 'Per-Tenant WMS Dev Environment — Provisioning Playbook' Google Doc (SBDEV-1535)"
severity: SEV3
escalation: "WMS backend owner before any manual SQL on the landlord DB or any DROP; infra (Joe) for DNS/TLS/Portainer/PG role grants; Keycloak admin for realm-level fixes and the create-realm identity"
related:
  - "[[wms2-tenant-routing-datasource-topology]]"
  - "[[wms2-landlord-vs-tenant-entity-map]]"
  - "[[wms2-keycloak-role-matrix]]"
  - "[[wms2-apply-pending-tenant-flyway]]"
  - "[[wms2-database-setup-guide]]"
  - "[[wms2-greenfield-db-provisioning]]"
  - "[[260901-wms2-multitenancy-readiness-audit]]"
tickets:
  - SBDEV-3193
  - SBDEV-1535
  - SBDEV-3868
tags:
  - runbook
  - provisioning
  - multitenancy
  - keycloak
---

# Runbook: Onboard a new WMS v2 tenant and warehouse

> [!warning] GATE — PRD last. This runbook has never been run end to end.
> Every step is grounded in code on `origin/main` of the three repos, but the sequence has **not yet
> been executed against a live tenant**. **Do not onboard on PRODUCTION** until §6 has been run in
> full on **DEV and UAT** and both runs are recorded in the §9 verification log (date, tenant/warehouse,
> rows run, who). If that log still says "not yet run", stop and run DEV first.
> On PRD: announce in the ops channel before §3.2, have the WMS backend owner and the Keycloak admin on
> the call, and never run during a deploy or a Flyway apply (`wms2-apply-pending-tenant-flyway`).

**Placeholders used throughout**

| Placeholder | Meaning | Example |
|---|---|---|
| `<t>` / `<tenant>` | OMS tenant **name** (slug) — also the Keycloak realm name | `wineco` |
| `<wh>` | warehouse code = **lower-cased** OMS facility code | `wsl` |
| `<WH>` | the same, upper-cased (as stored in sysprops / Keycloak attribute) | `WSL` |
| `<env>` | `dev`, `uat` or `prd` (script flag) | `uat` |
| `<api-host>` | `wms-api.dev.sbo.li` · `wms-api.uat.sbo.li` · `wms-api.sbo.li` | |
| `<ui-domain>` | `wms.dev.sbo.li` · `wms.uat.sbo.li` · `wms.sbo.li` | |
| `<FACILITY>` | the OMS facility code as entered in the OMS | `WSL` |
| `<role>` | the WMS landlord DB role: `wms_landlord` (DEV/UAT), `wms2_landlord_app` (PRD) | |
| `<keycloak-host>` | `kc2.dev.sbo.li` (DEV), `kc2.sbo.li` (PRD); UAT: confirm | |
| `<admin-client>` | the master-realm admin client the OMS uses (UAT: `owl-admin-cli`; PRD: Q-INFRA-4) | |
| `<pool_max>` / `<pool_min_idle>` | the chosen pool size (§4) | `10` / `1` |

**Secrets rule for every step.** The landlord DB stores tenant DB passwords and Keycloak secrets in
**plaintext** (`tenant_db_configuration.db_password`, `tenant_auth_configuration.client_secret`,
`svc_password`). Always name columns — **never `SELECT *`** from those tables — and never paste
passwords, tokens, client secrets or error bodies containing them into ClickUp, Slack or this vault.

## 0. Read this first — the model changed

The old per-tenant playbook (SBDEV-1535) assumed **one container stack per tenant** with placeholder
values `TENANT`, `BASE_DOMAIN`, `API_IMAGE`. That is the v1 model. **WMS v2 does not work that way**,
and reproducing that model to fill the placeholders would be wrong:

| Thing | v1 / old playbook | WMS v2 today |
|---|---|---|
| API | one deployment per warehouse | one **logical** `wms2-api` deployment per environment (`<api-host>`), serving every tenant, plus a cron instance (`app.cron=true`, i.e. env `APP_CRON=true`). Planned scale: start at 1 replica, then 2, max 3 (SBDEV-3193 Q2). *Live replica count and which service sets `app.cron` are unverified — Q-INFRA-1/5/6* |
| UIs | per tenant | one `wms2-web-ui` and one `wms2-mobile-ui` per environment on hosts `<wh>-<t>.<ui-domain>` (mobile = `/mobile/` on the same host) |
| Tenant selection | static `spring.datasource.url` | per request: `X-Tenant-ID` + `facility_code` headers → `TenantDynamicRoutingDataSource` |
| Tenant DB coordinates | env vars per instance | rows in the **landlord DB** |
| Onboarding a warehouse | new stack + env file + Traefik labels | **one idempotent API call** that creates the DB, migrates it and registers it |

So onboarding a warehouse touches **data**, not infrastructure: landlord rows, a Postgres database,
Keycloak realm pieces, and a hostname the wildcard is expected to cover (P9). **No Portainer stack,
image, env file or Traefik label is created per tenant.**

### Two keys — do not confuse them

| Key | Format | Example | Used by |
|---|---|---|---|
| **UI discovery key** | `<wh>-<t>` | `wsl-wineco`, `nywh-shipitez` | the UI hostname and `GET /api/public/authConfig?key=…` → `tenant_discovery.key` |
| **API routing key** | `first4(<t>)-<wh>` | `wine-wsl`, `ship-nywh`, `hydr-nywh` | the per-tenant Hikari pool / JWT decoder (`TenantKeyBuilder.buildKey`, `landlord/config/TenantKeyBuilder.java:18-26`); pool name `HikariPool-<key>` |

Input limits, all enforced in code (`landlord/service/TenantWarehouseProvisioningService.java` on
`origin/main`):
- Warehouse code `^[a-z0-9]{1,20}$` (`:76`) — **no dash**: the UI splits the host on the first dash.
  The OMS form caps the facility code at 10 characters.
- Tenant name `^[a-z][a-z0-9_]{0,49}$` (`:69`) — no dash either.
- Discovery key `<wh>-<t>` ≤ 50 characters (`:734`); realm ≤ 50; credentials ≤ 100; URLs ≤ 255.
- Role name `wms2_<t>_<wh>_app` ≤ 63 bytes (`:608-615`), so the DB name `wms2_<t>_<wh>` is effectively
  ≤ 59. A long tenant name can pass the regex and still be refused (400).
- Two tenants whose names share the first four letters cannot use the same warehouse code: **409**
  (`checkRoutingKeyFree`, `:277-291`; counts deactivated rows too).
- The OMS sends `facility_code = strtolower(<OMS facility code>)` (`WmsApiService.php`), so the WMS
  warehouse code **is** the lower-cased OMS facility code.
- **Tenant names and warehouse codes cannot be renamed** after provisioning. A typo is permanent
  (deactivate per §7 and provision again under the right name).

### Who does what

```
Operator ──► SiteBoss Admin (siteboss-frontend)
               │  New Tenant Wizard            Facilities ▸ "Set up WMS warehouse"
               ▼                                  ▼
             OMS (oms-laravel-api) ───────────────┤
               │ creates realm, MySQL DBs,        │ PUT /landlord/tenants/{t}/warehouses/{w}
               │ users, oms-s2s identity          │   (master-realm token, create-realm role)
               ▼                                  ▼
             Keycloak                          wms2-api ──► WMS Postgres cluster
               ▲   groups, claims, wms_user,      creates DB + role, Flyway,
               │   redirect URIs, wms-user-admin  sysprops, 4 landlord rows
               └── done by the OMS after the PUT (WmsKeycloakAccess)
```

**wms2-api makes no Keycloak admin calls during provisioning** — all Keycloak setup is the OMS's.
(Later, the WMS User Management screen does call the Keycloak admin API, using the stored
`wms-user-admin` login.)

---

## 1. One-time prerequisites, per environment

Do these once per environment. Record each check's result in §9.

| # | Prerequisite | Owner | How to check (pass value) |
|---|---|---|---|
| P1 | **Release order**: wms2-api ≥ v0.0.43, then OMS ≥ v2.0.142, then portal ≥ v2.0.52 | release owner | `curl -s https://<api-host>/api/public/version`; OMS/portal: `docs/releases/owl-v2.0.161/developer.md` |
| P2 | **WMS landlord role can create databases and roles**: `ALTER ROLE <role> CREATEDB CREATEROLE;` as a superuser on the WMS Postgres cluster. Role: `wms_landlord` (DEV/UAT), `wms2_landlord_app` (PRD). **Read §8.4 (blast radius) first** | infra (Joe) / DBA | `SELECT rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname = '<role>';` → `t`, `t`. Without it provisioning fails with a message naming this statement |
| P3 | **Landlord role owns the landlord tables** (else landlord Flyway `ALTER TABLE` fails 42501 — seen on UAT) | infra / DBA | in the landlord DB: `SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'public';` → every `tableowner` = the P2 role |
| P4 | **OMS landlord migrations** applied: `2026_10_22_100002_add_wms_provisioning_configuration` seeds the `wms.provisioning.*` Configs rows (`2026_10_23_100000` rewrites their descriptions; `2026_10_22_100000/100001` are the demo tables) | OMS release owner | rows visible in SiteBoss Admin ▸ Configs, category `wms` |
| P5 | **OMS → Keycloak admin identity has the master-realm role `create-realm`**: `KEYCLOAK_ADMIN_USERNAME`/`_PASSWORD` or `KEYCLOAK_ADMIN_CLIENT_ID`/`_SECRET` (UAT used client `owl-admin-cli`) | Keycloak admin | read-only probe in P12 returns 404, not 403 |
| P6 | **wms2-api trusts that same Keycloak's master realm**: `wms.landlord-admin.issuer-uri` (falls back to `rest.security.issuer-uri`) = master realm of the OMS's `KEYCLOAK_SERVER_URL`; `rest.security.enabled=true` (`LandlordAdminSecurityConfiguration.java:64-102`) | infra (Joe) | read-only probe in P12 returns 404, not 401. With `rest.security.enabled=false` the `/landlord/**` endpoints are **not mapped at all** |
| P7 | **OMS env**: `TENANT_BASE_DOMAIN` starts with `oms.` (e.g. `oms.dev.sbo.li`) so the WMS hosts derive; else set `wms.provisioning.api_url` and `wms.provisioning.ui_domain` in Admin ▸ Configs (**system level only**) | OMS owner | §2.2 derivation table |
| P8 | **OMS MySQL user** has CREATE/DROP on `om1_*` and `LOCK TABLES` on new `om1_*` DBs (DEV lacked it until granted) | DBA | tenant creation (§2) fails at DB creation otherwise |
| P9 | **Wildcard DNS + TLS + router** for `*.<ui-domain>` | infra (Joe) | `curl -sI https://<any-wh>-<any-tenant>.<ui-domain>/` → 200 with a valid certificate for that host. *Unverified on every env — Q-INFRA-2* |
| P10 | **OMS hosts allowed to reach WMS `/rest/**`**. The OMS calls these **unauthenticated** — the WMS trusts the network. Anything on that allow-list that sets the tenant headers can reach every tenant's `/rest/**`, so add only the OMS egress and **never widen it** | infra (Joe) | checked per warehouse in V12 |
| P11 | **Staff can obtain a master-realm token** for the read-only status call (see P12) | Keycloak admin | P12 succeeds |

### P12 — read-only master-realm token for status checks

V2 and the P5/P6 probe need a master-realm token carrying `create-realm`. Ask the Keycloak admin for
access to the existing OMS admin client (UAT: `owl-admin-cli`, client-credentials grant; PRD: confirm
the name — Q-INFRA-4). Fetch it **without echoing or logging** it:

```bash
# Secret and token go through stdin, never argv (argv is visible in `ps` on a shared host).
read -rs KC_SECRET                     # paste the client secret; nothing is printed
TOKEN=$(printf 'client_secret=%s' "$KC_SECRET" | curl -s -X POST \
  "https://<keycloak-host>/realms/master/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id=<admin-client> --data-binary @- | jq -r .access_token)
unset KC_SECRET
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "token request failed - stop"; }
# P5/P6 probe — a pair that does not exist (both names satisfy the §0 regexes):
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -s -o /dev/null -w '%{http_code}\n' -H @- \
  "https://<api-host>/landlord/tenants/zzcheck/warehouses/zz"
# 404 = token accepted (P5+P6) · 401 = issuer mismatch (P6) · 403 = no create-realm (P5)
```

A 404 is also what an **unmapped** route returns when `rest.security.enabled=false`, so P5/P6 pass only
once V2 on a real warehouse has returned 200. If the secret contains `&`, `+` or `%`, URL-encode it
first. Tokens are short-lived; never save them, paste them, or print `env`. *Not yet run on any
environment — confirm on DEV and record in §9.*

---

## 2. Create the tenant (only for a brand-new client)

Skip to §3 if the client already exists in the OMS and you are only adding a warehouse.

### 2.1 Create it

SiteBoss Admin ▸ **Tenants ▸ New Tenant Wizard** → `POST /api/admin/tenants`
(`AdminTenantController::store` → `TenantProvisioningService::provisionTenant`). There is no artisan
equivalent.

Inputs: `tenant_slug` (becomes the tenant name, the realm name and `om1_<slug>` — must satisfy the WMS
limits in §0, so check the length now), `admin_email`, `admin_first_name`, `admin_last_name`;
optional `admin_username` (default `admin` — **keep the default**: the warehouse setup admits the
realm user named `admin`), `template_realm` (default `spk`).

What it does, rolled back on any failure:
1. Keycloak realm `<slug>` from template realm `spk` (clients `om1`/`om1-web`, roles, groups;
   redirect URIs rewritten to `https://<slug>.<TENANT_BASE_DOMAIN>/*`).
2. MySQL `om1_<slug>` and `om1_<slug>_reporting`; baseline + incremental tenant migrations.
3. Users `admin` (rep_type 1) and `sbadmin` (rep_type 0), in the OMS DB **and** in Keycloak.
4. `tenant_auth_providers` row, tenant domain, branding/email config, tenant API key.
5. WMS service identity (non-fatal): enables service accounts, creates the `wms_user` client role,
   and — if the landlord client is public — a confidential client **`oms-s2s`**. Repaired on every
   OMS deploy by `wms:provision-tenant-service-auth --all --configure-facilities`.

### 2.2 Do before §3

- [ ] **Reset the `admin` and `sbadmin` passwords — before §3, not after.** Both start with
      predictable values, and `admin` becomes the **first WMS super-admin** of every warehouse of this
      tenant. Set new random passwords from the team password manager in **both** stores: Keycloak
      (realm `<slug>` ▸ Users ▸ `<user>` ▸ Credentials, *Temporary* off) **and** the OMS user record
      (exact OMS path: *owner to fill on first run*). Resetting only one leaves the other working.
      Record who/when in §9. Do not continue to §3 until both are done.
- [ ] **Migrate the reporting DB** — tenant creation leaves it empty:
      `php artisan tenants:migrate-reporting --tenant=<slug>`.
- [ ] No Mongo step: tenant documents are created lazily; indexes come from `mongodb:create-indexes`
      on deploy.
- [ ] **`service-account-oms-s2s` is enabled** in realm `<slug>` (Keycloak ▸ Users). On UAT
      2026-10-27 something outside the OMS disabled all of them and every OMS→WMS `/v3` call 401'd.

WMS host derivation when `wms.provisioning.*` are left blank (recommended):

| `TENANT_BASE_DOMAIN` | WMS API (`api_url`) | UI domain (`ui_domain`) | Warehouse sign-in |
|---|---|---|---|
| `oms.dev.sbo.li` | `https://wms-api.dev.sbo.li/v3` | `wms.dev.sbo.li` | `https://<wh>-<t>.wms.dev.sbo.li` |
| `oms.uat.sbo.li` | `https://wms-api.uat.sbo.li/v3` | `wms.uat.sbo.li` | `https://<wh>-<t>.wms.uat.sbo.li` |
| `oms.sbo.li` | `https://wms-api.sbo.li/v3` | `wms.sbo.li` | `https://<wh>-<t>.wms.sbo.li` |

`wms.provisioning.oms_callback_url` blank = the OMS `APP_URL`. A key that is **set but not a usable
URL/host is treated as missing** — it does not fall back to the derived value.

---

## 3. Add a warehouse

Repeat per warehouse. One tenant can have several (ShipItEZ has `nywh` and `c1wh`).

### 3.1 Create the OMS facility

OMS ▸ Settings ▸ **Facilities**. Set:
- **Facility code** — becomes `<wh>` after lower-casing. `NY-1` is rejected (422); `NYWH` → `nywh` is fine.
- **Timezone** — a valid IANA zone (`America/Los_Angeles`). It becomes the warehouse's
  `System Time Zone` and is **hard to change later** (§4). The OMS falls back to `America/New_York`
  if none is passed — **set it explicitly**.

### 3.2 Run "Set up WMS warehouse"

> [!danger] Confirm the tenant and warehouse before you click or run.
> Several tenants share warehouse codes today (`nywh` = hydra **and** shipitez). The UI action runs in
> the tenant context of your staff session; the CLI uses `--tenant=`. Read the target back first: you
> must be in tenant `<t>`, facility `<WH>`, and the result must name DB `wms2_<t>_<wh>`.
> **Never re-run Set up WMS warehouse on a live PRD warehouse to "check" it** — it applies any pending
> Flyway migrations to that production DB, outside the PRD gate of `wms2-apply-pending-tenant-flyway`.
> To check a warehouse, use the read-only V2.

Staff only (SiteBoss admin). Either:
- **UI**: Facilities list ▸ row action **Set up WMS warehouse** (`POST /api/wms-urls/provision-warehouse` with `{facility_code}`).
- **CLI**: `php artisan tenants:artisan "wms:provision-warehouse <FACILITY> --name=<name> --timezone=<IANA zone>" --tenant=<t>`
  — the inner options go **inside** the quotes; outside them the `tenants:artisan` wrapper rejects them.
  Both are optional (defaults: the facility's name and timezone).

It is **idempotent** for a warehouse being set up: re-running only migrates the DB and fills gaps;
stock, orders and settings are kept. It can take a minute (600 s timeout). Only **one** provisioning or
demo reset runs at a time per environment — a concurrent call gets
409 "Another warehouse provisioning or demo reset is running".

**What happens, in order** (OMS `WmsWarehouseProvisioningService::setUp` = `provision()` then `link()`):

**A. WMS side** — `PUT https://<api-host>/landlord/tenants/<t>/warehouses/<wh>` with the OMS's
master-realm admin token (`TenantWarehouseProvisioningService.provision`, `:146-196`):
1. Guards (all 409): routing-key collision (§0); discovery key owned by another realm (`:305-313`);
   tenant's auth row points at a different Keycloak server/realm (`:293-303`); warehouse row exists but
   `active=false` (`:162-165`, "reactivate it there first"); demo requested on a non-demo tenant.
2. New warehouse only (`TenantDatabaseCreator.ensure`, `:59-107`): role `wms2_<t>_<wh>_app` (random
   32-character password, set SCRAM-hashed, never in SQL text) and database `wms2_<t>_<wh>` owned by
   it, `TEMPLATE template0`, UTF8. The landlord role is also granted membership of the new role
   (`GRANT <role> TO CURRENT_USER`) and keeps it. **Always on the same Postgres cluster as the landlord
   DB** — there is no option for another server.
3. Flyway from `classpath:db/migration`, the same settings as boot. On PostgreSQL 14 (role does not own
   `public`) it applies `V2.2.00__base_v2_schema.sql` minus its `COMMENT ON SCHEMA public` statement,
   **baselines at 2.2.00**, then migrates (`:499-559`). Either way the DB **always gets
   `flyway_schema_history`**, so `StartupFlywayMigrator` keeps it current on every boot. No
   `CREATE EXTENSION` is needed — the base schema uses none.
4. Per-warehouse sysprops in `los_sysprop` (`:322-356`), **only where `sysvalue` still holds the
   `CHANGE-ME-FOR-NEW-CLIENT` placeholder**: `MULTIWAREHOUSE_IDENTIFIER`, `WAREHOUSE_NAME`,
   `OMS_TENANT_ID`, `System Time Zone`, `SYSTEM_OMS_NAME`, `SYSTEM_WMS_NAME`, `MOBILE_UI_URL`, and every
   `WEBSERVICE_*` callback base URL. A value already configured is never overwritten.
5. **One landlord transaction** (`:188-189`, `:218-268`), written last so no active route ever points
   at a half-built DB:

   | Table | Cardinality | Written |
   |---|---|---|
   | `tenant` | 1 per tenant | only if the name is new |
   | `tenant_auth_configuration` | 1 per tenant | only if absent; later only fills a missing user-management login |
   | `tenant_db_configuration` | 1 per warehouse | only if absent; **`active=true`** |
   | `tenant_discovery` | 1 per warehouse | update-by-key else insert, on every call; **`active=true`** |

   Both `active` flags land in the same transaction, which closes the split-brain risk raised by the
   readiness audit. (Four tables, not the "ten rows" the 2026-09-01 audit counted — that audit predates
   this tooling.)
6. Registry refresh **on the replica that served the call only** (`tenantConfigLoader.refreshNow()`).
   Other replicas pick it up on their periodic refresh (`wms.tenant.config.refresh-interval-ms`,
   300 000 ms fixed delay after the previous run finishes) — **allow at least 5 minutes, plus run time**,
   before testing through the load balancer.

**B. OMS side** — `link()`:
1. `wms_url_lut` row in the tenant's OMS DB: `facility_code`, `wms_url` (API with `/v3`, overwritten on
   every run), `site_url` (`https://<wh>-<t>.<ui-domain>`, set only when blank). **This is the only step
   that must succeed**; the rest report problems as messages.
2. Keycloak sign-in: adds `https://<wh>-<t>.<ui-domain>/*` to the sign-in client's redirect URIs, web
   origins and post-logout URIs.
3. Keycloak WMS access (`WmsKeycloakAccess::ensureWarehouse`, each piece added only if missing):
   `groups` and `warehouse` claim mappers on the sign-in client; group `/wms_user` carrying the
   `wms_user` client role; group `/warehouse/<wh>` with attribute `warehouse=<WH>`; on first creation
   the realm user **`admin`** joins both.
4. If the WMS reported `userAdmin=false`: creates/repairs the confidential client and user
   **`wms-user-admin`** (`view-users`, `manage-users`, `query-groups`), proves a sign-in, and re-sends the
   PUT with those credentials. The OMS does not keep them.
5. OMS → WMS service auth for the facility: writes the `wms_url_lut.config` auth block (`oms-s2s` or the
   tenant's own identity).

### 3.3 Read the result

The dialog shows **created** vs **brought up to date**, the database name, schema version and
migrations applied, and the warehouse + mobile sign-in links. Anything under the yellow
**"Still to do by hand"** heading is a step that failed and was not retried — do it, then re-run Set up
WMS warehouse (safe for a warehouse being set up). Treat error bodies as possibly containing
credentials until you have read them.

**The OMS reports every WMS refusal other than 409 as `502`** — match on the message, not the code:

| Code | Message (starts with) | Cause | Fix |
|---|---|---|---|
| 503 | "Set wms.provisioning.ui_domain in Admin ▸ Configs…" (or api_url, callback) | P7 | set the key at system level, or fix `TENANT_BASE_DOMAIN` |
| 503 | no master admin token | P5 credentials missing in OMS env | set `KEYCLOAK_ADMIN_*` |
| 422 | facility code | §3.1 regex | change the facility code |
| 422 | auth provider | the tenant's default auth provider is not Keycloak with realm + server URL | fix the tenant's `tenant_auth_providers` row |
| 500 | "Link a warehouse from inside its tenant." | the CLI was run without `--tenant=`, or the UI outside a tenant context | re-run inside the tenant (§3.2) |
| 502 | "The WMS at … could not be reached." | nothing reached the WMS — wrong API URL, DNS, network | check the OMS log, P7, `curl https://<api-host>/api/public/version`. **Not** a wms2-api log problem |
| 502 | "The WMS did not accept the OMS Keycloak token…" | WMS replied 401 — P6 | align `wms.landlord-admin.issuer-uri` with the OMS `KEYCLOAK_SERVER_URL` master realm |
| 502 | "…needs the create-realm role" | WMS replied 403 — P5 | grant `create-realm` in the master realm |
| 502 | "The WMS refused: … ALTER ROLE … CREATEDB CREATEROLE" | WMS replied 500 — P2 | run the grant |
| 502 | "The WMS refused: … db/backfill-flyway-history.sh" | WMS replied 500 — a DB with tables but no Flyway history (hand-made) | §5; do **not** drop the DB without the WMS backend owner |
| 502 | "The WMS refused: …" (400) | §0 input limits | shorten / rename **before** anything was created |
| 409 | routing key / discovery key / realm mismatch / inactive / lock | §3.2 A.1 | rename, reactivate per §7, or wait for the lock |
| 502 | anything else | WMS error | read wms2-api logs on the replica that served the call |

**Keycloak status `skipped`**: the tenant's realm lives on a **different Keycloak server** than the
OMS's `KEYCLOAK_SERVER_URL`. Step B.3 did nothing; B.2 still ran against the OMS's own Keycloak (it
reports a failure, or — if a realm of the same name exists there — touches that one, so check), and B.5
ran too. Do B.2–B.4 by hand on the right server (wms2-api `scripts/provision-oms-service-account.sh`
covers the service identity).

### 3.4 Partial states and what to do

| State | Symptom | Do |
|---|---|---|
| WMS PUT failed before the landlord transaction | error before "created"; no landlord rows | fix the cause, re-run §3.2. The leftover role + DB are adopted; adoption resets that role's password — **only** because no landlord row exists yet. A re-run never rotates a live warehouse's password |
| WMS done, `wms_url_lut` not written | WMS warehouse exists, OMS facility has no WMS link | re-run §3.2 (it is still being set up, not yet serving traffic). Do **not** deactivate |
| Keycloak step failed | "Still to do by hand" messages; sign-in fails | do the listed step by hand, re-run §3.2 |
| Wrong tenant or warehouse name provisioned | rows exist for a name nobody asked for | §7 deactivate and **leave it** (DB, role and inactive rows stay; record in §9). Orphan cleanup does not apply — landlord rows exist. Names cannot be renamed |

---

## 4. Manual follow-ups after every new warehouse

The tooling leaves these alone deliberately.

- [ ] **Pool size.** New rows get `max_pool_size=2`, `min_idle=0` (column defaults). That is small for a
      live warehouse (DEV WineCo `wsl` runs 10/1). Size from facts — on the WMS cluster:
      ```sql
      SHOW max_connections;
      -- landlord DB:
      SELECT t.name, c.warehouse, c.max_pool_size, c.min_idle
        FROM tenant_db_configuration c JOIN tenant t ON t.id = c.tenant_id
       WHERE c.active ORDER BY 1, 2;
      ```
      Required: `(sum of active max_pool_size after the change + landlord pool) × replicas + every other
      client of the cluster (v1 DBs, Keycloak) ≤ max_connections − 10 %`. Replicas: plan is 1 → 2 → max 3
      (SBDEV-3193 Q2); confirm the live count (Q-INFRA-6). **If you cannot confirm it, do not go above the
      sibling warehouse's value** and ask infra. Then, with the WMS backend owner:
      ```sql
      BEGIN;
      DO $$
      DECLARE n int;
      BEGIN
        UPDATE tenant_db_configuration SET max_pool_size = <pool_max>, min_idle = <pool_min_idle>
         WHERE tenant_id = (SELECT id FROM tenant WHERE name = '<t>') AND warehouse = '<wh>';
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n <> 1 THEN RAISE EXCEPTION 'expected 1 row, got % - aborting', n; END IF;
      END $$;
      COMMIT;   -- if the block raised, psql answers this COMMIT with "ROLLBACK" and nothing changed.
                -- Check the tag says COMMIT, then re-run the SELECT above.
      ```
      The periodic refresh notices the changed size and **evicts and rebuilds the live pool** on each
      replica (≤ 5 min + run time) — make the change while the warehouse is idle. To apply it at once on
      one replica: `POST /actuator/tenantpool` with body `{"tenant":"<t>","facility":"<wh>"}` and a
      `wms_admin` token — **per replica only**; call each replica directly, or wait out the refresh.
- [ ] **Timezone and URLs are fixed at the first call.** Later calls only fill placeholders. To change a
      warehouse's zone afterwards, update **both** `los_sysprop` (`syskey = 'System Time Zone'`,
      warehouse DB) and `tenant_discovery.timezone` (landlord) so they agree, **then evict the pool on
      every replica** (`POST /actuator/tenantpool` as above, or a restart): the session zone is set once
      at pool creation, and the refresh does not compare it.
- [ ] **Users.** The new warehouse DB knows only the seeded super-admin `admin`. Sign in as `admin`, then
      add real users and grant functions in WMS ▸ User Management. Keycloak is coarse (everyone gets
      `wms_user`); function-level permission lives in the warehouse DB (`wms2-keycloak-role-matrix`).
      The `warehouse` user attribute is editable by realm admins only.
- [ ] **Cron is on from the start.** The base schema seeds `NEW_CRON_JOB_ACTIVATED=true` and
      `ORDER_TIMER_ACTIVATED=true`, so the cron instance runs scheduled jobs for the warehouse after its
      next refresh. That is intended; expect job log lines for an empty warehouse.
- [ ] **Warehouse content.** Zones, locations, clients and items are not created here. Use the OMS
      Facilities **Sync to WMS** action and `wms:backfill-facility-items --all`. Existing v1 clients
      migrating data follow §5 instead.

---

## 5. Existing clients moving from v1 (not greenfield)

This runbook is for **new** databases. A client whose data already lives in WMS v1 follows
`wms2-database-setup-guide` **Path B** and its per-client migration runbooks; those databases were made
by hand under older names (`wh01_om1_v2`, `wh01_hydra_v2`, `wh01_shipitez_v2`, `wh02_shipitez_v2`). If
such a DB has tables but no `flyway_schema_history`, `StartupFlywayMigrator` skips it **on every boot,
forever** (logged at ERROR, gauged, boot stays green) — repair with `db/backfill-flyway-history.sh`
before relying on it. Set up WMS warehouse can run for such a facility afterwards: it adopts the
existing landlord row and only fills gaps (but see the §3.2 warning on PRD).

---

## 6. Post-onboarding verification checklist

Run in order. V1–V7 straight after §3.2; **wait the refresh interval before V8**. Record the first run in §9.

| # | Check | Command / where | Pass |
|---|---|---|---|
| V1 | Build carries the tooling | `curl -s https://<api-host>/api/public/version` | ≥ v0.0.43 (on DEV, a `develop-<sha>` at/after `f141ccb7`) |
| V2 | WMS registration status (read-only) | P12 token, then `curl -s -H "Authorization: Bearer $TOKEN" https://<api-host>/landlord/tenants/<t>/warehouses/<wh>` | 200; `database` = `wms2_<t>_<wh>`, `schemaVersion` current, `userAdmin: true` |
| V3 | Both `active` flags, exactly one row | landlord: `SELECT d.active AS discovery_active, c.active AS db_active FROM tenant_discovery d JOIN tenant t ON t.name = '<t>' JOIN tenant_db_configuration c ON c.tenant_id = t.id AND c.warehouse = '<wh>' WHERE d.key = '<wh>-<t>';` | exactly **one** row, `t`, `t`. Two rows = duplicate discovery key (no unique constraint) — stop, escalate |
| V4 | UI discovery | `curl -s 'https://<api-host>/api/public/authConfig?key=<wh>-<t>'` | 200 with expected `realm`, `clientId`, `webRedirectUrl`, `mobileRedirectUrl`, `timezone`. 404 = row missing **or inactive** |
| V5 | Schema current | `PGPASSWORD_LANDLORD=<from password manager, not echoed> sbdocs/9-System/scripts/apply-pending-tenant-flyway.sh --env <env> --repo <wms2-api checkout at the tag /api/public/version reports> --status` (needs `psql`, `flyway` and the DB tunnels — see `wms2-apply-pending-tenant-flyway`) | the new `<t>/<wh>` row is listed current. Pending/baseline on **other** tenants is not this runbook's failure — report it to the release owner. **Never add `--apply` here** |
| V6 | No placeholders left | warehouse DB `wms2_<t>_<wh>` (connect as the DBA/superuser infra provides — not by reading the password out of the landlord): `SELECT syskey FROM los_sysprop WHERE sysvalue LIKE '%CHANGE-ME-FOR-NEW-CLIENT%' ORDER BY syskey;` | 0 rows |
| V7 | Host resolves with a valid cert | `curl -sI https://<wh>-<t>.<ui-domain>/` and `…/mobile/` | 200; certificate valid for the host |
| — | **Wait** | ≥ 5 min + refresh run time after §3.2, so every replica has loaded the tenant | |
| V8 | Web sign-in through the load balancer | browser: `https://<wh>-<t>.<ui-domain>` as `admin` — repeat 3–4 times (new sessions) | lands in the WMS each time; facility shown = `<WH>` |
| V9 | Mobile sign-in | `https://<wh>-<t>.<ui-domain>/mobile` on a handheld | as V8 |
| V10 | No replica left behind | during V8, watch for `401 invalid_token "no matching key(s) found"` | none. That error means a replica has not loaded the tenant **or** the tenant header is missing — not a Keycloak misconfiguration. If seen: wait one more interval; then `POST /actuator/tenantpool` (body `{"tenant":"<t>","facility":"<wh>"}`) against each replica directly; then read that replica's wms2-api log for a registry-refresh error; then escalate to the WMS backend owner |
| V11 | OMS → WMS authenticated path | OMS: a `/v3` call for the facility (e.g. Facilities ▸ Sync to WMS) | succeeds; a 401 → `service-account-oms-s2s` disabled (§2.2) |
| V12 | OMS → WMS `/rest` path | OMS: an advice create or stock export for the facility | succeeds; failure → P10 |
| V13 | Per-tenant pool metric | `/actuator/prometheus` (`wms_admin`), **after** V8 has sent traffic through that replica | `hikaricp_connections{pool="HikariPool-<routing key>"}` present. Nothing scrapes this yet (SBDEV-3193) |
| V14 | Initial passwords gone | Keycloak admin tries the initial `admin`/`sbadmin` values in Keycloak **and** the OMS UI | both refused |

---

## 7. Deactivate, reactivate, remove

**There is no endpoint for any of these.** Manual SQL on the landlord DB, by the WMS backend owner.

**Deactivate a warehouse** — set **both** flags in one transaction (one left true is split-brain):

```sql
BEGIN;
DO $$
DECLARE n1 int; n2 int;
BEGIN
  UPDATE tenant_discovery SET active = false WHERE key = '<wh>-<t>';
  GET DIAGNOSTICS n1 = ROW_COUNT;
  UPDATE tenant_db_configuration SET active = false
   WHERE tenant_id = (SELECT id FROM tenant WHERE name = '<t>') AND warehouse = '<wh>';
  GET DIAGNOSTICS n2 = ROW_COUNT;
  IF n1 <> 1 OR n2 <> 1 THEN
    RAISE EXCEPTION 'expected 1 + 1 rows, got % and % - aborting', n1, n2;
  END IF;
END $$;
COMMIT;   -- if the block raised, psql answers this COMMIT with "ROLLBACK" and nothing changed.
          -- Check the tag says COMMIT, then verify with V3/V4.
```

It takes effect per replica on that replica's next refresh (≤ 5 min + run time), which closes the pool.
**`POST /actuator/tenantpool` does not help here** — it refuses inactive tenants and changes nothing.
Verify: V4 returns 404, and no `HikariPool-<routing key>` remains in `/actuator/prometheus` on each
replica.

**Reactivate**: the same block with `true`. Set up WMS warehouse refuses (409) while
`tenant_db_configuration.active=false`; after reactivating it is safe to re-run.

**Orphan cleanup** — **only** for a role + DB left by a failed first call, i.e. when **no landlord row
exists** for the warehouse. Owner to verify each step on DEV before relying on it:

```sql
-- 1. landlord DB — BOTH must return 0, else STOP (a landlord row still points at it).
--    db_url keeps the landlord URL's ?parameters after the DB name, so the pattern is NOT end-anchored;
--    '_' is a LIKE wildcard, which can only over-match — the safe direction for a STOP gate.
SELECT count(*) FROM tenant_db_configuration WHERE db_url LIKE '%/wms2_<t>_<wh>%';
SELECT count(*) FROM tenant_db_configuration c JOIN tenant t ON t.id = c.tenant_id
 WHERE t.name = '<t>' AND lower(c.warehouse) = '<wh>';
-- 2. WMS cluster — must return exactly one row, rolname = 'wms2_<t>_<wh>_app':
SELECT d.datname, r.rolname FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
 WHERE d.datname = 'wms2_<t>_<wh>';
-- 3. only then, as superuser (DROP DATABASE fails while any session is connected — that is a STOP too):
DROP DATABASE "wms2_<t>_<wh>";
DROP ROLE "wms2_<t>_<wh>_app";
```

**A typo'd name that was registered** (landlord rows exist) is **not** an orphan: step 1 will refuse it.
Deactivate it (above) and leave the DB, role and inactive rows in place — deleting landlord rows is not
supported. Record it in §9 so nobody reuses or reactivates it by mistake.

**Never call `POST /landlord/tenants/{t}/warehouses/{w}/demo-reset`** on a real tenant. It wipes and
reloads the warehouse DB; it refuses tenants without `tenant.is_demo`, but that guard is not the place to
find out.

---

## 8. Reference

### 8.1 What the tooling creates (names)

| Object | Name |
|---|---|
| Keycloak realm | `<t>` (OMS, from template `spk`) |
| Sign-in clients | `om1` / `om1-web` (from template) |
| OMS MySQL | `om1_<t>`, `om1_<t>_reporting` |
| WMS Postgres DB | `wms2_<t>_<wh>` (≤ 59 characters) |
| WMS Postgres role | `wms2_<t>_<wh>_app` (owns the DB and every object; ≤ 63 bytes) |
| Keycloak groups | `/wms_user`, `/warehouse/<wh>` |
| Keycloak clients/users | `wms-user-admin` (user management), `oms-s2s` (OMS→WMS) |
| Landlord rows | §3.2 A.5 |
| OMS row | `wms_url_lut` (tenant DB) |

### 8.2 Configuration names (values are never written here)

- **wms2-api**: `rest.security.enabled`, `rest.security.issuer-uri`, `wms.landlord-admin.issuer-uri`,
  `landlord.datasource.jdbc-url` / `.username` / `.password` (no default; required),
  `app.flyway.migrate-on-startup`, `app.flyway.out-of-order`, `wms.tenant.config.refresh-interval-ms`
  (`0` disables), `app.cron` (true on the cron instance only), `spring.data.redis.*`,
  `rest.security.cors.allowed-origin-patterns` (default covers `https://*.sbo.li`, so a new tenant host
  needs **no CORS change**).
- **OMS env**: `TENANT_BASE_DOMAIN`, `KEYCLOAK_SERVER_URL`, `KEYCLOAK_ADMIN_USERNAME`/`_PASSWORD` or
  `KEYCLOAK_ADMIN_CLIENT_ID`/`_SECRET`, `KEYCLOAK_ADMIN_REALM`, `KEYCLOAK_SERVICE_*` (fallback service
  account), `DB_*`, `WMS_FACILITY_<CODE>_URL` (fallback when no `wms_url_lut` row).
- **OMS Admin ▸ Configs** (system level): `wms.provisioning.api_url`, `wms.provisioning.ui_domain`,
  `wms.provisioning.oms_callback_url`.
- **UIs** (`publicRuntimeConfig`): `API_BASE_URL`, `APP_GROUP`, `APP_ADMIN_GROUP`, `OO_*` (RUM);
  `KEYCLOAK_*` apply to `localhost` only.
- **Secrets at rest**: see the secrets rule at the top. The landlord DDL comments that say `ENC(...)` are
  stale — v2 has no Jasypt. Access to the landlord DB is access to every tenant's credentials.

### 8.3 Not applicable to WMS v2

S3 and SMTP: wms2-api has no S3 or mail configuration, so those rows of the old playbook do not apply.
Per-tenant env files, images, Portainer stacks and Traefik labels: obsolete (§0). Secret **values** are
deliberately not recorded in this vault (1535 point 4 asked for them; that part is declined as policy).

### 8.4 Security notes for the P2 grant

`CREATEROLE` on PostgreSQL < 16 lets the role change the password of **any non-superuser role** on the
cluster — every other tenant's app role, and v1 database owners where the cluster is shared (PRD
co-hosts live v1 databases). Before granting: check `SHOW server_version;`, get the WMS backend owner's
and infra's explicit acceptance and record it in §9, and confirm the PRD landlord password is no longer
the pre-SBDEV-3175 committed literal (SBDEV-3193 security item). If onboarding is rare, revoke between
windows with `ALTER ROLE <role> NOCREATEDB NOCREATEROLE;`.

**PRD state, measured 2026-11-09:** PostgreSQL **14.23**, and `wms2_landlord_app` **already has**
`rolcreatedb = t, rolcreaterole = t`. The exposure above is therefore live on PRD today, and the
landlord password's rotation since the SBDEV-3175 literal is unconfirmed. Rotation is item 1 of
SBDEV-3193.

---

## 9. SBDEV-1535 requirement reconciliation, and what is still open

SBDEV-1535 was closed on 2026-11-05 as "Included in SBDEV-3193; remaining documentation scope continues
there". Its open points (2, 4-values, 5, 7) are carried by **SBDEV-3193** — recorded there in the
2026-11-09 runbook comment, which also supersedes that ticket's stale "ten landlord rows, no tool
creates any" bullet.

State vocabulary: `OPEN` · `DONE-FROM-CODE (not run)` · `VERIFIED (date, env)`.

| # | 1535 requirement | Where it lives now | State |
|---|---|---|---|
| 1 | Replace placeholders `TENANT`, `BASE_DOMAIN`, `API_IMAGE` | §0, §2.2, §8.1. **Re-scoped**: `TENANT`/`BASE_DOMAIN` are request inputs, not per-instance values; `API_IMAGE` is one image per environment (from CI config — *unverified against the live stacks*, Q-INFRA-1) | DONE-FROM-CODE (not run) |
| 2 | Traefik hostnames, routes, labels, networks, cert resolver | P9 | OPEN — no WMS Traefik or stack file exists in any repo. Only the OMS compose shows the pattern (`le_dns` resolver, wildcard `HostRegexp`, external `traefik` network). Needs Q-INFRA-1/2 |
| 3 | Keycloak realms, client IDs, redirect URIs, roles | §2.1, §3.2 B, §8.1 | DONE-FROM-CODE (not run); manual remainder in §2.2, §3.3 `skipped` |
| 4 | Env config: endpoints, DB, Redis, S3, SMTP | §8.2, §8.3 | names DONE-FROM-CODE; values OPEN by policy (secret store is infra's, Q-INFRA-5); S3/SMTP not applicable |
| 5 | Portainer stack files match the deployment | — | OPEN, blocked — stacks exist only in Portainer. CI config suggests DEV/UAT redeploy by webhook (api + cron) and PRD by hand (*unverified*). Needs Q-INFRA-1 |
| 6 | PostgreSQL DB names, users, roles, extensions | §3.2 A.2–A.3, P2, P3, §8.1, §8.4 | DONE-FROM-CODE (not run); P2/P3 per env OPEN (Q-INFRA-3) |
| 7 | Validate the post-deploy checklist against a working DEV tenant | §6 | OPEN — not yet run. DEV `meridiandemo` (`mdlw`, `mdle`) shows the tooling ran there (rows present, `wms-user-admin` login stored): supporting evidence, not a run of §6 |

### Open questions for infra (Joe)

- **Q-INFRA-1** Export the Portainer stacks (wms2-api api + cron, wms2-web-ui, wms2-mobile-ui) per
  environment into git or this doc: services, replicas, networks, labels, env var names, resolver.
- **Q-INFRA-2** Is `*.wms.<domain>` a wildcard router **and** wildcard certificate on DEV, UAT and PRD? Is
  anything needed per new host?
- **Q-INFRA-3** Has `ALTER ROLE <role> CREATEDB CREATEROLE` been run on the UAT cluster, and which
  Postgres major version is it? (§8.4) *PRD answered 2026-11-09: granted, PG 14.23.*
- **Q-INFRA-4** Who holds the master-realm `create-realm` identity the OMS uses, per environment, and can
  staff get read-only use of it for P12?
- **Q-INFRA-5** Which service sets `APP_CRON=true`; is `wms.landlord-admin.issuer-uri` set per env; where
  do secrets live (Portainer env, files)?
- **Q-INFRA-6** How many wms2-api replicas (api + cron) run in each environment today?

### Verification log

| Date | Env | Tenant / warehouse | Rows run (P/V) | Result | By |
|---|---|---|---|---|---|
| 2026-11-10 | DEV | `meridiandemo` / `mdlw`, `mdle` (already provisioned by the tooling; **read-only, no §3.2 run**) | V1, V3 (`mdlw`), V4, V7 | **PASS.** V1 `develop-36deaa25` contains `f141ccb7`. V3: exactly one row, `t`/`t`. V4: both keys 200 with realm `meridiandemo`, client `om1`, the right redirects, LA/NY zones. V7: web + `/mobile/` 200, certificate valid on all 4 hosts. Also confirmed: pool defaults 2/0; DEV `db_url` has no `?params`; the §7 orphan gate's step 1 returns non-zero (STOP) for these live warehouses, as it must. **Not run:** V2 (needs a P12 token), V5 (needs tunnels), V6 (needs DBA access to the warehouse DB), V8–V14 (browser/handheld/OMS). Does **not** lift the PRD gate — §2/§3.2 have not been run | Claude for Nam |

---

## 10. Related docs

- `3-Resources/architecture/wms2-tenant-routing-datasource-topology.md` — routing key (§3.1), activation landmines (§10.13)
- `3-Resources/data-dictionary/wms2-landlord-vs-tenant-entity-map.md` — the four landlord entities
- `3-Resources/architecture/wms2-keycloak-role-matrix.md` — roles, groups, function gating
- `2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md` — migrating **existing** tenants between deploys; script prerequisites for V5
- `3-Resources/architecture/wms2-database-setup-guide.md` — Path A (fresh; superseded by this runbook) and Path B (v1→v2)
- `3-Resources/architecture/wms2-greenfield-db-provisioning.md` — base-dump background; §1 scenarios and §5 settings still valid
- `3-Resources/reports/260901-wms2-multitenancy-readiness-audit.md` — the audit that raised H9/B4/B5
- Code-level source of truth (`origin/main`): wms2-api `CLAUDE.md` (DB provisioning section),
  `landlord/controller/TenantProvisioningController.java`, `landlord/service/TenantWarehouseProvisioningService.java`,
  `landlord/service/TenantDatabaseCreator.java`, `landlord/config/LandlordAdminSecurityConfiguration.java`;
  OMS `app/Services/WmsWarehouseProvisioningService.php`, `WmsKeycloakAccess.php`,
  `WmsServiceAuthProvisioner.php`, `docs/demo/meridian-admin-seeding.md`, `docs/releases/owl-v2.0.161/developer.md`
