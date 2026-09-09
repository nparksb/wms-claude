# PR #296 fact-check — round 2 (narrowed scope)

Independent re-derivation of the round-2-specific claims in
[PR #296](https://github.com/SiteBossInc/wms2-api/pull/296), on top of round 1's own fact-check
(`pr296-fact-check.md`, 6/6 PASS against `e7c844b7`), which is not re-derived here. Scope narrowed by
the team lead mid-task to exactly the three items below. Worktree:
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-296-review2-fact`.

**Commits covered**: `7edd47d2` (round-1 fixes: M-1, L-3) and `2ada3e37` (round-2 fix: R2-L-1) —
the latter landed on the PR *after* this fact-check's original assignment (its head was `7edd47d2`
when the task was handed out), fetched separately via `refs/pull/296/head`.

## Verdict table

| # | Claim | Verdict | Detail |
|---|---|---|---|
| 1 | M-1 fix uses `lenient()` (not plain `when()`) for the second sysprop stub; full suite still 6265/0/0/67 | PASS | §1 |
| 2 | R2-L-1 fix adds a `ListAppender`-based log assertion pinning the INFO line in `refusesWhenNotActivated` | PASS | §2 |
| 3 | PR body no longer cites specific line numbers for the three PIT-survivor returns (cites by role instead) | **FAIL** | §3 |

**2/3 PASS, 1 FAIL.**

## 1. M-1 fix: `lenient()` stub + full suite

`git diff e7c844b7..7edd47d2 -- src/test/java/net/aim_ai/wms/unit/schedulejob/CleanUpOldMessagesJobUnitTest.java`:

```diff
             when(syspropService2.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
                     .thenReturn("false");
+            lenient().when(syspropService2.getSysvalue(WmsConstants.SYSTEM_PROPERTY_CLEAN_UP_OLD_MESSAGES_ACTIVATED_KEY))
+                    .thenReturn("true");
```

Confirmed: `lenient()` wraps the second stub, not a plain `when()` — under `STRICT_STUBS` a plain
`when()` here would risk `UnnecessaryStubbing` on correct code (the `||` short-circuits so correct
code never reads this key), which is exactly the trap M-1 was filed against.

**Full suite, run solo** (see note below on a self-inflicted false start): `mvn -o clean test` at
`7edd47d2` →

```
[WARNING] Tests run: 6265, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
```

Exact match to the PR's "6265/0/0/67". **Note on method**: an earlier attempt at this run produced a
garbage result (5725/15/5175/67) because a PIT `mvn clean test-compile` was briefly running
concurrently in the same worktree (the known concurrent-Maven-in-one-worktree trap) before being
killed; a second "clean" rerun still showed 1 failure because the corrupted first run had mutated a
committed-but-gitignored-from-`mvn clean` stateful fixture — the ArchUnit freeze store
`src/test/resources/archunit_store/5fb3fee0-...` — pruning 58 entries it wrongly judged solved. Restored
via `git checkout --` and reran a third time solo: clean 6265/0/0/67, and `git status --short` after
the run was empty (no store drift). This has nothing to do with PR #296's actual diff (it never touches
that package) — recorded here only because it's this fact-check's own methodology note, not a PR defect.

## 2. R2-L-1 fix: `ListAppender` log assertion

`2ada3e37` is not in the original `e7c844b7..7edd47d2` diff window; fetched via
`git fetch origin pull/296/head` (resolves to `2ada3e37`). `git show --stat 2ada3e37`: one file changed,
`CleanUpOldMessagesJobUnitTest.java`, +28 lines.

Read the actual test code (`git show 2ada3e37:.../CleanUpOldMessagesJobUnitTest.java`):

- `RunForCurrentTenantLocking` gained `private ListAppender<ILoggingEvent> captured;` and
  `private Logger jobLog;`, wired in `@BeforeEach` (`jobLog = (Logger) LoggerFactory.getLogger(CleanUpOldMessagesJob.class); captured.start(); jobLog.addAppender(captured);`) and torn down in `@AfterEach`
  (`jobLog.detachAppender(captured)`), plus a `messagesAt(Level)` helper filtering `captured.list` by
  level and mapping to `getFormattedMessage()`.
- `refusesWhenNotActivated` (not `refusesWhenGlobalCronSwitchOff`) gained, after its existing
  `assertThat(ran).isFalse()` / `never()).archiveMessage()` / `unlock(...)` assertions:
  ```java
  assertThat(messagesAt(Level.INFO))
          .anySatisfy(m -> assertThat(m).contains("not activated for this tenant"));
  ```

Confirmed: this is a genuine log-level pin, not a no-op — it asserts the refusal message is present
**at INFO**, which would fail if a future change reverted the L-3 fix back to DEBUG (the exact scenario
the commit message for `2ada3e37` describes as its motivation). The commit message also claims
"Hand-mutation-verified: reverting the log call to DEBUG fails the new assertion" — plausible given the
assertion shape (`messagesAt(Level.INFO)` would return empty and `anySatisfy` on an empty list fails),
but this fact-check did not itself re-run that hand-mutation (out of the narrowed scope; the mechanism
is unambiguous from reading the code).

## 3. R2-L-2 claim: PR body no longer cites specific line numbers — FAIL

Re-fetched the PR body live (`gh pr view 296 --repo SiteBossInc/wms2-api --json body,updatedAt`,
`updatedAt` = `2026-09-03T23:02:31Z`, i.e. after `2ada3e37` was pushed). The **Test surgery** section
still reads, verbatim:

> PIT on `CleanUpOldMessagesJob`: 84% kill rate. `runForCurrentTenant()`'s three return statements
> (`:357`, `:360`, `:363`) each show one SURVIVED mutant...

`grep -c "Review round 2\|R2-L-1\|R2-L-2"` on the current body returns **0** — there is no "Review round
2" section at all, despite `2ada3e37`'s commit message explicitly being titled "review round 2: fix
R2-L-1" and stating "(R2-L-2, a stale line-number citation in the PR description, is a PR-text-only fix
with no code change.)". The commit message asserts R2-L-2 was fixed; the PR description itself was not
actually edited to reflect that — the line numbers are still there, unchanged, and still stale relative
to the current file (which now sits at `:362/:365/:368` after the L-3 fix inserted comment lines — see
round 1's fact-check methodology note, not re-derived here since it's unchanged).

**This is the one FAIL of this pass**: the specific, checkable claim ("PR body no longer cites specific
line numbers, cites by role instead") does not hold against the live PR description as of this check.
The commit message's claim to have made this fix is not reflected on GitHub — either the PR description
edit did not happen, or did not save/push. Recommend re-pushing the PR description update before this
PR is considered ready, and re-verifying stale line-number references generally don't survive future
code edits (this file's own history — round 1 already introduced one instance of this exact drift).

---

## Method note

Items 1-2 verified against the actual diffs/commits with `git show`/`git diff` plus one from-scratch
`mvn -o clean test` run (after diagnosing and discarding a self-inflicted false start from concurrent
Maven processes in the same worktree). Item 3 verified against a live re-fetch of the PR body via `gh
pr view`, not a cached copy, with a byte-for-byte grep for the line numbers and for any round-2 section
heading. Per the team lead's scope narrowing, this pass did not re-derive: the `e83d9550` historical
claim, the original suite count/scope, the original PIT 84% figure, or the M-1 hand-mutation (all
already established by round 1's fact-check).
