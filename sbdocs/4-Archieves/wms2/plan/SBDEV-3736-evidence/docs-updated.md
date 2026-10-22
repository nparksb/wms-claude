# SBDEV-3736 docs updated (2026-10-15)

Source: branch `feature/SBDEV-3736-returns-audit-linkage` @ `b002934f`, unmerged. All additions marked as branch-pending.

- `3-Resources/architecture/wms2-state-machine-catalog.md`: §4.8 SBDEV-3736 note (finisher write sites, exact-match rule, locking, residual windows, RETURN can reach FINISHED via dock receive/adjust/delete, `markFinished` entity save); §9 change-log row. `last_verified` NOT bumped.
- `3-Resources/workflows/wms2-receiving-putaway-workflow.md`: SBDEV-3736 block before §4.4 (items 1-5 plus returnsAudit), pointer in §3.5, §11 log row. `last_verified` NOT bumped.
- `3-Resources/architecture/wms2-function-to-docs-map.md`: not changed. It names ReportController only as a class in a row and does not enumerate its endpoints.

Correction to brief: adjust/delete for TRANSFER use `CODE_RECEIVING_REGULAR` (`"RECEIVING"`), not `RECEIVING_TRANSFER`.
