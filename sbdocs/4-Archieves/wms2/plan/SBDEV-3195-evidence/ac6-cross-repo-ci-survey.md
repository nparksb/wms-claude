# SBDEV-3195 AC-6 — cross-repo CI survey

Measured 2026-09-07 against `origin/develop` in each repo (fetched immediately before).
Read-only; nothing changed outside `v2/wms2-api`.

## The finding

AC-6 asks whether the same decision should apply to `wms2-web-ui`, `wms2-mobile-ui` and
`v1/wms-api`. It should — and the surface is larger than AC-6 assumed.

**16 GitHub workflow files across the four repos; 15 of them run no test.** (⚠ an earlier
revision of this file said "13 … not one runs a test". Both halves were wrong: 13 is the count for
the *other three* repos — 3+4+5+4 = 16 — and one file, `playwright.yml`, does run tests. The
document's own table said so two paragraphs below the sentence that denied it.) The 15 are all one
shape: checkout → registry login → `docker/build-push-action` → (sometimes) a Portainer webhook.
The four `.gitlab-ci.yml` files add nothing: each passes `-DskipTests` or has no test stage.

| Repo | Workflow files | Any run tests? | Test command that exists but is never invoked |
|---|---|---|---|
| `v2/wms2-api` | 3 | none | `mvn verify` — 445 test classes |
| `v2/wms2-web-ui` | 4 | none | `yarn test` → `jest` |
| `v2/wms2-mobile-ui` | 5 | **1, but see below** | `yarn test` → `jest` |
| `v1/wms-api` | 4 | none | `mvn verify` |

## The one exception is aimed at the wrong branch

`wms2-mobile-ui/.github/workflows/playwright.yml` does run tests — `npx playwright test`,
with `push` **and** `pull_request` triggers, and **seven** real spec files behind it
(`tests/e2e/{home,lookup,m23-authz-denial,navigation,picking,putaway,replenish}.spec.ts`, plus
`auth.setup.ts` and `fixtures.ts` — nine files in `tests/e2e`, all in scope via
`playwright.config.ts:4` `testDir: './tests/e2e'`). ⚠ An earlier revision said five/six; it missed
`putaway.spec.ts` (added 2026-05-28) and `replenish.spec.ts` (added 2026-07-12). The undercount
understated the value of re-pointing this workflow.

It does not close the gap, for one reason — and one I got wrong first time, recorded here
because the correction is the useful part:

1. **It triggers on `branches: [ main, master ]`.** This repo's branches are
   `develop` / `release` / `main` (`master` is absent — verified against `git ls-remote
   --heads origin`, 31 branches, no `master`). So it fires only on a push to `main`, i.e. a
   *production* deploy, and never on `develop` or on the PRs where a defect is still cheap
   to fix. This is the whole of the problem with it.

2. ⚠ **Not a reason: "it has no server to test against."** I asserted that first, from
   reading only the workflow. It is false. `playwright.config.ts:29-34` carries a
   `webServer` block (`command: 'npm run dev'`, `url: http://localhost:3001/mobile/`,
   `reuseExistingServer: true`, 60s timeout), so Playwright starts the app itself and the
   workflow does not need a provisioning step. Reading the workflow without reading the
   config produced a confident, wrong verdict about the one file in four repos that
   actually runs tests.

Separately, it does **not** run the Jest unit suite, which is what `"test": "jest"` in
`package.json` points at. Re-pointing the trigger at `develop` would still leave Jest
unrun.

## Recommendation — do not fold this into SBDEV-3195's PR

Scoping AC-6 into the same change would make this multi-repo, which is a T3 trigger, and
would mix a Java/Maven pipeline with two Node/Jest pipelines and a legacy Java 8 build that
has its own toolchain problem (v1 needs a Java 8 `JAVA_HOME` and `-Dapi.version=1.41` in
`argLine` to run its Testcontainers ITs at all).

Proposed split, in the order the value lands:

| Follow-up | Why this order |
|---|---|
| `wms2-web-ui` + `wms2-mobile-ui` Jest on push+PR | Same shape as this ticket, 84 spec files in web-ui (file count, measured; the ticket's ~1117 is a *test* count and was not re-derived here), no Docker/toolchain complications. Cheapest real coverage available. |
| Re-point `playwright.yml` at `develop`, or delete it | Right now it is a workflow that *looks* like a test gate and is aimed at a branch where finding a defect is most expensive. Decide which; either is better than today. |
| `v1/wms-api` | Java 8 toolchain + the `withReuse(true)` container leak (43 containers/run measured) need handling first. |

⚠ `v1` is reference-only — no self-initiated v1 work. That row is listed for completeness,
not as a proposal to start.
