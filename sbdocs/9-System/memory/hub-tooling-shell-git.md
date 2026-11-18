---
name: hub-tooling-shell-git
description: Workstation tooling, shell portability, git workflow and agent-harness quirks. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Tooling, shell, git, OMC, ClickUp quirks**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [OMC subagent final messages return truncated](omc-subagent-final-message-truncated.md) — recover it from `tasks/<agentId>.output` JSONL
- [Lane A git cherry false positives](lane-a-git-cherry-false-positives.md) — `git cherry +` over-reports on v1→v2 UI
- [ClickUp comment API drops markdown tables](clickup-comment-api-drops-markdown-tables.md) — reads back as "undefined"; use lists, read back
- [git add -A in a worktree sweeps .omc/state](git-add-all-in-worktree-sweeps-omc-state.md) — leaked session files into an OMS commit; stage explicit paths, exclude .omc/
- [Idle executor on bg suite stalls](subagent-background-notification-can-stall.md) — a lane waiting on its background mvn suite may never wake; watch the build yourself
- [Squash via reset --soft reverts peers](squash-by-soft-reset-onto-moved-origin-reverts-peers.md) — use merge-base
- Process-match self-hits: [pgrep -f wait loops match themselves](pgrep-f-wait-loop-matches-itself.md) · [pkill -f kills its own shell](pkill-f-matches-its-own-shell.md)
- [Claude Code add-ons (LSPs, Context7, Serena, …)](claude-code-tooling-installed.md) — PATH/JDK pins
- [Stacked v2 PRs: merge base-first into develop](stacked-v2-pr-merge-order-orphan-trap.md) — or orphaned
- [omc = shim to plugin CLI; ralph works](omc-cli-lacks-ralph-verify.md) — old 4.x globals removed 2026-10-24; ~/.local/bin/omc follows installed_plugins.json
- [Scripts must run on Mac AND Linux](owl-tooling-scripts-break-on-macos-bsd-userland.md) — run .claude/scripts/portability-check.sh after any script edit
- [Bracket ranges follow the locale](bracket-ranges-follow-locale-set-lc-all-c.md) — glibc en_US matches é in [A-Za-z]; set LC_ALL=C (PR #577 CI)
- [ClickUp links: fetch the task id, never construct it](clickup-links-fetch-task-id-never-construct.md) — custom ID ≠ URL id; wrote a made-up 3310 link on 2026-11-07
- [gh token needs `workflow` scope to push workflow files](gh-token-needs-workflow-scope-for-workflow-pushes.md) — refresh -s workflow + setup-git; run the device flow as a background Bash and hand over the code
