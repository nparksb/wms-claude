---
name: java-state-constant-has-three-spellings
description: "wms2 state constants appear qualified, bare via static import, and as numeric literals — a one-spelling sweep is a false negative"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 0a3c8a18-078e-4915-af56-c67bd7a21d3d
  modified: 2026-09-15T16:51:08.643Z
---

A `WmsConstants.State.*` constant appears in **three** spellings in wms2-api, and a sweep for one misses
the others:

1. **qualified** — `WmsConstants.State.PACKED`
2. **bare, via static import** — `import static net.aim_ai.wms.service.WmsConstants.State.PACKED;` then
   `position.getState() >= PACKED`. `CustomerorderService` does this.
3. **numeric literal** — JPQL and native `@Query` strings never use the constant: `c.state != 800`,
   `WHEN co.state = 650 THEN 1`.

Measured on SBDEV-3363 (2026-09-15): `git grep "State.PACKED"` returned three of the four guards in the
argument and **silently dropped the fourth** — `CustomerorderService.cancelOrder`'s
`getState() >= PACKED && getState() < WmsConstants.State.CANCELED`, which is the precedent the whole fix
rested on. A separate `\b650\b` sweep then found four more state comparisons in
`OrderMonitorViewRepository`'s native SQL that neither constant spelling could see.

**How to apply:** sweep all three spellings, or accept that any "every site" claim is wrong. Positive control
for the numeric pass: `\b800\b` returns the `state != 800` guards in `CustomerorderRepository`,
`CustomerorderPositionRepository` and `CustomerorderBatchRepository` — if it does not, the instrument is
broken. Related: [[a-zero-scan-needs-a-positive-control]], [[grep-is-ugrep-skips-binary-without-dash-a]],
[[annotation-census-by-grep-is-wrong-by-default]].
