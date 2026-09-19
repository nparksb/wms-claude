---
name: hibernate-validate-ignores-extra-columns-and-nullability
description: Hibernate 6.6 ddl-auto=validate checks only that a MAPPED column exists with a compatible type — extra DB columns and nullability mismatches pass; measured with a positive control on wms2-api
metadata:
  type: reference
---

Measured 2026-09-09 (SBDEV-3285) on `v2/wms2-api`, Hibernate **6.6.39.Final** / Spring Boot 3.5.9,
against a real Testcontainers `postgres:14-alpine` migrated from `db/migration`.

`spring.jpa.hibernate.ddl-auto=validate` asserts **only that each MAPPED column exists with a
compatible type**. It does **not** react to:

- **extra columns in the DB that no entity maps** — tested with `itemdata.archive`
  (`boolean NOT NULL DEFAULT false`) and `customerorder_batch.packingline` (nullable varchar);
- **a nullability mismatch** — tested by dropping `NOT NULL` from `billoflading.transfer_id`, which
  `db/migration` declares `NOT NULL`.

All three applied at once: lane **GREEN**. So a schema that is *looser* or *wider* than the mapping
passes validate; only a missing or type-incompatible mapped column fails.

⚠ **The green is only meaningful because of the control.** In the *same* configuration (probe
migration still applied) reintroducing `@Column(name = "bottlesNeeded")` on
`ReplenishmentMonitorView.bottlesNeeded` went **RED** with
`SchemaManagementException: Schema-validation: missing column [bottlesNeeded] in table
[replenishment_monitor_view]`. Without that, "validate ignores these shapes" and "validate wasn't
running" are indistinguishable — see [[a-zero-scan-needs-a-positive-control]].

**Two more things that surprise people:**
- The validator reports the **FIRST** mismatch and **stops**. A green means zero; a red names one
  problem, not the list. Expect to fix iteratively.
- It reaches **both** wms2 persistence units, because `TenantDatabaseConfig` and
  `LandlordDatabaseConfig` each read `spring.jpa.hibernate.ddl-auto` via `@Value` and insert it as
  `hibernate.hbm2ddl.auto`. So it is NOT blocked by
  [[wms2-tenant-persistence-unit-gets-no-jpa-properties]] (SBDEV-3246) — `ddl-auto` and `dialect`
  are the two properties that bypass that empty vendor-property map.

**How to apply:** do not use a validate lane as evidence that a schema *matches* — it proves no
mapped column is missing. For "does this tenant's schema equal `db/migration`", diff
`information_schema.columns` yourself; see
[[wms2-tenant-schema-fingerprint-vs-db-migration]].
