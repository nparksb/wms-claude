---
name: wms2-replen-monitor-view-missing-section-and-ro-id
description: v2 replenishment_monitor_view lacks section_name AND ro_id vs the 19-field entity — SBDEV-2384 v2 port gap
metadata: 
  node_type: memory
  type: project
  originSessionId: 0195c630-46e9-46f3-b582-77fcce2d96ab
---

The v2 `ReplenishmentMonitorView` entity (`@Table(name="replenishment_monitor_view")`, REST-exposed via `@RepositoryRestResource(path="replenishmentMonitorView")` findAll) has 19 mapped fields, but every v2 view definition exposes only 17 — missing exactly `{section_name, ro_id}`. Confirmed in base `migration/V2.2.00__base_v2_schema.sql` (SELECT ~1998-2014, GROUP BY ~2082), onboarding `V2.1.16`, and UTC `V1.2.04`.

- `ro_id`: the v1 follow-up `V1.26.30__…add_ro_id.sql` was never ported. v1 entity had only `roId`.
- `section_name`: v2-ONLY. The v2 entity (`ReplenishmentMonitorView.java:17-18` `@Column(name="section_name")`) declares a field v1's entity never had; no v2 view provides the column.

The core SBDEV-2384 flag-based fix (`loc_area.useforreplenish=true`) IS already in v2 (inline query + all views + V2.1.16). Only the column-reconciliation follow-up is missing.

Impact: test profile `ddl-auto=validate` → `SchemaManagementException` at context load (compounds [[wms2-it-harness-broken-sbdev-2217]]); prod `ddl-auto=none` → latent `column does not exist` on `GET /replenishmentMonitorView` findAll (that HAL surface is currently UNUSED — real consumer is the native `getReplenishViewSummary()` superset projection at `ViewDtoService:1208`).

Fix implemented (2026-07-13, NOT yet committed): SINGLE file `db/migration/V2.2.02__replenishment_monitor_view_add_section_and_ro_id.sql` — CREATE OR REPLACE VIEW appending both columns as trailing 18th/19th. Only ONE file needed: both provisioning paths (brand-new DB via `flyway migrate db/migration/`, and onboarded v1→v2 DB) converge at the V2.1.16 watermark then both take V2.2.x deltas from db/migration/ — so no onboarding-side delta. (Earlier plan wrongly specified a 2nd onboarding V2.1.17 + a drift guard; dropped.)

Gate test: `v2/.../integration/schema/ReplenishmentMonitorViewSchemaIT.java` — bare Testcontainers + `flyway migrate classpath:db/migration` + JDBC information_schema check. Red→green proven. MUST run with `mvn clean` — a stale `target/classes/db/migration/` (33 leftover pre-reorg onboarding SQLs) pollutes the classpath and makes Flyway replay the old chain (dies at V1.2.01 outbox ref = [[wms2-it-harness-broken-sbdev-2217]]). The onboarding schema/ chain is NOT forward-runnable from empty (that IS the 2217 break), so gate deliberately uses db/migration base dump, not the onboarding chain. Plan: `sbdocs/1-Projects/wms2/plan/SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md`. Pairs with [[feedback_plan_status_after_implementation]].

**Landed:** the column reconciliation is DONE via `V2.2.02` — the migration above was committed after this note was written.
