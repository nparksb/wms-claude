---
name: sbdev-3190-singleton-tenant-state
description: SBDEV-3190 MERGED on dev — four instances of per-tenant state on Spring singletons, plus the ArchUnit rail and its four blind spots
metadata:
  type: project
---

**SBDEV-3190 merged to `develop` 2026-09-02 (`20b60209`, PR #272).** Four instances of one defect
class — per-tenant state held on a `@Service` singleton, invisible while prd ran one tenant-facility:

1. `Unitload`/`StockunitBusinessService` memoised the Nirwana rows behind one `boolean initialized`
   latch → now resolved per call. Nirwana **unitload** ids differ per facility (hydra 1,
   shipitez/c1wh 5,069,679, wineco 66,252); the **location** id is 0 everywhere, so only the unitload
   half ever bit. A real FK `fkhoxjsrvueohjwo8qjyi6falad` on `stockunit.unitload_id` rejects a
   borrowed id — JPA models no association but PostgreSQL enforces it.
2. `KeycloakService.userCache` keyed on bare username → now `realm + "::" + username`, via
   `userCacheKey`/`cachedUser`/`cacheUser`/`evictUser`. It cached the **plaintext password**
   (`createSingleUser` sets credentials on the instance it caches; `AdminController` serialises it)
   — pre-fix a cross-tenant CREDENTIAL disclosure, not just identity.
3. `BillofladingService.bolToClose` `Set<Long>` → `Set<String>` keyed `cacheKey(tenant) + "#" + bolId`.
4. `SyspropService.omsInstanceName/wmsInstanceName` — found by the rail, not the audit; never
   assigned, so a primed trap rather than a live bug. Deleted.

**The axis is not always the tenant.** Slice 2 keys on the **realm** (ShipItEZ's two warehouses share
one); Slice 3 keys on **tenant+facility** (those same warehouses are separate DBs with independent id
sequences). Pick the axis from what the value is scoped to. `TenantKeyBuilder.cacheKey` (full tenant
name), never `buildKey` (4-char truncation is routing-only).

**`SingletonTenantStateArchTest` has FOUR disclosed blind spots** and its green is not evidence:
(1) a `final` field holding a mutable object — where instances 2 and 3 both lived; (2) boxing round
the rule; (3) singletons with no stereotype (`@ControllerAdvice`, `@Bean`, XML); (4) fields declared
on a superclass. It uses a one-entry reviewed allow-list, deliberately **not** the repo's
`FreezingArchRule` store — a freeze would have swallowed the real defect fields and gone green.

**Still open: [[sbdev-3197-jwt-cachemap]]** — a fifth instance on the auth path.

Related: [[wms2-boxed-long-id-comparison-works-under-128]], [[a-guard-fences-the-mechanism-you-aimed-at]].
