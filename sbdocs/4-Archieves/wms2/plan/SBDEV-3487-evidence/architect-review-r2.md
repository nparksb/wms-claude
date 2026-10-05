---
title: "SBDEV-3487 architect review r2"
snapshot_sha1: bac6c5a4d83536acc2c4b3b3f9f1b1505695d724
---

## Verdict: SOUND-WITH-CHANGES

r2 resolves all nine of my round-1 findings, and each resolution holds up against the code. Two things need fixing before Step 2:
- **N1 (High).** As written, AC-6a, AC-6b and AC-10a hit a `NullPointerException` on a fixture defect before the code under test runs. The Step 2 STOP rule would then "withdraw the C2 claim" for a reason that has nothing to do with C2.
- **N2 (Medium).** The plan says rejections come back as "4xx". Both endpoints actually return HTTP 200 with an `errors` body.

The rest are Low.

## Resolution check, F1–F9

| # | Status | Checked against |
|---|---|---|
| F1 finishTransfer | **Resolved, correct.** §2.1 has the order right: BOL `FOR UPDATE` (`BillofladingService.java:1485`), then the positions bulk update (`:1511-1516`), then Unitload (`:1590-1597`). The deadlock argument holds for both V1 and C2. | BillofladingService |
| F2 R2 / A2 reason / positive control | **Resolved, correct** (see Q3 below). R2 is now "unreachable". A2 is rejected for the `clearAutomatically` reason. AC-10a was added. | UnitloadBusinessService `:526-527,544` |
| F3 RALPLAN-DR | Resolved (§2.5) | — |
| F4 mixed tree | Resolved (§5.5) | — |
| F5 `throws` | **Resolved, correct.** `assertNothingWasWritten` (`MobileTruckLoadingWriteServiceUnitTest.java:124`) is the only caller without `throws`. The other callers at `:237`, `:497`, `MobileMoveUnitloadServiceUnitTest:534,550,896` and `MobileMoveUnitloadServiceTest:638` already declare it. | grep of every caller |
| F6 measured vs code-read | Resolved (§2.1, §5.3 comment, follow-up (b)) | — |
| F7 AC-2 | **Resolved.** `MobileTruckLoadingServiceTest` builds a real `OutboundPalletLabelGuard(syspropService)` (`:81`) under `STRICT_STUBS`. The target tests exist at `:402` and `:427`. The other scanGate tests (`:464`, `:494`) hit a void mock and need no stub. | — |
| F8 re-check | Adopted (§5.5, AC-11) | — |
| F9 §3.3 | Resolved (SBDEV-3490 coupling recorded) | — |

## Focus questions

**(a) `void`→`int`.** This is legal. Spring Data JPA accepts `void`, `int` or `Integer` on a `@Modifying` query. The repository is `exported = false` at class level (`BillofladingPositionRepository.java:20`), so the method-level `@RestResource(path=…)` on R5/R6 doesn't expose them over HTTP.
- In the unit tests, Mockito's default of 0 reaches the re-check at exactly one site: `MobileMoveUnitloadServiceUnitTest:556`, the only place that stubs R1 non-null. The other R1 stubs return null (`:902`, `MobileMoveUnitloadServiceTest:645`). The write-service tests mock the whole `MobileMoveUnitloadService`.
- In production and the ITs, the real counts are used.
- One nit is N4 below.

**(b) Is the 0-row re-check unreachable today?** Yes, that holds.
- V1 holds B2.
- Two C2 moves on the same pallet serialise on the pallet row and the loser fails its `@Version` check before it reaches R5.
- The only other position deleters are `BillofladingPositionService:162,166`. They delete parcel-level rows, never the pallet row.
- R4's id list is the children plus the pallet id, so it cannot delete the pallet row itself.
- Under READ COMMITTED, the re-check is a fresh statement, so it sees whatever the waiting DELETE saw.

**(c) Logback ListAppender.** This is robust.
- The PG profile sets `logging.level.net.aim_ai=INFO` (`application-postgres-integration.properties:214`), so a WARN reaches the appender.
- `BillofladingPositionService` logs through `LoggerFactory.getLogger(BillofladingPositionService.class)` (`:15`).
- The pom configures no parallel execution and there is no `junit-platform.properties`.
- Caveat: `TenantProbeStallTest:135-150` is a unit test with no Spring context. See N5.

**(d) AC-10b (the NOWAIT check).** Sound in substance.
- `jdbcTemplate` runs on `PostgresTestSupportConfig`'s `DriverManagerDataSource` (fixture `:138`, `:340-351`). That gives a fresh autocommit physical connection that is not bound to `tx()`.
- The fixture is committed (`seedPallet` runs in its own `tx()`, `:235`), so both sides see it.
- Nothing on the transfer path takes a lock on the unitload row:
  - `findByIdForUpdate` locks only the destination location (`UnitloadBusinessService:244`).
  - `lockOwningPickingorders` locks only pickingorder rows.
  - `unitload_record` has no FK to `unitload`.
- So SQLSTATE `55P03` means the pallet UPDATE was actually sent. `findByCarrierunitloadId` at `:544` runs after `save` at `:527`, before `transferUnitLoadToLocation` returns.
- Refinements are in N3.

**(e) AC-6b.** The arm is reachable:
- DEST is type 1, so the flowbin test at `MobileMoveUnitloadService:352` fails and the non-flowbin branch runs.
- DEST is not EmptyPallets.
- `assertSourceCarrierNotOnTruck` does nothing for a pallet.

It is blocked by N1, though, and its provenance should be stated (N6).

**(f) DEST fixture location.** Confirmed.
- `location_type` 1 is `NoRestriction` (`V2.2.00:2546`).
- None of the `location_constraint` seeds (`:2517-2525`) uses `storagelocationtype_id` 1, and no later `db/migration` file adds constraint rows.
- `PgLaneFixtures.location` sets type 1 and `entity_lock` 0 (`:120`, `:129`).

**Q3. The §2.1 C2 derivation is correct.**
- `findByCarrierunitloadId` is a derived JPQL query on `Unitload` (`UnitloadRepository:50`). It runs at `:544` after the dirty `save` at `:527`, so Hibernate auto-flushes the pallet UPDATE.
- The pom inherits Hibernate 6.6.39 from Boot 3.5.9. In that version, `NativeQueryImpl.prepareForExecution()` calls `getSession().flush()` when no query spaces are declared and `shouldFlush()` is true. Under AUTO flush mode, `shouldFlush()` returns `isJpaBootstrap()`. I checked this in the sources jar, lines 653-690.
- The EMF is a `LocalContainerEntityManagerFactoryBean` (`TenantDatabaseConfig` ~`:70`), which is a JPA bootstrap.
- `processTransfer` re-reads the pallet through `findById` and gets the same stale L1-cached instance. So a close that committed in between makes the UPDATE fail its version check.

**Q4. Principles and length.** No principle violations. P5 now holds. At 391 lines the length is acceptable. Optional cuts: the struck-through §8 R2 row, and the §1 DB bullets that repeat analysis §8.

## New findings

| # | Sev | Location | Finding | Concrete change |
|---|---|---|---|---|
| N1 | **High** | AC-6a, AC-6b, AC-10a; the Step 2 STOP rule | `seedPallet` → `PgLaneFixtures.unitload` never sets `entityLock`, so the pallet row has `entity_lock` NULL (`Unitload.java:12`, no default). `scanDestination` does `sourceUnitLoad.getEntityLock() == ON_HOLD` (`MobileMoveUnitloadService.java:310`). That compares an `Integer` with an `int`, unboxes, and throws `NullPointerException` before the transfer runs. No IT has ever called `scanDestination`. Its siblings set `ul.setEntityLock(0)` explicitly (`MobilePalletizeRepalletizeIT:300`, `MobilePalletizeGuardOrderIT:225`). A second problem: AC-6a says "close X as CLOSED (as `closeBolAsShipped`) → pallet on Shipped, lock 405", but `closeBolAsShipped` writes only BOL and position state (`MobileTruckLoadingClosedBolPurgeIT:117-124`). AC-6b's claim "entity_lock 0" is also false as the fixture stands. | Have the new IT set the state with jdbc before calling `scanDestination`:<br>• 6b and 10a: pallet `entity_lock = 0`.<br>• 6a: mirror what closeBOL writes (`BillofladingService:664-678`). Pallet and child get `storagelocation_id` = Shipped and `entity_lock` 405; the stockunits get 405.<br>Add to the STOP rule: "an NPE at `:310` is a fixture defect, not grounds to withdraw C2". |
| N2 | Medium | §6.2 rows 1 and 3; ADR Consequences "A new 4xx" | Both controllers catch `BusinessException` and return **200** with `errors:[{…message}]` (`TruckLoadingController:119-133`, `MoveUnitloadController:73-79`). `MobileTruckLoadingService:220` says the same thing. | Change the expected result to "HTTP 200, `errors[0]` carries 'Pallet … already part of BOL …'", and fix the ADR line to match. |
| N3 | Low | AC-10b | Two refinements:<br>• An FK check takes `FOR KEY SHARE`, which conflicts with `FOR UPDATE`. This path has no such check today, but a future insert that references `unitload` would make `55P03` fire without any UPDATE.<br>• A `FOR UPDATE` on a missing or wrong id returns 0 rows with no error, so a positive control of "lock acquired" can pass vacuously. | • Use `FOR NO KEY UPDATE NOWAIT`, which does not conflict with `FOR KEY SHARE`.<br>• The positive control should assert that the pallet id comes back.<br>• Call `status.setRollbackOnly()` inside `tx()`. |
| N4 | Low | §5.7 row `MobileMoveUnitloadServiceUnitTest` | The row says "stub R3/R5 `thenReturn(1)`", but the V2 happy path (`:550`) calls only R5. Stubbing R3 fails with `UnnecessaryStubbingException` under the MockitoExtension default. Also, `verify(repo).deleteBolPositionById(1L)` passes whatever R5 returns. | Stub R5 only. Add `verify(bps, never()).assertPalletNotShipped(any(), eq(MOVE_UNITLOAD_D0_RECHECK))`. |
| N5 | Low | §6 layer attribution | The precedent (`TenantProbeStallTest`) has no Spring context. In an IT, the appender must be attached after the context loads, because Boot's LoggingSystem resets appenders when a context starts. | Attach it in `@BeforeEach` and detach it in `@AfterEach`. Filter on logger name, level WARN and the message template, then assert `getArgumentArray()[0] == site`, not the formatted text. |
| N6 | Low | AC-6b | Neither code path that writes CLOSED leaves a pallet off Shipped: closeBOL `:664-671` and finishTransfer `:1590-1597` both move the whole tree to Shipped with lock 405. The AC-6b state only arises after some move that doesn't purge positions takes the pallet out of Shipped. | Say so in AC-6b's javadoc, so nobody deletes it as "unrealistic". It is exactly the case where Fix C is the only protection. |

No new steelman argument or tradeoff tension came up.

## References
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:287,310,352-378,488-574`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java:221-341,522-559`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java:20,109-162`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java:50`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/service/BillofladingService.java:664-678,1478-1516,1590-1605`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/java/net/aim_ai/wms/controller/mobile/MoveUnitloadController.java:67-79`; `TruckLoadingController.java:112-133`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java:138,152,170-290,340-351,435`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/integration/service/mobile/MobileTruckLoadingClosedBolPurgeIT.java:117-124`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/java/net/aim_ai/wms/common/fixtures/PgLaneFixtures.java:112-130,202-219`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:2460-2480,2517-2525,2544-2553,2615,2638`
- `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487/src/test/resources/application-postgres-integration.properties:214`
- Hibernate 6.6.39 `NativeQueryImpl.prepareForExecution` / `shouldFlush`, from the local sources jar (`~/.m2/.../hibernate-core-6.6.39.Final-sources.jar`)
- Snapshot reviewed unmodified: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3487-evidence/plan-snapshot-r2.md` (sha1 `bac6c5a4d83536acc2c4b3b3f9f1b1505695d724`)