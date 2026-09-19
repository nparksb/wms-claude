---
name: wms2-actuator-info-build-time-identifies-the-deploy
description: "wms2-api /actuator/info now carries a build block — use build.time vs a merge timestamp to prove which build is deployed; build.version is permanently 0.1.0 and identifies nothing, and git-commit-id-maven-plugin would fail CI because the Docker build has no .git"
metadata: 
  node_type: memory
  type: project
  originSessionId: 6cb9776e-0d51-4b37-8a7e-cab8197878f9
  modified: 2026-09-01T18:55:47.269Z
---

**SBDEV-3185, merged `452d3ed4`, verified live on dev 2026-09-01.** `GET /actuator/info` on wms2-api is
**unauthenticated** (`SecurityConfiguration`: `/actuator/health/**` and `/actuator/info` are
`permitAll()`; everything else under `/actuator/**` needs `ADMIN`/`wms_admin`).

## How to prove which build is running

```bash
curl -s https://wms-api.dev.sbo.li/actuator/info
# {"build":{"group":"net.aim_ai","artifact":"wms-api","name":"wms-api",
#           "version":"0.1.0","time":"2026-09-01 18:51:03"}, "java":{...}}
```

**Compare `build.time` against the merge commit timestamp.** `develop` builds are linear, so
`build.time` later than the merge ⇒ the container contains it. Measured on the first real use: merge
18:50:35Z → CI start 18:50:38Z → `build.time` 18:51:03. Docker Image CI takes ~3 min.

⚠ **`build.version` is permanently `0.1.0` in EVERY environment** — no lane runs `versions:set`, and
`APP_VERSION` is a Docker build-arg that becomes container ENV, never a Maven property. It matches no
release tag on dev, UAT or prd. Reading it as a release number is wrong everywhere. Use `build.time`.

## 🔴 CHECK `/api/public/version` FIRST — it is cheaper and, on dev, exact

`GET /api/public/version` (added 2026-07-09 `f732a082` for the UI footer, `permitAll()` via
`/api/public/**`) already returns on dev:

```json
{"environment":"dev","self":{"repository":"wms2-api",
 "version":"develop-452d3ed45644ad041caad343296b5021cfe5bacf"},"drift":false}
```

— the **full git SHA**, unauthenticated, since July. I missed it and asserted that "which build is
deployed" was unanswerable from outside; that was false for dev, and it also invalidated a
SHA-*disclosure* argument I made (the SHA was already public). Corrected on SBDEV-3185.

**Which endpoint to use:**

| env | `/api/public/version` | what `build.time` adds |
|---|---|---|
| dev | `develop-<full sha>` — exact per deploy | little |
| UAT / prd | a **release tag** (`2.0.136`), not a commit | **which build of that release** is running |

So `build.time` earns its place on UAT/prd, where a release tag cannot distinguish two builds of the
same release. On dev, prefer `/api/public/version`.

## Why build identity matters at all

On a post-deploy probe a **PASS is self-certifying but a FAIL is ambiguous**: "the fix is broken" and
"the fix is not deployed yet" look identical from outside.

## The trap that was there before

`management.info.build.enabled=true` had been set in `application.properties` for some time while
`spring-boot-maven-plugin` was declared with **no `<executions>`** — so the goal never ran, no
`META-INF/build-info.properties` was generated, and the flag was completely **inert**. A config flag
claiming a capability whose input producer is missing. The same shape recurs one layer out: the
Dockerfile declares `ARG GIT_COMMIT` / `BUILD_DATE` / `PLATFORM_RELEASE`, exports all three as ENV with
a comment saying this is "what lets a running container report what it actually is" — and **nothing in
`src/` reads `GIT_COMMIT` or `BUILD_DATE`.**

## 🔴 If you ever add the git SHA — do NOT use git-commit-id-maven-plugin

The Dockerfile builds the jar **in-image** from `COPY pom.xml .` + `COPY src ./src`, with no
`.dockerignore`. **`.git` never reaches the build**, and the plugin's `failOnNoGitDirectory` defaults to
`true`, so it would fail every CI image build in all three environments.

The working route needs no plugin, because `management.info.env.enabled=true` is already on:

1. add `GIT_COMMIT=${{ github.sha }}` to **`docker-image-develop.yml`** — `docker-image-uat.yml` and
   `docker-image.yml` already pass it; develop is the only one that does not, so publishing the field
   first would read `unknown` on the one environment that asks the question;
2. then `info.git.commit=${GIT_COMMIT:unknown}` in `application.properties`.

`BuildInfoPublishedUnitTest` enforces that ORDER — it fails if `info.git.commit` is published while the
develop workflow still lacks the arg. It fences the **outcome**, not the plugin name, because a
name-based block misses the one-line env route entirely
([[a-guard-fences-the-mechanism-you-aimed-at]]).

⚠ `management.info.env.enabled=true` means **any** `info.*` property becomes public on this
unauthenticated endpoint. None exist today; the first one added is published by default rather than by
decision.

Related: [[sbdev-3176-sdr-cache-eviction]] (the deploy this could not verify),
[[wms2-ui-develop-tag-race-deploys-older-code]] (the prior "deployed artifact is not what you think"),
[[a-guard-fences-the-mechanism-you-aimed-at]], [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].
