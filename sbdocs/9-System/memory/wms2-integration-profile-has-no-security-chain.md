---
name: wms2-integration-profile-has-no-security-chain
description: BaseIntegrationTest subclasses run with security OFF — a MockMvc authz test there passes against an open endpoint; use a slim context importing SecurityConfiguration
metadata:
  type: feedback
---

The wms2-api `integration` test profile sets `rest.security.enabled=false` and excludes Boot's security auto-configs, so **no `BaseIntegrationTest` / `BaseControllerIntegrationTest` subclass runs any filter chain**. A path-authorization test written there returns 200 for every path. On SBDEV-3982 it got 200 with the fix in place, and `ClientControllerLegacyIntegrationTest`'s "swagger UI is served" check proves nothing about anonymity. The tell: the response carries no Spring Security headers (`X-Content-Type-Options`, `Cache-Control`).

A second trap in the same place: the test `application.properties` shadows main's and sets no `springdoc.*`, so the spec is served at `/v3/api-docs` under test, not at the production `/api-docs`.

**Why:** an authz test that cannot fail looks exactly like a passing one.

**How to apply:**
- To grade `SecurityConfiguration` rules, follow `LandlordAdminSecurityConfigurationTest` / `security/ApiDocsAccessContextTest`: use `@SpringJUnitWebConfig` + `@EnableWebMvc` + `@Import(SecurityConfiguration.class)`, mock its five collaborators plus an `ObjectMapper`, add a catch-all `@GetMapping("/**")` handler, then `springSecurity()` + `jwt()`.
- Include a positive control: an authorized call must get 200.
- Read config values such as paths from main's properties file, not the test one.

Related: [[hub-wms2-test-harness]], [[hub-wms2-authz]].
