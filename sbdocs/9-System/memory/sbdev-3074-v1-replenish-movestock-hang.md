---
name: sbdev-3074-v1-replenish-movestock-hang
description: SBDEV-3074 (WMSv1 WineCo, replenish + Move Stock hang forever) — the replenish half is ALREADY FIXED on origin/develop and undeployed; the Move Stock half is NOT fixed by it
metadata:
  type: project
---

Triaged 2026-08-25; triage block posted as a comment on the ticket. Spun off **SBDEV-3091**
(v2 dead `triggerRefill` branch + `MobileReplenishMultiUnitLoadIT` in neither Maven lane +
`UnitloadBusinessService:283`). WineCo prod (`wh01_om1`, port 25061), SKU `OWE18GWTPG0`, 12-XC14 → SH-A06.

**The replenish half is already fixed and merely undeployed.** `b186a69` / [PR #202](https://github.com/SiteBossInc/wms-api/pull/202),
merged to `develop` 2026-08-24T22:07Z, names `SH-A06` in its own problem statement — a prior session
worked this ticket and never updated it. Prod runs tag **v1.26.47** (2026-08-21), which does not
contain it. `git log v1.26.47..origin/develop` is exactly that fix + its merge; `wms-mobile-ui` is one
commit (#103) ahead of `v1.25.20`. A hotfix release is cleanly scoped — nothing else rides along.
Regression came from `1d5d847` (`calculateOrder` → `REQUIRES_NEW`), released in **v1.26.44** on
2026-07-10, so the latent window opened six weeks before the report.

**`b186a69` does NOT close the Move Stock symptom the ticket also reports.** It edits
`MobileReplenishService` only. `MobileMoveStockService.selectDestination` never calls
`refillFixedLocations`/`calculateOrder` and has no nested REQUIRES_NEW — it cannot self-deadlock. It
hangs as a *victim* of a row lock someone else leaked, at the `UPDATE stockunit` flushed from
`StockunitBusinessService.transferStockToUnitLoad`. `MobileMoveUnitloadService.scanDestination` shares
this exactly. See [[wms1-has-no-lock-timeout-or-leak-detection]] for why "victim" means "forever".

**Unresolved — do not claim the ticket is closed by the release.** Two live candidates for who holds
the lock: the wedged replenish tx (needs `b186a69`), or `ReplenishOrderJob.doCalculationGuarded`, which
holds ONE transaction across a 10-phase run and inside it takes `SELECT … FOR UPDATE` on replenish
source stockunits via `recalculateOpenOrders(true)` — untouched by `b186a69`. Discriminate with one
`pg_stat_activity` + `pg_blocking_pids` query **while a hang is live**; the blocker's `xact_age` and
last query separate them.

**DB facts measured on prod, which reframe severity:** the reported movement actually **completed** at
2026-08-24 12:25:38 (stockrecord shows the 6 units transferred to SH-A06, then picked at 15:51 for
order 930975); the leftover qty-1 order was cancelled 2026-08-25 09:08. But **77 open replenishorders
have `destination_id IS NULL`**, all 77 for items with zero `fix_location_assignment` rows anywhere —
the exact cohort PR #202 says deadlocks — and **18 of them were created on 2026-08-25 alone**. So the
exposure is a daily-recurring queue, not one SKU. 662 of 2149 flowbins have no FLA. Zero wedged
backends and zero advisory locks at triage time, so no `pg_terminate_backend` cleanup was needed.

`v1.26.47:MobileReplenishService` checkDestination has an **inverted guard**: `findByLabelid(code)`
empty → `throw new BusinessException("Unit load already exists.")`. A clean flowbin therefore fails
this scan with a message meaning the opposite, and the `createFixedLocationAssignment` on the next line
is unreachable from that path — which is why the FLA only ever gets created at finish time, inside the
locked transaction. That is a precondition of the whole failure mode.

**v2 is NOT affected** — but by one boolean, not by architecture. v2 also creates the FLA in-tx on a
flowbin (`MobileReplenishService:570`); the SBDEV-2854 FLA-free branch is the *non*-flowbin club lane,
not a flowbin protection. On the single-UL flowbin path the only thing stopping a verbatim repro is
`triggerRefill = false` at `:463`/`:467` — hence SBDEV-3091. The multi-UL path has two real protections
(SBDEV-2575 Fix A + Fix D). Also note v1's fix uses `TransactionSynchronizationAdapter`, **removed in
Spring 6**, so it is not portable to v2 as written — v2 registers bare `TransactionSynchronization`.

Related: [[wms2-requires-new-in-lock-holding-tx-deadlock]], [[sbdev-3003-version-defeated-by-stale-operand]],
[[wms1-has-no-lock-timeout-or-leak-detection]], [[wms2-boxed-long-id-comparison-works-under-128]].
