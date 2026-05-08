---
title: "Design Docs — MOC"
type: index
status: active
version: both
scope: design
updated: 2026-04-26
tags: [moc, index, design]
---

# Design Docs — MOC

Module-level design documents for the SiteBoss OWL / WMS platform. Where architecture docs cover cross-cutting structure, design docs cover a specific service, entity model, or API contract in depth.

See also: [vault index](../../INDEX.md) · [architecture](../architecture/) · [workflows](../workflows/)

---

## WMS v1

| Doc | Scope | Read when… |
|---|---|---|
| [wms1-stockunit-design.md](./wms1-stockunit-design.md) | `StockUnit` entity model — fields, state lifecycle, relationships to Unitload/Position | Editing stock quantity logic; tracing a stock discrepancy; understanding v1 inventory data model |

---

## WMS v2

| Doc | Scope | Read when… |
|---|---|---|
| [wms2-stockunit-design.md](./wms2-stockunit-design.md) | `StockUnit` entity model in v2 — fields, state lifecycle, relationships to Unitload/Position, v1↔v2 differences | Editing v2 stock quantity logic; tracing a v2 stock discrepancy; understanding v2 inventory data model |
| [wms2-replenishment-design.md](./wms2-replenishment-design.md) | Replenishment flow design — trigger conditions, state machine, `ReplenishmentorderService`, job integration | Editing replenishment logic; debugging stuck replenishment orders; planning changes to replenish triggers |

---

## Conventions

- **`type: design`** — mandatory on any new doc here.
- **`system:`** — `wms1` or `wms2` (or `both`).
- **`last_verified:`** — carry a verification date; default cadence 60 days.
- **Code-grounded claims only.** Cite file paths + line numbers for every structural assertion.
- Add a row in the appropriate version section above when landing a new doc.
