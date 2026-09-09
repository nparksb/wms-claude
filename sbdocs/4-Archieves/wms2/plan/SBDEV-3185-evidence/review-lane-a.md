# SBDEV-3185 — adversarial review (lane A)

- **Commit:** `4e1aefe7` "chore(build): SBDEV-3185 — generate build-info so the deployed build is identifiable"
- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/3185-review` (clean at `4e1aefe7` before and after; every mutation restored and verified by `git status`)
- **Reviewer:** cr-3185 · 2026-09-01
- **Tier:** T1 build-config change (2 files, +131 lines)

## Verdict

The change **works end to end** and the single highest-risk failure mode I went looking for — adding
`<executions>` silently cancelling the inherited `repackage` execution and shipping a non-executable
jar — **does not occur**. Both goals run and the fat jar is intact.

Findings on this commit: **0 High · 3 Medium · 5 Low.** Separately, one **pre-existing High** in files
this commit did not touch (§6) that I am not willing to leave unreported.

The Medium findings are all "the guard is narrower than the prose claims", not "the change is wrong".
Nothing here should block the merge; M1 and M2 are each a one-line fix in the idiom the test already uses.

---

## 1. Does it work end to end?

**Yes — verified, not assumed.**

```
[INFO] --- spring-boot:3.5.9:build-info (build-info) @ wms-api ---
[INFO] --- spring-boot:3.5.9:repackage (repackage)   @ wms-api ---
[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0 -- BuildInfoPublishedUnitTest
[INFO] BUILD SUCCESS
```

`target/classes/META-INF/build-info.properties`:

```properties
build.artifact=wms-api
build.group=net.aim_ai
build.name=wms-api
build.time=2026-09-01T18\:29\:40.431Z
build.version=0.1.0
```

**`repackage` was the real risk and it is clean.** The pom inherits
`spring-boot-starter-parent:3.5.9`, whose `pluginManagement` declares a `repackage` execution. Maven
merges plugin executions **by `<id>`**, so the new `<id>build-info</id>` is additive rather than
replacing the inherited one. Confirmed empirically, not from the docs: `mvn -o package -DskipTests`
emits both goal lines above and produces exactly one jar —

```
-rw-rw-r-- 1 nampark nampark 139600362 target/wms-api-0.1.0.jar
Main-Class:  org.springframework.boot.loader.launch.JarLauncher
Start-Class: net.aim_ai.wms.StartApplication
```

(Single jar, so no `unzip -l *.jar` multi-match false green.) The name also still matches the
Dockerfile's `ARG JAR_FILE=wms-api-0.1.0`, which all three GitHub workflows leave at its default.

**Placement inside the fat jar — worth stating because it looks wrong at first glance.** The artefact
lands at the **jar root**, `META-INF/build-info.properties`, *not* under `BOOT-INF/classes/`, where
`application.properties` goes. Boot's repackage keeps the root `META-INF/` at root (alongside
`MANIFEST.MF` and `spring-configuration-metadata.json`). I verified it is still resolvable on the
runtime classpath rather than trusting that it is — under `java -jar app.jar` the jar itself sits on
the system classloader, which is the parent of Boot's `LaunchedClassLoader`:

```
resolved = jar:file:.../wms-api-0.1.0.jar!/META-INF/build-info.properties
keys = {build.artifact=wms-api, build.group=net.aim_ai, build.name=wms-api,
        build.time=2026-09-01T18:31:50.237Z, build.version=0.1.0}
```

So `spring.info.build.location`'s default `classpath:META-INF/build-info.properties` resolves in the
deployed image. **Not a defect.**

### Is the stated limitation accurate?

The javadoc's core disclaimer is **accurate**:

> ⚠ This asserts the artefact, not the endpoint.

It is right that a booted `/actuator/info` cannot be asserted offline (SBDEV-2217). But the class
implies that the artefact is the *most* that can be checked offline, and that is not true — see **L1**,
where I ran the missing check and it works.

---

## 2. Side effects of binding a new goal into every build

**Clean on every axis I checked except the version semantics (M3).**

| Checked | Result |
|---|---|
| `project.build.outputTimestamp` set anywhere? | No — so `build.time` is a real instant, which is the point. Nothing pins it to a reproducible constant. |
| Anything hashing/diffing `target/classes`? | No. The only `checksum` hits are `backfill-flyway-history.sh`, computing CRC32 over migration **SQL** — unrelated to `target/`. |
| ArchUnit / resource-enumerating tests? | Clean. The two candidates (`LoggerAttributionUnitTest`, `TenantCacheKeyUnitTest`) use `ClassPathScanningCandidateComponentProvider`, which imports **classes**. A `.properties` file is invisible to it. |
| Runtime `classpath*:META-INF/**` scan in `src/main`? | None. |
| Three GitHub workflows | All three build via `Dockerfile`, whose stage 1 runs `mvn clean package -DskipTests`. `build-info` runs in each; `no-cache: true` everywhere, so a changing `build.time` cannot poison a layer cache. |
| `.gitlab-ci.yml` | Unaffected — but see **L6**, it appears already dead. |

---

## 3. Findings

### M1 (Medium) — AC-1 goes green over a **stale** artefact; the javadoc's claim is false for `mvn test`

The class states the regression it exists to catch:

> Deleting the pom execution again would restore the old silent no-op, and without this test nothing
> would notice.

**Demonstrated false.** I removed the `<execution>` block from `pom.xml` and ran the suite **without
`clean`**, leaving the previous build's artefact on disk:

```
### MUTANT A: execution removed, NO clean (stale artefact on disk) ###
[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

No `build-info (build-info)` goal line in that log — the goal genuinely did not run, and the test
passed anyway off `target/classes/META-INF/build-info.properties` left over from the prior build.
(pom restored; `git status` clean.)

The commit message's "Confirmed red before the pom change" is true **under `clean`**, which is
presumably how it was checked. CI is safe — the Dockerfile runs `mvn clean package`. But a developer
or a reviewer running `mvn test` locally gets a false green over exactly this regression, and this
repo already has a documented stale-`target/` trap of the same family.

**Fix — one line, in the idiom AC-4 already uses:**

```java
assertThat(java.nio.file.Files.readString(java.nio.file.Path.of("pom.xml")))
        .as("the spring-boot-maven-plugin build-info execution must stay declared — "
                + "without it AC-1 passes off a stale target/classes artefact")
        .contains("<goal>build-info</goal>");
```

This kills mutant A outright and does not depend on `clean`.

### M2 (Medium) — the git-SHA guard is a deny-list on one mechanism's *name*

```java
assertThat(java.nio.file.Files.readString(java.nio.file.Path.of("pom.xml")))
        .doesNotContain("git-commit-id");
```

This fences `git-commit-id-maven-plugin` and nothing else. The route most likely to actually be taken
sails straight past it: `management.info.env.enabled=true` is **already on**
(`application.properties:111`), so **any** `info.*` property is published by `EnvironmentInfoContributor`.
A future change of

```properties
info.git.commit=${GIT_COMMIT}
```

publishes the SHA on the permitAll endpoint and AC-4 stays **green** — and this is not hypothetical:
`GIT_COMMIT` is *already an environment variable inside the uat and prod containers* (`Dockerfile`
`ARG GIT_COMMIT` / `ENV GIT_COMMIT`, fed by `docker-image-uat.yml` and `docker-image.yml`
`GIT_COMMIT=${{ github.sha }}`). The ingredient is in place; only the one-line wiring is missing.
Two further uncovered routes: `management.info.git.enabled` plus a generated `git.properties`, and
`<additionalProperties>` inside the plugin's own execution (inside `pom.xml`, but containing no such
string).

**Fix:** replace the deny-list with the positive allow-list in **L1**, which pins the actual rendered
key set instead of one plugin's name.

### M3 (Medium) — `build.version` is permanently `0.1.0` in every deployed image

`pom.xml:11` is `<version>0.1.0</version>`, and **no lane changes it before the build that matters**:

- `Dockerfile` stage 1 runs `mvn clean package -DskipTests` against the pom as committed.
- All three GitHub workflows pass version identity as **Docker build-args** (`APP_VERSION`,
  `PLATFORM_RELEASE`, `GIT_COMMIT`, `BUILD_DATE`) which become **container ENV** — never Maven
  properties. They never reach the pom.
- The only `mvn versions:set -DnewVersion=${CI_COMMIT_TAG}` lives in `.gitlab-ci.yml`, which is dead
  (**L6**).

So `/actuator/info` will report `"version": "0.1.0"` on dev, uat **and** prod alike, matching no
release tag the team uses (`v0.0.22`, `rc-0.0.22`, `owl-v*`). Answering the team lead's question
directly: **`build.version` is not meaningful for identifying a deploy.** Only `build.time` is, which
is what the commit message actually relies on — so the feature meets its stated goal — but a version
field that is constant across all three environments is worse than absent, because an operator
reasonably reads it as the deployed version and it will never disagree with itself.

Also worth naming: the *meaningful* identity is **already inside every uat/prod container** as
`APP_VERSION`, `PLATFORM_RELEASE`, `GIT_COMMIT`, `BUILD_DATE`, and **nothing renders any of it**.
With `management.info.env.enabled=true` already on, `info.app.version=${APP_VERSION:unknown}` would
surface the real version. That is arguably the change that was wanted — but it is a scope increase
over a T1, it re-opens the disclosure question this commit deliberately settled (`APP_VERSION` on dev
is literally `develop-<full git sha>`), so it belongs on the ticket as a follow-up, **not** in this commit.

### L1 (Low) — a cheap offline check that *does* prove the rendering was missed

The class says the artefact is all it can assert. A meaningful part of the rendering path is offline-
testable, and every dependency is already on the test classpath. I **built and ran it** rather than
assuming:

```
details keys = [build]
build block  = {artifact=wms-api, name=wms-api, time=2026-09-01T18:31:50.237Z,
                version=0.1.0, group=net.aim_ai}
getTime()    = 2026-09-01T18:31:50.237Z
```

Roughly ten lines in the test, mirroring what `ProjectInfoAutoConfiguration` does (strip the `build.`
prefix, construct `BuildProperties`, run `BuildInfoContributor.contribute`). It proves three things
the current AC-1 does not:

1. `BuildProperties` can actually **parse** the generated file.
2. `BuildInfoContributor` emits a **`build` detail block** — i.e. the thing `/actuator/info` renders.
3. `getTime()` parses to a real `Instant`. `isNotBlank()` would not catch a malformed or
   format-changed timestamp; `build.time` is the one field the whole feature rests on.

And it subsumes **M2** far better than the deny-list does:

```java
assertThat(info.getDetails()).containsOnlyKeys("build");
assertThat((Map<?, ?>) info.get("build"))
        .containsOnlyKeys("group", "artifact", "name", "version", "time");
```

An allow-list over the **rendered output** catches a SHA arriving by *any* mechanism into the build
block, instead of catching one plugin by name.

### L2 (Low) — signpost the `management.info.env.enabled=true` footgun

`application.properties:111`. Latent, not live: I grepped and there are **no `info.*` properties
anywhere** in the repo today, so nothing is currently exposed. Leaving the setting alone is the right
call for a T1 — flipping it off could break a consumer, and it is also the mechanism someone would
legitimately use for M3's real version.

But this commit is precisely the one that turns `/actuator/info` into a surface people will start
adding to, and the next person to want a version there will reach for `info.app.version=...` without
knowing it lands on an unauthenticated endpoint. A one-line comment converts a latent footgun into a
signposted one at zero risk:

```properties
# ⚠ /actuator/info is permitAll() (SecurityConfiguration:146). With env.enabled=true, ANY
# info.* property added below becomes internet-visible. Nothing defines one today (SBDEV-3185).
management.info.env.enabled=true
```

### L3 (Low) — the SHA-exclusion *reasoning* is weak, though the decision is right

Stated rationale:

> it pins the running code to a specific commit while the authorization programme still has unclosed gaps

This does not survive much pressure. The repo is private, so an outsider cannot resolve a SHA to
source; and `management.info.java.enabled=true` already publishes the exact JRE version on the same
unauthenticated endpoint, which is a **far more actionable** fingerprint (it maps directly to known
JRE CVEs) than a commit hash. On its own the stated argument is closer to security theatre.

The **outcome** is still correct, and there is a better argument for it: a published SHA is a
*correlation key*, not just a fingerprint. Any clone of a private repo that leaks — an old fork, a
departed employee's checkout, a CI artefact — turns a public SHA into an exact source mapping for the
running build, permanently and retroactively. `build.time` gives the operational answer without that
property. Recommend keeping the exclusion and replacing the justification in the pom comment and the
test with that argument.

**Overall disclosure verdict: acceptable.** `group`/`artifact`/`name` are already inferable from any
error page or header, `version` is a constant (M3), and `time` is marginal next to the JRE version
already published. The change does not meaningfully widen the attack surface.

### L4 (Low) — `doesNotContain("git-commit-id")` can go red for the wrong reason

The assertion matches the raw text of `pom.xml`, including comments. It passes today (`grep -c
"git-commit-id" pom.xml` → `0`; the existing comment says "git commit SHA"). But anyone documenting
the exclusion by the plugin's actual name — the natural thing to write — turns the test red while the
behaviour is correct. If the deny-list survives M2/L1, match a structural token such as
`<artifactId>git-commit-id-maven-plugin</artifactId>` instead.

### L5 (Low, nit) — both path reads assume CWD == module basedir

`Path.of("src", "main", "resources", "application.properties")` and `Path.of("pom.xml")` are relative.
Correct under Surefire (working dir defaults to `${basedir}`, single-module repo) but they throw
`NoSuchFileException` under IDE run configurations that set a different working directory. This
matches the existing `SdrEvictionPostCommitAssumptionUnitTest` precedent, so it is consistent with the
codebase rather than a new problem. Noting only for completeness.

### L6 (Low, pre-existing) — `.gitlab-ci.yml` appears dead

Not touched by this commit, but it is load-bearing for the M3 analysis so it should be on the record.
It cannot currently work: `build_jar` uses `maven:3.9.4-eclipse-temurin-**11**` for a Java 21 project
(`<java.version>21</java.version>`), and `.build_image_template` passes
`JAR_FILE=wms-api-${CI_COMMIT_TAG}` while the Dockerfile's own stage 1 builds `wms-api-0.1.0.jar`, so
the `COPY --from=build /app/target/${JAR_FILE}.jar` cannot resolve. Recommend deleting it or filing
its removal, so the only `versions:set` in the repo stops implying that versions get stamped.

---

## 4. Test quality — could either test pass against a broken implementation?

- **AC-1:** yes, in one specific way — the stale-artefact path, **M1**, demonstrated.
- **AC-4:** yes for the disclosure half — **M2**, the deny-list is one-mechanism-wide. The two gating-
  property assertions are sound and genuinely load-bearing: without them AC-1 would be a green test
  over an artefact published nowhere, which the class correctly says.

### Classpath-vs-path reasoning — verified, and it holds

I checked this empirically rather than accepting the comment. `src/test/resources/application.properties`
exists and **is** copied over the deployed one on the test classpath:

```
target/classes/application.properties      : 1  occurrence of management.info.build.enabled
target/test-classes/application.properties : 0  occurrences
```

`target/test-classes` precedes `target/classes` on Surefire's classpath, so a
`getResourceAsStream("application.properties")` would load the **test** copy, `getProperty` would
return `null`, and AC-4 would fail against a correctly-configured deployment. **Reading by path is
required, and the comment is right.** The cited precedent is real —
`SdrEvictionPostCommitAssumptionUnitTest:45-52` does exactly the same thing for the same reason, with
a comment recording that an earlier classpath version of it failed.

Conversely `build-info.properties` is generated only into `target/classes` and has no
`src/test/resources` shadow (confirmed: `src/test/resources/` holds 6 entries, none of them
`META-INF/`), so the classpath read is correct there. **The split treatment is deliberate and correct,
and the class explains it well.**

---

## 5. Category summary

| Category | Verdict |
|---|---|
| Works end to end | **Clean.** Goal runs, `repackage` unaffected, artefact resolvable in the fat jar. |
| Reproducibility / build-time churn | **Clean.** Nothing hashes `target/classes`; no `outputTimestamp`. |
| CI interaction (3 GH workflows + Dockerfile) | **Clean** for the goal itself; version semantics broken (M3), GitLab lane dead (L6). |
| ArchUnit / classpath-walking tests | **Clean.** Class scanners cannot see a `.properties` file. |
| Disclosure | **Acceptable.** Reasoning weak (L3), footgun latent and worth signposting (L2). |
| Test honesty | Two demonstrated gaps: **M1**, **M2**. Classpath/path split **verified correct**. |

---

## 6. Out of scope, pre-existing — must not go unreported

**High — the container registry password is committed in plaintext**, in all three workflow files
(`docker-image-develop.yml`, `docker-image-uat.yml`, `docker-image.yml`):

```yaml
    - name: Log in to the Container registry
      uses: docker/login-action@v3.3.0
      with:
        registry: hub.impactathleticsny.com
        username: impact
        password: t@8LHY8p&QmEDnBBetCPocTHupz$Mia3cHN#Pa
```

Not introduced by `4e1aefe7` and not this ticket's business, but it is a live credential in git
history with push access to the registry that feeds dev, uat and prod. It needs rotating into
`secrets.*`, and rotation must assume the current value is already compromised. This is the same
class as the SBDEV-3175 landlord-password finding. Recommend filing separately.

---

## 7. Evidence

All commands run in `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/3185-review`, offline
(`mvn -o`), never concurrently with another Maven in the same worktree.

| # | Command | Result |
|---|---|---|
| 1 | `mvn -o clean test -Dtest=BuildInfoPublishedUnitTest` | 2/2 green; `build-info` goal ran |
| 2 | `cat target/classes/META-INF/build-info.properties` | 5 keys, no SHA |
| 3 | `mvn -o package -DskipTests` | `build-info` **and** `repackage` both ran; BUILD SUCCESS |
| 4 | `unzip -l target/wms-api-0.1.0.jar` | fat jar; `JarLauncher`; artefact at root `META-INF/` |
| 5 | `URLClassLoader` probe over the jar | root artefact **is** classpath-resolvable |
| 6 | Mutant A: execution removed, `mvn -o test` (no clean) | **SURVIVED** — 2/2 green (M1) |
| 7 | pom restored via backup copy | `git status` clean, `git diff` empty |
| 8 | `BuildInfoContributor` probe on real deps | rendered `build` block; `getTime()` parsed (L1) |
| 9 | `grep -c management.info.build.enabled` on both `target` copies | 1 vs 0 — shadow proven |
| 10 | `grep -rn "^info\."` across resources | none — env footgun latent, not live (L2) |

`mvn` is not on `PATH` in this environment; it lives at
`~/.sdkman/candidates/maven/current/bin`. The first run of command 1 exited **0 with
`mvn: command not found`** — a silent false pass. Worth remembering: bash's 127 records as an ordinary
success at the end of a `;`-chain.
