---
title: "Outbound palletising accepts any existing container as a pallet"
ticket: "SBDEV-2995"
ticket_url: "https://app.clickup.com/t/868ktvc2h"
type: "bugfix"
priority: "normal"
status: "merged — PR #169 in develop @ 399fd30; no deploy prerequisites. Acceptance is executed tests + mutation coverage, not the verify script (§7.7)"
project:
  - wms2
version: "v2"
requester: "found during the SBDEV-2994 ralplan consensus review"
created: 2026-08-19
updated: 2026-08-19
db_verified: true
related:
  - "[[SBDEV-2994-move-stock-unknown-destination-container-generic-error]]"
  - "[[wms2-bol-truck-loading-workflow]]"
tags:
  - plan
  - wms2
  - palletising
---

# Outbound palletising accepts any existing container as a pallet

**Ticket:** [SBDEV-2995](https://app.clickup.com/t/868ktvc2h)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** normal — severe consequence, zero observed occurrences (§1.3)
**Status:** draft — **architect + critic + independent break lane all complete.** Diagnosis and fix design VERIFIED sound; the verify script is **rejected as semantic evidence** (§7.7). Ready to implement once acceptance moves to mutation coverage.
**Split:** the receiving half became **[SBDEV-3004](https://app.clickup.com/t/868ku6zua)**
**Dependencies:** **none.** (The first draft hard-blocked on SBDEV-2994 PR #167; §4 explains why that is gone.)

**Acceptance script:** `sbdocs/9-System/scripts/verify-SBDEV-2995-palletising-receiving-accept-nirvana-sentinel.sh`

---

## 0. What the first draft got wrong

Recorded because the corrections are the plan, not footnotes to it. The architect review invalidated
**3 of the 4** sites the first draft proposed to fix, and replaced the guard mechanism.

| First draft | Reality (verified at `origin/develop` `e7b3b88`) |
|---|---|
| Fix `ParcelMonitorViewService.palletiseAndTruckLoad:287` too — "both copies" | ❌ **No reachable existing-label path.** Its `else` branch is `throw new BusinessException("Pallet with name=" + palletName + " already exists!")` (`:304`). A guard there is **dead code**, and `pallet` is still `null`. Verify row `A3` would have pinned dead code permanently. |
| Fix `MobilePalletizingService:209, 316` — "**Mobile is not better-guarded here**" | ❌ **Exactly backwards.** Both `else` branches open with `if (!pallet.getTypeId().equals(pallet_type.getId())) throw new BusinessException("Not a pallet: " + …)` (`:257-258`, `:350-351`). The sentinel's `type_id` is 0 or 1; `Pallet` is 5. Mobile rejects it today on every tenant. |
| Guard with `DestinationEligibilityService.assertCanReceiveStock` from SBDEV-2994 | ❌ **Wrong predicate, and it costs a blocking dependency.** See §4. |

⚠ **The draft already contained the fact that kills two of those rows.** §0 row 9 used *"the sentinel's
type is `Default`, not `Pallet`"* to file receiving-assign out of scope — and never carried it to the
mobile row. The triage classified by **call shape** (`findByLabelid` → attaches stock) without reading
the guard on the next line.

---

## 1. Problem Statement

### 1.1 Symptom

On the outbound palletising screen the **Pallet Name** field is free text
(`wms2-web-ui components/reports/popups/palletizeOutboundParcel.vue:13`). Typing the label of **any
container that already exists** — a Case, a Tote, a PickLocation unit load, or the Nirvana retirement
sentinel — attaches the scanned parcels to it as their carrier and flips the orders to `PALLETIZED`.
No error.

### 1.2 The real defect is narrower and bigger than "the sentinel"

`ParcelMonitorViewService.palletise:129-152` validates the label **only when creating**:

```java
Optional<Unitload> palletOpt = unitloadRepository.findByLabelid(palletName);
if (palletOpt.isEmpty()) {
    …
    if (!palletName.matches(pattern) && !palletName.matches(convertedPrintingPattern)) {
        throw new BusinessException("Not valid format: " + palletName);   // ← NEW labels only
    }
    …
} else {
    pallet = unitloadRepository.findByIdForUpdate(palletOpt.get().getId()) …
    if (pallet.getCarrierunitloadId() != null) { throw … }   // passes for any free container
    billofladingPositionService.assertPalletNotAssignedToGate(pallet.getLabelid());   // passes
}
```

**There is no type check on the existing-label branch.** Every sibling implementation has one —
`MobilePalletizingService:257`, `:350`, and `ReceivingService.resolvePalletByLabelId:628`. This one
method is the outlier.

**What that admits today**, on `dev_wh01_om1` — unit loads with `carrierunitload_id IS NULL` and
`type ≠ Pallet`, i.e. what the `else` branch accepts as a carrier right now:

| type | count |
|---|---|
| Case | 299,426 |
| PickLocation | 23,597 |
| Tote | 1,064 |
| Package | 66 |
| **Default (the Nirvana sentinel)** | **1** |

The sentinel is **1 of 324,154**. A ticket scoped to the sentinel fixes 0.0003% of the exposure.

### 1.3 DB verification (`db_verified: true`)

**Zero regression risk, measured on the population this fix constrains:**

```sql
SELECT t.name, count(*) FROM unitload_record r
  JOIN unitload u ON u.labelid = r.tounitload
  JOIN unitload_type t ON t.id = u.type_id
WHERE r.activitycode = 'PALLETIZING' GROUP BY 1;
```

`dev_wh01_om1` → **Pallet: 412,170** and nothing else. `wh01_hydra_v2` → **Pallet: 9,389** and nothing
else. **Every palletising operation ever recorded on both tenants targeted a Pallet-type carrier.**

**The sentinel, for completeness** (six distinct tenant DBs — ⚠ eight MCP endpoints resolve to six;
`wms2-hydra-uat` / `wms2-hydra-dev2` / `nywh-hydra-uat` are all `wh01_hydra_v2`): exactly one row each,
`labelid='Nirwana'`, `storagelocation_id=0`, `entity_lock=0`, `type_id` 0 (migrated) or 1 (fresh-seeded).
`Pallet` is `id=5` on all of them. `unitload_record` where `tounitload='Nirwana'` = **0**, against
412,170 `PALLETIZING` rows — so the probe has signal and this has never fired.

### 1.4 Blast radius

The sentinel's stock-unit rows are **all zero-amount** (`sum(amount) = sum(reservedamount) = 0` on both
tenants). These paths corrupt **placement and reporting**, never quantity. That, plus zero observed
occurrences, is the basis for `priority: normal`.

### 1.5 Reproduction

Web UI → Reports → Parcel Monitor → select parcels → **Palletize** → type any existing non-pallet
container label (e.g. a Case label, or `Nirwana`) → Submit. The parcels attach; orders go `PALLETIZED`.

---

## 2. Root Cause Analysis

### Bug 1 — the type check is missing on the one branch that needs it

The house idiom for "is this a pallet I may load onto" is a `typeId` comparison, present at three
sibling sites and absent here. The format regex is not a substitute: it validates *shape of a new
label*, not *kind of an existing container*, and it is deliberately scoped to the create branch.

**Why not hoist the regex instead** (the first draft's rejected alternative, still rejected): hoisting
would reject every existing pallet whose label predates a sysprop change — it fires on **real
pallets**, not on wrong containers. The type check fires on exactly the wrong containers and on nothing
else. Verify row `P1` pins the regex in place so a future author does not "simplify" it outward.

### Bug 2 — `scanDestination` re-resolves the source without the identity check its sibling has

`MobileMoveUnitloadService:254`. `scanUnitLoad` guards the source three ways (`:122` label, `:135`
identity, `:139-143` location); `scanDestination` re-resolves the same source and checks only
`ON_HOLD` and reservations.

⚠ **This is not merely "defence in depth", as the first draft called it.** `scanDestination:264` then
does `stockunitRepository.findByUnitloadId(sourceUnitLoad.getId())` and iterates — for the sentinel
that materialises **210,167 `Stockunit` entities** on wineco-dev, after which `checkReservedStock`
iterates them again with a `pickingorderPositionRepository` query per row. That is an OOM/timeout on a
mobile endpoint, not a cosmetic gap. **The guard must be placed before `:264`.**

---

## 3. Architecture Overview

```
 palletizeOutboundParcel.vue:13   free-text "Pallet Name"
        │ POST /v3/billOfLading/palletize
        ▼
 BillOfLadingController:458 ──► ParcelMonitorViewService.palletise:129
        │
        ├─ palletOpt.isEmpty()  ──► regex check ──► createUnitload(type = Pallet)      ✅ safe
        │
        └─ else (EXISTING label) ─► findByIdForUpdate
                                    ✗ NO TYPE CHECK              ← Bug 1
                                    ✓ carrierunitloadId == null   (passes for 324,154 containers)
                                    ✓ assertPalletNotAssignedToGate
                                          ▼
                                    transferUnitLoadToCarrier(parcel, <any container>)
                                    customerOrder.setState(PALLETIZED)
```

### Key files

| File | Lines | Role |
|---|---|---|
| `service/ParcelMonitorViewService.java` | 147-152 | **the single Fix A site** |
| `service/mobile/MobilePalletizingService.java` | 257-258, 350-351 | **the reference idiom — already correct, do not change** |
| `service/ReceivingService.java` | 628 | the same idiom, third instance |
| `service/mobile/MobileMoveUnitloadService.java` | 254, 264 | Bug 2 |

---

## 4. Fix Design

### Fix A — the existing-label branch gets the type check its siblings have

`ParcelMonitorViewService.java`, inside the `else` branch, immediately after the locked re-fetch:

```java
pallet = unitloadRepository.findByIdForUpdate(palletOpt.get().getId())
    .orElseThrow(() -> new EntityNotFoundException("UnitLoad", palletOpt.get().getId()));

// SBDEV-2995: an EXISTING label skips the outbound-pallet regex above, so any free container —
// Case, Tote, PickLocation, or the Nirvana sentinel — is accepted as a carrier. Verbatim parity
// with MobilePalletizingService:257-258 and ReceivingService.resolvePalletByLabelId:628.
UnitloadType palletType = unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_PALLET)
    .orElseThrow(() -> new EntityNotFoundException("UnitLoadType not found by name: " + WmsConstants.UNIT_LOAD_TYPE_PALLET));
if (!pallet.getTypeId().equals(palletType.getId())) {
    throw new BusinessException("Not a pallet: " + pallet.getLabelid());
}

if (pallet.getCarrierunitloadId() != null) { … }
```

**Why this and not `DestinationEligibilityService.assertCanReceiveStock` (the first draft's choice):**

| | type check | `assertCanReceiveStock` |
|---|---|---|
| Wrong containers refused (wineco-dev) | **324,154** | 1 |
| Dependency on SBDEV-2994 PR #167 | **none** | hard, blocking |
| Predicate answers | "is this a pallet?" — the question asked | "is this a live stock location?" |
| Robustness | `type_id` is not moved by any workflow | location-based; **one `storagelocation_id` write from silently passing** |
| Rollout coupling | none | see below |

⚠ **The coupling that decided it.** `assertCanReceiveStock` has two clauses under two governance
regimes: an **ungated** Nirvana clause, and **gated** lock/Shipped clauses behind
`TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` (default OFF). Calling it here would enrol palletising in
SBDEV-2994's rollout, whose retirement criterion — *"run one operating cycle, count the shadow lines,
enable where the count is zero"* — will be measured on **move-stock** traffic. The day someone flips
that sysprop on move-stock evidence, palletising silently acquires two refusal rules it was never
measured against. The first draft's §6.1 called this *"ungated behaviour for free"*; it is free only
for the Nirvana clause.

**Residual, stated rather than hidden:** the type check does **not** catch a `Pallet`-type unit load
parked at Nirwana. No such row exists on any of the six databases (the sentinel is the only UL at
Nirwana with a scannable label, and its type is `Default`). If one ever appears, `assertCanReceiveStock`
is the guard that would catch it — see §9 Q2.

### Fix B — place the source guard before the 210k-row materialisation

Extract `scanUnitLoad`'s identity check into `private void assertNotNirvanaSentinel(Unitload)` and
call it from both entry points.

⚠ **Renamed during implementation, on a code-review Medium.** This section originally specified
`assertSourceUnitLoadMovable`. `scanUnitLoad` applies **five** source guards, not two — the scanned-label
literal (`:122`), the sentinel identity check (`:133`), source-at-Nirwana (`:137-140`),
source-at-Shipped (`:142-145`), and source-carrying-a-`FixLocationAssignment` (`:158-161`, which this
plan never enumerated). Only the identity check moves, so a helper named *assertSourceUnitLoadMovable*,
called unconditionally from both entry points, would read as "source movability is now enforced on both
paths" — false for four of the five clauses, and the next author would believe it. The other four
remain `scanUnitLoad`-only by design (§4 rationale: the 210,167-row materialisation is unique to the
sentinel); closing them is an unmeasured behaviour change on an unscoped path. The narrow name plus a
Javadoc naming the four omissions is the honest form. **No behaviour difference.** In `scanDestination` it must sit **before** `:264`'s
`findByUnitloadId`, for the reason in §2 Bug 2. Verify row `C3` pins that ordering.

---

## 5. File Change Summary

| File | Change | Description |
|---|---|---|
| `service/ParcelMonitorViewService.java` | modify | Fix A — one site, `:147-152` |
| `service/mobile/MobileMoveUnitloadService.java` | modify | Fix B — extract + two calls, ordered before `:264` |
| `src/test/.../unit/service/ParcelMonitorViewServiceUnitTest.java` | modify | Fix A — **corrected at gate time.** This section proposed a *new* class; `ParcelMonitorViewServiceUnitTest` already exists on `origin/develop` with 28 tests across six `@Nested` classes, so the gate added a nested `Sbdev2995PalletTypeGuard` beside them. §0.3 never enumerated the class — the same classified-from-the-plan's-model error the architect review caught twice. Verify rows `T1`–`T3` inherited the wrong path and were three false REDs from one stale premise; repointed. |
| `src/test/.../unit/service/mobile/MobileMoveUnitloadServiceUnitTest.java` | modify | Fix B |

**No** new message keys (`"Not a pallet: "` is the sibling's existing literal), **no** migration, **no**
sysprop, **no** new collaborator, **no** cross-ticket dependency.

---

## 6. Implementation Steps

### 6.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| Dependency | **N/A — removed in rework** | The type check needs nothing from SBDEV-2994. The first draft's R3 ("High — blocking") is gone. |
| DB state | N/A | No schema or data change. The sentinel is left exactly as-is. |
| Feature flags | **No** | Deliberately none — and deliberately *not* inheriting SBDEV-2994's gate (§4). |
| System properties | N/A | Reuses `UNIT_LOAD_TYPE_PALLET`; no sysprop read is added. |
| Deploy order | N/A | Single repo, no UI change. |
| Data migration | **N/A — nothing to remediate** | §1.3: zero occurrences. |
| Monitoring | No | `BusinessException` → already-visible error contract. |

### 6.2 Steps

1. **Fix A** — inject `UnitloadTypeRepository` if absent, add the type check. Commit alone.
2. **Fix B** — extract `assertSourceUnitLoadMovable`, call from both sites, ordered before `:264`.
3. **Tests** (§7), then `mvn clean compile`.

**Branch:** `bugfix/SBDEV-2995-palletising-pallet-type-check` off freshly-fetched `origin/develop`.

---

## 7. Testing Plan

### 7.1 Unit — `ParcelMonitorViewServicePalletTypeGuardTest` (new)

| Test | Asserts |
|---|---|
| `palletise_existingLabelIsNotPalletType_throws` | message contains `Not a pallet`; parameterised over Case / Tote / PickLocation / the sentinel |
| `palletise_refusesBeforeAnyWrite` | `InOrder`: the type check precedes `transferUnitLoadToCarrier`; **zero** `save`; no `setState(PALLETIZED)` |
| `palletise_existingPalletTypeLabel_stillSucceeds` | Non-regression over the 412,170-row happy path |
| `palletise_newLabel_stillFormatChecked` | The create branch is untouched — the regex still fires |

### 7.2 Unit — `MobileMoveUnitloadServiceUnitTest` (modify)

| Test | Asserts |
|---|---|
| `scanDestination_sourceIsNirvanaSentinel_throwsBeforeLoadingStock` | `verify(stockunitRepository, never()).findByUnitloadId(any())` — the ordering claim, pinned |
| `scanUnitLoad_sourceIsNirvanaSentinel_stillThrows` | Non-regression on the existing guard |

### 7.3 Ablation gates (mandatory — run each, each must fail)

⚠ **These must be written from the CODE, not from this plan.** The first draft's seven mutations all
passed while five drawn from reading the code scored `22 pass / 0 fail`. See §7.6.

- type check placed in the **create** branch instead of the `else` branch → 7.1 tests 1-2 fail
- type check placed **after** `transferUnitLoadToCarrier` → test 2 fails
- `assertSourceUnitLoadMovable` given an **empty body** → 7.2 test 1 fails
- Fix B's call placed **after** `:264` → 7.2 test 1 fails

### 7.4 Integration

**None.** The v2 Testcontainers lane cannot boot (SBDEV-2217); the IT surface is `@Disabled` on
develop. Not a coverage choice — no runnable lane exists.

### 7.5 Manual test plan

| # | Scenario | Env | Expected |
|---|---|---|---|
| M1 | Palletize with an existing **Case** label | WineCo dev, web | Refused: "Not a pallet: …" |
| M2 | Palletize with `Nirwana` | WineCo dev, web | Refused, same message |
| M3 | Palletize with a valid existing `OUT-######` pallet | WineCo dev, web | Succeeds unchanged |
| M4 | Palletize with a **new** `OUT-######` label | WineCo dev, web | Created and used — create branch untouched |
| M5 | Palletize with a new malformed label | WineCo dev, web | "Not valid format" — regex still in the create branch |
| M6 | `POST /v3/moveUnitload/selectDestination` with source `Nirwana`, called directly | WineCo dev | Refused fast; **no** 210k-row load (watch response time) |

---

## 7.6 Acceptance

**Script:** `sbdocs/9-System/scripts/verify-SBDEV-2995-palletising-receiving-accept-nirvana-sentinel.sh` (revision 2)

| Direction | Result |
|---|---|
| (i) unfixed `origin/develop` | **5 pass / 12 fail / 1 skip** — only the five parity pins |
| (ii) correct shadow | **17 pass / 0 fail** — no false-REDs |
| (iii) seven **code-derived** mutations | each caught |

| Mutation | Caught by |
|---|---|
| **guard moved to the CREATE arm — the bug 100% unfixed** | `A1` `A2` `A3` |
| guard placed after the gate assertion | `A1` `A2` `A3` |
| `assertSourceUnitLoadMovable` left with an **empty body** | `B2` |
| Fix B called **after** the 210k-row `findByUnitloadId` | `B4` |
| format regex **hoisted out** of the create arm | `P1` |
| mobile "fixed" with the 2994 collaborator | `P5` |
| mobile's working type check deleted | `P4` |

### What revision 1 could not see, and why

Revision 1 scored `22 pass / 0 fail` against **five** near-miss implementations. The root cause was
one blind spot: **`A1`/`A2` sliced the whole `palletise` method.** Both arms of
`if (palletOpt.isEmpty())` sit before `transferUnitLoadToCarrier`, so a guard in the **create** arm —
leaving the defect entirely unfixed — was indistinguishable from one in the **existing** arm. The
single most important structural fact about this fix was invisible to every row.

Revision 2 slices the `else` arm specifically (`findByIdForUpdate(palletOpt` →
`getCarrierunitloadId() != null`), which is why `W1` now fails three rows.

### One more defect caught at baseline

`T4` passed on the unfixed tree: it grepped `findByUnitloadId` in the existing MMU test class, which
already mentions the symbol, so it could not distinguish "covers the new ordering" from "mentions it".
It now requires the negative assertion that actually pins the ordering — `never()).findByUnitloadId`.

### The transferable lesson

⚠ **A near-miss family written by the plan's author cannot test the plan's blind spots.** Revision 1's
seven mutations all failed correctly *and proved nothing*, because each was derived from the plan's own
model of the fix. The five that walked through came from reading the **code**. Every mutation in the
table above was written from `origin/develop`, not from this document. That is now the standard.

⚠ **`RUN_MVN` defaults to `0`, so the figures above are code-SHAPE only.** Revision 1's headline
"22 pass / 0 fail" was grep-only and no test ever executed. Final acceptance requires `RUN_MVN=1`.

---

## 8. Horizontal Scalability Validation

| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | **N/A** |
| 2 | Connection pool | **No** — one `findByName(UNIT_LOAD_TYPE_PALLET)` per palletise, inside the existing transaction. The create branch already performs it |
| 3 | Scheduled jobs | **N/A** |
| 4 | Long transactions | **Improves** — Fix B prevents a 210,167-entity materialisation on a mobile endpoint |
| 5 | Request affinity | **N/A** |
| 6 | Retry / idempotency | **No** — refusal paths write nothing |
| 7 | Tenant context | **N/A** |
| 8 | Distributed locks | **No** — Fix A sits after the existing `findByIdForUpdate`; the lock window is unchanged |
| 9 | Cache invalidation | **N/A** |
| 10 | External notifications | **No** — the guard precedes `setState(PALLETIZED)`, so no OMS notification fires on a refusal |

---

## 9. Open Questions

- **Q1 — should the sentinel be locked at creation?** ⚠ **Decision unchanged (no), reasoning replaced.**
  The first draft's reasons were wrong: neither retirement path reads the sentinel's lock
  (`UnitloadBusinessService.sendToNirvana:371-399` and `StockunitBusinessService.sendStockUnitToNirvana:401-424`
  read only ids), so "three C-category consumers expect it usable" was unsubstantiated. The two reasons
  that actually decide it: **(i)** it would fix **neither** bug here — `palletise` never reads
  `Unitload.getEntityLock()`, and `unassignPallet`'s `ignoreLock=true` gates the *Location's* lock, not
  the unit load's; **(ii)** `getNirvana():195-211` only constructs when the row is **missing**, and all
  six tenants already have it, so the change is a **no-op everywhere** without a data migration this
  plan rules out. Not worth its own ticket as scoped.
- **Q2 — should `assertCanReceiveStock` be added *in addition to* the type check?** It is the only guard
  that would catch a `Pallet`-type unit load parked at Nirwana, which the type check misses. No such row
  exists today on any of six databases. **Recommendation: no**, on the §4 coupling grounds — but if it
  is added, §6.1 must record that palletising becomes governed by `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED`.
- **Q3 — `palletiseAndTruckLoad` has zero callers in `src/main/java`.** Delete it? Out of scope here;
  proving it dead needs a UI + REST sweep this plan has not done.

---

## 10. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **R1** The type check refuses a legitimate carrier | **Low** | Measured: all 421,559 palletisings across two tenants targeted a Pallet-type carrier. M3 covers the happy path |
| **R2** A `Pallet`-type UL that is otherwise ineligible slips through | **Low** | **Widened at implementation time.** `ParcelMonitorViewService` reads neither `Unitload.getStoragelocationId()` nor `getEntityLock()` **anywhere** — verified by grep — so the type check leaves three residuals open, not one: a `Pallet`-type UL parked at **Nirwana**, one parked at **Shipped**, and one with `entity_lock` ON_HOLD / GOING_TO_DELETE. All are pre-existing and unchanged by this fix; none exists on any of the six databases. Q2 records `assertCanReceiveStock` as the guard that would close all three, and the §4 rollout-coupling argument for not adding it here. |
| **R3** A future author "simplifies" by hoisting the regex out of the create branch | Medium | `P1` pins the regex **inside** the `isEmpty()` branch (the first draft's `P1` only grepped the constant file-wide and could not detect a hoist) |
| **R4** Ablation mutations drawn from this plan miss the plan's blind spots | **Medium — realised once already** | §7.3 requires mutations written from the code. The first draft's seven all passed while five code-derived ones scored `0 fail` |

---

## 11. Implementation Status

**Implemented 2026-08-19.** Branch `bugfix/SBDEV-2995-palletising-pallet-type-check` off `origin/develop @ e7b3b88`.
Worktree `.claude/worktrees/wms2-api/SBDEV-2995`. Single repo (`v2/wms2-api`); no UI change, no migration, no sysprop.

### What shipped

**PR:** https://github.com/SiteBossInc/wms2-api/pull/169 — **MERGED** into `develop` 2026-08-20, merge commit `399fd30`, after SBDEV-2994's three PRs and onto the resulting `develop` (clean merge, no file overlap with those twelve). Both guards verified present in the merged tree. **No deploy prerequisites** — no migration, no sysprop, no ordering; both guards are active on deploy.
**ClickUp:** SBDEV-2995 → `pr submitted`. Its description was rewritten at this point: it still carried the
pre-split framing (`StockunitService.transferStock` accepting `Nirwana` as a *destination*), which is
SBDEV-2994's defect and shipped in PR #167. The title was updated at the split; the body was not.

| Commit | Subject |
|---|---|
| `73125ca` | `fix(palletising): type-check the pallet on the existing-label arm (SBDEV-2995)` |
| `0eec81d` | `fix(move-unitload): refuse the Nirvana sentinel as a source on both entry points (SBDEV-2995)` |

| Fix | Site | Note |
|---|---|---|
| A | `ParcelMonitorViewService.java:149-156` | Type check in the `else` (existing-label) arm, after the `findByIdForUpdate` lock, before the carrier guard. Verbatim parity with `MobilePalletizingService:257` — same operand order, same 1-arg `BusinessException`, same literal. Not sysprop-gated. Format regex left in the CREATE arm. |
| B | `MobileMoveUnitloadService.java:218` (helper), `:133` + `:284` (calls) | `assertNotNirvanaSentinel(Unitload)`, identity-only, called unconditionally from both entry points; in `scanDestination` it precedes `findByUnitloadId`. |

`palletiseAndTruckLoad` and `MobilePalletizingService` unchanged, as §0 predicted — re-verified: `palletiseAndTruckLoad` has **zero** callers in `src/main/java`, `palletise` has exactly one (`BillOfLadingController:480`), and `MobilePalletizingService` already carries the check at **both** `:258` and `:351`.

### Test results

| Gate | Result |
|---|---|
| `ParcelMonitorViewServiceUnitTest` | 35/35 pass (28 before) |
| `MobileMoveUnitloadServiceUnitTest` | 25/25 pass |
| `MobileMoveUnitloadServiceTest` | 23/23 pass |
| `mvn clean compile` | BUILD SUCCESS |
| `mvn test` (full) | 5158 run, **2 failures — both the pre-existing clean-`develop` baseline** (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`). No new red. |
| `verify-SBDEV-2995…sh` | 18 pass / 0 fail / 1 skip on the worktree; 7 pass / 11 fail on the unfixed control |
| **PIT mutation coverage, changed lines** | **6/7 killed** |

### Mutation coverage — the acceptance figure (§7.7)

| Line | Mutation | Status |
|---|---|---|
| `PMV:154` | negated conditional (the guard predicate) | **KILLED** |
| `PMV:153` | `orElseThrow` lambda → `null` | **KILLED** |
| `PMV:157` | negated conditional (carrier guard) | **KILLED** |
| `MMU:221` | negated conditional (sentinel identity) | **KILLED** |
| `MMU:133` | **removed call** to `assertNotNirvanaSentinel` (`scanUnitLoad`) | **KILLED** |
| `MMU:284` | **removed call** to `assertNotNirvanaSentinel` (`scanDestination`) | **KILLED** |
| `PMV:148` | `orElseThrow` lambda → `null` | `NO_COVERAGE` — **pre-existing**, SBDEV-2232's lambda, not part of this change |

The inverted-predicate, empty-body, and deleted-call escapes that defeated the grep script are all killed by executed tests. The PIT plugin was added to `pom.xml` **for the measurement only and reverted before committing** — PR carries no build tooling.

### 15 pre-existing tests broke and were repaired (the plan predicted 13, in one class)

One root cause: the guards introduced collaborator calls that existing tests never stubbed. **None was deleted or weakened.**

| Class | Broke | Repair |
|---|---|---|
| `ParcelMonitorViewServiceUnitTest` | 13 (5 fail + 8 error) | `lenient()` stub of `unitloadTypeRepository.findByName(PALLET)` + `testPallet.setTypeId(...)` in the shared `@BeforeEach`; two local fixtures that built their own `Unitload` also needed `setTypeId` (they NPE'd — the fixture had never set `type_id`, invisible only because the else arm did no type lookup) |
| `MobileMoveUnitloadServiceUnitTest` | 2 | `lenient()` default for `unitloadService.getNirvana()` in `@BeforeEach` |
| **`MobileMoveUnitloadServiceTest`** | **2** | same — **this class was missed by both §0.3 and the TDD gate**; a second, differently-named test class for the same service |

### Deviations from this plan, and why

1. **§5 proposed a new test class** `ParcelMonitorViewServicePalletTypeGuardTest`. Not created — `ParcelMonitorViewServiceUnitTest` already existed with 28 tests. A nested `Sbdev2995PalletTypeGuard` was added instead. Verify rows `T1`–`T3` inherited the phantom path and were three false REDs from one stale premise; repointed. `T2`'s `InOrder` requirement was replaced — §7.1's own critic note forbids `InOrder` on `findByName` here.
2. **§4 named the helper `assertSourceUnitLoadMovable`.** Renamed to `assertNotNirvanaSentinel` on a code-review Medium — see §4. No behaviour difference.
3. **The endpoint `POST /v3/moveUnitLoad/scanDestination` does not exist.** Real route is `POST /v3/moveUnitload/selectDestination` (`MoveUnitloadController:25,64`); a similarly-named route on `MoveStockController` does exist and points at a service this fix does not touch. Corrected in §7.5 M6 and in the code comments — manual step M6 would otherwise have 404'd and been ticked as a pass.

### Landmines this plan did not predict

- **A second test class for the same service.** `MobileMoveUnitloadServiceTest` sits beside `MobileMoveUnitloadServiceUnitTest`; grepping only for `*UnitTest` misses it, and it broke on the same unstubbed collaborator.
- **`scanUnitLoad` has FIVE source guards, not two.** The plan enumerated the identity check and (implicitly) the location checks; it never listed the `FixLocationAssignment` guard at `:158-161`. `scanDestination` is still missing four of the five — recorded in the helper's Javadoc so the narrow name cannot be misread as full enforcement.
- **A vacuous parity test.** The first draft of `scanUnitLoad_shouldStillThrow_whenSourceIsNirvanaSentinel` scanned the literal `"Nirwana"`, which trips `scanUnitLoad`'s label guard at `:122` and never reaches the identity check at `:133` — it stayed green with the guard under test deleted. Rewritten to reach the sentinel by id under an ordinary label; **ablation-proved**: commenting out the `:133` call site now fails exactly that test.
- **`ParcelMonitorViewService` reads neither `getStoragelocationId()` nor `getEntityLock()` anywhere** — so R2's residual is three cases, not one (see §10).

### Independent review

Two lanes were run against the implementation. The **code-review lane** returned **0 High, 4 Medium, 4 Low** on the first pass and **0 new High/Medium** on the second (scoped to the fixes). All 8 first-pass findings and both second-pass Lows were fixed; the Mediums are recorded above as landmines. The **adversarial break lane never delivered a report** across three requests — attacks A–F were therefore run by the implementing context itself, which is weaker evidence by exactly the standard §7.7 sets out, and is flagged as such in the PR body. All six attacks failed to find a defect in this change.

The single highest-value finding was that the first draft of the `scanUnitLoad` parity test was **vacuous**. It is now ablation-proved in both directions: removing the `:133` call site fails exactly that test, and a `verify(locationRepository, never()).findByName(NIRVANA)` pin stops it re-vacuuming if the fixture ever grows the two stubs that would let the *next* guard satisfy its message assertion — `"Can not move"` is a strict prefix of `:139`'s `"Can not move unit load from …"`.

### Skill/tooling corrections worth carrying forward

- `wms-plan-executor`'s shadow-root recipe assumes `PROJECT_ROOT` is the **monorepo** root. This script's `PROJECT_ROOT` is the **repo** root and it `cd`s into it, so the recipe produced `0 pass / 19 fail` — a harness failure that reads exactly like a catastrophic code failure. Point `PROJECT_ROOT` straight at the worktree.
- A blanket re-indent regex applied while moving a Javadoc silently altered **27 lines across five unrelated pre-existing tests**. Caught by `git diff -U0 | grep '^-'`; the file was reverted and re-applied. Check for a purely-additive diff before trusting a green run.


---

## 7.7 The verify script is not acceptance evidence — verdict of the independent break lane

An adversarial lane, given the fix spec but not this document, built its own correct implementation and
then attacked the script. Reports: `reviews/SBDEV-2995-review-critic.md`, `reviews/SBDEV-2995-break-report.md`.

**Result: 13 false GREENS at `18 pass, 0 fail`, and 10 false REDS on behaviourally-correct code.**

Nine of the ten previously-known escapes were genuinely closed by the repairs. The lane then found
thirteen more. The worst three:

| # | Shadow | Reality |
|---|---|---|
| **F1** | **unfixed `develop` + one dead helper above `palletise`** containing a textbook guard, never called | **Every Fix A row and every parity pin green.** I reproduced it: `10 pass`, the bug 100% present. `slice` is a **first-match-in-file** search, so a decoy relocates the whole graded window. This file already contains two near-duplicate palletise methods, so it is not hypothetical |
| **F2** | Fix B removed from `scanDestination`; a `LOG.debug("next step is scanDestination")` added to `scanUnitLoad` | `B3`/`B4` anchor on the bare token `scanDestination`, so they grade the tail of **`scanUnitLoad`** — which legitimately satisfies both. 210,167 entities still materialise |
| **F7** | resolve `UNIT_LOAD_TYPE_PALLET` (satisfying `A4`), then compare against a second `UNIT_LOAD_TYPE_CART` lookup | Rejects every real pallet, accepts every cart — **strictly worse than shipping nothing**. `A4` checks the constant is *mentioned*, never that it is the one compared |

Plus: a `@Value`-gated guard defaulting to `false` (`A5` blacklists only `getSysvalue|parseBoolean`); the
throw swallowed by a surrounding `try/catch`; a helper body that *mentions* Nirvana without comparing or
throwing; `equals(5L)` hardcoded; the mobile parity throws replaced with `LOG.warn` (`P4` counts
conditions, not enforcement); `MobilePalletizingService` gutted to a husk (`P5` negates over a
surviving-but-empty file); and compiling, assertion-free test stubs that survive `mvn test` too.

⚠ **And `RUN_MVN=1` — now the default — degrades silently.** `mvn` is SDKMAN-only here, so the maven
rows `SKIP` and the script still **exits 0**. "Final acceptance requires `RUN_MVN=1`" is documentation,
not enforcement.

### The false REDs matter as much

Ten idiomatic correct implementations are **rejected**, including several a reviewer would actively
request: the guard extracted into `private void assertIsPallet(...)` — *the very idiom this plan
mandates for Fix B* — plus `Objects.equals` (the null-safe form), constant-first operand order (the
NPE-safe convention), a line break inside the `if`, `if (palletOpt.isPresent())` instead of `isEmpty()`,
a `this.` qualifier, and the helper declared last in the class. **A script that reds correct code
teaches the implementer to contort code until the grep is happy.**

### Conclusion — a structural ceiling, not a patchable bug

Three rounds of repair, each closing the previous round's escapes, each followed by a new lane finding
more. The pattern is not carelessness; it is the technique. **A regex over source text cannot express
"this predicate, in this method, actually enforces this rule"** — it can only express "these tokens
appear near each other," and every such assertion has a decoy.

**Adopted position for this plan, and proposed for the vault:**

1. **The verify script is a coarse "did you touch the right files" check, not semantic acceptance.**
   Its green means nothing about correctness. Downgrade every claim in §7.6 accordingly.
2. **The executed unit tests are the contract.** `RUN_MVN=1` must be the default *and* a missing `mvn`
   must be a **FAIL**, never a SKIP, when it was requested.
3. **A verify script is never validated by its own author.** Three rounds demonstrated this; the
   author's mutation family only tests what the author already imagined.
4. Where a semantic property genuinely must be pinned, pin it with an **executed test**, not a grep.

The repairs the break report lists are worth applying for the coarse-check role — but they must not
restore the belief that a green from this script is evidence the fix is present.
