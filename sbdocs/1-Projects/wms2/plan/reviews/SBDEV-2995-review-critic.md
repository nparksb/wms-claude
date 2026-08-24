All shadows built and scored. Here is my report.

---

# CRITIC REVIEW — SBDEV-2995 (reworked plan, verify script revision 2)

**Verdict: ITERATE.**

The rework is a genuine repair. Its central claim — the one the whole plan rests on — **is true and I verified it independently**. The scoping down from 4 sites to 1, the switch from `assertCanReceiveStock` to the type check, and the §4 coupling argument are all correct and well-argued.

But **the verify script is still not sound**, and this is now the third time. I built nine near-miss implementations from the code at `origin/develop`. **Seven of them score `17 pass / 0 fail` — byte-identical to a correct shadow.** Three of the seven leave the defect 100% unfixed; one *inverts* it so that every real pallet is refused and every wrong container accepted. A separate, behaviourally-correct implementation **false-REDs** two rows.

Beyond the script, two of the rework's own §0 corrections are overstated in ways that matter, and one causal claim in §2 is false.

All citations are `origin/develop` = `e7b3b8812b9a1a9a020a81c65a2c82b260a46331`, verified via `git show`. Shadows are reproducible at `/tmp/claude-1000/-home-nampark-dev-wms-claude/009d04f4-ec21-44a5-8ee4-7b54fc0d80bc/scratchpad/shadows/`.

---

## 1. Is Fix A's premise TRUE? — **YES. Verified.**

I read the method rather than trusting the correction.

`ParcelMonitorViewService.java:145-153` (`palletise`), the existing-label arm:

```java
} else {
    // Fix E: re-fetch existing pallet under lock and guard against concurrent carrier assignment
    pallet = unitloadRepository.findByIdForUpdate(palletOpt.get().getId())          // :147
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad", palletOpt.get().getId()));
    if (pallet.getCarrierunitloadId() != null) {                                     // :149
        throw new BusinessException("Pallet already loaded onto a carrier: " + pallet.getLabelid());
    }
    billofladingPositionService.assertPalletNotAssignedToGate(pallet.getLabelid());  // :152
}
```

There is **no type check**. Confirmed. The `Not valid format` regex is at `:136-138`, inside `if (palletOpt.isEmpty())` at `:131` — create-only, exactly as §1.2 says. `transferUnitLoadToCarrier` is at `:206`. The reachability chain holds: `BillOfLadingController.java:458` `@PostMapping("/palletize")` → `:480` `parcelMonitorDtoService.palletise(...)`, and `palletizeOutboundParcel.vue:13` is indeed a bare `<v-text-field v-model="palletName">` with no validation.

The counts in §1.2 reproduce **exactly** on `dev_wh01_om1`:

| type | plan | measured |
|---|---|---|
| Case | 299,426 | 299,426 |
| PickLocation | 23,597 | 23,597 |
| Tote | 1,064 | 1,064 |
| Package | 66 | 66 |
| Default (sentinel) | 1 | 1 |

**§0 row 1 is also correct.** `palletiseAndTruckLoad`'s existing-label arm is `:303-305`, a bare `throw new BusinessException("Pallet with name=" + palletName + " already exists!")`. There is no reachable existing-label path there, and `git grep palletiseAndTruckLoad origin/develop -- src/main/java` returns only the declaration at `:235`; a sweep of `wms2-web-ui` and `wms2-mobile-ui` returns nothing. **§9 Q3's "zero callers" is verified, including the UI sweep the plan says it has not done.** You can close Q3 with more confidence than the plan claims.

---

## 2. Is the type check the RIGHT guard? — **Yes, with one caveat the plan does not state.**

The §4 comparison table is sound and the coupling argument (`TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` governance leaking into palletising) is the strongest part of the rework. I checked the residual from both directions:

- **Does the type check newly refuse anything palletising legitimately needs?** No. On `dev_wh01_om1` all 412,170 joinable `PALLETIZING` records target a `Pallet`; on `wh01_hydra_v2`, all 9,389. `Cart` (`type_id=6`) never appears as a palletising target on either tenant.
- **NPE risk on `pallet.getTypeId().equals(...)`?** None — `unitload.type_id` is `is_nullable = NO` on both DBs I checked, and there are 0 NULL rows in 754,774 / 13,402. The plan never states this; I verified it holds, so it is not a finding, but §4 should record it since the guard dereferences the value.

### Finding C-1 — §1.3's "Every palletising operation ever recorded" overstates the evidence (**Low**)

The probe query joins `unitload_record.tounitload` to `unitload.labelid`. On `dev_wh01_om1` there are **428,125** `PALLETIZING` records, of which **412,170 join** and **15,955 (3.7%) do not** — the target unit load no longer exists, so its type is unknowable. Hydra: 10,386 total, 9,389 joined, 997 unresolved.

The measurement is still strong enough to carry R1, but "every palletising operation ever recorded on both tenants targeted a Pallet-type carrier" is not what the query shows. It shows *every classifiable one*. Restate as "of the 421,559 records whose target still exists, 100% were Pallet-type; 16,952 records (3.9%) are unclassifiable."

---

## 3. Fix B's ordering claim — **the mechanism is real; one stated amplification is false; reachability is weaker than implied**

`MobileMoveUnitloadService.java`:

```java
public void scanDestination(TransferInfoDto dto) …                                    // :251
    Unitload sourceUnitLoad = unitloadRepository.findByLabelid(dto.getUnitLoadLabel())…// :254
    if (sourceUnitLoad.getEntityLock() == …ON_HOLD) { throw … }                        // :260
    List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(…getId());     // :264
    …
    checkReservedStock(sourceUnitLoad);                                                 // :271
```

`:264` and the second materialisation inside `checkReservedStock:226` are both real, and `scanUnitLoad`'s `:135` identity check (`unitLoad_nirvana.equals(unitLoad)`) is genuinely absent here. **210,167 is the exact `stockunit` count for `labelid='Nirwana'` on `dev_wh01_om1`** — verified. Placing the guard before `:264` does prevent both loads.

### Finding C-2 — §2 Bug 2's "a `pickingorderPositionRepository` query per row" is FALSE (**Medium**)

§2 states: *"after which `checkReservedStock` iterates them again with a `pickingorderPositionRepository` query per row."*

`checkReservedStock:227-230`:
```java
for (Stockunit stockUnit : stockUnitList) {
    if (BigDecimal.ZERO.compareTo(stockUnit.getReservedamount()) == 0) {
        continue;                       // ← no repository call for this row
    }
```
Measured: all 210,167 sentinel stock units have `reservedamount = 0.0000` (and `amount = 0.0000` — §1.4 is correct). **Zero** rows reach the `pickingorderPositionRepository` call. The N+1 does not occur.

What actually happens is 2 × 210,167 entity materialisations. That is still a real problem and still justifies the fix — but the plan's own §1.4 ("all zero-amount") contradicts its own §2, and the false claim is doing rhetorical work ("That is an OOM/timeout"). Fix the sentence; the conclusion survives.

### Finding C-3 — `scanDestination`'s reachability is API-only, and the plan half-hides this (**Low**)

In the mobile flow the operator must pass `scanUnitLoad` first, which refuses `Nirwana` at `:122` on the **label string** before any lookup. `scanDestination` re-reads the label from the DTO, so the 210k path requires a direct authenticated `POST /v3/moveUnitLoad/scanDestination`. §7.5's M6 says "called directly" and §2 does not. This is an authenticated-endpoint robustness issue, not an operator-reachable one; the priority is right but §2 should say so rather than implying the UI reaches it.

### Finding C-4 — Fix B is under-specified: which of `scanUnitLoad`'s guards get extracted? (**High for the TDD gate**)

§2 says `scanUnitLoad` "guards the source three ways (`:122` label, `:135` identity, `:139-143` location)". It guards it **four** ways — `:146-149` also refuses a source at `STORAGE_LOCATION_SHIPPED`, and the plan never mentions it. §4 then says "Extract `scanUnitLoad`'s **identity check**" (singular), §5 says "extract + two calls", and verify row `B2` accepts either `getNirvana(` or `STORAGE_LOCATION_NIRVANA`.

So four readings are all consistent with the plan:
1. identity only (`:135`);
2. identity + nirvana-location (`:139-143`);
3. identity + nirvana-location + shipped-location;
4. label-string compare (`:122`) instead of identity.

These are behaviourally different — reading 1 leaves `scanDestination` willing to move a UL parked *at* Nirwana or *at* Shipped, which `scanUnitLoad` refuses. The plan must name the exact set, and §7.2's tests must pin it. It must also state the expected message; today `:136` throws `"Can not move " + unitLoad_nirvana` (an entity `toString()`), which is a poor contract to carry into a new helper without saying so.

---

## 4. Is §0 over-corrected? — **Row 1 is right. Row 2 is right by accident, and the accident is not pinned.**

### Finding C-5 — "Mobile rejects it today on every tenant" depends on a sysprop the plan never mentions (**Medium**)

§0 row 2 claims *"Both `else` branches open with `if (!pallet.getTypeId()…`"* and *"Mobile rejects it today on every tenant."* That is true for `scanPallet` and true-today for `scanPalletBulk` — but `scanPalletBulk` has a **second, unguarded arm**:

```java
// MobilePalletizingService.java:321-330  (scanPalletBulk)
if (activated) {                                          // SHIPPING_METHOD_ACTIVATED
    if (pallet == null) { throw new BusinessException("Not allowed to create pallet (shipping method)"); }
    if (pallet.getShippingmethodId() == null) { throw new BusinessException("Pallet " + palletLabel + " has no shipping method!"); }
    billofladingPositionService.assertPalletNotAssignedToGate(palletLabel);
} else {
    UnitloadType pallet_type = …findByName(UNIT_LOAD_TYPE_PALLET)…                 // :331
    if (pallet == null) { … } else {
        if (!pallet.getTypeId().equals(pallet_type.getId())) { throw … }           // :350
```

**The type check at `:350` lives entirely inside the `else` (shipping-method OFF) branch.** With `SHIPPING_METHOD_ACTIVATED = true`, `scanPalletBulk` accepts any existing container that has a non-null `shippingmethod_id` — no type check at all.

I checked all six tenant DBs: `SHIPPING_METHOD_ACTIVATED = 'false'` on `dev_wh01_om1`, `wh01_hydra_v2`, `wh01_shipitez_v2`, `wh01_om1_v2`, `wh02_shipitez_v2`, `wh01_hydra_v2t`. And on `dev_wh01_om1`, **zero** unit loads of any type carry a non-null `shippingmethod_id`. So the gap is doubly latent today.

The claim is therefore true, but for a reason the plan does not know and does not pin. `P4` (`grep -c 'getTypeId()…equals' >= 2`) would stay green if someone moved `:350` further into the activated branch or deleted the `else` structure. The plan's §0 correction should say "mobile rejects it on every tenant **because `SHIPPING_METHOD_ACTIVATED` is `false` on all six; `scanPalletBulk`'s activated branch has no type check**", and either add a verify row or file it as a follow-up observation. This is exactly the shape of error the rework was written to correct — a guard asserted from call shape rather than from the enclosing branch.

### Finding C-6 — "the sentinel's type is `Default`" is false on 2 of 6 databases (**Low**)

§4's Residual paragraph: *"the sentinel is the only UL at Nirwana with a scannable label, and **its type is `Default`**."*

Measured `unitload.type_id` for `labelid='Nirwana'`: `0` on `dev_wh01_om1`, `wh01_hydra_v2`, `wh01_shipitez_v2`, `wh01_om1_v2`; **`1` on `wh02_shipitez_v2` and `wh01_hydra_v2t`**. And `unitload_type` id 1 is **`PickLocation`** on every DB I enumerated (`0=Default, 1=PickLocation, 2=Tote, 3=Package, 4=Case, 5=Pallet, 6=Cart`).

So on the two fresh-seeded tenants the sentinel is typed `PickLocation`, not `Default`. §1.3's raw statement ("`type_id` 0 (migrated) or 1 (fresh-seeded)") is correct; §4's prose derived from it is not. Harmless to the fix (1 ≠ 5 either way) but it makes §1.2's "**Default** (the Nirvana sentinel)" row a tenant-local label, and it is one more instance of a fact stated in one section and mis-carried into another — the exact failure mode §0 diagnoses.

---

## 5. Could a TDD gate write failing tests from §7 without inventing a contract? — **No. Four gaps.**

| Under-specified | Why it blocks |
|---|---|
| **C-4 above** — which guards `assertSourceUnitLoadMovable` contains, and its message | Four incompatible readings; the test must assert *something* |
| `palletise_refusesBeforeAnyWrite`: "`InOrder`: the type check precedes `transferUnitLoadToCarrier`" | The type check is **not a mock interaction**. The only observable is `unitloadTypeRepository.findByName(UNIT_LOAD_TYPE_PALLET)` — but the create arm calls that too (`:141`), so an `InOrder` on it does not discriminate arms. The plan must say the assertion is `verify(unitloadBusinessService, never()).transferUnitLoadToCarrier(...)` plus `verify(unitloadRepository, never()).save(...)` plus `verify(customerorderRepository, never()).save(...)`, not an `InOrder` |
| `palletise_existingLabelIsNotPalletType_throws`: "parameterised over Case / Tote / PickLocation / the sentinel" | In a Mockito unit test these are four identical stub values (`typeId = 4/2/1/0`). Harmless, but the gate should be told they are `typeId` fixtures, not DB rows |
| `BusinessException` assertion shape | The plan asserts "message contains `Not a pallet`". Per the estate's known trap, the 1-arg `BusinessException` ctor sets `key="placeholder"` and `getMessage()` returns the key only while it is absent from the bundle. The sibling at `MobilePalletizingService:258` uses the same 1-arg form, so parity is preserved — but §7 must say **assert on `getMessage()`, not `getKey()`**, or the gate will write the wrong assertion |

§7.3's four ablation gates are adequate as far as they go, but see §6: **all four are drawn from the plan's own model of the fix**, which is the exact failure R4 says is "realised once already."

---

## 6. VERIFY SCRIPT — full audit of all 17 rows

### Baselines reproduce exactly

| Direction | Plan claims | Measured |
|---|---|---|
| (i) unfixed `origin/develop` | 5 pass / 12 fail / 1 skip | **5 / 12 / 1** ✅ (P1–P5 green) |
| (ii) correct shadow | 17 pass / 0 fail | **17 / 0 / 1** ✅ |

The four mutations §7.6 claims are caught, are caught: guard in the create arm → `A1 A2 A3`; guard after the gate assertion → `A1 A2 A3`; empty `assertSourceUnitLoadMovable` body → `B2`; Fix B after `findByUnitloadId` → `B4`. The rev-1 → rev-2 repairs (`palletise_else_arm`, `palletise_create_arm`, `T4`'s `never()`) all work as advertised.

### Finding C-7 — seven independent near-misses score a full green (**High**)

Every shadow below was written from `origin/develop`, not from the plan. Each is a complete tree; each was scored with the shipped script.

| # | Shadow | What it actually does | Score |
|---|---|---|---|
| **N2** | `if (pallet.getTypeId().equals(palletType.getId())) throw new BusinessException("Not a pallet: "…)` — **the `!` dropped** | **Predicate inverted.** Every real `Pallet` is refused; every Case / Tote / PickLocation / sentinel is accepted. Strictly worse than develop. | **17/0** |
| **N3** | `if (!pallet.getTypeId().equals(…)) { LOG.warn("Not a pallet: " + pallet.getLabelid()); }` | **Logs instead of throwing. Bug 100% unfixed**, zero behaviour change. | **17/0** |
| **N4** | Same guard, but resolved from `WmsConstants.UNIT_LOAD_TYPE_CART` | Compares against `Cart`. Refuses every pallet, accepts every cart. | **17/0** |
| **N11** | Guard wrapped in `Boolean.parseBoolean(syspropService.getSysvalue("PALLET_TYPE_CHECK_ENABLED")) && !pallet.getTypeId()…` | **Sysprop-gated, default OFF → inert on every tenant.** §6.1 says "Feature flags: **No** — deliberately none"; the script cannot enforce that. | **17/0** |
| **N13** | `assertSourceUnitLoadMovable` declared + called **twice inside `scanDestination`**; `scanUnitLoad` never calls it | `B3` counts occurrences (`>= 3`), not sites. This is the **same hole the architect flagged as rev-1's `A4`** ("counts occurrences, not sites") carried forward unrepaired into `B3`. | **17/0** |
| **N14** | Fix B call wrapped in `if (Boolean.parseBoolean(syspropService.getSysvalue("MOVE_SOURCE_GUARD_ENABLED")))` | Fix B inert by default. `B4`'s `order_within` only sees textual position. | **17/0** |
| **N7** | Correct production code; both test files are ~8-line stubs whose only content is the tokens `InOrder`, `never()`, `never()).findByUnitloadId` | `T1`–`T4` are pure token greps. Nothing is tested. | **17/0** |

**Root causes, row by row:**

- **`A1`** (`palletise_else_arm | grep -qE 'getTypeId\(\)[^\n]*equals'`) asserts a *token sequence*, not a predicate. It cannot see `!`, cannot see which constant feeds `palletType`, and cannot see whether the `if` body throws. N2, N3, N4, N11 all satisfy it.
- **`A3`** (`grep -qE 'Not a pallet'` in the else arm) is satisfied by the string appearing anywhere in code — including inside `LOG.warn` (N3). It asserts the literal exists, not that it is thrown.
- **`A4`** has an `||` fallback: `code_contains 'UnitloadType[^\n]*palletType' "$PMV"`. This matches the *declaration line* regardless of which constant it resolves — so N4 (wrong constant, right variable name) passes. I confirmed the dependency is purely on the **variable name**: N4b, identical but with the variable renamed `type_cart`, is the only one of my shadows `A4` catches. `A4` is a naming assertion, not a semantic one.
- **`B3`** (`grep -c 'assertSourceUnitLoadMovable\(' >= 3`) — N13.
- **`T1`–`T4`** are greps against files the same author writes — N7. With `RUN_MVN=0` (the default) nothing executes.

**Minimum repairs (all mechanically checkable):**
1. `A1`: require the negation and the throw together, scoped to the else arm — e.g. `order_within` over `!\s*pallet\.getTypeId\(\)[^\n]*\.equals\(` then `throw new BusinessException\("Not a pallet: `, with a tempered gap so it cannot span the whole arm.
2. `A3`: require `throw new BusinessException\("Not a pallet: ` (the `throw` is the load-bearing token), not the bare literal.
3. `A4`: drop the `||` name fallback; require `UNIT_LOAD_TYPE_PALLET` **inside** `palletise_else_arm`, and require the same identifier to feed the comparison.
4. Add a row that fails on any sysprop read inside the else arm between the re-fetch and the carrier guard (`! palletise_else_arm | grep -q 'getSysvalue'`), pinning §6.1's "deliberately no feature flag" — otherwise N11/N14 are permanently invisible.
5. `B3`: replace the count with two scoped rows — `assertSourceUnitLoadMovable(` inside the `scanUnitLoad` slice **and** inside the `scanDestination` slice.
6. `B4`: additionally require the call is not inside a conditional — or at minimum assert the call statement matches `^\s*assertSourceUnitLoadMovable\(`.
7. Make `RUN_MVN=1` the **default**, or stop reporting the grep-only figures as acceptance. §7.6's own footnote concedes this and then reports 17/0 in the headline table anyway.

### Finding C-8 — one row family false-REDs a correct implementation (**Medium**)

`N5_correct_but_after_carrier_guard`: the plan's exact guard, placed three lines later — **after** the `if (pallet.getCarrierunitloadId() != null)` check at `:149-151` instead of before it. Behaviourally identical (both throw, no writes in between; it is arguably the better ordering, since the cheaper in-memory check runs first). Score: **15 pass / 2 fail — `A1`, `A3` red.**

Cause: `palletise_else_arm` ends at `getCarrierunitloadId\(\) != null`, so anything after that line is outside every A row's window. `A2` compounds it by requiring the type check to precede `assertPalletNotAssignedToGate` — so the plan's own §7.6 mutation "guard placed after the gate assertion" is scored as a defect when it is a benign reorder.

A verify script that reds a correct fix teaches the implementer to move code to satisfy the grep. Widen the `A` window's end anchor to `assertPalletNotAssignedToGate\(` (or to the closing of the else arm), and drop `assertPalletNotAssignedToGate` from `A2`'s second alternation — leave `setState|transferUnitLoadToCarrier`, which is the ordering that actually matters.

### Rows that are sound

`P1` (regex pinned inside `palletise_create_arm`) is a real repair over rev 1 and correctly detects a hoist. `P2`, `P3`, `P5` are honest pins. `B2`'s slice-end anchor is contained — I checked the two `getNirvana(` sites at `MobileMoveUnitloadService:133` and `:416`, and the `\n\s*(?:public|private|protected)\s` end anchor stops the slice before `transferStock:412`, so an empty stub cannot borrow a neighbour's token. `B4`'s slice (`scanDestination` → next member modifier) correctly spans `:251-390`. `code_only`'s comment stripper would corrupt any line carrying `//` inside a string literal; none of the five files has one today (**Low**, note only).

### Finding C-9 — §7.6's "the transferable lesson" is asserted but not applied (**High, and this is the headline**)

§7.6 states: *"Every mutation in the table above was written from `origin/develop`, not from this document. That is now the standard."*

The seven mutations in that table map one-to-one onto the plan's own rows — create-arm/`A1A2A3`, after-gate/`A1A2A3`, empty-body/`B2`, after-`:264`/`B4`, regex-hoist/`P1`, 2994-collaborator/`P5`, deleted-mobile-check/`P4`. Every mutation exists because a row exists to catch it. That is a family generated from the plan's model of the fix, exactly as rev 1's was. §10 R4 ("Ablation mutations drawn from this plan miss the plan's blind spots — Medium, **realised once already**") is now realised **twice**, and the mitigation the plan wrote for it did not fire.

The operational fix is not a better mutation list. It is: **the mutation family must be written by someone who did not write the script**, and the script is not accepted until an independent lane fails to break it.

---

## 7. DELIBERATE mode — §10 is a risk register, not a pre-mortem

§10's four rows are all risks the author already surfaced elsewhere in the document; none is a discovery. A pre-mortem ("this shipped, and three months later it made things worse — what happened?") yields at least these, none of which has a row:

- **PM-1.** Someone enables `SHIPPING_METHOD_ACTIVATED` for a tenant. `MobilePalletizingService.scanPalletBulk:321-329` becomes the live path and has no type check — and nobody looks, because this plan's §0 recorded mobile as safe (C-5).
- **PM-2.** The fix is implemented with a sysprop gate "for safe rollout" (the house habit — SBDEV-1666, 1762, 2994 all shipped default-OFF). The verify script is fully green, the plan says "Feature flags: No", and the guard is inert on every tenant (N11).
- **PM-3.** A later author refactors `palletise`'s else arm — moves the guard after the carrier check — the script goes red on a correct change, and the reviewer "fixes" it by reverting to the grep-pleasing order (C-8).
- **PM-4.** `assertSourceUnitLoadMovable` is extracted as identity-only. `scanDestination` still permits moving a source parked at `Shipped`, which `scanUnitLoad` refuses, and the asymmetry is now blessed by a named helper (C-4).

**§7's coverage given SBDEV-2217.** §7.4's reasoning is honest — there is no runnable IT lane, so "None" is a fact, not a choice. But that makes the unit tests the *only* executable evidence, and §7.6 defaults `RUN_MVN=0`, so the plan's headline acceptance figure contains **zero executed assertions**. With no IT lane, `RUN_MVN=1` is not "required for final acceptance" — it is the *entire* runtime evidence base and should be the default. §7.5's M1–M6 are good and correctly cover both branches; M6's "watch response time" is the right instrument for Fix B.

---

## 8. FACTUAL AUDIT — spot-check of every count, line number, and quoted block

| Claim | Verdict |
|---|---|
| `palletise` else arm has no type check | ✅ `:145-153` |
| `MobilePalletizingService:257-258`, `:350-351` type checks | ✅ verbatim |
| `ReceivingService.resolvePalletByLabelId:628` | ⚠️ method is at `:622`, check at **`:629`** |
| "verbatim parity with … `ReceivingService…:628`" | ⚠️ **not verbatim** — `:629` is `unitLoad.getTypeId() != unitloadType.getId()`, a **reference comparison on boxed `Long`**, not `.equals`. It works only via the `Long` cache (ids ≤ 127). Two idioms, not one. (Not this ticket's problem, but do not cite it as parity.) |
| `palletiseAndTruckLoad` else arm throws at `:304` | ✅ |
| `palletiseAndTruckLoad` zero callers | ✅ also zero UI references |
| §1.2 counts (299,426 / 23,597 / 1,064 / 66 / 1 = 324,154) | ✅ exact |
| `Pallet` = `id=5`; sentinel `type_id` 0 or 1 | ✅ on all six DBs |
| sentinel `storagelocation_id=0`, `entity_lock=0` | ✅ |
| sentinel `sum(amount) = sum(reservedamount) = 0` | ✅ 210,167 rows, all zero |
| 210,167 `Stockunit` at `:264` | ✅ exact |
| `dev_wh01_om1` → Pallet 412,170; `wh01_hydra_v2` → 9,389; R1's 421,559 | ✅ arithmetic and both queries, **but see C-1** (15,955 + 997 unresolved) |
| `unitload_record` where `tounitload='Nirwana'` = 0 | ✅ |
| eight MCP endpoints → six DBs | ✅ `dev_wh01_om1`, `wh01_hydra_v2`, `wh01_shipitez_v2`, `wh01_om1_v2`, `wh02_shipitez_v2`, `wh01_hydra_v2t` |
| `BillOfLadingController:458`; `palletizeOutboundParcel.vue:13` | ✅ |
| §2 "`checkReservedStock` … query per row" | ❌ **false** — C-2 |
| §2 "`scanUnitLoad` guards the source three ways" | ⚠️ **four** — `:146-149` (Shipped) omitted — C-4 |
| §4 "its type is `Default`" | ❌ **PickLocation on 2 of 6** — C-6 |
| §0 "Mobile rejects it today on every tenant" | ⚠️ true-today, sysprop-dependent, unpinned — C-5 |
| §6.2 step 1 "inject `UnitloadTypeRepository` if absent" | ✅ already a field on `ParcelMonitorViewService`; step is a no-op |
| §8 row 2 "the create branch already performs it" | ✅ `:141` |
| §9 Q1 (`getNirvana():195-211` constructs only when missing; retirement paths read ids only) | ✅ consistent with what I read; decision and reasoning both sound |

---

## MUST-FIX LIST

**High**
1. **C-7 — repair the verify script against the seven full-green near-misses** (repairs 1–7 in §6). At minimum: `A1`/`A3` must pin the negation *and* the `throw`; `A4` must drop the variable-name fallback; `B3` must become two scoped rows; add a row forbidding a sysprop read in the guarded window; make `RUN_MVN=1` the default.
2. **C-9 — the mutation family must be produced by an independent lane.** The script is not accepted on the author's own ablations. R4 has now fired twice; the mitigation as written does not work.
3. **C-4 — specify Fix B exactly**: which of `scanUnitLoad`'s four guards move into `assertSourceUnitLoadMovable`, and the exception message. Without this the TDD gate invents the contract.

**Medium**

4. **C-5 — correct §0 row 2**: mobile is safe *because* `SHIPPING_METHOD_ACTIVATED` is `false` on all six tenants; `MobilePalletizingService.scanPalletBulk:321-329` has no type check when it is `true`. Either add a verify row or file it explicitly as an accepted latent gap.
5. **C-2 — delete the false "query per row" claim** from §2 Bug 2; it contradicts §1.4 in the same document.
6. **C-8 — widen the `A` window** so a correct implementation that places the guard after the carrier check does not false-RED, and drop `assertPalletNotAssignedToGate` from `A2`'s ordering alternation.
7. **§7.1 test 2** — replace the `InOrder` framing with the `never()` verifications that are actually observable.

**Low**

8. **C-1** — restate §1.3's universal claim with the 3.9% unclassifiable figure.
9. **C-6** — fix §4's "its type is `Default`" (PickLocation on `wh02_shipitez_v2` and `wh01_hydra_v2t`).
10. **C-3** — §2 should state that `scanDestination` is reachable by direct API call, not through the mobile UI flow.
11. Cite `ReceivingService:629` (not `:628`) and stop calling it "verbatim parity" — it uses `!=`, not `.equals`.
12. Record in §4 that `unitload.type_id` is `NOT NULL` (verified: 0 nulls in 754,774 + 13,402 rows), since the guard dereferences it.
13. §9 Q3 can be closed: `palletiseAndTruckLoad` has zero callers in `src/main/java` **and** zero references in either UI repo. The plan's "proving it dead needs a UI + REST sweep this plan has not done" is now done.

---

**Bottom line.** The plan's diagnosis is correct and the rework substantially improved it — this is a real fix aimed at the right line, with the right guard, for the right reason. It should not ship on this verify script. Seven near-misses walk through untouched, including one that inverts the guard and three that make it inert, and the document asserts a validation standard it did not apply to itself. Repair the script under an independent mutation lane, pin Fix B's contract, and correct the four factual items, and this is an APPROVE.