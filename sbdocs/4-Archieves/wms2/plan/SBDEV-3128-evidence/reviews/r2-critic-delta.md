# SBDEV-3128 r2: Critic delta review

> Saved by the main session from the lane's returned text (the lane had no Write tool). Hibernate bytecode extracts:
> /private/tmp/claude-503/-Users-np1076-dev-spk-owl/4ddfcc59-1650-45c2-b27a-e5f4e6c95b90/scratchpad/hib/ (scratch, not durable).

**VERDICT: ITERATE** — 0 High, 2 Medium, 4 Low. One Medium (M-1) would make the TDD gate encode a mutant that cannot go red; the fix is a text edit.

**Code base.** `git diff --stat 1b421d08 origin/develop` (207db277) touches `CLAUDE.md`, `RequestHeaderSizeFloor.java`, `application.properties` (−12), `logback-spring.xml`, `RequestHeaderSizeTest.java` — request-header config only; the planner's claim holds.

## A. Revision log vs plan body (10 sampled) — all fixes present in the body
Arch H-1 (§3.2 `lockById`, §3.6, AC-4 `InOrder`, §7.3) · Arch M-2 (§3.4 `boundsOutOfDate`, §3.7, AC-14, UI-4/5) · Critic M1 (AC-17 value, both orders) · Critic M4 (§0.3 L5, §4, AC-14b; `ViewDtoService:874-876`) · Critic M5 (§3.3, AC-16a/b, UI-3b) · Critic M6 (§8 step 6 SQL parses; O-4 COALESCE; PM-2) · Critic M8 (AC-18; `ViewDtoService:708`) · Critic M9 (checklist; Risk/Effort) · Critic L6 (DEV: n=1→4, 2→1, 3→1, 28→1 — r2 right) · Critic L8 (`LocationControllerUnitTest:38` only ctor call).

## B. `adjust*` becomes `@Transactional`, trigger post-commit — sound
- `ReplenishmentMaintenanceTrigger:84-109`: in a tx, recalculated in `afterCompletion(STATUS_COMMITTED)` in its own `REQUIRES_NEW`, same thread, before the proxied call returns; outside a tx immediate; a failing recalc never fails the caller. Response timing/contract of `/set*Bound` and `/update` unchanged.
- Callers: `FixLocationAssignmentController:78,80,82` (`/update`), `:161,184,207` (`/set*Bound`). D-3 unchanged in kind.
- Tests: unit tests mock the trigger; `ReplenishMaintenanceDeferralIT` covers create only; no test asserts an inline trigger.
- New `ObjectOptimisticLockingFailureException` reaches `RestEndpointExceptionHandler`/`RestExceptionHandler` → §6 should say "plus a new optimistic-lock response on a conflict".
- Gap: no AC/mutant pins `@Transactional` itself (L-3).

## C. Concurrency via conditional native UPDATEs (READ COMMITTED EvalPlanQual)
| Race | Result |
|---|---|
| Edit vs adjust, edit first | `markOverridden(id, v)` re-checks `version = v` → 0 → OOLFE, loud ✓ |
| Edit vs adjust, adjust first | edit re-checks `and bounds_inherited` → false → 0, correct no-op ✓ |
| Adjust vs adjust | second gets OOLFE ✓ |
| Edit vs create | both `lockById` same row; AC-17 measures both orders ✓ |
| Edit vs move off | `assignedlocation_id = :loc` re-checked → 0, or move's `@Version` save fails ✓ |
| Edit vs move onto | move holds destination from `:163` (`UnitloadBusinessService:243-246`) ✓ |
| Edit vs reset | both lock the location → serialized ✓ |
| Reset vs adjust | last explicit action wins, I-1 holds ✓ |
| **Reset vs move** | reset reads `assignedlocationId` before locking; `resetBounds` has no location predicate → **open (L-1)** |

`@Version` interplay: no tx loads an FLA, native-bumps its version, then saves it. create/adjust native writes don't bump version; reset bumps via native and never dirties the entity (keep that rule explicit); edit loads no FLA entity before `writeThroughInherited`; move has no native bump. `clearAutomatically` unnecessary.

## Findings

### M-1. The "drop `flushAutomatically`" mutant is equivalent in Hibernate 6.6.39; the plan's rationale is wrong
- Plan: §3.2 "without it the UPDATE hits 0 rows"; §7.3 "drop `flushAutomatically` on `markInherited` | AC-4b"; PM-3 names the unflushed INSERT as cause.
- Bytecode (`hibernate-core-6.6.39.Final.jar`): `AbstractQuery.executeUpdate` → `beforeQuery` → `NativeQueryImpl.prepareForExecution`: with no synchronized query spaces (Spring Data adds none) it calls `session.flush()` when `shouldFlush()` (tx in progress, FlushMode AUTO, `isJpaBootstrap()` — `LocalContainerEntityManagerFactoryBean` is). The pending INSERT flushes regardless.
- Consequence: AC-4b stays green under the mutant → the gate demands a red that never comes.
- Confidence HIGH (bytecode); blind spot: not run — confirm empirically at gate time.
- Fix: (1) keep `flushAutomatically = true` as explicit intent; reword §3.2 ("Hibernate 6.6 already auto-flushes before a native `executeUpdate` in a tx; `flushAutomatically` makes it explicit and FlushMode-independent"). (2) Replace the §7.3 mutant with "call `markInherited` before `save`" (or FlushMode COMMIT) → AC-4b red via `== 1` → `IllegalStateException`. (3) PM-3 prevention = the `== 1` guard + AC-4b.

### M-2. D8 failure surface omits `adjust*` and understates the auto-create break; the header is checksum-frozen
- Plan: Principle 5 "that tenant keeps every Location and FLA entity read, so putaway, picking and the replenishment job keep working"; header/PM-1 list auto-create, move/reset, defaults edit, the two lists.
- Actually breaks on a tenant stuck at 2.2.44: (1) **`adjust*`** (`markOverridden` → 42703) = existing `/set{Upper,Middle,Lower}Bound` (`fixedLocation.js:137,157,177`) and `/update` — listed nowhere; (2) **every putaway / move-unitload / replenish-finish into a flowbin without an FLA** (the five W1c callers) — create's first native read raises 42703, PG aborts the tx, the whole operator action rolls back; (3) both admin lists (listed).
- r2 is still strictly better than r1; the finding is honesty + residual blast radius.
- Fix — minimum: correct Principle 5, PM-1, header list. **Recommended (~½ hr + 2 tests):** non-aborting probe `select exists (select 1 from information_schema.columns where table_schema = current_schema() and table_name = 'fix_location_assignment' and column_name = 'bounds_inherited')` — cannot raise 42703, works on H2 (`DATABASE_TO_LOWER`), cheap per call. Probe false → create seeds from sysprop (today's behaviour) and skips `markInherited`; `adjust*` skips `markOverridden`. Admin lists may fail. AC + mutant. Nam's call; text fix mandatory either way.

### Low
- **L-1** Reset vs move: `resetBounds … where id = :id` lacks `and assignedlocation_id = :locationId`; add it with `== 1` else OOLFE; unit assertion + mutant "drop the location predicate".
- **L-2** Five existing unit tests go red by construction: create (`FixLocationAssignmentServiceUnitTest:405`, `:963`) — `lockById` default `Optional.empty()` → `EntityNotFoundException`, `markInherited` 0 → `IllegalStateException`; three adjust happy paths (`:129,176,221`) — `markOverridden` 0 → OOLFE. State the re-stubbing in §7.2/AC-4/AC-5.
- **L-3** Nothing pins `@Transactional` on `adjust*`/reset/edit (12 repo precedents pair `@Modifying` with repository-level `@Transactional`). Add mutant "drop `@Transactional` on `adjustUpperBound`" → AC-5b red (call with no ambient test tx); state "no `@Transactional` on the new repository methods".
- **L-4** Principle 1/§6 "readers unchanged" vs R2 "+4 columns" → "no reader's bound expression changes".

## What's missing
- Explicit "reset never saves the FLA entity" executor note.
- §6: new optimistic-lock response on `/set*Bound` under contention.

## E. H2 harness — verified
`TestDatabaseConfig` (`src/test/java/net/aim_ai/wms/common/config/`) `@Import`ed by `BaseIntegrationTest:25`, already runs raw DDL on `landlordDataSource`. EMF bean `tenantEntityManagerFactory` (`TenantDatabaseConfig:116`), no async bootstrap → `@DependsOn` orders after create-drop. Landlord and tenant URLs same H2 DB (`application-integration.properties:20,31`); `:38,:40` create-drop; `:51` Flyway off. Shared `EntityManagerFactoryBuilder` (`TenantDatabaseConfig:87-104`) → `import_files` rejection holds. `@Primary DataSource` is a Mockito mock → `spring.sql.init` rejection holds. No schema/import/data SQL on either classpath. Unverified: the four ITs not run.

## F. Migration SQL and header — correct except the M-2 42703 list
Keys match `WmsConstants:1356-1360`; CTE mirrors `SyspropRepository:30` incl. NULL `client_id` ordering; regex rejects only 19-digit longs; 5s matches `V2.2.40:13`; precedent `V2.2.40:9-11`; deadlock/runbook sentences accurate. DEV 2026-11-01: 2750 locations, 1344 FLAs, 1307 at 36/60/84, 0 new columns, head 2.2.44.

## G. Spot-checks (14, all correct)
`FixLocationAssignmentService:86-88,121,163,167-168,301-307`; `ViewDtoService:708,874-876,903-905`; `LocationRepository:127-129`; `UnitloadBusinessService:243-246`; `StockunitBusinessService:349-350`; `SyspropRepository:30`; `LocationControllerUnitTest:38`; `V2.2.40:9-13`; `StartupFlywayMigrator`. Completeness words: "putaway … keep working" false (M-2); others hold.

## Ruled out
Code delta matters; managed-FLA + native-bump + save collision; `/set*Bound` timing change; existing inline-trigger tests; H2 bean ordering; missing `exported=false`; Storage Locations list consumed elsewhere; backfill tier mismatch.

## Verdict justification
ITERATE on M-1 alone (gate mis-programmed). M-2 text mandatory; probe is Nam's call. L-1..L-4 same pass. To APPROVE: M-1 rationale + mutant swap, M-2 header + Principle 5 text (with or without probe).
