# SBDEV-3155 — test-harness analysis lane

**Basis of measurement.** `v2/wms2-api` checkout, branch `develop`, HEAD `ad681319915688c7e48499f7b32144de3bc2bd2b`,
identical to `origin/develop` after `git fetch origin` (`git rev-list --left-right --count origin/develop...HEAD` → `0 0`),
working tree clean. Every quote below is from that tree.

**The ten target handlers, as they are actually deployed** (from a real generated
`surface-inventory.tsv`, see §B.4 for provenance) — `declaringClass` is the subclass itself in all ten
cases, *not* `AdminController`, so there is no dual/alias registration to worry about and each is one row:

| verb | path | handler method | kind today | gate today |
|---|---|---|---|---|
| GET | `/v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}` | `assignStagingLane` | `read` | — |
| GET | `/v3/clubLine/unlinkStagingLane/{orderBatchId}` | `unlinkStagingLane` | `read` | — |
| GET | `/v3/clubLine/activateBatch/{orderBatchId}/{locationId}` | **`activeBatch`** ⚠ | `read` | — |
| GET | `/v3/clubLine/runClubLine/{orderBatchId}` | `runClubLine` | `read` | — |
| GET | `/v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}` | `reassignTransferLane` | `read` | — |
| GET | `/v3/transfers/unlinkTransferLane/{customerOrderId}` | `unlinkTransferLane` | `read` | — |
| GET | `/v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}` | `activateTransferOrder` | `read` | — |
| GET | `/v3/transfers/assignTransferLane/{customerOrderId}/{locationId}` | `assignTransferLane` | `read` | — |
| GET | `/v3/transfers/runTransfer/{orderId}` | `runTransfer` | `read` | — |
| GET | `/v3/pickingOrderPosition/fixPickingPosition/{id}` | `fixPickingPosition` | `read` | — |

⚠ **`/activateBatch` is served by a method named `activeBatch`** (`ClubLineController.java:134-135`):

```java
    @GetMapping(path= "/activateBatch/{orderBatchId}/{locationId}", produces = "application/json")
    public ResponseEntity<Object> activeBatch(@PathVariable("orderBatchId") String orderBatchId,
```

The ticket text says "activateBatch". That is the *path*. Any name-keyed assertion written from the ticket
will silently match nothing. This is the eleventh instance of the name-lies trap the two harness classes
already document.

---

## A. `Sbdev3017TrancheGateContextTest`

`src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` (471 lines).
Extends `BaseRollbackIntegrationTest` — full Spring context, reflects over the **deployed**
`RequestMappingHandlerMapping` beans.

### A.1 Keying axis — confirmed, `declaringClass.getSimpleName() + " " + path`

Write side:

```java
    /** (declaring class simple name + " " + path) -> the exact function set the route must require. */
    private static final Map<String, String> EXPECTED = new LinkedHashMap<>();

    private static void row(String declaringClass, String path, String... functions) {
        EXPECTED.put(declaringClass + " " + path, String.join("+", new TreeSet<>(Set.of(functions))));
    }
```

Read side, inside `everyTrancheRouteCarriesItsIntendedFunctions()`:

```java
                String declaring = hm.getMethod().getDeclaringClass().getSimpleName();
                for (String p : paths) {
                    String key = declaring + " " + p;
                    actual.put(key, resolve(hm));
```

Note it is the **simple** name, not the FQN, and it is `getMethod().getDeclaringClass()` — deliberately the
*interceptor's* axis, not `getBeanType()`. The class javadoc calls this out explicitly:

> ⚠ This resolves annotations the way the INTERCEPTOR does, which is NOT how the inventory tool does
> … `SurfaceInventoryContextTest.requiresFunction` keys its class-level fallback on `hm.getBeanType()`.
> Those disagree … **The interceptor is the authority**.

The expected value is a `+`-joined, `TreeSet`-sorted (alphabetical) function set; `""` means "must be
UNGATED".

### A.2 Row count and where it is asserted

**131 rows**, hardcoded in a *separate* `@Test`:

```java
    @Test
    @DisplayName("the pin covers every tranche route and every deliberate carve-out")
    void thePinHasNotBeenQuietlyShrunk() {
        assertThat(EXPECTED).hasSize(131);
    }
```

That is the only place the number appears in code. It appears again in prose in that method's javadoc
(`131 = 123 + 8 from SBDEV-3154`, decomposed further to `123 = the original 85 … + 38 from SBDEV-3142`) —
that javadoc arithmetic must be updated alongside the literal or the next reader is working from a false
ledger.

### A.3 Yes, it has a shrink guard, and how it computes the expected count

`thePinHasNotBeenQuietlyShrunk()` **is** the guard. Two properties worth knowing before extending it:

1. **It is a separate `@Test` on purpose.** Its javadoc:

   > Separate `@Test` on purpose. When this lived at the foot of the drift test, `assertThat(wrong).isEmpty()`
   > threw first, so any run WITH drift never reached the size check — exactly the run in which someone might
   > have deleted a row to make the drift go away.

2. **The expected count is a hand-maintained literal, not derived.** There is no computation. The
   anti-tamper property comes from the interaction with the drift test:

   > A duplicate key cannot hide a deletion — `LinkedHashMap.put` collapses it and the count drops. The only
   > way through is a simultaneous delete-and-add, and the added row must name a real deployed route with its
   > exact function set, which the drift test then checks.

### A.4 Mechanical steps to extend with 10 rows (AC-4 says extend, do not write a new class)

1. In the `static { … }` initializer, append a new banner block at the **end**, after the SBDEV-3154 block
   and before the closing `}`. Follow the house style: a `── SBDEV-3155 — <what> ──` rule comment, then the
   `row(...)` calls.
2. Add exactly these ten calls, keyed on **path**, using the *simple* class name:

   ```java
   row("ClubLineController",  "/v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}", "<FN>");
   row("ClubLineController",  "/v3/clubLine/unlinkStagingLane/{orderBatchId}",              "<FN>");
   row("ClubLineController",  "/v3/clubLine/activateBatch/{orderBatchId}/{locationId}",     "<FN>");
   row("ClubLineController",  "/v3/clubLine/runClubLine/{orderBatchId}",                    "<FN>");
   row("TransfersController", "/v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}", "<FN>");
   row("TransfersController", "/v3/transfers/unlinkTransferLane/{customerOrderId}",         "<FN>");
   row("TransfersController", "/v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}", "<FN>");
   row("TransfersController", "/v3/transfers/assignTransferLane/{customerOrderId}/{locationId}", "<FN>");
   row("TransfersController", "/v3/transfers/runTransfer/{orderId}",                        "<FN>");
   row("PickingOrderPositionController", "/v3/pickingOrderPosition/fixPickingPosition/{id}","<FN>");
   ```

   The `{…}` path-variable names must match the source **exactly** — the key is the registered
   `RequestMappingInfo` pattern string, so `{orderBatchId}` vs `{id}` is load-bearing. Copy them from the
   table at the top of this file (which came from the deployed surface, not from reading source).
3. Bump the literal: `assertThat(EXPECTED).hasSize(131)` → `hasSize(141)`.
4. Update the `thePinHasNotBeenQuietlyShrunk()` javadoc arithmetic to read `141 = 131 + 10 from SBDEV-3155`
   and say what the 10 are.
5. **Consider adding negative rows too.** Every prior tranche that added gates to a class also pinned that
   class's *ungated* siblings, and in both SBDEV-3142 and SBDEV-3154 those negative rows were measured to be
   the only thing that catches the "tidy this into one class-level annotation" mutation. Concretely: with
   only positive rows, replacing ten method annotations with one class-level `@RequiresFunction` on
   `ClubLineController`/`TransfersController` resolves **identically** for every positive row and the pin
   stays green — while fail-closing every read handler on those classes (`/openClubRun`, `/closedClubRun`,
   `/activeClubRun`, `/inactiveClubRun`, `/availableStagingLanes`, `/orderBatch/{orderBatchId}`,
   `/openTransfer`, `/allOpenTransfer`, `/activeTransfer`, `/closedTransfer`, `/inactiveTransfer`,
   `/transferOrder/{customerOrderId}`, `/transferOrderByOrderBatchId/{orderBatchId}`). If SBDEV-3155 intends
   those to stay ungated, pin two or three of them with the empty-value `row(cls, path)` form. **This changes
   the count** — decide it before writing step 3.
   - Caveat that applies to `PickingOrderPositionController`: it declares **exactly one** handler
     (`fixPickingPosition`), so a method-level and a class-level annotation are behaviourally identical there
     and no negative row is possible. Say so rather than leaving it looking like an oversight.

### A.5 Would it catch a gate arriving via `@PreAuthorize` instead of `@RequiresFunction`?

**For SBDEV-3155's ten rows: yes, it fails RED — but for the "route is ungated" reason, not for a
"you used the wrong mechanism" reason.** `resolve()` reads only `@RequiresFunction`:

```java
    /** Resolves exactly as {@link FunctionGuardInterceptor} does: method annotation, else DECLARING class. */
    private static String resolve(HandlerMethod hm) {
        Method m = hm.getMethod();
        RequiresFunction r = AnnotatedElementUtils.findMergedAnnotation(m, RequiresFunction.class);
        if (r == null) {
            r = AnnotatedElementUtils.findMergedAnnotation(m.getDeclaringClass(), RequiresFunction.class);
        }
        return r == null ? "" : String.join("+", new TreeSet<>(Set.of(r.value())));
    }
```

So a row expecting `[WEB_UI_VIEW_CLUB_LINE]` whose handler carries only `@PreAuthorize` yields
`expected [WEB_UI_VIEW_CLUB_LINE] but was [UNGATED]` — red. Good.

**The High defect the ticket refers to was the opposite direction, and it is already fixed.** The hole was on
rows expecting **no** gate (§0.C OMS carve-out): `resolve()` returns `""` for a `@PreAuthorize`-gated handler,
so adding `@PreAuthorize`/`@Secured`/`@RolesAllowed`/`@DenyAll` to a carve-out route left the pin green while
403-ing OMS in production. The fix is now in the tree — `METHOD_SECURITY_GATES` plus:

```java
            } else if (want.getValue().isEmpty() && methodSecurityGated.contains(want.getKey())) {
                // §0.C carve-out gated by the OTHER mechanism. resolve() cannot see this.
```

with the measurement recorded in the javadoc: `@Secured` + `@RolesAllowed` + `@DenyAll` on all three
carve-out routes *simultaneously* "left it GREEN at 5692. `@DenyAll` denies everyone; it is the most total
gate the framework offers, and nothing in the repository noticed."

**Residual blind spot, relevant if SBDEV-3155 adds any negative rows.** `hasMethodSecurityGate` is consulted
**only** in the `want.getValue().isEmpty()` branch. A row that expects a function set and carries the correct
`@RequiresFunction` **plus** an extra `@PreAuthorize` stays green. That is a narrowing nobody would see here.

---

## B. `SurfaceInventoryContextTest`

`src/test/java/net/aim_ai/wms/security/SurfaceInventoryContextTest.java` (162 lines).

### B.1 The GET-mutation heuristic, verbatim (lines 116-122)

```java
                boolean isMutating = verbs.isEmpty()
                        || verbs.contains(RequestMethod.POST) || verbs.contains(RequestMethod.PUT)
                        || verbs.contains(RequestMethod.PATCH) || verbs.contains(RequestMethod.DELETE);
                // GET-that-mutates: the §0.C orphan class, e.g. GET /v3/shipperId/delete/{id}
                String joined = String.join(",", paths).toLowerCase();
                boolean getMutates = !isMutating && (joined.contains("/delete") || joined.contains("/remove")
                        || joined.contains("/cancel") || joined.contains("/reset") || joined.contains("/create"));
```

Two mechanics worth noting: it matches on the **lower-cased, comma-joined path set** (so a handler with two
paths matches if *either* contains the token), and `verbs.isEmpty()` (an unqualified `@RequestMapping`)
counts as mutating.

### B.2 The `kind` column and the output file

`kind` is a three-way ternary, computed once per registration:

```java
                rows.add(String.join("\t",
                        bean.getKey(), verbStr, String.join(",", paths),
                        type.getName(), method.getDeclaringClass().getName(), method.getName(),
                        (isMutating ? "MUTATE" : (getMutates ? "GET-MUTATE" : "read")),
                        rf, pa, isPublic ? "PUBLIC" : "", guarded ? "GUARDED" : ""));
```

Output: **`target/surface-inventory.tsv`**, 11 columns
(`mappingBean, verbs, paths, beanType, declaringClass, handler, kind, requiresFunction, preAuthorize,
publicHandler, guardedClass`), rows naturally sorted, written unconditionally:

```java
        Path out = Path.of("target", "surface-inventory.tsv");
        Files.createDirectories(out.getParent());
```

Three counters (`total`, `mutating`, `gatedMutating`) go to **stdout only**:

```java
        System.out.println("SURFACE-INVENTORY totalHandlers=" + total
                + " mutating=" + mutating + " gatedMutating=" + gatedMutating
                + " ungatedMutating=" + (mutating - gatedMutating));
```

### B.3 Blast radius — **there is none.** This is the answer to "find the real blast radius"

The class has **exactly one assertion**, and it is on `total`, which is incremented for *every* registration
regardless of `kind`:

```java
        org.assertj.core.api.Assertions.assertThat(total)
                .as("a context that registered nothing must not look like an empty surface")
                .isGreaterThan(200);
```

`mutating` / `gatedMutating` / `ungatedMutating` are **never asserted anywhere**. Verified by grep over the
whole module:

```
$ grep -rn "ungatedMutating\|gatedMutating" --include=*.java src/
src/test/.../SurfaceInventoryContextTest.java:101   int total = 0, mutating = 0, gatedMutating = 0;
src/test/.../SurfaceInventoryContextTest.java:132       if (!rf.isEmpty() || !pa.isEmpty()) gatedMutating++;
src/test/.../SurfaceInventoryContextTest.java:154-155  System.out.println(...)
```

And **nothing else in the repo reads the TSV** — `grep -rn "surface-inventory" --include=*.java --include=*.sh
--include=*.md --include=*.xml .` (excluding `target/`) returns **zero hits**. No verify script, no other test,
no doc consumes it. The `getMutates` symbol itself appears only inside this one file.

The class javadoc states the design intent that makes this so:

> It is an **inventory generator, not a ratchet**: it asserts only that the surface is non-trivially large …
> A frozen per-endpoint allowlist was considered and **deliberately rejected**.

**Conclusion: widening the heuristic cannot break any currently-passing assertion or count, anywhere in the
module.** The cost of a widening is entirely in the *quality of the artifact a human reads*, not in test
stability. That inverts the usual risk calculus for this decision.

### B.4 The three options, each measured

Provenance for the measurements: a real `target/surface-inventory.tsv` generated by this very test in the
SBDEV-3154 worktree, `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3154/target/surface-inventory.tsv`,
written 2026-09-01 10:42 — i.e. from the code that became `ad681319`, the current `origin/develop` HEAD.
792 registration rows. Current tally: **404 `MUTATE`, 379 `read`, 9 `GET-MUTATE`**.

All ten SBDEV-3155 targets are currently `read` and ungated (table at top). **Zero of ten** are caught by
today's heuristic.

The nine current `GET-MUTATE` rows, for calibration — 7 true positives, 2 known false:

```
GET /v3/cancellation/{customerOrderId}/detail   [detail]                  ← FALSE POSITIVE ("cancellation")
GET /v3/cancellation/list                       [listPendingReversals]    ← FALSE POSITIVE ("cancellation")
GET /v3/printer/delete/{printerId}              [deletePrinter]
GET /v3/replenishOrder/cancelReplenishOrder/{id}[cancelReplenishOrder]
GET /v3/shipperId/delete/{shipId}               [deleteShipperId]
GET /v3/unitLoad/deleteContainerRecursive/{id}  [deleteContainerRecursive]
GET /v3/user/delete/{userId}                    [delet]
GET /v3/userGroup/delete/{groupId}              [delete]
GET /v3/userRole/delete/{roleId}                [deletRole]
```

#### Option (i) — widen the substring list

Measured precision, per candidate token, over the 379 currently-`read` rows:

| token | matches | true positives | false positives |
|---|---|---|---|
| `/assign` | 2 | 2 (`assignStagingLane`, `assignTransferLane`) | **0** |
| `/reassign` | 1 | 1 (`reassignTransferLane`) | **0** |
| `/unlink` | 3 | 3 (both targets **+ `/v3/receiving/unlinkSelectedPallet/{palletName}`**, a genuinely mutating GET already gated `M:WEB_UI_VIEW_RECEIVING` and named in the class javadoc's own list of misses) | **0** |
| `/activate` | 2 | 2 (`activateBatch`, `activateTransferOrder`) | **0** |
| `/run` | 2 | 2 (`runClubLine`, `runTransfer`) | **0** |
| `/fix` | 9 | 1 (`fixPickingPosition`) | **8** — 7 × `/v3/fixedAssignment/*` reads (`detailView`, `getFlowBinHavingNoFixedAssignment`, `user/findUsers`, …) + `/v3/replenish/fixedLocationUpperBound/{locationId}` |
| `/fixpicking` | 1 | 1 | **0** |

Note `/assign` does **not** subsume `/reassign` (the literal `/assign` is absent from
`/reassignTransferLane`) — both tokens are needed.

The honest minimal widening is therefore **five tokens**:
`/assign`, `/reassign`, `/unlink`, `/activate`, `/run` — 10 new matches, **9 of the 10 SBDEV-3155 targets,
zero false positives**, plus one bonus true positive (`unlinkSelectedPallet`, a real GET-mutate the current
heuristic misses).

`/fix` is the outlier and must **not** be added as a bare token: 8 false positives against 1 true positive
would push the heuristic's precision from 7/9 to 8/19 and is exactly the "train readers to re-baseline
without auditing" failure the class javadoc cites SBDEV-3089 for. Either use the narrow `/fixpicking`
(1 match, 0 FP — but it is a per-endpoint literal wearing a heuristic's clothes, and it would then also
warrant `/fixhub` for `/v3/advice/fixHubAndSpokePalletIssues`, which is already `MUTATE`), or leave
`fixPickingPosition` uncaught and say so in the javadoc's limitation §1 list.

What option (i) **would** catch going forward: a future GET named with one of those verbs, on any
controller, appearing as `GET-MUTATE` in the artifact instead of `read`. What it would **not** catch: every
other mutating-GET spelling — `/close*`, `/set*`, `/toggle*`, `/print*`, `/accept*`, `/trigger*`, `/finish*`,
`/adjust*`, `/move*`, `/recover*`, `/release*`, `/update*`. Those are 12 further token families the class
javadoc's own limitation §1 already names (`closeInboundBol`, `closeOutboundBol`, `triggerOrderReplenish`,
`printLabel`, `setDefault`, `toggleActiveStatus`, `acceptHubAndSpokeBol`, `closeIntraCompanyTransfer`).
Adding five tokens does not make the heuristic complete; it makes it 15/379 instead of 9/379. State that
plainly rather than letting the widening read as closure.

Change to a passing assertion or count: **none** (§B.3).

#### Option (ii) — a hand-maintained allow-list of known mutating GETs

Shape: a `private static final Set<String> KNOWN_MUTATING_GETS` of `declaringClass#handler/arity` or of exact
paths, OR-ed into `getMutates`.

Catches: exactly what is listed, with zero false positives, including the 12 families option (i) misses.
Does not catch: anything new. It is the frozen per-endpoint allowlist the class javadoc **explicitly and
by name rejects**:

> A frozen per-endpoint allowlist was considered and **deliberately rejected** — SBDEV-3089 measured what 150
> frozen ArchUnit entries cost: entries keyed on names and line numbers guarantee a steady false-positive rate
> and train readers to re-baseline without auditing.

It is also redundant with the thing SBDEV-3155 is already required to do: the ten endpoints get a
`(declaringClass, path)` row in `Sbdev3017TrancheGateContextTest`, which is a *stronger* pin (it asserts the
function set, not merely "someone thought this mutates") on the interceptor's own resolution axis. Building a
second, weaker hand-list in a generator that asserts nothing adds a maintenance surface and no coverage.
Change to a passing assertion or count: none, but it contradicts a documented, cited design decision — expect
a review lane to flag it.

**Recommendation: option (i) with the five clean tokens, plus a javadoc amendment.** It costs one line, has
measured zero false positives, improves the artifact a human reads, and touches no assertion. Skip `/fix`.

#### Option (iii) — comment only

Amend limitation §1's list of known-miss endpoints to name the ten (or the one remaining, if (i) lands) and
leave the code alone. Catches nothing new mechanically; keeps the artifact's `read` label wrong for ten
mutating routes. Change to a passing assertion or count: none.

Whichever option is chosen, the class javadoc's own numbers need a pass: it says the heuristic "also produced
2 false positives" (still exactly true — the two `/v3/cancellation/*` rows), and its `AdminController is a
base class for 45` / `395 mutating registrations` / `164 distinct methods` figures were measured 2026-08-28
and were not re-measured for this report.

---

## C. Gate mechanisms and the ArchUnit rails

### C.1 `GUARDED` membership — none of the three, as expected

`FunctionGuardInterceptor.java`, the set is `Set.of(...)` of 14 `Class` literals:

```java
    static final Set<Class<?>> GUARDED = Set.of(
            LookupController.class, PutawayController.class, MoveUnitloadController.class,
            MoveStockController.class, PickingController.class, PalletizingController.class,
            TruckLoadingController.class, CycleCountLosController.class, ReplenishController.class,
            TransferOrderController.class, OrderCancellationController.class,
            UserRoleController.class, UserGroupController.class, UserController.class);
```

(elided here for length; the source carries long per-entry comments). **`ClubLineController`,
`TransfersController` and `PickingOrderPositionController` are absent — confirmed.** Note the near-miss:
`net.aim_ai.wms.controller.mobile.TransferOrderController` **is** in the set and is a *different class* from
`net.aim_ai.wms.controller.TransfersController`. Do not conflate them in a plan or a grep.

**Do not add any of the three to `GUARDED`.** Every one of them carries ungated read handlers
(`ClubLineController`: `/orderBatch`, `/openClubRun`, `/closedClubRun`, `/activeClubRun`, `/inactiveClubRun`,
`/availableStagingLanes`; `TransfersController`: `/transferOrder`, `/transferOrderByOrderBatchId`,
`/openTransfer`, `/allOpenTransfer`, `/activeTransfer`, `/closedTransfer`, `/inactiveTransfer`), and
membership fail-closes every unannotated handler on the class at **boot**, not at request time —
`FunctionGuardStartupAssertion.afterSingletonsInstantiated()` throws `IllegalStateException` and no replica
starts. Its javadoc names this shape exactly:

> The genuinely un-bootable split is a different one: adding a class to `FunctionGuardInterceptor.GUARDED`
> *without* its class-level `@RequiresFunction`.

### C.2 `FunctionGuardArchTest#noSharedControllerCarriesRequiresFunction` — **would not fire**

The rule iterates a fixed list:

```java
    /** §0.B — shared controllers that must never be annotated; gating one 403s a web screen. */
    private static final List<String> SHARED_CONTROLLERS =
            Arrays.asList("StockUnitController", "DashboardController", "ReplenishOrderController",
                    "UnitLoadController");
```

**"Shared" is exactly those four, and none of SBDEV-3155's three is among them.** Annotating methods on
`ClubLineController`, `TransfersController` or `PickingOrderPositionController` does not trip this rule, does
not require a `REVIEWED_SHARED_METHOD_GATES` entry, and must not be given one — the second half of the test
asserts every allow-list entry is *live*:

```java
        assertThat(stale)
                .as("these allow-list entries no longer name an annotated method, so they permit nothing and "
                        + "hide the next real offender — delete them or fix the name")
                .isEmpty();
```

so a speculative entry for a class the rule never scans would itself go red.

Precedent confirming this: SBDEV-3142 already added method-level `@RequiresFunction` to `ClubLineController`
(`/skus`, `/unitLoads`, `/parcels`) and `TransfersController` (`/skus`, `/unitLoads`, `/parcels`,
`/availableTransferLanes`) with **no** `SHARED_CONTROLLERS` or `REVIEWED_SHARED_METHOD_GATES` change.

**The registration procedure, for the record** (needed only if a lane argues one of the three should be
declared shared): add the simple name to `SHARED_CONTROLLERS`; then every annotated declared method needs an
entry keyed **name + parameter arity** in `REVIEWED_SHARED_GATE_FUNCTIONS` (a `Map<String, Set<String>>`,
`"Cls#method/arity" -> functions`) and the arity-free twin `"Cls#method"` in `REVIEWED_SHARED_METHOD_GATES`;
`reviewedSharedGatesCarryTheirFullAnyOfSet()` asserts the two stay in bijection:

```java
        assertThat(REVIEWED_SHARED_GATE_FUNCTIONS.keySet().stream()
                        ...
                .containsExactlyInAnyOrderElementsOf(REVIEWED_SHARED_METHOD_GATES);
```

The documented bar for an entry is high (untruncated caller enumeration across *both* UIs, every caller's own
function folded into an ANY-of set, single/bulk pairs kept identical). **Class-level annotations on a shared
controller stay banned outright.**

**Corollary that does bind SBDEV-3155:** because none of the three is "shared", *nothing* stops a class-level
`@RequiresFunction` being put on them. That is the M4-shaped mutation, and only `Sbdev3017TrancheGateContextTest`
negative rows (§A.4 step 5) can catch it. Weigh that when deciding step 5.

### C.3 Other ArchUnit rails — what does and does not reach the three classes

- `AC-1 everyGuardedControllerCarriesRequiresFunction`, `AC-2 controllerToFunctionMapMatchesTheGoldenMap`
  (`.hasSize(GOLDEN_MAP.size())`): iterate `GOLDEN_MAP`, i.e. the 14 guarded controllers. Not reached.
- **`AC-3 everyRequiresFunctionValueIsADeclaredFunctionEnumConstant`: also iterates `GOLDEN_MAP.keySet()`
  only.** So a `@RequiresFunction` value on a non-guarded, non-shared controller is validated against
  `FunctionEnum` by **no test**. In practice the constants are referenced symbolically
  (`WmsConstants.FunctionEnum.WEB_UI_VIEW_CLUB_LINE`) so the compiler covers it — but a string literal typo
  would ship fail-closed and silent. Worth one sentence in the plan's risk section.
- `G-1 noRestControllerCarriesRequiresFunction` / `G-2 noRestControllerIsInTheGuardedSet`: scoped to
  `src/main/java/net/aim_ai/wms/controller/rest`. The three live in `controller/`, not `controller/rest/`.
  Not reached.
- `AC-26 noMobileControllerUsesPreAuthorizeForFunctionChecks`: mobile only. Not reached — **so nothing stops
  SBDEV-3155 from being implemented with `@PreAuthorize` on these three classes.** The only thing that would
  make that fail is the `Sbdev3017TrancheGateContextTest` rows (§A.5).
- `AC-5 adminControllerCarriesNoRequiresFunction`: all three `extend AdminController`. Annotating **methods
  on the subclasses** is fine; annotating `AdminController` itself is banned and would register under all 43+
  subclass prefixes.
- `ActionGuardAnnotationContractUnitTest` (`unit/security/`) is the anti-drift rail for method-level gates on
  *non-GUARDED* controllers — but it is a **closed pin over its own 13-entry map**
  (`assertThat(EXPECTED).hasSize(13)`, `StockUnitController` + `UnitLoadController` only). SBDEV-3155 gates do
  not break it and are not covered by it. If the plan wants a class-shaped anti-drift rail rather than more
  `Sbdev3017TrancheGateContextTest` rows, this is the class whose shape to copy.

### C.4 Every mechanism by which a gate can arrive, with enablement status

> ⚠ **Superseded 2026-09-01 by SBDEV-3156.** Rows **6, 7 and 8** are now **NO**: `MethodSecurityConfig`
> reads `@EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false)`,
> all three attributes are pinned by `MethodSecurityEnablementContractTest`, and `@Secured`,
> `@RolesAllowed`, `@DenyAll` and `@PermitAll` are banned from `src/main` by
> `MethodSecurityAnnotationSurfaceArchTest` (direct **or** meta-annotated). **Both caveats below are
> closed.** Rows 1-5 and 9-10 stand. The table is left as-written because its header pins it to a
> basis commit — read the rows as evidence as-of that commit, not as current enablement. A planner
> enumerating denial mechanisms off the un-annotated table would over-count by three.

| # | Mechanism | Enabled? | Evidence |
|---|---|---|---|
| 1 | `@RequiresFunction` (method-level, then **declaring-class**-level fallback) via `FunctionGuardInterceptor.preHandle` | **YES** | `FunctionGuardInterceptor.java` `@Component`; registered as a `MappedInterceptor` **bean** on `/**` — `WebConfig.java:86-87` `public MappedInterceptor functionGuardMappedInterceptor() { return new MappedInterceptor(new String[] {"/**"}, functionGuardInterceptor); }` |
| 2 | `FunctionGuardInterceptor.GUARDED` membership (fail-closed for **unannotated** handlers on member classes) | **YES**, 14 classes | `FunctionGuardInterceptor.java` `static final Set<Class<?>> GUARDED = Set.of(...)`; boot-enforced by `FunctionGuardStartupAssertion.afterSingletonsInstantiated()` → `throw new IllegalStateException(...)` |
| 3 | `@PublicHandler` (escape hatch — *removes* a gate, resolves **first**) | **YES** | `FunctionGuardInterceptor` class javadoc "The one escape hatch"; enumerated at boot by `FunctionGuardStartupAssertion.findPublicHandlers` |
| 4 | `@PreAuthorize` | **YES** | `MethodSecurityConfig.java:9` `@EnableMethodSecurity(prePostEnabled = true, securedEnabled = true, jsr250Enabled = true)` |
| 5 | `@PostAuthorize` | **YES** | same line, `prePostEnabled = true` |
| 6 | `@Secured` | **YES** | same line, `securedEnabled = true` |
| 7 | `@RolesAllowed` (JSR-250) | **YES** | same line, `jsr250Enabled = true` |
| 8 | `@DenyAll` / `@PermitAll` (JSR-250) | **YES** | same line, `jsr250Enabled = true` |
| 9 | `SecurityConfiguration` `authorizeHttpRequests` matchers | **YES in prod, INVISIBLE to every Spring-context test** | `SecurityConfiguration.java:43` `@ConditionalOnProperty(prefix = "rest.security", value = "enabled", havingValue = "true")`; the integration profile sets it false. Relevant matchers: `:150-154` `.permitAll()` for the `/rest/**` block, `:178` `.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority(Authority.WMS_USER_ROLE)`, `:181` `.anyRequest().authenticated()` |
| 10 | `SdrFunctionGuard` (Spring Data REST, keyed on exported **domain type**) | **YES but ships at `OFF`** per tenant | `FunctionGuardInterceptor.preHandle` first branch `if (SdrFunctionGuard.isSpringDataRestHandler(declaring))`; mode from `SdrGuardModeProvider`, sysprop `wms2.authz.sdr.unruled`. Irrelevant to SBDEV-3155 (all ten are MVC handlers), but it is a gate mechanism and the enumeration should not read as closed |

Two caveats the codebase itself flags and that a plan should carry:

- ~~**`securedEnabled` and `jsr250Enabled` are not pinned.**~~ **CLOSED 2026-09-01 by SBDEV-3156.** All three
  attributes are now pinned with a reason each, the two extra families are OFF, and the four annotations they
  enabled are banned from `src/main`. (The quoted `Sbdev3017TrancheGateContextTest` javadoc has itself been
  corrected, and its cited line range had drifted.)
- **Mechanism 9 is unobservable by any Spring-context test in this module**, by construction. The only
  coverage is source-level (`Sbdev3017OmsCarveOutSourceContractTest`).

---

## D. The three existing unit tests — all vacuous for gating

All three extend `BaseControllerUnitTest` and call the **plain** `setupMockMvc(...)`, which installs
**no interceptor**:

```java
// ClubLineControllerUnitTest.java:77
        setupMockMvc(clubLineController);

// TransfersControllerUnitTest.java:90
        setupMockMvc(transfersController);

// PickingOrderPositionControllerUnitTest.java:48
        setupMockMvc(controller);
```

`BaseControllerUnitTest.setupMockMvc(Object, Object...)`:

```java
        this.mockMvc = MockMvcBuilders.standaloneSetup(controller)
            .setCustomArgumentResolvers(
                new PageableHandlerMethodArgumentResolver(),
                new MockPrincipalArgumentResolver())
            .setMessageConverters(new MappingJackson2HttpMessageConverter(objectMapper))
            .setControllerAdvice(controllerAdvice)
            .alwaysDo(print())
            .build();
```

versus the guard-installing variant, which is the **only** MockMvc mode in this repo in which authorization is
exercisable:

```java
    protected void setupMockMvcWithGuard(Object controller, HandlerInterceptor interceptor) {
        this.mockMvc = MockMvcBuilders.standaloneSetup(controller)
            ...
            .addInterceptors(interceptor)
```

**Consequence: a gate test written into any of these three classes as they stand would pass whether or not any
gate exists.** `standaloneSetup` builds its mapping outside an `ApplicationContext`, so
`initApplicationContext` never runs and the `MappedInterceptor` bean of §C.4 row 1 is never detected — the
interceptor javadoc says this in terms:

> ⚠ Notably **not** `MockMvcBuilders.standaloneSetup(...)` … `BaseControllerUnitTest` must still call
> `.addInterceptors(...)` by hand, and a gate test written in that lane without it is still vacuous. Do not
> read "it is a bean now" as "standalone tests get it for free".

Ten classes currently use `setupMockMvcWithGuard`. The right template for SBDEV-3155 is
**`src/test/java/net/aim_ai/wms/unit/controller/ReportReadGateUnitTest.java`** (571 lines, SBDEV-3142): it
already constructs both `ClubLineController` and `TransfersController` with a real guard, with the exact
constructor arguments and the exact stubs needed to keep the ALLOW path off a 500:

```java
        clubLineController = new ClubLineController(keycloakService, 5000, customerorderBatchService,
                customerorderBatchRepository, locationRepository, dtoViewService);
        transfersController = new TransfersController(keycloakService, 5000, customerorderService,
                customerorderRepository, transferOrderService, locationRepository, billofladingService,
                dtoViewService);
        guard = new FunctionGuardInterceptor(accessService, new ObjectMapper(), new SimpleMeterRegistry(),
                SdrTestGuards.inert());
```

Four traps that class documents and that SBDEV-3155 inherits verbatim:

1. **Assert 403 specifically on the deny path.** A test asserting only 200 on the allow path passes with no
   interceptor at all.
2. **Status assertions pin *that* a gate exists, never *which* function.** Measured on
   `ShipperIdControllerActionGuardUnitTest`: swapping one endpoint's constant left **34 tests green**, because
   `denyEverything()` denies every function and `allowEverything()` allows every function. The per-endpoint
   function needs a separate reflection assertion (or the `Sbdev3017TrancheGateContextTest` rows).
3. **Key the reflection lookup on the mapped PATH, not the handler name**, and assert *exactly one* match —
   `getDeclaredMethods()` order is unspecified. For SBDEV-3155 this is not optional: `activeBatch` ≠
   `activateBatch`.
4. **`@RequestMapping(value=…)` vs `@GetMapping(path=…)`** — raw `Method#getAnnotation` does not resolve
   `@AliasFor`, so one attribute reads empty. `ReportReadGateUnitTest#mappedPaths` unions both.
   **Relevant here**: all ten SBDEV-3155 targets use `@GetMapping(path=…)`, while the SBDEV-3142 handlers on
   the same two classes use `@RequestMapping(value=…, method=…)`. A new helper that reads only `value()` sees
   **zero** of the ten.
5. Not from that class but from `PickingOrderPositionController` itself: `fixPickingPosition` calls
   `pickingorderPositionRepository.findById(id).orElseThrow(() -> new EntityNotFoundException(...))` on its
   first line, so the ALLOW path needs that stub or it 500s — and a 500 satisfies `isNotEqualTo(403)`.

`PickingOrderPositionController` has no guard-installing test today; its constructor is
`(KeycloakService, Integer maxPageSize, PickingorderPositionService, PickingorderPositionRepository)`.

---

## Blind spots in this report

1. **I did not run any test.** Every claim about assertions and counts is read from source; every claim about
   the deployed surface is read from a TSV generated by `SurfaceInventoryContextTest` in the SBDEV-3154
   worktree on 2026-09-01 (the code that became `ad681319`). If any handler mapping changed between that run
   and `ad681319`, the ten-row table and every false-positive count in §B.4 shift. Re-run
   `mvn test -Dtest=SurfaceInventoryContextTest` before treating the numbers as final.
2. **The `131` figure is what the source asserts, not what the suite currently proves.** I did not execute
   `thePinHasNotBeenQuietlyShrunk()`.
3. **`SurfaceInventoryContextTest` and `Sbdev3017TrancheGateContextTest` both extend
   `BaseRollbackIntegrationTest`**, i.e. they need a working Spring context and a database. I did not verify
   they are green on this checkout, only that they are surefire-visible by the `*ContextTest` naming
   convention the classes document.
4. **False-positive counts in §B.4 are computed over the `read`-labelled rows only**, matching the
   `!isMutating &&` short-circuit in the real heuristic. A token that also matches `MUTATE` rows (e.g.
   `/fixhub`) is invisible in those tallies by design.
5. **I did not verify which `FunctionEnum` constant each of the ten endpoints should carry.** That is an
   authz/design question (§9.16 Option B — a route takes its screen's existing function), and it is what the
   `<FN>` placeholders in §A.4 stand for. Getting it wrong is invisible to every status-based test (trap 2 in
   §D).
6. **I did not enumerate UI callers** of the ten endpoints in either UI repo. §C.2's conclusion that the three
   classes are not "shared" is read off `SHARED_CONTROLLERS`, which is a maintained list — it is not a fresh
   measurement of whether the mobile UI calls these paths. If it does, the list is what is wrong, not the rule.
