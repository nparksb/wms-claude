---
name: verify-spring-bean-changes-clean-compile-and-context-load
description: "For wms2-api/wms-api Spring changes, gate on `mvn clean compile` + a @SpringBootTest context-load test — unit/JDBC tests and incremental compile miss compile drift and DI wiring failures."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 6afcb85d-5884-4ebf-b8ac-a71f963a0ce1
---

When a change to v2/wms2-api (or v1/wms-api) touches a Spring bean — constructor params, a new `@Autowired`/injected dependency, a second constructor, a repository method return type consumed elsewhere — do NOT declare it done on unit tests alone.

Two deploy-blockers shipped to `develop` during SBDEV-2381 despite "all green":
1. A repository return-type drift (`Page<Object[]>` vs `Page<OrderBatchPageView>`) compiled locally only because Maven **incremental compilation** reused stale `target/`; `mvn clean compile` failed.
2. `OutboxDispatchService` got a 6-arg convenience constructor added alongside the 7-arg DI constructor (to avoid editing a unit test). Two public constructors with none `@Autowired` → Spring "No default constructor found" `UnsatisfiedDependencyException` at startup. Unit tests (direct `new`) and the outbox Testcontainers ITs (JDBC + Flyway, no Spring context) never exercised DI, so it only failed on the dev-server boot.

**Why:** wms2-api unit tests construct beans directly and many "ITs" hit the DB via JDBC without booting the app context. So they validate logic but not (a) a clean compile across all consumers or (b) Spring DI wiring.

**How to apply:**
- Run `mvn clean compile` (not incremental) before claiming a build is good.
- Run a full-context boot test for bean changes — `net.aim_ai.wms.smoke.OmsNotificationConfigContextLoadTest` extends `@SpringBootTest(classes = StartApplication.class)` and is the cheap canonical context-load smoke (~18s + Testcontainers). Add it to the verify script / completion gate for any DI-touching change.
- Prefer a single constructor (Spring uses a sole constructor with no annotation); never add a second constructor just to keep an old test compiling — update the test's `new X(...)` call instead.
- Be skeptical of "pre-existing unrelated IT failures": a context-load failure (e.g. a bad bean) cascades identically across every `@SpringBootTest`; check one such failure's root cause before dismissing the batch.

Related: [[feedback_plan_status_after_implementation]]
