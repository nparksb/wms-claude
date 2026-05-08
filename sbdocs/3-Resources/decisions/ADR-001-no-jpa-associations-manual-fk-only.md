---
type: decision
status: accepted
date: 2022-01-01
system: wms1+wms2
---
# ADR-001: No JPA Associations — Manual FK Relationships Only

## Status
Accepted

## Context
Both `wms-api` (v1) and `wms2-api` (v2) use Spring Data JPA with Hibernate. The domain model has ~67 entities (v1) and a comparable count in v2, with extensive inter-entity relationships. The standard JPA approach would be to map these with `@ManyToOne`, `@OneToMany`, and `@ManyToMany` annotations, letting Hibernate manage joins and lazy/eager loading.

This was rejected for this codebase. The pattern was discovered as a firm rule, documented as a critical constraint in both `v1/wms-api/CLAUDE.md` and `v2/wms2-api/CLAUDE.md`:

> "No JPA associations: All entity relationships use `Long foreignKeyId` fields. NEVER add `@ManyToOne`, `@OneToMany`, or other JPA association annotations. Fetch related entities manually via repository calls."

Evidence: `grep -rn "@ManyToOne\|@OneToMany\|@ManyToMany" .../wms-api/src/main/java/.../model/` returns **0 matches** in both v1 and v2 (5 hits in v2 are in test/utility code, not production entities). All entity relationships are represented as plain `Long foreignKeyId` fields.

## Decision
All inter-entity relationships in both v1 and v2 are expressed as `Long` FK ID fields on the owning entity. Related entities must be fetched manually via separate repository calls. No `@ManyToOne`, `@OneToMany`, `@ManyToMany`, or `@OneToOne` annotations are used on production entity classes.

## Rationale
JPA associations introduce a class of bugs that are hard to diagnose in a warehouse management system under load:

1. **N+1 query explosions.** Lazy `@OneToMany` collections trigger an additional SELECT per parent row unless explicitly JOIN FETCHed. In WMS batch operations (e.g., `CustomerorderBatchService` processing hundreds of orders), this silently degraded performance.
2. **Cascading delete/update surprises.** `CascadeType.ALL` or `CascadeType.REMOVE` on a collection can wipe child rows unexpectedly when a parent is merged or deleted. WMS data (stock units, unit loads, transfer orders) cannot tolerate silent cascades.
3. **OSIV-masked LazyInitializationException.** In v1, OSIV is on by default, so lazy associations load silently in the controller/view layer — masking the fact that the fetch happens outside a transaction. This bug class only surfaces when porting to v2 (where OSIV is disabled). See ADR-003.
4. **Schema coupling.** Hibernate association mappings encode schema topology in Java. When the physical schema diverges (e.g., via a Flyway migration that renames a column), Hibernate fails at startup or silently produces wrong joins. With plain Long IDs, the Java model is decoupled from schema shape.
5. **Explicit is safer.** Manual repository fetches are visible in the call graph. A developer reading a service method sees exactly which entities are loaded and when. There is no hidden join or lazy proxy.

## Consequences

**Positive:**
- No N+1 query risk from ORM-managed associations.
- No cascade surprises — deletes and updates are explicit.
- Entity classes are simple POJOs; no Hibernate proxy weirdness.
- Porting between v1 and v2 is straightforward — no `FetchType` mismatches to reconcile.
- ~270 `nativeQuery=true` annotations in v1 repositories (and ~171 in v2) work cleanly alongside this pattern; native SQL and plain ID fields are natural partners.

**Trade-offs:**
- Service-layer code is more verbose: loading a `CustomerOrder` with its `StockUnit` list requires two repository calls, not one.
- No Hibernate dirty-checking on relationships — the caller must explicitly call `save()` on all modified entities.
- Graph traversal (e.g., "give me all stock for this order") requires explicit orchestration in the service layer.

## Do NOT revisit unless
- The team adopts a full read-model / CQRS split where projections are generated separately from the command model, eliminating the need for manual in-service joins.
- A profiling exercise proves that explicit repository calls (not some other factor) are the performance bottleneck, and the team is prepared to audit all callers for N+1 and cascade safety.
- Spring Boot and Hibernate are upgraded to a version where Hibernate 6 `@BatchSize` or `@Fetch(FetchMode.SUBSELECT)` is thoroughly validated against the WMS load profile.
