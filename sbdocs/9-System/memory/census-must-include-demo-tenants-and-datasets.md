---
name: census-must-include-demo-tenants-and-datasets
description: "A pre-migration data census (unique index, constraint) must cover demo tenants (landlord tenant.is_demo) and the shipped demo-datasets fixtures, not just PRD/UAT/dev client DBs"
metadata:
  node_type: memory
  type: feedback
  originSessionId: accbb0fa-a9ea-4061-b4d7-305226e8dc0b
  modified: 2026-11-11T14:35:48.646Z
---

On SBDEV-4107 (2026-11-11) the duplicate census for a new partial unique index covered the 4 PRD tenants, the 4 UAT tenants and dev, and every one returned 0. The full IT lane still failed. `TenantWarehouseProvisioningIntegrationTest` demo-reset loads `src/main/resources/demo-datasets/meridian/fixtures.sql`, and that fixture seeds three open batches on staging lane 23. The fixture is also deployed as tenant `meridiandemo` (warehouses `mdle` and `mdlw`) on **UAT and dev**. Those databases are not in the client MCP list and were never queried.

**Why:** demo tenants (SBDEV-3868 provisioning and demo-reset) are a separate tenant population, built from a fixture file rather than real operations. A new constraint can be violated by the fixture itself. In that case the migration's guard stalls the demo tenant at the previous version, and every demo-reset fails.

**How to apply:** before adding a unique index, NOT NULL or CHECK constraint in a tenant migration:
1. Find demo tenants: `select t.name, regexp_replace(d.db_url,'^.*/','') from tenant t join tenant_db_configuration d on d.tenant_id=t.id where t.is_demo` on landlord-prd, landlord-uat and landlord-dev. Never select the password or secret columns.
2. Read `demo-datasets/*/fixtures.sql`, including every `${variant}` branch, for rows that would violate the constraint.
3. Run `TenantWarehouseProvisioningIntegrationTest` (demo-reset) as part of the targeted ITs, not only in the full lane.

Related: [[hub-flyway]] (other Flyway traps).
