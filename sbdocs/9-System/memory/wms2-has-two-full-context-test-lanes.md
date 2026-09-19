---
name: wms2-has-two-full-context-test-lanes
description: wms2-api has TWO @SpringBootTest lanes; only the Testcontainers one was ever broken, and SBDEV-3239 fixed only that
metadata:
  type: project
---

**wms2-api has two full-context `@SpringBootTest` lanes, and conflating them produces confident false
claims.** Established 2026-09-08 (SBDEV-3257), after I got it wrong twice.

| base class | profile | landlord URL from | broken? |
|---|---|---|---|
| `BasePostgresIntegrationTest` | `@ActiveProfiles("postgres-integration")` | `@DynamicPropertySource` → Testcontainers | **was** — SBDEV-3239 fixed it (`0984435e`, 2026-09-06) |
| `BaseRollbackIntegrationTest` | `@ActiveProfiles("integration")` | **its own `@TestPropertySource`** (`jdbc:h2:mem:rollback_landlord`) | never |
| `BaseControllerIntegrationTest` | `@SpringBootTest` + `@AutoConfigureMockMvc` | via `BaseIntegrationTest` (H2) | never — dates to `3d91c4ad` |

⚠ **`application-integration.properties:9` also declares `landlord.datasource.jdbc-url`, but
`BaseRollbackIntegrationTest` OVERRIDES it.** The profile file *is* loaded (its `pool-name=
LandlordTestPool` survives); the URL is not from it. Probe the resolved `Environment`, don't read the
properties file and assume.

**So:** a full-context MockMvc lane that *could* evaluate `@PreAuthorize` has existed since long
before SBDEV-3239 — `WebContextLaneContextTest` (`b9b138d4`, **2026-08-24**) exists to prove the web
context boots, 13 days earlier. Six classes extend `BaseControllerIntegrationTest`, none `@Disabled`,
two asserting a real 403. What is true is that **no controller test uses it for method security** —
that gap is a choice, not a broken lane. Never write "as of SBDEV-3239" about the web/MockMvc lane.

Anything crediting SBDEV-3239 for the **PostgreSQL** lane is correct: 22 classes extend
`BasePostgresIntegrationTest`, 20 enabled, and it migrates `classpath:db/migration`.

Related: [[wms2-test-suite-baseline-and-h2-verdict]],
[[fixing-a-false-claim-tends-to-produce-a-new-one]],
[[wms2-repository-tests-commit-they-do-not-roll-back]].
