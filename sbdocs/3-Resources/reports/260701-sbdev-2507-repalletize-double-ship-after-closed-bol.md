---
title: "SBDEV-2507 — Parcel Re-Palletized & Double-Shipped After Closed BOL (Web Palletize Check Gap)"
type: investigation
status: concluded
version: v1
scope: "v1/wms-api — Outbound-report palletize (ParcelMonitorViewService) vs mobile palletize (MobilePalletizingService); closeBOL order-state finalize"
owner: "Nam Park"
created: 2026-07-01
updated: 2026-07-01
last_verified: 2026-07-01
verified_by: "Nam Park (live wms1-wineco MCP, read-only)"
db_verified: true
ticket: "SBDEV-2507 (ST#1023)"
related:
  - "[[wms1-bol-truck-loading-workflow]]"
  - "[[SBDEV-2099-outbound-parcel-report-clears-after-palletize]]"
  - "[[wms1-state-machine-catalog]]"
tags:
  - investigation
  - report
  - palletizing
  - bol
  - double-ship
  - data-state-mismatch
---

# SBDEV-2507 — Parcel Re-Palletized & Double-Shipped After Closed BOL (Web Palletize Check Gap)

**Topic:** Why the web (Outbound Parcel Report) palletize imposes fewer checks than the mobile flow, and what that caused in production | **Version:** v1/wms-api
**Ticket:** SBDEV-2507 / ST#1023 (WineCo, reported by Michelle Cervone, 2026-06-30)
**Started:** 2026-07-01 | **Investigator:** Nam Park
**Status:** concluded

---

## 1. Context & Trigger

Prior analysis (this session) found that WineCo's two palletizing UIs call **different** API paths with **different validation depth**:
- **Mobile** `/v3/palletizing/*` → `MobilePalletizingService.scanParcel/scanPallet` — a rich series of pre-checks (order ≥ PACKED, not cancelled/finished, shipping-method compatibility, target is a pallet, **pallet not already assigned to gate**).
- **Web** Outbound Parcel Report → `POST /palletize` (`BillOfLadingController:316`) → `ParcelMonitorViewService.palletise()` — a much leaner path (order-not-finished + duplicate-truck-load guard only).

SBDEV-2507 (ST#1023) is the real-world escalation: WineCo reported that order **54068** / parcel **XR1781642381900** on pallet **PM-017012** still appears on the Outbound Report showing state **Palletized**, even though its BOL **OBOL117374** is **CLOSED** (shipped 2026-06-19). This report determines what actually happened and whether the web palletize check gap contributed.

**Primary issue (per operator report):** a user used the **web UI to create another pallet and add it/parcels onto a pallet that was already truck-loaded**. The mobile flow blocks this with `Pallet already assigned to gate!`; the web path has no equivalent guard. This code-level gap is the root cause and is independent of any data state.

**DB verification:** performed live and read-only against `wms1-wineco` (`wh01_om1`); no writes. Records, timeline, and scope queries are quoted inline in §5.

> ⚠️ **Data caveat:** the current DB state may already include **manual fixes** applied by support/ops after the incident. The `unitload_record` timeline (§5.2) and current order state (700) are therefore **indicative, not authoritative** — they corroborate the symptom class but must not be over-read for exact causal ordering. The **code-level check gap (§5.0)** is the robust, fix-independent finding and is the spine of this report. `db_verified: true`.

---

## 2. Questions

1. **(Primary)** Does the web palletize path allow adding to / building onto a pallet that is **already truck-loaded (assigned to a gate/BOL)**, when the mobile path blocks it? What exactly is the missing check?
2. What real-world consequence did that cause — a report-only display glitch, or an actual data/shipment error?
3. Why does the web (Outbound Report) palletize impose fewer checks than mobile — is the leniency intentional?
4. Is this isolated to one order, or systemic across the facility?
5. Where should the fix live?

> Note: an earlier framing of Q2 leaned on the `unitload_record` timeline to reconstruct causal ordering. Per the §1 data caveat, that timeline may reflect post-incident manual fixes, so the analysis below leads with the **code-level check gap** (Q1) and treats the timeline as corroborating, not decisive.

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| **H0 (primary)** | Web `palletise` lets an operator **build onto / reuse a pallet that is already truck-loaded (assigned to a gate/BOL)** — the `Pallet already assigned to gate!` guard the mobile path enforces is absent | **high** | Operator report + code read; fix-independent |
| H1 | Report-only mismatch: the Outbound Report reads palletized state instead of shipped state (the ticket's own guess) | low | Ticket "Initial Impact" framing |
| H2 | `closeBOL` of OBOL117374 failed to transition order 54068 to FINISHED → order stuck at PALLETIZED (670) | medium | Ticket shows "Palletized" 11 days after close — but current state may be post-fix |
| H3 | The lean web palletize path allowed a duplicate/second-pallet association for an already-shipped parcel | medium | Prior check-gap analysis; timeline may be post-fix |
| H4 | Web palletize leniency is intentional (back-office correction tool), but lacks a safety floor | medium | Report-driven, no-scanner path |
| H5 | Systemic — many orders stuck at 670 on closed BOLs | low | Must rule out |
| H6 | Nothing is actually wrong | low | Include per protocol |

---

## 4. Method

- Read the ticket SBDEV-2507 (ClickUp) for the reported symptom and the client's data row.
- Traced the two palletize code paths (prior analysis): `MobilePalletizingService.scanParcel/scanPallet` vs `ParcelMonitorViewService.palletise` (`BillOfLadingController:316`).
- Live read-only DB queries against `wms1-wineco`: resolved the order/parcel/pallet/BOL records; pulled the full `unitload_record` movement history for the parcel; ran two scope queries; confirmed the outbound-pallet label patterns from `los_sysprop`.

State constants (`WmsConstants.State`): `PICKED=600, PACKED=650, PALLETIZED=670, FINISHED=700, CANCELED=800`.

---

## 3.5 Sources In Scope

| Source | Role |
|---|---|
| ClickUp SBDEV-2507 / ST#1023 | Symptom, client data row, closed-BOL screenshot values |
| `service/ParcelMonitorViewService.java:73-164` `palletise()` | Web/report palletize — lean checks (the path under scrutiny) |
| `controller/BillOfLadingController.java:316` `/palletize` | Web endpoint → `parcelMonitorDtoService.palletise(...)` |
| `service/mobile/MobilePalletizingService.java:63-221` | Mobile palletize — full check series (baseline for the gap) |
| `service/BillofladingService.java` `closeBOL`/`closeBOLs` | BOL close → should finalize parcel orders to FINISHED (H2 target) |
| `web-ui components/reports/popups/palletizeOutboundParcel.vue:64` | Only client check: `state >= 670` (already palletized) |
| `los_sysprop` `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` / `STRING_PATTERN_OUTBOUND_PALLET` | Pallet-label provenance (PM- system vs OUT- manual) |
| live `wms1-wineco`: `customerorder`, `unitload`, `billoflading`, `billoflading_position`, `unitload_record` | Records + movement history |

Related prior work: `SBDEV-2099-outbound-parcel-report-clears-after-palletize` (same web palletize path) and this session's palletize check-gap analysis.

---

## 5. Evidence

### 5.0 PRIMARY — web palletize does not reject a pallet already assigned to a gate/BOL (mobile does)

**Source:** `ParcelMonitorViewService.palletise:89-115` vs `MobilePalletizingService.scanPallet:198-201`
**Observation:** In the web/Outbound-Report path, when the supplied pallet name resolves to an **existing** unitload, the code simply reuses it — the "already exists" rejection is *commented out* and there is **no check** that the pallet is already truck-loaded:

```java
// ParcelMonitorViewService.palletise (web) — existing-pallet branch
} else {
    // throw new BusinessException("Pallet with name=" + palletName + " already exists!");
    // Pallet already exist
    pallet = palletOpt.orElseThrow(() -> new NoSuchElementException("No value present"));
}
```

The mobile path, by contrast, explicitly blocks it:

```java
// MobilePalletizingService.scanPallet — existing-pallet branch
List<BillofladingPosition> billOfLadingPosition =
    billofladingPositionRepository.getBySourceUnitLoadLabelId(palletLabel);
if (!billOfLadingPosition.isEmpty()) {
    throw new BusinessException("Pallet already assigned to gate!");   // <-- absent on web
}
```

Neither the web `palletise` nor the client (`palletizeOutboundParcel.vue:64`, which only checks parcel `state >= 670`) runs `getBySourceUnitLoadLabelId` on the target pallet. So an operator can, from the web, **create/select a pallet and add parcels to one that is already assigned to a gate and truck-loaded onto a BOL** — precisely the reported action. This is the root cause, and it does not depend on the current DB state.
**Supports:** H0 (high). **Contradicts:** H1, H6.

### 5.1 The parcel is on a DIFFERENT pallet and a DIFFERENT closed BOL than the client believes

**Source:** live `wms1-wineco`
**Observation:**
- Order (`customerorder`): id `33553408`, `clientordernumber=54068`, `parcel_id=33560700`, `parcelexternalnumber=XR1781642381900`, **`state=700` (FINISHED)** — as of 2026-07-01.
- Parcel unitload `XR1781642381900` (id `33560700`): **`carrierunitload_id=33787042`** — i.e. it is on carrier `33787042` = labelid **`OUT-999093`**, *not* on PM-017012.
- Pallet `PM-017012` (id `33559412`): `carrierunitload_id=NULL`, currently carries **60 parcels**; it is `source_id` of `billoflading_position` `33559560` on BOL **OBOL117374** (`state=CLOSED`, shipped 2026-06-19).
- Carrier `OUT-999093` (id `33787042`): `source_id` of position `33787048` on BOL **OBOL117390** (`state=CLOSED`).

So parcel 54068 currently hangs off `OUT-999093`/`OBOL117390`, while the client references `PM-017012`/`OBOL117374`. Two pallets, two closed BOLs.
**Supports:** H3. **Contradicts:** H1 (not a mere display read), H6.

### 5.2 The `unitload_record` history proves a double-shipment

**Source:** `unitload_record` WHERE `label='XR1781642381900'` OR `ordernumber='060875-000001'`, ordered by `created`
**Observation (abridged):**

| created (UTC) | activitycode | from → to | ordernumber | operator |
|---|---|---|---|---|
| 2026-06-16 16:36 | PACKAGING (CREATED) | — | — | anonymous |
| **2026-06-17 11:18** | **PALLETIZING** | → **PM-017012** | 060875-000001 | **mcervone** |
| **2026-06-19 15:59** | **SHIPPING** | PM-017012 | **OBOL117374** | dwessel |
| **2026-07-01 10:21** | **PALLETIZING** | **PM-017012 → OUT-999093** | 060875-000001 | **bcampbell** |
| 2026-07-01 10:22 | TRUCKLOADING | OUT-999093 | **OBOL117390** | bcampbell |
| 2026-07-01 10:23 | SHIPPING | OUT-999093 | **OBOL117390** | bcampbell |

The parcel was palletized (06-17) and **shipped on closed BOL OBOL117374 (06-19)**. Then on **2026-07-01** it was **re-palletized off the already-shipped pallet PM-017012 onto a new pallet OUT-999093 and shipped a SECOND time on OBOL117390.** This is a genuine **duplicate/erroneous shipment lineage**, not a display bug.

> ⚠️ Per the §1 data caveat, the 07-01 rows may be **manual-remediation activity** rather than the original incident. Treat this as corroboration that the operation *was possible and did occur*, not as a proven unattended causal chain. The fix-independent proof is §5.0.
**Supports:** H3, H0. **Contradicts:** H1, H6.

### 5.3 The order was stuck at PALLETIZED (670) after the first BOL close — which disabled the "already finished" guard

**Source:** ticket (dated 2026-06-30) + §5.2 timeline + state constants
**Observation:** The ticket, filed 2026-06-30 — 11 days after OBOL117374 closed (06-19) — reports the order's "Current displayed state" as **Palletized**. The `SHIPPING` record on OBOL117374 exists (06-19), so the parcel was shipped, yet the `customerorder` was **not advanced to FINISHED (700)** — it remained at **PALLETIZED (670)**. Because the order was at 670 (not ≥ 700), the palletize path's only relevant state guard — `if (customerOrder.getState() >= FINISHED) throw "Order is already finished"` (`ParcelMonitorViewService.java:120-122`) — **did not fire** on 07-01, so the re-palletize/double-ship in §5.2 was not blocked. The order only reached `state=700` via the *second* (erroneous) shipment on OBOL117390.
**Supports:** H2 — corroborated by the contemporaneous ticket (the order displayed as Palletized on 06-30), though the *current* state (700) may be a manual fix, so whether the 670 was a genuine closeBOL finalize miss or a transient mid-remediation state cannot be settled from the snapshot alone. Either way it is **secondary** to H0: even with correct order state, H0's missing guard independently allows building onto an already-truck-loaded pallet.

### 5.4 The web palletize path is missing the guards the mobile path has

**Source:** `ParcelMonitorViewService.palletise:73-164` vs `MobilePalletizingService.scanParcel/scanPallet:63-221`
**Observation:** the web `palletise` enforces only: pallet-name format (manual), order-not-FINISHED (`≥700`), duplicate-truck-load, and removes a stale BOL position. It does **not** check: order ≥ PACKED; shipping-method/carrier compatibility; target is actually a pallet type; **pallet not already assigned to a gate/BOL**. The mobile flow enforces all of these (`:86,:128,:148-169,:194,:198-201`). **Crucially, neither path rejects a parcel that is already loaded/shipped on a CLOSED BOL** — the exact condition in §5.2. The web client (`palletizeOutboundParcel.vue:64`) only blocks `state ≥ 670`, which the stuck-at-670 order (§5.3) sat exactly on the boundary of.
**Supports:** H3, H4.

### 5.5 Pallet-label provenance: PM- = system-generated, OUT- = manually entered

**Source:** `los_sysprop`
**Observation:** `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL = 'PM-%1$06d'` (system-generated labels, e.g. `PM-017012`); `STRING_PATTERN_OUTBOUND_PALLET = 'OUT-\d{6}|TESTPALLET-\d{4}'` (accepted manual/scanned labels, e.g. `OUT-999093`). So the second pallet `OUT-999093` was created by a caller **supplying an explicit pallet name** (web `palletise` with `palletName='OUT-999093'`, or a mobile scan of that label) — a deliberate manual action, consistent with a back-office correction attempt.
**Supports:** H4 (the second palletize was an operator-driven action with a hand-supplied label).

### 5.6 Scope: isolated, not a live systemic backlog

**Source:** two live scope queries
**Observation:**
- The 60 other parcels currently on `PM-017012` are **all `state=700`** — they finished correctly at the same BOL close. Only order 54068 diverged.
- Facility-wide: `customerorder.state=670` whose parcel's carrier pallet is a `source` on a `CLOSED` BOL → **0 rows**. No other order is currently stuck the same way.

So the closeBOL finalize miss (H2) is **rare/intermittent**, and the one known instance "self-resolved" to 700 only via the erroneous double-ship. **Contradicts H5.** (Note: the query captures the *current* snapshot; a transient window like 06-19→07-01 for order 54068 would not be counted today.)
**Supports:** refutes H5; keeps H2 as a rare race rather than a broad defect.

### 5.7 Why the web path is intentionally lean (answers Q3)

**Source:** code + workflow (`wms1-bol-truck-loading-workflow §4`) + UI context
**Observation:** the mobile flow is a **floor scanning** process — it can enforce shipping-method compatibility (needs a scanned pallet carrying a shipping method), PACKED confirmation, and gate assignment because those artifacts are present at scan time. The web **Outbound Parcel Report → Palletize** is a **back-office bulk/correction** tool operating on report rows without a physical scan, so several floor-scan checks are structurally omitted **by design**. That rationale is legitimate — but "fewer floor-scan checks" was over-applied to also drop the **safety-floor** guard (do not palletize a parcel already shipped on a closed BOL), which is exactly what let the double-ship happen.
**Supports:** H4 (intentional leniency) — while establishing the leniency lacks a necessary floor.

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| **H0 (primary)** | Web palletize lacks the `Pallet already assigned to gate!` guard → operator can build onto an already-truck-loaded pallet | **high** | §5.0 (code, fix-independent) |
| H4 | Web leniency is intentional (no-scanner correction tool) but lacks this safety floor | **high** | §5.0, §5.4, §5.7 |
| H3 | The gap produced a duplicate/erroneous shipment lineage for parcel 54068 | **medium-high** (occurred; timeline possibly post-fix) | §5.1, §5.2 |
| H2 | closeBOL(OBOL117374) left order at 670 | **medium** (corroborated by ticket; current state may be manual fix) | §5.3, §5.6 |
| H1 | Report-only display mismatch | **rejected** | §5.0, §5.2 |
| H5 | Systemic backlog of stuck orders | **rejected (currently)** | §5.6 (0 rows) |
| H6 | Nothing wrong | **rejected** | §5.0, §5.2 |

---

## 7. Verdict

SBDEV-2507 is **not** a report-only display glitch. The **root cause is a code-level check gap (§5.0)**: the web (Outbound Parcel Report) palletize path — `ParcelMonitorViewService.palletise` — lets an operator **create/reuse a pallet and add parcels to one that is already assigned to a gate and truck-loaded onto a BOL**. The mobile flow blocks exactly this with `Pallet already assigned to gate!` (`MobilePalletizingService:198-201`); the web path never checks it (the "already exists" rejection is commented out, `:110-114`). This is what the operator did, and the finding does **not** depend on the current data.

The web path's reduced checking is *partly* by design — it is a no-scanner back-office correction tool, so several floor-scan validations are legitimately omitted (§5.7) — but that design dropped a **safety floor** (do not build onto an already-truck-loaded pallet) that must hold regardless of channel.

The observed data (parcel 54068 associated with two pallets on two closed BOLs; order momentarily at PALLETIZED per the 06-30 ticket) is **consistent** with this gap and shows the operation did occur, but the **current DB state may reflect manual remediation** (§1 caveat), so it is treated as corroboration rather than an authoritative unattended timeline. A possible secondary contributor — a `closeBOL` finalize miss that left the order at 670 — is plausible but cannot be confirmed from the post-hoc snapshot; it is not required to explain the incident, since H0's missing guard is sufficient on its own.

**Confidence:** high for the root cause (H0) — it is a direct code read, independent of data state. Medium for the exact production sequence (the timeline may be partly manual-fix activity).

---

## 8. Recommendation

- [x] **Fix now** — draft via `wms-bugfix-plan` (v1/wms-api). Ship `sbdocs/9-System/scripts/verify-<plan-id>.sh` per that skill.

Primary fix + supporting work:

1. **Add the "pallet already assigned to a gate/BOL" guard to the web palletize path (root-cause fix, highest priority).** In `ParcelMonitorViewService.palletise`, when the target pallet already exists, reject it if it has any `billoflading_position` (mirror `MobilePalletizingService.scanPallet:198-201` — `getBySourceUnitLoadLabelId(palletLabel)` non-empty → `Pallet already assigned to gate!`). Best done as a **shared server-side helper** (e.g. `assertPalletNotTruckLoaded(pallet)` / `assertParcelPalletizable(...)`) called by **both** `ParcelMonitorViewService` and `MobilePalletizingService`, so the two paths cannot drift again. Also un-comment / restore the target-pallet safety checks (the "already exists" branch at `:110-114`).
2. **(Secondary, verify first) closeBOL finalize:** confirm whether a stuck-at-670 order state is a real defect before fixing — if reproducible, ensure `BillofladingService.closeBOL/closeBOLs` reliably advances every shipped parcel's `customerorder` to FINISHED (700); check for a swallowed `ObjectOptimisticLockingFailureException` / an order skipped in the bulk close (a matching swallow exists in `MobilePalletizingService:209-213`). Gate this on reproduction, since the current data may be post-fix.
3. **Data remediation (ops):** reconcile order 54068 / parcel `XR1781642381900` (associated with two closed BOLs, OBOL117374 & OBOL117390) with WineCo — determine the authoritative shipment, correct inventory/billing/manifest, void the erroneous one, and confirm no duplicate OMS ship-notification fired.
4. **Consider** porting the other mobile checks (shipping-method compatibility, PACKED, pallet-type) to the web path where they fit a bulk/no-scanner tool — lower priority than #1.

The downstream `wms-bugfix-plan` MUST ship a `verify-<plan-id>.sh`.

---

## 9. Open Questions

- **Original incident state (data may be post-fix):** the current DB likely includes manual remediation. Confirm the *original* state from the support thread (ST#1023), app/audit logs, or DB backups before treating the §5.2 timeline or the stuck-670 state as authoritative. The root-cause finding (§5.0) does not depend on this, but the exact production sequence does.
- **Root cause of the closeBOL finalize miss (only if it's a real bug):** why would order 54068 alone (of 61 on PM-017012) not reach FINISHED on 06-19? Optimistic-lock swallow, ordering/race in the 335-position bulk close, or a state precondition? Needs a `closeBOL` code read + ideally a repro. Determines the exact fix for workstream #2.
- **Operator intent on 07-01:** was `bcampbell`'s re-palletize a deliberate correction attempt after the 06-30 ticket? If so, the support runbook also needs a "do not re-palletize a shipped parcel" note. (Cannot be proven from data.)
- **OMS/ERP impact:** did the second shipment (OBOL117390) send a duplicate ship notification to OMS? Cross-system reconciliation needed.
- **Historical prevalence:** the scope query is a current snapshot (0 stuck now). A history/audit scan (parcels with ≥2 SHIPPING `unitload_record` rows on distinct BOLs) would quantify how many parcels were ever double-shipped this way.

---

## 10. References

- **Ticket:** SBDEV-2507 / ST#1023 — https://app.clickup.com/t/868k7cq35
- **Prior analysis (this session):** mobile vs web palletize check comparison
- **Related plans:** `[[SBDEV-2099-outbound-parcel-report-clears-after-palletize]]` (same web palletize path)
- **Workflow:** `[[wms1-bol-truck-loading-workflow]]` §4 (palletizing), BOL close
- **Code:** `service/ParcelMonitorViewService.java:73-164`, `controller/BillOfLadingController.java:316`, `service/mobile/MobilePalletizingService.java:63-221`, `service/BillofladingService.java` (closeBOL), `web-ui .../palletizeOutboundParcel.vue:64`
- **Downstream plan:** _to be created via `wms-bugfix-plan` — link here once drafted (must ship `verify-<plan-id>.sh`)._
- **Queries/records preserved:** order `33553408`, parcel `33560700`, pallets `PM-017012`=`33559412` / `OUT-999093`=`33787042`, BOLs `OBOL117374`=`33554820` / `OBOL117390`=`33787045`; `unitload_record` timeline §5.2. All from live `wms1-wineco`, read-only, 2026-07-01.

---

## 11. Verification Log

| Date | Who | Check | Result |
|---|---|---|---|
| 2026-07-01 | Nam Park | Live read-only `wms1-wineco`: resolved order/parcel/pallet/BOL, pulled `unitload_record` timeline, ran scope queries, confirmed label patterns | Double-ship confirmed (§5.2); stuck-670 corroborated (§5.3); isolated (§5.6). No writes. |
