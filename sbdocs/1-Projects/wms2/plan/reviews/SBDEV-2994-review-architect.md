I have enough evidence. Full report below.

---

# ARCHITECT LANE — SBDEV-2994 adversarial review

**Verdict: the diagnosis is correct and Fix A is right. Fix B is largely dead code aimed at the wrong population, Fix C ships an internal string to an operator, Fix D's stated ordering rationale describes an unreachable condition, and the plan's §0 enumeration misses the single most important site in the estate — a fully-guarded sibling implementation of this exact screen that the mobile UI stopped calling.** Six load-bearing assertions in the plan are false against `origin/develop`. Details, then the three mandated sections.

---

## PART 0 — Load-bearing claims that do not survive contact with the code

I verified every §0 row. Rows 1–13, 14, 15, 17, 18, 21, 23–25 hold at the cited lines. The following do not.

### 0.1 — `MobileMoveStockService` is missing from the enumeration, and it is the whole ballgame

`v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveStockService.java:235` `selectDestination`, reachable via `MoveStockController.java:96` `POST /v3/moveStock/scanDestination`, **is a second, complete, correctly-guarded implementation of the reporter's screen.** It has every guard Fix B proposes to invent, plus more:

| Concern | `MobileMoveStockService` | `StockunitService.transferStock` |
|---|---|---|
| destination label misses | `:294-307` — validates against the `STRING_PATTERN_SEPARATE_STOCK` sysprop and throws **keyed** `BusinessException("noValidString", …)` with the expected format | `:156` `EntityNotFoundException` — the reported bug |
| valid-format unknown label | `:309-317` — **auto-creates the container at `Clearing`** | n/a |
| destination is Nirvana | `:320-324` | absent |
| source on-hold | `:240-242` | absent |
| damaged permission | `:250-258` | present at `:230-235` only in the `new`-container branch |

And `store/moveStock.js:133-151` still has the `scanDestination` action posting to `/moveStock/scanDestination` — **it is dead code.** Nothing dispatches `moveStock/scanDestination`; `components/moveStock/scanDestination.vue:184` dispatches `moveStock/transferStock` instead (verified by `git grep` across the whole mobile repo at `origin/develop`).

**The architectural root cause of SBDEV-2994 is that the mobile Move Stock screen was rewired off its purpose-built, guarded service onto the generic web endpoint, and the guards did not come with it.** The plan never finds this. Fix B is therefore not "adding a missing guard" — it is *re-implementing, in a third place, guards that already exist correctly in the service this screen was built on*, while the correct version rots unreachable one HTTP route away.

Note also `:300-306`: SBDEV-2962 (C6) touched this exact line weeks ago with exactly the "message must name the right expected thing" reasoning the plan claims is unwritten. **The precedent is recent, authoritative, keyed, and directly on point. The plan surveyed neither it nor the endpoint.**

### 0.2 — Fix B's `entity_lock` branches are unreachable; its value lives entirely in a branch the plan treats as an afterthought

Measured on `wms2-wineco-dev` (the tenant the plan itself used), full `unitload` table:

```
entity_lock | rows    | mangled ('-X-') | carrying stock
        405 | 411,862 |               0 |        395,984
          2 | 320,642 |         320,642 |              0
          0 |  22,262 |               0 |         19,472
```
```
loc      | entity_lock | rows
Nirwana  |           2 | 320,637
Nirwana  |           0 |       1     <- unitload id=66252, labelid='Nirwana'
Shipped  |         405 | 411,862
```

Read that carefully:

- **`GOING_TO_DELETE` is 100% mangled — 320,642 of 320,642.** Every single To-Delete unit load on this tenant is unreachable by label scan, so **Fix A's label miss always fires first and Fix B's `GOING_TO_DELETE` branch can never execute.** The plan's own manual test M4 concedes this ("seed one if none exists"). **P5 violation: a check that cannot fail.**
- **`ON_HOLD` (104) has zero rows.** Same problem, and see §Attack-5 for why it also has no precedent.
- The Nirvana-location branch has **exactly one** reachable target: unit load `66252`, `labelid='Nirwana'`, `entity_lock=0`, sitting at location `Nirwana`. That is the special sentinel UL — and an operator typing `Nirwana` into "Scan Destination Container" **resolves it today and moves stock into it**. `MobileMoveUnitloadService.java:122` guards exactly this; `MobileMoveStockService.java:320-324` guards exactly this; `transferStock` does not. **This is a real, live, silent data-loss path that the plan does not identify** — and Fix B closes it only by accident, via the location check rather than a label check.
- **The entire genuine value of Fix B is the `Shipped` branch: 411,862 scannable, unmangled labels, 395,984 of them carrying stock — ~95% of all scannable non-live labels on the tenant.** Fix B catches these *only* via `location.name == "Shipped"`, never via the lock check, because **they all carry `entity_lock = 405 (SHIPPED)`, a state Fix B does not enumerate.**

So Fix B as written is: two dead branches, one branch with a single target, and one branch doing all the work for a reason the plan never states.

**Architectural form problem:** `BusinessObjectLockState` has **eight** members (`WmsConstants.java:1258-1265`: `NOT_LOCKED 0`, `GOING_TO_DELETE 2`, `PICKED_FOR_GOODSOUT 100`, `QUALITY_FAULT 103`, `ON_HOLD 104`, `NOT_FOUND 403`, `TRANSFER 404`, `SHIPPED 405`). Fix B denylists two of the eight. A UL with `SHIPPED`, `TRANSFER`, `NOT_FOUND`, or `PICKED_FOR_GOODSOUT` at a non-Shipped location passes the guard and receives stock. **A denylist over an open enum is not a rule; it is a snapshot that silently drifts on the next enum addition.** The correct shape is an allowlist (`entityLock == NOT_LOCKED`, or a documented `ALLOWED` set with `QUALITY_FAULT` handled by the existing damaged branch) plus a location-class predicate.

### 0.3 — §12 Q4's evidence is wrong

The plan's parenthetical claims WineCo dev holds "210,167 at Nirwana with `entity_lock=0` that do carry stock". **There is exactly one**, and it carries no stock (it is the sentinel). 320,637 + 210,167 also does not equal the 320,638 rows actually at Nirwana. Q4's *conclusion* (nobody moves stock into these destinations) still stands on the `stockrecord` half, but the population figure that "clears" R3 is fabricated or misread and should not be relied on in review.

### 0.4 — Fix A changes `bulkTransferStock`, which the plan states three times is unchanged

`StockUnitController.java:163-167` — the `catch (EntityNotFoundException)` is **outside the `for` loop at `:142-162`**, not inside it.

Today, a dead label with N selected rows: row 1 throws `EntityNotFoundException` → escapes the inner catches → outer catch → **one** error, **loop aborts, rows 2..N never attempted** (and each `transferStock` commits its own transaction, so a partial bulk is already possible).

After Fix A: row 1 throws `BusinessException` → **inner** catch at `:154` → error appended → **loop continues** → N errors.

That is a behaviour change to a second endpoint. §0.2 row 15 says "no code change expected"; M6 says "Per-row errors, 200 — **unchanged** from today"; §12 says "`bulkTransferStock` is the correct one". All three are wrong. Parity pin `P1` (`grep 'getErrorMessage("Entity Not Found"'`) cannot detect it. The change is arguably an *improvement*, but it is unowned, untested, and mis-described — and the plan is simultaneously holding bulk up as the convention to converge on while that convention's defining artifact (a catch outside the loop that truncates a batch) is itself the bug.

### 0.5 — Fix A silently re-statuses a second HTTP endpoint

`RestExceptionHandler.java:118-124` maps `BusinessException` → **422**; `:153-159` maps `EntityNotFoundException` → **404**. `OrderCancellationController.java:58-63` `POST /{customerOrderId}/complete` propagates both (it declares `throws BusinessException`). So Fix A at `StockunitService.java:178` flips that endpoint from **404 → 422** for a missing `pickfromlocationname`. The plan's R4 is about *compilation*; the status change is never named. No UI consumes that endpoint today (`git grep` across all three UI repos: zero hits), so impact is low — but it is an unowned public-contract change.

Related: **`wms-exception-taxonomy.md` §3 is stale on precisely this row.** It states "`BusinessException` … **not** registered handlers in v2's `RestExceptionHandler` … propagate as 500." That has been false since a `@ExceptionHandler(BusinessException.class)` landed at `:118`. The plan contests the taxonomy's §6 decision tree without noticing its §3 is wrong about the very type it is proposing to switch to.

### 0.6 — Fix D's ordering rationale describes an impossible state

Plan §5 Fix D: *"validating before the reason pause means an operator is never asked to type a reason for a move that is about to be rejected. Ordering matters."*

`scanDestination.vue:118-122`, with a comment stating it explicitly: `isDamagedDestination` requires `currentMode === 'new'`. The reason pause at `:168` **is unreachable in `existing` mode**, which is the only mode that has a destination container to validate. The stated hazard cannot occur. Harmless, but it is the *only* justification given for a specific placement, and it is fictitious.

Two real Fix-D issues the plan does miss:
- `submit()` at `:141` is **synchronous**. Fix D requires `await`. Two existing Jest specs mount and drive it — `test/components/move-damaged-reason-payload.spec.js` (incl. `describe('SBDEV-2658 … existing-container mode')` at `:350`) and `test/pages/workflow-reset-on-entry.spec.js`. §0.3 "existing test surface that must not regress" lists three **Java** classes and **no mobile specs at all**.
- In `new` mode, `labelId = this.currentStock.unitLoad.labelid` (`:160`) — the **source** UL. An unguarded `checkContainer(labelId)` would probe the source. The plan does not scope the probe to `existing` mode; verify row `D2` (grep `checkContainer` in the .vue) would pass either way.

---

## PART (i) — STEELMAN ANTITHESIS

> **The plan solves the wrong problem, in the wrong repo, at a cost of three coordinated deployments, and Option 4 delivers the reported user outcome in four lines with zero server risk.**
>
> **1. The defect is a client-side error-extraction defect.** The server already answered. `RestExceptionHandler:156` puts the real string in `ProblemDetail.detail`; `plugins/axios.js:167-174` faithfully rejects with `error.response.data.detail` populated. The operator saw "network or server issue" because `store/moveStock.js:181` **throws that information away**. Every byte of what the operator needed was already on the wire. A four-line `backendMsg(error)` helper reading `error.response.data.detail ?? data.errors?.[0]?.message` in the `catch` prints `"UnitLoad not found by labelid: UL314581"` — naming the container, from `origin/develop`, today, with no server change, no message keys, no bundle-locale trap, no transaction question, no deploy ordering, and no behaviour change to a write path every warehouse uses. The plan files it as "out of scope, ~18 modules" — but nobody asked for 18 modules; **one** module fixes SBDEV-2994.
>
> **2. Fix A's real justification is aesthetic, not functional.** After Option 4, what does Fix A buy? A nicer string and a 200 instead of a 404. Those are worth having, but they are not what the ticket reports, and they are being bought by changing the exception type on a `@Transactional` write path shared by an interactive controller, a bulk controller, and a **non-interactive system replay** — with **no runnable lane that can observe the contract change** (D1: Testcontainers dead per SBDEV-2217; the controller unit lane is `standaloneSetup` with no `setControllerAdvice`, so `RestExceptionHandler` is absent there too). Every claim in §8.2 about "returns 200" is a claim about a `@ControllerAdvice` **that is not loaded in the test that asserts it.** The plan's own acceptance is `grep`.
>
> **3. Fix B is a new business rule on a hot write path, justified by a scenario that cannot occur.** 320,642 of 320,642 To-Delete ULs are mangled; zero On-Hold ULs exist. Two of four branches are provably dead on the tenant the plan measured. What remains is a Shipped-location rule that the plan treats as a footnote and an enum denylist that omits the state 100% of that population actually carries. **The rule is being introduced without its author having established what it refuses.**
>
> **4. It rebuilds what already exists.** `MobileMoveStockService.selectDestination` is the same feature, correctly guarded, keyed, and recently maintained (SBDEV-2962). The mobile UI's own `scanDestination` action still points at it and is dead. **The one-line fix — repoint `scanDestination.vue:184` at the guarded action — is not in the plan's option set,** because §0 never enumerated the endpoint.
>
> **5. Three repos, three PRs, no version negotiation.** Fix B's probe fold makes `isUnitLoadIdValid` reject existing-but-unusable containers; the web toast that must change to stay true lives in a *different repo with a different deploy cadence*. §7.1's deploy-order row names only api and mobile. **API-first — the order the plan prescribes — is exactly the order that makes the desktop lie.**

---

## PART — the five specific attacks

### Attack 1 — Is "whose input produced the miss" a sound axis?

**No, not as stated. It is not stable, not enforceable, and not mechanically checkable — and it is empirically false as a description of the codebase.**

**It is not stable.** Site `:178` is the counterexample the plan itself supplies and then waves through. Three callers reach it: the web dropdown (operator-chosen), mobile's hardcoded `'Clearing'` (`scanDestination.vue:152` — a **constant in the client**, exactly the "internal constant" the rule says stays `EntityNotFoundException`), and `CancellationReversalService:203` replaying a **logged** `pickfromlocationname` with no human in the loop. The axis assigns three different answers to one throw site, and the plan resolves it by taking the union — which means the axis reduces to "if *any* caller might be interactive." That is a rule that ratchets one way only: every shared site eventually becomes `BusinessException`, and the split dissolves.

**It is not enforceable.** The axis is a property of the *call graph*, not of the throw site. Nothing at `StockunitService.java:178` tells a future author where `locationName` came from. A new system caller added tomorrow silently inherits an operator-framed message and a 422. The plan writes the discriminator into a doc (§7 step 9) and pins it with `grep` (`A3`) — neither survives a refactor. Compare `verify-script-rows-go-stale-when-a-refactor-moves-code`.

**It is empirically false.** The plan claims "this is already how `MobileMoveUnitloadService` behaves." It is not. In that same class:
- `:126-130` — scanned label misses → `BusinessException` ✓ (the half the plan cites)
- `:254` — **the same scanned label**, in `scanDestination`, → `EntityNotFoundException` ✗

`:254` even has orphaned dead code at `:256-258` (`if (sourceUnitLoad == null)` after an `orElseThrow`) — the fingerprint of the same mechanical null-safety sweep that produced `:156`. And `MobileMoveStockService:143` does the same thing. **The precedent is 50/50, and the plan cited only the supporting half.**

**A better axis — and it is already in the codebase.** Replace "whose input" (a call-graph property, invisible locally) with **"is the identifier part of the endpoint's declared input contract?"** — a property of the *signature*, visible at the throw site and mechanically checkable:

> A miss on a value that arrived as a **parameter of the enclosing public method** is a `BusinessException`. A miss on a value **derived inside the method** (a field of an already-loaded entity, a `WmsConstants` literal, a sysprop key) is an `EntityNotFoundException`.

Apply to §0.1: rows 1 (`unitLoadLabelId`) and 2 (`locationName`) are method parameters → `BusinessException`. Rows 3–13 are all derived (`stockUnit.getUnitloadId()`, `pallet.getStoragelocationId()`, `UNIT_LOAD_TYPE_PALLET`, `WAREHOUSE_NAME`) → `EntityNotFoundException`. **Identical verdicts on all 13 rows**, but now the rule is local, survives caller changes, and answers `:178` without argument: it is a parameter, full stop, regardless of who fills it. It also correctly classifies `MobileMoveUnitloadService:254` as *wrong today* rather than as a precedent to be explained away — which is the honest reading.

**Naming, separately:** the plan's `transferStock.destinationUnitloadNotFound` is a **fourth** key convention (`BusinessException.ObjectNotFound` in taxonomy §5; bare camelCase `putawayDestinationNotPermitted` in SBDEV-2732; `noValidString` at `MobileMoveStockService:305`). Pick SBDEV-2732's bare-camelCase — it is the most recent and the largest cohort. **P3 violation as written.**

### Attack 2 — Fix C: is `LOG.error` sufficient for the 404→200 downgrade?

**The downgrade concern is real but the plan has it backwards, and the mitigation is in the wrong file. There is a worse problem the plan does not see.**

First, the correction: `RestExceptionHandler.java:155` logs `EntityNotFoundException` at **`LOG.debug`**. Genuine referential corruption on `transferStock` is *already* invisible in any environment where debug is off — which is all of them. So Fix C's `LOG.error` is a **strict observability improvement**, not a downgrade. R1 overstates the risk it is mitigating.

Which immediately raises the better move: **the one-line fix is `RestExceptionHandler:155` `debug` → `warn`.** That covers *every* `EntityNotFoundException` in all 61 controllers, not just this one, is smaller than Fix C, and needs no new catch. Fix C's `LOG.error` gives one endpoint what the whole estate needs. The plan never considers the handler.

**The problem the plan does not see.** Fix C's catch does `errors.add(getErrorMessage("Entity Not Found", e.getMessage()))`, and `store/moveStock.js:173` renders `results.errors[0].message` **verbatim to a warehouse operator on a handheld**. Those messages are `"Location 4471"`, `"UnitLoadType not found by name: pallet"`, `"Client 55750"` — internal entity names and raw primary keys. Fix C therefore replaces an unactionable-but-neutral toast with an **unactionable, confusing, and mildly information-disclosing** one, and it does so for §0.1 rows 3–13, which the plan itself classifies as "the operator can do nothing; an engineer must." **You cannot simultaneously hold that these are engineer-only faults and route their raw text to the operator's screen.** That is an internal contradiction between §0.1's split rule and Fix C's body.

**Recommendation:** keep the catch; log `e` at `warn`/`error` **with the raw message**; return a **fixed, operator-safe string** plus a correlation token, e.g. `errors.add(getErrorMessage("Entity Not Found", "This move could not be completed. Report reference " + id + " to support."))`. That satisfies P1 (the type still routes), P4 (true under every future), and R1 (loud in logs) without teaching operators to read FK ids. And it makes the 404→200 downgrade defensible, which the current draft does not.

On the metric question: **no new Micrometer counter is needed** and §10 row 8 is right to decline one — but only if the logging fix lands at `RestExceptionHandler`, where it produces one greppable signal for the estate. Fix C alone leaves 60 controllers silent, so "we have monitoring" would be a false comfort.

### Attack 3 — Layering: controller probe → service usability predicate

**The dependency direction is fine; the transaction and failure semantics are not, and §10 row 3 is factually wrong about its own design.**

`StockunitService` has **no class-level `@Transactional`** (`:18-19`, `@Service` only), and `spring.jpa.open-in-view=false` (`application.properties:55`). The probe path (`isUnitLoadIdValid`) has **no** transaction; `transferStock` (`:149`) does. So the same predicate runs under two different regimes:

- **Service path**: inside the existing tx. Free, consistent. Fine.
- **Probe path**: `unitloadRepository.findByLabelid` opens tx#1 and closes it; `canReceiveStock`'s `locationRepository.findById` opens **tx#2** and closes it. Two connection acquisitions, two round trips, a read-consistency gap between them, and — because OSIV is off — no session to fall back on. §9 row 2 ("adds one short read per scan") counts one; it is two, on a per-keystroke-submit endpoint the desktop calls on *every* transfer including bulk.

**The real defect is the exception contract.** `canReceiveStock` as specified in §5 does `locationRepository.findById(...).orElseThrow(EntityNotFoundException)` — an unchecked throw — inside a method now called from a controller **with no try/catch**, on an endpoint whose entire declared contract is `Boolean`. A broken `storagelocation_id` FK turns a `true`/`false` probe into a **404**. And the web store's `checkContainer` (`store/handlingUnits/stockUnits.js:209-219`) catches, logs, and **leaves `validContainer` at the `false` pre-committed at `transferStock.vue:141`** — so the operator gets the generic network toast *and* "Container is not available to receive stock" for a container that is perfectly usable. **Two toasts, both wrong. This is SBDEV-2994's exact failure mode, reintroduced on the probe.**

**Fix:** `canReceiveStock` must be **total** — no throws, `Optional`/`orElse(null)` internally, unresolvable FK ⇒ `false` (fail-closed on a probe is correct; the write path still gets the typed error). And §10 row 3 must be corrected: `canReceiveStock` **is** a service entry point the moment `stockunitService::canReceiveStock` appears in a controller (a method reference cannot bind a private method), so it needs `@Transactional(value="tenantTransactionManager", readOnly=true)` and the checklist's "N/A" is wrong.

### Attack 4 — Deploy ordering / contract versioning

**Yes, and the plan prescribes the hazardous order.**

§7.1's Deploy-order row reasons entirely about Fix D and names only "API first, mobile UI second." It never mentions `wms2-web-ui`, which §12 Q1 put in scope. The dependency it misses:

**Fix B's probe fold (api) and the toast reword (web) are one semantic change split across two independently-deployed repos.** In the window between them:

| order | window behaviour |
|---|---|
| **API first** (what §7.1 says) | probe now returns `false` for an existing, unmangled, Shipped container — **411,862 of them on WineCo dev** — and the desktop says **"Container does not exist."** For a container that visibly does exist, that the operator can see on a shelf. **This is precisely the untruth §12 Q1 was written to eliminate, and the prescribed order manufactures it.** |
| **Web first** | toast reads "Container is not available to receive stock" while the probe is still existence-only. The container genuinely is not available (it doesn't exist). **Still true.** |

**Correct order: web-ui first (or same release), then api, then mobile.** Alternatively: split step 6 — reword the toast in the web PR, land the probe fold only after the web PR is deployed. Either way it must be written down; "not a hard coupling" is wrong for the web half.

Second, unnamed hazard: the acceptance gate is **atomic across three repos** (`PROJECT_ROOT`/`MOBILE_ROOT`/`WEB_ROOT`, `Result: N pass, 0 fail`) while deployment is not. The green line will imply a coherence the estate will not have for however long the three PRs take to land. Worth a sentence in §8.7.

Third: nothing in the estate depends on `transferStock` returning 404. Verified — the only two consumers are `wms2-mobile-ui store/moveStock.js:167` and `wms2-web-ui store/handlingUnits/stockUnits.js:159`, both blanket-catch; `plugins/axios.js:35-39` retries **only** 401/403. **The 404→200 change is safe from a client-contract standpoint.** That part of the plan is sound.

### Attack 5 — Is Fix B's guard in the right layer?

**No. It wants a shared collaborator, and one already exists in better shape than the guard being written.**

Counting after Fix B, the estate would hold **four** hand-rolled implementations of "can this destination receive stock":

1. `MobileMoveUnitloadService:288-296` — Nirvana/Shipped, but on the **scanned destination *Location***, not on a destination unit load's current location. **The plan mis-cites this as its model; the predicates are not the same shape.**
2. `MobileMoveUnitloadService:260-262` — the plan cites this as the on-hold **destination** guard. **It is not.** `sourceUnitLoad.getEntityLock() == ON_HOLD` is the **source**. `:265-269` is the source's stock units. **There is no destination on-hold guard anywhere in that class.** Fix B's `ON_HOLD` branch is therefore *newly invented*, not precedent-backed — and it has zero rows to act on (`entity_lock=104`: 0 rows tenant-wide). **P3 + P5 violation.**
3. `MobileMoveStockService:320-324` — destination-is-Nirvana, on the destination **unit load**. This is the genuinely matching precedent, and it is unmentioned.
4. Fix B's new `assertDestinationCanReceiveStock`.

Four spellings of one predicate, three of them disagreeing about which entity they apply to, none sharing a message key. The next ticket adds a fifth.

**The synthesis: extract one collaborator, don't add a fourth site.** `DestinationEligibilityService` (or a method pair on `UnitloadService`) exposing `assertCanReceiveStock(Unitload)` / `canReceiveStock(Unitload)` (total, non-throwing), keyed to one message key, with an **allowlist** on `entityLock` and an explicit location-class predicate. Then `StockunitService`, `MobileMoveStockService`, and `MobileMoveUnitloadService` all call it. That is P3 satisfied for real.

**And before any of that, the cheaper structural question the plan must answer:** should `scanDestination.vue:184` simply dispatch the existing, guarded, dead `moveStock/scanDestination` action instead of `moveStock/transferStock`? That is a one-line UI change that inherits *all* the guards, the `noValidString` keyed message, and the auto-create affordance — and it makes Fix B unnecessary on the mobile path entirely. It may well be rejected (the web path still needs guarding; the two flows have diverged; `MobileMoveStockService` may have its own gaps). **But it cannot be rejected by a plan that does not know the endpoint exists.**

---

## PART (ii) — THE REAL TRADEOFF TENSION

> **An unknown destination label is either an error to report or a container to create. The two live implementations of this screen already answer differently, and no amount of engineering makes both answers true at once.**

- `MobileMoveStockService:294-318`: an unresolvable destination label that **matches** `STRING_PATTERN_SEPARATE_STOCK` is **not an error** — the system creates the container at `Clearing` and proceeds. Only a *malformed* label errors, with `noValidString` naming the expected format.
- `StockunitService.transferStock:156` + Fix A: **every** unresolvable label is a hard rejection, and the message the plan proposes actively instructs the operator to give up — *"scan a container that is currently in use."*

These are not two error messages. They are **two product decisions about what "Existing Container" means**, and they are irreconcilable: either an unknown well-formed label is a create-affordance or it is a rejection. Fix A's message forecloses the create-affordance on the `/stockUnit/transferStock` path **and does so silently**, as a side effect of an error-taxonomy ticket, while the sibling screen keeps the opposite behaviour.

Why this cannot be resolved by more work:
- **Adopt create-on-scan** → the reported incident stops being an error at all (`UL314581` matches no pattern? then it errors on *format*, with a different message; if it does match, you create it and the ticket's premise dissolves) — but you inherit the sysprop dependency, and you have changed a write path's semantics far beyond the ticket.
- **Adopt hard rejection** (the plan) → simple, honest, matches the web UI's existing pre-validation — but the two mobile screens now teach operators contradictory rules for the same scan gesture, and the message "scan a container that is currently in use" is *false guidance* on the other screen.
- **Make them the same** → that is a product change requiring Zeshan's input, not a bugfix, and it is bigger than SBDEV-2994.

There is no third option that keeps both. **The plan must pick one explicitly and say so in §12; it currently picks rejection by accident.** My recommendation is hard rejection (matches the web pre-validation, smaller, no sysprop coupling) **with the divergence recorded as a known inconsistency and a follow-up ticket**, and with the message reworded per P4 below.

Secondary, genuinely-either/or tension: **testability vs. correctness of the assertion.** D1 says nothing can observe the HTTP contract change. You may have a test that asserts the *type* (`getKey()`, in the service lane, real) **or** you may have a test that asserts the *status* (`200 {errors}`, in a `standaloneSetup` controller lane where `RestExceptionHandler` is not registered, therefore **vacuous**). §8.2's `transferStock_entityNotFound_returns200WithErrors` is in the second category: it will pass on the *unfixed* tree too, because without `setControllerAdvice` an escaping `EntityNotFoundException` in `standaloneSetup` does not become a 404 — it becomes a thrown exception the test asserts against differently. **That test is either a real assertion or it is theatre, depending on a `setControllerAdvice` call the plan does not mention.** Verify row `T4` greps for the method *name*, so it cannot tell the difference. Either add `.setControllerAdvice(new RestExceptionHandler())` to the builder and assert both statuses, or stop claiming §8.2 covers the contract.

---

## PART (iii) — SYNTHESIS

Keep the plan's spine. Change five things.

**S1 — Keep Fix A, re-found it on a local axis.** Ship both sites. Replace §5.4's "whose input produced the miss" with **"is it a parameter of the enclosing public method?"** Same 13 verdicts, locally decidable, refactor-stable, and it correctly labels `MobileMoveUnitloadService:254` / `MobileMoveStockService:143` as *unfixed*, not as precedent. Add both to §0 as known-divergent, out of scope. Use bare-camelCase keys (SBDEV-2732 cohort). Follow taxonomy §5 exactly for the bundle test: `getLocalizedMessage(Locale.ROOT)` **and** `Properties.load` **with an explicit UTF-8 reader** (`Properties.load(InputStream)` is ISO-8859-1; `PropertyResourceBundle` is UTF-8) — the worked pattern is `UnitloadBusinessServiceUnitTest` T14b.

**S2 — Reshape Fix B around what it actually refuses.** Lead with **Shipped** (411,862 reachable labels, 395,984 with stock — the real exposure) and the **`Nirwana` sentinel scan** (`unitload 66252`, resolvable today, currently silently accepts stock — arguably the most serious thing in this whole review, and unreported). Convert the lock check from a two-member **denylist** to an **allowlist** over the eight `BusinessObjectLockState` members. Drop the `ON_HOLD` branch or justify it on its own merits — it has no precedent (`:260` is the *source*) and no rows. Keep `GOING_TO_DELETE` for completeness but say plainly in the plan that Fix A subsumes it on every mangled UL (320,642/320,642) so nobody mistakes it for the fix.

**S3 — Extract, don't duplicate.** One `canReceiveStock(Unitload)` / `assertCanReceiveStock(Unitload)` collaborator, **total** (no throws in the predicate form), one message key, called from `StockunitService`, `MobileMoveStockService`, and `MobileMoveUnitloadService`. Mark the predicate `@Transactional(readOnly=true, value="tenantTransactionManager")` and fix §10 row 3. Separately, add a §12 question: *should `scanDestination.vue:184` dispatch the existing guarded `moveStock/scanDestination` action instead?* — with `MobileMoveStockService.selectDestination` and the dead `store/moveStock.js:133-151` action as the evidence.

**S4 — Fix C: operator-safe body, and move the loudness one layer up.** Keep the catch. Log the raw `e` at ERROR **in the catch**, return a **fixed** operator-safe string + the stock-unit id as a support reference — never `e.getMessage()`. Then add the one-line change the plan missed: `RestExceptionHandler:155` `LOG.debug` → `LOG.warn`, which buys the same observability for all 61 controllers at a fraction of Fix C's blast radius. Add a verify row that the catch does **not** interpolate `e.getMessage()` into the response.

**S5 — Ordering, and the option the plan never priced.** Rewrite §7.1: **web-ui first, then api, then mobile** — API-first makes the desktop say "Container does not exist" about 411,862 containers that do. Note in §8.7 that the three-root green implies a coherence the deploy pipeline does not provide. And add **Option 4** (the ~4-line `backendMsg` extraction in `store/moveStock.js:179-182`) to §12 as an explicitly-priced, explicitly-rejected alternative — it is the smallest thing that closes the reported ticket, and a reviewer is entitled to see why it was passed over rather than have it filed under "Fix E, ~18 modules."

**Not blocking, but do it:** correct §12 Q4's population figures (1, not 210,167); correct §0.2 row 15 / M6 / §12 to say `bulkTransferStock` **does** change (loop no longer aborts; N errors instead of 1) and pin it with a test; name the `OrderCancellationController` 404→422; add the mobile Jest specs to §0.3; drop Fix D's fictitious ordering rationale and replace it with the two real ones (`submit()` must become `async`; scope the probe to `existing` mode).

---

## PRINCIPLE VIOLATIONS

| # | Principle | Violation | Severity |
|---|---|---|---|
| V1 | **P5** — a check that cannot fail is worse than no check | Fix B's `GOING_TO_DELETE` branch: 320,642/320,642 such ULs are mangled, so Fix A always fires first. `ON_HOLD` branch: **zero** rows tenant-wide. Two of four branches are dead. | **High** |
| V2 | **P3** — converge on existing precedent | `MobileMoveStockService.selectDestination` (`:235`, via `MoveStockController:96`) is the same feature, fully guarded, keyed (`noValidString`, SBDEV-2962), and its mobile action is **dead code**. Never enumerated. Fix B becomes a 4th implementation. | **High** |
| V3 | **P1** — the type is the routing decision | Fix C routes `EntityNotFoundException` to a 200 **and puts `e.getMessage()` ("Location 4471") on an operator's handheld** — the same rows §0.1 classifies as "an engineer must." The type-based split is contradicted by the body. | **High** |
| V4 | **P4** — the message must be true under every recoverable future | §7.1's prescribed **API-first** deploy makes the desktop say "Container does not exist" for 411,862 existing Shipped containers, for the whole inter-deploy window. §12 Q1 exists to prevent exactly this. | **High** |
| V5 | **P3 / precedent mis-citation** | `MobileMoveUnitloadService:260-267` is cited as an **on-hold destination** guard; it is a **source** guard. `:288-296` is cited as the model for a destination *unit load's* location; it guards a scanned destination **Location**. `:254` (same-class, scanned label → `EntityNotFoundException`) contradicts the split rule and is omitted. | **Medium** |
| V6 | **P2** — fix at the throw site, net at the boundary | The net is placed at one controller. `RestExceptionHandler:155` already logs these at **`debug`** for all 61 controllers — the boundary fix is one line and is not in the plan. | **Medium** |
| V7 | **P5** (assertions) | §8.2's `transferStock_entityNotFound_returns200WithErrors` is vacuous unless the builder calls `.setControllerAdvice(...)`, which the plan never specifies; verify `T4` greps the method **name**, so it cannot distinguish a real assertion from theatre. | **Medium** |

---

## VERIFY-SCRIPT NOTES

Structurally the best-negative-tested script I have reviewed in this vault — the `[ -f "$2" ] || return 1` hardening, the `file_contains_n_times` counter for `C1` (1 today → 2 after), and the uniqueness of the `A1b`/`A2b` literals all check out. I confirmed `"UnitLoad not found by labelid: "` appears **once** in `StockunitService.java` (`:156`) and `"Location not found by name: " + locationName` once (`:178`; `:388` concatenates `STORAGE_LOCATION_DAMAGED`, so `A2b` is correctly tempered). `"Container does not exist"` appears once in the whole web repo. Real gaps:

1. **`T3` green-lights the wrong bundle test.** It greps `Properties` && `\.load\(`, which passes the ISO-8859-1 `Properties.load(InputStream)` form — the exact variant taxonomy §5 warns against. Require the UTF-8 reader and `getLocalizedMessage(Locale.ROOT)`.
2. **`T4` is name-only** and cannot see whether `setControllerAdvice` is wired. Grep for `setControllerAdvice` in `$TEST_CTL` as well, or the row proves nothing (V7).
3. **No row detects the `bulkTransferStock` behaviour change** (§0.4). `P1` greps a string that survives it.
4. **No row forbids `e.getMessage()` in Fix C's response body** (V3). Add a negative.
5. **`D2` cannot distinguish `existing`-mode-scoped from unscoped**, so a probe on the source UL in `new` mode passes.
6. Latent: `file_contains_n_times`'s `count=$(grep -cE ... || echo 0)` yields `"0\n0"` on zero matches (`grep -c` prints `0` *and* exits 1), so the `[ ... -ge n ]` errors out. Harmless here (`$CTL` has 1 match), but it will bite a future reuse.

---

## WHAT I DID NOT COMPLETE

- I did not re-run the verify script; the reported 4/21/1 baseline is consistent with everything I read, and the four parity pins (`A3`, `P1`, `P2`, `P3`) are all green on `origin/develop` by inspection.
- I did not audit §0.2 row 22's "~10 mobile / ~8 web store modules" count — it is scoped out and nothing turns on the exact number.
- I could not execute any Java test (D1 stands: `mvn` was not run in this lane).
- The Shipped/Nirvana/lock-state population figures are from **`wms2-wineco-dev` only**. I did not re-measure Hydra UAT; the plan's Q4 claims to have, but given that its WineCo figures are wrong, **its Hydra figures should be re-run before R3 is treated as cleared.**

**Files, all absolute:**
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveStockService.java` (the unenumerated sibling, `:235-345`)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/controller/mobile/MoveStockController.java` (`:96`, `/v3/moveStock/scanDestination`)
`/home/nampark/dev/wms-claude/v2/wms2-mobile-ui/store/moveStock.js` (`:133-151` dead action; `:167-183` the live one)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/controller/StockUnitController.java` (`:163-167` catch outside the loop; `:557-564` probe)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` (`:118-124` BusinessException→422, absent from the taxonomy; `:155` `LOG.debug`)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java` (`:254` counterexample; `:260-267` source-not-destination)
`/home/nampark/dev/wms-claude/v2/wms2-web-ui/store/handlingUnits/stockUnits.js` (`:209-219` probe catch leaves `validContainer=false`)