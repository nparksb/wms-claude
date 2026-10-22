---
title: SBDEV-3215 / SBDEV-3183 AC-2 — independent code review, pass 2 (all three commits)
ticket: SBDEV-3215
pr: https://github.com/SiteBossInc/wms2-api/pull/290
branch: bugfix/SBDEV-3215-advice-state-readonly
reviewed_head: 5e70b588fede2dae7e413bcd7acaaf8e4b65d3da
reviewer: independent lane 2 (no prior context on the change)
date: 2026-09-03
verdict: SHIP IT — conditional on the M-1/M-2/M-3 documentation corrections (no behavioural change required)
---

# Independent review, pass 2 — PR #290

Scope: all three commits, with emphasis on commit 3 (`5e70b588`), which had not been reviewed at
all. Pass 1's report (`review-code.md`, commits 1–2) was read for background only; every claim
below was re-derived from primary sources rather than inherited from it.

## Verdict

**SHIP IT**, conditional on three documentation corrections. The change is behaviourally safe:
I independently re-derived the "zero legitimate callers of the bare collection route" claim across
all three consuming repos at `origin/develop`, independently verified the required-item-verb table
against the live UI code, mutation-killed both rails myself, confirmed the sentinel move is
non-vacuous, and reproduced the suite figure exactly. Every finding below is about the accuracy of
a stated claim or a recorded residual — **none is a merge blocker, and none requires a code change
to the exposure configuration.**

| Sev | # | Finding |
|---|---|---|
| Medium | M-1 | `POST /v3/userGroup` and `POST /v3/userRole` are left open on a justification that is true but closes nothing today; absent from the PR's deferred list, and the new sentinel depends on that route staying open |
| Medium | M-2 | Commit 3 and the PR title are labelled "SBDEV-3183 AC-2" but do not satisfy AC-2 as written |
| Medium | M-3 | The `RestConfiguration` caller table's `Location` and `LocationType` rows are wrong on both verb and liveness — the conclusion holds, the cited evidence does not |
| Low | L-1 | `REQUIRED_ITEM_VERBS["LocationType"] = {DELETE}` claims a caller that is dead code |
| Low | L-2 | The `isNew()` reasoning attributes the `em.merge` branch to `id`; on the pinned version it is driven by `version` |
| Low | L-3 | Stale javadoc on `MUST_STAY_WRITABLE` — names one deriver, there are now two |
| Low | L-4 | "Zero callers" is a statement about repo defaults; OMS's endpoint paths are env-overridable |
| Low | L-5 | Both blast-radius sentinels now sit on the one residual M-1 recommends closing |

---

## What I verified independently (and it held)

### 1. Suite claim — reproduced exactly

Re-ran `mvn clean test` in the worktree from scratch:

```
[WARNING] Tests run: 6249, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
```

`6249/0/0/67` — matches the PR claim digit for digit. Zero surefire regressions. I did **not** run
the failsafe/IT lane (known broken, SBDEV-2217) and make no claim about it.

Toolchain note for the next lane: `mvn` is not on `PATH` in this environment. My first run died with
`mvn: command not found` and recorded `EXIT=127`, which in a log tail is indistinguishable from a
test failure. Use
`JAVA_HOME=/home/nampark/.sdkman/candidates/java/21.0.11-ms`
`PATH=/home/nampark/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH`.

### 2. Mutation checks — both rails kill, reproduced from scratch

**Mutant A — remove the exposure call.** Commented out
`configureMustStayWritableCollectionCreateWriteExposure(config);` (`RestConfiguration.java:578`).
`collectionPostIsWithdrawnEverywhere` reds at
`MustStayWritableCollectionPostWithdrawalContextTest.java:110`, and the message names **all seven**:

```
[Section, Boxtype, Client, Cyclecount, Location, LocationType, Sysprop]
```

**Mutant B — simulate over-withdrawal.** Flipped `withCollectionExposure` → `withItemExposure`
inside the loop only (`RestConfiguration.java:567`). Two tests red, and the over-gating rail names
the specific resource and verb:

```
requiredItemVerbsRemainExposed:123 [Location must keep [DELETE] exposed — withdrawing
collection POST must not have taken an item verb with a real caller down with it]
  Expecting HashSet: [HEAD, GET, OPTIONS] to contain: [DELETE]
```

Restored and re-confirmed green after each. **`git status` is clean — the worktree was left
untouched.**

> ⚠️ **A trap worth recording, because I fell into it.** My first attempt at mutant B used
> `perl -0pi -e 's|(\.forDomainType\(domainType\)\n\s*)\.withCollectionExposure|$1.withItemExposure|'`
> — a **non-global** substitution. That exact two-line pattern occurs *earlier* in the same file, in
> `configureUnwrittenResourceWriteExposure` (`RestConfiguration.java:443-444`), so the edit landed
> in the wrong method and the mutant **survived** (`EXIT=0`). A surviving mutant read as "the rail
> is vacuous" when in fact the rail was never challenged. Aim file-scoped mutants at a *method*
> (I re-did it with a Python `re.search` on the method body plus an
> `assert body.count('.withCollectionExposure') == 1`) and print the `git diff` before running, or
> a mis-aimed mutant becomes a false finding.

### 3. "Zero legitimate callers of the bare collection route" — re-derived, holds for all 7

SDR resource paths confirmed from the annotations, not assumed —
`SectionRepository.java:13` `section`, `BoxtypeRepository.java:13` `boxtype`,
`ClientRepository.java:19` `client`, `LocationRepository.java:20` `location`,
`LocationTypeRepository.java:11` `locationType`, `SyspropRepository.java:15` `sysprop`,
`CyclecountRepository.java:15` `cyclecount`. Both UIs' axios `baseURL` ends in `/v3`
(`wms2-web-ui/nuxt.config.js:93,195`; `wms2-mobile-ui/nuxt.config.js:72,130`), so a bare-route call
would read `$post('/client', …)`.

- **`wms2-web-ui`** (`origin/develop` `ad5159c`) — I enumerated all 314 axios write-verb call sites,
  then resolved every one whose first argument is not a plain literal. Exactly one is genuinely
  dynamic (`store/admin/labelPrinting.js:256`, `$post(url, payload)`); its four callers all pass
  `/labelPrinting/*` literals (`:274,:282,:290,:298`). **No bare-collection write.** My grep was
  name-anchored, not slash-anchored, so the leading-slash trap from the earlier review is covered.
- **`wms2-mobile-ui`** (`origin/develop` `e8a2e97`) and **`oms-laravel-api`** (`origin/develop`
  `8ccad384`) — swept in a dedicated lane with positive controls. Mobile: 34 real write sites, all
  inline literals, all MVC subpaths; cycle-count writes go to `/cycleCountLos/*`. OMS: every WMS URL
  derives from the 25 `endpoints.*` keys in `config/wms.php` plus one inline literal, through a
  single dispatcher (`WmsApiService.php:362-372`). The two keys that *are* bare collection routes —
  `client_list` = `v3/client` and `boxtype_list` = `v3/boxtype` — are reachable only via
  `getFromWms()`, which **hardcodes `'GET'`** (`WmsApiService.php:3647`). **No bare-collection
  write in either repo.**

The distinct-path claims check out in the API too: `BoxTypeController.java:24` is `/v3/boxType`
(capital T) against the SDR `/v3/boxtype`; `CycleCountController.java:38` is `/v3/cycleCount`;
`SystemPropertyController.java:35` is `/v3/systemProperty`. Those three genuinely do not collide.
(`SectionController.java:20`, `ClientController.java:32` and `LocationController.java:31` *do* share
the SDR base path — the javadoc's "most on a DIFFERENT controller mapping" is correctly hedged with
"most".)

### 4. `withCollectionExposure` really does leave the item verbs alone — table verified against the UI

I checked every row of `REQUIRED_ITEM_VERBS`
(`MustStayWritableCollectionPostWithdrawalContextTest.java:61-69`) against live UI code rather than
trusting the map, tracing each store action to a dispatching component so a dead action could not
pass as a caller:

| Resource | Verb | Live caller | ✓ |
|---|---|---|---|
| Client | PATCH | `editShipper.vue:206` → `store/admin/shippers.js:59` `$patch('/client/${id}')` | ✓ |
| Cyclecount | PATCH | `plannedCycleCountDescription.vue:92` → `store/internalOps/cycleCount.js:250` | ✓ |
| Section | DELETE | `section.vue:244` → `store/masterData/section.js:73` | ✓ |
| Boxtype | PUT | `editPackagingDialog.vue:142` → `store/masterData/packaging.js:116` | ✓ |
| Boxtype | DELETE | `packaging.vue:285` → `store/masterData/packaging.js:89` | ✓ |
| Location | DELETE | `storageLocation.vue:281` → `store/masterData/storageLocation.js:73` | ✓ |
| Sysprop | PUT | `editParamAndConfig.vue:160` → `store/admin/configuration.js:127` | ✓ |
| Sysprop | DELETE | `deleteParamAndConfig.vue:47` → `store/admin/configuration.js:179` | ✓ |
| LocationType | DELETE | `store/masterData/locationType.js:99` — **zero dispatchers** | ✗ see L-1 |

Plus OMS's `PATCH v3/client/{id}` (`WmsApiService.php:3281`), unaffected — the withdrawal touches
`COLLECTION` only. 8 of 9 rows are correct; the map is over-permissive by one row, never
under-permissive, so no live caller can break.

### 5. The `UserGroup` sentinel is genuinely non-vacuous

The claim that only `UserGroup`'s ASSOCIATION and ITEM exposures are restricted holds. In
`RestConfiguration.java`: `:267-268` disables association writes, `:278-280` disables item
PATCH/DELETE only (PUT survives for `store/admin/group.js`). **Nothing restricts its COLLECTION
exposure**, and `UserGroup` is absent from `SDR_WRITE_WITHDRAWN` (`:391-437`). So
`POST /v3/userGroup` is still published, both moved assertions
(`SdrWriteExposureUnitTest.java:204-205`, `AccessChainSdrWriteExposureUnitTest.java:266`) are
protective rather than silently vacuous, and they would still catch an unscoped global
`withCollectionExposure`. The "SENTINEL MOVED" convention was followed as documented. See L-5 for
the maintenance consequence.

### 6. The mechanism claim — verified against the actually-pinned versions

`spring-data-commons 3.5.7`, `spring-data-jpa 3.5.7`, `spring-data-rest-webmvc 4.5.7` confirmed, via
the Boot 3.5.9 parent → `spring-data-bom 2025.0.7`; no `spring-data*.version` override in
`pom.xml`, and the project's `spring-cloud-dependencies:2025.0.1` import manages no `spring-data`
artifact. All 8 entities extend `AbstractBaseEntity` with `@Version` at
`AbstractBaseEntity.java:34-35` and public `setId`/`setVersion` (`:41-43`, `:65-67`).
`SimpleJpaRepository.save` (3.5.7 sources, `:647-659`) branches on `isNew`. And the
`@ReadOnlyProperty` asymmetry is real: an exhaustive scan of both REST jars finds `isWritable`
in exactly 4 + 1 files, and the three consulting sites are precisely the three the javadoc names —
merge-PATCH (`DomainObjectReader.doMerge:253`), PUT-with-existing
(`MergingPropertyHandler:686-688`), JSON-Patch (`JacksonBindContext:73`) — while the collection-create
path (`PersistentEntityResourceHandlerMethodArgumentResolver`, the 3-arg `read` at **`:233-241`**,
`converter.read` at `:237` — the cited line numbers are accurate for 4.5.7) consults none. The
`Cyclecount` javadoc correction in commit 3 is therefore right on the merits: the bypass is a
property of the mechanism, not of which fields carry the annotation.

### 7. Commit 1's dead-code deletion — confirmed dead

`toggleEnableReceivingById` has zero references anywhere in `src/main`. The surviving MVC endpoint
`ClientController.toggleReceiving` (`:179-189`) uses `clientRepository.findById(...)` +
`save(...)`, not the deleted `@Modifying` query. The deletion is safe.

### 8. Process / scope — compliant

`SBDEV-3183` is at **`in development`**, not `on dev` or later, so folding AC-2 work onto the
existing parent ticket is exactly what the ticket policy prescribes; the `on dev`+ carve-out does
not apply. Bundling into a branch named for SBDEV-3215 is cosmetically awkward (a future
`git log --grep SBDEV-3183` finds this work under a 3215 branch) but not a process violation. The
PR's deferred list — item-verb residuals on Client/Section/Location/LocationType/Boxtype/Sysprop,
and `Client.enablereceiving`/`printerreceivingId` blocked on AC-5 — is accurate as far as it goes;
M-1 is the one thing missing from it.

---

## Findings

### M-1 (Medium) — `POST /v3/userGroup` and `POST /v3/userRole` stay open, on a reason that is true but closes nothing today

`RestConfiguration.java:558-560` excludes `UserGroup` and `UserRole` from
`MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN`, and
`MustStayWritableCollectionPostWithdrawalContextTest.java:51` encodes that as
`RULED_ELSEWHERE = Set.of("UserGroup", "UserRole")` with the comment *"already `SdrFunctionRules`-ruled
— a different mechanism, out of scope here."*

The mechanism claim is **correct**: `SdrFunctionGuard` is deliberately verb-blind
(`SdrFunctionGuard.java:33-36`, *"Nothing here inspects the HTTP method … and to any write verb
Spring Data REST still publishes for it"*), and both types carry rules
(`SdrFunctionRules.java:190`, `:202`). SBDEV-3183's own description agrees, and lists exactly these
two as the ruled pair.

What the justification omits is the qualifier the guard's own javadoc attaches four lines later:
*"so **at an enforcing mode** this also closes PUT/PATCH/DELETE on them"* (`:42`). Every tenant is
at `OFF` — SBDEV-3183 states it twice (*"Effective enforcement, any tenant: none"*, and AC-5:
*"Adding rules while every tenant stays `OFF` closes nothing; do not report it as closed"*), and my
own test-run startup log reproduces it:

```
SdrRuleStartupCheck: Spring Data REST read guard: 35 exported domain type(s), 5 ruled, 30 unruled.
Mode is per-tenant via sysprop WMS2_SDR_READ_GUARD_MODE (absent or unparseable => OFF).
```

So today `POST /v3/userGroup` and `POST /v3/userRole` remain reachable by a zero-function
`wms_user` for the *identical* `em.merge`-over-an-existing-row bypass this PR closes on the other
eight — on the two **access-chain** types. And the create path is *worse* here than the item verbs
already fenced on these types: `UserGroup.roles` is the `@ManyToMany` onto
`mywms_group_mywms_role`, i.e. hop 2 (`UserGroup.java:22-28`, `cascade = CascadeType.PERSIST`), and
the collection-create path binds linkable associations through `UriStringDeserializer`
(`PersistentEntityJackson2Module`'s `AssociationUriResolvingDeserializerModifier`) — whereas
`RestConfiguration.java:272-274` records that item PUT is safe precisely because *"mergeForPut skips
linked associations."* A body of the shape
`POST /v3/userGroup {"id":…, "version":…, "roles":["/v3/userRole/<privileged>"]}` is therefore the
same hop-2 escalation that `:96-100`, `:199-214` and `:265-268` exist to prevent, arriving by an
uncovered fourth route.

The internal tension makes this worth fixing rather than merely noting: **the same commit relies on
`POST /v3/userGroup` being open** as its replacement sentinel. The PR simultaneously describes the
type as "ruled … out of scope" and uses the openness of that exact route as a test fixture.

Not introduced by this PR, and I am **not** proposing it be closed inside it — that is a T3-shaped
decision (access-chain, `@ManyToMany` rebinding, guard-mode interaction) and per the ticket policy
should be **proposed to Nam, not filed**. What this PR should do is cheap and purely additive:

1. Extend the `RULED_ELSEWHERE` comment and the `RestConfiguration` javadoc to say *ruled, therefore
   closed **only at an enforcing mode**, and every tenant is at `OFF`* — cite AC-5.
2. Add `POST /v3/userGroup` / `POST /v3/userRole` to the PR description's deferred list, which
   currently omits them entirely.

### M-2 (Medium) — commit 3 is labelled "SBDEV-3183 AC-2" but does not satisfy AC-2

Commit subject: *"SBDEV-3183 AC-2: withdraw collection POST on the 7 remaining kept-writable
types."* PR title: *"SBDEV-3215 + SBDEV-3183 AC-2."*

AC-2 reads: *"The 9 unruled kept-writable resources **each either carry a rule or a recorded
per-resource decision for why they stay open**."* The nine are `Section, Advice, Boxtype, Client,
Customerorder, Cyclecount, Location, LocationType, Sysprop`. This PR delivers a **collection-POST-only
withdrawal** on eight of them (`Customerorder` is already fully withdrawn,
`RestConfiguration.java:391`), adds no rule, and explicitly defers the item-verb residuals. That is
real progress on AC-2 and is honestly described in the PR *body* — but it is not AC-2, and the
commit subject and PR title read as delivering it. On a ticket whose own AC-5 says *"do not report
it as closed,"* the label should carry the qualifier: `SBDEV-3183 AC-2 (partial — collection POST
only)`. Cheap, and it stops AC-2 being ticked on the strength of this merge.

### M-3 (Medium) — the caller table's `Location` and `LocationType` rows are wrong on both verb and liveness

`RestConfiguration.java`'s new javadoc table asserts:

```
Location      -> PUT  /location/create             (LocationController @ /v3/location)
LocationType  -> PUT  /location/createLocationType (LocationController @ /v3/location)
```

Two problems, both verifiable statically:

1. **The verb does not exist on those handlers.** `LocationController.java:63` is
   `@PostMapping(path = "/create")` and `:107` is `@PostMapping(path = "/createLocationType")` —
   POST, not PUT. Meanwhile the UI genuinely does send PUT
   (`store/masterData/storageLocation.js:118` `$put('/location/create')`,
   `store/masterData/locationType.js:63` `$put('/location/createLocationType')`). UI verb ≠ handler
   verb, so those two calls cannot reach the handler the table names. The inversion is symmetric and
   systematic across the whole controller — the UI *POSTs* `/location/update` and
   `/location/updateLocationType` while `:85` and `:129` are `@PutMapping` — four verb-mismatched
   routes in one controller. All pre-existing and out of scope here; flagged because the table rests
   on two of them. (Established by reading the annotations and the store files; I did not execute a
   request.)
2. **Both cited UI actions are dead code.** On `origin/develop`, `createStorageLocation` and
   `createLocationType` have **zero dispatchers** — the only dispatches into those two stores are
   `getLocationTypes` (`locationType.vue:208`) and, for storage locations,
   `getStorageLocations` / `deleteStorageLocation` / `getStorageLocationDetail` /
   `exportStorageLocations` (`storageLocation.vue:242,281,287,314`). `updateStorageLocation` and
   `updateLocationType` are dead too. This is the same shape as the `updateCustomerOrder` dead-code
   finding already recorded at `SdrWriteWithdrawalContextTest.java:38-40`.

**The conclusion is unaffected** — I re-derived independently that no caller writes to the bare
`/v3/location` or `/v3/locationType` collection route, so the withdrawal is safe on both. But for
2 of 7 rows the *evidence offered* is not what the code does, and a future reader auditing the
withdrawal from this table would be misled. Correct the two rows to say what is actually true:
the store actions are undispatched dead code and verb-mismatched against the controller, so neither
resource has a live create path at all.

### L-1 (Low) — `REQUIRED_ITEM_VERBS["LocationType"] = {DELETE}` claims a caller that is dead

`MustStayWritableCollectionPostWithdrawalContextTest.java:67`. `deleteLocationType`
(`store/masterData/locationType.js:99`) has zero dispatchers (see M-3), so the "real item-verb
caller" that rail protects does not exist. Harmless in direction — an over-permissive rail cannot
break a screen — but the map's own javadoc (`:57-59`) promises *"the item verb(s) each type's real
caller needs,"* and a follow-up ticket working the item-verb residuals would wrongly treat
LocationType DELETE as load-bearing. Either drop the row or annotate it as unverified.

### L-2 (Low) — the `isNew()` reasoning names the wrong property

`RestConfiguration.java:467-469` says a body carrying `id`, `version` and `state` *"deserializes as
a non-new entity (`AbstractBaseEntity` has a public `setId`/`setVersion`), so
`SimpleJpaRepository.save` takes `em.merge`."* On the pinned spring-data-jpa 3.5.7,
`JpaMetamodelEntityInformation.isNew` (`:225-236`) delegates to the id check **only** when the
version attribute is absent or primitive; `AbstractBaseEntity.java:34-35` is
`@Version private Integer version` — boxed — so newness is decided **solely by the version
property**, ignoring `id` entirely. Consequences: a body with `id` *and* non-null `version` →
`isNew() == false` → `em.merge` (the claim holds, and the javadoc's example body does include
`version`); a body with `id` but no `version` → `isNew() == true` → `em.persist`, and since
`@GeneratedValue(strategy = SEQUENCE)` is in force the supplied `id` is discarded and a **new row**
is created rather than an existing one overwritten. So the attack *requires* supplying `version` —
which is not disclosed in the serialized body (`PersistentEntityJackson2Module:286-288` drops the
version property) but **is** recoverable from the `ETag` header (`ETag.java:87-88`, `:160-168`), so
it costs one extra request. Worth a sentence: it is the reachability argument, and attributing the
branch to `setId` would mislead anyone reasoning about a variant.

### L-3 (Low) — stale javadoc on `MUST_STAY_WRITABLE`

`SdrWriteWithdrawalContextTest.java:145-150` (added in commit 2) says the field was made
package-private *"so `SdrMustStayWritableStateNotPatchableContextTest` can derive its domain-type
list from here."* Commit 3 added a second deriver —
`MustStayWritableCollectionPostWithdrawalContextTest.java:88` and `:130` — and did not update the
comment. Exactly the drift the comment itself warns about.

### L-4 (Low) — "zero callers" is a claim about repo defaults, not deployments

`oms-laravel-api/config/wms.php` defines every WMS path through `env(...)` with a default — e.g.
`client_create` is `env('WMS_CLIENT_CREATE_ENDPOINT', 'v3/client/create')`, `client_list` is
`env('WMS_CLIENT_LIST_ENDPOINT', 'v3/client')`. A deployment setting `WMS_CLIENT_CREATE_ENDPOINT`
to `v3/client` would put a live create on the now-withdrawn bare route with no code change. No
`.env.example` sets any of the `WMS_{CLIENT,BOXTYPE,SHIPPERID,ITEMDATA}_*` variables, so the
in-repo defaults apply and the verdict stands — but a repo sweep cannot see deployed env, and the
javadoc's *"Measured against `origin/develop` … zero legitimate callers"* reads stronger than the
instrument supports. One clause naming the constraint is enough.

### L-5 (Low) — both sentinels now sit on the residual M-1 recommends closing

`SdrWriteExposureUnitTest.java:204` and `AccessChainSdrWriteExposureUnitTest.java:266` now both pin
`UserGroup` collection POST as the "still fully open" control. That is correct today (verified in
§5), and the third move in the chain (`Itemdata` → `Client` → `UserGroup`). But if M-1 is ever acted
on, `MUST_STAY_WRITABLE` will contain **no** member with an open collection POST, and the
"SENTINEL MOVED" convention runs out of candidates — the next author's cheapest option becomes
deleting the pin, which is how blast-radius coverage is lost (the comment at
`AccessChainSdrWriteExposureUnitTest.java:244-246` says so in as many words). Worth a forward note
now, and worth considering asserting the `forDomainType` scoping *directly* — e.g. that a type with
no rule in this file retains its configured verbs — rather than through whichever live resource
happens to still be open.

---

## Things I could not establish

- **No runtime confirmation of the exposure change.** Everything here is source, bytecode/BOM and
  configuration analysis plus the surefire lane. I did not deploy and did not observe
  `POST /v3/<resource>` returning 405 against a running instance, nor the pre-fix `em.merge`
  overwrite. The context tests assert `ResourceMappings` metadata, which is the configuration, not
  a served response.
- **The failsafe/IT lane was not run** (known broken, SBDEV-2217).
- **M-3's 405 consequence is inferred**, not executed — I read the annotations and the store files
  and did not issue a request.
- **Deployed OMS env values** (L-4) are outside any repo sweep.
- **`DELETE /v3/advice/{id}`**, flagged as a pre-existing residual at `RestConfiguration.java:486-488`,
  I did not audit.
- **`Sysprop`'s special status** — SBDEV-3183 warns it holds the guard's own kill switch and was
  fenced at two specific routes. This PR withdraws only its collection POST, which does not touch
  that fencing, but I did not re-verify the fencing itself.
