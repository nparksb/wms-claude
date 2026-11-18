---
name: targeted-runs-must-include-the-rails
description: "When the full wms2-api suite can't run locally, a targeted run must include *ArchTest + count-pin tests, or rail reds surface only in CI"
metadata:
  node_type: memory
  type: feedback
  originSessionId: a0f0636a-bf3c-4026-b3ad-db400c3b6be0
  modified: 2026-11-12T12:49:38.078Z
---

When the full `mvn test` cannot run locally (memory pressure killed it on SBDEV-4109, 2026-11-12), the targeted run must include **every `*ArchTest`, `TenantCacheKeyUnitTest`, and the `*Contract*Test`s**, not just the touched classes. Measured on SBDEV-4109: three reds that the touched-class run missed and the PR's CI caught:
- `NeverMatcherNullBlindnessArchTest`: one new `never().save(any(User.class))`
- `TestClassTransactionManagerArchTest`: a new `NOT_SUPPORTED` IT not registered in `EXEMPT_NON_TRANSACTIONAL`
- `TenantCacheKeyUnitTest`: the keyed-cache-annotation count pin (21 → 22) after adding one `@CacheEvict`

`-Dtest='*ArchTest,TenantCacheKeyUnitTest,*ContractUnitTest,*ContractTest,<touched classes>'` ran 1822 tests in a few minutes and fit in memory.

**Why:** the rails scan the whole tree for patterns that new code adds. They don't care which class you touched, so a touched-class filter excludes exactly the tests that police the new code.

**And `mvn test` cannot see the integration lane at all.** On SBDEV-4132 (2026-11-12) the targeted `mvn test` run, rails included, was green (1159 tests). CI then failed `FixLocationAssignmentControllerIT.delete_whileFlaHeld_blocksAtFlaLockAndReturns409`: SBDEV-4031 AC-9 pins that route's 409 contract through MockMvc on real Postgres, and my change had turned it into a 200. So when a change alters a route's HTTP status or error shape, run `git grep -ln '<route path or controller>' -- 'src/test/**/*IT.java' 'src/test/**/*IntegrationTest.java'` and run those through `mvn verify -Dit.test=<A>,<B> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`. A pinned contract that turns up there is a design question for Nam (escalation trigger 3), not a test to update.

**How to apply:** use that filter as the minimum local gate whenever the full suite isn't run, and still treat the PR's CI as the authoritative full-suite run. Related: [[hub-maven-false-verdicts]], [[hub-wms2-test-harness]].
