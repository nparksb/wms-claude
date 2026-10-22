# SBDEV-3142 AC-1 — live baseline probe output (verbatim, final run: scope 20/33)

Run 2026-08-31 against https://wms-api.dev.sbo.li (tenant wineco / facility wsl).
Accounts: truckloading (4 fns, holds none) / sbtest (35, two-directional differential) /
panderson (80, sb_admin control). Script:
`sbdocs/9-System/scripts/probe-wms2-report-read-gating-dev.sh baseline`

Includes row 20 (GET /v3/transfers/skus), taken into scope by Nam 2026-08-31.

Three instrument bugs were found and fixed BEFORE this run was trusted:
  1. The 3 GET `*View` rows omitted the REQUIRED page+size params -> six 400s that looked
     like findings. panderson 400'd too, which is what exposed it as my bug.
  2. The empty-payload guard was a byte threshold (`-lt 32`), and
     `{"content":[],"totalElements":0}` is EXACTLY 32 bytes -> an empty page reported as a
     confirmed leak. Now asserts on content, not size.
  3. Row 20's `orderBatchId` is a REQUIRED @RequestParam - same 400-proves-nothing trap.

```
SBDEV-3142 read-gating probe — mode=baseline — 2026-08-31T16:45:55Z
  truckloading(4 fns, none) / sbtest(35, holds INV+LOCK+TRANSFER) / panderson(80, sb_admin)

── A. The 10 dual-mapped exports, deprived user, BOTH prefixes (20 rows)
  PASS  report/exportInventory  [truckloading]                         200 (6042 B)
  PASS  dashboard/exportInventory  [truckloading]                      200 (6042 B)
  PASS  report/exportLock  [truckloading]                              200 (5736 B)
  PASS  dashboard/exportLock  [truckloading]                           200 (5736 B)
  PASS  report/exportReceiving  [truckloading]                         200 (6404 B)
  PASS  dashboard/exportReceiving  [truckloading]                      200 (6404 B)
  PASS  report/exportSkuLocation  [truckloading]                       200 (7003 B)
  PASS  dashboard/exportSkuLocation  [truckloading]                    200 (7003 B)
  PASS  report/exportFlowbin  [truckloading]                           200 (7301 B)
  PASS  dashboard/exportFlowbin  [truckloading]                        200 (7301 B)
  PASS  report/exportParcelPicking  [truckloading]                     200 (6322 B)
  PASS  dashboard/exportParcelPicking  [truckloading]                  200 (6322 B)
  PASS  report/exportOutboundParcel  [truckloading]                    200 (6920 B)
  PASS  dashboard/exportOutboundParcel  [truckloading]                 200 (6920 B)
  PASS  report/exportStockUnitRecord  [truckloading]                   200 (7268 B)
  PASS  dashboard/exportStockUnitRecord  [truckloading]                200 (7268 B)
  PASS  report/exportContainerRecord  [truckloading]                   200 (6030 B)
  PASS  dashboard/exportContainerRecord  [truckloading]                200 (6030 B)
  PASS  report/exportStorageLocations  [truckloading]                  200 (566050 B)
  PASS  dashboard/exportStorageLocations  [truckloading]               200 (566050 B)

── B. The 3 dual-mapped GET monitor views, deprived user (6 rows)
  PASS  report/flowbinMonitorView  [truckloading]                      200 (14990 B)
  PASS  dashboard/flowbinMonitorView  [truckloading]                   200 (14990 B)
  INCON report/parcelPickingView  [truckloading]                       200 but empty result set (32 B) — reachable, leak NOT demonstrated
  INCON dashboard/parcelPickingView  [truckloading]                    200 but empty result set (32 B) — reachable, leak NOT demonstrated
  INCON report/parcelMonitorView  [truckloading]                       200 but empty result set (32 B) — reachable, leak NOT demonstrated
  INCON dashboard/parcelMonitorView  [truckloading]                    200 but empty result set (32 B) — reachable, leak NOT demonstrated

── C. ClubLine + Transfers query-shaped reads, deprived user (7 rows, incl. row 20)
  PASS  clubLine/skus  [truckloading]                                  200 (563 B)
  PASS  clubLine/unitLoads  [truckloading]                             200 (11874 B)
  PASS  clubLine/parcels  [truckloading]                               200 (1584 B)
  PASS  transfers/unitLoads  [truckloading]                            200 (667 B)
  PASS  transfers/parcels  [truckloading]                              200 (525 B)
  PASS  transfers/availableTransferLanes  [truckloading]               200 (621 B)
  PASS  transfers/skus (GET)  [truckloading]                           200 (547 B)

── D. DIFFERENTIAL (the load-bearing section) — sbtest LACKS CLUB_LINE + RECEIVED_STOCK_OVERVIEW
     but HOLDS INVENTORY_RECORD + LOCK_OVERVIEW + TRANSFER_ORDER. Post-fix it must be DENIED
     on the first two rows and ALLOWED on the last three. All-denied = over-gated;
     all-allowed = inert. Neither is visible with a deprived-only account.
  PASS  clubLine/skus  [sbtest: lacks CLUB_LINE]                       200 (563 B)
  PASS  report/exportReceiving  [sbtest: lacks RECV]                   200 (6403 B)
  PASS  report/exportInventory  [sbtest: HOLDS INV]                    200 (6041 B)
  PASS  report/exportLock  [sbtest: HOLDS LOCK]                        200 (5735 B)
  PASS  transfers/parcels  [sbtest: HOLDS TRANSFER]                    200 (525 B)
  PASS  transfers/skus  [sbtest: HOLDS TRANSFER]                       200 (547 B)

── E. CONTROL — the entitled admin must keep working in BOTH modes.
     A gated run where these fail means the fix broke the feature, not that it closed a hole.
  PASS  report/exportInventory  [panderson]                            200 (6041 B)
  PASS  dashboard/exportInventory  [panderson]                         200 (6041 B)
  INCON report/parcelMonitorView  [panderson]                          200 but empty result set (32 B) — reachable, leak NOT demonstrated
  PASS  clubLine/skus  [panderson]                                     200 (563 B)

── F. MOBILE SAFETY — DashboardController-DECLARED handlers, which our change must NOT touch.
     These are called by the MOBILE UI. declaringClass is DashboardController, not
     ReportController, so a method-level annotation on the exports cannot reach them.
     They must return 200 in BOTH modes. A 403 here in gated mode = a 403'd mobile screen.
  PASS  dashboard/orderMonitorViewSummary  [truckloading]              200 (4186 B)
  PASS  dashboard/replenishMonitorViewSummary  [truckloading]          200 (10325 B)

Result: 40 pass, 0 fail, 5 inconclusive  (mode=baseline)

Reading a BASELINE run:
  Sections A-D all PASS with non-trivial byte counts => the exposure is CONFIRMED. AC-1 met.
  Any INCON row  => reachable but no data returned; re-derive that row's ids before ticking it.
  Section F PASS => the mobile-shared handlers are live, so the gated run can prove they survive.
```
