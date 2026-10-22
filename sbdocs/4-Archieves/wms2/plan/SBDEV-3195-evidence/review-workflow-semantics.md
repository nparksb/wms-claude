# SBDEV-3195 — review: GitHub Actions workflow mechanics

**Scope:** mechanical correctness of `.github/workflows/docker-image-develop.yml` at commit `ed575fb3`
(branch `feature/SBDEV-3195-ci-runs-tests`, one commit ahead of `origin/develop`). No Java review.

**Method note.** The file's comments are the author's assertions and were not treated as evidence.
Every Actions-semantics claim below is resolved against the **primary doc source** — the raw markdown
of `github/docs@main` — because two separate summarised web answers got question 3 **wrong** in the
direction that would have invalidated the whole change. Details in Finding 0.

**Verdict: YES — safe to merge.** No Critical findings. One High, two Medium, eight Low. Nothing in
this workflow can produce a deploy from a red suite. See §Verdict for the one assumption I did not
certify and the recommended merge procedure.

---

## Finding 0 (method) — two web sources gave the wrong answer to the critical question

Asked whether a workflow file introduced *by a PR* runs *on that PR*, two summarised doc lookups both
answered **no**, citing "This event will only trigger a workflow run if the workflow file exists on the
default branch." Both were wrong: that note belongs to other events and was over-generalised to
`pull_request`. Had it been accepted, this review would have reported the author's verification plan as
invalid. Resolved by pulling the doc source and reading the `pull_request` section itself (Finding 3).

Recorded because the failure mode — a confident summary that agrees with the adversarial hypothesis —
is exactly the one this review was asked to guard against, and it pointed at the reviewer, not the author.

---

## 1. Does `needs: test` actually stop the image build, registry push and Portainer webhooks?

**Yes, in all four failure modes. AC-1 holds.** No finding.

Parsed from the file (not read by eye — `yaml.safe_load`):

```
build.needs = 'test'   build.if = "github.event_name == 'push'"
test.timeout-minutes = 30
```

Primary source, `data/reusables/actions/jobs/section-using-jobs-in-a-workflow-needs.md`:

> "If a job fails or is skipped, all jobs that need it are skipped **unless the jobs use a conditional
> expression that causes the job to continue.** [...] If you would like a job to run even if a job it is
> dependent on did not succeed, use the `always()` conditional expression in `jobs.<job_id>.if`."

`content/actions/reference/workflows-and-actions/expressions.md:322`:

> "A default status check of **`success()` is applied unless you include one of these functions.**"

`build`'s `if` contains no status check function, so `success()` is implicitly applied. Therefore:

| Test job outcome | `success()` | `build` runs? | Image / push / webhooks |
|---|---|---|---|
| `mvn` fails | false | **no — skipped** | none |
| 30-min timeout | false (job concludes failed) | **no — skipped** | none |
| Job cancelled | false | **no — skipped** | none |
| Whole run cancelled | n/a — run terminates | **no** | none |

The escape hatch the docs describe (`always()`) is **not** present. Verified against the parsed AST above,
not against the comment on line 123.

One scoping caveat, not a defect: this guarantees no deploy *from this workflow run*. It is not a
guarantee that nothing else deploys — see Finding 8.

## 2. Does `if: github.event_name == 'push'` weaken the `needs:` gate?

**No. They are ANDed, not ORed.** No finding.

Same primary source as above (`expressions.md:322`). The effective condition on `build` is:

```
success()  AND  github.event_name == 'push'
```

Both must hold. The `if` can only ever make `build` *less* likely to run, never more. The dangerous
inverse — `if: always() && github.event_name == 'push'`, which **would** deploy from a red suite — is not
what is written; the parsed value is the bare comparison. This combination cannot produce a deploy from
a red suite.

## 3. Will `pull_request: branches: [develop]` fire for the PR that INTRODUCES this file?

**Yes. The author's verification plan is valid.** No finding. This is the question flagged as
invalidating, and it is the one two web summaries got wrong (Finding 0).

Primary source, `content/actions/reference/workflows-and-actions/events-that-trigger-workflows.md:459`,
the `pull_request` row:

| Webhook event payload | `GITHUB_SHA` | `GITHUB_REF` |
|---|---|---|
| `pull_request` | Last merge commit on the `GITHUB_REF` branch | PR merge branch `refs/pull/PULL_REQUEST_NUMBER/merge` |

Two independent confirmations from the same file:

1. **The `pull_request` section does not carry the default-branch columns.** Twenty-plus other events
   (`issue_comment`, `label`, `schedule`, `workflow_run`, `check_run`, …) show `Last commit on default
   branch | Default branch` in those two columns. `pull_request` shows the merge-branch values instead.
   `pull_request_target` (line 665) **does** show `Last commit on default branch | Default branch`.
2. **Line 673 states the contrast outright:**
   > "This event runs in the context of the default branch of the base repository, **rather than in the
   > context of the merge commit, as the `pull_request` event does.**"

`pull_request` is evaluated from `refs/pull/N/merge`, which contains the PR's own changes — so a workflow
file added in the PR branch is present and runs. (`actions/checkout` defaults to `GITHUB_REF`, so the
suite runs against the *merged result*, which is the desirable behaviour here.)

Also confirmed: this repo's default branch is **`main`**, not `develop` (`gh repo view`). Irrelevant for
`pull_request`, but it would have been fatal had the author reached for `pull_request_target`.

### Low-1 — a PR with a merge conflict silently runs nothing

Same doc note, `pull_request` section:

> "Workflows will not run on `pull_request` activity if the pull request has a merge conflict. The merge
> conflict must be resolved first."

No merge ref can be built, so no run is created — the check is *absent*, not red. Combined with Finding 4
(the check cannot be made required on this plan), a conflicted PR shows no test signal at all. Resolve
conflicts before reading the check as meaningful.

## 4. The `concurrency` block

**The author's core claim is correct; the phrase "byte-for-byte" is not.**

**Is an expression legal in `cancel-in-progress`? Yes.** `data/reusables/actions/actions-group-concurrency.md`:

> "To conditionally cancel currently running jobs or workflows in the same concurrency group, you can
> specify `cancel-in-progress` as an expression with any of the allowed expression contexts."

The docs' own example is `cancel-in-progress: ${{ !contains(github.ref, 'release/')}}`. Allowed contexts
are `github`, `inputs`, `vars`; every expression here uses only `github`. Legal.

**Key derivation is sound.** On `push`, `github.event.pull_request` is undefined, property access yields
null, and `null || github.sha` falls back to the SHA. A PR key (`…-318`) and a push key (`…-<40 hex>`) can
never collide. So a PR run and a push run on the same commit land in **different** groups — the author's
claim holds.

**Push runs cannot cancel each other** — correct, because distinct pushes carry distinct SHAs.

### Low-2 — "deploy behaviour is byte-for-byte what it was" overstates it

A concurrency group **serialises even when `cancel-in-progress` is false**. Same doc:

> "there can be at most one running and one pending job in a concurrency group at any time. When a
> concurrent job or workflow is queued, if another [...] is in progress, the queued job or workflow will
> be `pending`. **Any existing `pending` job or workflow in the same concurrency group, if it exists, will
> be canceled** and the new queued job or workflow will take its place."

Before this change there was no group, so two runs sharing a key ran in parallel; now the second waits and
a third would cancel the second *while pending*. This requires two runs at the same SHA — a force-push
back to a prior SHA, or a manual re-run while the first is still in flight. Rare and harmless (worst case
a delayed deploy, never a wrong one), but the behaviour is not unchanged. Reword the comment on lines 27–30.

### Medium-1 — `github.workflow` is not unique: two workflows share the name "Docker Image CI"

Hard evidence from the API, not from the files:

```
246185111  Docker Image CI      .github/workflows/docker-image-develop.yml  active
246185112  Docker UAT Image CI  .github/workflows/docker-image-uat.yml      active
246185113  Docker Image CI      .github/workflows/docker-image.yml          active
```

`github.workflow` resolves to the `name:` field, so **both** the develop and the main workflow produce the
string `Docker Image CI`, and the group prefix is not workflow-unique. The docs warn about exactly this:

> "If you have multiple workflows in the same repository, concurrency group names must be unique across
> workflows to avoid canceling in-progress jobs or runs from other workflows. Otherwise, any previously
> in-progress or pending job will be canceled, **regardless of the workflow.**"

**Harmless today** — `docker-image.yml` declares no `concurrency`, so it joins no group; I verified this
rather than assuming it. It is a latent trap for whoever gates `main`/`release` next (the AC-6 follow-up):
copying this block into `docker-image.yml` would put prod and dev runs in the same namespace, colliding
whenever `main` and `develop` resolve to the same SHA.

It is also a live usability problem independent of concurrency: the two workflows are indistinguishable in
the Actions tab (`gh run list` shows bare `Docker Image CI` for every develop push), and any future check
configuration would have to disambiguate them by job name alone.

**Fix (cheap, do it in this PR):** rename this workflow to something like `Docker Image CI (develop)`.
Note line 15 already claims the name is "deliberately unchanged" — that decision predates this evidence
and should be revisited; see Low-6.

## 5. The `Record the suite baseline` heredoc

**Correct. Verified by execution, not by reading.** No structural finding.

**YAML dedent** — loaded the file with `yaml.safe_load` and printed the resulting script. The block scalar
dedents to column 0 and the terminator lands correctly:

```
  1|set -euo pipefail
  2|python3 - <<'PY' >> "$GITHUB_STEP_SUMMARY"
  3|import glob, xml.etree.ElementTree as ET
 ...
 33|PY
```

`PY` is at column 0 with no leading whitespace, which is what unquoted `<<'PY'` (not `<<-`) requires.
Python's relative indentation survives. The delimiter is quoted, so the shell performs no expansion or
globbing inside the body — correct, given the `**` and f-strings in the payload.

**Executed the dedented script verbatim** under four conditions:

| Condition | Exit | Result |
|---|---|---|
| reports with 2 failures / 1 error | **0** | table correct: `10 / 2 / 1 / 3` |
| a truncated, unparseable `TEST-*.xml` alongside a good one | **0** | file count `1`, not `2` — the corrupt file is skipped *and* excluded from the count, as the comment claims |
| `target/` absent entirely (build died before any test) | **0** | all-zero table |
| `testsuite` element with no attributes | **0** | `r.get("tests", 0)` default holds |

The author's claim about this step is accurate.

**Can `if: always()` mask a failed test job? No.** `always()` is a *step* condition. A step succeeding
after a failed step does not reset the job conclusion — the job is failed because `mvn` failed, and
`needs: test` keys on the **job** conclusion. Confirmed consistent with `expressions.md`: `success()`
"Returns `true` when all previous steps have succeeded." The neighbouring `Upload test reports` step uses
`if: failure()` correctly, and `failure()` ("Returns `true` when any previous step of a job fails") stays
true after the `always()` step succeeds, so reports still upload.

### Low-3 — an all-zero summary is indistinguishable from a genuine zero

Row 3 of the table above: when the build dies before any test runs, the step publishes a clean all-zero
baseline. The job is red regardless, so nothing is masked, but a reader skimming the summary sees a
well-formed table rather than "no reports were produced". Consider printing an explicit
`no report files found — the build did not reach the test phase` when `parsed == 0` for both lanes.

### Low-4 — `set -u` vs `GITHUB_STEP_SUMMARY` (theoretical only)

With the variable unset the step exits 1 (`unbound variable`). GitHub-hosted runners always set it, so
this cannot fire in this workflow. Recorded for completeness, not for action.

## 6. Would the FIRST run on a real runner fail for an environmental reason?

No blocker found. One Medium, several Lows.

**Clean:**
- **Action versions** — `checkout@v4`, `setup-java@v4`, `upload-artifact@v4`. All current; notably **not**
  `upload-artifact@v3`, which was shut down. `docker/login-action@v3.3.0` and
  `docker/build-push-action@v6.9.0` are unchanged from the existing file.
- **JDK** — `temurin` 21 matches `<java.version>21</java.version>` / `maven.compiler.source|target 21`.
- **Docker for Testcontainers** — `ubuntu-latest` ships a daemon; no provisioning step needed. Exactly one
  image is used, `postgres:14-alpine`, and I verified the pin holds: all 19 raw `new PostgreSQLContainer<>(…)`
  sites pass `AppPostgresDBContainer.IMAGE`, none hard-code a tag.
- **Dependency resolution needs no credentials** — every `<repository>` in `pom.xml` is public (repo1,
  jboss, sonatype, spring). `ci_settings.xml` exists but only carries a GitLab deploy-token header for the
  `gitlab-maven` *deploy* server; the workflow correctly does not pass `-s`.
- **`permissions:`** — absent, so the repo/org default applies. `actions/checkout` needs `contents: read`,
  which is present under either default setting, and `upload-artifact@v4` authenticates with the runtime
  token rather than `GITHUB_TOKEN`. No first-run failure. (See Low-5 for hygiene.)
- **Caching** — `cache: maven` on `setup-java@v4` is correct usage.

### Medium-2 — the 30-minute timeout has little headroom on a *private-repo* runner

The budget is derived from a "~4 minutes … one uncontended `mvn clean verify`" on a developer laptop. The
runner is not comparable:

- This repo is **private** (`gh api`: `{"plan":"Organization","private":true}`), so `ubuntu-latest` is the
  standard 2-vCPU / 7 GB / 14 GB runner — not the larger public-repo runner.
- The **first** run pays a cold Maven cache (`cache: maven` has nothing to restore yet) and a cold
  `postgres:14-alpine` pull.
- ~19 Postgres containers start sequentially (no `forkCount`/`parallel` configured, so surefire is
  single-fork), and `withReuse(true)` is a documented no-op without machine-level opt-in, which a fresh
  runner does not have.

A 4-minute laptop suite landing inside 30 minutes on 2 vCPU is plausible but not comfortable. The failure
mode is benign — the job fails, `build` is skipped, nothing bad deploys — but it blocks the dev deploy and
looks like a real regression. **Recommend starting at 45–60 and tightening once two or three real runs are
measured.** For calibration, existing develop runs (image build only) take 2m16s–3m13s; this change adds
the whole suite in front of that.

Related, Low: 7 GB RAM with Spring contexts plus a Postgres container and no `-Xmx`/`MAVEN_OPTS` is a
plausible OOM surface. Watch the first runs.

### Low-5 — `permissions:` not declared (hygiene, and inconsistent with the sibling)

`docker-image-uat.yml` declares `permissions: contents: write`; this workflow declares none and inherits
whatever the org default is. Not a defect, but an explicit `permissions: contents: read` on the `test` job
documents the intent and makes the workflow immune to a future org-level default change.

### Low-6 — `springdoc-openapi:generate` prints an alarming stack trace into every CI log

`pom.xml:649-661` binds `springdoc-openapi-maven-plugin:1.4:generate` to the **`integration-test`** phase in
the main `<build><plugins>` — not profile-gated, no `skip`, no `failOnError`. `mvn verify` therefore runs it,
and the goal expects a live app on `localhost:8080`.

I ran it with nothing listening:

```
[INFO] --- springdoc-openapi:1.4:generate (default-cli) @ wms-api ---
[ERROR] An error has occured
   <full ConnectException stack trace>
[INFO] BUILD SUCCESS
MVN_EXIT=0
```

**Not a gate-breaker** — the plugin swallows the failure and the build succeeds. Flagged because every CI
log will now carry `[ERROR]` and a stack trace on a *green* run, which makes triaging a genuinely red run
harder and will cost someone an hour the first time they see it. Worth a one-line note in the workflow, or
a `<skip>` in the pom.

### Low-7 — javadoc runs in CI although every other build path skips it

`maven-javadoc-plugin`'s `attach-javadocs` execution binds the `jar` goal at the default `package` phase, so
`mvn clean verify` generates javadoc. Both the `Dockerfile` (`-Dmaven.javadoc.skip=true`) and
`.gitlab-ci.yml` (same flag) skip it; the new CI command does not. `-Xdoclint:none` is configured so it
should pass, but it adds minutes to a job whose timeout is already tight (Medium-2) and exercises a failure
surface no other path touches. CI does not consume the javadoc jar — **suggest adding
`-Dmaven.javadoc.skip=true` to the `mvn` line.**

### Low-8 — anonymous Docker Hub pulls are rate-limited

`postgres:14-alpine` is pulled anonymously from Docker Hub on shared Actions egress IPs, a known source of
intermittent `TOOMANYREQUESTS`. Would present as a random red suite and a blocked deploy. Mitigation if it
bites: authenticate the pull, or mirror the image into `hub.impactathleticsny.com` (already in use by this
workflow, with credentials already present).

## 7. Consistency with the sibling workflows

- **`docker-image-uat.yml` (release → UAT) and `docker-image.yml` (main → prod) stay ungated.** The added
  CLAUDE.md section states this explicitly and names the hotfix-direct-to-`main` bypass as "a known,
  accepted gap, not an oversight." That is a reasonable and honestly-stated position. Worth noting that
  `release` is reached by merging `develop` → `release` and nothing re-runs the suite there either, so a
  green `develop` is the only evidence carried forward to UAT and prod.
- **Duplicate workflow name** — the substantive inconsistency introduced. See Medium-1.
- **`permissions:`** — declared in uat, absent in the other two. See Low-5.
- The `build` job of this workflow is otherwise byte-identical to what it was (login, buildx, two webhooks);
  the diff adds only `needs:` and `if:` above it. Confirmed against `git show ed575fb3`.

### Low-9 — dangling cross-reference in the header comment

Line 15: *"The name is now inaccurate but deliberately unchanged: see the note on `name:`."* There is no note
on `name:` — line 16 is bare. The pointer is circular. Given Medium-1 recommends renaming anyway, both
should be resolved together.

---

## 8. Finding outside the listed scope — and the most consequential one

### High-1 — the PR check **cannot be made a required status check** on this repo's plan

Both relevant APIs refuse:

```
GET /repos/SiteBossInc/wms2-api/branches/develop/protection
 → 403 "Upgrade to GitHub Pro or make this repository public to enable this feature."
GET /repos/SiteBossInc/wms2-api/rulesets
 → 403 "Upgrade to GitHub Pro or make this repository public to enable this feature."
```

The repo is private and org-owned on a plan that offers **neither branch protection nor rulesets**. So:

- The `test` job **will** run on PRs into `develop` (Finding 3 — that part is real and correct).
- But it **cannot be marked required**, and GitHub will not block a merge on it. A human can merge a PR
  whose `test` job is red, or absent (Low-1), and nothing intervenes.

**What still holds:** the post-merge protection is genuine. The push run's `test` job fails → `build` is
skipped → no image, no registry push, no Portainer webhooks. **AC-1 is real.** The *deploy* is gated even
though the *branch* is not. The failure mode degrades to "develop goes red and silently stops deploying",
which is the right direction — but the only signal is the Actions tab or a notification email.

**Why this is High rather than informational:** the CLAUDE.md text this commit adds says the job "runs on
**pull requests into `develop`**, which is where you will normally see it." True as written, but a reader
will reasonably infer it *blocks* the merge. It does not, and on this plan it cannot. That inference is
precisely the "the build will catch it" false confidence this ticket exists to eliminate — reintroduced one
level up. **Fix in this PR: add one sentence to the CLAUDE.md section** saying the PR check is advisory,
that this repo's plan supports no required checks, and that a red `test` on a PR must be honoured by the
human merging.

---

## Severity summary

| Severity | Count | Items |
|---|---|---|
| **Critical** | **0** | *none found — stated explicitly* |
| **High** | 1 | High-1 PR check cannot be required; CLAUDE.md wording implies it blocks merges |
| **Medium** | 2 | Medium-1 duplicate workflow name / concurrency namespace · Medium-2 30-min timeout headroom on a 2-vCPU private runner |
| **Low** | 9 | Low-1 conflicted PRs run nothing · Low-2 "byte-for-byte" overstated · Low-3 all-zero summary ambiguous · Low-4 `set -u` theoretical · Low-5 no `permissions:` · Low-6 springdoc stack-trace noise · Low-7 javadoc not skipped · Low-8 Docker Hub rate limit · Low-9 dangling `name:` comment |

Questions 1, 2, 3 and 5 produced **no findings** — the mechanics are correct as written, and each was
confirmed against the primary doc source or by executing the code, not by trusting the file's comments.

---

## Verdict

**Safe to merge to `develop`: YES.**

The two load-bearing claims are true, and I verified both independently of the author's comments:

1. `needs: test` genuinely stops the image build, the registry push and both Portainer webhooks on
   failure, timeout and cancellation alike (`success()` is implicitly ANDed).
2. `pull_request` is evaluated from the merge ref, so this workflow **will** run on the PR that introduces
   it. The verification plan is valid — the opposite claim, which two web sources asserted, is wrong.

Nothing in this file can produce a deploy from a red suite. The worst realistic outcome is a *missing*
deploy, which is the correct direction to fail.

**Must change first: nothing.** No finding blocks the merge.

**Should change in this PR (all cheap):**
1. **High-1** — one sentence in the CLAUDE.md section stating the PR check is advisory and cannot be made
   required on this plan. This is the only finding that would otherwise leave a false belief in writing.
2. **Medium-2** — raise `timeout-minutes` to 45–60 until real runs are measured.
3. **Medium-1** — rename to `Docker Image CI (develop)`; resolves Low-9 at the same time.
4. **Low-7** — add `-Dmaven.javadoc.skip=true` to the `mvn` line, matching every other build path.
5. **Low-2** — reword the "byte-for-byte" comment on lines 27–30.

### The one assumption I did not certify

**I did not run the suite.** The commit asserts a green baseline at this commit (surefire 6330/0/0/6,
failsafe 352/0/0/70); I neither reproduced nor contradicted it, and deliberately avoided a `clean verify`
that would have wiped `target/` under sibling review lanes sharing this worktree. If the suite is *not*
green on the merge result, merging this halts every dev deploy until it is fixed.

**Recommended merge procedure**, which turns Finding 3 into the safeguard: open the PR into `develop` and
**let the `test` job run before merging**. Because `pull_request` checks out the merge ref, that run
exercises the suite against `develop` + this branch merged — the exact tree the post-merge push will build.
A green check there settles the one open assumption. Given High-1, honouring that check is a human
responsibility; GitHub will not enforce it on this plan.
