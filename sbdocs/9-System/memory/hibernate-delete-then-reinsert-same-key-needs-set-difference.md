---
name: hibernate-delete-then-reinsert-same-key-needs-set-difference
description: "In wms2, delete-all-then-reinsert is never a safe \"make it atomic\" fix — Hibernate emits inserts before deletes, and most join-table repos have no flush()"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 06947b5e-b469-4ffe-99d7-c41704a80bab
  modified: 2026-08-19T20:24:43.743Z
---

Wrapping a `delete existing rows` → `insert new rows` endpoint in one transaction to make it atomic **introduces** a duplicate-key bug on the dominant path. Hibernate's `ActionQueue` executes in fixed order — orphan removals, **inserts**, updates, collection actions, **deletes last** — so a key that is both deleted and re-inserted in the same transaction has its INSERT emitted while the row is still present. Since these endpoints are normally used to *edit* a set (keeping most members), that is the common case, not an edge case.

Two wms2-specific traps make the obvious mitigations fail:

1. **`repo.flush()` often does not compile.** Many join-table repositories extend `PagingAndSortingRepository` + `CrudRepository` only — `flush()`/`saveAndFlush()`/`deleteAllInBatch()` live on `JpaRepository`. Example: `UserRoleUserFunctionRepository`. Widening the base interface is not free either: these carry `@RepositoryRestResource`, so inheritance changes the exposed Spring Data REST surface.
2. **`save()` is `merge()`, not `persist()`.** Join entities with an assigned `@EmbeddedId` and no `@Version` always have a non-null id, so Spring Data's `isNew()` is false. Merging an id whose persistence-context entry is already DELETED yields a `23505`, an `ObjectDeletedException`, or a silently dropped insert depending on the path.

**Fix: compute a set difference** — delete only what is dropped, insert only what is new, leave unchanged rows untouched. No ordering hazard to sequence around, no flush, no interface change, and it removes the wasted `merge()` SELECTs. Safe alternatives if delete-all must be kept: a `@Modifying @Query("DELETE …")` (immediate SQL, runs before any insert is queued), or widen to `JpaRepository` and `flush()` between the delete and the inserts.

**Also pin minimality with a test.** "An unchanged assignment is neither deleted nor re-inserted" needs its own assertion — otherwise a later "simplification" back to delete-all leaves the whole suite green. Related: [[sbdev-3005-role-function-composite-key-swap]], [[wms2-requires-new-in-lock-holding-tx-deadlock]] (same defect class: the naive fix still 23505s without an explicit flush).

**Watch for a second mapping of the same table.** `UserRole.functions` is a `@ManyToMany(fetch=EAGER) @JoinTable` over `mywms_role_mywms_function`, alongside the `UserRoleUserFunction` entity. Hibernate treats them as unrelated, so loading the owning entity inside a transaction that writes through the entity mapping can produce conflicting collection actions. Never load `UserRole` inside such a method.
