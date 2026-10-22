---
name: is-ancestor-does-not-prove-a-fix-shipped
description: "`git merge-base --is-ancestor <fix> <prd commit>` passes even when the fix was REVERTED on release — git grep the fix's symbol at the deployed commit instead"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 8f3d8ebe-48d9-417a-ad1d-3a6fb4afd805
  modified: 2026-10-12T17:38:56.975Z
---

To prove a fix was in a PRD build, `git grep` a symbol the fix adds **at the deployed commit**, with a positive control on `origin/develop`. Do not rely on ancestry.

**Why:** measured on 2026-10-12. While investigating WineCo cancelled-order stock that shipped, I checked that SBDEV-3547 PR-B (09306eed) was an ancestor of the v2.0.149 prod promote c7e0b023. It was, so I concluded the fence was live on PRD from 2026-10-02. That was wrong. a3380070 "Hold SBDEV-3547 PR-B from production: revert #431 on release" removed it from that very build. `git grep releaseUnlessGoodsOut c7e0b023` returns 0 files; on develop it returns 3. The fence only reached PRD with v2.0.150 (fa7f34f4, WineCo Flyway 2026-10-08 08:06 UTC). A review lane (tracer) caught it.

**How to apply:**
- "Was fix X in build Y?" means `git grep -l <symbol-X-adds> <Y>`. Run the same grep on develop as a positive control.
- Release holds happen through revert commits on `release` (pattern: "Hold … from production: revert #NNN on release" / "Bring … back: revert <sha>"). Run `git log origin/main --grep=<ticket>` to see them.
- To tie a deploy time to a commit, use the tenant DB's `flyway_schema_history.installed_on`: it is UTC on the v2 DBs and lands about 15 minutes after the main merge. Then match the max migration version to the commit.
- **Happened again on 2026-10-13 (SBDEV-3074):** I claimed SBDEV-3678 was on prod from an ancestry check, but v2.0.151 had held it out (revert 07afea75). This memory existed and did not prevent the mistake, so the rule now also lives in wms-triage probe Q1, where it runs before any "already fixed" verdict. List every hold-out with `git log origin/main --oneline | grep -i "hold .* out"`.
- Related: [[wms2-deployed-image-differs-from-branch-head]], [[absence-of-a-path-is-not-absence-of-the-guarantee]]
