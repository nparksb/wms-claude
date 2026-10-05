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

## Third consequence: DML ordering (added 2026-09-23, SBDEV-3458 review)

`spring.jpa.properties.hibernate.order_inserts` / `order_updates` are set
(`src/main/resources/application.properties:93-94`) and are **inert for tenant entities** for the
same reason. `src/test/resources/application.properties` shadows the main file and carries neither,
so no lane sees them either — see [[wms2-test-resources-shadows-main-application-properties]].

**Why it matters beyond one more inert property:** it is load-bearing for reasoning about write
order. Caught in review when I justified splitting two deletes into separate transactions with
*"Hibernate orders DML by entity type rather than by call order."* Wrong three ways, any one
sufficient: (1) there is **no delete reordering at all** — `ActionQueue` runs action types in a fixed
sequence (orphan-removal → insert → update → collection → delete) and sorts only *within* the insert
and update buckets; there is no `hibernate.order_deletes` setting in Hibernate; (2) the two sort
settings that do exist never reach these entities, per above; (3) the familiar
[[hibernate-delete-then-reinsert-same-key-needs-set-difference]] hazard is **inserts-before-deletes**,
a *cross-type* property — it says nothing about two operations of the same type.

**So: scheduled deletes execute in call order, and two deletes in one transaction respect a FK if you
call the child first.** Do not split a transaction to "guarantee" ordering Hibernate already gives
you — the split buys nothing and costs atomicity.

Related: [[wms2-repository-tests-commit-they-do-not-roll-back]] — same family, a JPA wiring detail
silently defeating a guarantee the tests assumed.
