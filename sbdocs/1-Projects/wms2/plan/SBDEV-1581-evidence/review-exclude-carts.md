---
title: "SBDEV-1581 — independent review: exclude Carts from EmptyPalletCleanupJob"
type: review
ticket: SBDEV-1581
date: 2026-10-19
reviewer: code-reviewer lane (read-only)
subject: "wms2-api worktree .claude/worktrees/wms2-api/SBDEV-1581-carts, branch fix/SBDEV-1581-exclude-carts, git diff origin/develop(f862e814)...HEAD — aaa71da3, 5457d940"
verdict: APPROVE
---

# Review — SBDEV-1581 "exclude Carts"

**Verdict: APPROVE.** 0 CRITICAL · 0 HIGH · 0 MEDIUM · 7 LOW (+1 info). No finding blocks.

Scope read: the 7-file diff, plus the unchanged job path (`EmptyPalletCleanupJob`, `EmptyPalletCleanupJobService`,
`UnitloadRepository.findEmptyStoragePalletIds`, `UnitloadBusinessService.relocateEmptyStoragePallet` /
`disqualification` / `relocateEmptiedContainer`, `JobMetrics*`, V2.2.41), the three ITs, and catalog §4.6a/§6/changelog.
`mvn` NOT run (a full suite was running in the worktree, as instructed); compile risk judged by reading: the three new
test imports (`ArgumentCaptor`, `Collection`, `anyInt`) are all used, `lenient` was already imported.

## Stage 1 — spec compliance: PASS

| Requirement | Where | Status |
|---|---|---|
| Selection excludes Carts | `EmptyPalletCleanupJobService.java`: `private static final Set<String> CONTAINER_TYPES = Set.of(WmsConstants.UNIT_LOAD_TYPE_PALLET);` | ✔ |
| Re-check under lock refuses Cart → SKIPPED_STATE, not a throw | `UnitloadBusinessService.disqualification`: `if (!WmsConstants.UNIT_LOAD_TYPE_PALLET.equals(typeName)) { return "type=" + typeName; }` | ✔ (null type name also refused, as before) |
| `relocateEmptiedContainer` Cart branch unchanged | `case UNIT_LOAD_TYPE_PALLET: case UNIT_LOAD_TYPE_CART: → EmptyPallets` still present; callers outside this job (SBDEV-2001) unaffected | ✔ |
| V2.2.41 untouched | not in diff | ✔ (see L-2 for the consequence) |
| Mutation evidence (both directions) | `selectsPalletsOnly`, `refusesACart` — reported red on revert; reading confirms each would go red for the stated reason | ✔ |

**Sibling sweep** (`git grep` of `Pallet/Cart`, `Pallet, Cart`, `Pallet + Cart`, `Pallets and/or Carts`, and
case-insensitive `cart` over every SBDEV-1581 file in `src/main`/`src/test`): no remaining job-path text claims the job
moves Carts. Remaining hits are all legitimate:
- `UnitloadBusinessService.java:611` `Pallet, Cart -> EmptyPallets` and `:644` — `relocateEmptiedContainer`'s own doc/switch (still true).
- `UnitloadBusinessServiceUnitTest.java:1619,1673` — `relocateEmptiedContainer` tests (still true).
- `EmptyStoragePalletCandidatesIT` — see L-1.
- `V2.2.41__seed_empty_pallet_cleanup_sysprops.sql:2,26` — see L-2.
- `JobMetrics`, `JobMetricsConfiguration`, `EmptyPalletCleanupJob`, `EmptyPalletCleanupJobUnitTest`, `UnitloadSkipLockedIT`, `RelocateEmptyStoragePalletIT`, seed tests: zero Cart mentions.

**Job-level failure rule still meaningful:** `EmptyPalletCleanupJob` (b) "every candidate refused" now fires only when a
tenant's EmptyPallets refuses *Pallets* — still a real seed fault, and the reworded comment ("every candidate of that
type") is accurate.

## DB verification (run by this lane, 2026-10-19)

EmptyPallets' `location_constraint` (`storagelocationtype_id = location.type_id` → `unitload_type.name`), **all nine tenant DBs**:

- `Pallet` only: wms2-wineco-dev, wsl-wineco-uat, wsl-wineco-prd
- `Case+Pallet`: nywh-hydra-uat, nywh-hydra-prd, c1wh-shipitez-uat, c1wh-shipitez-prd, nywh-shipitez-uat, nywh-shipitez-prd

→ zero DBs accept Cart. "no tenant's EmptyPallets location accepts a Cart" holds across the full current estate
(the code comments cite only five of the nine; see I-1).

Live candidate census on the four PRDs with the query's predicates and `{Pallet, Cart}`:
WineCo 74 Pallet / 0 Cart · c1wh 18 / 0 · nywh-shipitez 22 / 0 · Hydra 0 / 0. **The exclusion strands no Cart on PRD today.**

## Stage 2 — findings

### [LOW] L-1 — `EmptyStoragePalletCandidatesIT` still frames Cart as a "qualifying type" — Confidence: HIGH
File: `src/test/java/net/aim_ai/wms/integration/repository/EmptyStoragePalletCandidatesIT.java:33-35, 76-83, 180`
> `The positive controls are spread over BOTH storage areas and BOTH qualifying types (seeded unitload_type 5 "Pallet" and 6 "Cart")`
> `@DisplayName("selects an empty, unlocked Pallet in a storage area, and an empty Cart in another")`
> `@DisplayName("excludes types other than Pallet and Cart (Tote, Case, Default)")`

The IT is still a **meaningful** test of the repository contract: the query is `ut.name IN (:typeNames)`, and passing two
types exercises multi-element IN binding and keeps a type-hard-coding regression red. It does not claim the *job* moves
Carts in so many words, but "qualifying types" reads as the job's definition, and nothing at DB level pins the job's
actual argument (only the Mockito captor in `selectsPalletsOnly` does).
Failure scenario: a future reader takes the javadoc as the job's scope and "fixes" `CONTAINER_TYPES` back to match it.
Fix: reword to "the query is type-parameterised; these tests pass two types (Pallet, Cart) to exercise the IN-list and
the type predicate. The job passes Pallet only (SBDEV-1581, 2026-10-19), pinned by
`EmptyPalletCleanupJobServiceUnitTest.selectsPalletsOnly`." Optionally add one assertion that
`findEmptyStoragePalletIds(Set.of(PALLET), …)` excludes the Cart control — a DB-level pin of the job's real argument.

`RelocateEmptyStoragePalletIT` and `UnitloadSkipLockedIT`: fixtures are type 5 (Pallet) only; no Cart claim. Still true.

### [LOW] L-2 — operator-visible sysprop description still says "Pallets/Carts" — Confidence: HIGH
File: `src/main/resources/db/migration/V2.2.41__seed_empty_pallet_cleanup_sysprops.sql:26` (`hidden = false`)
> `'SBDEV-1581: enable the nightly job that returns empty Pallets/Carts left in storage areas to EmptyPallets. …'`

Leaving V2.2.41 alone is correct (applied on dev; editing it breaks the Flyway checksum). But this string is what an
admin sees on the sysprop screen when deciding to switch the job on, on every tenant that later applies V2.2.41.
Failure scenario: an operator enables the job expecting Carts to be returned; they are silently SKIPPED/never selected.
Fix (pick one): a follow-up `V2.2.xx` `UPDATE los_sysprop SET description = '…Pallets…' WHERE syskey =
'EMPTY_PALLET_CLEANUP_ACTIVATED' AND description = '<old literal>'` (idempotent, leaves edited rows alone); or accept
and record it as a known-stale string in catalog §4.6a. The header comment (line 2) is developer-only and harmless.

### [LOW] L-3 — catalog §4.6a attributes "Pallet only" to the repository method — Confidence: HIGH
File: `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md:387`
> `` `UnitloadRepository.findEmptyStoragePalletIds` — ids only, up to 500: **Pallet only** (Carts excluded 2026-10-19 … ``

The method is type-parameterised; "Pallet only" is the caller's `EmptyPalletCleanupJobService.CONTAINER_TYPES`.
Fix: `findEmptyStoragePalletIds(CONTAINER_TYPES = {Pallet}, …)`. Otherwise the row is accurate: the facts (constraint
values, product decision, ⏳ pending-merge marker) match the code and the DB check above.

### [LOW] L-4 — catalog §4.6a Writes row omits the type re-check — Confidence: HIGH
File: `wms2-scheduled-jobs-catalog.md:388`
> `re-check under the lock (incl. emptiness → SKIPPED_STATE)`

The second half of the exclusion (a non-Pallet, incl. Cart, → `SKIPPED_STATE`, logged `type=<name>`) is not in the
doc, so it describes half the mechanism. Fix: `re-check under the lock (type = Pallet, storage area, not at EmptyPallets,
not a child, empty → else SKIPPED_STATE)`.
Changelog row 619: accurate (branch name `fix/SBDEV-1581-exclude-carts` matches `git branch --show-current`; constraint
values match the DB). §6 row 477 and every other §4.6a row: no Pallet/Cart text, nothing stale. The Metrics row's
"a location-type constraint rejects a whole type" is still true (for a tenant that refuses Pallets).

### [LOW] L-5 — callee javadoc carries a caller fact — Confidence: MEDIUM
File: `src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java:405`
> `containers of the given types (the job passes Pallet only) left in a STORAGE area,`

A second copy of `CONTAINER_TYPES` in prose; it rots the day the set changes (the service javadoc already lists two
places to edit on re-adding Cart, and this is a third it does not name). Fix: `containers of the given types (see
EmptyPalletCleanupJobService.CONTAINER_TYPES)`. The line is also ~120+ chars, as is the edited `disqualification` javadoc
line (`UnitloadBusinessService.java:1020`) — reflow.

### [LOW] L-6 — `refusesACart` re-implements `assertRefusedBecause` — Confidence: HIGH
File: `src/test/java/net/aim_ai/wms/unit/service/UnitloadBusinessServiceRelocateEmptyStoragePalletTest.java:165-178`

Not vacuous: the `.as(...)` message, `never()` verify and `type=Cart` log assertion each go red on a reverted re-check.
**The lenient stub is justified**: without it, a regression would enter the real `relocateEmptiedContainer` on mocks
(`locationRepository.findByName` → empty → `EntityNotFoundException`), failing on an unrelated exception rather than on
the MOVED-vs-SKIPPED_STATE assertion; with it, the regression reaches `MOVED` and the attributable message fires. Lenient
is required because on correct code the stub is unused (STRICT_STUBS default). Nit only: body could be
`lenient()…; assertRefusedBecause("type=" + WmsConstants.UNIT_LOAD_TYPE_CART);` with the custom `.as()` folded into the helper.

`selectsPalletsOnly` (EmptyPalletCleanupJobServiceUnitTest:103-119): not vacuous — `containsExactly(PALLET)` on the
captured arg is red for `{Pallet, Cart}` and for `{}`. Belt and braces with the strict `candidates()` stub (which now
binds `Set.of(PALLET)` and would raise PotentialStubbingProblem in every other test on drift); the dedicated test gives
the attributable message. Good.

### [LOW] L-7 — investigation report's open question is now answered but not annotated — Confidence: HIGH
File: `sbdocs/3-Resources/reports/260506-sbdev-1581-empty-pallet-cleanup-investigation.md:187`
> `1. **Should the cleanup job also handle empty CART-type unit loads?** … Clarify with Brent whether carts should go to the same location or be excluded.`

Fix: append `→ Answered 2026-10-19: excluded (EmptyPallets' location_constraint refuses Cart on all nine tenant DBs; SBDEV-1581 fix/…-exclude-carts).`

### [INFO] I-1 — evidence cited in code is a subset of the estate; future-tenant caveat
Files: `EmptyPalletCleanupJobService.java:38-43`, `EmptyPalletCleanupJobServiceUnitTest.java:106-108`
The comments name five DBs ("dev and WineCo PRD; … c1wh, nywh and Hydra PRD") while asserting "no tenant". This lane's
check covers all nine, so the claim is true today. Two caveats worth one clause if you touch the comment again: (a) it is
a property of tenant seed data, not code, so a tenant onboarded with a Cart-accepting EmptyPallets type would simply not
get its Carts cleaned (silent, not wrong); (b) the "re-add" note correctly names both code sites.

## Open Questions
None at CRITICAL/HIGH.

## Positive observations
- Exclusion is applied at **both** layers (selection and under-lock re-check), and the re-check returns `SKIPPED_STATE`
  instead of throwing, so a Cart can never reach the "every candidate refused → tenant failure" path.
- `relocateEmptiedContainer` left alone — correct blast-radius control for SBDEV-2001's callers; the new inline comment
  says so at the exact point a future editor would be tempted.
- V2.2.41 untouched — right call for an applied migration.
- `CONTAINER_TYPES` javadoc records the why, the evidence, and the condition for reversal.
- Both new tests are mutation-attributable (custom `.as()` messages), and the lenient stub is reasoned in a comment.
- Display names of the neighbouring tests were updated ("not a Pallet"), so no stale test name survives.

## Recommendation
**APPROVE.** Ship as is; fold L-1, L-3, L-4, L-5 (comment/doc-only) into the same PR if convenient. Decide L-2
(follow-up migration vs. accept) explicitly. L-6/L-7 optional.
