---
title: "SBDEV-3183 item-verb residuals — independent review (PR #295)"
ticket: SBDEV-3183
pr: "SiteBossInc/wms2-api#295"
branch: bugfix/SBDEV-3183-item-verb-residuals
base: develop
reviewer: independent lane (no prior context on this change)
date: 2026-09-03
verdict: ship it (with two Low + one Medium follow-up, none blocking)
---

# SBDEV-3183 AC-2 item-verb residuals — independent review of PR #295

Reviewed at worktree HEAD `9f8589e9`, base `56fc1035` (merge of PR #290).
Every claim below was re-derived, not inherited from the PR description, the commit message, or the
SBDEV-3215 review reports.

## Verdict

**Ship it.** All six substantive claims hold. The change is correct, the new test is a real
instrument (mutation-checked in both directions, four independent mutations), and the full surefire
lane is green at exactly the claimed figure.

Three findings, none blocking the merge:

| # | Sev | Summary |
|---|---|---|
| M-1 | **Medium** | `unrequiredItemVerbsAreWithdrawn` has no vacuity guard — silently dropping a type from `REQUIRED_ITEM_VERBS` leaves the full suite green. Its sibling test guards exactly this. |
| L-1 | Low | `Advice` item PUT is an unaudited residual on a must-stay-writable type; the sweep and its test javadoc read as if the surface is now fully covered. |
| L-2 | Low | The `Sysprop` caller citation in the new javadoc miscounts and over-claims ("configuration.js: three `$put` call sites … all dispatched" — two are in that file; the third is in `management.js` and is undispatched). |

## Instruments used

- `git grep` against **`origin/develop`** of `wms2-web-ui` (`ad5159c`), `wms2-mobile-ui` (`e8a2e97`)
  and `oms-laravel-api` (`8ccad384`), all freshly fetched — never the local checkouts.
- `mvn clean test` in the PR worktree (`PATH` pinned to sdkman maven + Java 21.0.11-ms).
- Five source mutations of `RestConfiguration.java` / the new test, each run and then restored
  (`diff -q` confirmed byte-identical restore after every one).
- Set-content `diff` on the two withdrawn lists, not a size comparison.

---

## Claim 1 — `LocationType` moves to full write-withdrawal: **VERIFIED**

Independently re-derived, and it holds on four separate axes.

**All three write actions are undispatched.** `git grep` for each action name across
`origin/develop` of `wms2-web-ui` returns *only* its own declaration and its own internal
`console.log` / `context.dispatch('getLocationTypes')` lines:

- `store/masterData/locationType.js:61` `createLocationType` — no call site
- `store/masterData/locationType.js:80` `updateLocationType` — no call site
- `store/masterData/locationType.js:99` `deleteLocationType` — no call site

**The consumer screen is read-only by construction.** `components/masterData/location/locationTypes/locationType.vue`
is the only component that touches the module. Its `mounted()` (`:208`) dispatches
`getLocationTypes` and nothing else; the create button (`:39-56`), the edit button (`:88`) and the
delete button are all **commented out** in the template. This is stronger evidence than the grep —
there is no UI affordance that could reach a write, dispatched or not.

**Verb inversion confirmed against the real annotations** (`controller/LocationController.java`,
`@RequestMapping("/v3/location")`):

| UI dead action | verb it sends | MVC handler | its annotation | matches? |
|---|---|---|---|---|
| `createLocationType` | `$put('/location/createLocationType')` | `createLocationType` `:107` | `@PostMapping` | no |
| `updateLocationType` | `$post('/location/updateLocationType')` | `updateLocationType` `:129` | `@PutMapping` | no |
| `deleteLocationType` | `$delete('/locationType/' + id)` | — (SDR item DELETE) | — | would have hit SDR |

So even a hypothetical dispatcher could not have reached the MVC handlers for two of the three. The
third targets the SDR item route directly — the one this PR closes — and is equally undispatched.

**No caller outside `wms2-web-ui`.** `wms2-mobile-ui`: zero matches for `locationtype` (any case) at
`origin/develop`. `oms-laravel-api`: 20 matches, **all unrelated** — FedEx/UPS address
`location_type` (`HAL`/`ACP`) in `app/DTOs/Label/AddressDto.php`,
`app/DTOs/FacilityLocation/FacilityLocationRequestDto.php`,
`app/Http/Controllers/Api/Legacy/LegacyClientController.php:1168`. No WMS endpoint reference.

**No dynamic/indirect path.** Web-UI has exactly one variable-target `dispatch(...)`
(`components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue:806`); its `action`
comes from `writeActionForScope()` `:760-769`, a closed three-entry map of
`admin/configuration/set{Warehouse,Merchant,Sku}PutawayDestination`. Nothing reaches `locationType`.
There are **zero** variable-URL write calls (`$put(x, …)` / `$axios.delete(x)`) and **zero** HAL
`_links.self.href` writes anywhere in the repo — `editParamAndConfig.vue:156` is a `delete
this.rowData._links` (strips the field before sending), the only non-test `_links` reference.

**Reads survive, as required.** `getLocationTypes` → `$get('/locationType')`, SDR resource path
`locationType` (`repo/jpa/LocationTypeRepository.java:11`). The withdrawal loop
(`RestConfiguration.java:459-473`) disables only `WRITE_VERBS`
(`:28-29` = POST/PUT/PATCH/DELETE), and `SdrWriteWithdrawalContextTest#withdrawnResourcesStillExposeReads`
(`:255-281`) iterates every resource in `WITHDRAWN` — now including `LocationType` — asserting GET on
both the COLLECTION and ITEM axes. Green. **`getLocationTypes` is unaffected.**

---

## Claim 2 — the six per-resource item-verb closures: **VERIFIED, all six**

Method under review: `RestConfiguration#configureMustStayWritableItemVerbWriteExposure`
(`src/main/java/net/aim_ai/wms/RestConfiguration.java:663-699`), registered at `:698`.

I swept both UIs for every `$put` / `$patch` / `$delete` / `$axios.delete` whose path begins with
each of the six SDR resource paths, then resolved each hit to its enclosing store action and searched
for a component that dispatches it. Result — every surviving verb has a real dispatched caller, and
every withdrawn verb has none:

| Resource | Withdrawn | Surviving verb | Store call site | Dispatched from | ✓ |
|---|---|---|---|---|---|
| `Client` | PUT, DELETE | PATCH | `store/admin/shippers.js:59` `$patch(`/client/${id}`)` (`editShipper`) | `components/admin/shippers/editShipper.vue:206` | ✓ |
| `Section` | PUT, PATCH | DELETE | `store/masterData/section.js:73` `$axios.delete('/section/'+id)` (`deleteSection`) | `components/masterData/location/sections/section.vue:244` | ✓ |
| `Location` | PUT, PATCH | DELETE | `store/masterData/storageLocation.js:73` `$delete('/location/'+id)` (`deleteStorageLocation`) | `components/masterData/location/storageLocations/storageLocation.vue:281` | ✓ |
| `Boxtype` | PATCH | PUT, DELETE | `store/masterData/packaging.js:116` `$put`, `:89` `$delete` | `editPackagingDialog.vue:142`, `packaging.vue:285` | ✓ |
| `Sysprop` | PATCH | PUT, DELETE | `store/admin/configuration.js:127` `$put`, `:224` `$put`, `:179` `$delete` | `editParamAndConfig.vue:160`, `warehouseDetails.vue:268`, `deleteParamAndConfig.vue:47` | ✓ |
| `Cyclecount` | PUT, DELETE | PATCH | `store/internalOps/cycleCount.js:250` `$patch(`/cyclecount/${id}`)` (`saveComment`) | `plannedCycleCountDescription.vue:92` (`{id, comment}`) | ✓ |

**No withdrawn verb has a caller anywhere.** Enumerating *every* write call in each implicated store
module (not just those matching the resource prefix) turned up only MVC subpaths for the other verbs
— `$post('/section/create')`, `$post('/client/create')`, `$post('/boxType/create')`,
`$put('/location/create')`, `$post('/location/update')`. `wms2-mobile-ui` has **zero** item writes on
any of the six.

**OMS is clean and its one write survives.** The only OMS write to any of the six is
`PATCH /v3/client/{id}` — `app/Services/WmsApiService.php:3281`, endpoint `client_update` from
`config/wms.php:104`. I resolved all twelve OMS `PUT`/`DELETE` call sites in `WmsApiService` to their
endpoint keys: `sku_create`, `sku_delete`, `order_create`, `order_finished_transfer`,
`advice_create`, `advice_create_transfer`, `advice_hub_and_spoke`, `facility_update` — none touches
the six SDR item routes. `boxtype_list` (`v3/boxtype`) is GET-only; `boxtype_create` and
`client_create` are the MVC `/create` subpaths.

**The surviving verbs really do resolve to SDR, not to a shadowing MVC handler.** This matters
because it is the axis on which a "the caller needs this verb" claim could be wrong in the safe
direction. I checked every controller mapped at one of these base paths:

- `SectionController` `/v3/section` — `@GetMapping` ×3, `@PostMapping("/create")`. **No item-shaped write mapping.**
- `ClientController` `/v3/client` — `@GetMapping` ×5 (incl. `/{id}/effectivePutawayDestination`, GET only), `@PostMapping` ×4. **No item-shaped write mapping.**
- `LocationController` `/v3/location` — `@GetMapping` ×2, `@PostMapping("/create")`, `@PutMapping("/update")`, plus the two locationType handlers. **No `/{id}` write mapping.**
- `BoxTypeController` is `/v3/boxType` and `CycleCountController` is `/v3/cycleCount` — **case-distinct** from the SDR paths `boxtype` / `cyclecount`.
- There is **no** controller mapped at `/v3/sysprop` (`SystemPropertyController` is `/v3/systemProperty`).

So all six surviving verbs are genuinely SDR-served, and disabling them would have broken a live
screen. The over-gating rail (`requiredItemVerbsRemainExposed`) is load-bearing, not decorative —
mutation M3 below confirms it fires.

**The collection-POST withdrawal is not clobbered.** All six types now receive **two** separate
`getExposureConfiguration().forDomainType(X)` registrations — `withCollectionExposure` in
`configureMustStayWritableCollectionCreateWriteExposure` (`:626-635`) and `withItemExposure` in the
new method. Had the second registration replaced rather than composed with the first, collection POST
would have silently re-opened on all six. `collectionPostIsWithdrawnEverywhere` is green at
`checked == 6`, which measures exactly that — the registrations compose. Worth recording explicitly,
because nothing in the PR description reasons about it.

**Association axis: not a gap here.** The `UserGroup`-style finding cannot recur on these types.
Repo-wide there are exactly three JPA association mappings — `User.groups`
(`model/User.java:63`), `UserGroup.roles` (`:22`), `UserRole.functions` (`:27`), all
`@ManyToMany`. **None of the six, and not `LocationType`, carries any `@ManyToMany`, `@OneToMany`,
`@ManyToOne` or `@OneToOne`** — verified by grep over each entity file. SDR therefore generates no
association resource for them, so the new method's omission of `withAssociationExposure` closes
nothing and misses nothing. (`LocationType`'s full withdrawal does disable the association axis
anyway, via the shared loop at `:465`.)

---

## Claim 3 — the new exact-match test is a real instrument: **VERIFIED (4 mutations, both directions)**

`MustStayWritableCollectionPostWithdrawalContextTest#unrequiredItemVerbsAreWithdrawn` (`:142-168`).
Baseline as committed: **green** (`EXIT=0`, 7 tests across the two classes).

| # | Mutation | Result |
|---|---|---|
| M1 | Delete `Section`'s whole `withItemExposure` block from `RestConfiguration` | **RED** — `unrequiredItemVerbsAreWithdrawn`: `"Section exposes [PUT, PATCH] beyond its required [DELETE]"` |
| M2 | Narrow `Cyclecount` to `disable(PUT)` (drop `DELETE`) | **RED** — `"Cyclecount exposes [DELETE] beyond its required [PATCH]"` |
| M3 | **Over-close**: add `PATCH` to `Client`'s `disable(...)` | **RED ×2** — `requiredItemVerbsRemainExposed:135` (`"Client must keep [PATCH] exposed"`) **and** `SdrWriteWithdrawalContextTest` (`"Client /client lost every write verb"`) |
| M4 | Remove `LocationType.class` from `SDR_WRITE_WITHDRAWN` | **RED** — `"LocationType /locationType still exposes [collection:POST, item:DELETE, item:PATCH, item:PUT]"` |

Each mutation named the right resource **and** the right verb set. The over-closure direction (M3) is
caught by two independent rails. `RestConfiguration.java` restored byte-identically after each
(`diff -q` clean).

I did not find any residual under-closure in the committed state: the exact-match assertion is
green with `REQUIRED_ITEM_VERBS` at its committed contents, which by construction means each of the
six exposes *exactly* its required item write verbs and nothing more.

### M-1 (Medium) — the new test can lose coverage silently

`unrequiredItemVerbsAreWithdrawn` (`:147`) and `requiredItemVerbsRemainExposed` (`:128`) both iterate
`REQUIRED_ITEM_VERBS` (`:74-81`), and **nothing pins that map's key set.** Fifth mutation:

> **M5** — delete the `"Boxtype"` entry from `REQUIRED_ITEM_VERBS`.
> Result: **`EXIT=0`, still green.** Boxtype's item verbs simply stop being checked.

This is the identical defect class the sibling test in the same file already guards against — see the
comment at `:112` (*"Sensitivity check — a vacuous pass … would prove nothing"*) and the
`assertThat(checked).isEqualTo(6)` at `:113-116` that the collection-POST test carries for exactly
this reason. The new test inherited the pattern but not the guard.

There is also a forward-drift hole. `REQUIRED_ITEM_VERBS` is a hand-written literal, not derived from
`SdrWriteWithdrawalContextTest.MUST_STAY_WRITABLE` minus `RULED_ELSEWHERE` (`:57`) and
`COVERED_ELSEWHERE` (`:60`). If a future type joins `MUST_STAY_WRITABLE`,
`collectionPostIsWithdrawnEverywhere` reds on `checked == 6` — but the natural repair is to bump that
literal to `7`, which leaves the new type with **zero** item-verb coverage and no signal at all.

**Suggested fix** (a few lines, in the test only):

```java
assertThat(REQUIRED_ITEM_VERBS.keySet())
        .as("every covered must-stay-writable type needs an item-verb row, or its item verbs "
                + "are unchecked — this map is not derived, so it must be pinned")
        .isEqualTo(SdrWriteWithdrawalContextTest.MUST_STAY_WRITABLE.stream()
                .filter(n -> !RULED_ELSEWHERE.contains(n) && !COVERED_ELSEWHERE.contains(n))
                .collect(Collectors.toSet()));
```

That single assertion closes both halves: it reds on M5, and it reds when a new
`MUST_STAY_WRITABLE` type has no row. It also lets `checked == 6` be dropped in favour of a derived
figure. Not merge-blocking — the committed state is correct and mutation-proven; this protects the
*next* change.

---

## Claim 4 — the set arithmetic and the identity invariant: **VERIFIED by content, not by size**

Extracted both lists mechanically and `diff`ed the contents:

- `RestConfiguration.SDR_WRITE_WITHDRAWN` → **49** entries
- `SdrWriteWithdrawalContextTest.WITHDRAWN` (`:102-167`) → **49** entries
- `diff` of the two sorted name lists: **IDENTICAL, zero difference in either direction.** The
  class javadoc's standing claim still holds.
- `MUST_STAY_WRITABLE` (`:168-182`) → **9**: `Advice Boxtype Client Cyclecount Location Section
  Sysprop UserGroup UserRole`.
- `comm -12` of the two sets: **empty** — no resource is in both.
- 49 + 9 = **58**, reconciling with the documented writable-resource total.

`LocationType` is present in `WITHDRAWN` and `SDR_WRITE_WITHDRAWN`, absent from
`MUST_STAY_WRITABLE` and absent from `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` (`:624`, now
six entries). Nothing else moved. The two `hasSize` updates (`:201` 48→49, `:292` 10→9) match the
measured contents.

The javadoc's third "⚠ it is now 49/9 for a third, unrelated reason" paragraph is accurate and, given
that this pair has now been mis-restated three times, the standing instruction to re-derive rather
than quote is the right thing to have written down.

---

## Claim 5 — full suite: **VERIFIED, exactly as claimed**

```
mvn clean test   (PATH pinned: sdkman maven current + java 21.0.11-ms)
[WARNING] Tests run: 6264, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS   Total time: 03:28 min
```

**`6264/0/0/67` — matches the PR claim digit for digit.** Zero failures, zero errors in the surefire
lane. The two classes under review: `SdrWriteWithdrawalContextTest` 3/0/0/0,
`MustStayWritableCollectionPostWithdrawalContextTest` 4/0/0/0. I did not run the failsafe/IT lane
(known pre-existing breakage, SBDEV-2217) and flag nothing from it.

---

## Claim 6 — what the PR's own framing might be missing

### SBDEV-3215 AC-5 (`Client.enablereceiving` / `printerreceivingId`): correctly untouched

The new method's javadoc (`:655-661`) states plainly that closing an item verb removes the *whole*
verb and says nothing about which fields a surviving verb accepts, naming
`enablereceiving`/`printerreceivingId` and AC-5's dependence on the `SdrGuardMode` rollout as
explicitly out of scope. Verified: `Client` item PATCH survives, so that residual is neither closed
nor broken by this PR. No over-claim. Same for `Cyclecount` — `saveComment` sends `{id, comment}`,
but the surviving PATCH still accepts the whole representation; disclosed, not claimed closed.

### L-1 (Low) — `Advice` item PUT is an unaudited residual

`Advice` is one of the nine `MUST_STAY_WRITABLE` types and is excluded from this test class as
`COVERED_ELSEWHERE` (`:60`) on the grounds that it has its own dedicated test. But
`AdviceCollectionPostWithdrawalContextTest` covers **collection POST**, and `Advice`'s field-level fix
covers **`state`** — neither is an item-verb audit. Advice's live item-verb callers, at
`origin/develop`:

- item PATCH — `store/receiving/inboundNotices.js:380` `$patch(`/advice/${id}`)` (`saveComment`), dispatched from `components/receiving/closed/closedNoticeDescription.vue:242`
- item DELETE — `store/receiving/inboundNotices.js:187` `$delete(`/advice/${id}`)`

I found **no** caller for `Advice` item PUT in either UI or in OMS (OMS's advice writes all go to
`rest/advice/create*`, `config/wms.php:37,64,65`). So the same residual this PR exists to close
appears to survive on a seventh must-stay-writable type, and no test covers it.

This is a genuine scope boundary rather than a defect — but the framing overstates the sweep's reach.
`REQUIRED_ITEM_VERBS`'s javadoc now reads *"This is now the FULL required set for each type"* and
*"closed every item verb NOT listed here"*, which is true only of the six enumerated types; the
paragraph does not say Advice is outside it. Either add `Advice` (`Set.of(PATCH, DELETE)`) and extend
the disable list, or narrow that sentence to name the exclusion. `UserGroup`/`UserRole` are a
different matter — genuinely `SdrFunctionRules`-ruled (`RestConfiguration.java:99,267,278,283`) and
correctly out of scope.

### L-2 (Low) — the `Sysprop` caller citation is miscounted and over-claimed

`RestConfiguration.java:679-680` reads:

> `Sysprop  item PATCH withdrawn — PUT and DELETE both survive (configuration.js: three $put call sites, one $delete, all dispatched).`

Measured at `origin/develop`: `store/admin/configuration.js` has **two** `$put` on `/sysprop/{id}`
(`:127` `editParamAndConfig`, `:224` `editWarehouseDetail`) and one `$delete` (`:179`
`deleteParamAndConfig`) — three matching lines total, not three `$put`. The third `$put` is in a
**different file**, `store/admin/management.js:233`, and it is **not dispatched**: the only
`editWarehouseDetail` dispatcher repo-wide is
`components/admin/parametersAndConfiguration/warehouseDetails/warehouseDetails.vue:268`, which
targets `admin/configuration/editWarehouseDetail`. `management.js:233` is a dead duplicate.

So "three `$put` call sites … all dispatched" is wrong on both the count and the file, and "all
dispatched" is false for one of them. **The verdict is unaffected** — `Sysprop` item PUT and DELETE
each have a real dispatched caller either way — but this is the same class of inaccurate caller
citation that pass 2 (M-3) penalised on `Location`/`LocationType`, and the citations are the only
record of how the audit was performed. Suggested wording: *"configuration.js: two dispatched `$put`
(`:127`, `:224`) and one dispatched `$delete` (`:179`); a third `$put` in management.js:233 is
undispatched dead code."*

### Environment-override caveat

The javadoc correctly carries pass 2's L-4 caveat forward. Re-confirmed as real and unchanged in
character: every OMS WMS endpoint is `env()`-overridable (`config/wms.php`), so all cross-repo
statements here describe checked-in defaults. Note that overriding `WMS_CLIENT_UPDATE_ENDPOINT` cannot
change the *verb* — `WmsApiService.php:3281` hard-codes `'PATCH'` — so no override can turn OMS into
a caller of a verb this PR withdraws.

### Guard-mode interaction: none

These closures take effect at `SdrGuardMode` OFF — they are `ExposureConfiguration` decisions made at
context startup, not interceptor rules. Consistent with the existing note at
`RestConfiguration.java:389`. No interaction with the SBDEV-3169 rollout.

---

## Summary of required action

None to merge. Three follow-ups, in priority order:

1. **M-1** — add the `REQUIRED_ITEM_VERBS.keySet()` pin (test-only, ~5 lines). This is the one I would
   actually ask for, ideally in this PR: without it the PR's primary instrument can be silently
   defeated, and the same file already demonstrates the fix.
2. **L-1** — either extend the sweep to `Advice` item PUT or narrow the "FULL required set" sentence
   so the exclusion is explicit.
3. **L-2** — correct the `Sysprop` citation.
