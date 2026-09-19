---
name: v1-its-blocked-roid-view-drift
description: All v1/wms-api @SpringBootTest ITs fail at context load — ro_id missing from replenishment_monitor_view (SBDEV-2384 drift)
metadata: 
  node_type: memory
  type: project
  originSessionId: d45982e5-5dfe-4e71-a268-42bb74813e48
---

As of 2026-06-24, every v1/wms-api `@SpringBootTest` integration test fails at context load with `SchemaManagementException: Schema-validation: missing column [ro_id] in table [replenishment_monitor_view]`. This blocks the whole failsafe phase (any `*IT`), including CI's `mvn verify`, regardless of the test.

Root cause: `ReplenishmentMonitorView.java:122` declares `private Long roId;` with no `@Column` override (so Hibernate expects column `ro_id`), but the view migration `V1.26.29__replenishment_monitor_view_flag_based_classification.sql` (SBDEV-2384, commit `4652a80c` / `a6e2b2bb`) selects `ro.number AS ro_number`, `ro.itemdata_id AS i_id`, etc. — never `ro.id AS ro_id`. The view + entity drifted.

FIX STAGED 2026-06-24 (working tree on `develop`, NOT yet committed): migration `V1.26.30__replenishment_monitor_view_add_ro_id.sql` re-emits the V1.26.29 view and appends `t4.ro_id AS ro_id` (matches the already-correct native `getReplenishViewSummary`). Verified: a v1 IT now loads context (`SchemaManagementException` gone). Separate latent bug in the SBDEV-2384 area — NOT part of [[SBDEV-2481 stale pick-line plan]]; review/commit independently (own branch/ticket).

Impact on TDD/work: the SBDEV-2481 gate IT `PickLineRealignmentIT` compiles but cannot RUN until this is fixed. Also: surefire has pre-existing failures `ClientRepositoryH2Test` / `LocationRepositoryH2Test` (ApplicationContext load) — scope around with `-Dtest='!ClientRepositoryH2Test,!LocationRepositoryH2Test'`. See [[run-v1-wms-api-testcontainers-its-locally]] for the SDKMAN/argLine harness.
