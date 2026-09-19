---
name: sbdev-3071-arbitrary-username-user-reads
description: SHIPPED PR #193 on dev — scoping a @PublicHandler to the caller is only half the fix; the same capability was published twice more over SDR, and un-exporting one search only relocated the oracle.
metadata:
  type: project
---

`UserController.getAllRoles/{username}` and `isWmsUser/{username}` took a path variable and never consulted
the principal. Both carry `@PublicHandler` (SBDEV-3063), so the function gate short-circuits before any check.
Measured on DEV as `sbtest` (35 functions, no user-management): `getAllRoles/admin` returned **admin's 80
functions**; `isWmsUser` was a working existence oracle. Fixed by `denyUnlessSelf()` as the FIRST statement of
both (before any repository call), 403 not 404. **Merged PR #193 → `0d1e3e5`, verified live: 10/10 smoke rows.**

**Why:** three traps here generalise to any "scope this to the caller" fix in wms2.

1. **The unauthenticated principal is the String `"anonymousUser"`, NOT `SecurityContextUtils.ANONYMOUS`
   ("anonymous").** `getUserName()` returns `ANONYMOUS` only when `authentication == null`; `anonymous()` is
   not disabled in `SecurityConfiguration` (only `csrf` is), so a real unauthenticated request carries an
   `AnonymousAuthenticationToken` whose String principal is returned verbatim through the `instanceof String`
   branch. **Guard on the token TYPE, not the literal.** Also guard `self == null` — `getUserName()` is
   `preferred != null ? preferred : jwt.getSubject()` and BOTH can be null, which NPEs into a 500;
   `UserAdministrationController:118` has that clause and a guard claiming to copy it dropped it.
2. **`@AuthenticationPrincipal Principal principal` is ALWAYS NULL in production** — `Jwt` does not implement
   `java.security.Principal`. The unit lane hides this: `BaseControllerUnitTest` installs a
   `MockPrincipalArgumentResolver` that always yields a non-null principal, so code reading
   `principal.getName()` NPEs on every production request with a green suite. Read the `SecurityContext`.
   An unused-but-non-null-looking parameter is very likely why this handler read as already-scoped.
3. **Scoping the controller closes ONE of three doors.** `UserRepository` published the same capabilities over
   SDR, which reaches no rule source (`FunctionGuardInterceptor` keys on the DECLARING class; for SDR that is
   `RepositorySearchController`). Un-exporting `findByName` alone only **relocated** the oracle to
   `findClientIdByName` — measured `?name=admin` → 200 body `0`, `?name=nobody99` → 404. It is **JPQL
   returning a `Long`**, so SDR's `isPrimitiveOrWrapper` branch materialises it; the "nativeQuery cannot be
   materialised" reasoning that makes `getAllRoles`/`getDetails` 500 does NOT cover it, and **a 500 is an
   accident, not a control**. All five searches were withdrawn. See
   [[wms2-sdr-is-gatable-via-mappedinterceptor-bean]].

**How to apply:**
- Pin an export surface **structurally, never as a hand-maintained allow-list.** The first draft of the test
  listed `findClientIdByName` under "the reviewed searches", converting an unexamined exposure into an
  asserted-reviewed one — the worst of the three states. Assert instead that NO declared method is exported,
  and treat a **missing** `@RestResource` as a violation, since Spring Data REST exports query methods by
  default. Idiom: `AdviceRepositoryRestExportUnitTest`.
- **Still open after this fix:** the whole function-set read replays for an arbitrary username via three
  ungated SDR GETs — `userGroup/search/findByUsername` → `userGroup/{id}/roles` → `userRole/{id}/functions`
  (measured 79 functions for `admin`). Same join, table for table. Hop 1 is the only username-addressable
  link. Recorded on SBDEV-3017. Related: [[sbdev-3079-sdr-serializes-user-password]],
  [[wms2-function-gate-anti-drift-only-covers-guarded-classes]].
