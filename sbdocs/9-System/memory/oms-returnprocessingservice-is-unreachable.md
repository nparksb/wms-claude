---
name: oms-returnprocessingservice-is-unreachable
description: OMS v2 ReturnProcessingService / ProcessReturnJob are never dispatched — InventoryService::adjustInventory (OMS return restock) never runs; live returns are ReturnManagementService/QaReturnService + RETURN advice
metadata:
  node_type: memory
  type: project
  originSessionId: b745221a-79a8-466a-b748-f341c296e411
  modified: 2026-11-12T23:22:40.866Z
---

Verified 2026-11-13 on oms-laravel-api origin/develop 387be521 (SBDEV-4127). Nothing dispatches `ProcessReturnJob`, and nothing calls `ReturnProcessingService::createReturnOrder()`. A repo-wide `git grep` for both class names returns only their own files and docs. An independent review lane also checked the scheduler, listeners, providers and console commands. So `InventoryService::adjustInventory()`, which is reached only from that service, never runs either: the OMS-side "return to inventory" restock is dead code. The live return path is `QaReturnController` → `ReturnManagementService` / `QaReturnService`, and WMS stock arrives through the RETURN advice (`rest/advice/create`).

**Why:** the SBDEV-4127 ticket called `inventory_adjust` "LIVE" because of these callers. The decision first rested on a double-count risk that cannot happen.

**How to apply:** before treating anything reached from `ReturnProcessingService` as live behaviour, re-check for a dispatch site. If someone wires it back up, pushing return restocks to the WMS would double-count against the RETURN advice. Whether returned stock reaches **OMS** `product_inventory` at all is an open returns question that SBDEV-4127 did not answer. Related: [[sbdev-1512-damaged-returns-decisions]].
