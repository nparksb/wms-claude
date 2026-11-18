---
name: signature-change-leaves-test-classes-stale
description: "Adding a checked exception to a main-code method: incremental mvn test-compile exits 0 without recompiling the unchanged tests that no longer compile"
metadata:
  node_type: memory
  type: feedback
  originSessionId: a0f0636a-bf3c-4026-b3ad-db400c3b6be0
  modified: 2026-11-12T07:59:31.284Z
---

On SBDEV-4128 (2026-11-12) I added `throws ApiInvalidParameterException` (checked) to `ShipperIdController.createShipperId`. `mvn -o -q test-compile` exited **0** with no errors. But `ShipperIdControllerUnitTest` declares `throws BusinessException` only, so it no longer compiled. The incremental compiler recompiled main and skipped the **unchanged** test sources, so the stale test classes were run. After `rm -rf target/classes target/test-classes`, the same command showed 5 compile errors.

**Why:** the maven-compiler incremental check works per module and source set. A test file that did not change is not recompiled when only a main signature it depends on changed. The result is a green that never compiled the code it reports on. CI (`mvn clean verify`) would have gone red.

**How to apply:** after changing any main-code signature (parameters, return type, `throws`), delete `target/classes target/test-classes` (or run `mvn clean`) before the targeted run whose green you will report. Related: [[mvn-without-clean-runs-deleted-tests]], [[failsafe-without-compile-runs-stale-classes]], [[hub-maven-false-verdicts]].
