---
title: "Archives — Completed Plans & Closed Investigations"
type: index
status: active
version: both
scope: archives
updated: 2026-04-25
tags: [moc, index, archive]
---

# Archives — Completed Plans & Closed Investigations

Cold storage for finished WMS work. Active work lives in [../1-Projects/](../1-Projects/); this folder is **read-mostly** — new work rarely starts here, but ported v2 hot-fixes and post-mortems land directly here by design (see the [sync workflow hot-fix exception](../2-Areas/wms-v1-v2-sync/README.md#hot-fix-exception-procedure)).

See also: [vault index](../INDEX.md) · [plan template](../9-System/templates/wms-plan-template.md)

---

## Folder layout

| Folder | Contents | Live count |
|---|---|---|
| [wms1/plan/](wms1/plan/) | Completed v1 plans (fixes, feature ports, migrations, audits) | ~40 |
| [wms1/analysis/](wms1/analysis/) | Closed v1 investigations & root-cause reports | ~3 |
| [wms2/plan/](wms2/plan/) | Completed v2 plans (fixes, ports, refactors, performance) | ~64 |
| [wms2/analysis/](wms2/analysis/) | Closed v2 investigations | *(currently empty)* |

> Live counts are approximate — run `ls wms*/plan | wc -l` to refresh. Treat Dataview output below as authoritative in Obsidian.

---

## Dataview — recently archived (last 20)

```dataview
TABLE version AS "Version", type AS "Type", scope AS "Scope", updated AS "Archived"
FROM "4-Archieves"
WHERE type != "index"
SORT updated DESC
LIMIT 20
```

## Dataview — archived by scope

Useful when hunting for prior art on a subsystem (e.g. "has anyone fixed a stock-unit optimistic-lock bug before?").

```dataview
TABLE rows.file.link AS "Doc", rows.version AS "v"
FROM "4-Archieves"
WHERE type != "index" AND scope
GROUP BY scope
SORT scope ASC
```

## Dataview — v2 ports of v1 plans

```dataview
TABLE file.link AS "v2 plan", related AS "v1 source", updated AS "Archived"
FROM "4-Archieves/wms2/plan"
WHERE type != "index" AND related AND any(related, (r) => contains(string(r), "wms1"))
SORT updated DESC
```

## Dataview — investigations (root-cause analyses)

```dataview
TABLE version AS "Version", scope AS "Scope", updated AS "Closed"
FROM "4-Archieves/wms1/analysis" OR "4-Archieves/wms2/analysis"
WHERE type != "index"
SORT updated DESC
```

---

## How things land here

1. **Normal path** — a plan in `1-Projects/wms{1,2}/plan/` is completed and verified. Move (don't copy) the file into `4-Archieves/wms{1,2}/plan/`. Set `status: archived`. Bump `updated`.
2. **Hot-fix port** — when a v1 release-blocker is ported to v2 between sweeps, the port plan is authored **directly** in `4-Archieves/wms2/plan/` (example: `260418-v1-91e8732-move-stock-assigned-pickable-location-port.md`). It never passes through `1-Projects/` because it's already done by the time it's documented.
3. **Investigation close-out** — a root-cause analysis that is no longer actively used moves from `1-Projects/` (or wherever it was drafted) into `wms{1,2}/analysis/`.

## What NOT to do

- Do not delete archived files — they are the institutional memory for recurring bug classes (optimistic-lock storms, connection-pool exhaustion, staging-lane edge cases).
- Do not edit archived files in-place except to fix metadata (`status`, `related`, typos). If the work genuinely reopens, create a new plan in `1-Projects/` with a `related:` link back here.
- Do not put v1 plans under `wms2/` or vice-versa. The `version:` frontmatter field and the folder must agree.
