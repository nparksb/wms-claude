---
name: wms2-concurrency-it-fixture-traps
description: "Two traps when writing a wms2 NOT_SUPPORTED concurrency IT — a committed fixture is NOT isolated by client_id from a sibling that deletes by id watermark, and a version bump via jdbcTemplate self-deadlocks against the holder's own lock"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9d52a4a0-a665-4761-910e-aecb134394a3
  modified: 2026-09-10T20:19:00.788Z
---

A `BasePostgresIntegrationTest` with `@Transactional(propagation = NOT_SUPPORTED)` — which you need
whenever two threads must see each other's **committed** rows — has no test transaction, so every
fixture row commits and outlives the class. Two traps follow, both measured on SBDEV-3244.

**1. "No other test uses my client id" does NOT isolate a committed fixture.** Cleaning up only in
`@BeforeEach` is not enough, because a sibling may clean up by **id watermark** rather than by client:
`OrderReleaseSectionQueryIT` does `idWatermark = SELECT last_value FROM seqentities` then
`DELETE FROM itemdata WHERE id > ?`. A surviving fixture `itemdata` above that watermark, still
referenced by a surviving `stockunit`, makes its DELETE fail on FK
`fk13mb98u9dqlwtiduo040tl4l5` — and all four of its tests error. Green alone, red whenever the
leaking class ran first. **Always delete in `@AfterEach` as well**, children before parents
(`client` LAST — `fk_client_defaultputawaylocation` makes it a child of `location`).
SBDEV-3285 fixed the same symptom from the other side by bounding the sweep's window, so the two
fixes are complementary. ⚠ Be precise about which class leaked, because 3285's own commit message is
wrong about it: on `origin/develop` the leaker was
`ReplenishmentOrderMaintenanceServiceIntegrationTest` (`ITEMDATA = 9951L`, the exact `Key (id)=(9951)`
in the quoted FK error). `ReplenReassignOnNonReplenishableMoveIT` is named there as a leaker but
already carried `@AfterEach`. Check the id in the FK error against each class's fixture constants —
do not take a commit message's class list.

**2. The version bump must go through the holder's OWN transaction.** Doing it with `jdbcTemplate`
**self-deadlocks**: that template is a standalone `DriverManagerDataSource` in autocommit, so its
`UPDATE` waits on the row lock the holder's `TransactionTemplate` already owns, and the tenant
`lock_timeout` does not apply to that connection. It hangs until the suite is killed, with **no
deadlock report**. Mutate the entity the holder loaded and `save()` it instead — Hibernate bumps
`@Version` on flush, which is what a real winner does. (`jdbcTemplate` is still right for plain
committed `UPDATE`s from a third actor, and for `SELECT`s.)

**Why:** both produce failures that point somewhere else — an FK violation in an unrelated class, or a
silent hang — so the cost is a debugging session, not a red test you can read.

**How to apply:** take the lock through the repository inside a
`TransactionTemplate(tenantTransactionManager)`, never through `jdbcTemplate` (a `SELECT … FOR UPDATE`
there releases at statement end and the choreography silently tests nothing — `MoveCronConcurrencyIT`
documents this and two sibling ITs have the defect). And prove the subject is blocked by **observing**
it, not by a latch that failed to fire: a latch that has not counted down is equally consistent with
the subject never having started, which lands your bump before the prefetch and passes green for the
wrong reason. `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND
datname = current_database())` works; its blind spot is that it cannot attribute the wait to a
specific session. Related: [[findbyidforupdate-throws-at-the-lock-read-not-at-flush]],
[[wms2-repository-tests-commit-they-do-not-roll-back]], [[concurrent-maven-one-worktree-false-reds]].
