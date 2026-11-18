# Doc Drift Audit — SBDEV-4031 — 2026-11-06

Scope: `git diff origin/develop...HEAD` in `.claude/worktrees/wms2-api/SBDEV-4031` (HEAD e60a10c4), 8 src/main files.
Method: `grep -rlw <ClassName>` over `sbdocs/3-Resources/` (v2 docs only; v1 is reference-only), then a grep for the specific
symbols whose behaviour changed (`recalculateReplenishmentOrderWithoutFixedLocationAssignment`, `RecalcContext`, `alignDestination`,
`deleteEmptyFixAssignmentWithoutStockToReplenish`, `deleteByUser`, `findByStateLessThanEqualAndDestinationIdIsNull`, `lock order`).
Blind spot: a doc that describes the behaviour without naming any of these symbols is not found.

Merge check: branch is 51 behind origin/develop; `git merge-tree` is clean and none of the 51 commits touch the 8 files.

## Summary
- Changed src/main files: 8 · v2 docs implicated: 13 (by class name) · docs with claims this change makes false: 3
- Staleness: all implicated docs ≤ 60 days except `wms2-state-machine-catalog.md` and `wms2-cancel-cascade-workflow.md`
  (2026-05-08, red) — neither carries a claim this change invalidates.

## Section 1 — Claims this change makes false (update with `✓ merged(SBDEV-4031: #637 65444c6b, 2026-11-07)`)

| Doc | Where (quoted) | Now true |
|---|---|---|
| design/wms2-replenishment-design.md | maintenance table, `recalculateOrder(orderId, ctx)` row: "then checks FLA, validates/redirects source" | When the order's destination is null, a scalar FLA lock (`lockIdByItemdataId`) is taken BEFORE the order lock (per-order hint `findItemdataIdByIdAndDestinationIdIsNull`; `recalculateForItem` takes it once before the loop). On a stale hint (destination detached after the hint) no FLA lock is taken after the order lock and alignment is skipped for that pass (§10.z). |
| design/wms2-replenishment-design.md | "3. **Maintenance alignment** — … calls `resolveActiveAssignment` to fetch the FLA, then `alignDestination`" | `alignDestination` reads the location via `findActiveLocationIdByItemdataId` under the FLA lock, not from `RecalcContext`. |
| design/wms2-replenishment-design.md | service table rows for `recalculateReplenishmentOrderWithoutFixedLocationAssignment()` (`tenantTransactionManager` / "Delegates to `ReplenishorderService`") and job phase 9 row | Non-transactional loop over `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById`; each order runs in its own `REQUIRES_NEW` `assignFixedDestination` (FLA lock → order lock), per-order catch, WARN logs exception class only. The `ReplenishOrderJobService` wrapper no longer carries `@Transactional`. |
| design/wms2-replenishment-design.md | delete entry-point table, `delete(Long)` / `deleteByUser(Long)` rows | Both lock the FLA row first (`findByIdForUpdate`); a FLA deleted/moved meanwhile → skip. `delete(Long)` is `propagation=MANDATORY`; the cron no longer pre-reads the FLA; `ReplenishOrderJob` catches `PessimisticLockingFailureException` on the delete sub-op (plus a final `catch(Exception)`). |
| design/wms2-replenishment-design.md | "*Move:* `move()` re-seeds a still-inherited FLA from the destination location's default." | `move()` also locks F → owning Pickingorders → L′ → replen orders ascending; refuses a missing/non-flowbin destination, an order in processing, or an order already at L′ before any P/L′ lock; re-points PROCESSABLE orders from L to L′. |
| design/wms2-replenishment-design.md | repository table (`findByItemdataIdIn` row area) | New FLA finders `findByIdForUpdate`, `lockIdByItemdataIdAndLocation`, `lockIdByItemdataId`, `findActiveLocationIdByItemdataId`; replenishorder finders `findItemdataIdByIdAndDestinationIdIsNull`, `findIdsByStateLessThanEqualAndDestinationIdIsNullOrderById`, `existsByItemdataIdAndStateGreaterThanAndStateLessThan`; all `exported=false`. Retired: SDR search `findByStateLessThanEqualAndDestinationIdIsNull` (0 UI callers). |
| architecture/wms2-scheduled-jobs-catalog.md | "**Per-step TX** — all inner service methods are `@Transactional(... REQUIRES_NEW)`" and "`recalculateReplenishmentOrderWithoutFixedLocationAssignment` has no loop at all" | Phase 9 now has a loop of per-order REQUIRES_NEW calls and no outer tx; `calculateAutomaticOrder` returns null (skip) when the FLA at the destination is gone (C0). |
| architecture/wms2-transaction-osiv-boundary-map.md | §8.5 lock-order bullets | Add an SBDEV-4031 bullet: FLA is the single lock object for destination decisions; order FLA → Pickingorders → L′ → orders ascending → SU; no path locks FLA after an order; multi-UL confirm never locks FLA (ABBA-5); scalar `@Lock @Query SELECT f.id` (FOR NO KEY UPDATE) where the PC may already hold the FLA. |

## Section 2 — Pre-existing drift found on the way (not caused by this change)

| Doc | Claim | Code |
|---|---|---|
| architecture/wms2-transaction-osiv-boundary-map.md | "`wms.tenant.lock-timeout-ms`, default 10 s" | `application.properties`: `wms.tenant.lock-timeout-ms=3000`; `TenantDatabaseConfig`: `@Value("${wms.tenant.lock-timeout-ms:3000}")` |

## Section 3 — No doc coverage
None — every changed class is referenced by `wms2-replenishment-design.md`. No REST reference lists the retired SDR search.

## Section 4 — Recommended actions (ranked)
1. `wms2-replenishment-design.md`: the six rows above, each marked `✓ merged(SBDEV-4031: #637 65444c6b, 2026-11-07)`.
2. `wms2-transaction-osiv-boundary-map.md` §8.5: new SBDEV-4031 lock-order bullet; fix the 10 s → 3000 ms default.
3. `wms2-scheduled-jobs-catalog.md`: the Per-step TX paragraph (phase 9 and C0).
