---
name: clickup-wms-tickets-fulfillment-backlog
description: Which ClickUp list to file new WMS task/bug tickets in
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 50923e14-62bd-4abf-a57d-571f1819fe93
  modified: 2026-07-26T02:01:37.649Z
---

When creating a new ClickUp ticket for any WMS task (bug, feature, etc.), file it in the **Fulfillment Development Backlog** list.

- List name: `Fulfillment Development Backlog`
- List ID: `901103718309`
- Path: Workspace → `SiteBoss Development` space → `Backlog` folder → `Fulfillment Development Backlog`

**Why:** User directive (2026-07-25) — WMS tickets belong in this category alongside the other WMS tickets.

**How to apply:** Default `list_id` to `901103718309` for `clickup_create_task` on WMS work; no need to re-ask which list. Still confirm assignee/priority/status if not obvious.
