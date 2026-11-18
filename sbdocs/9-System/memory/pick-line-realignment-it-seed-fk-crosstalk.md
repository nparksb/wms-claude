---
name: pick-line-realignment-it-seed-fk-crosstalk
description: PickLineRealignmentIT.ac6_concurrentMoveTrees_doNotDeadlock can ERROR in a full verify with a seed FK violation; passes alone — rerun before investigating
metadata:
  node_type: memory
  type: reference
  originSessionId: 5ed66503-8604-4a38-8bbb-1604e19ad100
  modified: 2026-11-02T08:26:09.022Z
---

`PickLineRealignmentIT.ac6_concurrentMoveTrees_doNotDeadlock` ERRORed in a full `mvn clean verify -Pci` on 2026-11-02 (SBDEV-3987 worktree, base origin/develop 4643acf5) at `seed:152->stockunit:194`: `DataIntegrityViolation … violates foreign key constraint "fkhoxjsrvueohjwo8qjyi6falad"`, `Key (unitload_id)=(98306) is not present in table "unitload"`. That run: unit lane 9548/0 failures; failsafe 1186 with 1 error, this one.

Rerun alone (`-Dit.test=PickLineRealignmentIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`): 12/12 green. The change under test (an additive DTO field) cannot reach the seed, so this is shared-container state, not a regression. See [[hub-it-shared-state-crosstalk]].

**How to apply:** a full-run ERROR in this IT whose message is the seed FK above → rerun the class alone first. A failure in the deadlock/lock assertions themselves is a different matter; see [[wms2-lock-timeouts-are-inert-on-postgres]].
