---
name: wms2-prd-public-schema-create-granted-to-public
description: "All 5 v2 PRD DBs (landlord + 4 tenants) keep PG14's `=UC` on schema public; app roles' CREATE (runtime Flyway) comes FROM it — can't simply revoke"
metadata:
  node_type: memory
  type: project
  originSessionId: 1622ae45-d0bb-48e8-bd54-3543480f2f93
  modified: 2026-10-07T00:39:15.607Z
---

Measured 2026-10-06 (SBDEV-3325) on PostgreSQL 14.23: schema `public` in `wms2_landlord`,
`wh01_hydra_v2`, `wh01_shipitez_v2`, `wh02_shipitez_v2`, `wh01_om1_v2` all carry `=UC` — PUBLIC may
CREATE. Any role that can connect can create objects, including the new read-only
`wms2_egress_watchdog`; Postgres cannot revoke a PUBLIC grant from one role, and
`default_transaction_read_only` is session-overridable, so it is not a boundary.

**The trap:** the tenant app roles hold only `U` explicitly (`wh01_shipitez_v2_app=U/postgres` etc.;
Hydra's schema is owned by `pg_database_owner`). Their CREATE — which `StartupFlywayMigrator` uses on
every boot — comes from the PUBLIC grant. `REVOKE CREATE ON SCHEMA public FROM PUBLIC` alone would
freeze runtime Flyway on those tenants (see [[sbdev-2801-runtime-flyway-default-on]],
[[wms2-tenant-object-ownership-blocks-flyway]]). Grant CREATE to each app role first, then revoke.

**How to apply:** filed as SBDEV-3673 (2026-10-06). Re-query `pg_namespace.nspacl` before
acting — do not assume it is still true.

**Re-measured 2026-10-07 (triage on SBDEV-3673; ON HOLD pending a DBA conversation):** wider than filed.
The 4 tenant DBs also grant CONNECT to PUBLIC (datacl NULL, hydra `=Tc`), so 25 login roles (other
tenants' app roles, v1 `wh0X_om1`/`wineco`, keycloak, zbx_monitor, personal accounts) can connect and
CREATE. Table reads across tenants are 0, because the app role owns all tables. The landlord is clean. Dev app
roles hold NO explicit USAGE either, so a fix must grant USAGE+CREATE. Hydra has an extra explicit
`wh01_om1_hmg=UC`. None of the MCP connections are superusers. The full measurement is in the ticket comment.
