---
id: "wms-testing-smoke-test-checklist"
title: "Smoke Test Checklist"
description: "Testing OMS WMS"
category_id: "wms-testing"
---

# Smoke Test Checklist

## Scenario 1: Regular Pick & Pack Order (OMS → WMS → WMS Mobile → Ship)

### OMS — Order Creation
- [ ] Upload an order file (format 209) via `uploadClientFileAction` in OMS 
-
  > **How:** In OMS, go to the main **Orders** dashboard. Click the **"Upload Order Group"** (or **"Upload Orders"** in Shipper view) button in the top-right toolbar. A modal appears with a drag-and-drop dropzone. Drop or browse for a valid `.xls`, `.xlsx`, `.odt`, or `.csv` file. Click **Upload**. Wait for the success alert: *"Client orders file uploaded successfully"*.
  
- [ ] Verify order appears with status **NEW (1)**
-
  > **How:** After upload, the new Order Group should appear in the **filesData** table on the Orders dashboard. Click the row to expand — individual orders inside should show status **New**.

- [ ] Cron job runs address validation → order moves to **READY (2)** (or to an exception status if address/inventory fails)
-
  > **How:** The cron runs automatically on a schedule. Wait a minute or two, then refresh the Orders dashboard. The order status cards at the top will update counts. Orders should move from **New** to **Ready** (or to **Exception** if there's a problem).

- [ ] Resolve any exceptions (address, inventory, fulfillment) if present
-
  > **How:** Click the **Exception** status card/tab on the Orders dashboard. The exception list shows orders grouped by type (Address, Inventory, Cubing, Special). Click an order row to expand the exception detail panel. For **Address** exceptions: correct the address fields and click **Reprocess**. For **Inventory** exceptions: replace the SKU or adjust quantities. Click **Reprocess** — the order will re-enter the cron cycle.

- [ ] Verify order batched correctly (batch label generated per shipper)
-
  > **How:** Navigate to the **Ready** tab. You can toggle between "View by Group" and "View by Shipper" using the tabs. In the Ready view, select parcels using checkboxes, choose a **Pack Type** (Pick Pack / Club / Transfer) and **Priority**, then click **"Submit Batch"**. A confirmation popup shows the batch ID, parcel count, fulfillment types, and carrier methods. Click **Submit Batch** to send.

### OMS → WMS Handoff
- [ ] Order batch sent to WMS REST API (`API_ORDER_CREATE_URL`)
-
  > **How:** This happens automatically when you submit the batch above. The OMS calls `batchToWMS` which sends the parcels to the WMS REST API. Check the browser console or OMS logs for confirmation.

- [ ] Verify `CustomerorderBatch` created in WMS with `type = PICK_PACK`, `state = RAW (0)`
-
  > **How:** In WMS Web UI, go to **Outbound → Pick Pack** (`/outbound/pick-pack`). The batch should appear in the **Open Parcels** tab. Alternatively, check the WMS database `customerorder_batch` table.

- [ ] Verify `Customerorder` and `CustomerorderPosition` records exist
-
  > **How:** Click the batch row in WMS Pick Pack to view details. Individual customer orders and their line items (positions) should be listed.

### WMS — Order Release & Picking Order Creation
- [ ] `ReleaseOrderJobService` runs → creates `Pickingorder` with `state = PROCESSABLE (300)`
-
  > **How:** This runs automatically via a scheduled job. In WMS Web UI, go to **Dashboard** (`/dashboard`) and select **"Pick Pack Monitor"** from the dropdown. Released orders will appear here. Alternatively, wait ~1 minute and check back.

- [ ] Picking positions created, stock reserved (`changeReservedAmount`)
-
  > **How:** In WMS Web UI, go to **Handling Units → Stock Units** (`/handlingUnits/handling-units`, select "Stock Units"). Search for the SKU — the **Reserved** column should show an increased amount.

- [ ] Customer order state → **ASSIGNED**
-
  > **How:** Verify in the Pick Pack Monitor dashboard or by checking the batch details in Outbound → Pick Pack.

- [ ] WMS sends "released for picking" message back to OMS
-
  > **How:** Check the WMS `message` table in the database for a recent outgoing message with the batch/order reference. The message type should indicate picking release.

- [ ] OMS order status → **READY_TO_PICK (23)**
-
  > **How:** In OMS, go to the order group → click the **WMS** tab. The batch table should show the batch with updated status. Individual order statuses in the main view should show "Ready to Pick".

### WMS Mobile — Picking (Tote-based)
- [ ] On mobile, scan/select picking **section**
-
  > **How:** Open the WMS Mobile app. From the home screen, tap **"Picking"**. The first screen ("Scan Section") shows a scan input field. Scan or type a picking section name/barcode and press Enter.

- [ ] Verify picking type = `Tote` → picking orders list shown
-
  > **How:** After scanning the section, if the section is configured for Tote picking, a list of available picking orders appears. Each row shows the picking order number, SKU count, and priority.

- [ ] Select picking order → state → **RESERVED (400)** → **STARTED (500)**
-
  > **How:** Tap a picking order row to select it. The order is now reserved to you and the picking screen loads showing the first position to pick.

- [ ] For each position: scan **location**, verify it matches expected location
-
  > **How:** The pick screen shows the expected location name and SKU. Scan the location barcode. If it matches, the screen advances. If it doesn't match, an error message appears.

- [ ] Scan **tote** label → `processPick` runs, stock transfers to tote
-
  > **How:** After confirming the location, scan the tote barcode (or enter the tote label). The pick is processed — stock transfers from the source location to the tote. The screen advances to the next position.

- [ ] All positions picked → picking order state → **PICKED (600)**
-
  > **How:** Repeat location scan → tote scan for each position. After the last position, a success message appears and the picking order is complete.

- [ ] WMS sends "picking started" and "picking finished" messages to OMS
-
  > **How:** These messages are sent automatically. Verify in the WMS `message` table or check OMS order status update.

- [ ] OMS order status → **PICKING (24)**
-
  > **How:** In OMS, refresh the order view. The status should now show "Picking".

### WMS — Packaging
- [ ] `packageOrder` runs → stock transfers from tote to package unit load
-
  > **How:** This runs automatically after picking is complete. The system transfers stock from the tote to the final parcel/package unit load.

- [ ] Customer order state → **PACKED (650)**
-
  > **How:** In WMS Web UI, check the Pick Pack Monitor on the Dashboard or the batch details under Outbound → Pick Pack. The order state should show as Packed.

- [ ] Tote returned to empty totes location
-
  > **How:** The tote is automatically cleared and returned to the empty totes pool. Verify via Handling Units search if needed.

- [ ] WMS sends "packed" message to OMS
-
  > **How:** Check the WMS `message` table for the packed status message.

### WMS — BOL & Shipping
- [ ] Create outbound BOL (name, courier, truck, seal number) → state = **OPEN**
-
  > **How:** In WMS Web UI, go to **Outbound → Outbound BOL** (`/outbound/outbound-bol`). On the **"Open Outbound BOLs"** tab, click **"Create Outbound BOL"** button. Fill in the form: Type, Destination, BOL Name, Dock/Gate, Carrier, Truck Number, Seal Number. Click **Create**. A success toast confirms: *"Outbound BOL created"*.

- [ ] Assign parcels/pallets to BOL
-
  > **How:** Click the newly created BOL row to open its detail page. Use the **Truck Loading** feature on WMS Mobile (home → **"Truck Loading"**) to scan parcels/pallets and assign them to the BOL. Alternatively, assign via the BOL detail table in the web UI.

- [ ] Close BOL → `closeBOL` runs → state = **CLOSED**
-
  > **How:** On the BOL detail page, click the **"Close BOL"** button. A confirmation dialog appears listing the BOL number. Click **"Acknowledge"** to confirm. The BOL moves to the **"Closed Outbound BOLs"** tab.

- [ ] Stock moved to "Shipped" location, entity lock → SHIPPED
-
  > **How:** Verify in Handling Units → Stock Units that the stock associated with the shipped parcels now has entity lock = SHIPPED (405).

- [ ] WMS sends `ORDER_BATCH_SHIPPED` message to OMS
-
  > **How:** Check the WMS `message` table for the shipped message.

- [ ] OMS order status → **SHIPPED (4)**
-
  > **How:** In OMS, go to the order group → **Shipped** tab. The parcels should appear with Ship Date, Carrier, and Tracking # columns populated.

### OMS — Post-Ship Tracking
- [ ] Order tracking cron picks up SHIPPED parcels
-
  > **How:** The tracking cron runs automatically. Wait for the scheduled interval, then check the OMS Shipped tab for tracking updates.

- [ ] Tracking updates: ON_TRANSPORT → IN_TRANSIT → OUT_FOR_DELIVERY → **DELIVERED (18)**
-
  > **How:** In OMS, click a shipped parcel to view its tracking history. Status progression should update as carrier tracking info comes in. Final status = **Delivered**.

---

## Scenario 2: Club Line Order

### OMS → WMS
- [ ] Club batch submitted to WMS
-
  > **How:** In OMS, go to the **Ready** tab. Switch to "View by Shipper" if needed. Select the parcels for the club order, set **Pack Type** to **"Club"** using the dropdown, and click **"Submit Batch"**. Confirm in the popup.

- [ ] `CustomerorderBatch` created with `type = CLUB`, `state = RAW (0)`
-
  > **How:** In WMS Web UI, go to **Outbound → Club** (`/outbound/club`). The batch should appear in the **Open** tab with type = Club.

### WMS Web UI — Staging & Activation
- [ ] Assign **staging lane** to batch → state → **ORDER_BATCH_STAGING_LANE_ASSIGNED (525)**
-
  > **How:** In WMS Web UI, go to **Outbound → Club** (`/outbound/club`). Click the batch row to open details. Use the staging lane assignment control to select an available staging lane location.

- [ ] Verify stock on staging lane is sufficient
-
  > **How:** Check the batch detail view — it should show the required SKUs and quantities vs. what is available on the assigned staging lane.

- [ ] **Activate** batch → state → **ORDER_BATCH_ACTIVATED (520)**
-
  > **How:** On the batch detail page, click the **"Activate"** button. This starts the club line process.

### WMS — Club Line Run
- [ ] Run club line (`runClubLine`) → parcels created, stock transferred from staging lane to parcels
-
  > **How:** In WMS Web UI, go to **Processes → Club Run** (`/processes/club-run`). The activated batch appears in the **Active Club Runs** table. Click the batch row or the eye icon to open the fulfillment details. Click **"Run Club Line"** to execute. Alternatively, click **"View Outbound Club Batches"** to go back to the outbound club page.

- [ ] All customer orders → **PACKED (650)**
-
  > **How:** After the club run completes, verify in the club run detail view that all customer orders show state = Packed.

- [ ] Batch → **ORDER_BATCH_CLUB_RUN_FINISHED (530)**
-
  > **How:** The batch state updates automatically. Refresh the Active Club Runs page to confirm.

- [ ] WMS sends picking released/started/finished messages to OMS (all at once)
-
  > **How:** These messages are sent automatically as part of the club run. Check the WMS `message` table or verify in OMS that order statuses have updated.

### WMS — BOL & Ship _(same as Scenario 1)_
- [ ] Create BOL, assign parcels, close BOL
-
  > **How:** Follow the same BOL steps as Scenario 1: go to **Outbound → Outbound BOL**, click **"Create Outbound BOL"**, fill in details, assign parcels, then close.

- [ ] Batch → **FINISHED (700)**
-
  > **How:** After BOL is closed, the batch state updates to Finished. Verify in the Outbound → Club **Closed** tab.

- [ ] OMS order status → SHIPPED → DELIVERED
-
  > **How:** In OMS, check the order group → Shipped tab. Tracking updates will follow via the tracking cron.

---

## Scenario 3: Transfer Offsite Order

### WMS Web UI
- [ ] `CustomerorderBatch` with `type = TRANSFER_OFFSITE`
-
  > **How:** In OMS, submit a batch with **Pack Type** set to **"Transfer"**. In WMS Web UI, go to **Outbound → Transfer** (`/outbound/transfer`). The batch should appear in the Open tab.

- [ ] Assign **transfer lane** → order state → **CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED (510)**
-
  > **How:** Click the transfer batch row to open details. Select an available transfer lane location from the assignment control.

- [ ] **Activate** transfer order → state → **CUSTOMER_ORDER_ACTIVATED (505)**
-
  > **How:** On the transfer batch detail page, click the **"Activate"** button.

- [ ] Verify stock on transfer lane
-
  > **How:** Check the transfer detail view for SKU quantities vs. available stock on the assigned lane.

- [ ] Run transfer → `billofladingService.transferOrder()`
-
  > **How:** In WMS Web UI, go to **Processes → Transfer Picking** (`/processes/transfer-picking`). The activated transfer appears in the **Active Transfer Orders** table. Click the row to open the fulfillment detail page. Run the transfer process from there.

- [ ] Create & close BOL → parcels shipped
-
  > **How:** Follow the same BOL steps as Scenario 1: create BOL at **Outbound → Outbound BOL**, assign parcels, close BOL.

---

## Scenario 4: Transfer Intracompany

- [ ] Same as Transfer Offsite, but BOL state → **TRANSFER** (not CLOSED)
-
  > **How:** Follow the same steps as Scenario 3 (Transfer Offsite). The difference is that when the BOL is closed for an intracompany transfer, the system sets the state to TRANSFER instead of CLOSED, allowing the receiving warehouse to accept the shipment.

- [ ] Entity lock → **TRANSFER** (not SHIPPED)
-
  > **How:** Verify in WMS **Handling Units → Stock Units** that the transferred stock has entity lock = 404 (TRANSFER) instead of 405 (SHIPPED).

- [ ] Receiving warehouse can receive the transfer
-
  > **How:** At the receiving warehouse's WMS instance, the transfer should appear as an inbound notice. Follow the Receiving flow (Scenario 6) to receive the transferred goods.

---

## Scenario 5: Hub & Spoke (Cross-Docking)

### WMS — Inbound triggers Outbound
- [ ] Inbound advice created with `type = HUB_AND_SPOKE`
-
  > **How:** The inbound advice is created with type Hub & Spoke (either via OMS or manually). Go to WMS Web UI **Receiving → Inbound Notices** (`/receiving/inbound-notices?tab=open`). The notice should appear with the Hub & Spoke type.

- [ ] On receiving, `CustomerorderBatch` auto-created with `type = HUB_AND_SPOKE`, `state = STARTED`
-
  > **How:** When the inbound product is received (following the Receiving flow in Scenario 6), the system automatically creates an outbound customer order batch. Check **Outbound → Pick Pack** or the database for the auto-created batch.

- [ ] Customer orders and parcels created immediately
-
  > **How:** Unlike normal pick-pack, parcels are created immediately upon receiving. Verify in the batch detail view that customer orders and parcels exist.

- [ ] Cross-docking lanes assigned
-
  > **How:** The system assigns cross-docking lanes automatically. Verify the lane assignment in the batch/order detail view.

- [ ] BOL created, closed, shipped
-
  > **How:** Follow the standard BOL process: **Outbound → Outbound BOL** → create, assign, close.

---

## Scenario 6: Inbound / Receiving

### WMS Web UI
- [ ] Verify inbound advice (open notices) appear in receiving list
-
  > **How:** In WMS Web UI, go to **Receiving → Inbound Notices** (`/receiving/inbound-notices?tab=open`). The **"Inbound Open Notices"** tab shows all active inbound advices. Verify your expected notice appears in the table.

- [ ] Open advice → view positions (SKUs, expected amounts)
-
  > **How:** Click a notice row to open the detail page (`/receiving/openNotice/{id}`). The detail page shows the notice description (number, client, dates) and a table of positions listing each SKU, expected amounts, and received amounts so far.

### WMS Mobile or Web — Receive
- [ ] Select advice position
-
  > **How:** On the inbound notice detail page, find the SKU row you want to receive. Click the **"Receive"** button/link on that row. This navigates to the receiving form (`/receiving/openNotice/receive?...`).

- [ ] Scan/select pallet or cart (verify label pattern)
-
  > **How:** On the receiving form, scan the pallet or cart barcode (or type it manually). The system validates the unit load label format.

- [ ] Enter amounts (bottles, cases, bottles per case)
-
  > **How:** Fill in the quantity fields on the receiving form: number of cases, bottles per case, and/or total bottles. The form calculates the total automatically.

- [ ] Select box type and printer
-
  > **How:** Select the appropriate **Box Type** from the dropdown. Choose a **Printer** for case label printing from the available printers list.

- [ ] Submit receive → stock units created, transferred to put-away location (or carrier)
-
  > **How:** Click **Submit** on the receiving form. The system creates stock units, assigns them to the scanned pallet/cart, and transfers to the receiving location. A success message appears.

- [ ] Case labels printed
-
  > **How:** After submit, case labels are automatically sent to the selected printer. Verify labels print correctly at the physical printer.

- [ ] Stock change message sent to OMS
-
  > **How:** The WMS automatically sends a stock change message to OMS. Check the WMS `message` table or verify in OMS that inventory counts have updated.

- [ ] Advice position quantities update
-
  > **How:** Go back to the inbound notice detail page. The received quantities on the position row should reflect the just-received amounts.

### WMS Mobile — Put Away
- [ ] Scan pallet label
-
  > **How:** On WMS Mobile, tap **"Putaway"** from the home screen. The first screen ("Scan Pallet") shows a scan input. Scan the pallet barcode. The system loads the pallet's contents showing items, quantities, and suggested put-away locations.

- [ ] Scan destination location (flow bin, rack, etc.)
-
  > **How:** Depending on the contents, you may be prompted to choose between replenish (flow bin) or store (pallet/rack). For flow bins: scan the flow bin barcode on the **"Scan Flow Bin"** screen. For pallet storage: scan the rack/storage location barcode on the **"Store Pallet"** screen. For boxes: scan the box location on the **"Store Box"** screen.

- [ ] Verify `transferUnitLoadToLocation` succeeds
-
  > **How:** After scanning the destination, a success confirmation appears. If the location is invalid or occupied, an error message displays.

- [ ] Stock available for picking
-
  > **How:** Verify via WMS Mobile **"Lookup"** — scan the SKU or location to confirm stock is now available. Or check WMS Web UI → **Handling Units** for the SKU.

---

## Scenario 7: Replenishment

- [ ] `ReplenishOrderJob` runs → generates replenish orders for items below threshold
-
  > **How:** The replenish job runs on a schedule automatically. In WMS Web UI, go to **Dashboard** (`/dashboard`) and select **"Replenishment Monitor"** from the dropdown. Pending replenish orders appear here. Alternatively, on WMS Mobile tap **"Replenish Process"** to see available orders.

- [ ] Replenish order state = **PROCESSABLE**
-
  > **How:** Verify in the Replenishment Monitor that orders show as processable/available.

- [ ] On mobile: pick from source location, transfer stock to fixed assignment location
-
  > **How:** On WMS Mobile, tap **"Replenish Process"** from the home screen. Select a replenish order from the list. The screen shows the source location, SKU, and quantity to pick. Go to the source location, scan the location barcode, confirm the quantity, then scan the destination (flow bin) location. Alternatively, use **"Replenish Request"** to create an ad-hoc replenishment — scan the low-stock flow bin location, enter the desired amount, and submit.

- [ ] Replenish order → **FINISHED (700)**
-
  > **How:** After completing the transfer, the replenish order state updates to Finished. Verify in the Replenishment Monitor.

- [ ] Flow bins refilled → picking can continue
-
  > **How:** Use WMS Mobile **"Lookup"** to scan the flow bin location and confirm the stock level has increased. Picking orders that were waiting on stock should now be processable.

---

## Scenario 8: Cycle Count

- [ ] Create cycle count (by SKU set and/or area)
-
  > **How:** On WMS Mobile, tap **"Cycle Count"** from the home screen. Two tabs are available: **"Count Parcel"** (by SKU/order) and **"Quick Adjustment"**. For Count Parcel: select a cycle count order from the list on the **"Select Order"** screen.

- [ ] Positions created with state = **CREATED**
-
  > **How:** The cycle count order contains positions for each location/SKU to count. They start in CREATED state and appear in the order's position list.

- [ ] Count positions → enter actual amounts
-
  > **How:** After selecting an order, the **"Select Location"** screen appears. Scan the location barcode. Then on the **"Scan Unit Load"** screen, scan the unit load at that location. The **"Count"** screen appears — enter the actual counted quantity for each stock unit. Submit the count.

- [ ] Positions → **FINISHED**
-
  > **How:** After submitting counts, positions move to FINISHED. If counts don't match expected amounts, a **"Recount"** screen may appear asking you to count again for verification.

- [ ] Discrepancies trigger stock adjustments + messages to OMS
-
  > **How:** When counts differ from system amounts, the WMS automatically creates stock adjustments and sends stock change messages to OMS. Verify in OMS inventory that the corrected amounts are reflected. For **Quick Adjustment**: use the second tab — scan a unit load directly, enter the actual count, and submit without needing a pre-created cycle count order.

---

## Scenario 9: Inventory Management

- [ ] **Adjust quantity** — change stock unit amount, verify stock change message sent to OMS
-
  > **How:** In WMS Web UI, go to **Handling Units** (`/handlingUnits/handling-units`). Select **"Stock Units"** from the "View by" dropdown. Search for the SKU. Click the **actions menu** (three dots or action buttons) on the stock unit row and select **"Adjust Amount"**. In the popup, enter the new amount and a comment explaining the reason. Click **Submit**. A stock change message is sent to OMS automatically.

- [ ] **Put on hold** — stock moves to on-hold location, entity lock = ON_HOLD
-
  > **How:** In the Stock Units table, select the stock unit row. Click the **lock/hold action** button. In the confirmation dialog, confirm the hold action. The entity lock changes to ON_HOLD (104) and the stock is no longer available for picking.

- [ ] **Release hold** — stock returns, entity lock cleared
-
  > **How:** Find the on-hold stock unit (filter by entity lock if available). Click the **unlock/release** action button. Confirm the release. Entity lock returns to 0 (NOT_LOCKED) and the stock becomes available again.

- [ ] **Quality fault** — stock marked as damaged
-
  > **How:** In the Stock Units table, select the stock unit. Click **"Transfer to Damaged"** from the actions. Confirm in the popup. The entity lock changes to QUALITY_FAULT (103) and stock is moved to the damaged/quarantine area.

---

## Scenario 10: Rapid Picking (WMS Mobile)

- [ ] On mobile, scan section → picking type = `Rapid`
-
  > **How:** On WMS Mobile, tap **"Picking"** from the home screen. On the **"Scan Section"** screen, scan or type a section barcode that is configured for Rapid picking. If the section uses Rapid type, the flow proceeds to the rapid picking screens instead of the tote-based flow.

- [ ] Scan **package** label → `processRapidPickScanPackage`
-
  > **How:** The **"Scan Package"** screen appears. Scan the barcode of the package (parcel/box) that you'll be picking into.

- [ ] Select **package type**
-
  > **How:** The **"Scan Package Type"** screen appears. Select the appropriate package type from the list (e.g., box size, parcel type).

- [ ] Scan **source** (location/stock) → `processRapidPickScanSource`
-
  > **How:** The **"Scan Source"** screen shows the SKU and quantity to pick. Go to the source location. Scan the location barcode or stock unit barcode. If a simpler mode is available, the **"Scan Source Simple"** screen is used instead.

- [ ] Verify package → `processRapidPickScanPackageToVerify`
-
  > **How:** The **"Verify Package"** screen appears. Scan the package label again to confirm it matches. This prevents mix-ups.

- [ ] Repeat for all positions
-
  > **How:** The flow cycles back through scan package → scan source → verify for each position in the picking order until all items are picked.

- [ ] Order → PICKED → PACKED
-
  > **How:** Once all positions are complete, the order transitions through PICKED to PACKED automatically. A success message appears on the mobile screen.

---

## Cross-Cutting Checks

- [ ] **Printers** — verify label/laser printers reachable (CUPS)
-
  > **How:** In WMS Web UI, the Dashboard has a printer popup component. Verify printers are listed and reachable. On the old WMS mobile, go to **"PRINTING"** from the home screen to test label printing by scanning a parcel and printing its pick sheet or carrier label. Check the CUPS admin page (usually `http://server:631`) to verify printers are online.

- [ ] **OMS ↔ WMS Messages** — check `message` table for SENT status and valid responses
-
  > **How:** Query the WMS database `message` table: `SELECT * FROM message ORDER BY created DESC LIMIT 20`. Verify recent messages have `state = SENT` and no error responses. Check both directions — WMS→OMS and OMS→WMS.

- [ ] **Stock sync** — OMS inventory matches WMS after receiving/shipping/adjustments
-
  > **How:** In OMS, go to the **Inventory** page and check on-hand quantities for a few test SKUs. Compare with WMS Web UI → **Handling Units → Stock Units** for the same SKUs. Totals should match (accounting for reserved, on-hold, and damaged amounts).

- [ ] **Auth** — Keycloak SSO working across OMS, WMS web, WMS mobile
-
  > **How:** Log out and log back in to each system (OMS, WMS Web UI, WMS Mobile). Verify SSO works — logging into one should authenticate across the others. Test with different user roles to verify permission-based access (e.g., a user without picking permissions should not see the Picking option on mobile).

- [ ] **Error handling** — intentionally trigger exceptions (bad address, insufficient stock, invalid scan) and verify graceful handling
-
  > **How:** Test a few intentional failures: (1) In OMS, upload an order with an invalid address — verify it creates an Address exception. (2) On WMS Mobile picking, scan a wrong location barcode — verify an error message appears and picking doesn't proceed. (3) On receiving, enter a quantity exceeding the expected amount — verify the system warns or prevents over-receiving. (4) Try to close a BOL with no parcels assigned — verify an appropriate error message.
