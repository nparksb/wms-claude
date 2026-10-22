---
ticket: "SBDEV-3758"
kind: evidence
created: 2026-10-14
env: wms2 dev (wineco/WSL, DB dev_wh01_om1), build 2026-10-14 01:55:15 = develop f3fa36d5 (PR #512)
user: panderson
verdict: PASS
---

# SBDEV-3758: dev test of the transfer-order pick on a pick face

## Setup (writes on dev)
- **Pick face:** FLA 948558197, SKU TRACTOR (client PHV), bin 21-B07. Its UL 949451598 was on 21-B07 with 1 unit and 0 reserved. It was the SKU's only stock unit in a transfer area.
- **Order:** created via `PUT /rest/order/create`. TRANSFER_OFFSITE, transfer_id `SBDEV3758-T-1791945248`, order 051900-000001 (id 31394744), TRACTOR × 2.
- **Lane:** `GET /v3/transfers/activateTransferOrder/31394744/59201` assigned TransferLane02 and set state 510.

## Handheld flow (`/v3/transferOrder/*`)
- **processOrderPositionSelect:** returned one pick source, 21-B07, amount 1.
- **processScanUnitLoad** with `21-B07`: set currentPickSource to stock unit 948956043.
- **processScanTransferLane** with `TransferLane02`: returned HTTP 200 and `"Moved whole stock"`. amountNeeded dropped to 1, and no pick sources were left.

## End state (dev DB)
- **Pick face:** FLA 948558197's UL 949451598 (`21-B07`) is **still on 21-B07**. Its stock unit is there at amount 0.
- **Lane:** TransferLane02 holds the 1 unit on a **new** UL, UL323293 (id 31394747). Its unitload_record is CREATED, Spawn → TransferLane02, MANUAL_SPLIT.
- **Stock records** (all MANUAL_SPLIT):
  - STOCK_REMOVED −1 on 21-B07;
  - STOCK_CREATED +1 on UL323293;
  - plus the known 0-amount STOCK_CREATED artefact (SBDEV-3382).
- **No relocation:** there is no TRANSFERRED unitload_record for 21-B07. Before the fix, the container itself moved to the lane.

## Cleanup (done 2026-10-14)
- **Stock moved back:** `POST /v3/stockUnit/transferStock` moved stock unit 31394749 (1 unit) into the existing container 21-B07. The pick face's stock unit 948956043 is back to amount 1, reserved 0.
- **UL323293 retired:** once emptied, it was sent to Nirwana as `UL323293-X-31394747`.
- **Order cancelled:** `POST /rest/order/cancelPositions` set order 31394744 to state 800 and released its lane. No TRACTOR stock is left on TransferLane02.
