---
name: v2-only-no-v1-fixes-unless-asked
description: "Fix v2 only — do not plan, file, or implement v1/wms-api fixes unless Nam explicitly asks"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 06947b5e-b469-4ffe-99d7-c41704a80bab
  modified: 2026-08-20T00:40:07.534Z
---

**Directive from Nam, 2026-08-19: "We are going to fix only v2 from now on unless I explicitly tell you to."**

Applies to `v1/wms-api`, `v1/wms-web-ui`, `v1/wms-mobile-ui`, and `v1/oms`. Do **not**:

- file v1 tickets or paired v1 plans as follow-ups from v2 work;
- add "port this to v1" items to a plan's §4 V1/V2 Applicability;
- implement v1 changes on your own initiative.

**Why:** v1 is being wound down in favour of v2; effort spent there is wasted, and a v1 ticket on the board implies work someone is expected to do.

**How to apply:** when a v2 investigation finds the same defect in v1 — which is common, since v2 was forked from it — **state the finding and stop there.** Record it in the v2 plan as an observation, not as an action item, and do not create the ticket. Only act on v1 when Nam names v1 explicitly in the request.

Concrete instance: SBDEV-3005's §6 originally called for "a paired v1 ticket for Bugs 2 and 3" after confirming `v1/.../RoleController.java:82-102` carries the identical non-atomic replace and misleading log lines. That ticket was dropped on this directive; the *finding* stays in the plan. See [[sbdev-3005-role-function-composite-key-swap]].

This supersedes the `wms-v2-migrate` and `wms-v1-sync-sweep` skills' default assumption that v1↔v2 parity is desirable — those still run when asked for, but are no longer a reason to open v1 work unprompted.
