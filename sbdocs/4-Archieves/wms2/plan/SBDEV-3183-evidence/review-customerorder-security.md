# SBDEV-3183 — adversarial security review of `6280d34c` (Customerorder SDR write withdrawal)

**Reviewer lane:** `sec-co` · **Date:** 2026-09-01 · **Mode:** READ-ONLY, no build run in the reviewed worktree.
**Commit:** `6280d34c` on `feature/SBDEV-3183-customerorder-write-withdrawal`, parent `origin/develop` @ `452d3ed4`.
**Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3183`

> Out of scope by instruction: the "`updateCustomerOrder` is dead code" caller analysis (a parallel lane owns it).
> Where I touched it, it was only to corroborate, and I say so.

---

## Verdict in one paragraph

The change is **correct, and it closes more than the ticket claimed** — pre-commit, `DELETE /v3/customerorder/{id}`
and `POST /v3/customerorder` were open to any authenticated `wms_user`, not just the `PATCH` the ticket named,
and the withdrawal takes all four. The remedy shape (write-verb withdrawal, not a rule, not `@ReadOnlyProperty`)
is the **right** one and is strictly stronger than either alternative. **But it does not close the capability.**
`customerorder.state` remains settable to an arbitrary value, by any authenticated `wms_user`, over
**`GET /v3/customerorder/search/updateStateByIds`** and two sibling `@Modifying` search routes — a surface the
`SDR_WRITE_WITHDRAWN` mechanism **structurally cannot reach**, as this repository's own test comments already
state. `transferlane_id` I believe is genuinely closed on the SDR axis.

| # | Finding | Severity |
|---|---|---|
| **H1** | Three exported SDR **searches** on `CustomerorderRepository` are `@Modifying` `UPDATE … SET state = :state` — reachable by `GET`, untouched by this commit, and no rule covers `Customerorder` at any guard mode | **High** (pending live confirmation — see H1.5) |
| **M1** | The `SdrLockingSearchNotExportedContextTest` invariant covers `@Lock` but **not** `@Modifying`; 29 exported `@Modifying` searches repo-wide have no pin | **Medium** |
| **M2** | `SdrSurfaceInventoryContextTest` hard-codes every SEARCH row as `"read-only"`, so the inventory artifact is blind to H1 by construction | **Medium** |
| **L1** | `/rest/order/cancelPositions` and `/rest/order/finishedQA` write `customerorder.state` **and** null `transferlane_id`, ungated and `permitAll` — known accepted risk, recorded not filed | **Low** (informational) |
| **L2** | Customerorder reads stay fully open to a zero-function principal across 18 read searches incl. PII-ish fields; no `SdrFunctionRules` entry means **even `ENFORCE_RULED` would not gate them** | **Low** (by design; recorded for the record) |
| **L3** | The new test pins `Customerorder` only. A sibling entity added to the kept-ten later gets no equivalent behavioural pin | **Low** |
| — | No availability regression found (Q3) — verified independently | pass |

---

## What I ran vs. what I read

**Ran** (all read-only, all outside the reviewed worktree except `grep`/`sed` inside it):
- `git show 6280d34c`, `git log`, targeted `grep`/`sed` over `src/main` and `src/test`.
- `git grep` over `origin/develop` of `v2/wms2-web-ui`, `v2/wms2-mobile-ui`, `v2/oms-laravel-api`, `v2/omsv2-UI`
  (per the standing rule: cross-repo claims derived from `origin/develop`, not the local checkout).
- Unzipped `spring-data-rest-core-4.5.7-sources.jar`, `spring-data-rest-webmvc-4.5.7-sources.jar` and
  `spring-data-commons-3.5.7-sources.jar` from `~/.m2` into the scratchpad and read the mapping/dispatch code.
- One `Explore` subagent for the MVC call-graph fan-out (its blind spots are carried into L1 below).

**Did not run:** no Maven, no test execution, no live HTTP probe, no DB query. Every claim below that would need
one is marked **[needs live]**.

---

## Q1 — Does this close the capability, or only one route to it?

### Enumeration method, and what it cannot see

I enumerated on four axes:

1. **SDR item/collection/association verbs** — read from `RestConfiguration.java:441-447` and cross-checked
   against the library's `ExposureConfiguration` semantics in the extracted sources.
2. **SDR query methods (`/search/**`)** — read `CustomerorderRepository.java` in full, then confirmed the
   library's exposure rule in `RepositoryResourceMappings.getSearchResourceMappings` and
   `RepositoryMethodResourceMapping`.
3. **JPA associations** — read `Customerorder.java` in full and grepped `@ManyToOne|@OneToMany|@OneToOne|@ManyToMany`
   across the whole `model` package.
4. **MVC + `/rest/**`** — delegated a call-graph walk from the 30 `setState`/`setTransferlaneId` call sites up to
   handler methods.

**What this cannot see:** SpEL/reflective dispatch; anything reaching the columns through a native `@Query` I did
not read (I read every `@Modifying` in `repo/jpa`, but not every native `@Query` body in all 62 repositories);
Flyway/DB-side triggers; non-MVC entry points (outbox consumers, `@EventListener`, JMS); and any consumer outside
the five repos I grepped. Reachability below is static analysis, **not** a live probe.

### 🔴 H1 — `customerorder.state` is still settable by any `wms_user`, over `GET`, via three SDR searches

`CustomerorderRepository` carries three `@Modifying` bulk-`UPDATE` methods. **None** carries
`@RestResource(exported = false)` — unlike its sibling `findByIdForUpdate`, which SBDEV-3169 explicitly closed
three lines above the first of them:

`v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderRepository.java`

```java
@Modifying
@Query("UPDATE Customerorder c SET c.state = :state WHERE c.id IN :ids AND c.state != 800")
int updateStateByIds(@Param("ids") List<Long> ids, @Param("state") int state);
```

```java
@Modifying
@Query("UPDATE Customerorder co SET co.state = :noSection, co.modified = CURRENT_TIMESTAMP "
     + "WHERE co.id = :id AND co.state IN (:raw, :futurePickingDate)")
int markClientHasNoSection(@Param("id") long id, @Param("noSection") int noSection,
                           @Param("raw") int raw, @Param("futurePickingDate") int futurePickingDate);
```

```java
@Modifying
@Query("UPDATE Customerorder co SET co.state = :raw, co.modified = CURRENT_TIMESTAMP "
     + "WHERE co.state = :futurePickingDate AND co.pickingdate <= :today "
     + "AND co.orderbatchId IN (SELECT b.id FROM CustomerorderBatch b WHERE b.type IN :types)")
int releaseDueFutureTransferOrders(...);
```

Every bind parameter is caller-supplied and `@Param`-named. So the exposed shapes are:

| Route (all `GET`) | Effect |
|---|---|
| `/v3/customerorder/search/updateStateByIds?ids=…&state=…` | set **any** state on **any** set of order ids (only `state = 800` rows are spared) |
| `/v3/customerorder/search/markClientHasNoSection?id=…&noSection=…&raw=…&futurePickingDate=…` | set any state on one id, with a caller-chosen precondition — the CAS guard is itself a parameter |
| `/v3/customerorder/search/releaseDueFutureTransferOrders?raw=…&futurePickingDate=…&today=…&types=…` | **mass** state flip across every order in a caller-chosen state and batch type |

**Why the withdrawal cannot reach them — this is mechanism, not speculation.** `RestConfiguration:441-447`
applies `withCollectionExposure` / `withItemExposure` / `withAssociationExposure`. Spring Data REST's
`ResourceType` enum has only `COLLECTION` and `ITEM`; searches are dispatched by `RepositorySearchController`,
which is `GET`-only and never consults the exposure filters. **The repository already documents this**, in the
sibling slice's own test, `src/test/java/net/aim_ai/wms/security/SdrUncalledSurfaceNotExportedContextTest.java:241-244`:

> `The whole case for class-level exported=false over ExposureConfiguration is /search/**: ResourceType has only`
> `COLLECTION and ITEM, and RepositorySearchController never calls verifySupportedMethod, so exposure filters`
> `cannot reach a search at all.`

That sentence was written to justify Slice 2's choice of `exported = false` for 29 *other* types. It applies with
equal force here, and this commit chose the mechanism it warns about.

**That the three are exported is measured, not inferred.** The same test records an instrument reading taken on
2026-09-01 (`:265-268`):

> `Measured 2026-09-01 — Customerorder reports 21, Billoflading (withdrawn) reports 0.`

`CustomerorderRepository` declares 18 `@RestResource`-annotated read searches plus `findByIdForUpdate`
(`exported = false`, excluded) plus these three `@Modifying` methods. **18 + 3 = 21.** The three mutating methods
are in that count.

Library confirmation, from the extracted sources:
- `RepositoryResourceMappings.getSearchResourceMappings:110` iterates `repositoryInformation.getQueryMethods()`;
- `RepositoryInformationSupport.isQueryMethodCandidate:158` — `isQueryAnnotationPresentOn(method) || …` — a
  `@Query` method **is** a query method, `@Modifying` notwithstanding;
- `RepositoryMethodResourceMapping:76` — `this.isExported = annotation != null ? annotation.exported() : exposeMethodsByDefault;`
  and `RestConfiguration.configureRepositoryRestConfiguration` never calls
  `setExposeRepositoryMethodsByDefault(false)`, so the default `true` applies;
- `:79-80` — with no `@RestResource(path=…)`, the path defaults to the **method name**.

**No gate covers it, at any mode.** `SdrFunctionGuard` does fire on searches and is deliberately verb-blind
(`SdrFunctionGuard.java:33-37`: *"THIS GATES EVERY VERB SDR SERVES, NOT ONLY READS"*), but it only bites on a
domain type that has a rule, and only at `ENFORCE_RULED`. `grep -n Customerorder src/main/java/net/aim_ai/wms/security/*.java`
returns **nothing** — `SdrFunctionRules` has no `Customerorder` entry. And `SdrGuardModeProvider:67-74` resolves an
absent/unparseable sysprop to `OFF`, which is where every tenant is. So these three are open today and would stay
open after the whole SBDEV-3169 rollout completes.

#### H1.5 — the one thing I cannot settle from source, stated plainly **[needs live]**

Whether the `UPDATE` **commits** depends on the transaction the SDR search path runs in. Spring Data's
`TransactionalRepositoryProxyPostProcessor` falls back to `SimpleJpaRepository`'s class-level
`@Transactional(readOnly = true)` for interface-declared query methods; `HibernateJpaDialect.beginTransaction`
with the default `prepareConnection = true` then sets the JDBC connection read-only, and Postgres rejects DML
with SQLSTATE **25006**. This repo has independent evidence that exact thing happens:
`sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md:204` records that
`markClientHasNoSection` needs `REQUIRES_NEW` precisely because *"the bulk JPQL CAS used here raises Postgres
`25006`"* when it joins a `readOnly = true` transaction.

So the likely live behaviour is **500 / SQLSTATE 25006, no mutation**. I am **not** treating that as a control:

- It is an accident of transaction defaults, not a security decision. `prepareConnection`, the base-class
  annotation, or a `@Transactional` added to any of the three would silently arm it.
- It is not asserted anywhere.
- Even in the 25006 branch it is an unauthenticated-shaped 500 on a `GET`, i.e. an availability and
  error-oracle nuisance, and the two sibling `@Modifying` methods on `CustomerorderPositionRepository`
  are shielded only because that repository is `exported = false`.

**Severity is stated as High conditional on the probe.** If a live `GET /v3/customerorder/search/updateStateByIds?ids=<id>&state=<n>`
as a zero-function principal returns 25006 → downgrade to **Medium** (latent, one annotation away from live).
If it returns 200 and the row moved → it is **High and worse than the exploit this commit closed**, because it
is a `GET`, needs no body, and hits a set of ids in one call.

**Fix shape:** `@RestResource(exported = false)` on all three — the same one-line instrument SBDEV-3169 used on
`findByIdForUpdate` in this very file. Internal Java callers (`CustomerorderBatchService:702`,
`ReleaseOrderJobService:802,831`) are unaffected; `exported = false` removes the HTTP route only.

### transferlane_id on the SDR axis — closed, and I could not find a way around it

`Customerorder.java` declares **no** JPA associations: `transferlaneId`, `parcelId`, `pickingtoteId`, `clientId`,
`orderbatchId`, `boxtypeId`, `shipperidId` are all plain `@Column` `Long` fields (repo convention — "no JPA
association annotations, manual FK relationships only"). Grepping the whole `model` package for
`@ManyToOne|@OneToMany|@OneToOne|@ManyToMany` returns **four** hits, all on `UserRole`, `UserGroup`, `User` and a
comment in `OutboxMessage`. Therefore:

- **No association resource exists** on or pointing at `Customerorder`, so no
  `PUT /v3/{other}/{id}/customerorder` can write the row. `RestConfiguration:449-453` says the same thing in
  its own words, and the `withAssociationExposure` line is correctly present anyway as belt-and-braces.
- **No projection write path** — SDR projections are read-only.
- **No repository event handler** touches `Customerorder`: the only two `@RepositoryEventHandler` classes are
  `SdrCacheEvictionEventHandler` and `PutawayConfigRepositoryEventHandler` (putaway/sysprop only).
- **None of the three `@Modifying` searches writes `transferlane_id`** — I checked each `SET` clause.

The four withdrawn verbs are `POST` (collection) and `PUT` / `PATCH` / `DELETE` (item) — the commit's own
mutation check A enumerates exactly that set. On the SDR axis, `transferlane_id` is closed.

### L1 — `/rest/**` reaches both columns, ungated and unauthenticated (informational)

`SecurityConfiguration.java:150-151` puts `/rest/**` in the `permitAll()` bucket:

```
.requestMatchers(
    "/", "/v3", "/v3/token", "/error", "/rest/**", "/api/**",
```

`OrderRestController` (`:38-40`, `@RestController @RequestMapping("/rest/order")`) carries no `@RequiresFunction`
or `@PreAuthorize` anywhere in the file, and two of its routes reach both columns:

| Route | Reaches |
|---|---|
| `POST /rest/order/cancelPositions` | `CustomerorderService.cancelOrder` → `setState(CANCELED)` (`:799`) **and** `setTransferlaneId(null)` (`:805`); fans out to `forceCancelOrder` (`:422,460,478`) and `CustomerorderBatchService.finalizeBatchIfComplete` (`:418`, also nulls `transferlane_id`) |
| `POST /rest/order/finishedQA` | `CustomerorderService.packageOrder` → `setState(PACKED)` (`:567`) |

**I am recording this, not filing it.** Nam's 2026-08-27 decision stands: `/rest/**` is the internal WMS↔OMS
surface, JWT is deferred, and it is not treated as a live exposure. It is included here only because the brief
asked for the `/rest/**` axis explicitly, and because it is the honest answer to "is the capability closed":
these routes null `transferlane_id` and set `state`, so the *capability* survives on that axis — just not for
the threat model (an authenticated `wms_user` on `/v3`) that SBDEV-3183 targets. OMS's own code confirms it is
the intended consumer — `v2/oms-laravel-api` `app/Services/OrderWmsRecallService.php:19`, on `origin/develop`:

> `(POST rest/order/cancelPositions -> CustomerorderService.cancelOrder), which`

which independently corroborates the commit's claim that *"OMS never writes it over SDR — its order traffic goes
to the internal `/rest/order/*` surface."*

### MVC routes — gated, with one nuance

Every `/v3` MVC route reaching `setTransferlaneId` carries `@RequiresFunction(WEB_UI_VIEW_TRANSFER_ORDER)`:
`TransfersController.java:99` (`reassignTransferLane`), `:126` (`unlinkTransferLane`), `:150`
(`activateTransferOrder`), `:179` (`assignTransferLane`), `:244` (`runTransfer`) — SBDEV-3155's four plus
`runTransfer`. The `state`-writing routes are likewise gated (`CustomerOrderController:61,89`,
`BillOfLadingController`, `AdminActionController:106,184`, `ClubLineController:163`, and the mobile
`PickingController` / `PalletizingController` / `TruckLoadingController` class-level gates).

Two `TransfersController` routes are **ungated** — `:70 /transferOrder/{customerOrderId}` and
`:93 /transferOrderByOrderBatchId/{orderBatchId}`. I read both: they are pure reads
(`customerorderRepository.findById(...)` → `ResponseEntity.ok(currentTransferOrder)`). They leak a full
`Customerorder` entity to a zero-function principal, which is the same exposure as L2, but they do not write.

`UtilRestController.resetOrdersInReleasedStatus` (`:1079-1092`, `setState(RAW)`) is **not a route at all** —
the class is annotated `@Service`, not `@RestController` (`:23-24`), so its nine `@RequestMapping` methods are
never registered. This matches the known repo trap and is not a finding.

---

## Q2 — Is `state` reachable by another name?

**Yes — that is H1**, and it is reachable under names that read as harmless finders in a URL
(`/search/updateStateByIds`). On the axes the brief named specifically:

- **CustomerorderPosition** — its repository is `exported = false` at class level
  (`CustomerorderPositionRepository.java:25`), so its two `@Modifying` searches
  (`updateStateByOrderIds`, `releaseDueFutureTransferOrderPositions`) publish **no** HTTP route. They write
  `customerorder_position.state`, not `customerorder.state`, in any case.
- **CustomerorderBatch** — in `SDR_WRITE_WITHDRAWN` (unchanged by this commit) and its repository declares no
  `@Modifying` method. Its `state` cascade to orders runs through `CustomerorderBatchService`, reachable only
  from the gated `ClubLineController:163` and the `permitAll` `/rest` surface (L1).
- **Cascade from a parent entity** — none exists. There are no JPA associations to cascade along (see Q1).

---

## Q3 — Availability regression?

**No regression found.** I verified this independently of the parallel caller-analysis lane, on
`origin/develop` of both UIs and of `oms-laravel-api`:

| Path | Verb | Caller | Status after the commit |
|---|---|---|---|
| `/customerorder/{id}` | GET | `wms2-web-ui components/outbound/bol/outboundBolDetailsTable.vue:200` | unaffected |
| `/customerorder/{id}` | GET | `wms2-web-ui store/processes/transferPicking.js:143` | unaffected |
| `/customerorder/search/findByKeyword` | GET | `wms2-web-ui store/masterData/customerOrder.js:46` | unaffected |
| `/customerorder`, `/customerorder/{id}`, `…/search/findByKeyword` | GET | `cypress/e2e/wms/smoke/phase1-submit.cy.js:82,114`, `phase2-pick.cy.js:123` | unaffected |
| `/customerorder/{id}` | **PATCH** | `wms2-web-ui store/common/order.js:15`, inside `updateCustomerOrder` | now 405 |

`git grep updateCustomerOrder origin/develop` in `wms2-web-ui` returns exactly one line —
`store/common/order.js:13`, its own declaration. `wms2-mobile-ui` has no `/customerorder` HTTP call at all
(its `customerorder*` hits are DTO field names on the cancellation screens). `omsv2-UI` has **zero** matches for
`customerorder` on any branch. That corroborates the parallel lane rather than duplicating it.

**The three javadoc reader citations in the new test are accurate** — I checked each file path against
`origin/develop` and each exists with the claimed call at the claimed responsibility. That matters, because the
`customerorderReadsRemainAvailable` test's whole value is that those citations are true.

**The MVC path does not route through the SDR item handler.** `CustomerOrderController` is a plain
`@RestController` at `@RequestMapping("/v3/customerOrder")` (`:31`), dispatched by
`RequestMappingHandlerMapping`; SDR's `/v3/customerorder` is dispatched by `RepositoryRestHandlerMapping`. They
are different handler mappings over different (case-distinct) paths, and the exposure configuration is consulted
only inside `RepositoryEntityController`. No MVC handler can be reached through it.

⚠ One caveat worth stating: **the two paths differ only by the case of one letter** (`customerOrder` vs
`customerorder`). Nothing in the codebase prevents a future reader from "fixing" one to match the other. That is
not a defect in this commit, but it is why the new behavioural test earns its place.

---

## Q4 — Reads: what remains open, for the record

`Customerorder` stays `EXPORTED`. Any authenticated principal — **including one holding zero functions** —
retains:

- `GET /v3/customerorder` (collection) and `GET /v3/customerorder/{id}`;
- **18 read searches**, including `findByKeyword` (substring match across `clientordernumber`,
  `parcelexternalnumber`, `recipient` — i.e. free-text search over every order in the tenant),
  `getOrderViewsByBatchId`, `getOrdersByBatchStatesAndTypeAndKeyword`, `getOrderViewsByBolId`,
  `getManifestLocationsByPalletName`;
- the serialized entity, which carries `recipient`, `clientordernumber`, `parcelexternalnumber`, `brand`,
  `brandname`, `manifestLocation`, `specialinstructions`, `additionalcontent` and `weight`.

Plus the two ungated MVC reads at `TransfersController:70,93`.

**This is not gated now and would not be gated later.** `SdrFunctionRules` has no `Customerorder` entry, so even
after every tenant reaches `ENFORCE_RULED` these reads stay open. I agree with the commit's reasoning that a rule
would have been the *wrong* instrument for the write problem — but the read exposure is a separate,
still-open question that this commit deliberately does not address and that nothing else currently tracks.
Recording it here so it is not later mistaken for something SBDEV-3183 covered. **Rated Low** because it is a
consistent-with-design read surface, not a regression, and Nam's authz axis decision (Keycloak coarse, functions
fine-grained) means read gating is a programme, not a bug.

---

## Q5 — Is the remedy the right shape?

**Better than both named alternatives, on the axes that matter — with one thing left open that neither
alternative would have closed either.**

| | `SdrFunctionRules` rule | `@ReadOnlyProperty` on `transferlaneId` + `state` | **write withdrawal (chosen)** |
|---|---|---|---|
| Bites at guard mode `OFF` (where every tenant is) | ❌ no — needs `ENFORCE_RULED` | ✅ | ✅ |
| Leaves reads open | ❌ verb-blind, would gate the UI's reads too | ✅ | ✅ |
| Closes `PATCH {transferlaneId, state}` | at ENFORCE only | ✅ | ✅ |
| Closes `DELETE /v3/customerorder/{id}` | at ENFORCE only | ❌ **no** | ✅ |
| Closes `POST /v3/customerorder` (arbitrary order creation) | at ENFORCE only | ❌ **no** | ✅ |
| Closes the `@Modifying` `/search/**` routes (H1) | ❌ no rule exists for the type | ❌ no — `@ReadOnlyProperty` governs SDR deserialization, not JPQL | ❌ no |

The decisive column is `DELETE`. The ticket framed the exploit as a `PATCH` of two fields, and
`@ReadOnlyProperty` on those two fields is the remedy that framing implies — but the commit's own mutation check
A shows the pre-existing exposed set was `[collection:POST, item:DELETE, item:PUT, item:PATCH]`. **An ungated
SDR `DELETE` on `customerorder` was open to any `wms_user` before this commit**, and `@ReadOnlyProperty` would
have left it open while looking like a fix. Withdrawal takes all four. That is the "a guard fences the mechanism
you aimed at" principle applied *correctly* on this axis, and it is a better outcome than the ticket asked for.

Contradicting the ticket's landmine was the right call: the landmine's premise ("it is genuinely written to")
was false, and I found no HTTP caller of any of the four verbs in any of the five repos I searched.

**What is left open is H1**, and no alternative on the table would have closed it. It needs the third
instrument — `@RestResource(exported = false)` on the query method — which is the same one SBDEV-3169 already
applied to `findByIdForUpdate` eleven lines above.

---

## Test-quality findings

### M1 — the `@Lock` invariant has no `@Modifying` sibling

`SdrLockingSearchNotExportedContextTest` asserts a genuine invariant — *"an exported SDR search must not resolve
to a repository method carrying `@Lock`"* — and argues explicitly for the invariant-over-instance form:

> `Pinning the one known path would leave the next locking search to be exported silently — the failure this`
> `codebase keeps repeating, where one instance of a pattern is fixed and its siblings are not.`

Its own "what it does NOT cover" list names three blind spots. **`@Modifying` is not among them**, and the
identical argument applies: a search that *writes* is at least as bad as one that *locks*. I audited all 62
repositories under `repo/jpa`: **31 `@Modifying` methods, of which 0 carry `@RestResource(exported = false)`.**
29 of them sit on repositories that are still exported at class level. Most are shielded only incidentally —
by a class-level `exported = false` added for unrelated reasons — which is exactly the fragility this test family
exists to prevent.

**Suggested fix:** extend the existing test (or add a sibling) with the same shape, swapping
`method.getAnnotation(Lock.class)` for `Modifying.class`. It is ~10 lines, reuses the vacuity guard already
there, and would have caught H1 at authoring time.

### M2 — the SDR inventory labels every search read-only by construction

`SdrSurfaceInventoryContextTest:97-102` emits SEARCH rows with the last two columns hard-coded:

```java
rows.add(String.join("\t",
        md.getDomainType().getSimpleName(),
        md.getPath() + "/search" + m.getPath(),
        "SEARCH",
        String.valueOf(m.isExported()),
        "GET", "", "read-only"));
```

`target/sdr-surface-inventory.tsv` is the artifact SBDEV-3157's AC-1 produces to answer *"what is the deployed
SDR surface"*. A `@Modifying` search appears in it as `GET … read-only`. **The instrument built to find this
class of exposure is blind to it by construction.** Deriving the column from the resolved method
(`m.getMethod().isAnnotationPresent(Modifying.class)`) is a one-line change and would make H1 visible in the
inventory rather than only in a review.

### L3 — the new pin is per-type

`CustomerorderTransferLaneSdrWriteContextTest` is well-built: it correctly identifies that
`SdrWriteWithdrawalContextTest`'s two lists are edited by the same hand and that moving a name between them
would keep it green; keying on `getSupportedHttpMethods()` instead defeats that. The over-gating rail
(`customerorderReadsRemainAvailable`) is the right second half, and its three UI citations check out.

The limit: it protects `Customerorder` and nothing else. The kept-ten still rest on list membership alone. Not
worth blocking on — a behavioural pin for all ten is a different ticket — but worth stating so a future reader
does not read this file as covering the kept set.

### Positive notes

- The withdrawal loop correctly includes `withAssociationExposure` (`RestConfiguration:446`) even though
  `Customerorder` owns no association today; the comment at `:449-453` explains that it is a no-op kept as
  belt-and-braces. That is the right call and the right documentation of it.
- `SdrWriteWithdrawalContextTest`'s size assertions were both updated (`47→48`, `11→10`), and the class javadoc
  and the "TEN resources" prose in `RestConfiguration:334` were updated in the same commit. The stale-count
  failure mode that file's own comment warns about did not recur here.
- The commit message's DB grounding (404,996 orders / 23 with a lane / 6 distinct lanes) is the right kind of
  evidence for a reachability claim. I did not re-run it **[needs live]**.

---

## Recommended actions

1. **H1 — add `@RestResource(exported = false)` to `updateStateByIds`, `markClientHasNoSection` and
   `releaseDueFutureTransferOrders`** in `CustomerorderRepository`. One line each, no internal caller affected.
   Per the ticket policy this belongs on **this** ticket (its own tier is well under T3, and SBDEV-3183 is not
   yet `on dev`) — it is the same finding, on the same entity, that this commit set out to close.
2. **H1.5 — run the live probe** as a zero-function principal against dev:
   `GET /v3/customerorder/search/updateStateByIds?ids=<a non-existent id>&state=<n>` and record the status +
   SQLSTATE. Use a **non-existent** id, per the discipline the SBDEV-3155 probe script already encodes — the
   answer to "did this route exist and reach the query" does not require mutating a real row.
3. **M1 — extend `SdrLockingSearchNotExportedContextTest`** (or add a `@Modifying` sibling) so the invariant,
   not the instance, is pinned. Mutation-check it by removing one of the three `exported = false` annotations
   from step 1 and confirming red.
4. **M2 — derive the SEARCH `writable` column** in `SdrSurfaceInventoryContextTest` from `@Modifying` rather
   than hard-coding `"read-only"`.
5. **L2 — record, do not fix here.** The Customerorder read surface is out of this commit's scope by design.
   It is worth a line in whatever tracks the SBDEV-3169 rule programme, since `Customerorder` has no rule and
   would survive a completed rollout unguarded.
6. **L1 — no action.** Accepted risk per Nam 2026-08-27.

Nothing here blocks the commit. H1 was open before it and is open after it; the commit strictly reduces the
attack surface and does so with the better of the three available instruments.
