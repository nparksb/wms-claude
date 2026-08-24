---
name: wms-architecture-doc
description: Produce a system-level architecture document for a WMS subsystem or the whole v1 or v2 stack. Use when the user wants a topology / layers / tech-stack / integrations overview ("what are the boxes and wires", "onboarding doc for v2 picking", "deployment architecture of v1 wms-api", "cross-cutting concerns overview"). Output is a long-lived reference doc at sbdocs/3-Resources/architecture/. Does NOT cover module-level class design (use wms-design-doc) or business workflows (use wms-workflow-doc).
---

# WMS Architecture Document

Produces a long-lived system-level architecture document at `sbdocs/3-Resources/architecture/`. Audience: new engineers, ops, security, anyone who needs the "big picture" before touching code.

## Before you write — `wms-triage` owns two rules that apply here

You are not tiering a fix, so skip the router. Two things still bind, and they live in `wms-triage`, not here:

- **The floor's evidence rules.** Every non-obvious claim in an architecture doc needs the same grounding a fix needs — a `file:line` or a DB query, and one independent review pass. Docs asserting opposite things about the same subsystem (measured: two repo docs disagreed on v1 OSIV) come from claims that were never checked.
- **The ticket policy.** Documenting a subsystem surfaces defects. Route them through the policy — fix tooling/doc defects directly, widen an existing ticket on the same code path, and file at most one new ticket, confirmed by Nam. Do not open a ticket per drift you notice.

## Trigger

- "Write / update the architecture doc for {v1|v2|WMS API|picking|replenishment|auth|multi-tenancy}"
- "Onboarding doc for …"
- "Architectural overview of …"
- "Deployment topology of …"
- "System diagram of …"

Do NOT use this skill for:
- Module-level class design (data model, state machines, algorithms) → `wms-design-doc`
- Business-process / user flows → `wms-workflow-doc`
- Decision records → `wms-adr` template (no skill — just fill it in)

## Scope detection

First, clarify the scope with the user (or from their prompt):

| Scope | Example target |
|-------|---------------|
| Whole stack | "v1 wms-api architecture", "v2 wms2-api architecture" |
| Subsystem | "picking", "replenishment", "cycle count", "multi-tenancy", "auth" |
| Cross-cutting | "observability", "caching strategy", "error handling" |
| Cross-project | "OMS ↔ WMS interaction", "mobile UI → API flow" |

The smaller the scope, the deeper the doc goes. For whole-stack docs, keep each section concise and link out to subsystem docs.

## Pre-investigation phase (specialist agents — run AFTER scope is confirmed, BEFORE analysis)

After scope is confirmed, route to one or more specialist agents to gather primary evidence before the author starts reading files. Their output is folded into §0 Scope Inventory and the body sections — it does NOT replace the analysis protocol below.

**Routing table — invoke when ANY trigger matches:**

| Agent | Invoke when | What to ask for |
|---|---|---|
| `architect` | Scope spans ≥2 services or the topology is not well-documented yet — which is almost always for a new architecture doc | Current file:line evidence for each layer (entry points, integrations, cross-cutting concerns), what the code says vs what any existing doc says — fold into §0 and §4–§6 |
| `analyst` | Scope boundary is still ambiguous after the scope detection step, or the user's request implies two conflicting audiences (e.g., "onboarding doc" vs "deployment topology") | Clarified scope, target audience, what questions the doc must answer and what can be linked out — fold into §1 Overview framing |

**Skip pre-investigation when:**
- Scope is already a concrete, bounded subsystem the author has recently read (e.g., "update the scheduled-jobs catalog with the new job I just added")
- The user has explicitly said "just write it"

**Fold findings into the doc:**
- `architect` findings → §0 Scope Inventory (confirmed entry points, integrations, cross-cutting concerns with file:line), §4 Layered Architecture, §6 Integrations
- `analyst` findings → §1 Overview (audience + purpose framing), §12 Verification Log (scope decisions recorded)

## Analysis protocol

Do these BEFORE drafting. An architecture doc written from memory always gets details wrong.

1. **Read the sub-project CLAUDE.md for the target version.** It names the critical rules and idioms — those must be reflected in the doc.
2. **Inventory the tech stack by reading the build files.** v1: `pom.xml` for Java, `package.json` for Nuxt. v2: same plus Spring Boot parent version, React package.json. Record actual versions, not assumed versions.
3. **Map the topology by reading the entry points.** Controllers, main classes, `application.properties`, docker-compose, deployment manifests. Capture ports, protocols, auth.
4. **Walk the layers with a concrete example.** Pick one representative request (e.g., `GET /picking/orders`) and trace Controller → Service → Business → Repository → DB. Keep the trace — it becomes section 4 of the doc.
5. **Name real integrations.** Grep for `@FeignClient`, RestTemplate, Keycloak config, JMS/Kafka, external carrier SDKs, printer drivers. Never list integrations you didn't confirm in code.
6. **Capture cross-cutting concerns by configuration, not intent.** `@EnableCaching`, `@EnableTransactionManagement`, `ObjectPostProcessor`, `TenantDynamicRoutingDataSource`, logback config, actuator endpoints — this is what actually runs, not what "should" run.
7. **Non-functional numbers need a source.** Don't write "handles 10K req/s" unless there's a load test or SLO doc to cite. Otherwise mark "target" vs "measured".

## Pre-draft enumeration (Layer 1 — code-grounding before drafting)

Before writing any section, produce a single Scope-Inventory table by **enumeration, not memory**. An architecture doc written from a vague mental model has wrong details; one driven by an enumeration is grounded:

1. **List every entry-point class in scope** — controllers, main classes, scheduled job entry points. Capture file:line for each.
2. **List every external integration** — `grep -rn "@FeignClient\|httpRestService\|RestTemplate\|JmsTemplate"` plus Keycloak adapters, printer drivers, carrier SDKs. Confirm in code; never list integrations from memory.
3. **List every cross-cutting concern wired in scope** — `@EnableCaching`, `@EnableTransactionManagement`, `@EnableScheduling`, `TenantDynamicRoutingDataSource`, `ObjectPostProcessor`, actuator endpoints. Capture the configuration class.
4. **List every related architecture / design / ADR doc** in `sbdocs/3-Resources/` and `sbdocs/4-Archieves/`. The new doc cross-links rather than duplicates.
5. **Confirm exact versions** by reading `pom.xml` / `package.json` — never assume.

Place this Scope Inventory as §0 of the doc so reviewers can audit what was/wasn't covered. Every row must appear in the body or be explicitly out-of-scope with a link to the right doc.

## Completeness checklist (Layer 2 — gate before declaring the doc ready)

Walk every row. Mark `✓ <reference>` or `no — <rationale>`. Empty rows block sign-off.

| # | Concern | Considered? |
|---|---|---|
| 1 | All scope-inventory entries (§0) appear in the body, or excluded with rationale |  |
| 2 | All external integrations named with protocol + auth + direction (§6) |  |
| 3 | All cross-cutting concerns (caching, txn, security, observability) explicitly described |  |
| 4 | Cross-references to related docs in §11 Related ADRs |  |
| 5 | Code-grounding — every claim cites file:line or config-key, no design fiction |  |
| 6 | v1/v2 deltas explicit if doc spans both |  |
| 7 | Non-functional numbers cited with measurement method or marked "target vs measured" |  |
| 8 | Known limitations / tech debt explicit (so plans that follow can reference them) |  |
| 9 | Verification Log updated with `last_verified` and `verified_by` |  |
| 10 | Tech-debt entries that are expected to spawn plans note "downstream plan needs verify script" |  |

## Output document

Save to `sbdocs/3-Resources/architecture/<scope>.v{1|2}.md` (use `.overview.md` only when the v1/v2 deltas are the point of the doc). Use the template at `sbdocs/9-System/templates/wms-architecture-template.md`. Canonical references already in the repo: files under `sbdocs/3-Resources/architecture/` (entity reports, package analysis).

Required sections (in template order):
1. Overview (2–4 sentences)
2. Topology (ASCII box diagram)
3. Tech Stack (table with exact versions)
4. Layered Architecture (Controller → Service → Business → Repository → Data)
5. Key Components (table: Component | Responsibility | Representative file)
6. Integrations (table with protocols, auth, direction)
7. Deployment Topology
8. Cross-cutting Concerns (multi-tenancy, auth, caching, metrics/tracing, transactions)
9. Non-functional Characteristics (current vs target, with measurement method)
10. Known Limitations & Tech Debt
11. Related ADRs
12. Verification Log

## Non-negotiable WMS context

Include every item that applies to the doc's scope:

**v1/wms-api:**
- Java 8, Spring Boot 2.3.7, Maven, PostgreSQL, ports 8088 (dev) / 8080 (prod)
- Per-tenant datasource routing via `tenant_name` + `facility_code` HTTP headers → 4-char routing key
- Spring Security OAuth2 + per-tenant Keycloak JWT
- Jasypt `ENC(...)` encrypted properties
- OSIV disabled (`spring.jpa.open-in-view=false`) in deployed profile
- No JPA association annotations — manual FK relationships only
- `Location.equals()` compares coord+name (broken intentionally; never redesigned)
- Mockito 3.3.3 test stack (no `mockStatic`)
- Swagger UI at `/api/swagger-ui.html`

**v2/wms2-api:**
- Java 21, Spring Boot 3.5.9, Maven, PostgreSQL
- Same multi-tenant routing headers as v1; explicit `tenantTransactionManager`
- Jakarta namespace (persistence, servlet, validation)
- Caffeine caching + Micrometer metrics + Zipkin tracing
- Constructor injection throughout
- `AbstractBaseEntity.equals()` is ID-based
- SpringDoc UI at `/swagger-ui/index.html`
- Integration tests via Testcontainers + PostgreSQL

**Both versions:**
- Database-per-tenant; never assume cross-tenant reads
- OSIV disabled; every unannotated method splits into mini-sessions
- `RestExceptionHandler` catches `ApiInvalidParameterException` / `ApiConstraintViolationException` / `MethodArgumentNotValidException` / `ApiMissingUserException` / SSO
- Never commit `.env`, `auth.json`, `local.php`, `config.php`, `*_dev.properties`

## Diagram discipline

- ASCII box diagrams only (renders in both Obsidian and plain Markdown; no tooling dependency).
- One primary topology diagram at the top. If the doc is long, inline smaller diagrams per section.
- Boxes hold nouns (components). Arrows hold verbs (calls/events). Label every arrow with its protocol (HTTP, JDBC, JMS, etc.) and, if applicable, its direction-of-authority.
- Do NOT attempt class diagrams here — that's the design doc.

## Freshness contract

An architecture doc only helps if it's trustworthy. The template's "Verification Log" is the trust signal.

- On every update, set `last_verified` and `verified_by` (e.g., "code read 2026-04-17", "integration run 2026-04-17", "reviewed with owner 2026-04-17").
- When a doc is >6 months stale, flag it as `status: draft` until re-verified.
- Never silently edit stale sections; log the change in the Verification Log.

## When uncertain

- Scope too broad to analyze fully → ask the user to pick a subsystem; offer to draft an overview + link-out docs.
- Conflicting signals (code says X, CLAUDE.md says Y) → document the conflict in §10 and open an investigation (use `wms-investigation-report`) before deciding.
- Data this doc should contain lives in code comments / commit history / tribal knowledge → ask the user to source-of-truth it before drafting.

## Verification script — not produced here, required downstream

This skill produces a *long-lived reference doc*, not an actionable plan, so no acceptance script ships with the architecture doc itself. **However:** when this doc names a refactor target, a deprecation, or an upcoming change in §10 (Known Limitations & Tech Debt), the plan that captures that work MUST ship with a `sbdocs/9-System/scripts/verify-<plan-id>.sh` per `wms-bugfix-plan` / `wms-feature-plan` conventions. Note this expectation in §10 next to each tech-debt entry that's expected to spawn a plan.
