---
type: moc
---
# Architecture Decision Records — OWL WMS

This folder contains Architecture Decision Records (ADRs) for the OWL WMS monorepo (`wms-api` v1 and `wms2-api` v2). Each ADR documents a cross-cutting decision that is frequently questioned by new developers or re-litigated during bug fixes.

## Index

| ADR | Title | System | Status |
|---|---|---|---|
| [ADR-001](ADR-001-no-jpa-associations-manual-fk-only.md) | No JPA Associations — Manual FK Relationships Only | wms1+wms2 | Accepted |
| [ADR-002](ADR-002-deployment-per-tenant-v1-vs-in-process-routing-v2.md) | Deployment-Per-Tenant in v1 vs In-Process Routing in v2 | wms1+wms2 | Accepted |
| [ADR-003](ADR-003-osiv-enabled-v1-disabled-v2.md) | OSIV Enabled in v1, Disabled in v2 | wms1+wms2 | Accepted |
| [ADR-004](ADR-004-mixed-transactional-strategy-v1.md) | Mixed @Transactional Strategy in v1 | wms1 | Accepted |
| [ADR-005](ADR-005-native-sql-over-jpql.md) | Native SQL Queries Over JPQL | wms1+wms2 | Accepted |

## Quick Reference

**New developer onboarding — read in this order:**
1. ADR-001 (why there are no `@ManyToOne` annotations anywhere)
2. ADR-005 (why everything is `nativeQuery=true`)
3. ADR-002 (why v1 has no `TenantContext` and v2 does)
4. ADR-003 (why v2 throws `LazyInitializationException` on code that worked in v1)
5. ADR-004 (why some v1 services have no `@Transactional` and that's intentional)

**Bug fix entry points:**

| Symptom | Start here |
|---|---|
| `@ManyToOne` / `@OneToMany` added and causing N+1 or cascade issues | ADR-001 |
| v1 code works, v2 port throws `LazyInitializationException` | ADR-003 |
| v2 write goes to landlord DB instead of tenant DB | ADR-002, then `wms2-transaction-osiv-boundary-map.md` |
| v1 OMS notification silently not firing | ADR-004 |
| Schema migration broke a query at runtime (was fine at startup) | ADR-005 |
| v1 transaction committed when it should have rolled back | ADR-004 |

## Related Docs

- `architecture/wms1-tenant-routing-datasource-topology.md` — v1 datasource topology (ADR-002)
- `architecture/wms2-tenant-routing-datasource-topology.md` — v2 datasource topology (ADR-002)
- `architecture/wms1-transaction-boundary-map.md` — full v1 transaction map (ADR-004)
- `architecture/wms2-transaction-osiv-boundary-map.md` — v2 OSIV + dual-TM map (ADR-003)
- `architecture/wms1-vs-wms2-delta.md` — migration delta across all dimensions
