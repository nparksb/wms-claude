---
name: wms-v1-sync-sweep
description: Coordinate a weekly WMS v1 → v2 sync sweep across the three v1 repos (wms-api, wms-web-ui, wms-mobile-ui). Use when the user asks to "run the weekly sync", "sweep v1 into v2", "port Arden's commits", "catch v2 up to v1", or similar. Reads sync-log.md for anchors, enumerates pending commits per repo, classifies each into UI cherry-pick vs API port and into bucket (cherry-pick-clean / adapt-and-apply / already-done / not-applicable / needs-investigation), drafts a sweep report, coordinates ui-sync.sh for UI repos and wms-v2-migrate for the API repo, then updates sync-log.md. Does NOT replace the existing tools — it stitches them together.
---

# WMS v1 → v2 Sync Sweep (Coordinator)

Coordinates a weekly v1 → v2 migration sweep across the three v1 repos. Invoked when the user says "run the weekly sync", "sweep v1", "port Arden's commits", or similar. Not for single hot-fix commits — for those use `wms-v2-migrate` (API) or `ui-sync.sh` (UI) directly.

## What this skill IS and is NOT

- **IS:** a thin coordinator that reads/writes `sync-log.md`, enumerates pending commits, drafts the sweep report, and dispatches to the right lane per repo.
- **IS NOT:** the actual port mechanism. Lane A uses `ui-sync.sh`; Lane B uses `wms-v2-migrate`. This skill invokes them; it doesn't re-implement them.

## Inputs

One of:
- "Run the weekly sync"
- "Sweep v1 commits from Arden"
- Explicit start/end SHAs per repo (override the log anchors)
- Dry-run mode: "preview only, don't apply"

## Workflow

Execute in this order. Do not skip steps.

### 1. Read current state

- Open `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md` and extract the most recent anchor row.
- Confirm `v1-synced-upstream` tags in the two v2 UI repos match the log (if they don't, alert the user and stop — drift means a prior sweep didn't close cleanly).

### 2. Enumerate pending commits per repo

For each of the three v1 repos run:

```
git -C <v1-repo> log --oneline --reverse <anchor>..develop-arden
```

If a repo's pending list is empty, note "nothing to sync" for that repo and move on.

### 3. Classify each pending commit

For every pending commit, produce one table row:

| Repo | v1 SHA | Subject | Lane | Bucket | Proposed action |
|---|---|---|---|---|---|

- **Lane:**
  - UI repos → **A (cherry-pick)**
  - API repo → **B (port via plan)**
- **Bucket:**
  - **cherry-pick-clean** — Lane A, no conflicts expected (most mobile/web UI commits).
  - **adapt-and-apply** — Lane B, needs v2 translation (Jakarta namespace, `tenantTransactionManager`, extracted services).
  - **already-done** — patch-equivalent in v2 per `git cherry` (Lane A) or manually verified equivalent (Lane B).
  - **not-applicable** — v1-only concern (Java 8 workaround, `Location.equals()` rewrite that v2 doesn't need, etc.).
  - **needs-investigation** — touches an area where v2 architecture diverged significantly; defer to `wms-investigation-report` before acting.

### 4. Draft the sweep report BEFORE executing

Create `sbdocs/2-Areas/wms-v1-v2-sync/sweeps/YYYY-MM-DD-wms-v1-sync.md` using the frontmatter conventions from `sbdocs/9-System/templates/wms-plan-template.md`. Required structure:

1. Summary — totals per repo, per bucket.
2. Per-repo pending commit table (from step 3).
3. Per-commit detail for `adapt-and-apply` and `needs-investigation` entries — link to or defer the full plan writing to `wms-v2-migrate`.
4. Planned actions (execution order).
5. (Filled after execution) Applied commits + resulting v2 SHAs.
6. (Filled after execution) Skipped with reason.
7. Follow-ups (new issues, investigation reports spun off, next-sweep carryovers).

Show the report to the user and wait for confirmation before step 5 — unless dry-run mode, in which case stop here.

### 5. Execute per lane

**Lane A (UIs):**
```
./sbdocs/9-System/scripts/ui-sync.sh <v1-path> <v2-path>
```
The script is interactive — it shows the preview, asks for confirmation, cherry-picks with `-x`, fast-forward merges, and moves the tag. If conflicts halt it, resolve manually following the on-screen instructions; update the sweep report accordingly.

**Lane B (API):**
- For each `adapt-and-apply` commit, invoke `wms-v2-migrate` to produce (or append to) a migration plan section.
- Port manually in v2/wms2-api following the plan.
- v2 commit message format: `port v1 <sha> — <summary>` with body describing v2 adaptations made.

### 6. Update sync-log.md

After all successful ports:

- Add a new row with today's date.
- For UI repos: copy the new `v1-synced-upstream` tag SHA (the script already advanced it).
- For the API repo: set the anchor to the last v1 SHA you ported.
- Under "Notes", list any deferred items (cross-reference the sweep report).

### 7. Close the sweep report

Fill in sections 5 and 6 of the sweep report (applied commits with v2 SHAs; skipped-with-reason entries). Set `status: completed`.

## Classification heuristics (for step 3)

These are fast-path rules; always read the diff before committing.

**Auto-classify as `cherry-pick-clean`:**
- UI repo, diff touches only `.vue` / `.js` / `.scss` / `package.json` (with a trivial dep bump), AND no files in `nuxt.config.js` / `store/index.js`.

**Auto-classify as `adapt-and-apply`:**
- API repo, any diff — always needs v2 adaptation review.

**Auto-classify as `needs-investigation`:**
- Touches migration-sensitive subsystems where v1/v2 are known to diverge: `tenantTransactionManager` wiring, Keycloak plugin config, JPA entity equality, extracted services (`PickingOrderMergeService`), or anything mentioning OSIV.

**Auto-classify as `not-applicable`:**
- Commit subject contains "Java 8 workaround", "revert Jakarta", or mentions a file that exists in v1 but not v2 (e.g., `mbassador` / old logging bridge).

**Fallback:** if in doubt, `adapt-and-apply` for API, `cherry-pick-clean` for UI — the tooling will surface conflicts if the classification is wrong.

## Error recovery

- **Drift between git tag and sync-log.md:** stop and alert. Don't auto-reconcile — the user needs to decide which is authoritative.
- **Cherry-pick conflict in Lane A:** `ui-sync.sh` halts with specific instructions. Follow them; update the sweep report's "skipped" section if a commit is abandoned.
- **Port decision is ambiguous:** open an investigation via `wms-investigation-report` and mark the commit as `needs-investigation`; defer to a later sweep.
- **Mid-sweep interruption:** the sync-log is the source of truth — never move the anchor forward if the port didn't actually land.

## When NOT to use this skill

- Single hot-fix commit → use `ui-sync.sh` or `wms-v2-migrate` directly.
- Ad-hoc v2-only feature work → unrelated to this skill.
- Setting up a new v1/v2 repo pair → use the one-time setup section of `sbdocs/2-Areas/wms-v1-v2-sync/README.md` instead.
- Backfilling historical v1 commits that predate the anchor → move the anchor backward manually and run a regular sweep.

## Output locations

- Sweep report: `sbdocs/2-Areas/wms-v1-v2-sync/sweeps/YYYY-MM-DD-wms-v1-sync.md`
- Log update: `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md`
- API plan spillover: `sbdocs/1-Projects/wms2/plan/` (if a single API commit warrants a full plan), archived to `sbdocs/4-Archieves/wms2/plan/` after implementation.
- Hot-fix retroactive notes: `sbdocs/4-Archieves/wms2/plan/v1-<sha>-<kebab>.md`.

## References

- Workflow definition: `sbdocs/2-Areas/wms-v1-v2-sync/README.md`
- Sync log: `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md`
- UI cherry-pick script: `sbdocs/9-System/scripts/ui-sync.sh`
- API port skill: `owl/.claude/skills/wms-v2-migrate/SKILL.md`
- Investigation skill: `owl/.claude/skills/wms-investigation-report/SKILL.md`
- Plan template: `sbdocs/9-System/templates/wms-plan-template.md`
