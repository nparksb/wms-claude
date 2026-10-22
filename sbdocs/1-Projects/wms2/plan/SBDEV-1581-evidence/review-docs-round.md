---
ticket: SBDEV-1581
kind: review
lane: scoped check of ca5e4dea (docs round) + catalog SBDEV-1581 parts
date: 2026-10-19
verdict: APPROVE (Lows only)
---

# SBDEV-1581 review of ca5e4dea and the scheduled-jobs catalog

Read-only, no mvn. Worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1581` at HEAD `d95824a0`. Evidence: `git show ca5e4dea`, review-final-2.md, implementation-report.md "Docs round", the code at HEAD, catalog `/home/nampark/dev/wms-claude/sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md`.

Counts: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 5.

## 1. review-final-2 findings, as claimed

| Finding | Claimed | Verified |
|---|---|---|
| M-1 (document single-candidate refusal) | Result javadoc, runFor rule javadoc, code comment, catalog 4.6a | Yes, all four. `EmptyPalletCleanupJobService` Result javadoc, `EmptyPalletCleanupJob` rule `<li>` and the comment above the `if`, catalog line 389 ("Deliberately including a run with **one** candidate"). `singleRefusedCandidateIsAllRefused` exists (`EmptyPalletCleanupJobUnitTest.java:415`). The decision (keep) is stated, not just the fact. |
| L-1 ("newest" wording) | replaced with dated/positional | Yes in all 5 sites of the diff (SchedulingConfiguration x2, both test constants, both fixture comments, one `.as(...)`). `grep -i newest` over `schedulejob/`, `service/job/` and the scheduling tests finds only `PendingReversalReconciliationJob` lines about row age, which are unrelated. |
| L-2 (rename) | `...AsAllOfThem` | Yes (`SchedulingConfigurationUnitTest.java:982` region). No `AllSeven` left under `schedulejob` tests. I did not grep the whole tree, so the report's claim about `ItemDataControllerUnitTest` is unverified by me but plausible. |
| L-3 (one ERROR format; soften "likely") | shared format; "one possible cause" | Yes. "likely a location constraint" is now "one possible cause is a location constraint". |
| L-4 (derive SEED_VERSION) | derived from SEED_FILE | Yes, see section 2. |

## 2. Non-comment changes

- **ERROR format, both branches.** Placeholder count equals argument count in both (6 and 6; JOB_NAME, tenant, facility, candidates, failed, refused). Argument order matches the placeholder order (the old UnexpectedFailures call had `failed` before `candidates`; the new one is reordered consistently). The condition, the `jobMetrics.tenantFailure(...)` reason tags and `anyFailure = true` are untouched. Behaviour change: log text only.
- **`EmptyPalletCleanupJobService`.** Javadoc only. `cleanupEmptyPallets()` body is untouched in the diff.
- **`SchedulingConfiguration`.** Comments only.
- **SEED_VERSION.** `SEED_FILE = "/db/migration/V2.2.41__seed_empty_pallet_cleanup_sysprops.sql"`. `lastIndexOf("/V") + 2` lands on `2.2.41__seed...`, `indexOf("__")` is the first double underscore in the whole path (after `41`; the directory and the descriptive part use single underscores only), so the substring is `2.2.41`; `.replace('_','.')` is a no-op here and would correctly handle a `V2_2_41` style name. Result equals the old literal, so `MigrationVersion.fromVersion` yields the identical version and the absence check at line ~101 (`v.compareTo(SEED_VERSION) < 0`, max of those) still targets the highest migration below V2.2.41. `SEED_FILE` is a compile-time constant declared before use, so no init-order hazard. The migration file exists at `src/main/resources/db/migration/V2.2.41__seed_empty_pallet_cleanup_sysprops.sql`. Correct.
- **Test rename.** Method name only; `@DisplayName` was already count-free.

No behaviour changes beyond log wording. Confirmed.

## 3. Catalog (SBDEV-1581 parts) against code at HEAD

Verified exact: lock id `EMPTY_PALLET_CLEANUP = 100011L` (`AdvisoryLockService.java:285`), two-key `tryLock(..., tenantId)` and `unlock` in `runFor`; the 100001L to 100011L table rows and `tryLock :182` / `unlock :221`; sysprop keys and defaults (`ACTIVATED` false, `TIMER_HOUR` 3, `TIMER_MINUTE` 15, `WmsConstants:1541-1546`) and V2.2.41 seeding them with `WHERE NOT EXISTS` on `workstation='DEFAULT'`; cron `"0 " + minutes + " " + hours + " * * *"` in the warehouse zone; activation requires `NEW_CRON_JOB_ACTIVATED` and `EMPTY_PALLET_CLEANUP_ACTIVATED`; WARN on the boot pass only (`!reconciling`) and DEBUG on reconcile; batch size 500 (`MAX_CANDIDATES_PER_RUN`); candidate predicates and the `md5(u.id::text || current_date::text), u.id` ordering with `LIMIT :batchSize` (`UnitloadRepository.java`); the six outcome buckets; per-pallet `lockIdForUpdateSkipLocked` then re-check then `relocateEmptiedContainer(..., CODE_CONTAINER_RELOCATED_EMPTYPOOL, null, comment)`; the tenant-failure rule `candidates > 0 && moved == 0 && (failed > 0 || refused == candidates)` with reason order; "called last in the D' block, before the single-trigger read" (`SchedulingConfiguration.java:704` then `onlyIfMissing`); `CONFIGURED_JOB_NAMES` has seven entries including `EmptyPalletCleanupJob.JOB_NAME`; "next free is 100012L" (highest constant is 100011L).

Not checkable from this tree: "the rows are not in the base dump", "0 overlap on WineCo/c1wh PRD 2026-10-18", "72 candidates measured". Those are dated measurements; I did not re-query.

## Issues

### [LOW] L-1: section 1 states "no total" and then states totals
File: catalog line 37 vs 39, 48, 183: "this doc deliberately states no total" / "**Seven** as of SBDEV-1581 (2026-10-18; six before it)" / "(seven since SBDEV-1581)" / "there were **six** ... and are **seven** since SBDEV-1581"
Confidence: MEDIUM
Issue: the paragraph that says every total has gone stale then adds three new totals. Each is dated and points at the list, so none is false today, but the next job makes lines 39, 48 and 183 stale in exactly the way line 37 warns about. This is the closed-set pattern, not a false claim.
Fix: keep the date and the pointer, drop the number ("the jobs in `CONFIGURED_JOB_NAMES`; SBDEV-1581 added `EmptyPalletCleanupJob`"). Same for the code comment at `SchedulingConfiguration.java:145` ("Before SBDEV-3198 all seven ...", dated, acceptable) and `PendingReversalReconciliationJob.java:73` ("seven since SBDEV-1581", dated, acceptable).

### [LOW] L-2: changelog and verified_by not updated for the 10-19 text
File: catalog line 618 ("| 2026-10-18 | SBDEV-1581 (branch ... unmerged at writing): ... new §4.6a ...") and frontmatter `verified_by` (line 11, names SBDEV-3672 only)
Confidence: MEDIUM
Issue: the single-candidate statement added to 4.6a after 10-18 is covered by no changelog row, and `verified_by` does not mention SBDEV-1581 at all although this lane read the branch source.
Fix: add "2026-10-19 final-review-2: 4.6a notes the one-candidate refusal" to the 10-18 row or a new row, and one clause to `verified_by` naming the sections read and that the branch is unmerged. Also the new text carries no `pending-merge(SBDEV-1581)` marker, unlike the 3672 rows; given the repo's marker convention, the 4.6a section and the §2 rows describe unmerged code as fact. The 10-18 row says "unmerged at writing", which partly covers it.

### [LOW] L-3: AllRefused ERROR prints a constant "0 failed unexpectedly"
File: `EmptyPalletCleanupJob.java`: `"... ({} candidates, {} failed unexpectedly, " + "{} refused — every candidate refused; one possible cause ..."`
Confidence: HIGH
Issue: in this branch `failed == 0` by construction, so the line always reads "0 failed unexpectedly". Harmless and it delivers the shared format L-3 asked for, but the operator reads a bucket that cannot be non-zero. Neither ERROR line is asserted by a test (same as before).
Fix: optional. Keep, or note in a comment that the format is shared on purpose.

### [LOW] L-4: new javadoc line is a long unwrapped line
File: `EmptyPalletCleanupJobService.java`: `{@code EmptyPalletCleanupJob#runFor}; pinned by {@code singleRefusedCandidateIsAllRefused}). (A locked destination cannot occur here: the move`
Confidence: HIGH
Issue: the edit joined the old tail onto the new text and produced a line of about 150 characters, with the following line left short. Cosmetic. Also `singleRefusedCandidateIsAllRefused` is named without its class here, while the job javadoc and the catalog qualify it as `EmptyPalletCleanupJobUnitTest.singleRefusedCandidateIsAllRefused`.
Fix: re-wrap; qualify the name.

### [LOW] L-5: the single-candidate rule is documented, but the Result javadoc still opens "those clear on their own"
File: `EmptyPalletCleanupJobService.java`: `Race-driven ones come from a concurrent commit ... those clear on their own. ⚠ The job cannot tell the two kinds apart`
Confidence: LOW
Issue: reads correctly in order, with the warning immediately after. The only residual is that a reader skimming the first half takes "clear on their own" as "no tenant failure". The catalog 4.6a Metrics row has the same shape ("benign race noise" followed later by the one-candidate warning). Not wrong.
Fix: optional; none needed.

## Open Questions

None. (M-1 from review-final-2 was a decision, and the decision was recorded; I did not reopen it.)

## Positive observations
- The M-1 decision is stated in four places with the same wording and pinned by a named test, which is the failure the previous review raised.
- SEED_VERSION derivation is correct and fail-loud (a missing resource still fails test 2; the derived bound cannot silently go stale).
- The log reformat kept placeholder and argument counts aligned and touched no metric, flag or condition.
- The catalog's 4.6a facts all trace to code; the tenant-failure rule is stated as a predicate, not prose.

## Recommendation
APPROVE. The L-1 and L-2 doc items are worth doing in the same pass as the next docs touch; none block.
