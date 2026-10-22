---
name: wms2-it-seeding-system-client-must-evict-clients-cache
description: "Any wms2 H2 IT that seeds the System client and reaches ClientService.getSystemClient() must clear the `clients` cache in @BeforeEach AND @AfterEach — rollback does not evict it"
metadata:
  node_type: memory
  type: project
  originSessionId: 2ecfa799-7c20-4505-ab17-331e8a4cc72f
  modified: 2026-10-09T19:00:32.900Z
---

`ClientService.getSystemClient()` is `@Cacheable("clients")`; BaseIntegrationTest's rollback does NOT evict
the entry, so a System client seeded by one class outlives its row and breaks
`ClientServiceIntegrationTest.systemClientTest` ("expected: 0L but was: 2L") depending on failsafe run order.
Hit twice: SBDEV-3320 (MobilePickingServiceIntegrationTest) and SBDEV-3709 (MobilePutawayServiceIntegrationTest,
PR #489 — reproduced with `-Dfailsafe.runOrder=reversealphabetical`).

The non-obvious reach: **PutawayDestinationResolver tier 3 calls getSystemClient() on every `resolve()`**, so
any IT through `calculatePutAwayList` or receiving's putaway gate needs the System client seeded AND the
eviction — tier 3 throws "System-Client not found" if it is absent, before tier 4 is reached.

**Why:** passes alone and locally, fails in CI order — the classic false green.
**How to apply:** copy the evictClientsCache() @BeforeEach/@AfterEach pair from either class above. To prove it
is load-bearing, remove it and run the two classes together with reversealphabetical order. Related:
[[a-test-can-pass-for-the-wrong-reason-vary-the-fixture]].
