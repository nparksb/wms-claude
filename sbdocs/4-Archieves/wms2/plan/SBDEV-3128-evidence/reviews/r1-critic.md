# SBDEV-3128 r1 — Critic review

> Saved by the main session from the lane's returned text (the lane had no Write tool).
> **Main-session note on M1/M2's lock-clause premise:** the Critic grepped `PostgreSQLDialect.class` bytes and found no
> `for no key update`, so concluded `findByIdForUpdate` emits `FOR UPDATE`. The repo's `LockReads` javadoc
> (origin/develop) says the dialect renders `FOR NO KEY UPDATE` on PostgreSQL and that `StockunitSkipLockedIT`
> MEASURED it. Two instruments disagree; the runtime measurement outranks a byte grep (Hibernate 6 assembles lock
> clauses in the SQL AST translator, not as one dialect string). Architect's H-1 (JPQL `PESSIMISTIC_WRITE` →
> `FOR NO KEY UPDATE`) stands; M1's value-assertion requirement for AC-17 stands independently of the clause.

**VERDICT: ITERATE** (0 High, 9 Medium, 10 Low)

**Overall assessment:** The design direction is sound and largely well grounded. Most file:line citations hold, the DEV counts reproduce exactly, the writer enumeration is complete, and V2.2.45 is genuinely free. But four things need revision before the TDD gate:
- **Concurrency section (§3.6).** It rests on lock facts that are wrong or were left for someone else to check, so its one regression test (AC-17) can't kill the mutant it claims to kill.
- **Frozen migration header.** It states something false.
- **Settled O-1 decision.** It isn't reflected in the ACs, the service steps or the UI.
- **Storage Locations list.** The plan's file list leaves out one wiring step, so the new list columns would ship blank with no test noticing.

No finding is High after the realist check. There are 9 Medium findings, which suggests a systemic pattern (concurrency and claim facts not re-verified), so I switched to adversarial mode.

**Mode:** Started THOROUGH, switched to ADVERSARIAL after the 3rd Medium (M1–M3 cluster on unverified lock facts).

## Pre-commitment predictions vs actual

| Predicted | Found |
|---|---|
| Flyway V2.2.45 collision with in-flight branches | **No.** All 499 remote heads are checked; the local `refs/remotes/origin` matches `ls-remote` (0 diffs). No `V2.2.4[5-9]*` on any remote branch, any worktree (`_baseline-develop`, 3552, 3649, 3922, 3947), the main checkout, or any other plan in `1-Projects/`. Prereq #1 holds. |
| ACs that pass on today's code or encode shape | **Partly.** AC-17 asserts ordering, not value (M1). AC-15 is a pure regression net (fine, but label it). AC-8 and AC-6 are interaction-shaped. |
| Concurrency/locking claims not verified | **Yes:** M1, M2. |
| Something in the UI wiring missed | **Yes:** M4 (`getLocationView`), L7 (SBDEV-3560 refusal convention). |
| Incorrect "first/only" claims | **Yes:** M3 (V2.2.40 already sets `lock_timeout`). |

## Medium findings

### M1. AC-17 cannot kill the "FOR SHARE removed" mutant, so the plan's only race-closure guard is a non-discriminating test
- **Evidence: the lock clause.** Hibernate 6.6.39 `PostgreSQLDialect.class` contains only ` for update` / ` for share`, with no `for no key update` string. `getWriteLockString(int)` delegates to `getForUpdateString()`. So `findByIdForUpdate` emits `FOR UPDATE`. *(Disputed — see main-session note at top.)*
- **Evidence: the FKs.** DEV has `fkldy0b50ji7k3475o7u87vyldl` (unitload.storagelocation_id → location) and `fk6h2v1pcxaemjlmshun9be2mfj` (fla.assignedlocation_id → location). Their `FOR KEY SHARE` conflicts with `FOR UPDATE`.
- **Evidence: the ordering.** The plan puts the new read where `:86-88` is now (`FixLocationAssignmentService.java:86-88`), before `unitloadService.createUnitload(...)` at `:91`, which inserts a unitload row.
- **Consequence.** With the mutant (plain SELECT, no FOR SHARE), create reads the **old** default, then blocks on the FK check at the unitload INSERT until the edit commits, then commits afterwards. "Second commits after first" still holds and AC-17 stays green. Meanwhile I-1 is broken: the FLA is tagged inherited with the stale triple, and the edit's step 5 found no FLA. The §7.3 row "`FOR SHARE` removed → AC-17" is therefore a false mutation-check claim, and §3.6's "the IT … proves the serialization" doesn't hold.
- **Fix.**
  - AC-17 must assert the **value**: after both commit, the FLA triple equals the edited default and `bounds_inherited = true`. Ordering alone isn't enough.
  - Add a second case where the edit commits first and create follows.
  - Re-run the mutant and record the red.
- **Confidence:** HIGH.
- **Realist check, High → Medium.** Mitigated by: §7.3 makes the executor apply this mutant by hand, so the survival would surface at the TDD gate rather than in production. Even if missed, production impact is one FLA mis-tagged, recoverable with "Use location default".

### M2. §3.6 lock facts are wrong or left open, and O-2 can already be answered
- **Callers don't hold the lock.** §3.6 says `create … callers typically already hold PESSIMISTIC_WRITE via transferUnitLoadToLocation(…, ignoreLock=false) (analysis §2.6)`. That's false for the flowbin arms I read:
  - `MobilePutAwayService:600` reads the Location unlocked (`findByName`) and the flowbin arm `:622-649` never calls `transferUnitLoadToLocation`; it calls `transferStockToUnitLoad`.
  - `MobileMoveUnitloadService:458` likewise uses `findByName`; the `FLOWBIN_STOCK` arm `:625-650` calls `transferStock(...)`, not a location lock.
  - `StockunitService:543` uses `findByName`, then `transferStockToUnitLoad` at `:575`.
  - Analysis §2.6 derived the claim from the `LocationRepository:29-32` javadoc, not from the five callers.
- **O-2 is answerable now.** O-2 has an answer: Hibernate emits `FOR UPDATE` (M1 evidence). *(Disputed — see top note; measured `FOR NO KEY UPDATE`.)*
- **The deadlock residual is mostly moot.** No flowbin caller upgrades share to update on the location, and concurrent creates meet on UNIQUE `assignedlocation_id`, as today.
- **Why it matters.** A T3 plan shouldn't hand its own concurrency verification to a reviewer. The wrong premise also understates how unlocked the create path really is, which is exactly what makes M1's mutant survivable.
- **Fix.**
  - Rewrite §3.6 from the five callers' actual lock sequence (one line each, with file:line).
  - Close O-2.
  - Drop the "callers typically hold" sentence.
- **Confidence:** HIGH for 3 of the 5 callers. I did not open the `MobileReplenishService:309/1109` arms.

### M3. The migration header states a falsehood that freezes into the Flyway checksum
- **Evidence.** §3.1 header: `WHY lock_timeout (FIRST migration in this repo to set it; V2.2.00's "SET lock_timeout = 0" is pg_dump preamble…)`. But `V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql:13` is `SET LOCAL lock_timeout = '5s';`, with a header (`:4-12`) giving the same rationale. The same false claim appears in D4's wording and in the ADR ("first migration with `lock_timeout` sets a precedent").
- **Why it matters.** The plan itself warns `THE NUMBERS IN THIS HEADER FREEZE ON FIRST APPLY`. A wrong fact in an immutable file misleads every future reader. It also hides that 10s departs from the existing 5s precedent without saying why.
- **Fix.**
  - Replace the sentence with "Same pattern as V2.2.40 (5s); 10s here because …", or align to 5s. D4 settles that a timeout is used, not that this repo has no precedent.
  - Fix the ADR consequence line.
- **Confidence:** HIGH.

### M4. The Storage Locations list columns would ship blank: `ViewDtoService.getLocationView` isn't in the change list and isn't tested
- **Evidence.**
  - §4 adds the 3 columns to `LocationRepository.getDetailView` / `LocationDetailView` (L5).
  - But `/v3/location/detailView` returns `dtoViewService.getLocationView()` (`LocationController:52`), which copies projection fields **by name** into a HashMap (`ViewDtoService:874-901`: `id, locationName, clientNumber, clientName, areaName, locationType, created, modified`).
  - §4 lists `ViewDtoService` only for "~:905 defaultSource + effective triple".
  - AC-14 tests `fixedAssignmentDetailView_*` and `LocationServiceUnitTest.locationDetails_includesDefaults` (that's L4, the details popup), not the L5 list.
- **Why it matters.** U4's three new list columns and the dialog's pre-fill would read `undefined`. No automated test would catch it; only M4/M5 by eye.
- **Fix.**
  - Add `ViewDtoService.getLocationView` (+3 `dto.put`) to §0.3 L5 and §4.
  - Add AC-14b `ViewDtoServiceUnitTest.locationView_includesDefaults`, mutation: drop one `put`.
- **Confidence:** HIGH.

### M5. The settled O-1 (clear on any location type, set only on flowbins) isn't propagated
- **Evidence.**
  - §3.3 step 3 says `requireFlowbin(...) (D6; also for clear — see O-1)`.
  - AC-16 says `non-flowbin location → BusinessException, nothing saved` (no set/clear split).
  - §3.7: the menu item is `shown only when the row's location type is flowbin`, and the Clear button exists only inside that dialog.
- **Why it matters.** As written, the executor implements the rejected option. A location retyped away from flowbin keeps stale defaults that no UI path can clear, and the create paths don't check type, so they would still seed from them.
- **Fix.**
  - Step 3: validate first; call `requireFlowbin` only when `l, m, u` are non-null.
  - Split AC-16 into `rejectsSetOnNonFlowbin` and `allowsClearOnNonFlowbin` (the latter also writes inherited FLAs back to sysprop).
  - UI: show a "Clear replenishment defaults" item on non-flowbin rows whose defaults are non-null, and add UI-3b.
  - Mutation: invert the null guard so it rejects clears too.
- **Confidence:** HIGH.

### M6. The rollback story ignores old-jar `adjust*`, and the O-4 drift check can't see the failure PM-2 describes
- **Evidence.** §8 runbook: `FLAs created by the old jar get bounds_inherited=false … re-tag them`. But an old jar after rollback also runs `adjust*` (`FixLocationAssignmentService:181-233`), which doesn't know the column. An operator edit on an **inherited** FLA leaves `bounds_inherited = true` with a hand-tuned triple. After roll-forward, the next defaults edit on that location overwrites the tuning. That is PM-2's failure, through an unlisted cause.
- **O-4's blind spots.**
  - It only checks the location tier. An inherited FLA drifted from the **sysprop** tier (location default null) is invisible.
  - After an overwrite, the row equals the default again, so O-4 reads 0. O-4 detects the precondition only on locations that already have a default, and never the loss itself.
- **Fix.**
  - Add to the rollback runbook, at roll-forward, per tenant: `UPDATE fix_location_assignment f SET bounds_inherited=false FROM location l WHERE l.id=f.assignedlocation_id AND f.bounds_inherited AND (f.lowerbound,f.middlebound,f.upperbound) IS DISTINCT FROM (COALESCE(l.default_lowerbound,:sl), COALESCE(l.default_middlebound,:sm), COALESCE(l.default_upperbound,:su))`. This is fail-safe, the same rule as the backfill.
  - Extend O-4 with the same COALESCE so it covers the sysprop tier.
  - Note in PM-2 that O-4 detects drift, not overwrites.
- **Confidence:** HIGH.
- **Realist check.** The trigger needs a rollback, which is rare. Kept at Medium because the outcome is silent loss of operator tuning (data loss isn't downgraded).

### M7. Alternatives aren't explored fairly: Option F's rejection rests on mapping the columns in the entity, and an unmapped-column variant isn't considered
- **Evidence.** §9 F is rejected because `Location has no @DynamicUpdate … so any concurrent full-row save overwrites the defaults with stale nulls`. That's true only if `Location` maps `default_*`. If the three columns stay unmapped (written by a native `UPDATE location SET default_*=… WHERE id=:id` under the same `findByIdForUpdate`, and read by the native `lockDefaultBoundsById` the plan already adds, plus the two native detail views), you get:
  - no full-row save can null them;
  - no `location.version` bump (D5's SBDEV-3418 exposure goes away);
  - no READ_ONLY / mass-assignment need and no cache serialization concern;
  - **if V2.2.45 fails on a tenant (55P03 or 42501), Location entity reads don't raise 42703.** This is the V2.2.40 design: "dispatch keeps working there, because OutboxMessage does not map the column". PM-1's blast radius shrinks from every Location read (putaway, picking, replenishment) to FLA reads.
- **Why it matters.** Principle 5 ("Entity and migration ship together") is chosen without weighing this. This sits within D1 (columns on `location`) and D5 (D5 accepts the bump, it doesn't require it).
- **Fix.** Add the unmapped variant as option G with an honest verdict. If the plan still rejects it, give the real reason.
- **Confidence:** MEDIUM.

### M8. The D-1 fold-in has no AC and no failing test
- **Evidence.** §10.5 D-1 says `fold into P1 (ViewDtoService is touched; replace with the parseSyspropLong-style fallback)`, which changes `ViewDtoService:708` (`new BigDecimal(syspropService.getSysvalue(...UPPER_BOUND_KEY))`). No AC in §7.2 covers it.
- **Why it matters.** The floor says one failing test first, mutation-checked, at every tier including folded T0s.
- **Fix.** Add AC-18 `ViewDtoServiceUnitTest.<method at :708>_absentUpperSysprop_fallsBackTo84` (today it throws an NPE, so it's red for the right reason). Mutation: restore the raw `new BigDecimal(...)`.
- **Confidence:** HIGH.

### M9. The completeness checklist isn't the skill's checklist
- **Evidence.** `wms-feature-plan/SKILL.md:262-282` requires these rows: all callsites, **adjacent shapes**, backward compatibility, concurrency, **multi-tenant**, **error handling**, DB verified, **observability**, rollout, test coverage, **cross-version v1↔v2**, alternatives. It also says "Empty rows block the plan". The plan's checklist has 11 rows of its own; adjacent shapes, multi-tenant, error handling, observability and cross-version are missing.
- **Fix.** Use the skill's rows, each marked ✓ §ref or "no — rationale". Cross-version is "N/A — v1 reference-only (no client since 2026-10-02)". Phase subsections also lack the skill's required *Risk level* and *Estimated effort*.
- **Confidence:** HIGH.

## Low findings
- **L1. The M0 query in §7.4 doesn't run.** It errors with `column "uid" does not exist` because the outer `select` lacks `from u`. Adding `from u` gives 44/44/0, which matches the plan. It also ignores the direct `mywms_user_mywms_role` path (0 rows on DEV; PRD unknown). Fix the SQL and either add the user→role path or state that the gate resolver doesn't use it.
- **L2. Prereq #5 and O-1 use `select max(version) from flyway_schema_history`.** That's a text max (`'2.2.5' > '2.2.45'`). Use `select success from flyway_schema_history where version='2.2.45'`.
- **L3. §3.5 states "per-replica Caffeine" as fact.** `CacheConfig.java:43-68` also has a `redis` profile, and `wms2-caching-strategy.md:288` says the profile in effect "is not derivable here". Under Redis, `@JsonProperty(READ_ONLY)` makes `GenericJackson2JsonRedisSerializer` **drop** `default_*` on read-back. No live harm today. Hedge the claim.
- **L4. PIT acceptance in step 4 can't be met as written.** `move()`'s new re-seed branch is tested only in the IT (AC-10), so its PIT mutants survive. Either add unit tests for the move re-seed or scope the PIT criterion.
- **L5. Manual-plan preconditions M4, M5, M7 and M8 are prose, not one SQL query.** Counts re-derived and match. M8 counts only destinations; `move()` also needs a source with exactly 1 UL and 1 SU and no in-process replen (`:139-160`). Write out the SQL, including the source side.
- **L6. Small citation and count slips.** R14 `FixLocationAssignmentRepository:198` → `:200`. §2.1 "6 singletons": DEV actually has 2×(1/1/6) plus 5 singletons.
- **L7. UI refusal handling is untested.** SBDEV-3560 pins that masterData write actions return `true`/`false` and that dialogs close only on success (`test/store/masterDataSaveResultSweep.spec.js`, `test/components/masterDataDialogRefusalSweep.spec.js`). Add UI-6.
- **L8. `LocationController` constructor change is unmentioned.** The new handler needs `FixLocationAssignmentService`; `LocationControllerUnitTest:38` constructs it directly. List it in §4.
- **L9. "Delete each new `@RequiresFunction`" doesn't apply to `resetBoundsToDefault`** (class-level gate); the mutant there is the loop row in `Sbdev3017TrancheGateContextTest`.
- **L10. "Location writers are only master-data paths" (§3.6 D5) has no stated blind spot.** Dirty-checked managed-entity writes aren't covered by the `locationRepository.save` grep.

## Over-engineering (Low)
- AC-2's garbage-sysprop fallbacks (`'abc'`, `' 36 '`) and the `{1,18}` regex — one fallback case (row absent) is enough.
- AC-3 `migration_isIdempotent` — Flyway never replays an applied script.
- AC-12's `boundsInherited` READ_ONLY half — no endpoint binds a `FixLocationAssignment` from JSON; vacuous.
- The 8 additive keys on `/fixedAssignment/detailView` — acceptable.
- Length: 723 lines for ~200 LOC; trim §0 rows ending in "— none".

## What's missing
- A `getLocationView` change and test (M4).
- AC-17 value assertion (M1); D-1 AC (M8); O-1 split AC (M5); UI refusal AC (L7).
- Roll-forward re-classification and sysprop-tier drift checking (M6).
- Behaviour when write-through hits an FLA whose replenishment order is in processing (state > PROCESSABLE): say "same as `adjust*`, accepted".
- PRD measurement still open (MCP down); prereqs #5 and #7 correctly gated on it.

## Ambiguity risks
- `"(D6; also for clear — see O-1)"` — A: reject clear on non-flowbins (as written); B: allow it (as settled).
- `"callers typically already hold PESSIMISTIC_WRITE"` — B (the lock is the only serialization) is what's true (M2).
- `"enabled only when Overridden"` — label when the reset target is the system triple; consider "Use default (system)".

## Pre-mortem and expanded test plan quality
- PM-1: adequate; M7 would shrink the blast radius.
- PM-2: **weak** (O-4 blind; rollback cause missing — M6).
- PM-3: adequate.
- Expanded test plan: all 4 layers present; gaps M4, M8, L7.

## Manual test plan: DEV re-run (q.sh, 2026-11-01)
| Row | Plan | Mine |
|---|---|---|
| §2.1 total / 36-60-84 / other / active | 1344 / 1307 / 37 / all | **1344 / 1307 / 37 / 1344** |
| sysprops | 36/60/84 @ client 0, DEFAULT | **same** |
| flyway head | 2.2.44 (rank 45) | **2.2.44, 45 rows** |
| location count | 2,750 | **2750** |
| M0 | 44/44/0 | **query errors as written**; with `from u`: **44/44/0** |
| M4 | 00-A01/03/05 | **✓** |
| M5 | 22-A01, 25-A06, 25-C01, 25-C04, 26-A02 | **✓** |
| M7 | 62 | **✓** |
| M8 | 723 | **✓** |
| non-flowbin FLAs | 0 | **✓** |
| 53-B06 | id 3223189, flowbin, no FLA | **✓** |

## Citation spot-check (~30 checked)
All correct except R14 `:198` (actually `:200`) and the V2.2.45 header's "FIRST migration" claim (M3). Full list in the lane's returned text: FixLocationAssignmentService ranges, LocationController, FunctionGuardInterceptor (0 LocationController), LocationService, LocationRepository, RestConfiguration, SyspropRepository:30, WmsConstants:969,1361, ViewDtoService, MobileReplenishService, FixLocationAssignmentRepository, ReplenishorderRepository, ReplenishmentMonitorViewRepository, ReplenishOrderJobService, ReplenishmentOrderMaintenanceService, ReplenishGeneratorService, ReplenishOrderJob:759, ReplenishmentMaintenanceTrigger, StartupFlywayMigrator:53, FixLocationAssignmentController:22-24, Sbdev3017TrancheGateContextTest, BillofladingTransferIdNotNullIT, the 13 cited test classes, the 5 W1c callers' transactions, and the UI rows.

## Flyway, prerequisites, rollback and ticket policy
- Collision check verified (pre-commitment table).
- Rollback: "old jar is safe" holds (`StartupFlywayMigrator:38-40` default `ignoreMigrationPatterns = *:future`; new columns nullable/defaulted); incomplete on data semantics (M6).
- Ticket policy: D-1/D-5 folded correctly (D-1 needs a test, M8); D-2/3/4/6 as comments correct; D-7 in docs step fine; capacity cap proposed not filed — correct.

## Multi-perspective notes
- Executor: stuck on O-1 (M5), PIT criterion (L4), blank list columns (M4).
- Stakeholder: WineCo's need (53-B06 = 48) is met; cap properly a proposal.
- Skeptic: strongest argument is M7.

## What's solid (verified)
Writer enumeration complete; backfill mirrors `getSysvalue`/`SyspropRepository:30` exactly; gating correctly method-level on non-GUARDED `LocationController`; deploy order and per-tenant checks right; no verify script is correct.

## Verdict justification
**ITERATE.** Upgrading needs: (1) AC-17 asserts the value; (2) §3.6 re-derived from the five callers, O-2 closed; (3) header/ADR "first lock_timeout" corrected; (4) `getLocationView` wired and tested; (5) O-1 propagated; (6) roll-forward re-classification + sysprop-tier O-4; (7) option G weighed; (8) D-1 AC; (9) skill checklist rows.

## Open questions (unscored)
- Do the `MobileReplenishService` create arms (`:309`, `:1109`) lock the location before or after create? (Architect: after.)
- Which `SPRING_PROFILES_ACTIVE` do UAT and PRD run (Caffeine or Redis)?
- Does `FixLocationAssignmentServiceIT` already have a two-connection harness?

## Ralplan summary row
- Principle/Option consistency: pass with reservation (Principle 5 vs unmapped variant, M7).
- Alternatives depth: fail (M7).
- Risk/verification rigor: fail (M1, M2, M6).
- Deliberate additions: partial (PM-2 weak; gaps M4, M8, L7).
