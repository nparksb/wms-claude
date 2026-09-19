---
name: consolidate-tickets-dont-file-one-per-finding
description: Findings found while working go on the EXISTING ticket if under T3; T3 is proposed, never filed (Nam, 2026-08-28)
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4c28a059-d7ee-4f6d-b720-9e64c9c85a7e
  modified: 2026-08-27T00:00:00.000Z
---

**Consolidate tickets. Do not file one per finding.** Said on 2026-08-20 after I created four
tickets in a single session (two 500s, an SDR gating gap, a shared-endpoint residual, a mangled
method name). Two of them did not earn their own row and were merged down to two total.

**Why:** Nam is the sole reviewer/assignee on this backlog. Ticket count is a real cost to him,
independent of the work behind it. A finding recorded in a plan's residual notes is not lost; a
finding split into its own ticket adds triage, prioritisation and status-tracking load forever.
Investigation depth is welcome — the *filing* is what he wants restrained.

**How to apply:**
- Default to recording a finding in the plan (a residual note, a risk row, a `§14.x` subsection),
  and only file a ticket when it needs its **own owner, decision, or schedule**.
- When several findings do warrant filing, group them by **who does the work and when**, not by
  subject matter. Good grouping axes: "small fixes with no design decision, land after X" versus
  "needs a design decision".
- One ticket may carry multiple fixes as `## Fix 1` / `## Fix 2` sections with a shared
  sequencing constraint. That is preferred over sibling tickets.
- Do **not** collapse work of genuinely different kinds into one ticket — a trivial rename plus an
  architecture decision in one row cannot be closed until both are done, which is worse. Two is a
  reasonable floor when the kinds differ.
- Before filing, ask: does this need its own status, or is it a line in an existing ticket or plan?
- Worked example from that session: 4 → 2. `SBDEV-3016` absorbed the mangled method name (both are
  small non-authorization defects in mobile controllers that must land after SBDEV-2968);
  `SBDEV-3017` absorbed the shared-endpoint residual (both are "what is still reachable after the
  gating plans ship", one design pass). The two absorbed tickets were deleted, and every reference
  in the plan, README and CLAUDE.md was repointed at the survivor.

Related: [[clickup-wms-tickets-fulfillment-backlog]] for where WMS tickets go, and
[[feedback_plan_status_after_implementation]] for the plan-doc side of the same instinct.

**CORRECTED 2026-08-21 — Nam.** This note's "record findings in the plan and file only when a finding
needs its own owner" produced the wrong behaviour. **A finding recorded in a plan or a ticket comment
DIES when the plan is archived** — hard to track, and forgotten. Findings DO belong in tickets.

The lever is **fewer tickets per finding**, not fewer findings filed:
- **one ticket per FIX VISIT** (one code path + one owner), never one per symptom;
- **search the backlog for a ticket sharing the code path and WIDEN it** before opening a sibling;
- still ask before filing — 68 of 94 assigned tickets are already high/urgent, so the priority signal
  is saturated.

Worked example: SBDEV-1615 (picking-started guard 500s) + SBDEV-2473 (same method defers replenishment
re-sync) are one `adjustReservedAmount` visit = one ticket, not two.

And a whole category was being mishandled: **tooling/template/skill defects must be FIXED DIRECTLY**,
not filed and not merely memorised. Eight memories recorded ways verify scripts lie while the template
stayed broken and 51 active scripts inherited the fault. See
[[verify-script-traps]].

**REFINED 2026-08-27 — Nam: widen only what is NOT yet merged to develop.**
*"I want you widen the ticket if they are not merged into the develop, otherwise create a new ticket.
Some tickets have been open too long — I want to move forward rather than dealing with the existing
tickets whose implementations got already merged into the develop."*

This puts a **gate on the search-then-widen step above.** Finding a ticket that shares the code path is
no longer sufficient reason to widen it:

| Candidate widen-target's state | Action |
|---|---|
| unmerged work still in flight (status `Open`/`in development`, or an **open PR**) | **WIDEN it** |
| implementation already merged to `develop` (`on dev`, `on qa`, `on prod`, `Closed`) | **NEW ticket** |

**Why:** widening a ticket whose code already shipped re-opens something Nam considers finished and
re-litigates a closed decision. Ticket *age* is itself a cost to him — a long-open ticket that keeps
absorbing new scope never closes. Merged-and-shipped is the boundary between "still being decided" and
"done"; new scope past that boundary belongs in a fresh row that can be scheduled on its own.

**How to apply:**
- Check merge state, not just ClickUp status: `gh pr list --state open` plus
  `git merge-base --is-ancestor origin/<branch> origin/develop`. A ticket can read `Open` while its
  slices are merged, and can read `on dev` while a follow-up PR is still open.
- A ticket with **any** open PR counts as unmerged → widen.
- Splitting one finding across both destinations is correct when the halves differ in kind.
- Worked example, 2026-08-27: one finding, two halves. The SDR `PATCH /v3/itemdata/{id}` half **widened
  SBDEV-3017** (its own title is "SDR endpoints are ungatable"; PRs #217 + #220 open ⇒ unmerged). The
  `SkuRestController.delete` cache-eviction half became **SBDEV-3135**, because its only code-path
  sibling SBDEV-3033 was already `on dev` — and it was a different concern (eviction vs key
  composition) anyway. I had initially filed both as one new ticket; that was wrong on the first half.

Related: [[deploy-only-to-develop-release-and-main-are-devops]] — `develop` is the merge target that
defines "shipped" for this rule.

## Two gates on widening (Nam, 2026-08-28) — widening is no longer the automatic default

`search-then-widen` now requires **both** to pass, or you file a new ticket instead:

1. **The sibling must be earlier than `on dev`.** At `on dev` its code is deployed, and in this
   workspace the status ladder IS the deployment tracker (`on dev` → `on qa` → `ready for
   deployment` → `on prod` → `Closed`). Widening a deployed ticket either stalls promotion of code
   that already shipped, or promotes it carrying scope nobody built. Nam said `on dev` and **confirmed the same day** that
   "at or past `on dev`" is the intended reading — `on qa`, `ready for deployment`, `on prod` and
   `Closed` block a widening too. Settled.
2. **The ADDED scope must be under T3.** Tier the addition **on its own**, not the combined ticket
   and not the host's existing tier. A T3 addition (authz · data integrity · Flyway · multi-repo ·
   irreversible · unknown root cause) is a second project wearing the first one's number, and it
   silently re-tiers the host so a T1 someone picked up as an afternoon's work goes open-ended.

**This does not reverse the original instruction** — the lever is still *fewer tickets per finding*,
not fewer findings. It narrows *when* widening is the cheaper option. When a gate fails: say so
explicitly, suggest the new ticket, cross-link both ways so the code-path link survives the split.
Never widen quietly, never drop the finding.

**Caught by this immediately:** I widened SBDEV-3142 (16 ungated read endpoints) to cover 106 the
same day. Status gate passed (`Open`) but the added scope was plainly T3 — ~90 more endpoints of
authorization work — so it should have been a new ticket. Tier the addition, not the ticket.

## SIMPLIFIED 2026-08-28 — Nam. This is now the primary rule; everything above is its history.

*"If the new fixes are found during the analysis or implementation add them to the existing tickets if
the size of the fix is less than T3. Otherwise propose creation of the new ticket."*

> **A fix found during analysis or implementation goes onto the EXISTING ticket when its own tier is
> under T3. If it is T3, PROPOSE a new ticket — do not file one.**

What changed: **search-then-widen is no longer the gate.** You used to need a backlog search that
turned up a code-path sibling before a finding had a home; now the default home is **the ticket you
are already working in**. Fewer findings end up homeless, and fewer become their own row.

What survives unchanged:
- **Tier the ADDED scope on its own**, never the host's tier. Ten more endpoints on a gating ticket
  is T3 whether or not the host already says T3.
- **T3 is proposed, never filed**, capped at one per fix visit, and Nam confirms.
- **The `on dev` carve-out** (gate 1 above) is the ONE thing that turns a sub-T3 finding into a new
  ticket: adding scope to already-deployed code corrupts the status ladder. Nam reaffirmed this on
  2026-08-28, hours before simplifying the rest — so it was NOT intended to be swept away, but I kept
  it on my own reading and flagged that to him rather than assuming.
- Tooling/template/skill defects are still **fixed directly**, never filed.
- Never drop a finding to stay tidy.

Authoritative text: `.claude/skills/wms-triage/SKILL.md`, "Ticket policy".

