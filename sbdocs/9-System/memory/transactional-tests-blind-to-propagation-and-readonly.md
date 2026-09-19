---
name: transactional-tests-blind-to-propagation-and-readonly
description: "Asserting @Transactional's transaction-manager name proves almost nothing — propagation=NOT_SUPPORTED and readOnly=true are invisible to both annotation checks and mock-PlatformTransactionManager slice tests"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 06947b5e-b469-4ffe-99d7-c41704a80bab
  modified: 2026-08-19T21:40:42.368Z
---

A mutant of `@Transactional(value = "tenantTransactionManager", propagation = NOT_SUPPORTED, readOnly = true)` was **measured 100% green** against a full unit suite, a Spring slice test with a mocked `PlatformTransactionManager`, and a grep-based verify script — while being strictly worse than having no fix at all:

- `NOT_SUPPORTED` **suspends** the transaction, so any delete-then-insert data-loss defect returns in full.
- `readOnly = true` sets `FlushMode.MANUAL` on a `JpaTransactionManager`, so writes are **never flushed** — the operation becomes a silent no-op returning `200`.

Why each lane misses it:

1. **Annotation tests** typically read only `tx.value()`. Add `assertThat(tx.propagation()).isEqualTo(Propagation.REQUIRED)` and `assertThat(tx.readOnly()).isFalse()`.
2. **Mock-transaction-manager slice tests** cannot see it: `TransactionAspectSupport.createTransactionIfNecessary` calls `tm.getTransaction(txAttr)` for *every* propagation, and `completeTransactionAfterThrowing` calls `tm.rollback(status)` unconditionally. Against a mock, `REQUIRED`, `SUPPORTS`, `NOT_SUPPORTED` and `NEVER` are indistinguishable, and `readOnly` lives on the `TransactionDefinition` the mock discards. Fix by capturing it:
   ```java
   ArgumentCaptor<TransactionDefinition> def = ArgumentCaptor.forClass(TransactionDefinition.class);
   verify(tenantTransactionManager).getTransaction(def.capture());
   assertThat(def.getValue().getPropagationBehavior()).isEqualTo(TransactionDefinition.PROPAGATION_REQUIRED);
   assertThat(def.getValue().isReadOnly()).isFalse();
   ```
3. **Grep rows** with a tempered gap forbidding `;` and `@` don't notice, because `propagation = …, readOnly = true)` contains neither.

**Also: use `AnnotatedElementUtils.findMergedAnnotation`, never `getMethod().getAnnotation()`.** `transactionManager` is `@AliasFor("value")`, so raw JDK reflection reports `value() == ""` for `@Transactional(transactionManager = "…")` — a legal, semantically identical spelling Spring resolves fine. Raw reflection makes it a **false red**, and the failure message points at the wrong theory.

Related: [[wms2-requires-new-in-lock-holding-tx-deadlock]], [[hibernate-delete-then-reinsert-same-key-needs-set-difference]], [[sbdev-3005-role-function-composite-key-swap]]. A `standaloneSetup` MockMvc registers **no** `@ControllerAdvice` and installs no method-security advisor, so neither `@Transactional` nor `@PreAuthorize` is exercised there at all.
