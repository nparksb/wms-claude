# SBDEV-3156 — review lane 2 (security)

**Lane:** lane-security (review lane 2 of 3)
**Change under review:** `3594108a` on `chore/SBDEV-3156-method-security-enablement-pin` (wms2-api)
**Review worktree:** `/tmp/claude-1000/review-3156-security` (detached at `3594108a`)
**Comparison worktree:** `/tmp/claude-1000/review-3156-main` (detached at `origin/main` = `55cf8952`)
**Date:** 2026-09-01
**Probe sources (reproducible):** `sbdocs/1-Projects/wms2/plan/SBDEV-3156-evidence/review-security-probes/`

Every finding is tagged **CONFIRMED BY EXECUTION** or **REASONED ONLY**. Every sentence containing
`every/only/all/no/none/exactly` names the instrument that derived it and that instrument's blind
spots inline.

---

## VERDICT

**This change weakens no authorization — on any branch, in any deployed environment.**
CONFIRMED BY EXECUTION on two independently-compiled trees (`3594108a` and `origin/main`
`55cf8952`), by two instruments each, plus a runtime probe against the real spring-security 6.5.7
on this project's classpath that measures the actual before/after decision for all five annotations.

The production blast radius is **one line in one file**. `git show --stat 3594108a` restricted to
`src/main` returns exactly one path: `src/main/java/net/aim_ai/wms/MethodSecurityConfig.java`, and
its only functional change is the attribute list on `@EnableMethodSecurity`. The other three changed
files are under `src/test`. CONFIRMED BY EXECUTION.

Three findings are worth acting on before merge — none of them is "this un-protects something
today", all three are "the safety argument the change makes for itself is weaker than stated":
**S1 (Medium)**, **S2 (Medium)**, **S3 (Low)**.

---

## (1) THE CENTRAL QUESTION — does anything lose protection?

### What the annotations actually did before the change

CONFIRMED BY EXECUTION — `Sbdev3156PermitAllDirectionProbe`, 4/4 green, real spring-security
6.5.7, `AnnotationConfigApplicationContext`, principal = authenticated with **zero** authorities
(the OMS integration principal's shape):

| annotation | `securedEnabled=true, jsr250Enabled=true` (BEFORE) | `false, false` (AFTER) |
|---|---|---|
| `@RolesAllowed("sb_admin")` | **DENIED** (`AuthorizationDeniedException`) | ALLOWED — **inert** |
| `@DenyAll` | **DENIED** | ALLOWED — **inert** |
| `@Secured("ROLE_sb_admin")` | **DENIED** | ALLOWED — **inert** |
| `@PreAuthorize("hasRole('sb_admin')")` | **DENIED** | **DENIED** — unchanged |
| `@PermitAll` | ALLOWED | ALLOWED — unchanged |
| unannotated | ALLOWED | ALLOWED — unchanged |

So the three de-armed annotations **were** real gates, and after the change they are genuinely
inert. The question is therefore purely: does any of them exist anywhere.

### Instrument 1 — source grep, per-ref, `src/main` only

`git grep -nE '@(Secured|RolesAllowed|DenyAll|PermitAll|PostAuthorize)\b' <ref> -- 'src/main/**/*.java'`

- `origin/main`: 0 files
- `origin/develop`: 0 files
- `origin/release`: 0 files
- `chore/SBDEV-3156-...`: 1 file — `MethodSecurityConfig.java`, all 8 hits inside the new block comment

A second pass with the **fully-qualified** spelling
(`annotation\.(Secured)|annotation\.security\.(RolesAllowed|DenyAll|PermitAll)`) returns 0 on all
three refs excluding that comment — this closes the escape recorded at
`FunctionGuardArchTest:355-357`, which the naive regex above would have missed.

A third pass swept **every** remote branch (`git branch -r`, 50+ refs, loop over
`git grep -l ... -- 'src/main/**/*.java'`): printed nothing, i.e. no branch in the remote carries
any of the five in `src/main`.

**Blind spots of instrument 1, stated:** it is text, so it cannot see (a) a meta-annotation arriving
from a jar, (b) an annotation inherited from a superclass outside `src/main`, (c) a non-Java source.
(c) is closed separately: `git ls-tree -r origin/develop -- src/main` filtered to non-`.java`
returns only `.sql/.sh/.md/.properties/.xml/.example` — there is no Kotlin/Groovy/Scala source under
`src/main`. (a) and (b) are closed by instruments 2 and 3.

### Instrument 2 — annotation-descriptor scan over compiled bytecode, with a positive control

`grep -ralF "<descriptor>" target/classes --include='*.class'`, over a fresh `mvn -o compile`.

| descriptor | `3594108a` (650 class files) | `origin/main` `55cf8952` (649) |
|---|---|---|
| `Lorg/springframework/security/access/prepost/PreAuthorize;` **(positive control)** | **4** | **4** |
| `Lorg/springframework/security/access/annotation/Secured;` | 0 | 0 |
| `Ljakarta/annotation/security/RolesAllowed;` | 0 | 0 |
| `Ljakarta/annotation/security/DenyAll;` | 0 | 0 |
| `Ljakarta/annotation/security/PermitAll;` | 0 | 0 |
| `Ljavax/annotation/security/{RolesAllowed,DenyAll,PermitAll};` | 0 / 0 / 0 | 0 / 0 / 0 |
| `Lorg/springframework/security/access/prepost/PostAuthorize;` | 0 | 0 |

The four `@PreAuthorize` carriers are `AdminController`, `AdminActionController`,
`ReplenishmentReconciliationController`, `PutawayConfigService` — verified individually. This
matches the commit message's "4 carrier classes", and the 13-vs-4 source/bytecode divergence it
mentions is explained: `PutawayConfigController` for instance has an **unused import** of
`@PreAuthorize` and no usage (`javap -v` on its class file shows only `RequiresFunction`
descriptors). I re-derived that independently rather than taking the commit's word for it.

> ⚠ **The positive control earned its keep, and this is worth recording.** My first run of this
> scan used `grep -rlF` without `-a`; GNU grep treated the class files as binary and returned **0
> for the positive control as well**. A reviewer reading only the seven zeros would have called it
> confirmation. Only `@PreAuthorize -> 0` exposed the broken instrument. Repeat with `-a`: control
> = 4, banned = 0. This is the exact "false green from a broken instrument" failure the repo's
> mutation-harness memory records.

### Instrument 3 — the rest of the deployed classpath (304 dependency jars)

`review-security-probes/jarscan.py` walks every `.class` entry in every jar on the full
(test-scope superset of runtime) classpath and reports any constant-pool mention of each descriptor.
Mention is a **superset** of "is annotated with", so a zero is conclusive; a non-zero needs a look.

Identical result on `3594108a` and on `origin/main`, 304 jars each:

- `@DenyAll` (jakarta and javax): **0** carriers, in any jar
- `@PermitAll` (jakarta and javax): **0** carriers, in any jar
- `@RolesAllowed` (jakarta): 3 — `spring-security-core`'s `Jsr250MethodSecurityMetadataSource` and
  `Jsr250AuthorizationManager$Jsr250AuthorizationManagerRegistry` (the **processors** these flags
  switch on), and `resteasy-core-6.2.9.Final`'s `RoleBasedSecurityFeature`, a JAX-RS feature that
  **reads** the annotation, arrives transitively via `keycloak-admin-client`, and is not a Spring
  bean. Independently verified by name; the commit's characterisation is accurate.
- `@RolesAllowed` (javax): 0
- `@Secured`: 2 — both `spring-security-core` processors.

**So no class anywhere on the deployed classpath — 650 own + 304 jars — is annotated with any of the
four.** That closes the meta-annotation and inheritance axes as well, because a composed annotation
is itself a class file that would have to carry the descriptor, and inheritance cannot conjure an
annotation that exists nowhere.

### Is the classpath I scanned the classpath that deploys?

Yes, and this matters for the completeness claim. CONFIRMED BY EXECUTION/inspection:
- `pom.xml` declares **0** `<module>` elements — single module, single artifact.
- `Dockerfile:43` copies exactly one jar (`COPY --from=build /app/target/${JAR_FILE}.jar app.jar`);
  `Dockerfile:47` is `java ... -jar app.jar` with no `-cp`, no loader path, no plugin directory, and
  the only other `COPY` into the runtime stage is a CA certificate.
- **Blind spot:** an operator mounting an extra jar into the container at runtime, or a
  `JAVA_TOOL_OPTIONS`/`-javaagent` set in Portainer, is outside anything I can see from the repo.

### Other axes the brief named

- **Superclass/interface inheritance, `AdminController` as base of ~43 controllers:** `AdminController`
  carries 11 `@PreAuthorize` sites and **zero** of the four (instrument 2: its class file's only
  security descriptor is `PreAuthorize`). No parent anywhere carries one, per instrument 3.
- **`landlord/`:** included in every instrument above — instrument 1 globs all of `src/main`,
  instrument 2 walks all of `target/classes` (34 landlord class files, counted). Not a separate root.
- **Scheduled jobs, event handlers, SDR handlers:** covered by the same whole-tree instruments. Zero.
- **A second `@EnableMethodSecurity` or a legacy `@EnableGlobalMethodSecurity` that could override
  this one:** `grep -rn 'EnableMethodSecurity|EnableGlobalMethodSecurity|GlobalMethodSecurityConfiguration'
  src/main` excluding `MethodSecurityConfig.java` returns nothing. Single enablement site.
- **`main` vs `develop`:** both carry `securedEnabled=true, jsr250Enabled=true` and both carry zero
  uses (instruments 1 and 2, on a fresh compile of each). This change removes machinery for
  annotations that do not exist on either branch.

### ⚠ S6 (Info) — a context line in the brief went stale DURING this review

The brief states the authz programme is "develop-only and NOT on prd". At my first check (~16:20)
`origin/main` was `cf430ff3` (2026-08-20, v2.0.128). A re-fetch at ~16:35 shows **`origin/main` =
`55cf8952`, "Release SiteBoss OWL v2.0.137 to production", committed 2026-09-01 16:27:54** — a
production release landed mid-review. `git cat-file -e origin/main:.../security/FunctionGuardInterceptor.java`
→ **PRESENT**. `git rev-list --count origin/main..origin/develop` → 22.

So the function-gating programme **is** on the production branch now, and
`wms2-authorization-programme-is-develop-only-not-on-prd` should be treated as superseded. It does
not change this verdict — I re-ran both instruments against a fresh compile of `55cf8952` and got
identical zeros — but any other lane reasoning from "not on prd" is reasoning from a stale premise.

---

## (2) THE INERT-ANNOTATION HAZARD

### S1 — Medium — the ban rule has two CONFIRMED detector bypasses, and it is the change's stated load-bearing half

`MethodSecurityConfig`'s new comment says it plainly:

```
 * ⚠ THIS IS HALF OF A PAIR. Turning these off is only safe because
 * MethodSecurityAnnotationSurfaceArchTest fails the build if @Secured, @RolesAllowed, @DenyAll or
 * @PermitAll appears anywhere in src/main.
```

The rule's detector is direct-only:

```java
// MethodSecurityAnnotationSurfaceArchTest.java
if (type.isAnnotatedWith(banned)) { ... }
if (method.isAnnotatedWith(banned)) { ... }
```

ArchUnit's `isAnnotatedWith` does not consider meta-annotations (`isMetaAnnotatedWith` is the
separate method), and the scan root is `net.aim_ai.wms`. Spring Security's lookup is strictly
stronger than both.

**CONFIRMED BY EXECUTION** — `Sbdev3156BanDetectorGapProbe`, 2/2 green. I planted a composed
annotation and a base class in `com.example.composed` (standing in for a jar, i.e. outside the scan
root):

```
### BAN-DETECTOR direct   -> [...DirectCarrier#x]      <- caught
### BAN-DETECTOR meta     -> []                        <- MISSED
### BAN-DETECTOR inherit  -> []                        <- MISSED
### SPRING(on)  meta-@RolesAllowed  -> DENIED(AuthorizationDeniedException)
### SPRING(on)  inherited-@DenyAll  -> DENIED(AuthorizationDeniedException)
### SPRING(off) meta-@RolesAllowed  -> ALLOWED(ran)
### SPRING(off) inherited-@DenyAll  -> ALLOWED(ran)
```

Read the last four lines together: Spring **honours** both shapes when the flags are on, and both
go **silently inert** when they are off — and the ban rule sees neither. That is precisely the
"written in good faith, reads exactly like a gate, enforces nothing" defect the change exists to
prevent, reachable through two doors the change leaves open.

**Exploit/breakage scenario.** A future ticket adds a dependency (or writes a shared annotation in
a companion library) exposing `@AdminOnly` meta-annotated with `@RolesAllowed("sb_admin")`, or a
base class with an `@DenyAll`'d method. A developer applies it to an identity-write route. The build
is green, the ArchUnit ban is green, the code review reads it as a gate — and the route is open to
every authenticated caller. Note that gating is *substitutable* in this repo, so the reviewer's
mental model would be "this route is gated"; nothing would contradict it.

**This is not live today.** Instrument 3 puts annotated classes on the whole classpath at zero, so
neither door is currently walked through. Severity is Medium because the change's own safety
argument is explicitly load-bearing on this rule, and because it is cheap to close.

**The fix already exists in this repo, in the sibling file the commit edited.**
`Sbdev3017TrancheGateContextTest.hasMethodSecurityGate` uses
`AnnotatedElementUtils.findMergedAnnotation(m, a)` / `(m.getDeclaringClass(), a)`.
**CONFIRMED BY EXECUTION** — `Sbdev3156StrongerDetectorProbe`:

```
### STRONG-DETECTOR meta     -> x:RolesAllowed
### STRONG-DETECTOR inherit  -> inheritedDenied:DenyAll
```

Both gaps close. Recommendation: either switch the ban's detector to
`AnnotatedElementUtils.findMergedAnnotation` over the reflective class set, or add
`isMetaAnnotatedWith` alongside `isAnnotatedWith` plus a hierarchy walk. The former reuses a
detector this repo has already vetted; the latter is more ArchUnit-idiomatic but needs the
hierarchy walk written by hand. I recommend the former, and recording in the javadoc's
"What this does NOT cover" list whichever residual remains.

### S2 — Medium — the ban never runs in any pipeline, so the "pair" is enforced by discipline, not by the build

The comment says the rule "fails the build". CONFIRMED BY inspection of every build path in the repo:

- `.gitlab-ci.yml:47` — `mvn package -s ci_settings.xml -DskipTests=true -D"checkstyle.skip" ...`
- `Dockerfile:10` — `RUN mvn clean package -DskipTests -Dmaven.javadoc.skip=true`
- `.github/workflows/docker-image-develop.yml` — the develop→dev deploy path — runs
  `actions/checkout`, `docker/login-action`, `docker/build-push-action` (which invokes the
  `Dockerfile` above), then two Portainer webhooks. **No `mvn test` step.** Its `pull_request`
  trigger is commented out.
- `docker-image-uat.yml` / `docker-image.yml` — same shape (version resolution + docker build/push).

So no automated pipeline on any branch ever executes `MethodSecurityAnnotationSurfaceArchTest` or
the two new flag pins. They fail only when a human or an agent runs `mvn test` locally. That is
consistent with `wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway` ("no CI on PRs"), so this is
a pre-existing repo property rather than something this change broke — but the change **newly
depends** on it for an authorization guarantee, which it did not before. Either soften the comment's
"fails the build" to say where it actually fails, or add a test step to the develop workflow.
**REASONED ONLY** for the consequence; **CONFIRMED** for the pipeline contents.

### Reverse hazard — does anything now become inert that a reader would believe is enforcing?

Two candidates, both benign, one worth a note:

- **`Sbdev3017TrancheGateContextTest.METHOD_SECURITY_GATES` (S7, Low, disclosed).** It still checks
  five annotations against the §0.C carve-out rows. Three of those five can no longer deny anything,
  so those three entries are now unfalsifiable in practice (and separately banned outright). The
  javadoc was rewritten in this very commit to say exactly that — "defence in depth, not current
  enforcement… Do not trim them to match the flags" — so it is disclosed rather than misleading, and
  keeping them is the right call for the re-enablement case. Noted only so a future reader does not
  mistake five checked annotations for five enforced ones. CONFIRMED: the test runs and passes
  (2/2 in the full suite, `net.aim_ai.wms.security.Sbdev3017TrancheGateContextTest`).
- **`MethodSecurityConfig` itself** now reads `securedEnabled = false, jsr250Enabled = false`
  explicitly rather than by omission. That is the right choice: a reader sees a decision, and the
  two pins make a silent flip impossible. No reverse hazard.

---

## (3) `@PermitAll` — could de-arming a PERMIT tighten anything? **No.** Cleared.

Two independent arguments, both confirmed.

**Mechanism.** `javap -c` on
`spring-security-config-6.5.7.jar!MethodSecuritySelector` shows the three flags select three
**separate** `@Configuration` imports — `PrePostMethodSecurityConfiguration`,
`SecuredMethodSecurityConfiguration`, `Jsr250MethodSecurityConfiguration` — and `javap -p` on each
shows each holds its own `AuthorizationManagerBeforeMethodInterceptor` and registers it as its own
advisor bean. Three advisors in the same chain compose as **AND**: every one must allow. A
`@PermitAll` grant was therefore only ever consulted by the JSR-250 interceptor, and could never
override a `@PreAuthorize` denial. Removing that interceptor removes a *potential denial path* and
nothing else. CONFIRMED BY EXECUTION (bytecode inspection).

**Measurement.** `Sbdev3156PermitAllDirectionProbe.permitAllDirection` puts `@PermitAll` on a method
of a class carrying a class-level `@PreAuthorize("hasRole('sb_admin')")` — the only shape where a
permit could plausibly matter — and measures the verdict for a zero-authority principal in both
configurations:

```
### @PermitAll under class @PreAuthorize: BEFORE=DENIED:AuthorizationDeniedException  AFTER=DENIED:AuthorizationDeniedException
```

Identical. And `@PermitAll` standing alone is ALLOWED before and after (same row as `unannotated`).
De-arming the permit changes no decision in either direction.

**The OMS integration principal specifically.** The three §0.C carve-out routes
(`/v3/client/create`, `/v3/boxType/create`, `/v3/shipperId/create`) are documented as deliberately
ungated at `RestConfiguration.java:319-320` and `BoxTypeController.java:49`
(`// /boxType/create stays UNGATED on purpose - OMS is a live caller (sec 0.C).`). A grep of
`ClientController`, `BoxTypeController` and `ShipperIdController` for
`RolesAllowed|DenyAll|PermitAll|@Secured` returns **nothing**, and instrument 3 puts `@PermitAll`
carriers at **zero across all 304 jars and all 650 own classes**. Nothing on those routes relied on
a permit, so facility/catalog sync cannot break. **No production-only breakage.**

Blind spot on this item: I did not exercise the real OMS caller against a deployed environment; the
argument is mechanism + local runtime measurement + absence of the annotation, not a live dev probe.

---

## (4) Does the ban create a security-relevant FALSE ASSURANCE?

Mostly no — the non-vacuity guard is real and it bites. But it is a *size floor*, not a *coverage
assertion*, and that distinction is a Low finding.

**CONFIRMED BY EXECUTION** — `Sbdev3156ArchScanVacuityProbe`:

```
### ARCHSCAN main-only size = 650
### ARCHSCAN main+tests size = 2536
### ARCHSCAN tests-only size = 1886
### main-only scan leaked a test class? false
### wrong-root (controller subtree only) size = 68
### typo-root size = 0
```

- The guard is `hasSizeGreaterThan(400)` against an actual **650**. Margin 250.
- The two realistic vacuity shapes both red: a **typo'd root** → 0, a **narrowed root** → 68.
  Measured: no maxdepth-1 subpackage of `net.aim_ai.wms` exceeds **184** class files
  (`service` 184, `repo` 123, `model` 76, `json` 68, `controller` 68, `landlord` 34, remainder
  smaller), so no single-subtree root can satisfy `>400`. The guard genuinely defeats the M3 mutant.
- An **unbuilt `target/classes`** → main-only scan 0 → guard fires. Good.
- `DO_NOT_INCLUDE_TESTS` **works**, and I validated it the hard way rather than by reading: I
  planted live `@DenyAll`, `@RolesAllowed`, `@PermitAll` and `@Secured` fixtures in
  `net.aim_ai.wms.reviewprobe` under `src/test`, then ran the ban rule. It stayed **green** (2/2),
  and the probe's own leak check reports `leaked a test class? false`, with main-only 650 exactly
  matching `find target/classes -name '*.class' | wc -l`. The javadoc's claim that the option is
  load-bearing is correct and now measured. Note the failure direction if it ever stopped working:
  the scan would become 2536 and the rule would red on fixtures — a false RED, not a false green.

### S3 — Low — the guard cannot detect a partial scan caused by a package move

`hasSizeGreaterThan(400)` with an actual 650 means **any subtree of up to 249 classes can leave
`net.aim_ai.wms` and the ban keeps passing while never looking at it.** `landlord/` is **34** class
files (counted) — comfortably inside that window, and it is the exact escape this repo already
recorded (`PublicHandlerContractArchTest`'s class javadoc, cited by the new test's own javadoc as
the reason the root is whole-tree). The new rule inherits the lesson about the *root* but not about
the *guard*: the guard proves the scan is big, not that it is complete.

Recommendation, cheap: assert a **landmark** is present rather than only a count — e.g. that the
imported set contains `net.aim_ai.wms.landlord.config.TenantFilter` and
`net.aim_ai.wms.controller.AdminController`. That converts a floor into a coverage assertion for the
one subtree with a recorded history of escaping. **REASONED ONLY** (I did not simulate a package
move; the 249-class window and the 34-class landlord size are both measured).

Two smaller items in the same area, both **cleared**, recorded so they are not re-raised:

- **Field/parameter gap: none.** `@Target` measured reflectively —
  `Secured = [METHOD, TYPE]` (`@Inherited=true`), `RolesAllowed/DenyAll/PermitAll = [TYPE, METHOD]`.
  None targets a field or parameter, so the rule's class + method + constructor iteration covers the
  whole legal surface (the constructor loop is harmlessly redundant). CONFIRMED BY EXECUTION.
- **Do the new tests actually run under surefire?** Yes. `pom.xml`'s surefire block declares
  `<excludes>` only (`**/*IntegrationTest.java`, `**/*E2ETest.java`) and no `<includes>`, so the
  default `**/*Test.java` pattern applies and both new classes match. CONFIRMED: the full-suite log
  contains `MethodSecurityAnnotationSurfaceArchTest` 2/2 and `MethodSecurityEnablementContractTest`
  18/18. This matters because `wms2-api-29-it-classes-run-in-neither-test-lane` records tests that
  silently run nowhere.

---

## (5) What the change should ALSO have done

1. **Close the two detector bypasses (S1).** Switch to `AnnotatedElementUtils.findMergedAnnotation`,
   or add `isMetaAnnotatedWith` + a hierarchy walk. The stronger detector is already in the sibling
   file this commit edited, so this is a copy, not a design.
2. **Stop claiming "fails the build" without saying which build (S2).** No pipeline runs the rule.
   Either add a test step to `.github/workflows/docker-image-develop.yml`, or reword the three
   javadoc/comment sites to "fails `mvn test`", so nobody merges believing an automated gate exists.
3. **Make the vacuity guard a coverage assertion, not a size floor (S3).** Landmark classes,
   including one from `landlord/`.
4. **Say something about the two unpinned attributes.** `@EnableMethodSecurity` has six attributes
   (`javap -p`): the three `*Enabled` booleans, plus `proxyTargetClass`, `mode`, `offset`. The
   commit pins three and is silent on the rest, and `mode` is the one that could de-arm the *live*
   `@PreAuthorize` mechanism. **I checked it and it is CLEARED** —
   `Sbdev3156ModeAttributeProbe`, CONFIRMED BY EXECUTION:

   ```
   ### MODE as-shipped      -> DENIED(AuthorizationDeniedException)  <-- gate live
   ### MODE ASPECTJ         -> CONTEXT FAILED TO START: BeanCreationException ... PrePostMethodSecurityConfiguration
   ### MODE proxyTargetClass-> DENIED(AuthorizationDeniedException)  <-- gate live
   ```

   `mode = AdviceMode.ASPECTJ` **fails the context to boot** on this classpath — fail-loud, not a
   silent de-arm — and `proxyTargetClass = true` leaves the gate live. So no pin is *required*.
   Blind spot worth one sentence in the javadoc: if `spring-security-aspects` is ever added to the
   classpath, ASPECTJ mode stops failing loudly and becomes exactly the silent-de-arm shape this
   ticket exists to prevent. A one-line note, not a fourth pin.
5. **Nothing else.** In particular I looked for and did **not** find: a missing `@PostAuthorize`
   consideration (correctly left live and unbanned, being part of the still-enabled prePost family),
   an SDR interaction (no `src/main` file other than `MethodSecurityConfig` is touched), or a
   Flyway/data dimension (none).

---

## S8 — out of scope, pre-existing, High — flagged because this is the security lane

`.github/workflows/docker-image-develop.yml:23` commits a plaintext container-registry credential:

```yaml
        username: impact
        password: t@8LHY8p&QmEDnBBetCPocTHupz$Mia3cHN#Pa
```

Not introduced by `3594108a` and unrelated to it. It sits alongside the already-recorded
`wms2-landlord-db-password-committed-live` (SBDEV-3175) and
`wms2-oms-api-credential-identical-dev-and-prd` (SBDEV-3181). Raising here only so it is not lost;
filing is Nam's call, and per the ticket policy a T3-shaped finding is proposed, never filed.

---

## Floor items

| item | result |
|---|---|
| full suite on the branch | `mvn -o clean test` → **6014 run, 0 failures, 0 errors, 67 skipped**, BUILD SUCCESS, 4m05s. CONFIRMED BY EXECUTION. Consistent with the recorded green baseline (5937/0 earlier; the count has been climbing daily). |
| new tests actually execute | `MethodSecurityAnnotationSurfaceArchTest` 2/2, `MethodSecurityEnablementContractTest` 18/18, `Sbdev3017TrancheGateContextTest` 2/2 — all present in the full-suite log. |
| independent review | this file. |
| two instruments on every count that drives a conclusion | done; where they could disagree they were made to (the `-a` incident under (1) is the one place an instrument was caught lying, and the positive control is what caught it). |
| DB verification | **not applicable and not performed** — this change touches no schema, no query and no data. There is no symptom row to confirm. |

---

## WHAT I DID NOT CHECK

- **Whether any `@PreAuthorize` or `@RequiresFunction` expression is correct.** Out of scope; the
  change does not touch one.
- **The SDR surface** (`SdrFunctionRules`, the `MappedInterceptor`) beyond confirming that
  `3594108a` changes no `src/main` file except `MethodSecurityConfig.java`.
- **Any live environment.** No dev/UAT/prd HTTP probe was run. All runtime evidence is
  local `AnnotationConfigApplicationContext` against the real spring-security 6.5.7 on this
  project's classpath.
- **The failsafe lane.** I ran `mvn test` only, not `mvn verify`. The `*IT` classes that
  `wms2-api-29-it-classes-run-in-neither-test-lane` records as running in neither lane were not
  exercised by me either.
- **A develop-side full-suite baseline for diffing.** The branch suite is green, which is what the
  floor requires; I did not run `origin/develop` to compare counts test-by-test.
- **v1/wms-api and both UIs.** Not in scope for a wms2-api method-security change, and neither uses
  `@EnableMethodSecurity`.
- **Runtime classpath mutation outside the repo** — an operator-mounted jar, a `-javaagent`, or a
  `JAVA_TOOL_OPTIONS` set in Portainer. My completeness claim about "the whole deployed classpath"
  is bounded by the `Dockerfile` and the Maven graph.
- **The 22 commits between `origin/main` and `origin/develop` individually.** I grepped
  `origin/develop`'s tree (0 uses), which covers their net effect, but I did not walk them one by one
  for a use that was added and then removed.
