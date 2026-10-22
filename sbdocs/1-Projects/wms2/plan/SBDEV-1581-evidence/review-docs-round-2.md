---
ticket: SBDEV-1581
kind: review
lane: scoped check of 9978e69c (L-3/L-4), catalog L-1/L-2 edits, merge d95824a0
date: 2026-10-19
verdict: APPROVE (Lows only)
---

# SBDEV-1581 review, docs round 2

Read-only, no mvn. Worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1581`, HEAD `9978e69c`, working tree clean. Catalog: `/home/nampark/dev/wms-claude/sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md`, diffed against the scratchpad `catalog.bak`.

Counts: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 5.

## 1. Commit 9978e69c

- `git diff --stat`: 2 files, +5/-2. Both files are comment or javadoc only (`EmptyPalletCleanupJob.java` +2 comment lines, `EmptyPalletCleanupJobService.java` javadoc rewrap). No statement, literal or condition touched. Confirmed no code change.
- L-3 comment ("failed is always 0 on this branch ... both ERROR lines share one format"): accurate. The `else` is reached only when the guard holds and `result.failed() > 0` is false, so `failed == 0` there. The format string and args are unchanged.
- L-4: the long line is rewrapped (all lines now about 110 chars or less) and the pin is qualified as `EmptyPalletCleanupJobUnitTest.singleRefusedCandidateIsAllRefused`, matching the job javadoc and catalog wording. The test exists: `src/test/java/net/aim_ai/wms/schedulejob/EmptyPalletCleanupJobUnitTest.java:415`. The sentence still reads correctly across the new wrap, including the `ignoreLock = true` parenthetical.
- Commit message says L-5 left as advised and L-1/L-2 catalog-only: consistent with the report.

## 2. Merge d95824a0

`git show --remerge-diff d95824a0` and `git show --cc d95824a0` both print only the commit header and no hunks. So git's automatic merge was never altered: no conflict hunks, no manual resolution, nothing added in the merge commit beyond the auto-merge. Parents `ca5e4dea` and `f0d3c8b5`.

## 3. Catalog edits (L-1, L-2)

Verified OK:
- Line 39 (§1): "Seven as of SBDEV-1581 ... six before it" replaced by "count that list, not this bullet; SBDEV-1581 added `EmptyPalletCleanupJob` to it" plus marker. Sentence still parses. The enumerated names (seven) are an enumeration, not a stated total.
- Line 48 (§1): "(seven since SBDEV-1581)" dropped; sentence intact.
- Line 183 (§4): "and are **seven** since SBDEV-1581" became "SBDEV-1581 has since added one"; sentence intact and true.
- `verified_by` clause: states branch, UNMERGED, the sections read, and keeps the SBDEV-3672 clause. `last_verified` is unchanged, consistent with the SBDEV-3672 precedent.
- 2026-10-19 changelog row: sits directly above 2026-10-18 and below the leading 2026-09-06 (3rd pass) row, matching the section's existing order (newest first after that row). Its content matches the diff and the verified 4.6a text. The test name is qualified correctly.
- Markers: form `⏳ pending-merge(SBDEV-1581)` placed trailing, before the closing pipe or period, identical to the SBDEV-3672 markers at lines 426, 427 and 620. No new false claims found in the added text.

## Issues

### [LOW] L-1: fixed totals remain elsewhere, two of them in §4 and now false
File: catalog line 244 (§4), line 165 (§3.3), line 519 (§7.8)
Confidence: HIGH
Issue: L-1 asked for the totals to go from §1/§4. Line 244 ("The lock is per `(job, tenant)` for four of the six jobs") is in §4 and is stale now that a seventh two-key job exists (it would be five of seven). Line 165 ("configures **all six** business cron jobs") is false today. Line 519 ("Five of the six jobs are grouped") sits in §7.8 describing the D' change and is arguably a dated statement, but it reads as current.
Fix: restate as rules ("for every `SchedulingConfiguration` job except `CleanUpOldMessagesJob` and `StockSummaryExportJob`"; "configures every job in `CONFIGURED_JOB_NAMES`"; "every job except `releaseExpiredPickingOrdersFromUser`" or add "at SBDEV-3198"). Line 244's 4-of-6 is worth checking against `EmptyPalletCleanupJob`'s lock shape, since that job is two-key per `(job, tenant)` and is not one of the exceptions.

### [LOW] L-2: new 10-19 changelog row undercounts its own markers
File: catalog line 618
Confidence: HIGH
Issue: the row says markers were added to "the §2 row, §4.6a and §6 row". There are four sites: also the §1 bullet (line 39). The SBDEV-3672 row says "New text marked", which is the pattern to follow.
Fix: add "§1 bullet" to the list.

### [LOW] L-3: `verified_by` says "every §4.6a fact" was checked
File: catalog line 11
Confidence: MEDIUM
Issue: the prior review explicitly did not re-check the dated measurements in 4.6a ("rows are not in the base dump", "0 overlap on WineCo/c1wh PRD 2026-10-18", "72 candidates measured"). "Every" overstates it, and this doc's own history is a list of exactly that kind of overclaim.
Fix: "every code-derived §4.6a fact; the dated PRD measurements were not re-queried".

### [LOW] L-4: markers are coarse in §4.6a, and `updated:` not bumped
File: catalog line 377 and frontmatter line 8
Confidence: LOW
Issue: the heading carries one marker for the whole section, whereas the 3672 markers are per sentence. For a whole new section this is reasonable and consistent with the SBDEV-1581 section being new in its entirety. `updated: 2026-10-16` was not moved to 2026-10-19 although the file changed.
Fix: optional; bump `updated`.

### [LOW] L-5: wms-merge flip step needs to find all four markers
File: catalog lines 39, 115, 377, 476
Confidence: LOW
Issue: not a defect. The marker count (four) differs from the changelog's three, so whoever flips them at merge should grep `pending-merge(SBDEV-1581)` rather than trust the changelog row (see L-2).
Fix: none beyond L-2.

## Open Questions

None.

## Positive observations
- The commit is strictly comments and the new comment states a true invariant tied to the guard above it.
- The merge was a clean auto-merge with an empty remerge-diff.
- The totals removal kept every sentence grammatical and kept dated history rows intact rather than rewriting them.
- Marker form and placement follow the SBDEV-3672 convention exactly.

## Recommendation
APPROVE. L-1 (lines 244 and 165) is the one worth fixing in the same pass; line 165 is a false claim the feature created.
