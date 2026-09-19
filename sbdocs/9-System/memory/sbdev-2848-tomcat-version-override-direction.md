---
name: sbdev-2848-tomcat-version-override-direction
description: "SBDEV-2848 — wms2-api pinned Tomcat 10.1.30 below the parent BOM; fixed by an UPWARD pin to 10.1.55 (PR #245). `tomcat.version` is a Boot hook, not inert"
metadata: 
  node_type: memory
  type: project
  originSessionId: 518ad76d-0650-4f08-b17a-74478c435d9d
  modified: 2026-08-30T13:22:07.880Z
---

**SBDEV-2848** — **MERGED to develop 2026-08-30 as `b2b6a339` (PR #245), status `on dev`.** Five of six
ACs ticked; **AC-5 (OMS↔WMS callback regression) is OUTSTANDING and owned by David Oppenheim** — that is
the only thing between this and Closed, so do not archive it.
`pom.xml` pinned `<tomcat.version>10.1.30</tomcat.version>` — inside CVE-2025-24813's range.

**`tomcat.version` is NOT an inert leftover.** `spring-boot-dependencies` declares it and interpolates
it across **six** `tomcat-*` artifacts in its own `dependencyManagement`, so a child override silently
wins. That is exactly how the downgrade happened. "Nothing references it, safe to delete" was my first
(wrong) safety argument; the correct one is *nothing in **this repo** interpolates it, and the parent's
value is a strict upgrade — verified with `dependency:tree`*.

**Direction is the whole rule.** An override **below** the parent is the bug. An override **above** it
is the supported way to take a Tomcat security release ahead of a Boot release — and the only lever
available, since **Boot 3.5 is end-of-OSS-line** (3.5.16 last; 4.0/4.1 are GA). A naive
"never override `tomcat.version`" comment would forbid the actual fix; I wrote one and review caught it.

**Falling back to the parent is not enough.** Boot 3.5.9 manages **10.1.50**, which closes this CVE but
still carried **13** further Tomcat advisories (OSV-verified) fixed across 10.1.52–10.1.55, including
*Digest authenticator authenticates any unknown user* and *Security constraints not correctly applied*.
Shipped **10.1.55**; Spring Boot stays 3.5.9. Clean suite 5767/0.

**Tomcat trivia that inverts the obvious guess:** the CVE-2025-24813 fix did **not** withdraw partial PUT
or its temp file. `executePartialPut` and `allowPartialPut=true` persist on 10.1.50+; the fix changed the
temp file's *name* from path-derived + `deleteOnExit()` to `createTempFile("put-part-", …)`, removing
attacker control of the path. A partial PUT at a writable container still returns **201 and writes**.
Also: three independent gates sit between a PUT and a file — servlet mapped, servlet `readonly=false`,
**and** a writable resource root (`DefaultServlet.isReadOnly()` is `readOnly || resources.isReadOnly()`,
and Boot's root is read-only). Only the first is expressible in `application.properties`.

**Left on the ticket, not actioned** (Nam: keep it narrow): `checkstyle` is **compile scope** and ships
~13 MB into the fat JAR, dragging `plexus-utils` (CVE), `reflections` and `javassist` onto the production
classpath; `jakarta.xml.ws-api` pinned 3.0.1 below the BOM's 4.0.2 (same defect shape); dead
`junit-bom`/`mockito-inline` pins; Dockerfile Jasypt uses `PBEWithMD5AndDES` + `ZeroSaltGenerator` (zero
salt ⇒ deterministic `ENC(...)`). **T3 FILED 2026-08-31 as SBDEV-3172** (Boot 3.5 end-of-line dependency currency; Nam approved).
Its sharpest item is spring-data-rest-core 4.5.7 CVE-2026-41728 — JSON-Patch access-control bypass on
the exact surface the FunctionGuard gating programme fences. ⚠ **3.5.16 does NOT close it**: several fix
releases (spring-framework 6.2.19, spring-security 6.5.11, spring-data-rest 4.5.12) sit past what 3.5.16
manages, so the route choice is 3.5.x-with-upward-overrides vs Boot 4.x.

⚠ **OSV artifact-coordinate trap, cost me a false "no advisories":** the Actuator auth-bypass CVEs
(CVE-2026-22731/-22733) are filed against **`spring-boot-starter-actuator`**, NOT `spring-boot-actuator`
— the latter returns 0 advisories. Query the STARTER. And 22731 is health-**group**-scoped, so it is
reachable here only because `management.endpoint.health.probes.enabled=true` implicitly creates
`liveness`/`readiness`; the CloudFoundry sibling 22733 is not reachable at all.

Jasypt: RESOLVED for v2 — removed entirely in **SBDEV-3174** / PR #249 (it was inert under Boot 3, not
merely unused). See [[sbdev-3174-jasypt-removed-from-v2]]. The `ZeroSaltGenerator` weakness remains real
in **v1**, which does use Jasypt.
See [[consolidate-tickets-dont-file-one-per-finding]].
