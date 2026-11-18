---
name: sbdev-3908-on-dev
description: SBDEV-3908 (P22, mobile put-away moved any pallet anywhere) — PR #567 MERGED c80eee6e 2026-10-25, on dev; PRD awaits DevOps promotion
metadata:
  type: project
---
SBDEV-3908 shipped as **wms2-api PR #567**, merged into develop as `c80eee6e` on 2026-10-25. Reviewed tip: `683f89fc`. ClickUp: **on dev**. Verified 2026-10-26: dev `/api/public/version` = `develop-c80eee6e…`.

**Scope:** `storeBoxOnLocation` was folded in at Nam's request.
- A shared `resolveOperatorLocation()` (the caller's location, in the `users` area) is used by the scan, both store endpoints and back-on-lane.
- Damaged/Shipped/Nirwana are refused by name.
- storePalletOnLocation also requires a Pallet type and passes the SBDEV-2821 area gate.

**Evidence:** re-graded on develop ab983389 (unit 8867/0, IT 1004/0). Gate passed (PR comment #issuecomment-6398250757). The 3 PRD probe queries (Damaged/Shipped/Nirwana area config; users located outside `users`; unit loads stuck on such locations) returned 0 on all 4 PRD tenants.

**Dev test DONE 2026-10-25:** two `wms-dev-probe` runs on dev (develop-c80eee6e), as panderson, posted as ClickUp comments. Every refusal passed (foreign pallet/box, Damaged/Shipped/Nirwana/TransferLane01/EmptyTotes, Case through the pallet endpoint, flowbin scan of Damaged, operator outside `users`), and so did every allowed-path control. Restore proof: snapshots `sbdev3908` and `t3908-{ul,su,loc}` all show `restored`. Not run: a full box put-away into a flowbin, which can't be undone and is covered by unit and integration tests.

**Still open (Nam's call, out of scope):** should outbound StagingLane01-06 stay valid put-away targets? Separately, the mobile-ui toast "Container undefined stored in undefined" (`store/putaway.js:153`) needs a UI-repo fix.

**Cleanup done 2026-10-26:** worktree `.claude/worktrees/wms2-api/SBDEV-3908` and its local branch were removed. No plan doc exists (T2, bullets on the ticket), so there is nothing to archive.

**Why:** the fix is on develop/dev only. PRD does not have it until DevOps promotes release/main (see [[deploy-only-to-develop-release-and-main-are-devops]]).

**How to apply:** don't re-implement or re-merge. If SBDEV-3908 comes up, the only open item is PRD promotion, which belongs to DevOps. Background: `.omc/handoffs/SBDEV-3908.md`.
