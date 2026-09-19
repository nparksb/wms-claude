---
name: enhancement-paths-must-fail-open-on-missing-config
description: "A guard copied from an action-selecting switch is wrong on a yes/no question — an enhancement path must skip on missing config, not throw"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: de93b3da-8de1-4f18-850d-adab1aa3f02b
  modified: 2026-09-11T20:52:39.220Z
---

When new code answers **"should I also do X?"**, every missing *configuration* prerequisite must log and skip. Throwing turns an absent optional row into a total outage of the host operation.

On SBDEV-3320 I made this mistake **three times in one ticket**, because I copied `SectionService.create` and `CustomerorderService.processPackaging`, which throw on an unrecognised `sectionpickingtype`. That rationale does not transfer: those switches **select an action** and have no safe default (`processPackaging` must either return the tote to the empty pool or retire it — doing neither strands it). A yes/no question has a safe negative.

The three, all in the cart-mint path off `MobilePickingService.processPick`:
1. unrecognised `sectionpickingtype` → would 500 every pick in that section
2. missing `Cart` `unitload_type` row → same
3. null system client → NPE (`ClientService.getSystemClient()` documents returning **null**, not throwing; 56 call sites mostly dereference it unguarded)

**Keep the leniency narrow.** It covers missing config only — a genuine failure from the work itself (a cycle, a type violation, a lock timeout) must still propagate. A blanket try/catch here would be the swallowed-exception antipattern.

**How they were found:** all three by `mvn verify`, never by `mvn test`. See [[mvn-test-cannot-see-the-integration-lane]]. Related: [[a-guard-fences-the-mechanism-you-aimed-at]], [[wms-fix-effort-tiers-and-the-floor]].

**Why:** the failure mode is invisible in the tier that introduced it — a T2 enhancement silently acquiring the blast radius of the feature it hangs off.

**How to apply:** for any new conditional enhancement, list its prerequisites explicitly and decide per-prerequisite: config → skip + LOG.error; operational error → propagate. Do not infer the choice from a nearby switch without checking whether that switch selects an action or answers a question.
