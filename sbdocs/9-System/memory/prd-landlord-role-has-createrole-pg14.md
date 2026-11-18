---
name: prd-landlord-role-has-createrole-pg14
description: "PRD wms2_landlord_app has CREATEDB+CREATEROLE on PG 14.23 (can reset any non-superuser role's password); landlord pw rotation since the 3175 literal unconfirmed; zbx_monitor (Zabbix) sits on every PRD tenant DB"
metadata:
  type: project
---

Measured 2026-11-09 on the shared PRD cluster (via nywh-hydra-prd MCP, `pg_roles`):
- `wms2_landlord_app`: `rolcreatedb=t, rolcreaterole=t` (granted for SBDEV-3868 provisioning). PG **14.23**, so CREATEROLE = can change any non-superuser role's password (all tenant `*_v2_app` roles, v1 owners).
- Its password was a committed literal until SBDEV-3175 (fix IS in PRD build 0.0.44); rotation never confirmed.
- Cluster: max_connections 300, ~72 in use; landlord 21 sessions, each tenant 7–8 vs max_pool_size 5 ⇒ 2 JVMs (api + cron).
- `zbx_monitor` (Zabbix) holds a session on every PRD tenant DB — an existing monitoring path for SBDEV-3193 alerting.

**Why:** makes landlord credential rotation the top live-tenant risk on SBDEV-3193 (rescoped 2026-11-09 to "Live multi-tenant PRD: operability and security").
**How to apply:** don't re-derive; re-check `pg_roles` before claiming the grant was revoked or kept. Related: [[hub-secrets-exposures]], [[hub-envs-deploys]].
