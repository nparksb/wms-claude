---
title: SBDEV-3241 review — PR #313 FINAL state (both commits, shrink 16→10)
ticket: SBDEV-3241
reviewer: review-pr313-final (independent lane)
date: 2026-09-07
worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3241-seq
branch: bugfix/SBDEV-3241-sequence-tx-tests
commits: 81165424 (repair, previously reviewed) + 96494339 (shrink, NEVER reviewed)
scope: 1 file, +54/−128 vs origin/develop
verdict: MERGE AS-IS. 0 High. 2 Medium, 7 Low — none blocking.
---

# SBDEV-3241 — review of the FINAL state of PR #313

Read-only review. No git state changed (`git status --short` clean at every checkpoint).
Maven WAS run in this worktree, one invocation at a time: `test-compile`, the test class,
two source mutants (applied then restored byte-for-byte), two PIT runs, and the full unit suite.

---

## 0. Verdict

**Merge as-is.** The shrink commit `96494339` is correct. Every claim the author made about it
that I could test, I tested, and each one holds:

| Author's claim | My re-derivation | Result |
|---|---|---|
| 10 methods → 14 executions; `$EdgeCases` 6, `$GetNextSequenceNumber` 8 | ran the class | **CONFIRMED exactly** |
| all five `@MethodSource` cases execute | surefire XML lists `[1]`…`[5]` | **CONFIRMED** |
| the parameterized test asserts MORE than the five it replaced | mutant on the service | **CONFIRMED — and provably so** |
| `shouldHandleConcurrentAccessSimulation` was a duplicate | read both bodies | **CONFIRMED** |
| `shouldPersistChangesToDatabase` could not fail | read the body + `equals()` | **CONFIRMED** |
| PIT 7/7 KILLED before and after | ran PIT on both commits | **CONFIRMED (7/7 both)** |
| `classname` is `varchar(255) NOT NULL` and the PK | read the migration | **both facts TRUE; the line citation for the PK half is WRONG** |

The two Medium findings are both *residue* — things the shrink should have swept while it was in
the file, not defects it introduced. The change is a strict improvement over `81165424`.

---

## 1. Q1 — is the `@ParameterizedTest` correct, and does it really run five cases?

**Yes. Verified by execution, not by reading.**

```
[INFO] Running …SequenceTransactionServiceUnitTest$EdgeCases
[INFO] Tests run: 6, Failures: 0, Errors: 0, Skipped: 0
[INFO] Running …SequenceTransactionServiceUnitTest$GetNextSequenceNumber
[INFO] Tests run: 8, Failures: 0, Errors: 0, Skipped: 0
[INFO] Tests run: 14, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

6 + 8 = 14, exactly the numbers the author reported. And the five invocations are individually
present in the surefire XML, so this is not a `@MethodSource` that silently resolved to nothing:

```
$ grep -o 'testcase name="[^"]*"' target/surefire-reports/TEST-…$EdgeCases.xml
testcase name="shouldHandleNegativeSequenceNumbers"
testcase name="unrecognisedKeyCreatesSequenceAtZero(String, String)[1]"
testcase name="unrecognisedKeyCreatesSequenceAtZero(String, String)[2]"
testcase name="unrecognisedKeyCreatesSequenceAtZero(String, String)[3]"
testcase name="unrecognisedKeyCreatesSequenceAtZero(String, String)[4]"
testcase name="unrecognisedKeyCreatesSequenceAtZero(String, String)[5]"
```

The `@Nested` + `static Stream<Arguments>` combination that the lead flagged as a silent-skip risk
resolves correctly here: `junit-jupiter` is the aggregate artifact (`pom.xml:342-343`), so
`junit-jupiter-params` is on the classpath, and a static factory inside an inner class is legal on
Java 21 and is what JUnit looks up first for a `@MethodSource` with no class qualifier.

**Note on how you run it.** `mvn surefire:test -Dtest=…` standalone **fails** here with
`The forked VM terminated without properly saying goodbye` — surefire's `<argLine>` carries jacoco's
late-binding `@{argLine}` (`pom.xml:536`), which is unresolved outside the lifecycle. Use
`mvn -o test -Dtest=…`. This is a false red waiting to happen for the next reviewer; it is a pom
property, not a defect in this PR, and I mention it only so the number above is reproducible.

---

## 2. Q2 — does it cover what the five it replaced covered?

**Yes, and the "asserts MORE" claim is not just plausible — it is demonstrated.**

The five deleted tests each asserted exactly one thing: `assertThat(result).isEqualTo(0L)`.
`result` is `returnSeq`, which the service (`SequenceTransactionService.java:25,37,40`) initialises
to `0L` and never touches on the not-found branch. So **no assertion in any of the five could
observe what the service wrote into the entity.**

The replacement adds two captor assertions that can:

```java
assertThat(saved.getValue().getClassname()).isEqualTo(key);       // stored verbatim
assertThat(saved.getValue().getSequencenumber()).isEqualTo(0L);   // seeded at 0
```

**Mutation check (the real evidence).** I mutated the service —
`seq.setSequencenumber(returnSeq)` → `seq.setSequencenumber(1L)` at line 37 — and re-ran:

```
Tests run: 14, Failures: 6
  EdgeCases.unrecognisedKeyCreatesSequenceAtZero:250 [the seeded row must start at 0, not at 1]   ×5
  GetNextSequenceNumber.shouldCreateNewSequenceWhenNotFound:117
```

All five parameterized cases go red. **The five tests they replaced would all have stayed green
under that mutant**, because none of them looked at the saved entity. The collapse therefore
*increased* discriminating power 5×, exactly as claimed. (Service file restored byte-for-byte;
`git status --short` empty.)

### 2.1 Was anything silently dropped? Specifically the `save(...)` stub

Each of the five old tests carried
`when(losSequencenumberRepository.save(any())).thenAnswer(inv -> inv.getArgument(0))`.
The new test drops it entirely. **This is safe and is an improvement:**

- The service discards `save`'s return value (`SequenceTransactionService.java:39-40`), so the echo
  answer configured a value nobody read.
- The new test reads the *argument* via `ArgumentCaptor`, not the return, so the echo is
  unnecessary.
- Empirically: 14/14 green with no stub, and 5/5 red under the mutant — the captor path works.

This also closes the earlier lane's §F8 for these five.

**Nothing was dropped.** The one property the five genuinely pinned — that the service passes `key`
through unmodified, enforced by STRICT_STUBS on an exact-value stub — is preserved, and is now
additionally pinned by a *named assertion* (`"the key must be stored verbatim"`) rather than only by
a stubbing error.

---

## 3. Q3 — were the two deletions justified?

**Both yes. Judged independently from `git show 81165424:…`, not from the author's summary.**

### 3.1 `shouldHandleConcurrentAccessSimulation` — genuine duplicate. Deletion correct.

Diffed against the surviving `shouldHandleMultipleIncrementsCorrectly` (now lines 120-138): same
arrange, same shared mutable `testSequence`, same three sequential calls, same `101/102/103`
assertions. The only deltas are the key literal (`"CONCURRENT_KEY"` vs `"TEST_KEY"`) and two extra
lines:

```java
assertThat(result1).isNotEqualTo(result2);
assertThat(result2).isNotEqualTo(result3);
```

AssertJ assertions are hard, so control only reaches those lines after `101`, `102` and `103` have
already been pinned — at which point `101 != 102` is a tautology. Confirmed: zero discriminating
power.

The name was also actively harmful. One thread, a Mockito mock, no lock, no transaction: nothing in
that method touches `@Lock(PESSIMISTIC_WRITE)` (`LosSequencenumberRepository.java:25`) or
`@Transactional(REQUIRES_NEW)` (`SequenceTransactionService.java:23`). The real concurrency proof is
`integration/service/SequenceTransactionServiceConcurrencyIT` ("SBDEV-2217 AC-4", 50×100 threads).
Removing a unit test called "concurrent access simulation" removes a standing invitation to believe
concurrency is unit-covered. **Good deletion.**

### 3.2 `shouldPersistChangesToDatabase` — genuinely unable to fail. Deletion correct.

Its whole assertion was `assertThat(captor.getValue()).isEqualTo(testSequence)`. Three independent
reasons that cannot fail:

1. On the found branch the service saves *the very instance the stub returned* — reference
   identity, so `isEqualTo` passes trivially.
2. Even without identity it would pass on anything: `LosSequencenumber.equals()`
   (`model/LosSequencenumber.java:48-53`) compares **classname only**.
3. Its fixture was incoherent — it stubbed the key `"PERSIST_KEY"` but handed back `testSequence`,
   whose classname is `"TEST_KEY"`, and passed anyway.

And it never asserted the change its name promised: the captured entity's `sequencenumber` is never
checked. That behaviour is asserted by `shouldUpdateSequenceNumberInDatabase` (line 81), and the
"save was called with the object we read" property by `verify(…).save(testSequence)` (line 65).

**No unique coverage lost.** Corroborated independently by PIT: the mutation score is identical with
and without it (§4).

---

## 4. Q4 — re-deriving the PIT evidence, and what it is worth

**The number reproduces. The argument built on it is weaker than the author implies — but the
conclusion survives on other evidence, so this is not a blocker.**

I ran `mvn -o test-compile` **first** on each side (the stale-`target/test-classes` trap the lead
warned about), then PIT scoped to the class:

| Tree | Result |
|---|---|
| `96494339` (HEAD, 10 methods) | `Generated 7 mutations Killed 7 (100%)` |
| `81165424` (16 methods) | `Generated 7 mutations Killed 7 (100%)` |

The seven mutants, from `target/pit-reports/mutations.xml`:

| Line | Mutator | Status |
|---|---|---|
| 32 | MathMutator (`+` → `-`) | KILLED |
| 33 | MathMutator (`+` → `-`) | KILLED |
| 29 | NegateConditionals (`isPresent()`) | KILLED |
| 32 | VoidMethodCall (`setSequencenumber`) | KILLED |
| 36 | VoidMethodCall (`setClassname`) | KILLED |
| 37 | VoidMethodCall (`setSequencenumber`) | KILLED |
| 40 | EmptyObjectReturnVals (`return returnSeq`) | KILLED |

**Judging the argument.** "Same score" is **necessary but not sufficient**. It shows the six removed
methods killed nothing that the survivors do not already kill — which is real, and it is the exact
question you would ask before deleting tests. But it establishes nothing about coverage PIT cannot
see, and here PIT is blind to the two things SBDEV-2217 actually changed:

- **The finder choice is not in the mutant set at all.** `DEFAULTS`' `VOID_METHOD_CALLS` removes
  calls to **void** methods only. Both repository calls return values —
  `findByClassnameForUpdate(key)` returns `Optional<…>` (line 28) and `save(seq)` returns `S`
  (line 39) — so PIT generated **zero** mutants for either. Confirmed empirically: no line-28 or
  line-39 entry in the XML above. The lead's suspicion is correct.
- The `@Lock(PESSIMISTIC_WRITE)` annotation lives on a different type, outside `targetClasses`.
- `@Transactional(REQUIRES_NEW, "tenantTransactionManager")` is an annotation, and `@InjectMocks`
  builds the bean with no Spring proxy, so it is structurally unobservable from this class.

So the honest statement of the PIT evidence is: *"the arithmetic, the branch, and the entity
mutation are covered by assertions on both sides, and the deletions took none of that away."* It is
**not** "nothing was lost". The thing that actually establishes nothing was lost is the by-hand
subsumption argument in §2 and §3, which I re-derived independently and which holds. Also worth
noting: on HEAD, PIT credits the *parameterized test* with killing the line-36 and line-37 mutants
(`test-template-invocation:#4`) — that is first-killer ordering, not exclusivity;
`shouldCreateNewSequenceWhenNotFound` still kills them too.

### 4.1 A second mutant PIT cannot generate — and what it exposes

I reverted line 28 to the pre-SBDEV-2217 `findByClassname(key)`:

```
Tests run: 14, Failures: 7, Errors: 7
  … × 7  » UnnecessaryStubbing
  … × 7  wrong-value assertion failures
```

**14/14 red — but via `UnnecessaryStubbingException`, not a named expectation.** That is precisely
the failure signature that got this class written off as "pre-existing failures, unrelated" for five
months before being `@Disabled`. The earlier lane recommended two lines to convert it into a named
failure (its §F5); the shrink did not apply them. See **M2** below.

---

## 5. Q5 — the javadoc's schema claims

Both **facts** are true. One **citation** is wrong.

| Claim | Verdict | Evidence |
|---|---|---|
| `classname` is `character varying(255) NOT NULL` | **TRUE** | `V2.2.00__base_v2_schema.sql:1359` — inside the cited range |
| `classname` is the PRIMARY KEY | **TRUE** | `V2.2.00__base_v2_schema.sql:3392-3396`: `ALTER TABLE ONLY public.los_sequencenumber ADD CONSTRAINT los_sequencenumber_pkey PRIMARY KEY (classname);` |
| both are at `V2.2.00__base_v2_schema.sql:1358-1362` | **FALSE for the PK half** | lines 1358-1362 are the bare `CREATE TABLE` body; they contain no `PRIMARY KEY` token |

Lines 1358-1362 verbatim:

```sql
CREATE TABLE public.los_sequencenumber (
    classname character varying(255) NOT NULL,
    sequencenumber bigint NOT NULL,
    version integer NOT NULL
);
```

The earlier lane cited **both** locations (`:1358-1362` *and* `:3396`); the author dropped the
`:3396` half while keeping the PK assertion. Fix is one token — see **L1**. The conclusion the
javadoc draws (null and 1004-char are unreachable in production) is **correct on the merits**: null
is rejected by `NOT NULL` regardless of the PK, and 1004 chars by `varchar(255)`.

**Live-DB verification: NOT OBTAINED.** I tried `wms2-hydra` (prd) and `wms2-wineco-dev`. Both
failed, and the failure is instrument-side, not a data answer — the positive control `SELECT 1`
itself timed out after 30s on hydra, and wineco-dev could not get a connection. So these claims rest
on the migration file, which I read directly. Recorded as a gap, not as a confirmation.

---

## 6. Q6 — do the earlier lane's "default-answer" tests survive among the 10?

**Five of the six were fixed. One survives.**

The earlier lane's §F4 named six tests whose only assertion (`assertThat(result).isEqualTo(0L)`) is
satisfied by Mockito's default `Optional.empty()` even if the finder were never called:
`shouldReturnZeroWhenSequenceDoesNotExist` plus the five key-shape tests.

- **The five key-shape tests: FIXED.** The parameterized replacement adds captor assertions that no
  default answer produces. Proven — all five went red under the line-37 mutant (§2).
- **`shouldReturnZeroWhenSequenceDoesNotExist` (lines 84-98): NOT FIXED.** Proven by the same run:
  under the line-37 mutant it stayed **green** while every other not-found test went red. It is the
  one remaining test in the file whose written assertion cannot distinguish "called the locking
  finder and got empty" from "called nothing". See **M1** — it is also now strictly subsumed.

---

## 7. Q7 — stale references

**Clean.** `grep -n "2099\|2217\|Disabled\|findByClassname(\|[Cc]oncurrent\|[Pp]ersist"` over the
changed file returns nothing. Both `@Disabled` blocks and the `Disabled` import are gone. The import
list (lines 3-23) is exactly the used set — the three new `org.junit.jupiter.params.*` imports and
`java.util.stream.Stream` are all consumed, and nothing left over from the deletions. A repo-wide
`git grep` for the seven removed method names finds no reference anywhere (one unrelated hit,
`ViewDtoServiceUnitTest.java:838 shouldHandleSpecialCharactersInKeyword`, different class, different
name). The class javadoc (lines 25-28) was generic and remains accurate.

---

## 8. Findings

No High. The change is correct and I would merge it.

### M1 — MEDIUM — `shouldReturnZeroWhenSequenceDoesNotExist` is now both vacuous *and* strictly subsumed; delete it

Lines 84-98. Two independent reasons, one of which is new to this commit:

1. **Vacuous** (carried over from the earlier lane's §F4, un-swept). Its only assertion is
   `assertThat(result).isEqualTo(0L)`, which Mockito's default `Optional.empty()` satisfies with or
   without the finder call. **Measured:** it was the only not-found test still green under the
   line-37 mutant.
2. **Newly redundant.** The parameterized test now asserts `result == 0L` **plus** the captured
   classname **plus** the captured sequencenumber, for five keys. This test is a strict subset of
   parameter case 2 (`""`) modulo the key literal.

It also still carries the `thenAnswer(inv -> inv.getArgument(0))` save stub the shrink removed
elsewhere, so the file is now internally inconsistent about whether that stub is needed.

**Fix:** delete it (10 → 9 methods). Same standard the author applied two `@Nested` classes down.

### M2 — MEDIUM — the SBDEV-2217 lock choice is still protected only by an error type, and the shrink was the moment to fix it

The earlier lane's §F5 recommended two lines in the happy-path test. They were not applied, and
§4.1 above measures the consequence: a revert of `SequenceTransactionService.java:28` to
`findByClassname` turns the class 14/14 red — but 7 of those are `UnnecessaryStubbingException`,
i.e. the exact signature that got this class dismissed as "pre-existing failures … unrelated" across
four archived plan docs and then `@Disabled` for five months.

PIT structurally cannot cover this (§4: no mutant is generated for either repository call). Two
lines in `shouldReturnIncrementedSequenceWhenSequenceExists` convert an obscure stubbing error into
a named expectation:

```java
verify(losSequencenumberRepository).findByClassnameForUpdate("TEST_KEY");
verify(losSequencenumberRepository, never()).findByClassname(any());
```

The `never()` line earns its keep specifically because `findByClassname` is still declared
(`LosSequencenumberRepository.java:22-23`) and still has a live production caller
(`LabelPrintingService.java:968`), so an accidental revert compiles cleanly. (The
`never()`+`any()` primitive-unboxing trap does not apply — the argument is a `String`.)

Not a defect the shrink introduced; a defect it walked past. Given the PR's stated purpose is
"make this class say true things", this is the highest-value two lines available.

### L1 — LOW — the javadoc's PK citation points at the wrong lines

`SequenceTransactionServiceUnitTest.java:223-224` asserts `classname` is
`varchar(255) NOT NULL` **and the PRIMARY KEY**, citing only
`V2.2.00__base_v2_schema.sql:1358-1362`. That range covers the column definition but not the PK,
which is declared at `:3392-3396`. Both facts are true; the pointer is half wrong.

This matters more than a normal miscitation because the javadoc's entire subject is *"the old test
names claimed things that are not true."* A reader who checks the citation finds no `PRIMARY KEY`
there and has to go looking. **Fix:** `(V2.2.00__base_v2_schema.sql:1358-1362 and :3396)`.

### L2 — LOW — `shouldCreateNewSequenceWhenNotFound` is now also subsumed by the parameterized test

Lines 100-118. Its two captor assertions (`classname == "NEW_KEY"`, `sequencenumber == 0L`) are
exactly the two the parameterized test now makes, for five keys. PIT agrees they are
interchangeable: on HEAD it credits the parameterized test with the line-36/37 kills.

Unlike M1 this one is *not* vacuous, so keeping it as the canonical happy-path new-key test in the
`GetNextSequenceNumber` group is defensible for readability. Flagged for consistency only —
applying the shrink's own standard uniformly would take the file to 8 methods. **Author's call; no
action required.**

### L3 — LOW — five consecutive blank lines left where the deleted tests were

Lines 262-267. Whitespace residue from the deletion, visible in the diff as bare context. Cosmetic.

### L4 — LOW — surefire reports the parameterized cases as `[1]`…`[5]`, not by label

`@ParameterizedTest(name = "{0}")` renders the label in JUnit's display name, but the surefire XML
records `unrecognisedKeyCreatesSequenceAtZero(String, String)[1]` (verified above). A CI failure
will therefore name `[3]` rather than "special characters", and the reader must count the
`Stream.of(...)` entries. Harmless; noted so nobody is surprised.

### L5 — LOW — dropping the `save` stub trades a clean assertion failure for a future NPE

Correct today (§2.1), because the service ignores `save`'s return. But if anyone later writes
`return save(seq).getSequencenumber()`, the parameterized test fails with an NPE inside the service
rather than a named assertion. One line —
`when(…save(any())).thenAnswer(inv -> inv.getArgument(0))` — would future-proof it, at the cost of
re-adding the dead stub the shrink deliberately removed. **Recommend leaving as-is;** recorded
because it is the one thing the deletion genuinely changed about failure *shape*.

### L6 — LOW — the new DisplayName still asserts a production behaviour the project's own IT calls broken

`"an unrecognised key of any shape creates a new sequence at 0"`. The javadoc carefully explains why
two *key shapes* are unreachable, but not that the whole not-found branch is contested:
`SequenceTransactionServiceConcurrencyIT.java:101-103` states in its own comment that the test seeds
a row specifically so the service *"never hits the new-key insert path (which would fail under
@Version constraint)"*, and `LosSequencenumber.java:11-18` puts
`@GeneratedValue(strategy = SEQUENCE)` on a **String** `@Id`.

Two caveats keep this at Low rather than Medium. First, the IT's claim and the service's actual path
may not agree — the service constructs the entity with `version == null`, which is the *isNew* case,
so `save()` should `persist()`; the IT's workaround is about seeding with `version = 0`, a different
situation. Second, the branch is not dead: while ~20 keys are seeded at migration time
(`V2.2.00__base_v2_schema.sql:2559ff`), the label-sequence callers pass **sysprop-configured** names
(`BillofladingService.java:821`, `LabelPrintingService.java:337`,
`OrderMonitorViewService.java:180`, `ParcelMonitorViewService.java:113,285`), which need not be in
the seed list.

Pre-existing, out of scope for a test-only PR, and already recorded by the earlier lane as §F6
("propose, do not file"). **No action in this PR.** Recorded here only because the shrink's stated
purpose was removing names that claim more than is true, and this name is in that family.

### L7 — LOW — `mvn surefire:test -Dtest=…` is a false-red trap for the next reviewer

`pom.xml:536` puts jacoco's late-binding `@{argLine}` in surefire's `<argLine>`. Invoking the
surefire goal directly leaves it unresolved and the fork dies with *"The forked VM terminated
without properly saying goodbye"* — which reads as a crash in the code under test. Use
`mvn -o test -Dtest=…`. Pre-existing pom property, not this PR's doing.

---

## 9. Would I merge as-is?

**Yes.** `96494339` does what it claims, the evidence I could re-derive all reproduced, and every
one of the three coverage-removal claims survives independent scrutiny — two by reading, one by a
mutation experiment that also proved the replacement is 5× stronger than what it replaced.

M1 (delete a vacuous, now-subsumed test) and L1 (one wrong line citation) are three lines of work
and, per the standing "address Low findings too" rule, are worth doing in this pass rather than
filing. M2 is the highest-value change available in this file but is a *scope addition* — it adds
coverage rather than repairing this commit — so it belongs on the existing SBDEV-3241 ticket
(sub-T3, ticket not yet `on dev`) if it is not done here, not in a new one.

None of the nine findings block the merge.

## 10. What I did not verify

- **No live-DB confirmation of the schema.** Both MCP endpoints failed their positive control
  (`SELECT 1` timed out on hydra; wineco-dev could not connect), so the `varchar(255) NOT NULL` and
  PK claims rest on `V2.2.00__base_v2_schema.sql` read directly, not on a running database.
- Did not run the failsafe/IT lane; `SequenceTransactionServiceConcurrencyIT` was read, not
  executed.
- Did not re-run PIT across the whole module — only `targetClasses=net.aim_ai.wms.service.SequenceTransactionService`.
- The full unit-suite result is recorded in §11.

## 11. Full unit suite

Run on `96494339` after a `clean test-compile` (so no stale `target/test-classes`), single Maven
invocation, nothing else touching this worktree:

```
[WARNING] Tests run: 6316, Failures: 0, Errors: 0, Skipped: 10
BUILD SUCCESS   (exit 0)
```

1690 test classes started. The 10 skips are pre-existing conditional skips unrelated to this change
(`TenantPoolEndpointSecurityTest` ×1, `ClientRepositoryIntegrationTest$GetTransactionDetailSmokeTest`
×2, `KeycloakServiceTest` ×3, `CustomerOrderControllerH2Test` ×2, `ReplenishOrderControllerH2Test`
×2) — none is in `SequenceTransactionServiceUnitTest`, which contributes 14 executions, 0 skipped.

Working tree confirmed clean (`git status --short` empty) after every mutation experiment and at the
end of the review; HEAD still `96494339`.
