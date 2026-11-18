---
name: not-supported-test-needs-exempt-list-entry
description: "Making a wms2 test class @Transactional(NOT_SUPPORTED/NEVER) reds TestClassTransactionManagerArchTest unless it is added to EXEMPT_NON_TRANSACTIONAL; \"test-only\" commits still need the full suite"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 7b155671-54ac-4689-8213-a9af450d48d6
  modified: 2026-10-31T08:14:04.742Z
---

Adding `@Transactional(propagation = NOT_SUPPORTED)` (or `NEVER`) to any wms2-api test class requires adding
that class's FQN to `EXEMPT_NON_TRANSACTIONAL` in `unit/config/TestClassTransactionManagerArchTest`, with a comment
naming the ids it commits and how it cleans them up. `nonTransactionalPropagationsMustBeDeclared` pins the set
exactly.

**Why:** SBDEV-3980 commit 2c8f8832 made `ReplenishorderDetailMapIT` NOT_SUPPORTED to stop a seed leak. It was
pushed on the reasoning "test-only commit, the earlier full suite still stands", and CI run 41161372507 went red on
this rail. Surefire failed first, so failsafe never ran and the ITs were not graded either. Fixed in a20ffa03.

**How to apply:** test-only commits are not exempt from the full suite, because arch rails scan test classes too.
Run full `-Pci` (or at least `mvn test`) before every push, not only on the first production commit. Related:
[[wms2-concurrency-it-fixture-traps]], [[review-rounds-leave-their-own-fix-commits-unreviewed]].
