# Security Review Report: SBDEV-2624 wms2-api half (Phase 3b)

**head:** `086cb309` (worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-2624`, diff `origin/develop...HEAD`)
**Scope:** `SkuRestController` (create/update/delete + `resolveForUpdate`), `SkuDto`, `ItemdataRepository` (`findByIdAndClientId`, `saveAndFlush`), `StockrecordRepository.renameItemdataForClient`, `SkuBatchCreateUpdateService` (`upsertAll`, `rename`, `translate`), `WmsConstants` 108/109. Tests were read only as evidence.
**Risk level:** LOW

## Summary
- Critical: 0 · High: 0 · Medium: 1 · Low: 4 · Info: 3
- Cross-client: every new lookup is client-scoped. `findByIdAndClientId(id, clientId)` treats another client's id as a miss (AC-3 IT `update_facilityItemIdOfOtherClient_isMiss`, unit `delete_facilityItemIdOfOtherClient_fallsBackToCode`). The cached finders are keyed `tenant:clientId:itemNr`. The native UPDATE binds `client_id = :clientId` (pinned by `StockrecordRenameQueryShapeUnitTest`; IT row `:532` checks that client d's 'A' rows are untouched). I found no path where one client can rename, delete or read another client's itemdata.
- SQL: fully parameterized. There is no concatenation and no LIKE/wildcard, so there is no injection surface.
- SDR: `findByIdAndClientId` and `saveAndFlush` are both `@RestResource(exported = false)`. `Itemdata.class` is in `SDR_WRITE_WITHDRAWN` (`RestConfiguration.java:498`). `StockrecordRepository` has type-level `exported = false`. No new route.
- Context, not a finding: per Nam's decision, `/rest/**` is internal WMS↔OMS and JWT is deferred. So "crafted request" below means a misbehaving or mis-mapped OMS, not an internet attacker.

## Medium

### M1. Rename-by-id without `previous_sku` is unconditional on the WMS side; the CAS is opt-in by the caller
**Category:** A04 Insecure Design / A01 (integrity, same-client)
**Location:** `SkuBatchCreateUpdateService.java` `rename()`:
```java
if (previousSku != null && !oldCode.equals(previousSku)) { ... throw 108 ... }
if (previousSku == null) {
    // A plain edit that found the row by id: the recovery path for an earlier failed rename.
    LOG.warn("SBDEV-2624 SKU_RENAME_BY_ID_RECOVERY ...");
}
```
**Exploitability:** an internal caller (or an OMS defect) sends `facility_item_id` with no `previous_sku`.
**Blast radius:** one item of the same client is renamed to the request SKU, and every `stockrecord` row of that client carrying the old code is rewritten (up to about 44k rows on WineCo prd). Reversible by renaming back, but not cleanly: the reverse rewrite also takes any (client, B) stockrecord rows that already existed.
**Scenario:** D-M2 moved the guard to the OMS. The OMS always sends `previous_sku`, and only its bad-map-guarded 108 resend drops it. wms2 enforces nothing, though. A wrong map row is enough: ShipItEZ runs two facilities with separate id sequences, and client ids can coincide across facility DBs. That wrong row combined with any OMS code path that omits `previous_sku` (an old OMS build during the deploy window, another caller, a future regression) silently renames the wrong product. The §11 S1 mitigation relies on OMS-side behaviour that the WMS cannot check.
**Fix (cheap, keeps AC-2a recovery):** have the guarded resend send the code that the 108 reported (`"item_id=X is D"`) as `previous_sku = D`. The CAS then still runs and only passes against the exact row state the OMS observed. wms2 can then refuse an id-found rename without `previous_sku`:
```java
// BAD
if (previousSku == null) { LOG.warn("...BY_ID_RECOVERY..."); }   // proceeds unconditionally
// GOOD
if (previousSku == null) {
    LOG.warn("SBDEV-2624 SKU_RENAME_PRECONDITION clientId={} itemId={} itemNr={} previousSku=null sku={} via={}",
            clientId, itemId, oldCode, code, via);
    throw new WebserviceBusinessExceptionClientSide(WmsConstants.SKU_RENAME_PRECONDITION_FAILED, null,
            "item_id=" + itemId + " is " + oldCode, "expected <previous_sku required for rename>");
}
```
This is a contract change (OMS resend plus the AC-2a test). It needs Nam's call, because D-M2 says "wms2 is unchanged". If it is declined, record it as accepted residual risk in §11 S1.

## Low

### L1. `upsertAll` reloads the row unscoped and rewrites stockrecord with the request `clientId`, not `row.getClientId()`
**Category:** A01 (defence in depth)
**Location:** `SkuBatchCreateUpdateService.java`:
```java
Itemdata row = existing != null ? itemdataRepository.findById(existing.getId()).orElse(null) : null;
...
int n = stockrecordRepository.renameItemdataForClient(clientId, oldCode, code);
```
**Scenario:** `existing` can come from the `@Cacheable` finder. If a cached entry's row ever changes `client_id`, the item of client c2 is renamed while client c1's stockrecords are rewritten, which is a cross-client write. Today `itemdata.client_id` is immutable in app code: the only setters are the create paths `FileImportController:406` and `SkuBatchCreateUpdateService:90`, and SDR writes are withdrawn. That makes this unreachable without an out-of-band DB edit.
**Fix:** one line, which makes the invariant explicit:
```java
if (row != null && !Objects.equals(row.getClientId(), clientId)) { row = null; } // treat as miss
```
or pass `row.getClientId()` to `renameItemdataForClient`.

### L2. The delete fallback (no `facility_item_id`, or an id miss) has no code CAS; only `@Version` blocks a wrong-row delete
**Category:** A04
**Location:** `SkuRestController.delete`: `itemData = itemdataService.findByClientIdAndItemNr(client.getId(), sku.getSku());` (cached), then `itemdataRepository.delete(itemData.get())`.
**Scenario:** item X is renamed A→B on replica 1. Replica 2's Caffeine cache still maps `c:A → X` for up to 5 min (G4). A delete of `{sku:A}` on replica 2 resolves to X, which is now B. `SimpleJpaRepository.delete` merges the stale detached entity. Because the rename bumped `@Version`, the merge throws `ObjectOptimisticLockingFailureException` and nothing is deleted. The outcome is an unhandled 500 (only `WebserviceBusinessExceptionClientSide` is caught), and the protection is incidental. Renames are what make code→id cache entries semantically stale, which is new with this ticket. Exposure needs multi-replica Caffeine (Q5 open).
**Fix:** apply the same CAS used on the id path after any cached resolution:
```java
if (itemData.isPresent() && !itemData.get().getItemNr().equals(sku.getSku())) { throw 108 ... }
```
Better still, resolve deletes with the uncached `itemdataRepository.findByClientIdAndItemNr`.

### L3. Item-level FOR UPDATE locks accumulate across a multi-rename batch; there is no batch-size cap and no `statement_timeout`
**Category:** A04 / DoS shape
**Location:** `upsertAll` holds one tenant tx for the whole `List<SkuDto>`. Each `rename()` ends in `saveAndFlush(row)`, whose itemdata FOR UPDATE lock is held to commit.
**Scenario:** one request with N renames of hot SKUs. Each request is bounded only by `app.idempotency.max-body-bytes=5242880`, so thousands of DTOs fit. Item k's lock blocks the FOR KEY SHARE that every child-FK insert takes (stockunit, customerorder_position, …) for the rewrites of k+1…n. `lock_timeout` (5 s, per acquisition) bounds waiters, not the holder: picking and receiving on those SKUs get 5 s waits and then fail, for the whole batch duration. Another client's stockrecord sets cannot be rewritten (client predicate). The plan accepts this in §7.5 #4 (A-r2 N4) because the OMS sends one SKU per update.
**Fix (optional hardening):** reject `/rest/sku/update` batches that contain more than one rename (or more than a small N), or `SET LOCAL statement_timeout` for the rename tx:
```java
long renames = skuList.stream().filter(s -> s.getFacilityItemId() != null || (s.getPreviousSku() != null && !s.getPreviousSku().equals(s.getSku()))).count();
if (renames > 1) throw new WebserviceBusinessExceptionClientSide(WmsConstants.PARAMETER_IS_NULL /* or a new code */, null, "batch contains more than one rename");
```

### L4. Log forging through request-controlled SKU strings in the new INFO/WARN audit lines
**Category:** A09
**Location:** `SKU_RENAME`, `SKU_RENAME_PRECONDITION`, `SKU_RENAME_COLLISION`, `SKU_RENAME_BY_ID_RECOVERY`, `SKU_DELETE_PRECONDITION`. Values `sku`, `previous_sku` and `itemNr` are logged through `%msg%n` plain pattern encoders (`logback-spring.xml:9,22`). `normalize()` only `trim()`s, so CR/LF in the middle of a value survive.
**Scenario:** a SKU value containing `\n... SBDEV-2624 SKU_RENAME clientId=…` forges a rename audit line. §7.4 makes these lines the observability contract. The pre-existing DEBUG lines have the same issue, but these run at INFO/WARN in prd.
**Fix:** reject control characters in `sku` and `previous_sku` at validation, which is better since a SKU never legitimately contains them:
```java
if (sku.getSku().chars().anyMatch(Character::isISOControl)) throw new WebserviceBusinessExceptionClientSide(WmsConstants.FIELD_NOT_SET, null, "sku", sku);
```
Alternatively use `%replace(%msg){'[\r\n]','_'}` in the encoder.

## Info
- **I1. Error text exposure (108/109/105):** descriptions echo the item id, the row's current code, and the colliding item id. All of these belong to the requesting client in the requesting tenant DB. `getErrorMap()` returns only `status` + `description`. The stack trace built from the `translate` cause is kept in `WebserviceError.stacktrace` and is not serialized. Acceptable for a private API. Because the 108/109 prefixes are a cross-repo contract, they must not be localized.
- **I2. `previous_sku = ""`:** after trim, an empty string is treated as present. The CAS gives `oldCode != ""` → 108, which fails safe. `resolveForUpdate` skips it. No issue.
- **I3. Batch key collision:** two DTOs with the same (client, sku) but different `facility_item_id` overwrite each other in `existingByClient`. The later resolution wins, and the first DTO's id is ignored (plain update of the other row, no rename, no cross-client effect). This is a correctness edge, not security.

## Secrets / dependencies
- Secrets scan of the 17 changed files: no added credentials. The hits are pre-existing `WmsConstants:1240` `CUPS_SERVER_ADDRESS_PASSWORD_DEFAULT_VALUE` (not in this diff, out of scope) and a Testcontainers `getPassword()` in the IT.
- Dependency audit: `pom.xml` is not in the diff, so the change introduces no new or changed dependencies and no `dependency-check` run was needed for it.

## Security checklist
- [x] No hardcoded secrets added
- [x] Injection prevention: native UPDATE fully bound, no string concatenation
- [x] Cross-client scoping on id lookup, cached finders, stockrecord rewrite (tests pin all three)
- [x] No new SDR route (exported=false on both new methods; Itemdata writes withdrawn)
- [~] Input validation: control chars in SKU not rejected (L4)
- [~] Rename-by-id CAS not enforced server-side (M1); delete fallback CAS incidental (L2)
- [x] Authz on /rest/sku: out of scope per Nam's internal-only/JWT-deferred decision
- [x] Dependencies: unchanged
