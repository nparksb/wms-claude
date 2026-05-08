---
title: "Tag & Scope Inventory"
type: index
status: active
scope: tag-inventory
updated: 2026-04-19
tags: [index, tags, vocabulary, vault]
---

# Tag & Scope Inventory

**Scope:** Every `scope:` value and `tag:` value in use across the vault, with canonical docs for each. Source of truth for Dataview queries that expect consistent metadata.

If a doc's `scope` or `tags` differ from the canonical values below, normalize the doc, not the index.

- 📘 Architecture — `3-Resources/architecture/`
- 📕 Workflows — `3-Resources/workflows/`
- 📗 Data dictionary — `3-Resources/data-dictionary/`
- 📔 Plans (active) — `1-Projects/wms{1,2}/plan/`
- 📒 Plans (archived) — `4-Archieves/wms{1,2}/plan/`
- 📓 Areas — `2-Areas/`
- 📙 Template — `9-System/templates/`

---

## 1. `type` — Document role

Canonical set. If you write a doc, pick **exactly one** from this list.

| Value | Canonical use | Primary docs |
|---|---|---|
| `architecture` | System / subsystem structural reference | All `3-Resources/architecture/wms2-*.md` |
| `workflow` | Code-grounded business-process walkthrough | All `3-Resources/workflows/wms{1,2}-*.md` |
| `data-dictionary` | Reference for names / values / columns / configs | All `3-Resources/data-dictionary/wms2-*.md` |
| `plan` | Transient fix / feature / debug plan | `1-Projects/wms{1,2}/plan/*`, `4-Archieves/wms{1,2}/plan/*` |
| `investigation` | Root-cause / analysis document | `4-Archieves/wms{1,2}/analysis/*` |
| `index` | MOC / lookup file (like this one) | `INDEX.md`, `_symptom-index.md`, `_tags.md`, every `README.md` under PARA folders |
| `adr` | Architecture Decision Record | `3-Resources/decisions/` (currently empty) |
| `runbook` | Operational runbook | `2-Areas/runbooks/` (currently empty) |
| `bug` / `design` / `migration` | Legacy types from imported docs | Do not use for new docs — normalize to one of the above |

**Deprecated / cleanup needed:** a few archived plans use `type: bug`, `type: design`, `type: migration`. Don't remove, just don't use in new work.

---

## 2. `scope` — Subject area

Canonical value list. Prefer these when authoring new docs. One scope per doc.

### 2.1 WMS subsystem scopes (v2-focused)

| `scope:` | Meaning | Canonical docs |
|---|---|---|
| `transactions` | `@Transactional` / TX manager / OSIV / locking | 📘 [wms2-transaction-osiv-boundary-map](3-Resources/architecture/wms2-transaction-osiv-boundary-map.md) |
| `state-machines` | Lifecycle states for entities | 📘 [wms2-state-machine-catalog](3-Resources/architecture/wms2-state-machine-catalog.md) |
| `multi-tenancy` | Tenant routing / datasource / Hikari pool | 📘 [wms2-tenant-routing-datasource-topology](3-Resources/architecture/wms2-tenant-routing-datasource-topology.md), 📗 [wms2-landlord-vs-tenant-entity-map](3-Resources/data-dictionary/wms2-landlord-vs-tenant-entity-map.md) |
| `scheduled-jobs` | Cron jobs / advisory locks / schedulers | 📘 [wms2-scheduled-jobs-catalog](3-Resources/architecture/wms2-scheduled-jobs-catalog.md) |
| `authorization` | Keycloak roles / Keycloak groups | 📘 [wms2-keycloak-role-matrix](3-Resources/architecture/wms2-keycloak-role-matrix.md) |
| `cross-cutting` | Cross-project request journey / E2E flow | 📘 [wms2-end-to-end-request-journey](3-Resources/architecture/wms2-end-to-end-request-journey.md) |
| `sysprops` | System-property catalog | 📗 [wms2-sysprop-catalog](3-Resources/data-dictionary/wms2-sysprop-catalog.md) |
| `domain-vocabulary` | Business / warehouse glossary | 📗 [wms2-domain-glossary](3-Resources/data-dictionary/wms2-domain-glossary.md) |

### 2.2 Workflow scopes (one per business process)

| `scope:` | Canonical doc |
|---|---|
| `picking` | 📕 [wms2-picking-workflow](3-Resources/workflows/wms2-picking-workflow.md) |
| `cancel-cascade` | 📕 [wms2-cancel-cascade-workflow](3-Resources/workflows/wms2-cancel-cascade-workflow.md) |
| `receiving-putaway` | 📕 [wms2-receiving-putaway-workflow](3-Resources/workflows/wms2-receiving-putaway-workflow.md) |
| `bol-truck-loading` | 📕 [wms2-bol-truck-loading-workflow](3-Resources/workflows/wms2-bol-truck-loading-workflow.md) |
| `club-run` | 📕 [wms2-club-run-workflow](3-Resources/workflows/wms2-club-run-workflow.md) |
| `replenish` (informal) | 📕 [wms2-replenish-workflow](3-Resources/workflows/wms2-replenish-workflow.md), 📕 [wms2-replenish-order-creation](3-Resources/workflows/wms2-replenish-order-creation.md), 📕 [wms2-multi-unitload-replenish](3-Resources/workflows/wms2-multi-unitload-replenish.md) |

### 2.3 Meta scopes (indexes and MOCs)

| `scope:` | Meaning | Canonical doc |
|---|---|---|
| `moc` | Map-of-content / folder README | Per-folder `README.md` |
| `symptom-lookup` | Master debug index | [_symptom-index.md](_symptom-index.md) |
| `tag-inventory` | This file | [_tags.md](_tags.md) |
| `archives` | Archive-folder MOC | [4-Archieves/README](4-Archieves/README.md) |
| `workflows` | Workflows-folder MOC | [3-Resources/workflows/README](3-Resources/workflows/README.md) |
| `wms1-planning` / `wms2-planning` | Per-version active-plans MOC | [1-Projects/wms1/plan/README](1-Projects/wms1/plan/README.md), [1-Projects/wms2/plan/README](1-Projects/wms2/plan/README.md) |
| `wms-v1-v2-sync` | Sync workflow | [2-Areas/wms-v1-v2-sync/README](2-Areas/wms-v1-v2-sync/README.md) |

### 2.4 Data-quality notes

A handful of imported / legacy docs have `scope: ""` (empty). Known offenders — fill in a canonical scope when you touch them:

- Various entries in `1-Projects/wms{1,2}/plan/*` and `4-Archieves/wms{1,2}/plan/*`.

Not actively harmful — Dataview queries on `scope = X` simply skip them.

---

## 3. `tags:` — Secondary classification

Tags are free-form lists; keep them short and reuse the canonical values below. Pick 3–6 per doc.

### 3.1 Project / version tags

| Tag | Use |
|---|---|
| `wms1` | Applies to v1 codebase |
| `wms2` | Applies to v2 codebase |
| `both` | Applies to both |

### 3.2 Document-role tags (mirror `type:`)

`architecture`, `workflow`, `data-dictionary`, `plan`, `investigation`, `index`, `moc`

### 3.3 Subject tags (mirror `scope:` where it makes sense)

`transactions`, `state-machine`, `multi-tenancy`, `cron`, `authorization`, `keycloak`, `roles`, `auth`, `osiv`, `concurrency`, `datasource`, `hikaricp`, `pgbouncer`, `advisory-lock`, `picking`, `cancel`, `cascade`, `bol`, `truck-loading`, `shipping`, `receiving`, `putaway`, `club-run`, `club-order`, `order-lifecycle`, `glossary`, `vocabulary`, `sysprop`, `configuration`, `frontend-backend`

### 3.4 Activity tags

| Tag | Use |
|---|---|
| `debug` | Root-cause / debugging analysis |
| `symptom` | Symptom-index entry |
| `scheduled-jobs` | Covers scheduled work (NB: prefer scope over tag for this one) |
| `entities` | Entity / table reference |

### 3.5 Technology tags (rare — prefer scope)

Avoid tagging things like `java`, `spring-boot` — the version namespace (`wms2`) already implies it. Exception: `pgbouncer`, `hikaricp`, `keycloak` are worth tagging when they specifically drive the doc.

---

## 4. Housekeeping queries

In Obsidian with Dataview, the queries below surface docs that violate the conventions in §1–§3:

### Missing `type`

```dataview
LIST file.path
FROM "" WHERE !type
```

### Missing `scope`

```dataview
LIST file.path
FROM "" WHERE !scope OR scope = ""
```

### Missing `last_verified`

```dataview
LIST file.path
FROM "1-Projects" OR "3-Resources" OR "2-Areas"
WHERE !last_verified
```

### `type:` outside the canonical set

```dataview
LIST type
FROM "" WHERE type AND !contains(
  list("architecture", "workflow", "data-dictionary", "plan", "investigation", "index", "adr", "runbook"),
  type)
```

---

## 5. How to use this file

- Before writing a new doc: skim §1, §2, §3 to pick canonical `type`, `scope`, and tags.
- After writing: run §4 queries; clean up violations.
- When you introduce a **new `scope`**, add it to §2 with its canonical doc.
- When you introduce a new `type:` value: don't — pick an existing one.

---

## 6. Verification log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-04-19 | `grep -h "^scope:" **/*.md`, `grep -h "^type:" **/*.md`, `grep -h "^version:" **/*.md` | 20 unique scopes, 11 unique types (3 deprecated), 4 versions | Shell audit of current sbdocs state |

**Re-verify every 90 days.** Next due: **2026-07-18**.
