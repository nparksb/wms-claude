---
name: wms2-tenant-persistence-unit-gets-no-jpa-properties
description: "SBDEV-3246 (merged f977c018, 2026-10-11) — wms2-api's tenant AND landlord units now get Boot's full spring.jpa.properties map; before, the shared builder map was empty. Traps that fix surfaced: order_inserts unsafe, test props shadow main, format_sql breaks SQL capture"
metadata:
  node_type: memory
  type: project
  originSessionId: 7a84f2ad-550e-49b2-a057-ec72c96ff191
  modified: 2026-10-11T02:15:16.065Z
---

**State (2026-10-11): MERGED to develop `f977c018` (PR #500), deployed on dev.** Branch was `bugfix/SBDEV-3246-jpa-properties-reach-both-units`
(pre-rebase SHAs in older notes are orphans). Prod gains batching only on promotion past develop.

**Before the fix.** `TenantDatabaseConfig.entityManagerFactoryBuilder` was the app's ONLY
`EntityManagerFactoryBuilder`, seeded with `new HashMap<>()`, and BOTH units (tenant and landlord) build
off it. `StartApplication` **excludes `HibernateJpaAutoConfiguration`**, so nothing else supplied the map:
no physical naming strategy (identity), `validation.mode=NONE` inert, `batch_size`/`order_*` inert. Only
`dialect` and `hbm2ddl.auto` worked (re-read via `@Value`), which is why the gap looked absent.

**The fix:** `HibernateProperties.determineHibernateProperties(jpaProperties.getProperties(), ...)`
into the builder, with `@EnableConfigurationProperties({JpaProperties, HibernateProperties})` on the
config, because the auto-config that would bind them is excluded. Deleting the custom builder "so
Boot's takes over" would leave prod with NO builder. A test that adds the auto-config to its context
runner would pass that wrong fix.

**Traps it surfaced. These stay true after merge:**
- **`hibernate.order_inserts` is unsafe here** and was dropped (Nam, 2026-10-10). Hibernate learns insert
  dependencies only from mapped associations, and v2 maps FKs as plain `Long` columns. So it groups a
  flush's inserts by entity type, and S1, U1(new), S2(→U1) runs as S1, S2, U1, which fails one of 130
  non-deferrable FKs with 23503. `ForbiddenJpaPropertiesUnitTest` bans it.
- **`src/test/resources/application.properties` shadows the main file** in every lane. Any newly-live
  key must be checked in BOTH files. Its `jdbc.time_zone=America/New_York` went live and broke
  `ReplenishLaneExclusionUnconditionalIT` under UTC only (CI is UTC, the dev host is NY, so local stayed
  green). Removed. **Run `TZ=UTC mvn clean verify -Pci` to match CI.**
- **`format_sql=true` logs SQL across several lines.** Any test matching captured `org.hibernate.SQL` text
  must collapse whitespace first (`StockunitSkipLockedIT`).
- Bean validation is ON in every lane, deliberately (AC-5). A `ConstraintViolationException` means the
  fixture is incomplete. Do not re-add `validation.mode=NONE`; it would work now.
- The naming strategy also applies to explicit names and implicit TABLE names.
  `EntityColumnNameResolutionArchTest` requires explicit names for camelCase fields AND for entities with
  an internal capital.

**Delete order is still call order.** There is no `order_deletes`, and `ActionQueue` runs inserts → updates →
deletes. Do not split a transaction to "guarantee" FK delete order.

Related: [[wms2-test-resources-shadows-main-application-properties]] ·
[[hibernate-delete-then-reinsert-same-key-needs-set-difference]] ·
[[concurrent-maven-one-worktree-false-reds]]
