---
name: wms1-oms-notification-plan-claims-a-fix-that-never-existed
description: The v1 OMS-notification remediation plan says status implemented with a file manifest, and none of it is in git
metadata:
  type: project
---

`sbdocs/1-Projects/wms1/plan/260424-oms-notification-rollback-risk-remediation.md` has
`status: implemented`, `deployed_env: dev`, and a §11 "Implementation Status" listing new files
(`service/util/OmsNotificationHelper.java`, `OmsNotificationProgramIT.java`), 12 modified
production files and ~29 new tests, dated 2026-04-25.

**None of it exists.** Verified 2026-09-08 with two instruments over all refs after `git fetch --all`:
`git log --all -S "OmsNotificationHelper"` and `-S "deferToCommit"` return nothing, and
`git log --all --diff-filter=A --name-only` never adds either file. No branch, no stash, no worktree.
Blind spot: only covers refs present in the local clone; an un-pushed clone elsewhere is invisible.

It also would not have fixed the live outage even if merged — its S10 row gives the picking path only
a `LOG.error` upgrade, and it never adds `REQUIRES_NEW` to `createServiceLog`, which is the actual
cause ([[wms1-aftercommit-message-rows-silently-lost]]).

**Why:** another instance of [[plan-state-probe-beats-reading-plan-status]] — a hand-written
`status:` field with nothing validating it, this time with a fabricated file manifest attached,
which reads far more convincingly than a bare status line.

**How to apply:** before trusting any plan's §Implementation Status, grep git for one distinctive
symbol it claims to have added. Ten seconds, and it is the only thing that catches this.
