---
name: los-sysprop-modified-does-not-track-value-changes
description: "los_sysprop.modified dates the ROW, not its current value — a direct UPDATE leaves it untouched, so sysprop timestamps cannot date a bad value; reads are also cached 2min and direct SQL bypasses @CacheEvict"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 808bca86-52b6-4371-ba7e-d7eb03e16a35
  modified: 2026-09-11T12:43:44.231Z
---

Measured 2026-09-11 on SBDEV-3314 (Hydra prd), where it produced a **false inference posted to a
ticket**. Nam updated three `WEBSERVICE_*` values by direct SQL; re-querying showed the new values with
`modified` **unchanged** at `2026-06-11 21:44:19.259594+00` — byte-identical to the literal timestamps
baked into `V2.2.00__base_v2_schema.sql`'s seed INSERT.

**There is no trigger and no `@PreUpdate` maintaining `modified` on this table.** So:

- `modified` dates the **row's creation** (or whatever the seed literal said), never its current value.
- A wrong value can sit there indefinitely carrying an innocent-looking timestamp from years earlier.
- **`los_sysprop` has no audit trail at all** — no history table, no `modified_by`. Once a value is
  overwritten, *how* and *when* it got there is unrecoverable from the database. Do not spend effort on
  attribution; say it is untraceable and move on.

**The trap:** grouping by `modified` makes the rows sort into tidy clusters that look like discrete
seed runs, and the story is compelling — "these 8 were created in a 3-second window, therefore an
automated seeder wrote these values." The clustering is real (the rows *were* created together); the
conclusion about the **values** does not follow. What actually settled the question was reading the
migration (it seeds a `CHANGE-ME-FOR-NEW-CLIENT/…` sentinel, so it cannot have written the bad URL) and
comparing every other tenant's current value — evidence that does not route through a timestamp.

**Second, independent trap on the same table — sysprop reads are CACHED.** `SyspropService.getByKey`
is `@Cacheable(value = "sysprops", key = <tenant>:<key>)`, and eviction fires only through the service's
own `@CacheEvict` write methods. **A direct SQL `UPDATE` bypasses it entirely.** `sysprops` happens to
carry a **2-minute TTL** on both cache managers (`buildCaffeineCache("sysprops", 200,
Duration.ofMinutes(2))` for the default profile, `.withCacheConfiguration("sysprops", …
entryTtl(Duration.ofMinutes(2)))` under `redis`), both `expireAfterWrite` — so it self-heals fast and no
restart is needed.

⚠ **The caching half is v2-ONLY.** `SyspropService`, `CacheConfig` and the Caffeine/Redis managers do
not exist in v1 — measured 2026-09-16, there is no `@Cacheable`, `@CacheEvict` or `@EnableCaching`
anywhere under `v1/wms-api/src/main/java/net/aim_ai/wms`, and `LosSyspropRepository.findSysvalueBySyskey`
is a plain `nativeQuery` that hits the DB on every call. So on **v1 a direct SQL sysprop edit is live on
the next read** — no TTL to wait out, no restart. Carrying the v2 caching assumption to v1 makes you wait
for, or restart for, a staleness that cannot occur. The `modified` half above applies to BOTH versions.

⚠ **Do not generalise that 2 minutes.** The siblings in `CacheConfig` are 5-minute (`clients`,
`locations`, `itemdata`), and a 5-minute cache patched by direct SQL reads as *applied in the DB, stale
in the app* for long enough to look like the fix did not work. Check the TTL for the specific cache
before concluding a direct DB edit took effect.

**How to apply:** never date a sysprop value from `modified`, and never verify a direct sysprop edit by
re-reading the DB alone — the DB is the thing you just wrote. Verify at the behaviour: for a
`WEBSERVICE_*` URL that means the next `message` row's `destination` and `statuscodeanswer`, not
`status` (see [[wms2-hydra-prd-notifies-uat-oms.md]] — `status` is hardcoded `SENT` on the legacy path).

Related: [[wms2-hydra-prd-notifies-uat-oms]], [[a-zero-scan-needs-a-positive-control]],
[[failed-regex-resolution-must-not-become-a-verdict]].
