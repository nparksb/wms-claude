---
name: mutation-harness-traps
description: "Use PIT, never a hand-rolled patch-and-recompile mutation script — hand-rolled harnesses produced confident, well-formatted, entirely wrong tables at least nine measured times; PIT's own trap is that it does NOT compile, so keep `test-compile` in the same script"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 6cb9776e-0d51-4b37-8a7e-cab8197878f9
  modified: 2026-09-09T21:20:26.000Z
---

Supersedes and merges four earlier memories — old slugs kept here so stale links stay traceable:
[[mutation-harness-must-force-recompile]], [[mutation-harness-must-prove-the-mutant-hit-its-target]],
[[mutation-pin-vacuous-after-fix-when-two-fixes-interlock]], [[pit-does-not-compile-stale-test-bytecode]].
Companion file: [[green-tests-that-prove-nothing]] — what to do once a mutant *does* land and nothing
goes red.

## Bottom line

**Use PIT (`org.pitest:pitest-maven:mutationCoverage`), not a hand-rolled mutate-run-restore script.**
PIT mutates *bytecode in memory*: no source patch, no anchor matching, no restore, no race — which is
exactly the class of bug that made every hand-rolled harness below lie. **Nine distinct failure
mechanisms, every one of them measured on real work** — SBDEV-3012 (Java + jest halves), SBDEV-2967-C
(**four separate lies in ONE session**, found by me and by two independent review lanes), SBDEV-2960,
and a compile-error case on SBDEV-3102's entity work. None of them *looked* like an error; all
produced confident, well-formatted, entirely wrong tables.

**Generalisation:** the outputs of a verification tool are themselves unverified until negative-tested.
Same lesson as [[negative-test-verify-scripts-before-trusting-them]] and
[[verify-template-helpers-were-broken-and-inherited-by-51-scripts]], now on the mutation lane.

## PIT's own trap: it does not compile

**PIT never compiles. It grades whatever bytecode sits in `target/test-classes`.** Mutating bytecode
in memory covers only the **production** classes; the **test** classes it runs come straight off disk
from `target/test-classes`, and the `mutationCoverage` goal does not bind `test-compile`. So a source
edit to a *test* is invisible to PIT until something else compiles it.

Measured on SBDEV-3102 slice B rev 2: I added a test covering
`ReplenishmentOrderMaintenanceService:235` (`desiredAmount <= 0`), then tuned its fixture to land
availability on exactly zero so the `ConditionalsBoundary` mutant would die too. PIT reported
`235 SURVIVED ConditionalsBoundaryMutator` **twice in a row**. The test was correct both times — PIT
was grading the pre-edit bytecode. Prefixing `mvn -o -q test-compile &&` (i.e. a plain
`mvn test-compile` in front of the PIT invocation) flipped the same mutant to `KILLED`, attributed to
the new test, and moved the board from **110 to 111 killed**.

- **Direction of failure:** it fails *safe* — a false `SURVIVED`, never a false `KILLED`. But safe is
  not harmless: a false SURVIVED reads as "the test you just wrote does not work", and the natural
  response is to rewrite a test that was already right, or to conclude a branch is uncoverable. I
  nearly did both.
- **Tell for a stale run:** the killed-count does not move *at all* between two PIT runs where you
  changed a test. Real edits move it, even by one.
- **How to apply:** the recipe in `.claude/skills/wms-triage/SKILL.md` already has the compile step —
  `mvn -o test-compile -q` then `mvn -o org.pitest:pitest-maven:mutationCoverage`. Keep them in **one
  script, one call**, so the compile cannot be dropped while iterating. Same reason the
  `git checkout -- src/test/resources/archunit_store` revert belongs in that script
  ([[wms2-develop-preexisting-test-failures]] — that suite MUTATES the tracked `archunit_store`, so
  `git checkout` it after every `mvn test`).

## What PIT structurally cannot cover

- **Ordering defects — and a 100% score actively CONCEALS them.** `VoidMethodCallMutator` removes
  calls; it **never reorders** them. A guard moved *below* the state change it protects still
  throws, just too late, and every call-removal mutant stays killed. Ordering pins are hand-written
  or absent.
  **Measured twice on SBDEV-3198, same day (2026-09-02), both times against a PERFECT PIT score:**
  (a) moving a guard below `RUNNING.compareAndSet` in `ReplenishOrderJob` leaves a JVM-wide flag
  true forever and stops replenishment fleet-wide with one DEBUG line as the only signal — the test
  class stayed green through it at **48/48 killed**, and the author's own `@BeforeEach` reset the
  flag so no later test could see it either; (b) swapping schedule-then-cancel into
  cancel-then-schedule in `SchedulingConfiguration.register` strands a job with **no trigger for
  the life of the process** whenever `schedule()` throws — PIT scored **118/118, 0 survivors** on
  that exact class while blind to it, and **no existing test asserted the ordering the author's own
  javadoc claimed**.
  ⚠️ **So "118/118 killed" and "the dangerous mutant ships" are fully compatible statements.** The
  score is evidence about the operators PIT has, not about the invariants you care about.
  **How to apply:** before believing a high score, write down each invariant the change relies on as
  a sentence, then ask for each one "what single edit falsifies this?" Any answer of the form *move
  X above/below Y*, *swap these two statements*, or *revert this specific guard* is outside every
  operator's vocabulary — hand-apply it. On (b) that took ten minutes and produced the most
  valuable test in the change; the fix was **a new test, not a new comment**.
- **"Revert this specific guard."** No mutation operator generates it. And the class-level PIT score
  is a **max over all tests**, so a disarmed test hides behind a sibling that kills a different mutant
  on the same line. The only signal is **per-test attribution** — see the two cheap probes in
  [[green-tests-that-prove-nothing]].

## Failure catalogue — how hand-rolled harnesses lie

**1. mtime-preserving restore skips recompilation, so mutant BYTECODE leaks into later mutants.**
SBDEV-3012: my harness reported **17 killed, 0 survived**. It was **void**. Confirmed with `javap`:
`target/classes/.../UserGroupService.class` still contained the M11 mutant (`int membersRemoved = 0;`
— `iconst_0; istore_3` where the repository call belongs) while the source on disk was correct.
Mechanism: the harness backed files up with `shutil.copy2` and restored with `shutil.move`; **both
preserve mtime**, so after a restore the `.java` was *older* than the `.class` compiled from the
mutant. `maven-compiler-plugin` is timestamp-based (`staleMillis`), skipped recompiling, and every
subsequent mutant ran against partially-mutated bytecode. Kills were credited to assertions that never
ran.
*How I caught it — not by reasoning.* The kill **attributions** were wrong in a way that made no sense:
a mutant in `UserService` was reported killed by `UserGroupServiceTransactionBoundaryTest`. Chasing
that one oddity exposed the whole run. Had every attribution looked plausible I would have shipped a
fabricated 17/17.
*Mitigations:* `os.utime(f, None)` on every source file **after applying the patch AND after restoring
it**; `mvn clean` once before the run.

**2. The patch silently did not apply.** SBDEV-2967-C, 2026-08-22: my script printed "5 guards now key
on the header" and had changed **nothing** — it printed `s.count(OLD)` computed BEFORE `replace`.
**Verify AFTER the write, by re-reading the file**, never by the count you used to find the target.
Assert the patch anchor matched **exactly once**.

**3. The anchor matched the wrong occurrence** — twice: a shared constant on SBDEV-2967-C, and on
SBDEV-3012 an anchor that hit a **template comment** instead of the code. On 2967-C the conformance
lane's first sweep reported **6 false-greens** — its regex anchored on the *constant*, and single/bulk method pairs share
one, so with `count=1` it deleted the pair partner's annotation and then asked whether the *other*
method was still gated. Anchor on something unique to the target — each method's own mapping path.

**4. A concurrent writer moved the tree.** Same session: three review lanes plus me were
patch-and-restoring in the **same two worktrees**. One lane got a changed result from a patch that
provably had not applied. **Give each lane its own worktree, or serialise them.**

**5. A greedy multiline regex ate real code.** Same session: `re.S` with `.*?` across a comment block
deleted **six store actions**, and the script reported success. Caught by diffing
`grep -c '^  async '` against HEAD. **Assert a structural invariant (declaration count) after every
bulk edit**, and prefer line-anchored edits.

**6. A suite that could not RUN scored as SURVIVED.** SBDEV-3012's UI half (jest, 2026-08-26): a
rewrite invalidated one mutant's second anchor, so only half of a two-part mutation applied, the file
stopped parsing, jest printed `Test suite failed to run` and **zero `✕` lines** — and the harness read
"no test failed" as "the mutant survived". A fabricated result for a mutant that was never validly
applied. Detect a non-running suite (`"Test suite failed to run" in out or "Tests:" not in out`) and
score it **INVALID**, never as a survival.

**7. The marker was ABSENT, so nothing failed — the worst of the family, because the table looks
complete.** SBDEV-3012, 2026-08-26: a harness reported **0 of 12 mutants killed** while the very same
jest output said `Tests: 4 failed`. **jest prints the per-test `✕ <name>` lines ONLY when given a
SINGLE test file (or `--verbose`); with two or more spec paths it emits `● <suite> › <name>` blocks and
no `✕` at all.** A regex matching `✕` found nothing and scored every mutant as surviving. The only
reason I looked is that 0/12 is not a credible result — had it been 9/12 I would have "fixed" three
imaginary assertion gaps.

**8. The DETECTOR could not see red.** SBDEV-2960's T2 slice, 2026-08-26. Proving the mutant landed is
necessary but **not sufficient** — the thing that reads the result must also be proven able to report a
failure. A harness returned **three consecutive "NOTHING RED — vacuous"** verdicts against mutants that
were definitely fatal (reverting the one-line fix among them). The mutants had landed; the tests were
failing; the harness was blind. Cause: the detector was `jest ... | grep -E "^\s+✕"`, and for that spec
file Jest printed `● suite › test` blocks with **no** per-test `✓`/`✕` list, so the grep matched nothing
whether tests passed or failed. The same grep had worked minutes earlier on a *different* spec file,
which is what made it feel trustworthy.

**9. A COMPILE ERROR counted as a kill — classify compile errors separately or they inflate the kill
count.** ADDENDUM 2026-08-27. Never count a compile error as a kill: **the mutant never executed.**
A mutant that fails to compile produces **no test output at all**, which a harness grepping for
failures reads as a KILL. Hit for real: adding
`Itemdata(Long)` to an `@Entity` removed the implicit no-arg constructor that JPA and every
`new Itemdata()` depend on, so the mutant never compiled — and it reported as a kill until the harness
emitted `COMPILE-ERROR(inadmissible)` as a **THIRD outcome** alongside KILL/SURVIVED. Without that third
bucket an inadmissible mutant silently inflates the kill count. Also assert the build actually compiled
— `grep -q "BUILD SUCCESS"` is **not enough**; check for `COMPILATION ERROR`.

⚠️ **Jest is the most dangerous host for hand-rolled mutation** precisely because there is no compile
step: a half-applied source mutation, an anchor that missed, and an unobserved kill all present
identically as "the suite ran and nothing failed". On the JVM the same mistakes usually fail the build.

## The rule that generalises lies 6–8: never infer "nothing failed" from a missing marker

Parse the authoritative summary count, and cross-check it against the named failures — if the count is
non-zero and you have no names, or you have names and the count is zero, your parse is wrong and you
must refuse to report a verdict:

```python
summary = re.search(r"^Tests:\s+(?:(\d+) failed, )?", out, re.M)
count = int(summary.group(1)) if summary and summary.group(1) else 0
names = [m.strip() for m in re.findall(r"^\s+●\s+(.+?)$", out, re.M)]
if (count > 0) != bool(names):
    return None   # parse disagrees with itself: INVALID, not a survival
```

**Read `Tests:` / `● ` lines, never a `✓`/`✗` glyph grep.** The summary line is emitted by every
reporter configuration; the per-test glyph list is not.

## Harness checklist (if you must hand-roll one anyway)

- `os.utime(f, None)` after patch **and** after restore; `mvn clean` once before the run.
- Require a **green baseline** first — a suite that is already red "kills" every mutant.
- **Run the unmutated tree through the detector and require it to report 0 failures** — a sanity row.
  If the detector cannot distinguish the unmutated baseline from a mutated run, nothing downstream of
  it is evidence.
- End with a **control run** on the restored tree and require green. If a mutant leaked, this is the
  only thing that notices.
- Never count a **compile error** as a kill — the mutant never executed; emit it as a third outcome.
- Assert the patch anchor matched **exactly once**, verified by re-reading the file after the write —
  a silent **no-op patch is a false kill**.
- One worktree per lane, or serialise the lanes.
- Assert a structural invariant (e.g. declaration count) after every bulk edit.
- Smell that catches a blind harness for free: **a mutant that reverts the fix itself MUST go red.**
  If it does not, suspect the harness before believing the result.
- **Corollary:** when a harness declares the test name it expects to kill each mutant, RENAMING a test
  silently turns a real kill into `KILLED-BY-WRONG-TEST`. That is the harness working — but the
  expectations must be re-checked after any test rename, or a genuine regression hides behind a stale
  label.

## Equivalent mutants are not gaps

Also on SBDEV-3012: moving `hidePageSpinner` out of a `finally` block into the line after the `try` is
**semantically identical** when the `catch` swallows, so it can never be killed. I first scored it as a
surviving mutant, i.e. an assertion gap. Before adding an assertion to kill a survivor, check the mutant
actually changes behaviour — otherwise you write a test for nothing.

**But do not just dismiss them: an equivalent mutant is often a signal that the CODE carries a
meaningless value, and deleting that value is the right fix.** Measured on SBDEV-3198 (2026-09-02):
six `return register(...)` call sites each produced a `BooleanTrueReturnValsMutator` survivor, because
`register` could only ever return `true` or throw — so replacing its return with `true` changed
nothing. The survivors were not an assertion gap **and** not noise; they were PIT correctly reporting
that the boolean return conveyed no information. Changing `register` to `void` with an explicit
`return true;` at each call site made all six **observable and killed**, and moved the class from 60 to
**118 mutations, 118 killed**.

**How to apply:** when a survivor turns out to be equivalent, ask *why* it is equivalent before moving
on. "This value can only ever be one thing" is a code smell PIT just found for you for free, and it is
cheaper to delete the value than to explain the survivor in a report. The bad outcome is not writing a
useless test — it is leaving six unkillable mutants in the report permanently, where they are
**indistinguishable from real assertion gaps** for whoever reads it next.

## Mutation-check PASSING pins too — a pin can stay vacuous AFTER the fix

A TDD-gate pin labelled "vacuous pre-fix" is normally expected to become load-bearing once the feature
exists. On **SBDEV-3003 Slice 2** one did **not**, and only mutation-checking *after* implementation
revealed it.

- The pin: "GET on the allow-listed path stays out of scope" — `verifyNoInteractions(service)`.
- The mutant: delete the GET gate from `IdempotencyFilter.shouldNotFilter`.
- **Measured 21/21 GREEN.** With the gate gone the GET request *is* in scope, but it carried no
  `Idempotency-Key`, so it took the *other* fix in the same change — G-b's fail-open branch, which calls
  `chain.doFilter` and returns without touching the service. "No interaction with the service" stayed
  trivially true for a completely different reason than the one the test names.
- Second instance in the same change: no test pinned that G-e's errors-body rule is *scoped* to the
  allow-list. Dropping the scope conjunct also scored **21/21 green** (the verify row caught it; no test
  did).

**Why:** two fixes landing together can each provide the other's exit path. A test that asserts an
*absence* ("nothing happened") cannot tell which mechanism produced the absence. Sibling early returns
are exactly what makes an absence-assertion ambiguous.

**How to apply:** mutation-check every `[pin: vacuous pre-fix]` assertion AFTER implementation, not only
the ones that were red at the gate — being red at the gate is what you already know. For an
absence-assertion, ask "what else in this change could produce this same absence?" and give the test an
input that forecloses those paths (here: send a nonce on the GET, so the fail-open branch cannot be the
reason). Prefer asserting the positive mechanism where possible. **A green pin at gate time is where
vacuity hides — mutation-check the assertions that PASS, not only the ones that fail.**

**And doubt the fix's own test.** The coverage list and the fix list are usually written together, so
they omit the same things. Derive the expected set from the source (I now parse the store module for
gated endpoint paths) rather than hand-maintaining it — that single change caught the five unguarded
bulk actions both lanes found.

## The restore target must be a COMMIT, never the working tree (measured 2026-08-28, SBDEV-3017)

A harness that restores each mutant with `git checkout -- <file>` while the work is **uncommitted**
does not restore the mutant — it reverts to `origin/develop` and **deletes the work**. On SBDEV-3017
tranche 1 this silently wiped **17 annotations** across 4 files on the first mutant, and every mutant
after it ran against the broken tree. **All four reported KILLED; only the first was real.**

Two mechanical rules:

1. **Commit before mutating.** Then `git checkout <sha> -- <file>` restores the *work*. Assert the
   restore is clean (`git diff --name-only -- <file>` is empty) after every mutant, and assert the
   final tree is identical to the baseline sha.
2. **Attribute each verdict by the mutant's OWN diagnostic.** The tell that exposed this: M2's
   failure message quoted **M1's** constant. A harness that greps `head -1` of the failure output
   reports whichever assertion fails first, not the one the mutant broke — so a stale tree reads as a
   clean kill. If a verdict does not name the symbol the mutant touched, it is not a verdict.

This is the same family as the mtime-preserving restore already recorded above: every measured lie
here has come from the RESTORE step, not the mutate step.

**ADDENDUM 2026-09-01 (SBDEV-3176): `git checkout --` fails in BOTH directions, and both bit in one
session.** The rule above covers the tracked-and-uncommitted case. The other half is the mirror image:

- **UNTRACKED file** (a new class you just wrote): `git checkout -- <file>` **silently fails** —
  `error: pathspec '<file>' did not match any file(s) known to git` — and **leaves the mutant in
  place**. It also exits non-zero, which is easy to miss inside a `&&` chain or when the output is
  grepped for test results. Caught only because the next step `md5sum`'d the file against a saved copy.
- **TRACKED, uncommitted-modified file**: it succeeds and **discards the real fix**. Hit on
  `ClientRepository.java` — reverting a mutant took the H-1 fix with it, and the file quietly dropped
  out of `git status`. Caught by grepping for the annotation count right after the restore.

So neither "it's tracked" nor "it's untracked" makes `git checkout --` safe during mutation work. **The
only safe restore is `cp` from an explicit saved copy, verified immediately with `diff -q` or a `grep
-c` on the thing you mutated.** Verify the restore, always — do not infer it from the command
succeeding, and especially not from it producing no output.

A shape pin can rescue this: the `@CacheEvict`-presence test written for an unrelated review finding
would have caught the lost fix at the next full run.

Related: [[green-tests-that-prove-nothing]], [[junit-reflection-test-vacuous-when-list-is-empty]],
[[verify-never-is-vacuous-if-control-flow-cannot-reach-it]],
[[transactional-tests-blind-to-propagation-and-readonly]],
[[idle-review-subagent-is-not-a-passing-review]], [[sbdev-3003-slice2-transfer-stock-idempotency]],
[[wms2-develop-preexisting-test-failures]]. (One source also carried a mistyped self-link,
[[a-mutation-harness-must-prove-the-mutant-hit-its-target]] — kept here so it stays traceable.)

Provenance: merged from memories originating in sessions `74e9ade3-54f9-40c9-b7fd-5f0d8ec80cce`
(recompile + interlocking-pin) and the SBDEV-2967-C / SBDEV-3102 review sessions.

**PIT itself lies if you skip `test-compile`.** Measured 2026-09-06 (SBDEV-3241): after adding two
`verify(jobMetrics)` assertions, `mvn -o org.pitest:pitest-maven:mutationCoverage` reported
**"Generated 102 mutations Killed 17"** — byte-identical to the pre-assertion run, with the same
mutants still SURVIVED. It had mutated against stale `target/test-classes`. Running
`mvn -o test-compile` first gave "Killed 19" and the two mutants flipped to KILLED. **The tell is an
identical mutation score across a real source change** — treat that as a broken instrument, never as
"my assertion didn't help". Same family as [[mvn-without-clean-runs-deleted-tests]].


**ADDENDUM 2026-09-09 (SBDEV-3255): I hit the `git checkout --` trap AGAIN, with this memory already
written, and the thing that caught it was a COUNT, not reasoning.** The harness restored each mutant
with `git checkout -- $T` while the work was uncommitted — the exact case the section above forbids —
so mutant 1 (a real kill) was followed by the restore silently deleting the fix, and mutant 2 then ran
against the ORIGINAL vacuous test and reported SURVIVED. A survivor is the plausible-looking outcome,
so nothing about it invited suspicion.

**The tell, and the cheap rail:** the script echoed `tracked-modified=$(git status --porcelain | wc -l)`
after each restore. It printed **5** where the change touched **6** files. That one number is the whole
detection. So: **print the modified-file count after every restore and assert it against the expected
value**, and add a **PRE-CHECK before each mutant** asserting the thing you are about to mutate is still
present (`grep -c '<the fix>'` = 1). Both are one line; together they make this failure impossible to
ship, which reading the prose above evidently did not.

Generalises the section's own conclusion: **every measured lie in this file came from the RESTORE step**,
and the defence is a cheap machine-checked invariant around it, not a remembered rule.

## Tenth mechanism: `git checkout --` as the "restore" step deletes your whole change

Measured 2026-09-09 on SBDEV-3287, in v1/wms-api where PIT is not wired up so the mutation had to be
hand-rolled. The loop was `sed` in the mutant → run → `git checkout -- $FILE` to restore. That
restores the file to **HEAD**, not to its pre-mutant working state, so it silently discarded every
edit the session had made to that file — the new repository method, the javadoc, all of it.

The verification step made it worse rather than catching it: `git diff --stat -- $FILE | wc -l`
printed **0**, which reads as "restored cleanly" and actually meant "identical to HEAD, i.e. your work
is gone". A check against the wrong reference is not a check.

**Restore from a copy you took yourself, and diff against that copy:**

```bash
cp "$FILE" "$BK/file.java"          # before the mutant
...                                  # mutate, run, read the kill message
cp "$BK/file.java" "$FILE"          # restore
diff -q "$BK/file.java" "$FILE"     # verify against the COPY, never against HEAD
```

Same session, an eleventh way to get a silent no-op: a `perl -0777 -pi -e 's/.../.../'` mutation whose
regex did not match printed nothing and exited 0, so the run that followed graded **unmutated** code
and would have been recorded as a surviving mutant. Assert the anchor matched before running:

```python
assert s.count(old) == 1, "anchor count=%d -- mutation NOT applied" % s.count(old)
```

Both belong to the same family as everything above: **the mutation step needs its own positive
control** ([[a-zero-scan-needs-a-positive-control]]). Print "mutant APPLIED" only after proving the
file actually changed, and never infer it from the tool's exit code.
