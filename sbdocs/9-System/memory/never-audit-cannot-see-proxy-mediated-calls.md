---
name: never-audit-cannot-see-proxy-mediated-calls
description: "\"CUT doesn't reference the collaborator\" is NOT vacuity — Spring proxies and @InjectMocks both defeat it"
metadata:
  type: reference
---

`never-audit.py`'s CHECK A, and any classifier built on *"the class under test must reference the
collaborator in its own source"*, is **wrong in the direction that deletes live guards**. Measured
twice on SBDEV-3170, both times toward "this asserts nothing" when it did:

**1. Proxy-mediated calls are invisible.** `UserGroupServiceTransactionBoundaryTest` and its two
siblings assert `verify(landlordTransactionManager, never()).getTransaction(any())`. `UserGroupService`
never mentions a transaction manager — **Spring's `@Transactional` proxy calls it**. These are
Spring-context tests with mocked `@Bean`s, not plain Mockito. Proof: stripping the tenant qualifier from
ONE `@Transactional` (the CLAUDE.md dual-TM hazard) fails **3 tests**. They guard the repo's
self-declared most dangerous mistake.

**2. "Not a constructor parameter" means HALF-BLIND, not vacuous.** With `@InjectMocks`, adding the
collaborator as a ctor param wires the mock and the assertion **does** fire — measured on
`PutawayDestinationResolver`: ctor param → 2 failures; field/static/other instance → passes for every
implementation. So such a site covers the injected route only and **self-arms** on the likeliest
regression.

Genuine vacuity needs BOTH: manual construction (`new Cut(...)`) AND the mock absent from the argument
list — then it cannot fire and will not self-arm (`UserGroupControllerUnitTest` /
`userGroupUserRepository`).

**How to apply:** never delete a `never()` on a classifier's say-so. Apply the realistic hazard and see
whether the assertion fires. That per-site empirical test is cheap and is the only instrument that has
been right here. See [[never-audit-check-a-does-not-find-vacuity]] — this supersedes its "mock the CUT
does not hold ⇒ noise" rule — and [[failed-regex-resolution-must-not-become-a-verdict]].
