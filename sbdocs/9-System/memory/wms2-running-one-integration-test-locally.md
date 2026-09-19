---
name: wms2-running-one-integration-test-locally
description: In wms2-api an *IntegrationTest/*IT class is NOT in the surefire lane, and -DfailIfNoTests=false is the wrong property — the combination produces a BUILD FAILURE that reads like a broken test
metadata:
  type: reference
---

Running a single `*IntegrationTest` / `*IT` / `*E2ETest` class in `v2/wms2-api`:

```bash
mvn -o verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false \
    -Dmaven.javadoc.skip=true -Dspringdoc.skip=true
```

Three traps, all measured 2026-09-09:

1. **`mvn test -Dtest=<AnyIntegrationTest>` can never work.** Surefire's config *excludes*
   `**/*IntegrationTest.java` and `**/*E2ETest.java`; failsafe *includes* those plus `**/*IT.java`.
   The class is simply not in the unit lane.
2. **`-DfailIfNoTests=false` is NOT surefire's property.** It is
   **`-Dsurefire.failIfNoSpecifiedTests=false`**. With the wrong one you get
   `No tests matching pattern "X" were executed!` and a **BUILD FAILURE** — which reads like a broken
   test rather than "wrong lane", and if you suppressed output you see only a bare non-zero exit.
   This is why the `-Dtest=ZzzNone` half needs the `surefire.`-prefixed flag to be tolerated.
3. **`mvn failsafe:integration-test -Dit.test=<Class>` LIES** — the pom says so: the standalone goal
   reports `Tests run: 0` + `BUILD SUCCESS` for *any* class, included or not, because it is a no-op
   outside the lifecycle. Always go through `verify`.

⚠️ `Tests run: 0` plus a non-zero exit is the signature of all three. Never read it as "the tests
passed" or "the class has no tests" — read the surefire/failsafe report file, or run without
suppressing output. Related: [[maven-it-test-exclusion-discards-includes]] (an exclusion-only
`-Dit.test` discards the pom `<includes>`; an inclusion-only one is safe),
[[mvn-without-clean-runs-deleted-tests]].
