# OWL — Project Skills Catalog

Skills in this folder are project-scoped helpers for the daily WMS workflow (bug fixes, features, v2 ports, investigations, architecture/design docs). They are loaded by Claude Code on session start and triggered either by keyword match against the `description` field or by an explicit `/skill-name` slash command.

## Skills

### `wms-triage`
**Runs first, for every WMS task.** Four-question triage probe (already fixed on `origin/develop`? does it reproduce? is the reported cause the real cause? is it one line?) then a tier verdict T0–T3, routed on execution risk rather than ClickUp priority.
- **Trigger:** any new WMS ticket, symptom, feature request, port, or investigation — including ones that look trivial
- **Output:** a five-line triage block as a ticket comment. Never a file
- **Also the single source of truth for:** the tier router and its escalation triggers, the five-item floor that never scales, the ticket-filing policy, and verify-script row hygiene. Every skill below defers here. Where one restates a rule (the executor's per-tier phase table, the feature skill's tier modifiers) it must agree with `wms-triage`, which is authoritative — fix the rule there first, then reconcile the restatement
- **NOT for:** doing the work. It routes and stops; at T0/T1 it hands off to the floor and you implement inline with no plan document

### `wms-bugfix-plan`
Produces a bug-fix plan from an error, stack trace, HTTP 500, or SBDEV ticket.
- **Trigger words:** stack trace, error log, `SBDEV-####`, StaleObjectStateException, optimistic lock, NullPointerException, "stuck", "cannot scan", workflow breakage names (putaway / picking / replenish / receiving / cycle count / palletize / truck loading / BOL / move stock)
- **Output:** `sbdocs/1-Projects/wms{1|2}/plan/<SBDEV-####-or-kebab-name>.md`
- **NOT for:** design / feature requests (→ `wms-feature-plan`); v1→v2 ports (→ `wms-v2-migrate`); diagnosis without a fix commitment (→ `wms-investigation-report`)

### `wms-feature-plan`
Produces an implementation plan for a new feature, enhancement, refactor, or architecture change.
- **Trigger words:** design, feature, enhancement, refactor, performance goal, configurable, system property, endpoint, caching, pooling, horizontal scaling
- **Output:** `sbdocs/1-Projects/wms{1|2}/plan/<descriptive-name>.md`
- **NOT for:** concrete errors (→ `wms-bugfix-plan`); v2 porting of an existing v1 plan (→ `wms-v2-migrate`)

### `wms-tdd-gate`
Bridges plan review and implementation. Reads a critic-approved plan, writes the minimum failing tests that encode its acceptance criteria, validates they fail for the right reason, and pauses for human approval before any production code is written.
- **Trigger:** runs automatically as the final phase of `wms-bugfix-plan` / `wms-feature-plan`; also `/wms-tdd-gate <path-to-plan-file>` standalone against an approved plan
- **Output:** new/updated test class(es) in `v{1|2}/wms-api/src/test/`, plus a baseline failure report
- **NOT for:** writing tests after implementation (that's just coverage); plans that have no §8 Acceptance section (complete the plan first)

### `wms-plan-executor`
Executes a reviewed plan to an open PR: ralph-loops the implementation until the TDD-gate tests and verify script are green, confirms every §0 site and §8 criterion in an independent `verifier` lane, runs code review and fixes EVERY finding including Low, audits doc drift, commits, opens the PR into `develop`, updates the plan doc, and moves the ClickUp ticket to `pr submitted`.
- **Trigger:** `/wms-plan-executor <plan-file | SBDEV-#### | "the plan we just wrote">` — or "implement plan X", "ship SBDEV-####"
- **Output:** production code + tests on a feature branch, a PR into `develop`, updated plan §Implementation Status, ClickUp status + comment
- **NOT for:** merging, deploying, applying Flyway to a tenant DB, or archiving the plan (→ `archive-plan` after merge); implementing a `draft` plan (get ralplan sign-off first)

### `wms-v2-migrate`
Ports an existing v1 plan into a v2-specific plan; flags already-done, still-needed, and new-in-v2 issues.
- **Trigger words:** "port to v2", "v1 → v2 applicability", "backport", "migrate", pointer to a v1 plan file in `sbdocs/*/wms1/plan/`
- **Output:** `sbdocs/1-Projects/wms2/plan/<same-base-name-as-v1>.md`
- **NOT for:** creating a fresh v1 plan (→ `wms-bugfix-plan` / `wms-feature-plan`); v2-only issues unrelated to a v1 plan (use the bug/feature skills directly)

### `wms-investigation-report`
Produces an evidence-based investigation report that ends in a verdict + confidence + recommendation — NOT an implementation plan.
- **Trigger words:** investigate, audit, diagnose, "is X actually a bug?", feasibility study, metric anomaly, connection pool saturation, reservation leak, OSIV impact, cross-DB reconciliation
- **Output:** `sbdocs/3-Resources/reports/<descriptive-name>.md`
- **NOT for:** tasks where fixing is already decided (→ a plan skill); operational recovery steps (→ runbook template)

### `wms-architecture-doc`
Produces a long-lived system-level architecture document (topology, layers, tech stack, integrations, cross-cutting concerns).
- **Trigger words:** "architecture doc", "onboarding doc", topology, deployment, layers, system diagram, cross-cutting concerns
- **Output:** `sbdocs/3-Resources/architecture/<scope>.v{1|2}.md`
- **NOT for:** class-level design (→ `wms-design-doc`); business process flows (→ workflow template); proposed changes (→ plan skills)

### `wms-design-doc`
Produces a module-level design document (public API, data model, state machines, key flows) for a specific service/package/feature.
- **Trigger words:** "design doc for X", class structure, data model, state machine, API contract, module-scope documentation
- **Output:** `sbdocs/3-Resources/design/<scope>.v{1|2}.md`
- **NOT for:** system-wide overview (→ `wms-architecture-doc`); user-facing workflows (→ workflow template)

## Documentation maintenance skills

These keep `sbdocs/` consistent as docs are added, renamed, archived. All four are **report-first** — they print a review before changing anything (and `broken-links` never changes anything).

### `verify-docs`
Audit sbdocs/ for drift against the code. Given a PR diff, a changed file list, or nothing, report which docs reference the changed code and whether their `last_verified` date has aged past the re-verify cadence.
- **Trigger words:** "verify docs", "check doc drift", "what docs need updating", "audit sbdocs", or after landing a non-trivial change to `v2/wms2-api` or `v1/wms-api`
- **Output:** structured drift report (implicated docs, overdue docs, no-coverage files, ranked recommendations); does NOT rewrite
- **NOT for:** writing docs (→ architecture / design / workflow doc skills); bumping `last_verified` dates (do manually)

### `refresh-moc`
Audit every folder-level README (MOC) in `sbdocs/` against the filesystem. Flags doc lists, inventory rows, and archive counts that have drifted.
- **Trigger words:** "refresh MOC", "audit READMEs", "check MOC drift", after landing a batch of new docs
- **Output:** drift report per README; applies minimal edits only if the user explicitly asks
- **NOT for:** restructuring READMEs or adding commentary for new docs (user decides row placement)

### `archive-plan`
Move a completed plan from `1-Projects/wms{1,2}/plan/` to `4-Archieves/wms{1,2}/plan/`. Flips frontmatter `status: active → archived`, removes the plan's row from the source README, bumps the count in the archive README.
- **Trigger words:** "archive plan X", "this plan is done", "move to archive"
- **Input:** plan filename or path
- **Output:** 4 coordinated operations (file move + frontmatter + 2 README edits); always confirms before executing
- **NOT for:** batch archival (one plan at a time); reviving an archived plan (manual reverse of the 4 steps)

### `broken-links`
Scan every markdown doc in `sbdocs/` for unresolvable `related:` frontmatter entries and broken inline `[text](relative-path)` links.
- **Trigger words:** "check broken links", "find broken cross-references", "audit link integrity", after renaming or moving docs
- **Output:** broken-link report grouped by source file with line numbers; NEVER modifies files
- **NOT for:** HTTP / external URL checks (use `lychee` or similar); checking fragment identifiers (`#section`)

## Activation

Skills load on Claude Code startup from this folder. If you add, rename, or edit `SKILL.md` files, restart Claude Code to pick up the changes.

## Conventions for writing new skills

- One folder per skill, named `<skill-name>/`. The skill file is always `SKILL.md`.
- Frontmatter: `name`, `description` (both required). Description must be specific enough for trigger-matching — include keywords a user would actually type.
- Reference existing templates rather than duplicating their structure inside the skill.
- Always include a "When NOT to use this skill" section that points to the correct alternative.
- Bake in the non-negotiable WMS technical context (v1 `Location.equals()` broken, v2 `tenantTransactionManager`, OSIV disabled, Jakarta namespace, etc.) — it saves review cycles later.

## Related

- Templates: `sbdocs/9-System/templates/` (see its `README.md`)
- PARA structure: `sbdocs/` root (1-Projects / 2-Areas / 3-Resources / 4-Archieves / 9-System)
- Project CLAUDE.md: repo root, plus per-sub-project `CLAUDE.md` files
