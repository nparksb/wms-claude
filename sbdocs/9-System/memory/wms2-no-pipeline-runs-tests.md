---
name: wms2-no-pipeline-runs-tests
description: wms2-api DOES gate its develop deploy on tests since 2026-09-08; the other three repos still do not
metadata:
  type: project
---

**`wms2-api` gates its dev deploy on the test suite as of 2026-09-08** (SBDEV-3195, PR #322, merged
`0dfcefc6`). This entry previously said no pipeline ran tests and that *"the build will catch it"* was
false here. That is now **wrong for `wms2-api`** and still **right for the other three repos**.

`.github/workflows/docker-image-develop.yml` runs `mvn -B -ntp clean verify` in a `test` job; the
image `build` job declares `needs: test`. Proven in both directions on real runs:
- red suite → `build` **skipped**, no image, no registry push, neither Portainer webhook;
- green suite → `build` runs and deploys.

It also runs on **pull requests into `develop`** — and a `pull_request` trigger added *in* a PR does
fire for that PR (evaluated from `refs/pull/N/merge`; two web summaries claim otherwise and are wrong).

**Cost:** a develop deploy went from ~150s to **~966s (16 min)** — 13m31s tests + 2m26s image. Full
`verify` on every push and PR was chosen over unit-on-push/integration-nightly, because the authz
structural pins live in both lanes and a nightly red is attributed to nobody.

⚠️ **The PR check is ADVISORY and cannot be made required.** `wms2-api` is a private org repo on a
plan with neither branch protection nor rulesets — both APIs return
`403 "Upgrade to GitHub Pro or make this repository public"`. GitHub will let anyone merge a red PR,
and a **conflicted** PR produces no run at all, so the check is *absent* rather than red. The branch
is not gated; the **deploy** is. Do not tell anyone "CI will block it" — it will not.

⚠️ **CI pins `LANG`/`LC_ALL=en_US.UTF-8`**, because the runner's JVM is the only environment in the
chain that is not `en_US` and 320 of 347 message keys live only in `messages_en_US.properties`. That
pin makes CI represent production; it is not a fix. See
[[surefire-does-not-propagate-user-locale-props]] and SBDEV-3256.

**Still true elsewhere — AC-6 was deliberately not done:** 16 workflow files across the four repos,
**15 run no tests**. `wms2-web-ui`, `wms2-mobile-ui` and `v1/wms-api` remain ungated. The single
exception, `wms2-mobile-ui/.github/workflows/playwright.yml`, runs `npx playwright test` but triggers
on `[main, master]` — production only, and `master` does not exist. Survey:
`sbdocs/1-Projects/wms2/plan/SBDEV-3195-evidence/ac6-cross-repo-ci-survey.md`.


---

## ⚠ FIXED 2026-09-08 — SBDEV-3195 merged (PR #322)

`.github/workflows/docker-image-develop.yml` now runs the test suite **before** building the develop
image, and it fires on `pull_request` as well — PR #323 was the first PR ever gated by it, showing a
`test` check and `mergeStateStatus = UNSTABLE` while in flight.

**What this invalidates.** "No pipeline runs tests, so a bad merge reaches dev unchallenged" was a
load-bearing premise in a lot of risk reasoning — I used it the same day to argue that an untested
`statement_timeout` value would be especially dangerous (SBDEV-3253) and that an ArchUnit rail's cost
was worth it because nothing else would catch a regression. **Re-derive those arguments; do not reuse
the premise.**

**What it does NOT change:**
- A PR check is not a substitute for the local full-suite comparison. The lane totals still need
  comparing against a known baseline, because a green check says "the build passed", not "the same
  tests passed".
- `mergeStateStatus` can now be `UNSTABLE` legitimately while the check runs. `CLEAN` before a check
  exists and `CLEAN` after it passes are different facts; do not merge on a stale `CLEAN`.
- Merging to develop still triggers a dev deploy and a Flyway run.

Related: [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].
