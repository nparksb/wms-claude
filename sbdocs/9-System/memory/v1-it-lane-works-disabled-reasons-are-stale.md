---
name: v1-it-lane-works-disabled-reasons-are-stale
description: The v1/wms-api @SpringBootTest IT lane DOES boot; the five @Disabled "SBDEV-2384 ro_id view drift" annotations are wrong on both counts
metadata:
  type: project
---

Five v1/wms-api ITs carry `@Disabled("SBDEV-2384: v1 IT lane context-load broken (ro_id view drift)
— enable when fixed")` (`MoveStockMoveUnitloadConcurrencyIT`,
`ReplenishGenerationTransactionBoundaryIT`, `ReplenishmentOrderSourceSyncIT`,
`ReplenishAdvisoryLockConcurrencyIT`, `SBDEV2496DeferredTests`). **That reason is stale on both
counts** (measured 2026-09-08 on `origin/develop` @ `a0e859a`):

1. The `ro_id` fix **landed** — `V1.26.30__replenishment_monitor_view_add_ro_id.sql`.
2. The real blocker was never `ro_id`. Removing the `@Disabled` gives
   `BeanDefinitionOverrideException: … 'inventoryRecordRepository' … already defined in
   RepositoryH2TestConfiguration`. `unit/repo/RepositoryH2TestConfiguration` is annotated
   `@SpringBootApplication` and sits **inside** `net.aim_ai.wms`, so `@SpringBootTest(classes =
   StartApplication.class)` component-scans it and its `@EnableJpaRepositories` collides.

**The lane works.** `ReplenishmentMonitorViewRepositoryIT` runs **14 tests green in ~26 s**. The
recipe is already in two ITs — add to `@SpringBootTest`:

```java
properties = {
  "spring.main.allow-bean-definition-overriding=true",   // the collision above
  "spring.jpa.hibernate.ddl-auto=none"                   // mirror prod; entity/view drift can't abort startup
}
@MockBean private OAuth2RestTemplate oauth2RestTemplate;  // Keycloak is called eagerly at bean creation
```

plus the environment overrides in [[run-v1-wms-api-testcontainers-its-locally]].

**How to apply:** never accept a `@Disabled` reason as the current cause — remove it and read the
actual failure. Same family as [[plan-state-probe-beats-reading-plan-status]] and
[[absence-of-a-path-is-not-absence-of-the-guarantee]]: a hand-written note about why something is
broken is not evidence that it is still broken for that reason. Re-enabling these five is worth its
own ticket — but see [[un-suppressing-a-test-can-create-a-false-green]] before trusting a green.
