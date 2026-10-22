---
name: wms2-h2-schema-reset-leaves-stale-app-caches
description: "H2 lane — a new context's create-drop restarts the id sequence under an older cached context whose Caffeine caches stay warm → stale itemdata/client hits; fixed by a cache-reset listener (SBDEV-3729)"
metadata:
  node_type: memory
  type: project
  originSessionId: 8ba50089-49fb-4127-9271-10ab67b75ecb
  modified: 2026-10-12T00:25:59.908Z
---

`BaseIntegrationTest` contexts all use `jdbc:h2:mem:wms_integration` with `ddl-auto=create-drop`. When a class with different bean overrides starts its own context (e.g. `MobilePalletizeBulkMintIT`'s `@MockitoSpyBean`), that context re-creates the schema, which restarts `seqentities` (`allocationSize = 1`, so older contexts draw the restarted values directly). An OLDER context still cached keeps its Caffeine caches (`itemdata`, `clients`, `locations`, `sysprops`) warm, so a fresh row can reuse an id that a stale entry holds.

Hit PR #505's CI on 2026-10-11: `MobilePutawayServiceIntegrationTest` → "Client not found with id: 89" via the cached `itemdataService.getById`. It was green locally and on develop: the failure depends on class order and id allocation.

Fixed in SBDEV-3729 by `common/base/ApplicationCacheResetTestExecutionListener` (spring.factories). Before each class it clears every `CacheManager` cache, but only when `testContext.hasApplicationContext()`. That guard is load-bearing: without it, `getApplicationContext()` in `beforeTestClass` loads Postgres-lane contexts before `AppPostgresDBSetupExtension` provisions the landlord DB, and 63 ITs failed with "failure threshold exceeded".

**Why:** this is a third way the shared create-drop DB bites, after [[wms2-baserollback-shared-h2-create-drop]] and [[new-test-context-fork-breaks-an-unrelated-it]] (those drop tables; this one leaves the caches stale).

**How to apply:** for an order-dependent "X not found with id: N" in an H2 IT, suspect a stale cache after a schema reset. In the CI log, check which classes ran between the cache-warming class and the failure, and which of them started a context ("Starting <Class> using Java"). A class on its own Postgres container does not touch `wms_integration`.
