---
name: hub-shipped-tickets
description: Tickets merged/on dev or closed; kept for their landmines and follow-ups. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Shipped-ticket notes (on dev or later)**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [SBDEV-3190 singleton tenant-state (4 fixes + rail)](sbdev-3190-singleton-tenant-state.md) — MERGED on dev `20b60209`; the axis is NOT always the tenant; rail has 4 blind spots
- [SBDEV-3197 JWT authority cache](sbdev-3197-jwt-cachemap.md) — ON DEV #651 c0bd417b; full-token compare is the ONLY cross-tenant guard; issuer/aud gap → SBDEV-4075
- [SBDEV-3205 pick-timeout query unsatisfiable](sbdev-3205-pick-timeout-query-unsatisfiable.md) — CLOSED, both fixes on develop; squash-merge reads as unmerged
- [SBDEV-3353 parcel source guard](wms2-parcel-source-guard-sbdev-3353.md) — PR #416 on dev (27280283); 6 sites; callee sweep missed transferToDamaged
- [SBDEV-3862 DONE + archived](sbdev-3862-paused-handoff.md) — follow-ups are P21/P23/P24; dev Damaged admits only Case/PickLocation
- [SBDEV-3908: MERGED c80eee6e, on dev](sbdev-3908-on-dev.md) — put-away rules; cleanup done; only PRD promotion (DevOps) left
- [SBDEV-3310 real state](sbdev3310-club-run.md) — #351 in prod since Sept despite "on dev"; V2.2.48 (#623/#625) unreleased; rest moved to 4007
