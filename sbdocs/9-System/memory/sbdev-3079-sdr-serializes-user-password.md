---
name: sbdev-3079-sdr-serializes-user-password
description: SHIPPED 2026-08-24 (PR #192, 564e99c) as @JsonProperty(access=WRITE_ONLY) on User.password — NOT @JsonIgnore, because the value must still bind inbound. The id-walk it rode on survives.
metadata:
  type: project
---

**SHIPPED 2026-08-24, PR #192 `564e99c`, verified live on dev** (`GET /v3/user/0` as a non-admin no longer
carries a `password` field). Fixed with `@JsonProperty(access = JsonProperty.Access.WRITE_ONLY)` — **not**
`@JsonIgnore`, deliberately: the value must still bind INBOUND or a read-modify-write nulls it and
`@NotNull` breaks. ⚠️ **The enumeration route it rode on SURVIVES** — `/v3/userGroupUser` still hands out
every `userlistId` and `/v3/user/{id}` still returns the row, so a non-admin can enumerate every user
minus the password.

Filed out of [[sbdev-3071-arbitrary-username-user-reads]] triage. Measured on DEV
(`wineco`/`wsl`) with a real non-admin token (`sbtest`, 35 functions, no `WEB_UI_VIEW_USER_MANAGEMENT`).

`model/User.java:25` — `@NotNull private String password;` — carries **no** `@JsonIgnore`/`@JsonProperty` and
has a public getter (`:97-98`). There is **no `@JsonIgnore` precedent anywhere in `model/`**, which is why
nothing caught it. So SDR serializes the column:

- `GET /v3/user/{id}` → 200 with a 32-hex hash. **Ids are walkable — 6 of 6 tested** (0, 1, 52150, 52600,
  52601, 52602).
- `GET /v3/user/search/findByName?name=<anyone>` → same field. 404 for a nonexistent name.
- DB: 99/99 rows have a password, **85 MD5-shaped** (`^[0-9a-f]{32}$`).

**Not an auth bypass** — auth is Keycloak, nothing in `src/main` authenticates against the column, and
`UserService:75` writes the literal placeholder `"KeycloakHasIt"`. These are legacy myWMS-era hashes. Still
credential material (crackable MD5, password reuse) readable by every operator.

**Why:** two traps make the obvious fix wrong and the obvious "safe" reading wrong.

1. **Do NOT fix by un-exporting.** `@RepositoryRestResource(exported = false)` — or withdrawing GET on
   `forDomainType(User.class)` — **breaks User Management**: `wms2-web-ui/components/admin/userManagement/
   users/user.vue:304` reads `GET /user/${item.id}` and `store/admin/user.js:50` reads
   `GET /user/${userId}/groups`. This is exactly why SBDEV-3077 / PR #191 disabled `WRITE_VERBS` only
   (`RestConfiguration:190` association, `:202` item) and preserved GET. **The fix is
   `@JsonProperty(access = WRITE_ONLY)` on the field** — suppress the value, keep the route.
2. **An SDR endpoint that 500s is NOT a closed door.** `search/getAllRoles` and `search/getDetails` both
   return 500 because they are `nativeQuery = true`, which SDR cannot materialise. They are ungated **and**
   inert; making either query SDR-compatible turns it live **and** ungated in one move — and `getDetails` is
   the whole-directory dump `UserController:503-509` guards with `denyUnlessUserManagementAllowed()`. Two of
   the five advertised `@RestResource` searches on `UserRepository` do not work, so
   [[advertised-capability-is-not-exploitable-capability]] cuts **both** ways: advertised ≠ live, and 500 ≠ safe.
   `findByPrinterId` returns `List<User>` — structurally the same bulk exposure, unconfirmed only because no
   `wineco-dev` row has a non-null `printer_id`.

**How to apply:** state the environment for every claim. `origin/develop` led `origin/main` by **87 commits**
on 2026-08-24, and on `main` the exposure is strictly worse: `User.password` is unannotated identically, **and**
`RestConfiguration` has no `forDomainType`/`WRITE_VERBS` at all and `WebConfig` has no `MappedInterceptor`
bean — so on prd the SDR write surface is still open and the function gate never reaches SDR. Slice A's
reachability and 3077's withdrawals are dev-only. Same shape as
[[sbdev-3005-role-function-composite-key-swap]]. Related: [[wms2-sdr-is-gatable-via-mappedinterceptor-bean]],
[[wms2-only-one-of-80-functions-is-enforced]].

**Triaged 2026-08-24 → T2, no plan doc** (deciding factor: a response-contract change across every
`User` serialization; not T3 — no gate, no migration, no data write, single repo). The consumer sweep is
**done and clean**, so `@JsonProperty(access = WRITE_ONLY)` is verified safe and needs no UI change:
`editUser.vue:115-118` does `Object.assign({}, newVal)` then **`resetPassword()`** (`:174`) — the hash is
already discarded on load, so a missing key is behaviourally identical; `store/admin/user.js` and all of
`wms2-mobile-ui` have **zero** `password` refs; and no GET→PUT round-trip can drop the column because
PR #191 withdrew all four `WRITE_VERBS` from the `User` **item** (`RestConfiguration.java:200-202`), not
just the association (`:188-190`). `UserService.setPassword:97-115` is entirely commented out. Note the
file lives at `repo/jpa/UserRepository.java`, not `repository/`. Field-level is the right altitude: one
annotation closes all five exported read routes plus every `UserController` route returning a `User`.

**MERGED to develop 2026-08-24 — PR #192, fix `564e99c`, merge `adb6ee8`,
ticket `on dev`.** Fix = `@JsonProperty(access = WRITE_ONLY)` on the field, plus deleting the
commented-out `details.put("password", ...)` in `UserService.getUserDetails` (a hand-built Map the
annotation cannot protect — already pinned by `UserServiceUnitTest$GetUserDetails
.shouldExcludePasswordFromDetails`, so the "all tests stay green" framing of that finding was wrong).

**Two corrections to this memory's own original numbers:**
1. **Four** live read routes leaked, not five: item, collection, `findByName`, `findByPrinterId`.
   `getAllRoles` returns `List<String>` and `getDetails` returns `UserDetailView` (no password getter) — so
   they were inert *and* structurally harmless, not merely inert. The "500 ≠ closed door" lesson still holds
   for `getDetails` as a **whole-directory dump**, just not as a password vector.
2. **`RestConfiguration` never calls `withCollectionExposure` for `User`** — only `withAssociationExposure`
   (`:189-190`) and `withItemExposure` (`:201-202`). So `POST /v3/user` is live to any wms_user and, under
   `setReturnBodyForPutAndPost(true)` (`:222`), echoes the created entity. This is *why* WRITE_ONLY is
   strictly correct and `@JsonIgnore` is wrong: `@NotNull` on `password` must stay satisfiable inbound on
   that route. Evidence added to SBDEV-3077; the id+version→`em.merge` overwrite primitive is INFERENCE
   (the HTTP request was never issued) — probe before acting.

**Severity was under-filed:** the 85 MD5 rows are only **25 distinct hashes, one shared by 41 users**.

**Residual gap, documented in the test javadoc:** the pin asserts Jackson introspection on a plain mapper,
not a render through SDR's `PersistentEntityJackson2Module`. SDR honours it (its `BeanSerializerModifier`
only prunes associations from the property list Jackson already built by introspection; there is no
`addMixIn`, custom `AnnotationIntrospector`, or `@Projection` in `src/main`), and a route-level assertion
would need the MockMvc web-context lane, which does not boot. **If an SDR `@Projection` over `User` is ever
added, re-verify.** No log leak: neither `User` nor `AbstractBaseEntity` declares `toString()`.

**Two acceptance criteria are NOT ticked** and were deliberately not claimed: the live
`GET /v3/user/{id}` and `search/findByName` probes with a non-admin token. The unit test pins Jackson
introspection, not a render through SDR's `PersistentEntityJackson2Module`, so a green suite is not
evidence for the route. Needs an `sbtest`-class token post-deploy. **Recommended prd path: ride the next
release, no hotfix** — cherry-picking one commit out of an 87-commit divergence is more risk than a
non-bypass exposure behind a valid token warrants, but it stays live on prd until that release ships.
