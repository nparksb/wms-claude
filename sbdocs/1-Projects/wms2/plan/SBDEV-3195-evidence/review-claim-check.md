# SBDEV-3195 — independent claim check

**Target:** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3195`,
branch `feature/SBDEV-3195-ci-runs-tests`, commit `ed575fb3`.
**Sources checked:** commit message, `.github/workflows/docker-image-develop.yml` comments,
the `### CI runs this suite (SBDEV-3195, 2026-09-08)` block in `CLAUDE.md`, and
`sbdocs/1-Projects/wms2/plan/SBDEV-3195-evidence/ac6-cross-repo-ci-survey.md`.
**Checked:** 2026-09-07. Read-only — the worktree was not modified (`git status --porcelain` empty
at the end of this pass). No Maven was run; the baseline was corroborated from the report XML
already on disk.

---

## HEADLINE — FALSE claims

### F1. "standaloneSetup — the only MockMvc mode used here" — **FALSE**

Appears in the commit message and, in a slightly longer form, in the workflow header comment
("standaloneSetup - the only MockMvc mode used in this repo").

`standaloneSetup` is used by 27 test files (48 occurrences). It is **not** the only mode. The
context-backed mode is present as `@AutoConfigureMockMvc`, and it is live:

```
$ git grep -l "standaloneSetup" HEAD -- src/test | wc -l
27
$ git grep -n "AutoConfigureMockMvc" HEAD -- src
HEAD:src/test/java/net/aim_ai/wms/common/base/BaseControllerIntegrationTest.java:20:@AutoConfigureMockMvc
HEAD:src/test/java/net/aim_ai/wms/integration/controller/ClientControllerLegacyIntegrationTest.java:41:@AutoConfigureMockMvc
HEAD:src/test/java/net/aim_ai/wms/integration/controller/rest/OrderRestControllerIntegrationTest.java:37:@AutoConfigureMockMvc
HEAD:src/test/java/net/aim_ai/wms/integration/controller/rest/SkuRestControllerIntegrationTest.java:40:@AutoConfigureMockMvc
HEAD:src/test/java/net/aim_ai/wms/unit/controller/CustomerOrderControllerH2Test.java:33:@AutoConfigureMockMvc
HEAD:src/test/java/net/aim_ai/wms/unit/controller/ReplenishOrderControllerH2Test.java:24:@AutoConfigureMockMvc
```

`BaseControllerIntegrationTest extends BaseIntegrationTest`, which is
`@SpringBootTest(classes = StartApplication.class)` — a full context, so MockMvc there is built
from the `WebApplicationContext`, not standalone. Three classes extend it, two of which surefire
runs (`*ContextTest` names):

```
$ git grep -ln "extends BaseControllerIntegrationTest" HEAD -- src/test
HEAD:src/test/java/net/aim_ai/wms/integration/controller/CustomerOrderControllerIntegrationTest.java
HEAD:src/test/java/net/aim_ai/wms/security/SdrReadGateEnforcementContextTest.java
HEAD:src/test/java/net/aim_ai/wms/smoke/WebContextLaneContextTest.java
```

`WebContextLaneContextTest`'s entire purpose is to prove that lane boots
(`@DisplayName("SBDEV-3017 slice A — the @AutoConfigureMockMvc lane boots")`), and
`SdrReadGateEnforcementContextTest` drives a real 403 through it.

The literal string `webAppContextSetup` does appear zero times — but that is the wrong instrument,
because Boot's `@AutoConfigureMockMvc` builds the context-backed MockMvc without the caller ever
naming that method. Positive control that the search itself works: the same
`git grep` over `HEAD -- src` returns 16 hits for `AutoConfigureMockMvc`.

Note the repo's own javadoc, in the very file this reasoning was drawn from, is correctly hedged:
`SdrReadGateEnforcementContextTest:32` says standaloneSetup is *"the lane most gate tests here
use"* — **most**, not **only**. The commit tightened a correct "most" into a false "only".

### F2. "so nothing in this repo evaluates `@PreAuthorize` at runtime" — **inference FALSE; conclusion incidentally holds**

The premise ("standaloneSetup installs no method-security advisor") is true and is quoted verbatim
from `PutawayConfigRepositoryEventHandlerUnitTest:373`, where it is correctly scoped to
standaloneSetup. Generalising it to the whole repo does not follow, because the
`@AutoConfigureMockMvc` / `@SpringBootTest` lane exists, is live, and *does* load
`MethodSecurityConfig`:

```
$ git grep -n "EnableMethodSecurity" HEAD -- src/main
HEAD:src/main/java/net/aim_ai/wms/MethodSecurityConfig.java:49:@EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false)
```

The advisor is therefore installed in that lane. The conclusion survives only for a different
reason than the one given: none of the 14 `src/main` files carrying `@PreAuthorize` is exercised
through that lane. The 4 classes using `@WithMockUser` in a context lane
(`ClientControllerLegacyIntegrationTest`, `CustomerOrderControllerIntegrationTest`,
`CustomerOrderControllerH2Test`, `ReplenishOrderControllerH2Test`) target controllers that carry no
`@PreAuthorize`; the 10 `@PreAuthorize` methods on `PutawayConfigService` are covered only by plain
Mockito unit tests. So *as written* the sentence is unsound; the underlying "no test kills a
`@PreAuthorize` deletion" point stands and is independently documented by
`586a5a1e` F3 ("deleting ItemDataController.setPutAwayLocation's annotation survived all 5673 tests").

Recommended rewrite: *"no test drives a `@PreAuthorize`-carrying bean through a security-aware
proxy — the standaloneSetup lane installs no advisor, and the context lane that does never reaches
one."*

### F3. "of which 4 remain @Disabled — **all four citing a current, open ticket**" — **FALSE**

One of the four cites **SBDEV-2216, which is Closed** (closed 2026-07-26).

```
$ for f in $(git ls-tree -r --name-only HEAD -- src/test | grep -E 'IT\.java$'); do
    git show HEAD:$f | grep -nE '^[[:space:]]*@Disabled' | sed "s|^|$f:|"; done
.../integration/ReplenishDupConcurrencySliceIT.java:166:    @Disabled("SBDEV-3248 slice 5: ...
.../integration/performance/BillofladingServiceFinishTransferPerformanceIT.java:78:@Disabled("on-demand only — long-running load test for SBDEV-2216 AC2. " +
.../service/FixLocationAssignmentServiceIT.java:42:@Disabled("SBDEV-3239: harness FIXED, one assertion unmet. ...
.../service/TransferLaneLeakOnCancelIT.java:33:@Disabled("SBDEV-3239: harness FIXED, test fixture incomplete. ...
```
(positive control: the same regex over all of `src/test` matches 21 files, so it is not silently failing)

ClickUp statuses:

| Cited ticket | Status | Verdict |
|---|---|---|
| SBDEV-3248 | `Open` | current |
| SBDEV-3239 (×2) | `pr submitted` | current |
| **SBDEV-2216** | **`Closed`** (`date_closed` 1785331877134 → 2026-07-26) | **not current** |

This is the exact failure mode SBDEV-3239's own **AC-3** was written to eliminate ("Any test that
cannot be honestly implemented is re-`@Disabled` with a marker naming the real blocker and a live
ticket — **never a closed one**"). Mitigating: that marker's text is `"on-demand only — long-running
load test"`, i.e. a deliberate on-demand exclusion rather than a parked broken test, so the ticket
reference is contextual rather than a tracking pointer. The claim as written is still false.

Second, smaller inaccuracy in the same sentence: "4 remain @Disabled" reads as four *classes*. Three
are class-level; `ReplenishDupConcurrencySliceIT`'s marker is **method-level** (line 166, on one
`@Test`) — that class runs, with one method skipped.

### F4. "13 workflow files across four repos" — **FALSE (actual: 16)**

Stated in the commit message and in the survey ("**13 GitHub workflow files across the four repos**").
The survey's own table contradicts it: 3 + 4 + 5 + 4 = **16**.

```
$ for r in v2/wms2-api v2/wms2-web-ui v2/wms2-mobile-ui v1/wms-api; do
    echo "$r: $(git -C /home/nampark/dev/wms-claude/$r ls-tree -r --name-only origin/develop -- .github/workflows | wc -l)"; done
v2/wms2-api: 3
v2/wms2-web-ui: 4
v2/wms2-mobile-ui: 5
v1/wms-api: 4
```

13 is the count for the **three other** repos (4+5+4). Either the number should be 16 or the scope
should be "three other repos".

### F5. "**none running tests**" (commit) / "**Not one runs a test**" (survey) — **FALSE, and self-contradicted**

`v2/wms2-mobile-ui/.github/workflows/playwright.yml` runs `npx playwright test`:

```
$ git -C /home/nampark/dev/wms-claude/v2/wms2-mobile-ui show origin/develop:.github/workflows/playwright.yml | grep -nE "^on:|branches:|run:"
2:on:
4:    branches: [ main, master ]
6:    branches: [ main, master ]
17:      run: npm ci
19:      run: npx playwright install --with-deps
21:      run: npx playwright test
```

The survey itself says so two paragraphs later ("**1, but see below**" in the table, then "The one
exception…"), so the bolded lead sentence contradicts the document it leads. The commit message
carries the unqualified version forward with no "but see below" attached. The defensible claim is:
*13 of the 16 files across the other three repos run no tests; one (playwright.yml) runs tests but
only on `main`.*

### F6. Survey: "six real spec files behind it (`tests/e2e/{home,lookup,m23-authz-denial,navigation,picking}.spec.ts` plus `auth.setup.ts`)" — **FALSE (undercount)**

```
$ git -C /home/nampark/dev/wms-claude/v2/wms2-mobile-ui ls-tree -r --name-only origin/develop -- tests
tests/e2e/auth.setup.ts
tests/e2e/fixtures.ts
tests/e2e/home.spec.ts
tests/e2e/lookup.spec.ts
tests/e2e/m23-authz-denial.spec.ts
tests/e2e/navigation.spec.ts
tests/e2e/picking.spec.ts
tests/e2e/putaway.spec.ts      <-- missed
tests/e2e/replenish.spec.ts    <-- missed
```

Seven `.spec.ts` files, not five; nine files in `tests/e2e` total. Both missed files predate the
survey (`putaway.spec.ts` added `c56f57e`, 2026-05-28; `replenish.spec.ts` added `3f1156a`,
2026-07-12), so this is not a staleness artifact. `playwright.config.ts:4` is
`testDir: './tests/e2e'`, so all of them are in scope. The error is in the direction that
*understates* the value of re-pointing that workflow — the recommendation is unaffected.

---

## VERIFIED claims

### V1. "No build path in this repo ran a single test" — **VERIFIED**

```
$ git show origin/develop:.gitlab-ci.yml | grep -n skipTests
47:    - mvn package -s ci_settings.xml -DskipTests=true -D"checkstyle.skip" -Dmaven.javadoc.skip=true
$ git show origin/develop:Dockerfile | grep -n skipTests
16:RUN mvn clean package -DskipTests -Dmaven.javadoc.skip=true
```
`Dockerfile_new` carries the same `-DskipTests` line; `Dockerfile_old` invokes no Maven at all. The
only other CI descriptors in the repo are the three workflow files and `.gitlab-ci.yml`:
```
$ git ls-tree -r --name-only origin/develop | grep -iE "\.github/|gitlab|jenkins|azure-pipelines|circleci|travis"
.github/workflows/docker-image-develop.yml
.github/workflows/docker-image-uat.yml
.github/workflows/docker-image.yml
.gitlab-ci.yml
```
I read all three workflows in full on `origin/develop`. None contains `mvn`, `test`, or any
test-invoking step.

### V2. "all three GitHub workflows went checkout -> docker build-push" — **VERIFIED in substance, imprecise as shorthand**

The load-bearing part (no tests) is confirmed above. The shorthand undersells two of them:
`docker-image-uat.yml` resolves a semver tag, **pushes a git tag**, builds/pushes, creates a
**GitHub Release**, and fires two Portainer webhooks; `docker-image.yml` resolves versions from
tags before building. Only `docker-image-develop.yml` is literally checkout → build-push → webhook.
Not a defect, but "checkout -> docker build-push" is not accurate for all three.

### V3. "445 test classes" — **VERIFIED under one specific definition**

```
$ git ls-tree -r --name-only HEAD -- src/test/java | grep -cE 'Test\.java$'
445
```
Exact match for "files under `src/test/java` whose name ends `Test.java`". For context, other
defensible definitions give: 488 (all `.java` under `src/test`), 478 (matching any
surefire/failsafe name pattern), 471 (files containing a `@Test`/`@ParameterizedTest`/`@ArchTest`).

⚠ Worth knowing: 445 **excludes the 28 `*IT` classes**, which the same commit message elsewhere
says are wired into failsafe. The number of classes Maven actually runs is 445 + 25 = 470. 445 is a
safe lower bound, so the argument is unaffected.

### V4. "28 `*IT` classes, 3 excluded by name in pom.xml, 25 wired into failsafe" — **VERIFIED**

```
$ git ls-tree -r --name-only HEAD -- src/test | grep -cE 'IT\.java$'
28
```
`pom.xml` failsafe `<excludes>` names exactly three, each with an inline reason:
`WarehouseStockReportServiceStreamIT` (INSERT into a view), `MessageCleanupBatchServiceIT`
(`@MockitoBean` erases SDR metadata), `ParcelMonitorViewServiceConcurrencyIT` (incomplete fixture,
6 constraint violations). 28 − 3 = 25. "each with a stated reason" — verified, all three carry a
substantive multi-line justification.

### V5. "surefire alone would silently skip the whole failsafe lane (`*IntegrationTest`, `*E2ETest` and, since SBDEV-3239, `*IT`)" — **VERIFIED**

`pom.xml:564-567` surefire `<excludes>`: `**/*IntegrationTest.java`, `**/*E2ETest.java`.
`pom.xml:714-733` failsafe `<includes>`: those two **plus** `**/*IT.java`.
`*IT` is skipped by surefire not by exclusion but by non-inclusion — surefire's defaults are
`Test*`, `*Test`, `*Tests`, `*TestCase`, none of which match `*IT`. Same outcome, different
mechanism; `CLAUDE.md` already records this correctly. Counts: 44 `*IntegrationTest`, 1 `*E2ETest`,
28 `*IT`.

### V6. "the trigger that stood here targeted `main`" — **VERIFIED**

```
$ git show origin/develop:.github/workflows/docker-image-develop.yml | head -8
name: Docker Image CI

on:
  push:
    branches: [ "develop" ]
#  pull_request:
#    branches: [ "main" ]
```
The diff removes exactly those two commented lines and writes `pull_request: branches: [ "develop" ]`
fresh. `docker-image.yml` still carries the same dead `# branches: [ "main" ]` pair, unchanged.

### V7. Baseline "surefire 6330/0/0/6, failsafe 352/0/0/70" — **VERIFIED against the on-disk reports**

I did not re-run Maven. Tallying the XML already in the worktree:

```
target/surefire-reports: files=1693 unparseable=0 tests=6330 failures=0 errors=0 skipped=6
target/failsafe-reports: files=141  unparseable=0 tests=352  failures=0 errors=0 skipped=70
```
Exact match on all eight numbers. Report mtimes (surefire 22:12:39→22:16:06, failsafe
22:17:04→22:21:22 on 2026-09-07) are consistent with a single coherent run finishing ~1 minute
before the commit at 22:22:10, and the 0/0 result argues against a concurrent-build corruption.

### V8. Workflow structure (`needs`, `if`, `concurrency`, triggers) — **VERIFIED**

Read from `HEAD:.github/workflows/docker-image-develop.yml`:
`on: push: branches: ["develop"]` + `pull_request: branches: ["develop"]` (l.18-25);
`concurrency.group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}`,
`cancel-in-progress: ${{ github.event_name == 'pull_request' }}` (l.31-33);
`test` job with `timeout-minutes: 30` (l.43), `run: mvn -B -ntp clean verify` (l.65),
summary step `if: always()` (l.73), artifact upload `if: failure()` (l.111);
`build` job with `needs: test` (l.125) and `if: github.event_name == 'push'` (l.129).
All match the described behaviour. On a push `github.event.pull_request` is null, so the group key
falls through to `github.sha` — one run per group, nothing to cancel, as claimed.

### V9. CLAUDE.md: "The `release` → UAT and `main` → prod workflows are deliberately left ungated" — **VERIFIED**

`docker-image-uat.yml` triggers on `push: branches: ["release"]`; `docker-image.yml` on
`push: branches: ["main"]`. Neither is touched by this change. The stated hotfix-to-`main` gap is
real and correctly labelled as accepted.

### V10. "checkstyle is not bound to the build" / "`-Dcheckstyle.skip` in `.gitlab-ci.yml` is a no-op" — **VERIFIED**

⚠ Neither sentence appears in the commit message, the workflow comments, or the CLAUDE.md diff — it
was checked because the review brief asked for it, not because the artifact asserts it.

```
$ git show HEAD:pom.xml | grep -n -i checkstyle
243:		    <artifactId>checkstyle</artifactId>
$ git show HEAD:pom.xml | grep -n "maven-checkstyle-plugin"
(no output)
```
Line 243 is a plain `com.puppycrawl.tools:checkstyle:10.21.0` **dependency**, not the plugin. No
`maven-checkstyle-plugin` is declared, so no checkstyle goal is bound to any phase and
`-D"checkstyle.skip"` on line 47 of `.gitlab-ci.yml` toggles nothing. (`.checkstyle` at the repo
root is an Eclipse IDE fileset config pointing at `file:/Users/ra1079/...` — a dead absolute path
on someone else's machine.)

### V11. AC-6 survey, per-repo table — **VERIFIED except the total (F4) and the spec count (F6)**

| Repo | Workflow files | Survey says | Actual | Any run tests? |
|---|---|---|---|---|
| `v2/wms2-api` | 3 | 3, none | 3, none | correct |
| `v2/wms2-web-ui` | 4 | 4, none | 4, none | correct |
| `v2/wms2-mobile-ui` | 5 | 5, "1, but see below" | 5, `playwright.yml` only | correct |
| `v1/wms-api` | 4 | 4, none | 4, none | correct |

Other survey specifics, all confirmed:
- `playwright.yml` triggers on `branches: [ main, master ]` for both `push` and `pull_request`.
- `master` is absent from the remote: `git ls-remote --heads origin | wc -l` → **31**, and no
  `refs/heads/master` (only `develop`, `main`, `release` among the named ones). Both numbers exact.
- `playwright.config.ts:29-34` **is** the `webServer` block, byte-for-byte as quoted
  (`command: 'npm run dev'`, `url: 'http://localhost:3001/mobile/'`, `reuseExistingServer: true`,
  `timeout: 60_000`). The self-correction in the survey is right and the line range is exact.
- `"test": "jest"` in both `wms2-web-ui/package.json:14` and `wms2-mobile-ui/package.json:10`.
- **84 spec files in web-ui**: `git ls-tree -r --name-only origin/develop | grep -cE '\.(spec|test)\.(js|ts)$'` → **84**. Exact.
- "The four `.gitlab-ci.yml` files add nothing": `v1/wms-api` and `v2/wms2-api` both pass
  `-DskipTests=true`; the two Node repos' files have no test stage and invoke no test runner. Correct.

---

## UNVERIFIED / UNVERIFIABLE

### U1. "45 of them the authorization programme's only control" — **not reproducible from any defensible definition**

I could not derive 45 from a census that survives inspection. What the repo gives:

| Definition | Count |
|---|---|
| files under a `.../security/` package | **34** |
| files referencing `RequiresFunction\|FunctionEnum\|FunctionGuard\|AccessService\|PreAuthorize\|SdrFunctionRules` | **66** |
| paths matching the substring set `Gate\|Authz\|Sdr\|Security\|Access\|Function\|RequiresFunction` | **45** |

The third reproduces the number exactly, but it is not a test-class census: it **includes two
non-test files** (`common/fixtures/MockSecurityContext.java`, `unit/security/SdrTestGuards.java`)
and **excludes six authz test classes** that live in `net/aim_ai/wms/security/` without a matching
substring (`AdviceCollectionPostWithdrawalContextTest`, `AdviceStateReadOnlyContextTest`,
`MustStayWritableCollectionPostWithdrawalContextTest`, `PutForCreationWithdrawalContextTest`,
`Sbdev3017OmsCarveOutSourceContractTest`, `SurfaceInventoryContextTest`). The two errors happen to
nearly cancel.

Separately, the memory record for this ticket carries the pair "**418** test classes incl. **45**
authz pins" — the 445 was re-derived for this commit and the 45 was not. The figure is rhetorical
and nothing in the change depends on it, but it should either be re-derived under a stated
definition or softened to "roughly 40".

### U2. "A PR deleting a `@RequiresFunction` compiled, merged green, and deployed straight to dev" — **misattributed; the substance is true, the annotation named is wrong**

Two real events are compressed into one sentence that matches neither.

The merged PR is `169d7071` ("feat(authz): putaway config writes gate on FUNCTIONS, not sb_admin
[SBDEV-3017 R8]", 2026-08-27, an ancestor of `origin/develop`). Its diff removes **seven
`@PreAuthorize(Authority.IS_SB_ADMIN)`** lines and adds `@RequiresFunction` — it deleted a
`@PreAuthorize`, not a `@RequiresFunction`. The follow-up `586a5a1e` records the consequence:
*"F1 HIGH (blocking) — ON main THIS LEFT ALL FOUR ENDPOINTS TOTALLY UNGATED."* So a merged,
dev-deployed PR really did remove an authorization gate with nothing catching it.

The `@RequiresFunction` deletion is a different thing: `586a5a1e` F3 — *"deleting
ItemDataController.setPutAwayLocation's annotation survived all 5673 tests"* — which was a
**mutation probe**, not a merged PR.

Sweeping every commit on `origin/develop` that removes a `@RequiresFunction` line from `src/main`
finds 9, and all are gate *replacements* or widenings (SBDEV-3158 review fixes, SBDEV-3063,
SBDEV-2968) or a deliberate whole-path deletion (`c6409a16`). None is a naked gate removal.

Recommended rewrite: *"a merged PR removed a `@PreAuthorize` backstop and shipped to dev with the
four endpoints ungated (`169d7071`, caught only by a later review lane); separately, deleting a
`@RequiresFunction` survives the whole suite."*

### U3. "The suite is ~4 minutes" (workflow comment, l.40) — **contradicted by the artifacts of the very run cited as the baseline**

Report mtimes in this worktree span **22:12:39 → 22:21:22 = 8m 43s** across the two lanes, before
counting `clean`, compile, dependency resolution and the jacoco report. Sum of per-class `time`
attributes: surefire 276s + failsafe 317s = 593s (parallelism makes this an upper bound on wall
time; the mtime span is the better estimate).

The likely provenance of "~4 minutes" is SBDEV-3239's measured "≈ 3m 45s" — but that was taken when
`mvn verify` **aborted before the integration lane** (6 surefire reds), so it never included
failsafe. On this commit both lanes run.

This does not break the gate: `timeout-minutes: 30` still has margin. But a GitHub runner is
typically slower than this laptop, and the comment's stated rationale ("The suite is ~4 minutes. 30
leaves room for a cold dependency download and a slow runner") is reasoning from a number that is
roughly half the observed one. Suggest changing the comment to "~9 minutes locally".

### U4. "Totals move with every merge (5620 -> 5937 -> 6010 -> 6018 -> 6330 within days)" — **partially corroborated**

Four of the five appear in `origin/develop` commit messages (5620 ×2, 6010 ×8, 6018 ×2, 6330 ×3).
**5937 appears in no commit message**; it does appear in four sbdocs plan/evidence files, so it has
a paper trail, just not one in git. The claim is explicitly unasserted by the workflow (AC-3), so
nothing depends on it.

### U5. actionlint verification — **UNVERIFIABLE here**

The commit states actionlint was run clean with a deliberate bad `needs:` target and an undefined
context injected as a negative control. `actionlint` is not on this PATH
(`command -v actionlint` → nothing), so I cannot reproduce it. The described method (inject a known
defect, confirm the linter reports it) is the right shape; I simply could not re-run it.

Likewise "Testcontainers needs a Docker daemon; ubuntu-latest ships one" is a well-known property of
the GitHub-hosted runner image, corroborated by SBDEV-3239's own out-of-scope note, but not
verifiable from this repo.

---

## Summary

| # | Claim | Verdict |
|---|---|---|
| F1 | standaloneSetup is the only MockMvc mode | **FALSE** |
| F2 | nothing in this repo evaluates `@PreAuthorize` at runtime | **inference FALSE**, conclusion holds for another reason |
| F3 | all four `@Disabled` ITs cite a current, open ticket | **FALSE** — SBDEV-2216 is Closed |
| F4 | 13 workflow files across four repos | **FALSE** — 16 (13 = the other three repos) |
| F5 | none of them run tests | **FALSE** — `playwright.yml` does; the survey says so itself |
| F6 | six spec files behind playwright.yml | **FALSE** — seven `.spec.ts` (missed putaway, replenish) |
| V1–V11 | no build path ran tests · 445 · 28/3/25 · surefire-vs-failsafe · the `main` trigger · the 6330/352 baseline · workflow structure · release/main ungated · checkstyle unbound · the per-repo table | **VERIFIED** |
| U1 | "45 authz test classes" | not reproducible under any clean definition (34 / 66 / 45-by-accident) |
| U2 | "a PR deleting a `@RequiresFunction`" | misattributed — the PR deleted `@PreAuthorize`; substance is real |
| U3 | "the suite is ~4 minutes" | contradicted — 8m43s in this worktree |
| U4 | the 5620→6330 series | 4 of 5 in git; 5937 only in sbdocs |
| U5 | actionlint clean | unverifiable (not installed) |

**Pattern holds, again.** Every quantitative claim I could re-derive survived exactly — 445, 28, 3,
25, 6330/0/0/6, 352/0/0/70, 84, 31 branches, `playwright.config.ts:29-34`. Every claim containing
*only / all / none / not one* failed: F1 ("the only MockMvc mode"), F2 ("nothing in this repo"), F3
("all four"), F5 ("none running tests" / "Not one"). F4 and F6 are miscounts in the survey, both in
the direction of understating the surface.

**None of these invalidates the change.** The workflow does what it says: `verify` runs before the
image builds, `needs: test` gates it, and PRs into `develop` are covered. The corrections are to
the narrative, plus one real hygiene finding — the SBDEV-2216 marker violates SBDEV-3239's AC-3 and
should be re-pointed or the reference dropped.
