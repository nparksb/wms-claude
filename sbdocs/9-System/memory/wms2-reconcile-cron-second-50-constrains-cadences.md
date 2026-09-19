---
name: wms2-reconcile-cron-second-50-constrains-cadences
description: "wms2 RECONCILE_CRON fires on second 50 and must share it with no fixed-phase cron — so a sub-minute job cadence must avoid 50; */2 is illegal, */3 is fine"
metadata:
  node_type: memory
  type: project
---

`SchedulingConfiguration.RECONCILE_CRON = "50 */5 * * * *"`. Its invariant: **second 50 must not be a
second any fixed-phase cron fires on**, because a slow reconcile cycle must delay only the NEXT
reconcile. `SchedulingReconcileIdempotencyUnitTest.reconcileSecondCollidesWithNoScheduledJob` enforces
it by reading `src/main/resources/application.properties` **off disk** (the test-classpath copy shadows
main and would grade the wrong file).

**Consequence for any sub-minute cadence:** `*/2` occupies every even second including 50 — illegal.
`*/1` occupies all 60 — illegal. `*/3` gives `{0,3,…,57}`, which excludes 50 — fine. Chosen for both
outbox lanes in PR #353.

Two traps around this:
- The rail's key list is **hand-maintained** and was missing `app.cron.outbox-dispatcher-club` (added
  by #352, never registered), so a club-lane-only collision passed. Grep `src/main` for
  `@Scheduled(cron = "${...}")` rather than trusting the list by eye.
- `RECONCILE_CRON`'s javadoc used to carry a seconds-occupancy enumeration ("six of sixty … 54 are
  free") which any cadence change falsifies. Replaced with the rule — see
  [[prose-enumerations-rot-state-the-rule]].

**A step cadence cannot be written literally in a javadoc** — the `*` followed by `/` closes the block
comment. Write "a 15-second cadence", not the expression.
