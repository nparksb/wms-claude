---
name: flyway-version-pick-sweep-all-remote-branches
description: "Pick a new wms2-api Flyway version by sweeping ALL remote branches, never `ls db/migration/` — in-flight unmerged branches hold versions that are invisible from develop"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 2b3c103c-8c7b-423c-bd67-eac809f8718d
  modified: 2026-08-03T20:52:27.819Z
---

When authoring a new `wms2-api` Flyway migration, choose the version number by sweeping **every
remote branch**, not by listing `src/main/resources/db/migration/` in your worktree:

```bash
for b in $(git branch -r --format='%(refname:short)' | grep -v HEAD); do
  git ls-tree -r --name-only "$b" -- src/main/resources/db/migration 2>/dev/null
done | grep -oE 'V2\.2\.[0-9]+' | sort -u -V | tail -3
```

**Why:** an unmerged branch's migration is invisible from `develop`, so a directory listing shows a
stale head and makes the next number *look* free. Caught 2026-08-03 on SBDEV-2778: `develop`'s head
was `V2.2.07` (SBDEV-2777, merged `ee92337`), so `V2.2.08` looked free — but SBDEV-2801 already held
it on `origin/claude/sbdev-2801-report-500-utkj8x`. Nothing fails until the second ticket merges, then
Flyway dies with "Found more than one migration with version 2.2.08". I picked from worktree scope and
got it wrong; Nam caught it by asking why the number was what it was. SBDEV-2778 moved to `V2.2.09`.

**How to apply:** run the sweep when drafting the plan **and again immediately before opening the PR**
— a sibling ticket can claim your number in between, and reservation is first-to-merge, not
first-to-write. Record the chosen version plus the branches you swept in the plan's prerequisites so a
reviewer can re-check. Flyway versions are append-only global identifiers: **never per-ticket, never
reused, never "overwritten"** — editing an already-applied migration's content causes a checksum
mismatch, whose recovery is deleting the `flyway_schema_history` row, never `flyway repair`
(see [[wms2-sysprop-live-keys-exceed-code-constants]] for the V2.2.05 amendment that cost this once).

Corollary worth checking at the same time: other agents/sessions are often driving sibling SBDEV
tickets in this repo (`claude/sbdev-*` branch names). A version sweep doubles as discovery of in-flight
work that needs a rebase-order agreement.

Applying migrations is a separate concern — see [[flyway-runbook-covers-dev-and-uat-via-env-flag]].
Related: [[sbdev-2777-stock-history-client-id-blind]] (owns V2.2.07, merged but applied to no DB).
