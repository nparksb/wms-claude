head: 723e1ba0267ff93d689a0a1d3a154f692ab40419

# Security Review Report: SBDEV-3381 Phase 1 (supervisor waive plus V2.2.34)

**Scope:** `git diff 91789cc7...HEAD` in `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3381`. I read the 10 `src/main` files plus the authz surface they depend on: `FunctionGuardInterceptor`, `AccessService`, `RestConfiguration`, `SdrFunctionRules`, `SecurityConfiguration`, `JwtAccessTokenCustomizer`, `SecurityContextUtils` and the User/Role/Group controllers and repositories. I did not run `mvn` and wrote nothing in the worktree.
**Risk Level:** MEDIUM

**DB checks could not be run.** Every read-only MCP I tried failed: `c1wh-shipitez-prd`, `nywh-hydra-prd` and `nywh-shipitez-prd` each dropped once, then timed out at 30s, including on `SELECT 1`. `wms2-wineco-dev` could not connect. So table ownership, role names on live tenants and the current `WMS2_SDR_READ_GUARD_MODE` are all **UNVERIFIED**.

## Summary
- Critical: 0
- High: 0
- Medium: 1
- Low: 4, plus 1 UNVERIFIED migration-privilege item

## Medium

### 1. V2.2.34 grants the new override by a role name any `wms_user` can rewrite (a self-grant path before the migration runs)
**Category:** A01 Broken Access Control
**Location:** `src/main/resources/db/migration/V2.2.34__cancellation_reversal_waive.sql:806-809`, plus the pre-existing item PUT on `UserRole` in `src/main/java/net/aim_ai/wms/RestConfiguration.java`.

The seed picks roles by name only:
```sql
WHERE f.name = 'MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL' AND r.name IN ('outbound-manager','super-admin')
```

`mywms_role.name` can be changed over SDR:
- `RestConfiguration` removes only PATCH and DELETE from `UserRole` items: `.forDomainType(UserRole.class).withItemExposure((metadata, httpMethods) -> httpMethods.disable(HttpMethod.PATCH, HttpMethod.DELETE));`. It keeps item PUT on purpose for `store/admin/role.js`.
- `mergeForPut` skips linked associations only. Scalar fields are applied, and `UserRole.name` is a plain `@NotNull private String name;`.
- The only gate on it is `SdrFunctionRules`: `rules.put(UserRole.class, USER_ADMIN_VIEW)`. That rule does nothing at `SdrGuardMode.OFF`, and OFF is what dev and Hydra prd measured on 2026-09-03 (not re-measured today).
- `/v3/**` requires only the `wms_user` authority (`SecurityConfiguration`, rule D).
- `mywms_role` has `UNIQUE (name)` (V2.2.00:3643-3644), so the attack takes two requests instead of one.

**Scenario.** The attacker is an outbound worker who is in a group bound to role R and holds only `MOBILE_UI_VIEW_CANCELLATION`. `GET /v3/userRole` is readable at OFF, so they can find the ids.
1. `PUT /v3/userRole/{outbound-manager id}` with `name:"om-old"` (full body).
2. `PUT /v3/userRole/{R}` with `name:"outbound-manager"`.
3. The next deploy's Flyway run executes V2.2.34 on that tenant, and R receives `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`.

This works on any tenant V2.2.34 has not reached yet. Prd is on 2.2.33, so the window stays open until the prd deploy.

**Blast radius:** the attacker can then waive any order in that facility:
- close pending reversal rows;
- clear `PICKED_FOR_GOODSOUT` locks (in the ON-tote case where the ownership rule holds);
- send OMS `ORDER_BATCH_REVERSAL_COMPLETED` with `stockReturned=true` in cases (i), (i″) and (iii-a) (see finding 2).

The real outbound-manager role also silently misses the grant. The audit query SET 9 (`audit-access-invariants.sql`) keys on the same names, so it would show the renamed role as correct.

**Status:** derived from source. I did not send the PUT to confirm it works (per memory, advertised ≠ exploitable), and I could not re-measure the guard mode.

**Pre-existing vs new:** the original "self-grantable gates" hole is closed in this tree:
- `UserController`, `UserRoleController` and `UserGroupController` are class-gated on `WEB_UI_VIEW_USER_MANAGEMENT` and in `GUARDED`.
- SDR hop 1 (`UserGroupUser`) and all write verbs on `UserFunction` are withdrawn.
- Hops 2 and 3 are unexported or withdrawn.

What is left is the role-rename primitive. On its own it grants nothing; this migration is what turns a name into a grant. For the record: anyone holding `WEB_UI_VIEW_USER_MANAGEMENT` can grant the new function through `saveRoleFunctions`, which has no "you can't grant what you don't hold" check. That is intended admin power.

**Fix (cheap, in this PR):** don't trust a mutable name alone. Two parts:
- Also require a stable attribute (`r.number` still equal to the seeded value, `connector = false`).
- Assert exactly the expected cardinality, so the migration fails instead of guessing.
```sql
-- BAD
WHERE f.name = 'MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL' AND r.name IN ('outbound-manager','super-admin')
-- GOOD
WHERE f.name = 'MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL'
  AND r.name IN ('outbound-manager','super-admin')
  AND r.number = r.name AND NOT r.connector
```
Then add a post-deploy check to the runbook: list the roles and users holding the new function per tenant and compare against expectations. The lasting fix, outside this ticket, is moving tenants to `ENFORCE_RULED`, or withdrawing name mutation on the `UserRole` item PUT. I would propose that as a ticket, not file it.

## Low

### 2. OMS receives "reversal completed" on the operator's word alone, and the payload does not say it was a waive
**Category:** A04 Insecure Design / trust boundary
**Location:** `CancellationReversalService.waiveReversal`, the `if (suId == null) continue;` and `if (su == null) continue;` lines that run before the `stockReturned` check, and the `refuse` expression.

The plan's refusals are correctly implemented:
```java
boolean refuse = isLock(lock, SHIPPED) || (hasStock && (isLock(lock, PICKED_FOR_GOODSOUT) || state != ToteState.OFF));
```
- SHIPPED is always refused.
- Stock on ON, PARCEL or UNKNOWN is refused.
- Lock 100 with stock is refused.

What remains is by design:
- `stockReturned=true` is accepted with no WMS evidence when the stock unit is missing or unresolvable (iii-a), or when its amount is 0 (i and i″). The live c1wh case is amount 0 at lock 2 on Nirwana.
- `enqueueReversalCompletedIfClosed` sends a payload identical byte-for-byte to a real reversal, so OMS cannot tell a physical reversal from a waive attestation.

**Scenario:** a supervisor with the function, by mistake or on purpose, waives with `true` for stock that was actually consumed. OMS records a return WMS never performed.

**Mitigations present:** the grant set, and an attributable row (`reversal_completed_by`, reason, attestation, protected by a CHECK).

**Fix (Phase 2 or an OMS contract change):** carry a `waived:true` or attestation marker in the payload, or accept this as settled.

### 3. `positionIds` has no size limit, and the no-op path logs the whole list
**Category:** A05 / DoS (authorized callers only)
**Location:** `waiveReversal`, the "none pending" branch:
```java
LOG.info("waiveReversal order={} positions={}: none pending — no-op", coId, positionIds);
```
Duplicates of a valid id pass the `onOrder` check, so `[id, id, …] × 10^6` reaches this line and writes a multi-MB log line on every call. The `positionIds.contains` filter over a `List` also makes the cost O(pending × N). Only a holder of the waive function can do this.

**Sibling sweep:** `completeReversal` / `CancellationCompleteRequest` has no cap either.
```java
// GOOD
if (positionIds.size() > MAX_POSITION_IDS) throw new BusinessException("too many positionIds (max " + MAX_POSITION_IDS + ")");
Set<Long> ids = new HashSet<>(positionIds);   // use for contains + logging
```

### 4. The name used to authorize and the name stamped in the audit field can differ
**Category:** A09 Logging / attribution
**Locations:**
- `FunctionGuardInterceptor.currentUsername()` uses `authentication.getName()`. `JwtAccessTokenCustomizer:53` sets that to `preferred_username`, falling back to `"service-account"`.
- `SecurityContextUtils.getUserName()` (the value written to `reversal_completed_by`) uses `preferred_username`, falling back to `jwt.getSubject()`.

The route itself is sound:
- Rule D requires an authenticated `wms_user`.
- The interceptor then requires the function, so `anonymous` cannot reach the service.

**Scenario:** a token without `preferred_username` is authorized as the DB user `service-account`, but the waive is recorded under a raw UUID `sub`. This is pre-existing, but it now decides who is recorded as having made the stock attestation.

**Fix:** stamp the name of the principal the gate authorized.
```java
final String operator = SecurityContextHolder.getContext().getAuthentication().getName();
```
Alternatively, refuse waive when `preferred_username` is absent.

### 5. Stored reason is shown later with no output encoding (a note for Phase 2)
**Category:** A03 XSS (latent)
The reason is trimmed, capped at 500 characters, stored raw and returned in `CancellationLogEntryDto.waiveReason` to every `VIEW_CANCELLATION` holder, not just waive holders. It is not logged, so there is no log injection. Phase 2's mobile or web rendering must use `{{ }}` interpolation and never `v-html`. CR/LF are also kept, which matters for any CSV or report export.

## UNVERIFIED: migration privileges on tenants whose table ownership has drifted
`ALTER TABLE public.customerorder_cancellation_log ADD COLUMN … / ADD CONSTRAINT` needs the app role to own the table. Per memory, a tenant not owned by the app role fails with 42501 at boot and freezes that tenant silently. The plan's evidence is only that V2.2.28 and V2.2.31 already ALTERed this table fleet-wide, and that V2.2.18 already inserted into `mywms_function` and `mywms_role_mywms_function`. I could not run the ownership probe because the MCPs timed out. Run this on each prd/UAT tenant before the prd deploy:
```sql
SELECT tablename, tableowner FROM pg_tables
WHERE tablename IN ('customerorder_cancellation_log','mywms_function','mywms_role_mywms_function');
```
The DO block's `pg_constraint WHERE conname = …` check is not scoped to the table, which is harmless. The rest of the migration is safe: `ADD COLUMN IF NOT EXISTS`, and no dynamic SQL, so no injection surface.

## Checked and clean
- **Method gate replaces the class gate.** Confirmed in `FunctionGuardInterceptor.preHandle`: `RequiresFunction methodLevel = handlerMethod.getMethodAnnotation(...)`, then `if (annotation == null) annotation = AnnotationUtils.findAnnotation(declaring, ...)`, then `checkAnyAccess(username, annotation.value())`. A holder of only `VIEW_CANCELLATION` is refused; this is pinned by `FunctionGuardMockMvcUnitTest` T11.
- **Consequence as stated.** Both roles in the grant set also hold `MOBILE_UI_VIEW_CANCELLATION` (`UtilRestController` initDB, just above the new grant), so list and detail still work for them.
- **`OrderCancellationController` is in `GUARDED`.**
- **`AccessService.checkAnyAccess`** is a plain DB lookup (user → group → role → function) with no bypass. `getAllRoles` is not `@Cacheable`.
- **No other route reaches `waiveReversal`.** The only caller is the controller.
- **No SDR path to the new columns.** `CustomerorderCancellationLogRepository` has no `@RepositoryRestResource`, and `RestConfiguration:902` uses `RepositoryDetectionStrategies.ANNOTATED`. The entity has no JPA associations, so no exported repository can write it through an association. No MVC handler writes `reversal_waive*` or `reversal_completed_at` except the service.
- **IDOR.** Every `positionId` must be in `onOrder`, built from `findByCustomerorderId(coId)`, otherwise "position X is not on order Y". Targets are filtered to this order's pending rows. An unknown `coId` is refused.
- **Tenant isolation.** The method is `@Transactional("tenantTransactionManager")`, and all repositories used are tenant JPA repositories. No `@Cacheable` is involved; the only cache on the path is sysprops, whose key includes the tenant. The authz lookup runs against the routed facility DB.
- **Concurrency.** Waive and complete of the same order take the same `FOR UPDATE` lock. Stock-unit writes are protected by `@Version` on `AbstractBaseEntity`, so there are no lost updates on a tote reused across orders. A refused waive rolls back the SBDEV-3316 recovery save (`rollbackFor`).
- **Input validation.** Null, empty or blank `positionIds` and `reason` are refused. The reason is trimmed before the 500 cap. `stockReturned` is a boxed `Boolean` and null is refused. The DB CHECK makes a waived row without a reason or attestation impossible (SQLSTATE 23514).
- **Log injection.** The reason is never logged. Log lines carry only ids and booleans.
- **Seed scope.** `mywms_role.name` is `UNIQUE` on V2.2.00-baselined tenants, so the name match cannot hit duplicate roles there (drifted tenants UNVERIFIED). `WHERE NOT EXISTS` makes a re-run idempotent. The seed cannot reach `outbound-worker`.
- **Refusal rules match plan §3.2** for SHIPPED, ON, PARCEL, UNKNOWN and lock 100 with stock. The tote check fails closed: an unresolvable type, a missing view or a mislabelled tote all read UNKNOWN.
- **Secrets and dependencies.** The diff adds no secrets and no dependencies, so I did not run a dependency audit.

## Security Checklist
- [x] No hardcoded secrets in the diff
- [x] Inputs validated (except the `positionIds` cap, finding 3)
- [x] Injection prevention verified (JPQL only, static SQL migration)
- [~] Authentication/authorization: the route gate is correct; the seed trusts a mutable role name (finding 1)
- [x] No new dependencies to audit
- [ ] Migration ownership and privileges on live tenants: UNVERIFIED (DB MCPs unreachable)

**Verdict: REQUEST CHANGES** (narrow). Harden the V2.2.34 seed so a renamed role cannot receive the grant, and add the per-tenant post-deploy check of who holds the new function (finding 1). Run the table-ownership probe on each prd/UAT tenant before the prd deploy. Findings 2–5 are Low and can go on this ticket or into Phase 2.
