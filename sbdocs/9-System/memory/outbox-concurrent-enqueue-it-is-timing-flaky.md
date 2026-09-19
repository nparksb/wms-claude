---
name: outbox-concurrent-enqueue-it-is-timing-flaky
description: OutboxConcurrentEnqueueIT asserts an ordering between two racing threads that only a Thread.sleep(5) makes likely — it randomly reds develop and silently stops the dev deploy
metadata: 
  node_type: memory
  type: project
  originSessionId: 885ee114-3071-4b9e-9b32-e55329684a43
  modified: 2026-09-08T19:29:56.864Z
---

**Measured 2026-09-08 (during the SBDEV-3262 merge).**
`OutboxConcurrentEnqueueIT.concurrentEnqueueSameCo_shouldNotRollback_andStartedGetsLowerId` failed on
the post-merge `develop` run, then **passed on a re-run of the identical commit with zero code change**.
Pre-existing flake, not a regression.

The assertion: STARTED (enqueued first) must carry a lower outbox id than FINISHED. Observed
`Expecting 2L to be less than 1L`. Two threads race on the same customer order and the only thing
ordering them is:

```java
Thread.sleep(5); // STARTED commits first in the common case
```

The test's own comment says **"in the common case"**. A 5 ms sleep is not a synchronisation primitive;
on a loaded CI runner thread B wins. Nothing in the production code guarantees which thread commits
first, so the test asserts more than the code promises.

**Why it costs more than one red run:** the `build` job declares `needs: test`, so a red `develop`
**silently stops deploying** — no image, neither Portainer webhook. The only signal is the Actions tab.
Merged work sits undeployed until somebody looks. See
[[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]] and [[wms2-no-pipeline-runs-tests]].

**How to apply.** If a post-merge `develop` run fails on this test alone, re-run before investigating —
but establish independence first, not after: check whether the diff touches the outbox path at all and
whether the failing test references any changed symbol. On SBDEV-3262 both answers were no (11 files,
none in the outbox path; zero references to any changed symbol), which is what justified a re-run
rather than a revert. **A re-run is only evidence when you predicted the outcome beforehand** — re-running
until green is how a real intermittent regression gets shipped.

The real fix is not a retry annotation: either relax the assertion to what the code actually guarantees,
or impose a genuine ordering (a latch the second thread waits on) instead of a sleep.

**FILED as SBDEV-3280 (2026-09-09).** The ticket carries the derived population and the fix template.

**`ParcelMonitorViewServiceConcurrencyIT` is the correct model in this repo** — it orders its threads with
a `CountDownLatch` plus a real pessimistic row lock, and its `Thread.sleep(300)` only holds the
transaction open while the other thread blocks. It asserts no ordering. The distinction worth carrying:
a sleep that HOLDS state while a real primitive orders is fine; a sleep used AS the primitive is not.
Derived population: exactly 2 test classes combine `Thread.sleep` with a concurrency construct, and only
the outbox one is defective (blind spot: grep-based, so it would miss Awaitility/busy-wait/poll-timeout
ordering).

Related: [[green-tests-that-prove-nothing]], [[concurrent-maven-one-worktree-false-reds]].
