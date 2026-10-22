# SBDEV-3474: re-review 2, commit `93be265d` (fixes for F1, F3, F4, F5 from `code-rereview.md`)

- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3474`, HEAD `93be265d` (local only), parent `d9a708b9`. `d62a663d` is already on `origin/bugfix/SBDEV-3474-scangate-outbound-label-check`, so the commit message is right that F2 has to go in the PR body.
- **Lane:** code-reviewer, read-only. No edits, stash, checkout or reset.
- **Executed:** `mvn -o -q test -Dtest=OutboundPalletLabelGuardUnitTest`. Result: tests=12, errors=0, failures=0, skipped=0. The report is timestamped 03:00, which matches this run. An unrelated `clean test` was running in the SBDEV-3486 worktree at the same time. It is a separate `target/`, and this was a unit test only, with no container.
- **Read:** `git show 93be265d`; `TruckLoadingWriteEntryPointArchTest` (whole file); `OutboundPalletLabelGuard` (whole file); `MobileMoveUnitloadService.handleTruckOffLoadingNoClear` (:532-574); `MobileTruckLoadingWriteService.scanGate`, PHASE A through D (:251-515, lock sites by grep).

## 1. Resolution check

| Item | Status | Note |
|---|---|---|
| F1 | Resolved, with one new closed-set error | "cannot reach" is now "almost never reaches" / "only in a rare race". The mechanism is correct: the guard (`OutboundPalletLabelGuard:63-64`) and D0 (`MobileMoveUnitloadService:534-535`) each call `getSysvalue` for both keys. Their emptiness and match logic is identical (guard :68-77 vs D0 :547-564), both run on the same `dto.getPalletName()` (`MobileTruckLoadingService:162`, `MobileTruckLoadingWriteService:427`), and both run in the same thread and client context. So a disagreement needs a sysprop change, and "almost" is justified. The new sentence says the gap "includes every lock acquisition". That is false. See **N1**. |
| F3 | Resolved | The list now matches the arch test's own blind-spot javadoc: reflection, method reference, subtype- or proxy-typed receiver, and another method of the facade (class granularity). The rule imports `net.aim_ai.wms` with `DO_NOT_INCLUDE_TESTS`. All of `src/main/java` is under `net/aim_ai/wms` (no other root, no Kotlin or Groovy), so import scope is not a missing escape today. `MobileTruckLoadingWriteService` extends nothing and implements nothing (:178), so no supertype- or interface-typed call escapes either. "A check on the obvious bypass, not a proof" is accurate. |
| F4 | Resolved | The display names now state what the tests assert: key `noValidString` plus `(no label format configured)`; and `AOUT-000123` passes while `IN-000002` gets `noValidString`. The new javadoc claim holds: dropping either `isEmpty` check changes no outcome, because `"X".matches("")` is false, and the only other consumer of `patternConfigured` is the WARN. The javadoc's formatting is broken. See **N2**. |
| F5 | Resolved | "a bad label never reaches it" matches what `verifyNoInteractions(unitloadRepository)` proves. |

## 2. Closed-set words checked

- **"almost never" / "almost always" / "only in a rare race"** (fixture :95-97, :148-149): accurate, for the reasons in the F1 row. They are not absolute, and the qualifier's mechanism is correct.
- **"through `SyspropService`'s cache"**: acceptable. Both reads go through the `@Cacheable` method. Strictly, an unset key is never cached (`unless = "#result == null"`), but the sentence makes no claim either way. Not raised.
- **"a pattern edited in between"**: not exclusive wording, so not false. For completeness: a direct-SQL edit made *before* the guard's read can also surface between the reads when the 2-minute cache entry expires. That is "visible in between", not "edited in between". Not raised, because the sentence says "can", not "only".
- **"includes every lock acquisition"** (fixture :99-100; commit F1 bullet): **false**. See N1.
- **"so it only ever takes D0's no-match exit"**: already there before this commit and unchanged. Out of scope.
- **Commit F3 bullet, "lists every bypass the arch rule cannot see"**: holds against `src/main` today (F3 row).
- **Unit-test javadoc "its only other effect is the WARN"**: true (guard :68-77).

## 3. Diff is comments and display names only

Confirmed. Every changed line in `git diff 93be265d^ 93be265d` is a javadoc/comment line (`*` or `//`) or a `@DisplayName`. No production or test logic changed.

## 4. Commit message

It is accurate except that the F1 bullet repeats N1's error ("the gap between them includes every lock acquisition"). The commit is local and unpushed, so an amend is cheap. The F2 note is correct: `d62a663d` is on the remote branch.

---

## Findings

### [LOW] N1: "the time between them includes every lock acquisition" is false; PHASE D takes the gate lock after D0
**File:** `src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java:99-100`; also the commit message of `93be265d` (F1 bullet)
**Confidence:** HIGH

> `the time between them includes every lock acquisition, so a pattern edited in between can make D0 disagree with the guard.`

D0 runs at `MobileTruckLoadingWriteService:427`. After it, PHASE D takes `locationRepository.findByIdForUpdate(resolvedGateId)` (:464), and `transferUnitLoadToLocation(pallet, gate, false, …)` (:466) re-locks that row. D0's own purge also row-locks the `billoflading_position` rows it deletes. The window contains PHASE B's locks (the BOL, the pallet, every child, every order), not every lock the scan takes. The conclusion is unaffected. This is a new closed-set word in the text that was written to remove one.
**Fix:** "…and the time between them includes PHASE B's lock acquisitions (the BOL, the pallet, every child and every order), so…". Make the same change in the commit message's F1 bullet before pushing.

### [LOW] N2: The new F4 javadoc is malformed: lost indentation, a stray literal `*`, and an editing artifact
**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/OutboundPalletLabelGuardUnitTest.java:161-167`
**Confidence:** HIGH

> ```
>      * What these two pin is the OUTCOME ... The guard treats
>  * {@code ""} as unconfigured, ...
>  * <p>Original note: * An EMPTY sysprop value counts as unconfigured, ...
> ```

Lines 161-164 lost the class's 5-space `*` indentation. `Original note: * An EMPTY` carries a leftover leading `*` from the old first line, and javadoc renders it as a literal asterisk mid-sentence. "Original note:" is revision narration, not documentation. Separately, fixture line 100 is 137 characters, because the new sentence was joined onto the next line. That line is cosmetic only: checkstyle is a pom dependency, not a build gate that was observed.
**Fix:** re-indent 161-164 to `     * `. Replace line 165 with `     * <p>An EMPTY sysprop value counts as unconfigured, exactly like null. {@code los_sysprop.sysvalue} can` (drop "Original note:" and the stray `*`). Re-wrap fixture :99-100.

## Open questions (low confidence, not blocking)

None.

## Positive observations

- F1's replacement states the mechanism instead of only softening the adjective. The emptiness and match logic really is shared between the guard and D0, so "almost" is justified, not hand-waved.
- F3 now mirrors the arch test's own blind-spot list exactly, so the two cannot drift apart silently. The class-granularity escape is named in both places.
- F4 chose the honest rename over pretending, and the javadoc says why the emptiness check is not pinned (the WARN is its only observable effect).
- The commit really is comment and display-name only, and the 12 guard tests are green.

## Verdict

F1, F3, F4 and F5 are resolved as the re-review suggested. There are two new Lows. N1 is a false closed-set word ("every lock acquisition") in the fixture and in the commit message. N2 is broken javadoc formatting. Neither affects behaviour, but N1 is exactly the kind of claim this round set out to remove, and the commit is still local, so both are cheap to fix before pushing.

CHANGES REQUESTED
