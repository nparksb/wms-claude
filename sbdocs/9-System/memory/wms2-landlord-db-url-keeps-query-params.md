---
name: wms2-landlord-db-url-keeps-query-params
description: "tenant_db_configuration.db_url keeps the landlord URL's ?params after the DB name — never end-anchor a LIKE on it, esp. in a STOP gate before DROP"
metadata:
  type: project
---

`TenantWarehouseProvisioningService.siblingDatabaseUrl` (SBDEV-3868 / PR #557) builds a tenant `db_url` as landlord URL host + `/wms2_<t>_<wh>` + **the landlord URL's `?query` suffix** (e.g. `?sslmode=require`). So `db_url LIKE '%/wms2_<t>_<wh>'` matches nothing for a live warehouse when the env's `landlord.datasource.jdbc-url` carries parameters.

Caught 2026-11-09 by the round-2 review of the SBDEV-3193 onboarding runbook: the orphan-cleanup "must return 0, else STOP" gate failed **open** right before `DROP DATABASE`.

**Why:** a guard that returns 0 on a format mismatch reads as "safe to destroy".
**How to apply:** match DB identity by key (`tenant.name` + `lower(warehouse)`), and if matching `db_url` use an unanchored `'%/wms2_<t>_<wh>%'` (over-match is the safe direction for a STOP gate). Related: [[hub-code-traps]], [[hub-scan-instruments-lie]].
