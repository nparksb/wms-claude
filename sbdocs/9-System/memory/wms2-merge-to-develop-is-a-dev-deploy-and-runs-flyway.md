---
name: wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway
description: Merging to wms2-api/wms2-web-ui develop auto-deploys WineCo dev AND applies pending Flyway to every active tenant DB — deploys are branch-push-driven, not tag-driven as CLAUDE.md claims
metadata:
  type: project
---

Measured 2026-08-22 while landing SBDEV-2967-B.

The monorepo `CLAUDE.md` says "CI/CD: GitLab CI with tag-driven deployments (dev-*, qa-*, ua-*, v*)".
**For `v2/wms2-api` and `v2/wms2-web-ui` that is wrong** — both carry GitHub Actions keyed on a
**branch push**, and both end by firing Portainer redeploy webhooks:

- `wms2-api/.github/workflows/docker-image-develop.yml` — `on: push: branches: ["develop"]` → builds
  and pushes `wms2-api:develop`, then POSTs two `portainer.dev.sbo.li` webhooks (api + cron service).
- `wms2-web-ui/.github/workflows/docker-develop-image.yml` — same shape, one webhook.
- `docker-image.yml` on both is keyed on `main` → **production**.

So **merging a PR into `develop` IS a dev deployment**, ~3 min later, with no separate approval step.
There is also **no CI on PRs at all** (`gh pr checks` reports "no checks reported"), so nothing gates
the merge but you.

**Sharper, measured 2026-08-25: `wms2-api` runs ZERO tests in ANY CI lane.** Not merely "no CI on
PRs" — no pipeline anywhere executes the suite. The three GitHub workflows above are docker image
builds with no test step. `.gitlab-ci.yml` is tag-only (`workflow.rules`: `merge_request_event →
never`, plus `if: $CI_COMMIT_TAG`) and its `build_jar` job runs
`mvn package -s ci_settings.xml -DskipTests=true`. So the full suite runs **only where a human runs
it**, and any proposal phrased as "gate this in CI" (a coverage floor, a mutation threshold, a lint
gate) has nothing to attach to — the test lane itself would have to be built first. Established while
scoping [[sbdev-3007-pit-scoped-only-verdict]].

**Compounding: the same merge runs database migrations.** `application.properties` sets
`app.flyway.migrate-on-startup=true` and `app.flyway.out-of-order=true` (`spring.flyway.enabled=false`
— Boot's autoconfig is excluded, so the `spring.*` keys are inert). The redeployed container applies
every pending `V2.2.*` on boot to landlord + all **active** tenant DBs. That is how V2.2.19 got applied
on SBDEV-2967-B — nobody ran it by hand. See [[sbdev-2801-runtime-flyway-default-on]].

**Blast radius is narrower than the tenant list suggests.** `dev_landlord.tenant` lists wineco, hydra
and shipitez, but `tenant_db_configuration` shows only **one** `active=true` row on dev:
wineco/wsl → `dev_wh01_om1`. Hydra and shipitez rows are all `active=false`. Query
`tenant_db_configuration.active` — never the `tenant` table — to scope what a dev boot will touch.
See [[wms2-dev-landlord-is-dev-landlord-not-landlord]].

**Release topology is develop → release → main, and `main` lags badly.** On 2026-08-22:
`origin/main` = `cf430ff` v2.0.128, `origin/release` = `41cbe77` v2.0.130 (43 commits ahead of main),
`develop` 62 ahead of main and **39 behind** it (main carries release/version commits develop never
gets — so a plain `main..develop` count misreads as one-way drift). Getting any one fix to production
means promoting the whole release train, not cherry-picking. See [[sbdev-3005-role-function-composite-key-swap]].

**Why this matters:** a plan whose prerequisite reads "not deployable until X is on `origin/main`" is
gating UAT/PRD only. The dev environment runs `develop`, so if X is on `develop` the gate is already
satisfied for dev, and treating it as a blocker for the dev merge stalls the work for a production
release nobody asked for.
