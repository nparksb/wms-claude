---
name: hmg-is-hydra-nywh-warehouse
description: "HMG" in tickets is the former name of the Hydra nywh warehouse — resolve it to tenant hydra / facility nywh, not a separate client
metadata:
  type: project
---

**HMG is the former name of the Hydra `nywh` warehouse.** Tickets (SBDEV-2729, SBDEV-2643) say "Warehouse: HMG"; SBDEV-2731 says "NYWH" — these are the same place.

Resolve HMG → tenant `hydra`, facility `nywh`. On the dev landlord that is `jdbc:postgresql://dev.sbo.li:25060/wh01_hydra_v2`, reachable via the `wms2-hydra-dev2` MCP (`current_database()` = `wh01_hydra_v2`).

**Why:** searching the landlord tenant list for "HMG" returns nothing, so an HMG ticket looks unreproducible when the tenant is actually right there under a different name. Don't conclude "reporting environment unreachable" on an HMG ticket.

⚠ **`wms2-hydra-dev2` is an INACTIVE tenant** (confirmed 2026-08-19). It is not in the landlord's active list, so `StartupFlywayMigrator` never targets it — and it has **no `flyway_schema_history` table at all**, so its schema is frozen wherever provisioning left it. Do **not** report its missing migrations as a stalled Flyway chain or a tenant-ownership problem; that is the expected state for an inactive DB, not drift. It is a config-shape reference only, never evidence about what is deployed.

**How to apply:** when a ticket names HMG, query `wms2-hydra-dev2` for config-shape evidence (location types, constraints, sysprops). Three caveats:
- `wh01_hydra_v2` is a **v1→v2 migrated** DB, so its `location_type` ids are high (1, 50051–50057) — there is no id 2–7. A ticket error quoting a low canonical id (e.g. "location type ID 2") therefore came from a **freshly-provisioned** v2 DB seeded from `V2.2.00__base_v2_schema.sql` (canonical ids 0–7, where 2 = flowbin), i.e. UAT/prod — not this dev copy.
- The dev copy lags: it has no `ICE PACK` SKU or `Ice Pack` location, so ticket-specific rows may be absent even though the tenant is correct.

Careful not to confuse with `shipitez/nywh` → `wh01_hydra` (no `_v2`), a different DB sitting beside it on the same port. See [[wms2-tenant-object-ownership-blocks-flyway]] for the *active*-tenant failure mode this is NOT, plus [[shipitez-two-warehouse-v2-migration]] and [[wms2-seqentities-dual-island-id-space]].
