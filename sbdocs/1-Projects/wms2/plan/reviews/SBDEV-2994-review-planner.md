The report did run — full file reads and `git show origin/develop` verification against api `d2bedc0`, mobile `8e623b8`, web `d4f71c1`. Re-emitting it in full below.

---

# RALPLAN-DR — SBDEV-2994 (Planner lane, DELIBERATE mode)

**Verdict up front:** the diagnosis is correct and well-evidenced; the *fix shape* is defensible but the plan is not implementation-ready. I found **one false technical claim**, **three pre-existing green tests the plan will break and never lists**, **an internal contradiction about `canReceiveStock`'s visibility**, **a backwards premise under Fix C**, **an unstated behaviour change to `bulkTransferStock`**, and **six more verify-script defects** in the same class as the two the author already caught. I disagree with the author on 2 of the 5 contested calls (d, and partially b), and I want the split rule (a) restated on a different axis.

---

## 1. PRINCIPLES the plan implicitly operates under

**P1 — An error's *type* is its routing decision, not its description.** In this codebase the exception class alone decides HTTP status, rollback behaviour, log level, and whether a caller's `catch` can even see it. Choosing `BusinessException` over `EntityNotFoundException` is choosing four things at once, so the plan is really arguing about *routing*, not wording.

**P2 — Fix at the throw site, net at the boundary.** Fixes A/B type the error where the knowledge lives; Fix C catches whatever escapes. The plan consistently treats the net as *additive*, never as a substitute (§5 Fix A: "Fix C is still worth doing, as a net, but it is not a substitute"). This principle is what makes A+C non-redundant rather than belt-and-braces.

**P3 — Converge on an existing in-repo precedent rather than invent a convention.** Explicit in §5 Fix C ("converge on the sibling"), §5 Fix D ("mirror the web UI"), §5.4 ("this is already how `MobileMoveUnitloadService` behaves — the taxonomy just never wrote it down"). **This is the principle most damaged by my findings** — the chosen precedent (`bulkTransferStock`) is a 1-of-12 outlier, not the convention. See §7 G4.

**P4 — A message must remain true under every recoverable future.** Drives the "cannot receive stock", never "does not exist" wording (§5 Fix B), because `UnitloadBusinessService:532-538` / `:738-740` can un-mangle and restore a Nirvana'd label. A good principle, consistently applied.

**P5 — A check that cannot fail is worse than no check.** Runs through §8.7's two recorded script defects, the `getKey()`-not-rendered-copy rule (§8.1), and the baseline-discipline header of the verify script. I hold the plan to this principle in §7 G9 and find it wanting in six further places.

---

## 2. DECISION DRIVERS (top 3)

**D1 — There is no runnable lane that can observe the contract being changed.** SBDEV-2217 kills Testcontainers, *and* `BaseControllerUnitTest.java:50` builds MockMvc via `MockMvcBuilders.standaloneSetup(controller)` with **no `.setControllerAdvice(new RestExceptionHandler())`**. So `RestExceptionHandler:153-159`'s `EntityNotFoundException → 404 ProblemDetail` mapping — the pivot of the entire root cause — is exercised by **nothing that runs**. Every design choice must be gradeable by grep, by a Mockito `verify`, or by a human on dev. Nothing else exists. The plan's §8.5 understates this as "no IT."

**D2 — Blast radius is measured in behaviour change, not lines.** Fix A is a pure type swap on two throws — near-zero behavioural risk. Fix B is a **new business rule** that refuses moves which succeed today, on a write path every warehouse uses. These are different risk classes, and §7.1's flat "No sysprop gate. This is a message-quality fix with no behavioural risk worth gating" elides that difference on the ticket's only genuinely risky change.

**D3 — Which precedent is authoritative.** `bulkTransferStock:163-167`, `MobileMoveUnitloadService:126-130`, `CancellationReversalService:186-188`, `store/cancellation.js:44-48`, and `wms-exception-taxonomy.md` §6 all disagree with one another about this exact case. The plan picks winners without acknowledging that it is picking.

---

## 3. VIABLE OPTIONS

### Option 1 — the plan's shape: A+B+C+D, typed at the throw site
- **Pro:** fixes the reported defect at the root; gives `CancellationReversalService` (a non-HTTP caller) a distinguishable error; establishes a discriminator future authors can follow; Fix C nets the other 11 internal lookups.
- **Con:** Fix B is a behaviour change riding on a message-quality ticket, cleared only by a dev/UAT measurement (§6d); three repos → three PRs → three review cycles for one toast; breaks 3 currently-green tests the plan never lists (§7 G1).

### Option 2 — "controller-catch only" (C alone)
- **Pro:** one file, one hunk, zero behaviour change, and it *immediately* ships the operator a real string — `"UnitLoad not found by labelid: UL314581"` already beats the network toast.
- **Con:** flattens a scan mistake and an FK corruption into one indistinguishable `"Entity Not Found"` type; leaves `CancellationReversalService:203` unable to discriminate either; the message is developer-voice, not operator-voice (it names a Java class and a column).
- **Invalidation: none — this is genuinely viable as a hotfix.** If this were blocking a warehouse today I would ship C alone same-day. It is not sufficient as the ticket's resolution.

### Option 3 — "client-side only" (D alone)
- **Invalidation, and this one *is* invalid.** `isUnitLoadIdValid` is a **separate request** from `transferStock`. Pre-validating narrows the window; it cannot close it. The plan already knows this: §1.4's own reproduction instruction for the desktop is "*only if* the client-side `checkContainer` probe is bypassed." Shipping D alone would make the defect *harder to reproduce* without making it *less possible* — the worst possible outcome for a support queue, because the next report arrives with no reproduction steps.

### Option 4 — **the plan never enumerated this one: mobile-store error extraction (call it E′)**
`v2/wms2-mobile-ui/store/cancellation.js:44-48` on `origin/develop` already contains exactly the helper §5 Fix E calls "cross-cutting" and defers:
```js
function backendMsg(error, fallback) {
  return (error && error.response && error.response.data && error.response.data.errors && error.response.data.errors[0])
    ? error.response.data.errors[0].message : fallback
}
```
and `scanTote` (~`:75-77`) even special-cases `error.response.status === 404` into an actionable sentence. **§0.2 row 22's census is therefore wrong** — it is ~9 blanket-toast modules, not ~10, and one module in the same repo already broke the pattern and shows the shape.
- **Pro:** ~4 lines in `store/moveStock.js`; no server change; no deploy ordering; fixes *every* 4xx on the Move Stock screen, including the 11 internal-lookup 404s Fix C exists to cover.
- **Con:** a 404 `ProblemDetail` carries `detail`, not `errors[0].message`, so `backendMsg` alone still falls back — it needs an `error.response.data.detail` arm. Purely cosmetic; the server still lies with a 404 and `CancellationReversalService` still can't discriminate.
- **My position:** not a replacement for A, but a **strictly cheaper** replacement for the operator-visible half of **Fix C**. It belongs on the table the moment anyone argues the 404→200 downgrade isn't worth it. The plan should say why it isn't taking it.

**Recommendation:** Option 1, but **split Fix B out of this ticket** (§6d) and add the missing test work in §7.

---

## 4. PRE-MORTEM — three concrete failure modes, 6 months post-merge

### PM-1 — "Container is not available to receive stock" becomes the new unactionable toast, on the desktop
Fix B folds `canReceiveStock` into `isUnitLoadIdValid` (`StockUnitController.java:557-564`). Its body does `locationRepository.findById(destination.getStoragelocationId())`. `Unitload.storagelocationId` is a plain `Long` with no FK-backed guarantee and `getEntityLock()` returns `Integer` (`model/Unitload.java:12,23,37`). On any tenant where a UL carries a `storagelocation_id` pointing at a deleted `location` row — or `NULL` — the probe throws `EntityNotFoundException` out of a method that has **no `try`**, so it 404s. `store/handlingUnits/stockUnits.js:209-218`'s `checkContainer` catches that and fires:

> *"Error: Request failed due to a network or server issue. Please retry."*

**The exact toast this ticket exists to eliminate — now on the desktop, on a perfectly healthy container.** Six months later this reopens as "the SBDEV-2994 fix broke desktop transfers."

*The mechanism is provable today:* `StockUnitControllerUnitTest.IsUnitLoadIdValid.returnsTrueWhenUnitloadExists` (~`:1030-1045`) builds `new Unitload()` with only `labelid` set, so `getStoragelocationId()` is `null`. That test goes red the moment Fix B lands.

### PM-2 — On-hold destinations were in live use on a tenant nobody measured
R3 was cleared against **WineCo dev** and **Hydra UAT** only. Per the tenant Flyway runbook a v2 **production** landlord (`wms2_landlord` @25061) carries a live tenant; there is no MCP for it in this session, so it was not measured and cannot be from here. Separately the ON_HOLD half of the query is structurally blind: it looked for `MANUAL_SPLIT`/`MANUAL_TRANSFER` rows whose destination UL **currently** carries `entity_lock IN (2,104)`. On-hold is a *toggle* — `setLockOnHold` (`StockUnitController:334`) and `removeLock` (`:474`) are endpoints on this very controller. Any UL that was on hold at move time and has since been released is **invisible** to that query. Six months on, a QA-hold workflow ("park it on hold → consolidate into it → release the lot") silently stops working; operators blame the scanner; and because Fix B returns a clean `BusinessException` → HTTP 200, the failure never trips a 5xx alert.

### PM-3 — Fix C's 404→200 downgrade hides slow referential rot, exactly as R1 feared, because R1's mitigation was never verifiable
Fix C's only mitigation is `LOG.error`. R2's verification step is "force one internal-lookup failure on dev and confirm the line appears" — that verifies the **dev** sink and says nothing about prod. §10 row 8 explicitly declines a Micrometer counter. Six months later a botched tenant migration leaves `unitload_type` rows missing on one tenant; `StockunitService.java:157`'s `findByName(UNIT_LOAD_TYPE_PALLET)` misses on **every** pallet transfer; every operator receives a polite HTTP 200 with `"Entity Not Found"`; nothing pages; the only trace is an `ERROR` line among thousands. It is discovered when a human reads a support ticket. **Under the pre-Fix-C behaviour this was a 404 flood, visible on any status-code dashboard.** Fix C deletes the only signal that currently exists and replaces it with one nobody is watching.

---

## 5. EXPANDED TEST PLAN

**The constraint, stated precisely — the plan understates it.** §8.5 says the Testcontainers lane can't boot. True. Additionally `BaseControllerUnitTest.java:50` uses `standaloneSetup(controller)` **without** `.setControllerAdvice(...)`, so `RestExceptionHandler` is absent from the unit request path too. **The "was 404, is now 200" contract is unobservable in both lanes.**

**What that costs:** the *pre-fix* half of the contract is unpinned permanently. Nothing will ever catch a regression that re-routes these throws back to 404. `transferStock_entityNotFound_returns200WithErrors` proves the post-state only. (It is still a valid TDD red — pre-fix the request errors out of MockMvc rather than returning 200 — but it proves nothing about the 404.)

**Compensating controls, in order of value:**

| Lane | Add | Why it compensates |
|---|---|---|
| **Unit — service** | §8.1's 8 tests, **plus `existingContainer_destinationWithNullStoragelocation_…`** | The only lane that runs. `internalLookupMiss_stillThrowsEntityNotFound` is the load-bearing one — it is the *only* automated proof the split is a split and not a blanket conversion. The new test pins PM-1's mechanism at service level. |
| **Unit — controller** | §8.2's 3, **plus the 3 `IsUnitLoadIdValid` tests re-stubbed for Fix B** (§7 G1) | Catches PM-1 before it ships. |
| **Unit — regression** | `StockunitServiceUnitTest`: 2 tests need a **new `locationRepository.findById(10L)` stub** (§7 G1) | §6 attributes this class's breakage to "the new throw types" — the wrong reason. A TDD gate following §6 looks in the wrong place. |
| **Advice-level (new, ~10 lines)** | One `standaloneSetup(controller).setControllerAdvice(new RestExceptionHandler())` MockMvc in the new test class, asserting the deliberately-untouched `StockUnitController:89` path **still 404s** | Pins the §5 Fix C scope decision (§7 G5) and is the only automated proof the advice mapping is real at all. **Add this.** |
| **e2e / mobile Jest** | §8.4's 3, plus one asserting Fix D's own `checkContainer` catch does **not** emit the generic toast | Fix D must not copy `stockUnits.js:214-217`'s bug into mobile. |
| **Observability** | **Take the Micrometer counter §10 row 8 declines**, tagged by the `"Entity Not Found"` type | Without it PM-3 is undetectable and R1's mitigation is unfalsifiable in prod. Micrometer is already a dependency. |
| **Manual** | §8.6 M1–M8 stand. **Add M9:** desktop probe against a UL whose `storagelocation_id` is dangling or `NULL` (PM-1). **Rewrite M6** per §7 G6. | |

---

## 6. MY INDEPENDENT POSITION ON THE FIVE CONTESTED CALLS

### (a) THE SPLIT RULE — right instinct, **wrong axis. I disagree with the rule as stated.**

"Whose input produced the miss" breaks at site `:178` exactly as suspected. `CancellationReversalService.java:203` replays `log.getPickfromlocationname()` — a **logged system value**, non-interactive, hours or days after the pick. Nobody scanned it; no operator can rescan it. Under the plan's own rule that site should keep `EntityNotFoundException` — but it *can't*, because the site is shared with the two interactive callers. **The rule is unenforceable at the granularity the code has.**

Two independent reasons the *outcome* is nonetheless right, on a better axis:

1. **The taxonomy's own v2 branch presupposes a surrogate key.** It reads `EntityNotFoundException(entityName, id)` — the `(String, Long)` overload (`exceptions/EntityNotFoundException.java:14`). Both contested sites use `findByLabelid` / `findByName` and the **hand-written-sentence** overload (`:9-11`), which is not the documented form at all. The doc never covered natural-key lookups. That is the real ambiguity, and it is cleaner than "whose input."
2. **v1's branch of the same tree already resolves it the plan's way:** `BusinessException("BusinessException.ObjectNotFound", entityName)` → 422. Fix A is **restoring** the v1 convention for these two sites, not inventing one. The plan never says this, and it is a stronger argument than the one it makes.

**My proposed discriminator, replacing §5.4's:**

> **Natural key resolved at runtime → `BusinessException`. Surrogate FK, or a natural key that is a compile-time constant → `EntityNotFoundException`.**

Tested against all 13 rows of §0.1: rows 1 (`findByLabelid(unitLoadLabelId)`) and 2 (`findByName(locationName)`) → BusinessException ✓. Rows 4–10, 12 (all `findById(...)`) → surrogate ✓. Rows 3, 11 (`findByName(WmsConstants.UNIT_LOAD_TYPE_PALLET/BOX)`) and 13 (`findBySyskeyAndClientId(WAREHOUSE_NAME)`) → natural key but **constant** ✓. It classifies all 13 correctly, it is **mechanically greppable** (is the argument a `WmsConstants.` literal or a method parameter?), and it does not require knowing who called you — so `CancellationReversalService` stops being a counterexample instead of being explained away.

### (b) FIX C's 404→200 DOWNGRADE — do it, but **`LOG.error` alone is not enough. Partial disagreement.**

The consistency argument is real and I accept the change. My objection is the mitigation. R2's own verification ("force a failure on dev, check the line appears") verifies the *dev* sink and nothing about production, while §10 row 8 declines the counter that would make it observable. **Take the Micrometer counter.** Three lines; already a dependency; it is the difference between "we can see this happening" and "someone will eventually read a log."

Second, the argument *for* C is weaker than the plan states, on two counts: the sibling it cites is not the convention (§7 G4), and Option 4 above delivers the operator-visible half at zero status-contract cost. C is still right — the non-HTTP caller and the `errors[]` response shape both want it — but it should be argued on its own merits, not on a parity claim that does not survive inspection.

### (c) KEYED vs 1-ARG `BusinessException` — **agree with the author, unreservedly.**

Extra evidence the plan does not use, which strengthens its case: **`placeholder=%1s` is present in both bundles** (`messages.properties:10`, `messages_en_US.properties:343`), so the 1-arg form renders the raw message correctly today. The divergence is therefore *purely* about `getKey()` discrimination — exactly as `BusinessException.java:133-144` documents — with **zero rendering downside**. And `MobileMoveUnitloadService:130` builds its message by string concatenation, so it can never be localized at all; following that sibling would be following a dead end. Divergence is worth it.

### (d) FIX B's BREADTH — **no. This is my sharpest disagreement with the author.**

Two dev/UAT tenants do not clear a guard for production, for three separate reasons:

1. **A v2 production tenant exists and was not measured.** The prd landlord `wms2_landlord` @25061 carries a live v2 DB. No MCP for it exists in this session, so the measurement *cannot* be extended here. "Zero on dev and UAT" is being read as "zero everywhere."
2. **The ON_HOLD query is structurally blind.** It matched destination ULs whose `entity_lock` is **currently** 2 or 104. On-hold is a toggle with dedicated endpoints on this very controller (`setLockOnHold:334`, `removeLock:474`). A "hold → consolidate into → release" workflow leaves no trace the query can see. To-Delete / Nirvana / Shipped are *terminal* states and do not have this problem; ON_HOLD does.
3. **`stockrecord` records outcomes, not attempts.** It can show that nobody *succeeded* in moving into these destinations. It cannot show that nobody *tries* — and the population Fix B will start rejecting is precisely the attempts.

**Recommendation:** ship **To-Delete + Nirvana + Shipped** — all terminal, all already refused by `MobileMoveUnitloadService:288-296` on the sibling screen, which is genuine precedent. **Drop ON_HOLD from this ticket**, or land it log-only first. Better still: split all of Fix B into its own ticket. It is a new business rule, and the reported defect is fully fixed by A + C — as §5 Fix D itself concedes ("with A + C the mobile UI already displays the real message with zero UI changes"). Bundling a warehouse-behaviour change into a toast-wording ticket is how PM-2 happens.

### (e) NO INTEGRATION TEST for an HTTP-status-contract change — **acceptable, but the plan's account of what is lost is too generous.**

It is not merely "no IT." Per D1, **no lane at all** exercises `RestExceptionHandler`. §8.5 frames the gate as "unit tests + `mvn clean compile` + the manual plan" as though the unit lane covers the status contract; it does not. Make that explicit in §8.5, and add the ~10-line `setControllerAdvice` MockMvc from §5 so at least one automated thing knows a 404 is supposed to exist on the `:89` path. With that addition, acceptable.

---

## 7. GAPS THE AUTHOR MISSED

### G1 — Fix B breaks three currently-green tests. None appear anywhere in the plan. **(High)**
`assertDestinationCanReceiveStock` / `canReceiveStock` calls `locationRepository.findById(destination.getStoragelocationId())`. Mockito's default answer returns `Optional.empty()` for unstubbed `Optional`-returning methods, so `.orElseThrow(EntityNotFoundException)` fires:

| Test | Site | Mechanism |
|---|---|---|
| `StockunitServiceUnitTest.transfersToExistingNonPalletContainer` (act at `:1454`) | stubs only `findByLabelid` + `findByName(PALLET)`; the `@BeforeEach` sets `targetUnitload.setStoragelocationId(10L)` but there is **no `locationRepository.findById(10L)` stub** in this test | new lookup misses → throws |
| `StockunitServiceUnitTest.transferStock_doesNotTriggerReplenishmentMaintenance` (act at `:1508`) | comment says "mirror `transfersToExistingNonPalletContainer` setup" — same gap | same |
| `StockUnitControllerUnitTest.IsUnitLoadIdValid.returnsTrueWhenUnitloadExists` (~`:1030-1045`) | `new Unitload()` with only `labelid` set → `getStoragelocationId()` is **`null`** | probe throws instead of returning `true` — **PM-1's mechanism, provable today** |

(`transfersToPalletByCreatingBox` at `:1484` and `usesDefaultBoxTypeWhenItemdataHasNone` at `:1543` survive — both already stub `findById(10L)`.)

§6 lists `StockunitServiceUnitTest` as "update the 9 existing `transferStock` invocations **for the new throw types**." That is the wrong diagnosis — these two fail on **missing stubs from Fix B**, not on throw types — and a TDD gate reading §6 will look in the wrong place. The three `isUnitLoadIdValid` tests are not mentioned anywhere in the plan.

### G2 — The plan states a false Java rule and contradicts its own code block. **(Medium)**
§5 Fix A, immediately after the `:178` "after" snippet:
> "`orElseThrow` cannot throw a checked exception from a lambda, so the location site needs the same `Optional` + `isEmpty()` shape as the label site. Write both the same way."

`Optional.orElseThrow(Supplier<? extends X>) throws X` is generically declared to throw `X`; a checked exception compiles fine when the enclosing method declares it — and `transferStock` declares `throws BusinessException, FacadeException` (`StockunitService.java:150`). **Proof on `origin/develop`:** `CancellationReversalService.java:186-188` already does exactly `.orElseThrow(() -> new BusinessException("Source stock unit not found for position … — manual intervention required"))`. The plan's own `:178` "after" snippet uses that very form, ten lines above the sentence denying it works. Cost: the implementer writes needlessly verbose code, and verify rows `A1a`/`A2a` are regexed against the wrong shape.

### G3 — `canReceiveStock` visibility is self-contradictory, and its contract is undefined. **(High — blocks the TDD gate)**
- §5 Fix B has the controller call `unitLoad.filter(stockunitService::canReceiveStock)` — a method reference from another package, which requires **`public`**. §10 row 3 states "`canReceiveStock` is a private helper, not a service entry point." Both cannot be true.
- It is described as "the non-throwing twin," yet the only lookup in the sketched body (`locationRepository.findById`) **can throw**. Whether a missing/null Location makes it return `true` (fail-open — the probe green-lights garbage) or `false` (fail-closed — PM-1) is **never stated**. A TDD gate cannot write a test for either.
- Knock-on for §9/§10: row 2 ("runs inside the existing `transferStock` transaction — no new connection") and §10 row 1 ("runs inside the existing transaction") are true only on the **service** path. On the **probe** path the controller calls it with no transaction and OSIV disabled. Both rows need a second sentence.

### G4 — "`bulkTransferStock` is the correct one; `transferStock` is the outlier" is backwards. **(Medium — it is Fix C's entire rationale)**
`StockUnitController` has **twelve** error-returning endpoints. Exactly **one** — `bulkTransferStock`, at `:165` — has an `EntityNotFoundException` catch. Every other one catches only `BusinessException`/`FacadeException`, identically to `transferStock`: `adjustAmount:201`, `bulkAdjustAmount:243`, `adjustReservedAmount:279`, `bulkAdjustReservedAmount:319`, `setLockOnHold:347`, `bulkSetLockOnHold:380`, `transferToDamaged:417`, `bulkTransferToDamaged:459`, `removeLock:486`, `bulkRemoveLock:516`.

`transferStock` **is** the convention; `bulkTransferStock` is the outlier. Fix C is still worth doing, but §2 Bug 2 ("The single-transfer endpoint is the outlier, not the bulk one") and §12's "converge on the sibling rather than inventing a third convention" are inverted. The honest framing is: *we are starting a new convention, currently practised on 1 of 12 endpoints.*

### G5 — `StockUnitController:89` left as a 404: **agree, but for a reason the plan doesn't give.** **(Low)**
`stockunitRepository.findById(id)` outside the `try` is right to stay a 404 — but the plan's justification ("a bad `id` is a client-programming error") is weaker than the one available. `id` is a **surrogate key**, so it lands squarely in the surrogate branch of the discriminator in §6a: consistent with the rule, not an exception carved out of it. Worth noting that `bulkTransferStock` treats the same lookup differently — `:147` is **inside** the outer `try`, so a bad id there yields a 200 — which is a second way the two endpoints already disagree, and further evidence for G4.

### G6 — Fix A silently changes `bulkTransferStock`'s behaviour; the plan asserts twice that it doesn't. **(Medium)**
`bulkTransferStock`'s `catch (EntityNotFoundException)` at `:165` sits on the **outer** `try` wrapping the entire `for` loop (`:141-168`), not on the per-row inner `try` (`:152-160`). Today a bad destination label throws `EntityNotFoundException` on iteration 1 → **the loop aborts**; the remaining ids are never attempted and never reported. After Fix A it throws `BusinessException` → caught by the **inner** catch → the loop continues.

Three plan statements are wrong as a result:
- §0.2 row 15: "no code change expected, pinned by a regression check" — true of the *code*, false of the *behaviour*.
- §8.6 **M6**: "Per-row errors, 200 — **unchanged** from today." Today it is *one* error and an aborted loop, not per-row errors. A manual tester following M6 will "confirm" the wrong thing.
- The error `type` string also flips from `"Entity Not Found"` to `"Runtime Error"`, and `errors[]` goes from length 1 to length N.

The web UI renders only `errors[0].message` (`store/handlingUnits/stockUnits.js`, `bulkTransferStock` action), so the operator-visible change is the wording — an improvement. But M6 must be rewritten, and §8.2's `bulkTransferStock_entityNotFound_returns200WithErrors` "must stay green untouched" only stays green because it *mocks* the service throw; it pins nothing about the real path.

### G7 — Nothing depends on `transferStock` returning 404. **(Confirmed — the plan's silence is correct)**
Swept both UIs on `origin/develop` for `404`, `response.status`, `error.response`. The only status-sensitive code is tenant bootstrap (`plugins/tenant-auth-fetch.js:112`, `plugins/initTenantAuth.client.js:154`), Nuxt's `layouts/error.vue`, and `store/cancellation.js:~75`. No consumer of `transferStock`, `bulkTransferStock`, or `isUnitLoadIdValid` branches on status. (Web-UI Cypress hits under `cypress/e2e/oms/**` are OMS endpoints, unrelated.)

Also confirmed: **`isUnitLoadIdValid` has exactly one consumer in the entire estate** — `store/handlingUnits/stockUnits.js:209-218`. Fix B's fold-in is therefore safe from a *coupling* standpoint; its danger is PM-1, not breakage elsewhere.

### G8 — `transferToDamaged` out-of-scope is defensible, but there is a real adjacent bug worth naming. **(Low)**
Server-side the call is correct: `transferToDamaged` (`StockUnitController:395-429`) calls `stockunitService.setLockDamaged` at `:415`, **not** `transferStock`. Different service method, different failure surface. Legitimately out of scope — the plan just never says *why*, and "shares the same popup and store module" is the wrong reason to consider it in the first place.

But the client side is broken in a *different* way worth filing: the `transferToDamaged` action in `v2/wms2-web-ui/store/handlingUnits/stockUnits.js` (immediately above `checkContainer` at `:209`) does `context.commit('setLocations', results)` — a copy-paste from `getLocations` — and **never inspects `results.errors`**. A `BusinessException` from `setLockDamaged` (e.g. `"No permission to alter damaged stock"`) is silently swallowed: no toast, and the error map is committed into the location dropdown. Same popup, same store module, same class of "the server said something and the operator never saw it." §0.2 should name it; a follow-up should be filed alongside Q3.

### G9 — Verify script: six more defects, all in the two classes the author already identified

| Row | Defect | Consequence |
|---|---|---|
| **P1** | `getErrorMessage\("Entity Not Found"` is **exactly the string Fix C adds to `transferStock`**. Post-fix the parity pin can no longer tell "bulk's catch retained" from "transferStock's new catch." | Deleting bulk's catch entirely would still green P1. It becomes unfalsifiable **the moment the fix lands** — the worst possible timing. **Fix:** `file_contains_n_times 'getErrorMessage\("Entity Not Found"' "$CTL" 2`. |
| **B3** | `BusinessObjectLockState.GOING_TO_DELETE` **already appears in `StockunitService.java` at `:368`, `:421`, `:465`, `:514`** on the unfixed tree. Only the `STORAGE_LOCATION_NIRVANA`/`_SHIPPED` clauses are genuinely red today. | An implementation guarding Nirvana + Shipped that **skips To-Delete entirely** greens B3. This is the **third** instance of the exact file-scoped-containment defect the author already fixed twice (`A3`, `P3`). **Fix:** scope the To-Delete assertion to the helper body, or pin `MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_USABLE` appearing within a `GOING_TO_DELETE` branch. |
| **(missing row)** | **ON_HOLD is checked by no row at all**, though R3 explicitly claims Fix B keeps "To-Delete + On-Hold + Nirvana + Shipped" and §5 Fix B's snippet elides that branch as `{ … }`. | The one clause I would cut (§6d) is also the only one nothing verifies — so it ships or doesn't ship **by accident**. |
| **K1 / K2** | They assert the *key exists*, not that its *value interpolates the identifier*. `transferStock.destinationUnitloadNotFound=Container not found.` greens both rows. | **A row that cannot fail in the way that matters.** Naming the container is the entire ticket. **Fix:** `^transferStock\.destinationUnitloadNotFound=.*%1\$?s` on both bundles, and `%2\$?s` on `…NotUsable`. |
| **B1 / B2** | Neither localizes the guard. A declaration anywhere in the 636-line file plus a call anywhere greens both — nothing asserts it runs **in the existing-container branch, after the destination resolves, before `transferStockToUnitLoad`**. | A guard placed in the `false` branch, or *after* the transfer, passes both rows. |
| **A1a / A2a** | Line-based grep pinned to `new BusinessException(WmsConstants.MSG_…, unitLoadLabelId)` with exact spacing and the exact parameter identifier. | False-**red** on a line wrap — and G2's mandated `Optional` + `isEmpty()` shape makes a wrap likely. A permanently-red row is indistinguishable from unimplemented work (the `A3` lesson, restated). |
| **M-row coverage** | `M1`–`M3` never run `StockunitServiceUnitTest` — the class Fix B is most likely to break (G1). Also `skip M1` increments `SKIP` by 1 for three rows. | **Add `M4 = StockunitServiceUnitTest`.** Without it the headline `Result: N pass, 0 fail` can be green while two regression tests are red. |

**Rows I checked and found sound** (so the Critic does not re-litigate them): `A1b` and `A2b` — both negatives correctly disambiguated; `"UnitLoad not found by labelid: "` occurs once, at `:156`, and the `\+ locationName` anchor correctly excludes the sibling at `:388` which concatenates `WmsConstants.STORAGE_LOCATION_DAMAGED`. `A3` — both literals confirmed present (`"UnitLoadType not found by name: "` at `:157`/`:225`, `"Client"` at `:227`). `P2` — matches `:149` byte-for-byte. `P3` — the comment is confirmed at `:161-165` of the `transferStock` body. `C1` — count-based, baseline 1, correct design (though not localized to `transferStock`; `C2` covers that). `W2` — `"Container does not exist"` occurs exactly once in the whole web repo, at `components/handlingUnits/popups/transferStock.vue:144`. `D1`/`D2` — both symbols genuinely absent from the mobile repo today. `K1`/`K2` `^`-anchoring. And the fail-closed `[ -f "$2" ] || return 1` in every helper, which correctly avoids the documented fail-open template trap. Baseline arithmetic checks out: 25 rows + 1 skip; 4 pass / 21 fail.

### G10 — §8's acceptance criteria are not TDD-gate-ready in four places. **(High)**
1. `canReceiveStock`'s behaviour on a missing/null Location — fail-open or fail-closed — is undefined (G3). Two of the eight §8.1 tests depend on the answer.
2. The three message **format strings** appear as prose in §5 but are never stated as acceptance criteria; `…NotUsable` takes two params and the tests name only the key (see G9/K1).
3. Fix D's toast copy is never specified — §8.4 says "specific toast." The gate cannot write `expect(toast).toHaveBeenCalledWith(???)`.
4. `internalLookupMiss_stillThrowsEntityNotFound` names "e.g. `unitloadTypeRepository.findByName(PALLET)` empty" — but reaching `:157` requires `findByLabelid` to **succeed** first, which under Fix B now *also* requires a `locationRepository.findById` stub. The test as described is under-specified in exactly the way G1 predicts.

### G11 — Doc step 9 should correct one more line. **(Low)**
`wms-exception-taxonomy.md` §5 "Adding a new localized error message" instructs *"Add a message key to `messages_en_US.properties` if new"* — singular, en_US only — and the §6 decision tree repeats it ("Add a message key to messages_en_US.properties if new"). The plan's own R5 / §5 Fix A argument makes that instruction **wrong**, and it is precisely the instruction the next author will follow. Step 9 currently only adds the discriminator; it should also fix both of those lines and the `EntityNotFoundException(entityName, id)` branch per §6a.

---

## Bottom line for the Architect and Critic

- **Ship A + C** — with the Micrometer counter, not just `LOG.error`. This fully resolves the reported defect at low risk.
- **Split Fix B out**, or at minimum drop the ON_HOLD clause. It is a new warehouse business rule cleared by a measurement that cannot see production and is structurally blind to the one state operators actively toggle.
- **Fix D is fine** as parity, provided it does not copy `stockUnits.js:214-217`'s generic-toast catch into mobile.
- **Before any code is written:** resolve G3 (`canReceiveStock` visibility + missing-Location contract), correct G2's false Java claim, add the three broken tests from G1 to §6/§8.3, rewrite M6 per G6, and repair the six verify rows in G9.