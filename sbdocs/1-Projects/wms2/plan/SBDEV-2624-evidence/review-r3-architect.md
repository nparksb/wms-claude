**Verdict: REVISE (light).** All nine r2 findings are now in the plan body and correct. The new r3 surface is sound on performance, flush semantics, AC-11, error code 109, the backfill keep rule and both deletions. I found one new Medium: a Spring Data trap that can make the create branch send `item_ids {"B": null}`. Two Lows and one Info are listed after it. None of them changes D1–D3, H1/H2 or G6.

I checked against wms2-api `origin/develop` `62c92dd5` and oms-laravel-api `origin/develop` `dad34d7e`.

## A. r2 findings N1–N9

| r2 | In the body? | Correct? |
|---|---|---|
| N1 | Yes: §3.3 create branch, step 5, the translation scope, AC-4d, AC-12 (9 cases) | Yes. The 8 FKs are non-deferrable and every write is flushed inside the wrapper, so nothing new can be raised at commit. AC-4d's latch test passes whether the error comes back as 105 or 109, because it asserts only "422, not 500". |
| N2 | Yes: §3.5 resend, AC-7f, mutant #17 | Yes. Both the race case and the stuck case converge. There is one coverage gap (R2). |
| N3 | Yes: §6 G6 (a)–(c) | Yes. Claim (a) holds: an UPDATE of a stockunit that leaves `itemdata_id` unchanged does not fire the FK trigger, so moves and picks take no KEY SHARE. |
| N4 | Yes: §7.5 #4 | Yes |
| N5 | Yes: AC-16 decoys per reader, §0 R1 | Yes. The cross-client decoy suits `LegacyInventoryAdjustService.php:966` (no client filter). The same-client decoy suits `LegacyWmsController.php:441` and `LegacyProductUpdateService.php:165`. |
| N6 | Yes: §3.5, AC-14, §7.4 | Yes |
| N7 | Yes: §3.5, S3 | Yes |
| N8 | Yes: AC-8c, mutant #19 | Yes |
| N9 | Yes: §5.3 | Yes. It matches `WmsApiService.php:1541`. |

## B. New findings

**R1 — Medium. With `version = 1`, the create branch's `saveAndFlush` merges a copy, so the original entity's id stays null.**
- **Evidence:**
  - `AbstractBaseEntity.java:34-35` declares `@Version private Integer version;`, a wrapper type.
  - The create branch sets `itemData.setVersion(1);` (`SkuBatchCreateUpdateService.java:62`).
  - Spring Data's `JpaMetamodelEntityInformation.isNew` treats an entity with a non-primitive version as new only when the version is null. So `isNew` is false, and `save`/`saveAndFlush` call `em.merge(itemData)`.
  - Merging a transient entity persists a managed copy and returns that copy. The local `itemData` keeps `id == null`.
  - This is harmless today because `:66` ignores the return value. r3 now needs the id ("put the new id in the map", §3.3).
- **Consequence:** if the implementation reads `itemData.getId()`, the create path returns `{"B": null}`.
  - The OMS NULL guard (C5) then silently records nothing.
  - That defeats the return leg (§1) and the stated reason for deploying wms2 first (§5.3).
  - No AC catches it. AC-7a stubs `upsertAll`. AC-4d asserts only the 422. A unit test whose mock `saveAndFlush` sets the id on its argument passes falsely.
- **Fix:**
  - State `Itemdata saved = itemdataRepository.saveAndFlush(itemData); ids.put(sku, saved.getId());`.
  - Add a PG-IT row: create B, then assert the response's `item_ids["B"]` equals `SELECT id FROM itemdata WHERE client_id=c AND item_nr='B'`.
  - Mutant: read `itemData.getId()` instead, which must give "expected <id> was null".
  - Step 5's `row.getId()` is fine, because `row` is managed and merge returns the same instance.

**R2 — Low. The OMS side never tests the 109 resend marker.**
- AC-7f only uses `sku rename precondition failed`. A mutant that drops `sku concurrent modification` from the OMS match list stays green.
- The kept verify row only checks that each OMS marker is a prefix of the wms2 text, not that the resend path uses it.
- **Fix:** parameterise AC-7f over both markers, and add mutant "drop the 109 marker → resend count 0 ≠ 1".

**R3 — Low. On the rename path, `saveAndFlush` could run twice, and the create-branch 105 text has no Y.**
- Step 4c folds in step 5's setters, step 4d calls `saveAndFlush`, and step 5 calls `saveAndFlush` again.
  - The second call is a no-op in SQL, but the plan reads as two calls.
  - An InOrder or `times(1)` check in AC-11 could then flake depending on how it is coded.
  - **Fix:** say that after step 4e the flow goes straight to `ids.put`, and that step 5 is the tail of the non-rename path.
- Separately, the D2 text names Y (`"sku B (item_id=Y)"`). A create-branch duplicate-key error has no Y, and the transaction is already aborted, so it cannot be queried.
  - **Fix:** define a create-branch argument set for the 105 arm, for example `"sku B"`, `"create"`.

**R4 — Info. Matching on the description text is acceptable as specified.**
- The 422 body has no error code. `getErrorMap()` returns only `status` and `description` (`WebserviceBusinessExceptionClientSide.java:46-50`), so the description text is the only signal the OMS can match on.
- `getTechnicalDetails()` carries the untruncated body: `"HTTP {$statusCode}: {$rawResponse}"` (`WmsException.php:40`), fed from `$response->body()` (`WmsApiService.php:406`).
- The leading phrases are plain ASCII, so JSON escaping cannot change them.
- The guard is sufficient: a wms2 unit row pins the template prefix (`WmsConstantsSkuRenameUnitTest`), an OMS fixture uses the literal, and the cross-repo verify row is the drift check. That fits the policy of preferring tests over verify rows.
- Optional hardening:
  - Match `"description":"sku rename precondition failed` rather than a bare substring.
  - Or add `"error_code"` to `getErrorMap()`. That is additive but affects every client-side 4xx body, so it is not worth it on this ticket.

## C. Checks on the new surface (no action)

- **Performance of `saveAndFlush` on a batch create.**
  - The batch size is `SKU_BATCH_SIZE = 200` (`WmsFacilitySyncService.php:43`), not 50.
  - The tenant persistence unit gets no JDBC batching. `hibernate.jdbc.batch_size=25` (`application.properties:92`) never reaches it, because no `setJpaPropertyMap` exists in `src/main`.
  - With `allocationSize = 1` (`AbstractBaseEntity.java:24`) there is one `nextval` per insert either way.
  - The r2 uncached re-check already auto-flushes pending inserts before each next row's query.
  - So the extra cost is about one flush (a dirty check) for the last row: no extra round trips.
  - On the update branch, `findById` + `saveAndFlush` costs the same SQL as today's `save(detached)`, which is a merge, so SELECT + UPDATE.
- **Lock hold on plain updates.** Each update's FOR NO KEY UPDATE lock is now taken at flush instead of at commit. Postgres decides the lock mode from whether a key value actually changes, and here none does. That mode does not conflict with child-FK KEY SHARE, so stock writers are not blocked.
- **AC-11 InOrder.** Because every earlier item is flushed, no stale dirty Itemdata can be auto-flushed by the step-4b native query. This strictly strengthens H2 and supersedes N4's "pending plain updates" note.
- **Error code 109.**
  - The constants run 0, 50, 75, 100–107, then 200 (`WmsConstants.java:1732-1764`), so 108 and 109 are free.
  - The constructor at `WebserviceBusinessExceptionClientSide.java:24-31` fills both the text and the name. The plan's dual-arm row avoids the gap that `NOT_ENABLLED_FOR_RECEIVING` has (`:1749`).
  - Use the bare `%1s, %2s` form only with exactly two arguments. Arity and order matching is what makes that form render correctly.
- **Backfill keep rule and `code_drift`.**
  - `backfillFacilityItemMap` (`:997-1052`) loads no stored ids today. The "identical rule" needs a per-chunk `ProductWmsItem` pluck inside `chunkById(500)` and an id→itemNr inversion of `$itemsByClientId`. Both fit the existing memory footprint.
  - Edge: if code A is still a current SKU of another product of the same client, X is observed twice. The ambiguity guard then suppresses `facility_item_id` for both, and the `previous_sku` path still works. Acceptable; could be one line in S3.
- **Deleting the `backfillWmsItemIds` global write** (`:977-981`) is safe.
  - The only remaining global readers are the three R1 readers, which this plan rewrites, and O2 at `:1644`, which it deletes.
  - No test asserts the backfilled column.
  - The docblock at `:927-930` ("returns no ids") becomes stale; update it.
- **Deleting the dead branch at `:1103`** is safe.
  - Once the `item_id` lookup at `:965-967` is gone, every path that reaches `:1103` has passed the early return at `:972`, whose condition is identical.
  - `$clientCode` is therefore always non-null.

## D. Tradeoff

Flushing every write closes the commit-time 500s. The cost is that a defect which used to be invisible (R1) now matters, because the plan reads ids back. The cost of the fix is one PG-IT row.

## References

- `/Users/np1076/dev/spk/owl/v2/wms2-api` (origin/develop):
  - `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java:20-35`
  - `src/main/java/net/aim_ai/wms/service/SkuBatchCreateUpdateService.java:62,66,78`
  - `src/main/java/net/aim_ai/wms/service/WmsConstants.java:1732-1764,1766-1867`
  - `src/main/java/net/aim_ai/wms/exceptions/WebserviceBusinessExceptionClientSide.java:24-50`
  - `src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java:160-179`
  - `src/main/resources/application.properties:92-93`
- `/Users/np1076/dev/spk/owl/v2/oms-laravel-api` (origin/develop):
  - `app/Exceptions/WmsException.php:38-46`
  - `app/Services/WmsApiService.php:406,1334-1380,1567-1611,1644`
  - `app/Services/WmsFacilitySyncService.php:43,856-981,997-1052`
  - `app/Services/Legacy/LegacyInventoryAdjustService.php:963-990,1094-1110`
- Plan reviewed: `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-2624-evidence/plan-snapshot-r3.md`, §3.3, §3.5, §6 G6, ACs 4d/7f/11/12/15b/16, the 108/109 row, Acceptance.