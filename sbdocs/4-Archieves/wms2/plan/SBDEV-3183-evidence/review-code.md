# SBDEV-3183 Slice 2 — code review

**Target commit:** `aec71edb` "withdraw 29 caller-less domain types from the SDR surface"
**Parent:** `origin/develop` @ `92ca2e38`
**Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3183`
**Reviewed:** 2026-09-01. Read-only lane; no file in the reviewed worktree was modified.

> ⚠ **HEAD moved during this review.** Three follow-up commits landed after `aec71edb`
> (`36e0f438`, `945bcf3e`, `2616b0ac` — the security lane's Lows). Every finding below was
> re-checked against `HEAD` = `2616b0ac`, and each one states whether it is still live there.
> Findings already fixed by those three are not reported.

**Verdict: DO NOT MERGE.** One High: two of the 29 have a live, menu-reachable production caller,
and withdrawing them breaks the Lock Report screen. The caller-detection claim that cleared them is
false in a specific, reproducible way that also governs the other 27.

| # | Severity | Summary | Live at HEAD? |
|---|---|---|---|
| H-1 | **High** | `LockOverviewDtoView` / `LockOverviewAllDtoView` have a live caller — Lock Report breaks | **yes** |
| M-1 | Medium | "four independent methods" is false; A and C share one blind spot, and it is the one that hid H-1 | **yes** |
| M-2 | Medium | `SdrWriteWithdrawalContextTest` split drops the still-exported pin for 20 read-live types, with no rail | **yes** |
| M-3 | Medium | `SdrFunctionGuard.buildIndex`'s new un-exported skip is untested; the fixture cannot express it | **yes** (from `2616b0ac`) |
| L-1 | Low | `PutawayConfigService:379` — "one of the 54 unruled types" | **yes** |
| L-2 | Low | `PutawayConfigRepositoryEventHandler:482` — "one of the 54 domain types" | **yes** |
| L-3 | Low | `RestConfiguration:289` — "the 48 exported resources", 27 of which are no longer exported | **yes** |
| L-4 | Low | "347 searches" survives in 10 controller files the same series calls unreproducible | **yes** |
| L-5 | Low | `PickingStartedGuardScalarSubqueryIntegrationTest:77` — "reachable only through its SDR export" | **yes** |

Focus areas that produced **nothing**, stated explicitly rather than padded: **internal Java
callers (focus 2) are clean** — see §"Focus 2" below; **the anti-rename property of
`SdrWriteWithdrawalContextTest` genuinely survives the split** (focus 3, first half); **no caller
of the v2 `/v3/<withdrawn>` surface exists in `omsv2-UI`, the two v1 UIs, `v1/qa-api`, `v1/qa-ui`,
`v1/carrier-integration` or `v1/label-automation`** (focus 1, external repos).

---

## H-1 — HIGH — `LockOverviewDtoView` and `LockOverviewAllDtoView` have a live production caller

**Where the caller is.** `v2/wms2-web-ui` @ `origin/develop` `3117acac`,
`store/reports/lock.js:54-66`:

```js
    // SBDEV-2474: default view (lockOverviewDtoView) excludes Shipped locks; the
    // all-view (lockOverviewAllDtoView) includes them for the "Include Shipped Locks" toggle.
    const resource = data.includeShipped ? 'lockOverviewAllDtoView' : 'lockOverviewDtoView'
    let urlPart = '?page=' + (data.page - 1) + '&size=' + data.itemsPerPage + '&keyword=' + data.keyword + ...
      const results = await this.$axios.$get('/' + resource + '/search/findByKeyword' + urlPart)
      const reportItems = results._embedded?.[resource] ?? []
```

`nuxt.config.js` sets the axios `baseURL` to `.../v3`, so the two resolved requests are exactly
`GET /v3/lockOverviewDtoView/search/findByKeyword?...` and
`GET /v3/lockOverviewAllDtoView/search/findByKeyword?...` — the SDR search finders on two of the 29.
`sdr-surface-inventory.tsv:193,196` lists both `.../search/findByKeyword` rows as `SEARCH true GET`,
so the surface being withdrawn is precisely the one being called.

**It is live and menu-reachable, not dead code.** `util/appMenuList.js:110`:

```js
      { text: 'Lock Report', to: '/reports/lock-report', fn: 'WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW' }, // 22
```

→ `pages/reports/lock-report.vue` → `components/reports/lockReport.vue` (dispatches
`reports/lock/searchReport`). The `includeShipped` toggle it drives is SBDEV-2474, shipped and
merged.

**Symptom after this commit.** `RepositoryRestHandlerMapping` stops routing the path, the request
404s, `lock.js`'s `catch` fires and the operator gets
`"Error: Request failed due to a network or server issue. Please retry."` on an empty grid. No test
in `wms2-api` reddens — this is exactly the over-withdrawal failure mode
`SdrUncalledSurfaceNotExportedContextTest`'s own `MUST_REMAIN_EXPORTED` javadoc describes ("a
withdrawn resource a screen needs surfaces as a broken button, not as a red test"), and the rail
did not catch it because the rail lists only the eleven *writable* resources, not the read-live ones.

**Both are still `exported = false` at HEAD:**

```
src/main/java/net/aim_ai/wms/repo/jpa/LockOverviewAllDtoViewRepository.java:24:
@RepositoryRestResource(collectionResourceRel = "lockOverviewAllDtoView", path = "lockOverviewAllDtoView", exported = false)
src/main/java/net/aim_ai/wms/repo/jpa/LockOverviewDtoViewRepository.java:17:
@RepositoryRestResource(collectionResourceRel = "lockOverviewDtoView", path = "lockOverviewDtoView", exported = false)
```

**Fix.**

1. Revert `exported = false` on `LockOverviewDtoViewRepository` and
   `LockOverviewAllDtoViewRepository` (drop the argument; the parent had no `exported` attribute).
2. Remove both from `SdrUncalledSurfaceNotExportedContextTest.WITHDRAWN` and add both to
   `MUST_REMAIN_EXPORTED`, with the `store/reports/lock.js:56` citation — the rail is where this
   belongs, and it converts the near-miss into a permanent pin.
3. Update the "24 with zero mention by every method" bucket in
   `ac1-sdr-surface-classification.md` §B.5 — it currently names both types in a list asserting all
   four methods returned 0, which is false (see M-1). Move them into §B.3/B.4 with their gate
   (`WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW`, from `appMenuList.js:110`) so Slice 3 can rule them.
4. Fix the count literals the change cascades into: 29 → 27, and 33 exported → 35.

---

## M-1 — MEDIUM — "four independent caller-detection methods" is false, and its shared blind spot is what hid H-1

The commit message, `SdrUncalledSurfaceNotExportedContextTest`'s class javadoc, and
`ac1-sdr-surface-classification.md` §B.5 all assert:

> "29 domain types cleared by **four independent** caller-detection methods … a `git grep` over ALL
> tracked files (reaching the `.gitignore`'d `reports/` tree) …"

and §B.5 names `LockOverviewAllDtoView` and `LockOverviewDtoView` in the bucket headed
"**24 with zero mention by every method** … All four returned 0 for each row."

**They are not four independent methods along the axis that matters.** From §B.1's own table,
method **A** is ``git grep -- "/<path>"`` over `*.js *.vue *.ts` and method **C** is the same query
over all tracked files. Both embed the leading slash. Method **B**'s stated blind spot is
"truncates at `${…}` / `' +` concatenation". Method **D** is Cypress-only. `lock.js` never puts the
resource name adjacent to a slash — the slash is contributed separately by `'/' + resource` — so A,
B and C all miss it by one shared assumption, and D never looks at `store/`.

Reproduced:

```
$ cd v2/wms2-web-ui
$ git grep -n -- "/lockOverviewDtoView" origin/develop -- .     # methods A and C, exactly as documented
$ echo $?
1                                                                # zero hits
$ git grep -n -- "lockOverviewDtoView" origin/develop -- .       # the same grep without the slash
origin/develop:store/reports/lock.js:54: ...
origin/develop:store/reports/lock.js:56: const resource = data.includeShipped ? 'lockOverviewAllDtoView' : 'lockOverviewDtoView'
```

Two secondary points worth recording because they were both invoked as reassurance and neither
applied:

- **The `reports/`-gitignore story is a red herring here.** `git check-ignore -v
  store/reports/lock.js` exits 1 — the file is not ignored — and method C found other files in that
  same tree (`store/reports/receiving.js`, `store/reports/data.js` are both cited in §B.3). The miss
  is the leading slash, not the ignore rule. The javadoc's parenthetical brag about reaching that
  tree is doing no work.
- **Method B recorded the call site and then discarded it.** `callsites.tsv:330` literally contains
  the line, with its resolved-path column reduced to a bare `/`:

  ```
  web	store/reports/lock.js:64	/	      const results = await this.$axios.$get('/' + resource + '/search/findByKeyword' + urlPart)
  ```

  The evidence to catch H-1 was collected and then filtered out by the truncation §B.1 documents.
  §E.4 even names the hazard — "A URL assembled in a variable and passed as `$axios.$get(url)` is
  invisible to it. Method C (all-file substring) partially covers this" — but method C is not an
  all-file *substring* search, it is an all-file *path* search, so the stated compensation does not
  exist.

**Fix.** Re-run the sweep with the slash dropped and word boundaries, then re-derive §B.5. For what
it is worth I have already run that corrected instrument over all 29 names across all three
repositories (`git grep -n -i -w "<name>" origin/develop`, plus a separate scan for every axios call
whose URL is a variable rather than a literal):

- **`lockOverviewDtoView` / `lockOverviewAllDtoView` are the only break.** The other 27 survive.
- The only other two computed-URL axios call sites in either UI are
  `store/admin/labelPrinting.js:256` (`$post(url, …)`, values are `/labelPrinting/*` MVC routes) and
  `wms2-mobile-ui/pages/replenish.vue:154,196` (`/replenishOrder/detailView`, MVC). Neither reaches
  any of the 29.
- Near-misses correctly excluded: `/billOfLading/*`, `/customerOrderPosition/detailsByOrderId`,
  `/goodsreceiptposition/*` (MVC, case-distinct), `receivingDtoView` vs `receivedDtoView`,
  `cyclecountPosition` / `pickingorderPosition` as JSON field names.

Also add a permanent line to the class javadoc naming the leading-slash assumption as the blind
spot that produced a real break, not a hypothetical one — the file currently teaches the
`Cyclecount` and `Section` near-misses and would teach this one better, since it actually shipped.

---

## M-2 — MEDIUM — the `SdrWriteWithdrawalContextTest` split drops the still-exported pin for 20 read-live types

The anti-rename property **does** survive — I checked this specifically, and it holds. A renamed
type appears in neither `stillExported` nor `withdrawnEntirely`, so `accountedFor.hasSize(47)` fails.
That half of the change is correct.

What is lost is different. Before:

```java
if (!WITHDRAWN.contains(name) || !md.isExported()) continue;
seen.add(name);
...
assertThat(seen).hasSize(47);
```

that assertion required **all 47 to be exported**. After the split, `withdrawnEntirely` absorbs any
un-export and the test stays green. 27 of the 47 are deliberately withdrawn here; the other **20**
are still exported and now have no assertion that they stay so:

`CustomerorderBatch`, `Goodsreceiptposition`, `Itemdata`, `Itemunit`, `LocationArea`,
`LocationRack`, `Message`, `Pickingorder`, `Printer`, `ReceivingDtoView`, `Replenishorder`,
`Shipperid`, `StockView`, `Stockrecord`, `Stockunit`, `Unitload`, `UnitloadRecord`, `UnitloadType`,
`User`, `ViewWarehouseLocationReport`.

**None of these 20 is in `MUST_REMAIN_EXPORTED`** — that array is the eleven *writable* resources
(`Section`, `Advice`, `Boxtype`, `Client`, `Customerorder`, `Cyclecount`, `Location`,
`LocationType`, `Sysprop`, `UserGroup`, `UserRole`), a set disjoint from the write-withdrawn 47 by
construction. So the two rails between them now cover 11 resources, and 20 read-live ones are
covered by neither. Several are named as outages elsewhere in the same change set —
`SdrFunctionRulesUnitTest` says of one of them *"Itemdata is read by OMS and half the UI; a Slice 1
rule on it is an outage"* — and `ac1-sdr-surface-classification.md` §B.3/B.4 cites a live caller for
essentially all 20.

This is the same class of gap as H-1: an un-export nobody intended passes silently.

**Fix.** Extend `MUST_REMAIN_EXPORTED` from the eleven writable resources to *every resource with a
live caller of any kind* — the 11 writers plus the read-live set from §B.3/B.4, which includes these
20 and (per H-1) the two `LockOverview*` views. Rename the array and its `@DisplayName` accordingly
("every resource with a live SDR caller is still exported"). An equivalent alternative is a third
assertion in `SdrWriteWithdrawalContextTest` pinning `stillExported` to exactly those 20 names, but
the single consolidated rail is better: one place to look, and it is the place H-1 should have been
caught.

---

## M-3 — MEDIUM — the new un-exported skip in `SdrFunctionGuard.buildIndex` is untested

Introduced by follow-up `2616b0ac` (security-review L2), not by `aec71edb`.

`src/main/java/net/aim_ai/wms/security/SdrFunctionGuard.java`, in `buildIndex`:

```java
            if (!metadata.isExported()) {
                continue;
            }
```

The reasoning is sound and I agree with the change. But it is a **behaviour change to main code
with no test that can observe it**. Every fixture mapping in `SdrFunctionGuardUnitTest` is
hard-coded exported:

```java
    private static ResourceMetadata metadata(Class<?> domainType, String path) {
        ...
        when(md.isExported()).thenReturn(true);
        return md;
    }
```

No call site anywhere in the test constructs an un-exported one, so deleting the two-line skip
leaves the whole suite green. The commit's own rationale is that Slice 2 "took the un-exported
population from 4 to 33, multiplying a latent condition by ~8" — that is the argument for pinning
it, not for trusting it. It also sits directly against this project's standing rule to
mutation-check every new assertion.

**Fix.** Add an overload `metadata(Class<?>, String, boolean exported)` (keep the 2-arg form
delegating with `true` so no existing call site changes), then a sibling to
`duplicateExportedPathIsDetected`:

```java
    @Test
    @DisplayName("an un-exported mapping sharing a path is skipped, so the exported one wins")
    void unexportedMappingIsNotIndexed() {
        SdrFunctionGuard g = new SdrFunctionGuard(accessService, new SdrFunctionRules(), modeProvider,
                () -> new FakeMappings(List.of(
                        metadata(UserGroup.class, "clash", false),   // withdrawn — must not be indexed
                        metadata(Itemdata.class, "clash", true))),   // live
                meterRegistry);
        ...
        assertThat(verdict.domainTypeLabel()).isEqualTo("Itemdata");
        assertThat(meterRegistry.find("wms2.authz.sdr.path_collision").counters()).isEmpty();
    }
```

Ordering the un-exported entry **first** is what makes it a real mutant kill: without the skip,
`putIfAbsent` gives the label `UserGroup` and fires the collision counter. Mutation-check it by
deleting the skip and confirming red.

---

## Low findings

### L-1 — `PutawayConfigService.java:379` still says 54

```java
        //    Slice 1 does not add: Sysprop is one of the 54 unruled types.
```
33 exported − 5 ruled = **28**. `2616b0ac` claims *"Corrected across 10 files to 33 exported / 5
ruled / 28 unruled"*, but its diff touches only the `security` package plus `RestConfiguration`;
this file and L-2's are outside it. That "across 10 files" is itself a mild completeness overclaim.
**Fix:** `54` → `28`.

### L-2 — `PutawayConfigRepositoryEventHandler.java:482` still says 54

```java
     * must-stay-writable list) and is one of the 54 domain types Slice 1 does not rule, so the guard allows
```
**Fix:** `54` → `28`. Same sweep as L-1.

### L-3 — `RestConfiguration.java:289` — "the 48 exported resources"

```java
     * SBDEV-3157 — the 48 exported resources that accept writes over Spring Data REST and have <b>no
     * writer anywhere</b>. Their write verbs are withdrawn; their reads are untouched.
     ...
     * the rest of SBDEV-3157. These 48 do not need it — nothing writes to them, so the verb can simply go.
```
The `48` is inherited verbatim from `origin/develop` (and already disagrees with the array's own
47 — `SdrWriteWithdrawalContextTest` records *"correction moved the split to 47/11"*), so the number
is pre-existing. What **this** commit makes newly false is the adjective: 27 of those resources are
no longer exported at all, and "their reads are untouched" is now wrong for them.
**Fix:** rewrite as "the 47 resources SBDEV-3157 found accepting writes with no writer anywhere; 27
of them were subsequently un-exported entirely by SBDEV-3183 Slice 2, so for those the reads are
gone too", and reconcile 47 vs 48 or say the discrepancy is unresolved.

### L-4 — "347 searches" survives in 10 controller files

Ten files carry the identical boilerplate `// … but SDR READS remain ungated (347 searches), so this
…`: `BillOfLadingController`, `UnitLoadController`, `GoodsReceiptPositionController`,
`ReceivingController`, `SectionController`, `PrinterController`,
`FixLocationAssignmentController`, `CustomerOrderBatchController`, `ReplenishOrderController`,
`FileImportController`.

Meanwhile the same commit series retires that figure in two other places —
`RestConfiguration.java:349` (*"the documented 347 does not reproduce (a runtime enumeration
measured 336…)"*) and `SdrWriteWithdrawalContextTest.java:49-51` (*"Do not quote either number
without re-deriving it"*). Leaving 10 copies of a number the codebase has just declared
unreproducible, and which Slice 2 further reduced by withdrawing 29 types, is the drift those two
corrections were written to stop.
**Fix:** in all 10, replace `(347 searches)` with `(most exported searches — see
RestConfiguration's note; re-derive rather than quoting a figure)`.

### L-5 — `PickingStartedGuardScalarSubqueryIntegrationTest.java:77`

```java
 * <b>zero production callers</b> and is reachable only through its Spring Data REST export at
```
`PickingorderPositionRepository` is one of the 29, so after this commit the method it guards has no
reachability at all — no production caller and no SDR route. The test itself stays green (it drives
raw JDBC, not HTTP), but its stated justification for existing is now false, and a later reader
following that sentence will look for a route that no longer exists.
**Fix:** append that SBDEV-3183 Slice 2 un-exported the repository, so the SDR route is gone and the
test now pins the SQL against a future re-export rather than a live path. Decide explicitly whether
the test still earns its place.

---

## Focus 2 — internal Java callers: clean

Swept `src/main` and `src/test` for everything that could depend on export rather than on the bean.
Nothing found. Recorded so the negative is auditable:

- **`RepositoryEntityLinks` / `EntityLinks` / `linkFor` / `Link.of` / `EntityModel` /
  `RepresentationModel` — zero matches anywhere.** `RepositoryEntityLinks.linkFor(X.class)` throws
  `IllegalArgumentException` for an un-exported type; there is no such call site. The only
  link-builder in the codebase is `RepositoryLinksResourceProcessor:16`, which links
  `TokenController`, not a domain type.
- **`@Projection` — zero real usages** (comments only).
- **`@RepositoryEventHandler` — one class**, `PutawayConfigRepositoryEventHandler`, handling
  `Itemdata`, `Client`, `Sysprop`. None of the 29, so no handler is silently disarmed.
- **`ResourceMappings` read at runtime by main code** — only the `SdrRuleStartupAssertion` /
  `SdrRuleStartupCheck` / `SdrFunctionGuard` cluster. The boot check is the coupling the commit
  correctly handled: after the three rule deletions, `SdrFunctionRules`' live rules are `User`,
  `UserFunction`, `UserGroup`, `UserGroupUser`, `UserRole`, none of them among the 29, and
  `productionOverrides()` returns `Map.of()`. The boot check does not trip.
- **`UserRoleUserFunctionRepository`** — `AccessService:203-205` (`findByRolelistIdAndFunctionlistId`
  inside a `delete`), `:328`, `:356` (`findByRolelistId`); plus `UserRoleService` and
  `UserFunctionService`. All plain injected-bean calls. `exported = false` removes the route, not
  the method. Unaffected.
- **`LosSequencenumberRepository`** — two callers, both bean calls:
  `SequenceTransactionService.getNextSequenceNumber` (`findByClassnameForUpdate`, `@Lock`
  `PESSIMISTIC_WRITE`, `REQUIRES_NEW`) and `LabelPrintingService:968` (`findByClassname`). Neither
  goes over HTTP. A repo-wide grep for `RestTemplate` / `WebClient` / `HttpClient` finds only
  Keycloak/OAuth2 usage and one commented-out `RestTemplate` — **there is no self-call over HTTP to
  any `/v3/` path**, so the write path of the product is untouched.
- **No test issues a MockMvc / RestAssured / TestRestTemplate request against any of the 29 paths.**
  The three that mention such a path (`ReportReadGateUnitTest`,
  `PickingStartedGuardScalarSubqueryIntegrationTest`, `AccessChainSdrWriteExposureUnitTest`) were
  each read: the first two target MVC routes or raw JDBC, the third calls
  `ExposureConfiguration.filter` against a fixture. Consistent with the claimed green suite.

## Focus 1 — external repositories: clean

`v2/omsv2-UI` (React, never searched by the author) has **no WMS backend integration at all** — zero
matches for `/v3`, `wms2`, `wms-api`, `WMS_API`, `wmsApi`; its `.env` holds only Supabase vars.
`v1/qa-ui`, `v1/carrier-integration`, `v1/label-automation` contain no WMS API references.
`v1/qa-api` calls `{wms_base_url}rest/order/finishedQA` and `.../rest/advice/create` — the
`/rest/**` MVC surface, not SDR, and neither path matches any of the 29. `v1/wms-web-ui` and
`v1/wms-mobile-ui` do match several names (`/fixLocationAssignment/search/findByAssignedlocationId`,
`/billOfLading/openBol`, `/customerOrderPosition/detailsByOrderId`,
`/goodsreceiptposition/search/findByAdvicepositionId`) but every one goes through an axios instance
whose `baseURL` is hard-coded to **v1**'s API (`nuxt.config.js:71` / `:56` — `localhost:8088/v3`,
`wms.siteboss.net:8088/v3`, `wms-api.siteboss.net/v3`); they reach `v1/wms-api`, a separate
deployment, and are not callers of this surface. Note the trap: v1's API also serves a `/v3` prefix,
so the path alone does not discriminate — only the host does.

**One gap the review could not close, stated rather than glossed:** `v1/oms` is **not cloned** under
`/home/nampark/dev/wms-claude/v1/`, so it could not be searched by anyone. The class javadoc already
lists it as un-searched, which is honest; this note records that it is not searchable here, not
merely un-searched.

## HAL `_links` following — the vector no static sweep can close

`oms-laravel-api/app/Services/WmsApiService.php:3363-3367` is the one genuine href-following site in
any of the three repos:

```php
$selfHref = $data['_links']['self']['href'] ?? null;
if (is_string($selfHref) && preg_match('#/(\d+)(?:\{[^}]*\})?$#', $selfHref, $matches)) {
    return (int) $matches[1];
}
```

It is fed by `resolveWmsClientId()`, i.e. `GET /v3/client/search/findByClNr` — the `Client`
resource, which is not among the 29 — and it reads `self`, never an association href, so it cannot
land on a withdrawn path. The mechanism the javadoc warns about exists; its single instance is
scoped away from this change. `WmsApiService.php:2430` reads `$body['_embedded']['printer']`, also
not withdrawn. Neither UI follows `_links` at all (every hit is a cosmetic `exclude-fields` list or
`window.location.href`).

`oms-laravel-api` also has the generic-CRUD-helper shape that would defeat all four methods —
`getFromWms(string $facility, string $endpointKey, …)` and
`readWmsCollection(string $facilityCode, string $endpointKey, …)` — but all five call sites pass
literal keys (`client_list`, `boxtype_list`, `shipperid_list`, `itemdata_list`,
`itemdata_by_client`) resolving through `config/wms.php` to `v3/client`, `v3/boxtype`,
`v3/shipperid`, `v3/itemdata*`. None of the 29 appears as a value in that config. It would take a
new call site, not existing code, to reach a withdrawn path this way.

**Association subpaths** (`/v3/<exported>/{id}/<assoc>` where the target is withdrawn): the three
association reads in `wms2-web-ui` — `/user/${id}/groups`, `/userGroup/${id}/roles`,
`/userRole/${id}/functions` — target `UserGroup`, `UserRole` and `UserFunction`, all of which stay
exported. Confirmed against the withdrawal list: none of those three is among the 29, so the three
join tables' withdrawal does not disturb them. `projection=` has zero occurrences in any of the
three repos.

## Mechanism

The `ExposureConfiguration`-cannot-reach-`/search/**` argument is correct and is now pinned by
`2616b0ac`'s addition to `withdrawnDomainTypesAreNotExported`, including a sensitivity control
(`Customerorder` reports 21 searches) that keeps the emptiness assertion from being vacuous. That is
good work and I have nothing to add to it. `SdrWriteWithdrawalContextTest`'s anti-rename property
survives the split, as stated above.
