---
name: wms2-sdr-association-resource-verb-reality
description: On /v3/userRole/{id}/functions PUT is the destructive verb, PATCH/POST are additive only, and collection DELETE is 405 — not what SBDEV-3013 assumes
metadata:
  type: reference
---

For the Spring Data REST **association** resource `/v3/userRole/{id}/functions` (generated from `UserRole.functions`), verified directly against `spring-data-rest-core 4.5.7`'s `RepositoryPropertyReferenceController` during SBDEV-3011:

- **`PUT` + `text/uri-list` with an EMPTY body is the destructive verb** — `PUT` is absent from `AUGMENTING_METHODS`, so it replaces the collection wholesale and Hibernate's `CollectionRemoveAction` clears every `mywms_role_mywms_function` row (77 on `super-admin`).
- **`PATCH` / `POST` are ADDITIVE ONLY** — they can grant functions, never remove them. An escalation primitive, not a destructive one.
- **`DELETE` on the collection returns 405**, not a mass delete; the controller rejects a collection-like property. Only `DELETE /functions/{functionId}` works, removing exactly one grant.
- Leaving the **item** `PUT`/`PATCH` exported is safe: `DomainObjectReader`'s `LinkedAssociationSkippingAssociationHandler` returns early for linkable associations, and `UserFunction` has an exported repository — so `PUT /v3/userRole/{id}` omitting `functions` does **not** null the grants. The usual SDR "PUT nulls omitted fields" hazard doesn't apply here.

**Why it matters:** SBDEV-3013's ticket text lists the surface as `PUT/PATCH/DELETE`, implying all three destroy. Scoping that ticket off the original wording would target the wrong verbs. `@RestResource(exported = false)` on repository methods cannot reach `PropertyReferenceController` at all — suppressing association exposure needs field-level `@RestResource` or a `RepositoryRestConfigurer` exposure change.

**How to apply:** `repo/cinterface/NoDeletePagingAndSortingRepository` closes the **item** resource only (first used by SBDEV-3011; it also lacked `@NoRepositoryBean`, unlike its 11-user sibling `ReadOnlyPagingAndSortingRepository`). Confirm exported verbs empirically by driving SDR's own `CrudMethodsSupportedHttpMethods.getMethodsFor(...)` rather than reasoning from annotations. See [[sbdev-3011-delete-role-join-table-cascade]], [[wms2-function-gates-are-self-grantable-via-ungated-usercontroller]].
