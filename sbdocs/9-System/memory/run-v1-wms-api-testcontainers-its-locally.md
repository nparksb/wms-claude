---
name: run-v1-wms-api-testcontainers-its-locally
description: "How to run v1/wms-api Testcontainers ITs on this machine (Java 8, Maven path, Docker API override, Keycloak mock)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4914c296-92e0-499b-8e2e-bd58f265a0c5
---

Running `v1/wms-api` Testcontainers integration tests (`*IT.java`) locally on this machine requires four things the non-interactive shell does not provide by default:

1. **Java 8 + Maven on PATH** (project is Java 8; SDKMAN default is 21):
   `export JAVA_HOME=/home/nampark/.sdkman/candidates/java/8.0.412-tem`
   `export PATH=/home/nampark/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH`
2. **Docker API version override.** The daemon requires API ≥ 1.40, but Testcontainers 1.17.6 → docker-java-api 3.2.13 negotiates **1.32** and the daemon rejects it (`client version 1.32 is too old`). `DOCKER_API_VERSION` env is **ignored**; pass the `api.version` **system property to the forked surefire JVM**: `-DargLine="-Dapi.version=1.41"`. (User is in the `docker` group; socket is `/var/run/docker.sock`.)
   **Symptom seen 2026-08-27 (daemon API now 1.54):** the failure surfaces as `java.lang.IllegalStateException: Could not find a valid Docker environment` — NOT the older `client version 1.32 is too old`. It looks like a missing/denied Docker socket, so it is easy to misdiagnose as a sandbox or permissions problem: `docker ps` and `docker run hello-world` both succeed from the same shell, and disabling the tool sandbox changes nothing. The fix is unchanged — the `api.version` property must reach the **forked** test JVM via `argLine`; a bare `-Dapi.version=1.41` on the Maven command line does nothing.
3. **Skip javadoc + jacoco** for a clean `verify`: pre-existing Javadoc errors in `exceptions/FacadeException.java` break `maven-javadoc-plugin` (`attach-javadocs`). Use `-Dmaven.javadoc.skip=true`; add `-Djacoco.skip=true` if overriding `argLine` (jacoco sets `argLine`).
4. **Keycloak at startup.** A full `@SpringBootTest` boots `SecurityConfigurer.oauth2RestTemplate`, which eagerly calls `getAccessToken()` against `kc.dev.komatik.co` — unreachable offline, aborts context load (affects pre-existing ITs like `BoxtypeRepositoryIT` too). For repo/SQL ITs, add `@MockBean private OAuth2RestTemplate oauth2RestTemplate;` so the `@Bean` factory (and its network call) never runs.

5. **`sbdocs/9-System/scripts/verify-*.sh` that embed `mvn_test_passes`/`it_test_passes` rows must be run in a Java-8 shell too.** The grep checks pass regardless, but the embedded `mvn` calls run under whatever Java is active — under the SDKMAN default (21) every `T-*` mvn row spuriously FAILs (e.g. `25 pass, 6 fail` instead of `31 pass, 0 fail`). Export the item-1 Java 8 `JAVA_HOME`/`PATH` before `bash verify-….sh`. (Hit on SBDEV-2492.)

Full working invocation:
`mvn test -Dtest=SomeIT -DfailIfNoTests=false -Djacoco.skip=true -Dmaven.javadoc.skip=true -DargLine="-Dapi.version=1.41"`

These are environment quirks, not code defects; CI with a matching Docker daemon + Keycloak reachability needs none of the overrides. See [[verify-spring-bean-changes-clean-compile-and-context-load]].
