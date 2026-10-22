# SBDEV-3474: final review, `93be265d` → `9fe170e0` and the PR #409 description

- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3474`, HEAD `9fe170e0` (= `origin/bugfix/SBDEV-3474-scangate-outbound-label-check`, = PR head `headRefOid`). Base `origin/develop` `67acb39d` (merge-base, unchanged).
- **Lane:** code-reviewer, read-only. No edits, stash, checkout, reset or Maven.
- **Instruments:** `git diff 93be265d 9fe170e0`; `git log -1 --format=%B` on `93be265d`, `9fe170e0`, `d62a663d`, `d9a708b9`; `git show 9fe170e0:` / `origin/develop:` of `MobileTruckLoadingWriteService` (PHASE A–D), `MobileTruckLoadingService`, `OutboundPalletLabelGuard`, `StringConverter.describeExpectedFormat`, the guard unit test, the fixture, `MobilePalletizeRepalletizeIT`; `git diff origin/develop...9fe170e0 -- src/test` for test annotations; `gh pr view 409`; `gh run view --log` of CI runs `35899976587` (`9fe170e0`), `35898212417` (`d9a708b9`) and `35849266840` (develop `67acb39d`); the evidence folder (`code-review.md`, `code-rereview.md`, `code-rereview-2.md`, `conformance.md`, `architect-consult.md`, `pit-mutations.xml`, the last parsed mutation by mutation).

## (a) `93be265d` → `9fe170e0`

- **Same parent** (`d9a708b9`) for both, so the amend changes only what `git diff 93be265d 9fe170e0` shows: 2 files, +11/−10, all in javadoc lines. No production file, test logic, annotation or display name changed.
- **N1 resolved.** Fixture :99-100 now reads "the time between them includes PHASE B's lock acquisitions (the BOL, the pallet, every child and every order)", which is the reviewer's wording. Checked against `9fe170e0` `MobileTruckLoadingWriteService`: B1 `billofladingRepository.findByIdForUpdate` (:295), B2 `unitloadRepository.findByLabelidForUpdate` (:299), B3 `findByIdForUpdate` per child from `findIdsByCarrierunitloadIdOrderById` (:306-310), B5 `customerorderRepository.findByIdForUpdate` per entry of `distinctOrderIds`, a `TreeSet` of the order ids that the children carry (:331-346). So "every order" means every **distinct** order the pallet's children carry, locked once each. That is accurate: a repeated order is not locked twice, but the sentence doesn't say it is. B4 and B6 are unlocked, so nothing is missing from the list. "Includes" is not exclusive, and the window also holds PHASE A's reads and C, so the sentence is true. The PHASE D gate lock (:464) comes after D0 (:427), so it is correctly not claimed.
- **N2 resolved.** Lines 161-167 of the unit test are back to 5-space ` * ` indentation, the stray literal `*` and "Original note:" are gone, and fixture line 100 is re-wrapped. No changed line is over 110 characters. The two remaining long lines in the unit test (:51, :184) predate this amend.
- **New second paragraph, checked:** "a guard that treated `""` as a configured pattern would match only the empty label, which the null/empty-label check already rejects first."
  - `String.matches("")` compiles the empty regex and requires a whole-input match, so only `""` matches. True.
  - The guard rejects `null`/`""` at :59-60, before either sysprop read (:63-64) and before the match (:80-81). True.
  - The printing-pattern case the old note mentioned holds as well: `convertFormatToRegex("")` returns `""`, which then behaves the same way.
  - Every clause is factually correct. There is a coherence problem, filed as Open Question Q1 below.
- **Amended commit message:** the F1 bullet now reads "includes PHASE B's lock acquisitions (the BOL, the pallet, every child and every order)", so N1's copy in the message is fixed. The rest of the message is byte-identical to `93be265d`'s, and its other claims were verified in `code-rereview-2.md`. Cosmetic only: the reflow leaves `It is now "almost` / `never".` split across two short lines. Not a finding.

## (b) PR #409 description, claim by claim

| Claim | Result |
|---|---|
| Problem: facade `scanGate` had no label check; the write service locks the BOL, the pallet and every child before PHASE C | TRUE (`origin/develop` facade :166-193 calls the write service directly; B1-B3 then PHASE C :404-406) |
| Repro numbers (1.9 s, 336 rows, 1,931 children) | Not in the evidence folder (only "336" is echoed, in `architect-consult.md:56`). Not verifiable here. Not raised. |
| Guard: pure string match, no entity row, configured-only, fails closed, fixes `checkPallet` NPE | TRUE (guard :58-87; `origin/develop` `checkPallet` did `palletLabel.matches(pattern)` with no null check) |
| Facade calls the guard before the write service; `checkPallet` delegates; `syspropService` removed | TRUE (`git diff origin/develop 9fe170e0 -- MobileTruckLoadingService.java`) |
| Rail + positive control | TRUE (2 `@Test` in `TruckLoadingWriteEntryPointArchTest`) |
| Fixture and `MobileTruckLoadingRollbackIT` mock the guard | TRUE (fixture :152 `@MockitoBean OutboundPalletLabelGuard`; RollbackIT references it) |
| Behaviour change: `unexpectedUnitLoadDoesNotHaveOrder` after PHASE B's locks | TRUE (PHASE C :404-406, after B1-B5) |
| `entityNotFoundForName` from PHASE A before any lock, for a label that does not exist | TRUE (`existsByLabelid`, `origin/develop` :263-265, before B1) |
| "Or a BOL or gate error" | TRUE, and it makes no timing claim. Unknown BOL/gate throw in PHASE A; gate mismatch and BOL state throw in PHASE C after the locks. |
| Succeeded if every child carried an order, or the pallet had no children | TRUE, given passing gate/BOL checks. With no children, `parcelIds` is empty, the orphan loop passes, D0 takes the no-match exit, and D's per-parcel loop is empty (same result as `code-rereview.md` §2). The duplicate-order case ("Too many orders…") is an exception, but the list is not framed as closed. |
| F2 correction of `d62a663d`'s message | TRUE (its message says "…or entityNotFoundForName after the locks") |
| New tests: guard unit test (12), service regression test, rail (2); "+15 new tests" | TRUE. The diff adds 10 `@Test` + 1 `@ParameterizedTest @NullAndEmptySource` (2 cases) = 12 in the guard test, 1 `@Test` in `MobileTruckLoadingServiceTest`, and 2 in the arch test = 15. No test annotation is removed. The CI log confirms 12 and 2 per class. |
| CI unit 6873/0 vs develop 6858/0; integration 503/0 vs 503/0 | TRUE on both PR runs and on develop run `35849266840`. 6873 − 6858 = 15. Integration also has 31 skipped on both sides, unchanged. |
| Local 6871 vs 6858, +13 | Not in the evidence folder; internally consistent. Not raised. |
| Per-class IT counts 4/3/2/7/2/3 | TRUE, identical on both PR runs |
| "Every truck-loading IT passed with the mocked guard: … `MobilePalletizeRepalletizeIT` 7" | **MISLEADING**, see F-A |
| Mutation-check bullets | One false, one imprecise, see F-B and F-C |
| Review history | One false, one imprecise, see F-D and F-E |

---

## Findings

### [LOW] F-A: `MobilePalletizeRepalletizeIT` is listed as a truck-loading IT that "passed with the mocked guard". It is neither.
**Location:** PR body, Tests, "CI on `d9a708b9`" bullet
**Confidence:** HIGH

> `Every truck-loading IT passed with the mocked guard: MobileTruckLoadingLockOrderProbeIT 4, MobileTruckLoadingRaceIT 3, MobileTruckLoadingRollbackIT 2, MobilePalletizeRepalletizeIT 7, plus …`

`MobilePalletizeRepalletizeIT` extends `BaseIntegrationTest`, not `AbstractTruckLoadingPgFixture`. It declares no `OutboundPalletLabelGuard` mock (only `@MockitoBean ManageOrderService`, :67), and it never calls `scanGate`. It runs `MobilePalletizingService.scanPallet`, and its only truck-loading reference is a helper that fakes "what `MobileTruckLoadingService.scanGate` leaves behind" (:128). `git grep OutboundPalletLabelGuard` over `src/test` finds only the fixture, its two subclasses (LockOrderProbe, Race), RollbackIT, the unit tests and the arch tests. So the sentence overstates the guarded-path coverage by 7 tests.
**Fix:** move it next to the two probes: "…`MobileTruckLoadingRollbackIT` 2; plus `MobilePalletizeRepalletizeIT` 7, `ClosebolLockOrderProbeIT` 2 and `PalletizeLockOrderProbeIT` 3 (neighbouring lock/BOL ITs, which do not use the guard)."

### [LOW] F-B: "PIT credited the kills to other tests" contradicts the saved PIT report for the scanGate call
**Location:** PR body, Tests, Mutation checks, second sub-bullet
**Confidence:** HIGH

> `PIT credited the kills to other tests, so a hand mutation confirmed the regression test itself fails …`

In `pit-mutations.xml`, the `scanGate` guard-removal mutant (`MobileTruckLoadingService:162`, `VoidMethodCallMutator`) is KILLED with `killingTest` = `MobileTruckLoadingServiceTest…scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService()`, which is the regression test itself. `conformance.md:390` says the same ("killed directly and attributably"). Only the `checkPallet` mutant (:87) is credited to another test (`testCheckPalletSuccessfully`, via `UnnecessaryStubbingException`). The sentence contradicts the evidence the previous bullet points to. It understates the evidence, but it is still false. It may describe an earlier PIT run, but that run is not what was saved.
**Fix:** "PIT credits the `scanGate` kill to the regression test itself. It credits the `checkPallet` kill to `testCheckPalletSuccessfully` (an unused-stub failure), so a hand mutation confirmed the targeted `checkPallet` test fails on its own …" If the hand mutation you mean was on `scanGate`, keep it and drop "credited to other tests".

### [LOW] F-C: "2 PIT survivors" reads as the report total; the saved scoped report has 6
**Location:** PR body, Tests, Mutation checks, last sub-bullet
**Confidence:** MEDIUM

> `2 PIT survivors, both on the neither-configured branch that only logs a warning; disclosed rather than tested.`

`pit-mutations.xml` has 6 SURVIVED: the 2 at `OutboundPalletLabelGuard:70`, plus 4 in unchanged `MobileTruckLoadingService` code: `setManifestLocationsOnPallet` at :127 (`checkPallet`) and :180 (`scanGate`), `setManifestLocationsOnBOL` at :263, and `resolveBOLType` at :268. The 4 predate this PR and none is in a line it touched. Still, the sentence does not scope itself to the new code, and a reader who opens the report finds 6.
**Fix:** "2 PIT survivors in the new code (both on the guard's neither-configured branch, which only logs a warning), disclosed rather than tested. The report's other 4 survivors are in pre-existing `MobileTruckLoadingService` DTO setters."

### [LOW] F-D: "Both are fixed … using the reviewer's suggested wording" is false for N2
**Location:** PR body, Review, last bullet
**Confidence:** HIGH

> `Both are fixed in 9fe170e0 using the reviewer's suggested wording, and that final edit has not been reviewed itself.`

N1 uses the suggested wording verbatim. N2 does not. The suggestion was `<p>An EMPTY sysprop value counts as unconfigured, exactly like null. {@code los_sysprop.sysvalue} can …`, which kept the old note. What landed is a new paragraph, `<p>Why empty strings are worth pinning at all: … would match only the empty label, which the null/empty-label check already rejects first.` It also drops the old note's printing-pattern clause. The new paragraph is factually correct (see (a)), but "the reviewer's suggested wording" is what told readers no further review was needed. The trailing "has not been reviewed itself" becomes stale once this report exists.
**Fix:** "N1 uses the reviewer's wording. N2's formatting is fixed, and its second paragraph is rewritten rather than restored. Both were reviewed in `final-review.md`."

### [LOW] F-E: "All addressed in `d9a708b9` except M2": L2 was addressed in the reworded `d62a663d`, not in `d9a708b9`
**Location:** PR body, Review, "Code review (`d62a663d`)" bullet
**Confidence:** HIGH

> `Code review (d62a663d): approved, 2 Medium and 8 Low. All addressed in d9a708b9 except M2, which is recorded on the ticket.`

`d9a708b9`'s subject is "address the code review (M1, L1, L3-L8)". L2 (the old-outcomes list omitted "success") was fixed by rewording the parent's message into `d62a663d`, which now says "…the scan SUCCEEDED…". Separately, the review was run on `3b8b19e1` (`code-review.md` title). `d62a663d` has the same tree (`4e110922`), so citing it is defensible, but the reword is exactly why L2's fix does not appear in `d9a708b9`.
**Fix:** "Code review (`3b8b19e1`, since reworded as `d62a663d`): approved, 2 Medium and 8 Low. L2 was fixed in the reword, M1 (doc half) and L1, L3-L8 in `d9a708b9`. M2 and M1's IT half are recorded on the ticket."

### [LOW] F-F: "That last case" dangles after the inserted Correction sentence
**Location:** PR body, Fix, "Behaviour change" paragraph
**Confidence:** MEDIUM

> `…the scan succeeded. **Correction:** commit d62a663d's message says entityNotFoundForName came "after the locks"; it does not (fix-round review F2). That last case needed a direct API call, because the handheld UI always runs /scanPallet first.`

"That last case" meant the success case, but the Correction sentence now sits between them. As written, it reads as referring to the `entityNotFoundForName` correction.
**Fix:** move the Correction to its own paragraph after "…runs `/scanPallet` first.", or write "The success case needed a direct API call…".

## Open questions (low confidence, not blocking)

### [LOW] Q1: The new paragraph's lead-in promises a reason to pin, and the reason given shows the outcome cannot differ
**Location:** `src/test/java/net/aim_ai/wms/unit/service/mobile/OutboundPalletLabelGuardUnitTest.java:165-167`
**Confidence:** LOW

> `<p>Why empty strings are worth pinning at all: {@code los_sysprop.sysvalue} can hold {@code ''}, and a guard that treated {@code ""} as a configured pattern would match only the empty label, which the null/empty-label check already rejects first.`

Each clause is true. But the second clause argues that even a guard which got the emptiness rule wrong would produce the same outcome, so it reads as a reason the tests catch nothing. The first paragraph already says that. The real reason to keep the tests is the first clause: `''` is a real stored value, and they pin the fail-closed outcome and the `(no label format configured)` message for it (`describeExpectedFormat` drops blank accept patterns, :84). A reader may wonder why the rest of the sentence is there. This is wording, not a false claim, so it does not affect the verdict.
**Possible fix:** "…can hold `''`, and these pin that such a tenant still fails closed with the no-format message. (A guard that treated `""` as a configured pattern would behave the same, since `""` matches only the empty label, which is rejected first.)"

## Positive observations

- The amend is limited to the lines N1 and N2 named. Both files and the commit message changed together, and no logic moved.
- N1's replacement names the locks precisely, and it survives the B5 check: orders are locked per distinct id, and "every order" does not claim otherwise.
- Every number in the PR description that has an instrument behind it holds: 15 new tests, 6873/6858, 503/503, and the six per-class IT counts on both CI runs. The behaviour-change list matches `origin/develop`'s PHASE A/C/D in every case it names.

## Verdict

Part (a) is clean: N1 and N2 are resolved, the amend is javadoc-only, and nothing new in it is false. Part (b) has six Lows, all in the PR description (editable without a commit). F-A, F-B and F-D are claims the evidence contradicts, so fix them before merge. F-C, F-E and F-F are precision edits.

CHANGES REQUESTED
