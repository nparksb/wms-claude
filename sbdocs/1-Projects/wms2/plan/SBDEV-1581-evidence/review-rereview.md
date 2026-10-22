---
ticket: SBDEV-1581
kind: review
lane: re-review of review-fix commits
scope: git diff 60c782c2..HEAD (a0c1d77c, 7d9d1e24, d7c34e17), worktree .claude/worktrees/wms2-api/SBDEV-1581
date: 2026-10-18
verdict: COMMENT
---

# SBDEV-1581 — re-review of the review-fix round

Read-only. mvn was not run. Evidence: source reads of the diff and surrounding code, `git ls-tree` across `refs/remotes/origin`, and one plain `EXPLAIN` (estimates only, no ANALYZE) on c1wh-shipitez PRD.

**Counts:** CRITICAL 0 · HIGH 0 · MEDIUM 2 · LOW 7 · Open questions 1

## Stage 1: was each finding fixed?

| Finding | Status | Basis |
|---|---|---|
| A M-1 (no test sees `@Transactional`) | **Fixed, plausibly** | `RelocateEmptyStoragePalletIT` autowires `UnitloadBusinessService`, so calls go through the proxy. The class is `NOT_SUPPORTED`, the fixture is committed via `JdbcTemplate`, and the class is registered in `EXEMPT_NON_TRANSACTIONAL`. Without the annotation, the self-invoked `relocateEmptiedContainer` gets no proxy either, so each repository save commits by itself. That means test (c) goes red, which matches mutant R1. See L-2, L-3 and L-4 for weaknesses. |
| A M-2 (failures invisible, all-failed advances last_success) | Fixed, but with a semantic regression | See M-2 below. `items{tenant,outcome}` is correct, and `JobMetricsUnitTest` checks n-increment per tag. |
| A L-1 (concurrent stock/child counted as failed) | Fixed | `disqualification` now probes `findByUnitloadId` and `findByCarrierunitloadId` under the lock. Covered by unit tests and IT (d). |
| A L-2 (literal-key `never()`) | Fixed | `verifyNoInteractions(advisoryLockService)`; `times(1).tryLock(anyLong(), anyLong())` plus the positive literal plus `never().tryLock(anyLong())`. Ledger entry added with its reason. |
| A L-3 (cap starvation) | Fixed | `ORDER BY md5(u.id::text \|\| current_date::text), u.id`. Correctness, volatility and performance are checked below. No "lowest-id-first" or "ascending" claim is left about this query (grep of `src/`). Javadoc, catalog §4.6a and the IT DisplayName are all updated. |
| A L-4 (nested pallet) | Fixed | `AND u.carrierunitload_id IS NULL` plus a `disqualification` refusal. The IT has a positive control. |
| A L-7 / B L-3 (census) | Fixed, re-derived | Non-comment `FOR UPDATE` in `repo/`: `OutboxMessageRepository.java:55`, `StockunitRepository.java:318`, `UnitloadRepository.java:476`, so 3. No non-comment `FOR UPDATE` string outside `repo/`. `grep "2 native"` gives 0. |
| B L-1 (ERROR every 5 min) | Fixed | `!reconciling` gate, WARN. No new shared state (see L-5). |
| B L-2 (stale counts) | Mostly fixed | One closed count is left: see L-6. |
| B L-4 (int4 rail) | Fixed, not vacuous | Reflective walk with a positive control (`containsKeys("ORDER_RELEASE","STALE_CLUB_BATCH_CLEANUP","EMPTY_PALLET_CLEANUP")` and `hasSizeGreaterThanOrEqualTo(11)`), and mutant R7 is red. Note: a constant changed to `int` would drop out of the `long.class` filter silently, but the `containsKeys` guard covers the important one. |
| B L-5 (reconcile pin) | Fixed | `emptyPalletDerivations` counter. |
| B L-6 (no IT runs V2.2.41) | Fixed, but fragile | Real Flyway run over `classpath:db/migration`, then a re-exec of the resource file. See M-1. |
| B L-7 (description) | Fixed | |

### L-3 order: correctness, determinism, volatility and performance
- `md5(text)` is IMMUTABLE and `current_date` is STABLE, so it is legal in ORDER BY and stays fixed within a statement and a transaction (`transaction_timestamp`). The production read is one statement per tenant run, so the order is deterministic within a run. The day boundary follows the DB session's TimeZone, not the warehouse zone. One run a day makes that irrelevant.
- Anti-starvation holds in the probabilistic sense the javadoc claims ("no fixed set can hold the cap night after night"). A re-run on the same day (manual run, or a timer edit that fires twice) repeats the same order. That is acceptable.
- **Performance, measured:** plain EXPLAIN on c1wh-shipitez PRD gives `Limit → Sort (cost 769.68..769.73, rows 21)` over bitmap scans of `unitload` (BitmapAnd, 377 est.), with nested-loop index probes for location, area, stockunit and the child. md5 is computed only for the ~21 filtered rows. While fewer than 500 rows qualify, the old `ORDER BY u.id LIMIT` could not stop early either, so this is not a regression. **This closes the implementer's open item "EXPLAIN on c1wh before activation".**

## Issues

### [MEDIUM] M-1 — Seed IT goes red once SBDEV-3672's V2.2.40 merges
File: `src/test/java/net/aim_ai/wms/integration/schema/EmptyPalletCleanupSeedMigrationIT.java` (`PRE_SEED_WATERMARK = "2.2.39"`, `seedsTheThreeRows`)
Confidence: HIGH
Issue: `origin/fix/SBDEV-3672-chunk-bol-shipped` adds `V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql`, which runs `INSERT INTO public.los_sysprop` (lines 42–52). After either merge order, `migrateTo(url, "2.2.41")` from the 2.2.39 watermark also applies V2.2.40, so `count(*) from los_sysprop` becomes `before + 4` and `.as("exactly three rows added").isEqualTo(before + 3)` fails. Develop will go red, and the deploy is gated on tests. The 3672 lanes are active in this same session.
Fix: count only the rows this file owns (`where syskey in (<DEFAULTS keys>)`: 0 before, 3 after), or derive the watermark as the highest classpath migration below 2.2.41. Separately, the merge coordinator should note that V2.2.40 and V2.2.41 come from two branches: whichever merges second applies out of order on dev (the Flyway-collision preflight in `wms-merge`).

### [MEDIUM] M-2 — `AllMovesFailed` turns one poison pallet into a permanent job failure, and the wording overstates the condition
File: `src/main/java/net/aim_ai/wms/schedulejob/EmptyPalletCleanupJob.java` (`if (result.failed() > 0 && result.moved() == 0)`)
Confidence: MEDIUM
Issue:
- (a) Failure scenario: the L-3 javadoc names the poison case itself ("a constraint on EmptyPallets' location type"). Say a tenant has one Cart that `transferUnitLoadToLocation` always rejects with `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION`, and no other empty pallet appears that night. Then every night is `candidates=1, failed=1, moved=0`, so the run is charged `failure{AllMovesFailed}`. `anyFailure` is fire-wide, so `last_success` stops advancing for the **whole group fire**, including every other tenant that shares the spec, until a human fixes that pallet. A staleness alert on `last_success` would then say "the job is broken" for an issue with one row.
- (b) The condition is "nothing moved and at least one failed", not "every candidate failed". With 499 `skipped_state` and 1 `failed`, the ERROR reads "every candidate move failed … (1 of 500)", and the javadoc bullet says "a run in which every candidate failed". Both are false for that case.
- (c) Vocabulary: every other `failure{reason}` value is an exception simple name. `AllMovesFailed` is the first synthetic reason. Dashboards that group by exception class will show it as an unknown class. This is minor and is documented as "this job only".
Fix: decide which semantics you want and state them accurately. Options:
- Classify deterministic `BusinessException` refusals (constraint, "has stock"/"is carrier" backstop) as their own `items{outcome=refused}` bucket that does not count toward `AllMovesFailed`, and keep `failed` for unexpected exceptions.
- Or gate on `failed == candidates`.
- At minimum, reword the log and javadoc to "no move succeeded and N failed", and record in catalog §4.6a that one poison pallet withholds `last_success` for the group.

### [LOW] L-1 — `runFor`'s javadoc is orphaned
File: `EmptyPalletCleanupJob.java`, around `:123–176`
Confidence: HIGH
Issue: `recordItems` (with its own `/** Review M-2 … */`) was inserted between the big `runFor` javadoc and `public void runFor`. Two consecutive doc comments mean the first one attaches to nothing. `runFor` now carries no javadoc, and the metrics contract (including the new M-2 bullet) is invisible to IDE and javadoc.
Fix: move `recordItems` below `runFor`, or above the big javadoc.

### [LOW] L-2 — IT (c) accepts any exception
File: `RelocateEmptyStoragePalletIT.aFailureMidMoveLeavesNothingBehind` (`assertThatThrownBy(...).as(...).isNotNull()`)
Confidence: HIGH
Issue: an exception thrown before the move is issued (fixture drift, a missing EmptyPallets row, a constraint) also leaves the pallet on RACK with no audit row, so the green run does not prove the trigger fired. Mutant R1 proves the path reaches the write when the code is mutated, but nothing proves it on the unmutated run.
Fix: `.hasRootCauseMessage(...)` or `.rootCause().hasMessageContaining("forced unitload_record failure")`.

### [LOW] L-3 — IT javadoc's mechanism claim may be false in the passing case
File: `RelocateEmptyStoragePalletIT` class javadoc ("a trigger makes the `unitload_record` insert fail AFTER the unit-load update was issued")
Confidence: LOW
Issue: inside one transaction, Hibernate's ActionQueue flushes INSERTs before UPDATEs. Unless something auto-flushes in between, the UPDATE may never reach the server before the trigger raises. The test still catches the no-transaction mutant (each save commits in order), so only the prose is in question.
Fix: say "the pallet's update and the audit insert commit or roll back together; without a transaction the update has already committed on its own".

### [LOW] L-4 — IT javadoc implies coverage of mutants that were not run
File: `RelocateEmptyStoragePalletIT` javadoc ("Neither could see the annotation deleted, re-pointed at the landlord manager, or set to `NOT_SUPPORTED`")
Confidence: MEDIUM
Issue: only deletion (R1) was mutation-checked. The other two very likely turn red by the same mechanism, but the claim is unproven.
Fix: run both mutants once, or narrow the sentence.

### [LOW] L-5 — "Once per boot" never names a tenant onboarded after boot
File: `SchedulingConfiguration.configureEmptyPalletCleanupGroups` (`if (!noSchedule.isEmpty() && !reconciling)`)
Confidence: HIGH
Issue: the gate is the `reconciling` parameter, not shared state, so there is no thread-safety concern, and the gate covers all tenants in the boot pass. Boot ordering is sound: `onApplicationReady` (`ApplicationReadyEvent`) runs after the `StartupFlywayMigrator` ApplicationRunner, so a first deploy with V2.2.41 does not false-alarm every tenant. The gap: a tenant first seen by a 5-minute reconcile (onboarded after boot) that lacks the rows is never named at any level. Catalog §4.6a's "named once per boot" is accurate but doesn't call this out.
Fix: track the reported tenant keys in a `Set` (for example `ConcurrentHashMap.newKeySet()`) and WARN when a key is new, or document the gap.

### [LOW] L-6 — One closed count survived the B-L2 sweep
File: `SchedulingConfiguration.java:703` ("SBDEV-1581: the sixth grouped job")
Confidence: HIGH
Issue: this is true today (`:698–705`, six `configure*Groups` calls), but it is the kind of count B-L2 restated as a rule elsewhere. It goes stale with the next grouped job.
Fix: "the newest grouped job".

### [LOW] L-7 — Catalog prose nits
File: `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md`
Confidence: HIGH
Issue:
- `:49`: "five grouped at SBDEV-3198, six since SBDEV-1581 — — a grouped job" has a doubled dash.
- `:37` still chains counts ("said **ten** … SBDEV-1581 adds an eleventh … and `PendingReversalReconciliationJob` … is not in the bullets either"), so the reader has to work out 12. It is disclaimed ("do not trust a number here"), but it contradicts the rule-not-count style used two lines later.

Every other SBDEV-1581 claim in the catalog matched the code:
- the seven `CONFIGURED_JOB_NAMES`
- the six grouped jobs
- called last in the D′ block, before `onlyIfMissing(releaseExpiredPickingOrdersFromUser)`
- `100011L` two-key
- cap 500 (`MAX_CANDIDATES_PER_RUN`)
- the md5 order
- `carrierunitload_id IS NULL`
- the SKIPPED_STATE emptiness re-check
- `items{…}` / `AllMovesFailed`
- `RelocateEmptyStoragePalletIT` named as the proxy pin

Fix: remove the doubled dash, and reduce `:37` to the rule.

## Open questions (low confidence, not blocking)
- [MEDIUM] Is M-2(a) the intended alarm semantics? An operator might want one stuck pallet to page every night. If so, close M-2 with a catalog sentence instead of a code change. That is a product call.

## Positive observations
- The red-before list and mutants R1–R7, with sha1 restore, are proper evidence. The int4 rail's positive control turns a drifting hand list into a derived one.
- L-1 and L-4 were fixed at both layers: the selection predicate, and the re-check under the lock with `relocateEmptiedContainer` kept as a backstop.
- The census header now states its derivation, and the sibling comments point to it instead of restating a number (prose-enumerations-rot, applied).
- The B-L1 justification (base dump vs a V2.2.41-only seed) is a real, documented difference from the sibling. It is not a silent fork.

## Recommendation
**COMMENT.** No CRITICAL or HIGH at HIGH confidence. Fix M-1 before either V2.2.40 or V2.2.41 reaches develop: it will turn develop red, and develop gates the deploy. Decide M-2's semantics, or reword it. Per the project rule, fix the Lows in the same pass.
