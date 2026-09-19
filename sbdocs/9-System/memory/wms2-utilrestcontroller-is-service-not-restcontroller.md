---
name: wms2-utilrestcontroller-is-service-not-restcontroller
description: wms2 UtilRestController is annotated @Service, not @RestController — none of its 9 @RequestMapping endpoints route, so /rest/util/initDB and /initAdmin are both dead
metadata:
  type: reference
---

`v2/wms2-api/.../controller/rest/UtilRestController.java` is annotated **`@Service`**, has no class-level `@RequestMapping`, and is injected nowhere in `src/main`. `RequestMappingHandlerMapping.isHandler()` requires `@Controller` (or a type-level `@RequestMapping`), so **none of its 9 `@RequestMapping` methods are routed** — including `POST /rest/util/initDB` and `POST /rest/util/initAdmin`.

**Why this misleads:** the class is named `...RestController`, lives in the `controller/rest` package, and its methods carry `@RequestMapping` — so a call-graph or grep-based reachability check reports it as a live endpoint. It holds 138 `addFunctionToRole` calls and 4 `addFunctionToUser` calls, which is enough volume to look like the main provisioning path. It is not: fresh v2 DBs are seeded from `V2.2.00__base_v2_schema.sql`.

**How to apply:** before claiming any `UtilRestController` endpoint is live, check the class-level annotation. Already documented in archived plan `SBDEV-2222-rest-inbound-no-idempotency-contract.md:81-84` rows 16a–16d. Cost of missing it: an acceptance step that 404s and reads as a failed fix. Surfaced during [[sbdev-3005-role-function-composite-key-swap]] review.
