---
name: green-tests-that-prove-nothing
description: "Assertions that pass while proving nothing in wms2-api — STRICT_STUBS is already the default (88% of files) so LENIENT is an opt-OUT; PotentialStubbingProblem gets swallowed and suppresses the dead-stub report entirely; and never()/for-each/reflection pins go vacuous when control flow cannot reach them"
metadata:
  node_type: memory
  type: reference
---

Supersedes and merges six earlier memories — old slugs kept here so stale links stay traceable:
[[mockito-strict-stubs-is-already-the-default]],
[[mockito-suppresses-dead-stub-report-after-arg-mismatch]],
[[lenient-census-grep-confounded-by-own-javadoc]], [[dead-stub-in-negative-test-arms-the-trap]],
[[junit-reflection-test-vacuous-when-list-is-empty]],
[[verify-never-is-vacuous-if-control-flow-cannot-reach-it]].
Companion file: [[mutation-harness-traps]] — how to run the mutation check that exposes these, and why
a hand-rolled harness will lie to you about the result.

---

# Part 1 — Mockito stubbing

## `Strictness.STRICT_STUBS` is already the DEFAULT; LENIENT files are opt-OUTs

Measured 2026-08-26 on wms2-api `be3411ca` (mockito-junit-jupiter **5.17.0**), during SBDEV-3102 slice A.

`MockitoExtension()` calls `this(Strictness.STRICT_STUBS)`, and `beforeEach` resolves the annotation
with `...orElse(strictness)`. Proven empirically, not just read: a dead stub injected into
`TimezoneServiceUnitTest` — which carries **no `@MockitoSettings` at all**, only
`@ExtendWith(MockitoExtension.class)` — failed with `UnnecessaryStubbingException`.

**So the counts everyone quotes are misleading.** SBDEV-3102's description says "LENIENT in 47 of 365
classes; STRICT_STUBS in 0", which reads as *the repo is lenient*. Census: **346 of 393 files with
`@Test` (88%) were already strict**; only 47 carry any `@MockitoSettings`. The LENIENT files are
explicit **opt-OUTs** of a strict default — a worse story than "strictness was never adopted", and
exactly why SBDEV-3089's 9 dead stubs hid in `MobilePalletizingServiceTest` for a month, and why
SBDEV-3119's `findById(null)` walk shipped (`UnitloadServiceUnitTest` was lenient; an unstubbed
`Optional` method returns `Optional.empty()`, so the walk exited cleanly in the test).

**Practical consequences**

- A new test class needs **no annotation** to be strict. Adding `@MockitoSettings(STRICT_STUBS)` is
  documentation, not behaviour. `LENIENT` is the only value that changes anything.
- `@MockitoSettings` resolves **up the enclosing-class chain** (`retrieveAnnotationFromTestClasses`),
  so a class-level value reaches `@Nested` inners. Load-bearing in this repo — most service tests keep
  their tests in `@Nested` classes, so a mutation check placed on a flat method proves nothing about
  them. **Mutate inside a `@Nested` method.**
- **Two different exceptions, two different axes.** `UnnecessaryStubbingException` = dead stub, raised
  per **test method** at session end (so it structurally cannot depend on test ordering).
  `PotentialStubbingProblem` = argument mismatch at call time. A method **never stubbed at all** still
  returns `null`/`Optional.empty()` silently even under STRICT_STUBS — **the trigger is the mismatch,
  not the absence.**
- ⚠️ **`PotentialStubbingProblem` gets swallowed by production catch blocks** and then shows up as a
  *missing `verify()`*, not an error. Measured: **40** swallowed by `ReplenishOrderJob`'s per-tenant
  catch, **3** by `ReturnAdviceAutoReceiveService`, **1** by `MobilePickingService`. **Surefire XML
  showed ZERO `PotentialStubbingProblem` at testcase level while the log showed 114** — grep the log,
  not the XML, or you will misclassify these as assertion bugs.
- **Shared `@BeforeEach` stubs are a trap under strictness.** A class can be green-on-flip and still
  break the *next* author: `OrderReleaseJobStreamingTest:78-97` had 7 non-lenient shared stubs against
  2 tests, both of which drove the full path. A third test on an early-return path fails pointing at
  stubs it never wrote, and the exception advises removing them — which breaks the other two. Wrap
  shared setup in `lenient()` (idiom already at `PutawayConfigServiceUnitTest:115`,
  `ReceivingControllerUnitTest:104`). Check for this shape before flipping any class.

**Flip-all measurement** (all 46 LENIENT → STRICT_STUBS, full suite): 5653 tests — unchanged —
**330** methods on `UnnecessaryStubbingException` across **251 unique dead-stub sites** + **42**
substantive. ⚠️ Do NOT quote "990" — that counts repeated log occurrences (each exception block
re-lists its sites, stack frames repeat); dedupe by `(file, line)`.
**16 classes flip clean, 30 need cleanup.** Of the 42 substantive, **none is a production defect**;
**61 of 68 argument mismatches are one fixture pattern** — partial `syspropService.getSysvalue`
stubbing. So the cleanup is far more tractable than a raw stub count reads. Slice A = the 16 clean
classes, PR #213.

## An arg mismatch SUPPRESSES the dead-stub report entirely

Measured 2026-08-27 on wms2-api `d2a7da47` (Mockito 5.17.0) during SBDEV-3102 slice B.

**Mockito suppresses the unnecessary-stubbing report for a stubbing that already had a
`PotentialStubbingProblem` (argument mismatch) reported against it.** So a dead stub of that shape
produces **no `UnnecessaryStubbingException` and a green build, even under `STRICT_STUBS`**.

Worked example — `MobilePickingServiceUnitTest` (carries **no** `@MockitoSettings`, so already on the
strict default, and green on develop):

- The test stubs `sectionRepository.findById(anyLong())` to throw `EntityNotFoundException`.
- The fixture never set `sectionId`, so production called `findById(null)`.
- **`anyLong()` does not match `null`** → `PotentialStubbingProblem`.
- `MobilePickingService` catches it into its "Tx-2 failed, releasing claim" compensation path.
- The test's compensation assertions all pass. Result: **103/0/0 BUILD SUCCESS, 0 UnnecessaryStubbing,
  2 PotentialStubbingProblem** — a test green off a *harness* error rather than the domain exception it
  is named for.

**Consequence for any dead-stub census.** Counting `UnnecessaryStubbingException` sites
(`-> at …(File.java:NN)` lines in the surefire log) undercounts: it misses every dead stub whose method
is called with non-matching args and whose `PotentialStubbingProblem` is swallowed by a broad
`catch (RuntimeException | Exception)` in the production code under test. **That is the higher-value
category** — it yields a falsely-green test rather than a merely redundant line. To find them, grep the
*log* for `PotentialStubbingProblem`, and separately grep services under test for broad catches.
⚠️ **Surefire XML is useless for this**: 114 occurrences in the log vs **ZERO** at testcase level in the
XML, because the swallowed ones never fail a test.

## `lenient()` vs deletion — measure consumption first

- **Zero consumption in a POSITIVE test → delete.** `FileImportControllerTest:165` was dead in **6 of
  6** tests, so `lenient()` would have preserved a stub protecting nothing while reading as "some test
  needs this". Correct verdict was deletion — and deleting the mock-`SecurityContext` *binding*
  alongside it removed the source of the SBDEV-2870 cross-class leak, not just its symptom.
- **Zero consumption in a NEGATIVE test → keep it, as `lenient()`.** See Part 2.
- **Partial consumption → `lenient()`.**

## The census grep counts its own javadoc

On SBDEV-3102 slice B batch 4 the post-flip census came back **30**, one HIGHER than the pre-flip 29,
immediately after I flipped a class off LENIENT. Nothing had regressed. The metric SBDEV-3102 tracks
progress with is `grep -rl Strictness.LENIENT src/test/java`, i.e.
`grep -rl "Strictness.LENIENT" src/test/java | wc -l` — `-l` counts **files containing the string**, and
the class javadoc I had just written to explain the flip said "flipped from `{@code Strictness.LENIENT}`
to `{@code STRICT_STUBS}`". The file matched its own documentation.

**Why it is worse than a cosmetic slip.** The ticket reports slice progress with that number. Every
batch that documents its flip in prose makes the census under-report by one, and since documenting the
flip is exactly what I do on every batch, the figure would have frozen while the work continued — the
failure mode looks like "no progress", not like "broken metric".

**Two fixes, apply both.**
1. In a flipped class's javadoc write **LENIENT** bare, never the qualified `Strictness.LENIENT`.
2. Count with the annotation-precise pattern:
   `grep -rl '@MockitoSettings(strictness = Strictness.LENIENT)' src/test/java | wc -l`

Verified: batches 1 and 3 are unaffected (neither flipped file mentions the qualified name), so the
`30 → 29` figures already reported on those PRs are correct. Only batch 4 hit it, and only because I
wrote a more thorough javadoc than the earlier batches.

**Generalisation:** a grep-based progress metric measures TEXT, so any prose that discusses the thing
being counted is indistinguishable from the thing itself. Same family as
[[verify-script-over-tempered-gap-and-comment-satisfied-negatives]] — where a *comment* satisfied a
negative grep — and [[verify-rows-cannot-assert-policy-only-jest-can]]. (Both of those verify-script
slugs were folded into [[verify-script-traps]] in the same 2026-08-28 consolidation.) When a metric
moves the wrong way, suspect the metric before the work.

---

# Part 2 — Assertions that are vacuous

## A dead stub in a NEGATIVE test is load-bearing BECAUSE it is dead — it arms the trap

SBDEV-3102 slice B batch 4, `PickingorderBusinessServiceUnitTest`. I flipped the class to STRICT_STUBS,
found **38 dead stubs**, and deleted **37** of them on the rule I had applied since batch 1:
*`lenient()` is for partial consumption, zero consumption means delete.* That rule is right for a
*positive* test. It is wrong for a negative one, and review caught it **three times in one file**.

**The mechanism.** `confirmPick_shouldNotEnqueueStarted_whenCoAlreadyPicked` asserted
`verify(outboxService, never()).enqueue(...PICKING_STARTED...)` and also stubbed
`buildPickingStartedPayloadJson`. The stub was dead, so I deleted it and argued the outbox `never()`
"strictly dominates" it. It does not — the outbox call sits **downstream** of `if (payload != null)`.
With the stub gone the unstubbed builder returns `null`, the enqueue is skipped **for the wrong
reason**, and the `never()` passes with SBDEV-2381 Fix F-ii fully reverted. **Measured: reverting the
guard failed the test at base and 0 of 56 at HEAD.** I had disarmed the only test guarding a shipped
fix, and reported the deletion as safe.

**Why PIT did not catch it.** The class-level score showed no regression (it even improved), because no
mutation operator generates "revert this specific guard", and the class score is a **max over all
tests** — another test killed a different mutant on the same line. The only signal in the PIT data was
**per-test attribution**: this test killed 2 mutants at base and **0** at HEAD.

**How to apply.**
- For a `verify(never())` test, ask *what makes the negative observable?* If a stub is what forces
  control into the region the assertion guards, keep it — as `lenient()`, since with the guard intact it
  is legitimately dead. That is the case where `lenient()` beats deletion.
- Point the assertion at the call **upstream** of any null/empty short-circuit. Here
  `verify(never()).buildPickingStartedPayloadJson(...)` is the real guard; the enqueue `never()` is not.
- **A `never()` on a method the class under test never calls on any path is VACUOUS** — satisfied by
  every implementation, unprovable by mutation (no operator adds a call). The same file had **10**,
  three of them silently disarmed by my deletions. Detector skips comments — a javadoc quoting an old
  assertion matched the first version: `sbdocs/9-System/scripts/` … or see scratchpad `vacuous-never.py`
  in the batch-4 session.
- Two cheap probes that found all of this: **diff PIT's per-test attribution base-vs-HEAD and chase any
  test that drops to 0 kills**; then hand-roll the one mutant that reverts the guard each negative test
  is *named after*.

## A `verify(never())` placed after `assertThatThrownBy` can be unreachable

A `verify(mock, never()).method(...)` placed **after** an `assertThatThrownBy(...)` is vacuous whenever
the fixture makes the method unreachable on that path. The test still passes, and it still passes under
the very mutant it was written to catch — because it dies on the *earlier* assertion first.

Hit on SBDEV-3089. I added `verify(unitloadBusinessService, never()).transferUnitLoadToCarrier(...)` to
pin that a guard aborts before mutating state. Mutation-check (move the guard below the transfer) went
red — but on the pre-existing `hasMessageContaining` assertion, because the test never stubbed the
parcel or order and so died on the parcel-missing path long before the transfer. The new assertion could
not fire under any input.

**Fix:** stub the whole downstream happy path so the guard is the *only* thing that can stop the call.
Then the mutant fails with `NeverWantedButInvoked` — the real signal.

**Why PIT cannot cover this defect class at all:** `VoidMethodCallMutator` removes calls; it never
**reorders** them. A guard moved below the state change still throws, just too late, and every
call-removal mutant stays killed. Ordering pins are hand-written or absent.

**How to apply:** when mutation-checking a new assertion, do not accept "the test went red" — confirm
*which* assertion went red. If it was a pre-existing one, the new pin is still unproven.

## A `getDeclaredMethods()` for-each passes on an empty list

`for (Method m : Foo.class.getDeclaredMethods()) { assertThat(...) }` **passes when `Foo` declares
nothing** — the loop body never runs. Measured on SBDEV-3011: gutting
`NoDeletePagingAndSortingRepository` to `{}` (deleting the whole fix and re-exporting a destructive HTTP
route) left **all 13 tests green**, and the sibling `isAssignableFrom` check passed too, because that is
true of an empty interface.

The obvious fix is also wrong. Asserting
`.map(Method::getName).distinct().contains("deleteById","delete","deleteAll",...)` is **arity-blind**:
it collapses overloads, so removing only `deleteAll(Iterable)` — or only the no-arg `deleteAll()` —
stayed green while the assertion's own message claimed a shrinking list meant the fix was gutted.

**Why:** this is the JUnit cousin of the grep-row traps in
[[verify-script-over-tempered-gap-and-comment-satisfied-negatives]] — a reflection test looks rigorous
and reads as behavioural, but iterating a collection is not asserting its contents.

**How to apply:** assert the SET before iterating, keyed on `name + "/" + getParameterCount()` with
`containsExactlyInAnyOrder`, so both total and partial removal go red. And always mutation-test the
assertion: delete the thing it protects and confirm it fails. Same discipline as
[[negative-test-verify-scripts-before-trusting-them]] — an assertion never seen red is not evidence.

---

Related: [[mutation-harness-traps]], [[pit-does-not-compile-stale-test-bytecode]],
[[a-mutant-must-be-proven-to-hit-its-target]],
[[verify-never-is-vacuous-if-unreachable-if-control-flow-cannot-reach-it]],
[[wms2-mobile-palletizing-has-two-duplicate-test-classes]] (the duplicate-pair half of SBDEV-3102),
[[sbdev-3119-null-parent-walk]],
[[sbdev-3089-two-red-tests-on-develop]], [[address-low-review-findings-too]],
[[transactional-tests-blind-to-propagation-and-readonly]].

Provenance: merged from memories originating in session `afc23d06-1cfd-4b37-a864-1f84ddec40e3`
(Mockito strictness census + arg-mismatch suppression) and the SBDEV-3011 / SBDEV-3089 / SBDEV-3102
batch-4 sessions.

## A context-sensitive stub that returns null on no-context HIDES no-context reads (SBDEV-3198, 2026-09-02)

The stub shape `if (TenantContext.getCurrentTenant() == null) return null;` is the right defence against
one regression — it caught the dropped `setCurrentTenant` on the boot probe — and it is **blind to the
opposite one**. On the D′ slice a per-tenant walk cleared the context on every iteration and the caller's
context was restored only in an outer `finally`, so a `CRON_JOB_SHOW_LOG` sysprop read in between ran with
**no tenant at all** — unroutable in production. Every test stayed green: the stub returned `null`,
`Boolean.parseBoolean(null)` is quietly `false`, and nothing downstream cared. **PIT found it, as a
SURVIVING mutant**: negating the additive gate made the read happen, and no stub could see a read made
with no context. The surviving mutant was not noise — it was the only instrument pointing at the bug.

**How to apply.** A context-sensitive stub must do one of two things on no-context, and returning a
value is not one of them: either **throw** (which fails the test loudly at the exact site) or **record
the no-context read** into a list the test asserts is empty. `return null` is the one choice that makes
the read invisible. And when PIT reports a survivor on a guard whose *removal* should cause an observable
read/write, ask what the test would have observed — if the answer is "nothing, because the stub swallows
it", the stub is the finding.

---

# Part 4 — an unstubbed BOXED-primitive return is `0`, not `null`

Measured 2026-09-11 on SBDEV-3316. A collaborator mocked with a `Long`-returning method:

```java
Long recovered = cancellationLogService.resolvePicktoStockunitId(a, b);   // mock, unstubbed
if (recovered != null) { log.setPicktostockunitId(recovered); save(log); }
```

Mockito's default answer routes wrapper types through `Primitives.defaultValue`, so an **unstubbed
`Long`/`Integer`/`Boolean` method returns `0L` / `0` / `false`, not `null`.** The recovery branch
therefore "succeeded" with stock unit **0**, and the test named
`...RefusesWhenStockUnitWasNeverResolved` still went green on its `assertThatThrownBy` — because a
`BusinessException` was thrown, just **one guard later**, from the `findById(0L)` lookup rather than
from the guard the test exists to pin. Delete that guard and the test stays green.

It was caught only by an unrelated `verify(logRepository, never()).save(any())` in the same test.

**Practice:** whenever a mocked method returns a boxed primitive and the CUT branches on `!= null`,
**stub the null explicitly** — `when(x.m(any(), any())).thenReturn(null)` — and say in a comment that
the stub is not redundant. Reaching the same exception type from a different line is the tell; assert
on the message, not just the class. Same family as the `never()` vacuity in Part 3 and
[[mockito-never-any-primitive-unboxing-trap]] (which is the mirror image: bare `any()` for a
*primitive parameter* NPEs at unboxing).
