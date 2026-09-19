---
name: wms2-tenant-persistence-unit-gets-no-jpa-properties
description: wms2-api's tenant persistence unit is built with an empty vendor-property map, so no spring.jpa.properties.* ever reaches it — naming strategy absent, bean validation unconfigurable, in every lane
metadata:
  type: project
---

**SBDEV-3246, filed 2026-09-07.** `TenantDatabaseConfig.entityManagerFactoryBuilder` (`:36-45`) does
`new EntityManagerFactoryBuilder(adapter, new HashMap<>(), ...)`. That second argument is the
**vendor-property map**; Boot's own auto-config passes the resolved `spring.jpa.properties.*` there.
So for the `tenant` unit — all 60+ warehouse entities — **no `spring.jpa.properties.*` key from any
profile has any effect**, in every lane including H2.

Two consequences, both of which read as unrelated bugs:

- **No physical naming strategy.** Hibernate falls back to identity, so a field without an explicit
  `@Column(name=…)` maps to its literal camelCase name → folds to lowercase in PG → column not found.
  Produced [[wms2-replenishmentmonitorview-entity-drift]] (SBDEV-3247).
- **`validation.mode=NONE` is inert.** `application-integration.properties:33-37` has claimed to
  "skip bean validation in tests" since the H2 lane was written; for tenant entities it never did.
  So a `ConstraintViolationException` on a tenant fixture is a **genuinely incomplete fixture**, not
  a lane artefact — don't chase the property.

**The trap:** `hibernate.dialect` and `hbm2ddl.auto` DO work, because `tenantEntityManagerFactory`
re-reads them via `@Value` and re-inserts them by hand. The two properties anyone would spot-check
are exactly the two that are wired, so the gap looks like it isn't there.

Only the H2 lane's `ddl-auto=create-drop` hid it: it *creates whatever the entity declares*, so
entity and schema agree by construction. Production is `ddl-auto=none`, so no boot-time check either.
The first `validate` ever run against a real migrated schema found drift immediately.

Related: [[wms2-repository-tests-commit-they-do-not-roll-back]] — same family, a JPA wiring detail
silently defeating a guarantee the tests assumed.
