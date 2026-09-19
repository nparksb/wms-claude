---
name: wms2-test-resources-shadows-main-application-properties
description: src/test/resources/application.properties SHADOWS src/main's in every wms2-api test lane, so no test can observe a change to a production-only property — @Value falls back to its inline default
metadata:
  type: reference
---

`wms2-api` has an `application.properties` in **both** `src/main/resources` and
`src/test/resources`. Same resource name, and `target/test-classes` precedes `target/classes` on the
test classpath, so **the test copy wins outright** — the production file is not merged, it is not
read at all. Any `@Value("${key:default}")` whose key lives only in the main file silently resolves
to its **inline default** in every lane.

**Why this is nastier than it sounds: the failure is invisible when the two values agree.** On
SBDEV-3250 a test asserted the tenant lock bound was `10s` and called it "the production value this
lane runs at". It was reading the `@Value` fallback. Both were `10000`. Mutating the production file
to `60000` left the suite **GREEN** — and the same trap fired a *second* time later in the same
ticket when I tried to mutation-check the fix and the mutant "survived".

**Two consequences worth internalising:**
- **A mutation of `src/main/resources/application.properties` reaches no test.** If a mutant there
  survives, suspect the harness before believing the survivor. Confirm the value actually reached the
  runtime (assert on the observed value, not on the file).
- **To pin a production property you must read the FILE**, e.g.
  `Properties.load(Files.newInputStream(Path.of("src/main/resources/application.properties")))` —
  precedent at `SchedulingReconcileIdempotencyUnitTest` and `TenantLockTimeoutPropertyUnitTest`. Guard
  it with a positive control (file exists, parses non-empty), or it passes vacuously against an empty
  `Properties`.
- To make a lane's value *testable*, declare it explicitly in that lane's profile file
  (`application-postgres-integration.properties`), not just in `src/main`.

Same shadowing note explains why `spring.jpa.properties.*` behaves oddly here — though that has a
second, independent cause: see [[wms2-tenant-persistence-unit-gets-no-jpa-properties]].

Related: [[green-tests-that-prove-nothing]], [[a-zero-scan-needs-a-positive-control]],
[[mutation-harness-traps]].

**Corollary measured 2026-09-09 (SBDEV-3285) — the shadowing also decides what an ABSENT
profile key resolves to, and the intuitive answer is wrong.** Removing a key from a
`application-<profile>.properties` does NOT fall through to the `@Value("${k:default}")` default. It
falls through to `src/test/resources/application.properties` first. Measured for
`spring.jpa.hibernate.ddl-auto` on the `postgres-integration` profile: key present → `validate`, key
**removed** → still `validate` (from the test base file, line 45), key set to `none` → `none`. The
`@Value` default (`none`, in `TenantDatabaseConfig`/`LandlordDatabaseConfig`) is unreachable in every
test lane.

So a test that says "without this key the lane silently falls back to the @Value default" is
asserting a false mechanism. **Do not reason about property precedence — observe it**, with a
property-sources-only context, which is cheap and needs no DB or Docker:

```java
new SpringApplicationBuilder(BareConfig.class).web(WebApplicationType.NONE)
    .profiles("postgres-integration").run();   // ~1s
// ctx.getEnvironment().getProperty(key)
```

Assert `getActiveProfiles()` contains the profile as a positive control, or the probe measures the
default property set and agrees for the wrong reason. This rung sits between a file-text pin and
asserting what Hibernate received (which does need Docker).
