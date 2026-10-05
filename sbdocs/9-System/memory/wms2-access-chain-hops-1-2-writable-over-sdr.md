---
name: wms2-access-chain-hops-1-2-writable-over-sdr
description: "STALE/CORRECTED 2026-10-01: hops 1, 2, 4 are now write-disabled via RestConfiguration.configureAccessChainMembershipWriteExposure; the 2026-08-24 SDR write exposure below is history"
metadata:
  type: project
---
> **STALE / CORRECTED 2026-10-01.** The title claim ("hops 1-2 writable over SDR") is no longer true on `origin/develop`. `RestConfiguration.configureAccessChainMembershipWriteExposure` (`RestConfiguration.java:200`, called from `:102`) now disables `WRITE_VERBS` on collection and item exposure for hop 1 (`UserGroupUser`), hop 2 (`UserGroupUserRole`) and hop 4 (`UserFunction`): e.g. `.forDomainType(UserGroupUser.class).withCollectionExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS))`. Hop 2 is additionally un-exported entirely by SBDEV-3183 Slice 2 (its block is now a no-op "belt-and-braces"). The javadoc reads "closing every SDR route to hops 1 and 2, plus the item-PATCH route to hop 3" (SBDEV-3545 also withdrew `UserRole` item verbs). The table and "How to apply" below are the 2026-08-24 measurement, kept as history; do not cite them as current. Verified by `git grep` on `origin/develop` 2026-10-01.


`AccessService` derives every authorization decision from `UserRepository.getAllRoles`
(`UserRepository.java:29-37`), a four-hop join:

```
mywms_user → mywms_group_mywms_user → mywms_group_mywms_role → mywms_role_mywms_function → mywms_function
                  hop 1                     hop 2                hop 3 (SBDEV-3013 closed this one)
```

**Measured on `origin/develop` 2026-08-24** by driving the production `ExposureConfiguration` through SDR's own
package-private `filter(...)` entry points — the technique `SdrWriteExposureUnitTest` uses, which is
authoritative for what SDR exposes and needs no token:

| entity | SDR path | COLLECTION | ITEM |
|---|---|---|---|
| `UserGroupUser` (hop 1) | `/v3/userGroupUser` | **GET POST PUT PATCH DELETE** | **all** |
| `UserGroupUserRole` (hop 2) | `/v3/userGroupUserRole` | **GET POST PUT PATCH DELETE** | **all** |
| `UserRoleUserFunction` (hop 3) | `/v3/userRoleUserFunction` | `GET` only ✅ | `GET` only |
| `UserGroup`, `UserRole` | `/v3/userGroup`, `/v3/userRole` | **all** | **all** |

The hop-3 row is the **control**: it proves the probe reads the real production config rather than a default.
`RestConfiguration.configureRepositoryRestConfiguration` withdraws write verbs via `forDomainType` for exactly
two types — `UserRole` (association only) and `UserRoleUserFunction`.

**Why:** `/v3/**` requires only the `wms_user` authority (`SecurityConfiguration.java:151`), and SDR never
reaches `FunctionGuardInterceptor`'s policy layer (there is no rule source for SDR handlers even after
SBDEV-3017 slice A made the interceptor *reachable*). So a principal holding `wms_user` can add itself to a
privileged group — on wineco-dev `mywms_group.id = 51856` is the `super-admin` group → role `super-admin`
→ 79 functions. If that reproduces end to end, **every function gate shipped by SBDEV-2967 / 2968 / 3013 / 3017
is a label rather than a boundary.** Related: [[wms2-function-gates-are-self-grantable-via-ungated-usercontroller]],
[[wms2-13-action-gates-are-self-grantable-and-sdr-bypassable]], [[wms2-join-table-uniqueness-is-out-of-band]].

**How to apply:**
- **Still owed: one curl.** The exposure config permitting a verb is necessary, not sufficient —
  [[advertised-capability-is-not-exploitable-capability]]. `RestConfiguration.java:38-39` records a *measured*
  live 200 on the analogous hop-3 surface before 3013 closed it, so the precedent is strong, but do not report
  this as exploited until a write is executed.
- Closing it is the same one-line shape as 3013 door ①: `forDomainType(UserGroupUser.class)` +
  `withCollectionExposure`/`withItemExposure` disabling the four write verbs. Scope `forDomainType` — a bare
  `withCollectionExposure` makes the whole HAL API read-only.
- ⚠️ Check `UserGroup`/`UserRole` before withdrawing: the web UI's Role and Group admin screens read those
  paths, and 3013 kept GET deliberately for that reason.
- The probe is reusable — preserved in this session's scratchpad as `AccessChainSdrExposureProbeTest.java`.
