---
name: review-lanes-under-audit-prerequisite-tables
description: "A false completeness claim survived 3 plan revisions and 2 adversarial review lanes because it sat in a prerequisites table, not a design section — reviewers audit §3, not §5.1"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 75060194-ee15-400f-bfc3-b3e78707041b
  modified: 2026-09-15T18:06:01.567Z
---

**Reviewers audit the design sections. Claims hiding in prerequisites, rollout and ops tables are
effectively unreviewed — check them yourself.**

Measured on SBDEV-1512, 2026-09-15. A plan's §5.1 Prerequisites row asserted that *"a tenant DB with
no `flyway_schema_history` is skipped entirely — the state of every not-yet-cut-over v1 client,
ShipItEZ included."* False: both ShipItEZ **v2** tenant DBs (`wh01_shipitez_v2`, `wh02_shipitez_v2`)
have `flyway_schema_history`, sit at `V2.2.30` with **0** failed rows, and one applied a migration
**the same day**. The historyless DB was `wh01_shipitez` — their **v1 production** database, which is
not a v2 tenant and never a Flyway target at all.

It survived rev1, rev2 and rev3 **and** an Architect lane **and** a Critic lane, both of which were
explicitly briefed on claim discipline and both of which broke real completeness claims elsewhere in
the same document. It was caught only by an independent DB query from the orchestrator.

**Why it survived:** the reviewers attacked §3 Design, §7 Testing and §9 Alternatives — where the
argument lives. A prerequisites table reads as bookkeeping, so nobody re-derived it.

**Why the direction mattered:** it would have sent an implementer to run a `flyway_schema_history`
backfill against a tenant schema that was already current — a manual write, on no evidence. The
error's *consequence* was an unnecessary destructive-ish action, not just a wrong sentence.

**The underlying generator, worth recognising on sight:** two measured facts about DB *A* and DB *B*
were generalised into a completeness claim about a *third* property (schema currency) across a
*whole class* of clients. Neither measured fact was about that property. That is the exact failure
[[a-zero-scan-needs-a-positive-control]] and the claim-discipline rule target — and the author did
not apply the rule to their own prerequisites row because it did not read like a claim.

**How to apply:**
- When reviewing or commissioning review of a plan, **explicitly name §5.1 / rollout / ops tables as
  in-scope**, or they will be skipped.
- Any prerequisites row asserting the state of a named environment gets **measured**, not reasoned.
  Prefer "do not reason about which tenants those are — measure it" plus the query, over a prose
  claim about which tenants qualify.
- Distinguish **client traffic not cut over** from **v2 schema not provisioned**. They are
  independent; v2 DBs are provisioned and kept schema-current *ahead of* cutover. Related:
  [[shipitez-two-warehouse-v2-migration]], [[wms2-tenant-object-ownership-blocks-flyway]].
