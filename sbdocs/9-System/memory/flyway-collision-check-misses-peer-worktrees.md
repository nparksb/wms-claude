---
name: flyway-collision-check-misses-peer-worktrees
description: "check-migration-version-collision.sh scans REMOTE branches only — a peer session's unpushed V2.2.x in another worktree collides silently, and its reuse-mode ITs poison the shared Testcontainers DB"
metadata:
  node_type: memory
  type: project
  originSessionId: ef01634c-64c4-48e7-a907-80d33f3df2f6
  modified: 2026-11-04T12:30:29.129Z
---

Measured 2026-11-04 on SBDEV-4002: `bash src/main/resources/db/check-migration-version-collision.sh V2.2.46` reported FREE, yet SBDEV-4007 (a live peer session, worktree `.claude/worktrees/wms2-api/SBDEV-4007`, uncommitted) also held a `V2.2.46__club_run_job.sql`. Found only because the peer's ITs applied ITS V2.2.46 into the shared reused Testcontainers postgres, so my ITs failed `FlywayValidate … checksum mismatch for migration version 2.2.46`.

**Why:** the script fetches remotes; unpushed files in sibling worktrees are invisible to it. The shared reuse container is cross-session state (same family as [[reused-container-accumulates-sequences-not-just-rows]]).

**Fixed:** wms2-api #616 merged 2026-11-04 as `3b77a3c0` (on dev). The script now also scans local branches and every sibling worktree on disk (needs git 2.36+; older git = FATAL). Run it from a worktree based on current develop. Another machine's unpushed claims stay invisible. A follow-up from the SBDEV-4007 session was pending: skip local branches already pushed/merged (duplicate owners, false stale/COLLISION rows), `heads/foo` label when a tag shares the name, ls-tree failure = FATAL.

**How to apply:**
- On a branch older than 3b77a3c0, the manual sweep still applies: `find .claude/worktrees -path '*/db/migration/V2.2.*' -not -path '*/target/*' | sort -V | tail` from the owl root, plus `ticket-lease.sh list` / `ListAgents` to find the owner.
- A 2.2.x checksum-mismatch in an IT you didn't change → query the container's `flyway_schema_history` for that version's `description` before debugging your own migration; it may be a peer's file.
- Run your own ITs with `TESTCONTAINERS_REUSE_ENABLE=false` (private container per run) — avoids both directions of cross-talk; never `docker rm -f` the shared container while a peer's Maven may be running (message them first).
- Resolution precedent: Nam picks which ticket renumbers (4002 kept V2.2.46, 4007 → V2.2.47).
