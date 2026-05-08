---
title: "Data Dictionary Docs — MOC"
type: index
status: active
version: both
scope: data-dictionary
updated: 2026-04-27
tags: [moc, index, data-dictionary]
---

# Data Dictionary Docs — MOC

Reference tables for names, values, columns, and configuration constants in `v1/wms-api` and `v2/wms2-api`. Distinct from [architecture](../architecture/) (which is about code structure) and [workflows](../workflows/) (which is about user actions) — data-dictionary answers **"what does this value / term / key mean?"**

See also: [vault index](../../INDEX.md) · [architecture MOC](../architecture/README.md) · [landlord-vs-tenant map](./wms2-landlord-vs-tenant-entity-map.md)

---

## 1. Current docs

| Doc | Answers | Read when… |
|---|---|---|
| [wms1-sysprop-catalog.md](./wms1-sysprop-catalog.md) | All 106 v1 `SYSTEM_PROPERTY_*_KEY` constants — defaults, reading services, cron gates, OMS URL keys, Keycloak keys, printing/CUPS keys, barcode regex patterns | v1 sysprop appears in logs; enabling a v1 cron job; configuring v1 OMS callback URLs; v1 Keycloak setup; comparing v1 vs v2 sysprop coverage |
| [wms2-sysprop-catalog.md](./wms2-sysprop-catalog.md) | What is each v2 `sysprop` key, its default, and which service reads it? | Enabling a cron job for a new v2 tenant; configuring OMS callback URLs; Keycloak realm setup; sysprop appears in v2 logs |
| [wms2-landlord-vs-tenant-entity-map.md](./wms2-landlord-vs-tenant-entity-map.md) | Which entity lives in which DB? Which transaction manager covers it? | Adding `@Transactional` on a new service method; planning a schema migration; PgBouncer routing audit |
| [wms-domain-glossary.md](./wms-domain-glossary.md) | Unified v1+v2 glossary — 64 terms including v1-only states (PACKED=650, FUTURE_PICKING_DATE=80), entity prefixes (IBOL/OBOL/GRT/GRP), location types, unit-load types, Nirwana spelling trap | Reading WMS code for the first time; onboarding; disambiguating a term in a plan; v1-specific term not in v2 glossary |
| [wms2-domain-glossary.md](./wms2-domain-glossary.md) | v2-focused glossary — "tote" / "flowbin" / "staging lane" / `CANCELED` vs `CANCELLED` | v2-specific term lookup; cross-check against the unified glossary above |

---

## 2. Dataview — by type

```dataview
TABLE scope AS "Scope", version AS "Version", last_verified AS "Last verified"
FROM "3-Resources/data-dictionary"
WHERE type = "data-dictionary"
SORT last_verified DESC
```

---

## 3. Conventions

- **`type: data-dictionary`** — mandatory for new docs here.
- **`scope:`** — pick a canonical value from [_tags.md §2](../../_tags.md) (`sysprops`, `multi-tenancy`, `domain-vocabulary`, etc.).
- **`last_verified:`** — default cadence is **90 days** (vocabulary / reference data changes slowly).
- **Reference-style tables** over prose — the point of these docs is lookup speed.
- **Cross-link** to architecture / workflow docs that consume the values.

---

## 4. When NOT to add a doc here

- Per-column entity schema — too large to hand-author; auto-generate from `information_schema` if ever needed.
- One-off reference pulled from a single plan — keep it in the plan.
- Lists better served by the [function-to-docs map](../architecture/wms2-function-to-docs-map.md) — that's the meta-index.

Folder is intentionally small. Three docs cover the three lookup axes (config keys, entities, domain terms); more usually fragments rather than helps.
