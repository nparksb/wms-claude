---
name: sbdev-2956-2960-putaway-ui-children
description: "SBDEV-2956/2960 (children of SBDEV-2643) triaged T2 each; 2956 MERGED 2026-08-26; re-triage puts 9 of 2960's 15 ACs already met, and its AC11/AC12 name a tenant tier that does not exist"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15746052-ae44-4afd-b8c8-c905718fbdb5
  modified: 2026-08-26T00:36:00.162Z
---

Triaged 2026-08-25. Both are UI polish on **working** machinery — SBDEV-2643 shipped and
`putaway_config_audit` on `dev_wh01_om1` shows set / clear / re-set all succeeding with
`changed_by` recorded. Neither is a functional bug. **T2 each**, no plan document.

**SBDEV-2956 — the ticket's stated cause is wrong.** It claims Default Putaway Location "is not
presented as a normal field." The label mapping *does* exist (`skuData.vue:150`). The field is
invisible because `ItemdataService.java:172` wraps **both** `details.put` calls in
`if (i.getPutawaylocationId() != null)`, and `fullDetails.vue` renders `v-for` over the details
object — **an absent key renders no row**. Measured: 8,805 SKUs, **2** with an override → invisible
for 99.98%. Fix the display half by calling the existing ungated
`GET /v3/itemData/{id}/effectivePutawayDestination`, **not** by widening the projection: the
id-with/without-name asymmetry is a deliberate contract (SBDEV-2643 AC8 — "configured but the
location is gone") and widening it collapses that state.

**Requirement neither ticket states:** `PutawayDestinationResolver` has a pick-face→lane diversion
gate, so *configured* ≠ *where stock lands*. A field showing only the resolved name reads `ICEPACK`
for a SKU whose receipts actually land on `PutAwayLane`. The field must render the diversion state.

**SBDEV-2960 — re-triaged 2026-08-26 against `origin/develop` @685546d: 9 of 15 ACs MET, 4 PARTIAL,
1 NOT MET, 1 unverifiable by code.** Tier still T2. The first pass said "4 of 15"; that under-counted
what 2643-B2/2732/2947 had shipped, and 2956's `effectivePutawayRow.vue` then carried AC9+AC12.
Real remaining work: AC1 (title lacks the word "Edit"), AC2 (subtitle is a `||` fallback chain, and
the two callers pass DIFFERENT shapes — the row pencil's payload has no `itemNr`), AC5, AC15's
search row. **AC11/AC12 name a `tenant` tier that DOES NOT EXIST**: `PutawayScope` is
`{SKU, MERCHANT, WAREHOUSE}` and `PutawayDestinationResolver:27` says SKU → merchant → warehouse
sysprop → `PutAwayLane` **by name**; `putaway_config_audit` is 8,806 rows, all `scope=SKU`. The
code's toast is already right. Original triage note follows — **4 of 15 ACs were already met**: clear/X (picker is `clearable`; clearing **omits**
`locationId`, sending `null` is a 400), palletizing/shipped exclusion (both sit in area `Outbound`
with `useforgoodsin=false, useforstorage=false` → already rejected `AREA_NOT_USABLE`), capability-
not-name-based eligibility (the only by-name exclusion is `PutAwayLane` itself; `WmsConstants
.STORAGE_LOCATION_PALLETISING` has zero readers in `src/main`), and pick/storage inclusion.
**Type-ahead is half-built**: `GET /v3/putawayConfig/eligibleLocations` already accepts `name`
(SBDEV-2643 Phase A4, `PutawayDestinationQueryService:297`) and **no UI caller passes it** — the store
builds only `scope`/`page`/`size`/`subjectId` (`store/admin/configuration.js:536-539`).
⚠ **CORRECTION to "looks like type-ahead and isn't":** the store accumulates EVERY page, so Vuetify's
default substring filter does see the full set and filtering is functionally correct. The defect is
**latency, not function** — 2,568 stock-capable of 2,747 locations on wineco-dev = 13-14 sequential
GETs before the dialog is usable ("seconds, not milliseconds",
`defaultPutawayLocationField.vue:513`). Wiring `name` will NOT break the eligible-count banner:
`captureCounts()` latches the first unfiltered payload only.

**Division that works**: split by *surface*, not by the tickets' "field vs modal" wording — the
shared `defaultPutawayLocationField` → `LocationPicker` stack sits under both. 2956 owns
`skuData.vue` + `fullDetails.vue`; 2960 owns `editSkuPutawayDialog.vue` +
`defaultPutawayLocationField.vue` + `LocationPicker.vue` + `store/admin/configuration.js`.
File-disjoint → parallel PRs. Rebase 2960 on [[wms2-sku-putaway-picker-shared-across-three-scopes]]
work (SBDEV-2947, merged 2026-08-15).

**Two conflicts raised, not resolved**: 2960's copy-reduction AC would strip a safety banner
deliberately mirrored from `messages.properties` and pinned by 4 Jest tests; and 2960 says "revert
to the tenant default" when the chain is four tiers (SKU → merchant/shipper → warehouse **sysprop**
→ `PutAwayLane` by name) with no tenant record at all. See
[[wms2-putaway-config-is-sb-admin-only]].
