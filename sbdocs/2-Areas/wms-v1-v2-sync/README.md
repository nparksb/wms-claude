---
title: "WMS v1 → v2 Sync Workflow"
type: workflow
status: active
version: both
scope: wms-v1-v2-sync
owner: Nam Park
created: 2026-04-18
updated: 2026-04-18
last_verified: 2026-04-18
verified_by: initial authoring
related:
  - ../../../.claude/skills/wms-v1-sync-sweep/SKILL.md
  - ../../../.claude/skills/wms-v2-migrate/SKILL.md
  - ../../9-System/scripts/ui-sync.sh
  - ./sync-log.md
tags:
  - workflow
  - sync
  - operations
---

# WMS v1 → v2 Sync Workflow

Ongoing operational workflow for migrating changes Arden (and others) make on WMS v1 repos into WMS v2. This is an **area**, not a project — there is no end date as long as v1 continues to receive fixes.

## Scope — three v1 repos, two lanes

| v1 Repo | v2 Target | Lane | Mechanism |
|---|---|---|---|
| `v1/wms-api` | `v2/wms2-api` | **B — port via plan** | `wms-v2-migrate` skill. Never cherry-pick (stack divergence: Java 8↔21, Jakarta namespace, `tenantTransactionManager`, extracted services). |
| `v1/wms-web-ui` | `v2/wms2-web-ui` | **A — cherry-pick** | `sbdocs/9-System/scripts/ui-sync.sh`. Same stack (Nuxt 2 / Vue 2 / Vuetify 2). |
| `v1/wms-mobile-ui` | `v2/wms2-mobile-ui` | **A — cherry-pick** | Same script. Same stack. |

## Cadence

| Event | Cadence | Action |
|---|---|---|
| Normal v1 commits | **Weekly sweep** | One coordinated sweep across all three repos |
| Hot-fix / release blocker | **Ad-hoc** | Port immediately using lane-appropriate tool |
| v1 release tag cut | **Trigger a sweep** | Creates a clean anchor point regardless of weekly cadence |

## How to run a sweep

### Option 1: coordinator skill (recommended)

Invoke the `wms-v1-sync-sweep` skill in Claude Code. It reads `sync-log.md`, enumerates pending commits per repo, classifies them, drafts the sweep report in `sweeps/YYYY-MM-DD-wms-v1-sync.md`, and coordinates the lane-specific tools.

### Option 2: manual

1. Read `sync-log.md` for current anchors.
2. For each v1 repo: `git log <anchor>..develop-arden --oneline`.
3. **UI repos:** run `./sbdocs/9-System/scripts/ui-sync.sh <v1-path> <v2-path>` for each pair.
4. **API repo:** for each pending v1 commit, apply the `wms-v2-migrate` skill's analysis protocol; port manually.
5. Draft a sweep report at `sweeps/YYYY-MM-DD-wms-v1-sync.md` using the plan template shape (one section per v1 commit with applicability verdict).
6. Update `sync-log.md` with the new anchor SHAs.

## Tracking artifacts

- **`sync-log.md`** — one row per sweep, columns: date | wms-api anchor | wms-web-ui anchor | wms-mobile-ui anchor | notes.
- **`sweeps/YYYY-MM-DD-wms-v1-sync.md`** — per-sweep batch plan and outcome. Sections: summary, per-repo pending commits, per-commit verdict, applied commits, skipped commits with reason, follow-ups.
- **Git anchor tags** (UI repos only): `v1-synced-upstream` on each v2 UI repo points at the last-synced v1 SHA; `ui-sync.sh` reads and advances it automatically.

## Hot-fix exception procedure

When a v1 release-blocker hot-fix needs to land in v2 immediately (like `v1/wms-mobile-ui@91e8732` → `v2/wms2-mobile-ui@ace9948`):

1. Port using the lane-appropriate tool (`ui-sync.sh` for UIs; `wms-v2-migrate` for API).
2. Write a migration note in `sbdocs/4-Archieves/wms2/plan/` using the plan template (example: `260418-v1-91e8732-move-stock-assigned-pickable-location-port.md`).
3. **Do NOT advance `sync-log.md` yet** — the next regular sweep covers it.
4. At the sweep, the hot-fix will show as `-` (patch-equivalent) in `git cherry` output and be skipped automatically.

## Guardrails

- Every v2 commit that ports a v1 commit must reference the v1 SHA in the commit message (`-x` flag for cherry-picks adds this automatically).
- Never push without review.
- Never force-move `v1-synced-upstream` forward without verifying the range was actually synced.
- If a v1 commit cannot be ported (architectural divergence, v1-only concern), record it in the sweep report under "skipped with reason" so the next sweep doesn't re-investigate.

## Related

- Script: `sbdocs/9-System/scripts/ui-sync.sh`
- Coordinator skill: `owl/.claude/skills/wms-v1-sync-sweep/SKILL.md`
- API port skill: `owl/.claude/skills/wms-v2-migrate/SKILL.md`
- Plan template: `sbdocs/9-System/templates/wms-plan-template.md`
