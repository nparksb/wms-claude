---
title: "sbdocs — Map of Content"
type: index
status: active
updated: 2026-04-19
tags: [moc, index]
---

# sbdocs — Map of Content

Single jump-off point for the OWL documentation vault. Top half is **plain-markdown links** (works everywhere — Claude Code, grep, GitHub preview). Bottom half is **Dataview** (works in Obsidian with the Dataview plugin enabled).

Source of truth is always the file itself. If a query and the filesystem disagree, trust the filesystem and fix the file's frontmatter.

---

## 1. Quick Links (plain markdown)

### Active work — plans

- **WMS v1 plans** → [1-Projects/wms1/plan/](1-Projects/wms1/plan/)
- **WMS v2 plans** → [1-Projects/wms2/plan/](1-Projects/wms2/plan/)

### Ongoing areas

- **v1 → v2 sync** → [2-Areas/wms-v1-v2-sync/README.md](2-Areas/wms-v1-v2-sync/README.md) · [sync-log.md](2-Areas/wms-v1-v2-sync/sync-log.md) · [sweeps/](2-Areas/wms-v1-v2-sync/sweeps/)
- **Runbooks** → [2-Areas/runbooks/README.md](2-Areas/runbooks/README.md) (1 doc — MOC)

### Reference material

- **Architecture** → [3-Resources/architecture/README.md](3-Resources/architecture/README.md) (24 docs — MOC)
- **Workflows** → [3-Resources/workflows/README.md](3-Resources/workflows/README.md) (22 docs — MOC)
- **Data dictionary** → [3-Resources/data-dictionary/README.md](3-Resources/data-dictionary/README.md) (5 docs — MOC)
- **Design (module-level)** → [3-Resources/design/README.md](3-Resources/design/README.md) (3 docs — MOC)
- **ADRs / decisions** → [3-Resources/decisions/](3-Resources/decisions/)
- **Reports** → [3-Resources/reports/](3-Resources/reports/) *(2 imported reports)*

### Archives

- **WMS v1 — completed plans** → [4-Archieves/wms1/plan/](4-Archieves/wms1/plan/)
- **WMS v1 — closed investigations** → [4-Archieves/wms1/analysis/](4-Archieves/wms1/analysis/)
- **WMS v2 — completed plans** → [4-Archieves/wms2/plan/](4-Archieves/wms2/plan/)
- **WMS v2 — closed investigations** → [4-Archieves/wms2/analysis/](4-Archieves/wms2/analysis/)

### Templates & conventions

- **Plan template** → [9-System/templates/wms-plan-template.md](9-System/templates/wms-plan-template.md)
- **Frontmatter reference** → [9-System/templates/_frontmatter.md](9-System/templates/_frontmatter.md)
- **All templates** → [9-System/templates/](9-System/templates/)

### Search & lookup

- **Symptom Index** → [_symptom-index.md](_symptom-index.md) — every documented error/anomaly → canonical doc + section.
- **Tag & scope inventory** → [_tags.md](_tags.md) — canonical `type` / `scope` / `tags` values, with Dataview housekeeping queries.

---

## 2. Common Queries (Obsidian)

> Copy-paste ready. Replace the one highlighted token per query.

### Active plans for a version

```dataview
TABLE status AS "Status", priority AS "Priority", scope AS "Scope", updated AS "Updated", owner AS "Owner"
FROM "1-Projects"
WHERE type != "index" AND version = "v2"     /* change to "v1" or "both" */
SORT updated DESC
```

### All docs in a given scope

```dataview
TABLE type AS "Type", version AS "Version", status AS "Status", updated AS "Updated"
FROM ""
WHERE scope = "picking"                      /* change scope value */
SORT updated DESC
```

### Stale — not verified in 60+ days

```dataview
TABLE scope AS "Scope", version AS "Version", last_verified AS "Last verified"
FROM "3-Resources"
WHERE last_verified AND (date(today) - date(last_verified)) > dur(60 days)
SORT last_verified ASC
```

### Newest N docs (any folder)

```dataview
TABLE scope AS "Scope", type AS "Type", updated AS "Updated"
FROM ""
WHERE type AND type != "index"
SORT updated DESC
LIMIT 10
```

### Drafts (anywhere)

```dataview
LIST file.folder
FROM ""
WHERE status = "draft"
SORT file.mtime DESC
```

### Missing frontmatter (housekeeping)

See [_tags.md §4](_tags.md) for the authoritative housekeeping queries (`!type`, `!scope`, non-canonical `type`, etc.).

---

## 3. Dataview — Active Plans (Obsidian only)

> Requires the [Dataview](https://blacksmithgu.github.io/obsidian-dataview/) community plugin. If these blocks render as raw code, install/enable the plugin.

### Active WMS v1 plans

```dataview
TABLE
  status AS "Status",
  priority AS "Priority",
  scope AS "Scope",
  updated AS "Updated",
  owner AS "Owner"
FROM "1-Projects/wms1/plan"
WHERE status != "archived" AND status != "superseded"
SORT updated DESC
```

### Active WMS v2 plans

```dataview
TABLE
  status AS "Status",
  priority AS "Priority",
  scope AS "Scope",
  updated AS "Updated",
  owner AS "Owner"
FROM "1-Projects/wms2/plan"
WHERE status != "archived" AND status != "superseded"
SORT updated DESC
```

### Stale — not verified in 30+ days

```dataview
TABLE
  version AS "Version",
  scope AS "Scope",
  last_verified AS "Last Verified",
  status AS "Status"
FROM "1-Projects" OR "3-Resources"
WHERE last_verified AND (date(today) - date(last_verified)) > dur(30 days)
SORT last_verified ASC
```

### Drafts across the vault

```dataview
LIST
  "→ " + file.folder
FROM ""
WHERE status = "draft"
SORT file.mtime DESC
```

---

## 4. Dataview — Reference Material

### All architecture docs

```dataview
TABLE version AS "Version", scope AS "Scope", updated AS "Updated"
FROM "3-Resources/architecture"
SORT updated DESC
```

### All workflows

```dataview
TABLE version AS "Version", scope AS "Scope", updated AS "Updated"
FROM "3-Resources/workflows"
SORT file.name ASC
```

### All ADRs (by number)

```dataview
TABLE adr_number AS "ADR", status AS "Status", deciders AS "Deciders", updated AS "Updated"
FROM "3-Resources/decisions"
WHERE type = "adr"
SORT adr_number ASC
```

### Runbooks by severity

```dataview
TABLE severity AS "Severity", alert AS "Alert", escalation AS "Escalation"
FROM "2-Areas/runbooks"
WHERE type = "runbook"
SORT severity ASC
```

---

## 5. Dataview — Recently Archived

### Last 10 archived docs

```dataview
TABLE version AS "Version", scope AS "Scope", updated AS "Archived"
FROM "4-Archieves"
SORT updated DESC
LIMIT 10
```

---

## 6. Dataview — By Scope

Replace `picking` with any scope tag (`replenishment`, `putaway`, `cycle-count`, `palletizing`, `truck-loading`, `receiving`, `transfer`, `auth`, `multi-tenancy`, etc.).

```dataview
TABLE type AS "Type", version AS "Version", status AS "Status", updated AS "Updated"
FROM "1-Projects" OR "3-Resources" OR "2-Areas"
WHERE scope = "picking" OR contains(tags, "picking")
SORT updated DESC
```

---

## 7. Housekeeping Queries

### Missing frontmatter (no `type` set)

```dataview
LIST file.path
FROM "1-Projects" OR "3-Resources" OR "2-Areas"
WHERE !type
```

### Files with broken `related:` links

```dataview
LIST related
FROM ""
WHERE related AND length(related) > 0
FLATTEN related AS r
WHERE !(r = link(r))
```

---

## How to keep this file honest

- When a plan moves from `1-Projects/` to `4-Archieves/`, Dataview queries update automatically — no edit needed here.
- When you add a new **top-level category** (e.g. a new `3-Resources/` subfolder or a new `2-Areas/` workstream), add a link in Section 1.
- When you add a new `type:` or `status:` value, update [9-System/templates/_frontmatter.md](9-System/templates/_frontmatter.md) first, then this file.
