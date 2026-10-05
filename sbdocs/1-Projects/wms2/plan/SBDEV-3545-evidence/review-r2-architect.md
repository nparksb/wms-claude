---
ticket: SBDEV-3545
lane: ralplan round 2 — Architect (opus)
snapshot: plan-r2-snapshot.md
base: 286b5673 (unchanged)
verdict: APPROVE with minor revisions — no High; 1 Medium, 3 Low
---
Round-1: H-1 RESOLVED · M-1 RESOLVED (option a correct; "masks" = hides a test failure; runtime withdrawnResourcesExposeNoWriteVerb pins the per-type block; state arithmetic WITHDRAWN 51 = SDR_WRITE_WITHDRAWN 50 + UserRole; 51+8=59) · M-2/M-3/M-4 RESOLVED · L-1 PARTIAL (pin `$.id` in AC-1 GET control — exposeIdsFor RestConfiguration:891-892) · L-2 RESOLVED.
Checks: unique violation surfaces as plain DataIntegrityViolationException at commit (LockTimeoutHibernateJpaDialect extends HibernateJpaDialect, TenantDatabaseConfig:111/158; precedents UserController:512, ReplenishController:133); getMostSpecificCause→PSQLException→"23505". AC-9 regex matches exactly the 8 predicates, 0 non-grant hits. dev_wh01_om1 is the ONLY active dev tenant (landlord-dev 4 rows, 1 active) — dev post-boot check is effectively certain.
- N-1 (Medium) Fix D misses: PutForCreationWithdrawalContextTest:67 @DisplayName "item PUT-to-existing intact", :91 "stays open on all four types"; SdrWriteWithdrawalContextTest:26 "50 resources", :29 "9 resources that must KEEP"; AccessChainSdrWriteExposureUnitTest:63-64 "Deliberately NOT touched … UserRole … $put('/userRole'"; MustStayWritableCollectionPostWithdrawalContextTest:79; CustomerorderTransferLaneSdrWriteContextTest:68. Extend instrument with `KEEP|intact|all four|NOT touched|\b(50|9) resources`; control :67.
- N-2 (Low) @Version (AbstractBaseEntity:34): overlapping edits → OOLFE → RestExceptionHandler:361; only sequential edits are last-write-wins.
- N-3 (Low) AC-9: add left boundary (?<![A-Za-z0-9_]), case-insensitive; alias-dependent — add file-level trigger (V*.sql referencing mywms_(role|group) and comparing .name to a literal; allow-list V2.2.00,18,19,20,21,34); pin == 8.
- N-4 (Low) AC-6b: drop the message-substring OR; number immutable so any 23505 here is the name index; cite UserController:512.
