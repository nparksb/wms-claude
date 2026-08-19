I have enough evidence, including a full positive/negative re-test of the verify script. Report below.

---

# ARCHITECT LANE — SBDEV-2994, ITERATION 2

**Verdict: PARTIALLY DISCHARGED. I would not sign off on the TDD gate — but the remaining list is short and specific, not another 22.**

The revision is a genuine, high-quality response. Every architectural *argument* I made in iteration 1 was engaged with, most were adopted, and two were adopted better than I proposed. The problem is that the fixes were applied **in the sections where the argument lived, and not propagated to the sections a TDD gate actually reads** (§6, §7.2, §8.1, §8.2, §7.1). The plan now contains four internal contradictions where §5 and §8 specify *different artifacts*, and a TDD gate following §8 would write tests that can never satisfy the verify script.

And the headline finding: **I rebuilt the correct implementation and six wrong ones, and the revision-2 verify script returns `42 pass, 0 fail` on all seven.** §8.7's claim that it "was validated in BOTH directions" is true but far too weak a test — it validated one wrong implementation (`C3`'s leak) and generalised.

---

## PART A — the empirical re-test of verify script revision 2

I reconstructed all three repos at exactly the SHAs the plan cites (`git archive origin/develop`: api `d2bedc0`, mobile `8e623b8`, web `d4f71c1`) into a shadow root.

**Baseline reproduces exactly.** `Result: 4 pass, 38 fail, 1 skip`, with `A3`, `P1`, `P2`, `P3` the only greens. That claim in §8.7 is true and I verified it rather than accepting it.

I then built a **correct** implementation (new `DestinationEligibilityService` with a total predicate, both throw-site conversions, the `:169` guard, the reworked catch, `RestExceptionHandler` `debug`→`warn`, both bundles, the web toast, the mobile async probe, the four test artifacts):

```
Result: 42 pass, 0 fail, 1 skip
```

**No false-REDs.** That is a real improvement over revision 1 and discharges my verify-note about permanently-red rows. Then I mutated that correct tree six times, each mutation being precisely the defect a row exists to catch:

| # | Mutation | Row that should catch it | Result |
|---|---|---|---|
| W1 | `canReceiveStock` uses `findById(dest.getStoragelocationId()).get()` with **no null guard** — PM-1 exactly | `B8` "predicate is TOTAL" | **42 pass, 0 fail** |
| W2 | `RestExceptionHandler`'s log line **deleted entirely** rather than raised to `warn` | `C4` | **42 pass, 0 fail** |
| W3 | Fix D's probe moved **out of the `existing` block**, so `new` mode probes the *source* UL | `D3` "scoped to 'existing' mode" | **42 pass, 0 fail** |
| W4 | One **extra** internal lookup (`:157` PALLET) blanket-converted to `BusinessException` | `A3` (comment: "converting even ONE extra site trips it") | **42 pass, 0 fail** |
| W5 | `messages_en_US.properties` value reduced to `Container not found.` (no `%1$s`) | `K3` | **42 pass, 0 fail** |
| W6 | `transferStock`'s catch does **not** log; `bulkTransferStock`'s catch logs instead | `C2` | **42 pass, 0 fail** |

Mechanisms, so these are actionable rather than assertions:

- **`B8` is the worst.** It is `! file_contains_within 'public boolean canReceiveStock' 'public [a-z]' 'orElseThrow'`. It forbids the literal string `orElseThrow` and nothing else. The two mechanisms §5 Fix B and PM-1 identify by name — `Optional.get()`, and `findById(null)` raising `InvalidDataAccessApiUsageException` on a null `Long` — are both invisible to it. **The single most load-bearing new contract in the reshaped Fix B has a row that cannot see its primary failure mode.** `B8` also false-REDs in the other direction: the forbid pattern `public [a-z]` does not match `private`, so a legitimate `orElseThrow` inside a *private* helper declared below `canReceiveStock` trips it.
- **`C4` is a bare negation with no positive requirement.** "No `LOG.debug` survives in `handleEntityNotFound`" is satisfied by deleting the logging. The correct implementation and the strictly-worse-than-today implementation are indistinguishable. (`C4` also fails OPEN on a missing `$ADVICE` — `! file_contains_within(...)` returns true when the file is absent, violating the script's own stated design rule #1.)
- **`D3`'s anchor backtracks onto the wrong occurrence.** `currentMode === 'existing'` appears three times in the .vue: `showReason()` (`:128`), `submit()`'s `if`, and `isTransferExistingContainer: this.currentMode === 'existing'` in the payload object. Perl backtracks to the third, after which no further `currentMode ===` exists, so *any* `checkContainer` anywhere below the payload object satisfies the row — which is the unscoped placement D3 was written to forbid.
- **`A3` is off by one, and the arithmetic error is new in revision 2.** I counted directly: `origin/develop` = 34 matching lines (33 throws + the import). Fix A removes 2 → 32. But **`A4` — new in this revision — adds one back** at `:169`. So a correct implementation sits at 33, and the `>=32` threshold tolerates exactly one extra blanket conversion. Measured: shadow 34 → correct 33 → W4 32 → **PASS**.
- **`K3` checks `$MSG_BASE` only.** With `Locale.getDefault()` = `en_US` on every real container, `messages_en_US.properties` is the bundle that actually renders. K3 audits the one that does not.
- **`C2` is anchored file-wide** (`catch (EntityNotFoundException` … `LOG.error`, forbidding `@PostMapping`) while its sibling `C3` was correctly hardened with `method_slice`. The inconsistency is the bug: `C1` proves the catch exists in `transferStock`, `C2` proves *some* catch logs, and nothing joins them.

`A1a/A1b/A2a/A2b/B1-B7/B9-B11/C1/C3/K1/K2/K4/W1/W2/D1/D2/D4/P1-P3` all behaved correctly under every mutation I tried. §8.7's list of seven script defects is honest and its diagnosis of defect 6 (the `@`-as-perl-array interpolation) is correct and well found. But the conclusion drawn — "run against a correct shadow as well as the unfixed tree" — is the *lesser* half of the lesson. The greater half: **a correct shadow proves no false-REDs; only a family of near-miss wrong shadows proves no false-GREENs**, and six of the eleven near-misses I built walked straight through.

---

## PART B — item-by-item on my iteration-1 findings

### Part 0 findings

**0.1 — `MobileMoveStockService` missing from §0.** **DISCHARGED.** Rows 26-28 added, the endpoint, the service and the dead `store/moveStock.js:133-151` action are all named, the grep method is corrected to "enumerate by SCREEN, not by URL", and the SBDEV-2962 precedent is picked up. Split to SBDEV-2996 is a defensible call. See §D for the ordering consequence.

**0.2 — Fix B's dead branches / denylist-over-open-enum.** **DISCHARGED, with one new defect.** ON_HOLD dropped with the reason stated; GOING_TO_DELETE kept but explicitly labelled as subsumed by Fix A; SHIPPED promoted to "the entire real exposure"; denylist→allowlist. I re-measured on `wms2-wineco-dev` and the revision's table is **exactly right**: Shipped/405 = 411,862 (0 mangled), Nirwana/2 = 320,637 (320,637 mangled), Nirwana/0 = 1. The new defect is the QUALITY_FAULT carve-out — see §C-N5.

**0.3 — §12 Q4's 210,167 statistic.** **DISCHARGED.** Corrected to 1, the `count(*)`-over-`LEFT JOIN` mechanism is explained, and Q4 is reopened rather than reworded.

**0.4 — Fix A changes `bulkTransferStock`.** **DISCHARGED.** §0.2 row 15 rewritten with the loop/catch mechanism, M6 rewritten, a new pinning test added (§8.2 `bulkTransferStock_deadLabel_continuesLoopAndReportsEveryRow`), and verify row `T7` added. `T7` is name-only, so it proves the test exists, not that it asserts anything — acceptable but note it.

**0.5 — Fix A silently re-statuses `OrderCancellationController` 404→422.** **NOT DISCHARGED — not mentioned anywhere.** I grepped the revised plan for `OrderCancellation` and for `422` in this context: zero hits. `CancellationReversalService:203` is discussed only as a *compile* risk (R4, step 3, M7). I re-verified the mechanism on `origin/develop`: `completeReversal` (`:171`) calls `transferStock(..., false, log.getPickfromlocationname(), ...)`, so Fix A's `:178` change lands on it; `RestExceptionHandler:118` maps `BusinessException`→422 and `:153` maps `EntityNotFoundException`→404. `POST /{customerOrderId}/complete` flips status. No UI consumes it, so impact is low — but it is still an unowned public-contract change, and it is the second half of the same finding whose first half (the compile risk) *was* adopted. The related note that `wms-exception-taxonomy.md` §3 is stale (it still says `BusinessException` has no registered handler and propagates as 500) is also absent, while §6 schedules a taxonomy edit for the discriminator only.

**0.6 — Fix D's fictitious ordering rationale.** **DISCHARGED, and well.** Deleted, replaced by the two real constraints (`submit()` must become `async`; scope the probe to `existing` mode), the mobile Jest specs added as §0.3 rows 31-32, and the toast copy specified so a test can assert it. I confirmed in `scanDestination.vue:118-128` that the code's own comments state the unreachability.

### The five attacks

**Attack 1 — the discriminator axis.** **DISCHARGED in §5.4, then contradicted in §5 Fix C.** §5.4 adopts the signature axis verbatim, argues it against the three rejection counts, and adds two supporting arguments (the taxonomy's surrogate-key presupposition; v1's branch) that are both stronger than the original. **I re-tested it on all 14 rows of §0.1 and it holds on every one**, including new row 14 (`defaultUnitLoadType` is derived from `itemData.getDefultypeId()` → `EntityNotFoundException`, which is the decision the plan makes). **It survives `CancellationReversalService:203` cleanly** — by construction, since the axis is caller-blind, `locationName` is a parameter regardless of who fills it. The message text stays honest too: `transferStockDestinationLocationNotFound=Location %1$s was not found.` is voice-neutral, and the operator-voiced unitload message is only reachable with `isTransferToExistingContainer=true`, which that caller never passes.

But the **first application of the axis outside §0.1 requires an unstated exception**: §5 line 554 keeps `stockunitRepository.findById(id)` at `StockUnitController:89` as `EntityNotFoundException`, justified as *"`id` is a surrogate key, so it lands squarely in the `EntityNotFoundException` branch of §5.4's discriminator."* Under the adopted rule it does not. `id` is read from the request body inside the enclosing public handler and is as much a caller-supplied input as `labelId`. "Surrogate key" is a **third criterion smuggled in as if it were the rule**, and the plan explicitly claims the opposite — "consistent with the rule, not an exception carved out of it." Either the axis needs a stated second clause (*"…and is not an opaque surrogate identifier"*, which reopens the enforceability objection), or this site's carve-out must be labelled as a deliberate exception. Right now the plan asserts a consistency it does not have, on the one site where the axis is put to work.

Naming: **DISCHARGED in argument, broken in artifact.** §5.4 adopts bare-camelCase with the SBDEV-2732 cohort argued, and the pre-existing `entityNotFoundForId`/`entityNotFoundForName` divergence is now argued rather than skipped. See §C-N1 for the schism.

**Attack 2 — Fix C body + `LOG.error`.** **DISCHARGED.** The body is now a fixed operator-safe string with a support reference; `e.getMessage()` is forbidden in a comment, pinned by a new test (`transferStock_entityNotFound_doesNotLeakInternalMessage`) and by verify row `C3` — the one row I could not break. The `RestExceptionHandler:155` `debug`→`warn` one-liner is adopted, and R1's direction is corrected. On the question I was asked to answer directly:

- **Is Fix C's new body genuinely operator-safe?** Yes. It carries only the stockunit surrogate id as a support reference, which is a reference number rather than an explanation of internal structure. One residual: because the string is identical for all 11 sites, support cannot triage from the toast — they need the log line, so R2's "confirm the ERROR line reaches the sink" is genuinely load-bearing, not ceremonial. R2's mitigation (rename the `Pallet` row in `unitload_type`, transfer, rename back) is concrete and owned. Good.
- **Downsides of `debug`→`warn`.** Three, one of which the plan should name. (i) *Volume*: every `EntityNotFoundException` across 61 controllers becomes a WARN, and **nobody has measured the estate-wide rate**. That is structurally the same "asserted, not measured" failure R3 was reopened for, applied to C4 — and it is what makes R11 ("someone mutes it") *more* likely, not less, since the mute would now silence 61 controllers instead of one. One query against a log sink would settle it. (ii) *Disclosure*: the messages carry entity names, surrogate PKs and operator-scanned label strings. That is not PII, and there is precedent one method up — `handleBusinessException` at `:119` already logs `ex.getMessage()` at WARN — so this is acceptable, but it should be stated rather than left implicit. (iii) *Note in favour*: after Fix A, the message that motivated the ticket (`UnitLoad not found by labelid`) no longer reaches this handler at all — it becomes a `BusinessException` handled at `:118`. So the `warn` buys visibility for exactly the engineer-only rows, which is the right target. The net is positive; only (i) needs writing down.

**Attack 3 — layering / transaction / totality.** **DISCHARGED, and the two-transaction analysis I asked for is now in §10 row 1.** §10 row 3 is corrected (public, service entry point, `@Transactional(value="tenantTransactionManager", readOnly=true)`), and the totality contract is stated with the `findById(null)` mechanism named. On the two questions I was asked:

- **Circular dependency: no.** `DestinationEligibilityService` needs only `LocationRepository`. `StockunitService` and `StockUnitController` both already sit downstream of repositories, and `StockUnitController` already injects `StockunitService`. The follow-on adopters (`MobileMoveStockService`, `MobileMoveUnitloadService`) are also downstream. There is no cycle on any spelling of this design, including the stale §6/§7.2 spelling that keeps the helper on `StockunitService`.
- **Transaction propagation: no hazard, one cosmetic no-op.** On the write path `assertCanReceiveStock` joins `transferStock`'s existing read-write transaction under `REQUIRED`; Spring silently ignores `readOnly` for a participating transaction, so nothing breaks. If `assertCanReceiveStock` calls `canReceiveStock` via `this.`, the proxy is bypassed and the annotation is a no-op there — harmless, and the annotation still applies on the probe path where it matters. Worth knowing that **verify row `B9` greps for the annotation text and cannot tell a live annotation from a self-invoked dead one**, but nothing functional turns on it.

**Attack 4 — deploy ordering.** **DISCHARGED as a decision, contradicted by the step list.** §7.1 now prescribes web-ui → api → mobile with the 411,862-container reasoning written out, and web-first is genuinely safe in both windows. But **§7.2 step 6 puts the api probe fold and the web toast reword in the same step** — "fold `canReceiveStock` into `isUnitLoadIdValid` … and reword `transferStock.vue:144`". A single step spanning two repos cannot be sequenced web-first. §7.2 needs splitting into 6a (web, ships first) and 6b (api). My secondary note — that a three-root green implies a coherence the deploy pipeline does not provide, and that §8.7 should say so — was **not adopted**; §8.7 says only "point all three roots at the worktree."

**Attack 5 — Fix B's layer / the shared collaborator.** **DISCHARGED in §5, not propagated.** The extraction is adopted with the four-implementations census, the correct precedent (`MobileMoveStockService:320-324`) cited, and the mis-cited ones corrected. §12 Q5 records the product question about repointing `scanDestination.vue:184`, framed as the irreconcilable-product-decision it is, which is the right treatment. See §C-N3 for the propagation failure.

### Principle violations V1-V7

| | Status |
|---|---|
| **V1** (P5, dead branches) | **DISCHARGED** — ON_HOLD dropped, GOING_TO_DELETE labelled subsumed, the real population identified and re-measured correct by me |
| **V2** (P3, 4th implementation) | **DISCHARGED in §5** — extraction adopted, sibling enumerated. Undermined by §6/§7.2 still describing the private helper |
| **V3** (P1, raw text to operator) | **DISCHARGED** — fixed string, forbidden by comment, test and `C3` |
| **V4** (P4, deploy order) | **DISCHARGED as a decision**, contradicted by §7.2 step 6 |
| **V5** (precedent mis-citation) | **DISCHARGED for the cited instances**, **re-committed at a new one** — see §C-N5 |
| **V6** (P2, net at the boundary) | **DISCHARGED** — the `RestExceptionHandler` one-liner is in scope, in §7.1 monitoring, in R1, in §10 row 8 |
| **V7** (vacuous controller assertion) | **DISCHARGED** — §8.2 opens with the `standaloneSetup` warning, `entityNotFoundStillMapsTo404_onTheUnnettedPath` is specified as the compensating control, and verify `T6` greps `setControllerAdvice`. I confirmed `BaseControllerUnitTest:49-57` has no `.setControllerAdvice(...)`, so the framing is accurate |

### Verify-script notes 1-6

1. `T3` (ISO-8859-1 `Properties.load`) → **DISCHARGED**; now `T4`, requires `InputStreamReader(` + UTF-8. (It no longer requires `Properties` at all, and nothing checks `getLocalizedMessage(Locale.ROOT)` — minor.)
2. `T4` name-only / `setControllerAdvice` → **DISCHARGED** as `T6`.
3. No row detects the bulk behaviour change → **DISCHARGED** as `T7` (name-only).
4. No row forbids `e.getMessage()` in Fix C's body → **DISCHARGED** as `C3`, the strongest row in the script.
5. `D2` cannot distinguish scoped from unscoped → **NOT DISCHARGED**; `D3` was added for it and **passes on the unscoped implementation** (W3).
6. `file_contains_n_times` `grep -c` arithmetic → **DISCHARGED**, fixed with the comment explaining why.

---

## PART C — defects introduced or left by the revision itself

**N1 — the message keys exist in two spellings, and the verify script only accepts one. Gate-blocking.**
§5's bundle block (`:432-434`) and §8.1's two primary tests (`:733`, `:739`) use the **dotted** form `transferStock.destinationUnitloadNotFound`. §5.4 (`:662`), §8.1 `:744` and `:752` use the **bare camelCase** form. The verify script hard-codes camelCase (`K_UL`/`K_LOC`/`K_USE`, `:136-138`). §5.4's naming decision was applied in §5.4 and nowhere else. A TDD gate reading §8.1 writes `assertThat(ex.getKey()).isEqualTo("transferStock.destinationUnitloadNotFound")` and `K1`/`K2`/`K3` stay red forever against a correct implementation. There is also a third-key name drift: `transferStock.destinationUnitloadNotUsable` (§5) vs `transferStockDestinationNotUsable` (§5.4, §8.1, script).

**N2 — Fix C's `field` label contradicts its own acceptance criterion. Gate-blocking.**
§5 Fix C's normative code (`:543`) is `errors.add(getErrorMessage("Runtime Error", …))`. §8.2's row (`:769`) asserts `errors[0].field == "Entity Not Found"`. Verify `T5` greps only the literal string `errors[0].field`, so it cannot discriminate. Pick one. (§0.2 row 15's bulk analysis assumes `"Runtime Error"`, so that is probably the intended answer.)

**N3 — §6 and §7.2 still describe the pre-extraction Fix B, and §6 omits two files the acceptance script requires. Gate-blocking.**
§6 row 1 says `StockunitService.java … Fix B (assertDestinationCanReceiveStock + canReceiveStock)` — the old name, the old class. §7.2 step 4 repeats it. §0.3 row 29 (`:108`) and §5 (`:510`) still say `stockunitService::canReceiveStock`. Meanwhile §5 (`:482`) and §10 row 3 say `DestinationEligibilityService` / `destinationEligibilityService::canReceiveStock`, and the script's `B1`/`T2` require the files `service/DestinationEligibilityService.java` and `unit/service/DestinationEligibilityServiceUnitTest.java`. **Neither new file appears in §6's File Change Summary**, which is the section an implementer works from. Relatedly, §0.3 row 29's remediation ("restub") is stale: after the extraction the controller test needs a *new* `@Mock DestinationEligibilityService` and `@InjectMocks` rewiring, not a restub of `StockunitService`.

**N4 — R10 adopts a sysprop gate that exists nowhere else in the plan, and contradicts three other sections. Gate-blocking.**
R10's mitigation is *"gate Fix B behind a sysprop defaulting OFF, enable per tenant after observing its log line in shadow mode."* But §7.1 still says **Feature flags: N/A — "no behavioural risk worth gating"** and **System properties: N/A — no new keys**. R10 even acknowledges it "reverses the draft's" position without editing it. There is no key name, no `WmsConstants` constant, no seeding step, no §7.2 step, no verify row, and no test. Three downstream contradictions follow: (a) §8.6 **M10 asserts the Nirvana sentinel is rejected** — false if the gate ships OFF; (b) §8.1's four Fix-B service tests must all set the gate; (c) **the entire web-first deploy-order argument evaporates** if the flag is OFF, because the probe stays existence-only until someone flips it. The gate must be either designed or declined — and if it is declined, R10 needs a different mitigation, because "no rollback but a hotfix across all tenants" while R3 is uncleared is a real problem.

**N5 — the QUALITY_FAULT allowlist member repeats V5's precedent mis-citation, inside the fix reshaped to correct V5.**
§5 Fix B: *"a destination may receive stock only when its lock is `NOT_LOCKED`, or `QUALITY_FAULT` (which the existing damaged branch at `:230-251` already handles deliberately)."* I read `StockunitService:230-251`. Two problems, both the same shape as V5: (a) that branch is entirely inside the **new-container** (`isTransferToExistingContainer == false`) path, whereas §5 calls `assertCanReceiveStock` "immediately after the destination resolves in the **existing-container** branch" — the two never co-occur; (b) the condition it tests is `stockUnit.getEntityLock() == QUALITY_FAULT` — the **source stockunit's** lock, not the destination unitload's. Different entity, different table, different branch. Measured on `wms2-wineco-dev`: **zero `unitload` rows carry any lock outside {0, 2, 405}**, so QUALITY_FAULT on a destination unit load is a population of nothing, admitted on a justification that does not describe the cited code. Drop it, or justify it on its own merits. (The allowlist *shape* is right and I am not reopening that — a single comparison against an allowed set does not create dead branches the way four denylist branches did.)

**N6 — the axis's first application outside §0.1 contradicts the axis.** See Attack 1 above: `StockUnitController:89`'s `id`.

**N7 — `A3`'s stated sensitivity is off by one** because `A4` (new this revision) adds an `EntityNotFoundException` the threshold arithmetic does not count. Demonstrated: 34 → 33 (correct) → 32 (one extra conversion) → still `>=32` → PASS.

**N8 — §0.1 and §0.2 both contain a row numbered 14**, so "row 14" is ambiguous in §5 Fix C's cross-reference and in §14.2.

**N9 — §7.2 step 6 spans two repos in the order §7.1 forbids.** See Attack 4.

**N10 — §7.1's Feature-flags cell cross-references "§9 R3"**; the risk register is §11. Cosmetic.

---

## PART D — did the SBDEV-2995 / SBDEV-2996 split leave 2994 coherent?

**Fix A and Fix C: yes, cleanly.** They stand alone, need nothing from either new ticket, and their scope is now honest.

**Fix B: no — there is a live ordering trap, and it is the most consequential thing in this section.**
SBDEV-2995 is the confirmed silent-data-loss path (`labelid='Nirwana'`, `entity_lock=0`, resolvable by scan, on both tenants). **Fix B's Nirvana branch is currently the only fix for it in the estate** — §5's table and M10 both say so ("Fix B closes it incidentally"). Combine that with R10's proposal to ship Fix B **default OFF** and the result is: the highest-severity finding in the whole review is (i) removed from this ticket's scope, (ii) fixed only as a side effect of a change that is proposed to be disabled, and (iii) has no owner and no landing date in either document. Either 2994 owns the sentinel guard unconditionally, or SBDEV-2995 must be scheduled ahead of / alongside it. This must not be left to "incidentally".

**Fix D: no — it is gated on a question the plan says does not block it.**
§12 Q5 is an *unresolved product decision* about what an unknown-but-well-formed destination label means on this screen, tracked against SBDEV-2996, and the plan says it "does not block this ticket." That is right for A/B/C and **wrong for D**. Fix D ships a hard client-side rejection onto `scanDestination.vue` — the exact screen whose semantics Q5 leaves open — and SBDEV-2996's likely resolution is to repoint `:184` at the guarded `moveStock/scanDestination` action, whose server (`MobileMoveStockService:309-317`) **auto-creates** an unknown well-formed container at Clearing. If 2996 lands after 2994, Fix D's probe will client-side-block containers the server was about to create, and Fix D gets rewritten or reverted. Either answer Q5 before implementing Fix D, or explicitly accept that Fix D is provisional and will be revisited by 2996. Note the plan already carries the milder version of this interaction as R12 (PM-4) but frames it as a message-consistency risk, not an ordering dependency.

**Fix E / Option 4: discharged and priced well.** The comparison table is fair, the rejection reasons are the honest ones (desktop + bulk + the non-HTTP caller), and keeping it on the shelf as a same-day hotfix is exactly right.

---

## PART E — what would make me sign off

The plan's *thinking* is now sound. What is missing is one propagation pass and two decisions.

**Must fix before the gate (5):**
1. **N1** — one key spelling, everywhere (§5 bundle block, §8.1 rows, §5.4, script). Camel is already the argued choice and the script's choice.
2. **N2** — one `field` label for Fix C (§5 code vs §8.2 row).
3. **N3** — rewrite §6 and §7.2 step 4 for `DestinationEligibilityService`; add both new files to §6; fix §0.3 row 29's remediation.
4. **N4** — decide the sysprop gate. If yes: key, constant, §7.1 rows, a §7.2 step, a verify row, and M10/§8.1 updated. If no: give R10 a different mitigation, because "hotfix across all tenants" with R3 uncleared is not one.
5. **R3** — the plan already declares this blocking with **owner unassigned**. It needs a human to run the corrected query (all time, `split_part(tounitload,'-X-',1)`, at least one production tenant) before Fix B is written. I agree with the plan's own assessment.

**Must fix in the verify script (4):** `B8` must assert totality by mechanism (forbid `.get()` and require an explicit null guard on `getStoragelocationId()`) or, better, be replaced by grepping `$TEST_ELIG` for the two named totality tests plus a `RUN_MVN` row — a regex will not carry this contract. `C4` must require a `LOG.warn`/`LOG.error` to *exist*, not merely require `LOG.debug` to be absent. `D3` must slice `submit()`'s `existing` block with `method_slice` the way `C3` slices `transferStock`. `K3` must check `$MSG_EN` as well as `$MSG_BASE`. Fix `A3`'s threshold to 33. Then **re-run against near-miss wrong shadows, not just one.**

**Should fix, not blocking (5):** the `OrderCancellationController` 404→422 (finding 0.5, still absent) and the stale `wms-exception-taxonomy.md` §3; the axis exception at `StockUnitController:89` (N6); §7.2 step 6 split web/api (N9); the §0.1/§0.2 row-14 collision (N8); one sentence in §8.7 that a three-root green implies a coherence three independent deploy pipelines do not provide.

**Sign-off: no, not yet — but this is one focused revision away, not another round.** Iteration 1 found 22 must-fixes across the design; iteration 2 leaves five, of which three are pure propagation edits, one is a decision the author already flagged as needing a human, and one is a measurement someone has to run. The verify script needs four surgical repairs and one better negative-testing pass. Nothing here requires rethinking the fix.

**Files, all absolute:**
`/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-2994-move-stock-unknown-destination-container-generic-error.md` (§5 `:432-434`/`:543`, §5.4 `:662`, §6 `:672`, §7.1 `:697-700`, §7.2 `:714`/`:716`, §8.1 `:733`/`:739`/`:744`, §8.2 `:769`, §11 R10 `:945`)
`/home/nampark/dev/wms-claude/sbdocs/9-System/scripts/verify-SBDEV-2994-move-stock-unknown-destination-container-generic-error.sh` (`:136-138` keys, `:148-152` K3, `:179-181` A3, `:203-206` B8, `:217-219` C2, `:242-244` C4, `:255-257` D3)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockunitService.java` (`:230-251` — new-container branch, source-stockunit lock, the mis-cited QUALITY_FAULT precedent)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/service/CancellationReversalService.java` (`:171` `completeReversal`, `:203` the `false`-branch call)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java` (`:118` BusinessException→422 already at WARN; `:154` `LOG.debug`)
`/home/nampark/dev/wms-claude/v2/wms2-api/src/test/java/net/aim_ai/wms/common/base/BaseControllerUnitTest.java` (`:49-57`, no `setControllerAdvice` — confirmed)
`/home/nampark/dev/wms-claude/v2/wms2-mobile-ui/components/moveStock/scanDestination.vue` (`:128` `showReason`, `:141` `submit()`, the three `currentMode === 'existing'` occurrences that defeat `D3`)
Shadow trees used for the re-test, if anyone wants to reproduce: `/tmp/claude-1000/-home-nampark-dev-wms-claude/009d04f4-ec21-44a5-8ee4-7b54fc0d80bc/scratchpad/{shadow,good,w1..w6}`