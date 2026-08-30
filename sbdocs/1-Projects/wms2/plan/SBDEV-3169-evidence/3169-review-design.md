# SBDEV-3169 plan — design review

Everything below was checked at `origin/develop` (`git show`), plus the SDR 4.5.7 and spring-webmvc
6.2.15 **sources** jars from `~/.m2`. No checkout, no `mvn`.

## Verdict

**REWORK — scoped.** The *mechanism* is right and I'd keep it nearly unchanged: Fix A (package
predicate), Fix B (`URI_TEMPLATE_VARIABLES` → `ResourceMappings`), Fix C (`Class`-keyed rules) and
Fix E all hold up against the framework source, and §0–§2 is the best-evidenced problem statement
I've reviewed on this programme. What does not hold up is the part that decides whether this ships
without an outage. **§5's staging is self-contradictory with §4 Fix D**: Slice 0/1 describe a single
boolean flag over a 7-entry rule map while Fix D declares `no rule ⇒ DENY` unconditionally — an
implementer who follows Fix D literally and flips Slice 1's flag 403s the other 55 domain types,
i.e. the entire UI. Separately, **Fix F's carve-out reopens arbitrary-username group enumeration**
(the SBDEV-3071 shape) and is keyed on a raw string that no assertion validates, and **§7 names both
new tests `*IT`, which this repo has documented in `src/test` as running in neither lane.** Those
three plus the missing shadow/audit mode are the rework. §1.4, §12 and half of §9 should be cut
while it's open — at 860 lines the plan still does not contain the one artifact implementation needs
(the 62-row rule table), so the length is all in the justification.

---

## Findings

### [SEVERITY: High] Slice 0/1 as written cannot coexist with Fix D — one boolean cannot express "enforce where ruled" and "deny where unruled"

**Where**: §4 Fix D · §5 Slice 0, Slice 1, Slice 4 · §5.1-P6

**Problem**: Fix D's table is the *end state* (Slice 4), but it is written as the definition of the
design — *"'No rule ⇒ deny' is the whole design"*, followed by *"It also means Slice 0 cannot ship
before the rule table is complete."* Slice 0 then says the opposite: an **empty** rule map, flag off,
"nothing changes behaviour". Slice 1 says "Flag on for these types only" — which a single boolean
cannot do: with fail-closed semantics and 7 rules present, flipping it denies the other 55 types.
Slice 4 is then described as "flip the default to fail-closed", confirming there really are two
knobs, but the plan never names the second one.

**Why it matters**: this is the one defect in the plan that produces a total outage rather than a
regression, and it lives in the sentence an implementer will treat as authoritative. §5.1-P6 ("no
new sysprop before [Slice 4]") contradicts Slice 0's own flag, so the plan does not even agree with
itself on how many knobs exist.

**Suggested fix**: replace the flag with a named three-valued mode and put it in Fix D's table, so
the decision table is a function of `(handler shape, rule presence, mode)`:

| mode | ships in | SDR handler, rule present | SDR handler, no rule |
|---|---|---|---|
| `OFF` | Slice 0 | allow | allow |
| `ENFORCE_RULED` | Slices 1–3 | evaluate | **allow** |
| `FAIL_CLOSED` | Slice 4 | evaluate | **deny** |

and state that the root index / `/profile` deny (§2.5) is independent of the mode. Then P6 says "one
sysprop, introduced in Slice 0, removed in Slice 4" and Slice 1 stops needing a per-type flag it
can't have.

---

### [SEVERITY: High] Fix F's carve-out reopens arbitrary-username group enumeration — and the plan cites the ticket that fixed exactly this

**Where**: §1.5.1 · §4 Fix F · §8 AC-11 · §9-R12

**Problem**: `BOOTSTRAP_READS` exempts `GET /userGroup/search/findByUsername` for *any* authenticated
caller, with **no binding between the `username` request parameter and the authenticated principal**.
The login bootstrap needs "my groups"; the carve-out grants "anyone's groups", one username at a
time. Since `GET /user` is being gated in the same slice, the username list is harder to obtain —
but §1.3 itself establishes that this estate's usernames are not secret, and the whole point of
Slice 1 is that the access graph is the reconnaissance step.

**Why it matters**: Slice 1 is sold as "the slice that closes §1.3". It closes five of the six paths
and leaves a keyed lookup into the sixth. SBDEV-3071 is the same shape (arbitrary-username reads) and
the plan's own §1.5.1 correctly identifies SBDEV-3063's `@PublicHandler` as the precedent — then
copies the *exposure* rather than the *remedy*. `UserController.getAllRoles` is `@PublicHandler` and
derives its answer for the caller; `findByUsername` over SDR cannot, because SDR has no way to bind a
query parameter to the principal.

**Suggested fix**: don't build Fix F. Add `getAffiliatedGroups()` to `UserController` as a third
`@PublicHandler` that reads the principal from the security context (the file already has two
markers, an arity-keyed allow-list and a boot-log enumeration for exactly this), point
`store/index.js:249` at it, and gate SDR `UserGroup` with **no exemption**. `BOOTSTRAP_READS` then
starts empty, which is a far stronger invariant than AC-11's "pinned and non-growing", and Slice 1
becomes a two-repo change with an obvious deploy order (API first — the new endpoint is additive).
If Fix F is kept anyway, AC-11 must be widened: pinning the *contents* of the set says nothing about
whether an entry is safe, and this entry is not.

---

### [SEVERITY: High] Over-gating mitigation is a manual canary; the metric infrastructure for a real one is already in the plan and unused

**Where**: §9-R1 · §7 manual test plan · §5.1-P8

**Problem**: R1 is rated High with "silent: an empty table, not an error. No test fails" — and its
four mitigations are slice ordering, a **manual** canary ("pick 2 of the 17 partial holders … diff
their reachable screens"), a metric, and per-tranche revert. Only the metric is automated, and it
only tells you *after* users are already 403ing. The plan diagnoses the risk precisely and then
mitigates it with a hope.

**Why it matters**: §1.4-2 establishes that 38 of 99 users bypass every gate, so ordinary usage
generates no signal at all; the 17 partial holders are the entire detection surface and two of them
walking screens by hand is the instrument. On a 62-type rollout that is not enough, and the failure
is exactly the kind this repo's own history says goes unnoticed.

**Suggested fix**: two things, both cheap and both already half-built.

1. **A shadow mode before `ENFORCE_RULED`.** Evaluate the rule, emit
   `wms2.authz.sdr.would_deny{domainType, function}`, and **allow**. Slice 0 already ships the metric
   tagging (P8); this is one branch. Run a tranche in shadow for a deploy cycle; a non-zero
   `would_deny` for a type is the over-gate, found before anyone loses a screen. This turns R1's
   "no test fails" into "a counter moves", which is the only detector that works against a
   population where 38% are immune.
2. **A caller-coverage test.** `3169-lane-callers.md` already maps domain type → caller file → screen
   → function. Encode that as a fixture and assert, for every rule, that the any-of set is a
   **superset** of the functions of every screen the lane found reading that type. An over-narrow
   rule then fails at build time. This is the same "reflection pin over data, not mechanism" shape as
   `Sbdev3017TrancheGateContextTest`, which exists and works.

---

### [SEVERITY: Medium] Both new tests are named `*IT` — this module has 28 `*IT` classes that run in neither lane, and `src/test` documents it

**Where**: §6 File Change Summary · §7 Integration

**Problem**: the plan adds `SdrGateDenialIT.java` and describes the lane as "Integration
(Testcontainers PostgreSQL)". Both are wrong for this module.
`FunctionGateEnforcementPointContextTest:60-68` states it verbatim: `*IT.java` matches neither
surefire's defaults nor this pom's failsafe `<includes>` (`*IntegrationTest`, `*E2ETest` only), *"so
all **28** existing `*IT.java` classes in this module run in **neither** lane and are dead"* —
measured, 5468 tests, zero `*IT`. And the lane that can actually see SDR's handler mapping is
`BaseRollbackIntegrationTest`, which is `@SpringBootTest` on **H2**, not Testcontainers.

**Why it matters**: AC-2 and AC-3 — the denial proof and the don't-over-gate rail — would be written,
pass locally under `-Dtest=`, and never run in CI. That is a silently vacuous green on the two ACs
that carry the whole ticket.

**Suggested fix**: name them `SdrGateDenialContextTest` / `SdrFunctionRulesContextTest` and extend
`BaseRollbackIntegrationTest`. Reuse `FunctionGateEnforcementPointContextTest`'s harness verbatim —
it resolves a `MockHttpServletRequest` through every `HandlerMapping` bean in order and hands you
`chain.getHandler()`, which is how you get a real `RepositorySearchController` HandlerMethod without
MockMvc (standalone MockMvc cannot see SDR at all, and the web-context MockMvc lane is still blocked
on `RestIdempotencyCleanupJob:48`). For AC-3's positive rail, seed the grant rows and set
`SecurityContextHolder` by hand before driving `preHandle` — the integration profile sets
`rest.security.enabled=false`, so there is no principal otherwise and every SDR read would 403
vacuously. Also: `FunctionGateEnforcementPointContextTest` carries a **DO NOT RENAME** clause because
two mutants are caught only there; Slice 0 edits `preHandle`, so the plan should say that class's
arity assertions must stay green untouched.

---

### [SEVERITY: Medium] Fix D's table has no row for a non-`HandlerMethod` handler, and the URI-template attribute outlives the dispatch that set it

**Where**: §4 Fix D · §3 flow diagram

**Problem**: the table has four rows and none of them covers "the handler is not a `HandlerMethod`".
Today `preHandle:159` early-returns `true` for that case, and that early return is load-bearing:
`WebConfig`'s own javadoc records that `resourceHandlerMapping` was already in the gate's reach, so
static-resource dispatch passes through it, and the interceptor is registered on `/**`. A CORS
preflight is safe for a *different* reason than the plan would guess —
`AbstractHandlerMapping:680-692` (6.2.15) replaces the handler with a `PreFlightHttpRequestHandler`
**and inserts it as interceptor index 0**, where its `preHandle` short-circuits the chain before the
guard runs — but note `BasePathAwareHandlerMapping.hasCorsConfigurationSource()` returns `true`
unconditionally, so *every* SDR request goes down that branch.

The trap is ordering. `RequestMappingInfoHandlerMapping.handleMatch` sets
`URI_TEMPLATE_VARIABLES_ATTRIBUTE` **before** the preflight swap and **before** any interceptor runs,
and request attributes survive ERROR and ASYNC re-dispatch. So an implementation that reads the
attribute first — which is what "SDR handler, **no domain type** → DENY" invites, since §2.5 wants
`/v3` denied and `/v3` has no `{repository}` variable — will deny a preflight, an error dispatch of a
failed SDR request, and anything else that inherits a stale attribute.

**Why it matters**: it is a fail-*closed* bug, so it will not show up in the denial tests; it shows up
as the web UI not loading from a second origin, or as a 403 body replacing a 500. Nothing in the
proposed test set would catch it.

**Suggested fix**: add two rows to Fix D and pin both.

| Case | Decision |
|---|---|
| handler is not a `HandlerMethod` (static resource, preflight, actuator) | **allow — unchanged** |
| declaring class outside `org.springframework.data.rest.webmvc` | unchanged |

and state the invariant explicitly: *the URI-template attribute is read only after the declaring-class
package check has passed.* Tests: (a) `OPTIONS` + `Origin` + `Access-Control-Request-Method` on
`/v3/itemdata` resolves to a non-`HandlerMethod` and `preHandle` returns `true`; (b) a
`ResourceHttpRequestHandler` path returns `true`; (c) `preHandle` with a non-SDR `HandlerMethod` and
a pre-set `URI_TEMPLATE_VARIABLES` attribute containing `repository` returns `true` — that one is the
direct mutant for the ordering bug.

---

### [SEVERITY: Medium] Fix E does not cover the carve-out list, and Fix F's second key is a raw string — the exact property Fix C exists to preserve

**Where**: §4 Fix E · §4 Fix F · §8 AC-5b, AC-11

**Problem**: Fix E asserts two directions, both over the **rule** map: rule → exported type, and
exported type → rule. `BOOTSTRAP_READS` is asserted by nothing at boot; AC-11 only pins its contents
against a literal in a test, which is a diff tripwire, not a validity check. And Fix C's whole
argument — *"a repository rename or a `path=` change is a compile error or a startup failure rather
than a silent un-gating"* — is discarded for the half of the carve-out tuple that matters:
`"findByUsername"` is a string. Rename the repository method, or add `@RestResource(path="byUser")`,
and the carve-out stops matching. AC-11's test still passes (the literal is unchanged) and Fix E is
silent.

Also note the tuple's second element is ambiguous as written: the URL segment is the **exported search
path**, which is not always the method name.

**Why it matters**: the failure is fail-closed — 61 users get an error toast on every login — which
§1.5.1 itself says would not hard-fail and might therefore run for a while unnoticed. It is the same
class of drift the plan builds Fix C and Fix E to prevent, left uncovered in the one place a hole was
deliberately opened.

**Suggested fix**: extend the startup assertion to a third direction — for every `BOOTSTRAP_READS`
entry, `mappings.getSearchResourceMappings(domainType).getExportedMethodMappingForPath(path)` must be
non-null, else fail the boot. That API exists (`SearchResourceMappings:119`) and gives you exactly the
exported-path semantics. Say "exported search path" in the comment, not "method name". (Moot if the
High finding above is taken and the set is empty — but then assert it *is* empty.)

---

### [SEVERITY: Medium] Rules are per-type while exemptions are per-search — so a broad any-of union under-gates every narrow search inside it

**Where**: §4 Fix C vs §4 Fix F · `3169-lane-functions.md` unknown #5

**Problem**: Fix C keys requirements on `Class<?>` only, and Fix F establishes that the granularity a
real decision needs is `(type, search)`. The plan does not reconcile them. For the 14 broadly-read
types this makes the rule near-vacuous in the permissive direction: `Client` has 13 read paths and 22
caller files spanning Cycle Count, Shippers, Reports, Receiving and mobile Picking, so its any-of set
must be wide enough that *every* one of the 13 paths becomes readable by anyone holding *any* member.
The functions lane says so directly — *"a per-search map would likely split several rows"* — and the
plan drops that limit.

**Why it matters**: §2.7 already argues this ticket can't claim to close §1.1 alone. If the rules for
the broad types are unions, the ticket also can't claim to close much for `Client`, `Location`,
`Itemdata`, `Printer`, `Unitload` — the five types with the widest caller sets, which is most of the
business-data exposure. The plan should say that out loud rather than let the acceptance criteria
imply the whole surface is covered.

**Suggested fix**: keep the type-keyed map as the default and add an optional per-search **override**
keyed the same way the carve-out is, `(Class<?>, exportedSearchPath)`. It costs one extra lookup and
one extra startup-assertion direction, and it makes the mechanism able to express the narrowing the
evidence already demands. Then say explicitly, in §8, that a type rule without overrides is a
*ceiling*, not a fit.

---

### [SEVERITY: Medium] Slice 2 conflates two withdrawal mechanisms with different blast radii, and ignores the two types whose writes are still live

**Where**: §5 Slice 2 · §6 File Change Summary

**Problem**: §6 lists both `RestConfiguration.java` ("`exported=false` per search") and "repositories
in the UNCALLED bucket — `@RestResource(exported = false)` per method". These are different
mechanisms and only one of them can do each job:

- **Per-search** withdrawal needs `@RestResource(exported = false)` on the repository query method.
  There is no `ExposureConfiguration` equivalent — correct as the plan says.
- **Whole-type read** withdrawal (the 28 no-reference types, 133 paths) has an in-repo precedent the
  plan doesn't use: `RestConfiguration:372` `configureUnwrittenResourceWriteExposure` already does
  `forDomainType(X).withCollectionExposure/withItemExposure/withAssociationExposure(… disable …)`.
  That is `Class`-keyed (rename = compile error), lives in one file, is enumerable, and reverts in one
  diff — versus annotations scattered across 28 repository interfaces. It also reaches **association**
  exposure, which §0 row 4 says is the gap.

And `3169-lane-callers.md` Tier B flags two types — `Advice` and `Cyclecount` — as read-uncalled but
with **live SDR writes** (`inboundNotices.js:187` DELETE, `:380` PATCH; `cycleCount.js:250` PATCH).
The plan never mentions them. Suppressing `findById` on those repositories to kill the item read is
the kind of change that can take the item resource with it.

**Why it matters**: Slice 2 is now the plan's dominant remedy (§0.1). Choosing the scattered-annotation
mechanism for the whole-type cases gives up the one property the plan spends §4 Fix C defending, and
the two write-live types are a concrete breakage the lane already found and the plan dropped.

**Suggested fix**: split Slice 2 into 2a (28 whole types via `ExposureConfiguration`, read verbs on
collection + item + association) and 2b (per-search annotations inside called types, staged). Call out
`Advice` and `Cyclecount` by name with the instruction to disable **read** exposure only and leave the
write verbs, and add a probe row confirming the DELETE/PATCH still work afterwards.

---

### [SEVERITY: Medium] Slice 2's stated synergy with Slice 3 only holds for the 28 whole-type un-exports

**Where**: §5 Slice 2 — *"every path removed here is a path Slice 3 does not need a rule, a test or a probe row for"*

**Problem**: rules are keyed on domain **type** (Fix C). Un-exporting 41 of `Replenishorder`'s 42
searches removes zero rules — the type is still exported via its collection and still needs its rule,
its test and its probe row. The claim is true only for a type withdrawn entirely.

**Why it matters**: it's the stated justification for the slice ordering, and it overstates the payoff
by roughly an order of magnitude (309 per-search removals reduce the rule count by 0; the 28 whole
types reduce it by 28 of 62). The ordering is still right — un-exporting is cheaper and safer — but
for the correct reason: it removes *surface*, not *rules*.

**Suggested fix**: restate as "Slice 2a removes 28 of the 62 rules outright; Slice 2b removes surface
and probe rows but not rules."

---

### [SEVERITY: Medium] Every gated SDR read adds an uncached DB join; §11 has no performance row

**Where**: §11 checklist · §5 Slice 3

**Problem**: `AccessService.checkAnyAccess` (`:134`) does `userRepository.getAllRoles(username)` on
**every** call — no `@Cacheable`, no cache anywhere in the class — plus a second query
(`findByName`) on every deny. Today that cost lands on 14 `GUARDED` controllers and the annotated
handlers. This plan puts it on every SDR read across 62 resources, including hot paths: mobile picking
`/section/search/findByName`, `/stockunit/search/getStockUnitsForReplenishment`,
`/client/search/findByClNr` per pick. The completeness checklist row 4 says "no concurrency concern"
and there is no latency/load row at all.

**Why it matters**: after Slice 4 every denied SDR read costs **two** queries, and 61 of 99 users are
denied by a typical gate — so the failure mode of a mis-scoped rule is not just an empty screen, it's
an empty screen plus 2× the DB traffic. The repo already runs Caffeine.

**Suggested fix**: add a §11 row, and either (a) a short-TTL Caffeine cache on
`getAllRoles(username)` keyed by tenant+username, invalidated by the existing grant-mutation paths in
`AccessService`, or (b) a request-scoped memo so a single dispatch never queries twice. Measure one
representative screen's SDR call count before Slice 3 so the regression is falsifiable.

---

### [SEVERITY: Medium] After Slice 2, the smoke script's 403/405/404 discriminator can no longer distinguish "un-exported" from "row not found"

**Where**: §1.2 (*"403 = gated · 405 = verb withdrawn · 404 = reached the repository"*) · §8 AC-9

**Problem**: `RepositoryRestHandlerMapping.lookupHandlerMethod:153-157` returns `null` when
`!mappings.exportsTopLevelResourceFor(path)`, and `handleNoMatch` returns `null` — so an un-exported
resource produces a **404** with no interceptor involvement, the same code §1.2 assigns to "reached
the repository". AC-9 requires a second, different confirmation method per un-export, and the live
probe is the natural second method — but it can't tell the two apart. §2.5 makes it worse by denying
`GET /v3`, which is the other way to enumerate what's exported.

**Why it matters**: AC-9 exists because of the `Section` near-miss. An AC whose verification
instrument is ambiguous is not a control.

**Suggested fix**: for un-exports, probe the **collection** GET (200 when exported vs 404 when not) as
an authorised user, not an item GET; and add a row to `SdrSurfaceInventoryContextTest` asserting the
withdrawn paths are absent from `ResourceMappings` — that's the authoritative, non-ambiguous check and
it already runs in CI. Update §1.2's discriminator legend in the same commit as Slice 2.

---

### [SEVERITY: Low] `HEAD`/`OPTIONS` were analysed by neither lane and are unmentioned in the plan

**Where**: §0 · §7 · `3169-lane-callers.md` limit #8

**Problem**: the caller lane says explicitly *"HEAD and OPTIONS (present on every COLLECTION row) were
not analysed"*, and the plan carries none of it. In fact SDR declares real HandlerMethods for both:
`RepositoryEntityController:126/145/265/286` and `RepositorySearchController:101/118/264/283` map
`OPTIONS` and `HEAD` on `/{repository}`, `/{repository}/{id}`, `/{repository}/search` and
`/{repository}/search/{search}`. Because Fix B keys on the domain type and not the verb, all of them
*are* gated — but by luck of the design, not by decision, and nothing asserts it. Today a plain
(non-preflight) `OPTIONS /v3/{repo}` returns an `Allow` header enumerating the supported verbs to any
`wms_user`.

**Suggested fix**: one sentence in Fix D ("the rule is verb-independent; SDR's HEAD and OPTIONS
handlers carry the same `{repository}` variable and are covered"), and one AC row asserting 403 on
`HEAD /v3/userRole` — a cheap mutant for anyone who later adds a `GET`-only condition to the branch.

---

### [SEVERITY: Low] 403-vs-404 still enumerates the exported repository list after `GET /v3` is denied

**Where**: §2.5

**Problem**: §2.5's argument for denying the root index is that leaving it open *"hands an attacker
the map even after every resource is gated."* But the map is still derivable one probe at a time:
gated ⇒ 403, not exported ⇒ 404. Denying `/v3` raises the cost from one request to ~n, it does not
close the oracle.

**Suggested fix**: keep the deny (it is right), but state the residual honestly in §2.5 rather than
implying the map is closed. This is the "advertised capability ≠ closed" hygiene this programme keeps
having to re-learn in the other direction.

---

### [SEVERITY: Low] Unbounded pagination is measured, reported parenthetically, and then owned by nobody

**Where**: §1.2 — *"200  1000 rows  (page cap, not the row count)"*

**Problem**: there is no `spring.data.rest.max-page-size` anywhere in `application.properties` or
`RestConfiguration`, so that 1000 is SDR's default and `?page=N` walks the whole table. After this
plan, a user who legitimately holds `WEB_UI_VIEW_INVENTORY_RECORD` can still page all of `stockView`.
The review brief asks whether this is in scope; the plan neither owns nor disclaims it.

**Suggested fix**: one row in §11 or a line in §10 — either "out of scope, tracked as <ticket>" or set
`max-page-size` in Slice 0 where it costs nothing. Silence is the only wrong answer, given §1.2 quotes
the number.

---

### [SEVERITY: Low] The 403 body and `X-Authz-Denied` header will name an arbitrary member of an any-of set

**Where**: §4 Fix C · `FunctionGuardInterceptor.deny()`

**Problem**: `AccessDecision`'s `requiredFunction` is `functions[0]` (`AccessService:135`). With
single-function MVC gates that is fine. With Fix C's any-of sets of four to six for the master-data
types, every denial reports the first array element — so the metric tag, the log line and the
`X-Authz-Denied` header the UI reads all name a function that may have nothing to do with the screen
the user was on.

**Suggested fix**: for the SDR branch, join the set (`"A|B|C"`) into the metric tag and header, or add
a `requiredFunctions` list to the problem body. Cardinality is bounded by 62 rules. Cheap, and it is
the difference between a usable denial dashboard and one that says `WEB_UI_VIEW_STOCK_UNIT` for
everything.

---

### [SEVERITY: Low] Ten cypress-only read paths are flagged in §0.1 and then owned by nothing

**Where**: §0.1 limit 3 · §7 Regression

**Problem**: §0.1 notes *"Cypress-only paths (10) may or may not run against a gated environment"* and
the plan never returns to it. §7's Regression section is the maven suite only. Slice 2 un-exports
several of them (`CustomerorderBatch`, `Pickingorder/search/findByNumber`,
`Unitload/search/findByLabelid`, `findByStoragelocationId`, `Stockunit/search/findByItemdataId`) and
Slice 1/3 gate others; either way the e2e suite goes red with no owner and no expectation set.

**Suggested fix**: a §7 row — run the affected cypress specs before the un-export lands, record whether
they run as `sb_admin`, and either update them in the same PR or list them as accepted breakage with
the ticket that fixes them.

---

### [SEVERITY: Low] Four lane limits were dropped in the fold-in, and one of them is the same bug shape as §1.5.1

**Where**: §0.1, §2.6, §2.7 vs the two lane files

The plan carries R10 (repos outside the three), R11 (HAL `_links`) and the association gap faithfully.
It drops:

1. **`3169-lane-functions.md` unknown #2 — "whether `Sysprop` SDR reads happen before function
   resolution."** This is *exactly* §1.5.1's shape: a bootstrap read that must work for a user holding
   zero functions. `Sysprop` is named in §0.1 as one of the cleanest gating candidates and is a Slice-3
   type. The lane says its four known callers are admin screens but that `plugins/` and `middleware/`
   were not traced exhaustively — and `plugins/adjustmentAlerts.client.js` is called out elsewhere in
   the same lane as a **global plugin that fires on every page**. This needs to be a prerequisite of
   the tranche that gates `Sysprop` and `Stockrecord`, not a dropped footnote.
2. **`3169-lane-callers.md` #7 — SDR-vs-custom-controller handler-mapping precedence was derived from
   mapping declarations, never probed.** §2.7's entire argument (and therefore AC-10) assumes the two
   routes are distinct and both live.
3. **`3169-lane-callers.md` #2 — the OMS `printer_search_by_type` env override.** §2.6 says
   "optionally `v3/printer/search/findByType`"; the lane's point is stronger — the default is the
   non-SDR `rest/…` form, `.env` is gitignored, and whether any facility overrides it is
   *undeterminable by any static means*. That belongs in Q1/P3, not in an "optionally".
4. **`3169-lane-functions.md` #5** — two class-level-gated controllers (`FixLocationAssignmentController`,
   `SystemPropertyController`) plus `FileImportController`/`LabelPrintingController` are not in
   `GUARDED`, so they have no deletion tripwire. §11 row 2 ("adjacent bugs") should list it.

---

### [SEVERITY: Low] Line references in §3 Key Files have drifted

`RestConfiguration:376 configureUnwrittenResourceWriteExposure` is at **372** on `origin/develop`;
`:324 SDR_WRITE_WITHDRAWN` lands inside the preceding javadoc. Trivial in itself, but §2.6 makes
"derive from `origin/develop`, never a checkout" a rule of this plan, and a stale offset is the exact
tell it names.

---

## Is the plan too long? — yes, and the cut is unusually clean

860 lines, and §12 closes with *"Still not implementation-ready … the table is not [decided]."* The
one artifact implementation needs — the 62-row `domainType → any-of` table — is not in the document.
Everything that *is* in it is justification. Concrete cuts, ~400 lines:

| Cut | Lines | Tradeoff |
|---|---|---|
| **§1.4** → a 6-row table + one sentence | ~35 | The correction narrative (55 vs 99 denominator) is a genuinely valuable lesson but it is a *memory*, not a plan section. It is already saved. Keep the six numbers and the "17 partial holders are the only group that can lose something" sentence, which is what §9-R1 and §7 actually consume. |
| **§5.1-P1's inline SQL** → a script under `sbdocs/9-System/scripts/` | ~10 | An 8-line CTE inside a markdown table cell is unrunnable as written and will be retyped wrong. A file is copy-pasteable and diffable. |
| **§12 Provenance** → 4 bullets | ~25 | Frontmatter already carries `db_verified` and the date. The four fold-in changes are each stated in their own section; restating them is the third copy. |
| **§2.7's table** → the two sharpest rows + a pointer to the lane file | ~15 | The full 10-row table is verbatim from `3169-lane-functions.md`. `ReportController` and `ItemDataController` carry the argument; the other eight are evidence, and evidence belongs in the lane file. |
| **§9** → drop R4, R5, R8 rows; keep R1, R2, R6, R7, R9–R12 | ~15 | R4/R5/R8 restate §2.4, §7's warning box and a general principle, in a table whose mitigations are the same sentences. A risk register that duplicates the design section is read once and never again. |
| **§0.1's "three limits" block** | ~12 | Identical content to R10/R11 plus the cypress point. Keep one copy — the risk table, since that's where mitigations live. |
| **§4 Fix A/B code blocks** → prose + signature | ~15 | An 8-line Java package check is not a design decision; the *rationale* ("not a six-class list, because the failure direction is open") is, and it survives in one sentence. Fix C's and Fix F's shapes are load-bearing — keep those. |

That lands ~450 lines and, more importantly, makes room for the rule table, which is the thing whose
absence makes this plan not implementable regardless of length.

---

## What the plan gets right

- **§2.1 is the correct root cause and it is stated precisely**: the guard reaches SDR and asks the
  wrong question. That framing is what makes Fix B possible, and it is right — I verified
  `BasePathAwareHandlerMapping.lookupHandlerMethod` wraps the request only in
  `CustomAcceptHeaderHttpServletRequest`, which overrides header accessors only, so
  `handleMatch`'s `setAttribute` reaches the real request. **Fix B works.**
- **Fix A's package predicate over a six-class list**, with the "failure direction is open" argument.
  Correct, and it covers more than the plan claims: `alps/AlpsController` and `ProfileController` are
  in the package too and would be missed by any list built from the `Repository*Controller` naming.
- **§2.4's insight that keying on the domain type covers association reads by construction** rather
  than by remembering to enumerate them. This is the best decision in the plan and it is the one that
  makes Slice 1 actually close the authorization-graph traversal.
- **§2.7 / AC-10** — refusing to let the ticket claim it closes §1.1 while `ItemDataController` is
  ungated. That is the "a guard fences the mechanism you aimed at" lesson applied *before* the fact,
  which is rare.
- **§1.4's insistence that the unit is users, not roles**, and the two independent corroborations
  (the smoke script's 35/80, SBDEV-3063's 61-of-99). The arithmetic reconciles.
- **The UNCALLED inversion (§0.1)** and the willingness to re-order the plan around it rather than
  defend the original scoping. 84.6% unreferenced genuinely does change the remedy mix.
- **§1.5.1 as a first-class correction** rather than a footnote, including the detail that the catch
  fires a visible toast. My disagreement is with the *remedy*, not the finding.

---

## Open questions the plan should have asked but did not

1. **Should the login bootstrap move off SDR entirely instead of being carved out?** (Fix F vs a third
   `@PublicHandler` on `UserController`.) This is the highest-leverage unasked question — it decides
   whether Slice 1 ships with a hole, and whether `BOOTSTRAP_READS` starts empty or starts at one.
2. **Does any pre-function-resolution path read `Sysprop` over SDR?** Same shape as §1.5.1, flagged by
   the functions lane, dropped. If yes, gating `Sysprop` is a chicken-and-egg deadlock, not an empty
   screen. Must be settled before the Slice-3 tranche containing it.
3. **What is the acceptable per-request cost of the gate?** Nobody has stated a budget, and the plan
   adds an uncached join to every SDR read. Related: should `getAllRoles` be cached as part of this
   ticket, or is that a separate one?
4. **After Slice 4, what happens to a repository someone adds without a rule — fail the boot in every
   environment, or only where the guard is enabled?** Fix E says "fails the boot"; a shared rule table
   plus per-tenant deployments means one forgotten rule takes down every replica of every tenant. The
   plan should say whether that is the intended trade (I think it is — but it should be a decision).
5. **Does the e2e suite run as `sb_admin`?** One question to the person who owns cypress collapses
   §0.1's limit 3 and my Low finding above. It is answerable in a minute and nobody asked.
6. **Is `GET /v3/profile/{repository}` gated by the same rule as `/v3/{repository}`?** §2.5 decides the
   root and the bare profile, but `RepositorySchemaController` and `AlpsController` both map
   `/profile/{repository}` — they *do* carry the variable, so under Fix D they resolve and take the
   resource's rule. Probably right, but it is a decision the plan makes by accident.
