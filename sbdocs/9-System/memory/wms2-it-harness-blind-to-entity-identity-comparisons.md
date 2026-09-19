---
name: wms2-it-harness-blind-to-entity-identity-comparisons
description: BaseIntegrationTest runs each test in ONE persistence context, so a JPA entity `.equals()` identity comparison always holds there and the mutant survives
metadata:
  type: reference
---

`BaseIntegrationTest` is `@Transactional("tenantTransactionManager")`, so every repository call in a
test method shares one persistence context and Hibernate's identity map returns the **same instance**
for the same id. Any production code comparing two separately-loaded entities with `.equals()`
therefore behaves correctly *in the harness* — and cannot be distinguished from correct code.

Measured on SBDEV-2371 (2026-09-17): replacing v2's `MobileTransferOrderService.calculateStockOnStagingLane`
with v1's `itemdata.equals(sku)` loop **SURVIVED** a real-DB integration test that otherwise kills a
`return 0;` mutant, a cap-removal mutant and a `<=`→`<` boundary mutant, all attributably. A review
lane reproduced it and also killed the obvious objection: a literal `itemdata == sku` mutant survived too.

⚠ **In v2 there are TWO reasons that transplant survives, and the harness is only one of them.**
v2's model entities mostly extend `AbstractBaseEntity`, whose `equals` is `getId().equals(other.getId())`
— so for those, `.equals()` is correct regardless of persistence context. v1's `Itemdata` is a bare
`public class Itemdata {`. Check the entity's superclass FIRST; see
[[wms2-entity-equals-is-id-based-via-abstractbaseentity]] for the v2 entities that do NOT get it.

Production is the opposite: `spring.jpa.open-in-view=false` (`application.properties`), so a service
method **without** `@Transactional` gets a fresh EntityManager per repository call and identity never
holds. So the harness is green exactly where production is broken.

**How to test this class of defect instead:** assert the *observable effect* (the quantity, the guard
firing), not the comparison; and mutate to the effect (`return 0`) rather than to the v1 shape. To
exercise the real context split you would need the call outside a test transaction — no current
harness does that.

Related: [[wms2-entity-equals-is-id-based-via-abstractbaseentity]], [[mutation-harness-traps]],
[[wms2-has-two-full-context-test-lanes]].
