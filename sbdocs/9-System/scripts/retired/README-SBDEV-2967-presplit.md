# Retired 2026-08-21 — `verify-SBDEV-2967-web-ui-function-gating-enforcement.sh`

Superseded by the SBDEV-2967 split into slices A / B / C:

- `../verify-SBDEV-2967-A-axios-403-denial-not-logout.sh`
- `../verify-SBDEV-2967-B-web-view-gating.sh`
- `../verify-SBDEV-2967-C-web-action-gating.sh`

**Do not resurrect it.** 10 of its 50 rows were wrong at the time of retirement, and all
ten read as honest work-not-done rather than as script defects:

| Row(s) | Defect |
|---|---|
| `E1`–`E6` | Assert the action constants appear in `StockunitService.java` / `UnitloadService.java` — the **service-layer placement the plan's own architect review had already reversed**. A correct controller-level implementation leaves those files untouched, so these are permanent reds. |
| `E8` | Pins `ADJUST_LOCK_DAMAGED` as *"enforcement is UNCHANGED (regression pin)"*. It is **not** enforced on `setLockDamaged` (slice C §0.E). Following this row ships `/transferToDamaged` open. |
| `E9` | Asserts **no** `WEB_UI_ACTION_*` appears inside a `@RequiresFunction`. That is exactly what the corrected design requires — **this row would FAIL a correct implementation.** Inverted as slice C's `P1`. |
| `E7` | Targets `LabelPrintingService`, which is not a convergence point for the tote surface (4 write endpoints across 3 controllers). Deferred to tranche C2. |
| `R2` | *"the 5 shared controllers stay unannotated by this plan"* — SBDEV-2968 legitimately annotated `StockUnitController` on 2026-08-21, so this **can never pass again**. Replaced by slice C's `R1`–`R3`, which pin the 2968 annotations instead of forbidding them. |

Two further gaps: there were **no rows at all** for AC-19 (the axios 403 fix, now slice A)
or for the user-admin self-escalation gate (moved to SBDEV-3013).

The pre-split plan document is at
`sbdocs/4-Archieves/wms2/plan/SBDEV-2967-presplit-2026-08-21.md`.
