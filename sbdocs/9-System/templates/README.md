# sbdocs — Template Catalog

Templates in this folder define the required shape of each document type in the OWL documentation vault. Authors copy a template to its target folder, rename it, fill in the YAML frontmatter, and replace the placeholder sections.

All templates share the same frontmatter convention (see `_frontmatter.md`). Each template also adds a few type-specific fields.

## Templates

### `wms-plan-template.md`
Plan documents — **bug fixes**, **features**, and **v1→v2 migrations**. A single template serves all three plan types; the author omits sections that don't apply.
- **Used by skills:** `wms-bugfix-plan`, `wms-feature-plan`, `wms-v2-migrate`
- **Frontmatter extras:** `ticket`, `ticket_url`, `priority`, `project`, `requester`
- **Output folder:** `sbdocs/1-Projects/wms{1|2}/plan/` (move to `sbdocs/4-Archieves/wms{1|2}/plan/` when closed)
- **Canonical example:** `sbdocs/1-Projects/wms1/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md`

### `wms-architecture-template.md`
System-level architecture — topology, tech stack, layers, integrations, cross-cutting concerns, non-functional characteristics.
- **Used by skill:** `wms-architecture-doc`
- **Frontmatter extras:** none beyond shared
- **Output folder:** `sbdocs/3-Resources/architecture/`
- **Filename pattern:** `<scope>.v{1|2}.md` (e.g., `picking.v2.md`), or `<scope>.overview.md` when comparing v1/v2

### `wms-design-template.md`
Module-level design — purpose, public API, classes, data model, state machines, key flows, dependencies, extension points.
- **Used by skill:** `wms-design-doc`
- **Frontmatter extras:** none beyond shared
- **Output folder:** `sbdocs/3-Resources/design/`
- **Filename pattern:** `<scope>.v{1|2}.md`

### `wms-workflow-template.md`
Business process / workflow — actors, triggers, happy path, state transitions, edge cases, business rules.
- **Used by skill:** *(no dedicated skill — fill in manually)*
- **Frontmatter extras:** none beyond shared
- **Output folder:** `sbdocs/3-Resources/workflows/`
- **Canonical example:** existing files under `sbdocs/3-Resources/workflows/` (replenish, club orders)

### `wms-investigation-report-template.md`
Investigation report — context, questions, hypotheses with confidence, evidence, verdict, recommendation. Ends in a decision, NOT an implementation.
- **Used by skill:** `wms-investigation-report`
- **Frontmatter extras:** none beyond shared (status values: open / concluded / archived)
- **Output folder:** `sbdocs/3-Resources/reports/`
- **Canonical example:** `sbdocs/1-Projects/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md`, `sbdocs/4-Archieves/wms1/plan/260424-WMS_OSIV_Disabled_Audit.md`

### `wms-adr-template.md`
Architecture Decision Record — one-page, numbered (`ADR-XXXX`), IMMUTABLE once accepted. Captures Context / Decision / Consequences / Alternatives.
- **Used by skill:** *(no dedicated skill — fill in manually)*
- **Frontmatter extras:** `adr_number`, `deciders`, `supersedes`, `superseded_by`
- **Status lifecycle:** `proposed → accepted → superseded | deprecated`
- **Output folder:** `sbdocs/3-Resources/decisions/` (create if missing)
- **Filename pattern:** `ADR-0001-short-title.md`

### `wms-runbook-template.md`
Operational runbook / incident playbook — when-to-use, triage, diagnosis, recovery, escalation, verification.
- **Used by skill:** *(no dedicated skill — fill in manually after an incident)*
- **Frontmatter extras:** `alert`, `severity` (SEV1/SEV2/SEV3), `escalation`, `post_mortem_url`
- **Output folder:** `sbdocs/2-Areas/runbooks/` (create if missing)

### `wms-data-dictionary-template.md`
Per-table data dictionary — columns, enum values, keys, indexes, invariants, cross-DB relationships, diagnostic queries.
- **Used by skill:** *(no dedicated skill — per-table authoring is factual, not analytical)*
- **Frontmatter extras:** `database`, `schema`, `table`
- **Output folder:** `sbdocs/3-Resources/data-dictionary/` (create if missing)
- **Filename pattern:** `<database>.<schema>.<table>.md` (e.g., `postgres-wms-v2.public.customerorder.md`)
- **Especially useful for:** cross-system reconciliation work (MySQL OMS ↔ PostgreSQL WMS)

### `_frontmatter.md`
Reference fragment — documents the shared frontmatter fields and conventions. **Not a standalone document.** Open this file when unsure which fields are required or how `version` / `type` / `status` are expected to be formatted.

## Authoring workflow

1. Copy the template to the target folder.
2. Rename using the convention documented in the template's own "Filename pattern" note.
3. Fill in the frontmatter — all shared fields are required.
4. Replace placeholder sections (`<!-- ... -->`) with real content.
5. On first save, set `status: draft` and `last_verified` to today; update on each revision.

## Related

- Skills: `owl/.claude/skills/` (see its `README.md`)
- PARA structure: `sbdocs/` root (1-Projects / 2-Areas / 3-Resources / 4-Archieves / 9-System)
