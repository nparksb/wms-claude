---
name: sbdev-2984-usercontroller-gated-but-sdr-user-still-writable
description: "SBDEV-2984 (v2) on dev — 9 UserController handlers now @RequiresFunction-gated, PR #180 dc56849; LANDMINE the SDR item resource PATCHes /v3/user/{id} to 200 regardless, so only the Keycloak half is actually closed"
metadata: 
  node_type: memory
  type: project
  originSessionId: 74e9ade3-54f9-40c9-b7fd-5f0d8ec80cce
  modified: 2026-08-21T20:20:38.896Z
---

**SBDEV-2984 (v2) — `on dev`. [wms2-api #180](https://github.com/SiteBossInc/wms2-api/pull/180) merged 2026-08-21 as `dc56849`.** Scope widened during implementation from the ticket's 3 named endpoints to **9** handlers on `UserController` — the six writes plus the three User-Management-only reads — all annotated `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` **and** carrying an explicit `denyUnlessUserManagementAllowed()` as the first statement, outside every `try`.

**Why the belt AND the braces.** `UserController` cannot join `FunctionGuardInterceptor.GUARDED`, because `isWmsUser` and `getAllRoles` on the same class must stay open to every authenticated user — and `GUARDED` is a *class*-level fail-closed set. So the annotation alone would not be enforced at runtime here. The imperative call is what actually denies; the annotation is the declarative record plus what a build-time test keys on. Follow-up **SBDEV-3063** moves those two methods off the class so it can join `GUARDED` and get real runtime fail-closed. Until then, the guarantee that a *newly added* handler cannot ship open is a **test**, not the framework: `UngatedWriteEndpoints.everyWriteHandlerIsGated`, with `OPEN_BY_DESIGN = Set.of("isWmsUser","getAllRoles")`, keyed on the annotation rather than the HTTP verb (verb-keying misses the destructive `GET /v3/user/delete/{userId}`, which is still a GET — the verb change was **not** done).

**LANDMINE — do not read this ticket as "the user endpoints are locked down".** `UserRepository` is exported by Spring Data REST at the *same* `/v3/user` prefix, and measured on DEV:

```
OPTIONS /v3/user      -> allow: GET,HEAD,OPTIONS          (collection: no POST)
OPTIONS /v3/user/{id} -> allow: HEAD,DELETE,GET,OPTIONS,PUT,PATCH
PATCH   /v3/user/{id} -> HTTP 200
```

So the **WMS-row** half of `/update`, `/bulkEditUsers` and `/delete` is still reachable ungated and unaudited. What IS closed is the **Keycloak** half — `createSingleUser`, `addUserToWmsGroup`, `updateSingleUser`, `updateUserPassword` — because SDR cannot reach Keycloak at all, so manufacturing a *loginable* identity with warehouse-group membership is genuinely gated. That was the ticket's sharpest edge. This is a real 200, unlike the `/v3/stockunit` case in [[advertised-capability-is-not-exploitable-capability]] — measured, not inferred from an `Allow` header. **Deliberately unfiled** (Nam has not authorised a ticket for the SDR write surface; it spans 51 exported repos, needs an owner with authority over that surface, and closing it bluntly breaks ≥8 known UI call sites).

**No live 403 was ever observed.** By design there is no observable change for an *authorized* caller, and the DEV credentials available (`panderson`) hold the function. Confirming denial needs an account with `wms_user` but not `WEB_UI_VIEW_USER_MANAGEMENT`; then `GET /v3/user/getDetails` should be 403 with `application/problem+json`. Evidence base is 11 killed mutants + suite (5342/2 alone, 5371/2 combined with SBDEV-3011) + deploy.

Related: [[wms2-only-one-of-80-functions-is-enforced]], [[wms2-function-gates-are-self-grantable-via-ungated-usercontroller]], [[sbdev-3011-delete-role-join-table-cascade]], [[wms2-admincontroller-is-a-base-class-for-43-controllers]]
