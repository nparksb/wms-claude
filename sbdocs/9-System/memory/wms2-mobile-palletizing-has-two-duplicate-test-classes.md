---
name: wms2-mobile-palletizing-has-two-duplicate-test-classes
description: wms2-api XxxTest/XxxUnitTest duplicate pairs (11 at 2026-08; MobilePalletizing merged 2026-10-20) — a red test can be duplicated-green, and scoping PIT to one class misattributes the kill; SBDEV-3102 slice C
metadata:
  type: reference
---

> **UPDATE 2026-10-20 (SBDEV-3102 C1, merged to develop as #543, head 006c483a):** the
> `MobilePalletizingService` pair is merged. `MobilePalletizingServiceTest` was folded into
> `MobilePalletizingServiceUnitTest` and deleted; the merged class runs under `STRICT_STUBS` (both LENIENT
> opt-outs and the `FROZEN_PAIRS` entry removed). The dead `"PALLET-001"` stubs listed at the bottom were
> deleted with it. `FROZEN_OPT_OUTS` is now EMPTY: no wms2-api test opts out of STRICT_STUBS. Slice C finished 2026-10-21
> (C3 #545, C2 #547): every duplicate pair is consolidated; `FROZEN_PAIRS` holds only the deliberate
> CustomerorderService KEEP. The pairs listed below are HISTORY.

Tracked as **SBDEV-3102** (filed 2026-08-26). `wms2-api` has **11 `XxxTest`+`XxxUnitTest` pairs**
across 365 test files — **9 genuine same-kind duplicates**, plus 2 legitimate integration-vs-unit
splits (`CustomerorderService` on `BaseRepositoryIntegrationTest`, `KeycloakService` on
`@SpringBootTest`) that must NOT be "fixed". The pair that bit me:

- `unit/service/mobile/MobilePalletizingServiceTest.java` — flat `testXxx` naming
- `unit/service/mobile/MobilePalletizingServiceUnitTest.java` — `@Nested` + `@DisplayName`

They cover overlapping ground. On SBDEV-3089 the *same* scenario existed in both:
`MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate` (red for a month)
and `MobilePalletizingServiceUnitTest:1116 shouldThrowExceptionWhenPalletAlreadyAssignedToGate`
(green the whole time, already using the correct `doThrow` + `verify` on the collaborator).

**Two traps this creates:**

1. **A red test is not proof of a coverage gap.** I claimed the guard "could be deleted and
   every test would stay green"; false — the sibling class already killed that mutant on
   `develop`. The fix removed a false signal and added **zero net mutation coverage**. Before
   asserting a gap, grep the *other* class for the same scenario.
2. **`-DtargetTests` scoped to one class misattributes the kill.** PIT reports the first
   killing test it runs among the tests you gave it, so scoping to one class will always name
   that class — it is never evidence that no other test would have killed the mutant. See
   [[mutation-harness-traps]].

**Do not assume `XxxTest` = legacy and `XxxUnitTest` = canonical.** True for 4 of the duplicates,
but the **4 job pairs** (`CleanUpOldMessagesJob`, `OrderReleaseJob`,
`ReleaseExpiredPickingOrdersFromUserJob`, `StockSummaryExportJob`) have BOTH halves on
`BaseServiceUnitTest` and the `…Test` half is the **larger** one. Merge direction is per-pair.

Also: **47 of 365 test classes use `Strictness.LENIENT`; zero use `STRICT_STUBS`.**
`@MockitoSettings(strictness = Strictness.LENIENT)` on `MobilePalletizingServiceTest:26`
is why 9 dead stubs survived a refactor silently — under `STRICT_STUBS` every one would have
thrown `UnnecessaryStubbingException` the day the refactor landed. The same dead-stub pattern
is still present in `MobilePalletizingServiceUnitTest` (`"PALLET-001"` stubs at :997, :1022,
:1049, :1077, :1104, :1161, :1196, :1240, :1280). Related: [[sbdev-3089-two-red-tests-on-develop]].
