---
title: "wms2-web-ui — dead NuxtLogo spec makes every unfiltered `yarn test` exit non-zero"
ticket: "SBDEV-2931"
ticket_url: "https://app.clickup.com/t/868kqb03k"
type: "bugfix"
priority: "low"
status: "MERGED 2026-08-12 — wms2-web-ui PR #53 into develop, merge 1f2605b, ClickUp `on dev`. Merged develop re-verified: verify 8 pass / 0 fail, Jest 27/27 suites, 251 passed, exit 0. DO NOT ARCHIVE until manual rows M3/M4/M6 are run; v1 twin SBDEV-2937 still open."
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-08-12"
updated: "2026-08-12"
db_verified: false
related:
  - "SBDEV-2732-configurable-default-putaway-location-hierarchy"
  - "SBDEV-2643-sku-default-putaway-location-ui"
  - "SBDEV-2930-mobile-workflow-pages-resume-stale-operator-state"
tags:
  - plan
  - wms2-web-ui
  - jest
  - test-tooling
  - ci-hygiene
---

# wms2-web-ui — dead NuxtLogo spec makes every unfiltered `yarn test` exit non-zero

**Ticket:** [SBDEV-2931](https://app.clickup.com/t/868kqb03k)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Repo:** `v2/wms2-web-ui` (Nuxt 2.15 / Vue 2 / Vuetify 2) — **not `wms2-api`**
**Priority:** low
**Status:** **MERGED 2026-08-12** — PR [#53](https://github.com/SiteBossInc/wms2-web-ui/pull/53) into `develop`, merge `1f2605b`, ClickUp `on dev`. ⚠ do not archive until M3/M4/M6 run
**Date:** 2026-08-12

> **ralplan consensus loop deliberately skipped.** The `wms-bugfix-plan` skill permits this for
> mechanical fixes, and this one is a single-file deletion of dead scaffold with no contract,
> schema, or behaviour surface. Sending a `git rm` through Planner → Architect → Critic would
> add latency without adding a decision. **The two judgement calls this plan does contain were
> put to the user instead** and are recorded in §10: v1 scope, and whether to add a CI gate.

> **This is a front-end test-tooling plan.** The Java-oriented gates in the plan template
> (§7 horizontal scalability, the v2-only constraint checklist, Testcontainers, `BaseControllerUnitTest`)
> have **no surface here** — this plan changes no runtime code in any language. They are answered
> explicitly rather than left blank in §7 and §7a; do not read those N/A rows as skipped work.

---

## 0. Affected sites (enumeration before drafting)

Enumerated, not recalled. Method: `grep -rn "NuxtLogo"` across all four UI repos excluding
`node_modules`/`.git`/`.nuxt`, plus `git log --all` per candidate component path, plus a
`ls test/` inventory per repo.

| # | File | Construct | Same root-cause? | In-scope this plan? |
|---|------|-----------|------------------|----------------------|
| 1 | `v2/wms2-web-ui/test/NuxtLogo.spec.js:2` | `import NuxtLogo from '@/components/NuxtLogo.vue'` → module not resolvable → suite dies at load | **yes** | **yes** — the whole plan |
| 2 | `v1/wms-web-ui/test/NuxtLogo.spec.js:2` | byte-identical dead import; same originating commit `3462148` | **yes** | **no** — split to **SBDEV-2937** by explicit user decision (§10 D1) |
| 3 | `v1/wms-mobile-ui` | no `NuxtLogo.spec.js`, no `jest.config.js` at all — repo has no Jest surface | n/a | no — nothing to fix |
| 4 | `v2/wms2-mobile-ui` | has `jest.config.js`, **no** `NuxtLogo` spec and no dead specs | n/a | no — already clean |
| 5 | `v2/wms2-web-ui/jest.config.js` | no `testMatch` / `testPathIgnorePatterns` keys, so Jest defaults pick up every `test/**/*.spec.js` | contributing | no — **must stay unchanged**; guarded by a negative check (§9 `N2`) |
| 6 | `v2/wms2-web-ui/.gitlab-ci.yml` + `.github/workflows/*.yml` (4 files) | **no job runs `yarn test`** anywhere; GitLab is build-only/tag-gated, GitHub workflows are docker image builds | adjacent, not causal | no — deferred by explicit user decision (§10 D2) |

**Rows 1 and 5 are the only two files this plan touches or asserts on**, and row 5 is asserted
*unchanged*. Row 1 is the sole deletion. Every in-scope row maps to a check in §9.

There is **no `components/NuxtLogo.vue` to enumerate** — in either web repo, ever (`git log --all`
returns 0 commits for that path). Rows 1 and 2 are specs for a component that was never imported
from the Nuxt scaffold.

### Cross-reference: prior plans that worked around this

The habit the ticket describes is documented, not hypothetical. Nine lines across seven vault
documents record the workaround rather than the fix:

| Document | What it recorded |
|---|---|
| `SBDEV-2732-…-hierarchy.md:4011-4013` | *"`test/NuxtLogo.spec.js` is red and always has been… Every '26 suites' figure in this plan was taken with `--testPathIgnorePatterns=NuxtLogo`"* |
| `SBDEV-2643-sku-default-putaway-location-ui.md:2295` | *"251 pass, 27/28 suites. ⚠ fails to run — pre-existing, reproduced on clean develop"* |
| `SBDEV-2781-…-tz-shift.md:877` | *"suite-load failure is pre-existing on `origin/develop`"* |
| `4-Archieves/…/SBDEV-2554-…md:456` | *"The one failing suite is the pre-existing broken `test/NuxtLogo.spec.js`… unrelated"* |
| `4-Archieves/…/SBDEV-2391-…md:468` | *"pre-existing unrelated `NuxtLogo.spec.js` module-resolution failure left as-is"* |

Each author independently re-derived the same diagnosis and moved on. That repeated cost — not the
red suite itself — is the actual justification for this ticket.

---

## 1. Problem Statement

### Symptom

Running the repo's own documented test command in `v2/wms2-web-ui` fails:

```
$ yarn test          # → package.json: "test": "jest"

FAIL test/NuxtLogo.spec.js
  ● Test suite failed to run

    Configuration error:
      Could not locate module @/components/NuxtLogo.vue mapped as:
      /home/nampark/dev/wms-claude/v2/wms2-web-ui/$1.

      1 | import { mount } from '@vue/test-utils'
    > 2 | import NuxtLogo from '@/components/NuxtLogo.vue'
        | ^

Test Suites: 1 failed, 27 passed, 28 total
Tests:       251 passed, 251 total
```

**Exit code 1.** Measured 2026-08-12 on `develop` at parity with `origin/develop`
(`git rev-list --left-right --count develop...origin/develop` → `0  0`), clean working tree,
via `node_modules/.bin/jest` (no `yarn` on PATH in this environment — see
[[run-wms2-mobile-ui-jest-tests]] for the same constraint on the sibling repo).

### Impact — deliberately stated narrowly

- **No test coverage is lost today.** The suite dies during module resolution, before any
  `test()` callback registers, so it contributes **zero** tests. Only the *suite* tally and the
  process exit code are affected.
- **No CI pipeline is red.** §0 row 6: nothing runs `yarn test`. This is worth stating plainly
  because the ticket's phrase *"`yarn test` cannot be used as a CI gate as-is"* is
  **forward-looking**, not a report of a currently-failing build. The defect blocks a gate from
  being *added*; it is not breaking one.
- **The real cost is habituation.** A permanently non-zero exit code trains every contributor to
  pass a filter and to read `exit 1` as normal. The five documents in §0 are that habit already
  paid for five times. This repo has a hard-won green Jest lane (251 tests); an exit code nobody
  trusts is the mechanism by which a *real* failure gets waved through as "the usual one".

### Reproduction

1. `cd v2/wms2-web-ui` on a clean `develop`.
2. `node_modules/.bin/jest` (or `yarn test`) with **no** `--testPathPattern` /
   `--testPathIgnorePatterns`.
3. Observe `Test Suites: 1 failed, 27 passed, 28 total` and `echo $?` → `1`.

### Correction to the ticket's stated numbers

The ticket's evidence table is **stale by two suites and one test** — it was written against an
earlier `develop`. Both figures were re-measured for this plan:

| Figure | Ticket (SBDEV-2931) | Measured 2026-08-12 on `develop` |
|---|---|---|
| Suites | `1 failed, 26 passed, 27 total` | **`1 failed, 27 passed, 28 total`** |
| Tests | `250 passed, 250 total` | **`251 passed, 251 total`** |

The drift is benign — SBDEV-2643 / SBDEV-2732 landed a suite between the ticket being filed and
this plan. It matters only because the ticket's **acceptance criterion #2 hard-codes 250**. A
literal reading of it would fail a correct fix. §8 restates it as *"unchanged from the pre-fix
baseline"* with the baseline captured at implementation time, which is the property actually
worth asserting and does not rot. See §10 D3.

### DB verification gate — `db_verified: false`, and that is correct

The analysis protocol's mandatory DB gate has **no applicable surface**: this plan changes one
test file in a Nuxt front-end. There is no query, no entity, no migration, no tenant data, and no
server round-trip anywhere in the change or its acceptance. Recording `db_verified: true` would be
false precision.

The gate's *purpose* — do not write a root-cause narrative that rests on an unverified assumption —
is discharged by **executed** probes instead of prose, all four run before this plan was drafted:

| Probe | Command | Result |
|---|---|---|
| P1 | `node_modules/.bin/jest` (unfiltered, v2) | `1 failed, 27 passed, 28 total` / `251 passed`, **exit 1** — the defect, reproduced |
| P2 | `node_modules/.bin/jest --testPathIgnorePatterns=NuxtLogo` | `27 passed, 27 total` / **`251 passed`**, **exit 0** — the fix's outcome, simulated |
| P3 | `git log --all -- components/NuxtLogo.vue` | `0` commits — the component never existed |
| P4 | `grep -rn NuxtLogo` (excl. `node_modules`, `.git`, `.nuxt`, `dist`) | exactly 3 lines, all inside `test/NuxtLogo.spec.js` |

**P2 is the load-bearing one.** It proves the two claims the fix depends on simultaneously:
removing this suite yields a green, `exit 0` run, **and** the test count is *unchanged* at 251 —
so "no coverage is lost" is a measurement here, not an assertion. It also pre-empts the
[[negative-test-verify-scripts-before-trusting-them]] failure mode by establishing what the
post-fix numbers must be *before* any code changes.

**No manual DB check is owed to the implementer.**

---

## 2. Root Cause Analysis

### Bug 1 (only bug): a scaffold spec survived an import that its component did not

`v2/wms2-web-ui/test/NuxtLogo.spec.js` — the file in full, all 9 lines:

```js
import { mount } from '@vue/test-utils'
import NuxtLogo from '@/components/NuxtLogo.vue'   // ← line 2: unresolvable

describe('NuxtLogo', () => {
  test('is a Vue instance', () => {
    const wrapper = mount(NuxtLogo)
    expect(wrapper.vm).toBeTruthy()
  })
})
```

This is the **stock `create-nuxt-app` example spec**, verbatim. `NuxtLogo` is a component of the
Nuxt 2 default scaffold — the purple hexagon on the starter landing page.

**Why it fails.** `jest.config.js` maps `^@/(.*)$` → `<rootDir>/$1`, so line 2 resolves to
`<rootDir>/components/NuxtLogo.vue`. That path does not exist:

```
$ ls components/
admin  common  handlingUnits  homepage  internalOps  layout_components
masterData  outbound  processes  receiving  reports          # ← no NuxtLogo.vue

$ git log --all --oneline -- components/NuxtLogo.vue
                                                            # ← 0 commits, on every ref
```

Jest's resolver raises `createNoMappedModuleFoundError` **at module-load time**, before the
`describe` block executes. Consequences, in order — this ordering is the whole explanation of the
odd symptom:

1. No `test()` ever registers → the suite contributes **0 tests** → `Tests: 251 passed, 251 total`
   is *unaffected*, which is why nobody noticed for two years.
2. The **suite** is nonetheless counted and marked failed → `Test Suites: 1 failed`.
3. Jest exits **non-zero** because a suite failed.

So the defect is invisible in the headline number everyone reads (tests) and visible only in the
two nobody reads (suite tally, exit code). That is precisely why it rotted for two years while
being noted five separate times.

**Why the app never noticed.** The scaffold's landing page was replaced by this application's own
`pages/index.vue` and `layouts/default.vue` during the initial build-out. Nuxt auto-imports
components (per `CLAUDE.md` → "Component Auto-Import"), so a *component* nobody references is
simply never bundled and costs nothing at runtime. A *spec*, by contrast, is discovered by
filename — `jest.config.js` sets no `testMatch`, so Jest's default `**/?(*.)+(spec|test).[jt]s?(x)`
picks up anything under `test/`. Deleting the component was therefore free and silent; the spec
that imported it was not, and stayed behind.

**Not a regression.** The spec has exactly one commit in its entire history — the repo's initial
import:

```
$ git log --oneline -- test/NuxtLogo.spec.js
3462148 initial check in the code
```

No branch has ever removed it (checked across all remote refs). This is **scaffold rot from day
one**, not fallout from recent work — which also means no in-flight branch conflicts with the
deletion.

### What this is *not*

Ruled out explicitly, so review does not have to re-derive them:

| Hypothesis | Ruled out by |
|---|---|
| A recent refactor moved/renamed `NuxtLogo.vue` | `git log --all` → **0** commits for that path, ever. Nothing to restore. |
| A build step generates the component, so it exists at test time | The failure *is* the test-time run; `moduleNameMapper` targets `<rootDir>`, not `.nuxt/`. No generated-component path is configured. |
| `moduleNameMapper` is misconfigured (real bug, wrong file blamed) | The same `^@/` mapping resolves correctly in all 27 green suites. The map is fine; the target is missing. |
| The suite hides real coverage that deletion would lose | P2: 251 tests with the suite present, **251** with it excluded. Delta **0**. |
| A `jest.config.js` ignore-entry already suppresses it | §0 row 5: no `testPathIgnorePatterns` key exists. Prior plans passed the flag on the **command line**, per-run. |

---

## 3. Fix Design

### Fix A — delete `v2/wms2-web-ui/test/NuxtLogo.spec.js`

```bash
git rm v2/wms2-web-ui/test/NuxtLogo.spec.js
```

One file, 9 lines, deleted. No other file changes — **including `jest.config.js`, which must stay
byte-identical** (§9 `N2`).

**Why deletion and not the alternatives.** Four options exist; three are worse:

| Option | Verdict |
|---|---|
| **A. Delete the spec** ✅ | Removes the dead artifact. Zero coverage delta (P2). No config debt. Restores a truthful exit code. **Chosen.** |
| B. Add `components/NuxtLogo.vue` to satisfy the import | Adds a **dead component** to a mature app purely to keep a test that asserts `mount()` returns truthy — a test of Vue itself, with zero value here. Trades dead test code for dead *production* code, which also enters the coverage denominator (`collectCoverageFrom: components/**/*.vue`) and *lowers* reported coverage. The ticket floats this and self-rejects it; agreed. |
| C. Add `testPathIgnorePatterns: ['NuxtLogo']` to `jest.config.js` | Makes the exit code green while **keeping the dead file**, and converts a per-run CLI workaround into permanent committed config. Anyone later runs `--testPathIgnorePatterns` for a real reason and silently un-ignores it. Institutionalises the habit the ticket exists to break. |
| D. Leave it; document it harder | The 5-document trail in §0 *is* six attempts at this. It does not work. |

**Blast radius: nil.** The file is imported by nothing (P4: the only three `NuxtLogo` mentions in
the repo are inside the file itself), referenced by no config (§0 row 5), and named in no CI job
(§0 row 6). Deleting it cannot affect the 27 remaining suites, the dev server, or the build.

---

## 4. V1/V2 Applicability

| Aspect | v1 (`v1/wms-web-ui`) | v2 (`v2/wms2-web-ui`) | Impact |
|---|---|---|---|
| Dead `test/NuxtLogo.spec.js` present | **yes** — byte-identical | yes | same root cause |
| `components/NuxtLogo.vue` exists | no (0 commits ever) | no (0 commits ever) | same |
| Originating commit | `3462148 initial check in the code` | `3462148 initial check in the code` | shared scaffold ancestry |
| Unfiltered Jest, measured 2026-08-12 | `1 failed, 2 passed, 3 total` / `4 passed`, **exit 1** | `1 failed, 27 passed, 28 total` / `251 passed`, **exit 1** | v1 is **proportionally worse**: 1 of only **3** suites is red |
| Mobile sibling | `v1/wms-mobile-ui` — no Jest surface at all | `v2/wms2-mobile-ui` — Jest present, **no** dead spec | neither needs work |

### What needs porting

Nothing, in this plan. **v1 is deferred to [SBDEV-2937](https://app.clickup.com/t/868kqgtvz)**, filed
2026-08-12 with the measured v1 evidence — by explicit user decision (§10 D1), to keep this PR
matching its ticket exactly. The fix there is the identical one-line `git rm`.

> Deliberate asymmetry worth flagging at review: **v1 stays red when this ships.** That is the
> accepted cost of the v2-only scope, not an oversight. SBDEV-2937 exists so it is tracked rather
> than rediscovered a sixth time.

### What does NOT need porting

- `v1/wms-mobile-ui` — no `jest.config.js` and no spec. Nothing to delete.
- `v2/wms2-mobile-ui` — has Jest, already clean. Verified, not assumed (§0 row 4).

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **N/A** — the change is one front-end test file; no schema, no rows, no Flyway version. | — | See §1 `db_verified` rationale |
| 2 | **Feature flags / sysprops** | **N/A** — no runtime behaviour changes, so nothing to gate. | — | |
| 3 | **Config / env changes** | **N/A** — `jest.config.js` and `package.json` are unchanged *by design* (§9 `N2`, `N3`). | — | |
| 4 | **Deploy-order dependencies** | **N/A** — test-only file; not in the bundle, so no deploy coupling. | — | Nuxt never bundles `test/` |
| 5 | **Data migration** | **N/A** — no data. | — | |
| 6 | **External systems** | **N/A** — no OMS / printer / Keycloak surface. | — | |
| 7 | **Access / permissions** | Push access to `v2/wms2-web-ui` + PR into `develop`. | implementer | Normal repo access; no new role |
| 8 | **Monitoring / alerts** | **N/A** — no runtime failure mode to observe. The acceptance signal is Jest's exit code, asserted in §9. | — | |
| 9 | **Working tree / node** | Clean tree on `develop` at parity with `origin/develop`; node via `nvm` (**no `yarn` on PATH** here — use `node_modules/.bin/jest`). | implementer | Verified 2026-08-12: `0  0` divergence |
| 10 | **Pre-fix baseline captured** | Run unfiltered Jest **before** deleting; record suite/test counts + exit code. | implementer | Feeds §9 `B4`'s no-coverage-loss floor. **Do not skip** — this is the only defence against grading against a number that has drifted again (§1). |

### 5.2 Implementation Checklist

Single atomic commit; the ordering exists only so the baseline is captured before it is destroyed.

- [ ] **Step 1 — branch.** From clean `develop` (fetched, at parity):
      `git checkout -b feature/SBDEV-2931-remove-dead-nuxtlogo-spec`
- [ ] **Step 2 — capture the pre-fix baseline** (Prerequisite 10). Run unfiltered
      `node_modules/.bin/jest`; record suites / tests / exit code. Expect
      `1 failed, 27 passed, 28 total` / `251 passed` / exit `1` — **if the counts differ, use the
      observed numbers as the floor** and note the drift in the PR.
- [ ] **Step 3 — capture the verify-script FAIL baseline.**
      `PROJECT_ROOT=$(pwd) bash sbdocs/9-System/scripts/verify-SBDEV-2931-dead-nuxtlogo-spec-fails-yarn-test.sh`
      Expect **`4 pass, 4 fail`** (§9) — this exact figure was measured on `develop` while authoring.
      A run that is already all-green means the script is not asserting anything — stop and fix the
      script, not the code. ⚠ **Grade in the real checkout or a real `git worktree`, never through a
      symlink shadow root** — Jest finds zero tests there and `B3`/`B4` fail closed on a *correct*
      fix (§9.1 harness finding).
- [ ] **Step 4 — delete.** `git rm test/NuxtLogo.spec.js`. **Touch nothing else** — in particular
      not `jest.config.js` or `package.json`.
- [ ] **Step 5 — re-run unfiltered Jest.** Expect `27 passed, 27 total` / `251 passed` / **exit 0**.
      Test count MUST be ≥ the Step 2 figure.
- [ ] **Step 6 — re-run the verify script.** Require **`8 pass, 0 fail`** and paste the
      `Result:` line verbatim into the PR body and the §6 execution table.
- [ ] **Step 7 — lint.** `node_modules/.bin/eslint --ext .js,.vue .` — confirm the deletion left no
      unused-import or config reference behind. (Expect no new findings; a deletion cannot add any.)
- [ ] **Step 8 — commit + PR** into `develop`, referencing SBDEV-2931 and linking SBDEV-2937 as the
      v1 counterpart. Single-file diff; the PR body carries both `Result:` lines from Steps 3 and 6.
- [ ] **Step 9 — update this document** (§6 execution table + §9 Implementation Status) with the
      real numbers, commit SHA, and PR number **before** declaring done
      ([[feedback_plan_status_after_implementation]]).

---

## 6. Test Plan

### The honest framing

**No new automated test is written, and that is the correct outcome — not a coverage gap.**

The deliverable here is the *deletion of a test*. The acceptance property is a fact about the test
runner's own aggregate result — "zero failed suites, exit 0" — which cannot be asserted from
*inside* a Jest suite, since a suite cannot observe its own runner's exit code. The assertion
therefore lives in the verify script (§9 `B3`/`B4`), which runs Jest as a subprocess and inspects
its output and status. That is the right altitude for this claim; a `.spec.js` asserting it would
be circular.

Writing a replacement spec to "preserve the suite count" would mean inventing a test for a
component that does not exist — the exact defect being removed.

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Unfiltered run is green | `node_modules/.bin/jest` (no filters) | `Test Suites: 27 passed, 27 total`; **exit 0** |
| No coverage lost | compare test count to the Step 2 baseline | `251 passed` — **equal**, not merely close (P2 proved this pre-emptively) |
| No dead references remain | `grep -rn NuxtLogo` excl. `node_modules`/`.git`/`.nuxt`/`dist` | zero matches repo-wide |
| Fix is a deletion, not a suppression | inspect `jest.config.js` diff | **empty** — no `testPathIgnorePatterns` / `testMatch` added |
| Fix is a deletion, not a component add | `ls components/NuxtLogo.vue` | still absent |
| Surviving suites unaffected | the 27 remaining suites | all pass; per-suite results identical to baseline |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| **none** | — | Deliberate — see "The honest framing" above. Coverage of the acceptance property lives in `verify-SBDEV-2931-…sh` rows `B3`, `B4`, `N1`–`N3`. |
| `test/NuxtLogo.spec.js` | *(deleted)* | Asserted `mount(NuxtLogo).vm` was truthy — i.e. tested Vue, not this app. Contributed **0** executing tests. |

### Manual test plan

Scoped to "did anything that used to work stop working" — the change has no user-visible path, but
it *is* a repo-hygiene change and the developer workflow is its user.

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| M1 — documented command works | local, post-fix branch | `yarn test` (as `CLAUDE.md` documents) | green, **exit 0**; `echo $?` → `0` | |
| M2 — filtered runs still work | local | `yarn test -- --testPathPattern="store"` | passes; the documented filter form is unbroken | |
| M3 — dev server unaffected | local | `yarn dev`, load `localhost:3000`, sign in, open any page | app loads normally; no missing-component warning in console | |
| M4 — production build unaffected | local | `yarn build` | build succeeds; no reference to `NuxtLogo` in output | |
| M5 — coverage report intact | local | inspect the `collectCoverage` table Jest prints | table renders; `components/`+`pages/` rows present as before | |
| M6 — clean-clone sanity | fresh clone of the merged branch | `yarn install && yarn test` | `27 passed, 27 total`, exit 0 — proves the fix is in the commit, not in local state | |

M3/M4 are cheap paranoia rows: they exist to confirm the deleted file really was inert in the app
build, rather than relying on the argument that `test/` is never bundled.

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `node_modules/.bin/jest` (pre-fix baseline, Step 2) | | expect `1 failed, 27 passed, 28 total` / `251 passed` / exit 1 |
| `bash verify-SBDEV-2931-…sh` (pre-fix, Step 3) | | expect **`4 pass, 4 fail`** |
| `node_modules/.bin/jest` (post-fix, Step 5) | | expect `27 passed, 27 total` / `251 passed` / exit 0 |
| `bash verify-SBDEV-2931-…sh` (post-fix, Step 6) | | expect **`8 pass, 0 fail`** |
| `eslint --ext .js,.vue .` (Step 7) | | expect no new findings |

`mvn` rows are **N/A** — no Java module is touched.

### Deliberately-skipped coverage

| What | Why |
|---|---|
| A replacement `.spec.js` | Would test a non-existent component. The suite contributed 0 executing tests; there is nothing to replace. |
| Unit test for "exit code is 0" | Not expressible from inside Jest — a suite cannot assert its own runner's exit status. Lives in verify `B3`. |
| Testcontainers / `BaseControllerUnitTest` | No Java, no API, no DB, no endpoint in this change. |
| A CI job asserting green | Out of scope by explicit decision (§10 D2); recorded as a follow-up in §8. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

**All ten rows are N/A for one shared reason, stated once and applied honestly:** this plan deletes
a Jest spec from a Nuxt front-end repo. It ships **no runtime code** — no JVM, no replica, no
request path, no DB connection, no cache, no scheduled job. `test/` is not bundled by Nuxt, so the
deleted file is absent from every deployed artifact both before and after the fix. There is no
mechanism by which it can influence `wms2-api` replica behaviour.

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **N/A** | No JVM. Test-file deletion in a Nuxt repo. |
| 2 | Connection pool math | **N/A** | No DB connection opened by this change or its tests. |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled`, no cron, no client-side timer. |
| 4 | Long transactions | **N/A** | No transaction. |
| 5 | Request affinity | **N/A** | No request; no session or in-memory state added. |
| 6 | Retry / idempotency | **N/A** | No write path. Deleting a file is idempotent by construction. |
| 7 | Tenant context | **N/A** | No `TenantContext`, no async boundary, no tenant-scoped code. |
| 8 | Distributed lock correctness | **N/A** | No locks. |
| 9 | Cache invalidation | **N/A** | No cached entity; no Caffeine/Redis surface. Jest's own cache is per-run and local. |
| 10 | External notifications | **N/A** | No HTTP send, no OMS/printer call. |

### Evidence (for any "Yes" row)

No "Yes" rows. Nothing to evidence.

---

## 7a. v2-only constraint checklist

The template's v2 checklist targets **`v2/wms2-api`** (Java 21 / Spring Boot 3.5.9). This plan
targets **`v2/wms2-web-ui`** (Nuxt 2 / Vue 2), so every row is N/A — recorded explicitly rather
than dropped, so review can see the checklist was read and not skipped.

| # | Constraint | Verdict | Rationale |
|---|---|---|---|
| 1 | OSIV disabled | **N/A** | No Hibernate session; no Java. |
| 2 | `@Transactional("tenantTransactionManager")` | **N/A** | No Spring transaction. |
| 3 | `readOnly=true` on reads | **N/A** | No service method. |
| 4 | Caffeine cache invalidation | **N/A** | No cached entity touched. |
| 5 | Jakarta namespace | **N/A** | No Java imports; nothing ported from v1 in *this* plan (the v1 twin is SBDEV-2937, itself a JS deletion). |
| 6 | H2-compatible test SQL | **N/A** | No SQL in any form. |
| 7 | `BaseControllerUnitTest` for controller changes | **N/A** | No controller, no endpoint. |
| 8 | Micrometer metrics | **N/A** | No server-side path; the change has no runtime frequency. |

---

## 8. Notes

### Follow-up recorded, not silently dropped

**No CI job runs `yarn test` in `v2/wms2-web-ui`** (§0 row 6): `.gitlab-ci.yml` has a single
`build` stage that runs only on `$CI_COMMIT_TAG` and just builds/pushes a Docker image; all four
`.github/workflows/*.yml` are docker-image builds. So this fix makes the exit code *truthful* but
**nothing yet enforces it** — the suite can rot red again with no signal.

Scoped out of this plan by explicit decision (§10 D2): adding a pipeline gate means a runner with
node, an `install` step, and a real risk of blocking merges on pre-existing flakiness — a
materially larger change than a low-priority deletion warrants. Recorded here so the observation
survives this plan. **This fix is a precondition for that gate, not a substitute for it.**

### Why the deletion is safe to merge without a soak

Nothing imports the file, no config names it, no CI job runs it, and it is absent from every built
artifact. Post-merge risk is bounded by whether the file was truly inert — which M3/M4 confirm
directly rather than by argument.

### Related

- **SBDEV-2937** — the v1 twin (`v1/wms-web-ui`), filed from this plan's §0 enumeration.
- **SBDEV-2732 / SBDEV-2643** — whose reported Jest figures were taken with
  `--testPathIgnorePatterns=NuxtLogo`. After this ships, their successors can report unfiltered
  numbers. Neither needs amending; their figures were correct, just filtered, and both said so.
- **SBDEV-2930** — the other front-end-only plan in this folder; same repo family, same
  "no DB surface, discharge the gate with executed probes" pattern.

### Document history

| Date | Change |
|---|---|
| 2026-08-12 | Created. Ticket claims re-measured (suites/tests drifted 26/27→27/28 and 250→251); v1 twin found and split to SBDEV-2937; absence of any CI test job established. |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-2931-dead-nuxtlogo-spec-fails-yarn-test.sh`

Run from the repo root of `v2/wms2-web-ui`:

```bash
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-web-ui \
  bash sbdocs/9-System/scripts/verify-SBDEV-2931-dead-nuxtlogo-spec-fails-yarn-test.sh
```

Eight checks. The columns matter as much as the rows: **`Baseline` is what the row reports on
unfixed `develop`**, and a row that reads PASS there proves nothing about the fix.

| id | Asserts | Kind | Baseline (pre-fix) | Post-fix |
|---|---|---|---|---|
| `A1` | `test/NuxtLogo.spec.js` no longer exists | positive | **FAIL** | PASS |
| `A2` | no `NuxtLogo` reference under `test/` or `components/` | positive | **FAIL** | PASS |
| `A3` | no `NuxtLogo` reference **anywhere** in the repo (excl. `node_modules`/`.git`/`.nuxt`/`dist`) | positive | **FAIL** | PASS |
| `B3` | unfiltered Jest exits **0** with `0 failed` suites | behaviour | **FAIL** | PASS |
| `B4` | unfiltered Jest test count **≥ 251** (no coverage loss) | behaviour | PASS¹ | PASS |
| `N1` | `components/NuxtLogo.vue` still absent — fix is a deletion, **not** option B | guard | PASS² | PASS |
| `N2` | `jest.config.js` has gained **no** `testPathIgnorePatterns` / `testMatch` — not option C | guard | PASS² | PASS |
| `N3` | `package.json` `"test"` script is still plain `jest` — no filter smuggled in | guard | PASS² | PASS |

¹ `B4` passes at baseline **by design**: 251 tests already run today (the dead suite contributes
none). Its job is to catch a *regression* — an implementer who "fixes" the count by deleting a live
suite. It is a ratchet, not a defect detector, and is documented as such so nobody later reads its
green baseline as the script being toothless.

² `N1`–`N3` are **guards against the wrong fix**, so they necessarily pass before *and* after a
correct implementation. They fail only if someone implements option B or C from §3. Per
[[verify-script-undefined-check-fn-reads-as-honest-fail]] they are labelled `guard` rather than
padding the pass count with rows that can never discriminate.

**Expected: `4 pass, 4 fail` pre-fix → `8 pass, 0 fail` post-fix.** Both `Result:` lines go in the
PR body. The 4-fail baseline is the script's own negative test — the discriminating rows are
`A1`, `A2`, `A3`, `B3`.

#### Script validated in BOTH directions during authoring — measured, not asserted

Per [[negative-test-verify-scripts-before-trusting-them]], the script was run against real builds
before this plan was called done. **Every number in the table above is an observation.**

| Run | Harness | Observed |
|---|---|---|
| **Pre-fix** | real `develop`, clean tree, parity with origin | **`4 pass, 4 fail, 0 skip`**, exit 1 — `A1`/`A2`/`A3`/`B3` red; `jest exit=1`, `1 failed, 27 passed, 28 total`, `251 passed` |
| **Post-fix** | real `git worktree` off `develop` with only `test/NuxtLogo.spec.js` removed | **`8 pass, 0 fail, 0 skip`**, exit 0 — `jest exit=0`, **`27 passed, 27 total`**, **`251 passed`** |

The post-fix run is the direct proof of both acceptance criteria: **exit 0 with zero failed suites,
and the test count unchanged at 251.**

#### Mutation testing — all four wrong-fix mutations caught, each by exactly one row

Guard rows that pass in both directions are worthless unless they can actually fail. Each was
forced to fail on a real build:

| Mutation applied to the worktree | Expected to trip | Observed |
|---|---|---|
| **§3 option B** — add `components/NuxtLogo.vue`, keep the spec | `N1` | **`N1` FAIL**, `N2`/`N3` still PASS ✓ |
| **§3 option C** — add `testPathIgnorePatterns: ['NuxtLogo']` to `jest.config.js`, keep the spec | `N2` | **`N2` FAIL**, `N1`/`N3` still PASS ✓ |
| Smuggle a filter into `package.json` → `"test": "jest --testPathIgnorePatterns=NuxtLogo"` | `N3` | **`N3` FAIL**, `N1`/`N2` still PASS ✓ |
| **Fail-open trap** — rename `jest.config.js` away entirely | `N2` (must FAIL, not vacuously pass) | **`N2` FAIL** ✓ — confirms the explicit `[ -f ]` precondition defeats the template-helper trap |

No mutation produced a false green, and none tripped a row other than its target — so the three
guards discriminate rather than decorate. Row `B4` was additionally confirmed to fail closed on an
unparseable summary (see the shadow-root note below).

#### One harness finding worth passing to the implementer

A first attempt at the post-fix run used a **symlink shadow root** (the `wms-plan-executor` recipe).
It produced a misleading `6 pass, 2 fail`: `A1`–`A3` flipped green but `B3`/`B4` failed with **empty
summary lines**, because Jest resolves symlinked spec files to their real paths — outside `rootDir` —
and so discovered no tests at all. Two lessons:

- **The script behaved correctly**: `B3`/`B4` require the `Test Suites:` / `Tests:` lines to parse and
  **failed closed** when they were absent, rather than reporting green on a run that never happened.
- **Do not grade this script through a symlink shadow root.** Use a real `git worktree` (with
  `node_modules` symlinked in, which *is* fine). Recorded because the shadow-root recipe is the
  documented default elsewhere in this vault and would silently mis-grade a correct fix here.

> **Script self-audit performed during authoring** ([[negative-test-verify-scripts-before-trusting-them]],
> [[verify-script-template-perl-helpers-fail-open]]):
> - Every path assertion uses an explicit `[ -e ]` / `[ ! -e ]`, **not** the template's
>   `file_contains` / `file_not_contains` helpers — those return "pass" for a *missing* file
>   (`grep` exits 2, and `!` inverts it to success), which would false-green `N2`/`N3` if
>   `jest.config.js` or `package.json` were ever renamed. `N2`/`N3` therefore assert the file
>   **exists** first, and FAIL if it does not.
> - `A3`'s grep is scoped with explicit `--exclude-dir` for `node_modules`, `.git`, `.nuxt`, `dist`.
>   Without those it can never pass — `node_modules` contains unrelated `NuxtLogo` strings.
> - `B3`/`B4` invoke Jest as a subprocess and read `${PIPESTATUS[0]}`, not `grep`'s status, so a
>   parse miss cannot masquerade as a green run. `B4` fails closed if the count line is unparseable.
> - No unbounded `.*?` and no multi-line perl helper is used anywhere
>   ([[verify-script-unbounded-lazy-gap-loses-containment]]) — every assertion is a whole-file
>   existence test, a line-scoped `grep`, or a subprocess exit code.
> - Every `run` row invokes a function defined in the script; the function list was cross-checked
>   against the row ids in this table, so no row can report bash's `127` as an honest FAIL.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | **Trivial** | One file deleted, 9 lines, no contract/schema/runtime surface |
| **Pre-draft step** | none (2 user decisions taken directly) | §10 D1/D2 resolved by asking; ralplan skipped per the skill's mechanical-fix exception |
| **Plan-review step** | none required | Trivial class. A `critic` pass is cheap if review wants one |
| **Implementation shape** | `executor` (single agent) | Deletion + two Jest runs |
| **Verification step** | verify-script + `verifier` | **Mandatory.** The FAIL→PASS baseline transition is the whole contract |
| **Code-review step** | none | Single-file deletion; the diff is self-evident |
| **Commit step** | git directly | One atomic commit |

### 9.3 TDD-gate disposition

**The `wms-tdd-gate` chain does not apply, and this is a named skip row — not a bypass.**

The skill's skip table has a **"No test surface"** row. It applies here in its strongest form,
because the deliverable *is* the removal of a test:

- The gate writes **failing Java tests** into `v{1,2}/wms-api`. This plan touches **no Java repo**
  — there is nothing for it to check out or write into.
- A TDD gate needs a test that fails before the fix and passes after. Here the pre-fix failing
  artifact **already exists**: it is `test/NuxtLogo.spec.js` itself, and the fix is to delete it.
  Authoring a new failing test to justify a deletion is incoherent.
- The gate's real function — capture a trustworthy pre-fix baseline — **is discharged**, twice
  over: the verify script's `4 pass, 4 fail` (§9.1 Step 3) and the four executed probes P1–P4
  (§1), including P2, which measured the post-fix numbers *before* any change.

The plan's own §5.2 Step 3 is the negative-test gate that the TDD chain would otherwise supply: if
the verify script does not report **4 fails** on unfixed `develop`, implementation stops.

Coverage of the acceptance property is therefore the verify script (`B3`/`B4` behavioural rows) plus
the §6 manual rows M1–M6 — not a Jest spec, for the reason given in §6.

### 9.4 Implementation Status

**Implemented 2026-08-12. PR open, NOT merged.** Every predicted figure was hit exactly.

| Item | Value |
|---|---|
| Worktree | `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-web-ui/SBDEV-2931` (base `origin/develop` @ `9bfa8ac`, freshly fetched) |
| Branch | `feature/SBDEV-2931-remove-dead-nuxtlogo-spec` |
| Commit SHA | **`7b9029a`** — `SBDEV-2931: delete the dead NuxtLogo spec that reddens every unfiltered test run` |
| Diff | **1 file, +0/−9** — `D test/NuxtLogo.spec.js` and nothing else |
| PR | **[#53](https://github.com/SiteBossInc/wms2-web-ui/pull/53)** — `wms2-web-ui` → `develop`, **MERGED 2026-08-12 17:44 UTC**, merge commit **`1f2605b`** |
| Post-merge re-verification | On merged `develop` (`1f2605b`): **`Result: 8 pass, 0 fail, 0 skip`**, `jest exit=0`, `27 passed, 27 total`, `251 passed`. `7b9029a` confirmed an ancestor of `develop`; **0** tracked `NuxtLogo` paths and **0** content matches remain on the merged branch. |
| Pre-fix Jest baseline | `Test Suites: 1 failed, 27 passed, 28 total` / `Tests: 251 passed` / **exit 1** ✅ as predicted |
| Post-fix Jest | `Test Suites: 27 passed, 27 total` / `Tests: 251 passed` / **exit 0** ✅ as predicted |
| Coverage delta | **251 → 251, zero loss — measured** |
| Verify pre-fix | `Result: 4 pass, 4 fail, 0 skip` ✅ (`A1`/`A2`/`A3`/`B3` red) |
| Verify post-fix | **`Result: 8 pass, 0 fail, 0 skip`** ✅ |
| Verify wiring proof | Same script against the **main checkout** still reported `A1`/`A2`/`A3` FAIL (`3 pass, 3 fail, 2 skip` with `SKIP_JEST=1`) — proving the 8/0 came from the worktree, not the stale main copy |
| ESLint | `--ignore-path .gitignore` → **3739 problems (1481 errors, 2258 warnings) in BOTH trees — zero delta**, all pre-existing. The deleted file contributed no findings. |
| Guards `N1`/`N2`/`N3` | green; `git diff --cached origin/develop -- jest.config.js package.json` confirmed **both byte-unchanged** |
| Manual rows | **M1/M2/M5 exercised** (M2: `--testPathPattern=store` → 5 suites / 37 tests, exit 0). **M3/M4/M6 outstanding — the reviewer's to run**; they are the only checks that confirm the file was inert in the *app build* rather than by argument. |
| Docs (Phase 4) | **None needed** — no `3-Resources/` architecture, design, or workflow doc references `NuxtLogo` or these suite counts (grepped). |
| ClickUp | SBDEV-2931 → `in development` (2026-08-12) → **`pr submitted`** at PR |
| v1 counterpart | **SBDEV-2937 — still `Open`**, deferred by decision D1. `v1/wms-web-ui` remains red. |

#### Deviations from the executor skill's default flow — stated, not buried

| Deviation | Why | Compensating control |
|---|---|---|
| **Phase 1 `ralph` loop not used** | One `git rm`. The plan's own §9.2 classes this Trivial → single executor. A PRD-driven loop over a one-line deletion adds nothing. | The verify script was the exit gate regardless: `4/4` → `8/0`. |
| **Phase 3a `verifier` + 3b `code-reviewer` lanes not run** | Session guidance forbids spawning subagents unless the user asks; plan §9.2 had already set `Code-review step: none — single-file deletion; the diff is self-evident`. **Conformance here is self-assessed, not independent.** | Verify script was **mutation-tested** (4/4 wrong-fix mutations caught, each by exactly one row) + the wiring proof above. Both §0 in-scope rows and all three §8 criteria green. |
| **Verify script run with `PROJECT_ROOT=<worktree>`, not the skill's symlink shadow root** | This script's `PROJECT_ROOT` is the *repo* root, not the monorepo root — and the shadow root **breaks Jest here** (§9.1 harness finding). | Wiring proved directly instead: main checkout still FAILs `A1`–`A3`. |

#### Not done

- ~~**Merging PR #53**~~ — **DONE 2026-08-12** on explicit instruction, merge `1f2605b`. Merged before the M3/M4/M6 manual rows were run, so those rows are now the **only** outstanding compensating control (see below).
- ~~**ClickUp → `on dev`**~~ — **DONE**, set after the merge was confirmed.
- **Archiving this plan** — run `archive-plan` **only after** manual rows **M3/M4/M6** pass. ⚠ Because the merge preceded them, `yarn build` / dev-server / clean-clone are unverified on this change; they are cheap and the risk is low (the file was never bundled), but nothing has *proven* it yet.
- **Worktree removal** — left in place at the path above so review feedback can be applied without recreating it. `archive-plan` step 5f owns cleanup; to remove sooner:
  `git -C v2/wms2-web-ui worktree remove .claude/worktrees/wms2-web-ui/SBDEV-2931 && git -C v2/wms2-web-ui worktree prune`
- **SBDEV-2937 (v1 twin)** — untouched. `v1/wms-web-ui` still exits 1 on every unfiltered run.
- **A CI gate that enforces the green exit code** — none exists (§8); this PR unblocks one rather than satisfying one.

---

## 10. Open Questions / Resolved Decisions

All resolved. No open questions block review.

| # | Question | Resolution | Source |
|---|---|---|---|
| **D1** | `v1/wms-web-ui` has the byte-identical dead spec. Fix both repos here, or v2 only? | **v2 only, v1 documented and split to a paired ticket.** Keeps the PR matching its ticket exactly. SBDEV-2937 filed 2026-08-12 with the measured v1 evidence. Accepted cost: v1 stays red until that ticket is worked (§4). | User decision, 2026-08-12 |
| **D2** | The ticket's motivation is CI-gating, but no CI job runs `yarn test`. Add the gate? | **No — deletion only.** Adding a pipeline gate needs a node runner and risks blocking merges on pre-existing flakiness; too large for a low-priority hygiene ticket. Recorded as a follow-up in §8 so the finding survives. | User decision, 2026-08-12 |
| **D3** | Ticket AC #2 hard-codes "test count stays at 250", but the measured count is 251. Which governs? | **The measured baseline governs.** AC restated in §8/§9 as "unchanged from the pre-fix baseline, captured at implementation time" — the property actually worth asserting, and one that does not rot. Verify `B4` encodes it as `≥ 251`. Ticket text left as filed; the correction is recorded in §1. | Plan author, from measurement (P1/P2) |
| **D4** | Delete the spec, or add the missing `NuxtLogo.vue` component? | **Delete.** Option B would add dead *production* code to satisfy a test that asserts Vue works, and would enter the coverage denominator, *lowering* reported coverage. Full comparison in §3. | Plan author; ticket concurs |

---

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ `db_verified: false` — **correct, not a gap**: no DB surface exists in a Jest-spec deletion. Gate discharged by four **executed** probes P1–P4 recorded in §1, incl. P2 which measured the post-fix result (251 tests, exit 0) before any change. No manual DB check owed to the implementer. |
| 1 | **All callsites enumerated** | ✓ §0 — 6 rows across all four UI repos. Row 1 in scope (the deletion); row 2 split to SBDEV-2937 (D1); rows 3–4 verified clean; row 5 asserted *unchanged* (`N2`); row 6 deferred (D2). Every in-scope row maps to a §9 check. |
| 2 | **Adjacent bugs** | ✓ Pattern-grepped `NuxtLogo` across all four UI repos + `ls test/` inventory each. Found the v1 twin (§4) — **not named in the ticket**. Mobile repos confirmed clean. Also found the *habit*: 9 lines in 7 vault docs (§0). |
| 3 | **Backward compatibility** | ✓ None possible — no API, schema, persisted state, payload, or error shape. `jest.config.js` + `package.json` asserted byte-unchanged (`N2`/`N3`). File is absent from every built artifact (M4 confirms). |
| 4 | **Concurrency** | ✓ N/A — no runtime code, no shared state. Deleting a file is idempotent. |
| 5 | **Multi-tenant** | ✓ N/A — no tenant context, query, or datasource anywhere in scope. |
| 6 | **Error handling** | ✓ No new throw path. The change *removes* an error (Jest's `createNoMappedModuleFoundError`); nothing consumes it — no CI job, config entry, or script references the suite (§0 rows 5–6). |
| 7 | **Observability** | ✓ N/A for runtime — no failure mode to log or alert on. The acceptance signal is Jest's exit code, asserted by `B3`. §8 records that nothing yet *enforces* it (no CI job) as an explicit follow-up rather than an implied guarantee. |
| 8 | **Rollback / migration** | ✓ No Flyway, no backfill, no flag, no deploy-order coupling. Rollback is `git revert` of a one-file deletion. |
| 9 | **Test coverage** | ✓ **No new automated test, deliberately** — the acceptance property is Jest's own exit code, which no suite can assert about its own runner (§6 rationale). Encoded in verify `B3`/`B4` + manual M1–M6. Zero coverage delta *measured* (P2: 251→251), not asserted. |
| 10 | **Cross-version (v1↔v2)** | ✓ §4 — v1 confirmed affected and **proportionally worse** (1 of 3 suites red vs 1 of 28); deferred to SBDEV-2937 by decision D1, with the asymmetry flagged for review rather than buried. Both mobile repos verified unaffected. |
