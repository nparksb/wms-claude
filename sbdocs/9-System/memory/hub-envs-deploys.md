---
name: hub-envs-deploys
description: Which DB/host/build is which per env, deploy mechanics, migrations status, DB MCP access. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Environments, DBs, deploys, MCP access**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [WineCo wsl v1→v2 migration status](wineco-wsl-v1-v2-migration-status.md) — dev+uat Phase C+F DONE, G–K left; 3
- [ShipItEZ two-warehouse v2 migration](shipitez-two-warehouse-v2-migration.md) — NY=wh02, LA=wh01 (inverted!); both
- [wms DB MCP first query after idle drops](wms-mcp-first-query-after-idle-drops.md) — "server closed the connection
- [wms2-wineco-dev = the DB `dev_wh01_om1`](wineco-dev-db-is-dev-wh01-om1-not-the-migration-env-target.md) — migration.env.wineco is a STALE copy
- [v2 dev has TWO landlord DBs](wms2-dev-landlord-is-dev-landlord-not-landlord.md) — `dev_landlord` = deployed dev
- [HMG = former name of Hydra's nywh warehouse](hmg-is-hydra-nywh-warehouse.md) — resolve to tenant hydra/facility
- [Merging to wms2 develop = a dev deploy + a Flyway run](wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway.md) — branch-push-driven; no CI on PRs
- [v1 vs v2 dev API hostnames](wms-v1-vs-v2-dev-api-hostnames.md) — the tenant-subdomain host
- [DB MCP tools absent ≠ DB unreachable](wms-mcp-tools-not-surfaced-use-psql-direct.md) — `claude mcp list` disagrees with the session registry both
- [WineCo env map — v2 PRD = Hydra + ShipItEZ + WineCo](wineco-is-a-v2-client-prd-mcp-is-wms1-wineco.md) — WineCo live on v2 PRD 2026-09-26 via `wsl-wineco-prd`; `wms1-wineco` is v1
- [:develop tag race — BOTH v2 repos](wms2-ui-develop-tag-race-deploys-older-code.md) — back-to-back merges race; wms2-api HAS concurrency: and it does NOT help (SHA-keyed)
- [Which wms2 build is deployed](wms2-actuator-info-build-time-identifies-the-deploy.md) — check `/api/public/version` FIRST (full SHA on dev, public since July); `build.version` is 0.1.0 forever
- [Deployed wms2 image != branch HEAD](wms2-deployed-image-differs-from-branch-head.md) — prd tracks `main`, but main drifts BOTH ways vs the running image within a day; read /api/public/version
- [wms2-api DOES gate its deploy on tests](wms2-no-pipeline-runs-tests.md) — since 2026-09-08; PR check is ADVISORY (no branch protection on this plan); other 3 repos still ungated
- [version endpoint's environment field lies](wms2-version-endpoint-environment-field-lies.md) — said "dev" on prd
- [wms2 metrics are published but unwatched](wms2-metrics-exist-but-nothing-scrapes-them.md) — nothing scrapes Prometheus yet (2026-09-02); Joe owns infra; a metric is NOT a working control
- [Hydra prd replenishorder zero is SUPERSEDED](hydra-prd-has-never-had-a-replenishorder-row.md) — 2026-09-29: v2 prd has thousands (WineCo/ShipItEZ); re-query, never assume zero exposure
- [Tenant schema fingerprint vs db/migration](wms2-tenant-schema-fingerprint-vs-db-migration.md) — "66 tables" is 54 + 12 VIEWS; only WineCo differs; script exists
- [v2 cutover can leave NEW_CRON_JOB_ACTIVATED=false](wms2-cutover-leaves-new-cron-job-activated-false.md) — searchable-but-not-pickable at state 0; master gate for all 6 cron jobs
- [A v2 estate census is SIX tenant DBs](wms2-estate-census-is-six-tenant-dbs.md) — missing the two WineCo ones under-counted 8.5x
- [DB MCP for data validation](db-mcp-for-data-validation.md) — use `wms2-wineco-dev` (not wms1) for live v2 data checks
- [develop push can create NO CI run](wms2-develop-push-can-create-no-ci-run.md) — no dispatch; next push carries it
- [wms2 dev actuator: 404 = never incremented; resets per deploy](wms2-dev-actuator-metrics-readable-counters-lazy-and-reset.md) — capture before deploys
- [DB MCPs dead: pglast 7.2.0 deleted from PyPI](postgres-mcp-pglast-720-deleted-needs-override.md) — all 15 CONNECTION_CLOSED; fixed via uvx --overrides pglast==7.21
- [Dev-probe control: read the guard BODY](dev-probe-control-must-read-guard-body.md) — setLockDamaged clamps amount>stock and damaged 2 SUs on dev (SBDEV-3984, reversed)
- [wms2 ingress = Traefik; 60 s readTimeout is NOT a response bound](wms2-ingress-traefik-readtimeout-60s-not-a-response-bound.md) — dev/UAT/prd; long GETs bounded only by serversTransport (default none); dev ≥57.8 s observed
