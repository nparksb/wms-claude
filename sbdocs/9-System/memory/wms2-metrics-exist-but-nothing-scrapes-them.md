---
name: wms2-metrics-exist-but-nothing-scrapes-them
description: wms2 publishes Micrometer/Prometheus metrics but NOTHING scrapes them yet (2026-09-02); Joe owns the infra side
metadata:
  type: project
---

**wms2-api exposes metrics, but as of 2026-09-02 nothing consumes them** (Nam). Monitoring is
planned; **Joe, the infrastructure lead, owns that work.**

The app side is real and wired: `micrometer-registry-prometheus` at runtime scope,
`management.endpoints.web.exposure.include=health,info,metrics,hikaricp,prometheus,tenantpool`, and
`/actuator/prometheus` on prd returns **401 (not 404)** — it exists, gated behind `wms_admin`. There
is no Prometheus/Grafana scrape config in any repo, which proves nothing either way since deployment
is Portainer webhooks with no manifests in git.

**Why this matters when proposing fixes:** do not treat "it emits a metric / increments a counter /
publishes a gauge" as a working control. Today that is write-only. Until Joe's work lands, a design
whose only failure signal is a metric has **no** failure signal. Prefer a check that fails a build, a
test, or a script's exit code — e.g. `apply-pending-tenant-flyway.sh --status` already exits
0/2/3/1 for up-to-date / pending / needs-baseline / errors.

Concrete instance: `FlywaySchemaMetrics` publishes `wms2.flyway.tenants.stale` and
`wms2.flyway.enumeration_failed` (registered EAGERLY, so the series exist from boot and absence is
itself alertable) plus per-tenant `stale`/`ownership_drift` (registered lazily). A tenant DB
provisioned without `flyway_schema_history` is skipped every boot forever, and today the only signals
are an ERROR log line and those unread gauges — which is how `wh01_hydra_v2` sat nine migrations
behind for twelve days. ⚠️ `StartupFlywayMigrationRunner` is
`@ConditionalOnProperty("app.flyway.migrate-on-startup", matchIfMissing=true)`, so with migration
disabled NO gauge is published at all — absence would then mean "disabled", not "healthy".

Related: [[flyway-runbook-covers-dev-and-uat-via-env-flag]],
[[wms2-deployed-image-differs-from-branch-head]], [[verify-script-traps]].
