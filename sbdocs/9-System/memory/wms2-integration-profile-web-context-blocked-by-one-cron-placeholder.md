---
name: wms2-integration-profile-web-context-blocked-by-one-cron-placeholder
description: wms2-api's @SpringBootTest + @AutoConfigureMockMvc lane is not dead — one @Scheduled cron placeholder has no default, and supplying it boots the full web context
metadata:
  type: project
---

The full-web-context MockMvc lane in v2/wms2-api (`@SpringBootTest(classes = StartApplication.class)` +
`@ActiveProfiles("integration")` + `@AutoConfigureMockMvc`) fails to load on `origin/develop` for a reason
that has nothing to do with datasources:

```
Could not resolve placeholder 'app.cron.cleanup-rest-idempotency'
```

`RestIdempotencyCleanupJob:48` declares `@Scheduled(cron = "${app.cron.cleanup-rest-idempotency}")` with
**no default**, and the property is absent from `src/test/resources/application-integration.properties`, so
the refresh dies **before any handler mapping exists**. It is the only such placeholder —
`OutboxDispatcherJob:57` uses `${app.cron.outbox-dispatcher:*/15 * * * * *}` and needs nothing.

Supplying `app.cron.cleanup-rest-idempotency=-` via `@TestPropertySource` was enough to boot the full web
context and run MockMvc against real SDR handler mappings (verified 2026-08-24, JDK 21.0.11 + Maven
3.9.15 + `-o`) — so the "landlord datasource not configured" attribution on the two `@Disabled` H2 MockMvc
tests is **stale**: the same annotations plus that one property boot fine.

**The fix belongs in product code, not in each test base:** give the placeholder a default
(`${app.cron.cleanup-rest-idempotency:-}`), which un-breaks `BaseIntegrationTest`,
`BaseRepositoryIntegrationTest` and `BaseControllerIntegrationTest` at once. `BaseRollbackIntegrationTest`
already carries the property in its own `@TestPropertySource` — which is why the three
`smoke/*ContextLoadTest` classes are green (3/3, measured) while the MockMvc lane is not. The workaround
existed in one of four base classes and was never propagated.

**Why:** `CustomerOrderControllerIntegrationTest` currently errors with a bare
`Failed to load ApplicationContext`, and `ReplenishOrderControllerH2Test` /
`CustomerOrderControllerH2Test` are `@Disabled` blaming *"landlord datasource not configured
(SBDEV-2099 env skip)"*. That attribution may be stale — the lane reads as structurally dead when it is
two properties from working, which is why every recent authorization test was written against
`standaloneSetup` instead. See [[wms2-it-harness-broken-sbdev-2217]] and
[[wms2-function-gate-anti-drift-only-covers-guarded-classes]] (`setupMockMvc` installs no interceptor, so
gate tests written that way are vacuous).

**How to apply:** before concluding the web-context lane is unavailable, add the one property and try.
`BaseRollbackIntegrationTest`'s `@TestPropertySource` block is the complete working recipe (H2 landlord +
tenant, `spring.flyway.enabled=false`, `spring.cache.type=none`) — copy from it rather than re-deriving.
Anything that must observe a real handler mapping — interceptor wiring, Spring Data REST dispatch, filter
ordering — is invisible to `standaloneSetup` and needs this lane.
