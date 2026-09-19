---
name: sbdev3198-landlord-pool-cap-risk-accepted
description: "SBDEV-3198 M-2/M-3 landlord Hikari pool cap risk — Nam accepted it 2026-09-03, not a merge blocker for step 5 parts 2-4"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8d467913-4107-4e19-9aa8-6ed0a283a346
  modified: 2026-09-03T18:21:53.309Z
---

PR #288 round-2 review (step 4) instructed reading the live landlord Hikari pool's
`maximumPoolSize` before SBDEV-3198's step-5 fan-out, since each D′-converted job that needs the
dual-lock rolling-deploy mitigation holds BOTH advisory-lock forms simultaneously (2 of 2 landlord
connections against the in-repo `landlord.datasource.maximum-pool-size=2`) during its per-tenant
critical section. PR #291 (step 5 part 1, `CleanUpOldMessagesJob`) crossed that deadline for the
second review round in a row — DB/actuator MCP access was unavailable both times.

Nam's decision, asked directly via AskUserQuestion 2026-09-03: **accept the risk and continue**,
rather than pause the ticket to chase live DB/actuator access. Reasoning: the hold is now scoped to
one tenant's critical section (H-1's per-tenant lock scoping), not the whole per-tenant walk; these
are nightly off-peak jobs; and the failure mode if two jobs' windows genuinely overlap and the cap
really is 2 is a misleading log message plus a skipped occurrence — not data loss or corruption.

**How to apply:** do NOT re-raise this as a blocking finding in step 5 parts 2-4's reviews (or any
later step-5/6 PR) — it is a closed, recorded decision, not an open item. If a live pool-cap reading
becomes available for free later (e.g. actuator MCP starts working), it's still worth doing and
recording, but it is a nice-to-have, not a gate. Full record: `sbdocs/1-Projects/wms2/plan/SBDEV-3198-per-tenant-cron-scheduling.md`
§7a step 5, PR #291's entry.

See also [[wms-mcp-tools-not-surfaced-use-psql-direct]] — DB/actuator MCP servers failing to connect
has been a recurring obstacle across multiple sessions on this ticket, not specific to this decision.
