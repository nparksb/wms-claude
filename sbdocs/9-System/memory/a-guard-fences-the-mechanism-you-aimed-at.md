---
name: a-guard-fences-the-mechanism-you-aimed-at
description: Before calling a guard complete, enumerate every mechanism that can produce the outcome — on SBDEV-3017 a remedy for a measured hole was itself holed three times
metadata:
  type: feedback
---

Measured three times on SBDEV-3017, twice on SBDEV-3102/3089 before it. **A guard written against the
defect you just saw fences that defect's SHAPE, not its OUTCOME.** Reviewers keep finding the second shape,
which means the check is cheap and I keep skipping it.

**The worked example.** A review lane showed that adding a class-level `@RequiresFunction` to
`ClientController` breaks the OMS integration while every test stays green. I fixed it with three pin rows
asserting those routes stay ungated. **Two independent lanes then showed `@PreAuthorize` does the same thing
and the new rows are blind to it** — the suite stayed green at 5691 tests. The outcome ("OMS gets 403") had
**three** producers, and my fix covered one:

| mechanism | caught by |
|---|---|
| `@RequiresFunction` | the new rows |
| `@PreAuthorize` | nothing, until fix #2 |
| `@PostAuthorize` / `@Secured` / `@RolesAllowed` / `@DenyAll` | nothing, until fix #3 |
| `GUARDED` membership | a startup assertion — boot failure, not a named route |
| `SecurityConfiguration`'s `authorizeHttpRequests` matchers | nothing, until fix #3 added a SOURCE test |

**It took three rounds.** Each fix fenced the mechanism the previous lane had demonstrated and missed its
siblings. Round 3 measured `@Secured` + `@RolesAllowed` + `@DenyAll` on all three routes **at once** —
`@DenyAll` denies *everyone* — with the suite green at 5692; and separately, adding three prefixes to
`SecurityConfiguration`'s admin-only list, also green. Enumerate BEFORE fixing, not after each round.

**Two enabling traps, both general:**
- `@EnableMethodSecurity(prePostEnabled, securedEnabled, jsr250Enabled)` — check which flags are ON before
  assuming one annotation family is the surface. Here all three were on, and only `prePostEnabled` was pinned
  by any test, so the other two were live with nothing defending them.
- A bean behind `@ConditionalOnProperty` that the test profile DISABLES is invisible to every Spring-context
  test — `SecurityConfiguration` is `rest.security.enabled`, false in `application-integration.properties`.
  No runtime test can assert on it at all; that is the documented case for a narrow SOURCE assertion.

**A closed-set claim is load-bearing.** My comment "three gate mechanisms exist" was itself the thing that
made two of them invisible — written, ironically, to close a different false claim. Say what is covered
here, what is covered elsewhere *and by which rail*, and what is not covered. Never assert a total.

**How to apply.** When writing any guard, assertion, or pin, ask **"how many ways can this outcome be
produced?"** and enumerate them before claiming coverage. Then state in the code which ones the guard covers
and which are covered elsewhere — a green guard that fences one of three mechanisms reads to the next person
as "this is fenced". The javadoc must say *"catches X and Y; Z is caught by <named other rail>"*.

Related shapes of the same error, all measured:
- [[archunit-call-site-rules-have-five-blind-spots]] — a call-site rule that missed ctors, static init,
  method refs, subtypes and field writes; 5 escapes survived 5673 tests.
- SBDEV-3017 §9.24 — a rule watched the SETTER, not the COLUMN, so an alias setter walked past it.
- [[mockito-never-any-primitive-unboxing-trap]] — widening a matcher to cover one shape broke another.

**Corollary, same ticket:** a fix to a false comment corrected the class name and **carried the wrong path
forward** from the text it was replacing, and a retracted claim survived verbatim in a second copy of the
same comment. **Grep the CLAIM across the repo, never just the file you were editing** — see
[[retitling-a-section-leaves-the-rule-asserted-below-it]].

## Sibling failure: a stabilising guard is only as stable as its INPUT (SBDEV-3198, 2026-09-02)

Same family, one level up. Above, the guard fenced one *producer of an outcome*. Here the guard was
correct and complete — and **defeated through the value it reads**.

AC14 required a schedule reconcile to be a strict no-op when the desired trigger set is unchanged,
because a cancel-and-re-add cycle drops up to 288 order-release minutes a day. I built the diff, got
PIT to 140/140, hand-mutated the three mutants PIT structurally cannot express, and never once asked
whether **the value being diffed was deterministic**. It was not: the schedule is derived from
"the first reachable tenant in an arbitrary iteration order", which the converging reconcile re-ran
**288 times a day** where boot had run it once. A review lane then measured that tenants genuinely
disagree (`STOCK_SUMMARY_EXPORT_TIMER_HOUR` = 3 on prd, 18 and 17 on two uat tenants), so a flapping
tenant DB would have produced the exact churn the guard existed to prevent — through the front door.

**The check, worth running on any idempotency/no-op/caching guard:** name the input the guard
compares, then ask *"who can change this, and how often?"* A diff, a cache key, an `equals`-based
early return and a change-detection snapshot are all only as stable as that input. **"The comparison
is correct" and "the comparison is stable" are different claims, and the tests for the first do not
touch the second.**

Two related traps observed in the same change:

- **Fixing it by changing which path a test exercises can silently empty the test.** Making the
  reconcile additive-only left three tests passing **vacuously** — they no longer reached the method
  under test at all, and stayed green. Only re-running the mutants found it. Re-run the mutation set
  after any change to *which* code path a test drives, not only after changing assertions.
- **An inadmissible mutant is not a kill.** A hand-mutant that moves a statement can break
  declaration order and fail to compile; a harness that greps for test failures sees no failures and
  scores it KILLED. Detect `COMPILATION ERROR` and emit a third outcome — see
  [[mutation-harness-traps]].
