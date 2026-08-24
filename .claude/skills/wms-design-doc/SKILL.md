---
name: wms-design-doc
description: Produce a module-level design document for a specific WMS service, package, or feature area (e.g. PickingOrderMergeService, TenantDynamicRoutingDataSource, replenishment subsystem, tote handling, receiving pipeline). Use when the user wants class-level design, data model, state machines, or API contracts scoped to one module. Output is a long-lived design document at sbdocs/3-Resources/design/. Does NOT cover system-wide architecture (wms-architecture-doc) or business processes (wms-workflow-doc).
---

# WMS Design Document

Produces a module-level design document at `sbdocs/3-Resources/design/`. Audience: engineers about to modify or extend the module.

## Before you write — `wms-triage` owns two rules that apply here

You are not tiering a fix, so skip the router. Two things still bind, and they live in `wms-triage`, not here:

- **The floor's evidence rules.** Class lists, state machines and contracts are claims: ground each in a `file:line` (or a DB query for a data-model claim), and take one independent review pass. A design doc that was never checked against the code is what a future fix will trust and get wrong.
- **The ticket policy.** Reading a module closely surfaces defects. Route them through the policy — fix tooling/doc defects directly, widen an existing ticket sharing the code path, and file at most one new ticket, confirmed by Nam.

## Trigger

- "Design doc for PickingOrderMergeService / TenantDynamicRoutingDataSource / ReplenishGeneratorService …"
- "Document the class structure of …"
- "Data model for {replenishment | picking | receiving | cycle count} …"
- "State machine for {customer order | picking order | unit load} …"

Do NOT use for:
- System-level topology / layers → `wms-architecture-doc`
- Business workflows / user-facing flows → `wms-workflow-doc`
- Proposed changes → a plan skill (`wms-bugfix-plan`, `wms-feature-plan`)
- One-decision records → `wms-adr` template

## Scope detection

A design doc should fit in one engineer's head. Aim for:
- One Java package, or
- One service class plus its immediate collaborators, or
- One coherent feature (the code that implements it)

If the scope is bigger (e.g., "the whole picking subsystem"), split into multiple design docs linked from an architecture doc.

## Pre-investigation phase (specialist agents — run AFTER scope is confirmed, BEFORE analysis)

After the module scope is confirmed, route to one or more specialist agents to gather primary evidence before the author reads through the module. Their output is folded into §0 Module Inventory and the body sections — it does NOT replace the analysis protocol below.

**Routing table — invoke when ANY trigger matches:**

| Agent | Invoke when | What to ask for |
|---|---|---|
| `architect` | Module has external collaborators, the class structure is not well-known, or the doc needs to accurately capture transaction / lock / tenant-routing semantics — applies to nearly every new design doc | File:line evidence for every class in scope and its immediate collaborators, transaction boundaries, pessimistic lock sites, entity FK structure — fold into §0 and §3–§6 |
| `analyst` | Module scope is ambiguous (overlaps with another module, unclear boundaries), or the user's intent is unclear (designing a NEW module vs documenting an EXISTING one) | Clarified scope, module boundary, what the doc must answer — fold into §1 Purpose and §8 Extension Points |
| `tracer` | The module has a known concurrency issue, a recurring `StaleObjectStateException` / lock race, or the design doc is being written specifically to diagnose or explain an incident | Ranked hypotheses for the concurrency failure mode, evidence for/against each — fold into §6 Concurrency Semantics and §11 Known Limitations |

**Skip pre-investigation when:**
- Module is small and already fully in-context (a single service class the author just read)
- The user has explicitly said "just write it"

**Fold findings into the doc:**
- `architect` findings → §0 Module Inventory (confirmed class list, entity list, public methods), §3 Key Classes, §4 Data Model, §6 Key Flows
- `analyst` findings → §1 Purpose (scope boundary, what is explicitly out of scope), §8 Extension Points
- `tracer` findings → §6 Concurrency Semantics (confirmed lock sites, known race conditions), §11 Known Limitations

## Analysis protocol

Do every step before drafting. A design doc built from memory always has wrong field names, wrong cardinalities, wrong state values.

1. **Read the module end-to-end.** Every class in the scope. Note inheritance, fields, methods, transactions, lock usage.
2. **Read the tests.** They reveal contract (what the module promises) and edge cases the code alone wouldn't tell you. Especially the `*ServiceUnitTest.java` files.
3. **Enumerate the data model.** For every entity the module reads or writes:
   - Table name, primary key, unique constraints
   - FK columns (`Unitload.storagelocationId`, `PickingorderPosition.pickingorderId`, …)
   - Enum-valued fields (state codes, types) with every valid value and meaning
   - v1/v2 difference if the entity model diverged
4. **Enumerate state transitions.** Only for entities with a `state` column. Table of From → Event → To → Guard → Side effects. Cite the code location that performs each transition.
5. **Enumerate public API.** Every method on the scope's services that is called from outside the module. For each: signature, transaction boundary, exceptions, HTTP status (if reachable from controller).
6. **Capture concurrency semantics.** Pessimistic locks used (`findByIdForUpdate`), transaction manager (`tenantTransactionManager` in v2), OSIV implications, optimistic-locking `@Version` fields, known race sites.
7. **Capture extension points.** Strategy interfaces, system properties, config toggles, event listeners. Anything someone adding a new feature would want to plug into.
8. **Note what is deliberately NOT supported.** Constraints are design, too. "No cross-tenant queries", "no bulk write above N rows", "no soft-delete on state PICKED" — make them explicit.

## Pre-draft enumeration (Layer 1 — code-grounding before drafting)

Before writing any section, produce a single Module-Inventory table by **enumeration, not memory**. A design doc written from memory always has wrong field names, wrong cardinalities, wrong state values; one driven by enumeration is grounded:

1. **List every class in scope** — `find src/main/java/.../<package>/ -name "*.java"` plus immediate collaborators reached by `@Autowired` / constructor injection.
2. **List every entity touched** — for each, capture: table name, primary key, FK columns, enum-valued fields with every valid value, `@Version` field if present.
3. **List every public method on the scope's services** — these define the module's contract.
4. **List every system-property / config toggle the module reads** — `WmsConstants.SYSTEM_PROPERTY_*_KEY` references, `LosSyspropService` calls.
5. **List every related design / architecture doc** in `sbdocs/3-Resources/` and `sbdocs/4-Archieves/`.
6. **List every test class** in `src/test/` that exercises the module — they reveal contract details the code alone won't.

Place this Module Inventory as §0 of the doc so reviewers can audit what was/wasn't covered. Every row must appear in the body or be explicitly out-of-scope.

## Completeness checklist (Layer 2 — gate before declaring the doc ready)

Walk every row. Mark `✓ <reference>` or `no — <rationale>`. Empty rows block sign-off.

| # | Concern | Considered? |
|---|---|---|
| 1 | All §0 inventory entries appear in the body, or excluded with rationale |  |
| 2 | Public API contract (§2) — every external caller method documented with tx boundary, exceptions, HTTP status if reachable |  |
| 3 | Data model (§4) — every entity's table name + PK + FKs + enum values |  |
| 4 | State machines (§5) — every stateful entity has a complete From/Event/To/Guard table |  |
| 5 | Concurrency semantics — pessimistic locks, optimistic-lock fields, OSIV implications, known race sites |  |
| 6 | Extension points — strategy interfaces, sysprops, listeners, anything pluggable |  |
| 7 | Deliberately-NOT-supported constraints — explicit "this is by design" list |  |
| 8 | Code-grounding — every method signature / state code / FK column cites file:line, no design fiction |  |
| 9 | v1/v2 deltas if module exists in both versions |  |
| 10 | Verification Log updated with `last_verified` and `verified_by` |  |
| 11 | Known-limitations entries that are expected to spawn plans note "downstream plan needs verify script" |  |

## Output document

Save to `sbdocs/3-Resources/design/<scope>.v{1|2}.md`. Use the template at `sbdocs/9-System/templates/wms-design-template.md`.

Required sections (in template order):
1. Purpose (what module does + what it deliberately does NOT do)
2. Public API / Contract
3. Key Classes / Services
4. Data Model (entities + relationships + enum values)
5. State Machines (per stateful entity)
6. Key Flows / Algorithms (with sequence diagrams)
7. Dependencies (internal + external)
8. Extension Points
9. Error Handling
10. Testing Approach
11. Known Limitations
12. Related ADRs & Docs
13. Verification Log

## Diagram discipline

- **Data model:** text tables plus a compact ASCII relationship sketch (e.g., `Customerorder 1 ─┬─ N Customerorderposition`). No UML tooling.
- **State machines:** tables are easier to diff than pictures. Columns: From | Event | To | Guard | Side effects.
- **Sequence diagrams:** ASCII only, one per non-trivial flow. Include the transaction boundary if it matters.
- Keep every diagram under ~25 lines. If longer, split into sub-flows.

## Non-negotiable WMS context

Apply to the module being documented:

**State codes (v1 + v2 — `WmsConstants.State`):**
- 100 NEW, 200 READY, 300 RELEASED, 400 STARTED, 500 FINISHED, 600 PICKED, 700 FINISHED, 800 CANCELED (confirm the actual constants when drafting — state-code conventions vary by entity family)
- Always quote the constant name AND the numeric value.

**Transactions (v2):**
- `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` on every tenant write method.
- Pessimistic locks require the caller to be transactional — a lock without a tx is silently released on auto-commit.
- OSIV disabled means an entity loaded in one method should not be re-used in another without re-loading or a shared `@Transactional` boundary.

**Entity idioms:**
- Do not document `.equals()`-based comparisons in v1. v1 idiom is `.getId().equals()`.
- v2 `AbstractBaseEntity.equals()` is ID-based — safe to use directly.
- Repositories often have both `findById` and `findByIdForUpdate` — flag which one each call site uses and why.

**Error handling:**
- Services throw `BusinessException` / `FacadeException`, caught at controller level.
- Never throw `NoSuchElementException` or `NullPointerException` to the client.
- For user-scoped not-found errors, include the identifier in the message.

**Testing idioms:**
- v1: Mockito 3.3.3 — no `mockStatic`. If the module has static collaborators, note the test-seam workaround used.
- v2: Testcontainers + PostgreSQL for integration tests. Unit tests use standard Mockito.
- Aim for the doc to tell a reader "how would I add a test for X?" — name the test class and the typical mock setup.

## Freshness contract

Same as architecture docs: set `last_verified` and `verified_by` on every update; status `draft` until re-verified after a major refactor.

## When uncertain

- Can't find a method's callers → grep harder (all modules + tests); if still zero, flag as potentially dead code in §11.
- State constants hard to track down → read `WmsConstants` and the entity class; quote the exact values.
- v1 vs v2 divergence is too big for one doc → split into two docs with matching base names and cross-link.
- Module behavior doesn't match the tests → don't paper over it; flag as a contradiction and open an investigation (use `wms-investigation-report`).

## Verification script — not produced here, required downstream

This skill produces a *long-lived design doc*, not an actionable plan, so no acceptance script ships with the design doc itself. **However:** when the design doc names a refactor opportunity, a missing test layer, or a planned API change in §11 (Known Limitations), the plan that captures that work MUST ship with a `sbdocs/9-System/scripts/verify-<plan-id>.sh` per `wms-bugfix-plan` / `wms-feature-plan` conventions. Note this expectation in §11 next to each entry that's expected to spawn a plan.
