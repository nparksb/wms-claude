---
name: wms2-entity-equals-is-id-based-via-abstractbaseentity
description: v2 model entities inherit id-based equals from AbstractBaseEntity — grepping the class file for "boolean equals" and concluding reference identity is wrong
metadata:
  type: reference
---

**44 of 74 classes in `v2/wms2-api/src/main/java/net/aim_ai/wms/model/` extend `AbstractBaseEntity`**
(verified on `origin/develop` 2026-09-17 by iterating the directory), whose `equals` is:

```java
if (this.getClass() != other.getClass()) return false;
return getId() != null && getId().equals(other.getId());
```

So `.equals()` on `Unitload`, `Stockunit`, `Itemdata`, `Location` … compares **ids**, and is correct
regardless of persistence context. The 30 that do not extend it are views, projections, embeddable-id
classes, `OutboxMessage`, `RestIdempotency` and `LosSequencenumber`.

⚠ **I got this wrong on SBDEV-2371 and reported a non-defect.** `grep -c 'boolean equals'` on
`Unitload.java` returns 0 and the class *does* declare a lone `hashCode()` — which reads exactly like
"hashCode without equals, so equals is Object identity". It is not: the `equals` is inherited, and the
lone `hashCode` (`getClass().hashCode()`) deliberately mirrors the base class's, kept stable because
`getId()` goes null→Long on persist. On that basis I claimed two Nirwana guards
(`MobileMoveStockService.selectSource`, `MobileMoveUnitloadService.scanUnitLoad`) were dead. **They are
not.** Retracted on the ticket.

**The rule: never conclude reference-identity equality from the class file alone — resolve the
superclass chain.** `javap -c` or an LSP "go to definition" answers it; a single-file grep cannot.
This is the same failure shape as [[annotation-census-by-grep-is-wrong-by-default]]: the instrument
saw one file and the answer lived one level up.

Contrast v1: `v1/wms-api`'s `Itemdata` is a bare `public class Itemdata {` with no superclass and no
`equals`, so there `.equals()` IS reference identity — which is the v1 half of SBDEV-2371.
See [[wms2-it-harness-blind-to-entity-identity-comparisons]].
